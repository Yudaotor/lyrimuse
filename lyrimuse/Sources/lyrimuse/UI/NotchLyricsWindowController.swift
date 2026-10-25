import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

// 灵动岛/刘海样式悬浮歌词的窗口控制器——跟 LyricsOverlayWindowController 平行、完全
// 独立的第二套实现(两种形态各自独立的窗口控制器,可以同时开;不去改造经典那一套让它同时
// 兼容两种形态,那样的改造复杂度和风险都更高)。跟经典悬浮窗的行为差异:
// 1) 位置是算出来的、贴死在屏幕顶部居中,不支持用户拖拽(见 NotchLyricsWindow 里
//    isMovableByWindowBackground = false),所以没有"锁定位置"这个概念,也不需要
//    像经典悬浮窗那样持久化位置。
// 2) 暂停 / 广告时可以收起(见 isCollapsed):只留顶行那一条;播放中常显顶行 + 当前歌词,
//    不需要 hover 才能看到——歌词类信息本来就该随时可见。hover 时在下面多展开一块补充信息
//    (见 expandedExtraHeight)。
//
// 极其重要的一条不变量,贯穿 AppDelegate / SettingsView / 菜单栏这些外部调用点:这个类是
// `static let shared`,真正引用到 `.shared` 才会执行 init() 建窗口(含鼠标监听器和一堆 Combine 订阅)。
// 灵动岛没开的时候,任何代码引用了 `NotchLyricsWindowController.shared`(哪怕只是读一下属性)都会把这扇
// 窗凭空建出来。外部调用点因此都必须先过 `settings.notchOverlayEnabled`,不能像"同时持有两个控制器的
// @ObservedObject"这种最直白的写法那样两个都摸一遍。
//
// 歌词文字这一行让到物理刘海下方那一条,刘海本身所在的高度只留纯黑背景——物理刘海是
// 屏幕硬件层面真实不发光的区域,不是"渲染层级"问题,任何 App 都不可能把内容"显示"在
// 那个区域本身。
//
// isCollapsed(收起到顶行那一条,歌词行不渲染)跟 hideWhenNotPlaying(整个窗口
// 隐藏)是两个独立机制,不冲突:后者关闭时窗口本身还在(用户能看到"这里有个东西"),
// hover 到收起的卡片上依然能重新展开出完整内容(包括播放按钮,可以用来重新播放)。见 isCollapsed。
@MainActor
// 遵循 NotchChromeSource:设置页的预览拿一个轻量替身(NotchPreviewChrome)装同一份 NotchLyricsView。
final class NotchLyricsWindowController: NSWindowController, ObservableObject, NotchChromeSource {
    static let shared = NotchLyricsWindowController(pinnedScreenID: nil)

    // 真值在 AppSettings.notchOverlayEnabled,这里只是它的镜像(菜单栏要观察这个
    // @Published)。只能经 setVisible(_:) 改,那是打开/关闭的唯一入口。
    @Published private(set) var isVisible: Bool = AppSettings.shared.notchOverlayEnabled
    // 初值直接读设置(同 isVisible):写死 false 的话,冷启动 / 插屏建副本时 init 里的播放订阅先按「不隐藏」
    // 把卡片摆出来,等真实设置补上又缩回去,开着「暂停时隐藏」、此刻没在放的人会看到卡片闪一下。
    @Published private(set) var hideWhenNotPlaying: Bool = AppSettings.shared.notchHideWhenNotPlaying
    /// 窗口此刻是否真的看得见(`occlusionState` 含 `.visible`)。关掉灵动岛 / 暂停时隐藏(orderOut)、
    /// 锁屏、屏保、熄屏都是 false。灵动岛所有按时间推进的表都按它停(经环境值 `notchCardLayerActive`),
    /// SwiftUI 不会因为窗口看不见就自己停 `TimelineView(.animation)`。默认 true:宁可多跑也不能把看得见的窗口停表。
    @Published private(set) var isSurfaceVisible = true
    // 常显内容行(歌词)相对窗口顶部的偏移——正好等于刘海(或无刘海屏幕的兜底高度)
    // 本身的高度,这样歌词永远从刘海往下才开始画,不会被刘海真实挡住一部分。
    // NotchLyricsView 读这个属性给歌词行加 .padding(.top, contentTopInset)。
    @Published private(set) var contentTopInset: CGFloat = 32
    // 刘海本身的真实宽度(无真刘海时为 0)——播放控制按钮要挪到刘海两侧("耳朵")那
    // 两条空间里,不能摆在刘海本身的 x 范围内:物理刘海是屏幕硬件层面真实不发光的
    // 区域,横向也会跟纵向一样把落在这个范围内的内容整个挡掉。NotchLyricsView 读这个
    // 属性把顶部这一行让出中间 notchWidth 宽度的空当,按钮只放在左右两侧。
    @Published private(set) var notchWidth: CGFloat = 0
    // 卡片是否展开:hover(经 NotchWindowRoot 的精确命中判定,见 setExpandedFromWindow)、「发现新播放器」
    // 提醒、收听里程碑任一成立就展开,唯一写入点是 refreshExpanded。决定 NotchLyricsView 要不要渲染下面那块
    // 补充内容;稳态(false)本身已经是完整可用的一套,这个状态不影响稳态内容本身是否显示。
    @Published private(set) var isExpanded: Bool = false
    /// 此刻在报的收听里程碑(`ListenMilestoneCenter.current` 的镜像,见 setMilestone);nil = 没有。
    @Published private(set) var milestone: ListenMilestone?
    /// 换歌翻牌:此刻从刘海里掉出来的那条歌名(见 applyReveal);nil = 没有。
    @Published private(set) var trackDrop: NotchTrackDrop?
    /// 换歌翻牌:最近一次揭晓的曲目(`NotchTrackDropRules.key`,见 applyReveal)。耳朵里的封面换歌后等揭晓了同一首才翻。
    @Published private(set) var revealedTrackKey: String?
    /// 此刻有没有瞬态横幅(`NotchTransientCenter.banner` 的镜像)。关着歌词行时卡片为它多长一截(`showsBannerStrip`)。
    @Published private(set) var transientBannerActive = false
    /// 要不要画底边那根进度线,真值在 `AppSettings.notchShowsProgressLine`,镜像理由同 `showsEqualizer`。
    @Published private(set) var showsProgressLine: Bool = AppSettings.shared.notchShowsProgressLine
    /// `isExpanded` 的两个输入(拆开):hover 那一路的兑现结果,和「发现新播放器」主动提醒的
    /// 撑开(`NotchUnknownPlayerPrompt.isAlerting` 的镜像)。任一为 true 卡片就是展开的,见 refreshExpanded ——
    /// 提醒期间光标进出卡片改的是 hoverExpanded,不会把提醒撑开的卡片提前收掉;提醒到点时光标还停在上面,
    /// 卡片也不会从光标底下塌回去。alertHold 同时进 updateActualVisibility 的判据:开着「暂停/无播放时隐藏」
    /// 的机器上,提醒发生的那一刻窗口本来是隐藏的(没有曲目),得把它叫回来、到点再照常隐藏。
    private var hoverExpanded = false
    private var alertHold = false
    /// 收听里程碑报喜时撑开,跟 alertHold 一样只是 isExpanded 的一个输入。不进 updateActualVisibility:
    /// 灵动岛这会儿藏着(全屏、暂停隐藏)就看不到,不为它把窗口叫回来。
    private var milestoneHold = false
    /// 「临时展开灵动岛」快捷键撑开的那几秒(`NotchPeekCenter.isPeeking` 的镜像),跟 milestoneHold 一样只是 isExpanded 的一个输入,
    /// 不进 updateActualVisibility:藏着的灵动岛不为它叫回来。
    private var peekHold = false
    /// 卡片上这一次滚动手势认到哪了(`handleScrollWheel`)。
    private var scrollGesture = NotchScrollGesture()
    /// 报喜结束时指针还停在卡片上:等它离开再收面板(refreshExpanded)。
    private var milestoneClearPending = false
    /// 「全屏时隐藏」(`NotchVisibility.fullScreenHides`)的结论,由 `applyFullScreenCover` 写入,进
    /// updateActualVisibility 的判据。主实例和镜像副本各看自己那块屏,别的屏全屏不算。
    private var coveredByFullScreen = false
    /// 「纯音乐/无歌词时收起歌词行」开着、这首没有歌词(`NoLyricsAutoHide.hides`),由 init 里 `$notchCollapseLyricsWhenNoLyrics` 那条订阅写入,
    /// 跟 `showsLyricsSetting` 一起算出 `showsLyrics`。每个实例(含镜像副本)各自订阅。
    private var lyricsCollapsedForNoLyrics = false
    /// 当前有没有在播放。由 init 里 `$isPlayingSmoothed` 那条订阅写入,值取 sink 的**参数**——不能回头去读
    /// PlaybackCoordinator 的存储属性,@Published 在 willSet 时机发布,那一刻读到的还是
    /// 旧值(见 init 里那条订阅处的注释)。
    ///
    /// 单独存一份而不是每次现读,是为了让下面的 isCollapsed 能写成计算属性。
    @Published private(set) var isPlayingNow: Bool = false

    // 收起态:卡片只留顶行那一条高度,宽度收到两只耳朵(算法在 NotchChromeSource.cardWidth 的收起分支),
    // 歌词行与展开区不渲染;hover 照样能展开出完整内容(含播放键)。
    // 开关各自的作用:collapsesWhenPaused 关掉暂停时就不收;hideWhenNotPlaying 开着时暂停直接缩进刘海
    // (isVanished)、不经过收起态;广告插播(isAdBreakNow)看 collapsesDuringAds。
    //
    // 必须是计算属性:hover 改 isExpanded 的那条路径(setExpandedFromWindow)不调 recomputeGeometry,
    // 存成存储属性的话暂停时 hover 不会展开。
    var isCollapsed: Bool {
        ((collapsesWhenPaused && !isPlayingNow && (!hideWhenNotPlaying || vanishesFromCollapsed))
            || (collapsesDuringAds && isAdBreakNow)) && !isExpanded
    }

    /// 这一次缩进刘海是从收起态开始的:暂停着、已经收起时才打开「暂停时隐藏」。收起判据里 `!hideWhenNotPlaying` 那一项
    /// 一翻,卡片会先按弹簧撑回正常大小、同时又缩进刘海;这时照旧算收起,从收起的样子直接缩进去。重新露面时清掉。
    @Published private(set) var vanishesFromCollapsed = false

    /// 「暂停/无播放时隐藏」的退场态:true 时 NotchWindowRoot 把整卡缩到刘海里
    /// (scale→0 + 透明),动画走完再 orderOut;恢复播放时先 orderFront 再翻回 false,卡片从
    /// 刘海里弹出来。窗口隐藏期间保持 true,这样下次露面一定是从无到有,而不是先满幅一帧。
    @Published private(set) var isVanished = false

    /// 出场动画的触发计数:每次卡片「从无到有」露面 —— 窗口刚 orderFront(冷启动、手动打开
    /// 灵动岛)或从 isVanished 回场 —— 加一,`NotchWindowRoot` 的 keyframeAnimator 以它为 trigger 播一遍
    /// 「从刘海撑开」(细节见 NotchReveal / NotchRevealShape 头注)。两件事同时发生只加一次。收起 → 稳态那条
    /// 弹簧不走这里:那是尺寸变化,不是出场。
    @Published private(set) var revealGeneration = 0

    /// Spotify 广告插播中。写入规则与 isPlayingNow 相同:只取 sink 参数值。
    @Published private(set) var isAdBreakNow: Bool = false

    /// 暂停时要不要收缩,真值在 `AppSettings.notchCollapsesWhenPaused`(见那边的注释)。
    /// 镜像到这里是同一条性能审计纪律:`NotchWindowRoot` 只观察这个控制器、
    /// 不观察 AppSettings,别为了一个开关把整卡挂回去观察全部设置。
    @Published private(set) var collapsesWhenPaused: Bool = AppSettings.shared.notchCollapsesWhenPaused
    /// 广告时要不要收缩(「广告时收起」),真值在 `AppSettings.notchCollapsesDuringAds`,镜像理由同上。
    @Published private(set) var collapsesDuringAds: Bool = AppSettings.shared.notchCollapsesDuringAds

    /// 要不要显示播放指示条(音浪),真值在 `AppSettings.notchShowsEqualizer`。镜像到这里
    /// 是同一条性能审计纪律:`NotchWindowRoot` 只观察这个控制器、不观察
    /// AppSettings。
    @Published private(set) var showsEqualizer: Bool = AppSettings.shared.notchShowsEqualizer
    /// 音浪贴哪只耳朵的外缘,真值在 `AppSettings.notchEqualizerEar`。同上。
    @Published private(set) var equalizerEar: NotchEqualizerEar = AppSettings.shared.notchEqualizerEar

    /// 展开区要不要给"下一句歌词预览"留高度(= 这首歌有没有歌词)。写入规则同
    /// isPlayingNow:只取 sink 参数值,绝不回头读 PlaybackCoordinator 的存储属性。
    @Published private(set) var expandedShowsLyricPreview: Bool = false
    /// 用户要不要看歌词行,真值在 `AppSettings.notchShowLyrics`(见那边的注释)。
    /// 镜像到这里是因为 `NotchWindowRoot` 只观察这个控制器、不观察 AppSettings ——
    /// 那是性能审计定的纪律,别为了这一个开关把整卡挂回去观察全部设置。
    /// `showsLyrics` 是卡片读的生效值(`NotchVisibility.showsLyrics`,叠上了无歌词收起),`showsLyricsSetting`
    /// 是开关本身(快捷操作那颗键的文案读它)。
    @Published private(set) var showsLyrics: Bool = AppSettings.shared.notchShowLyrics
    @Published private(set) var showsLyricsSetting: Bool = AppSettings.shared.notchShowLyrics
    /// 展开区要不要给迷你进度条留高度(= 这首歌有没有时长)。同上。
    @Published private(set) var expandedShowsScrubber: Bool = false

