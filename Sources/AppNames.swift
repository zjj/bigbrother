import AppKit

/// 把日志里的裸标识符解析成**人能读懂的名字和图标**。
///
/// ── 为什么这是产品化的第一步 ────────────────────────────────────────
/// 之前界面上直接显示的是:
///
///     com.googlecode.iterm2
///     bash-55554944a8fef82db6133d58943d0b342fdd6340
///     com.apple.WorkflowKit.BackgroundShortcutRunner
///
/// 用户不认识这些东西,而且一看到就会觉得自己不该打开这个界面 ——
/// 这是最典型的「调试产品」气质的来源。名字必须在这里被翻译一次,
/// 而不是指望用户去查。
final class AppNames {

    static let shared = AppNames()

    enum Kind {
        case app        // 正常 App
        case script     // 裸可执行文件 / 脚本(继承来的权限)
        case system     // Apple 系统组件
        case unknown

        var hint: String? {
            switch self {
            case .script: return "脚本"
            case .system: return "系统"
            default:      return nil
            }
        }
    }

    struct Entry {
        let name: String
        let icon: NSImage?
        let kind: Kind
        /// 原始标识符,需要时可在详情里查到
        let raw: String
    }

    private var cache: [String: Entry] = [:]

    private init() {}

    // MARK: 查询

    func lookup(_ identifier: String?) -> Entry {
        guard let identifier, !identifier.isEmpty else {
            return Entry(name: "未知来源", icon: nil, kind: .unknown, raw: "")
        }
        if let hit = cache[identifier] { return hit }
        let e = resolve(identifier)
        cache[identifier] = e
        return e
    }

    /// 显示名(最常用)
    func name(_ identifier: String?) -> String { lookup(identifier).name }

    // MARK: 解析

    private func resolve(_ id: String) -> Entry {
        // 1) 我们自己的固定说法。系统守护进程在 LaunchServices 里查不到,
        //    而它们的原始名字(routined / corespotlightd)对用户毫无意义。
        if let friendly = Self.manual[id] {
            return Entry(name: friendly.0, icon: Self.symbolIcon(friendly.1),
                         kind: friendly.2, raw: id)
        }

        // 2) 脚本 / 裸可执行文件:TCC 里以「名字-<hash>」的形式出现,
        //    例如 bash-55554944a8fef82d…。这类恰恰是最值得警惕的(继承来的权限),
        //    所以要给出明确的说法而不是那串哈希。
        if let base = Self.scriptBaseName(id) {
            return Entry(name: base, icon: Self.symbolIcon("terminal"),
                         kind: .script, raw: id)
        }

        // 2.5) 辅助进程:com.netease.163music.helper.gpu 这类。
        //      它们本身没有 App 身份,单独显示「gpu」「renderer」毫无意义 ——
        //      必须归到它所属的那个 App 名下。
        if let parentID = Self.helperParent(id) {
            let parent = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parentID)
            let parentName: String
            var icon: NSImage? = Self.symbolIcon("gearshape.2")
            if let url = parent {
                let b = Bundle(url: url)
                parentName = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? FileManager.default.displayName(atPath: url.path)
                let i = NSWorkspace.shared.icon(forFile: url.path)
                i.size = NSSize(width: 32, height: 32)
                icon = i
            } else {
                parentName = Self.prettify(parentID)
            }
            return Entry(name: "\(parentName)的辅助进程", icon: icon,
                         kind: parentID.hasPrefix("com.apple.") ? .system : .app, raw: id)
        }

