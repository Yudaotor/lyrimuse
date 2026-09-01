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
    // 这张封面在**来源平台上属于哪张专辑**(collector/enrich.go 的 e.CoverAlbum,
    // 2026-08-20 起落盘)。2026-09-01 起 Swift 侧解码——「最近记录」需要区分"缓存里有图"
    // 和"缓存里这张图确实属于这行的专辑":后者才有资格纠正 Last.fm 自带图,见
    // albumVerifiedCoverURL。
    let coverAlbum: String?
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
    // 各平台跳转目标(2026-08-24)。collector 早就把这几个落进缓存了,Swift 侧此前一个
    // 都没解码 —— 见 PlatformLinks 的头注。
    let appleMusicURL: String?
    let qqMusicURL: String?
    let neteaseURL: String?
    let qqAlbumMid: String?
    let qqSingerMid: String?
    // 这首歌的语种真值(collector/enrich.go 的 enrichEntry.SongLanguage,取值
    // "yue"=粤语/"cmn"=普通话/空=没判出来),给粤拼罗马音开关用——光看歌词文字认不出
    // 粤语和普通话(汉字一样),得靠 collector 那边已经判出来的这个字段。2026-08-29 起
    // 才第一次被 Swift 侧读取,此前完全没人解码它。
    let songLanguage: String?
    // plainLyrics:2026-08-30 起才被读取——"搜索候选歌词"弹窗采纳一条"仅纯文本"候选时
    // (见 lyrimuse target 的 EnrichCacheStore.savePlainTextEdit)写的独立字段,跟 lyrics
    // 不是一回事:这个没有时间戳,只给"歌词窗口"当静态兜底用。collector 侧
    // enrichEntry.PlainLyrics 头注解释了为什么必须分开存。
    let plainLyrics: String?

    enum CodingKeys: String, CodingKey {
        case lyrics
        case lyricsTr = "lyrics_tr"
        case lyricsRoma = "lyrics_roma"
        case lyricsYRC = "lyrics_yrc"
        case lyricsSource = "lyrics_source"
        case coverSource = "cover_source"
        case coverURL = "cover_url"
        case coverAlbum = "cover_album"
        case instrumental
        case ts
        case appleMusicURL = "apple_music_url"
        case qqMusicURL = "qq_music_url"
        case neteaseURL = "netease_url"
        case qqAlbumMid = "qq_album_mid"
        case qqSingerMid = "qq_singer_mid"
        case songLanguage = "song_language"
        case plainLyrics = "plain_lyrics"
    }
}

