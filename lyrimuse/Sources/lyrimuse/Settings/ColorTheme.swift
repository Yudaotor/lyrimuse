import Foundation

// 经典悬浮窗"配色主题"——内置预设一键套用 + 自定义主题另存复用,对标 PlayStatus/
// Lyricify/AlgerMusicPlayer/HotLyric/VutronMusic 都有的配色主题功能。只打包这四个
// "配色"相关字段(不含字体/字号——那是排版,不是配色,两者概念上不是一回事,不该被同一个
// "主题"捆在一起改动)。textStrokeEnabled/textStrokeColorHex 对应的渲染效果是实心描边
// (非模糊阴影,见 LyricsOverlayView.swift 的 OptionalTextStroke)。
public struct ColorTheme: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var foregroundColorHex: String
    public var backgroundColorHex: String
    public var textStrokeEnabled: Bool
    public var textStrokeColorHex: String

    public init(
        id: String = UUID().uuidString, name: String,
        foregroundColorHex: String, backgroundColorHex: String,
        textStrokeEnabled: Bool, textStrokeColorHex: String
    ) {
        self.id = id
        self.name = name
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.textStrokeEnabled = textStrokeEnabled
        self.textStrokeColorHex = textStrokeColorHex
    }

    // 手写解码,只为兼容改名之前存下的主题。
    //
    // 这两个字段早先叫 textShadowEnabled / textShadowColorHex(那会儿渲染的确是模糊阴影,
    // 后来换成实心描边才一起改的名),改名时没做迁移 —— 于是任何在那之前存过自定义主题的
    // 用户,合成的 Codable 解到旧 JSON 会抛 keyNotFound,而 AppSettings 那边是
    // `try? JSONDecoder().decode([ColorTheme].self, …)`,**整个数组**被吞成空:界面上一个
    // 自定义主题都不剩,用户以为自己存的东西没了。
    //
    // 比"看不见"更糟的是下一步:数组已经是空的,用户再存一个新主题时,didSet 会把这个只有
    // 一条的新数组整体编码回写,旧 JSON 被覆盖 —— 那才是真的不可恢复。所以这不只是显示
    // 问题,是一条数据丢失路径。
    //
    // 2026-08-14 实测复现(用户机器上真实存着的那串 JSON):
    //   DecodingError.keyNotFound: Key 'textStrokeEnabled' not found …
    //
    // 只写 init(from:) 不写 encode(to:):编码继续用合成的那份,也就是**只写新名字**,旧名
    // 只在读的时候认。这样迁移是一次性的 —— 存过一次之后 JSON 里就没有旧名了。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        foregroundColorHex = try c.decode(String.self, forKey: .foregroundColorHex)
        backgroundColorHex = try c.decode(String.self, forKey: .backgroundColorHex)
        textStrokeEnabled = try c.decodeIfPresent(Bool.self, forKey: .textStrokeEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .legacyTextShadowEnabled)
            ?? false
        textStrokeColorHex = try c.decodeIfPresent(String.self, forKey: .textStrokeColorHex)
            ?? c.decodeIfPresent(String.self, forKey: .legacyTextShadowColorHex)
            ?? "#000000A6"
    }

    // 必须手写:CodingKeys 里多了两个没有对应属性的 legacy case,合成的 encode 编不出来。
    // 只写新名字 —— 旧名是纯粹的读兼容,不该被再写回磁盘。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(foregroundColorHex, forKey: .foregroundColorHex)
        try c.encode(backgroundColorHex, forKey: .backgroundColorHex)
        try c.encode(textStrokeEnabled, forKey: .textStrokeEnabled)
        try c.encode(textStrokeColorHex, forKey: .textStrokeColorHex)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, foregroundColorHex, backgroundColorHex
        case textStrokeEnabled, textStrokeColorHex
        case legacyTextShadowEnabled = "textShadowEnabled"
        case legacyTextShadowColorHex = "textShadowColorHex"
    }
}

