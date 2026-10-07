import Foundation

enum HourlyTimeline {
    static func end(after date: Date, calendar: Calendar = .current) -> Date {
        guard let hour = calendar.dateInterval(of: .hour, for: date) else {
            preconditionFailure("Cannot determine the hour containing \(date)")
        }
        return hour.end
    }
}

// MARK: - 界面标签页

/// 放在 Models 里而不是 Views 里,这样 Monitor 可以在下钻时切换标签页,
/// 而不必依赖 SwiftUI。
enum PanelTab: String, CaseIterable {
    case overview = "今天"
    case events   = "记录"
    case stats    = "关联"
    case settings = "设置"
}

/// 概览页下钻时携带的筛选条件
struct DrillFilter: Equatable {
    var scope: EventScope = .usage
    var kinds: Set<PrivacyKind> = []
    var actor: String?
    /// 按「授权主体」筛选。
    ///
    /// 和 actor 的区别:actor 只看实际执行者,subject 看的是
    /// COALESCE(responsible, accessing) —— 也就是概览页主列表用的口径。
    /// 两者必须一致,否则点进去的数字会对不上。
    var subject: String?
    var onlyDenied = false
    var onlyHighRisk = false
    var search = ""
    /// 时间下限。
    ///
    /// 必须和概览上被点击的那个数字用**同一个时间窗**,否则会出现
    /// 「概览说今日 4125,点进去 6123 条」这种自相矛盾 ——
    /// 这个 bug 在真实数据(全是当天产生)下看不出来,是 50 万行跨 90 天的
    /// 合成数据把它逼出来的。
    var since: Date?
    /// 时间窗的可读标签,显示在筛选标签上
    var sinceLabel: String?
    var isEmpty: Bool {
        scope == .usage && kinds.isEmpty && actor == nil && subject == nil && !onlyDenied
            && !onlyHighRisk && search.isEmpty && since == nil
    }

    /// 界面上的可移除筛选标签
    var chips: [(label: String, clear: (inout DrillFilter) -> Void)] {
        var out: [(String, (inout DrillFilter) -> Void)] = []
        if scope != .usage { out.append((scope.rawValue, { $0.scope = .usage })) }
        if !kinds.isEmpty {
            let names = kinds.count == 1
                ? kinds.first!.label
                : "\(kinds.count) 类记录"
            out.append((names, { $0.kinds = [] }))
        }
        if let actor {
            out.append(("程序：\(actor)", { $0.actor = nil }))
        }
        if onlyDenied { out.append(("未获授权", { $0.onlyDenied = false })) }
        if onlyHighRisk { out.append(("需要留意", { $0.onlyHighRisk = false })) }
        if !search.isEmpty { out.append(("搜索：\(search)", { $0.search = "" })) }
        if let sinceLabel { out.append((sinceLabel, { $0.since = nil; $0.sinceLabel = nil })) }
        if let subject {
            out.append((AppNames.shared.name(subject), { $0.subject = nil }))
        }
        return out
    }
}

// MARK: - 权限分类

enum PrivacyCategory: String, CaseIterable {
    case capture    // 摄录与定位
    case input      // 输入与键盘
    case data       // 个人数据
    case disk       // 文件与磁盘

    var label: String {
        switch self {
        case .capture: return "摄像头、麦克风与位置"
        case .input:   return "键盘与电脑控制"
        case .data:    return "个人信息"
        case .disk:    return "文件与磁盘"
        }
    }

    var symbol: String {
        switch self {
        case .capture: return "record.circle"
        case .input:   return "keyboard"
        case .data:    return "person.text.rectangle"
        case .disk:    return "externaldrive"
        }
    }
}

// MARK: - 隐私类型

/// 我们关心的敏感权限。rawValue 直接对应 TCC 的 service 名。
///
/// ── 关于「实测」与「推测」────────────────────────────────────────────
/// 下面每个 case 都标了它在真实日志里是否被实际观测到。
///
/// 踩过的坑:`locationAlways` 曾经是我照 iOS 的「始终允许」类推出来的,
/// 结果 macOS 上根本不存在,`isCore = true` 还让它在核心区**永远显示一个 0**。
/// 编造一个权限类型,比少一个权限类型糟糕得多 —— 前者是在骗用户。
///
/// 没实测过的 case 仍然保留,但都放在「其他敏感权限」区,
/// **只有计数 > 0 才渲染**,所以永远不会造成「永久 0」的误导。
enum PrivacyKind: String, CaseIterable, Codable {

