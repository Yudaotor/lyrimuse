import AppKit
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "dockicon")

// "歌词窗口"/"歌词管理"/"设置"/"欢迎使用"这几扇正经标题栏窗口开着期间的记账。
//
// ## 不再借 Dock 图标
//
// 这几扇窗打开时会把 activationPolicy 临时切成 .regular 借一个 Dock
// 图标、全部关掉再还原。起因是 .accessory 下切到别的 App 后窗口就找不回来了,Cmd-Tab
// 里完全看不到 lyrimuse。这个折中被否掉了:「在 Dock 中显示」关掉就该
// 一个图标都不出现,**开关说了算**,不接受"窗口一开它自己冒出来"。
//
// 于是 windowDidAppear 不再碰 activationPolicy。换来的代价是用户知情并接受的:
// showInDock 关着时,切到别的 App 后这几扇窗会被压在后面、Cmd-Tab 里叫不出来,要点
// 菜单栏图标重新叫回来。**打开窗口本身不受影响** —— 每条开窗路径各自带着
// NSApp.activate(ignoringOtherApps:)(MenuBarStatusMenu.swift:261 等),`.accessory`
// 下唤起窗口全靠它,跟 policy 切不切无关。
//
// ## openCount 为什么还留着
//
// 它已经不为"什么时候还 Dock 图标"服务了,但另外两件事还在用:AppDelegate 的
// applicationShouldHandleReopen 拿 hasAnyOpen 判断"该不该顺便开歌词窗口",
// bringOpenWindowsForward 靠它决定点 Dock 图标时要不要把窗口捞回来(showInDock 开着
// 时 Dock 里确实有图标可点)。多扇辅助窗口可能同时开着(比如"设置"和"歌词管理"),
// 所以是计数器而不是布尔值。
@MainActor
enum AuxiliaryWindowActivation {
    private static var openCount = 0

    // 给 AppDelegate.applicationShouldHandleReopen 用:"这几扇辅助窗口里有没有任意一扇
    // 还开着"——`.onDisappear` 只在窗口真正**关闭**时触发,最小化不算关闭,所以这个计数器
    // 天然就是"开着"而不是"当前可见",拿来判断"该不该顺便开歌词窗口"正合适,不用另起一套
    // 窗口枚举逻辑。
    static var hasAnyOpen: Bool { openCount > 0 }

    // 挂在每个辅助窗口根视图的 .onAppear。`who` 只进日志:现象是"设置里关掉了
    // 「在 Dock 中显示」,图标却还在",而当时手上只有 reopen 那条"计数器说有窗开着、枚举却一扇
    // 都没找到"的日志,分不清是哪一扇窗加的这一笔 —— 加减两头都记名字,下次一眼能对上账。
    //
    // 这里**不许**碰 activationPolicy(理由见文件头)。加回一句
    // `setActivationPolicy(.regular)` 就等于让「在 Dock 中显示」这个开关重新失灵,
    // 而它失灵的样子恰好是"关了图标还在" —— 用户为此报过两次。
    static func windowDidAppear(_ who: String) {
        openCount += 1
        logger.notice("aux window opened: \(who, privacy: .public) -> openCount=\(openCount, privacy: .public)")
    }

    // 挂在每个辅助窗口根视图的 .onDisappear。归零时仍调一次 restoreAccessoryIfWanted ——
    // 撤掉借用之后那是纯兜底(正常路径上 policy 根本没被动过,它那道
    // `activationPolicy() != .accessory` 的闸会直接挡掉),留着是因为"policy 漂成 .regular
    // 却没人还原"这个故障历史上真出过,而这里是最自然的复位点。
    static func windowDidDisappear(_ who: String) {
        openCount = max(0, openCount - 1)
        logger.notice("aux window closed: \(who, privacy: .public) -> openCount=\(openCount, privacy: .public)")
        if openCount == 0 {
            restoreAccessoryIfWanted("last auxiliary window closed")
            return
        }
        // 计数器还没归零,但它只是个代理值 —— 关窗这一刻跟真实窗口列表对一次账。
        // 必须排到下一轮 runloop:隔离探针实测,`.onDisappear` 触发的**同一拍**里,
        // 正在关的那扇窗 `isVisible` 仍然是 true(下一轮才从列表里消失),当场核会永远认为
        // "还有窗开着",这道对账就成了摆设。
        DispatchQueue.main.async { MainActor.assumeIsolated { reconcile(reason: "after closing \(who)") } }
    }

