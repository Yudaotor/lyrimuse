import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.chenyuhao.applemusic-desktop-lyrics", category: "network")

// 协调网络轮询(可见15s/隐藏60s,照顾同一个免费 Worker/KV 现在要服务网页+这个 App 两个
// 独立公开客户端)+ 本地20Hz快速tick(进度外推+歌词同步)。UI 只需订阅这几个 @Published
// 属性,不用关心轮询/外推的细节。
@MainActor
public final class RelayPoller: ObservableObject {
    public static let shared = RelayPoller(baseURL: "https://np.yudaotor.me")

    @Published public private(set) var title: String = ""
    @Published public private(set) var artist: String = ""
    @Published public private(set) var album: String = ""
    @Published public private(set) var artworkURLString: String?
    @Published public private(set) var isPlayingNow: Bool = false
    @Published public private(set) var currentLine: SyncedLyricLine?
    @Published public private(set) var nextLineText: String?

    // 是否优先用逐字(yrc)高亮——由设置面板控制(desktop-lyrics 应用层的 AppSettings),
    // 关掉后只用整行高亮。改这个值会用最近一次拿到的状态立刻重新加载,不用等下一首歌。
    @Published public var preferWordLevelKaraoke: Bool = true {
        didSet { reloadCurrentLyrics() }
    }

    private var client: NowPlayingClient
    private let syncEngine = LyricsSyncEngine()
    // 公开给 View 层——逐字填色现在按渲染帧频(TimelineView)从这个锚点直接外推真实
    // 播放位置现算,不再靠这里的 20Hz tick 把预算好的 fillFraction 塞进 currentLine。
    @Published public private(set) var anchor: ProgressAnchor?
    private var lastKey = ""
    private var lastState: NowPlayingState?

    private var pollTimer: Timer?
    private var fastTimer: Timer?
    private var isOverlayVisible = true

    public init(baseURL: String) {
        client = NowPlayingClient(baseURL: baseURL)
    }

    // 设置面板改了 relay 域名时调用;重建内部 client,不用重启整个 App。
    public func updateBaseURL(_ baseURL: String) {
        client = NowPlayingClient(baseURL: baseURL)
    }

    public func start() {
        reschedulePollTimer()
        startFastTimer()
        poll()
    }

    // 切到本地数据源时调用,让这个源彻底停下来,不在后台空转白耗网络/KV配额。
    public func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        fastTimer?.invalidate(); fastTimer = nil
    }

    // 悬浮窗隐藏时不需要20Hz的逐字同步(没人看),网络轮询也退到60s只保活菜单里的
    // "最近曲目"文本;重新显示时立刻补一次轮询,不用等下一个周期。
    public func setOverlayVisible(_ visible: Bool) {
        guard visible != isOverlayVisible else { return }
        isOverlayVisible = visible
        reschedulePollTimer()
        if visible {
            startFastTimer()
            poll()
        } else {
            fastTimer?.invalidate()
            fastTimer = nil
        }
    }

    private func reschedulePollTimer() {
        pollTimer?.invalidate()
        let interval: TimeInterval = isOverlayVisible ? 15 : 60
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func startFastTimer() {
        fastTimer?.invalidate()
        // 20Hz;必须挂 .common mode(不是默认 mode),否则用户点开菜单/拖拽悬浮窗时
        // (进入 .eventTracking mode)这个 tick 会停摆,看起来像卡死。
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await self.client.fetchNow()
                let fetchedAt = Date()
                logger.debug("poll ok: playing=\(state.playing == true) source=\(state.source ?? "nil", privacy: .public)")
                await MainActor.run { self.apply(state, fetchedAt: fetchedAt) }
            } catch {
                // 轮询失败(relay挂了/网络抖动):保留上次显示,不清空,下一轮再试——
                // 跟网页版 tick() 遇到 fetchState() 失败时"保留当前显示不清屏"是同一思路。
                logger.error("poll failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func apply(_ state: NowPlayingState, fetchedAt: Date) {
        lastState = state
        title = state.title ?? ""
        artist = state.artist ?? ""
        album = state.album ?? ""
        artworkURLString = state.artwork
        isPlayingNow = state.playing == true

        // 换歌就重载;没换歌但目前还没解析出任何歌词内容也要重载——采集器换歌那一刻的
        // enrich(网易云/QQ 解析)经常还没跑完,第一次轮询可能拿到空歌词字段,如果只在
        // "换歌"那一次机会重载,后面同一首歌永远不会再重试,会卡死在"这首歌没歌词"的
        // 误判上(实测坐实:方大同《玩乐 (Live)》——网页版 10s 后再轮询就补上了,这个 App
        // 15s 轮询间隔一样的接口却一直显示空,因为只在换歌那一次调用重载)。跟网页版
        // setLyrics() 的 `!sameTrack || !lrcLines.length` 判据是同一个逻辑。
        let key = state.trackKey
        if key != lastKey || !syncEngine.hasContent {
            if key != lastKey {
                logger.info("track changed: \(state.artist ?? "", privacy: .public) - \(state.title ?? "", privacy: .public)")
            }
            lastKey = key
            reloadCurrentLyrics()
        }
        anchor = ProgressAnchor.from(state, fetchedAt: fetchedAt)
        if anchor == nil { currentLine = nil; nextLineText = nil }
    }

    // 供外部(EnrichCacheStore 保存/删除歌词后)强制立刻重新轮询一次——跟
    // LocalPlaybackSource.forceReloadLyricsForCurrentTrack() 同样的诉求,但 relay 模式
    // 靠网络轮询、内容缓存在 lastState 里,得真的发一次新请求才能拿到 collector 重启后
    // 的最新内容,不能只是重跑 reloadCurrentLyrics()(那只会用旧的 lastState 再解析
    // 一遍,等于没变)。
    public func forceRefetchNow() {
        poll()
    }

    private func reloadCurrentLyrics() {
        guard let state = lastState else { return }
        syncEngine.load(
            lyrics: state.lyrics ?? "",
            lyricsTr: state.lyricsTr ?? "",
            lyricsRoma: state.lyricsRoma ?? "",
            lyricsYRC: state.lyricsYRC ?? "",
            preferWordLevel: preferWordLevelKaraoke
        )
        // 只记字符数,不记歌词原文——校验解析是否真的产出了内容,不泄露歌词文本。
        logger.debug("lyrics reloaded: hasContent=\(self.syncEngine.hasContent) lyricsLen=\((state.lyrics ?? "").count) yrcLen=\((state.lyricsYRC ?? "").count)")
    }
}
