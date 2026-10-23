import Foundation
import NaturalLanguage

/// 用西里尔字母写的几种语言。各用各的罗马化体系,所以要先认出是哪一种(整首歌认一次)。
public enum CyrillicLanguage: String, Sendable, CaseIterable {
    case russian, ukrainian, bulgarian, belarusian, serbian, macedonian, kazakh
}

/// 西里尔字母读音:每种语言按它自己国家现行的官方体系写。前四种同时是联合国推荐体系,表逐条照 UNGEGN 罗马化工作组
/// 《联合国罗马化体系现状报告》各语言那一份:
///   - 俄语:1987 年 V/18 决议,GOST 1983(GOST 16876-71)。软音符、硬音符写修饰字母 ʹ ʺ(U+02B9、U+02BA,
///     算字母、不断词),别写成撇号标点 ′ ″。
///   - 乌克兰语:2012 年 X/9 决议,乌克兰政府 2010 年体系。
///   - 保加利亚语:2012 年 X/7 决议,2009 年《音译法》体系(含法里国名 България 固定写 Bulgaria 的例外)。
///   - 白俄罗斯语:2012 年 X/6 决议,2007 年国家体系。
///   - 塞尔维亚语:1977 年 III/11 决议,即塞尔维亚语的官方拉丁字母。
///   - 马其顿语:北马其顿 2008 年起护照、身份证这些官方证件用的无附加符号写法(ѓ gj、ќ kj、ж zh、ш sh、ч ch、
///     џ dj、ѕ dz,ICAO Doc 9303 那一套),不用联合国 1977 年那套。
///   - 哈萨克语:哈萨克斯坦 2021 年定的官方拉丁字母(ә ä、ғ ğ、қ q、ң ñ、ө ö、ұ ū、ү ü、і ı、и й i、ш ş、ж j)。
/// 字母大小写跟原文走:大写字母转成多个拉丁字母时,后面跟着小写就只大写第一个(Щ → Šč),
/// 整词大写就全大写。见 10 章决策 49。
public enum CyrillicRomanization {
    public static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCyrillic)
    }

    static func isCyrillic(_ s: Unicode.Scalar) -> Bool { (0x0400...0x052F).contains(s.value) }

    // MARK: - 认语言

    /// 整首歌是哪种语言。没有西里尔字母,或认出来是不支持的语言(吉尔吉斯语、蒙古语等)时返回 nil。
    ///
    /// 每种语言按自己的字母表数「表里没有的字母」出现了几次,最少的那种胜出;几种并列(只用了共有字母,
    /// 俄语 / 保加利亚语最常见)时,先看各自独有的字母,还分不出再交给系统的语言识别 —— 只在西里尔字母
    /// 够 40 个时才问它(一两个词它常认错),不够就按俄语。外来字母超过
    /// 西里尔字母总数的 2% 就当不是这几种语言:歌词里偶尔夹一两个别的语言的字母(形近字符混写)不影响判断。
    public static func detectLanguage(_ text: String) -> CyrillicLanguage? {
        var counts: [Character: Int] = [:]
        var total = 0
        for ch in text.precomposedStringWithCanonicalMapping.lowercased() where ch.unicodeScalars.allSatisfy(isCyrillic) {
            counts[ch, default: 0] += 1
            total += 1
        }
        guard total > 0 else { return nil }
        func count(_ set: String) -> Int { set.reduce(0) { $0 + counts[$1, default: 0] } }
        // 吉尔吉斯语、蒙古语:有 ң ө ү,却没有哈萨克语独有的 ә ғ қ ұ һ。
        if count("ңөү") > 0, count("әғқұһ") == 0 { return nil }
        var foreign: [(language: CyrillicLanguage, foreign: Int, own: Int)] = []
        for language in CyrillicLanguage.allCases {
            let alphabet = alphabets[language]!
            let outside = counts.filter { !alphabet.contains($0.key) }.values.reduce(0, +)
            foreign.append((language, outside, count(distinctive[language]!)))
        }
        let fewest = foreign.map(\.foreign).min()!
        guard fewest * 50 <= total else { return nil }
        let tied = foreign.filter { $0.foreign == fewest }
        if tied.count == 1 { return tied[0].language }
        let mostOwn = tied.map(\.own).max()!
        let leaders = tied.filter { $0.own == mostOwn }
        if leaders.count == 1, mostOwn > 0 { return leaders[0].language }
        let candidates = Set(leaders.map(\.language))
        guard total >= 40 else { return candidates.contains(.russian) ? .russian : leaders[0].language }
        let recognizer = NLLanguageRecognizer()
        let codes: [CyrillicLanguage: NLLanguage] = [.russian: .russian, .bulgarian: .bulgarian, .ukrainian: .ukrainian, .kazakh: .kazakh]
        recognizer.languageConstraints = candidates.compactMap { codes[$0] }
        recognizer.processString(text)
        if let found = recognizer.dominantLanguage, let language = codes.first(where: { $0.value == found })?.key,
            candidates.contains(language)
        {
            return language
        }
        return candidates.contains(.russian) ? .russian : leaders[0].language
    }

    /// 各语言的字母表(小写)。乌克兰语、白俄罗斯语的撇号不是字母,不进表。
    private static let alphabets: [CyrillicLanguage: Set<Character>] = [
        .russian: Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя"),
        .ukrainian: Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя"),
        .bulgarian: Set("абвгдежзийклмнопрстуфхцчшщъьюя"),
        .belarusian: Set("абвгдеёжзійклмнопрстуўфхцчшыьэюя"),
        .serbian: Set("абвгдђежзијклљмнњопрстћуфхцчџш"),
        .macedonian: Set("абвгдѓежзѕијклљмнњопрстќуфхцчџш"),
        .kazakh: Set("аәбвгғдеёжзийкқлмнңоөпрстуұүфхһцчшщъыіьэюя"),
    ]

    /// 各语言(在这几种里)独有或少见的字母,并列时用来分高下。
    private static let distinctive: [CyrillicLanguage: String] = [
        .russian: "ыэё", .ukrainian: "ґєії", .bulgarian: "ъ", .belarusian: "ў", .serbian: "ђћ",
        .macedonian: "ѓќѕ", .kazakh: "әғқұһ",
    ]

    // MARK: - 转写

    /// 一行里的西里尔字母按 `language` 的体系换成拉丁字母,其余字符原样保留。
    public static func romanize(_ text: String, language: CyrillicLanguage) -> String {
        guard containsCyrillic(text) else { return text }
        // 先合成:й ё 这类字母有的歌词存成「и / е + 组合符」,不合成就查不到表。
        let composed = text.precomposedStringWithCanonicalMapping
        let chars = Array(language == .bulgarian ? bulgarianCountryName(composed) : composed)
        var out = ""
        for i in chars.indices {
            let ch = chars[i]
            let lower = Character(ch.lowercased())
            guard ch.unicodeScalars.allSatisfy(isCyrillic) || isApostrophe(ch) else {
                out.append(ch)
                continue
            }
            let previous = i > 0 ? Character(chars[i - 1].lowercased()) : nil
            let next = i + 1 < chars.count ? Character(chars[i + 1].lowercased()) : nil
            let context = Context(
                previous: previous, next: next,
                wordInitial: previous.map { !isLetter($0) && !isApostrophe($0) } ?? true,
                wordFinal: next.map { !isLetter($0) } ?? true)
            guard let latin = latin(lower, language: language, context: context) else {
                out.append(ch)
                continue
            }
            if latin.isEmpty { continue }
            var latinCased = cased(latin, original: ch, neighbours: (i > 0 ? chars[i - 1] : nil, next != nil ? chars[i + 1] : nil))
            // 哈萨克语的 i(и й,以及 ё ю я 开头的 i)大写是带点的 İ;`uppercased()` 只给 I。ı 的大写本来就是 I。
            if language == .kazakh, latin.hasPrefix("i"), latinCased.hasPrefix("I") {
                latinCased = "İ" + latinCased.dropFirst()
            }
            out += latinCased
        }
        // 白俄罗斯语的 ь 写成前一个字母上的锐音符(нь → ń),这里把「字母 + 组合锐音符」合成预组字符。
        return out.precomposedStringWithCanonicalMapping
    }

    struct Context {
        let previous: Character?
        let next: Character?
        let wordInitial: Bool
        let wordFinal: Bool
    }

    private static func isLetter(_ c: Character) -> Bool { c.isLetter }
    private static func isApostrophe(_ c: Character) -> Bool { "'’ʼ".contains(c) }

    private static func cased(_ latin: String, original: Character, neighbours: (Character?, Character?)) -> String {
        guard original.isUppercase else { return latin }
        let allCaps = [neighbours.0, neighbours.1].contains { $0.map { $0.isUppercase } ?? false }
        if allCaps || latin.count == 1 { return latin.uppercased() }
        return latin.prefix(1).uppercased() + latin.dropFirst()
    }

    /// 一个小写字母按语言换成拉丁字母;空串 = 不写;nil = 这个语言里没有这个字母,原样保留。
    static func latin(_ c: Character, language: CyrillicLanguage, context: Context) -> String? {
        switch language {
        case .russian: return russian[c]
        case .ukrainian: return ukrainian(c, context)
        case .bulgarian: return bulgarian(c, context)
        case .belarusian: return belarusian(c, context)
        case .serbian: return serbian[c]
        case .macedonian: return macedonian(c, context)
        case .kazakh: return kazakh[c]
        }
    }

    /// 俄语,GOST 1983(联合国 1987)。ъ、ь 是修饰字母双撇、单撇(U+02BA、U+02B9)。
    static let russian: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "ë", "ж": "ž", "з": "z",
        "и": "i", "й": "j", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "č", "ш": "š", "щ": "šč",
        "ъ": "\u{02BA}", "ы": "y", "ь": "\u{02B9}", "э": "è", "ю": "ju", "я": "ja",
    ]

    /// 乌克兰语,2010 年体系(联合国 2012)。є ї й ю я 在词首写 ye yi y yu ya、其余位置写 ie i i iu ia;
    /// зг 写 zgh;ь 和撇号不写。
    private static func ukrainian(_ c: Character, _ ctx: Context) -> String? {
        switch c {
        case "г": return ctx.previous == "з" ? "gh" : "h"
        case "є": return ctx.wordInitial ? "ye" : "ie"
        case "ї": return ctx.wordInitial ? "yi" : "i"
        case "й": return ctx.wordInitial ? "y" : "i"
        case "ю": return ctx.wordInitial ? "yu" : "iu"
        case "я": return ctx.wordInitial ? "ya" : "ia"
        case "ь", "'", "’", "ʼ": return ""
        default: return ukrainianFixed[c]
        }
    }

    private static let ukrainianFixed: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "ґ": "g", "д": "d", "е": "e", "ж": "zh", "з": "z", "и": "y",
        "і": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s",
        "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
    ]

    /// 保加利亚语,2009 年体系(联合国 2012)。词尾的 -ия 写 -ia。
    private static func bulgarian(_ c: Character, _ ctx: Context) -> String? {
        if c == "я", ctx.previous == "и", ctx.wordFinal { return "a" }
        return bulgarianFixed[c]
    }

    /// 《音译法》第 6 条:国名 България 固定写 Bulgaria(按字母转是 Balgaria)。只认这一个词本身。
    private static let bulgariaWord = try! NSRegularExpression(pattern: "(?<![\\p{L}])(България|БЪЛГАРИЯ)(?![\\p{L}])")

    private static func bulgarianCountryName(_ text: String) -> String {
        let ns = text as NSString
        var out = text
        for m in bulgariaWord.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range)
            let latin = word == "БЪЛГАРИЯ" ? "BULGARIA" : "Bulgaria"
            out = (out as NSString).replacingCharacters(in: m.range, with: latin)
        }
        return out
    }

    private static let bulgarianFixed: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ж": "zh", "з": "z", "и": "i",
        "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s",
        "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sht", "ъ": "a",
        "ь": "y", "ю": "yu", "я": "ya",
    ]

    /// 白俄罗斯语,2007 年体系(联合国 2012)。е ё ю я 在词首、元音 / 撇号 / ь / ў 之后写 je jo ju ja,
    /// 辅音之后写 ie io iu ia;ь 写成前一个字母上的锐音符(дзь dź、зь ź、ль ĺ、нь ń、сь ś、ць ć);撇号不写。
    private static func belarusian(_ c: Character, _ ctx: Context) -> String? {
        let iotated: [Character: String] = ["е": "e", "ё": "o", "ю": "u", "я": "a"]
        if let vowel = iotated[c] {
            let afterConsonant = ctx.previous.map { belarusianConsonants.contains($0) } ?? false
            return (afterConsonant && !ctx.wordInitial ? "i" : "j") + vowel
        }
        switch c {
        case "ь": return "\u{0301}"
        case "'", "’", "ʼ": return ""
        default: return belarusianFixed[c]
        }
    }

    private static let belarusianConsonants: Set<Character> = Set("бвгджзйклмнпрстфхцчшґ")

    private static let belarusianFixed: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "h", "д": "d", "ж": "ž", "з": "z", "і": "i", "й": "j",
        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
        "у": "u", "ў": "ŭ", "ф": "f", "х": "ch", "ц": "c", "ч": "č", "ш": "š", "ы": "y", "э": "e",
    ]

    /// 塞尔维亚语(联合国 1977),即塞尔维亚语的官方拉丁字母。
    static let serbian: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ђ": "đ", "е": "e", "ж": "ž", "з": "z",
        "и": "i", "ј": "j", "к": "k", "л": "l", "љ": "lj", "м": "m", "н": "n", "њ": "nj", "о": "o",
        "п": "p", "р": "r", "с": "s", "т": "t", "ћ": "ć", "у": "u", "ф": "f", "х": "h", "ц": "c",
        "ч": "č", "џ": "dž", "ш": "š",
    ]

    /// 马其顿语,官方证件的无附加符号写法。撇号原样。
    private static func macedonian(_ c: Character, _ ctx: Context) -> String? {
        switch c {
        case "'", "’", "ʼ": return "’"
        default: return macedonianTable[c]
        }
    }

    private static let macedonianTable: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ѓ": "gj", "е": "e", "ж": "zh", "з": "z",
        "ѕ": "dz", "и": "i", "ј": "j", "к": "k", "л": "l", "љ": "lj", "м": "m", "н": "n", "њ": "nj",
        "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "ќ": "kj", "у": "u", "ф": "f", "х": "h",
        "ц": "c", "ч": "ch", "џ": "dj", "ш": "sh",
    ]

    /// 哈萨克语,2021 年官方拉丁字母。ё ю я 写 io iu ia,ц ч щ 写 ts tş ştş,ъ ь 不写;
    /// и й 大写是带点的 İ,і 是不带点的 ı(大写 I),大小写在 `romanize` 里处理。
    static let kazakh: [Character: String] = [
        "а": "a", "ә": "ä", "б": "b", "в": "v", "г": "g", "ғ": "ğ", "д": "d", "е": "e", "ё": "io",
        "ж": "j", "з": "z", "и": "i", "й": "i", "к": "k", "қ": "q", "л": "l", "м": "m", "н": "n",
        "ң": "ñ", "о": "o", "ө": "ö", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ұ": "ū",
        "ү": "ü", "ф": "f", "х": "h", "һ": "h", "ц": "ts", "ч": "tş", "ш": "ş", "щ": "ştş", "ъ": "",
        "ы": "y", "і": "ı", "ь": "", "э": "e", "ю": "iu", "я": "ia",
    ]
}
