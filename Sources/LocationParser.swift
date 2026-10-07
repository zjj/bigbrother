import Foundation

/// 位置事件采集器。
///
/// ── 为什么位置需要单独一条通道 ──────────────────────────────────────
/// 屏幕/麦克风/摄像头/通讯录等都走 TCC,tccd 会记 AUTHREQ 审计行。
/// **位置不走 TCC 审计**:实测 3 小时日志里 `kTCCServiceLocation` 出现 0 次,
/// 而 `locationd` 10 分钟就记了 29528 行。位置是完全独立的一条管线,
/// 权限判定由 locationd 自己做,不经过 tccd 的审计日志。
///
/// 好消息是 locationd 自带 App 归属,Client 字段有两种形态:
///
///     <uuid>:i<bundle-id>:                                  → App
///     root:p<bundle 路径>:p<framework 路径>                  → 系统位置组件
///
/// ── 哪些日志才是「真的用了定位」(实测 macOS 27)───────────────────
/// 旧版只认 `computing freshAuthorizationContext` 且要求
/// `InUseLevel != NotInUse`。实测证明**这两个条件恰好把真实使用排除掉了**:
/// Google Chrome 02:23:27 真的拿到了坐标(`Sending location to client` 带坐标、
/// `#SystemStatus Publishing receiving location interval begin`),
/// 而它同一时刻的 `computing freshAuthorizationContext` 仍然是
/// `kCLClientInUseLevelNotInUse`。于是定位使用一条都记不下来。
///
/// 现在按证据强度分三级,同一毫秒内取最强的那条:
///
/// 1. `#SystemStatus Publishing receiving location interval begin`
///    —— 系统状态栏开始显示「正在使用定位」,与用户看到的绿点同源
/// 2. `Sending location to client` —— 坐标确实被投递给了这个客户端
/// 3. `client authorized for location; starting shortly` —— 授权通过并开始供数
///
/// `computing freshAuthorizationContext` 不再作为使用证据:它只是授权上下文的
/// 计算,与「有没有拿到坐标」无关。
///
/// ── 系统组件不进记录 ────────────────────────────────────────────────
/// Client 有 `root:` 前缀的那些(CoreParsec.framework、Routine.bundle、
/// CoreWLAN.framework…)是苹果自己的位置组件,不是用户装的 App,也不是某个
/// App 的代理:实测同一次供数里它们与第三方 App 没有归因关系。
/// 把它们当事件显示出来只会把真正要看的 App 挤下去 —— 那是噪音,不是信号。
/// 因此只统计不显示,计数保留在 `skippedSystemClients` 里供诊断。
final class LocationParser {

    /// 与用户看到的定位指示器同源:系统开始给这个客户端供数
    static let intervalBeginMarker = "receiving location interval begin"
    /// 坐标真的投递出去了
    static let deliveryMarker = "Sending location to client"
    /// 授权通过并开始供数(会话起点)
    static let authorizedMarker = "client authorized for location"

    static let markers = [intervalBeginMarker, deliveryMarker, authorizedMarker]

