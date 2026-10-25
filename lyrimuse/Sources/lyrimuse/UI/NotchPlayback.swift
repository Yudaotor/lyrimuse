import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

/// 灵动岛的**窄订阅代理**(性能审计落地,与悬浮歌词的 OverlayPlayback 同款
/// 模式,那边的注释讲了完整机制,这里不重复):PlaybackCoordinator 36 个 @Published 灵动岛
/// 实读约 17 个、AppSettings 47 个只读 2 个,整对象订阅会让歌词窗口拖音量、设置页无关
/// 滑杆这类写入以鼠标事件频率打醒整卡 body(含封面背景/跑马灯/音浪),开多屏镜像再按
/// 屏数翻倍。只转发实读字段,值类型一律 removeDuplicates。
///
/// sink 只用参数值,不回读源属性(@Published willSet 时机,回读是旧值)。
///
/// anchor 例外地**入订阅**(跟悬浮窗不同):灵动岛的 progressSection 要在 body 里判断
/// 「有没有锚点」决定进度条走播放态还是暂停态分支,而 LocalPlaybackSource 只在首锚/换歌/
/// seek/倍速变化时才重建锚点(稳定播放期间不赋值),它本身就是低频源,订阅无害。
/// currentLyricsOffsetMs 仍由逐字填色的 TimelineView 闭包直读协调器,不入订阅。
@MainActor
final class NotchPlayback: ObservableObject {
    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var title = ""
    @Published private(set) var displayTitle = ""
    @Published private(set) var artist = ""
    /// 画在歌手模块上的那份(署名不可信的播放器在纠正落地前是空串,判据见
    /// `PlayerArtistFix.displayArtist`)。`artist` 留着给广告判定那类拿它当判据的地方。
    @Published private(set) var displayArtist = ""
    /// 只有「专辑」这个耳朵模块读它。窄订阅的纪律没变:多订一个字段是因为
    /// 真的有人读,不是"顺手都订上"。
    @Published private(set) var album = ""
    @Published private(set) var displayAlbum = ""
    /// 专辑行可不可点(`trackInfoAlbumLine`):键里没专辑、但有 YouTube Music 登记的那张时也算有专辑。
    @Published private(set) var youtubeMusicAlbum = ""
    @Published private(set) var isPlayingNow = false
    /// 播放控制被拦下时的说明,没拦下是 nil(见 `PlaybackCoordinator.playbackControlsWithheldReason`)。
    @Published private(set) var controlsWithheldReason: String?
    @Published private(set) var currentLine: SyncedLyricLine?
    /// 歌词行**主行**画哪一句(是合成值,不再直接等于 PlaybackCoordinator 的
    /// compactLine):
    ///   - 副行关着(单行面):取 `compactLine` —— 唱完就切走、提前亮出下一句给跟唱用,规则见
    ///     CompactLyricLead / 05 章决策 11;
    ///   - 副行开着(不管显示的是下一句、译文还是罗马音):取 `currentLine` —— 跟悬浮歌词同一套语义,
    ///     唱完停在填满的样子直到下一句开始。副行是「下一句」时尤其不能再提前切:那会变成两行同一句;
    ///     选译文 / 罗马音时副行显示的是**当前句**的译文 / 罗马音,主行若提前切到下一句,两行就对不上号;
    ///   - 「卡拉OK效果」关着时再压成整行(`lineLevel`),渲染分支不用改,自然落到 `.plain` 那一档。
    /// `currentLine` 本身仍单独保留 —— 均衡器条子跟的是"此刻在唱哪个字",那是 currentLine 的语义,
    /// 不能跟"屏幕上显示哪一句"混。
    @Published private(set) var displayLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?
    /// 副行的文本(`AppSettings.notchSecondaryLine` 四选一):下一句 / 当前句译文 /
    /// 当前句罗马音,取不到就是 nil(这一行留空、高度不变,不让卡片一首一首跳)。`.off` 恒为 nil。
    /// 罗马音走 `SyncedLyricLine.romanization`,跟悬浮歌词同一来源(服务端 lyrics_roma 优先、
    /// 客户端 Romanizer 兜底、`romanizationScripts` 语言门控都在引擎侧做完了),这里不再判一遍。
    @Published private(set) var secondaryText: String?
    /// 副行选项本身,视图据此决定歌词行走单行排法还是双行排法。 初值必须是
    /// `AppSettings.defaultNotchSecondaryLine`,理由同下面 `lyricsAlignment` 那条。
    @Published private(set) var secondaryLine: LyricSecondaryLine = AppSettings.defaultNotchSecondaryLine
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    /// 这首只有纯文本歌词(没有时间戳):「暂无歌词」那一格改说「仅有纯文本，无时间戳」,同悬浮歌词。
    @Published private(set) var hasPlainLyrics = false
    @Published private(set) var engineNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    /// 电台口白:这一刻在放的不是歌,台里在说话。语义与 `isCurrentTrackAdBreak` 平行。
    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var radioStationName: String?
    @Published private(set) var radioStationImage: NSImage?
    /// 前奏/间奏窗口(见 `LyricsGapWindow`):给 `LyricsGapDotsView` 用。
    /// 跟悬浮歌词同一来源(`PlaybackCoordinator.rawGapWindow`),不设门槛 —— 灵动岛没有
    /// "沿用上一行"这条退路,短前奏/短间奏也要画出来,不然就是兜底状态机漏判退回静态占位符。
    @Published private(set) var rawGapWindow: LyricsGapWindow?
    /// 单行面此刻是「唱完了、下一句还早」的占位(`SurfaceLyrics.compactPlaceholder`),`gapDotsWindow` 要用。
    @Published private(set) var compactShowsPlaceholder = false
    /// 这条广告是插播里的第几条 / 一共几条(「广告中,还剩几个广告」
    /// 显示出来)。只有 YT Music 网页广告给得出;拿不到是 nil,那一段整个不画 —— 同
    /// 「时长未知不画倒计时」那条纪律,不编数字。语义见 `LocalPlaybackSource.currentAdSlot`。
    @Published private(set) var currentAdSlot: YouTubeMusicAdProbe.AdSlot? = nil
    /// 「广告中」那一行的倒计时从哪来,见 `LocalPlaybackSource.adCountdown`。
    @Published private(set) var adCountdown: AdCountdown = .track
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var highResArtworkImage: NSImage?
    // **这里刻意没有 `motionCoverFile`**(撤掉)。灵动岛这一面的封面只画静态图 ——
    // 动态封面只留在歌词窗口那张 460pt 的大卡上。理由见 artworkThumbnail 上方那段。
    // `PlaybackCoordinator.motionCoverFile` 本身还在(歌词窗口在用),别顺手把它一起删了。
    @Published private(set) var blurredArtworkImage: NSImage?
    /// coverArt 背景那层黑色压暗,按模糊图亮区算(`NotchBackdropTone.overlayOpacity`)。
    @Published private(set) var backdropOverlayOpacity: Double = LocalPlaybackSource.notchCoverArtOverlayOpacity
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?
    /// 图层版逐字 / 间奏三点按墙钟自己跑动画:暂停通知先到、锚点已冻住而 isPlayingNow 还没翻时也算停着,
    /// 不然先按原速冲出去、等轮询报了暂停再跳回(同悬浮歌词、歌词窗口,07 章决策 167)。
    var lyricsClockRunning: Bool { isPlayingNow && !(anchor?.isFrozen ?? false) }
    /// 播放速率(锚点里的,读数异常时图层行自己按 1 算)。倍速播放时逐字填色、滚动、尾部渐隐都按它排。
    var playbackRate: Double { anchor?.rate ?? 1 }
    @Published private(set) var currentDurationMs: Int?
    /// 灵动岛几乎所有前景元素的颜色:音浪、歌名、歌手、歌词(含逐字染色的调色板)、三个播放键、进度条、瞬态横幅,全卡 16 处
    /// `accentOrWhite` 都是它。取到封面主色就用,否则白(用 notchAccentColor 而非 artworkAccentColor 的理由见
    /// PlaybackCoordinator.notchAccentColor 注释)。两个输入在这里预组合成单个去重值,任何一个变了才发一次。
    ///
    /// "要不要跟封面走"由 `notchCardStyle == .coverArt` 决定,不读桌面悬浮歌词那边的 `AppSettings.followsCoverArt`:那个开关的入口
    /// 都挂在悬浮歌词上,只开灵动岛的用户够不到。灵动岛「风格」里的「跟随封面」就是这件事:选它 = 整张卡跟着封面走(背景是模糊
    /// 封面、前景是封面主色),选另外三种风格 = 前景恒为白。取不到封面主色时 `notchAccentColor` 为 nil,自动落回白色,跟
    /// `.coverArt` 背景在没有封面时退回纯黑是同一种兜底。
    @Published private(set) var accent: Color = .white
    // ---- 来自 AppSettings ----
    // 灵动岛只读这一项:它既决定卡片背景(见 NotchCardStyle.backdrop / backgroundLayer),
    // 也决定前景取不取封面主色(折进上面的 accent)。
    @Published private(set) var notchCardStyle: NotchCardStyle = .coverArt
    /// 稳态/展开那一行两只耳朵各显示什么(见 NotchEarModule)。
    @Published private(set) var leftEar: NotchEarModule = .title
    @Published private(set) var rightEar: NotchEarModule = .artist
    /// 换歌翻牌那条歌名前那枚音符的颜色:封面(高清替代优先)里最鲜艳的那种(`ArtworkVividColor`);没有封面、或封面里
    /// 没有够鲜艳的颜色时为 nil(画白)。换图时在后台算,只认最后一次换图的结果。
    @Published private(set) var vividAccent: Color?
    private var vividGeneration = 0
    /// 歌词行末尾那枚封面缩略图要不要显示、贴哪一边。走这里现读而不是
    /// `NotchChromeSource` 协议——它只影响 `lyricRowContent` 内部的 HStack 排列,不影响
    /// 卡片高度/宽度,理由同 `notchCardStyle`/`leftEar`/`rightEar`(那几个也只影响渲染)。
    @Published private(set) var lyricRowShowsArtwork: Bool = true
    @Published private(set) var lyricRowArtworkPosition: NotchLyricRowArtworkPosition = .right
    /// 装得下的短句靠哪边。同上走这里现读:它只改跑马灯静止时的
    /// 对齐锚点和展开态「下一句」那一行的 frame 对齐,不影响卡片任何一个尺寸。
    /// 初值必须是 `AppSettings.defaultNotchLyricsAlignment`,不能另写一个字面量 ——
    /// 这个 `@Published` 的初值和 `AppSettings.init()` 的 fallback 是同一件事,写两份就会
    /// 在"订阅还没首次投递"的那一帧闪一下另一个方向。
    @Published private(set) var lyricsAlignment: LyricsRestingAlignment =
        AppSettings.defaultNotchLyricsAlignment
    /// 灵动岛歌词的字体(设置页「字体」组):主行 / 主行同字号细一档(广告态倒计时)/ 副行与展开区
    /// 「下一句」预览。同上走这里现读:只改字形,不改卡片任何一个尺寸(字号上限由 Core 倒推、保证两行仍塞进 44,
    /// 见 `NotchLyricRowMetrics`)。初值直接读 `AppSettings.shared` 已算好的派生值,不另抄一份字面量。
    @Published private(set) var mainFont: Font = AppSettings.shared.notchMainFont
    @Published private(set) var mainDetailFont: Font = AppSettings.shared.notchMainDetailFont
    @Published private(set) var secondaryFont: Font = AppSettings.shared.notchSecondaryFont
    /// 主行字体的 AppKit 孪生,给有逐字时间轴的主行画图层长图用(`layerKaraokeLine`,见
    /// `AppSettings.notchMainNSFont`)。
    @Published private(set) var mainNSFont: NSFont = AppSettings.shared.notchMainNSFont