    /// 计数器 与 真实窗口列表对账:真实列表说一扇都没开着,就按"一扇都没开"处理(计数器清零、
    /// 还原 .accessory)。
    ///
    /// 为什么需要它:openCount 是"有没有辅助窗口开着"的**代理值**,靠 SwiftUI 的
    /// `.onAppear`/`.onDisappear` 一加一减维持。这两个回调的触发时机不完全由本仓控制,一旦
    /// 哪条路径只加不减,计数器就永久停在 >0,且**无法自愈**(开一扇关一扇是 +1-1,回不到 0)。
    /// 撤掉 Dock 图标借用之前,这个卡死直接表现成"关掉了「在 Dock 中显示」、图标
    /// 却收不回去",只能重启 App;现在它影响的是 reopen 那条路(hasAnyOpen 恒为真,点 Dock
    /// 图标时去捞一扇根本不存在的窗)。加这道对账之后,漏加的那一笔在下一次关窗 / 下一次点
    /// Dock 图标时就被抹平。
    ///
    /// `NSApp.isHidden` 那道闸不能省:Cmd+H 把 App 整个隐藏时,窗口只是 orderOut、**没关**,
    /// 但真实列表里它们 `isVisible=false`(探针实测),不挡住就会把"隐藏着的开着的窗"
    /// 误判成"一扇都没开"。
    static func reconcile(reason: String) {
        guard !NSApp.isHidden else { return }
        guard openAuxiliaryWindows().isEmpty else { return }
        if openCount > 0 {
            logger.error("openCount=\(openCount, privacy: .public) but no auxiliary window is actually open (\(reason, privacy: .public)) -- treating as 0")
            openCount = 0
        }
        restoreAccessoryIfWanted("reconcile: \(reason)")
    }

    /// 兜底复位成"没有 Dock 图标"。三道前提:计数器归零、用户没打开那个永久偏好、当前确实
    /// 不是 .accessory。撤掉借用之后,正常路径上第三道闸就把它挡住了(没人再把
    /// policy 切成 .regular);它只在 policy 不知被谁弄成 .regular、而用户偏好是"不显示"时
    /// 才真的动手。
    private static func restoreAccessoryIfWanted(_ reason: String) {
        guard openCount == 0, !AppSettings.shared.showInDock else { return }
        guard NSApp.activationPolicy() != .accessory else { return }
        logger.notice("restoring .accessory (\(reason, privacy: .public))")
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

    /// 点 Dock 图标时把开着的辅助窗口**真正**带回来。
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
        let open = openAuxiliaryWindows()
        guard !open.isEmpty else { return result }

        // orderedWindows 是前到后;最小化的窗口不一定在里面,所以可见那扇找不到时退回枚举顺序。
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

    /// 真正开着(含最小化)的辅助窗口。bringOpenWindowsForward 与 reconcile 共用一处,
    /// 免得两边的"开着"口径漂移。
    private static func openAuxiliaryWindows() -> [NSWindow] {
        NSApp.windows.filter { isAuxiliaryRegularWindow($0) && ($0.isVisible || $0.isMiniaturized) }
    }

    /// 设置 / 歌词管理 / 歌词窗口 / 欢迎使用 / 搜索歌词… 这类"正经"窗口的形态判据。悬浮歌词和
    /// 灵动岛是 NSPanel,状态栏项、菜单栏面板、场景 action 的隐藏锚点都是无标题栏窗口,全部排除。
    ///
    /// `canBecomeMain` 不能单独用:**窗口一最小化它就变 false**(隔离探针实测,
    /// 同一扇窗 `isVisible=false isMiniaturized=true canBecomeMain=false`;AppKit 对这个属性的
    /// 定义里本来就含"窗口可见"这一条)。原来只写 canBecomeMain,于是上面那句
    /// `($0.isVisible || $0.isMiniaturized)` 的 isMiniaturized 分支是**死代码** ——
    /// bringOpenWindowsForward 永远 restored=0(用户日志里每一次点击都是),那版
    /// "最小化的全部还原"根本没跑起来过;最小化的辅助窗口既点 Dock 叫不回来、又一直占着借来的
    /// Dock 图标,而用户开着「最小化窗口到应用程序图标」时 Dock 上连个缩略图都看不见,
    /// 表现就是"窗口明明都关了,图标赖着不走"。
    private static func isAuxiliaryRegularWindow(_ w: NSWindow) -> Bool {
        !(w is NSPanel) && w.styleMask.contains(.titled) && (w.canBecomeMain || w.isMiniaturized)
    }
}
