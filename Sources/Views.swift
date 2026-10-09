import SwiftUI
import AppKit

// MARK: - 配色

func severityColor(_ s: Int) -> Color {
    switch s {
    case 5: return .red
    case 4: return .orange
    case 3: return .yellow
    case 2: return .blue
    default: return .secondary
    }
}

private let bg = Color(nsColor: .windowBackgroundColor)

/// 头部眼睛的颜色 —— 与菜单栏保持一致
func eyeColor(level: Int, capturing: Bool) -> Color {
    guard capturing else { return .red }
    switch level {
    case 5: return .red
    case 4: return .orange
    case 3: return .yellow
    default: return .accentColor
    }
}

// MARK: - 根视图

private struct PanelContentSize: Equatable {
    var chrome: CGFloat = 0
    var content: CGFloat = 0
    var tab: PanelTab?
}

private struct PanelContentSizeKey: PreferenceKey {
    static let defaultValue = PanelContentSize()

    static func reduce(value: inout PanelContentSize, nextValue: () -> PanelContentSize) {
        let next = nextValue()
        value.chrome = max(value.chrome, next.chrome)
        if next.content > 0 {
            value.content = max(value.content, next.content)
            value.tab = next.tab
        }
    }
}

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    var onContentHeightChange: (PanelTab, CGFloat) -> Void = { _, _ in }
    @ScaledMetric(relativeTo: .body) private var fontScale = 1.0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                Picker("", selection: $monitor.tab) {
                    ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("页面")
                .font(.system(size: 12 * fontScale))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PanelContentSizeKey.self,
                                       value: PanelContentSize(chrome: geometry.size.height))
            })

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = monitor.storageError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("无法保存或读取记录").font(.headline)
                            Text("请检查磁盘空间和记录文件夹的访问权限。这里的数据可能不完整。")
                            Text(error).textSelection(.enabled)
                        }
                        .font(.system(size: 12 * fontScale))
                        .foregroundStyle(.red)
                    }
                    switch monitor.tab {
                    case .overview: OverviewTab(monitor: monitor)
                    case .events:   EventsTab(monitor: monitor)
                    case .stats:    StatsTab(monitor: monitor)
                    case .settings: SettingsTab(monitor: monitor)
                    }
                }
                .padding(12)
                .background(GeometryReader { geometry in
                    Color.clear.preference(
                        key: PanelContentSizeKey.self,
                        value: PanelContentSize(content: geometry.size.height,
                                                tab: monitor.tab))
                })
            }
        }
        .onPreferenceChange(PanelContentSizeKey.self) { size in
            guard size.chrome > 0, size.content > 0, let tab = size.tab else { return }
            onContentHeightChange(tab, ceil(size.chrome + size.content))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Esc 收起。用 SwiftUI 原生的 onExitCommand,不装任何 NSEvent 监听 ——
        // 任何形式的键盘监听都会让本应用去申请「输入监控」权限,
        // 而一个隐私工具碰这个权限是最糟糕的自相矛盾。
        .onExitCommand { monitor.requestClose?() }
    }

    static func statusText(level: Double) -> String {
        switch level {
        case ..<2.5: return "监测中"
        case ..<3.5: return "近期有请求或活动"
        case ..<4.5: return "近期有需留意的记录"
        default:     return "近期有高风险记录"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: monitor.isCapturing ? "eye" : "eye.slash")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("BigBrother").font(.system(size: 15 * fontScale, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(eyeColor(level: monitor.threatLevel,
                                       capturing: monitor.isCapturing))
                        .frame(width: 6, height: 6)
                    Text(monitor.isCapturing
                         ? Self.statusText(level: Double(monitor.threatLevel))
                         : monitor.hasStarted ? "监测已暂停" : "正在启动…")
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("退出")
                    .font(.system(size: 12 * fontScale))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("退出 BigBrother")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - 概览

struct OverviewTab: View {
    static let emptyContentMinHeight: CGFloat = 400

    @ObservedObject var monitor: Monitor
    @ScaledMetric(relativeTo: .body) private var fontScale = 1.0

    private let cols = [GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)]

    private var hasTodayRecords: Bool {
        !monitor.todaySubjects.isEmpty || !monitor.todayCounts.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            summary

            if !hasTodayRecords {
                Spacer(minLength: 0)
            }

            if !monitor.todaySubjects.isEmpty {
                Divider()
                sectionTitle("今日 App")
                ForEach(Array(monitor.todaySubjects.enumerated()), id: \.offset) { _, subj in
                    SubjectRow(identifier: subj.identifier, count: subj.n, worst: subj.worst) {
                        monitor.drillIntoSubject(subj.identifier)
                    }
                }
            }

            if !monitor.todayCounts.isEmpty {
                Divider()
                sectionTitle("权限")
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(PrivacyKind.allCases.filter(\.isCore), id: \.self) { k in
                        KindChip(kind: k, count: count(k)) { monitor.drillInto(kind: k) }
                    }
                }
                if monitor.todayCounts.contains(where: { !$0.kind.isCore && $0.n > 0 }) {
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(monitor.todayCounts.filter { !$0.kind.isCore }, id: \.kind) { item in
                            KindChip(kind: item.kind, count: item.n) {
                                monitor.drillInto(kind: item.kind)
                            }
                        }
                    }
                }
            }

            Divider()
            sectionTitle("近 24 小时")
            Sparkline(values: monitor.histogram, endingAt: monitor.histogramEnd)
        }
        .frame(maxWidth: .infinity,
               minHeight: hasTodayRecords ? nil : Self.emptyContentMinHeight,
               alignment: .topLeading)
    }

    @ViewBuilder
    private var summary: some View {
        let n = monitor.todaySubjects.count
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("今日").font(.system(size: 13 * fontScale, weight: .semibold))
                Spacer()
                Text("\(n) 个 App · \(monitor.todayTotal) 条访问记录")
                    .font(.system(size: 12 * fontScale))
                    .monospacedDigit()
            }
            Text(!monitor.isCapturing
                 ? (monitor.hasStarted
                    ? "监测已暂停，记录可能不完整。"
                    : "正在启动监测。")
                 : "基于系统日志；没有记录不代表没有访问。")
                .font(.system(size: 11 * fontScale))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func count(_ k: PrivacyKind) -> Int {
        monitor.todayCounts.first { $0.kind == k }?.n ?? 0
    }
}

