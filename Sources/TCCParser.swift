import Foundation

/// 把 `log stream` 的输出解析成结构化的隐私事件。
///
/// tccd 为每一次权限访问打 4 类日志,靠 msgID 关联:
///   AUTHREQ_CTX          → 时间 / 服务 / 是否 preflight
///   AUTHREQ_ATTRIBUTION  → 归因链三要素(授权主体 / 实际执行者 / 请求通道)
///   AUTHREQ_SUBJECT      → 责任主体标识
///   AUTHREQ_RESULT       → 授权结果
///
/// 只有 CTX + ATTRIBUTION 齐备的事件才有产品价值;缺 accessing 的是
/// WindowServer 内部检查,直接丢弃。
///
/// ⚠️ `preflight=yes` **不是**「没访问」的同义词:实测 macOS 27 上真实录屏
/// 与真实开摄像头都会同时产生 preflight=no 与 preflight=yes 两种请求。
/// 解析层原样保留这个字段,判定层(`PrivacyEvent` / `Judge`)才决定它算
/// 「已证实访问」还是「已授权的访问痕迹」。
final class TCCParser {

    private struct Partial {
        var timestamp: Date
        var raw: String
        var service: String?
        var preflight: String?
        var responsible: ProcInfo?
        var accessing: ProcInfo?
        var requesting: ProcInfo?
        var authValue: Int?
        var hasAttribution = false
        var firstSeen = Date()
    }

    private var pending: [String: Partial] = [:]
    private let lock = NSRecursiveLock()

    /// 尚未凑齐的事件数(诊断用)
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// 已处理过的 msgID。
    ///
    /// 轮询兜底的回看窗口(25s)大于轮询周期(8s),同一条事件必然被读到多次;
    /// 没有这层去重就会成倍重复入库。
    private var seenMsgIDs: [String: Date] = [:]
    private var lastSweep = Date()

