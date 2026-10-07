import Foundation

/// 某个 App 在指定界面语言下的名字(「Safari浏览器」/「Safari」)。按这个 App 自己带的本地化取:先挑跟界面语言同一种的
/// 语言目录,读那里的 `InfoPlist.strings`(系统自带的 App 是 `InfoPlist.loctable`);这个 App 没有这种语言时退回
/// Info.plist 里的原名,不拿系统语言或别的语言的名字凑数。界面语言是语言包目录名("zh-hans" / "zh-hant" / "en"),
/// 语言目录归哪个语言包见 `UILanguage.pack(forLocalization:)`。
public enum LocalizedAppName {
    public static func name(bundleURL: URL, uiLanguage: String) -> String? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        let preference = UILanguage.localeIdentifier(for: uiLanguage)
        if let loc = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [preference]).first,
           UILanguage.pack(forLocalization: loc) == uiLanguage {
            if let path = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: loc),
               let strings = NSDictionary(contentsOfFile: path), let name = pick(strings) {
                return name
            }
            if let url = bundle.url(forResource: "InfoPlist", withExtension: "loctable"),
               let table = NSDictionary(contentsOf: url), let strings = table[loc] as? NSDictionary, let name = pick(strings) {
                return name
            }
        }
        if let info = bundle.infoDictionary, let name = pick(info as NSDictionary) { return name }
        let base = bundleURL.deletingPathExtension().lastPathComponent
        return base.isEmpty ? nil : base
    }

    private static func pick(_ strings: NSDictionary) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = strings[key] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        }
        return nil
    }
}
