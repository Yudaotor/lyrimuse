import Foundation

/// Last.fm「喜欢」(track.love / track.unlove / track.getInfo 的 userloved)里不碰网络的那部分:
/// 打在哪个写法上、表单怎么编、响应怎么读。网络与状态在 App 的 `LastfmLoveModel`(12 章 §8)。
public enum LastfmLove {
    public struct Target: Equatable, Sendable {
        public let artist: String
        public let title: String

        public init(artist: String, title: String) {
            self.artist = artist
            self.title = title
        }
    }

    /// 喜欢要打在哪个写法上。
    ///
    /// collector 上送时可能改写歌手 / 歌名(合唱串收拢、「智能」档编目匹配),喜欢必须打在**上送的
    /// 那个写法**上,否则 Last.fm 上喜欢的是另一个实体。Last.fm 回报的 nowplaying 就是上送写法本身:
    /// 它新鲜、歌手非空、且歌名宽松对得上本机这首时用它;否则退回本机显示的写法。本机歌名或歌手为空
    /// (没在放 / 元数据不全)返回 nil。
    public static func resolveTarget(localArtist: String, localTitle: String,
                                     nowPlaying: Target?, nowPlayingFresh: Bool) -> Target? {
        let title = localTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = localArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        if let np = nowPlaying, nowPlayingFresh, !np.artist.isEmpty, looselySameTitle(np.title, title) {
            return np
        }
        return Target(artist: artist, title: title)
    }

    /// 跟「正在记录」红点判「服务器确认收到了本机这首」同一个口径:只忽略大小写和首尾空白。
    public static func looselySameTitle(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased()
            == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 写请求的表单体:按 RFC 3986 unreserved 严格转义(`+` → `%2B`、空格 → `%20`),键按字母序。
    /// POST 表单不像读接口的 query 那样被多解一次码,不走 `LastfmQuery` 的双重转义 —— 跟 collector
    /// 用 Go `url.Values.Encode` 发写请求同一个口径。
    public static func formBody(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return params.keys.sorted().map { esc($0) + "=" + esc(params[$0]!) }.joined(separator: "&")
    }

    /// 读 track.getInfo 响应里的喜欢状态。nil = 没读到(其它 API 错误 / 结构不对)。
    /// error 6(Last.fm 没收录这首)算「没喜欢」—— track.love 对没收录的曲目照样能喜欢。
    /// userloved 实测是字符串 "0"/"1",数字形态也认。
    public static func parseUserLoved(_ json: [String: Any]) -> Bool? {
        if let code = json["error"] as? Int { return code == 6 ? false : nil }
        guard let track = json["track"] as? [String: Any] else { return nil }
        if let s = track["userloved"] as? String { return s == "1" }
        if let n = track["userloved"] as? Int { return n == 1 }
        return nil
    }

    /// track.love / track.unlove 的响应算不算写成功:成功是空对象,失败带 `error` 码
    /// (Last.fm 多以 HTTP 200 + {"error":N} 报错,不能只看状态码)。
    public static func writeSucceeded(_ json: [String: Any]) -> Bool {
        json["error"] == nil
    }
}