    /// 副行开着时主行那一格给多高(`lyricTextColumn`):随字号走,公式只在 Core 一份。
    @Published private(set) var mainLineHeight: CGFloat =
        NotchLyricRowMetrics.mainLineHeight(fontSize: CGFloat(AppSettings.shared.notchFontSize))
    /// 主行字号本身(已夹回 11…17)。`mainFont` 是 Font、取不出数值,而间奏「•••」的圆点要按字号
    /// 等比给尺寸 —— 跟歌词窗口 / 悬浮歌词同一套 0.32 / 0.3 比例,见 `lyricContent` 里那处调用。
    @Published private(set) var mainFontSize: CGFloat =
        NotchLyricRowMetrics.clampedMainFontSize(CGFloat(AppSettings.shared.notchFontSize))
    /// 下一句的对唱声部(「对齐方式 · 自动」用)。跟 `nextLineText` 一样直接镜像
    /// `PlaybackCoordinator.nextLineSide` —— 悬浮歌词那边同一个来源、同一条"下一句不假定跟当前句
    /// 同一边"的理由(见 `LyricsOverlayView.nextLineDuetSide`)。当前句的声部不另镜像,`displayLine.side`
    /// 本来就在。
    @Published private(set) var nextLineSide: LyricDuet.Side?

