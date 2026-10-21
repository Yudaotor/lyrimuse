import Foundation

// 「解析决策」面板的三件分析:判词 / 差值分解 / 共有项 —— 全是纯函数,不碰 IO、不认 SwiftUI,因此 selftest 直接覆盖得到。
//
// 界面不照搬引擎的数据结构(候选数组、每条带一个打分项数组):打分明细摊开后很长,大量行在每条候选上一模一样,
// 冠亚分差又常常只差在一两项上。所以分三层:判词回答「为什么是它」、差值分解回答「其它几个差在哪」、共有项把每条
// 候选上都一样的项折成一行说一次。统计数据见 11 章决策 24。
//
// 判词不做归因:多数对局的分差是七八项的合力,没有单一维度能解释,硬写一句"胜者凭什么赢"就是编。判词只说可以直接
// 量出来的三件事:是不是同一份词(consensus 项)、差多少(相减)、有没有吃到否决性负分。差在多项上时 separator 就是
// `.multiple`,不挑一项出来当理由。

/// 一个打分项的「kind + 分值」。绝对分解里 points 是原始分值,差值分解里是**差值**。
public struct LyricsScoreTermValue: Sendable, Equatable, Identifiable {
    public var id: String { kind }
    /// 跟引擎 match.go 的 scoreTerm kind 一一对应;中文译名在 App 侧
    /// `LyricsSearchService.ScoreTerm.label`(Core 不做本地化)。
    public let kind: String
    public let points: Int

    public init(kind: String, points: Int) {
        self.kind = kind
        self.points = points
    }
}

/// 一条候选在存档里的样子 —— 只留这三件分析用得到的字段。App 侧把
/// `LyricsResolutionDecision.Candidate` 映射成它(跟 `LyricQueryRound` 同一个做法:
/// Core 不认 App 的解码模型,App 也不把分析逻辑写进 View)。
public struct LyricsScoredCandidate: Sendable, Equatable {
    public let source: String
    public let score: Int
    public let terms: [LyricsScoreTermValue]
    /// 存档里的 `instrumental`。老存档没有这个字段 → nil。
    public let instrumental: Bool?
    /// 存档里的 `consensus_peers`。老存档没有 → 空。
    public let consensusPeers: [String]
    /// 存档里的 `track_found_no_lyrics`。老存档没有 → nil。
    public let trackFoundNoLyrics: Bool?

    public init(source: String, score: Int, terms: [LyricsScoreTermValue],
                instrumental: Bool? = nil, consensusPeers: [String] = [], trackFoundNoLyrics: Bool? = nil) {
        self.source = source
        self.score = score
        self.terms = terms
        self.instrumental = instrumental
        self.consensusPeers = consensusPeers
        self.trackFoundNoLyrics = trackFoundNoLyrics
    }

    /// 引擎塞的「这首本来就没有词」信号 —— 不是候选,见 `LyricsDecisionRow` 头注。
    public var isInstrumentalMarker: Bool {
        LyricsDecisionRow.isInstrumentalMarker(instrumental: instrumental, score: score)
    }

    /// 被判不可用(首项 kind 以 `reject` 开头)。这类候选存档里 score 恒为 -1 ——
    /// 那个 -1 是内部手段不是评价,界面不该印它(全库 604 行 / 301 个条目)。
    public var isRejected: Bool { terms.first?.kind.hasPrefix("reject") ?? false }

    /// 「曲库里有这首歌、平台上没有歌词文本」的信号(引擎塞的 -1 分伪候选),也不是候选。存档没写这个字段的老记录
    /// 按形状认:负分、一个打分项都没有、又不是纯音乐标记(被拒的候选总带着那条 reject 项)。
    public var isNoLyricsMarker: Bool {
        if trackFoundNoLyrics == true { return true }
        return score < 0 && terms.isEmpty && instrumental != true
    }

    /// 真正参与比分的候选。判词和差值分解都只看这些。
    public var isContender: Bool { !isInstrumentalMarker && !isRejected && !isNoLyricsMarker }

    /// 分项之和。
    public var rawTermSum: Int { terms.reduce(0) { $0 + $1.points } }

    /// 分项之和跟总分对不上时给出那个和,对得上是 nil。
    ///
    /// 引擎在 `match.go` 里把负分**统一夹到 1**(注释原话:重扣表达「差」不是「不能用」)。
    /// 于是全库 **644 行(3.74%)、443 份存档(10%)** 的分项之和 ≠ 总分 —— 面板会印出
    /// 「总分 1」后面跟一串加起来是 −353 的项,谁真去加一遍都会以为界面算错了。
    /// 差值分解必须显式交代这一条,否则逐项差值加起来对不上总分差。
    public var clampedRawSum: Int? { rawTermSum == score ? nil : rawTermSum }
}

