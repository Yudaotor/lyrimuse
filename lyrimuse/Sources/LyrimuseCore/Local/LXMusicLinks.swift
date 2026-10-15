import Foundation

/// 洛雪音乐的「搜索并播放」链接(`lxmusic://music/searchPlay?data=<JSON>`):按歌名、歌手(专辑、时长可选)让洛雪在它配的
/// 音源里搜到就放;`playLater` 为真时加进它的「稍后播放」,不打断正在放的。只要歌名和歌手,不依赖本机缓存里的链接。
/// `data` 是整段 JSON 按 URL 编码(只留字母数字和 `-._~`),`&`、`=`、`+` 留着会被当成别的参数。见 12 章决策 77。
/// 另有「搜索」(`lxmusic://music/search?data=<JSON>`):打开洛雪的搜索页搜这串字,把它带到前台;歌手、专辑行用。
public enum LXMusicLinks {
    public struct Track: Equatable, Sendable {
        public let title: String
        public let artist: String
        public let album: String?
        public let durationSecs: Double?

        public init(title: String, artist: String, album: String? = nil, durationSecs: Double? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.durationSecs = durationSecs
        }
    }

    public static func searchPlayURL(_ track: Track, playLater: Bool) -> URL? {
        let name = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var payload: [String: Any] = ["name": name, "playLater": playLater]
        let singer = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !singer.isEmpty { payload["singer"] = singer }
        if let album = track.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty { payload["albumName"] = album }
        if let secs = track.durationSecs, secs >= 1 {
            let total = Int(secs.rounded())
            payload["interval"] = String(format: "%02d:%02d", total / 60, total % 60)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8),
              let encoded = json.addingPercentEncoding(withAllowedCharacters: dataAllowed) else { return nil }
        return URL(string: "lxmusic://music/searchPlay?data=" + encoded)
    }

    /// 洛雪的搜索链接校验搜索词最多 128 个字,先截到这么长。
    public static let searchMaxLength = 128

    /// 在洛雪里搜这串字的链接;空的不给。
    public static func searchURL(keywords: String) -> URL? {
        let text = String(keywords.trimmingCharacters(in: .whitespacesAndNewlines).prefix(searchMaxLength))
        guard !text.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["keywords": text], options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8),
              let encoded = json.addingPercentEncoding(withAllowedCharacters: dataAllowed) else { return nil }
        return URL(string: "lxmusic://music/search?data=" + encoded)
    }

    private static let dataAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}
