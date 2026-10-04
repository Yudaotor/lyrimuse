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
    /// 引擎上送时可能改写歌手 / 歌名(合唱串收拢、「智能」档编目匹配),喜欢必须打在**上送的
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
    /// POST 表单不像读接口的 query 那样被多解一次码,不走 `LastfmQuery` 的双重转义 —— 跟引擎
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

    /// 「最近记录」一行跟喜欢列表对得上的键:歌手 + 歌名,忽略大小写和首尾空白(Last.fm 按曲目实体
    /// 认喜欢,实体名不分大小写)。空歌手或空歌名返回 nil。
    public static func lovedKey(artist: String, title: String) -> String? {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !a.isEmpty, !t.isEmpty else { return nil }
        return a + "\n" + t
    }

    /// 读 `user.getLovedTracks` 的一页:这一页的曲目和总页数。nil = 没读到(API 错误 / 结构不对)。
    /// 只有一首时 `track` 是对象而不是数组,两种都认;歌手在 `artist.name`。
    public static func parseLovedTracksPage(_ json: [String: Any]) -> (targets: [Target], totalPages: Int)? {
        guard json["error"] == nil, let loved = json["lovedtracks"] as? [String: Any] else { return nil }
        let rows: [[String: Any]]
        if let array = loved["track"] as? [[String: Any]] {
            rows = array
        } else if let single = loved["track"] as? [String: Any] {
            rows = [single]
        } else {
            rows = []
        }
        let targets = rows.compactMap { row -> Target? in
            guard let title = row["name"] as? String,
                  let artist = (row["artist"] as? [String: Any])?["name"] as? String,
                  lovedKey(artist: artist, title: title) != nil else { return nil }
            return Target(artist: artist, title: title)
        }
        let attr = loved["@attr"] as? [String: Any]
        let pages = (attr?["totalPages"] as? String).flatMap { Int($0) } ?? (attr?["totalPages"] as? Int) ?? 1
        return (targets, max(1, pages))
    }

    /// 本机改过的一首:改成了什么、什么时候改的。
    public struct LovedOverride: Equatable, Sendable {
        public let loved: Bool
        public let at: Date

        public init(loved: Bool, at: Date) {
            self.loved = loved
            self.at = at
        }
    }

    /// 拉回来的喜欢列表跟本机改过的状态合并:`window` 之内本机为准(拉取可能先于写落地发出,Last.fm 读接口
    /// 也可能还没跟上刚才那次写),过了窗口的本机记录丢掉、以服务端为准。返回合并后的键和还留着的本机记录。
    public static func mergeLoved(fetched: Set<String>, overrides: [String: LovedOverride],
                                  now: Date, window: TimeInterval) -> (keys: Set<String>, overrides: [String: LovedOverride]) {
        let kept = overrides.filter { now.timeIntervalSince($0.value.at) < window }
        var keys = fetched
        for (key, o) in kept {
            if o.loved { keys.insert(key) } else { keys.remove(key) }
        }
        return (keys, kept)
    }

    /// track.love / track.unlove 的响应算不算写成功:成功是空对象,失败带 `error` 码
    /// (Last.fm 多以 HTTP 200 + {"error":N} 报错,不能只看状态码)。
    public static func writeSucceeded(_ json: [String: Any]) -> Bool {
        json["error"] == nil
    }
}