    // ── 核心权限(最初需求点名,全部实测确认)──
    case screenCapture  = "kTCCServiceScreenCapture"   // 实测
    case microphone     = "kTCCServiceMicrophone"      // 实测
    case camera         = "kTCCServiceCamera"          // 实测
    /// 位置的**事件**来自 locationd 通道,不是 TCC。
    /// 这个 rawValue 只作为本地分类标签使用 —— macOS 从不发出 kTCCServiceLocation。
    case location       = "kTCCServiceLocation"
    case clipboard      = "CLIPBOARD"                  // 非 TCC,本机轮询

    // 输入与键盘 —— 可用于键盘记录
    case accessibility  = "kTCCServiceAccessibility"   // 实测
    case listenEvent    = "kTCCServiceListenEvent"     // 实测

    /// 系统音频录制(录屏带声音、或 App 抓系统音频)
    case audioCapture   = "kTCCServiceAudioCapture"    // 实测

    // 文件与磁盘
    case fullDisk        = "kTCCServiceSystemPolicyAllFiles"          // 实测
    case documentsFolder = "kTCCServiceSystemPolicyDocumentsFolder"   // 实测
    case desktopFolder   = "kTCCServiceSystemPolicyDesktopFolder"     // 实测
    case appBundles      = "kTCCServiceSystemPolicyAppBundles"        // 实测
    case developerTool   = "kTCCServiceDeveloperTool"                 // 实测

    // 个人数据
    case photos            = "kTCCServicePhotos"            // 实测
    case contacts          = "kTCCServiceAddressBook"       // 实测
    case calendar          = "kTCCServiceCalendar"          // 实测
    case reminders         = "kTCCServiceReminders"         // 实测
    case mediaLibrary      = "kTCCServiceMediaLibrary"      // 实测
    case ubiquity          = "kTCCServiceUbiquity"          // 实测
    /// 语音银行:把你的声音样本存下来供辅助功能使用 —— 生物特征数据
    case voiceBanking      = "kTCCServiceVoiceBanking"      // 实测

    /// 兜底:任何我们没显式列出的 kTCCService*,都记到这里,而不是丢弃。
    /// 真实服务名保留在 events.service 列里。
    /// 加这个兜底是因为踩过坑:kTCCServiceAudioCapture 曾经被静默丢掉,
    /// 界面上完全看不出来 —— 少数据比多数据危险得多。
    case other             = "OTHER"

    var label: String {
        switch self {
        case .screenCapture:  return "屏幕画面"
        case .microphone:     return "麦克风"
        case .camera:         return "摄像头"
        case .location:       return "定位"
        case .clipboard:      return "剪贴板"
        case .accessibility:  return "控制电脑"
        case .listenEvent:    return "键盘输入"
        case .fullDisk:       return "完全磁盘访问"
        case .documentsFolder: return "文稿"
        case .desktopFolder:   return "桌面"
        case .appBundles:      return "其他 App"
        case .developerTool:   return "开发者工具"
        case .photos:          return "照片"
        case .contacts:        return "通讯录"
        case .calendar:        return "日历"
        case .reminders:       return "提醒事项"
        case .mediaLibrary:    return "音乐与媒体"
        case .ubiquity:        return "iCloud 云盘"
        case .voiceBanking:    return "声音样本"
        case .audioCapture:    return "系统声音"
        case .other:           return "其他权限"
        }
    }

    var symbol: String {
        switch self {
        case .screenCapture:  return "rectangle.dashed.badge.record"
        case .microphone:     return "mic"
        case .camera:         return "video"
        case .location: return "location"
        case .clipboard:      return "doc.on.clipboard"
        case .accessibility:  return "accessibility"
        case .listenEvent:    return "keyboard"
        case .fullDisk:       return "internaldrive"
        case .documentsFolder, .desktopFolder: return "folder"
        case .appBundles:     return "app.badge.checkmark"
        case .developerTool:  return "hammer"
        case .photos:         return "photo"
        case .contacts:       return "person.crop.circle"
        case .calendar:       return "calendar"
        case .reminders:      return "checklist"
        case .mediaLibrary:   return "music.note.list"
        case .ubiquity:       return "icloud"
        case .voiceBanking:   return "waveform.circle"
        case .audioCapture:   return "waveform.badge.mic"
        case .other:          return "questionmark.shield"
        }
    }

