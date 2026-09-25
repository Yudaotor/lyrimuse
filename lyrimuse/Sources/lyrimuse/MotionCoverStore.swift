import AVFoundation
import CryptoKit
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "motion-cover")

/// Apple Music 动态封面的**下载与落盘**。
///
/// 分工:发现在 collector(`motioncover.go`,把 master m3u8 记进 enrich 缓存)、清单推导在 Core
/// (`MotionCoverManifest`,纯函数、selftest 钉着)、播放在 `MotionCoverLayer`,这一层只干三件事:
/// 拼出该下哪个文件、把它下下来、按 LRU 管住磁盘。
///
/// **为什么是"下整个文件"而不是流式播 HLS**:用户选的就是"先下载再本地循环"。而它
/// 之所以做得到,是因为实测发现每一档 variant 的分片全是**同一个 `.mp4` 的 byte range**
/// (`#EXT-X-MAP` + `#EXT-X-BYTERANGE`)—— 底层就是一个完整 fMP4,整份拿下来直接就能播,不必拼
/// 分片、也不必上 `AVAssetDownloadURLSession` 那套 `.movpkg`。代价是首次要等几秒(实测 960²
/// 档 7.17 MB),换来的是之后零网络、无卡顿、可反复命中。完整实测清单见 `MotionCoverManifest` 头注。
@MainActor
final class MotionCoverStore {
    static let shared = MotionCoverStore()

    /// 歌词窗口那张封面卡是 460pt,Retina 下 920px —— 按它选档(实测会落到 960² 那一档)。
    /// 那张卡是**唯一**的消费面(灵动岛那份已撤,见 `NotchLyricsView` 顶上那条注释),所以
    /// 这个数就照它一个来定,不必为别的尺寸再存一档。
    static let targetPixelWidth = 920

    /// 磁盘上限。一份 ~7 MB,400 MB 约合 55 张专辑;超了按访问时间删最旧的。
    /// 动态封面覆盖率只有三成上下,实际很难长到这个量级,这个数是兜底不是常态。
    private static let diskBudgetBytes: Int64 = 400 << 20

    private let fm = FileManager.default
    /// 正在下的 key 到 任务。同一个 key 并发只跑一次(同 `ImageMemoryCache` 的做法)。
    private var inflight: [String: Task<URL?, Never>] = [:]
    /// 这一次运行里已经失败过的 key —— 失败多半是"Apple 改了结构 / 这档拿不到",反复重试
    /// 只是白发请求。刻意**不落盘**:进程重启后再给一次机会。
    private var failed: Set<String> = []

    private var directory: URL { LyrimusePaths.configFile("motion-covers") }

