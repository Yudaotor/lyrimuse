import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 迷你窗的悬停跟踪,报给「悬浮淡化」(`LyricsWindowHoverFade`)和迷你面板的红绿灯。管整扇迷你窗(含标题栏那一条)。
///
/// 用 AppKit 跟踪区、选项带 `.activeAlways`,不用 SwiftUI `.onHover`:后者只在 Lyrimuse 是当前 App 时才报,
/// 而迷你窗最常见的用法是浮在别的 App 上面。只跟踪、不接点击(`hitTest` 返回 nil),点按照常落到下面的控件上。
struct MiniWindowHoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    /// 让这扇窗(`object`)上的跟踪视图重新挂一次跟踪区、按真实指针位置重报。「淡化时点按穿透」那段时间里窗口收不到
    /// 鼠标事件,跟踪区没报的进出要补上(07 章决策 144)。
    static let resyncNotification = Notification.Name("MiniWindowHoverTracker.resync")

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var inside = false

        /// 跟踪区挂在整扇窗最外层(内容视图的父视图,含标题栏那一条),不挂在自己身上:这个视图在 SwiftUI 内容里,
        /// 盖不到窗口最上面那一条,指针一进标题栏就报「离开」(07 章决策 137)。
        private weak var frameView: NSView?
        private var frameArea: NSTrackingArea?
        private var resyncObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installFrameTracking()
            if let resyncObserver { NotificationCenter.default.removeObserver(resyncObserver) }
            resyncObserver = nil
            guard let window else { return }
            resyncObserver = NotificationCenter.default.addObserver(
                forName: MiniWindowHoverTracker.resyncNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.installFrameTracking() }
            }
        }

        private func installFrameTracking() {
            if let frameArea, let frameView { frameView.removeTrackingArea(frameArea) }
            frameArea = nil
            frameView = nil
            guard let window, let host = window.contentView?.superview else { return }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
            host.addTrackingArea(area)
            frameArea = area
            frameView = host
            // 挂上那一刻指针已经在窗里:跟踪区不补这一下「进入」。
            report(NSRect(origin: .zero, size: window.frame.size).contains(window.mouseLocationOutsideOfEventStream))
        }

        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        // 拆掉时指针可能还在窗里(切回完整尺寸、关窗):不补一个「离开」,窗口会一直淡着。
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                if let frameArea, let frameView { frameView.removeTrackingArea(frameArea) }
                frameArea = nil
                frameView = nil
                report(false)
            }
        }

        private func report(_ value: Bool) {
            guard inside != value else { return }
            inside = value
            onChange?(value)
        }
    }
}

