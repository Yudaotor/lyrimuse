import Foundation

/// 一首歌在各平台的跳转目标(2026-08-24)。
///
/// 数据**全部早就在本机**:collector 解析歌词那一轮顺手把 `apple_music_url` / `qq_music_url` /
/// `netease_url` 落进了 enrich 缓存(本机实测覆盖率 95% / 100% / 85%),QQ 的专辑/歌手 mid
/// 2026-08-24 一起补上 —— 而 Swift 侧此前**一个都没解码**(`EnrichCacheEntry.CodingKeys` 只有
/// 歌词和封面那几个)。所以这一族入口是**零网络**的,不像「前往专辑」老那条要先打一次
/// iTunes Search。
///
/// 2026-09-10 加 Spotify 曲目页(`spotify_track_id`,见 `spotifySong`),同时简介面板那行改成只显示
/// **当前播放器自己那个平台**的歌曲页(`songLink(forPlayerBundleID:webPlatformID:)`),不再全铺。
///
/// ⚠️ 落地位置不一样,文案必须分开写:
/// - Apple Music 那条能改写成 `music://`,**在 Music.app 里原生打开**;
/// - Spotify 给的是 `open.spotify.com` 网页链接(进 App 的深链是菜单里「在 Spotify 中显示」那条,
///   `SpotifyReveal`),这里不抢它的活;
/// - QQ 音乐 / 网易云只能落到**浏览器**。QQ 音乐没有 `associated-domains` 授权(实测
///   entitlements 里没有),`y.qq.com` 不会被 App 接走;而它注册的 `qqmusicmac://` 命令表
///   只有 `playsong` / `downloadsong`(2026-08-24 二进制取证),没有任何"打开这一页"的语义 ——
///   而且 `playsong` 会把正在放的这首从头重播,不是我们要的。所以别把它写成「在 QQ 音乐中打开」。
public struct PlatformLinks: Sendable, Equatable {
    /// Apple Music 曲目页(已是 `music://`,进 App)。
    public let appleMusic: URL?
    /// QQ 音乐歌曲页(浏览器)。**已排除搜索兜底链接** —— 见 `isQQSearchFallback`。
    public let qqSong: URL?
    /// QQ 音乐专辑页 / 歌手页(浏览器)。缺 mid 时为 nil,调用方据此隐藏对应入口。
    public let qqAlbum: URL?
    public let qqArtist: URL?
    /// 网易云音乐歌曲页(浏览器)。
    public let neteaseSong: URL?
    /// Spotify 曲目页 `open.spotify.com/track/<id>`(浏览器;2026-09-10 起解码)。**只认真曲目 ID**
    /// (collector 的 `spotify_track_id`,Spotify 原生播放换曲那一拍从 `spotify url` 留下的),
    /// 缓存里另一个 `spotify_url` 是本地拼的**搜索页**兜底,跟 QQ 的搜索兜底同一个理由不当歌曲页给出去。
    public let spotifySong: URL?

    public var isEmpty: Bool {
        appleMusic == nil && qqSong == nil && qqAlbum == nil && qqArtist == nil && neteaseSong == nil && spotifySong == nil
    }

    public init(appleMusic: URL?, qqSong: URL?, qqAlbum: URL?, qqArtist: URL?, neteaseSong: URL?, spotifySong: URL? = nil) {
        self.appleMusic = appleMusic
        self.qqSong = qqSong
        self.qqAlbum = qqAlbum
        self.qqArtist = qqArtist
        self.neteaseSong = neteaseSong
        self.spotifySong = spotifySong
    }

    /// 歌曲页所在的平台 —— 给「简介」面板那行选文案用(名字在 App 层本地化,这里只给身份)。
    public enum Platform: String, Sendable, Equatable {
        case appleMusic, qqMusic, netease, spotify
    }

