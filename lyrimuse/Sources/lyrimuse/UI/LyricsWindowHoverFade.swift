import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 迷你窗的悬停跟踪,报给「悬浮淡化」(`LyricsWindowHoverFade`)。铺满整扇迷你窗(含标题栏那一条)。
///
/// 用 AppKit 跟踪区、选项带 `.activeAlways`,不用 SwiftUI `.onHover`:后者只在 Lyrimuse 是当前 App 时才报,
/// 而迷你窗最常见的用法是浮在别的 App 上面。只跟踪、不接点击(`hitTest` 返回 nil),点按照常落到下面的控件上。
struct MiniWindowHoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

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

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        // 拆掉时指针可能还在窗里(切回完整尺寸、关窗):不补一个「离开」,窗口会一直淡着。
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { report(false) }
        }

        private func report(_ value: Bool) {
            guard inside != value else { return }
            inside = value
            onChange?(value)
        }
    }
}

/// 迷你窗「悬浮淡化」(07 章决策 118):开着这颗设置、窗口在迷你、指针一进窗,整扇窗淡到
/// `LyricsWindowMiniHoverFade.dimmedAlpha`,出去就恢复。不穿透:淡着的时候点击、拖动照样落在这扇窗上;按下鼠标
/// 就恢复不透明,这次停留里不再淡 —— 按下去就是要用这扇窗(按控制条、拖动、点歌词跳转),对着一扇看不清的窗操作不顺手。
///
/// 动的是整扇窗的 `alphaValue`(背景、阴影一起淡),窗口别处不碰它。
@MainActor
final class LyricsWindowHoverFade {
    private weak var window: NSWindow?
    private var enabled = false
    private var isMini = false
    private var hovered = false
    private var heldOpenByClick = false
    private var mouseDownMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    /// 窗口第一次 attach 时调。`isMini` 是窗口控制器那个 @Published 的发布者;两个订阅都会先报一次当前值。
    func attach(_ window: NSWindow, isMini: AnyPublisher<Bool, Never>) {
        self.window = window
        cancellables.removeAll()
        isMini.removeDuplicates().sink { [weak self] in self?.miniChanged($0) }.store(in: &cancellables)
        AppSettings.shared.$lyricsWindowMiniFadeOnHover.removeDuplicates()
            .sink { [weak self] in self?.enabledChanged($0) }.store(in: &cancellables)
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
    }

    func setHovered(_ value: Bool) {
        hovered = value
        if !value { heldOpenByClick = false }
        apply(animated: true)
    }

    /// 关窗时调:下次打开从不透明开始。
    func windowClosed() {
        hovered = false
        heldOpenByClick = false
        apply(animated: false)
    }

    private func miniChanged(_ mini: Bool) {
        isMini = mini
        if !mini {
            hovered = false
            heldOpenByClick = false
        }
        apply(animated: false)
    }

    private func enabledChanged(_ on: Bool) {
        enabled = on
        apply(animated: true)
    }

    private func mouseDown(in eventWindow: NSWindow?) {
        guard let window, eventWindow === window, hovered, !heldOpenByClick else { return }
        heldOpenByClick = true
        apply(animated: true)
    }

    private func apply(animated: Bool) {
        guard let window else { return }
        let dim = LyricsWindowMiniHoverFade.shouldDim(enabled: enabled, isMini: isMini,
                                                      hovered: hovered, heldOpenByClick: heldOpenByClick)
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
