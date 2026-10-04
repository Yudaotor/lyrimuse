import Foundation

/// 「听得最多」榜单一行右键菜单里能直接进 App 打开的目标。只收进 App 的:Apple Music(`music://`)、
/// Spotify(`spotify:track:`)、KKBOX(`kkbox://song/…#view`)、Kaset(`kaset://play?v=`,打开就从这首开始放,菜单写成
/// 「播放」)、QQ 音乐(同样只能播放,见 `QQSongPlayLink`);网易云(`orpheus://` 只在它开着时生效)、Spotify 网页这类不收,
/// 见 12 章决策 21。
/// 数据全来自本机歌词缓存(引擎解析歌词时存的链接),零网络。
public struct ChartAppLinks: Sendable, Equatable {
    /// 歌曲:曲目链接(Music 打开专辑页并定位到这首);专辑:专辑页。
    public var appleMusic: URL?
    /// 歌曲:Spotify 曲目深链。
    public var spotify: URL?
    /// 歌曲:KKBOX 曲目页。
    public var kkbox: URL?
    /// 歌曲:在 Kaset 里从这首开始放(换掉它当前的队列),见 `PlatformLinks.kasetPlayURL`。
    public var kaset: URL?
    /// 歌曲:QQ 音乐 songmid。点击时换成数字歌曲 ID 再拼链接,见 `QQSongPlayLink`。
    public var qqSongMID: String?
    /// 歌手:缓存里这位歌手的一张 Apple Music 专辑。歌手页没有现成链接,点击时取这张专辑的页面、从署名里
    /// 拿到歌手 ID 再打开歌手页(专辑简介取歌手 ID 走的是同一条路,只连 music.apple.com)。
    public var artistAlbum: AlbumEditorialNotes.AlbumRef?
    /// 歌手:本机 MusicBrainz 身份缓存里这位歌手的 mbid。点击时查一次它在 MusicBrainz 上登记的平台主页
    /// (`ArtistPlatformPages`),拿到 Spotify / Apple Music 歌手页。
    public var artistMBID: String?
    /// 歌手:引擎后台预取好的平台主页(PlatformPagesCache)。有就直接打开;没有才在点击时按 mbid 现查。
    public var artistPages: ArtistPlatformPages.Pages?

    public init(appleMusic: URL? = nil, spotify: URL? = nil, kkbox: URL? = nil, kaset: URL? = nil, qqSongMID: String? = nil,
                artistAlbum: AlbumEditorialNotes.AlbumRef? = nil, artistMBID: String? = nil,
                artistPages: ArtistPlatformPages.Pages? = nil) {
        self.appleMusic = appleMusic
        self.spotify = spotify
        self.kkbox = kkbox
        self.kaset = kaset
        self.qqSongMID = qqSongMID
        self.artistAlbum = artistAlbum
        self.artistMBID = artistMBID
        self.artistPages = artistPages
    }

    public var isEmpty: Bool {
        appleMusic == nil && spotify == nil && kkbox == nil && kaset == nil && qqSongMID == nil && artistAlbum == nil
            && artistMBID == nil && artistPages == nil
    }
}

public enum ChartLinkKind: Sendable {
    case artist, album, track
}

/// 从歌词缓存条目建的查找表:歌曲按「歌手 + 歌名」(忽略专辑)、专辑按「歌手 + 专辑」、歌手按歌手名。
/// 键的口径跟榜单本机封面兜底同一套(`EnrichCacheReader.artistTitleKey` / `albumCoverKey`),合唱署名另按主歌手
/// 进一个别名键,只填精确键没占的位置。歌曲另有一张宽松键(繁简归一、去空格)的表,原样写法查不到时才用,见 `links`。
/// 按缓存 key 排序遍历,同一份缓存每次给出同一个结果。纯数据,selftest 直接覆盖。
public struct ChartLinkIndex: Sendable {
    public struct Row: Sendable {
        public let key: String
        public let appleMusicURL: String?
        public let spotifyTrackID: String?
        public let kkboxURL: String?
        public let youtubeMusicURL: String?
        public let qqMusicURL: String?

