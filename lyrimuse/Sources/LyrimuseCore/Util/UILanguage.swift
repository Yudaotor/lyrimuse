import Foundation

/// 界面语言协商:系统首选语言标签 → 语言包目录名("zh-hans" / "zh-hant" / "en")。
///
/// 加繁体界面时从 App 层的 `L10n.current` 下沉到这里,两个理由:① selftest 只依赖
/// LyrimuseCore,判定不下沉就钉不住 zh-Hant-TW / zh-HK / zh-Hans-HK / 裸 zh 这些标签的分流;
/// ② `AppSettings.userReadsSimplifiedChinese`(引导页播放器排序用)原来自己写了一份同样的
/// 港台标记判断,两份规则各写一遍迟早漂。
///
/// 规则(按优先级):
///   1. 以 "en" 开头 → 英文包。
///   2. 不以 "zh" 开头 → 退回简体包:简体是这个项目的开发语言,没有对应语言包时至少是能读的原文,
///      不该冒出一句读不懂的英文兜底。
///   3. 中文:显式 script 子标签优先 —— 含 "hans" 一定是简体(zh-Hans-HK 是「香港的简体用户」,
///      不能被地区码拉去繁体),含 "hant" 一定是繁体;两者都没写才看地区码,-TW / -HK / -MO 按繁体,
///      其余(裸 zh、zh-CN、zh-SG …)按简体。
public enum UILanguage {
    public static let traditionalRegions = ["-tw", "-hk", "-mo"]

    public static func resolve(preferred: String) -> String {
        let tag = preferred.lowercased()
        if tag.hasPrefix("en") { return "en" }
        guard tag.hasPrefix("zh") else { return "zh-hans" }
        return isTraditionalChineseTag(tag) ? "zh-hant" : "zh-hans"
    }

    /// 一个 zh 标签该不该按繁体处理。只管 zh 家族;传进别的语言标签一律 false。
    public static func isTraditionalChineseTag(_ tag: String) -> Bool {
        let t = tag.lowercased()
        guard t.hasPrefix("zh") else { return false }
        if t.contains("hans") { return false }
        if t.contains("hant") { return true }
        return traditionalRegions.contains { t.contains($0) }
    }

    /// 语言包目录名 → 系统 API 认的 locale 标识("zh-hant" → "zh-Hant")。加一种语言要在这里加映射。
    public static func localeIdentifier(for pack: String) -> String {
        switch pack {
        case "en": return "en"
        case "zh-hant": return "zh-Hant"
        default: return "zh-Hans"
        }
    }

    /// 别的 App 的本地化目录名(「zh_CN」「zh-Hant」「English」这类)归哪个语言包,不是这三种语言时为 nil。中文的简繁
    /// 跟界面语言协商用同一个判据(`isTraditionalChineseTag`);跟 `resolve` 不同,别的语言不退回简体包。
    public static func pack(forLocalization name: String) -> String? {
        let tag = name.lowercased().replacingOccurrences(of: "_", with: "-")
        if tag.hasPrefix("en") { return "en" }
        guard tag.hasPrefix("zh") || tag == "chinese" else { return nil }
        return isTraditionalChineseTag(tag) ? "zh-hant" : "zh-hans"
    }
}
