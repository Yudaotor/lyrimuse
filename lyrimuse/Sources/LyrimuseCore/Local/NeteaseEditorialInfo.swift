import Foundation

/// 歌手简介、专辑简介的第三个来源:网易云音乐的歌手介绍(`/api/artist/introduction`)和专辑介绍(`/api/v1/album/<id>`),
/// 不用登录、不加密,跟引擎问网易云的那些接口同一类。Apple Music 明确没有时才问,排在 Last.fm 前面;**只在中文界面问**
/// (`isUsable`):两种介绍都只有中文,接口也没有语言参数(实测 Taylor Swift、米津玄師的歌手介绍,欧美专辑的介绍,
/// 也都是中文写的),别的界面问来了也看不懂。
///
/// 歌手、专辑都只从这首歌的网易云歌曲页来:enrich 缓存的 `netease_url` → 歌曲详情 `/api/song/detail` 里的署名和所在专辑,
/// 不按名字搜 —— 同名歌手不少(「圈9」搜出来就有两位),挂错人比没有更糟。署名里挑哪一位同 Apple 那一路
/// (`AlbumEditorialNotes.pickArtist`);专辑要跟正在放的对得上(`Album.matches`):同一首歌常收在好几张专辑里,
/// 网易云挂的那张未必是正在放的那张。
///
/// 歌手正文用总述 `briefDesc`(网易云「歌手详情」页顶上那段「某某简介」);总述是空的才用分段(`introduction` 的 `ti` / `txt`),
/// 「演艺经历」这类上千字的长段不放进卡片。专辑正文用专辑页的 `description`(`briefDesc` 实测都是空的;歌曲详情里带的
/// 那份专辑也是空的,所以要单独问专辑页),保留原文的分行 —— 宣传文案常一句一行、段与段之间空一行。
/// 网易云的正文是简体,繁体界面转成繁体。展示时注明出处(卡片底部「来自网易云音乐」)。纯函数部分 selftest 钉着。
public enum NeteaseEditorialInfo {
    /// 解析结果。`.none` = 网易云明确没有(没有这位歌手 / 这张专辑、或者有但没有介绍);形状不对是 nil(不记结论,下次再试)。
    public enum Parsed: Equatable, Sendable {
        case text(String)
        case none
    }

    /// 歌曲详情里用得上的两样:署名(按网易云给的顺序)和所在专辑(没有为 nil)。
    public struct Song: Equatable, Sendable {
        public let artists: [AlbumEditorialNotes.ArtistLink]
        public let album: Album?

        public init(artists: [AlbumEditorialNotes.ArtistLink], album: Album?) {
            self.artists = artists
            self.album = album
        }
    }

    /// 网易云上这首歌所在的专辑:ID、名字,和别名(`alias` / `transName`,常是另一种语言的名字:
    /// 《最伟大的作品》的「Greatest Works of Art」、《Coloring Stephy》的「有声有色」)。
    public struct Album: Equatable, Sendable {
        public let id: Int64
        public let name: String
        public let aliases: [String]

        public init(id: Int64, name: String, aliases: [String] = []) {
            self.id = id
            self.name = name
            self.aliases = aliases
        }

        /// 跟正在放的专辑是不是同一张:名字或任一别名跟它 `PresenceCover.sameAlbum`(繁简、大小写、空格、Apple 加的
        /// ` - Single` / ` - EP` 都不算差别)。正在放的没报专辑名比不了,算对不上。版本不同(`(Deluxe Edition)`、
        /// `(Digital EP)`)也算对不上 —— 宁可退到下一个来源,不拿另一张的介绍顶上。
        public func matches(playing: String) -> Bool {
            ([name] + aliases).contains { PresenceCover.sameAlbum(playing, $0) }
        }
    }

    /// 分段里比这长的不放进卡片(只在总述是空的时候才用分段)。
    static let maxSectionLength = 2000

    /// 网易云歌曲页(`https://music.163.com/song?id=<数字>`,带 `#/` 的也认)里的歌曲 ID;别的形状为 nil。
    public static func songID(fromSongPage url: URL?) -> Int64? {
        guard let url, let host = url.host?.lowercased(), host == "music.163.com" || host.hasSuffix(".music.163.com")
        else { return nil }
        // `#/song?id=` 的参数在片段里,`URLComponents` 读不到 query,把片段当路径再拆一次。
        let candidates = [url.absoluteString, url.fragment.map { "https://music.163.com" + $0 } ?? ""]
        for raw in candidates {
            guard let parts = URLComponents(string: raw), parts.path.hasSuffix("/song"),
                  let value = parts.queryItems?.first(where: { $0.name == "id" })?.value,
                  let id = Int64(value), id > 0 else { continue }
            return id
        }
        return nil
    }

    public static func songDetailURL(songID: Int64) -> URL? {
        URL(string: "https://music.163.com/api/song/detail?ids=%5B\(songID)%5D")
    }

    public static func introductionURL(artistID: Int64) -> URL? {
        URL(string: "https://music.163.com/api/artist/introduction?id=\(artistID)")
    }

    /// 专辑页。老端点 `/api/album/<id>` 不带登录常被风控(`code` -462),用引擎也在用的 v1 端点。
    public static func albumURL(albumID: Int64) -> URL? {
        URL(string: "https://music.163.com/api/v1/album/\(albumID)")
    }