        public init(key: String, appleMusicURL: String?, spotifyTrackID: String?, kkboxURL: String?,
                    youtubeMusicURL: String? = nil, qqMusicURL: String? = nil) {
            self.key = key
            self.appleMusicURL = appleMusicURL
            self.spotifyTrackID = spotifyTrackID
            self.kkboxURL = kkboxURL
            self.youtubeMusicURL = youtubeMusicURL
            self.qqMusicURL = qqMusicURL
        }
    }

    var tracks: [String: ChartAppLinks] = [:]
    /// 歌曲的宽松键表:`looseKey(歌手) + "|" + looseKey(normalizedTitle(歌名))`。榜单行是 Last.fm 上的写法(常是繁体),
    /// 缓存键是引擎写的(多是简体),原样对不上。不并进 `tracks`:同一首歌两种写法都在缓存里时,原样那条优先。
    var looseTracks: [String: ChartAppLinks] = [:]
    var albums: [String: URL] = [:]
    var artists: [String: AlbumEditorialNotes.AlbumRef] = [:]

    /// `looseKey`:算宽松键的函数,默认就是 `EnrichCacheKeys.looseKey`。App 里传一个带记忆的版本进来:
    /// 九千多条缓存每条要算五次(歌手、主歌手、专辑两次、歌名一次),每次一遍繁简转换;歌手 / 专辑名大量重复,
    /// 歌名基本不重复,但那份记忆跨缓存版本保留,重建时只算新出现的写法。
    public static func build(_ rows: [Row], looseKey: (String) -> String = EnrichCacheKeys.looseKey) -> ChartLinkIndex {
        var index = ChartLinkIndex()
        var trackAliases: [String: ChartAppLinks] = [:]
        var looseTrackAliases: [String: ChartAppLinks] = [:]
        var albumAliases: [String: URL] = [:]
        var artistAliases: [String: AlbumEditorialNotes.AlbumRef] = [:]
        for row in rows.sorted(by: { $0.key < $1.key }) {
            let parts = row.key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let artist = String(parts[0]), title = String(parts[1]), album = String(parts[2])
            let merged = ArtistCredit.mergeArtist(artist)

            let track = ChartAppLinks(
                appleMusic: MusicCatalogSearch.musicSchemeURL(row.appleMusicURL),
                spotify: SpotifyURI.deepLink("spotify:track:" + (row.spotifyTrackID ?? "")),
                kkbox: PlatformLinks.kkboxAppURL(songPage: row.kkboxURL ?? ""),
                kaset: PlatformLinks.kasetPlayURL(watchURL: row.youtubeMusicURL ?? ""),
                qqSongMID: PlatformLinks.qqSongMID(songPage: row.qqMusicURL ?? ""))
            if !track.isEmpty {
                let exact = EnrichCacheReader.artistTitleKey(artist: artist, title: title)
                if index.tracks[exact] == nil { index.tracks[exact] = track }
                let alias = EnrichCacheReader.artistTitleKey(artist: merged, title: title)
                if alias != exact, trackAliases[alias] == nil { trackAliases[alias] = track }
                let looseTitle = "|" + looseKey(EnrichCacheKeys.normalizedTitle(title))
                let looseExact = looseKey(artist) + looseTitle
                if index.looseTracks[looseExact] == nil { index.looseTracks[looseExact] = track }
                let looseAlias = looseKey(merged) + looseTitle
                if looseAlias != looseExact, looseTrackAliases[looseAlias] == nil { looseTrackAliases[looseAlias] = track }
            }

            guard let ref = AlbumEditorialNotes.albumRef(fromAppleMusicURL: row.appleMusicURL) else { continue }
            if !album.isEmpty,
               let albumURL = MusicCatalogSearch.musicSchemeURL(
                   AlbumEditorialNotes.pageURL(albumID: ref.id, storefront: ref.storefront ?? "")?.absoluteString) {
                // 同 EnrichCacheReader.albumCoverKey,只是经传进来的 looseKey 算。
                let looseAlbum = looseKey(album)
                let exact = looseKey(artist) + "|" + looseAlbum
                if index.albums[exact] == nil { index.albums[exact] = albumURL }
                let alias = looseKey(merged) + "|" + looseAlbum
                if alias != exact, albumAliases[alias] == nil { albumAliases[alias] = albumURL }
            }
            let exactArtist = looseKey(artist)
            if index.artists[exactArtist] == nil { index.artists[exactArtist] = ref }
            let aliasArtist = looseKey(merged)
            if aliasArtist != exactArtist, artistAliases[aliasArtist] == nil { artistAliases[aliasArtist] = ref }
        }
        for (k, v) in trackAliases where index.tracks[k] == nil { index.tracks[k] = v }
        for (k, v) in looseTrackAliases where index.looseTracks[k] == nil { index.looseTracks[k] = v }
        for (k, v) in albumAliases where index.albums[k] == nil { index.albums[k] = v }
        for (k, v) in artistAliases where index.artists[k] == nil { index.artists[k] = v }
        return index
    }