    /// 面向用户的一句话说明,例如「读取了你的通讯录」。
    ///
    /// 界面之前显示的是 rawValue(kTCCServiceAddressBook)和分类名,
    /// 都是给开发者看的。用户需要的是「它对我做了什么」。
    var actionPhrase: String {
        switch self {
        case .screenCapture:   return "使用了屏幕录制"
        case .microphone:      return "使用了麦克风"
        case .camera:          return "使用了摄像头"
        case .location:        return "获取了你的位置"
        case .clipboard:       return "剪贴板内容发生了变化"
        case .accessibility:   return "获得了控制电脑的权限"
        case .listenEvent:     return "读取了键盘输入"
        case .audioCapture:    return "录制了 Mac 发出的声音"
        case .fullDisk:        return "访问了 Mac 上的文件"
        case .documentsFolder: return "访问了你的文稿"
        case .desktopFolder:   return "访问了你的桌面"
        case .appBundles:      return "更改了其他 App"
        case .developerTool:   return "连接了开发者工具"
        case .photos:          return "访问了你的照片"
        case .contacts:        return "访问了你的通讯录"
        case .calendar:        return "访问了你的日历"
        case .reminders:       return "访问了你的提醒事项"
        case .mediaLibrary:    return "访问了你的音乐与媒体"
        case .ubiquity:        return "访问了你的 iCloud 云盘"
        case .voiceBanking:    return "使用了你的声音样本"
        case .other:           return "访问了其他受保护的内容"
        }
    }

    var category: PrivacyCategory {
        switch self {
        case .screenCapture, .microphone, .camera, .location:
            return .capture
        case .accessibility, .listenEvent:
            return .input
        case .fullDisk, .documentsFolder, .desktopFolder,
             .appBundles, .developerTool, .ubiquity:
            return .disk
        default:
            return .data
        }
    }

    /// 最初需求点名的六项
    var isCore: Bool {
        switch self {
        case .screenCapture, .microphone, .camera, .location, .clipboard:
            return true
        default:
            return false
        }
    }

    /// 基础危险度:读取屏幕/键盘/全盘 = 高;摄录与定位 = 中;其余 = 低
    var baseSeverity: Int {
        switch self {
        case .screenCapture, .accessibility, .listenEvent, .fullDisk, .appBundles:
            return 3
        case .microphone, .camera, .location, .developerTool:
            return 2
        case .audioCapture:
            return 3
        default:
            return 1
        }
    }

    static func from(service: String) -> PrivacyKind? {
        if let k = PrivacyKind(rawValue: service) { return k }
        // 兼容带后缀的服务名(定位有多个变体)
        if service.hasPrefix("kTCCServiceLocation") { return .location }
        // 兜底:未知的 kTCCService* 也要记下来,绝不静默丢弃
        if service.hasPrefix("kTCCService") { return .other }
        return nil
    }
}

// MARK: - 进程身份

struct ProcInfo: Equatable {
    var identifier: String
    var pid: Int
    var path: String?

    /// 是否是「不是 App 的裸可执行文件」——继承链里最危险的一类
    var isBareExecutable: Bool {
        if identifier.hasPrefix("bash-") || identifier.hasPrefix("sh-")
            || identifier.hasPrefix("zsh-") || identifier.hasPrefix("python-")
            || identifier.hasPrefix("node-") || identifier.hasPrefix("perl-") {
            return true
        }
        return !identifier.contains(".")
    }

    var isAppleSystem: Bool { identifier.hasPrefix("com.apple.") }

