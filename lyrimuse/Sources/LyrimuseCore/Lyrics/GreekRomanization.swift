import Foundation

/// 希腊字母读音:ELOT 743 转写版(transcription),联合国 1987 年 V/19 决议推荐,同 ISO 843:1997 第 2 类。
/// 表与规则逐条照 UNGEGN 罗马化工作组《联合国罗马化体系现状报告》希腊语那一份(4.0 版):
///   - αυ ευ ηυ:在 β γ δ ζ λ μ ν ρ 和元音前写 av ev iv,在 θ κ ξ π σ τ φ χ ψ 前和词尾写 af ef if;
///     前一个元音带重音或 υ 带分音符时按单个字母转(注 3);重读在 υ 上时重音标在前一个元音上(αύ áv,注 4)。
///   - γγ ng、γξ nx、γχ nch;μπ 在词首词尾写 b、词中写 mp;其余组合(αι ει οι γκ ντ…)按单个字母转(注 2)。
///   - 重音和分音符保留在对应的拉丁元音上。转写版另加的下横线不写(那是转写版 transliteration 的)。
/// 多调符号(送气符等)不写,扬抑符、钝音符当重音。希腊问号「;」写成「?」。见 10 章决策 49。
public enum GreekRomanization {
    public static func containsGreek(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isGreek)
    }

    static func isGreek(_ s: Unicode.Scalar) -> Bool {
        (0x0370...0x03FF).contains(s.value) || (0x1F00...0x1FFF).contains(s.value)
    }

    private struct Letter {
        let base: Character  // 小写、不带任何符号
        let upper: Bool
        let accent: Bool
        let diaeresis: Bool
    }

    private enum Piece {
        case letter(Letter)
        case other(Character)
    }

    public static func romanize(_ text: String) -> String {
        guard containsGreek(text) else { return text }
        let pieces = split(text)
        var out = ""
        var i = 0
        while i < pieces.count {
            guard case .letter(let l) = pieces[i] else {
                if case .other(let c) = pieces[i] { out.append(c == "\u{037E}" ? "?" : c == "\u{0387}" ? ";" : c) }
                i += 1
                continue
            }
            let next = letter(pieces, i + 1)
            let previous = letter(pieces, i - 1)
            let wordInitial = previous == nil
            // υ 组成的双元音
            if "αεη".contains(l.base), let n = next, n.base == "υ", !l.accent, !n.diaeresis {
                let after = letter(pieces, i + 2)
                let voiceless = after.map { "θκξπστφχψς".contains($0.base) } ?? true
                let vowel = latinVowel(l.base == "α" ? "a" : l.base == "ε" ? "e" : "i", accent: n.accent, diaeresis: false)
                out += cased(vowel + (voiceless ? "f" : "v"), first: l, second: n)
                i += 2
                continue
            }
            if l.base == "ο", let n = next, n.base == "υ", !l.accent, !n.diaeresis {
                out += cased("o" + latinVowel("u", accent: n.accent, diaeresis: false), first: l, second: n)
                i += 2
                continue
            }
            if l.base == "γ", let n = next, "γξχ".contains(n.base) {
                let latin = n.base == "γ" ? "ng" : n.base == "ξ" ? "nx" : "nch"
                out += cased(latin, first: l, second: n)
                i += 2
                continue
            }
            if l.base == "μ", let n = next, n.base == "π" {
                let wordFinal = letter(pieces, i + 2) == nil
                out += cased(wordInitial || wordFinal ? "b" : "mp", first: l, second: n)
                i += 2
                continue
            }
            out += cased(single(l), first: l, second: next)
            i += 1
        }
        return out.precomposedStringWithCanonicalMapping
    }

    /// 相邻的希腊字母;中间隔着非字母(空格、标点)就算词界,返回 nil。
    private static func letter(_ pieces: [Piece], _ i: Int) -> Letter? {
        guard i >= 0, i < pieces.count, case .letter(let l) = pieces[i] else { return nil }
        return l
    }

    private static func single(_ l: Letter) -> String {
        switch l.base {
        case "α": return latinVowel("a", accent: l.accent, diaeresis: l.diaeresis)
        case "ε": return latinVowel("e", accent: l.accent, diaeresis: l.diaeresis)
        case "η", "ι": return latinVowel("i", accent: l.accent, diaeresis: l.diaeresis)
        case "ο", "ω": return latinVowel("o", accent: l.accent, diaeresis: l.diaeresis)
        case "υ": return latinVowel("y", accent: l.accent, diaeresis: l.diaeresis)
        default: return consonants[l.base] ?? String(l.base)
        }
    }

    private static let consonants: [Character: String] = [
        "β": "v", "γ": "g", "δ": "d", "ζ": "z", "θ": "th", "κ": "k", "λ": "l", "μ": "m", "ν": "n",
        "ξ": "x", "π": "p", "ρ": "r", "σ": "s", "ς": "s", "τ": "t", "φ": "f", "χ": "ch", "ψ": "ps",
    ]

    private static func latinVowel(_ v: String, accent: Bool, diaeresis: Bool) -> String {
        v + (diaeresis ? "\u{0308}" : "") + (accent ? "\u{0301}" : "")
    }

    /// 大写字母转成多个拉丁字母时,后面跟着小写就只大写第一个(Θ → Th),两个都大写就全大写。
    private static func cased(_ latin: String, first: Letter, second: Letter?) -> String {
        guard first.upper else { return latin }
        if second?.upper == true || latin.unicodeScalars.filter({ $0.properties.isAlphabetic }).count == 1 {
            return latin.uppercased()
        }
        return latin.prefix(1).uppercased() + latin.dropFirst()
    }

    /// 拆成「不带符号的小写字母 + 重音 / 分音符」。多调符号:送气符、iota 下标不写,扬抑符、钝音符当重音。
    private static func split(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        for ch in text {
            let scalars = Array(String(ch).decomposedStringWithCanonicalMapping.unicodeScalars)
            guard let first = scalars.first, isGreek(first), first.properties.isAlphabetic else {
                pieces.append(.other(ch))
                continue
            }
            let marks = Set(scalars.dropFirst().map(\.value))
            let base = Character(String(first).lowercased())
            pieces.append(.letter(Letter(
                base: base == "ϐ" ? "β" : base == "ϑ" ? "θ" : base == "ϕ" ? "φ" : base,
                upper: first.properties.isUppercase,
                accent: !marks.isDisjoint(with: [0x0301, 0x0300, 0x0342]),
                diaeresis: marks.contains(0x0308))))
        }
        return pieces
    }
}