    /// 榜单一行(歌手行 `artist` 就是行名,`name` 不用)的进 App 目标。先按原样写法查,再按主歌手查;都没有时,
    /// 歌曲再按宽松键查,最后用 `aliasArtist` 给的另一种歌手写法查(App 传本机推断的歌手别名,`Jason Chan → 陳柏宇`,
    /// 见 `PlayCountFold.canonicalArtist`;给 nil 或给的就是上面查过的写法时跳过)。都没有返回 nil。
    public func links(kind: ChartLinkKind, artist: String, name: String,
                      aliasArtist: (String) -> String? = { _ in nil }) -> ChartAppLinks? {
        var candidates = [artist, ArtistCredit.mergeArtist(artist)]
        for a in candidates {
            switch kind {
            case .track:
                if let hit = tracks[EnrichCacheReader.artistTitleKey(artist: a, title: name)] { return hit }
            case .album:
                if let url = albums[EnrichCacheReader.albumCoverKey(artist: a, album: name)] {
                    return ChartAppLinks(appleMusic: url)
                }
            case .artist:
                if let ref = artists[EnrichCacheKeys.looseKey(a)] { return ChartAppLinks(artistAlbum: ref) }
            }
        }
        let alias = aliasArtist(artist).map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty || candidates.contains($0) ? nil : $0 }
        switch kind {
        case .track:
            if let alias { candidates.append(alias) }
            let looseTitle = "|" + EnrichCacheKeys.looseKey(EnrichCacheKeys.normalizedTitle(name))
            for a in candidates {
                if let hit = looseTracks[EnrichCacheKeys.looseKey(a) + looseTitle] { return hit }
            }
        case .album:
            if let alias, let url = albums[EnrichCacheReader.albumCoverKey(artist: alias, album: name)] {
                return ChartAppLinks(appleMusic: url)
            }
        case .artist:
            if let alias, let ref = artists[EnrichCacheKeys.looseKey(alias)] { return ChartAppLinks(artistAlbum: ref) }
        }
        return nil
    }
}

/// 榜单卡底那行概况里的「前 N 名占总次数百分之几」。总次数没有(还没取到 / 取失败)或为 0 时返回 nil;
/// 两个数来自不同接口(榜单 vs 收听记录总数),前 N 名之和偶尔会略超总数,封顶 100。
public enum ChartSummary {
    public static func topShare(counts: [Int], total: Int?) -> Int? {
        guard let total, total > 0 else { return nil }
        let top = counts.reduce(0, +)
        return min(100, Int((Double(top) / Double(total) * 100).rounded()))
    }
}

