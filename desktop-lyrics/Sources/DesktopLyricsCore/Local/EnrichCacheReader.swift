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

public enum EnrichCacheReader {
    private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/applemusic-nowplaying/applemusic-nowplaying-enrich-cache.json")

    // 每次全量读+解析——这个文件不大,没有增量/文件监听的必要,换来的是实现简单、
    // 不用担心漏掉更新。文件不存在/解析失败/key 查不到都返回 nil,上层据此显示
    // "还没有内容"而不是崩溃。
    public static func lookup(artist: String, title: String, album: String) -> EnrichCacheLyrics? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        guard let all = try? JSONDecoder().decode([String: EnrichCacheEntry].self, from: data) else { return nil }
        let key = "\(artist)|\(title)|\(album)"
        guard let entry = all[key] else { return nil }
        return EnrichCacheLyrics(
            lyrics: entry.lyrics ?? "",
            lyricsTr: entry.lyricsTr ?? "",
            lyricsRoma: entry.lyricsRoma ?? "",
            lyricsYRC: entry.lyricsYRC ?? ""
        )
    }
}
