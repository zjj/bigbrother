import Foundation

/// 开机自启。
///
/// 走 LaunchAgent 而不是 `SMAppService.mainApp` —— 后者要求 App 位于
/// /Applications 且经过正式签名,本项目的 ad-hoc 构建用不了。
enum LoginItem {

    static let label = "local.bigbrother"
    private(set) static var lastError: String?

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        lastError = nil
        return on ? enable() : disable()
    }

    private static func failed(_ message: String) -> Bool {
        lastError = message
        Diagnostics.log("[登录启动] \(message)")
        return false
    }

    private static func enable() -> Bool {
        guard let exe = Bundle.main.executablePath else {
            return failed("无法找到 BigBrother，请重新安装后再试。")
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Background",
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            return failed("无法保存登录启动设置：\(error.localizedDescription)")
        }
    }

    private static func disable() -> Bool {
        guard isEnabled else { return true }
        do {
            try FileManager.default.removeItem(at: plistURL)
            return true
        } catch {
            return failed("无法关闭登录启动：\(error.localizedDescription)")
        }
    }
}
