import Foundation

/// 「搜索候选歌词」里一条候选跟当前使用那份对照:逐字找两边对得上的字,再把字连着的行归成一块,标出改了的字、
/// 只有一边有的句子、分行方式不同、时间差得多的地方。放在 LyrimuseCore 是为了可测:面板在 app target 里,
/// selftest 够不着。见 11 章决策 106。
///
/// 按字比、不按行比:各家分行常常不一样(一句长句拆成三四句短句),按行比会把同一段词判成一句改了字加几句多出来的,
/// 满屏都是差别。
public enum LyricsCandidateComparison {
    /// 时间差到这么多才写出来:少于它的是各家打轴的正常出入。
    public static let retimeThresholdMs = 500
    /// 两边都一个字也对不上的句子,时间差在这以内当成同一句改了字;再远就是一边多出来的。
    static let substitutionWindowMs = 2_000

    public enum Kind: Equatable {
        /// 一句对一句,字全对得上。
        case same
        /// 字全对得上,分行不同(一边一句、另一边几句)。
        case resegmented
        /// 有字对不上(改了字、多了或少了几个字)。
        case changed
        /// 只有候选有这一句。
        case onlyCandidate
        /// 只有当前使用的有这一句。
        case onlyCurrent
    }

    /// 对照的一行。左边是候选的一句(只有当前使用有的那几行没有),右边是当前使用里跟它同一块的那几句,
    /// 只摆在这一块的第一行;同一块后面几行 `continuation` 为真,右边留空。
    public struct Pair: Equatable {
        public let candidate: Int?
        public let current: [Int]
        public let kind: Kind
        public let continuation: Bool
        /// 这一块开头那句的时间差(候选减当前,正数是候选晚),超过 `retimeThresholdMs` 才有,只挂在块的第一行。
        public let deltaMs: Int?
        /// 候选这一句里对不上的字,按 `Character` 下标。
        public let candidateMarks: Set<Int>
        /// 跟 `current` 一一对应,当前使用那几句里对不上的字。
        public let currentMarks: [Set<Int>]
        /// 这一块里有字只是繁简写法不同(按简体比对得上、原字不一样),只挂在块的第一行。
        public let scriptVariant: Bool

        public init(candidate: Int?, current: [Int], kind: Kind, continuation: Bool = false, deltaMs: Int? = nil,
                    candidateMarks: Set<Int> = [], currentMarks: [Set<Int>]? = nil, scriptVariant: Bool = false) {
            self.candidate = candidate
            self.current = current
            self.kind = kind
            self.continuation = continuation
            self.deltaMs = deltaMs
            self.candidateMarks = candidateMarks
            self.currentMarks = currentMarks ?? current.map { _ in [] }
            self.scriptVariant = scriptVariant
        }
    }

    /// 对照下来各种差别有几处:改了字和分行不同按块数,只一边有的按句数,时间差按块数。
    public struct Summary: Equatable {
        public var changed = 0
        public var onlyCandidate = 0
        public var onlyCurrent = 0
        public var retimed = 0
        public var resegmented = 0
        /// 有几块只是繁简写法不同。不算差别,但采用后显示的字会跟着变,小结里要说。
        public var scriptVariants = 0

        public init(changed: Int = 0, onlyCandidate: Int = 0, onlyCurrent: Int = 0, retimed: Int = 0,
                    resegmented: Int = 0, scriptVariants: Int = 0) {
            self.changed = changed
            self.onlyCandidate = onlyCandidate
            self.onlyCurrent = onlyCurrent
            self.retimed = retimed
            self.resegmented = resegmented
            self.scriptVariants = scriptVariants
        }

        /// 词和时间都一样(分行不同不算不一样)。
        public var isIdentical: Bool { changed == 0 && onlyCandidate == 0 && onlyCurrent == 0 && retimed == 0 }
    }

    /// 参与对照的一句:时间是这份歌词实际生效的时间(LRC 时间戳减去它自带的 `[offset:]`),没有时间戳为 nil。
    public struct Line: Equatable {
        public let timeMs: Int?
        public let text: String

        public init(timeMs: Int?, text: String) {
            self.timeMs = timeMs
            self.text = text
        }
    }

    /// 预览行换成参与对照的句子。`embeddedOffsetMs` 是这份歌词自带的 `[offset:]`(正数 = 歌词提前)。
    public static func lines(_ rows: [LyricsPreviewRow], embeddedOffsetMs: Int) -> [Line] {
        rows.map { Line(timeMs: $0.timeMs.map { $0 - embeddedOffsetMs }, text: $0.text) }
    }

