import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lastfm-stats")

/// Last.fm 信息页(AccountLinkingTab 的 Last.fm 卡)的数据层:档案数字、最近 scrobble、
/// 三种 Top 榜。全部走只读接口,用桥接那把 API Key,不需要签名、不经 collector ——
/// 设计方案(2026-08-11 artifact)里"技术落点"一节定的就是 Swift 直连。
///
/// ## 请求节奏
///
/// 进页面拉 getInfo + 两个计数 + 最近列表 + 当前分段的榜单;其余分段**切到才请求**。
/// 结果按 15 分钟 TTL 缓存在内存里,期间重进不再请求 —— 这页在设置窗里,被反复开关是
/// 常态,不能每次都打五个请求出去。
///
/// ## 为什么用 JSONSerialization 而不是 Codable
///
/// Last.fm 的 JSON 键长这样:`@attr`、`#text`、数字全是字符串、单元素数组会塌成对象。
/// 给它建 Codable 模型要写一堆 CodingKeys + 兼容初始化器,换 JSONSerialization 按路径
/// 取反而直白,错了也只是那一块显示为空,不会整个解码失败把别的数据一起拖下水。
@MainActor
final class LastfmStatsService: ObservableObject {
    static let shared = LastfmStatsService()

    private init() {
        loadSnapshot()
    }

    // MARK: - 模型