// MARK: - 判词

/// 冠亚之间「差在哪」的形状。只在**能一句话说清**时才细分,说不清就是 `.multiple`。
public enum LyricsVerdictSeparator: Sendable, Equatable {
    /// 冠亚的打分项**完全相同**(kind 与分值都一样)—— 真平局,先后由引擎的
    /// 稳定排序按构造顺序决定。全库 134 场。
    case identical
    /// 只差在这一项上。`points` = 冠军 − 亚军(正数 = 冠军在这一项上多拿)。
    /// 全库分差 ≤1 的 1011 场里有 789 场(78%)属于这一类,且几乎全是「行数」。
    case single(LyricsScoreTermValue)
    /// 差在多项上 —— **不挑一项出来当理由**(那就是被否掉的归因)。
    case multiple
}

/// 一句坐得实的判词。命不中任何一类就是 nil,界面整块不渲染
/// (跟「只有首轮一组时不显示查询词摘要」是同一个规矩)。
///
/// 对全库 4426 份存档按**本文件的实际判据**跑出来的覆盖率:
///   · `.sameLyrics` 3320 份(75.0%,其中 1534 份 nearTie)
///   · `.tooClose`    235 份(5.3%)
///   · `.decisiveNegative` 80 份(1.8%)
///   · nil            791 份(17.9%:504 份无判词 + 287 份独苗/无对局)
/// 命中判词时 separator 的分布:multiple 2129 · single 1372 · identical 134。
public enum LyricsVerdict: Sendable, Equatable {
    /// 参赛的 N 条候选**内容一致**(每一条都拿到了 consensus 项)——
    /// 也就是说分差比的是包装(有没有逐字轴、有没有译文),不是内容。
    case sameLyrics(contenders: Int, gap: Int, gapPercent: Double?, nearTie: Bool,
                    separator: LyricsVerdictSeparator)
    /// 亚军吃了冠军没有的**否决性负分**,且其绝对值 ≥ 分差 —— 这一项自己就够定胜负。
    case decisiveNegative(term: LyricsScoreTermValue, loser: String, gap: Int)
    /// 分差极小,但**不是每条候选**都拿到了内容印证。
    ///
    /// 带上 contenders / corroborated 两个计数,是因为只说「不是每条候选都有印证」时,
    /// 读的人眼睛正盯着冠亚两行,很容易读成"这两份不是同一份词"——而它们往往恰恰是
    /// 同一份(实测:陶喆《说走就走》冠亚都有 +150 印证,没有的是第三名)。给出数字就不会误读。
    case tooClose(contenders: Int, corroborated: Int, gap: Int, gapPercent: Double?,
                  separator: LyricsVerdictSeparator)
}

public enum LyricsVerdictBuilder {
    /// 「否决性负分」认哪几个 kind —— 它们表达的是「这个候选**配错了**」(版本不符、
    /// 时长对不上、挂在另一场演出上),不是「它稍微差一点」。`reject*` 不在此列:
    /// 那些候选压根不参赛(isContender == false)。跟引擎 match.go 的负分项对齐,
    /// 那边新增负分项时这里要跟着补 —— 漏补只是少一类判词,不会出错。
    public static let vetoKinds: Set<String> = [
        "versionTags", "durationOff", "durationOvershoot",
        "sourceDurationOff", "liveAlbumConflict", "wordTimingOverride", "timelineOffset",
        "timelineIntrusion", "sourceDurationNearMiss",
    ]

    /// 「接近平分」的判据:分差 ≤1 分,或不到冠军分的 1%。
    /// 两条都要 —— 低分局(冠军 200 分)里 1% 还不到 2 分,高分局(冠军 1200)里 1% 是 12 分,
    /// 只用相对值会把低分局的真实差距说成打平,只用绝对值会把高分局的微弱差距说成有差距。
    public static func isNearTie(gap: Int, championScore: Int) -> Bool {
        if gap <= 1 { return true }
        guard championScore > 0 else { return false }
        return Double(gap) * 100 / Double(championScore) < 1
    }

