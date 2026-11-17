import CoreText
import Foundation

/// 字体选择器列出来的系统字体族。这一趟要等 fontd(冷读几百毫秒到几秒),只在后台调;用的全是 Core Text 函数,
/// 可以在任意线程上调。结果跟 `NSFontManager.availableFontFamilies` + `localizedName(forFamily:face: nil)` 逐项一致
/// (selftest 对拍),见 04 章决策 105。
public enum SystemFontFamilies {
    public struct Snapshot: Equatable, Sendable {
        /// 去掉点号开头的系统内部字体(.AppleSystemUIFont 这类),按不区分大小写排序。
        public let families: [String]
        /// 本地化名跟族名不同的那些族:族名 → 本地化名(按系统首选语言,中文字体的族名是英文的)。
        public let localizedNames: [String: String]

        public init(families: [String], localizedNames: [String: String]) {
            self.families = families
            self.localizedNames = localizedNames
        }
    }

    public static func read() -> Snapshot {
        let families = ((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var localized: [String: String] = [:]
        for family in families {
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            // 拿不到本地化名时回的是族名本身,所以判据是「跟族名不同」。
            if let name = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontFamilyNameAttribute, nil) as? String,
               name != family {
                localized[family] = name
            }
        }
        return Snapshot(families: families, localizedNames: localized)
    }
}
