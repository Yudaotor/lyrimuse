import Foundation

/// 泰文读音:皇家学术院转写(RTGS,泰国 2000 年官方体系,联合国 2002 年 VIII/13 决议推荐)。
///
/// RTGS 按读音写:声调符号、不发音符号(◌์)、短音符号(◌็)一律不写,同一个字母做声母和做
/// 韵尾写法不同,词里不写出的元音要补出来(คน khon、สบาย sabai)。不知道这个词怎么念就写不对,
/// 所以先查词典(`ThaiRTGSTable`,Wiktionary 的皇家学术院写法),查不到的按词典里的词切开,
/// 再查不到的才按联合国文件里的声母 / 韵尾 / 元音表逐个音节拼。
///
/// 输出规则同联合国文件(UNGEGN WGRS 泰语报告 4.0 版)的注:
///   - 音节之间要分开读的加连字符:前一音节以元音结尾、后一音节以 ng 开头;前一音节以 ng
///     结尾、后一音节以元音开头;后一音节以元音开头(สะอาด sa-at、บังอร bang-on)。
///   - ๆ 把前一个词按读音再写一遍(บ่อยๆ boi boi)。
///   - 词与词之间用空格;非泰文字符原样保留。
/// 见 10 章决策 49。
public enum ThaiRomanization {
    /// 一行里的泰文片段换成 RTGS,其余字符原样保留。不含泰文时原样返回。
    public static func romanize(_ text: String) -> String {
        let normalized = normalize(text)
        var out = ""
        var run = ""
        // ๆ 常跟前一个词隔着空格(นาน ๆ),前一个词的读音要跨过空格带过去。
        var previous: String?
        func flush() {
            guard !run.isEmpty else { return }
            out += romanizeRun(run, previous: &previous)
            run = ""
        }
        for scalar in normalized.unicodeScalars {
            if isThai(scalar) {
                run.unicodeScalars.append(scalar)
            } else {
                flush()
                out.unicodeScalars.append(scalar)
            }
        }
        flush()
        return out
    }

