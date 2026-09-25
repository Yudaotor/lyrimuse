import SwiftUI
import Combine
import LyrimuseCore

/// 悬浮歌词的**窄订阅代理**(性能审计落地,照「歌词管理」LiveRowPlayback 的
/// 既有模式):PlaybackCoordinator 有 30+ 个 @Published、AppSettings 有 40+ 个,而
/// ObservableObject 的 objectWillChange 不分字段 —— 悬浮窗原来整对象订阅这两个单例,
/// 歌词窗口拖音量滑杆(soundVolume)、灵动岛/歌词窗口专属的封面与统计、设置页那几个
/// 与悬浮窗无关的宽度滑杆,每一次写入都会打醒它整个 body。这里只转发悬浮窗真正读的
/// 字段,值类型一律 removeDuplicates。
///
/// sink 里只能用收到的参数值,不能回读源属性 —— @Published 在 willSet 时机发布,
/// 回读拿到的是上一拍的旧值(本仓在 hideWhenNotPlaying 上实测踩过)。
///
/// anchor / currentLyricsOffsetMs 故意**不在**这里:它们只被 TimelineView 的每帧闭包
/// 消费,闭包按帧重跑、自己直读 PlaybackCoordinator.shared 就是最新值;订阅只会让
/// 重锚/校准这类事件多打醒一次整个 body(同 LiveRowPlayback 对 anchor 的处理)。
@MainActor
private final class OverlayPlayback: ObservableObject {
    /// lyricsCard 的水平内边距。算可用宽度要减掉它,所以提成常量、别在两处各写一遍 20。
    static let cardHorizontalPadding: CGFloat = 20

    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var currentLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?
    // 下一句摆哪一边,见 PlaybackCoordinator 同名属性的注释——独立于 currentLine.side。
    @Published private(set) var nextLineSide: LyricDuet.Side?
    // 下一行的罗马音/译文,见 PlaybackCoordinator 同名属性的注释——currentLine 为 nil 时
    // (前奏/间奏「•••」下方)那句其实是接下来的第一句本身,靠它们按正常行的规格展示。
    @Published private(set) var nextLineRomanization: String?
    @Published private(set) var nextLineTranslation: String?
    /// 下一行的逐词分组,只在 `currentLine` 为 nil(前奏/间奏「•••」下方)时用来把罗马音逐词标在
    /// 那句底下。跟 `currentLine` 同一道「卡拉OK效果」闸:关着时当前行压成整行、不带分组,这里一起清。
    @Published private(set) var nextLineWordGroups: [SyncedLyricWordGroup]?
    /// 当前行的显示窗口(`LyricDisplayWindow`,跟 `PlaybackCoordinator.currentLineDwellSeconds` 同一份)。
    /// 滚动模式下没有逐字时间轴的行、以及当前行的译文 / 罗马音按它配速(`OverlayScrollingLyricRow.PacedWindow`)。
    @Published private(set) var currentLineWindow: OverlayScrollingLyricRow.PacedWindow?
    @Published private(set) var isPlayingNow = false
    /// 此刻有没有曲目。false = 停播/播放器没开/刚装好还没放过歌 —— 停播时
    /// `LocalPlaybackSource.clearIfWasPlaying` 会把 title/artist 连同几个"这首歌"的判定一起清空。
    /// 判据照抄灵动岛 `NotchLyricsWindowController.hasTrack`(title 或 artist 非空、或正在广告插播):
    /// 广告那一档必须算"有曲目",否则 Spotify 广告期间 title/artist 都空的话会画成品牌标记而不是「广告中」。
    /// 只订阅折算后的这一个 Bool、不订阅标题本身:换歌时标题变了但"有曲目"没变,不该打醒 body。
    @Published private(set) var hasTrack = false
    @Published private(set) var isFavorited: Bool?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    /// 电台口白:这一刻在放的不是歌,台里在说话。语义与 `isCurrentTrackAdBreak` 平行。
    @Published private(set) var isRadioTalkBreak = false
    @Published private(set) var currentLineFillSettled = true
    /// 间奏「•••」呼吸圆点(见 LyricsGapDotsView)的窗口边界——**不设门槛**的版本
    /// (`PlaybackCoordinator.rawGapWindow`),不是歌词窗口那份 `lyricsGapMarkers`。悬浮窗
    /// 没有"沿用上一行继续显示"这条退路,`currentLine` 一旦为 nil 就必须画点什么,门槛版
    /// (5s 前奏 / 6s 间奏起标)会把没达标的那几秒晾成静态「♪」,而没达标的短前奏/短间奏
    /// 比达标的场景常见得多。
    @Published private(set) var rawGapWindow: LyricsGapWindow?
    /// 悬浮歌词实际显示用的前景色 —— 语义同 PlaybackCoordinator.displayForegroundColor
    /// (那份保留给设置页预览等别处),这里预组合成单个去重值:三个输入(动态高亮色/
    /// "跟随封面"开关/手选前景色)任何一个变了才发一次。
    @Published private(set) var displayForegroundColor: Color = .white
    // ---- 来自 AppSettings(只挑悬浮窗读的这一小片) ----
    @Published private(set) var lockPosition = false
    /// 指针划过时让开(见 AppSettings.overlayFadeOnHover)。
    @Published private(set) var fadeOnHover = false
    /// 位置模式(见 AppSettings.overlayPlacementMode)。视图只关心一件事:内容块在窗口里
    /// 贴顶还是贴底(`.bottomCenter` 贴底,其余贴顶),见 body 末尾那条 `.frame(alignment:)`。
    @Published private(set) var placementMode: OverlayPlacementMode = .free
    @Published private(set) var showRomanization = true
    @Published private(set) var showTranslation = false
    @Published private(set) var showNextLinePreview = true
    @Published private(set) var duetAlignmentOverride: OverlayDuetAlignmentOverride = .automatic
    /// 一行放不下时换行还是滚动(见 `OverlayLineOverflow`)。
    @Published private(set) var lineOverflow: OverlayLineOverflow = .wrap
    /// 滚动模式下一行要占多高 = 字本身(`scrollTextHeight`)+ 描边那圈预留(`scrollStrokePadding`)。
    ///
    /// 滚动行必须显式定高:`MarqueeText` 的外壳是 `GeometryReader`,没有固有高度,不定高会在卡片的
    /// VStack 里跟别的行平分高度、互相重叠。
    /// 描边那圈不能漏:内容套了 `lyricsTextStroke`,四周各多出 `LyricsTextStrokeMetrics.inset`,
    /// 框只给字高的话描边上下沿会被裁掉。
    func scrollRowHeight(_ font: NSFont) -> CGFloat {
        scrollTextHeight(font) + scrollStrokePadding
    }

    /// 一行字本身的高度:`ascender − descender + leading`,再留 2pt 接住 g/q 的下伸部分
    /// (同 `MenuBarMarqueeRenderer.lineHeight`)。`OverlayLyricScrollView.textHeight` 必须是同一个式子。
    func scrollTextHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 2
    }

    /// 描边开着时一行上下两份预留加起来多高;关着为 0。
    var scrollStrokePadding: CGFloat {
        textStrokeEnabled ? LyricsTextStrokeMetrics.inset * 2 : 0
    }

    @Published private(set) var mainFont: Font = .system(size: 20, weight: .bold)
    /// `mainFont` 背后那个原始磅值——`Font` 本身取不回数字,间奏点按字号比例算尺寸
    /// (跟歌词窗口的 `lyricFontSize` 同一用途)得单独接一份。
    @Published private(set) var mainFontSize: CGFloat = 20
    @Published private(set) var romanizationFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var translationFont: Font = .system(size: 14, weight: .regular)
    @Published private(set) var previewFont: Font = .system(size: 14, weight: .medium)
    @Published private(set) var textStrokeEnabled = false
    @Published private(set) var textStrokeColor: Color = .black.opacity(0.65)
    /// 卡拉OK"未唱到"那一段实际显示用的颜色——跟 displayForegroundColor
    /// 完全对称的一对:「跟随封面」开着且这首歌已算出动态高亮色时用它,否则退回用户手选的
    /// 固定未唱色。两者是独立的颜色,不是同一个值的两种状态。
    @Published private(set) var displayKaraokeUnsungColor: Color = .white.opacity(0.35)
    @Published private(set) var backgroundIsVisible = false
    @Published private(set) var backgroundColor: Color = .clear
    /// 悬浮歌词背景毛玻璃,见 AppSettings.overlayBackgroundGlass。
    @Published private(set) var backgroundGlass = false
    /// 毛玻璃「浓淡」,见 AppSettings.overlayGlassIntensity / OverlayGlassIntensity。
    @Published private(set) var backgroundGlassIntensity: OverlayGlassIntensity = .regular
    /// 对唱行两侧留白的基准量(见 LyricDuetLayout)。窗宽和字号都会影响它,所以在这里
    /// 预组合成一个去重值 —— 免得视图为了算这一个数字去订阅两个高频设置。
    @Published private(set) var duetInsetUnit: CGFloat = 0
    /// 对唱舞台两侧各让出的量(见 OverlayCardGeometry.duetStageInset):窗口比
    /// 默认宽时左右声部只在正中一条带里分栏,多出来的宽度留给长句。同样由窗宽和字号预组合。
    @Published private(set) var duetStageInset: CGFloat = 0
    /// 卡片内容块拿得到的宽度 = 窗宽 − 两侧 20pt 卡片内边距。上面两个量的共同分母,
    /// 视图还要拿它跟"这一行不换行要多宽"相减,算出两侧留白能吃掉多少富余
    /// (见 `LyricsOverlayView.duetInsetScale`)。
    @Published private(set) var cardAvailableWidth: CGFloat = 0
    /// 四行字体的 AppKit 孪生,测宽用(见 `OverlayNaturalWidth`)。
    @Published private(set) var overlayNSFonts = OverlayNSFonts()
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            // 「卡拉OK效果」关着时把行压成整行(`SyncedLyricLine.lineLevel`):这一面的
            // 逐字填色、逐词罗马音标注都在下游按 `line.words` / `line.wordGroups` 走,压成整行之后
            // 它们自然走"这首歌没有逐字数据"那条路,渲染分支一处不用改。开关翻面也会重新发一次
            // 当前行,所以正在显示的那句当场变(不用等换行)。歌词窗口不经这里、始终逐字。
            Publishers.CombineLatest(p.$currentLine, s.$overlayLyricsKaraoke)
                .map { line, karaoke in karaoke ? line : line?.lineLevel }
                .removeDuplicates()
                .sink { [weak self] in self?.currentLine = $0 },
            p.$nextLineText.removeDuplicates().sink { [weak self] in self?.nextLineText = $0 },
            p.$nextLineSide.removeDuplicates().sink { [weak self] in self?.nextLineSide = $0 },
            p.$nextLineRomanization.removeDuplicates().sink { [weak self] in self?.nextLineRomanization = $0 },
            p.$nextLineTranslation.removeDuplicates().sink { [weak self] in self?.nextLineTranslation = $0 },
            Publishers.CombineLatest3(p.$currentLineIndex, p.$allLines, p.$currentDurationMs)
                .map { index, lines, duration -> OverlayScrollingLyricRow.PacedWindow? in
                    LyricDisplayWindow.of(index: index, starts: lines.lazy.map(\.timeMs), trackDurationMs: duration)
                        .map { .init(startMs: $0.startMs, dwellMs: $0.dwellMs) }
                }
                .removeDuplicates()
                .sink { [weak self] in self?.currentLineWindow = $0 },
            Publishers.CombineLatest(p.$nextLineWordGroups, s.$overlayLyricsKaraoke)
                .map { groups, karaoke in karaoke ? groups : nil }
                .removeDuplicates()
                .sink { [weak self] in self?.nextLineWordGroups = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            // CombineLatest3 而不是三个独立 sink:三个输入要**同时**拿到才能算,独立 sink 里另两个
            // 只能回头读存储属性 —— 正是本文件头注说的 willSet 旧值坑(灵动岛那份同款写法)。
            Publishers.CombineLatest3(p.$title, p.$artist, p.$isCurrentTrackAdBreak)
                .map { title, artist, isAd in !title.isEmpty || !artist.isEmpty || isAd }
                .removeDuplicates()
                .sink { [weak self] in self?.hasTrack = $0 },
            p.$isFavorited.removeDuplicates().sink { [weak self] in self?.isFavorited = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$isRadioTalkBreak.removeDuplicates().sink { [weak self] in self?.isRadioTalkBreak = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$rawGapWindow.removeDuplicates().sink { [weak self] in self?.rawGapWindow = $0 },
            Publishers.CombineLatest3(p.$artworkAccentColor, s.$followsCoverArt, s.$foregroundColor)
                .map { accent, follows, fg in (follows ? accent : nil) ?? fg }
                .removeDuplicates()
                .sink { [weak self] in self?.displayForegroundColor = $0 },
            s.$lockPosition.removeDuplicates().sink { [weak self] in self?.lockPosition = $0 },
            s.$overlayFadeOnHover.removeDuplicates().sink { [weak self] in self?.fadeOnHover = $0 },
            s.$overlayPlacementMode.removeDuplicates().sink { [weak self] in self?.placementMode = $0 },
            s.$showRomanization.removeDuplicates().sink { [weak self] in self?.showRomanization = $0 },
            s.$showTranslation.removeDuplicates().sink { [weak self] in self?.showTranslation = $0 },
            s.$showNextLinePreview.removeDuplicates().sink { [weak self] in self?.showNextLinePreview = $0 },
            s.$overlayDuetAlignmentOverride.removeDuplicates().sink { [weak self] in self?.duetAlignmentOverride = $0 },
            s.$overlayLineOverflow.removeDuplicates().sink { [weak self] in self?.lineOverflow = $0 },
            s.$mainFont.removeDuplicates().sink { [weak self] in self?.mainFont = $0 },
            s.$fontSize.map { CGFloat($0) }.removeDuplicates().sink { [weak self] in self?.mainFontSize = $0 },
            s.$romanizationFont.removeDuplicates().sink { [weak self] in self?.romanizationFont = $0 },
            s.$translationFont.removeDuplicates().sink { [weak self] in self?.translationFont = $0 },
            s.$previewFont.removeDuplicates().sink { [weak self] in self?.previewFont = $0 },
            s.$textStrokeEnabled.removeDuplicates().sink { [weak self] in self?.textStrokeEnabled = $0 },
            s.$textStrokeColor.removeDuplicates().sink { [weak self] in self?.textStrokeColor = $0 },
            // 跟随封面时**不能**直接给 accent 本身:已唱色(displayForegroundColor)在
            // 跟随封面时同样是这个 accent,原样传出去的话两段会是完全相同的颜色,卡拉OK的
            // 进度效果直接消失。这里补一次 dimOpacity,复现"未唱比已唱调暗"的观感,只是源头
            // 从固定 fg 换成了动态 accent。固定色(fixed,没开跟随封面时手选或迁移种下的那个)
            // 已经在存的时候就带着期望的深浅,不再额外调暗。
            Publishers.CombineLatest3(p.$artworkAccentColor, s.$karaokeUnsungFollowsCoverArt, s.$karaokeUnsungColor)
                .map { accent, follows, fixed in
                    (follows ? accent?.opacity(WordKaraokeGradient.dimOpacity) : nil) ?? fixed
                }
                .removeDuplicates()
                .sink { [weak self] in self?.displayKaraokeUnsungColor = $0 },
            s.$backgroundIsVisible.removeDuplicates().sink { [weak self] in self?.backgroundIsVisible = $0 },
            s.$backgroundColor.removeDuplicates().sink { [weak self] in self?.backgroundColor = $0 },
            s.$overlayBackgroundGlass.removeDuplicates().sink { [weak self] in self?.backgroundGlass = $0 },
            s.$overlayGlassIntensity.removeDuplicates().sink { [weak self] in self?.backgroundGlassIntensity = $0 },
            // 内缩基准:可用宽度 = 窗宽 − 两侧 20pt 内边距(见 lyricsCard 的 padding)。
            s.$overlayWidth.combineLatest(s.$fontSize)
                .map { width, font in
                    LyricDuetLayout.insets(
                        for: .leading,
                        availableWidth: CGFloat(width) - Self.cardHorizontalPadding * 2,
                        fontSize: CGFloat(font)
                    ).trailing
                }
                .removeDuplicates()
                .sink { [weak self] in self?.duetInsetUnit = $0 },
            // 对唱舞台:同一份可用宽度和字号,算舞台在卡片里居中后两侧各让出多少。
            s.$overlayWidth.combineLatest(s.$fontSize)
                .map { width, font in
                    OverlayCardGeometry.duetStageInset(
                        availableWidth: CGFloat(width) - Self.cardHorizontalPadding * 2,
                        fontSize: CGFloat(font))
                }
                .removeDuplicates()
                .sink { [weak self] in self?.duetStageInset = $0 },
            s.$overlayWidth
                .map { CGFloat($0) - Self.cardHorizontalPadding * 2 }
                .removeDuplicates()
                .sink { [weak self] in self?.cardAvailableWidth = $0 },
            s.$overlayNSFonts.removeDuplicates().sink { [weak self] in self?.overlayNSFonts = $0 },
        ]
    }
}

