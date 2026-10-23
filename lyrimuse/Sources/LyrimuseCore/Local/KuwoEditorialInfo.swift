import Foundation

/// 专辑简介、歌手简介的一个来源:酷我音乐的专辑介绍、歌手介绍。**只在用洛雪放来自酷我的歌时有**:曲目 id 是洛雪本地库给的
/// (`PlatformLinks.kuwoSong`,酷我歌曲页 `www.kuwo.cn/play_detail/<id>`),精确对上、不用搜。
///
/// 两步,都不用登录:曲目 id 经数据中心(`datacenter.kuwo.cn/d.c?ft=music&ids=<id>&cmkey=plist_pl2012`,JSON 数组)换成专辑 id、
/// 歌手 id;再取 `search.kuwo.cn/r.s?stype=albuminfo&albumid=` / `stype=artistinfo&artistid=`,回的是单引号的伪 JSON,正文在
/// `'info':'…'`(带 `\n` 转义和 `&nbsp;` 这类实体)。两个接口不带浏览器 User-Agent 回 403(实测)。专辑文案跟 QQ 音乐常是
/// 同一份宣传稿。
///
/// 只在中文界面问(介绍只有中文),排在网易云之后(网易云的介绍更长)。正文保留原文分行,繁体界面转成繁体。纯函数部分
/// selftest 钉着。见 05 章决策 92。
public enum KuwoEditorialInfo {
    public enum Kind: Equatable, Sendable {
        case album, artist
    }

    /// 一首歌在酷我的专辑 id、歌手 id(没有的为 nil)。
    public struct IDs: Equatable, Sendable, Codable {
        public let albumID: String?
        public let artistID: String?

        public init(albumID: String?, artistID: String?) {
            self.albumID = albumID
            self.artistID = artistID
        }
    }

    /// 酷我歌曲页 → 曲目 id;别的地址为 nil。
    public static func songID(fromSongPage url: URL?) -> String? {
        guard let url, url.host == "www.kuwo.cn" else { return nil }
        let parts = url.pathComponents
        guard parts.count == 3, parts[1] == "play_detail", isNumericID(parts[2]) else { return nil }
        return parts[2]
    }

    public static func datacenterURL(songID: String) -> URL? {
        guard isNumericID(songID) else { return nil }
        return URL(string: "https://datacenter.kuwo.cn/d.c?ft=music&ids=\(songID)&cmkey=plist_pl2012")
    }

    /// 数据中心应答 → 这首的专辑 id、歌手 id。数组里没有这一首为两个都是 nil 的 IDs(酷我明确没有);解不开为 nil。
    public static func ids(fromDatacenter data: Data, songID: String) -> IDs? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        guard let row = rows.first(where: { "\($0["id"] ?? "")" == songID }) else { return IDs(albumID: nil, artistID: nil) }
        func id(_ key: String) -> String? {
            let s = "\(row[key] ?? "")"
            return isNumericID(s) && s != "0" ? s : nil
        }
        return IDs(albumID: id("albumid"), artistID: id("artistid"))
    }

    public static func infoURL(_ kind: Kind, id: String) -> URL? {
        guard isNumericID(id) else { return nil }
        switch kind {
        case .album: return URL(string: "https://search.kuwo.cn/r.s?stype=albuminfo&albumid=\(id)")
        case .artist: return URL(string: "https://search.kuwo.cn/r.s?stype=artistinfo&artistid=\(id)")
        }
    }

    /// 简介应答 → 正文;没有 `'info'` 这一项为 nil(没问成),有但是空的为 ""(酷我明确没有)。
    public static func info(fromResponse data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #"'info'\s*:\s*'((?:[^'\\]|\\.)*)'"#, options: .regularExpression) else { return nil }
        let match = String(text[range])
        guard let open = match.range(of: #":\s*'"#, options: .regularExpression) else { return nil }
        let raw = String(match[open.upperBound...].dropLast())
        return EditorialText.lines(decodeEntities(unescape(raw)))
    }

    /// 伪 JSON 字符串里的反斜杠转义:`\n` 换行,`\t` 空格,别的去掉反斜杠留原字。
    static func unescape(_ s: String) -> String {
        var out = ""
        var escaping = false
        for ch in s {
            if escaping {
                switch ch {
                case "n": out.append("\n")
                case "r": break
                case "t": out.append(" ")
                default: out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// 常见的几个具名实体和数字实体还原;认不出的原样留着。
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'"]
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var decoded: String?
                if let v = named[name] {
                    decoded = v
                } else if name.hasPrefix("#x") || name.hasPrefix("#X"), let n = UInt32(name.dropFirst(2), radix: 16) {
                    decoded = Unicode.Scalar(n).map(String.init)
                } else if name.hasPrefix("#"), let n = UInt32(name.dropFirst()) {
                    decoded = Unicode.Scalar(n).map(String.init)
                }
                if let decoded {
                    out += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }

    static func isNumericID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 20 && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber)
    }

    /// 这个界面语言下问不问酷我:只在中文界面(简体、繁体)问 —— 介绍只有中文。
    public static func isUsable(uiLanguage: String) -> Bool {
        EditorialText.isChineseUI(uiLanguage)
    }

    /// 繁体界面(`zh-Hant`)把正文转成繁体;别的界面原样。
    public static func localized(_ text: String, uiLanguage: String) -> String {
        EditorialText.localized(text, uiLanguage: uiLanguage)
    }

    /// 曲目 id → 专辑 id、歌手 id。nil = 没问成。
    public static func fetchIDs(songID: String, session: URLSession = .shared) async -> IDs? {
        guard let url = datacenterURL(songID: songID) else { return IDs(albumID: nil, artistID: nil) }
        return await fetch(url, operation: "datacenter.music", session: session).flatMap { ids(fromDatacenter: $0, songID: songID) }
    }

    /// 专辑 / 歌手的介绍。nil = 没问成;"" = 酷我没有。
    public static func fetchInfo(_ kind: Kind, id: String, session: URLSession = .shared) async -> String? {
        guard let url = infoURL(kind, id: id) else { return "" }
        return await fetch(url, operation: kind == .album ? "albuminfo" : "artistinfo", session: session).flatMap(info(fromResponse:))
    }

    /// 带浏览器 User-Agent 取一次,记进对外请求审计日志(服务名 `kuwo`)。非 200、网络错误为 nil。
    private static func fetch(_ url: URL, operation: String, session: URLSession = .shared) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let host = url.host ?? "kuwo.cn"
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "kuwo", operation: operation, host: host,
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return status == 200 ? data : nil
        } catch {
            NetworkAuditLog.record(service: "kuwo", operation: operation, host: host,
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