    /// 词典第一次用时解析(约 45 毫秒)。换到泰语歌时在后台先解析好,别让第一句歌词在主线程上等它。
    public static func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = dictionary }
    }

    public static func containsThai(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isThai)
    }

    // MARK: - 词

    private static func romanizeRun(_ run: String, previous: inout String?) -> String {
        var words: [String] = []
        for token in tokenize(run) {
            if token == "ๆ" {
                if let previous { words.append(previous) }
                continue
            }
            var body = token
            var repeats = 0
            while body.hasSuffix("ๆ") {
                body.removeLast()
                repeats += 1
            }
            guard !body.isEmpty else { continue }
            let reading = readWord(body)
            guard !reading.isEmpty else { continue }
            words.append(reading)
            for _ in 0..<repeats { words.append(reading) }
            previous = reading
        }
        return words.joined(separator: " ")
    }

    private static let tokenizerLocale = CFLocaleCreate(nil, CFLocaleIdentifier("th_TH" as CFString))

    private static func tokenize(_ run: String) -> [String] {
        let cf = run as CFString
        let ns = run as NSString
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, CFRangeMake(0, CFStringGetLength(cf)), kCFStringTokenizerUnitWordBoundary, tokenizerLocale)
        var tokens: [String] = []
        var kind = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while kind != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let piece = ns.substring(with: NSRange(location: r.location, length: r.length))
            if containsThai(piece) { tokens.append(piece) }
            kind = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return tokens
    }

    /// 一个词的读音(音节按 RTGS 的连字符规则拼好)。
    static func readWord(_ word: String) -> String {
        wordCache.value(for: word) { joinWords(segment(Array($0.unicodeScalars))) }
    }

    private static let wordCache = BoundedMemo<String>(limit: 4096)

    /// 只按规则拼(不查词典)。selftest 和规则准确率评估用。
    public static func ruleOnly(_ word: String) -> String {
        joinWords(segment(Array(word.unicodeScalars), useDictionary: false))
    }

    /// 查词典但不认这个词本身:看复合词能不能由别的词拼回来。评估用。
    static func readWordExcluding(_ word: String) -> String {
        joinWords(segment(Array(word.unicodeScalars), excluding: word))
    }

    /// 一段泰文切成若干片,每片是词典里的一个词(读音来自词典)或按规则拼出的一个音节。按 Unicode 标量切:
    /// 泰文的元音、声调符号是组合字符,按 Character 会跟前面的辅音并成一个。
    /// 代价最小的切法胜出:词典词记 1、规则音节记 3、单独一个辅音补 a 的记 5,读不出的标量记 100、不出读音。
    private static func segment(
        _ chars: [Unicode.Scalar], useDictionary: Bool = true, excluding: String? = nil
    ) -> [[String]] {
        let n = chars.count
        var best = [(cost: Int, pieces: [[String]])?](repeating: nil, count: n + 1)
        best[0] = (0, [])
        let table = dictionary
        for i in 0..<n {
            guard let here = best[i] else { continue }
            func offer(_ end: Int, _ cost: Int, _ piece: [String]?) {
                let total = here.cost + cost
                if let current = best[end], current.cost <= total { return }
                best[end] = (total, piece.map { here.pieces + [$0] } ?? here.pieces)
            }
            if useDictionary {
                var key = String.UnicodeScalarView()
                for j in i..<min(n, i + table.maxLength) {
                    key.append(chars[j])
                    let piece = String(key)
                    if piece != excluding, let reading = table.words[piece] { offer(j + 1, 1, reading) }
                }
            }
            for syllable in ThaiSyllable.parse(chars, at: i) {
                offer(i + syllable.length, syllable.cost, [syllable.reading])
            }
            offer(i + 1, 100, nil)
        }
        return best[n]?.pieces ?? []
    }

    /// 片与片接起来:词典里带空格的短语原样分词,其余音节按 RTGS 注 1 决定要不要加连字符。
    private static func joinWords(_ pieces: [[String]]) -> String {
        var words: [[String]] = [[]]
        for piece in pieces {
            for (k, word) in piece.enumerated() {
                if k > 0 { words.append([]) }
                words[words.count - 1].append(word)
            }
        }
        return words.filter { !$0.isEmpty }
            .map { joinSyllables($0.flatMap { $0.split(separator: "-").map(String.init) }) }
            .joined(separator: " ")
    }

    static func joinSyllables(_ syllables: [String]) -> String {
        var out = ""
        for syllable in syllables where !syllable.isEmpty {
            if let last = out.last, let first = syllable.first {
                let vowelThenNg = isVowel(last) && syllable.hasPrefix("ng")
                if vowelThenNg || isVowel(first) { out.append("-") }
            }
            out += syllable
        }
        return out
    }

    private static func isVowel(_ c: Character) -> Bool { "aeiou".contains(c) }

    // MARK: - 词典

    struct Dictionary {
        var words: [String: [String]] = [:]
        var maxLength = 1
    }

    /// 读音按空格拆成词、每个词保留连字符(拼接时再拆成音节)。maxLength 按 Unicode 标量数。
    /// static let 的初始化本身是线程安全的,`prewarm` 从后台先触发也没问题。
    static let dictionary: Dictionary = {
        var d = Dictionary()
        for line in ThaiRTGSTable.entries.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let word = String(line[..<tab])
            d.words[word] = line[line.index(after: tab)...].split(separator: " ").map(String.init)
            d.maxLength = max(d.maxLength, word.unicodeScalars.count)
        }
        return d
    }()

    // MARK: - 规范化

    /// 「ํ + า」是「ำ」的拆写(部分歌词源这么存),合回去;去掉零宽字符。
    private static func normalize(_ text: String) -> String {
        guard containsThai(text) else { return text }
        return text.replacingOccurrences(of: "\u{0E4D}\u{0E32}", with: "\u{0E33}")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
    }

    /// 泰文字母与符号(不含泰文数字):U+0E01–U+0E4F、U+0E5A–U+0E5B。
    static func isThai(_ scalar: Unicode.Scalar) -> Bool {
        (0x0E01...0x0E4F).contains(scalar.value) || (0x0E5A...0x0E5B).contains(scalar.value)
    }
}