    /// 歌曲详情 → 这首的署名和所在专辑。`code` 不是 200、形状不对为 nil;没有这首歌是署名为空、专辑为 nil。
    /// ID 为 0 的署名(网易云给没收录的歌手占位用)不算;专辑 ID 为 0 或者没有名字算没有专辑。
    public static func song(fromDetail data: Data) -> Song? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == 200,
              let songs = root["songs"] as? [[String: Any]] else { return nil }
        guard let song = songs.first else { return Song(artists: [], album: nil) }
        let credits = song["artists"] as? [[String: Any]] ?? song["ar"] as? [[String: Any]] ?? []
        let artists = credits.compactMap { credit -> AlbumEditorialNotes.ArtistLink? in
            guard let id = (credit["id"] as? NSNumber)?.int64Value, id > 0,
                  let name = trimmed(credit["name"]) else { return nil }
            return AlbumEditorialNotes.ArtistLink(name: name, id: id)
        }
        return Song(artists: artists, album: album(from: song["album"] as? [String: Any] ?? song["al"] as? [String: Any]))
    }

    /// 歌手介绍 → 正文。`code` 是 404(没有这位歌手)或者总述、分段都空是 `.none`;`code` 是别的(风控之类)、形状不对为 nil。
    /// 总述按行收拾:去掉每行首尾空白和空行,段与段之间空一行。
    public static func introduction(from data: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = (root["code"] as? NSNumber)?.intValue else { return nil }
        if code == 404 { return Parsed.none }
        guard code == 200 else { return nil }
        let brief = EditorialText.paragraphs(root["briefDesc"] as? String ?? "")
        if !brief.isEmpty { return .text(brief) }
        let sections = (root["introduction"] as? [[String: Any]] ?? []).compactMap { section -> String? in
            let body = EditorialText.paragraphs(section["txt"] as? String ?? "")
            guard !body.isEmpty, body.count <= maxSectionLength else { return nil }
            let title = (section["ti"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? body : title + "\n" + body
        }
        return sections.isEmpty ? Parsed.none : .text(sections.joined(separator: "\n\n"))
    }

    /// 专辑页 → 介绍。`code` 是 404(没有这张专辑)或者介绍是空的为 `.none`;`code` 是别的(风控之类)、形状不对为 nil。
    /// 先用 `description`,空了才看 `briefDesc`;保留原文的分行(`EditorialText.lines`)。
    public static func albumDescription(from data: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = (root["code"] as? NSNumber)?.intValue else { return nil }
        if code == 404 { return Parsed.none }
        guard code == 200, let album = root["album"] as? [String: Any] else { return nil }
        for field in ["description", "briefDesc"] {
            let text = EditorialText.lines(album[field] as? String ?? "")
            if !text.isEmpty { return .text(text) }
        }
        return Parsed.none
    }

    /// 这个界面语言下问不问网易云:只在中文界面(简体、繁体)问 —— 网易云的介绍只有中文;问的话排在 Last.fm 前面
    /// (Last.fm 对中文歌手、中文专辑常常没有,或者只有英文)。
    public static func isUsable(uiLanguage: String) -> Bool {
        EditorialText.isChineseUI(uiLanguage)
    }

    /// 繁体界面(`zh-Hant`)把正文转成繁体;别的界面原样。
    public static func localized(_ text: String, uiLanguage: String) -> String {
        EditorialText.localized(text, uiLanguage: uiLanguage)
    }

    /// 这首的署名和所在专辑。nil = 没问成(网络、风控、形状不对),下次再试。
    public static func fetchSong(songID: Int64, session: URLSession = .shared) async -> Song? {
        guard let url = songDetailURL(songID: songID), let data = await fetch(url, operation: "song.detail", session: session)
        else { return nil }
        return song(fromDetail: data)
    }

    /// 这位歌手的介绍。nil = 没问成,下次再试。
    public static func fetchIntroduction(artistID: Int64, session: URLSession = .shared) async -> Parsed? {
        guard let url = introductionURL(artistID: artistID),
              let data = await fetch(url, operation: "artist.introduction", session: session) else { return nil }
        return introduction(from: data)
    }

    /// 这张专辑的介绍。nil = 没问成,下次再试。
    public static func fetchAlbumDescription(albumID: Int64, session: URLSession = .shared) async -> Parsed? {
        guard let url = albumURL(albumID: albumID),
              let data = await fetch(url, operation: "album.detail", session: session) else { return nil }
        return albumDescription(from: data)
    }

    // MARK: - 内部

    private static func album(from dict: [String: Any]?) -> Album? {
        guard let dict, let id = (dict["id"] as? NSNumber)?.int64Value, id > 0, let name = trimmed(dict["name"])
        else { return nil }
        let aliases = ((dict["alias"] as? [Any] ?? []) + [dict["transName"] as Any]).compactMap(trimmed)
        return Album(id: id, name: name, aliases: aliases)
    }

    /// 去掉首尾空白后非空的字符串;别的(空串、null、不是字符串)为 nil。
    private static func trimmed(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// 发一次 GET,记进对外请求审计日志。HTTP 不是 200、连不上都返回 nil。带浏览器的 User-Agent 和网易云的 Referer,
    /// 同引擎问网易云的口径(不带时容易被风控当成脚本)。
    private static func fetch(_ url: URL, operation: String, session: URLSession) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "netease", operation: operation, host: url.host ?? "music.163.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return status == 200 ? data : nil
        } catch {
            NetworkAuditLog.record(service: "netease", operation: operation, host: url.host ?? "music.163.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
