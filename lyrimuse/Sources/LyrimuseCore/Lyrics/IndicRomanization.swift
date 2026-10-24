import Foundation

/// 印度系文字读音。天城文、孟加拉文、古木基文、古吉拉特文、泰米尔文、泰卢固文、卡纳达文、马拉雅拉姆文按 ISO 15919:2001;联合国 1977 年给印地语、旁遮普语、泰米尔语推荐过
/// 一套体系,UNGEGN 报告(4.0 版)写明印度、斯里兰卡和国际制图都没有在用。ISO 15919 留给使用方选的写法:
///   - 长短 e / o 一律按标准默认的统一写法:ए ओ 写 ē ō(天城文、孟加拉文、古木基文、古吉拉特文没有短 e / o,也照写长音符)。
///   - 随韵(anusvāra)一律写 ṁ(标准的简化选项),古木基文的 tippi、bindi 同样写 ṁ。
///   - 鼻化符(candrabindu)写成前一个元音上的波浪号(非梵语文本的写法)。
///   - 辅音不带元音符号、也没有消音符时写出固有元音 a(ISO 15919 是逐字转写,不删 schwa)。
/// 僧伽罗文按斯里兰卡测绘局的国家体系(2018 年内阁批准,之后修订;UNGEGN 报告 5.0 版收录的现行修订版):
/// 在 ISO 15919 上改了几个字母(随韵 ං ṅ、ච ch、ෂ sh、ඣ q、ඨ ṯ、ඞ ṁ、ඹ ḅ、ඓ ĩ、ඍ ṛ)。报告里 ඞ 的辅音表写 ṁa、
/// 加消音符的特殊形写 ṅ,前后不一,按辅音表。
/// 点(nukta)跟在没有带点写法的字母后面时不出字。
/// 马拉雅拉姆文的独立辅音(chillu,ൻ ർ ൽ 这些)不带固有元音;词尾的消音符(saṁvr̥tōkāram,കണ്ണ്)写 ŭ,
/// 老写法 ു് 同样写 ŭ;后面跟着零宽连接符的是老式 chillu,照消音符转。
/// 先做 NFC:泰米尔文、僧伽罗文、卡纳达文、马拉雅拉姆文的两段式元音(ோ = ெ + ா 这类)有的歌词按两个字符存,不合成就会读成两个元音。
/// 数字换成阿拉伯数字,单竖线 । 写「.」、双竖线 ॥ 写「..」。见 10 章决策 51、53。
public enum IndicScript: String, Sendable, CaseIterable {
    case devanagari, bengali, gurmukhi, gujarati, tamil, telugu, kannada, malayalam, sinhala

    var range: ClosedRange<UInt32> {
        switch self {
        case .devanagari: return 0x0900...0x097F
        case .bengali: return 0x0980...0x09FF
        case .gurmukhi: return 0x0A00...0x0A7F
        case .gujarati: return 0x0A80...0x0AFF
        case .tamil: return 0x0B80...0x0BFF
        case .telugu: return 0x0C00...0x0C7F
        case .kannada: return 0x0C80...0x0CFF
        case .malayalam: return 0x0D00...0x0D7F
        case .sinhala: return 0x0D80...0x0DFF
        }
    }
}

