import Foundation

/// Discord 资料卡上「当前歌词」那一行挑哪一句。Discord 最多每 `DiscordPresenceGate.minInterval` 收一次,大半句子比这短,
/// 到点挑「接下来这一段里唱得最久的那句」,比挑「此刻这一句」跟得更齐(见 12 章决策 65)。纯函数,时刻都在歌词时间轴上。
public enum DiscordLyricLine {
    /// 一句从开始唱到唱完(毫秒,歌词时间轴)。
    public struct Span: Equatable, Sendable {
        public var startMs: Int
        public var endMs: Int
        public var text: String

        public init(startMs: Int, endMs: Int, text: String) {
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
        }
    }

    /// 每句唱到哪:下一句开始、或者这一句后面的间奏开始(`gapStarts`:句号 → 间奏起点),取早的那个;最后一句没有间奏时到
    /// 整首结束,不知道整首多长时按 `lastLineMs` 算。只有空白的句子不要。`starts` 与 `texts` 一一对应,按时间排好。
    public static func spans(starts: [Int], texts: [String], gapStarts: [Int: Int], trackDurationMs: Int?,
                             lastLineMs: Int = 5_000) -> [Span] {
        var result: [Span] = []
        for index in starts.indices where index < texts.count {
            let text = texts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = starts[index]
            var end = index + 1 < starts.count ? starts[index + 1] : (trackDurationMs ?? start + lastLineMs)
            if let gap = gapStarts[index], gap > start { end = min(end, gap) }
            guard end > start else { continue }
            result.append(Span(startMs: start, endMs: end, text: text))
        }
        return result
    }

    /// 从 `atMs` 起 `windowMs` 这一段里唱得最久的那句;一样久挑先唱的。唱的时间不到 `minOverlapMs`、句子本身又没整句落在
    /// 这一段里的不算 —— 间奏快结束时不提前好几秒亮出下一句。没有一句算数时为 nil(间奏里、唱完了)。
    public static func pick(_ spans: [Span], atMs: Int, windowMs: Int, minOverlapMs: Int = 1_000) -> String? {
        let windowEnd = atMs + windowMs
        var best: (text: String, overlap: Int)?
        for span in spans {
            if span.startMs >= windowEnd { break }
            let overlap = min(span.endMs, windowEnd) - max(span.startMs, atMs)
            guard overlap > 0 else { continue }
            let whole = span.startMs >= atMs && span.endMs <= windowEnd
            guard overlap >= minOverlapMs || whole else { continue }
            if overlap > (best?.overlap ?? 0) { best = (span.text, overlap) }
        }
        return best?.text
    }

    /// `pick` 的结论从 `atMs` 往后多少毫秒第一次变:按 `stepMs` 往前试,最多看 `horizonMs`,一直不变为 nil。资料卡要跟着
    /// 换句时用它排下一次该看的时刻,不用每半秒醒一次(句子几十条、`pick` 遇到窗口外的就停,试一遍是微秒级)。
    /// 见 12 章决策 81。
    public static func nextChangeMs(_ spans: [Span], atMs: Int, windowMs: Int, stepMs: Int = 100,
                                    horizonMs: Int = 10_000, minOverlapMs: Int = 1_000) -> Int? {
        guard stepMs > 0 else { return nil }
        let now = pick(spans, atMs: atMs, windowMs: windowMs, minOverlapMs: minOverlapMs)
        var delta = stepMs
        while delta <= horizonMs {
            if pick(spans, atMs: atMs + delta, windowMs: windowMs, minOverlapMs: minOverlapMs) != now { return delta }
            delta += stepMs
        }
        return nil
    }
}
