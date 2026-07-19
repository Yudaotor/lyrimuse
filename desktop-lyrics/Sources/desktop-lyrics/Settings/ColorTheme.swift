import Foundation

// 经典悬浮窗"配色主题"——用户反馈现在文字/背景/阴影颜色只能逐项手动调,没有"内置预设
// 一键套用"、也没有"把调好的一套另存复用"这两层(对标 PlayStatus/Lyricify/AlgerMusicPlayer/
// HotLyric/VutronMusic 都有的配色主题功能)。只打包这四个"配色"相关字段(不含字体/字号——
// 那是排版,不是配色,两者概念上不是一回事,不该被同一个"主题"捆在一起改动)。
public struct ColorTheme: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var foregroundColorHex: String
    public var backgroundColorHex: String
    public var textShadowEnabled: Bool
    public var textShadowColorHex: String

    public init(
        id: String = UUID().uuidString, name: String,
        foregroundColorHex: String, backgroundColorHex: String,
        textShadowEnabled: Bool, textShadowColorHex: String
    ) {
        self.id = id
        self.name = name
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.textShadowEnabled = textShadowEnabled
        self.textShadowColorHex = textShadowColorHex
    }
}

extension ColorTheme {
    // id 用固定字符串(不是随手 UUID())——内置预设每次启动都是同一份字面量构造出来的
    // 新实例,固定 id 才能让"当前配色是不是正好等于某个内置预设"这类比较(如果以后需要)
    // 有意义;用户自己存的自定义主题才用随机 UUID(见 SettingsView 里"存为新主题"那处)。
    // 用户反馈带阴影的几个预设"太丑了"——统一去掉阴影,四个预设的 textShadowEnabled
    // 都是 false(textShadowColorHex 留着一个合理默认值,单纯是给用户手动重新打开
    // 阴影开关时有个还算顺眼的起始值,不影响预设本身的观感)。
    public static let builtInPresets: [ColorTheme] = [
        ColorTheme(
            id: "builtin-classic", name: L10n.t("经典白字"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
            textShadowEnabled: false, textShadowColorHex: "#000000A6"
        ),
        ColorTheme(
            id: "builtin-warm", name: L10n.t("暖黄"),
            foregroundColorHex: "#FFE29AFF", backgroundColorHex: "#00000000",
            textShadowEnabled: false, textShadowColorHex: "#000000CC"
        ),
        ColorTheme(
            id: "builtin-card", name: L10n.t("深色卡片"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#000000B3",
            textShadowEnabled: false, textShadowColorHex: "#000000A6"
        ),
        ColorTheme(
            id: "builtin-cyan", name: L10n.t("赛博青"),
            foregroundColorHex: "#7DF9FFFF", backgroundColorHex: "#00000000",
            textShadowEnabled: false, textShadowColorHex: "#001A1ACC"
        ),
    ]

    // 跟"是不是同一个主题"(id/name)无关,只比较四个真正影响观感的字段——用来判断
    // "当前配色是不是正好等于某个预设/自定义主题",给菜单标签当"当前生效哪个"的
    // 展示依据(见 SettingsView 的 currentColorThemeLabel)。阴影关闭时阴影颜色不参与
    // 比较:两个主题都关着阴影,颜色值哪怕不同也该算"看起来一样"。
    public func hasSameColors(as other: ColorTheme) -> Bool {
        foregroundColorHex == other.foregroundColorHex
            && backgroundColorHex == other.backgroundColorHex
            && textShadowEnabled == other.textShadowEnabled
            && (!textShadowEnabled || textShadowColorHex == other.textShadowColorHex)
    }
}