/// 概览页主列表的一行:**一个 App**,不是一次权限调用。
private struct SubjectRow: View {
    let identifier: String
    let count: Int
    let worst: Int
    let action: () -> Void

    @State private var hovering = false

    private var entry: AppNames.Entry { AppNames.shared.lookup(identifier) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let img = entry.icon {
                    Image(nsImage: img).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 13))
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if let hint = entry.kind.hint {
                        Text(hint).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // 只有真的需要留意时才出现颜色。全是绿点等于没有点。
                if worst >= 4 {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
                Text("\(count) 条")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 「N 次访问被系统拦下」。
///
/// 措辞很重要:这**不是**在报警,而是在说系统正常工作了。
/// 「被拒尝试 N 次」听起来像出了事,实际上恰恰相反。
private struct DeniedNote: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 12)).foregroundStyle(.green)
                Text("系统拒绝了 \(count) 次权限请求")
                    .font(.system(size: 11))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.green.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 可点击的统计卡片
struct DrillCard: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color
    let hint: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
                    Text(title).font(.system(size: 10.5, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                Text("\(value)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(value > 0 ? tint : .secondary)
                Text(hint).font(.system(size: 8.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(hovering ? 0.18 : (value > 0 ? 0.10 : 0.05))))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 可点击的列表行(带 hover 反馈与箭头)
struct DrillRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct KindChip: View {
    let kind: PrivacyKind
    let count: Int
    var action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(kind.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 不引第三方图表库,手绘柱状图
struct Sparkline: View {
    let values: [Int]
    let endingAt: Date

    static func tickDates(endingAt: Date, hours: Int) -> [Date] {
        (0...4).map { endingAt.addingTimeInterval(-Double(4 - $0) * Double(hours) * 900) }
    }

    var body: some View {
        let maxV = max(values.max() ?? 0, 1)
        let ticks = Self.tickDates(endingAt: endingAt, hours: values.isEmpty ? 24 : values.count)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(v > 0 ? Color.accentColor : Color.secondary.opacity(0.18))
                        .frame(height: max(2, CGFloat(v) / CGFloat(maxV) * 42))
                        .help("\(Self.detailFormatter.string(from: endingAt.addingTimeInterval(-Double(values.count - index) * 3600))) 起 1 小时：\(v) 条相关记录")
                }
            }
            .frame(height: 44, alignment: .bottom)
            GeometryReader { geometry in
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, date in
                    let x = geometry.size.width * CGFloat(index) / 4
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 1, height: 4)
                        .position(x: x, y: 2)
                    Text(Self.timeFormatter.string(from: date))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42)
                        .position(x: min(max(x, 21), geometry.size.width - 21), y: 13)
                        .help(Self.detailFormatter.string(from: date))
                }
            }
            .frame(height: 22)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - 事件列表

struct EventsTab: View {
    @ObservedObject var monitor: Monitor
    @ScaledMetric(relativeTo: .body) private var fontScale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 下钻来源提示 + 可移除的筛选标签
            if !monitor.filter.isEmpty {
                HStack(spacing: 5) {
                    Button {
                        monitor.backToOverview()
                    } label: {
                        Label("概览", systemImage: "chevron.left")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    Text("›").font(.system(size: 10)).foregroundStyle(.tertiary)

                    Text("筛选").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("清除") { monitor.clearFilter() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                FlowChips(items: monitor.filter.chips) { clear in
                    var f = monitor.filter
                    clear(&f)
                    monitor.filter = f
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11 * fontScale)).foregroundStyle(.secondary)
                TextField("搜索记录", text: $monitor.filter.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * fontScale))
                    .help("搜索 App 标识符或记录内容")
                if !monitor.filter.search.isEmpty {
                    Button { monitor.filter.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Picker("类别", selection: $monitor.filter.scope) {
                        ForEach(EventScope.allCases, id: \.self) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .font(.system(size: 12 * fontScale))
                    Toggle(isOn: $monitor.filter.onlyHighRisk) {
                        Text("仅需留意").font(.system(size: 12 * fontScale))
                    }.toggleStyle(.checkbox)
                }

                HStack(spacing: 8) {
                    Menu {
                        Button("全部类型") { monitor.filter.kinds = [] }
                        Divider()
                        ForEach(PrivacyKind.allCases, id: \.self) { k in
                            Button {
                                if monitor.filter.kinds.contains(k) {
                                    monitor.filter.kinds.remove(k)
                                } else {
                                    monitor.filter.kinds.insert(k)
                                }
                            } label: {
                                Text((monitor.filter.kinds.contains(k) ? "✓ " : "   ") + k.label)
                            }
                        }
                    } label: {
                        Text(monitor.filter.kinds.isEmpty
                             ? "全部类型"
                             : "已选 \(monitor.filter.kinds.count) 类")
                            .font(.system(size: 12 * fontScale))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    if monitor.filter.actor != nil {
                        Button {
                            monitor.filter.actor = nil
                        } label: {
                            Text("清除 App 筛选").font(.system(size: 11 * fontScale))
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }

                    Spacer()
                    Text(monitor.hasMoreRecent
                         ? "已加载 \(monitor.recent.count) 条"
                         : "\(monitor.recent.count) 条")
                        .font(.system(size: 11 * fontScale)).foregroundStyle(.secondary)
                }
                DisclosureGroup("记录说明") {
                    Text("访问记录包括已授权访问与系统确认的活动；未获授权的权限查询、被拒或未知结果不计为访问。授权不代表实际读取了内容。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11 * fontScale))
            }

            Divider()
            if monitor.recent.isEmpty && monitor.isLoadingRecent {
                ProgressView("正在加载记录…")
            } else if monitor.recent.isEmpty {
                emptyHint(monitor.filter.onlyHighRisk
                          ? "暂无需留意的记录"
                          : "暂无符合条件的记录")
            } else {
                ForEach(monitor.recent) { e in
                    EventRow(event: e)
                    Divider().opacity(0.4)
                }
                if monitor.hasMoreRecent {
                    HStack {
                        Spacer()
                        Button(monitor.isLoadingRecent ? "正在加载…" : "加载更多") {
                            monitor.loadMoreRecent()
                        }
                        .disabled(monitor.isLoadingRecent)
                        Spacer()
                    }
                } else {
                    Text("已加载全部记录")
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 自动换行的筛选标签组
struct FlowChips: View {
    let items: [(label: String, clear: (inout DrillFilter) -> Void)]
    let onClear: ((inout DrillFilter) -> Void) -> Void

    var body: some View {
        // 面板宽度固定,hstack + 换行用简单的两行策略即可
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Text(item.label)
                        .font(.system(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
                    Button {
                        onClear(item.clear)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
    }
}

struct EventRow: View {
    let event: PrivacyEvent
    @ScaledMetric(relativeTo: .body) private var fontScale = 1.0
    @State private var isEvidenceNoteExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if event.affectsThreatLevel && event.severity >= 4 {
                Circle()
                    .fill(severityColor(event.severity))
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                    .accessibilityLabel("需留意")
            }

            // 真实 App 图标 —— 一行 SF Symbol 是所有行看起来都一样的根源
            subjectIcon

            VStack(alignment: .leading, spacing: 3) {
                // ── 第一行:谁 + 什么时候 ──
                HStack(spacing: 6) {
                    Text(subjectName)
                        .font(.system(size: 13 * fontScale, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Self.timeFmt.string(from: event.timestamp))
                        .font(.system(size: 10.5 * fontScale, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // ── 第二行:它对我做了什么(说人话)──
                Text(event.actionPhrase)
                    .font(.system(size: 12 * fontScale))
                    .foregroundStyle(.primary)

                Text(event.phase.rawValue == event.resultLabel
                     ? event.resultLabel
                     : "\(event.phase.rawValue) · \(event.resultLabel)")
                    .font(.system(size: 11 * fontScale))
                    .foregroundStyle(event.isDenied && event.phase != .permissionCheck
                                     ? Color.orange : .secondary)

                // ── 第三行:只有值得说的细节才出现 ──
                if !details.isEmpty || distinctExecutorName != nil {
                    VStack(alignment: .leading, spacing: 3) {
                        if let executorName = distinctExecutorName {
                            Text("执行程序：\(executorName)")
                            .font(.system(size: 11 * fontScale))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        if !details.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(details, id: \.self) { d in
                                    Text(d.text)
                                        .font(.system(size: 11 * fontScale))
                                        .foregroundStyle(d.warn ? Color.orange : .secondary)
                                }
                            }
                        }
                    }
                }
                if isEvidenceNoteExpanded, let note = event.evidenceNote {
                    Text(note)
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleEvidenceNote)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(isEvidenceNoteExpanded ? "收起证据说明" : "查看证据说明")) {
            toggleEvidenceNote()
        }
    }

    private func toggleEvidenceNote() {
        guard event.evidenceNote != nil else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            isEvidenceNoteExpanded.toggle()
        }
    }

    // MARK: 主角

    /// 展示的是**授权主体**,不是执行者
    private var subjectEntry: AppNames.Entry { AppNames.shared.lookup(event.subject?.identifier) }
    private var subjectName: String { subjectEntry.name }
    private var distinctExecutorName: String? {
        guard let executor = event.executor else { return nil }
        let name = AppNames.shared.name(executor.identifier)
        return name == subjectName ? nil : name
    }

    @ViewBuilder
    private var subjectIcon: some View {
        if let img = subjectEntry.icon {
            Image(nsImage: img)
                .resizable().frame(width: 18, height: 18)
                .padding(.top, 1)
        } else {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 12))
                .frame(width: 18, height: 18)
                .foregroundStyle(severityColor(event.severity))
                .padding(.top, 1)
        }
    }

    private struct Detail: Hashable {
        let text: String
        var warn = false
    }

    /// 只保留用户看得懂、且值得看的细节。
    /// 「日志 N 条」这类内部计数不再出现 —— 那是调试信息。
    private var details: [Detail] {
        var out: [Detail] = []

        // 证据强度:同样是「微信访问了屏幕画面」,系统只观察到授权查询、
        // 还是真的发起了采集请求,对用户的含义完全不同 —— 必须写清楚,
        // 否则就是在替 App 下结论。
        if let confidence = event.accessConfidenceLabel,
           confidence != event.resultLabel {
            out.append(Detail(text: confidence))
        }

        // 完整录制 / 持续时长
        if event.phase == .activity, let d = event.duration {
            out.append(Detail(text: String(format: "持续 %.1f 秒", d), warn: d >= 5))
        }

        // 屏幕事件必须区分「真实画面」和「只是窗口信息」——
        // 这是本产品最有价值的判断之一,不能省略
        if event.kind == .screenCapture, event.phase != .activity {
            out.append(Detail(text: event.channel == .replayd ? "涉及屏幕画面权限" : "涉及窗口信息权限"))
        }

        // 位置事件说明它不走 TCC(否则用户会以为漏报了)
        if event.kind == .location {
            out.append(Detail(text: "位置记录由 macOS 单独提供"))
        }
        return out
    }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()
}

// MARK: - 统计

struct StatsTab: View {
    @ObservedObject var monitor: Monitor
    @State private var exportMsg: String?
    @State private var exporting = false
    @State private var exportScope: EventScope = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("App 与执行程序")
            Text("权限归属不代表请求获准或已读取内容。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            if monitor.inheritance.isEmpty {
                emptyHint("暂无记录")
            } else {
                ForEach(Array(monitor.inheritance.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("关联 App：\(row.owner)")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8)).foregroundStyle(.secondary)
                            Text("执行程序：\(row.actor)")
                                .font(.system(size: 10))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(row.n)").font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3).padding(.horizontal, 7)
                    Divider()
                }
            }

            Divider()
            sectionTitle("导出")
            Picker("记录类别", selection: $exportScope) {
                ForEach(EventScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .disabled(exporting)
            HStack(spacing: 8) {
                Button("导出近 7 天记录…") { export() }
                    .font(.system(size: 11))
                    .disabled(exporting)
                if let m = exportMsg {
                    Text(m).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bigbrother-\(Self.stamp()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "选择访问记录的保存位置。"
        exporting = true
        monitor.isPresentingSystemDialog = true
        panel.begin { response in
            monitor.endSystemDialog()
            guard response == .OK, let url = panel.url else {
                exporting = false
                return
            }
            exportMsg = "正在保存…"
            let store = monitor.store
            let scope = exportScope
            DispatchQueue.global(qos: .utility).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let count = try store.exportCSV(to: url.path, scope: scope)
                    DispatchQueue.main.async {
                        exportMsg = "已保存 \(count) 条记录"
                        exporting = false
                    }
                } catch {
                    let message = "保存失败：\(error.localizedDescription) 请重新选择有写入权限的位置。"
                    DispatchQueue.main.async {
                        exportMsg = message
                        exporting = false
                    }
                }
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date())
    }
}

// MARK: - 设置

struct SettingsTab: View {

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "BigBrotherCommit") as? String ?? "未知"
    }

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "eye").font(.system(size: 22, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text("BigBrother").font(.system(size: 15, weight: .semibold))
                    Text("版本 \(version)").font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Link("GitHub 源码", destination: URL(string: "https://github.com/zjj/bigbrother")!)
            statement(title: "记录范围", body: """
                已授权的 App 也会记录，但仅限系统提供的证据。摄像头、麦克风和个人数据主要依赖权限调用日志；录屏活动仅覆盖可归因的系统录制日志。不能保证捕获每次截图、剪贴板读取或设备启停。没有记录不代表没有访问。
                """)
        }
    }

    private func statement(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12 * fontScale, weight: .semibold))
            Text(body)
                .font(.system(size: 11 * fontScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ObservedObject var monitor: Monitor
    @ScaledMetric(relativeTo: .body) private var fontScale = 1.0
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var requestingNotificationPermission = false
    @State private var showNotificationAlert = false
    @State private var notificationAlertMessage = ""
    @State private var notificationPermissionHint: String?
    @State private var ignoreBundleIdentifier = ""
    @State private var ignoreKind: PrivacyKind = .clipboard

    private var recentIgnoreApps: [(identifier: String, name: String)] {
        var seen = Set<String>()
        return monitor.recent.compactMap { event in
            guard let identifier = event.subject?.identifier,
                  seen.insert(identifier).inserted else { return nil }
            return (identifier, AppNames.shared.name(identifier))
        }.prefix(12).map { $0 }
    }

    private var canAddIgnoreRule: Bool {
        let identifier = ignoreBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return !identifier.isEmpty && !monitor.ignoredAppPermissions.contains {
            $0.bundleIdentifier == identifier && $0.kind == ignoreKind
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("监测与通知") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("状态颜色保留", selection: Binding(
                        get: { Int(monitor.threatWindow) },
                        set: { monitor.threatWindow = Double($0) })) {
                        Text("30 秒").tag(30)
                        Text("1 分钟").tag(60)
                        Text("5 分钟").tag(300)
                        Text("15 分钟").tag(900)
                    }
                    .font(.system(size: 12 * fontScale))

                    Toggle(isOn: Binding(
                        get: { monitor.notifyOnAlert },
                        set: setNotificationEnabled)) {
                        Text("高风险通知").font(.system(size: 12 * fontScale))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(requestingNotificationPermission)
                    .help("开启时 macOS 会询问是否允许通知；只在高风险访问时发送，不会为权限查询发通知。")
                    if requestingNotificationPermission {
                        Text("正在等待系统授权…").font(.system(size: 11 * fontScale))
                    } else if let hint = notificationPermissionHint {
                        Text(hint).font(.system(size: 11 * fontScale)).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("图标颜色说明") {
                        VStack(alignment: .leading, spacing: 5) {
                            legend(.red, "高风险", "命令行程序访问敏感权限")
                            legend(.orange, "需留意", "较高风险的权限访问")
                            legend(.yellow, "请关注", "屏幕画面等敏感权限的访问")
                            legend(.blue, "一般", "其他权限访问")
                        }
                        .padding(.top, 4)
                    }
                    .font(.system(size: 11 * fontScale))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            GroupBox("忽略规则") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("仅忽略后续记录，已有记录不受影响。")
                        .font(.system(size: 10.5 * fontScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        TextField("App Bundle ID", text: $ignoreBundleIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11 * fontScale, design: .monospaced))
                        Menu {
                            ForEach(recentIgnoreApps, id: \.identifier) { app in
                                Button("\(app.name) (\(app.identifier))") {
                                    ignoreBundleIdentifier = app.identifier
                                }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .help("从最近记录选择 App")
                        .disabled(recentIgnoreApps.isEmpty)
                    }

                    Picker("权限或活动", selection: $ignoreKind) {
                        ForEach(PrivacyKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .font(.system(size: 11 * fontScale))
                    if ignoreKind == .clipboard {
                        Text("剪贴板来源按内容变化时的前台 App 推测。")
                            .font(.system(size: 11 * fontScale))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Spacer()
                        Button {
                            monitor.addIgnoredAppPermission(
                                bundleIdentifier: ignoreBundleIdentifier, kind: ignoreKind)
                            ignoreBundleIdentifier = ""
                        } label: {
                            Label("添加规则", systemImage: "plus")
                        }
                        .disabled(!canAddIgnoreRule)
                    }

                    if monitor.ignoredAppPermissions.isEmpty {
                        emptyHint("尚未设置忽略规则")
                    } else {
                        ForEach(monitor.ignoredAppPermissions) { rule in
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(AppNames.shared.name(rule.bundleIdentifier)) · \(rule.kind.label)")
                                        .font(.system(size: 11 * fontScale, weight: .medium))
                                    Text(rule.bundleIdentifier)
                                        .font(.system(size: 9 * fontScale, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                Button {
                                    monitor.removeIgnoredAppPermission(rule)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .help("删除忽略规则")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            GroupBox("启动与数据") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $launchAtLogin) {
                        Text("登录时自动启动").font(.system(size: 12 * fontScale))
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { on in
                        let succeeded = LoginItem.setEnabled(on)
                        loginItemError = succeeded ? nil : LoginItem.lastError
                        launchAtLogin = LoginItem.isEnabled
                    }
                    if let error = loginItemError {
                        Text(error).font(.system(size: 11 * fontScale)).foregroundStyle(.red)
                    }
                    Picker("保留记录", selection: Binding(
                        get: { monitor.retentionDays },
                        set: { monitor.retentionDays = $0 })) {
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                        Text("180 天").tag(180)
                        Text("一直保留").tag(36500)
                    }
                    .font(.system(size: 12 * fontScale))

                    Text(monitor.store.path)
                        .font(.system(size: 10 * fontScale, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3).truncationMode(.middle)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Button("在访达中显示") {
                            NSWorkspace.shared.selectFile(monitor.store.path, inFileViewerRootedAtPath: "")
                        }.font(.system(size: 12 * fontScale))
                        Button("清空记录…") { confirmClearData() }
                            .font(.system(size: 12 * fontScale))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            DisclosureGroup("关于 BigBrother") {
                aboutPage
                    .padding(.top, 8)
            }

            DisclosureGroup("免责声明") {
                VStack(alignment: .leading, spacing: 12) {
                    statement(title: "仅供参考", body: """
                        BigBrother 根据系统提供的记录展示权限与活动信息。权限获准不代表实际读取了内容；风险颜色和提醒不代表相关 App 存在恶意行为，不应作为认定违规或追究责任的唯一依据。
                        """)
                    statement(title: "记录可能不完整", body: """
                        系统版本、日志可用性及程序运行状态都可能影响记录的完整性和准确性，可能出现漏记、延迟或误判。没有记录或提醒不代表没有访问，也不代表设备安全。
                        """)
                    statement(title: "不提供安全保证", body: """
                        本工具用于辅助了解系统活动，不负责拦截访问，也不保证发现所有隐私或安全风险。请结合 macOS 权限设置及其他安全措施自行核实，并谨慎处理、分享导出的记录。
                        """)
                }
                .padding(.top, 8)
            }
        }
        .onAppear(perform: checkNotificationPermission)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkNotificationPermission()
        }
        .alert("无法开启通知", isPresented: $showNotificationAlert) {
            Button("打开系统设置") {
                monitor.endSystemDialog(restoringFocus: false)
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    if !NSWorkspace.shared.open(url) {
                        Diagnostics.log("[通知] 无法打开系统设置")
                        notificationPermissionHint = "请手动打开系统设置，在“通知”中找到 BigBrother。"
                        monitor.requestFocus?()
                    }
                }
            }
            Button("取消", role: .cancel) { monitor.endSystemDialog() }
        } message: {
            Text(notificationAlertMessage)
        }
        .onChange(of: showNotificationAlert) { presented in
            if !presented { monitor.endSystemDialog() }
        }
    }

    /// 清空全部记录前的确认。
    ///
    /// 这里刻意用 NSAlert 而不是 SwiftUI 的 `confirmationDialog`:
    /// 后者在菜单栏面板(NSPanel + 失焦即收起)上会让面板先被收起来,
    /// 用户得再点一次图标才能看到界面 —— 也就是「点清空、界面消失」。
    /// 走和「高风险通知」同一条路径就不会:先声明正在展示系统对话框,
    /// 收起逻辑会让路;关掉之后再恢复面板焦点。
    private func confirmClearData() {
        // 走 withSystemDialog:弹窗期间面板不会因为失焦被收起。
        let confirmed = monitor.withSystemDialog { () -> Bool in
            let alert = NSAlert()
            alert.messageText = "确定删除所有记录？"
            alert.informativeText = "删除后无法恢复，只影响本机保存的记录。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "删除记录")
            alert.addButton(withTitle: "取消")
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed == true else { return }
        monitor.store.clearAll()
        monitor.refresh()
    }

    private func setNotificationEnabled(_ enabled: Bool) {
        guard !requestingNotificationPermission else { return }
        guard enabled else {
            monitor.notifyOnAlert = false
            return
        }

        requestingNotificationPermission = true
        monitor.isPresentingSystemDialog = true
        Notifier.requestAuthorization { result in
            DispatchQueue.main.async {
                requestingNotificationPermission = false
                monitor.requestFocus?()
                switch result {
                case .authorized:
                    monitor.notifyOnAlert = true
                    notificationPermissionHint = nil
                    monitor.endSystemDialog()
                case .denied:
                    monitor.notifyOnAlert = false
                    notificationAlertMessage = "BigBrother 目前没有发送通知的权限。请在系统设置的“通知”中找到 BigBrother 并允许通知。"
                    showNotificationAlert = true
                case .alertsDisabled:
                    monitor.notifyOnAlert = false
                    notificationAlertMessage = "请在系统设置的“通知”中找到 BigBrother，打开“允许通知”，并选择横幅或提醒。"
                    showNotificationAlert = true
                case .unavailable:
                    monitor.notifyOnAlert = false
                    notificationAlertMessage = "现在无法请求通知权限，请确认 BigBrother 已正确安装后再试。"
                    showNotificationAlert = true
                }
            }
        }
    }

    private func checkNotificationPermission() {
        guard !requestingNotificationPermission else { return }
        Notifier.authorizationStatus { status in
            DispatchQueue.main.async {
                guard !requestingNotificationPermission else { return }
                switch status {
                case .authorized:
                    notificationPermissionHint = nil
                case .denied, .alertsDisabled:
                    notificationPermissionHint = "系统通知未开启。开启此功能时，可以前往系统设置允许通知。"
                case .unavailable:
                    notificationPermissionHint = "首次开启此功能时，会向 macOS 申请通知权限。"
                }
            }
        }
    }
}

// MARK: - 小组件

struct SectionTitle: View {
    let title: String
    @ScaledMetric(relativeTo: .body) private var fontSize = 12.0

    var body: some View {
        Text(title).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(.secondary)
    }
}

func sectionTitle(_ s: String) -> some View {
    SectionTitle(title: s)
}

/// 眼睛颜色图例
func legend(_ color: Color, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 7) {
        Circle().fill(color).frame(width: 8, height: 8).padding(.top, 3)
        Text(title)
            .font(.system(size: 10.5, weight: .medium))
            .frame(width: 54, alignment: .leading)
        Text(detail)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
    }
}

func emptyHint(_ s: String) -> some View {
    Text(s).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
}

func iconFor(_ identifier: String) -> String {
    if identifier.hasPrefix("com.apple.") { return "apple.logo" }
    if identifier.hasPrefix("bash-") || identifier.hasPrefix("sh-")
        || identifier.hasPrefix("zsh-") { return "terminal" }
    if !identifier.contains(".") { return "gearshape.2" }
    return "app"
}