    /// 用户要不要看展开区那行「下一句歌词预览」,真值在 `AppSettings.notchExpandedShowsNextLine`。
    /// 跟 `expandedShowsLyricPreview`(曲目级数据信号)是两个不同来源、两个不同属性,两者
    /// 都成立才画,见 `NotchChromeSource.showsExpandedLyricPreview`。镜像到这里的理由同
    /// showsLyrics:`NotchWindowRoot` 只观察这个控制器、不观察 AppSettings。
    @Published private(set) var expandedShowsNextLine: Bool = LyricSecondaryLine.expandedNextLinePreviewVisible(
        userToggle: AppSettings.shared.notchExpandedShowsNextLine, secondary: AppSettings.shared.notchSecondaryLine)
    /// 用户要不要看展开区那排播放控制键,真值在 `AppSettings.notchExpandedShowsControls`。
    /// 跟上面 `expandedShowsNextLine` 同一个理由镜像——它是纯用户设置、不看曲目级数据,
    /// 跟 `expandedShowsScrubber`(曲目级信号)性质不一样,但镜像+重算几何这条链路是
    /// 完全一样的模式。
    @Published private(set) var expandedShowsControls: Bool = AppSettings.shared.notchExpandedShowsControls
    /// 展开区「曲目信息头部」四个独立开关(封面/歌名/歌手/专辑),真值分别在 `AppSettings`
    /// 的四个 `notchExpandedShows*`。同上镜像——封面这枚**要**镜像,跟 `lyricRowShowsArtwork`
    /// 那枚(歌词行末尾的,不影响高度)不一样:这枚固定贴文字块左边、按 `max(封面, 文字)`
    /// 参与头部高度算术,所以必须走这条"镜像+重算几何"的链路,不能交给 `NotchPlayback`
    /// 现读了事(那条链只适合纯渲染、不影响几何的设置)。
    @Published private(set) var expandedTrackInfoShowsArtwork: Bool = AppSettings.shared.notchExpandedShowsArtwork
    @Published private(set) var expandedTrackInfoShowsTitle: Bool = AppSettings.shared.notchExpandedShowsTrackTitle
    @Published private(set) var expandedTrackInfoShowsArtist: Bool = AppSettings.shared.notchExpandedShowsArtist
    @Published private(set) var expandedTrackInfoShowsAlbum: Bool = AppSettings.shared.notchExpandedShowsAlbum
    /// 头部右侧那排「快捷操作」,真值在 `AppSettings.notchExpandedShowsQuickActions`。
    /// 跟头部四项同一条链路:参与头部高度(`max` 的第三块),四项全关时它一个人撑起 22pt。
    @Published private(set) var expandedShowsQuickActions: Bool = AppSettings.shared.notchExpandedShowsQuickActions
    /// 展开时多行歌词那一格的高度(关着「多行歌词」为 0),由三项设置合成(`AppSettings.notchExpandedLyricListHeight`)。
    /// 窗口高度跟着它:订阅里先写镜像、再重算几何,`recomputeGeometry` 读镜像(同 `lyricRowHeight`)。
    @Published private(set) var expandedLyricListHeight: CGFloat = AppSettings.shared.notchExpandedLyricListHeight

    /// 此刻有没有一首曲目 —— 决定歌词行整行占不占高度(见协议 NotchChromeSource.hasTrack)。
    /// 由 CombineLatest3 一次给全三个值,不存在"回头读存储属性拿到旧值"那个坑。
    @Published private(set) var hasTrack: Bool = false

    /// 有没有曲目的判据:歌名、歌手有一个不空,或正在放广告。设置页编辑台的预览(`NotchPreviewChrome`)用同一个。
    static func trackPresent(title: String, artist: String, isAdBreak: Bool) -> Bool {
        !title.isEmpty || !artist.isEmpty || isAdBreak
    }

    /// 稳态卡片的宽度(= contentWidth(baseWidth:notchWidth:) 的结果)。展开态另有 `expandedCardWidth`。
    @Published private(set) var steadyCardWidth: CGFloat = 360
    /// hover 展开态卡片的宽度 = `max(稳态真实宽, notchExpandedContentWidth)`(`NotchWidthBounds`)。
    /// **窗口本身常驻这个宽度**(最大形态),卡片在里面按形态变宽变窄,见 NotchWindowRoot。
    /// 稳态宽是下限,这个是上限。
    @Published private(set) var expandedCardWidth: CGFloat = 360

    // 没有真刘海的屏幕(外接显示器、不带刘海的机型)退到一套不依赖真刘海几何形状的兜底样式,
    // 宽度沿用下面 contentWidth 算出来的常显宽度。
    //
    // 无刘海屏幕上"假刘海"的兜底高度下限。真正用的值是那块屏**当前的菜单栏高度**
    // (见 menuBarHeight(of:)) —— 写死一个数字在外接屏上必然对不齐:菜单栏高度随屏幕
    // 缩放/分辨率变化(内建屏实测 33pt,外接屏常见 24~37pt 不等),黑条比菜单栏矮
    // 会露出一条桌面、比它高会压住窗口内容。这个常量只在菜单栏被自动隐藏(顶部差为 0)
    // 时兜底。
    private static let fallbackNotchHeight: CGFloat = 24

