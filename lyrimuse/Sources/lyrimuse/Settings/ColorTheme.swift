import AppKit
import AppKit
import Foundation

// 经典悬浮窗"配色主题"——内置预设一键套用 + 自定义主题另存复用。只打包配色字段:文字色
// (= 逐字的已唱色)与它的「跟随封面」、未唱色与它的「跟随封面」、背景色、毛玻璃开关与浓淡、
// 描边开关与描边色;不含字体/字号(那是排版,不该被同一个"主题"捆在一起改动)。
// 毛玻璃浓淡只在主题开着毛玻璃时才套用、才参与判等:不开毛玻璃的主题不该改掉用户自己选的浓淡。
// 「跟随封面」进主题,是为了让全新安装的那套配置(文字色跟随封面 + 白描边)本身就是一套可以
// 套回去的主题(「默认」,排第一)。
// textStrokeEnabled/textStrokeColorHex 对应的渲染效果是实心描边(非模糊阴影,见
// LyricsOverlayView.swift 的 OptionalTextStroke)。
//
// 未唱色必须跟文字色同一套:两者是逐字歌词里同一行的两半,只换一半就会出现"浅色卡片配淡白未唱色"
// 这种在白底上看不见的组合(见 04 章决策 33)。
public struct ColorTheme: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var foregroundColorHex: String
    public var karaokeUnsungColorHex: String
    public var backgroundColorHex: String
    /// 背景底下垫毛玻璃(`AppSettings.overlayBackgroundGlass`),背景色当玻璃上的着色。
    public var backgroundGlass: Bool
    /// 毛玻璃浓淡(`AppSettings.overlayGlassIntensity`),只在 `backgroundGlass` 开着时有意义。
    var glassIntensity: OverlayGlassIntensity
    public var textStrokeEnabled: Bool
    public var textStrokeColorHex: String
    /// 文字色(已唱)跟随封面主色(`AppSettings.followsCoverArt`);开着时 `foregroundColorHex` 只是备用色。
    public var followsCoverArt: Bool
    /// 未唱色跟随封面(`AppSettings.karaokeUnsungFollowsCoverArt`);开着时 `karaokeUnsungColorHex` 只是备用色。
    public var karaokeUnsungFollowsCoverArt: Bool

    /// `karaokeUnsungColorHex` 不给就取文字色淡化后的样子(`AppSettings.dimmedForegroundHex`),
    /// 内置预设都走这条,未唱色永远跟自己的文字色成对。
    init(
        id: String = UUID().uuidString, name: String,
        foregroundColorHex: String, karaokeUnsungColorHex: String? = nil, backgroundColorHex: String,
        backgroundGlass: Bool = false, glassIntensity: OverlayGlassIntensity = .default,
        textStrokeEnabled: Bool, textStrokeColorHex: String,
        followsCoverArt: Bool = false, karaokeUnsungFollowsCoverArt: Bool = false
    ) {
        self.id = id
        self.name = name
        self.foregroundColorHex = foregroundColorHex
        self.karaokeUnsungColorHex = karaokeUnsungColorHex ?? AppSettings.dimmedForegroundHex(foregroundColorHex)
        self.backgroundColorHex = backgroundColorHex
        self.backgroundGlass = backgroundGlass
        self.glassIntensity = glassIntensity
        self.textStrokeEnabled = textStrokeEnabled
        self.textStrokeColorHex = textStrokeColorHex
        self.followsCoverArt = followsCoverArt
        self.karaokeUnsungFollowsCoverArt = karaokeUnsungFollowsCoverArt
    }

    // 手写解码,兼容两类老 JSON:
    //
    // 一、没有 karaokeUnsungColorHex 的主题:按文字色淡化补上,跟内置预设同一条派生规则;
    //     没有 backgroundGlass 和两个「跟随封面」的都按关着算,没有浓淡的按默认档。
    //
    // 二、描边两个字段早先叫 textShadowEnabled / textShadowColorHex(那会儿渲染的确是模糊阴影,
    // 后来换成实心描边才一起改的名),改名时没做迁移 —— 于是任何在那之前存过自定义主题的
    // 用户,合成的 Codable 解到旧 JSON 会抛 keyNotFound,而 AppSettings 那边是
    // `try? JSONDecoder().decode([ColorTheme].self, …)`,**整个数组**被吞成空:界面上一个
    // 自定义主题都不剩,用户以为自己存的东西没了。
    //
    // 比"看不见"更糟的是下一步:数组已经是空的,用户再存一个新主题时,didSet 会把这个只有
    // 一条的新数组整体编码回写,旧 JSON 被覆盖 —— 那才是真的不可恢复。所以这不只是显示
    // 问题,是一条数据丢失路径。
    //
    // 实测复现:
    //   DecodingError.keyNotFound: Key 'textStrokeEnabled' not found …
    //
    // 只写 init(from:) 不写 encode(to:):编码继续用合成的那份,也就是**只写新名字**,旧名
    // 只在读的时候认。这样迁移是一次性的 —— 存过一次之后 JSON 里就没有旧名了。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        foregroundColorHex = try c.decode(String.self, forKey: .foregroundColorHex)
        karaokeUnsungColorHex = try c.decodeIfPresent(String.self, forKey: .karaokeUnsungColorHex)
            ?? AppSettings.dimmedForegroundHex(foregroundColorHex)
        backgroundColorHex = try c.decode(String.self, forKey: .backgroundColorHex)
        backgroundGlass = try c.decodeIfPresent(Bool.self, forKey: .backgroundGlass) ?? false
        glassIntensity = (try? c.decodeIfPresent(OverlayGlassIntensity.self, forKey: .glassIntensity)) ?? .default
        textStrokeEnabled = try c.decodeIfPresent(Bool.self, forKey: .textStrokeEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .legacyTextShadowEnabled)
            ?? false
        textStrokeColorHex = try c.decodeIfPresent(String.self, forKey: .textStrokeColorHex)
            ?? c.decodeIfPresent(String.self, forKey: .legacyTextShadowColorHex)
            ?? "#000000A6"
        followsCoverArt = try c.decodeIfPresent(Bool.self, forKey: .followsCoverArt) ?? false
        karaokeUnsungFollowsCoverArt = try c.decodeIfPresent(Bool.self, forKey: .karaokeUnsungFollowsCoverArt) ?? false
    }

    // 必须手写:CodingKeys 里多了两个没有对应属性的 legacy case,合成的 encode 编不出来。
    // 只写新名字 —— 旧名是纯粹的读兼容,不该被再写回磁盘。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(foregroundColorHex, forKey: .foregroundColorHex)
        try c.encode(karaokeUnsungColorHex, forKey: .karaokeUnsungColorHex)
        try c.encode(backgroundColorHex, forKey: .backgroundColorHex)
        try c.encode(backgroundGlass, forKey: .backgroundGlass)
        try c.encode(glassIntensity, forKey: .glassIntensity)
        try c.encode(textStrokeEnabled, forKey: .textStrokeEnabled)
        try c.encode(textStrokeColorHex, forKey: .textStrokeColorHex)
        try c.encode(followsCoverArt, forKey: .followsCoverArt)
        try c.encode(karaokeUnsungFollowsCoverArt, forKey: .karaokeUnsungFollowsCoverArt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, foregroundColorHex, karaokeUnsungColorHex, backgroundColorHex, backgroundGlass, glassIntensity
        case textStrokeEnabled, textStrokeColorHex, followsCoverArt, karaokeUnsungFollowsCoverArt
        case legacyTextShadowEnabled = "textShadowEnabled"
        case legacyTextShadowColorHex = "textShadowColorHex"
    }
}