/// 迷你窗「悬浮淡化」(07 章决策 118):开着这颗设置、窗口在迷你、指针一进窗,整扇窗淡到
/// `LyricsWindowMiniHoverFade.dimmedAlpha`,出去就恢复。默认不穿透:淡着的时候点击、拖动照样落在这扇窗上;按下鼠标
/// 就恢复不透明,这次停留里不再淡 —— 按下去就是要用这扇窗(按控制条、拖动、点歌词跳转),对着一扇看不清的窗操作不顺手。
///
/// 开着从属的「淡化时点按穿透」时(07 章决策 144),淡着的那段时间整扇窗 `ignoresMouseEvents`,点按落到下面的窗口;
/// 按住 ⌥ 恢复不透明、收得到点按。这段时间里指针进出和 ⌥ 靠轮询判,跟踪区报上来的进出不作数。
///
/// 动的是整扇窗的 `alphaValue`(背景、阴影一起淡),窗口别处不碰它;`ignoresMouseEvents` 只在自己的穿透状态翻转时写。
@MainActor
final class LyricsWindowHoverFade {
    private weak var window: NSWindow?
    private var enabled = false
    private var clickThrough = false
    private var isMini = false
    private var hovered = false
    private var heldOpenByClick = false
    /// 按住 ⌥,只在开着「淡化时点按穿透」时由轮询更新。
    private var revealHeld = false
    private var passingThrough = false
    private var pointerPoll: Timer?
    private var mouseDownMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    /// 窗口第一次 attach 时调。`isMini` 是窗口控制器那个 @Published 的发布者;两个订阅都会先报一次当前值。
    func attach(_ window: NSWindow, isMini: AnyPublisher<Bool, Never>) {
        self.window = window
        cancellables.removeAll()
        isMini.removeDuplicates().sink { [weak self] in self?.miniChanged($0) }.store(in: &cancellables)
        AppSettings.shared.$lyricsWindowMiniFadeOnHover.removeDuplicates()
            .sink { [weak self] in self?.enabledChanged($0) }.store(in: &cancellables)
        AppSettings.shared.$lyricsWindowMiniFadeClickThrough.removeDuplicates()
            .sink { [weak self] in self?.clickThroughChanged($0) }.store(in: &cancellables)
        if mouseDownMonitor == nil {
            // 本地监听只收得到送进本 App 的事件:点在这扇窗上的那一下(App 原本不在前台时,第一下点击也送进来)。
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.mouseDown(in: event.window) }
                return event
            }
        }
        apply(animated: false)
    }

    deinit {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        pointerPoll?.invalidate()
    }

    func setHovered(_ value: Bool) {
        // 穿透期间窗口收不到鼠标事件,跟踪区报的进出不作数,指针在不在窗里由 `pollPointer` 判。
        if passingThrough { return }
        hovered = value
        if !value { endStay() }
        apply(animated: true)
    }

    /// 关窗时调:下次打开从不透明开始。
    func windowClosed() {
        hovered = false
        endStay()
        apply(animated: false)
    }

    private func endStay() {
        heldOpenByClick = false
        revealHeld = false
    }

    private func miniChanged(_ mini: Bool) {
        isMini = mini
        if !mini {
            hovered = false
            endStay()
        }
        apply(animated: false)
    }

    private func enabledChanged(_ on: Bool) {
        enabled = on
        apply(animated: true)
    }

    private func clickThroughChanged(_ on: Bool) {
        clickThrough = on
        if !on { revealHeld = false }
        apply(animated: true)
    }

    private func pollPointer() {
        guard let window else { return }
        if !(window.isVisible && window.frame.contains(NSEvent.mouseLocation)) {
            hovered = false
            endStay()
            apply(animated: true)
            return
        }
        let option = NSEvent.modifierFlags.contains(.option)
        guard option != revealHeld else { return }
        revealHeld = option
        apply(animated: true)
    }

    private func updatePointerPoll() {
        typealias F = LyricsWindowMiniHoverFade
        let polls = F.pollsPointer(enabled: enabled, clickThrough: clickThrough, isMini: isMini,
                                   hovered: hovered, heldOpenByClick: heldOpenByClick)
        if !polls {
            pointerPoll?.invalidate()
            pointerPoll = nil
            return
        }
        guard pointerPoll == nil else { return }
        let timer = Timer(timeInterval: F.pointerPollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        timer.tolerance = F.pointerPollSeconds / 2
        RunLoop.main.add(timer, forMode: .common)
        pointerPoll = timer
    }

    private func mouseDown(in eventWindow: NSWindow?) {
        guard let window, eventWindow === window, hovered, !heldOpenByClick else { return }
        heldOpenByClick = true
        apply(animated: true)
    }

    private func apply(animated: Bool) {
        guard let window else { return }
        let dim = LyricsWindowMiniHoverFade.shouldDim(enabled: enabled, isMini: isMini,
                                                      hovered: hovered, heldOpenByClick: heldOpenByClick,
                                                      revealHeld: clickThrough && revealHeld)
        let pass = LyricsWindowMiniHoverFade.passesClicksThrough(clickThrough: clickThrough, dimmed: dim)
        if pass != passingThrough {
            passingThrough = pass
            window.ignoresMouseEvents = pass
            if !pass {
                // 推迟一拍:重报会经窗口控制器回到 `setHovered`,别在这次 apply 里重入。
                DispatchQueue.main.async { [weak window] in
                    guard let window else { return }
                    NotificationCenter.default.post(name: MiniWindowHoverTracker.resyncNotification, object: window)
                }
            }
        }
        updatePointerPoll()
        let target = CGFloat(dim ? LyricsWindowMiniHoverFade.dimmedAlpha : 1)
        // 不带动画时也走 animator(时长 0):直接写 alphaValue 盖不掉还在跑的那段淡入淡出。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated
                ? (dim ? LyricsWindowMiniHoverFade.dimSeconds : LyricsWindowMiniHoverFade.restoreSeconds)
                : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = target
        }
    }
}