    /// 「对齐方式」落到三个消费点上的**确定**方向(加「自动」后从直接读 `swiftUIAlignment`
    /// 改过来的):非自动三档原样;「自动」按声部 —— 主行按 `displayLine.side`,展开态「下一句」按
    /// `nextLineSide`,副行看它显示的是谁的内容(下一句跟下一句走,译文 / 罗马音是当前句的,跟主行走)。
    /// 三个消费点**必须**读这三个值、不许再直接读 `playback.lyricsAlignment.swiftUIAlignment`(selftest 源码
    /// 契约钉着):这个仓库为"同一个视觉属性漏改一条路径"付过代价,见 `LyricsRestingAlignment.swiftUIAlignment` 注释。
    var mainLyricAlignment: Alignment {
        lyricsAlignment.resolved(duetSide: displayLine?.side).swiftUIAlignment
    }
    var nextLineAlignment: Alignment {
        lyricsAlignment.resolved(duetSide: nextLineSide).swiftUIAlignment
    }
    var secondaryLyricAlignment: Alignment {
        secondaryLine == .nextLine ? nextLineAlignment : mainLyricAlignment
    }

    /// 「跳过广告」有没有对象:广告中,**且**这条广告是 YT Music 网页广告(探针强信号判定,
    /// 见 `YouTubeMusicAdSkipper.isYouTubeMusicAd`)。计算属性、不另发布:`isCurrentTrackAdBreak` 翻成 true
    /// 的那一拍正是探针把 `.ad` 写进缓存的那一拍(`LocalPlaybackSource.apply()` 读的是同一份缓存),视图
    /// 因 `isCurrentTrackAdBreak` 重估时读到的就是它;广告期间那份缓存每 5 秒被刷一次。Spotify 广告
    /// (原生 / 网页)的 YT 判定恒 nil,键不出现。
    var canSkipAd: Bool {
        isCurrentTrackAdBreak && YouTubeMusicAdSkipper.isYouTubeMusicAd(artist: artist, title: title)
            && adSkipAvailable
    }

