import Foundation

/// collector 落盘的 Last.fm「最近记录」feed(`lyrimuse-lastfm-recent-feed.json`,2026-09-03)。
///
/// 写入方是 collector 的桥接拉取(lyrimuse-collector/lastfmfeed.go):它本来就每 15 s
/// (空闲 60 s)拉一次 `user.getrecenttracks limit=50`,现在把结果原样落盘。App 侧读它代替
/// 自己直连轮询同一个接口——本机实测 App 那条链路(URLSession 走系统代理)p50 1.2 s、16%
/// 超时,collector 的 Go 直连 p50 0.4 s、~1% 失败;而且同一份数据两个进程各拉一遍本来就没有
/// 道理。字段名跟 Go 侧 `lastfmFeedFile` 逐字对应,改一边必须改另一边。
///
/// 这里只放**纯数据 + 纯算术**(解码、新鲜度判断、"今天听了几首"的派生),按本仓惯例好被
/// selftest 覆盖;文件监听/合并进界面状态在 App 侧 LastfmStatsService。
public struct LastfmRecentFeed: Equatable, Decodable, Sendable {
    public struct Track: Equatable, Decodable, Sendable {
        public let artist: String
        public let title: String
        public let album: String?
        /// Last.fm 给的 large 档图 URL,原样透传(可能是那颗"万能占位星",由消费方过滤)。
        public let image: String?
        /// scrobble 时刻(unix 秒);now-playing 行没有。
        public let uts: TimeInterval?

        public init(artist: String, title: String, album: String? = nil, image: String? = nil, uts: TimeInterval?) {
            self.artist = artist
            self.title = title
            self.album = album
            self.image = image
            self.uts = uts
        }
    }

    public let username: String
    /// collector 发起那次拉取的时刻(unix 秒)。
    public let fetchedAt: TimeInterval
    /// `@attr.total`:账号总 scrobble 数。
    public let total: Int
    public let nowPlaying: Track?
    /// 已完成的 scrobble,新→旧,≤50 条。
    public let tracks: [Track]

    public init(username: String, fetchedAt: TimeInterval, total: Int, nowPlaying: Track?, tracks: [Track]) {
        self.username = username
        self.fetchedAt = fetchedAt
        self.total = total
        self.nowPlaying = nowPlaying
        self.tracks = tracks
    }

    /// feed 多旧算"活着"。collector 内容没变时也至少每 60 s 心跳重写一次、空闲拉取周期 60 s,
    /// 两者相加再留余量:3 分钟内有过写入就认为 collector 在、数据可信;超过就当它不在,
    /// App 退回自己轮询(旧行为)。
    public static let freshWindow: TimeInterval = 180

    public func isFresh(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince1970 - fetchedAt
        return age >= 0 && age < Self.freshWindow
    }

    /// 从文件解码。任何形状不对 → nil(调用方视作"没有 feed")。
    public static func decode(_ data: Data) -> LastfmRecentFeed? {
        try? JSONDecoder().decode(LastfmRecentFeed.self, from: data)
    }

    /// 按 Last.fm 网页的分页口径,总条数 → 总页数(每页 `pageSize` 条,至少 1 页)。
    public static func totalPages(total: Int, pageSize: Int) -> Int {
        guard pageSize > 0, total > 0 else { return 1 }
        return (total + pageSize - 1) / pageSize
    }

    /// 「今天听了几首」的派生(替代此前每轮刷新单发的 `from=今日0点&limit=1` 请求)。
    ///
    /// 两份数据凑:热力图日桶 `bucketToday`(截至 `syncedThrough` 为止今天的条数,只存非零天,
    /// 所以 nil 可能是 0)+ feed 里的行。三种情形:
    ///  - feed 的 50 行窗口**盖住了整天**(最旧一行早于今日零点)→ 直接数窗口里今天的行,精确;
    ///  - 窗口盖不住整天,但日桶今天同步过(`syncedThrough >= todayStart`)→ 桶 + 窗口里晚于
    ///    `syncedThrough` 的行,精确到"同步收尾那几秒内多算一条"的量级(下次 top-up 归正);
    ///  - 两者都不行(今天听了 >50 首、日桶又还停在昨天)→ 只能给下界(窗口里今天的行数),
    ///    `exact == false`,调用方可以补一个 `limit=1` 请求把真值拿回来。
    public static func todayCount(
        rowUTS: [TimeInterval], todayStart: TimeInterval,
        bucketToday: Int?, syncedThrough: TimeInterval
    ) -> (count: Int, exact: Bool) {
        let todayRows = rowUTS.filter { $0 >= todayStart }.count
        if let oldest = rowUTS.min(), oldest < todayStart {
            return (todayRows, true)
        }
        if syncedThrough >= todayStart {
            let afterSync = rowUTS.filter { $0 > syncedThrough }.count
            return (max((bucketToday ?? 0) + afterSync, todayRows), true)
        }
        return (todayRows, false)
    }
}
