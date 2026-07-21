import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.chenyuhao.lyrimuse", category: "local")

// 本地播放数据源:音乐本来就在这台 Mac 上放,没道理还要绕一圈公网——播放位置/进度靠
// AppleScript 本地轮询问 Music.app 本身要(零网络、零延迟,见 MediaControlClient.swift
// 顶部注释——2026-07-21 起从依赖外部 `media-control` 换成了这个),歌词靠读 collector
// 已经解析好、写在磁盘上的那份缓存(同样零网络)。2026-07-20 起是唯一的数据源(原本
// 还有一个远程 relay 数据源、跟这个二选一,已删除——见 PlaybackCoordinator.start())。
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
        // 20Hz;必须挂 .common mode,否则菜单打开/拖拽悬浮窗时会停摆。
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

    // nil 快照(真的没有任何曲目在加载)和"有曲目但不是 Apple Music"共用同一套清理——
    // title/artist/album 故意不清空,保留"最近一次 Apple Music 播放"这份信息,跟原有
    // "暂停"分支的既有行为一致,见两处调用点各自的注释。
    private func clearIfWasPlaying() {
        if isPlayingNow {
            isPlayingNow = false
            anchor = nil
            currentLine = nil
            nextLineText = nil
            stopFastTimer()
        }
    }

    private func poll() {
        // 同步阻塞调用(内部 fork 子进程等待退出),挪到后台线程跑,避免卡住主线程/UI。
        Task {
            let snapshot = await Task.detached {
                MediaControlClient.fetchSnapshot()
            }.value
            guard let snapshot else {
                // 返回 nil 不只是"调用失败"(比如没有"自动化"权限),更常见的是真的没有
                // 任何曲目在加载(比如 Music.app 处于 stopped 而不是 paused——paused 时
                // 仍会给一个 playing=false 的正常快照,只有"压根没曲目"才会是 nil)。这里
                // 之前只打日志就直接 return,不碰任何 @Published 状态——一旦从"正在播放"
                // 变成这种 nil 快照,isPlayingNow/currentLine 全部卡在停播前那一刻,状态栏
                // /悬浮窗会一直显示"还在播"的样子,不会自己恢复(2026-07-18 真机实测坐实:
                // 完全停止播放后状态栏歌词卡死不消失)。现在补上跟 apply() 里"暂停"分支
                // 完全一致的清理(anchor=nil 时清 currentLine/nextLineText+停快速计时器),
                // 只是多加了 isPlayingNow=false——title/artist/album 不清空,跟"暂停"时
                // 保留最近播放信息的既有行为保持一致。
                logger.error("snapshot failed (没有自动化权限、Music.app 不在运行，或者没有曲目在播放)")
                clearIfWasPlaying()
                return
            }
            // isMusicApp 现在直接由 MediaControlClient 硬编码为 true(只在真的问到
            // Music.app 自己的当前曲目时才会返回非 nil 快照,不再是系统级 Now Playing
            // 焦点判断)——这个 guard 留着只是保持跟旧版同一套代码路径,不删这一步的
            // 保险性质。
            guard snapshot.isMusicApp == true else {
                logger.debug("snapshot ignored: not Apple Music (isMusicApp=\(String(describing: snapshot.isMusicApp)))")
                clearIfWasPlaying()
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

        // elapsedTime 现在就是 Music.app 自己实时算出来的播放位置(MediaControlClient
        // 直接问 Music.app 要,不是旧版 media-control 那种会在稳定播放期间整段冻结不动
        // 的估算值),不需要再额外问一次、也不需要区分"精确"和"估算"两条路径。
        if snapshot.playing == true, let duration = snapshot.duration, duration > 0 {
            let positionSeconds = snapshot.elapsedTime ?? 0
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

    // 单曲歌词时间轴微调——只对"当前正在播的这首歌"生效,立即体现在下一次 fastTick()
    // 里(不等换歌/下次轮询)。没有任何曲目信息(currentOffsetKey 还是空)时静默什么都
    // 不做,不会把校正值存进一个毫无意义的空 key 下面。
    @discardableResult
    public func nudgeLyricsOffset(by deltaMs: Int) -> Int {
        guard lastSnapshot != nil else { return syncEngine.offsetMs }
        let newValue = LyricsOffsetStore.shared.nudge(by: deltaMs, forKey: currentOffsetKey)
        syncEngine.offsetMs = newValue
        return newValue
    }

    public func resetLyricsOffset() {
        guard lastSnapshot != nil else { return }
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey)
        syncEngine.offsetMs = 0
    }

    // 供"歌词管理"窗口的偏移输入框用——那边直接写 LyricsOffsetStore(不经过
    // nudge/reset,是敲一个具体数值),写完之后调这个让当前正在播的这首歌(如果编辑的
    // 恰好就是它)立刻用上新值,不用等下次换歌。跟别的歌词内容(key 对不上当前曲目)
    // 无关时,这里只是把 currentOffsetKey 对应的值重新读一遍、原样赋回去,是个安全的
    // 空操作。
    public func refreshOffsetFromStore() {
        guard lastSnapshot != nil else { return }
        syncEngine.offsetMs = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey)
    }

    // 跟 syncEngine 实际加载的歌词内容(lyrics+lyricsYRC)绑在一起算出来的 key——见
    // reloadCurrentLyrics() 里怎么算的。只在换歌词内容那一刻更新一次,nudge/reset 直接
    // 复用,不用每次都重新拼一遍(也保证跟当初读校正值时用的是同一个 key)。
    private var currentOffsetKey = ""

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
        currentOffsetKey = LyricsOffsetStore.trackKey(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            lyrics: found?.lyrics ?? "",
            lyricsYRC: found?.lyricsYRC ?? ""
        )
        syncEngine.offsetMs = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey)
        logger.debug("lyrics reloaded: hasContent=\(self.syncEngine.hasContent) found=\(found != nil)")
    }
}