extension ColorTheme {
    // 内置预设。第一套「默认」就是全新安装的那套配置(defaultTheme);后面六套每套一种风格,把主题能配的
    // 几样(已唱 / 未唱 / 背景含毛玻璃 / 描边)各用出一个方向:
    //   墨字白边  黑字 + 白描边,透明底 —— 靠描边在任何壁纸上托字;跟「默认」只差文字色不跟随封面
    //   卡拉OK    黄色已唱 + 白色未唱 + 深色描边 —— 逐字进度一眼看得出唱到哪
    //   夜幕卡片  白字压在近黑的实心卡片上 —— 最稳的可读性
    //   磨砂玻璃  深灰字 + 超薄白色毛玻璃,底下透出模糊的壁纸
    //   纸白卡片  深灰字压在暖白卡片上 —— 浅色风格
    //   霓虹      白字 + 深洋红描边
    //
    // 可读性底线(改色值前先复算):已唱对紧贴的底色(有描边看描边,有卡片看卡片叠在壁纸上的合成色)
    // 最坏对比度 ≥ 6,未唱 ≥ 3.3。"最坏"取白 / 黑 / 中灰三种壁纸,毛玻璃再乘浅 / 深两种系统外观。
    // 各套的实测值与算法见 04 章决策 34。未唱比已唱淡是逐字进度的本意,但淡到 2.4 就看不清了。
    // id 用固定字符串:内置预设每次都是新构造的实例,固定 id 才能稳定地当 ForEach 的身份。
    //
    // 必须是**计算属性**(`{ ... }`,每次读都重新求值):预设名走 L10n.t,设置树靠 .id(L10n.current)
    // 支持不重启切换语言,`static let` 或带初始值的 `static var`(惰性存储属性,只求值一次)都会把名字
    // 冻结在进程内第一次访问时的语言上。访问点都在设置页 / 菜单渲染路径上,不在热路径,每次重建
    // 7 个 struct 的开销可以忽略。
    public static var builtInPresets: [ColorTheme] { [
        initialDefault,
        inkOutline,
        ColorTheme(
            id: "builtin-karaoke", name: L10n.t("卡拉OK"),
            foregroundColorHex: "#FFD60AFF", karaokeUnsungColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
            textStrokeEnabled: true, textStrokeColorHex: "#000000E6"
        ),
        ColorTheme(
            id: "builtin-night-card", name: L10n.t("夜幕卡片"),
            foregroundColorHex: "#FFFFFFFF", karaokeUnsungColorHex: "#FFFFFF99", backgroundColorHex: "#121214D9",
            textStrokeEnabled: false, textStrokeColorHex: "#000000A6"
        ),
        // 超薄毛玻璃 + 六成白色着色 + 深灰字。毛玻璃跟系统深浅色走,着色要厚到深色外观下也压得成浅底,
        // 字才能用深色;白字在浅色外观下几乎看不见(对比度约 1)。
        ColorTheme(
            id: "builtin-frosted-glass", name: L10n.t("磨砂玻璃"),
            foregroundColorHex: "#1C1C1EFF", karaokeUnsungColorHex: "#1C1C1EB3", backgroundColorHex: "#FFFFFF99",
            backgroundGlass: true, glassIntensity: .ultraThin,
            textStrokeEnabled: false, textStrokeColorHex: "#FFFFFFA6"
        ),
        ColorTheme(
            id: "builtin-paper-card", name: L10n.t("纸白卡片"),
            foregroundColorHex: "#1C1C1EFF", karaokeUnsungColorHex: "#1C1C1E99", backgroundColorHex: "#F7F4EDEB",
            textStrokeEnabled: false, textStrokeColorHex: "#FFFFFFA6"
        ),
        ColorTheme(
            id: "builtin-neon", name: L10n.t("霓虹"),
            foregroundColorHex: "#FFFFFFFF", karaokeUnsungColorHex: "#FFFFFFBF", backgroundColorHex: "#00000000",
            textStrokeEnabled: true, textStrokeColorHex: "#B8127FFF"
        ),
    ] }

