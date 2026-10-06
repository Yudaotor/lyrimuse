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
        // 窗口阴影跟着"背景卡片"设置走,由控制器订阅 backgroundIsVisible 驱动(见
        // LyricsOverlayWindowController 里 shadowObserver 那段注释):透明 shaped 窗口的
        // 阴影要 WindowServer 按内容 alpha 轮廓提取+模糊来算,每次换行高度动画逐帧重算;
        // 默认无背景模式下内容只有细字形,这份阴影视觉上根本不可见,纯付成本。这里给的
        // 只是订阅回放前的一瞬间的初值,跟默认设置(无背景)一致。
        hasShadow = false
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

    /// 指针停在按钮 / 歌词文字上时窗口收回了点击穿透,滚轮会落到这里:交给控制器还原穿透,这一格丢掉,
    /// 同一手势后面的滚动直接到下层(见 `LyricsOverlayWindowController.yieldPointerCaptureToScroll`)。
    var onScrollWheel: (@MainActor () -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?()
    }
}
