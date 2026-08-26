import Foundation

/// 解析一页 `user.getrecenttracks` 响应:抽出 totalPages 和这一页的曲目行。
///
/// 这段解析(包括"只有一条时 track 是对象不是数组"这个 Last.fm 怪癖)原来在
/// LastfmStatsService 里被写了两遍——ensureTitleFormsIndex(写法索引首次建索引)和
/// refreshDailyCounts(热力图全量同步)各自独立分页扫**同一个接口**,互不知道对方
/// 存在,新账号首次连接时两条同时跑,请求量翻倍还容易撞 Last.fm 限速(2026-08-25)。
/// 合并成一次扫描后,两个消费者(写法索引收割 / 按天计数)喂的是同一份解析结果,
/// 这里收成一份、可被 lyrimuse-selftest 单测覆盖。
public enum LastfmRecentTracksPage {
    public struct Row: Equatable {
        public let artist: String
        public let title: String
        /// nil = 这一行是"正在播放"、或响应里缺时间戳(两种情况原逻辑都只跳过计数,
        /// 不影响写法收割——调用方仍应该把 artist/title 喂给收割函数)。
        public let uts: TimeInterval?

        public init(artist: String, title: String, uts: TimeInterval?) {
            self.artist = artist
            self.title = title
            self.uts = uts
        }
    }

    /// 从 `request(method: "user.getrecenttracks", ...)` 拿到的顶层 JSON 解析一页。
    /// 返回 nil = 响应形状不对(缺 `recenttracks`/`@attr`),调用方应视为这一页失败、
    /// 中止分页(跟原来两处的 `guard ... else { failed = true; break }`/`else { return }`
    /// 语义一致)。
    ///
    /// 一行必须有 artist+title 才产出 Row(原逻辑用 `if let`/`guard let` 转型失败时
    /// 整行跳过);uts 缺失(nowPlaying 行,或响应里没带时间戳的畸形行)返回 nil,
    /// 由调用方决定"仍要收割写法、但不计入按天总数"。
    public static func parse(_ json: [String: Any]) -> (rows: [Row], totalPages: Int)? {
        guard let rt = json["recenttracks"] as? [String: Any],
              let attr = rt["@attr"] as? [String: Any]
        else { return nil }
        let totalPages = Int((attr["totalPages"] as? String) ?? "1") ?? 1
        var tracks = (rt["track"] as? [[String: Any]]) ?? []
        if tracks.isEmpty, let single = rt["track"] as? [String: Any] { tracks = [single] }
        let rows: [Row] = tracks.compactMap { t in
            guard let name = t["name"] as? String,
                  let art = (t["artist"] as? [String: Any])?["#text"] as? String
            else { return nil }
            let isNowPlaying = ((t["@attr"] as? [String: Any])?["nowplaying"] as? String) == "true"
            if isNowPlaying { return Row(artist: art, title: name, uts: nil) }
            let uts = (t["date"] as? [String: Any])
                .flatMap { $0["uts"] as? String }
                .flatMap { TimeInterval($0) }
            return Row(artist: art, title: name, uts: uts)
        }
        return (rows, totalPages)
    }
}
