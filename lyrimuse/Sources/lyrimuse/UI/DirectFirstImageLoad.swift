import AppKit
import Foundation
import LyrimuseCore

/// 图片「先直连,连不上再走系统代理」。只给 Spotify 图床原图替代用(见 PlaybackCoordinator.refreshSpotifyOriginalCover)。
///
/// `URLSession.shared` 一律走系统代理:同一张 Spotify 原图,直连 1.7 秒,经系统代理 40 秒超时(640 档也要
/// 八秒到七十秒不等)。直连用短超时,失败就按主机记下,10 分钟内这台主机直接走代理 —— 跟引擎对
/// 自己请求的做法同一个思路(proxyfallback.go)。直连拿到的图写进 ImageMemoryCache,跟代理那条路共用缓存。
@MainActor
enum DirectFirstImageLoad {
    private nonisolated static let directSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.connectionProxyDictionary = [:] // 空字典 = 不用任何代理(nil 才是跟随系统设置)
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 15
        c.urlCache = URLCache.shared
        return URLSession(configuration: c)
    }()

    /// 直连失败过的主机,多久之内不再试直连。
    private static let directRetryAfter: TimeInterval = 10 * 60
    private static var directFailedAt: [String: Date] = [:]

    /// 原图档。直连这条不降采样(Spotify 原图实测最大 2000²,本来就在原图档 2048 的封顶之内);
    /// 直连失败退回 ImageMemoryCache.shared.load(系统代理,不设总时长上限)。
    static func loadOriginal(_ url: URL) async -> NSImage? {
        if let hit = ImageMemoryCache.shared.image(for: url, variant: .original) { return hit }
        let host = url.host ?? ""
        let directAllowed = directFailedAt[host].map { Date().timeIntervalSince($0) >= directRetryAfter } ?? true
        if directAllowed {
            switch await fetchDirect(url) {
            case .image(let image):
                directFailedAt[host] = nil
                ImageMemoryCache.shared.store(image, for: url, variant: .original)
                return image
            case .serverAnswered:
                // 直连是通的,只是服务器说没有这张图(Spotify 原图档本来就可能没有,取不到退 640):
                // 不拉黑这台主机,也不再去走系统代理 —— 代理那边拿到的是同一个 404,还要白等 8~70 秒。
                directFailedAt[host] = nil
                return nil
            case .transportFailed:
                // 调用方取消了(切歌、封面换了):不是直连不通,别把这台主机拉黑 10 分钟,也别再去走系统代理。
                if Task.isCancelled { return nil }
                directFailedAt[host] = Date()
            }
        }
        return await ImageMemoryCache.shared.load(url, variant: .original)
    }

    private enum DirectResult {
        case image(NSImage)
        /// 连上了、服务器回了非 200(或者回来的字节解不成图)。
        case serverAnswered
        /// 连不上 / 超时 / 被取消。只有这一种才说明「直连不通、该走代理」。
        case transportFailed
    }

    /// nonisolated:解码(Spotify 原图最大 2000²)在后台做,别占主线程。
    private nonisolated static func fetchDirect(_ url: URL) async -> DirectResult {
        let start = Date()
        do {
            let (data, resp) = try await directSession.data(from: url)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.recordSummarized(service: "image", operation: "image-direct", host: url.host ?? "unknown",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            guard status == 200, let image = NSImage(data: data) else { return .serverAnswered }
            return .image(image)
        } catch {
            NetworkAuditLog.recordSummarized(service: "image", operation: "image-direct", host: url.host ?? "unknown",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return .transportFailed
        }
    }
}
