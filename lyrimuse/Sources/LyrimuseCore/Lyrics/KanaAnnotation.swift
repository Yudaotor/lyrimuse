import Foundation

/// 酷狗歌词自带的**假名标注**(furigana)——汉字该怎么读,由歌词源直接给出,不用再让
/// 形态分析器在多个合法读音里挑。
///
/// 为什么需要:CFStringTokenizer 只能给一个"词典里的某个读音",遇到多音词就未必是这首歌
/// 里唱的那个。2026-08-10 用户实测对比 Apple Music:「明日」我们读 asu、Apple 读
/// ashita —— 两个都是这个词的合法读音,分词器无从判断。而酷狗的 LRC 里**明明白白写着**
/// 这里念 あした,只是这个标签一直没人读。
///
/// ## 格式(2026-08-10 逆向 + 全曲对齐校验坐实)
///
/// LRC 里有一行 `[kana:...]`,内容是一串 `<单个数字><读音假名>` 条目:
///
///     [kana:1111 1う1た1だ1し …… 2あ(43121,327)し(43448,344)た(43792,504)1い(45296,241)ま……]
///
///   - 数字是**单个**数字(不是多位数),表示这条读音覆盖几个待标字符;
///   - 读音里可能夹着 `(起始毫秒,时长)`,是逐音节的时间戳(本类型目前只取文字,时间戳留着
///     以后做逐音节填色);
///   - 读音为空表示这几个字没有标注。
///
/// 条目按顺序对齐正文里的**待标字符**(汉字 + 叠字符号 `々`),**不是**逐字覆盖全文 ——
/// 假名/拉丁字母/标点都不占条目。实测 First Love:正文 82 个待标字符、条目覆盖 82 个,
/// 严丝合缝;而 `々` 一开始漏算就会从「百々政幸」那里开始整体错位一格,后面全歪。
///
/// `2あした` 这条正是关键:数字 2 表示这个读音覆盖**两个**汉字(明+日),这是分词器给不出
/// 的信息。
///
/// ## 严格性
///
/// 对不齐就**整份弃用**、退回形态分析。半对半错地标歪比不标更糟:用户没法一眼看出哪一行
/// 的读音被串了,只会觉得这个功能不可信。
public struct KanaAnnotation {
    /// 一行里的一处标注:范围是这一行内的 UTF-16 区间。
    public struct Mark: Equatable {
        public let utf16Start: Int
        public let utf16Length: Int
        public let reading: String
        public var utf16End: Int { utf16Start + utf16Length }
    }

    /// 行文本 → 这一行的标注。按行文本索引而不是行号:逐字歌词(YRC)的行集合跟 LRC 的
    /// 行集合不一定一一对应,用文本对得上就行。同一句重复出现时读音也一样,后写覆盖前写
    /// 没有影响。
    private let byLine: [String: [Mark]]

    public func marks(forLine line: String) -> [Mark] { byLine[line] ?? [] }
    public var isEmpty: Bool { byLine.isEmpty }

    /// 需要标注的字符:汉字,以及叠字符号 `々`(它不在 CJK 统一表意文字区里,单独算)。
    public static func needsAnnotation(_ c: Character) -> Bool {
        if c == "々" { return true }
        return c.unicodeScalars.contains { CharacterSet.ideographicHan.contains($0) }
    }