    /// 墨字白边:黑字 + 透明底 + 不透明白描边,未唱是 55% 黑。单独命名是因为 `defaultTheme` 要引用它,
    /// "默认配色"和"预设列表里第 N 项"是两件事,不靠数组下标耦合。
    public static var inkOutline: ColorTheme {
        ColorTheme(
            id: "builtin-ink-outline", name: L10n.t("墨字白边"),
            foregroundColorHex: "#000000FF", karaokeUnsungColorHex: "#0000008C", backgroundColorHex: "#00000000",
            textStrokeEnabled: true, textStrokeColorHex: "#FFFFFFFF"
        )
    }

    /// 上一轮的六套内置主题(按当时的四个字段:文字色 / 背景色 / 描边开关 / 描边色)。只给升级迁移用
    /// (`AppSettings.migrateLegacyBuiltInTheme`):当前配色正好是其中一套时,用原名存进「我的配色主题」。
    /// 色值必须保持当时的原样,不能跟着新预设调。
    static var legacyBuiltInPresets: [ColorTheme] { [
        ColorTheme(id: "legacy-classic-white", name: L10n.t("经典白字"),
                   foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
                   textStrokeEnabled: false, textStrokeColorHex: "#000000A6"),
        ColorTheme(id: "legacy-white-stroke", name: L10n.t("白字描边"),
                   foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
                   textStrokeEnabled: true, textStrokeColorHex: "#000000A6"),
        ColorTheme(id: "legacy-classic-black", name: L10n.t("经典黑字"),
                   foregroundColorHex: "#000000FF", backgroundColorHex: "#00000000",
                   textStrokeEnabled: false, textStrokeColorHex: "#FFFFFFFF"),
        ColorTheme(id: "legacy-black-stroke", name: L10n.t("黑字描边"),
                   foregroundColorHex: "#000000FF", backgroundColorHex: "#00000000",
                   textStrokeEnabled: true, textStrokeColorHex: "#FFFFFFFF"),
        ColorTheme(id: "legacy-dark-card", name: L10n.t("深色卡片"),
                   foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#000000B3",
                   textStrokeEnabled: false, textStrokeColorHex: "#000000A6"),
        ColorTheme(id: "legacy-light-card", name: L10n.t("浅色卡片"),
                   foregroundColorHex: "#000000FF", backgroundColorHex: "#FFFFFFB3",
                   textStrokeEnabled: false, textStrokeColorHex: "#FFFFFFA6"),
    ] }

