import Foundation

/// 「每个 key 最新一条收听是什么时候」—— 「第 N 次听」缓存作废判据的输入。
///
/// 为什么要有这个判据(2026-08-21 用户报「第 15 次听下面紧跟着第 21 次听」):原来只按
/// **页内出现次数变多**判作废,而连播同一首歌时最近记录那一页很快被它占满 —— 新的挤进来、
/// 旧的挤出去,页内次数**不再增长**,于是缓存的总次数永久冻结,而真实次数一路往上爬。
/// 实测那次缓存冻在 15,真实合计 22(《园游会》10 + 《園遊會》12 —— Last.fm 上是两个实体,
/// 歌手的简繁被 autocorrect 折了、歌名的没折)。而实时行是每次换歌现取的,显示 21。
///
/// 「最新一条收听的时刻往前走了」这个判据不会随页面被同一首歌占满而饱和。
///
/// 放在 LyrimuseCore 而不是跟 LastfmStatsService 待在一起:那个类在 App target 里
/// (要 SwiftUI),而 selftest 只依赖 LyrimuseCore。输入取成 `(key, date?)` 这种最小形态,
/// 上层负责把自己的行类型映射过来 —— 纯算术下沉,不把 App 的模型也拖进来。
public enum PlayCountRecency {
    /// 同一个 key 出现多次时取**最新**那条;date 为 nil 的项跳过(还没落库的"正在播放"
    /// 那条就是这种 —— 它不在 userplaycount 里,不该参与)。
    public static func newest(_ items: [(key: String, date: Date?)]) -> [String: Date] {
        var out: [String: Date] = [:]
        for item in items {
            guard let d = item.date else { continue }
            if let cur = out[item.key], cur >= d { continue }
            out[item.key] = d
        }
        return out
    }

    /// 「页内自相矛盾」判据的纯算术(2026-08-22)。
    ///
    /// 上面那条 recency 判据和更早的「页内出现次数变多」都要跟**上一轮**比,而基线
    /// (newestPlaySeen)只在内存里、次数表却是持久化的。两者一错配就留下一个**稳态**盲区:
    /// App 重启、或统计页关着的那段时间之后,基线被重设成「当下」,只要那首歌**不再被播
    /// 一次**,盘上冻住的旧数字就永远不会被作废。用户 2026-08-22 实测:缓存冻在 3、
    /// Last.fm 真实 12,而那一页有 11 行《开不了口 (live)》—— 视图侧的减法把后 8 行全算成
    /// ≤0,整片空白,且不会自愈。
    ///
    /// 这一条不跟任何历史比,只问当下这一页自己站不站得住:**页内已经看得见的收听次数
    /// 比缓存的总次数还多**,那缓存必错。无状态 → 重启后第一轮就生效,正好补上盲区。
    ///
    /// - Parameters:
    ///   - onPage: 这一页里这个**折叠族**出现了几次收听(不含还没落库的 nowPlaying 那条)。
    ///     必须按族数,不能按单个写法数 —— 次数表存的是整族合并总数,视图侧的减法也按族数,
    ///     三处得用同一把尺子,否则同页两种写法各 5 行、族总数 8 时数不出矛盾。
    ///   - cachedTotal: 缓存里这一族的合并总次数。
    ///   - lastFetched: 上一次真的问过 Last.fm 的时刻;nil = 本进程还没问过。
    ///   - recheckAfter: 命中矛盾后的重查节流。Last.fm 自己的 userplaycount 也滞后几分钟,
    ///     刚 scrobble 完重取回来还是同一个数、下一轮又矛盾 —— 不节流就是每轮刷新都白发
    ///     一个请求、永不收敛。nil 基线**不**受节流约束,那正是「重启后第一轮就质疑一次」。
    public static func contradicted(onPage: Int, cachedTotal: Int,
                                    lastFetched: Date?, now: Date,
                                    recheckAfter: TimeInterval) -> Bool {
        guard onPage > cachedTotal else { return false }
        guard let lastFetched else { return true }
        return now.timeIntervalSince(lastFetched) >= recheckAfter
    }
}
