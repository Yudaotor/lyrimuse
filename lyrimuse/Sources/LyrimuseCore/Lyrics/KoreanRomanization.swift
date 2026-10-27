import Foundation

/// 韩文按读音的罗马字:照韩国《国语的罗马字标记法》,连读、鼻音化、流音化、腭化、送气这些音变按变化后的音写,
/// 紧音不写(있는 → inneun、같이 → gachi、멀리 → meolli)。
///
/// 规则移植自 koroman 1.0.16(MIT,Copyright (c) 2025 Donghe Youn,https://github.com/gerosyab/koroman
/// 的 js/src/koroman.core.js,`romanize` 默认选项那条路),顺序与写法照搬:补 ㄴ(「잎」)→ 音节拆成字母 →
/// 按顺序整串替换读音规则 → 字母换成拉丁字母。许可证全文见 THIRD_PARTY_LICENSES。
///
/// 跟原版不同的几处:
///  - 没有原版「연음」段开头那两条「ㄱ / ㄹ 收音 + ㅇ + ㅑㅒㅕㅖㅛㅠ → 补 ㄴ」:它分不出复合词和词尾变化,
///    필요해、움직여、죽여、말야 都会多出一个 ㄴ。代价是 열여섯、알약 这类真该补的也不补。
///  - 不改大小写:原版默认整串转小写,这里只换谚文,其余字符原样(歌词里的英文要保留大小写)。
///  - 补了标准发音法里几条:ㅅ ㅆ ㅊ ㅌ 收音 + ㅎ → ㅌ(못해 → motae);ㄺ + ㄱ 念 ㄹ(붉게 → bulge),
///    ㄺ + ㅎ 合成送气音(밝혀 → balkyeo);收音碰上实词「없」先变代表音再连读(끝없이 → kkeudeopsi);
///    ㅀ ㄾ + ㄴ 流音化(잃는 → illeun)。ㄴ + ㄹ 一律念 ㄹㄹ(난로 → nallo),念 ㄴㄴ 的只认 `nieunNieunWords`
///    里那几个词(原版按「后面接 ㅗ」判,난로、본론 会念错)。见 10 章决策 59。
///
/// 只换组合好的谚文音节(U+AC00–U+D7A3)和拆开的现代谚文字母(初声 U+1100–U+1112、中声 U+1161–U+1175、
/// 终声 U+11A8–U+11C2);古谚文字母、兼容字母(ㅋㅋ)和别的文字原样留给调用方。规则有先后,前一条的输出是
/// 后一条的输入,不能调换顺序,也不能改成逐条单独匹配原文。
/// 见 10 章决策 33。
public enum KoreanRomanization {
    public static func romanize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { isSyllable($0) || isJamo($0) }) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in pronounced(text).unicodeScalars {
            if let latin = latinByJamo[scalar] {
                out.append(contentsOf: latin.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// 一串连写的谚文音节(中间不夹别的字符)按音节给读音,音变跟 `romanize` 一样跨音节算:算完每个音节仍恰好留一个
    /// 中声,收音归前一个音节、初声归后一个(같이 → ga / chi),ㄹㄹ 的「ll」一边一个,送气音前的连字符不要。规则里没挪的
    /// 收音碰上后一个音节开头不发音的 ㅇ 时也归后一个(음악이 → eu / ma / gi),ㅇ 收音(ng)除外。不是纯谚文音节、或切出来的
    /// 段数跟音节数对不上时返回 nil。
    public static func syllableReadings(_ syllables: String) -> [String]? {
        let count = syllables.unicodeScalars.count
        guard count > 0, syllables.unicodeScalars.allSatisfy(isSyllable) else { return nil }
        let scalars = Array(pronounced(syllables).unicodeScalars)
        var pieces: [String] = []
        var current = ""
        var hasMedial = false
        var trailingFinal: Unicode.Scalar?
        func startPiece() {
            pieces.append(current)
            current = ""
            hasMedial = false
        }
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            switch s.value {
            case 0x1100...0x1112:
                var carried = ""
                if s.value == 0x110B, let final = trailingFinal, final.value != 0x11BC,
                   let latin = latinByJamo[final], current.hasSuffix(latin) {
                    current.removeLast(latin.count)
                    carried = latin
                }
                if hasMedial { startPiece() }
                current += carried + (latinByJamo[s] ?? "")
            case 0x1161...0x1175:
                if hasMedial { startPiece() }
                current += latinByJamo[s] ?? ""
                hasMedial = true
            case 0x11A8...0x11C2:
                current += latinByJamo[s] ?? ""
            case 0x6C where i + 1 < scalars.count && scalars[i + 1].value == 0x6C:
                current += "l"
                startPiece()
                current = "l"
                i += 1
            case 0x2D:
                break
            default:
                return nil
            }
            trailingFinal = (0x11A8...0x11C2).contains(s.value) ? s : nil
            i += 1
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.count == count && !pieces.contains(where: \.isEmpty) ? pieces : nil
    }

    /// 补 ㄴ、拆成字母、按顺序套完读音规则之后的字母串(还没换成拉丁字母)。
    private static func pronounced(_ text: String) -> String {
        var jamo = decomposed(insertingNieun(nieunNieunApplied(text)))
        for rule in rules {
            jamo = rule.regex.stringByReplacingMatches(
                in: jamo, range: NSRange(location: 0, length: (jamo as NSString).length),
                withTemplate: rule.template)
        }
        return jamo
    }

    private static let syllableBase: UInt32 = 0xAC00
    private static let leaf = Unicode.Scalar(0xC78E)!  // 잎

    private static func isSyllable(_ s: Unicode.Scalar) -> Bool { (0xAC00...0xD7A3).contains(s.value) }
    private static func isJamo(_ s: Unicode.Scalar) -> Bool { (0x1100...0x11FF).contains(s.value) }

    /// 音节的初声 / 中声 / 终声序号(终声 0 = 没有收音)。
    private static func parts(_ s: Unicode.Scalar) -> (initial: UInt32, medial: UInt32, final: UInt32) {
        let n = s.value - syllableBase
        return (n / (21 * 28), (n % (21 * 28)) / 28, n % 28)
    }

    /// 原版 applyNInsertionTriggers:一串连续的谚文音节以「잎」结尾、前一个音节有收音时,「잎」换成「닙」
    /// (꽃잎 → 꼰닙)。
    private static func insertingNieun(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        var start = 0
        while start < scalars.count {
            guard isSyllable(scalars[start]) else {
                start += 1
                continue
            }
            var end = start
            while end < scalars.count, isSyllable(scalars[end]) { end += 1 }
            if end - start >= 2, scalars[end - 1] == leaf, parts(scalars[end - 2]).final != 0 {
                let p = parts(leaf)
                scalars[end - 1] = Unicode.Scalar(syllableBase + (2 * 21 + p.medial) * 28 + p.final)!
            }
            start = end
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// ㄴ + ㄹ 念 ㄴㄴ 的词(标准发音法第 20 项「다만」所列,加上路名 신문로):其余的 ㄴ + ㄹ 一律流音化念 ㄹㄹ。
    /// 值是把那个 ㄹ 换成 ㄴ 的写法,只换这一处,音节数不变(`syllableReadings` 靠音节数对位)。
    private static let nieunNieunWords: [(String, String)] = [
        ("의견란", "의견난"), ("임진란", "임진난"), ("생산량", "생산냥"), ("결단력", "결단녁"), ("공권력", "공권녁"),
        ("동원령", "동원녕"), ("상견례", "상견녜"), ("횡단로", "횡단노"), ("이원론", "이원논"), ("입원료", "입원뇨"),
        ("구근류", "구근뉴"), ("신문로", "신문노"),
    ]

    private static func nieunNieunApplied(_ text: String) -> String {
        guard text.contains(where: { $0 == "란" || $0 == "량" || $0 == "력" || $0 == "령" || $0 == "례" || $0 == "로"
                || $0 == "론" || $0 == "료" || $0 == "류" }) else { return text }
        var out = text
        for (word, spoken) in nieunNieunWords where out.contains(word) {
            out = out.replacingOccurrences(of: word, with: spoken)
        }
        return out
    }

    /// 原版 splitHangulToJamos:音节拆成初声(U+1100…)、中声(U+1161…)、终声(U+11A8…),别的字符原样。
    private static func decomposed(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard isSyllable(scalar) else {
                out.append(scalar)
                continue
            }
            let p = parts(scalar)
            out.append(Unicode.Scalar(0x1100 + p.initial)!)
            out.append(Unicode.Scalar(0x1161 + p.medial)!)
            if p.final != 0 { out.append(Unicode.Scalar(0x11A7 + p.final)!) }
        }
        return String(out)
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static func rule(_ pattern: String, _ template: String) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern), template: template)
    }

    /// 原版 applyPronunciationRules,顺序照搬(原版第 4、5 条不收,见类型注释)。
    private static let rules: [Rule] = [
        // 不用的终声 U+11A7 去掉。
        rule(#"ᆧ"#, ""),
        // 收音碰上实词「없」:先变代表音再连读(끝없이 → 끄덥씨),不是直接把收音挪过去。
        rule(#"[ᆺᆻᆽᆾᇀ](?=없)"#, "\u{11AE}"),
        rule(#"[ᆩᆿ](?=없)"#, "\u{11A8}"),
        rule(#"ᇁ(?=없)"#, "\u{11B8}"),
        // 鼻音化:收音碰上 ㄴ / ㅁ。
        rule(#"[ᆸᇁᆹᆲᆵ](?=[ᄂᄆ])"#, "\u{11B7}"),
        rule(#"[ᆮᇀᆽᆾᆺᆻᇂ](?=[ᄂᄆ])"#, "\u{11AB}"),
        rule(#"[ᆨᆩᆿᆪᆰ](?=[ᄂᄆ])"#, "\u{11BC}"),
        // ㄹ 的鼻音化与流音化。
        rule(#"[ᆨᆼ]ᄅ"#, "\u{11BC}\u{1102}"),
        rule(#"[ᆯᆶᆴ]ᄂ|ᆫᄅ"#, "\u{11AF}\u{1105}"),
        rule(#"[ᆷᆸ]ᄅ"#, "\u{11B7}\u{1102}"),
        rule(#"ᆰᄅ"#, "\u{11A8}\u{1105}"),
        // 收音与同部位送气音之间加连字符。
        rule(#"ᆨᄏ"#, "\u{11A8}-\u{110F}"),
        rule(#"ᆸᄑ"#, "\u{11B8}-\u{1111}"),
        rule(#"ᆮᄐ"#, "\u{11AE}-\u{1110}"),
        // 双收音碰上元音:后一个辅音挪到下一个音节开头。
        rule(#"ᆪᄋ"#, "\u{11A8}\u{1109}"),
        rule(#"ᆬᄋ"#, "\u{11AB}\u{110C}"),
        rule(#"ᆭᄋ"#, "\u{11AB}\u{110B}"),
        rule(#"ᆰᄋ"#, "\u{11AF}\u{1100}"),
        rule(#"ᆱᄋ"#, "\u{11AF}\u{1106}"),
        rule(#"ᆲᄋ"#, "\u{11AF}\u{1107}"),
        rule(#"ᆳᄋ"#, "\u{11AF}\u{1109}"),
        rule(#"ᆴᄋ"#, "\u{11AF}\u{1110}"),
        rule(#"ᆵᄋ"#, "\u{11AF}\u{1111}"),
        rule(#"ᆶᄋ"#, "\u{11AF}\u{110B}"),
        rule(#"ᆹᄋ"#, "\u{11B8}\u{1109}"),
        // ㄺ 碰上 ㅎ:ㄱ 跟 ㅎ 合成 ㅋ,ㄹ 留下(下面拆双收音时 ㄺ 拆成「ㄱ 在前」,送气那条接不上)。
        rule(#"ᆰᄒ"#, "\u{11AF}\u{110F}"),
        // ㄺ 碰上 ㄱ 念 ㄹ(붉게、읽고)。
        rule(#"ᆰ(?=ᄀ)"#, "\u{11AF}"),
        // 「밟」在辅音前念 ㅂ。
        rule(#"밟(?=[ᄀ-ᄊᄌ-ᄒ])"#, "\u{1107}\u{1161}\u{11B8}"),
        // 双收音拆开,要念的那个放前面,最后一条只留前一个。
        rule(#"ᆪ"#, "\u{11A8}\u{11BA}"),
        rule(#"ᆬ"#, "\u{11AB}\u{11BD}"),
        rule(#"ᆭ"#, "\u{11AB}\u{11C2}"),
        rule(#"ᆰ"#, "\u{11A8}\u{11AF}"),
        rule(#"ᆱ"#, "\u{11B7}\u{11AF}"),
        rule(#"ᆲ"#, "\u{11AF}\u{11B8}"),
        rule(#"ᆳ"#, "\u{11AF}\u{11BA}"),
        rule(#"ᆴ"#, "\u{11AF}\u{11C0}"),
        rule(#"ᆵ"#, "\u{11C1}\u{11AF}"),
        rule(#"ᆶ"#, "\u{11AF}\u{11C2}"),
        rule(#"ᆹ"#, "\u{11B8}\u{11BA}"),
        // 腭化:ㄷ / ㅌ 收音 + 이 → 지 / 치,ㄷ + 히 → 치。
        rule(#"ᆮ이"#, "\u{110C}\u{1175}"),
        rule(#"ᇀ이"#, "\u{110E}\u{1175}"),
        rule(#"ᆮ히"#, "\u{110E}\u{1175}"),
        // 连读:收音挪到后面以元音开头的音节。
        rule(#"ᆨᄋ"#, "\u{1100}"),
        rule(#"ᆩᄋ"#, "\u{1101}"),
        rule(#"ᆮᄋ"#, "\u{1103}"),
        rule(#"ᆯᄋ"#, "\u{1105}"),
        rule(#"ᆸᄋ"#, "\u{1107}"),
        rule(#"ᆺᄋ"#, "\u{1109}"),
        rule(#"ᆻᄋ"#, "\u{110A}"),
        rule(#"ᆽᄋ"#, "\u{110C}"),
        rule(#"ᆾᄋ"#, "\u{110E}"),
        rule(#"ᇂᄋ"#, ""),
        // 送气:ㅎ 与 ㄱ / ㄷ / ㅈ / ㅂ 合成送气音。
        rule(#"ᇂᄀ|ᆨᄒ"#, "\u{110F}"),
        rule(#"ᇂᄃ|ᆮᄒ"#, "\u{1110}"),
        rule(#"ᇂᄌ|ᆽᄒ"#, "\u{110E}"),
        rule(#"[ᆺᆻᆾᇀ]ᄒ"#, "\u{1110}"),
        rule(#"ᇂᄇ"#, "\u{1107}"),
        rule(#"ᆸᄒ"#, "\u{1111}"),
        // ㄹㄹ 写 ll;词中落单的 ㅎ 收音去掉;剩下的连续两个收音只留前一个。
        rule(#"ᆯᄅ"#, "ll"),
        rule(#"ᇂ(?!\s|$)"#, ""),
        rule(#"([ᆨ-ᇂ])([ᆨ-ᇂ])"#, "$1"),
    ]

    /// 原版 ROMAN_MAP_STD:初声、中声按位置固定,终声按代表音(ㄷ / ㅈ / ㅊ / ㅌ / ㅎ 都是 t)。
    private static let latinByJamo: [Unicode.Scalar: String] = {
        let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
        let medials = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we",
                       "wi", "yu", "eu", "ui", "i"]
        let finals = ["k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "p", "t", "t", "p", "l", "m", "p", "p", "t",
                      "t", "ng", "t", "t", "k", "t", "p", "t"]
        var map: [Unicode.Scalar: String] = [:]
        for (i, latin) in initials.enumerated() { map[Unicode.Scalar(0x1100 + UInt32(i))!] = latin }
        for (i, latin) in medials.enumerated() { map[Unicode.Scalar(0x1161 + UInt32(i))!] = latin }
        for (i, latin) in finals.enumerated() { map[Unicode.Scalar(0x11A8 + UInt32(i))!] = latin }
        return map
    }()
}
