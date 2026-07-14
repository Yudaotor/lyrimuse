import AppKit
import SwiftUI
import Combine
import DesktopLyricsCore

// 文件级常量(不挂在 @MainActor 类上),避免 Timer 的 @Sendable 闭包里引用
// MainActor-isolated static let 触发并发检查警告。
private let overlayPositionKey = "np:overlayPositionOrigin" // "x,y" 字符串
// 宽度比原来(480)加宽,减少偏长的歌词行触发换行的概率;真正装不下的极端长行交给
// WrapLayout(LyricsOverlayView.swift)自动换行,不再单靠"更宽"兜底。高度是初始/最小值,
// 换行需要更多行时由 updateHeight 动态调整,不会比这个更矮。
private let overlayDefaultSize = NSSize(width: 640, height: 120)

// 拥有悬浮窗面板 + SwiftUI 内容 + 拖拽位置持久化。位置存 UserDefaults(裸可执行文件也能
// 跨进程重启正确持久化,已实测确认,不需要 .app 包)。ObservableObject 让菜单栏菜单
// 直接观察 .shared 就能反映"是否显示/是否锁定位置"这两个状态,不用绕经 AppDelegate。
@MainActor
final class LyricsOverlayWindowController: NSWindowController, ObservableObject {
    static let shared = LyricsOverlayWindowController()

    @Published private(set) var isVisible: Bool = true
    @Published private(set) var isPositionLocked: Bool = false
    // "暂停/无播放时自动隐藏"这个开关本身——跟 isVisible(用户手动的显示/隐藏偏好)是
    // 两个独立维度,见 updateActualVisibility() 的组合逻辑,不能互相覆盖对方的语义。
    @Published private(set) var hideWhenNotPlaying: Bool = false

    private var moveObserver: NSObjectProtocol?
    private var moveDebounceTimer: Timer?
    private var isPlayingObserver: AnyCancellable?

    convenience init() {
        let size = overlayDefaultSize
        let rect = NSRect(origin: Self.restoredOrigin(size: size), size: size)
        let panel = LyricsOverlayWindow(contentRect: rect)
        self.init(window: panel)

        let hosting = NSHostingView(rootView: LyricsOverlayView(onContentHeightChange: { [weak self] height in
            self?.updateHeight(height)
        }))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSavePosition() }
        }

        // 订阅播放状态(PlaybackCoordinator 统一了 relay/local 两个数据源,不用关心当前
        // 到底是哪个源在跑)——不管 hideWhenNotPlaying 这个开关有没有打开都订阅,开关本身
        // 只影响 updateActualVisibility() 里的判断,订阅这一步保持常开更简单,不用在开关
        // 切换时动态订阅/取消订阅。
        //
        // 关键坑:sink 闭包里必须用这里收到的 isPlaying 参数,不能在闭包里另外去读
        // PlaybackCoordinator.shared.isPlayingNow 这个存储属性——@Published 的 willSet
        // 会在真正把新值写进存储属性*之前*就把新值发布出去,这个时间点上闭包里直接读存储
        // 属性拿到的是*上一次*的旧值,不是这次改变后的新值(实测用独立 Combine demo 坐实:
        // sink 收到的参数已经是新值,但闭包内 self.property 读到的还是旧值)。之前踩过这个
        // 坑:改成从存储属性读,会导致每次暂停/恢复播放都要再等一次(本地模式 2 秒、
        // relay 模式最长 60 秒)轮询周期后"碰巧又发布了一次没变化的值"才纠正过来,实测确认
        // 暂停后隔了将近一个轮询周期悬浮窗才消失,不是立即生效。
        isPlayingObserver = PlaybackCoordinator.shared.$isPlayingNow.sink { [weak self] isPlaying in
            self?.updateActualVisibility(isPlayingNow: isPlaying)
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingNow)
        // 这里刻意继续只跟 isVisible(用户手动的显示/隐藏)挂钩,不跟着 hideWhenNotPlaying
        // 的自动隐藏状态走——网络轮询(relay 模式)隐藏时会退到 60s 一次,如果自动隐藏也
        // 触发这个,暂停时轮询变慢,恢复播放要等下一次轮询才能被发现,自动隐藏的"暂停后
        // 立刻隐藏、恢复播放立刻重新显示"这个及时性反而会变差。
        RelayPoller.shared.setOverlayVisible(visible)
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

    // 锁定位置:关掉"点背景拖拽移动"的能力,顺带打开点击穿透(ignoresMouseEvents)——
    // 这个窗口除了拖拽移动之外没有任何其它可交互内容,原来把"点击穿透"设成独立开关,
    // 实际效果几乎跟"锁定位置"完全重叠(开着点击穿透自然也拖不动),用户反馈这两个
    // 开关是冗余的,合并成一个:锁定 = 不能拖 + 点击穿透到下层;解锁 = 能拖 + 正常
    // 拦截点击。
    func setLocked(_ locked: Bool) {
        isPositionLocked = locked
        window?.isMovableByWindowBackground = !locked
        window?.ignoresMouseEvents = locked
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
        let newHeight = max(overlayDefaultSize.height, ceil(contentHeight))
        let current = window.frame
        guard abs(newHeight - current.height) >= 0.5 else { return } // 避免亚像素抖动反复触发
        let top = current.origin.y + current.height
        let newFrame = NSRect(x: current.origin.x, y: top - newHeight, width: current.width, height: newHeight)
        window.setFrame(newFrame, display: true, animate: true)
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
