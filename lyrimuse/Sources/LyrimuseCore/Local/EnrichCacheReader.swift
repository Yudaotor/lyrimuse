import Foundation

// 读 collector 自己维护的那份磁盘缓存(collector/enrich.go 的 enrichEntry,持久化路径
// 由 collector/main.go:68 拼出来,这台机器上固定是这个路径)。key 是
// "歌手|歌名|专辑"(跟 collector/enrich.go:93 的 `artist + "|" + title + "|" + album`
// 完全一致),value 里已经有解析好的歌词——本地数据源靠这个拿歌词,不用在 Swift 里
// 重新实现一遍网易云/QQ/酷狗/Musixmatch/LRCLIB 的匹配逻辑。
public struct EnrichCacheEntry: Decodable {
    let lyrics: String?
    let lyricsTr: String?
    let lyricsRoma: String?
    let lyricsYRC: String?
    let lyricsSource: String?
    let coverSource: String?
    // collector 解析出的封面地址(网易云/QQ/Apple)。桌面这边原来只读歌词字段,封面一直
    // 没人用 —— 直到「最近播放」列表需要一个 Last.fm 之外的兜底,见 coverURL(artist:...)。
    let coverURL: String?
    // 联网查过了、至少一个源(目前是 lrclib)明确说这首歌是纯音乐——跟"lyrics 是空的"
    // 要分开看,后者也可能是"还没解析完"或者"五个源都没查到"这类更含糊的情况。见
    // collector/enrich.go 的 enrichEntry.Instrumental 定义处的注释。
    let instrumental: Bool?
    // 这条记录的**解析时刻**(Unix 秒)。>0 就代表"联网解析已经完整跑完一轮"——
    // collector 一轮搜索结束时才写它,而且找不到歌词时**同样会写**一条只有 ts、
    // 没有 lyrics 的记录(2026-08-11 在真实缓存里核实过确有这种条目)。
    //
    // 为什么不能用"查得到这个 key"当判据:外围字段补全那条路径(封面/各平台链接)也会
    // 写这个 key,但它刻意不动 ts(见 collector/enrich.go 里 e.PeripheralTS 那段注释),
    // 于是"条目存在"可能只代表封面补好了、歌词还在查 —— 拿它当"搜完了"会让 UI 提前
    // 认输。ts 是那一轮搜索真正结束的凭据。
    let ts: Int64?

    enum CodingKeys: String, CodingKey {
        case lyrics
        case lyricsTr = "lyrics_tr"
        case lyricsRoma = "lyrics_roma"
        case lyricsYRC = "lyrics_yrc"
        case lyricsSource = "lyrics_source"
        case coverSource = "cover_source"
        case coverURL = "cover_url"
        case instrumental
        case ts
    }
}

public struct EnrichCacheLyrics {
    public let lyrics: String
    public let lyricsTr: String
    public let lyricsRoma: String
    public let lyricsYRC: String
    public let instrumental: Bool
    /// 这首歌已经被完整解析过一轮了吗(见 EnrichCacheEntry.ts)。
    /// 它为 true 而 lyrics 为空,就是"搜过了,确实没有"——UI 靠这个区别把
    /// "搜索歌词中…"换成"暂无歌词",而不是无限期转圈。
    public let resolved: Bool
}

@MainActor
public enum EnrichCacheReader {
    private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-enrich-cache.json")

    // 缓存文件设计上永久不清理,会攒到几百条、几 MB——如果每次 lookup() 都全量读+解析,
    // 而当前播放的歌还没解析出歌词(新歌/纯音乐/查无此歌)时每 2 秒轮询都会触发一次,
    // 代价可观。这里按文件 mtime 加一层缓存:文件没变就直接用上次解析好的结果,只有
    // collector 真的写过新内容(mtime 变了)才重新读+解析。这个 enum 加 @MainActor 是
    // 因为两个调用方(LocalPlaybackSource 取歌词、LastfmStatsService 取封面兜底)本来
    // 就都是 @MainActor,静态缓存状态不需要额外加锁,让编译器保证单线程访问即可。
    private static var cachedMTime: Date?
    private static var cachedEntries: [String: EnrichCacheEntry]?
    // 忽略专辑的封面索引,跟 cachedEntries 同寿命 —— 见 coverByArtistTitle()。
    private static var cachedCoverIndex: [String: String]?

