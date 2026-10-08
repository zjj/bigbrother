import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 所有数据库访问都串行化在这条队列上。
final class EventStore {

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "local.bigbrother.store")
    private let queueKey = DispatchSpecificKey<UInt8>()

    /// 写库失败次数。持续增长说明存储层出问题了。
    private(set) var writeFailures = 0
    private var lastLog = Date.distantPast
    private var storageFailure: String?

    var storageError: String? { onQueue { storageFailure } }

    private func recordFailure(_ message: String) {
        writeFailures += 1
        storageFailure = message
        if Date().timeIntervalSince(lastLog) > 5 {
            lastLog = Date()
            DBLog(message)
        }
    }

    /// 统一日志出口。用 NSLog 而不是 stderr —— 通过 `open` 启动的 App
    /// 的 stderr 不一定能被读到,而 NSLog 会进统一日志。
    private func DBLog(_ msg: String) {
        Diagnostics.log("[DB] \(msg)")
    }

    /// 串行化 + **重入保护**。
    ///
    /// 踩过的坑:如果某条路径在 store 队列内部又调用 queue.sync,
    /// 就会永久死锁 —— 表现是「App 还活着、log stream 也活着,
    /// 但再也不会写任何事件」。所以这里先判断是否已在队列上。
    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    /// 内存中的会话表:sessionKey → 最近一次写库的 event id 与时间。
    /// 用于把一次采集产生的 3~4 条日志折叠成一行。
    private var openSessions: [String: (id: Int64, ts: Date)] = [:]

    let path: String

    init(path: String? = nil) {
        self.path = path ?? EventStore.defaultPath()
        queue.setSpecific(key: queueKey, value: 1)
        open()
        if db != nil {
            migrate()
            if storageFailure == nil { DBLog("已打开数据库: \(self.path)") }
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    static func defaultPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["BIGBROTHER_DB"] ?? env["PRIVACYSENTINEL_DB"] { return p }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("BigBrother", isDirectory: true)
        return dir.appendingPathComponent("events.db").path
    }

    // MARK: - 建库

    private func open() {
        do {
            if path != ":memory:" {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            }
        } catch {
            recordFailure("无法创建记录文件夹: \(error.localizedDescription)")
            return
        }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开文件"
            recordFailure("无法打开记录文件: \(message)")
            if let db { sqlite3_close(db) }
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS events (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            ts_epoch         REAL    NOT NULL,
            ts_text          TEXT    NOT NULL,
            service          TEXT    NOT NULL,
            kind             TEXT    NOT NULL,
            responsible      TEXT,
            responsible_path TEXT,
            accessing        TEXT,
            accessing_path   TEXT,
            accessing_pid    INTEGER,
            requesting       TEXT,
            channel          TEXT,
            auth_value       INTEGER,
            preflight        TEXT,
            log_count        INTEGER NOT NULL DEFAULT 1,
            severity         INTEGER NOT NULL DEFAULT 1,
            reason           TEXT,
            is_inherited     INTEGER NOT NULL DEFAULT 0,
            session_key      TEXT,
            duration         REAL
        );
        CREATE INDEX IF NOT EXISTS idx_ts      ON events(ts_epoch);
        CREATE INDEX IF NOT EXISTS idx_actor_ts ON events(accessing, ts_epoch);
        CREATE INDEX IF NOT EXISTS idx_subject_ts
            ON events(COALESCE(responsible, accessing), ts_epoch);
        CREATE INDEX IF NOT EXISTS idx_denied_ts ON events(auth_value, ts_epoch);
        -- annotateDuration 的查询是
        --   WHERE accessing_pid = ? AND kind = ? ORDER BY ts_epoch DESC LIMIT 1
        -- 没有这个复合索引时会退化成「扫该 kind 的全部行 + 临时 B 树排序」
        CREATE INDEX IF NOT EXISTS idx_pid_kind_ts ON events(accessing_pid, kind, ts_epoch);
        """)

        // ── 迁移(旧库才会真正执行)──
        var columns = Set<String>()
        query("PRAGMA table_info(events)", []) { st in
            if let name = Self.text(st, 1) { columns.insert(name) }
        }
        if !columns.contains("duration") {
            exec("ALTER TABLE events ADD COLUMN duration REAL;")
        }

        // session_key 曾经作为列持久化,但**没有任何查询会读它** ——
        // 会话折叠完全在内存 openSessions 里做。连带 idx_sess 也是零使用。
        // 它们只增加写入开销和库体积,一并清掉。
        exec("DROP INDEX IF EXISTS idx_sess;")
        if columns.contains("session_key") {
            exec("ALTER TABLE events DROP COLUMN session_key;")
        }

        // Remove unused single-column indexes after installing indexes matched
        // to the app's actual filtering and sort patterns.
        exec("DROP INDEX IF EXISTS idx_kind;")
        exec("DROP INDEX IF EXISTS idx_actor;")
        migrateEventSemantics()
    }

    /// 旧记录重新判定。
    ///
    /// v2 改的是**判定语义**:已授权的第三方访问不再被当成「权限检查」丢弃,
    /// 于是历史记录也必须跟着重新判定,否则界面上的数字会自相矛盾 ——
    /// 今天的微信录屏算使用,昨天同样的日志却算权限检查。
    ///
    /// 只重算 severity / reason(判定结果);授权值、preflight、时间段等原始
    /// 证据一字不改,也不删除任何行。
    private static let semanticsVersion = 2

    private func migrateEventSemantics() {
        guard scalar("PRAGMA user_version", []) < Self.semanticsVersion else { return }
        guard run("BEGIN IMMEDIATE", []) else { return }
        var lastID: Int64 = 0
        while true {
            var batch: [PrivacyEvent] = []
            let succeeded = query("""
                SELECT \(Self.eventColumns) FROM events
                WHERE id > ? AND service LIKE 'kTCCService%'
                ORDER BY id LIMIT 500
                """, [.int(lastID)]) { st in
                batch.append(Self.readEvent(st))
            }
            guard succeeded else {
                _ = run("ROLLBACK", [])
                return
            }
            if batch.isEmpty { break }
            for e in batch {
                let (severity, reason) = Judge.evaluate(
                    kind: e.kind, service: e.service, responsible: e.responsible,
                    accessing: e.accessing, requesting: e.requesting,
                    authValue: e.authValue, preflight: e.preflight,
                    directRequest: e.requesting == e.accessing?.identifier)
                guard run("UPDATE events SET severity = ?, reason = ?, preflight = ? WHERE id = ?",
                          [.int(Int64(severity)), .text(reason),
                           .text(e.normalizedPreflight), .int(e.id)]) else {
                    _ = run("ROLLBACK", [])
                    return
                }
                lastID = e.id
            }
        }
        guard run("PRAGMA user_version = \(Self.semanticsVersion)", []), run("COMMIT", []) else {
            _ = run("ROLLBACK", [])
            return
        }
    }

    private func exec(_ sql: String) {
        guard let db else {
            recordFailure("记录文件未打开")
            return
        }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            recordFailure("无法更新记录文件: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: - 写入(含会话折叠)

    /// 写入一个非 Apple 专属事件。若属于同一个采集会话,则只增加计数而不新增行。
    @discardableResult
    func insert(_ e: PrivacyEvent) -> (id: Int64, merged: Bool, ignored: Bool) {
        onQueue {
            if e.isAppleOnly { return (0, false, true) }
            if !e.isRecordable { return (0, false, true) }
            guard db != nil else {
                recordFailure("记录文件未打开")
                return (0, false, false)
            }
            let key = e.sessionKey

            // 会话折叠:同一次采集连打 3~4 条日志
            if let open = openSessions[key],
               abs(e.timestamp.timeIntervalSince(open.ts)) <= Judge.sessionGap {
                // severity 取最大值,避免先到的低危日志掩盖后到的高危判定
                if e.channel == .replayd {
                    // 一次录屏的 4 条日志里,可能首条请求通道是 coreaudiod、
                    // 后三条才是 replayd。以「像素采集」为准,否则整行会被
                    // 误标成「仅窗口元数据」。
                    guard run("""
                        UPDATE events SET log_count = log_count + 1,
                                          ts_epoch = ?, ts_text = ?,
                                          severity = MAX(severity, ?),
                                          requesting = ?, channel = ?, reason = ?,
                                          duration = COALESCE(?, duration)
                        WHERE id = ?
                        """,
                        [.double(e.timestamp.timeIntervalSince1970),
                         .text(Self.fmt.string(from: e.timestamp)),
                         .int(Int64(e.severity)),
                         .text(e.requesting),
                         .text(e.channel.rawValue),
                         .text(e.reason),
                         e.duration.map(Bind.double) ?? .text(nil),
                         .int(open.id)]) else { return (0, false, false) }
                } else {
                    guard run("""
                        UPDATE events SET log_count = log_count + 1,
                                          ts_epoch = ?, ts_text = ?,
                                          severity = MAX(severity, ?)
                        WHERE id = ?
                        """,
                        [.double(e.timestamp.timeIntervalSince1970),
                         .text(Self.fmt.string(from: e.timestamp)),
                         .int(Int64(e.severity)),
                         .int(open.id)]) else { return (0, false, false) }
                }
                openSessions[key] = (open.id, e.timestamp)
                return (open.id, true, false)
            }

            guard run("""
                INSERT INTO events
                (ts_epoch, ts_text, service, kind, responsible, responsible_path,
                 accessing, accessing_path, accessing_pid, requesting, channel,
                 auth_value, preflight, log_count, severity, reason, is_inherited, duration)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [.double(e.timestamp.timeIntervalSince1970),
                 .text(Self.fmt.string(from: e.timestamp)),
                 .text(e.service),
                 .text(e.kind.rawValue),
                 .text(e.responsible?.identifier),
                 .text(e.responsible?.path),
                 .text(e.accessing?.identifier),
                 .text(e.accessing?.path),
                 .int(Int64(e.accessing?.pid ?? -1)),
                 .text(e.requesting),
                 .text(e.channel.rawValue),
                 .int(Int64(e.authValue ?? -1)),
                 // 归一化后再落库:模型与 SQL 的判定必须永远一致。
                 .text(e.normalizedPreflight),
                 .int(Int64(e.logCount)),
                 .int(Int64(e.severity)),
                 .text(e.reason),
                 .int(e.isInherited ? 1 : 0),
                 e.duration.map(Bind.double) ?? .text(nil)]) else { return (0, false, false) }

            let id = sqlite3_last_insert_rowid(db)
            openSessions[key] = (id, e.timestamp)
            if openSessions.count > 512 { pruneSessions(now: e.timestamp) }
            return (id, false, false)
        }
    }

    private func pruneSessions(now: Date) {
        openSessions = openSessions.filter { now.timeIntervalSince($0.value.ts) < 30 }
    }

    /// 录制开始不依赖授权结果;身份来自实时进程或邻近的 TCC 归因。
    func recordingStarted(pid: Int, at timestamp: Date, actor: ProcInfo?,
                          excluding shouldIgnore: (PrivacyEvent) -> Bool = { _ in false }) -> PrivacyEvent? {
        onQueue {
            var duplicate = false
            query("""
                SELECT id FROM events WHERE service = 'SCREEN_RECORDING'
                  AND accessing_pid = ? AND ts_epoch = ? LIMIT 1
                """, [.int(Int64(pid)), .double(timestamp.timeIntervalSince1970)]) { _ in
                duplicate = true
            }
            if duplicate { return nil }
            var attribution: PrivacyEvent?
            query("""
                SELECT \(Self.eventColumns) FROM events
                WHERE accessing_pid = ? AND kind = ? AND service <> 'SCREEN_RECORDING'
                  AND ts_epoch BETWEEN ? AND ?
                ORDER BY ABS(ts_epoch - ?) ASC LIMIT 1
                """, [.int(Int64(pid)), .text(PrivacyKind.screenCapture.rawValue),
                      .double(timestamp.addingTimeInterval(-5).timeIntervalSince1970),
                      .double(timestamp.addingTimeInterval(5).timeIntervalSince1970),
                      .double(timestamp.timeIntervalSince1970)]) { st in
                attribution = Self.readEvent(st)
            }
            guard pid > 0, let source = actor ?? attribution?.accessing, source.pid == pid else {
                Diagnostics.log("[Capture] 录制已开始但无法确认访问者 pid=\(pid)")
                return nil
            }
            let owner = attribution?.accessing?.identifier == source.identifier
                ? attribution?.responsible : nil
            var event = PrivacyEvent(
                timestamp: timestamp, service: "SCREEN_RECORDING", kind: .screenCapture,
                responsible: owner, accessing: source, requesting: "com.apple.replayd",
                severity: PrivacyKind.screenCapture.baseSeverity,
                reason: "ScreenCaptureKit 报告录制开始",
                isInherited: owner.map { $0.identifier != source.identifier } ?? false)
            guard !shouldIgnore(event) else { return nil }
            let result = insert(event)
            guard result.id > 0 else { return nil }
            event.id = result.id
            return event
        }
    }

    /// 已入库的屏幕记录补上采集时长。
    ///
    /// 旧版会把「尚未证实的像素请求」先扣在内存里,等结束日志到了再入库;
    /// 新版这类请求本身就是使用事件、已经入库,所以只需按 pid 找到那一行补时长。
    func annotateDuration(pid: Int, startedAt: Date, seconds: Double) -> PrivacyEvent? {
        onQueue {
            guard seconds > 0, pid > 0 else { return nil }
            // ⚠️ 这里**不能**套 usageFilter:还没有授权结果的屏幕请求
            // (auth_value 为空)在补上时长之前不算使用,但时长恰恰是把它
            // 升级成「实际活动」的证据。窗口(±5s)+ pid + kind + 兄弟行去重
            // 已经足够精确,不需要再加使用口径。
            var candidate: PrivacyEvent?
            query("""
                SELECT \(Self.eventColumns) FROM events
                WHERE accessing_pid = ? AND kind = ?
                  AND ts_epoch BETWEEN ? AND ?
                  AND (service <> 'SCREEN_RECORDING' OR ts_epoch = ?)
                  AND COALESCE(auth_value,-1) <> 0
                  AND COALESCE(duration, 0) <= 0
                  AND NOT EXISTS (
                      SELECT 1 FROM events AS sibling
                      WHERE sibling.accessing_pid = events.accessing_pid
                        AND sibling.service = events.service
                        AND sibling.id <> events.id
                        AND COALESCE(sibling.duration, 0) > 0
                        AND ABS(sibling.ts_epoch - ?) <= 5)
                ORDER BY (service = 'SCREEN_RECORDING') DESC,
                         -- 时长属于「真的发起采集」的那条,而不是同一次采集里的
                         -- 授权查询。preflight=no 的那条优先。
                         (LOWER(TRIM(COALESCE(preflight,''), char(9) || char(10) || char(13) || ' ')) = 'no') DESC,
                         ABS(ts_epoch - ?) ASC LIMIT 1
                """, [.int(Int64(pid)), .text(PrivacyKind.screenCapture.rawValue),
                      .double(startedAt.addingTimeInterval(-5).timeIntervalSince1970),
                      .double(startedAt.addingTimeInterval(5).timeIntervalSince1970),
                      .double(startedAt.timeIntervalSince1970),
                      .double(startedAt.timeIntervalSince1970),
                      .double(startedAt.timeIntervalSince1970)]) { st in
                candidate = Self.readEvent(st)
            }
            guard let existing = candidate else {
                Diagnostics.log("[Capture] 无法归因录屏活动 pid=\(pid)")
                return nil
            }
            let assessment = Self.recordingAssessment(for: existing)
            guard run("UPDATE events SET duration = ?, severity = ?, reason = ? WHERE id = ?",
                      [.double(seconds), .int(Int64(assessment.severity)),
                       .text(assessment.reason), .int(existing.id)]) else { return nil }
            return nil
        }
    }

    private static func recordingAssessment(for event: PrivacyEvent) -> (severity: Int, reason: String) {
        if event.service == "SCREEN_RECORDING" {
            return (event.severity, "ScreenCaptureKit 报告录制开始与结束")
        }
        // 用事件自己的 preflight —— 「已授权的访问痕迹」和「已证实访问」的
        // 判定不同,不能统一按 preflight=no 重算。
        let (severity, reason) = Judge.evaluate(
            kind: event.kind, service: event.service,
            responsible: event.responsible, accessing: event.accessing,
            requesting: event.requesting, authValue: event.authValue,
            preflight: event.preflight)
        if reason == "已授权调用，系统记录了这次访问" || reason == "部分授权，系统记录了这次访问"
            || reason == "已授权的访问请求，确实向系统申请了该权限" {
            return (severity, "记录到屏幕录制活动")
        }
        return (severity, reason + ";记录到屏幕录制活动")
    }

    /// 有采集时长的记录(用于统计「录了多久」)
    func recordingDurations(days: Int = 7) -> [(actor: String, seconds: Double)] {
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        var out: [(String, Double)] = []
        query("""
              SELECT COALESCE(accessing,'?'), duration FROM events
              WHERE ts_epoch >= ? AND kind = 'kTCCServiceScreenCapture'
              AND duration > 0 \(Self.usageFilter)
              ORDER BY ts_epoch DESC LIMIT 50
              """, [.double(since)]) { st in
            out.append((Self.text(st, 0) ?? "?", sqlite3_column_double(st, 1)))
        }
        return out.map { (actor: $0.0, seconds: $0.1) }
    }

    // MARK: - 查询

    private static let activityCondition = """
        ((service = 'CLIPBOARD' AND kind = 'CLIPBOARD')
         OR (service = 'CAMERA_IN_USE' AND kind = 'kTCCServiceCamera')
         -- 苹果自己的位置组件不是 App(历史记录里可能有),不计入使用
         OR (service = 'LOCATION_IN_USE' AND kind = 'kTCCServiceLocation'
             AND NOT \(systemLocationCondition))
         OR (kind = 'kTCCServiceScreenCapture'
             AND (service = 'SCREEN_RECORDING'
                  OR (COALESCE(duration,0) > 0 AND COALESCE(auth_value,-1) <> 0))))
        """

    /// 「已授权」= 系统允许或部分允许。
    private static let allowedCondition = "COALESCE(auth_value,-1) IN (2,3)"

    /// 屏幕画面:只有 replayd 那条通路才涉及像素,WindowServer 通路只是窗口信息。
    private static let pixelChannelCondition = "COALESCE(channel,'') = 'com.apple.replayd'"

    /// 有明确证据的采集动作(对应 `PrivacyEvent.isConfirmedAccess`)。
    private static let confirmedAccessCondition = """
        (service LIKE 'kTCCService%'
         AND LOWER(TRIM(COALESCE(preflight,''), char(9) || char(10) || char(13) || ' ')) = 'no'
         AND \(allowedCondition)
         AND (kind <> 'kTCCServiceScreenCapture' OR \(pixelChannelCondition)))
        """

    /// 访问者里有第三方程序(对应 `PrivacyEvent.involvesThirdParty`)。
    ///
    /// ⚠️ 两个 OR 分支整体必须加括号 —— 少一层括号,SQL 的 AND 优先级会让
    /// `auth_value IN (2,3)` 变成可选项,苹果自家组件的预检查也会被算成使用。
    private static let thirdPartyCondition = """
        ((COALESCE(responsible,'') <> '' AND responsible NOT LIKE 'com.apple.%')
         OR (COALESCE(accessing,'') <> '' AND accessing NOT LIKE 'com.apple.%'))
        """

    /// 已授权访问(对应 `PrivacyEvent.isAuthorizedAccessTrace`)。
    ///
    /// 旧版把这类记录全部归入「权限检查」,于是 App 一旦拿到授权,它的每次访问
    /// 都从统计、趋势和下钻里消失。这里把它们放回使用统计,但保留 preflight
    /// 列以便界面区分「已证实访问」和「访问痕迹」。
    private static let accessTraceCondition = """
        (service LIKE 'kTCCService%'
         AND LOWER(TRIM(COALESCE(preflight,''), char(9) || char(10) || char(13) || ' ')) = 'yes'
         AND \(allowedCondition)
         AND \(thirdPartyCondition)
         AND (kind <> 'kTCCServiceScreenCapture' OR \(pixelChannelCondition)))
        """

    /// 苹果自己的位置组件(历史遗留行):不是 App,任何口径都不该出现。
    private static let systemLocationCondition = """
        (kind = 'kTCCServiceLocation'
         AND (COALESCE(accessing,'') LIKE 'com.apple.%'
              OR COALESCE(accessing,'') LIKE '%.framework'
              OR COALESCE(accessing,'') LIKE '%.bundle'
              OR COALESCE(accessing_path,'') LIKE '/System/%'))
        """

    /// 访问记录(记录页默认口径) = 证实过的采集动作 + 已授权访问
    private static let usageCondition =
        "(\(activityCondition) OR \(confirmedAccessCondition) OR \(accessTraceCondition))"

    /// 「仅权限查询」:预检查且没拿到授权(或结果未知)。
    private static let checkCondition =
        "(LOWER(TRIM(COALESCE(preflight,''), char(9) || char(10) || char(13) || ' ')) = 'yes'"
        + " AND NOT \(usageCondition))"

    private static let usageFilter = " AND \(usageCondition)"
    private static let visibleFilter = usageFilter

    private static func evidenceFilter(_ scope: EventScope) -> String {
        switch scope {
        case .usage: return usageFilter
        case .activity: return " AND \(activityCondition)"
        case .permissionChecks: return " AND \(checkCondition)"
        case .unconfirmed:
            // 历史遗留的系统位置组件既不算使用、也不是"未确认请求" ——
            // 它压根不是 App,只在「全部证据」里可见。
            return " AND NOT \(usageCondition) AND NOT \(checkCondition)"
                + " AND NOT \(systemLocationCondition)"
        case .all: return ""
        }
    }

    /// 今日按类型计数。
    ///
    /// ── 为什么要写成 MATERIALIZED CTE ──────────────────────────────
    /// 直接写 `WHERE ts_epoch >= ? AND NOT(...) GROUP BY kind`,SQLite 会
    /// **全索引扫描 idx_kind**(它想省掉一次 GROUP BY 排序),完全无视时间过滤。
    /// 50 万行实测 0.371 秒,而这条查询每 2 秒就要跑一次。
    ///
    /// `ANALYZE` 和覆盖索引都改变不了这个选择。用 MATERIALIZED 把时间范围
    /// 先固定成一个物化结果,就变成 `SEARCH idx_ts (ts_epoch>?)` → 0.004 秒,
    /// 快 88 倍,而且不像 `INDEXED BY` 那样会因为索引变动直接报错。
    func todayCounts() -> [(PrivacyKind, Int)] {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var out: [(PrivacyKind, Int)] = []
        // ⚠️ 用 SELECT * 而不是列清单:visibleFilter 引用的列一旦漏掉,
        // SQLite 只会报 "no such column",而 query() 的失败是静默的 ——
        // 表现就是概览页所有数字变成 0,极难定位。
        let sql = "WITH window AS MATERIALIZED ("
            + "SELECT * FROM events WHERE ts_epoch >= ?"
            + ") SELECT kind, COUNT(*) FROM window"
            + " WHERE 1=1\(Self.visibleFilter)"
            + " GROUP BY kind ORDER BY 2 DESC"
        query(sql, [.double(start)]) { st in
            if let raw = Self.text(st, 0) {
                // 认不出的 kind 归入 .other,绝不丢弃 ——
                // 否则一旦枚举里删掉某个类型,历史数据会从界面上凭空消失。
                out.append((PrivacyKind(rawValue: raw) ?? .other,
                            Int(sqlite3_column_int64(st, 1))))
            }
        }
        return out
    }

    /// 窗口信息相关记录数,不混进屏幕画面权限统计。
    func metadataOnlyCount(days: Int = 1) -> Int {
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        return scalar("SELECT COUNT(*) FROM events WHERE ts_epoch >= ?"
                      + " AND kind = 'kTCCServiceScreenCapture'"
                      + " AND (channel IS NULL OR channel <> 'com.apple.replayd')"
                      + " AND NOT (COALESCE(duration,0) > 0 AND COALESCE(auth_value,-1) <> 0)"
                      + Self.usageFilter,
                      [.double(since)])
    }

    func todayTotal() -> Int {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return scalar("SELECT COUNT(*) FROM events WHERE ts_epoch >= ?\(Self.visibleFilter)",
                      [.double(start)])
    }

    /// 最近 N 秒内的最高事件等级 —— 驱动菜单栏眼睛的颜色。
    /// 事件随时间滑出窗口,颜色就自动退回,不需要额外的状态机。
    /// 已排除窗口元数据枚举,否则任何 App 枚举一次窗口都会让眼睛变色。
    func maxSeveritySince(seconds: TimeInterval) -> Int {
        let since = Date().addingTimeInterval(-seconds).timeIntervalSince1970
        return scalar("SELECT COALESCE(MAX(severity),0) FROM events"
                      + " WHERE ts_epoch >= ?\(Self.visibleFilter)", [.double(since)])
    }

    func totalCount() -> Int { scalar("SELECT COUNT(*) FROM events WHERE 1=1\(Self.usageFilter)", []) }

    /// 被拒绝的请求次数,与所有相关记录的概览计数分开。
    func deniedCount(days: Int = 7) -> Int {
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        return scalar("SELECT COUNT(*) FROM events WHERE ts_epoch >= ? AND auth_value = 0"
                      + Self.visibleFilter, [.double(since)])
    }

    func deniedEvents(limit: Int = 20) -> [PrivacyEvent] {
        recentEvents(limit: limit, minSeverity: 0, onlyDenied: true)
    }

    /// 折叠会话表大小(诊断用)
    var openSessionCount: Int { onQueue { openSessions.count } }

    /// 把 WAL 折回主库。
    ///
    /// 只用 PASSIVE:不用 TRUNCATE —— 实测 `PRAGMA wal_checkpoint(TRUNCATE)`
    /// 会触发 SQLite 在解析阶段崩溃(见崩溃栈 sqlite3Pragma → sqlite3DbMallocRawNNTyped)。
    /// 另外 SQLite 默认的 wal_autocheckpoint(1000 页)本来就会自动折回,WAL 不会无限涨。
    func checkpoint() {
        onQueue { exec("PRAGMA wal_checkpoint(PASSIVE);") }
    }

    /// 删除超过 retentionDays 的事件。
    ///
    /// 菜单栏应用会连续运行数月,没有保留策略的话表会无限涨。
    /// 返回删掉的行数。
    @discardableResult
    func pruneOlderThan(days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let before = scalar("SELECT COUNT(*) FROM events", [])
        onQueue {
            _ = run("DELETE FROM events WHERE ts_epoch < ?", [.double(cutoff)])
        }
        let removed = before - scalar("SELECT COUNT(*) FROM events", [])
        if removed > 0 {
            Diagnostics.log("[DB] 保留策略:删除 \(removed) 条超过 \(days) 天的记录")
            onQueue { exec("PRAGMA incremental_vacuum;") }
        }
        return removed
    }

    /// 清空全部事件
    func clearAll() {
        queue.sync {
            exec("DELETE FROM events;")
            exec("VACUUM;")
            openSessions.removeAll()
        }
    }

    func highSeverityCount(sinceHours: Int = 24) -> Int {
        let since = Date().addingTimeInterval(-Double(sinceHours) * 3600).timeIntervalSince1970
        return scalar("SELECT COUNT(*) FROM events WHERE ts_epoch >= ? AND severity >= 4\(Self.visibleFilter)",
                      [.double(since)])
    }

    /// 今日按「授权主体」聚合 —— 概览页的主列表。
    ///
    /// 用 COALESCE(responsible, accessing) 而不是 accessing:
    /// 用户认识的永远是那个**授权方**,实测 46% 的事件里两者不同。
    ///
    /// 同样用 MATERIALIZED 锁住时间范围,否则会被规划成全索引扫描。
    func todaySubjects(limit: Int = 12) -> [(identifier: String, n: Int, worst: Int)] {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var out: [(String, Int, Int)] = []
        let sql = "WITH window AS MATERIALIZED ("
            + "SELECT * FROM events WHERE ts_epoch >= ?"
            + ") SELECT COALESCE(responsible, accessing) AS subj, COUNT(*), MAX(severity) FROM window"
            + " WHERE subj IS NOT NULL"
            + Self.visibleFilter
            // 第三方 App 排在系统组件前面。
            // 否则像 siriactionsd 这种「系统在替快捷指令跑腿」的组件
            // 会以几十次的调用量把真正值得看的 App 全部压到下面。
            + " GROUP BY subj ORDER BY (subj LIKE 'com.apple.%') ASC, 2 DESC LIMIT ?"
        query(sql, [.double(start), .int(Int64(limit))]) { st in
            guard let id = Self.text(st, 0) else { return }
            out.append((id,
                        Int(sqlite3_column_int64(st, 1)),
                        Int(sqlite3_column_int64(st, 2))))
        }
        return out
    }

    func topActors(days: Int = 7, limit: Int = 8) -> [(String, Int)] {
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        var out: [(String, Int)] = []
        // 与下钻口径一致:排除窗口元数据枚举
        query("""
              SELECT COALESCE(accessing,'?') AS a, COUNT(*) c FROM events
              WHERE ts_epoch >= ?\(Self.visibleFilter) GROUP BY a ORDER BY c DESC LIMIT ?
              """, [.double(since), .int(Int64(limit))]) { st in
            out.append((Self.text(st, 0) ?? "?", Int(sqlite3_column_int64(st, 1))))
        }
        return out
    }

    /// 以时间轴右端为界按小时聚合,每个区间包含起点、不包含终点。
    func hourlyHistogram(hours: Int = 24,
                         endingAt now: Date = HourlyTimeline.end(after: Date())) -> [Int] {
        var buckets = [Int](repeating: 0, count: hours)
        let since = now.addingTimeInterval(-Double(hours) * 3600).timeIntervalSince1970
        query("SELECT ts_epoch FROM events WHERE ts_epoch >= ? AND ts_epoch < ?\(Self.visibleFilter)",
              [.double(since), .double(now.timeIntervalSince1970)]) { st in
            let timestamp = sqlite3_column_double(st, 0)
            let idx = Int((timestamp - since) / 3600)
            if idx >= 0 && idx < hours { buckets[idx] += 1 }
        }
        return buckets
    }

    func recentEvents(limit: Int = 200, minSeverity: Int = 0,
                      onlyDenied: Bool = false,
                      kinds: Set<PrivacyKind>? = nil,
                      actor: String? = nil,
                      search: String = "",
                      since: Date? = nil,
                      subject: String? = nil,
                      scope: EventScope = .usage) -> [PrivacyEvent] {
        var sql = """
              SELECT \(Self.eventColumns)
              FROM events WHERE severity >= ?
              """
        var binds: [Bind] = [.int(Int64(minSeverity))]
        sql += Self.evidenceFilter(scope)
        // 时间下限必须和概览上那个数字的窗口一致
        if let since { sql += " AND ts_epoch >= ?"; binds.append(.double(since.timeIntervalSince1970)) }
        // 与概览页主列表同一个口径 —— 否则点进去数字对不上
        if let subject {
            sql += " AND COALESCE(responsible, accessing) = ?"
            binds.append(.text(subject))
        }
        if onlyDenied { sql += " AND auth_value = 0" }
        if let actor { sql += " AND accessing = ?"; binds.append(.text(actor)) }
        if let kinds {
            let selected = kinds.map(\.rawValue).sorted()
            if kinds.contains(.other) {
                let known = PrivacyKind.allCases.filter { $0 != .other }.map(\.rawValue).sorted()
                sql += " AND (kind IN (\(selected.map { _ in "?" }.joined(separator: ",")))"
                    + " OR kind NOT IN (\(known.map { _ in "?" }.joined(separator: ","))))"
                binds += selected.map { .text($0) } + known.map { .text($0) }
            } else {
                sql += " AND kind IN (\(selected.map { _ in "?" }.joined(separator: ",")))"
                binds += selected.map { .text($0) }
            }
        }
        if !search.isEmpty {
            sql += " AND (COALESCE(accessing,'') LIKE ? OR COALESCE(responsible,'') LIKE ?"
                 + " OR COALESCE(reason,'') LIKE ?)"
            let pat = "%\(search)%"
            binds += [.text(pat), .text(pat), .text(pat)]
        }
        sql += " ORDER BY ts_epoch DESC LIMIT ?"
        binds.append(.int(Int64(limit)))

        var out: [PrivacyEvent] = []
        query(sql, binds) { st in
            let event = Self.readEvent(st)
            let kind = event.kind
            if let kinds, !kinds.contains(kind) { return }
            out.append(event)
        }
        return out
    }

    /// 导出为 CSV(供外部取证 / 报表使用)
    func exportCSV(to path: String, days: Int = 7, scope: EventScope = .usage) throws -> Int {
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        var rows: [String] = []
        rows.append("时间,类型,分类,严重度,实际执行者,授权主体,请求通道,日志数,时长秒,授权值,判定,"
                    + "执行者路径,授权主体路径,preflight,事件阶段,授权结果,事件说明,证据强度,证据说明,"
                    + "计入使用统计,原始服务")
        let succeeded = query("""
              SELECT ts_text, kind, severity, COALESCE(accessing,''), COALESCE(responsible,''),
                     COALESCE(channel,''), log_count, duration, auth_value, COALESCE(reason,''),
                     COALESCE(accessing_path,''), COALESCE(responsible_path,''),
                     preflight, service, requesting
              FROM events WHERE ts_epoch >= ?\(Self.evidenceFilter(scope)) ORDER BY ts_epoch DESC
              """, [.double(since)]) { st in
            let kindRaw = Self.text(st, 1) ?? ""
            let kind = PrivacyKind(rawValue: kindRaw)
            let dur = sqlite3_column_type(st, 7) == SQLITE_NULL
                ? "" : String(format: "%.2f", sqlite3_column_double(st, 7))
            let event = PrivacyEvent(
                timestamp: Date(), service: Self.text(st, 13) ?? "",
                kind: kind ?? .other,
                // responsible / accessing 不只是给 CSV 列用的:判定
                // 「已授权的访问痕迹」需要它们。少了这两项,导出会把一条
                // 使用记录标成「否」,与界面自相矛盾。
                responsible: Self.proc(Self.text(st, 4), Self.text(st, 11)),
                accessing: Self.proc(Self.text(st, 3), Self.text(st, 10)),
                requesting: Self.text(st, 14),
                authValue: sqlite3_column_type(st, 8) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(st, 8)),
                preflight: Self.text(st, 12),
                duration: sqlite3_column_type(st, 7) == SQLITE_NULL
                    ? nil : sqlite3_column_double(st, 7))
            func esc(_ s: String) -> String {
                s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
                    ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    : s
            }
            rows.append([
                esc(Self.text(st, 0) ?? ""),
                esc(kind?.label ?? kindRaw),
                esc(kind?.category.label ?? ""),
                esc(Judge.severityLabel(Int(sqlite3_column_int64(st, 2)))),
                esc(Self.text(st, 3) ?? ""),
                esc(Self.text(st, 4) ?? ""),
                esc(Self.text(st, 5) ?? ""),
                String(sqlite3_column_int64(st, 6)),
                dur,
                sqlite3_column_type(st, 8) == SQLITE_NULL ? "" : String(sqlite3_column_int64(st, 8)),
                esc(Self.text(st, 9) ?? ""),
                esc(Self.text(st, 10) ?? ""),
                esc(Self.text(st, 11) ?? ""),
                esc(Self.text(st, 12) ?? ""),
                esc(event.phase.rawValue),
                esc(event.resultLabel),
                esc(event.actionPhrase),
                esc(event.accessConfidenceLabel ?? ""),
                esc(event.evidenceNote ?? ""),
                event.isUsageEvent ? "是" : "否",
                esc(event.service)
            ].joined(separator: ","))
        }
        guard succeeded else {
            throw NSError(domain: "BigBrother.Storage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: storageError ?? "无法读取访问记录"])
        }
        do {
            try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return rows.count - 1
        } catch {
            DBLog("导出失败: \(error.localizedDescription)")
            throw error
        }
    }


    /// 继承链审计:实际使用者 ≠ 授权主体
    func inheritanceReport(days: Int = 7, limit: Int = 10) -> [(owner: String, actor: String, n: Int)] {
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        var out: [(String, String, Int)] = []
        query("""
              SELECT COALESCE(responsible,'?') o, COALESCE(accessing,'?') a, COUNT(*) c
              FROM events
              WHERE ts_epoch >= ? AND responsible IS NOT NULL AND accessing <> responsible
              \(Self.visibleFilter)
              GROUP BY o, a ORDER BY c DESC LIMIT ?
              """, [.double(since), .int(Int64(limit))]) { st in
            out.append((Self.text(st, 0) ?? "?", Self.text(st, 1) ?? "?", Int(sqlite3_column_int64(st, 2))))
        }
        return out.map { (owner: $0.0, actor: $0.1, n: $0.2) }
    }

    // MARK: - SQLite 薄封装

    private static let eventColumns = """
        id, ts_epoch, service, kind, responsible, responsible_path,
        accessing, accessing_path, accessing_pid, requesting,
        auth_value, preflight, log_count, severity, reason, is_inherited, duration
        """

    private static func readEvent(_ st: OpaquePointer?) -> PrivacyEvent {
        let auth = sqlite3_column_int64(st, 10)
        return PrivacyEvent(
            id: sqlite3_column_int64(st, 0),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
            service: text(st, 2) ?? "",
            kind: PrivacyKind(rawValue: text(st, 3) ?? "") ?? .other,
            responsible: proc(text(st, 4), text(st, 5), -1),
            accessing: proc(text(st, 6), text(st, 7), Int(sqlite3_column_int64(st, 8))),
            requesting: text(st, 9),
            authValue: sqlite3_column_type(st, 10) == SQLITE_NULL || auth < 0 ? nil : Int(auth),
            preflight: text(st, 11), logCount: Int(sqlite3_column_int64(st, 12)),
            severity: Int(sqlite3_column_int64(st, 13)), reason: text(st, 14) ?? "",
            isInherited: sqlite3_column_int64(st, 15) != 0,
            duration: sqlite3_column_type(st, 16) == SQLITE_NULL ? nil : sqlite3_column_double(st, 16))
    }

    private enum Bind {
        case text(String?), int(Int64), double(Double)
    }

    @discardableResult
    private func run(_ sql: String, _ binds: [Bind]) -> Bool {
        guard let db else { recordFailure("记录文件未打开"); return false }
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &st, nil)
        guard rc == SQLITE_OK else {
            recordFailure("无法写入记录: \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_finalize(st)
            return false
        }
        defer { sqlite3_finalize(st) }
        bind(st, binds)
        let src = sqlite3_step(st)
        if src != SQLITE_DONE && src != SQLITE_ROW {
            recordFailure("无法写入记录: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private func scalar(_ sql: String, _ binds: [Bind]) -> Int {
        var result = 0
        query(sql, binds) { st in result = Int(sqlite3_column_int64(st, 0)) }
        return result
    }

    @discardableResult
    private func query(_ sql: String, _ binds: [Bind], _ each: (OpaquePointer?) -> Void) -> Bool {
        onQueue {
            guard let db else { recordFailure("记录文件未打开"); return false }
            var st: OpaquePointer?
            defer { sqlite3_finalize(st) }
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                recordFailure("无法读取记录: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            bind(st, binds)
            var rc = sqlite3_step(st)
            while rc == SQLITE_ROW {
                each(st)
                rc = sqlite3_step(st)
            }
            guard rc == SQLITE_DONE else {
                recordFailure("无法读取记录: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            return true
        }
    }

    private func bind(_ st: OpaquePointer?, _ binds: [Bind]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .text(let s):
                if let s { sqlite3_bind_text(st, idx, s, -1, SQLITE_TRANSIENT) }
                else { sqlite3_bind_null(st, idx) }
            case .int(let v):    sqlite3_bind_int64(st, idx, v)
            case .double(let v): sqlite3_bind_double(st, idx, v)
            }
        }
    }

    private static func text(_ st: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(st, col) else { return nil }
        return String(cString: c)
    }

    private static func proc(_ id: String?, _ path: String?, _ pid: Int = -1) -> ProcInfo? {
        guard let id else { return nil }
        return ProcInfo(identifier: id, pid: pid, path: path)
    }

    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
