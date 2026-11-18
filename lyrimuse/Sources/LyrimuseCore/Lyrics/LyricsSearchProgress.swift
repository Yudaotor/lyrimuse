import Foundation

/// 「搜索候选歌词」表头那一行进度由哪几句组成,App 按顺序换成文案、用「 · 」连起来。
/// 第一轮:有源给了结果说「N 个源已有结果」,跟右边徽标「有结果的源 / 总数」的分子是同一个数;第二轮起(引擎的兜底轮
/// 换个写法把开着的源重扫一遍)说「第 N 轮：换个写法再搜」;这一轮还有源没回来时接「还有 N 个源在搜」,
/// 都回来了不写 0。见 11 章决策 185。
public enum LyricsSearchProgress {
    public enum Part: Equatable, Sendable {
        /// 还不知道一共几个源,或者什么都还没得说:「正在查询各个歌词源…」。
        case querying
        /// 给过候选的联网歌词源有几个。
        case responded(Int)
        /// 第几轮(≥ 2)。
        case retrying(round: Int)
        /// 这一轮还有几个源没回来。
        case waiting(Int)
    }

    /// - Parameters:
    ///   - responded: 给过候选的联网歌词源数(徽标的分子)。
    ///   - done: 这一轮已经回来的源数(引擎报的 sourcesDone,每轮从 0 数)。
    ///   - total: 这一轮一共几个源(引擎报的 sourcesTotal);0 = 还没收到第一行。
    ///   - round: 第几轮,从 1 起。
    public static func parts(responded: Int, done: Int, total: Int, round: Int) -> [Part] {
        guard total > 0 else { return [.querying] }
        var parts: [Part] = []
        if round >= 2 {
            parts.append(.retrying(round: round))
        } else if responded > 0 {
            parts.append(.responded(responded))
        }
        let left = total - done
        if left > 0 { parts.append(.waiting(left)) }
        return parts.isEmpty ? [.querying] : parts
    }
}