    private func alreadySeen(_ msgID: String) -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastSweep) > 30 {
            seenMsgIDs = seenMsgIDs.filter { now.timeIntervalSince($0.value) < 240 }
            lastSweep = now
        }
        if seenMsgIDs[msgID] != nil { return true }
        seenMsgIDs[msgID] = now
        return false
    }

    /// 每产出一条完整、且属于我们关心的类型的隐私事件时回调
    var onEvent: ((PrivacyEvent) -> Void)?

    /// 持续录屏结束时回调 (访问者 pid, 时长秒)。
    ///
    /// TCC 日志只在**开流时**检查权限 —— 实测一次 10.04 秒的录屏,
    /// TCC 检查只覆盖了前 87 毫秒(0.87%)。时长必须从采集进程自己的
    /// ScreenCaptureKit 日志里取:
    ///   -[SCRecordingOutput recordingOutputDidStartRecording:]
    ///   -[SCRecordingOutput recordingOutputDidFinishRecording:]
    var onDuration: ((Int, Date, Double) -> Void)?
    var onRecordingStart: ((Int, Date, String) -> Void)?

    /// pid → 录制开始时间
    private var recordingSince: [Int: Date] = [:]
    private var reportedRecordings: [String: Date] = [:]
    private var reportedStarts: [String: Date] = [:]

    /// 系统中介者。attribution 里缺少 accessing、而 requesting 是其中之一时,
    /// 才是真正该丢弃的内部检查。
    static let mediators: Set<String> = [
        "com.apple.WindowServer",
        "com.apple.sandboxd",
        "com.apple.tccd",
    ]

    /// 定点调试:设 PS_WATCH=msgID 后只打印该 msgID 的处理过程
    private static let watchID = ProcessInfo.processInfo.environment["PS_WATCH"]

    private func watch(_ what: String, msgID: String) {
        guard let w = Self.watchID, w == msgID else { return }
        FileHandle.standardError.write("  [watch \(msgID)] \(what)\n".data(using: .utf8)!)
    }

    // MARK: 正则

    private static let reTS = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})"#)

    private static let reCTX = try! NSRegularExpression(
        pattern: #"AUTHREQ_CTX: msgID=([\w.]+).*?service=(\w+)(?:.*?preflight=(\w+))?"#)

    private static let reATTR = try! NSRegularExpression(
        pattern: #"AUTHREQ_ATTRIBUTION: msgID=([\w.]+), attribution=\{(.*)\}"#)

    private static let reResult = try! NSRegularExpression(
        pattern: #"AUTHREQ_RESULT: msgID=([\w.]+), authValue=(-?\d+)"#)

    private static let reProcTemplate = #"%K=\{TCCDProcess: identifier=([^,]*), pid=(\d+)([^}]*)\}"#

    private static let reRecStart = try! NSRegularExpression(
        pattern: #"^\S+ \S+ \S+ (.+?)\[(\d+):[^\]]*\] .*recordingOutputDidStartRecording"#)

    private static let reRecStop = try! NSRegularExpression(
        pattern: #"^\S+ \S+ \S+ (.+?)\[(\d+):[^\]]*\] .*recordingOutputDidFinishRecording"#)

    private static let rePath = try! NSRegularExpression(pattern: #"binary_path=([^,}]+)"#)

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let procRegexes: [String: NSRegularExpression] = [
        "responsible": try! NSRegularExpression(
            pattern: reProcTemplate.replacingOccurrences(of: "%K", with: "responsible")),
        "accessing": try! NSRegularExpression(
            pattern: reProcTemplate.replacingOccurrences(of: "%K", with: "accessing")),
        "requesting": try! NSRegularExpression(
            pattern: reProcTemplate.replacingOccurrences(of: "%K", with: "requesting")),
    ]

    // MARK: 解析

    func feed(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        // 录屏生命周期标记(不是 TCC 权限事件,单独处理)
        if line.contains("recordingOutputDid") {
            handleRecording(line)
            return
        }

        // 便宜的前置过滤,避免对海量无关行跑正则
        guard line.contains("AUTHREQ_") else { return }

        guard let tsRange = Self.reTS.firstMatch(in: line, range: line.fullRange),
              let ts = formatter.date(from: (line as NSString).substring(with: tsRange.range(at: 1)))
        else { return }

        if let m = Self.reCTX.firstMatch(in: line, range: line.fullRange) {
            let ns = line as NSString
            let msgID = ns.substring(with: m.range(at: 1))
            var p = pending[msgID] ?? Partial(timestamp: ts, raw: line)
            p.service = ns.substring(with: m.range(at: 2))
            watch("CTX 收到 service=\(p.service ?? "-") preflight=\(p.preflight ?? "-")", msgID: msgID)
            if m.range(at: 3).location != NSNotFound {
                p.preflight = ns.substring(with: m.range(at: 3))
            }
            pending[msgID] = p
            emitIfComplete(msgID: msgID, p)
            return
        }

        if let m = Self.reATTR.firstMatch(in: line, range: line.fullRange) {
            let ns = line as NSString
            let msgID = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            var p = pending[msgID] ?? Partial(timestamp: ts, raw: line)
            p.responsible = Self.proc(body, "responsible")
            p.accessing   = Self.proc(body, "accessing")
            p.requesting  = Self.proc(body, "requesting")
            p.hasAttribution = true
            watch("ATTR 收到 responsible=\(p.responsible?.identifier ?? "NIL") accessing=\(p.accessing?.identifier ?? "NIL")/\(p.accessing?.pid ?? -1) bodyLen=\(body.count)", msgID: msgID)
            pending[msgID] = p
            emitIfComplete(msgID: msgID, p)
            return
        }

        if let m = Self.reResult.firstMatch(in: line, range: line.fullRange) {
            let ns = line as NSString
            let msgID = ns.substring(with: m.range(at: 1))
            var p = pending[msgID] ?? Partial(timestamp: ts, raw: line)
            p.authValue = Int(ns.substring(with: m.range(at: 2)))
            pending[msgID] = p
            emitIfComplete(msgID: msgID, p)
        }
    }

    private func emitIfComplete(msgID: String, _ partial: Partial) {
        if partial.service != nil, partial.hasAttribution, partial.authValue != nil {
            emit(msgID: msgID, partial)
        }
    }

    /// 持续录屏的开始 / 结束标记
    private func handleRecording(_ line: String) {
        guard let tsRange = Self.reTS.firstMatch(in: line, range: line.fullRange),
              let ts = formatter.date(from: (line as NSString).substring(with: tsRange.range(at: 1)))
        else { return }
        let ns = line as NSString

        if let m = Self.reRecStart.firstMatch(in: line, range: line.fullRange) {
            guard let pid = Int(ns.substring(with: m.range(at: 2))), pid > 0 else { return }
            let key = "\(pid)|\(ts.timeIntervalSince1970)"
            guard reportedStarts[key] == nil else { return }
            let now = Date()
            reportedStarts = reportedStarts.filter { now.timeIntervalSince($0.value) < 240 }
            reportedStarts[key] = now
            recordingSince[pid] = ts
            onRecordingStart?(pid, ts, ns.substring(with: m.range(at: 1)))
        } else if let m = Self.reRecStop.firstMatch(in: line, range: line.fullRange) {
            let pid = Int(ns.substring(with: m.range(at: 2))) ?? -1
            if let start = recordingSince.removeValue(forKey: pid) {
                let d = ts.timeIntervalSince(start)
                let key = "\(pid)|\(start.timeIntervalSince1970)"
                if d > 0, reportedRecordings[key] == nil {
                    reportedRecordings[key] = Date()
                    if reportedRecordings.count > 512 {
                        reportedRecordings = reportedRecordings.filter {
                            Date().timeIntervalSince($0.value) < 240
                        }
                    }
                    onDuration?(pid, start, d)
                }
            }
        }
    }

    /// 有些事件永远等不到 RESULT(例如只做了 preflight),定时清理防止内存增长
    func flushStale(olderThan seconds: TimeInterval = 3.0) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        for (msgID, p) in pending where now.timeIntervalSince(p.firstSeen) > seconds {
            emit(msgID: msgID, p)
        }
    }

    private func emit(msgID: String, _ p: Partial) {
        pending.removeValue(forKey: msgID)
        guard !alreadySeen(msgID) else { return }
        watch("emit msg=\(msgID) svc=\(p.service ?? "NIL") acc=\(p.accessing?.identifier ?? "NIL") pid=\(p.accessing?.pid ?? -1) req=\(p.requesting?.identifier ?? "NIL") auth=\(p.authValue.map(String.init) ?? "NIL")",
              msgID: msgID)

        guard let service = p.service,
              let kind = PrivacyKind.from(service: service)
        else { return }

        // 归因:优先用 accessing。
        //
        // 踩过的坑:原本「没有 accessing 就丢弃」,理由是「那是 WindowServer 内部检查」。
        // 这条规则把两件完全不同的事混为一谈:
        //   · 缺 accessing + requesting=WindowServer/sandboxd → 确实是中介型内部检查
        //   · 缺 accessing + requesting=某个 App          → **App 直接申请自己的权限**
        // 后者恰恰是最重要的一类(摄像头、麦克风、通讯录、输入监控都走这条路),
        // 结果整类事件被静默丢掉,摄像头在界面上完全看不见。
        let actor: ProcInfo
        let requestingID: String?
        if let acc = p.accessing {
            actor = acc
            requestingID = p.requesting?.identifier
        } else if let req = p.requesting, !Self.mediators.contains(req.identifier) {
            actor = req                       // App 自己就是申请者
            requestingID = req.identifier
        } else {
            return                            // 真正的中介型内部检查,丢弃
        }

        let (sev, reason) = Judge.evaluate(
            kind: kind, service: service,
            responsible: p.responsible, accessing: actor,
            requesting: requestingID,
            authValue: p.authValue,
            preflight: p.preflight,
            directRequest: p.accessing == nil)

        let event = PrivacyEvent(
            timestamp: p.timestamp,
            service: service,
            kind: kind,
            responsible: p.responsible,
            accessing: actor,
            requesting: requestingID,
            authValue: p.authValue,
            preflight: p.preflight,
            severity: sev,
            reason: reason,
            isInherited: (p.responsible?.identifier).map { $0 != actor.identifier } ?? false)

        onEvent?(event)
    }

    // MARK: 工具

    private static func proc(_ body: String, _ key: String) -> ProcInfo? {
        guard let re = procRegexes[key],
              let m = re.firstMatch(in: body, range: body.fullRange)
        else { return nil }
        let ns = body as NSString
        let ident = ns.substring(with: m.range(at: 1))
        let pid = Int(ns.substring(with: m.range(at: 2))) ?? -1
        let rest = ns.substring(with: m.range(at: 3))
        var path: String?
        if let pm = rePath.firstMatch(in: rest, range: rest.fullRange) {
            path = (rest as NSString).substring(with: pm.range(at: 1))
        }
        return ProcInfo(identifier: ident, pid: pid, path: path)
    }
}

extension String {
    var fullRange: NSRange { NSRange(startIndex..<endIndex, in: self) }
}