    /// 上一轮判"当前是哪套"的口径:只比四个字段,描边关着时不比描边色。迁移沿用它,才能认出用户当时
    /// 在界面上看到的那个主题名。
    func matchesLegacyFields(foregroundHex: String, backgroundHex: String, strokeEnabled: Bool, strokeHex: String) -> Bool {
        foregroundColorHex == foregroundHex
            && backgroundColorHex == backgroundHex
            && textStrokeEnabled == strokeEnabled
            && (!strokeEnabled || textStrokeColorHex == strokeHex)
    }

    /// 「默认」:全新安装的那套配置 —— 墨字白边的颜色 + 已唱、未唱都跟随封面
    /// (`AppSettings.defaultFollowsCoverArt` / `defaultKaraokeUnsungFollowsCoverArt`)。
    public static var initialDefault: ColorTheme {
        let ink = inkOutline
        return ColorTheme(
            id: "builtin-default", name: L10n.t("默认"),
            foregroundColorHex: ink.foregroundColorHex, karaokeUnsungColorHex: ink.karaokeUnsungColorHex,
            backgroundColorHex: ink.backgroundColorHex,
            textStrokeEnabled: ink.textStrokeEnabled, textStrokeColorHex: ink.textStrokeColorHex,
            followsCoverArt: AppSettings.defaultFollowsCoverArt,
            karaokeUnsungFollowsCoverArt: AppSettings.defaultKaraokeUnsungFollowsCoverArt
        )
    }

    /// 首次安装、「恢复默认文字与配色」、「清除所有配置」之后的配色(AppSettings.init() 和
    /// `OverlayStyleDefaults.restoreTextAndColors` 都读它)。备用的黑字透明底完全靠白描边托字:深色壁纸上
    /// 不如自带底衬的卡片可靠,如果以后有"装上看不见歌词"的反馈,先想到这里。
    public static var defaultTheme: ColorTheme { initialDefault }

    // 跟"是不是同一个主题"(id/name)无关,只比较真正影响观感的配色字段——用来判断
    // "当前配色是不是正好等于某个预设/自定义主题",给「主题」预览卡的选中框、工具栏摘要和
    // 快捷菜单的勾当依据(`OverlayThemeSettingsRows.currentThemeLabel`)。看不见的值不参与比较:
    // 描边关着时的描边色、跟随封面开着时的那个备用色。
    public func hasSameColors(as other: ColorTheme) -> Bool {
        followsCoverArt == other.followsCoverArt
            && (followsCoverArt || foregroundColorHex == other.foregroundColorHex)
            && karaokeUnsungFollowsCoverArt == other.karaokeUnsungFollowsCoverArt
            && (karaokeUnsungFollowsCoverArt || karaokeUnsungColorHex == other.karaokeUnsungColorHex)
            && backgroundColorHex == other.backgroundColorHex
            && backgroundGlass == other.backgroundGlass
            && (!backgroundGlass || glassIntensity == other.glassIntensity)
            && textStrokeEnabled == other.textStrokeEnabled
            && (!textStrokeEnabled || textStrokeColorHex == other.textStrokeColorHex)
    }