    /// 参赛候选按分数降序。不参赛的(纯音乐标记 / 被拒)不在内。
    ///
    /// 传了 winner 时**冠军排第一**:同分的两条按源名定序有可能把没戴皇冠的排在前面
    /// (实测:方大同《1234567》酷狗与 QQ 同为 1219 分,存档里的 winner 是 QQ,按源名却是
    /// 酷狗在前)——列表第一行不是胜者,读起来像出了错。采用的不是最高分那条(匹配算法选「顺序优先」、
    /// 或最高分那条吃了版本 / 曲长扣分)时同样把它提到第一。
    public static func ranked(_ candidates: [LyricsScoredCandidate],
                              winner: String? = nil) -> [LyricsScoredCandidate] {
        // 同分时按 source 定序 —— 存档里的数组顺序是引擎的构造顺序,稳定,
        // 但这里再排一次必须自己保证稳定,否则同分的两条在界面上的先后会飘。
        let order = candidates.filter(\.isContender)
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.source < $1.source }
        guard let winner, let idx = order.firstIndex(where: { $0.source == winner }), idx != 0
        else { return order }
        var moved = order
        moved.insert(moved.remove(at: idx), at: 0)
        return moved
    }

    /// 谁是冠军。存档里的 `winner` **是**当时真正被采用的那一条,只要它参赛就认它,哪怕不是最高分(顺序优先、
    /// 最高分那条吃了扣分):皇冠得戴在详情页「选用 X」的那条上。不是最高分时判词整块不出(`build` 返回 nil),
    /// 界面另说一句(`isOutscored`)。存档里没有 `winner` 或它不在参赛候选里时退回分数最高的那条。
    /// 存档里没有 `winner`、又有一条纯音乐标记时没有冠军:
    /// 那一轮按纯音乐处理,一条都没采用(播放器自己说是纯音乐时,分数再高也不用),别把最高分那条说成胜者。
    ///
    /// 判词和候选表**必须**用同一个判据,所以抽成公共函数:两处各写一份迟早漂开,
    /// 而漂开的后果是界面上戴皇冠的那条跟判词里说的"胜者"不是同一个。
    public static func champion(among candidates: [LyricsScoredCandidate],
                                winner: String?) -> LyricsScoredCandidate? {
        if (winner ?? "").isEmpty, candidates.contains(where: \.isInstrumentalMarker) {
            return nil
        }
        let order = ranked(candidates)
        guard let top = order.first else { return nil }
        return order.first { $0.source == winner } ?? top
    }

    /// 采用的那条(冠军)分数比别的参赛候选低:界面说一句「采用的不是得分最高的那条」,判词不出。
    public static func isOutscored(among candidates: [LyricsScoredCandidate], winner: String?) -> Bool {
        guard let champion = champion(among: candidates, winner: winner) else { return false }
        return candidates.contains { $0.isContender && $0.source != champion.source && $0.score > champion.score }
    }

    public static func build(candidates: [LyricsScoredCandidate], winner: String?) -> LyricsVerdict? {
        let contenders = ranked(candidates)
        guard contenders.count >= 2,
              let champion = champion(among: candidates, winner: winner),
              let runnerUp = contenders.first(where: { $0.source != champion.source }),
              champion.score >= runnerUp.score
        else { return nil }

        let gap = champion.score - runnerUp.score
        let gapPercent: Double? = champion.score > 0
            ? Double(gap) * 100 / Double(champion.score) : nil
        let nearTie = isNearTie(gap: gap, championScore: champion.score)
        let sep = separator(champion: champion, runnerUp: runnerUp)

        // ② 否决性负分优先 —— 它比「接近平分」更具体,而且这两类几乎不会同时命中
        //    (吃了 600 分负分还能打平的对局极罕见)。
        let championTerms = Dictionary(champion.terms.map { ($0.kind, $0.points) },
                                       uniquingKeysWith: { a, _ in a })
        let veto = runnerUp.terms
            .filter {
                vetoKinds.contains($0.kind) && $0.points < 0
                    && (championTerms[$0.kind] ?? 0) >= 0 && abs($0.points) >= gap
            }
            // 多项都够格时取绝对值最大的那一项;绝对值相同时取 kind 字典序在前的
            // —— 不定序的话同分的两项谁被选中取决于数组顺序,输出会飘。
            .max { a, b in
                a.points.magnitude != b.points.magnitude
                    ? a.points.magnitude < b.points.magnitude
                    : a.kind > b.kind
            }
        if let veto {
            return .decisiveNegative(term: veto, loser: runnerUp.source, gap: gap)
        }

        // ① 全员内容一致 —— 每条参赛候选都拿到了 consensus 项。
        // 判的是「有没有这一项」,不是「分值多少」:2 家以上 250、1 家 150,
        //    两档都算「有别的源印证」。老存档同样有这一项,所以这条判词不依赖 V2 新加的
        //    consensus_peers 字段(那个只有新存档才有)。
        if contenders.allSatisfy({ c in c.terms.contains { $0.kind == "consensus" } }) {
            return .sameLyrics(contenders: contenders.count, gap: gap, gapPercent: gapPercent,
                               nearTie: nearTie, separator: sep)
        }
        // ③ 只剩「差得极少」这一件可说的。
        if nearTie {
            let corroborated = contenders.filter { c in
                c.terms.contains { $0.kind == "consensus" }
            }.count
            return .tooClose(contenders: contenders.count, corroborated: corroborated,
                             gap: gap, gapPercent: gapPercent, separator: sep)
        }
        return nil
    }

    static func separator(champion: LyricsScoredCandidate,
                          runnerUp: LyricsScoredCandidate) -> LyricsVerdictSeparator {
        let diffs = termDiffs(of: champion, against: runnerUp)
        if diffs.isEmpty { return .identical }
        if diffs.count == 1 { return .single(diffs[0]) }
        return .multiple
    }
}

