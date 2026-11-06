import Foundation

/// 升级后多了这个人系统语言的界面时,提示他切过去。只管手动选过界面语言的人:「跟随系统」的升级后自己就换了。
/// 状态与界面在 App 侧 `WhatsNewCenter` 和菜单栏面板顶部的横条。见 14 章决策 180。
public enum NewLanguageOffer {
    /// 记「上次启动时有哪些语言包」之前的版本(1.12.x 及更早)带的语言包:老用户第一次跑到这套代码时按它算。
    public static let legacyPacks = ["zh-hans", "zh-hant", "en", "ja", "ko", "es", "fr", "de"]

    /// 这次启动该提示切到哪个语言包,不提示为 nil。
    /// - chosen: 用户选的界面语言(`np:appLanguage`);nil 或 "system" 是跟随系统。
    /// - knownPacks: 上次启动时记下的语言包;nil 时老用户(`isExistingUser`)按 `legacyPacks`,新装的按现有的全部(不提示)。
    /// 按系统语言列表协商出的语言包跟他选的不一样、又是上次启动时还没有的,才提示。
    public static func offer(chosen: String?, preferredLanguages: [String], knownPacks: [String]?,
                             isExistingUser: Bool) -> String? {
        guard let chosen, chosen != "system", UILanguage.packs.contains(chosen) else { return nil }
        let candidate = UILanguage.resolve(preferredLanguages: preferredLanguages)
        guard candidate != chosen else { return nil }
        let known = knownPacks ?? (isExistingUser ? legacyPacks : UILanguage.packs)
        return known.contains(candidate) ? nil : candidate
    }

    /// 存着的提示还该不该出:他已经切到那种语言、改回了跟随系统,或者那个语言包没了,就不出。
    public static func stillApplies(pending: String?, chosen: String?) -> Bool {
        guard let pending, let chosen, chosen != "system" else { return false }
        return pending != chosen && UILanguage.packs.contains(pending)
    }
}
