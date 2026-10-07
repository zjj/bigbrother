import AppKit
import SwiftUI
import Combine
import UserNotifications

enum PanelLayout {
    static let width: CGFloat = 460
    static let topGap: CGFloat = 16
    static let bottomMargin: CGFloat = 12

    static func frame(below anchor: NSRect, in visibleFrame: NSRect,
                      contentHeight: CGFloat? = nil) -> NSRect {
        let top = min(anchor.minY - topGap, visibleFrame.maxY)
        let maximumHeight = max(0, min(visibleFrame.height * 0.75,
                                      top - visibleFrame.minY - bottomMargin))
        let size = NSSize(width: min(width, visibleFrame.width),
                          height: min(maximumHeight, max(0, contentHeight ?? maximumHeight)))
        let x = min(max(anchor.midX - size.width / 2, visibleFrame.minX),
                    visibleFrame.maxX - size.width)
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 菜单栏状态项。
///
/// 行为约定(产品级约束):**应用永不主动弹出任何东西,只记录。**
/// 唯一的对外信号是菜单栏眼睛的颜色,它跟随最近一段时间内最高的事件等级变化。
/// 面板只在你主动点击时打开。
final class StatusController: NSObject {

    private let statusItem: NSStatusItem
    private let panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: 1),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
    private let monitor: Monitor
    private var cancellables = Set<AnyCancellable>()

    private var resignObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?
    private(set) var isPanelShown = false
    private var presentationGeneration = 0
    private var overviewHeight: CGFloat?

    /// 面板打开的时刻。用来防止「刚打开就因为失焦被自己关掉」——
    /// 那会退化成另一种形式的「要点两次」。
    private var shownAt = Date.distantPast
    private static let resignGuard: TimeInterval = 0.3

    /// 眼睛当前**显示**的等级(可以带小数)。它平滑地追赶真实等级,
    /// 于是颜色是淡出而不是跳变。
    /// 上升是立即的(严重事件要马上被看到),下降才走渐变。
    private var displayedLevel: Double = 0
    private var fadeTimer: Timer?
    private static let fadeFPS: Double = 20

    // MARK: 眼睛
    //
    //   形状:eye 正常 / eye.slash 采集已中断
    //   颜色:跟随威胁等级 —— 中=黄,高=橙,严重=红,其余不染色(跟随菜单栏主题)
    private static let iconIdle    = "eye"
    private static let iconStopped = "eye.slash"

    init(monitor: Monitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Esc 收起:交给 SwiftUI 的 onExitCommand,避免申请输入监控权限
        monitor.requestClose = { [weak self] in self?.closePanel() }
        monitor.requestFocus = { [weak self] in self?.restorePanelFocus() }
        let host = NSHostingController(rootView: PanelView(monitor: monitor) { [weak self] height in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.overviewHeight = height
                if self.isPanelShown { self.updatePanelFrame() }
            }
        })
        panel.contentViewController = host
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.title = "BigBrother"

        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            guard !self.monitor.isPresentingSystemDialog else { return }
            // 刚打开就失焦不算「切走了」,忽略
            guard Date().timeIntervalSince(self.shownAt) > Self.resignGuard else { return }
            self.scheduleFocusLossDismissal()
        }