    public static func summary(_ pairs: [Pair]) -> Summary {
        var s = Summary()
        for pair in pairs {
            if pair.deltaMs != nil { s.retimed += 1 }
            if pair.scriptVariant { s.scriptVariants += 1 }
            switch pair.kind {
            case .same: break
            case .resegmented: if !pair.continuation { s.resegmented += 1 }
            case .changed: if !pair.continuation { s.changed += 1 }
            case .onlyCandidate: s.onlyCandidate += 1
            case .onlyCurrent: s.onlyCurrent += 1
            }
        }
        return s
    }

    /// 一句话参与比对的形状:只留字母和数字,转小写(同 `tokens` 的取字规则)。
    static func key(_ text: String) -> String {
        text.filter { $0.isLetter || $0.isNumber }.map { $0.lowercased() }.joined()
    }

    /// 参与比对的一个字:只取字母和数字,转小写、汉字转简体(繁简写法不同不算改了字),记着原字、在第几句、
    /// 是那一句的第几个字符。
    private struct Token {
        let key: String
        let raw: String
        let line: Int
        let offset: Int
    }

    private static func tokens(_ lines: [Line]) -> [Token] {
        var out: [Token] = []
        for (lineIndex, line) in lines.enumerated() {
            let original = Array(line.text)
            // 整句一起转(字形转换吃上下文),字数变了就不转这一句。
            let folded = Array(HanScript.simplified(line.text))
            let canFold = folded.count == original.count
            for (offset, character) in original.enumerated() where character.isLetter || character.isNumber {
                let raw = character.lowercased()
                out.append(Token(key: canFold ? folded[offset].lowercased() : raw, raw: raw, line: lineIndex, offset: offset))
            }
        }
        return out
    }

