import Foundation

/// 歌曲简介的一个来源:QQ 音乐歌曲详情里的「简介」—— 客户端网关 `musicu.fcg` 的 `music.pf_song_detail_svr` /
/// `get_song_detail_yqq`,不用登录(引擎取 QQ 的歌词、搜歌也走这个网关)。Apple Music 不给单曲写介绍(Apple Music API
/// 单曲的 `editorialNotes` 抽 39 首一首都没有),所以歌曲简介没有 Apple 那一档,直接从这里起;**只在中文界面问**
/// (`isUsable`):简介是中文写的,问的话排在 Last.fm 前面。
///
/// 歌曲只从这首在缓存里的 QQ 音乐歌曲页来(enrich 缓存的 `qq_music_url`,引擎解析歌词时按歌名、歌手、时长对上的;
/// 搜索页兜底那一档不算,见 `PlatformLinks.qqSongMID`),不按名字搜。
///
/// 覆盖率不高:抽样中文歌 25 首里 5 首有、外文歌 15 首里 1 首有;一两百字,讲词曲作者和创作背景。有的像机器写的、
/// 偶有事实错误(Justin Bieber《Peaches》那条把 2021 年的《Justice》写成 2023 年)—— 卡片底部注明「来自 QQ 音乐」。
/// 正文是简体,繁体界面转成繁体。纯函数部分 selftest 钉着。
public enum QQSongInfo {
    /// 解析结果。`.none` = QQ 明确没有(没有这首、或者有但没有简介);形状不对、风控是 nil(不记结论,下次再试)。
    public enum Parsed: Equatable, Sendable {
        case text(String)
        case none
    }

    public static let gatewayURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!

    /// 歌曲详情的请求体。mid 不像 QQ 的 songmid(`PlatformLinks.isPlausibleQQMid`)为 nil。
    public static func detailBody(songMID: String) -> Data? {
        guard PlatformLinks.isPlausibleQQMid(songMID) else { return nil }
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "songinfo": [
                "module": "music.pf_song_detail_svr",
                "method": "get_song_detail_yqq",
                "param": ["song_type": 0, "song_mid": songMID],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// 歌曲详情 → 简介(`songinfo.data.info.intro.content[].value`;多段之间空一行,每段保留原文的分行)。
    /// `songinfo.code` 是 404(没有这首,实测)、没有 `intro`、简介是空的为 `.none`;顶层 `code` 不是 0、`songinfo.code`
    /// 是别的(风控之类)、形状不对为 nil。
    public static func intro(fromDetail data: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == 0,
              let songinfo = root["songinfo"] as? [String: Any],
              let code = (songinfo["code"] as? NSNumber)?.intValue else { return nil }
        if code == 404 { return Parsed.none }
        guard code == 0, let info = (songinfo["data"] as? [String: Any])?["info"] as? [String: Any] else { return nil }
        let content = (info["intro"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        let parts = content.compactMap { item -> String? in
            let text = EditorialText.lines(item["value"] as? String ?? "")
            return text.isEmpty ? nil : text
        }
        return parts.isEmpty ? Parsed.none : .text(parts.joined(separator: "\n\n"))
    }

    /// 这个界面语言下问不问 QQ 音乐:只在中文界面(简体、繁体)问 —— 简介只有中文。
    public static func isUsable(uiLanguage: String) -> Bool {
        EditorialText.isChineseUI(uiLanguage)
    }

    /// 繁体界面(`zh-Hant`)把正文转成繁体;别的界面原样。
    public static func localized(_ text: String, uiLanguage: String) -> String {
        EditorialText.localized(text, uiLanguage: uiLanguage)
    }

    /// 这首的简介。nil = 没问成(网络、风控、形状不对),下次再试;mid 拼不成请求算 QQ 这边没有(`.none`)。
    /// 带浏览器的 User-Agent 和 QQ 音乐的 Referer,记进对外请求审计日志(服务名同 App 别处问 QQ 的 `qq`)。
    public static func fetchIntro(songMID: String, session: URLSession = .shared) async -> Parsed? {
        guard let body = detailBody(songMID: songMID) else { return Parsed.none }
        var req = URLRequest(url: gatewayURL)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        let host = gatewayURL.host ?? "u.y.qq.com"
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "qq", operation: "song.detail", host: host,
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return status == 200 ? intro(fromDetail: data) : nil
        } catch {
            NetworkAuditLog.record(service: "qq", operation: "song.detail", host: host,
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
