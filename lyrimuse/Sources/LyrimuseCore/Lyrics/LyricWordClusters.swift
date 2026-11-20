import Foundation

/// 逐字词的边界对齐到字素簇(用户看到的一个字,Swift 的 `Character`)。
///
/// 有的歌词源按码位切逐字:天城文「पा」切成「प」「ा」、泰文「ค่」切成「ค」「่」、带组合重音的拉丁字母、希伯来文点符、
/// emoji 的 ZWJ 序列、分解形式的谚文都会被拆开。各展示面每个逐字词单独排字,一个词开头是组合符号时系统字体找不到
/// 基字,补一个虚线圈「◌」占位,还把它当成一个字占宽。这里把开头接着上一个词末字的那几个码位并回上一个词。
/// 见 08 章决策 73。
public enum LyricWordClusters {
    /// 每一行各自对齐,行与行之间不并。
    public static func merging(_ lines: [LyricLineWords]) -> [LyricLineWords] {
        lines.map { line in
            guard line.words.count > 1 else { return line }
            let merged = merging(line.words)
            return merged == line.words
                ? line
                : LyricLineWords(timeMs: line.timeMs, words: merged, durationMs: line.durationMs)
        }
    }

    /// 一个词开头的字跟上一个词的末字合成同一个字素簇时,把这几个码位挪到上一个词末尾;挪完这个词空了就整个并掉,
    /// 上一个词的终点延到它的终点。起点不动,没被并掉的词时间不动。行首的词前面没有可并的词,原样留着。
    public static func merging(_ words: [LyricWord]) -> [LyricWord] {
        guard words.count > 1 else { return words }
        var out: [LyricWord] = []
        out.reserveCapacity(words.count)
        for word in words {
            guard let previous = out.last, let tail = previous.text.last, !word.text.isEmpty else {
                out.append(word)
                continue
            }
            let (moved, rest) = continuation(of: tail, in: word.text)
            if moved.isEmpty {
                out.append(word)
                continue
            }
            var end = previous.startMs + previous.durationMs
            if rest.isEmpty { end = max(end, word.startMs + word.durationMs) }
            out[out.count - 1] = LyricWord(startMs: previous.startMs, durationMs: end - previous.startMs,
                                           text: previous.text + moved)
            if !rest.isEmpty {
                out.append(LyricWord(startMs: word.startMs, durationMs: word.durationMs, text: rest))
            }
        }
        return out
    }

    /// `text` 开头有多少码位跟 `tail` 连成同一个字素簇:返回这一截和剩下的部分。按 `Character` 的切法逐个码位试,
    /// 组合符号、ZWJ 序列、谚文字母、国旗两个区域指示符都是同一个判据。
    static func continuation(of tail: Character, in text: String) -> (moved: String, rest: String) {
        let scalars = Array(text.unicodeScalars)
        var cluster = String(tail)
        var taken = 0
        for scalar in scalars {
            let candidate = cluster + String(Character(scalar))
            guard candidate.count == 1 else { break }
            cluster = candidate
            taken += 1
        }
        guard taken > 0 else { return ("", text) }
        var moved = String.UnicodeScalarView(), rest = String.UnicodeScalarView()
        moved.append(contentsOf: scalars[..<taken])
        rest.append(contentsOf: scalars[taken...])
        return (String(moved), String(rest))
    }
}
