import Foundation

/// 一次 `track.getinfo` 之后,「第 N 次听」这一格该怎么记账(2026-09-10)。
///
/// **为什么要有这个三态、而不是原来那个 if/else**(用户报「为什么这三个 lastfm 里面没有播放次数」,
/// 现场坐实):原来的判据是
///
///     if let n, n > 0 { 记数 } else if 请求成功, 行够老 { 记进"那边没有"名单 }
///
/// 而 `n` 是 `(dig(json,"track","userplaycount") as? String).flatMap { Int($0) }` —— 它对
/// **两件完全不同的事**都产出 nil:
///
///   - 那边明确回答"0 次"(响应里 `userplaycount: "0"`)—— 这是一个**答案**;
///   - 响应 200、track 对象正常、但**压根没带 `userplaycount` 这个字段** —— 这是"这次没答上来"。
///
/// 后者被当成前者,于是 Last.fm 的一次抖动会被写成定论。2026-09-10 实测的现场:10:56:00 那一批
/// 20 首里 17 首正常,`prince|1999` / `prince|little red corvette` /
/// `prince & the revolution|kiss (extended)` 三首同时"没有次数",日志里那一批**全是 200、
/// 一条 api error 都没有**;5 分钟后拿同样的参数直接问,三首分别是 18 / 20 / 1 次,而
/// `user.getTrackScrobbles` 显示这些收听最早可追到 2026-07-07 —— 既不是"那边真没有",也不是
/// 已知的"刚 scrobble 完还没并账"(那个由 `rowIsOldEnough` 挡)。Last.fm 的按用户计数是另一次
/// 后端查询,高并发下会静默缺字段,而 App 刚重启时一口气打二十几个 getinfo 正好撞上。
///
/// 代价是"字段缺失"这一档从此**不进**「那边没有」名单、也不落盘,下一轮照常重问 —— 这正是它
/// 该有的行为:进了名单的行连 `···` 占位都不画(见 `PlayCountBadge`),看起来就是"这行天生没有
/// 次数",而实际上只要一次重问就能拿到。
///
/// ⚠️ **error 6(Track not found)仍然是定论**。调用方在那条路上传 `reportedCount: 0`:
/// Last.fm 说"压根没有这个实体"跟它说"0 次"是同一个答案,不能跟"没答上来"混在一起 ——
/// 否则本机那 7 首有声书章节(Last.fm 确实没有)会每轮重问、永不收敛,那正是 2026-09-03
/// 引入 `notFound` 要解决的问题。
///
/// 纯函数,selftest 覆盖(`LastfmTests.swift`「次数记账三态」)。
public enum PlayCountOutcome: Equatable {
    /// 拿到正数,直接记进次数表。
    case counted(Int)
    /// 那边明确没有(回答 0 次,或 error 6 说压根没这个实体),且这一行够老 ——
    /// 可以记进「那边没有」名单,按 `PlayCountUnavailableBackoff` 退避重探。
    case definitivelyNone
    /// 这次没答上来(请求失败 / 成功但没带 `userplaycount` / 行还太新,0 不算数)——
    /// 什么都别记,留给下一轮。
    case unanswered

    /// - Parameters:
    ///   - requestSucceeded: 请求本身成不成功。超时/限流是 false;error 6 算 true
    ///     (那是一个明确答案,见头注)。
    ///   - reportedCount: 响应里**真的带回来**的 `userplaycount`;没带这个字段就传 nil。
    ///     ⚠️ 别把"没带字段"折成 0 传进来 —— 那就是本次修复要消掉的那个混淆。
    ///   - rowIsOldEnough: 这一行的 scrobble 是否已经超过宽限期
    ///     (`LastfmStatsService.playCountZeroGraceSecs`,15 分钟)。刚 scrobble 完拿到 0
    ///     是"还没并账",不是答案。
    public static func classify(requestSucceeded: Bool, reportedCount: Int?,
                               rowIsOldEnough: Bool) -> PlayCountOutcome {
        guard requestSucceeded else { return .unanswered }
        // ⚠️ 这一行就是本次修复的全部:字段缺失 ≠ 那边是 0。
        guard let n = reportedCount else { return .unanswered }
        if n > 0 { return .counted(n) }
        return rowIsOldEnough ? .definitivelyNone : .unanswered
    }
}
