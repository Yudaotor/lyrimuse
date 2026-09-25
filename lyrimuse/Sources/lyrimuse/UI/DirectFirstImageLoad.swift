import AppKit
import Foundation
import LyrimuseCore

/// 图片「先直连,连不上再走系统代理」。只给 Spotify 图床原图替代用(见 PlaybackCoordinator.refreshSpotifyOriginalCover)。
///
/// `URLSession.shared` 一律走系统代理:同一张 Spotify 原图,直连 1.7 秒,经系统代理 40 秒超时(640 档也要
/// 八秒到七十秒不等)。直连用短超时,失败就按主机记下,10 分钟内这台主机直接走代理 —— 跟 collector 对
/// 自己请求的做法同一个思路(proxyfallback.go)。直连拿到的图写进 ImageMemoryCache,跟代理那条路共用缓存。
@MainActor
enum DirectFirstImageLoad {
    private static let directSession: URLSession = {
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

    /// 原图档(不降采样)。直连失败退回 ImageMemoryCache.shared.load(系统代理,不设总时长上限)。
    static func loadOriginal(_ url: URL) async -> NSImage? {
        if let hit = ImageMemoryCache.shared.image(for: url, variant: .original) { return hit }
        let host = url.host ?? ""
        let directAllowed = directFailedAt[host].map { Date().timeIntervalSince($0) >= directRetryAfter } ?? true
        if directAllowed {
            if let image = await fetchDirect(url) {
                directFailedAt[host] = nil
                ImageMemoryCache.shared.store(image, for: url, variant: .original)
                return image
            }
            directFailedAt[host] = Date()
        }
        return await ImageMemoryCache.shared.load(url, variant: .original)
    }

    private static func fetchDirect(_ url: URL) async -> NSImage? {
        let start = Date()
        do {
            let (data, resp) = try await directSession.data(from: url)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "image", operation: "image-direct", host: url.host ?? "unknown",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            guard status == 200 else { return nil }
            return NSImage(data: data)
        } catch {
            NetworkAuditLog.record(service: "image", operation: "image-direct", host: url.host ?? "unknown",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
