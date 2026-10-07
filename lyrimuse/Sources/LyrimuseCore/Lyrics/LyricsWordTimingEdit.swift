import Foundation

/// 逐字歌词「只改字」(11 章决策 52)。
///
/// 编辑框里摊开的是逐字拼出来的每一行:行首 `[mm:ss.xx]` + 这一行的字,跟各处显示的一样(`editableText`)。改完用 `apply`
/// 套回逐字:
/// - 时间戳没动、字改了的行:每个词原来的起点和时长都不动,改过的字按位置归到原来的词里(`changedLines`);
/// - 新加的行、改了时间戳的行:没有原来的时间可留,这一行的时长按字数均分(`estimatedLines`);
/// - 删掉的行跟着删(`removedLines`);没有时间戳的歌词行不进逐字(`skippedLines`,`[ti:]` 这类文件头不算)。
///
/// 没动过的行、逐字以外的行(`[ti:]` 这类文件头)逐字节原样,行的先后不变,新行按时间插进去。整行歌词里时间差不超过 10ms、
/// 原文(只比字母和数字)也对得上的行跟着换字、跟着删,新行按时间插进去;对不上的行不动(网易云的整行歌词常带署名行,
/// 跟逐字本来就不是一套)。
public enum LyricsWordTimingEdit {
    public struct Result: Equatable, Sendable {
        public let yrc: String
        public let lrc: String
        public let changedLines: Int
        public let estimatedLines: Int
        public let removedLines: Int
        public let skippedLines: Int

        /// 每一行的时间都没动,只改了字。
        public var timingUnchanged: Bool { estimatedLines == 0 && removedLines == 0 }
    }

    /// 这份逐字里有没有能摊开编辑的行。
    public static func hasWordLines(_ yrc: String) -> Bool {
        !wordLines(rawLines(yrc)).isEmpty
    }

    /// 编辑框里摊开的文本:每个逐字行一行,`[mm:ss.xx]` + 这一行的字。
    public static func editableText(yrc: String) -> String {
        wordLines(rawLines(yrc)).map { stamp($0.startMs) + $0.text }.joined(separator: "\n")
    }

    /// 两份行级歌词按行序的时间戳一样:只改了字。
    public static func sameLineTimes(_ a: String, _ b: String) -> Bool {
        rawLines(a).compactMap { leadingStamps($0)?.times } == rawLines(b).compactMap { leadingStamps($0)?.times }
    }

    /// 把编辑后的文本套回逐字 `yrc`,整行歌词 `lrc` 跟着改。编辑后的文本跟 `editableText(yrc:)` 一样时两份原样返回。
    public static func apply(edited: String, yrc: String, lrc: String) -> Result {
        let raw = rawLines(yrc)
        let old = wordLines(raw)
        var skipped = 0
        var edits: [EditedLine] = []
        for line in rawLines(edited) {
            let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard let stamps = leadingStamps(text) else {
                if !text.trimmingCharacters(in: .whitespaces).isEmpty, !isHeaderTag(text) { skipped += 1 }
                continue
            }
            edits.append(EditedLine(ms: stamps.times[0], text: String(text[stamps.end...])))
        }

        // 时间戳(按显示的精度)和字都一样的行没动,行尾空白不算(编辑器存盘时常顺手删掉,屏幕上看不出来);时间戳一样、
        // 字不一样的配成改字;剩下的新行估时间,剩下的旧行删掉。
        var used = [Bool](repeating: false, count: old.count)
        var plan = [Plan?](repeating: nil, count: edits.count)
        var exact: [String: [Int]] = [:]
        for (i, o) in old.enumerated() { exact[stamp(o.startMs) + "\u{1}" + trimmingTrailingWhitespace(o.text), default: []].append(i) }
        for (j, e) in edits.enumerated() {
            let k = stamp(e.ms) + "\u{1}" + trimmingTrailingWhitespace(e.text)
            if let i = exact[k]?.first {
                exact[k]?.removeFirst()
                used[i] = true
                plan[j] = .keep(i)
            }
        }
        var byStamp: [String: [Int]] = [:]
        for (i, o) in old.enumerated() where !used[i] { byStamp[stamp(o.startMs), default: []].append(i) }
        for (j, e) in edits.enumerated() where plan[j] == nil {
            let s = stamp(e.ms)
            if let i = byStamp[s]?.first {
                byStamp[s]?.removeFirst()
                used[i] = true
                plan[j] = .retext(i)
            }
        }

        var lines: [Slot] = raw.map { Slot(raw: $0, startMs: nil) }
        for o in old { lines[o.rawIndex].startMs = o.startMs }
        let crlf = yrc.contains("\r\n")
        var changed = 0, estimated = 0, removed = 0
        var lrcEdits: [LRCEdit] = []
        for (i, o) in old.enumerated() where !used[i] {
            lines[o.rawIndex].removed = true
            removed += 1
            lrcEdits.append(.remove(ms: o.startMs, text: o.text))
        }
        var inserts: [(ms: Int, text: String)] = []
        for (j, e) in edits.enumerated() {
            switch plan[j] {
            case .keep?:
                continue
            case let .retext(i)?:
                let o = old[i]
                if isBlank(e.text) {
                    lines[o.rawIndex].removed = true
                    removed += 1
                    lrcEdits.append(.remove(ms: o.startMs, text: o.text))
                } else {
                    lines[o.rawIndex].raw = retokenized(o, to: e.text) + (crlf ? "\r" : "")
                    changed += 1
                    lrcEdits.append(.retext(ms: o.startMs, old: o.text, new: e.text))
                }
            case nil:
                guard !isBlank(e.text) else { continue }
                inserts.append((e.ms, e.text))
                estimated += 1
                lrcEdits.append(.insert(ms: e.ms, text: e.text))
            }
        }
        guard changed + estimated + removed > 0 else {
            return Result(yrc: yrc, lrc: lrc, changedLines: 0, estimatedLines: 0, removedLines: 0, skippedLines: skipped)
        }

        var kept = lines.filter { !$0.removed }
        for ins in inserts.sorted(by: { $0.ms < $1.ms }) {
            kept.insert(Slot(raw: "", startMs: ins.ms, pendingText: ins.text), at: insertionIndex(kept, ms: ins.ms))
        }
        for k in kept.indices where kept[k].pendingText != nil {
            let next = kept[(k + 1)...].first(where: { $0.startMs != nil })?.startMs
            kept[k].raw = synthesized(ms: kept[k].startMs ?? 0, text: kept[k].pendingText ?? "", nextStart: next) + (crlf ? "\r" : "")
        }
        return Result(
            yrc: kept.map(\.raw).joined(separator: "\n"), lrc: mirrored(lrc, lrcEdits),
            changedLines: changed, estimatedLines: estimated, removedLines: removed, skippedLines: skipped)
    }

