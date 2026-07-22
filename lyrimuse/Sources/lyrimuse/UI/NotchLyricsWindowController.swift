import AppKit
import SwiftUI
import Combine
import LyrimuseCore

// 灵动岛/刘海样式悬浮歌词的窗口控制器——跟 LyricsOverlayWindowController 平行、完全
// 独立的第二套实现(两种样式互斥、各自独立的窗口控制器,不去改造经典那一套让它同时
// 兼容两种形态,那样的改造复杂度和风险都更高)。跟经典悬浮窗最大的行为差异:
// 1) 位置是算出来的、贴死在屏幕顶部居中,不支持用户拖拽(见 NotchLyricsWindow 里
//    isMovableByWindowBackground = false),所以没有"锁定位置"这个概念,也不需要
//    像经典悬浮窗那样持久化位置。
// 2) 收起态(默认)只是刘海本身(或无刘海屏幕的兜底胶囊)大小;展开态靠鼠标 hover
//    触发(NotchLyricsView 的 .onHover),展开态里播放控制按钮直接常驻,不用像经典
//    悬浮窗那样再叠一层"展开后还要再单独 hover 一次才出现控制按钮"——用户明确要求
//    "展开本身就已经代表用户正在看着它"。
//
// 极其重要的一条不变量,贯穿 AppDelegate/SettingsView/MenuBarMenu 三处外部路由代码:
// 这个类是 `static let shared`,真正引用到 `.shared` 才会执行 init() 建窗口——而
// init() 里订阅 PlaybackCoordinator.$isPlayingNow 的这个 Combine sink,在订阅的
// 一瞬间就会用当下的 isVisible(默认 true)触发一次 updateActualVisibility→
// orderFront。也就是说,只要有任何代码在"经典"样式生效期间不小心引用了
// `NotchLyricsWindowController.shared`(哪怕只是拿来读一下属性),这个没人要的
// 灵动岛胶囊就会凭空出现在屏幕顶部。三处外部路由代码因此都必须做到:只有在
// settings.overlayStyle == "notch" 的分支里才会出现 `.shared` 这个词——尤其
// MenuBarMenu.swift,不能像"同时持有两个控制器的 @ObservedObject"这种最直白的写法
// 那样两个都摸一遍。
//
// 真机(有物理刘海)实测坐实两个问题、这里改成常显、内容整体下移:
// 1) 最初"收起态空胶囊+hover 展开"的设计,真机上悬停才会显示,用户明确反馈"预期是
//    常显"——歌词类信息本来就需要随时可见,不该藏在 hover 后面,砍掉了 hover 才显示
//    任何东西这层门槛,稳态(不 hover)永远显示"歌名+控制按钮+当前歌词"这一整套。
// 2) 歌词文字这一行如果跟物理刘海本身占同一条 y 范围,会被刘海真实挡住一部分——物理
//    刘海是屏幕硬件层面真实不发光的区域,不是"渲染层级"问题,任何 App 都不可能把内容
//    "显示"在那个区域本身。真正可行的做法(参考 boring.notch/DynamicNotchKit 等真实
//    刘海companion 应用的通用做法):可读内容整体让到刘海下方那一条,刘海本身所在的
//    高度只留纯黑背景(视觉上跟物理刘海融为一体),不放任何文字/图标。
//
// 2026-07-18 再次调整:hover 展开这个状态又加回来了,但跟最初那版语义完全不同——
// 最初是"不 hover 就什么都没有",现在是"稳态本来就已经完整可用,hover 只是在下面
// 多展开一块补充信息(下一句歌词预览 + 迷你进度条)",调研过 boring.notch 等真实
// 参考实现后确认这个补充思路是合理的,详见 isExpanded/expandedExtraHeight。
//
// 2026-07-19 再次调整:上面这条"稳态永远显示完整内容"只在播放中才成立——用户明确
// 要求"当前歌曲没有在播放的时候自动缩回去,不要占着空间",不是"缩到常显内容的下限
// 宽度"那种程度,而是真的缩到跟物理刘海本身(或无刘海屏幕的兜底胶囊)一样大,常显
// 内容整套不渲染。跟已有的 hideWhenNotPlaying(整个窗口隐藏)是两个独立机制,不冲突:
// 那个开关关闭时窗口本身还在(用户能看到"这里有个东西"),只是不常显内容、缩到最小,
// hover 到这一小块区域上依然能重新展开出完整内容(包括播放按钮,可以用来重新播放)。
// 见 isCollapsed/collapsedFallbackWidth。
@MainActor
final class NotchLyricsWindowController: NSWindowController, ObservableObject {
    static let shared = NotchLyricsWindowController()

