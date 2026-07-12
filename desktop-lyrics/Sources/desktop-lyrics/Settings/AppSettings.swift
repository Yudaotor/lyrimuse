import Foundation

// 数据源:远程(跟网页版同一个 state-worker /now)或本地(这台 Mac 上直接读
// media-control + collector 的磁盘缓存,零网络)。新增选项,默认保持原有的远程行为。
enum PlaybackSourceMode: String, Codable, Hashable {
    case relay
    case local
}

// UserDefaults 支撑的设置存储。relay 域名默认写死成这个项目自己的地址(个人工具、
// 不打算分发给别人用,零配置优先),其余是歌词展示偏好 + 开机启动开关。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let defaultRelayBaseURL = "https://np.yudaotor.me"

    private enum Keys {
        static let relayBaseURL = "np:relayBaseURL"
        static let preferWordLevelKaraoke = "np:preferWordLevelKaraoke"
        static let showRomanization = "np:showRomanization"
        static let showTranslation = "np:showTranslation"
        static let launchAtLoginEnabled = "np:launchAtLoginEnabled"
        static let dataSourceMode = "np:dataSourceMode"
        static let showNextLinePreview = "np:showNextLinePreview"
        static let fontFamilyName = "np:fontFamilyName"
        static let fontSize = "np:fontSize"
        static let foregroundColorHex = "np:foregroundColorHex"
        static let backgroundColorHex = "np:backgroundColorHex"
    }

    private let defaults = UserDefaults.standard

    @Published var relayBaseURL: String {
        didSet { defaults.set(relayBaseURL, forKey: Keys.relayBaseURL) }
    }
    @Published var preferWordLevelKaraoke: Bool {
        didSet { defaults.set(preferWordLevelKaraoke, forKey: Keys.preferWordLevelKaraoke) }
    }
    @Published var showRomanization: Bool {
        didSet { defaults.set(showRomanization, forKey: Keys.showRomanization) }
    }
    @Published var showTranslation: Bool {
        didSet { defaults.set(showTranslation, forKey: Keys.showTranslation) }
    }
    @Published var launchAtLoginEnabled: Bool {
        didSet {
            defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled)
            LoginItemManager.shared.setEnabled(launchAtLoginEnabled)
        }
    }
    // 只负责持久化——不在这里连带调 PlaybackCoordinator.applyMode(),那样会在
    // AppSettings 自己的 init() 里(设置 dataSourceMode 初始值那行)触发 didSet,
    // 顺带在 AppSettings.shared 还没构造完成时就去访问 PlaybackCoordinator.shared,
    // 有循环初始化的风险。改成跟 relayBaseURL/preferWordLevelKaraoke 一样的既有写法:
    // 设置面板的 Picker 里手动分两步调用(见 SettingsView.swift)。
    @Published var dataSourceMode: PlaybackSourceMode {
        didSet { defaults.set(dataSourceMode.rawValue, forKey: Keys.dataSourceMode) }
    }
    @Published var showNextLinePreview: Bool {
        didSet { defaults.set(showNextLinePreview, forKey: Keys.showNextLinePreview) }
    }
    // 字体族名——空字符串表示"跟随系统",对应悬浮窗原来硬编码的系统字体,不用额外
    // enum/Optional 表达"未设置",跟 relayBaseURL 的空字符串兜底是同一种写法。
    @Published var fontFamilyName: String {
        didSet { defaults.set(fontFamilyName, forKey: Keys.fontFamilyName) }
    }
    // 主歌词行字号(pt)。罗马音/译文/下一句预览三行的字号从这个值按比例换算,
    // 见 AppearanceHelpers.swift 的 romanizationFontSize/secondaryFontSize。
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }
    // #RRGGBBAA。默认不透明白色,跟悬浮窗原来硬编码的 .white 视觉完全一致。
    @Published var foregroundColorHex: String {
        didSet { defaults.set(foregroundColorHex, forKey: Keys.foregroundColorHex) }
    }
    // #RRGGBBAA。默认 alpha=0(全透明),保留"没有背景、文字直接浮在桌面上"的原有观感——
    // 没主动去设置面板改过的人,悬浮窗外观应该跟改动前逐像素一致。
    @Published var backgroundColorHex: String {
        didSet { defaults.set(backgroundColorHex, forKey: Keys.backgroundColorHex) }
    }

    private init() {
        relayBaseURL = defaults.string(forKey: Keys.relayBaseURL) ?? Self.defaultRelayBaseURL
        preferWordLevelKaraoke = (defaults.object(forKey: Keys.preferWordLevelKaraoke) as? Bool) ?? true
        showRomanization = (defaults.object(forKey: Keys.showRomanization) as? Bool) ?? true
        showTranslation = (defaults.object(forKey: Keys.showTranslation) as? Bool) ?? true
        launchAtLoginEnabled = (defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool) ?? false
        dataSourceMode = PlaybackSourceMode(rawValue: defaults.string(forKey: Keys.dataSourceMode) ?? "") ?? .relay
        showNextLinePreview = (defaults.object(forKey: Keys.showNextLinePreview) as? Bool) ?? false
        fontFamilyName = defaults.string(forKey: Keys.fontFamilyName) ?? ""
        fontSize = (defaults.object(forKey: Keys.fontSize) as? Double) ?? 20
        foregroundColorHex = defaults.string(forKey: Keys.foregroundColorHex) ?? "#FFFFFFFF"
        backgroundColorHex = defaults.string(forKey: Keys.backgroundColorHex) ?? "#00000000"
    }
}
