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
/// 4. 同一首在别的播放器记下的、缓存里认专辑的封面(调用方给);
/// 5. 按缓存里 Apple Music 链接的专辑 ID 问 iTunes,再按歌手 + 歌名搜、只认专辑对得上的。
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

    public static func pick(own: URL?, hit: Hit?, local: URL?) -> URL? {
        if let own { return own }
        if let hit, hit.tier.beatsLocal { return hit.url }
        return local ?? hit?.url
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
    /// 中继和曲目 ID 那两档同时问:中继上有这张也要曲目 ID 那份回包里的歌手页(`Hit.artistPage`)。
    public static func lookUp(_ request: Request) async -> (hit: Hit?, relayMissing: Bool) {
        async let relayState = relayExists(request.relayURL)
        async let trackMatch = appleTrackMatch(request)
        var relayMissing = false
        let artistPage = await trackMatch?.artistPage
        if let relay = request.relayURL {
            switch await relayState {
            case true?: return (Hit(url: relay, tier: .relay, artistPage: artistPage), false)
            case false?: relayMissing = true
            case nil: break
            }
        }
        if let match = await trackMatch {
            return (Hit(url: match.url, tier: .appleTrack, artistPage: artistPage), relayMissing)
        }
        guard request.wantsFallback else { return (nil, relayMissing) }
        if let ref = request.albumRef {
            switch await MusicCatalogSearch.albumArtwork(albumID: ref.id, storefronts: request.albumStorefronts) {
            case .found(let match): return (Hit(url: match.url, tier: .appleAlbum), relayMissing)
            case .unreached: return (nil, relayMissing)
            case .noMatch: break
            }
        }
        let lookup = await MusicCatalogSearch.resolveArtwork(
            title: request.title, artist: request.artist, album: request.album.isEmpty ? nil : request.album,
            storefront: request.searchStorefront)
        guard let match = lookup.match, match.confidence == .albumMatch || request.album.isEmpty else {
            return (nil, relayMissing)
        }
        return (Hit(url: match.url, tier: .search), relayMissing)
    }

    private static func relayExists(_ url: URL?) async -> Bool? {
        guard let url else { return nil }
        return await RelayArtwork.exists(url)
    }

    private static func appleTrackMatch(_ request: Request) async -> MusicCatalogSearch.ArtworkMatch? {
        guard let id = request.appleTrackID else { return nil }
        return await MusicCatalogSearch.trackArtwork(trackID: id, storefronts: request.trackStorefronts).match
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