    @Published private(set) var isVisible: Bool = true
    @Published private(set) var hideWhenNotPlaying: Bool = false
    // 常显内容行(歌词)相对窗口顶部的偏移——正好等于刘海(或无刘海屏幕的兜底高度)
    // 本身的高度,这样歌词永远从刘海往下才开始画,不会被刘海真实挡住一部分。
    // NotchLyricsView 读这个属性给歌词行加 .padding(.top, contentTopInset)。
    @Published private(set) var contentTopInset: CGFloat = 32
    // 刘海本身的真实宽度(无真刘海时为 0)——播放控制按钮真机反馈要挪到刘海两侧
    // ("耳朵")那两条空间里,不能摆在刘海本身的 x 范围内,物理刘海是屏幕硬件层面真实
    // 不发光的区域,横向也会跟纵向一样把落在这个范围内的内容整个挡掉。NotchLyricsView
    // 读这个属性把顶部这一行让出中间 notchWidth 宽度的空当,按钮只放在左右两侧。
    @Published private(set) var notchWidth: CGFloat = 0
    // 鼠标是否悬停在这个悬浮窗上——由 NotchLyricsView 的 .onHover 驱动,决定窗口要不要
    // 多撑出 expandedExtraHeight 那一块、以及 NotchLyricsView 要不要渲染下一句预览+
    // 迷你进度条这部分补充内容。稳态(false)本身已经是"歌名+控制+当前歌词"完整可用的
    // 一套,这个状态只影响"要不要在下面多展开一块",不影响稳态内容本身是否显示。
    @Published private(set) var isExpanded: Bool = false
    // 当前没有在播放、也没有 hover 展开时为 true——这时窗口收缩到真实刘海本身的大小
    // (无真刘海屏幕退到 collapsedFallbackWidth 那个兜底胶囊宽度),歌名/控制按钮/歌词
    // 这一整套常显内容完全不渲染,单纯是一小块跟屏幕硬件本身融为一体的黑色区域。
    // NotchLyricsView 读这个属性决定要不要渲染 topRow/lyricRow,跟窗口本身的尺寸
    // (recomputeGeometry 里同一份 collapsed 判断)保持单一数据源,不在两处各自算一遍
    // 容易失焦。
    @Published private(set) var isCollapsed: Bool = false

