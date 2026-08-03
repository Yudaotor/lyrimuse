import Foundation
import Combine
import CoreImage
import CoreGraphics
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "local")

// 本地播放数据源:音乐本来就在这台 Mac 上放,没道理还要绕一圈公网——播放位置/进度靠
// AppleScript 本地轮询问 Music.app 本身要(零网络、零延迟,见 MediaControlClient.swift),
// 歌词靠读 collector 已经解析好、写在磁盘上的那份缓存(同样零网络)。
@MainActor
public final class LocalPlaybackSource: ObservableObject {
    public static let shared = LocalPlaybackSource()

    @Published public private(set) var title: String = ""
    @Published public private(set) var artist: String = ""
    @Published public private(set) var album: String = ""
    @Published public private(set) var isPlayingNow: Bool = false
    @Published public private(set) var currentLine: SyncedLyricLine?
    @Published public private(set) var nextLineText: String?
    // "歌词窗口"(完整可滚动歌词列表)用——跟 currentLine/nextLineText 同一套 20Hz tick
    // 算出来,只在真的换了行时才重新赋值(见 fastTick())。allLines 换歌时才重新构造一次
    // (reloadCurrentLyrics()),不需要每 tick 重算——歌词内容本身在同一首歌播放期间不变。
    @Published public private(set) var currentLineIndex: Int?
    @Published public private(set) var allLines: [LyricsWindowLine] = []
    // 当前曲目是否已经解析出任何歌词内容(syncEngine.hasContent 的转发)——只用来跟
    // "currentLine 恰好是 nil"这种正常情况(整曲还没到第一句歌词、两句歌词间的空档)
    // 区分开。collector 对一首没见过的歌是异步解析的(见 collector/enrich.go
    // trackEnrichment),没解析完之前磁盘缓存里根本没有这个 key,reloadCurrentLyrics()
    // 只能拿到空字符串——这时 hasLyricsContent 为 false,UI 据此判断"这是还没解析出来"
    // 而不是"这首歌就是没歌词/正在间奏"。
    @Published public private(set) var hasLyricsContent: Bool = false
    // 联网查过了、至少一个源(目前是 lrclib)明确说这首歌是纯音乐——2026-08-03 补上,
    // 跟 hasLyricsContent 是两个不同维度:hasLyricsContent==false 本身分不清是"还没
    // 解析完"还是"解析完了但真没歌词",这个字段专门标记后一种情况里"有明确依据"的那
    // 一类(而不是"五个源都没搜到"这种更含糊、可能只是没搜对的情况)。UI 侧靠这个字段
    // 决定要不要显示"纯音乐"而不是笼统的占位符——见各 View 里 lyricContent/mainLine
    // 的分支顺序,这个判断必须排在"还在搜索中"那个分支之前,不然一首已经确认是纯音乐
    // 的歌会在播放期间一直卡在"搜索歌词中…"、永远不会显示出这个更准确的结论。
    @Published public private(set) var isCurrentTrackInstrumental: Bool = false
    // Spotify 广告插播——2026-08-03 补上:media-control 自己的文档确认广告播放时 album
    // 字段恒为空字符串,靠"当前是 Spotify 在报告 + album 为空"这个信号判断(见
    // apply() 里的计算);跟 isCurrentTrackInstrumental 同一个优先级问题,必须排在
    // "还在搜索中"分支前面——否则一段广告会在整段广告期间一直卡在"搜索歌词中…"
    // (广告的标题/歌手压根不会被写进歌词缓存,见 collector/enrich.go trackEnrichment
    // 的对应守卫,hasLyricsContent 永远拿不到内容)。
    @Published public private(set) var isCurrentTrackAdBreak: Bool = false
    // 当前曲目已生效的歌词时间轴校正值(毫秒)——跟 syncEngine.offsetMs 保持一致,供菜单栏
    // "歌词时间轴"菜单展示累计校准值/决定"重置"按钮是否显示用。2026-08-03 实测排查坐实:
    // 这里之前没有这个属性,PlaybackCoordinator 自己用 "\(artist)|\(title)" 现拼了一个跟
    // LyricsOffsetStore 实际存储用的 key(LyricsOffsetStore.trackKey,多拼了一段内容指纹)
    // 完全对不上的 key 去查询,导致查到的值永远是 0——用户点"提前"好几次,nudge 本身其实
    // 已经生效(syncEngine.offsetMs 真的改了、歌词显示也真的偏移了),但菜单标题/"重置"
    // 按钮永远没有任何反馈,看起来就像完全没生效。改成不重新拼 key、直接转发这里的
    // syncEngine.offsetMs 权威值,从根上消除"两处各自算 key、容易算歪"这个问题。
    @Published public private(set) var currentLyricsOffsetMs: Int = 0
    // "歌词窗口"背景用的模糊封面图——原始图片数据(JPEG/PNG),不是 NSImage:
    // LyrimuseCore 这一层刻意不引入 AppKit/SwiftUI(见 Package.swift 的单向依赖注释),
    // 解码成 NSImage/Image 交给 lyrimuse 主 App target 的 View 自己做。只在换歌那一刻
    // 异步取一次(见 apply()/fetchArtworkForCurrentTrack()),不是每 2 秒轮询的一部分。
    @Published public private(set) var artworkData: Data?
    // 从 artworkData 里算出来的单一平均色(十六进制 #RRGGBBAA)——供"跟随封面"外观模式
    // 用作悬浮歌词的动态高亮色。跟 artworkData 同一时刻算好、同一套 expectedKey 换歌
    // 校验(见 fetchArtworkForCurrentTrack()),不是每次渲染都现算。只存十六进制字符串
    // 不存 Color/NSColor——这一层刻意不引入 AppKit/SwiftUI(见 Package.swift 的单向
    // 依赖注释),转成 Color 交给 lyrimuse 主 App target(PlaybackCoordinator)做,跟
    // AppSettings 里所有颜色字段都是"存 hex、用的地方再转 Color"同一个既有模式。
    @Published public private(set) var artworkAccentHex: String?

