import Foundation
import SQLite3

@main
enum StorageTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigBrother-storage-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try testAppleFiltering(in: directory)
        testIgnoreRules()
        try testPermissionEvents(in: directory)
        try testLegacyPermissionEvents(in: directory)
        try testEvidenceScopes(in: directory)
        try testAlreadyAuthorizedScreenAccess(in: directory)
        testCameraInUseChannel()
        try testLogStreamEOF(in: directory)
        testRecordingActivity()

        let database = directory.appendingPathComponent("records/events.db")
        let output = directory.appendingPathComponent("records.csv")
        let event = PrivacyEvent(
            timestamp: Date(), service: PrivacyKind.microphone.rawValue, kind: .microphone,
            accessing: ProcInfo(identifier: "test.app", pid: 100),
            authValue: 2, preflight: "no")

        let hourlyStore = EventStore(path: ":memory:")
        let alignedEnd = HourlyTimeline.end(after: Date())
        let hourlyStart = alignedEnd.addingTimeInterval(-24 * 3600)
        for (index, timestamp) in [hourlyStart, alignedEnd.addingTimeInterval(-3600), alignedEnd].enumerated() {
            let boundaryEvent = PrivacyEvent(
                timestamp: timestamp, service: PrivacyKind.microphone.rawValue, kind: .microphone,
                accessing: ProcInfo(identifier: "boundary.app.\(index)", pid: 200 + index),
                authValue: 2, preflight: "no")
            precondition(hourlyStore.insert(boundaryEvent).id > 0)
        }
        let hourlyCounts = hourlyStore.hourlyHistogram(endingAt: alignedEnd)
        precondition(hourlyCounts[0] == 1 && hourlyCounts[23] == 1 && hourlyCounts.reduce(0, +) == 2,
                     "Whole-hour boundaries must belong to the next bucket; exclude the axis end")
        print("PASS: natural-hour histogram boundaries match chart ticks")

        do {
            let store = EventStore(path: database.path)
            precondition(store.storageError == nil, "A writable database must initialize successfully")
            let inserted = store.insert(event)
            precondition(inserted.id > 0 && !inserted.merged)
            precondition(store.insert(event).merged, "Session folding must still work")
            precondition(store.totalCount() == 1)
            let histogramEnd = event.timestamp.addingTimeInterval(7.5 * 3600)
            let histogram = store.hourlyHistogram(endingAt: histogramEnd)
            precondition(histogram.count == 24 && histogram[16] == 1 && histogram.reduce(0, +) == 1)
            precondition(store.hourlyHistogram(endingAt: event.timestamp.addingTimeInterval(-60)).reduce(0, +) == 0,
                         "Histogram must not include events after its labeled end time")
            precondition(store.hourlyHistogram(endingAt: event.timestamp.addingTimeInterval(25 * 3600)).reduce(0, +) == 0)
            let exportedCount = try store.exportCSV(to: output.path)
            let exportedText = try String(contentsOf: output, encoding: .utf8)
            precondition(exportedCount == 1)
            precondition(exportedText.contains("test.app"))

            do {
                _ = try store.exportCSV(to: directory.path)
                preconditionFailure("Exporting over a directory must fail")
            } catch {
                print("PASS: export reports a write error instead of success")
            }
        }

        let reopened = EventStore(path: database.path)
        precondition(reopened.storageError == nil, "Re-running migrations must not report duplicate-column errors")
        precondition(reopened.totalCount() == 1, "Records must survive reopening")
        print("PASS: creation, session folding, export and repeated migrations")

        let deniedDirectory = directory.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: deniedDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: deniedDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedDirectory.path)
        }
        do {
            _ = try reopened.exportCSV(to: deniedDirectory.appendingPathComponent("records.csv").path)
            preconditionFailure("Exporting to a directory without write permission must fail")
        } catch {
            print("PASS: export propagates a file permission denial")
        }
        let denied = EventStore(path: deniedDirectory.appendingPathComponent("events.db").path)
        precondition(denied.storageError != nil, "A denied database must expose an error")
        precondition(denied.insert(event).id == 0, "A failed write must not return a successful event ID")
        do {
            _ = try denied.exportCSV(to: directory.appendingPathComponent("invalid.csv").path)
            preconditionFailure("A failed database read must not export an empty success-shaped file")
        } catch {
            precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("invalid.csv").path))
        }
        print("PASS: denied storage is visible and does not claim successful writes or exports")
    }

    private static func testAppleFiltering(in directory: URL) throws {
        let store = EventStore(path: directory.appendingPathComponent("apple-filter.db").path)
        let apple = ProcInfo(identifier: "com.apple.FaceTime", pid: 100)
        let appleHelper = ProcInfo(identifier: "com.apple.replayd", pid: 101)
        let wechat = ProcInfo(identifier: "com.tencent.xinWeChat", pid: 102)
        let now = Date()

        let appleOnly = [
            PrivacyEvent(timestamp: now, service: PrivacyKind.camera.rawValue, kind: .camera,
                         accessing: apple, requesting: "com.apple.tccd", authValue: 2),
            PrivacyEvent(timestamp: now, service: PrivacyKind.screenCapture.rawValue,
                         kind: .screenCapture, responsible: apple, accessing: appleHelper,
                         requesting: "com.apple.replayd", authValue: 2),
            PrivacyEvent(timestamp: now, service: PrivacyKind.microphone.rawValue,
                         kind: .microphone, responsible: apple, authValue: 2)
        ]
        for event in appleOnly {
            precondition(event.isAppleOnly)
            let result = store.insert(event)
            precondition(result.ignored && result.id == 0 && !result.merged)
        }
        precondition(store.totalCount() == 0 && store.storageError == nil)

        let thirdParty = [
            PrivacyEvent(timestamp: now, service: PrivacyKind.screenCapture.rawValue,
                         kind: .screenCapture, accessing: wechat,
                         requesting: "com.apple.replayd", authValue: 2, preflight: "no"),
            PrivacyEvent(timestamp: now, service: PrivacyKind.microphone.rawValue,
                         kind: .microphone, responsible: apple, accessing: wechat,
                         authValue: 2, preflight: "no"),
            PrivacyEvent(timestamp: now, service: PrivacyKind.camera.rawValue,
                         kind: .camera, responsible: wechat, accessing: appleHelper,
                         authValue: 2, preflight: "no"),
            PrivacyEvent(timestamp: now, service: "CLIPBOARD", kind: .clipboard,
                         accessing: ProcInfo(identifier: "local.bigbrother", pid: 103))
        ]
        for event in thirdParty {
            precondition(!event.isAppleOnly)
            let result = store.insert(event)
            precondition(result.id > 0 && !result.ignored)
        }
        precondition(store.totalCount() == 4 && store.todayTotal() == 4)
        precondition(store.todayCounts().reduce(0) { $0 + $1.1 } == 4)
        precondition(store.recentEvents().count == 4)
        precondition(store.recentEvents(kinds: [.screenCapture]).first?.accessing?.identifier
                     == "com.tencent.xinWeChat")
        precondition(store.todaySubjects().contains { $0.identifier == "com.tencent.xinWeChat" })

        let path = store.path
        var db: OpaquePointer?
        precondition(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, """
            INSERT INTO events(ts_epoch, ts_text, service, kind, accessing, accessing_pid)
            VALUES (\(now.timeIntervalSince1970), 'old', 'kTCCServiceCamera',
                    'kTCCServiceCamera', 'com.apple.FaceTime', 999);
            """, nil, nil, nil) == SQLITE_OK)
        let reopened = EventStore(path: path)
        precondition(reopened.storageError == nil && reopened.totalCount() == 4)
        precondition(reopened.recentEvents().count == 4)
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events", -1,
                                        &statement, nil) == SQLITE_OK)
        precondition(sqlite3_step(statement) == SQLITE_ROW
                     && sqlite3_column_int(statement, 0) == 5,
                     "Existing rows must not be deleted, even if excluded from usage reports")
        sqlite3_finalize(statement)
        precondition(reopened.insert(appleOnly[0]).ignored && reopened.totalCount() == 4)
        print("PASS: Apple-only events are not stored; third-party usage and old raw data remain")
    }

    private static func testIgnoreRules() {
        let suiteName = "BigBrother-ignore-test-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let store = EventStore(path: ":memory:")
        let monitor = Monitor(store: store, preferences: preferences)
        let rule = AppPermissionIgnoreRule(bundleIdentifier: "com.microsoft.VSCode", kind: .clipboard)
        monitor.addIgnoredAppPermission(bundleIdentifier: rule.bundleIdentifier, kind: rule.kind)

        let clipboard = PrivacyEvent(
            timestamp: Date(), service: "CLIPBOARD", kind: .clipboard,
            accessing: ProcInfo(identifier: "com.microsoft.VSCode", pid: 100))
        monitor.handle(clipboard)
        precondition(store.totalCount() == 0, "Matching app and permission must be ignored before storage")

        let microphone = PrivacyEvent(
            timestamp: Date(), service: PrivacyKind.microphone.rawValue, kind: .microphone,
            accessing: ProcInfo(identifier: "com.microsoft.VSCode", pid: 100),
            authValue: 2, preflight: "no")
        monitor.handle(microphone)
        precondition(store.totalCount() == 1, "An app rule must not suppress other permission types")

        let restored = Monitor(store: EventStore(path: ":memory:"), preferences: preferences)
        precondition(restored.ignoredAppPermissions.contains(rule), "Ignore rules must persist in preferences")
        monitor.removeIgnoredAppPermission(rule)
        monitor.handle(clipboard)
        precondition(store.totalCount() == 2, "Removing a rule must allow later matching events")
        print("PASS: app+permission ignore rules filter before storage, persist and can be removed")
    }

    private static func parsedEvent(kind: PrivacyKind = .fullDisk, preflight: String? = "yes",
                                    auth: Int? = 0, identifier: String = "local.bigbrother",
                                    requesting: String = "com.apple.sandboxd",
                                    pid: Int = 100,
                                    at timestamp: Date = Date()) -> PrivacyEvent {
        let parser = TCCParser()
        var events: [PrivacyEvent] = []
        parser.onEvent = { events.append($0) }
        let prefix = "\(EventStore.fmt.string(from: timestamp)) Df tccd[1:1] "
        parser.feed(prefix + "AUTHREQ_CTX: msgID=1.1, service=\(kind.rawValue)"
                    + (preflight.map { ", preflight=\($0)" } ?? ""))
        parser.feed(prefix + "AUTHREQ_ATTRIBUTION: msgID=1.1, attribution={accessing={TCCDProcess: identifier=\(identifier), pid=\(pid)}, requesting={TCCDProcess: identifier=\(requesting), pid=1}}")
        if let auth {
            parser.feed(prefix + "AUTHREQ_RESULT: msgID=1.1, authValue=\(auth)")
        } else {
            parser.flushStale(olderThan: -1)
        }
        precondition(events.count == 1)
        return events[0]
    }

    private static func testPermissionEvents(in directory: URL) throws {
        let check = parsedEvent()
        precondition(check.preflight == "yes" && check.authValue == 0)
        precondition(check.phase == .permissionCheck && check.authorization == .denied)
        precondition(check.actionPhrase == "检查了完全磁盘访问权限" && check.resultLabel == "还没授权")
        precondition(check.severity == 1 && !check.shouldAlert && !check.affectsThreatLevel)
        precondition(check.evidenceNote?.contains("不代表已读取文件") == true)
        // 没拿到授权的预检查才是「权限检查」:不计入使用统计。
        for identifier in ["local.bigbrother", "test.app", "bash", "com.apple.finder"] {
            for auth in [0, 1, -1, 99] {
                let event = parsedEvent(auth: auth, identifier: identifier)
                precondition(event.severity == 1 && !event.shouldAlert)
                precondition(event.phase == .permissionCheck && event.isDeniedCheck)
                precondition(!event.isUsageEvent && event.accessConfidenceLabel == "仅权限查询")
            }
        }
        // 已授权就不一样了 —— 系统仍在记录这次访问,必须计入使用。
        for auth in [2, 3] {
            for identifier in ["local.bigbrother", "test.app"] {
                let event = parsedEvent(auth: auth, identifier: identifier)
                precondition(event.isUsageEvent && event.isAuthorizedAccessTrace)
                precondition(event.accessConfidenceLabel == "已授权访问（未证实采集）")
                precondition(event.phase == .accessRequest)
                precondition(event.severity == PrivacyKind.fullDisk.baseSeverity)
            }
        }
        // 苹果自家组件之间的预检查既不是访问痕迹,也不算使用。
        let appleComponentTrace = parsedEvent(auth: 2, identifier: "com.apple.finder")
        precondition(!appleComponentTrace.isUsageEvent && !appleComponentTrace.isAuthorizedAccessTrace)
        precondition(appleComponentTrace.phase == .accessRequest)
        // 只有苹果自家组件之间的预检查才完全不算事件。
        let appleOnlyTrace = parsedEvent(auth: 2, identifier: "com.apple.finder",
                                         requesting: "com.apple.finder")
        precondition(!appleOnlyTrace.isAuthorizedAccessTrace && !appleOnlyTrace.isUsageEvent)
        precondition(parsedEvent(auth: 2).resultLabel == "已获授权")
        precondition(parsedEvent(auth: 3).resultLabel == "部分授权")
        precondition(parsedEvent(auth: nil).resultLabel == "结果未知")
        precondition(parsedEvent(preflight: "unexpected").phase == .unknown)
        precondition(parsedEvent(preflight: "unexpected").severity == 1)

        let denied = parsedEvent(preflight: "no")
        let allowed = parsedEvent(preflight: "no", auth: 2)
        precondition(denied.phase == .accessRequest && !denied.isUsageEvent)
        precondition(allowed.phase == .accessRequest && allowed.resultLabel == "已获系统授权")
        precondition(allowed.isConfirmedAccess && allowed.accessConfidenceLabel == "已证实访问")
        precondition(allowed.actionPhrase == "存在完全磁盘访问的访问记录" && allowed.evidenceNote != nil)
        precondition(denied.severity == allowed.severity && denied.severity == 3,
                     "Denial and development-style identifiers must not escalate risk")
        let photosDenied = parsedEvent(kind: .photos, preflight: "no", auth: 0)
        precondition(photosDenied.severity == 1 && !photosDenied.shouldAlert)
        let terminal = parsedEvent(preflight: "no", auth: 2, identifier: "bash")
        precondition(terminal.severity == 5 && terminal.shouldAlert)
        let missing = parsedEvent(preflight: "no", auth: nil)
        precondition(missing.authorization == .unknown && missing.resultLabel == "结果未知")
        for auth in [1, -1, 99] {
            precondition(parsedEvent(preflight: "no", auth: auth).authorization == .unknown)
        }

        var screen = parsedEvent(kind: .screenCapture, preflight: "no", auth: 2,
                                 requesting: "com.apple.replayd")
        precondition(screen.phase == .accessRequest && !screen.actionPhrase.contains("进行了"))
        screen.duration = 10
        precondition(screen.phase == .activity && screen.actionPhrase == "记录到屏幕录制活动")
        screen.authValue = 0
        precondition(screen.phase == .accessRequest, "A stale duration must not turn denial into activity")
        let clipboard = PrivacyEvent(timestamp: Date(), service: "CLIPBOARD", kind: .clipboard)
        precondition(clipboard.phase == .activity && clipboard.actionPhrase == "剪贴板内容发生了变化")

        // ── 落库与分桶 ────────────────────────────────────────────────
        //
        // 固定时间轴,让「哪些算独立访问、哪些会被折叠」完全确定。
        // 会话窗口是 2 秒,所以相邻事件至少隔 2.5 秒。
        let store = EventStore(path: ":memory:")
        let t0 = Date()
        func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }
        func moved(_ event: PrivacyEvent, to offset: TimeInterval) -> PrivacyEvent {
            var copy = event
            copy.timestamp = at(offset)
            return copy
        }
        // 每一步都显式记录期望的使用条数,避免"数不清的魔法数字"。
        func usageCount(_ label: String) -> Int {
            let n = store.totalCount()
            precondition(n == store.recentEvents().count,
                         "\(label): SQL 使用判定与模型判定必须一致")
            return n
        }
        // ① 权限检查(没拿到授权)、被拒、结果未知 —— 都不算使用,但都要入库。
        precondition(store.insert(moved(check, to: 0)).id > 0)
        precondition(store.insert(moved(denied, to: 2.5)).id > 0)
        precondition(store.insert(moved(missing, to: 5)).id > 0)
        precondition(usageCount("权限检查/被拒/未知") == 0)
        precondition(store.recentEvents(scope: .permissionChecks).count == 1)
        precondition(store.recentEvents(scope: .unconfirmed).count == 2)
        precondition(store.recentEvents(scope: .all).count == 3)

        // ② 已授权、但系统只做了预检查:算一次使用(访问痕迹)。
        let trace = moved(parsedEvent(auth: 2), to: 7.5)
        precondition(trace.isAuthorizedAccessTrace && !trace.isConfirmedAccess)
        precondition(store.insert(trace).id > 0)
        precondition(usageCount("已授权预检查") == 1)
        // 已授权的那条必须只出现在使用口径里,不能再落进权限检查。
        precondition(store.recentEvents(scope: .permissionChecks).count == 1,
                     "已授权的预检查不再算权限检查,只有未获授权的那条留着")

        // ③ preflight 为空 / 取值无法解读:阶段未知,不构成访问。
        precondition(store.insert(moved(parsedEvent(preflight: nil, auth: 2), to: 10)).id > 0)
        precondition(store.insert(moved(parsedEvent(preflight: "unexpected", auth: 2), to: 12.5)).id > 0)
        precondition(usageCount("阶段未知") == 1)

        // ④ 已证实的访问(系统这次不是预检查 + 已授权):各算一次。
        precondition(store.insert(moved(allowed, to: 15)).id > 0)
        precondition(usageCount("已证实访问") == 2)
        let limited = moved(parsedEvent(preflight: "no", auth: 3), to: 17.5)
        precondition(store.insert(limited).id > 0)
        precondition(usageCount("部分授权") == 3)
        var normalizedNo = moved(parsedEvent(preflight: "no", auth: 2), to: 20)
        normalizedNo.preflight = " \tNO\n"
        normalizedNo.accessing?.pid = 201
        precondition(normalizedNo.isConfirmedAccess, "空白与大小写必须被归一化")
        precondition(store.insert(normalizedNo).id > 0)
        precondition(usageCount("归一化 preflight") == 4)

        // ⑤ 同一次采集的重复日志必须继续折叠。
        precondition(store.insert(moved(allowed, to: 15.1)).merged,
                     "Only identical usage clues should fold")
        precondition(usageCount("折叠后") == 4)

        // 统计口径必须与上面的逐条判定一致。
        precondition(store.todayTotal() == 4 && store.todayCounts().reduce(0) { $0 + $1.1 } == 4)
        precondition(store.todaySubjects().first?.n == 4 && store.topActors().first?.1 == 4)
        precondition(store.deniedCount() == 0 && store.deniedEvents().isEmpty)
        precondition(store.highSeverityCount() == 0 && store.maxSeveritySince(seconds: 60) == 3)
        precondition(store.todayTotal() == 4)
        precondition(store.hourlyHistogram().reduce(0, +) == 4)
        precondition(store.recentEvents(scope: .all).count == 9)

        // ⑥ 归一化后的 preflight 不能因为多写了空白和大小写就变成"使用"。
        var normalizedCheck = moved(check, to: 25)
        normalizedCheck.preflight = " \tYES\n"
        normalizedCheck.accessing?.pid = 200
        normalizedCheck.severity = 5
        precondition(normalizedCheck.isPermissionCheck && !normalizedCheck.shouldAlert)
        precondition(normalizedCheck.normalizedPreflight == "yes")
        precondition(store.insert(normalizedCheck).id > 0)
        precondition(usageCount("归一化后的权限检查") == 4)
        precondition(store.highSeverityCount() == 0)
        precondition(store.recentEvents(minSeverity: 4).isEmpty)

        let export = directory.appendingPathComponent("permission-events.csv")
        let exportedCount = try store.exportCSV(to: export.path)
        precondition(exportedCount == 4)
        let text = try String(contentsOf: export, encoding: .utf8)
        precondition(text.contains("事件阶段,授权结果,事件说明,证据强度,证据说明"))
        precondition(!text.contains("权限检查") && !text.contains("系统拒绝"))
        precondition(text.contains("访问请求,已获系统授权,存在完全磁盘访问的访问记录"))
        precondition(text.contains("已授权访问（未证实采集）"),
                     "CSV 必须保留访问痕迹与已证实访问的区别")

        let monitor = Monitor(store: store)
        monitor.refresh()
        let deadline = Date().addingTimeInterval(3)
        while monitor.recent.count != 4 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(monitor.recent.count == 4 && monitor.todayTotal == 4 && monitor.threatLevel == 3,
                     "Approved usage clues must appear, including already-authorized ones")

        // ── 已授权之后的访问:这是本次改动的核心 ──────────────────────────
        // 旧版把「preflight=yes + 已授权」当成权限检查丢弃,于是微信这类
        // 已经拿到屏幕录制权限的 App,它每一次访问在界面上都不存在。
        let screenshotStore = EventStore(path: ":memory:")
        let screenshot = parsedEvent(kind: .screenCapture, preflight: "yes", auth: 2,
                                     identifier: "com.tencent.xinWeChat",
                                     requesting: "com.apple.replayd")
        precondition(screenshotStore.insert(screenshot).id > 0)
        precondition(screenshotStore.insert(parsedEvent(kind: .microphone, preflight: "yes",
                                                       auth: 2, identifier: "other.app")).id > 0)
        precondition(screenshot.phase == .accessRequest && screenshot.isUsageEvent)
        precondition(screenshot.isAuthorizedAccessTrace && !screenshot.isConfirmedAccess)
        precondition(screenshot.actionPhrase == "已授权状态下访问屏幕画面")
        precondition(screenshot.affectsThreatLevel,
                     "已授权的屏幕访问必须让眼睛变色,不能被当成权限检查")
        precondition(screenshot.severity == PrivacyKind.screenCapture.baseSeverity)
        precondition(!screenshot.shouldAlert,
                     "只是授权查询、没有证实采集时不该发通知")
        precondition(screenshot.evidenceNote?.contains("无法断言画面或声音被读取") == true)
        precondition(screenshotStore.recentEvents().count == 2
                     && screenshotStore.todayTotal() == 2,
                     "已授权访问必须进入使用统计")
        precondition(screenshotStore.recentEvents(scope: .permissionChecks).isEmpty,
                     "已授权的访问不该再出现在权限检查里")
        precondition(screenshotStore.todayCounts().first { $0.0 == .screenCapture }?.1 == 1,
                     "概览按类型也必须看到它")
        precondition(screenshotStore.todaySubjects().first { $0.identifier == "com.tencent.xinWeChat" }?.n == 1)
        var screenshotClue = parsedEvent(kind: .screenCapture, preflight: "no", auth: 2,
                                         identifier: "com.tencent.xinWeChat",
                                         requesting: "com.apple.replayd")
        // 拉到会话间隔之外,确保它是独立的一次采集(而不是被折叠进上面那条)。
        screenshotClue.timestamp = screenshot.timestamp.addingTimeInterval(3)
        precondition(screenshotStore.insert(screenshotClue).id > 0)
        precondition(screenshotStore.insert(parsedEvent(kind: .microphone, preflight: "no",
                                                       auth: 2, identifier: "other.app")).id > 0)
        precondition(screenshotStore.recentEvents().count == 4)
        precondition(screenshotClue.isConfirmedAccess && screenshotClue.accessConfidenceLabel == "已证实访问")
        precondition(screenshotStore.recentEvents(kinds: [.screenCapture]).count == 2,
                     "访问痕迹与已证实访问必须各占一行,不能互相折叠")
        precondition(screenshotStore.todayCounts().first { $0.0 == .screenCapture }?.1 == 2)
        precondition(screenshotStore.todayTotal() == 4)
        precondition(screenshotStore.todaySubjects().first { $0.identifier == "com.tencent.xinWeChat" }?.n == 2)
        precondition(screenshotStore.topActors().first { $0.0 == "com.tencent.xinWeChat" }?.1 == 2)
        precondition(screenshotStore.hourlyHistogram().reduce(0, +) == 4)
        precondition(screenshotStore.maxSeveritySince(seconds: 60) == 3)
        let screenshotMonitor = Monitor(store: screenshotStore)
        screenshotMonitor.refresh()
        let screenshotDeadline = Date().addingTimeInterval(3)
        while screenshotMonitor.recent.count != 4 && Date() < screenshotDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(screenshotMonitor.recent.count == 4 && screenshotMonitor.todayTotal == 4)
        precondition(screenshotMonitor.todayCounts.first { $0.kind == .screenCapture }?.n == 2)
        precondition(screenshotMonitor.threatLevel == 3)
        screenshotMonitor.drillInto(kind: .screenCapture)
        let drillDeadline = Date().addingTimeInterval(3)
        while screenshotMonitor.recent.count != 2 && Date() < drillDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(screenshotMonitor.recent.count == 2
                     && screenshotMonitor.recent.allSatisfy { $0.phase == .accessRequest })

        let crowded = EventStore(path: ":memory:")
        crowded.insert(screenshotClue)
        for index in 0..<401 {
            crowded.insert(PrivacyEvent(
                timestamp: Date().addingTimeInterval(Double(index + 1) * 0.001),
                service: PrivacyKind.microphone.rawValue, kind: .microphone,
                accessing: ProcInfo(identifier: "app.\(index)", pid: 200 + index),
                authValue: 2, preflight: "no"))
        }
        precondition(crowded.recentEvents(limit: 1, kinds: [.screenCapture]).first?.kind == .screenCapture,
                     "The type filter must apply before the record limit")
        precondition(crowded.recentEvents(limit: 1, kinds: [.other]).isEmpty)

        // 同一次采集里 preflight 不同的两条记录必须各占一行,时长只挂到
        // 「已证实访问」那一条上。
        let screenStore = EventStore(path: ":memory:")
        let confirmedCapture = parsedEvent(kind: .screenCapture, preflight: "no", auth: 2,
                                           requesting: "com.apple.replayd")
        let captureID = screenStore.insert(confirmedCapture).id
        var traceCapture = confirmedCapture
        traceCapture.preflight = "yes"
        traceCapture.timestamp = traceCapture.timestamp.addingTimeInterval(0.1)
        precondition(traceCapture.phase == .accessRequest && traceCapture.isAuthorizedAccessTrace)
        precondition(screenStore.insert(traceCapture).id > 0)
        _ = screenStore.annotateDuration(pid: 100, startedAt: confirmedCapture.timestamp.addingTimeInterval(0.1),
                                         seconds: 10)
        let screens = screenStore.recentEvents(scope: .all)
        precondition(screens.first { $0.id == captureID }?.phase == .activity)
        precondition(screens.first { $0.id == captureID }?.reason == "记录到屏幕录制活动")
        precondition(screens.first { $0.id != captureID }?.duration == nil,
                     "Duration must not attach to the authorized access trace")
        precondition(screens.filter { $0.duration != nil }.count == 1)
        precondition(screenStore.todayTotal() == 2 && screenStore.recentEvents().count == 2)
        precondition(screenStore.todayCounts().first?.1 == 2 && screenStore.todaySubjects().first?.n == 2)
        precondition(screenStore.deniedCount() == 0)
        precondition(screenStore.recordingDurations().count == 1,
                     "Only the confirmed capture may report a measured duration")
        let unknownCaptureStore = EventStore(path: ":memory:")
        precondition(unknownCaptureStore.insert(parsedEvent(
            kind: .screenCapture, preflight: "no", auth: nil,
            requesting: "com.apple.replayd")).id > 0)
        precondition(unknownCaptureStore.recentEvents().isEmpty,
                     "没有授权结果的屏幕请求不构成访问")
        precondition(unknownCaptureStore.annotateDuration(
            pid: 999, startedAt: Date(), seconds: 5) == nil)
        precondition(unknownCaptureStore.recentEvents().isEmpty,
                     "Unattributed recordings must not imply usage")
        precondition(unknownCaptureStore.annotateDuration(
            pid: 100, startedAt: Date(), seconds: 5) == nil)
        let promotedCapture = unknownCaptureStore.recentEvents().first
        precondition(promotedCapture?.phase == .activity && promotedCapture?.duration == 5,
                     "A matched recording is activity evidence even without an authorization result")
        precondition(unknownCaptureStore.todayTotal() == 1)
        let promotedStore = EventStore(path: ":memory:")
        precondition(promotedStore.insert(screenshot).id > 0)
        // 访问痕迹本身已经算访问,所以它一开始就在概览里 ——
        // 这正是「已授权也要记录」的含义。
        precondition(promotedStore.todayTotal() == 1)
        precondition(promotedStore.annotateDuration(
            pid: 100, startedAt: screenshot.timestamp.addingTimeInterval(0.1), seconds: 10) == nil)
        let promoted = promotedStore.recentEvents(scope: .activity)
        precondition(promoted.count == 1
                     && promoted[0].duration == 10
                     && promoted[0].reason == "记录到屏幕录制活动",
                     "A duration log must upgrade the authorized access row in place")
        precondition(promoted[0].preflight == "yes",
                     "The original preflight evidence must not be rewritten")
        precondition(promotedStore.todayTotal() == 1, "Upgrading must not duplicate the row")
        precondition(promotedStore.recordingDurations().count == 1,
                     "The measured duration must be reported")
        precondition(promotedStore.annotateDuration(
            pid: 100, startedAt: screenshot.timestamp.addingTimeInterval(0.1), seconds: 10) == nil)
        precondition(promotedStore.totalCount() == 1, "Repeated lifecycle logs must not duplicate activity")

        let recordingParser = TCCParser()
        var completed: [(pid: Int, startedAt: Date, seconds: Double)] = []
        recordingParser.onDuration = { completed.append(($0, $1, $2)) }
        let startedAt = Date()
        let startLine = "\(EventStore.fmt.string(from: startedAt)) Df WeChat[100:1] recordingOutputDidStartRecording"
        let stopLine = "\(EventStore.fmt.string(from: startedAt.addingTimeInterval(3))) Df WeChat[100:1] recordingOutputDidFinishRecording"
        for _ in 0..<2 {
            recordingParser.feed(startLine)
            recordingParser.feed(stopLine)
        }
        precondition(completed.count == 1 && completed[0].pid == 100
                     && completed[0].seconds == 3,
                     "Overlapping log polls must not duplicate recording completion")

        let locationParser = LocationParser()
        var locations: [PrivacyEvent] = []
        locationParser.onEvent = { locations.append($0) }
        let prefix = "\(EventStore.fmt.string(from: Date())) Df locationd[382:1a03a8] "
        let chrome = #""Client":"D2ED7D43-4FBF-4D73-A682-6B2649A00689:icom.google.Chrome:""#
        // 旧版认的那条标记:它只算授权上下文,与"有没有拿到坐标"无关。
        locationParser.feed(prefix + #"{"msg":"computing freshAuthorizationContext", "# +
                            chrome + #", "InUseLevel":"kCLClientInUseLevelNotInUse"}"#)
        precondition(locations.isEmpty,
                     "授权上下文计算不是使用证据 —— 旧版正是靠它漏掉了真实定位")
        // 真实使用:授权通过 → 投递坐标 → 系统状态栏开始显示
        locationParser.feed(prefix + #"{"msg":"client authorized for location; starting shortly", "# +
                            chrome + #", "DC":"0x7a296d9680"}"#)
        locationParser.feed(prefix + #"{"msg":"Sending location to client", "# + chrome +
                            #", "DC":"0x7a296d9680", "location":{"location":"<redacted>"}, "desiredAccuracy":"100.000000"}"#)
        locationParser.feed(prefix + "{\"msg\":\"#SystemStatus Publishing receiving location interval begin\", "
                            + chrome + ", \"AttributionUUID\":\"D2ED7D43\"}")
        locationParser.flush()
        precondition(locations.count == 1,
                     "同一毫秒的三条证据只算一次访问,得到 \(locations.count)")
        let location = locations[0]
        precondition(location.phase == .activity && location.isUsageEvent)
        precondition(location.service == "LOCATION_IN_USE" && location.kind == .location)
        precondition(location.accessing?.identifier == "com.google.Chrome")
        precondition(location.actionPhrase == "系统向它提供了位置信息")
        precondition(location.evidenceNote?.contains("不含坐标") == true)
        precondition(location.reason.contains("系统开始向该客户端提供定位"))
        // 持续供数会每秒打一条日志:同一毫秒的合并成一条,限流窗口内不再新增
        let later = EventStore.fmt.string(from: Date().addingTimeInterval(1))
        // 先让上面那一毫秒的三条证据定稿(采集管线会在读完一批日志后 flush)
        locationParser.flush()
        precondition(locations.count == 1)
        for _ in 0..<50 {
            locationParser.feed(later + " Df locationd[382:1a03a8] " +
                                #"{"msg":"Sending location to client", "# + chrome +
                                #", "DC":"0x7a296d9680", "notification":"kNotificationLocation"}"#)
        }
        locationParser.flush()
        precondition(locations.count == 1, "限流窗口内不重复记同一个客户端")
        // 跨过限流窗口(20 秒)后,新的一次使用要重新记录
        let next = EventStore.fmt.string(from: Date().addingTimeInterval(25))
        locationParser.feed(next + " Df locationd[382:1a03a8] " +
                            #"{"msg":"Sending location to client", "# + chrome + #"}"#)
        locationParser.flush()
        precondition(locations.count == 2, "跨过限流窗口的新一次使用必须记录")
        // 苹果自己的位置组件(CoreParsec / Routine.bundle / CoreWLAN…)不是 App,
        // 不进记录 —— 否则真正要看的 App 会被这些噪音挤下去。
        let routine = #""Client":"root:p\134/System\134/Library\134/LocationBundles\134/Routine.bundle:""#
        locationParser.feed(prefix + #"{"msg":"Sending location to client", "# + routine + #"}"#)
        locationParser.flush()
        precondition(locations.count == 2 && locations.allSatisfy { $0.severity == 3 },
                     "系统组件不该出现在记录里")
        precondition(locationParser.skippedSystemClients == 1,
                     "但要知道它们发生过")
        precondition(promotedStore.insert(locations[0]).id > 0)
        precondition(promotedStore.todayCounts().first { $0.0 == .location }?.1 == 1)
        precondition(screenStore.storageError == nil && store.storageError == nil)

        // 旧版把苹果自己的位置组件当成"访问者"记了下来(CoreParsec.framework 等)。
        // 这些行留在库里,但不能继续出现在记录和统计里。
        let legacy = EventStore(path: directory.appendingPathComponent("legacy-location.db").path)
        let systemLocation = PrivacyEvent(
            timestamp: Date(), service: "LOCATION_IN_USE", kind: .location,
            accessing: ProcInfo(identifier: "CoreParsec.framework", pid: -1,
                                path: "/System/Library/PrivateFrameworks/CoreParsec.framework"),
            requesting: "com.apple.locationd", severity: 3, reason: "Apple 系统位置组件")
        precondition(systemLocation.accessing?.isSystemLocationComponent == true)
        precondition(!systemLocation.isUsageEvent, "系统位置组件不是 App,不算使用")
        precondition(legacy.insert(systemLocation).id > 0, "历史行仍然写入,便于审计")
        let realLocation = PrivacyEvent(
            timestamp: Date(), service: "LOCATION_IN_USE", kind: .location,
            accessing: ProcInfo(identifier: "com.tencent.xinWeChat", pid: -1),
            requesting: "com.apple.locationd", severity: 3, reason: "App 定位使用")
        precondition(legacy.insert(realLocation).id > 0)
        precondition(legacy.recentEvents().count == 1
                     && legacy.recentEvents().first?.accessing?.identifier == "com.tencent.xinWeChat",
                     "只有真正的 App 出现在记录里")
        precondition(legacy.todayTotal() == 1 && legacy.totalCount() == 1)
        precondition(legacy.recentEvents(scope: .all).count == 2,
                     "系统组件的行不删除,仍可在全部证据里查到")
        precondition(legacy.recentEvents(scope: .unconfirmed).isEmpty,
                     "系统组件不是 App,不该落进未确认口径")
        print("PASS: usage clues, actual recording evidence, exclusions, statistics and export")
    }

    private static func testEvidenceScopes(in directory: URL) throws {
        let path = directory.appendingPathComponent("evidence.db").path
        do {
            let store = EventStore(path: path)
            let check = parsedEvent(kind: .camera, auth: 2, identifier: "chat.app")
            let allowed = parsedEvent(kind: .camera, preflight: "no", auth: 2, identifier: "chat.app")
            let denied = parsedEvent(kind: .camera, preflight: "no", auth: 0, identifier: "chat.app")
            let unknown = parsedEvent(kind: .microphone, preflight: nil, auth: nil, identifier: "chat.app")
            var unsupported = allowed
            unsupported.kind = .other
            unsupported.service = "kTCCServiceFutureSensitiveData"
            for event in [check, allowed, denied, unknown, unsupported] {
                precondition(store.insert(event).id > 0)
            }
            precondition(store.recentEvents(scope: .all).count == 5)
            precondition(store.recentEvents(scope: .permissionChecks).isEmpty,
                         "已授权的预检查属于访问,不再算权限检查")
            precondition(store.recentEvents(scope: .unconfirmed).count == 2,
                         "只有被拒与结果未知的请求留在未确认里")
            precondition(store.recentEvents(scope: .activity).isEmpty)
            precondition(store.recentEvents().count == 3 && store.todayTotal() == 3,
                         "已授权的预检查、preflight=no 的调用、以及未列举的服务都计入使用")
            precondition(check.isUsageEvent && check.isAuthorizedAccessTrace)
            precondition(store.recentEvents(onlyDenied: true, scope: .all).count == 1)
            precondition(store.recentEvents(kinds: [.other], scope: .all).first?.service == unsupported.service)
            let csv = directory.appendingPathComponent("all-evidence.csv")
            let count = try store.exportCSV(to: csv.path, scope: .all)
            let text = try String(contentsOf: csv)
            precondition(count == 5 && text.contains("系统拒绝"))
            precondition(text.contains("计入使用统计") && text.contains(unsupported.service))
            precondition(text.contains("已授权访问（未证实采集）"), "CSV 必须保留证据强度")
            let monitor = Monitor(store: store)
            monitor.filter.scope = .unconfirmed
            monitor.refresh()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                if monitor.recent.count == 2 { break }
            }
            precondition(monitor.recent.count == 2
                         && monitor.recent.allSatisfy { !$0.isUsageEvent },
                         "未确认口径只包含被拒与结果未知")
            precondition(monitor.todayTotal == 3 && monitor.threatLevel == allowed.severity)
        }
        let reopened = EventStore(path: path)
        precondition(reopened.recentEvents(scope: .all).count == 5 && reopened.totalCount() == 3)
        print("PASS: all evidence persists; authorized access counts, denials stay outside usage")
    }

    // MARK: 已授权之后仍然要记录(实测形态)

    /// 用真实 macOS 27 日志的形态回归两个错误认知:
    ///
    ///   1. `preflight=yes` ≠「没访问」。已授权的 App 每次访问都会打这条
    ///      授权查询(实测微信每 ~30 秒一组,requesting=com.apple.replayd),
    ///      旧版把它归为「权限检查」并排除出统计 —— 于是用户界面上完全看不到。
    ///   2. 同一次采集里 preflight=yes / preflight=no 必须各占一行,
    ///      否则「已证实访问」会被降级成「访问痕迹」。
    private static func testAlreadyAuthorizedScreenAccess(in directory: URL) throws {
        let parser = TCCParser()
        var events: [PrivacyEvent] = []
        parser.onEvent = { events.append($0) }

        let t0 = Date()
        let fmt = EventStore.fmt
        func ctx(_ offset: TimeInterval, _ msgID: String, _ preflight: String) -> String {
            "\(fmt.string(from: t0.addingTimeInterval(offset))) Df tccd[406:17c059] "
                + "[com.apple.TCC:access] AUTHREQ_CTX: msgID=\(msgID), "
                + "function=TCCAccessRequest, service=kTCCServiceScreenCapture, "
                + "preflight=\(preflight), query=1, client_dict=(null), daemon_dict=<private>"
        }
        func attr(_ offset: TimeInterval, _ msgID: String) -> String {
            "\(fmt.string(from: t0.addingTimeInterval(offset))) Df tccd[406:17c059] "
                + "[com.apple.TCC:access] AUTHREQ_ATTRIBUTION: msgID=\(msgID), attribution={"
                + "accessing={TCCDProcess: identifier=com.tencent.xinWeChat, pid=32771, "
                + "auid=501, euid=501, binary_path=/Applications/WeChat.app/Contents/MacOS/WeChat}, "
                + "requesting={TCCDProcess: identifier=com.apple.replayd, pid=703, "
                + "auid=501, euid=501, binary_path=/usr/libexec/replayd}, },"
        }
        func result(_ offset: TimeInterval, _ msgID: String, _ value: Int) -> String {
            "\(fmt.string(from: t0.addingTimeInterval(offset))) Df tccd[406:17c059] "
                + "[com.apple.TCC:access] AUTHREQ_RESULT: msgID=\(msgID), authValue=\(value), "
                + "authReason=4, authVersion=1, desired_auth=0, error=(null),"
        }

        // ① 已授权状态下的四次授权查询(微信实测形态)。
        for (index, msgID) in ["703.828", "703.829", "703.830", "703.831"].enumerated() {
            let offset = Double(index) * 0.04
            parser.feed(ctx(offset, msgID, "yes"))
            parser.feed(attr(offset + 0.002, msgID))
            parser.feed(result(offset + 0.01, msgID, 2))
        }
        // ② 紧接着系统真正发起采集请求(preflight=no)。
        parser.feed(ctx(1.0, "703.832", "no"))
        parser.feed(attr(1.001, "703.832"))
        parser.feed(result(1.005, "703.832", 2))
        parser.flushStale(olderThan: -1)

        // 解析器逐条上报(4 条预检查 + 1 条真实请求);折叠由存储层负责。
        precondition(events.count == 5, "解析出 4 条预检查 + 1 条真实请求,得到 \(events.count)")
        let traces = events.filter { $0.isAuthorizedAccessTrace }
        let captures = events.filter { $0.isConfirmedAccess }
        precondition(traces.count == 4 && captures.count == 1)
        precondition(Set(traces.map(\.sessionKey)).count == 1,
                     "同一次采集的四条预检查必须折叠成一行")
        let trace = traces[0]
        let capture = captures[0]
        precondition(trace.sessionKey != capture.sessionKey,
                     "preflight 不同就不能折叠成同一行")
        precondition(trace.isUsageEvent,
                     "已授权的预检查必须计入使用 —— 这正是旧版丢掉的那类记录")
        precondition(trace.accessConfidenceLabel == "已授权访问（未证实采集）")
        precondition(trace.actionPhrase == "已授权状态下访问屏幕画面")
        precondition(trace.phase == .accessRequest)
        precondition(capture.accessConfidenceLabel == "已证实访问")
        precondition(capture.channel == .replayd && capture.isUsageEvent)

        let store = EventStore(path: directory.appendingPathComponent("authorized-screen.db").path)
        for event in events { precondition(store.insert(event).id > 0) }
        precondition(store.recentEvents(scope: .all).count == 2,
                     "四条预检查折叠成一行,加上真实请求共两行")
        precondition(store.recentEvents().count == 2)
        precondition(store.recentEvents(scope: .permissionChecks).isEmpty,
                     "已授权的预检查不该出现在权限检查口径里")
        precondition(store.todayCounts().first { $0.0 == .screenCapture }?.1 == 2)
        precondition(store.todaySubjects().first { $0.identifier == "com.tencent.xinWeChat" }?.n == 2)

        // ③ 结束日志补时长:只能落在「已证实访问」那一条上。
        precondition(store.annotateDuration(pid: 32771, startedAt: t0.addingTimeInterval(1.0),
                                            seconds: 12.5) == nil)
        let refreshed = store.recentEvents(scope: .all)
        precondition(refreshed.filter { $0.duration != nil }.count == 1)
        precondition(refreshed.first { $0.isConfirmedAccess }?.duration == 12.5)
        precondition(refreshed.first { $0.isAuthorizedAccessTrace }?.duration == nil,
                     "访问痕迹不该被补上时长")
        print("PASS: already-authorized screen access is recorded (trace + confirmed)")
    }

    /// 摄像头使用通道。
    ///
    /// 起因:实测一次微信视频通话,摄像头真的开了(Control Center 标记
    /// com.tencent.xinWeChat 摄像头活跃、cameracaptured 配置了 1920x1440 流),
    /// 而 tccd **一条 kTCCServiceCamera 审计都没有** —— 只有麦克风的 AUTHREQ。
    /// 只靠 TCC 采集必然漏报,所以补了 Control Center 这条线。
    private static func testCameraInUseChannel() {
        let parser = CameraParser()
        var events: [PrivacyEvent] = []
        parser.onEvent = { events.append($0) }

        let t0 = Date()
        func line(_ offset: TimeInterval, _ bundle: String, module: String = "avccm_VideoEffectsModuleShouldBeShownForBundleID") -> String {
            "\(EventStore.fmt.string(from: t0.addingTimeInterval(offset))) Df ControlCenter[659:1b8d01] "
                + "[com.apple.cameracapture:] <<<< AVControlCenterModules >>>> "
                + "\(module): \(bundle) active:1"
        }

        // 摄像头活跃:同一秒里 Control Center 会重发几十条,只记一条
        for i in 0..<40 {
            parser.feed(line(Double(i) * 0.001, "com.tencent.xinWeChat"))
        }
        // 麦克风模块不是摄像头,不能张冠李戴
        parser.feed(line(0.5, "com.tencent.xinWeChat",
                         module: "AVControlCenterMicrophoneModuleShouldBeShownForBundleID"))
        // 系统自己的采集组件不是 App
        parser.feed(line(0.6, "com.apple.cameracaptured"))
        // 没有 active:1 的「开始显示」不是正在使用
        parser.feed("\(EventStore.fmt.string(from: t0.addingTimeInterval(0.7))) Df ControlCenter[659:1b8d01] "
                    + "[com.apple.cameracapture:] <<<< AVControlCenterModules >>>> "
                    + "avccm_VideoEffectsModuleShouldBeShownForBundleID: com.evil.app")

        precondition(events.count == 1, "一次摄像头会话只记一条,得到 \(events.count)")
        let camera = events[0]
        precondition(camera.kind == .camera && camera.service == "CAMERA_IN_USE")
        precondition(camera.phase == .activity && camera.isUsageEvent && camera.affectsThreatLevel)
        precondition(camera.accessing?.identifier == "com.tencent.xinWeChat")
        precondition(camera.actionPhrase == "系统报告摄像头正在被使用")
        precondition(camera.evidenceNote?.contains("不含画面") == true)
        precondition(parser.skippedSystemClients == 1)

        // 限流窗口内的重复不再记;跨窗口的新会话要记
        parser.feed(line(5, "com.tencent.xinWeChat"))
        precondition(events.count == 1, "限流窗口内不重复记录")
        parser.feed(line(30, "com.tencent.xinWeChat"))
        precondition(events.count == 2, "跨过限流窗口的新一次使用必须记录")

        // 摄像头不再依赖 TCC:即使一条 AUTHREQ 都没有,也要出现在概览里
        let store = EventStore(path: ":memory:")
        for e in events { precondition(store.insert(e).id > 0) }
        precondition(store.recentEvents().count == 2)
        precondition(store.todayCounts().first { $0.0 == .camera }?.1 == 2)
        precondition(store.todaySubjects().first { $0.identifier == "com.tencent.xinWeChat" }?.n == 2)
        print("PASS: camera-in-use is recorded even when tccd logs nothing")
    }

    /// 实时流子进程退出(管道 EOF)后必须收摊。
    ///
    /// 踩过的坑:管道写端关闭后 `readabilityHandler` 会以极高频率反复触发,
    /// 每次都返回空数据;旧写法拿到空数据就 `return`,于是变成烧满一个核的
    /// 空转循环 —— 实测应用因此跑到 199% CPU,四条 fd 监控线程里
    /// 1518/1616 全耗在这个回调上,而子进程一个都不剩。
    private static func testLogStreamEOF(in directory: URL) throws {
        precondition(LogStreamer.isEndOfFile(Data()), "空数据就是 EOF")
        precondition(!LogStreamer.isEndOfFile(Data([0x41])), "有数据不是 EOF")

        let streamer = LogStreamer()
        // 用一个立刻退出的子进程模拟 log stream 挂掉
        streamer.streamExecutable = URL(fileURLWithPath: "/bin/sh")
        streamer.streamArguments = ["-c", "printf 'hello\\n'; exit 0"]

        var lines: [String] = []
        var statuses: [String] = []
        streamer.onLine = { lines.append($0) }
        streamer.onStatus = { statuses.append($0) }

        streamer.start()
        // 等子进程退出、EOF 被处理
        let deadline = Date().addingTimeInterval(8)
        while streamer.streamExits == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        precondition(streamer.streamExits == 1,
                     "子进程退出后必须识别为 EOF 并收摊(实际 \(streamer.streamExits))")
        precondition(lines.contains("hello"), "退出前读到的那行不能丢: \(lines)")
        precondition(streamer.mode == .poll, "退出后要切到轮询兜底,不能就此失联")
        precondition(statuses.contains { $0.contains("轮询") },
                     "要明确告诉用户已切轮询: \(statuses)")
        streamer.stop()
        print("PASS: stream EOF is reclaimed instead of spinning a core")
    }

    private static func testRecordingActivity() {
        let store = EventStore(path: ":memory:")
        let parser = TCCParser()
        let actor = ProcInfo(identifier: "chat.app", pid: 400)
        var starts = 0
        parser.onRecordingStart = { pid, timestamp, name in
            precondition(name == "Chat-App Helper")
            starts += 1
            precondition(store.recordingStarted(pid: pid, at: timestamp, actor: actor) != nil)
        }
        parser.onDuration = { pid, timestamp, seconds in
            _ = store.annotateDuration(pid: pid, startedAt: timestamp, seconds: seconds)
        }
        let now = Date()
        let start = "\(EventStore.fmt.string(from: now)) Df Chat-App Helper[400:1] recordingOutputDidStartRecording"
        let stop = "\(EventStore.fmt.string(from: now.addingTimeInterval(30))) Df Chat-App Helper[400:1] recordingOutputDidFinishRecording"
        parser.feed(start)
        precondition(starts == 1 && store.todayTotal() == 1,
                     "Activity must persist at start without a TCC request or a stop log")
        let event = store.recentEvents(scope: .activity)[0]
        precondition(event.authorization == .unknown && event.duration == nil && event.isUsageEvent)
        precondition(store.recordingStarted(pid: 400, at: event.timestamp, actor: actor) == nil)
        parser.feed(start)
        parser.feed(stop)
        parser.feed(start)
        parser.feed(stop)
        precondition(starts == 1 && store.recentEvents()[0].duration == 30)
        precondition(store.todayTotal() == 1 && store.recordingDurations().count == 1)
        precondition(store.recordingStarted(pid: 401, at: now,
                     actor: ProcInfo(identifier: "com.apple.FaceTime", pid: 401)) == nil)
        precondition(store.recordingStarted(pid: 402, at: now, actor: nil) == nil)
        let checkStore = EventStore(path: ":memory:")
        let check = parsedEvent(kind: .screenCapture, preflight: "yes", auth: 0,
                                identifier: "chat.app", requesting: "com.apple.replayd")
        checkStore.insert(check)
        let recording = checkStore.recordingStarted(pid: 100, at: check.timestamp, actor: nil)
        precondition(recording?.phase == .activity && recording?.authorization == .unknown)
        precondition(checkStore.recentEvents(scope: .permissionChecks).count == 1
                     && checkStore.recentEvents(scope: .activity).count == 1,
                     "Independent recording evidence must not be gated by an earlier denial")
        precondition(checkStore.recentEvents(scope: .all).count == 2)
        precondition(checkStore.todayTotal() == 1, "纯检查不计入使用统计")

        let ignoredRecordingStore = EventStore(path: ":memory:")
        let ignoredRecording = ignoredRecordingStore.recordingStarted(
            pid: 500, at: now, actor: ProcInfo(identifier: "com.microsoft.VSCode", pid: 500),
            excluding: { AppPermissionIgnoreRule(bundleIdentifier: "com.microsoft.VSCode",
                                                   kind: .screenCapture).matches($0) })
        precondition(ignoredRecording == nil && ignoredRecordingStore.totalCount() == 0,
                     "Ignore rules must also filter synthesized recording events before storage")

        let reordered = TCCParser()
        var events: [PrivacyEvent] = []
        reordered.onEvent = { events.append($0) }
        let prefix = "\(EventStore.fmt.string(from: now)) Df tccd[1:1] "
        reordered.feed(prefix + "AUTHREQ_RESULT: msgID=9.1, authValue=2")
        reordered.feed(prefix + "AUTHREQ_ATTRIBUTION: msgID=9.1, attribution={accessing={TCCDProcess: identifier=chat.app, pid=400}}")
        reordered.feed(prefix + "AUTHREQ_CTX: msgID=9.1, service=kTCCServiceCamera, preflight=no")
        precondition(events.count == 1 && events[0].isUsageEvent,
                     "Out-of-order authorization logs must not lose authorized access clues")
        print("PASS: screen start is recorded independently; duration, replay and reordered TCC logs work")
    }

    private static func testLegacyPermissionEvents(in directory: URL) throws {
        let path = directory.appendingPathComponent("legacy-events.db").path
        do {
            let store = EventStore(path: path)
            precondition(store.storageError == nil)
        }
        var database: OpaquePointer?
        precondition(sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        precondition(sqlite3_exec(database, """
            PRAGMA user_version = 0;
            WITH RECURSIVE seq(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 500)
            INSERT INTO events(ts_epoch, ts_text, service, kind, accessing,
                               accessing_pid, auth_value, preflight, severity)
            SELECT \(Date().timeIntervalSince1970), 'old',
                   'kTCCServiceSystemPolicyAllFiles', 'kTCCServiceSystemPolicyAllFiles',
                   'local.bigbrother', n + 100, 0, 'yes', 5 FROM seq;
            INSERT INTO events(ts_epoch, ts_text, service, kind, accessing,
                               accessing_pid, auth_value, preflight, severity)
            VALUES (\(Date().timeIntervalSince1970), 'old',
                    'kTCCServiceSystemPolicyAllFiles', 'kTCCServiceSystemPolicyAllFiles',
                    'local.bigbrother', 1000, NULL, 'no', 4),
                   (\(Date().timeIntervalSince1970), 'old',
                    'kTCCServiceSystemPolicyAllFiles', 'kTCCServiceSystemPolicyAllFiles',
                    'local.bigbrother', 1001, 2, 'no', 4);
            """, nil, nil, nil) == SQLITE_OK)
        let migrated = EventStore(path: path)
        precondition(migrated.storageError == nil && migrated.totalCount() == 1)
        let records = migrated.recentEvents(limit: 600)
        precondition(records.count == 1 && records[0].authorization == .allowed
                     && records[0].severity == 3)
        precondition(migrated.todayTotal() == 1 && migrated.deniedCount() == 0)
        precondition(migrated.highSeverityCount() == 0 && migrated.maxSeveritySince(seconds: 60) == 3)
        var rawCount: OpaquePointer?
        precondition(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM events", -1,
                                        &rawCount, nil) == SQLITE_OK)
        precondition(sqlite3_step(rawCount) == SQLITE_ROW
                     && sqlite3_column_int(rawCount, 0) == 503,
                     "Historical checks must be hidden, not silently deleted")
        sqlite3_finalize(rawCount)
        let reopened = EventStore(path: path)
        precondition(reopened.storageError == nil && reopened.totalCount() == 1)
        precondition(reopened.recentEvents().first?.severity == 3)
        print("PASS: legacy checks remain on disk but never count as usage")
    }
}
