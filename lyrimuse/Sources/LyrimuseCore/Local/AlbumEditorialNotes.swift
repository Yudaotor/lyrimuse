import Foundation

/// Apple Music 专辑页上那段编辑撰写的专辑简介(网页 / Music.app 专辑页里点「更多」弹出来的那段)。
///
/// 来源是专辑的**公开网页** `music.apple.com/{店面}/album/x/{专辑 ID}`:页面内嵌的
/// `serialized-server-data` JSON 里,专辑头部那一项的 `modalPresentationDescriptor` 就是「更多」弹窗的
/// 数据(`headerTitle` / `headerSubtitle` / `paragraphText`),正文与 Apple Music API 的
/// `editorialNotes.standard` 逐字相同,不需要 developer token。collector 抓动态封面走的是同一个页面
/// (`motioncover.go` 的 `fetchAlbumPage`),请求头照抄它:这一页对 UA 敏感,要桌面 Safari 的串。
///
/// 文案按店面各写一份(cn 与 tw 不是简繁转换,是两段不同的文字),有的店面没有;专辑 ID 各店面通用,但不是每个
/// 店面都上架(没上架的店面专辑页直接 404)。所以先问用户地区的店面,404 再问 `apple_music_url` 自带的店面
/// (`storefronts(region:linkStorefront:)`)。纯函数部分(ID 解析、店面顺序、页面解析、按店面依次取)selftest 覆盖。
public enum AlbumEditorialNotes {
    public struct Notes: Equatable, Sendable {
        /// 页面上的专辑名(用户店面的写法,可能与播放器报的专辑名不同)。
        public let title: String
        /// 「歌手 · 年份」那一行,可能为空。
        public let subtitle: String
        public let text: String

        public init(title: String, subtitle: String, text: String) {
            self.title = title
            self.subtitle = subtitle
            self.text = text
        }
    }

    /// 专辑页上的一位署名歌手(头部「歌手」那一行的链接)。合作专辑有多位。
    public struct ArtistLink: Equatable, Sendable {
        public let name: String
        public let id: Int64

        public init(name: String, id: Int64) {
            self.name = name
            self.id = id
        }
    }

    /// 一次专辑页请求里用得上的全部东西:简介(可能没有)+ 署名歌手(歌手简介要靠它拿歌手 ID)。
    public struct AlbumPage: Equatable, Sendable {
        public let notes: Notes?
        public let artists: [ArtistLink]

        public init(notes: Notes?, artists: [ArtistLink]) {
            self.notes = notes
            self.artists = artists
        }
    }

    /// `apple_music_url` 指向的专辑:专辑 ID + 链接里的店面(链接不带店面时为 nil)。
    public struct AlbumRef: Equatable, Sendable {
        public let id: Int64
        public let storefront: String?

        public init(id: Int64, storefront: String?) {
            self.id = id
            self.storefront = storefront
        }
    }

    public static func albumRef(fromAppleMusicURL raw: String?) -> AlbumRef? {
        guard let id = albumID(fromAppleMusicURL: raw), let url = raw.flatMap(URL.init(string:)) else { return nil }
        let first = url.path.split(separator: "/").first.map { $0.lowercased() }
        let storefront = first.flatMap { $0.count == 2 && $0.allSatisfy(\.isLetter) ? $0 : nil }
        return AlbumRef(id: id, storefront: storefront)
    }

    /// 取专辑页时依次要试的店面:用户地区在前,链接自带的店面在后;小写、去重,两个都没有时退回 `us`。
    public static func storefronts(region: String?, linkStorefront: String?) -> [String] {
        var out: [String] = []
        for raw in [region, linkStorefront] {
            guard let sf = raw?.lowercased(), !sf.isEmpty, !out.contains(sf) else { continue }
            out.append(sf)
        }
        return out.isEmpty ? ["us"] : out
    }