    /// 当前设置里的配色打包成一个无名主题:存为新主题、用当前配色覆盖、判断"当前是哪套"都读它。
    @MainActor
    static func current(_ settings: AppSettings, name: String = "") -> ColorTheme {
        ColorTheme(
            name: name,
            foregroundColorHex: settings.foregroundColorHex,
            karaokeUnsungColorHex: settings.karaokeUnsungColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            backgroundGlass: settings.overlayBackgroundGlass,
            glassIntensity: settings.overlayGlassIntensity,
            textStrokeEnabled: settings.textStrokeEnabled,
            textStrokeColorHex: settings.textStrokeColorHex,
            followsCoverArt: settings.followsCoverArt,
            karaokeUnsungFollowsCoverArt: settings.karaokeUnsungFollowsCoverArt
        )
    }

    /// 套用这个主题——设置页「主题」预览卡和悬浮窗快捷设置菜单(`OverlayQuickSettingsMenu`)
    /// 套用同一批内置/自定义主题,两处都调这个方法。
    @MainActor
    func apply(to settings: AppSettings) {
        // 两处「跟随封面」按主题自己的值写:固定色主题会把它们关掉,不然套用之后颜色看起来毫无反应
        // (被跟随封面接管了);「默认」这类跟随封面的主题则把它打开。
        settings.followsCoverArt = followsCoverArt
        settings.karaokeUnsungFollowsCoverArt = karaokeUnsungFollowsCoverArt
        settings.foregroundColorHex = foregroundColorHex
        settings.karaokeUnsungColorHex = karaokeUnsungColorHex
        settings.backgroundColorHex = backgroundColorHex
        settings.overlayBackgroundGlass = backgroundGlass
        if backgroundGlass { settings.overlayGlassIntensity = glassIntensity }
        settings.textStrokeEnabled = textStrokeEnabled
        settings.textStrokeColorHex = textStrokeColorHex
    }
}

extension ColorTheme {
    /// 所有「点一下套用主题」的入口都走这里(设置页主题库、「我的配色主题」、悬浮窗快捷菜单)。
    ///
    /// 套用会整套覆盖当前配色;当前配色要是手调过、还没存成主题(跟哪一套都对不上),先记一份到
    /// `UnsavedColorThemeSnapshot`,不然「自定义」那张卡随即消失、手调的颜色就找不回来了。
    @MainActor
    func applyKeepingUnsaved(to settings: AppSettings) {
        ColorTheme.rememberUnsaved(settings)
        apply(to: settings)
    }

    /// 当前配色手调过、还没存成主题时记一份(`UnsavedColorThemeSnapshot`)。整套覆盖配色之前调:套用主题、恢复默认。
    @MainActor
    static func rememberUnsaved(_ settings: AppSettings) {
        let current = ColorTheme.current(settings)
        if !UnsavedColorThemeSnapshot.isKnown(current, settings: settings) {
            UnsavedColorThemeSnapshot.save(current)
        }
    }
}

/// 套用主题之前那套手调、没存过的配色。只留最近一份;「我的配色主题」里显示成一张可恢复的卡,
/// 点一下套回去(恢复之后当前配色又是「没存过」,那张「自定义」卡照旧出现,可以接着存)。
enum UnsavedColorThemeSnapshot {
    private static let key = "np:unsavedColorThemeSnapshotJSON"

    static func load() -> ColorTheme? {
        guard let json = UserDefaults.standard.string(forKey: key), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ColorTheme.self, from: data)
    }

    static func save(_ theme: ColorTheme) {
        guard let data = try? JSONEncoder().encode(theme), let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: key)
    }

    /// 这套配色是不是已经在内置主题或「我的配色主题」里(是的话不用单独留着)。
    @MainActor
    static func isKnown(_ theme: ColorTheme, settings: AppSettings) -> Bool {
        (ColorTheme.builtInPresets + settings.customColorThemes).contains { $0.hasSameColors(as: theme) }
    }
}

extension ColorTheme {
    /// 悬浮窗快捷菜单「配色主题」子菜单条目左边的四段色条(已唱 / 未唱 / 背景 / 描边)。
    func swatchImage() -> NSImage {
        ThemeSwatch.image(
            foregroundHex: foregroundColorHex, foregroundFollowsCover: followsCoverArt,
            unsungHex: karaokeUnsungColorHex, unsungFollowsCover: karaokeUnsungFollowsCoverArt,
            backgroundHex: backgroundColorHex,
            strokeEnabled: textStrokeEnabled, strokeHex: textStrokeColorHex
        )
    }
}
