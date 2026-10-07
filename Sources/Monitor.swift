import Foundation
import Combine
import AppKit

/// 协调器:把「采集 → 解析 → 判定 → 落库 → 聚合 → 界面」串起来。
final class Monitor: ObservableObject {

    // MARK: 对外发布的状态

    @Published var statusText = "正在启动…"
    @Published var storageError: String?
    @Published var isCapturing = false
    private(set) var hasStarted = false
    @Published var todayCounts: [(kind: PrivacyKind, n: Int)] = []
    @Published var todayCategories: [(category: PrivacyCategory, n: Int)] = []
    /// 今日访问过敏感权限的 App(概览页主列表)
    @Published var todaySubjects: [(identifier: String, n: Int, worst: Int)] = []
    @Published var todayTotal = 0
    @Published var totalCount = 0
    @Published var highSeverity = 0
    @Published var deniedCount = 0
    @Published var notifyOnAlert = UserDefaults.standard.bool(forKey: "notifyOnAlert") {
        didSet { UserDefaults.standard.set(notifyOnAlert, forKey: "notifyOnAlert") }
    }
    @Published var recent: [PrivacyEvent] = []
    @Published var topActors: [(name: String, n: Int)] = []
    @Published var histogram: [Int] = []
    @Published var histogramEnd = HourlyTimeline.end(after: Date())
    @Published var inheritance: [(owner: String, actor: String, n: Int)] = []
    @Published var latest: PrivacyEvent?

    /// 当前威胁等级(0~5)= 最近一段时间内的最高事件等级。
    /// 菜单栏眼睛的颜色完全由它驱动 —— 应用不会以任何方式主动弹出。
    @Published var threatLevel = 0

    /// 当前标签页。放在 Monitor 里,概览页的下钻才能切到事件页。
    @Published var tab: PanelTab = .overview

    /// 当前筛选(搜索 / 类型 / 进程 / 仅被拒 / 仅高危),由下钻与手动筛选共同驱动
    @Published var filter = DrillFilter()

