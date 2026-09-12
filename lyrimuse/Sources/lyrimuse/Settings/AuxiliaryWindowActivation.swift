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
// 才还原——跟"先检查 fullscreen 是不是还开着、再决定要不要切回 .accessory"是同一个
// 道理(同类实现里常见的写法),这里把它泛化成"还有没有任意一个辅助窗口开着"的计数器。
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

    /// 点 Dock 图标(reopen)带回来的结果,给 AppDelegate 打日志和决定下一步用。
    struct BringForwardResult {
        /// 从最小化状态还原了几扇。
        var restored = 0
        /// 可见窗口里被 makeKeyAndOrderFront 的那扇(0 或 1)。
        var fronted = 0
        /// 那扇被带到前台的窗口在动手之前**就已经**是 key、可见、且在当前 Space 上——
        /// 也就是这一下点击对用户来说什么都没变。只在 restored == 0 时有意义(还原过窗口
        /// 就一定有可见变化)。
        var alreadyFront = false
        /// 计数器说有窗口开着、真去枚举却一扇都没找到。
        var foundNone: Bool { restored == 0 && fronted == 0 }
    }

    /// 点 Dock 图标时把开着的辅助窗口**真正**带回来(2026-09-09)。
    ///
    /// 此前 AppDelegate 在 `hasAnyOpen` 时 `return true` 交给 AppKit 默认 reopen,注释里写的
    /// 预期是"还原被最小化的窗口、把已有窗口带到前台"。隔离探针(自建 .app,只动自己的窗口)
    /// 实测 AppKit 默认只做一件事:**没有任何普通窗口可见时,还原一扇(且只一扇)最小化窗口**;
    /// 只要有一扇普通窗口还可见,它什么都不做。所以"设置窗开着、歌词窗口最小化"时点 Dock 就是
    /// 没反应——用户 02:25 连点 12 下的那段 reopen 日志,每一条都停在这一支。同一探针顺带坐实
    /// `hasVisibleWindows` 对这个 App 恒为 true(悬浮/灵动岛的 NSPanel、状态栏窗口都算进去),
    /// 拿它判断任何事都不成立;以及 SwiftUI 的 `.onDisappear` 关窗必触发、最小化不触发,
    /// `openCount` 这个"开着(含最小化)"的口径是可靠的。
    ///
    /// 这里自己做:最小化的**全部**还原(而不是 AppKit 那种只还原一扇——这个 App 顶多四扇窗,
    /// 用户点 Dock 的意图就是"把我的窗口都叫回来",日志里也确实是先后手动把两扇都点回来);
    /// 可见的按窗口服务器的前后顺序取最前那扇 makeKeyAndOrderFront(窗口在别的 Space 上时,
    /// 成为 key 会把 Space 一起切过去——「窗口」菜单选中某扇窗走的就是这条路,这一点未单独
    /// 实测)。
    ///
    /// "辅助窗口"按窗口本身的形态判(有标题栏、不是 NSPanel、能当主窗口),不去对四个场景的
    /// 标题——标题随语言变、歌词窗口还是 hiddenTitleBar。这样「搜索歌词…」那扇小窗也一并带回:
    /// 它不参与 openCount(不借 Dock 图标),但用户点 Dock 时它若最小化着,没理由不还原。
    @discardableResult
    static func bringOpenWindowsForward() -> BringForwardResult {
        var result = BringForwardResult()
        let open = NSApp.windows.filter { isAuxiliaryRegularWindow($0) && ($0.isVisible || $0.isMiniaturized) }
        guard !open.isEmpty else { return result }

        // orderedWindows 是前→后;最小化的窗口不一定在里面,所以可见那扇找不到时退回枚举顺序。
        let frontVisible = NSApp.orderedWindows.first { w in open.contains(w) && w.isVisible }
            ?? open.first { $0.isVisible }
        let minimized = open.filter(\.isMiniaturized)

        // 还原过窗口就让最后还原的那扇当 key(deminiaturize 本身会把它排到前面);没有可还原的
        // 才去动可见那扇——两者都做会让刚还原的窗口立刻被压到后面。
        if !minimized.isEmpty {
            for w in minimized { w.deminiaturize(nil) }
            result.restored = minimized.count
            minimized.last?.makeKeyAndOrderFront(nil)
        } else if let target = frontVisible {
            // 动手之前先记下它是不是本来就在最前面——makeKeyAndOrderFront 之后再看就永远是 true 了。
            result.alreadyFront = target.isKeyWindow && target.isOnActiveSpace
            target.makeKeyAndOrderFront(nil)
            result.fronted = 1
        }
        return result
    }

    /// 设置 / 歌词管理 / 歌词窗口 / 欢迎使用 / 搜索歌词… 这类"正经"窗口的形态判据。悬浮歌词和
    /// 灵动岛是 NSPanel,状态栏项、菜单栏面板、场景 action 的隐藏锚点都是无标题栏窗口,全部排除。
    private static func isAuxiliaryRegularWindow(_ w: NSWindow) -> Bool {
        !(w is NSPanel) && w.styleMask.contains(.titled) && w.canBecomeMain
    }
}
