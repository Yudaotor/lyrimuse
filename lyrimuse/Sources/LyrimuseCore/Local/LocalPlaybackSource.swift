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
    /// 这首是 MV。Apple Music 看 JXA 快照的 `isMusicVideo`,网页播放器看探针交出的视频类型(`noteBrowserVideo`)。
    /// 只给界面在专辑位写「MV」用,不进任何缓存 key。判据见 `musicVideoTrackKey(...)`。
    @Published public private(set) var isMusicVideo: Bool = false
    @Published public private(set) var isPlayingNow: Bool = false
    @Published public private(set) var currentLine: SyncedLyricLine?
    @Published public private(set) var nextLineText: String?
    /// 下一行摆在哪一边(见 SyncedLyricLine.side)——**独立于 currentLine?.side**,不能假定
    /// 下一句跟当前句是同一位演唱者(悬浮窗"下一句预览"对唱分栏 bug)。
    @Published public private(set) var nextLineSide: LyricDuet.Side?
    /// 下一行的罗马音/译文——跟 currentLine 上同名字段同一对查找函数算出来的,不是简化版。
    /// `currentLine` 为 nil 时(前奏/间奏「•••」下方没有当前行陪衬),那句其实是接下来的
    /// 第一句本身,该按正常行的规格展示这两项,见 LyricsOverlayView.lyricsCard。
    @Published public private(set) var nextLineRomanization: String?
    @Published public private(set) var nextLineTranslation: String?
    /// 下一行的逐词分组(见 `LyricsSyncEngine.TickResolution.nextWordGroups`):`currentLine` 为 nil
    /// 时悬浮歌词用它把罗马音逐词标在那句底下,跟它变成当前行之后的排版一致。
    @Published public private(set) var nextLineWordGroups: [SyncedLyricWordGroup]?
    // "歌词窗口"(完整可滚动歌词列表)用——跟 currentLine/nextLineText 同一套 20Hz tick
    // 算出来,只在真的换了行时才重新赋值(见 fastTick())。allLines 换歌时才重新构造一次
    // (reloadCurrentLyrics()),不需要每 tick 重算——歌词内容本身在同一首歌播放期间不变。
    @Published public private(set) var currentLineIndex: Int?
    /// 歌词窗口的滚动锚(AM 式"滚动先于染色"):一句唱完、下一句还没开始的
    /// 空档里先指向下一行,染色仍看 currentLineIndex。语义与三种空档的划分见
    /// LyricsSyncEngine.scrollLeadIndex;这里跟 currentLineIndex 同一套 tick、同一条
    /// "只在真的变化时才赋值"纪律。
    @Published public private(set) var scrollLineIndex: Int?
    /// 单行展示面(灵动岛 / 菜单栏)该显示的那一行(「唱完就切到下一句,
    /// 好提前看到歌词跟唱」)。跟 currentLine 的区别是**唱完就切走**;长间奏中段为 nil,
    /// 由 compactShowsPlaceholder 区分成因。规则见 CompactLyricLead —— 它跟歌词窗口的
    /// scrollLineIndex 是两套,别混(多行有「•••」可停靠,单行没有)。
    @Published public private(set) var compactLine: SyncedLyricLine?
    /// compactLine == nil 的成因:true = 唱完了、下一句还早(画 ♪);false = 压根还没有
    /// 可显示的行(交给各展示面既有的空态分支:搜索中 / 无歌词 / 广告 / 纯音乐…)。
    @Published public private(set) var compactShowsPlaceholder: Bool = false
    /// compactLine 总共会显示多久(毫秒),给菜单栏跑马灯配速。见 CompactLyricLead.displayDurationMs。
    @Published public private(set) var compactDwellMs: Int?
    /// compactLine 出现之后、开唱之前那段"已显示但还没染色"的提前量(毫秒)。菜单栏跑马灯
    /// 拿它当"起步前至少等多久" —— 没染色就不该滚。见 CompactLyricLead.leadInMs。
    @Published public private(set) var compactLeadInMs: Int?
    @Published public private(set) var allLines: [LyricsWindowLine] = []
    // 歌词间奏点(歌词窗口的「•••」):整首歌的间奏位置换歌时算一次;
    // "此刻在不在间奏里"跟 currentLineIndex 一样只在真的变化时赋值(20Hz tick 判定)。
    @Published public private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published public private(set) var currentGapIndex: Int?
    /// `currentGapIndex` 的不设门槛版本——悬浮歌词兜底用(它没有"沿用上一行"这条退路,
    /// `currentLine` 一旦为 nil 就必须画点什么,门槛只对"值不值得在歌词窗口插一整排三点"
    /// 有意义)。见 `LyricsSyncEngine.gapWindow(after:applyMinimumDuration:)`。
    @Published public private(set) var rawGapWindow: LyricsGapWindow?
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
    // 联网查过了、至少一个源(目前是 lrclib)明确说这首歌是纯音乐——补上,
    // 跟 hasLyricsContent 是两个不同维度:hasLyricsContent==false 本身分不清是"还没
    // 解析完"还是"解析完了但真没歌词",这个字段专门标记后一种情况里"有明确依据"的那
    // 一类(而不是"所有源都没搜到"这种更含糊、可能只是没搜对的情况)。UI 侧靠这个字段
    // 决定要不要显示"纯音乐"而不是笼统的占位符——见各 View 里 lyricContent/mainLine
    // 的分支顺序,这个判断必须排在"还在搜索中"那个分支之前,不然一首已经确认是纯音乐
    // 的歌会在播放期间一直卡在"搜索歌词中…"、永远不会显示出这个更准确的结论。
    @Published public private(set) var isCurrentTrackInstrumental: Bool = false
    /// 联网解析已经跑完一轮,但一句歌词都没拿到。
    ///
    /// 跟 hasLyricsContent==false 的区别就是"搜没搜过":没有它的话,一首查遍所有源都
    /// 找不到歌词的歌,只要还在播,界面就会**永远**停在"搜索歌词中…"——那句话在第 3 秒
    /// 是实话,在第 3 分钟就是假话了。判据是缓存条目里的解析时刻(见
    /// EnrichCacheLyrics.resolved)。
    ///
    /// 跟 isCurrentTrackInstrumental 互斥:纯音乐是"有依据地确认没有歌词",比这个更精确,
    /// 所以那一档单独判、并且排在前面(见各 View 的分支顺序)。
    @Published public private(set) var currentTrackHasNoLyrics: Bool = false

    /// 没有时间戳的纯文本歌词兜底——加,只在"这首歌真的没有能同步显示的版本,
    /// 但用户在「搜索候选歌词」弹窗里采纳过一条明确标了 PlainTextOnly 的候选"时非空(见
    /// EnrichCacheReader.EnrichCacheLyrics.plainLyrics / collector 侧
    /// enrichEntry.PlainLyrics 头注)。桌面悬浮歌词/灵动岛这些依赖时间戳逐字/逐行高亮的
    /// 展示面**不读**这个字段,继续如实显示"无歌词"——只有「歌词窗口」认它,当静态文字
    /// 展示。恒为空串时代表"没有这份兜底",不是"还没加载完",跟 currentTrackHasNoLyrics
    /// 一样以 EnrichCacheLyrics.resolved 为准。
    @Published public private(set) var currentTrackPlainLyrics: String = ""

    /// collector 报告"这一轮什么都没查到,是因为网络不通"(见 CollectorStatus)。
    ///
    /// 跟 currentTrackHasNoLyrics 是互补的两半:那个是"查过了,这首歌没有",这个是
    /// "根本没查成"。没有它的话,断网时界面会一直停在"搜索歌词中…" —— 而那句话在
    /// 断网状态下永远不会有下文。
    @Published public private(set) var collectorNetworkDown: Bool = false
    // Spotify 广告插播——补上:media-control 自己的文档确认广告播放时 album
    // 字段恒为空字符串,靠"当前是 Spotify 在报告 + album 为空"这个信号判断(见
    // apply() 里的计算);跟 isCurrentTrackInstrumental 同一个优先级问题,必须排在
    // "还在搜索中"分支前面——否则一段广告会在整段广告期间一直卡在"搜索歌词中…"
    // (广告的标题/歌手压根不会被写进歌词缓存,见 collector/enrich.go trackEnrichment
    // 的对应守卫,hasLyricsContent 永远拿不到内容)。
    @Published public private(set) var isCurrentTrackAdBreak: Bool = false
    /// 这条广告在这次插播里是第几条、一共几条(灵动岛显示出来)。
    ///
    /// 只有 **YouTube Music 网页广告**给得出 —— 它自己把「赞助商广告 1/2 ·」写在页面的广告
    /// 徽章上,探针顺路读回来(`YouTubeMusicAdProbe.Reading.adSlot`)。Spotify(原生和网页)
    /// 没有这个东西,恒 nil;英文界面的 "Ad 1 of 2" 也抓不到(探针只认斜杠写法,见那边头注)。
    /// **拿不到就是 nil,界面上那一段不画** —— 同「时长未知不画倒计时」那条纪律,不编数字。
    ///
    /// 跟着 `isCurrentTrackAdBreak` 一起收:广告一结束必须清掉,否则下一首歌的卡片上会
    /// 挂着上一次插播的「1/2」。
    @Published public private(set) var currentAdSlot: YouTubeMusicAdProbe.AdSlot? = nil
    // 当前曲目已生效的歌词时间轴校正值(毫秒)——跟 syncEngine.offsetMs 保持一致,供菜单栏
    // "歌词时间轴"菜单展示累计校准值/决定"重置"按钮是否显示用。实测排查坐实:
    // 这里之前没有这个属性,PlaybackCoordinator 自己用 "\(artist)|\(title)" 现拼了一个跟
    // LyricsOffsetStore 实际存储用的 key(LyricsOffsetStore.trackKey,多拼了一段内容指纹)
    // 完全对不上的 key 去查询,导致查到的值永远是 0——用户点"提前"好几次,nudge 本身其实
    // 已经生效(syncEngine.offsetMs 真的改了、歌词显示也真的偏移了),但菜单标题/"重置"
    // 按钮永远没有任何反馈,看起来就像完全没生效。改成不重新拼 key、直接转发这里的
    // syncEngine.offsetMs 权威值,从根上消除"两处各自算 key、容易算歪"这个问题。
    //
    // 这个值是**实际生效的总偏移** = 全局基准 + 这首歌的微调
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
    // 从 artworkAccentHex 改名成这个,同时把"提亮"从这里挪走了 —— 这里
    // 现在是**未经任何调整的原始均值**。原因见下面 accentAgainstStroke 的注释:两个消费面
    // (灵动岛永远深底 / 桌面悬浮歌词背景未知)对"这个颜色该多亮"的要求正好相反,在源头
    // 提前统一成一个"够亮"的值,等于替桌面那一侧做了错误的决定。各自的处理放在
    // PlaybackCoordinator,那里才知道自己是哪个面。
    @Published public private(set) var artworkAverageHex: String?
    /// Spotify 原生客户端这首歌在 Spotify 图床上的封面地址(AppleScript `artwork url`,640 档),由
    /// `SpotifyPositionProbe` 开播 2.5s 后那次脚本顺带带回来(经 noteSpotifyArtwork 落到这里,
    /// 先核对还是这首)。换歌 / 停播置 nil;Spotify 网页版由 BrowserPositionProbe 从页面带回同一格式的地址
    ///,其它播放器恒 nil。消费方是
    /// `PlaybackCoordinator.refreshSpotifyOriginalCover`:系统那份封面(实测 600×600)本来就身份精确,
    /// 这条只为把歌词窗口那张 920px 卡换成**同一张图**的原图档,见 03 章「高清替代」。
    @Published public private(set) var spotifyArtworkURL: URL?
    // "歌词窗口"进度条用(随 Apple Music 风格重做补上):暂停时 anchor 会被
    // 置 nil(见 apply() 的 else 分支),进度条如果只认 anchor,一暂停就整个没有位置可
    // 显示。暂停态 media-control/AppleScript 的 elapsedTime 本身就是精确的冻结位置,
    // 这里单独发布出来,让进度条在暂停时显示冻结的进度而不是直接消失。播放中恒为 nil
    // (此时该用 anchor 外推)。
    @Published public private(set) var pausedPositionMs: Int?
    // 当前曲目时长(毫秒)——anchor 里虽然也带 durationMs,但暂停时 anchor 是 nil,
    // 冻结进度条还需要时长算比例,单独发布。没有曲目/时长未知时为 nil。
    @Published public private(set) var currentDurationMs: Int?
    /// 电台专用:当前这首歌已经越过真曲长(= 进了口白那一段)。收歌词看它,见 fastTick()。
    private var radioTrackFinished = false
    /// 同一件事发布给界面:三个展示面在口白期间把歌词那一格换成「口白」,
    /// 语义与既有的 `isCurrentTrackAdBreak` 平行 —— 都是"这一刻在放的不是歌"。
    @Published public private(set) var isRadioTalkBreak = false
    /// 当前这个台的台名与台标(口白期间顶上去,见 RadioStationCard)。抓不到台卡就都是 nil,
    /// 界面退回原样(还显示上一首)—— 宁可保持现状,也不要编一个台名。
    @Published public private(set) var radioStationName: String?
    @Published public private(set) var radioStationArtwork: Data?
    /// 台卡的内存副本 + 还在等封面的那张台卡的 trackKey(台卡那一拍往往还没有图,
    /// 封面是几百毫秒后单独一行,见 noteRadioStationArtwork)。
    private var radioStationCard: RadioStationCard?
    private var radioStationCardLoaded = false
    private var pendingStationCardKey: String?

    // (之前这里有一个全局的"卡拉OK效果"开关:关掉就让引擎不解析逐字数据,四个
    //  展示面一起退成整行高亮。已撤:引擎始终解析逐字数据,"要不要逐字填色"改成悬浮歌词 /
    //  灵动岛 / 菜单栏各自的开关,由各展示面在自己的消费点上把 `SyncedLyricLine` 压成整行
    //  (`SyncedLyricLine.lineLevel`);歌词窗口始终逐字。见 AppSettings.overlayLyricsKaraoke。)
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
    /// **当前这首歌**的歌词会不会真的被简繁转换改动。跟上面那个粘性位是两件事:
    ///   - `sawChineseLyrics` 是"这台机器上见过中文歌词没有",只置不清,给**设置页**用 ——
    ///     一个已经露出来的设置项不该因为换了首歌就消失(见它自己的注释)。
    ///   - 这一个逐曲计算、会来回变,给**悬浮窗右键菜单**用(「只有中文歌
    ///     时才出现简繁转换」)。右键菜单本来就是上下文菜单、每次弹出重建,它里面已经有
    ///     按当前曲目决定显隐的先例(「搜索歌词…」在没歌在播时就不给)。
    ///
    /// 判据直接用 `ChineseVariant.affects`,跟 `converted(_:)` 是同一个函数 —— 保证
    /// "菜单显示 ⟺ 转换真的会发生",不可能出现"开关不见了但歌词还在被转"。
    ///
    /// 译文这一支要**再乘一个「译文正在屏幕上」**,不能只判
    /// `affects(正文) || affects(译文)`:译文没在显示时,把它从简体转成繁体是一次
    /// **看不见**的改动,菜单项就会变成点了没有任何视觉反馈的死项。举例:米津玄师
    /// 《Petrichor》是纯日文歌词(正文那一支正确地判 false),但缓存里带一份中文机翻
    /// `lyrics_tr`,若译文那一支单独点亮菜单,就会出现"播日文歌为什么也显示简繁转换"。
    /// 所以不变量是:**菜单显示 ⟺ 转换真的会发生、而且看得见**。
    ///
    /// 判据本体抽成了纯函数 `supportsChineseVariant(lyrics:translation:translationVisible:)`。
    @Published public private(set) var currentLyricsSupportsChineseVariant = false

    /// 译文有没有在屏幕上 —— 镜像 App 层的 `AppSettings.showTranslation`
    /// (Core 够不到 AppSettings,由 AppDelegate 订阅推进来)。
    ///
    /// 这个开关**不参与歌词装载**:译文转不转由 `chineseVariant` 决定,关掉它只是不画
    /// 那一行,引擎侧照常转(见 reloadCurrentLyrics 里的 `variant.converted(lyricsTr)`)。
    /// 它唯一的用途是上面那条显隐判据 —— Core 之所以需要知道一件纯展示的事,理由在那里。
    /// 也正因为不参与装载,它**不进** `LyricsReloadSnapshot`:那道闸管的是"要不要重算",
    /// 而这个标志的重算发生在闸之前,翻转时正好只更新标志、跳过整段解析。
    @Published public var showsTranslation = false {
        didSet { reloadCurrentLyrics() }
    }

    /// 「简繁转换」这一项该不该露出来。抽成纯函数是为了让 selftest 能直接钉住这条不变量——
    /// `reloadCurrentLyrics()` 要一份真实播放快照才跑得起来,测不到。
    /// (`nonisolated`:不碰任何 @MainActor 隔离状态,跟 `servoDecision` 同一个理由。)
    public nonisolated static func supportsChineseVariant(
        lyrics: String, translation: String, translationVisible: Bool
    ) -> Bool {
        ChineseVariant.affects(lyrics)
            || (translationVisible && ChineseVariant.affects(translation))
    }

    private let syncEngine = LyricsSyncEngine()
    // 公开给 View 层——逐字填色现在按渲染帧频(TimelineView)从这个锚点直接外推真实
    // 播放位置现算,不再靠这里的 20Hz tick 把预算好的 fillFraction 塞进 currentLine。
    @Published public private(set) var anchor: ProgressAnchor?
    private var lastKey = ""
    private var lastSnapshot: MediaControlSnapshot?
    /// 这首是 MV 时按 SponsorBlock 片段换算出的时间轴(见 MusicVideoTimeline),连同它属于哪首歌。
    private var musicVideoTimeline: (trackKey: String, timeline: MusicVideoTimeline)?
    /// 已经为哪首歌发起过片段查询(同一首只查一次,换歌清掉)。
    private var musicVideoLookupKey: String?
    /// 此刻叠进引擎的 MV 偏移(≤ 0),由 20Hz tick 按播放位置刷新,见 refreshMusicVideoOffset。
    private var musicVideoOffsetMs = 0
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

    // ---- 播放位置平滑(加,修 QQ 音乐"歌词时间不准") --------------------
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
    // 连续"(换歌、暂停与播放切换、或者这次读数跟"按上一次锚点+经过的真实时间外推"的
    // 预测值差太多,说明真的 seek/跳曲了)时才信任这次读数重新锚定;平稳播放期间改成
    // 按真实 wall-clock 经过的时间累加,不理会每次读数自身的抖动。这套逻辑对 Apple
    // Music 同样安全——它的读数本来就精确,预测值和读数几乎总是相差无几,不会触发"跟
    // 预测差太多"这个分支,观感上跟直接按读数累加没有差别。
    private var trackPosSeconds: Double = 0
    private var posTrackingKey = ""
    /// 上一轮那首是不是广告(换歌那一拍它就是"上一首是不是广告",见 spotifyNaturalStartKind)。
    private var posPrevWasAdBreak = false
    private var posWasPlaying = false
    private var posPrevWall: Date?
    // 上一轮的报告值 —— 冻结检测(isFrozenReport)用它算"这一轮报告值前进了多少"。
    // 每次 resolvePositionSeconds 退出时统一更新(defer),换歌/暂停恢复不需要单独清:
    // 那些路径本身就会把它刷成当轮读数,下一轮的差值语义自然正确。
    private var posPrevReported: Double?
    // "真实读数 − 墙钟外推值"偏差的滑动平均——见 servoDecision 的注释,
    // 实测排查坐实的"锁死偏差"问题的修复状态。播种/跳变/校正后都归零重新累计。
    private var posErrEMA: Double = 0
    /// 最近一次"播放器说状态变了"的信号到达时刻(只记真状态信号,不记纯锚点刷新)。
    private var posStateSignalAt: Date?
    // nonisolated:被 shouldProbeLateAnchor(nonisolated 纯函数)引用,不可变 Sendable。
    private nonisolated static let seekJumpToleranceSecs = 2.0
    /// 已经为哪个锚点问过「晚锚点」确认(见 shouldProbeLateAnchor)。坏锚点在位期间偏差每拍都在,
    /// 不按锚点去重的话会每拍探一次。换歌 / 恢复播放时清掉 —— 新一首的锚点 elapsed 常常也是 0,
    /// 不清就会被上一首的记录误抑制掉第一次确认。
    private var posLateAnchorProbedElapsed: Double?

    // 地板量化源的「前向棘轮」阈值。
    //
    // 实测坐实(QQ 音乐,采样 media-control 原始字段 + 程序化暂停/恢复):
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
    /// 这个档位同时是 **MediaRemote 锚点补偿机制的总开关**:晚锚点探针、冻结守卫、
    /// `SpotifyPositionProbe` 的位置纠正,只在 `cleanExtrapolated` 这一档成立。哪个播放器归哪一档
    /// 写在 shared/players.json 的 `positionTier` 字段里。
    /// 自然切歌偏置与 repeat-one 回绕重估**不归它管**,归 `carriesGaplessLead`(Spotify 在 precise 档
    /// 照样需要)。
    public enum PositionSourceTier {
        /// Apple Music / Spotify:AppleScript 播放头,读数精确到 ~0.1s,不需要锚点补偿
        /// (Spotify 的自然切歌领先另算,见 carriesGaplessLead)。
        case precise
        /// 酷狗音乐 / 汽水音乐:media-control 外推,稳态读数干净(±0.05s)但换歌初期锚点
        /// 可能带常量超前 —— 门槛要小到能把播种偏差拉回来,又别被暂停/切换瞬间的单发陈旧
        /// 读数(实测 -1.27s 一类)骗出回跳。
        ///
        /// 酷狗归这一档是实测定的,不是猜的:它**播放期间根本不刷新锚点**
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
        // 把默认档从 noisyFloored 翻成 cleanExtrapolated,并把真正"整秒下取整 +
        // 大抖动"的那两个显式列出来。
        //
        // 理由是实测:noisyFloored 那一档的两样东西(1.0s 大门槛 + 前向棘轮)都只对**整秒
        // 量化**的源成立 —— 棘轮的前提是"报告值 ≤ 真实位置"(下取整才恒成立)。而所有走
        // media-control 的源实测都是**纯墙钟外推、无量化**:酷狗(实测 23 秒
        // 累计偏差 +0.0011s)、Arc(同款,小数位完全连续)。也就是说 noisyFloored 是**少数
        // 派**,把它当默认档等于让每一个没被显式登记的源都套上一副不适用的参数,而 1.0s
        // 门槛意味着 1 秒以内的固定偏差永远修不掉。
        //
        // bundleID 为 nil(压根没有来源信息)也走这一档:所谓"保守"应该是"别用前提不成立的
        // 棘轮",而不是"选那个门槛最大的"。
        //
        // 哪个播放器归哪一档,在 shared/players.json 的 positionTier 字段(生成成
        // `PlaybackPlayer.positionTierID`)。这里只做两件本地的事:映射成这个类型,以及定
        // "认不出来源"时的默认档 —— 后者是判断,不是每播放器一行的数据,所以留在这里。
        switch PlaybackPlayer.builtin(forBundleID: bundleID)?.positionTierID {
        case "precise": return .precise
        case "noisyFloored": return .noisyFloored
        default: return .cleanExtrapolated
        }
    }

    /// 见 flooredForwardSnapEpsilonSecs。纯函数,selftest 直接覆盖。
    ///
    /// 浏览器探针那笔一次性地面真值,差多少才值得重锚。
    ///
    /// 0.30s 的取法:探针值做完去地板补偿后,自身残余误差是 ±0.5s 内的均匀分布(标准差 ≈0.29s),
    /// 再叠上页面文字本身 ±0.1s 的跳变抖动。门槛低于这个量级只会来回抖,高于它就白白放过
    /// 实测中最常见的那档 0.7~0.9s 系统性偏差。
    ///
    /// 值得重锚的判据是"比噪声大",不是"比 1 秒大" —— 用 `servoDecision` 那套给周期性
    /// 噪声源设计的门槛来卡一次性样本,是这条纠偏此前从不生效的直接原因。
    public static let groundTruthSnapToleranceSecs: Double = 0.30

    /// Spotify 播放中途重发的「晚锚点」:新的 elapsedTime 比真实位置晚 1~2 秒,单看 MediaRemote
    /// 是一个形状完全正常的锚点。它从两道既有的闸中间漏过去 —— `MediaControlClient.
    /// isStaleAnchorRepublish` 要求 elapsed 逐 ms 相等(这里 elapsed 变了,29.3 ≠ 上一个锚点),
    /// seek 分支要求跳变过 `seekJumpToleranceSecs`(这里够不着 2 秒)。
    ///
    /// 漏过去之后伺服会把它当成新真相:cleanExtrapolated 档 alpha 0.3、单样本限幅 ±0.75,持续
    /// 同号的 1~2 秒误差第 3 拍(~6 秒)就把 EMA 推过 0.4 门槛 snap 过去;此后 reported 与
    /// predicted 同出这一个坏锚点、误差再也不显现 —— 整首歌恒定落后,只有暂停(Spotify 那时会
    /// 重打准锚点)才纠得回来。用户视角就是"歌词慢一两秒,暂停再播放就好了"。
    ///
    /// 一天的真机日志:这种锚点 30 次,幅度集中在 1.0~2.0 秒(另有 38 次锚点冻结重发被 stale 闸
    /// 认出、57 次跳变过 2 秒进 seek 分支)。**幅度越大越容易自愈**是这个坑反直觉的地方 ——
    /// 播到 100 秒时来一个 elapsed=2.5 的锚点(差 97 秒)反而进 seek 分支、探针 1.5 秒纠回来。
    ///
    /// 处置只有一件事:**问一次探针**,位置照旧走伺服,这里不自己动位置。探针 ~1 秒就回来,而
    /// 伺服要 3 拍才 snap,坏值来不及固化;真拖动 0.5~2 秒时探针与新锚点一致、什么都不改,假锚点
    /// 时探针把差折进偏置(与 seek 分支同一条处置,只是门槛低)。
    ///
    /// 0.5 秒的下沿:稳态抖动 ±0.05s、暂停/切换瞬间的单发陈旧读数实测 -1.27s。取 0.5 能把稳态
    /// 噪声挡在外面,又接得住实测幅度最小的那一档(-1.0s);单发陈旧读数多问一次探针无害 ——
    /// 它与新锚点一致时探针什么都不改。纯函数,selftest 直接覆盖。
    public nonisolated static func shouldProbeLateAnchor(
        reported: Double, predicted: Double, tier: PositionSourceTier
    ) -> Bool {
        guard tier == .cleanExtrapolated else { return false }
        let backwards = predicted - reported
        return backwards > lateAnchorProbeToleranceSecs && backwards <= seekJumpToleranceSecs
    }

    /// 见 shouldProbeLateAnchor。(nonisolated:同 seekJumpToleranceSecs,纯函数要读它。)
    public nonisolated static let lateAnchorProbeToleranceSecs: Double = 0.5

    /// 探针量出的偏置:**这一拍流读数 − 探针值**,两个数都必须取**原始域**(没扣过偏置的值)。
    ///
    /// 别拿 `resolvePositionSeconds` 里那个 `reported` 当减数 —— 它是 `rawReported - 偏置`,
    /// 已经在扣过偏置的域里。混域算出来的是 `(流读数 − 探针值) + 旧偏置`:旧偏置为 0 时恰好
    /// 等于正解,所以平时看不出来;偏置还在位时再来一次探针(开播那次与锚点变化那次可以隔
    /// 百来毫秒先后落地),这一段差就被叠进去、整首歌的纠偏翻倍。叠出来的方向跟着旧偏置的
    /// 符号走:偏负多了读数被加得过头、歌词偏快,偏正多了减得过头、歌词偏慢,暂停时播放器
    /// 重打准锚点、偏置作废才回得准 —— 表现就是"忽快忽慢、一暂停就对齐"。
    ///
    /// 偏置符号约定:正=流读数超前真声(用时要减),负=落后(用时要加)。纯函数,selftest 覆盖。
    public nonisolated static func probeMeasuredBias(streamRaw: Double, probeRaw: Double) -> Double {
        streamRaw - probeRaw
    }

    /// 只对地板量化源(noisyFloored)生效:棘轮的依据是"reported ≤ 真实位置"这条
    /// 不等式,而 Spotify 的读数恰恰恒略**超前**真值,对它棘轮
    /// 只会把位置锁在抖动的上包络、且 EMA 每次吸附都被清零,永远修不回来。
    public nonisolated static func shouldRatchetForward(
        reported: Double, predicted: Double, tier: PositionSourceTier
    ) -> Bool {
        tier == .noisyFloored && reported - predicted > flooredForwardSnapEpsilonSecs
    }

    // 实测排查坐实的设计缺陷修复:原来"稳定播放"分支只按墙钟外推、完全不回看
    // 真实读数,任何播种时刻带进来的偏差——App 启动那一拍的读数毛刺、恰好整个落在两次
    // 2 秒轮询之间而完全没被观察到的短暂停(墙钟累加器会把暂停时长也当播放时间加进去)——
    // 只要小于 2 秒的 seek 容差,就会永久锁死、永远不被纠正(诊断日志坐实:一次启动播种
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
    // - cleanExtrapolated(Spotify,拆档):alpha 0.3、门槛 0.4s——稳态抖动
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
        // cleanExtrapolated 的单样本限幅(冻结守卫的配套):锚点冻结的
        // **第一拍**只表现为一次大负偏差(实测 -1.74),冻结检测要到第二拍(报告值
        // 连续没动)才认得出来 —— 不限幅的话第一拍 0.3×(-1.74) = -0.52 就冲过 0.4
        // 门槛,歌词被拖回半秒。限在 ±0.75:单发异常最多把 EMA 推到 ±0.225,到不了
        // 门槛;真实的持续偏差只是多等一轮(0.8s 偏差第 3 轮仍能校正,见 selftest)。
        let clamped = tier == .cleanExtrapolated ? max(-0.75, min(0.75, error)) : error
        let newEMA = errEMA * (1 - alpha) + clamped * alpha
        return (newEMA, abs(newEMA) > threshold)
    }

    /// 恢复播放时,播种值最多允许比冻结值超前这么多的硬上限(兜底)。
    ///
    /// 正常取值是"状态信号到达至今"这段(实测中位数 0.338s,见 `resumeSeedSeconds`);
    /// 这个常量只在拿不到信号时兜底 —— 那时宁可不砍,也别按一个猜出来的上界砍。
    /// 播放档轮询是 2 秒一拍,取它。
    public nonisolated static let resumeMaxForwardCapSecs: Double = 2.0

    /// 从暂停恢复那一拍该用哪个位置播种。纯函数,selftest 直接覆盖。
    ///
    /// 别直接采信这一笔读数:暂停期间 media-control 的 `elapsedTimeNow` **照样按暂停前的
    /// rate 空转**(见 `livePositionSeconds` 开头那段),恢复那一笔因此普遍超前真实位置 ——
    /// 真机 17 次恢复实测前跳 +0.37~+1.93s,而位置在暂停期间根本没走。种偏之后伺服要
    /// 上百秒才拉得回来,这期间歌词一直偏快(用户视角:"进度偏一点,暂停一下就正常")。
    ///
    /// 冻结值(`pausedPositionMs`)是播放器暂停时自报的真实位置,**暂停中拖进度条也会刷新它**,
    /// 所以它就是恢复那一刻的真值;真正未知的只有"从真按下播放到我们查到"这段延迟。
    /// 它的上界是**恢复信号到达至今**这段(`posStateSignalAt`,实测 0.31~0.43s)——
    /// 恢复不可能发生在信号之前。超过这个上界的超前一律削掉。
    ///
    /// 上界只能用状态信号,不能用"距上一次观测"(暂停档轮询 6 秒一拍,那个上界一路顶到
    /// 兜底值、等于没砍 —— 实测过,中位数反而从 −0.273 退到 −0.350)。
    ///
    /// 落后或小幅超前**原样采信**:播放器真报了个新位置(暂停中拖动、跨曲恢复)就该听它,
    /// 这道闸只砍"不可能发生的前跳"。
    public nonisolated static func resumeSeedSeconds(
        reported: Double, frozen: Double?, maxForwardSecs: Double
    ) -> Double {
        guard let frozen else { return reported }
        let ceiling = frozen + min(max(0, maxForwardSecs), resumeMaxForwardCapSecs)
        return reported > ceiling ? ceiling : reported
    }

    /// 冻结检测:曲目/广告结尾 Spotify 会把 MediaRemote 锚点冻住 ——
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

    // ---- Spotify 自然切歌(gapless)锚点超前校正 --------------------------
    //
    // 量出来的偏移(样本:Forever Love→在那遙遠的地方,media-control 0.25s 采样 + 旧曲连续外推
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
    // 旧曲外推的时钟偏移实测 std 0.008s,足够当真值。
    //
    // 这套连续性估计**只给 media-control 那条路用**(cleanExtrapolated 档,以及 Spotify 退回
    // media-control 时)。Spotify 自己的 `player position` 同样整首领先,但不能这么估:交界处声音
    // 并不连续,估出来偏小甚至为负 —— 那条路按起播方式给领先量,见 SpotifyStartKind。
    //
    // 偏置的生命周期:换歌估计(守卫见 naturalAdvanceCorrection);真实 seek(Spotify
    // 会重打锚点,重打后的锚点是准的)清零并改信原始读数;暂停时按读数来源分(见
    // biasSurvivesAnchor);手动换歌/非 Spotify 清零。
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

    /// 这份读数带不带"gapless 自然切歌后新曲位置领先真声"的毛病 —— 自然切歌校正与
    /// repeat-one 回绕重估的总闸。纯函数,selftest 直接覆盖。
    ///
    /// 别收回成只看档位:Spotify 的 `player position` 归 precise 档(稳态干净、伺服按精确源
    /// 调参),但它每次起播后都整首领先一截、伺服对它结构性失明(读数与外推同出一个钟)。
    /// 两件事正交,只按档位开就会整首歌偏快、一暂停才对齐。Spotify 那一档具体怎么扣见 SpotifyStartKind。
    ///
    /// 酷狗不开:它的钟在单曲循环回绕与自然切歌处都是连续的(实测差 0.04~0.08s),按旧曲外推越界量估出来的
    /// 只是我们自己外推的误差,而那个偏置一暂停也清不掉。自然切歌晚打的锚点另由
    /// `MediaControlClient.resetAnchorStartCorrection` 按先到的归零锚点补。数据见 02 章「酷狗单曲循环报暂停」「酷狗自然切歌」。
    public nonisolated static func carriesGaplessLead(tier: PositionSourceTier, bundleID: String?) -> Bool {
        if bundleID == PlaybackPlayer.kugou.bundleIdentifier { return false }
        return tier == .cleanExtrapolated || bundleID == PlaybackPlayer.spotify.bundleIdentifier
    }

    /// 播放器自己的钟是不是已经对回了出声位置 —— 偏置在位时,播放中的读数(已扣偏置)突然比外推
    /// **退回了约一个偏置量**。纯函数,selftest 直接覆盖。
    ///
    /// 暂停那一拍作废偏置(`biasSurvivesAnchor` 的 `playing`)只在**看到**暂停时成立;暂停与恢复落在
    /// 同一个轮询间隙里、一拍都没看到时,偏置还在,而 Spotify 的钟已经对齐,扣完偏置的读数恰好慢一个
    /// 偏置量 —— precise 档伺服一拍就吸附过去,整首偏慢。这个签名不依赖看没看到暂停:暂停对齐、
    /// 往回小拖(拖动同样让钟对齐)、播放中钟停一下等音频,三种成因下"采信原始读数、清偏置"都对。
    /// 漏掉的暂停时长 d 让退回量变成 偏置+d,所以只设"至少退回这么多",不设上限(>2s 走 seek 分支)。
    ///
    /// 只看 `anchorElapsedTime == nil`(读的是播放器自己的钟):media-control 那条路上锚点重发另有
    /// `biasSurvivesAnchor` 盯着,而那边 cleanExtrapolated 档的负偏置(探针量出的锚点落后)语义相反。
    public nonisolated static func playerClockResynced(error: Double, bias: Double, anchorElapsedTime: Double?) -> Bool {
        guard anchorElapsedTime == nil, bias > 0 else { return false }
        return error <= -(bias - playerClockResyncToleranceSecs) && error < -playerClockResyncMinDropSecs
    }
    /// Spotify 同一首歌里读数换了钟(AppleScript `player position` ⇄ media-control)时怎么处置。
    public enum SpotifyClockAction: Equatable {
        /// 跟这一首采信的钟一致,照常。
        case accept
        /// 偶发退回 media-control 的一拍:不采信它的位置,照外推走。
        case hold
        /// 认定换钟:重锚到这一拍读数、偏置作废。
        case switchClock
    }
    /// 退回 media-control 持续多久才认定换钟(AppleScript 真的不可用了:权限被收回 / Spotify 卡住)。
    public nonisolated static let spotifyForeignClockHoldSecs = 4.0

    /// 纯函数,selftest 直接覆盖。
    ///
    /// 两个钟对同一首歌的读数可以差出一秒多(gapless 自然切歌后 `player position` 自己领先,
    /// media-control 的锚点另有自己的偏差),偏置也只对量它的那个钟成立。所以夹在 AppleScript 读数
    /// 中间的一拍 media-control 不能喂进伺服 —— precise 档一拍就会被它拽过去,下一拍再拽回来。
    /// 持续退回才换钟;回到 AppleScript 立即换回(它是首选的钟)。
    public nonisolated static func spotifyClockAction(
        acceptedPlayerClock: Bool?, readsPlayerClock: Bool, foreignSince: Date?, now: Date
    ) -> SpotifyClockAction {
        guard let accepted = acceptedPlayerClock, accepted != readsPlayerClock else { return .accept }
        if !readsPlayerClock, now.timeIntervalSince(foreignSince ?? now) < spotifyForeignClockHoldSecs {
            return .hold
        }
        return .switchClock
    }

    /// Spotify 自己的钟是不是进了歌尾那段(外推与读数都在最后几秒)。纯函数,selftest 直接覆盖。
    ///
    /// 歌尾最后一秒它会**停住或往回退**(数据见 02 章「订正」),这时读数既不是真声也不是
    /// "钟已对齐",拿它喂伺服或 `playerClockResynced` 都会把
    /// 位置往回拽 —— 而下一首的自然切歌校正正要拿这一段的连续外推当真值,拽一下就把下一首的偏置估歪
    /// 同样的量。所以这一段照外推走。
    ///
    /// 要求**读数本身**也在歌尾:从歌尾往回拖,读数离开歌尾,照常走 seek 分支,不会被这里吞掉。
    public nonisolated static func inPlayerClockTail(
        predicted: Double, raw: Double, duration: Double, anchorElapsedTime: Double?
    ) -> Bool {
        guard anchorElapsedTime == nil, duration > 0 else { return false }
        return predicted >= duration - playerClockTailSecs && raw >= duration - playerClockTailSecs - 1
    }
    public nonisolated static let playerClockTailSecs = 3.0

    // ---- Spotify 自己的钟:按起播方式分档的领先量 ----
    //
    // `player position` 是解码器的钟,每次起播都先于出声跑一截,量取决于那一刻缓冲了多少,
    // **按起播方式分得很开、同一种方式里很稳**(ScreenCaptureKit 截 Spotify 的音频当真值直接量的,
    // 数据见 02 章「订正」):手动点播 / 没预载的换歌 ~0.24,播放中拖动 ~0.45,预载好的无缝换歌 0.49~0.73
    // (这一档波动最大,先验取均值)。
    // 暂停后恢复那一档不在这里 —— 那一拍有真值,当场量(resumeLead)。
    //
    // 别再拿"上一首连续放完 = 新曲真值"去估新曲的领先量:交界处声音并不连续(实测新曲出声比
    // 旧曲名义结尾晚 0.5~0.8s,随曲目变),连续性一估就小、甚至估成负数被拒,整首偏快。
    //
    // 先验取实测值;每次暂停再用冻结值反推这一段真实的领先量(pauseResidualLead),按档慢慢修正
    // (np:spotifyStartLeadByKind,机器本地)。

    /// Spotify 这一段是怎么起播的 —— 决定用哪一档领先量,也决定暂停时的残差学进哪一档。
    public enum SpotifyStartKind: String, CaseIterable, Sendable {
        /// 手动点播 / 没预载的换歌(新曲的钟晚于旧曲名义结尾才开始走)。
        case fresh
        /// 播放中拖动。
        case seek
        /// 预载好的无缝换歌(新曲的钟在旧曲名义结尾那一刻就开始走),含单曲循环回绕。
        case gapless
        /// 广告放完接着放的那首。广告报的时长不准(实测报 29.99、29.09 就结束),"钟接不接得上"那道判据
        /// 在这里判不准;领先量跟预载无缝换歌同一量级,不能学进 fresh(会把手动点播那档抬高一倍多)。
        case afterAd
    }

    /// 同一首歌里读数跳回开头时,这是重新起播还是拖动。纯函数,selftest 直接覆盖。
    ///
    /// 两者在读数上一模一样(同曲、位置回到 ~0),领先量却差一截(重新起播同 fresh ~0.25,拖动 ~0.45~0.5)。
    /// 能分开它们的是 Spotify 的分布式通知:重新起播(点同一首 / `play track`)先后发 `Stopped` 与
    /// `Playing, Playback Position 0`,拖动一条都不发。数据见 02 章「Spotify 重新起播」。
    public nonisolated static let spotifyRestartNoticeWindowSecs: TimeInterval = 3
    public nonisolated static let spotifyRestartMaxRawSecs: Double = 3
    public nonisolated static func spotifyJumpKind(raw: Double, playingFromStartNoticeAt: Date?, now: Date) -> SpotifyStartKind {
        guard raw <= spotifyRestartMaxRawSecs, let noticeAt = playingFromStartNoticeAt else { return .seek }
        let age = now.timeIntervalSince(noticeAt)
        return age >= 0 && age <= spotifyRestartNoticeWindowSecs ? .fresh : .seek
    }

    public nonisolated static func spotifyStartLeadPrior(_ kind: SpotifyStartKind) -> Double {
        switch kind {
        case .fresh: return 0.24
        case .seek: return 0.45
        case .gapless: return 0.66
        case .afterAd: return 0.66
        }
    }

    /// 上一首还在播、这一首接着起来时的起播方式。纯函数,selftest 直接覆盖。
    /// - previousWasAd: 上一首是不是广告(`isCurrentTrackAdBreak` 在上一首时的值)
    public nonisolated static func spotifyNaturalStartKind(raw: Double, clockOverrun: Double, previousWasAd: Bool) -> SpotifyStartKind {
        if previousWasAd, abs(clockOverrun) <= naturalAdvanceWindowSecs { return .afterAd }
        return isPreloadedGaplessStart(raw: raw, clockOverrun: clockOverrun) ? .gapless : .fresh
    }

    /// 换歌那一拍,是不是预载好的无缝换歌。纯函数,selftest 直接覆盖。
    /// - raw: 新曲第一笔读数(它自己的钟)
    /// - clockOverrun: 旧曲**钟**按连续外推越过其时长的量(= 声音外推越界量 + 旧曲偏置)
    /// 预载时新曲的钟在旧曲钟走到头那一刻就接上,两者一致;没预载时新曲的钟要等加载完才走,差出一截。
    public nonisolated static func isPreloadedGaplessStart(raw: Double, clockOverrun: Double) -> Bool {
        abs(clockOverrun) <= naturalAdvanceWindowSecs && abs(raw - clockOverrun) <= preloadedClockToleranceSecs
    }
    /// 实测:预载时两者差 ~0.1s;没预载时新曲的钟晚 1.9s。
    public nonisolated static let preloadedClockToleranceSecs = 0.5

    /// 暂停那一拍 Spotify 发布的冻结值比我们停在的位置**本来就大**这么多:发出暂停后声音还要淡出
    /// ~0.25s 才停(实测 0.246~0.318),冻结值对应的是停下那一刻。偏置量得准时 `pause transition` 的
    /// delta 实测 +0.25~+0.30。
    public nonisolated static let spotifyPauseFadeSecs = 0.27

    /// 暂停那一拍反推这一段真实的领先量。纯函数,selftest 直接覆盖。
    /// - bias: 这一段在用的偏置(暂停作废之前的值)
    /// - pauseDelta: 冻结值 − 暂停那一刻屏上位置
    /// 真实领先 = 在用的偏置 + (淡出量 − delta)。残差超过 1s 多半是别的事(暂停前拖过 / 事件没跟上),不学。
    public nonisolated static func pauseResidualLead(bias: Double, pauseDelta: Double) -> Double? {
        let residual = spotifyPauseFadeSecs - pauseDelta
        guard abs(residual) <= 1.0 else { return nil }
        let lead = bias + residual
        guard lead >= 0, lead <= naturalAdvanceMaxBiasSecs else { return nil }
        return lead
    }

    /// 学到的领先量怎么更新:EMA α=0.3,别让一次异常样本把整档拽走。纯函数,selftest 直接覆盖。
    public nonisolated static func learnedStartLead(current: Double, sample: Double) -> Double {
        current * 0.7 + sample * 0.3
    }

    private static let spotifyStartLeadDefaultsKey = "np:spotifyStartLeadByKind"
    private static let spotifyStartLeadSchemaDefaultsKey = "np:spotifyStartLeadSchema"

    /// 起播领先量表的规则版本。某一档的**判定或学习规则**变了,就把版本 +1、在 `migratedStartLeadTable`
    /// 里作废那一档(按规则作废,不按数值大小猜哪个坏了)。没有版本号的旧表算 1。
    /// 2:广告之后那首从 fresh 拆出成 afterAd,旧 fresh 值里混着广告之后的样本,作废(见决策 47)。
    public nonisolated static let spotifyStartLeadSchema = 2

    /// 把按旧规则学的表迁到当前版本。纯函数,selftest 直接覆盖。
    public nonisolated static func migratedStartLeadTable(_ table: [String: Double], fromSchema: Int) -> [String: Double] {
        var migrated = table
        if fromSchema < 2 { migrated.removeValue(forKey: SpotifyStartKind.fresh.rawValue) }
        return migrated
    }

    /// 读表;表还是旧版本时先迁一次、连同版本号写回。
    private func loadStartLeadTable() -> [String: Double] {
        let defaults = env.defaults
        let table = (defaults.dictionary(forKey: Self.spotifyStartLeadDefaultsKey) as? [String: Double]) ?? [:]
        let schema = defaults.object(forKey: Self.spotifyStartLeadSchemaDefaultsKey) as? Int ?? 1
        guard schema < Self.spotifyStartLeadSchema else { return table }
        let migrated = Self.migratedStartLeadTable(table, fromSchema: schema)
        defaults.set(migrated, forKey: Self.spotifyStartLeadDefaultsKey)
        defaults.set(Self.spotifyStartLeadSchema, forKey: Self.spotifyStartLeadSchemaDefaultsKey)
        logger.notice("spotify start lead table migrated: schema \(schema) -> \(Self.spotifyStartLeadSchema) \(table.keys.sorted(), privacy: .public) -> \(migrated.keys.sorted(), privacy: .public)")
        return migrated
    }

    private func spotifyStartLead(_ kind: SpotifyStartKind) -> Double {
        loadStartLeadTable()[kind.rawValue] ?? Self.spotifyStartLeadPrior(kind)
    }

    private func learnSpotifyStartLead(kind: SpotifyStartKind, sample: Double) {
        var table = loadStartLeadTable()
        let current = table[kind.rawValue] ?? Self.spotifyStartLeadPrior(kind)
        let updated = Self.learnedStartLead(current: current, sample: sample)
        table[kind.rawValue] = updated
        env.defaults.set(table, forKey: Self.spotifyStartLeadDefaultsKey)
        logger.notice("spotify start lead learned: kind=\(kind.rawValue, privacy: .public) sample=\(sample, format: .fixed(precision: 3)) \(current, format: .fixed(precision: 3)) → \(updated, format: .fixed(precision: 3))")
    }

    /// Spotify 自己的钟是不是开播起步晚了:还在曲首几秒、读数(已扣偏置)比外推慢出一截。纯函数,selftest 直接覆盖。
    /// 跟 `playerClockResynced` 的签名重叠(都是"读数落后"),靠"还在曲首"区分 —— 曲首没有可对齐的领先。
    public nonisolated static func playerClockStartedLate(raw: Double, reported: Double, predicted: Double) -> Bool {
        raw < playerClockStartWindowSecs && reported < predicted - playerClockResyncMinDropSecs
    }
    public nonisolated static let playerClockStartWindowSecs = 3.0

    /// 恢复播放那一拍,Spotify 自己的钟领先真声多少。纯函数,selftest 直接覆盖。
    ///
    /// 那个钟是解码器的钟,**每次重新起播都先跑一截**:恢复后第一笔读数比「暂停值 + 恢复后走过的时间」
    /// 领先 0~1.5s(实测见 02 章「订正」),下一拍伺服就吸附过去、整首偏快,直到下一次暂停它才对回来。
    /// 播种值(resumeSeedSeconds:暂停值 + 状态信号至今)就是真声,差值即领先量。守卫与自然切歌同一套。
    public nonisolated static func resumeLead(raw: Double, seed: Double) -> Double? {
        let lead = raw - seed
        guard lead > naturalAdvanceMinBiasSecs, lead <= naturalAdvanceMaxBiasSecs else { return nil }
        return lead
    }

    /// App 重启后第一拍,能不能接着用上一个进程给这首歌量的偏置。纯函数,selftest 直接覆盖。
    ///
    /// 不接的话,重启那一首余下部分偏快一个偏置量;更糟的是下一首的自然切歌校正拿这段偏快的位置当
    /// 真值,估出来的偏置接近 0 被守卫拒掉,偏快顺着 gapless 连播链传下去。
    ///
    /// 记录是偏置量出来那一拍写的,带着那一刻的位置(`positionSecs`,旧记录没有按 0 算 —— 自然切歌那拍
    /// 位置≈0),所以"从那以后一直连续在放"的签名是:扣掉偏置的读数 ≈ 那一刻的位置 + 记录至今的秒数。
    /// 对不上(中途暂停过 —— 钟已对齐;拖过;重播过)就不接。只接播放器自己的钟那一档
    /// (`anchorElapsed == nil`),media-control 那条路另有锚点判据。
    public nonisolated static func restorablePlayerClockBias(
        record: PositionBiasRecord, bundleID: String?, artist: String, title: String,
        raw: Double, now: Date
    ) -> Double? {
        guard record.anchorElapsed == nil, record.biasSecs > 0,
              record.bundleID == bundleID, record.artist == artist, record.title == title
        else { return nil }
        let age = now.timeIntervalSince1970 - Double(record.writtenAtMs) / 1000
        let expected = (record.positionSecs ?? 0) + age
        guard age >= 0, abs((raw - record.biasSecs) - expected) <= restoreContinuityToleranceSecs else { return nil }
        return record.biasSecs
    }
    /// 记录时位置不是恰好 0(自然切歌播种在 −0.9~+0.7 之间),再留轮询间隔的余量。
    public nonisolated static let restoreContinuityToleranceSecs = 2.0

    /// 退回量跟偏置之间允许差多少(AppleScript 读数稳态噪声 ±0.06s,再留一倍余量)。
    public nonisolated static let playerClockResyncToleranceSecs = 0.15
    /// 至少退回这么多才算 —— 偏置很小(下限 0.05)时别让读数噪声把它误清。
    public nonisolated static let playerClockResyncMinDropSecs = 0.2

    /// 当前曲目读数相对真声的偏差(秒)——resolvePositionSeconds 对每笔原始读数先扣掉它。
    /// 只在 `carriesGaplessLead` 为真的源上非零(cleanExtrapolated 档 + Spotify;Apple Music 恒为 0)。
    /// 正=读数超前真声(gapless 自然切歌,量法见上);
    /// **负=锚点落后真声**(允许:播放器给歌曲发 now-playing 常晚 ~2s 而 elapsedTime
    /// 仍是 0,`SpotifyPositionProbe` 量到的差折进来,见 resolvePositionSeconds 的地面真值分支)。
    private var posReportedBiasSecs: Double = 0
    /// 这份偏置是对着哪个锚点量的(那一刻快照的原始 anchorElapsedTime)。偏置只对这个锚点成立,
    /// 锚点一换就作废,见 biasSurvivesAnchor。偏置为 0 时恒为 nil。
    private var posBiasAnchorElapsed: Double?

    private func setReportedBias(_ bias: Double, anchorElapsed: Double?, fromProbe: Bool = false,
                                 fromBrowserProbe: Bool = false, startKind: SpotifyStartKind? = nil) {
        posReportedBiasSecs = bias
        posBiasAnchorElapsed = bias == 0 ? nil : anchorElapsed
        posBiasFromProbe = bias != 0 && fromProbe
        posBiasFromBrowserProbe = bias != 0 && fromBrowserProbe
        posBiasStartKind = bias == 0 ? nil : startKind
    }
    /// 当前偏置是网页探针的精确读数量出来的(页面 `currentTime` 对流读数)。它跟 Spotify 探针那份一样只属于
    /// 量它时的锚点,走同一道 biasSurvivesAnchor 作废;但不参与 Spotify 的领先量学习。
    private var posBiasFromBrowserProbe = false
    /// 当前偏置是按哪一档起播领先量给的(nil = 别的来源:恢复当场量的、重启接回的、media-control 那条路的)。
    /// 只有它非 nil 时,暂停那一拍的残差才学进对应那一档。
    private var posBiasStartKind: SpotifyStartKind?
    /// 当前偏置是不是 Spotify 探针量出来的(而不是自然切歌估的)——只有它参与 probeLeadSecs 的学习。
    private var posBiasFromProbe = false

    // ---- Spotify 探针钟的领先量(按输出设备分别记) ----
    //
    // AppleScript `player position` 不是用户耳朵里的位置:它比 Spotify 暂停 / 恢复时发布给 MediaRemote
    // 的冻结值**恒定领先一段**,量级跟音频输出路径走 —— 真机:内建输出时 0.06~0.14s(vampire /
    // Adore You / RAYE / IDGAF),切到蓝牙 AirPods 之后 0.51~0.65s(Kiss It Better / London Boy),
    // 26s 连续采样里 AppleScript 钟与 MediaRemote 外推的差是常数(不是开播瞬态)。用户对"准"的
    // 判据就是暂停再播之后的位置(= 冻结 / 恢复锚点那套钟),所以探针值要先扣掉这段领先量,
    // 否则整首歌偏快一个蓝牙延迟(用户 17:39 报「感觉有一点点偏快」)。
    //
    // 领先量没法直接读,但每次 Spotify 界面里按暂停都送来一份真值:偏置随暂停锚点作废那一拍,
    // 「我们停在的位置 − Spotify 冻结值」= 探针领先量(+ 外推漂移 ±0.06)。只在偏置是探针量的时候学
    // (自然切歌估的偏置有自己的误差来源),|残差|>1.5s 不学(暂停中拖了进度条之类)。
    //
    // **按默认输出设备分别记**(用户 18:0x 追问「不用蓝牙了依旧准确吧,逻辑必须通用」):领先量是输出
    // 链路的属性,一台机器上蓝牙 0.55 / 内建 0.1 交替出现,单个 EMA 在每次切换后都要靠两三次暂停慢慢
    // 收敛、中间那段反着偏。所以按 `AudioOutputRoute.Current.uid` 存一张表(np:spotifyProbeLeadByDevice,
    // 机器本地,不随配置搬家),取值时看此刻的默认输出:学过就用学过的,没学过按传输类型给先验
    // (probeLeadPrior:蓝牙 0.5、内建 0.1,其余 0),第一份残差直接采信、之后 EMA α=0.5。默认输出一换
    // (AudioOutputRoute.startObserving)立刻换值,并且正在放 Spotify 且偏置是探针量的就再问一次探针
    // (requestConfirmation),让位置在 ~1s 内按新领先量重折,不等用户暂停。
    private static let probeLeadByDeviceDefaultsKey = "np:spotifyProbeLeadByDevice"
    private static let anchorLagDefaultsKey = "np:anchorLagByPlayer"
    /// 旧的单值键;启动时若表为空就把它归到当前设备名下,然后删掉。
    private static let legacyProbeLeadDefaultsKey = "np:spotifyProbeLeadSecs"
    private nonisolated static let probeLeadLearnAlpha = 0.5
    private nonisolated static let probeLeadMaxResidualSecs = 1.5

    /// 没学过的设备按传输类型给的先验。纯函数,selftest 直接覆盖。数字来自真机:蓝牙 AirPods
    /// 0.51~0.65,内建 0.06~0.14;AirPlay / USB / 显示器音频没量过,给 0(= 不假设)。
    public nonisolated static func probeLeadPrior(for transport: AudioOutputRoute.Transport) -> Double {
        switch transport {
        case .bluetooth: return 0.5
        case .builtIn: return 0.1
        case .airPlay, .display, .usb, .other: return 0
        }
    }

    /// 纯函数,selftest 直接覆盖:一次暂停量到的残差怎么更新这台设备的领先量。
    ///
    /// 残差是**扣过当前领先量之后**还剩的偏差(我们停在的位置已经减过 `current`),所以真值 =
    /// current + residual,不是 residual 本身 —— 把残差当真值直接采信会越学越离谱:真机
    /// 19:43 先验 0.5 下量到残差 0.07(真值 0.57)却把领先量写成 0.07,19:49 再量到残差 0.50 又折成 0.285
    /// (日志 `probe lead learned` 两行对出来的)。没学过的设备第一份直接采信 current +
    /// residual(先验只是起点),学过的按 α=0.5 往真值靠;残差离谱返回原值。
    public nonisolated static func learnedProbeLead(current: Double, residual: Double, hasPrior: Bool) -> Double {
        guard abs(residual) <= probeLeadMaxResidualSecs else { return current }
        guard hasPrior else { return current + residual }
        return current + residual * probeLeadLearnAlpha
    }

    // ---- 锚点滞后(开播锚点比真声晚打多少) ----
    //
    // 走 media-control 外推的播放器里有一类:**播放期间根本不刷新锚点**(elapsedTime 恒为开播
    // 那一刻的值、timestamp 纹丝不动),位置全靠墙钟外推 —— 那么开播锚点晚打多少,整首歌就恒定
    // 滞后多少,而且曲内没有任何可观测量能揭示它。汽水音乐实测 ~0.43s(Electron/Chromium 的
    // MediaSession 晚于真声更新);Spotify 同病但走 `SpotifyPositionProbe` 那条地面真值路。
    //
    // 自然切歌那套(`naturalAdvanceCorrection`)救不了这一类:旧曲外推和"换歌被观察到"同样
    // 晚这一段,overrun 里两边抵消成 ~0,估不出偏置(真机 `bias=0.000` 逐条坐实)。
    //
    // 唯一的真值来源是播放器**自己重发一次带真实位置的锚点** —— 汽水音乐每首歌快放完时必有
    // 一次(真机:每首歌换歌前 2~3 秒),暂停时也有一次。那一刻量出的残差就是这个播放器的滞后量,
    // 学下来持久化,**下一首开播直接预置**,所以只有第一首吃这个滞后。
    /// 一次残差离谱到这个程度就不是锚点滞后(seek / 换歌错位),原样退回。
    public nonisolated static let anchorLagMaxResidualSecs: Double = 1.5
    /// 学过之后按这个系数往新样本靠(与 probeLead 同量级:单次样本不该整份顶掉历史)。
    public nonisolated static let anchorLagLearnAlpha: Double = 0.4
    /// 学到的滞后量上限。比这还大的"滞后"更可能是别的毛病,补过去只会把歌词推成偏快。
    public nonisolated static let anchorLagMaxSecs: Double = 1.5
    /// 小于这个量不值得补:补偿本身有学习噪声,而这个量级肉眼无感。
    public nonisolated static let anchorLagMinApplySecs: Double = 0.08
    /// 换歌那一笔原始读数大过这个值,就不是"从这首歌的开播锚点跟下来"(App 中途接手别人
    /// 已经在放的歌 / 手动从中间点播),这一首整首不采样。见 posAnchorLagSampleValid。
    public nonisolated static let anchorLagFreshStartMaxSecs: Double = 1.0

    /// 纯函数,selftest 直接覆盖:播放器重发锚点时量到的一次残差怎么更新它的滞后量。
    ///
    /// 残差是**扣过当前滞后量之后**还剩的偏差(外推位置已经补过 `current`),所以真值 =
    /// current + residual —— 跟 `learnedProbeLead` 同一个陷阱,把残差当真值会越学越离谱。
    /// 没学过的第一份直接采信,学过的按 α 往真值靠;结果夹进 [0, anchorLagMaxSecs]:
    /// 负的"滞后"(锚点反而超前)不在这条路的职责里,交给自然切歌偏置。
    public nonisolated static func learnedAnchorLag(current: Double, residual: Double, hasPrior: Bool) -> Double {
        guard abs(residual) <= anchorLagMaxResidualSecs else { return current }
        let next = hasPrior ? current + residual * anchorLagLearnAlpha : current + residual
        return min(max(next, 0), anchorLagMaxSecs)
    }

    /// 按设备 UID 学到的领先量表。lazy:第一次用到时从 UserDefaults 读,顺带迁移旧的单值键。
    private lazy var probeLeadByDevice: [String: Double] = {
        var table: [String: Double] = [:]
        if let json = env.defaults.string(forKey: Self.probeLeadByDeviceDefaultsKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            table = decoded
        }
        if env.defaults.object(forKey: Self.legacyProbeLeadDefaultsKey) != nil {
            let legacy = env.defaults.double(forKey: Self.legacyProbeLeadDefaultsKey)
            if table.isEmpty, let route = env.outputRoute() {
                table[route.uid] = legacy
                logger.notice("probe lead: migrated legacy value \(legacy, format: .fixed(precision: 3)) to device \(route.name, privacy: .public)")
            }
            env.defaults.removeObject(forKey: Self.legacyProbeLeadDefaultsKey)
            persistProbeLeadTable(table)
        }
        return table
    }()

    private func persistProbeLeadTable(_ table: [String: Double]) {
        if let data = try? JSONEncoder().encode(table), let json = String(data: data, encoding: .utf8) {
            env.defaults.set(json, forKey: Self.probeLeadByDeviceDefaultsKey)
        }
    }

    /// 按 bundle id 学到的锚点滞后量。lazy:第一次用到时从 UserDefaults 读。
    private lazy var anchorLagByPlayer: [String: Double] = {
        guard let json = env.defaults.string(forKey: Self.anchorLagDefaultsKey),
              let data = json.data(using: .utf8),
              let table = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return table
    }()

    private func persistAnchorLagTable(_ table: [String: Double]) {
        if let data = try? JSONEncoder().encode(table), let json = String(data: data, encoding: .utf8) {
            env.defaults.set(json, forKey: Self.anchorLagDefaultsKey)
        }
    }

    /// 上一拍快照的原始锚点 elapsedTime。只用来认出"播放器这一拍重发了锚点"——重发那一拍
    /// 才有真值可量,之后每拍锚点都保持新值,不能重复学。
    private var posPrevAnchorElapsed: Double?

    /// 这一首的锚点滞后样本还作不作数。
    ///
    /// 滞后量的定义是"开播锚点比真声晚多少",所以只有**从开播锚点一路墙钟外推下来、中途没被
    /// 重锚过**的那种曲子量出来才是它。 这道闸是真机打脸补上的:App 在别人已经放到一半时
    /// 启动(位置走"首次观察"直接采信读数那条路),歌尾量到的残差是 **1.046** —— 把它当滞后学
    /// 进去,下一首直接偏快一秒,比原来的滞后更难受。凡是重锚过(seek / 恢复播放 / 探针介入 /
    /// 单曲循环回绕)的曲子一律不采样,宁可少学几次。
    private var posAnchorLagSampleValid = false

    /// 这个播放器走不走锚点滞后这套(学一个平均滞后、下一首开播预置)。纯函数,selftest 直接覆盖。
    ///
    /// 酷狗不走:它的晚打时有时无(同一个歌单连着三首,0.5s / 0 / 0.5s),平均值必然有的歌补过头、有的补不够;
    /// 它晚打的那种由 `MediaControlClient.resetAnchorStartCorrection` 逐首补。
    public nonisolated static func learnsAnchorLag(bundleID: String?) -> Bool {
        bundleID != PlaybackPlayer.kugou.bundleIdentifier
    }

    /// 这个播放器此刻该预置的锚点滞后量;没学到(或学到的太小)时为 0。
    private func anchorLag(forBundleID bundleID: String?) -> Double {
        guard Self.learnsAnchorLag(bundleID: bundleID),
              let bundleID, let lag = anchorLagByPlayer[bundleID], lag >= Self.anchorLagMinApplySecs
        else { return 0 }
        return lag
    }

    /// 播放器重发锚点那一刻量到一次残差:更新并持久化它的滞后量。
    private func learnAnchorLag(bundleID: String?, residual: Double) {
        guard Self.learnsAnchorLag(bundleID: bundleID), let bundleID else { return }
        let prior = anchorLagByPlayer[bundleID]
        let next = Self.learnedAnchorLag(current: prior ?? 0, residual: residual, hasPrior: prior != nil)
        logger.notice("anchor lag learned: player=\(bundleID, privacy: .public) residual=\(residual, format: .fixed(precision: 3)) lag \(prior ?? 0, format: .fixed(precision: 3)) -> \(next, format: .fixed(precision: 3))")
        guard prior != next else { return }
        // "没学过 + 这次也没学出东西"不要建条目:建了之后 hasPrior 就成立,下一次真量到
        // 滞后时会走 α 而不是直接采信(酷狗的换歌残差全被限幅夹成 0,正好踩这个)。
        guard next > 0 || prior != nil else { return }
        anchorLagByPlayer[bundleID] = next
        persistAnchorLagTable(anchorLagByPlayer)
    }

    /// 此刻默认输出设备(startObservingOutputRoute 之后随系统变化刷新;为 nil 时按 .other 处理)。
    private var currentOutputRoute: AudioOutputRoute.Current?

    /// 此刻该从探针值里扣掉的领先量:这台输出设备学过的值,或按传输类型的先验。
    private var probeLeadSecs: Double {
        guard let route = currentOutputRoute else { return 0 }
        return probeLeadByDevice[route.uid] ?? Self.probeLeadPrior(for: route.transport)
    }

    private func learnProbeLead(residual: Double) {
        guard let route = currentOutputRoute else { return }
        let prior = probeLeadByDevice[route.uid]
        let next = Self.learnedProbeLead(current: prior ?? Self.probeLeadPrior(for: route.transport),
                                         residual: residual, hasPrior: prior != nil)
        logger.notice("probe lead learned: residual=\(residual, format: .fixed(precision: 3)) device=\(route.name, privacy: .public) (\(route.transport.rawValue, privacy: .public)) lead \(self.probeLeadSecs, format: .fixed(precision: 3)) -> \(next, format: .fixed(precision: 3))")
        guard prior != next else { return }
        probeLeadByDevice[route.uid] = next
        persistProbeLeadTable(probeLeadByDevice)
    }

    /// 默认输出设备换了:换用那台设备的领先量;正在放 Spotify 且偏置是探针量的,再问一次探针让位置按新
    /// 领先量重折(否则要等用户下一次暂停)。
    private func outputRouteChanged() {
        let route = env.outputRoute()
        guard route != currentOutputRoute else { return }
        let before = probeLeadSecs
        currentOutputRoute = route
        logger.notice("output route changed: \(route?.name ?? "-", privacy: .public) (\(route?.transport.rawValue ?? "-", privacy: .public)) probe lead \(before, format: .fixed(precision: 3)) -> \(self.probeLeadSecs, format: .fixed(precision: 3))")
        if posBiasFromProbe, posWasPlaying,
           lastSnapshot?.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier {
            env.spotifyProbeRequestConfirmation(posTrackingKey)
        }
    }

    /// 上一次写给 collector 的偏置记录(见 PositionBiasFile)。
    private var lastPublishedBias: PositionBiasRecord?

    /// 把当前偏置告诉 collector(网页 / 飞书预览那条链路走它自己的 media-control 外推,见
    /// PositionBiasFile 头注)。只在内容变了才写;只有 Spotify 与网页探针精确读数量出的偏置要发布,其余只在需要
    /// 把上一条非零记录作废时才写一条 0 —— 免得 Apple Music 每换一首歌都落一次盘。
    private func publishPositionBiasIfChanged(snapshot: MediaControlSnapshot, isSpotifyNative: Bool, now: Date) {
        // 读数层补过的切歌修正(酷狗,见 MediaControlSnapshot.anchorStartCorrection)不经过偏置,但 collector
        // 读的是原始锚点,同一段修正要按"对着原始锚点的负偏置"写给它。
        let startCorrection = posReportedBiasSecs == 0 ? snapshot.anchorStartCorrection : nil
        let record = PositionBiasRecord(
            artist: snapshot.artist ?? "", title: snapshot.title ?? "",
            bundleID: snapshot.bundleIdentifier ?? "",
            anchorElapsed: startCorrection != nil ? snapshot.anchorElapsedTime : posBiasAnchorElapsed,
            biasSecs: startCorrection.map { -$0 } ?? posReportedBiasSecs,
            writtenAtMs: Int64(now.timeIntervalSince1970 * 1000),
            positionSecs: trackPosSeconds)
        if let last = lastPublishedBias, last.sameContent(as: record) { return }
        guard isSpotifyNative || posBiasFromBrowserProbe || startCorrection != nil
                || (lastPublishedBias?.biasSecs ?? 0) != 0 else { return }
        lastPublishedBias = record
        env.writePositionBias(record)
    }

    /// 偏置能不能跟着这个锚点继续用。纯函数,selftest 直接覆盖。
    ///
    /// 别让偏置在"暂停与恢复"之间继承(以为冻结值来自同一个超前锚点):gapless 切歌
    /// 后 Spotify 自己的钟会停一下等新音频,稳态时就是音频位置(暂停冻结值 152.673 与 App 已扣偏置
    /// 的显示 152.689 只差 16ms,而当时偏置 1.080)。偏置只属于**量它时对着的那个**锚点;Spotify 后来
    /// 重新发布的任何锚点 —— 暂停冻结值、恢复、拖动 —— 都对齐它的钟,原始 elapsedTime 必然变了,这时
    /// 再扣偏置就是把准的值往回拖一个偏置量(实测暂停瞬间 −1.097s)。MediaRemote 指令暂停不重发锚点
    /// (原始 elapsedTime 不变),那时暂停值来自我们自己按开播锚点外推,偏置照旧扣 —— 所以判据是
    /// "锚点的原始 elapsedTime 还是不是量偏置时那个",不是"现在是不是暂停"。
    ///
    /// 从"开播锚点 = elapsedTime 0"改成"= 量偏置时的那个值":Spotify 有时开播半秒内会把锚点
    /// 从 0@T 改发成 1.923@T(BIRDS OF A FEATHER 实测),按旧判据这首歌任何偏置都活不过下一拍;
    /// `measuredAgainst` 缺失时退回旧判据。
    ///
    /// `anchorElapsedTime == nil` = 这一拍读的是播放器自己的钟(Spotify 的 AppleScript `player position`),
    /// 没有锚点可比。那个钟**一暂停就对回出声位置**(暂停冻结值比暂停前一刻的读数退回一个偏置量,
    /// 伺服 errEMA 同期 ≈0),所以偏置只活到暂停那一拍:`playing == false` 即作废。
    public nonisolated static func biasSurvivesAnchor(anchorElapsedTime: Double?, measuredAgainst: Double? = nil, playing: Bool = true) -> Bool {
        guard let anchorElapsedTime else { return playing }
        guard let measuredAgainst else { return anchorElapsedTime <= 0.001 }
        return abs(anchorElapsedTime - measuredAgainst) <= 0.001
    }

    /// 探针值该不该扣领先量;同一条判据也决定一次暂停残差有没有资格拿来学领先量。
    ///
    /// 探针读的是播放器自己的钟,而那个钟**只在开播锚点还在位的那段时间超前真声** —— gapless
    /// 切歌后它先跑、等音频跟上(同 biasSurvivesAnchor 头注里那段)。播放器一旦在曲中重发锚点
    /// (暂停 / 恢复 / 拖动),钟就与真声一致,探针本身即真值,这时再扣一个领先量等于凭空造出
    /// 一个偏置,整首歌恒定偏慢那一段,直到暂停时冻结值把它揭穿。
    ///
    /// 两种场合的样本**绝不能喂进同一个领先量**:曲中样本把它往 0 拽、切歌样本把它往
    /// 0.8 拽,学出来的中间值在两边都是错的 —— 一边扣多、一边扣少,而且方向相反。表现是
    /// 歌词进度忽前忽后、一按暂停就跳回准的位置(暂停时偏置作废,显示改用播放器的冻结值)。
    /// 真机按 `measuredAgainst` 分组,两簇残差符号完全不重叠:开播锚点那档 +0.25 / +0.26 / +0.59,
    /// 曲中重打那档 −1.00 / −0.83(且量值正好等于当时的领先量,即真实领先量是 0)。
    ///
    /// 领先量按输出设备存盘(probeLeadByDevice),但**设备不是这件事的自变量** —— 决定它的是
    /// 探针在什么时机量的。设备维度留着不改只是因为动存盘格式的代价更大;别据此以为换耳机
    /// 会改变这个量。
    public nonisolated static func probeLeadApplies(anchorElapsedTime: Double?) -> Bool {
        guard let anchorElapsedTime else { return true }
        return anchorElapsedTime <= 0.001
    }

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
    /// 上一轮快照的播放器(仅当它 `carriesGaplessLead`,否则 nil)——自然切歌校正的"旧曲真值"
    /// 必须来自**同一个**播放器自己的连续外推;auto 模式跨播放器切歌时,拿 QQ/网易云的整秒
    /// 地板外推或 Apple Music 的播放头当旧曲真值去估 Spotify 偏置是错的。
    private var posPrevGaplessLeadBundleID: String?
    /// 这一首 Spotify 眼下采信哪个钟(true = AppleScript `player position`;非 Spotify 为 nil)。
    /// 换歌 / 首次观察 / 恢复播放那一拍按那一拍的读数定,见 spotifyClockAction。
    private var posSpotifyAcceptedPlayerClock: Bool?
    /// 读数从哪一刻起一直来自另一个钟(nil = 没在换钟)。
    private var posSpotifyForeignClockSince: Date?
    /// 进程启动后第一份带曲目的快照是否已经处理过 —— 接回上一个进程的偏置只在那一拍做。
    private var posBiasRestoreChecked = false
    /// 暂停期间上一轮的原始冻结读数——暂停中用户在播放器里拖进度条时,冻结值会跳变
    /// (Spotify 同时重打对齐真声的锚点),旧偏置必须作废;不检测的话恢复播放后整曲
    /// 反向偏慢一个旧偏置。播放态清 nil。
    private var posPausedRawSecs: Double?

    /// 换曲那一拍"按字段/页面判定这条是不是广告"(纯函数,selftest 钉着;收出来):
    ///   - YouTube Music 探针判成广告 → 广告(`showsAdBadge`:只有 `.ad` 算,nil 不算);
    ///   - Spotify **网页版**:只认 `SpotifyWebAdProbe` 的正向证据 `.ad`,nil / `.song` 都不算 ——
    ///     配对关系不等于此刻在放 Spotify,不能按配对套下面那套启发式;
    ///   - Spotify **原生**客户端:字段启发式(album 空 / artist 空 / 标题「—」,与 collector `isAdBreak`
    ///     同款),另有 AppleScript `spotify url` 异步复核兜底;
    ///   - 其它播放器一律不是广告。
    public static func adBreakByFields(
        isSpotifyNative: Bool, title: String, artist: String, album: String,
        youTubeMusicVerdict: YouTubeMusicAdProbe.Verdict?, spotifyWebVerdict: SpotifyWebAdProbe.Verdict?
    ) -> Bool {
        if YouTubeMusicAdProbe.showsAdBadge(verdict: youTubeMusicVerdict) { return true }
        if spotifyWebVerdict == .ad { return true }
        return isSpotifyNative && !title.isEmpty && (album.isEmpty || artist.isEmpty || title == "—")
    }

    /// 「广告中」标志的状态机(纯函数,selftest 钉着;从 apply 里收出来):
    ///   - 换曲那一拍按当下字段/页面判定定初值(`adByFields`);
    ///   - 同曲期间字段/页面说是广告 → 往 true 棘轮(Spotify 广告字段会闪变,见 apply() 里那段);
    ///   - 同曲期间**页面明确说是歌**(`.song`,不是 nil)→ 回落成 false —— 只有 YouTube Music 的
    ///     音乐视频会走到这一条:前贴片广告跟正片共用同一份 MediaSession 元数据,判定会在同一个
    /// key 下先 ad 后 song(见 YouTubeMusicAdProbe.verdictMaxAge 的提醒);
    ///   - 其余保持不变(含 nil:探针超时/还没探到,不许把已判定的广告抹掉,也不许把歌变成广告)。
    /// Spotify 的 AppleScript 复核在别处异步把它置 true,跟这里不冲突(它传进来的 pageVerdict 恒为 nil)。
    public static func nextAdBreakState(
        previous: Bool, isNewTrack: Bool, adByFields: Bool, pageVerdict: YouTubeMusicAdProbe.Verdict?
    ) -> Bool {
        if isNewTrack { return adByFields }
        if adByFields { return true }
        if pageVerdict == .song { return false }
        return previous
    }

    /// 换曲那一拍对 Spotify 原生客户端做广告分类:先看 Spotify 自己刚广播的通知
    /// (`SpotifyNotificationHint`,Track ID 前缀是权威分类、且比 MediaRemote 早到),按快照的歌名/歌手核对是
    /// 同一首才采信 —— 说是广告就当场置位,说是曲目就到此为止,**不再 fork osascript**。通知没到 / 对不上这首
    /// (App 刚启动、Spotify 没广播)才退回下面那次 AppleScript 复核,行为不劣于旧状。
    /// 调用方约定同 verifySpotifyAdViaAppleScript:只在 换曲 + 原生 Spotify + 字段启发式没判中 时调。
    private func spotifyNativeAdCheckForNewTrack(snapshot: MediaControlSnapshot) {
        if let hint = spotifyNotificationHint, hint.matches(title: snapshot.title, artist: snapshot.artist) {
            if hint.isAd, !isCurrentTrackAdBreak { isCurrentTrackAdBreak = true }
            logger.debug("spotify ad check: notification says \(hint.isAd ? "ad" : "track", privacy: .public) for key=\(snapshot.trackKey, privacy: .public)")
            return
        }
        verifySpotifyAdViaAppleScript(forKey: snapshot.trackKey)
    }

    /// 位置探针带回这首歌的图床地址;还是这首才收(晚到的地址不能挂到下一首头上,同 verifySpotifyAdViaAppleScript
    /// 回来时那道核对)。
    public func noteSpotifyArtwork(url: URL, forKey key: String) {
        guard lastSnapshot?.trackKey == key else {
            logger.notice("spotify artwork url: dropped, track moved on (for key=\(key, privacy: .public))")
            return
        }
        if spotifyArtworkURL != url {
            spotifyArtworkURL = url
            logger.notice("spotify artwork url: \(url.lastPathComponent, privacy: .public) for key=\(key, privacy: .public)")
        }
    }

    /// 网页播放器交出的视频身份。是 MV(`MusicVideoTimeline.isMusicVideoType`)时查 SponsorBlock 标注的
    /// 非音乐片段,按「这份歌词的来源自报的歌曲版时长」建时间轴;检查不过就什么都不做。同一首只查一次。
    ///
    /// 片段一到先只扣片头(不需要歌曲版时长,见 MusicVideoTimeline 头注),再等歌词判决拿歌曲版时长升级成全部片段。
    /// 第一次放的歌,判决要等全部歌词源应答(实测半分钟上下):每 `musicVideoSongDurationRetrySecs` 秒重读一次
    /// 缓存键与判决明细,最多 `musicVideoSongDurationAttempts` 次,换歌即停。片段有缓存,重试不再联网。
    public func noteBrowserVideo(_ video: BrowserPositionProbe.VideoIdentity, forKey key: String) {
        guard let snapshot = lastSnapshot, snapshot.trackKey == key else { return }
        guard MusicVideoTimeline.isMusicVideoType(video.musicVideoType) else { return }
        musicVideoKey = key
        if !isMusicVideo { isMusicVideo = true }
        guard musicVideoLookupKey != key else { return }
        musicVideoLookupKey = key
        musicVideoLookupBasis = (key, video, musicVideoLyricsContext(forKey: key)?.lyricsSource)
        let videoDuration = currentDurationMs.map { Double($0) / 1000 }
        let videoID = video.videoID
        let attempts = Self.musicVideoSongDurationAttempts
        let retryNanos = UInt64(Self.musicVideoSongDurationRetrySecs * 1_000_000_000)
        Task.detached(priority: .utility) { [weak self] in
            guard let result = await SponsorBlockSegments.shared.segments(forVideoID: videoID) else { return }
            guard !result.cuts.isEmpty else {
                await self?.adoptMusicVideoTimeline(nil, forKey: key, videoID: videoID, cutCount: 0, songDuration: nil)
                return
            }
            let duration = result.videoDurationSecs ?? videoDuration ?? 0
            if let leadingOnly = MusicVideoTimeline.make(cuts: result.cuts, videoDurationSecs: duration, songDurationSecs: nil) {
                await self?.adoptMusicVideoTimeline(leadingOnly, forKey: key, videoID: videoID,
                                                    cutCount: result.cuts.count, songDuration: nil)
            }
            var songDuration: Double?
            for attempt in 0..<attempts {
                if attempt > 0 { try? await Task.sleep(nanoseconds: retryNanos) }
                guard let context = await self?.musicVideoLyricsContext(forKey: key) else { return }
                if let cacheKey = context.cacheKey,
                   let record = DecisionSidecar.loadRecord(key: cacheKey,
                                                           directory: LyrimusePaths.configFile(DecisionSidecar.directoryName)) {
                    songDuration = MusicVideoTimeline.songDurationSecs(fromDecisionRecord: record,
                                                                       lyricsSource: context.lyricsSource)
                }
                if songDuration != nil { break }
            }
            guard let songDuration else { return }
            let timeline = MusicVideoTimeline.make(cuts: result.cuts, videoDurationSecs: duration, songDurationSecs: songDuration)
            await self?.adoptMusicVideoTimeline(timeline, forKey: key, videoID: videoID,
                                                cutCount: result.cuts.count, songDuration: songDuration)
        }
    }

    /// 上一次查 MV 时间轴时用的视频身份与当时显示的歌词来源。歌曲版时长取自「显示的那份歌词」的判决,
    /// 同一首歌的歌词换了来源(collector 播放中重选,见 02 章决策 49 追加)就要按新判决重查一次,见 recheckMusicVideoTimelineIfLyricsChanged。
    private var musicVideoLookupBasis: (key: String, video: BrowserPositionProbe.VideoIdentity, lyricsSource: String?)?

    /// 同一首歌的歌词缓存变了之后调:显示的歌词换了来源才重查,其余情况什么都不做。
    private func recheckMusicVideoTimelineIfLyricsChanged(forKey key: String) {
        guard let basis = musicVideoLookupBasis, basis.key == key, musicVideoLookupKey == key,
              let source = musicVideoLyricsContext(forKey: key)?.lyricsSource, source != basis.lyricsSource else { return }
        logger.notice("music video timeline: lyrics source changed \(basis.lyricsSource ?? "-", privacy: .public) -> \(source, privacy: .public), rechecking song duration")
        musicVideoLookupKey = nil
        noteBrowserVideo(basis.video, forKey: key)
    }

    static let musicVideoSongDurationAttempts = 10
    static let musicVideoSongDurationRetrySecs: Double = 4

    /// 这首歌此刻在歌词缓存里的键与歌词来源;已经换歌返回 nil。缓存读取要在主线程。
    private func musicVideoLyricsContext(forKey key: String) -> (cacheKey: String?, lyricsSource: String?)? {
        guard let snapshot = lastSnapshot, snapshot.trackKey == key else { return nil }
        let artist = snapshot.artist ?? "", title = snapshot.title ?? "", album = snapshot.album ?? ""
        return (EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album),
                EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)?.lyricsSource)
    }

    private func adoptMusicVideoTimeline(_ timeline: MusicVideoTimeline?, forKey key: String, videoID: String,
                                         cutCount: Int, songDuration: Double?) {
        guard lastSnapshot?.trackKey == key else { return }
        guard let timeline else {
            logger.notice("music video timeline: not applied for \(videoID, privacy: .public) (cuts=\(cutCount, privacy: .public) songDuration=\(songDuration ?? -1, privacy: .public))")
            return
        }
        musicVideoTimeline = (key, timeline)
        logger.notice("music video timeline: applied for \(videoID, privacy: .public) (cuts=\(timeline.cuts.count, privacy: .public) complete=\(timeline.isComplete, privacy: .public) songDuration=\(songDuration ?? -1, privacy: .public))")
        if let anchor {
            refreshMusicVideoOffset(atRawMs: anchor.extrapolatedPositionMs())
        } else if let frozen = pausedPositionMs {
            refreshMusicVideoOffset(atRawMs: frozen)
        }
    }

    /// 按此刻的播放位置刷新 MV 偏移,变了才重灌引擎。不是 MV / 时间轴不属于这首歌时归零。
    private func refreshMusicVideoOffset(atRawMs rawMs: Int) {
        var next = 0
        if let mv = musicVideoTimeline, mv.trackKey == lastSnapshot?.trackKey {
            next = mv.timeline.offsetMs(atVideoMs: rawMs)
        }
        guard next != musicVideoOffsetMs else { return }
        musicVideoOffsetMs = next
        applyOffsets()
    }

    /// 认成 MV 的那首歌的 trackKey(见 isMusicVideo)。
    private var musicVideoKey: String?

    /// 这一拍之后「认成 MV 的那首」是哪首。按曲目记住、换歌作废:Apple Music 暂停时不走 JXA
    /// (`MediaControlClient.adaptedSnapshot`),快照里没有这一位;网页那一位要等探针,也不是每拍都有。纯函数,selftest 覆盖。
    public nonisolated static func musicVideoTrackKey(previous: String?, currentKey: String, markedMusicVideo: Bool) -> String? {
        if markedMusicVideo { return currentKey }
        return previous == currentKey ? previous : nil
    }

    /// 换歌 / 停播时清掉 MV 时间轴(偏移随下一次 applyOffsets 归零)。
    private func clearMusicVideoTimeline() {
        musicVideoTimeline = nil
        musicVideoLookupKey = nil
        musicVideoLookupBasis = nil
        musicVideoOffsetMs = 0
    }

    /// 权威广告判据:AppleScript 的 `spotify url` 对广告返回 "spotify:ad:…"。
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
    /// `isGroundTruthSeed`:这一笔读数是不是**探针直接问播放器要来的地面真值**(浏览器探针问网页 DOM、
    /// Spotify 探针问 AppleScript `player position`),而不是 MediaRemote 报的外推值。为真时走一条
    /// 专门的重锚路径,见函数体里那段提醒。`anchorElapsedTime`:这拍快照的原始锚点 elapsedTime,只用来
    /// 给新量出的偏置记"对着哪个锚点量的"(biasSurvivesAnchor)。`streamRaw`:探针那一拍 MediaRemote 自己的
    /// 读数(snapshot.elapsedTime),偏置按它折,见地面真值分支。
    /// - gaplessLeadBundleID: 这一拍的播放器,仅当它 `carriesGaplessLead`(否则 nil)。自然切歌校正、
    ///   repeat-one 回绕重估与偏置的存续都只看它,不看 `tier`。
    /// - clockAction: Spotify 同曲换钟的处置(见 spotifyClockAction),只在同曲稳定播放那条路上生效。
    /// - restoredBias: App 重启后第一拍可接着用的偏置(见 restorablePlayerClockBias),只在换歌分支生效。
    private func resolvePositionSeconds(reported rawReported: Double, rate: Double, key: String, now: Date, tier: PositionSourceTier, gaplessLeadBundleID: String?, clockAction: SpotifyClockAction = .accept, restoredBias: Double? = nil, isGroundTruthSeed: Bool = false, groundTruthFromBrowser: Bool = false, anchorElapsedTime: Double? = nil, streamRaw: Double? = nil, anchorLagSeed: Double = 0) -> (seconds: Double, didReanchor: Bool) {
        // 锚点偏置(见 naturalAdvanceCorrection 一带的注释):同曲期间每笔读数相对真声恒定偏
        // bias(正=超前,负=落后),先扣掉再进入后续所有判断。raw 值只在三处直接用:换歌时的偏置
        // 估计、冻结检测的逐笔差分(常量偏置在差分里天然消掉,但语义上按原始值记)、
        // 以及真实 seek 之后的重新采信(Spotify 重打的新锚点是准的,偏置随之作废)。
        if gaplessLeadBundleID == nil, posReportedBiasSecs != 0 {
            // 同 key 跨播放器接续(同一首歌从 Spotify 切到别的源)不触发换歌分支——偏置
            // 只对 Spotify 这类会领先的源有意义,源变了立即作废。
            setReportedBias(0, anchorElapsed: nil)
        }
        let reported = rawReported - posReportedBiasSecs
        // 冻结检测要用"上一轮的报告值",这里先算差值、再统一记录本轮值(defer 保证
        // 每条退出路径都记,包括下面的各个 early return)。探针那一笔**不记**:它不是
        // MediaRemote 流里的样本,记了会让下一拍的差分变成"探针值→流读数"的假倒退,
        // 恰好落进冻结守卫的"几乎没动"区间(Δ≈2s、间隔 2s 时差分≈0)。
        let reportedAdvance = rawReported - (posPrevReported ?? rawReported)
        defer { if !isGroundTruthSeed { posPrevReported = rawReported } }
        // seek 刚发出去的一小段时间里,播放器可能还没跳过去(或这份快照是 seek 之前抓的)。
        // 这种读数比目标位置更靠近旧位置,采信它就会把刚跳过去的进度条/歌词硬拽回原处。
        // 直接沿用当前外推值(等于"这一轮不更新位置"),等播放器状态跟上。
        // 只对同一首歌生效:seek 永远发生在曲内,换歌那一拍(拖到结尾触发自然切歌/
        // seek 后 1.2s 内恰好换歌)不能被整拍拒收——否则新曲第一拍被吞、apply() 末尾又
        // 已把 posTrackingKey 推进成新曲,换歌分支(含自然切歌校正)被永久跳过
        //。
        if key == posTrackingKey,
           let target = lastSeekTargetSecs, let prev = lastSeekPrevSecs, let at = lastSeekAt,
           Self.shouldRejectStalePositionAfterSeek(
               reported: reported, target: target, previous: prev, elapsedSinceSeek: now.timeIntervalSince(at)
           ) {
            return (trackPosSeconds, false)
        }
        // 默认作废,只有下面几条"位置是连续的"路径把它放回来 —— 新增分支忘了放回来只会
        // 少学一次,忘了作废却会学进一个不是滞后的数。
        let anchorLagSampleWasValid = posAnchorLagSampleValid
        posAnchorLagSampleValid = false
        guard key == posTrackingKey, posWasPlaying, let prevWall = posPrevWall else {
            if key != posTrackingKey {
                // 换歌:先判是不是 gapless 自然切歌——上一首(还在播)按墙钟连续外推已经
                // 走到结尾附近。是的话按连续性播种 + 量出锚点超前量;否则(手动点播/首次
                // 观察/别的播放器)原样采信这次读数、偏置清零。只对 carriesGaplessLead 的源启用:
                // Apple Music 的播放头本身就是真值,QQ/网易云的整秒地板会把偏置估计噪声化。
                var corrected: (seed: Double, bias: Double)?
                // Spotify 自己的钟不走连续性估计,按起播方式给领先量(见 SpotifyStartKind)。
                let isSpotifyPlayerClock = gaplessLeadBundleID == PlaybackPlayer.spotify.bundleIdentifier
                    && anchorElapsedTime == nil
                var spotifyKind: SpotifyStartKind?
                if let bundle = gaplessLeadBundleID, bundle == posPrevGaplessLeadBundleID,
                   posWasPlaying, let prevWall = posPrevWall,
                   posPrevDurationSecs > 0 {
                    let overrun = trackPosSeconds
                        + now.timeIntervalSince(prevWall) * (rate > 0 ? rate : 1)
                        - posPrevDurationSecs
                    if isSpotifyPlayerClock {
                        // 旧曲的钟 = 声音外推 + 旧曲偏置(此刻还没换成新曲的)。
                        spotifyKind = Self.spotifyNaturalStartKind(
                            raw: rawReported, clockOverrun: overrun + posReportedBiasSecs,
                            previousWasAd: posPrevWasAdBreak)
                    } else {
                        corrected = Self.naturalAdvanceCorrection(reported: rawReported, overrun: overrun)
                    }
                    if !isSpotifyPlayerClock, corrected == nil, abs(overrun) <= Self.naturalAdvanceWindowSecs {
                        // 像自然切歌、估出来的偏置却不可信:多半是上一首的位置本身就偏了(重启 / 恢复后没扣
                        // 领先量),偏快顺着连播链往下传。留一行,排查时不用再从 stepMs 反推。
                        logger.notice("natural advance rejected: raw \(rawReported, format: .fixed(precision: 3)) overrun \(overrun, format: .fixed(precision: 3)) → bias \(rawReported - overrun, format: .fixed(precision: 3))")
                    }
                }
                // 学到过锚点滞后的播放器:用它,并让自然切歌那套让位(负=锚点落后真声)。
                // 播种值同样要补上 —— 开播那一笔原始读数是 0,而真声已经走了这么多。
                //
                // 谁优先不是随手定的:滞后量是播放器**自报真实位置**直接量出来的,自然切歌
                // 那套是拿"旧曲外推越过时长多少"间接推的,而旧曲外推本身就带着同一个滞后 ——
                // 真机(汽水音乐,滞后实测 0.54)上它估出来的是「锚点**超前** 0.080」,方向相反、
                // 量级也不对。让它压在滞后补偿上面,等于用间接的错数盖掉直接量到的真数。
                let seedLag = anchorLagSeed
                let natural = seedLag > 0 ? nil : corrected
                // 日志要说的是"这一首最后按哪套播种的",不是"自然切歌估出了什么" —— 估出来
                // 却被让位时照打那行,排查的人会以为它生效了。
                if let natural {
                    logger.notice("natural advance: seed \(natural.seed, format: .fixed(precision: 3))s, anchor leads audio by \(natural.bias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
                } else if seedLag > 0 {
                    // 让位与"压根没估出来"要分开写:拿一个哨兵值混着打,日志会说成"自然切歌估了
                    // −1.000 被让位",而那一刻它其实什么都没估。
                    if let corrected {
                        logger.notice("anchor lag seeded: \(seedLag, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)), natural advance estimate \(corrected.bias, format: .fixed(precision: 3)) superseded)")
                    } else {
                        logger.notice("anchor lag seeded: \(seedLag, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
                    }
                }
                setReportedBias(natural?.bias ?? -seedLag, anchorElapsed: anchorElapsedTime)
                trackPosSeconds = natural?.seed ?? (rawReported + seedLag)
                if natural == nil, seedLag == 0, let restoredBias {
                    // App 重启后的第一拍,接着用上一个进程给这首歌量的偏置(见 restorablePlayerClockBias)。
                    logger.notice("anchor bias restored after relaunch: \(restoredBias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
                    setReportedBias(restoredBias, anchorElapsed: nil)
                    trackPosSeconds = rawReported - restoredBias
                } else if isSpotifyPlayerClock {
                    // 上一拍不在播(首次观察 / 暂停中换了歌)时不知道怎么起播的:按 fresh 给,但不学。
                    let kind = spotifyKind ?? .fresh
                    let lead = spotifyStartLead(kind)
                    logger.notice("spotify start lead: kind=\(kind.rawValue, privacy: .public)\(spotifyKind == nil ? " (unknown start)" : "", privacy: .public) lead \(lead, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
                    setReportedBias(lead, anchorElapsed: nil, startKind: spotifyKind)
                    trackPosSeconds = rawReported - lead
                }
                // 自然切歌接手的那一首不采样(两套补偿会互相学);剩下的只认真·开播。
                posAnchorLagSampleValid = natural == nil && rawReported <= Self.anchorLagFreshStartMaxSecs
            } else {
                // 刚从暂停恢复播放 / 首次观察(同曲)。这一笔读数在暂停期间被 elapsedTimeNow
                // 空转污染过,不能原样采信 —— 削掉"不可能发生的前跳",见 resumeSeedSeconds。
                let sinceSignal = posStateSignalAt.map { now.timeIntervalSince($0) }
                    ?? Self.resumeMaxForwardCapSecs
                trackPosSeconds = Self.resumeSeedSeconds(
                    reported: reported,
                    frozen: pausedPositionMs.map { Double($0) / 1000 },
                    maxForwardSecs: sinceSignal)
                // Spotify 自己的钟恢复播放后重新领先(见 resumeLead):播种值就是真声,差值折进偏置。
                if gaplessLeadBundleID != nil, anchorElapsedTime == nil, posStateSignalAt != nil,
                   pausedPositionMs != nil,
                   let lead = Self.resumeLead(raw: rawReported, seed: trackPosSeconds) {
                    logger.notice("resume lead: seed \(self.trackPosSeconds, format: .fixed(precision: 3))s, player clock leads audio by \(lead, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
                    setReportedBias(lead, anchorElapsed: nil)
                }
            }
            posErrEMA = 0
            // 换歌 / 恢复播放:上一段的「晚锚点已确认过」记录作废(见 posLateAnchorProbedElapsed)。
            posLateAnchorProbedElapsed = nil
            return (trackPosSeconds, true)
        }
        let gap = now.timeIntervalSince(prevWall)
        let predicted = trackPosSeconds + gap * rate
        switch clockAction {
        case .accept:
            break
        case .hold:
            trackPosSeconds = predicted
            return (trackPosSeconds, false)
        case .switchClock:
            logger.notice("spotify clock switch: raw=\(rawReported, format: .fixed(precision: 3)) predicted=\(predicted, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3)) toPlayerClock=\(anchorElapsedTime == nil)")
            setReportedBias(0, anchorElapsed: nil)
            trackPosSeconds = rawReported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        // 探针的**一次性地面真值**:不走 EMA,超过门槛直接重锚。
        //
        // 这条必须有,否则这个纠偏**几乎永远不会生效**(用真机日志坐实)。
        // 它是"每首歌一次"的样本,而 `servoDecision` 对 noisyFloored 是 alpha 0.3 / 门槛 1.0
        // —— 单个样本最多把 EMA 推到 `0.3 × 误差`,要误差超过 **3.33 秒**才可能触发。实测
        // 连着三首歌 `ema=-0.197 / -0.206 / -0.226`、`snap=false`,而同期离屏逐帧量到的真实
        // 偏差是 0.7~0.9 秒(App 偏快):**探针每次都测准了、每次都被扔掉**。
        //
        // 一次性直接采信跟 `BrowserPositionProbe` 类头注那条"不要持续覆盖"的教训**不冲突**:
        // 那次的病根是**每 ~0.9 秒**拿一份整秒读数覆盖一次连续外推,造成周期性回退;这里每首歌
        // 只发生一次,采信完立刻把稳态精度交还给连续外推。
        //
        // 位置有讲究(从 seek 分支之后挪到冻结守卫之前):探针这一笔不是流里的样本,
        // 冻结 / 回绕 / seek 三条守卫对它都是误判 —— 尤其 seek 分支:差超过 2s 时把它当"用户拖动"
        // 采信后顺手清偏置,下一拍流读数又差回 2s、再被当成一次拖动重锚回去,纠偏活不过一拍。
        // 它仍必须排在前向棘轮**之前** —— 浏览器探针值做过去地板补偿(`flooredMidpointBiasSecs`),
        // 不再满足棘轮赖以成立的"reported ≤ 真实位置"。
        //
        // **Spotify(cleanExtrapolated)要把量到的差折进偏置,不能只重锚一次**:Spotify
        // 给歌曲发 now-playing 常晚 ~2s 而 elapsedTime 仍是 0,之后整首歌 MediaRemote 的每笔
        // 读数都从这个晚打的锚点外推、恒定落后 ~2s。只重锚一次的话,下一拍起流读数与外推
        // 差回 ~2s:差 >2s 走 seek 分支当场拽回,差 <2s 三拍 EMA 拽回(限幅 ±0.75、门槛
        // 0.4)—— 实测(vampire 15:01:07 重锚 +1.956,
        // 15:01:42 暂停时又落后 1.817、errEMA≈0(伺服认为一切正常)。把 Δ 折进 posReportedBiasSecs
        // (负值=锚点落后)之后,后续每笔读数先加回这段差,与重锚后的外推一致,伺服才不会再"纠正"回去。
        // 探针值本身在 Spotify 的钟域里,与流读数同源,先扣同一个旧偏置再比是对的(gapless 时
        // 它同样超前真声 ~0.9s,见 SpotifyPositionProbe 头注)。偏置归属这一拍的锚点
        // (biasSurvivesAnchor):暂停 / 拖动后 Spotify 重发的锚点是准的,偏置随之作废。
        if isGroundTruthSeed {
            // 网页探针的精确读数是页面自己的钟,不在流读数的钟域里,不扣流的旧偏置。
            let truth = groundTruthFromBrowser ? rawReported : reported
            let delta = truth - predicted
            let tolerance = groundTruthFromBrowser
                ? BrowserPositionProbe.preciseSnapToleranceSecs : Self.groundTruthSnapToleranceSecs
            guard abs(delta) > tolerance else {
                // 差在门槛内:探针与流一致,这一笔什么都不改。noisyFloored 保持 09-02 以来的
                // 行为继续往下走(棘轮 / EMA 照常吃这一笔);cleanExtrapolated 直接沿用外推。
                if tier == .cleanExtrapolated {
                    trackPosSeconds = predicted
                    return (trackPosSeconds, false)
                }
                return resolveSteadyState(reported: reported, predicted: predicted, key: key, tier: tier)
            }
            if tier == .cleanExtrapolated, let streamRaw {
                // 偏置 = **这一拍流读数** − 探针值,不是 predicted − 探针值(
                // greedy 实测:开播半秒 Spotify 把锚点从 0@47 改发成 2.434@48,流读数已跟着新锚点、
                // 我们的外推还在旧锚点上,两者差 1.45s;按 predicted 折出 −2.025,流读数再扣它就
                // 超前真声 1.5s,暂停时 delta=+0.523、恢复回退 −1.100)。偏置的定义是"流读数相对
                // 真声偏多少",量它就得拿流读数本身当被减数;我们自己的外推只决定"这一下要不要重锚"。
                // 不设上限:探针已经两次采样验过钟在走(SpotifyPositionProbe.clockIsRunning),而流那边
                // 倒是会差出 60~110 秒(Spotify 把开播那份 now-playing 带着新时间戳晚发,elapsed 0.367
                // / 2.458 落在播到 60s / 110s 的时候,决策 29)—— 上限取 6s 会恰好把这两次真纠偏
                // 都挡了。
                setReportedBias(
                    Self.probeMeasuredBias(streamRaw: streamRaw, probeRaw: rawReported),
                    anchorElapsed: anchorElapsedTime, fromProbe: !groundTruthFromBrowser,
                    fromBrowserProbe: groundTruthFromBrowser)
            }
            logger.notice("browser probe reanchor: reported=\(truth, format: .fixed(precision: 3)) predicted=\(predicted, format: .fixed(precision: 3)) delta=\(delta, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3)) precise=\(groundTruthFromBrowser)")
            trackPosSeconds = truth
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        // 冻结守卫(必须在 seek 分支**之前**):冻结的读数越冻越落后,几秒
        // 后就会超过 2s 的 seek 容差 —— 放到 seek 分支后面的话,位置会被"重锚"回冻结值,
        // 歌尾歌词整段倒回去。命中时维持墙钟外推、不喂 EMA;解冻那一拍报告值大步前跳,
        // 自然落进 seek 分支瞬间追上。判据与边界见 isFrozenReport 注释。
        if Self.isFrozenReport(reportedAdvance: reportedAdvance, gap: gap, rate: rate, tier: tier) {
            trackPosSeconds = predicted
            posAnchorLagSampleValid = anchorLagSampleWasValid
            return (trackPosSeconds, false)
        }
        // 单曲循环(repeat-one)的 gapless 回绕:key 不变、走不到换歌分支,但与跨曲自然
        // 切歌是同一机制(引擎驱动的自然过渡,新锚点先于真声打好)——不识别的话会落进
        // 下面的 seek 分支把量准的偏置清掉,循环第 2 遍起整曲回到偏快(对抗
        // 审查抓出)。签名=外推已到曲尾窗口、且按"回绕真值=越界量"估出的偏置落在可信
        // 区间(稳定播放到曲尾时 raw 是大值,估出的偏置≈整曲时长,天然不命中;向后拖到
        // 曲首的误判面与"手动跳歌落窗"同级,伤害同被 2.5s 上限钉死且方向偏慢)。
        let isSpotifyPlayerClock = gaplessLeadBundleID == PlaybackPlayer.spotify.bundleIdentifier
            && anchorElapsedTime == nil
        // Spotify 自己的钟:回绕同样按起播方式给领先量(见 SpotifyStartKind),签名 = 读数回到曲首、外推在曲尾附近。
        if isSpotifyPlayerClock, posPrevDurationSecs > 0,
           rawReported < Self.naturalAdvanceWindowSecs,
           abs(predicted - posPrevDurationSecs) <= Self.naturalAdvanceWindowSecs {
            let kind: SpotifyStartKind = Self.isPreloadedGaplessStart(
                raw: rawReported, clockOverrun: predicted + posReportedBiasSecs - posPrevDurationSecs) ? .gapless : .fresh
            let lead = spotifyStartLead(kind)
            logger.notice("repeat-one wrap: spotify start lead kind=\(kind.rawValue, privacy: .public) lead \(lead, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
            setReportedBias(lead, anchorElapsed: nil, startKind: kind)
            trackPosSeconds = rawReported - lead
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        if !isSpotifyPlayerClock, gaplessLeadBundleID != nil, posPrevDurationSecs > 0,
           let corr = Self.naturalAdvanceCorrection(reported: rawReported, overrun: predicted - posPrevDurationSecs) {
            logger.notice("repeat-one wrap: seed \(corr.seed, format: .fixed(precision: 3))s, anchor leads audio by \(corr.bias, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
            setReportedBias(corr.bias, anchorElapsed: anchorElapsedTime)
            trackPosSeconds = corr.seed
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        // Spotify 自己的钟在歌尾会停住或往回退:这一段照外推走,见 inPlayerClockTail。排在 seek 分支之前 ——
        // 停住的读数加上偏置,几拍就够得着 2s 容差,会被当成一次往回拖。只对会领先的源(Spotify)开。
        if gaplessLeadBundleID != nil,
           Self.inPlayerClockTail(predicted: predicted, raw: rawReported, duration: posPrevDurationSecs, anchorElapsedTime: anchorElapsedTime) {
            trackPosSeconds = predicted
            return (trackPosSeconds, false)
        }
        if abs(reported - predicted) > Self.seekJumpToleranceSecs {
            // 真实 seek/跳变:直接重锚到这次读数。seek 时 Spotify 会重打锚点,重打后的
            // 锚点与真声对齐(与手动点播同一性质),自然切歌偏置随之作废——清零并改信
            // 原始读数,否则整首歌会反向偏慢一个旧偏置。
            //
            // 已知边界(对抗审查确认,单源本质歧义、接受不修):偏置在位时,
            // 用户在 Spotify 自己界面里**小幅**拖动(幅度 < 偏置+2s ≈ 3s)——重打后的
            // 锚点是准的,但扣着旧偏置的读数跳变量 |d−bias| 不过 2s 门槛,进不来这个
            // 分支,伺服会把该曲余下部分收敛到"真声−偏置"(恒慢 ~0.9s)。单凭
            // elapsedTimeNow 分不出"带偏置的锚点没动"和"准锚点+拖了≈偏置":拖动
            // ≥3s(绝大多数)正常进此分支纠正,换歌即自愈。
            setReportedBias(0, anchorElapsed: nil)
            trackPosSeconds = rawReported
            posErrEMA = 0
            if isSpotifyPlayerClock {
                // Spotify 自己的钟:拖动之后同样先于出声跑一截(见 SpotifyStartKind.seek);
                // 跳回开头且刚收到过「从头播放」的通知的是重新起播,按 fresh(见 spotifyJumpKind)。
                let kind = Self.spotifyJumpKind(
                    raw: rawReported, playingFromStartNoticeAt: spotifyPlayingFromStartNoticeAt, now: now)
                let lead = spotifyStartLead(kind)
                logger.notice("spotify start lead: kind=\(kind.rawValue, privacy: .public) lead \(lead, format: .fixed(precision: 3))s (raw \(rawReported, format: .fixed(precision: 3)))")
                setReportedBias(lead, anchorElapsed: nil, startKind: kind)
                trackPosSeconds = rawReported - lead
            }
            // Spotify 原生:先照单全收,再问一次 Spotify 的钟确认这个新锚点是真的(
            // 见 SpotifyPositionProbe.requestConfirmation)。真拖动探针与新锚点一致、什么都不改;
            // Spotify 把开播那份 now-playing 带着新时间戳晚发(播到 60s 时来一个 0.367)那种假锚点,
            // 探针 ~1s 后把位置纠回去、差折进偏置。只对 cleanExtrapolated:探针本来就只对它开。
            if tier == .cleanExtrapolated {
                env.spotifyProbeRequestConfirmation(key)
            }
            return (trackPosSeconds, true)
        }
        // Spotify 自己的钟开播头几秒还没走起来(加载中,实测首笔 0.001、1.3s 后才到 0.087):我们按起播领先量
        // 播的种已经往前外推,读数反而落在后面。这不是"钟对齐了",是钟起步晚了 —— 跟着钟重新对准,偏置保留。
        // 必须排在 playerClockResynced 之前,否则会被当成对齐、连偏置一起清掉。
        if isSpotifyPlayerClock, posReportedBiasSecs > 0,
           Self.playerClockStartedLate(raw: rawReported, reported: reported, predicted: predicted) {
            logger.notice("player clock started late: reported=\(reported, format: .fixed(precision: 3)) predicted=\(predicted, format: .fixed(precision: 3)) raw=\(rawReported, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3))")
            trackPosSeconds = reported
            posErrEMA = 0
            // 偏置文件里那一份的位置已经对不上了,下一拍按新位置重写(collector 靠它核连续性)。
            lastPublishedBias = nil
            return (trackPosSeconds, true)
        }
        // 读的是 Spotify 自己的钟、偏置在位,读数退回了约一个偏置量:钟已对回出声位置(没看到的暂停 /
        // 往回小拖),见 playerClockResynced。必须排在伺服之前 —— precise 档一拍就会吸附到"慢一个偏置"的值上。
        if Self.playerClockResynced(error: reported - predicted, bias: posReportedBiasSecs, anchorElapsedTime: anchorElapsedTime) {
            logger.notice("player clock resync: reported=\(reported, format: .fixed(precision: 3)) predicted=\(predicted, format: .fixed(precision: 3)) raw=\(rawReported, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3))")
            setReportedBias(0, anchorElapsed: nil)
            trackPosSeconds = rawReported
            posErrEMA = 0
            return (trackPosSeconds, true)
        }
        // 跳变够不着 seek 容差、但读数相对外推**向后**退了半秒以上:Spotify 中途重发的晚锚点
        // 长这个样子,机制与取值见 shouldProbeLateAnchor。只问探针,位置照旧往下走伺服。
        if Self.shouldProbeLateAnchor(reported: reported, predicted: predicted, tier: tier),
           anchorElapsedTime != posLateAnchorProbedElapsed {
            posLateAnchorProbedElapsed = anchorElapsedTime
            logger.notice("late anchor suspected: reported=\(reported, format: .fixed(precision: 3)) predicted=\(predicted, format: .fixed(precision: 3)) behind=\(predicted - reported, format: .fixed(precision: 3)) anchorElapsed=\(anchorElapsedTime ?? -1, format: .fixed(precision: 3))")
            env.spotifyProbeRequestConfirmation(key)
        }
        posAnchorLagSampleValid = anchorLagSampleWasValid
        return resolveSteadyState(reported: reported, predicted: predicted, key: key, tier: tier)
    }

    /// resolvePositionSeconds 的尾段:前向棘轮 + 偏差 EMA 伺服。拆出来是因为探针那一笔差在门槛内时
    /// (noisyFloored)也要走到这里,与 09-02 以来的行为一致。
    private func resolveSteadyState(reported: Double, predicted: Double, key: String, tier: PositionSourceTier) -> (seconds: Double, didReanchor: Bool) {
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

    // Music.app 的播放状态变化通知(加,借鉴 FlowX)——见
    // startObservingPlayerInfoNotification() 的注释。
    private var playerInfoObserver: NSObjectProtocol?
    private var spotifyInfoObserver: NSObjectProtocol?
    /// Spotify 最近一条 PlaybackStateChanged 通知里的分类提示(Track ID / Name / Artist),给换曲那一拍的
    /// 广告判定用,见 spotifyNativeAdCheckForNewTrack 与 SpotifyNotificationHint 头注。只在 apply() 里读。
    private var spotifyNotificationHint: SpotifyNotificationHint?
    /// 最近一条「Playing、位置 ≈0」的 Spotify 通知是什么时候到的(见 spotifyJumpKind)。
    private var spotifyPlayingFromStartNoticeAt: Date?
    // media-control 的事件流(QQ 音乐/网易云没有分布式通知,靠它)。见
    // MediaControlStreamWatcher —— 事件同样只当"提前 poll 一次"的信号。
    private var streamWatcher: MediaControlStreamWatcher?
    // 通知去抖动:待触发的那次补查(收到新通知就取消重排)——见
    // handlePlayerInfoChanged() 的注释。
    private var pendingNotificationPoll: Task<Void, Never>?
    private static let playerInfoDebounce: Duration = .milliseconds(250)

    /// 位置状态机的外部依赖(见 PlaybackPositionEnvironment)。
    private let env: PlaybackPositionEnvironment

    private init() {
        env = .live
        currentOutputRoute = env.outputRoute()
    }

    private init(environment: PlaybackPositionEnvironment) {
        env = environment
        currentOutputRoute = environment.outputRoute()
    }

    /// 回放测试用的独立实例:不 `start()`、不挂通知,外部依赖全换成 `environment`。
    public static func makeForPositionReplay(environment: PlaybackPositionEnvironment) -> LocalPlaybackSource {
        LocalPlaybackSource(environment: environment)
    }

    /// 回放一拍快照:key 与换歌的算法同 `apply`,只跑位置状态机。
    public func replayPosition(_ snapshot: MediaControlSnapshot, now: Date, isAdBreak: Bool = false) {
        let key = snapshot.identityKey
        let trackChanged = key != lastKey
        let previousKey = lastKey
        if trackChanged { lastKey = key }
        lastSnapshot = snapshot
        applyPosition(snapshot: snapshot, key: key, trackChanged: trackChanged, previousKey: previousKey,
                      isSpotifyNative: snapshot.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier,
                      isAdBreak: isAdBreak, now: now)
    }

    /// 回放:一条播放器状态通知到达(线上是 handlePlayerInfoChanged:记下时刻;暂停类通知同时冻住外推)。
    public func replayPlayerStateEvent(at date: Date, freeze: Bool) {
        posStateSignalAt = date
        if freeze { freezeExtrapolationUntilNextPoll(now: date) }
    }

    /// 回放:Spotify「Playing、位置 ≈0」通知到达的时刻(线上由通知观察者记,见 spotifyJumpKind)。
    public func replaySpotifyPlayingFromStartNotice(at date: Date) { spotifyPlayingFromStartNoticeAt = date }

    /// 回放:此刻屏上的位置(播放中按锚点外推,暂停时是冻结位置)。
    public func replayPositionMs(at now: Date) -> Int? {
        anchor?.extrapolatedPositionMs(now: now) ?? pausedPositionMs
    }

    /// 回放:当前在用的锚点偏置(正 = 读数超前真声)。
    public var replayReportedBiasSecs: Double { posReportedBiasSecs }

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
    // 无关)。借鉴 FlowX(Kadxy/FlowX,同类菜单栏歌词工具)加上这条订阅,
    // 补上 2 秒轮询天然的感知延迟。
    //
    // 设计取舍(刻意的,不要"顺手优化"掉):通知**只当作"提前触发一次 poll()"的信号**,
    // 完全不从 notification.userInfo 里取标题/播放状态/位置去直接喂状态——虽然那份
    // userInfo 里确实带着这些字段(FlowX 就是直接用的)。理由是这个类的状态机已经相当
    // 微妙(poll 世代号防乱序、resolvePositionSeconds 的位置平滑+伺服校正、
    // ensureFastTimerRunning 的生命周期),再引入一条"绕过 poll() 直接改状态"的并行
    // 路径,就会出现两套数据源需要互相对账:通知先到还是轮询先到、通知里的位置跟
    // AppleScript 读数哪个更准、平滑器该信谁——这些都是实打实的乱序 bug 温床。现在的
    // 写法让所有状态变更仍然只发生在 apply() 这一条路径上,通知的唯一作用是让那条路径
    // 提早跑一次,已有的世代号防护(见 poll())原样继续生效、不需要任何改动。
    //
    // 有一个划得很窄的例外(与 02 章决策 1 里 stream watcher 那条同性质):Spotify 那条通知
    // 的 userInfo 会被读 **Track ID / Name / Artist 三个键**,只为给换曲那一拍的广告分类提供权威依据
    // (`spotify:ad:` 前缀,跟 AppleScript `spotify url` 是同一个值,但不用 fork 子进程、而且比 MediaRemote
    // 那份 now-playing 早到)。位置、播放状态、标题**仍然一律不从通知喂**;分类结果也只在 apply() 里、按快照的
    // 歌名/歌手核对过之后才生效(见 spotifyNativeAdCheckForNewTrack)。通知没收到就退回原来的 osascript。
    //
    // Apple Music 和 Spotify 都广播分布式通知,两个都订阅。
    //
    // 这里原来写着"Spotify 不广播这个通知……这些播放器没有等价机制",那句话是错的:
    // Spotify 有自己的 com.spotify.client.PlaybackStateChanged(审阅
    // lycrics_notch 时发现,它的 SpotifyController 一直在用),我们却只订阅了 Apple Music
    // 那条,于是 Spotify 用户白等 2 秒轮询。QQ 音乐/网易云确实没有等价通知,它们靠
    // media-control 的事件流(见 MediaControlStreamWatcher)。
    //
    // 两条订阅都不按 features.players 条件挂载:某个播放器可能开着但不在当前选中集合里,
    // 那种情况下补查一次 poll() 完全无害(poll() 自己会核对 bundleIdentifier,见
    // MediaControlClient.fetchSnapshot 的各条分支)。
    private func startObservingPlayerInfoNotification() {
        startStreamWatcher()
        // Spotify 位置探针顺带带回的图床地址落到 spotifyArtworkURL(还是这首才收,见 noteSpotifyArtwork)。
        SpotifyPositionProbe.shared.setArtworkSink { [weak self] key, url in
            Task { @MainActor [weak self] in self?.noteSpotifyArtwork(url: url, forKey: key) }
        }
        // 网页版 Spotify 同款:浏览器位置探针从页面 cover-art-image 顺带读到图床地址,也落到同一个
        // 属性;下游 PlaybackCoordinator 那条原图档替代路不分原生还是网页。
        BrowserPositionProbe.shared.setArtworkSink { [weak self] key, url in
            Task { @MainActor [weak self] in self?.noteSpotifyArtwork(url: url, forKey: key) }
        }
        // 同一次探针顺带读到的视频身份:是 MV 时按 SponsorBlock 片段换算时间轴(见 noteBrowserVideo)。
        BrowserPositionProbe.shared.setVideoSink { [weak self] key, video in
            Task { @MainActor [weak self] in self?.noteBrowserVideo(video, forKey: key) }
        }
        // 探针结果一落地就补查一次,不等下一拍 2s 轮询来消费:poll() 自己会核对曲目,
        // 消费那边还有 posWasPlaying / key 两道门,多这一次查询完全无害。
        SpotifyPositionProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // 两条**广告闸**探针同款。它们跟上面那条位置探针不是一回事:位置探针迟到
        // 只是位置晚几秒纠偏,这两条迟到会让快照被 `gate` 整条丢掉 —— 换曲/广告边界那一拍新 key
        // 下缓存必然是空的,fail-closed 拒掉之后原本要干等一整个轮询周期才有人去读探针刚探回来的
        // 结果,这段干等就是用户看到的"广告完了之后几秒没有歌曲信息、灵动岛退到兜底图标"。
        // 挂上之后这段等待 = 探针往返本身(~187ms)。poll() 自己会核对曲目身份,多查一次无害。
        YouTubeMusicAdProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        SpotifyWebAdProbe.shared.setResultSink { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // 默认输出设备一换,探针领先量跟着换(见 probeLeadByDevice 一带注释)。
        AudioOutputRoute.startObserving { [weak self] in
            Task { @MainActor [weak self] in self?.outputRouteChanged() }
        }
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
            object: nil, queue: .main) { [weak self] note in
                // 只读 Track ID / Name / Artist 做广告分类(上面那段 里的窄例外);位置与播放状态照旧只当
                // "提前 poll 一次"的信号。userInfo 在主队列上读,跟下面 handler 同一条路。
                let hint = SpotifyNotificationHint(userInfo: note.userInfo)
                let playingFromStart = (note.userInfo?["Player State"] as? String) == "Playing"
                    && ((note.userInfo?["Playback Position"] as? NSNumber)?.doubleValue ?? .infinity) < 1
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let hint, self.spotifyNotificationHint != hint { self.spotifyNotificationHint = hint }
                    if playingFromStart { self.spotifyPlayingFromStartNoticeAt = Date() }
                    self.handlePlayerInfoChanged()
                }
            }
    }

    // media-control 事件流跟两条分布式通知走**同一条**去抖动补查路径:三个来源都只是
    // "有动静了"的信号,合并成一次 poll() 正是想要的效果(比如 Spotify 换歌会同时触发
    // 它自己的通知和 MediaRemote 的事件,合并后只查一次)。
    private func startStreamWatcher() {
        guard streamWatcher == nil else { return }
        let watcher = MediaControlStreamWatcher { [weak self] pauseSignal, resumeSignal in
            MainActor.assumeIsolated {
                self?.handlePlayerInfoChanged(freezeExtrapolation: pauseSignal,
                                              stateSignal: pauseSignal || resumeSignal)
            }
        }
        streamWatcher = watcher
        watcher.start()
    }

    // 通知到达 → 去抖动之后补查一次 poll()。
    //
    // 用"去抖动"(延迟一小段再查,期间再来通知就重新计时)而不是"立刻查一次+之后节流",
    // 是实测量出来的必要选择,不是随手挑的:
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
    /// `freezeExtrapolation` = 这个信号有没有可能意味着播放状态变了。
    ///
    /// 别无条件冻:冻结期间位置**完全不走**,而逐字填色直接读这个锚点 —— 一次信号就是
    /// 一次几百毫秒的停顿再跳过去(实测 148~462ms)。两条分布式通知本来就只在状态变化时发,
    /// 照旧冻;media-control 事件流不一样,它连锚点刷新也发,而把当前歌词行塞进署名字段的
    /// 播放器**每唱一句就刷新一次锚点** —— 那种信号按状态变化处理,就是每句开头顿一下。
    private func handlePlayerInfoChanged(freezeExtrapolation: Bool = true,
                                        stateSignal: Bool = true) {
        // 记时刻和冻结外推是**两件事**:冻结只认暂停(纯锚点刷新冻了就是每句一顿),
        // 而"状态什么时候变的"这个上界,暂停和恢复都要记。
        if stateSignal { posStateSignalAt = Date() }
        if freezeExtrapolation { freezeExtrapolationUntilNextPoll() }
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
    /// 现象是的就是这个("为什么有时候暂停的时候进度条会突然回退一点")——
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
    /// 这个冻结锚点靠 apply() 里那句 `needsNewAnchor` 中的 `anchor?.rate != rate`
    /// 被换掉:冻结时 rate 置 0,而播放中的 rate 是 1,两者不等就必然重建锚点。仍在播放
    /// 时走这条(位置继续走),已经暂停则走 `anchor = nil` 那条。**别把 needsNewAnchor
    /// 里的 rate 比较去掉** —— 去掉之后稳定播放期间会认为"不必重锚",这个 rate=0 的锚点
    /// 就永远留在那儿,进度条从此不动。
    private func freezeExtrapolationUntilNextPoll(now: Date = Date()) {
        guard let current = anchor, current.rate > 0 else { return }
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

    /// 轮询间隔按播放状态分档:每一拍都要 fork 一个子进程
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
        /// 刚开始拿不到快照的头几拍仍按播放档轮询,之后才认命降档。见 `desiredPollInterval`。
        static let nilGraceTicks = 3
    }

    private var currentPollInterval: TimeInterval = PollInterval.playing

    /// 此刻该用的轮询间隔。暂停(有曲目没在放)6s:用户在播放器里拖进度条这类"不发通知
    /// 的静默变化"最坏晚 6s 被兜到,可接受;空闲(连曲目都没有)10s。
    ///
    /// **刚失去快照的头几拍必须留在 2s 档**。`clearIfWasPlaying()` 会把
    /// title 清空(那是对的,停播不该留半吊子状态),于是下面那行立刻判成"空闲"、降到 10s ——
    /// 而快照变 nil 最常见的原因**根本不是空闲**,是浏览器播放的广告闸 fail-closed 丢了这一拍
    /// (`trustedPlaybackRejected` → 探针判定还没到 → `gate` 拒)。一拍本该 2 秒就自愈的
    /// 抖动,被这次降档自己延长成 10 秒:**一次拿不到 → 把下次去拿的时间推迟 5 倍**,而
    /// 探针 ~187ms 就把结果放进缓存了,没人去读。
    ///
    /// 真机实测(16:02:24.464 `snapshot failed` → 16:02:31.486 `snapshot recovered`)
    /// 真空期 **7.0 秒**,期间菜单栏 16:02:27.651 `slot rebuild: fixed(223.5) -> icon(38.5)`
    /// 塌成图标、灵动岛同时退到兜底图标。那 7 秒还是**侥幸**:靠 16:02:31 一条 media-control
    /// 事件唤醒补查才提前救回,没有那条事件就是满 10 秒。
    ///
    /// 3 拍 = 6 秒:真停播(Music.app 退出 / 播放列表放完)时多跑两次 poll 就降档,代价可忽略;
    /// 而任何"一两拍就自愈"的抖动全程留在 2s 档。
    private var desiredPollInterval: TimeInterval {
        if isPlayingNow { return PollInterval.playing }
        if consecutiveNilSnapshots > 0, consecutiveNilSnapshots <= PollInterval.nilGraceTicks {
            return PollInterval.playing
        }
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
    /// 只停这一条:2 秒 poll 必须继续跑,否则锁屏期间听的歌不会被记录、Last.fm /
    /// ListenBrainz 提交会整段丢失 —— 那是不可恢复的数据,省一点电不值当。
    public func setScreenLocked(_ locked: Bool) {
        guard screenLocked != locked else { return }
        screenLocked = locked
        logger.notice("screen \(locked ? "locked" : "unlocked", privacy: .public); word-level tick \(locked ? "paused" : "resumed", privacy: .public)")
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
    /// apply() 和 fastTick() 必须都走这里。这两处本来各写了一份"anchor 为 nil 就三连
    /// 清空",于是把 apply() 那份改成"暂停不清行"之后,fastTick() 那份还在原样清 —— 而
    /// seek(toMs:) 末尾是**无条件**调 fastTick() 的(为了拖动进度条时歌词立刻跟到新位置),
    /// 所以暂停状态下拖一次进度条,行又被清掉,要等下一次 apply()(2 秒轮询)才回来。抽成
    /// 一处,两边不可能再错开。
    ///
    /// 不要在这里另外加 currentLyricsOffsetMs:activeLine/upcomingLineText/activeLineIndex
    /// 内部都会先做 rawPosMs + offsetMs(见 LyricsSyncEngine),手动再加一次就是双倍校正。
    /// 记下这个台的台卡。名字一变就落盘;封面要等取图那条路回来(台卡那一拍常常没有图)。
    private func noteRadioStationCard(name: String, hash: String, trackKey: String) {
        pendingStationCardKey = trackKey
        guard radioStationCard?.stationHash != hash || radioStationCard?.name != name else { return }
        // 换台了就整张换掉(旧台的封面扣在新台头上比没有封面更糟);同台改名只换名字、留住封面。
        let keptArtwork = radioStationCard?.stationHash == hash ? radioStationCard?.artwork : nil
        let card = RadioStationCard(stationHash: hash, name: name, artwork: keptArtwork)
        radioStationCard = card
        RadioStationCardFile.write(card)
        logger.notice("radio station card: name=\(name, privacy: .public) hasArtwork=\(keptArtwork != nil)")
    }

    /// 取图那条路拿到了图 —— 如果它属于刚才那张台卡,就补进去。
    private func noteRadioStationArtwork(_ data: Data?, forKey key: String) {
        guard let data, !data.isEmpty, key == pendingStationCardKey,
              var card = radioStationCard, card.artwork != data else { return }
        card.artwork = data
        radioStationCard = card
        RadioStationCardFile.write(card)
        if radioStationName == card.name { radioStationArtwork = data }
        logger.notice("radio station card: artwork attached bytes=\(data.count)")
    }

    /// 把"当前该显示哪一行"这一组发布状态清干净。**只清行,不碰曲目 / 封面 / 时长** ——
    /// 那是 clearIfWasPlaying() 的活(整个停播)。逐个先比再赋:这些都是 @Published,
    /// 无条件赋值会让订阅者每拍重渲染(理由同 apply() 里那段注释)。
    private func clearLineDisplay() {
        if currentLine != nil { currentLine = nil }
        if nextLineText != nil { nextLineText = nil }
        if nextLineSide != nil { nextLineSide = nil }
        if nextLineRomanization != nil { nextLineRomanization = nil }
        if nextLineTranslation != nil { nextLineTranslation = nil }
        if nextLineWordGroups != nil { nextLineWordGroups = nil }
        if currentLineIndex != nil { currentLineIndex = nil }
        if scrollLineIndex != nil { scrollLineIndex = nil }
        if compactLine != nil { compactLine = nil }
        if compactShowsPlaceholder { compactShowsPlaceholder = false }
        if compactDwellMs != nil { compactDwellMs = nil }
        if compactLeadInMs != nil { compactLeadInMs = nil }
        // 没有可显示的行,间奏点和"填色未定格"也一并归位 —— 别让上一首歌的残留值
        // 挂着(fillSettled 归 true:没有行就没有可动的填色,表该停着)。
        if currentGapIndex != nil { currentGapIndex = nil }
        if rawGapWindow != nil { rawGapWindow = nil }
        if !currentLineFillSettled { currentLineFillSettled = true }
    }

    private func resolveLinesForPausedPosition() {
        guard let frozen = pausedPositionMs, syncEngine.hasContent, !radioTrackFinished else {
            clearLineDisplay()
            return
        }
        refreshMusicVideoOffset(atRawMs: frozen)
        // 打包查询:四个值要的是同一个 posMs 的同一次定位,原来四个入口各自从头扫一遍
        // (性能审计,见 LyricsSyncEngine.tickQuery)。
        let r = syncEngine.tickQuery(atMs: frozen, trackEndMs: currentDurationMs)
        if r.line != currentLine { currentLine = r.line }
        if r.compactLine != compactLine { compactLine = r.compactLine }
        if r.compactPlaceholder != compactShowsPlaceholder { compactShowsPlaceholder = r.compactPlaceholder }
        if r.compactDwellMs != compactDwellMs { compactDwellMs = r.compactDwellMs }
        if r.compactLeadInMs != compactLeadInMs { compactLeadInMs = r.compactLeadInMs }
        if r.nextText != nextLineText { nextLineText = r.nextText }
        if r.nextSide != nextLineSide { nextLineSide = r.nextSide }
        if r.nextRomanization != nextLineRomanization { nextLineRomanization = r.nextRomanization }
        if r.nextTranslation != nextLineTranslation { nextLineTranslation = r.nextTranslation }
        if r.nextWordGroups != nextLineWordGroups { nextLineWordGroups = r.nextWordGroups }
        if r.index != currentLineIndex { currentLineIndex = r.index }
        if r.scrollIndex != scrollLineIndex { scrollLineIndex = r.scrollIndex }
        if r.gapIndex != currentGapIndex { currentGapIndex = r.gapIndex }
        if r.rawGapWindow != rawGapWindow { rawGapWindow = r.rawGapWindow }
        updateLineFillSettled(line: r.line, atRawMs: frozen)
    }

    private func fastTick() {
        // 电台:两首歌之间还有一两分钟主持人说话(实测这个台多出 66~110 秒),那段时间
        // 元数据还停在上一首、表也还在走,不收的话上一首的歌词会在说话声里继续滚(
        // 收掉)。判定本身在 apply 里按真曲长算,见 radioTrackFinished。
        if radioTrackFinished {
            clearLineDisplay()
            return
        }
        guard let anchor else {
            resolveLinesForPausedPosition()
            return
        }
        let pos = anchor.extrapolatedPositionMs()
        refreshMusicVideoOffset(atRawMs: pos)
        // 只在真的换了行/换了下一句预览时才赋值——这两个是 @Published,SwiftUI 不管
        // 新旧值是否相等,只要赋值就会通知订阅者重新渲染。逐字填色已经交给
        // TimelineView 按渲染帧频现算(不经过这两个属性),这里 20Hz 只是为了判断当前
        // 该显示哪一行,绝大多数 tick 其实还是同一行——无条件赋值会让悬浮窗所在的
        // LyricsOverlayView(以及任何订阅 PlaybackCoordinator 的其它 View,比如"歌词
        // 管理"窗口)整个 body 跟着每秒重算 20 次,造成播放期间的卡顿。
        // 打包查询:当前行/下一句/行下标/间奏下标要的是同一个 pos 的
        // 同一次定位,原来四个入口各自独立扫一遍数组(原注释"这个量级完全可以忽略"没错,
        // 但 tickQuery 让下标只算一次、还带单调窗口记忆化,调用方也从四行收敛成一次调用)。
        // "只在真的变化时才赋值"的规则原样保留 —— 这四个是 @Published,SwiftUI 不管新旧值
        // 是否相等,只要赋值就会通知订阅者重新渲染,而绝大多数 tick 其实还是同一行。
        let r = syncEngine.tickQuery(atMs: pos, trackEndMs: currentDurationMs)
        if r.line != currentLine { currentLine = r.line }
        if r.compactLine != compactLine { compactLine = r.compactLine }
        if r.compactPlaceholder != compactShowsPlaceholder { compactShowsPlaceholder = r.compactPlaceholder }
        if r.compactDwellMs != compactDwellMs { compactDwellMs = r.compactDwellMs }
        if r.compactLeadInMs != compactLeadInMs { compactLeadInMs = r.compactLeadInMs }
        if r.nextText != nextLineText { nextLineText = r.nextText }
        if r.nextSide != nextLineSide { nextLineSide = r.nextSide }
        if r.nextRomanization != nextLineRomanization { nextLineRomanization = r.nextRomanization }
        if r.nextTranslation != nextLineTranslation { nextLineTranslation = r.nextTranslation }
        if r.nextWordGroups != nextLineWordGroups { nextLineWordGroups = r.nextWordGroups }
        if r.index != currentLineIndex { currentLineIndex = r.index }
        if r.scrollIndex != scrollLineIndex { scrollLineIndex = r.scrollIndex }
        if r.gapIndex != currentGapIndex { currentGapIndex = r.gapIndex }
        if r.rawGapWindow != rawGapWindow { rawGapWindow = r.rawGapWindow }
        updateLineFillSettled(line: r.line, atRawMs: pos)
    }

    /// 见 currentLineFillSettled 的注释。阈值(该行从哪一毫秒起定格)是纯数值,算法在
    /// KaraokeFill.lineFillSettledMs(selftest 覆盖);这里只负责跟填色视图同一个时间基准
    /// 比较 —— 视图的 currentMs = 外推位置 + offsetMs(见 LyricsOverlayView.mainLine),
    /// 词的时间戳是歌词原始时间轴,所以这里同样要加 offsetMs 再比。
    // 阈值是**行级常量**(只由词/组的时间轴决定),原来每个 tick 都对全行词+组重算一遍
    // O(词数)浮点循环——按行记忆化:引擎的行是按下标记忆化的同一
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
            // 必须用 effectiveOffsetMs(含歌词自带的 [offset:]),不能用 offsetMs:
            // settledThresholdMs 来自词时间戳(歌词原始时间轴),而"播放位置 → 歌词时间轴"
            // 的换算就是引擎那句「所有查询入口都必须用 effectiveOffsetMs」管的事 ——
            // 全链路核对 [offset:] 处理时抓到这里是唯一漏改的入口(
            // 那次只改了引擎内部五个入口,这处在引擎外面、漏了),带非零 offset 的歌
            // "行内填色已完成"的判定会偏差相应毫秒数。
            settled = rawMs + syncEngine.effectiveOffsetMs >= settledThresholdMs
        } else {
            settled = true
            settledThresholdLine = nil
        }
        if settled != currentLineFillSettled { currentLineFillSettled = settled }
    }

    // nil 快照(真的没有任何曲目在加载)和"有曲目但不是 Apple Music"共用同一套清理。
    //
    // 改:title/artist/album 以前**故意不清**,理由写的是"保留最近一次播放
    // 的信息,跟暂停分支的既有行为一致"。那个理由站不住 —— **暂停根本不走这条路径**:
    // 暂停时 media-control 仍然给出一份带曲目的快照(playing=false),走的是 apply(),
    // 曲目信息本来就留着。能走到这里的只有"真的什么都没在放"。
    //
    // 于是一张专辑放完之后,"歌词窗口"会停在一个半吊子状态:曲名歌手还在,封面变回占位
    // 音符、配色没了、歌词列表空了写着"无歌词" —— 现象是的就是这个,看着像坏了而不是像
    // 停了。曲目信息一起清掉,各界面才会一致地表达"现在没有在放"。
    //
    // 别的界面早就防过空标题:菜单栏那条 `if !coordinator.title.isEmpty` 直接不显示这一行,
    // 灵动岛 `poller.title.isEmpty ? "♪" : poller.title` 回退成音符,都不需要改。
    //
    // allLines/artworkData 这两个是补上的——之前漏清,导致播放彻底停止(不是
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
            nextLineSide = nil
            nextLineRomanization = nil
            nextLineTranslation = nil
            nextLineWordGroups = nil
            currentLineIndex = nil
            scrollLineIndex = nil
            compactLine = nil
            compactShowsPlaceholder = false
            compactDwellMs = nil
            compactLeadInMs = nil
            allLines = []
            lyricsGapMarkers = []
            currentGapIndex = nil
            rawGapWindow = nil
            if !currentLineFillSettled { currentLineFillSettled = true }
            artworkData = nil
            artworkAverageHex = nil
            if spotifyArtworkURL != nil { spotifyArtworkURL = nil }
            clearMusicVideoTimeline()
            pausedPositionMs = nil
            currentDurationMs = nil
            // 曲目本身也清掉,理由见上面那段。跟着一起清的还有"这首歌"的几个判定 ——
            // 留着的话停播之后空状态会写成「纯音乐」/「广告中」这种明显不对的文案。
            if !title.isEmpty { title = "" }
            if !artist.isEmpty { artist = "" }
            if !album.isEmpty { album = "" }
            musicVideoKey = nil
            if isMusicVideo { isMusicVideo = false }
            if hasLyricsContent { hasLyricsContent = false }
            if isCurrentTrackInstrumental { isCurrentTrackInstrumental = false }
            if currentTrackHasNoLyrics { currentTrackHasNoLyrics = false }
            if isCurrentTrackAdBreak { isCurrentTrackAdBreak = false }
            // 等值闸快照必须一起失效:上面把 allLines 等发布状态清空了,而引擎/缓存文件
            // 里的内容还是原样 —— 不失效的话,同一首歌再次播放时 reloadCurrentLyrics 会被
            // 内容等值闸吞掉,allLines 永远回不来(闸只保证"引擎状态不用重算",保证不了
            // "发布状态还在")。
            lastReloadSnapshot = nil
            // lastKey 必须一起清空,否则上面清掉的 allLines/artworkData 再也回不来。
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
            // 位置追踪的私有状态也要一起断链:不清的话,
            // "上一首还在播"这份陈旧状态会一直活着,中断(焦点被抢/退出/stopped)之后
            // 另起的一首歌若恰好落进自然切歌窗口(|overrun|≤4 且假偏置落 (0.05,2.5]),
            // 会被伪判成 gapless 自然切歌、种下最多 2.5s 的假偏置且整曲不自愈——改动前
            // 换歌分支无条件采信读数,这份陈旧状态才是无害的。与 collector 侧
            // updatePosition 的 key=="" 分支清理对齐。
            posWasPlaying = false
            posPrevWall = nil
            posPrevDurationSecs = 0
            posLateAnchorProbedElapsed = nil
            setReportedBias(0, anchorElapsed: nil)
            stopFastTimer()
        }
    }

    // poll 之间乱序完成的保护——实测排查坐实:每次 Timer 触发都新起一个
    // Task,内部子进程调用(几十~上百毫秒,但权限弹窗/系统繁忙等情况下可能明显变慢)之间
    // 没有任何互斥,较早发起的一次如果比较晚发起的一次更慢完成,会在 apply() 里用一份
    // 过期快照覆盖掉刚刚已经生效的新快照,造成标题/歌词短暂跳回上一首歌。用单调递增的
    // 世代号标记"这是第几次发起的轮询",子进程返回后只在"没有更新的轮询已经发起过"时
    // 才继续走 apply()/clearIfWasPlaying()——跟 fetchArtworkForCurrentTrack() 已经用
    // expectedKey 做的事是同一个模式,只是这里换歌与否都要防护,不能用 trackKey 当
    // 世代标识。
    //
    // poll 现在有两个调用方(2 秒轮询 Timer + playerInfo 通知补查,见
    // handlePlayerInfoChanged),这道防护对新入口天然同样成立、不需要任何改动——它保护的
    // 是"任意两次 poll() 的返回乱序",跟这两次分别是谁触发的无关。通知补查跟定时轮询
    // 挨得很近(通知先到、轮询紧随其后)时,后发起的那次赢,先发起的那次结果被丢弃,
    // 正是想要的行为。
    private var pollGeneration = 0

    /// 连续多少次 poll() 拿到了 nil 快照——给下面"snapshot failed"那行判断该不该打日志用。
    /// 实测坐实的问题:这条路径原来无条件每拍都打一遍 `.error`,而空闲档
    /// (没在放歌)轮询间隔只有 10s,一晚上挂机就是几百条一模一样的行——诊断导出一份
    /// 24 小时 App Log 里这一条能占到三成,把真正有用的信号淹没掉。改成只在**状态刚
    /// 变成这样**(从"有快照"变成"没有")时才打一次;如果这个状态持续存在(比如权限
    /// 真的被收回了),每隔一段时间(约 5 分钟,`% 30` × 10s 空闲档)再打一次,不完全
    /// 沉默——不然真出问题时诊断导出里反而一条线索都没有。
    private var consecutiveNilSnapshots = 0
    /// 这一串连续拿不到快照是从哪一刻开始的。焦点那一档的宽限按秒算,见
    /// `MediaControlClient.focusHeldGraceSeconds`。
    private var nilStreakStartedAt: Date?

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
                self.consecutiveNilSnapshots += 1
                if self.nilStreakStartedAt == nil { self.nilStreakStartedAt = Date() }
                if self.consecutiveNilSnapshots == 1 || self.consecutiveNilSnapshots % 30 == 0 {
                    // logger.error(_:) 吃的是 OSLogMessage,只认编译期字符串插值,不能用
                    // `+` 拼运行时 String——先把可变的那半拼成局部变量,再一次性插值进去。
                    let streakSuffix = self.consecutiveNilSnapshots > 1
                        ? " streak=\(self.consecutiveNilSnapshots)" : ""
                    // 说出**具体是哪一种**。原来这句把三种原因合成
                    // 一句话、还漏掉了第四种(焦点被别的 App 占走 / 私有通道坏了),用户交上来的
                    // 诊断日志里只有这一句,指不出任何方向。枚举见 MediaControlClient.SnapshotFailure。
                    let reason = MediaControlClient.lastSnapshotFailure?.rawValue ?? "unknown"
                    // notice 而不是 error:这多数时候是正常状态(Music 没开 / 没曲目在放),
                    // 落盘留线索就够,不该在 error 级别里跟真正的故障混在一起。后缀显式 .public ——
                    // 默认 private 会把它打成 <private>,24 小时日志里 36 条全是 <private> 尾巴。
                    logger.notice("snapshot failed: \(reason, privacy: .public)\(streakSuffix, privacy: .public)")
                }
                // 单拍 nil 不清状态:判据与代价见
                // MediaControlClient.nilSnapshotClearsState。
                let failure = MediaControlClient.lastSnapshotFailure
                let nilStreakSeconds = Date().timeIntervalSince(self.nilStreakStartedAt ?? Date())
                if MediaControlClient.nilSnapshotClearsState(
                    consecutiveNilCount: self.consecutiveNilSnapshots,
                    failure: failure, nilStreakSeconds: nilStreakSeconds) {
                    clearIfWasPlaying()
                } else if MediaControlClient.isFocusHeldElsewhere(failure),
                          self.consecutiveNilSnapshots == 1 {
                    // 进入这一档时打一次(不是每拍),口径同 MediaControlClient 那条 fallback notice。
                    let grace = Int(MediaControlClient.focusHeldGraceSeconds)
                    logger.notice("focus held by another app; holding playback state (grace \(grace, privacy: .public)s)")
                }
                self.adjustPollCadence()
                return
            }
            if self.consecutiveNilSnapshots > 0 {
                logger.notice("snapshot recovered after \(self.consecutiveNilSnapshots) consecutive failures")
                self.consecutiveNilSnapshots = 0
                self.nilStreakStartedAt = nil
            }
            // isMusicApp 现在直接由 MediaControlClient 硬编码为 true(只在真的问到
            // Music.app 自己的当前曲目时才会返回非 nil 快照,不再是系统级 Now Playing
            // 焦点判断)——这个 guard 仍然保留,当作一层保险。
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

    private func apply(_ rawSnapshot: MediaControlSnapshot) {
        // 电台的分母:系统报的 `duration` 是**整档节目**的(实测 3390.122s = 56 分半),
        // 而位置已经在 MediaControlClient 里换成了单曲口径(见 RadioTrackClock)。分母不跟着换,
        // 灵动岛和歌词窗口就会显示成「2:29 / 56:30」—— 这是明显的自相矛盾。
        // 真曲长由 collector 从 Apple 目录查到(实测把 3390.122 纠成 226.283)并写进歌词缓存,这里读出来替换。
        //
        // 缓存里还没有这首歌时(刚换曲、歌词还在解析)**保留快照自己那份**,绝不置 0:
        // 进度锚点按 durationMs 夹位置(ProgressClock),0 会把位置钉死在开头、整档没有歌词
        // —— 真踩过一次。代价只是换曲后头几秒分母偏大,缓存一落地自己纠正。
        //
        // 放在 apply 最前面而不是 MediaControlClient 里:EnrichCacheReader 是 @MainActor 隔离的,
        // 快照那条路是 nonisolated,够不着。
        var snapshot = rawSnapshot
        if rawSnapshot.isRadio == true,
           let cached = EnrichCacheReader.trackDurationSecs(
               artist: rawSnapshot.artist ?? "", title: rawSnapshot.title ?? "", album: rawSnapshot.album ?? ""),
           cached > 0, cached != rawSnapshot.duration {
            snapshot = rawSnapshot.withDuration(cached)
        }
        // 台卡:开台那一刻系统会先推一张 **artist 为空、title 就是台名**的载荷(实测三次:
        // `|NCT 127`、`|YEONJUN`、`|petal radio`,enrich key 的第一段是歌手)。这是**唯一**能拿到
        // 台名台标的时机 —— 口白期间系统一个字段都不变(抓了整段 61 秒的口白坐实)。
        // 判据与理由见 RadioStationCard。
        let stationHash = MediaControlClient.currentRadioStationHash()
        if stationHash != nil, !radioStationCardLoaded {
            radioStationCardLoaded = true
            radioStationCard = RadioStationCardFile.load()
        }
        let stationCardName = stationHash.flatMap {
            RadioStationCardFile.stationName(isRadio: snapshot.isRadio == true, stationHash: $0,
                                             title: snapshot.title, artist: snapshot.artist)
        }
        if let hash = stationHash, let name = stationCardName {
            noteRadioStationCard(name: name, hash: hash, trackKey: snapshot.trackKey)
        }
        // 这首歌放完了没有(电台专用,判据见 RadioTrackClock.passedTrackEnd)。位置用快照里那份
        // **没被夹过**的原始值:进度锚点的 extrapolatedPositionMs 会把位置夹在 [0, duration],
        // 从那边永远看不到"越过曲长"。时长拿不到时 passedTrackEnd 返回 false,不会误收。
        // 台卡期间同样「不是歌」。开台那几十秒系统把台名当一首歌推过来(实测 33.4 秒),
        // 不拦的话歌词那一格会一路走到「搜索歌词中…」再到「暂无歌词」。收进同一个标记 = 三个展示面
        // 一起显示「口白」+ 台名台标,不用各自再判一次。collector 那侧有同判据的对应守卫
        // (`radioStationCard`,不把台卡写进歌词缓存)。
        let finished = stationCardName != nil || RadioTrackClock.passedTrackEnd(
            position: snapshot.isRadio == true ? (snapshot.elapsedTime ?? 0) : 0,
            durationSecs: snapshot.isRadio == true ? snapshot.duration : nil)
        // 这一刻在放哪个台 —— 电台时间轴校准按「台 + 曲目」记(见 LyricsOffsetStore.radioOffsets),
        // 所以要把它留到 nudge / applyOffsets 用得着的地方。不是电台就是 nil。
        if currentStationHash != stationHash { currentStationHash = stationHash }
        let station = RadioStationCardFile.card(radioStationCard, forStation: stationHash)
        if station?.name != radioStationName { radioStationName = station?.name }
        if station?.artwork != radioStationArtwork { radioStationArtwork = station?.artwork }
        if finished != isRadioTalkBreak { isRadioTalkBreak = finished }
        if finished != radioTrackFinished {
            radioTrackFinished = finished
            // 只在翻转时打一行。这个判定要靠歌词缓存里的真曲长,缓存没命中时 duration 还是整档
            // 节目那个大数、判定恒 false —— 那种"安静地不生效"只有日志看得见。
            logger.notice("radio track finished=\(finished) card=\(stationCardName != nil) pos=\(snapshot.elapsedTime ?? -1, format: .fixed(precision: 1)) dur=\(snapshot.duration ?? -1, format: .fixed(precision: 1))")
        }
        lastSnapshot = snapshot
        // title/artist/album/isPlayingNow 只在真的变化时才赋值——理由跟 fastTick() 里
        // currentLine/nextLineText/currentLineIndex 的既有注释完全一样:这几个都是
        // @Published,Combine 不管新旧值是否相等,只要赋值就会通知订阅者。同一首歌播放期间
        // 这四个字段每 2 秒轮询其实拿到的都是同一份值,无条件赋值会让"歌词窗口"(以及任何
        // 订阅 PlaybackCoordinator 的其它 View)的整个 body 跟着每 2 秒重算一次——
        // 实测排查坐实,这是"歌词窗口"封面模糊背景每 2 秒被重新解码+重新高斯模糊的根因
        // 之一(另一个是下面的 anchor,两处需要一起改才能真正消除这个重渲染)。
        let newTitle = snapshot.title ?? ""
        if newTitle != title { title = newTitle }
        let newArtist = snapshot.artist ?? ""
        if newArtist != artist { artist = newArtist }
        let newAlbum = snapshot.album ?? ""
        if newAlbum != album { album = newAlbum }
        musicVideoKey = Self.musicVideoTrackKey(previous: musicVideoKey, currentKey: snapshot.trackKey,
                                                markedMusicVideo: snapshot.isMusicVideo == true)
        let newIsMusicVideo = musicVideoKey == snapshot.trackKey
        if newIsMusicVideo != isMusicVideo { isMusicVideo = newIsMusicVideo }
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
        // 广告判定必须在下面 np:lastTrack* 落盘**之前**算出来:那几个键是"上次在听什么"
        // (停播页的唱片 hero、待机页、歌词窗口都读它),一段广告不该被记成上次在听的歌。
        // 之前不需要管这件事 —— YT Music 的广告在 MediaControlClient 那道闸
        // 就被整条丢掉了,根本走不到这里;现在它会走到(为了让 UI 能显示「广告中」,见
        // YouTubeMusicAdProbe.Gate.acceptAsAd),所以这道保护要在这里补上。
        // 判定语义见下面 isCurrentTrackAdBreak 那一段。
        let isSpotifyNative = snapshot.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier
        let resolvedBundleID = BrowserPositionProbe.probeTargetBundleID(forReported: snapshot.bundleIdentifier)
        let isSpotifyWeb = BrowserPositionProbe.shared.isPaired(bundleID: resolvedBundleID, platformID: "spotifyWeb")
        // YouTube Music 网页版的广告:它的字段形状跟"真歌但没报专辑名"分不开
        // (广告的 artist 是**广告主频道名**、非空,album 空),所以下面那套 adByFields 启发式
        // 对它无效 —— 判据只能来自页面本身。这里读的正是 MediaControlClient 刚用过的同一份
        // 探针缓存(同一个 key、同一把锁),两边不会得出不同结论。
        let youTubeMusicAdKey = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        // 用 showsAdBadge 而不是 `!= .song`:判定**缺失**时绝不能点亮「广告中」,
        // 否则探针一超时就会在真歌上贴广告标签。方向与 gate 相反,理由见它的头注。
        // 读的是 **badge 口径**(`cachedBadgeVerdict`，02 章决策 #26):只靠裸标题撑起来的
        // 广告判定在这里算「拿不准」(nil)。换歌那两三秒页面标题就是裸的「YouTube Music」,而 YT Music
        // 首次发布元数据常常不带 album、会被 MediaControlClient 那道闸踢一次探针 —— 恰好探到,弱 ad 就
        // 缓存到了下一首歌的 key 下,下一拍换曲按当下判定定初值,整首真歌被贴「广告中」(举例:
        // Safari 播 Prince《It's Gonna Be Lonely》1:15 处仍「广告中」、歌词却正常)。gate 那边仍按任一命中即广告。
        let youTubeMusicVerdict = YouTubeMusicAdProbe.shared.cachedBadgeVerdict(forKey: youTubeMusicAdKey)
        // Spotify **网页版**只认页面的正向证据(`SpotifyWebAdProbe` 判成广告),**不再**套原生那套
        // "album 空 / artist 空 / 标题「—」"字段启发式:`isSpotifyWeb` 只说明"这个浏览器**配对过** Spotify 网页版",不说明此刻在放的是
        // Spotify —— 这台机器上 Safari / Arc 同时配对了 spotifyWeb 和 youtubeMusic,于是 YT Music 里
        // 一首 album 为空的 MV(王子《Why You Wanna Treat Me So Bad?》,MV 常常不报专辑名)被那条
        // "album 空即广告"整首标成「广告中」,而 YT Music 探针明明判它是歌;同专辑带专辑名的
        // 《Sexy Dancer》就正常 —— 差别只在 album 空不空。网页版广告的形状(artist 空)本来就只有在
        // `SpotifyWebAdProbe` 判成广告时才过得了 MediaControlClient 那道闸(见 spotifyWebAdAccepted),
        // 这里读同一份缓存,两边口径一致;原生 Spotify 的启发式 + AppleScript 复核原样不动。
        let spotifyWebVerdict: SpotifyWebAdProbe.Verdict? = isSpotifyWeb
            ? SpotifyWebAdProbe.shared.cachedVerdict(
                forKey: SpotifyWebAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title))
            : nil
        let adByFields = Self.adBreakByFields(
            isSpotifyNative: isSpotifyNative, title: newTitle, artist: newArtist, album: newAlbum,
            youTubeMusicVerdict: youTubeMusicVerdict, spotifyWebVerdict: spotifyWebVerdict)
        if !newTitle.isEmpty, !adByFields, newTitle != lastPersistedTrackTitle {
            UserDefaults.standard.set(newTitle, forKey: "np:lastTrackTitle")
            UserDefaults.standard.set(newArtist, forKey: "np:lastTrackArtist")
            // 专辑才补上(停播页的唱片 hero 要显示「歌手 · 专辑」)。它跟着
            // 曲名一起写、不单独判变化:同一首歌的专辑不会中途变,而换歌必然触发这个分支。
            // 旧安装第一次打开新版停播页时这个键还不存在 —— 消费方按「空就只显示歌手」处理。
            UserDefaults.standard.set(newAlbum, forKey: "np:lastTrackAlbum")
            lastPersistedTrackTitle = newTitle
        }
        // Spotify 广告插播判断(字段启发式 + 同曲棘轮 + AppleScript 权威)。
        // 不能每一拍都按"当下字段"重判 —— 广告字段会**闪变**(开播 album 空、几拍后
        // 补齐,Blinds.com 坐实),看走眼的那几拍 UI 会退回"歌名 + 搜索歌词中"。
        // 换曲那一拍按加宽的启发式(album 空/artist 空/标题「—」,与 collector isAdBreak
        // 同款)定初值,同曲期间只往 true 棘轮、不回落;是 Spotify 就再异步问一次本尊
        // (`spotify url` 前缀是权威分类,广告可以带全 artist/title/album 骗过启发式),
        // 结果回来仍是这首才采纳。judge 与 collector 两侧口径一致,那边管上报,这边管 UI。
        //
        // **网页版 Spotify 也要认**(对拍坐实:Last.fm 那张卡的
        // "正在记录"行原样显示了一条"广告"——`!playback.isAdBreak` 那道闸没拦住,因为下面
        // `isSpotify` 原来只认原生客户端的 bundleIdentifier,浏览器代理进程报的是
        // `com.apple.WebKit.GPU`/浏览器自己的 bundle id,永远对不上)。现场抓的真实广告
        // 样本:`album=""  artist=""  title="广告"  duration≈30s`——跟原生客户端广告同一套
        // 字段信号,不需要另外发明判据,只需要把"这是不是 Spotify"的判断扩到网页版。
        // `BrowserPositionProbe.shared.platformBrowserPairs` 是用户在「网页播放器」设置页
        // 显式配对过的浏览器与平台关系(跟 kickIfNeeded 用的是同一份数据、同一把锁),
        // 配对了 "spotifyWeb" 的浏览器标签页播放就按 Spotify 处理。
        //
        // **YouTube Music 网页版也要认**("chrome 上播 YT Music 的
        // 广告也像 Spotify 那样显示出来是广告")。它跟 Spotify 走的不是同一条判据:Spotify
        // 广告靠字段形状就能认(album/artist 空、标题「—」),而 YT Music 广告的 artist 是
        // 广告主频道名、**非空**,跟"真歌但没报专辑名"在字段上完全分不开 —— 只能问页面。
        // 那次查询由 `YouTubeMusicAdProbe` 异步做、结果进缓存,上面 `isYouTubeMusicAd`
        // 读的就是它。在此之前这类广告在 MediaControlClient 那道闸就被整条丢掉了,后果是
        // 30 秒广告期间灵动岛/悬浮窗整个塌成"没有在播放"、广告完了再弹回来。
        //
        // 上面这段"网页版也要认"的落地方式改了:**不再**把 `isSpotify` 扩成"配对过
        // 网页版就按 Spotify 启发式判",而是网页版只认 `SpotifyWebAdProbe` 的正向证据 —— 配对关系
        // 不等于此刻在放 Spotify(Safari / Arc 两个平台都配了),按配对套启发式会把 YT Music 里
        // 没有专辑名的 MV 整首判成广告。判据收在 `adBreakByFields`(纯函数,selftest 钉着)。
        //
        // isSpotifyNative/isSpotifyWeb/youTubeMusicVerdict/adByFields 几个局部量在上面
        // np: 落盘那段之前就算好了(广告不该被记成"上次在听"),这里直接用。
        // 同曲棘轮有一个**例外**:YouTube Music 的**音乐视频**前贴片广告不是
        // 独立的 now-playing 条目,它在 `#movie_player` 里放、MediaSession 元数据却一直是这首歌
        // 自己的 —— 于是页面判定会在**同一个 key** 下先 ad 后 song。只往 true 棘轮的话,前贴片
        // 一过、整首 MV 都挂着「广告中」(现象是的就是这个,Safari 播王子《Why You Wanna Treat
        // Me So Bad?》当场坐实,collector 日志里三轮 rejected 之后才 now playing)。所以页面**明确**
        // 说是歌(`.song`,不是 nil)时允许回落;Spotify 那套字段启发式 + AppleScript 复核不受
        // 影响(它们的 verdict 恒为 nil)。状态机收在 nextAdBreakState 里,selftest 钉着。
        // pageVerdict 只在**原生 Spotify** 上置 nil(它有自己的 AppleScript 复核语义);浏览器播放一律
        // 传 YT Music 探针的判定 —— 不能按 isSpotifyWeb 置 nil,那会让"配对了 Spotify 网页版的浏览器"
        // 里的 YT Music MV 在前贴片放完后回落不了(修正,同上一段)。
        let nextAd = Self.nextAdBreakState(
            previous: isCurrentTrackAdBreak, isNewTrack: snapshot.trackKey != lastKey,
            adByFields: adByFields, pageVerdict: isSpotifyNative ? nil : youTubeMusicVerdict)
        if isCurrentTrackAdBreak != nextAd { isCurrentTrackAdBreak = nextAd }
        // 广告计数跟着广告态一起收:不在广告里就必须是 nil,否则下一首歌会挂着
        // 上一次插播的「1/2」。读的是**同一份缓存**(`cachedReading`),不额外踢探针 —— 它跟
        // 上面那条 `cachedBadgeVerdict` 是同一次读数的两个字段,不会出现"判定说广告、计数
        // 却来自另一拍"的错位。徽章从 1/2 翻到 2/2 最多滞后一个探测周期(广告期间 5 秒一探),
        // 评审时确认可接受 —— 为一个装饰性计数把 AppleEvent 往返频率翻倍不值。
        let nextAdSlot = nextAd
            ? YouTubeMusicAdProbe.shared.cachedReading(forKey: youTubeMusicAdKey)?.adSlot
            : nil
        if currentAdSlot != nextAdSlot { currentAdSlot = nextAdSlot }
        // 只要「广告中」还亮着、而且是浏览器播放,就**每拍**再踢一次 YT Music 探针(决策 #26)。
        // 原来探针只在 MediaControlClient 那道闸"album 为空"时才被踢:YT Music 首次发布元数据常常不带
        // album、几百毫秒后重发才带上 —— 重发之后基础守卫直接放行,**再没有任何地方去问页面**,状态机等的
        // 那个 `.song` 永远不会来;60 秒可读期一过判定变 nil、按「保持」走,整首歌挂着「广告中」直到换歌
        // (决策 25 修的"广告 5 秒再探"在这条路上根本没人触发)。kickIfNeeded 内部按判定分档(广告 5 秒
        // 一探、歌 60 秒不动),真广告期间也就是每 5 秒一次往返。不踢的情况:原生 Spotify(它有自己的
        // AppleScript 复核语义,pageVerdict 恒 nil);`spotifyWebVerdict == .ad`(那是 Spotify 网页广告,
        // 去问 YT Music 标签页只会 NOTFOUND 白烧一次往返);非浏览器 bundle 在 kickIfNeeded 里自然 no-op。
        if nextAd, !isSpotifyNative, spotifyWebVerdict != .ad {
            YouTubeMusicAdProbe.shared.kickIfNeeded(
                bundleIdentifier: snapshot.bundleIdentifier, key: youTubeMusicAdKey)
        }
        // 暂停着的浏览器播放:进度探测不跑,面板角标「是哪个网页平台」的证据另外补(见 identifyIfNeeded)。
        if snapshot.playing != true {
            BrowserPositionProbe.shared.identifyIfNeeded(
                bundleIdentifier: snapshot.bundleIdentifier, key: snapshot.identityKey, title: newTitle)
        }
        // 权威复核只对原生客户端有意义(`spotify url` 与通知里的 Track ID 都是原生 App 才有,网页版没有这
        // 两个接口)——网页版只吃字段启发式本身的结果。先问 Spotify 自己刚广播的通知、对不上
        // 才退回 osascript,见 spotifyNativeAdCheckForNewTrack。
        if snapshot.identityKey != lastKey, isSpotifyNative, !adByFields {
            spotifyNativeAdCheckForNewTrack(snapshot: snapshot)
        }

        // identityKey 而不是 trackKey:署名不可信的播放器要把署名剔出身份,否则换歌头几秒
        // 身份会抖好几次(见 MediaControlSnapshot.identityKey)。封面核对那边用的是同一把尺子。
        let key = snapshot.identityKey
        let trackChanged = key != lastKey
        // 必须在这里留一份旧 key:下面 `lastKey = key` 之后,`lastKey` 就等于 `key` 了,
        // 到浏览器探针那一段(`if trackChanged`)再读它只会读到新值。留它是为了让探针的
        // "重新开放额度"日志能分辨这次到底是**真换歌**(旧 key 非空、跟新的不一样)还是
        // **中断后重新接上**(旧 key 为空 —— 快照变 nil 那条路径把 lastKey 清成了 "",
        // 见上面 `lastKey = ""` 一带)。加:真机上实测到同一首歌连续播放期间
        // 探针额度被重开了 4 次(同一个 pid,排除了重启),但当时的日志分辨不出是哪一种。
        let previousKey = lastKey
        // 同一首歌播到中途,collector 还可能给它补出译文、或者换上一份更好的歌词(见
        // collector 的 backfillTranslation / retryLyricsUpgrade / rescoreLyrics)。原来这里
        // 只在换歌或"完全没歌词"时才重读,于是这类中途补上的东西要等下一次换歌才看得到 ——
        // 表现是"为什么当前这歌没有英文译文",而译文其实早在 19 秒前就翻好并落盘了。
        //
        // 不要加"已经有译文了就不用再盯"这类省事的闸门。试过一版,当场被
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
        // 会提前吃掉这次变化,后台解码完成后就再没有东西触发 reload 了。
        EnrichCacheReader.refreshIfNeeded()
        let enrichMTime = EnrichCacheReader.decodedContentVersion
        // 先无条件推进对外那个信号 —— 它的消费方(高清封面重查)关心的是"缓存内容变了",
        // 跟下面那个 reload 是否触发无关(reload 还看 trackChanged/hasContent)。
        if enrichContentVersion != enrichMTime { enrichContentVersion = enrichMTime }
        // 缓存被内存压力让出、正在后台重建时,同一首歌不因为"版本变了"去重灌:那一拍 lookup 拿不到东西,
        // 重灌只会把引擎里好好的歌词换成空的;重建完 onContentAdopted 捅的那一拍再来。换歌照常走。
        let enrichRebuilding = EnrichCacheReader.isRebuilding
        if trackChanged || ((!syncEngine.hasContent || enrichMTime != lastEnrichMTime) && !enrichRebuilding) {
            if trackChanged {
                logger.notice("track changed: \(snapshot.artist ?? "", privacy: .public) - \(snapshot.title ?? "", privacy: .public)")
                // 上一首的图床地址跟着换歌走;新地址要等探针 2.5s 后带回来(见 spotifyArtworkURL)。
                if spotifyArtworkURL != nil { spotifyArtworkURL = nil }
                clearMusicVideoTimeline()
            }
            lastKey = key
            lastEnrichMTime = enrichMTime
            reloadCurrentLyrics()
            if !trackChanged { recheckMusicVideoTimelineIfLyricsChanged(forKey: snapshot.trackKey) }
        }
        // 换了播放器也要重算偏移 —— 上面那个 reload 的触发条件是「换歌 / 没内容 / 缓存变了」,
        // **不含**"播放器变了"。而 trackKey 只由 歌手|歌名 决定:.auto 档下焦点在两个 App 之间
        // 切、或两个播放器放同名曲目时,曲目没"变"、内容也在,于是 applyOffsets 不跑,新播放器
        // 会继续套用**上一个播放器**那一档 —— 正是"把浏览器的补偿套到 Apple Music 上"这个
        // effectiveOffset 注释里明写要防的形态(加播放器维度时发现)。
        //
        // 放在 reload 判断之后:换歌那一支已经经 reloadCurrentLyrics → applyOffsets 算过一遍,
        // 这里只补"没换歌但换了播放器"这一种情况,不重复跑。
        let bundleID = snapshot.bundleIdentifier
        if bundleID != lastAppliedBundleID {
            lastAppliedBundleID = bundleID
            if !trackChanged, syncEngine.hasContent { applyOffsets() }
        }

        if trackChanged {
            // 换歌时**不再**立即清空上一首歌的封面。
            //
            // 立即清空造成的后果比"背景多显示上一首模糊图"严重得多——"歌词窗口"的背景、
            // 文字颜色、封面占位
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
        applyPosition(snapshot: snapshot, key: key, trackChanged: trackChanged, previousKey: previousKey,
                      isSpotifyNative: isSpotifyNative, isAdBreak: isCurrentTrackAdBreak, now: Date())
        if anchor == nil {
            // 暂停(anchor == nil 但曲目还在、位置已冻结)时**不能**把当前歌词行清掉。
            //
            // 不能无条件三连清空:一按暂停就让悬浮歌词/灵动岛/菜单栏那一行歌词
            // 直接消失、歌词窗口的高亮也没了,会破坏用户按暂停的典型场景——"这句是什么?
            // 我看一下"。停掉 20Hz 定时器是对的(暂停期间位置不
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

    /// 位置状态机:这一拍的快照 → 锚点 / 暂停位置 / 偏置,以及各项学习。`apply` 每拍调一次;
    /// 回放测试经 `replayPosition` 直接调它(外部依赖全走 `env`,见 PlaybackPositionEnvironment)。
    /// - isAdBreak: 这一首此刻是不是广告(`isCurrentTrackAdBreak`),下一次换歌时当"上一首是不是广告"用。
    private func applyPosition(snapshot: MediaControlSnapshot, key: String, trackChanged: Bool, previousKey: String,
                               isSpotifyNative: Bool, isAdBreak: Bool, now: Date) {
        let playing = snapshot.playing == true
        // 网页探针的每首额度换歌就重开,不管这一拍在不在播、有没有时长。别挪进下面 `if playing, let duration` 那支:
        // 页面内换歌的头一拍常常还没有时长,跳过这一步,探针就还记着上一次探过的 key,A → B → A 切回来时一次都不探。
        if trackChanged { env.browserProbeTrackChanged(previousKey, key) }
        // 暂停/恢复那一拍的诊断:用户看到"一按暂停歌词进度变一下",要量的就是
        // "暂停前一刻屏上外推到哪"与"冻结值"之差、以及"冻结值"与"恢复后第一笔"之差。两个
        // 变量只在状态翻转的那一拍非 nil,日志也只在那一拍打一行。
        var pauseShownMs: Int?
        var pauseAnchorWasFrozenByEvent = false
        /// 这一拍暂停作废的偏置是哪一档起播领先量、值多少(见 pauseResidualLead)。
        var pauseLearnStart: (kind: SpotifyStartKind, bias: Double)?
        // 锚点偏置(自然切歌量的、Spotify 探针量的、网页探针精确读数量的)只属于量它时对着的那个锚点:播放器重新发布了
        // 锚点(暂停冻结 / 恢复 / 拖动,原始 elapsedTime 变了)就作废;读的是 Spotify 自己的钟时暂停即作废。
        // 见 biasSurvivesAnchor。放在播放/暂停两个分支之前 —— 暂停分支的 pausedPositionMs 和播放分支的
        // resolvePositionSeconds 都要看到清零后的值。
        if isSpotifyNative || posBiasFromBrowserProbe, key == posTrackingKey, posReportedBiasSecs != 0,
           !Self.biasSurvivesAnchor(anchorElapsedTime: snapshot.anchorElapsedTime, measuredAgainst: posBiasAnchorElapsed, playing: playing) {
            logger.notice("anchor bias dropped: elapsed=\(snapshot.anchorElapsedTime ?? -1, format: .fixed(precision: 3)) (-1 = player clock) measuredAgainst=\(self.posBiasAnchorElapsed ?? -1, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3)) playing=\(playing)")
            // 暂停发布的冻结值是耳朵里的位置,跟我们(探针纠过的)停在的位置一比就是探针钟的领先量。
            // 已经在暂停态(冻结锚点晚一拍才到)取 pausedPositionMs;同一拍翻转的取被事件冻住的锚点外推值。
            //
            // 只有"偏置是对着开播锚点量的"这一档有资格当领先量样本 —— 曲中重打的锚点上探针
            // 本来就是真值,那一档的残差量的是我们多扣的那一份,喂进去会把两种场合搅成一个数
            // (见 probeLeadApplies)。
            if !playing, posBiasFromProbe, Self.probeLeadApplies(anchorElapsedTime: posBiasAnchorElapsed),
               let frozen = snapshot.anchorElapsedTime {
                let oursMs = anchor == nil ? pausedPositionMs : anchor?.extrapolatedPositionMs(now: now)
                if let oursMs {
                    learnProbeLead(residual: Double(oursMs) / 1000 - frozen)
                }
            }
            // Spotify 自己的钟按起播方式给的偏置:暂停那一拍拿冻结值反推这一段真实的领先量,学进那一档
            // (下面 pause transition 那一行算,那时屏上位置和冻结值都齐了)。
            if !playing, snapshot.anchorElapsedTime == nil, let kind = posBiasStartKind {
                pauseLearnStart = (kind, posReportedBiasSecs)
            }
            setReportedBias(0, anchorElapsed: nil)
            // 播放中换了锚点就再问一次 Spotify 的钟(见 SpotifyPositionProbe.requestConfirmation):
            // 新锚点准就什么都不改;它要是又晚了 2s(或干脆是假的),探针把新偏置量出来。暂停
            // 发的冻结锚点不问 —— 那个就是 Spotify 自己的钟,而且探针只在播放中消费。
            if playing, isSpotifyNative {
                env.spotifyProbeRequestConfirmation(key)
            }
        }
        // 非 Spotify 的纯外推源(汽水音乐这类)重发锚点的那一拍:播放器自己报的位置就是真值,
        // 跟我们的外推一比就是这个播放器的锚点滞后量。见 learnedAnchorLag 一带的注释。
        //
        // 只在**变化的那一拍**量:重发之后锚点会一直保持新值,每拍都量的话第二拍起残差恒为
        // 0,刚学到的滞后量立刻被稀释回去。
        // 量完要把预置的偏置清掉:偏置是对着开播那个晚打的锚点估的,播放器重发的这个锚点
        // 本身是准的(与 biasSurvivesAnchor 同一条理由)。
        // 电台必须排除:电台那份快照的 `anchorElapsedTime` 装的是**整档节目的位置**
        // (`radioPosition ?? raw.elapsedTime`),每拍都在变,"锚点重发"这条判据对它每拍都成立。
        if !isSpotifyNative, key == posTrackingKey, posAnchorLagSampleValid, snapshot.isRadio != true,
           Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier) == .cleanExtrapolated,
           let republished = snapshot.anchorElapsedTime, republished > 0,
           let previousAnchor = posPrevAnchorElapsed, abs(republished - previousAnchor) > 0.001 {
            // 播放翻暂停的**那一拍**要用被冻住的锚点外推值,不能用 pausedPositionMs —— 后者
            // 这一拍才算出来,此刻还是上一拍播放态留下的 nil,于是一次都学不成(酷狗只在暂停时
            // 报真值,整个漏光)。锚点要到下面的暂停分支才被清掉,这里还在。
            let oursMs = anchor == nil ? pausedPositionMs : anchor?.extrapolatedPositionMs(now: now)
            if let oursMs {
                learnAnchorLag(bundleID: snapshot.bundleIdentifier,
                               residual: republished - Double(oursMs) / 1000)
            }
            if posReportedBiasSecs != 0 { setReportedBias(0, anchorElapsed: nil) }
            // 重发之后这一首的位置已经换了基准,后面再量的都不是开播锚点的滞后。
            posAnchorLagSampleValid = false
        }
        posPrevAnchorElapsed = snapshot.anchorElapsedTime
        let isFirstObservationSinceLaunch = !posBiasRestoreChecked
        posBiasRestoreChecked = true
        if playing, let duration = snapshot.duration, duration > 0 {
            // 切歌/加载瞬间 Spotify 会短暂报 rate=0(playing 仍 true),按 1 计——与
            // collector 的 reconcile 规则一致。不归一的话 predicted 停走,下一拍正常
            // 前进的读数会被误判成 seek 跳变,顺手把自然切歌偏置也清了(
            // 对抗审查抓出)。真暂停走的是下面的 else 分支,不经过这里。
            var rate = snapshot.playbackRate ?? 1
            if rate <= 0 { rate = 1 }
            // 数据源三档画像(见 PositionSourceTier):Apple Music / Spotify=AppleScript
            // 播放头(precise);酷狗 / 汽水音乐=干净的 media-control 外推
            // (cleanExtrapolated);QQ 音乐 / 网易云=整秒下取整带抖动(noisyFloored)。
            // 各档伺服参数见 servoDecision。
            let tier = Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier)
            // 浏览器地面真值探针(见 BrowserPositionProbe 头注,
            // 改成一次性纠偏后再补一版):对受支持的浏览器+网站,换歌后探测一次网页 DOM
            // 拿真实播放位置,当"精确种子值"喂给 resolvePositionSeconds(tier 按
            // noisyFloored——它就是整秒地板量化读数),走正常的 seek-跳变/棘轮/EMA 判定,
            // 而不是绕开整套伺服逻辑直接采信。命中一次大跳变就会重锚,解决"换歌后进度
            // 偏慢"的原始问题;这首歌只消费一次(见 consumeCorrection),稳态精度交还给
            // 本来就更准的 .cleanExtrapolated 连续外推,不会被整秒精度的探针值持续覆盖
            // 导致周期性回退。
            if trackChanged {
                // Spotify 原生客户端:开播 2.5s 后问一次。它带回两样东西 —— `artwork url`
                // (图床 640 档地址,任何档位都要,见 spotifyArtworkURL)和 player position
                // (只有 cleanExtrapolated 档消费,见下面那处闸门)。
                env.spotifyProbeTrackChanged(key, isSpotifyNative)
            }
            // `expectedDuration` 不是可选的锦上添花:探针拿它在 JS 里认"这个标签页放的
            // 是不是同一首歌"(见 `BrowserPositionProbe.pageDurationToleranceSecs`),
            // YouTube Music 插播广告、同一浏览器里开着第二个 Spotify 标签页都靠它认出来。
            // 这里的 `duration` 已经被外层 `if playing, let duration, duration > 0` 保证 >0。
            env.browserProbeKick(snapshot.bundleIdentifier, key, duration)
            let rawReportedForResolve: Double
            let effectiveTier: PositionSourceTier
            var usedBrowserProbe = false
            // **这里不要再加"拿 MediaRemote 位置当参照物"的守卫。** 加过一道
            // (`isPlausibleCorrection(probed:reference:)`,reference 传 `snapshot.elapsedTime`),
            // 当天就被真机抓出来删掉了:这个探针存在的前提就是网页播放器的 `elapsedTime`
            // **恒为 0**,拿它当参照物,守卫直接退化成"只有页面放在前 8 秒内的修正才采纳",
            // 而消费又是每首歌一次性的 —— 整首歌都跑在错锚点上。完整原委和"为什么换成外推值
            // 同样不行"见 `BrowserPositionProbe.pageClockIsRunning` 一带的头注。
            // 可信度判据已经全部下沉进探针内部(同一首歌 + 页面的钟在走),那里才有能证明这
            // 两件事的材料;这一层只负责把探针值当"精确种子"喂进伺服逻辑。
            var browserProbePrecise = false
            // 整秒读数在 Safari 上一律不用(见 floorReadingApplies);额度照样消费,免得同一首反复探。
            var browserCorrection = env.browserProbeConsume(key, rate, now)
            if let c = browserCorrection, !c.isPrecise,
               !BrowserPositionProbe.floorReadingApplies(reportedBundleID: snapshot.bundleIdentifier) {
                logger.notice("browser probe floor reading ignored: \(c.seconds, format: .fixed(precision: 3))s vs stream \((snapshot.elapsedTime ?? -1), format: .fixed(precision: 3))s (bundle \(snapshot.bundleIdentifier ?? "-", privacy: .public))")
                browserCorrection = nil
            }
            if let probed = browserCorrection {
                rawReportedForResolve = probed.seconds
                // 精确读数(页面 `currentTime`)跟流读数同一个钟:按源本来的档位走,cleanExtrapolated 时差值
                // 折进偏置、锚点一重发就作废(见 biasSurvivesAnchor)。整秒读数仍按 noisyFloored。
                effectiveTier = probed.isPrecise ? tier : .noisyFloored
                browserProbePrecise = probed.isPrecise
                usedBrowserProbe = true
            } else if tier == .cleanExtrapolated, posWasPlaying, key == posTrackingKey,
                      let probed = env.spotifyProbeConsume(key, rate, now) {
                // Spotify 的一次性真值(见 SpotifyPositionProbe):同样走 isGroundTruthSeed 通道,
                // 档位不变(cleanExtrapolated)。只在稳定播放中消费 —— 刚换歌那一拍要留给自然切歌
                // 校正播种,刚恢复播放那一拍恢复锚点本身就是准的。
                //
                // 档位闸不能去掉:这个探针纠的是 media-control 锚点与 `player position` 的差。
                // 快照本身已经是 `player position`(precise 档)时,两边同一个钟,再纠一遍只会把
                // 领先量凭空扣进位置里。探针在那一档仍然会跑,但只为顺路带回 `artwork url`。
                //
                // 领先量只在开播锚点还在位时才扣:播放器在曲中重发过锚点的话,它的钟已经与真声
                // 对齐,探针本身就是真值,再扣一次就是凭空造一个偏置(见 probeLeadApplies)。
                let lead = Self.probeLeadApplies(anchorElapsedTime: snapshot.anchorElapsedTime)
                    ? probeLeadSecs : 0
                rawReportedForResolve = probed - lead
                effectiveTier = tier
                usedBrowserProbe = true // 名字沿用:含义是"这一笔是地面真值种子",见 resolvePositionSeconds
            } else {
                // 读数在后台读到之后,主线程可能卡半秒多才轮到这里:按读到的时刻补到 now,别让卡顿伪装成
                // 位置误差(见 MediaControlSnapshot.capturedAt)。上限 2s,再长就当读数本身不可信,不补。
                let captureLag = snapshot.capturedAt.map { now.timeIntervalSince($0) } ?? 0
                let lagFix = captureLag > 0 && captureLag <= 2 ? captureLag * rate : 0
                rawReportedForResolve = (snapshot.elapsedTime ?? 0) + lagFix
                effectiveTier = tier
            }
            // Spotify 这一拍读的是哪个钟:AppleScript 那份没有锚点信息(anchorElapsedTime == nil)。
            // 换歌 / 首次观察 / 恢复播放那一拍按这一拍定,之后同曲换钟走 spotifyClockAction。
            let readsPlayerClock = snapshot.anchorElapsedTime == nil
            if !isSpotifyNative || key != posTrackingKey || !posWasPlaying {
                posSpotifyAcceptedPlayerClock = isSpotifyNative ? readsPlayerClock : nil
                posSpotifyForeignClockSince = nil
            }
            // App 重启后的第一拍(见 restorablePlayerClockBias)。只在这一拍读一次文件。
            var restoredBias: Double?
            if isFirstObservationSinceLaunch, isSpotifyNative, readsPlayerClock, !usedBrowserProbe,
               key != posTrackingKey, let record = env.readPositionBias() {
                restoredBias = Self.restorablePlayerClockBias(
                    record: record, bundleID: snapshot.bundleIdentifier,
                    artist: snapshot.artist ?? "", title: snapshot.title ?? "",
                    raw: rawReportedForResolve, now: now)
                // 接回来的就是文件里这一份:记成"已发布",别用新的写入时刻重写它 —— 同一首里再重启一次,
                // 连续性签名还要对着偏置量出来那一刻。
                if restoredBias != nil { lastPublishedBias = record }
            }
            var clockAction = SpotifyClockAction.accept
            if isSpotifyNative, !usedBrowserProbe {
                clockAction = Self.spotifyClockAction(
                    acceptedPlayerClock: posSpotifyAcceptedPlayerClock, readsPlayerClock: readsPlayerClock,
                    foreignSince: posSpotifyForeignClockSince, now: now)
                switch clockAction {
                case .accept:
                    posSpotifyForeignClockSince = nil
                case .hold:
                    if posSpotifyForeignClockSince == nil { posSpotifyForeignClockSince = now }
                case .switchClock:
                    posSpotifyAcceptedPlayerClock = readsPlayerClock
                    posSpotifyForeignClockSince = nil
                }
            }
            let (positionSeconds, didReanchor) = resolvePositionSeconds(
                reported: rawReportedForResolve, rate: rate, key: key, now: now,
                tier: effectiveTier,
                gaplessLeadBundleID: Self.carriesGaplessLead(tier: effectiveTier, bundleID: snapshot.bundleIdentifier)
                    ? snapshot.bundleIdentifier : nil,
                clockAction: clockAction,
                restoredBias: restoredBias,
                isGroundTruthSeed: usedBrowserProbe,
                groundTruthFromBrowser: browserProbePrecise,
                anchorElapsedTime: snapshot.anchorElapsedTime, streamRaw: snapshot.elapsedTime,
                anchorLagSeed: usedBrowserProbe ? 0 : anchorLag(forBundleID: snapshot.bundleIdentifier))
            if !posWasPlaying, key == posTrackingKey, let prevPaused = pausedPositionMs {
                // 暂停→恢复翻转的那一拍(同曲)。delta = 恢复后第一笔 − 暂停冻结值。
                env.browserProbeReopenAfterResume(key)
                logger.notice("resume transition: paused=\(Double(prevPaused) / 1000, format: .fixed(precision: 3)) resumed=\(positionSeconds, format: .fixed(precision: 3)) raw=\(rawReportedForResolve, format: .fixed(precision: 3)) delta=\(positionSeconds - Double(prevPaused) / 1000, format: .fixed(precision: 3)) rate=\(snapshot.playbackRate ?? -1, format: .fixed(precision: 2)) signalAge=\(self.posStateSignalAt.map { now.timeIntervalSince($0) } ?? -1, format: .fixed(precision: 3)) wouldSeed=\(Double(prevPaused) / 1000 + (self.posStateSignalAt.map { now.timeIntervalSince($0) } ?? 0), format: .fixed(precision: 3))")
            }
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
            if let anchor {
                // 屏上此刻显示的位置:通知已把锚点冻住(rate=0)就是冻住那一刻的值,否则是
                // 还在往前跑的外推值 —— 两种形态的"暂停跳变"成因不同,一起记下来。
                pauseShownMs = anchor.extrapolatedPositionMs(now: now)
                pauseAnchorWasFrozenByEvent = anchor.rate == 0
                self.anchor = nil
            }
            // 暂停态里换了曲目(暂停中点了另一首):没有走 resolvePositionSeconds,自然
            // 切歌偏置的归零要在这里补上——新曲的冻结位置是新锚点的值,跟旧偏置无关。
            if key != posTrackingKey, posReportedBiasSecs != 0 { setReportedBias(0, anchorElapsed: nil) }
            // 暂停中用户在播放器里拖了进度条:冻结值跳变 = Spotify 已重打对齐真声的
            // 锚点,旧偏置作废(见 posPausedRawSecs 注释)。我们自己 UI 里的暂停拖动走
            // seek(toMs:),那边已经清过,这里再看到的跳变清一次也只是幂等。
            let frozenRaw = snapshot.elapsedTime ?? 0
            if let prev = posPausedRawSecs, abs(frozenRaw - prev) > Self.seekJumpToleranceSecs,
               posReportedBiasSecs != 0 {
                setReportedBias(0, anchorElapsed: nil)
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
        // 函数一进门就有 shouldRejectStalePositionAfterSeek 这层保护;这里若直接采信
        // snapshot.elapsedTime,会导致:暂停时拖进度条,seek(toMs:) 刚把 pausedPositionMs
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
        if let shown = pauseShownMs, let paused = newPausedPositionMs {
            // 播放→暂停翻转的那一拍。delta<0 = 显示往回退,>0 = 往前补。
            logger.notice("pause transition: shown=\(Double(shown) / 1000, format: .fixed(precision: 3)) frozenRaw=\(snapshot.elapsedTime ?? -1, format: .fixed(precision: 3)) bias=\(self.posReportedBiasSecs, format: .fixed(precision: 3)) paused=\(Double(paused) / 1000, format: .fixed(precision: 3)) delta=\(Double(paused - shown) / 1000, format: .fixed(precision: 3)) frozenByEvent=\(pauseAnchorWasFrozenByEvent) errEMA=\(self.posErrEMA, format: .fixed(precision: 3))")
            // 屏上位置得是被暂停事件当场冻住的那一刻(frozenByEvent),淡出量那个常数才对得上。
            if pauseAnchorWasFrozenByEvent, let learn = pauseLearnStart,
               let sample = Self.pauseResidualLead(bias: learn.bias, pauseDelta: Double(paused - shown) / 1000) {
                learnSpotifyStartLead(kind: learn.kind, sample: sample)
            }
        }
        // 无论这一轮是否在播放,都要更新这三个状态,供下一轮判断"是不是刚从暂停里恢复
        // 播放"——只在上面播放分支里更新的话,"播放→暂停→再播放"这个序列会因为暂停期间
        // 完全没走到这行,让下一次恢复播放时的判断误用暂停前的陈旧 posPrevWall/
        // posWasPlaying,而不是正确识别出"刚从暂停恢复"。
        posTrackingKey = key
        posWasPlaying = playing
        posPrevWall = now
        posPrevWasAdBreak = isAdBreak
        publishPositionBiasIfChanged(snapshot: snapshot, isSpotifyNative: isSpotifyNative, now: now)
        // 自然切歌判定要用"旧曲"的时长/来源——resolve 被调用时 snapshot 已是新曲,所以
        // 这里每轮把本轮的存下来,下一轮它们就是"上一首的"。
        posPrevDurationSecs = snapshot.duration ?? 0
        posPrevGaplessLeadBundleID = Self.carriesGaplessLead(
            tier: Self.positionSourceTier(forBundleID: snapshot.bundleIdentifier),
            bundleID: snapshot.bundleIdentifier) ? snapshot.bundleIdentifier : nil
        if playing, posPausedRawSecs != nil { posPausedRawSecs = nil }
    }

    // 供外部(EnrichCacheStore 保存/删除歌词后)强制重新读取当前曲目的歌词——正常情况
    // apply() 只在换歌那一刻才 reloadCurrentLyrics(),同一首歌播放中途改了缓存内容
    // 不会自动重新读。本地模式的 EnrichCacheReader 每次都是直接读磁盘文件,写完盘立刻
    // 调用这个就能拿到最新内容,不需要等 collector 重启。
    public func forceReloadLyricsForCurrentTrack() {
        // 刚写的内容在后台解(EnrichCacheReader.reloadSoon;同步解 32MB 的索引要 125~200ms,主线程上
        // 四个展示面一起卡)。解完经 onContentAdopted 捅一次 poll:apply() 见 decodedContentVersion 变了
        // 就重灌,末尾按有没有内容拉起 / 停掉 20Hz 定时器,暂停态按冻结位置解一次当前行。
        EnrichCacheReader.reloadSoon()
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
        // .auto/多选模式下要按"这一刻实际在播的是谁"选后端,不能只看设置值——只要不是排他地
        // 选了 Apple Music 一个(PlaybackPlayerPreference.isExclusivelyAppleMusic 为 false),
        // 写路径会走 media-control,而读路径对 Apple Music 走的是精确的 AppleScript 播放头,
        // 两条路不一致。
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
        // 我们主动发的 seek 同样会让 Spotify 重打锚点(与真声对齐)——锚点偏置作废。
        setReportedBias(0, anchorElapsed: nil)
        // 例外:读的是 Spotify 自己的钟、且正在放 —— 拖完它照样先于出声跑一截(SpotifyStartKind.seek),
        // 这里不预置的话,下一拍读数领先这一截,伺服一拍就吸附过去。暂停中拖的,恢复那一拍当场量。
        if anchor != nil, lastSnapshot?.bundleIdentifier == PlaybackPlayer.spotify.bundleIdentifier,
           lastSnapshot?.anchorElapsedTime == nil {
            setReportedBias(spotifyStartLead(.seek), anchorElapsed: nil, startKind: .seek)
        }
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
        // 电台上调的是**这个台上这首歌**那一档(「仅适用于这个电台里播放的歌」)。
        // 绝不能落进按曲目那层:实测同一首歌正常播放本来是准的,把电台的 δ 套过去会把对的搞错。
        let radioKey = currentRadioOffsetKey
        if !radioKey.isEmpty {
            LyricsOffsetStore.shared.nudgeRadio(by: deltaMs, forKey: radioKey)
        } else {
            LyricsOffsetStore.shared.nudge(by: deltaMs, forKey: currentOffsetKey, pinKey: currentPinKey)
        }
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
        // 电台上「归零」清的也是电台那一档 —— 跟上面 nudge 对称,不然调得进去、清不掉。
        let radioKey = currentRadioOffsetKey
        if !radioKey.isEmpty {
            LyricsOffsetStore.shared.setRadioOffset(0, forKey: radioKey)
        } else {
            LyricsOffsetStore.shared.reset(forKey: currentOffsetKey, pinKey: currentPinKey)
        }
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
    /// 那个同名入口是内部为 Spotify 写死的补偿,08-20 随根修一起删了;这次是
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
        // 播放到这首歌时把 pin 状态跟当前校正值重新对一遍(双向,见那个方法的注释)。
        // 幂等,状态已经一致时是纯内存判断。
        LyricsOffsetStore.shared.syncPinToOffset(forKey: currentOffsetKey, pinKey: currentPinKey)
        // 播放器那层按**这一刻真正在播的那个 App** 算。拿不到身份(还没有快照)时传 nil,
        // 那层就按 0 算 —— 绝不能猜一个,否则会把浏览器的补偿套到 Apple Music 上。
        let radioKey = currentRadioOffsetKey
        let effective = LyricsOffsetStore.shared.effectiveOffset(
            forKey: currentOffsetKey, bundleID: lastSnapshot?.bundleIdentifier, radioKey: radioKey
        )
        // MV 偏移只进引擎与 currentLyricsOffsetMs(歌词对齐用),不进 trackLyricsOffsetMs(「你调了多少」)。
        syncEngine.offsetMs = effective + musicVideoOffsetMs
        // 对外报的是**引擎真正在用的那个数**,含这份歌词自己带的 `[offset:]`
        // (`syncEngine.lrcOffsetMs`,见 LRCParser.parseOffsetMs)。
        //
        // 必须含它:这个属性的唯一用途是"把歌词时间轴换算到播放位置",而歌词窗口点某一行
        // 反算 seek 目标用的就是 `行时间 − currentLyricsOffsetMs`。漏掉 LRC 那一层的话,带
        // 非零 offset 的歌点行会跳到隔壁行 —— 正是这个属性当初存在的理由(注释见上面)。
        // 用户可见的那两个数(设置页的基准、菜单里的单曲值)都不含它,那是对的:LRC offset
        // 不是用户调出来的,不该出现在"你调了多少"里。
        let effectiveWithLRC = effective + musicVideoOffsetMs + syncEngine.lrcOffsetMs
        // 只在真的变了时才赋值:这两个都是 @Published,每次赋值都会推着订阅者重渲染,
        // 而 reloadCurrentLyrics 在"歌词还没解析出来"时会被反复调用(见那边的注释)。
        if currentLyricsOffsetMs != effectiveWithLRC { currentLyricsOffsetMs = effectiveWithLRC }
        // 对外那个"这首歌调到了多少"在电台上报的是**电台那一档** —— 用户此刻按加减键改的就是它,
        // 显示另一个数会让人以为没生效。不是电台时逐字同改动前。
        let shown = radioKey.isEmpty ? track : LyricsOffsetStore.shared.radioOffset(forKey: radioKey)
        if trackLyricsOffsetMs != shown { trackLyricsOffsetMs = shown }
        // 前奏那个间奏点的起点跟着总偏移走(见 LyricsSyncEngine.gapWindow),偏移变了要重算。
        let newMarkers = syncEngine.gapMarkers()
        if newMarkers != lyricsGapMarkers { lyricsGapMarkers = newMarkers }
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

    /// 这一刻在放的电台(载荷里的 `radioStationHash`),不是电台就是 nil。见 currentRadioOffsetKey。
    private var currentStationHash: String?

    /// 这首歌**在这个台上**的时间轴校准 key。不是电台 / 拿不到台标哈希 / 还没有曲目身份 → 空串,
    /// 那一层整个不适用,行为跟这个功能加进来之前逐字相同。
    private var currentRadioOffsetKey: String {
        guard lastSnapshot?.isRadio == true, let hash = currentStationHash else { return "" }
        return LyricsOffsetStore.radioKey(stationHash: hash, trackKey: currentOffsetKey)
    }

    /// 上一次读缓存时那个文件的 mtime。变了就说明 collector 又写过,当前这首歌的内容可能
    /// 已经不是手上这一份了(见 apply() 里那段注释)。
    private var lastEnrichMTime: Date?

    /// enrich 缓存**已解码那一代**的版本(= `EnrichCacheReader.decodedContentVersion`)。
    ///
    /// 为什么要把它 @Published 出去:collector 解析一首没听过的歌要**好几秒**
    /// (实测「七月上」13:52:52 开播、13:53:00 才把 cover_url 写进缓存,晚 8 秒),而
    /// `PlaybackCoordinator.refreshHighResCover()` 原来**只**由 曲目/封面字节 的变化触发、
    /// 换歌后 300ms 查一次就完 —— 那一刻缓存里还没有这首歌,于是 clearHighRes() 之后
    /// **永不重试**,整首歌都停在系统那张 100×100 上(这正是「网易云封面依然很糊」的根因)。
    /// 这个信号让"缓存里多了东西"也能成为一个重查触发点 —— 判据跟歌词重载用的是**同一代**
    /// 版本号,不会出现"歌词换上了、封面没跟上"的偏差。
    ///
    /// 只在**变化**时赋值:@Published 是 willSet 语义,同值重复赋会白广播一轮下游订阅。
    @Published public private(set) var enrichContentVersion: Date?

    /// reloadCurrentLyrics 的**全部**会影响引擎装载/派生状态的输入快照。相等 到 整段重算
    /// (简繁转换×3 + 引擎 load + allLines/gapMarkers 重建)可以跳过。
    /// trackKey 必须在里面:两首都没有歌词的歌五个字段全空相等,不带曲目身份的话
    /// 换歌会被闸误吞,currentOffsetKey/applyOffsets/allLines 的 idPrefix、以及 load 的
    /// 抬头识别(trackTitle/trackArtist)全部停留在上一首,偏移校正会串歌。
    private struct LyricsReloadSnapshot: Equatable {
        let trackKey: String
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let instrumental, resolved: Bool
        let variant: ChineseVariant
        let romanizationScripts: RomanizationScripts
        let isCantonese: Bool
        // 加,见 currentTrackPlainLyrics 头注——没有时间戳的纯文本兜底,跟
        // lyrics 一样得参与这道内容等值闸,不然采纳/更换一条纯文本候选之后,闸会因为
        // 其它字段(lyrics 本来就是空的,没变)误判"内容没变"而跳过重算,新内容显示不出来。
        let plainLyrics: String
    }
    private var lastReloadSnapshot: LyricsReloadSnapshot?

    private func reloadCurrentLyrics() {
        guard let snapshot = lastSnapshot else { return }
        let found = EnrichCacheReader.lookup(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            album: snapshot.album ?? ""
        )
        // 见过中文歌词就记一笔(粘性,只置不清)。判据改用共享的
        // `ChineseVariant.affects` —— 这里原本手抄了一份"有汉字、且没有假名",注释还写着
        // "判据跟 ChineseVariant.converted 一致",那正说明它该是同一个函数而不是两份抄写。
        // 刻意放在下面的等值闸**之前**——闸命中早退时这两个标志也必须照常更新。
        let raw = found?.lyrics ?? ""
        if !sawChineseLyrics, ChineseVariant.affects(raw) {
            sawChineseLyrics = true
        }
        // 逐曲的那个每次都要**重算**(它会来回变),不能跟着上面那个 `if !sawChineseLyrics`
        // 的早退一起被跳掉。译文只在**正在显示**时才算进来,理由见它声明处。
        currentLyricsSupportsChineseVariant = Self.supportsChineseVariant(
            lyrics: raw,
            translation: found?.lyricsTr ?? "",
            translationVisible: showsTranslation)
        // 内容等值闸:失效键是整个 enrich 缓存文件的 mtime,collector
        // 给**别的歌**写盘(专辑预取最多 30 首逐个落盘/译文回填/重打分)都会带着一字未变的
        // found 走到这里 —— 原来每次都白跑简繁转换×3 + 全套解析过滤 + 整曲罗马音/分词重算
        // + allLines/gapMarkers 重建,单次 10-50ms 主线程,正撞上 30Hz 填色渲染。快照含
        // resolved/instrumental:它们翻转("搜索中"→"确实没有")时快照必不相等,不会被
        // 闸吞掉;比较用 String ==(mtime 已变时 lookup 是新解码实例,引用比较必 miss,
        // 别指望它)。 闸只跳"重算",不跳上面的粘性置位;闸后的 found 派生赋值
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
            romanizationScripts: romanizationScripts,
            isCantonese: found?.isCantonese ?? false,
            plainLyrics: found?.plainLyrics ?? "")
        if reloadSnapshot == lastReloadSnapshot {
            logger.debug("lyrics reload skipped: content unchanged (mtime-only churn)")
            return
        }
        lastReloadSnapshot = reloadSnapshot
        // 简繁转换只作用在展示上:正文、译文、逐字数据都转,罗马音是拉丁字母不用转。
        // 逐字数据整串转是安全的 —— 时间戳是数字,转换只碰汉字。
        let variant = chineseVariant
        // 日文歌里被源写成简体的汉字先修回(`JapaneseKanjiRepair`,规则见那边),再做
        // 用户的简繁偏好。顺序无所谓 —— `converted` 见到假名就整份放过,对日文歌本来就是空操作 ——
        // 但概念上先修源的错、再套用户的偏好。整首判定用正文,正文为空(只有逐字)才看逐字串;
        // 译文是中文、罗马音是拉丁字母,都不进修回。
        let rawYRC = found?.lyricsYRC ?? ""
        let japaneseSong = Romanizer.looksJapaneseSong(raw.isEmpty ? rawYRC : raw)
        // 引擎侧还有第二道指纹早退(见 LyricsSyncEngine.load 注释),两道闸各管一层:这里
        // 管"连转换都别做",那里兜"其它调用方/清过发布状态后的重灌"。
        syncEngine.load(
            lyrics: variant.converted(JapaneseKanjiRepair.repair(raw, japaneseSong: japaneseSong)),
            lyricsTr: variant.converted(found?.lyricsTr ?? ""),
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: variant.converted(JapaneseKanjiRepair.repair(rawYRC, japaneseSong: japaneseSong)),
            // 用来认出歌词文件开头那行「曲名 - 歌手」抬头,见 looksLikeHeaderLine。
            trackTitle: snapshot.title ?? "",
            trackArtist: snapshot.artist ?? "",
            romanizationScripts: romanizationScripts,
            songIsCantonese: found?.isCantonese ?? false
        )
        currentOffsetKey = LyricsOffsetStore.trackKey(
            artist: snapshot.artist ?? "",
            title: snapshot.title ?? "",
            lyrics: found?.lyrics ?? "",
            lyricsYRC: found?.lyricsYRC ?? ""
        )
        // 必须走 EnrichCacheKeys.normalizedKey,不能拿播放器报的原始三段自己拼:
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
        // 但"跑完了"不等于"问过了":那一轮要是有源因为熔断冷却被整个跳过(直连 DNS 抽风
        // 之类),下这个结论就是把一次网络事故说成了这首歌的属性。searchIncomplete 就是
        // 那种情况,collector 那边还欠一次快速补搜,界面继续说"搜索中"才是实话——它不会
        // 无限转圈,补搜一跑完这个标记就没了,详见 EnrichCacheLyrics.searchIncomplete。
        let newNoLyrics = (found?.resolved ?? false) && !newHasContent && !newInstrumental
            && !(found?.searchIncomplete ?? false)
        if newNoLyrics != currentTrackHasNoLyrics { currentTrackHasNoLyrics = newNoLyrics }
        // 纯文本兜底只在"确实没有能同步显示的版本"时才有展示意义——newHasContent 为 true
        // 时(不管是不是这首歌待会儿又补出了带时间戳的版本)优先用那份,不显示纯文本,
        // 避免"歌词窗口"同时收到两份内容不一定完全一致的候选、不知道信哪个。
        let newPlainLyrics = newHasContent ? "" : (found?.plainLyrics ?? "")
        if newPlainLyrics != currentTrackPlainLyrics { currentTrackPlainLyrics = newPlainLyrics }
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
    private func scheduleArtworkStaleTimeout(forKey key: String, after: TimeInterval? = nil) {
        artworkStaleTimeoutTask?.cancel()
        artworkStaleTimeoutTask = nil
        guard artworkData != nil else { return }
        let deadline = after ?? Self.artworkStaleTimeout
        artworkStaleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled, let self, self.lastKey == key else { return }
            logger.debug("artwork stale timeout: clearing previous cover after \(Self.artworkStaleTimeout)s")
            self.artworkData = nil
            self.artworkAverageHex = nil
            self.artworkStaleTimeoutTask = nil
        }
    }

    // 换歌后取图拿到 nil 时的重试节奏(秒)。实测坐实:切歌那一刻系统 Now Playing
    // 的封面往往还没更新完,media-control 会先返回"有新曲目元数据、但没有 artworkData"。
    // 不能一次 nil 就当成"这首歌没有封面"定案——那样会导致整首歌都显示占位音符 + 系统
    // 浅色背景(实测切歌后录屏:左栏平均亮度从 0.446 升到 0.946 并**一直保持**,不是闪一下),
    // 表现就是"切歌白屏一下子",只是通常重新播到下一首又碰巧取到了才不容易被注意到。
    //
    // 间隔递增而不是等间隔:绝大多数情况第一次重试(0.3s)就有了,不值得为罕见的慢场景把
    // 每次切歌都拖长。
    //
    // 不能只按这几个 sleep 之和(2.1s)去论证"落在 artworkStaleTimeout(3s)之内"——
    // 这条链上还有最多 4 次 attempt(),每次都要 fork media-control 子进程、把几百 KB 的
    // base64 封面读到 EOF、waitUntilExit 再解码,单次就是几百毫秒量级(见本文件取图那段
    // 注释)。只要平均往返超过 ~225ms,3s 的兜底就会在重试还没跑完时先开火,把旧封面清掉
    // ——正好重演它当初要消除的那次白屏(先闪成系统浅色背景,重试成功后再闪回来,两次跳变)。
    // 修法是每次重试前把兜底任务重新排一遍(见 fetchArtworkForCurrentTrack 里的调用),
    // 这样"3s"变成"距最后一次尝试 3s",既不会打断重试,也保留了"子进程真挂住就别无限期
    // 挂着旧封面"这个原始目的。
    private static let artworkRetryDelays: [TimeInterval] = [0.3, 0.6, 1.2]

    // 首轮定案后按这张表再确认几次(累计 3 / 8 / 16 / 31 秒)。两件事靠它收敛:
    //
    // 1. 首轮可能抓到"新标题+旧封面"的合体载荷 —— 识别陈旧封面靠的是载荷自带的
    //    artist/title(见 fetchArtwork 的 trackKey 注释),但系统侧先换标题、封面字段
    //    晚一拍才刷时,这份陈旧带着**新歌**的标识,首轮的比对拦不住。
    // 2. 播放器会**先推自己的占位图、真封面晚几秒才推**。酷狗 3.3.2 实测:换歌后头 8 秒
    //    推的是它内置的那张蓝底黑胶唱片(同一张图被本机十几首歌共用),之后才换成真封面。
    //    网易云"先给占位图、匹配到曲库后换真图"是同一类行为。
    //
    // 别退回"只确认一次"。3 秒那一档整个落在占位期里,字节没变就不替换、之后再也不看,
    // 结果是**整首歌**都挂着播放器的占位图。它是一张合法的 600×600 JPEG,取图这条路上没有
    // 任何一道判据能识破它,日志里也不留痕迹——看起来完全像"封面取不到"。
    //
    // 登记在案的占位图(KnownPlaceholderArtwork)只是它的补充,不能替代它:那张表按字节指纹认图,
    // 播放器换一版内置图就静默失效。按时间多确认几次是通用的——没有这个行为的播放器只是多几次
    // 字节比对,相同就原样丢弃。
    //
    // 档位密在 3~16 秒之间,是按占位期的实测分布排的:同一个播放器上量到过 3.2 / 7 / 8 秒
    // 三种翻转时刻。稀疏排法(累计 3 / 8 / 16)在 8 秒那一档翻转的歌上最坏要等到第 16 秒才
    // 换掉占位图;加密到累计 3 / 6 / 9 / 12 / 16 之后,翻转到换上的滞后收在 3 秒以内。
    // 首尾两档不动:3 秒是"翻转最快的那种"能赶上的最早时机,31 秒是整条确认链的收尾。
    // 别为了省这两次取图把中间挖空——挖掉的正是占位期的众数所在。
    private static let artworkConfirmDelays: [TimeInterval] = [3, 3, 3, 3, 4, 15]

    // 首轮留着旧封面等真图(见 fetchArtworkForCurrentTrack 里的 holdingPrevious)最多等到二次确认的
    // 哪一档(累计秒数)。9 秒盖住实测的换图时刻(酷狗占位图 3.2 / 7 / 8 秒;Spotify 系统侧切到新歌
    // 常见 3~9 秒),到这一档还没等到就当场清掉旧封面。清理必须在确认循环里做,别交给定时器:
    // 确认间隔和 artworkStaleTimeout 都是 3 秒,定时器的期限必然跟某一档确认撞在一起,旧封面先被
    // 清成灰底、下一拍真图才到。
    private static let artworkHoldLimit: TimeInterval = 9

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
            // 取图不再顺手预算均值色:重试打满 key 不匹配、confirm
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
            // 重试,绝不能直接挂上(举例:网易云云盘歌若直接挂上,会沿用上一首封面)。
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
            // 首轮没等到这首歌能用的图,又不能断定它没有封面,就**留着当前挂着的旧封面**,交给下面的
            // 二次确认换上(到 artworkHoldLimit 那一档还等不到才清)。两种情况:
            //  - 重试打满载荷仍是别的歌的:系统侧还没切到这首(Spotify 实测常要 3~30 秒)。这张图绝不能
            //    挂上,但它也不是"这首没有封面"的证据,清空会让歌词窗口整窗回落成无封面的样子再闪回来;
            //  - 登记在案的播放器内置占位图(KnownPlaceholderArtwork):挂一张跟这首歌无关的唱片,比
            //    "旧封面多留几秒"糟。
            // 留一条日志:万一两条路径的元数据出现系统性偏差(同一首歌两个 key 恒不相等),前一条会对
            // 每首歌都触发,靠日志能一眼定位;后一条用来确认占位图登记表还在生效。
            var holdingPrevious = false
            if let payloadKey, data != nil, !Self.artworkKeyMatches(payloadKey, expectedKey) {
                logger.notice("artwork payload key mismatch after retries: payload=\(payloadKey, privacy: .public) expected=\(expectedKey, privacy: .public), keeping previous cover")
                holdingPrevious = true
            } else if let data, KnownPlaceholderArtwork.isPlaceholder(data) {
                logger.notice("artwork placeholder recognized: bytes=\(data.count), keeping previous cover")
                holdingPrevious = true
            }
            if holdingPrevious {
                // 清旧封面由确认循环在 artworkHoldLimit 那一档做;兜底任务只防子进程卡死(确认循环跑不下去),
                // 期限排在那一档之后。
                self.scheduleArtworkStaleTimeout(
                    forKey: expectedKey, after: Self.artworkHoldLimit + Self.artworkStaleTimeout)
            } else {
                // 结果定案了(data 为 nil = 重试完还是没有,判定这首歌确实没有封面),
                // 兜底任务**先**撤掉再去取色 —— 取色那次 await 有几十毫秒,3s 兜底在最后
                // 一次尝试逼近期限时可能正落在这个窗口里开火,把旧封面清掉又立刻被新封面
                // 覆盖,白闪一跳。
                self.artworkStaleTimeoutTask?.cancel()
                self.artworkStaleTimeoutTask = nil
                // 定案才取色(后台),丢弃路径一次都不算。
                let averageHex = await hexFor(data)
                guard expectedKey == self.lastKey else { return }
                self.artworkData = data
                self.artworkAverageHex = averageHex
                self.noteRadioStationArtwork(data, forKey: expectedKey)
                logger.debug("artwork fetched: bytes=\(data?.count ?? 0) retries=\(round) average=\(averageHex ?? "nil")")
            }

            // 二次确认,理由见 artworkConfirmDelays 的注释。换上一次就收工——占位图换成
            // 真封面是一次性事件。
            //
            // 某一档读空、或读到别的歌,要 continue 不能 return:一次瞬时的读取失败不该
            // 把已经挂好的封面抹掉,更不该让后面几档不再检查(播放器换真图的那一刻正好撞上
            // 一次空载荷,整首歌就再也没有第二次机会了)。
            var waited: TimeInterval = 0
            for delay in Self.artworkConfirmDelays {
                try? await Task.sleep(for: .seconds(delay))
                waited += delay
                guard expectedKey == self.lastKey else { return }
                let confirm = await attempt()
                guard expectedKey == self.lastKey else { return }
                // 留着的旧封面恰好就是这首的(同一张专辑的下一首,字节相同):等到了,别再按期限清掉。
                if holdingPrevious, let confirmData = confirm.data, let confirmKey = confirm.payloadKey,
                   Self.artworkKeyMatches(confirmKey, expectedKey), confirmData == self.artworkData {
                    holdingPrevious = false
                    self.artworkStaleTimeoutTask?.cancel()
                    self.artworkStaleTimeoutTask = nil
                    continue
                }
                guard let confirmData = confirm.data, let confirmKey = confirm.payloadKey,
                      Self.artworkKeyMatches(confirmKey, expectedKey),
                      // 这一档又读到占位图:字节确实跟当前挂着的不一样,但它不是真封面,
                      // 换上去等于把上面那道闸白拦一次。
                      !KnownPlaceholderArtwork.isPlaceholder(confirmData),
                      confirmData != self.artworkData else {
                    // 留着旧封面等到了期限还没等到这首的图:当场清掉,理由见 artworkHoldLimit。
                    if holdingPrevious, waited >= Self.artworkHoldLimit {
                        holdingPrevious = false
                        self.artworkStaleTimeoutTask?.cancel()
                        self.artworkStaleTimeoutTask = nil
                        if self.artworkData != nil {
                            logger.notice("artwork: no cover for \(expectedKey, privacy: .public) \(waited, privacy: .public)s after the track change, clearing the previous one")
                            self.artworkData = nil
                            self.artworkAverageHex = nil
                        }
                    }
                    continue
                }
                // 先比完字节确认真的要换,才算这一份的均值色(attempt 顺手预算的话,字节相同
                // 丢弃的常态路径每次白算一遍取色)。
                let confirmHex = await hexFor(confirmData)
                guard expectedKey == self.lastKey else { return }
                logger.notice("artwork confirm pass replaced cover after \(waited, privacy: .public)s: bytes=\(confirmData.count) hadCover=\(self.artworkData != nil)")
                // 兜底任务要一起撤:留着旧封面那条路上它还在倒数,不撤的话几秒后会把刚换上的真封面清掉。
                self.artworkStaleTimeoutTask?.cancel()
                self.artworkStaleTimeoutTask = nil
                self.artworkData = confirmData
                self.artworkAverageHex = confirmHex
                self.noteRadioStationArtwork(confirmData, forKey: expectedKey)
                return
            }
            if self.artworkData == nil {
                logger.notice("artwork: still no matching system cover \(waited, privacy: .public)s after the track change for \(expectedKey, privacy: .public)")
            }
        }
    }

    // 从封面原始图片数据算出一个单一的平均色,供"跟随封面"外观模式当动态高亮色用——
    // 算法跟同类开源实现一致:CIAreaAverage 把
    // 整张图平均成一个像素,而不是 K-means/直方图那类更贵的聚类算法,对"给悬浮歌词提供
    // 一个跟封面基调呼应的强调色"这个用途完全够用。
    //
    // 这里**只求均值,不做任何亮度调整**。之前它顺手调了 brightenedAccent,
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
    // PlaybackCoordinator.blurBakeContext 同一个理由/写法(性能审计,
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
    /// 这条规则**只服务于永远深色的表面**(灵动岛)。它保证的是"够亮",
    /// 而桌面悬浮歌词压在壁纸/任意窗口上,"够亮"在浅色背景下正好是最坏的选择 ——
    /// 那一侧改走 accentAgainstStroke,见那里的注释。
    ///
    /// 不能在 RGB 空间按亮度整体乘一个 boost,两个毛病:
    ///  ① 近黑封面(纯黑背景专辑)均值可能只有 (2,1,3)/255,boost 达到 11 倍,于是把
    ///    JPEG 噪点放大成一个饱和的随机色 —— 同一张黑封面每次取到的颜色都不一样;
    ///  ② 乘法保持 RGB 比例 = 保持饱和度,一个暗而浓的酒红被提到该亮度后依然浓,
    ///    贴在歌词上非常刺眼。
    ///
    /// 改成 HSB 空间处理:
    ///  - 近黑直接兜底成中性灰,不试图从噪点里"抢救"色相;
    ///  - 提亮多少,就按同一比例压低多少饱和度 —— 被提亮的颜色天然该更淡,这正是
    ///    人眼对"亮色"的预期,也避免了上面第 ② 条的刺眼。
    ///
    /// 手写 RGB与HSB 而不是用 NSColor:LyrimuseCore 这一层刻意不引入 AppKit
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

    /// `NotchCardStyle.coverArt` 背景上那层黑色叠加的不透明度——`NotchLyricsView.
    /// backgroundLayer` 拿它铺 `Color.black.opacity(...)`,`accentForCoverArtBackground`
    /// (下面)拿它**推算**背景实际有多亮。两处必须用同一个数,所以提成命名常量而不是各自
    /// 写一遍 0.45——修对比度问题之前就是这么各写各的,两处数字一旦以后有一处
    /// 改动没同步,contrast 的估算值就会跟渲染出来的背景对不上,静默失效。
    nonisolated public static let notchCoverArtOverlayOpacity: Double = 0.45

    /// coverArt 卡片风格下,给灵动岛文字保足够对比度。
    ///
    /// `accentForDarkBackdrop` 假设灵动岛背景永远接近纯黑(纯黑/深色渐变两种风格确实是),
    /// 但 coverArt 背景是「模糊封面 + `notchCoverArtOverlayOpacity` 黑叠加」——亮度**正比于
    /// 封面本身的亮度**,不是恒定的暗。亮封面(举例一张黄底专辑封面,均值
    /// #BBA45E、Rec.709 luma 0.645)已经在 accentForDarkBackdrop 的地板之上、不会被再提亮,
    /// 叠加 45% 黑之后背景仍有 luma 0.355(不暗),文字跟这个背景的 WCAG 对比度实测只有
    /// 2.78,连大号文字的门槛(3.0)都够不到,灵动岛字号(9~13.5pt)按 WCAG 还够不上"大号
    /// 文字"这一档,该按 4.5 的门槛要求。
    ///
    /// 跟 accentAgainstStroke 修桌面悬浮歌词描边对比度是同一个哲学:量**真实相邻色**的
    /// 对比度,不是赌一个"背景反正很暗"的假设——这里直接复用 accentAgainstStroke,把
    /// "描边色"换成按封面自身算出来的 coverArt 背景色估计值。只在 `.coverArt` 风格时调用,
    /// 纯黑/深色渐变两种风格背景是真的暗,原有的 accentForDarkBackdrop 地板已经够用,
    /// 不该为它们多算一次。
    ///
    /// - Parameters:
    ///   - r/g/b: `accentForDarkBackdrop` 处理过的候选文字色。
    ///   - rawR/rawG/rawB: 封面**原始**均值色(未经 brightenedAccent/accentForDarkBackdrop
    ///     提亮)——背景是拿这份原始色乘 `(1 - notchCoverArtOverlayOpacity)` 得出的,不能拿
    ///     已经被提亮过的文字色去算,那样估出来的背景会比实际渲染的亮得多。
    nonisolated public static func accentForCoverArtBackground(
        r: Double, g: Double, b: Double,
        rawR: Double, rawG: Double, rawB: Double,
        minContrast: Double = 4.5
    ) -> (r: Double, g: Double, b: Double) {
        let dim = 1 - notchCoverArtOverlayOpacity
        return accentAgainstStroke(
            r: r, g: g, b: b,
            strokeR: rawR * dim, strokeG: rawG * dim, strokeB: rawB * dim,
            minContrast: minContrast)
    }

    // MARK: - 桌面悬浮歌词的封面取色(跟描边拉开对比)

    /// 把封面均值色调成"在描边包围下一定看得清"的文字色。桌面悬浮歌词专用,纯函数。
    ///
    /// ### 为什么不能沿用 brightenedAccent
    ///
    /// 那条规则保证"够亮",前提是背景永远深(灵动岛)。桌面悬浮歌词压在壁纸和任意窗口上,
    /// 背景可能是任何颜色 —— 近黑封面被兜底成 0.72 的浅灰,用户又开着不透明
    /// 白描边,于是浅灰字被白描边整个吃掉,压在浅色窗口上几乎看不见(实测:屏幕上最暗的
    /// 不透明像素 #ADABA6,相对亮度 0.671,而描边是纯白)。 别在这一侧套那条亮度地板:
    /// 不兜底时同一张近黑封面算出来是 #160B21,深字配白边非常清楚。
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

        // 优先方向差一点点够不到边界(灵动岛「封面偏白、歌词却是全黑,
        // 太突兀」):贴着边界(纯白/纯黑)已经接近达标时,宁可就地收下这个"差一点点"
        // 的结果,也不要为了凑够数值目标翻到对面走极端——翻方向在几何上总能精确命中
        // minContrast(往反方向去到 lower/upper 就是照着目标解出来的),数值上永远"更
        // 好",但对一张偏白的封面,翻过去意味着把文字砸成近乎纯黑,观感上是灾难,
        // 不是"差一点点"能比的。
        //
        // 这里**不能**写 95% 容忍度:手算的假设场景(luma≈0.187)看着能过,而真实封面
        // (方大同《红豆》,Timeless 专辑,大面积白底
        // 配一角深色人像)一测,问题还在——真实封面均值色算出来 luma≈0.779,coverArt
        // 背景估出来 luma≈0.207,贴纯白只能到对比度 4.08,只有 minContrast=4.5 的
        // 90.7%,被 95% 的门槛卡在外面,照样翻成了近黑。教训:**手算的假设数字算得再
        // 仔细,也不能替代拿真实素材跑一遍**——这条经验在这个仓库里已经不是第一次
        // 印证(第九轮背景取色那次也是纸面系数一个个假设都对、样本一放大就露馅)。
        // 这版把容忍度从 95% 放宽到 80%,用《红豆》这组真实数字(见下面 selftest)
        // 和原有的假设场景一起钉住,两组都过。
        //
        // 判据双重限定,不能只看"离目标够不够近":① 贴边界的实际对比度必须先过 WCAG
        // 大号文字基线 3.0(所有调用方字号都够格用这条基线)——这一步保证 minContrast
        // 本来就是默认值 3.0 的调用方(比如下面的全区间扫描)永远不会走进这条分支:
        // canGoUp 为 false 在 minContrast==3.0 时数学上等价于贴边界对比度 <3.0,必然
        // 过不了这道闸,行为原样不变,这条数学关系不随下面这个比例常数变化,调整比例
        // 不会影响这条安全性。② 贴边界还要接近 minContrast 本身(取 80%)——只有
        // minContrast 明显高于基线(比如 coverArt 那条路的 4.5)、且贴边界的结果离
        // 那个更高目标也没差太远时才生效;像下面 selftest 的 mid-gray 反例
        // (minContrast=7.0,贴边界只够到目标的 57%),跟《红豆》案例的 90.7% 差着
        // 34 个百分点,离得足够远,仍然应该老实翻方向或取更好端点——80% 卡在两者中间,
        // 两头都留了余量,不是贴着《红豆》那组数字的下边界硬凑的。
        let closeEnoughFloor = 3.0
        let closeEnoughRatio = 0.80
        if preferUp, !canGoUp {
            let clamped = contrastRatio(strokeLum, 1)
            if clamped >= closeEnoughFloor, clamped >= minContrast * closeEnoughRatio {
                return blendToLuminance(r: r, g: g, b: b, target: 1.0, towardWhite: true)
            }
        }
        if !preferUp, !canGoDown {
            let clamped = contrastRatio(strokeLum, 0)
            if clamped >= closeEnoughFloor, clamped >= minContrast * closeEnoughRatio {
                return blendToLuminance(r: r, g: g, b: b, target: 0.0, towardWhite: false)
            }
        }

        if canGoUp {
            return blendToLuminance(r: r, g: g, b: b, target: upper, towardWhite: true)
        }
        if canGoDown {
            return blendToLuminance(r: r, g: g, b: b, target: lower, towardWhite: false)
        }
        // 两侧都够不到 —— 取黑/白里对比更好的那个端点,别返回一个"差一点点"的中间值。
        //
        // 默认的 minContrast = 3.0 走不到这里:两侧都够不到要同时满足
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
