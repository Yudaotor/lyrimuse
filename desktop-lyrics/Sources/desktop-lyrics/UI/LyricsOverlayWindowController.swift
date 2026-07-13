import AppKit
import SwiftUI
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

    private var moveObserver: NSObjectProtocol?
    private var moveDebounceTimer: Timer?

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
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible { window?.orderFront(nil) } else { window?.orderOut(nil) }
        RelayPoller.shared.setOverlayVisible(visible)
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
