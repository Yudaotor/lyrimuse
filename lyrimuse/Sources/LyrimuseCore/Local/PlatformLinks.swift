import Foundation

/// 一首歌在各平台的跳转目标(2026-08-24)。
///
/// 数据**全部早就在本机**:collector 解析歌词那一轮顺手把 `apple_music_url` / `qq_music_url` /
/// `netease_url` 落进了 enrich 缓存(本机实测覆盖率 95% / 100% / 85%),QQ 的专辑/歌手 mid
/// 2026-08-24 一起补上 —— 而 Swift 侧此前**一个都没解码**(`EnrichCacheEntry.CodingKeys` 只有
/// 歌词和封面那几个)。所以这一族入口是**零网络**的,不像「前往专辑」老那条要先打一次
/// iTunes Search。
///
/// ⚠️ 落地位置不一样,文案必须分开写:
/// - Apple Music 那条能改写成 `music://`,**在 Music.app 里原生打开**;
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

    public var isEmpty: Bool {
        appleMusic == nil && qqSong == nil && qqAlbum == nil && qqArtist == nil && neteaseSong == nil
    }

    public init(appleMusic: URL?, qqSong: URL?, qqAlbum: URL?, qqArtist: URL?, neteaseSong: URL?) {
        self.appleMusic = appleMusic
        self.qqSong = qqSong
        self.qqAlbum = qqAlbum
        self.qqArtist = qqArtist
        self.neteaseSong = neteaseSong
    }

    // MARK: - 纯函数(selftest 钉住)

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