    /// 眼睛保持变色多久(秒)。事件滑出这个窗口后颜色自动退回。
    var threatWindow: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "threatWindow")
            return v == 0 ? 60 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "threatWindow") }
    }

    /// 事件保留天数。菜单栏应用会连续跑数月,没有保留策略表会无限涨。
    var retentionDays: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "retentionDays")
            return v == 0 ? 90 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "retentionDays") }
    }

    /// 达到「值得关注」的事件回调(仅用于可选的通知,不再用于弹窗)
    var onAlert: ((PrivacyEvent) -> Void)?

    let store: EventStore
    private let parser = TCCParser()
    private let locationParser = LocationParser()
    /// 摄像头另开一条通道:实测微信视频通话时 TCC 完全没有摄像头审计行,
    /// 只有 Control Center 的「哪个 App 在用摄像头」记录。
    private let cameraParser = CameraParser()
    private let streamer = LogStreamer()
    private let clipboard = ClipboardMonitor()
    private var refreshTimer: Timer?
    private var staleTimer: Timer?
    private var heartbeatTimer: Timer?
    private var pruneTimer: Timer?

    init(store: EventStore) {
        self.store = store
        storageError = store.storageError

        parser.onEvent = { [weak self] e in self?.handle(e) }
        locationParser.onEvent = { [weak self] e in self?.handle(e) }
        cameraParser.onEvent = { [weak self] e in self?.handle(e) }

        parser.onRecordingStart = { [weak self] pid, timestamp, processName in
            guard let self else { return }
            // 回看日志可能来自已退出的进程,不能把复用的 PID 归给当前 App。
            let app = NSRunningApplication(processIdentifier: pid_t(pid))
            let fresh = abs(timestamp.timeIntervalSinceNow) < 30
            let launchedBefore = app?.launchDate.map { $0 <= timestamp } ?? false
            let matchesName = app?.executableURL?.lastPathComponent == processName
            let actor: ProcInfo?
            if fresh, launchedBefore, matchesName, let identifier = app?.bundleIdentifier {
                actor = ProcInfo(identifier: identifier, pid: pid, path: app?.executableURL?.path)
            } else {
                actor = nil
            }
            if let event = self.store.recordingStarted(pid: pid, at: timestamp, actor: actor) {
                self.publish(event)
            }
        }

        // 录屏结束时回填时长 —— TCC 日志没有这个信息
        parser.onDuration = { [weak self] pid, startedAt, seconds in
            guard let self,
                  let event = self.store.annotateDuration(
                    pid: pid, startedAt: startedAt, seconds: seconds) else { return }
            self.publish(event)
        }

        streamer.onLine = { [weak self] line in
            self?.parser.feed(line)
            self?.locationParser.feed(line)
            self?.cameraParser.feed(line)
        }
        // 每批日志读完把定位那攒着的一条冲出去:同一次访问的多条证据
        // 要等这一批内更强的那个到了再定稿。
        streamer.onBatchEnd = { [weak self] in self?.locationParser.flush() }
        streamer.onStatus = { [weak self] s in
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusText = s
                self.isCapturing = self.streamer.isRunning
            }
        }
        clipboard.onChange = { [weak self] e in self?.handle(e) }
    }

    // MARK: 生命周期

    func start() {
        streamer.start()
        hasStarted = true
        isCapturing = streamer.isRunning
        clipboard.start()

        // 5 秒足够:威胁等级(眼睛颜色)有独立的即时路径 handle(),
        // 不依赖这个聚合刷新。2 秒会把 7 天聚合的 CPU 占用放大 2.5 倍。
        let r = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(r, forMode: .common)
        refreshTimer = r

        // 保留策略:启动时清一次,之后每小时一次
        store.pruneOlderThan(days: retentionDays)
        let prune = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.store.pruneOlderThan(days: self.retentionDays)
            self.refresh()
        }
        RunLoop.main.add(prune, forMode: .common)
        pruneTimer = prune

        // 心跳:每 15 秒记录一次管线各段的计数,用来定位「卡在哪一段」
        let hb = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let since = Date().timeIntervalSince(self.streamer.lastDataAt)
            Diagnostics.log("HEARTBEAT 模式=\(self.streamer.mode.rawValue) "
                + "行数=\(self.streamer.linesReceived) "
                + "采集存活=\(self.streamer.isRunning) "
                + "距上次数据=\(String(format: "%.1f", since))s "
                + "解析器pending=\(self.parser.pendingCount) "
                + "会话表=\(self.store.openSessionCount) "
                + "写失败=\(self.store.writeFailures)")
        }
        RunLoop.main.add(hb, forMode: .common)
        heartbeatTimer = hb

        // preflight 类事件可能永远等不到 RESULT,需要定期清理
        let s = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.parser.flushStale()
        }
        RunLoop.main.add(s, forMode: .common)
        staleTimer = s

        refresh()
    }

    func stop() {
        streamer.stop(); clipboard.stop()
        isCapturing = false
        refreshTimer?.invalidate(); staleTimer?.invalidate()
heartbeatTimer?.invalidate()
    }

    // MARK: 下钻
    //
    // 概览页上的每一个聚合数字都可以点进去看构成它的事件。

    /// 从概览页下钻到事件页,并应用一组筛选
    private func drill(_ mutate: (inout DrillFilter) -> Void) {
        var f = DrillFilter()
        mutate(&f)
        filter = f
        tab = .events
        refresh()
    }

    /// 由 StatusController 注入:请求关闭面板(Esc 用)
    var requestClose: (() -> Void)?
    var requestFocus: (() -> Void)?
    var isPresentingSystemDialog = false

    func endSystemDialog(restoringFocus: Bool = true) {
        guard isPresentingSystemDialog else { return }
        if restoringFocus { requestFocus?() }
        // 焦点恢复要在标志位清掉之前完成 —— 否则面板会在这中间被
        // 「失去 key 就收起」的规则收走,用户就得再点一次图标。
        isPresentingSystemDialog = false
    }

    /// 展示一个系统对话框(NSAlert / 系统权限弹窗)时,面板不能因为失焦而收起。
    ///
    /// 踩过的坑:清空全部数据原本用 SwiftUI 的 `confirmationDialog`,
    /// 弹窗把面板顶掉之后面板就被收起了 —— 用户看到「点一下,界面消失」,
    /// 得再点一次图标才能回来。所有会抢焦点的系统 UI 都必须走这里:
    /// 期间让收起逻辑让路,结束后恢复面板焦点。
    ///
    /// `body` 返回后标志位一定会被清掉,不需要每个调用点自己配对。
    func withSystemDialog<T>(_ body: () -> T) -> T? {
        guard !isPresentingSystemDialog else { return nil }
        isPresentingSystemDialog = true
        defer { endSystemDialog() }
        return body()
    }

    /// 事件列表一次最多取多少条(界面上的「N 条」要据此判断是否被截断)
    static let listLimit = 400

    /// 今日零点
    static var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }
    /// 7 天前(「最活跃的进程」与「被拒尝试」的窗口)
    static var sevenDaysAgo: Date { Date().addingTimeInterval(-7 * 86400) }
    /// 24 小时前(「高危」的窗口)
    static var dayAgo: Date { Date().addingTimeInterval(-24 * 3600) }

    /// 点某个权限类型(来源是「今日按类型」,窗口同今日)
    func drillInto(kind: PrivacyKind) {
        drill { $0.kinds = [kind]; $0.since = Self.startOfToday; $0.sinceLabel = "今日" }
    }

    /// 点某个分类(来源是「今日分类」)
    func drillInto(category: PrivacyCategory) {
        drill {
            $0.kinds = Set(PrivacyKind.allCases.filter { $0.category == category })
            $0.since = Self.startOfToday
            $0.sinceLabel = "今日"
        }
    }

    /// 点概览页主列表里的某个 App(口径 = 授权主体,窗口 = 今日)
    func drillIntoSubject(_ identifier: String) {
        drill {
            $0.subject = identifier
            $0.since = Self.startOfToday
            $0.sinceLabel = "今日"
        }
    }

    /// 点某个进程(来源是「最活跃的进程(7 天)」)
    func drillInto(actor: String) {
        drill { $0.actor = actor; $0.since = Self.sevenDaysAgo; $0.sinceLabel = "近 7 天" }
    }

    /// 点「被拒尝试」(对应 deniedCount,窗口 7 天)
    func drillIntoDenied() {
        drill { $0.onlyDenied = true; $0.since = Self.sevenDaysAgo; $0.sinceLabel = "近 7 天" }
    }

    /// 点「高危」(对应 highSeverityCount,窗口 24 小时)
    func drillIntoHighRisk() {
        drill { $0.onlyHighRisk = true; $0.since = Self.dayAgo; $0.sinceLabel = "近 24 小时" }
    }

    /// 清空筛选(留在事件页)
    func clearFilter() {
        filter = DrillFilter()
        refresh()
    }

    /// 从事件页回到概览
    func backToOverview() {
        filter = DrillFilter()
        tab = .overview
        refresh()
    }

    // MARK: 事件入口

    private func handle(_ e: PrivacyEvent) {
        let result = store.insert(e)
        if result.ignored { return }
        guard result.id != 0 else {
            let error = store.storageError
            DispatchQueue.main.async { self.storageError = error }
            return
        }
        publish(e)
    }

    private func publish(_ e: PrivacyEvent) {
        DispatchQueue.main.async {
            self.latest = e

            // 眼睛颜色立即跟上,不等下一次聚合刷新
            // 元数据枚举(非 replayd 的屏幕访问)不参与变色,否则任何 App
            // 枚举一次窗口都会让眼睛闪一下
            if e.affectsThreatLevel && e.severity > self.threatLevel {
                self.threatLevel = e.severity
            }

            // 仅当用户显式打开通知时才发系统通知 —— 默认「只记录」
            if self.notifyOnAlert && e.shouldAlert {
                self.onAlert?(e)
            }
        }
    }

    // MARK: 聚合刷新

    func refresh() {
        let store = self.store
        let f = filter
        let window = threatWindow

        DispatchQueue.global(qos: .utility).async {
            // ── 快查询:每轮都跑(都被时间窗限制,毫秒级)──
            let tc    = store.todayCounts()
            let subs  = store.todaySubjects()
            let tt    = store.todayTotal()
            let tot   = store.totalCount()
            let rec   = store.recentEvents(limit: Self.listLimit,
                                           minSeverity: f.onlyHighRisk ? 4 : 0,
                                           onlyDenied: f.onlyDenied,
                                           kinds: f.kinds.isEmpty ? nil : f.kinds,
                                           actor: f.actor,
                                           search: f.search,
                                           since: f.since,
                                           subject: f.subject,
                                           scope: f.scope)

            // 分类直接从类型计数推导 —— 这两者本来就是同一个查询,
            // 之前跑了两遍,在 50 万行下白花掉 0.37 秒
            var catAgg: [PrivacyCategory: Int] = [:]
            for (k, n) in tc { catAgg[k.category, default: 0] += n }
            let tcat = PrivacyCategory.allCases
                .compactMap { c in catAgg[c].map { (c, $0) } }
                .sorted { $0.1 > $1.1 }

            // 这些查询都是毫秒级(时间窗已被索引覆盖),每轮直接算,
            // 不再需要"每 6 轮跑一次"的节流。
            let hs   = store.highSeverityCount()
            let dn   = store.deniedCount()
            let top  = store.topActors()
            let histEnd = HourlyTimeline.end(after: Date())
            let hist = store.hourlyHistogram(endingAt: histEnd)
            let inh  = store.inheritanceReport()
            // 重新从库里算威胁等级,事件滑出时间窗后颜色自动退回
            let thr   = store.maxSeveritySince(seconds: window)
            let storageError = store.storageError

            DispatchQueue.main.async {
                self.storageError = storageError
                self.todayCounts     = tc.map { (kind: $0.0, n: $0.1) }
                self.todayCategories = tcat.map { (category: $0.0, n: $0.1) }
                self.todaySubjects   = subs.map { (identifier: $0.0, n: $0.1, worst: $0.2) }
                self.todayTotal  = tt
                self.totalCount  = tot
                self.highSeverity = hs
                self.deniedCount = dn
                self.recent      = rec
                self.topActors   = top.map { (name: $0.0, n: $0.1) }
                self.histogram   = hist
                self.histogramEnd = histEnd
                self.inheritance = inh
                self.threatLevel = thr
            }
        }
    }
}
