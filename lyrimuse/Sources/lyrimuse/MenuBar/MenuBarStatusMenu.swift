import AppKit
import Combine
import KeyboardShortcuts
import LyrimuseCore

// 状态栏那个下拉菜单(从 SwiftUI 搬到 AppKit)。
//
// 为什么手写 NSMenu 而不是把原来的 SwiftUI 菜单原样端过来:
//   * NSHostingMenu(能把 SwiftUI 视图树变成 NSMenu 的那个 API)要 **macOS 14.4**,
//     而这个 App 的下限是 14.0 —— 不值得为一个下拉菜单抬高系统门槛。
//   * 菜单打开/关闭这两个时机本来就要自己接(滚动歌词得跟着反白,见
//     MenuBarScrollingLabel.setHighlighted),NSMenuDelegate 顺手就有。
//   * 顺带甩掉一个 SwiftUI 菜单的老毛病:那边默认**不画** Label 的图标,得靠外层套一句
//     .labelStyle(.titleAndIcon) 才显示,不加就整排图标凭空消失。
//
// 每次弹出前整棵重建(menuNeedsUpdate)。菜单项十几个,重建的代价可以忽略,换来的是
// "显示的一定是此刻的状态",不用为每一项单独维护刷新逻辑。
//
// 贯穿全文件的一条不变量(跟 AppDelegate/SettingsView/GlobalHotkeys 那三处同源,
// 详见 NotchLyricsWindowController 顶部注释):**构建菜单时只读 AppSettings,绝不碰
// LyricsOverlayWindowController.shared / NotchLyricsWindowController.shared**。两个
// 控制器都是 `static let shared`,真正引用到才会执行 init() 建窗口,而 init() 里订阅
// PlaybackCoordinator 的那个 sink 在订阅瞬间就会按当下的 isVisible 显示/隐藏一次 ——
// 在构建路径上碰它,等于"点开一次菜单就把用户关掉的悬浮窗凭空建出来"。
// 唯一的例外是"锁定位置"那一项,它必须读控制器自己的 isPositionLocked;所以它只在
// classicOverlayEnabled 为真(控制器必然已经存在)时才构建。
// 在 action 里碰是可以的:那是用户主动要求打开/关闭它。
@MainActor
final class MenuBarStatusMenu: NSObject, NSMenuDelegate {
    private var onHighlightChange: ((Bool) -> Void)?

    /// - Parameter onHighlightChange: 菜单打开/关闭。状态栏那行滚动歌词要跟着反白 ——
    ///   以前用模板图时这件事是系统免费做的,自己拿图层之后得自己转达。
    func makeMenu(onHighlightChange: @escaping (Bool) -> Void) -> NSMenu {
        self.onHighlightChange = onHighlightChange
        let menu = NSMenu()
        menu.delegate = self
        // 自己控制启用状态,不走 AppKit 那套"按 target 能不能响应 action"的自动判定 ——
        // 这里每一项都是常驻可点的,没有需要变灰的场景。
        menu.autoenablesItems = false
        // 这里**不**先 rebuild 一遍:弹出前 AppKit 必然回调 menuNeedsUpdate,
        // 那里会构建 —— 原来这行让整棵菜单每次弹出都构建两遍,第一遍是白做的。
        return menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 只有根菜单挂了 delegate,子菜单跟着根菜单一起重建,不会重复进来。
        rebuild(menu)
        AutomationAlertMonitor.shared.refresh()
    }

    /// 菜单开着时盯权限提示:menuNeedsUpdate 里先用缓存的结果建菜单、再发起一次异步刷新,结果回来时菜单
    /// 多半还开着 —— 当场重建一次,别让这次打开看到的是上一次的结论(刚撤销权限时第一次打开看不到提示)。
    private var alertObservation: AnyCancellable?

    func menuWillOpen(_ menu: NSMenu) {
        onHighlightChange?(true)
        alertObservation = AutomationAlertMonitor.shared.$alert.dropFirst()
            .sink { [weak self, weak menu] _ in
                // @Published 在 willSet 时发布,rebuild 读的是 shared.alert:排到下一拍再读。菜单追踪期间
                // GCD 主队列照样会跑(RunLoop.main 的 default 模式不跑,所以不用 receive(on:))。
                DispatchQueue.main.async {
                    guard let self, let menu else { return }
                    self.rebuild(menu)
                }
            }
    }

