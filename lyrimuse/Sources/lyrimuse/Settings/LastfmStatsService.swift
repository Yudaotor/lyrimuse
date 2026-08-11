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

    struct Overview: Equatable {
        var total: Int
        var today: Int
        var week: Int
    }

    struct ChartEntry: Identifiable, Equatable {
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

    struct RecentTrack: Identifiable, Equatable {
        let title: String
        let artist: String
        let imageURL: URL?
        /// nil = 这行是"正在播放"(Last.fm 把 nowplaying 行的 date 整个省掉)。
        let date: Date?
        var nowPlaying: Bool { date == nil }
        var id: String { "\(title)|\(artist)|\(date?.timeIntervalSince1970 ?? -1)" }
    }

    // MARK: - 状态

    @Published private(set) var overview: Overview?
    @Published private(set) var recent: [RecentTrack] = []
    /// 最近记录当前拉多少条:8 → 30 → 100 阶梯,由"显示更多"推进。存在服务里而不是
    /// 视图里 —— 2 分钟定时刷新和换歌强刷都走 refreshBaseline,得按用户已经展开到的
    /// 条数重拉,不能刷一次又缩回 8 条。
    @Published private(set) var recentLimit = 8
    /// "显示更多"正在加载(按钮转圈用)。跟 baselineFailed 分开:展开失败不该把整卡
    /// 换成失败态,已有的 8 条还好好的。
    @Published private(set) var recentExpanding = false
    /// kind|period → 榜单。切分段/时段时旧内容还在,不闪空。
    @Published private(set) var charts: [String: [ChartEntry]] = [:]
    @Published private(set) var chartLoading = false
    /// 歌手名 → 真头像 URL。由 collector 的 artist-avatars 子命令解析(QQ 音乐优先、
    /// Deezer 兜底,14 天磁盘缓存,见 avatarcli.go)——Last.fm API 的歌手图是占位星。
    /// 查不到的名字**不会**出现在这里,UI 自然回落到首字母色块。
    @Published private(set) var artistAvatars: [String: URL] = [:]
    /// "歌手|歌名" → 这首歌所属专辑的封面。歌曲榜的 API 图也是占位星,真封面得按首
    /// 调 track.getInfo 拿它的专辑图 —— 榜单到手后并发补一轮,查不到的(无专辑的单曲)
    /// 不进字典,UI 回落到首字母色块。
    @Published private(set) var trackCovers: [String: URL] = [:]
    @Published private(set) var baselineFailed = false
    @Published private(set) var chartFailed = false

    private var fetchedAt: [String: Date] = [:]
    /// 榜单的缓存时长 —— Top 榜一天都未必变一名,15 分钟足够。
    private let ttl: TimeInterval = 15 * 60
    /// 档案数字 + 最近记录的缓存时长。这块是页面上"活"的部分:刚听完的歌应该几分钟内
    /// 出现,页面常开时每次定时器到点也靠它放行,不能跟榜单共用 15 分钟。
    private let baselineTTL: TimeInterval = 2 * 60

    func chart(_ kind: ChartKind, _ period: Period) -> [ChartEntry]? {
        charts["\(kind.rawValue)|\(period.rawValue)"]
    }

    // MARK: - 凭据

    /// 用户名优先手填时代的 lastfmUser(桥接读的就是它),空了退回授权返回的用户名;
    /// Key 优先账号卡那把,退回老的只读 Key —— 跟 collector 侧 lastfmBridgeAPIKey()
    /// 同一套优先级。
    private var credentials: (user: String, key: String)? {
        let c = ConfigStore.shared
        let user = c.lastfmUser.isEmpty ? c.lastfmScrobbleUsername : c.lastfmUser
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
        Task {
            baselineFailed = false
            async let info = request(method: "user.getinfo", cred: cred)
            async let recentJSON = request(method: "user.getrecenttracks", cred: cred,
                                           extra: ["limit": String(recentLimit)])
            // 两个计数:recenttracks 带 from 时,@attr.total 就是区间内的条数,limit=1
            // 让响应体最小。
            let dayStart = Calendar.current.startOfDay(for: Date())
            async let todayJSON = request(method: "user.getrecenttracks", cred: cred,
                                          extra: ["limit": "1", "from": String(Int(dayStart.timeIntervalSince1970))])
            async let weekJSON = request(method: "user.getrecenttracks", cred: cred,
                                         extra: ["limit": "1", "from": String(Int(Date().timeIntervalSince1970 - 7 * 86400))])
            let (i, r, t, w) = await (info, recentJSON, todayJSON, weekJSON)
            guard let i, let r, let t, let w else {
                baselineFailed = true
                fetchedAt["baseline"] = nil // 失败不占用 TTL,重试立刻能发
                return
            }
            let total = Int(dig(i, "user", "playcount") as? String ?? "") ?? 0
            overview = Overview(
                total: total,
                today: attrTotal(t),
                week: attrTotal(w)
            )
            recent = parseRecent(r)
        }
    }

    /// "显示更多":把最近记录的条数推进到下一档并重拉。到顶(100)后调用是空操作,
    /// UI 侧到顶也不再显示按钮,这里只是兜底。
    func expandRecent() {
        let ladder = [8, 30, 100]
        guard let next = ladder.first(where: { $0 > recentLimit }) else { return }
        guard !recentExpanding else { return }
        recentLimit = next
        recentExpanding = true
        Task {
            defer { recentExpanding = false }
            guard let cred = credentials,
                  let json = await request(method: "user.getrecenttracks", cred: cred,
                                           extra: ["limit": String(next)])
            else { return }
            recent = parseRecent(json)
            fetchedAt["baseline"] = Date() // 刚拉过,定时器下一拍不用再拉一遍
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
            chartLoading = true
            chartFailed = false
            defer { chartLoading = false }
            guard let json = await request(method: kind.method, cred: cred,
                                           extra: ["period": period.rawValue, "limit": "10"])
            else {
                chartFailed = true
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
            if kind == .artists {
                resolveAvatars(names: entries.map(\.name))
            }
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
        }
    }

    private func refreshMergedArtistChart(cacheKey: String, period: Period) {
        let collectorPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/collector").path
        chartLoading = true
        chartFailed = false
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: collectorPath)
            process.arguments = ["top-artists", "-period", period.rawValue, "-limit", "10"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var rows: [[String: Any]] = []
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { throw CocoaError(.fileReadCorruptFile) }
                rows = arr
            } catch {
                await MainActor.run {
                    let svc = LastfmStatsService.shared
                    svc.chartLoading = false
                    svc.chartFailed = true
                    svc.fetchedAt[cacheKey] = nil
                }
                return
            }
            let entries = rows.enumerated().compactMap { idx, row -> ChartEntry? in
                guard let name = row["name"] as? String, !name.isEmpty else { return nil }
                let count = row["playCount"] as? Int ?? 0
                return ChartEntry(rank: idx + 1, name: name, detail: "", playcount: count, imageURL: nil)
            }
            await MainActor.run {
                let svc = LastfmStatsService.shared
                svc.chartLoading = false
                svc.charts[cacheKey] = entries
                svc.resolveAvatars(names: entries.map(\.name))
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
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                logger.notice("artist-avatars: launch failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            await MainActor.run {
                for (name, url) in map where !url.isEmpty {
                    if let u = URL(string: url) { LastfmStatsService.shared.artistAvatars[name] = u }
                }
            }
        }
    }

    // MARK: - 解析

    private func parseRecent(_ json: [String: Any]) -> [RecentTrack] {
        let items = (dig(json, "recenttracks", "track") as? [[String: Any]]) ?? []
        return items.compactMap { item in
            let title = item["name"] as? String ?? ""
            guard !title.isEmpty else { return nil }
            let artist = dig(item, "artist", "#text") as? String ?? ""
            let uts = dig(item, "date", "uts") as? String
            return RecentTrack(
                title: title,
                artist: artist,
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
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            logger.notice("\(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
