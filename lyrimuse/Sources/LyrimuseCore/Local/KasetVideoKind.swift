import Foundation

/// Kaset 放的这一条是不是播客单集。Kaset 自己知道视频类型,脚本接口不报,所以按 videoId 问一次 YouTube Music 的 `next`
/// (不登录,跟引擎取登记署名同一种问法),看它给这一条标的类型;结论按 videoId 记下,待播队列里的提前问好(`prefetch`,
/// App 代引擎读队列时调)。是播客单集就跟 KKBOX / Amazon 的播客一样当没在放音乐(`MediaControlClient.readKasetSnapshot`)。
/// 问不成不挡,当不是播客。
public enum KasetVideoKind {
    public enum Verdict: Equatable, Sendable {
        case podcastEpisode
        case notPodcast
        /// 正在问,结论还没出来。
        case pending
    }

    /// YouTube Music 给播客单集标的视频类型。
    public static let podcastEpisodeType = "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
    /// 一条从第一次问起这么久还没结论,就先当不是播客照常报,结论出来再改。
    public static let pendingHoldSecs: TimeInterval = 2
    /// 没问成的,隔这么久再问。
    public static let retryAfterSecs: TimeInterval = 60
    /// 问一次的上限。
    static let timeout: TimeInterval = 6
    static let cacheLimit = 500
    /// 跟引擎问 YouTube Music 时同一个 UA(`ytmusicUserAgent`)。
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"

    private static let lock = NSLock()
    /// videoId → 是不是播客单集(问成了的)。
    nonisolated(unsafe) private static var known: [String: Bool] = [:]
    /// 正在问的,第一次问的时刻。
    nonisolated(unsafe) private static var askingSince: [String: Date] = [:]
    /// 没问成的时刻。
    nonisolated(unsafe) private static var failedAt: [String: Date] = [:]
    /// 轮询问到时结论还没出来的(按住着的,和过了 `pendingHoldSecs` 先照常报的);结论出来只为它们通知,只被预问过的不通知。
    nonisolated(unsafe) private static var waiting: Set<String> = []
    /// 轮询最近问的那一条(正在放的)。表满了清表时留下它的,不然它下一拍要重新问、被按住一拍。
    nonisolated(unsafe) private static var lastAsked: String?
    nonisolated(unsafe) private static var resultSink: (@Sendable () -> Void)?

    /// 轮询在等的那一条问出结论后通知一声(播放源据此马上轮询一次,不等下一拍)。
    public static func setResultSink(_ sink: @escaping @Sendable () -> Void) {
        lock.lock()
        resultSink = sink
        lock.unlock()
    }

    /// 这个 videoId 此刻的结论。记过的直接给;没记过就在后台问(不阻塞),这一回给 `pending`。
    public static func verdict(for videoID: String, now: Date = Date()) -> Verdict {
        guard !videoID.isEmpty else { return .notPodcast }
        lock.lock()
        lastAsked = videoID
        let decision = decide(knownPodcast: known[videoID], failedAt: failedAt[videoID],
                              askingSince: askingSince[videoID], now: now)
        if decision.ask { askingSince[videoID] = now }
        if askingSince[videoID] != nil { waiting.insert(videoID) }
        lock.unlock()
        if decision.ask { fetch(videoID) }
        return decision.verdict
    }

    /// 后台把这些 videoId 的类型先问好(问成了的、正在问的、刚没问成的不再问)。
    public static func prefetch(_ videoIDs: [String], now: Date = Date()) {
        for id in Set(videoIDs) where !id.isEmpty {
            lock.lock()
            let decision = decide(knownPodcast: known[id], failedAt: failedAt[id], askingSince: askingSince[id], now: now)
            if decision.ask { askingSince[id] = now }
            lock.unlock()
            if decision.ask { fetch(id) }
        }
    }

    /// 由记下的状态给结论,并说要不要去问:问成了的照结论;没问成过的当不是、不再按住,隔 `retryAfterSecs` 再问;
    /// 正在问的,不到 `pendingHoldSecs` 给 `pending`,过了当不是;都没有就去问、这一回给 `pending`。纯函数,selftest 覆盖。
    public static func decide(knownPodcast: Bool?, failedAt: Date?, askingSince: Date?,
                              now: Date) -> (verdict: Verdict, ask: Bool) {
        if let knownPodcast { return (knownPodcast ? .podcastEpisode : .notPodcast, false) }
        if let failedAt {
            return (.notPodcast, askingSince == nil && now.timeIntervalSince(failedAt) >= retryAfterSecs)
        }
        if let askingSince {
            return (now.timeIntervalSince(askingSince) < pendingHoldSecs ? .pending : .notPodcast, false)
        }
        return (.pending, true)
    }

    /// next 应答里这个 videoId 那一条(`playlistPanelVideoRenderer`)的播放入口上标的视频类型。找不到返回 nil。
    /// 纯函数,selftest 覆盖。
    public static func videoType(fromNext data: Data, videoID: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: String?
        func walk(_ node: Any) {
            guard found == nil else { return }
            if let dict = node as? [String: Any] {
                if let r = dict["playlistPanelVideoRenderer"] as? [String: Any], (r["videoId"] as? String) == videoID {
                    let nav = r["navigationEndpoint"] as? [String: Any]
                    let watch = nav?["watchEndpoint"] as? [String: Any]
                    let configs = watch?["watchEndpointMusicSupportedConfigs"] as? [String: Any]
                    let music = configs?["watchEndpointMusicConfig"] as? [String: Any]
                    if let t = music?["musicVideoType"] as? String {
                        found = t
                        return
                    }
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(root)
        return found
    }

    /// `next` 的请求体:网页客户端身份(版本号按 UTC 日期),只带 videoId。
    public static func requestBody(videoID: String, now: Date = Date()) -> Data? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.\(formatter.string(from: now)).01.00"], "user": [:]],
            "videoId": videoID,
            "isAudioOnly": true,
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    private static func fetch(_ videoID: String) {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/next?prettyPrint=false&alt=json"),
              let body = requestBody(videoID: videoID) else { return }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let start = Date()
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "youtube-music", operation: "next.videoType", host: url.host ?? "music.youtube.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            let type = status == 200 ? data.flatMap { videoType(fromNext: $0, videoID: videoID) } : nil
            lock.lock()
            askingSince[videoID] = nil
            if status == 200 {
                if known.count >= cacheLimit { known = known.filter { $0.key == lastAsked } }
                known[videoID] = type == podcastEpisodeType
                failedAt[videoID] = nil
            } else {
                if failedAt.count >= cacheLimit { failedAt = failedAt.filter { $0.key == lastAsked } }
                failedAt[videoID] = Date()
            }
            let sink = waiting.remove(videoID) != nil ? resultSink : nil
            lock.unlock()
            sink?()
        }.resume()
    }
}