    @Published public var preferWordLevelKaraoke: Bool = true {
        didSet { reloadCurrentLyrics() }
    }

    private let syncEngine = LyricsSyncEngine()
    // 公开给 View 层——逐字填色现在按渲染帧频(TimelineView)从这个锚点直接外推真实
    // 播放位置现算,不再靠这里的 20Hz tick 把预算好的 fillFraction 塞进 currentLine。
    @Published public private(set) var anchor: ProgressAnchor?
    private var lastKey = ""
    private var lastSnapshot: MediaControlSnapshot?

    // ---- 播放位置平滑(2026-07-24 加,修 QQ 音乐"歌词时间不准") --------------------
    //
    // QQ 音乐没有 AppleScript,elapsedTime 来自 media-control --now 的 elapsedTimeNow
    // 外推值(见 MediaControlClient.swift)——实测坐实:同一首歌连续轮询,单次读数相对
    // 真实经过的时间能有 ±1~1.5 秒的抖动(不是持续偏向一个方向,是每次独立采样各自的
    // 误差,推测是 QQ 音乐自己上报 Now Playing 信息给系统的节奏本来就不是每次都精确
    // 刷新)。Apple Music 走的 AppleScript player position 没有这个问题,精确到
    // ~0.1s。过去不管哪个播放器,每次轮询(2 秒一次)都无条件把这次读数直接当成新锚点
    // ——QQ 音乐下逐字歌词填色因此每 2 秒就带着这份噪声跳一下,肉眼可见"歌词时间不准"。
    //
    // 改成跟 collector/poller.go 的 updatePosition() 同一套思路:只在真的发生"不
    // 连续"(换歌、暂停⇄播放切换、或者这次读数跟"按上一次锚点+经过的真实时间外推"的
    // 预测值差太多,说明真的 seek/跳曲了)时才信任这次读数重新锚定;平稳播放期间改成
    // 按真实 wall-clock 经过的时间累加,不理会每次读数自身的抖动。这套逻辑对 Apple
    // Music 同样安全——它的读数本来就精确,预测值和读数几乎总是相差无几,不会触发"跟
    // 预测差太多"这个分支,实际观感跟改之前几乎一致。
    private var trackPosSeconds: Double = 0
    private var posTrackingKey = ""
    private var posWasPlaying = false
    private var posPrevWall: Date?
    private static let seekJumpToleranceSecs = 2.0

