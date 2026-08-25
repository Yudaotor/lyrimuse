import AppKit

// 2026-08-04 新增——"歌词窗口"/"歌词管理"/"设置"/"欢迎使用"这几个正经标题栏窗口默认
// 在 .accessory 策略(没有 Dock 图标)下打开,关掉/切到别的 App 后只能重新点菜单栏
// 图标才能找回来,Cmd-Tab 完全看不到——MenuBarMenu.swift 里到处撒的
// NSApp.activate(ignoringOtherApps:) 本身就是这个摩擦的旁证(不这么做,openWindow
// 调了也没反应)。这几个窗口打开期间临时借一个 Dock 图标,关掉后(且没有别的辅助
// 窗口还开着)还原,不持久化——跟"在 Dock 中显示"这个永久偏好(AppSettings.showInDock)
// 是两回事,那个开着时这里全程不用管,不会跟永久偏好打架。
//
// openCount 而不是"最后一个关的窗口负责还原"这种简单逻辑:多个辅助窗口可能同时开着
// (比如"设置"和"歌词管理"),关掉其中一个时不该把 Dock 图标也收走,得等全部都关了
// 才还原——跟 LyricFever 自己检查"fullscreen 是不是还开着"再决定要不要切回
// .accessory 是同一个道理,这里把它泛化成"还有没有任意一个辅助窗口开着"的计数器。
@MainActor
enum AuxiliaryWindowActivation {
    private static var openCount = 0

    // 给 AppDelegate.applicationShouldHandleReopen 用:"这几扇辅助窗口里有没有任意一扇
    // 还开着"——`.onDisappear` 只在窗口真正**关闭**时触发,最小化不算关闭,所以这个计数器
    // 天然就是"开着"而不是"当前可见",拿来判断"该不该顺便开歌词窗口"正合适,不用另起一套
    // 窗口枚举逻辑。
    static var hasAnyOpen: Bool { openCount > 0 }

    // 挂在每个辅助窗口根视图的 .onAppear。
    static func windowDidAppear() {
        openCount += 1
        guard !AppSettings.shared.showInDock else { return }
        NSApp.setActivationPolicy(.regular)
    }

    // 挂在每个辅助窗口根视图的 .onDisappear——openCount 归零(所有辅助窗口都关了)才
    // 还原,且要在还原前再读一次 showInDock:用户可能在窗口开着期间自己把这个永久
    // 偏好打开了,那种情况下不应该在这里把它又切回 .accessory。
    static func windowDidDisappear() {
        openCount = max(0, openCount - 1)
        guard openCount == 0, !AppSettings.shared.showInDock else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