    /// 苹果自己的位置组件(`CoreParsec.framework`、`Routine.bundle`、
    /// `CoreWLAN.framework`…)。
    ///
    /// 它们不带 `com.apple.` 前缀,只看标识符会被当成第三方 App ——
    /// 实测旧版就是这样把一堆 framework 当成"访问者"显示出来的。
    var isSystemLocationComponent: Bool {
        if isAppleSystem { return true }
        // locationd 给系统组件用的是 `root:p<路径>` 形式,解析后只剩文件名,
        // 所以既要看标识符形态,也要看路径。
        if identifier.hasSuffix(".framework") || identifier.hasSuffix(".bundle") { return true }
        guard let path else { return false }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/")
    }
}

// MARK: - 采集通道

/// 请求通道不是采集成功的证据。
enum Channel: String {
    case replayd      = "com.apple.replayd"
    case windowServer = "com.apple.WindowServer"
    case coreaudiod   = "com.apple.audio.coreaudiod"
    case sandboxd     = "com.apple.sandboxd"
    case locationd    = "com.apple.locationd"
    case other        = "other"

    static func of(_ requesting: String?) -> Channel {
        switch requesting {
        case "com.apple.replayd":          return .replayd
        case "com.apple.WindowServer":     return .windowServer
        case "com.apple.audio.coreaudiod": return .coreaudiod
        case "com.apple.sandboxd":         return .sandboxd
        case "com.apple.locationd":        return .locationd
        default:                           return .other
        }
    }

    var label: String {
        switch self {
        case .replayd:      return "屏幕画面请求"
        case .windowServer: return "屏幕相关请求"
        case .coreaudiod, .sandboxd, .locationd, .other: return ""
        }
    }

    /// 请求是否通过屏幕画面采集通道;通道本身不证明采集成功。
    var isPixelCapture: Bool { self == .replayd }
}

// MARK: - 事件

/// 记录页的筛选口径。
///
/// 名字面向用户,不面向实现:用户想知道的是「谁访问了什么」,而不是
/// preflight / 审计行这类词。括号里是它对应的事实。
enum EventScope: String, CaseIterable {
    /// 系统能确认的访问:已证实的采集动作 + 已授权状态下的访问
    case usage = "访问记录"
    /// 更硬的一层:剪贴板变更、定位供数、录屏生命周期
    case activity = "只有动作"
    /// 只是问了权限、而系统没有给出授权
    case permissionChecks = "仅权限查询"
    /// 授权结果缺失,或被系统拒绝
    case unconfirmed = "被拒或未知"
    /// 不做任何过滤
    case all = "全部原始记录"
}

enum EventPhase: String {
    case permissionCheck = "仅权限查询"
    case accessRequest = "访问请求"
    case activity = "实际动作"
    case unknown = "结果未知"
}

enum AuthorizationResult {
    case allowed, limited, denied, unknown

    init(_ value: Int?) {
        switch value {
        case 2: self = .allowed
        case 3: self = .limited
        case 0: self = .denied
        default: self = .unknown
        }
    }
}

struct PrivacyEvent: Identifiable {
    var id: Int64 = 0
    var timestamp: Date
    var service: String
    var kind: PrivacyKind
    var responsible: ProcInfo?
    var accessing: ProcInfo?
    var requesting: String?
    var authValue: Int?
    var preflight: String?
    var logCount: Int = 1
    var severity: Int = 1
    var reason: String = ""
    var isInherited: Bool = false
    /// 采集持续时长(秒)。仅对「持续录屏」有意义 —— TCC 日志本身不含时长,
    /// 需要靠采集进程的 SCStream start/stop 标记补齐。
    var duration: Double?

    var channel: Channel { Channel.of(requesting) }

    /// 系统做的是「预检查」(TCCAccessPreflight / preflight=true)。
    ///
    /// ⚠️ 它**不是**「没访问」的同义词 —— 实测 macOS 27 上真实录屏、真实开摄像头
    /// 都会同时产生 preflight=no 与 preflight=yes 两种请求。它的真正含义是:
    /// 「这次调用只查询当前授权状态」。因此它只能用来描述**证据强度**,
    /// 不能用来否定访问,更不能作为「这条记录不重要」的理由。
    var isPermissionCheck: Bool {
        Self.isPermissionCheck(preflight)
    }

    static func isPermissionCheck(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes"
    }