    // MARK: - 逐字行

    private struct WordLine {
        let rawIndex: Int
        let startMs: Int
        let durationMs: Int
        let words: [LyricWord]
        var text: String { words.map(\.text).joined() }
    }

    private struct EditedLine {
        let ms: Int
        let text: String
    }

    private enum Plan {
        case keep(Int)
        case retext(Int)
    }

    private struct Slot {
        var raw: String
        var startMs: Int?
        var pendingText: String?
        var removed = false

        init(raw: String, startMs: Int?, pendingText: String? = nil) {
            self.raw = raw
            self.startMs = startMs
            self.pendingText = pendingText
        }
    }

    /// 按 `\n` 切,行尾的 `\r` 留在行里(CRLF 的文件没动的行原样写回)。
    private static func rawLines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// 每一行按显示时的同一套切法(YRCParser)解析;解析不出词的行不算逐字行。
    private static func wordLines(_ raw: [String]) -> [WordLine] {
        raw.enumerated().compactMap { i, line in
            guard line.hasPrefix("["), let parsed = YRCParser.parse(line).first else { return nil }
            let end = parsed.words.map { $0.startMs + $0.durationMs }.max() ?? parsed.timeMs
            return WordLine(rawIndex: i, startMs: parsed.timeMs, durationMs: parsed.durationMs ?? max(0, end - parsed.timeMs),
                            words: parsed.words)
        }
    }

    /// 新行插在时间不晚于它的最后一个逐字行后面;一个都没有就插在第一个逐字行前面,再没有就接在最后。
    private static func insertionIndex(_ slots: [Slot], ms: Int) -> Int {
        if let last = slots.lastIndex(where: { ($0.startMs ?? .max) <= ms }) { return last + 1 }
        return slots.firstIndex(where: { $0.startMs != nil }) ?? slots.count
    }

