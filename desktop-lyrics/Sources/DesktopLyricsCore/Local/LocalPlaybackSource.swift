import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.chenyuhao.applemusic-desktop-lyrics", category: "local")

// 本地播放数据源:音乐本来就在这台 Mac 上放,没道理还要绕一圈公网——播放位置/进度靠
// `media-control get` 本地轮询拿(零网络、零延迟),歌词靠读 collector 已经解析好、
// 写在磁盘上的那份缓存(同样零网络)。形状照抄 RelayPoller,好让 PlaybackCoordinator
// 能用同一套 Combine 转发逻辑对接两个源。
@MainActor
public final class LocalPlaybackSource: ObservableObject {
    public static let shared = LocalPlaybackSource()

    @Published public private(set) var title: String = ""
    @Published public private(set) var artist: String = ""
    @Published public private(set) var album: String = ""
    @Published public private(set) var isPlayingNow: Bool = false
    @Published public private(set) var currentLine: SyncedLyricLine?
    @Published public private(set) var nextLineText: String?

    @Published public var preferWordLevelKaraoke: Bool = true {
        didSet { reloadCurrentLyrics() }
    }

    private let syncEngine = LyricsSyncEngine()
    private var anchor: ProgressAnchor?
    private var lastKey = ""
    private var lastSnapshot: MediaControlSnapshot?

    private var pollTimer: Timer?
    private var fastTimer: Timer?

    private init() {}

    public func start() {
        reschedulePollTimer()
        startFastTimer()
        poll()
    }

    public func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        fastTimer?.invalidate(); fastTimer = nil
    }

    private func reschedulePollTimer() {
        pollTimer?.invalidate()
        // 本地读取开销可忽略,不用像远程模式那样顾虑限流/免费额度,2秒一次足够"实时"
        // 又不至于无意义地频繁 fork 子进程。
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func startFastTimer() {
        fastTimer?.invalidate()
        // 20Hz;必须挂 .common mode,理由跟 RelayPoller 一致(菜单打开/拖拽悬浮窗时
        // 不能停摆)。
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fastTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        fastTimer = t
    }

    private func fastTick() {
        guard let anchor else { currentLine = nil; nextLineText = nil; return }
        let pos = anchor.extrapolatedPositionMs()
        currentLine = syncEngine.activeLine(atMs: pos)
        nextLineText = syncEngine.upcomingLineText(afterMs: pos)
    }

    private func poll() {
        // MediaControlClient.fetchSnapshot() 是同步阻塞调用(内部 fork 子进程等待退出),
        // 挪到后台线程跑,避免卡住主线程/UI。
        Task {
            let snapshot = await Task.detached { MediaControlClient.fetchSnapshot() }.value
            guard let snapshot else {
                logger.error("snapshot failed (media-control 不可用或解析失败)")
                return
            }
            logger.debug("snapshot ok: playing=\(snapshot.playing == true)")
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: MediaControlSnapshot) {
        lastSnapshot = snapshot
        title = snapshot.title ?? ""
        artist = snapshot.artist ?? ""
        album = snapshot.album ?? ""
        isPlayingNow = snapshot.playing == true

        let key = snapshot.trackKey
        if key != lastKey || !syncEngine.hasContent {
            if key != lastKey {
                logger.info("track changed: \(snapshot.artist ?? "", privacy: .public) - \(snapshot.title ?? "", privacy: .public)")
            }
            lastKey = key
            reloadCurrentLyrics()
        }

        if snapshot.playing == true, let duration = snapshot.duration, duration > 0, let elapsed = snapshot.elapsedTime {
            anchor = ProgressAnchor(
                durationMs: Int(duration * 1000),
                progressMs: Int(elapsed * 1000),
                rate: snapshot.playbackRate ?? 1,
                progressTs: nil,
                baseAgeMs: 0, // 本机直接读取,没有网络延迟需要外推的锚点年龄
                fetchedAt: Date(),
                fresh: true // 本地读取,始终当作新鲜锚点,不封顶外推
            )
        } else {
            anchor = nil
        }
        if anchor == nil { currentLine = nil; nextLineText = nil }
    }

    private func reloadCurrentLyrics() {
        guard let snapshot = lastSnapshot else { return }
        let found = EnrichCacheReader.lookup(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            album: snapshot.album ?? ""
        )
        syncEngine.load(
            lyrics: found?.lyrics ?? "",
            lyricsTr: found?.lyricsTr ?? "",
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: found?.lyricsYRC ?? "",
            preferWordLevel: preferWordLevelKaraoke
        )
        logger.debug("lyrics reloaded: hasContent=\(self.syncEngine.hasContent) found=\(found != nil)")
    }
}
