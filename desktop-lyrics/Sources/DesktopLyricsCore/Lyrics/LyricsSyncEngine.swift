import Foundation

public struct SyncedLyricWord: Equatable {
    public let text: String
    public let fillFraction: Double // 0...1,驱动逐字渐变填色
}

public struct SyncedLyricLine: Equatable {
    public let romanization: String?
    public let translation: String?
    public let mainText: String?         // 整行高亮时用(没有逐字数据)
    public let words: [SyncedLyricWord]? // 逐字高亮时用(有 yrc 数据)
}

// 按当前歌曲的四个歌词字段选基准 + 按外推位置算当前应该展示哪一行,算法照抄
// web/index.html 的 setLyrics()/syncLyrics():有 yrc(逐字)优先用,否则退化到 lyrics
// 整行;roma/tr 各自独立解析、用 700ms 容差的最近邻匹配贴到对应原文行。
public final class LyricsSyncEngine {
    private var baseLines: [LyricLine] = []
    private var wordLines: [LyricLineWords] = []
    private var romaLines: [LyricLine] = []
    private var trLines: [LyricLine] = []
    private var usingWords = false

    public init() {}

    public func load(lyrics: String, lyricsTr: String, lyricsRoma: String, lyricsYRC: String, preferWordLevel: Bool = true) {
        let yrc = preferWordLevel ? YRCParser.parse(lyricsYRC) : []
        usingWords = !yrc.isEmpty
        wordLines = yrc
        baseLines = usingWords ? [] : LRCParser.parse(lyrics)
        romaLines = LRCParser.parse(lyricsRoma)
        trLines = LRCParser.parse(lyricsTr)
    }

    public var hasContent: Bool { usingWords ? !wordLines.isEmpty : !baseLines.isEmpty }

    private func nearestText(_ arr: [LyricLine], _ t: Int, tolerance: Int = 700) -> String? {
        var best: String?
        var bestDiff = tolerance
        for it in arr {
            let d = abs(it.timeMs - t)
            if d <= bestDiff { bestDiff = d; best = it.text }
        }
        return best
    }

    public func activeLine(atMs posMs: Int) -> SyncedLyricLine? {
        if usingWords {
            var idx = -1
            for (i, ln) in wordLines.enumerated() where ln.timeMs <= posMs { idx = i }
            guard idx >= 0 else { return nil }
            let ln = wordLines[idx]
            let words = ln.words.map { w -> SyncedLyricWord in
                var f = w.durationMs > 0 ? Double(posMs - w.startMs) / Double(w.durationMs) : (posMs >= w.startMs ? 1 : 0)
                f = min(1, max(0, f))
                return SyncedLyricWord(text: w.text, fillFraction: f)
            }
            return SyncedLyricLine(
                romanization: nearestText(romaLines, ln.timeMs),
                translation: nearestText(trLines, ln.timeMs),
                mainText: nil,
                words: words
            )
        }
        var idx = -1
        for (i, ln) in baseLines.enumerated() where ln.timeMs <= posMs { idx = i }
        guard idx >= 0 else { return nil }
        let ln = baseLines[idx]
        return SyncedLyricLine(
            romanization: nearestText(romaLines, ln.timeMs),
            translation: nearestText(trLines, ln.timeMs),
            mainText: ln.text,
            words: nil
        )
    }
}
