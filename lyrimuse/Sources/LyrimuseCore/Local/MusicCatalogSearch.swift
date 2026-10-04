import Foundation

/// iTunes Search API 解析当前曲目的目录页链接(歌词窗口「前往专辑/前往
/// 艺人/分享」一族的地基)。为什么走这条路:AppleScript 拿不到流媒体曲目的任何目录
/// ID/链接(实机验证:URL track 连 `address` 属性都没有),iTunes Search API 是唯一
/// 免密钥的解析途径 —— 按 歌名+歌手+店面 搜 song 实体,响应里直接带 trackViewUrl /
/// artistViewUrl / collectionViewUrl(与 Music 自己分享菜单产出的链接同形)。
///
/// 拿到链接后**必须**经 LaunchServices 打开(music:// scheme 或 NSWorkspace 指定
/// Music.app):AppleScript 的 `open location` 会把 URL 当**音频流**加载、清掉整个
/// 播放队列(实机踩雷验证,sdef 里它的语义就是 "audio stream URL")。
///
/// 纯函数部分(URL 构造/结果挑选/scheme 改写)被 lyrimuse-selftest 钉住。
public enum MusicCatalogSearch {
    public struct Item: Decodable, Sendable {
        public let trackName: String?
        public let artistName: String?
        public let collectionName: String?
        public let trackViewUrl: String?
        public let artistViewUrl: String?
        public let collectionViewUrl: String?
        /// 100pt 的专辑封面。响应里本来就带,才开始解码它 —— 最近记录的
        /// 封面第⑤级兜底用(见 pickArtwork)。
        public let artworkUrl100: String?

        public init(trackName: String?, artistName: String?, collectionName: String?,
                    trackViewUrl: String?, artistViewUrl: String?, collectionViewUrl: String?,
                    artworkUrl100: String? = nil) {
            self.trackName = trackName
            self.artistName = artistName
            self.collectionName = collectionName
            self.trackViewUrl = trackViewUrl
            self.artistViewUrl = artistViewUrl
            self.collectionViewUrl = collectionViewUrl
            self.artworkUrl100 = artworkUrl100
        }
    }

    struct Response: Decodable { let results: [Item] }

    /// 依次要问的店面:调用方给的(系统地区)在前,搜出来一条都没有才换下一个。中国区的 search 接口对
    /// 任何歌都回 0 条(见 12 章),只问系统地区的话,系统地区是中国的用户这条路整个是死的。台区、港区的
    /// 华语曲库最全,美区兜底。目录 id 全球通用,别的店面查回来的封面和链接一样能用。
    public static func storefronts(primary: String) -> [String] {
        var out: [String] = []
        for s in [primary.lowercased(), "tw", "hk", "us"] where !s.isEmpty && !out.contains(s) {
            out.append(s)
        }
        return out
    }

