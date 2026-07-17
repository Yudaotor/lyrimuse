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
    // 是否尝试用 AppleMusicPositionClient(需要"自动化"系统权限)问 Music.app 要精确
    // 播放位置——App 层(AppSettings.preciseAppleMusicPosition)推值进来,这里不直接
    // 依赖 AppSettings(DesktopLyricsCore 是纯逻辑 library,不该反过来依赖 App target),
    // 照抄 preferWordLevelKaraoke 同一个"App 层推值"的既有模式。关掉时直接跳过这次
    // 尝试,等同于"这次调用失败了",走 poll() 里现成的 media-control 估算进度回退。
    public var preciseAppleMusicPosition: Bool = true

    private let syncEngine = LyricsSyncEngine()
    // 公开给 View 层——逐字填色现在按渲染帧频(TimelineView)从这个锚点直接外推真实
    // 播放位置现算,不再靠这里的 20Hz tick 把预算好的 fillFraction 塞进 currentLine。
    @Published public private(set) var anchor: ProgressAnchor?
    private var lastKey = ""
    private var lastSnapshot: MediaControlSnapshot?

    private var pollTimer: Timer?
    private var fastTimer: Timer?

    private init() {}

    public func start() {
        reschedulePollTimer()
        // 快速 tick 不在这里无条件启动——是否需要它取决于第一次 poll() 拿到的播放
        // 状态,交给 apply() 里的 ensureFastTimerRunning()/stopFastTimer() 决定。
        poll()
    }

    public func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        stopFastTimer()
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

    // 只在真的需要时(anchor 非 nil,即正在播放)才保持 20Hz 快速 tick 运行——暂停/
    // 长时间挂起时没有锚点可外推,tick 只会一遍遍把 currentLine/nextLineText 置 nil,
    // 没必要让计时器继续空转。用 fastTimer == nil 判断"已经在跑了"而不是每次 apply()
    // 都无条件重建,避免播放中每 2 秒(poll 周期)就重开一次计时器。
    private func ensureFastTimerRunning() {
        guard fastTimer == nil else { return }
        // 20Hz;必须挂 .common mode,理由跟 RelayPoller 一致(菜单打开/拖拽悬浮窗时
        // 不能停摆)。
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fastTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        fastTimer = t
    }

    private func stopFastTimer() {
        fastTimer?.invalidate()
        fastTimer = nil
    }

    private func fastTick() {
        guard let anchor else {
            if currentLine != nil { currentLine = nil }
            if nextLineText != nil { nextLineText = nil }
            return
        }
        let pos = anchor.extrapolatedPositionMs()
        // 只在真的换了行/换了下一句预览时才赋值——这两个是 @Published,SwiftUI 不管
        // 新旧值是否相等,只要赋值就会通知订阅者重新渲染。逐字填色早已经交给
        // TimelineView 按渲染帧频现算(不经过这两个属性),这里 20Hz 只是为了"判断当前
        // 该显示哪一行",绝大多数 tick 其实还是同一行——之前无条件赋值导致悬浮窗所在的
        // LyricsOverlayView(以及任何订阅 PlaybackCoordinator 的其它 View,比如"歌词
        // 管理"窗口)整个 body 跟着每秒重算 20 次,是播放期间持续感觉卡顿的根因之一。
        let newLine = syncEngine.activeLine(atMs: pos)
        if newLine != currentLine { currentLine = newLine }
        let newNext = syncEngine.upcomingLineText(afterMs: pos)
        if newNext != nextLineText { nextLineText = newNext }
    }

    private func poll() {
        // 两个都是同步阻塞调用(内部各自 fork 子进程等待退出),一起挪到后台线程跑,
        // 避免卡住主线程/UI。
        let wantsPrecisePosition = preciseAppleMusicPosition
        Task {
            let (snapshot, livePosition) = await Task.detached {
                (MediaControlClient.fetchSnapshot(), wantsPrecisePosition ? AppleMusicPositionClient.fetchPositionSeconds() : nil)
            }.value
            guard let snapshot else {
                // media-control 返回 nil 不只是"调用失败",更常见的是真的没有任何曲目在
                // 加载(比如 Music.app 处于 stopped 而不是 paused——paused 时 media-control
                // 仍会给一个 playing=false 的正常快照,只有"压根没曲目"才会是 nil)。这里
                // 之前只打日志就直接 return,不碰任何 @Published 状态——一旦从"正在播放"
                // 变成这种 nil 快照,isPlayingNow/currentLine 全部卡在停播前那一刻,状态栏
                // /悬浮窗会一直显示"还在播"的样子,不会自己恢复(2026-07-18 真机实测坐实:
                // 完全停止播放后状态栏歌词卡死不消失)。现在补上跟 apply() 里"暂停"分支
                // 完全一致的清理(anchor=nil 时清 currentLine/nextLineText+停快速计时器),
                // 只是多加了 isPlayingNow=false——title/artist/album 不清空,跟"暂停"时
                // 保留最近播放信息的既有行为保持一致。
                logger.error("snapshot failed (media-control 不可用或解析失败,或者没有曲目在播放)")
                if isPlayingNow {
                    isPlayingNow = false
                    anchor = nil
                    currentLine = nil
                    nextLineText = nil
                    stopFastTimer()
                }
                return
            }
            logger.debug("snapshot ok: playing=\(snapshot.playing == true) livePos=\(livePosition != nil)")
            self.apply(snapshot, livePositionSeconds: livePosition)
        }
    }

    private func apply(_ snapshot: MediaControlSnapshot, livePositionSeconds: Double?) {
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

        // media-control 的 elapsedTime 在稳定播放期间会整段冻结不动(实测坐实:同一个值
        // 连续多次轮询、跨越十几秒真实时间也不变),如果直接拿它当"这一刻的准确位置"、
        // 每次轮询都重新锚定,外推出来的进度会一直卡在轨道刚开始播放的那个点附近,歌词
        // 表现为"卡死在最前面不动、好像没有歌词"。改用 AppleMusicPositionClient(问
        // Music.app 本身要实时位置,精确到 ~0.1s,不会冻结)优先,media-control 的
        // elapsedTime 只在拿不到(比如没在放 Apple Music)时兜底。
        if snapshot.playing == true, let duration = snapshot.duration, duration > 0 {
            let positionSeconds = livePositionSeconds ?? snapshot.elapsedTime ?? 0
            anchor = ProgressAnchor(
                durationMs: Int(duration * 1000),
                progressMs: Int(positionSeconds * 1000),
                rate: snapshot.playbackRate ?? 1,
                progressTs: nil,
                baseAgeMs: 0, // 本机直接读取,没有网络延迟需要外推的锚点年龄
                fetchedAt: Date(),
                fresh: true // 本地读取,始终当作新鲜锚点,不封顶外推
            )
        } else {
            anchor = nil
        }
        if anchor == nil {
            currentLine = nil
            nextLineText = nil
            stopFastTimer()
        } else {
            ensureFastTimerRunning()
        }
    }

    // 供外部(EnrichCacheStore 保存/删除歌词后)强制重新读取当前曲目的歌词——正常情况
    // apply() 只在换歌那一刻才 reloadCurrentLyrics(),同一首歌播放中途改了缓存内容
    // 不会自动重新读。本地模式的 EnrichCacheReader 每次都是直接读磁盘文件,写完盘立刻
    // 调用这个就能拿到最新内容,不需要等 collector 重启。
    public func forceReloadLyricsForCurrentTrack() {
        reloadCurrentLyrics()
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
