import AppKit
import SwiftUI
import Combine
import LyrimuseCore

// 文件级常量(不挂在 @MainActor 类上),避免 Timer 的 @Sendable 闭包里引用
// MainActor-isolated static let 触发并发检查警告。
// 2026-08-07:位置改成存**顶边**("x,顶边y" 字符串),不再存 AppKit 的左下角 origin。
//
// 旧写法(overlayPositionLegacyOriginKey)存 frame.origin,而 updateHeight 是"顶边固定、
// 向下增高"的:内容一变高,origin.y 就跟着变小,didMoveNotification 又把这个新 origin.y 存
// 下来;下次启动窗口按**默认高度** 120 重建、把那个 origin.y 当左下角还原 —— 顶边就落到了
// (存的时候的顶边 − (存的时候的高度 − 120))。于是悬浮窗每次重启都往下漂一截,漂多少等于
// "上次那份内容比默认高多少":悬停一次(122pt)漂 2pt,歌词换行成两行(150pt 上下)一次就漂
// 30pt,而且会累积。
//
// 顶边是这个窗口真正稳定的锚:updateHeight 固定的是它,用户拖窗口时看的也是它。存顶边之后
// 高度怎么变都不影响还原结果。
private let overlayPositionKey = "np:overlayPositionTop" // "x,顶边y" 字符串
// 旧键只读不写,给一次性迁移用(见 savedAnchor)。
private let overlayPositionLegacyOriginKey = "np:overlayPositionOrigin" // 旧:"x,左下角y"
// isVisible 的持久化在 2026-08-05 并进了 AppSettings.classicOverlayEnabled(原来这里有
// 一个私有的 np:overlayVisible,跟设置页那个开关是同一件事的两个真值,详见 setVisible(_:)
// 和 AppSettings.init() 里的迁移注释),所以这里不再有自己的 visible key。
// 2026-08-02 补上——"解锁「锁定位置」后长按才能拖动"这条手势提示之前只写在设置页
// footer,用户真正需要它的时刻(已经解锁、站在悬浮窗前面想拖却拖不动)完全看不到。
// 只在解锁这一刻、且这台机器从没显示过一次时,才在悬浮窗本身短暂弹一条提示——只需要
// 提醒一次,不是每次解锁都刷一遍存在感。
private let hasShownDragHintKey = "np:hasShownOverlayDragHint"
// 高度是初始/最小值,换行需要更多行时由 updateHeight 动态调整,不会比这个更矮。宽度
// 在 AppSettings.overlayWidth 里(可在设置里调,默认 640),真正装不下的极端长行交给
// WrapLayout(LyricsOverlayView.swift)自动换行,不再单靠"更宽"兜底。
private let overlayDefaultHeight: CGFloat = 120

// 拥有悬浮窗面板 + SwiftUI 内容 + 拖拽位置持久化。位置存 UserDefaults(裸可执行文件也能
// 跨进程重启正确持久化,不需要 .app 包)。ObservableObject 让菜单栏菜单
// 直接观察 .shared 就能反映"是否显示/是否锁定位置"这两个状态,不用绕经 AppDelegate。
@MainActor
final class LyricsOverlayWindowController: NSWindowController, ObservableObject {
    static let shared = LyricsOverlayWindowController()

    // 真值在 AppSettings.classicOverlayEnabled,这里只是它的镜像(菜单栏/悬浮窗本身要观察
    // 这个 @Published)。只能经 setVisible(_:) 改,那是打开/关闭的唯一入口。
    @Published private(set) var isVisible: Bool = AppSettings.shared.classicOverlayEnabled
    // 跟 isVisible 一样,真值在 AppSettings(lockPosition),这里只是镜像 —— 必须从那份
    // 持久化值起步,不能硬编码 false。
    //
    // 原来这一行是 `= false`,于是同一个设置有了两个互相矛盾的读数:设置页读
    // AppSettings.lockPosition,菜单栏「锁定位置」读的却是这个镜像。唯一修补它的地方是
    // AppDelegate 启动时那句 setLocked(settings.lockPosition),而那句被包在
    // `if settings.classicOverlayEnabled` 里 —— 用户上次是"锁定着、但把桌面悬浮歌词关掉"
    // 退出的话,启动时这个分支根本不执行,之后再从设置里打开悬浮歌词,控制器就带着
    // isPositionLocked=false 建出来:设置页显示"已锁定",菜单栏显示"未锁定",而且实际
    // **是没锁的**——handleMouseEvent 用的就是这个镜像,长按 0.35s 就能把"显示为已锁定"
    // 的窗口拖走。
    @Published private(set) var isPositionLocked: Bool = AppSettings.shared.lockPosition
    // "暂停/无播放时自动隐藏"这个开关本身——跟 isVisible(用户手动的显示/隐藏偏好)是
    // 两个独立维度,见 updateActualVisibility() 的组合逻辑,不能互相覆盖对方的语义。
    @Published private(set) var hideWhenNotPlaying: Bool = false

    private var moveObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// "现在这个落点是借来的" —— 用户存的位置在当前显示器配置下一块屏都看不见(窗口停在
    /// 已经拔掉/已经休眠的那块外接屏上),只好临时借主屏显示。
    ///
    /// 为真期间 `scheduleSavePosition(_:)` **不写盘**:否则拔屏/息屏这一下就把用户拖出来的位置
    /// 永久改写成主屏坐标,外接屏插回来也回不去了 —— 这正是"悬浮歌词经常在主屏和副屏之间来回
    /// 跳"的第二条路径(第一条是启动时无条件夹回主屏,见 restoredPlacement)。那块屏回来时
    /// reconcilePlacementWithScreens() 按盘上的锚点把窗口送回去、清掉这个标记;用户自己拖过
    /// 窗口也清(拖动是新的、明确的意图,见 armDragIfStillPressed 末尾)。
    private var isBorrowingScreen = false