    /// 从整份 LRC 里解析。没有 `[kana:]` 标签、或对不齐时返回 nil。
    public static func parse(lrc: String) -> KanaAnnotation? {
        guard let raw = kanaTag(in: lrc) else { return nil }
        let entries = parseEntries(raw)
        guard !entries.isEmpty else { return nil }

        let lines = bodyLines(of: lrc)
        // 先做总数校验 —— 对不上就整份弃用,不冒着"从某一行开始全歪"的风险硬塞。
        let need = lines.reduce(0) { $0 + $1.filter(needsAnnotation).count }
        guard need == entries.reduce(0, { $0 + $1.count }), need > 0 else { return nil }

        var byLine: [String: [Mark]] = [:]
        var entryIdx = 0
        var pendingInEntry = 0 // 当前条目还剩几个字没消费(跨行的整词标注)
        for line in lines {
            var marks: [Mark] = []
            var utf16Pos = 0
            var i = line.startIndex
            while i < line.endIndex {
                let ch = line[i]
                let w = String(ch).utf16.count
                guard needsAnnotation(ch) else {
                    utf16Pos += w
                    i = line.index(after: i)
                    continue
                }
                if pendingInEntry == 0 {
                    guard entryIdx < entries.count else { return nil }
                    pendingInEntry = entries[entryIdx].count
                }
                // 一条读音可能覆盖好几个字(「明日」→ あした),把这几个字并成一个 Mark。
                let start = utf16Pos
                var length = 0
                var consumed = 0
                while i < line.endIndex, consumed < pendingInEntry {
                    let c = line[i]
                    let cw = String(c).utf16.count
                    if needsAnnotation(c) { consumed += 1 }
                    length += cw
                    utf16Pos += cw
                    i = line.index(after: i)
                    // 覆盖的字数够了就停,别把后面跟着的假名也吃进这个 Mark
                    if consumed == pendingInEntry { break }
                }
                let reading = entries[entryIdx].reading
                if !reading.isEmpty {
                    marks.append(Mark(utf16Start: start, utf16Length: length, reading: reading))
                }
                if consumed == pendingInEntry {
                    entryIdx += 1
                    pendingInEntry = 0
                } else {
                    // 这条标注跨到了下一行(理论上不该发生),剩下的留给下一行继续消费
                    pendingInEntry -= consumed
                }
            }
            if !marks.isEmpty { byLine[line] = marks }
        }
        guard !byLine.isEmpty else { return nil }
        return KanaAnnotation(byLine: byLine)
    }

    // MARK: - 解析细节

    private static func kanaTag(in lrc: String) -> String? {
        for line in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("[kana:"), s.hasSuffix("]") else { continue }
            return String(s.dropFirst("[kana:".count).dropLast())
        }
        return nil
    }

    struct Entry: Equatable {
        let count: Int
        let reading: String
    }

    /// `<单个数字><读音>` 序列。读音里的 `(起始,时长)` 先剥掉(逐音节时间戳,暂未使用)。
    static func parseEntries(_ raw: String) -> [Entry] {
        var out: [Entry] = []
        var idx = raw.startIndex
        while idx < raw.endIndex {
            guard let digit = raw[idx].wholeNumberValue, raw[idx].isNumber else {
                idx = raw.index(after: idx) // 落单的杂字符,跳过
                continue
            }
            idx = raw.index(after: idx)
            var reading = ""
            while idx < raw.endIndex {
                let c = raw[idx]
                if c.isNumber { break }
                if c == "(" {
                    // 跳过整个 (起始,时长)
                    while idx < raw.endIndex, raw[idx] != ")" { idx = raw.index(after: idx) }
                    if idx < raw.endIndex { idx = raw.index(after: idx) }
                    continue
                }
                reading.append(c)
                idx = raw.index(after: idx)
            }
            out.append(Entry(count: max(1, digit), reading: reading))
        }
        return out
    }

    /// 正文行:带时间戳、且去掉时间戳后非空的行。跟标注对齐用的就是这一组、这个顺序。
    static func bodyLines(of lrc: String) -> [String] {
        var out: [String] = []
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard let m = lrcTimeTag.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            _ = m
            let text = lrcTimeTag.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(text) }
        }
        return out
    }

    private static let lrcTimeTag = try! NSRegularExpression(
        pattern: #"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#)
}

extension CharacterSet {
    /// CJK 统一表意文字(含扩展 A)。`々` 不在其中,由 needsAnnotation 单独收。
    fileprivate static let ideographicHan: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: Unicode.Scalar(0x4E00)!...Unicode.Scalar(0x9FFF)!)
        s.insert(charactersIn: Unicode.Scalar(0x3400)!...Unicode.Scalar(0x4DBF)!)
        return s
    }()
}
