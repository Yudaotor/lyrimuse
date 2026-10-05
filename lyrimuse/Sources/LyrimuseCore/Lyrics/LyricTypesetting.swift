import CoreText
import Foundation

/// 歌词文字按哪种语言排字。
///
/// 选的字体里没有的字,系统会换一款字体补上;换哪一款要看文字标的语言,不标就按系统语言挑。汉字在
/// 中文、日文里共用一个编码、写法不同,不标的话日文歌词会被画成中文字形,标了 `ja` 才用日文字体;
/// 繁体同理。**画字和量宽度必须用同一个标注**:标了 `ja` 之后同一行的宽度会变,按宽度断句的
/// 「放得下」靠量宽度,口径不一就失准。见 08 章决策 27。
///
/// 逐词画、逐词量时单个词看不出语言(「夢中」只有汉字),所以日文要看整首歌:当前这首是日文歌时,
/// 主行里含汉字的文字都按日文排。译文行不按日文算 —— 日文歌的译文是中文。
public enum LyricTypesetting {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var japaneseSong = false
    nonisolated(unsafe) private static var traditionalChinese = false

    /// 当前这首是不是日文歌(加载歌词时设,判据同 `JapaneseKanjiRepair` 用的 `Romanizer.looksJapaneseSong`)。
    public static func setJapaneseSong(_ value: Bool) {
        lock.lock()
        japaneseSong = value
        lock.unlock()
    }

    /// 当前这首是不是日文歌(`setJapaneseSong` 设的值)。
    static var isJapaneseSong: Bool {
        lock.lock()
        defer { lock.unlock() }
        return japaneseSong
    }

    /// 简繁显示是不是设成了繁体。
    public static func setTraditionalChinese(_ value: Bool) {
        lock.lock()
        traditionalChinese = value
        lock.unlock()
    }

    /// 这段文字该标的语言(BCP 47),nil = 不标、按系统语言。`translation` 为真时是译文行。
    public static func language(for text: String, translation: Bool = false) -> String? {
        lock.lock()
        let japanese = japaneseSong
        let traditional = traditionalChinese
        lock.unlock()
        return language(for: text, translation: translation, japaneseSong: japanese, traditionalChinese: traditional)
    }

    /// 纯函数,selftest 直接覆盖。
    public static func language(for text: String, translation: Bool,
                                japaneseSong: Bool, traditionalChinese: Bool) -> String? {
        var han = false
        for scalar in text.unicodeScalars {
            if !translation, isKana(scalar) { return "ja" }
            if !han, isHan(scalar) { han = true }
        }
        guard han else { return nil }
        if !translation, japaneseSong { return "ja" }
        return traditionalChinese ? "zh-Hant" : nil
    }

    /// 富文本里标语言用的属性键(CoreText 的 `kCTLanguageAttributeName`,AppKit 画字与量宽度都认)。
    public static let attributeKey = NSAttributedString.Key(kCTLanguageAttributeName as String)

    /// 在一组富文本属性上补语言标注;不用标时原样返回。
    public static func attributes(_ base: [NSAttributedString.Key: Any], for text: String,
                                  translation: Bool = false) -> [NSAttributedString.Key: Any] {
        guard let language = language(for: text, translation: translation) else { return base }
        var attrs = base
        attrs[attributeKey] = language
        return attrs
    }

    /// 片假名区里的中点「・」(U+30FB)中文歌词也用,不算假名。
    private static func isKana(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x30FB: return false
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true
        default: return false
        }
    }

    private static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: return true
        default: return false
        }
    }
}