extension ColorTheme {
    // id 用固定字符串(不是随手 UUID())——内置预设每次启动都是同一份字面量构造出来的
    // 新实例,固定 id 才能让"当前配色是不是正好等于某个内置预设"这类比较(如果以后需要)
    // 有意义;用户自己存的自定义主题才用随机 UUID(见 SettingsView 里"存为新主题"那处)。
    // "经典黑字"跟"经典白字"对称;"白字描边"/"黑字描边"是它们各自打开描边开关的变体
    // (2026-08-26 加)。defaultTheme 现在指向 `classicBlackStroke`(见下方)。
    /// 白字 + 七成不透明黑底。被定为 `defaultTheme`(见下方)—— 全新安装长这个样子。
    ///
    /// 跟 classicBlack 一样单独命名而不是只躺在 builtInPresets 里:defaultTheme 要引用它,
    /// 而"默认配色"和"预设列表里第 N 项"是两件事,不该靠数组下标耦合。
    public static var darkCard: ColorTheme {
        ColorTheme(
            id: "builtin-card", name: L10n.t("深色卡片"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#000000B3",
            textStrokeEnabled: false, textStrokeColorHex: "#000000A6"
        )
    }

    public static var classicBlack: ColorTheme {
        ColorTheme(
            id: "builtin-classic-black", name: L10n.t("经典黑字"),
            foregroundColorHex: "#000000FF", backgroundColorHex: "#00000000",
            // 描边色 2026-08-17 从 65% 黑改成**不透明白**(用户要求)——这一款的文字本来
            // 就是黑的,黑字配黑边等于没有描边,配白边才真的能在深色壁纸上把字托出来。
            // 描边开关依旧关着,这个颜色只是用户手动打开它时的起点。
            textStrokeEnabled: false, textStrokeColorHex: "#FFFFFFFF"
        )
    }

    /// "经典黑字"打开描边开关的变体——跟 `builtInPresets` 里的"黑字描边"是同一份配色,
    /// 单独命名出来是因为 `defaultTheme`(见下方)要引用它,理由跟 `classicBlack`/
    /// `darkCard` 单独命名的理由一样:"默认配色"和"预设列表里第 N 项"是两件事,不该靠
    /// 数组下标耦合。
    ///
    /// 2026-08-26 定为 `defaultTheme`(用户要求把自己手动调好的这套——跟随封面 + 描边——
    /// 定为新的默认初始化配色):前景/背景直接复用 `classicBlack` 的字段,只把描边打开,
    /// 两者的前景/背景色天然保持同步。
    public static var classicBlackStroke: ColorTheme {
        ColorTheme(
            id: "builtin-classic-black-stroke", name: L10n.t("黑字描边"),
            foregroundColorHex: classicBlack.foregroundColorHex, backgroundColorHex: classicBlack.backgroundColorHex,
            textStrokeEnabled: true, textStrokeColorHex: classicBlack.textStrokeColorHex
        )
    }

    // ⚠️ 必须是**计算属性**(`{ ... }`,每次读都重新求值)。
    //
    // 预设名走 L10n.t,而整个设置树靠 .id(L10n.current) 支持不重启切换语言;一旦这里被
    // 求值一次就定死,名字会冻结在**进程内第一次访问**时的语言上——先用中文打开过一次
    // 「配色主题」菜单,再切成 English,整页别的字都变了,只有这几个预设名还是中文,只能
    // 重启 App 才恢复。L10n.swift 顶部对 current/bundle 定的是同一条规则:"每次读都重新
    // 解析,不用 static let 一次性缓存"。
    //
    // 2026-08-06 订正:上一版把它从 `static let` 改成带初始值的 `static var builtInPresets
    // = [...]` 并注释成"每次读都重新求值",那是错的——Swift 里带初始值的 `static var` 是
    // **惰性初始化的存储属性**,只在第一次访问时求值一次(swift_once),跟 `static let`
    // 一样会冻结,改动等于没生效,还白搭了一个可变全局状态。只有计算属性才真的重新求值。
    //
    // 数组体保持原缩进,所以写成 `{ [ ... ] }` 而不是另起一层——两处访问点(SettingsView
    // 的预设列表和 currentColorThemeLabel)都在设置页渲染路径上,不在 20Hz/60fps 热路径,
    // 每次读重建 6 个 struct + 6 次字典查表的开销可以忽略。
    public static var builtInPresets: [ColorTheme] { [
        ColorTheme(
            id: "builtin-classic", name: L10n.t("经典白字"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
            textStrokeEnabled: false, textStrokeColorHex: "#000000A6"
        ),
        // "经典白字"加描边(2026-08-26 用户要求,去掉"暖黄"/"赛博青"换成这两款)——
        // 前景/背景跟"经典白字"完全一样,只是把描边开关打开;描边色沿用"经典白字"
        // 本来就带的那个"手动打开描边时的默认色"(#000000A6),两款不是巧合重复,
        // 是同一份配色的"描边关/描边开"两个变体。
        ColorTheme(
            id: "builtin-classic-white-stroke", name: L10n.t("白字描边"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
            textStrokeEnabled: true, textStrokeColorHex: "#000000A6"
        ),
        classicBlack,
        classicBlackStroke,
        darkCard,
        // 跟"深色卡片"对称的浅色版本——同样的卡片不透明度(0xB3),前景/背景黑白对调。
        ColorTheme(
            id: "builtin-light-card", name: L10n.t("浅色卡片"),
            foregroundColorHex: "#000000FF", backgroundColorHex: "#FFFFFFB3",
            textStrokeEnabled: false, textStrokeColorHex: "#FFFFFFA6"
        ),
    ] }

    // 全新安装/"恢复默认文字与配色"/"清除所有配置"之后应该长成的样子——AppSettings.init()
    // 和 SettingsView 的"恢复默认文字与配色"按钮都读这一个值,不再各自硬编码一遍。
    // 也写成计算属性:眼下几个调用点只读它的十六进制色值(name 从不读),所以冻结与否
    // 不影响现在的行为;但它是 classicBlackStroke 的别名,让两者求值语义一致,免得以后
    // 有人读 defaultTheme.name 又踩一次上面那个语言冻结。
    //
    // 2026-08-13 从 classicBlack 换成 card,2026-08-15 从 darkCard 换回 classicBlack,
    // 2026-08-26 从 classicBlack 换成 classicBlackStroke(用户要求把自己实际在用的那套——
    // 跟随封面 + 打开文字描边——定为新的默认初始化配色;`followsCoverArt` 不是 `ColorTheme`
    // 的字段,默认值改在 `AppSettings.defaultFollowsCoverArt`,两处各自改各自的字段,理由
    // 见那边注释)。
    /// 首次安装、以及任何没有显式配过色的用户看到的配色。
    ///
    /// ⚠️ 历史上这几个候选的可读性策略完全不同,换的时候要知道自己在换什么:
    ///   darkCard            白字 + 70% 黑底 —— 自带底衬,任何壁纸上都读得清
    ///   classicBlack         纯黑字 + **全透明**背景、不描边 —— 完全依赖桌面本身够浅,
    ///                       深色壁纸上会看不见
    ///   classicBlackStroke  跟 classicBlack 同一份前景/背景,但打开了白色描边 —— 深色
    ///                       壁纸上靠描边托字,比 classicBlack 更能兜底,但仍不如 darkCard
    ///                       那种自带底衬的卡片可靠
    /// 配色随时能在「外观」里改,描边也能单独打开,所以这是个偏好问题而非缺陷;
    /// 但如果以后有新用户反馈"装上看不见歌词",先想到这里。
    public static var defaultTheme: ColorTheme { classicBlackStroke }

    // 跟"是不是同一个主题"(id/name)无关,只比较四个真正影响观感的字段——用来判断
    // "当前配色是不是正好等于某个预设/自定义主题",给菜单标签当"当前生效哪个"的
    // 展示依据(见 SettingsView 的 currentColorThemeLabel)。描边关闭时描边颜色不参与
    // 比较:两个主题都关着描边,颜色值哪怕不同也该算"看起来一样"。
    public func hasSameColors(as other: ColorTheme) -> Bool {
        foregroundColorHex == other.foregroundColorHex
            && backgroundColorHex == other.backgroundColorHex
            && textStrokeEnabled == other.textStrokeEnabled
            && (!textStrokeEnabled || textStrokeColorHex == other.textStrokeColorHex)
    }

    /// 套用这个主题——原来是 `SettingsView.AppearanceSettingsTab` 的私有方法
    /// `applyColorTheme(_:)`,2026-08-29 悬浮窗新增的快捷设置菜单(`OverlayQuickSettingsMenu`)
    /// 要套用同一批内置/自定义主题,提到这里当唯一实现,两处调用点都改成调这个方法,行为不变。
    @MainActor
    func apply(to settings: AppSettings) {
        // 套用一个具体命名主题就是在明确表态"我要固定色,不要动态色"——顺手关掉
        // "跟随封面"(如果开着),不然套用之后前景色看起来毫无反应,像是套用失灵了
        // (实际上是被"跟随封面"接管了,只是用户不知道)。
        settings.followsCoverArt = false
        settings.foregroundColorHex = foregroundColorHex
        settings.backgroundColorHex = backgroundColorHex
        settings.textStrokeEnabled = textStrokeEnabled
        settings.textStrokeColorHex = textStrokeColorHex
    }
}
