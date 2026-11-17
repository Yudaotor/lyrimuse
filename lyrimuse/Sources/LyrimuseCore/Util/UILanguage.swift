import Foundation

/// 界面语言协商:系统首选语言列表 → 语言包目录名(`packs` 里的一项)。
///
/// 放在 LyrimuseCore 而不是 App 层的 `L10n`:selftest 只依赖 LyrimuseCore,判定放这里才钉得住各种语言标签的分流;
/// `AppSettings.userReadsSimplifiedChinese`(引导页播放器排序用)也用这里的简繁判据,别各写一份。
///
/// 规则:按系统首选语言列表的顺序,取第一个有语言包的;一个都没有用英文。一个标签归哪个包:
///   - 中文(`isChineseFamilyTag`:zh 和粤语 yue):显式 script 子标签优先 —— 含 "hans" 一定是简体(zh-Hans-HK 是「香港的简体用户」,
///     不能被地区码拉去繁体),含 "hant" 一定是繁体;两者都没写时粤语按繁体,zh 看地区码,-TW / -HK / -MO 按繁体,
///     其余(裸 zh、zh-CN、zh-SG …)按简体。
///   - 葡萄牙语(pt、pt-BR、pt-PT、pt-AO …)都归巴西葡语包 pt-br。
///   - 其余语言按主语言码(en-GB → en),没有这个语言包的跳过、看列表里的下一项。
public enum UILanguage {
    /// 界面有的语言包,顺序就是语言下拉里的顺序。加一种语言:这里加一项,`localeIdentifier(for:)`、`nativeName(of:)` 加映射,
    /// generate-strings.py 的 TARGETS 登记 catalog 语言码 → 目录名(目录名一律小写,SwiftPM 打包会把它转小写)。
    public static let packs = ["zh-hans", "zh-hant", "en", "ja", "ko", "es", "fr", "de", "it", "pt-br", "vi", "ru", "uk", "th", "tr", "hi"]

    public static let traditionalRegions = ["-tw", "-hk", "-mo"]

    public static func resolve(preferredLanguages: [String]) -> String {
        for tag in preferredLanguages {
            if let pack = pack(forTag: tag) { return pack }
        }
        return "en"
    }

    /// 一个语言标签归哪个语言包;界面没有这种语言时为 nil。
    public static func pack(forTag tag: String) -> String? {
        let t = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        if isChineseFamilyTag(t) {
            return isTraditionalChineseTag(t) ? "zh-hant" : "zh-hans"
        }
        let language = t.split(separator: "-").first.map(String.init) ?? t
        if language == "pt" { return "pt-br" }
        // 印地语(拉丁字母)hi-Latn 读的是罗马字印地语,界面只有天城文,不归印地语包,往下一个首选语言找
        if language == "hi" && t.split(separator: "-").contains("latn") { return nil }
        return packs.contains(language) ? language : nil
    }

    /// 写汉字的中文标签:zh、zh-*,以及粤语 yue、yue-*(粤语书面用汉字,系统首选是粤语的人读中文界面)。
    /// 「读不读中文」「界面归哪个中文包」都按它判,别各自写 `hasPrefix("zh")`。
    public static func isChineseFamilyTag(_ tag: String) -> Bool {
        let t = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        return t == "zh" || t.hasPrefix("zh-") || t == "yue" || t.hasPrefix("yue-")
    }

    /// 一个中文标签该不该按繁体处理。只管 `isChineseFamilyTag` 认的标签;传进别的语言标签一律 false。
    /// 粤语没写文字子标签(yue、yue-HK)按繁体:Apple 的粤语默认是 yue-Hant。
    public static func isTraditionalChineseTag(_ tag: String) -> Bool {
        let t = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        guard isChineseFamilyTag(t) else { return false }
        if t.contains("hans") { return false }
        if t.contains("hant") || t == "yue" || t.hasPrefix("yue-") { return true }
        return traditionalRegions.contains { t.contains($0) }
    }

    /// 语言包目录名 → 系统 API 认的 locale 标识("zh-hant" → "zh-Hant")。加一种语言要在这里加映射。
    public static func localeIdentifier(for pack: String) -> String {
        switch pack {
        case "zh-hans": return "zh-Hans"
        case "zh-hant": return "zh-Hant"
        case "pt-br": return "pt-BR"
        default: return pack
        }
    }

