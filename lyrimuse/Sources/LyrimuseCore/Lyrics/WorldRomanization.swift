import Foundation

/// 日 / 韩 / 中以外几种文字的读音:泰文(RTGS)、西里尔字母(各国官方体系)、希腊字母(ELOT 743)、
/// 天城文 / 孟加拉文 / 古木基文 / 古吉拉特文 / 泰米尔文 / 泰卢固文 / 卡纳达文 / 马拉雅拉姆文(ISO 15919)、
/// 僧伽罗文(斯里兰卡国家体系)。阿拉伯字母、希伯来字母平时不写短元音,
/// 联合国体系要求元音标全才能转,这里不转,只显示歌词源自带的读音。见 10 章决策 49、51 与 10 章决策 53。
public enum WorldRomanization {
    /// 能认出来的几种文字。`arabic` 只用来归开关(源自带读音),不现算。
    enum Family: CaseIterable, Hashable {
        case cyrillic, greek, thai, indic(IndicScript), arabic

        static let allCases: [Family] = [.cyrillic, .greek, .thai] + IndicScript.allCases.map(Family.indic) + [.arabic]

        /// 各文字的范围以各自转写模块为准,这里只转一手。
        func contains(_ s: Unicode.Scalar) -> Bool {
            let v = s.value
            switch self {
            case .cyrillic: return CyrillicRomanization.isCyrillic(s)
            case .greek: return GreekRomanization.isGreek(s)
            case .thai: return ThaiRomanization.isThai(s)
            case .indic(let script): return script.range.contains(v)
            case .arabic:
                return (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
                    || (0xFB50...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
            }
        }
    }

    /// 出现最多的那种文字;一个都没有返回 nil。
    static func dominantFamily(_ text: String) -> Family? {
        var counts: [Family: Int] = [:]
        for s in text.unicodeScalars where s.value >= 0x0370 {
            if let f = Family.allCases.first(where: { $0.contains(s) }) { counts[f, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// 文字种类 → 归哪个开关。西里尔字母要看语言:整首歌已经认出是哪种西里尔语言就用它;整首认成不支持的
    /// 西里尔语言就不出读音;整首不是西里尔字母时按这段文字自己认(中文歌里夹的一句俄语)。认不出返回 `.other`。
    static func script(of family: Family, text: String, song: LyricScript) -> LyricScript {
        switch family {
        case .cyrillic:
            if song.cyrillicLanguage != nil { return song }
            if song == .unsupportedCyrillic { return .other }
            return lineCyrillic.value(for: text) { line in
                CyrillicRomanization.detectLanguage(line).map(LyricScript.init(cyrillic:)) ?? .other
            }
        case .greek: return .greek
        case .thai: return .thai
        case .indic(.devanagari): return .hindi
        case .indic(.bengali): return .bengali
        case .indic(.gurmukhi): return .punjabi
        case .indic(.gujarati): return .gujarati
        case .indic(.tamil): return .tamil
        case .indic(.telugu): return .telugu
        case .indic(.kannada): return .kannada
        case .indic(.malayalam): return .malayalam
        case .indic(.sinhala): return .sinhala
        case .arabic: return .arabic
        }
    }

    private static let lineCyrillic = BoundedMemo<LyricScript>(limit: 512)

    /// 一行里这几种文字的片段换成拉丁字母,其余字符(拉丁字母、汉字、谚文、阿拉伯字母……)原样保留。
    /// 西里尔字母按 `song` 认出的语言转;整首歌不是西里尔语言时按这一行自己认,认不出就不转。
    public static func romanize(_ text: String, song: LyricScript) -> String {
        var out = text
        if ThaiRomanization.containsThai(out) { out = ThaiRomanization.romanize(out) }
        if GreekRomanization.containsGreek(out) { out = GreekRomanization.romanize(out) }
        if IndicRomanization.script(of: out) != nil { out = IndicRomanization.romanize(out) }
        if CyrillicRomanization.containsCyrillic(out),
            let language = script(of: .cyrillic, text: out, song: song).cyrillicLanguage
        {
            out = CyrillicRomanization.romanize(out, language: language)
        }
        return out
    }
}
