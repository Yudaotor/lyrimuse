import AppKit
import SwiftUI
import Combine
import LyrimuseCore

// 文件级常量(跟 LyricsOverlayWindowController.swift 同一个理由不挂在 @MainActor 类
// 上)。2026-08-03 补上——"显示灵动岛歌词"这个菜单开关(isVisible)之前只存在内存里,
// setVisible() 只改了 @Published 属性、从没写过 UserDefaults。用户关掉灵动岛后退出
// 重开 App,isVisible 又从声明处的硬编码默认值 true 重新起步,违背用户上一次的选择、
// 无条件重新冒出来——这个窗口 level 是 .screenSaver(见 NotchLyricsWindow.swift,
// 特意调到比系统菜单栏还高才能贴住刘海),意外重新出现时会整个盖在菜单栏那一整条上,
// 挡住(包括这个 App 自己的)菜单栏图标,肉眼看起来像"菜单栏图标跑到灵动岛的位置去
// 了"——实际是图标一直没动,只是被这个不该出现的高层级窗口盖住了。跟经典悬浮窗
// (overlayVisibleKey)是各自独立的 key,两种样式的"显示/隐藏"偏好不共用。
// isVisible 的持久化在 2026-08-05 并进了 AppSettings.notchOverlayEnabled(原来这里有一个
// 私有的 np:notchOverlayVisible,跟设置页那个开关是同一件事的两个真值),详见 setVisible(_:)
// 和 AppSettings.init() 里的迁移注释。

// 灵动岛/刘海样式悬浮歌词的窗口控制器——跟 LyricsOverlayWindowController 平行、完全
// 独立的第二套实现(两种样式互斥、各自独立的窗口控制器,不去改造经典那一套让它同时
// 兼容两种形态,那样的改造复杂度和风险都更高)。跟经典悬浮窗的行为差异:
// 1) 位置是算出来的、贴死在屏幕顶部居中,不支持用户拖拽(见 NotchLyricsWindow 里
//    isMovableByWindowBackground = false),所以没有"锁定位置"这个概念,也不需要
//    像经典悬浮窗那样持久化位置。
// 2) 稳态(没在播放、没 hover)缩到刘海本身(或无刘海屏幕的兜底胶囊)大小;播放中
//    常显"歌名+控制按钮+当前歌词"整套,不需要 hover 才能看到——歌词类信息本来就该
//    随时可见。hover 时在下面多展开一块补充信息(下一句歌词预览+迷你进度条),展开
//    态里播放控制按钮直接常驻,不需要再单独 hover 一次才出现。
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
// 歌词文字这一行让到物理刘海下方那一条,刘海本身所在的高度只留纯黑背景——物理刘海是
// 屏幕硬件层面真实不发光的区域,不是"渲染层级"问题,任何 App 都不可能把内容"显示"在
// 那个区域本身(参考 boring.notch/DynamicNotchKit 等真实刘海companion 应用的做法)。
//
// isCollapsed(缩到刘海大小,内容整套不渲染)跟已有的 hideWhenNotPlaying(整个窗口
// 隐藏)是两个独立机制,不冲突:后者关闭时窗口本身还在(用户能看到"这里有个东西"),
// 只是不常显内容、缩到最小,hover 到这一小块区域上依然能重新展开出完整内容(包括
// 播放按钮,可以用来重新播放)。见 isCollapsed/collapsedFallbackWidth。
@MainActor
// 已经有 NotchChromeSource 要的全部四个属性和 setExpanded,只是把这层契约显式写出来
// —— 这样「外观」页的预览可以拿一个轻量替身装同一份 NotchLyricsView。
final class NotchLyricsWindowController: NSWindowController, ObservableObject, NotchChromeSource {
    static let shared = NotchLyricsWindowController()

