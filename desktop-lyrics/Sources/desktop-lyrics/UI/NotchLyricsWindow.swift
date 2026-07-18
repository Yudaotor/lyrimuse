import AppKit

// 灵动岛/刘海样式悬浮歌词窗口本体——跟 LyricsOverlayWindow 平行的独立实现(不改造
// 那个类去兼容两种形态,复杂度和风险都更高,见 NotchLyricsWindowController 顶部
// 注释)。NSPanel 技术方案逐项照抄 LyricsOverlayWindow(无边框+常驻置顶+跨 Space/
// 全屏应用可见+不抢焦点),唯一差异:isMovableByWindowBackground = false——灵动岛
// 的位置是算出来的、贴死在屏幕顶部居中,不像经典悬浮窗那样允许用户拖拽换位置,
// "锁定位置"这个概念对这个新样式不适用(没有可拖拽的位置需要锁,也没有位置持久化)。
final class NotchLyricsWindow: NSPanel {
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
        // 跟 LyricsOverlayWindow 同一套 flag,含义见那个文件的注释:.fullScreenAuxiliary
        // 让它能显示在"某个 App 已全屏"那个 Space 上面,.canJoinAllSpaces 跟着切 Space
        // 走不用每次重新显示。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    // .nonactivatingPanel 已经不会主动抢焦点,这里再显式挡掉 key/main——保证鼠标 hover
    // 展开/播放控制按钮的点击永远不会打断用户正在操作的其它 App,跟 LyricsOverlayWindow
    // 的取舍完全一致。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
