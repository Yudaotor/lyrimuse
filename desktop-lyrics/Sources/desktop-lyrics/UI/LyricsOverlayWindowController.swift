import AppKit
import SwiftUI
import DesktopLyricsCore

// 文件级常量(不挂在 @MainActor 类上),避免 Timer 的 @Sendable 闭包里引用
// MainActor-isolated static let 触发并发检查警告。
private let overlayPositionKey = "np:overlayPositionOrigin" // "x,y" 字符串
private let overlayDefaultSize = NSSize(width: 480, height: 120)

// 拥有悬浮窗面板 + SwiftUI 内容 + 拖拽位置持久化。位置存 UserDefaults(裸可执行文件也能
// 跨进程重启正确持久化,已实测确认,不需要 .app 包)。ObservableObject 让菜单栏菜单
// 直接观察 .shared 就能反映"是否显示/是否点击穿透"这两个状态,不用绕经 AppDelegate。
@MainActor
final class LyricsOverlayWindowController: NSWindowController, ObservableObject {
    static let shared = LyricsOverlayWindowController()

    @Published private(set) var isVisible: Bool = true
    @Published private(set) var isClickThrough: Bool = false
    @Published private(set) var isPositionLocked: Bool = false

    private var moveObserver: NSObjectProtocol?
    private var moveDebounceTimer: Timer?

    convenience init() {
        let size = overlayDefaultSize
        let rect = NSRect(origin: Self.restoredOrigin(size: size), size: size)
        let panel = LyricsOverlayWindow(contentRect: rect)
        self.init(window: panel)

        let hosting = NSHostingView(rootView: LyricsOverlayView())
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSavePosition() }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible { window?.orderFront(nil) } else { window?.orderOut(nil) }
        RelayPoller.shared.setOverlayVisible(visible)
    }

    func setClickThrough(_ on: Bool) {
        // 点击穿透打开时 isMovableByWindowBackground 天然失效(鼠标事件根本传不到窗口)——
        // 这是预期取舍,想拖拽就得先关掉点击穿透。
        isClickThrough = on
        window?.ignoresMouseEvents = on
    }

    // 锁定位置:关掉"点背景拖拽移动"这个能力,跟点击穿透是两回事——点击穿透关着的时候
    // 也可能想固定住悬浮窗不被误拖(比如旁边还有别的窗口要拖),这里单独给一个开关。
    func setLocked(_ locked: Bool) {
        isPositionLocked = locked
        window?.isMovableByWindowBackground = !locked
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