    // 真值在 AppSettings.notchOverlayEnabled,这里只是它的镜像(菜单栏要观察这个
    // @Published)。只能经 setVisible(_:) 改,那是打开/关闭的唯一入口。
    @Published private(set) var isVisible: Bool = AppSettings.shared.notchOverlayEnabled
    @Published private(set) var hideWhenNotPlaying: Bool = false
    // 常显内容行(歌词)相对窗口顶部的偏移——正好等于刘海(或无刘海屏幕的兜底高度)
    // 本身的高度,这样歌词永远从刘海往下才开始画,不会被刘海真实挡住一部分。
    // NotchLyricsView 读这个属性给歌词行加 .padding(.top, contentTopInset)。
    @Published private(set) var contentTopInset: CGFloat = 32
    // 刘海本身的真实宽度(无真刘海时为 0)——播放控制按钮要挪到刘海两侧("耳朵")那
    // 两条空间里,不能摆在刘海本身的 x 范围内:物理刘海是屏幕硬件层面真实不发光的
    // 区域,横向也会跟纵向一样把落在这个范围内的内容整个挡掉。NotchLyricsView 读这个
    // 属性把顶部这一行让出中间 notchWidth 宽度的空当,按钮只放在左右两侧。
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
    // 数值本身在 NotchMetrics.compactRowHeight —— 视图那边按同一个数字排版,
    // 两处各写一份 44 迟早会漂。
    private static var contentHeight: CGFloat { NotchMetrics.compactRowHeight }
    // 宽度是固定值,不随当前歌词文字宽度动态变化——预期是多大就多大,不会随着歌词
    // 发生变化。数值本身(默认 360)以及用户可调的设置项都定义在 AppSettings.
    // notchContentWidth(这里不重复放一份、避免两处数字不同步)。超长歌词交给
    // NotchLyricsView 的 MarqueeText 来回滚动展示,不靠加宽窗口解决。
    // 顶行左右两只"耳朵"各自的最低可用宽度(歌名文字 + 3 个播放控制按钮都要放得下,
    // 不能比这更窄)——算下限时要把这两只耳朵 + 刘海本身宽度 + 左右 padding 都算进去。
    // 真刘海本身可能相当宽(实测有的机器约 179pt)、或者用户把设置里的宽度调得很小,
    // 这层下限比用户设的宽度还宽的话取这层,保证按钮不会被裁切。
    private static let minEarWidth: CGFloat = 70
    // hover 展开时在 contentSize 之外额外撑出的高度,放下一句歌词预览 + 迷你进度条这
    // 两样补充信息(更多控制按钮都不如这两样贴合"歌词类产品"的定位)。专辑封面不在这一块
    // ——它常显在歌词行的尾端(见 NotchLyricsView.artworkThumbnail),不需要 hover 才出现,
    // 也不占额外高度。
    // 同上,单一来源在 NotchMetrics。
    private static var expandedExtraHeight: CGFloat { NotchMetrics.expandedExtraHeight }

    private var isPlayingObserver: AnyCancellable?
    private var screenParamsObserver: NSObjectProtocol?
    // 一个真实的坑:窗口 hover 展开/收起时靠 autoresizingMask 让 NSHostingView
    // 跟着 window.setFrame 自动同步尺寸——AppKit 层面这个同步是真的发生了(window.frame/
    // contentView.frame 都能读到新的高度),但 NSHostingView 内部的 SwiftUI 布局树没有
    // 跟着重新走一遍布局,导致新撑出来的那一段区域(展开态多出来的 40pt)在屏幕上什么都
    // 不画,肉眼看起来完全没有展开。直接持有这个引用、在 recomputeGeometry 里手动把它的
    // frame 也显式设一遍(而不是只信任 autoresizingMask 那条隐式路径),能让 SwiftUI 真正
    // 重新布局这一块。
    private var hostingView: NSHostingView<NotchLyricsView<NotchLyricsWindowController>>?

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
        isPlayingObserver = PlaybackCoordinator.shared.$isPlayingSmoothed.sink { [weak self] isPlaying in
            self?.updateActualVisibility(isPlayingNow: isPlaying)
            // 当前没有在播放(且没 hover 展开)时收缩到刘海本身大小——同一个坑同一个
            // 修法,必须把 sink 参数里的 isPlaying 显式传下去,不能让 recomputeGeometry
            // 内部再去读 PlaybackCoordinator.shared.isPlayingNow 这个存储属性本身
            // (这一刻读到的还是切换前的旧值,原因见上面 isPlayingObserver 声明处注释)。
            self?.recomputeGeometry(animate: true, isPlayingOverride: isPlaying)
        }