    /// 两串字里对得上的那些(各自的下标),按先后。用最短编辑脚本(`difference(from:)`),没删也没插的就是对上的。
    private static func matchedPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var out: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if removed.contains(i) { i += 1; continue }
            if inserted.contains(j) { j += 1; continue }
            out.append((i, j))
            i += 1
            j += 1
        }
        return out
    }

    /// 一对句子之间对上的字够不够多,够才把这两句连成一块:对上的字至少是较短那句的三分之一,而且至少两个字
    /// (那句本身只有一两个字时一个就行)。零星一个「的」「我」对上不算,不然不相干的句子会被串成一大块。
    private static func isStrongLink(matched: Int, lengthA: Int, lengthB: Int) -> Bool {
        let shorter = min(lengthA, lengthB)
        return matched * 3 >= shorter && (matched >= 2 || shorter <= 2)
    }

    public static func align(candidate: [Line], current: [Line]) -> [Pair] {
        let ta = tokens(candidate)
        let tb = tokens(current)
        let lengthA = candidate.indices.map { i in ta.filter { $0.line == i }.count }
        let lengthB = current.indices.map { j in tb.filter { $0.line == j }.count }
        let matches = matchedPairs(ta.map(\.key), tb.map(\.key))

        // 每一对句子之间对上了几个字。
        var linkCount: [Int: [Int: Int]] = [:]
        for (i, j) in matches {
            linkCount[ta[i].line, default: [:]][tb[j].line, default: 0] += 1
        }
        func strong(_ la: Int, _ lb: Int) -> Bool {
            isStrongLink(matched: linkCount[la]?[lb] ?? 0, lengthA: lengthA[la], lengthB: lengthB[lb])
        }
        // 对上的字只认连成块的那些;零星对上的跟没对上一样标出来。
        var matchedA = Set<Int>()
        var matchedB = Set<Int>()
        var links: [(Int, Int)] = []
        var variantLinesA = Set<Int>()
        for (i, j) in matches where strong(ta[i].line, tb[j].line) {
            matchedA.insert(i)
            matchedB.insert(j)
            if ta[i].raw != tb[j].raw { variantLinesA.insert(ta[i].line) }
            let link = (ta[i].line, tb[j].line)
            if links.last.map({ $0 != link }) ?? true { links.append(link) }
        }
        var marksA = candidate.map { _ in Set<Int>() }
        var marksB = current.map { _ in Set<Int>() }
        for (index, token) in ta.enumerated() where !matchedA.contains(index) { marksA[token.line].insert(token.offset) }
        for (index, token) in tb.enumerated() where !matchedB.contains(index) { marksB[token.line].insert(token.offset) }

        // 连着的句子归成块。字的对应是按先后的,块在两边也都是连续的几句。
        var blocks: [(a: ClosedRange<Int>, b: ClosedRange<Int>)] = []
        for (la, lb) in links {
            if let last = blocks.last, la <= last.a.upperBound || lb <= last.b.upperBound {
                blocks[blocks.count - 1] = (last.a.lowerBound...max(last.a.upperBound, la),
                                            last.b.lowerBound...max(last.b.upperBound, lb))
            } else {
                blocks.append((la...la, lb...lb))
            }
        }

        var out: [Pair] = []
        var nextA = 0, nextB = 0
        for block in blocks {
            out += pairGap(candidate: candidate, current: current,
                           candidateRange: nextA..<block.a.lowerBound, currentRange: nextB..<block.b.lowerBound)
            let marked = block.a.contains { !marksA[$0].isEmpty } || block.b.contains { !marksB[$0].isEmpty }
            let kind: Kind = marked ? .changed : (block.a.count == 1 && block.b.count == 1 ? .same : .resegmented)
            let delta = deltaMs(candidate[block.a.lowerBound], current[block.b.lowerBound])
            for a in block.a {
                let first = a == block.a.lowerBound
                out.append(Pair(candidate: a, current: first ? Array(block.b) : [], kind: kind,
                                continuation: !first, deltaMs: first ? delta : nil,
                                candidateMarks: marksA[a], currentMarks: first ? block.b.map { marksB[$0] } : [],
                                scriptVariant: first && block.a.contains(where: variantLinesA.contains)))
            }
            nextA = block.a.upperBound + 1
            nextB = block.b.upperBound + 1
        }
        out += pairGap(candidate: candidate, current: current,
                       candidateRange: nextA..<candidate.count, currentRange: nextB..<current.count)
        return out
    }

    private static func deltaMs(_ x: Line, _ y: Line) -> Int? {
        guard let tx = x.timeMs, let ty = y.timeMs, abs(tx - ty) > retimeThresholdMs else { return nil }
        return tx - ty
    }

    /// 两块之间两边剩下的句子(一个字也没连上):按时间先后合并,时间挨得近的一对当成改了字,对不上的字单独比一遍
    /// 标出来;没有时间戳的按先后配。
    private static func pairGap(candidate: [Line], current: [Line],
                                candidateRange: Range<Int>, currentRange: Range<Int>) -> [Pair] {
        var out: [Pair] = []
        var i = candidateRange.lowerBound, j = currentRange.lowerBound
        func changedPair() {
            let (marksA, marksB) = lineMarks(candidate[i].text, current[j].text)
            out.append(Pair(candidate: i, current: [j], kind: .changed, deltaMs: deltaMs(candidate[i], current[j]),
                            candidateMarks: marksA, currentMarks: [marksB]))
            i += 1
            j += 1
        }
        while i < candidateRange.upperBound || j < currentRange.upperBound {
            guard i < candidateRange.upperBound else {
                out.append(Pair(candidate: nil, current: [j], kind: .onlyCurrent))
                j += 1
                continue
            }
            guard j < currentRange.upperBound else {
                out.append(Pair(candidate: i, current: [], kind: .onlyCandidate))
                i += 1
                continue
            }
            guard let ti = candidate[i].timeMs, let tj = current[j].timeMs else {
                changedPair()
                continue
            }
            if abs(ti - tj) <= substitutionWindowMs {
                changedPair()
            } else if ti < tj {
                out.append(Pair(candidate: i, current: [], kind: .onlyCandidate))
                i += 1
            } else {
                out.append(Pair(candidate: nil, current: [j], kind: .onlyCurrent))
                j += 1
            }
        }
        return out
    }

    /// 单独两句之间对不上的字。
    private static func lineMarks(_ a: String, _ b: String) -> (Set<Int>, Set<Int>) {
        let ta = tokens([Line(timeMs: nil, text: a)])
        let tb = tokens([Line(timeMs: nil, text: b)])
        let matches = matchedPairs(ta.map(\.key), tb.map(\.key))
        let matchedA = Set(matches.map(\.0))
        let matchedB = Set(matches.map(\.1))
        return (Set(ta.indices.filter { !matchedA.contains($0) }.map { ta[$0].offset }),
                Set(tb.indices.filter { !matchedB.contains($0) }.map { tb[$0].offset }))
    }
}
