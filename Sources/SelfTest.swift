import Foundation
import AppKit

/// 命令行自检:不需要 GUI 就能验证「解析 → 判定 → 会话折叠 → 落库 → 聚合」整条链路。
/// 这是本项目能在没有图形会话的环境里被验证的关键。
enum SelfTest {

    struct Parsed {
        var events: [PrivacyEvent] = []
        var durations: [(pid: Int, startedAt: Date, seconds: Double)] = []
        var starts: [(pid: Int, timestamp: Date)] = []
    }

    static func parse(files: [String]) -> Parsed {
        let parser = TCCParser()
        let locParser = LocationParser()
        var result = Parsed()
        parser.onEvent = { result.events.append($0) }
        locParser.onEvent = { result.events.append($0) }
        parser.onDuration = {
            result.durations.append((pid: $0, startedAt: $1, seconds: $2))
        }
        parser.onRecordingStart = { pid, timestamp, _ in
            result.starts.append((pid, timestamp))
        }

        for f in files {
            guard let content = try? String(contentsOfFile: f, encoding: .utf8) else {
                FileHandle.standardError.write("无法读取 \(f)\n".data(using: .utf8)!)
                continue
            }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let l = String(line)
                parser.feed(l)
                locParser.feed(l)
            }
        }
        parser.flushStale(olderThan: 0)     // 排空未闭合的事件
        return result
    }

    // MARK: 只解析并打印

    static func run(files: [String]) -> Int32 {
        guard !files.isEmpty else {
            print("用法: BigBrother --selftest <日志文件>...")
            return 1
        }
        let parsed = parse(files: files)
        let events = parsed.events
        print("解析到原始事件 \(events.count) 条")

        var byKind: [PrivacyKind: Int] = [:]
        for e in events { byKind[e.kind, default: 0] += 1 }
        for (k, n) in byKind.sorted(by: { $0.value > $1.value }) {
            print("  \(k.label): \(n)")
        }

        print("\n前 10 条:")
        for e in events.prefix(10) {
            print(String(format: "  %@  [%@]  %@  (%@)",
                         EventStore.fmt.string(from: e.timestamp),
                         Judge.severityLabel(e.severity),
                         e.actorName, e.channel.label))
        }
        return 0
    }

    // MARK: 解析 + 落库 + 聚合(端到端)

    static func scan(files: [String]) -> Int32 {
        guard !files.isEmpty else {
            print("用法: BigBrother --scan <日志文件>...")
            return 1
        }
        let store = EventStore()
        print("数据库: \(store.path)\n")

        let parsed = parse(files: files)
        let events = parsed.events
        var mergedCount = 0
        var ignoredCount = 0
        var failedCount = 0
        for e in events {
            let result = store.insert(e)
            if result.ignored {
                ignoredCount += 1
            } else if result.merged {
                mergedCount += 1
            } else if result.id == 0 {
                failedCount += 1
            }
        }
        if failedCount > 0 {
            print("记录写入失败 \(failedCount) 条：\(store.storageError ?? "未知原因")")
            return 1
        }

        var promotedCount = 0
        for start in parsed.starts {
            if store.recordingStarted(pid: start.pid, at: start.timestamp, actor: nil) != nil {
                promotedCount += 1
            }
        }
        for d in parsed.durations {
            if store.annotateDuration(pid: d.pid, startedAt: d.startedAt, seconds: d.seconds) != nil {
                promotedCount += 1
            }
        }
        if let error = store.storageError {
            print("记录写入失败：\(error)")
            return 1
        }

        print("══════════════════════════════════════════════════════")
        print(" BigBrother · 审计结果")
        print("══════════════════════════════════════════════════════")
        print("原始日志事件 : \(events.count) 条")
        print("折叠掉重复   : \(mergedCount) 条(同一采集会话)")
        print("忽略系统等记录: \(ignoredCount) 条")
        print("录屏活动补记 : \(promotedCount) 条")
        print("入库事件     : \(events.count - mergedCount - ignoredCount + promotedCount) 条")
        print("累计总数     : \(store.totalCount()) 条")
        print("今日总数     : \(store.todayTotal()) 条")
        print("24h 高危     : \(store.highSeverityCount()) 条")

        print("\n── 今日按类型 ──")
        for (k, n) in store.todayCounts() {
            print(String(format: "  %-16@ %4d", k.label as NSString, n))
        }

        print("\n── 最活跃进程(7 天)──")
        for (name, n) in store.topActors() {
            print(String(format: "  %4d  %@", n, String(name.prefix(58)) as NSString))
        }

        print("\n── 继承链审计(实际使用者 ≠ 授权主体)──")
        let inh = store.inheritanceReport()
        if inh.isEmpty { print("  未发现") }
        for r in inh {
            print(String(format: "  %4d  %@", r.n, String(r.owner.prefix(40)) as NSString))
            print("        └─ 实际由 \(String(r.actor.prefix(56))) 执行")
        }

        print("\n── 采集时长(持续录屏)──")
        let durs = store.recordingDurations()
        if durs.isEmpty {
            print("  未捕获到持续采集")
        } else {
            for d in durs {
                print(String(format: "  %6.2f 秒   %@", d.seconds,
                             String(d.actor.prefix(50)) as NSString))
            }
        }

        print("\n── 最近 15 条 ──")
        for e in store.recentEvents(limit: 15) {
            print(String(format: "  %@ [%@] %@",
                         EventStore.fmt.string(from: e.timestamp),
                         Judge.severityLabel(e.severity) as NSString,
                         e.actorName as NSString))
            print("        \(e.kind.label) · \(e.channel.label) · 日志 \(e.logCount) 条")
            print("        \(e.reason)")
        }
        print()
        return 0
    }

    // MARK: 菜单栏图标自检
    //
    // 开发时踩过的坑:NSStatusBarButton.contentTintColor 作用在模板图上时,
    // 会被菜单栏的明暗主题覆盖,颜色根本不生效 —— 而且不报任何错,
    // 代码看着是对的,菜单栏上就是不变色。
    // 所以这里直接对合成出来的位图采样,用像素证明颜色确实写进去了。
    static func iconTest() -> Int32 {
        print("BigBrother 菜单栏图标自检")
        print("══════════════════════════════════════════════════════════════")
        print(pad("状态", 10) + pad("等级", 6) + pad("预期颜色", 16)
              + pad("采样像素", 20) + "TEMPLATE")
        print("──────────────────────────────────────────────────────────────")

        var allOK = true
        for level in 0...5 {
            guard let img = IconFactory.eye(stopped: false, level: level),
                  let px = IconFactory.dominantPixel(img) else {
                print("等级 \(level): 图标生成失败"); allOK = false; continue
            }
            let ok = matches(r: px.r, g: px.g, b: px.b,
                             color: IconFactory.nsColor(for: level))
            if !ok { allOK = false }
            print(pad("监视中", 10) + pad("\(level)", 6)
                  + pad(IconFactory.colorName(for: level), 16)
                  + pad("(\(px.r),\(px.g),\(px.b) a\(px.a))", 20)
                  + (img.isTemplate ? "是" : "否") + "  " + (ok ? "✓" : "✗ 不符"))
        }

        if let img = IconFactory.eye(stopped: true, level: 0),
           let px = IconFactory.dominantPixel(img) {
            let ok = matches(r: px.r, g: px.g, b: px.b, color: .systemRed)
            if !ok { allOK = false }
            print(pad("中断", 10) + pad("-", 6) + pad("红色 · 采集中断", 16)
                  + pad("(\(px.r),\(px.g),\(px.b) a\(px.a))", 20)
                  + (img.isTemplate ? "是" : "否") + "  " + (ok ? "✓" : "✗ 不符"))
        }

        print("──────────────────────────────────────────────────────────────")
        if allOK {
            print("✓ 变色等级全部通过:非模板彩色位图,颜色确实写进了像素")
        } else {
            print("✗ 存在不符合预期的等级")
        }

        // 淡出插值:连续等级的中间色应当是平滑渐变,而不是跳变
        print("\n【淡出插值】displayedLevel 从 5 缓慢回落到 2 时经过的颜色")
        print(pad("等级", 8) + pad("采样像素", 20) + "形态")
        print("  " + String(repeating: "·", count: 44))
        for lv in [5.0, 4.5, 4.0, 3.5, 3.0, 2.5, 2.0] {
            guard let img = IconFactory.eye(stopped: false, level: lv),
                  let px = IconFactory.dominantPixel(img) else { continue }
            print(pad(String(format: "%.1f", lv), 8)
                  + pad("(\(px.r),\(px.g),\(px.b))", 20)
                  + (img.isTemplate ? "模板(跟随主题)" : "着色"))
        }

        print("──────────────────────────────────────────────────────────────")
        return allOK ? 0 : 1
    }

    /// 判断采样色与期望色是否同调(比较主导通道,允许亮度差异)
    private static func matches(r: Int, g: Int, b: Int, color: NSColor?) -> Bool {
        func dominant(_ x: Int, _ y: Int, _ z: Int) -> Int {
            if x >= y && x >= z { return 0 }
            if y >= x && y >= z { return 1 }
            return 2
        }
        guard let color else {
            // 期望「不染色」:应当接近中性灰(模板图是黑或白)
            return (max(r, max(g, b)) - min(r, min(g, b))) <= 12
        }
        // 目录色(System Yellow 之类)必须先转到具体色彩空间才能读分量,
        // 否则直接读 redComponent 会抛 NSInvalidArgumentException。
        let c = color.usingColorSpace(.sRGB) ?? color
        return dominant(r, g, b) == dominant(Int(c.redComponent * 255),
                                             Int(c.greenComponent * 255),
                                             Int(c.blueComponent * 255))
    }

    // MARK: 下钻一致性自检
    //
    // 核心不变量:**下钻看到的明细行数,必须等于概览上的聚合数字。**
    // 两者不一致时,用户点进去会觉得「概览在骗我」——而这是最难发现的一类 bug,
    // 因为两个界面各自看都正常。
    static func drillTest(files: [String]) -> Int32 {
        let store = EventStore()
        let parsed = parse(files: files)
        for e in parsed.events {
            store.insert(e)
        }
        for d in parsed.durations {
            _ = store.annotateDuration(pid: d.pid, startedAt: d.startedAt, seconds: d.seconds)
        }

        print("BigBrother 下钻一致性自检")
        print("══════════════════════════════════════════════════════════════")
        print(" 不变量:下钻明细行数 == 概览聚合数字")
        print("──────────────────────────────────────────────────────────────")

        var allOK = true
        let big = 5_000_000   // 合成数据可能上百万行,上限要够大

        // 分类由类型计数推导 —— todayCategoryCounts 已经删掉,
        // 因为它和 todayCounts 本来就是同一个查询
        let todayByKind = store.todayCounts()
        var catAgg: [PrivacyCategory: Int] = [:]
        for (k, n) in todayByKind { catAgg[k.category, default: 0] += n }
        let todayByCategory = PrivacyCategory.allCases
            .compactMap { c in catAgg[c].map { (c, $0) } }
            .sorted { $0.1 > $1.1 }

        // 1) 按权限类型
        print("\n【按权限类型下钻】")
        var kindSum = 0
        let today = Calendar.current.startOfDay(for: Date())
        for (kind, n) in todayByKind {
            let rows = store.recentEvents(limit: big, kinds: [kind], since: today).count
            kindSum += n
            let ok = (rows == n)
            if !ok { allOK = false }
            print("  \(pad(kind.label, 16)) 概览 \(pad("\(n)", 6)) 下钻 \(pad("\(rows)", 6)) \(ok ? "✓" : "✗")")
        }

        // 2) 按进程
        print("\n【按进程下钻】")
        for (name, n) in store.topActors(limit: 6) {
            let rows = store.recentEvents(limit: big, actor: name,
                                          since: Date().addingTimeInterval(-7 * 86400)).count
            let ok = (rows == n)
            if !ok { allOK = false }
            print("  \(pad(String(name.prefix(28)), 30)) 概览 \(pad("\(n)", 6)) 下钻 \(pad("\(rows)", 6)) \(ok ? "✓" : "✗")")
        }

        // 3) 被拒尝试
        print("\n【被拒尝试下钻】")
        let dn = store.deniedCount()
        let dnRows = store.recentEvents(limit: big, onlyDenied: true,
                                        since: Date().addingTimeInterval(-7 * 86400)).count
        let dnOK = (dn == dnRows)
        if !dnOK { allOK = false }
        print("  \(pad("被拒尝试", 16)) 概览 \(pad("\(dn)", 6)) 下钻 \(pad("\(dnRows)", 6)) \(dnOK ? "✓" : "✗")")

        // 4) 分类 = 其下各类型之和
        print("\n【分类下钻(应等于其下各类型之和)】")
        for (cat, n) in todayByCategory {
            let kinds = Set(PrivacyKind.allCases.filter { $0.category == cat })
            let rows = store.recentEvents(limit: big, kinds: kinds, since: today).count
            let ok = (rows == n)
            if !ok { allOK = false }
            print("  \(pad(cat.label, 16)) 概览 \(pad("\(n)", 6)) 下钻 \(pad("\(rows)", 6)) \(ok ? "✓" : "✗")")
        }

        // 5) 全量:分类之和 == 今日总数
        let total = store.todayTotal()
        let catSum = todayByCategory.reduce(0) { $0 + $1.1 }
        let totOK = (kindSum == total && catSum == total)
        if !totOK { allOK = false }
        print("\n【总量守恒】")
        print("  今日总数 \(total) · 类型之和 \(kindSum) · 分类之和 \(catSum)  \(totOK ? "✓" : "✗")")

        print("──────────────────────────────────────────────────────────────")
        print(allOK
              ? "✓ 全部一致:下钻明细与概览聚合完全对得上"
              : "✗ 存在不一致 —— 下钻会显示与概览不同的数字")
        return allOK ? 0 : 1
    }

    // MARK: 标识符解析自检

    /// 把数据库里真实出现过的标识符挨个解析一遍,人工检查有没有
    /// 「一串哈希糊在脸上」这种没翻译干净的情况。
    ///
    /// 这条锁守的是产品气质:界面上出现 `com.googlecode.iterm2` 或
    /// `bash-55554944a8fef82d…` 就是调试产品,用户会觉得自己不该看这个界面。
    static func namesTest() -> Int32 {
        print("BigBrother 标识符解析自检")
        print(String(repeating: "─", count: 70))
        let store = EventStore()
        let rows = store.recentEvents(limit: 200_000)
        guard !rows.isEmpty else {
            print("数据库中暂无事件,先让它运行一会儿再试")
            return 0
        }
        var seen = Set<String>()
        var pairs: [(String, AppNames.Entry)] = []
        for e in rows {
            for id in [e.accessing?.identifier, e.responsible?.identifier] {
                guard let id, !id.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                pairs.append((id, AppNames.shared.lookup(id)))
            }
        }
        pairs.sort { $0.0 < $1.0 }

        var untranslated = 0
        print("  \(pad("原始标识符", 48))\(pad("显示名", 22))类型")
        print(String(repeating: "─", count: 70))
        for (raw, e) in pairs {
            var tag: String
            switch e.kind {
            case .app:     tag = "App"
            case .script:  tag = "脚本"
            case .system:  tag = "系统"
            case .unknown: tag = "未识别"
            }
            // 判据:显示名不能还是那串原始标识符(含点号 = 还是 bundle id)
            let stillRaw = (e.name == raw || e.name.contains("."))
            if stillRaw { untranslated += 1; tag = "仍是原始串" }
            print("  \(pad(raw, 48))\(pad(e.name, 22))\(tag)")
        }
        print(String(repeating: "─", count: 70))
        print("共 \(pairs.count) 个标识符,未识别 \(untranslated) 个")
        if untranslated == 0 {
            print("✓ 全部标识符都解析成了人能读懂的名字")
        } else {
            print("✗ 有 \(untranslated) 个仍是一串原始标识符 —— 用户看不懂")
        }
        return untranslated == 0 ? 0 : 1
    }

    // MARK: 文案预览

    /// 把事件列表默认收起状态下的文案以文本打印出来。
    ///
    /// 为什么需要这个:文案改动没法靠读代码评审,而界面又截不了图。
    /// 有了它,每一句话都能逐条看、逐条改。
    static func preview() -> Int32 {
        let store = EventStore()
        let rows = store.recentEvents(limit: 22)
        guard !rows.isEmpty else {
            print("数据库中暂无事件")
            return 0
        }
        print("BigBrother 事件列表文案预览(共取 \(rows.count) 条)")
        print(String(repeating: "═", count: 72))
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm:ss"
        for e in rows {
            let subj = AppNames.shared.lookup(e.subject?.identifier)
            print("")
            print("  ● \(subj.name)                          \(timeFmt.string(from: e.timestamp))")
            print("      \(e.actionPhrase)")
            print("      \(e.phase.rawValue) · \(e.resultLabel)")
            if let ex = e.executor {
                print("      实际由 \(AppNames.shared.name(ex.identifier)) 执行")
            }
            if e.phase == .activity, let d = e.duration {
                print(String(format: "      持续 %.1f 秒", d))
            }
            if e.kind == .location {
                print("      位置不走系统权限界面")
            }
        }
        print("")
        print(String(repeating: "═", count: 72))
        print("以上为界面默认收起状态下的内容(不含图标)。原始标识符已被翻译,内部计数已移除。")
        return 0
    }

    // MARK: 服务覆盖率自检
    //
    // 扫描日志里出现过的**所有** kTCCService*,列出哪些会被 PrivacyKind 认识、
    // 哪些会走兜底、哪些连服务名也无法识别。服务识别不等于实际使用。
    //
    // 写这个是因为踩过坑:kTCCServiceAudioCapture 曾经不在列表里,
    // 于是音频录制事件被静默丢掉 —— 界面上完全看不出来。
    // 少数据比多数据危险得多。
    /// 只跑定位通道:定位不走 TCC,单独一条管线,单独一个诊断入口。
    static func locationScan(files: [String]) -> Int32 {
        guard !files.isEmpty else {
            print("用法: BigBrother --locscan <日志文件>...")
            return 1
        }
        let parser = LocationParser()
        var events: [PrivacyEvent] = []
        parser.onEvent = { events.append($0) }
        for f in files {
            guard let content = try? String(contentsOfFile: f, encoding: .utf8) else {
                FileHandle.standardError.write("无法读取 \(f)\n".data(using: .utf8)!)
                continue
            }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                parser.feed(String(line))
            }
        }
        parser.flush()

        var byClient: [String: (n: Int, sev: Int)] = [:]
        for e in events {
            let id = e.accessing?.identifier ?? "?"
            let current = byClient[id] ?? (0, 0)
            byClient[id] = (current.n + 1, max(current.sev, e.severity))
        }
        print("BigBrother 定位通道自检")
        print("══════════════════════════════════════════════════════════════")
        print(" 解析出定位使用 \(events.count) 条,涉及 \(byClient.count) 个 App")
        print(" 跳过苹果系统位置组件 \(parser.skippedSystemClients) 条(不是 App,不进记录)\n")
        for (id, v) in byClient.sorted(by: { $0.value.sev != $1.value.sev
            ? $0.value.sev > $1.value.sev : $0.value.n > $1.value.n }) {
            print(String(format: "  [%@] %@ ×%d", Judge.severityLabel(v.sev), id, v.n))
        }
        return 0
    }

    static func coverageTest(files: [String]) -> Int32 {
        let re = try! NSRegularExpression(pattern: #"service=(kTCCService\w+)"#)
        var seen: [String: Int] = [:]

        for f in files {
            guard let content = try? String(contentsOfFile: f, encoding: .utf8) else {
                FileHandle.standardError.write("无法读取 \(f)\n".data(using: .utf8)!)
                continue
            }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                guard s.contains("service=kTCCService") else { continue }
                let ns = s as NSString
                for m in re.matches(in: s, range: s.fullRange) {
                    let svc = ns.substring(with: m.range(at: 1))
                    seen[svc, default: 0] += 1
                }
            }
        }

        print("BigBrother 服务覆盖率自检")
        print("══════════════════════════════════════════════════════════════")
        print(" 扫描到 \(seen.count) 种不同的 TCC 服务\n")

        var dropped: [String] = []
        var fallback: [String] = []
        var known: [(String, String)] = []

        for (svc, n) in seen.sorted(by: { $0.value > $1.value }) {
            switch PrivacyKind.from(service: svc) {
            case nil:
                dropped.append("\(svc) (×\(n))")
            case .other:
                fallback.append("\(svc) (×\(n))")
            case .some(let k):
                known.append(("\(k.label) — \(svc) ×\(n)", k.category.label))
            }
        }

        print("【已明确识别】\(known.count) 种")
        for (d, cat) in known { print("  ✓ [\(cat)] \(d)") }

        if !fallback.isEmpty {
            print("\n【走兜底(other),保留证据但不计入使用统计】\(fallback.count) 种")
            for d in fallback { print("  ○ \(d)") }
        }

        if !dropped.isEmpty {
            print("\n【会被丢弃 —— 这是 bug】\(dropped.count) 种")
            for d in dropped { print("  ✗ \(d)") }
        }

        print("──────────────────────────────────────────────────────────────")
        if dropped.isEmpty {
            print("✓ 所有服务名可被识别并保留证据；已授权的访问才计入使用")
        } else {
            print("✗ 有 \(dropped.count) 种服务会被静默丢弃")
        }

        // 反向检查:我们自己声明的类型里,有没有谁从未在真实日志中出现过?
        //
        // 这一条是为了防「编造权限类型」。曾经把 iOS 的 locationAlways 类推到
        // macOS 上,还在核心区永久显示 0 —— 编造一个类型比少一个类型糟糕得多。
        // 核心权限必须是实测存在的;非核心的可以只是推测,但要显式列出来。
        print("\n【反向检查】声明了却从未在日志中出现的类型")
        let declared = PrivacyKind.allCases.filter { $0 != .other }
        // clipboard 和 location 不走 TCC,日志里没有 service=kTCCService… 字段,
        // 所以不能拿这个集合去判断它们 —— 它们各有自己的采集通道。
        let nonTCCChannels: Set<PrivacyKind> = [.clipboard, .location]
        let unobserved = declared.filter {
            seen[$0.rawValue] == nil && !nonTCCChannels.contains($0)
        }
        let coreBad = unobserved.filter { $0.isCore }
        if unobserved.isEmpty {
            print("  ✓ 全部类型都在日志中被实际观测到")
        } else {
            for k in unobserved {
                print("  \(k.isCore ? "✗ 核心" : "○ 推测")  \(k.label)  (\(k.rawValue))")
            }
        }
        if !coreBad.isEmpty {
            print("  ✗ 核心权限里有 \(coreBad.count) 个从未被观测到 —— 不该放在核心区")
        }

        // 归因规则回归检查
        //
        // 这里守住的是一个曾经真实发生过的 bug:attribution 里缺少 accessing 时,
        // 旧规则一律丢弃,于是「App 直接申请自己权限」这一整类事件(摄像头、麦克风、
        // 通讯录、输入监控)全部消失。摄像头因此在界面上完全看不见。
        let reAttr = try! NSRegularExpression(pattern: #"AUTHREQ_ATTRIBUTION: msgID=([\w.]+)"#)
        let reAcc = try! NSRegularExpression(
            pattern: #"accessing=\{TCCDProcess: identifier=([^,]+)"#)
        let reReq = try! NSRegularExpression(
            pattern: #"requesting=\{TCCDProcess: identifier=([^,]+)"#)

        var retained = 0, discarded = 0
        var retainedActors: Set<String> = []
        for f in files {
            guard let content = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                guard s.contains("AUTHREQ_ATTRIBUTION"), reAttr.firstMatch(
                        in: s, range: s.fullRange) != nil else { continue }
                let ns = s as NSString
                if reAcc.firstMatch(in: s, range: s.fullRange) != nil { continue }  // 有 accessing
                guard let rm = reReq.firstMatch(in: s, range: s.fullRange) else { continue }
                let req = ns.substring(with: rm.range(at: 1))
                if TCCParser.mediators.contains(req) {
                    discarded += 1
                } else {
                    retained += 1
                    retainedActors.insert(req)
                }
            }
        }
        print("\n【归因规则】attribution 缺少 accessing 时")
        print("  保留(App 直接申请自己的权限): \(retained) 条,涉及 \(retainedActors.count) 个进程")
        for a in retainedActors.sorted().prefix(6) { print("      · \(a)") }
        print("  丢弃(WindowServer / sandboxd / tccd 中介的内部检查): \(discarded) 条")

        print("──────────────────────────────────────────────────────────────")
        if dropped.isEmpty {
            return 0
        }
        return 1
    }

    /// 按显示宽度补齐(中文算 2 列)
    private static func pad(_ s: String, _ n: Int) -> String {
        let w = s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2000 ? 2 : 1) }
        return s + String(repeating: " ", count: max(1, n - w))
    }
}