    /// 改了字的行:行头和每个词的时间原样,字按原文到新文的逐字对齐归到原来的词里。纯插入的字并进前一个字所在的词;
    /// 在行首、或者贴着后一个词开头插进来(前面是空白、自己不以空白结尾,"not here" 改成 "not there")就并进后一个;
    /// 一段被替换掉的字,新字按原来那几个词各占的字数比例分回去,不拆开拉丁词;分不到字的词去掉。
    private static func retokenized(_ line: WordLine, to newText: String) -> String {
        var oldChars: [Character] = []
        var owner: [Int] = []
        for (w, word) in line.words.enumerated() {
            for c in word.text {
                oldChars.append(c)
                owner.append(w)
            }
        }
        let newChars = Array(newText)
        var assigned = [String](repeating: "", count: line.words.count)
        var previous: Int?
        var lastKept: Character?
        var deleted: [Int] = []
        var inserted: [Int] = []
        func flush(next: Int?) {
            defer { deleted.removeAll(); inserted.removeAll() }
            guard !inserted.isEmpty else { return }
            let text = String(inserted.map { newChars[$0] })
            if deleted.isEmpty {
                if let next, lastKept?.isWhitespace == true, text.last?.isWhitespace == false {
                    assigned[next] += text
                } else {
                    assigned[previous ?? next ?? 0] += text
                }
            } else {
                distribute(text, over: deleted.map { owner[$0] }, into: &assigned)
            }
        }
        for op in alignment(oldChars, newChars) {
            switch op {
            case let .equal(i, j):
                flush(next: owner[i])
                assigned[owner[i]].append(newChars[j])
                previous = owner[i]
                lastKept = newChars[j]
            case let .delete(i):
                deleted.append(i)
            case let .insert(j):
                inserted.append(j)
            }
        }
        flush(next: nil)
        var out = "[\(line.startMs),\(line.durationMs)]"
        for (w, word) in line.words.enumerated() where !assigned[w].isEmpty {
            out += "(\(word.startMs),\(word.durationMs),0)\(assigned[w])"
        }
        return out
    }

    /// 一段替换进来的字分回原来那几个词:按各词被替换掉的字数占比,按字 / 词为单位顺序分,不拆开拉丁词。
    private static func distribute(_ text: String, over owners: [Int], into assigned: inout [String]) {
        var counts: [(word: Int, n: Int)] = []
        for w in owners {
            if counts.last?.word == w { counts[counts.count - 1].n += 1 } else { counts.append((w, 1)) }
        }
        let pieces = units(text)
        let totalOld = Double(owners.count)
        let totalNew = Double(max(1, pieces.reduce(0) { $0 + $1.count }))
        var ends: [Double] = []
        var acc = 0
        for c in counts {
            acc += c.n
            ends.append(Double(acc) / totalOld)
        }
        var before = 0
        var k = 0
        for piece in pieces {
            let mid = (Double(before) + Double(piece.count) / 2) / totalNew
            while k < counts.count - 1, ends[k] < mid { k += 1 }
            assigned[counts[k].word] += piece
            before += piece.count
        }
    }

    /// 新加的行:时长按字数估(每个字 / 词 350ms,0.8~8 秒),不超过下一行开始;均分给每个字 / 词。
    private static func synthesized(ms: Int, text: String, nextStart: Int?) -> String {
        let pieces = units(text)
        var duration = min(max(pieces.count * 350, 800), 8000)
        if let next = nextStart, next > ms { duration = min(duration, next - ms) }
        duration = max(duration, pieces.count)
        var out = "[\(ms),\(duration)]"
        var t = ms
        for (k, piece) in pieces.enumerated() {
            let end = ms + duration * (k + 1) / pieces.count
            out += "(\(t),\(end - t),0)\(piece)"
            t = end
        }
        return out
    }

