import Foundation

/// 逐字词的边界对齐到字素簇(用户看到的一个字,Swift 的 `Character`)。
///
/// 有的歌词源按码位切逐字:天城文「पा」切成「प」「ा」、泰文「ค่」切成「ค」「่」、带组合重音的拉丁字母、希伯来文点符、
/// emoji 的 ZWJ 序列、分解形式的谚文都会被拆开。各展示面每个逐字词单独排字,一个词开头是组合符号时系统字体找不到
/// 基字,补一个虚线圈「◌」占位,还把它当成一个字占宽。这里把开头接着上一个词末字的那几个码位并回上一个词。
/// 见 08 章决策 73。
public enum LyricWordClusters {
    /// 每一行各自对齐,行与行之间不并(跨行的见 `mergingLineStarts`)。
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

    /// 一行开头的码位跟上一行的末字合成同一个字素簇时(歌词源把行切在一个字中间),把这几个码位挪到上一行最后一个词末尾。
    /// 挪走的是整个词时,上一行最后一个词的终点延到这个词的终点,但不越过这一行的行头;一行挪完只剩空白就整行并掉,
    /// 终点不越过再下一行的行头。行头时间、其余词的时间不动。第一行、上一行以空白结尾的不挪:空白加组合符号
    /// 虽然算一个字素簇,却不是那个字。换行本身就是词界,只挪本身不能起头的码位(`cannotStartCluster`),
    /// virama 后面接的辅音不挪。见 08 章决策 74、75。
    public static func mergingLineStarts(_ lines: [LyricLineWords]) -> [LyricLineWords] {
        guard lines.count > 1 else { return lines }
        var out: [LyricLineWords] = []
        out.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            guard let previous = out.last, let tailWord = previous.words.last,
                  let tail = tailWord.text.last, !tail.isWhitespace else {
                out.append(line)
                continue
            }
            var words = line.words
            var cluster = tail
            var movedText = ""
            var movedEndMs: Int?
            while let first = words.first {
                let (moved, rest) = continuation(of: cluster, in: first.text, marksOnly: true)
                guard !moved.isEmpty else { break }
                movedText += moved
                cluster = Character(String(cluster) + moved)
                if rest.isEmpty {
                    movedEndMs = first.startMs + first.durationMs
                    words.removeFirst()
                    continue
                }
                words[0] = LyricWord(startMs: first.startMs, durationMs: first.durationMs, text: rest)
                break
            }
            guard !movedText.isEmpty else {
                out.append(line)
                continue
            }
            let emptied = words.allSatisfy { $0.text.allSatisfy(\.isWhitespace) }
            let limitMs = emptied ? (index + 1 < lines.count ? lines[index + 1].timeMs : nil) : line.timeMs
            var endMs = tailWord.startMs + tailWord.durationMs
            if let movedEndMs { endMs = max(endMs, min(movedEndMs, limitMs ?? movedEndMs)) }
            var previousWords = previous.words
            previousWords[previousWords.count - 1] = LyricWord(
                startMs: tailWord.startMs, durationMs: endMs - tailWord.startMs, text: tailWord.text + movedText)
            out[out.count - 1] = LyricLineWords(timeMs: previous.timeMs, words: previousWords, durationMs: previous.durationMs)
            if !emptied {
                out.append(LyricLineWords(timeMs: line.timeMs, words: words, durationMs: line.durationMs))
            }
        }
        return out
    }

    /// 整行歌词的同一条:行首接着上一行末字的码位挪到上一行末尾,挪完只剩空白的行并掉。规则同上一个重载。
    public static func mergingLineStarts(_ lines: [LyricLine]) -> [LyricLine] {
        guard lines.count > 1 else { return lines }
        var out: [LyricLine] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            guard let previous = out.last, let tail = previous.text.last, !tail.isWhitespace else {
                out.append(line)
                continue
            }
            let (moved, rest) = continuation(of: tail, in: line.text, marksOnly: true)
            guard !moved.isEmpty else {
                out.append(line)
                continue
            }
            out[out.count - 1] = LyricLine(timeMs: previous.timeMs, text: previous.text + moved)
            if !rest.allSatisfy(\.isWhitespace) { out.append(LyricLine(timeMs: line.timeMs, text: rest)) }
        }
        return out
    }

    /// `text` 开头有多少码位跟 `tail` 连成同一个字素簇:返回这一截和剩下的部分。按 `Character` 的切法逐个码位试,
    /// 组合符号、ZWJ 序列、谚文字母、国旗两个区域指示符都是同一个判据。`marksOnly` 时只挪 `cannotStartCluster`
    /// 的码位,遇到能起头的(字母、emoji、区域指示符)就停,哪怕它按运行时的 Unicode 版本跟 `tail` 连成一个簇。
    static func continuation(of tail: Character, in text: String, marksOnly: Bool = false) -> (moved: String, rest: String) {
        let scalars = Array(text.unicodeScalars)
        var cluster = String(tail)
        var taken = 0
        for scalar in scalars {
            if marksOnly && !cannotStartCluster(scalar) { break }
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

    /// 本身不能起头、只能接在前一个码位后面的码位:Grapheme_Cluster_Break 为 Extend、SpacingMark、ZWJ 的
    /// (组合符号、泰文 ำ、半角浊点、emoji 肤色)。按码位属性判,不随运行时的 Unicode 版本变:辅音 + virama + 辅音
    /// 算一个簇(GB9c)只有 Unicode 15.1 起的运行时才这样切。
    public static func cannotStartCluster(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isGraphemeExtend || properties.isEmojiModifier || properties.generalCategory == .spacingMark {
            return true
        }
        switch scalar.value {
        case 0x200D, 0x0E33, 0x0EB3: return true
        default: return false
        }
    }
}
