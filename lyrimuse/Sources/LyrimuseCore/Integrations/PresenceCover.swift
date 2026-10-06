import Foundation

/// 设备直送封面在网页中继上的公网地址。引擎把 `~/.config/lyrimuse/artwork/<sha>.jpg` 传到中继的 `/artwork/<sha>.jpg`
/// (lyrimuse-engine/artworkrelay.go,按图片内容寻址,播放时才传)。认法跟引擎的 `deviceArtworkRef` 一样收得紧:文件名
/// 必须是 16 位小写十六进制、后缀 jpg / png、在 artwork 文件夹里,别的 file:// 一律不认,免得把本机路径拼进地址发出去。
public enum RelayArtwork {
    public static func publicURL(relayBase: String, coverURL: URL?) -> URL? {
        guard let coverURL, coverURL.isFileURL,
              coverURL.deletingLastPathComponent().lastPathComponent == "artwork" else { return nil }
        let ext = coverURL.pathExtension.lowercased()
        let stem = coverURL.deletingPathExtension().lastPathComponent
        guard ext == "jpg" || ext == "png", stem.count == 16,
              stem.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        var base = relayBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let baseURL = URL(string: base), baseURL.scheme?.lowercased() == "https", baseURL.host != nil else { return nil }
        return URL(string: base + "/artwork/" + stem + "." + ext)
    }

    /// 中继上有没有这张:200 且是图片 = 有;404 = 还没传上去;连不上、超时、别的状态 = 不知道(nil)。
    public static func exists(_ url: URL) async -> Bool? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            NetworkAuditLog.record(service: "relay", operation: "artwork.check", host: url.host ?? "",
                                   statusCode: http?.statusCode, durationMs: Date().timeIntervalSince(started) * 1000,
                                   error: nil)
            switch http?.statusCode {
            case 200?: return (http?.mimeType ?? "").hasPrefix("image/")
            case 404?: return false
            default: return nil
            }
        } catch {
            NetworkAuditLog.record(service: "relay", operation: "artwork.check", host: url.host ?? "",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(started) * 1000, error: error)
            return nil
        }
    }
}

/// 给 App 外面(Discord 状态)挑这首的封面地址。依次取,前一档有就不往下走:
/// 1. 当前播放器自己给的公网地址(调用方给:Spotify / Kaset / YouTube Music 网页版是 App 读到的,网易云 / QQ / KKBOX /
///    Amazon 是引擎从它们本机数据里读到、记在缓存条目里的);
/// 2. 本机那张封面在网页中继上的地址(跟 App 里显示的是同一张,配了中继、中继上已经有才算);
/// 3. 当前是 Apple Music 时按系统给的曲库曲目 ID 问 iTunes;
/// 4. 本机封面在网上的同一张图(引擎换上本机封面时核对过是同一张,见 `EnrichCacheReader.publicCoverURL`)、同一首在别的
///    播放器记下的、缓存里认专辑的封面(调用方给);
/// 5. 按缓存里 Apple Music 链接的专辑 ID 问 iTunes(专辑得对得上正在放的,见 `anchoredAlbumMatches`),再按歌手 + 歌名搜、
///    只认专辑对得上的(`sameAlbum`);
/// 6. 放的是视频(Kaset、YouTube Music 网页版)、前面都没有时,这支视频的截图(调用方给,`KasetPlayerInfo.videoFrameURL`)。
/// 2、3、5 要联网,在 `lookUp` 里;都没有时调用方用应用里上传的图。
public enum PresenceCover {
    public enum Tier: Sendable, Equatable {
        case relay, appleTrack, appleAlbum, search

        /// 排在「别的播放器记下的 / 缓存里的」那一档前面:中继上那张就是 App 里显示的,按曲目 ID 查到的就是这一首。
        public var beatsLocal: Bool { self == .relay || self == .appleTrack }
    }

    public struct Hit: Sendable, Equatable {
        public let url: URL
        public let tier: Tier
        /// 按曲目 ID 问 iTunes 时顺带拿到的 Apple Music 歌手页(Discord 状态里歌手那一行的链接)。
        public let artistPage: URL?

        public init(url: URL, tier: Tier, artistPage: URL? = nil) {
            self.url = url
            self.tier = tier
            self.artistPage = artistPage
        }
    }

    /// `videoFrame`:放的是视频时这支视频的截图,只在别的都没有时用 —— 有方形专辑图就用专辑图。
    public static func pick(own: URL?, hit: Hit?, local: URL?, videoFrame: URL? = nil) -> URL? {
        if let own { return own }
        if let hit, hit.tier.beatsLocal { return hit.url }
        return local ?? hit?.url ?? videoFrame
    }