    /// 这次响应是不是「这个店面一条都搜不到」:只有这种情况才换下一个店面。有结果但挑不出(那边确实没有
    /// 这一首)、没问成(限流 / 超时 / 非 200)都不换 —— 前者换了也是白问,后者交给退避。纯函数,selftest 钉住。
    public static func shouldTryNextStorefront(status: Int?, data: Data) -> Bool {
        guard status == 200, let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return false }
        return decoded.results.isEmpty
    }

    /// 发一次搜索请求并记审计日志、喂退避。没问成返回 nil。
    private static func fetch(_ url: URL, gate: ITunesSearchGate) async -> (status: Int?, data: Data)? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let start = Date()
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            NetworkAuditLog.record(service: "itunes", operation: "itunes.search", host: url.host ?? "itunes.apple.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            // 网络层失败按 0 记退避(口径同引擎);调用方自己取消的不算。
            if (error as? URLError)?.code != .cancelled { gate.note(status: 0, retryAfter: nil) }
            return nil
        }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode
        NetworkAuditLog.record(service: "itunes", operation: "itunes.search", host: url.host ?? "itunes.apple.com",
                               statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
        if let status {
            gate.note(status: status, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        }
        return (status, data)
    }

    /// 请求 URL。storefront 传系统地区码、外层兜底 "us" —— 账号店面与系统地区可能
    /// 不一致,搜错店面的代价只是链接落到别的店面页,Music.app 会自己按账号跳转。
    /// limit 默认 8 是跳转链接那条路径的老口径(第一条命中就够);封面兜底要在候选里
    /// 挑「专辑也对得上」的那条,给到 12 命中率更高(见 pickArtwork)。
    public static func searchURL(title: String, artist: String, storefront: String,
                                 limit: Int = 8) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")
        c?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "country", value: storefront),
        ]
        // URLQueryItem 不编码 `+`,iTunes 那边按表单规则把它当空格:「1+1」会按「1 1」去搜。
        let encodedQuery = c?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        c?.percentEncodedQuery = encodedQuery
        return c?.url
    }

    /// 结果挑选:歌名+歌手都松匹配 > 歌手精确匹配 > 只歌手松匹配 > 第一条。松匹配=
    /// 去空格小写后互相包含(标题常带 feat./版本后缀,搜索端和曲库端谁长谁短不一定)。
    public static func pickBest(_ items: [Item], title: String, artist: String) -> Item? {
        func norm(_ s: String?) -> String {
            (s ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        }
        func looseContains(_ a: String, _ b: String) -> Bool {
            guard !a.isEmpty, !b.isEmpty else { return false }
            return a.contains(b) || b.contains(a)
        }
        let t = norm(title), a = norm(artist)
        if let hit = items.first(where: {
            looseContains(norm($0.trackName), t) && looseContains(norm($0.artistName), a)
        }) { return hit }
        // 歌手精确匹配优先于歌手松匹配(实测):「你的常听·歌手」
        // 跳转时 title 传空串,只有这条"只歌手"分支在起作用,而互相包含对艺人名是危险的
        // 松匹配——单人艺人名常常正好是另一个合作/乐队艺人名的前缀(点"Prince"却跳到
        // "Prince & The Revolution",点"陈奕迅"可能跳到某场合唱的联合署名艺人页),
        // 跟标题那边"版本后缀谁长谁短不一定"的场景不是一回事,不能用同一把尺子。
        // 精确相等命中不了才退回松匹配(比如源数据本身就是"周杰伦 (Jay Chou)"这类夹带,
        // 松匹配好歹还能命中同一个人)。
        if let hit = items.first(where: { norm($0.artistName) == a }) { return hit }
        if let hit = items.first(where: { looseContains(norm($0.artistName), a) }) { return hit }
        return items.first
    }

    // MARK: - 封面兜底

    /// 封面匹配的把握程度。调用方按它决定要不要用、以及排在哪一级。
    public enum ArtworkConfidence: String, Sendable {
        /// 歌手 + 歌名 + **专辑**都对上 —— 就是这一版发行的封面。
        case albumMatch
        /// 歌手 + 歌名对上、专辑对不上 —— 同一首歌**另一个发行版**的封面
        /// (实测:《光辉岁月》拿到 25th Anniversary 版)。比空位强,但同屏可能不一致。
        case trackOnly
    }

    public struct ArtworkMatch: Sendable {
        public let url: URL
        public let confidence: ArtworkConfidence
        public let matchedAlbum: String?
    }

    /// 把 iTunes 的 100pt 图换成 600pt。URL 形如 `…/100x100bb.jpg`;认不出这个模式
    /// 就原样返回 —— 尺寸段的写法 Apple 改过几次,认不出时用小图也比没有强。
    public static func upscaleArtwork(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    /// 给「最近记录」缺封面的行挑一张 iTunes 封面。**故意不复用 pickBest**:那个是给
    /// 「前往专辑/前往艺人」跳转用的,松匹配 + 最后兜底 `items.first`——跳转跳到近似条目
    /// 顶多是跳偏了,而封面挂错图会被当成事实。实测那条兜底会把
    /// 《微醺卡带 - 情非得已 (微醺版)》配上《鱼翅Fin - 无声的告别是对往事的礼赞》的封面。
    ///
    /// 规则:**歌手+歌名必须匹配,匹配不上就留空位**,绝不退回第一条。判据直接借
    /// `PlayCountFold.familyKey` —— 跟「第 N 次听」查写法族**同一把尺子**:NFKC、繁简
    /// (Last.fm 那行常是 `周杰倫`、iTunes 是 `周杰伦`)、去空格大小写、合唱归首位
    /// (`周杰伦` 对得上 `周杰伦 & 派伟俊`)、目录学噪音(`POP/STARS` 对得上
    /// `POP/STARS (feat. …)`),这些折叠正好都是封面匹配需要的;而它**刻意不折** `(Live)`
    /// 这类版本副题 —— Live 版和录音室版本来就该是两张封面。
    ///
    /// 专辑对得上的优先(实测这一步很值:只取第一条时《NOW YOU SEE ME (Live)》
    /// 会拿到录音室版《周杰伦的床边故事》、《青花瓷 (Live)》会拿到魔天伦演唱会,30 首里有
    /// 5 首被这一步纠正回正确的那张)。专辑名走 `foldTitle` 归一,跟歌名同一套。
    public static func pickArtwork(_ items: [Item], title: String, artist: String,
                                   album: String?) -> ArtworkMatch? {
        let want = PlayCountFold.familyKey(artist: artist, title: title)
        let wantAlbum = album.map { PlayCountFold.foldTitle($0) } ?? ""
        var fallback: ArtworkMatch?
        for item in items {
            guard let itemArtist = item.artistName, let itemTitle = item.trackName,
                  PlayCountFold.familyKey(artist: itemArtist, title: itemTitle) == want,
                  let url = upscaleArtwork(item.artworkUrl100)
            else { continue }
            if !wantAlbum.isEmpty, PlayCountFold.foldTitle(item.collectionName ?? "") == wantAlbum {
                return ArtworkMatch(url: url, confidence: .albumMatch,
                                    matchedAlbum: item.collectionName)
            }
            // 同曲、专辑对不上:先记着,继续找专辑也对得上的那条
            if fallback == nil {
                fallback = ArtworkMatch(url: url, confidence: .trackOnly,
                                        matchedAlbum: item.collectionName)
            }
        }
        return fallback
    }

    /// 一次封面查询的结局。`unreached` 只说明这次没问成(退避中 / 超时 / 限流 / 非 200 /
    /// 响应解不开),调用方绝不能把它记成「那边没有这一首」。
    public enum ArtworkLookup: Sendable {
        case found(ArtworkMatch)
        case noMatch
        case unreached

        public var match: ArtworkMatch? {
            if case .found(let m) = self { return m }
            return nil
        }
    }

    /// 把一次响应归成 `ArtworkLookup`。纯函数,selftest 钉住。
    public static func artworkLookup(status: Int?, data: Data, title: String, artist: String,
                                     album: String?) -> ArtworkLookup {
        guard status == 200, let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return .unreached }
        if let hit = pickArtwork(decoded.results, title: title, artist: artist, album: album) {
            return .found(hit)
        }
        return .noMatch
    }

    /// 按 歌手+歌名 查 iTunes,挑一张能对上的封面。挑不出是 `.noMatch`(不留退路)。店面按 storefronts(primary:)
    /// 依次问,一条都搜不到才换下一个。后台批量调用,`ITunesSearchGate` 退避期间不发请求。
    public static func resolveArtwork(title: String, artist: String, album: String?,
                                      storefront: String,
                                      gate: ITunesSearchGate = .shared) async -> ArtworkLookup {
        for store in storefronts(primary: storefront) {
            guard !gate.coolingDown(),
                  let url = searchURL(title: title, artist: artist, storefront: store, limit: 12),
                  let (status, data) = await fetch(url, gate: gate)
            else { return .unreached }
            if shouldTryNextStorefront(status: status, data: data) { continue }
            return artworkLookup(status: status, data: data, title: title, artist: artist, album: album)
        }
        return .noMatch
    }

    /// https://music.apple.com/… → music://…(注册给 Music.app 的 scheme,经
    /// LaunchServices 打开即原生跳页、不动播放队列,实机验证)。非 music.apple.com
    /// 的输入一律拒绝,不做泛化改写。
    public static func musicSchemeURL(_ httpsURL: String?) -> URL? {
        guard let httpsURL, httpsURL.hasPrefix("https://music.apple.com/") else { return nil }
        return URL(string: "music" + httpsURL.dropFirst("https".count))
    }

    /// 引擎存的曲目链接(`apple_music_url`,`…/album/<名>/<专辑 id>?i=<曲目 id>`,https 或 music:// 都认)
    /// 所在专辑的页面,已改写成 `music://`,店面照链接。不是专辑形状(MV 等)返回 nil,调用方退回按歌名搜。
    public static func albumPage(fromTrackURL raw: String?) -> URL? {
        guard let ref = AlbumEditorialNotes.albumRef(fromAppleMusicURL: raw),
              let page = AlbumEditorialNotes.pageURL(albumID: ref.id, storefront: ref.storefront ?? "") else { return nil }
        return musicSchemeURL(page.absoluteString)
    }

    /// 拉取并挑选(URLSession async,调用方自行放到非主线程上下文)。用户点一次发一次,
    /// 不看 `ITunesSearchGate` 的退避,但响应照样记进去。店面同 resolveArtwork,一条都搜不到才换下一个。
    public static func resolve(title: String, artist: String, storefront: String) async -> Item? {
        for store in storefronts(primary: storefront) {
            guard let url = searchURL(title: title, artist: artist, storefront: store),
                  let (status, data) = await fetch(url, gate: .shared)
            else { return nil }
            if shouldTryNextStorefront(status: status, data: data) { continue }
            guard status == 200, let decoded = try? JSONDecoder().decode(Response.self, from: data)
            else { return nil }
            return pickBest(decoded.results, title: title, artist: artist)
        }
        return nil
    }
}
