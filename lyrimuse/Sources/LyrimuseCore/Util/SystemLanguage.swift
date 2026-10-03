import Foundation

/// 译文语言「跟随系统语言」认的那门语言。App 读本机全局偏好写进 features.json 的 `system_language`,
/// collector 解析 auto 时用它(features.go `resolveLyricsTranslationLanguage`);「翻译语言包」那一行按同一个值算目标。
///
/// 取法:全局偏好 AppleLocale(`zh_CN` / `en_US` / `ja_JP`)下划线前那段转小写,跟 `defaults read -g AppleLocale`
/// 是同一个值,文字子标签原样留着(`zh-Hans_CN` 得 `zh-hans`)。必须跟 collector 的 `appleLocaleLanguage` 逐字一致
/// (两侧共用样例 `shared/testdata/system-language.json`):文件里还没有这个键时 collector 自己查一次,两边对同一台
/// 机器得出不同语言,会被当成译文语言换了、整库机翻清一遍。
///
/// 这个键描述的是这台机器,不随配置包走:导出时去掉,导入时换成本机的值。
public enum SystemLanguage {
    public static let featuresKey = "system_language"

    /// 本机的值。读不到 AppleLocale 时退回首选语言列表的第一项,再没有就是 "en"。
    public static func current() -> String {
        let locale = CFPreferencesCopyValue("AppleLocale" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return code(appleLocale: locale, preferredLanguages: Locale.preferredLanguages)
    }

    public static func code(appleLocale: String?, preferredLanguages: [String]) -> String {
        let fromLocale = appleLocaleLanguage(appleLocale ?? "")
        if !fromLocale.isEmpty { return fromLocale }
        if let first = preferredLanguages.first?.split(separator: "-").first, !first.isEmpty {
            return first.lowercased()
        }
        return "en"
    }

    /// AppleLocale → 语言代码;取不到是空串。
    public static func appleLocaleLanguage(_ raw: String) -> String {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let i = s.firstIndex(of: "_"), i > s.startIndex { s = s[..<i] }
        return s.lowercased()
    }

    /// 配置包 `features` 段导出前去掉;不是对象原样返回。
    public static func strippingForExport(_ features: Any) -> Any {
        guard var dict = features as? [String: Any] else { return features }
        dict.removeValue(forKey: featuresKey)
        return dict
    }

    /// 导入时换成本机的值(包里没有这个键也补上);不是对象原样返回。
    public static func localizingForImport(_ features: Any, local: String) -> Any {
        guard var dict = features as? [String: Any] else { return features }
        dict[featuresKey] = local
        return dict
    }
}
