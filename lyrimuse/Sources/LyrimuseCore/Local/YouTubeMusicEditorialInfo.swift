import Foundation

/// 专辑简介、歌手简介的一个来源:YouTube Music 专辑页 / 歌手页上的介绍。那其实是维基百科条目,按请求的界面语言给
/// (`descriptionHL`:简体界面 zh-CN、繁体界面 zh-TW、英文界面 en),结尾带一段「来自 Wikipedia(链接)按 CC BY-SA 授权」。
/// 不用登录(innertube 网页客户端身份,同 `KasetVideoKind`、引擎的 ytmusic.go)。**所有界面语言都问**:网易云、汽水的介绍
/// 只有中文,非中文界面原来只剩 Last.fm(还要连账号)。界面语言那一版没有时退到英文版(实测 Boards of Canada、米津玄師的
/// 专辑在中文维基没有条目、英文有)。
///
/// **只收带维基出处的介绍**(`wikipediaText`):歌手页在英文界面常摆频道自己的宣传语(实测 Taylor Swift:「New album … Out
/// October 3」加购买链接),那不是简介,算没有。出处那一段(最后一段,后面跟着维基和授权协议的链接)剥掉,卡片底部注明
/// 「来自维基百科」。
///
/// 专辑从哪来:用 Kaset / YouTube Music 网页版放的歌,缓存里有播放器给的专辑 ID(`browseID(fromAlbumPage:)`);别的按
/// 「歌手 专辑」只搜专辑,专辑名要跟正在放的对得上(`PresenceCover.sameAlbum`)、署名里要有正在放的歌手(`artistMatches`),
/// 见 `pickAlbum`。搜索的界面语言按歌手名的文字取(`searchHL`,同引擎 `ytmusicSearchHL`):YouTube Music 按它换歌名、歌手名的
/// 写法,不带时中日韩歌手多半回英文名;汉字名的日本歌手(米津玄師)按中文搜回「Kenshi Yonezu」,对不上再按日文搜一次
/// (`retryHL`)。歌手从哪来:缓存里播放器给的歌手 ID,或者对上的那张专辑页署名里的歌手 —— 不单独按名字搜歌手(同名的人不少)。
/// 纯函数部分 selftest 钉着。
public enum YouTubeMusicEditorialInfo {
    /// 解析结果。`.none` = 明确没有(页面不存在、没有介绍、介绍不是维基的);形状不对是 nil(不记结论,下次再试)。
    public enum Parsed: Equatable, Sendable {
        case text(String)
        case none
    }

    /// 一位署名歌手:名字 + 频道 ID(`UC…`)。
    public struct Artist: Equatable, Sendable {
        public let name: String
        public let channelID: String

        public init(name: String, channelID: String) {
            self.name = name
            self.channelID = channelID
        }
    }

    /// 搜索结果里的一张专辑。
    public struct AlbumHit: Equatable, Sendable {
        public let browseID: String
        public let title: String
        public let artists: [Artist]

        public init(browseID: String, title: String, artists: [Artist]) {
            self.browseID = browseID
            self.title = title
            self.artists = artists
        }
    }

    /// 专辑页:维基介绍(没有为 nil)+ 署名歌手(头部歌手那一行的链接)。
    public struct AlbumPage: Equatable, Sendable {
        public let description: String?
        public let artists: [Artist]

        public init(description: String?, artists: [Artist]) {
            self.description = description
            self.artists = artists
        }
    }

    /// 只搜专辑的 search params(ytmusicapi `get_search_params("albums")` 算出来的常量,同引擎歌曲那个的算法)。
    static let albumsFilterParams = "EgWKAQIYAWoMEA4QChADEAQQCRAF"
    /// 同 `KasetVideoKind`、引擎的 ytmusicUserAgent(ytmusicapi 的默认值)。
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"

    // MARK: - 语言