        // 宽度固定后,recomputeGeometry 的结果不再跟 currentLine 有任何关系,不需要
        // 额外订阅 currentLine 来触发重算。
    }

    deinit {
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
    }

    // 打开/关闭"灵动岛歌词"的**唯一**入口——设置页那个 Toggle、菜单栏"显示灵动岛歌词"两处
    // 都必须走这里。理由跟 LyricsOverlayWindowController.setVisible(_:) 完全对称,不重复展开:
    // 统一写回 AppSettings.notchOverlayEnabled(由它的 didSet 持久化),打开时顺手把两个已
    // 配置好的隐藏偏好也应用上。
    func setVisible(_ visible: Bool) {
        isVisible = visible
        AppSettings.shared.notchOverlayEnabled = visible
        if visible {
            setHiddenFromCapture(AppSettings.shared.hideDuringScreenCapture)
            setHideWhenNotPlaying(AppSettings.shared.hideWhenNotPlaying)
        }
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    // 跟经典悬浮窗共用同一个"暂停/无播放时隐藏"设置项(AppSettings.hideWhenNotPlaying),
    // 不新增独立开关——两种样式各自独立调用这个方法应用同一个设置值。
    func setHideWhenNotPlaying(_ hide: Bool) {
        hideWhenNotPlaying = hide
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    // 跟经典悬浮窗共用同一个"截屏/录屏时隐藏"设置项(AppSettings.hideDuringScreenCapture),
    // 不新增独立开关——两种样式各自独立调用这个方法应用同一个设置值。
    func setHiddenFromCapture(_ hidden: Bool) {
        window?.sharingType = hidden ? .none : .readWrite
    }

    // NotchLyricsView 的 .onHover 调这个,animate 传 false(瞬间展开/收起,不做过渡
    // 动画)——2026-08-02 实测排查坐实:这里原来的注释错误地写着"跟经典悬浮窗
    // updateHeight() 同一个既有模式",但 updateHeight() 其实一直是 animate: true,
    // 两者从未真正一致过,是注释本身写错了,不是代码需要改成 true 去凑注释。这里刻意
    // 用瞬时响应是因为 hover 展开/收起是对鼠标动作的直接反馈,需要跟手感觉跟得上,不能
    // 有过渡延迟;而下面 isPlayingObserver(播放状态切换)/applyContentWidthSetting
    // (拖动宽度滑块)这两处用 animate: true,是因为它们是后台状态变化触发的、非用户
    // 直接操作的尺寸调整,平滑过渡观感更好,不需要即时响应。两处需求不同,animate 参数
    // 本来就该不一样,不是遗漏。
    // hover 意图判定的两个延迟。
    //
    // 光标从刘海底下横穿而过(去点菜单栏、去够右上角控制中心)会连着触发 enter+exit,
    // 没有延迟的话灵动岛就闪一下,很扎眼;反过来光标停在展开态卡片的下边缘时,内容
    // 高度变化会让 hover 状态在边界上来回抖,收起延迟能把这种抖动吸收掉。
    //
    // 值取自 boringNotch 的实测手感(它默认进入 0.3s / 离开 0.1s),这里进入压到 0.2s:
    // 我们展开出来的是"下一句 + 迷你进度条",是想看就得马上看到的信息,不像它那样
    // 展开出一整块控制面板。
    private static let hoverEnterDelay: TimeInterval = 0.2
    private static let hoverExitDelay: TimeInterval = 0.1
    private var pendingHoverWork: DispatchWorkItem?

    func setExpanded(_ expanded: Bool) {
        // 每次新的 hover 事件都先撤掉上一次还没兑现的意图 —— "进了又出"必须净效果为零,
        // 而不是两个延迟各自到期、先展开再收起地闪一下。
        pendingHoverWork?.cancel()
        pendingHoverWork = nil
        guard expanded != isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, expanded != self.isExpanded else { return }
            self.pendingHoverWork = nil
            self.isExpanded = expanded
            self.recomputeGeometry(animate: false)
        }
        pendingHoverWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (expanded ? Self.hoverEnterDelay : Self.hoverExitDelay),
            execute: work)
    }

    // 设置里"灵动岛宽度"滑块调用——跟经典悬浮窗的 setWidth(_:) 不是同一套实现:那个
    // 需要"保持窗口中心点不变"的增量调整,因为经典悬浮窗的位置是用户拖拽/持久化的,直接
    // 重设宽度容易把窗口推出屏幕外。灵动岛完全不是这么回事:它的位置从来不是持久化的,
    // 每次都是 recomputeGeometry 里用当前屏幕的 geo.centerX 重新居中算出来的,所以这里
    // 直接把完整的几何计算(位置+尺寸)重新走一遍就行,不用另外单独维护一份"保持居中"
    // 的增量逻辑。
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

    // 不加 private:「外观」页的灵动岛预览要用同一套刘海几何。
    //
    // ⚠️ 预览**只能**用这个 static 函数,绝不能去读 `.shared` 的属性 —— 见文件顶部那条
    // 不变量:引用 .shared 会执行 init() 建窗口并立刻 orderFront,灵动岛关着的用户会
    // 凭空多出一个胶囊。这个函数不碰任何实例状态,拿它算几何是安全的。
    struct NotchGeometry {
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
    static func geometry(for screen: NSScreen) -> NotchGeometry {
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
    // 不加 private:设置页的灵动岛预览要用同一个公式算宽度,否则设成小宽度时预览
    // 显示的是设定值、真窗口却被耳朵下限顶宽,两边对不上。
    static func contentWidth(baseWidth: CGFloat, notchWidth: CGFloat) -> CGFloat {
        let earBasedFloor = notchWidth + minEarWidth * 2 + 20
        return max(baseWidth, earBasedFloor)
    }

    // 灵动岛贴哪块屏。
    //
    // 用户在设置里指定了某块屏(存的是显示器 UUID,见 ScreenIdentity)就用那块;没指定
    // (或者指定的那块现在没接着——拔了、合盖了)就自动挑**真的有刘海**的那块,再没有
    // 就退回 NSScreen.main。
    //
    // 2026-08-07 之前这里直接用 NSScreen.main,注释写的是"当前有键盘焦点/菜单栏所在的
    // 那块屏幕……跟'灵动岛只应该出现在当前主屏'这个直觉一致"。实测这个直觉不成立:
    // NSScreen.main 跟着**键盘焦点**跳,而 recomputeGeometry 只在少数几个时机重算
    // (init/屏幕配置变化/播放状态切换/hover/拖宽度),于是最后一次重算时焦点碰巧在哪块
    // 屏,窗口就一直停在哪块屏。用户的外接屏排在内置屏上方,灵动岛就停在外接屏顶部
    // (CG 坐标 y=-1440)——那块屏还没有刘海,而用户正看着内置屏,怎么找都找不到它,
    // 报的是"开了灵动岛歌词但是不显示"。
    // 不加 private:设置页预览要跟真窗口取同一块屏(纯静态、不碰实例状态,安全)。
    static func targetScreen() -> NSScreen? {
        if let pinned = ScreenIdentity.screen(withID: AppSettings.shared.notchScreenID) {
            return pinned
        }
        return ScreenIdentity.notched ?? NSScreen.main
    }

    // 设置页改完"显示在哪块屏幕"后调这个立刻生效(跟 applyContentWidthSetting 同一个模式)。
    func applyScreenSetting() {
        recomputeGeometry(animate: false)
    }

    // 顶边固定贴在屏幕最顶端(screen.frame.maxY)、水平居中对齐刘海中心点、总高度 =
    // 刘海高度 + 内容行高度(+ hover 展开时再加 expandedExtraHeight)、宽度固定(见
    // contentWidth(baseWidth:notchWidth:))。
    // isPlayingOverride 只在 isPlayingObserver 的 sink 闭包里传——那个时间点闭包参数
    // 才是真正的新值,读存储属性本身拿到的还是旧值(见 init() 里那处注释)。其余调用
    // 场景(screenParamsObserver/setExpanded/init 本身)都不在那个时序陷阱里,直接读
    // PlaybackCoordinator.shared.isPlayingNow 就是准确的当前值。
    private func recomputeGeometry(animate: Bool, isPlayingOverride: Bool? = nil) {
        guard let window, let screen = Self.targetScreen() else { return }
        let geo = Self.geometry(for: screen)
        contentTopInset = geo.notchHeight
        notchWidth = geo.notchWidth
        // 兜底同样读缓收版:收缩判定必须跟上面的可见性判定同一口径,否则会出现
        // "窗口还在但已经缩成刘海"或反过来的错配。
        let isPlayingNow = isPlayingOverride ?? PlaybackCoordinator.shared.isPlayingSmoothed
        // 没在播放、也没 hover 展开——收缩到刘海本身大小,常显内容整套不渲染(见
        // NotchLyricsView 里对 controller.isCollapsed 的判断)。是真的缩到刘海本身
        // 大小,不是把常显内容那份宽度缩到下限——下限本身仍然要给两只耳朵留够按钮/
        // 歌名的空间。
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
