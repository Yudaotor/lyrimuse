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
    // 歌词间奏点(歌词窗口的「•••」,2026-08-19):整首歌的间奏位置换歌时算一次;
    // "此刻在不在间奏里"跟 currentLineIndex 一样只在真的变化时赋值(20Hz tick 判定)。
    @Published public private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published public private(set) var currentGapIndex: Int?
    /// 当前行的逐字填色是否已经**完全定格**(所有词/组的过渡带都越过了 [0,1],继续按帧
    /// 重算不会再改变任何像素)。悬浮歌词的 TimelineView 用它做 paused 条件 —— 行尾拖延、
    /// 以最后一行收尾的间奏/曲末期间视觉零变化,不该让 30Hz 的表继续空转。每行至多翻转
    /// 两次(开始填色时 false、填完 true),跟其它 @Published 一样只在真的变化时赋值。
    /// 行级歌词(没有逐字数据)恒为 true —— 那条路径压根没有按帧填色的表可停。
    @Published public private(set) var currentLineFillSettled: Bool = true
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
    //
    // ⚠️ 2026-08-17 起这个值是**实际生效的总偏移** = 全局基准 + 这首歌的微调
    // (见 LyricsOffsetStore.effectiveOffset)。所有"把歌词时间轴对齐到播放位置"的地方
    // 都该用它 —— 逐字填色算当前毫秒、点某一行反算 seek 目标,用的都必须是引擎真正在
    // 用的那个数。想显示/重置"这首歌调了多少"请用下面的 trackLyricsOffsetMs。
    @Published public private(set) var currentLyricsOffsetMs: Int = 0
    // 上面那个总偏移里**只属于这首歌**的那一半(不含全局基准)。
    //
    // 菜单标题和「重置」按钮认它:显示总和的话,用户看到"歌词时间轴(+0.8s)"、点了重置
    // 却只回到 +0.5s(全局基准还在),数字对不上操作 —— 那比不显示更让人困惑。
    @Published public private(set) var trackLyricsOffsetMs: Int = 0
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
    //
    // ⚠️ 2026-08-17 从 artworkAccentHex 改名成这个,同时把"提亮"从这里挪走了 —— 这里
    // 现在是**未经任何调整的原始均值**。原因见下面 accentAgainstStroke 的注释:两个消费面
    // (灵动岛永远深底 / 桌面悬浮歌词背景未知)对"这个颜色该多亮"的要求正好相反,在源头
    // 提前统一成一个"够亮"的值,等于替桌面那一侧做了错误的决定。各自的处理放在
    // PlaybackCoordinator,那里才知道自己是哪个面。
    @Published public private(set) var artworkAverageHex: String?
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
    /// 上一拍的播放器 bundle id —— 只为「按播放器偏移」那一层服务(见 apply() 里那处判断)。
    /// 不能靠 lastSnapshot 反推:apply() 第一行就把它换成新快照了,等走到判断处已经比不出来。
    private var lastAppliedBundleID: String?
    /// 已落 UserDefaults 的「最后播放器/最后曲目」内存镜像(去重用,见 apply() 里的写点)。
    private var lastPersistedPlayerBundleID: String?
    private var lastPersistedTrackTitle: String?

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
    // 上一轮的报告值 —— 冻结检测(isFrozenReport)用它算"这一轮报告值前进了多少"。
    // 每次 resolvePositionSeconds 退出时统一更新(defer),换歌/暂停恢复不需要单独清:
    // 那些路径本身就会把它刷成当轮读数,下一轮的差值语义自然正确。
    private var posPrevReported: Double?
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
    // nonisolated:被 shouldRatchetForward(nonisolated 纯函数)引用,不可变 Sendable
    // 常量脱离 MainActor 隔离是安全的(不标的话 && 右侧的 autoclosure 会报隔离警告)。
    private nonisolated static let flooredForwardSnapEpsilonSecs = 0.05

    /// 位置数据源的三档画像 —— 伺服参数和棘轮适用性都按它选。
    ///
    /// 2026-08-18 从两档(preciseSource 布尔)拆成三档:Spotify 回归 media-control 通用
    /// 路径后被套在 noisyFloored 档里,但对照 AppleScript 真值实测(140+ 样本/4 首歌),
    /// 它的 elapsedTimeNow 稳态偏差只有 ±0.05s、比 QQ 音乐干净一个量级 —— 真正的问题
    /// 是换歌后头几秒 MediaRemote 报数是脏的(锚点先于音频出声,实测最高 +1.32s),App
    /// 换歌那一拍用首个读数播种,种进 <1.0s 的超前值后,noisyFloored 档的 1.0s 伺服
    /// 门槛让它整曲不被纠正 —— 用户视角就是"Spotify 歌词经常偏快"。给它单开一档收紧门槛。
    public enum PositionSourceTier {
        /// Apple Music:AppleScript 播放头,读数精确到 ~0.1s。
        case precise
        /// Spotify / 酷狗音乐:media-control 外推,稳态读数干净(±0.05s)但换歌初期锚点
        /// 可能带常量超前 —— 门槛要小到能把播种偏差拉回来,又别被暂停/切换瞬间的单发陈旧
        /// 读数(实测 -1.27s 一类)骗出回跳。
        ///
        /// 酷狗归这一档是 2026-08-21 实测定的,不是猜的:它**播放期间根本不刷新锚点**
        /// (`elapsedTime` 和 `timestamp` 21 秒纹丝不动,恒为开播那一刻的值),位置全靠
        /// `--now` 的墙钟外推。所以读数天然连续、无量化:实测 23.115s 墙钟对应 23.116s
        /// 读数(累计偏差 +0.0011s,单步 ±0.011s 以内,小数位 .467/.550/.620 完全连续)。
        /// 这跟 QQ/网易云那种"整秒下取整 + ±1~1.5s 抖动"是两种完全不同的画像 —— 按
        /// noisyFloored 处理会给它挂上前向棘轮,而棘轮的前提("reported ≤ 真实位置")
        /// 对一个纯外推源根本不成立。
        case cleanExtrapolated
        /// QQ 音乐/网易云:整秒下取整 + ±1~1.5s 抖动,大门槛 + 前向棘轮。
        case noisyFloored
    }

    /// bundleID → 数据源画像。纯函数,selftest 直接覆盖。
    public nonisolated static func positionSourceTier(forBundleID bundleID: String?) -> PositionSourceTier {
        if bundleID == PlaybackPlayer.appleMusic.bundleIdentifier { return .precise }
        // 2026-08-21 把默认档从 noisyFloored 翻成 cleanExtrapolated,并把真正"整秒下取整 +
        // 大抖动"的那两个显式列出来。
        //
        // 理由是实测:noisyFloored 那一档的两样东西(1.0s 大门槛 + 前向棘轮)都只对**整秒
        // 量化**的源成立 —— 棘轮的前提是"报告值 ≤ 真实位置"(下取整才恒成立)。而所有走
        // media-control 的源实测都是**纯墙钟外推、无量化**:酷狗(2026-08-21 实测 23 秒
        // 累计偏差 +0.0011s)、Arc(同款,小数位完全连续)。也就是说 noisyFloored 是**少数
        // 派**,把它当默认档等于让每一个没被显式登记的源都套上一副不适用的参数,而 1.0s
        // 门槛意味着 1 秒以内的固定偏差永远修不掉。
        //
        // bundleID 为 nil(压根没有来源信息)也走这一档:所谓"保守"应该是"别用前提不成立的
        // 棘轮",而不是"选那个门槛最大的"。
        if bundleID == PlaybackPlayer.qqMusic.bundleIdentifier
            || bundleID == PlaybackPlayer.netease.bundleIdentifier {
            return .noisyFloored
        }
        return .cleanExtrapolated
    }

    /// 见 flooredForwardSnapEpsilonSecs。纯函数,selftest 直接覆盖。
    ///
    /// 只对地板量化源(noisyFloored)生效:棘轮的依据是"reported ≤ 真实位置"这条
    /// 不等式,而 Spotify 的读数恰恰恒略**超前**真值(2026-08-18 实测),对它棘轮
    /// 只会把位置锁在抖动的上包络、且 EMA 每次吸附都被清零,永远修不回来。
    public nonisolated static func shouldRatchetForward(
        reported: Double, predicted: Double, tier: PositionSourceTier
    ) -> Bool {
        tier == .noisyFloored && reported - predicted > flooredForwardSnapEpsilonSecs
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
    // 抗抖动能力不受影响。三档参数按数据源画像选(见 PositionSourceTier):
    // - precise(Apple Music,AppleScript 播放头,读数精确到 ~0.1s):alpha 0.5、门槛
    //   0.15s——持续偏差两三轮(4~6 秒)就校正,稳定期读数噪声 ±0.06s 的 EMA 幅度 ~±0.04,
    //   离门槛很远,不会误触发。
    // - cleanExtrapolated(Spotify,2026-08-18 拆档):alpha 0.3、门槛 0.4s——稳态抖动
    //   ±0.05s 离门槛很远;换歌初期播种进来的 0.4~1.3s 超前(MediaRemote 脏窗口)两轮
    //   (~4 秒)就校正;暂停/切换瞬间的单发陈旧读数(实测 -1.27s)只把 EMA 推到 -0.38,
    //   不触发回跳,下一轮干净读数就衰减掉。
    // - noisyFloored(QQ 音乐/网易云,media-control 外推读数):alpha 0.3、门槛
    //   1.0s——±1.5s 零均值抖动的 EMA 分布 ~±0.6,大部分时间到不了 1.0;真有持续 1 秒
    //   以上的锁死偏差(同样低于 2 秒 seek 容差、原来永远修不掉的那种)时几轮后能修正。
    // 纯函数,selftest 直接覆盖(nonisolated:不碰任何 @MainActor 隔离状态)。
    public nonisolated static func servoDecision(errEMA: Double, error: Double, tier: PositionSourceTier) -> (newEMA: Double, snap: Bool) {
        let alpha: Double, threshold: Double
        switch tier {
        case .precise: (alpha, threshold) = (0.5, 0.15)
        case .cleanExtrapolated: (alpha, threshold) = (0.3, 0.4)
        case .noisyFloored: (alpha, threshold) = (0.3, 1.0)
        }
        // cleanExtrapolated 的单样本限幅(2026-08-18,冻结守卫的配套):锚点冻结的
        // **第一拍**只表现为一次大负偏差(实测 -1.74),冻结检测要到第二拍(报告值
        // 连续没动)才认得出来 —— 不限幅的话第一拍 0.3×(-1.74) = -0.52 就冲过 0.4
        // 门槛,歌词被拖回半秒。限在 ±0.75:单发异常最多把 EMA 推到 ±0.225,到不了
        // 门槛;真实的持续偏差只是多等一轮(0.8s 偏差第 3 轮仍能校正,见 selftest)。
        let clamped = tier == .cleanExtrapolated ? max(-0.75, min(0.75, error)) : error
        let newEMA = errEMA * (1 - alpha) + clamped * alpha
        return (newEMA, abs(newEMA) > threshold)
    }

    /// 冻结检测(2026-08-18):曲目/广告结尾 Spotify 会把 MediaRemote 锚点冻住 ——
    /// 实测广告结尾 elapsedTimeNow 卡死 6 秒,真声一路走到落后 8 秒。播放中墙钟走了
    /// gap、报告值却几乎没动,这份读数**必然**陈旧(音频在播,诚实的位置不可能不动)。
    /// 判的是"几乎没动"(绝对值),不是"没前进":真实的向后 seek 是大负数、解冻那一拍
    /// 是大正数,都不命中,照常走 seek 分支。gap < 0.75s 的样本不判 —— 事件触发的
    /// 250ms 补查间隔太短,正常前进量也接近 0,分不出真假。只对 cleanExtrapolated
    /// 启用:QQ/网易云的整秒地板在 2s 轮询下本来就该前进 ≥1s,不需要;precise 更不需要。
    /// 纯函数,selftest 直接覆盖。
    public nonisolated static func isFrozenReport(
        reportedAdvance: Double, gap: Double, rate: Double, tier: PositionSourceTier
    ) -> Bool {
        tier == .cleanExtrapolated && gap >= 0.75
            && abs(reportedAdvance) < max(0.1, 0.15 * gap * rate)
    }

    // ---- Spotify 自然切歌(gapless)锚点超前校正(2026-08-20) --------------------------
    //
    // 实测坐实(Forever Love→在那遙遠的地方,media-control 0.25s 采样 + 旧曲连续外推
    // 做真值):gapless 自然切歌时,Spotify 在**旧曲真声还剩 ~0.84s** 时就换了元数据并
    // 打好新曲锚点(elapsedTime=0),此后整首歌 elapsedTimeNow 恒定超前真声 +0.888s
    // (±0.009s,60s 窗口内纹丝不动,锚点从不重打)。手动点播的锚点是点击瞬间打的、与
    // 真声对齐,所以准——这就是"自然切歌整首偏快、单独点播正常"的完整机理。
    //
    // 伺服(servoDecision)对这种偏差**结构性失明**:稳定播放期间每笔读数都从同一个
    // 超前锚点外推,与我们的墙钟外推步调完全一致,reported−predicted 恒 ≈0,EMA 永远
    // 够不到门槛。所以必须在换歌那一拍用外部真值把偏置量出来、之后每笔读数都扣掉。
    //
    // 真值来源=**上一首歌自己的连续外推**:音频时间是连续的,换歌被观察到那一刻,新曲
    // 的真实位置就是旧曲外推位置越过其时长的量(overrun;负值=旧曲真声还没放完,新曲
    // 位置为负,UI 侧 extrapolatedPositionMs 天然钳到 0,表现为歌词等真声开始才起走)。
    // 旧曲外推的时钟偏移实测 std 0.008s,足够当真值。08-14~08-18 的 JXA 直查路线
    // (playerPosition)不能当真值:它自己在自然切歌时同样超前(本次实测 +0.77s,08-17
    // 实测 +1.84s,每首抽签),已整体撤除,见 PositionSourceTier 注释。
    //
    // 偏置的生命周期:换歌估计(守卫见 naturalAdvanceCorrection);真实 seek(Spotify
    // 会重打锚点,重打后的锚点是准的)清零并改信原始读数;暂停⇄恢复继承(冻结的
    // elapsedTime 带着同一个超前锚点的值);手动换歌/非 Spotify 清零。
    /// 换歌被观察到时,旧曲连续外推位置与其时长的最大允许差距——超出说明不是"自然播完
    /// 切歌"(手动跳歌/外推基准已陈旧),不做校正。取值覆盖实测 ~0.84s 的元数据提前量 +
    /// 通知触发轮询的 ~0.3-0.6s 延迟,再留余量。
    public nonisolated static let naturalAdvanceWindowSecs = 4.0
    /// 锚点超前量的可信区间。下限滤掉测量噪声(Apple Music 级精度的源天然落在这之下);
    /// 上限之外视为陈旧读数(08-18 实测换歌瞬间 elapsedTimeNow 可能还挂着上一首的值,
    /// 如 30.3 vs 0.02)或模型失效,放弃校正退回原样采信(=改动前行为,seek 分支会兜住
    /// 陈旧值)。实测真实偏置 0.69~1.32s,2.5s 的上限同时把"手动跳歌恰好发生在结尾窗口
    /// 内"这种误判的伤害钉死在 ≤2.5s(且仅那一首、且是偏慢——比整首偏快的现状轻)。
    public nonisolated static let naturalAdvanceMaxBiasSecs = 2.5
    public nonisolated static let naturalAdvanceMinBiasSecs = 0.05

    /// 自然切歌锚点偏置估计。纯函数,selftest 直接覆盖。
    /// - reported: 新曲第一笔**原始**读数(elapsedTimeNow,未扣任何偏置)
    /// - overrun: 换歌被观察到那一刻,旧曲连续外推位置 − 旧曲时长(负=真声还没放完)
    /// - 返回 (seed, bias):seed=新曲播种位置(=overrun,允许为负),bias=之后每笔读数
    ///   要扣除的超前量;nil=窗口外/偏置不可信,按原逻辑采信读数。
    public nonisolated static func naturalAdvanceCorrection(
        reported: Double, overrun: Double
    ) -> (seed: Double, bias: Double)? {
        guard abs(overrun) <= naturalAdvanceWindowSecs else { return nil }
        let bias = reported - overrun
        guard bias > naturalAdvanceMinBiasSecs, bias <= naturalAdvanceMaxBiasSecs else { return nil }
        return (overrun, bias)
    }

    /// 当前曲目的锚点超前量(秒)——resolvePositionSeconds 对每笔原始读数先扣掉它。
    /// 只在 Spotify(cleanExtrapolated)自然切歌时非零。
    private var posReportedBiasSecs: Double = 0

    /// 播放时钟的只读快照,给「导出诊断信息」用(第 14 章 §7)。
    ///
    /// 为什么需要它:「歌词慢半拍」是这个 App 最难复现、也最常被报的一类问题,而它至少有
    /// 四种成因,修法完全不同 —— 帧率掉了 / `positionSourceTier` 判错(把精确源当成外推源)/
    /// 伺服在反复 snap(位置读数抖)/ 自然切歌偏置估歪。在此之前诊断报告里**一行播放时钟
    /// 状态都没有**,这四种在报障里长得一模一样,只能靠猜加翻 collector 日志。
    ///
    /// 这些全是本来就在内存里的字段,这里只是把它们读出来 —— 零热路径成本,不新增任何计算。
    /// 刻意做成一次性快照而不是 @Published:诊断导出是"点一下读一次"的动作,做成发布属性
    /// 会让每次伺服调整都推着订阅者重渲染。
    public struct ClockSnapshot: Sendable {
        public var tier: String
        public var posErrEMASecs: Double
        public var reportedBiasSecs: Double
        public var anchorRate: Double?
        public var anchorFresh: Bool?
        public var anchorAgeSecs: Double?
        public var effectiveLyricsOffsetMs: Int
        public var lrcOffsetMs: Int
        public var fillSettled: Bool
        public var hasLyrics: Bool
        public var isPlaying: Bool
    }

    public var clockSnapshot: ClockSnapshot {
        let tier = Self.positionSourceTier(forBundleID: lastSnapshot?.bundleIdentifier)
        return ClockSnapshot(
            tier: String(describing: tier),
            posErrEMASecs: posErrEMA,
            reportedBiasSecs: posReportedBiasSecs,
            anchorRate: anchor?.rate,
            anchorFresh: anchor?.fresh,
            anchorAgeSecs: anchor.map { Date().timeIntervalSince($0.fetchedAt) },
            effectiveLyricsOffsetMs: currentLyricsOffsetMs,
            lrcOffsetMs: syncEngine.lrcOffsetMs,
            fillSettled: currentLineFillSettled,
            hasLyrics: hasLyricsContent,
            isPlaying: isPlayingNow
        )
    }
    /// 上一轮快照的曲目时长(秒)——自然切歌判定要用"旧曲"的时长,而 resolve 被调用时
    /// snapshot 已经是新曲的了。apply() 每轮末尾更新(与 posTrackingKey 同批)。
    private var posPrevDurationSecs: Double = 0
    /// 上一轮快照是否也是 cleanExtrapolated 档(Spotify)——自然切歌校正的"旧曲真值"
    /// 必须来自 Spotify 自己的连续外推;auto 模式跨播放器切歌时,拿 QQ/网易云的整秒
    /// 地板外推或 Apple Music 的播放头当旧曲真值去估 Spotify 偏置是错的
    /// (2026-08-20 对抗审查抓出)。
    private var posPrevTierCleanExtrapolated = false
    /// 暂停期间上一轮的原始冻结读数——暂停中用户在播放器里拖进度条时,冻结值会跳变
    /// (Spotify 同时重打对齐真声的锚点),旧偏置必须作废;不检测的话恢复播放后整曲
    /// 反向偏慢一个旧偏置(2026-08-20 对抗审查抓出)。播放态清 nil。
    private var posPausedRawSecs: Double?

    /// 权威广告判据(2026-08-19):AppleScript 的 `spotify url` 对广告返回 "spotify:ad:…"。
    /// 每次换曲最多一次、后台异步,失败静默退回字段启发式(不劣于旧状)。结果回来时先核对
    /// 还是不是同一首 —— 广告只有二三十秒,晚到的 true 不能扣在下一首真歌头上。
    private func verifySpotifyAdViaAppleScript(forKey key: String) {
        Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "tell application \"Spotify\" to spotify url of current track"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { return }
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let out = String(data: data, encoding: .utf8),
                  out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("spotify:ad")
            else { return }
            await MainActor.run { [weak self] in
                guard let self, self.lastSnapshot?.trackKey == key else { return }
                if !self.isCurrentTrackAdBreak { self.isCurrentTrackAdBreak = true }
            }
        }
    }

    // 调用方(apply())只在"这一轮确实在播放"时才会调用这个函数——暂停态不需要外推,
    // apply() 的 else 分支直接把 anchor 置 nil,不经过这里。
    //
    // 返回值除了外推出的秒数,还带一个 didReanchor:标记这次是不是真的发生了"不连续"
    // (换歌/刚恢复播放/第一次观察/真实 seek,即用了 reported 而不是 predicted)。
    // 调用方(apply())用这个标记判断"这次真的有必要重新构造 anchor 吗"——见那边注释。
    private func resolvePositionSeconds(reported rawReported: Double, rate: Double, key: String, now: Date, tier: PositionSourceTier) -> (seconds: Double, didReanchor: Bool) {
        // 自然切歌锚点偏置(见 naturalAdvanceCorrection 一带的注释):同曲期间每笔读数
        // 恒定超前 bias,先扣掉再进入后续所有判断。raw 值只在三处直接用:换歌时的偏置
        // 估计、冻结检测的逐笔差分(常量偏置在差分里天然消掉,但语义上按原始值记)、
        // 以及真实 seek 之后的重新采信(Spotify 重打的新锚点是准的,偏置随之作废)。
        if tier != .cleanExtrapolated, posReportedBiasSecs != 0 {
            // 同 key 跨播放器接续(同一首歌从 Spotify 切到别的源)不触发换歌分支——偏置
            // 只对打歪的 Spotify 锚点有意义,源变了立即作废(2026-08-20 对抗审查抓出)。
            posReportedBiasSecs = 0
        }
        let reported = rawReported - posReportedBiasSecs
        // 冻结检测要用"上一轮的报告值",这里先算差值、再统一记录本轮值(defer 保证
        // 每条退出路径都记,包括下面的各个 early return)。
        let reportedAdvance = rawReported - (posPrevReported ?? rawReported)
        defer { posPrevReported = rawReported }
        // seek 刚发出去的一小段时间里,播放器可能还没跳过去(或这份快照是 seek 之前抓的)。
        // 这种读数比目标位置更靠近旧位置,采信它就会把刚跳过去的进度条/歌词硬拽回原处。
        // 直接沿用当前外推值(等于"这一轮不更新位置"),等播放器状态跟上。
        // ⚠️ 只对同一首歌生效:seek 永远发生在曲内,换歌那一拍(拖到结尾触发自然切歌/
        // seek 后 1.2s 内恰好换歌)不能被整拍拒收——否则新曲第一拍被吞、apply() 末尾又
        // 已把 posTrackingKey 推进成新曲,换歌分支(含自然切歌校正)被永久跳过
        // (2026-08-20 对抗审查抓出)。
        if key == posTrackingKey,
           let target = lastSeekTargetSecs, let prev = lastSeekPrevSecs, let at = lastSeekAt,
           Self.shouldRejectStalePositionAfterSeek(
               reported: reported, target: target, previous: prev, elapsedSinceSeek: now.timeIntervalSince(at)
           ) {
            return (trackPosSeconds, false)
        }
        guard key == posTrackingKey, posWasPlaying, let prevWall = posPrevWall else {
            if key != posTrackingKey {
                // 换歌:先判是不是 gapless 自然切歌——上一首(还在播)按墙钟连续外推已经
                // 走到结尾附近。是的话按连续性播种 + 量出锚点超前量;否则(手动点播/首次
                // 观察/别的播放器)原样采信这次读数、偏置清零。只对 Spotify 启用:Apple
                // Music 的播放头本身就是真值,QQ/网易云的整秒地板会把偏置估计噪声化。
                var corrected: (seed: Double, bias: Double)?
                if tier == .cleanExtrapolated, posPrevTierCleanExtrapolated,
                   posWasPlaying, let prevWall = posPrevWall,
                   posPrevDurationSecs > 0 {
                    let overrun = trackPosSeconds
                        + now.timeIntervalSince(prevWall) * (rate > 0 ? rate : 1)
                        - posPrevDurationSecs
                    corrected = Self.naturalAdvanceCorrection(reported: rawReported, overrun: overrun)
                    if let corrected {
                        logger.notice("natural advance: seed \(corrected.seed, format: .fixed(precision: 3))s, anchor leads audio by \(corrected.bias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
                    }
                }
                posReportedBiasSecs = corrected?.bias ?? 0
                trackPosSeconds = corrected?.seed ?? rawReported
            } else {
                // 刚从暂停恢复播放 / 首次观察(同曲):暂停冻结的 elapsedTime 带着同一个
                // 超前锚点的值,偏置继续适用,采用已扣偏置的读数。
                trackPosSeconds = reported
            }
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        let gap = now.timeIntervalSince(prevWall)
        let predicted = trackPosSeconds + gap * rate
        // 冻结守卫(2026-08-18,必须在 seek 分支**之前**):冻结的读数越冻越落后,几秒
        // 后就会超过 2s 的 seek 容差 —— 放到 seek 分支后面的话,位置会被"重锚"回冻结值,
        // 歌尾歌词整段倒回去。命中时维持墙钟外推、不喂 EMA;解冻那一拍报告值大步前跳,
        // 自然落进 seek 分支瞬间追上。判据与边界见 isFrozenReport 注释。
        if Self.isFrozenReport(reportedAdvance: reportedAdvance, gap: gap, rate: rate, tier: tier) {
            trackPosSeconds = predicted
            return (trackPosSeconds, false)
        }
        // 单曲循环(repeat-one)的 gapless 回绕:key 不变、走不到换歌分支,但与跨曲自然
        // 切歌是同一机制(引擎驱动的自然过渡,新锚点先于真声打好)——不识别的话会落进
        // 下面的 seek 分支把量准的偏置清掉,循环第 2 遍起整曲回到偏快(2026-08-20 对抗
        // 审查抓出)。签名=外推已到曲尾窗口、且按"回绕真值=越界量"估出的偏置落在可信
        // 区间(稳定播放到曲尾时 raw 是大值,估出的偏置≈整曲时长,天然不命中;向后拖到
        // 曲首的误判面与"手动跳歌落窗"同级,伤害同被 2.5s 上限钉死且方向偏慢)。
        if tier == .cleanExtrapolated, posPrevDurationSecs > 0,
           let corr = Self.naturalAdvanceCorrection(reported: rawReported, overrun: predicted - posPrevDurationSecs) {
            logger.notice("repeat-one wrap: seed \(corr.seed, format: .fixed(precision: 3))s, anchor leads audio by \(corr.bias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
            posReportedBiasSecs = corr.bias
            trackPosSeconds = corr.seed
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        if abs(reported - predicted) > Self.seekJumpToleranceSecs {
            // 真实 seek/跳变:直接重锚到这次读数。seek 时 Spotify 会重打锚点,重打后的
            // 锚点与真声对齐(与手动点播同一性质),自然切歌偏置随之作废——清零并改信
            // 原始读数,否则整首歌会反向偏慢一个旧偏置。
            //
            // 已知边界(2026-08-20 对抗审查确认,单源本质歧义、接受不修):偏置在位时,
            // 用户在 Spotify 自己界面里**小幅**拖动(幅度 < 偏置+2s ≈ 3s)——重打后的
            // 锚点是准的,但扣着旧偏置的读数跳变量 |d−bias| 不过 2s 门槛,进不来这个
            // 分支,伺服会把该曲余下部分收敛到"真声−偏置"(恒慢 ~0.9s)。单凭
            // elapsedTimeNow 分不出"带偏置的锚点没动"和"准锚点+拖了≈偏置":拖动
            // ≥3s(绝大多数)正常进此分支纠正,换歌即自愈。
            posReportedBiasSecs = 0
            trackPosSeconds = rawReported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        if Self.shouldRatchetForward(reported: reported, predicted: predicted, tier: tier) {
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
        let (newEMA, snap) = Self.servoDecision(errEMA: posErrEMA, error: reported - predicted, tier: tier)
        posErrEMA = newEMA
        if snap {
            trackPosSeconds = tier == .precise ? reported : predicted + newEMA
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        trackPosSeconds = predicted
        return (trackPosSeconds, false)
    }

    private var pollTimer: Timer?
    private var fastTimer: Timer?
    private var screenLocked = false

    // Music.app 的播放状态变化通知(2026-08-04 加,借鉴 FlowX)——见
    // startObservingPlayerInfoNotification() 的注释。
    private var playerInfoObserver: NSObjectProtocol?
    private var spotifyInfoObserver: NSObjectProtocol?
    // media-control 的事件流(QQ 音乐/网易云没有分布式通知,靠它)。见
    // MediaControlStreamWatcher —— 事件同样只当"提前 poll 一次"的信号。
    private var streamWatcher: MediaControlStreamWatcher?
    // 通知去抖动:待触发的那次补查(收到新通知就取消重排)——见
    // handlePlayerInfoChanged() 的注释。
    private var pendingNotificationPoll: Task<Void, Never>?
    private static let playerInfoDebounce: Duration = .milliseconds(250)

    private init() {}

    public func start() {
        reschedulePollTimer()
        startObservingPlayerInfoNotification()
        // 内存紧张时让出解码后的全曲库歌词缓存(~21MB),见 EnrichCacheReader 注释。
        EnrichCacheReader.installMemoryPressureRelief()
        // 后台解码采纳新内容即回捅一次 poll:新歌词/译文不等下一拍轮询(暂停档 6s)才
        // 上屏,见 EnrichCacheReader.onContentAdopted 注释。
        EnrichCacheReader.onContentAdopted = { [weak self] in self?.poll() }
        // 快速 tick 不在这里无条件启动——是否需要它取决于第一次 poll() 拿到的播放
        // 状态,交给 apply() 里的 ensureFastTimerRunning()/stopFastTimer() 决定。
        poll()
    }

    public func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        for observer in [playerInfoObserver, spotifyInfoObserver].compactMap({ $0 }) {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        playerInfoObserver = nil
        spotifyInfoObserver = nil
        streamWatcher?.stop()
        streamWatcher = nil
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
    // Apple Music 和 Spotify 都广播分布式通知,两个都订阅。
    //
    // ⚠️ 这里原来写着"Spotify 不广播这个通知……这些播放器没有等价机制",那句话是错的:
    // Spotify 有自己的 com.spotify.client.PlaybackStateChanged(2026-08-16 审阅
    // lycrics_notch 时发现,它的 SpotifyController 一直在用),我们却只订阅了 Apple Music
    // 那条,于是 Spotify 用户白等 2 秒轮询。QQ 音乐/网易云确实没有等价通知,它们靠
    // media-control 的事件流(见 MediaControlStreamWatcher)。
    //
    // 两条订阅都不按 features.player 条件挂载:某个播放器可能开着但不是当前选定的那个,
    // 那种情况下补查一次 poll() 完全无害(poll() 自己会核对 bundleIdentifier,见
    // MediaControlClient.fetchSnapshot 的各条分支)。
    private func startObservingPlayerInfoNotification() {
        startStreamWatcher()
        guard playerInfoObserver == nil else { return }
        let center = DistributedNotificationCenter.default()
        let handler: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePlayerInfoChanged() }
        }
        playerInfoObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main, using: handler)
        // Spotify 的这条通知同样"一次操作连发多条、且第一条可能还带着旧状态",所以走
        // 完全相同的 250ms 去抖动补查路径,不需要为它单独调参。
        spotifyInfoObserver = center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main, using: handler)
    }

    // media-control 事件流跟两条分布式通知走**同一条**去抖动补查路径:三个来源都只是
    // "有动静了"的信号,合并成一次 poll() 正是想要的效果(比如 Spotify 换歌会同时触发
    // 它自己的通知和 MediaRemote 的事件,合并后只查一次)。
    private func startStreamWatcher() {
        guard streamWatcher == nil else { return }
        let watcher = MediaControlStreamWatcher { [weak self] in
            MainActor.assumeIsolated { self?.handlePlayerInfoChanged() }
        }
        streamWatcher = watcher
        watcher.start()
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
        freezeExtrapolationUntilNextPoll()
        pendingNotificationPoll?.cancel()
        pendingNotificationPoll = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.playerInfoDebounce)
            guard !Task.isCancelled else { return }
            self?.pendingNotificationPoll = nil
            self?.poll()
        }
    }

    /// 收到"播放器状态有变"的通知之后、真正查到新状态之前,先把位置外推**冻住**。
    ///
    /// ---- 为什么需要它 ----
    ///
    /// 通知在用户按下暂停后 ~116ms 就到了,但我们要等去抖结束(查询落在 ~480ms,理由见
    /// handlePlayerInfoChanged 上面那段实测)才拿得到"确实暂停了"这个事实。这中间外推
    /// 还在按播放速度往前跑,等真相到达时显示位置已经超前了将近半秒 —— 一切到暂停的
    /// 冻结位置(pausedPositionMs 是播放器报的真实值)就往回跳:进度条退一点、时间数字
    /// 倒退一秒、运气不好还跨过一句歌词,歌词跟着"变一下"。
    /// 2026-08-17 用户报的就是这个("为什么有时候暂停的时候进度条会突然回退一点")——
    /// "有时候"正对应那半秒是否恰好跨过一句歌词的边界。
    ///
    /// 冻住之后,误差只剩通知本身那 ~116ms,跳变基本看不出来。
    ///
    /// ---- 为什么这么做是安全的 ----
    ///
    /// rate 置 0 时 extrapolatedPositionMs 直接返回锚点值、不再随时间推进(见
    /// ProgressAnchor),所以"冻结"不需要任何一处 UI 配合,进度条/歌词行照常读 anchor。
    ///
    /// 万一这条通知其实不是暂停(换歌、seek),接下来那次 poll() 会照常重建锚点、位置继续
    /// 走,代价只是这 ~360ms 里进度条没动 —— 而那两个场景本来就要把显示整个重置。
    ///
    /// 从暂停**恢复**播放时 anchor 本来就是 nil,下面的 guard 直接放行,不会误冻。
    ///
    /// ⚠️ 这个冻结锚点靠 apply() 里那句 `needsNewAnchor` 中的 `anchor?.rate != rate`
    /// 被换掉:冻结时 rate 置 0,而播放中的 rate 是 1,两者不等就必然重建锚点。仍在播放
    /// 时走这条(位置继续走),已经暂停则走 `anchor = nil` 那条。**别把 needsNewAnchor
    /// 里的 rate 比较去掉** —— 去掉之后稳定播放期间会认为"不必重锚",这个 rate=0 的锚点
    /// 就永远留在那儿,进度条从此不动。
    private func freezeExtrapolationUntilNextPoll() {
        guard let current = anchor, current.rate > 0 else { return }
        let now = Date()
        anchor = ProgressAnchor(
            durationMs: current.durationMs,
            progressMs: current.extrapolatedPositionMs(now: now),
            rate: 0,
            // 已经把外推结果落成了锚点位置本身,不需要再带任何年龄基准。
            progressTs: nil,
            baseAgeMs: nil,
            fetchedAt: now,
            fresh: current.fresh)
    }

    /// 轮询间隔按播放状态分档(2026-08-20 性能审计):每一拍都要 fork 一个子进程
    /// (media-control 或 osascript),固定 2s 意味着**彻底没在放歌**的机器也一天 fork
    /// 三万多次、常驻 0.5-1% 单核底噪。降速是安全的:三路事件唤醒(AM/Spotify 分布式
    /// 通知 + media-control stream,见 startObservingPlayerInfoNotification)会把
    /// 播放/暂停/换歌的感知拉回亚秒级,慢节拍只是它们全失效时的兜底。
    /// 播放中保持 2s 不动——scrobble 计时、enrich mtime 检查、"还没解析出歌词"的重试
    /// 全搭在这个节拍上,不能慢。
    private enum PollInterval {
        static let playing: TimeInterval = 2
        static let paused: TimeInterval = 6
        static let idle: TimeInterval = 10
    }

    private var currentPollInterval: TimeInterval = PollInterval.playing

    /// 此刻该用的轮询间隔。暂停(有曲目没在放)6s:用户在播放器里拖进度条这类"不发通知
    /// 的静默变化"最坏晚 6s 被兜到,可接受;空闲(连曲目都没有)10s。
    private var desiredPollInterval: TimeInterval {
        if isPlayingNow { return PollInterval.playing }
        return title.isEmpty ? PollInterval.idle : PollInterval.paused
    }

    private func reschedulePollTimer() {
        reschedulePollTimer(interval: PollInterval.playing)
    }

    private func reschedulePollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        currentPollInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// 每拍 poll 末尾调:状态档位变了才重建 Timer(重建本身廉价,但没必要每拍做)。
    /// 事件唤醒(handlePlayerInfoChanged→poll)让"暂停→播放"在下一拍前就被感知,
    /// 感知到的那拍会立刻把节拍调回 2s。
    private func adjustPollCadence() {
        let desired = desiredPollInterval
        if desired != currentPollInterval { reschedulePollTimer(interval: desired) }
    }

    // 只在真的需要时(anchor 非 nil,即正在播放)才保持 20Hz 快速 tick 运行——暂停/
    // 长时间挂起时没有锚点可外推,tick 只会一遍遍把 currentLine/nextLineText 置 nil,
    // 没必要让计时器继续空转。用 fastTimer == nil 判断"已经在跑了"而不是每次 apply()
    // 都无条件重建,避免播放中每 2 秒(poll 周期)就重开一次计时器。
    /// 屏幕锁上时暂停 20Hz 的逐字 tick。
    ///
    /// 锁屏时没有任何人在看歌词,而 fastTick 是这个 App 最热的那条路径(逐字填色要 20Hz)。
    /// ⚠️ 只停这一条:2 秒 poll 必须继续跑,否则锁屏期间听的歌不会被记录、Last.fm /
    /// ListenBrainz 提交会整段丢失 —— 那是不可恢复的数据,省一点电不值当。
    public func setScreenLocked(_ locked: Bool) {
        guard screenLocked != locked else { return }
        screenLocked = locked
        logger.info("screen \(locked ? "locked" : "unlocked", privacy: .public); word-level tick \(locked ? "paused" : "resumed", privacy: .public)")
        if locked {
            stopFastTimer()
        } else if anchor != nil {
            // 解锁时只在"确实还在播"的前提下恢复,判据跟 apply() 里一致(有锚点才需要外推,
            // 且引擎里得有歌词内容 —— 没词的空转档见 apply() 末尾那段注释)。
            if syncEngine.hasContent { ensureFastTimerRunning() }
            fastTick() // 立刻补一帧,别等下一个 50ms
        }
    }

    private func ensureFastTimerRunning() {
        // 锁屏期间一律不起 —— 否则 apply() 每 2 秒会把刚停掉的计时器又拉起来。
        guard !screenLocked else { return }
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
            // 没有可显示的行,间奏点和"填色未定格"也一并归位 —— 别让上一首歌的残留值
            // 挂着(fillSettled 归 true:没有行就没有可动的填色,表该停着)。
            if currentGapIndex != nil { currentGapIndex = nil }
            if !currentLineFillSettled { currentLineFillSettled = true }
            return
        }
        // 打包查询:四个值要的是同一个 posMs 的同一次定位,原来四个入口各自从头扫一遍
        // (2026-08-20 性能审计,见 LyricsSyncEngine.tickQuery)。
        let r = syncEngine.tickQuery(atMs: frozen)
        if r.line != currentLine { currentLine = r.line }
        if r.nextText != nextLineText { nextLineText = r.nextText }
        if r.index != currentLineIndex { currentLineIndex = r.index }
        if r.gapIndex != currentGapIndex { currentGapIndex = r.gapIndex }
        updateLineFillSettled(line: r.line, atRawMs: frozen)
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
        // 打包查询(2026-08-20 性能审计):当前行/下一句/行下标/间奏下标要的是同一个 pos 的
        // 同一次定位,原来四个入口各自独立扫一遍数组(原注释"这个量级完全可以忽略"没错,
        // 但 tickQuery 让下标只算一次、还带单调窗口记忆化,调用方也从四行收敛成一次调用)。
        // "只在真的变化时才赋值"的规则原样保留 —— 这四个是 @Published,SwiftUI 不管新旧值
        // 是否相等,只要赋值就会通知订阅者重新渲染,而绝大多数 tick 其实还是同一行。
        let r = syncEngine.tickQuery(atMs: pos)
        if r.line != currentLine { currentLine = r.line }
        if r.nextText != nextLineText { nextLineText = r.nextText }
        if r.index != currentLineIndex { currentLineIndex = r.index }
        if r.gapIndex != currentGapIndex { currentGapIndex = r.gapIndex }
        updateLineFillSettled(line: r.line, atRawMs: pos)
    }

    /// 见 currentLineFillSettled 的注释。阈值(该行从哪一毫秒起定格)是纯数值,算法在
    /// KaraokeFill.lineFillSettledMs(selftest 覆盖);这里只负责跟填色视图同一个时间基准
    /// 比较 —— 视图的 currentMs = 外推位置 + offsetMs(见 LyricsOverlayView.mainLine),
    /// 词的时间戳是歌词原始时间轴,所以这里同样要加 offsetMs 再比。
    // 阈值是**行级常量**(只由词/组的时间轴决定),原来每个 tick 都对全行词+组重算一遍
    // O(词数)浮点循环(2026-08-20 性能审计)——按行记忆化:引擎的行是按下标记忆化的同一
    // 实例,`==` 走同一性快路径,换行才真的重算一次,tick 退化为一次整数比较。
    private var settledThresholdLine: SyncedLyricLine?
    private var settledThresholdMs = 0

    private func updateLineFillSettled(line: SyncedLyricLine?, atRawMs rawMs: Int) {
        let settled: Bool
        if let words = line?.words {
            if line != settledThresholdLine {
                settledThresholdLine = line
                settledThresholdMs = KaraokeFill.lineFillSettledMs(words: words, groups: line?.wordGroups)
            }
            settled = rawMs + syncEngine.offsetMs >= settledThresholdMs
        } else {
            settled = true
            settledThresholdLine = nil
        }
        if settled != currentLineFillSettled { currentLineFillSettled = settled }
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
            lyricsGapMarkers = []
            currentGapIndex = nil
            if !currentLineFillSettled { currentLineFillSettled = true }
            artworkData = nil
            artworkAverageHex = nil
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
            // ⚠️ 等值闸快照必须一起失效:上面把 allLines 等发布状态清空了,而引擎/缓存文件
            // 里的内容还是原样 —— 不失效的话,同一首歌再次播放时 reloadCurrentLyrics 会被
            // 内容等值闸吞掉,allLines 永远回不来(闸只保证"引擎状态不用重算",保证不了
            // "发布状态还在")。
            lastReloadSnapshot = nil
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
            // 位置追踪的私有状态也要一起断链(2026-08-20 对抗审查抓出):不清的话,
            // "上一首还在播"这份陈旧状态会一直活着,中断(焦点被抢/退出/stopped)之后
            // 另起的一首歌若恰好落进自然切歌窗口(|overrun|≤4 且假偏置落 (0.05,2.5]),
            // 会被伪判成 gapless 自然切歌、种下最多 2.5s 的假偏置且整曲不自愈——改动前
            // 换歌分支无条件采信读数,这份陈旧状态才是无害的。与 collector 侧
            // updatePosition 的 key=="" 分支清理对齐。
            posWasPlaying = false
            posPrevWall = nil
            posPrevDurationSecs = 0
            posReportedBiasSecs = 0
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
                self.adjustPollCadence()
                return
            }
            // isMusicApp 现在直接由 MediaControlClient 硬编码为 true(只在真的问到
            // Music.app 自己的当前曲目时才会返回非 nil 快照,不再是系统级 Now Playing
            // 焦点判断)——这个 guard 留着只是保持跟旧版同一套代码路径,不删这一步的
            // 保险性质。
            guard snapshot.isMusicApp == true else {
                logger.debug("snapshot ignored: not Apple Music (isMusicApp=\(String(describing: snapshot.isMusicApp)))")
                clearIfWasPlaying()
                self.adjustPollCadence()
                return
            }
            logger.debug("snapshot ok: playing=\(snapshot.playing == true)")
            self.apply(snapshot)
            // 状态落定后按播放态调轮询档位(播放 2s/暂停 6s/空闲 10s,见 PollInterval)。
            self.adjustPollCadence()
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
        // 停播欢迎态的「继续播放/打开 XX」要知道停播前在用谁、放的什么 —— 停播时快照
        // 整个清空,这里是唯一还记得的地方(见 LyricsWindowView.idleWelcomeView)。落
        // UserDefaults,只在值变化时写,2 秒轮询不刷盘。
        let bid = snapshot.bundleIdentifier ?? ""
        if !bid.isEmpty, !newTitle.isEmpty, bid != lastPersistedPlayerBundleID {
            UserDefaults.standard.set(bid, forKey: "np:lastPlayerBundleID")
            lastPersistedPlayerBundleID = bid
        }
        if !newTitle.isEmpty, newTitle != lastPersistedTrackTitle {
            UserDefaults.standard.set(newTitle, forKey: "np:lastTrackTitle")
            UserDefaults.standard.set(newArtist, forKey: "np:lastTrackArtist")
            lastPersistedTrackTitle = newTitle
        }
        // Spotify 广告插播判断(2026-08-19 重做:字段启发式 + 同曲棘轮 + AppleScript 权威)。
        // 老版本每一拍按"当下字段"重判 —— 实测广告字段会**闪变**(开播 album 空、几拍后
        // 补齐,Blinds.com 实锤),看走眼的那几拍 UI 会退回"歌名 + 搜索歌词中"。现在:
        // 换曲那一拍按加宽的启发式(album 空/artist 空/标题「—」,与 collector isAdBreak
        // 同款)定初值,同曲期间只往 true 棘轮、不回落;是 Spotify 就再异步问一次本尊
        // (`spotify url` 前缀是权威分类,广告可以带全 artist/title/album 骗过启发式),
        // 结果回来仍是这首才采纳。judge 与 collector 两侧口径一致,那边管上报,这边管 UI。
        let isSpotify = snapshot.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier
        let adByFields = isSpotify && !newTitle.isEmpty
            && (newAlbum.isEmpty || newArtist.isEmpty || newTitle == "—")
        if snapshot.trackKey != lastKey {
            if isCurrentTrackAdBreak != adByFields { isCurrentTrackAdBreak = adByFields }
            if isSpotify, !adByFields { verifySpotifyAdViaAppleScript(forKey: snapshot.trackKey) }
        } else if adByFields, !isCurrentTrackAdBreak {
            isCurrentTrackAdBreak = true
        }

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

        // 每拍先让 Reader 推进内容(mtime 变了在后台解码,见 refreshIfNeeded 注释),触发
        // 键用**已解码代**的版本而不是文件即时 mtime——stale 返回窗口里拿文件 mtime 触发
        // 会提前吃掉这次变化,后台解码完成后就再没有东西触发 reload 了(2026-08-20)。
        EnrichCacheReader.refreshIfNeeded()
        let enrichMTime = EnrichCacheReader.decodedContentVersion
        if trackChanged || !syncEngine.hasContent || enrichMTime != lastEnrichMTime {
            if trackChanged {
                logger.info("track changed: \(snapshot.artist ?? "", privacy: .public) - \(snapshot.title ?? "", privacy: .public)")
            }
            lastKey = key
            lastEnrichMTime = enrichMTime
            reloadCurrentLyrics()
        }
        // 换了播放器也要重算偏移 —— 上面那个 reload 的触发条件是「换歌 / 没内容 / 缓存变了」,
        // **不含**"播放器变了"。而 trackKey 只由 歌手|歌名 决定:.auto 档下焦点在两个 App 之间
        // 切、或两个播放器放同名曲目时,曲目没"变"、内容也在,于是 applyOffsets 不跑,新播放器
        // 会继续套用**上一个播放器**那一档 —— 正是"把浏览器的补偿套到 Apple Music 上"这个
        // effectiveOffset 注释里明写要防的形态(2026-08-21 加播放器维度时发现)。
        //
        // 放在 reload 判断之后:换歌那一支已经经 reloadCurrentLyrics → applyOffsets 算过一遍,
        // 这里只补"没换歌但换了播放器"这一种情况,不重复跑。
        let bundleID = snapshot.bundleIdentifier
        if bundleID != lastAppliedBundleID {
            lastAppliedBundleID = bundleID
            if !trackChanged, syncEngine.hasContent { applyOffsets() }
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
            // 切歌/加载瞬间 Spotify 会短暂报 rate=0(playing 仍 true),按 1 计——与
            // collector 的 reconcile 规则一致。不归一的话 predicted 停走,下一拍正常
            // 前进的读数会被误判成 seek 跳变,顺手把自然切歌偏置也清了(2026-08-20
            // 对抗审查抓出)。真暂停走的是下面的 else 分支,不经过这里。
            var rate = snapshot.playbackRate ?? 1
            if rate <= 0 { rate = 1 }
            // 数据源三档画像(见 PositionSourceTier):Apple Music=AppleScript 播放头
            // (precise);Spotify=干净的 media-control 外推(cleanExtrapolated,
            // 2026-08-18 实测拆档——此前 08-14~08-18 走 JXA 直查、连修三轮仍不准已撤,
            // 撤掉后又被 noisyFloored 档的 1.0s 大门槛养出"整曲偏快",见枚举注释和
            // MediaControlClient.fetchRawMediaControlSnapshot 的决策注释);QQ 音乐/
            // 网易云=整秒下取整带抖动(noisyFloored)。各档伺服参数见 servoDecision。
            let tier = Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier)
            let (positionSeconds, didReanchor) = resolvePositionSeconds(reported: snapshot.elapsedTime ?? 0, rate: rate, key: key, now: now, tier: tier)
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
            // 暂停态里换了曲目(暂停中点了另一首):没有走 resolvePositionSeconds,自然
            // 切歌偏置的归零要在这里补上——新曲的冻结位置是新锚点的值,跟旧偏置无关。
            if key != posTrackingKey, posReportedBiasSecs != 0 { posReportedBiasSecs = 0 }
            // 暂停中用户在播放器里拖了进度条:冻结值跳变 = Spotify 已重打对齐真声的
            // 锚点,旧偏置作废(见 posPausedRawSecs 注释)。我们自己 UI 里的暂停拖动走
            // seek(toMs:),那边已经清过,这里再看到的跳变清一次也只是幂等。
            let frozenRaw = snapshot.elapsedTime ?? 0
            if let prev = posPausedRawSecs, abs(frozenRaw - prev) > Self.seekJumpToleranceSecs,
               posReportedBiasSecs != 0 {
                posReportedBiasSecs = 0
            }
            posPausedRawSecs = frozenRaw
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
            // 冻结的 elapsedTime 带着同一个超前锚点的值——自然切歌偏置在暂停态同样要扣
            // (不扣的话,暂停看歌词那一眼恰恰是偏快 ~0.9s 的)。
            let reported = max(0, (snapshot.elapsedTime ?? 0) - posReportedBiasSecs)
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
        // 自然切歌判定要用"旧曲"的时长/来源——resolve 被调用时 snapshot 已是新曲,所以
        // 这里每轮把本轮的存下来,下一轮它们就是"上一首的"。
        posPrevDurationSecs = snapshot.duration ?? 0
        posPrevTierCleanExtrapolated =
            Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier) == .cleanExtrapolated
        if playing, posPausedRawSecs != nil { posPausedRawSecs = nil }
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
        } else if syncEngine.hasContent {
            ensureFastTimerRunning()
        } else {
            // 在播、但引擎里没有任何歌词内容(纯音乐/广告/还没解析出来):每一拍 fastTick
            // 的四个查询都扫空数组、四个守卫全不触发,20Hz 定时器整首歌空转纯属浪费 ——
            // 暂停(上面)和锁屏(setScreenLocked)都已特判掉这种空转,这里补上"在播但
            // 没词"这一档。先补最后一拍把可能残留的行状态清掉再停表;collector 中途解析
            // 出歌词会改 enrich 文件 mtime,上面 reloadCurrentLyrics 那个分支会让下一轮
            // apply(≤2s)重新走到 hasContent 分支拉起定时器。
            fastTick()
            stopFastTimer()
        }
    }

    // 供外部(EnrichCacheStore 保存/删除歌词后)强制重新读取当前曲目的歌词——正常情况
    // apply() 只在换歌那一刻才 reloadCurrentLyrics(),同一首歌播放中途改了缓存内容
    // 不会自动重新读。本地模式的 EnrichCacheReader 每次都是直接读磁盘文件,写完盘立刻
    // 调用这个就能拿到最新内容,不需要等 collector 重启。
    public func forceReloadLyricsForCurrentTrack() {
        // 用户显式操作(保存/删除歌词)必须立刻读到刚写的内容——同步重解,别等后台
        // 世代号那条慢路径(见 EnrichCacheReader.reloadNow 注释);版本同步推进,免得
        // 下一拍 poll 按版本差再白跑一次 reload(等值闸也会挡,这里省得它挡)。
        EnrichCacheReader.reloadNow()
        lastEnrichMTime = EnrichCacheReader.decodedContentVersion
        reloadCurrentLyrics()
        // 20Hz 定时器在"在播但没词"时是停着的(见 apply() 末尾)——刚保存进来的歌词若让
        // hasContent 从无到有,这里得立刻拉起,不能干等下一轮 2s 轮询;fastTick 无条件补
        // 一拍,让当前行马上按新内容解出来(暂停态走 anchor==nil 分支,同样立即生效)。
        if anchor != nil, syncEngine.hasContent { ensureFastTimerRunning() }
        fastTick()
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
        // 我们主动发的 seek 同样会让 Spotify 重打锚点(与真声对齐)——自然切歌偏置作废。
        posReportedBiasSecs = 0
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
        guard lastSnapshot != nil else { return trackLyricsOffsetMs }
        LyricsOffsetStore.shared.nudge(by: deltaMs, forKey: currentOffsetKey, pinKey: currentPinKey)
        applyOffsets()
        // 返回**这首歌**那部分,不是总和:调用方(快捷键的提示条、菜单标题)说的是
        // "这首歌调到了多少",全局基准不该混进那个数字里。
        return trackLyricsOffsetMs
    }

    public func resetLyricsOffset() {
        guard lastSnapshot != nil else { return }
        // 只清这首歌的微调。全局基准是设备侧的固定延迟,跟"这首歌歌词准不准"是两件事,
        // 被一次「重置」连带抹掉的话,用户得回设置里重新调一遍(见 LyricsOffsetStore
        // .globalOffsetMs 的注释)。
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey, pinKey: currentPinKey)
        applyOffsets()
    }

    /// 改全局基准(设置页那个控件)。所有歌都受影响,正在播的这首立刻跟上。
    public func setGlobalLyricsOffset(_ ms: Int) {
        LyricsOffsetStore.shared.setGlobalOffset(ms)
        guard lastSnapshot != nil else { return }
        applyOffsets()
    }

    /// 改某个播放器那档(设置页那个下拉框选中具体播放器时的控件)。只有当前正在播的**恰好
    /// 就是它**时才需要立刻重算 —— 改别的播放器的档位对眼下这首歌没有任何影响,白跑一次
    /// applyOffsets 会顺带把两个 @Published 推一遍。
    ///
    /// 2026-08-18 那个同名入口是内部为 Spotify 写死的补偿,08-20 随根修一起删了;这次是
    /// 用户显式配置的那一层,语义不同(见 LyricsOffsetStore.playerOffsets)。
    public func setPlayerLyricsOffset(_ ms: Int, forBundleID bundleID: String) {
        LyricsOffsetStore.shared.setPlayerOffset(ms, forBundleID: bundleID)
        guard lastSnapshot?.bundleIdentifier == bundleID else { return }
        applyOffsets()
    }

    /// 把「全局基准 + 这个播放器那档 + 这首歌的微调」算出来灌进引擎,并把两个对外属性刷成一致。
    ///
    /// 所有入口(换歌词内容、nudge、reset、改全局基准/从 store 重读)都走这里。
    /// 原来它们各自赋两次值,加了全局基准之后每处都要多算一步 —— 分散写迟早漏掉一处,而
    /// 漏掉的表现是"某条路径下全局偏移不生效",只在特定操作顺序下复现,极难归因。
    private func applyOffsets() {
        let track = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey)
        // 存量补钉 —— pin 机制上线前调好的歌在这里才第一次被钉住(见那个方法的注释)。
        // 幂等,已经钉住时是纯内存判断。
        LyricsOffsetStore.shared.backfillPinIfNeeded(forKey: currentOffsetKey, pinKey: currentPinKey)
        // 播放器那层按**这一刻真正在播的那个 App** 算。拿不到身份(还没有快照)时传 nil,
        // 那层就按 0 算 —— 绝不能猜一个,否则会把浏览器的补偿套到 Apple Music 上。
        let effective = LyricsOffsetStore.shared.effectiveOffset(
            forKey: currentOffsetKey, bundleID: lastSnapshot?.bundleIdentifier
        )
        syncEngine.offsetMs = effective
        // 对外报的是**引擎真正在用的那个数**,含这份歌词自己带的 `[offset:]`
        // (`syncEngine.lrcOffsetMs`,见 LRCParser.parseOffsetMs)。
        //
        // ⚠️ 必须含它:这个属性的唯一用途是"把歌词时间轴换算到播放位置",而歌词窗口点某一行
        // 反算 seek 目标用的就是 `行时间 − currentLyricsOffsetMs`。漏掉 LRC 那一层的话,带
        // 非零 offset 的歌点行会跳到隔壁行 —— 正是这个属性当初存在的理由(注释见上面)。
        // 用户可见的那两个数(设置页的基准、菜单里的单曲值)都不含它,那是对的:LRC offset
        // 不是用户调出来的,不该出现在"你调了多少"里。
        let effectiveWithLRC = effective + syncEngine.lrcOffsetMs
        // 只在真的变了时才赋值:这两个都是 @Published,每次赋值都会推着订阅者重渲染,
        // 而 reloadCurrentLyrics 在"歌词还没解析出来"时会被反复调用(见那边的注释)。
        if currentLyricsOffsetMs != effectiveWithLRC { currentLyricsOffsetMs = effectiveWithLRC }
        if trackLyricsOffsetMs != track { trackLyricsOffsetMs = track }
    }

    // 供"歌词管理"窗口的偏移输入框用——那边直接写 LyricsOffsetStore(不经过
    // nudge/reset,是敲一个具体数值),写完之后调这个让当前正在播的这首歌(如果编辑的
    // 恰好就是它)立刻用上新值,不用等下次换歌。跟别的歌词内容(key 对不上当前曲目)
    // 无关时,这里只是把 currentOffsetKey 对应的值重新读一遍、原样赋回去,是个安全的
    // 空操作。
    public func refreshOffsetFromStore() {
        guard lastSnapshot != nil else { return }
        applyOffsets()
    }

    // 跟 syncEngine 实际加载的歌词内容(lyrics+lyricsYRC)绑在一起算出来的 key——见
    // reloadCurrentLyrics() 里怎么算的。只在换歌词内容那一刻更新一次,nudge/reset 直接
    // 复用,不用每次都重新拼一遍(也保证跟当初读校正值时用的是同一个 key)。
    private var currentOffsetKey = ""

    // 同一首歌在 LyricsPinStore 里的身份 —— 归一化的 enrich key(artist|title|album),
    // **不含**歌词内容指纹。两个 key 各管一件事:上面那个决定"这份校正值属于哪一份歌词
    // 内容",这个决定"哪首歌不许后台再换歌词源"。内容指纹恰恰是会变的那一半,拿它当 pin
    // 的身份等于"内容一换 pin 也失效",正好把要防的事情放过去(见 LyricsPinStore)。
    private var currentPinKey = ""

    /// 上一次读缓存时那个文件的 mtime。变了就说明 collector 又写过,当前这首歌的内容可能
    /// 已经不是手上这一份了(见 apply() 里那段注释)。
    private var lastEnrichMTime: Date?

    /// reloadCurrentLyrics 的**全部**会影响引擎装载/派生状态的输入快照。相等 ⇒ 整段重算
    /// (简繁转换×3 + 引擎 load + allLines/gapMarkers 重建)可以跳过。
    /// ⚠️ trackKey 必须在里面:两首都没有歌词的歌五个字段全空相等,不带曲目身份的话
    /// 换歌会被闸误吞,currentOffsetKey/applyOffsets/allLines 的 idPrefix、以及 load 的
    /// 抬头识别(trackTitle/trackArtist)全部停留在上一首,偏移校正会串歌。
    private struct LyricsReloadSnapshot: Equatable {
        let trackKey: String
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let instrumental, resolved: Bool
        let variant: ChineseVariant
        let preferWordLevel: Bool
        let romanizationScripts: RomanizationScripts
    }
    private var lastReloadSnapshot: LyricsReloadSnapshot?

    private func reloadCurrentLyrics() {
        guard let snapshot = lastSnapshot else { return }
        let found = EnrichCacheReader.lookup(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            album: snapshot.album ?? ""
        )
        // 见过中文歌词就记一笔(粘性,只置不清)。判据跟 ChineseVariant.converted 一致:
        // 有汉字、且没有假名(有假名是日文)。刻意放在下面的等值闸**之前**——闸命中早退
        // 时这个粘性位也必须照常置位。
        let raw = found?.lyrics ?? ""
        if !sawChineseLyrics, Romanizer.containsHan(raw), !Romanizer.looksJapanese(raw) {
            sawChineseLyrics = true
        }
        // 内容等值闸(2026-08-20 性能审计):失效键是整个 enrich 缓存文件的 mtime,collector
        // 给**别的歌**写盘(专辑预取最多 30 首逐个落盘/译文回填/重打分)都会带着一字未变的
        // found 走到这里 —— 原来每次都白跑简繁转换×3 + 全套解析过滤 + 整曲罗马音/分词重算
        // + allLines/gapMarkers 重建,单次 10-50ms 主线程,正撞上 30Hz 填色渲染。快照含
        // resolved/instrumental:它们翻转("搜索中"→"确实没有")时快照必不相等,不会被
        // 闸吞掉;比较用 String ==(mtime 已变时 lookup 是新解码实例,引用比较必 miss,
        // 别指望它)。⚠️ 闸只跳"重算",不跳上面的粘性置位;闸后的 found 派生赋值
        // (hasLyricsContent 等)在快照相等时算出来的必然是同值,skip 无害。
        let reloadSnapshot = LyricsReloadSnapshot(
            trackKey: "\(snapshot.artist ?? "")|\(snapshot.title ?? "")|\(snapshot.album ?? "")",
            lyrics: raw,
            lyricsTr: found?.lyricsTr ?? "",
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: found?.lyricsYRC ?? "",
            instrumental: found?.instrumental ?? false,
            resolved: found?.resolved ?? false,
            variant: chineseVariant,
            preferWordLevel: preferWordLevelKaraoke,
            romanizationScripts: romanizationScripts)
        if reloadSnapshot == lastReloadSnapshot {
            logger.debug("lyrics reload skipped: content unchanged (mtime-only churn)")
            return
        }
        lastReloadSnapshot = reloadSnapshot
        // 简繁转换只作用在展示上:正文、译文、逐字数据都转,罗马音是拉丁字母不用转。
        // 逐字数据整串转是安全的 —— 时间戳是数字,转换只碰汉字。
        let variant = chineseVariant
        // 引擎侧还有第二道指纹早退(见 LyricsSyncEngine.load 注释),两道闸各管一层:这里
        // 管"连转换都别做",那里兜"其它调用方/清过发布状态后的重灌"。
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
        // ⚠️ 必须走 EnrichCacheKeys.normalizedKey,不能拿播放器报的原始三段自己拼:
        // 「歌词管理」那边的 pinKey 是缓存 key 本身(已归一化),两边不一致的话,在管理页
        // 校准的歌跟播放时钉住的歌就是两个身份 —— 而歌名带结尾译名括号的曲目(实测这台
        // 机器 2483 首里 111 首,4.5%)恰好都落在这个差异上。
        currentPinKey = EnrichCacheKeys.normalizedKey(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            album: snapshot.album ?? ""
        )
        applyOffsets()
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
        // 间奏点跟 allLines 同一时机重算 —— 纯由时间轴决定,同一首歌播放期间不变。
        let newMarkers = syncEngine.gapMarkers()
        if newMarkers != lyricsGapMarkers { lyricsGapMarkers = newMarkers }
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
            self.artworkAverageHex = nil
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

    // 首轮定案后隔这么久再确认一次。防的是首轮抓到"新标题+旧封面"的合体载荷:识别
    // 陈旧封面靠的是载荷自带的 artist/title(见 fetchArtwork 的 trackKey 注释),但如果
    // 系统侧是先换了标题、封面字段晚一拍才刷,这份陈旧就带着**新歌**的标识,首轮的比对
    // 拦不住。等 3 秒(系统侧封面到这时一定刷完了,量级参考 artworkRetryDelays 的实测)
    // 再取一次,拿到不同的字节就换上——顺带把"播放器中途升级封面"(网易云先给占位图、
    // 匹配到曲库后换真图)这类正常更新也接住了。只在确认结果**非空且属于这首歌**时才动,
    // 一次瞬时的读取失败不该把已经挂好的封面抹掉。
    private static let artworkConfirmDelay: TimeInterval = 3

    /// 封面载荷的曲目标识和当前曲目是否算同一首。大小写不敏感:media-control 对同一首歌
    /// 报过大小写不一致的元数据(enrich 缓存那边为 "2 Bad"/"Scream" 踩过,见相应 memory),
    /// 这里按大小写敏感比对的话,那类歌会被误判成"别的歌的封面"而永远显示占位。
    public nonisolated static func artworkKeyMatches(_ payloadKey: String, _ expectedKey: String) -> Bool {
        payloadKey.compare(expectedKey, options: [.caseInsensitive]) == .orderedSame
    }

    private func fetchArtworkForCurrentTrack(expectedKey: String) {
        Task {
            // 取图和算平均色都在同一个后台 Task.detached 里做完——两者共用同一份原始
            // 图片字节,没必要为了"少写一个函数"分成两次异步往返各自触发一次 MainActor
            // 跳转。computeAverageHex 是 nonisolated 的纯函数,可以在这个非 MainActor 的
            // 闭包里直接调用。
            // 取图不再顺手预算均值色(2026-08-20 性能审计):重试打满 key 不匹配、confirm
            // 拿到相同字节这些**注定丢弃**的路径上,预算的取色纯属白烧;改成确定采纳那一刻
            // 再算一次(仍在后台,见 hexFor)。
            func attempt() async -> (data: Data?, payloadKey: String?) {
                await Task.detached { () -> (Data?, String?) in
                    guard let result = MediaControlClient.fetchArtwork() else { return (nil, nil) }
                    return (result.data, result.trackKey)
                }.value
            }
            func hexFor(_ data: Data?) async -> String? {
                guard let data else { return nil }
                return await Task.detached { Self.computeAverageHex(from: data) }.value
            }
            // "这一把算不算定案":拿到了图,且载荷标识对得上这首歌。没拿到图 = 系统侧封面
            // 还没更新完(见 artworkRetryDelays 的注释);拿到了但标识对不上 = 系统侧整个
            // Now Playing 条目还是上一首的,这份图是**上一首的封面**,同样按"还没更新完"
            // 重试,绝不能直接挂上(2026-08-17 用户报网易云云盘歌沿用上一首封面)。
            func isFinal(_ data: Data?, _ payloadKey: String?) -> Bool {
                guard data != nil, let payloadKey else { return false }
                return Self.artworkKeyMatches(payloadKey, expectedKey)
            }
            var (data, payloadKey) = await attempt()
            // 没定案就重试几次。每次重试前都重新核对 expectedKey——期间用户可能又切了
            // 下一首,那就直接放弃这一轮,交给新那一轮自己去取。
            var round = 0
            while !isFinal(data, payloadKey), round < Self.artworkRetryDelays.count {
                guard expectedKey == self.lastKey else { return }
                // 把兜底清理往后推一轮,理由见 artworkRetryDelays 上面那段注释。
                self.scheduleArtworkStaleTimeout(forKey: expectedKey)
                try? await Task.sleep(for: .seconds(Self.artworkRetryDelays[round]))
                guard expectedKey == self.lastKey else { return }
                (data, payloadKey) = await attempt()
                round += 1
            }
            guard expectedKey == self.lastKey else { return }
            if let payloadKey, data != nil, !Self.artworkKeyMatches(payloadKey, expectedKey) {
                // 重试打满仍是别的歌的封面:宁可占位也不挂错图。留一条 info 日志——万一
                // 两条路径的元数据出现系统性偏差(同一首歌两个 key 恒不相等),这里会对
                // 每首歌都触发,靠日志能一眼定位。
                logger.info("artwork payload key mismatch after retries: payload=\(payloadKey, privacy: .public) expected=\(expectedKey, privacy: .public), dropping")
                data = nil
            }
            // 结果定案了(data 仍为 nil = 重试完还是没有,判定这首歌确实没有封面),
            // 兜底任务**先**撤掉再去取色 —— 取色那次 await 有几十毫秒,3s 兜底在最后
            // 一次尝试逼近期限时可能正落在这个窗口里开火,把旧封面清掉又立刻被新封面
            // 覆盖,白闪一跳(对抗核实抓出的时序窗)。
            self.artworkStaleTimeoutTask?.cancel()
            self.artworkStaleTimeoutTask = nil
            // 定案才取色(后台),丢弃路径一次都不算。
            let averageHex = await hexFor(data)
            guard expectedKey == self.lastKey else { return }
            self.artworkData = data
            self.artworkAverageHex = averageHex
            logger.debug("artwork fetched: bytes=\(data?.count ?? 0) retries=\(round) average=\(averageHex ?? "nil")")

            // 二次确认,理由见 artworkConfirmDelay 的注释。
            try? await Task.sleep(for: .seconds(Self.artworkConfirmDelay))
            guard expectedKey == self.lastKey else { return }
            let confirm = await attempt()
            guard expectedKey == self.lastKey else { return }
            guard let confirmData = confirm.data, let confirmKey = confirm.payloadKey,
                  Self.artworkKeyMatches(confirmKey, expectedKey),
                  confirmData != self.artworkData else { return }
            // 先比完字节确认真的要换,才算这一份的均值色(原来 attempt 顺手预算,字节相同
            // 丢弃的常态路径每次白算一遍取色)。
            let confirmHex = await hexFor(confirmData)
            guard expectedKey == self.lastKey else { return }
            logger.debug("artwork confirm pass replaced cover: bytes=\(confirmData.count)")
            self.artworkData = confirmData
            self.artworkAverageHex = confirmHex
        }
    }

    // 从封面原始图片数据算出一个单一的平均色,供"跟随封面"外观模式当动态高亮色用——
    // 算法跟同类开源实现(Karacookie 的 DominantColor.swift)一致:CIAreaAverage 把
    // 整张图平均成一个像素,而不是 K-means/直方图那类更贵的聚类算法,对"给悬浮歌词提供
    // 一个跟封面基调呼应的强调色"这个用途完全够用。
    //
    // ⚠️ 这里**只求均值,不做任何亮度调整**。2026-08-17 之前它顺手调了 brightenedAccent,
    // 结果是桌面悬浮歌词也吃到了那条为灵动岛(永远深底)定的"保证够亮"地板 —— 见
    // artworkAverageHex 和 accentAgainstStroke 的注释。提亮/压暗按消费面各自处理。
    //
    // nonisolated:纯函数,不读写这个类的任何 @MainActor 隔离状态,允许从
    // fetchArtworkForCurrentTrack() 里的后台 Task.detached 闭包(非 MainActor)直接调用,
    // 不需要为了调用它专门跳回主线程再跳出去。
    nonisolated private static func computeAverageHex(from data: Data) -> String? {
        guard let ciImage = CIImage(data: data) else { return nil }
        return computeAverageHex(ciImage: ciImage)
    }

    /// CGImage 入口——给已经解码好的图用(PlaybackCoordinator 的高清封面是下载回来的
    /// NSImage,拿不到原始字节,没必要为了走 Data 入口再编码一遍)。
    public nonisolated static func computeAverageHex(cgImage: CGImage) -> String? {
        computeAverageHex(ciImage: CIImage(cgImage: cgImage))
    }

    // CIContext 创建不便宜(实测 ~15ms)且线程安全,进程级复用一个 —— 跟
    // PlaybackCoordinator.blurBakeContext 同一个理由/写法(2026-08-20 性能审计,
    // 原来每次取色都新建一个,每次换歌 2 次左右纯属重复)。
    nonisolated(unsafe) private static let averageHexContext =
        CIContext(options: [.workingColorSpace: NSNull()])

    nonisolated private static func computeAverageHex(ciImage: CIImage) -> String? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }
        // 不指定 workingColorSpace ——只是要把一整张图迅速塌缩成一个像素
        // 的均值,不需要色彩管理带来的准确性,换来的是渲染更快。
        let context = averageHexContext
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return String(
            format: "#%02X%02X%02XFF", Int(bitmap[0]), Int(bitmap[1]), Int(bitmap[2]))
    }

    /// 把封面均值色调整成"能当文字色用"的亮度。纯函数,selftest 直接覆盖。
    ///
    /// ⚠️ 2026-08-17 起这条规则**只服务于永远深色的表面**(灵动岛)。它保证的是"够亮",
    /// 而桌面悬浮歌词压在壁纸/任意窗口上,"够亮"在浅色背景下正好是最坏的选择 ——
    /// 那一侧改走 accentAgainstStroke,见那里的注释。
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

    /// 在 brightenedAccent 的结果之上,再保一道**感知亮度**(Rec.709 luma)下限——
    /// 专供永远深色背景的表面(灵动岛:纯黑/深色渐变/封面模糊+压黑,三种风格全是暗的)。
    ///
    /// 为什么 brightenedAccent 不够:它保的是 HSB 的 brightness(= RGB 最大分量),
    /// 而人眼对三个通道的敏感度差一个数量级(绿 0.7152 vs 蓝 0.0722)——一个饱和纯蓝
    /// brightness 满格 1.0、luma 却只有 0.07,原样通过 0.62 的地板,贴在深色背景上
    /// 就是"看得见但区分度差"。冷色(蓝/紫/深红)封面全中这一条。
    ///
    /// 提法是朝白色线性混合:luma 随混合比例线性上升,可以解析地一步到位;混白天然
    /// 保色相族、按比例减饱和,跟 brightenedAccent"提亮多少就压淡多少"是同一个哲学。
    /// 桌面悬浮歌词**不要**用这个——壁纸可能是浅色,朝白提亮反而毁掉那边的对比度。
    ///
    /// luma 用 gamma 空间的 Rec.709 加权近似感知明度,对"设一个下限"这个用途足够,
    /// 不值得为它引入 sRGB 线性化。
    nonisolated public static func accentForDarkBackdrop(
        r: Double, g: Double, b: Double, lumaFloor: Double = 0.62
    ) -> (r: Double, g: Double, b: Double) {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luma < lumaFloor, luma < 1 else { return (r, g, b) }
        // luma(c + t*(1-c)) = luma(c) + t*(1-luma(c)),反解出恰好到地板的 t。
        let t = min(1, max(0, (lumaFloor - luma) / (1 - luma)))
        return (r + t * (1 - r), g + t * (1 - g), b + t * (1 - b))
    }

    // MARK: - 桌面悬浮歌词的封面取色(跟描边拉开对比)

    /// 把封面均值色调成"在描边包围下一定看得清"的文字色。桌面悬浮歌词专用,纯函数。
    ///
    /// ### 为什么不能沿用 brightenedAccent
    ///
    /// 那条规则保证"够亮",前提是背景永远深(灵动岛)。桌面悬浮歌词压在壁纸和任意窗口上,
    /// 背景可能是任何颜色 —— 2026-08-16 起近黑封面被兜底成 0.72 的浅灰,用户又开着不透明
    /// 白描边,于是浅灰字被白描边整个吃掉,压在浅色窗口上几乎看不见(实测:屏幕上最暗的
    /// 不透明像素 #ADABA6,相对亮度 0.671,而描边是纯白)。同一张近黑封面在 08-16 之前
    /// 算出来是 #160B21,深字配白边非常清楚 —— 这次回归就是那条地板漏到了这一侧。
    ///
    /// ### 判据换成"跟描边的对比度"
    ///
    /// 描边是紧贴字形外沿的那一圈,字**直接相邻**的永远是它,不是背景 —— 字幕类显示靠
    /// 描边在任意背景上都能读,正是这个道理。所以这一侧要保证的不是"够亮"而是"跟描边
    /// 够对比":只要这一条成立,背景是白墙纸还是黑墙纸都不影响可读性。
    ///
    /// 对比度用 WCAG 的定义(相对亮度做 sRGB 线性化后取 (L₁+0.05)/(L₂+0.05))。这里
    /// **要**做线性化,跟 accentForDarkBackdrop 里那句"设个下限用 gamma 空间近似就够"
    /// 不一样 —— 那边只要一个单调的阈值,这边要的是两色之间的真实可读性判据。
    /// 默认 3.0 取 WCAG 对**大号文字**的门槛,歌词字号(默认 31pt 粗体)远在其上。
    ///
    /// ### 怎么调
    ///
    /// 1. 近黑先换成**同亮度的中性灰**:三个通道都低到这个程度时色相完全来自压缩噪点
    ///    (brightenedAccent 那条注释里的老问题),但"它很暗"这个信息是真的,不该像那边
    ///    一样连亮度一起丢掉换成固定浅灰。
    /// 2. 已经够对比就原样返回 —— 绝大多数封面走这一条,不动用户看惯的颜色。
    /// 3. 不够就沿"离开描边亮度"的方向走到**刚好达标**为止:描边偏亮就压暗(RGB 整体
    ///    乘系数,保色相保饱和;压暗不像提亮那样刺眼),描边偏暗就朝白混合(同
    ///    accentForDarkBackdrop,天然降饱和)。两个方向都够不到时取更好的那个端点。
    ///
    /// 目标亮度是解析求出的,沿着方向找系数用二分 —— sRGB 的分段传递函数没有好看的
    /// 闭式反解,而这个函数每首歌只跑一次,24 次二分的开销可以忽略。
    ///
    /// - Parameter minContrast: 目标对比度,默认 3.0(WCAG 大号文字门槛)。
    nonisolated public static func accentAgainstStroke(
        r: Double, g: Double, b: Double,
        strokeR: Double, strokeG: Double, strokeB: Double,
        minContrast: Double = 3.0
    ) -> (r: Double, g: Double, b: Double) {
        // ① 近黑去噪:保留亮度,只丢掉不可信的色相。
        var (r, g, b) = (r, g, b)
        if r < 0.03, g < 0.03, b < 0.03 {
            let mean = (r + g + b) / 3
            (r, g, b) = (mean, mean, mean)
        }

        let strokeLum = relativeLuminance(r: strokeR, g: strokeG, b: strokeB)
        let ownLum = relativeLuminance(r: r, g: g, b: b)

        // ② 够对比就别动。
        if contrastRatio(strokeLum, ownLum) >= minContrast { return (r, g, b) }

        // ③ 解析出两侧的目标相对亮度:比描边亮要到 upper,比描边暗要到 lower。
        //    (L+0.05)/(S+0.05) = minContrast → L = (S+0.05)*minContrast - 0.05
        let upper = (strokeLum + 0.05) * minContrast - 0.05
        let lower = (strokeLum + 0.05) / minContrast - 0.05

        // 优先往"自己本来就在的那一侧"走,动得最少;那一侧够不到(比如描边是纯白,
        // 再亮也不可能比它亮 3 倍)才换另一侧。两侧都够不到时取端点里更好的那个。
        let canGoUp = upper <= 1.0
        let canGoDown = lower >= 0.0
        let preferUp = ownLum >= strokeLum
        if preferUp, canGoUp {
            return blendToLuminance(r: r, g: g, b: b, target: upper, towardWhite: true)
        }
        if !preferUp, canGoDown {
            return blendToLuminance(r: r, g: g, b: b, target: lower, towardWhite: false)
        }
        if canGoUp {
            return blendToLuminance(r: r, g: g, b: b, target: upper, towardWhite: true)
        }
        if canGoDown {
            return blendToLuminance(r: r, g: g, b: b, target: lower, towardWhite: false)
        }
        // 两侧都够不到 —— 取黑/白里对比更好的那个端点,别返回一个"差一点点"的中间值。
        //
        // ⚠️ 默认的 minContrast = 3.0 走不到这里:两侧都够不到要同时满足
        // strokeLum < 0.05(mc−1) 和 strokeLum > 1.05/mc − 0.05,有解的条件是
        // mc > √21 ≈ 4.58。这条分支是给传更严目标的调用方留的,不是死代码,
        // selftest 里用 7.0 显式覆盖它。
        return contrastRatio(strokeLum, 0) >= contrastRatio(strokeLum, 1)
            ? (0, 0, 0) : (1, 1, 1)
    }

    /// WCAG 相对亮度:先把 sRGB 分量线性化,再按 Rec.709 加权。
    nonisolated public static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            let c = min(1, max(0, c))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG 对比度,恒 ≥ 1。参数顺序无关。
    nonisolated public static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// 沿"朝白"或"朝黑"的方向混合，直到相对亮度达到 target。二分求混合比例。
    ///
    /// 朝白 = 线性插值到 (1,1,1)(提亮同时天然降饱和);朝黑 = RGB 整体乘系数
    /// (等价于线性插值到 (0,0,0),保色相保饱和)。两者沿方向都是单调的,二分成立。
    nonisolated private static func blendToLuminance(
        r: Double, g: Double, b: Double, target: Double, towardWhite: Bool
    ) -> (r: Double, g: Double, b: Double) {
        func at(_ t: Double) -> (Double, Double, Double) {
            towardWhite
                ? (r + t * (1 - r), g + t * (1 - g), b + t * (1 - b))
                : (r * (1 - t), g * (1 - t), b * (1 - t))
        }
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 24 {
            let mid = (lo + hi) / 2
            let c = at(mid)
            let lum = relativeLuminance(r: c.0, g: c.1, b: c.2)
            // 朝白亮度递增、朝黑亮度递减 —— 两种方向下"还没到 target"的判据正好相反。
            if towardWhite ? (lum < target) : (lum > target) { lo = mid } else { hi = mid }
        }
        let c = at(hi)
        return (c.0, c.1, c.2)
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
