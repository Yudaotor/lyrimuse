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

    // 滚轮**不再需要**任何特殊处理:ignoresMouseEvents 现在恒为 true(唯一例外是长按拖动
    // 武装期间),窗口压根收不到滚轮事件,窗口服务器直接把它派给下层窗口。
    //
    // 原来这里有一个 scrollWheel 覆写(丢掉事件 + 把穿透设回 true)和配套的
    // isDragArmedProvider / onScrollWheelSwallowed 两条接线,都是为了缓解「胶囊热区吞滚轮」;
    // 病根(按指针位置翻转穿透)2026-08-18 删掉之后它们一并没有存在意义了。详见
    // LyricsOverlayWindowController 里「点击穿透 + 悬停热区 + 长按拖动」那一节。
}