/// 词典里没有的音节,按联合国文件的表 I(声母 / 韵尾)、表 II(元音)逐个拼。全部按 Unicode 标量处理。
enum ThaiSyllable {
    struct Match {
        let length: Int
        let reading: String
        let cost: Int
    }

    private static func table(_ pairs: [(String, String)]) -> [UInt32: String] {
        var t: [UInt32: String] = [:]
        for (k, v) in pairs { t[k.unicodeScalars.first!.value] = v }
        return t
    }

    /// 表 I:做声母时的写法。อ 做元音的载体时不读(注 4)。
    static let initials = table([
        ("ก", "k"), ("ข", "kh"), ("ฃ", "kh"), ("ค", "kh"), ("ฅ", "kh"), ("ฆ", "kh"), ("ง", "ng"), ("จ", "ch"),
        ("ฉ", "ch"), ("ช", "ch"), ("ซ", "s"), ("ฌ", "ch"), ("ญ", "y"), ("ฎ", "d"), ("ฏ", "t"), ("ฐ", "th"),
        ("ฑ", "th"), ("ฒ", "th"), ("ณ", "n"), ("ด", "d"), ("ต", "t"), ("ถ", "th"), ("ท", "th"), ("ธ", "th"),
        ("น", "n"), ("บ", "b"), ("ป", "p"), ("ผ", "ph"), ("ฝ", "f"), ("พ", "ph"), ("ฟ", "f"), ("ภ", "ph"),
        ("ม", "m"), ("ย", "y"), ("ร", "r"), ("ล", "l"), ("ว", "w"), ("ศ", "s"), ("ษ", "s"), ("ส", "s"),
        ("ห", "h"), ("ฬ", "l"), ("อ", ""), ("ฮ", "h"),
    ])

    /// 表 I 括号里:做韵尾时的写法。ย、ว 做韵尾时是元音的一部分,写在元音表里。
    static let finals = table([
        ("ก", "k"), ("ข", "k"), ("ฃ", "k"), ("ค", "k"), ("ฅ", "k"), ("ฆ", "k"), ("ง", "ng"), ("จ", "t"),
        ("ฉ", "t"), ("ช", "t"), ("ซ", "t"), ("ฌ", "t"), ("ญ", "n"), ("ฎ", "t"), ("ฏ", "t"), ("ฐ", "t"),
        ("ฑ", "t"), ("ฒ", "t"), ("ณ", "n"), ("ด", "t"), ("ต", "t"), ("ถ", "t"), ("ท", "t"), ("ธ", "t"),
        ("น", "n"), ("บ", "p"), ("ป", "p"), ("ผ", "p"), ("ฝ", "p"), ("พ", "p"), ("ฟ", "p"), ("ภ", "p"),
        ("ม", "m"), ("ร", "n"), ("ล", "n"), ("ศ", "t"), ("ษ", "t"), ("ส", "t"), ("ฬ", "n"),
    ])

    private static func scalars(_ s: String) -> Set<UInt32> { Set(s.unicodeScalars.map(\.value)) }

    /// 能跟 ร ล ว 组成复辅音的声母。
    private static let clusterHeads = scalars("กขคตปผพ")
    private static let clusterTails = scalars("รลว")
    /// 「จ ซ ศ ส + ร」里 ร 不读(จริง ching、สร้าง sang)。
    private static let silentRHeads = scalars("จซศส")
    /// 「ห + 低辅音」里 ห 不读,只定声调。
    private static let silentHTargets = scalars("งญนมยรลว")
    /// 声调符号和短音符号:RTGS 不写。
    private static let ignored = scalars("\u{0E48}\u{0E49}\u{0E4A}\u{0E4B}\u{0E47}")
    /// 写在辅音后面的元音符号:有它就说明前面那个辅音是这一音节的声母、不是上一音节的韵尾。
    private static let dependentVowels = scalars("\u{0E30}\u{0E31}\u{0E32}\u{0E33}\u{0E34}\u{0E35}\u{0E36}\u{0E37}\u{0E38}\u{0E39}")
    private static let karan: UInt32 = 0x0E4C

