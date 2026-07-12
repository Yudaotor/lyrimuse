import Foundation

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

    private init() {
        relayBaseURL = defaults.string(forKey: Keys.relayBaseURL) ?? Self.defaultRelayBaseURL
        preferWordLevelKaraoke = (defaults.object(forKey: Keys.preferWordLevelKaraoke) as? Bool) ?? true
        showRomanization = (defaults.object(forKey: Keys.showRomanization) as? Bool) ?? true
        showTranslation = (defaults.object(forKey: Keys.showTranslation) as? Bool) ?? true
        launchAtLoginEnabled = (defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool) ?? false
    }
}