    /// 给日期格式器用的 locale 标识:泰语带上系统日历(`systemCalendar` 是日历标识,如 "gregorian"、"buddhist")。
    /// `Locale("th")` 自带佛历,不带的话系统用公历的人也会看到 2569;其余语言同 `localeIdentifier(for:)`,日历由格式器自己跟系统。
    public static func formattingLocaleIdentifier(for pack: String, systemCalendar: String) -> String {
        pack == "th" && !systemCalendar.isEmpty ? "th@calendar=" + systemCalendar : localeIdentifier(for: pack)
    }

    /// 泰语列表:系统 `ListFormatter` 用空格分隔各项(「A B และ C」),项里有空格或拉丁字母(播放器名、服务名)时分不清
    /// 哪几个词是一项,这时照 Apple 泰语并列拉丁名的写法用「, 」分隔、最后一项前加「และ」;纯泰文的项返回 nil,交给系统拼。
    public static func thaiList(_ items: [String]) -> String? {
        guard items.count > 1, items.contains(where: { $0.contains(where: { $0.isWhitespace || ($0.isASCII && $0.isLetter) }) }) else { return nil }
        return items.dropLast().joined(separator: ", ") + " และ " + items[items.count - 1]
    }

    /// 语言下拉里的名字:一律用这种语言自己的写法,哪种界面语言下都不翻译。
    public static func nativeName(of pack: String) -> String {
        switch pack {
        case "zh-hans": return "简体中文"
        case "zh-hant": return "繁體中文"
        case "en": return "English"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "es": return "Español"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "it": return "Italiano"
        case "pt-br": return "Português (Brasil)"
        case "vi": return "Tiếng Việt"
        case "ru": return "Русский"
        case "uk": return "Українська"
        case "th": return "ไทย"
        case "tr": return "Türkçe"
        case "hi": return "हिन्दी"
        default: return pack
        }
    }

    /// 别的 App 的本地化目录名(「zh_CN」「zh-Hant」「English」「Japanese」这类)归哪个语言包,界面没有这种语言时为 nil。
    /// 老式的英文全称目录名先换成语言码,其余同 `pack(forTag:)`。
    public static func pack(forLocalization name: String) -> String? {
        let legacyNames = ["english": "en", "chinese": "zh", "japanese": "ja", "korean": "ko", "spanish": "es", "french": "fr", "german": "de", "italian": "it", "portuguese": "pt", "vietnamese": "vi", "russian": "ru", "ukrainian": "uk", "thai": "th", "turkish": "tr", "hindi": "hi"]
        return pack(forTag: legacyNames[name.lowercased()] ?? name)
    }

    /// 数量的 CLDR 复数类别(只管整数)。`L10n.plural` 按它取「键#one / #few / #many」,`other` 取键本身;
    /// 类别名跟 generate-strings.py 的 PLURAL_FORMS、报告用语的 `plural_rule` 必须一致。
    /// 按 one / few / many 分的语言包;报告用语表的 `plural_rule` 也取这几个值。
    public static let eastSlavicPluralPacks: Set<String> = ["ru", "uk"]

    public enum PluralCategory: String, CaseIterable {
        case one, few, many, other
    }

    /// 这个数量在这种界面语言里属于哪一类:
    ///   - 多数语言只有 1 是 one;法语、葡萄牙语、印地语 0 和 1 都是 one(CLDR one 的整数是 0、1);
    ///   - 俄语、乌克兰语(`eastSlavicPluralPacks`,CLDR 同一套整数规则):个位 1 且末两位不是 11 → one,个位 2～4 且末两位不是 12～14 → few,其余(0、5～20、11～14 …)→ many;
    ///   - 日、韩、越南语、泰语、土耳其语不分单复数(土耳其语数词后的名词不变复数),catalog 里那一条不写成 plural 变体、没有派生键,返回什么都取同一条。
    public static func pluralCategory(_ count: Int, pack: String) -> PluralCategory {
        if eastSlavicPluralPacks.contains(pack) {
            let n = abs(count), mod10 = n % 10, mod100 = n % 100
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        }
        return count == 1 || (count == 0 && (pack == "fr" || pack == "pt-br" || pack == "hi")) ? .one : .other
    }
}
