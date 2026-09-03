import Foundation

/// 界面语言协商:系统首选语言标签 → 语言包目录名("zh-hans" / "zh-hant" / "en")。
///
/// 2026-09-03 加繁体界面时从 App 层的 `L10n.current` 下沉到这里,两个理由:① selftest 只依赖
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
}
