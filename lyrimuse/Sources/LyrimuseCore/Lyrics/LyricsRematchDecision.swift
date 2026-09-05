import Foundation

/// 「重新自动匹配」跑完一轮之后**要不要采纳**、以及该跟用户说什么 —— 纯判定,不碰 IO。
///
/// 抽进 Core 的理由跟这个仓库其它几处一样(AGENTS.md 的分层约定):这里面五条分支各自只在
/// 特定的一轮搜索结果下才成立(当前源恰好超时、全源全废、这一轮没有逐字、冠军跟现状一模
/// 一样、正常换源),混在 View 里除了反复点按钮碰运气以外没有别的验证办法。而其中两条
/// (不可判、逐字保护)恰恰是**不该动**的分支 —— 它们没被触发时的表现是"用户看得见的东西
/// 被悄悄弄没了",不是报错。
public enum LyricsRematchDecision {
    public enum Outcome: Equatable {
        /// 采纳冠军。
        case adopt
        /// 别动,因为当前生效的那个源这一轮没应答(它可能本来就是最优的,只是这次超时了 ——
        /// 拿一次偶发的部分应答去换,就是降级)。复刻 collector 的 rescoreDecidable。
        case keptNotDecidable
        /// 别动,因为一个能用的候选都没有。自动路径此时也是一个字都不写。
        case keptNoCandidate
        /// 别动,因为现有的这份有逐字时间轴、而这一轮的冠军没有。复刻 collector 的
        /// needsLyricsRetry 里那道"已经有逐字就别乱动"的闸:逐字是这套打分里最值钱的东西
        /// (+400),但它取决于这一轮那个源有没有把逐字接口给全 —— 实测同一首歌上一轮拿到
        /// 6887 字节 YRC、下一轮五个源一个逐字都没有。这种情况下换过去是把用户看得见的
        /// 卡拉OK填色弄丢,而且不可逆。想强制换有「联网搜索候选歌词」那条明确的手动路径。
        case keptWouldLoseWordTiming
        /// 冠军跟现状完全一样(同源、正文和逐字都没变):什么都不用写,如实说"没有更好的"。
        case unchanged
    }

    /// - decidable: collector 给的 `pick.decidable`。
    /// - winnerSource: 冠军的源;空串 = 一个能用的候选都没有(**不许**退回"取第一条",那会把
    ///   一份明确被判废的歌词写进去)。
    /// - currentHasWordTiming / winnerHasWordTiming: 现有的这份、以及冠军,各自有没有逐字。
    /// - sameSource / sameLyrics / sameWordTiming: 冠军跟现状是否逐项一致。
    public static func decide(decidable: Bool,
                             winnerSource: String,
                             currentHasWordTiming: Bool,
                             winnerHasWordTiming: Bool,
                             sameSource: Bool,
                             sameLyrics: Bool,
                             sameWordTiming: Bool) -> Outcome {
        // 顺序要紧:先问"这一轮的结论算不算数",再问"有没有东西可采纳",最后才比内容。
        guard decidable else { return .keptNotDecidable }
        guard !winnerSource.isEmpty else { return .keptNoCandidate }
        if currentHasWordTiming && !winnerHasWordTiming { return .keptWouldLoseWordTiming }
        if sameSource && sameLyrics && sameWordTiming { return .unchanged }
        return .adopt
    }
}