    /// `apple_music_url`(`https://music.apple.com/{店面}/album/{slug}/{专辑 ID}?i={曲目 ID}`)里的专辑 ID。
    /// 只认 `music.apple.com` 的 `/album/` 链接;slug 可有可无。
    public static func albumID(fromAppleMusicURL raw: String?) -> Int64? {
        guard let raw, let url = URL(string: raw), url.host == "music.apple.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let albumIndex = parts.firstIndex(of: "album"), albumIndex + 1 < parts.count else { return nil }
        let tail = parts[(albumIndex + 1)...]
        guard let last = tail.last, let id = Int64(last), id > 0 else { return nil }
        return id
    }

    public static func pageURL(albumID: Int64, storefront: String) -> URL? {
        let sf = storefront.isEmpty ? "us" : storefront.lowercased()
        return URL(string: "https://music.apple.com/\(sf)/album/x/\(albumID)")
    }

    /// 从专辑页 HTML 里取简介。`albumID` 用来确认取到的那一项确实是这张专辑(页面里还挂着同歌手的其它专辑)。
    /// 正文里的 HTML 标签去掉、首尾空白收掉;正文为空返回 nil。
    public static func parse(html: String, albumID: Int64) -> Notes? {
        parseAlbumPage(html: html, albumID: albumID)?.notes
    }

