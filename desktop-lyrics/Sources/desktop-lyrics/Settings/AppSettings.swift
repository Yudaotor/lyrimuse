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

    private init() {
        relayBaseURL = defaults.string(forKey: Keys.relayBaseURL) ?? Self.defaultRelayBaseURL
        preferWordLevelKaraoke = (defaults.object(forKey: Keys.preferWordLevelKaraoke) as? Bool) ?? true
        showRomanization = (defaults.object(forKey: Keys.showRomanization) as? Bool) ?? true
        showTranslation = (defaults.object(forKey: Keys.showTranslation) as? Bool) ?? true
        launchAtLoginEnabled = (defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool) ?? false
        dataSourceMode = PlaybackSourceMode(rawValue: defaults.string(forKey: Keys.dataSourceMode) ?? "") ?? .relay
        showNextLinePreview = (defaults.object(forKey: Keys.showNextLinePreview) as? Bool) ?? false
    }
}