    /// **当前播放器自己那个平台**上这首歌的歌曲页(2026-09-10,用户定的规则:简介面板的「网页」行
    /// 只显示对应播放器的,不再把三个平台全铺开)。
    ///
    /// - Apple Music 播放 → Apple Music 曲目页(`music://`,进 App);QQ 音乐 → QQ 歌曲页;网易云 →
    ///   网易云歌曲页;Spotify(原生客户端,或浏览器里配对成 `spotifyWeb` 的网页版)→ Spotify 曲目页。
    /// - 酷狗 / YouTube Music / 认不出来的播放器 → nil:collector 没存酷狗歌曲页(酷狗网页版能开的只有
    ///   `kugou.com/mixsong/<EMixSongID>.html`,那个编码 ID 只有带签名的网页版搜索接口才给),YouTube
    ///   Music 压根没存链接。调用方据 nil 整行隐藏,不拿别的平台顶上。
    /// - 播放器认得出但这首歌在它那个平台上没链接(网易云版权下架的周杰伦、QQ 只有搜索兜底)→ 同样 nil。
    ///
    /// `webPlatformID` 是 `BrowserPositionProbe.playingPlatformID(forBundleID:)` 的结果(浏览器在放哪个
    /// 网页音乐平台),优先于 bundle id 判 —— 浏览器的 bundle id 本身不对应任何平台。
    public func songLink(forPlayerBundleID bundleID: String?, webPlatformID: String? = nil) -> (platform: Platform, url: URL)? {
        if webPlatformID == "spotifyWeb" {
            return spotifySong.map { (.spotify, $0) }
        }
        guard let bundleID, !bundleID.isEmpty else { return nil }
        switch bundleID {
        case PlaybackPlayer.appleMusic.bundleIdentifier: return appleMusic.map { (.appleMusic, $0) }
        case PlaybackPlayer.qqMusic.bundleIdentifier: return qqSong.map { (.qqMusic, $0) }
        case PlaybackPlayer.netease.bundleIdentifier: return neteaseSong.map { (.netease, $0) }
        case PlaybackPlayer.spotify.bundleIdentifier: return spotifySong.map { (.spotify, $0) }
        default: return nil
        }
    }

    // MARK: - 纯函数(selftest 钉住)

    /// Spotify 曲目页。ID 的形状闸与 collector 的 `spotifyTrackIDFromURI` 同源:22 位 base62,别的一律不认
    /// (缓存里这个字段只由 collector 写,形状闸是防手改 / 防把 `missing value` 这类脚本回声当 ID)。
    public static func spotifyTrackURL(id: String) -> URL? {
        guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return URL(string: "https://open.spotify.com/track/" + id)
    }

    /// `qq_music_url` 有两档:真·歌曲页 `…/n/ryqq/songDetail/<mid>`,和 smartbox 查不到
    /// 时拼的**搜索页兜底**。判据与 collector 的 `isQQSearchFallbackURL` 同源(qq.go:49-54)。
    ///
    /// ⚠️ 必须区分:把兜底链接当"这首歌的页面"给出去,用户点了会被丢到一个搜索结果页,
    /// 还得自己再点一次 —— 那不该叫「歌曲页」。本机实测 565 条里有 40 条是这一档。
    public static func isQQSearchFallback(_ raw: String) -> Bool {
        raw.hasPrefix("https://y.qq.com/n/ryqq/search?")
    }

    /// QQ 音乐专辑页。路由实测有效(302 到 /n/ryqq_v2/…,与代码在用的 songDetail 同族)。
    public static func qqAlbumURL(mid: String) -> URL? {
        guard isPlausibleQQMid(mid) else { return nil }
        return URL(string: "https://y.qq.com/n/ryqq/albumDetail/" + mid)
    }

    /// QQ 音乐歌手页。多歌手时 collector 只存首位 —— QQ 的歌手页是一人一页,
    /// 合唱曲目没有"这首歌的歌手页"这种东西。
    public static func qqArtistURL(mid: String) -> URL? {
        guard isPlausibleQQMid(mid) else { return nil }
        return URL(string: "https://y.qq.com/n/ryqq/singer/" + mid)
    }

    /// mid 的形状闸。y.qq.com 是个 SPA 空壳:**假 mid 也会 302**,服务端不校验,
    /// 所以链接对不对没有任何远端反馈 —— 只能在本地把明显不是 mid 的东西挡掉
    /// (空串、带斜杠/问号的路径片段、超长)。
    public static func isPlausibleQQMid(_ mid: String) -> Bool {
        guard !mid.isEmpty, mid.count <= 32 else { return false }
        return mid.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
