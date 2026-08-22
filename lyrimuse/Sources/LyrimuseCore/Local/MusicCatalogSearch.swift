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

        public init(trackName: String?, artistName: String?, collectionName: String?,
                    trackViewUrl: String?, artistViewUrl: String?, collectionViewUrl: String?) {
            self.trackName = trackName
            self.artistName = artistName
            self.collectionName = collectionName
            self.trackViewUrl = trackViewUrl
            self.artistViewUrl = artistViewUrl
            self.collectionViewUrl = collectionViewUrl
        }
    }

    struct Response: Decodable { let results: [Item] }

    /// 请求 URL。storefront 传系统地区码、外层兜底 "us" —— 账号店面与系统地区可能
    /// 不一致,搜错店面的代价只是链接落到别的店面页,Music.app 会自己按账号跳转。
    public static func searchURL(title: String, artist: String, storefront: String) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")
        c?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "8"),
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
