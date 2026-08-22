import Foundation

/// iTunes Search API 解析当前曲目的目录页链接(2026-08-22,歌词窗口「前往专辑/前往
/// 艺人/分享」一族的地基)。为什么走这条路:AppleScript 拿不到流媒体曲目的任何目录
/// ID/链接(实机验证:URL track 连 `address` 属性都没有),iTunes Search API 是唯一
/// 免密钥的解析途径 —— 按 歌名+歌手+店面 搜 song 实体,响应里直接带 trackViewUrl /
/// artistViewUrl / collectionViewUrl(与 Music 自己分享菜单产出的链接同形)。
///
/// ⚠️ 拿到链接后**必须**经 LaunchServices 打开(music:// scheme 或 NSWorkspace 指定
/// Music.app):AppleScript 的 `open location` 会把 URL 当**音频流**加载、清掉整个
/// 播放队列(2026-08-22 实机踩雷验证,sdef 里它的语义就是 "audio stream URL")。
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
        /// 100pt 的专辑封面。响应里本来就带,2026-08-22 才开始解码它 —— 最近记录的
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
        return c?.url
    }

    /// 结果挑选:歌名+歌手都松匹配 > 只歌手匹配 > 第一条。松匹配=去空格小写后互相
    /// 包含(标题常带 feat./版本后缀,搜索端和曲库端谁长谁短不一定)。
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
        if let hit = items.first(where: { looseContains(norm($0.artistName), a) }) { return hit }
        return items.first
    }

    // MARK: - 封面兜底(2026-08-22)

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
    /// 专辑对得上的优先(2026-08-22 实测这一步很值:只取第一条时《NOW YOU SEE ME (Live)》
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

    /// 按 歌手+歌名 查一次 iTunes,挑一张能对上的封面。挑不出就 nil(不留退路)。
    public static func resolveArtwork(title: String, artist: String, album: String?,
                                      storefront: String) async -> ArtworkMatch? {
        guard let url = searchURL(title: title, artist: artist, storefront: storefront, limit: 12)
        else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return pickArtwork(decoded.results, title: title, artist: artist, album: album)
    }

    /// https://music.apple.com/… → music://…(注册给 Music.app 的 scheme,经
    /// LaunchServices 打开即原生跳页、不动播放队列,实机验证)。非 music.apple.com
    /// 的输入一律拒绝,不做泛化改写。
    public static func musicSchemeURL(_ httpsURL: String?) -> URL? {
        guard let httpsURL, httpsURL.hasPrefix("https://music.apple.com/") else { return nil }
        return URL(string: "music" + httpsURL.dropFirst("https".count))
    }

    /// 拉取并挑选(URLSession async,调用方自行放到非主线程上下文)。
    public static func resolve(title: String, artist: String, storefront: String) async -> Item? {
        guard let url = searchURL(title: title, artist: artist, storefront: storefront) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return pickBest(decoded.results, title: title, artist: artist)
    }
}
