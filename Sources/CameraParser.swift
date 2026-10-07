import Foundation

/// 摄像头「正在使用」采集器。
///
/// ── 为什么摄像头需要第二条通道 ──────────────────────────────────────
/// 摄像头走 TCC,tccd 通常会记 AUTHREQ 审计行。但实测 macOS 27 + 微信视频通话
/// 出现了 TCC **完全没有记录**的情况:
///
///     02:58:27  cameracaptured  配置 1920x1440 视频流、ControlCenter 标记
///               com.tencent.xinWeChat 摄像头活跃
///     同一时刻  tccd 只有 kTCCServiceMicrophone 的 AUTHREQ,
///               kTCCServiceCamera 一条审计都没有
///
/// 也就是说:App 已经在用摄像头,而权限审计这条线是空的。只靠 TCC 会漏报。
///
/// 可靠的那条线是 Control Center 自己:它要为用户显示摄像头指示器,
/// 因此会明确记下 **哪个 bundle 在活跃使用摄像头**:
///
///     [com.apple.cameracapture:] <<<< AVControlCenterModules >>>>
///       avccm_VideoEffectsModuleShouldBeShownForBundleID: com.tencent.xinWeChat active:1
///
/// 这与菜单栏那个摄像头小圆点同源 —— 用户看到指示灯亮了,这里就必须有记录。
final class CameraParser {

    /// 摄像头(视频效果)模块开始显示。实测摄像头活跃对应的是
    /// `avccm_VideoEffectsModuleShouldBeShownForBundleID`,不是名字里带
    /// Camera 的那个 —— 按名字猜会一条都匹配不到。
    static let cameraActiveMarker = "avccm_VideoEffectsModuleShouldBeShownForBundleID"
    /// 只认「确实活跃」的那条(开始显示的那条不带 active)
    static let activeMarker = "active:1"

    /// 系统自己的采集组件,不是 App
    static let systemBundlePrefixes = ["com.apple.cameracaptured", "com.apple.controlcenter"]

    static let predicateFragment =
        #"(eventMessage CONTAINS "\#(cameraActiveMarker)" AND eventMessage CONTAINS "\#(activeMarker)")"#

    var onEvent: ((PrivacyEvent) -> Void)?

    private static let reBundle = try! NSRegularExpression(
        pattern: #"ForBundleID: ([A-Za-z0-9._-]+)"#)
    private static let reTS = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})"#)

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 精确去重(轮询会重复读到同一行)+ 按 App 限流。
    private var seen: [String: Date] = [:]
    private var lastReported: [String: Date] = [:]
    private var lastSweep = Date()

    /// 一次摄像头会话里,Control Center 会反复重发同一条状态;实测一分钟上百条。
    static let reportInterval: TimeInterval = 20

    /// 被跳过的系统采集组件条数(诊断用)
    private(set) var skippedSystemClients = 0

    private func sweep(_ now: Date) {
        guard now.timeIntervalSince(lastSweep) > 30 else { return }
        lastSweep = now
        seen = seen.filter { now.timeIntervalSince($0.value) < 240 }
        lastReported = lastReported.filter { now.timeIntervalSince($0.value) < 3600 }
    }

    func feed(_ line: String) {
        guard line.contains(Self.cameraActiveMarker), line.contains(Self.activeMarker) else { return }

        guard let tsRange = Self.reTS.firstMatch(in: line, range: line.fullRange),
              let ts = formatter.date(from: (line as NSString).substring(with: tsRange.range(at: 1))),
              let bm = Self.reBundle.firstMatch(in: line, range: line.fullRange)
        else { return }

        let ns = line as NSString
        let bundle = ns.substring(with: bm.range(at: 1))
        guard !bundle.isEmpty else { return }
        guard !Self.systemBundlePrefixes.contains(where: { bundle.hasPrefix($0) }) else {
            skippedSystemClients += 1
            return
        }

        let millisecond = ns.substring(with: tsRange.range(at: 1))
        let key = "\(millisecond)|\(bundle)"
        sweep(Date())
        if seen[key] != nil { return }
        seen[key] = ts

        if let last = lastReported[bundle], ts.timeIntervalSince(last) < Self.reportInterval {
            return
        }
        lastReported[bundle] = ts

        var e = PrivacyEvent(
            timestamp: ts,
            service: "CAMERA_IN_USE",
            kind: .camera,
            responsible: nil,
            accessing: ProcInfo(identifier: bundle, pid: -1, path: nil),
            requesting: "com.apple.controlcenter",
            authValue: nil,
            preflight: nil,
            severity: 3,
            reason: "系统报告摄像头正在被该 App 使用;Control Center 摄像头指示器同时点亮")
        e.isInherited = false
        onEvent?(e)
    }
}
