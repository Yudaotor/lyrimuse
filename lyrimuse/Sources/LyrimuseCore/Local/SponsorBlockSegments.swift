import CryptoKit
import Foundation

/// 查 SponsorBlock 标注的 MV「非音乐片段」(`music_offtopic`),给 `MusicVideoTimeline` 用。
///
/// 走哈希前缀接口 `GET /api/skipSegments/<sha256(videoID) 前 4 位>`:服务器返回同一前缀下的一批视频,
/// 本地挑出自己那一支,SponsorBlock 不知道具体在看哪个视频。别换成按 videoID 直查的接口。
///
/// 数据许可是 CC BY-NC-SA 4.0:只能运行时按需取、只在本机用。不落盘到会随包或随备份分发的地方,
/// 不经任何我们自己的服务转发,不把数据文件放进仓库(见 02 章决策 50)。署名在 THIRD_PARTY_LICENSES。
public actor SponsorBlockSegments {
    public static let shared = SponsorBlockSegments()

    public struct Result: Equatable, Sendable {
        public let cuts: [MusicVideoTimeline.Cut]
        /// SponsorBlock 记录的视频时长;没有片段时为 nil。
        public let videoDurationSecs: Double?
    }

    static let baseURL = URL(string: "https://sponsor.ajay.app/api/skipSegments/")!
    private static let timeout: TimeInterval = 8
    private static let cacheLimit = 200

    /// 按 videoID 缓存查到的结果(含「没有标注」)。只在内存里,进程退出即丢。
    private var cache: [String: Result] = [:]
    private var inFlight: [String: Task<Result?, Never>] = [:]

    /// videoID 的 SHA-256 十六进制前 4 位(接口文档推荐的长度)。
    public static func hashPrefix(forVideoID videoID: String) -> String {
        SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4).description
    }

    public static func requestURL(forVideoID videoID: String) -> URL? {
        var c = URLComponents(url: baseURL.appendingPathComponent(hashPrefix(forVideoID: videoID)), resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "categories", value: "[\"music_offtopic\"]"),
            URLQueryItem(name: "actionTypes", value: "[\"skip\"]"),
        ]
        return c?.url
    }

    /// 解析哈希前缀接口的返回,挑出 `videoID` 那一支的 `music_offtopic` / `skip` 片段。
    /// 返回里没有这一支 = 没有标注(`cuts` 为空);JSON 形状不对返回 nil。
    public static func parse(_ data: Data, videoID: String) -> Result? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        guard let mine = arr.first(where: { ($0["videoID"] as? String) == videoID }),
              let segs = mine["segments"] as? [[String: Any]] else {
            return Result(cuts: [], videoDurationSecs: nil)
        }
        var cuts: [MusicVideoTimeline.Cut] = []
        var duration: Double?
        for s in segs {
            guard (s["category"] as? String) == "music_offtopic",
                  (s["actionType"] as? String ?? "skip") == "skip",
                  let pair = s["segment"] as? [NSNumber], pair.count == 2 else { continue }
            cuts.append(.init(start: pair[0].doubleValue, end: pair[1].doubleValue))
            if let d = (s["videoDuration"] as? NSNumber)?.doubleValue, d > 0 { duration = d }
        }
        return Result(cuts: cuts, videoDurationSecs: duration)
    }

    /// 查一支视频的片段。网络失败返回 nil,不进缓存,下次再查。
    public func segments(forVideoID videoID: String) async -> Result? {
        if let hit = cache[videoID] { return hit }
        if let running = inFlight[videoID] { return await running.value }
        let task = Task<Result?, Never> { await Self.fetch(videoID: videoID) }
        inFlight[videoID] = task
        let result = await task.value
        inFlight[videoID] = nil
        if let result {
            if cache.count >= Self.cacheLimit { cache.removeAll() }
            cache[videoID] = result
        }
        return result
    }

    private static func fetch(videoID: String) async -> Result? {
        guard let url = requestURL(forVideoID: videoID) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        req.setValue("Lyrimuse/\(version) (https://github.com/Yudaotor/lyrimuse)", forHTTPHeaderField: "User-Agent")
        let start = Date()
        let host = url.host ?? "sponsor.ajay.app"
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "sponsorblock", operation: "skipSegments", host: host,
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            // 404 = 这个前缀下一支有标注的视频都没有。
            if status == 404 { return Result(cuts: [], videoDurationSecs: nil) }
            guard status == 200 else { return nil }
            return parse(data, videoID: videoID)
        } catch {
            NetworkAuditLog.record(service: "sponsorblock", operation: "skipSegments", host: host,
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