    /// 取介绍时的界面语言:繁体界面 zh-TW、别的中文界面 zh-CN,其余用界面语言本身(英文界面 en)。
    public static func descriptionHL(uiLanguage: String) -> String {
        let lang = uiLanguage.lowercased()
        if lang.hasPrefix("zh-hant") || lang.hasPrefix("zh-tw") || lang.hasPrefix("zh-hk") { return "zh-TW" }
        if lang.hasPrefix("zh") { return "zh-CN" }
        let primary = lang.split(separator: "-").first.map(String.init) ?? ""
        return primary.isEmpty ? "en" : primary
    }

    /// 搜索时的界面语言,按歌手名的文字取(同引擎 `ytmusicLocalHL` / `ytmusicSearchHL`):出现假名是日文;否则看哪种文字最多 ——
    /// 谚文 ko,汉字按繁简 zh-TW / zh-CN,拉丁字母这类不带(nil)。汉字歌手的专辑名带假名时也按日文。
    public static func searchHL(artist: String, album: String) -> String? {
        switch dominantScript(artist) {
        case .kana: return "ja"
        case .hangul: return "ko"
        case .han:
            if containsKana(album) { return "ja" }
            return OpenCCT2S.toSimplified(artist) != artist ? "zh-TW" : "zh-CN"
        case .other: return nil
        }
    }

    /// 头一次搜不到对得上的专辑时要不要换日文再搜一次:头一次按中文搜(歌手名以汉字为主),而且结果里一位对得上的歌手都没有
    /// —— 汉字名的日本歌手按中文搜,YouTube Music 回的是罗马字名(米津玄師 → Kenshi Yonezu)。结果里有对得上的歌手、
    /// 只是没有这张专辑,换日文也一样没有,不再搜。
    public static func retryHL(firstHL: String?, hits: [AlbumHit], playingArtist: String) -> String? {
        guard firstHL == "zh-CN" || firstHL == "zh-TW",
              !hits.contains(where: { $0.artists.contains { artistMatches($0.name, playingArtist: playingArtist) } })
        else { return nil }
        return "ja"
    }

    // MARK: - 请求体