    /// 页面上那颗「跳过」键此刻放出来没有。镜像 `YouTubeMusicAdSkipCenter.adSkipAvailable` —— 门槛轮询在那边,
    /// App 里只有一份,每块屏的灵动岛读同一个结果。必须是 `@Published`:倒计时过完、键刚放出来的那一刻,
    /// 广告态这一格没有任何别的东西在变,计算属性不会被重估,键就一直不出现。
    @Published private(set) var adSkipAvailable = false
    /// 一次跳过正在跑,镜像 `YouTubeMusicAdSkipCenter.skipInFlight`(手动与自动跳过共用那一把)。
    @Published private(set) var skipAdInFlight = false

    /// 这扇灵动岛在广告态时向 `YouTubeMusicAdSkipCenter` 登记要门槛结果,离开广告态撤销。
    ///
    /// **由 `NotchLyricsView` 按 `controller.isAdBreakNow` 驱动、只有真窗口登记(`drivesAdSkipGate`),不挂在
    /// `$isCurrentTrackAdBreak` 订阅上**。`NotchPlayback` 在编辑台预览里照样订阅真的 `PlaybackCoordinator`,挂在订阅上
    /// 的话,设置页只要开着,那块编辑台预览就会替轮询登记需求、跟着真广告对用户的浏览器发 AppleScript。
    func syncAdSkipGate(adBreak: Bool) {
        YouTubeMusicAdSkipCenter.shared.setNotchDemand(adSkipDemandID, active: adBreak)
    }

    /// 向门槛轮询登记需求用的 id。不用 `ObjectIdentifier(self)`:deinit 里的注销是异步排队的,那之前新建的实例可能复用同一个地址,
    /// 注销会把新实例的需求一起撤掉。
    private let adSkipDemandID = UUID()