    /// 专辑页的简介与署名歌手。页面不是预期形状(没有内嵌数据 / 找不到这张专辑那一项)返回 nil。
    public static func parseAlbumPage(html: String, albumID: Int64) -> AlbumPage? {
        guard let json = serializedServerData(in: html),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }
        let want = String(albumID)
        var page: AlbumPage?
        visit(root) { dict in
            // 只认专辑头部那一项:标识对得上这张专辑,且带简介描述符或署名链接(播放按钮等别的节点也引用同一个
            // ID)。没有标识的形状不放行,宁可不显示也不配错专辑。
            guard page == nil, storeAdamID(of: dict, kind: nil) == want,
                  dict["modalPresentationDescriptor"] != nil || dict["subtitleLinks"] != nil else { return }
            var notes: Notes?
            if let descriptor = dict["modalPresentationDescriptor"] as? [String: Any],
               let paragraph = descriptor["paragraphText"] as? String {
                let text = cleaned(paragraph)
                if !text.isEmpty {
                    notes = Notes(title: cleaned(descriptor["headerTitle"] as? String ?? ""),
                                  subtitle: cleaned(descriptor["headerSubtitle"] as? String ?? ""),
                                  text: text)
                }
            }
            page = AlbumPage(notes: notes, artists: artistLinks(in: dict))
        }
        return page
    }

    /// 一次页面请求的结果。404 单独一档:那是「这个店面没有这一页」,跟网络失败不同,不该下次再试。
    public enum PageFetch: Equatable, Sendable {
        case ok(String)
        case notFound
        case failed

        public static func classify(statusCode: Int?, body: String?) -> PageFetch {
            switch statusCode {
            case 200: return body.map(PageFetch.ok) ?? .failed
            case 404, 410: return .notFound
            default: return .failed
            }
        }
    }

    public enum AlbumPageResult: Equatable, Sendable {
        /// 取到了;`storefront` 是给出这一页的店面(歌手页也按它问)。
        case found(AlbumPage, storefront: String)
        /// 所有店面都 404:这张专辑没有公开页,本次运行不必再问。
        case missing
        /// 请求失败 / 页面不是预期形状,下次还该再试。
        case failed
    }

    /// 按 `storefronts` 的顺序取专辑页:404 换下一个店面,取到或失败就停。一次约 0.4 MB,别在主线程 await。
    public static func fetchAlbumPage(albumID: Int64, storefronts: [String],
                                      session: URLSession = .shared) async -> AlbumPageResult {
        await resolveAlbumPage(albumID: albumID, storefronts: storefronts) { url in
            await fetchPage(url, operation: "album.notes", session: session)
        }
    }

    /// `fetchAlbumPage` 的逐店面逻辑,请求由 `load` 给(selftest 用假的)。
    public static func resolveAlbumPage(albumID: Int64, storefronts: [String],
                                        load: (URL) async -> PageFetch) async -> AlbumPageResult {
        for storefront in storefronts {
            guard let url = pageURL(albumID: albumID, storefront: storefront) else { return .failed }
            switch await load(url) {
            case .ok(let html):
                guard let page = parseAlbumPage(html: html, albumID: albumID) else { return .failed }
                return .found(page, storefront: storefront)
            case .notFound:
                continue
            case .failed:
                return .failed
            }
        }
        return storefronts.isEmpty ? .failed : .missing
    }

    // MARK: - 歌手简介

    /// 歌手页(`music.apple.com/{店面}/artist/x/{歌手 ID}`)头部那一项的 `bio`。正文与 Apple Music API 的
    /// `artistBio` 逐字相同。出生日期 / 类型不在页面上,见 `ArtistFacts`。
    public static func artistPageURL(artistID: Int64, storefront: String) -> URL? {
        let sf = storefront.isEmpty ? "us" : storefront.lowercased()
        return URL(string: "https://music.apple.com/\(sf)/artist/x/\(artistID)")
    }

    /// 页面是预期形状、这位歌手没有简介时返回 `""`;形状不对返回 nil。
    public static func parseArtistBio(html: String, artistID: Int64) -> String? {
        guard let json = serializedServerData(in: html),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }
        let want = String(artistID)
        var bio: String?
        visit(root) { dict in
            // 只认歌手头部那一项:标识对得上,且带简介或头像(页面别处指向这位歌手的链接也引用同一个 ID)。
            guard bio == nil, storeAdamID(of: dict, kind: "artist") == want, dict["title"] != nil,
                  dict["bio"] != nil || dict["circleArtwork"] != nil else { return }
            bio = cleaned(dict["bio"] as? String ?? "")
        }
        return bio
    }

    /// 返回值同 `parseArtistBio`;这个店面没有这位歌手的页面(404)也算「没有简介」返回 `""`,请求失败返回 nil。
    public static func fetchArtistBio(artistID: Int64, storefront: String,
                                      session: URLSession = .shared) async -> String? {
        guard let url = artistPageURL(artistID: artistID, storefront: storefront) else { return nil }
        switch await fetchPage(url, operation: "artist.bio", session: session) {
        case .ok(let html): return parseArtistBio(html: html, artistID: artistID)
        case .notFound: return ""
        case .failed: return nil
        }
    }

    /// 歌手页上看不到、只有 Apple Music API 才给的两项:出生日期(乐队是成立时间)与类型。
    public struct ArtistFacts: Equatable, Sendable {
        /// 原样的日期文字(店面语言,如「1983年7月14日」)。
        public let bornOrFormed: String?
        public let genres: [String]
        public let isGroup: Bool

        public init(bornOrFormed: String?, genres: [String], isGroup: Bool) {
            self.bornOrFormed = bornOrFormed
            self.genres = genres
            self.isGroup = isGroup
        }
    }

    public static func artistFactsURL(artistID: Int64, storefront: String) -> URL? {
        let sf = storefront.isEmpty ? "us" : storefront.lowercased()
        return URL(string: "https://amp-api.music.apple.com/v1/catalog/\(sf)/artists/\(artistID)?extend=bornOrFormed,isGroup")
    }

    public static func parseArtistFacts(_ data: Data) -> ArtistFacts? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]],
              let attrs = items.first?["attributes"] as? [String: Any] else { return nil }
        let born = (attrs["bornOrFormed"] as? String).map(cleaned).flatMap { $0.isEmpty ? nil : $0 }
        let genres = (attrs["genreNames"] as? [String] ?? []).map(cleaned).filter { !$0.isEmpty && $0 != "音乐" && $0 != "Music" }
        return ArtistFacts(bornOrFormed: born, genres: genres, isGroup: attrs["isGroup"] as? Bool ?? false)
    }

    /// 要 developer token(collector 从 music.apple.com 取来缓存在 `AppleMusicDeveloperToken`)。
    /// 没有 token / 请求失败都返回 nil,调用方只是少显示两行。
    public static func fetchArtistFacts(artistID: Int64, storefront: String, token: String,
                                        session: URLSession = .shared) async -> ArtistFacts? {
        guard let url = artistFactsURL(artistID: artistID, storefront: storefront) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        // amp-api 校验 Origin,不带就 403。同 collector 的 applemusicWebOrigin。
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "apple-music-api", operation: "artist.facts", host: url.host ?? "amp-api.music.apple.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return status == 200 ? parseArtistFacts(data) : nil
        } catch {
            NetworkAuditLog.record(service: "apple-music-api", operation: "artist.facts", host: url.host ?? "amp-api.music.apple.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }

    /// 专辑署名里挑出这首歌的歌手:名字能对上的那一位(忽略大小写与空白,互相包含即算);只有一位就用它
    /// (播放器报的可能是另一种语言的写法,比如 Spotify 给 Khalil Fong、cn 店面写方大同);多位都对不上返回 nil,
    /// 不猜。
    public static func pickArtist(_ links: [ArtistLink], localArtist: String) -> ArtistLink? {
        func norm(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let local = norm(localArtist)
        if !local.isEmpty,
           let hit = links.first(where: { let n = norm($0.name); return !n.isEmpty && (local.contains(n) || n.contains(local)) }) {
            return hit
        }
        return links.count == 1 ? links[0] : nil
    }

    // MARK: - 内部

    private static func fetchPage(_ url: URL, operation: String, session: URLSession) async -> PageFetch {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "apple-music-web", operation: operation, host: url.host ?? "music.apple.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return PageFetch.classify(statusCode: status, body: String(data: data, encoding: .utf8))
        } catch {
            NetworkAuditLog.record(service: "apple-music-web", operation: operation, host: url.host ?? "music.apple.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return .failed
        }
    }

    /// 节点的 `contentDescriptor.identifiers.storeAdamID`。`kind` 非 nil 时同时要求 `contentDescriptor.kind` 相符。
    private static func storeAdamID(of dict: [String: Any], kind: String?) -> String? {
        guard let content = dict["contentDescriptor"] as? [String: Any],
              let ids = content["identifiers"] as? [String: Any],
              let adam = ids["storeAdamID"] as? String else { return nil }
        if let kind, content["kind"] as? String != kind { return nil }
        return adam
    }

    /// 专辑头部 `subtitleLinks` 里指向歌手页的那几条。
    private static func artistLinks(in item: [String: Any]) -> [ArtistLink] {
        guard let links = item["subtitleLinks"] as? [[String: Any]] else { return [] }
        return links.compactMap { link in
            guard let segue = link["segue"] as? [String: Any],
                  let destination = segue["destination"] as? [String: Any],
                  let adam = storeAdamID(of: destination, kind: "artist"), let id = Int64(adam), id > 0 else { return nil }
            let name = cleaned(link["title"] as? String ?? "")
            return name.isEmpty ? nil : ArtistLink(name: name, id: id)
        }
    }

    static func serializedServerData(in html: String) -> String? {
        let open = "<script type=\"application/json\" id=\"serialized-server-data\">"
        guard let a = html.range(of: open),
              let b = html.range(of: "</script>", range: a.upperBound..<html.endIndex) else { return nil }
        return String(html[a.upperBound..<b.lowerBound])
    }

    private static func visit(_ node: Any, _ body: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            body(dict)
            for value in dict.values { visit(value, body) }
        } else if let array = node as? [Any] {
            for value in array { visit(value, body) }
        }
    }

    /// 去掉 HTML 标签(API 那一路的正文里出现过 `<i>` / `<br />`,页面这一路目前没有,防一手),
    /// 把 `\u{202F}` 这类窄空格保留原样,只收首尾空白。
    static func cleaned(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// collector 从 music.apple.com 取来、落盘缓存的 Apple Music developer token(`applemusic.go` 的
/// `applemusicDevTokenPath`,文件 `{"token", "expiry"}`)。App 只读,不自己去取:拿不到就当没有。
public enum AppleMusicDeveloperToken {
    public static var fileURL: URL { LyrimusePaths.configFile("lyrimuse-applemusic-devtoken.json") }

    /// 还有效的 token;文件不在 / 读不出 / 离过期不到一分钟返回 nil。
    public static func cached(now: Date = Date()) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return parse(data, now: now)
    }

    public static func parse(_ data: Data, now: Date) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty,
              let expiry = (obj["expiry"] as? NSNumber)?.doubleValue,
              expiry > now.timeIntervalSince1970 + 60 else { return nil }
        return token
    }
}