    // MARK: - 对外
    ///
    /// **终审没过不算失败,别往这里塞**。那是"此刻拿来比对的封面不对",不是"这份资源
    /// 取不到" —— 换歌那几秒里参照图完全可能还是上一首的(播放器推自带占位图时更是如此,
    /// 见 `KnownPlaceholderArtwork`:那种情况下我们会刻意留着上一首的封面)。记进这里就等于
    /// 拿一次时序上的巧合,把整张专辑的动态封面封杀到进程重启。它归 `referenceRejected`。

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
    ///
    /// - Parameter reference: 当前显示的那张封面的 `CoverFingerprint.Reference`。下载完成后
    ///   会拿视频**中段**的真实一帧跟它比一次,理由见 `verifyMatchesReference` 的注释。传
    ///   nil(拿不到当前封面,比如刚换歌那一瞬)就跳过这道终审,不因为一时缺参照而白白拒了。
    func prepare(master: URL, referenceHash: UInt64?) async -> URL? {
        if let hit = cachedFile(master: master) { return hit }
        let key = cacheKey(for: master)
        if failed.contains(key) { return nil }
        if let running = inflight[key] { return await running.value }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            let result = await self.download(master: master, referenceHash: referenceHash)
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

    private nonisolated func download(master: URL, referenceHash: UInt64?) async -> URL? {
        do {
            // ① master 到 选一档。
            let masterText = try await text(from: master)
            let variants = MotionCoverManifest.parseVariants(master: masterText)
            guard let picked = MotionCoverManifest.pick(variants, minimumWidth: Self.targetPixelWidth),
                  let variantURL = MotionCoverManifest.absolute(picked.uri, relativeTo: master) else {
                logger.notice("motion cover: no usable variant in master playlist")
                return nil
            }
            // ② variant 到 那个承载全部分片的单文件。
            let variantText = try await text(from: variantURL)
            guard let name = MotionCoverManifest.mediaFileName(fromVariant: variantText),
                  let mediaURL = MotionCoverManifest.absolute(name, relativeTo: variantURL) else {
                logger.notice("motion cover: variant has no EXT-X-MAP single file")
                return nil
            }
            // ③ 整份下下来,先落到临时文件——终审(④)要用 AVAsset 读它,得是个真实文件路径,
            // 不是内存里的 Data。落地在系统临时目录,不是最终缓存位置:没通过终审就地删掉,
            // 通过了再原子改名搬进 `directory`(⑤ store)。
            let (data, response) = try await URLSession.shared.data(from: mediaURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.notice("motion cover: media http \(http.statusCode, privacy: .public)")
                return nil
            }
            guard Self.looksLikeMP4(data) else {
                logger.notice("motion cover: payload is not an mp4 (\(data.count, privacy: .public) bytes)")
                return nil
            }
            let scratch = fm.temporaryDirectory.appendingPathComponent(
                ProcessInfo.processInfo.globallyUniqueString + ".mp4")
            try data.write(to: scratch, options: .atomic)
            defer { try? fm.removeItem(at: scratch) }
            // ④ 终审:视频中段的真实一帧跟当前封面像不像。
            if let referenceHash, !(await Self.verifyMatchesReference(scratch, referenceHash: referenceHash)) {
                return nil
            }
            // ⑤ 通过终审才落盘。
            return try await MainActor.run { try self.store(data, master: master, width: picked.width) }
        } catch {
            logger.notice("motion cover: fetch failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// **终审**:视频**中段**(时长过半)的真实一帧,跟当前显示的封面是不是同一张。
    ///
    /// 为什么不能只信 collector 那边(`motioncover.go` 的 `motionCoverMatchesCover`):它比的
    /// 是 Apple 给的 `previewFrame`,而那常常就是视频**最开头**一帧。有些专辑的动态封面开场
    /// 是"揭幕"特效——实测 Ariana Grande《Positions (Deluxe)》,首帧是逐渐聚拢的九宫格拼贴,
    /// 跟静态封面的感知距离高达 41(阈值 12 的好几倍),播到视频过半时才收拢成跟静态封面
    /// 逐位相同的画面(距离 0)。collector 拿不到解码后的视频帧,只能在 previewFrame 上打转;
    /// 这里能拿到刚下载下来的完整视频,能挑一个更可能"已经稳定下来"的时刻。
    ///
    /// 中段(`duration * 0.5`)是经验取值,不是精确计算出的"揭幕结束点"——不同专辑的揭幕
    /// 时长不一样,但"放到一半"总落在片头效果之后、循环收尾之前,兼顾两端。
    ///
    /// 取不到时长/取不到帧/解码失败,都当**没法确认**处理,返回 false——跟这条链路其它每一层
    /// 一样,拿不准就不显示动态封面,不该让一次解码失败悄悄放过一段没验过的动画。
    private nonisolated static func verifyMatchesReference(_ file: URL, referenceHash: UInt64) async -> Bool {
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return false }
        let midpoint = CMTime(seconds: duration.seconds * 0.5, preferredTimescale: duration.timescale)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? await generator.image(at: midpoint).image else { return false }
        let distance = CoverFingerprint.distance(CoverFingerprint.hash(of: frame), referenceHash)
        if distance > CoverFingerprint.motionCoverMaxDistance {
            logger.notice("motion cover: mid-video frame distance \(distance, privacy: .public) > \(CoverFingerprint.motionCoverMaxDistance, privacy: .public), skipping")
            return false
        }
        return true
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
