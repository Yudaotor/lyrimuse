import Foundation

/// 网易云此刻放的是不是播客单集。
///
/// 系统那份 Now Playing 把单集报得跟一首歌一样:主播当歌手、节目名当专辑、时长照给,单看快照分不出来。客户端放单集时
/// 把这档节目的单集列表整份写进当前播放列表 `playingList`;引擎盯着这份文件,把里面的单集(单集名 + 主播)写成
/// `lyrimuse-netease-episodes.json`(`neteasepodcast.go`)。按歌名 + 主播在名单里找到当前这一条,就认定是单集。
/// 见 02 章决策 114。
///
/// iPad 版网易云(按 Mac 版认)没有这份列表,引擎读它此刻放的那一项,是节目时写成另一份同样形状的名单
/// `lyrimuse-netease-ipad-episodes.json`(`neteaseipad.go`);两份名单一起认。见 02 章决策 199。
///
/// 只读引擎写的名单,别在 App 里读网易云的容器:App 是前台进程,没有完全磁盘访问时系统会弹「想访问其他 App 的数据」,
/// 引擎读得到也不代表 App 读得到。名单不在(没装网易云、没授权、引擎没在跑)就一律不当单集。见 02 章决策 151。
/// 文件按 mtime + 大小缓存,变了才重新解析。
public enum NeteasePodcastQueue {
    public static let bundleID = "com.netease.163music"

    public static var stateURL: URL { LyrimusePaths.configFile("lyrimuse-netease-episodes.json") }
    public static var iPadStateURL: URL { LyrimusePaths.configFile("lyrimuse-netease-ipad-episodes.json") }
    public static var stateURLs: [URL] { [stateURL, iPadStateURL] }

    /// 单集名(归一后)→ 主播名(归一后)。主播缺失的条目记空串。
    public typealias Episodes = [String: Set<String>]

    /// 引擎写的名单;不是这份文件的形状返回 nil。
    public static func episodes(fromStateJSON data: Data) -> Episodes? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["episodes"] as? [[String: Any]] else { return nil }
        var out: Episodes = [:]
        for item in list {
            guard let name = item["title"] as? String else { continue }
            let title = normalized(name)
            guard !title.isEmpty else { continue }
            out[title, default: []].insert(normalized(item["host"] as? String ?? ""))
        }
        return out
    }

    /// 歌名对得上一条单集、歌手是它的主播(条目没记主播时只看歌名)。
    public static func contains(_ episodes: Episodes, title: String, artist: String) -> Bool {
        guard let hosts = episodes[normalized(title)] else { return false }
        return hosts.contains(normalized(artist)) || hosts.contains("")
    }

    /// 这一份快照是不是网易云在放播客单集:任一份名单里有它。
    public static func isEpisode(bundleID: String?, title: String?, artist: String?, stateURLs: [URL] = stateURLs) -> Bool {
        guard bundleID == Self.bundleID, let title, !normalized(title).isEmpty else { return false }
        return stateURLs.contains { url in
            cachedEpisodes(at: url).map { contains($0, title: title, artist: artist ?? "") } ?? false
        }
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct Cached {
        let mtime: Date
        let size: Int
        let episodes: Episodes?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [String: Cached] = [:]

    private static func cachedEpisodes(at url: URL) -> Episodes? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let c = cached[url.path], c.mtime == mtime, c.size == size { return c.episodes }
        let episodes = FileIO.read(url).flatMap(episodes(fromStateJSON:))
        cached[url.path] = Cached(mtime: mtime, size: size, episodes: episodes)
        return episodes
    }
}