// 悬浮窗内容:逐字高亮时用渐变扫过效果(近似网页版 CSS 渐变裁字的视觉,不追求逐像素
// 还原),否则整行高亮;罗马音在上、译文在下,都是可选的小字。
//
// 换行不做任何动画(纯属性跳变,不经过 SwiftUI 动画事务),逐字填色用 TimelineView
// 按渲染帧频直接从播放位置现算 fillFraction(不经过 Timer 采样+插值)——两者都是为了
// 尽可能流畅、开销尽可能小,具体机制见下面 mainLine/wordText 的注释。
/// `LyricsOverlayView` 需要从"承载它的那个东西"那里知道的全部状态 —— 四个只读量加一次回调。
///
/// 抽成协议是为了让**同一份视图**既能装进真窗口,也能装进设置页那块编辑台
/// (`OverlayEditorStage`),照灵动岛 `NotchChromeSource` 的先例。编辑台原来画的是另一份
/// 刻意简化的渲染(`OverlayLyricsCanvas`,已删:只有主歌词一行,没有译文/罗马音/
/// `WrapLayout` 换行/下一句预览/对唱分声部与声部指示),两份渲染必然越漂越远 —— 而"漂"在设置页预览上
/// 是致命的:它存在的全部意义就是所见即所得。本仓已经为"同一个视觉属性两条渲染路径"付过
/// 两次账(「对齐方式」在预览条上失效并且修好后又回归;灵动岛手搓预览跟真卡差了一整排
/// 元素),这是第三次,也是最后一次 —— 编辑台从此渲染的就是真视图本身。
///
/// 预览侧**绝不能**拿 `LyricsOverlayWindowController.shared` 来凑这几个属性:那是个
/// `static let`,光是读一下属性就会执行 init() 建窗口并 orderFront —— 悬浮歌词关着的用户
/// 一打开设置页就会凭空多出一扇(不可见但已经装好监听器的)窗。编辑台用的是不建窗的
/// `OverlayPreviewChrome`(见 OverlayEditorStage.swift),这跟 `NotchPreviewChrome` 存在的
/// 理由是同一条。
@MainActor
protocol OverlayChromeSource: ObservableObject {
    /// 指针压在**歌词或控制排**上 —— 播放控制排(或锁定态的解锁提示)的显示条件。
    /// 从"指针在窗口上"收紧,命中区见 `OverlayControlHitTest.chromeHoverZone`。
    var isHoveringForControls: Bool { get }
    /// 指针压在**歌词文字**上 —— 「指针划过时让开」的命中判据。跟上面那个的区别是它**不**
    /// 把控制排并进来:让开是为了看清歌词底下那块桌面,指针停在按钮排上时歌词不该跟着淡掉。
    var isHoveringLyrics: Bool { get }
    /// 指针压在**控制排本身**上(播放控制胶囊,或锁定态那颗解锁按钮)。跟上面那个
    /// `isHoveringForControls` 是两件事:那个决定"要不要显示",这个决定"能不能
    /// 让它横向换边" —— 用户正瞄着按钮时把落点冻住,见 `OverlayControlsSidePin`。
    var isHoveringControlPill: Bool { get }
    /// 指针此刻压在**哪一颗**按钮上(nil = 一颗都没压着),用来画悬停高亮。判据在
    /// `OverlayControlHitTest.hoveredControl`,值由真窗口的全局鼠标监听器发布 ——
    /// 窗口常年点击穿透,`.onHover` 收不到事件(同这排按钮的点击为什么要由控制器分发)。
    var hoveredControl: OverlayControlID? { get }
    /// 长按拖动已经"武装",画一圈跟前景色同色的高亮描边。
    var isDragArmed: Bool { get }
    /// 第一次解锁「锁定位置」时短暂弹一次的手势提示。
    var showDragHint: Bool { get }
    /// 通用的瞬态提示文字(全局快捷键的操作回声:"歌词偏移 +0.50s"、"已锁定位置"…)。
    /// nil = 此刻没有要显示的。跟 `showDragHint` 共用同一个显示位,同时有内容时它优先
    /// —— 它是用户**刚刚按了键**的直接回声,那条一次性手势提示可以等下次。
    var transientHint: String? { get }
    /// 预设模式(顶部 / 底部居中)下用户想拖窗口被拒时,控制排槽位里那条「🔒 已固定为…」胶囊的
    /// 文字;nil = 不显示。真窗口在 `armDragIfStillPressed` 里设、2.4 秒后清。
    var placementLockNotice: String? { get }
    /// 同一事件的抖动计数:每被拒一次 +1,视图据此让歌词卡左右抖一下(`OverlayRejectShake`)。
    var placementLockShakeTick: Int { get }
    /// 控制排该不该画在卡片**下方**(而不是常规的上方)。真窗口按「顶部居中」预设 / 自由拖动时
    /// 是否顶到可见区顶边动态算,见 `LyricsOverlayWindowController.recomputeControlsBelowCard`;
    /// 编辑台预览没有真实屏幕位置,只跟着预设走。
    var controlsBelowCard: Bool { get }
    /// 悬停时露不露出那排播放控制按钮。真窗口是 `AppSettings.overlayShowHoverControls` 的
    /// **滞后**镜像(悬停中改了先攒着,等这次悬停结束才生效,见
    /// `LyricsOverlayWindowController.showHoverControls` 声明处);编辑台预览没有真实悬停,
    /// 直接跟原始设置值同步。
    var showHoverControls: Bool { get }
    /// 播放控制排刚露出来。真窗口借这一下重读一次「喜欢」状态 —— 那要起一个 osascript
    /// 子进程,所以做成回调而不是让视图直接打 `PlaybackCoordinator`:设置页预览必须能把
    /// 这条副作用空实现掉(同 `NotchChromeSource.setExpanded` 的处理)。
    func controlsDidBecomeVisible()
}

/// 设置页预览用的示例行 —— **真窗口恒传 nil**,排版逐像素不变。
///
/// 为什么要它:没在播放(或这首歌还没解析出歌词)时,真视图走的是 `mainLine` 的占位分支
/// (♪ /「搜索歌词中…」/「暂无歌词」),搬进设置页就是一张几乎空的卡 —— 而"改文字色/
/// 字体/描边能当场看见"正是那块预览存在的全部理由(这是共用画布当初带示例句的原因,
/// 换成真视图之后得由真视图自己提供同一个能力)。
///
/// 带上译文/罗马音/下一句三条示例文字,是为了让那三个显隐开关在**没歌放**的时候也能当场
/// 看出效果 —— 它们各有独立的字号和不透明度,是这一页最难凭想象判断的几项。
struct OverlayPreviewLine {
    var line: SyncedLyricLine
    /// 下一句预览的文字。它在真窗口来自 `PlaybackCoordinator.nextLineText`、不在
    /// `SyncedLyricLine` 里,所以这里单独带一份。
    var nextLineText: String?
}

/// 对唱声部指示(圆点 + 细竖线)的两个几何常量。
///
/// 单独抽成一个类型、而不是留在 `LyricsOverlayView` 里当 `private static let`:那个视图
/// 泛型化之后(见 `OverlayChromeSource`),Swift 不允许泛型类型持有 static
/// **存储**属性。数值和取舍一个字没变,只是换了个落脚点。
private enum OverlaySpeakerIndicator {
    /// 指示条的固定高度——若跟着这一行的完整高度撑满(`.frame(maxHeight: .infinity)`),
    /// 主行字号越大越显眼、喧宾夺主;固定小尺寸只当一个不起眼的"这里有对唱"边角标记,
    /// 不管主行还是更小号的下一句预览,视觉分量都一样克制。
    static let barHeight: CGFloat = 12
    /// dot(6) + 间距(7) + 竖线(2) + 间距(7) = 22pt —— `withSpeakerIndicator` 摆在文字
    /// 前面那一截的固定宽度,`speakerIndicatorInset(side:)` 要拿同一份值给罗马音/译文
    /// 补留白,两处必须**完全**一致(否则又是一次没对齐)。
    static let width: CGFloat = 6 + 7 + 2 + 7
}

/// 控制排横向落点用的声部快照 —— 指针压在按钮上的那段时间里冻住不动。
///
/// 为什么要冻(跟"控制排跟着歌词换边"同一次改动):对唱歌逐句换人唱时歌词
/// 每几秒就换一次边,控制排跟着换边之后,**换边的幅度就是大半个窗宽**(1016pt 宽的窗、
/// 默认字号下两个落点差 759pt)。用户瞄准某颗按钮的那零点几秒里正好赶上换行,按钮排会
/// 整条从指针底下抽走 —— 轻则点空(事件穿透到桌面),重则点到挪过来的**另一颗**按钮上,
/// 而这一排里有「关闭悬浮窗」和「锁定位置」两颗点错了要费事收拾的。
///
/// 判据用的是"指针**压在按钮排上**"(`OverlayChromeSource.isHoveringControlPill`),不是
/// "控制排显示着"(`isHoveringForControls`)—— 后者的命中区是"歌词 ∪ 控制排"的包围盒
/// (前更宽,是整扇窗),指针只是停在**歌词**上、根本没在瞄按钮的时候也会一起
/// 冻住,那正好又变回要修的那个现象(按钮不在歌词上方)。
/// 指针一离开按钮排,下一行就立刻回到"跟着歌词走"。
private enum OverlayControlsSidePin: Equatable {
    /// 没冻:跟着当前行走。
    case free
    /// 冻住:按压上按钮那一刻**当前行的原始声部**算(`nil` = 那一行没有对唱信息)。
    ///
    /// 存的是**原始**声部、不是算完的对齐方向:落点由"对齐方向"和"两侧内缩"两件事
    /// 合成,而这两件事在非自动的「对齐方式」覆盖下走的是两条不同的推导(见
    /// `OverlayDuetAlignmentOverride`)。只冻其中一半,换行时另一半照旧会变,冻了等于白冻。
    case pinned(LyricDuet.Side?)
}

struct LyricsOverlayView<Chrome: OverlayChromeSource>: View {
    // 不直接 @ObservedObject 整个 PlaybackCoordinator/AppSettings —— 见 OverlayPlayback
    // 的注释,那两个单例上与悬浮窗无关的高频写入会打醒整个 body。
    @StateObject private var playback = OverlayPlayback()
    /// 逐字行文字实际矩形的旁路,见 WrapContentRectSink。@State 保证视图重建时是同一个实例。
    @State private var wrapContentSink = WrapContentRectSink()
    // 悬停展示控制按钮/长按拖动这套手势整个搬到了 WindowController 用全局鼠标监听器
    // 实现(背景常年点击穿透,原生 .onHover 收不到事件),这里只读它算出来的结果
    // (isHoveringForControls/isDragArmed)展示对应视觉效果,不再自己维护 @State。
    //
    // 故意不写成 "= LyricsOverlayWindowController.shared" 默认值——这个 View 正是在
    // LyricsOverlayWindowController 自己的 init() 里被构造出来的(装进 NSHostingView),
    // 这时候 .shared 这个 static let 的一次性初始化(dispatch_once)还没跑完,任何在这个
    // 构造过程中对 .shared 的再次访问都会在同一线程递归触发同一个 dispatch_once,被
    // 系统直接判定成非法重入而 SIGTRAP 崩溃(实测坐实:EXC_BREAKPOINT,栈顶正是
    // _dispatch_once_wait 卡在这个默认值上)。改成必填参数,由外部显式传入当时已经
    // 拿到手的 self,不再经过 .shared 这层。
    // 不加 private——需要在另一个文件(LyricsOverlayWindowController.swift)里通过
    // 编译器合成的 memberwise init 传入,标 private 会让那个 init 的访问级别一并降到
    // private,导致跨文件调不到。
    // 类型是**协议**而不是那个具体类:设置页编辑台要渲染同一份视图,
    // 而它绝不能碰 .shared —— 见 OverlayChromeSource 顶部那条提醒。真窗口那唯一一个
    // 构造点靠类型推导拿到 Chrome == LyricsOverlayWindowController,一个字都不用改。
    @ObservedObject var overlayController: Chrome
    /// 只给按钮悬停高亮用(见 `iconButton`):辅助功能开了「减弱动态效果」就不补间,但高亮
    /// **照画** —— 它回答的是"指针现在在哪颗按钮上",是功能反馈,不是装饰(同灵动岛那批
    /// `reduceMotion ? nil : .spring(...)` 的取舍)。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 设置页编辑台里那一份:设置窗口看不见时跟暂停一样停表(见 PreviewHostVisibility.swift)。
    /// 桌面上那扇真窗读到的恒为 true。
    @Environment(\.previewHostVisible) private var previewHostVisible

    // 悬浮窗高度跟着内容动态变化(见 LyricsOverlayWindowController.updateHeight)——这里
    // 汇报"这次渲染实际需要多高",不需要就什么都不做(默认空闭包,方便预览/测试构造)。
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    // 播放控制按钮胶囊的实际屏幕矩形,汇报给 WindowController 当作"点击穿透的例外热区"
    // ——只有落在这个矩形里的鼠标事件才会被窗口正常接收,其它任何地方(包括歌词文字
    // 本身)永远穿透。按钮没显示时(锁定/未悬停)报 .zero。
    var onControlsFrameChange: (CGRect) -> Void = { _ in }
    /// 胶囊里每个按钮各自的矩形(overlayContent 命名坐标空间)。窗口常年点击穿透,
    /// SwiftUI 收不到鼠标事件,点击由控制器按这些矩形自己分发 —— 见
    /// LyricsOverlayWindowController.performControlAction。
    var onControlRectsChange: ([OverlayControlID: CGRect]) -> Void = { _ in }
    /// 歌词**文字**实际占据的矩形(overlayContent 命名坐标空间,多元素并集)。
    /// 给「指针划过时让开」当命中判据 —— 见 LyricsTextRectPreferenceKey。
    var onLyricsTextRectChange: (CGRect) -> Void = { _ in }
    /// 设置页预览的示例行,真窗口恒为 nil —— 见 OverlayPreviewLine。
    var previewLine: OverlayPreviewLine? = nil

    // 固定值,不是设置项——加一个圆角纯粹是给"背景颜色"这个设置配套的实现细节,免得
    // 用户一开背景色看到的是个生硬的直角矩形;两个参考的开源实现里圆角都不是用户可调项。
    private let overlayBackgroundCornerRadius: CGFloat = 16
    private let overlayCoordSpaceName = "overlayContent"
    /// 控制排横向落点的"冻结"状态,见 `OverlayControlsSidePin`。
    @State private var controlsSidePin: OverlayControlsSidePin = .free

    // 播放控制排该不该显示:开关开着、悬停中、且没锁定位置。抽成计算属性是因为下面有三处要用
    // 同一个判断(可见性、是否接受点击、热区要不要上报),散开写容易改漏其中一处。
    //
    // 判据本体在 Core(`OverlayControlHitTest.controlsShown`,有 selftest),不要在这里
    // 就地展开:控制器侧 `handleMouseEvent` 的 `controlsShown` 要跟这里**逐字同一条** ——
    // 它决定收不收回点击穿透、点击分发到哪颗按钮。两边长歪就是"看不见却挡手"或
    // "看得见点不动"。加「悬停控制条」开关时合并的。
    private var controlsVisible: Bool {
        OverlayControlHitTest.controlsShown(
            hovering: overlayController.isHoveringForControls,
            positionLocked: playback.lockPosition,
            hoverControlsEnabled: overlayController.showHoverControls)
    }

    /// 「指针划过时让开」的当前不透明度。
    ///
    /// 做成淡到 15% 而不是整窗 orderOut:orderOut 会打断 `updateActualVisibility` 那套
    /// 状态机(它同时被"暂停时隐藏""截屏时隐藏""手动开关"三方驱动),而这里要的只是
    /// "临时看一眼下面",不该跟那三个真正的可见性来源抢同一个开关。留 15% 也让用户知道
    /// 窗口还在那儿、不是消失了。
    private var hoverFadeOpacity: Double {
        playback.fadeOnHover && overlayController.isHoveringLyrics ? 0.15 : 1
    }

    /// 这一屏实际要画的那一行。真窗口恒等于 `playback.currentLine`(`previewLine` 是 nil),
    /// 排版逐像素不变;设置页预览在没有真实行时退到示例行。
    ///
    /// 收在这**一个**计算属性里,而不是只在 `mainLine` 里挑一次:译文、罗马音、逐词
    /// 分组、对唱声部、换行缓存 key 读的都得是同一行,漏掉任何一处就会变成"示例句显示
    /// 出来了、译文却按空行算"。
    private var line: SyncedLyricLine? { playback.currentLine ?? previewLine?.line }

    /// 这一屏画的是不是示例行。
    private var showingPreviewLine: Bool { playback.currentLine == nil && previewLine != nil }

    /// 下一句预览的文字。示例行在场时用示例那句 —— 它不在 `line` 里,真窗口那边同样是从
    /// 协调器单取的一条(见 `OverlayPlayback.nextLineText`)。
    private var nextLineText: String? {
        showingPreviewLine ? previewLine?.nextLineText : playback.nextLineText
    }