    /// SQL 侧把 preflight 归一化成小写、去掉空白后使用的字符集合。
    ///
    /// ⚠️ 必须和 `preflightValue` 的 `CharacterSet.whitespacesAndNewlines`
    /// 完全一致:两边只要有一处不一样,同一条记录就会「模型算使用、SQL 不算」
    /// (或反过来),表现为概览数字和记录列表对不上。
    static let preflightTrimSet = CharacterSet.whitespacesAndNewlines

    /// 预检查字段的规范化形式:nil / 空串 / "yes" / "no" / 其他原文
    var preflightValue: String? {
        guard let raw = preflight?.trimmingCharacters(in: Self.preflightTrimSet),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// 入库前归一化:**小写**并去掉两侧空白。
    ///
    /// SQL 侧的判定用的是 `LOWER(TRIM(preflight, char(9)||char(10)||char(13)||' '))`。
    /// 把归一化放在写库这一处,能保证任意形态的原始值(实测出现过 `" \tNO\n"`)
    /// 落库后只剩 `yes` / `no`,模型和 SQL 永远不会得出不同结论。
    var normalizedPreflight: String? {
        preflightValue?.lowercased()
    }

    /// 系统给出了可以解读的阶段信息。
    ///
    /// 空值也算 —— 早期事件(以及 locationd 这类不走 TCC 的通道)没有这个字段,
    /// 那时只能按授权结果判断;但出现了 yes/no 之外的取值就是无法解读。
    var hasKnownPreflightPhase: Bool {
        guard let value = preflightValue?.lowercased() else { return true }
        return value == "yes" || value == "no"
    }

    /// 这次屏幕请求不是像素通路 —— 系统只返回了窗口/枚举类信息。
    ///
    /// 依据实测:macOS 27 上真正读取屏幕画面的只有 `com.apple.replayd`
    /// (截图与 SCStream 都会走它)。WindowServer 通路是窗口列表/元数据;
    /// coreaudiod、sandboxd 等中介只是顺带做了一次屏幕权限查询。
    var isScreenMetadataOnly: Bool {
        kind == .screenCapture && !channel.isPixelCapture
    }

    /// 有明确证据的采集动作:系统不是在做预检查,且授权结果允许。
    ///
    /// 依据实测:真正的录屏/开摄像头都会出现 `preflight=no` 且 `authValue=2/3`
    /// 的那次请求,紧随 preflight=yes 的授权查询之后。
    var isConfirmedAccess: Bool {
        guard service.hasPrefix("kTCCService") else { return false }
        guard !isScreenMetadataOnly else { return false }
        guard preflightValue?.lowercased() == "no" else { return false }
        guard authorization == .allowed || authorization == .limited else { return false }
        return true
    }

    /// 已授权、但只观察到预检查的访问痕迹。
    ///
    /// 这是**新版刻意保留**的一类证据:App 已经拿到授权后,系统对每次访问
    /// 往往只打一条 preflight=yes 的授权查询(实测微信每隔半分钟产生一组
    /// `kTCCServiceScreenCapture, preflight=yes, authValue=2`,
    /// requesting=com.apple.replayd)。旧版把这类记录一律当成「权限检查」
    /// 且不计入统计,结果 App 已经授权后的每一次访问在界面上完全消失 ——
    /// 这正是「已授权就不记录」的错误来源。
    ///
    /// 措辞上必须区分:它证明 App 此刻在向系统确认这项权限,不证明它已经
    /// 拿到了画面或录音;真正拿到内容时系统会另发 preflight=no 的那条请求。
    var isAuthorizedAccessTrace: Bool {
        guard service.hasPrefix("kTCCService") else { return false }
        // 窗口/元数据查询即使已授权也不算「访问了画面」。
        guard !isScreenMetadataOnly else { return false }
        guard preflightValue?.lowercased() == "yes" else { return false }
        guard authorization == .allowed || authorization == .limited else { return false }
        return involvesThirdParty
    }

    /// 访问者里有第三方程序(苹果自家 App 之间的调用不算)。
    ///
    /// 之所以要单独判断:attribution 里 responsible 常常缺失(实测微信录屏时
    /// 只有 accessing=com.tencent.xinWeChat、requesting=com.apple.replayd),
    /// 所以不能要求 responsible 存在才认为它是第三方。
    var involvesThirdParty: Bool {
        [responsible, accessing]
            .compactMap { $0 }
            .contains { !$0.isAppleSystem }
    }

    /// 预检查、且未获授权 —— 这才是真正意义上的「权限检查」,不构成访问痕迹。
    var isDeniedCheck: Bool {
        isPermissionCheck && service.hasPrefix("kTCCService")
    }

    var authorization: AuthorizationResult { AuthorizationResult(authValue) }

    var phase: EventPhase {
        if kind == .clipboard { return .activity }
        if kind == .screenCapture, service == "SCREEN_RECORDING" { return .activity }
        if kind == .camera, service == "CAMERA_IN_USE" { return .activity }
        if kind == .screenCapture, let duration, duration > 0,
           authorization != .denied { return .activity }
        if kind == .location, service == "LOCATION_IN_USE" { return .activity }
        guard service.hasPrefix("kTCCService") else { return .unknown }
        guard hasKnownPreflightPhase else { return .unknown }
        // 屏幕画面的非 replayd 通路只是窗口/元数据查询,永远不算访问画面;
        // 被拒的元数据请求也只能算一次「检查」。
        let screenMetadataOnly = isScreenMetadataOnly
        func allowedPhase() -> EventPhase? {
            switch authorization {
            case .allowed, .limited: return .accessRequest
            case .denied: return isPermissionCheck ? .permissionCheck : .accessRequest
            case .unknown: return nil
            }
        }
        if !screenMetadataOnly, let known = allowedPhase() { return known }
        return isPermissionCheck ? .permissionCheck : .unknown
    }

    var isUsageEvent: Bool {
        if kind == .clipboard { return service == "CLIPBOARD" }
        if service == "CAMERA_IN_USE" { return kind == .camera }
        if kind == .location {
            // 旧版本把苹果自己的位置组件(CoreParsec.framework 之类)也记了进来。
            // 行保留在库里,但不再计入使用 —— 它们不是 App,也没有归因到任何 App。
            guard accessing?.isSystemLocationComponent != true else { return false }
            return service == "LOCATION_IN_USE"
        }
        if kind == .screenCapture, phase == .activity { return true }
        return isConfirmedAccess || isAuthorizedAccessTrace
    }

    /// 证据强度:确认的采集动作 / 已授权的访问痕迹 / 仅仅是检查
    var accessConfidenceLabel: String? {
        if isConfirmedAccess { return "已证实访问" }
        if isAuthorizedAccessTrace { return "已授权访问（未证实采集）" }
        if isDeniedCheck { return "仅权限查询" }
        return nil
    }

    var isRecordable: Bool {
        if isUsageEvent || service.hasPrefix("kTCCService") { return true }
        // 历史库里苹果自己的位置组件记录:不再计入使用,但要留在库里可审计
        // (否则升级后重放同一条日志会被静默丢弃,和已有行对不上)。
        return kind == .location && service == "LOCATION_IN_USE"
    }

    var actionPhrase: String {
        switch phase {
        case .permissionCheck: return "检查了\(kind.label)权限"
        case .activity:
            if service == "CAMERA_IN_USE" { return "系统报告摄像头正在被使用" }
            if kind == .screenCapture { return "记录到屏幕录制活动" }
            if kind == .location { return "系统向它提供了位置信息" }
            return kind.actionPhrase
        case .accessRequest:
            if kind == .screenCapture && !channel.isPixelCapture {
                return "检测到屏幕相关请求，未证实采集"
            }
            if isConfirmedAccess { return "存在\(kind.label)的访问记录" }
            if isAuthorizedAccessTrace {
                // 已授权 ≠ 没发生。系统仍会为每次访问打这条授权日志,
                // 但只凭它无法断言内容已经被读取。
                return "已授权状态下访问\(kind.label)"
            }
            return "请求访问\(kind.label)，未证实使用"
        case .unknown: return "检测到\(kind.label)相关记录"
        }
    }

    var resultLabel: String {
        if phase == .activity { return "已记录活动" }
        if kind == .location { return "系统定位记录" }
        switch authorization {
        case .allowed: return isPermissionCheck ? "已获授权" : "已获系统授权"
        case .limited: return "部分授权"
        case .denied: return isPermissionCheck ? "还没授权" : "已被系统拒绝"
        case .unknown: return "结果未知"
        }
    }

    var evidenceNote: String? {
        if service == "SCREEN_RECORDING" {
            return duration == nil
                ? "系统报告录制开始；尚未观察到结束，不代表此刻仍在录制。"
                : "系统报告录制开始与结束；时长来自日志，不包含画面内容。"
        }
        if phase == .activity {
            if service == "CAMERA_IN_USE" {
                return "由 Control Center 的摄像头指示器记录；绿灯亮起即产生此记录，不含画面。"
            }
            if kind == .screenCapture { return "系统报告了屏幕录制活动；日志不含画面内容。" }
            if kind == .location {
                return "由系统定位服务记录；不含坐标，也不代表读取了具体地点。"
            }
            return nil
        }
        if phase == .accessRequest {
            if authorization == .denied { return "此请求被系统拒绝，不代表已访问数据或设备。" }
            if authorization == .unknown { return "授权结果缺失或无法识别，不代表已访问数据或设备。" }
            if isAuthorizedAccessTrace {
                return "它已经获得授权，系统仍在每次访问时记录了这次请求；"
                    + "日志里不含采集到的内容，所以无法断言画面或声音被读取。"
            }
            return "获准调用不代表已经开始使用或读取内容。"
        }
        if kind == .fullDisk || kind == .documentsFolder || kind == .desktopFolder {
            return "此记录不代表已读取文件；具体目标文件未知。"
        }
        return "权限结果不代表实际使用了数据或设备。"
    }

    var affectsThreatLevel: Bool {
        isUsageEvent
    }

    var shouldAlert: Bool { affectsThreatLevel && severity >= 4 }

    /// 系统记录的责任主体,不代表已获授权或已读取数据。
    var subject: ProcInfo? { responsible ?? accessing }

    /// 配角:真正执行的那一方(仅在和主角不同时才有意义)
    var executor: ProcInfo? {
        guard let r = responsible?.identifier, let a = accessing?.identifier,
              r != a else { return nil }
        return accessing
    }

    var actorName: String {
        accessing?.identifier ?? responsible?.identifier ?? "未知"
    }

    var isDenied: Bool { authorization == .denied }

    var isAppleOnly: Bool {
        let participants = [responsible, accessing].compactMap { $0 }
        return !participants.isEmpty && participants.allSatisfy(\.isAppleSystem)
    }

    /// 会话键:同一次采集会打 3~4 条日志,必须折叠。
    ///
    /// 必须包含 service —— 否则同一个进程在录屏时同时访问麦克风与屏幕,
    /// 两次访问的键会完全相同而被错误地折叠成一行(实测踩过这个坑:
    /// 一次录屏同时产生 kTCCServiceMicrophone 与 kTCCServiceScreenCapture,
    /// 结果屏幕事件被吞进了麦克风那一行)。
    ///
    /// 定位与录屏还要带上时间戳:它们是「按会话」记录的事件,同一个 App 一天
    /// 可能用很多次,不带时间就会被折叠成一条。
    ///
    /// 必须包含 preflight —— 同一次采集里,系统会先打一条 preflight=yes 的
    /// 授权查询、紧接着打一条 preflight=no 的真实访问请求(实测录屏与开摄像头
    /// 都是这个顺序)。两者的证据强度完全不同,折叠成一行只会剩下先到的那条,
    /// 于是「已证实访问」被降级成「访问痕迹」,甚至反过来。
    var sessionKey: String {
        let r = responsible?.identifier ?? "?"
        let a = accessing?.identifier ?? "?"
        let p = accessing?.pid ?? -1
        let timed = (service == "SCREEN_RECORDING" || service == "LOCATION_IN_USE")
            ? "|\(timestamp.timeIntervalSince1970)" : ""
        let pre = normalizedPreflight ?? "?"
        return "\(r)|\(a)|\(p)|\(service)|\(phase.rawValue)|\(pre)|"
            + "\(authValue.map(String.init) ?? "?")\(timed)"
    }
}

// MARK: - 判定

enum Judge {
    /// 单次采集会话内允许的最大日志间隔。超过即视为新的一次采集。
    /// 依据实测:同一次采集的 3~4 条日志跨度 < 150ms;
    /// 而 App 内建采集(如微信)pid 恒定,不能只靠 pid 分界,必须引入时间维度。
    static let sessionGap: TimeInterval = 2.0

