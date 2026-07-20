import Foundation

// 读 collector 自己维护的那份磁盘缓存(collector/enrich.go 的 enrichEntry,持久化路径
// 由 collector/main.go:68 拼出来,这台机器上固定是这个路径)。key 是
// "歌手|歌名|专辑"(跟 collector/enrich.go:93 的 `artist + "|" + title + "|" + album`
// 完全一致),value 里已经有解析好的歌词——本地数据源靠这个拿歌词,不用在 Swift 里
// 重新实现一遍网易云/QQ/酷狗/LRCLIB 的匹配逻辑。
public struct EnrichCacheEntry: Decodable {
    let lyrics: String?
    let lyricsTr: String?
    let lyricsRoma: String?
    let lyricsYRC: String?
    let lyricsSource: String?
    let coverSource: String?

    enum CodingKeys: String, CodingKey {
        case lyrics
        case lyricsTr = "lyrics_tr"
        case lyricsRoma = "lyrics_roma"
        case lyricsYRC = "lyrics_yrc"
        case lyricsSource = "lyrics_source"
        case coverSource = "cover_source"
    }
}

public struct EnrichCacheLyrics {
    public let lyrics: String
    public let lyricsTr: String
    public let lyricsRoma: String
    public let lyricsYRC: String
}

@MainActor
public enum EnrichCacheReader {
    private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/applemusic-nowplaying/applemusic-nowplaying-enrich-cache.json")

    // 2026-07-17 真机实测坐实:这个缓存文件设计上永久不清理,现在已经攒到几百条、
    // 几 MB——lookup() 原来是真·每次全量读+解析,而 LocalPlaybackSource 只要当前
    // 播放的歌还没解析出歌词(新歌/纯音乐/查无此歌),每 2 秒轮询就会调用一次,一直
    // 卡到这首歌播完,实测一次要 16ms 以上。加一层基于文件 mtime 的缓存:文件没变
    // 就直接用上次解析好的结果,只有 collector 真的写过新内容(mtime 变了)才重新
    // 读+解析。这个 enum 加 @MainActor 是因为目前唯一的调用方 LocalPlaybackSource
    // 本来就是 @MainActor,静态缓存状态不需要额外加锁,让编译器保证单线程访问即可。
    private static var cachedMTime: Date?
    private static var cachedEntries: [String: EnrichCacheEntry]?

    // 文件不存在/解析失败/key 查不到都返回 nil,上层据此显示"还没有内容"而不是崩溃。
    public static func lookup(artist: String, title: String, album: String) -> EnrichCacheLyrics? {
        guard let all = loadEntries() else { return nil }
        let key = "\(artist)|\(title)|\(album)"
        guard let entry = all[key] else { return nil }
        return EnrichCacheLyrics(
            lyrics: entry.lyrics ?? "",
            lyricsTr: entry.lyricsTr ?? "",
            lyricsRoma: entry.lyricsRoma ?? "",
            lyricsYRC: entry.lyricsYRC ?? ""
        )
    }

    private static func loadEntries() -> [String: EnrichCacheEntry]? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        if let mtime, mtime == cachedMTime, let cachedEntries {
            return cachedEntries
        }
        guard let data = try? Data(contentsOf: cacheURL) else {
            cachedMTime = nil
            cachedEntries = nil
            return nil
        }
        guard let all = try? JSONDecoder().decode([String: EnrichCacheEntry].self, from: data) else {
            cachedMTime = nil
            cachedEntries = nil
            return nil
        }
        cachedMTime = mtime
        cachedEntries = all
        return all
    }
}
