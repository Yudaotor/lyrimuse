import Foundation

/// 最近记录列表那一页 `user.getrecenttracks` 响应的逐行解析(LastfmStatsService.parseRecent 用)。
///
/// `dup` 是「同一时刻 + 同一首歌」重复出现时的序号,几乎恒为 0。它是行 id 的一部分,**不能**
/// 换成在这批响应里的行号:那样每来一条新 scrobble,后面所有行的 id 全变,SwiftUI 会把整张列表
/// 当成被替换掉、连带把滚动位置顶回去。
public enum LastfmRecentRows {
    public struct Row: Equatable {
        public let dup: Int
        public let title: String
        public let artist: String
        /// 响应里的专辑名原样保留(可能是空串)。
        public let album: String?
        /// 已按 LastfmImage.pick 挑档并滤掉万能占位星。
        public let image: String?
        /// nil = 这行是「正在播放」(Last.fm 把 nowplaying 行的 date 整个省掉)。
        public let uts: TimeInterval?

        public init(dup: Int, title: String, artist: String, album: String?, image: String?, uts: TimeInterval?) {
            self.dup = dup
            self.title = title
            self.artist = artist
            self.album = album
            self.image = image
            self.uts = uts
        }
    }

    /// 没有曲名的行跳过;`track` 不是数组时返回空。
    public static func parse(_ json: [String: Any]) -> [Row] {
        let items = ((json["recenttracks"] as? [String: Any])?["track"] as? [[String: Any]]) ?? []
        var dupCount: [String: Int] = [:]
        return items.compactMap { item in
            let title = item["name"] as? String ?? ""
            guard !title.isEmpty else { return nil }
            let artist = (item["artist"] as? [String: Any])?["#text"] as? String ?? ""
            let uts = (item["date"] as? [String: Any])?["uts"] as? String
            let dupKey = "\(uts ?? "np")|\(artist)|\(title)"
            let dup = dupCount[dupKey, default: 0]
            dupCount[dupKey] = dup + 1
            return Row(
                dup: dup,
                title: title,
                artist: artist,
                album: (item["album"] as? [String: Any])?["#text"] as? String,
                image: LastfmImage.pick(item["image"]),
                uts: uts.flatMap { TimeInterval($0) }
            )
        }
    }
}
