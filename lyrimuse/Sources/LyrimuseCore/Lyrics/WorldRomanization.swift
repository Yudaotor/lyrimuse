import Foundation

/// 日 / 韩 / 中以外几种文字的读音:泰文(RTGS)、西里尔字母(各国体系 / ISO 9)、希腊字母(ELOT 743)、
/// 天城文 / 古木基文 / 泰米尔文 / 僧伽罗文(ISO 15919)。阿拉伯字母、希伯来字母平时不写短元音,
/// 联合国体系要求元音标全才能转,这里不转,只显示歌词源自带的读音。见 10 章决策 49。
public enum WorldRomanization {
    /// 能认出来的几种文字。`arabic` 只用来归开关(源自带读音),不现算。
    enum Family: CaseIterable {
        case cyrillic, greek, thai, devanagari, gurmukhi, tamil, sinhala, arabic

        func contains(_ s: Unicode.Scalar) -> Bool {
            let v = s.value
            switch self {
            case .cyrillic: return (0x0400...0x052F).contains(v)
            case .greek: return (0x0370...0x03FF).contains(v) || (0x1F00...0x1FFF).contains(v)
            case .thai: return (0x0E01...0x0E4F).contains(v) || (0x0E5A...0x0E5B).contains(v)
            case .devanagari: return (0x0900...0x097F).contains(v)
            case .gurmukhi: return (0x0A00...0x0A7F).contains(v)
            case .tamil: return (0x0B80...0x0BFF).contains(v)
            case .sinhala: return (0x0D80...0x0DFF).contains(v)
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

    /// 文字种类 → 归哪个开关。西里尔字母要看语言:整首歌已经认出是哪种西里尔语言就用它,
    /// 否则按这段文字自己认(中文歌里夹的一句俄语)。认不出(不支持的语言)返回 `.other`。
    static func script(of family: Family, text: String, song: LyricScript) -> LyricScript {
        switch family {
        case .cyrillic:
            if song.cyrillicLanguage != nil { return song }
            return lineCyrillic.value(for: text) { line in
                CyrillicRomanization.detectLanguage(line).map(LyricScript.init(cyrillic:)) ?? .other
            }
        case .greek: return .greek
        case .thai: return .thai
        case .devanagari: return .hindi
        case .gurmukhi: return .punjabi
        case .tamil: return .tamil
        case .sinhala: return .sinhala
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