    func menuDidClose(_ menu: NSMenu) {
        alertObservation = nil
        onHighlightChange?(false)
    }

    // MARK: - 构建

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared

        // 正在播的这家自动化权限被拒或作废时,顶上一行提示 + 处理入口(判据见 AutomationAlert)。
        // 读的是 AutomationAlertMonitor 的缓存,构建路径上不做跨进程查询。
        if let alert = AutomationAlertMonitor.shared.alert {
            let item = makeItem(String(format: L10n.t("%@ 的自动化权限未开启…"), alert.player.displayName),
                                symbol: "exclamationmark.triangle.fill",
                                selector: #selector(resolveAutomationAlert))
            item.toolTip = L10n.t("未授权时，播放进度可能不准确，歌词上的播放控制也无法使用")
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // 排法见 06 章决策 48:偏移在最上面原地调,下面是这首歌的「搜索歌词…」和「快速开关」;
        // 看歌词的两扇窗一组;设置 / 更新 / 关于 / 帮助一组;退出单独一组。
        // 能对上全局快捷键的项把用户录的那个组合显示在右侧(`shortcut:`);菜单开着时全局快捷键是停用的
        // (GlobalHotkeys.pauseWhileMenuTracking),按下去只触发菜单项这一次。
        //
        // 没有任何曲目信息(从未播过任何曲目)时偏移和搜索歌词都不显示,不留点了也没意义的项;广告、电台串场也不给
        // (口径同面板背面「歌词管理」那几项),不然偏移记在广告上、搜索对着广告标题搜。
        if !coordinator.title.isEmpty, !coordinator.isCurrentTrackAdBreak, !coordinator.isRadioTalkBreak {
            let offset = NSMenuItem()
            // 顶层没有勾选列,标题按 16 对齐其余菜单项的文字。
            offset.view = MenuStepperRowView.lyricsOffset(titleInset: 16)
            menu.addItem(offset)
            menu.addItem(action(L10n.t("搜索歌词…"), symbol: "magnifyingglass",
                                selector: #selector(searchLyrics), shortcut: .lyricsQuickSearchHotkey))
        }

        // ---- 「快速开关」子菜单 ----
        let quick = NSMenu()
        quick.autoenablesItems = false
        quick.addItem(toggle(L10n.t("显示桌面悬浮歌词"), symbol: "captions.bubble",
                             on: settings.classicOverlayEnabled,
                             action: #selector(toggleClassicOverlay), shortcut: .toggleOverlay))
        quick.addItem(toggle(L10n.t("显示灵动岛歌词"), symbol: SurfaceGlyph.notch.rawValue,
                             on: settings.notchOverlayEnabled,
                             action: #selector(toggleNotchOverlay), shortcut: .toggleNotchOverlayHotkey))
        // 菜单栏歌词跟上面两个不一样:它没有独立的 WindowController(就画在状态栏那一行
        // 上),所以直接读写 AppSettings 那个布尔值就够。
        quick.addItem(toggle(L10n.t("显示菜单栏歌词"), symbol: "menubar.rectangle",
                             on: settings.showLyricsInMenuBar,
                             action: #selector(toggleMenuBarLyrics), shortcut: .toggleMenuBarLyricsHotkey))
        // 触控栏歌词:这台 Mac 此刻有触控栏时才有(`TouchBarAvailability`,App 启动时已经开始盯,读它没有副作用)。
        // 跟菜单栏歌词一样只翻 AppSettings 那个布尔值,`TouchBarLyricsController` 盯着它启停,拨开的那一下顺手展开。
        // 不挂快捷键:那个快捷键是展开 / 收起,这一项翻的是总开关,两件事。
        if TouchBarAvailability.shared.isPresent {
            quick.addItem(toggle(L10n.t("显示触控栏歌词"), symbol: SurfaceGlyph.touchBar.rawValue,
                                 on: settings.showLyricsInTouchBar,
                                 action: #selector(toggleTouchBarLyrics)))
        }
        // 只有经典悬浮窗有"锁定位置"这个概念(灵动岛的位置是算出来的、贴死屏幕顶部)。
        // 这一项是全文件唯一允许碰 .shared 的构建路径,前提就是这个 if(见文件头)。
        if settings.classicOverlayEnabled {
            let locked = LyricsOverlayWindowController.shared.isPositionLocked
            // 图标跟着锁定状态动态换(锁上/打开),不是固定图标 —— 跟"关于"tab 里状态图标
            // 那套"用图标本身表达当前状态"的做法一致。
            quick.addItem(toggle(L10n.t("锁定位置"),
                                 symbol: locked ? "lock.fill" : "lock.open.fill",
                                 on: locked, action: #selector(toggleLockPosition), shortcut: .toggleLockPosition))
        }
        quick.addItem(.separator())
        // 译文 / 读音跟同名快捷键一个口径:悬浮歌词、歌词窗口两份一起切,有一处开着就打勾。
        quick.addItem(toggle(L10n.t("显示译文"), symbol: "character.book.closed",
                             on: settings.overlayShowTranslation || settings.showTranslation,
                             action: #selector(toggleTranslation), shortcut: .toggleTranslationHotkey))
        quick.addItem(toggle(L10n.t("显示读音"), symbol: "textformat.abc",
                             on: settings.overlayShowRomanization || settings.showRomanization,
                             action: #selector(toggleRomanization), shortcut: .toggleRomanizationHotkey))
        quick.addItem(.separator())
        settings.syncLaunchAtLoginFromSystem()
        quick.addItem(toggle(L10n.t("开机启动"), symbol: "power",
                             on: settings.launchAtLoginEnabled,
                             action: #selector(toggleLaunchAtLogin)))
        menu.addItem(submenu(L10n.t("快速开关"), symbol: "switch.2", menu: quick))

        menu.addItem(.separator())
        menu.addItem(action(L10n.t("歌词窗口…"), symbol: "text.quote",
                            selector: #selector(openLyricsWindow), shortcut: .openLyricsWindowHotkey))
        menu.addItem(action(L10n.t("歌词管理…"), symbol: "music.note.list",
                            selector: #selector(openLyricsManager), shortcut: .openLyricsManagerHotkey))

        menu.addItem(.separator())
        let settingsItem = action(L10n.t("设置…"), symbol: "gearshape",
                                  selector: #selector(openSettings), shortcut: .openSettingsHotkey)
        // 没录「打开设置」快捷键时显示系统惯例的 ⌘,。
        if settingsItem.keyEquivalent.isEmpty {
            settingsItem.keyEquivalent = ","
            settingsItem.keyEquivalentModifierMask = .command
        }
        menu.addItem(settingsItem)
        // 同「关于」页那张卡片:无 Sparkle 构建里这一项点了没反应,不如不给。
        // 查到还没装的新版本时换成跟面板底栏同一句提示,点了同样翻到设置的「软件更新」页(06 章决策 46)。
        #if canImport(Sparkle)
        if let update = SparkleUpdaterManager.shared.availableUpdate {
            menu.addItem(action(AppMenuActions.updateTitle(update),
                                symbol: "arrow.down.circle.fill", selector: #selector(openSoftwareUpdate)))
        } else {
            menu.addItem(action(L10n.t("检查更新…"), symbol: "arrow.triangle.2.circlepath",
                                selector: #selector(checkForUpdates)))
        }
        #endif
        menu.addItem(action(L10n.t("关于 Lyrimuse"), symbol: "info.circle",
                            selector: #selector(openAbout)))
        let help = NSMenu()
        help.autoenablesItems = false
        help.addItem(action(L10n.t("重新运行引导…"), symbol: "sparkles",
                            selector: #selector(rerunOnboarding)))
        // 跟设置「关于」页的「反馈问题」同一个入口,见 FeedbackReporter。引导收尾页那句提示写的是这条路径。
        help.addItem(action(L10n.t("反馈问题…"), symbol: "exclamationmark.bubble",
                            selector: #selector(reportIssue)))
        menu.addItem(submenu(L10n.t("帮助"), symbol: "questionmark.circle", menu: help))

        menu.addItem(.separator())
        let quit = action(L10n.t("退出 Lyrimuse"), symbol: "rectangle.portrait.and.arrow.right",
                          selector: #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    // MARK: - 菜单项工厂

    private func makeItem(_ title: String, symbol: String, selector: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        // 菜单项图标按 14pt 排,跟系统自带菜单里的 SF Symbol 一个量级;不写死
        // size(那样会把非正方形的符号压变形)。符号名也可以是自画图标的名字(`SurfaceGlyph`)。
        item.image = NSImage.symbol(named: symbol, pointSize: 14, weight: .regular)
        return item
    }

    /// `shortcut`:用户录了这个全局快捷键就显示在右侧,没录就空着。
    private func action(_ title: String, symbol: String, selector: Selector,
                        shortcut: LyrimuseAction? = nil) -> NSMenuItem {
        let item = makeItem(title, symbol: symbol, selector: selector)
        if let shortcut { item.setShortcut(KeyboardShortcuts.getShortcut(for: KeyboardShortcuts.Name(shortcut))) }
        return item
    }

    private func toggle(_ title: String, symbol: String, on: Bool, action: Selector,
                        shortcut: LyrimuseAction? = nil) -> NSMenuItem {
        let item = self.action(title, symbol: symbol, selector: action, shortcut: shortcut)
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, symbol: String, menu: NSMenu) -> NSMenuItem {
        // 带子菜单的项本身不响应点击,selector 给 nil。
        let item = makeItem(title, symbol: symbol, selector: nil)
        item.submenu = menu
        return item
    }

    // MARK: - 动作
    //
    // 这里可以碰 .shared:用户主动在打开/关闭某个模式,不是被动误触构造。

    @objc private func toggleClassicOverlay() {
        // setVisible(_:) 是打开/关闭一种悬浮歌词的唯一入口,连"顺手把已配置好的隐藏偏好
        // 也应用上"这一步都在里面,菜单/设置页/全局快捷键三处不各自复制一遍。
        LyricsOverlayWindowController.shared.setVisible(!AppSettings.shared.classicOverlayEnabled)
    }

    @objc private func toggleNotchOverlay() {
        NotchLyricsWindowController.shared.setVisible(!AppSettings.shared.notchOverlayEnabled)
    }

    @objc private func toggleMenuBarLyrics() {
        AppSettings.shared.showLyricsInMenuBar.toggle()
    }

    @objc private func toggleTouchBarLyrics() {
        AppSettings.shared.showLyricsInTouchBar.toggle()
    }

    @objc private func toggleLockPosition() {
        guard AppSettings.shared.classicOverlayEnabled else { return }
        let overlay = LyricsOverlayWindowController.shared
        let newValue = !overlay.isPositionLocked
        // 持久化偏好 + 让窗口真正生效,两步都要做,不能只做其中一步
        // (跟 GlobalHotkeys 里那个快捷键完全一致)。
        AppSettings.shared.lockPosition = newValue
        overlay.setLocked(newValue)
    }

    @objc private func toggleLaunchAtLogin() {
        AppSettings.shared.launchAtLoginEnabled.toggle()
    }

    // 跟同名快捷键走同一个派发(两份一起切、当下这首没有译文时也有一句回声)。
    @objc private func toggleTranslation() { LyrimuseActionRunner.perform(.toggleTranslationHotkey) }
    @objc private func toggleRomanization() { LyrimuseActionRunner.perform(.toggleRomanizationHotkey) }

    // 下面几个"打开某扇窗"的动作都走 AppActions —— 那几个闭包里已经带了
    // NSApp.activate(ignoringOtherApps:),.accessory 策略(没有 Dock 图标)下少了这一步
    // 窗口打不开(见 MenuBarSceneActions 里注册处的注释)。
    @objc private func openSettings() { AppActions.shared.openSettings?() }
    @objc private func openLyricsManager() { AppActions.shared.openLyricsManager?() }
    @objc private func openLyricsWindow() { AppActions.shared.openLyricsWindow?() }
    @objc private func rerunOnboarding() { AppMenuActions.rerunOnboarding() }
    @objc private func resolveAutomationAlert() { AutomationAlertMonitor.shared.resolve() }
    @objc private func reportIssue() { AppMenuActions.reportIssue() }
    @objc private func searchLyrics() { AppActions.shared.openLyricsQuickSearch?() }

    @objc private func openAbout() { AppMenuActions.openAbout() }

    #if canImport(Sparkle)
    @objc private func checkForUpdates() { AppMenuActions.checkForUpdates() }
    @objc private func openSoftwareUpdate() { AppMenuActions.openSoftwareUpdate() }
    #endif

    @objc private func quit() {
        // 经 AppExit 登记原因再终止:所有主动退出都从那一个出口走,见 AppExit 头注。
        AppExit.request(.menuQuit)
    }
}
