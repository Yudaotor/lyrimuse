import Foundation
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
    /// getinfo 查不到数据的曲目(Last.fm 压根没有这条目)。记下来别每轮刷新都重查一遍。
    private var trackDetailsUnavailable = Set<String>()
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
    /// 那年今日:去年(查不到再往前,最多三年)同一天的收听。整天没有记录则为 nil,卡片隐藏。
    @Published private(set) var onThisDay: OnThisDayResult?

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
    private let baselineTTL: TimeInterval = 2 * 60

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
        snapshotSaveTask?.cancel()
        try? FileManager.default.removeItem(at: Self.snapshotURL)
        charts = [:]
        artistAvatars = [:]
        trackCovers = [:]
        trackPlayCounts = [:]
        recentTrackCovers = [:]
        recentAlbumCovers = [:]
        trackDetailsUnavailable = []
        playCountsInFlight = []
        lastAppliedRecentPage = 0
        chartLoadingKeys = []
        chartFailedKeys = []
        baselineFailed = false
        recentPaging = false
        recentPage = 1
        recentTotalPages = 1
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
            let json = await request(method: "track.getinfo", cred: cred,
                                     extra: ["artist": artist, "track": title,
                                             "autocorrect": "1", "username": cred.user])
            guard nowPlayingCountKey == key, let json else { return }
            if let s = dig(json, "track", "userplaycount") as? String, let n = Int(s) {
                // userplaycount 是**过去**的次数,这一次还没被记进去 —— 所以是第 n+1 次
                nowPlayingCount = n + 1
            }
        }
    }

    /// 那年今日:去年同一天(0 点到 24 点)的收听。整天为空自动再往前一年,最多探三年,
    /// 全空保持 nil(卡片整个隐藏)。6 小时 TTL —— 一天之内内容不会变。
    func refreshOnThisDay() {
        guard fresh("onthisday", ttl: 6 * 3600) == false else { return }
        guard let cred = credentials else { return }
        fetchedAt["onthisday"] = Date()
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
                onThisDay = OnThisDayResult(yearsAgo: yearsAgo, total: total,
                                            top: Array(ranked.prefix(3)))
                return
            }
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
        trackPlayCounts = snap.trackPlayCounts ?? [:]
        recentTrackCovers = snap.recentTrackCovers ?? [:]
        recentAlbumCovers = snap.recentAlbumCovers ?? [:]
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
            let snap = StatsSnapshot(
                username: cred.user, overview: overview,
                recent: recent.filter { $0.date != nil },
                recentLimit: nil,
                charts: charts, artistAvatars: artistAvatars, trackCovers: trackCovers,
                trackPlayCounts: trackPlayCounts,
                recentTrackCovers: recentTrackCovers, recentAlbumCovers: recentAlbumCovers)
            guard let data = try? JSONEncoder().encode(snap) else { return }
            try? data.write(to: Self.snapshotURL, options: .atomic)
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
    nonisolated static func albumKey(_ album: String?) -> String? {
        guard let a = album?.trimmingCharacters(in: .whitespaces), !a.isEmpty else { return nil }
        return a.lowercased()
    }

    /// 一行最近记录该用哪张封面:自带的(scrobble 记录里的真图)→ getinfo 纠正后的曲目封面
    /// → 同专辑兄弟曲目的封面。三级都没有才留空位。
    func coverURL(for track: RecentTrack) -> URL? {
        if let own = track.imageURL { return own }
        if let byTrack = recentTrackCovers[Self.playCountKey(artist: track.artist, title: track.title)] {
            return byTrack
        }
        if let key = Self.albumKey(track.album) { return recentAlbumCovers[key] }
        return nil
    }

    /// 曲目在播放次数表里的键:大小写/首尾空白不算差异(跟红点的宽松比对同一套口径)。
    nonisolated static func playCountKey(artist: String, title: String) -> String {
        artist.trimmingCharacters(in: .whitespaces).lowercased()
            + "|" + title.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func applyRecent(_ rows: [RecentTrack]) {
        // 同一首歌在窗口里多出一次收听 → 它的总数已经变了,作废让它重取。只在窗口大小
        // 没变时判(翻页那一下换的是完全不同的一批行,那个比较没有意义)。
        if lastAppliedRecentPage == recentPage {
            let before = countByKey(recent)
            for (key, n) in countByKey(rows) where n > (before[key] ?? 0) {
                trackPlayCounts[key] = nil
            }
        }
        lastAppliedRecentPage = recentPage
        recent = rows
        let next = rows.first(where: \.nowPlaying)
        let nextKey = next.map { "\($0.artist)|\($0.title)" }
        let prevKey = apiNowPlaying.map { "\($0.artist)|\($0.title)" }
        if nextKey != prevKey {
            apiNowPlayingSince = next == nil ? nil : Date()
        }
        apiNowPlaying = next
        resolvePlayCounts(for: rows)
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
        let missing = rows.compactMap { r -> (key: String, artist: String, title: String, album: String?)? in
            let key = Self.playCountKey(artist: r.artist, title: r.title)
            // 次数和封面共用这一次请求,任一还缺就得查;查过一次没有数据的不再重查。
            let needs = trackPlayCounts[key] == nil || recentTrackCovers[key] == nil
            guard needs, !trackDetailsUnavailable.contains(key), !playCountsInFlight.contains(key),
                  seen.insert(key).inserted, !r.artist.isEmpty, !r.title.isEmpty else { return nil }
            return (key, r.artist, r.title, r.album)
        }
        guard !missing.isEmpty else { return }
        missing.forEach { playCountsInFlight.insert($0.key) }
        Task {
            defer { missing.forEach { playCountsInFlight.remove($0.key) } }
            var index = 0
            await withTaskGroup(of: (String, String?, Int?, URL?).self) { group in
                let maxConcurrent = 4
                func addNext() {
                    guard index < missing.count else { return }
                    let item = missing[index]
                    index += 1
                    group.addTask { [weak self] in
                        guard let self else { return (item.key, item.album, nil, nil) }
                        let json = await self.request(method: "track.getinfo", cred: cred,
                                                      extra: ["artist": item.artist, "track": item.title,
                                                              "autocorrect": "1", "username": cred.user])
                        guard let json else { return (item.key, item.album, nil, nil) }
                        let parsed = await MainActor.run { () -> (Int?, URL?) in
                            let n = (self.dig(json, "track", "userplaycount") as? String).flatMap { Int($0) }
                            // 封面从纠正后的规范专辑实体上取 —— scrobble 自带的那张多半是占位星星。
                            return (n, self.imageURL(self.dig(json, "track", "album", "image")))
                        }
                        return (item.key, item.album, parsed.0, parsed.1)
                    }
                }
                for _ in 0..<min(maxConcurrent, missing.count) { addNext() }
                for await (key, album, n, cover) in group {
                    if let n, n > 0 { trackPlayCounts[key] = n }
                    if let cover {
                        recentTrackCovers[key] = cover
                        // 同一张专辑的其它行(包括 getinfo 压根没返回专辑的那些)共用它
                        if let ak = Self.albumKey(album) { recentAlbumCovers[ak] = cover }
                    }
                    if n == nil, cover == nil { trackDetailsUnavailable.insert(key) }
                    addNext()
                }
            }
            scheduleSnapshotSave()
        }
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
        var items = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "user", value: cred.user),
            URLQueryItem(name: "api_key", value: cred.key),
            URLQueryItem(name: "format", value: "json"),
        ]
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
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