    private enum Item { case initial, final, literal(UInt32) }

    /// 表 II,ก 写成 C、韵尾写成 F(带 F 的模板韵尾必须有)。另加不写元音的闭音节 CF → o(คน khon)。
    private static let templates: [(items: [Item], vowel: String)] = [
        ("เCียว", "iao"), ("เCือย", "ueai"), ("เCียะ", "ia"), ("เCือะ", "uea"),
        ("เCียF", "ia"), ("เCือF", "uea"), ("เCีย", "ia"), ("เCือ", "uea"),
        ("เCาะ", "o"), ("เCอะ", "oe"), ("เCิF", "oe"), ("เCอ", "oe"), ("เCา", "ao"),
        ("เCย", "oei"), ("เCว", "eo"), ("เCะ", "e"), ("เCF", "e"), ("เC", "e"),
        ("แCว", "aeo"), ("แCะ", "ae"), ("แCF", "ae"), ("แC", "ae"),
        ("โCย", "oi"), ("โCะ", "o"), ("โCF", "o"), ("โC", "o"),
        ("ใC", "ai"), ("ไCย", "ai"), ("ไC", "ai"),
        ("Cัวะ", "ua"), ("Cัว", "ua"), ("CวF", "ua"), ("Cวย", "uai"),
        ("Cัย", "ai"), ("CัF", "a"), ("Cาย", "ai"), ("Cาว", "ao"), ("CาF", "a"), ("Cา", "a"),
        ("Cะ", "a"), ("Cำ", "am"), ("CรรF", "a"), ("Cรร", "an"),
        ("Cิว", "io"), ("CิF", "i"), ("Cิ", "i"), ("CีF", "i"), ("Cี", "i"),
        ("CึF", "ue"), ("Cึ", "ue"), ("CืF", "ue"), ("Cือ", "ue"),
        ("Cุย", "ui"), ("CุF", "u"), ("Cุ", "u"), ("CูF", "u"), ("Cู", "u"),
        ("Cอย", "oi"), ("CอF", "o"), ("Cอ", "o"),
        ("CF", "o"),
    ].map { pattern, vowel in
        (pattern.unicodeScalars.map { scalar -> Item in
            switch scalar {
            case "C": return .initial
            case "F": return .final
            default: return .literal(scalar.value)
            }
        }, vowel)
    }

    static func parse(_ chars: [Unicode.Scalar], at start: Int) -> [Match] {
        guard start < chars.count else { return [] }
        let first = chars[start].value
        if first == 0x0E24 || first == 0x0E26 {  // ฤ ฦ(ฤๅ ฦๅ 同音)
            let long = start + 1 < chars.count && chars[start + 1].value == 0x0E45
            return [Match(length: long ? 2 : 1, reading: first == 0x0E24 ? "rue" : "lue", cost: 3)]
        }
        var matches: [Match] = []
        for template in templates {
            matches += match(template.items, vowel: template.vowel, chars, start)
        }
        // 什么元音都不带的单个声母:补出不写的 a(สบาย 的 ส)。
        for initial in readInitial(chars, start) {
            let end = skipSilent(chars, skipIgnored(chars, initial.end))
            matches.append(Match(length: end - start, reading: initial.reading + "a", cost: 5))
        }
        return matches
    }