    enum ChartKind: String, CaseIterable, Identifiable {
        case artists, albums, tracks
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .artists: return L10n.t("歌手")
            case .albums: return L10n.t("专辑")
            case .tracks: return L10n.t("歌曲")
            }
        }
        var method: String {
            switch self {
            case .artists: return "user.gettopartists"
            case .albums: return "user.gettopalbums"
            case .tracks: return "user.gettoptracks"
            }
        }
        /// 响应里列表所在的路径:`topartists.artist` / `topalbums.album` / `toptracks.track`
        var listPath: (String, String) {
            switch self {
            case .artists: return ("topartists", "artist")
            case .albums: return ("topalbums", "album")
            case .tracks: return ("toptracks", "track")
            }
        }
    }

    enum Period: String, CaseIterable, Identifiable {
        case week = "7day", month = "1month", year = "12month", overall = "overall"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .week: return L10n.t("近 7 天")
            case .month: return L10n.t("近 30 天")
            case .year: return L10n.t("近一年")
            case .overall: return L10n.t("全部")
            }
        }
    }

    struct Overview: Equatable, Codable {
        var total: Int
        var today: Int
        var week: Int
    }

    struct ChartEntry: Identifiable, Equatable, Codable {
        let rank: Int
        let name: String
        /// 专辑/歌曲的所属歌手;歌手榜为空。
        let detail: String
        let playcount: Int
        /// 只有专辑榜有真封面(歌手/歌曲的 image 是 Last.fm 的白星占位图,见设计方案的
        /// 数据盘点表),其余留 nil,由 UI 画首字母色块。
        let imageURL: URL?
        var id: Int { rank }
    }

    struct RecentTrack: Identifiable, Equatable, Codable {
        /// 同一时刻+同一首歌重复出现时的序号(双端同时 scrobble 等罕见情况),几乎恒为 0。
        ///
        /// ⚠️ 这里**不能**放"在这批响应里的行号":那样每来一条新 scrobble,后面所有行的
        /// id 全变,SwiftUI 会把整张列表当成被替换掉、连带把滚动位置顶回去 —— 表现就是
        /// "列表滑不动/滑到一半弹回去"(2026-08-12 用户反馈,列表每 45 秒刷一次)。
        /// 老快照没有这个键,可选类型解码为 nil。
        var dup: Int?
        let title: String
        let artist: String
        /// scrobble 记录里带的专辑名(可能为空)。用来给同专辑的兄弟曲目共享封面,
        /// 见 coverURL(for:)。老快照没有这个键,可选类型解码时自动为 nil。
        var album: String?
        let imageURL: URL?
        /// nil = 这行是"正在播放"(Last.fm 把 nowplaying 行的 date 整个省掉)。
        let date: Date?
        var nowPlaying: Bool { date == nil }
        var id: String { "\(date?.timeIntervalSince1970 ?? -1)|\(artist)|\(title)|\(dup ?? 0)" }
    }

    // MARK: - 状态

    @Published private(set) var overview: Overview?
    @Published private(set) var recent: [RecentTrack] = []
    /// 最近记录一页放多少条。2026-08-12 从"8→30→100 一路展开"改成分页:一路展开会把
    /// 一页撑到上百行(整页越滚越长、每页刷新都要给上百首查播放次数),而看历史本来就是
    /// 翻页的事,不是无限长列表(用户要求)。
    static let recentPageSize = 20
    /// 当前第几页(1 起)。存在服务里而不是视图里 —— 定时刷新和换歌强刷都走
    /// refreshBaseline,得按用户正在看的那一页重拉。
    @Published private(set) var recentPage = 1
    /// 总页数(来自响应的 @attr.totalPages),给翻页控件显示和封顶。
    @Published private(set) var recentTotalPages = 1
    /// 正在翻页(按钮转圈用)。跟 baselineFailed 分开:翻页失败不该把整卡换成失败态,
    /// 当前这页还好好的。
    @Published private(set) var recentPaging = false
    /// 最近记录最后一次**成功**拉到内容的时刻。给卡片头显示"几分钟前更新"。
    /// 刻意不从快照恢复:那是上次会话的数据,标成"刚刚更新"是撒谎;首次刷新落地后才有值。
    @Published private(set) var recentUpdatedAt: Date?
    /// kind|period → 榜单。切分段/时段时旧内容还在,不闪空。
    @Published private(set) var charts: [String: [ChartEntry]] = [:]
    /// 正在拉取/拉取失败的榜单键(kind|period)。原来是两个全局布尔 —— 歌手榜和歌曲榜
    /// 并发拉取时互相踩:一个先完成会把另一个的转圈提前掐掉,一个失败会把失败态标到
    /// 正在看的另一个榜头上(2026-08-11 审阅确认)。按键控各管各的。
    @Published private(set) var chartLoadingKeys: Set<String> = []
    @Published private(set) var chartFailedKeys: Set<String> = []

    func chartLoading(_ kind: ChartKind, _ period: Period) -> Bool {
        chartLoadingKeys.contains("\(kind.rawValue)|\(period.rawValue)")
    }
    func chartFailed(_ kind: ChartKind, _ period: Period) -> Bool {
        chartFailedKeys.contains("\(kind.rawValue)|\(period.rawValue)")
    }

    /// baseline(数字+最近记录)的代际计数器。refreshBaseline 和 goToPage 的 Task
    /// 都会写 overview/recent,彼此之间没有取消 —— 没有它的话,翻页拉回来的那批
    /// 之后,一个更早在飞的 limit=8 旧响应后到,会把列表又缩回 8 条(2026-08-11 审阅
    /// 确认,窗口就是一个网络 RTT)。规则:发起时自增并捕获,写回前核对,旧代直接丢弃。
    /// 所有读写都在 MainActor 上,check-then-write 天然原子。
    private var baselineGen = 0
    /// 歌手名 → 真头像 URL。由 collector 的 artist-avatars 子命令解析(QQ 音乐优先、
    /// Deezer 兜底,14 天磁盘缓存,见 avatarcli.go)——Last.fm API 的歌手图是占位星。
    /// 查不到的名字**不会**出现在这里,UI 自然回落到首字母色块。
    @Published private(set) var artistAvatars: [String: URL] = [:]
    /// "歌手|歌名" → 这首歌所属专辑的封面。歌曲榜的 API 图也是占位星,真封面得按首
    /// 调 track.getInfo 拿它的专辑图 —— 榜单到手后并发补一轮,查不到的(无专辑的单曲)
    /// 不进字典,UI 回落到首字母色块。
    @Published private(set) var trackCovers: [String: URL] = [:]
    /// 每首歌**当前的**总收听次数(track.getinfo 的 userplaycount,含已 scrobble 的这一次)。
    /// 键用 playCountKey 归一。注意它是"到此刻为止的总数",不是"那一次是第几次"——
    /// 后者由视图侧减去更新的同曲收听算出,见 LastfmStatsSection.playCount(at:)。
    @Published private(set) var trackPlayCounts: [String: Int] = [:]
    /// 最近记录行的封面兜底。scrobble 记录自带的图常常是 Last.fm 的占位星星(被
    /// imageURL 滤成 nil)—— 那是因为 scrobble 上报的专辑名跟 Last.fm 的规范实体对不上
    /// (实测:上报"公转.自转",规范实体叫"公轉自轉",简繁+标点都不同),落到了一个没有图的
    /// 条目上。track.getinfo 带 autocorrect 能纠到有图的那个,而它正是算播放次数时**已经
    /// 在调**的同一个请求,封面白拿(2026-08-12 用户点出这条线索)。
    @Published private(set) var recentTrackCovers: [String: URL] = [:]
    /// 按 scrobble 里那个专辑名归一后的封面。给"getinfo 连专辑都没返回"的曲目兜底:
    /// 同一张专辑里只要有一首纠正成功,这一整张的行都能共用它的封面。
    @Published private(set) var recentAlbumCovers: [String: URL] = [:]
    /// 已经问过 getinfo、但那边**确实没有**这一项的曲目。分成两张表:次数和封面是两件事,
    /// 合成一张的话「有次数没封面」会永远满足重查条件、每轮刷新都重发一次请求,永不收敛
    /// (2026-08-12 性能审阅坐实的死循环)。
    /// ⚠️ 只在请求**成功返回**但该项为空时才记;网络失败/限流不记,那种要留给下次重试。
    ///
    /// ⚠️⚠️ 还有一类"成功返回但不能当真"的:**刚 scrobble 完的曲目 userplaycount 会是 0**。
    /// Last.fm 的这个数不是实时的,新记录要过几分钟才并进去 —— 而"最近记录"最上面那几行
    /// 恰恰全是刚 scrobble 的。记进这张表就等于永久放弃(这一进程内再不重查),表现是那一行
    /// 永远不显示「第 N 次听」。2026-08-19 用户报「为什么只有微尘没有第一次听」就是这个:
    /// 实测那一刻直接问 Last.fm,userplaycount 已经是 1 了,只是 8 分钟前问的时候是 0。
    /// 所以 0 值只对**够老的行**才记进来,见 playCountZeroGraceSecs。
    private var playCountUnavailable = Set<String>()
    /// scrobble 之后多久之内,userplaycount=0 一律当成"还没并进去",留给下一轮重查。
    /// 15 分钟:实测几分钟就并好了,留足余量;超过这个岁数还是 0 才认为那边真的没有
    /// (那时行也快被新的 scrobble 顶下去了,重查的成本自然收敛)。
    private static let playCountZeroGraceSecs: TimeInterval = 15 * 60
    private var coverUnavailable = Set<String>()
    /// 上一次 applyRecent 时看的是第几页。翻了页就不做下面那套"同曲次数变多 → 旧总数
    /// 作废"的判定:换了一批完全不同的行,那个比较没有意义。
    private var lastAppliedRecentPage = 0
    /// 正在查次数的曲目键 —— 挡住"2 分钟定时刷新又触发一轮同样的请求"这种重复。
    private var playCountsInFlight = Set<String>()
    @Published private(set) var baselineFailed = false
    @Published private(set) var chartFailed = false
    /// Last.fm 侧当前回报的 nowplaying 条目(recenttracks 里 date 缺失的那行)。
    /// 「正在记录」红点的**真值来源**:collector 发出的 updateNowPlaying 被 Last.fm 收到
    /// 后才会出现在这里 —— 本地开始播放只能算「正在播放」,服务器确认过才算「正在记录」
    /// (2026-08-11 发散采纳,红点不再本地猜)。
    @Published private(set) var apiNowPlaying: RecentTrack?
    /// 我们第一次看到 apiNowPlaying 这一首的时刻(换了一首才重置)。
    /// 用途见 apiNowPlayingIsFresh —— Last.fm 的 nowplaying 不会在播放停止时立刻消失。
    @Published private(set) var apiNowPlayingSince: Date?
    /// 「这是你第 N 次听」:track.getinfo 带 username 的 userplaycount + 1。
    /// 换歌那一刻取一次,同一首歌不重取(取晚了这次播放被 scrobble 进去就会多算一)。
    @Published private(set) var nowPlayingCount: Int?
    private var nowPlayingCountKey = ""
    /// 被「正在记录」实时行**吸收**的那条最近记录的 id。长歌播到 4 分钟/过半时 Last.fm
    /// 就已收到 scrobble(时间戳=开播时刻),于是同一次播放在列表里出现两行:上面
    /// "第 5 次听·正在记录"、下面"第 4 次听·4 分钟前"(2026-08-17 用户截图)。由
    /// LiveScrobbleRow 维护(唯一同时看得到播放进度和最近记录的地方),列表渲染时跳过
    /// 这一行;播放结束/暂停实时行退场时置回 nil,该行随即以普通历史行身份回归。
    @Published var liveAbsorbedRecentID: String?
    /// 那年今日:去年(查不到再往前,最多三年)同一天的收听。整天没有记录则为 nil,卡片隐藏。
    @Published private(set) var onThisDay: OnThisDayResult?
    /// 上面那份数据最后一次**成功**拉到的时刻,给卡片头显示"几小时前更新"。
    /// 跟 recentUpdatedAt 同一套语义:只在真的取到内容时才写(见 refreshOnThisDay 里
    /// 赋值的位置——那一句紧挨着 onThisDay 的赋值,不是开头占 TTL 的那个 fetchedAt)。
    /// 探完三年都没有记录时保持 nil,反正那时整张卡都不显示。
    @Published private(set) var onThisDayUpdatedAt: Date?
    /// 手上这份「那年今日」是按哪一天算出来的(存当天任意时刻即可)。它是 TTL 之外的
    /// 第二道判据,少了它 6 小时 TTL 会把昨天那份一路带过零点 —— 见 DailyRefreshGate。
    private var onThisDayDay: Date?

    struct OnThisDayResult: Equatable {
        /// 当天播放最多的一首:曲目本身 + 那天听了几次 + 那天最后一次的时刻。
        struct TopTrack: Equatable, Identifiable {
            let track: RecentTrack
            let count: Int
            let lastPlayed: Date?
            var id: String { track.id }
        }
        let yearsAgo: Int
        let total: Int
        /// 当天播放最多的前三首(次数降序)。2026-08-12 从"当天最后听的三首"改成这个:
        /// 副标题讲的是"循环最多",下面却列着"最后听的",一张卡说两套口径,用户实测被绕住。
        let top: [TopTrack]
    }

    private var fetchedAt: [String: Date] = [:]
    /// 榜单的缓存时长 —— Top 榜一天都未必变一名,15 分钟足够。
    private let ttl: TimeInterval = 15 * 60
    /// 档案数字 + 最近记录的缓存时长。这块是页面上"活"的部分:刚听完的歌应该几分钟内
    /// 出现,页面常开时每次定时器到点也靠它放行,不能跟榜单共用 15 分钟。
    /// ⚠️ 必须**小于**页面那条定时轮的间隔(LastfmStatsSection 里是 120 秒)。两个数一样
    /// 大的时候,"睡够 120 秒"和"过期需要超过 120 秒"是同一条线上的两个端点,到点那一刻
    /// 究竟算不算过期取决于几毫秒的循环开销 —— 定时刷新变成抛硬币,有时候整轮什么都不发。
    /// 取 110 秒留 10 秒余量:既保证每一轮都真的放行,也不影响"刚听完的歌几分钟内出现"。
    private let baselineTTL: TimeInterval = 110

    func chart(_ kind: ChartKind, _ period: Period) -> [ChartEntry]? {
        charts["\(kind.rawValue)|\(period.rawValue)"]
    }

    /// 断开/换账号时把一切归零 —— 统计数字、榜单、头像、封面都是**上一个身份**的,
    /// 挂着不清,重连另一个账号后页面会先展示前任的数据(审阅指出)。
    func resetAll() {
        baselineGen += 1
        overview = nil
        recent = []
        apiNowPlaying = nil
        apiNowPlayingSince = nil
        nowPlayingCount = nil
        nowPlayingCountKey = ""
        onThisDay = nil
        onThisDayUpdatedAt = nil
        onThisDayDay = nil
        snapshotSaveTask?.cancel()
        try? FileManager.default.removeItem(at: Self.snapshotURL)
        titleForms = [:]
        titleFormsSyncedThrough = 0
        titleFormsLoaded = false
        titleFormsSyncing = false
        titleFormsLastTopUp = nil
        titleFormsSaveTask?.cancel()
        try? FileManager.default.removeItem(at: Self.titleFormsURL)
        charts = [:]
        artistAvatars = [:]
        trackCovers = [:]
        trackPlayCounts = [:]
        recentTrackCovers = [:]
        recentAlbumCovers = [:]
        recentCoverByTrack = [:]
        recentCoverByAlbum = [:]
        localCovers = [:]
        playCountUnavailable = []
        coverUnavailable = []
        playCountsInFlight = []
        playCountFetchedAt = [:]
        newestPlaySeen = [:]
        catalogCovers = [:]
        catalogCoverUnavailable = []
        catalogCoversInFlight = []
        artistCorrections = [:]
        artistCorrectionTasks.values.forEach { $0.cancel() }
        artistCorrectionTasks = [:]
        lastAppliedRecentPage = 0
        chartLoadingKeys = []
        chartFailedKeys = []
        baselineFailed = false
        recentPaging = false
        recentPage = 1
        recentTotalPages = 1
        recentUpdatedAt = nil
        fetchedAt = [:]
    }

    /// 「第 N 次听」:换歌那一刻取一次。key 守卫保证晚到的响应不会写到下一首歌头上,
    /// 也保证同一首歌不重取(播放中途重取会把这次已 scrobble 的计入,多算一)。
    func refreshNowPlayingCount(title: String, artist: String) {
        let key = "\(artist)|\(title)"
        guard key != nowPlayingCountKey else { return }
        nowPlayingCountKey = key
        nowPlayingCount = nil
        guard !title.isEmpty, let cred = credentials else { return }
        Task {
            // 写法孪生实体(括号风格/去副题/繁简,见 PlayCountVariants 注释)在 Last.fm
            // 各记各的账 —— 逐个问、按规范身份去重后求和。身份去重防两类翻倍:孪生写法
            // 不存在时 autocorrect 折回本尊,以及两个变体折到同一个第三实体。
            //
            // 本尊 + 孪生**并发**取(2026-08-19 性能审计 #4:原来逐个串行 await,孪生
            // 封顶 8 个时「第 N 次听」要排队九个来回才显示出来)。请求都发出去、结果按
            // 下标收齐后,仍按「本尊在前、孪生按原顺序」折叠 —— 身份去重的语义跟串行版
            // 逐字节一致,谁先返回不影响结果。
            let sibs = playCountSiblings(artist: artist, title: title)
            var results = [Int: (count: Int?, identity: String?)](minimumCapacity: sibs.count + 1)
            await withTaskGroup(of: (Int, (count: Int?, identity: String?)).self) { group in
                group.addTask { [weak self] in
                    (0, await self?.userPlayCount(artist: artist, title: title, cred: cred)
                        ?? (count: nil, identity: nil))
                }
                for (i, sib) in sibs.enumerated() {
                    group.addTask { [weak self] in
                        (i + 1, await self?.userPlayCount(artist: sib.artist, title: sib.title, cred: cred)
                            ?? (count: nil, identity: nil))
                    }
                }
                for await (i, r) in group { results[i] = r }
            }
            var total = results[0]?.count
            var identities = Set<String>()
            if let id = results[0]?.identity { identities.insert(id) }
            // 注:下面求和完之后会把这个新鲜总数写回 trackPlayCounts(见 adoptFreshTotal)
            // —— 那是历史行用的同一张表,而它自己只在"页内出现次数变多"时才作废,
            // 连播同一首歌时会冻结(2026-08-21 用户报的 15 vs 21)。这次取数本来就付过了,
            // 顺手刷新是白捡的。
            for i in sibs.indices {
                guard let r = results[i + 1], let c = r.count, let id = r.identity,
                      identities.insert(id).inserted else { continue }
                total = (total ?? 0) + c
            }
            guard nowPlayingCountKey == key else { return }
            if let total {
                // 顺手把这个**新鲜的合并总数**写回历史行用的那张表(见 adoptFreshTotal)。
                adoptFreshTotal(total, artist: artist, title: title, siblings: sibs)
                // userplaycount 是**过去**的次数,这一次还没被记进去 —— 所以 +1
                nowPlayingCount = total + 1
            }
        }
    }

    /// track.getinfo 的 userplaycount + 响应里的规范身份(纠正后的 歌手|歌名 小写键)。
    /// count nil = 请求失败,或那边没有这个实体/没记过次数;identity nil = 请求失败。
    /// identity 用来识别「孪生查询被 autocorrect 折回了同一个实体」—— 见调用处。
    private func userPlayCount(artist: String, title: String,
                               cred: (user: String, key: String))
        async -> (count: Int?, identity: String?)
    {
        let json = await request(method: "track.getinfo", cred: cred,
                                 extra: ["artist": artist, "track": title,
                                         "autocorrect": "1", "username": cred.user])
        guard let json else { return (nil, nil) }
        let count = (dig(json, "track", "userplaycount") as? String).flatMap { Int($0) }
        var identity: String?
        if let name = dig(json, "track", "name") as? String,
           let art = dig(json, "track", "artist", "name") as? String {
            identity = Self.playCountKey(artist: art, title: name)
        }
        return (count, identity)
    }

    /// 那年今日:去年同一天(0 点到 24 点)的收听。整天为空自动再往前一年,最多探三年,
    /// 全空保持 nil(卡片整个隐藏)。6 小时 TTL —— 同一天之内内容不会变。
    ///
    /// ⚠️ TTL 必须跟**日历天**一起判,不能只判"过了多久"(2026-08-17 用户报"昨天和今天
    /// 显示的是同一份")。这张卡的内容按日历天定义,而 6 小时 TTL 只知道经过了多少秒:
    /// 22:00 打开取到 8/16 那份,次日 02:00 再打开时 TTL 还没到期,界面就把昨天那份继续
    /// 挂在"今天"上,最长挂 6 小时。App 是常驻 launchd 服务、跨零点不重启,而 fetchedAt
    /// 只在进程内存里 —— 不重启就一直有效,所以这不是理论问题。跨过零点就把缓存作废。
    func refreshOnThisDay() {
        let now = Date()
        // 判据是 DailyRefreshGate 那个纯函数(TTL 或 跨天,取或),不是这个类里通用的
        // fresh() —— 后者只判 TTL,正是这次的 bug 所在。见那个文件的注释。
        guard DailyRefreshGate.needsRefresh(
            lastFetchedAt: fetchedAt["onthisday"], cachedDay: onThisDayDay,
            now: now, ttl: 6 * 3600)
        else { return }
        guard let cred = credentials else { return }
        // 两个字段同一时机写(而不是等取到内容):它们一起决定"这一天要不要再发请求",
        // 失败时同样占住 6 小时不重试,语义跟其它 fetchedAt 键保持一致。真正对用户可见的
        // "更新时间"是另一个字段 onThisDayUpdatedAt,那个才只在成功时写。
        fetchedAt["onthisday"] = now
        onThisDayDay = now
        Task {
            let cal = Calendar.current
            for yearsAgo in 1...3 {
                guard let anchor = cal.date(byAdding: .year, value: -yearsAgo, to: Date()) else { continue }
                let from = cal.startOfDay(for: anchor)
                let base = ["from": String(Int(from.timeIntervalSince1970)),
                            "to": String(Int(from.timeIntervalSince1970) + 86400),
                            "limit": String(onThisDayPageSize)]
                guard let first = await request(method: "user.getrecenttracks", cred: cred, extra: base)
                else { continue }
                let total = attrTotal(first)
                var rows = parseRecent(first).filter { $0.date != nil }
                guard total > 0, !rows.isEmpty else { continue }
                // 统计口径必须跟"听了 N 次"这个数对得上:一页 200 条盖不住的重听大日子,
                // 再翻几页补齐,不然会出现"总数是全天的、最多那首却只从最近 200 条里挑"
                // 的混用(2026-08-12 用户点出)。翻页上限兜住极端值,超出部分如实少算。
                let totalPages = Int(dig(first, "recenttracks", "@attr", "totalPages") as? String ?? "") ?? 1
                if totalPages > 1 {
                    for page in 2...min(totalPages, onThisDayMaxPages) {
                        guard let more = await request(method: "user.getrecenttracks", cred: cred,
                                                       extra: base.merging(["page": String(page)]) { _, new in new })
                        else { break }
                        rows.append(contentsOf: parseRecent(more).filter { $0.date != nil })
                    }
                }
                var counts: [String: Int] = [:]
                var sample: [String: RecentTrack] = [:]
                var lastPlayed: [String: Date] = [:]
                for r in rows {
                    let k = Self.playCountKey(artist: r.artist, title: r.title)
                    counts[k, default: 0] += 1
                    if sample[k] == nil { sample[k] = r } // 响应是倒序,首见即当天最后一次
                    if let d = r.date, lastPlayed[k] == nil || d > lastPlayed[k]! { lastPlayed[k] = d }
                }
                // 确定性排序:次数降序 → 当天最后一次更晚的在前 → 歌名。少了后两级的话,
                // 并列时取谁全看字典迭代序,同一天刷两次能给出不同的"最多那首"。
                let ranked = counts.keys.compactMap { key -> OnThisDayResult.TopTrack? in
                    guard let track = sample[key], let n = counts[key] else { return nil }
                    return OnThisDayResult.TopTrack(track: track, count: n, lastPlayed: lastPlayed[key])
                }.sorted { a, b in
                    if a.count != b.count { return a.count > b.count }
                    let ad = a.lastPlayed ?? .distantPast, bd = b.lastPlayed ?? .distantPast
                    if ad != bd { return ad > bd }
                    return a.track.title < b.track.title
                }
                guard !ranked.isEmpty else { continue }
                let top = Array(ranked.prefix(3))
                onThisDay = OnThisDayResult(yearsAgo: yearsAgo, total: total, top: top)
                onThisDayUpdatedAt = Date()
                // 这三首的封面走跟最近记录**完全同一套**兜底:本机 enrich 缓存 + getinfo
                // (必要时按纠正后的歌手名重查一次)。不补的话它们只剩 coverURL(for:) 的
                // 第一级可用,碰上占位星就是灰块 —— 见 refreshLocalCovers 的注释。
                //
                // 借道 resolvePlayCounts 而不是另写一个只取封面的:它一趟 getinfo 本来就同时
                // 拿次数和封面,顺带写进 trackPlayCounts 的次数是"这首歌的总收听次数",全局
                // 有效(最近记录里要是也有这首就白拿)。这张卡自己显示的「N 次」是当天次数,
                // 来自 entry.count,跟那张表无关,不会串。
                refreshLocalCovers()
                resolvePlayCounts(for: top.map(\.track))
                return
            }
        }
    }

    // MARK: - 播放热力图(每日计数)

    /// "yyyy-MM-dd"(本地时区) → 当日 scrobble 数。数据来自 user.getRecentTracks 全量
    /// 分页聚合:首次同步整个历史(两万条 ≈ 110 页,只跑一次),之后按 dailySyncedThrough
    /// 增量,通常一页就完。独立缓存文件,删了无损、下次重建。
    @Published private(set) var dailyCounts: [String: Int] = [:]
    @Published private(set) var dailySyncing = false
    /// 首次全量同步的进度文案;增量同步一闪而过,保持 nil 不占界面。
    @Published private(set) var dailySyncProgress: String?
    @Published private(set) var dailySyncFailed = false
    private var dailySyncedThrough: TimeInterval = 0
    private var dailyLoaded = false

    private struct DailySnapshot: Codable {
        var username: String
        var syncedThrough: TimeInterval
        var days: [String: Int]
    }

    private static let dailyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-lastfm-daily-heatmap.json")

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    private func loadDailySnapshot() {
        dailyLoaded = true
        guard let cred = credentials,
              let data = try? Data(contentsOf: Self.dailyURL),
              let snap = try? JSONDecoder().decode(DailySnapshot.self, from: data),
              snap.username == cred.user   // 换过账号不吃旧缓存
        else { return }
        dailyCounts = snap.days
        dailySyncedThrough = snap.syncedThrough
    }

    private func saveDailySnapshot() {
        guard let cred = credentials else { return }
        let snap = DailySnapshot(username: cred.user, syncedThrough: dailySyncedThrough, days: dailyCounts)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: Self.dailyURL, options: .atomic)
        }
    }

    /// 回填在热力图同步**进行中**到达时的挂起回拨——立刻改水位会被同步收尾那句
    /// `dailySyncedThrough = syncStartedAt` 盖回去,记下来等收尾时应用。
    private var pendingDailyRewind: TimeInterval?

    /// 回填(补提交)成功后调用:把每日计数的增量水位拨回回填窗口起点。
    ///
    /// 为什么必须拨(2026-08-18 用户报"补提交后没刷新"时顺带发现的隐患):回填把
    /// scrobble 塞进**过去最多 13 天**(collector backfill.go 的回溯窗口),而增量同步
    /// 只从"最后已同步那天的零点"往后扫 —— 不回拨的话,补进历史的那些天会被增量同步
    /// **永远**漏掉,热力图永久少计。拨 14 天带一天余量;重扫 14 天 ≈ 一两页请求,开销
    /// 可忽略。只动水位不动 dailyCounts:下次打开热力图时那段区间整体重算,重算前旧
    /// 数据照常显示,跟 refreshDailyCounts"全部成功才合并替换"的口径一致。
    func rewindDailySyncForBackfill() {
        if !dailyLoaded { loadDailySnapshot() }
        let target = Date().timeIntervalSince1970 - 14 * 86400
        guard dailySyncedThrough > target else { return } // 从没同步过/水位本就更早
        if dailySyncing {
            pendingDailyRewind = target
            return
        }
        dailySyncedThrough = target
        saveDailySnapshot()
    }

    /// 见 pendingDailyRewind。同步收尾(成功或失败)时调,有挂起的回拨就应用。
    private func applyPendingDailyRewind() {
        guard let target = pendingDailyRewind else { return }
        pendingDailyRewind = nil
        if dailySyncedThrough > target {
            dailySyncedThrough = target
            saveDailySnapshot()
        }
    }

    /// 打开热力图时调用。单飞;增量从"最后已同步那天的零点"重拉——那一天上次可能只
    /// 覆盖到中途,整天作废重算,天粒度桶不存在半天拼接的口径问题。
    ///
    /// ⚠️ 同步过程不动 dailyCounts,全部页拉完才一次性合并替换——中途失败(断网/限流)
    /// 时旧数据原样保留,失败态只是一个可重试的标记,不是数据丢失。
    func refreshDailyCounts() {
        guard !dailySyncing else { return }
        guard let cred = credentials else { return }
        if !dailyLoaded { loadDailySnapshot() }
        dailySyncing = true
        dailySyncFailed = false
        let syncStartedAt = Date().timeIntervalSince1970
        var from: TimeInterval = 1
        var wipeFromDay: String?
        if dailySyncedThrough > 0 {
            let lastDayStart = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: dailySyncedThrough))
            from = lastDayStart.timeIntervalSince1970
            wipeFromDay = Self.dayKey(lastDayStart)
        }
        Task {
            var fresh: [String: Int] = [:]
            var page = 1
            var totalPages = 1
            var failed = false
            // 400 页 = 8 万条,远超当前量级的安全上限,防 totalPages 异常时打穿。
            while page <= totalPages && page <= 400 {
                guard let obj = await request(
                    method: "user.getrecenttracks", cred: cred,
                    extra: ["limit": "200", "page": "\(page)", "from": "\(Int(from))"]),
                    let rt = obj["recenttracks"] as? [String: Any],
                    let attr = rt["@attr"] as? [String: Any]
                else {
                    failed = true
                    break
                }
                totalPages = Int((attr["totalPages"] as? String) ?? "1") ?? 1
                // Last.fm 的怪癖:只有一条时 track 是对象不是数组。
                var tracks = (rt["track"] as? [[String: Any]]) ?? []
                if tracks.isEmpty, let single = rt["track"] as? [String: Any] {
                    tracks = [single]
                }
                for t in tracks {
                    // 顺手收割写法索引(nowplaying 行也是真实写法,一并收)
                    if let name = t["name"] as? String,
                       let art = (t["artist"] as? [String: Any])?["#text"] as? String {
                        harvestTitleForm(artist: art, title: name)
                    }
                    // 正在播放的行没有 date,跳过(它还不是一条落库的 scrobble)。
                    if let a = t["@attr"] as? [String: Any],
                       (a["nowplaying"] as? String) == "true" { continue }
                    guard let dateObj = t["date"] as? [String: Any],
                          let utsS = dateObj["uts"] as? String,
                          let uts = TimeInterval(utsS) else { continue }
                    fresh[Self.dayKey(Date(timeIntervalSince1970: uts)), default: 0] += 1
                }
                if totalPages > 3 {
                    dailySyncProgress = String(
                        format: L10n.t("正在同步历史（%1$@/%2$@ 页）"), "\(page)", "\(totalPages)")
                }
                page += 1
                if page <= totalPages {
                    try? await Task.sleep(nanoseconds: 150_000_000) // 对 API 客气一点
                }
            }
            dailySyncProgress = nil
            dailySyncing = false
            if failed {
                dailySyncFailed = true
                applyPendingDailyRewind() // 同步期间来过回填:失败也要把水位拨回去
                return
            }
            var days = dailyCounts
            if let wipe = wipeFromDay {
                // "yyyy-MM-dd" 字典序即时间序,直接字符串比较。
                for k in days.keys where k >= wipe { days.removeValue(forKey: k) }
            }
            for (k, v) in fresh { days[k, default: 0] += v }
            dailyCounts = days
            dailySyncedThrough = syncStartedAt
            applyPendingDailyRewind() // 同步期间来过回填:水位不能停在 syncStartedAt
            saveDailySnapshot()
        }
    }

    // MARK: - 写法索引(「第 N 次听」的数据驱动合并,2026-08-19)
    //
    // 背景:同一首歌因写法差异(全半角括号/繁简/麼麽字形/双语拼接/空格)在 Last.fm 被记成
    // 多本账,猜枚举(PlayCountVariants)修一茬冒一茬。这里改成从用户**自己的全量播放历史**
    // 建 折叠键(PlayCountFold)→ 真实写法族 的索引:查次数时按族查,数据驱动、自更新 ——
    // 新的分裂形态一旦在历史里出现就自动被族住,不需要再补表。userplaycount 只统计本用户
    // 的 scrobble,所以「历史里没有的写法」在 Last.fm 那边必然是 0,索引按构造即完备。
    //
    // 更新机制:①首次全量分页建索引(~110 页,一次性,后台);②之后每一批**已经拉到手**的
    // scrobble 行(最近记录/热力图分页)顺手收割,零额外请求;③页面主刷新时从水位起低频
    // 增量补漏(App 关着期间产生的新写法,15 分钟节流,通常 1 页)。

    struct TitleForm: Codable, Equatable {
        var artist: String
        var title: String
    }

    private struct TitleFormsSnapshot: Codable {
        var username: String
        var syncedThrough: TimeInterval
        var forms: [String: [TitleForm]]
        /// 写这份文件时的折叠规则版本(PlayCountFold.foldVersion)。加载时版本一致
        /// 直接采用盘上的键;不一致(旧文件缺字段也算)才做一次性重折迁移。
        var foldVersion: Int?
    }

    private static let titleFormsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-lastfm-title-forms.json")
    /// 折叠键 → 历史上真实出现过的写法族。
    private var titleForms: [String: [TitleForm]] = [:]
    /// 全量建成/增量补到的水位(uts)。0 = 从未建成,候选退回猜枚举。
    private var titleFormsSyncedThrough: TimeInterval = 0
    private var titleFormsLoaded = false
    private var titleFormsSyncing = false
    private var titleFormsLastTopUp: Date?
    private var titleFormsSaveTask: Task<Void, Never>?

    /// titleForms 的派生索引:桶的键把歌手换成「合唱 credit 的第一位」再聚一遍。
    ///
    /// 2026-08-20 加。titleForms 自己按**完整歌手串**分桶,于是同一首歌被两种 credit 写法
    /// 记成两本账时(实测 `Daniel Caesar & Mustafa|Toronto 2014` 与
    /// `Daniel Caesar|Toronto 2014` 各 1 次,两行都显示「第 1 次听」),两边互相看不见 ——
    /// 这个索引是唯一能把它们连起来的东西。
    ///
    /// 为什么派生一份而不是直接改 PlayCountFold.key 的歌手口径:那个键是整本统计账的身份,
    /// 改了要 foldVersion +1 并把盘上几千条写法全量重折(见 loadTitleForms 的迁移分支);
    /// 而这里要的只是"查孪生时多看一眼隔壁桶",派生索引在内存里现算就够,零迁移风险。
    private var primaryCreditFamilies: [String: [TitleForm]] = [:]

    /// 从 titleForms 全量重建派生索引。titleForms 整体换过(加载/迁移)时调。
    private func rebuildPrimaryCreditFamilies() {
        var out: [String: [TitleForm]] = [:]
        for family in titleForms.values {
            for form in family { Self.insertForm(form, into: &out) }
        }
        primaryCreditFamilies = out
    }

    /// 往派生索引里塞一条写法(按 歌手|歌名 小写键去重),加载与增量收割共用。
    private static func insertForm(_ form: TitleForm, into index: inout [String: [TitleForm]]) {
        let key = PlayCountFold.familyKey(artist: form.artist, title: form.title)
        let raw = playCountKey(artist: form.artist, title: form.title)
        var fam = index[key] ?? []
        guard !fam.contains(where: { playCountKey(artist: $0.artist, title: $0.title) == raw })
        else { return }
        fam.append(form)
        index[key] = fam
    }

    /// 把实时行刚取到的**新鲜合并总数**写进历史行用的 trackPlayCounts。
    ///
    /// 2026-08-21 用户报「第 15 次听下面紧跟着第 21 次听」查出来的:两条路径用的是两份数据 ——
    /// 实时行每次换歌**现取**(refreshNowPlayingCount),历史行读缓存,而那份缓存只在"页内
    /// 出现次数变多"时作废、连播同一首歌时会冻结。这次取数本来就付过了,顺手刷新是白捡的。
    ///
    /// 写本尊 + 全部孪生键:这张表存的就是**合并后的总数**、孪生行显示同一个数(见
    /// resolvePlayCounts 里那段注释),所以整族写同一个值才是自洽的。
    ///
    /// 语义对得上:trackPlayCounts 存"已落库的总次数",而 total 正是 userplaycount 的合并值
    /// (这次播放还没落库 —— 那 +1 是实时行自己加的,不写进表里)。
    ///
    /// 同时把 newestPlaySeen 里这一族的基线清掉:这次播放随后落库时,那条"出现了更新的
    /// 同曲收听"判据才会认出它、把这个数再刷一次。不清的话新落库那条会被当成"已经算过了"。
    private func adoptFreshTotal(_ total: Int, artist: String, title: String,
                                 siblings: [(artist: String, title: String)]) {
        var keys = [Self.playCountKey(artist: artist, title: title)]
        keys += siblings.map { Self.playCountKey(artist: $0.artist, title: $0.title) }
        for k in Set(keys) {
            trackPlayCounts[k] = total
            newestPlaySeen[k] = nil
            // 之前被判"那边没有这一项"的,拿到真数就该解除 —— 否则它永远不再取。
            playCountUnavailable.remove(k)
        }
        scheduleSnapshotSave()
    }

    /// 「第 N 次听」的孪生实体候选。索引就绪 → 历史真实写法族(去掉本尊,封顶 8);
    /// 索引未建成(首次全量拉取中/失败过)→ 退回猜枚举,行为与索引之前完全一致。
    private func playCountSiblings(artist: String, title: String) -> [(artist: String, title: String)] {
        if !titleFormsLoaded { loadTitleForms() }
        guard titleFormsSyncedThrough > 0 else {
            return PlayCountVariants.siblings(artist: artist, title: title)
        }
        let selfKey = Self.playCountKey(artist: artist, title: title)
        // 查的是派生索引:同一首歌的"A & B"和"A"两种 credit 落在同一个桶里,两边都能
        // 看见对方,于是两行显示的次数是同一个合计数(不会一行 2 次、一行 1 次)。
        let family = primaryCreditFamilies[
            PlayCountFold.familyKey(artist: artist, title: title)] ?? []
        return family
            .filter { Self.playCountKey(artist: $0.artist, title: $0.title) != selfKey }
            .prefix(8)
            .map { ($0.artist, $0.title) }
    }

    /// 把一条真实出现过的写法收进索引(按 歌手|歌名 小写键去重)。
    private func harvestTitleForm(artist: String, title: String) {
        guard !artist.isEmpty, !title.isEmpty else { return }
        if !titleFormsLoaded { loadTitleForms() }
        let key = PlayCountFold.key(artist: artist, title: title)
        let raw = Self.playCountKey(artist: artist, title: title)
        var family = titleForms[key] ?? []
        guard !family.contains(where: { Self.playCountKey(artist: $0.artist, title: $0.title) == raw })
        else { return }
        let form = TitleForm(artist: artist, title: title)
        family.append(form)
        titleForms[key] = family
        // 派生索引跟着增量更新 —— 少了这一步,App 运行期间新收割到的写法要等下次启动
        // 重新加载才能参与合并。
        Self.insertForm(form, into: &primaryCreditFamilies)
        scheduleTitleFormsSave()
    }

    /// 索引冷启动/增量补漏。全部页成功才推进水位;任一页失败保持原水位,下次再来。
    private func ensureTitleFormsIndex() {
        if !titleFormsLoaded { loadTitleForms() }
        guard let cred = credentials, !titleFormsSyncing else { return }
        let full = titleFormsSyncedThrough <= 0
        if !full, let last = titleFormsLastTopUp, Date().timeIntervalSince(last) < 15 * 60 { return }
        titleFormsSyncing = true
        titleFormsLastTopUp = Date()
        let from = full ? 1 : Int(titleFormsSyncedThrough)
        let startedAt = Date().timeIntervalSince1970
        Task {
            defer { titleFormsSyncing = false }
            var page = 1
            var totalPages = 1
            while page <= totalPages && page <= 400 {
                guard let obj = await request(method: "user.getrecenttracks", cred: cred,
                                              extra: ["limit": "200", "page": "\(page)", "from": "\(from)"]),
                      let rt = obj["recenttracks"] as? [String: Any],
                      let attr = rt["@attr"] as? [String: Any]
                else { return }
                totalPages = Int((attr["totalPages"] as? String) ?? "1") ?? 1
                var tracks = (rt["track"] as? [[String: Any]]) ?? []
                if tracks.isEmpty, let single = rt["track"] as? [String: Any] { tracks = [single] }
                for t in tracks {
                    guard let name = t["name"] as? String,
                          let art = (t["artist"] as? [String: Any])?["#text"] as? String else { continue }
                    harvestTitleForm(artist: art, title: name)
                }
                page += 1
                if page <= totalPages { try? await Task.sleep(nanoseconds: 150_000_000) }
            }
            titleFormsSyncedThrough = startedAt
            scheduleTitleFormsSave()
            if full {
                // 索引首次就绪:此前猜枚举口径的总数已经落后 —— 整表作废,按写法族重取
                trackPlayCounts = [:]
                playCountUnavailable = []
                resolvePlayCounts(for: recent)
            }
        }
    }

    private func loadTitleForms() {
        titleFormsLoaded = true
        guard let cred = credentials,
              let data = try? Data(contentsOf: Self.titleFormsURL),
              let snap = try? JSONDecoder().decode(TitleFormsSnapshot.self, from: data),
              snap.username == cred.user   // 换过账号不吃旧索引
        else { return }
        if snap.foldVersion == PlayCountFold.foldVersion {
            // 折叠规则没变:盘上的键就是当前规则算出来的(保存路径永远写当前规则的键),
            // 直接采用 —— 2026-08-19 性能审计点 #1:此前每次启动都对全部写法重折
            // (2400+ 条 × 每条数次 ICU 繁简 transform,约百毫秒),全压在主线程的
            // 首次触碰上;版本一致时这笔账一分不用付。
            titleForms = snap.forms
            rebuildPrimaryCreditFamilies()
        } else {
            // 折叠规则变过(或旧文件没有版本字段):按当前规则从真实写法重算全部键,
            // 一次性迁移 —— 不用重新全量拉几百页,写法总量几千条,纯本地计算;迁移完
            // 随手落盘(带上新版本号),下次启动走上面的免算路径。
            var refolded: [String: [TitleForm]] = [:]
            for family in snap.forms.values {
                for form in family {
                    let key = PlayCountFold.key(artist: form.artist, title: form.title)
                    let raw = Self.playCountKey(artist: form.artist, title: form.title)
                    var fam = refolded[key] ?? []
                    guard !fam.contains(where: { Self.playCountKey(artist: $0.artist, title: $0.title) == raw })
                    else { continue }
                    fam.append(form)
                    refolded[key] = fam
                }
            }
            titleForms = refolded
            rebuildPrimaryCreditFamilies()
            scheduleTitleFormsSave()
        }
        titleFormsSyncedThrough = snap.syncedThrough
    }

    /// 防抖落盘,编码+写文件挪出主线程 —— 同 scheduleSnapshotSave 的取舍。
    private func scheduleTitleFormsSave() {
        titleFormsSaveTask?.cancel()
        titleFormsSaveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let cred = credentials else { return }
            let snap = TitleFormsSnapshot(
                username: cred.user, syncedThrough: titleFormsSyncedThrough, forms: titleForms,
                foldVersion: PlayCountFold.foldVersion)
            let url = Self.titleFormsURL
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snap) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    // MARK: - 快照(stale-while-revalidate)

    /// 重启后信息页原来要空窗几秒等五个请求 —— 把上一次的数字/榜单/头像/封面落盘,
    /// 启动时先端上桌,刷新照常在后台跑(2026-08-11 发散采纳)。快照就是缓存,删了无损。
    private struct StatsSnapshot: Codable {
        var username: String
        var overview: Overview?
        var recent: [RecentTrack]
        /// 老快照留下的阶梯档位,现已改分页(2026-08-12)。字段保留为可选只为让老快照
        /// 仍能解出来,值不再使用。
        var recentLimit: Int?
        var charts: [String: [ChartEntry]]
        var artistAvatars: [String: URL]
        var trackCovers: [String: URL]
        /// 老快照没有这几个字段,解码时给空表(不能让整份快照因为缺它而解不出来)。
        var trackPlayCounts: [String: Int]?
        var recentTrackCovers: [String: URL]?
        var recentAlbumCovers: [String: URL]?
        /// 第⑤级(Apple Music 目录)查回来的封面。查一次要一个 iTunes 请求,不持久化的话
        /// 每次冷启动整页缺图的行都要重查一轮。
        var catalogCovers: [String: URL]?
        /// 次数表的口径版本:11 = 第三批的修正(裸场次标记不归一等,见 foldVersion 注释);
        /// 10 = 同日第三批(**用户拍板**:R1 守卫套到原串 + 版本尾缀分隔符
        /// 归一 + 罗马字歌手名别名归一);9 = 同日第二批(破折号版本尾缀 `Bad - 2012 Remaster` + with
        /// 头词黑名单);8 = 目录学噪音口径补齐到参考实现(with 客串署名 + bonus track
        /// + explicit,2026-08-22 用户报《一路向北 (bonus track)》第 2 次 vs《一路向北》14 次);
        /// 7 = 合唱 credit 归并(2026-08-20);6 = 目录学噪音副题折叠扩到 feat 客串署名家族(盖世英雄
        /// (feat. 欧阳靖 & 李岩) 并入 蓋世英雄,2026-08-19 第二波);5 = 写法索引合并 +
        /// remaster 噪音折叠(Automatic (Remastered 2014) 并入 Automatic,2026-08-19);
        /// 4 = 按写法索引(历史真实写法族,PlayCountFold)合并后的总数(2026-08-19)。
        /// 缺失/更小 = 旧口径 —— 加载时把次数表整个作废重取。索引首次建成时运行期也会
        /// 整表作废一次(见 ensureTitleFormsIndex),这里的版本管的是**跨启动**的同一件事。
        /// 老快照里的 hanMergedCounts 布尔字段不再读取,解码时被忽略即视为旧口径。
        var mergedCountsVersion: Int?
    }

    private static let snapshotURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-lastfm-stats-cache.json")
    private var snapshotSaveTask: Task<Void, Never>?

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snap = try? JSONDecoder().decode(StatsSnapshot.self, from: data) else { return }
        // 换过账号就不吃旧快照 —— 那是前任的数据
        guard let cred = credentials, cred.user == snap.username else { return }
        overview = snap.overview
        recent = snap.recent
        // 快照里存的永远是第一页(见 scheduleSnapshotSave),重开也从第一页看起
        recentPage = 1
        charts = snap.charts
        artistAvatars = snap.artistAvatars
        trackCovers = snap.trackCovers
        // 旧口径的次数不端上桌 —— 见 mergedCountsVersion 字段注释
        // 10 = R1 守卫套到原串 + 版本尾缀分隔符归一 + 罗马字歌手别名(2026-08-22 第三批);
        // 9 = 破折号版本尾缀 + with 头词黑名单(2026-08-22 第二批);
        // 8 = 目录学噪音补齐到参考实现(with/bonus track/explicit,2026-08-22);
        // 7 = 合唱 credit 归并(2026-08-20 加,见 primaryCreditFamilies);6 = 索引口径 +
        // 目录学噪音折叠。⚠️ 改动合并口径必须 +1,否则存量缓存里按旧口径算出来的数会一直
        // 端上桌 —— 实测《Toronto 2014》两本账各存着 1,不作废就永远显示「第 1 次听」。
        trackPlayCounts = snap.mergedCountsVersion == 11 ? (snap.trackPlayCounts ?? [:]) : [:]
        recentTrackCovers = snap.recentTrackCovers ?? [:]
        recentAlbumCovers = snap.recentAlbumCovers ?? [:]
        catalogCovers = snap.catalogCovers ?? [:]
        // 本机封面兜底不进快照 —— 它是从 enrich 缓存现算的,存下来只会存一份可能已经过期的
        // 副本。但**必须在这里补算一次**:这条路径不经过 applyRecent,冷启动那一屏就是快照
        // 里的行,不算的话本机能给出封面的行要一直灰到下一次联网刷新回来才补上。
        refreshLocalCovers()
        // 同理:冷启动那一屏的实时行也要能复用快照里这些行的封面,不能等联网刷新回来
        rebuildRecentCoverIndex()
        // 快照里的图提前解码进内存:否则冷启动第一次打开这一页,每张图都要先画一帧占位符
        // 再从 URLCache 里异步取(见 ImageMemoryCache.prewarm)。
        ImageMemoryCache.shared.prewarm(
            Array(artistAvatars.values) + Array(recentTrackCovers.values)
                + Array(recentAlbumCovers.values) + Array(catalogCovers.values)
                + charts.values.flatMap { $0.compactMap(\.imageURL) }
                + recent.compactMap(\.imageURL))
        // fetchedAt 刻意留空:所有刷新照常发生,快照只是首屏的底
    }

    /// 防抖落盘:一轮刷新会连着改好几个字段,攒 2 秒写一次;nowplaying 行是瞬时状态,
    /// 不落盘(重启后它十有八九已经不是真的)。
    private func scheduleSnapshotSave() {
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let cred = credentials else { return }
            // 只快照第一页:快照是给"重开时先端上桌"用的,端一页历史上来没有意义
            guard recentPage == 1 else { return }
            // 只带**这一页用得上的**次数/封面下快照。这三张表在内存里随"听过多少歌、翻过
            // 多少页"只增不减,整份写盘的话文件会月复一月长大,而快照的用途只是"重开时先把
            // 第一页端上桌",多出来的键一个也用不上(2026-08-12 审阅指出的无界增长)。
            let rows = recent.filter { $0.date != nil }
            var keptCounts: [String: Int] = [:]
            var keptCovers: [String: URL] = [:]
            var keptAlbumCovers: [String: URL] = [:]
            var keptCatalogCovers: [String: URL] = [:]
            for r in rows {
                let key = Self.playCountKey(artist: r.artist, title: r.title)
                if let n = trackPlayCounts[key] { keptCounts[key] = n }
                if let c = recentTrackCovers[key] { keptCovers[key] = c }
                if let c = catalogCovers[key] { keptCatalogCovers[key] = c }
                if let ak = Self.albumKey(artist: r.artist, album: r.album), let c = recentAlbumCovers[ak] {
                    keptAlbumCovers[ak] = c
                }
            }
            let snap = StatsSnapshot(
                username: cred.user, overview: overview,
                recent: rows,
                recentLimit: nil,
                charts: charts, artistAvatars: artistAvatars, trackCovers: trackCovers,
                trackPlayCounts: keptCounts,
                recentTrackCovers: keptCovers, recentAlbumCovers: keptAlbumCovers,
                catalogCovers: keptCatalogCovers,
                mergedCountsVersion: 11)
            // 编码 + 落盘挪出主线程:这个类是 @MainActor,Task{} 会继承它的隔离,原来
            // JSONEncoder 和同步的 atomic 写(临时文件 + rename)全压在主线程上(审阅指出)。
            let url = Self.snapshotURL
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snap) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    // MARK: - 凭据

    /// 用户名以**授权返回的**为准(scrobbleUsername),空了才退回手填时代的 lastfmUser
    /// —— 跟卡片头部"已连接:X"的展示优先级一致。原来这里反着排(lastfmUser 优先),
    /// 两个字段都有值且不同时,头部显示 A、下面统计的却是 B 的账号(审阅确认)。
    /// Key 优先账号卡那把,退回老的只读 Key,同 collector 侧 lastfmBridgeAPIKey()。
    private var credentials: (user: String, key: String)? {
        let c = ConfigStore.shared
        let user = c.lastfmScrobbleUsername.isEmpty ? c.lastfmUser : c.lastfmScrobbleUsername
        let key = c.lastfmScrobbleAPIKey.isEmpty ? c.lastfmAPIKey : c.lastfmScrobbleAPIKey
        guard !user.isEmpty, !key.isEmpty else { return nil }
        return (user, key)
    }

    // MARK: - 拉取

    /// 档案数字 + 最近记录。TTL 内重复调用是空操作;force 无视 TTL(换歌触发的
    /// 刷新用 —— 刚唱完的那首就该马上出现,不该被缓存挡两分钟)。
    func refreshBaseline(force: Bool = false) {
        // 写法索引的冷启动/增量补漏挂在这条页面主刷新路径上(内部自带单飞+节流)
        ensureTitleFormsIndex()
        if force { fetchedAt["baseline"] = nil }
        guard fresh("baseline", ttl: baselineTTL) == false else { return }
        guard let cred = credentials else { return }
        fetchedAt["baseline"] = Date()
        baselineGen += 1
        let gen = baselineGen
        Task {
            baselineFailed = false
            // 总数不用单独打 user.getinfo:下面拉最近记录那次(不带 from)的 @attr.total
            // 本来就是全量 scrobble 数,一个请求两用,4 个请求并成 3 个(审阅指出)。
            async let recentJSON = request(method: "user.getrecenttracks", cred: cred,
                                           extra: ["limit": String(Self.recentPageSize),
                                                   "page": String(recentPage)])
            // 两个计数:recenttracks 带 from 时,@attr.total 就是区间内的条数,limit=1
            // 让响应体最小。
            let dayStart = Calendar.current.startOfDay(for: Date())
            async let todayJSON = request(method: "user.getrecenttracks", cred: cred,
                                          extra: ["limit": "1", "from": String(Int(dayStart.timeIntervalSince1970))])
            async let weekJSON = request(method: "user.getrecenttracks", cred: cred,
                                         extra: ["limit": "1", "from": String(Int(Date().timeIntervalSince1970 - 7 * 86400))])
            let (r, t, w) = await (recentJSON, todayJSON, weekJSON)
            guard gen == baselineGen else { return } // 已有更新一代在飞/已完成,这批作废
            guard let r, let t, let w else {
                baselineFailed = true
                fetchedAt["baseline"] = nil // 失败不占用 TTL,重试立刻能发
                return
            }
            overview = Overview(
                total: attrTotal(r),
                today: attrTotal(t),
                week: attrTotal(w)
            )
            applyRecent(parseRecent(r))
            applyRecentPaging(r) // 总页数只在响应里,首次加载这条路径也得取(翻页控件靠它才出现)
            scheduleSnapshotSave()
        }
    }

    /// 专辑名归一(大小写/首尾空白不算差异)。空名返回 nil —— 空专辑不该互相共享封面。
    /// 专辑封面表的键。**必须带歌手** —— 只用专辑名的话是个全局命名空间,两个不同歌手
    /// 的同名专辑会互相覆盖,第三级兜底就会拿到别人专辑的封面,还会随快照长期留存
    /// (2026-08-12 性能/正确性审阅指出)。
    nonisolated static func albumKey(artist: String, album: String?) -> String? {
        guard let a = album?.trimmingCharacters(in: .whitespaces), !a.isEmpty else { return nil }
        return artist.trimmingCharacters(in: .whitespaces).lowercased() + "|" + a.lowercased()
    }

    /// 一行最近记录该用哪张封面:自带的(scrobble 记录里的真图)→ **本机缓存里 collector
    /// 解析出的那张** → getinfo 纠正后的曲目封面 → 同专辑兄弟曲目的封面。四级都没有才留空位。
    ///
    /// 第二级 2026-08-14 补上。原来四级里没有任何一级来自本机:全是 Last.fm,而 Last.fm 对
    /// 中文曲库缺图非常常见 —— 用户报的「陶喆 - 聖誕之吻」三级全空(Last.fm 只有那张所有
    /// 缺图实体共用的白星占位图,被 imageURL() 正确滤掉),而同一张专辑网易云是有图的,
    /// collector 播放时早就解析并存进 enrich 缓存了,只是这个列表从来没查过。
    ///
    /// 放在第二级而不是第一级:scrobble 自带图能用的行就别换了(换了只是徒增变化,26pt
    /// 的显示尺寸也看不出清晰度差别);但要排在两级 Last.fm 网络兜底**之前** —— 本地
    /// 命中就不必再为这一行发 getinfo 请求了,见 resolvePlayCounts 里的 hasCover。
    func coverURL(for track: RecentTrack) -> URL? {
        if let own = track.imageURL {
            // 自带图**不是无条件优先**(2026-08-20 加这道口子):同一首歌被两种歌手写法
            // 拆成两个 Last.fm 实体时,两边挂的图可能不是同一张 —— 实测《Toronto 2014》
            // 从 Mac 进来记在「Daniel Caesar & Mustafa」名下、挂的是单曲封面(深蓝纹章),
            // 从手机桥接进来那次记在「Daniel Caesar」名下、挂的是 NEVER ENOUGH 专辑封面,
            // 于是同一张专辑连播的列表里孤零零混进一张别的图。
            //
            // 判据是"同专辑的其它行怎么挂"(≥2 行一致才算共识,见 ArtistCredit),不是
            // "本机缓存说什么" —— 只纠正**跟同伴不一致**的那一行,不整体改变封面来源。
            if let key = ArtistCredit.albumConsensusKey(artist: track.artist, album: track.album),
               let consensus = albumConsensusCovers[key], consensus != own {
                return consensus
            }
            return own
        }
        if let local = localCovers[Self.playCountKey(artist: track.artist, title: track.title)] {
            return local
        }
        if let byTrack = recentTrackCovers[Self.playCountKey(artist: track.artist, title: track.title)] {
            return byTrack
        }
        if let key = Self.albumKey(artist: track.artist, album: track.album),
           let byAlbum = recentAlbumCovers[key] { return byAlbum }
        // 第⑤级:Apple Music 目录(iTunes Search)。2026-08-22 加 —— 前四级里只有本机
        // enrich 缓存覆盖得了「Last.fm 对中文曲库缺图」这一大类,而那一级**只有本机播过
        // 才有数据**:iPhone 听的歌、翻历史页看到的老歌天生在它的盲区里。实测抽样 205 首
        // 里 25% 缺图,其中 getinfo(第③级)只救回 20%、同专辑兄弟(第④级)一张都救不到
        // (整张 live 专辑都没图时没有兄弟可参照)。
        // 排最后:前四级任一命中就不发这个请求,且匹配不上时留空位而不是硬塞一张,
        // 挑选规则见 MusicCatalogSearch.pickArtwork。
        return catalogCovers[Self.playCountKey(artist: track.artist, title: track.title)]
    }

    /// 第⑤级:Apple Music 目录查回来的封面(键跟 playCountKey 同口径)。
    ///
    /// 跟前四级的分工:①行自带图、③getinfo、④同专辑兄弟 都来自 Last.fm,②来自本机
    /// collector 解析。这一级是唯一「Last.fm 没有、本机也没播过」时还能出图的来源。
    /// 进快照持久化 —— 查一次要一个 iTunes 请求,翻页来回不该重查。
    @Published private(set) var catalogCovers: [String: URL] = [:]
    /// 问过 Apple Music、那边也匹配不上的行。**匹配不上就留空位**,不退回搜索结果第一条
    /// (实测那样会给《微醺卡带 - 情非得已 (微醺版)》配上完全无关的封面)。
    /// 只在请求**成功返回**但挑不出条目时才记,超时/限流留给下次重试。
    private var catalogCoverUnavailable = Set<String>()
    private var catalogCoversInFlight = Set<String>()
    /// 每一轮最多为几行查 Apple Music。iTunes Search 没有公开配额,社区实测约 20 次/分钟,
    /// 而缺图的行可能占满一整页 —— 分几轮慢慢补,别一次把额度打光(封面是锦上添花,
    /// 拖几轮没关系)。
    private static let catalogCoverBatch = 6

    /// 本机 enrich 缓存能给出封面的行(键跟 playCountKey 同口径)。
    ///
    /// 在 applyRecent 里一次性算好,而不是让视图每行现查:EnrichCacheReader 每次调用都要
    /// stat 一次缓存文件判 mtime,而这个列表一页 100 行、每 45 秒重绘一轮。
    private(set) var localCovers: [String: URL] = [:]

    /// 重算本机封面兜底。覆盖**列表上所有会显示封面的行**:最近记录那一页 +「那年今日」
    /// 那三首。
    ///
    /// 2026-08-17 从"只算传进来的那一批行"改成固定算这两处的并集。原来只有 applyRecent
    /// 会调它、传进来的永远是最近记录那一页,于是「那年今日」的行在 coverURL(for:) 里
    /// **实际只有第一级(scrobble 自带图)有效** —— 后三级依赖的三张表(localCovers /
    /// recentTrackCovers / recentAlbumCovers)全部只由最近记录那条路径填,那年今日的曲目
    /// 从来没被喂进去过。第一级一旦是 Last.fm 的占位星(被 imageURL() 正确滤成 nil),
    /// 这一行就只能是灰块:2026-08-17 用户报的「活該 / David Tao」就是这么来的。
    ///
    /// 整体替换而不是往里 merge 的理由没变:这张表要跟着"当前屏幕上有哪些行"走,
    /// merge 会让它随翻页无界增长。
    /// 本机 enrich 缓存上次算 localCovers 时的 mtime。
    private var localCoversStamp: Date?

    /// 缓存文件变了就重算本机封面兜底表。
    ///
    /// ⚠️ 为什么需要单独一条路:refreshLocalCovers() 原来**只**在真的应用了一次 Last.fm
    /// 响应时才跑(applyRecent / 那年今日 / 读盘缓存三处)。而本机 enrich 缓存是**自己**会
    /// 变的 —— collector 解析出封面、或者同专辑预取一次灌进来一整张专辑,都不伴随任何
    /// Last.fm 响应。于是列表上那些行会一直是灰块,直到下一次真的有响应被应用。
    ///
    /// 2026-08-19 用户报「这些为什么没有封面」查到的就是这个:那 8 首 周杰倫《Jay》的曲目
    /// 在 21:14:01~21:14:21 被一次同专辑预取灌进本机缓存(带可用的 Apple 封面,实测
    /// HTTP 200),而截图是 21:19 —— 缓存里早就有了,列表却没重算过这张表。
    ///
    /// 只 stat 一次文件,内容没变就直接返回,所以可以挂在定时轮上。
    /// ⚠️ stamp 必须用**已解码代**的版本(decodedContentVersion),不能用文件即时 mtime
    /// (2026-08-20 对抗核实):Reader 改后台解码后,拿文件 mtime 当 stamp 会在"写盘了但
    /// 还没解码采纳"的窗口里把这次变化盖章烧掉——空闲态(没有 poll 在推进解码)collector
    /// 的落盘在统计页就永远看不到了。先 refreshIfNeeded() 让 Reader 自己推进(空闲态这里
    /// 就是唯一的推进者),再按已解码版本判变化。
    func refreshLocalCoversIfCacheChanged() {
        EnrichCacheReader.refreshIfNeeded()
        let stamp = EnrichCacheReader.decodedContentVersion
        guard stamp != localCoversStamp else { return }
        localCoversStamp = stamp
        refreshLocalCovers()
    }

    private func refreshLocalCovers() {
        var out: [String: URL] = [:]
        for r in recent + (onThisDay?.top.map(\.track) ?? []) {
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            guard out[key] == nil else { continue }
            if let url = EnrichCacheReader.coverURL(artist: r.artist, title: r.title, album: r.album ?? "") {
                out[key] = url
            }
        }
        localCovers = out
    }

    /// 「正在记录」那一行要复用的封面:列表里**这首歌 / 这张专辑**的历史行此刻正在显示的
    /// 那一张。跟 localCovers 一样不标 @Published —— 它永远跟着 recent /
    /// recentTrackCovers / recentAlbumCovers 这些 @Published 字段同批更新,那几个发出的
    /// objectWillChange 已经能让实时行重算 body、读到新值。
    ///
    /// 2026-08-17 加。在这之前实时行的封面走的是**另一条链路**:直接拿本机播放器的位图
    /// (poller.artworkImage —— media-control 从 Apple Music 的 Now Playing 会话读到的
    /// 600×600 图),而它下面那些历史行走 coverURL(for:)(第一级就是 Last.fm scrobble
    /// 自带的 174px 图)。两条链路互不知情,于是同一首歌在同一张卡里是两张不同的图 ——
    /// 用户报的「当前播放这首的封面跟历史的不一样,等它播完变成历史就又一样了」。
    ///
    /// 实测(2026-08-17,Prince《1999》)这两张确实不是同一个文件,也不只是清晰度差别:
    /// Apple 那版偏暗紫、Last.fm 那版偏亮蓝,各自缩到界面上的 26pt 一眼就能看出色调不同。
    private(set) var recentCoverByTrack: [String: URL] = [:]
    private(set) var recentCoverByAlbum: [String: URL] = [:]

    /// 重建上面那两张索引。凡是会改变 coverURL(for:) 结果的事情落地后都得调一次:
    /// 换了一批行、getinfo 补回封面、本机缓存重算。
    ///
    /// 为什么建索引而不是让实时行现扫 recent:实时行是全 Section 里唯一订阅
    /// PlaybackCoordinator 的视图,它的 body 跟着播放状态高频重算(歌词推进、重锚都会发),
    /// 在里面线性扫 20 行、每行再做两次字符串归一是白烧 —— 跟 localCovers 同一个理由。
    /// 同专辑共识封面(2026-08-20):键按「合唱 credit 归到主歌手 + 专辑名」聚,值是这张
    /// 专辑在当前这一页里出现最多的那张 scrobble 自带图(至少两行一致才算)。见
    /// ArtistCredit.albumConsensusCovers 与 coverURL(for:) 里的用法。
    ///
    /// 跟 recentAlbumCovers 是两回事:那个是"这张专辑有没有一张能借用的图"(补给压根
    /// 没图的行),这个是"这张专辑的图应该长什么样"(纠正挂错图的行)。
    private var albumConsensusCovers: [String: URL] = [:]

    private func rebuildRecentCoverIndex() {
        // 共识只看**行自带的图**:它要回答的问题是"Last.fm 给同一张专辑的各行挂了什么",
        // 掺进本机缓存/getinfo 的兜底图就变成拿两套来源互相投票,得不出干净结论。
        albumConsensusCovers = ArtistCredit.albumConsensusCovers(
            rows: recent.map { (artist: $0.artist, album: $0.album, image: $0.imageURL) })
        var byTrack: [String: URL] = [:]
        var byAlbum: [String: URL] = [:]
        for r in recent where !r.nowPlaying {
            guard let url = coverURL(for: r) else { continue }
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            if byTrack[key] == nil { byTrack[key] = url }
            // 同一张专辑取**最近的**那一行(recent 是倒序,首见即最新):整张专辑连播时,
            // 实时行跟着列表顶上那几行走。
            if let ak = Self.albumKey(artist: r.artist, album: r.album), byAlbum[ak] == nil {
                byAlbum[ak] = url
            }
        }
        recentCoverByTrack = byTrack
        recentCoverByAlbum = byAlbum
    }

    /// 「正在记录」这一行该用哪张封面。nil = 列表里没有可参照的行,由调用方回落到本机位图。
    ///
    /// 两级:先按歌手+歌名,再退到同一张专辑。第二级不是可有可无的兜底,而是常态 ——
    /// 本机播放器报的歌名跟 Last.fm 的规范名经常对不上(实测 Apple Music 报
    /// 「Something in the Water」,Last.fm 那边叫「Something In The Water (Does Not
    /// Compute)」,归一后仍然不等),第一级直接 miss;而两边的专辑名是一致的。
    func liveCoverURL(artist: String, title: String, album: String) -> URL? {
        if let url = recentCoverByTrack[Self.playCountKey(artist: artist, title: title)] { return url }
        if let ak = Self.albumKey(artist: artist, album: album) { return recentCoverByAlbum[ak] }
        return nil
    }

    /// 曲目在播放次数表里的键:大小写/首尾空白不算差异(跟红点的宽松比对同一套口径)。
    nonisolated static func playCountKey(artist: String, title: String) -> String {
        artist.trimmingCharacters(in: .whitespaces).lowercased()
            + "|" + title.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func applyRecent(_ rows: [RecentTrack]) {
        // Last.fm 侧漏进来的广告 nowplaying 行不展示(2026-08-19,两轮:「—」行 + 带全
        // 字段的 Blinds.com 行)。三个判据:歌手为空/标题是占位符「—」(真实 scrobble 必带
        // 歌手);以及**本机此刻正播着广告且同名** —— 广告可以带全 artist/title,只有本机
        // (AppleScript 权威判据,见 LocalPlaybackSource)知道它是广告。collector 侧已经
        // 不再上报,这里是显示端兜底:已发到 Last.fm 的 nowplaying 收不回,过渡期不能原样
        // 端给用户。
        let localAdKey: String? = {
            let pc = PlaybackCoordinator.shared
            guard pc.isCurrentTrackAdBreak else { return nil }
            return Self.playCountKey(artist: pc.artist, title: pc.title)
        }()
        let rows = rows.filter { r in
            guard r.nowPlaying else { return true }
            if r.artist.isEmpty || r.title == "—" { return false }
            if let localAdKey, Self.playCountKey(artist: r.artist, title: r.title) == localAdKey {
                return false
            }
            return true
        }
        // 写法索引的常态收割:这批行是**真实出现过**的写法,顺手入索引(见 harvestTitleForm)
        for r in rows where !r.artist.isEmpty && !r.title.isEmpty {
            harvestTitleForm(artist: r.artist, title: r.title)
        }
        // 同一首歌在窗口里多出一次收听 → 它的总数已经变了,作废让它重取。三条判据,
        // 前两条跟上一轮比、第三条只看当下这一页,理由分别见下。
        //
        // key → 任一行:作废孪生键要用行上的原始 歌手/歌名 生成变体(key 已折小写,
        // 但变体生成对大小写不敏感,folded 键一致即可)。
        var sample: [String: RecentTrack] = [:]
        for r in rows where !r.nowPlaying {
            let k = Self.playCountKey(artist: r.artist, title: r.title)
            if sample[k] == nil { sample[k] = r }
        }
        let newestNow = Self.newestPlayByKey(rows)
        var staleKeys = Set<String>()
        // 判据①②要跟**上一轮**比,只在窗口大小没变时成立(翻页那一下换的是完全不同的
        // 一批行,那个比较没有意义)。
        if lastAppliedRecentPage == recentPage {
            let before = countByKey(recent)
            // ① 页内出现次数变多。
            //
            // ⚠️ 只有这一条会漏掉一整类情况(2026-08-21 用户报「第 15 次听下面紧跟着第 21
            // 次听」)。countByKey 数的是**当前这一页里出现了几次**,而连着重播同一首歌时
            // 这一页很快被它占满 —— 新的挤进来、旧的挤出去,页内次数**不再增长**,于是这个
            // 条件永远为假、缓存总数永久冻结,而真实次数一路往上爬。用户那次实测:缓存冻在
            // 15,真实合计 22(园游会 10 + 園遊會 12 两个 Last.fm 实体)。
            staleKeys.formUnion(countByKey(rows).compactMap { key, n in
                n > (before[key] ?? 0) ? key : nil
            })
            // ② 这首歌最新一条收听的时刻往前走了 = 多听了一次。这一条不会随页面被同一首歌
            // 占满而失效。两条并存 —— 老快照(没有 newestPlaySeen 基线)仍按①走,不留空档。
            for (key, newest) in newestNow {
                guard let seen = newestPlaySeen[key], newest > seen else { continue }
                staleKeys.insert(key)
            }
        }
        // ③ 页内自相矛盾(2026-08-22)。①②都依赖跨轮次的内存基线,而次数表是**持久化**的
        // —— App 重启、或统计页关着的那段时间之后基线被重设成「当下」,只要那首歌不再被播
        // 一次,盘上冻住的旧数字就永远不会被作废。这一条不跟历史比、无状态,重启后第一轮
        // 就生效,专门补这个稳态盲区。翻页时同样成立(它不依赖"上一轮是同一页")。
        staleKeys.formUnion(contradictedPlayCountKeys(rows, now: Date()))
        // 基线**无条件**记下 —— 它只是"我上次看到这个 key 的最新收听是什么时候",跟这一轮
        // 判不判作废无关。原来这行埋在上面那个 if 里,于是重启后第一轮(lastAppliedRecentPage
        // 还是 0)整段被跳过、连基线都没记上,要到第三轮才真正开始作废,比注释里写的"第一次
        // 只记基线"多了一轮。
        // 取 max 而不是直接覆盖:翻到历史页时那一页的"最新"是很老的时刻,直接覆盖会把基线
        // **调低**,翻回第一页就凭空多判一次过期(无害,但白发一轮请求)。
        for (key, newest) in newestNow where (newestPlaySeen[key] ?? .distantPast) < newest {
            newestPlaySeen[key] = newest
        }
        for key in staleKeys {
            trackPlayCounts[key] = nil
            // 次数表里存的是写法孪生**合并后**的总数:这边多了一次,孪生行缓存的
            // 总数同样过期,一并作废。变体生成落空时退化成等那行自己的 key 被作废
            // —— 尽力而为,不影响正确性。
            if let r = sample[key] {
                for sib in playCountSiblings(artist: r.artist, title: r.title) {
                    trackPlayCounts[Self.playCountKey(artist: sib.artist, title: sib.title)] = nil
                }
            }
        }
        lastAppliedRecentPage = recentPage
        recentUpdatedAt = Date()
        recent = rows
        // 本机封面兜底跟着这一批行重算一次。放在这里而不是视图里,理由见 localCovers。
        refreshLocalCovers()
        rebuildRecentCoverIndex()
        let next = rows.first(where: \.nowPlaying)
        let nextKey = next.map { "\($0.artist)|\($0.title)" }
        let prevKey = apiNowPlaying.map { "\($0.artist)|\($0.title)" }
        if nextKey != prevKey {
            apiNowPlayingSince = next == nil ? nil : Date()
        }
        apiNowPlaying = next
        resolvePlayCounts(for: rows)
        // 第⑤级排在最后,内部靠 coverUnavailable 自己等前四级落定(见 resolveCatalogCovers)。
        resolveCatalogCovers(for: rows)
    }

    /// 每个 key 在这一批行里**最新**那条收听的时刻。给上面那条"多听了一次"的作废判据用 ——
    /// 它不像"页内出现次数"那样会随页面被同一首歌占满而饱和。
    ///
    /// nowPlaying 那条不算:它还没落库,不在 userplaycount 里(实时行自己 +1)。
    /// 纯函数,selftest 直接覆盖。
    /// 纯算术在 LyrimuseCore.PlayCountRecency(selftest 直接覆盖那一份),这里只负责
    /// 把行映射成 (key, date) —— 顺手滤掉 nowPlaying 那条(还没落库,不在 userplaycount 里)。
    nonisolated static func newestPlayByKey(_ rows: [RecentTrack]) -> [String: Date] {
        PlayCountRecency.newest(rows.filter { !$0.nowPlaying }.map {
            (key: playCountKey(artist: $0.artist, title: $0.title), date: $0.date)
        })
    }

    /// 上一次 applyRecent 时,每个 key 已知的最新收听时刻。只在内存里 —— 重启后第一次
    /// applyRecent 只是把基线记下来(不作废),之后新增的收听才触发。不持久化是刻意的:
    /// 持久化它意味着重启即判"全部过期",一页 100 行会一次性打出 100 个 getinfo 撞限速。
    ///
    /// ⚠️ 它只在内存、而 trackPlayCounts 是持久化的,这个错配留下一个**稳态**盲区:重启后
    /// 基线被重设成「当下」,那首歌不再被播一次的话,盘上冻住的旧数字永远等不到作废。判据③
    /// (contradictedPlayCountKeys)是专门补这个洞的,别把它当可有可无的加强项删掉。
    private var newestPlaySeen: [String: Date] = [:]

    /// 第⑤级封面兜底:给前四级全空的行去 Apple Music 目录查一张。
    ///
    /// ⚠️ 触发条件里的 `coverUnavailable.contains(key)` 是**时序闸**,不是可有可无的优化:
    /// 第③级(getinfo)是异步的,页面刚打开那一瞬间 recentTrackCovers / recentAlbumCovers
    /// 都还空着,这时判"四级全空"会把整页都算进来、白发一屏 iTunes 请求。等 getinfo 回来
    /// 并把这一行记进 coverUnavailable(= 那边确实没有)才动手,前四级就已经落定了。
    /// 代价是比 getinfo 晚一轮出图,换来的是不抢跑、不浪费额度。
    private func resolveCatalogCovers(for rows: [RecentTrack]) {
        let storefront = Locale.current.region?.identifier.lowercased() ?? "us"
        var seen = Set<String>()
        let all = rows.compactMap { r -> (key: String, artist: String, title: String, album: String?)? in
            guard !r.nowPlaying, !r.artist.isEmpty, !r.title.isEmpty else { return nil }
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            guard coverURL(for: r) == nil,          // 前四级(含第⑤级自身)都没有
                  coverUnavailable.contains(key),   // getinfo 已经问过、那边确实没有
                  !catalogCoverUnavailable.contains(key),
                  !catalogCoversInFlight.contains(key),
                  seen.insert(key).inserted
            else { return nil }
            return (key, r.artist, r.title, r.album)
        }
        // 收成 Array 再截:下面的 addNext 按 0 起的下标取,ArraySlice 的下标随起点走 ——
        // 这里的 prefix 恰好从头开始所以等价,但别把这个巧合留给下一次改动。
        let targets = Array(all.prefix(Self.catalogCoverBatch))
        guard !targets.isEmpty else { return }
        targets.forEach { catalogCoversInFlight.insert($0.key) }
        Task {
            defer { targets.forEach { catalogCoversInFlight.remove($0.key) } }
            var found: [String: URL] = [:]
            var missed = Set<String>()
            // 并发 2:比 getinfo 那边(4)更保守 —— iTunes Search 的限流比 Last.fm 紧,
            // 而这是最后一级兜底,慢一点没有代价。
            await withTaskGroup(of: (String, MusicCatalogSearch.ArtworkMatch?, Bool).self) { group in
                var index = 0
                func addNext() {
                    guard index < targets.count else { return }
                    let item = targets[index]
                    index += 1
                    group.addTask {
                        let hit = await MusicCatalogSearch.resolveArtwork(
                            title: item.title, artist: item.artist, album: item.album,
                            storefront: storefront)
                        return (item.key, hit, true)
                    }
                }
                for _ in 0..<min(2, targets.count) { addNext() }
                for await (key, hit, ok) in group {
                    if let hit {
                        found[key] = hit.url
                        logger.notice("catalog cover: \(hit.confidence.rawValue, privacy: .public) for \(key, privacy: .public)")
                    } else if ok {
                        // 成功返回但挑不出能对上的条目 = 那边确实没有这一首,别每轮重问。
                        missed.insert(key)
                    }
                    addNext()
                }
            }
            if !found.isEmpty {
                catalogCovers.merge(found) { _, new in new }
                // 实时行复用的那两张索引由 coverURL(for:) 派生,这一级填了要跟着重建
                rebuildRecentCoverIndex()
                scheduleSnapshotSave()
            }
            catalogCoverUnavailable.formUnion(missed)
        }
    }

    /// 每个 key 上一次真的问过 Last.fm 要次数的时刻。给判据③做节流。
    ///
    /// ⚠️ **刻意不持久化**,跟 newestPlaySeen 相反的理由:这里要的就是"重启后为空",
    /// 好让盘上那个可能已经冻住的旧数字在第一轮就被质疑一次。持久化它等于把盲区又焊回去。
    private var playCountFetchedAt: [String: Date] = [:]

    /// 判据③命中后的重查节流。Last.fm 的 userplaycount 本身滞后几分钟(见
    /// playCountZeroGraceSecs),刚 scrobble 完重取回来还是同一个数、下一轮又矛盾 ——
    /// 不节流就是每轮刷新(baselineTTL 110s)都白发一个请求、永不收敛。
    private static let playCountContradictionRecheckSecs: TimeInterval = 5 * 60

    /// 判据③:这一页自己就能证伪缓存的那些 key。推导见 PlayCountRecency.contradicted。
    ///
    /// 按**折叠族**数页内收听数,不按 playCountKey 数 —— trackPlayCounts 存的是整族合并
    /// 总数,LastfmStatsSection.recentRows 的减法也按族数,三处必须同一把尺子。
    private func contradictedPlayCountKeys(_ rows: [RecentTrack], now: Date) -> Set<String> {
        var onPage: [String: Int] = [:]
        for r in rows where !r.nowPlaying {
            onPage[PlayCountFold.familyKey(artist: r.artist, title: r.title), default: 0] += 1
        }
        var out = Set<String>()
        for r in rows where !r.nowPlaying {
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            guard let cached = trackPlayCounts[key], !out.contains(key) else { continue }
            let family = PlayCountFold.familyKey(artist: r.artist, title: r.title)
            guard PlayCountRecency.contradicted(
                    onPage: onPage[family] ?? 0, cachedTotal: cached,
                    lastFetched: playCountFetchedAt[key], now: now,
                    recheckAfter: Self.playCountContradictionRecheckSecs)
            else { continue }
            out.insert(key)
        }
        return out
    }

    private func countByKey(_ rows: [RecentTrack]) -> [String: Int] {
        var out: [String: Int] = [:]
        for r in rows where !r.nowPlaying {
            out[Self.playCountKey(artist: r.artist, title: r.title), default: 0] += 1
        }
        return out
    }

    /// 给最近记录里还没有次数的曲目补 userplaycount。一首一个 track.getinfo(Last.fm 没有
    /// 批量接口),故并发压到 4 —— 展开到 100 条时这是一百个请求,放开跑会撞限速(约 5 req/s),
    /// 而这些数字是锦上添花,不值得为它把整页的额度吃掉。失败静默:那一行不显示次数即可。
    private func resolvePlayCounts(for rows: [RecentTrack]) {
        guard let cred = credentials else { return }
        var seen = Set<String>()
        let now = Date()
        let missing = rows.compactMap { r -> (key: String, artist: String, title: String,
                                              album: String?, wantsCount: Bool,
                                              zeroIsFinal: Bool)? in
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            // 次数还缺、且没被判定为"那边没有"
            let needsCount = trackPlayCounts[key] == nil && !playCountUnavailable.contains(key)
            // 封面还缺:四级兜底任一有值就不必为封面发请求 —— 自带图/本机缓存/同专辑兄弟
            // 都算数,否则封面明明已经显示出来了还在每轮重查(审阅指出的放大器)。
            // localCovers 这一项 2026-08-14 补:漏了它的话本机已经给出封面的行还会继续
            // 每轮发 getinfo,白烧 Last.fm 的限速额度。
            let hasCover = r.imageURL != nil || localCovers[key] != nil || recentTrackCovers[key] != nil
                || catalogCovers[key] != nil
                || Self.albumKey(artist: r.artist, album: r.album).map { recentAlbumCovers[$0] != nil } ?? false
            let needsCover = !hasCover && !coverUnavailable.contains(key)
            guard needsCount || needsCover, !playCountsInFlight.contains(key),
                  seen.insert(key).inserted, !r.artist.isEmpty, !r.title.isEmpty else { return nil }
            // 这一行是不是"够老":刚 scrobble 完的行拿到 0 不能当真(见 playCountUnavailable
            // 的注释)。nowPlaying 行没有时间戳,按最新处理。
            let age = r.date.map { now.timeIntervalSince($0) } ?? 0
            return (key, r.artist, r.title, r.album, needsCount,
                    age >= Self.playCountZeroGraceSecs)
        }
        guard !missing.isEmpty else { return }
        missing.forEach { playCountsInFlight.insert($0.key) }
        Task {
            defer { missing.forEach { playCountsInFlight.remove($0.key) } }
            var index = 0
            // 元组多带三项:artist(专辑键要用)、ok(请求本身成不成功 —— 只有成功返回
            // 才能断言"那边没有这一项",超时/限流不能记进 unavailable)和 wantsCount
            // (这一趟是不是为了取次数 —— 只为补封面的重查**不许**碰次数表,否则会拿
            // 本尊单账的数把已缓存的繁简合并总数冲掉)
            await withTaskGroup(of: (String, String, String?, Bool, Int?, URL?, Bool, Bool).self) { group in
                let maxConcurrent = 4
                func addNext() {
                    guard index < missing.count else { return }
                    let item = missing[index]
                    index += 1
                    group.addTask { [weak self] in
                        guard let self else {
                            return (item.key, item.artist, item.album, false, nil, nil,
                                    item.wantsCount, item.zeroIsFinal)
                        }
                        let json = await self.request(method: "track.getinfo", cred: cred,
                                                      extra: ["artist": item.artist, "track": item.title,
                                                              "autocorrect": "1", "username": cred.user])
                        guard let json else {
                            return (item.key, item.artist, item.album, false, nil, nil,
                                    item.wantsCount, item.zeroIsFinal)
                        }
                        let parsed = await MainActor.run { () -> (Int?, URL?, String?) in
                            let n = (self.dig(json, "track", "userplaycount") as? String).flatMap { Int($0) }
                            // 规范身份(纠正后的 歌手|歌名),给下面的孪生查询做同实体比对
                            var identity: String?
                            if let name = self.dig(json, "track", "name") as? String,
                               let art = self.dig(json, "track", "artist", "name") as? String {
                                identity = Self.playCountKey(artist: art, title: name)
                            }
                            // 封面从纠正后的规范专辑实体上取 —— scrobble 自带的那张多半是占位星星。
                            return (n, self.imageURL(self.dig(json, "track", "album", "image")), identity)
                        }
                        // 写法孪生实体(括号风格/去副题/繁简,见 PlayCountVariants 注释)
                        // 在 Last.fm 各记各的账 —— 实测《一口(The Day You Left Me)》半角
                        // 25 次/全角 2 次/纯名 1 次。逐个问、按规范身份去重后求和,表里存
                        // **合并后的总数**,孪生行显示同一个数。孪生查询不另设缓存:总数随
                        // trackPlayCounts/快照一起缓存,失败退化成少算那一本。身份去重防
                        // 两类翻倍:孪生写法不存在时 autocorrect 折回本尊,以及两个变体折
                        // 到同一个第三实体。
                        var count = parsed.0
                        if item.wantsCount {
                            var identities = Set<String>()
                            if let id = parsed.2 { identities.insert(id) }
                            for sib in await self.playCountSiblings(artist: item.artist, title: item.title) {
                                let twin = await self.userPlayCount(artist: sib.artist, title: sib.title,
                                                                    cred: cred)
                                guard let tc = twin.count, let tid = twin.identity,
                                      identities.insert(tid).inserted else { continue }
                                count = (count ?? 0) + tc
                            }
                        }
                        // 这一首在这个歌手名下没有专辑图 —— 换成 Last.fm 认的规范歌手名再试
                        // 一次。写成 if 而不是 ??:后者的右侧是 autoclosure,不能 await。
                        var cover = parsed.1
                        if cover == nil {
                            cover = await self.coverByCorrectedArtist(
                                artist: item.artist, title: item.title, cred: cred)
                        }
                        return (item.key, item.artist, item.album, true, count, cover,
                                item.wantsCount, item.zeroIsFinal)
                    }
                }
                // 结果先攒在本地,循环结束再一次性合并写回:@Published 字典每写一次就发一次
                // objectWillChange,而这些结果按网络节奏跨秒到达、SwiftUI 合并不了,逐条写
                // 就是二十次整段重渲染(审阅坐实)。
                var counts: [String: Int] = [:]
                var covers: [String: URL] = [:]
                var albumCovers: [String: URL] = [:]
                var noCount = Set<String>()
                var noCover = Set<String>()
                var countFetched = Set<String>()
                for _ in 0..<min(maxConcurrent, missing.count) { addNext() }
                for await (key, artist, album, ok, n, cover, wantsCount, zeroIsFinal) in group {
                    // wantsCount 守卫:只为补封面的那趟不碰次数表,理由见上面元组注释。
                    if wantsCount {
                        // 判据③的节流基准:记的是"为它问过一次次数",不是"问到了" ——
                        // 只有请求真的成功返回才算(超时/限流不该顶着节流让下一轮不敢重试)。
                        if ok { countFetched.insert(key) }
                        if let n, n > 0 {
                            counts[key] = n
                        } else if ok, zeroIsFinal {
                            // 只有**够老**的行拿到 0 才算定论。刚 scrobble 完的 0 是
                            // Last.fm 还没并账,记进去就永久放弃了(见 playCountUnavailable)。
                            noCount.insert(key)
                        }
                    }
                    if let cover {
                        covers[key] = cover
                        // 同一张专辑的其它行(包括 getinfo 压根没返回专辑的那些)共用它
                        if let ak = Self.albumKey(artist: artist, album: album) { albumCovers[ak] = cover }
                    } else if ok {
                        noCover.insert(key)
                    }
                    addNext()
                }
                if !counts.isEmpty { trackPlayCounts.merge(counts) { _, new in new } }
                if !covers.isEmpty { recentTrackCovers.merge(covers) { _, new in new } }
                if !albumCovers.isEmpty { recentAlbumCovers.merge(albumCovers) { _, new in new } }
                playCountUnavailable.formUnion(noCount)
                coverUnavailable.formUnion(noCover)
                if !countFetched.isEmpty {
                    let stamp = Date()
                    for key in countFetched { playCountFetchedAt[key] = stamp }
                }
                // coverUnavailable 刚更新 = 第⑤级的时序闸刚放行,立刻给它一次机会。
                // 不在这里调的话要等下一轮 applyRecent(110s),首次出图白等两分钟。
                // resolveCatalogCovers 自带 inFlight/unavailable 守卫,重复调用无害。
                if !noCover.isEmpty { resolveCatalogCovers(for: rows) }
                // 有行刚补上封面 → 实时行复用的那两张索引跟着作废重建
                if !covers.isEmpty || !albumCovers.isEmpty { rebuildRecentCoverIndex() }
            }
            scheduleSnapshotSave()
        }
    }

    // MARK: - 歌手名纠正(封面的最后一招)

    /// 歌手名 → Last.fm 认的规范名。"" = 问过了,那边没有可纠正的(或者请求失败)。
    private var artistCorrections: [String: String] = [:]
    /// 同一个歌手正在飞的那次 getcorrection。最近记录一页里同一位歌手往往连着好几首,
    /// 不去重的话它们会各发一次一模一样的请求。
    private var artistCorrectionTasks: [String: Task<String, Never>] = [:]

    /// getinfo 给不出专辑图时的最后一招:把歌手名换成 Last.fm 认的规范名,再查一遍。
    ///
    /// 为什么 autocorrect=1 不够(2026-08-17 实测):autocorrect 只在"这个 track 实体不
    /// 存在"时才改写查询,而 `David Tao / 活該` 在 Last.fm 上**确实是一个存在的实体**,
    /// 只是它没有专辑图 —— 于是 autocorrect 原样放行,回来一个 album 为 null 的结果,
    /// 四级兜底全部落空,那一行就是灰块(用户报的就是这一首)。换成规范名 `陶喆 / 活該`
    /// 再查同一首歌就有图,而 artist.getcorrection 正是 Last.fm 官方给这件事的接口,
    /// 它对 David Tao 直接回答陶喆。
    ///
    /// ⚠️ 只取封面,**不取** userplaycount:两个实体的次数是分开记的(实测 David Tao 那边
    /// 25 次、陶喆那边 11 次),拿纠正后的数字覆盖会把「第 N 次听」显示错。
    private func coverByCorrectedArtist(artist: String, title: String,
                                        cred: (user: String, key: String)) async -> URL? {
        let corrected = await correctedArtistName(artist, cred: cred)
        guard !corrected.isEmpty, corrected != artist else { return nil }
        guard let json = await request(method: "track.getinfo", cred: cred,
                                       extra: ["artist": corrected, "track": title,
                                               "autocorrect": "1"])
        else { return nil }
        return imageURL(dig(json, "track", "album", "image"))
    }

    private func correctedArtistName(_ artist: String,
                                     cred: (user: String, key: String)) async -> String {
        if let cached = artistCorrections[artist] { return cached }
        if let running = artistCorrectionTasks[artist] { return await running.value }
        let task = Task { [weak self] () -> String in
            guard let self else { return "" }
            let json = await self.request(method: "artist.getcorrection", cred: cred,
                                          extra: ["artist": artist])
            guard let json else { return "" }
            return self.dig(json, "corrections", "correction", "artist", "name") as? String ?? ""
        }
        artistCorrectionTasks[artist] = task
        let name = await task.value
        // 请求失败也记空:失败就当"没有别名可试",不为一张锦上添花的封面反复重试。
        artistCorrections[artist] = name
        artistCorrectionTasks[artist] = nil
        return name
    }

    /// Last.fm 的 nowplaying 条目在播放停止后**不会**立刻消失(服务端按自己的节奏过期,
    /// 常能残留好几分钟)。拿它当"正在记录"显示就必须自己设一个上限,否则手机早停了、
    /// 这边还红着说正在记录。以"我们第一次看到这首"为起点计时:对开页面前就开始放的
    /// 那首,这个起点偏晚,但它要的只是一个"别一直挂着"的封顶,不是精确播放时长。
    static let apiNowPlayingMaxAge: TimeInterval = 15 * 60

    /// 「那年今日」取当天记录的分页参数。200 是 Last.fm recenttracks 单页上限;
    /// 3 页 = 600 次播放,比任何一天的真实收听量都宽裕。
    private let onThisDayPageSize = 200
    private let onThisDayMaxPages = 3
    var apiNowPlayingIsFresh: Bool {
        guard apiNowPlaying != nil, let since = apiNowPlayingSince else { return false }
        return Date().timeIntervalSince(since) < Self.apiNowPlayingMaxAge
    }

    /// 翻到第 page 页(1 起)。页码在成功后才算数:失败回滚,不让翻页控件停在一个
    /// 内容根本没换过的页码上(沿用 expandRecent 那次审阅定下的规矩)。
    func goToPage(_ page: Int) {
        let target = max(1, min(page, max(recentTotalPages, 1)))
        guard target != recentPage, !recentPaging else { return }
        let prev = recentPage
        recentPage = target
        recentPaging = true
        baselineGen += 1
        let gen = baselineGen
        Task {
            defer { recentPaging = false }
            guard let cred = credentials,
                  let json = await request(method: "user.getrecenttracks", cred: cred,
                                           extra: ["limit": String(Self.recentPageSize),
                                                   "page": String(target)])
            else {
                if gen == baselineGen { recentPage = prev }
                return
            }
            guard gen == baselineGen else { return }
            applyRecent(parseRecent(json))
            applyRecentPaging(json)
            scheduleSnapshotSave()
            fetchedAt["baseline"] = Date() // 刚拉过,定时器下一拍不用再拉一遍
        }
    }

    /// 从响应的 @attr 里取总页数。缺字段就保持原值,不把它当 1(那会让翻页按钮消失)。
    private func applyRecentPaging(_ json: [String: Any]) {
        if let s = dig(json, "recenttracks", "@attr", "totalPages") as? String, let n = Int(s), n > 0 {
            recentTotalPages = n
        }
    }

    func refreshChart(kind: ChartKind, period: Period) {
        let key = "\(kind.rawValue)|\(period.rawValue)"
        guard fresh(key) == false else { return }
        guard let cred = credentials else { return }
        fetchedAt[key] = Date()
        // 歌手榜不直连 API:Last.fm 的原始记录会把同一个真人拆成多条(中英文艺名
        // "Dean Ting"/"丁世光"、繁简"周杰倫"/"周杰伦"、合唱 credit "Prince & The
        // Revolution"),走 collector 的 top-artists 子命令拿**合并后**的榜 —— 那边复用
        // 网页版 Top 歌手已经在用的并查集(名字键+mbid,见 topartists.go),不在 Swift
        // 里重抄繁简表/别名表。专辑/歌曲榜没有这个问题,照旧直连。
        if kind == .artists {
            refreshMergedArtistChart(cacheKey: key, period: period)
            return
        }
        Task {
            chartLoadingKeys.insert(key)
            chartFailedKeys.remove(key)
            defer { chartLoadingKeys.remove(key) }
            guard let json = await request(method: kind.method, cred: cred,
                                           extra: ["period": period.rawValue, "limit": "10"])
            else {
                chartFailedKeys.insert(key)
                fetchedAt[key] = nil
                return
            }
            let (outer, inner) = kind.listPath
            let items = (dig(json, outer, inner) as? [[String: Any]]) ?? []
            var entries: [ChartEntry] = []
            entries.reserveCapacity(items.count)
            for (idx, item) in items.enumerated() {
                let name = item["name"] as? String ?? ""
                guard !name.isEmpty else { continue }
                let detail = dig(item, "artist", "name") as? String ?? ""
                let count = Int(item["playcount"] as? String ?? "") ?? 0
                // 只有专辑封面是真的,歌手/歌曲的 image 是占位星,直接不取
                let image = kind == .albums ? imageURL(item["image"]) : nil
                entries.append(ChartEntry(rank: idx + 1, name: name, detail: detail,
                                          playcount: count, imageURL: image))
            }
            charts[key] = entries
            scheduleSnapshotSave()
            // 歌手榜在上面就分流去 refreshMergedArtistChart 了,这条 Task 只会是
            // 专辑/歌曲 —— 头像解析在那边触发,这里只管歌曲封面。
            if kind == .tracks {
                resolveTrackCovers(entries, cred: cred)
            }
        }
    }

    /// 给一批歌曲榜条目补真封面。并发全放开也就 10 个轻量 JSON 请求,Last.fm 的
    /// 限速(约 5 req/s)对这个量级无感;失败静默 —— 封面是锦上添花。
    private func resolveTrackCovers(_ entries: [ChartEntry], cred: (user: String, key: String)) {
        let missing = entries.filter { trackCovers["\($0.detail)|\($0.name)"] == nil }
        guard !missing.isEmpty else { return }
        Task {
            await withTaskGroup(of: (String, URL?).self) { group in
                for e in missing {
                    group.addTask { [weak self] in
                        let key = "\(e.detail)|\(e.name)"
                        guard let self else { return (key, nil) }
                        let json = await self.request(method: "track.getinfo", cred: cred,
                                                      extra: ["artist": e.detail, "track": e.name,
                                                              "autocorrect": "1"])
                        guard let json else { return (key, nil) }
                        let image = await MainActor.run {
                            self.imageURL(self.dig(json, "track", "album", "image"))
                        }
                        return (key, image)
                    }
                }
                for await (key, url) in group {
                    if let url { trackCovers[key] = url }
                }
            }
            scheduleSnapshotSave()
        }
    }

    private func refreshMergedArtistChart(cacheKey: String, period: Period) {
        let collectorPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/collector").path
        chartLoadingKeys.insert(cacheKey)
        chartFailedKeys.remove(cacheKey)
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: collectorPath)
            // -all-periods:四个时段一次进程拿全(Go 侧四路并发取数),切时段零等待、
            // 也免了每档各一次 spawn + 磁盘加载(2026-08-11 发散采纳)。
            process.arguments = ["top-artists", "-all-periods", "-limit", "10"]
            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe
            var rows: [String: [[String: Any]]] = [:]
            do {
                try process.run()
                // 看门狗:子命令自己有 15 秒网络超时,25 秒还没退就是卡死了 —— 不杀的话
                // readDataToEndOfFile 永远不返回,这个榜单转圈到天荒地老,fetchedAt 还把
                // 重试锁 15 分钟(2026-08-11 审阅确认)。terminate 后读端拿到 EOF,走下面
                // 的解码失败路径,fetchedAt 被清掉,下次能重试。
                let watchdog = Task.detached {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    if !Task.isCancelled, process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                guard process.terminationStatus == 0,
                      let arr = try JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]]
                else {
                    // 失败时把子命令的 stderr 带进日志 —— 原来丢 nullDevice,collector 侧
                    // log.Fatal 的死因(配置缺失/网络全挂)从这边完全看不见(审阅指出)。
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8)?.prefix(300) ?? ""
                    logger.notice("top-artists failed (exit \(process.terminationStatus)): \(String(err), privacy: .public)")
                    throw CocoaError(.fileReadCorruptFile)
                }
                rows = arr
            } catch {
                await MainActor.run {
                    let svc = LastfmStatsService.shared
                    svc.chartLoadingKeys.remove(cacheKey)
                    svc.chartFailedKeys.insert(cacheKey)
                    svc.fetchedAt[cacheKey] = nil
                }
                return
            }
            var byKey: [String: [ChartEntry]] = [:]
            for (pd, periodRows) in rows {
                byKey["\(ChartKind.artists.rawValue)|\(pd)"] = periodRows.enumerated().compactMap { idx, row -> ChartEntry? in
                    guard let name = row["name"] as? String, !name.isEmpty else { return nil }
                    let count = row["playCount"] as? Int ?? 0
                    return ChartEntry(rank: idx + 1, name: name, detail: "", playcount: count, imageURL: nil)
                }
            }
            let filled = byKey
            await MainActor.run {
                let svc = LastfmStatsService.shared
                svc.chartLoadingKeys.remove(cacheKey)
                let now = Date()
                for (key, entries) in filled {
                    svc.charts[key] = entries
                    svc.fetchedAt[key] = now // 四档全部盖到 TTL,切时段不再各自重拉
                }
                // 用户正看的时段可能不在返回里(单时段失败被 Go 侧跳过):按失败态给重试入口
                if filled[cacheKey] == nil {
                    svc.chartFailedKeys.insert(cacheKey)
                    svc.fetchedAt[cacheKey] = nil
                }
                // 头像只解析当前时段的名字 —— 其它时段大量重合,切过去时按需补(有磁盘缓存)
                if let visible = filled[cacheKey] {
                    svc.resolveAvatars(names: visible.map(\.name))
                }
                svc.scheduleSnapshotSave()
            }
        }
    }

    /// 让 collector 去查一批歌手头像。失败静默 —— 头像是锦上添花,查不到就显示首字母,
    /// 不值得占一条错误提示。
    private func resolveAvatars(names: [String]) {
        let missing = names.filter { artistAvatars[$0] == nil }
        guard !missing.isEmpty else { return }
        let collectorPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/collector").path
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: collectorPath)
            process.arguments = ["artist-avatars"] + missing
            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                logger.notice("artist-avatars: launch failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            // 看门狗:冷缓存串行解析 10 个名字最坏约一分钟(每名 6s 超时),75 秒兜底,
            // 只防真正卡死的进程,不误杀正常的冷启动。
            let watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                if !Task.isCancelled, process.isRunning { process.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            guard let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?.prefix(300) ?? ""
                logger.notice("artist-avatars failed (exit \(process.terminationStatus)): \(String(err), privacy: .public)")
                return
            }
            await MainActor.run {
                for (name, url) in map where !url.isEmpty {
                    if let u = URL(string: url) { LastfmStatsService.shared.artistAvatars[name] = u }
                }
                LastfmStatsService.shared.scheduleSnapshotSave()
            }
        }
    }

    // MARK: - 解析

    private func parseRecent(_ json: [String: Any]) -> [RecentTrack] {
        let items = (dig(json, "recenttracks", "track") as? [[String: Any]]) ?? []
        var dupCount: [String: Int] = [:]
        return items.compactMap { item in
            let title = item["name"] as? String ?? ""
            guard !title.isEmpty else { return nil }
            let artist = dig(item, "artist", "#text") as? String ?? ""
            let uts = dig(item, "date", "uts") as? String
            // 只在"同一时刻+同一首歌"之间编号,不受整表位置影响(见 RecentTrack.dup)
            let dupKey = "\(uts ?? "np")|\(artist)|\(title)"
            let dup = dupCount[dupKey, default: 0]
            dupCount[dupKey] = dup + 1
            return RecentTrack(
                dup: dup,
                title: title,
                artist: artist,
                album: dig(item, "album", "#text") as? String,
                imageURL: imageURL(item["image"]),
                date: uts.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    private func attrTotal(_ json: [String: Any]) -> Int {
        Int(dig(json, "recenttracks", "@attr", "total") as? String ?? "") ?? 0
    }

    /// image 字段是 [{size: small/medium/large/extralarge, "#text": url}],取 large。
    private func imageURL(_ value: Any?) -> URL? {
        guard let arr = value as? [[String: Any]] else { return nil }
        let by = { (size: String) in arr.first { ($0["size"] as? String) == size } }
        let url = (by("large") ?? by("extralarge") ?? arr.last)?["#text"] as? String ?? ""
        guard !url.isEmpty else { return nil }
        // Last.fm 的"万能占位图"(一颗白星,所有缺图的实体共用同一个文件名 hash)。
        // 它是一个能正常加载的 URL,不滤掉的话会顶掉首字母色块、显示成一块灰 ——
        // 2026-08-11 歌曲榜实测:關於愛的定義/花田錯 两行就是这么来的。
        guard !url.contains("2a96cbd8b46e442fc41c2b86b821562f") else { return nil }
        return URL(string: url)
    }

    private func dig(_ dict: [String: Any], _ path: String...) -> Any? {
        var cur: Any? = dict
        for key in path {
            cur = (cur as? [String: Any])?[key]
        }
        return cur
    }

    private func fresh(_ key: String, ttl overrideTTL: TimeInterval? = nil) -> Bool {
        guard let at = fetchedAt[key] else { return false }
        return Date().timeIntervalSince(at) < (overrideTTL ?? ttl)
    }

    private func request(method: String, cred: (user: String, key: String),
                         extra: [String: String] = [:]) async -> [String: Any]? {
        var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        var pairs: [(name: String, value: String)] = [
            ("method", method),
            ("user", cred.user),
            ("api_key", cred.key),
            ("format", "json"),
        ]
        // extra 是字典,遍历顺序每次都不同 —— 排一下,同一组参数才会拼出同一个 URL
        // (抓包/日志比对时不至于每次长得不一样)。Last.fm 读接口不签名,顺序不影响结果。
        for k in extra.keys.sorted() { pairs.append((k, extra[k]!)) }
        // ⚠️ 不用 comps.queryItems:它按 urlQueryAllowed 编码,那套集合**放行 `+`**,
        // 而这个端点会把 query value 多解一次码、把 `+` 当成空格 —— 含加号的歌名
        // (《夜曲+窃爱 (Live)》)于是永远 error 6。完整推导和实测见 LastfmQuery。
        comps.percentEncodedQuery = LastfmQuery.queryString(pairs)
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                logger.notice("\(method, privacy: .public): http \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            // Last.fm 的错误多以 200 + {"error":N} 返回(API key 失效就是这形态)。不识别
            // 它的话,失效的 key 会让页面显示"0 scrobble/还没有记录"——一套看起来很确定、
            // 实际全错的数据,比失败态糟糕得多(审阅确认)。
            if let errCode = obj?["error"] as? Int {
                logger.notice("\(method, privacy: .public): api error \(errCode) \((obj?["message"] as? String) ?? "", privacy: .public)")
                return nil
            }
            return obj
        } catch {
            logger.notice("\(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