// MARK: - 差值分解

/// 一条落选候选**相对冠军**的差值分解。
///
/// 主张:落选的候选,用户不关心它得了多少,只关心它**差在哪**。「行数 −1」比
/// 「+400 / +250 / +164 / +51 / +50 / +30」有用得多,而且相同的项自动不出现
/// (差值为 0)——那正是实测那 32% 冗余的来源。
public struct LyricsScoreDelta: Sendable, Equatable, Identifiable {
    public var id: String { source }
    public let source: String
    /// 相对冠军的总分差(负数 = 落后)。用**存档里的总分**相减,不是分项和相减 ——
    /// 两者在被夹过分的那 3.74% 上不相等,而用户在界面上看到的分数是前者。
    public let scoreGap: Int
    /// 逐项差值(自己 − 冠军),按绝对值从大到小;差值为 0 的项不列。
    public let terms: [LyricsScoreTermValue]
    /// 非 nil 时:这条候选的分项之和被夹到过最低分,于是上面的逐项差值加起来
    /// **对不上** scoreGap。界面必须把这个原始和说出来,不能让人以为算错了。
    public let clampedRawSum: Int?

    public init(source: String, scoreGap: Int, terms: [LyricsScoreTermValue],
                clampedRawSum: Int?) {
        self.source = source
        self.scoreGap = scoreGap
        self.terms = terms
        self.clampedRawSum = clampedRawSum
    }
}

extension LyricsVerdictBuilder {
    /// `lhs` 相对 `rhs` 的逐项差值,按绝对值从大到小;为 0 的项不列。
    /// 绝对值相同时按 kind 字典序 —— 不这么定序的话 Set 的遍历顺序会让输出每次不同。
    static func termDiffs(of lhs: LyricsScoredCandidate,
                          against rhs: LyricsScoredCandidate) -> [LyricsScoreTermValue] {
        let a = Dictionary(lhs.terms.map { ($0.kind, $0.points) }, uniquingKeysWith: { x, _ in x })
        let b = Dictionary(rhs.terms.map { ($0.kind, $0.points) }, uniquingKeysWith: { x, _ in x })
        return Set(a.keys).union(b.keys)
            .map { LyricsScoreTermValue(kind: $0, points: (a[$0] ?? 0) - (b[$0] ?? 0)) }
            .filter { $0.points != 0 }
            .sorted { a, b in
                a.points.magnitude != b.points.magnitude
                    ? a.points.magnitude > b.points.magnitude
                    : a.kind < b.kind
            }
    }

    /// 落选候选相对冠军的差值分解。顺序沿用传进来的顺序(界面按分数降序传)。
    public static func deltas(champion: LyricsScoredCandidate,
                             others: [LyricsScoredCandidate]) -> [LyricsScoreDelta] {
        others.map { other in
            LyricsScoreDelta(source: other.source,
                             scoreGap: other.score - champion.score,
                             terms: termDiffs(of: other, against: champion),
                             clampedRawSum: other.clampedRawSum)
        }
    }

    /// 每条参赛候选上 **kind 与分值都相同** 的项 —— 它们在差值分解里全是 0,
    /// 折成一行说一次就够(实测:打分项种类的共有率中位 71%,完全相同的行占 32%)。
    ///
    /// 顺序沿用**第一条**候选里的出现顺序:那是引擎的打分顺序,本身有含义
    /// (先算时长、再算逐字、最后算增值内容),按分值重排反而读着乱。
    public static func sharedTerms(among candidates: [LyricsScoredCandidate]) -> [LyricsScoreTermValue] {
        let contenders = candidates.filter(\.isContender)
        guard let first = contenders.first, contenders.count >= 2 else { return [] }
        let rest = contenders.dropFirst().map {
            Set($0.terms.map { "\($0.kind)\u{1F}\($0.points)" })
        }
        return first.terms.filter { t in
            let key = "\(t.kind)\u{1F}\(t.points)"
            return rest.allSatisfy { $0.contains(key) }
        }
    }
}