    /// 一次"存位置"的来源。必须区分,因为**「锁定位置」开着时用户根本挪不动窗口**——手势整套
    /// 停用(`setLocked` → `syncMouseMonitors` 连鼠标监听器都卸了,`handleMouseEvent` 开头也
    /// 直接 return)。那种状态下收到的 `didMove` 只可能来自我们自己、或者**系统**:显示器消失
    /// 时 macOS 会自行把窗口搬到剩下那块屏。把系统的这一次搬家当成用户意图存进锚点,就等于让
    /// 一次息屏永久改写用户拖好的位置 —— 这是"悬浮歌词经常在主屏和副屏之间切换"的最后一环
    /// (前两条:启动时无条件夹回主屏、救援落位回存)。
    ///
    /// `programmaticResize`(换行变高 / 宽度滑杆)不受这条限制:变高守恒锚点(x + 顶边都不动),
    /// 改宽是用户自己在设置里拖的、本来就该记住。
    private enum PositionSaveSource { case windowMoved, programmaticResize }
    private var moveDebounceTimer: Timer?
    private var isPlayingObserver: AnyCancellable?
    private var shadowObserver: AnyCancellable?

    // MARK: - 点击穿透 + 悬停热区 + 长按拖动
    //
    // 解锁状态下 window.ignoresMouseEvents 常年为 true(背景对任何单击都真穿透到下层
    // App/桌面),原生 NSView 命中测试/事件分发对这个窗口完全失效,包括 .onHover——
    // 所以悬停检测、长按判定、拖动本身,统统改成用鼠标监听器在"事件旁边"观察鼠标
    // 位置/按键状态自己算,不依赖窗口原生收到事件。global+local 两个监听器都装、共用
    // 同一个处理函数:鼠标在窗口外(穿透去的背景区域)时只有 global 能看到;一旦移进
    // 播放控制按钮热区、ignoresMouseEvents 被临时收回 false,窗口就开始"本地"收到
    // 事件,这时只有 local 能看到——单独装 global 会在这个切换点彻底看不到"什么时候
    // 移出热区"。播放控制按钮胶囊的真实屏幕矩形由 LyricsOverlayView 通过 GeometryReader
    // 汇报上来(controlsHotZoneScreen)。
    @Published private(set) var isHoveringForControls: Bool = false
    // 长按拖动是否已经"武装"(用于 View 层画一圈高亮提示"现在可以拖了")。
    @Published private(set) var isDragArmed: Bool = false
    // 见 hasShownDragHintKey 处的注释——只在第一次解锁时短暂为 true,几秒后自动收回。
    @Published private(set) var showDragHint: Bool = false

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var longPressTimer: Timer?
    private var dragHintDismissTimer: Timer?
    // 按下时的鼠标屏幕坐标,只用来算"武装前挪动是否超过容差"——武装之后的拖动本身
    // 交给 performDrag 原生处理,不需要再自己算位移增量。
    private var pressStartLocation: NSPoint?
    // 播放控制按钮胶囊的实时屏幕矩形,由 LyricsOverlayView 汇报;nil = 当前没有显示
    // 这排按钮(锁定中,或还没悬停出来)。
    private var controlsHotZoneScreen: CGRect?

    private let longPressThresholdSecs: TimeInterval = 0.35
    // 按下之后到长按计时器触发之前,鼠标移动超过这个距离就当成"这是想让点击/拖拽
    // 穿透到下层 App 的普通手势",取消长按判定,不武装拖动。
    private let dragMoveTolerance: CGFloat = 4

    convenience init() {
        let size = NSSize(width: AppSettings.shared.overlayWidth, height: overlayDefaultHeight)
        let placement = Self.restoredPlacement(size: size)
        let panel = LyricsOverlayWindow(contentRect: NSRect(origin: placement.origin, size: size))
        self.init(window: panel)
        // 存的位置在当前显示器配置下一块屏都看不见(外接屏拔了/睡了)时,上面那个落点是临时
        // 借主屏摆的 —— 标记成"借来的",这次运行不许把它写回磁盘,那块屏回来自己回去。
        isBorrowingScreen = placement.wasRescued

        // 拖动改由长按手势接管(见 handleGlobalMouseEvent),原生"点背景就拖"不再使用;
        // 点击穿透常年开启,只有悬停到播放控制按钮胶囊那个热区时才会被临时收回。
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: LyricsOverlayView(
            overlayController: self,
            onContentHeightChange: { [weak self] height in
                self?.updateHeight(height)
            },
            onControlsFrameChange: { [weak self] rect in
                self?.updateControlsHotZone(rect)
            },
            onControlRectsChange: { [weak self] rects in
                self?.updateControlRects(rects)
            }
        ))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        // 尺寸完全由这边的显式通道驱动(GeometryReader 报高度 → updateHeight →
        // setFrameAnimated,hosting 用 autoresizingMask 铺满 contentView),macOS 13+
        // NSHostingView 默认 .standardBounds 的那套 intrinsic 尺寸测量/失效传播没有任何
        // 消费者 —— 每次换行/开关译文都白做几档 sizeThatFits,显式声明掐掉整条路径。
        hosting.sizingOptions = []
        panel.contentView = hosting

        // 鼠标监听器不在这里装死 —— 生命周期跟着"实际可见且未锁定"走,见 syncMouseMonitors:
        // global monitor 会把全系统的指针移动/拖拽事件经 mach IPC 逐个送进本进程,窗口
        // 隐藏(orderOut)或锁定位置时这套手势整个用不上,不该继续为每次移动付唤醒钱。
        // 首次装/卸由下面订阅 isPlayingSmoothed 触发的 updateActualVisibility 顺带完成。

        // 窗口阴影跟着"背景卡片"走:默认无背景模式下内容只有细字形(阴影视觉上不可见,
        // 却要 WindowServer 在每次高度动画帧按 alpha 轮廓重算);开了背景色时阴影是卡片
        // 的真实投影,不能一刀切关掉 —— 跟 NotchLyricsWindow 直接 hasShadow=false 的取舍
        // 不同,这边的背景是用户可开关的。sink 订阅时立即回放当前值,初始状态也走这里。
        shadowObserver = AppSettings.shared.$backgroundIsVisible.sink { [weak self] visible in
            self?.window?.hasShadow = visible
        }