    /// 去按 YT Music 页面自己的「跳过广告」键。每种结果的横幅见 `YouTubeMusicAdSkipCenter.reportManualOutcome`;
    /// 同一时刻只跑一份由那边的 `skipInFlight` 管。
    /// 不套 `controlButton` 那层 Apple Music 自动化权限守卫:这是浏览器自动化,权限在 `BrowserAutomationPermission`
    /// 那一套里,没权限时 osascript 直接失败、走「没能跳过」那句。
    func skipAd() {
        YouTubeMusicAdSkipCenter.shared.skip(trigger: .manual)
    }

    /// 封面换了:后台缩图取色(要把整张图解一遍),回到主线程只认最后一次换图的结果。
    private func refreshVividAccent(_ image: NSImage?) {
        vividGeneration &+= 1
        let generation = vividGeneration
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            if vividAccent != nil { vividAccent = nil }
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let rgb = ArtworkVividColor.color(image: cgImage)
            await self?.applyVividAccent(rgb, generation: generation)
        }
    }

    private func applyVividAccent(_ rgb: (r: Double, g: Double, b: Double)?, generation: Int) {
        guard generation == vividGeneration else { return }
        let next = rgb.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b) }
        if vividAccent != next { vividAccent = next }
    }

    deinit {
        let id = adSkipDemandID
        Task { @MainActor in YouTubeMusicAdSkipCenter.shared.setNotchDemand(id, active: false) }
    }

    /// 展开区时间行中间要不要显示「歌词时间轴微调」。同上走这里现读——只影响
    /// `NotchScrubber` 内部时间行怎么排,不影响卡片高度,理由见
    /// `AppSettings.notchExpandedShowsLyricsOffset` 的注释。
    @Published private(set) var showsLyricsOffsetControls: Bool = false
    /// 这首歌的歌词时间轴校正值(毫秒)+ 每次点击的步长——菜单栏面板那颗微调控件读的是
    /// 同一对值(`PlaybackCoordinator.trackLyricsOffsetMs`/`AppSettings.lyricsOffsetStepMs`),
    /// 这里镜像一份是因为 `NotchScrubber` 是 `private struct`、靠参数传值(不直接订阅
    /// PlaybackCoordinator/AppSettings),得有人先把值取到手。
    @Published private(set) var trackLyricsOffsetMs: Int = 0
    @Published private(set) var lyricsOffsetStepMs: Int = 200
    /// 实际生效的歌词时间轴**总**偏移(单曲 + 全局基准 + MV / LRC 自带,`PlaybackCoordinator.currentLyricsOffsetMs`)。
    /// 只订单曲那一项的话,改全局基准或 MV 偏移时逐字填色和音浪都不重排,要等换行才对上。
    @Published private(set) var lyricsOffsetMs: Int = 0
    /// 展开区随机 / 循环两颗键读的播放模式。只在这个播放器此刻随机、循环都能切(`PlaybackCoordinator.playbackModeOptions`)
    /// 时非 nil,只能切一样的(比如不允许改循环的 Spotify)和别的播放器一律 nil,两颗键据此整个不画。
    @Published private(set) var fullPlaybackMode: MusicPlaybackController.MusicPlaybackMode?
    /// 循环键走不走「单曲循环」那一档(Spotify 没有,两态)。
    @Published private(set) var playbackModeAllowsRepeatOne = false
    /// 循环键走不走「列表循环」那一档(QQ 音乐没有,两态:关 ↔ 单曲循环)。
    @Published private(set) var playbackModeAllowsRepeatAll = false
    /// 头部快捷操作那颗「喜欢」读的状态(`PlaybackCoordinator.isFavorited`);nil = 这个播放器没有「喜欢」,那颗键不画。
    @Published private(set) var isFavorited: Bool?
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        // 主行 / 副行认的当前句:够格的间奏里当作没有(`LyricSecondaryLine.currentLine(_:inMarkedInterlude:)`)。
        // 均衡器条子的 `currentLine` 不走这里。
        let shownCurrentLine = p.$notchLyrics.map(\.line)
            .combineLatest(p.$rawGapWindow.combineLatest(p.$lyricsGapMarkers)
                .map { raw, markers in raw?.isMarked(in: markers) ?? false })
            .map { LyricSecondaryLine.currentLine($0, inMarkedInterlude: $1) }
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$displayTitle.removeDuplicates().sink { [weak self] in self?.displayTitle = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$displayArtist.removeDuplicates().sink { [weak self] in self?.displayArtist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$displayAlbum.removeDuplicates().sink { [weak self] in self?.displayAlbum = $0 },
            p.$youtubeMusicAlbum.removeDuplicates().sink { [weak self] in self?.youtubeMusicAlbum = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$playbackControlsWithheldReason.removeDuplicates().sink { [weak self] in self?.controlsWithheldReason = $0 },
            // 当前句、要显示的那一句、下一句都取灵动岛自己那一份(按这一面的宽度断句,见
            // LocalPlaybackSource.notchLyrics),别混用逐行的 currentLine / compactLine / nextLine*。
            p.$notchLyrics.map(\.line).removeDuplicates().sink { [weak self] in self?.currentLine = $0 },
            // 主行画哪一句(见 displayLine 的注释):副行关着取 compactLine(唱完就切),副行开着取
            // currentLine(跟悬浮歌词同一套语义)。「卡拉OK效果」关着时再把**要画的那一行**压成整行
            // (`SyncedLyricLine.lineLevel`):歌词行的逐字填色按 `displayLine?.words` 走,
            // 压成整行之后自然落到 `.plain` 那一档,渲染分支不用改。`currentLine` **不**压 —— 它只给
            // 均衡器条子当"此刻在唱哪个字"的节拍,那是跟着人声动的律动、不是染色,关掉卡拉OK填色不该
            // 让条子一起哑掉。
            Publishers.CombineLatest4(p.$notchLyrics.map(\.compactLine), shownCurrentLine,
                                      s.$notchLyricsKaraoke, s.$notchSecondaryLine)
                .map { compact, current, karaoke, secondary -> SyncedLyricLine? in
                    // 挑哪一句在 Core(`LyricSecondaryLine.displayedLine`),菜单栏读的是同一份。
                    let line = secondary.displayedLine(compactLine: compact, currentLine: current)
                    return karaoke ? line : line?.lineLevel
                }
                .removeDuplicates()
                .sink { [weak self] in self?.displayLine = $0 },
            // 副行文本:按四选一取下一句 / 当前句译文 / 当前句罗马音,空白算没有。
            Publishers.CombineLatest3(shownCurrentLine, p.$notchLyrics.map(\.nextText), s.$notchSecondaryLine)
                .map { current, next, secondary -> String? in
                    // 取值规则在 Core(`LyricSecondaryLine.secondaryText`),菜单栏副行读的是同一份。
                    secondary.secondaryText(currentLine: current, nextLineText: next)
                }
                .removeDuplicates()
                .sink { [weak self] in self?.secondaryText = $0 },
            s.$notchSecondaryLine.removeDuplicates().sink { [weak self] in self?.secondaryLine = $0 },
            // 展开区「下一句」预览:接主行显示的那一句往后数(`LyricSecondaryLine.expandedNextLine`)。
            Publishers.CombineLatest(p.$notchLyrics, s.$notchSecondaryLine)
                .map { lyrics, secondary in secondary.expandedNextLine(next: lyrics.nextText, afterCompact: lyrics.compactNextText) }
                .removeDuplicates()
                .sink { [weak self] in self?.nextLineText = $0 },
            Publishers.CombineLatest(p.$notchLyrics, s.$notchSecondaryLine)
                .map { lyrics, secondary in secondary.expandedNextLine(next: lyrics.nextSide, afterCompact: lyrics.compactNextSide) }
                .removeDuplicates()
                .sink { [weak self] in self?.nextLineSide = $0 },
            Publishers.CombineLatest(p.$playbackMode, p.$playbackModeOptions)
                .map { mode, options in options.contains(.shuffle) && options.canRepeat ? mode : nil }
                .removeDuplicates()
                .sink { [weak self] in self?.fullPlaybackMode = $0 },
            p.$playbackModeOptions.map { $0.contains(.repeatOne) }.removeDuplicates()
                .sink { [weak self] in self?.playbackModeAllowsRepeatOne = $0 },
            p.$playbackModeOptions.map { $0.contains(.repeatAll) }.removeDuplicates()
                .sink { [weak self] in self?.playbackModeAllowsRepeatAll = $0 },
            p.$isFavorited.removeDuplicates().sink { [weak self] in self?.isFavorited = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$currentTrackPlainLyrics.map { !$0.isEmpty }.removeDuplicates()
                .sink { [weak self] in self?.hasPlainLyrics = $0 },
            p.$engineNetworkDown.removeDuplicates().sink { [weak self] in self?.engineNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            YouTubeMusicAdSkipCenter.shared.$adSkipAvailable.removeDuplicates().sink { [weak self] in self?.adSkipAvailable = $0 },
            YouTubeMusicAdSkipCenter.shared.$skipInFlight.removeDuplicates().sink { [weak self] in self?.skipAdInFlight = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$radioStationName.removeDuplicates().sink { [weak self] in self?.radioStationName = $0 },
            p.$radioStationImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.radioStationImage = $0 },
            p.$rawGapWindow.removeDuplicates()
                .sink { [weak self] in self?.rawGapWindow = $0 },
            p.$notchLyrics.map(\.compactPlaceholder).removeDuplicates()
                .sink { [weak self] in self?.compactShowsPlaceholder = $0 },
            p.$currentAdSlot.removeDuplicates().sink { [weak self] in self?.currentAdSlot = $0 },
            p.$adCountdown.removeDuplicates().sink { [weak self] in self?.adCountdown = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$blurredArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.blurredArtworkImage = $0 },
            p.$notchBackdropTone.map { $0?.overlayOpacity ?? LocalPlaybackSource.notchCoverArtOverlayOpacity }
                .removeDuplicates()
                .sink { [weak self] in self?.backdropOverlayOpacity = $0 },
            // 锚点本身低频(见类型注释),不去重(ProgressAnchor 非 Equatable,每次重锚
            // 也确实都是新值)。
            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },
            // 第二个输入是灵动岛自己的 `notchCardStyle`,不是悬浮歌词那边的 `followsCoverArt`,理由见 accent 的注释。
            Publishers.CombineLatest(p.$notchAccentColor, s.$notchCardStyle)
                .map { accent, style in style == .coverArt ? (accent ?? .white) : .white }
                .removeDuplicates()
                .sink { [weak self] in self?.accent = $0 },
            s.$notchCardStyle.removeDuplicates().sink { [weak self] in self?.notchCardStyle = $0 },
            s.$notchLeftEar.removeDuplicates().sink { [weak self] in self?.leftEar = $0 },
            s.$notchRightEar.removeDuplicates().sink { [weak self] in self?.rightEar = $0 },
            Publishers.CombineLatest(p.$highResArtworkImage, p.$artworkImage)
                .map { highRes, system in highRes ?? system }
                .removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.refreshVividAccent($0) },
            s.$notchLyricRowShowsArtwork.removeDuplicates().sink { [weak self] in self?.lyricRowShowsArtwork = $0 },
            s.$notchLyricRowArtworkPosition.removeDuplicates().sink { [weak self] in self?.lyricRowArtworkPosition = $0 },
            s.$notchLyricsAlignment.removeDuplicates().sink { [weak self] in self?.lyricsAlignment = $0 },
            // 字体三件:派生 Font 不是 Equatable,不去重 —— 上游只在三个输入之一真变时才重算,本来就低频。
            s.$notchMainFont.sink { [weak self] in self?.mainFont = $0 },
            s.$notchMainDetailFont.sink { [weak self] in self?.mainDetailFont = $0 },
            s.$notchSecondaryFont.sink { [weak self] in self?.secondaryFont = $0 },
            s.$notchMainNSFont.sink { [weak self] in self?.mainNSFont = $0 },
            s.$notchFontSize.removeDuplicates()
                .map { NotchLyricRowMetrics.mainLineHeight(fontSize: CGFloat($0)) }
                .removeDuplicates()
                .sink { [weak self] in self?.mainLineHeight = $0 },
            s.$notchFontSize.removeDuplicates()
                .map { NotchLyricRowMetrics.clampedMainFontSize(CGFloat($0)) }
                .removeDuplicates()
                .sink { [weak self] in self?.mainFontSize = $0 },
            s.$notchExpandedShowsLyricsOffset.removeDuplicates().sink { [weak self] in self?.showsLyricsOffsetControls = $0 },
            p.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.trackLyricsOffsetMs = $0 },
            p.$currentLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.lyricsOffsetMs = $0 },
            s.$lyricsOffsetStepMs.removeDuplicates().sink { [weak self] in self?.lyricsOffsetStepMs = $0 },
        ]
    }
}
