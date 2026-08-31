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

    /// 判据④(2026-08-29):不看"页内次数",只问"距离上次真验证过去了多久"——超过
    /// `maxAge` 就无条件判定过期,不管页内出没出现矛盾。
    ///
    /// 补的是判据③的一个盲点:`contradicted` 的第一道闸是 `onPage > cachedTotal`,只能
    /// 抓"缓存明显偏小"的情况。真实案例:方大同《ORANGe MOON》缓存冻结在 1,Last.fm 服务端
    /// 真实是 31——这首歌很久没被主动播放/浏览到,①②(依赖上一轮内存基线)从来没机会
    /// 比对,这次它只是又被听了一次重新出现在页面上,`onPage=1` 恰好没有超过冻住的旧值 `1`,
    /// `contradicted` 直接判"没问题"、永远不会触发重新验证。这类"好久没被翻到、这次只是
    /// 随手又听一次"的老歌都会踩中同一个盲区,不是罕见的边界情况。
    ///
    /// - Parameters:
    ///   - lastFetched: 上一次真的验证过这个 key 的时刻;`nil` = 从没验证过(老快照没有
    ///     这条记录,或者这个 key 是第一次出现)——无条件判定过期,宁可多查一次,不留
    ///     "从来没验证过"的空白。
    ///   - maxAge: 过期阈值,由调用方决定(见 LastfmStatsService.playCountStaleAfter 的
    ///     取值理由)。
    public static func stale(lastFetched: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        guard let lastFetched else { return true }
        return now.timeIntervalSince(lastFetched) >= maxAge
    }

    /// 「正在记录」nowPlayingCount 的追赶判据(2026-08-24)。
    ///
    /// nowPlayingCount 只在换歌那一刻取一次(取晚了这次播放被 scrobble 进去就会多算一,
    /// 见 LastfmStatsService.refreshNowPlayingCount),取完之后**没有任何自愈机制**——
    /// 跟 trackPlayCounts(历史行用)完全不是一回事,那张表有三条作废判据持续纠正。
    /// 用户实测(《Controversy》):换歌那一刻取到 16(显示 17),同一时刻历史行经
    /// trackPlayCounts 刷新已经追到 27(显示 28)——这个数字自己永远追不上去,直到下一次
    /// 换歌才会重新取一次全新的。
    ///
    /// 判据很朴素:trackPlayCounts 每次刷新都可能带来一个更新的总数,只要它比当前显示的
    /// 高就该采纳——**只能涨、不能跌**,理由跟原有「换歌那一刻取一次」的设计初衷一致:
    /// userplaycount 是过去的次数、只会越查越大(删除历史记录是极端例外,不在这个自愈的
    /// 处理范围内),跌下去只可能是缓存态一时不一致,采纳了反而会闪烁。
    ///
    /// ⚠️ 已知的窄边界(刻意接受,不是漏想):如果这次追赶发生在**当前这次播放自己**已经
    /// 越过 scrobble 门槛、且 Last.fm 已经把它计进 userplaycount 之后,新总数会连这次
    /// 播放也算进去,+1 之后偶发多算一。跟"完全冻结、整段会话数字长期错到离谱"（用户
    /// 实测过的 17 vs 28,差 11）相比,这个窗口窄得多、代价小得多——歌一换就会用全新的
    /// 换歌取数覆盖掉，不会带到下一首歌头上。两害相权取其轻，不是没考虑过就选的。
    public static func reconciledNowPlayingCount(current: Int?, freshTotal: Int) -> Int? {
        let candidate = freshTotal + 1
        guard candidate > (current ?? 0) else { return nil }
        return candidate
    }
}