    static func evaluate(kind: PrivacyKind, service: String,
                         responsible: ProcInfo?, accessing: ProcInfo?,
                         requesting: String?, authValue: Int?,
                         preflight: String? = nil,
                         directRequest: Bool = false) -> (Int, String) {
        let channel = Channel.of(requesting)
        // 非 replayd 请求可能只是窗口信息,不能仅凭通道断言截屏。
        let metaOnly = (kind == .screenCapture && !channel.isPixelCapture)
        let allowed = AuthorizationResult(authValue) == .allowed
            || AuthorizationResult(authValue) == .limited

        // 预检查(preflight=yes)在旧版被一律当成「没访问」,于是 App **已经
        // 获授权之后**的每一次访问都从统计里消失 —— 而这恰恰是用户最想知道
        // 的那类行为。系统在已授权状态下还打授权日志,本身就是一次访问请求。
        if PrivacyEvent.isPermissionCheck(preflight) {
            guard allowed else { return (1, "权限检查，不代表实际访问") }
            guard !metaOnly else {
                return (min(kind.baseSeverity, 2), "屏幕相关请求，未证实采集")
            }
            let thirdParty = [responsible, accessing].compactMap { $0 }
                .contains { !$0.isAppleSystem }
            guard thirdParty else { return (1, "系统组件之间的权限查询") }
            if let acc = accessing, acc.isBareExecutable {
                return (5, "命令行程序,已授权访问痕迹"
                        + (responsible.map { ",关联 App：\($0.identifier)" } ?? ""))
            }
            return (kind.baseSeverity, "已授权的访问请求，确实向系统申请了该权限")
        }
        if let preflight,
           preflight.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "no" {
            return (1, "事件阶段未知")
        }
        guard let acc = accessing else { return (1, "来源不明") }
        let rident = responsible?.identifier

        var sev = kind.baseSeverity
        var reasons: [String] = []

        // Apple 组件之间互相调用是系统内部机制(ReportCrashService ← CrashReporter、
        // dock.helper ← dock、隐私设置扩展 ← LocalAuthentication 之类)。
        // 这类关系必须整体放行,否则眼睛会一直乱变色 ——
        // 误报会直接让用户无视这个信号。
        let appleInternal = acc.isAppleSystem && (rident?.hasPrefix("com.apple.") ?? false)

        if acc.isBareExecutable {
            sev = 5
            reasons.append("命令行程序" + (rident.map { ",关联 App：\($0)" } ?? ""))
        } else if appleInternal {
            sev = min(sev, 1)
            reasons.append("系统内部调用")
        } else if let r = rident, r != acc.identifier {
            sev = max(sev, 3)
            reasons.append("关联 App：\(r)")
        } else if acc.isAppleSystem {
            sev = min(sev, 2)
            reasons.append("系统组件")
        }

        if AuthorizationResult(authValue) == .denied {
            reasons.append("系统拒绝请求")
        }

        if metaOnly {
            sev = min(sev, 2)
            reasons.insert("屏幕相关请求，未证实采集", at: 0)
        }

        if directRequest {
            reasons.append("App 直接申请")
        }

        if reasons.isEmpty {
            switch AuthorizationResult(authValue) {
            case .allowed: reasons.append("已授权调用，系统记录了这次访问")
            case .limited: reasons.append("部分授权，系统记录了这次访问")
            case .denied: reasons.append("系统拒绝请求")
            case .unknown: reasons.append("权限结果未知")
            }
        }
        return (sev, reasons.joined(separator: ";"))
    }

    /// 面向用户的措辞。
    ///
    /// 大部分事件本来就是「已授权的 App 在做它被允许做的事」——
    /// 那应该读起来像「正常」,而不是「信息」这种数据库词。
    /// 黄色以上才值得用户花注意力。
    static func severityLabel(_ s: Int) -> String {
        switch s {
        case 5: return "高风险"
        case 4: return "需要留意"
        case 3: return "请关注"
        default: return "一般"
        }
    }
}