        // 3) 正常 App:交给 LaunchServices 找,顺便拿真实图标
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let bundle = Bundle(url: url)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? FileManager.default.displayName(atPath: url.path)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            let isSys = id.hasPrefix("com.apple.")
            return Entry(name: name, icon: icon, kind: isSys ? .system : .app, raw: id)
        }

        // 4) 兜底:至少把 Bundle ID 的最后一段拿出来,别把整串糊在脸上。
        //    「helper」「extension」这种太笼统,补上它属于谁。
        var fallback = Self.prettify(id)
        if ["helper", "extension", "agent", "service"].contains(fallback.lowercased()) {
            let owner = id.split(separator: ".").dropLast().last.map(String.init) ?? ""
            if !owner.isEmpty { fallback = "\(owner) 的\(fallback)" }
        }
        return Entry(name: fallback, icon: Self.symbolIcon("app.dashed"),
                     kind: id.hasPrefix("com.apple.") ? .system : .unknown, raw: id)
    }

    /// 「bash-<uuid>」这类 → 返回可读的基名;不是脚本则返回 nil
    private static func scriptBaseName(_ id: String) -> String? {
        for prefix in ["bash", "sh", "zsh", "python", "python3", "perl", "ruby", "node"] {
            if id.hasPrefix(prefix + "-") {
                return "终端里的\(prefix)脚本"
            }
        }
        // 没有点号的裸二进制(ls、tcc_probe、curl …)
        if !id.contains(".") && !id.isEmpty {
            return "命令行程序「\(id)」"
        }
        return nil
    }

    /// 从 `a.b.helper.c` / `a.b.helper` 里取出父 App 的 bundle id
    private static func helperParent(_ id: String) -> String? {
        for marker in [".helper.", ".Helper.", ".helper"] {
            if let r = id.range(of: marker) {
                let parent = String(id[id.startIndex..<r.lowerBound])
                if parent.contains(".") { return parent }
            }
        }
        return nil
    }

    /// 这些叶子名太笼统,单独出现时没有信息量,应该退到上一层
    private static let genericLeaves: Set<String> = [
        "iphoneclient", "gpu", "renderer", "client", "mac", "desktop", "app",
        "daemon", "service", "agent", "extension", "helper", "xpc", "ui",
    ]

    /// com.tencent.xinWeChat → xinWeChat;整串太长的截断
    private static func prettify(_ id: String) -> String {
        // Apple 的守护进程名(corespeechd、siriknowledged…)对用户没有意义。
        // 宁可统一说「系统组件」,也不要把技术名糊到脸上。
        if id.hasPrefix("com.apple.") && id.split(separator: ".").count > 2 {
            return "系统组件"
        }
        if id.hasPrefix("/") {   // 以路径形式出现的平台二进制
            return (id as NSString).lastPathComponent
        }
        var parts = id.split(separator: ".").map(String.init)
        // 叶子名太笼统(iphoneclient / gpu / renderer)就退到上一层
        while parts.count > 2, let last = parts.last,
              genericLeaves.contains(last.lowercased()) {
            parts.removeLast()
        }
        if parts.count >= 2 {
            let tail = String(parts.last!)
            return tail.count <= 24 ? tail : String(id.prefix(28)) + "…"
        }
        return id.count <= 28 ? id : String(id.prefix(28)) + "…"
    }

    private static func symbolIcon(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    // MARK: 人工词表
    //
    // 只收录**实际观测到过**的系统组件 —— 它们的原始名字对用户没有意义,
    // 而 LaunchServices 也查不到。没观测到的不往里加(避免又变成编造)。
    private static let manual: [String: (String, String, Kind)] = [
        "com.apple.screencapture":      ("系统截屏工具", "camera.viewfinder", .system),
        "com.apple.osascript":          ("自动化脚本",   "applescript", .system),
        "com.apple.routined":           ("位置服务",     "location", .system),
        "com.apple.corespotlightd":     ("Spotlight 索引", "magnifyingglass", .system),
        "com.apple.ReportCrashService": ("崩溃报告",     "exclamationmark.triangle", .system),
        "com.apple.WorkflowKit.BackgroundShortcutRunner": ("快捷指令", "wand.and.stars", .system),
        "com.apple.appkit.xpc.openAndSavePanelService":   ("打开/存储面板", "doc", .system),
        "com.apple.tccd":               ("系统权限服务", "lock.shield", .system),
        "com.apple.replayd":            ("屏幕采集服务", "rectangle.dashed.badge.record", .system),
        "com.apple.WindowServer":       ("窗口服务",     "macwindow", .system),
        "com.apple.locationd":          ("定位服务",     "location", .system),
        "local.bigbrother":             ("BigBrother",   "eye", .app),

        // 下面这些同样是**实测出现过**的。LaunchServices 查不到它们
        // (是守护进程而非 App),而原始名字对用户毫无意义。
        "com.apple.AddressBook.abd":        ("通讯录服务",   "person.crop.circle", .system),
        "com.apple.AddressBookSourceSync":  ("通讯录同步",   "person.crop.circle", .system),
        "com.apple.CoreLocationAgent":      ("定位服务",     "location", .system),
        "com.apple.CrashReporter":          ("崩溃报告",     "exclamationmark.triangle", .system),
        "com.apple.MenuBarAgent":           ("菜单栏",       "menubar.rectangle", .system),
        "com.apple.TextInputMenuAgent":     ("输入法菜单",   "keyboard", .system),
        "com.apple.UserNotificationCenter": ("通知中心",     "bell", .system),
        "com.apple.cameracaptured":         ("相机服务",     "camera", .system),
        "com.apple.inputmethod.SCIM":       ("简体中文输入法", "keyboard", .system),
        "com.apple.maps.destinationd":      ("地图路线服务", "map", .system),
        "com.apple.quicklook.QuickLookUIService": ("快速查看", "eye", .system),
        "com.apple.screencaptureui":        ("截屏界面",     "camera.viewfinder", .system),
        "com.apple.siriactionsd":           ("Siri 动作",    "waveform", .system),
        "com.apple.siriknowledged":         ("Siri 知识",    "waveform", .system),
        "com.apple.spindump":               ("进程采样",     "waveform.path.ecg", .system),
        "com.apple.voicememod":             ("语音备忘录",   "mic", .system),
        "com.apple.campo":                  ("Siri",         "waveform", .system),
        "com.apple.coremedia.videodecoder": ("视频解码",     "film", .system),
    ]
}
