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

    /// 磁盘上限。一份 ~6 MB,1 GB 约合 170 张专辑;超了按访问时间删最旧的。
    ///
    /// **别调回 400 MB**。那个数是按"覆盖率三成、很难长到这个量级"估的,实测不成立:
    /// 一份普通听歌库用两周就有 71 张专辑带动态封面(共约 433 MB),400 MB 装不下 —— 表现不是
    /// 报错,是**每放一张没缓存的就顶掉一张旧的**,下次回头听那张又要重下 6 MB、头几秒只有
    /// 静态图。这一档的成本是磁盘,收益是"听过的专辑再听就是即时的",1 GB 是按那个实测量级
    /// 留一倍余量。
    private static let diskBudgetBytes: Int64 = 1024 << 20

    private let fm = FileManager.default
    /// 正在下的 key → 任务。同一个 key 并发只跑一次(同 `ImageMemoryCache` 的做法)。
    private var inflight: [String: (task: Task<URL?, Never>, reference: CoverFingerprint.Reference?)] = [:]
    /// 这一次运行里已经失败过的 key —— 失败多半是"Apple 改了结构 / 这档拿不到",反复重试
    /// 只是白发请求。刻意**不落盘**:进程重启后再给一次机会。
    ///
    /// **终审没过不算失败,别往这里塞**。那是"此刻拿来比对的封面不对",不是"这份资源
    /// 取不到" —— 换歌那几秒里参照图完全可能还是上一首的(播放器推自带占位图时更是如此,
    /// 见 `KnownPlaceholderArtwork`:那种情况下我们会刻意留着上一首的封面)。记进这里就等于
    /// 拿一次时序上的巧合,把整张专辑的动态封面封杀到进程重启。它归 `referenceRejected`。
    private var failed: Set<String> = []

    /// 终审没过的 (key, 参照图) 组合。跟 `failed` 分开的理由见上;**带上参照图的指纹**是
    /// 关键:封面一换就是一个新组合,自然会再试一次,而参照图没变时不重复下载那几 MB。
    private var referenceRejected: Set<String> = []

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
    ///
    /// - Parameter reference: 当前显示的那张封面的 `CoverFingerprint.Reference`。下载完成后
    ///   会拿视频**中段**的真实一帧跟它比一次,理由见 `verifyMatchesReference` 的注释。传
    ///   nil(拿不到当前封面,比如刚换歌那一瞬)就跳过这道终审,不因为一时缺参照而白白拒了。
    func prepare(master: URL, reference: CoverFingerprint.Reference?) async -> URL? {
        if let hit = cachedFile(master: master) { return hit }
        let key = cacheKey(for: master)
        if failed.contains(key) { return nil }
        // 同一份参照图上次就没过终审,不必再下一遍那几 MB;参照图一换就是新组合,自然重试。
        if let reference, referenceRejected.contains(Self.rejectionKey(key, reference)) { return nil }
        if let running = inflight[key] {
            let result = await running.task.value
            // 在跑的那一轮拿的是另一张参照图(换歌那一刻参照图还是上一首的),它被终审拒了,不代表拿现在这张也会被拒:
            // 用这张再试一次。参照图相同、或者资源本身取不到(已记进 failed),就认这个结果。
            if result == nil, let reference, running.reference != reference, !failed.contains(key),
               !referenceRejected.contains(Self.rejectionKey(key, reference)) {
                return await prepare(master: master, reference: reference)
            }
            return result
        }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            let outcome = await self.download(master: master, reference: reference)
            return await MainActor.run { () -> URL? in
                self.inflight[key] = nil
                switch outcome {
                case .ready(let file):
                    return file
                case .referenceMismatch:
                    if let reference {
                        self.referenceRejected.insert(Self.rejectionKey(key, reference))
                    }
                    return nil
                case .unavailable:
                    self.failed.insert(key)
                    return nil
                case .transient:
                    // 断网、超时这类:这一次没下成,下次换到这张专辑再试,不记进 failed(那会封到进程重启)。
                    return nil
                }
            }
        }
        inflight[key] = (task, reference)
        return await task.value
    }

    /// `failed` / `referenceRejected` 两张表的键各自独立:前者按资源,后者按 (资源, 参照图)。
    private nonisolated static func rejectionKey(_ key: String, _ reference: CoverFingerprint.Reference) -> String {
        "\(key)|\(reference.full)|\(reference.cropped)"
    }

    // MARK: - 下载

    /// `download` 的三种结局。**`referenceMismatch` 必须跟 `unavailable` 分开**:
    /// 前者是"这份动画本身没问题,是此刻拿来比对的那张封面不对",后者才是"这份资源取不到"。
    /// 合成一种的话,换歌那几秒里一次参照图错位就会被记进 `failed`,整张专辑到进程重启为止
    /// 都不再有动态封面。
    private enum DownloadOutcome {
        case ready(URL)
        case referenceMismatch
        case unavailable
        /// 网络层失败(断网、超时、DNS、服务端 5xx / 429):不是资源的问题,不进 `failed`。
        case transient
    }

    /// 一张专辑最多试几条候选(见 `MotionCoverManifest.candidates`):第一条多半是 HEVC,第二条多半是
    /// 同宽度的 H.264;再往后只是同编码的别的码率,试多了只是白发请求。
    private static let maxCandidateAttempts = 3

    private nonisolated func download(master: URL, reference: CoverFingerprint.Reference?) async -> DownloadOutcome {
        // ① master → 按顺序排好的候选档位。
        let variants: [MotionCoverManifest.Variant]
        do {
            variants = MotionCoverManifest.parseVariants(master: try await text(from: master))
        } catch {
            logger.notice("motion cover: master fetch failed — \(error.localizedDescription, privacy: .public)")
            return error is URLError ? .transient : .unavailable
        }
        let candidates = MotionCoverManifest.candidates(variants, minimumWidth: Self.targetPixelWidth)
        guard !candidates.isEmpty else {
            logger.notice("motion cover: no usable variant in master playlist")
            return .unavailable
        }
        // 一条拿不到就试下一条。画面跟封面对不上就直接认:换个编码画的还是同一段动画。
        // 中途有过一次网络层失败,就按 transient 报:那次没下成不代表这张专辑没有,下次还该再试。
        var sawTransient = false
        for variant in candidates.prefix(Self.maxCandidateAttempts) {
            switch await fetch(variant, master: master, reference: reference) {
            case .ready(let file): return .ready(file)
            case .referenceMismatch: return .referenceMismatch
            case .transient: sawTransient = true
            case .unavailable: continue
            }
        }
        return sawTransient ? .transient : .unavailable
    }

    /// 下一条候选:variant 清单 → 承载全部分片的单文件 → 临时文件 → 终审(或至少解得出帧)→ 落盘。
    private nonisolated func fetch(_ picked: MotionCoverManifest.Variant, master: URL,
                                   reference: CoverFingerprint.Reference?) async -> DownloadOutcome {
        let codec = picked.isHEVC ? "hevc" : "h264"
        do {
            // ② variant → 那个承载全部分片的单文件。
            guard let variantURL = MotionCoverManifest.absolute(picked.uri, relativeTo: master) else {
                return .unavailable
            }
            let variantText = try await text(from: variantURL)
            guard let name = MotionCoverManifest.mediaFileName(fromVariant: variantText),
                  let mediaURL = MotionCoverManifest.absolute(name, relativeTo: variantURL) else {
                logger.notice("motion cover: \(codec, privacy: .public) variant has no EXT-X-MAP single file")
                return .unavailable
            }
            // ③ 整份下下来,先落到临时文件——终审(④)要用 AVAsset 读它,得是个真实文件路径,
            // 不是内存里的 Data。落地在系统临时目录,不是最终缓存位置:没通过终审就地删掉,
            // 通过了再原子改名搬进 `directory`(⑤ store)。
            let (data, response) = try await URLSession.shared.data(from: mediaURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.notice("motion cover: \(codec, privacy: .public) media http \(http.statusCode, privacy: .public)")
                return http.statusCode == 429 || http.statusCode >= 500 ? .transient : .unavailable
            }
            guard Self.looksLikeMP4(data) else {
                logger.notice("motion cover: \(codec, privacy: .public) payload is not an mp4 (\(data.count, privacy: .public) bytes)")
                return .unavailable
            }
            let scratch = fm.temporaryDirectory.appendingPathComponent(
                ProcessInfo.processInfo.globallyUniqueString + ".mp4")
            try data.write(to: scratch, options: .atomic)
            defer { try? fm.removeItem(at: scratch) }
            // ④ 终审:视频中段的真实一帧跟当前封面像不像。没有参照图(专辑身份已核验)时终审跳过,
            // 也得确认这份文件真解得出画面 —— 解不出就接着试下一条候选,别把一份放不了的存下来。
            if let reference {
                switch await Self.verifyMatchesReference(scratch, reference: reference) {
                case .pass: break
                case .mismatch: return .referenceMismatch
                // 读不出时长/取不到帧 —— 是这份视频本身的问题,跟参照图无关,按这条候选不可用算。
                case .undecidable: return .unavailable
                }
            } else if !(await Self.decodesAFrame(scratch)) {
                logger.notice("motion cover: \(codec, privacy: .public) file decodes no frame")
                return .unavailable
            }
            // ⑤ 通过终审才落盘:把这份已经写好的临时文件挪进缓存目录(几 MB 的写入留在这条后台路径上,
            // 主线程只做一次改名)。
            let final = await MainActor.run { self.fileURL(for: master) }
            try Self.moveIntoPlace(scratch, final: final)
            logger.info("motion cover: stored \(picked.width, privacy: .public)px \(codec, privacy: .public) \(data.count / 1024, privacy: .public)KB")
            await MainActor.run { self.pruneIfNeeded() }
            return .ready(final)
        } catch {
            logger.notice("motion cover: \(codec, privacy: .public) fetch failed — \(error.localizedDescription, privacy: .public)")
            return error is URLError ? .transient : .unavailable
        }
    }

    /// 第一帧解不解得出来。
    private nonisolated static func decodesAFrame(_ file: URL) async -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        return (try? await generator.image(at: .zero).image) != nil
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
    /// 取不到时长/取不到帧/解码失败都不显示动态封面 —— 跟这条链路其它每一层一样,拿不准就
    /// 不显示,不该让一次解码失败悄悄放过一段没验过的动画。但它们要跟"比过了、不是同一张"
    /// **分开报**(`undecidable` vs `mismatch`):前者是这份视频自己的问题、换张参照图也救不回来,
    /// 后者换张参照图就可能通过。合成一个 false 的话,调用方就没法把它们分别记进
    /// `failed` 和 `referenceRejected` 两张表。
    private enum VerifyResult {
        case pass
        case mismatch
        case undecidable
    }

    private nonisolated static func verifyMatchesReference(
        _ file: URL, reference: CoverFingerprint.Reference
    ) async -> VerifyResult {
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return .undecidable }
        let midpoint = CMTime(seconds: duration.seconds * 0.5, preferredTimescale: duration.timescale)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? await generator.image(at: midpoint).image else { return .undecidable }
        let (distance, same) = CoverFingerprint.matches(frame, reference: reference)
        if !same {
            logger.notice("motion cover: mid-video frame distance \(distance, privacy: .public), skipping")
            return .mismatch
        }
        return .pass
    }

    private nonisolated func text(from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CocoaError(.fileReadUnknown)
        }
        guard let s = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return s
    }

    /// 落盘:下载时写好的临时文件整份挪到最终位置(同卷是一次改名),半份文件永远不会被当成可播的。
    private nonisolated static func moveIntoPlace(_ scratch: URL, final: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: final.path) { try? fm.removeItem(at: final) }
        try fm.moveItem(at: scratch, to: final)
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

    /// 缓存目录里动态封面一共占多少字节(设置页「动态封面缓存」那一行)。在后台量,不占主线程。
    func diskUsage() async -> Int64 {
        let dir = directory
        return await Task.detached(priority: .utility) { Self.measure(dir) }.value
    }

    /// 清掉已下载的动态封面,返回清完还剩多少字节。
    ///
    /// `keeping` 那一份(歌词窗口此刻正在播的)留着:删了它画面会断,下一次刷新又会把它原样下回来。
    /// 正在下的那几份下完照常落盘,不拦。
    func removeAllCached(keeping: URL?) async -> Int64 {
        let dir = directory
        let keep = keeping?.standardizedFileURL.path
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            var removed = 0
            for url in items where ["mp4", "tmp"].contains(url.pathExtension) && url.standardizedFileURL.path != keep {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
            logger.info("motion cover: cleared \(removed, privacy: .public) files")
            return Self.measure(dir)
        }.value
    }

    private nonisolated static func measure(_ dir: URL) -> Int64 {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.reduce(0) { sum, url in
            guard url.pathExtension == "mp4" else { return sum }
            return sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// 超预算就按 mtime 从旧到新删,删到预算之下。
    private func pruneIfNeeded() {
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        // 老版本落盘时先写 `<key>.mp4.tmp` 再改名,中途失败会留下这种孤儿,预算只数 mp4、永远删不到它们。
        for url in items where url.pathExtension == "tmp" {
            try? fm.removeItem(at: url)
        }
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
