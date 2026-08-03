import AppKit
import SwiftUI
import Combine
import LyrimuseCore

// 文件级常量(不挂在 @MainActor 类上),避免 Timer 的 @Sendable 闭包里引用
// MainActor-isolated static let 触发并发检查警告。
private let overlayPositionKey = "np:overlayPositionOrigin" // "x,y" 字符串
// 2026-08-03 补上——"显示桌面悬浮歌词"这个菜单开关(isVisible)之前只存在内存里,
// setVisible() 只改了 @Published 属性、从没写过 UserDefaults。用户关掉悬浮窗后退出
// 重开 App,isVisible 又从声明处的硬编码默认值 true 重新起步,悬浮窗(以及灵动岛,见
// NotchLyricsWindowController 同名 key)会违背用户上一次的选择、无条件重新冒出来。
private let overlayVisibleKey = "np:overlayVisible"
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

    @Published private(set) var isVisible: Bool = LyricsOverlayWindowController.restoredVisible()
    @Published private(set) var isPositionLocked: Bool = false
    // "暂停/无播放时自动隐藏"这个开关本身——跟 isVisible(用户手动的显示/隐藏偏好)是
    // 两个独立维度,见 updateActualVisibility() 的组合逻辑,不能互相覆盖对方的语义。
    @Published private(set) var hideWhenNotPlaying: Bool = false

    private var moveObserver: NSObjectProtocol?
    private var moveDebounceTimer: Timer?
    private var isPlayingObserver: AnyCancellable?

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
        let rect = NSRect(origin: Self.restoredOrigin(size: size), size: size)
        let panel = LyricsOverlayWindow(contentRect: rect)
        self.init(window: panel)

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
            }
        ))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        installMouseMonitors()

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // queue: .main 已经保证这个闭包在主线程被调用,同样不需要 Task 跳转
            // (理由跟 installMouseMonitors 那处一致)。另外拖动中 setFrameOrigin
            // 每帧都会触发这个通知,而拖动结束时 handleMouseEvent 的 .leftMouseUp
            // 分支已经显式存过一次最终位置——正在拖动("武装"中)时这里的重复调度
            // 只是白白每帧都 invalidate+新建一个 Timer,跳过它减轻拖动路径上的负担。
            MainActor.assumeIsolated {
                guard let self, !self.isDragArmed else { return }
                self.scheduleSavePosition()
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
        isPlayingObserver = PlaybackCoordinator.shared.$isPlayingNow.sink { [weak self] isPlaying in
            self?.updateActualVisibility(isPlayingNow: isPlaying)
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        UserDefaults.standard.set(visible, forKey: overlayVisibleKey)
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingNow)
    }

    // 暂停/没有任何曲目在播放时,可选让悬浮窗自动隐藏(不是用户手动关掉,窗口重新开始
    // 播放时会自动恢复显示,不需要用户自己再手动打开)。跟 isVisible 完全独立:用户手动
    // 隐藏时(isVisible=false)不管这个开关状态如何都保持隐藏;用户没手动隐藏时,这个开关
    // 打开且当前没在播放才会被自动隐藏。
    func setHideWhenNotPlaying(_ hide: Bool) {
        hideWhenNotPlaying = hide
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingNow)
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
        let current = window.frame
        let top = current.origin.y + current.height
        // 顶边固定、向下增高的同时,不能让底边超出当前屏幕可见区域——2026-08-02 实测
        // 排查坐实:早先这里只保证"不小于默认高度"这一层下限,极端情况下(罗马音+译文+
        // 下一句预览都开着、又遇上长歌词多行换行)可能把窗口下半部分撑到 Dock 后面甚至
        // 屏幕外,用户看不到、也没有任何自我纠正机制。跟 restoredOrigin(size:) 里"显示器
        // 配置可能变了,夹回可见区域"是同一个思路,这里对称地夹一下高度上限——最多只
        // 长到"顶边到屏幕可见区域底边"这么高,同时仍然保证不低于默认高度(用户内容真的
        // 需要更多空间时优先满足默认下限,不能反过来让默认高度本身失效)。
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? current
        let newHeight = min(rawHeight, max(overlayDefaultHeight, top - visibleFrame.minY))
        guard abs(newHeight - current.height) >= 0.5 else { return } // 避免亚像素抖动反复触发
        let newFrame = NSRect(x: current.origin.x, y: top - newHeight, width: current.width, height: newHeight)
        window.setFrame(newFrame, display: true, animate: true)
    }

    // 设置里的宽度滑块调用——保持窗口中心点不变(左右对称伸缩),而不是像 updateHeight
    // 那样固定顶边只往下长:宽度是用户主动在设置里调的偏好变化,不是内容溢出触发的被动
    // 适应,固定左边界的话,拖到屏幕右侧的窗口调宽后容易被推出屏幕外。
    func setWidth(_ width: CGFloat) {
        guard let window else { return }
        let current = window.frame
        let centerX = current.origin.x + current.width / 2
        // 按中心点算出的新左右边界同样需要夹回屏幕可见区域——2026-08-02 实测排查坐实:
        // 早先这里没做这层钳制,宽度滑块调到接近上限(1000pt)且窗口当前位置偏向屏幕
        // 一侧时,新边界可能超出屏幕,跟上面 updateHeight 是同一类"极端设置下窗口跑出
        // 可见区域、且没有自我纠正"的问题,同一个思路一起修。
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? current
        let newX = min(max(centerX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        let newFrame = NSRect(x: newX, y: current.origin.y, width: width, height: current.height)
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func installMouseMonitors() {
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
        guard let window, !isPositionLocked else { return }
        let loc = NSEvent.mouseLocation
        let frame = window.frame
        let insideHotZone = controlsHotZoneScreen?.contains(loc) ?? false

        switch type {
        case .mouseMoved:
            let insideWindow = frame.contains(loc)
            if isHoveringForControls != insideWindow {
                isHoveringForControls = insideWindow
            }
            // 只有真的贴在按钮胶囊那一小块热区,才把点击穿透临时收回去,让 SwiftUI
            // 按钮能正常收到点击;窗口里其它任何地方(包括歌词文字本身)永远穿透。
            // 正在拖动("武装"中)时不要在这里改 ignoresMouseEvents——armDragIfStillPressed
            // 已经为了 performDrag 把它收回 false 了,这里如果因为拖动途中飘出热区之外
            // 又把它设回 true,会打断正在进行中的原生拖动。
            guard !isDragArmed else { return }
            let desiredIgnoresMouseEvents = !(insideWindow && insideHotZone)
            if window.ignoresMouseEvents != desiredIgnoresMouseEvents {
                window.ignoresMouseEvents = desiredIgnoresMouseEvents
            }

        case .leftMouseDown:
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
        // performDrag 返回 = 这次拖动已经结束(正常松手,或者被系统提前打断),把
        // 最终落点存下来——原来"武装期间跳过 moveObserver 里的 scheduleSavePosition"
        // 那条 guard(见 init() 里的 didMoveNotification 观察者)在这里同样适用,拖动
        // 过程中的中间位置不需要重复存,只存这一次最终结果。
        UserDefaults.standard.set(
            "\(window.frame.origin.x),\(window.frame.origin.y)", forKey: overlayPositionKey
        )
    }

    private func cancelPendingPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        pressStartLocation = nil
        isDragArmed = false
    }

    private func scheduleSavePosition() {
        moveDebounceTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let origin = self?.window?.frame.origin else { return }
            UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: overlayPositionKey)
        }
        RunLoop.main.add(t, forMode: .common)
        moveDebounceTimer = t
    }

    // 没有存过(第一次启动/升级前的旧版本从没写过这个 key)时默认 true,跟这个属性
    // 原来的硬编码默认值保持一致,不改变"从没手动关过的用户"的既有体验。
    private static func restoredVisible() -> Bool {
        guard UserDefaults.standard.object(forKey: overlayVisibleKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: overlayVisibleKey)
    }

    private static func restoredOrigin(size: NSSize) -> NSPoint {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultOrigin = NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height - 40)
        guard let saved = UserDefaults.standard.string(forKey: overlayPositionKey) else { return defaultOrigin }
        let parts = saved.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return defaultOrigin }
        var origin = NSPoint(x: parts[0], y: parts[1])
        // 显示器配置可能变了(比如拔了外接屏):夹回当前可见区域内,避免悬浮窗跑到看不见的地方。
        origin.x = min(max(origin.x, screenFrame.minX), screenFrame.maxX - size.width)
        origin.y = min(max(origin.y, screenFrame.minY), screenFrame.maxY - size.height)
        return origin
    }
}