    /// log stream 的过滤条件用的字面量(避免两处写死不同步)
    static let predicateFragment = markers
        .map { #"eventMessage CONTAINS "\#($0)""# }
        .joined(separator: " OR ")

    var onEvent: ((PrivacyEvent) -> Void)?

    private static let reClient = try! NSRegularExpression(pattern: #""[Cc]lient":"([^"]*)""#)
    private static let reBundlePath = try! NSRegularExpression(pattern: #"bundlePath = \\"([^"]+)\\""#)
    private static let reTS = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})"#)

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 已经处理过的「毫秒 + 客户端」,挡掉轮询回看读到的重复行。
    private var seen: [String: Date] = [:]
    /// 同一个 App 持续用定位每秒都在打日志,按客户端限流,否则会刷屏。
    private var lastReported: [String: Date] = [:]
    private var lastSweep = Date()
    /// 同一毫秒内可能先后出现三条证据,先攒着,等更强的来了就替换。
    private var pending: (key: String, event: PrivacyEvent, rank: Int)?

    static let reportInterval: TimeInterval = 20

    /// 被跳过的系统位置组件条数(诊断用:说明这台机器确实在定位,
    /// 但那些组件不是 App,不该出现在记录里)。
    private(set) var skippedSystemClients = 0

    private func sweep(_ now: Date) {
        guard now.timeIntervalSince(lastSweep) > 30 else { return }
        lastSweep = now
        seen = seen.filter { now.timeIntervalSince($0.value) < 240 }
        lastReported = lastReported.filter { now.timeIntervalSince($0.value) < 3600 }
    }

    /// 毫秒 + 客户端:同一毫秒里的多条证据算同一次访问,
    /// 不同毫秒就是不同的访问(实测 Chrome 的授权在 .574、投递与状态栏在 .609)。
    private func seenBefore(_ key: String, now: Date) -> Bool {
        if seen[key] != nil { return true }
        sweep(now)
        seen[key] = now
        return false
    }

    private func throttled(_ key: String, now: Date) -> Bool {
        if let last = lastReported[key],
           now.timeIntervalSince(last) < Self.reportInterval { return true }
        lastReported[key] = now
        return false
    }

    func feed(_ line: String) {
        guard Self.markers.contains(where: { line.contains($0) }) else { return }

        guard let tsRange = Self.reTS.firstMatch(in: line, range: line.fullRange),
              let ts = formatter.date(from: (line as NSString).substring(with: tsRange.range(at: 1))),
              let cm = Self.reClient.firstMatch(in: line, range: line.fullRange)
        else { return }

        let ns = line as NSString
        let raw = ns.substring(with: cm.range(at: 1))
        var (identifier, path) = Self.parseClient(raw)
        // SystemStatus 那几行把 bundlePath 放在内嵌的 attribution 描述里,
        // 它能补上 Client 字段没给出的路径。
        if path == nil,
           let pm = Self.reBundlePath.firstMatch(in: line, range: line.fullRange) {
            path = ns.substring(with: pm.range(at: 1))
        }
        guard !identifier.isEmpty else { return }
        // 苹果自己的位置组件:只计数不记录。
        guard !Self.isSystemClient(identifier, path: path) else {
            skippedSystemClients += 1
            return
        }

        let evidence = Self.evidence(for: line)
        // 用日志原文里的毫秒字段做键(而不是 Date 的比较),这样 .574 与 .609
        // 是两次访问,而 .609 上的三条证据是同一毫秒的一次访问。
        let millisecond = ns.substring(with: tsRange.range(at: 1))
        let key = "\(millisecond)|\(identifier)"

        // 同一次访问(同一毫秒)留下的多条证据:只保留最强的那条。
        // 先到的「授权通过」不能被后到的「已开始供数」冲掉,也不能反过来
        // 把更强的证据丢掉。
        if seenBefore(key, now: Date()) {
            if let current = pending, current.key == key {
                pendingBuckets?.buckets.insert(evidence.bucket)
                if evidence.rank > current.rank {
                    pending = (key, Self.event(identifier: identifier, path: path,
                                               evidence: evidence, timestamp: ts, line: line),
                               evidence.rank)
                }
            }
            return
        }
        flushPending()

        // 不同毫秒的同一客户端在限流窗口内只记一条(持续供数不会刷屏),
        // 但限流不作用于同一毫秒的证据合并。
        guard !throttled("\(identifier)|\(evidence.bucket)", now: ts) else { return }

        pending = (key, Self.event(identifier: identifier, path: path,
                                   evidence: evidence, timestamp: ts, line: line),
                   evidence.rank)
        pendingBuckets = (identifier, [evidence.bucket], ts)
    }

    /// 结束一批日志时调用,避免最后一条一直攒着。
    func flush() { flushPending() }

    /// 同一毫秒内的多条证据都算「已经报过」。
    ///
    /// 否则会漏掉限流:这三条证据各自属于不同的分桶,只有最强的那条被记账时,
    /// 下一毫秒的另一条就会以为自己没报过,于是持续供数照样刷屏。
    private var pendingBuckets: (identifier: String, buckets: Set<String>, at: Date)?

    private func flushPending() {
        if let pendingBuckets {
            // 用日志自己的时间戳记账,而不是 Date() —— 轮询兜底读到的历史
            // 日志可能比当前时间早几秒到几十秒,用「现在」会让限流窗口错位。
            for bucket in pendingBuckets.buckets {
                lastReported["\(pendingBuckets.identifier)|\(bucket)"] = pendingBuckets.at
            }
            self.pendingBuckets = nil
        }
        guard let pending else { return }
        self.pending = nil
        onEvent?(pending.event)
    }

    // MARK: 证据

    struct Evidence {
        var text: String
        /// 限流分桶:同一个客户端的三类证据各自限流,不互相吞掉
        var bucket: String
        /// 越大越硬
        var rank: Int
    }

    static func evidence(for line: String) -> Evidence {
        if line.contains(intervalBeginMarker) {
            return Evidence(text: "系统开始向该客户端提供定位", bucket: "interval", rank: 3)
        }
        if line.contains(deliveryMarker) {
            return Evidence(text: "坐标已投递给该客户端", bucket: "delivery", rank: 2)
        }
        return Evidence(text: "该客户端获准使用定位并开始供数", bucket: "authorized", rank: 1)
    }

    static func event(identifier: String, path: String?, evidence: Evidence,
                      timestamp: Date, line: String) -> PrivacyEvent {
        var reasons: [String] = []
        reasons.append("App 定位使用")
        reasons.append(evidence.text)
        if let level = inUseLevel(in: line) {
            reasons.append("系统定位状态：\(level)")
        }
        reasons.append("由系统定位服务记录")

        var e = PrivacyEvent(
            timestamp: timestamp,
            service: "LOCATION_IN_USE",
            kind: .location,
            responsible: nil,
            accessing: ProcInfo(identifier: identifier, pid: -1, path: path),
            requesting: "com.apple.locationd",
            authValue: nil,
            preflight: nil,
            severity: 3,
            reason: reasons.joined(separator: ";"))
        e.isInherited = false
        return e
    }

    static func inUseLevel(in line: String) -> String? {
        guard let m = inUseLevelRegex.firstMatch(in: line, range: line.fullRange) else { return nil }
        return (line as NSString).substring(with: m.range(at: 1))
    }

    private static let inUseLevelRegex = try! NSRegularExpression(pattern: #""InUseLevel":"([^"]+)""#)

    /// 是系统位置组件而不是用户装的 App。
    ///
    /// 判定口径放在 `ProcInfo` 上,这样模型判定(排除历史遗留行)与解析器
    /// 用的是同一套规则,不会出现"解析器不记、统计却算"的分裂。
    static func isSystemClient(_ identifier: String, path: String?) -> Bool {
        ProcInfo(identifier: identifier, pid: -1, path: path).isSystemLocationComponent
    }

    /// 解析 Client 字段。
    ///
    ///     D2ED7D43-…:icom.apple.Maps:                      → bundle id
    ///     root:p/System/Library/LocationBundles/Routine.bundle: → 路径
    ///     D2ED7D43-…:icom.tencent.xinWeChat:p/Applications/…   → id + 路径
    static func parseClient(_ raw: String) -> (identifier: String, path: String?) {
        // 日志里的路径写成 `\134/System\134/Library`,其中 \134 是八进制 92
        // —— 也就是反斜杠本身。它其实是 JSON 的 `\/` 转义被再次转义的结果,
        // 而**斜杠已经跟在后面了**。
        //
        // 踩过的坑:一开始把 `\134` 整体替换成 `/`,于是 `/System` 变成 `//System`,
        // 前缀判断失配,系统位置组件全被误判成第三方 App。
        let s = raw
            .replacingOccurrences(of: "\\134/", with: "/")   // \134/ → /
            .replacingOccurrences(of: "\\134", with: "")     // 残留的 \134 → 去掉

        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        var identifier: String?
        var path: String?

        for part in parts {
            guard let first = part.first else { continue }
            switch first {
            case "i":
                let id = String(part.dropFirst())
                if !id.isEmpty { identifier = id }
            case "p":
                let candidate = String(part.dropFirst())
                if !candidate.isEmpty { path = candidate }
            default:
                continue
            }
        }

        if let identifier { return (identifier, path) }
        if let path {
            let last = (path as NSString).lastPathComponent
            return (last.isEmpty ? path : last, path)
        }
        return (s, nil)
    }
}
