import Foundation

/// 网易云此刻放的是不是播客单集。
///
/// 系统那份 Now Playing 把单集报得跟一首歌一样:主播当歌手、节目名当专辑、时长照给,单看快照分不出来。客户端放单集时
/// 把这档节目的单集列表整份写进当前播放列表 `playingList`(明文 JSON,引擎读待播也读它),单集条目的 `resourceType`
/// 是 `voice` / `downloadVoice` / `localVoice`,`track.name` 是单集名、`track.creator.nickname` 是主播。按歌名 + 主播在
/// 里面找到当前这一条,就认定是单集。见 02 章决策 114。
///
/// 读别家 App 的容器要完全磁盘访问:引擎确认读得到网易云(`LocalCacheAccess` 里 `netease` 是 readable)之前不读,
/// 没授权的用户不会因为这里被系统弹框。文件按 mtime + 大小缓存,变了才重新解析。
public enum NeteasePodcastQueue {
    public static let bundleID = "com.netease.163music"

    public static let queueURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.netease.163music/Data/Documents")
        .appendingPathComponent("storage/file_storage/webdata/file/playingList")

    static let voiceTypes: Set<String> = ["voice", "downloadVoice", "localVoice"]

    /// 跟引擎 `neteaseUpcomingMaxBytes` 同一个上限:防文件异常膨胀把内存吃光,不是格式约束。
    static let maxBytes = 16 << 20

    /// 单集名(归一后)→ 主播名(归一后)。主播缺失的条目记空串。
    public typealias Episodes = [String: Set<String>]

    /// 队列文件里的单集;不是这份文件的形状返回 nil。
    public static func episodes(fromQueueJSON data: Data) -> Episodes? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["list"] as? [[String: Any]] else { return nil }
        var out: Episodes = [:]
        for item in list {
            guard let type = item["resourceType"] as? String, voiceTypes.contains(type),
                  let track = item["track"] as? [String: Any],
                  let name = track["name"] as? String else { continue }
            let title = normalized(name)
            guard !title.isEmpty else { continue }
            let host = normalized(((track["creator"] as? [String: Any])?["nickname"] as? String) ?? "")
            out[title, default: []].insert(host)
        }
        return out
    }

    /// 歌名对得上一条单集、歌手是它的主播(条目没记主播时只看歌名)。
    public static func contains(_ episodes: Episodes, title: String, artist: String) -> Bool {
        guard let hosts = episodes[normalized(title)] else { return false }
        return hosts.contains(normalized(artist)) || hosts.contains("")
    }

    /// 这一份快照是不是网易云在放播客单集。`readable` 为 nil 时看引擎发布的授权结论。
    public static func isEpisode(bundleID: String?, title: String?, artist: String?,
                                 queueURL: URL = queueURL, readable: Bool? = nil) -> Bool {
        guard bundleID == Self.bundleID, let title, !normalized(title).isEmpty else { return false }
        guard readable ?? (LocalCacheAccess.grant(for: ["netease"]) == .granted) else { return false }
        guard let episodes = cachedEpisodes(at: queueURL) else { return false }
        return contains(episodes, title: title, artist: artist ?? "")
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct Cached {
        let path: String
        let mtime: Date
        let size: Int
        let episodes: Episodes?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Cached?

    private static func cachedEpisodes(at url: URL) -> Episodes? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let c = cached, c.path == url.path, c.mtime == mtime, c.size == size { return c.episodes }
        let episodes = size <= maxBytes ? FileIO.read(url).flatMap(episodes(fromQueueJSON:)) : nil
        cached = Cached(path: url.path, mtime: mtime, size: size, episodes: episodes)
        return episodes
    }
}
