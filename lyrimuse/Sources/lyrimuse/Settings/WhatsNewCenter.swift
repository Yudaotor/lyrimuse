import Foundation
import LyrimuseCore

/// 更新之后的提示(判据在 Core `WhatsNew`):主版本或次版本升级后,第一次打开菜单栏面板时顶部出一条「已更新到 X」,
/// 摆出来一次就记下、之后不再出;点它开「本次更新」卡片(`WhatsNewWindow`)。菜单栏右键菜单「查看本次更新…」和深链
/// `whats-new` 随时开同一张卡片。
///
/// 启动时 `start()` 定这次的基准版本并记下当前版本。几个键都是机器专属的(ConfigPortability.machineLocalDefaultsKeys)。
/// 见 14 章决策 155。
@MainActor
final class WhatsNewCenter {
    static let shared = WhatsNewCenter()

    enum Keys {
        static let lastLaunchedVersion = "np:lastLaunchedVersion"
        static let baseline = "np:whatsNewBaseline"
        /// 面板顶部「已更新」出过的是哪一版。
        static let bannerShown = "np:whatsNewShownVersion"
        /// 上次启动时有哪些语言包(Core `NewLanguageOffer`)。
        static let knownLanguagePacks = "np:knownLanguagePacks"
        /// 还没处理的「改用这种语言」提示:语言包名;切过去或点 ✕ 后删掉。
        static let languageOffer = "np:newLanguageOffer"
    }

    /// 面板顶部该出「已更新到 X」时是当前版本,否则 nil。
    private(set) var bannerVersion: String?

    /// 面板顶部该提示改用哪个语言包,否则 nil。见 14 章决策 180。
    var languageOffer: String? {
        let pending = defaults.string(forKey: Keys.languageOffer)
        return NewLanguageOffer.stillApplies(pending: pending, chosen: L10n.languageOverride) ? pending : nil
    }

    private let defaults = UserDefaults.standard
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let current = SparkleUpdaterManager.appVersionString
        let lastLaunched = defaults.string(forKey: Keys.lastLaunchedVersion)
        if let offer = NewLanguageOffer.offer(chosen: L10n.languageOverride, preferredLanguages: Locale.preferredLanguages,
                                              knownPacks: defaults.stringArray(forKey: Keys.knownLanguagePacks),
                                              isExistingUser: lastLaunched != nil || AppSettings.shared.hasCompletedOnboarding) {
            defaults.set(offer, forKey: Keys.languageOffer)
        }
        defaults.set(UILanguage.packs, forKey: Keys.knownLanguagePacks)
        let baseline = WhatsNew.baseline(current: current, lastLaunched: lastLaunched,
                                         stored: defaults.string(forKey: Keys.baseline),
                                         shownVersion: defaults.string(forKey: Keys.bannerShown),
                                         hasCompletedOnboarding: AppSettings.shared.hasCompletedOnboarding)
        defaults.set(baseline, forKey: Keys.baseline)
        defaults.set(current, forKey: Keys.lastLaunchedVersion)
        bannerVersion = WhatsNew.bannerPending(current: current, baseline: baseline,
                                               shownVersion: defaults.string(forKey: Keys.bannerShown)) ? current : nil
    }

    /// 「改用这种语言」那一条:切过去(`switchTo` 为真)或点了 ✕,都不再出。
    func languageOfferHandled(switchTo: Bool) {
        if switchTo, let pack = languageOffer { AppSettings.shared.appLanguage = pack }
        defaults.removeObject(forKey: Keys.languageOffer)
    }

    /// 用户在设置里改了界面语言:改成提示的那种、或改回跟随系统,提示就删掉,之后再改回别的也不再出。
    func languageChosen(_ chosen: String) {
        guard NewLanguageOffer.settles(pending: defaults.string(forKey: Keys.languageOffer), chosen: chosen) else { return }
        defaults.removeObject(forKey: Keys.languageOffer)
    }

    /// 面板把横条摆出来了:这一版不再出。正开着的面板自己留着那一条到收起。
    func bannerShown() {
        guard let bannerVersion else { return }
        defaults.set(bannerVersion, forKey: Keys.bannerShown)
        self.bannerVersion = nil
    }

    /// 这次更新的内容:包里那份 CHANGELOG.md(build.sh 拷进 Resources)里基准版本之后到当前版本的各节,同名小节并在一起。
    /// 界面是中文取中文(繁体界面由简体转写),别的语言取英文;一节都找不到为空。
    static func currentNotes() -> [ReleaseNotes.Section] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let data = FileIO.read(url), let text = String(data: data, encoding: .utf8) else { return [] }
        let current = SparkleUpdaterManager.appVersionString
        let baseline = UserDefaults.standard.string(forKey: Keys.baseline) ?? current
        let language = L10n.current
        let chinese = language == "zh-hans" || language == "zh-hant"
        let sections = ReleaseNotes.merge(ReleaseNotes.sections(after: baseline, through: current, in: text)
            .map { ReleaseNotes.parse($0, chinese: chinese) })
        guard language == "zh-hant" else { return sections }
        let hant = StringTransform("Hans-Hant")
        return sections.map { section in
            ReleaseNotes.Section(title: section.title.applyingTransform(hant, reverse: false) ?? section.title,
                                 items: section.items.map { $0.applyingTransform(hant, reverse: false) ?? $0 })
        }
    }
}
