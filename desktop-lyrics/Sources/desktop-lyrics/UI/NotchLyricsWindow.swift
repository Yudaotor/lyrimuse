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
        // 真机反馈"顶边有一小条不是纯黑"——实测坐实是 hasShadow=true 导致的:AppKit
        // 给无边框透明窗口自动算阴影时,会在窗口内容的最外沿采样出一圈很淡的灰色
        // (跟具体卡片颜色无关,固定在纯黑背景上尤其扎眼,磨砂玻璃因为本身半透明才不
        // 明显),这条窗口贴死在屏幕物理最顶边、这一圈阴影没有地方可以画到窗口外面,
        // 于是内嵌到了可见区域里。这个卡片设计上就是要"从刘海里长出来"、跟屏幕边缘
        // 融为一体,本来就不需要经典悬浮窗那种浮在桌面上方的阴影观感,直接关掉阴影,
        // 而不是想办法把阴影完全画到窗口外面。
        hasShadow = false
        // 磨砂玻璃背景(.thickMaterial)本身会跟随当前 NSAppearance 在浅色/深色两套
        // 材质之间切换——这个悬浮窗设计上任何时候都该是深色磨砂(白字), 不该因为用户
        // 系统外观是浅色模式就跟着变成一块刺眼的白色玻璃。固定成 .darkAqua,跟 boring.
        // notch 真机实现的做法一致(真实开源"贴刘海"项目也这么处理materialBackground)。
        appearance = NSAppearance(named: .darkAqua)
        // 经典悬浮窗用 .floating 就够了,因为它平时待在屏幕中段,从没需要跟系统菜单栏
        // 抢那一条像素。这个新样式恰恰要贴到菜单栏/刘海所在的那一整条——真机实测坐实两轮:
        // .floating(3)和 .statusBar(25,仅比 .mainMenu=24 高一级)都不够,frame 就算
        // 顶到了 y=0、CGWindowListCopyWindowInfo 也报告 isOnscreen/alpha 都正常,肉眼
        // 看真机依然"什么也不显示"——CGWindowListCopyWindowInfo 的 layer 只反映请求的
        // window level,不代表真的绕过了系统菜单栏/刘海自己那条专属渲染层,同 level 或
        // 更低的东西会被那条专属层直接盖住,截图工具目前也测不出这层遮挡关系(截图能看到
        // 但肉眼看不到)。对照三个真实开源"贴刘海"实现(boring.notch/NotchDrop/
        // DynamicNotchKit)交叉验证:跟这里同样是 NSPanel+.nonactivatingPanel 技术方案
        // 的 DynamicNotchKit,用的是 .screenSaver(比 .statusBar 还高好几级),不用任何
        // 私有 API 就能正常贴刘海——换成这个级别。
        level = .screenSaver
        // 跟 LyricsOverlayWindow 同一套 flag,含义见那个文件的注释:.fullScreenAuxiliary
        // 让它能显示在"某个 App 已全屏"那个 Space 上面,.canJoinAllSpaces 跟着切 Space
        // 走不用每次重新显示。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    // 经典悬浮窗(LyricsOverlayWindow)把这两个都锁 false,因为它没有必要跟系统菜单栏
    // 抢渲染层级。这个新样式对照的三个真实开源实现里,唯二两个"不用私有 API 就能贴到
    // 刘海"的(NotchDrop 用真正的 NSWindow 且两个都是 true,DynamicNotchKit 跟这里一样
    // 是 .nonactivatingPanel 但 canBecomeKey 也是 true)都让 canBecomeKey 返回 true——
    // 只有依赖私有 CGS Space 技巧的 boring.notch 才继续锁 false。.nonactivatingPanel
    // 本身已经保证"能变成 key 窗口"这件事不会连带激活/抢占整个 App(不会有 Dock 图标
    // 跳动、不会切菜单栏),所以放开 canBecomeKey 不等于开始抢别的 App 的焦点。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // 真机(有物理刘海的 MacBook)实测坐实的一个坑:AppKit 默认会把窗口的 setFrame
    // 请求"夹"回 visibleFrame 以内,不让普通窗口盖住菜单栏那一条——哪怕这个窗口的
    // level 是 .floating、哪怕算出来的目标位置正是刘海本身的真实坐标。不覆盖这个
    // 方法的话,NotchLyricsWindowController.recomputeGeometry() 算出来"贴着刘海"的
    // frame 会被系统悄悄下移一整个菜单栏高度,实际效果是胶囊浮在刘海下方一小段
    // 距离、跟真刘海视觉上明显脱节(不是"看起来像从刘海里长出来",而是"刘海下面
    // 多了一个不知道哪来的黑胶囊")。返回传入的 frameRect 本身、不做任何调整,这个
    // 窗口就能真正贴到 recomputeGeometry() 算出来的坐标,包括刘海所在的那一整条。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
