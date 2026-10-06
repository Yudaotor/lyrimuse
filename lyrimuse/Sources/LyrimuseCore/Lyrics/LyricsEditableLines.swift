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

    /// 跟 `base` 比,哪几行改过(时间戳或文字有一样不同)。行数不同时,多出来的行也算改过。
    public func changedIndices(from base: LyricsEditableLines) -> [Int] {
        var out: [Int] = []
        for index in lines.indices {
            if !base.lines.indices.contains(index) || base.lines[index] != lines[index] { out.append(index) }
        }
        return out
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
