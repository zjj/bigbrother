import AppKit
import SwiftUI

// MARK: - 应用委托

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = EventStore()
        let m = Monitor(store: store)
        Notifier.setup()
        status = StatusController(monitor: m)
        m.start()
        monitor = m
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}

// MARK: - 入口
//
// 默认启动菜单栏应用;带参数时进入命令行自检模式,便于在无图形会话的环境验证。

let arguments = CommandLine.arguments

if arguments.count >= 2 {
    switch arguments[1] {
    case "--selftest":
        exit(SelfTest.run(files: Array(arguments.dropFirst(2))))
    case "--scan":
        exit(SelfTest.scan(files: Array(arguments.dropFirst(2))))
    case "--icon-test":
        exit(SelfTest.iconTest())
    case "--drill-test":
        exit(SelfTest.drillTest(files: Array(arguments.dropFirst(2))))
    case "--coverage-test":
        exit(SelfTest.coverageTest(files: Array(arguments.dropFirst(2))))
    case "--stream-test":
        exit(SelfTest.logStreamTest())
    case "--locscan":
        exit(SelfTest.locationScan(files: Array(arguments.dropFirst(2))))
    case "--names-test":
        exit(SelfTest.namesTest())
    case "--preview":
        exit(SelfTest.preview())
    case "--help", "-h":
        print("""
              BigBrother — macOS 隐私行为审计

              用法:
                BigBrother                     启动菜单栏应用
                BigBrother --selftest <日志>…  仅解析日志并打印
                BigBrother --scan <日志>…      解析 → 落库 → 输出聚合报告
                BigBrother --locscan <日志>…   只看定位通道(不走 TCC)
                BigBrother --stream-test       验证实时流挂掉后能被回收

              环境变量:
                BIGBROTHER_DB   覆盖 SQLite 数据库路径
                PS_WATCH        定点跟踪某个 msgID 的解析过程
              """)
        exit(0)
    default:
        break
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)   // 只驻留菜单栏,不占 Dock
application.run()
