import CryptoKit
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "motion-cover")

/// Apple Music 动态封面的**下载与落盘**(2026-09-09)。
///
/// 分工:发现在 collector(`motioncover.go`,把 master m3u8 记进 enrich 缓存)、清单推导在 Core
/// (`MotionCoverManifest`,纯函数、selftest 钉着)、播放在 `MotionCoverLayer`,这一层只干三件事:
/// 拼出该下哪个文件、把它下下来、按 LRU 管住磁盘。
///
/// **为什么是"下整个文件"而不是流式播 HLS**:用户 2026-09-09 选的就是"先下载再本地循环"。而它
/// 之所以做得到,是因为实测发现每一档 variant 的分片全是**同一个 `.mp4` 的 byte range**
/// (`#EXT-X-MAP` + `#EXT-X-BYTERANGE`)—— 底层就是一个完整 fMP4,整份拿下来直接就能播,不必拼
/// 分片、也不必上 `AVAssetDownloadURLSession` 那套 `.movpkg`。代价是首次要等几秒(实测 960²
/// 档 7.17 MB),换来的是之后零网络、无卡顿、可反复命中。完整实测清单见 `MotionCoverManifest` 头注。
@MainActor
final class MotionCoverStore {
    static let shared = MotionCoverStore()

    /// 歌词窗口那张封面卡是 460pt,Retina 下 920px —— 按它选档(实测会落到 960² 那一档)。
    /// 灵动岛那 32pt 的小图和「跟随封面」背景**共用同一份文件**,不为它们再下一档小的:
    /// 同一张专辑存两份视频换不来什么,而用户随时可能把歌词窗口打开。
    static let targetPixelWidth = 920

    /// 磁盘上限。一份 ~7 MB,400 MB 约合 55 张专辑;超了按访问时间删最旧的。
    /// 动态封面覆盖率只有三成上下,实际很难长到这个量级,这个数是兜底不是常态。
    private static let diskBudgetBytes: Int64 = 400 << 20

    private let fm = FileManager.default
    /// 正在下的 key → 任务。同一个 key 并发只跑一次(同 `ImageMemoryCache` 的做法)。
    private var inflight: [String: Task<URL?, Never>] = [:]
    /// 这一次运行里已经失败过的 key —— 失败多半是"Apple 改了结构 / 这档拿不到",反复重试
    /// 只是白发请求。刻意**不落盘**:进程重启后再给一次机会。
    private var failed: Set<String> = []

    private var directory: URL { LyrimusePaths.configFile("motion-covers") }

    // MARK: - 对外

    /// 已经在盘上的那份;没有就 nil(调用方据此决定要不要 `prepare`)。
    func cachedFile(master: URL) -> URL? {
        let url = fileURL(for: master)
        guard fm.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    /// 取这张专辑的动态封面本地文件:盘上有就直接给,没有就下一份。
    ///
    /// 幂等 —— 同一个 master 并发调多次只会真下一次。失败返回 nil 且这一次运行里不再重试
    /// (见 `failed`)。**任何一步失败都只是"这首没有动态封面"**,不往上抛错(理由见
    /// `MotionCoverManifest` 头注最后一段:这是在解析公开网页里的非公开字段,必须优雅失效)。
    func prepare(master: URL) async -> URL? {
        if let hit = cachedFile(master: master) { return hit }
        let key = cacheKey(for: master)
        if failed.contains(key) { return nil }
        if let running = inflight[key] { return await running.value }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            let result = await self.download(master: master)
            await MainActor.run {
                self.inflight[key] = nil
                if result == nil { self.failed.insert(key) }
            }
            return result
        }
        inflight[key] = task
        return await task.value
    }

    // MARK: - 下载

    private nonisolated func download(master: URL) async -> URL? {
        do {
            // ① master → 选一档。
            let masterText = try await text(from: master)
            let variants = MotionCoverManifest.parseVariants(master: masterText)
            guard let picked = MotionCoverManifest.pick(variants, minimumWidth: Self.targetPixelWidth),
                  let variantURL = MotionCoverManifest.absolute(picked.uri, relativeTo: master) else {
                logger.info("motion cover: no usable variant in master playlist")
                return nil
            }
            // ② variant → 那个承载全部分片的单文件。
            let variantText = try await text(from: variantURL)
            guard let name = MotionCoverManifest.mediaFileName(fromVariant: variantText),
                  let mediaURL = MotionCoverManifest.absolute(name, relativeTo: variantURL) else {
                logger.info("motion cover: variant has no EXT-X-MAP single file")
                return nil
            }
            // ③ 整份下下来。
            let (data, response) = try await URLSession.shared.data(from: mediaURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.info("motion cover: media http \(http.statusCode, privacy: .public)")
                return nil
            }
            guard Self.looksLikeMP4(data) else {
                logger.info("motion cover: payload is not an mp4 (\(data.count, privacy: .public) bytes)")
                return nil
            }
            return try await MainActor.run { try self.store(data, master: master, width: picked.width) }
        } catch {
            logger.info("motion cover: fetch failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated func text(from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CocoaError(.fileReadUnknown)
        }
        guard let s = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return s
    }

    /// 落盘:临时文件 + 原子改名(同 collector 那几份缓存),半份文件永远不会被当成可播的。
    private func store(_ data: Data, master: URL, width: Int) throws -> URL {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let final = fileURL(for: master)
        let tmp = final.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: final.path) { try? fm.removeItem(at: final) }
        try fm.moveItem(at: tmp, to: final)
        logger.info("motion cover: stored \(width, privacy: .public)px \(data.count / 1024, privacy: .public)KB")
        pruneIfNeeded()
        return final
    }

    // MARK: - 磁盘管理

    private func fileURL(for master: URL) -> URL {
        directory.appendingPathComponent("\(cacheKey(for: master)).mp4")
    }

    /// key 里带上目标宽度:哪天把 `targetPixelWidth` 调了,旧文件不会被当成新档次的那份继续用。
    private func cacheKey(for master: URL) -> String {
        let seed = "\(master.absoluteString)|w\(Self.targetPixelWidth)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// mp4 magic:偏移 4 起是 `ftyp`。防的是"拿回来一段 HTML 错误页也当视频存下来"。
    private nonisolated static func looksLikeMP4(_ data: Data) -> Bool {
        guard data.count > 64 * 1024 else { return false }
        return data[4..<8].elementsEqual([0x66, 0x74, 0x79, 0x70]) // "ftyp"
    }

    /// 访问即续命 —— LRU 按 mtime 排,读一次就把它顶到最新。
    private func touch(_ url: URL) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// 超预算就按 mtime 从旧到新删,删到预算之下。
    private func pruneIfNeeded() {
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in items where url.pathExtension == "mp4" {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = v.fileSize, let date = v.contentModificationDate else { continue }
            files.append((url, Int64(size), date))
            total += Int64(size)
        }
        guard total > Self.diskBudgetBytes else { return }
        for f in files.sorted(by: { $0.date < $1.date }) {
            guard total > Self.diskBudgetBytes else { break }
            try? fm.removeItem(at: f.url)
            total -= f.size
            logger.info("motion cover: pruned \(f.size / 1024, privacy: .public)KB")
        }
    }
}