public enum IndicRomanization {
    public static func script(of text: String) -> IndicScript? {
        var counts: [IndicScript: Int] = [:]
        for s in text.unicodeScalars {
            for script in IndicScript.allCases where script.range.contains(s.value) { counts[script, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// 一行里这几种文字的片段按 ISO 15919 换成拉丁字母,其余字符原样保留。
    public static func romanize(_ text: String) -> String {
        let scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        var out: [Unicode.Scalar] = []
        var i = 0
        // 刚写出、还能被消音符 / 元音符号换掉的固有元音 a 在 out 里的下标。
        var pendingInherent: Int?
        var gemination = false
        while i < scalars.count {
            let s = scalars[i]
            guard let script = IndicScript.allCases.first(where: { $0.range.contains(s.value) }),
                let table = tables[script]
            else {
                if s.value == 0x200D || s.value == 0x200C { i += 1; continue }  // 零宽连接符(僧伽罗文的连写)
                out.append(s)
                pendingInherent = nil
                i += 1
                continue
            }
            let v = s.value
            if var consonant = table.consonants[v] {
                // 点(nukta)改字母:क़ q、ज़ z、ड़ ṛ……
                if i + 1 < scalars.count, scalars[i + 1].value == table.nukta, let dotted = table.nuktaForms[v] {
                    consonant = dotted
                    i += 1
                }
                if gemination, let first = consonant.unicodeScalars.first {
                    out.append(first)
                    gemination = false
                }
                out.append(contentsOf: consonant.unicodeScalars)
                pendingInherent = out.count
                out.append("a")
                i += 1
                continue
            }
            if v == table.virama {
                let wordFinal = i + 1 == scalars.count || !script.range.contains(scalars[i + 1].value)
                    && scalars[i + 1].value != 0x200D
                if script == .malayalam, wordFinal {
                    if let at = pendingInherent {
                        out[at] = "ŭ"
                    } else if out.last == "u" {
                        out[out.count - 1] = "ŭ"
                    }
                } else if let at = pendingInherent {
                    out.remove(at: at)
                }
                pendingInherent = nil
                i += 1
                continue
            }
            if let sign = table.vowelSigns[v] {
                if let at = pendingInherent {
                    out.remove(at: at)
                    out.append(contentsOf: sign.unicodeScalars)
                } else {
                    out.append(contentsOf: sign.unicodeScalars)
                }
                pendingInherent = nil
                i += 1
                continue
            }
            if v == table.candrabindu {
                out.append("\u{0303}")
                pendingInherent = nil
                i += 1
                continue
            }
            if v == table.addak {
                gemination = true
                i += 1
                continue
            }
            pendingInherent = nil
            if let carrier = table.vowelCarriers[v] {
                // 古木基文的 ੳ ੲ 自己不发音,读音由后面的元音符号定(ੳ + ◌ੁ = u);后面没有符号时按 ਅ 一类读。
                if i + 1 < scalars.count, let sign = table.vowelSigns[scalars[i + 1].value] {
                    out.append(contentsOf: sign.unicodeScalars)
                    i += 2
                } else {
                    out.append(contentsOf: carrier.unicodeScalars)
                    i += 1
                }
                continue
            }
            if let other = table.others[v] {
                out.append(contentsOf: other.unicodeScalars)
            } else if let digit = digitValue(v, script: script) {
                out.append(contentsOf: String(digit).unicodeScalars)
            } else {
                out.append(s)
            }
            i += 1
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: out)
        return String(text).precomposedStringWithCanonicalMapping
    }

    private static func digitValue(_ v: UInt32, script: IndicScript) -> Int? {
        let zero: UInt32
        switch script {
        case .devanagari: zero = 0x0966
        case .bengali: zero = 0x09E6
        case .gurmukhi: zero = 0x0A66
        case .gujarati: zero = 0x0AE6
        case .tamil: zero = 0x0BE6
        case .telugu: zero = 0x0C66
        case .kannada: zero = 0x0CE6
        case .malayalam: zero = 0x0D66
        case .sinhala: zero = 0x0DE6
        }
        return (zero...zero + 9).contains(v) ? Int(v - zero) : nil
    }

    struct Table {
        var consonants: [UInt32: String] = [:]
        var vowelSigns: [UInt32: String] = [:]
        var others: [UInt32: String] = [:]  // 独立元音、随韵、止韵、标点
        var nuktaForms: [UInt32: String] = [:]
        var vowelCarriers: [UInt32: String] = [:]
        var virama: UInt32 = 0
        var nukta: UInt32 = 0
        var candrabindu: UInt32 = 0
        var addak: UInt32 = 0
    }

    private static func map(_ pairs: [(String, String)]) -> [UInt32: String] {
        var t: [UInt32: String] = [:]
        for (k, v) in pairs { t[k.unicodeScalars.first!.value] = v }
        return t
    }

    static let tables: [IndicScript: Table] = [
        .devanagari: devanagari, .bengali: bengali, .gurmukhi: gurmukhi, .gujarati: gujarati, .tamil: tamil,
        .telugu: telugu, .kannada: kannada, .malayalam: malayalam, .sinhala: sinhala,
    ]

    private static let devanagari: Table = {
        var t = Table()
        t.consonants = map([
            ("क", "k"), ("ख", "kh"), ("ग", "g"), ("घ", "gh"), ("ङ", "ṅ"), ("च", "c"), ("छ", "ch"), ("ज", "j"),
            ("झ", "jh"), ("ञ", "ñ"), ("ट", "ṭ"), ("ठ", "ṭh"), ("ड", "ḍ"), ("ढ", "ḍh"), ("ण", "ṇ"), ("त", "t"),
            ("थ", "th"), ("द", "d"), ("ध", "dh"), ("न", "n"), ("प", "p"), ("फ", "ph"), ("ब", "b"),
            ("भ", "bh"), ("म", "m"), ("य", "y"), ("र", "r"), ("ल", "l"), ("ळ", "ḷ"),
            ("व", "v"), ("श", "ś"), ("ष", "ṣ"), ("स", "s"), ("ह", "h"),
            // 带点字母的预组形式(NFC 不合成其中 U+0958–U+095F,歌词里两种写法都有)。
            ("\u{0929}", "ṉ"), ("\u{0931}", "ṟ"), ("\u{0934}", "ḻ"), ("\u{0958}", "q"), ("\u{0959}", "k͟h"),
            ("\u{095A}", "ġ"), ("\u{095B}", "z"), ("\u{095C}", "ṛ"), ("\u{095D}", "ṛh"), ("\u{095E}", "f"),
            ("\u{095F}", "ẏ"),
        ])
        t.nuktaForms = map([
            ("क", "q"), ("ख", "k͟h"), ("ग", "ġ"), ("ज", "z"), ("ड", "ṛ"), ("ढ", "ṛh"), ("फ", "f"), ("य", "ẏ"),
            ("न", "ṉ"), ("र", "ṟ"), ("ळ", "ḻ"),
        ])
        t.vowelSigns = map([
            ("\u{093E}", "ā"), ("\u{093F}", "i"), ("\u{0940}", "ī"), ("\u{0941}", "u"), ("\u{0942}", "ū"),
            ("\u{0943}", "r̥"), ("\u{0944}", "r̥̄"), ("\u{0962}", "l̥"), ("\u{0963}", "l̥̄"), ("\u{0945}", "ê"),
            ("\u{0946}", "e"), ("\u{0947}", "ē"), ("\u{0948}", "ai"), ("\u{0949}", "ô"), ("\u{094A}", "o"),
            ("\u{094B}", "ō"), ("\u{094C}", "au"),
        ])
        t.others = map([
            ("अ", "a"), ("आ", "ā"), ("इ", "i"), ("ई", "ī"), ("उ", "u"), ("ऊ", "ū"), ("ऋ", "r̥"), ("ॠ", "r̥̄"),
            ("ऌ", "l̥"), ("ॡ", "l̥̄"), ("ऍ", "ê"), ("ऎ", "e"), ("ए", "ē"), ("ऐ", "ai"), ("ऑ", "ô"), ("ऒ", "o"),
            ("ओ", "ō"), ("औ", "au"), ("\u{0902}", "ṁ"), ("\u{0903}", "ḥ"), ("ऽ", "’"), ("ॐ", "om"),
            ("।", "."), ("॥", ".."), ("\u{093C}", ""),
        ])
        t.virama = 0x094D
        t.nukta = 0x093C
        t.candrabindu = 0x0901
        return t
    }()

    private static let gurmukhi: Table = {
        var t = Table()
        t.consonants = map([
            ("ਕ", "k"), ("ਖ", "kh"), ("ਗ", "g"), ("ਘ", "gh"), ("ਙ", "ṅ"), ("ਚ", "c"), ("ਛ", "ch"), ("ਜ", "j"),
            ("ਝ", "jh"), ("ਞ", "ñ"), ("ਟ", "ṭ"), ("ਠ", "ṭh"), ("ਡ", "ḍ"), ("ਢ", "ḍh"), ("ਣ", "ṇ"), ("ਤ", "t"),
            ("ਥ", "th"), ("ਦ", "d"), ("ਧ", "dh"), ("ਨ", "n"), ("ਪ", "p"), ("ਫ", "ph"), ("ਬ", "b"), ("ਭ", "bh"),
            ("ਮ", "m"), ("ਯ", "y"), ("ਰ", "r"), ("ਲ", "l"), ("ਵ", "v"), ("ਸ", "s"), ("ਹ", "h"), ("ੜ", "ṛ"),
            ("\u{0A33}", "ḷ"), ("\u{0A36}", "ś"), ("\u{0A59}", "k͟h"), ("\u{0A5A}", "ġ"), ("\u{0A5B}", "z"),
            ("\u{0A5E}", "f"),
        ])
        t.nuktaForms = map([
            ("ਸ", "ś"), ("ਲ", "ḷ"), ("ਖ", "k͟h"), ("ਗ", "ġ"), ("ਜ", "z"), ("ਫ", "f"),
        ])
        t.vowelSigns = map([
            ("\u{0A3E}", "ā"), ("\u{0A3F}", "i"), ("\u{0A40}", "ī"), ("\u{0A41}", "u"), ("\u{0A42}", "ū"),
            ("\u{0A47}", "ē"), ("\u{0A48}", "ai"), ("\u{0A4B}", "ō"), ("\u{0A4C}", "au"),
        ])
        t.vowelCarriers = map([("ੳ", "u"), ("ੲ", "i")])
        t.others = map([
            ("ਅ", "a"), ("ਆ", "ā"), ("ਇ", "i"), ("ਈ", "ī"), ("ਉ", "u"), ("ਊ", "ū"), ("ਏ", "ē"), ("ਐ", "ai"),
            ("ਓ", "ō"), ("ਔ", "au"), ("\u{0A02}", "ṁ"), ("\u{0A70}", "ṁ"), ("\u{0A03}", "ḥ"), ("\u{0A75}", "y"),
            ("\u{0A51}", ""), ("\u{0A3C}", ""),
        ])
        t.virama = 0x0A4D
        t.nukta = 0x0A3C
        t.candrabindu = 0x0A01
        t.addak = 0x0A71
        return t
    }()

    private static let tamil: Table = {
        var t = Table()
        t.consonants = map([
            ("க", "k"), ("ங", "ṅ"), ("ச", "c"), ("ஞ", "ñ"), ("ட", "ṭ"), ("ண", "ṇ"), ("த", "t"), ("ந", "n"),
            ("ப", "p"), ("ம", "m"), ("ய", "y"), ("ர", "r"), ("ல", "l"), ("வ", "v"), ("ழ", "ḻ"), ("ள", "ḷ"),
            ("ற", "ṟ"), ("ன", "ṉ"), ("ஜ", "j"), ("ஶ", "ś"), ("ஷ", "ṣ"), ("ஸ", "s"), ("ஹ", "h"),
        ])
        t.vowelSigns = map([
            ("\u{0BBE}", "ā"), ("\u{0BBF}", "i"), ("\u{0BC0}", "ī"), ("\u{0BC1}", "u"), ("\u{0BC2}", "ū"),
            ("\u{0BC6}", "e"), ("\u{0BC7}", "ē"), ("\u{0BC8}", "ai"), ("\u{0BCA}", "o"), ("\u{0BCB}", "ō"),
            ("\u{0BCC}", "au"),
        ])
        t.others = map([
            ("அ", "a"), ("ஆ", "ā"), ("இ", "i"), ("ஈ", "ī"), ("உ", "u"), ("ஊ", "ū"), ("எ", "e"), ("ஏ", "ē"),
            ("ஐ", "ai"), ("ஒ", "o"), ("ஓ", "ō"), ("ஔ", "au"), ("\u{0B82}", "ṁ"), ("ஃ", "ḵ"), ("ௐ", "ōm"),
            ("\u{0BD7}", ""),
        ])
        t.virama = 0x0BCD
        return t
    }()

    private static let bengali: Table = {
        var t = Table()
        t.consonants = map([
            ("ক", "k"), ("খ", "kh"), ("গ", "g"), ("ঘ", "gh"), ("ঙ", "ṅ"), ("চ", "c"), ("ছ", "ch"), ("জ", "j"),
            ("ঝ", "jh"), ("ঞ", "ñ"), ("ট", "ṭ"), ("ঠ", "ṭh"), ("ড", "ḍ"), ("ঢ", "ḍh"), ("ণ", "ṇ"), ("ত", "t"),
            ("থ", "th"), ("দ", "d"), ("ধ", "dh"), ("ন", "n"), ("প", "p"), ("ফ", "ph"), ("ব", "b"), ("ভ", "bh"),
            ("ম", "m"), ("য", "y"), ("র", "r"), ("ল", "l"), ("শ", "ś"), ("ষ", "ṣ"), ("স", "s"), ("হ", "h"),
            // 阿萨姆语的 ৰ ৱ;带点字母的预组形式(NFC 不合成)。
            ("\u{09F0}", "r"), ("\u{09F1}", "v"), ("\u{09DC}", "ṛ"), ("\u{09DD}", "ṛh"), ("\u{09DF}", "ẏ"),
        ])
        t.nuktaForms = map([("ড", "ṛ"), ("ঢ", "ṛh"), ("য", "ẏ")])
        t.vowelSigns = map([
            ("\u{09BE}", "ā"), ("\u{09BF}", "i"), ("\u{09C0}", "ī"), ("\u{09C1}", "u"), ("\u{09C2}", "ū"),
            ("\u{09C3}", "r̥"), ("\u{09C4}", "r̥̄"), ("\u{09E2}", "l̥"), ("\u{09E3}", "l̥̄"), ("\u{09C7}", "ē"),
            ("\u{09C8}", "ai"), ("\u{09CB}", "ō"), ("\u{09CC}", "au"),
        ])
        t.others = map([
            ("অ", "a"), ("আ", "ā"), ("ই", "i"), ("ঈ", "ī"), ("উ", "u"), ("ঊ", "ū"), ("ঋ", "r̥"), ("ৠ", "r̥̄"),
            ("ঌ", "l̥"), ("ৡ", "l̥̄"), ("এ", "ē"), ("ঐ", "ai"), ("ও", "ō"), ("ঔ", "au"), ("\u{0982}", "ṁ"),
            ("\u{0983}", "ḥ"), ("ঽ", "’"), ("\u{09CE}", "t"), ("\u{09BC}", ""), ("\u{09D7}", ""),
        ])
        t.virama = 0x09CD
        t.nukta = 0x09BC
        t.candrabindu = 0x0981
        return t
    }()

    private static let gujarati: Table = {
        var t = Table()
        t.consonants = map([
            ("ક", "k"), ("ખ", "kh"), ("ગ", "g"), ("ઘ", "gh"), ("ઙ", "ṅ"), ("ચ", "c"), ("છ", "ch"), ("જ", "j"),
            ("ઝ", "jh"), ("ઞ", "ñ"), ("ટ", "ṭ"), ("ઠ", "ṭh"), ("ડ", "ḍ"), ("ઢ", "ḍh"), ("ણ", "ṇ"), ("ત", "t"),
            ("થ", "th"), ("દ", "d"), ("ધ", "dh"), ("ન", "n"), ("પ", "p"), ("ફ", "ph"), ("બ", "b"), ("ભ", "bh"),
            ("મ", "m"), ("ય", "y"), ("ર", "r"), ("લ", "l"), ("ળ", "ḷ"), ("વ", "v"), ("શ", "ś"), ("ષ", "ṣ"),
            ("સ", "s"), ("હ", "h"),
        ])
        t.nuktaForms = map([
            ("ક", "q"), ("ખ", "k͟h"), ("ગ", "ġ"), ("જ", "z"), ("ડ", "ṛ"), ("ઢ", "ṛh"), ("ફ", "f"),
        ])
        t.vowelSigns = map([
            ("\u{0ABE}", "ā"), ("\u{0ABF}", "i"), ("\u{0AC0}", "ī"), ("\u{0AC1}", "u"), ("\u{0AC2}", "ū"),
            ("\u{0AC3}", "r̥"), ("\u{0AC4}", "r̥̄"), ("\u{0AE2}", "l̥"), ("\u{0AE3}", "l̥̄"), ("\u{0AC5}", "ê"),
            ("\u{0AC7}", "ē"), ("\u{0AC8}", "ai"), ("\u{0AC9}", "ô"), ("\u{0ACB}", "ō"), ("\u{0ACC}", "au"),
        ])
        t.others = map([
            ("અ", "a"), ("આ", "ā"), ("ઇ", "i"), ("ઈ", "ī"), ("ઉ", "u"), ("ઊ", "ū"), ("ઋ", "r̥"), ("ૠ", "r̥̄"),
            ("ઌ", "l̥"), ("ૡ", "l̥̄"), ("ઍ", "ê"), ("એ", "ē"), ("ઐ", "ai"), ("ઑ", "ô"), ("ઓ", "ō"), ("ઔ", "au"),
            ("\u{0A82}", "ṁ"), ("\u{0A83}", "ḥ"), ("ઽ", "’"), ("ૐ", "om"), ("\u{0ABC}", ""),
        ])
        t.virama = 0x0ACD
        t.nukta = 0x0ABC
        t.candrabindu = 0x0A81
        return t
    }()

    private static let telugu: Table = {
        var t = Table()
        t.consonants = map([
            ("క", "k"), ("ఖ", "kh"), ("గ", "g"), ("ఘ", "gh"), ("ఙ", "ṅ"), ("చ", "c"), ("ఛ", "ch"), ("జ", "j"),
            ("ఝ", "jh"), ("ఞ", "ñ"), ("ట", "ṭ"), ("ఠ", "ṭh"), ("డ", "ḍ"), ("ఢ", "ḍh"), ("ణ", "ṇ"), ("త", "t"),
            ("థ", "th"), ("ద", "d"), ("ధ", "dh"), ("న", "n"), ("ప", "p"), ("ఫ", "ph"), ("బ", "b"), ("భ", "bh"),
            ("మ", "m"), ("య", "y"), ("ర", "r"), ("ఱ", "ṟ"), ("ల", "l"), ("ళ", "ḷ"), ("ఴ", "ḻ"), ("వ", "v"),
            ("శ", "ś"), ("ష", "ṣ"), ("స", "s"), ("హ", "h"),
        ])
        t.vowelSigns = map([
            ("\u{0C3E}", "ā"), ("\u{0C3F}", "i"), ("\u{0C40}", "ī"), ("\u{0C41}", "u"), ("\u{0C42}", "ū"),
            ("\u{0C43}", "r̥"), ("\u{0C44}", "r̥̄"), ("\u{0C62}", "l̥"), ("\u{0C63}", "l̥̄"), ("\u{0C46}", "e"),
            ("\u{0C47}", "ē"), ("\u{0C48}", "ai"), ("\u{0C4A}", "o"), ("\u{0C4B}", "ō"), ("\u{0C4C}", "au"),
        ])
        t.others = map([
            ("అ", "a"), ("ఆ", "ā"), ("ఇ", "i"), ("ఈ", "ī"), ("ఉ", "u"), ("ఊ", "ū"), ("ఋ", "r̥"), ("ౠ", "r̥̄"),
            ("ఌ", "l̥"), ("ౡ", "l̥̄"), ("ఎ", "e"), ("ఏ", "ē"), ("ఐ", "ai"), ("ఒ", "o"), ("ఓ", "ō"), ("ఔ", "au"),
            ("\u{0C02}", "ṁ"), ("\u{0C03}", "ḥ"), ("ఽ", "’"), ("\u{0C55}", ""), ("\u{0C56}", ""),
        ])
        t.virama = 0x0C4D
        t.candrabindu = 0x0C01
        return t
    }()

    private static let kannada: Table = {
        var t = Table()
        t.consonants = map([
            ("ಕ", "k"), ("ಖ", "kh"), ("ಗ", "g"), ("ಘ", "gh"), ("ಙ", "ṅ"), ("ಚ", "c"), ("ಛ", "ch"), ("ಜ", "j"),
            ("ಝ", "jh"), ("ಞ", "ñ"), ("ಟ", "ṭ"), ("ಠ", "ṭh"), ("ಡ", "ḍ"), ("ಢ", "ḍh"), ("ಣ", "ṇ"), ("ತ", "t"),
            ("ಥ", "th"), ("ದ", "d"), ("ಧ", "dh"), ("ನ", "n"), ("ಪ", "p"), ("ಫ", "ph"), ("ಬ", "b"), ("ಭ", "bh"),
            ("ಮ", "m"), ("ಯ", "y"), ("ರ", "r"), ("ಱ", "ṟ"), ("ಲ", "l"), ("ಳ", "ḷ"), ("ೞ", "ḻ"), ("ವ", "v"),
            ("ಶ", "ś"), ("ಷ", "ṣ"), ("ಸ", "s"), ("ಹ", "h"),
        ])
        t.nuktaForms = map([("ಜ", "z"), ("ಫ", "f")])
        t.vowelSigns = map([
            ("\u{0CBE}", "ā"), ("\u{0CBF}", "i"), ("\u{0CC0}", "ī"), ("\u{0CC1}", "u"), ("\u{0CC2}", "ū"),
            ("\u{0CC3}", "r̥"), ("\u{0CC4}", "r̥̄"), ("\u{0CE2}", "l̥"), ("\u{0CE3}", "l̥̄"), ("\u{0CC6}", "e"),
            ("\u{0CC7}", "ē"), ("\u{0CC8}", "ai"), ("\u{0CCA}", "o"), ("\u{0CCB}", "ō"), ("\u{0CCC}", "au"),
        ])
        t.others = map([
            ("ಅ", "a"), ("ಆ", "ā"), ("ಇ", "i"), ("ಈ", "ī"), ("ಉ", "u"), ("ಊ", "ū"), ("ಋ", "r̥"), ("ೠ", "r̥̄"),
            ("ಌ", "l̥"), ("ೡ", "l̥̄"), ("ಎ", "e"), ("ಏ", "ē"), ("ಐ", "ai"), ("ಒ", "o"), ("ಓ", "ō"), ("ಔ", "au"),
            ("\u{0C82}", "ṁ"), ("\u{0C83}", "ḥ"), ("ಽ", "’"), ("\u{0CBC}", ""), ("\u{0CD5}", ""), ("\u{0CD6}", ""),
        ])
        t.virama = 0x0CCD
        t.nukta = 0x0CBC
        t.candrabindu = 0x0C81
        return t
    }()

    private static let malayalam: Table = {
        var t = Table()
        t.consonants = map([
            ("ക", "k"), ("ഖ", "kh"), ("ഗ", "g"), ("ഘ", "gh"), ("ങ", "ṅ"), ("ച", "c"), ("ഛ", "ch"), ("ജ", "j"),
            ("ഝ", "jh"), ("ഞ", "ñ"), ("ട", "ṭ"), ("ഠ", "ṭh"), ("ഡ", "ḍ"), ("ഢ", "ḍh"), ("ണ", "ṇ"), ("ത", "t"),
            ("ഥ", "th"), ("ദ", "d"), ("ധ", "dh"), ("ന", "n"), ("പ", "p"), ("ഫ", "ph"), ("ബ", "b"), ("ഭ", "bh"),
            ("മ", "m"), ("യ", "y"), ("ര", "r"), ("റ", "ṟ"), ("ല", "l"), ("ള", "ḷ"), ("ഴ", "ḻ"), ("വ", "v"),
            ("ശ", "ś"), ("ഷ", "ṣ"), ("സ", "s"), ("ഹ", "h"),
        ])
        t.vowelSigns = map([
            ("\u{0D3E}", "ā"), ("\u{0D3F}", "i"), ("\u{0D40}", "ī"), ("\u{0D41}", "u"), ("\u{0D42}", "ū"),
            ("\u{0D43}", "r̥"), ("\u{0D44}", "r̥̄"), ("\u{0D62}", "l̥"), ("\u{0D63}", "l̥̄"), ("\u{0D46}", "e"),
            ("\u{0D47}", "ē"), ("\u{0D48}", "ai"), ("\u{0D4A}", "o"), ("\u{0D4B}", "ō"), ("\u{0D4C}", "au"),
            ("\u{0D57}", "au"),
        ])
        t.others = map([
            ("അ", "a"), ("ആ", "ā"), ("ഇ", "i"), ("ഈ", "ī"), ("ഉ", "u"), ("ഊ", "ū"), ("ഋ", "r̥"), ("ൠ", "r̥̄"),
            ("ഌ", "l̥"), ("ൡ", "l̥̄"), ("എ", "e"), ("ഏ", "ē"), ("ഐ", "ai"), ("ഒ", "o"), ("ഓ", "ō"), ("ഔ", "au"),
            ("\u{0D02}", "ṁ"), ("\u{0D03}", "ḥ"), ("ഽ", "’"),
            ("\u{0D7A}", "ṇ"), ("\u{0D7B}", "n"), ("\u{0D7C}", "r"), ("\u{0D7D}", "l"), ("\u{0D7E}", "ḷ"),
            ("\u{0D7F}", "k"), ("\u{0D4E}", "r"),
        ])
        t.virama = 0x0D4D
        t.candrabindu = 0x0D01
        return t
    }()

    private static let sinhala: Table = {
        var t = Table()
        t.consonants = map([
            ("ක", "k"), ("ඛ", "kh"), ("ග", "g"), ("ඝ", "gh"), ("ඞ", "ṁ"), ("ඟ", "n̆g"), ("ච", "ch"), ("ඡ", "chh"),
            ("ජ", "j"), ("ඣ", "q"), ("ඤ", "ñ"), ("ඥ", "gn"), ("ඦ", "n̆ǰ"), ("ට", "ṭ"), ("ඨ", "ṯ"), ("ඩ", "ḍ"),
            ("ඪ", "ḍh"), ("ණ", "ṇ"), ("ඬ", "n̆ḍ"), ("ත", "t"), ("ථ", "th"), ("ද", "d"), ("ධ", "dh"), ("න", "n"),
            ("ඳ", "n̆d"), ("ප", "p"), ("ඵ", "ph"), ("බ", "b"), ("භ", "bh"), ("ම", "m"), ("ඹ", "ḅ"), ("ය", "y"),
            ("ර", "r"), ("ල", "l"), ("ව", "v"), ("ශ", "ś"), ("ෂ", "sh"), ("ස", "s"), ("හ", "h"), ("ළ", "ḷ"),
            ("ෆ", "f"),
        ])
        t.vowelSigns = map([
            ("\u{0DCF}", "ā"), ("\u{0DD0}", "æ"), ("\u{0DD1}", "ǣ"), ("\u{0DD2}", "i"), ("\u{0DD3}", "ī"),
            ("\u{0DD4}", "u"), ("\u{0DD6}", "ū"), ("\u{0DD8}", "ṛ"), ("\u{0DF2}", "ṝ"), ("\u{0DDF}", "ḷ"),
            ("\u{0DF3}", "ḹ"), ("\u{0DD9}", "e"), ("\u{0DDA}", "ē"), ("\u{0DDB}", "ĩ"), ("\u{0DDC}", "o"),
            ("\u{0DDD}", "ō"), ("\u{0DDE}", "au"),
        ])
        t.others = map([
            ("අ", "a"), ("ආ", "ā"), ("ඇ", "æ"), ("ඈ", "ǣ"), ("ඉ", "i"), ("ඊ", "ī"), ("උ", "u"), ("ඌ", "ū"),
            ("ඍ", "ṛ"), ("ඎ", "ṝ"), ("ඏ", "ḷ"), ("ඐ", "ḹ"), ("එ", "e"), ("ඒ", "ē"), ("ඓ", "ĩ"), ("ඔ", "o"),
            ("ඕ", "ō"), ("ඖ", "au"), ("\u{0D82}", "ṅ"), ("\u{0D83}", "ḥ"), ("\u{0DF4}", "."),
        ])
        t.virama = 0x0DCA
        return t
    }()
}
