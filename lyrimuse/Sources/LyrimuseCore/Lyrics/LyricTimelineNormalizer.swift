import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-timeline")

/// 逐字时间轴的**合法性归一化**:把各家歌词源给出的、跟行时间轴对不上的字级时间戳修成
/// 引擎能正确显示的形态,修不了的整行退化成"均匀扫过",文字一个不动。纯数值,`lyrimuse-selftest`
/// 钉住每条规则。
///
/// ## 为什么以「下一行的起点」为边界,而不是 `[行始,行长]` 里的行长
///
/// 引擎从来不看 YRC 行头里的行长(YRCParser 只取行始):一行的可见窗口就是**到下一行开始为止**,
/// `KaraokeFill.tailClamped` 也是按下一行起点压最后一个字。所以"字起点落在下一行开始之后"
/// 才是这里真正要治的病——那个字永远不会在自己那一行里被看见填色。
///
/// ## 2026-09-02 全库实测(3071 首带逐字 / 161,723 行 / 118.8 万字)
///
///   * 字起点 ≥ 下一行起点:**4516 字 / 422 首**——中位 0ms(网易云行尾标点 token 起点正好等于
///     下一行、时长 0)、p90 62ms、p99 1.9s;酷狗/QQ 的形态是最后一个真词晚了 50~300ms,正是
///     用户见到的「最后一点不走完就下一句」;amll 有整行错位一秒以上的。≤250ms 的占 4351。
///   * 字起点早于本行行首:27 字 / 8 首,中位 109ms;≤250ms 的 22 个,另 5 个差几秒到 153 秒。
///   * 字起点倒退:21 字 / 12 首(某个字的起点被写成 0 或行首)。
///   * 字终点晚于声明行尾 2155 字、与前一字重叠 1604 字——中位都是 1ms 的取整误差,而且在
///     "不看行长"的模型里无害,**不处理**。
///
/// `maxClampMs = 250`:p90 是 62ms、p99 是 1.9s,250 落在两者之间的空档——盖住 96% 的越界,又
/// 不会把整行错位一秒以上的坏数据硬夹进去(那种只能退化)。
///
/// ## 三条规则(顺序即代码顺序)
///
///   1. 字起点比前一个字**倒退** → 整行退化(乱序的行没有可信的字级时间轴)。
///   2. 字起点**早于行首**:差 ≤250ms 夹到行首、终点不动;超过 → 整行退化。
///   3. 字起点**不早于下一行起点**:差 ≤250ms 就拉到「下一行起点 − tailWindowMs」(换行提前量
///      140ms + 最短填色 120ms,见 KaraokeFill),终点不动,让它在换行前那 260ms 里能被看见填完;
///      超过 → 整行退化。拉的时候不越过前一个字的起点、不早于行首。相邻两行时间戳相同(对唱/
///      重复行)时没有可用边界,这条不判。
///
/// 退化 = 这一行只剩一个覆盖全部文字的字,从行首扫到下一行开始(没有下一行就到原来最后一个字
/// 的终点)。选"均匀扫过"而不是"整行高亮":同一首歌里其它行还在逐字,突然一行不动比匀速扫过
/// 更像坏了。
public enum LyricTimelineNormalizer {
    public static let maxClampMs = 250

    /// 越过下一行起点的字被拉回到换行前这么多毫秒。跟 KaraokeFill 的两个常数绑定,别单独改。
    public static var tailWindowMs: Int { KaraokeFill.lineTailLeadMs + KaraokeFill.minTailFillMs }

    public enum DegradeReason: String, CaseIterable {
        case wordStartDecreased = "word_start_decreased"
        case wordBeforeLine = "word_before_line"
        case wordAfterNextLine = "word_after_next_line"
    }

    public struct Report: Equatable {
        public var clampedToLineStart = 0
        public var clampedBeforeNextLine = 0
        public var degradedLines: [DegradeReason: Int] = [:]
        public init() {}
        public var degradedLineCount: Int { degradedLines.values.reduce(0, +) }
        public var isEmpty: Bool {
            clampedToLineStart == 0 && clampedBeforeNextLine == 0 && degradedLines.isEmpty
        }
    }

    /// `lines` 必须已按 timeMs 升序(YRCParser.parse 的输出就是)。
    public static func normalize(_ lines: [LyricLineWords]) -> (lines: [LyricLineWords], report: Report) {
        var report = Report()
        var out: [LyricLineWords] = []
        out.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            // 相邻行同一时间戳 → 没有可用的下一行边界(对唱两声部 / 重复行都会这样)。
            var nextStart: Int? = nil
            if i + 1 < lines.count, lines[i + 1].timeMs > line.timeMs {
                nextStart = lines[i + 1].timeMs
            }
            var words: [LyricWord] = []
            words.reserveCapacity(line.words.count)
            var previousStart: Int? = nil
            var degrade: DegradeReason? = nil
            for w in line.words {
                var start = w.startMs
                let end = w.startMs + max(0, w.durationMs)
                if let previousStart, start < previousStart {
                    degrade = .wordStartDecreased
                    break
                }
                if start < line.timeMs {
                    if line.timeMs - start <= maxClampMs {
                        start = line.timeMs
                        report.clampedToLineStart += 1
                    } else {
                        degrade = .wordBeforeLine
                        break
                    }
                }
                if let nextStart, start >= nextStart {
                    if start - nextStart <= maxClampMs {
                        start = max(line.timeMs, previousStart ?? line.timeMs, nextStart - tailWindowMs)
                        report.clampedBeforeNextLine += 1
                    } else {
                        degrade = .wordAfterNextLine
                        break
                    }
                }
                words.append(LyricWord(startMs: start, durationMs: max(0, end - start), text: w.text))
                previousStart = start
            }
            if let degrade {
                report.degradedLines[degrade, default: 0] += 1
                out.append(degraded(line, nextStart: nextStart))
            } else {
                out.append(LyricLineWords(timeMs: line.timeMs, words: words))
            }
        }
        return (out, report)
    }

    static func degraded(_ line: LyricLineWords, nextStart: Int?) -> LyricLineWords {
        let text = line.words.map(\.text).joined()
        let originalEnd = line.words.map { $0.startMs + max(0, $0.durationMs) }.max() ?? line.timeMs
        let end = nextStart ?? originalEnd
        return LyricLineWords(
            timeMs: line.timeMs,
            words: [LyricWord(startMs: line.timeMs, durationMs: max(0, end - line.timeMs), text: text)])
    }

    /// 每次加载只记一行汇总,不逐行打——全库 2.8% 的行会被夹,逐行打就是噪音。
    public static func logSummary(_ report: Report, track: String) {
        guard !report.isEmpty else { return }
        let reasons = report.degradedLines
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
        logger.info("word timeline normalized track=\(track, privacy: .public) clamped_to_line_start=\(report.clampedToLineStart) clamped_before_next_line=\(report.clampedBeforeNextLine) degraded_lines=\(report.degradedLineCount) reasons=\(reasons, privacy: .public)")
    }
}
