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
    /// 联网解析已经跑完一轮,但一句歌词都没拿到。
    ///
    /// 跟 hasLyricsContent==false 的区别就是"搜没搜过":没有它的话,一首查遍五个源都
    /// 找不到歌词的歌,只要还在播,界面就会**永远**停在"搜索歌词中…"——那句话在第 3 秒
    /// 是实话,在第 3 分钟就是假话了。判据是缓存条目里的解析时刻(见
    /// EnrichCacheLyrics.resolved)。
    ///
    /// 跟 isCurrentTrackInstrumental 互斥:纯音乐是"有依据地确认没有歌词",比这个更精确,
    /// 所以那一档单独判、并且排在前面(见各 View 的分支顺序)。
    @Published public private(set) var currentTrackHasNoLyrics: Bool = false

    /// collector 报告"这一轮什么都没查到,是因为网络不通"(见 CollectorStatus)。
    ///
    /// 跟 currentTrackHasNoLyrics 是互补的两半:那个是"查过了,这首歌没有",这个是
    /// "根本没查成"。没有它的话,断网时界面会一直停在"搜索歌词中…" —— 而那句话在
    /// 断网状态下永远不会有下文。
    @Published public private(set) var collectorNetworkDown: Bool = false
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
    // "歌词窗口"进度条用(2026-08-04 随 Apple Music 风格重做补上):暂停时 anchor 会被
    // 置 nil(见 apply() 的 else 分支),进度条如果只认 anchor,一暂停就整个没有位置可
    // 显示。暂停态 media-control/AppleScript 的 elapsedTime 本身就是精确的冻结位置,
    // 这里单独发布出来,让进度条在暂停时显示冻结的进度而不是直接消失。播放中恒为 nil
    // (此时该用 anchor 外推)。
    @Published public private(set) var pausedPositionMs: Int?
    // 当前曲目时长(毫秒)——anchor 里虽然也带 durationMs,但暂停时 anchor 是 nil,
    // 冻结进度条还需要时长算比例,单独发布。没有曲目/时长未知时为 nil。
    @Published public private(set) var currentDurationMs: Int?

    @Published public var preferWordLevelKaraoke: Bool = true {
        didSet { reloadCurrentLyrics() }
    }
    /// 要给哪几种文字标罗马音。改了立刻重新加载当前这首 —— 这道开关同时管服务端字段和
    /// 客户端兜底(见 LyricsSyncEngine.romanizationText 那道 guard)。
    @Published public var romanizationScripts: RomanizationScripts = .default {
        didSet { reloadCurrentLyrics() }
    }
    /// 歌词正文的简繁偏好。改了立刻重新加载当前这首 —— 转换发生在**送进解析引擎之前**,
    /// 缓存里存的原文一个字节都不动,切回来是无损的。
    @Published public var chineseVariant: ChineseVariant = .off {
        didSet { reloadCurrentLyrics() }
    }
    /// 这台机器上**见过**中文歌词没有。一旦见过就不再变回 false —— 设置项靠它决定要不要
    /// 露出简繁开关,而"这首歌不是中文"不该让一个已经露出来的设置消失。
    ///
    /// 为什么需要这个信号:光看用户的系统语言会漏掉"英文系统、但在听中文歌"的人 ——
    /// 比如英文系统的港台用户,他读繁体、正需要这个开关,而语言列表里可能压根没有中文。
    /// "库里有没有中文歌词"比"用户读什么语言"更贴近"这个设置对你有没有用"。
    @Published public private(set) var sawChineseLyrics = false

    private let syncEngine = LyricsSyncEngine()
    // 公开给 View 层——逐字填色现在按渲染帧频(TimelineView)从这个锚点直接外推真实
    // 播放位置现算,不再靠这里的 20Hz tick 把预算好的 fillFraction 塞进 currentLine。
    @Published public private(set) var anchor: ProgressAnchor?
    private var lastKey = ""
    private var lastSnapshot: MediaControlSnapshot?

    /// 最近一次快照实际来自哪个播放器的 bundle id,拿不到就是 nil。给「导出诊断信息」用——
    /// 用户在设置里选的可能是"自动识别",那一档只报设置值等于什么都没说,必须同时报出
    /// 这一刻真正被认下来的是谁。故意不做成 @Published:诊断报告只在导出那一刻读一次,
    /// 发布它只会让所有订阅者跟着每次轮询白重算一遍。
    public var lastResolvedBundleID: String? {
        let id = lastSnapshot?.bundleIdentifier ?? ""
        return id.isEmpty ? nil : id
    }

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
    // "真实读数 − 墙钟外推值"偏差的滑动平均——见 servoDecision() 的注释,2026-08-04
    // 实测排查坐实的"锁死偏差"问题的修复状态。播种/跳变/校正后都归零重新累计。
    private var posErrEMA: Double = 0
    private static let seekJumpToleranceSecs = 2.0

    // 地板量化源的「前向棘轮」阈值。
    //
    // 2026-08-16 实测坐实(QQ 音乐,采样 media-control 原始字段 + 程序化暂停/恢复):
    // QQ 音乐上报给 MediaRemote 的位置**只有整数秒**(6.0/21.0/23.0/25.0),而且锚点翻转
    // 瞬间 elapsedTimeNow 向前跳了 +1.001s —— 向下取整意味着每个锚点相对真实位置
    // **只会晚、不会早**(0~1s,平均 0.5s)。用户视角就是"歌词永远比实际唱的慢半个字"。
    //
    // 这推翻了 servoDecision 注释里"±1~1.5s 抖动是零均值噪声"的前提:取整偏差是单向的,
    // EMA 收敛到 -0.5s 左右、永远够不到 1.0s 门槛,于是换歌/恢复播放那一刻播种进来的
    // 取整滞后**永远不被纠正**。
    //
    // 棘轮的依据是一条不等式:对地板量化源,reported = 真实位置 - 取整误差 ≤ 真实位置,
    // 恒成立。所以只要 reported > predicted,就**证明** predicted 落后于真实位置,立刻
    // 向前采纳是安全的(不可能冲过头);反方向(reported < predicted)则分不清是"新锚点
    // 取整得更狠"还是"真实回退",维持原有 EMA 路径不动 —— 前者是单向噪声该忽略,后者
    // (漏观察的短暂停这类)靠 EMA 持续同号累积去修,跟改动前完全一致。
    // 0.05s 的下限只为过滤同锚点外推的 ±2ms 漂移,别为它白白重建锚点。
    private static let flooredForwardSnapEpsilonSecs = 0.05

    /// 见 flooredForwardSnapEpsilonSecs。纯函数,selftest 直接覆盖。
    public nonisolated static func shouldRatchetForward(
        reported: Double, predicted: Double, preciseSource: Bool
    ) -> Bool {
        !preciseSource && reported - predicted > flooredForwardSnapEpsilonSecs
    }

    // 2026-08-04 实测排查坐实的设计缺陷修复:原来"稳定播放"分支只按墙钟外推、完全不回看
    // 真实读数,任何播种时刻带进来的偏差——App 启动那一拍的读数毛刺、恰好整个落在两次
    // 2 秒轮询之间而完全没被观察到的短暂停(墙钟累加器会把暂停时长也当播放时间加进去)——
    // 只要小于 2 秒的 seek 容差,就会永久锁死、永远不被纠正(诊断日志实锤:一次启动播种
    // 偏差 0.205s,之后每一轮 reported−predicted 恒等于 +0.205,150 秒纹丝不动;用户视角
    // 就是"本地进度跟网页差了一截,而且一直差着")。
    //
    // 修法:对偏差做指数滑动平均(EMA),持续、同号的真实偏差会让 EMA 收敛到偏差值本身,
    // 超过门槛就把外推基准一次性校正回真实读数(snap)并触发重新锚定;而零均值的读数噪声
    // (QQ 音乐 elapsedTimeNow 的 ±1~1.5s 抖动)在 EMA 里相互抵消、到不了门槛,原有的
    // 抗抖动能力不受影响。两档参数按数据源精度选:
    // - precise(Apple Music,AppleScript 播放头,读数精确到 ~0.1s):alpha 0.5、门槛
    //   0.15s——持续偏差两三轮(4~6 秒)就校正,稳定期读数噪声 ±0.06s 的 EMA 幅度 ~±0.04,
    //   离门槛很远,不会误触发。
    // - 非 precise(QQ 音乐/网易云/Spotify,media-control 外推读数):alpha 0.3、门槛
    //   1.0s——±1.5s 零均值抖动的 EMA 分布 ~±0.6,大部分时间到不了 1.0;真有持续 1 秒
    //   以上的锁死偏差(同样低于 2 秒 seek 容差、原来永远修不掉的那种)时几轮后能修正。
    // 纯函数,selftest 直接覆盖(nonisolated:不碰任何 @MainActor 隔离状态)。
    public nonisolated static func servoDecision(errEMA: Double, error: Double, preciseSource: Bool) -> (newEMA: Double, snap: Bool) {
        let alpha = preciseSource ? 0.5 : 0.3
        let threshold = preciseSource ? 0.15 : 1.0
        let newEMA = errEMA * (1 - alpha) + error * alpha
        return (newEMA, abs(newEMA) > threshold)
    }

    // 调用方(apply())只在"这一轮确实在播放"时才会调用这个函数——暂停态不需要外推,
    // apply() 的 else 分支直接把 anchor 置 nil,不经过这里。
    //
    // 返回值除了外推出的秒数,还带一个 didReanchor:标记这次是不是真的发生了"不连续"
    // (换歌/刚恢复播放/第一次观察/真实 seek,即用了 reported 而不是 predicted)。
    // 调用方(apply())用这个标记判断"这次真的有必要重新构造 anchor 吗"——见那边注释。
    private func resolvePositionSeconds(reported: Double, rate: Double, key: String, now: Date, preciseSource: Bool) -> (seconds: Double, didReanchor: Bool) {
        // seek 刚发出去的一小段时间里,播放器可能还没跳过去(或这份快照是 seek 之前抓的)。
        // 这种读数比目标位置更靠近旧位置,采信它就会把刚跳过去的进度条/歌词硬拽回原处。
        // 直接沿用当前外推值(等于"这一轮不更新位置"),等播放器状态跟上。
        if let target = lastSeekTargetSecs, let prev = lastSeekPrevSecs, let at = lastSeekAt,
           Self.shouldRejectStalePositionAfterSeek(
               reported: reported, target: target, previous: prev, elapsedSinceSeek: now.timeIntervalSince(at)
           ) {
            return (trackPosSeconds, false)
        }
        guard key == posTrackingKey, posWasPlaying, let prevWall = posPrevWall else {
            // 换歌 / 刚从暂停恢复播放 / 第一次观察 → 没有可信的上一次锚点可外推,直接
            // 采用这次读数。
            trackPosSeconds = reported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        let gap = now.timeIntervalSince(prevWall)
        let predicted = trackPosSeconds + gap * rate
        if abs(reported - predicted) > Self.seekJumpToleranceSecs {
            // 真实 seek/跳变:直接重锚到这次读数。
            trackPosSeconds = reported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        if Self.shouldRatchetForward(reported: reported, predicted: predicted, preciseSource: preciseSource) {
            // 地板量化源(QQ 音乐/网易云)的前向棘轮:reported 恒 ≤ 真实位置,它比外推值
            // 靠前就证明外推值落后了,立刻向前采纳 —— 理由见 flooredForwardSnapEpsilonSecs。
            trackPosSeconds = reported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        // 稳定播放:默认继续墙钟外推,但用偏差 EMA 盯着"外推值是不是持续偏离真实读数"
        // ——持续偏差超过门槛就一次性校正(见 servoDecision 注释,修"播种偏差/漏观察的
        // 短暂停造成的永久锁死")。校正也走 didReanchor=true,让 apply() 重建锚点,
        // 不然校正只改了内部累加器、UI 用的锚点还在按旧基准外推,校正根本到不了屏幕。
        let (newEMA, snap) = Self.servoDecision(errEMA: posErrEMA, error: reported - predicted, preciseSource: preciseSource)
        posErrEMA = newEMA
        if snap {
            trackPosSeconds = preciseSource ? reported : predicted + newEMA
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        trackPosSeconds = predicted
        return (trackPosSeconds, false)
    }

    private var pollTimer: Timer?
    private var fastTimer: Timer?

    // Music.app 的播放状态变化通知(2026-08-04 加,借鉴 FlowX)——见
    // startObservingPlayerInfoNotification() 的注释。
    private var playerInfoObserver: NSObjectProtocol?
    // 通知去抖动:待触发的那次补查(收到新通知就取消重排)——见
    // handlePlayerInfoChanged() 的注释。
    private var pendingNotificationPoll: Task<Void, Never>?
    private static let playerInfoDebounce: Duration = .milliseconds(250)

    private init() {}

    public func start() {
        reschedulePollTimer()
        startObservingPlayerInfoNotification()
        // 快速 tick 不在这里无条件启动——是否需要它取决于第一次 poll() 拿到的播放
        // 状态,交给 apply() 里的 ensureFastTimerRunning()/stopFastTimer() 决定。
        poll()
    }

    public func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        if let playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(playerInfoObserver)
            self.playerInfoObserver = nil
        }
        pendingNotificationPoll?.cancel()
        pendingNotificationPoll = nil
        stopFastTimer()
    }

    // Music.app 每次换歌/暂停/恢复播放都会往分布式通知中心广播一条
    // "com.apple.Music.playerInfo"(系统级、无需任何额外权限,跟已有的"自动化"权限
    // 无关)。2026-08-04 借鉴 FlowX(Kadxy/FlowX,同类菜单栏歌词工具)加上这条订阅,
    // 补上 2 秒轮询天然的感知延迟。
    //
    // ⚠️ 设计取舍(刻意的,不要"顺手优化"掉):通知**只当作"提前触发一次 poll()"的信号**,
    // 完全不从 notification.userInfo 里取标题/播放状态/位置去直接喂状态——虽然那份
    // userInfo 里确实带着这些字段(FlowX 就是直接用的)。理由是这个类的状态机已经相当
    // 微妙(poll 世代号防乱序、resolvePositionSeconds 的位置平滑+伺服校正、
    // ensureFastTimerRunning 的生命周期),再引入一条"绕过 poll() 直接改状态"的并行
    // 路径,就会出现两套数据源需要互相对账:通知先到还是轮询先到、通知里的位置跟
    // AppleScript 读数哪个更准、平滑器该信谁——这些都是实打实的乱序 bug 温床。现在的
    // 写法让所有状态变更仍然只发生在 apply() 这一条路径上,通知的唯一作用是让那条路径
    // 提早跑一次,已有的世代号防护(见 poll())原样继续生效、不需要任何改动。
    //
    // 只对 Apple Music 有效——QQ 音乐/网易云音乐/Spotify 不广播这个通知,它们继续靠
    // 2 秒轮询感知(不是遗漏,是这些播放器没有等价机制)。选了别的播放器时这条订阅只是
    // 一条永远不触发的空订阅,不需要按 features.player 条件挂载:Music.app 可能同时开着
    // 但不是当前选定的播放器,那种情况下补查一次 poll() 也完全无害(poll() 自己会核对
    // bundleIdentifier,见 MediaControlClient.fetchSnapshot 的各条分支)。
    private func startObservingPlayerInfoNotification() {
        guard playerInfoObserver == nil else { return }
        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePlayerInfoChanged() }
        }
    }

    // 通知到达 → 去抖动之后补查一次 poll()。
    //
    // ⚠️ 用"去抖动"(延迟一小段再查,期间再来通知就重新计时)而不是"立刻查一次+之后节流",
    // 是 2026-08-04 实测量出来的必要选择,不是随手挑的:
    // ① Music.app 一次用户操作会连发 2 条 playerInfo(实测:按暂停 → 第一条 +116ms、
    //    第二条 +231ms),而且**第一条带的往往还是操作前的旧状态**(按暂停时第一条
    //    Player State 居然是 Playing,第二条才是 Paused);
    // ② 更关键的是 Music.app 自己的 AppleScript 可见状态也不是立刻切换的——实测
    //    `player state` 在命令后 +134ms 读到的还是 playing,到 +294ms 才变成 paused。
    // 所以"收到第一条通知就立刻查"会有很大概率读到一份还没切换完的快照,再叠加
    // "之后节流把真正带新状态的第二条吞掉",结果是白跑一次子进程、状态还得等下一次 2 秒
    // 轮询才纠正过来——比不加这套通知机制还糟。250ms 去抖动同时解掉这两点:一次操作的
    // 连发被合并成一次查询,且这次查询稳定发生在状态真正切换完之后(最后一条通知
    // +231ms,再等 250ms,查询落在 ~+480ms,远晚于 ~+294ms 的状态稳定点)。
    //
    // 即便如此仍明显优于改动前:感知延迟从"平均 1 秒、最坏 2 秒"降到 ~0.5 秒且稳定。
    // 2 秒轮询 Timer 继续独立运行不动,是这套机制的兜底——去抖动/取消逻辑万一有任何
    // 边界情况没覆盖到,最坏也只是退化成改动之前的行为,不会漏状态。
    private func handlePlayerInfoChanged() {
        pendingNotificationPoll?.cancel()
        pendingNotificationPoll = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.playerInfoDebounce)
            guard !Task.isCancelled else { return }
            self?.pendingNotificationPoll = nil
            self?.poll()
        }
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

    /// 没有 anchor(暂停,或曲目还在但位置已冻结)时按冻结位置 pausedPositionMs 解一次当前
    /// 歌词行;真的没有冻结位置、或引擎里没有歌词内容时才清空。
    ///
    /// ⚠️ apply() 和 fastTick() 必须都走这里。这两处本来各写了一份"anchor 为 nil 就三连
    /// 清空",于是把 apply() 那份改成"暂停不清行"之后,fastTick() 那份还在原样清 —— 而
    /// seek(toMs:) 末尾是**无条件**调 fastTick() 的(为了拖动进度条时歌词立刻跟到新位置),
    /// 所以暂停状态下拖一次进度条,行又被清掉,要等下一次 apply()(2 秒轮询)才回来。抽成
    /// 一处,两边不可能再错开。
    ///
    /// 不要在这里另外加 currentLyricsOffsetMs:activeLine/upcomingLineText/activeLineIndex
    /// 内部都会先做 rawPosMs + offsetMs(见 LyricsSyncEngine),手动再加一次就是双倍校正。
    private func resolveLinesForPausedPosition() {
        guard let frozen = pausedPositionMs, syncEngine.hasContent else {
            if currentLine != nil { currentLine = nil }
            if nextLineText != nil { nextLineText = nil }
            if currentLineIndex != nil { currentLineIndex = nil }
            return
        }
        let newLine = syncEngine.activeLine(atMs: frozen)
        if newLine != currentLine { currentLine = newLine }
        let newNext = syncEngine.upcomingLineText(afterMs: frozen)
        if newNext != nextLineText { nextLineText = newNext }
        let newIndex = syncEngine.activeLineIndex(atMs: frozen)
        if newIndex != currentLineIndex { currentLineIndex = newIndex }
    }

    private func fastTick() {
        guard let anchor else {
            resolveLinesForPausedPosition()
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

    // nil 快照(真的没有任何曲目在加载)和"有曲目但不是 Apple Music"共用同一套清理。
    //
    // ⚠️ 2026-08-14 改:title/artist/album 以前**故意不清**,理由写的是"保留最近一次播放
    // 的信息,跟暂停分支的既有行为一致"。那个理由站不住 —— **暂停根本不走这条路径**:
    // 暂停时 media-control 仍然给出一份带曲目的快照(playing=false),走的是 apply(),
    // 曲目信息本来就留着。能走到这里的只有"真的什么都没在放"。
    //
    // 于是一张专辑放完之后,"歌词窗口"会停在一个半吊子状态:曲名歌手还在,封面变回占位
    // 音符、配色没了、歌词列表空了写着"无歌词" —— 用户报的就是这个,看着像坏了而不是像
    // 停了。曲目信息一起清掉,各界面才会一致地表达"现在没有在放"。
    //
    // 别的界面早就防过空标题:菜单栏那条 `if !coordinator.title.isEmpty` 直接不显示这一行,
    // 灵动岛 `poller.title.isEmpty ? "♪" : poller.title` 回退成音符,都不需要改。
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
            pausedPositionMs = nil
            currentDurationMs = nil
            // 曲目本身也清掉,理由见上面那段。跟着一起清的还有"这首歌"的几个判定 ——
            // 留着的话停播之后空状态会写成「纯音乐」/「广告中」这种明显不对的文案。
            if !title.isEmpty { title = "" }
            if !artist.isEmpty { artist = "" }
            if !album.isEmpty { album = "" }
            if hasLyricsContent { hasLyricsContent = false }
            if isCurrentTrackInstrumental { isCurrentTrackInstrumental = false }
            if currentTrackHasNoLyrics { currentTrackHasNoLyrics = false }
            if isCurrentTrackAdBreak { isCurrentTrackAdBreak = false }
            // ⚠️ lastKey 必须一起清空,否则上面清掉的 allLines/artworkData 再也回不来。
            //
            // apply() 里重建这两样的两条路径都只在**换歌**时才跑:
            // reloadCurrentLyrics() 的条件是 `trackChanged || !syncEngine.hasContent`,
            // 而 syncEngine 在这里并没有被卸载、hasContent 仍是 true;取封面那条更是只有
            // `if trackChanged`。而 trackChanged 是 `key != lastKey` —— 不清 lastKey 的话,
            // 同一首歌恢复播放时 trackChanged 就是 false,两条路径全部跳过,"歌词窗口"会
            // 一直停在 allLines 为空的"无歌词"占位态、灵动岛也一直没有封面,直到用户换一
            // 首歌为止;而桌面悬浮歌词因为直接读 syncEngine(见 fastTick),显示的却是正常
            // 的,两个窗口互相矛盾。
            //
            // 这条路径不罕见:Music.app 退出、播放列表放完进入 stopped、以及选了 QQ 音乐/
            // 网易云/Spotify/自动识别时被别的 App(比如网页视频)抢走一次系统 Now Playing
            // 焦点,都会让快照变成 nil 走到这里。
            lastKey = ""
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
    //
    // 2026-08-04:poll() 现在有两个调用方(2 秒轮询 Timer + playerInfo 通知补查,见
    // handlePlayerInfoChanged),这道防护对新入口天然同样成立、不需要任何改动——它保护的
    // 是"任意两次 poll() 的返回乱序",跟这两次分别是谁触发的无关。通知补查跟定时轮询
    // 挨得很近(通知先到、轮询紧随其后)时,后发起的那次赢,先发起的那次结果被丢弃,
    // 正是想要的行为。
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
        // 同一首歌播到中途,collector 还可能给它补出译文、或者换上一份更好的歌词(见
        // collector 的 backfillTranslation / retryLyricsUpgrade / rescoreLyrics)。原来这里
        // 只在换歌或"完全没歌词"时才重读,于是这类中途补上的东西要等下一次换歌才看得到 ——
        // 2026-08-09 用户问"为什么当前这歌没有英文译文",译文其实早在 19 秒前就翻好并落盘了。
        //
        // ⚠️ 不要加"已经有译文了就不用再盯"这类省事的闸门。2026-08-09 试过一版,当场被
        // 一个真实场景打脸:译文不只会从无到有,还会**被顶替** —— 网易云先给一份固定中文的
        // 社区译文(于是"已有译文"成立、不再盯了),采集器随后判定它语言跟设置对不上、机翻
        // 成英文写回去,而这边已经不看了,界面就一直停在那份中文上。
        //
        // 代价是可控的:mtime 只是一次 stat,而重新解析只在文件真的被改写时发生 —— 那时候
        // 下一次 lookup() 本来也要重新解析(EnrichCacheReader 自己就是按 mtime 缓存的)。
        // 跟下面读 enrich cache 的 mtime 挂在同一个节拍上(每次快照,约 2s 一次)。
        // 成本是一次 stat —— CollectorStatus 自己按 mtime 缓存,文件没变就不会重新解码。
        let networkDown = CollectorStatus.networkLooksDown
        if networkDown != collectorNetworkDown { collectorNetworkDown = networkDown }

        let enrichMTime = EnrichCacheReader.fileModificationDate
        if trackChanged || !syncEngine.hasContent || enrichMTime != lastEnrichMTime {
            if trackChanged {
                logger.info("track changed: \(snapshot.artist ?? "", privacy: .public) - \(snapshot.title ?? "", privacy: .public)")
            }
            lastKey = key
            lastEnrichMTime = enrichMTime
            reloadCurrentLyrics()
        }
        if trackChanged {
            // ⚠️ 换歌时**不再**立即清空上一首歌的封面。
            //
            // 2026-08-02 曾经是立即清空的,当时的理由是"不清空的话背景会继续显示上一首的
            // 封面、新封面抓完才突然跳变,是一次可避免的闪烁"。2026-08-05 用户反馈坐实这个
            // 权衡选错了方向:清空造成的后果严重得多——"歌词窗口"的背景、文字颜色、封面占位
            // 全都挂在 artworkData != nil 上(见 LyricsWindowView.hasArtworkBackground),
            // 一清空,整扇窗从"封面模糊底 + 白色文字"整体回落到"系统默认背景 + 主文字色",
            // 浅色外观下就是**整窗白闪一下**,而封面取图有真实的、可感知的延迟(fork 子进程
            // + 管道读取 + base64 解码)。相比之下"背景多显示 200~500ms 上一首的模糊图"几乎
            // 无感——Apple Music 自己也是留着旧封面直到新封面加载完再交叉淡入。
            //
            // 现在交给 fetchArtworkForCurrentTrack 的完成回调收敛:拿到新封面就替换,确认这
            // 首歌没有封面(结果为 nil)就在那一刻清空——两种情况都只有一次视觉变化,没有
            // "先白闪再回来"。
            //
            // 但完成回调不能是唯一出路:MediaControlClient.fetchArtwork() 用的是
            // waitUntilExit() 且**没有超时**,子进程真挂住的话回调永远不来,旧封面就会一直
            // 挂着。所以再加一道超时兜底,见 scheduleArtworkStaleTimeout。
            scheduleArtworkStaleTimeout(forKey: key)
            fetchArtworkForCurrentTrack(expectedKey: key)
        }

        // elapsedTime 对 Apple Music 是 Music.app 自己实时算出来的精确播放位置;对 QQ
        // 音乐是 media-control --now 的外推值,带噪声,经 resolvePositionSeconds 平滑
        // 过再用(见该函数注释)。
        let now = Date()
        let playing = snapshot.playing == true
        if playing, let duration = snapshot.duration, duration > 0 {
            let rate = snapshot.playbackRate ?? 1
            // Apple Music 的读数是 AppleScript 播放头(精确到 ~0.1s),伺服校正用小门槛;
            // 其它播放器是 media-control 的带噪外推读数,维持高门槛抗抖动——见
            // servoDecision 的两档参数注释。
            // Spotify 2026-08-14 起也算 precise:它的位置已经改成直接问 Spotify 自己
            // (见 MediaControlClient.spotifyPlayerPosition),跟 Apple Music 一样是播放器
            // 报的真值,不再是 media-control 的带噪外推。继续按"非 precise"走 EMA 平滑
            // (alpha 0.3、门槛 1.0s)只会在已经准确的读数上**再加**一层滞后。
            // QQ 音乐/网易云没有 AppleScript 接口,仍旧维持原有的抗抖动处理。
            let preciseSource = snapshot.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier
                || snapshot.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier
            let (positionSeconds, didReanchor) = resolvePositionSeconds(reported: snapshot.elapsedTime ?? 0, rate: rate, key: key, now: now, preciseSource: preciseSource)
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
        // "歌词窗口"进度条的暂停态冻结位置/时长——见两个属性定义处的注释。跟其它
        // @Published 一样只在真的变化时才赋值。暂停态的 snapshot.elapsedTime 就是精确的
        // 冻结位置(AppleScript 对 Apple Music、media-control 的原始 elapsedTime 对其它
        // 播放器都是"暂停即冻结",见 MediaControlClient.fetchRawMediaControlSnapshot
        // 里暂停分支的注释),不需要再经过 resolvePositionSeconds 平滑。
        let newDurationMs: Int? = {
            if let d = snapshot.duration, d > 0 { return Int(d * 1000) }
            return nil
        }()
        if newDurationMs != currentDurationMs { currentDurationMs = newDurationMs }
        // 暂停态也要挡住 seek 之后的陈旧读数——播放分支走 resolvePositionSeconds,那个
        // 函数一进门就有 shouldRejectStalePositionAfterSeek 这层保护,而这行原来是直接
        // 采信 snapshot.elapsedTime。结果:暂停时拖进度条,seek(toMs:) 刚把 pausedPositionMs
        // 设成目标位置,紧接着这一轮 apply() 抓到的快照可能还是 seek 之前的位置(播放器
        // 没跟上,或这份快照本来就是 seek 之前抓的),于是进度条和歌词被硬拽回原处,过
        // 一两轮才跳到目标——手感上就是"弹回去一下再过去"。判定为陈旧时沿用当前值
        // (seek 刚写进去的目标位置),等播放器状态跟上。
        let newPausedPositionMs: Int? = {
            guard !playing else { return nil }
            let reported = snapshot.elapsedTime ?? 0
            if let target = lastSeekTargetSecs, let prev = lastSeekPrevSecs, let at = lastSeekAt,
               Self.shouldRejectStalePositionAfterSeek(
                   reported: reported, target: target, previous: prev, elapsedSinceSeek: now.timeIntervalSince(at)
               ) {
                return pausedPositionMs ?? Int(target * 1000)
            }
            return Int(reported * 1000)
        }()
        if newPausedPositionMs != pausedPositionMs { pausedPositionMs = newPausedPositionMs }
        // 无论这一轮是否在播放,都要更新这三个状态,供下一轮判断"是不是刚从暂停里恢复
        // 播放"——只在上面播放分支里更新的话,"播放→暂停→再播放"这个序列会因为暂停期间
        // 完全没走到这行,让下一次恢复播放时的判断误用暂停前的陈旧 posPrevWall/
        // posWasPlaying,而不是正确识别出"刚从暂停恢复"。
        posTrackingKey = key
        posWasPlaying = playing
        posPrevWall = now
        if anchor == nil {
            // 暂停(anchor == nil 但曲目还在、位置已冻结)时**不能**把当前歌词行清掉。
            //
            // 这里原来是无条件三连清空,于是一按暂停,悬浮歌词/灵动岛/菜单栏那一行歌词
            // 直接消失、歌词窗口的高亮也没了——而用户按暂停的典型场景恰恰是"这句是什么?
            // 我看一下",清掉正是最不该发生的事。停掉 20Hz 定时器是对的(暂停期间位置不
            // 再前进,没有必要每秒算 20 次),但"停止推进"跟"清空显示"是两回事。
            //
            // 暂停态有精确的冻结位置(pausedPositionMs,见上面那段注释:AppleScript 和
            // media-control 在暂停时给的 elapsedTime 都是冻结值),所以直接按这个位置解一
            // 次当前行即可。真的没有位置或没有歌词内容时才回落到清空。
            stopFastTimer()
            resolveLinesForPausedPosition()
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

    /// 跳到曲目内的某个位置(毫秒)——发指令给播放器,并**立刻**把本地外推重锚到目标位置。
    ///
    /// 为什么必须自己重锚、不能等下一轮轮询自愈:
    /// ① 轮询是 2 秒一轮(reschedulePollTimer),不重锚的话最坏要等 2 秒歌词才跟上,而拖
    ///    进度条这个动作用户预期是即时反馈;
    /// ② 更要命的是小幅拖动会被**永久**吞掉:resolvePositionSeconds 里那道
    ///    seekJumpToleranceSecs(2 秒)判定"读数跟外推差 2 秒以内算稳定播放,继续按旧基准
    ///    外推",拖动幅度小于 2 秒时它压根不认为发生了跳变,伺服 EMA 也会把这点差异当噪声
    ///    慢慢磨平——歌词会一直按拖动前的基准走。
    ///
    /// 重锚要同时改三处,少一处就会被下一轮"稳定播放"分支按旧值覆盖回去:trackPosSeconds
    /// (外推累加器)、posPrevWall(外推的墙钟基准)、posErrEMA(清零,拖动不是需要伺服慢慢
    /// 校正的漂移)。anchor 也当场重建,让 UI 这一帧就跳过去,不等 apply()。
    ///
    /// 暂停状态下也允许拖:此时 anchor 是 nil、pausedPositionMs 才是显示源,所以只更新它。
    // seek 之后短暂不信"更像 seek 之前"的位置读数,见 seek(toMs:) 与
    // shouldRejectStalePositionAfterSeek 的注释。
    private var lastSeekTargetSecs: Double?
    private var lastSeekPrevSecs: Double?
    private var lastSeekAt: Date?
    public nonisolated static let seekSettleWindow: TimeInterval = 1.2

    /// seek 刚发出去之后,这一份位置读数是不是"还是 seek 之前的播放器状态"、该整份丢弃。
    ///
    /// 纯函数,便于 selftest 覆盖。判据:还在窗口内,且这次读数**更靠近 seek 前的旧位置**
    /// 而不是目标位置。相等时不丢(拖动幅度极小时两者本来就分不开,丢了反而卡住自愈)。
    public nonisolated static func shouldRejectStalePositionAfterSeek(
        reported: Double, target: Double, previous: Double, elapsedSinceSeek: TimeInterval
    ) -> Bool {
        guard elapsedSinceSeek >= 0, elapsedSinceSeek < seekSettleWindow else { return false }
        return abs(reported - previous) < abs(reported - target)
    }

    public func seek(toMs targetMs: Int) {
        let clampedMs = max(0, min(targetMs, currentDurationMs ?? targetMs))
        let seconds = Double(clampedMs) / 1000
        // .auto 模式下要按"这一刻实际在播的是谁"选后端,不能只看设置值——设置是"自动识别"时
        // PlaybackPlayerPreference.current 不等于 .appleMusic,写路径会走 media-control,而
        // 读路径对 Apple Music 走的是精确的 AppleScript 播放头,两条路不一致。
        let resolvedIsAppleMusic = lastSnapshot?.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier
        MusicPlaybackController.seek(toSeconds: seconds, preferAppleScript: resolvedIsAppleMusic)

        let now = Date()
        // 记下"从哪跳到哪",用来在接下来一小段时间里识别并丢弃 seek 之前采样的陈旧读数。
        lastSeekPrevSecs = trackPosSeconds
        lastSeekTargetSecs = seconds
        lastSeekAt = now
        // 作废所有在飞的 poll:它们的快照是 seek **之前**抓的(子进程往返几十到几百毫秒),
        // 落地后会被 resolvePositionSeconds 当成"真实 seek 跳变"硬重锚回旧位置,表现成
        // 松手跳过去、一瞬间又弹回来。这一行只治"已经在飞"的那次;seek 本身还有 ~300ms
        // 才在播放器侧生效(Music.app 的 AppleScript 状态实测要 ~294ms 才切换,见
        // handlePlayerInfoChanged 那段注释),那之后**新发起**的 poll 同样会读到旧位置,
        // 靠上面那个接受窗兜。
        pollGeneration += 1
        trackPosSeconds = seconds
        posPrevWall = now
        posErrEMA = 0
        if let existing = anchor {
            anchor = ProgressAnchor(
                durationMs: existing.durationMs,
                progressMs: clampedMs,
                rate: existing.rate,
                progressTs: nil,
                baseAgeMs: 0,
                fetchedAt: now,
                fresh: true
            )
        } else if currentDurationMs != nil {
            // 暂停态:显示源是 pausedPositionMs(见 apply() 里那段注释),没有锚点可改。
            pausedPositionMs = clampedMs
        }
        // 歌词高亮跟着立刻走到新位置,不等 20Hz 的下一拍(它本来也会跟上,但那一拍之前
        // 屏幕上仍是旧的一句,拖动时看着像没反应)。
        fastTick()
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

    /// 上一次读缓存时那个文件的 mtime。变了就说明 collector 又写过,当前这首歌的内容可能
    /// 已经不是手上这一份了(见 apply() 里那段注释)。
    private var lastEnrichMTime: Date?

    private func reloadCurrentLyrics() {
        guard let snapshot = lastSnapshot else { return }
        let found = EnrichCacheReader.lookup(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            album: snapshot.album ?? ""
        )
        // 见过中文歌词就记一笔(粘性,只置不清)。判据跟 ChineseVariant.converted 一致:
        // 有汉字、且没有假名(有假名是日文)。
        let raw = found?.lyrics ?? ""
        if !sawChineseLyrics, Romanizer.containsHan(raw), !Romanizer.looksJapanese(raw) {
            sawChineseLyrics = true
        }
        // 简繁转换只作用在展示上:正文、译文、逐字数据都转,罗马音是拉丁字母不用转。
        // 逐字数据整串转是安全的 —— 时间戳是数字,转换只碰汉字。
        let variant = chineseVariant
        syncEngine.load(
            lyrics: variant.converted(found?.lyrics ?? ""),
            lyricsTr: variant.converted(found?.lyricsTr ?? ""),
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: variant.converted(found?.lyricsYRC ?? ""),
            preferWordLevel: preferWordLevelKaraoke,
            // 用来认出歌词文件开头那行「曲名 - 歌手」抬头,见 looksLikeHeaderLine。
            trackTitle: snapshot.title ?? "",
            trackArtist: snapshot.artist ?? "",
            romanizationScripts: romanizationScripts
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
        // 解析跑完了、又不是纯音乐、还是一句都没有 —— 那就是真的没有,别再说"搜索中"。
        let newNoLyrics = (found?.resolved ?? false) && !newHasContent && !newInstrumental
        if newNoLyrics != currentTrackHasNoLyrics { currentTrackHasNoLyrics = newNoLyrics }
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
    // 换歌后"旧封面最多还能挂多久"的兜底期限。取 3 秒:封面取图正常在几百毫秒内回来(见
    // fetchArtwork 的子进程往返),3 秒还没回来只可能是子进程卡死或那个二进制出了问题,
    // 此时挂着上一首的封面已经不合理了,宁可回落到系统背景。
    private static let artworkStaleTimeout: TimeInterval = 3
    private var artworkStaleTimeoutTask: Task<Void, Never>?

    /// 换歌时安排一次"旧封面过期清理"。只在真的有旧封面可挂时才安排——本来就没有封面的
    /// 情况下什么都不用做。取图回调先到就会把这个任务取消掉(见 fetchArtworkForCurrentTrack)。
    private func scheduleArtworkStaleTimeout(forKey key: String) {
        artworkStaleTimeoutTask?.cancel()
        artworkStaleTimeoutTask = nil
        guard artworkData != nil else { return }
        artworkStaleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.artworkStaleTimeout))
            guard !Task.isCancelled, let self, self.lastKey == key else { return }
            logger.debug("artwork stale timeout: clearing previous cover after \(Self.artworkStaleTimeout)s")
            self.artworkData = nil
            self.artworkAccentHex = nil
            self.artworkStaleTimeoutTask = nil
        }
    }

    // 换歌后取图拿到 nil 时的重试节奏(秒)。2026-08-05 实测坐实:切歌那一刻系统 Now Playing
    // 的封面往往还没更新完,media-control 会先返回"有新曲目元数据、但没有 artworkData",
    // 而原来的代码一次 nil 就当成"这首歌没有封面"定案——于是整首歌都显示占位音符 + 系统
    // 浅色背景(实测切歌后录屏:左栏平均亮度从 0.446 升到 0.946 并**一直保持**,不是闪一下)。
    // 用户报的"切歌白屏一下子"就是这件事,只是通常重新播到下一首又碰巧取到了。
    //
    // 间隔递增而不是等间隔:绝大多数情况第一次重试(0.3s)就有了,不值得为罕见的慢场景把
    // 每次切歌都拖长。
    //
    // ⚠️ 不能只按这几个 sleep 之和(2.1s)去论证"落在 artworkStaleTimeout(3s)之内"——
    // 这条链上还有最多 4 次 attempt(),每次都要 fork media-control 子进程、把几百 KB 的
    // base64 封面读到 EOF、waitUntilExit 再解码,单次就是几百毫秒量级(见本文件取图那段
    // 注释)。只要平均往返超过 ~225ms,3s 的兜底就会在重试还没跑完时先开火,把旧封面清掉
    // ——正好重演它当初要消除的那次白屏(先闪成系统浅色背景,重试成功后再闪回来,两次跳变)。
    // 修法是每次重试前把兜底任务重新排一遍(见 fetchArtworkForCurrentTrack 里的调用),
    // 这样"3s"变成"距最后一次尝试 3s",既不会打断重试,也保留了"子进程真挂住就别无限期
    // 挂着旧封面"这个原始目的。
    private static let artworkRetryDelays: [TimeInterval] = [0.3, 0.6, 1.2]

    private func fetchArtworkForCurrentTrack(expectedKey: String) {
        Task {
            // 取图和算平均色都在同一个后台 Task.detached 里做完——两者共用同一份原始
            // 图片字节,没必要为了"少写一个函数"分成两次异步往返各自触发一次 MainActor
            // 跳转。computeAccentHex 是 nonisolated 的纯函数,可以在这个非 MainActor 的
            // 闭包里直接调用。
            func attempt() async -> (Data?, String?) {
                await Task.detached { () -> (Data?, String?) in
                    guard let result = MediaControlClient.fetchArtwork() else { return (nil, nil) }
                    return (result.data, Self.computeAccentHex(from: result.data))
                }.value
            }
            var (data, accentHex) = await attempt()
            // 拿到 nil 就重试几次(见 artworkRetryDelays 的注释:切歌那一刻系统侧封面常还没
            // 更新完)。每次重试前都重新核对 expectedKey——期间用户可能又切了下一首,那就
            // 直接放弃这一轮,交给新那一轮自己去取。
            var round = 0
            while data == nil, round < Self.artworkRetryDelays.count {
                guard expectedKey == self.lastKey else { return }
                // 把兜底清理往后推一轮,理由见 artworkRetryDelays 上面那段注释。
                self.scheduleArtworkStaleTimeout(forKey: expectedKey)
                try? await Task.sleep(for: .seconds(Self.artworkRetryDelays[round]))
                guard expectedKey == self.lastKey else { return }
                (data, accentHex) = await attempt()
                round += 1
            }
            guard expectedKey == self.lastKey else { return }
            // 结果定案了(data 仍为 nil = 重试完还是没有,判定这首歌确实没有封面),
            // 兜底任务不再需要。
            self.artworkStaleTimeoutTask?.cancel()
            self.artworkStaleTimeoutTask = nil
            self.artworkData = data
            self.artworkAccentHex = accentHex
            logger.debug("artwork fetched: bytes=\(data?.count ?? 0) retries=\(round) accent=\(accentHex ?? "nil")")
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
        let (r, g, b) = brightenedAccent(
            r: Double(bitmap[0]) / 255.0,
            g: Double(bitmap[1]) / 255.0,
            b: Double(bitmap[2]) / 255.0)
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02XFF", ri, gi, bi)
    }

    /// 把封面均值色调整成"能当文字色用"的亮度。纯函数,selftest 直接覆盖。
    ///
    /// 2026-08-16 重写。原来是**在 RGB 空间按亮度整体乘一个 boost**,两个毛病:
    ///  ① 近黑封面(纯黑背景专辑)均值可能只有 (2,1,3)/255,boost 达到 11 倍,于是把
    ///    JPEG 噪点放大成一个饱和的随机色 —— 同一张黑封面每次取到的颜色都不一样;
    ///  ② 乘法保持 RGB 比例 = 保持饱和度,一个暗而浓的酒红被提到该亮度后依然浓,
    ///    贴在歌词上非常刺眼。
    ///
    /// 改成 HSB 空间处理(借鉴 boringNotch 的 ensureMinimumBrightness 思路):
    ///  - 近黑直接兜底成中性灰,不试图从噪点里"抢救"色相;
    ///  - 提亮多少,就按同一比例压低多少饱和度 —— 被提亮的颜色天然该更淡,这正是
    ///    人眼对"亮色"的预期,也避免了上面第 ② 条的刺眼。
    ///
    /// ⚠️ 手写 RGB↔HSB 而不是用 NSColor:LyrimuseCore 这一层刻意不引入 AppKit
    /// (见 Package.swift 的单向依赖注释)。
    nonisolated public static func brightenedAccent(
        r: Double, g: Double, b: Double, floor: Double = 0.62
    ) -> (r: Double, g: Double, b: Double) {
        // 近黑:三个通道都低到这个程度时,色相完全由压缩噪点决定,没有任何可信信息。
        // 给一个固定的中性灰,至少保证"同一张封面每次结果一样"。
        if r < 0.03, g < 0.03, b < 0.03 { return (0.72, 0.72, 0.72) }

        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let brightness = maxC
        let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
        guard brightness < floor else { return (r, g, b) }

        let ratio = brightness / floor  // < 1
        return hsbToRGB(
            hue: hueOf(r: r, g: g, b: b, maxC: maxC, minC: minC),
            saturation: saturation * ratio,
            brightness: floor)
    }

    /// 色相(0~1)。maxC==minC(灰)时色相无意义,返回 0。
    nonisolated private static func hueOf(
        r: Double, g: Double, b: Double, maxC: Double, minC: Double
    ) -> Double {
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        let h: Double
        switch maxC {
        case r: h = (g - b) / delta + (g < b ? 6 : 0)
        case g: h = (b - r) / delta + 2
        default: h = (r - g) / delta + 4
        }
        return h / 6
    }

    nonisolated private static func hsbToRGB(
        hue: Double, saturation: Double, brightness: Double
    ) -> (r: Double, g: Double, b: Double) {
        guard saturation > 0 else { return (brightness, brightness, brightness) }
        let sector = (hue - hue.rounded(.down)) * 6
        let i = Int(sector)
        let f = sector - Double(i)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch i % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