/// 榜单右键「在 QQ 音乐中播放」的链接。QQ 音乐对外只有「播放这一首」一种入口:`qqmusicmac://` 的 playsong 命令,
/// 拼法照 y.qq.com 网页「用客户端播放」,分隔符是 `==` 和 `&&`(写成普通 `=` / `&` 它不认),要的是数字歌曲 ID。
/// 缓存里只有 songmid,点击时按 mid 查一次 `fcg_play_single_song`(引擎取 QQ 歌曲详情用的同一个接口)。
/// 纯函数部分 selftest 直接覆盖。
public enum QQSongPlayLink {
    public struct Song: Sendable, Equatable {
        public let id: Int
        public let type: Int

        public init(id: Int, type: Int) {
            self.id = id
            self.type = type
        }
    }

    public static func lookupURL(mid: String) -> URL? {
        guard PlatformLinks.isPlausibleQQMid(mid), mid.allSatisfy(\.isASCII) else { return nil }
        return URL(string: "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?format=json&platform=yqq"
            + "&inCharset=utf8&outCharset=utf-8&songmid=" + mid)
    }

    /// 接口回的 `{"code":0,"data":[{"id":…,"type":…}]}`。code 不是 0、没有条目、id 不是正数都返回 nil。
    public static func parse(_ data: Data) -> Song? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["code"] as? Int) == 0,
              let first = (root["data"] as? [[String: Any]])?.first,
              let id = first["id"] as? Int, id > 0 else { return nil }
        let type = first["type"] as? Int ?? 0
        return type >= 0 ? Song(id: id, type: type) : nil
    }

    public static func playURL(_ song: Song) -> URL? {
        guard song.id > 0, song.type >= 0 else { return nil }
        return URL(string: "qqmusicmac://QQMusic/?version==1173&&from==y.qq.com&&cmd_count==1&&cmd_0==playsong"
            + "&&id_0==\(song.id)&&songtype_0==\(song.type)&&info_0==&&quality_0==quality")
    }
}

/// 歌手在各平台的主页,来自 MusicBrainz 歌手条目上登记的链接(`/ws/2/artist/<mbid>?inc=url-rels`)。
/// 本机没有任何平台的歌手 ID,而 mbid 已经在身份缓存里(歌手榜合并用的那份),查一次就能拿到 Spotify / Apple Music
/// 歌手页;不用登录、不走 iTunes Search。纯函数部分 selftest 直接覆盖。
public enum ArtistPlatformPages {
    public struct Pages: Sendable, Equatable {
        /// `spotify:artist:<22 位 ID>`,进 Spotify 客户端。
        public var spotify: URL?
        /// Apple Music 歌手页,已改写成 `music://`。
        public var appleMusic: URL?

        public init(spotify: URL? = nil, appleMusic: URL? = nil) {
            self.spotify = spotify
            self.appleMusic = appleMusic
        }
    }

    public static func lookupURL(mbid: String) -> URL? {
        let id = mbid.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return URL(string: "https://musicbrainz.org/ws/2/artist/\(id)?inc=url-rels&fmt=json")
    }

    /// 从 MusicBrainz 返回里挑出 Spotify 歌手页与 Apple Music 歌手页;别的链接(专辑、曲目、其它平台)不要。
    public static func parse(_ data: Data) -> Pages {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let relations = root["relations"] as? [[String: Any]] else { return Pages() }
        var pages = Pages()
        for rel in relations {
            guard let raw = (rel["url"] as? [String: Any])?["resource"] as? String,
                  let url = URL(string: raw), let host = url.host else { continue }
            let parts = url.path.split(separator: "/").map(String.init)
            if pages.spotify == nil, host == "open.spotify.com",
               let i = parts.firstIndex(of: "artist"), i + 1 < parts.count {
                let id = parts[i + 1]
                if SpotifyURI.isBase62ID(Substring(id)) { pages.spotify = URL(string: "spotify:artist:" + id) }
            }
            if pages.appleMusic == nil, host == "music.apple.com", parts.contains("artist"),
               let last = parts.last, Int64(last) != nil {
                pages.appleMusic = MusicCatalogSearch.musicSchemeURL(raw)
            }
        }
        return pages
    }