    /// 只搜专辑。
    public static func searchBody(query: String, hl: String?, now: Date = Date()) -> Data? {
        var body = context(hl: hl, now: now)
        body["query"] = query
        body["params"] = albumsFilterParams
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func browseBody(browseID: String, hl: String?, now: Date = Date()) -> Data? {
        var body = context(hl: hl, now: now)
        body["browseId"] = browseID
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - 解析

    /// 搜索结果 → 专辑(按 YouTube Music 给的顺序)。每一条要有 `MPREb_` 开头的专辑 ID 和标题;歌手取第二列里链到频道
    /// (`UC…`)的那几段。不是 JSON 对象为 nil;一条都没有是空数组。
    public static func albumHits(fromSearch data: Data) -> [AlbumHit]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var hits: [AlbumHit] = []
        walk(root) { node in
            guard let item = node["musicResponsiveListItemRenderer"] as? [String: Any],
                  let albumID = Self.browseID(of: item["navigationEndpoint"]), albumID.hasPrefix("MPREb_") else { return }
            let columns = (item["flexColumns"] as? [[String: Any]] ?? []).map { column -> [[String: Any]] in
                let renderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
                return (renderer?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
            }
            let title = (columns.first ?? []).compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !hits.contains(where: { $0.browseID == albumID }) else { return }
            hits.append(AlbumHit(browseID: albumID, title: title, artists: Self.artists(inRuns: columns.count > 1 ? columns[1] : [])))
        }
        return hits
    }

    /// 搜索结果里挑正在放的那张:专辑名对得上(`PresenceCover.sameAlbum`,繁简、大小写、标点、` - Single` 不算差别),
    /// 署名里有正在放的歌手(`artistMatches`)。取第一条两样都对上的;没有为 nil。
    public static func pickAlbum(_ hits: [AlbumHit], playingAlbum: String, playingArtist: String) -> AlbumHit? {
        hits.first { hit in
            PresenceCover.sameAlbum(playingAlbum, hit.title)
                && hit.artists.contains { artistMatches($0.name, playingArtist: playingArtist) }
        }
    }

    /// YouTube Music 上的署名跟正在放的歌手是不是同一位:折叠繁简、大小写,只看字母和数字,一边包含另一边就算
    /// (「田馥甄 Hebe Tien」对「田馥甄」、「Taylor Swift」对「Taylor Swift & Sabrina Carpenter」)。短的那边至少两个字,
    /// 相等不受这条限制。
    public static func artistMatches(_ name: String, playingArtist: String) -> Bool {
        let a = folded(name), b = folded(playingArtist)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 2 && long.contains(short)
    }

    /// 专辑页 → 维基介绍 + 署名歌手。没有 `contents`(专辑不存在,HTTP 照样 200,实测)是没有介绍、没有歌手;不是 JSON 对象为 nil。
    public static func albumPage(from data: Data) -> AlbumPage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard root["contents"] != nil else { return AlbumPage(description: nil, artists: []) }
        var artists: [Artist] = []
        walk(root) { node in
            guard artists.isEmpty, let header = node["musicResponsiveHeaderRenderer"] as? [String: Any] else { return }
            artists = Self.artists(inRuns: (header["straplineTextOne"] as? [String: Any])?["runs"] as? [[String: Any]] ?? [])
        }
        return AlbumPage(description: firstWikipediaDescription(in: root), artists: artists)
    }

    /// 歌手页 → 维基介绍。没有 `contents`(频道不存在)、没有介绍、介绍不是维基的(频道自己的宣传语)都是 `.none`;
    /// 不是 JSON 对象为 nil。
    public static func artistDescription(from data: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard root["contents"] != nil, let text = firstWikipediaDescription(in: root) else { return Parsed.none }
        return .text(text)
    }

    /// 介绍的 runs → 正文。要有一段指向维基百科的链接(出处),否则不是维基介绍,返回 nil。正文取第一个维基链接之前的
    /// 文字,去掉最后一段 —— 出处那句(「来自“Wikipedia”(」「資料來源為 Wikipedia (」「From Wikipedia (」……)—— 再按行收拾
    /// (`EditorialText.lines`)。剥完是空的也是 nil。
    public static func wikipediaText(fromRuns runs: [[String: Any]]) -> String? {
        guard let link = runs.firstIndex(where: { run in
            run["navigationEndpoint"] != nil && (run["text"] as? String ?? "").contains("wikipedia.org")
        }) else { return nil }
        var text = runs[..<link].compactMap { $0["text"] as? String }.joined()
        for separator in ["\n\n", "\n"] {
            if let range = text.range(of: separator, options: .backwards), text[range.upperBound...].contains("Wikipedia") {
                text = String(text[..<range.lowerBound])
                break
            }
        }
        let body = EditorialText.lines(text)
        return body.isEmpty ? nil : body
    }

    /// 缓存里播放器给的专辑页 `https://music.youtube.com/browse/MPREb_…` → 专辑 ID。别的形状为 nil。
    public static func browseID(fromAlbumPage url: URL?) -> String? {
        guard let url, url.host == "music.youtube.com", url.pathComponents.count == 3, url.pathComponents[1] == "browse"
        else { return nil }
        let id = url.pathComponents[2]
        return id.hasPrefix("MPREb_") ? id : nil
    }

    /// 缓存里播放器给的歌手页 `https://music.youtube.com/channel/UC…` → 频道 ID。别的形状为 nil。
    public static func channelID(fromArtistPage url: URL?) -> String? {
        guard let url, url.host == "music.youtube.com", url.pathComponents.count == 3, url.pathComponents[1] == "channel"
        else { return nil }
        let id = url.pathComponents[2]
        return id.hasPrefix("UC") ? id : nil
    }

    // MARK: - 取数

    /// 只搜专辑。nil = 没问成(网络、非 200、形状不对),下次再试。
    public static func searchAlbums(query: String, hl: String?, session: URLSession = .shared) async -> [AlbumHit]? {
        guard let body = searchBody(query: query, hl: hl),
              let data = await post("search", body: body, operation: "search.albums", session: session) else { return nil }
        return albumHits(fromSearch: data)
    }

    /// 专辑页。nil = 没问成。
    public static func fetchAlbumPage(browseID: String, hl: String?, session: URLSession = .shared) async -> AlbumPage? {
        guard let body = browseBody(browseID: browseID, hl: hl),
              let data = await post("browse", body: body, operation: "browse.album", session: session) else { return nil }
        return albumPage(from: data)
    }

    /// 歌手页的维基介绍。nil = 没问成。
    public static func fetchArtistDescription(channelID: String, hl: String?, session: URLSession = .shared) async -> Parsed? {
        guard let body = browseBody(browseID: channelID, hl: hl),
              let data = await post("browse", body: body, operation: "browse.artist", session: session) else { return nil }
        return artistDescription(from: data)
    }

    // MARK: - 内部

    private enum Script { case kana, hangul, han, other }

    /// 同引擎 `dominantScript`:出现假名就是日文;否则按谚文、汉字、别的字母数谁最多,一样多时取前面的。
    private static func dominantScript(_ s: String) -> Script {
        var hangul = 0, han = 0, other = 0
        for scalar in s.unicodeScalars {
            if isKana(scalar) { return .kana }
            if isHangul(scalar) { hangul += 1 } else if isHan(scalar) { han += 1 } else if scalar.properties.isAlphabetic { other += 1 }
        }
        let best = max(hangul, han, other)
        if best == 0 { return .other }
        if hangul == best { return .hangul }
        return han == best ? .han : .other
    }

    private static func containsKana(_ s: String) -> Bool { s.unicodeScalars.contains(where: isKana) }

    private static func isKana(_ s: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(s.value) || (0x31F0...0x31FF).contains(s.value) || (0xFF66...0xFF9F).contains(s.value)
    }

    private static func isHangul(_ s: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7AF).contains(s.value) || (0x1100...0x11FF).contains(s.value) || (0x3130...0x318F).contains(s.value)
    }