    var body: some View {
        // 按钮排在**歌词卡片上方**,而且**槽位常驻**(不显示时只是透明+不接受点击),两点缺一
        // 不可,原因分别是:
        //
        // 1) 放上方是用户明确要的。但如果照旧写成 `if controlsVisible { ... }`
        //    再放在歌词前面,按钮一出现就会把下面的歌词整个往下推 —— 那正是刚修掉的"悬停时
        //    歌词跳动"的反向版本(见下面 .frame(maxHeight:alignment:.top) 那段注释)。槽位常驻
        //    之后内容高度恒定,歌词的位置跟悬不悬停完全无关。
        // 2) 按钮排放在卡片**外面**而不是塞进卡片里:它自己已经是一个独立的深色胶囊
        //    (见 playbackControls 的 .background(.black.opacity(0.55), in: Capsule())),不需要
        //    借歌词卡片的背景。放外面还有个实际好处 —— 常驻槽位那块空白落在卡片之外,
        //    "深色卡片/浅色卡片"这类有可见背景的主题不会在卡片顶部多出一条空带。
        //
        // 3) **例外:槽位放到卡片下方**——「顶部居中」预设恒如此;自由拖动时,槽位若还在上面
        //    会被拖到超出可见区顶边(= 被真实菜单栏挡住,层级比这扇 `.floating` 悬浮窗高,
        //    盖住的部分既看不见也点不到),这时也翻到下面,让卡片能贴到可见区顶边、槽位仍留在
        //    够得着的地方。判据在 `LyricsOverlayWindowController.controlsBelowCard`。
        //    「底部居中」保持上方不动(守底边,贴 Dock,上面本来就有富余空间)。锁定态解锁
        //    提示跟着同一个槽位走。
        VStack(spacing: 0) {
            if !controlsSlotBelow { controlsSlot }
            lyricsCard
            if controlsSlotBelow { controlsSlot }
        }
        .coordinateSpace(name: overlayCoordSpaceName)
        // 纯测量用,不影响视觉——把这次渲染真正需要的高度(按钮槽位+歌词卡片)报给窗口控制器
        // 去调整窗口高度,长歌词换行到第二行时窗口跟着变高,而不是被原来写死的高度裁掉。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightPreferenceKey.self) { onContentHeightChange($0) }
        .onPreferenceChange(ControlsFramePreferenceKey.self) { onControlsFrameChange($0) }
        .onPreferenceChange(ControlRectsPreferenceKey.self) { onControlRectsChange($0) }
        .onPreferenceChange(LyricsTextRectPreferenceKey.self) { onLyricsTextRectChange($0) }
        .animation(.easeOut(duration: 0.16), value: controlsVisible)
        .animation(.easeOut(duration: 0.3), value: overlayController.showDragHint)
        .animation(.easeOut(duration: 0.2), value: overlayController.transientHint)
        .animation(.easeOut(duration: 0.2), value: overlayController.placementLockNotice)
        // 「指针划过时让开」。挂在**测量之后** —— opacity 不改布局,所以放哪一层都不影响上面
        // 那三条 preference 报出去的高度/热区;放这里只是让它和上面两条动画归在一起看得清。
        // 淡出比淡入慢一点(0.18 vs 0.12):指针扫过去要立刻让开才有用,回来时慢一点更从容。
        .opacity(hoverFadeOpacity)
        .animation(.easeOut(duration: hoverFadeOpacity < 1 ? 0.12 : 0.18), value: hoverFadeOpacity)
        // 控制排每次露出来时重读一次"喜欢"状态。这条状态不跟着 2 秒轮询走(每次读要起一个
        // osascript 子进程,为一个几乎不变的布尔值那么干不值当),换歌时刷一次之外,就靠这里
        // ——正好覆盖"用户刚在 Music.app 里自己点了心、回头来看悬浮窗"这种情况。
        //
        // 走 chrome 的回调而不是直接打 PlaybackCoordinator:设置页编辑台渲染的是同一份视图,
        // 那边必须能把这条副作用空实现掉(见 OverlayChromeSource.controlsDidBecomeVisible)。
        .onChange(of: controlsVisible) { _, visible in
            if visible { overlayController.controlsDidBecomeVisible() }
        }
        // 指针压上按钮排的那一刻把横向落点冻住,离开立刻解冻 —— 理由(以及为什么判据是
        // "压在按钮排上"而不是"控制排显示着")见 OverlayControlsSidePin。
        .onChange(of: overlayController.isHoveringControlPill) { _, onPill in
            controlsSidePin = onPill ? .pinned(line?.side) : .free
        }
        // 第二道闸:指针离开整扇窗时控制排本来就藏起来了,不该再留着一份陈旧快照。控制器
        // 在"窗口隐藏/锁定/卸掉监听器"几处也会顺手清掉 isHoveringControlPill,但那是四个
        // 分散的赋值点,漏一个就会冻死;这里只认"整窗悬停"这一个总闸,漏不掉。
        .onChange(of: overlayController.isHoveringForControls) { _, hovering in
            if !hovering { controlsSidePin = .free }
        }
        // 内容必须**贴着窗口的锚边**放(贴顶;「底部居中」下贴底),不能让它在窗口里居中。
        //
        // 在这一行之前,根视图只约束了宽度,高度就是内容的固有高度;而窗口高度有 120pt 的
        // 地板(updateHeight 里的 max(overlayDefaultHeight, …)),单行歌词的内容比它矮不少。
        // NSHostingView 比内容高的时候,SwiftUI 默认把内容**垂直居中**放 —— 于是内容高度一变,
        // 整块内容(连同歌词文字)就会在窗口里上下移动半个差值。
        //
        // 用独立的 SwiftUI 沙盒逐像素量过(同样的修饰符链 + 固定 120pt 宿主):
        //   居中(改前):静止时内容顶边距窗口顶 30.0pt,内容变高后 17.0pt —— 上移 13pt
        //   贴顶(改后):两种状态都是 0.0pt —— 纹丝不动
        //
        // 贴哪一边跟窗口从哪一边长是同一件事(LyricsOverlayWindowController.updateHeight):守顶边
        // 向下长就贴顶,「底部居中」守底边向上长就贴底 —— 这样锚边那一侧的文字永远不动,只有
        // 新增的行往另一侧展开。贴顶时热区换算 `windowHeight - rect.maxY` 隐含"内容块顶边 ==
        // 窗口顶边";贴底时内容块顶边在窗口顶边下方 (窗高 − 内容高),换算多扣这一截
        // (`OverlayControlHitTest.contentTopInset`),两种对齐下按钮命中区都对得上。
        //
        // 必须加在所有 background/测量修饰符**之后**:加在前面的话,那个测内容高度的
        // GeometryReader 量到的会变成整个窗口高度,updateHeight 就再也收不到真实内容高度了。
        //
        // `minHeight: 0` 不能省:内容变高的那一拍窗口还没长(高度要经 preference → updateHeight
        // 绕一圈,晚几帧),只写 maxHeight 的 frame 会取内容高度、比宿主高,NSHostingView 又把
        // 它垂直居中,整块歌词上跳半个差值、等窗口长好再落回来。钉住 minHeight 后 frame 恒等于
        // 宿主高度,多出来的内容照 alignment 从锚边那一侧往外溢(先被裁掉几帧),锚边的字不动。
        .frame(minHeight: 0, maxHeight: .infinity, alignment: playback.placementMode.anchorsBottom ? .bottom : .top)
    }

    /// 控制排槽位放在歌词卡片**下方**还是上方,判据见 `OverlayChromeSource.controlsBelowCard`
    /// 与 body 头注第 3 条。
    private var controlsSlotBelow: Bool { overlayController.controlsBelowCard }

