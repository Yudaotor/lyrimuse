import AppKit

// 悬浮歌词窗口本体。SwiftUI 自己的 Window/WindowGroup 场景 API 做不到"无边框+常驻置顶+
// 跨 Space(含全屏应用)+可关闭点击穿透"这一整套组合,这些都是 AppKit NSWindow 的能力,
// 所以手写一个 NSPanel 子类,内容仍用 SwiftUI(通过 NSHostingView 承载,见
// LyricsOverlayWindowController)。
final class LyricsOverlayWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        // .fullScreenAuxiliary 是能显示在"某个 App 已全屏"那个 Space 上面的关键 flag,
        // .canJoinAllSpaces 让它跟着切 Space 走、不用每次都重新显示。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }

    // .nonactivatingPanel 已经不会主动抢焦点,这里再显式挡掉 key/main——保证点击/拖拽
    // 悬浮窗永远不会打断用户正在操作的其它 App。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