    // 没有真刘海的屏幕(比如 MacBook Air 全系不带刘海,只有 14"/16" MacBook Pro
    // 2021 起才有)退到的固定兜底高度:不是"关掉整个功能",是换一套不依赖真刘海几何
    // 形状的兜底样式,宽度沿用下面 contentWidth 算出来的常显宽度。
    private static let fallbackNotchHeight: CGFloat = 32
    // 收起态(没在播放、没 hover)在无真刘海屏幕上退到的兜底宽度——真刘海屏幕收起态
    // 直接用 notchWidth 本身(跟硬件刘海严丝合缝),这个值只在没有真刘海可以贴的场景
    // 才用得到,给一个能装得下一小块胶囊、不会小到近乎看不见的经验值。
    private static let collapsedFallbackWidth: CGFloat = 120
    // 常显内容行的固定高度(一行歌词 + 3 个播放控制按钮那一行的高度经验取值)——窗口
    // 总高度 = 刘海本身高度(或兜底高度)+ 这一行高度,让内容行完整落在刘海下方。
    private static let contentHeight: CGFloat = 44
    // 2026-07-22:宽度改回固定值——中间有一版改成按当前这一句歌词的真实文字宽度动态算
    // (真机反馈"歌词大部分时候没这么长,固定宽度显得空着一大截"),但用户后来反馈"歌词
    // 一句太长时灵动岛整体长度会变化,这是非预期的,预期是多大就多大,不会随着歌词发生
    // 变化"——两条反馈方向相反,这次按最新反馈改回固定宽度。数值本身(默认 360)以及
    // 用户随后要求的"能在设置里调这个固定宽度"这条,都挪进了 AppSettings.
    // notchContentWidth(默认值就定义在那一处,这里不重复放一份、避免两处数字不同步),
    // 不再是这个文件自己的常量。超长歌词交给 NotchLyricsView 的 MarqueeText 来回滚动
    // 展示,不再靠加宽窗口解决。
    // 顶行左右两只"耳朵"各自的最低可用宽度(歌名文字 + 3 个播放控制按钮都要放得下,
    // 不能比这更窄)——算下限时要把这两只耳朵 + 刘海本身宽度 + 左右 padding 都算进去,
    // 不能让总宽度小到连按钮都摆不下(真机踩过这个坑,按钮被裁一截)。真刘海本身可能
    // 相当宽(这台机器实测约 179pt)、或者用户把设置里的宽度调得很小,这层下限比用户
    // 设的宽度还宽的话取这层。
    private static let minEarWidth: CGFloat = 70
    // hover 展开时在 contentSize 之外额外撑出的高度,放下一句歌词预览 + 迷你进度条
    // 这两样调研后确定值得加的补充信息(调研结论:封面/更多控制按钮都不如这两样贴合
    // "歌词类产品"的定位,专辑封面另外还受限于本地播放源目前没有转发 artwork 数据)。
    private static let expandedExtraHeight: CGFloat = 40

    private var isPlayingObserver: AnyCancellable?
    private var screenParamsObserver: NSObjectProtocol?
    // 真机实测坐实的一个坑:窗口 hover 展开/收起时靠 autoresizingMask 让 NSHostingView
    // 跟着 window.setFrame 自动同步尺寸——AppKit 层面这个同步是真的发生了(window.frame/
    // contentView.frame 都能读到新的高度),但 NSHostingView 内部的 SwiftUI 布局树没有
    // 跟着重新走一遍布局,导致新撑出来的那一段区域(展开态多出来的 40pt)在屏幕上什么都
    // 不画,肉眼看起来完全没有展开。直接持有这个引用、在 recomputeGeometry 里手动把它的
    // frame 也显式设一遍(而不是只信任 autoresizingMask 那条隐式路径),能让 SwiftUI 真正
    // 重新布局这一块。
    private var hostingView: NSHostingView<NotchLyricsView>?

