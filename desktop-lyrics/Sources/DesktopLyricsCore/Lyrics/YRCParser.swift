import Foundation

public struct LyricWord: Equatable {
    public let startMs: Int
    public let durationMs: Int
    public let text: String
    public init(startMs: Int, durationMs: Int, text: String) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.text = text
    }
}

public struct LyricLineWords: Equatable {
    public let timeMs: Int
    public let words: [LyricWord]
    public init(timeMs: Int, words: [LyricWord]) {
        self.timeMs = timeMs
        self.words = words
    }
}

// 网易云逐字 yrc 解析,算法照抄 web/index.html 的 parseYRC():每行 [行始ms,行长ms] 后跟
// 若干 (词始ms,词长ms,0)文字;跳过没有任何非空词的行(NetEase 会吐一些零宽标记行)。
public enum YRCParser {
    private static let headRegex = try! NSRegularExpression(pattern: #"^\[(\d+),\d+\]"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^(]*)"#)

    public static func parse(_ text: String) -> [LyricLineWords] {
        var out: [LyricLineWords] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            guard let head = headRegex.firstMatch(in: line, range: fullRange) else { continue }
            let lineTimeMs = Int(nsLine.substring(with: head.range(at: 1))) ?? 0
            var words: [LyricWord] = []
            for m in wordRegex.matches(in: line, range: fullRange) {
                let wordText = nsLine.substring(with: m.range(at: 3))
                if wordText.isEmpty { continue }
                let start = Int(nsLine.substring(with: m.range(at: 1))) ?? 0
                let dur = Int(nsLine.substring(with: m.range(at: 2))) ?? 0
                words.append(LyricWord(startMs: start, durationMs: dur, text: wordText))
            }
            if !words.isEmpty { out.append(LyricLineWords(timeMs: lineTimeMs, words: words)) }
        }
        return out.sorted { $0.timeMs < $1.timeMs }
    }
}