        // 显示器配置变了(拔插外接屏、改分辨率、改排列、外接屏睡醒)之后对一次账:该救的救、
        // 该送回去的送回去,好端端在屏上的一概不动。详见 reconcilePlacementWithScreens()。
        //
        // 启动落位(restoredPlacement)只在 convenience init 里跑一次,App 跑着的时候拔掉外接
        // 屏,窗口就停在一个不存在的坐标上,用户看不见、也没有任何自我纠正机制 —— 这个观察者
        // 就是为它准备的。
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcilePlacementWithScreens()
            }
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // queue: .main 已经保证这个闭包在主线程被调用,同样不需要 Task 跳转
            // (理由跟 installMouseMonitors 那处一致)。另外拖动中 setFrameOrigin
            // 每帧都会触发这个通知,而拖动结束时 handleMouseEvent 的 .leftMouseUp
            // 分支已经显式存过一次最终位置——正在拖动("武装"中)时这里的重复调度
            // 只是白白每帧都 invalidate+新建一个 Timer,跳过它减轻拖动路径上的负担。
            //
            // 程序性 resize 动画(setFrameAnimated:换行变高/宽度滑杆)同样每动画帧发
            // 一次 didMove,同样只是白白重建 Timer —— 动画的目标 frame 本来就是这边自己
            // 算的,不需要经通知回存;最终落点由 setFrameAnimated 的完成回调统一存一次。
            MainActor.assumeIsolated {
                guard let self, !self.isDragArmed, self.animatingTargetFrame == nil else { return }
                self.scheduleSavePosition(.windowMoved)
            }
        }

        // 订阅播放状态(PlaybackCoordinator 统一了 relay/local 两个数据源,不用关心当前
        // 到底是哪个源在跑)——不管 hideWhenNotPlaying 这个开关有没有打开都订阅,开关本身
        // 只影响 updateActualVisibility() 里的判断,订阅这一步保持常开更简单,不用在开关
        // 切换时动态订阅/取消订阅。
        //
        // 关键坑:sink 闭包里必须用这里收到的 isPlaying 参数,不能在闭包里另外去读
        // PlaybackCoordinator.shared.isPlayingNow 这个存储属性——@Published 的 willSet
        // 会在真正把新值写进存储属性*之前*就把新值发布出去,这个时间点上闭包里直接读存储
        // 属性拿到的是*上一次*的旧值。改成从存储属性读会导致每次暂停/恢复播放都要再等
        // 一次轮询周期(本地模式 2 秒、relay 模式最长 60 秒)才纠正过来,悬浮窗不会立即
        // 响应。
        isPlayingObserver = PlaybackCoordinator.shared.$isPlayingSmoothed.sink { [weak self] isPlaying in
            self?.updateActualVisibility(isPlayingNow: isPlaying)
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    // 打开/关闭"桌面悬浮歌词"的**唯一**入口——设置页那个 Toggle、菜单栏"显示桌面悬浮歌词"、
    // 全局快捷键三处都必须走这里。
    //
    // 2026-08-05:不再往私有的 np:overlayVisible 写一份,统一写回
    // AppSettings.classicOverlayEnabled(由它的 didSet 负责持久化)。合并之前这两份是各自
    // 独立持久化的,同一件事有两个真值,后果见 AppSettings.init() 里那段迁移注释。真值必须
    // 落在 AppSettings 那一侧:AppDelegate/MenuBarMenu/GlobalHotkeys 都需要在**不构造这个
    // 控制器**的前提下判断"这个模式开没开"(见 NotchLyricsWindowController 顶部那条不变量)。
    //
    // 打开时顺手把两个已配置好的隐藏偏好应用上——这一步以前只有设置页那一处做了,菜单栏和
    // 全局快捷键打开时都会漏掉,控制器会一直停在 init() 的默认值上直到下次重启 App。收进
    // 这里之后三个入口不可能再各自漏一次。
    func setVisible(_ visible: Bool) {
        isVisible = visible
        AppSettings.shared.classicOverlayEnabled = visible
        if visible {
            setHiddenFromCapture(AppSettings.shared.hideDuringScreenCapture)
            setHideWhenNotPlaying(AppSettings.shared.hideWhenNotPlaying)
            // lockPosition 跟上面两个是同一类"已经配置好、打开时要一并应用"的偏好,
            // 原来漏在外面(本函数上面那段注释说的"三个入口不可能再各自漏一次"当时只点了
            // 那两个隐藏偏好)。补进来之后,不管从设置页、菜单栏还是全局快捷键打开,窗口的
            // 锁定状态都跟持久化值一致。
            setLocked(AppSettings.shared.lockPosition)
        }
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    // 暂停/没有任何曲目在播放时,可选让悬浮窗自动隐藏(不是用户手动关掉,窗口重新开始
    // 播放时会自动恢复显示,不需要用户自己再手动打开)。跟 isVisible 完全独立:用户手动
    // 隐藏时(isVisible=false)不管这个开关状态如何都保持隐藏;用户没手动隐藏时,这个开关
    // 打开且当前没在播放才会被自动隐藏。
    func setHideWhenNotPlaying(_ hide: Bool) {
        hideWhenNotPlaying = hide
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    // 实际是否显示 = 用户手动偏好(isVisible) AND (没开自动隐藏 OR 当前正在播放)。
    // 不直接改 isVisible 本身——isVisible 就是纯粹的"用户手动想不想看见"这一件事,菜单栏
    // "显示悬浮歌词"复选框读的也是这个值;暂停时被自动隐藏不应该让那个复选框跟着变成
    // 未勾选状态,不然看起来像是被谁悄悄关掉了。
    //
    // isPlayingNow 强制要求调用方显式传入,不提供"不传就自己读 PlaybackCoordinator.shared.
    // isPlayingNow"的默认值——见 init() 里订阅播放状态那段注释,从 @Published 的 sink
    // 闭包调用这个函数时,读存储属性会拿到滞后一拍的旧值,必须用 sink 收到的参数;
    // setVisible/setHideWhenNotPlaying 这两个非 sink 触发的调用点没有这个问题,显式传入
    // 当前值即可(如果做成默认参数,默认值表达式在 Swift 6 严格并发模式下是 nonisolated
    // 上下文,访问 @MainActor 单例会报错,所以强制显式传参而不是偷懒用默认值)。
    private func updateActualVisibility(isPlayingNow: Bool) {
        let shouldShow = isVisible && (!hideWhenNotPlaying || isPlayingNow)
        if shouldShow { window?.orderFront(nil) } else { window?.orderOut(nil) }
        syncMouseMonitors()
    }

    // 锁定位置:彻底停用长按拖动+悬停控制按钮这整套手势。解锁后不是"正常拦截点击"了
    // ——背景常年保持点击穿透(isMovableByWindowBackground 也不再使用,原生"点了就拖"
    // 已经被 handleGlobalMouseEvent 里的长按判定取代),只有鼠标真的悬停到播放控制
    // 按钮胶囊那个热区时才会被动态收回 ignoresMouseEvents,见该方法的 .mouseMoved 分支。
    func setLocked(_ locked: Bool) {
        isPositionLocked = locked
        window?.isMovableByWindowBackground = false
        window?.ignoresMouseEvents = true
        if locked {
            // 锁定这一刻可能正悬停/正长按/正拖到一半,全部清零,不留任何残留状态。
            cancelPendingPress()
            isHoveringForControls = false
        } else {
            maybeShowDragHintOnFirstUnlock()
        }
        // 锁定 = 悬停/长按/拖动这整套手势彻底停用,监听器留着只是继续为全系统每次指针
        // 移动付 mach IPC + 进程唤醒的钱;解锁再装回来。见 syncMouseMonitors。
        syncMouseMonitors()
    }

    // 见 hasShownDragHintKey 处的注释——这台机器第一次解锁时,在悬浮窗本身短暂弹一条
    // "长按可拖动"提示,4 秒后自动收回,且只弹这一次(用 UserDefaults 记一个已展示过
    // 的标记,不是每次解锁都刷)。
    private func maybeShowDragHintOnFirstUnlock() {
        guard !UserDefaults.standard.bool(forKey: hasShownDragHintKey) else { return }
        UserDefaults.standard.set(true, forKey: hasShownDragHintKey)
        dragHintDismissTimer?.invalidate()
        showDragHint = true
        dragHintDismissTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showDragHint = false }
        }
    }

    // sharingType = .none 让这个窗口对截图/录屏/视频会议共享屏幕统统读不到内容——跟
    // isVisible/orderOut 不是一回事,orderOut 连用户自己都看不见了,这里要的是"用户自己
    // 仍然看得见,只是截不到"。默认 .readWrite(跟窗口原本行为完全一致,不设置这个开关的
    // 人截图/录屏观感不变)。
    func setHiddenFromCapture(_ hidden: Bool) {
        window?.sharingType = hidden ? .none : .readWrite
    }

    // 长歌词换行到第二行(或罗马音/译文/下一句预览同时都开着)时,内容比默认高度(120pt)
    // 需要更多空间——LyricsOverlayView 通过 GeometryReader 把实际渲染高度报上来,这里
    // 调整窗口高度去匹配,顶边固定、向下增高(用户拖到的位置是窗口顶部这块区域,不能让
    // 已经放好的位置跳动),下限钉在 overlayDefaultSize.height,不会比默认更矮。不持久化
    // 这个高度——跟位置不是一回事,每次内容变化重新算,窗口重启后从默认高度开始正常
    // 动态调整。
    private func updateHeight(_ contentHeight: CGFloat) {
        guard let window else { return }
        let rawHeight = max(overlayDefaultHeight, ceil(contentHeight))
        let current = baseFrame(of: window)
        let top = current.origin.y + current.height
        // 顶边固定、向下增高的同时,不能让底边超出当前屏幕可见区域——2026-08-02 实测
        // 排查坐实:早先这里只保证"不小于默认高度"这一层下限,极端情况下(罗马音+译文+
        // 下一句预览都开着、又遇上长歌词多行换行)可能把窗口下半部分撑到 Dock 后面甚至
        // 屏幕外,用户看不到、也没有任何自我纠正机制。跟 restoredPlacement() 里"存的位置在
        // 一块屏上都看不见就救回来"是同一个思路,这里对称地夹一下高度上限——最多只
        // 长到"顶边到屏幕可见区域底边"这么高,同时仍然保证不低于默认高度(用户内容真的
        // 需要更多空间时优先满足默认下限,不能反过来让默认高度本身失效)。
        // 依据的是**窗口自己落在**的那块屏,不是 NSScreen.main(那是"有键盘焦点的屏",跟这个
        // 窗口在哪儿无关;window.screen 又会在刚 orderOut 过等时刻拿不到值)。一块屏都不沾时
        // 干脆不夹 —— 没有可信的边界可用,硬按主屏算只会把副屏上的窗口往主屏方向推。
        let maxHeight = Self.hostVisibleFrame(of: current).map { max(overlayDefaultHeight, top - $0.minY) }
        let newHeight = min(rawHeight, maxHeight ?? rawHeight)
        guard abs(newHeight - current.height) >= 0.5 else { return } // 避免亚像素抖动反复触发
        let newFrame = NSRect(x: current.origin.x, y: top - newHeight, width: current.width, height: newHeight)
        setFrameAnimated(window, to: newFrame)
    }

    // setFrame(_:display:animate:) 是**同步阻塞**的:它自己跑一个动画循环,函数返回时
    // 动画已经播完,期间主线程什么都干不了。而调用它的两处都在热路径上——updateHeight
    // 每次歌词渲染高度变化(长句换行、罗马音/译文/下一句预览开合)都会调,setWidth 在
    // 设置里拖宽度滑块时连续调——每调一次就卡住主线程一整档动画时长(NSWindow 按尺寸
    // 变化量算,约 0.1~0.2s),表现就是逐字高亮(60fps 的 TimelineView)在窗口变高那一
    // 瞬间僵住、宽度滑块拖起来发黏。
    //
    // 换成 animator() 代理:视觉上一样有动画,但走 Core Animation 异步执行,不占主线程。
    // duration 取 animationResizeTime(与原来 animate: true 同一套时长算法),保证观感
    // 不变。两处调用都保持"某条边/中心点不动"的不变量:动画过程中读 window.frame 拿到
    // 的是中间值,但 origin.y + height(顶边)和 origin.x + width/2(中心)在各自的动画
    // 里本来就是恒定的,所以中途再被调用一次也不会让窗口跑位。
    // 这次动画的目标 frame。动画改成异步之后,动画途中读 window.frame 拿到的是**中间帧**,
    // 而 updateHeight/setWidth 都是"以当前 frame 为基准算新 frame",于是连续调用(宽度滑块
    // step 10 一路拖过去、歌词渲染高度连续变化)会以中间帧为基准层层累积。
    //
    // updateHeight 恰好不受影响:它守恒的是 origin.y + height(顶边),那个和在自己这段动画
    // 的首尾是同一个值。setWidth 会受影响:它算的中心点一旦撞上下面那层"夹回屏幕可见区域"
    // 的钳制就不再守恒(newX + width/2 != centerX),再以中间帧为基准重算一次,窗口就会漂到
    // 一个跟时序有关的位置上 —— 正是原来同步阻塞版本不会出现的问题。统一以"上一次的目标
    // frame"为基准,两处都稳。
    private var animatingTargetFrame: NSRect?

    // 算新 frame 的基准:有动画在飞就用它的目标,否则用窗口真实 frame —— 用户可能自己把
    // 窗口拖走过(performDrag),那种情况必须以真实位置为准,所以动画一结束就把缓存放掉。
    private func baseFrame(of window: NSWindow) -> NSRect {
        animatingTargetFrame ?? window.frame
    }

    private func setFrameAnimated(_ window: NSWindow, to frame: NSRect) {
        animatingTargetFrame = frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = window.animationResizeTime(frame)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // 只有"最后那次动画"结束时才清:动画途中又来一次调用会覆盖
                // animatingTargetFrame,那时旧动画的完成回调不该把新目标清掉。
                guard let self, self.animatingTargetFrame == frame else { return }
                self.animatingTargetFrame = nil
                // didMove 观察者对程序性动画整段豁免(见 init() 那条 guard),最终落点在
                // 这里统一存一次 —— setWidth 是保持中心伸缩的,x 会真的变,不存的话重启
                // 就会还原到调宽前的位置。scheduleSavePosition 落盘前会跟现值比较,高度
                // 动画(x/顶边都不变)不会产生多余的写。
                self.scheduleSavePosition(.programmaticResize)
            }
        })
    }

    // 设置里的宽度滑块调用——保持窗口中心点不变(左右对称伸缩),而不是像 updateHeight
    // 那样固定顶边只往下长:宽度是用户主动在设置里调的偏好变化,不是内容溢出触发的被动
    // 适应,固定左边界的话,拖到屏幕右侧的窗口调宽后容易被推出屏幕外。
    func setWidth(_ width: CGFloat) {
        guard let window else { return }
        let current = baseFrame(of: window)
        let centerX = current.origin.x + current.width / 2
        // 按中心点算出的新左右边界同样需要夹回屏幕可见区域——2026-08-02 实测排查坐实:
        // 早先这里没做这层钳制,宽度滑块调到接近上限(1000pt)且窗口当前位置偏向屏幕
        // 一侧时,新边界可能超出屏幕,跟上面 updateHeight 是同一类"极端设置下窗口跑出
        // 可见区域、且没有自我纠正"的问题,同一个思路一起修。
        // 同 updateHeight:按窗口自己所在那块屏夹,不沾任何屏就不夹。夹取本身复用
        // OverlayPlacement.clamped —— 它处理了"窗口比屏还宽时先 max 再 min 会把窗口推出右
        // 边界"那个顺序问题,原来这里手写的两层 min/max 没处理。
        let wanted = NSRect(x: centerX - width / 2, y: current.origin.y, width: width, height: current.height)
        let newX = Self.hostVisibleFrame(of: wanted)
            .map { OverlayPlacement.clamped(frame: wanted, into: $0).x } ?? wanted.origin.x
        let newFrame = NSRect(x: newX, y: current.origin.y, width: width, height: current.height)
        setFrameAnimated(window, to: newFrame)
    }

    /// 监听器生命周期 = "窗口实际在屏 且 未锁定位置"(2026-08-19 性能审计落地)。
    ///
    /// 原来是 init 装一次、只在 deinit 卸载 —— 而这是个 @MainActor 单例,deinit 永不执行,
    /// 等于本次运行只要开过一次悬浮歌词,global monitor 就永远挂着:WindowServer 把全系统
    /// **每一次**指针移动/拖拽经 mach IPC 送进本进程、在主线程调度回调,handleMouseEvent
    /// 开头那两条 guard(锁定/不可见)只省了回调体内的计算,IPC+唤醒这笔钱在 guard 之前
    /// 就已经花掉。"锁定"和"已隐藏"两种状态下这套手势系统完全用不上,按状态装/卸。
    /// 调用点:updateActualVisibility(orderFront/orderOut 之后)与 setLocked。
    /// 「指针划过时让开」开关切换后调一次。
    ///
    /// 必须有这个入口:这个开关进了 `syncMouseMonitors` 的判据,而那个函数原来只在
    /// 可见性变化和 setLocked 时被调 —— 不在这里补一次的话,用户在设置页打开它之后,
    /// 要等到下次显示/隐藏或锁定切换才真正装上监听器,表现成"开了没反应"。
    func setFadeOnHover(_ enabled: Bool) {
        syncMouseMonitors()
        // 关掉的一刻指针可能正停在窗口上。留着 true 不会让它一直淡着(视图层同时读开关),
        // 但会让下次开启时凭一个陈旧的悬停态直接淡下去 —— 清掉更干净。
        if !enabled, isHoveringForControls { isHoveringForControls = false }
    }

    private func syncMouseMonitors() {
        // ⚠️「划过让开」(overlayFadeOnHover)必须一起进这个判据 —— 它靠的正是
        // handleMouseEvent 的 .mouseMoved 分支维护 isHoveringForControls,而「锁定位置 +
        // 划过让开」恰恰是最常见的组合(位置钉死了的用户才更需要它临时让开)。只按
        // !isPositionLocked 装卸的话,一锁定监听器就整个卸掉,这个开关当场变成死的。
        let needed = (window?.isVisible ?? false)
            && (!isPositionLocked || AppSettings.shared.overlayFadeOnHover)
        if needed {
            installMouseMonitors()
        } else {
            removeMouseMonitors()
        }
    }

    private func removeMouseMonitors() {
        guard globalMouseMonitor != nil || localMouseMonitor != nil else { return }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        // 卸载这一刻可能正悬停/长按到一半 —— 跟 setLocked 的清理口径一致,不留残留状态。
        // 已武装的拖动不受影响:performDrag 是同步阻塞调用,跑着的时候到不了这里。
        cancelPendingPress()
        if isHoveringForControls { isHoveringForControls = false }
    }

    private func installMouseMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        // AppKit 保证这两个监听器的回调固定在安装时所在的线程上调用(这里是主线程)——
        // 用 MainActor.assumeIsolated 就地同步处理,不再经过 Task { @MainActor in ... }
        // 的异步跳转。.leftMouseDragged 在拖动时是逐帧高频事件,每个都单开一个 Task 会被
        // Main Actor 的任务队列按自己的调度节奏批处理/延后执行,跟真实鼠标位置对不上,
        // 实测就是"拖动有卡顿感"的根因;改成同步调用后窗口位置直接跟事件本身对齐,
        // 不再多一层调度延迟。
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouseEvent(type: type) }
        }
        // 本地监听器必须原样把 event 返回,否则会把这次点击整个吞掉,SwiftUI 按钮永远
        // 收不到点击——这里只是"旁听"一下鼠标位置,不是要拦截。
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouseEvent(type: type) }
            return event
        }
    }

    /// 胶囊里每个按钮的**屏幕**矩形。空 = 当前没显示控制排。
    private var controlRectsScreen: [OverlayControlID: CGRect] = [:]

    /// 执行某个按钮的动作。
    ///
    /// 这五个动作全都不依赖 View 的闭包上下文(播放控制是 MusicPlaybackController 的全局
    /// static、喜欢在 PlaybackCoordinator.shared、锁定在 AppSettings.shared),所以点击改由
    /// 控制器分发时**不需要**把 action 闭包穿过 PreferenceKey —— 那本来是这个改动里最脏的
    /// 一块,结果根本不必做。
    private func performControlAction(_ id: OverlayControlID) {
        switch id {
        case .previous: withMusicPermission { MusicPlaybackController.previousTrack() }
        // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
        case .playPause: withMusicPermission { PlaybackCoordinator.shared.userTogglePlayPause() }
        case .next: withMusicPermission { MusicPlaybackController.nextTrack() }
        // 不套权限守卫:权限检查和乐观更新都在 toggleFavorited() 里一起做了,再套一层会变成
        // 查两遍权限(原来 LyricsOverlayView 里也是特意绕开 controlButton 的)。
        case .favorite: PlaybackCoordinator.shared.toggleFavorited()
        // 锁定位置跟自动化播放控制完全不搭边,同样不套守卫(理由沿用原 lockButton 注释)。
        case .lock:
            AppSettings.shared.lockPosition = true
            setLocked(true)
        }
    }

    /// 播放控制三个动作共用的"点了才校验权限"守卫。
    ///
    /// 原来在 LyricsOverlayView.controlButton 里,点击改由控制器分发之后搬过来,行为逐字
    /// 不变:没问过就顺手弹一次系统授权对话框,已经拒绝过就 NSSound.beep() 给一个"没有
    /// 生效"的听觉反馈。必须用 checkForCurrentPlayerSafely(异步版),同步版的坑见该方法
    /// 定义处的注释。
    private func withMusicPermission(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                NSSound.beep()
                return
            }
            action()
        }
    }

    /// 把每个按钮的内容坐标矩形转成屏幕矩形。转换口径跟 updateControlsHotZone 完全一致。
    private func updateControlRects(_ rects: [OverlayControlID: CGRect]) {
        guard let window, !rects.isEmpty else {
            if !controlRectsScreen.isEmpty { controlRectsScreen = [:] }
            return
        }
        var out: [OverlayControlID: CGRect] = [:]
        for (id, rect) in rects where rect != .zero {
            let windowLocal = CGRect(
                x: rect.minX,
                y: window.frame.height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            out[id] = window.convertToScreen(windowLocal)
        }
        controlRectsScreen = out
    }



    // 把 LyricsOverlayView 汇报的 SwiftUI 内容坐标(GeometryReader 相对 overlayContent
    // 命名坐标空间量出来的矩形,左上角原点、y 向下,单位跟窗口点数一致——跟 updateHeight
    // 依赖的"GeometryReader 尺寸==窗口内容尺寸"是同一个已验证过的等价关系)转换成
    // AppKit 的窗口本地坐标(左下角原点、y 向上)再转屏幕坐标,供 handleMouseEvent 直接
    // 用 NSEvent.mouseLocation 做包含判断。
    private func updateControlsHotZone(_ rect: CGRect) {
        guard let window, rect != .zero else {
            controlsHotZoneScreen = nil
            return
        }
        let windowLocal = CGRect(
            x: rect.minX,
            y: window.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        controlsHotZoneScreen = window.convertToScreen(windowLocal)
    }




    private func handleMouseEvent(type: NSEvent.EventType) {
        guard let window else { return }
        // 锁定位置 = 停用整套手势(悬停控制排 + 长按拖动)。但 .mouseMoved 要放行:
        // 「划过让开」需要它维护 isHoveringForControls,而那件事跟"能不能拖动窗口"无关。
        // 控制排不会因此露出来 —— 下面 controlsShown 那行有 `&& !lockPosition` 守着。
        if isPositionLocked, type != .mouseMoved { return }
        // 窗口当前不在屏幕上时直接不处理。监听器的生命周期虽然已经跟着"实际可见且未锁定"
        // 装/卸(见 syncMouseMonitors),这道 guard 仍然要留:装/卸发生在 orderOut/orderFront
        // 的那一拍,而事件可能已经在派发队列里排着 —— 没有它的话,下面 .leftMouseDown 分支
        // 判断"点在窗口里吗"用的是 frame.contains(loc),隐藏窗口的 frame 还停在原处,用户
        // 在桌面上那块区域按过 longPressThresholdSecs(0.35s)就能把拖动"武装"起来,
        // armDragIfStillPressed 把 ignoresMouseEvents 收回 false 并对一个看不见的窗口发起
        // performDrag,那次点击被悄悄吞掉。
        // 顺便把可能残留的长按判定/悬停态清干净(可能正好在按着的时候被隐藏);已经
        // 武装的情况不碰,交给 performDrag 自己的收尾逻辑。
        guard window.isVisible else {
            if !isDragArmed {
                cancelPendingPress()
                if isHoveringForControls { isHoveringForControls = false }
            }
            return
        }
        let loc = NSEvent.mouseLocation
        let frame = window.frame
        // 热区矩形现在是**无条件**上报的(见 LyricsOverlayView 里那段注释:让它兼表可见性会
        // 被 preference 归约冲掉),所以"按钮到底显示着没有"这一层判断放在这里。槽位是常驻的,
        // 不加这层的话没显示时那块区域也会挡住点击穿透 —— 变成"看不见却挡手"。
        let controlsShown = isHoveringForControls && !AppSettings.shared.lockPosition
        let insideHotZone = controlsShown && (controlsHotZoneScreen?.contains(loc) ?? false)

        switch type {
        case .mouseMoved:
            let insideWindow = frame.contains(loc)
            if isHoveringForControls != insideWindow {
                isHoveringForControls = insideWindow
            }
            // 这里**不再**碰 ignoresMouseEvents。它恒为 true,唯一例外是长按拖动武装期间
            // (armDragIfStillPressed 为 performDrag 临时收回 false)。胶囊上的点击改由下面
            // .leftMouseDown 分支按各按钮矩形自己分发 —— 理由见本节顶部 2026-08-18 那段:
            // ignoresMouseEvents 是整窗 × 所有事件的一个布尔量,点击要它 false、滚轮要它
            // true,同一时刻只能满足一个,按位置翻转必然让其中一方受害。

        case .leftMouseDown:
            // 胶囊上的点击由我们自己分发:窗口常年点击穿透,SwiftUI 收不到任何事件。
            // 必须排在下面那条 guard 之前 —— 那条会因为 insideHotZone 直接 return。
            if controlsShown, let id = OverlayControlHitTest.control(at: loc, in: controlRectsScreen) {
                performControlAction(id)
                return
            }
            guard frame.contains(loc), !insideHotZone else { return }
            pressStartLocation = loc
            longPressTimer?.invalidate()
            let timer = Timer(timeInterval: longPressThresholdSecs, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.armDragIfStillPressed() }
            }
            RunLoop.main.add(timer, forMode: .common)
            longPressTimer = timer

        case .leftMouseDragged:
            // 武装之后整段拖动都交给 armDragIfStillPressed 里的 performDrag 原生处理
            // (那是一个同步阻塞调用,函数返回时拖动已经结束)——这里只需要在"还没
            // 武装"这段时间处理"移动太多就取消长按判定"。
            guard !isDragArmed, let start = pressStartLocation else { return }
            if hypot(loc.x - start.x, loc.y - start.y) > dragMoveTolerance {
                // 计时器还没到点,鼠标就已经挪动超过容差——这是想穿透到下层的普通拖拽
                // 手势(比如在桌面拖框选),不是想拖悬浮窗,取消长按判定。
                cancelPendingPress()
            }

        case .leftMouseUp:
            // 已经武装的情况下,这个 mouseUp 早被 performDrag 内部的原生跟踪循环
            // 自己消费掉了,armDragIfStillPressed 会在 performDrag 返回后做收尾;
            // 这里只需要处理"还没到长按阈值就松手"这种提前取消的情况。
            guard !isDragArmed else { return }
            cancelPendingPress()

        default:
            break
        }
    }

    // 长按阈值一到、鼠标仍按着,就把整段拖动移交给 AppKit 原生的窗口拖动机制
    // (NSWindow.performDrag(with:))接管,不再自己逐帧算 delta 调 setFrameOrigin。
    //
    // 原因:窗口在长按判定期间 ignoresMouseEvents 一直是 true(真穿透),物理按下
    // 那一刻的原始 mouseDown 因此从没被这个窗口收到过——那个真实事件已经被派发去了
    // 下层 App/桌面,没法"追认"回来。自己在监听器里手动追踪 dragged 事件、算 delta、
    // 调 setFrameOrigin,每一帧都要走一遍"WindowServer 派发事件→我们的监听器观察到→
    // 应用进程再发指令挪窗口"的来回,这条链路天然比原生拖动多好几层调度,实测就是
    // "有卡顿感"的根源,不是靠省掉个把 Task 调度就能追平的。
    //
    // 这里改成:武装这一刻先把 ignoresMouseEvents 收回 false(AppKit 对每个后续事件
    // 独立做命中测试,不是只在最初 mouseDown 时判一次——收回之后,只要物理左键还按着,
    // WindowServer 从下一次事件派发起就会把这次手势剩余的 dragged/up 事件判给这个
    // 窗口),再拿一个就地合成、时间戳为当下的 mouseDown 事件喂给 performDrag,把
    // 剩下的拖动过程完全交给 WindowServer 原生处理(跟原来"点背景直接拖"完全同一套
    // 机制,跟手不卡顿)。performDrag 是同步阻塞调用,内部有自己的事件循环,一直等到
    // 物理左键松开才返回——所以这个函数直到用户松手才会执行到最后,返回后统一收尾。
    private func armDragIfStillPressed() {
        // NSEvent.pressedMouseButtons 的 bit 0 对应左键——计时器触发这一刻鼠标左键
        // 必须还按着,否则说明 mouseUp 抢在计时器前面到了,不武装拖动。
        guard let window, pressStartLocation != nil, NSEvent.pressedMouseButtons & 1 != 0 else {
            cancelPendingPress()
            return
        }
        isDragArmed = true
        window.ignoresMouseEvents = false
        defer {
            window.ignoresMouseEvents = true
            cancelPendingPress()
        }

        guard let syntheticDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: window.mouseLocationOutsideOfEventStream,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }

        window.performDrag(with: syntheticDown)
        // 用户亲手把窗口拖到了哪儿,那就是新的锚点 —— 哪怕这次是在借来的屏上拖的,也从此
        // 以它为准(清掉标记,下面这次写盘才生效)。
        isBorrowingScreen = false
        // performDrag 返回 = 这次拖动已经结束(正常松手,或者被系统提前打断),把
        // 最终落点存下来——原来"武装期间跳过 moveObserver 里的 scheduleSavePosition"
        // 那条 guard(见 init() 里的 didMoveNotification 观察者)在这里同样适用,拖动
        // 过程中的中间位置不需要重复存,只存这一次最终结果。
        UserDefaults.standard.set(
            "\(window.frame.origin.x),\(window.frame.maxY)", forKey: overlayPositionKey
        )
    }

    private func cancelPendingPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        pressStartLocation = nil
        isDragArmed = false
    }

    // 屏幕配置变化后对一次账。判断/夹取的几何都在 OverlayPlacement(LyrimuseCore)里,
    // selftest 覆盖 —— 这台机器插着一块外接屏,但"拔掉/插回"这个瞬间没法在单测外复现,纯
    // 函数是唯一能覆盖它的手段。
    //
    // 两个方向,顺序要紧:
    // ① 盘上那个锚点现在**看得见**,而窗口不在那儿 → 送回去。两种情形合并成一支:
    //    · 正在借屏显示(外接屏插回来/睡醒了);
    //    · 「锁定位置」开着 —— 那时位置由锚点唯一决定,窗口偏离了只可能是系统在显示器消失
    //      时替我们搬的家(用户挪不动,见 PositionSaveSource),搬回来。
    // ② 当前位置看不见了(那块屏刚被拔掉)→ 借主屏显示,但**不写盘**(见 isBorrowingScreen)。
    //
    // 不做的事:未锁定、也没在借屏,而窗口好端端待在某块屏上时,一律不动它 —— 不"归位"、
    // 不跟焦点跑、不按主屏重排。用户主诉的"经常在主屏和副屏之间切换位置"就是这类自动搬家
    // 累积出来的。
    private func reconcilePlacementWithScreens() {
        guard let window else { return }
        let screens = Self.allVisibleFrames()

        if let home = Self.homeFrame(size: window.frame.size),
           OverlayPlacement.isSufficientlyVisible(frame: home, screens: screens) {
            // 锁定态的纠正判据故意收得很紧:**只有"窗口现在待的屏跟锚点那块屏不是同一块"**
            // 才搬。同屏内几个 pt 的偏差(别处的动画/钳制留下的)一律不管 —— 用户抱怨的是
            // 跨屏搬家,为了对齐锚点去发一次无谓的位移只会制造新的跳动。
            let movedToAnotherScreen =
                OverlayPlacement.hostVisibleFrame(of: window.frame, screens: screens)
                    != OverlayPlacement.hostVisibleFrame(of: home, screens: screens)
            if isBorrowingScreen || (isPositionLocked && movedToAnotherScreen) {
                isBorrowingScreen = false
                window.setFrameOrigin(home.origin)
                return
            }
        }

        guard let target = OverlayPlacement.repositionIfOffscreen(frame: window.frame, screens: screens) else {
            return
        }
        isBorrowingScreen = true
        window.setFrameOrigin(target)
        // 这个落点故意不落盘(scheduleSavePosition 在借屏期间直接返回):磁盘上留着的仍是用户
        // 自己拖出来的那个锚点,那块屏回来时上面 ① 那一支照它把窗口送回去。
    }

    private func scheduleSavePosition(_ source: PositionSaveSource) {
        // 借屏落位不是用户的意图,不许改写盘上的锚点(见 isBorrowingScreen)。程序性 resize
        // 动画的完成回调也走这条路,所以这层守卫必须放在最外面。
        guard !isBorrowingScreen else { return }
        // 锁定着还被挪了 = 不是用户挪的(见 PositionSaveSource)。不采纳为新锚点。
        if source == .windowMoved, isPositionLocked { return }
        moveDebounceTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let frame = self?.window?.frame else { return }
            let value = "\(frame.origin.x),\(frame.maxY)"
            // 值没变就别写 —— CFPreferences 的一次写路径不便宜,而高度动画结束后 x/顶边
            // 恰恰都是不变量,原来每次换行都会落一笔跟盘上完全相同的字符串。
            if UserDefaults.standard.string(forKey: overlayPositionKey) != value {
                UserDefaults.standard.set(value, forKey: overlayPositionKey)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        moveDebounceTimer = t
    }

    // 主屏排在第一个:窗口无处可去时的落脚点(见 OverlayPlacement 里的约定)。
    private static func allVisibleFrames() -> [CGRect] {
        var screens: [CGRect] = []
        if let main = NSScreen.main { screens.append(main.visibleFrame) }
        for s in NSScreen.screens where s != NSScreen.main { screens.append(s.visibleFrame) }
        return screens
    }

    // 这个 frame **自己落在**的那块屏的可见区域(相交面积最大的那块);一块都不沾时 nil。
    private static func hostVisibleFrame(of frame: NSRect) -> NSRect? {
        OverlayPlacement.hostVisibleFrame(of: frame, screens: allVisibleFrames())
    }

    /// 盘上存着的锚点("x,顶边")。新键没有时读一次旧键(左下角 origin)做迁移。
    ///
    /// 迁移换算成"顶边"用的是 overlayDefaultHeight 而不是当次的窗口高度:旧值是被上一次运行的
    /// **某个**高度污染过的左下角坐标,而读它的时机(convenience init)窗口高度恰好就等于
    /// overlayDefaultHeight —— 用它换算出的顶边,正好等于旧代码这次启动本来就会摆出的位置。
    /// 也就是说迁移这一步**视觉上完全无感**:窗口停在旧逻辑会摆的地方,只是从此以后不再继续
    /// 往下漂。
    private static func savedAnchor() -> (x: Double, top: Double)? {
        func parsePair(_ key: String) -> (x: Double, y: Double)? {
            guard let saved = UserDefaults.standard.string(forKey: key) else { return nil }
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
        if let p = parsePair(overlayPositionKey) { return (p.x, p.y) } // 新键:第二个分量就是顶边
        if let p = parsePair(overlayPositionLegacyOriginKey) {
            return (p.x, p.y + Double(overlayDefaultHeight)) // 旧键:左下角 → 换算成顶边
        }
        return nil
    }

    /// 盘上锚点 + 当前窗口尺寸 = 窗口"应该在"的那个 frame(顶边对齐锚点)。没存过锚点时 nil。
    private static func homeFrame(size: NSSize) -> NSRect? {
        guard let anchor = savedAnchor() else { return nil }
        return NSRect(x: anchor.x, y: anchor.top - Double(size.height),
                      width: size.width, height: size.height)
    }

    /// 启动时把窗口摆在哪儿。
    ///
    /// 2026-08-21:这里**不再**把存下来的位置无条件夹进 NSScreen.main.visibleFrame —— 那是
    /// "悬浮歌词经常在主屏和副屏之间切换位置"的根因。实测这台机器:外接屏 LS27B61x 的
    /// visibleFrame 是 (-526,956,2560,1440),窗口 900×120 的锚点存的是 x=849/顶边=1202(好端端
    /// 在外接屏上),而内置屏的 visibleFrame 是 (0,70,1470,853) —— 旧代码那两行 clamp 把它算成
    /// x=min(max(849,0),1470-900)=570、y=min(max(1082,70),923-120)=803,窗口整个被拽回内置屏。
    /// 用户拖回外接屏,下次启动再被拽走一次,反复如此(旧键 np:overlayPositionOrigin 里那个
    /// "602.0,803.0" 的 y 就是这条钳制留下的化石)。
    ///
    /// 改成:位置在**任何**一块屏上看得见就原样保留;一块都看不见(窗口停在已经拔掉的外接屏
    /// 上)才夹回主屏,并且由调用方把这次落点标记成"借来的"、不写回磁盘。
    private static func restoredPlacement(size: NSSize) -> OverlayPlacement.RestoredPlacement {
        let screens = allVisibleFrames()
        guard let frame = homeFrame(size: size) else {
            let screenFrame = screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return .init(
                origin: NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height - 40),
                wasRescued: false
            )
        }
        return OverlayPlacement.restored(frame: frame, screens: screens)
    }
}