    /// 切成逐字的「字 / 词」:中日韩的字一个一个算,连着的拉丁字母 / 数字算一个词,空白和标点挂在前一个上(行首的挂在后一个上)。
    static func units(_ text: String) -> [String] {
        var out: [String] = []
        var pending = ""
        var latinOpen = false
        for c in text {
            if isCJK(c) {
                out.append(pending + String(c))
                pending = ""
                latinOpen = false
            } else if c.isLetter || c.isNumber {
                if latinOpen, !out.isEmpty {
                    out[out.count - 1].append(c)
                } else {
                    out.append(pending + String(c))
                    pending = ""
                }
                latinOpen = true
            } else {
                if out.isEmpty { pending.append(c) } else { out[out.count - 1].append(c) }
                latinOpen = false
            }
        }
        if !pending.isEmpty { out.append(pending) }
        return out
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF, 0xFF66...0xFF9F, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private enum Op {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// 最长公共子序列对齐;一行太长(格数超过上限)就当整行替换。
    private static func alignment(_ a: [Character], _ b: [Character]) -> [Op] {
        let n = a.count, m = b.count
        guard n * m <= 1_000_000 else {
            return (0..<n).map { .delete($0) } + (0..<m).map { .insert($0) }
        }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                ops.append(.equal(i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.delete(i))
                i += 1
            } else {
                ops.append(.insert(j))
                j += 1
            }
        }
        ops.append(contentsOf: (i..<n).map { .delete($0) })
        ops.append(contentsOf: (j..<m).map { .insert($0) })
        return ops
    }

    // MARK: - 时间戳

    private static let stampRegex = try! NSRegularExpression(pattern: #"^\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

    private static let headerTagRegex = try! NSRegularExpression(
        pattern: #"^\s*\[(ti|ar|al|au|by|re|ve|length|offset|id|la|lr|tool|#)\s*:[^\]]*\]\s*$"#, options: [.caseInsensitive])

    /// `[ti:…]` / `[offset:…]` 这类文件头标签行。
    static func isHeaderTag(_ line: String) -> Bool {
        headerTagRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// 行首连着的 `[mm:ss.xx]`:各自的毫秒和正文开始的位置;行首不是时间戳返回 nil。
    static func leadingStamps(_ line: String) -> (times: [Int], end: String.Index)? {
        var times: [Int] = []
        var rest = Substring(line)
        while let m = stampRegex.firstMatch(in: String(rest), range: NSRange(location: 0, length: (String(rest) as NSString).length)) {
            let s = String(rest) as NSString
            // 分钟的位数不限的话,十几位的分钟数乘上去整数溢出、直接崩。歌词里没有上千分钟的时间戳,到这儿就当正文。
            guard let minutes = Int(s.substring(with: m.range(at: 1))), minutes < 1000 else { break }
            let seconds = Int(s.substring(with: m.range(at: 2))) ?? 0
            var frac = m.range(at: 3).location == NSNotFound ? "" : s.substring(with: m.range(at: 3))
            while frac.count < 3 { frac += "0" }
            times.append((minutes * 60 + seconds) * 1000 + (Int(frac) ?? 0))
            guard let r = Range(m.range, in: String(rest)) else { break }
            rest = rest.dropFirst(String(rest)[r].count)
        }
        guard !times.isEmpty else { return nil }
        return (times, rest.startIndex)
    }

    /// 去掉行尾的空白(空格、制表符、`\r`、全角空格这类)。
    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }

    /// 跟导出口径一样的 `[mm:ss.xx]`。
    static func stamp(_ ms: Int) -> String {
        let v = max(0, ms)
        return String(format: "[%02d:%02d.%02d]", v / 60_000, (v % 60_000) / 1000, (v % 1000) / 10)
    }

    // MARK: - 整行歌词

    private enum LRCEdit {
        case retext(ms: Int, old: String, new: String)
        case remove(ms: Int, text: String)
        case insert(ms: Int, text: String)
    }

    /// 整行歌词跟着逐字改:只动单个时间戳、时间差不超过 10ms、原文对得上的行;新行按时间插进去(整行歌词里一行时间戳都没有就不插)。
    private static func mirrored(_ lrc: String, _ edits: [LRCEdit]) -> String {
        guard !lrc.isEmpty, !edits.isEmpty else { return lrc }
        let crlf = lrc.contains("\r\n")
        var lines = rawLines(lrc)
        var removed = Set<Int>()
        func match(_ ms: Int, _ text: String) -> Int? {
            let key = normalized(text)
            return lines.indices.first { i in
                guard !removed.contains(i) else { return false }
                let line = lines[i].hasSuffix("\r") ? String(lines[i].dropLast()) : lines[i]
                guard let stamps = leadingStamps(line), stamps.times.count == 1, abs(stamps.times[0] - ms) <= 10 else { return false }
                return normalized(String(line[stamps.end...])) == key
            }
        }
        var inserts: [(ms: Int, text: String)] = []
        for edit in edits {
            switch edit {
            case let .retext(ms, old, new):
                guard let i = match(ms, old) else { continue }
                let line = lines[i].hasSuffix("\r") ? String(lines[i].dropLast()) : lines[i]
                guard let stamps = leadingStamps(line) else { continue }
                lines[i] = String(line[..<stamps.end]) + new + (lines[i].hasSuffix("\r") ? "\r" : "")
            case let .remove(ms, text):
                if let i = match(ms, text) { removed.insert(i) }
            case let .insert(ms, text):
                inserts.append((ms, text))
            }
        }
        var out: [(raw: String, ms: Int?)] = lines.indices.filter { !removed.contains($0) }.map { i in
            let line = lines[i].hasSuffix("\r") ? String(lines[i].dropLast()) : lines[i]
            return (lines[i], leadingStamps(line)?.times.first)
        }
        if out.contains(where: { $0.ms != nil }) {
            for ins in inserts.sorted(by: { $0.ms < $1.ms }) {
                let at = out.lastIndex(where: { ($0.ms ?? .max) <= ins.ms }).map { $0 + 1 }
                    ?? out.firstIndex(where: { $0.ms != nil }) ?? out.count
                out.insert((stamp(ins.ms) + ins.text + (crlf ? "\r" : ""), ins.ms), at: at)
            }
        }
        return out.map(\.raw).joined(separator: "\n")
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 配对整行歌词用:只留字母和数字,不分大小写。
    private static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