    // MARK: - 专辑对不对得上

    /// 比专辑名用的形状:先去掉不改变封面的标记(版本标记 Explicit / Clean,Apple 给单曲、EP 加的 - Single / - EP),再按
    /// `PlayCountFold.foldTitle` 折叠(繁简、大小写、空格、Remaster 这类目录学尾巴、中英双语名只留一种),最后只留字母和数字
    /// (标点两边写法不一:`HIStory: PAST, PRESENT…` / `HIStory - PAST, PRESENT…`)。纯函数,selftest 覆盖。
    public static func albumIdentity(_ album: String) -> String {
        var s = album
        var stripped = true
        while stripped {
            stripped = false
            for pattern in neutralAlbumMarkers {
                if let r = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    s.removeSubrange(r)
                    stripped = true
                }
            }
        }
        let folded = PlayCountFold.foldTitle(s)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// 专辑名末尾不改变封面的标记:`[Explicit]` / `(Clean)` / `[Explicit Version]` 这类版本标记,Apple 加的 ` - Single` / ` - EP`。
    private static let neutralAlbumMarkers = [#"\s*[\[(](explicit|clean)( version)?[\])]\s*$"#, #"\s+-\s+(single|ep)\s*$"#]

    /// 两个专辑名算不算同一张:`albumIdentity` 相等。`: The Encore`、`(Deluxe)`、`(Gold)` 这类版本差异算不同 —— 那常是另一张
    /// 封面。第 5 档按歌名搜时挑结果用(`MusicCatalogSearch.pickArtwork` 的 `albumMatches`)。纯函数,selftest 覆盖。
    public static func sameAlbum(_ a: String, _ b: String) -> Bool {
        let identity = albumIdentity(a)
        return !identity.isEmpty && identity == albumIdentity(b)
    }

    /// 第 5 档按缓存里 Apple Music 链接的专辑 ID 取到的那张(`catalog`),跟正在放的专辑对不对得上。链接是引擎按歌名、署名、
    /// 时长对出来的,偶尔锚到同一首歌的另一张发行,封面就跟播放器里的不是一张(实测 Taylor Swift《Wood》放的是
    /// The Encore 版,链接锚在标准版)。对不上就当没找到,接着按歌名搜。
    ///
    /// 正在放的没报专辑:比不了,算对得上。`sameAlbum` 算对得上;一边只有拉丁字母、一边带中日韩文字也比不了,信链接 ——
    /// 中国区店面给中文专辑名、播放器给英文名(`Timeless` / `可啦思刻`、`Hello Goodbye` / `再见你好吗`),本机缓存里
    /// 有链接的 1646 首实测这一类 11 首,都是同一张专辑。纯函数,selftest 覆盖。
    public static func anchoredAlbumMatches(playing: String, catalog: String?) -> Bool {
        let playing = playing.trimmingCharacters(in: .whitespaces)
        if playing.isEmpty { return true }
        guard let catalog = catalog?.trimmingCharacters(in: .whitespaces), !catalog.isEmpty else { return false }
        if sameAlbum(playing, catalog) { return true }
        return (isLatinOnly(playing) && LyricsWordEmphasis.containsCJK(catalog))
            || (isLatinOnly(catalog) && LyricsWordEmphasis.containsCJK(playing))
    }

    private static func isLatinOnly(_ s: String) -> Bool {
        !LyricsWordEmphasis.containsCJK(s) && s.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// 要联网那几档用的东西。没有一样能查的时候调用方别发起(`isEmpty`)。
    public struct Request: Sendable, Equatable {
        public var relayURL: URL?
        public var appleTrackID: Int64?
        public var trackStorefronts: [String]
        public var albumRef: AlbumEditorialNotes.AlbumRef?
        public var albumStorefronts: [String]
        public var artist: String
        public var title: String
        public var album: String
        public var searchStorefront: String
        /// 第 4 档没有时才往第 5 档查。
        public var wantsFallback: Bool

        public init(relayURL: URL?, appleTrackID: Int64?, trackStorefronts: [String],
                    albumRef: AlbumEditorialNotes.AlbumRef?, albumStorefronts: [String],
                    artist: String, title: String, album: String, searchStorefront: String, wantsFallback: Bool) {
            self.relayURL = relayURL
            self.appleTrackID = appleTrackID
            self.trackStorefronts = trackStorefronts
            self.albumRef = albumRef
            self.albumStorefronts = albumStorefronts
            self.artist = artist
            self.title = title
            self.album = album
            self.searchStorefront = searchStorefront
            self.wantsFallback = wantsFallback
        }

        public var isEmpty: Bool { relayURL == nil && appleTrackID == nil && !wantsFallback }
    }

    /// 按第 2、3、5 档的顺序查。`relayMissing`:中继上还没有这张(引擎在播放后才传),调用方过一会儿再问一次中继。
    /// `unreached`:没查到,而且有一档没问成(iTunes 冷却中、超时、限流,中继连不上)—— 不是「那边没有」,调用方过一会儿
    /// 再查(`retryAt`)。中继和曲目 ID 那两档同时问:中继上有这张也要曲目 ID 那份回包里的歌手页(`Hit.artistPage`)。
    /// `gate` 是 iTunes 的退避闸门,selftest 换成自己的(冷却中的闸门让各档当场没问成,不发请求)。
    public static func lookUp(_ request: Request,
                              gate: ITunesSearchGate = .shared) async -> (hit: Hit?, relayMissing: Bool, unreached: Bool) {
        async let relayState = relayExists(request.relayURL)
        async let trackState = appleTrackLookup(request, gate: gate)
        var relayMissing = false
        var unreached = false
        let track = await trackState
        let artistPage = track?.match?.artistPage
        if let relay = request.relayURL {
            switch await relayState {
            case true?: return (Hit(url: relay, tier: .relay, artistPage: artistPage), false, false)
            case false?: relayMissing = true
            case nil: unreached = true
            }
        }
        if let match = track?.match {
            return (Hit(url: match.url, tier: .appleTrack, artistPage: artistPage), relayMissing, false)
        }
        if case .unreached? = track { unreached = true }
        guard request.wantsFallback else { return (nil, relayMissing, unreached) }
        if let ref = request.albumRef {
            switch await MusicCatalogSearch.albumArtwork(albumID: ref.id, storefronts: request.albumStorefronts, gate: gate) {
            case .found(let match) where anchoredAlbumMatches(playing: request.album, catalog: match.matchedAlbum):
                return (Hit(url: match.url, tier: .appleAlbum), relayMissing, false)
            case .found:
                // 链接锚到了同一首歌的另一张发行:当没找到,接着按歌名搜。
                break
            case .unreached: return (nil, relayMissing, true)
            case .noMatch: break
            }
        }
        let lookup = await MusicCatalogSearch.resolveArtwork(
            title: request.title, artist: request.artist, album: request.album.isEmpty ? nil : request.album,
            storefront: request.searchStorefront, albumMatches: sameAlbum, gate: gate)
        if case .unreached = lookup { return (nil, relayMissing, true) }
        guard let match = lookup.match, match.confidence == .albumMatch || request.album.isEmpty else {
            return (nil, relayMissing, unreached)
        }
        return (Hit(url: match.url, tier: .search), relayMissing, false)
    }

    /// 没问成之后第一次再问隔多久;之后每次翻倍,最长 `retryMaxDelay`。
    public static let retryBaseDelay: TimeInterval = 20
    public static let retryMaxDelay: TimeInterval = 300

    /// `lookUp` 报没问成时,这一首什么时候再查:`attempt` 是这一首已经查过几轮(第一轮是 0),隔 `retryBaseDelay` 起、每轮
    /// 翻倍、最长 `retryMaxDelay`;iTunes 还在冷却(`cooldownEnds`,`ITunesSearchGate.cooldownEnds`)就等到冷却结束。
    /// 纯函数,selftest 覆盖。
    public static func retryAt(attempt: Int, now: Date, cooldownEnds: Date?) -> Date {
        let delay = min(retryBaseDelay * pow(2, Double(min(max(0, attempt), 16))), retryMaxDelay)
        let earliest = now.addingTimeInterval(delay)
        guard let cooldownEnds, cooldownEnds > earliest else { return earliest }
        return cooldownEnds
    }

    private static func relayExists(_ url: URL?) async -> Bool? {
        guard let url else { return nil }
        return await RelayArtwork.exists(url)
    }

    /// 按曲目 ID 问 iTunes 的结局;没有曲目 ID 时为 nil(这一档不问)。
    private static func appleTrackLookup(_ request: Request, gate: ITunesSearchGate) async -> MusicCatalogSearch.ArtworkLookup? {
        guard let id = request.appleTrackID else { return nil }
        return await MusicCatalogSearch.trackArtwork(trackID: id, storefronts: request.trackStorefronts, gate: gate)
    }

    /// 按曲目 ID 查时依次问的店面:系统地区在前,美区兜底;小写、去重。
    public static func trackStorefronts(region: String?) -> [String] {
        var out: [String] = []
        for raw in [region, "us"] {
            guard let store = raw?.lowercased(), !store.isEmpty, !out.contains(store) else { continue }
            out.append(store)
        }
        return out
    }
}