    private static func match(_ items: [Item], vowel: String, _ chars: [Unicode.Scalar], _ start: Int) -> [Match] {
        // 声母可能有几种读法(复辅音 / 单辅音),各走一遍。
        var states: [(i: Int, onset: String, coda: String)] = [(start, "", "")]
        for item in items {
            var next: [(i: Int, onset: String, coda: String)] = []
            for state in states {
                let i = skipIgnored(chars, state.i)
                switch item {
                case .initial:
                    for initial in readInitial(chars, i) { next.append((initial.end, initial.reading, state.coda)) }
                case .final:
                    // 元音和韵尾之间被 ◌์ 压着的辅音不读(การ์ด kat)。
                    let i = skipSilent(chars, i, pairs: false)
                    guard i < chars.count, let f = finals[chars[i].value] else { continue }
                    let after = skipIgnored(chars, i + 1)
                    if after < chars.count, dependentVowels.contains(chars[after].value) { continue }
                    next.append((skipTrailingSilent(chars, skipSilent(chars, i + 1), explicitVowel: items.count > 2),
                                 state.onset, f))
                case .literal(let value):
                    guard i < chars.count, chars[i].value == value else { continue }
                    next.append((i + 1, state.onset, state.coda))
                }
            }
            states = next
            if states.isEmpty { return [] }
        }
        return states.map { state in
            let end = skipSilent(chars, skipIgnored(chars, state.i))
            return Match(length: end - start, reading: state.onset + vowel + state.coda, cost: 3)
        }
    }

    /// 声母的几种读法:单辅音;复辅音(กร、คล、ปร…);จ ซ ศ ส + ร(ร 不读);ทร 读 s;ห 引低辅音;อย。
    private static func readInitial(_ chars: [Unicode.Scalar], _ start: Int) -> [(reading: String, end: Int)] {
        guard start < chars.count, let single = initials[chars[start].value] else { return [] }
        let c = chars[start].value
        var out: [(String, Int)] = []
        if start + 1 < chars.count {
            let n = chars[start + 1].value
            if c == 0x0E2B, silentHTargets.contains(n), let r = initials[n] { out.append((r, start + 2)) }  // ห
            if c == 0x0E2D, n == 0x0E22 { out.append(("y", start + 2)) }  // อย
            if c == 0x0E17, n == 0x0E23 { out.append(("s", start + 2)) }  // ทร
            if clusterHeads.contains(c), clusterTails.contains(n), let r = initials[n] { out.append((single + r, start + 2)) }
            if silentRHeads.contains(c), n == 0x0E23 { out.append((single, start + 2)) }
        }
        out.append((single, start + 1))
        return out
    }

    private static func skipIgnored(_ chars: [Unicode.Scalar], _ i: Int) -> Int {
        var j = i
        while j < chars.count, ignored.contains(chars[j].value) { j += 1 }
        return j
    }

    /// 不发音符号 ◌์ 连同它压着的辅音(和中间的 ◌ิ ◌ุ)都不读,连着几个一并吃掉。韵尾之后(`pairs`)
    /// ◌์ 压着第二个辅音、前面紧挨着一个辅音的(จันทร์ 的 ทร์、ศาสตร์ 的 ตร์),两个都不读;元音和韵尾
    /// 之间只吃一个(การ์ด 的 ร์)。
    private static func skipSilent(_ chars: [Unicode.Scalar], _ i: Int, pairs: Bool = true) -> Int {
        var j = i
        while true {
            if let end = silentRun(chars, j, consonants: 1) ?? (pairs ? silentRun(chars, j, consonants: 2) : nil) {
                j = end
            } else {
                return j
            }
        }
    }

    private static func silentRun(_ chars: [Unicode.Scalar], _ i: Int, consonants: Int) -> Int? {
        var k = i
        for _ in 0..<consonants {
            guard k < chars.count, initials[chars[k].value] != nil else { return nil }
            k += 1
        }
        while k < chars.count, chars[k].value == 0x0E34 || chars[k].value == 0x0E38 || ignored.contains(chars[k].value) {
            k += 1
        }
        guard k < chars.count, chars[k].value == karan else { return nil }
        return k + 1
    }

    /// 词尾不发音的梵巴借词收尾:韵尾后面紧跟、一直到词尾的 ร(จักร chak、จิตร chit),
    /// 或 ◌ิ ◌ุ(ชาติ chat、ธาตุ that)。只认写了元音的音节,不写元音的(มติ)是两个音节。
    private static func skipTrailingSilent(_ chars: [Unicode.Scalar], _ i: Int, explicitVowel: Bool) -> Int {
        guard explicitVowel, i + 1 == chars.count else { return i }
        let v = chars[i].value
        return v == 0x0E23 || v == 0x0E34 || v == 0x0E38 ? i + 1 : i
    }
}