    // 调用方(apply())只在"这一轮确实在播放"时才会调用这个函数——暂停态不需要外推,
    // apply() 的 else 分支直接把 anchor 置 nil,不经过这里。
    //
    // 返回值除了外推出的秒数,还带一个 didReanchor:标记这次是不是真的发生了"不连续"
    // (换歌/刚恢复播放/第一次观察/真实 seek,即用了 reported 而不是 predicted)。
    // 调用方(apply())用这个标记判断"这次真的有必要重新构造 anchor 吗"——见那边注释。
    private func resolvePositionSeconds(reported: Double, rate: Double, key: String, now: Date) -> (seconds: Double, didReanchor: Bool) {
        guard key == posTrackingKey, posWasPlaying, let prevWall = posPrevWall else {
            // 换歌 / 刚从暂停恢复播放 / 第一次观察 → 没有可信的上一次锚点可外推,直接
            // 采用这次读数。
            trackPosSeconds = reported
            return (trackPosSeconds, true)
        }
        let gap = now.timeIntervalSince(prevWall)
        let predicted = trackPosSeconds + gap * rate
        let jumped = abs(reported - predicted) > Self.seekJumpToleranceSecs
        trackPosSeconds = jumped ? reported : predicted
        return (trackPosSeconds, jumped)
    }

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
            if currentLineIndex != nil { currentLineIndex = nil }
            return
        }
        let pos = anchor.extrapolatedPositionMs()
        // 只在真的换了行/换了下一句预览时才赋值——这两个是 @Published,SwiftUI 不管
        // 新旧值是否相等,只要赋值就会通知订阅者重新渲染。逐字填色已经交给
        // TimelineView 按渲染帧频现算(不经过这两个属性),这里 20Hz 只是为了判断当前
        // 该显示哪一行,绝大多数 tick 其实还是同一行——无条件赋值会让悬浮窗所在的
        // LyricsOverlayView(以及任何订阅 PlaybackCoordinator 的其它 View,比如"歌词
        // 管理"窗口)整个 body 跟着每秒重算 20 次,造成播放期间的卡顿。
        let newLine = syncEngine.activeLine(atMs: pos)
        if newLine != currentLine { currentLine = newLine }
        let newNext = syncEngine.upcomingLineText(afterMs: pos)
        if newNext != nextLineText { nextLineText = newNext }
        // "歌词窗口"滚动定位用,同样的"只在真的变化时才赋值"这条规则——理由跟上面
        // currentLine 一样,这里多算一次下标不是新开销(activeLine 和 activeLineIndex
        // 各自独立扫一遍数组,都是 O(行数),这个量级完全可以忽略)。
        let newIndex = syncEngine.activeLineIndex(atMs: pos)
        if newIndex != currentLineIndex { currentLineIndex = newIndex }
    }

    // nil 快照(真的没有任何曲目在加载)和"有曲目但不是 Apple Music"共用同一套清理——
    // title/artist/album 故意不清空,保留"最近一次 Apple Music 播放"这份信息,跟原有
    // "暂停"分支的既有行为一致,见两处调用点各自的注释。
    //
    // allLines/artworkData 这两个是 2026-08-02 补上的——之前漏清,导致播放彻底停止(不是
    // 暂停,是这两处调用点代表的"真的没有任何曲目在加载"/"当前不是 Apple Music 在报告")
    // 后,"歌词窗口"会无限期冻结显示停播前那首歌的完整歌词列表和封面模糊背景,直到下一次
    // 真正播放新曲目才会刷新——因为 LyricsWindowView 判断"有没有内容可展示"用的是
    // `allLines.isEmpty`,不清空这个数组,视图就没有任何理由切回"无歌词"占位态。
    private func clearIfWasPlaying() {
        if isPlayingNow {
            isPlayingNow = false
            anchor = nil
            currentLine = nil
            nextLineText = nil
            currentLineIndex = nil
            allLines = []
            artworkData = nil
            artworkAccentHex = nil
            stopFastTimer()
        }
    }

    // poll() 之间乱序完成的保护——2026-08-02 实测排查坐实:每次 Timer 触发都新起一个
    // Task,内部子进程调用(几十~上百毫秒,但权限弹窗/系统繁忙等情况下可能明显变慢)之间
    // 没有任何互斥,较早发起的一次如果比较晚发起的一次更慢完成,会在 apply() 里用一份
    // 过期快照覆盖掉刚刚已经生效的新快照,造成标题/歌词短暂跳回上一首歌。用单调递增的
    // 世代号标记"这是第几次发起的轮询",子进程返回后只在"没有更新的轮询已经发起过"时
    // 才继续走 apply()/clearIfWasPlaying()——跟 fetchArtworkForCurrentTrack() 已经用
    // expectedKey 做的事是同一个模式,只是这里换歌与否都要防护,不能用 trackKey 当
    // 世代标识。
    private var pollGeneration = 0

    private func poll() {
        pollGeneration += 1
        let generation = pollGeneration
        // 同步阻塞调用(内部 fork 子进程等待退出),挪到后台线程跑,避免卡住主线程/UI。
        Task {
            let snapshot = await Task.detached {
                MediaControlClient.fetchSnapshot()
            }.value
            guard generation == self.pollGeneration else {
                logger.debug("poll result discarded: stale generation (\(generation) vs \(self.pollGeneration))")
                return
            }
            guard let snapshot else {
                // 返回 nil 不只是"调用失败"(比如没有"自动化"权限),更常见的是真的没有
                // 任何曲目在加载(比如 Music.app 处于 stopped 而不是 paused——paused 时
                // 仍会给一个 playing=false 的正常快照,只有"压根没曲目"才会是 nil)。必须
                // 清理播放状态(anchor=nil 时清 currentLine/nextLineText+停快速计时器,
                // 加 isPlayingNow=false),否则从"正在播放"切到这种 nil 快照时,状态栏/
                // 悬浮窗会卡在停播前那一刻不会自己恢复;title/artist/album 不清空,跟
                // "暂停"时保留最近播放信息的既有行为保持一致。
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
        // title/artist/album/isPlayingNow 只在真的变化时才赋值——理由跟 fastTick() 里
        // currentLine/nextLineText/currentLineIndex 的既有注释完全一样:这几个都是
        // @Published,Combine 不管新旧值是否相等,只要赋值就会通知订阅者。同一首歌播放期间
        // 这四个字段每 2 秒轮询其实拿到的都是同一份值,无条件赋值会让"歌词窗口"(以及任何
        // 订阅 PlaybackCoordinator 的其它 View)的整个 body 跟着每 2 秒重算一次——2026-08-02
        // 实测排查坐实,这是"歌词窗口"封面模糊背景每 2 秒被重新解码+重新高斯模糊的根因
        // 之一(另一个是下面的 anchor,两处需要一起改才能真正消除这个重渲染)。
        let newTitle = snapshot.title ?? ""
        if newTitle != title { title = newTitle }
        let newArtist = snapshot.artist ?? ""
        if newArtist != artist { artist = newArtist }
        let newAlbum = snapshot.album ?? ""
        if newAlbum != album { album = newAlbum }
        let newIsPlayingNow = snapshot.playing == true
        if newIsPlayingNow != isPlayingNow { isPlayingNow = newIsPlayingNow }
        // Spotify 广告插播判断——只在确认这次快照真的来自 Spotify(bundleIdentifier 对
        // 得上)时才生效,QQ 音乐/网易云音乐/Apple Music 的正常曲目本来就该有专辑名,不
        // 会误伤;title 也要求非空,避免在完全没有有效数据的边界情况下误判。跟
        // collector/enrich.go trackEnrichment 里同一个信号、同一条判断逻辑,那边负责
        // 不把广告当成歌曲写入歌词缓存,这里负责让 UI 立刻显示正确的"广告中"而不是无限期
        // 卡在"搜索歌词中…"(因为广告的标题永远不会出现在歌词缓存里)。
        let newIsAdBreak = !newTitle.isEmpty
            && snapshot.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier
            && newAlbum.isEmpty
        if newIsAdBreak != isCurrentTrackAdBreak { isCurrentTrackAdBreak = newIsAdBreak }

        let key = snapshot.trackKey
        let trackChanged = key != lastKey
        if trackChanged || !syncEngine.hasContent {
            if trackChanged {
                logger.info("track changed: \(snapshot.artist ?? "", privacy: .public) - \(snapshot.title ?? "", privacy: .public)")
            }
            lastKey = key
            reloadCurrentLyrics()
        }
        if trackChanged {
            // 换歌那一刻立即清空上一首歌的封面——不能只靠下面异步任务里 expectedKey
            // 校验(那个校验解决的是"结果回来时如果又换了下一首歌该不该采用"，防止旧结果
            // 覆盖新状态,但不解决"结果还没回来之前的这段空窗期该显示什么"这个问题)。
            // 2026-08-02 实测排查坐实:子进程调用有真实的、可感知的延迟(fork+管道读取+
            // JSON/base64 解码),这段时间里不清空的话,"歌词窗口"的封面模糊背景会继续
            // 显示上一首歌的封面,新封面抓完后才突然跳变,是一次可避免的视觉闪烁。跟
            // title/artist/album 故意保留"最近一次播放信息"是两回事(那三个是纯文字,
            // 旧值不会误导人;这里是背景图,挂着旧图会让人误以为"这就是当前这首歌的
            // 封面")。
            artworkData = nil
            artworkAccentHex = nil
            fetchArtworkForCurrentTrack(expectedKey: key)
        }

        // elapsedTime 对 Apple Music 是 Music.app 自己实时算出来的精确播放位置;对 QQ
        // 音乐是 media-control --now 的外推值,带噪声,经 resolvePositionSeconds 平滑
        // 过再用(见该函数注释)。
        let now = Date()
        let playing = snapshot.playing == true
        if playing, let duration = snapshot.duration, duration > 0 {
            let rate = snapshot.playbackRate ?? 1
            let (positionSeconds, didReanchor) = resolvePositionSeconds(reported: snapshot.elapsedTime ?? 0, rate: rate, key: key, now: now)
            // 只在真的有必要时才重新构造锚点——稳定播放期间(没有换歌/没有真实
            // seek/rate 和时长都没变),继续外推旧锚点在数学上跟重新构造一份新锚点得到
            // 完全相同的 extrapolatedPositionMs(now:) 结果(旧锚点的 fetchedAt+
            // progressMs 组合本身已经蕴含了外推到任意后续时刻的正确基准),重新赋值纯属
            // 多余的 @Published 通知。anchor 是结构体、不是 Equatable(fetchedAt 每次
            // 构造都不同,天然没法直接比较新旧是否相等),所以改成显式判断"这次是不是真的
            // 需要重新锚定"——首次锚定/换歌/真实不连续(didReanchor)/倍速或时长变化,
            // 缺一不可,不能只挑一两个条件。
            let needsNewAnchor = anchor == nil || trackChanged || didReanchor
                || anchor?.rate != rate || anchor?.durationMs != Int(duration * 1000)
            if needsNewAnchor {
                anchor = ProgressAnchor(
                    durationMs: Int(duration * 1000),
                    progressMs: Int(positionSeconds * 1000),
                    rate: rate,
                    progressTs: nil,
                    baseAgeMs: 0, // 本机直接读取,没有网络延迟需要外推的锚点年龄
                    fetchedAt: now,
                    fresh: true // 本地读取,始终当作新鲜锚点,不封顶外推
                )
            }
        } else {
            if anchor != nil { anchor = nil }
        }
        // 无论这一轮是否在播放,都要更新这三个状态,供下一轮判断"是不是刚从暂停里恢复
        // 播放"——只在上面播放分支里更新的话,"播放→暂停→再播放"这个序列会因为暂停期间
        // 完全没走到这行,让下一次恢复播放时的判断误用暂停前的陈旧 posPrevWall/
        // posWasPlaying,而不是正确识别出"刚从暂停恢复"。
        posTrackingKey = key
        posWasPlaying = playing
        posPrevWall = now
        if anchor == nil {
            if currentLine != nil { currentLine = nil }
            if nextLineText != nil { nextLineText = nil }
            if currentLineIndex != nil { currentLineIndex = nil }
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
        currentLyricsOffsetMs = newValue
        return newValue
    }

    public func resetLyricsOffset() {
        guard lastSnapshot != nil else { return }
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey)
        syncEngine.offsetMs = 0
        currentLyricsOffsetMs = 0
    }

    // 供"歌词管理"窗口的偏移输入框用——那边直接写 LyricsOffsetStore(不经过
    // nudge/reset,是敲一个具体数值),写完之后调这个让当前正在播的这首歌(如果编辑的
    // 恰好就是它)立刻用上新值,不用等下次换歌。跟别的歌词内容(key 对不上当前曲目)
    // 无关时,这里只是把 currentOffsetKey 对应的值重新读一遍、原样赋回去,是个安全的
    // 空操作。
    public func refreshOffsetFromStore() {
        guard lastSnapshot != nil else { return }
        let newValue = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey)
        syncEngine.offsetMs = newValue
        currentLyricsOffsetMs = newValue
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
        let newOffsetMs = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey)
        syncEngine.offsetMs = newOffsetMs
        if newOffsetMs != currentLyricsOffsetMs { currentLyricsOffsetMs = newOffsetMs }
        // hasLyricsContent/allLines 只在真的变化时才赋值——理由跟上面 apply() 里
        // title/artist/album 的同款注释一样。这个函数不止在真的换歌时调用,"歌词还没
        // 解析完、每轮都重试"那个分支(见 apply() 里 `!syncEngine.hasContent` 条件)会让
        // 这个函数在同一首歌播放期间被反复调用——这种情况下 hasContent 和 allLines 每次
        // 算出来的都是同一个"还没解析出来"的空结果,无条件赋值会白白触发订阅者(含"歌词
        // 窗口")重渲染。allLines 是 [LyricsWindowLine],Equatable(见 LyricsSyncEngine.swift
        // 里的定义),数组比较是安全、开销可忽略的操作(同一首歌的行数通常只有几十行)。
        let newHasContent = syncEngine.hasContent
        if newHasContent != hasLyricsContent { hasLyricsContent = newHasContent }
        let newInstrumental = found?.instrumental ?? false
        if newInstrumental != isCurrentTrackInstrumental { isCurrentTrackInstrumental = newInstrumental }
        // "歌词窗口"的全部行只在换歌词内容这一刻重新构造一次——同一首歌播放期间歌词
        // 本身不变,不需要每 20Hz tick 都重算。idPrefix 用 currentOffsetKey(已经是
        // 按当前曲目算出来的标识),保证换歌后这里产出的每个 LyricsWindowLine.id 整体
        // 跟上一首歌不同,SwiftUI 的 ForEach 才会做一次干净的整体替换而不是逐行"变形"
        // (见 LyricsWindowLine 类型定义处的注释)。
        let newAllLines = syncEngine.allLines(idPrefix: currentOffsetKey)
        if newAllLines != allLines { allLines = newAllLines }
        logger.debug("lyrics reloaded: hasContent=\(self.syncEngine.hasContent) found=\(found != nil)")
    }

    // 换歌那一刻异步取一次封面图(子进程调用,挪到后台线程,理由跟 poll() 一样)。等
    // 结果回来时如果又换了下一首歌(expectedKey 跟这时的 lastKey 对不上),说明这份图
    // 已经过时,直接丢弃——不会把上一首歌的封面错挂到新歌上。拿不到(没有 media-control
    // 二进制/bundle id 对不上/这首歌本来就没有封面数据)时置 nil,不保留上一首歌的封面
    // 硬挂着——跟 title/artist/album 故意保留"最近一次播放信息"是两回事:那三个字段是
    // 文字,显示旧值不会误导人;封面是背景图,挂着上一首歌的图会让人以为"这就是当前
    // 这首歌的封面",必须清空。
    private func fetchArtworkForCurrentTrack(expectedKey: String) {
        Task {
            // 取图和算平均色都在同一个后台 Task.detached 里做完——两者共用同一份原始
            // 图片字节,没必要为了"少写一个函数"分成两次异步往返各自触发一次 MainActor
            // 跳转。computeAccentHex 是 nonisolated 的纯函数,可以在这个非 MainActor 的
            // 闭包里直接调用。
            let (data, accentHex) = await Task.detached { () -> (Data?, String?) in
                guard let result = MediaControlClient.fetchArtwork() else { return (nil, nil) }
                return (result.data, Self.computeAccentHex(from: result.data))
            }.value
            guard expectedKey == self.lastKey else { return }
            self.artworkData = data
            self.artworkAccentHex = accentHex
            logger.debug("artwork fetched: bytes=\(data?.count ?? 0) accent=\(accentHex ?? "nil")")
        }
    }

    // 从封面原始图片数据算出一个单一的平均色,供"跟随封面"外观模式当动态高亮色用——
    // 算法跟同类开源实现(Karacookie 的 DominantColor.swift)一致:CIAreaAverage 把
    // 整张图平均成一个像素,而不是 K-means/直方图那类更贵的聚类算法,对"给悬浮歌词提供
    // 一个跟封面基调呼应的强调色"这个用途完全够用。太暗的平均色(比如封面本身是纯黑或
    // 深色专辑封面)会按亮度公式往上提亮到目标亮度 0.55——不提亮的话在深色封面上会算出
    // 一个近乎看不清的暗色,当文字颜色用完全不可读。
    //
    // nonisolated:纯函数,不读写这个类的任何 @MainActor 隔离状态,允许从
    // fetchArtworkForCurrentTrack() 里的后台 Task.detached 闭包(非 MainActor)直接调用,
    // 不需要为了调用它专门跳回主线程再跳出去。
    nonisolated private static func computeAccentHex(from data: Data) -> String? {
        guard let ciImage = CIImage(data: data) else { return nil }
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }
        // 不指定 workingColorSpace(传 NSNull())——只是要把一整张图迅速塌缩成一个像素
        // 的均值,不需要色彩管理带来的准确性,换来的是渲染更快。
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        var r = Double(bitmap[0]) / 255.0
        var g = Double(bitmap[1]) / 255.0
        var b = Double(bitmap[2]) / 255.0
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        if luminance < 0.45 {
            let boost = 0.55 / max(luminance, 0.05)
            r = min(1.0, r * boost)
            g = min(1.0, g * boost)
            b = min(1.0, b * boost)
        }
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02XFF", ri, gi, bi)
    }
}