    /// 缓存文件当前的 mtime,拿不到就是 nil。
    ///
    /// 给调用方判断"collector 是不是又写过了"。同一首歌播放中途补出来的译文/换上来的更好
    /// 的歌词,在这一侧唯一的外部体现就是这个文件被重写 —— collector 那边的重推通知只走
    /// relay,本地模式压根不看。一次 stat,比重新解析几 MB 的 JSON 便宜得多。
    public static var fileModificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate]
            as? Date
    }

    // 文件不存在/解析失败/key 查不到都返回 nil,上层据此显示"还没有内容"而不是崩溃。
    public static func lookup(artist: String, title: String, album: String) -> EnrichCacheLyrics? {
        guard let all = loadEntries() else { return nil }
        // ⚠️ 必须跟 collector 用同一套归一化(见 EnrichCacheKeys.normalizedKey)。collector
        // 按归一化 key 写盘,这边要是还按播放器报的原样拼,Spotify 那种带译名的歌名
        // (`不散的筵席（I Miss You）`)就会**查不到任何歌词**——不是显示旧内容,是整首歌
        // 没词,而且只在部分播放器上复现。
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        guard let entry = all[key] else { return nil }
        return EnrichCacheLyrics(
            lyrics: entry.lyrics ?? "",
            lyricsTr: entry.lyricsTr ?? "",
            lyricsRoma: entry.lyricsRoma ?? "",
            lyricsYRC: entry.lyricsYRC ?? "",
            instrumental: entry.instrumental ?? false,
            resolved: (entry.ts ?? 0) > 0
        )
    }

    /// 这首歌在本机缓存里有没有封面(collector 从网易云/QQ/Apple 解析出来的那张)。
    ///
    /// 给「最近播放」列表当 Last.fm 之外的兜底用:那个列表的封面本来**全部**来自 Last.fm
    /// (scrobble 自带图 → track.getInfo → 同专辑兄弟),而 Last.fm 对中文曲库缺图非常
    /// 常见 —— 2026-08-14 用户报的「陶喆 - 聖誕之吻」就是三级全空(Last.fm 只给它那张所有
    /// 缺图实体共用的白星占位图,被 imageURL() 正确滤掉),而同一张专辑网易云是有图的。
    ///
    /// 两级查找:
    ///  1. 归一化 key 精确命中 —— scrobble 本来就是本机 collector 上报的,三段字符串跟缓存
    ///     key 同源,这一级就能中。
    ///  2. 退到"歌手+歌名"(忽略专辑、忽略大小写)—— 手机端桥接过来的 scrobble 专辑名可能
    ///     跟本机播放器报的不一样。
    ///
    /// 刻意不做繁简折叠:本机播放写进缓存的和上报给 Last.fm 的是**同一批字符串**,折了也
    /// 不多命中一条,反而可能把两首真的不同名的歌并到一起。
    public static func coverURL(artist: String, title: String, album: String) -> URL? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        if let s = all[key]?.coverURL, let url = URL(string: s) { return url }
        if let s = coverByArtistTitle()[Self.artistTitleKey(artist: artist, title: title)],
           let url = URL(string: s) {
            return url
        }
        return nil
    }

    /// "歌手|歌名"(小写、去首尾空白)。跟 LastfmStatsService.playCountKey 同一套口径。
    /// nonisolated:纯字符串换算,不碰任何静态缓存,selftest 要在非主线程上下文里断言它。
    public nonisolated static func artistTitleKey(artist: String, title: String) -> String {
        artist.trimmingCharacters(in: .whitespaces).lowercased()
            + "|" + EnrichCacheKeys.normalizedTitle(title).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 忽略专辑的封面索引。跟 cachedEntries 同寿命(mtime 一变就一起作废),不是每次查询
    /// 都重建 —— 「最近播放」一页 100 行,每行都重扫几百条缓存就白烧一遍 CPU。
    private static func coverByArtistTitle() -> [String: String] {
        if let cachedCoverIndex { return cachedCoverIndex }
        var index: [String: String] = [:]
        for (key, entry) in cachedEntries ?? [:] {
            guard let cover = entry.coverURL, !cover.isEmpty else { continue }
            let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            // 同一首歌出现在多张专辑里时先到先得:都是这首歌的封面,选哪张都不算错。
            index[Self.artistTitleKey(artist: String(parts[0]), title: String(parts[1]))] = cover
        }
        cachedCoverIndex = index
        return index
    }

    private static func loadEntries() -> [String: EnrichCacheEntry]? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        if let mtime, mtime == cachedMTime, let cachedEntries {
            return cachedEntries
        }
        guard let data = try? Data(contentsOf: cacheURL) else {
            cachedMTime = nil
            cachedEntries = nil
            cachedCoverIndex = nil
            return nil
        }
        guard let all = try? JSONDecoder().decode([String: EnrichCacheEntry].self, from: data) else {
            cachedMTime = nil
            cachedEntries = nil
            cachedCoverIndex = nil
            return nil
        }
        cachedMTime = mtime
        cachedEntries = all
        cachedCoverIndex = nil // 内容换了,索引跟着作废,下次要用时按新内容重建
        return all
    }
}
