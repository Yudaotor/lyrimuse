import AppKit
import LyrimuseCore

// 状态栏那个下拉菜单(2026-08-16 从 SwiftUI 搬到 AppKit)。
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
// ⚠️ 贯穿全文件的一条不变量(跟 AppDelegate/SettingsView/GlobalHotkeys 那三处同源,
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
        // 这里**不**先 rebuild 一遍(2026-08-19):弹出前 AppKit 必然回调 menuNeedsUpdate,
        // 那里会构建 —— 原来这行让整棵菜单每次弹出都构建两遍,第一遍是白做的。
        return menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 只有根菜单挂了 delegate,子菜单跟着根菜单一起重建,不会重复进来。
        rebuild(menu)
    }

    func menuWillOpen(_ menu: NSMenu) { onHighlightChange?(true) }
    func menuDidClose(_ menu: NSMenu) { onHighlightChange?(false) }

    // MARK: - 构建

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = AppSettings.shared
        let coordinator = PlaybackCoordinator.shared

        // ---- 「快速开关」子菜单 ----
        // 2026-08-06 把四个状态开关收进二级子菜单,顶层只留"点一下就发生一件事"的动作
        // 入口。原来开关和动作混在顶层、靠两条分隔线分区,菜单一共十一项、相当长。
        let quick = NSMenu()
        quick.autoenablesItems = false
        quick.addItem(toggle(L10n.t("显示桌面悬浮歌词"), symbol: "captions.bubble",
                             on: settings.classicOverlayEnabled,
                             action: #selector(toggleClassicOverlay)))
        quick.addItem(toggle(L10n.t("显示灵动岛歌词"), symbol: "rectangle.topthird.inset.filled",
                             on: settings.notchOverlayEnabled,
                             action: #selector(toggleNotchOverlay)))
        // 菜单栏歌词跟上面两个不一样:它没有独立的 WindowController(就画在状态栏那一行
        // 上),所以直接读写 AppSettings 那个布尔值就够。
        quick.addItem(toggle(L10n.t("显示菜单栏歌词"), symbol: "menubar.rectangle",
                             on: settings.showLyricsInMenuBar,
                             action: #selector(toggleMenuBarLyrics)))
        // 只有经典悬浮窗有"锁定位置"这个概念(灵动岛的位置是算出来的、贴死屏幕顶部)。
        // 这一项是全文件唯一允许碰 .shared 的构建路径,前提就是这个 if(见文件头)。
        if settings.classicOverlayEnabled {
            let locked = LyricsOverlayWindowController.shared.isPositionLocked
            // 图标跟着锁定状态动态换(锁上/打开),不是固定图标 —— 跟"关于"tab 里状态图标
            // 那套"用图标本身表达当前状态"的做法一致。
            quick.addItem(toggle(L10n.t("锁定位置"),
                                 symbol: locked ? "lock.fill" : "lock.open.fill",
                                 on: locked, action: #selector(toggleLockPosition)))
        }
        quick.addItem(.separator())
        quick.addItem(toggle(L10n.t("开机启动"), symbol: "power",
                             on: settings.launchAtLoginEnabled,
                             action: #selector(toggleLaunchAtLogin)))
        menu.addItem(submenu(L10n.t("快速开关"), symbol: "switch.2", menu: quick))

        // ---- 「歌词时间轴」子菜单 ----
        // 跟悬浮窗样式(经典/灵动岛)正交——校准的是"当前这首歌的歌词该提前/延后多少",
        // 不管哪种样式在显示都适用,所以不收进上面那个"快速开关":它是一组增减操作,不是开关。
        //
        // 没有任何曲目信息(从未播过任何曲目)时整个子菜单不显示,不留一个点了也没意义的
        // 死菜单项。
        if !coordinator.title.isEmpty {
            let offset = NSMenu()
            offset.autoenablesItems = false
            offset.addItem(action(nudgeTitle(L10n.t("提前")), symbol: "gobackward",
                                  selector: #selector(nudgeEarlier)))
            offset.addItem(action(nudgeTitle(L10n.t("延后")), symbol: "goforward",
                                  selector: #selector(nudgeLater)))
            // 「重置」清的是这首歌的微调,所以按它出现,不看总和(全局基准非 0、这首歌
            // 没调过时,摆一个点了什么都不会变的「重置」才是真的坏)。
            if coordinator.trackLyricsOffsetMs != 0 {
                offset.addItem(.separator())
                offset.addItem(action(L10n.t("重置"), symbol: "arrow.counterclockwise",
                                      selector: #selector(resetOffset)))
            }
            menu.addItem(submenu(offsetMenuTitle, symbol: "timer", menu: offset))
        }

        menu.addItem(.separator())
        menu.addItem(action(L10n.t("设置…"), symbol: "gearshape",
                            selector: #selector(openSettings)))
        menu.addItem(action(L10n.t("歌词管理…"), symbol: "music.note.list",
                            selector: #selector(openLyricsManager)))
        // 「歌词窗口」跟上面两项各自单成一组:上面是"配置/管理"(改设置、整理歌词库),
        // 它是"看歌词"本身 —— 手上正在做的事不一样,不该看起来像同一串。
        menu.addItem(.separator())
        menu.addItem(action(L10n.t("歌词窗口…"), symbol: "text.quote",
                            selector: #selector(openLyricsWindow)))
        // 再一条分隔线,把上面"打开某个窗口做配置/管理"这几项,跟下面"检查更新/关于"
        // 这类"了解一下这个 App 本身"的入口分开(2026-07-30 用户反馈原来四项挤在一起看着乱)。
        menu.addItem(.separator())
        menu.addItem(action(L10n.t("检查更新…"), symbol: "arrow.triangle.2.circlepath",
                            selector: #selector(checkForUpdates)))
        // 引导可以重来:走完的人后来想重新配一遍(换了播放器、服务被自己关掉了、想重新
        // 给权限)也得有入口。
        menu.addItem(action(L10n.t("重新运行引导…"), symbol: "sparkles",
                            selector: #selector(rerunOnboarding)))
        menu.addItem(action(L10n.t("关于 Lyrimuse"), symbol: "info.circle",
                            selector: #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(action(L10n.t("退出 Lyrimuse"),
                            symbol: "rectangle.portrait.and.arrow.right",
                            selector: #selector(quit)))
    }

    // MARK: - 菜单项工厂

    private func makeItem(_ title: String, symbol: String, selector: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            // 菜单项图标按 14pt 排,跟系统自带菜单里的 SF Symbol 一个量级;不写死
            // size(那样会把非正方形的符号压变形)。
            item.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) ?? image
        }
        return item
    }

    private func action(_ title: String, symbol: String, selector: Selector) -> NSMenuItem {
        makeItem(title, symbol: symbol, selector: selector)
    }

    private func toggle(_ title: String, symbol: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = makeItem(title, symbol: symbol, selector: action)
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, symbol: String, menu: NSMenu) -> NSMenuItem {
        // 带子菜单的项本身不响应点击,selector 给 nil。
        let item = makeItem(title, symbol: symbol, selector: nil)
        item.submenu = menu
        return item
    }

    private func nudgeTitle(_ verb: String) -> String {
        let step = AppSettings.shared.lyricsOffsetStepMs
        return "\(verb) \(AppSettings.formattedSeconds(ms: step))\(L10n.t("秒"))"
    }

    // 菜单标题里直接带上当前校准值(比如"歌词时间轴(+0.6s)"),不用另开一个 HUD 或者
    // 禁用态文字行专门显示这个数字。
    private var offsetMenuTitle: String {
        // 只显示**这首歌**那部分,不含全局基准(2026-08-17 加全局偏移时改)。显示总和的
        // 话,用户看到"歌词时间轴(+0.8s)"、点了下面的「重置」却只回到 +0.5s(全局基准
        // 还在),数字跟操作对不上。全局基准在设置里调,也在那里显示。
        let ms = PlaybackCoordinator.shared.trackLyricsOffsetMs
        guard ms != 0 else { return L10n.t("歌词时间轴") }
        // 跟两个按钮共用同一份格式化(AppSettings.formattedSeconds)——不然步长设成
        // 比如 0.15s 时,按钮显示"0.15"、这里的累计值却按 %.1f 四舍五入成"0.2"。
        let sign = ms > 0 ? "+" : ""
        return "\(L10n.t("歌词时间轴"))(\(sign)\(AppSettings.formattedSeconds(ms: ms))s)"
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

    @objc private func nudgeEarlier() {
        PlaybackCoordinator.shared.nudgeLyricsOffset(by: AppSettings.shared.lyricsOffsetStepMs)
    }

    @objc private func nudgeLater() {
        PlaybackCoordinator.shared.nudgeLyricsOffset(by: -AppSettings.shared.lyricsOffsetStepMs)
    }

    @objc private func resetOffset() {
        PlaybackCoordinator.shared.resetLyricsOffset()
    }

    // 下面几个"打开某扇窗"的动作都走 AppActions —— 那几个闭包里已经带了
    // NSApp.activate(ignoringOtherApps:),.accessory 策略(没有 Dock 图标)下少了这一步
    // 窗口打不开(见 MenuBarSceneActions 里注册处的注释)。
    @objc private func openSettings() { AppActions.shared.openSettings?() }
    @objc private func openLyricsManager() { AppActions.shared.openLyricsManager?() }
    @objc private func openLyricsWindow() { AppActions.shared.openLyricsWindow?() }
    @objc private func rerunOnboarding() { AppActions.shared.openOnboarding?() }

    @objc private func openAbout() {
        // 直接跳到设置窗口的"关于"分类,复用 Onboarding 的 Last.fm 步骤已经在用的同一套
        // 一次性信箱(AppActions.pendingSettingsSelection),不用再点一次侧边栏。
        AppActions.shared.requestSettings(.tab(.about))
        AppActions.shared.openSettings?()
    }

    @objc private func checkForUpdates() {
        // 跟"设置…"同一个坑:.accessory 策略下 Sparkle 弹出的检查更新 UI 也得先手动激活
        // App,不然点了没反应(这里没有活跃窗口打底,不像"关于"页那个按钮 —— 那边是在
        // 已经打开的设置窗口里点,App 早就是激活状态)。
        NSApp.activate(ignoringOtherApps: true)
        SparkleUpdaterManager.shared.checkForUpdates()
    }

    @objc private func quit() {
        // 经 AppExit 登记原因再终止(2026-09-03):所有主动退出都从那一个出口走,见 AppExit 头注。
        AppExit.request(.menuQuit)
    }
}
