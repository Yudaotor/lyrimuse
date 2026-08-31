import SwiftUI
import Combine
import LyrimuseCore

/// 悬浮歌词的**窄订阅代理**(2026-08-19 性能审计落地,照「歌词管理」LiveRowPlayback 的
/// 既有模式):PlaybackCoordinator 有 30+ 个 @Published、AppSettings 有 40+ 个,而
/// ObservableObject 的 objectWillChange 不分字段 —— 悬浮窗原来整对象订阅这两个单例,
/// 歌词窗口拖音量滑杆(soundVolume)、灵动岛/歌词窗口专属的封面与统计、设置页那几个
/// 与悬浮窗无关的宽度滑杆,每一次写入都会打醒它整个 body。这里只转发悬浮窗真正读的
/// 字段,值类型一律 removeDuplicates。
///
/// ⚠️ sink 里只能用收到的参数值,不能回读源属性 —— @Published 在 willSet 时机发布,
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
    @Published private(set) var isPlayingNow = false
    @Published private(set) var isFavorited: Bool?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    @Published private(set) var currentLineFillSettled = true
    /// 悬浮歌词实际显示用的前景色 —— 语义同 PlaybackCoordinator.displayForegroundColor
    /// (那份保留给设置页预览等别处),这里预组合成单个去重值:三个输入(动态高亮色/
    /// "跟随封面"开关/手选前景色)任何一个变了才发一次。
    @Published private(set) var displayForegroundColor: Color = .white
    // ---- 来自 AppSettings(只挑悬浮窗读的这一小片) ----
    @Published private(set) var lockPosition = false
    /// 指针划过时让开(见 AppSettings.overlayFadeOnHover)。
    @Published private(set) var fadeOnHover = false
    @Published private(set) var showRomanization = true
    @Published private(set) var showTranslation = false
    @Published private(set) var showNextLinePreview = true
    @Published private(set) var duetAlignmentOverride: OverlayDuetAlignmentOverride = .automatic
    @Published private(set) var mainFont: Font = .system(size: 20, weight: .bold)
    @Published private(set) var romanizationFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var translationFont: Font = .system(size: 14, weight: .regular)
    @Published private(set) var previewFont: Font = .system(size: 14, weight: .medium)
    @Published private(set) var textStrokeEnabled = false
    @Published private(set) var textStrokeColor: Color = .black.opacity(0.65)
    @Published private(set) var backgroundIsVisible = false
    @Published private(set) var backgroundColor: Color = .clear
    /// 对唱行两侧留白的基准量(见 LyricDuetLayout)。窗宽和字号都会影响它,所以在这里
    /// 预组合成一个去重值 —— 免得视图为了算这一个数字去订阅两个高频设置。
    @Published private(set) var duetInsetUnit: CGFloat = 0
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$currentLine.removeDuplicates().sink { [weak self] in self?.currentLine = $0 },
            p.$nextLineText.removeDuplicates().sink { [weak self] in self?.nextLineText = $0 },
            p.$nextLineSide.removeDuplicates().sink { [weak self] in self?.nextLineSide = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$isFavorited.removeDuplicates().sink { [weak self] in self?.isFavorited = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            Publishers.CombineLatest3(p.$artworkAccentColor, s.$followsCoverArt, s.$foregroundColor)
                .map { accent, follows, fg in (follows ? accent : nil) ?? fg }
                .removeDuplicates()
                .sink { [weak self] in self?.displayForegroundColor = $0 },
            s.$lockPosition.removeDuplicates().sink { [weak self] in self?.lockPosition = $0 },
            s.$overlayFadeOnHover.removeDuplicates().sink { [weak self] in self?.fadeOnHover = $0 },
            s.$showRomanization.removeDuplicates().sink { [weak self] in self?.showRomanization = $0 },
            s.$showTranslation.removeDuplicates().sink { [weak self] in self?.showTranslation = $0 },
            s.$showNextLinePreview.removeDuplicates().sink { [weak self] in self?.showNextLinePreview = $0 },
            s.$overlayDuetAlignmentOverride.removeDuplicates().sink { [weak self] in self?.duetAlignmentOverride = $0 },
            s.$mainFont.removeDuplicates().sink { [weak self] in self?.mainFont = $0 },
            s.$romanizationFont.removeDuplicates().sink { [weak self] in self?.romanizationFont = $0 },
            s.$translationFont.removeDuplicates().sink { [weak self] in self?.translationFont = $0 },
            s.$previewFont.removeDuplicates().sink { [weak self] in self?.previewFont = $0 },
            s.$textStrokeEnabled.removeDuplicates().sink { [weak self] in self?.textStrokeEnabled = $0 },
            s.$textStrokeColor.removeDuplicates().sink { [weak self] in self?.textStrokeColor = $0 },
            s.$backgroundIsVisible.removeDuplicates().sink { [weak self] in self?.backgroundIsVisible = $0 },
            s.$backgroundColor.removeDuplicates().sink { [weak self] in self?.backgroundColor = $0 },
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
/// 刻意简化的渲染(`OverlayLyricsCanvas`,2026-08-31 已删:只有主歌词一行,没有译文/罗马音/
/// `WrapLayout` 换行/下一句预览/对唱分声部与声部指示),两份渲染必然越漂越远 —— 而"漂"在设置页预览上
/// 是致命的:它存在的全部意义就是所见即所得。本仓已经为"同一个视觉属性两条渲染路径"付过
/// 两次账(「对齐方式」在预览条上失效并且修好后又回归;灵动岛手搓预览跟真卡差了一整排
/// 元素),这是第三次,也是最后一次 —— 编辑台从此渲染的就是真视图本身。
///
/// ⚠️ 预览侧**绝不能**拿 `LyricsOverlayWindowController.shared` 来凑这几个属性:那是个
/// `static let`,光是读一下属性就会执行 init() 建窗口并 orderFront —— 悬浮歌词关着的用户
/// 一打开设置页就会凭空多出一扇(不可见但已经装好监听器的)窗。编辑台用的是不建窗的
/// `OverlayPreviewChrome`(见 OverlayEditorStage.swift),这跟 `NotchPreviewChrome` 存在的
/// 理由是同一条。
@MainActor
protocol OverlayChromeSource: ObservableObject {
    /// 指针在窗口上 —— 播放控制排(或锁定态的解锁提示)的显示条件。
    var isHoveringForControls: Bool { get }
    /// 指针压在**歌词文字**上 —— 「指针划过时让开」的命中判据。
    var isHoveringLyrics: Bool { get }
    /// 长按拖动已经"武装",画一圈跟前景色同色的高亮描边。
    var isDragArmed: Bool { get }
    /// 第一次解锁「锁定位置」时短暂弹一次的手势提示。
    var showDragHint: Bool { get }
    /// 通用的瞬态提示文字(全局快捷键的操作回声:"歌词偏移 +0.50s"、"已锁定位置"…)。
    /// nil = 此刻没有要显示的。跟 `showDragHint` 共用同一个显示位,同时有内容时它优先
    /// —— 它是用户**刚刚按了键**的直接回声,那条一次性手势提示可以等下次。
    var transientHint: String? { get }
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
/// 2026-08-30 泛型化之后(见 `OverlayChromeSource`),Swift 不允许泛型类型持有 static
/// **存储**属性。数值和取舍一个字没变,只是换了个落脚点。
private enum OverlaySpeakerIndicator {
    /// 指示条的固定高度(2026-08-27,用户反馈"线太长了,占视野")。原来是
    /// `.frame(maxHeight: .infinity)` 跟着这一行的完整高度撑满,主行字号越大越显眼、
    /// 喧宾夺主;改成固定小尺寸,只当一个不起眼的"这里有对唱"边角标记,不管主行还是
    /// 更小号的下一句预览,视觉分量都一样克制。
    static let barHeight: CGFloat = 12
    /// dot(6) + 间距(7) + 竖线(2) + 间距(7) = 22pt —— `withSpeakerIndicator` 摆在文字
    /// 前面那一截的固定宽度,`speakerIndicatorInset(side:)` 要拿同一份值给罗马音/译文
    /// 补留白,两处必须**完全**一致(否则又是一次没对齐)。
    static let width: CGFloat = 6 + 7 + 2 + 7
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
    // 类型是**协议**而不是那个具体类(2026-08-30):设置页编辑台要渲染同一份视图,
    // 而它绝不能碰 .shared —— 见 OverlayChromeSource 顶部那条⚠️。真窗口那唯一一个
    // 构造点靠类型推导拿到 Chrome == LyricsOverlayWindowController,一个字都不用改。
    @ObservedObject var overlayController: Chrome

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
    /// 要不要画调试 HUD 那个 fps 角标(隐藏开关 np:debugHUD)。设置页预览传 false ——
    /// 那块画的是"这扇窗在桌面上长什么样",角标既不属于窗口,开着还会让 frameProbe
    /// 每帧 tick 一次。
    var showsDebugHUD: Bool = true
    /// 设置页预览的示例行,真窗口恒为 nil —— 见 OverlayPreviewLine。
    var previewLine: OverlayPreviewLine? = nil

    // 固定值,不是设置项——加一个圆角纯粹是给"背景颜色"这个设置配套的实现细节,免得
    // 用户一开背景色看到的是个生硬的直角矩形;两个参考的开源实现里圆角都不是用户可调项。
    private let overlayBackgroundCornerRadius: CGFloat = 16
    private let overlayCoordSpaceName = "overlayContent"
    /// 调试 HUD 的帧率探针。@State 而不是 @StateObject:它是纯值类型,而且**只在 HUD 开着
    /// 时**才被 tick —— 关着的时候这里恒为初始值,不产生任何开销。
    @State private var frameProbe = FrameRateProbe()
    @State private var debugFPS: Double?

    // 播放控制排该不该显示:悬停中、且没锁定位置。抽成计算属性是因为下面有三处要用同一个
    // 判断(可见性、是否接受点击、热区要不要上报),散开写容易改漏其中一处。
    private var controlsVisible: Bool {
        overlayController.isHoveringForControls && !playback.lockPosition
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
    /// ⚠️ 收在这**一个**计算属性里,而不是只在 `mainLine` 里挑一次:译文、罗马音、逐词
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
        // ⚠️ 按钮排在**歌词卡片上方**,而且**槽位常驻**(不显示时只是透明+不接受点击),两点缺一
        // 不可,原因分别是:
        //
        // 1) 放上方是用户 2026-08-07 明确要的。但如果照旧写成 `if controlsVisible { ... }`
        //    再放在歌词前面,按钮一出现就会把下面的歌词整个往下推 —— 那正是刚修掉的"悬停时
        //    歌词跳动"的反向版本(见下面 .frame(maxHeight:alignment:.top) 那段注释)。槽位常驻
        //    之后内容高度恒定,歌词的位置跟悬不悬停完全无关。
        // 2) 按钮排放在卡片**外面**而不是塞进卡片里:它自己已经是一个独立的深色胶囊
        //    (见 playbackControls 的 .background(.black.opacity(0.55), in: Capsule())),不需要
        //    借歌词卡片的背景。放外面还有个实际好处 —— 常驻槽位那块空白落在卡片之外,
        //    "深色卡片/浅色卡片"这类有可见背景的主题不会在卡片顶部多出一条空带。
        VStack(spacing: 0) {
            // 锁定态下这个槙位换成"解锁"提示,不是叠在歌词上面(2026-08-29 用户反馈"不要
            // 显示在歌词中间,也放在上面")——跟播放控制排共用同一个槙位、同一套"常驻+
            // 透明度切换"处理,理由跟下面播放控制排的注释一致:槙位常驻才能保证歌词位置
            // 不随悬不悬停跳动。
            Group {
                if playback.lockPosition {
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
                        // ⚠️ 这里**永远报真实矩形**,不能写成"没显示时报 .zero"来兼表可见性。
                        // 2026-08-07 实测坐实:那样写的话观察者收到的恒为 .zero —— 这个 key 的
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
            // 跟窗口顶边留一点呼吸空间(2026-08-31 用户实机反馈"解锁按钮跟窗口边框贴在
            // 一起了,分开一点")——这个槙位原来紧贴 VStack 顶端、跟窗口内容区顶边完全
            // 零距离,锁定态下"🔒 解锁"这颗孤立的小胶囊尤其明显。⚠️ 这个 padding 必须挂在
            // Group 上(两个分支的**外面**),不能只加给 unlockPill 自己——playbackControls
            // 不加的话,两个状态又会变回不一样高,刚修好的"锁定/解锁切换时内容整体挪动"
            // 会原样复发(见下面播放控制排/解锁提示各自注释里记的那个高度不对齐的坑)。
            .padding(.top, 4)
            lyricsCard
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
        // 「指针划过时让开」。挂在**测量之后** —— opacity 不改布局,所以放哪一层都不影响上面
        // 那三条 preference 报出去的高度/热区;放这里只是让它和上面两条动画归在一起看得清。
        // 淡出比淡入慢一点(0.18 vs 0.12):指针扫过去要立刻让开才有用,回来时慢一点更从容。
        .opacity(hoverFadeOpacity)
        .animation(.easeOut(duration: hoverFadeOpacity < 1 ? 0.12 : 0.18), value: hoverFadeOpacity)
        // 调试 HUD(隐藏开关 np:debugHUD,不进设置界面)。挂 overlay 而不是塞进 VStack:
        // 它绝不能改变布局 —— 上面三条 preference 报出去的高度/热区是窗口几何的输入,
        // HUD 一旦占位就会把窗口撑高,量到的就不是原来那套渲染了。
        .overlay(alignment: .topTrailing) {
            if showsDebugHUD, AppSettings.shared.debugHUDEnabled {
                Text(debugFPS.map { String(format: "%.0f fps", $0) } ?? "-- fps")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // 控制排每次露出来时重读一次"喜欢"状态。这条状态不跟着 2 秒轮询走(每次读要起一个
        // osascript 子进程,为一个几乎不变的布尔值那么干不值当),换歌时刷一次之外,就靠这里
        // ——正好覆盖"用户刚在 Music.app 里自己点了心、回头来看悬浮窗"这种情况。
        //
        // 走 chrome 的回调而不是直接打 PlaybackCoordinator:设置页编辑台渲染的是同一份视图,
        // 那边必须能把这条副作用空实现掉(见 OverlayChromeSource.controlsDidBecomeVisible)。
        .onChange(of: controlsVisible) { _, visible in
            if visible { overlayController.controlsDidBecomeVisible() }
        }
        // ⚠️ 内容必须**贴着窗口顶边**放,不能让它在窗口里居中。
        //
        // 在这一行之前,根视图只约束了宽度,高度就是内容的固有高度;而窗口高度有 120pt 的
        // 地板(updateHeight 里的 max(overlayDefaultHeight, …)),单行歌词的内容比它矮不少。
        // NSHostingView 比内容高的时候,SwiftUI 默认把内容**垂直居中**放 —— 于是内容高度一变,
        // 整块内容(连同歌词文字)就会在窗口里上下移动半个差值。
        //
        // 2026-08-07 用独立的 SwiftUI 沙盒逐像素量过(同样的修饰符链 + 固定 120pt 宿主):
        //   居中(改前):静止时内容顶边距窗口顶 30.0pt,内容变高后 17.0pt —— 上移 13pt
        //   贴顶(改后):两种状态都是 0.0pt —— 纹丝不动
        //
        // 贴顶还顺带修正了一处隐含假设:updateControlsHotZone 把控制排的坐标从
        // overlayCoordSpaceName 换算成窗口坐标时用的是 `window.frame.height - rect.maxY`,
        // 这只有在"内容块顶边 == 窗口顶边"时才成立。内容居中时这个前提在内容高<120 的情况下
        // 是破的;贴顶之后它才真正永远成立。
        //
        // 必须加在所有 background/测量修饰符**之后**:加在前面的话,那个测内容高度的
        // GeometryReader 量到的会变成整个窗口高度,updateHeight 就再也收不到真实内容高度了。
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 对唱歌词的左右分栏(见 LyricDuet)——这是**对齐方向**用的值,已经套过设置页的
    /// 「对齐方式」覆盖(见 OverlayDuetAlignmentOverride):自动模式下等价于旧行为
    /// (nil = 没有演唱者标记的普通歌,兜底居中);非自动模式下**每一行**(不管有没有
    /// 真实声部信息)都固定成用户选的那个方向。
    ///
    /// ⚠️ 不要把这个值传进 withSpeakerIndicator/speakerIndicatorInset/duetInsets——
    /// 那三处要的是"要不要展示对唱装饰",跟"往哪边对齐"是两件事,非自动模式下前者必须
    /// 保持关闭(见 duetDecorationSide)。
    private var duetSide: LyricDuet.Side {
        playback.duetAlignmentOverride.effectiveAlignmentSide(realSide: line?.side)
    }

    /// 下一句预览摆哪一边——**独立于当前行的 duetSide 算**,不能假定下一句跟当前句是
    /// 同一位演唱者。对唱歌交替演唱时(比如逐句男/女/男/女切换的歌),下一句几乎每次都
    /// 换边;此前预览文字固定继承 duetSide,视觉上永远像是当前这位接着唱下一句
    /// (2026-08-26 用户反馈：《All Night》女声"U got to dance all night"被摆在
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

    /// 下一句预览用的字号——只有**下一句换了个人唱**(`nextLineSide` 有值且跟当前行的
    /// side 不一样)才用跟当前行同尺寸的 `mainFont`,不缩小;其它情况(非对唱歌、对唱歌
    /// 还没到第一个声部标记的前奏、以及对唱歌里同一位连唱两句)都照旧用更小的
    /// `previewFont`,跟普通歌排版逐像素不变。「对齐方式」覆盖生效时同样退回小字号——
    /// 这项字号放大专为"提前预告即将到来的位置+字号双重跳变"设计,覆盖生效时位置已经
    /// 锁死不会跳,这个理由不再成立。
    ///
    /// 2026-08-27 用户反馈:对唱歌逐句换人唱时,下一句预览从"更小的字号"跳到"当前行的
    /// 正常字号"这个变化,跟位置的变化(见 nextLineInsetsDelta)叠在一起格外抖——普通歌
    /// 因为位置没变,这个字号跳变本来就不明显,不需要跟着一起改。
    ///
    /// ⚠️ 第一版(同一天)判据只看 `nextLineSide != nil`,没有跟当前行的 side 比较——
    /// 对唱歌里同一位演唱者连唱两句(下一句 side 跟当前行相同,不会真的跳)也被一并放大了
    /// 字号,这种情况跟普通歌一样该用小字号预览,用户随后指出要收紧这个条件:只有下一句
    /// **真的**换了人唱、即将发生位置+字号的双重跳变时才值得用大字号提前"预告"。
    /// nextLineInsetsDelta 不需要跟着改——两句 side 相同时 duetInsets(next) 跟
    /// duetInsets(current) 天然算出同一份值,delta 本来就是 0,已经隐含了这条判据。
    private var nextLinePreviewFont: Font {
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
    /// 用**跟这段文字同一个颜色**(2026-08-27 改:用户反馈"颜色也和歌词颜色统一一下"——
    /// 原来是固定的蓝/粉两色,跟"身份"绑定而跟主题脱钩,但实测这套颜色跟用户自己的配色
    /// 主题不搭。改用调用方传入的 `color`——调用方直接传这一行文字实际在用的
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
    /// 起因(2026-08-27 用户反馈"翻译比实际歌词靠前、没对齐",实测坐实):主歌词、罗马音、
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
    /// (2026-08-23 修:在此之前行级歌词的对唱分栏 100% 失效,而且前缀已被剥掉,
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
    /// 行级歌词那一支是裸 Text、frame 本身就是文字范围,sink 为 .zero 时按整 frame 走。
    private func reportingMainLineRect<V: View>(_ v: V) -> some View {
        v.background(
            GeometryReader { proxy in
                let f = proxy.frame(in: .named(overlayCoordSpaceName))
                let local = wrapContentSink.rect
                let rect = local == .zero
                    ? f
                    : CGRect(x: f.minX + local.minX, y: f.minY + local.minY,
                             width: local.width, height: local.height)
                return Color.clear.preference(key: LyricsTextRectPreferenceKey.self, value: rect)
            })
    }

    /// 按**给定**声部算两侧留白——2026-08-27 从只认 `currentLine.side` 的计算属性
    /// 改成参数化:下一句预览要按**它自己**的声部单独算一份insets,不能沿用当前行那份
    /// (见调用点 nextLineInsetsDelta 的注释)。
    ///
    /// 只有真的有声部信息才留白:side 为 nil 时(普通歌、对唱歌第一个标记之前的前奏,
    /// 以及「对齐方式」覆盖生效时——见下)两边都是 0。注意调用方**不能**传已经把 nil
    /// 兜底成 .center 的 duetSide/nextLineDuetSide,那样每一首普通歌都会凭空缩进两边——
    /// 必须传经过 `OverlayDuetAlignmentOverride.effectiveDecorationSide` 处理过的值
    /// (自动模式下就是原始的 `currentLine?.side` / `nextLineSide`,非自动模式下强制
    /// 为 nil)。
    private func duetInsets(for side: LyricDuet.Side?) -> (leading: CGFloat, trailing: CGFloat) {
        guard let side else { return (0, 0) }
        switch side {
        case .leading: return (0, playback.duetInsetUnit)
        case .trailing: return (playback.duetInsetUnit, 0)
        case .center: return (playback.duetInsetUnit, playback.duetInsetUnit)
        }
    }

    private var duetInsets: (leading: CGFloat, trailing: CGFloat) {
        duetInsets(for: playback.duetAlignmentOverride.effectiveDecorationSide(realSide: line?.side))
    }

    /// 下一句预览要额外补偿的内边距——让它按**自己真正会用到的**位置摆,不是"当前行
    /// 缩进之后、在剩下的空间里尽量靠边"。
    ///
    /// 起因(2026-08-27 用户反馈,对唱悬浮歌词逐句切换演唱者时的抖动):`lyricsCard`
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

    private var duetRowAlignment: WrapLayout.RowAlignment {
        switch duetSide {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var lyricsCard: some View {
        VStack(alignment: duetAlignment, spacing: 4) {
            withSpeakerIndicator(side: duetDecorationSide, color: playback.displayForegroundColor) {
                reportingMainLineRect(mainLine)
            }
            // 罗马音在**歌词下面、译文上面**。2026-08-17 从歌词上面挪下来 —— 歌词窗口
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
            if playback.showRomanization, !usesPerWordRomanization,
                let roma = line?.romanization
            {
                reportingTextRect(
                    Text(roma)
                        .font(playback.romanizationFont)
                        .foregroundStyle(playback.displayForegroundColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true) // 允许换行时如实撑高,不被裁掉
                        .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor))
                    // 补主歌词那边圆点+竖线占掉的宽度,理由见 speakerIndicatorInset 的注释。
                    .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                    .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
            }
            if playback.showTranslation, let tr = line?.translation {
                reportingTextRect(
                    Text(tr)
                        .font(playback.translationFont)
                        .foregroundStyle(playback.displayForegroundColor.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor))
                    // 同上。
                    .padding(.leading, speakerIndicatorInset(side: duetDecorationSide).leading)
                    .padding(.trailing, speakerIndicatorInset(side: duetDecorationSide).trailing)
            }
            if playback.showNextLinePreview, let next = nextLineText {
                // 分栏按**下一句自己的** side 算,不继承外层 VStack 的 duetAlignment
                // (那个绑的是当前行)——.frame/.multilineTextAlignment 挂在
                // reportingTextRect(...) 的返回值上、而不是塞进它的参数里,是为了不
                // 打乱 reportingTextRect 量出来的文字矩形(它要量的是文字本身的紧凑
                // 边界,不是撑满整行之后的边界,见 reportingMainLineRect 同一处理由)。
                withSpeakerIndicator(side: nextLineDecorationSide, color: playback.displayForegroundColor.opacity(0.4)) {
                    reportingTextRect(
                        Text(next)
                            .font(nextLinePreviewFont)
                            .foregroundStyle(playback.displayForegroundColor.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                            .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
                    )
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment(for: nextLineDuetSide))
                .multilineTextAlignment(textAlignment(for: nextLineDuetSide))
                // 补偿到"下一句自己真正的" insets,理由见 nextLineInsetsDelta 的注释——
                // 不这样做的话,下一句只是在当前行的缩进基础上尽量靠边,换演唱者时轮到它
                // 变成当前行的那一刻,缩进会重新按它自己的声部算,位置就会跳一下。
                .padding(.leading, nextLineInsetsDelta.leading)
                .padding(.trailing, nextLineInsetsDelta.trailing)
            }
            // 2026-08-02 补上——第一次解锁「锁定位置」时短暂弹一次的手势提示,4 秒后
            // 自动消失,只弹一次(见 LyricsOverlayWindowController.hasShownDragHintKey
            // 处的注释)。放在播放控制按钮上面同一个位置,不额外占用固定空间。
            // 2026-08-31:同一个位置现在还兼做全局快捷键的操作回声(见 transientHint)。
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
        // 对唱行的两侧留白 —— 让左右真的读成两栏,而不是只靠字的落点(见 LyricDuetLayout)。
        // 没有对唱信息的行(普通歌的每一行)insets 恒为 0,排版逐像素不变。
        .padding(.leading, duetInsets.leading)
        .padding(.trailing, duetInsets.trailing)
        .padding(.horizontal, OverlayPlayback.cardHorizontalPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: duetFrameAlignment)
        .background(overlayBackground)
        // 长按拖动"武装"后的视觉提示——一圈跟前景色同色的高亮描边,松手/取消立刻淡出。
        .overlay(
            RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                .stroke(playback.displayForegroundColor.opacity(overlayController.isDragArmed ? 0.6 : 0), lineWidth: 2)
        )
        // 对唱歌词按演唱者分左右(2026-08-14)。不带标记的歌 duetSide 恒为 .center,
        // 跟原来完全一致——除非「对齐方式」覆盖生效(2026-08-29,issue #2),那时
        // duetSide 会固定成用户选的方向,不带标记的普通歌也会跟着一起改对齐。
        .multilineTextAlignment(duetTextAlignment)
    }

    /// 锁定态 hover 时是否露出"解锁"提示——跟 `controlsVisible`(未锁定时播放控制排的
    /// 显示条件)完全对称,只是把 `!lockPosition` 换成 `lockPosition`。
    private var unlockPillVisible: Bool {
        overlayController.isHoveringForControls && playback.lockPosition
    }

    /// 锁定态 hover 时露出的解锁提示——跟播放控制排共用**同一个槙位**(body 里的
    /// VStack 顶部那一格),不是叠在歌词上面(2026-08-29 用户反馈"不要显示在歌词中间,
    /// 也放在上面")。
    ///
    /// ⚠️ **2026-08-31 从"图标+「解锁」文字的胶囊"改成纯图标**(用户实机反馈"直接把这个
    /// 解锁按钮搞小一点,和正常没锁定的那些放在同一个位置、同一个大小")——之前手写
    /// HStack+Text 自己拼一套尺寸/padding,靠数字去凑"跟 playbackControls 一样大"
    /// (`.frame(height: 22)` 那次修法),凑得再准也仍然是**两套独立拼出来的样式**,
    /// 用户还是觉得不一样。改成直接调 `iconButton(.unlockPill, "lock.fill", primary:
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
            // 玻璃跟着可见性一起关 —— 理由见 overlayCapsuleBackground 那条⚠️(不关的话,
            // 设置页编辑台里这块胶囊会穿过外面的 .opacity(0) 显出来)。
            .overlayCapsuleBackground(visible: unlockPillVisible)
            .padding(.bottom, 4)
            .transition(.opacity)
    }

    private var playbackControls: some View {
        // 2026-08-29 用户反馈"整体按钮太大,挡桌面",间距从 15 收到 5——这排常驻在歌词
        // 上方,越小越不挡视线,跟下面 iconButton 的收尺寸是同一次改动。
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
            // 悬浮在歌词上方的"解锁"提示(见 unlockPill)。淡到 0.18(原 0.25)——2026-08-29
            // 视觉打磨的一部分,配合下面变窄的胶囊,分隔线也收得更柔和。
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 12)
            // 2026-08-29 参考 QQ 音乐悬浮歌词补的三个按钮。相对顺序原来照抄参考图
            // (展开 → 锁定 → 设置 → 关闭),2026-08-31 用户要求把**锁定和设置对调**,
            // 现在是 展开 → 设置 → 锁定 → 关闭。
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
        // ⚠️ 玻璃必须跟着 controlsVisible 一起关,光靠外面那句 .opacity(controlsVisible ? 1 : 0)
        // 藏不住它 —— 见 overlayCapsuleBackground 那条⚠️。
        .overlayCapsuleBackground(visible: controlsVisible)
        // 2026-08-07 这排按钮挪到歌词卡片**上方**之后,这 4pt 的间距也跟着从 .top 翻到
        // .bottom —— 它要隔开的一直是"按钮胶囊和歌词卡片之间"那道缝。
        .padding(.bottom, 4)
    }

    // 跟 GlobalHotkeys.swift 里播放控制三个动作同一套"点了才校验权限"逻辑——没问过就
    // 顺手弹一次系统授权对话框,已经拒绝过就用 NSSound.beep() 给一个"没有生效"的听觉
    // 反馈,不需要在悬浮窗里再单独设计一套提示 UI(2026-08-02 补上,理由跟
    // GlobalHotkeys.swift 同一处注释一致)。只有选了 Apple Music 才真的会走到这个
    // 权限检查,见 MusicAutomationPermission.checkForCurrentPlayer 注释。
    //
    // ⚠️ 必须用 checkForCurrentPlayerSafely(异步)——理由见该方法定义处的注释:同步版本
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
    /// 代价(2026-08-18 拍板接受):没有按下变暗、没有 hover 高亮。原来用的是
    /// .buttonStyle(.plain),本来就没有 hover 高亮,真正少掉的只有按下那一下的变暗。
    /// 换来的是「一个整窗布尔量同时服务点击和滚轮」这个矛盾被彻底删掉。
    private func iconButton(_ id: OverlayControlID, _ systemName: String,
                            primary: Bool = false) -> some View {
        Image(systemName: systemName)
            // 2026-08-29 用户反馈"按钮太大,挡桌面",从 13/15pt、26/30pt 收到这里——
            // 常驻按钮排要露出来才挡桌面,尽量小是这一排存在的前提,不是可以慢慢打磨的
            // 细节。20/24pt 的点击矩形对鼠标操作(这排按钮从不用于触摸)仍然够点,
            // 比这更小会开始不好点准。
            .font(.system(size: primary ? 12 : 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: primary ? 22 : 19, height: primary ? 22 : 19)
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
        if playback.backgroundIsVisible {
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
        if let words = line?.words {
            // 逐字填色用 TimelineView(.animation) 直接从 PlaybackCoordinator.anchor 外推
            // 播放位置,每帧现算 fillFraction,不经过 @Published 值 + .animation() 插值
            // ——SwiftUI 对 .linear 这类曲线动画在重新定目标时是矢量相加而不是从当前值
            // 接续,高频率更新下会造成逐字流转卡顿。暂停时 anchor 会变 nil(见 fastTick
            // 守卫),paused 的第一个条件顺带把这个子树的刷新也停下来。
            //
            // 帧率上限见 WordKaraokeGradient.refreshInterval —— 2026-08-14 那次实测(主线程
            // 跑满 100%)是在歌词窗口上做的,当时只给窗口加了上限,**这里和灵动岛漏了**,
            // 一直按显示器刷新率(ProMotion 120Hz)全速跑到 2026-08-15。常驻显示的恰恰是
            // 悬浮窗,所以这处漏掉的代价比窗口那处更大。
            //
            // paused 的第二个条件(2026-08-19 性能审计落地):这一行填完之后到下一行开始
            // 之前 —— 行尾拖延、以最后一行收尾的间奏/曲末 —— currentLine 不变、所有词的
            // 渐变恒为纯色,视觉零变化,但表不停的话闭包每 tick 照跑(每词一个 LinearGradient
            // 构造,一行 20 词就是每秒 600 个,换 0 像素变化)。currentLineFillSettled 每行
            // 至多翻转两次,换行时 currentLine 赋值触发 body 重估,表自然恢复。
            //
            // ⚠️ 这里**故意**保持"TimelineView 包住整个 WrapLayout",没有照搬歌词窗口那套
            // "下沉到每个字自己挂 TimelineView"(见 LyricsWindowView.KaraokeLineText.body
            // 顶部那段)。下沉之后每个字是**各自独立**的 30Hz 时钟、tick 时刻互不对齐,
            // 描边(整行一份 mask)反而可能被一行里 N 个错开的时刻各触发一次;整行一个表
            // 30Hz 的闭包成本本来就有上限,收益配不上结构翻动。描边自身已经不再吃每帧
            // 渐变变化 —— 剪影 mask 换成了静态源,见 lyricsTextStroke(maskSource:) 那段。
            TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                    paused: !playback.isPlayingNow || playback.currentLineFillSettled)) { context in
                // 加上 currentLyricsOffsetMs——activeLine/activeLineIndex(决定"现在是哪一
                // 行哪个词")内部已经把 offsetMs 加进判断了,这里如果不加同一个偏移量,
                // "被判定成当前词"用的时间基准跟"这个词该填多满"用的时间基准就对不上:
                // 词提前变成"当前词"了,但填色进度还是按未校正的原始位置算,会出现填到一半
                // 就卡住、然后突然跳到下一个词从 0 开始的现象(2026-08-03 用户反馈实测坐实)。
                //
                // anchor/currentLyricsOffsetMs **直读**协调器而不经 playback 代理:这个闭包
                // 由 TimelineView 按帧重跑,每帧读到的都是最新值,订阅它们只会让重锚/校准
                // 多打醒整个 body(见 OverlayPlayback 的注释)。
                // ?? pausedPositionMs(2026-08-19 修,四个展示面同款):暂停时 anchor 为 nil、冻结
                // 位置在 pausedPositionMs —— 原来 `?? 0` 会让暂停触发的最后一帧渲染把填色
                // 画成整行"未唱"(时间基准塌缩到 0),补兜底后停在暂停那一刻的真实进度。
                let currentMs = (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: context.date)
                    ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                    + PlaybackCoordinator.shared.currentLyricsOffsetMs
                karaokeLineContent(words: words, atMs: currentMs)
                    // 调试 HUD 的帧率取样。挂在**这个**闭包里是刻意的:它就是逐字填色的
                    // 那条热路径,量的正是"这个 App 最贵的那段渲染实际拿到多少帧",而不是
                    // 另起一个 TimelineView 去量一个跟它无关的数字(那样量出来的是
                    // SwiftUI 愿意给一个空闲视图多少帧,毫无意义)。
                    // 开关关着时整段不执行,零成本。
                    .onChange(of: context.date) { _, date in
                        guard showsDebugHUD, AppSettings.shared.debugHUDEnabled else { return }
                        frameProbe.tick(at: date)
                        debugFPS = frameProbe.fps
                    }
            }
            .font(playback.mainFont)
            // 描边的剪影 mask 用**静态副本**当 Canvas symbol(2026-08-19 性能审计落地):
            // 原来 symbol 就是 content 本身,活跃词的渐变每 tick 一变、symbol 就失效,整行
            // 位图被二次合成并重跑高斯模糊 + alphaThreshold —— 而 mask 只消费 alpha 剪影,
            // 剪影只由文字/字体/换行决定,一行存续期内 0 次真实变化,那些滤镜 pass 全是
            // 重复计算。静态副本走同一个 karaokeLineContent(同排版/同字体/同换行),只随
            // 换行/字体/宽度变化重建。
            .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor) {
                karaokeLineContent(words: words, atMs: nil)
                    .font(playback.mainFont)
            }
        } else if let text = line?.mainText {
            Text(text)
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackAdBreak {
            // 2026-08-03 补上——Spotify 广告插播,同样要排在"还在搜索中"分支前面:广告
            // 的标题/歌手永远不会被写进歌词缓存(见 collector/enrich.go
            // trackEnrichment 的对应守卫),hasLyricsContent 永远拿不到内容,不排在
            // 前面的话会在整段广告期间一直显示"搜索歌词中…",见
            // PlaybackCoordinator.isCurrentTrackAdBreak 定义处的注释。
            Text(L10n.t("广告中"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackInstrumental {
            // 2026-08-03 补上——联网查过了、明确是纯音乐,跟下面"还在搜索中"/"真的没搜到"
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
            // 2026-08-15 补上——必须排在下面"搜索歌词中…"**前面**,否则永远到不了这里。
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
        } else {
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
    /// 词组——日文靠分词器、中文/粤语靠字数与音节数一一对应(2026-08-29 起),拼不出来
    /// (比如中文/粤语行字数跟音节数对不上)时 wordGroups 为 nil,退回整行罗马音。
    private var usesPerWordRomanization: Bool {
        playback.showRomanization && line?.wordGroups?.isEmpty == false
    }

    /// 逐字行的内容本体,mainLine 的两个消费方共用同一份排版:
    /// - `atMs` 非 nil:正常展示路径,按播放位置给每个词/组算填色渐变(TimelineView 每帧调);
    /// - `atMs` 为 nil:描边剪影的**静态副本**(同字体/同排版/同换行,纯色填充)——mask 只
    ///   消费 alpha 剪影,用它当 Canvas symbol,描边层就不再被每帧的渐变变化整行重算,
    ///   见 mainLine 里 lyricsTextStroke(maskSource:) 那段注释。
    @ViewBuilder
    private func karaokeLineContent(words: [SyncedLyricWord], atMs currentMs: Int?) -> some View {
        // 渐变素材每帧每行只取一次(纯色词跨帧复用同一实例,见 WordKaraokeGradient.Palette
        // 注释;2026-08-20 性能审计:原来逐词现造 LinearGradient+AnyShapeStyle,~95% 纯色词
        // 每帧被迫重走样式失效)。currentMs == nil 是描边剪影副本,不需要素材。
        let palette = currentMs != nil
            ? WordKaraokeGradient.palette(fg: playback.displayForegroundColor) : nil
        let romaPalette = (currentMs != nil && usesPerWordRomanization)
            ? WordKaraokeGradient.palette(fg: playback.displayForegroundColor.opacity(0.75)) : nil
        // 会自动换行的 WrapLayout——HStack(spacing: 0) 从不换行,一行装不下所有字时会把
        // 每个 Text 压缩到自己出省略号,长的逐字歌词行会直接"消失"变成一串"…"。
        // 见文件底部 WrapLayout 定义。contentKey:行身份+字体+罗马音开关 —— 都没变就跳过
        // 逐词重新测宽(见 WrapLayout.Cache 的守卫注释)。
        WrapLayout(rowAlignment: duetRowAlignment,
                   contentKey: overlayLineLayoutKey,
                   contentRectSink: wrapContentSink) {
            if let groups = line?.wordGroups, usesPerWordRomanization {
                // 一组一列:上面是这一组的字(各自逐字填色),下面是这一组的罗马音
                // (跟着整组的进度填)。列宽由 VStack 取"上下两行里更宽的那个",
                // 主文字之间的间距因此会被下面的罗马音撑开 —— Apple 那边也是这样。
                ForEach(groups) { g in
                    // 组内左对齐,跟歌词窗口/Apple Music 一致
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            // indices 而不是 Array(enumerated()):后者每帧物化一个新数组
                            // 纯为当 id,Range 零分配,下标当 id 与原 offset 语义一致。
                            ForEach(g.words.indices, id: \.self) { i in
                                wordText(g.words[i], atMs: currentMs, palette: palette)
                            }
                        }
                        if let roma = g.romanization {
                            romaText(roma, group: g, atMs: currentMs, palette: romaPalette)
                        }
                    }
                }
            } else {
                ForEach(words.indices, id: \.self) { i in
                    wordText(words[i], atMs: currentMs, palette: palette)
                }
            }
        }
    }

    /// WrapLayout 的内容身份:这些输入不变,行内每个 Text 的固有尺寸就不变,布局缓存可以
    /// 跳过整行重新测宽。⚠️ 必须含**完整**字体身份(family/size/weight 都在 mainFont/
    /// romanizationFont 里)和罗马音开关 —— 漏一样就会拿陈旧尺寸错误换行。填色渐变/描边
    /// 不影响固有尺寸,刻意不进 key。
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

    /// 一组的罗马音。填色进度按**整组**算,不跟着组里单个字跳 —— 一组常常只对应一个读音
    /// (「いつか」是一个词),按字跳会让下面这行一顿一顿的。currentMs 为 nil 时是描边
    /// 剪影副本,纯色即可(mask 只取 alpha),见 karaokeLineContent。
    private func romaText(
        _ roma: String, group: SyncedLyricWordGroup, atMs currentMs: Int?,
        palette: WordKaraokeGradient.Palette?
    ) -> some View {
        let style: AnyShapeStyle
        if let currentMs, let palette {
            // 裸起止版 fillFraction:别再每帧现造一个纯为传参的伪 SyncedLyricWord。
            let fraction = KaraokeFill.fillFraction(
                startMs: group.startMs, durationMs: max(1, group.endMs - group.startMs),
                atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            style = palette.style(left: fraction - band, right: fraction + band)
        } else {
            // 不透明黑保证任何前景色/透明度设置下剪影都完整(过 alphaThreshold)。
            style = AnyShapeStyle(Color.black)
        }
        return Text(roma)
            .font(playback.romanizationFont)
            .foregroundStyle(style)
            .lineLimit(1)
            .fixedSize()
            // 左右各留一点,免得相邻两组的罗马音贴在一起分不清词界
            .padding(.horizontal, 2)
    }

    private func wordText(
        _ w: SyncedLyricWord, atMs currentMs: Int?, palette: WordKaraokeGradient.Palette?
    ) -> some View {
        let style: AnyShapeStyle
        if let currentMs, let palette {
            let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            style = palette.style(left: fraction - band, right: fraction + band)
        } else {
            // 描边剪影副本 —— 理由见 romaText 同款分支。
            style = AnyShapeStyle(Color.black)
        }
        return Text(w.text)
            .foregroundStyle(style)
            // 故意不再包 .animation(...)——TimelineView(.animation) 已经在按渲染帧频
            // 重算真值,这里再叠一层 SwiftUI Animation 补间只会重新引入 mainLine 注释里
            // 那套矢量叠加问题。也故意不在这里单独套描边——描边统一挂在 mainLine 里
            // TimelineView 外层的 .lyricsTextStroke(maskSource:),见那边注释。
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
// maskSource(2026-08-19 性能审计落地):剪影 mask 的自定义静态源,nil = 直接用 content
// 本身。静态文本(罗马音/译文/占位符/整行高亮)的 content 本来就不逐帧变,自身当 symbol
// 没有任何浪费;但逐字填色路径的 content 里活跃词的渐变每 tick 都在变 —— content 值一变
// Canvas symbol 就失效,整行位图被二次合成并重跑高斯模糊 + alphaThreshold,而 mask 只
// 消费 alpha 剪影,剪影在一行存续期内根本不变。那条路径改传一份同排版的纯色副本,
// 描边层就只随换行/字体/宽度变化重建。
private struct OptionalTextStroke<MaskSource: View>: ViewModifier {
    let enabled: Bool
    let color: Color
    let maskSource: MaskSource?
    // 固定常量,不做成 Settings 可调项——只给颜色选择器,粗细留在代码里,参考 LyricsX
    // 同款克制。1.2pt 在这个项目常用的歌词字号下是一圈清晰但不臃肿的细描边。
    private let width: CGFloat = 1.2
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
                                context.addFilter(.alphaThreshold(min: 0.01))
                                context.drawLayer { ctx in
                                    if let resolved = context.resolveSymbol(id: symbolID) {
                                        ctx.draw(resolved, at: CGPoint(x: size.width / 2, y: size.height / 2))
                                    }
                                }
                            } symbols: {
                                // ⚠️ 这里的 .padding 必须跟上面 content 那道**一模一样**。
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
                                // 于是整圈描边甩到一侧。2026-08-23 用户报的「对唱歌词描边偏了」
                                // 就是这个。
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

    /// 悬浮窗控制胶囊的材质(2026-08-29,用户在几套视觉方案里选了"液态玻璃 + 纯色兜底"):
    /// 有液态玻璃的系统(macOS 26+)用 `.glassEffect`,没有就退回纯色深底胶囊——跟
    /// SettingsDesignSystem.swift 的 `settingsCardBackground` 同一个取舍(`#available`
    /// 门控,旧系统不模拟液态玻璃,直接用改版前的样子)。`playbackControls`/`unlockPill`
    /// 共用这一份实现——视觉上是"同一片材质"在两种内容之间切换,不能各自写一份、观感对不上。
    ///
    /// 两个分支都补一条发丝描边,理由跟 `settingsCardBackground` 那条⚠️一致、而且更必要:
    /// 液态玻璃的可见度完全取决于它背后有什么,而这个胶囊背后是**任意桌面壁纸**(比设置页
    /// 卡片背后固定的系统窗口背景变化更大得多),描边是"胶囊边界一定看得见"的唯一保证。
    ///
    /// 液态玻璃调成深色调(`.tint(.black.opacity(...))`):胶囊里的图标固定是白色(这个
    /// 悬浮窗常年叠在任意桌面内容之上,不能像设置页卡片那样让系统默认的浅色玻璃质感决定
    /// 明暗),不调深的话亮壁纸背景下白色图标会读不清楚。不用 `.interactive()`——这扇
    /// 窗口常年 `ignoresMouseEvents`,SwiftUI 收不到真实的指针/点击事件,interactive
    /// 玻璃的悬停/按压响应永远不会触发,加了只是死代码。
    ///
    /// ⚠️ `visible` 不是"要不要好看"的开关,是**正确性**要求(2026-08-30 实测坐实):
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
/// 了淡出(2026-08-23 用户报的正是这个)。
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
/// ⚠️ reduce 必须取**最大值**,不能无脑 `value = nextValue()` —— 跟
/// `ControlsFramePreferenceKey` / `ControlRectsPreferenceKey` 那两条是同一个坑的第三例:
/// 全树只有一处真的设过这个 key(上面那个测高度的 `GeometryReader`),**其余每一个分支都在
/// 贡献 `defaultValue`(0)**;覆盖式写法的结果取决于"谁排在最后",一旦 0 排在后面,真实
/// 高度就被冲掉,消费方收到的恒为 0。
///
/// 2026-08-30 实测坐实(编辑台第十一步,单变量对照,四个宿主一致):同一次渲染里
/// `GeometryReader` 明明量到 206.2,`onPreferenceChange` 收到的却是 **0.0**;把这一行从
/// `value = nextValue()` 换成 `max` —— 别的一个字不改 —— 四个宿主立刻全部收到 206.2。
/// 编辑台的后果最刺眼:卡高被 `max(120, ceil(0))` 摁在 120pt 的地板上,`.clipped()` 把译文
/// 和下一句预览整个裁掉,看起来就像"编辑台不画译文"(用户报的正是这个)。
/// ⚠️ 第九步那条"探针进程里 onPreferenceChange 恒收到 0、是精简启动路径的产物"的结论**是
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
/// ⚠️ reduce 必须**合并**、而且**跳过零矩形**,不能无脑 value = nextValue():
/// 树里没设过这个 key 的分支(外层测高度的 background 里那个 Color.clear)会贡献
/// defaultValue,覆盖式写法会把真实矩形冲掉 —— 这个坑 2026-08-07 在
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
    // 写法排在后面就会把真正报上来的矩形冲掉 —— 2026-08-07 实测就是这么坏的。
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
// 2026-07-31 从 private 改成 internal:纯几何计算的自定义换行布局,不依赖这个文件里
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
}

struct WrapLayout: Layout {
    // 换行/对齐的几何计算全在 WrapLayoutMath(LyrimuseCore)里,selftest 够得到;这里只剩
    // Layout 协议的壳:量尺寸、缓存、把算好的坐标交给 SwiftUI 去 place。
    typealias RowAlignment = WrapLayoutMath.RowAlignment

    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 2
    var rowAlignment: RowAlignment = .center
    /// 内容身份 key(2026-08-20 性能审计):调用方把**一切影响子视图固有尺寸**的输入
    /// (行文本身份 + 完整字体身份 family/size/weight + 罗马音开关)拼成一个 Hashable
    /// 传进来 —— key 和子视图数量都没变,updateCache 就跳过整行重新测宽。nil = 关闭守卫,
    /// 保持"每回合全量重测"的旧行为(冷调用点不用改)。
    /// ⚠️ 漏掉一个影响尺寸的输入 = 拿陈旧尺寸错误换行,宁可多进 key 也别少。
    var contentKey: AnyHashable? = nil
    /// 可选:把"文字实际占据的矩形"写到这里,给鼠标命中判定用(见 WrapContentRectSink)。
    /// 不传就完全不参与,布局行为逐位不变。
    var contentRectSink: WrapContentRectSink? = nil

    // 量一次子视图尺寸就存住,别每次调用都重量一遍。
    //
    // 2026-08-14 用 sample 量到的现场:"歌词窗口"播放带逐字歌词的歌时,主线程 90%+ 的时间
    // 在 NSHostingView.layout,栈顶就是这个 Layout 的 sizeThatFits。原因是逐字填色由
    // TimelineView 按渲染帧频驱动(60~120Hz),而这里**每次** sizeThatFits/placeSubviews
    // 都会 `subviews.map { $0.sizeThatFits(.unspecified) }` 把整行每个字重新测一遍 ——
    // SwiftUI 一个布局回合里本来就会多次询问尺寸,再乘以帧率,就是一秒几千次文字排版。
    //
    // 缓存原来只在"子视图集合真的变了"时重建(updateCache)——但 SwiftUI 在子视图**值**
    // 更新(逐 tick 的渐变变化)时同样回调 updateCache,于是填色期间每个布局回合仍然
    // 全量重测。2026-08-20 补 contentKey 守卫:key/数量都没变就直接复用,顺带把 rows
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
            // 没有宽度限制:理论上不会走到——调用方(mainLine)所在的 VStack 总会有一个
            // 有限宽度的提案(悬浮窗宽度固定)。兜底铺成一行,不换行。
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