    /// 身份缓存(名字 → mbid)里按行名查:先原样,再忽略大小写。
    public static func mbid(for name: String, in cache: [String: String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let hit = cache[trimmed], !hit.isEmpty { return hit }
        let lower = trimmed.lowercased()
        return cache.first { $0.key.lowercased() == lower && !$0.value.isEmpty }?.value
    }

    /// 读本机 MusicBrainz 身份缓存,只取 mbid。文件不在或解析不了返回空表。
    public static func loadMBIDs(configDir: URL = LyrimusePaths.configDir) -> [String: String] {
        struct Identity: Decodable { var mbid: String? }
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent("lyrimuse-artist-identity-cache.json")),
              let m = try? JSONDecoder().decode([String: Identity].self, from: data) else { return [:] }
        return m.compactMapValues { $0.mbid }.filter { !$0.value.isEmpty }
    }
}

/// 引擎后台预取的平台主页缓存(`lyrimuse-platform-pages-cache.json`,引擎 platformpages.go 写):
/// 歌手按 mbid 存 Spotify 歌手 ID 与 Apple Music 歌手页,专辑、歌曲按 `albumKey`(歌手 + 专辑名 / 歌名)存 Spotify ID。
/// 只读,不联网。
public struct PlatformPagesCache: Sendable {
    struct Artist: Decodable, Sendable {
        var spotify: String?
        var apple: String?
    }
    struct Album: Decodable, Sendable {
        var spotify: String?
    }
    struct File: Decodable {
        var artists: [String: Artist]?
        var albums: [String: Album]?
        var tracks: [String: Album]?
    }

    var artists: [String: Artist] = [:]
    var albums: [String: Album] = [:]
    var tracks: [String: Album] = [:]

    public static let fileName = "lyrimuse-platform-pages-cache.json"

    public init() {}

    public static func parse(_ data: Data) -> PlatformPagesCache {
        var cache = PlatformPagesCache()
        guard let f = try? JSONDecoder().decode(File.self, from: data) else { return cache }
        cache.artists = f.artists ?? [:]
        cache.albums = f.albums ?? [:]
        cache.tracks = f.tracks ?? [:]
        return cache
    }

    public static func load(configDir: URL = LyrimusePaths.configDir) -> PlatformPagesCache {
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent(fileName)) else { return PlatformPagesCache() }
        return parse(data)
    }

    /// 专辑 / 歌曲条目的键:歌手名与专辑名(歌名)去首尾空白、转小写。引擎 platformAlbumKey 必须同一个算法。
    public static func albumKey(artist: String, album: String) -> String {
        artist.trimmingCharacters(in: .whitespaces).lowercased() + "|"
            + album.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 这位歌手预取好的平台主页;没有预取过、或两个平台都没登记返回 nil。
    public func artistPages(mbid: String) -> ArtistPlatformPages.Pages? {
        guard let a = artists[mbid] else { return nil }
        var pages = ArtistPlatformPages.Pages()
        if let id = a.spotify, SpotifyURI.isBase62ID(Substring(id)) { pages.spotify = URL(string: "spotify:artist:" + id) }
        pages.appleMusic = MusicCatalogSearch.musicSchemeURL(a.apple)
        return pages == ArtistPlatformPages.Pages() ? nil : pages
    }

    /// 这张专辑的 Spotify 专辑深链(`spotify:album:<ID>`);没有返回 nil。
    public func albumSpotify(artist: String, album: String) -> URL? {
        guard let id = albums[Self.albumKey(artist: artist, album: album)]?.spotify,
              SpotifyURI.isBase62ID(Substring(id)) else { return nil }
        return URL(string: "spotify:album:" + id)
    }

    /// 这首歌的 Spotify 曲目深链(`spotify:track:<ID>`);没有返回 nil。
    public func trackSpotify(artist: String, title: String) -> URL? {
        guard let id = tracks[Self.albumKey(artist: artist, album: title)]?.spotify,
              SpotifyURI.isBase62ID(Substring(id)) else { return nil }
        return URL(string: "spotify:track:" + id)
    }
}
