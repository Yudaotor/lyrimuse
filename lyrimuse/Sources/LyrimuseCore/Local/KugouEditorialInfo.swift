import Foundation

/// 专辑简介、歌手简介的一个来源:酷狗音乐的专辑介绍、歌手介绍。**只在用酷狗放过这首时有**:专辑 id 是引擎按酷狗正在放的
/// 那个文件记下的(缓存里的 `player_album_ids`,`PlatformLinks.kugouAlbum` 就是它的专辑页),精确对上、不用搜。
///
/// 两步,都不用登录:`mobileservice.kugou.com/api/v3/album/info?albumid=` 给专辑介绍和专辑歌手 id,
/// `…/api/v3/singer/info?singerid=` 给歌手介绍(同一套接口在 `mobilecdn.kugou.com` 上只有 http)。专辑不存在时 `status` 1、
/// `data` 为 null;歌手 id 不合法时 `status` 0。专辑署名的歌手跟正在放的对不上(合辑、合唱)时不给歌手卡片。
///
/// 只在中文界面问(介绍只有中文),排在汽水之后、网易云之前(专辑 id 是播放器给的,网易云那边是引擎按歌名对的)。正文保留
/// 原文分行,繁体界面转成繁体。纯函数部分 selftest 钉着。见 05 章决策 93。
public enum KugouEditorialInfo {
    /// 一张专辑的介绍(nil = 酷狗没有)和专辑歌手。
    public struct Album: Equatable, Sendable, Codable {
        public let text: String?
        public let singerID: String?
        public let singerName: String?

        public init(text: String?, singerID: String?, singerName: String?) {
            self.text = text
            self.singerID = singerID
            self.singerName = singerName
        }
    }

    /// 一位歌手的名字和介绍(nil = 酷狗没有)。
    public struct Singer: Equatable, Sendable, Codable {
        public let name: String?
        public let text: String?

        public init(name: String?, text: String?) {
            self.name = name
            self.text = text
        }
    }

    /// 酷狗专辑页 `https://www.kugou.com/album/info/<id>/` → 专辑 id;别的地址为 nil。
    public static func albumID(fromAlbumPage url: URL?) -> String? {
        guard let url, url.host == "www.kugou.com" else { return nil }
        let parts = url.pathComponents
        guard parts.count == 4, parts[1] == "album", parts[2] == "info", isNumericID(parts[3]) else { return nil }
        return parts[3]
    }

    public static func albumInfoURL(id: String) -> URL? {
        isNumericID(id) ? URL(string: "https://mobileservice.kugou.com/api/v3/album/info?albumid=\(id)") : nil
    }

    public static func singerInfoURL(id: String) -> URL? {
        isNumericID(id) ? URL(string: "https://mobileservice.kugou.com/api/v3/singer/info?singerid=\(id)") : nil
    }

    /// 专辑应答 → 介绍 + 专辑歌手。`status` 不是 1、解不开为 nil(没问成);`data` 为 null 是酷狗没有这张专辑。
    public static func album(fromResponse data: Data) -> Album? {
        guard let body = payload(data) else { return nil }
        guard let info = body else { return Album(text: nil, singerID: nil, singerName: nil) }
        let text = EditorialText.lines(info["intro"] as? String ?? "")
        return Album(text: text.isEmpty ? nil : text, singerID: numericID(info["singerid"]),
                     singerName: trimmed(info["singername"]))
    }

    /// 歌手应答 → 名字 + 介绍。`status` 不是 1、解不开为 nil(没问成);`data` 为 null 是酷狗没有这位歌手。
    public static func singer(fromResponse data: Data) -> Singer? {
        guard let body = payload(data) else { return nil }
        guard let info = body else { return Singer(name: nil, text: nil) }
        let text = EditorialText.lines(info["intro"] as? String ?? "")
        return Singer(name: trimmed(info["singername"]), text: text.isEmpty ? nil : text)
    }

    /// `{"status":1,"data":{…}}` 的 data:外层 nil = 没问成,内层 nil = data 是 null。
    static func payload(_ data: Data) -> [String: Any]?? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["status"] as? NSNumber)?.intValue == 1 else { return nil }
        if root["data"] is NSNull || root["data"] == nil { return .some(nil) }
        guard let info = root["data"] as? [String: Any] else { return nil }
        return .some(info)
    }

    static func numericID(_ value: Any?) -> String? {
        guard let value else { return nil }
        let s = "\(value)"
        return isNumericID(s) && s != "0" ? s : nil
    }

    static func trimmed(_ value: Any?) -> String? {
        let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    static func isNumericID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 20 && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber)
    }

    /// 这个界面语言下问不问酷狗:只在中文界面(简体、繁体)问 —— 介绍只有中文。
    public static func isUsable(uiLanguage: String) -> Bool {
        EditorialText.isChineseUI(uiLanguage)
    }

    /// 繁体界面(`zh-Hant`)把正文转成繁体;别的界面原样。
    public static func localized(_ text: String, uiLanguage: String) -> String {
        EditorialText.localized(text, uiLanguage: uiLanguage)
    }

    /// 专辑介绍与专辑歌手。nil = 没问成。
    public static func fetchAlbum(id: String, session: URLSession = .shared) async -> Album? {
        guard let url = albumInfoURL(id: id) else { return Album(text: nil, singerID: nil, singerName: nil) }
        return await fetch(url, operation: "album.info", session: session).flatMap(album(fromResponse:))
    }

    /// 歌手名字与介绍。nil = 没问成。
    public static func fetchSinger(id: String, session: URLSession = .shared) async -> Singer? {
        guard let url = singerInfoURL(id: id) else { return Singer(name: nil, text: nil) }
        return await fetch(url, operation: "singer.info", session: session).flatMap(singer(fromResponse:))
    }

    /// 带浏览器 User-Agent 取一次,记进对外请求审计日志(服务名 `kugou`)。非 200、网络错误为 nil。
    private static func fetch(_ url: URL, operation: String, session: URLSession = .shared) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let host = url.host ?? "mobileservice.kugou.com"
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "kugou", operation: operation, host: host,
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return status == 200 ? data : nil
        } catch {
            NetworkAuditLog.record(service: "kugou", operation: operation, host: host,
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