    convenience init() {
        // 初始 contentRect 只是占位——真正的尺寸/位置由下面 recomputeGeometry() 按
        // 当前屏幕几何重新算一遍并 setFrame,这里传什么都会被立刻覆盖掉。
        let placeholder = NSSize(width: AppSettings.shared.notchContentWidth, height: Self.fallbackNotchHeight + Self.contentHeight)
        let panel = NotchLyricsWindow(contentRect: NSRect(origin: .zero, size: placeholder))
        self.init(window: panel)

        let hosting = NSHostingView(rootView: NotchLyricsView(controller: self))
        hosting.frame = NSRect(origin: .zero, size: placeholder)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        hostingView = hosting

        recomputeGeometry(animate: false)

        // 外接显示器插拔/切换分辨率时,"这台屏幕有没有真刘海"这个前提可能整个变了
        // (外接显示器基本不会有刘海)——重新算一遍,思路照抄经典悬浮窗
        // LyricsOverlayWindowController.restoredOrigin() 里"配置可能变了、需要重新
        // 夹回可见区域"那段既有处理。系统触发的几何变化不需要过渡动画,直接跳变。
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recomputeGeometry(animate: false) }
        }

        // 跟 LyricsOverlayWindowController 同一个坑同一个修法:sink 闭包里必须用参数
        // 里收到的 isPlaying,不能在闭包内另外去读 PlaybackCoordinator.shared.
        // isPlayingNow 这个存储属性——@Published 的 willSet 在真正写入新值*之前*就
        // 已经发布,这个时间点读存储属性拿到的是上一次的旧值,细节见
        // LyricsOverlayWindowController.swift 同一处注释,不重复展开。
        isPlayingObserver = PlaybackCoordinator.shared.$isPlayingNow.sink { [weak self] isPlaying in
            self?.updateActualVisibility(isPlayingNow: isPlaying)
            // 当前没有在播放(且没 hover 展开)时收缩到刘海本身大小——同一个坑同一个
            // 修法,必须把 sink 参数里的 isPlaying 显式传下去,不能让 recomputeGeometry
            // 内部再去读 PlaybackCoordinator.shared.isPlayingNow 这个存储属性本身
            // (这一刻读到的还是切换前的旧值,原因见上面 isPlayingObserver 声明处注释)。
            self?.recomputeGeometry(animate: true, isPlayingOverride: isPlaying)
        }

        // 2026-07-22:原来这里还订阅了 currentLine、每次换歌词就重新 recomputeGeometry
        // 一遍——那是宽度按歌词文字宽度动态算的年代才需要的,换一句歌词宽度可能就变了。
        // 宽度改回固定值之后,recomputeGeometry 的结果不再跟 currentLine 有任何关系,
        // 这个订阅留着就是纯粹的空转(每换一句歌词都重算一遍、结果每次都跟上一次一样),
        // 删掉了,不留奇怪的死代码等着以后的人猜"这个订阅是干嘛的"。
    }

    deinit {
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingNow)
    }

    // 跟经典悬浮窗共用同一个"暂停/无播放时隐藏"设置项(AppSettings.hideWhenNotPlaying),
    // 不新增独立开关——两种样式各自独立调用这个方法应用同一个设置值。
    func setHideWhenNotPlaying(_ hide: Bool) {
        hideWhenNotPlaying = hide
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingNow)
    }

    // 跟经典悬浮窗共用同一个"截屏/录屏时隐藏"设置项(AppSettings.hideDuringScreenCapture),
    // 不新增独立开关——两种样式各自独立调用这个方法应用同一个设置值。
    func setHiddenFromCapture(_ hidden: Bool) {
        window?.sharingType = hidden ? .none : .readWrite
    }

    // NotchLyricsView 的 .onHover 调这个。用 AppKit 原生的 NSWindow.setFrame(animate:)
    // 而不是 SwiftUI 的 withAnimation 包一层——跟经典悬浮窗
    // LyricsOverlayWindowController.updateHeight() 同一个既有模式,窗口级尺寸变化交给
    // AppKit 自己的动画,不叠加两套动画系统。
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        recomputeGeometry(animate: false)
    }

    // 设置里"灵动岛宽度"滑块调用——跟经典悬浮窗的 setWidth(_:) 不是同一套实现:那个
    // 需要"保持窗口中心点不变"的增量调整,因为经典悬浮窗的位置是用户拖拽/持久化的,直接
    // 重设宽度容易把窗口推出屏幕外。灵动岛完全不是这么回事:它的位置从来不是持久化的,
    // 每次都是 recomputeGeometry 里用当前屏幕的 geo.centerX 重新居中算出来的,所以这里
    // 直接把完整的几何计算(位置+尺寸)重新走一遍就行,不用另外单独维护一份"保持居中"
    // 的增量逻辑——两者殊途同归都是居中,只是灵动岛的居中本来就是每次全量重算,天然免疫
    // 经典悬浮窗那个坑。
    func applyContentWidthSetting() {
        recomputeGeometry(animate: true)
    }

    private func updateActualVisibility(isPlayingNow: Bool) {
        let shouldShow = isVisible && (!hideWhenNotPlaying || isPlayingNow)
        // orderFrontRegardless(),不是 orderFront(nil)——这个 App 是 .accessory 策略、
        // 从不激活成前台 App,参照的真实开源实现(NotchDrop/DynamicNotchKit)贴刘海用的
        // 都是这个,不看"当前是否是活跃 App"这个前提就把窗口调到最前。
        if shouldShow { window?.orderFrontRegardless() } else { window?.orderOut(nil) }
    }

    private struct NotchGeometry {
        // 刘海本身(或无刘海屏幕的兜底值)的高度——这一整条永远只留纯黑背景,不放
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
    private static func geometry(for screen: NSScreen) -> NotchGeometry {
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            let centerX = (leftArea.maxX + rightArea.minX) / 2
            let notchWidth = rightArea.minX - leftArea.maxX
            return NotchGeometry(notchHeight: notchHeight, centerX: centerX, notchWidth: notchWidth)
        }
        return NotchGeometry(notchHeight: fallbackNotchHeight, centerX: screen.frame.midX, notchWidth: 0)
    }

    // 用户在设置里调的固定宽度(baseWidth,即 AppSettings.notchContentWidth)+ 耳朵下限
    // 两者取较大值——大多数情况下就是 baseWidth 本身,只有真刘海本身特别宽(这台机器
    // 实测约 179pt)、或者用户把 baseWidth 调得很小,把两只耳朵挤到摆不下按钮时才会
    // 突破 baseWidth(这层下限保护的是"按钮不被裁",不是"给歌词文字腾地方",不跟当前
    // 是哪句歌词、歌词有多长有任何关系)。
    private static func contentWidth(baseWidth: CGFloat, notchWidth: CGFloat) -> CGFloat {
        let earBasedFloor = notchWidth + minEarWidth * 2 + 20
        return max(baseWidth, earBasedFloor)
    }

    // 顶边固定贴在屏幕最顶端(screen.frame.maxY)、水平居中对齐刘海中心点、总高度 =
    // 刘海高度 + 内容行高度(+ hover 展开时再加 expandedExtraHeight)、宽度固定(见
    // contentWidth(baseWidth:notchWidth:))。用 NSScreen.main(当前有键盘焦点/菜单栏
    // 所在的那块屏幕)而不是记忆某一块固定屏幕——多屏环境下,这跟"灵动岛只应该出现在
    // 当前主屏"这个直觉一致。
    // isPlayingOverride 只在 isPlayingObserver 的 sink 闭包里传——那个时间点闭包参数
    // 才是真正的新值,读存储属性本身拿到的还是旧值(见 init() 里那处注释)。其余调用
    // 场景(screenParamsObserver/setExpanded/init 本身)都不在那个时序陷阱里,直接读
    // PlaybackCoordinator.shared.isPlayingNow 就是准确的当前值。
    private func recomputeGeometry(animate: Bool, isPlayingOverride: Bool? = nil) {
        guard let window, let screen = NSScreen.main else { return }
        let geo = Self.geometry(for: screen)
        contentTopInset = geo.notchHeight
        notchWidth = geo.notchWidth
        let isPlayingNow = isPlayingOverride ?? PlaybackCoordinator.shared.isPlayingNow
        // 没在播放、也没 hover 展开——收缩到刘海本身大小,常显内容整套不渲染(见
        // NotchLyricsView 里对 controller.isCollapsed 的判断)。用户明确要求"缩到正常
        // 机器刘海的大小",不是简单地把常显内容那份宽度缩到下限——下限本身仍然要给
        // 两只耳朵留够按钮/歌名的空间,不是"刘海大小"。
        let collapsed = !isPlayingNow && !isExpanded
        isCollapsed = collapsed
        let size: NSSize
        if collapsed {
            let collapsedWidth = geo.notchWidth > 0 ? geo.notchWidth : Self.collapsedFallbackWidth
            size = NSSize(width: collapsedWidth, height: geo.notchHeight)
        } else {
            let extra = isExpanded ? Self.expandedExtraHeight : 0
            let width = Self.contentWidth(baseWidth: AppSettings.shared.notchContentWidth, notchWidth: geo.notchWidth)
            size = NSSize(width: width, height: geo.notchHeight + Self.contentHeight + extra)
        }
        let frame = NSRect(
            x: geo.centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        window.setFrame(frame, display: true, animate: animate)
        hostingView?.frame = NSRect(origin: .zero, size: size)
    }
}
