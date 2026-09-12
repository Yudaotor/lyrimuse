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
    /// `currentPlayCounted` = 当前这次播放**自己**是否已经被 Last.fm 计进 `freshTotal`
    /// (判据见 `currentPlayIsScrobbled`,调用方拿最近记录里这首歌那条的时刻跟本次开播
    /// 时刻对)。它决定加不加那个 +1:
    ///  - `false`(默认处境,换歌那一刻就是这样):总数是**过去**的次数,显示值 = 总数 + 1。
    ///  - `true`:总数已经含这一次,再 +1 就是同一次收听算两遍。
    ///
    /// 2026-09-13 之前这里无条件 +1,代价是**第一次听的歌必然多算一次**:正是这次 scrobble
    /// 让它第一次出现在最近记录里,新 key 没有 playCountVerifiedAt、`resolvePlayCounts` 对它
    /// 无条件取数,于是必定撞在"已入账、还在播"这个窗口里 —— 用户 2026-09-13 实测
    /// (《Cow-girl moderne》,第一次听):06:02:06 开播、约 06:03:30 越过 scrobble 门槛、
    /// 06:03:45 取到 userplaycount=1,徽标当场从 1 跳到 2。老歌同理,只是 N→N+1 不显眼。
    /// 当时那条注释把它估成"偶发、窗口很窄",实测下来两样都不成立。
    ///
    /// 已入账时**允许收回恰好多算的那一次**(`candidate == current - 1`),否则"只能涨"会
    /// 把本次会话里已经多算出来的数字永久焊住;再低的跌幅一律不接受 —— 那只可能是 Last.fm
    /// 自己返回了陈旧值(实测过换歌取到 16 而真实 27 的形态),采纳会让数字来回闪。
    public static func reconciledNowPlayingCount(
        current: Int?, freshTotal: Int, currentPlayCounted: Bool
    ) -> Int? {
        let candidate = freshTotal + (currentPlayCounted ? 0 : 1)
        guard candidate > 0 else { return nil }
        if candidate > (current ?? 0) { return candidate }
        if currentPlayCounted, let current, candidate == current - 1 { return candidate }
        return nil
    }

    /// 当前这次播放是不是**已经**被 Last.fm 记进 userplaycount 了(2026-09-13)。
    ///
    /// 判据只有一条:这首歌最新一条**已落库**的 scrobble,时刻跟本次开播时刻对得上。
    /// Last.fm 的 scrobble 时间戳记的是开播时刻(不是提交时刻),所以两者本该几乎相等;
    /// 容差留 120 秒,吸收锚点外推、暂停/拖动、以及两端时钟的偏差。这跟设置页实时行
    /// 认"同一次播放在列表里冒出第二行"(`LiveScrobbleRow.absorbedRecent`)是同一把尺子、
    /// 同一个容差 —— 那边 2026-08-17 就用它顶替过这个多算的数,只是没下沉到这里,于是
    /// 歌词窗口的徽标一直吃着裸值。
    ///
    /// 两个 nil 都返回 false = "不知道,按没入账算":宁可退回 +1 的老行为,也不要凭空少算一次。
    public static func currentPlayIsScrobbled(
        newestScrobbleAt: Date?, playStart: Date?, tolerance: TimeInterval = 120
    ) -> Bool {
        guard let newestScrobbleAt, let playStart else { return false }
        return abs(newestScrobbleAt.timeIntervalSince(playStart)) < tolerance
    }
}
