import AVFoundation
import CryptoKit
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "motion-cover")

/// 动态封面的**下载与落盘**:Apple Music 的(HLS master),以及 QQ 音乐的专辑动态封面(`qqmv:<vid>`)、网易云的歌曲动态封面
/// (`ncmv:<歌曲 id>`),后两种下载时现换 mp4 地址(见 `QQMotionCover`、`NeteaseMotionCover`);酷狗的(`kgmv:<专辑 id>`)
/// 读引擎从酷狗本机拷过来的那份(`KugouMotionCover`)。
///
/// 分工:发现在引擎(`motioncover.go`、`motioncoverqq.go`,把地址记进 enrich 缓存)、清单推导在 Core
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
    /// 终审过了的 (key, 参照图) 组合:盘上那份再跟同一张参照图比时不再解帧。
    private var referencePassed: Set<String> = []
    /// 网络层失败(断网、超时、5xx / 429)的 key → 退避到什么时候、连着失败了几次。退避期间不再下;每连着失败一次
    /// 翻一倍(2、4、8… 分钟,最多 30 分钟),下成一次就清掉。不落盘,同 `failed`。
    private var transientBackoff: [String: (until: Date, failures: Int)] = [:]

    /// 下载、取清单用的会话:不进 `URLCache.shared`。mp4 已经自己落盘一份,再进共享缓存会把静态高清封面挤出去。
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private var directory: URL { LyrimusePaths.cacheFile("motion-covers") }

    /// 旧版本放在配置目录下,第一次用到时搬过来(`CacheRelocation`)。
    private init() {
        let outcome = CacheRelocation.move(from: LyrimusePaths.configFile("motion-covers"),
                                           to: LyrimusePaths.cacheFile("motion-covers"), extensions: ["mp4", "tmp"])
        if outcome != CacheRelocation.Outcome() {
            logger.info("motion cover: relocated cache, moved \(outcome.moved, privacy: .public) dropped \(outcome.dropped, privacy: .public) old dir removed \(outcome.removedOldDirectory, privacy: .public)")
        }
    }

    // MARK: - 对外

    /// 已经在盘上的那份;没有就 nil(调用方据此决定要不要 `prepare`)。
    func cachedFile(master: URL) -> URL? {
        let url = fileURL(for: master)
        guard fm.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    /// 取这张专辑的动态封面本地文件:盘上有就跟参照图比一次再给(`checkCached`),没有就下一份。
    ///
    /// 幂等 —— 同一个 master 并发调多次只会真下一次。失败返回 nil 且这一次运行里不再重试
    /// (见 `failed`)。**任何一步失败都只是"这首没有动态封面"**,不往上抛错(理由见
    /// `MotionCoverManifest` 头注最后一段:这是在解析公开网页里的非公开字段,必须优雅失效)。
    ///
    /// - Parameter reference: 当前显示的那张封面的 `CoverFingerprint.Reference`。下载完成后
    ///   会拿视频**中段**的真实一帧跟它比一次,理由见 `verifyMatchesReference` 的注释。传
    ///   nil(拿不到当前封面,比如刚换歌那一瞬)就跳过这道终审,不因为一时缺参照而白白拒了。
    func prepare(master: URL, reference: CoverFingerprint.Reference?) async -> URL? {
        let key = cacheKey(for: master)
        if let hit = cachedFile(master: master) {
            guard let reference else { return hit }
            return await checkCached(hit, master: master, key: key, reference: reference)
        }
        if failed.contains(key) { return nil }
        if let backoff = transientBackoff[key], backoff.until > Date() { return nil }
        // 同一份参照图上次就没过终审,不必再下一遍那几 MB;参照图一换就是新组合,自然重试。
        if let reference, referenceRejected.contains(Self.rejectionKey(key, reference)) { return nil }
        if let running = inflight[key] {
            let result = await running.task.value
            // 在跑的那一轮拿的是另一张参照图(换歌那一刻参照图还是上一首的,或者那一轮没带参照图):资源下好了就在盘上
            // (终审没过也落盘),按这一张再比一次;没下成就认这个结果。参照图相同也认。
            guard let reference, running.reference != reference else { return result }
            if let hit = cachedFile(master: master) {
                return await checkCached(hit, master: master, key: key, reference: reference)
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
                    self.transientBackoff[key] = nil
                    if let reference {
                        self.referencePassed.insert(Self.rejectionKey(key, reference))
                    }
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
                    // 断网、超时这类:这一次没下成,退避一阵再试,不记进 failed(那会封到进程重启)。
                    let failures = (self.transientBackoff[key]?.failures ?? 0) + 1
                    let delay = min(120.0 * Double(1 << min(failures - 1, 4)), 1800)
                    self.transientBackoff[key] = (Date().addingTimeInterval(delay), failures)
                    return nil
                }
            }
        }
        inflight[key] = (task, reference)
        return await task.value
    }

    /// 盘上那份跟参照图比一次:视频中段那一帧,同下载时的终审(`verifyMatchesReference`)。动画只叠在跟它是同一张图的封面上,
    /// 盘上的那份是对着别的封面下的(同一张专辑在别的条目上、引擎后来换了这条的封面)也得比。结果按 (资源, 参照图) 记着。
    private func checkCached(_ file: URL, master: URL, key: String, reference: CoverFingerprint.Reference) async -> URL? {
        let pair = Self.rejectionKey(key, reference)
        if referencePassed.contains(pair) { return file }
        if referenceRejected.contains(pair) { return nil }
        switch await Self.verifyMatchesReference(file, reference: reference, firstFrameToo: Self.comparesFirstFrameToo(master)) {
        case .pass:
            referencePassed.insert(pair)
            return file
        case .mismatch:
            referenceRejected.insert(pair)
            return nil
        case .undecidable:
            // 读不出时长、解不出帧:盘上这份坏了(换张参照图也救不回来)。删掉,下次换到这张专辑重下一份;
            // 重下的那份还解不出帧,下载那一步就记进 failed。
            logger.notice("motion cover: cached file undecodable, removing")
            try? fm.removeItem(at: file)
            return nil
        }
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
        if let vid = QQMotionCover.vid(from: master) {
            return await downloadQQ(vid: vid, master: master, reference: reference)
        }
        if let songID = NeteaseMotionCover.songID(from: master) {
            return await downloadNetease(songID: songID, master: master, reference: reference)
        }
        if let albumID = KugouMotionCover.albumID(from: master) {
            return await loadKugou(albumID: albumID, master: master, reference: reference)
        }
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

    /// QQ 音乐的专辑动态封面:先换 mp4 地址(带签名、几小时就过期,所以每次现换),按清晰度逐档试,同 HLS 那条一样最多 3 条。
    /// 换地址没问成按网络层失败算(退避后再试);问成了一档都没有算资源取不到。
    private nonisolated func downloadQQ(vid: String, master: URL, reference: CoverFingerprint.Reference?) async -> DownloadOutcome {
        guard let urls = await QQMotionCover.fetchCandidates(vid: vid, targetWidth: Self.targetPixelWidth,
                                                            session: Self.session) else {
            logger.notice("motion cover: qq video urls not answered")
            return .transient
        }
        var sawTransient = false
        for url in urls.prefix(Self.maxCandidateAttempts) {
            switch await fetchMedia(url, master: master, reference: reference, label: "qq") {
            case .ready(let file): return .ready(file)
            case .referenceMismatch: return .referenceMismatch
            case .transient: sawTransient = true
            case .unavailable: continue
            }
        }
        return sawTransient ? .transient : .unavailable
    }

    /// 网易云的歌曲动态封面:带游客身份换 mp4 地址(带签名、约半小时过期,所以每次现换),只有一档。没问成(网络、没有游客身份)
    /// 按网络层失败算,问成了没有算资源取不到。
    private nonisolated func downloadNetease(songID: String, master: URL,
                                             reference: CoverFingerprint.Reference?) async -> DownloadOutcome {
        switch await NeteaseGuestSession.shared.lookup(songID: songID, session: Self.session) {
        case .video(let url):
            return await fetchMedia(url, master: master, reference: reference, label: "netease")
        case .none:
            return .unavailable
        case .loggedOut, .failed:
            logger.notice("motion cover: netease video url not answered")
            return .transient
        }
    }

    /// 酷狗的专辑动态封面:引擎从酷狗本机拷过来的那份,直接读文件。读不到(被删旧的删掉了,引擎下次播到时再拷)按资源取不到算。
    private nonisolated func loadKugou(albumID: String, master: URL,
                                       reference: CoverFingerprint.Reference?) async -> DownloadOutcome {
        guard let data = FileIO.read(KugouMotionCover.stagedFile(albumID: albumID)) else {
            logger.notice("motion cover: kugou local video unreadable")
            return .unavailable
        }
        return await storeMedia(data, master: master, reference: reference, label: "kugou")
    }

    /// 下一条候选:variant 清单 → 承载全部分片的单文件,再交给 `fetchMedia`。
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
            return await fetchMedia(mediaURL, master: master, reference: reference, label: "\(picked.width)px \(codec)")
        } catch {
            logger.notice("motion cover: \(codec, privacy: .public) variant fetch failed — \(error.localizedDescription, privacy: .public)")
            return error is URLError ? .transient : .unavailable
        }
    }

    /// 一个 mp4 → 整份下下来,交给 `storeMedia`。`label` 只进日志。
    private nonisolated func fetchMedia(_ mediaURL: URL, master: URL, reference: CoverFingerprint.Reference?,
                                        label codec: String) async -> DownloadOutcome {
        do {
            // ③ 整份下下来。
            let (data, response) = try await Self.session.data(from: mediaURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.notice("motion cover: \(codec, privacy: .public) media http \(http.statusCode, privacy: .public)")
                return http.statusCode == 429 || http.statusCode >= 500 ? .transient : .unavailable
            }
            return await storeMedia(data, master: master, reference: reference, label: codec)
        } catch {
            logger.notice("motion cover: \(codec, privacy: .public) fetch failed — \(error.localizedDescription, privacy: .public)")
            return error is URLError ? .transient : .unavailable
        }
    }

    /// 一份 mp4 → 临时文件 → 终审(或至少解得出帧)→ 落盘(按 master 定文件名)。先落到临时文件:终审(④)要用 AVAsset 读它,
    /// 得是个真实文件路径,不是内存里的 Data。落地在系统临时目录,不是最终缓存位置:没通过终审就地删掉,通过了再原子改名搬进
    /// `directory`(⑤ store)。`label` 只进日志。
    private nonisolated func storeMedia(_ data: Data, master: URL, reference: CoverFingerprint.Reference?,
                                        label codec: String) async -> DownloadOutcome {
        do {
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
                switch await Self.verifyMatchesReference(scratch, reference: reference,
                                                         firstFrameToo: Self.comparesFirstFrameToo(master)) {
                case .pass: break
                case .mismatch:
                    // 资源本身没问题,是此刻拿来比的封面不对(换歌那几秒参照图还是上一首的):照样落盘,等封面到了
                    // 由 checkCached 按新参照图比,不必再下一遍。
                    let final = await MainActor.run { self.fileURL(for: master) }
                    try Self.moveIntoPlace(scratch, final: final)
                    await MainActor.run { self.pruneIfNeeded() }
                    return .referenceMismatch
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
            logger.info("motion cover: stored \(codec, privacy: .public) \(data.count / 1024, privacy: .public)KB")
            await MainActor.run { self.pruneIfNeeded() }
            return .ready(final)
        } catch {
            logger.notice("motion cover: \(codec, privacy: .public) store failed — \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    /// 第一帧解不解得出来。
    private nonisolated static func decodesAFrame(_ file: URL) async -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        return (try? await generator.image(at: .zero).image) != nil
    }

    /// **终审**:视频**中段**(时长过半)的真实一帧,跟当前显示的封面是不是同一张。
    ///
    /// 为什么不能只信引擎那边(`motioncover.go` 的 `motionCoverMatchesCover`):它比的
    /// 是 Apple 给的 `previewFrame`,而那常常就是视频**最开头**一帧。有些专辑的动态封面开场
    /// 是"揭幕"特效——实测 Ariana Grande《Positions (Deluxe)》,首帧是逐渐聚拢的九宫格拼贴,
    /// 跟静态封面的感知距离高达 41(阈值 12 的好几倍),播到视频过半时才收拢成跟静态封面
    /// 逐位相同的画面(距离 0)。引擎拿不到解码后的视频帧,只能在 previewFrame 上打转;
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

    ///
    /// `firstFrameToo`:中段帧对不上时再比第一帧,两帧有一帧对上就算(网易云那种,见 `comparesFirstFrameToo`)。
    private nonisolated static func verifyMatchesReference(
        _ file: URL, reference: CoverFingerprint.Reference, firstFrameToo: Bool = false
    ) async -> VerifyResult {
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return .undecidable }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        var closest = Int.max
        for fraction in firstFrameToo ? [0.5, 0] : [0.5] {
            let instant = CMTime(seconds: duration.seconds * fraction, preferredTimescale: duration.timescale)
            guard let raw = try? await generator.image(at: instant).image else { return .undecidable }
            // 竖幅的(QQ、酷狗动态封面)比中间那块正方形:卡上铺满裁中间,能看到的就是它。
            let (distance, same) = CoverFingerprint.matches(CoverFingerprint.centerSquare(raw), reference: reference)
            if same { return .pass }
            closest = min(closest, distance)
        }
        logger.notice("motion cover: video frame distance \(closest, privacy: .public), skipping")
        return .mismatch
    }

    /// 网易云的动态封面中段帧对不上时再比第一帧:它的正式动画常是首尾两帧就是封面、中间换成别的画面;酷狗的同理(动画常在中段
    /// 推近)。Apple 的照旧只比中段帧(它的片头常有揭幕特效,第一帧跟封面不像)。
    private nonisolated static func comparesFirstFrameToo(_ master: URL) -> Bool {
        NeteaseMotionCover.songID(from: master) != nil || KugouMotionCover.albumID(from: master) != nil
    }

    /// 清单正文。429 / 5xx 抛 `URLError`(调用方按网络层失败、退避重试),别的非 200 按资源取不到。
    private nonisolated func text(from url: URL) async throws -> String {
        let (data, response) = try await Self.session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 429 || http.statusCode >= 500 { throw URLError(.badServerResponse) }
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

/// 动态封面此刻有没有地方要显示:歌词窗口完整布局的封面卡在屏上,或副屏网页歌词有人在看。都没有就不下载、不取帧
/// (`PlaybackCoordinator.refreshMotionCover`);有了(封面卡出现、网页开始有人看)再刷新一次。
@MainActor
enum MotionCoverDemand {
    static let changed = Notification.Name("MotionCoverDemand.changed")
    private static var cardsShown = 0

    static var wanted: Bool { cardsShown > 0 || WebLyricsServer.screen.viewerCount > 0 }
    /// 歌词窗口完整尺寸那张封面卡在屏上(Spotify Canvas 背景只在这时下载、播放)。
    static var cardShown: Bool { cardsShown > 0 }

    static func cardAppeared() {
        cardsShown += 1
        if cardsShown == 1 { NotificationCenter.default.post(name: changed, object: nil) }
    }

    static func cardDisappeared() {
        cardsShown = max(0, cardsShown - 1)
    }
}
