import Foundation

/// 「歌词管理」逐句编辑用的一份正文:按行拆成「行首时间戳 + 文字」,改一句只换那一句的文字或时间戳。
///
/// 拼回去时没改的行原样不动:一个字都没改时 `joined` 跟传进来的正文逐字节相同,`LyricsBodyEdit.reassembled`
/// 据此返回原文,脏判定和单曲偏移的内容指纹都不受影响。正文取的是编辑框那一份(`LyricsBodyEdit.body`;逐字歌词是
/// `LyricsWordTimingEdit.editableText` 摘掉署名之后的那份),元信息标签和署名行不在里面。
public struct LyricsEditableLines: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// 行首的时间戳,一个或几个连写(`[00:12.34][01:20.00]`),原样;没有时间戳时为空。
        public let stamps: String
        /// 时间戳后面的文字,原样(含行尾空白)。
        public let text: String

        public init(stamps: String, text: String) {
            self.stamps = stamps
            self.text = text
        }

        /// 第一个时间戳的毫秒数;没有时间戳为 nil。
        public var timeMs: Int? { LyricsEditableLines.firstStampMs(stamps) }

        /// 空行(段落之间的分隔):没有时间戳、文字只有空白。
        public var isBlank: Bool { stamps.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public let lines: [Line]

    public init(body: String) {
        lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { Self.parse(String($0)) }
    }

    public init(lines: [Line]) {
        self.lines = lines
    }

    /// 按 `\n` 拼回去的正文。
    public var joined: String {
        lines.map { $0.stamps + $0.text }.joined(separator: "\n")
    }

    /// 换掉第 `index` 行的时间戳或文字(传 nil 的那一样不动);下标越界时原样返回。
    public func replacing(_ index: Int, stamps: String? = nil, text: String? = nil) -> LyricsEditableLines {
        guard lines.indices.contains(index) else { return self }
        var copy = lines
        copy[index] = Line(stamps: stamps ?? copy[index].stamps, text: text ?? copy[index].text)
        return LyricsEditableLines(lines: copy)
    }

    /// 时间对得上的那一行,给译文、读音挂到正文那一句下面用:先找第一个时间戳毫秒数相同的,
    /// 没有再找差不到 `toleranceMs` 的最近一行。
    public func index(matching timeMs: Int, toleranceMs: Int = 50) -> Int? {
        if let exact = lines.firstIndex(where: { $0.timeMs == timeMs }) { return exact }
        var best: (index: Int, distance: Int)?
        for (index, line) in lines.enumerated() {
            guard let t = line.timeMs else { continue }
            let distance = abs(t - timeMs)
            guard distance <= toleranceMs else { continue }
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    /// 跟 `base`(打开编辑时那份)比,哪几行改过或是新加的。按 `alignment(to:)` 对行,不按下标。
    public func changedIndices(from base: LyricsEditableLines) -> [Int] {
        let map = alignment(to: base)
        return lines.indices.filter { index in map[index].map { base.lines[$0] != lines[index] } ?? true }
    }

    /// 跟 `base` 比改了几句:改过的、新加的、删掉的各算一句。
    public func changeCount(from base: LyricsEditableLines) -> Int {
        let map = alignment(to: base)
        let removed = base.lines.count - map.compactMap { $0 }.count
        return removed + lines.indices.filter { index in map[index].map { base.lines[$0] != lines[index] } ?? true }.count
    }

    /// 每一行对应 `base` 的第几行,nil = 新加的行。整行(时间戳 + 文字)相同的按最长公共子序列先对上,两段对上的行之间
    /// 剩下的按先后一一配对(改过的那几句),多出来的是新加的。别按下标对:整段文本里增删过一行,后面每一句都会被当成
    /// 改过,「还原」也会还原到别的句子上(见 11 章决策 92)。两份都很长、格子数超过 `alignmentCellLimit` 时退回按下标对。
    public func alignment(to base: LyricsEditableLines) -> [Int?] {
        let a = lines
        let b = base.lines
        let n = a.count
        let m = b.count
        guard n * m <= Self.alignmentCellLimit else { return a.indices.map { $0 < m ? $0 : nil } }
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out = [Int?](repeating: nil, count: n)
        var gapA: [Int] = []
        var gapB: [Int] = []
        func pairGap() {
            for (ai, bi) in zip(gapA, gapB) { out[ai] = bi }
            gapA.removeAll()
            gapB.removeAll()
        }
        var i = 0
        var j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                pairGap()
                out[i] = j
                i += 1
                j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                gapB.append(j)
                j += 1
            } else {
                gapA.append(i)
                i += 1
            }
        }
        pairGap()
        return out
    }

    static let alignmentCellLimit = 250_000

    /// 去掉第 `index` 行(「还原」一句打开编辑之后新加的行);下标越界时原样返回。
    public func removing(_ index: Int) -> LyricsEditableLines {
        guard lines.indices.contains(index) else { return self }
        var copy = lines
        copy.remove(at: index)
        return LyricsEditableLines(lines: copy)
    }

    /// 一段文字是不是只由一个或几个时间戳连写而成(编辑时间戳时校验输入用)。
    public static func isValidStamps(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return parse(text).stamps == text
    }

    /// 时间戳写法:`[mm:ss.xx]`(百分之一秒),跟歌词文件里的一样。
    public static func stamp(ms: Int) -> String {
        "[" + LyricsPreviewText.timeLabel(ms) + "]"
    }

    static func parse(_ raw: String) -> Line {
        var rest = Substring(raw)
        var stampEnd = rest.startIndex
        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            guard stampInnerMs(inner) != nil else { break }
            stampEnd = rest.index(after: close)
            rest = rest[stampEnd...]
        }
        return Line(stamps: String(raw[raw.startIndex..<stampEnd]), text: String(rest))
    }

    public static func firstStampMs(_ stamps: String) -> Int? {
        guard stamps.first == "[", let close = stamps.firstIndex(of: "]") else { return nil }
        return stampInnerMs(stamps[stamps.index(after: stamps.startIndex)..<close])
    }

    /// `mm:ss`、`mm:ss.x`～`mm:ss.xxx`、`mm:ss:xx` 这几种写法的毫秒数;不是时间戳为 nil。
    private static func stampInnerMs(_ inner: Substring) -> Int? {
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let minutes = digits(parts[0], maxCount: 3) else { return nil }
        var secondsPart = parts[1]
        var fraction: Substring = ""
        if parts.count == 3 {
            fraction = parts[2]
        } else if let dot = secondsPart.firstIndex(of: ".") {
            fraction = secondsPart[secondsPart.index(after: dot)...]
            secondsPart = secondsPart[..<dot]
        }
        guard let seconds = digits(secondsPart, maxCount: 2), seconds < 60 else { return nil }
        var ms = minutes * 60_000 + seconds * 1000
        if parts.count == 3 || inner.contains(".") {
            guard let value = digits(fraction, maxCount: 3) else { return nil }
            switch fraction.count {
            case 1: ms += value * 100
            case 2: ms += value * 10
            default: ms += value
            }
        }
        return ms
    }

    private static func digits(_ s: Substring, maxCount: Int) -> Int? {
        guard !s.isEmpty, s.count <= maxCount, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }
}