// collector 那边 songLanguageCantonese 的取值("yue"),两边必须完全一致——match.go/enrich.go
// 那份常量的注释就说了它是 lyricCandidate.language 与 enrichEntry.SongLanguage 共用的取值。
private let songLanguageCantonese = "yue"

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
    /// 这首歌是不是粤语——给"标注哪些语言"的粤拼开关用(见 Romanizer.LyricScript.cantonese)。
    /// 判据是 collector 判定的 SongLanguage 真值,不是看歌词文字(汉字认不出粤语/普通话)。
    public let isCantonese: Bool
    /// 没有时间戳的纯文本兜底——只在 lyrics 为空、这首歌又确实采纳过一条"仅纯文本"候选时
    /// 才非空(见 EnrichCacheEntry.plainLyrics 头注)。「歌词窗口」用它决定要不要走静态
    /// 展示;桌面悬浮歌词/灵动岛这些依赖时间戳的展示面不读这个字段,继续如实显示"无歌词"。
    public let plainLyrics: String
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
    // 宽松匹配索引(looseKey → 组内字典序最小的原 key),跟 cachedEntries 同寿命、惰性
    // 构建 —— 见 looseMatch(2026-08-20 性能审计:原来每次精确 miss 都对全部 ~900 个 key
    // 逐个现算 ICU 繁简 transform,~7ms 主线程,新歌未解析窗口内每 2s 重复一遍)。
    private static var cachedLooseIndex: [String: String]?
    // 后台解码的世代号:kick 时占位,完成回主线程时对得上才采纳(reloadNow 的同步解码
    // 会推进世代号,把在飞的旧结果作废)。nil = 没有在飞的后台解码。
    private static var decodeGeneration = 0
    private static var inFlightGeneration: Int?
    private static var memoryPressureSource: DispatchSourceMemoryPressure?

    /// 缓存文件当前的 mtime,拿不到就是 nil。
    ///
    /// 给调用方判断"collector 是不是又写过了"。同一首歌播放中途补出来的译文/换上来的更好
    /// 的歌词,在这一侧唯一的外部体现就是这个文件被重写 —— collector 那边的重推通知只走
    /// relay,本地模式压根不看。一次 stat,比重新解析几 MB 的 JSON 便宜得多。
    /// 当前曲目的歌词/封面来源(2026-08-22,歌词窗口「显示简介」面板)。entry 里这两个
    /// 字段一直解码着但没往外传,这里补一个只读口;沿用 lookup 同款的 精确 key → 宽松
    /// key 两级匹配。首次调用要解析整份缓存 JSON,别在主线程调。
    public struct SourceInfo: Sendable {
        public let lyricsSource: String?
        public let coverSource: String?
    }

    public static func sourceInfo(artist: String, title: String, album: String) -> SourceInfo? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        guard let entry = all[key] ?? looseMatch(key, in: all) else { return nil }
        return SourceInfo(lyricsSource: entry.lyricsSource, coverSource: entry.coverSource)
    }

    /// 当前曲目在缓存里的**实际条目 key**(2026-08-22,歌词窗口「搜索歌词」写回用):
    /// 精确命中用精确 key;宽松命中返回缓存里真实存在的那条 key —— 播放器报法与缓存
    /// 写法有 空格/大小写/繁简 出入时(见 looseMatch 注释),写回必须落在读取路径命中的
    /// 同一条上,否则读写分家、改了不生效。两级都没有返回 nil,调用方退回 normalizedKey
    /// 新建条目。首次调用要解析整份缓存 JSON,别在主线程调。
    /// 这首歌在各平台的跳转目标。**零网络** —— 全是 collector 早就存好的字段,
    /// 首次调用要解析整份缓存 JSON(之后靠 mtime 缓存是 µs 级),别在主线程调。
    /// 沿用 lookup/sourceInfo 同款的 精确 key → 宽松 key 两级匹配。
    public static func platformLinks(artist: String, title: String, album: String) -> PlatformLinks? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        guard let entry = all[key] ?? looseMatch(key, in: all) else { return nil }
        let rawQQ = entry.qqMusicURL ?? ""
        // 搜索兜底链接不当"歌曲页"给出去,理由见 PlatformLinks.isQQSearchFallback
        let qqSong = (!rawQQ.isEmpty && !PlatformLinks.isQQSearchFallback(rawQQ))
            ? URL(string: rawQQ) : nil
        let links = PlatformLinks(
            // https://music.apple.com/… → music://(进 App)。非 AM 链接会被这个函数拒掉。
            appleMusic: MusicCatalogSearch.musicSchemeURL(entry.appleMusicURL),
            qqSong: qqSong,
            qqAlbum: PlatformLinks.qqAlbumURL(mid: entry.qqAlbumMid ?? ""),
            qqArtist: PlatformLinks.qqArtistURL(mid: entry.qqSingerMid ?? ""),
            neteaseSong: (entry.neteaseURL?.isEmpty == false) ? URL(string: entry.neteaseURL!) : nil)
        return links.isEmpty ? nil : links
    }

    public static func resolvedKey(artist: String, title: String, album: String) -> String? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        if all[key] != nil { return key }
        return looseIndex(in: all)[EnrichCacheKeys.looseKey(key)]
    }

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
        guard let entry = all[key] ?? looseMatch(key, in: all) else { return nil }
        return EnrichCacheLyrics(
            lyrics: entry.lyrics ?? "",
            lyricsTr: entry.lyricsTr ?? "",
            lyricsRoma: entry.lyricsRoma ?? "",
            lyricsYRC: entry.lyricsYRC ?? "",
            instrumental: entry.instrumental ?? false,
            resolved: (entry.ts ?? 0) > 0,
            isCantonese: entry.songLanguage == songLanguageCantonese,
            plainLyrics: entry.plainLyrics ?? ""
        )
    }

    /// 精确 key 没命中时,再按"忽略空格/大小写/繁简"找一次。
    ///
    /// 为什么必须有这一层:collector 那边把"其实是同一首歌"的重复条目合并成了一条,保留的是
    /// **最适合显示**的那个写法(简体、中英文之间带空格)。但播放器报的不一定是那个写法 ——
    /// QQ 音乐报 `Susan说`、网易云报 `Susan 说`,缓存里现在只剩后者。没有这层兜底,前者就
    /// 精确 miss,用户看到的是「这首歌整首没有歌词」,而不是「歌词不太对」,更难归因。
    ///
    /// ⚠️ 多条候选时必须挑**确定的**那一条:Swift 的 Dictionary 遍历顺序不保证稳定,撞见谁
    /// 用谁的话,同一首歌这次读到 A 的歌词、下次读到 B 的。按 key 字典序取最小,跟 collector
    /// 侧合并后只剩一条的常态也不冲突(那时候本来就只有一个候选)。
    ///
    /// 成本:只在精确 miss 时才扫,而 miss 只发生在合并过的那些歌上,量级是几百条字符串。
    private static func looseMatch(_ key: String, in all: [String: EnrichCacheEntry]) -> EnrichCacheEntry? {
        // 经 cachedLooseIndex 查表(2026-08-20):原来每次 miss 对全表逐 key 现算 looseKey
        // (每 key 一次 CFStringTransform 繁简转换),索引把它塌缩成一次 looseKey + 一次
        // 字典查找。索引**惰性**构建(首次 miss 时,~8ms 一次)——不急切挂在解码后:精确
        // 命中的曲目今天零成本,collector 预取连环写盘时急切重建反而是新增回归(对抗核实
        // 指出的坑);"字典序最小 key 胜出"的归并语义原样保留。
        guard let bestKey = looseIndex(in: all)[EnrichCacheKeys.looseKey(key)] else { return nil }
        return all[bestKey]
    }

    private static func looseIndex(in all: [String: EnrichCacheEntry]) -> [String: String] {
        if let cachedLooseIndex { return cachedLooseIndex }
        var index: [String: String] = [:]
        index.reserveCapacity(all.count)
        for k in all.keys {
            let loose = EnrichCacheKeys.looseKey(k)
            if let existing = index[loose] {
                if k < existing { index[loose] = k }
            } else {
                index[loose] = k
            }
        }
        cachedLooseIndex = index
        return index
    }

    /// 这首歌在本机缓存里有没有封面(collector 从网易云/QQ/Apple 解析出来的那张),
    /// 只走**认专辑**的两级查找,不退到忽略专辑的兜底。
    ///
    /// 给"当前正在播的这首歌"用(PlaybackCoordinator.refreshHighResCover):同一首歌在
    /// 不同专辑版本下封面经常是真的不一样(2026-08-26 用户报的「方大同 - 放不过自己」
    /// 就是实锤 —— `JTW 西游记 (Gold) [Explicit]` 是金底半脸特写,更早听过的
    /// `JTW西游记` 是黑底站姿,两张图完全不同)。这个调用点手里的专辑名来自系统 Now
    /// Playing、跟当前真正在播的这一版**必然对得上**,不像「最近播放」列表那边的 scrobble
    /// 专辑名可能跟本机播放器不一致——换句话说,这里没有"忽略专辑退一步"的必要性,
    /// 退了反而是拿错版本的风险。
    ///
    /// 两级查找同 coverURL:精确 key 命中,或退到"忽略空格/大小写/繁简"但**仍然认专辑**
    /// 的 looseMatch。
    ///
    /// ⚠️ 不要在这里加回 coverByArtistTitle() 那级兜底:换新专辑名的歌,collector 解析
    /// 完精确条目前的那几秒查空是**预期行为**,交给 refreshHighResCover 的
    /// enrichContentVersion 补查路(2026-08-24)在解析完后自动纠正 —— 那条路径的
    /// `onlyIfMissing: true` 只在"已经拿到精确匹配的图"时才安全跳过;一旦这里退到
    /// 忽略专辑的兜底给出一张**可能是别的版本**的图,onlyIfMissing 会把这张错图焊死到
    /// 换歌之前,后面精确条目写好了也不会被拿去纠正(这正是 2026-08-26 那次误封面的
    /// 根因)。
    public static func albumMatchedCoverURL(artist: String, title: String, album: String) -> URL? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        if let s = all[key]?.coverURL, let url = URL(string: s) { return url }
        if let s = looseMatch(key, in: all)?.coverURL, let url = URL(string: s) { return url }
        return nil
    }

    /// 比 albumMatchedCoverURL 再严一档:不光条目按专辑键命中,**这张封面自己**(cover_album,
    /// 即它在来源平台上属于哪张专辑)也得对得上请求的专辑。区别在哪:条目键对上只说明"这行
    /// 歌+专辑有一条缓存",而缓存里那张图可能是 collector 当年从错误版本解析来的(实测
    /// 陈奕迅《孤独探戈 (Live)》的旧条目键是 The Easy Ride,封面却是网易云错场次 Get A Life
    /// 的黑图)——只有 cover_album 也对上,这张图才有资格去**纠正**别的来源(Last.fm 自带图)。
    ///
    /// 给「最近记录」第①级纠错用,见 LastfmStatsService.coverURL(for:)。
    public static func albumVerifiedCoverURL(artist: String, title: String, album: String) -> URL? {
        guard let all = loadEntries() else { return nil }
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let entry = all[key] ?? looseMatch(key, in: all)
        guard let entry, coverAlbumVerified(coverAlbum: entry.coverAlbum, requestedAlbum: album),
              let s = entry.coverURL, let url = URL(string: s) else { return nil }
        return url
    }

    /// cover_album 与请求的专辑是否算同一张。宽松口径与 looseKey 同源(忽略空格/大小写/
    /// 繁简/合credit分隔符)——两侧字符串一个来自 collector 落盘、一个来自 Last.fm 行数据,
    /// 繁简/空格写法系统性不一致(实测行侧「陳奕迅」缓存侧「陈奕迅」)。纯函数,selftest 覆盖。
    public nonisolated static func coverAlbumVerified(coverAlbum: String?, requestedAlbum: String) -> Bool {
        guard let ca = coverAlbum?.trimmingCharacters(in: .whitespaces), !ca.isEmpty else { return false }
        let ra = requestedAlbum.trimmingCharacters(in: .whitespaces)
        guard !ra.isEmpty else { return false }
        return EnrichCacheKeys.looseKey(ca) == EnrichCacheKeys.looseKey(ra)
    }

    /// 这首歌在本机缓存里有没有封面(collector 从网易云/QQ/Apple 解析出来的那张)。
    ///
    /// 给「最近播放」列表当 Last.fm 之外的兜底用:那个列表的封面本来**全部**来自 Last.fm
    /// (scrobble 自带图 → track.getInfo → 同专辑兄弟),而 Last.fm 对中文曲库缺图非常
    /// 常见 —— 2026-08-14 用户报的「陶喆 - 聖誕之吻」就是三级全空(Last.fm 只给它那张所有
    /// 缺图实体共用的白星占位图,被 imageURL() 正确滤掉),而同一张专辑网易云是有图的。
    ///
    /// 三级查找(比 albumMatchedCoverURL 多退一步):
    ///  1. 归一化 key 精确命中 —— scrobble 本来就是本机 collector 上报的,三段字符串跟缓存
    ///     key 同源,这一级就能中。
    ///  2. 退到"歌手+歌名"(忽略专辑、忽略大小写)—— 手机端桥接过来的 scrobble 专辑名可能
    ///     跟本机播放器报的不一样。
    ///
    /// 刻意不做繁简折叠:本机播放写进缓存的和上报给 Last.fm 的是**同一批字符串**,折了也
    /// 不多命中一条,反而可能把两首真的不同名的歌并到一起。
    ///
    /// ⚠️ 这一级"忽略专辑"的兜底只适合"专辑名本来就不可信/拿不到精确对照"的消费方
    /// (这里,以及 IdleStandbyView 的"上一首"占位图)。当前正在播的这首歌请用
    /// albumMatchedCoverURL——原因见它的注释。
    public static func coverURL(artist: String, title: String, album: String) -> URL? {
        if let url = albumMatchedCoverURL(artist: artist, title: title, album: album) {
            return url
        }
        guard let all = loadEntries() else { return nil }
        if let s = Self.coverURLString(in: coverByArtistTitle(), artist: artist, title: title),
           let url = URL(string: s) {
            return url
        }
        return nil
    }

    /// 在"忽略专辑"的封面索引里查一行:先精确歌手写法,再退到**合唱 credit 归并**写法。
    /// 纯函数,selftest 直接覆盖。
    ///
    /// 为什么要退这一步(2026-08-20 用户报「最近记录里这几首没封面」):同一次收听会以两种
    /// 歌手写法存在 —— 本机缓存 key 用的是播放器逐曲 credit(`英雄联盟/Sara Skinner`、
    /// `Edouard Brenneisen & 英雄联盟`),而 Last.fm 那一行记的是主歌手(`英雄联盟`、
    /// `Edouard Brenneisen`)。前两级(归一化 key 精确 / looseKey)都救不了:looseKey 只把
    /// 分隔符变体折成 `&`、不会把合唱者**去掉**。实测那一屏 6 首缺封面的行在这一级下全部
    /// 命中,而两首本来就有封面的对照行在这一级前就已经命中(所以加这级不会改变它们)。
    public nonisolated static func coverURLString(in index: [String: String],
                                                  artist: String, title: String) -> String? {
        if let s = index[artistTitleKey(artist: artist, title: title)] { return s }
        let merged = ArtistCredit.mergeArtist(artist)
        guard merged != artist else { return nil }
        return index[artistTitleKey(artist: merged, title: title)]
    }

    /// 把封面 URL 换成"能拿到最大那一档"的形态。
    ///
    /// 三个图源三套机制,都是实测量出来的,不是照文档猜的:
    ///
    /// ① **网易云**:collector 存进缓存的 URL 尾巴上带着 `?param=600y600`(给列表里 26pt
    /// 的小图用,省流量)。那个 param **只降不升** —— 2026-08-17 实测:一张原生 800×800
    /// 的封面带 `param=600y600` 拿回来就是 600×600(`param=1200y1200` 也还是 800,它不
    /// 上采样);另一张原生 495×495 的,带不带 param 都是 495。所以对"要大图"的消费方,
    /// 那个 param 是在白扔分辨率,去掉才拿得到原图。
    ///
    /// ② **QQ 音乐**:尺寸档写在**路径**里(`T002R300x300M000<mid>.jpg`),换个数字就换
    /// 一档。2026-08-24 实测两个不同的 album mid:300/500/800 都 200,1000 与 2000 都
    /// **404** —— 所以 `qqCoverMaxEdge = 800` 是这个图床的天花板,不是随手挑的数。不带
    /// Referer 也照给(实测 200),而 App 这边发图片请求没有 Referer,所以能直接用。
    ///
    /// ③ **Apple**:thumb 管线要多大给多大(2026-08-24 实测同一张图 600/1000/1200/2000/
    /// 3000 全 200,999999 才 400)。取 1200 而不是更大:歌词窗口那张卡最大 460pt =
    /// 920px,1200 够用还有余量,2000 那一档一张就 1MB。
    ///
    /// 为什么 2026-08-24 开始要动 QQ/Apple(原来这两个源写的是"一个字都不许改"):用户
    /// 报 QQ 音乐的封面很模糊。QQ 音乐客户端往系统 Now Playing 报的封面就是 **300×300**
    /// (实测,见 PlaybackCoordinator.lowResArtworkThreshold),而缓存里那张高清替代图
    /// 当时也只有 300(QQ 源)/600(Apple 源)—— 顶到 820px 的封面卡上分别是 2.73× 和
    /// 1.37× 放大。光把替代路径打通不够,替代图本身也得先真的变大。
    ///
    /// nonisolated:纯 URL 换算,不碰任何静态缓存,selftest 要在非主线程上下文里断言它。
    public nonisolated static func nativeSizedCoverURL(_ url: URL) -> URL {
        if let u = neteaseNativeCoverURL(url) { return u }
        if let u = qqUpscaledCoverURL(url) { return u }
        if let u = appleUpscaledCoverURL(url) { return u }
        return url
    }

    /// QQ 音乐图床的最大边长 —— 再往上是 404,见 nativeSizedCoverURL 的注释。
    private static let qqCoverMaxEdge = 800
    /// Apple 图床取的那一档。它要多大给多大,所以这是"够用",不是"上限"。
    private static let appleCoverTargetEdge = 1200

    /// 摘掉网易云的 `?param=WxH`。nil = 不是网易云,或本来就没有那个参数。
    private nonisolated static func neteaseNativeCoverURL(_ url: URL) -> URL? {
        // 真实主机是 p1/p2/p4.music.126.net。判据写成"等于或以 . 分隔的子域",而不是光
        // hasSuffix("music.126.net") —— 后者连 evilmusic.126.net 都会当成网易云。
        guard let host = url.host,
              host == "music.126.net" || host.hasSuffix(".music.126.net")
        else { return nil }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty
        else { return nil }
        let kept = items.filter { $0.name != "param" }
        guard kept.count != items.count else { return nil } // 没有 param 可摘,原样返回
        // 只剩空数组时把整个 query 去掉,而不是留一个尾巴上的 "?" ——
        // 后者虽然多数服务器也认,但拼出来的字符串跟"没有查询串"不是同一个,
        // 会让 URLCache/内存缓存把它当成另一个 key。
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url
    }

    /// 把 QQ 图床路径里的尺寸档提到 800。nil = 不是 QQ 图床,或已经到顶。
    private nonisolated static func qqUpscaledCoverURL(_ url: URL) -> URL? {
        // 专辑封面在 y.qq.com、歌手头像在 y.gtimg.cn,两个域名同一套路径规则(都实测过
        // 800 给图)。判据用"等于"而不是 hasSuffix,理由同网易云那条。
        guard let host = url.host, host == "y.qq.com" || host == "y.gtimg.cn" else { return nil }
        guard url.path.hasPrefix("/music/photo_new/") else { return nil }
        let s = url.absoluteString
        // 尺寸段形如 T002R300x300M —— 只换这一段的数字,mid/扩展名/查询串一律照原样。
        guard let seg = s.range(of: "T[0-9]+R[0-9]+x[0-9]+M", options: .regularExpression),
              let size = s[seg].range(of: "[0-9]+x[0-9]+", options: .regularExpression)
        else { return nil }
        let edge = Int(s[size].prefix { $0.isNumber }) ?? 0
        guard edge > 0, edge < qqCoverMaxEdge else { return nil }
        return URL(string: s.replacingCharacters(in: size,
                                                 with: "\(qqCoverMaxEdge)x\(qqCoverMaxEdge)"))
    }

    /// 把 Apple 图床末段的 `600x600bb.jpg` 提到 1200。nil = 不是 Apple 图床 / 末段不是
    /// 那个形状 / 已经不小于目标档(2000 那种更大的档**不降**回来)。
    private nonisolated static func appleUpscaledCoverURL(_ url: URL) -> URL? {
        guard let host = url.host,
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
        else { return nil }
        // 只认 `<W>x<H>bb.<jpg|png>` 这一种末段 —— 本机缓存里 82 条 Apple 封面清一色是
        // `600x600bb.jpg`(2026-08-24 清点)。别的变体(`-999`、`sr`、裁切后缀)没实测过,
        // 一律不动:改错了是直接 404、整张封面消失,比"稍微软一点"糟得多。
        let last = url.lastPathComponent
        guard last.range(of: "^[0-9]+x[0-9]+bb\\.(jpg|png)$", options: .regularExpression) != nil
        else { return nil }
        let edge = Int(last.prefix { $0.isNumber }) ?? 0
        guard edge > 0, edge < appleCoverTargetEdge else { return nil }
        let ext = last.hasSuffix(".png") ? "png" : "jpg"
        let bumped = "\(appleCoverTargetEdge)x\(appleCoverTargetEdge)bb.\(ext)"
        // 用字面量倒查末段再替换,而不是 deletingLastPathComponent()+append ——
        // 后者对带查询串的 URL 行为没实测过。⚠️ .backwards 不能跟 .regularExpression
        // 同用(会被静默忽略),这里是纯字面量查找,所以是对的。
        let s = url.absoluteString
        guard let r = s.range(of: last, options: .backwards) else { return nil }
        return URL(string: s.replacingCharacters(in: r, with: bumped))
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
        var covers: [String: String] = [:]
        for (key, entry) in cachedEntries ?? [:] {
            guard let cover = entry.coverURL, !cover.isEmpty else { continue }
            covers[key] = cover
        }
        let index = Self.coverIndexByArtistTitle(covers)
        cachedCoverIndex = index
        return index
    }

    /// 从「缓存 key → 封面 URL」建出忽略专辑的封面索引。纯函数,selftest 直接覆盖。
    ///
    /// 每个条目进**两个**键:歌手写法原样的精确键,以及合唱 credit 归并到主歌手之后的别名键
    /// (见 coverURLString 里为什么需要它)。别名只填精确键没占的位置 —— 精确写法永远优先,
    /// 别让一条合唱条目的封面盖掉同名单人条目自己的封面。
    ///
    /// 按 key 排序遍历:同一首歌出现在多张专辑里时"先到先得"(都是这首歌的封面,选哪张都不
    /// 算错),但 Dictionary 的遍历顺序每次进程启动都不一样 —— 不定序的话同一份缓存在两次
    /// 启动里可能给出不同的图,是个查起来很费劲的"偶发不一致"。
    public nonisolated static func coverIndexByArtistTitle(_ covers: [String: String]) -> [String: String] {
        var index: [String: String] = [:]
        var aliases: [String: String] = [:]
        for key in covers.keys.sorted() {
            guard let cover = covers[key], !cover.isEmpty else { continue }
            let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let artist = String(parts[0]), title = String(parts[1])
            let exact = artistTitleKey(artist: artist, title: title)
            if index[exact] == nil { index[exact] = cover }
            let alias = artistTitleKey(artist: ArtistCredit.mergeArtist(artist), title: title)
            if alias != exact, aliases[alias] == nil { aliases[alias] = cover }
        }
        for (key, cover) in aliases where index[key] == nil { index[key] = cover }
        return index
    }

    /// 缓存文件的 mtime。给"要不要重算派生表"这类判断用 —— 调用方自己存一份上次的值,
    /// 变了才重算(见 LastfmStatsService.refreshLocalCoversIfCacheChanged)。
    public static func cacheModifiedAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
    }

    // ---- 解码调度(2026-08-20 性能审计重构) --------------------------------------
    //
    // 问题形状:缓存是全库单文件(现 ~11.6MB/900+ 条,设计上永不清理、单调增长),collector
    // 给**任何一首歌**写盘(新歌解析/译文回填/重打分/专辑预取最多 30 首逐个落盘)都 bump
    // mtime——原来 mtime 一变就在 @MainActor 上同步整读+decode,release 实测 32-47ms/次,
    // 专辑预取期约每 2s 一停,正撞 20Hz tick 和 30Hz 逐字填色,是播放中肉眼可见卡顿的最大
    // 单一来源。
    //
    // 现在:mtime 变化时**立即返回旧缓存**(与歌词本来就异步到达的语义一致),同时起一个
    // 带世代号的后台解码,完成后回主线程原子替换并经 onContentAdopted 回捅一次 poll ——
    // 陈旧窗口 ≈ 解码时长(几十 ms)+一次 poll 往返,不是被动等下一拍。调用方
    // (LocalPlaybackSource.apply)据 decodedContentVersion(**已解码代**的 mtime,不是
    // 文件即时 mtime)判断"要不要重灌引擎"——后台解码完成让版本推进,下一拍自然触发
    // reload 并命中新缓存。⚠️ 不能拿文件 mtime 当触发键:stale 返回窗口里 mtime 已变而
    // 内容未换,拿它触发会把 lastEnrichMTime 提前推进,后台解码完成后再没有任何东西触发
    // reload,新歌词永远不上屏。
    //
    // 两个例外仍走同步解码:①首次(cachedEntries == nil,冷启动/内存压力清空后)——保住
    // "启动即有词",一次 ~40ms 在启动期无感;②reloadNow()(「歌词管理」保存/删除后的
    // 强制重读)——用户显式操作,必须立刻读到刚写的内容,50ms 可接受,且推进世代号把
    // 在飞的旧后台结果作废(对抗核实钉的豁免入口)。
    // 解码失败(文件损坏/半写状态)保留旧缓存不清空——下一拍 mtime 仍不等,自然重试。

    /// 「当前已解码内容」对应的文件 mtime。给 apply() 当重灌触发键(见上面那段注释)。
    public static var decodedContentVersion: Date? { cachedMTime }

    /// 每拍 poll 调一次:stat 文件,内容落后时安排解码(首次同步、其余后台)。
    public static func refreshIfNeeded() {
        let mtime = fileModificationDate
        if mtime == cachedMTime { return }
        guard mtime != nil else {
            // 文件被删了(几乎只发生在手动清理):同步清空,行为与旧实现一致。
            cachedMTime = nil
            cachedEntries = nil
            cachedCoverIndex = nil
            cachedLooseIndex = nil
            return
        }
        if cachedEntries == nil {
            decodeSynchronously()
        } else {
            kickBackgroundDecode()
        }
    }

    /// 同步重读(「歌词管理」保存/删除后由 forceReloadLyricsForCurrentTrack 调)。
    public static func reloadNow() {
        decodeGeneration += 1 // 作废在飞的后台解码结果
        inFlightGeneration = nil
        decodeSynchronously()
    }

    private static func decodeSynchronously() {
        // mtime 取读文件**之前**的:rename 发生在 stat 与 read 之间时,读到的是更新的内容
        // 而记的是旧 mtime——下一拍会再解一次,方向安全;反过来记新 mtime 配旧内容会把
        // 一版内容永久漏掉。
        let mtime = fileModificationDate
        guard let data = try? Data(contentsOf: cacheURL),
              let all = try? JSONDecoder().decode([String: EnrichCacheEntry].self, from: data)
        else {
            cachedMTime = nil
            cachedEntries = nil
            cachedCoverIndex = nil
            cachedLooseIndex = nil
            return
        }
        adopt(entries: all, mtime: mtime)
    }

    private static func kickBackgroundDecode() {
        guard inFlightGeneration == nil else { return } // 在飞的完成后,下一拍 poll 自然再 kick(2s 节拍天然节流)
        decodeGeneration += 1
        let gen = decodeGeneration
        inFlightGeneration = gen
        let url = cacheURL
        Task.detached(priority: .utility) {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let decoded: [String: EnrichCacheEntry]? = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([String: EnrichCacheEntry].self, from: $0) }
            await MainActor.run {
                if inFlightGeneration == gen { inFlightGeneration = nil }
                guard gen == decodeGeneration else { return } // 被 reloadNow/压力清空顶掉
                guard let decoded else { return }             // 失败保留旧缓存,下一拍重试
                adopt(entries: decoded, mtime: mtime, notify: true)
            }
        }
    }

    /// 后台解码采纳新内容后的通知钩子(LocalPlaybackSource 注册成"捅一次 poll")——
    /// 不加它的话,内容推进要等下一拍 poll 才被看见,陈旧窗口是**两拍**(kick 一拍 +
    /// 发现一拍):播放档 ~4s、暂停档 ~12s,"暂停看这句歌词等译文"这个典型场景感知
    /// 明显变慢(对抗核实抓出的口径差)。钩子只在真的采纳了新内容时调。
    public static var onContentAdopted: (() -> Void)?

    private static func adopt(entries: [String: EnrichCacheEntry], mtime: Date?, notify: Bool = false) {
        cachedMTime = mtime
        cachedEntries = entries
        cachedCoverIndex = nil  // 内容换了,派生索引跟着作废,下次要用时按新内容重建
        cachedLooseIndex = nil
        if notify { onContentAdopted?() }
    }

    /// 内存压力时把全量缓存让出去(解码后的全曲库歌词字符串常驻 ~21MB,而稳态消费只有
    /// 当前 1 个 key)。清空 = 回到冷启动态,下一拍 poll 同步重建。⚠️ 如实说明让出的
    /// 时效(对抗核实订正):**有快照在轮询**的状态下,下一拍(2-10s)就会冷启动式重建,
    /// 让出只有一拍;真正长效的让出发生在**空闲态**(无播放时 poll 是 10s 档且 lookup
    /// 不消费)。压力事件罕见,一次 ~40ms 重建换周期性让出仍是划算的。
    /// 世代号必须一并推进:不推进的话,清空瞬间还在飞的后台解码回来会把刚让出的缓存
    /// 原样灌回,极端时序(清空→冷路径同步解到新版→更旧的在飞结果后到)还会把内容
    /// 倒退一版(对抗核实抓出的竞态)。
    public static func installMemoryPressureRelief() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                decodeGeneration += 1
                inFlightGeneration = nil
                cachedMTime = nil
                cachedEntries = nil
                cachedCoverIndex = nil
                cachedLooseIndex = nil
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private static func loadEntries() -> [String: EnrichCacheEntry]? {
        // 常规读取路径不再自己 stat/解码:poll 每拍的 refreshIfNeeded() 负责推进内容。
        // 这里兜一层"从未加载过"(App 启动后第一次消费先于第一拍 poll,或设置窗的
        // LastfmStatsService 独立调进来)的同步初始化。
        if cachedEntries == nil { decodeSynchronously() }
        return cachedEntries
    }
}
