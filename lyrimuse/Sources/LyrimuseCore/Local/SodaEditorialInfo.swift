import Foundation

/// 专辑简介、歌手简介的一个来源:汽水音乐的专辑介绍、歌手介绍。**只在用汽水放过这首时有**:专辑、歌手 ID 是汽水自己给的
/// (缓存里的 `soda_album_id` / `soda_artist_id`,`PlatformLinks.sodaAlbum` / `sodaArtist` 就是下面这两个分享页的地址),精确对上、
/// 不用搜 —— 汽水没有公开的搜索接口。
///
/// 取的是网页版分享页(`music.douyin.com/qishui/share/album?album_id=…` / `…/share/artist?artist_id=…`,不用登录,引擎取汽水的
/// 专辑曲目表也用它):服务端渲染时把整页数据以 `_ROUTER_DATA = {…}` 嵌在 HTML 里(`routerData`),专辑介绍在
/// `loaderData.album_page.albumInfo.intro`,歌手介绍在 `loaderData.artist_page.artistInfo.artist_profile.intro`。
/// 专辑不存在时页面照样 200,`albumInfo.hasError` 为 true(实测)。
///
/// 只在中文界面问(介绍只有中文),排在网易云前面(ID 是播放器自己给的,网易云那边是引擎按歌名对的)。正文保留原文分行
/// (专辑介绍常一句一行),繁体界面转成繁体。纯函数部分 selftest 钉着。
public enum SodaEditorialInfo {
    public enum PageKind: Equatable, Sendable {
        case album, artist
    }

    /// 一页的介绍:汽水写的名字(歌手卡片的标题用它 —— 播放器报的常是「泳儿/海鸣威」这种合唱署名)和正文。
    /// `text` 为 nil = 汽水明确没有(页面上报错、或者没有介绍)。
    public struct Intro: Equatable, Sendable {
        public let name: String?
        public let text: String?

        public init(name: String?, text: String?) {
            self.name = name
            self.text = text
        }
    }

    /// 分享页地址是专辑页还是歌手页(`/qishui/share/album`、`/qishui/share/artist`);别的为 nil。
    public static func pageKind(of url: URL) -> PageKind? {
        guard url.host == "music.douyin.com" else { return nil }
        switch url.path {
        case "/qishui/share/album": return .album
        case "/qishui/share/artist": return .artist
        default: return nil
        }
    }

    /// 分享页 → 名字 + 介绍。页面上报错(`hasError`,专辑 / 歌手不存在)、介绍是空的,`text` 为 nil;找不到页面数据、
    /// 没有 `albumInfo` / `artistInfo` 为 nil(没问成)。
    public static func intro(fromPage data: Data, kind: PageKind) -> Intro? {
        let loader = routerData(fromPage: data)?["loaderData"] as? [String: Any]
        let (pageKey, infoKey) = kind == .album ? ("album_page", "albumInfo") : ("artist_page", "artistInfo")
        guard let info = (loader?[pageKey] as? [String: Any])?[infoKey] as? [String: Any] else { return nil }
        if info["hasError"] as? Bool == true { return Intro(name: nil, text: nil) }
        let name = (info["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = kind == .album ? info["intro"] : (info["artist_profile"] as? [String: Any])?["intro"]
        let text = EditorialText.lines(raw as? String ?? "")
        return Intro(name: name?.isEmpty == false ? name : nil, text: text.isEmpty ? nil : text)
    }

    /// 分享页 HTML 里 `_ROUTER_DATA = {…}` 那个对象(标记同引擎 sodaParseSharePage)。只取标记后面第一个完整的 JSON 对象
    /// (按大括号配对,跳过字符串里的括号和转义),后面跟着的别的脚本不管。找不到、解不开为 nil。
    public static func routerData(fromPage data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        let marker = Array("_ROUTER_DATA = ".utf8)
        guard bytes.count > marker.count,
              let markerAt = (0...(bytes.count - marker.count)).first(where: { bytes[$0..<($0 + marker.count)].elementsEqual(marker) }),
              let start = bytes[(markerAt + marker.count)...].firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<bytes.count {
            let byte = bytes[i]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    return (try? JSONSerialization.jsonObject(with: Data(bytes[start...i]))) as? [String: Any]
                }
            default:
                break
            }
        }
        return nil
    }

    /// 这个界面语言下问不问汽水:只在中文界面(简体、繁体)问 —— 介绍只有中文。
    public static func isUsable(uiLanguage: String) -> Bool {
        EditorialText.isChineseUI(uiLanguage)
    }

    /// 繁体界面(`zh-Hant`)把正文转成繁体;别的界面原样。
    public static func localized(_ text: String, uiLanguage: String) -> String {
        EditorialText.localized(text, uiLanguage: uiLanguage)
    }

    /// 分享页(`PlatformLinks.sodaAlbum` / `sodaArtist`)的名字和介绍。nil = 没问成(网络、非 200、形状不对),下次再试;
    /// 不是这两种分享页的地址算汽水这边没有。
    public static func fetchIntro(page url: URL, session: URLSession = .shared) async -> Intro? {
        guard let kind = pageKind(of: url) else { return Intro(name: nil, text: nil) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let operation = kind == .album ? "share.album" : "share.artist"
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "soda", operation: operation, host: url.host ?? "music.douyin.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return status == 200 ? intro(fromPage: data, kind: kind) : nil
        } catch {
            NetworkAuditLog.record(service: "soda", operation: operation, host: url.host ?? "music.douyin.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
