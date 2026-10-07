import AppKit

/// 剪贴板监测。
///
/// 先说清楚能力边界:
///   ✅ 能知道「剪贴板内容发生了变更」以及内容类型(text / image / file-url …)
///   ❌ 不能知道「哪个 App 读取了剪贴板」—— macOS 没有提供这样的接口
///
/// 因此本模块记录的是**变更事件**,并把当时的前台 App 作为「推测来源」标注。
/// 这个措辞是刻意的:把推测标成事实,就是误报的开始。
///
/// 另一条刻意的设计:只读 `types`(类型元数据),**绝不读取内容本体**。
/// 一个监测隐私的工具如果自己去翻用户的剪贴板内容,就没有资格做这件事。
final class ClipboardMonitor {

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    var onChange: ((PrivacyEvent) -> Void)?

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // 只取类型,不取内容
        let types = (pb.types ?? []).map(\.rawValue)
        let notable = types.filter {
            $0.contains("string") || $0.contains("tiff") || $0.contains("png")
                || $0.contains("rtf") || $0.contains("file-url") || $0.contains("pdf")
        }
        let kindText = notable.isEmpty
            ? (types.first ?? "未知")
            : notable.prefix(3).joined(separator: ", ")

        let front = NSWorkspace.shared.frontmostApplication
        let actor = ProcInfo(
            identifier: front?.bundleIdentifier ?? "unknown",
            pid: Int(front?.processIdentifier ?? -1),
            path: front?.bundleURL?.path)

        var e = PrivacyEvent(
            timestamp: Date(),
            service: "CLIPBOARD",
            kind: .clipboard,
            responsible: nil,
            accessing: actor,
            requesting: nil,
            authValue: nil,
            preflight: nil,
            severity: 1,
            reason: "剪贴板内容变更(类型: \(kindText));来源为推测(变更时的前台应用)")
        e.isInherited = false
        onChange?(e)
    }
}
