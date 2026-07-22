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
}

extension ColorTheme {
    // id 用固定字符串(不是随手 UUID())——内置预设每次启动都是同一份字面量构造出来的
    // 新实例,固定 id 才能让"当前配色是不是正好等于某个内置预设"这类比较(如果以后需要)
    // 有意义;用户自己存的自定义主题才用随机 UUID(见 SettingsView 里"存为新主题"那处)。
    // 四个预设的 textStrokeEnabled 都是 false(textStrokeColorHex 留着一个合理默认值,
    // 单纯是给用户手动重新打开描边开关时有个还算顺眼的起始值,不影响预设本身的观感)。
    // "经典黑字"跟"经典白字"对称,同时被定为 defaultTheme(见下方)——AppSettings.init()
    // 和 SettingsView"恢复默认外观"按钮统一引用这一个值,不再各自硬编码一遍默认配色
    // 字面量。
    public static let classicBlack = ColorTheme(
        id: "builtin-classic-black", name: L10n.t("经典黑字"),
        foregroundColorHex: "#000000FF", backgroundColorHex: "#00000000",
        textStrokeEnabled: false, textStrokeColorHex: "#000000A6"
    )

    public static let builtInPresets: [ColorTheme] = [
        ColorTheme(
            id: "builtin-classic", name: L10n.t("经典白字"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
            textStrokeEnabled: false, textStrokeColorHex: "#000000A6"
        ),
        classicBlack,
        ColorTheme(
            id: "builtin-warm", name: L10n.t("暖黄"),
            foregroundColorHex: "#FFE29AFF", backgroundColorHex: "#00000000",
            textStrokeEnabled: false, textStrokeColorHex: "#000000CC"
        ),
        ColorTheme(
            id: "builtin-card", name: L10n.t("深色卡片"),
            foregroundColorHex: "#FFFFFFFF", backgroundColorHex: "#000000B3",
            textStrokeEnabled: false, textStrokeColorHex: "#000000A6"
        ),
        // 跟"深色卡片"对称的浅色版本——同样的卡片不透明度(0xB3),前景/背景黑白对调。
        ColorTheme(
            id: "builtin-light-card", name: L10n.t("浅色卡片"),
            foregroundColorHex: "#000000FF", backgroundColorHex: "#FFFFFFB3",
            textStrokeEnabled: false, textStrokeColorHex: "#FFFFFFA6"
        ),
        ColorTheme(
            id: "builtin-cyan", name: L10n.t("赛博青"),
            foregroundColorHex: "#7DF9FFFF", backgroundColorHex: "#00000000",
            textStrokeEnabled: false, textStrokeColorHex: "#001A1ACC"
        ),
    ]

    // 全新安装/"恢复默认外观"/"清除所有配置"之后应该长成的样子——AppSettings.init()
    // 和 SettingsView 的"恢复默认外观"按钮都读这一个值,不再各自硬编码一遍。
    public static let defaultTheme: ColorTheme = classicBlack

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
}