    private static func isHan(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
            || (0xF900...0xFAFF).contains(s.value) || (0x20000...0x2FFFF).contains(s.value)
    }

    /// 比歌手名用的形状:繁转简、小写,只留字母和数字。
    private static func folded(_ s: String) -> String {
        String(String.UnicodeScalarView(OpenCCT2S.toSimplified(s).lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static func context(hl: String?, now: Date) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": "1.\(formatter.string(from: now)).01.00"]
        if let hl { client["hl"] = hl }
        return ["context": ["client": client, "user": [String: Any]()]]
    }

    private static func browseID(of endpoint: Any?) -> String? {
        ((endpoint as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
    }

    /// 一串 runs 里链到频道(`UC…`)的那几段 → 署名歌手。
    private static func artists(inRuns runs: [[String: Any]]) -> [Artist] {
        runs.compactMap { run in
            guard let id = browseID(of: run["navigationEndpoint"]), id.hasPrefix("UC"),
                  let name = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }
            return Artist(name: name, channelID: id)
        }
    }

    /// 整页里第一段带维基出处的介绍(`musicDescriptionShelfRenderer`)。
    private static func firstWikipediaDescription(in root: [String: Any]) -> String? {
        var found: String?
        walk(root) { node in
            guard found == nil, let shelf = node["musicDescriptionShelfRenderer"] as? [String: Any],
                  let runs = (shelf["description"] as? [String: Any])?["runs"] as? [[String: Any]] else { return }
            found = wikipediaText(fromRuns: runs)
        }
        return found
    }

    private static func walk(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            visit(dict)
            for value in dict.values { walk(value, visit) }
        } else if let array = node as? [Any] {
            for value in array { walk(value, visit) }
        }
    }

    /// 发一次 innertube POST,记进对外请求审计日志。HTTP 不是 200、连不上都返回 nil。
    private static func post(_ endpoint: String, body: Data, operation: String, session: URLSession) async -> Data? {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false&alt=json") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "youtube-music", operation: operation, host: url.host ?? "music.youtube.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return status == 200 ? data : nil
        } catch {
            NetworkAuditLog.record(service: "youtube-music", operation: operation, host: url.host ?? "music.youtube.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