    /// 播放控制排 / 锁定态解锁提示 / 位置已固定提示 三者共用的那一个槽位。常驻、透明度切换,
    /// 三个状态**等高**(胶囊 30pt + 离卡片 4pt + 离窗口边 4pt),切来切去歌词不跳。
    private var controlsSlot: some View {
        // 锁定态下这个槙位换成"解锁"提示,不叠在歌词上面——跟播放控制排共用同一个槙位、同一套"常驻+
        // 透明度切换"处理,理由跟下面播放控制排的注释一致:槙位常驻才能保证歌词位置
        // 不随悬不悬停跳动。
        Group {
            // 预设模式下想拖窗口被拒:这个槽位临时换成一条醒目的"🔒 已固定"胶囊;同时卡片
            // 整体左右抖一下(见 lyricsCard 上的 ShakeEffect)。优先级最高:此刻用户的手正在窗口上。
            if let notice = overlayController.placementLockNotice {
                placementLockPill(notice)
            } else if playback.lockPosition {
                unlockPill
                    .opacity(unlockPillVisible ? 1 : 0)
                    .allowsHitTesting(unlockPillVisible)
                    .animation(.easeOut(duration: 0.16), value: unlockPillVisible)
            } else {
                playbackControls
                    .opacity(controlsVisible ? 1 : 0)
                    // 不显示时不接受点击 —— 槽位虽然常驻,但那时它必须对鼠标完全透明,否则会
                    // 在歌词上方挖出一块"看不见却挡手"的区域。
                    .allowsHitTesting(controlsVisible)
                    // 把这排按钮的真实位置汇报上去,当作点击穿透的例外热区(见
                    // WindowController.updateControlsHotZone)。
                    //
                    // 这里**永远报真实矩形**,不能写成"没显示时报 .zero"来兼表可见性。
                    // 实测坐实:那样写的话观察者收到的恒为 .zero —— 这个 key 的
                    // reduce 是"后来者覆盖",而树里别的分支(外层那个测高度的 background 里的
                    // Color.clear)会贡献 defaultValue(.zero)并排在后面,把真实矩形冲掉。
                    // 日志里能直接看到两行并排:GeometryReader 算出 (341.5,0.1,217,48),
                    // 而 onPreferenceChange 收到 (0,0,0,0)。
                    // 现在 .zero 只有一个含义 ——"这一轮没有任何人报告位置",可见性判断挪到
                    // 控制器侧(见 handleMouseEvent 里的 controlsShown)。
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ControlsFramePreferenceKey.self,
                                value: proxy.frame(in: .named(overlayCoordSpaceName))
                            )
                        }
                    )
            }
        }
        // 跟窗口边留一点呼吸空间——这个槙位若紧贴 VStack 顶端、跟窗口内容区顶边零距离,
        // 锁定态下"🔒 解锁"这颗孤立的小胶囊尤其明显。 这两个 padding 必须挂在
        // Group 上(三个分支的**外面**),不能只加给 unlockPill 自己——playbackControls
        // 不加的话,状态之间又会变回不一样高,"锁定/解锁切换时内容整体挪动"这个坏行为
        // 会复发(见下面播放控制排/解锁提示各自注释里记的那个高度不对齐的坑)。
        // 槽位在卡片下方时两条边对调:离窗口边的那 4pt 在下、离卡片的那 4pt 在上
        // (原来"离卡片 4pt"写在两颗胶囊自己身上的 .padding(.bottom, 4),
        //  为了能翻面挪到了这里)。
        .padding(controlsSlotBelow ? .bottom : .top, 4)
        .padding(controlsSlotBelow ? .top : .bottom, 4)
        // 横向跟着歌词块走 —— 这一格若只吃外层 `VStack(spacing: 0)` 默认的 `.center` 对齐,
        // 而歌词卡片自己是 `.frame(maxWidth:.infinity, alignment: duetFrameAlignment)`,
        // 对唱歌把歌词甩到右半边时,按钮排还会钉在整扇窗正中,差出大半个窗宽。普通歌看
        // 不出来纯属巧合:`duetSide` 兜底就是 `.center`,两边算出来正好同一个位置。
        //
        // 留白 = 卡片内缩 + 卡片水平内边距(`OverlayCardGeometry.controlsInsets`,跟卡片
        // 共用 core 里同一份几何),再按同一个方向靠边 —— 按钮排的近侧边缘因此跟歌词块
        // 的近侧边缘严格重合,不是靠肉眼凑。合唱/普通歌两侧对称,`.center` 下位置跟改动
        // 前逐像素相同。
        //
        // 故意**不加动画**:歌词换行本身就是纯属性跳变(见文件头),按钮排跟着一起
        // 硬切才对得上;而且动画途中 `ControlRectsPreferenceKey` 会逐帧上报中间位置,
        // 控制器按矩形分发的点击会落在"飞到一半"的按钮上。
        .padding(.leading, controlsInsets.leading)
        .padding(.trailing, controlsInsets.trailing)
        .frame(maxWidth: .infinity, alignment: controlsFrameAlignment)
    }

    /// 对唱歌词的左右分栏(见 LyricDuet)——这是**对齐方向**用的值,已经套过设置页的
    /// 「对齐方式」覆盖(见 OverlayDuetAlignmentOverride):自动模式下等价于旧行为
    /// (nil = 没有演唱者标记的普通歌,兜底居中);非自动模式下**每一行**(不管有没有
    /// 真实声部信息)都固定成用户选的那个方向。
    ///
    /// 不要把这个值传进 withSpeakerIndicator/speakerIndicatorInset/duetInsets——
    /// 那三处要的是"要不要展示对唱装饰",跟"往哪边对齐"是两件事,非自动模式下前者必须
    /// 保持关闭(见 duetDecorationSide)。
    private var duetSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: line?.side)
    }

    /// 下一句预览摆哪一边——**独立于当前行的 duetSide 算**,不能假定下一句跟当前句是
    /// 同一位演唱者。对唱歌交替演唱时(比如逐句男/女/男/女切换的歌),下一句几乎每次都
    /// 换边;固定继承 duetSide 的话,视觉上会永远像是当前这位接着唱下一句
    /// (例如《All Night》女声"U got to dance all night"被摆在
    /// 男声"All night"底下)。同样套过对齐方式覆盖,理由跟 duetSide 一致。
    private var nextLineDuetSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: playback.nextLineSide)
    }

    /// 对唱装饰(两侧内缩 + 声部指示圆点)该用哪个声部——跟上面两个"对齐方向"用的值是
    /// 两件事:自动模式下原样等价(nil 兜底成 .center,装饰照旧不出现);**非自动模式下
    /// 强制视为没有对唱信息**,不管真实声部是什么,两侧内缩归零、指示圆点不显示。
    ///
    /// 这是 issue 里"始终保持在同一个位置"真正需要的那一半:光把上面两个对齐值锁死,
    /// 留着这两处装饰继续按真实声部算,文字块还是会因为内缩量变化而轻微跳(见
    /// OverlayDuetAlignmentOverride 声明处注释),必须一并锁死才行。
    private var duetDecorationSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveDecorationSide(realSide: line?.side) ?? .center
    }
    private var nextLineDecorationSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveDecorationSide(realSide: playback.nextLineSide) ?? .center
    }

    /// 控制排(播放控制胶囊 / 锁定态的解锁按钮)算横向落点时用的**原始**声部。
    ///
    /// 平时就是当前行自己的 `line?.side` —— 于是按钮排跟歌词块贴同一条边(若不跟,
    /// 对唱歌里按钮排会钉在整扇窗正中,不在对应歌词上方)。指针压上按钮排的
    /// 那段时间里换成压上去那一刻的快照,理由见 `OverlayControlsSidePin`。
    private var controlsRealSide: LyricDuet.Side? {
        if case .pinned(let side) = controlsSidePin { return side }
        return line?.side
    }

    /// 控制排该贴哪一边 —— 跟卡片 `duetFrameAlignment` 同一条推导,只是输入换成
    /// `controlsRealSide`(可能是冻住的那一份)。
    private var controlsFrameAlignment: Alignment {
        frameAlignment(for: playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: controlsRealSide))
    }

    /// 这张卡里最宽的那一行**不换行的话要多宽**(含声部圆点占掉的那一截)。
    ///
    /// 直接量文字,不经过布局(见 `OverlayNaturalWidth` 头注:在自定义 `Layout` 里对整棵
    /// 卡片子树发无约束试探,会让主歌词行真的按"不换行"摆出来、冲出卡片被窗口裁掉)。
    /// 四行都要量:留白是加在整块上的,只顾主行的话译文/下一句会替它提前折行。
    private var cardNaturalWidth: CGFloat {
        let fonts = playback.overlayNSFonts
        let indicator = speakerIndicatorInset(side: duetDecorationSide)
        var widest: CGFloat = 0
        widest = max(widest, OverlayNaturalWidth.width(line?.plainText, font: fonts.main))
        // 逐词标注时罗马音没有独立的一行(标在每个词正下方),但它照样会把那一行撑宽,
        // 所以整行的罗马音也要参与取最大 —— 这是个近似:真实宽度是逐词 max(词, 读音)
        // 相加,量不到,差的那一点只会让留白多让一点,不会反过来害得提前折行。
        widest = max(widest, OverlayNaturalWidth.width(
            romanizationRowText ?? (usesPerWordRomanization ? line?.romanization : nil)
                ?? (upcomingWordGroups != nil ? playback.nextLineRomanization : nil),
            font: fonts.romanization))
        widest = max(widest, OverlayNaturalWidth.width(translationRowText, font: fonts.translation))
        if playback.showNextLinePreview {
            // 下一句预览换人唱时会放大到主字号(见 nextLinePreviewFont),量宽要跟着换。
            let previewFont = nextLinePreviewFont == playback.mainFont ? fonts.main : fonts.preview
            widest = max(widest, OverlayNaturalWidth.width(nextLineText, font: previewFont))
        }
        guard widest > 0 else { return 0 }
        return widest + indicator.leading + indicator.trailing
    }

    /// 两侧留白**这一行实际用上了多少**,0…1。判据与取舍见
    /// `OverlayCardGeometry.elasticInsetScale`。
    private var duetInsetScale: CGFloat {
        OverlayCardGeometry.elasticInsetScale(
            totalInset: duetInsets.leading + duetInsets.trailing,
            availableWidth: playback.cardAvailableWidth,
            naturalContentWidth: cardNaturalWidth)
    }

    /// 控制排两侧该留多少白 —— 卡片内缩 + 卡片水平内边距,算法在 core 里跟卡片共用同一份
    /// (见 `OverlayCardGeometry`)。加总之后按钮排的近侧边缘跟歌词块的近侧边缘严格重合。
    ///
    /// 留白让开时按钮排要跟着让开同样多(`scale`),否则长句把歌词块推到卡片边缘、按钮排
    /// 还钉在原来的缩进上 —— 又是一次"按钮不在歌词上方"。
    private var controlsInsets: (leading: CGFloat, trailing: CGFloat) {
        OverlayCardGeometry.controlsInsets(
            for: playback.duetAlignmentOverride.effectiveDecorationSide(realSide: controlsRealSide),
            unit: playback.duetInsetUnit,
            stageInset: playback.duetStageInset,
            scale: duetInsetScale,
            cardHorizontalPadding: OverlayPlayback.cardHorizontalPadding)
    }

    /// 下一句预览用的字号——只有**下一句换了个人唱**(`nextLineSide` 有值且跟当前行的
    /// side 不一样)才用跟当前行同尺寸的 `mainFont`,不缩小;其它情况(非对唱歌、对唱歌
    /// 还没到第一个声部标记的前奏、以及对唱歌里同一位连唱两句)都照旧用更小的
    /// `previewFont`,跟普通歌排版逐像素不变。「对齐方式」覆盖生效时同样退回小字号——
    /// 这项字号放大专为"提前预告即将到来的位置+字号双重跳变"设计,覆盖生效时位置已经
    /// 锁死不会跳,这个理由不再成立。
    ///
    /// 对唱歌逐句换人唱时,下一句预览从"更小的字号"跳到"当前行的
    /// 正常字号"这个变化,跟位置的变化(见 nextLineInsetsDelta)叠在一起格外抖——普通歌
    /// 因为位置没变,这个字号跳变本来就不明显,不需要跟着一起改。
    ///
    /// 判据**不能**只看 `nextLineSide != nil`,必须跟当前行的 side 比较——
    /// 对唱歌里同一位演唱者连唱两句(下一句 side 跟当前行相同,不会真的跳)也被一并放大了
    /// 字号,这种情况跟普通歌一样该用小字号预览,后来收紧了这个条件:只有下一句
    /// **真的**换了人唱、即将发生位置+字号的双重跳变时才值得用大字号提前"预告"。
    /// nextLineInsetsDelta 不需要跟着改——两句 side 相同时 duetInsets(next) 跟
    /// duetInsets(current) 天然算出同一份值,delta 本来就是 0,已经隐含了这条判据。
    private var nextLinePreviewFont: Font {
        // 前奏/间奏「•••」下方没有当前行陪衬——这句其实是接下来的第一句本身,不是伴随
        // 当前行的预告小字,跟下面对唱换人那条理由(提前预告位置跳变)不是一回事,不受
        // duetAlignmentOverride 影响,始终用 mainFont。
        guard line != nil else { return playback.mainFont }
        guard playback.duetAlignmentOverride == .automatic,
              let nextSide = playback.nextLineSide, nextSide != line?.side
        else {
            return playback.previewFont
        }
        return playback.mainFont
    }

    private func horizontalAlignment(for side: LyricDuet.Side) -> HorizontalAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private func textAlignment(for side: LyricDuet.Side) -> TextAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private func frameAlignment(for side: LyricDuet.Side) -> Alignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var duetAlignment: HorizontalAlignment { horizontalAlignment(for: duetSide) }

    private var duetTextAlignment: TextAlignment { textAlignment(for: duetSide) }

    /// 给一段已经在正确一侧对齐好的对唱内容,在文字贴边的那一侧叠一枚圆点+细竖线,
    /// 用**跟这段文字同一个颜色**——固定的蓝/粉两色跟"身份"绑定,会跟主题脱钩、跟用户
    /// 自己的配色主题不搭。改用调用方传入的 `color`——调用方直接传这一行文字实际在用的
    /// `displayForegroundColor`(含它自己的不透明度,下一句预览天生更淡,指示条跟着一起
    /// 淡,不会比自己贴着的文字更抢眼)。识别"谁在唱"现在纯靠**位置**(先出现的贴左、
    /// 第二位贴右,跟 LyricDuet.sides 的定边顺序一致),不再靠色相区分。
    ///
    /// side 为 `.center` 时(没有对唱信息,或者真的是合唱)原样返回 content,不包一层
    /// 容器——普通歌的排版必须逐像素不变,这是这份文件里反复出现的纪律(两侧内缩/nil
    /// 兜底都是同一条,见 duetInsets 的注释)。合唱不属于任何一侧,不该有边角标记。
    ///
    /// 圆点+竖线摆在**文字所在的那一侧**(leading 摆左、trailing 摆右),不是固定摆
    /// 左边——这样无论这一行贴哪一边,指示都紧挨着文字,跟着一起换边。
    /// dot(6) + 间距(7) + 竖线(2) + 间距(7) = 22pt——withSpeakerIndicator 摆在文字前面
    /// 那一截固定宽度,给 speakerIndicatorInset(side:) 用,geometry 必须跟下面那份完全
    /// 一致(否则又是一次没对齐)。见 OverlaySpeakerIndicator。

    /// 给罗马音/译文用:补上跟 withSpeakerIndicator 同一份几何值的留白,但不画圆点+竖线。
    ///
    /// 主歌词、罗马音、
    /// 译文三行共享同一个 `VStack(alignment: duetAlignment)`,VStack 按每个子视图各自的
    /// **frame** 左边缘对齐——主歌词那一支被 `withSpeakerIndicator` 包了一层 HStack(圆点+
    /// 竖线+文字),这个 HStack 的左边缘是圆点,不是文字本身;罗马音/译文没有这层包装,
    /// 左边缘就是文字本身。于是罗马音/译文的文字比主歌词的文字整体靠左了 22pt(圆点+竖线+
    /// 两段间距的宽度)——普通歌(side 恒为 nil)不受影响,只有对唱歌才会看见。
    ///
    /// 不给罗马音/译文也画一个圆点(信息重复,一行歌词配三个圆点没有意义),而是照抄同一份
    /// 几何值当 padding 补上,让三行文字的**文字本身**(不是容器)左边缘对齐。.center 两侧
    /// 都是 0,跟 withSpeakerIndicator 对 .center 不包容器是同一条纪律——没有对唱信息时
    /// 排版必须逐像素不变。参数跟 withSpeakerIndicator 一样收**已经把 nil 兜底过**的
    /// `LyricDuet.Side`(调用点传 duetSide,不是原始的 currentLine?.side)。
    private func speakerIndicatorInset(side: LyricDuet.Side) -> (leading: CGFloat, trailing: CGFloat) {
        switch side {
        case .leading: return (OverlaySpeakerIndicator.width, 0)
        case .trailing: return (0, OverlaySpeakerIndicator.width)
        case .center: return (0, 0)
        }
    }

    @ViewBuilder
    private func withSpeakerIndicator<V: View>(side: LyricDuet.Side, color: Color, @ViewBuilder content: () -> V) -> some View {
        if side != .center {
            let dot = Circle().fill(color).frame(width: 6, height: 6)
            let bar = Capsule().fill(color.opacity(0.55)).frame(width: 2, height: OverlaySpeakerIndicator.barHeight)
            HStack(spacing: 7) {
                if side == .leading {
                    dot
                    bar
                    content()
                } else {
                    content()
                    bar
                    dot
                }
            }
        } else {
            content()
        }
    }

    /// 给 `.frame(maxWidth:alignment:)` 用的二维对齐。
    ///
    /// 为什么需要它:VStack 的宽度 = 最宽子视图的宽度,而行级(无逐字)歌词那一支是裸
    /// `Text`,宽度就是文字自己的宽度 —— 外层 `.frame(maxWidth: .infinity)` 不写
    /// alignment 时默认居中,于是整块内容被摆回正中,VStack 里的 duetAlignment 根本
    /// 没有发挥余地,leading/trailing/center 三种 side 渲染出来一模一样。
    /// 逐字那一支侥幸生效,只是因为 WrapLayout 恒声明占满被提议的整宽。
    /// (修:在此之前行级歌词的对唱分栏 100% 失效,而且前缀已被剥掉,
    /// 屏幕上比不做这个功能时信息更少。)
    private var duetFrameAlignment: Alignment { frameAlignment(for: duetSide) }

    /// 把这个视图的 frame 报进歌词文字矩形的并集(见 LyricsTextRectPreferenceKey)。
    private func reportingTextRect<V: View>(_ v: V) -> some View {
        v.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LyricsTextRectPreferenceKey.self,
                    value: proxy.frame(in: .named(overlayCoordSpaceName)))
            })
    }

    /// 主歌词那一支单独走:逐字行是 WrapLayout,它**撑满整宽**,直接拿 frame 会把左右两片
    /// 空白也算成歌词。用布局阶段写进 sink 的"文字实际矩形"(相对 WrapLayout 原点)去修正;
    /// 别的那几支(行级歌词、间奏的 ♪、「暂无歌词」这些状态文案)是裸 Text、frame 本身就是
    /// 文字范围,按整 frame 走。
    ///
    /// 判"该不该用 sink"要认 **owner**,不能只判 `.zero`(实测):那几支
    /// 压根不经过 WrapLayout,没人写 sink,而一首逐字歌只要排过一行 sink 就再也不是 `.zero`
    /// —— 于是间奏的 ♪ 会顶着上一句歌词的宽高上报,命中区往右糊出一大片。见 WrapContentRectSink。
    private func reportingMainLineRect<V: View>(_ v: V) -> some View {
        v.background(
            GeometryReader { proxy in
                let f = proxy.frame(in: .named(overlayCoordSpaceName))
                let local = wrapContentSink.owner == overlayLineLayoutKey ? wrapContentSink.rect : .zero
                let rect = local == .zero
                    ? f
                    : CGRect(x: f.minX + local.minX, y: f.minY + local.minY,
                             width: local.width, height: local.height)
                return Color.clear.preference(key: LyricsTextRectPreferenceKey.self, value: rect)
            })
    }

    /// 按**给定**声部算两侧留白——从只认 `currentLine.side` 的计算属性
    /// 改成参数化:下一句预览要按**它自己**的声部单独算一份insets,不能沿用当前行那份
    /// (见调用点 nextLineInsetsDelta 的注释)。
    ///
    /// 只有真的有声部信息才留白:side 为 nil 时(普通歌、对唱歌第一个标记之前的前奏,
    /// 以及「对齐方式」覆盖生效时——见下)两边都是 0。注意调用方**不能**传已经把 nil
    /// 兜底成 .center 的 duetSide/nextLineDuetSide,那样每一首普通歌都会凭空缩进两边——
    /// 必须传经过 `OverlayDuetAlignmentOverride.effectiveDecorationSide` 处理过的值
    /// (自动模式下就是原始的 `currentLine?.side` / `nextLineSide`,非自动模式下强制
    /// 为 nil)。
    /// (映射本身搬进 core 的 `OverlayCardGeometry` —— 卡片上方那排控制按钮
    /// 要贴的是**同一条边**,两处必须逐字一致,见该类型声明处的注释。这里只是把
    /// `duetInsetUnit` 喂进去,数值和取舍一个字没变。)
    /// 多喂一个 `duetStageInset`:窗口比默认宽时左右声部的近侧也缩进,把两栏收进
    /// 卡片正中一条固定宽度的带里(见 OverlayCardGeometry 顶部「对唱舞台」)。下一句预览的
    /// `nextLineInsetsDelta` 和控制排的 `controlsInsets` 都从这里派生,自然一起跟着走。
    private func duetInsets(for side: LyricDuet.Side?) -> (leading: CGFloat, trailing: CGFloat) {
        OverlayCardGeometry.cardInsets(for: side, unit: playback.duetInsetUnit,
                                       stageInset: playback.duetStageInset)
    }

    private var duetInsets: (leading: CGFloat, trailing: CGFloat) {
        duetInsets(for: playback.duetAlignmentOverride.effectiveDecorationSide(realSide: line?.side))
    }

    /// 下一句预览要额外补偿的内边距——让它按**自己真正会用到的**位置摆,不是"当前行
    /// 缩进之后、在剩下的空间里尽量靠边"。
    ///
    /// `lyricsCard`
    /// 整块的 `.padding(duetInsets...)` 是按**当前行**的声部算的,下一句预览虽然自己有
    /// `.frame(alignment: frameAlignment(for: nextLineDuetSide))` 决定往哪边靠,但它是
    /// 嵌在这个已经按当前行缩进过的卡片**内部**——当下一句换了个人唱(声部跟当前行不
    /// 一样)时,预览只是"在当前行的缩进基础上尽量靠左/右",不是它真正激活时(那时缩进
    /// 会按它自己的声部重新算)会落在的位置,切换瞬间就会跳一下。
    ///
    /// 修法:算出"下一句真正应该有的 insets"与"当前行已经加在外层卡片上的 insets"之差,
    /// 叠加在预览这一行自己身上——外层贡献 `duetInsets(currentSide)`,这里再补
    /// `nextInsets − currentInsets`,两者相加就等于预览独立按 `nextInsets` 摆放,跟它变成
    /// 当前行时会用到的 insets 完全一致,不会再跳。
    private var nextLineInsetsDelta: (leading: CGFloat, trailing: CGFloat) {
        let override = playback.duetAlignmentOverride
        let current = duetInsets(for: override.effectiveDecorationSide(realSide: line?.side))
        let next = duetInsets(for: override.effectiveDecorationSide(realSide: playback.nextLineSide))
        return (next.leading - current.leading, next.trailing - current.trailing)
    }

    /// 图层版的主歌词行。宽度吃满卡片(滚动窗就是它),高度用跟 SwiftUI 那条同一个公式。
    private func layerScrollingKaraokeRow(words: [SyncedLyricWord]) -> some View {
        OverlayScrollingLyricRow(
            spec: .init(
                lineKey: line?.plainText ?? "",
                words: words,
                // 开了逐词罗马音才按词组排;否则只画一行字(同 karaokeWordRun 的两条分支)。
                groups: usesPerWordRomanization ? line?.wordGroups : nil,
                font: playback.overlayNSFonts.main,
                romaFont: playback.overlayNSFonts.romanization,
                baseColor: NSColor(playback.displayKaraokeUnsungColor),
                fillColor: NSColor(playback.displayForegroundColor),
                // 罗马音那一行的两色跟 SwiftUI 那边的 romaPalette 逐字一致:已唱是前景色打
                // 0.75 折,未唱跟主行同一个未唱色(**不**跟着打折 —— 那条折扣只对"同一色调暗"
                // 那套派生关系才有意义)。
                romaBaseColor: NSColor(playback.displayKaraokeUnsungColor),
                romaFillColor: NSColor(playback.displayForegroundColor.opacity(0.75)),
                strokeColor: playback.textStrokeEnabled ? NSColor(playback.textStrokeColor) : nil,
                alignment: duetSide,
                // 跟 SwiftUI 那条逐字染色的 TimelineView 同一条 paused 判据。
                paused: !playback.isPlayingNow || playback.currentLineFillSettled || !previewHostVisible),
            nowMs: Self.lyricsNowMs)
        .frame(maxWidth: .infinity)
        .frame(height: mainScrollRowHeight)
    }

    /// 换行模式的主歌词行:按可用宽度折成几行、每行一条图层行(`WrappedKaraokeRows`)。颜色、罗马音配色、
    /// 描边、停表判据跟 `layerScrollingKaraokeRow` 逐项一致;对齐按声部(`duetRowAlignment`,同原来
    /// `WrapLayout` 的 rowAlignment);文字矩形照旧写进 `wrapContentSink`(owner = `overlayLineLayoutKey`),
    /// 鼠标命中那条路不用动。
    private func layerWrappedKaraokeRows(words: [SyncedLyricWord]) -> some View {
        WrappedKaraokeRows(
            spec: .init(
                lineKey: line?.plainText ?? "",
                words: words,
                groups: usesPerWordRomanization ? line?.wordGroups : nil,
                font: playback.overlayNSFonts.main,
                romaFont: playback.overlayNSFonts.romanization,
                baseColor: NSColor(playback.displayKaraokeUnsungColor),
                fillColor: NSColor(playback.displayForegroundColor),
                romaBaseColor: NSColor(playback.displayKaraokeUnsungColor),
                romaFillColor: NSColor(playback.displayForegroundColor.opacity(0.75)),
                strokeColor: playback.textStrokeEnabled ? NSColor(playback.textStrokeColor) : nil,
                rowAlignment: duetRowAlignment,
                paused: !playback.isPlayingNow || playback.currentLineFillSettled || !previewHostVisible),
            nowMs: Self.lyricsNowMs,
            contentRectSink: wrapContentSink,
            sinkOwner: overlayLineLayoutKey)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: line?.plainText ?? ""))
    }

    /// 图层行读的播放位置:跟逐字染色那条 TimelineView 逐字节一份 —— 锚点外推 ?? 暂停冻结位置,
    /// 再叠歌词时间轴偏移。
    private static func lyricsNowMs() -> Int {
        (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: Date())
            ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
            + PlaybackCoordinator.shared.currentLyricsOffsetMs
    }

    /// 这一帧各行怎么排(显示什么、动不动、怎么动)。判据全在 Core 的 `OverlayRowPlan`,这里只喂输入;
    /// 下面各行的分支照着它的 `Motion` 走,别在视图里另写条件。
    private var rowPlan: OverlayRowPlan.Plan {
        OverlayRowPlan.resolve(.init(
            overflow: playback.lineOverflow,
            hasLine: line != nil,
            lineHasWords: line?.words != nil,
            lineHasWordGroups: line?.wordGroups?.isEmpty == false,
            lineRomanization: line?.romanization,
            lineTranslation: line?.translation,
            isPreviewLine: showingPreviewLine,
            hasTimingWindow: playback.currentLineWindow != nil,
            showRomanization: playback.showRomanization,
            showTranslation: playback.showTranslation,
            showNextLinePreview: playback.showNextLinePreview,
            nextText: nextLineText,
            nextRomanization: playback.nextLineRomanization,
            nextTranslation: playback.nextLineTranslation,
            nextHasWordGroups: playback.nextLineWordGroups?.isEmpty == false))
    }

    /// `.paced` 那几行的显示窗口。只在 `rowPlan` 判成 `.paced` 时取用(那时它必不为 nil)。
    private var pacedWindow: OverlayScrollingLyricRow.PacedWindow? { playback.currentLineWindow }

    /// 不滚的那一行。`lineLimit(1)` 不配 `fixedSize`:要让容器把宽度压下来,才会出「…」。
    private func stillUpcomingText(_ text: String, font: Font, color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
    }

    /// 按显示时长配速的图层行。不填色(整行一个颜色),描边、对齐、停走跟跟唱那条同一套。
    private func pacedLayerRow(
        key: String, text: String, font: NSFont, color: Color,
        alignment: LyricDuet.Side, height: CGFloat, window: OverlayScrollingLyricRow.PacedWindow
    ) -> some View {
        let ns = NSColor(color)
        return OverlayScrollingLyricRow(
            spec: .init(
                lineKey: key,
                words: [SyncedLyricWord(text: text, startMs: 0, durationMs: 0)],
                groups: nil,
                font: font,
                romaFont: playback.overlayNSFonts.romanization,
                baseColor: ns, fillColor: ns, romaBaseColor: ns, romaFillColor: ns,
                strokeColor: playback.textStrokeEnabled ? NSColor(playback.textStrokeColor) : nil,
                alignment: alignment,
                paused: !playback.isPlayingNow || !previewHostVisible,
                pacedWindow: window),
            nowMs: Self.lyricsNowMs)
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    /// 主行在滚动模式下占多高。开了**逐词罗马音**时这一行是「字 + 它的读音」上下两行的
    /// VStack(见 `karaokeWordRun`),高度要把读音那一行一起算进去,否则读音会被裁掉。
    private var mainScrollRowHeight: CGFloat {
        let main = playback.scrollTextHeight(playback.overlayNSFonts.main)
        let roma = usesPerWordRomanization ? playback.scrollTextHeight(playback.overlayNSFonts.romanization) : 0
        // 描边包的是字 + 读音那一整块,预留只加一份。
        return main + roma + playback.scrollStrokePadding
    }

    /// 滚动模式下**没溢出**的短句靠哪边 —— 跟换行模式下 VStack 的对齐同一个来源,
    /// 两种模式切来切去短句不该跳位置。溢出的句子一律从左起滚(见 `MarqueeText.restingAlignment`)。
    private var marqueeRestingAlignment: Alignment {
        Alignment(horizontal: duetAlignment, vertical: .center)
    }

    private var duetRowAlignment: WrapLayout.RowAlignment {
        switch duetSide {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var lyricsCard: some View {
        // 对唱行的两侧留白 —— 让左右真的读成两栏,而不是只靠字的落点(见 LyricDuetLayout)。
        // 没有对唱信息的行(普通歌的每一行)insets 恒为 0,排版逐像素不变。
        //
        // 留白乘 `duetInsetScale`:它只占"这一行本来就用不到"的那部分宽度,一行装不下就整份
        // 让开,别让留白逼出提前折行(见 OverlayCardGeometry.elasticInsetScale)。
        lyricsCardContent
            .padding(.leading, duetInsets.leading * duetInsetScale)
            .padding(.trailing, duetInsets.trailing * duetInsetScale)
            .padding(.horizontal, OverlayPlayback.cardHorizontalPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: duetFrameAlignment)
            .background(overlayBackground)
            // 长按拖动"武装"后的视觉提示——一圈跟前景色同色的高亮描边,松手/取消立刻淡出。
            .overlay(
                RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                    .stroke(playback.displayForegroundColor.opacity(overlayController.isDragArmed ? 0.6 : 0),
                            lineWidth: 2)
            )
            // 预设模式下想拖被拒:整张卡左右抖三下(照 macOS 密码框输错那一下的语义),
            // 配合槽位里那条「已固定」胶囊。tick 每次 +1,GeometryEffect 里 sin 走整数个周期、
            // 静止位精确归零。「减弱动态效果」开着时不抖(胶囊照样给)。纯位移、不改布局,
            // 热区/高度上报不受影响。
            .modifier(OverlayRejectShake(
                travel: reduceMotion ? 0 : CGFloat(overlayController.placementLockShakeTick)))
            .animation(reduceMotion ? nil : .linear(duration: 0.45),
                       value: overlayController.placementLockShakeTick)
            // 对唱歌词按演唱者分左右。不带标记的歌 duetSide 恒为 .center,
            // 跟原来完全一致——除非「对齐方式」覆盖生效,那时
            // duetSide 会固定成用户选的方向,不带标记的普通歌也会跟着一起改对齐。
            .multilineTextAlignment(duetTextAlignment)
    }

    /// 罗马音那一行的文字,没有就是 nil(这一行整个不出现)。
    ///
    /// 抽成计算属性而不是写在 body 的 `if let` 里:`overlayCardLayoutKey` 要拿同一份判据
    /// 当内容身份,两处各写一遍迟早会漂 —— 漂了的表现是换了行还用上一行的留白试探结果。
    ///
    /// 有逐词标注(`usesPerWordRomanization`)时读音已经标在每个词正下方,这一整行不再重复。
    /// `line` 为 nil(前奏/间奏「•••」下方没有当前行陪衬)时退到 `nextLineRomanization`——
    /// 那句其实就是接下来的第一句本身,该按正常行的规格展示。
    private var romanizationRowText: String? { rowPlan.romanization?.text }

    /// 译文那一行的文字,没有就是 nil。`line` 为 nil 时的退路同 `romanizationRowText`。
    private var translationRowText: String? { rowPlan.translation?.text }

    private var lyricsCardContent: some View {
        VStack(alignment: duetAlignment, spacing: 4) {
            withSpeakerIndicator(side: duetDecorationSide, color: playback.displayForegroundColor) {
                reportingMainLineRect(mainLine)
            }
            // 罗马音在**歌词下面、译文上面**。从歌词上面挪下来 —— 歌词窗口
            // (LyricsWindowView)早就是这个顺序了,这里是漏改的那一处,同一首歌只要解析不出
            // 词组就会跳到上面显示,四种组合里唯一的异类。
            //
            // 为什么是下面(调研结论):这里标的是**罗马字/音译**,不是注音。注音(furigana、
            // 拼音)是给"认得这套字、只是不确定读音"的读者用的,绑到单个字符,惯例在上方
            // (CSS ruby-position 默认 over);而音译是给"根本不认得这套字"的人跟着唱的,
            // 是一条跟译文并列的平行文本行,惯例在下方 —— 维基百科 Furigana 条目里唯一提到
            // 罗马字位置的例子(西武铁道站牌)也是把罗马字放在汉字下面。
            //
            // 四种语言统一放下面,不按语言分叉:① 韩文压根没有 ruby 传统(W3C 那份 ruby 文档
            // 从头到尾没提韩文 —— 谚文本身表音,韩国读者不需要注音),没有"上方"惯例可继承;
            // ② 中文拼音**作为注音**惯例确实在上方,但这里是音译,不是注音;③ K-pop 中日韩英
            // 混唱很常见,位置随语言变会让同一屏内上下不一致。
            //
            // 有逐词标注(perWordRomanization)时,读音已经标在每个词的正下方了,这一整行
            // 就不再重复一遍。
            // line 为 nil 时(前奏/间奏「•••」下方没有当前行陪衬)退到 nextLineRomanization——
            // 那句其实是接下来的第一句本身,该按正常行的规格展示,不是"预览小字没有罗马音"
            // 那条既有限制的例外,是同一份数据换了个取值来源。
            //
            // 三行(罗马音/译文/下一句预览)的先后顺序**不是恒定的**,取决于 `line` 是否
            // 为 nil——`nextLinePreviewRow` 在这两种状态下扮演的角色完全不同:
            //  - `line` 不为 nil(正常唱着的一行):它是**另一句**、跟当前行无关的小字预览,
            //    该照旧排在"当前行→当前行罗马音→当前行译文"**之后**。
            //  - `line` 为 nil(前奏/间奏「•••」下方):`romanizationRowText`/`translationRowText`
            //    退到的正是 `nextLinePreviewRow` 展示的**同一句**,而且用的是 mainFont 整行
            //    大小(见 nextLinePreviewFont)、俨然就是这段时间里的"伪正文"——它必须排在
            //    自己的罗马音/译文**前面**,跟任何一句正常行"正文→罗马音→译文"同一个顺序;
            //    维持原顺序的话,读到的是"译文在前、原文在后",倒着念——截图实测复现过
            //    这个倒序。
            if line == nil {
                nextLinePreviewRow
                romanizationRow
                translationRow
            } else {
                romanizationRow
                translationRow
                nextLinePreviewRow
            }
            // 补上——第一次解锁「锁定位置」时短暂弹一次的手势提示,4 秒后
            // 自动消失,只弹一次(见 LyricsOverlayWindowController.hasShownDragHintKey
            // 处的注释)。放在播放控制按钮上面同一个位置,不额外占用固定空间。
            // 同一个位置现在还兼做全局快捷键的操作回声(见 transientHint)。
            // 在这之前,只开桌面悬浮歌词的用户按「歌词提前/延后」是**完全没有反馈**的
            // —— 那条提示只有灵动岛渲染,而这两个键恰恰是最需要看到累计值的。
            if let hint = overlayController.transientHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.8))
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    .transition(.opacity)
            } else if overlayController.showDragHint {
                Text(AppSettings.shared.overlayDragNeedsLongPress
                        ? L10n.t("长按即可拖动位置")
                        : L10n.t("按住歌词即可拖动位置"))
                    .font(.caption)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.8))
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    .transition(.opacity)
            }
        }
        // 对唱歌词按演唱者分左右。不带标记的歌 duetSide 恒为 .center,
        // 跟原来完全一致——除非「对齐方式」覆盖生效,那时
        // duetSide 会固定成用户选的方向,不带标记的普通歌也会跟着一起改对齐。
        .multilineTextAlignment(duetTextAlignment)
    }

    /// 罗马音那一行——抽成独立视图是为了在 `lyricsCardContent` 里按 `line == nil` 换序
    /// (见那边的头注),不然三行只能写死同一个先后顺序。
    @ViewBuilder private var romanizationRow: some View {
        if let roma = romanizationRowText, rowPlan.romanization?.motion == .paced, let window = pacedWindow {
            reportingTextRect(
                pacedLayerRow(key: roma, text: roma, font: playback.overlayNSFonts.romanization,
                              color: playback.displayForegroundColor.opacity(0.6), alignment: duetSide,
                              height: playback.scrollRowHeight(playback.overlayNSFonts.romanization),
                              window: window))
                .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
        } else if let roma = romanizationRowText, rowPlan.romanization?.motion == .still {
            reportingTextRect(stillUpcomingText(roma, font: playback.romanizationFont,
                                                color: playback.displayForegroundColor.opacity(0.6)))
                .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
        } else if let roma = romanizationRowText {
            reportingTextRect(
                Text(roma)
                    .font(playback.romanizationFont)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.6))
                    .overlayLineFit(playback.lineOverflow) // 换行模式如实撑高,不被裁掉
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    .overlayScroll(playback.lineOverflow == .scroll, id: roma, alignment: marqueeRestingAlignment,
                                   height: playback.scrollRowHeight(playback.overlayNSFonts.romanization)))
                // 补主歌词那边圆点+竖线占掉的宽度,理由见 speakerIndicatorInset 的注释。
                .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
        }
    }

    /// 译文那一行,同上——抽出来只为了换序,内容/样式一个字没变。
    @ViewBuilder private var translationRow: some View {
        if let tr = translationRowText, rowPlan.translation?.motion == .paced, let window = pacedWindow {
            reportingTextRect(
                pacedLayerRow(key: tr, text: tr, font: playback.overlayNSFonts.translation,
                              color: playback.displayForegroundColor.opacity(0.75), alignment: duetSide,
                              height: playback.scrollRowHeight(playback.overlayNSFonts.translation),
                              window: window))
                .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
        } else if let tr = translationRowText, rowPlan.translation?.motion == .still {
            reportingTextRect(stillUpcomingText(tr, font: playback.translationFont,
                                                color: playback.displayForegroundColor.opacity(0.75)))
                .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
        } else if let tr = translationRowText {
            reportingTextRect(
                Text(tr)
                    .font(playback.translationFont)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.75))
                    .overlayLineFit(playback.lineOverflow)
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    .overlayScroll(playback.lineOverflow == .scroll, id: tr, alignment: marqueeRestingAlignment,
                                   height: playback.scrollRowHeight(playback.overlayNSFonts.translation)))
                // 同上。
                .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
        }
    }

    /// 下一句预览那一行,同上——抽出来只为了换序,内容/样式一个字没变。
    @ViewBuilder private var nextLinePreviewRow: some View {
        if playback.showNextLinePreview, let next = nextLineText {
            // 分栏按**下一句自己的** side 算,不继承外层 VStack 的 duetAlignment
            // (那个绑的是当前行)——.frame/.multilineTextAlignment 挂在
            // reportingTextRect(...) 的返回值上、而不是塞进它的参数里,是为了不
            // 打乱 reportingTextRect 量出来的文字矩形(它要量的是文字本身的紧凑
            // 边界,不是撑满整行之后的边界,见 reportingMainLineRect 同一处理由)。
            withSpeakerIndicator(side: nextLineDecorationSide, color: playback.displayForegroundColor.opacity(0.4)) {
                reportingTextRect(nextLinePreviewContent(next))
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment(for: nextLineDuetSide))
            .multilineTextAlignment(textAlignment(for: nextLineDuetSide))
            // 补偿到"下一句自己真正的" insets,理由见 nextLineInsetsDelta 的注释——
            // 不这样做的话,下一句只是在当前行的缩进基础上尽量靠边,换演唱者时轮到它
            // 变成当前行的那一刻,缩进会重新按它自己的声部算,位置就会跳一下。
            .padding(.leading, nextLineInsetsDelta.leading)
            .padding(.trailing, nextLineInsetsDelta.trailing)
        }
    }

    /// 前奏/间奏「•••」下方那句(`line` 为 nil)能不能把罗马音逐词标在底下 —— 判据同
    /// `usesPerWordRomanization`,数据取自下一行。设置页示例行在场时 `line` 不为 nil,恒为 nil。
    private var upcomingWordGroups: [SyncedLyricWordGroup]? {
        guard rowPlan.nextPerWordRomanization, let groups = playback.nextLineWordGroups, !groups.isEmpty
        else { return nil }
        return groups
    }

    /// 下一句预览的内容。有逐词分组时按「一组一列:字在上、读音在下」排,跟这句变成当前行之后
    /// (`karaokeWordRun`)同一种版式,开唱那一刻只换颜色、不挪位置;整行罗马音那一行随之让位。
    @ViewBuilder
    private func nextLinePreviewContent(_ next: String) -> some View {
        let color = playback.displayForegroundColor.opacity(0.4)
        let still = rowPlan.next?.motion == .still
        if still, let groups = upcomingWordGroups {
            // 逐词列放不下时从开头显示、右边裁掉(列没法打「…」);放得下时交给外层按声部对齐。
            // `minWidth: 0` 不能省:否则 frame 取列的整宽、被外层居中,变成两头都裁。
            ViewThatFits(in: .horizontal) {
                upcomingGroupColumns(groups, key: next, color: color)
                upcomingGroupColumns(groups, key: next, color: color)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
            .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if still {
            stillUpcomingText(next, font: nextLinePreviewFont, color: color)
        } else if let groups = upcomingWordGroups {
            upcomingGroupColumns(groups, key: next, color: color)
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else {
            Text(next)
                .font(nextLinePreviewFont)
                .foregroundStyle(color)
                .overlayLineFit(playback.lineOverflow)
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        }
    }

    /// 逐词列本体。换行模式走 WrapLayout(长句折行,同当前行);滚动模式排成一整条(不滚,见
    /// `OverlayRowPlan.Motion.still`)。
    /// 没有读音的组也占住读音那一行的高度(透明空格),理由同 `karaokeWordRun`。
    @ViewBuilder
    private func upcomingGroupColumns(_ groups: [SyncedLyricWordGroup], key: String, color: Color) -> some View {
        let columns = ForEach(groups) { g in
            VStack(alignment: .leading, spacing: 0) {
                Text(g.words.map(\.text).joined())
                    .font(nextLinePreviewFont)
                    .foregroundStyle(color)
                // 列宽规则跟图层行同一套(`OverlayRowLayout`:读音左右各留 romaSidePadding),
                // 开唱那一刻列宽不变。
                Text(g.romanization ?? " ")
                    .font(playback.romanizationFont)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, OverlayRowLayout.romaSidePadding)
                    .opacity(g.romanization == nil ? 0 : 1)
            }
            .fixedSize()
        }
        if playback.lineOverflow == .scroll {
            HStack(alignment: .top, spacing: 0) { columns }
                .fixedSize()
        } else {
            WrapLayout(rowAlignment: nextLineRowAlignment,
                       contentKey: AnyHashable(OverlayLineKey(
                           text: key, roma: true, mainFont: nextLinePreviewFont, romaFont: playback.romanizationFont))) {
                columns
            }
        }
    }

    private var nextLineRowAlignment: WrapLayout.RowAlignment {
        switch nextLineDuetSide {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    /// 锁定态 hover 时是否露出"解锁"提示。判据本体在 Core(`OverlayControlHitTest
    /// .unlockPillShown`,有 selftest),跟 `controlsVisible` 一样不要在这里就地展开——
    /// 控制器侧 `handleMouseEvent`/`hoveredControl` 要用**同一条**,长歪就是"看不见却挡手"
    /// 或"看得见点不动"。接了 `showHoverControls`:「悬停控制条」关掉时,
    /// 锁定态也不再露出这颗图标——解锁还有菜单栏面板/菜单/全局热键三条路,不会把用户
    /// 困住,理由见 `unlockPillShown` 声明处。
    private var unlockPillVisible: Bool {
        OverlayControlHitTest.unlockPillShown(
            hovering: overlayController.isHoveringForControls,
            positionLocked: playback.lockPosition,
            hoverControlsEnabled: overlayController.showHoverControls)
    }

    /// 锁定态 hover 时露出的解锁提示——跟播放控制排共用**同一个槙位**(body 里的
    /// VStack 顶部那一格),不叠在歌词上面。
    ///
    /// **纯图标,不带「解锁」文字**:手写 HStack+Text 自己拼一套尺寸/padding 去凑
    /// "跟 playbackControls 一样大",数字调得再准也仍然是**两套独立拼出来的样式**,
    /// 观感对不齐。改成直接调 `iconButton(.unlockPill, "lock.fill", primary:
    /// true)`——跟 `playbackControls` 里其它按钮**同一个构造函数**,自带同一套
    /// 22pt/19pt 尺寸表、同一条 `ControlRectsPreferenceKey` 矩形上报(下面不再需要单独
    /// 挂一次 `.background(GeometryReader...)`),外层套的 `.padding(.horizontal, 9)
    /// .padding(.vertical, 4)` 也跟 `playbackControls` 的胶囊内边距逐字一致——保证的
    /// 不是"数字算出来一样",是"用的是同一份代码",两个状态之间不会再有肉眼可辨的差异。
    /// 图标用 `lock.fill`(锁着的锁),跟未锁定时 `iconButton(.lock, "lock.open.fill")`
    /// (开着的锁)对称:开锁图标 = 点了会锁上,锁着图标 = 点了会解锁。不再单独放"解锁"
    /// 文字——这一排其它图标(展开/设置/关闭)也都是纯图标无文字,统一风格。
    private var unlockPill: some View {
        iconButton(.unlockPill, "lock.fill", primary: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            // 玻璃跟着可见性一起关 —— 理由见 overlayCapsuleBackground 那条提醒(不关的话,
            // 设置页编辑台里这块胶囊会穿过外面的 .opacity(0) 显出来)。
            .overlayCapsuleBackground(visible: unlockPillVisible)
            // 离卡片的 4pt 不再写在这里 —— 挪到 controlsSlot 上,槽位放到卡片下方时它要翻面。
            .transition(.opacity)
    }

    private var playbackControls: some View {
        // 这排常驻在歌词上方,越小越不挡视线,间距收到 5(跟下面 iconButton 的尺寸收紧
        // 同一个方向)。
        HStack(spacing: 5) {
            iconButton(.previous, "backward.fill")
            iconButton(.playPause, playback.isPlayingNow ? "pause.fill" : "play.fill", primary: true)
            iconButton(.next, "forward.fill")
            // 「喜欢」——对应 Apple Music 里那颗心(脚本字典里的 favorited)。只有 Apple Music
            // 有这个概念,所以 playback.isFavorited 为 nil(别的播放器/没拿到自动化权限)时整个
            // 按钮不出现,而不是显示一颗永远点不亮的心。跟前面三个播放按钮同属"对当前这首歌
            // 的操作",放在同一组里、竖线之前。
            //
            // 不走 controlButton:那个包装是为播放控制准备的(先查权限、被拒就 NSSound.beep()),
            // 而这里的权限检查和乐观更新都在 PlaybackCoordinator.toggleFavorited() 里一起做了,再套一层会
            // 变成查两遍权限。
            if let favorited = playback.isFavorited {
                // .help() 去掉了:窗口常年点击穿透,SwiftUI 连 hover 都收不到,那个 tooltip
                // 永远不会弹出来 —— 留着只是一段看起来有效、其实永不触发的死代码。
                // (同一对文案在「歌词窗口」那颗心上仍在用,本地化条目不受影响。)
                iconButton(.favorite, favorited ? "heart.fill" : "heart")
                    .foregroundStyle(favorited ? Color.red : Color.white)
            }
            // 用一条竖线跟前面三个播放按钮分组,提示这是不同类别的操作——这一组是"窗口级"
            // 操作(展开/锁定/设置/关闭),不是"对当前这首歌"的操作。点了锁定之后
            // playback.lockPosition 变 true,这一整排控制按钮(包括它自己)会立刻消失
            // (见 body 里 isHoveringForControls && !playback.lockPosition 那个条件),换成
            // 悬浮在歌词上方的"解锁"提示(见 unlockPill)。淡到 0.18(原 0.25)——
            // 视觉打磨的一部分,配合下面变窄的胶囊,分隔线也收得更柔和。
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 12)
            // 参考 QQ 音乐悬浮歌词补的三个按钮。相对顺序原来照抄参考图
            // (展开 到 锁定 到 设置 到 关闭),把**锁定和设置对调**,
            // 现在是 展开 到 设置 到 锁定 到 关闭。
            //
            // 这么排也更站得住:锁定是这一排里唯一**会让整排立刻消失**的按钮(点完
            // lockPosition 变 true,controlsVisible 的条件不再成立,整条胶囊换成 unlockPill)。
            // 把它从中间挪到紧挨关闭键的位置,两个"用完这排就没了"的操作凑在一起,而设置
            // (弹菜单,排还在)跟展开(开新窗,排还在)留在前面 —— 按"点完这排还在不在"分组,
            // 比原来照搬参考图更有道理。
            iconButton(.expandToLyricsWindow, "arrow.up.left.and.arrow.down.right")
            iconButton(.settingsMenu, "gearshape.fill")
            iconButton(.lock, "lock.open.fill")
            iconButton(.closeOverlay, "xmark")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        // 玻璃必须跟着 controlsVisible 一起关,光靠外面那句 .opacity(controlsVisible ? 1 : 0)
        // 藏不住它 —— 见 overlayCapsuleBackground 那条提醒。
        .overlayCapsuleBackground(visible: controlsVisible)
        // 这排按钮挪到歌词卡片**上方**之后,隔开"按钮胶囊和歌词卡片之间"那道缝的 4pt
        // 曾写在这里(.bottom);槽位在「顶部居中」下会翻到卡片下方,那 4pt 挪到
        // controlsSlot 上按上下翻面,这里不再带。
    }

    /// 预设模式下拒绝拖动时占据控制排槽位的那条胶囊。
    ///
    /// 跟 `playbackControls` / `unlockPill` **等高**(内容钉 30pt = 图标按钮 22 + 上下 4),三个状态
    /// 在同一个槽位里切换歌词不跳。字用 12pt 半粗、白字压深色胶囊 —— 跟这排按钮同一套底,但比
    /// 图标按钮多一整句话,是这个槽位里最"重"的一个状态;它本来就该抢眼。
    private func placementLockPill(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlayCapsuleBackground(visible: true)
        .transition(.opacity)
        .accessibilityLabel(text)
    }

    // 跟 GlobalHotkeys.swift 里播放控制三个动作同一套"点了才校验权限"逻辑——没问过就
    // 顺手弹一次系统授权对话框,已经拒绝过就用 NSSound.beep() 给一个"没有生效"的听觉
    // 反馈,不需要在悬浮窗里再单独设计一套提示 UI(补上,理由跟
    // GlobalHotkeys.swift 同一处注释一致)。只有选了 Apple Music 才真的会走到这个
    // 权限检查,见 MusicAutomationPermission.checkForCurrentPlayer 注释。
    //
    // 必须用 checkForCurrentPlayerSafely(异步)——理由见该方法定义处的注释:同步版本
    // 在还没问过时会直接触达有据可查、可能永久挂起主线程的系统 API。iconButton 的
    // action 是同步闭包(Button(action:) 要求),用 Task { ... } 包一层去调用异步版本。
    // controlButton(那层"点了才校验 Apple Music 自动化权限"的包装)已经搬到
    // LyricsOverlayWindowController.withMusicPermission —— 点击既然改由控制器分发,
    // 守卫也得跟着过去,不然会变成"View 里留一份没人调的守卫"。

    // 图标用 lock.open.fill——画的是"当前是开着的"这个状态,点一下把它关上/锁定,跟
    // 另外三个播放按钮统一用 .fill 系列图标保持视觉一致。不经过 controlButton 那层
    // "先查 Apple Music 自动化权限"的守卫——锁定位置这个动作跟自动化播放控制完全不
    // 搭边,复用会引入一个跟这个按钮语义不匹配的隐藏依赖,所以两者共享的只是纯视觉
    // 样式(iconButton),各自的守卫/动作逻辑分开写。
    // lockButton 同理并入 iconButton(.lock, …),动作在控制器的 performControlAction 里。

    /// 胶囊里的一个图标。**刻意不是 Button** —— 悬浮窗常年 ignoresMouseEvents=true,
    /// SwiftUI 一个鼠标事件都收不到,挂 Button 只会留下永不触发的死代码。点击由
    /// LyricsOverlayWindowController 按下面上报的矩形自己分发。
    ///
    /// 代价(拍板接受):没有按下变暗、没有 hover 高亮。原来用的是
    /// .buttonStyle(.plain),本来就没有 hover 高亮,真正少掉的只有按下那一下的变暗。
    /// 换来的是「一个整窗布尔量同时服务点击和滚轮」这个矛盾被彻底删掉。
    ///
    /// **hover 高亮补回来了**(「悬浮歌词这上面的按钮帮我开一个鼠标移上去
    /// 有交互的动效视觉 ux 效果」)。补的不是 `.onHover` —— 那条路照旧走不通,补的是"控制器
    /// 拿它本来就在算的那次命中测试告诉我哪颗被压着"(`Chrome.hoveredControl`),视图只负责
    /// 画。指针挪到哪颗,哪颗底下浮起一圈白色圆形高亮、图标同时轻微放大,离开就收回去。
    ///
    /// **上报矩形的那层 `.background(GeometryReader…)` 必须留在最外面,悬停的变形只准
    /// 发生在它里面**。那个矩形就是控制器分发点击用的判据:一旦让它跟着 hover 一起放大,
    /// 指针停在按钮边缘时就会变成"变大到仍然命中到保持变大"和"缩回到不再命中到缩回"来回抖
    /// 的自激反馈,而且按钮的可点区域会随指针位置伸缩。所以放大只加在 `Image` 上、高亮圆
    /// 只当背景画,`.frame` 那一层的尺寸**逐像素不变**(19/22pt),外层量到的还是原来那个矩形。
    ///
    /// 按下那一下仍然没有反馈:点击是在 `.leftMouseDown` 就派发掉的,而 `.settingsMenu`
    /// 会当场弹出一个跑自己事件循环的 NSMenu —— "按下变暗、松手复原"在那条路上很容易卡成
    /// 一个永远按着的按钮。真要补,得做成不依赖 mouseUp 的定时闪一下,不是这次的范围。
    private func iconButton(_ id: OverlayControlID, _ systemName: String,
                            primary: Bool = false) -> some View {
        let hovered = overlayController.hoveredControl == id
        return Image(systemName: systemName)
            // 常驻按钮排要露出来才挡桌面,尽量小是这一排存在的前提,不是可以慢慢打磨的
            // 细节。20/24pt 的点击矩形对鼠标操作(这排按钮从不用于触摸)仍然够点,
            // 比这更小会开始不好点准。
            .font(.system(size: primary ? 12 : 10.5, weight: .semibold))
            .foregroundStyle(.white)
            // 图标自己放大一点点。1.16 是"看得出来但不跳"的量:这排图标只有 10.5/12pt,
            // 再大就会撞到 5pt 的按钮间距上,显得两颗黏在一起。
            .scaleEffect(hovered ? 1.16 : 1)
            .frame(width: primary ? 22 : 19, height: primary ? 22 : 19)
            // 高亮圆:从 0.55 倍"长"出来,而不是原地淡入 —— 原地淡入在这个尺寸上几乎看不出
            // 是个动效,"从指针底下浮起来"才有被按钮迎上来的手感。透明度 0.18 是照着胶囊
            // 自己那层玻璃定的:再高就盖过图标,再低在浅色壁纸上看不见。
            .background {
                Circle()
                    .fill(Color.white.opacity(hovered ? 0.18 : 0))
                    .scaleEffect(hovered ? 1 : 0.55)
            }
            // 弹一下再停(response 0.24 / damping 0.72),跟灵动岛那几处按压反馈同一手感;
            // reduceMotion 下不补间,但高亮照画(见 reduceMotion 声明处)。
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72),
                       value: hovered)
            // 这一层必须是最外面的(见上面那条提醒):它量的是点击判据,不能跟着悬停动。
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ControlRectsPreferenceKey.self,
                        value: [id: proxy.frame(in: .named(overlayCoordSpaceName))])
                }
            )
    }

    // "没在播放"要不要隐藏,完全交给 hideWhenNotPlaying 那个开关(见
    // LyricsOverlayWindowController)决定——这里不重复处理,否则两条路径同时生效会分不清
    // 究竟是谁在起作用,看起来像开关失灵。
    @ViewBuilder
    private var overlayBackground: some View {
        if playback.backgroundGlass {
            // 毛玻璃:系统材质垫底,用户的背景色叠在上面当着色——背景色全透明
            // 就是纯玻璃,alpha 越高越接近下面那档纯色卡片。材质默认档 .regular 而不是
            // .thick(灵动岛那档):悬浮歌词压在壁纸/别的窗口上,厚材质几乎把底下盖成
            // 一块灰板,失去"透出壁纸"的意义;默认也不是 .ultraThin,浅色壁纸上白字会不够清楚。
            // Material 全部五档都能选(见 OverlayGlassIntensity)——上面这条
            // 默认档取舍的理由仍然成立,只是从"写死"变成了"没碰过这颗设置时落在哪一档"。
            // 材质在这扇 isOpaque=false、backgroundColor=.clear 的 NSPanel 里能直接渲染,
            // NotchLyricsWindow 用 .thickMaterial 是同一条路。系统「减少透明度」开着时材质
            // 自动退成近乎不透明的底色,不用特判。
            ZStack {
                RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                    .fill(playback.backgroundGlassIntensity.material)
                RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                    .fill(playback.backgroundColor)
            }
        } else if playback.backgroundIsVisible {
            RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                .fill(playback.backgroundColor)
        } else {
            // 未开启背景色(默认状态)时保留原来近乎透明的拖拽捕获层——纯透明区域有时候
            // 完全接不到拖拽手势,这里给个极淡的背景让 isMovableByWindowBackground 在
            // 整块区域都能生效。
            Color.black.opacity(0.001)
        }
    }

    @ViewBuilder
    private var mainLine: some View {
        if let words = line?.words, rowPlan.main == .follow {
            // 滚动模式下带逐字填色的主行走 AppKit 图层路,不走下面那条 SwiftUI 的。
            // 理由(30Hz 重建 × 每帧平移 = 主线程被打满)见 OverlayScrollingLyricRow 头注。
            layerScrollingKaraokeRow(words: words)
        } else if let words = line?.words {
            // 换行模式同样走图层:按宽度切成几行,每行一条图层行各自填色(见 WrappedKaraokeRows 头注)。
            // 原来这里是 30Hz TimelineView 包整个 WrapLayout、每个字一个渐变 Text,悬浮窗每拍整窗
            // 布局 + 提交一遍(实测播放中 9.3%,滚动模式的图层路 4.0%)。
            layerWrappedKaraokeRows(words: words)
        } else if let text = line?.mainText, rowPlan.main == .paced, let window = pacedWindow {
            // 没有逐字时间轴:按这一句显示多久配速,开头停一会儿、句末前滚完,暂停就停。
            pacedLayerRow(key: text, text: text, font: playback.overlayNSFonts.main,
                          color: playback.displayForegroundColor, alignment: duetSide,
                          height: playback.scrollRowHeight(playback.overlayNSFonts.main), window: window)
        } else if let text = line?.mainText {
            Text(text)
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor)
                .overlayLineFit(playback.lineOverflow)
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                // 整行歌词(没有逐字时间轴)没有跟唱路径可走,退回时间配速的「首停到匀速到尾停」。
                .overlayScroll(playback.lineOverflow == .scroll, id: text, alignment: marqueeRestingAlignment,
                               height: playback.scrollRowHeight(playback.overlayNSFonts.main))
        } else if !playback.hasTrack {
            // 没有任何曲目时,画品牌标记「♪ Lyrimuse」而不是复用曲内间奏那个 30% 不透明度
            // 的单个「♪」标记(那是给"这里有歌词、只是此刻没词"准备的轻标记,拿来当整个
            // App 的首屏等于一片空白):音符走 SF Symbol 拼进 Text(跟着主行
            // 字体尺寸缩放、基线对齐,不用另调间距),字体/前景色/描边全部沿用歌词本身的设置,
            // 所以用户在设置里调的外观在没放歌时也能当场看见。0.7 的不透明度介于歌词正文(1.0)
            // 与状态文案(0.5)之间:要的是"看得见它在",不是跟歌词抢眼。品牌名用 `Text(verbatim:)`
            // ——不是文案、不走本地化(灵动岛刘海胶囊同款);不用字符串插值 `"\(Image) Lyrimuse"`,
            // 那会被当成 LocalizedStringKey 白查一次表。
            //
            // 排在几条状态文案**前面**而不是并列在「♪」旁边:停播时 `clearIfWasPlaying` 已经把
            // 广告/纯音乐/无歌词/hasLyricsContent 一起清掉、isPlayingNow 也是 false,理论上那几条
            // 都不会命中,唯独 `collectorNetworkDown` 是 collector 的全局健康位、跟有没有曲目无关
            // —— 没有曲目就没有要搜的东西,断网这时候对用户没有信息量,不该把首屏变成一句
            // 「网络连接失败」。有曲目之后的状态机(广告/纯音乐/无歌词/断网/搜索中/间奏 ♪)一个字不变;
            // 设置页编辑台永远带示例行(`previewLine`),走不到这里。
            (Text(Image(systemName: "music.note")) + Text(verbatim: " Lyrimuse"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.7))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackAdBreak {
            // 补上——Spotify 广告插播,同样要排在"还在搜索中"分支前面:广告
            // 的标题/歌手永远不会被写进歌词缓存(见 collector/enrich.go
            // trackEnrichment 的对应守卫),hasLyricsContent 永远拿不到内容,不排在
            // 前面的话会在整段广告期间一直显示"搜索歌词中…",见
            // PlaybackCoordinator.isCurrentTrackAdBreak 定义处的注释。
            Text(L10n.t("广告中"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isRadioTalkBreak {
            // 电台口白:这首歌放完了、台里在说话。排在"还在搜索中"之前的理由跟上面
            // 那条广告分支一样 —— 口白期间元数据还停在上一首,不拦就一直显示「搜索歌词中…」。
            Text(L10n.t("口白"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackInstrumental {
            // 补上——联网查过了、明确是纯音乐,跟下面"还在搜索中"/"真的没搜到"
            // 两种含糊状态不一样,是有明确依据的结论,必须排在"还在搜索中"这个分支前面:
            // 不然这个分支会先命中、一直显示"搜索歌词中…",纯音乐的歌只要还在播放就永远
            // 到不了这里,见 PlaybackCoordinator.isCurrentTrackInstrumental 定义处的注释。
            Text(L10n.t("纯音乐"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.currentTrackHasNoLyrics {
            // 搜完了、确实一句都没有。必须排在下面那个"搜索歌词中…"分支前面,否则这首歌
            // 只要还在播,那句"搜索中"就会一直挂着(见 PlaybackCoordinator.currentTrackHasNoLyrics)。
            Text(L10n.t("暂无歌词"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.collectorNetworkDown && !playback.hasLyricsContent {
            // 补上——必须排在下面"搜索歌词中…"**前面**,否则永远到不了这里。
            //
            // 断网时 collector 查不到任何东西,而"全空不写缓存"的守卫(见 collector 的
            // enrich.go)让 hasLyricsContent 永远是 false,于是界面一直显示"搜索歌词中…"
            // —— 那句话在断网状态下永远不会有下文,是彻头彻尾的误导。
            //
            // 排在 currentTrackHasNoLyrics **后面**:那是"查过了,这首歌确实没有",是个
            // 明确结论;而"现在没网"只说明此刻查不了。两个同时成立时前者更有信息量。
            Text(L10n.t("网络连接失败"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isPlayingNow && !playback.hasLyricsContent {
            // 换到一首还没解析过的新歌,collector 后台搜索通常要几秒——这段空窗期跟"这首
            // 歌确实没有歌词/正在间奏"共用同一个 currentLine==nil,但含义完全不同,不能
            // 都糊成一个♪符号,容易让人以为"这首歌就是没词",见 PlaybackCoordinator.hasLyricsContent
            // 注释。
            Text(L10n.t("搜索歌词中…"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if let window = playback.rawGapWindow {
            // 前奏/间奏,跟歌词窗口同一份「•••」呼吸圆点(LyricsGapDotsView)——**不设门槛**
            // (rawGapWindow,见其头注):悬浮窗没有"沿用上一行"这条退路,哪怕这段静默不到
            // 5s/6s、够不着歌词窗口 gapMarkers() 的标准,这里也要画,不然就是短前奏/短间奏
            // (比长间奏常见得多)时兜底状态机漏判、退回旧的静态「♪」。
            //
            // 不套 lyricsTextStroke:那层描边是按 alpha 阈值抠静态剪影,三颗点本身就在逐帧
            // 变透明度/缩放,阈值一卡会把暗的那颗也描成跟亮的一样重,反而破坏"点亮进度"
            // 这个信号;Apple Music 的原版三点同样不描边。
            LyricsGapDotsView(
                startMs: window.startMs, endMs: window.endMs,
                dotSize: playback.mainFontSize * 0.32, spacing: playback.mainFontSize * 0.3,
                color: playback.displayForegroundColor,
                isPlaying: playback.isPlayingNow, isVisible: previewHostVisible,
                reduceMotion: reduceMotion
            ) { date in
                (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: date)
                    ?? PlaybackCoordinator.shared.pausedPositionMs ?? window.startMs)
                    + PlaybackCoordinator.shared.currentLyricsOffsetMs
            }
            .frame(height: playback.mainFontSize * 0.5)
        } else {
            // 兜底:数据层理论上「currentLine==nil 且以上分支都不命中」必然落在
            // rawGapWindow 的覆盖范围内(前奏 index==-1 到最后一句之前的整段时间轴,
            // 不受 GapRule 门槛限制),这里留着只是防真出现口径不一致时不要开天窗
            // ——例如换歌那一拍 rawGapWindow 还没跟上新曲目的极短窗口。
            Text("♪")
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.3))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        }
    }

    // 软边渐变算法本体抽到 WordKaraokeGradient(悬浮歌词/歌词窗口共用,见该文件顶部
    // 注释),这里只负责取实际生效的前景色(playback.displayForegroundColor)、算出这个字的当前进度,两者
    // 传给共享算法。
    /// 这一行能不能把罗马音标到每个词底下。要同时满足:用户开了罗马音、这一行确实分出了
    /// 词组——日文靠分词器、中文/粤语靠字数与音节数一一对应,拼不出来
    /// (比如中文/粤语行字数跟音节数对不上)时 wordGroups 为 nil,退回整行罗马音。
    private var usesPerWordRomanization: Bool { rowPlan.perWordRomanization }

    /// 逐字主行的内容身份:当作 `wrapContentSink` 的 owner(见 WrapContentRectSink —— 读热区的一方
    /// 认它判断「这块矩形是不是这一行的」)。必须含**完整**字体身份(family/size/weight 都在 mainFont/
    /// romanizationFont 里)和罗马音开关 —— 这些一变折行就变、之前量出的矩形就作废。填色 / 描边不影响
    /// 排版,刻意不进 key。
    private var overlayLineLayoutKey: AnyHashable {
        AnyHashable(OverlayLineKey(
            text: line?.plainText,
            roma: usesPerWordRomanization,
            mainFont: playback.mainFont,
            romaFont: playback.romanizationFont))
    }

    private struct OverlayLineKey: Hashable {
        let text: String?
        let roma: Bool
        let mainFont: Font
        let romaFont: Font
    }
}

// 悬浮窗背景透明、文字直接叠在桌面内容上,颜色/内容对不上时容易糊在一起——加一圈描边
// 提高辨识度,是字幕类悬浮显示的常见做法。
//
// 描边参考 katagaki/DJDX(View Modifiers/TextStroke.swift)的做法:content 先
// .blur(radius:) 让字形轮廓往外"胀"开一圈,Canvas 里用 .addFilter(.alphaThreshold(min:))
// 把这层模糊的 alpha 通道硬切成非 0 即 1,拿这个剪影当 mask 盖一层纯色矩形垫在原始文字
// (不模糊、保留自己的渐变/颜色)下面当描边。这个技术只需要文字的"形状"(alpha 通道),
// 不关心文字本身画的是纯色还是渐变,所以能像阴影一样整体套在 mainLine 外面一次搞定,
// 不需要对每个字分别处理;开销是固定的"整体渲染一遍 + 一次模糊 + 一次阈值",不随描边
// 粗细变化。备选的"N 个方向各偏移一份内容再叠加"写法更简单,但每多一个方向就多渲染一份
// 完整内容,用在这里(mainLine 是 60fps 逐字填色的热路径)会造成 N 倍重复开销,故未采用。
// maskSource(性能审计落地):剪影 mask 的自定义静态源,nil = 直接用 content
// 本身。静态文本(罗马音/译文/占位符/整行高亮)的 content 本来就不逐帧变,自身当 symbol
// 没有任何浪费;但逐字填色路径的 content 里活跃词的渐变每 tick 都在变 —— content 值一变
// Canvas symbol 就失效,整行位图被二次合成并重跑高斯模糊 + alphaThreshold,而 mask 只
// 消费 alpha 剪影,剪影在一行存续期内根本不变。那条路径改传一份同排版的纯色副本,
// 描边层就只随换行/字体/宽度变化重建。
/// 歌词描边的几何参数。换行模式(`OptionalTextStroke`,SwiftUI)和滚动模式
/// (`OverlayScrollingLyricRow`,位图)两条渲染路都读这一份 —— 两边算法相同(剪影模糊后
/// 按透明度硬阈值出实心轮廓),参数也必须相同,否则两种模式的描边粗细不一样。
enum LyricsTextStrokeMetrics {
    /// 剪影模糊半径(点)。不做成可调项,设置里只开颜色。
    static let width: CGFloat = 1.2
    /// 描边在内容四周预留的空白(点):模糊会让剪影往外胀,不留这一圈就会被裁掉。
    static var inset: CGFloat { width * 2 }
    /// 模糊后透明度不低于它的像素整片涂成描边色。
    static let alphaThreshold: Double = 0.01
}

private struct OptionalTextStroke<MaskSource: View>: ViewModifier {
    let enabled: Bool
    let color: Color
    let maskSource: MaskSource?
    private let width = LyricsTextStrokeMetrics.width
    private let symbolID = "np-lyrics-stroke"

    init(enabled: Bool, color: Color, maskSource: MaskSource?) {
        self.enabled = enabled
        self.color = color
        self.maskSource = maskSource
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                // 模糊会让内容的可见范围往外"胀"出原本的 frame,这里预留出对应的空间,
                // 不然 Canvas 会把胀出来的部分裁掉,描边看起来缺一圈。描边通常只有一两个
                // 点粗,这圈额外留白很小,不会明显改变歌词行之间的间距。
                .padding(width * 2)
                .background(
                    Rectangle()
                        .foregroundStyle(color)
                        .mask {
                            Canvas { context, size in
                                context.addFilter(.alphaThreshold(min: LyricsTextStrokeMetrics.alphaThreshold))
                                context.drawLayer { ctx in
                                    if let resolved = context.resolveSymbol(id: symbolID) {
                                        ctx.draw(resolved, at: CGPoint(x: size.width / 2, y: size.height / 2))
                                    }
                                }
                            } symbols: {
                                // 这里的 .padding 必须跟上面 content 那道**一模一样**。
                                //
                                // Canvas 把剪影按居中绘制,只有"剪影与 content 在 canvas 里
                                // 占据同一块矩形"时才逐点对齐。content 是 `.padding(width*2)`
                                // 之后才被 background 包住的,所以 canvas 的尺寸 = 正文 + 这圈
                                // padding;而 symbols 拿到的提议宽度是 canvas 的**整宽**。
                                //
                                // 对普通 Text 无所谓 —— 它按自然宽度收缩,剪影比 canvas 窄一圈
                                // padding,居中绘制正好补回来。但逐字行是 WrapLayout,它**撑满
                                // 被提议的宽度**:content 撑满的是 padding 内的宽度、剪影撑满的
                                // 是 canvas 整宽,两者相差正好一圈 padding。
                                //
                                // 居中对齐时(非对唱歌)两边各差一半、正好抵消,看不出来;一旦
                                // 按 leading/trailing 靠边(对唱歌的左右声部),文字就分别贴在
                                // 各自矩形的边上 —— 偏移 width*2 = 2.4pt,而描边本身只有 1.2pt,
                                // 于是整圈描边甩到一侧。
                                symbolSource(content: content)
                                    .padding(width * 2)
                                    .tag(symbolID)
                                    .blur(radius: width)
                            }
                        }
                )
        } else {
            content
        }
    }

    // 剪影源:有静态副本用副本,没有就用 content 本身。副本跟 content 同排版同字体,
    // 自然尺寸一致,Canvas 居中绘制后跟被描边的内容逐点对齐。
    @ViewBuilder
    private func symbolSource(content: Content) -> some View {
        if let maskSource {
            maskSource
        } else {
            content
        }
    }
}

// internal(而不是 private):设置页顶部的实时预览要用同一个描边实现渲染同一段歌词 ——
// 预览和真窗口各写一份描边最终一定会漂,而描边是这一页最难凭想象判断效果的一项。
extension View {
    func lyricsTextStroke(_ enabled: Bool, color: Color) -> some View {
        modifier(OptionalTextStroke<EmptyView>(enabled: enabled, color: color, maskSource: nil))
    }

    /// 带静态剪影源的版本,给逐字填色这类 content 逐帧变化的热路径用 —— 见
    /// OptionalTextStroke 顶部 maskSource 的注释。
    func lyricsTextStroke<M: View>(
        _ enabled: Bool, color: Color, @ViewBuilder maskSource: () -> M
    ) -> some View {
        modifier(OptionalTextStroke(enabled: enabled, color: color, maskSource: maskSource()))
    }

    /// 悬浮窗控制胶囊的材质(用户在几套视觉方案里选了"液态玻璃 + 纯色兜底"):
    /// 有液态玻璃的系统(macOS 26+)用 `.glassEffect`,没有就退回纯色深底胶囊——跟
    /// SettingsDesignSystem.swift 的 `settingsCardBackground` 同一个取舍(`#available`
    /// 门控,旧系统不模拟液态玻璃,直接用改版前的样子)。`playbackControls`/`unlockPill`
    /// 共用这一份实现——视觉上是"同一片材质"在两种内容之间切换,不能各自写一份、观感对不上。
    ///
    /// 两个分支都补一条发丝描边,理由跟 `settingsCardBackground` 那条一致、而且更必要:
    /// 液态玻璃的可见度完全取决于它背后有什么,而这个胶囊背后是**任意桌面壁纸**(比设置页
    /// 卡片背后固定的系统窗口背景变化更大得多),描边是"胶囊边界一定看得见"的唯一保证。
    ///
    /// 液态玻璃调成深色调(`.tint(.black.opacity(...))`):胶囊里的图标固定是白色(这个
    /// 悬浮窗常年叠在任意桌面内容之上,不能像设置页卡片那样让系统默认的浅色玻璃质感决定
    /// 明暗),不调深的话亮壁纸背景下白色图标会读不清楚。不用 `.interactive()`——这扇
    /// 窗口常年 `ignoresMouseEvents`,SwiftUI 收不到真实的指针/点击事件,interactive
    /// 玻璃的悬停/按压响应永远不会触发,加了只是死代码。
    ///
    /// `visible` 不是"要不要好看"的开关,是**正确性**要求:
    /// 玻璃这一层**必须跟着可见性一起关掉**,不能只靠调用方在外面套 `.opacity(0)` 把它藏起来。
    /// `GlassEffectContainer` 会把它内部**所有**带 `.glassEffect` 的子树收拢进容器自己那一趟
    /// 玻璃渲染里(容器存在的意义就是让多块玻璃共享采样、靠近时互相融合),而容器和玻璃视图
    /// **之间**那一层 `.opacity` 在这趟渲染里不生效 —— 连玻璃托着的内容(这排图标)一起原样
    /// 画出来。真悬浮窗没有容器,所以一直是对的;而设置页的编辑台渲染的是同一份视图,
    /// `SettingsPage` 又把整页内容包在 `SettingsGlassContainer` 里(见 SettingsDesignSystem),
    /// 于是「预览里凭空多出一排点不动的播放控制按钮」。
    /// 复现与证据见 docs/features/04-desktop-overlay.md「编辑台改造」第九步。
    ///
    /// 只有**玻璃那一档**需要这个参数。纯色兜底那一档(旧系统)不进任何玻璃容器,外面
    /// 那句 `.opacity(0)` 本来就藏得住它,原样不动。可见时这条修饰符链跟改动前逐字一致 ——
    /// 真悬浮窗的观感一个像素都没变。
    ///
    /// (`glassEffect(_:in:isEnabled:)` 这台机器的 SDK 上没有,只能用分支;代价是切换那一下
    /// 玻璃层换了视图身份 —— 落在 body 那条 `.animation(_:value: controlsVisible)` 的事务里,
    /// SwiftUI 给它默认的淡入淡出,跟图标那半边同一档时长,观感上仍是一起淡进淡出。)
    @ViewBuilder
    func overlayCapsuleBackground(visible: Bool = true) -> some View {
        let shape = Capsule()
        if #available(macOS 26.0, *) {
            if visible {
                glassEffect(.regular.tint(.black.opacity(0.32)), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            } else {
                // 不套玻璃 = 不被玻璃容器收走,外面那句 .opacity(0) 才藏得住这块胶囊。
                // 玻璃和描边都不参与布局,省掉它们不改变槽位尺寸,歌词位置照旧不跳。
                self
            }
        } else {
            background(.black.opacity(0.55), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
    }
}

/// 歌词**文字**实际占据的矩形(悬浮窗坐标空间),多行/多元素取并集。
///
/// 给「指针划过时让开」用:原来的判据是整个窗口矩形,而窗口比文字大得多 —— 上下有卡片
/// 内边距和播放控制槽位、左右是 WrapLayout 撑满留下的空白,于是指针在歌词**附近**就触发
/// 了淡出(现象是的正是这个)。
///
/// reduce 必须**合并**、且跳过零矩形:树里没设过这个 key 的分支(测高度那些 Color.clear)
/// 会贡献 .zero,覆盖式写法会把真实矩形冲掉 —— 同 ControlRectsPreferenceKey 那个坑。
private struct LyricsTextRectPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard next != .zero, next.width > 0, next.height > 0 else { return }
        value = value == .zero ? next : value.union(next)
    }
}

/// 这次渲染需要多高(按钮槽位 + 歌词卡片)。真窗口拿它调窗高(updateHeight),编辑台拿它
/// 定卡高(OverlayEditorStage.cardHeight)。
///
/// reduce 必须取**最大值**,不能无脑 `value = nextValue()` —— 跟
/// `ControlsFramePreferenceKey` / `ControlRectsPreferenceKey` 那两条是同一个坑的第三例:
/// 全树只有一处真的设过这个 key(上面那个测高度的 `GeometryReader`),**其余每一个分支都在
/// 贡献 `defaultValue`(0)**;覆盖式写法的结果取决于"谁排在最后",一旦 0 排在后面,真实
/// 高度就被冲掉,消费方收到的恒为 0。
///
/// 同一次渲染里
/// `GeometryReader` 明明量到 206.2,`onPreferenceChange` 收到的却是 **0.0**(单变量对照,
/// 四个宿主一致);把这一行从
/// `value = nextValue()` 换成 `max` —— 别的一个字不改 —— 四个宿主立刻全部收到 206.2。
/// 编辑台的后果最刺眼:卡高被 `max(120, ceil(0))` 摁在 120pt 的地板上,`.clipped()` 把译文
/// 和下一句预览整个裁掉,看起来就像"编辑台不画译文"。
/// 第九步那条"探针进程里 onPreferenceChange 恒收到 0、是精简启动路径的产物"的结论**是
/// 错的**,别再照着它把这类现象当环境噪声放过 —— 病根一直在这三行里。
///
/// 取 max 而不是"跳过零值再覆盖":本 key 只有一个写入方,`max` 与"那唯一一次写入的值"恒等
/// (其余分支都是 0),内容变矮时也照样报得下去(每一趟布局都从 defaultValue 重新归约,
/// 不会记住上一趟的旧值)。
private struct ContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 每个按钮各自的矩形。
///
/// reduce 必须**合并**、而且**跳过零矩形**,不能无脑 value = nextValue():
/// 树里没设过这个 key 的分支(外层测高度的 background 里那个 Color.clear)会贡献
/// defaultValue,覆盖式写法会把真实矩形冲掉 —— 这个坑在
/// ControlsFramePreferenceKey 上实测踩过一次,见它的注释。
private struct ControlRectsPreferenceKey: PreferenceKey {
    static let defaultValue: [OverlayControlID: CGRect] = [:]
    static func reduce(value: inout [OverlayControlID: CGRect],
                       nextValue: () -> [OverlayControlID: CGRect]) {
        for (id, rect) in nextValue() where rect != .zero { value[id] = rect }
    }
}

private struct ControlsFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    // 保留最后一个**非零**报告,而不是无脑 value = nextValue()。树里没设过这个 key 的分支
    // (比如外层测高度的 background 里那个 Color.clear)会贡献 defaultValue(.zero),按原来的
    // 写法排在后面就会把真正报上来的矩形冲掉 —— 实测就是这么坏的。
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// 自动换行布局(SwiftUI Layout 协议,macOS 14+起支持,项目 Package.swift 的最低部署目标
// 早就是 macOS 14,不用额外提版本)。逐字歌词一个字一个 Text 排成一排,原来的
// HStack(spacing: 0) 从不换行,遇到宽度不够时会把每个子 Text 压缩到自己装不下、表现成
// 省略号。这个布局改成:一行装不下下一个字就自动另起一行;并且把每一行整体居中(先按
// "这一行能不能再塞下一个字"分组算出每行,再在摆放时把整行按 (可用宽度-这一行实际宽度)/2
// 整体右移),跟这个界面其它文字元素统一的居中风格保持一致。刻意不处理"单个字本身就比
// 一整行还宽"这种极端情况——真实歌词数据里几乎不会出现,出现了也就是这一"行"单独超宽,
// 不做防御性拆分。
// 从 private 改成 internal:纯几何计算的自定义换行布局,不依赖这个文件里
// 任何其它状态,"歌词窗口"(UI/LyricsWindowView.swift)复用它给当前行的逐字高亮做
// 换行,不需要另起一份重复实现——同一个 target 内跨文件访问,行为对这里的悬浮窗
// 零影响。
/// WrapLayout 排完之后文字**真正占据**的那块矩形,相对它自己 bounds 的原点。
///
/// 为什么要它、为什么是引用类型:「鼠标划过歌词才让开」需要知道文字的真实范围,而
/// WrapLayout 的布局尺寸是**撑满整宽**的(对唱左右对齐要靠这个)。Layout 协议里没法写
/// PreferenceKey,而给逐字行的每个字挂 GeometryReader 会把几何依赖拖进 60fps 填色热路径
/// (这个坑项目里踩过,见 durable note swiftui-geometry-anchor-token-drags-panel-into-
/// per-frame-rebuild)。所以走一个纯引用的旁路:布局阶段写进来,AppKit 侧的鼠标事件
/// 处理直接读 —— 不经过 SwiftUI 的渲染循环,零重建成本。
final class WrapContentRectSink {
    /// 相对 WrapLayout bounds 原点的矩形。`.zero` = 还没排过 / 没有内容。
    var rect: CGRect = .zero
    /// 这块矩形是**哪一行**排出来的(WrapLayout 的 `contentKey`)。
    ///
    /// 没有它就会读到**上一行的残值**,现象是的就是这个:间奏时主行换成
    /// `Text("♪")`(以及行级歌词、「暂无歌词」这些状态文案),**整条分支压根不经过 WrapLayout**
    /// —— 没人写 sink,而 `reportingMainLineRect` 照读不误,于是上报出"♪ 的位置 + 上一句歌词
    /// 的宽高"那么一块矩形,往右糊出一大片。`.zero` 守卫拦不住:一首逐字歌只要排过一行,
    /// sink 就再也回不到 `.zero` 了。
    ///
    /// 读取方比对 owner 而不是各自再判一次"这一行走不走 WrapLayout":那种写法要在两处保持
    /// 同步,分支结构一改就会悄悄长歪 —— 让 sink 自己带身份,读取方问的是"这块矩形是不是
    /// 我这一行的",一处判据,不会漂。
    var owner: AnyHashable?
}

struct WrapLayout: Layout {
    // 换行/对齐的几何计算全在 WrapLayoutMath(LyrimuseCore)里,selftest 够得到;这里只剩
    // Layout 协议的壳:量尺寸、缓存、把算好的坐标交给 SwiftUI 去 place。
    typealias RowAlignment = WrapLayoutMath.RowAlignment

    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 2
    var rowAlignment: RowAlignment = .center
    /// 内容身份 key:调用方把**一切影响子视图固有尺寸**的输入
    /// (行文本身份 + 完整字体身份 family/size/weight + 罗马音开关)拼成一个 Hashable
    /// 传进来 —— key 和子视图数量都没变,updateCache 就跳过整行重新测宽。nil = 关闭守卫,
    /// 保持"每回合全量重测"的旧行为(冷调用点不用改)。
    /// 漏掉一个影响尺寸的输入 = 拿陈旧尺寸错误换行,宁可多进 key 也别少。
    var contentKey: AnyHashable? = nil
    /// 可选:把"文字实际占据的矩形"写到这里,给鼠标命中判定用(见 WrapContentRectSink)。
    /// 不传就完全不参与,布局行为逐位不变。
    var contentRectSink: WrapContentRectSink? = nil

    // 量一次子视图尺寸就存住,别每次调用都重量一遍。
    //
    // 用 sample 量到的现场:"歌词窗口"播放带逐字歌词的歌时,主线程 90%+ 的时间
    // 在 NSHostingView.layout,栈顶就是这个 Layout 的 sizeThatFits。原因是逐字填色由
    // TimelineView 按渲染帧频驱动(60~120Hz),而这里**每次** sizeThatFits/placeSubviews
    // 都会 `subviews.map { $0.sizeThatFits(.unspecified) }` 把整行每个字重新测一遍 ——
    // SwiftUI 一个布局回合里本来就会多次询问尺寸,再乘以帧率,就是一秒几千次文字排版。
    //
    // 缓存原来只在"子视图集合真的变了"时重建(updateCache)——但 SwiftUI 在子视图**值**
    // 更新(逐 tick 的渐变变化)时同样回调 updateCache,于是填色期间每个布局回合仍然
    // 全量重测。补 contentKey 守卫:key/数量都没变就直接复用,顺带把 rows
    // (换行分组)也缓存住 —— 原来 sizeThatFits/placeSubviews 各自把 rows() 重算一遍。
    struct Cache {
        var sizes: [CGSize]
        var contentKey: AnyHashable?
        var subviewCount: Int
        // rows 缓存:随 sizes 重测**必须**同步失效(sizes 新 rows 旧会摆放越界/重叠),
        // key 是 (maxWidth, horizontalSpacing)——placeSubviews 的 bounds.width 偶尔不等于
        // 最后一次提案宽度,miss 了重算就是,安全。
        var rows: [WrapLayoutMath.Row]?
        var rowsWidth: CGFloat = .nan
        var rowsSpacing: CGFloat = .nan
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
              contentKey: contentKey, subviewCount: subviews.count)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        if let key = contentKey, key == cache.contentKey, subviews.count == cache.subviewCount {
            return // 内容身份没变:字体/文本都没变,尺寸和 rows 缓存照用
        }
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.contentKey = contentKey
        cache.subviewCount = subviews.count
        cache.rows = nil
        cache.rowsWidth = .nan
        cache.rowsSpacing = .nan
    }

    private func cachedRows(_ cache: inout Cache, maxWidth: CGFloat) -> [WrapLayoutMath.Row] {
        if let rows = cache.rows, cache.rowsWidth == maxWidth, cache.rowsSpacing == horizontalSpacing {
            return rows
        }
        let rows = WrapLayoutMath.rows(
            sizes: cache.sizes, maxWidth: maxWidth, horizontalSpacing: horizontalSpacing)
        cache.rows = rows
        cache.rowsWidth = maxWidth
        cache.rowsSpacing = horizontalSpacing
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let maxWidth = proposal.width, maxWidth.isFinite else {
            // 没有宽度限制 = 在问"你不换行的话要多宽"。铺成一行如实作答 ——
            // `DuetStageInsetLayout` 正是拿这一支量自然宽、决定两侧留白让多少
            // (有限提案那一支恒等于提案宽,量不出内容自己有多宽)。
            return WrapLayoutMath.unconstrainedSize(
                sizes: cache.sizes, horizontalSpacing: horizontalSpacing)
        }
        return WrapLayoutMath.totalSize(
            rows: cachedRows(&cache, maxWidth: maxWidth),
            maxWidth: maxWidth, verticalSpacing: verticalSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = cachedRows(&cache, maxWidth: bounds.width)
        if let sink = contentRectSink {
            // 记的是**相对 bounds 原点**的矩形:bounds 的绝对位置取决于父容器,而调用方
            // (LyricsOverlayView)另有一条 GeometryReader 报 WrapLayout 自己在悬浮窗坐标
            // 空间里的位置,两者在控制器侧相加。
            let local = WrapLayoutMath.contentBounds(
                rows: rows, bounds: CGRect(origin: .zero, size: bounds.size),
                verticalSpacing: verticalSpacing, rowAlignment: rowAlignment)
            sink.rect = local
            // 跟矩形一起写,缺一不可 —— 只更新 rect 会让 owner 停在上一行,等于没有守卫。
            sink.owner = contentKey
        }
        for p in WrapLayoutMath.placements(
            rows: rows,
            sizes: cache.sizes, bounds: bounds,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing,
            rowAlignment: rowAlignment)
        {
            subviews[p.index].place(
                at: p.origin, anchor: .topLeading, proposal: ProposedViewSize(p.size))
        }
    }
}

/// 「拒绝」抖动:水平位移 = amplitude · sin(2π · cycles · travel)。`travel` 每次 +1
/// (整数),sin 在整数处恰为 0,所以静止位精确归零、不会累积出半像素偏移;动画过程中走完
/// `cycles` 个完整周期。纯 GeometryEffect 位移,不参与布局 —— 上报给控制器的热区矩形和内容高度
/// 都不受影响(它们量的是布局,不是投影)。
private struct OverlayRejectShake: GeometryEffect {
    var travel: CGFloat
    var amplitude: CGFloat = 7
    var cycles: CGFloat = 3

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = amplitude * sin(travel * .pi * 2 * cycles)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

// MARK: - 「长句处理」的两个排版件

extension View {
    /// 一行放不下时这一行怎么量自己:
    /// - 换行:`fixedSize(horizontal: false, vertical: true)` —— 横向接受外部提案(于是会折行)、
    ///   纵向如实撑高不被裁。
    /// - 滚动:钉成一行、两轴都按自然尺寸报 —— 跑马灯靠这个自然宽度判断有没有溢出,
    ///   让外部提案把它压窄的话它会永远"装得下"、一格都不滚。
    @ViewBuilder
    func overlayLineFit(_ overflow: OverlayLineOverflow) -> some View {
        switch overflow {
        case .wrap: fixedSize(horizontal: false, vertical: true)
        case .scroll: lineLimit(1).fixedSize()
        }
    }

    /// 「长句处理 = 滚动」时把这一行套进跑马灯;换行模式原样返回、一个修饰符都不多套(默认档的
    /// 排版必须逐像素不变)。
    /// `height` 必须给(取 `OverlayPlayback.scrollRowHeight`):`MarqueeText` 外壳没有固有高度。
    @ViewBuilder
    func overlayScroll(_ on: Bool, id: AnyHashable, alignment: Alignment,
                       height: CGFloat, follow: MarqueeFollow? = nil) -> some View {
        if on {
            // loops: false —— 歌词行滚到底就停在句尾,等换句(id 变)才归零。
            MarqueeText(id: id, restingAlignment: alignment, follow: follow, loops: false) { self }
                .frame(height: height)
        } else {
            self
        }
    }
}
