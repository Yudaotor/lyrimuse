import AVFoundation
import CryptoKit
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "spotify-canvas")

/// Spotify Canvas 短片的**下载与落盘**。地址由引擎从 Spotify 本机缓存里读出(`SpotifyCanvas`),播放复用动态封面那一层
/// (`MotionCoverView`)。跟 `MotionCoverStore` 的区别:Canvas 是另拍的画面、不跟封面比对,下完解得出一帧就存。
@MainActor
final class SpotifyCanvasStore {
    static let shared = SpotifyCanvasStore()

    /// 磁盘上限。一段 1～8 MB,超了按访问时间删最旧的。
    private static let diskBudgetBytes: Int64 = 300 << 20

    private let fm = FileManager.default
    /// 正在下的地址 → 任务。同一个地址并发只下一次。
    private var inflight: [URL: Task<URL?, Never>] = [:]
    /// 这次运行里拿不到的地址(404、不是 mp4、解不出帧)。不落盘,重启后再给一次机会。
    private var failed: Set<URL> = []
    /// 网络层失败的地址 → 退避到什么时候、连着失败了几次(2、4、8… 分钟,最多 30 分钟)。
    private var transientBackoff: [URL: (until: Date, failures: Int)] = [:]

    /// 不进 `URLCache.shared`:文件自己落盘一份,再进共享缓存会把封面挤出去。
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private var directory: URL { LyrimusePaths.cacheFile("spotify-canvas") }

    private init() {}

    /// 已经在盘上的那份;没有为 nil。
    func cachedFile(_ remote: URL) -> URL? {
        let url = fileURL(for: remote)
        guard fm.fileExists(atPath: url.path) else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// 取这段短片的本地文件:盘上有直接给,没有就下一份。拿不到为 nil(这首就照旧用封面背景)。
    func prepare(_ remote: URL) async -> URL? {
        if let hit = cachedFile(remote) { return hit }
        if failed.contains(remote) { return nil }
        if let backoff = transientBackoff[remote], backoff.until > Date() { return nil }
        if let running = inflight[remote] { return await running.value }
        let target = fileURL(for: remote)
        let task = Task<URL?, Never> {
            let outcome = await Self.download(remote, to: target)
            switch outcome {
            case .ready:
                self.transientBackoff[remote] = nil
                self.pruneIfNeeded()
                return target
            case .transient:
                let failures = (self.transientBackoff[remote]?.failures ?? 0) + 1
                let minutes = min(30.0, pow(2.0, Double(failures)))
                self.transientBackoff[remote] = (Date().addingTimeInterval(minutes * 60), failures)
                return nil
            case .unavailable:
                self.failed.insert(remote)
                return nil
            }
        }
        inflight[remote] = task
        let result = await task.value
        inflight[remote] = nil
        return result
    }

    private enum Outcome { case ready, transient, unavailable }

    private nonisolated static func download(_ remote: URL, to final: URL) async -> Outcome {
        do {
            let (data, response) = try await session.data(from: remote)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.notice("spotify canvas: http \(http.statusCode, privacy: .public)")
                return http.statusCode == 429 || http.statusCode >= 500 ? .transient : .unavailable
            }
            guard looksLikeMP4(data) else {
                logger.notice("spotify canvas: payload is not an mp4 (\(data.count, privacy: .public) bytes)")
                return .unavailable
            }
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory.appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString + ".mp4")
            try data.write(to: scratch, options: .atomic)
            defer { try? fm.removeItem(at: scratch) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: scratch))
            guard (try? await generator.image(at: .zero).image) != nil else {
                logger.notice("spotify canvas: file decodes no frame")
                return .unavailable
            }
            try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: scratch, to: final)
            logger.info("spotify canvas: stored \(data.count / 1024, privacy: .public)KB")
            return .ready
        } catch {
            logger.notice("spotify canvas: fetch failed — \(error.localizedDescription, privacy: .public)")
            return error is URLError ? .transient : .unavailable
        }
    }

    /// mp4 第 4～8 字节是 `ftyp`。
    nonisolated static func looksLikeMP4(_ data: Data) -> Bool {
        data.count > 12 && data.subdata(in: 4..<8) == Data("ftyp".utf8)
    }

    private func fileURL(for remote: URL) -> URL {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)) + ".mp4")
    }

    /// 超出磁盘上限时按修改时间(读一次就刷新一次)删最旧的。
    private func pruneIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.filter { $0.pathExtension == "mp4" }.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > Self.diskBudgetBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > Self.diskBudgetBytes {
            try? fm.removeItem(at: url)
            total -= size
        }
    }
}