        if let button = statusItem.button {
            button.image = IconFactory.eye(stopped: false, level: 0)
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown])
        }

        // 仅用于可选的通知;不再有任何弹窗行为
        monitor.onAlert = { _ in
            if monitor.notifyOnAlert { Notifier.postCurrent() }
        }

        // 威胁等级变化:上升立即、下降淡出
        monitor.$threatLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.easeBadge() }
            .store(in: &cancellables)
        monitor.$isCapturing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)
        monitor.$todayTotal
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)

        updateBadge()
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// 威胁等级 → 颜色(转发给 IconFactory,保持单一来源)
    static func tint(for level: Int) -> NSColor? { IconFactory.nsColor(for: level) }

    static func tintName(for level: Int) -> String { IconFactory.colorName(for: level) }

    // MARK: 交互

    private func restorePanelFocus() {
        guard isPanelShown else { return }
        shownAt = Date()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func updatePanelFrame() {
        guard let button = statusItem.button, let window = button.window,
              let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = PanelLayout.frame(below: anchor, in: screen.visibleFrame,
                                      contentHeight: overviewHeight)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    /// 唯一的开关决策者 —— 没有第二个东西会和它抢时序。
    @objc private func togglePanel() {
        if isPanelShown { closePanel() } else { showPanel() }
    }

    /// 只在你主动点击时打开。没有任何代码路径会自动调用它。
    func showPanel() {
        guard statusItem.button?.window?.screen != nil, !isPanelShown
        else { return }
        updatePanelFrame()
        presentationGeneration += 1
        isPanelShown = true
        shownAt = Date()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installDismissMonitors()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func closePanel() {
        guard isPanelShown else { return }
        isPanelShown = false
        presentationGeneration += 1
        let generation = presentationGeneration
        removeDismissMonitors()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.panel.orderOut(nil)
        }
    }

    // MARK: 面板外关闭

    private var isClickingStatusButton: Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let type = NSApp.currentEvent?.type
        let isClick = NSEvent.pressedMouseButtons & 1 != 0
            || type == .leftMouseDown || type == .leftMouseUp
        return isClick && anchor.contains(NSEvent.mouseLocation)
    }

    private func scheduleFocusLossDismissal() {
        guard isPanelShown, !monitor.isPresentingSystemDialog, !isClickingStatusButton else { return }
        let generation = presentationGeneration
        // 菜单栏点击可能先触发失焦;让按钮完成切换,再检查是否仍需收起。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.presentationGeneration == generation, self.isPanelShown,
                  !self.monitor.isPresentingSystemDialog,
                  (!NSApp.isActive || !self.panel.isKeyWindow),
                  !self.isClickingStatusButton else { return }
            self.closePanel()
        }
    }

    /// 点面板外收起 + Esc 收起。
    ///
    /// ── 为什么不能用 addGlobalMonitorForEvents ──────────────────────
    /// 全局事件监听需要**「输入监控」权限**。一个隐私审计工具去申请监听
    /// 键盘鼠标,是最糟糕的自相矛盾:它既是最重的权限之一,又会让工具自己
    /// 出现在被监测列表里(实测产生了 14 条 kTCCServiceListenEvent)。
    ///
    /// 改用「面板窗口失去 key 状态」的通知 —— 点到外面去了同样能捕获,
    /// 而且不需要任何权限。
    ///
    /// Esc 交给 SwiftUI,不安装键盘或鼠标监听。
    private func installDismissMonitors() {
        removeDismissMonitors()

        // 面板窗口失去焦点 → 收起。
        let t = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            self?.scheduleFocusLossDismissal()
        }
        resignObserver = t

        // Esc 收起改由 SwiftUI 的 .onExitCommand 处理(见 PanelView)。
        //
        // 这里连 local monitor 也不再使用:实测本应用持续产生
        // kTCCServiceListenEvent 且 auth_value=0(被拒),说明任何形式的
        // NSEvent 监听都会去申请「输入监控」。隐私工具不该碰这个权限。
    }

    private func removeDismissMonitors() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// 菜单栏外观完全由两个状态决定:
    ///   - 采集是否存活 → 形状(eye / eye.slash)
    ///   - 当前威胁等级 → 颜色
    ///
    /// 图标由 IconFactory 合成成**非模板彩色位图**。不用 contentTintColor ——
    /// 那个属性在模板图上会被菜单栏的明暗主题覆盖,颜色不生效。
    private func updateBadge() {
        guard let button = statusItem.button else { return }

        button.image = IconFactory.eye(stopped: !monitor.isCapturing,
                                       level: displayedLevel)
        button.contentTintColor = nil       // 我们自己上色,不让系统再叠一层

        let n = monitor.todayTotal
        button.title = n > 0 ? " \(n)" : ""
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    }

    /// 让显示等级平滑追赶真实等级。
    ///
    /// 上升直接到位 —— 严重事件要立刻可见,不能等动画。
    /// 下降走指数缓动,那就是「淡出」。
    private func easeBadge() {
        let target = Double(monitor.threatLevel)
        fadeTimer?.invalidate()
        fadeTimer = nil

        if target >= displayedLevel {
            displayedLevel = target
            updateBadge()
            return
        }

        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / Self.fadeFPS,
                                         repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let diff = target - self.displayedLevel
            if abs(diff) < 0.05 {
                self.displayedLevel = target
                self.updateBadge()
                t.invalidate()
                self.fadeTimer = nil
                return
            }
            self.displayedLevel += diff * 0.14      // 指数缓动
            self.updateBadge()
        }
        if let t = fadeTimer { RunLoop.main.add(t, forMode: .common) }
    }
}

// MARK: - 系统通知

enum Notifier {
    private static var available = false
    private static let delegate = NotificationDelegate()

    private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list])
        }
    }

    static func setup() {
        available = Bundle.main.bundleIdentifier != nil
        if available { UNUserNotificationCenter.current().delegate = delegate }
    }

    enum AuthorizationResult {
        case authorized
        case denied
        case unavailable
        case alertsDisabled
    }

    private static func result(for settings: UNNotificationSettings) -> AuthorizationResult {
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return settings.alertSetting == .enabled ? .authorized : .alertsDisabled
        case .denied:
            return .denied
        case .notDetermined:
            return .unavailable
        @unknown default:
            Diagnostics.log("[通知] 无法识别系统通知授权状态")
            return .unavailable
        }
    }

    static func authorizationStatus(completion: @escaping (AuthorizationResult) -> Void) {
        guard available else {
            completion(.unavailable)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(result(for: settings))
        }
    }

    static func requestAuthorization(completion: @escaping (AuthorizationResult) -> Void) {
        guard available else {
            completion(.unavailable)
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                completion(result(for: settings))
            case .denied:
                completion(.denied)
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, error in
                    if let error {
                        Diagnostics.log("[通知] 授权请求失败: \(error.localizedDescription)")
                        completion(.unavailable)
                    } else {
                        if granted {
                            authorizationStatus(completion: completion)
                        } else {
                            completion(.denied)
                        }
                    }
                }
            @unknown default:
                Diagnostics.log("[通知] 无法识别系统通知授权状态")
                completion(.unavailable)
            }
        }
    }

    /// 只在用户显式打开通知开关时才被调用。默认姿态是「只记录」。
    static func postCurrent() {
        guard available else {
            Diagnostics.log("[通知] 当前运行方式不支持系统通知")
            return
        }
        authorizationStatus { status in
            guard case .authorized = status else {
                Diagnostics.log("[通知] 系统未允许提醒，未发送通知")
                return
            }
            postAuthorizedNotification()
        }
    }

    private static func postAuthorizedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "BigBrother"
        content.body = "有需要留意的访问记录。点击菜单栏图标查看详情。"
        content.sound = nil
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                Diagnostics.log("[通知] 发送失败: \(error.localizedDescription)")
            }
        }
    }
}
