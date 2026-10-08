import AppKit
import SwiftUI

@main
enum PanelLayoutTests {
    static func main() {
        let desktop = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let anchor = NSRect(x: 1200, y: 875, width: 24, height: 25)
        let frame = PanelLayout.frame(below: anchor, in: desktop)
        precondition(frame.width == 460 && frame.height == desktop.height * 0.75)
        precondition(frame.maxY == anchor.minY - 16)
        precondition(!frame.intersects(anchor), "Panel must not cover the menu bar button")
        precondition(!frame.contains(NSPoint(x: anchor.midX, y: anchor.minY - 8)),
                     "Leave a clear click gap below the menu bar button")
        precondition(desktop.contains(frame))

        let fitted = PanelLayout.frame(below: anchor, in: desktop, contentHeight: 420)
        precondition(fitted.height == 420, "Panel must fit the overview without extra empty space")
        precondition(fitted.maxY == anchor.minY - 16)
        let shortContent = PanelLayout.frame(below: anchor, in: desktop, contentHeight: 180)
        precondition(shortContent.height == PanelLayout.minimumContentHeight,
                     "Panel must preserve a useful minimum height when the overview is empty")
        let lowAnchor = NSRect(x: 1200, y: 300, width: 24, height: 25)
        let constrained = PanelLayout.frame(below: lowAnchor, in: desktop, contentHeight: 900)
        precondition(constrained.minY == desktop.minY + 12)
        precondition(constrained.maxY == lowAnchor.minY - 16)

        for desktop in [
            NSRect(x: 0, y: 0, width: 1024, height: 700),
            NSRect(x: -1920, y: 150, width: 1920, height: 1050),
            NSRect(x: 0, y: -900, width: 400, height: 860),
            NSRect(x: 1440, y: 0, width: 2560, height: 1415),
            NSRect(x: 0, y: 0, width: 3840, height: 2090)
        ] {
            for x in [desktop.minX, desktop.maxX - 24] {
                let anchor = NSRect(x: x, y: desktop.maxY, width: 24, height: 25)
                let frame = PanelLayout.frame(below: anchor, in: desktop)
                precondition(desktop.contains(frame), "Panel must remain on its display")
                precondition(frame.width == min(460, desktop.width))
                precondition(frame.height == desktop.height * 0.75,
                             "Panel must not exceed three quarters of the usable screen")
                precondition(frame.maxY == desktop.maxY - 16)
                precondition(anchor.minY - frame.maxY >= 16)
                precondition(!frame.intersects(anchor))
                precondition(frame.minY >= desktop.minY + 12)
                for height: CGFloat in [240, 520, 760, 2400] {
                    let fitted = PanelLayout.frame(below: anchor, in: desktop, contentHeight: height)
                    precondition(fitted.height == min(max(height, PanelLayout.minimumContentHeight),
                                                       desktop.height * 0.75))
                    precondition(desktop.contains(fitted))
                }
            }
        }
        testOverviewMeasurement()
        testDialogFocusHandoff()
        testStatusButtonToggle()
        for offset in [8 * 3600, 19800] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: offset)!
            let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6,
                                                         hour: 10, minute: 1))!
            let end = HourlyTimeline.end(after: now, calendar: calendar)
            precondition(calendar.component(.hour, from: end) == 11)
            let ticks = Sparkline.tickDates(endingAt: end, hours: 24)
            precondition(ticks.count == 5 && ticks.last == end)
            for (index, date) in ticks.enumerated() {
                precondition(calendar.component(.minute, from: date) == 0)
                precondition(calendar.component(.second, from: date) == 0)
                precondition(end.timeIntervalSince(date) == Double(4 - index) * 6 * 3600,
                             "Time ticks must align with whole-hour data buckets")
            }
        }
        print("PASS: 10:01 ends at 11:00, with whole-hour ticks in multiple time zones")
        print("PASS: panel fits overview content, capped at 3/4 of the usable screen height")
    }

    private static func testStatusButtonToggle() {
        let monitor = Monitor(store: EventStore(path: ":memory:"))
        let controller = StatusController(monitor: monitor)
        let toggle = NSSelectorFromString("togglePanel")
        func wait(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        controller.perform(toggle)
        precondition(controller.isPanelShown, "First status button click must open the panel")
        wait(0.4)
        guard let panel = NSApp.windows.first(where: { $0.title == "BigBrother" }) else {
            preconditionFailure("Opening must create the actual BigBrother panel")
        }
        precondition(panel.isVisible)
        panel.resignKey()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification,
                                        object: NSApp)
        controller.perform(toggle)
        precondition(!controller.isPanelShown,
                     "Focus loss before a second click must not turn closing into reopening")
        wait(0.2)
        precondition(!controller.isPanelShown)
        precondition(!panel.isVisible, "Second click must actually hide the native window")

        controller.perform(toggle)
        controller.perform(toggle)
        controller.perform(toggle)
        wait(0.2)
        precondition(controller.isPanelShown, "Rapid toggles must ignore obsolete close completions")
        precondition(panel.isVisible)
        monitor.isPresentingSystemDialog = true
        panel.resignKey()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification,
                                        object: NSApp)
        wait(0.2)
        precondition(controller.isPanelShown, "Permission dialogs must preserve the panel")
        monitor.endSystemDialog()
        wait(0.4)
        panel.resignKey()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        wait(0.2)
        precondition(!controller.isPanelShown, "Normal outside focus loss must still close the panel")
        print("PASS: native panel toggles, focus-loss ordering, outside dismissal and rapid repeated clicks")
    }

    private static func testDialogFocusHandoff() {
        let monitor = Monitor(store: EventStore(path: ":memory:"))
        var focusRequests = 0
        monitor.requestFocus = {
            precondition(monitor.isPresentingSystemDialog,
                         "Restore focus before re-enabling outside-click dismissal")
            focusRequests += 1
        }
        monitor.isPresentingSystemDialog = true
        monitor.endSystemDialog()
        precondition(focusRequests == 1 && !monitor.isPresentingSystemDialog)
        monitor.endSystemDialog()
        precondition(focusRequests == 1, "Repeated dismissal must not steal focus")
        monitor.isPresentingSystemDialog = true
        monitor.endSystemDialog(restoringFocus: false)
        precondition(focusRequests == 1 && !monitor.isPresentingSystemDialog,
                     "Opening System Settings must let the panel lose focus normally")
        monitor.requestFocus = nil

        // ── 清空数据那类确认框:弹窗期间面板不能被收起 ──────────────────
        // 踩过的坑:SwiftUI 的 confirmationDialog 会把面板顶掉,用户看到
        // 「点一下,界面消失」,得再点一次图标才能回来。协议统一放在
        // withSystemDialog 里,这里锁住它:期间标志位为真、结束后恢复焦点。
        var focusRestores = 0
        monitor.requestFocus = { focusRestores += 1 }
        var sawFlagDuringPrompt = false
        let confirmed = monitor.withSystemDialog { () -> Bool in
            sawFlagDuringPrompt = monitor.isPresentingSystemDialog
            return true
        }
        precondition(confirmed == true && sawFlagDuringPrompt,
                     "弹出确认框时必须声明正在展示系统对话框,否则面板会被收起")
        precondition(!monitor.isPresentingSystemDialog, "结束后标志位必须复位")
        precondition(focusRestores == 1, "结束后要把焦点还给面板")

        // 取消时不做任何事,但标志位同样要复位
        let cancelled = monitor.withSystemDialog { false }
        precondition(cancelled == false && !monitor.isPresentingSystemDialog && focusRestores == 2)

        // 已经有一个系统对话框时不得重入(否则标志位会被提前清掉)
        monitor.isPresentingSystemDialog = true
        var ran = false
        let nested = monitor.withSystemDialog { ran = true; return true }
        precondition(nested == nil && !ran, "重入的对话框必须被拒绝")
        monitor.isPresentingSystemDialog = false
        monitor.requestFocus = nil

        print("PASS: dialog focus restoration and System Settings handoff")
    }

    private static func testOverviewMeasurement() {
        _ = NSApplication.shared
        let monitor = Monitor(store: EventStore(path: ":memory:"))
        var measuredHeight: CGFloat = 0
        var measuredTab: PanelTab?
        var pageHeights: [PanelTab: CGFloat] = [:]
        let host = NSHostingView(rootView: PanelView(monitor: monitor) { tab, height in
            measuredTab = tab
            measuredHeight = height
            pageHeights[tab] = height
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host

        func layout() {
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }

        layout()
        precondition(measuredTab == .overview
                 && measuredHeight >= OverviewTab.emptyContentMinHeight + 100
                 && measuredHeight < 600,
                 "Empty overview must reserve a spacious content area without filling the viewport")
        let emptyHeight = measuredHeight
        window.setContentSize(NSSize(width: 460, height: emptyHeight))
        layout()
        precondition(measuredHeight == emptyHeight, "Content fitting must settle without resize feedback")

        monitor.todaySubjects = (0..<20).map { ("test.app.\($0)", 1, 1) }
        monitor.todayCounts = [(.microphone, 20)]
        layout()
        precondition(measuredHeight > emptyHeight + 300,
                     "Overview measurement must include rows outside the scroll viewport")
        let fullHeight = measuredHeight
        monitor.tab = .events
        layout()
        precondition(measuredTab == .events && pageHeights[.events] != nil,
                 "Each selected tab must report its own content height")
        precondition(measuredHeight < fullHeight,
                 "A short events page must not inherit the empty overview's whitespace")
        window.close()
        print("PASS: spacious empty overview, page-specific sizing and tab switching")
    }
}
