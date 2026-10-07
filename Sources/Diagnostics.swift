import Foundation

/// 极简诊断日志。
///
/// 为什么不用 NSLog:实测这台机器上 `NSLog` 的输出并不会出现在统一日志里
/// (`log show --predicate 'process == "BigBrother"'` 搜不到),于是应用内部
/// 出错时完全是黑盒。对一个要长期驻留、出问题又没法交互调试的菜单栏应用来说,
/// 必须有一个能捞出来的落盘通道。
enum Diagnostics {

    private static let queue = DispatchQueue(label: "local.bigbrother.diagnostics")
    private static let maxBytes = 512 * 1024

    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("BigBrother", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.log")
    }

    static func log(_ msg: String) {
        queue.async {
            let ts = Self.stamp.string(from: Date())
            let line = "\(ts)  \(msg)\n"
            let url = fileURL
            guard let data = line.data(using: .utf8) else { return }

            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                // seekToEnd / offsetInFile 在当前 SDK 上是 throwing 的
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                // 简单轮转,避免无限增长
                if let size = try? h.offsetInFile, size > UInt64(maxBytes) {
                    try? h.truncate(atOffset: 0)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()
}