    /// 这块屏当前的菜单栏高度。
    ///
    /// 只能看**顶边差**,不能用 frame.height - visibleFrame.height —— 后者把 Dock
    /// 也算进去了(内建屏实测算出 109pt,而菜单栏只有 33pt)。
    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        max(fallbackNotchHeight, screen.frame.maxY - screen.visibleFrame.maxY)
    }
    /// 歌词行的实际高度(`AppSettings.notchEffectiveLyricRowHeight`)。窗口总高度 = 刘海高(或兜底高度)+ 它 + 展开区上限,
    /// 视图那边按同一个值排版。由 init 里歌词行高度那条订阅用 sink 参数值算好写进来(@Published 是 willSet 时机,
    /// 回读 AppSettings 拿到的是旧值),再重算几何。
    @Published private(set) var lyricRowHeight: CGFloat = AppSettings.shared.notchEffectiveLyricRowHeight
    // 宽度是固定值,不随当前歌词文字宽度动态变化。默认值和用户可调的设置项都在 AppSettings.notchContentWidth
    // (这里不重复放一份、避免两处数字不同步)。超长歌词交给 NotchLyricsView 的跑马灯滚动展示,
    // 不靠加宽窗口解决。
    /// 顶行一只"耳朵"的最低可用宽度。算卡片宽度下限时要把**两只**耳朵 + 刘海本身宽度 +
    /// 左右 padding 都算进去(见 `contentWidth`)。
    ///
    /// **两只耳朵恒等宽** —— `earWidth = (卡片宽 − 刘海宽 − 2×cardHorizontalPadding) / 2`
    /// (见 `NotchLyricsView.body`),所以这里取两边需求的**较大者**,而不是各算各的。
    ///
    /// 按两只耳朵实际选的模块算,别退回一个按"放得下三个播放键"定的常量 —— 那样两只耳朵都配成「不显示」
    /// 时宽度滑杆的下界照样很宽,调不小。
    ///
    /// 改了这个函数就等于改了滑杆的下界,而下界一变,**必须有人在它的任一入参变化时重算
    /// 几何**。承担这件事的是 init 里那**四条**订阅:`$notchLeftEar` / `$notchRightEar` /
    /// `$notchShowsEqualizer` / `$notchEqualizerEar`。**以后再往这个函数加一个入参,就得同时加第五条订阅** ——
    /// 漏了的表现不是崩,是"改完设置卡片宽度纹丝不动,直到下次拖宽度滑杆才追上",很难往
    /// 订阅上想。四条都把 sink 的**参数值**显式传给 `recomputeGeometry`,不让下游回读
    /// `AppSettings`:@Published 是 willSet 时机派发,此刻回读拿到的是旧值。
    static func minEarWidth(leftEar: NotchEarModule, rightEar: NotchEarModule,
                            showsEqualizer: Bool, equalizerEar: NotchEqualizerEar,
                            contentTopInset: CGFloat) -> CGFloat {
        // 音浪贴哪只耳朵外缘是可配的,所以两只耳朵都要按
        // "自己是不是那一侧"单独判断要不要多留音浪的空间。它是播放指示灯、不是可配模块
        // (见 NotchEarModule 上方那段),唯一的例外是那只耳朵本身选了控制键——那时音浪
        // 让位(见 NotchLyricsView.topRow 里那条提醒)。
        func equalizerAllowance(forEar ear: NotchEqualizerEar, module: NotchEarModule) -> CGFloat {
            guard showsEqualizer, equalizerEar == ear, module != .controls else { return 0 }
            return EqualizerBars.width + NotchMetrics.earWaveSpacing
        }
        let left = leftEar.minEarContentWidth(contentTopInset: contentTopInset)
            + equalizerAllowance(forEar: .left, module: leftEar)
            + NotchMetrics.earNotchInset
        let right = rightEar.minEarContentWidth(contentTopInset: contentTopInset)
            + equalizerAllowance(forEar: .right, module: rightEar)
            + NotchMetrics.earNotchInset
        return max(left, right)
    }
    // hover 展开时在 contentSize 之外额外撑出的高度,放(可选的)曲目信息头部 + 下一句歌词预览 + 迷你进度条 +
    // 播放控制键这几样补充信息。歌词行末尾那枚封面不在这一块:它在歌词行里,不需要 hover 才出现,也不占额外高度。
    // 同上,单一来源在 NotchMetrics。
    // 窗口恒按**最大**形态开(卡片在里面自己变大变小,见 NotchWindowRoot)——所以这里
    // 用 Max,不用那个按内容算的函数。用后者会让"没歌词的歌"把窗口也缩掉,而窗口一缩,
    // 后面换到有歌词的歌时卡片就没地方长了(会被窗口边界硬裁)。
    ///
    /// 展开区高度的入参分两类:曲目级数据(`hasLyricPreview`/`hasScrubber`)和**用户设置**(下一句预览、
    /// 播放控制键、曲目信息头部四项、快捷操作),后者会主动触发重算(见 `NotchExpandedMetrics.maxHeight`
    /// 的注释)。这些入参跟 `minEarWidth` 那组同一个规矩:非 nil = 调用方正处于对应 `@Published` 的
    /// willSet 窗口,必须用传入值;nil = 回读存储值。**以后再往这个函数加一个入参,就得同时在 init 里加一条
    /// 对应订阅**,漏了的表现是"改完设置卡片高度纹丝不动,直到下次触发别的几何重算才追上"。
    ///
    /// 歌词行末尾那枚封面开关(`notchLyricRowShowsArtwork`)**不在入参里**——它只影响歌词行内部排列,
    /// 不影响这个函数算的高度。头部**自己**的封面开关(`expandedTrackInfoShowsArtwork`)则**在**入参里——
    /// 它固定贴文字块左边、按 `max(封面, 文字)` 参与头部高度,必须跟其它几项一样走"传值+重算几何"这条路。
    private func expandedExtraHeight(
        expandedShowsNextLine: Bool? = nil,
        expandedShowsControls: Bool? = nil,
        expandedTrackInfoShowsArtwork: Bool? = nil,
        expandedTrackInfoShowsTitle: Bool? = nil,
        expandedTrackInfoShowsArtist: Bool? = nil,
        expandedTrackInfoShowsAlbum: Bool? = nil,
        expandedShowsQuickActions: Bool? = nil
    ) -> CGFloat {
        let showsArtwork = expandedTrackInfoShowsArtwork ?? AppSettings.shared.notchExpandedShowsArtwork
        let showsTitle = expandedTrackInfoShowsTitle ?? AppSettings.shared.notchExpandedShowsTrackTitle
        let showsArtist = expandedTrackInfoShowsArtist ?? AppSettings.shared.notchExpandedShowsArtist
        let showsAlbum = expandedTrackInfoShowsAlbum ?? AppSettings.shared.notchExpandedShowsAlbum
        let showsActions = expandedShowsQuickActions ?? AppSettings.shared.notchExpandedShowsQuickActions
        let trackInfoHeight = NotchExpandedMetrics.trackInfoHeight(
            showsArtwork: showsArtwork, showsTitle: showsTitle, showsArtist: showsArtist, showsAlbum: showsAlbum,
            showsActions: showsActions)
        // 开着多行歌词时「下一句」预览不会出现(`NotchChromeSource.showsExpandedLyricPreview`),不留它那一截。
        return NotchExpandedMetrics.maxHeight(
            hasLyricPreviewPossible: (expandedShowsNextLine ?? LyricSecondaryLine.expandedNextLinePreviewVisible(
                userToggle: AppSettings.shared.notchExpandedShowsNextLine, secondary: AppSettings.shared.notchSecondaryLine))
                && expandedLyricListHeight == 0,
            hasControlsPossible: expandedShowsControls ?? AppSettings.shared.notchExpandedShowsControls,
            trackInfoHeight: trackInfoHeight)
    }

    /// init 里建的全部 Combine 订阅;`teardown` 一次清掉,新加订阅一律 `.store(in: &subscriptions)`,别再单独开字段。
    private var subscriptions = Set<AnyCancellable>()
    /// 掉不掉歌名的判定,记着上一首(`NotchTrackDropTracker`);刚建出来时还没判过,第一首不掉。
    private var trackDropTracker = NotchTrackDropTracker()
    private var trackDropGeneration = 0
    private var trackDropClearTask: Task<Void, Never>?
    /// 最近收掉的那条和收的时刻:收回刚开始时揭晓的新歌名要把它推出去(`NotchTrackDropRules.replaced`)。
    private var clearedTrackDrop: (drop: NotchTrackDrop, at: Date)?
    /// 歌名掉下来和耳朵里的封面翻过来对到同一拍(`NotchTrackRevealGate`)。
    private var revealGate = NotchTrackRevealGate()
    private var revealWaitTask: Task<Void, Never>?
    /// 判成要掉、正等着封面的那一首;揭晓时掉它。
    private var pendingDrop: (title: String, artist: String, since: Date)?
    /// 掉歌名的判定日志:换了一首、判成要掉时写一行(掉了,或卡片此刻不显示没掉)。
    private static let trackDropLog = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notch-track-drop")
    private var screenParamsObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    // recomputeGeometry 里要把 hostingView 的 frame 也显式设一遍,别只信 autoresizingMask:那条隐式路径下
    // AppKit 层的 frame 跟上了,NSHostingView 内部的 SwiftUI 布局树却不重新走一遍,新撑出来的区域什么都不画。
    private var hostingView: NSHostingView<NotchWindowRoot>?

    /// 只有"每块屏各一个"模式下的副本实例才会设(见 NotchMirrorManager),且只在 init
    /// 里设一次。主实例(`.shared`)恒为 nil,跟着 targetScreen() 走。
    ///
    /// 这个字段是主/副实例的**唯一**区别 —— 副本共用同一个类、同一份视图、同一套
    /// hover/播放订阅,只是钉在别的屏上。多加一个"这是副本"的布尔就会诱使后面的人写
    /// `if isMirror { ... }` 的分支,那正是两套行为慢慢分叉的起点。
    private var pinnedScreenID: String?
    /// 「按宽度断句」的歌词列宽度由这个实例报(只有主实例报,见 `NotchWindowRoot.body`)。
    var reportsLineLayoutWidth: Bool { pinnedScreenID == nil }

    /// pinnedScreenID **必须**在这里传进来,不能等构造完再赋值:init() 一开头就会
    /// recomputeGeometry() 一次、随后订阅播放状态(订阅那一瞬间就会触发一次
    /// updateActualVisibility → orderFront)。晚设一步的话,新建的副本会先按
    /// targetScreen() 在**主屏**上摆好并显示出来,然后才被挪到它该去的那块屏 ——
    /// 表现为主屏上闪一下重叠的第二个灵动岛。
    /// 这个参数**不能**给默认值。给了默认值之后 `NotchLyricsWindowController()` 这个
    /// 调用就有两个候选:这个 convenience init,和从 NSWindowController 继承来的
    /// `init()`。Swift 选后者 —— 于是 `.shared` 建出来的是一个**没有窗口、没跑过下面
    /// 任何一行**的空壳控制器,`updateActualVisibility()` 里的 `window?.orderFrontRegardless()`
    /// 对 nil 什么都不做,灵动岛就此彻底不出现,而且编译期、运行期都没有任何报错或日志。
    /// 所以主实例也显式传 nil(见 `shared` 的声明),不留 `()` 这种写法。
    convenience init(pinnedScreenID: String?) {
        // 初始 contentRect 只是占位——真正的尺寸/位置由下面 recomputeGeometry() 按
        // 当前屏幕几何重新算一遍并 setFrame,这里传什么都会被立刻覆盖掉。
        let placeholder = NSSize(width: AppSettings.shared.notchContentWidth,
                                 height: Self.fallbackNotchHeight + AppSettings.shared.notchEffectiveLyricRowHeight)
        let panel = NotchLyricsWindow(contentRect: NSRect(origin: .zero, size: placeholder))
        // 「截屏 / 录屏时隐藏」同理从一开始就按设置来,不然设置应用上之前那一小段录屏拍得到它。
        panel.sharingType = AppSettings.shared.notchHideDuringScreenCapture ? .none : .readWrite
        self.init(window: panel)
        self.pinnedScreenID = pinnedScreenID

        // 先算好几何(刘海尺寸、两档卡宽、窗口 frame)再建 hostingView:反过来 SwiftUI 先按声明默认值和占位窗口排一版,
        // 几何一到卡片就从那个位置沿 cardAnimation 弹过去,冷启动主线程一忙就冻在半路。见 05 章决策 64。
        recomputeGeometry(animate: false)

        let hosting = NSHostingView(rootView: NotchWindowRoot(controller: self))
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        // 尺寸完全由 recomputeGeometry 手动管理(窗口和 hostingView 的 frame 都是),
        // 默认 .standardBounds 的 intrinsic 尺寸汇报没有任何消费者,关掉(悬浮窗那边同样关着)。
        hosting.sizingOptions = []
        panel.contentView = hosting
        hostingView = hosting
        panel.onScrollWheel = { [weak self] event in self?.handleScrollWheel(event) }

        // 窗口还没 orderFront 时 occlusionState 也是「不可见」,所以初值保持 true;上屏后系统会补一次通知。
        // 主实例和镜像副本都要挂:每扇窗各管各的树。
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] note in
            guard let win = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                let visible = win.occlusionState.contains(.visible)
                if self?.isSurfaceVisible != visible {
                    self?.isSurfaceVisible = visible
                    Self.hoverLog.notice("surface visible=\(visible, privacy: .public)")
                    // 看不见了(锁屏、屏保、熄屏;灵动岛在屏保层,别的窗口挡不住它):控制器这份悬停也清掉,跟视图那份
                    // (NotchWindowRoot 里 isSurfaceVisible 的 onChange)配对。只清视图那份的话,解锁时指针已经移开,
                    // 之后的离开事件都不算边沿,卡片一直停在展开态。
                    if !visible { self?.resetHoverAfterHide() }
                }
            }
        }

        // 外接显示器插拔/切换分辨率时,"这台屏幕有没有真刘海"这个前提可能整个变了
        // (外接显示器基本不会有刘海)——重新算一遍。系统触发的几何变化不需要过渡动画,直接跳变。
        //
        // 只有主实例注册 —— 镜像副本的屏幕参数处理统一由 NotchMirrorManager 的同款
        // 通知驱动(refresh → syncStateFromSettings → recomputeGeometry),副本再注册
        // 一份就是同一次插拔跑两遍全量几何;副本被钉的屏拔掉时,
        // 它自己的 observer 也只会按 resolvedScreen()==nil 空转,真正的清理本来就在
        // manager 那侧。
        if pinnedScreenID == nil {
            screenParamsObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.recomputeGeometry(animate: false)
                    self?.refreshFullScreenCover()
                    self?.syncActiveScreenTracking()
                }
            }
        }

        // 跟 LyricsOverlayWindowController 同一个坑同一个修法:sink 闭包里必须用参数
        // 里收到的 isPlaying,不能在闭包内另外去读 PlaybackCoordinator.shared.
        // isPlayingNow 这个存储属性——@Published 的 willSet 在真正写入新值*之前*就
        // 已经发布,这个时间点读存储属性拿到的是上一次的旧值,细节见
        // LyricsOverlayWindowController.swift 同一处注释,不重复展开。
        PlaybackCoordinator.shared.$isPlayingSmoothed.sink { [weak self] isPlaying in
            // 收缩与否(isCollapsed)是从这个属性算出来的计算属性,写进来就等于生效,
            // 不用触发几何重算。同一个坑同一个修法:存的必须是 sink 参数里的
            // isPlaying,不能回头读 PlaybackCoordinator 的存储属性(那一刻还是旧值)。
            self?.isPlayingNow = isPlaying
            self?.updateActualVisibility(isPlayingNow: isPlaying)
        }
        .store(in: &subscriptions)

        // 广告插播 → 收起(isCollapsed 的第三个输入)。同一个 willSet 坑同一个修法:
        // 存 sink 参数值,绝不回头读 PlaybackCoordinator 的存储属性。写入 @Published
        // 即生效,几何不用重算(窗口常驻最大尺寸,收起只是内容层的事,同 isPlayingNow)。
        PlaybackCoordinator.shared.$isCurrentTrackAdBreak.sink { [weak self] isAd in
            self?.isAdBreakNow = isAd
        }
        .store(in: &subscriptions)

        // 有没有曲目(没曲目时歌词行不该全空还占着高度)。三个输入必须**同时**拿到才能算,所以用
        // CombineLatest3 而不是三个独立 sink —— 独立 sink 里只能拿到自己那一个参数,另外两个得回头读
        // 存储属性,那正是 @Published willSet 旧值坑。
        Publishers.CombineLatest3(
            PlaybackCoordinator.shared.$title,
            PlaybackCoordinator.shared.$artist,
            PlaybackCoordinator.shared.$isCurrentTrackAdBreak
        ).sink { [weak self] title, artist, isAd in
            guard let self else { return }
            let present = Self.trackPresent(title: title, artist: artist, isAdBreak: isAd)
            self.hasTrack = present
            // 提醒开始那一刻正好有曲目,setAlertHold 把它跳过了(见那边的注释);提醒还没结束曲目就没了,这时补撑开 ——
            // isAlerting 做了去重、不会再推一次,不补的话这一轮提醒就整个被吞掉。
            if !present, !self.alertHold, NotchUnknownPlayerPrompt.shared.isAlerting {
                self.setAlertHold(true)
            }
        }
        .store(in: &subscriptions)

        // 收听里程碑:报喜期间卡片自己撑开,面板换成报喜那一块。每个实例(含「所有屏幕」的副本)各自订阅同一个单例;
        // 是控制器订阅它,它不碰 `.shared`。存 sink 参数值,理由同下。
        ListenMilestoneCenter.shared.$current.removeDuplicates().sink { [weak self] next in
            self?.setMilestone(next)
        }
        .store(in: &subscriptions)
        ListenMilestoneCenter.shared.registerSurface(self) { [weak self] in self?.canShowMilestone ?? false }

        // 换歌翻牌的「掉歌名」:歌名 / 歌手 / 广告 / 在不在等开播去抖 300ms(常常一前一后到)再判。存 sink 参数值,理由同上。
        // 去抖挂主队列、别挂 RunLoop.main:菜单栏菜单开着时主线程在事件跟踪模式里转,RunLoop.main 的计时器要等菜单关了才走(见 05 章决策 67)。
        Publishers.CombineLatest4(
            PlaybackCoordinator.shared.$title,
            PlaybackCoordinator.shared.$artist,
            PlaybackCoordinator.shared.$isCurrentTrackAdBreak,
            PlaybackCoordinator.shared.$isWaitingToPlay
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] title, artist, isAd, isWaiting in
            self?.trackChanged(title: title, artist: artist, isAdBreak: isAd, isWaitingToPlay: isWaiting)
        }
        .store(in: &subscriptions)

        // 换歌翻牌的揭晓:歌名或歌手一变(不去抖)就当这首的封面还没到;之后协调器发一张新的系统封面(每次赋值都发一张新图,
        // 定案没有封面时发 nil),或者高清替代到了,就是到了。
        Publishers.CombineLatest(PlaybackCoordinator.shared.$title, PlaybackCoordinator.shared.$artist)
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in self?.trackIdentityChanged() }
        .store(in: &subscriptions)
        Publishers.Merge(
            PlaybackCoordinator.shared.$artworkImage.dropFirst().map { _ in () },
            PlaybackCoordinator.shared.$highResArtworkImage.dropFirst().compactMap { $0 }.map { _ in () }
        )
        .sink { [weak self] in self?.artworkArrived() }
        .store(in: &subscriptions)
        PlaybackCoordinator.shared.$notchLyrics
            .map { $0.compactLine != nil }
            .removeDuplicates()
            .sink { [weak self] showing in
                if showing { self?.lyricsLineAppeared() }
            }
        .store(in: &subscriptions)

        // 「发现新播放器」的主动提醒(NotchUnknownPlayerPrompt):提醒期间卡片自己撑开、隐藏着的
        // 窗口叫回来,到点收回。同一个 willSet 坑同一个修法:存 sink 参数值。每个实例(含「所有屏幕」的副本)
        // 各自订阅同一个单例,所以每块屏的灵动岛同时提醒,不用经 NotchMirrorManager 转发。
        // 是控制器订阅提示,不是提示引用控制器 —— 后者会碰 `.shared`,见文件头那条不变量。
        NotchUnknownPlayerPrompt.shared.$isAlerting.removeDuplicates().sink { [weak self] alerting in
            self?.setAlertHold(alerting)
        }
        .store(in: &subscriptions)

        // 瞬态横幅(音量、切输出设备、快捷键回声):关着歌词行时卡片为它多长一截;横幅一出来,正停着的换歌歌名条让开
        // (两样占同一个位置,横幅是用户刚做的事)。每个实例各自订阅同一个单例。
        NotchTransientCenter.shared.$banner.map { $0 != nil }.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active { self.clearTrackDrop() }
            self.transientBannerActive = active
        }
        .store(in: &subscriptions)
        // 「临时展开灵动岛」快捷键:每个实例各自订阅,「所有屏幕」时每块屏一起撑开。
        NotchPeekCenter.shared.$isPeeking.removeDuplicates().sink { [weak self] peeking in
            self?.setPeekHold(peeking)
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchShowsProgressLine.removeDuplicates().sink { [weak self] shows in
            self?.showsProgressLine = shows
        }
        .store(in: &subscriptions)

        // 「全屏时隐藏」:开关和全屏表两个输入同时从参数拿(同一个 willSet 坑)。每个实例各自订阅,
        // 镜像副本不经 NotchMirrorManager 转发。
        AppSettings.shared.$notchHideInFullScreen
            .combineLatest(FullScreenSpaceMonitor.shared.$fullScreenDisplays)
            .sink { [weak self] enabled, displays in
                self?.applyFullScreenCover(enabled: enabled, displays: displays)
            }
        .store(in: &subscriptions)
        // 进出全屏 Space 时重算几何:无刘海屏的黑条高度按这块屏当下的菜单栏算(`menuBarHeight`),全屏 Space 里菜单栏
        // 收起、算出来是兜底的 24;在全屏里重算过一次(装机重启、改设置、插拔屏)的话,退出全屏后黑条一直比菜单栏矮,
        // 要等下一次屏幕参数变化。放到下一拍:切 Space 的通知到时可见区域不一定已经换好。
        FullScreenSpaceMonitor.shared.$fullScreenDisplays
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.recomputeGeometry(animate: false) } }
            }
        .store(in: &subscriptions)
        // 「纯音乐/无歌词时收起歌词行」:开关和「这首有没有歌词」同时从参数拿(同一个 willSet 坑)。
        AppSettings.shared.$notchCollapseLyricsWhenNoLyrics
            .combineLatest(PlaybackCoordinator.shared.$currentTrackLacksLyrics)
            .map { NoLyricsAutoHide.hides(enabled: $0, lacksLyrics: $1) }
            .removeDuplicates()
            .sink { [weak self] collapse in
                guard let self else { return }
                lyricsCollapsedForNoLyrics = collapse
                applyShowsLyrics()
            }
        .store(in: &subscriptions)

        // 展开区的两个"要不要留高度"标志(没歌词时展开卡不该留一大片空白)。
        // 刻意订阅**曲目级**信号而不是"此刻有没有下一句"——理由见
        // NotchExpandedMetrics.height 的注释(后者会让最后一句唱完时卡片抽动)。
        // 同一个 willSet 坑同一个修法:存 sink 参数值。写入 @Published 即生效,窗口尺寸
        // 不用重算(窗口恒为最大形态,卡片高度是内容层的事)。
        PlaybackCoordinator.shared.$hasLyricsContent.sink { [weak self] has in
            self?.expandedShowsLyricPreview = has
        }
        .store(in: &subscriptions)
        PlaybackCoordinator.shared.$currentDurationMs.sink { [weak self] ms in
            self?.expandedShowsScrubber = (ms ?? 0) > 0
        }
        .store(in: &subscriptions)
        // 「显示歌词」开关。同上:存 sink 参数值(@Published 是 willSet 时机,回读拿到旧值);
        // 只改卡片内容和高度,窗口尺寸不用重算(窗口恒为最大形态)。
        AppSettings.shared.$notchShowLyrics.removeDuplicates().sink { [weak self] show in
            guard let self else { return }
            showsLyricsSetting = show
            applyShowsLyrics()
        }
        .store(in: &subscriptions)
        // 「暂停时缩到最小」开关。同一个 willSet 坑同一个修法:存 sink 参数值。写入
        // @Published 即生效——isCollapsed 是计算属性,靠这次 objectWillChange 让依赖它的
        // 视图重新读到新值,不需要额外重算几何(窗口恒为最大形态,收缩只是内容层的事)。
        AppSettings.shared.$notchCollapsesWhenPaused.removeDuplicates().sink { [weak self] collapses in
            self?.collapsesWhenPaused = collapses
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchCollapsesDuringAds.removeDuplicates().sink { [weak self] collapses in
            self?.collapsesDuringAds = collapses
        }
        .store(in: &subscriptions)
        // 左右耳配置。**必须重算几何**:卡片宽度的下限是这两项的函数(见 minEarWidth),
        // 换一个模块就可能把卡片顶宽(配成控制键)或者放开(配成不显示)。漏了这两条订阅的表现是
        // "选了播放控制、三个键被裁掉半个,直到下次拖宽度才恢复"。
        //
        // 两条都把 sink 的**参数值**显式传下去,不让下游回读 AppSettings:@Published 是
        // willSet 时机派发,此刻存储属性还是旧值(同一个坑见 NotchMirrorManager.start())。
        // 每次只有一只耳朵在变,另一只回读是安全的。
        AppSettings.shared.$notchLeftEar.removeDuplicates().sink { [weak self] module in
            self?.recomputeGeometry(animate: false, leftEar: module)
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchRightEar.removeDuplicates().sink { [weak self] module in
            self?.recomputeGeometry(animate: false, rightEar: module)
        }
        .store(in: &subscriptions)
        // 音浪开关/贴哪只耳朵:同一个 willSet 坑同一个修法——存 sink 参数值、
        // 并且必须重算几何(下限公式 minEarWidth 依赖这两个值,见那边的注释)。
        AppSettings.shared.$notchShowsEqualizer.removeDuplicates().sink { [weak self] shows in
            self?.showsEqualizer = shows
            self?.recomputeGeometry(animate: false, showsEqualizer: shows)
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchEqualizerEar.removeDuplicates().sink { [weak self] ear in
            self?.equalizerEar = ear
            self?.recomputeGeometry(animate: false, equalizerEar: ear)
        }
        .store(in: &subscriptions)

        // 展开态那一组:同一个 willSet 坑同一个修法——存 sink 参数值、并且
        // 必须重算几何(展开区高度公式 expandedExtraHeight 依赖这几个值,见那边的注释)。
        // 宽度不受影响,所以这几条订阅只把新值传进 recomputeGeometry 对应的高度类入参,
        // 不碰 contentWidth/leftEar/rightEar/showsEqualizer/equalizerEar 那几个。歌词行
        // 末尾那枚封面开关/位置不影响高度,不在这一组;头部**自己**的封面开关在这一组
        // (`expandedTrackInfoShowsArtwork`),理由见 `expandedTrackInfoShowsArtwork` 上面
        // 那条提醒。播放控制键开关(`expandedShowsControls`)同样在这一组——它不是曲目级
        // 数据信号,是纯用户设置,跟 `expandedShowsNextLine` 同一个性质。
        // 「下一句歌词预览」最终画不画 = 用户开关 && 没被歌词行「副行」顶掉(副行选「下一句」
        // 时展开区再画一行同一句是重复)。判据只有 Core 那一份 `LyricSecondaryLine.expandedNextLinePreviewVisible`,
        // 设置页替身 `NotchPreviewChrome` 调的也是它;两个输入任一变化都要重算展开区高度上限。
        Publishers.CombineLatest(
            AppSettings.shared.$notchExpandedShowsNextLine, AppSettings.shared.$notchSecondaryLine
        )
        .map { LyricSecondaryLine.expandedNextLinePreviewVisible(userToggle: $0, secondary: $1) }
        .removeDuplicates()
        .sink { [weak self] shows in
            self?.expandedShowsNextLine = shows
            self?.recomputeGeometry(animate: false, expandedShowsNextLine: shows)
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchExpandedShowsControls.removeDuplicates().sink { [weak self] shows in
            self?.expandedShowsControls = shows
            self?.recomputeGeometry(animate: false, expandedShowsControls: shows)
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchExpandedShowsArtwork.removeDuplicates().sink { [weak self] shows in
            self?.expandedTrackInfoShowsArtwork = shows
            self?.recomputeGeometry(animate: false, expandedTrackInfoShowsArtwork: shows)
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchExpandedShowsTrackTitle.removeDuplicates().sink { [weak self] shows in
            self?.expandedTrackInfoShowsTitle = shows
            self?.recomputeGeometry(animate: false, expandedTrackInfoShowsTitle: shows)
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchExpandedShowsArtist.removeDuplicates().sink { [weak self] shows in
            self?.expandedTrackInfoShowsArtist = shows
            self?.recomputeGeometry(animate: false, expandedTrackInfoShowsArtist: shows)
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchExpandedShowsAlbum.removeDuplicates().sink { [weak self] shows in
            self?.expandedTrackInfoShowsAlbum = shows
            self?.recomputeGeometry(animate: false, expandedTrackInfoShowsAlbum: shows)
        }
        .store(in: &subscriptions)
        AppSettings.shared.$notchExpandedShowsQuickActions.removeDuplicates().sink { [weak self] shows in
            self?.expandedShowsQuickActions = shows
            self?.recomputeGeometry(animate: false, expandedShowsQuickActions: shows)
        }
        .store(in: &subscriptions)
        // 歌词行高度:设定值、字号、副行三项合成实际高度(设定值夹到装得下当前文字为止)。窗口高度跟着它,
        // 必须重算几何;三个值都取 sink 参数(同一个 willSet 坑),先写镜像,recomputeGeometry 再读镜像。
        // 副行同时决定展开区留不留「下一句」那一行,也按 sink 参数传进去:不传的话 recomputeGeometry 回退去读
        // AppSettings 里还没改完的旧副行。
        Publishers.CombineLatest3(
            AppSettings.shared.$notchLyricRowHeight, AppSettings.shared.$notchFontSize, AppSettings.shared.$notchSecondaryLine
        )
        .map { setting, fontSize, secondary in
            (height: NotchLyricRowMetrics.effectiveRowHeight(
                setting: CGFloat(setting), fontSize: CGFloat(fontSize), twoLines: secondary.showsSecondaryRow),
             secondary: secondary)
        }
        .removeDuplicates { $0.height == $1.height }
        .sink { [weak self] row in
            guard let self else { return }
            if self.lyricRowHeight != row.height { self.lyricRowHeight = row.height }
            self.recomputeGeometry(animate: false, expandedShowsNextLine: LyricSecondaryLine.expandedNextLinePreviewVisible(
                userToggle: AppSettings.shared.notchExpandedShowsNextLine, secondary: row.secondary))
        }
        .store(in: &subscriptions)
        // 多行歌词那一格的高度:开关、行数、副行(带译文 / 读音时每行高一截)。同上先写镜像再重算几何,三个值都取 sink 参数。
        Publishers.CombineLatest3(
            AppSettings.shared.$notchExpandedLyricList, AppSettings.shared.$notchExpandedLyricListLines,
            AppSettings.shared.$notchSecondaryLine
        )
        .map { AppSettings.notchExpandedLyricListHeight(enabled: $0, lines: $1, secondary: $2) }
        .removeDuplicates()
        .sink { [weak self] height in
            guard let self else { return }
            if self.expandedLyricListHeight != height { self.expandedLyricListHeight = height }
            self.recomputeGeometry(animate: false)
        }
        .store(in: &subscriptions)
        $isVisible
            .combineLatest($expandedTrackInfoShowsAlbum, $expandedTrackInfoShowsArtist, $expandedTrackInfoShowsTitle)
            .map { visible, album, artist, title in visible && (album || artist || title) }
            .removeDuplicates()
            .sink { [weak self] wants in self?.setEditorialDemand(wants) }
        .store(in: &subscriptions)

        // 两个自动隐藏开关、一对宽度:每个实例(主实例与镜像副本)自己订阅,设置的写入口只写 AppSettings、不碰控制器。
        // 值取 sink 参数(willSet 时机回读 AppSettings 是旧值);开窗那一刻的同步在 setVisible / syncStateFromSettings。
        Publishers.CombineLatest4(
            AppSettings.shared.$notchHideWhenNotPlaying, AppSettings.shared.$notchHideDuringScreenCapture,
            AppSettings.shared.$notchContentWidth, AppSettings.shared.$notchExpandedContentWidth
        )
        .dropFirst()
        .sink { [weak self] hide, captureHidden, width, expandedWidth in
            self?.applyBehaviorSettings(hide: hide, captureHidden: captureHidden,
                                        contentWidth: CGFloat(width), expandedContentWidth: CGFloat(expandedWidth))
        }
        .store(in: &subscriptions)
        // 主实例贴哪块屏(副本钉死在自己那块屏上,不看它)。目标屏由 resolvedScreen 现读设置,willSet 里读到的是旧值,
        // 所以放到主队列下一拍再算。
        if pinnedScreenID == nil {
            AppSettings.shared.$notchScreenID
                .dropFirst()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyScreenSetting() }
                .store(in: &subscriptions)
            // 「显示在:跟随当前窗口」(跟「全部屏幕」互斥,开着全部屏幕时不跟)。展开着时不搬:用户正在这块屏上点它。
            activeScreen.canMove = { [weak self] in self.map { !$0.isExpanded } ?? false }
            activeScreen.onFollow = { [weak self] screen, force in self?.followActiveScreen(screen, force: force) }
            AppSettings.shared.$notchFollowsActiveScreen
                .combineLatest(AppSettings.shared.$notchAllScreens)
                .map { follows, allScreens in follows && !allScreens }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] on in self?.setFollowsActiveScreen(on) }
                .store(in: &subscriptions)
        }

        // 宽度固定,recomputeGeometry 的结果跟 currentLine 没有关系,不需要额外订阅 currentLine 来触发重算。
    }

    /// 「显示在:跟随当前窗口」的镜像(`AppSettings.notchFollowsActiveScreen` 且没开全部屏幕),只有主实例用。
    private var followsActiveScreen = false
    /// 不算全屏遮挡的话该不该摆着(`updateActualVisibility` 写入)。
    private var shownApartFromFullScreen = false
    private let activeScreen = ActiveScreenFollower()

    deinit {
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// 展开态头部快捷操作里那颗 ✕:关掉「灵动岛歌词」总开关。只是 `setVisible(false)`
    /// 的一个入口,不另起状态 —— 跟悬浮歌词那颗 ✕(`LyricsOverlayWindowController` 的 `.closeOverlay`)
    /// 完全对称。副本上的 ✕ 转给主实例关:主实例不订阅总开关,只有它自己的 `setVisible` 能把它藏起来;
    /// 总开关一关,副本由 `NotchMirrorManager` 拆掉。
    func closeFromQuickAction() {
        guard pinnedScreenID != nil else {
            setVisible(false)
            return
        }
        NotchLyricsWindowController.shared.setVisible(false)
    }

    /// 展开态头部点歌名 / 专辑名 / 歌手名。卡片从屏幕顶边垂下来、水平居中,所以卡片在屏幕上的矩形按窗口顶边与
    /// 卡片宽高直接算。这一类没有简介时什么都不做(入口本来也不可点)。
    func toggleEditorial(_ kind: EditorialCard.Kind) {
        guard let window, let frame = cardScreenFrame, let card = EditorialNotesStore.shared.card(kind) else { return }
        NotchEditorialPanel.shared.toggle(card: card, cardFrame: frame, owner: window) { [weak self] hovered in
            self?.setEditorialHovered(hovered)
        }
    }

    /// 卡片此刻在屏幕上的矩形:卡片从窗口顶边垂下来、水平居中。
    private var cardScreenFrame: NSRect? {
        guard let window else { return nil }
        return NSRect(x: window.frame.midX - cardWidth / 2, y: window.frame.maxY - cardHeight,
                      width: cardWidth, height: cardHeight)
    }

    /// 灵动岛开着且头部画歌名、歌手名或专辑名时,向 `EditorialNotesStore` 登记要预取(入口只在有简介时可点,
    /// 得提前知道)。
    private var holdsEditorialDemand = false

    private func setEditorialDemand(_ wants: Bool) {
        guard wants != holdsEditorialDemand else { return }
        holdsEditorialDemand = wants
        if wants { EditorialNotesStore.shared.retain() } else { EditorialNotesStore.shared.release() }
    }

    // 打开/关闭"灵动岛歌词"的**唯一**入口——设置页那个 Toggle、菜单栏"显示灵动岛歌词"两处
    // 都必须走这里。理由跟 LyricsOverlayWindowController.setVisible(_:) 完全对称,不重复展开:
    // 统一写回 AppSettings.notchOverlayEnabled(由它的 didSet 持久化),打开时顺手把两个已
    // 配置好的隐藏偏好也应用上。
    func setVisible(_ visible: Bool) {
        isVisible = visible
        AppSettings.shared.notchOverlayEnabled = visible
        if visible {
            setHiddenFromCapture(AppSettings.shared.notchHideDuringScreenCapture)
            setHideWhenNotPlaying(AppSettings.shared.notchHideWhenNotPlaying)
            // **宽度和屏幕**跟上面两个隐藏偏好是同一类"已经配置好、打开时要一并应用"的东西。设置页
            // 那两个入口(宽度调整条 / 「屏幕」浮层)都带 `if settings.notchOverlayEnabled` 守卫(那条守卫
            // 本身必须留 —— `.shared` 是 `static let`,读一下就 init 出整扇窗),所以"关着改、再打开"这条路上
            // 只有这里会把新值应用到几何上;不重算的话窗口按旧宽度、甚至旧那块屏冒出来。
            //
            // recomputeGeometry 内部四个 @Published 和 setFrame 全部判等再写,所以这一句在
            // 几何没变时是纯读,没有额外代价。
            recomputeGeometry(animate: false)
        }
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    /// 写「暂停时隐藏」的唯一入口。先记 `vanishesFromCollapsed` 再翻开关:两个值同一拍到视图,卡片不先撑开一下。
    private func assignHideWhenNotPlaying(_ hide: Bool) {
        guard hideWhenNotPlaying != hide else { return }
        let fromCollapsed = hide && isCollapsed
        if vanishesFromCollapsed != fromCollapsed { vanishesFromCollapsed = fromCollapsed }
        hideWhenNotPlaying = hide
    }

    // 灵动岛自己那一份"暂停/无播放时隐藏"(`AppSettings.notchHideWhenNotPlaying`),跟悬浮歌词那份是
    // 两个独立的值 —— 别把 `AppSettings.hideWhenNotPlaying`(只归悬浮歌词)接到这里。
    func setHideWhenNotPlaying(_ hide: Bool) {
        assignHideWhenNotPlaying(hide)
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    // 灵动岛自己那一份"截屏/录屏时隐藏"(`AppSettings.notchHideDuringScreenCapture`),
    // 同上,跟悬浮歌词那一份互相独立。
    func setHiddenFromCapture(_ hidden: Bool) {
        window?.sharingType = hidden ? .none : .readWrite
    }

    /// 悬停展开 / 窗口显隐的边沿日志:只在边沿上写,不跟每次指针移动。
    static let hoverLog = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notch-hover")
    // hover 意图判定的两个延迟。
    //
    // 光标从刘海底下横穿而过(去点菜单栏、去够右上角控制中心)会连着触发 enter+exit,
    // 没有延迟的话灵动岛就闪一下,很扎眼;反过来光标停在展开态卡片的下边缘时,内容
    // 高度变化会让 hover 状态在边界上来回抖,收起延迟能把这种抖动吸收掉。
    //
    // 进入延迟取 0.12s:展开出来的是"下一句 + 迷你进度条",是想看就得马上看到的信息——
    // 展开本身还有一条 0.38s 的弹簧,感知延迟是这两段之和,砍在意图判定这一段最划算。
    //
    // 别再往下压:这个延迟唯一的作用就是滤掉"鼠标只是路过刘海下方"的误触发,
    // 归零的话光标横穿屏幕顶部就会一路把灵动岛捅开。
    private static let hoverEnterDelay: TimeInterval = 0.12
    private static let hoverExitDelay: TimeInterval = 0.1
    private var pendingHoverWork: DispatchWorkItem?

    func setExpandedFromWindow(_ expanded: Bool) {
        cardHovered = expanded
        syncCardCursor()
        applyHoverIntent()
    }

    /// 指针进出简介浮框(`NotchEditorialPanel`)。浮框算展开态的一部分:指针在上面时卡片不收。
    func setEditorialHovered(_ hovered: Bool) {
        guard hovered != editorialHovered else { return }
        editorialHovered = hovered
        syncCardCursor()
        applyHoverIntent()
    }

    /// 卡片自己、简介浮框,任一被指针停着就算悬停。两路都走同一套进入 / 收起延迟。
    private var cardHovered = false
    private var editorialHovered = false
    /// 控制器此刻认不认为指针在卡片上。`NotchWindowRoot.updateHover` 拿它跟自己的边沿记忆对账。
    var isCardHovered: Bool { cardHovered }

    /// 指针在卡片或简介浮框上时光标钉成箭头。App 在后台,不开 `BackgroundCursor` 时 `NSCursor.set()` 不生效,
    /// 光标停在下层前台 App 设的样子(终端上是 I 形);前台 App 重绘又会把它换回去,所以停着期间定时重设。
    /// 跟悬停同一份输入、不等进入延迟:光标跟着卡片的边界走。见 05 章决策 78。
    private var cardCursorTimer: Timer?

    private func syncCardCursor() {
        let wants = (cardHovered || editorialHovered) && (window?.isVisible ?? false)
        guard wants != (cardCursorTimer != nil) else { return }
        guard wants else { releaseCardCursor(); return }
        BackgroundCursor.setEnabled(true, for: ObjectIdentifier(self))
        NSCursor.arrow.set()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertCardCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cardCursorTimer = timer
    }

    /// 「离开」事件丢了也不能一直改别人窗口上的光标:指针已经不在卡片和浮框上就放手。
    private func reassertCardCursor() {
        let mouse = NSEvent.mouseLocation
        let onCard = (window?.isVisible ?? false) && (cardScreenFrame?.contains(mouse) ?? false)
        let onPanel = NotchEditorialPanel.shared.frame(ifOwner: window)?.contains(mouse) ?? false
        guard onCard || onPanel else { releaseCardCursor(); return }
        NSCursor.arrow.set()
    }

    private func releaseCardCursor() {
        cardCursorTimer?.invalidate()
        cardCursorTimer = nil
        BackgroundCursor.setEnabled(false, for: ObjectIdentifier(self))
    }

    private func applyHoverIntent() {
        let expanded = cardHovered || editorialHovered
        // 每次新的 hover 事件都先撤掉上一次还没兑现的意图 —— "进了又出"必须净效果为零,
        // 而不是两个延迟各自到期、先展开再收起地闪一下。
        pendingHoverWork?.cancel()
        pendingHoverWork = nil
        // 比的是 hover 自己那一路的值,不是 isExpanded(后者还有提醒这一个输入):提醒撑开
        // 期间光标进来,这里照样把 hoverExpanded 记成 true —— 到点收提醒时卡片才不会从光标底下塌回去。
        guard expanded != hoverExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, expanded != self.hoverExpanded else { return }
            self.pendingHoverWork = nil
            let wasExpanded = self.isExpanded
            self.hoverExpanded = expanded
            self.refreshExpanded()
            Self.hoverLog.notice("hover \(expanded ? "expand" : "collapse", privacy: .public) isExpanded=\(self.isExpanded, privacy: .public)")
            // 不 recomputeGeometry:窗口尺寸跟展开与否无关,展开这件事整个发生在 SwiftUI 那一侧
            // (NotchWindowRoot 的弹簧动画)。
            // 触觉反馈跟着卡片**真正展开**的这一刻给,别挪到意图延迟兑现之前(那样震动比视觉动作早
            // hoverEnterDelay 到达,不像一次反馈)。用 .generic 不用 .alignment:后者是给拖拽吸附设计的
            // 短促双击感,压在"只是把鼠标移过去"这种被动 hover 上偏硬。只在展开时给,收起不给;卡片本来
            // 就被提醒撑开着(没有视觉动作可对应)时也不给。
            if expanded && !wasExpanded {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
        pendingHoverWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (expanded ? Self.hoverEnterDelay : Self.hoverExitDelay),
            execute: work)
    }

    /// `isExpanded` 的唯一写入点:hover、提醒、收听里程碑任一成立就展开。判等再写 —— 它是 @Published,白写一次就是
    /// 整卡白重估一次。
    private func refreshExpanded() {
        if !hoverExpanded, milestoneClearPending {
            milestoneClearPending = false
            milestone = nil
        }
        let next = hoverExpanded || alertHold || milestoneHold || peekHold
        let opening = next && !isExpanded
        // 回读播放模式、「喜欢」只在指针悬停展开时做:提醒、报喜撑开卡片时那几颗键被盖着,而且每块屏的副本会同时撑开。
        let hoverOpening = opening && hoverExpanded && !alertHold && !milestoneHold
        if next != isExpanded { isExpanded = next }
        // 展开区的随机 / 循环键(只给随机、循环此刻都能切的播放器)跟播放器对一次表:用户可能在那边自己改过模式,
        // 没有事件通知得到。只在两颗键会出现时读,别的播放器不为这次悬停起脚本子进程。
        if hoverOpening, expandedShowsControls,
           PlaybackCoordinator.shared.playbackModeOptions.contains(.shuffle),
           PlaybackCoordinator.shared.playbackModeOptions.canRepeat {
            PlaybackCoordinator.shared.refreshPlaybackMode()
        }
        // 头部那颗「喜欢」同理:用户可能在播放器里自己点过。没有「喜欢」的播放器 refreshFavorited 不起子进程。
        if hoverOpening, expandedShowsQuickActions, !isAdBreakNow {
            PlaybackCoordinator.shared.refreshFavorited()
        }
        if next {
            // 展开头部本来就有歌名,掉出来的那条收掉。
            clearTrackDrop()
            // 展开是「要看了」的时刻:换歌时还没对上专辑的曲目,引擎补上之后靠这一下变可点。
            if holdsEditorialDemand { EditorialNotesStore.shared.refreshCurrent() }
        } else {
            NotchEditorialPanel.shared.close(ifOwner: window)
        }
    }

    /// 收听里程碑开始 / 结束(`ListenMilestoneCenter.current` 的 sink)。开:撑开卡片,顶行以下换成报喜面板;
    /// 关:指针不在卡片上就收回,在的话等它离开(refreshExpanded 里收)。
    private func setMilestone(_ next: ListenMilestone?) {
        if let next {
            milestoneClearPending = false
            if milestone != next { milestone = next }
        } else if hoverExpanded {
            milestoneClearPending = true
        } else if milestone != nil {
            milestone = nil
        }
        if next != nil { clearTrackDrop() }
        let hold = next != nil
        guard hold != milestoneHold else { return }
        milestoneHold = hold
        refreshExpanded()
    }

    /// 「临时展开灵动岛」开始 / 结束(`NotchPeekCenter.isPeeking` 的 sink)。到点时指针还停在卡片上,hoverExpanded 接着撑着。
    private func setPeekHold(_ hold: Bool) {
        guard hold != peekHold else { return }
        peekHold = hold
        refreshExpanded()
    }

    /// 卡片上的滚动事件(`NotchLyricsWindow.onScrollWheel`):两指左右滑切歌,上下滑调系统音量,判法在 `NotchScrollGesture`。
    /// 「触控板手势」关着、没有曲目、事件不落在卡片上时不认,这一次滑动作废。位置取事件自己带的(发生那一刻指针在哪),不取此刻的
    /// `NSEvent.mouseLocation`。切歌走快捷键那一条(先查自动化权限);调音量后音量横幅由 `VolumeMonitor` 照常弹,关着歌词行时卡片为它
    /// 多长一截。
    private func handleScrollWheel(_ event: NSEvent) {
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        guard AppSettings.shared.notchGestures, hasTrack, cardScreenFrame?.contains(point) ?? false else {
            scrollGesture.invalidate()
            return
        }
        // 鼠标滚轮每一格各自发给指针下面的窗口:卡片在不动的指针下面长大(掉歌名、横幅、临时展开)时,用户本来在滚下层的 App,
        // 后面几格就落到卡片上调了音量。要求指针真的移到过卡片上(`cardHovered` 只随指针移动更新)。
        if event.phase.isEmpty, event.momentumPhase.isEmpty, !cardHovered { return }
        let phase: NotchScrollGesture.Phase
        if !event.momentumPhase.isEmpty {
            phase = .momentum
        } else if event.phase.contains(.began) {
            phase = .began
        } else if event.phase.contains(.changed) {
            phase = .changed
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            phase = .ended
        } else if event.phase.isEmpty {
            phase = .none
        } else {
            return
        }
        guard let action = scrollGesture.feed(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                                              phase: phase, invertedFromDevice: event.isDirectionInvertedFromDevice,
                                              preciseDeltas: event.hasPreciseScrollingDeltas)
        else { return }
        switch action {
        case .nextTrack:
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            LyrimuseActionRunner.perform(.nextTrackHotkey)
        case .previousTrack:
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            LyrimuseActionRunner.perform(.previousTrackHotkey)
        case .volume(let delta):
            VolumeMonitor.adjustSystemVolume(by: delta)
        }
    }

    /// 换歌翻牌的「掉歌名」(init 里换歌翻牌那条订阅去抖后调):换了一首(判法见 `NotchTrackDropTracker`:不是这个实例看到的
    /// 第一首、不是广告,声音还没走起来时先不判),「换歌时显示歌名」开着,卡片此刻放得下(`trackDropFits`),就判成要掉。
    /// 什么时候真掉由 `NotchTrackRevealGate` 定:这首的封面到了才揭晓,歌名掉下来和耳朵里的封面翻过来同一拍,
    /// 封面最多等 `NotchTrackRevealGate.artworkWait`;判成不掉当场揭晓。
    private func trackChanged(title: String, artist: String, isAdBreak: Bool, isWaitingToPlay: Bool) {
        let outcome = trackDropTracker.observe(title: title, artist: artist, isAdBreak: isAdBreak,
                                               isWaitingToPlay: isWaitingToPlay)
        guard outcome != .none else { return }
        // 声音还没走起来:还没判,不揭晓,耳朵里的封面接着等;正停着的那条收掉。
        guard !isWaitingToPlay else {
            revealGate.cancel()
            stopRevealWait()
            clearTrackDrop()
            return
        }
        let wantsDrop = outcome == .drop
            && AppSettings.shared.notchShowsTrackDrop
            && trackDropFits
        if outcome == .drop, !wantsDrop, AppSettings.shared.notchShowsTrackDrop {
            Self.trackDropLog.notice("track drop: skipped, card not showing for \(artist, privacy: .public) - \(title, privacy: .public)")
        }
        let now = Date()
        pendingDrop = wantsDrop ? (title, artist, now) : nil
        let key = NotchTrackDropRules.key(title: title, artist: artist, isAdBreak: isAdBreak)
        if let reveal = revealGate.decided(key: key, wantsDrop: wantsDrop, now: now) {
            applyReveal(reveal)
            return
        }
        // 等这首的封面:正停着的上一首那条先收掉。
        clearTrackDrop()
        scheduleRevealWait()
    }

    /// 快捷键回声此刻能不能落在灵动岛上:横幅盖在歌词行上,关着歌词行时卡片为它多长一截(`showsBannerStrip`);窗口不在屏、
    /// 缩进刘海、收起(暂停 / 广告)或者没有曲目时无处显示。见 14 章决策 130、05 章决策 88。
    var showsTransientBanner: Bool {
        lastAppliedShouldShow == true && !isVanished && !isCollapsed && hasTrack
    }

    /// 收听里程碑此刻有没有地方报:窗口在屏、没缩进刘海、没被挡(全屏时隐藏、锁屏、熄屏都不算)。init 里登记给
    /// `ListenMilestoneCenter`,哪个实例都不在屏时它不判、不记账,不然这一档白白记掉、以后再也不报。
    var canShowMilestone: Bool {
        lastAppliedShouldShow == true && !isVanished && isSurfaceVisible
    }

    /// 卡片此刻放得下掉出来的歌名:窗口在屏、没缩进刘海、没被挡,不在收起 / 展开 / 报喜 / 「发现新播放器」提醒里,也没有瞬态横幅
    /// (两样占同一个位置,横幅在时歌名不掉,见 05 章决策 88)。
    private var trackDropFits: Bool {
        lastAppliedShouldShow == true && !isVanished && isSurfaceVisible
            && !isCollapsed && !isExpanded && milestone == nil && !alertHold && !transientBannerActive
    }

    /// 揭晓(`NotchTrackRevealGate`):耳朵里的封面这一拍可以翻了;判成要掉的,卡片还放得下就让新歌名掉出来停
    /// `NotchTrackDropRules.holdDuration`,停的时候又换歌就原地换成新的、重新计时。开着歌词行时歌名条盖在歌词行上,
    /// 停到第一句出来之前,第一句马上就来就不掉(`NotchTrackDropRules.hold`,见 05 章决策 72)。
    private func applyReveal(_ reveal: NotchTrackRevealGate.Reveal) {
        let track = pendingDrop
        stopRevealWait()
        if revealedTrackKey != reveal.key { revealedTrackKey = reveal.key }
        guard reveal.drops, let track else {
            clearTrackDrop()
            return
        }
        // 等封面的那一会儿卡片可能被收起、展开或挡住了。
        guard AppSettings.shared.notchShowsTrackDrop, trackDropFits else {
            if AppSettings.shared.notchShowsTrackDrop {
                Self.trackDropLog.notice("track drop: skipped, card not showing for \(track.artist, privacy: .public) - \(track.title, privacy: .public)")
            }
            clearTrackDrop()
            return
        }
        var hold = NotchTrackDropRules.holdSeconds
        if showsLyrics {
            let untilLyrics = secondsUntilLyrics()
            guard let lyricsHold = NotchTrackDropRules.hold(secondsUntilLyrics: untilLyrics) else {
                let until = untilLyrics.map { String(format: "%.2f", $0) } ?? "?"
                Self.trackDropLog.notice("track drop: skipped, lyrics start in \(until, privacy: .public)s for \(track.artist, privacy: .public) - \(track.title, privacy: .public)")
                clearTrackDrop()
                return
            }
            hold = lyricsHold
        }
        let waitedMs = Int(Date().timeIntervalSince(track.since) * 1000)
        Self.trackDropLog.notice("track drop: shown for \(track.artist, privacy: .public) - \(track.title, privacy: .public), waited \(waitedMs)ms for the cover, hold \(String(format: "%.2f", hold), privacy: .public)s")
        trackDropGeneration &+= 1
        let replacing = NotchTrackDropRules.replaced(showing: trackDrop, cleared: clearedTrackDrop?.drop,
                                                     clearedAt: clearedTrackDrop?.at, now: Date())
        trackDrop = NotchTrackDrop(id: trackDropGeneration, title: TrackNameDisplay.cleaned(track.title),
                                   artist: PlaybackCoordinator.shared.displayArtist,
                                   replacing: replacing)
        trackDropClearTask?.cancel()
        trackDropClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.clearTrackDrop()
        }
    }

    func revealsTrack(_ key: String) -> Bool { revealedTrackKey == key }

    /// 离灵动岛的歌词行显示第一句还有几秒(`NotchTrackDropRules.secondsUntilLyrics`)。
    private func secondsUntilLyrics() -> TimeInterval? {
        let playback = PlaybackCoordinator.shared
        let lyrics = playback.notchLyrics
        let anchor = playback.anchor
        return NotchTrackDropRules.secondsUntilLyrics(
            showingLine: lyrics.compactLine != nil, pastFirstLine: lyrics.lineIndex != nil,
            firstLineMs: playback.allLines.first?.timeMs,
            lyricsPositionMs: anchor.map { $0.extrapolatedPositionMs() + playback.currentLyricsOffsetMs },
            rate: anchor?.rate ?? 0)
    }

    /// 歌词行出现了要显示的一句(init 里 `$notchLyrics` 那条订阅):开着歌词行、歌名条正盖在上面就收掉。揭晓时已按第一句的时间算好
    /// 停多久,这里接住算不准的情形:歌词晚到、拖了进度(见 05 章决策 72)。
    private func lyricsLineAppeared() {
        guard showsLyrics, let shown = trackDrop else { return }
        Self.trackDropLog.notice("track drop: retracted early, lyrics started for \(shown.artist, privacy: .public) - \(shown.title, privacy: .public)")
        clearTrackDrop()
    }

    /// 判成要掉、封面还没到:等到 `NotchTrackRevealGate.deadline` 还没到就先掉歌名。
    private func scheduleRevealWait() {
        revealWaitTask?.cancel()
        revealWaitTask = nil
        guard let deadline = revealGate.deadline else { return }
        revealWaitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, let reveal = self.revealGate.artworkWaitExpired() else { return }
            self.applyReveal(reveal)
        }
    }

    private func stopRevealWait() {
        revealWaitTask?.cancel()
        revealWaitTask = nil
        pendingDrop = nil
    }

    /// 歌名或歌手变了(不去抖,见 init 里 `$title` / `$artist` 那条订阅):这首的封面还没到,还在等的那次判定作废。
    private func trackIdentityChanged() {
        revealGate.trackChanged()
        stopRevealWait()
    }

    /// 封面到了(见 init 里封面到货那条订阅):正等着封面的那次判定这一拍揭晓。
    private func artworkArrived() {
        guard let reveal = revealGate.artworkArrived() else { return }
        applyReveal(reveal)
    }

    private func clearTrackDrop() {
        trackDropClearTask?.cancel()
        trackDropClearTask = nil
        if let shown = trackDrop {
            clearedTrackDrop = (shown, Date())
            trackDrop = nil
        }
    }

    /// 「发现新播放器」主动提醒的开 / 关(来自 NotchUnknownPlayerPrompt.isAlerting 的 sink)。
    /// 开:撑开卡片(hasTrack 为 false 时展开出来的正是空闲面板那一块,视图那侧换成信任提议的变体),窗口若因
    /// 「暂停/无播放时隐藏」藏着就叫回来(走 updateActualVisibility 的常规出场路,含「从刘海撑开」动画)。
    /// 关:hover 没停在上面就收回,再按当下播放态重新决定要不要隐藏窗口。
    private func setAlertHold(_ hold: Bool) {
        guard hold != alertHold else { return }
        // 有曲目时不撑开:提议的变体只在"没有曲目"那块空闲面板上画(见 NotchIdlePanelHost),这时候撑开只会露出
        // 上一首(暂停中)的曲目头部、看不到任何提议 —— 用户只会纳闷"它怎么自己展开了"。系统通知那条路不受影响。
        // 正常情况下到不了这里:未信任的播放器抢到 Now Playing 焦点时,被采纳的那份快照已经没有曲目。
        if hold, hasTrack { return }
        alertHold = hold
        refreshExpanded()
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    /// 自动隐藏两个开关、一对宽度变了(init 里那条订阅,参数是 sink 收到的新值)。宽度变化把几何整个重算一遍:灵动岛的
    /// 位置从不持久化,每次都按当前屏幕居中算。`animate: false`:平滑过渡由卡片那条弹簧负责,NSWindow 再动画会跟它打架。
    private func applyBehaviorSettings(hide: Bool, captureHidden: Bool, contentWidth: CGFloat, expandedContentWidth: CGFloat) {
        assignHideWhenNotPlaying(hide)
        // sharingType 每次直接写、不判等:运行中这扇窗读回来的值不可靠(实测设成 .readWrite 后读回 0 = .none),判等会把
        // 「改成 .none」当成没变跳过,截屏时隐藏就不生效。
        window?.sharingType = captureHidden ? .none : .readWrite
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
        recomputeGeometry(animate: false, contentWidth: contentWidth, expandedContentWidth: expandedContentWidth)
    }

    /// 上一次实际执行的显隐动作,updateActualVisibility 的判等守卫用。nil = 还没执行过。
    /// orderFrontRegardless 不是免费的(一次 WindowServer 重排序事务),而这个函数挂在
    /// 播放状态翻转/设置同步/镜像 syncAll 多条路径上,值没变就别重复叫。
    private var lastAppliedShouldShow: Bool?
    /// 「先收起再隐藏」的排队与作废:挂着的延迟隐藏 + 代数。任何一次重新求值出
    /// 「要显示」/「立刻隐藏」都让它作废(代数加一),到点时再核一遍代数与当下状态才真正
    /// orderOut。挂着期间 lastAppliedShouldShow 仍是 true——窗口确实还在屏幕上。
    private var pendingHideWork: DispatchWorkItem?
    private var hideGeneration = 0

    /// 「显示歌词」开关与无歌词收起两个输入都存好之后再算生效值,值没变不发布。
    private func applyShowsLyrics() {
        let shows = NotchVisibility.showsLyrics(setting: showsLyricsSetting,
                                                collapsedForNoLyrics: lyricsCollapsedForNoLyrics)
        if showsLyrics != shows { showsLyrics = shows }
    }

    private func updateActualVisibility(isPlayingNow: Bool) {
        // 跟随当前窗口:显示状态定下来之后同步要不要盯焦点屏(主实例才盯),换屏放在这一步执行完之后。
        defer {
            if pinnedScreenID == nil {
                shownApartFromFullScreen = NotchVisibility.shouldShow(
                    isVisible: isVisible, hideWhenNotPlaying: hideWhenNotPlaying, isPlaying: isPlayingNow,
                    alertHold: alertHold, coveredByFullScreen: false)
                syncActiveScreenTracking()
            }
        }
        // 该做哪一步由 Core 的 NotchVisibility 决定(selftest 覆盖),这里只执行。
        let shouldShow = NotchVisibility.shouldShow(isVisible: isVisible, hideWhenNotPlaying: hideWhenNotPlaying,
                                                    isPlaying: isPlayingNow, alertHold: alertHold,
                                                    coveredByFullScreen: coveredByFullScreen)
        let step = NotchVisibility.step(shouldShow: shouldShow, isVisible: isVisible,
                                        lastApplied: lastAppliedShouldShow, isVanished: isVanished,
                                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                        hasPendingHide: pendingHideWork != nil)
        switch step {
        case .show(let orderFront, let replayReveal):
            // 中途又播放了:挂着的延迟隐藏作废。
            cancelPendingHide()
            // 先加出场动画计数再 orderFront / 翻 isVanished —— 同一事务里 SwiftUI 看到的第一帧就是裁剪到
            // 刘海宽的起始态,不会先满幅一帧。
            if replayReveal { revealGeneration &+= 1 }
            if orderFront {
                lastAppliedShouldShow = true
                Self.hoverLog.notice("window show replayReveal=\(replayReveal, privacy: .public)")
                // orderFrontRegardless(),不是 orderFront(nil)——这个 App 是 .accessory 策略、
                // 从不激活成前台 App,只有它能不看"当前是否是活跃 App"这个前提就把窗口调到最前。
                window?.orderFrontRegardless()
            }
            // 先 orderFront 再翻回 false:卡片在已经可见的窗口里从刘海撑开。顺序反了动画会在看不见的窗口里播完。
            if isVanished { isVanished = false }
            if vanishesFromCollapsed { vanishesFromCollapsed = false }
            return
        case .alreadyHidden:
            cancelPendingHide()
            return
        case .hideNow:
            cancelPendingHide()
            lastAppliedShouldShow = false
            if isVanished { isVanished = false }
            window?.orderOut(nil)
            resetHoverAfterHide()
            Self.hoverLog.notice("window hide")
            return
        case .keepPendingVanish:
            return
        case .startVanish:
            break
        }
        // 「暂停/无播放时隐藏」开着时先让整卡缩进刘海、再 orderOut(见 05 章设计决策 #17):isVanished 驱动
        // NotchWindowRoot 把整卡缩进刘海(NotchWindowRoot.vanishDuration),再等 vanishSettleDelay 三重校验后
        // orderOut。别做成"先播 0.45s 收起弹簧再走"——要的是不经过暂停状态,直接从正常大小缩小到无。
        // 截屏/录屏隐藏走的是 sharingType,不经这里。
        isVanished = true
        hideGeneration &+= 1
        let generation = hideGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingHideWork = nil
                // 到点时按当下重算,不信排队那一刻的结论:代数没被"又播放了/关掉了"作废过;
                // 开关与灵动岛仍开;平滑播放态仍是"没在放"。作废的那一路自己负责把 isVanished
                // 翻回去(shouldShow 分支 / 立刻隐藏分支),这里不动它。
                guard generation == self.hideGeneration else { return }
                let stillShow = NotchVisibility.shouldShow(
                    isVisible: self.isVisible, hideWhenNotPlaying: self.hideWhenNotPlaying,
                    isPlaying: PlaybackCoordinator.shared.isPlayingSmoothed, alertHold: self.alertHold,
                    coveredByFullScreen: self.coveredByFullScreen)
                if stillShow {
                    // 兜底:没人作废却又该显示了——别让一张缩成一点的卡片留在可见窗口里。
                    if self.isVanished { self.isVanished = false }
                    return
                }
                self.lastAppliedShouldShow = false
                self.window?.orderOut(nil)   // isVanished 保持 true:下次露面从刘海里长出来
                self.resetHoverAfterHide()
                Self.hoverLog.notice("window hide after vanish")
            }
        }
        pendingHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchWindowRoot.vanishSettleDelay, execute: work)
    }

    /// 窗口收走之后指针的「离开」事件不一定会来(点 ✕、暂停时隐藏,指针都还停在卡片上):不清的话下次露面
    /// 卡片直接停在展开态,要把指针移上去再移开才收回。
    private func resetHoverAfterHide() {
        pendingHoverWork?.cancel()
        pendingHoverWork = nil
        cardHovered = false
        editorialHovered = false
        syncCardCursor()
        clearTrackDrop()
        guard hoverExpanded else { return }
        hoverExpanded = false
        refreshExpanded()
    }

    private func cancelPendingHide() {
        hideGeneration &+= 1
        pendingHideWork?.cancel()
        pendingHideWork = nil
    }

    // 不加 private:设置页的灵动岛预览要用同一套刘海几何。
    //
    // 预览**只能**用这个 static 函数,绝不能去读 `.shared` 的属性 —— 见文件顶部那条
    // 不变量:引用 .shared 会执行 init() 把整扇窗建出来。这个函数不碰任何实例状态,拿它算几何是安全的。
    struct NotchGeometry {
        // 刘海本身(或无刘海屏幕的兜底值)的高度——这一整条永远只留纯黑背景,不放(唯一例外:NotchLyricsView.notchSeam 那枚故意让硬件挡住的彩蛋)
        // 任何文字/图标,常显内容行从这条高度往下才开始画,见 NotchLyricsView。
        let notchHeight: CGFloat
        let centerX: CGFloat
        // 刘海本身的真实宽度——无真刘海时为 0(没有需要横向避开的硬件区域,顶部这一行
        // 可以整条给按钮用)。
        let notchWidth: CGFloat
    }

    // 用 safeAreaInsets.top 判断这台屏幕有没有真刘海(>0 即有),用
    // auxiliaryTopLeftArea/auxiliaryTopRightArea(macOS 12 起的 API,这个项目部署
    // 目标是 14,肯定能用)量出刘海左右边界算出的真正中心点——不是简单假设刘海永远
    // 精确居中于整块屏幕,虽然实践中几乎总是如此。没有真刘海的屏幕退到固定兜底高度、
    // 水平居中于整块屏幕。
    static func geometry(for screen: NSScreen) -> NotchGeometry {
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            let centerX = (leftArea.maxX + rightArea.minX) / 2
            let notchWidth = rightArea.minX - leftArea.maxX
            // 顶行高度取 safeAreaInsets.top(贴紧真刘海),不跟菜单栏条高取大者:内建屏上两者差 1pt
            // (实测 32 / 33),多出的那 1pt(retina 上 2 个物理像素)落在刘海两侧的"耳朵"里,会平白盖掉一条
            // 系统状态图标 / 桌面内容;矮的那 1pt 落在菜单栏自己的材质范围内,看不出缝。
            return NotchGeometry(notchHeight: notchHeight, centerX: centerX, notchWidth: notchWidth)
        }
        // 无真刘海:黑条高度跟这块屏的菜单栏对齐,视觉上跟系统融为一体。
        return NotchGeometry(
            notchHeight: menuBarHeight(of: screen), centerX: screen.frame.midX, notchWidth: 0)
    }

    // 用户在设置里调的固定宽度(baseWidth,即 AppSettings.notchContentWidth)+ 耳朵下限
    // 两者取较大值——大多数情况下就是 baseWidth 本身,只有真刘海本身特别宽(实测约 179pt)、
    // 或者用户把 baseWidth 调得很小,把两只耳朵挤到摆不下按钮时才会突破 baseWidth(这层下限
    // 保护的是"按钮不被裁",不是"给歌词文字腾地方",不跟当前是哪句歌词、歌词有多长有任何关系)。
    // 不加 private:设置页的灵动岛预览要用同一个公式算宽度,否则设成小宽度时预览
    // 显示的是设定值、真窗口却被耳朵下限顶宽,两边对不上。
    ///
    /// contentTopInset:那块屏的顶行高度(= `geometry(for:).notchHeight`,真刘海屏是刘海本身
    /// 的高度、无刘海屏是菜单栏高度,见 geometry(for:) 里那段)。只有「封面」那一档用得到 ——
    /// 它的边长是这个值的函数。**不给估计值**是刻意的:拿 28pt(高菜单栏机器的上界)当常量,
    /// 在菜单栏 32 的屏上(封面 22pt)就白占 6pt/耳、卡片白宽 12pt。
    static func contentWidth(baseWidth: CGFloat, notchWidth: CGFloat,
                             leftEar: NotchEarModule, rightEar: NotchEarModule,
                             showsEqualizer: Bool, equalizerEar: NotchEqualizerEar,
                             contentTopInset: CGFloat) -> CGFloat {
        let earBasedFloor = notchWidth
            + minEarWidth(leftEar: leftEar, rightEar: rightEar,
                          showsEqualizer: showsEqualizer, equalizerEar: equalizerEar,
                          contentTopInset: contentTopInset) * 2
            + NotchMetrics.cardHorizontalPadding * 2
        return max(baseWidth, earBasedFloor)
    }

    /// 同上,耳朵/音浪配置**现读设置**。绝大多数调用点(几何重算、编辑台、菜单栏快捷面板)
    /// 要的就是"按当前配置",不必各自去取一遍。
    ///
    /// **`@Published` 的 willSet 窗口里不能用这个重载** —— 那时回读拿到的还是旧值
    /// (见 NotchMirrorManager.start() 里那段)。耳朵/音浪配置
    /// 变化那条路径必须走上面那个显式传参的版本,把 sink 收到的新值传下去。
    static func contentWidth(baseWidth: CGFloat, notchWidth: CGFloat,
                             contentTopInset: CGFloat) -> CGFloat {
        contentWidth(baseWidth: baseWidth, notchWidth: notchWidth,
                     leftEar: AppSettings.shared.notchLeftEar,
                     rightEar: AppSettings.shared.notchRightEar,
                     showsEqualizer: AppSettings.shared.notchShowsEqualizer,
                     equalizerEar: AppSettings.shared.notchEqualizerEar,
                     contentTopInset: contentTopInset)
    }

    /// 宽度滑杆真正能拖的区间:下界是这块屏、当前耳朵配置下的耳朵下限(设定值取存储层下界时的真实宽),规则在
    /// `NotchWidthBounds.usableRange(earFloor:)`。下界是屏幕和耳朵配置两者的函数(两只耳朵只配文字时约 252,配封面 256 / 296,
    /// 无刘海屏落到 200),每次现算;调用点要跟着耳朵配置重新求值(编辑台、菜单栏快捷面板观察 AppSettings,真窗口靠
    /// `$notchLeftEar` / `$notchRightEar` 那两条订阅)。耳朵配置现读设置,`@Published` 的 willSet 窗口里别用。
    static func usableWidthRange(notchWidth: CGFloat, contentTopInset: CGFloat) -> ClosedRange<Double> {
        NotchWidthBounds.usableRange(earFloor: Double(contentWidth(
            baseWidth: CGFloat(NotchWidthBounds.storageRange.lowerBound), notchWidth: notchWidth,
            contentTopInset: contentTopInset)))
    }

    // 灵动岛贴哪块屏。
    //
    // 用户在设置里指定了某块屏(存的是显示器 UUID,见 ScreenIdentity)就用那块;没指定
    // (或者指定的那块现在没接着——拔了、合盖了)就自动挑**真的有刘海**的那块,再没有
    // 就退回 NSScreen.main。
    //
    // 别直接用 NSScreen.main:它跟着**键盘焦点**跳,而 recomputeGeometry 只在少数几个时机重算,
    // 最后一次重算时焦点碰巧在哪块屏,窗口就一直停在哪块屏 —— 外接屏排在内置屏上方时,灵动岛会停在
    // 没有刘海的外接屏顶部,用户在内置屏上怎么找都找不到。
    // 不加 private:设置页预览要跟真窗口取同一块屏(纯静态、不碰实例状态,安全)。
    static func targetScreen() -> NSScreen? {
        // 跟随当前窗口:贴主实例跟到的那块屏(还没跟过、那块屏没了就按「自动」),不看指定的屏。
        if AppSettings.shared.notchFollowsActiveScreen && !AppSettings.shared.notchAllScreens {
            if let id = NotchFollowedScreen.shared.id, let followed = ScreenIdentity.screen(withID: id) {
                return followed
            }
        } else if let pinned = ScreenIdentity.screen(withID: AppSettings.shared.notchScreenID) {
            return pinned
        }
        // 没有刘海时取主屏(`screens.first`,带菜单栏的那块),不取 `NSScreen.main`:后者跟着键盘焦点跳,
        // 几何一重算灵动岛就换到焦点那块屏,开着「全部屏幕」时还会跟那块屏上的副本叠在一起。
        return ScreenIdentity.notched ?? NSScreen.screens.first
    }

    /// 主实例的 `notchScreenID` 变了(init 里那条订阅,主队列下一拍):挪到新屏,按新屏重判全屏遮挡。
    private func applyScreenSetting() {
        recomputeGeometry(animate: false)
        refreshFullScreenCover()
    }

    // MARK: - 显示在:跟随当前窗口

    private func setFollowsActiveScreen(_ on: Bool) {
        followsActiveScreen = on
        activeScreen.reset()
        if !on, NotchFollowedScreen.shared.id != nil {
            NotchFollowedScreen.shared.id = nil
            applyScreenSetting()
        }
        syncActiveScreenTracking()
    }

    /// 跟随开着、灵动岛该摆着(不算全屏时隐藏)时才盯焦点屏:关着、暂停时隐藏时不用每秒列一遍窗口;只因全屏藏着时照盯,
    /// 焦点换到别的屏就搬过去、在那块屏上摆出来。见 05 章决策 86。
    private func syncActiveScreenTracking() {
        activeScreen.update(wanted: followsActiveScreen && shownApartFromFullScreen)
    }

    /// 跟到了这块屏:记下来(targetScreen 读它),换了屏才重算几何、重判全屏遮挡;`force`(刚开始跟、屏幕参数变了)也重算。
    private func followActiveScreen(_ screen: NSScreen, force: Bool) {
        guard let id = ScreenIdentity.id(of: screen) else { return }
        guard force || NotchFollowedScreen.shared.id != id else { return }
        NotchFollowedScreen.shared.id = id
        applyScreenSetting()
    }

    /// 窗口换了屏(设置里改屏幕、插拔显示器)时按现值重判一次;开关或全屏表变化走 init 里全屏那条订阅。
    /// 这几个时机开关不在变化中,读存储值是稳定的。
    private func refreshFullScreenCover() {
        applyFullScreenCover(enabled: AppSettings.shared.notchHideInFullScreen,
                             displays: FullScreenSpaceMonitor.shared.fullScreenDisplays)
    }

    private func applyFullScreenCover(enabled: Bool, displays: Set<String>) {
        let screen = resolvedScreen()
        let covered = FullScreenSpaces.covers(
            screenID: screen.flatMap(ScreenIdentity.id(of:)),
            isMainScreen: screen != nil && screen == NSScreen.screens.first,
            fullScreenDisplays: displays)
        let hide = NotchVisibility.fullScreenHides(enabled: enabled, coveredByFullScreenApp: covered)
        guard hide != coveredByFullScreen else { return }
        coveredByFullScreen = hide
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    /// 这个实例贴哪块屏:副本贴它被钉的那块,主实例走全局的 targetScreen()。
    ///
    /// 副本被钉的屏拔掉时返回 nil,recomputeGeometry 直接 return —— 窗口维持原样不动。
    /// 这是刻意的:真正的清理由 NotchMirrorManager 在屏幕配置变化时做(它会把这个实例
    /// 整个销毁),这里再自作主张挪一次位置只会让窗口在被销毁前先闪到别的屏上去。
    private func resolvedScreen() -> NSScreen? {
        if let pinnedScreenID {
            return ScreenIdentity.screen(withID: pinnedScreenID)
        }
        return Self.targetScreen()
    }

    /// 副本建出来、或「灵动岛歌词」总开关翻转时,由 NotchMirrorManager 调:按当前偏好整体同步一遍。之后自动隐藏、宽度的变化
    /// 由每个实例自己的订阅接着(init)。
    ///
    /// `notchEnabled` 是给总开关那条 sink 用的:@Published 在 willSet 时机发布,sink 里回读 AppSettings 拿到的是**旧值**。
    /// 屏幕插拔这类时机传 nil 回读即可。各写入点判等,值没变不广播 objectWillChange。
    func syncStateFromSettings(notchEnabled: Bool? = nil) {
        let settings = AppSettings.shared
        let visible = notchEnabled ?? settings.notchOverlayEnabled
        if isVisible != visible { isVisible = visible }
        assignHideWhenNotPlaying(settings.notchHideWhenNotPlaying)
        // sharingType 直接写、不判等,理由见 applyBehaviorSettings。
        window?.sharingType = settings.notchHideDuringScreenCapture ? .none : .readWrite
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
        recomputeGeometry(animate: false)
        refreshFullScreenCover()
    }

    /// 副本销毁前调:先把窗口收走,再断掉订阅,最后**破掉保留环**。
    ///
    /// 最后两行不是可选的清理,是释放的前提:
    /// controller.hostingView 强持 NSHostingView,其 rootView(NotchWindowRoot)的
    /// @ObservedObject controller 又强持回来 —— 教科书式两节点保留环。NotchMirrorManager
    /// 把 mirrors[id] 置 nil 后没人再引用这套对象,但环内互持,整套 NSPanel + SwiftUI 树
    /// (还可能钉着一张旧封面)永久泄漏,且泄漏树仍挂在 PlaybackCoordinator/AppSettings/
    /// NotchTransientCenter 的 objectWillChange 扇出里;拔屏/合盖/开关「所有屏幕」的
    /// 插拔循环会无界累积。断开 contentView/hostingView 这一向,环即解体。
    /// (主实例 .shared 是有意常驻的单例、从不 teardown,不受影响。)
    func teardown() {
        cancelPendingHide()
        ListenMilestoneCenter.shared.unregisterSurface(self)
        pendingShrinkWork?.cancel()
        pendingShrinkWork = nil
        window?.orderOut(nil)
        releaseCardCursor()
        subscriptions.removeAll()
        setEditorialDemand(false)
        NotchEditorialPanel.shared.close(ifOwner: window)
        revealGate.cancel()
        stopRevealWait()
        clearTrackDrop()
        if let screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
            self.screenParamsObserver = nil
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        pendingHoverWork?.cancel()
        pendingHoverWork = nil
        window?.contentView = nil
        hostingView = nil
    }

    // 顶边固定贴在屏幕最顶端(screen.frame.maxY)、水平居中对齐刘海中心点、总高度 =
    // 刘海高度 + 内容行高度(hover 展开时再加 expandedExtraHeight)、宽度 = 展开宽(稳态宽见
    // contentWidth(baseWidth:notchWidth:),展开宽在它之上再取 NotchWidthBounds.expandedWidth)。
    // 这个函数跟播放状态无关(isCollapsed 是计算属性,见那边的注释)。
    /// 几何入参:非 nil = 调用方正处于对应那个 `@Published` 的 willSet 窗口(镜像 sink 那条路、左右耳/
    /// 音浪/展开态那几条 sink),必须用传入值;nil = 回读存储值(设置页滑杆对 .shared 的
    /// 调用发生在赋值语句之后,以及 init/屏幕插拔这些时机,存储值都是稳定的)。contentWidth /
    /// expandedContentWidth / leftEar / rightEar / showsEqualizer / equalizerEar 只影响宽度
    /// (`Self.contentWidth(...)` 与 `NotchWidthBounds.expandedWidth`),`expandedShows*` /
    /// `expandedTrackInfoShows*` 只影响 `self.expandedExtraHeight(...)`(高度),两组互不相干,别混着传。
    private func recomputeGeometry(animate: Bool, contentWidth: CGFloat? = nil,
                                   expandedContentWidth: CGFloat? = nil,
                                   leftEar: NotchEarModule? = nil,
                                   rightEar: NotchEarModule? = nil,
                                   showsEqualizer: Bool? = nil,
                                   equalizerEar: NotchEqualizerEar? = nil,
                                   expandedShowsNextLine: Bool? = nil,
                                   expandedShowsControls: Bool? = nil,
                                   expandedTrackInfoShowsArtwork: Bool? = nil,
                                   expandedTrackInfoShowsTitle: Bool? = nil,
                                   expandedTrackInfoShowsArtist: Bool? = nil,
                                   expandedTrackInfoShowsAlbum: Bool? = nil,
                                   expandedShowsQuickActions: Bool? = nil) {
        guard let window, let screen = resolvedScreen() else { return }
        let geo = Self.geometry(for: screen)
        // 四个 @Published 全部判等再写:这个函数挂在设置同步/屏幕插拔/镜像
        // syncAll 多条路径上,绝大多数调用几何根本没变,不判等就是每次白发四条
        // objectWillChange 打醒整卡视图树。
        if contentTopInset != geo.notchHeight { contentTopInset = geo.notchHeight }
        if notchWidth != geo.notchWidth { notchWidth = geo.notchWidth }
        // 兜底同样读缓收版:收缩判定必须跟上面的可见性判定同一口径,否则会出现
        // "窗口还在但已经缩成刘海"或反过来的错配。
        // isCollapsed 是从 isPlayingNow/isExpanded 现算的计算属性,这里不算。几何重算只管刘海尺寸和卡片宽度。
        let newSteady = Self.contentWidth(
            baseWidth: contentWidth ?? AppSettings.shared.notchContentWidth,
            notchWidth: geo.notchWidth,
            leftEar: leftEar ?? AppSettings.shared.notchLeftEar,
            rightEar: rightEar ?? AppSettings.shared.notchRightEar,
            showsEqualizer: showsEqualizer ?? AppSettings.shared.notchShowsEqualizer,
            equalizerEar: equalizerEar ?? AppSettings.shared.notchEqualizerEar,
            contentTopInset: geo.notchHeight)
        if steadyCardWidth != newSteady { steadyCardWidth = newSteady }
        // 展开宽 = max(稳态真实宽, 展开设定)。稳态已经过耳朵下限,所以展开这边
        // 不必再算一遍下限;两个设定值的不变量「展开 ≥ 稳态」由 NotchWidthBounds 统一兜住,
        // 用户在快捷面板把稳态拖过展开也不会出现"hover 反而变窄"。
        let newExpanded = NotchWidthBounds.expandedWidth(
            steady: newSteady,
            expandedSetting: expandedContentWidth ?? CGFloat(AppSettings.shared.notchExpandedContentWidth))
        if expandedCardWidth != newExpanded { expandedCardWidth = newExpanded }
        // 窗口恒为**最大**形态(展开态)的尺寸,不随收起/稳态/展开三种形态改:三种形态是卡片在这个
        // 固定窗口里自己变大变小(NotchWindowRoot),窗口只在屏幕几何或宽度设置变化时才动。
        //
        // 多出来的那片区域必须保持纯透明、不能有任何命中形状 —— 它压在系统菜单栏上,
        // 详见 NotchWindowRoot 顶部那段(带实测结论)。
        // 窗口尺寸 = 展开态卡片本身,不留额外余量。宽度是**展开宽**而不是稳态宽
        // (两者可以不同):窗口比稳态卡片宽出来的那两截跟下方多出来的高度一样是纯透明区,
        // 点击穿透到底下的菜单栏,见上面那条提醒。
        //
        // 窗口跟卡片严丝合缝,所以卡片不带投影:阴影会被窗口的矩形边界硬裁,在底部两个圆角外侧留下
        // 直角残影。**要加投影就得同时给窗口加一圈余量**,两件事绑在一起,别只做一半。
        // 收听里程碑的报喜卡片(顶行 + milestonePanelHeight)加上它下沿落出去的碎屑(`milestoneConfettiReach`)在展开区很矮的配置下
        // 可能比展开态还高,取两者大的;多出来的是透明区,点击穿透。
        let size = NSSize(
            width: expandedCardWidth,
            // 歌词那一格按两种排法里高的那种留:这首有歌词、开着多行歌词时是列表,别的歌照旧是一行歌词。
            height: max(geo.notchHeight + max(lyricRowHeight, expandedLyricListHeight) + self.expandedExtraHeight(
                expandedShowsNextLine: expandedShowsNextLine,
                expandedShowsControls: expandedShowsControls,
                expandedTrackInfoShowsArtwork: expandedTrackInfoShowsArtwork,
                expandedTrackInfoShowsTitle: expandedTrackInfoShowsTitle,
                expandedTrackInfoShowsArtist: expandedTrackInfoShowsArtist,
                expandedTrackInfoShowsAlbum: expandedTrackInfoShowsAlbum,
                expandedShowsQuickActions: expandedShowsQuickActions),
                        geo.notchHeight + NotchMetrics.milestonePanelHeight + NotchMetrics.milestoneConfettiReach))
        // 必须先取成整点,规则跟 AppKit 自己对窗口 frame 做的一致(实测:原点向下取整、宽高
        // 向上取整)。刘海高度 `safeAreaInsets.top` 在部分机型 / 缩放档下带小数(如 33.5),
        // 不取整的话:① 下面的判等永远不等(window.frame 已被取整),每次调用都白做一次同步
        // 重绘;② contentView 被设回未取整的尺寸、贴着窗口左下角,顶边空出半点,灵动岛
        // 上方露出一条菜单栏细缝。hostFrame 也要用取整后的尺寸,两处一起改。
        let frame = NSRect(
            x: (geo.centerX - size.width / 2).rounded(.down),
            y: (screen.frame.maxY - size.height).rounded(.down),
            width: size.width.rounded(.up),
            height: size.height.rounded(.up)
        )
        // 判等同上:setFrame(display: true) 是一次同步重绘 + WindowServer 事务,几何没变
        // 时纯属白付(镜像 syncAll 的每次触达都会走到这里)。
        pendingShrinkWork?.cancel()
        pendingShrinkWork = nil
        let apply: () -> Void = { [weak self, weak window] in
            guard let self, let window else { return }
            if window.frame != frame { window.setFrame(frame, display: true, animate: animate) }
            let hostFrame = NSRect(origin: .zero, size: frame.size)
            if self.hostingView?.frame != hostFrame { self.hostingView?.frame = hostFrame }
        }
        // 变窄晚一点再缩:卡片宽度按弹簧收回(NotchWindowRoot.cardAnimation,约 0.45 秒),窗口当场缩的话这段时间卡片比窗口宽,
        // 两侧被窗口边界切成直边、圆角和肩膀不见。变宽当场变(卡片要往外长);窗口不在屏、减少动态效果(卡片不做动画)时也当场缩。
        // 只有原地变窄才等:换屏、挪位置的那一次要当场到位,不跟着晚半秒。
        let shrinking = frame.width < window.frame.width - 0.5
        let inPlace = abs(frame.midX - window.frame.midX) < 1.5 && abs(frame.maxY - window.frame.maxY) < 1.5
        if shrinking, inPlace, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let work = DispatchWorkItem(block: apply)
            pendingShrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.windowShrinkDelay, execute: work)
        } else {
            apply()
        }
    }

    /// 窗口缩窄排着的那一次(见 recomputeGeometry 末尾)。下一次重算先取消它。
    private var pendingShrinkWork: DispatchWorkItem?
    /// 比卡片那条最慢的弹簧(收起态 response 0.45)稍长。
    private static let windowShrinkDelay: TimeInterval = 0.5
}

/// 灵动岛「显示在:跟随当前窗口」此刻跟到的那块屏(屏幕身份串)。主实例写,`targetScreen()`、菜单栏正中、编辑台预览读;
/// nil = 没开或还没跟过。
@MainActor
final class NotchFollowedScreen: ObservableObject {
    static let shared = NotchFollowedScreen()
    @Published fileprivate(set) var id: String?
}
