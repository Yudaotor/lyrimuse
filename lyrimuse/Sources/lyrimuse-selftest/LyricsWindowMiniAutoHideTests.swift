import Foundation
import LyrimuseCore

/// 迷你窗「暂停时隐藏」「全屏时隐藏」(07 章决策 142):判据、翻转动作、接线。
func checkLyricsWindowMiniAutoHide() {
    print("\n== 迷你窗暂停 / 全屏时隐藏 ==")
    typealias H = LyricsWindowMiniAutoHide
    func hides(_ pausedOn: Bool, playing: Bool, _ fullOn: Bool, covered: Bool) -> Bool {
        H.hides(hideWhenNotPlaying: pausedOn, isPlaying: playing, hideInFullScreen: fullOn, coveredByFullScreen: covered)
    }
    expectEqual(hides(false, playing: false, false, covered: true), false, "迷你自动隐藏: 两项都关,暂停、全屏都不藏")
    expectEqual(hides(true, playing: false, false, covered: false), true, "迷你自动隐藏: 开着暂停时隐藏,没在播就藏")
    expectEqual(hides(true, playing: true, false, covered: false), false, "迷你自动隐藏: 开着暂停时隐藏,在播不藏")
    expectEqual(hides(false, playing: true, true, covered: true), true, "迷你自动隐藏: 开着全屏时隐藏,所在屏全屏就藏")
    expectEqual(hides(false, playing: true, true, covered: false), false, "迷你自动隐藏: 开着全屏时隐藏,所在屏不是全屏不藏")
    expectEqual(hides(true, playing: true, true, covered: true), true, "迷你自动隐藏: 在播但全屏,照样藏")

    expectEqual(H.action(hides: true, panelVisible: true, hiddenByRule: false), .hide, "迷你自动隐藏: 要藏、在屏上就藏")
    expectEqual(H.action(hides: true, panelVisible: false, hiddenByRule: false), H.Action.none,
                "迷你自动隐藏: 要藏、本来就不在屏上(最小化)不动")
    expectEqual(H.action(hides: false, panelVisible: false, hiddenByRule: true), .show, "迷你自动隐藏: 不藏了,摆回自己藏起来的那扇")
    expectEqual(H.action(hides: false, panelVisible: false, hiddenByRule: false), H.Action.none,
                "迷你自动隐藏: 不藏了,不是自己藏的(最小化)不摆出来")
    expectEqual(H.action(hides: false, panelVisible: true, hiddenByRule: true), H.Action.none,
                "迷你自动隐藏: 不藏了,已经在屏上不动")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let autoHide = source("lyrimuse/UI/LyricsMiniPanelAutoHide.swift")
    let panel = source("lyrimuse/UI/LyricsMiniPanel.swift")
    let window = source("lyrimuse/UI/LyricsWindowView.swift")
    let restorer = source("lyrimuse/UI/LyricsWindowLaunchRestorer.swift")
    let sceneActions = source("lyrimuse/MenuBar/MenuBarSceneActions.swift")
    let appSettings = source("lyrimuse/Settings/AppSettings.swift")
    let settingsView = source("lyrimuse/SettingsView.swift")

    expectEqual(sourceBytes(autoHide, contain: "$isPlayingSmoothed.removeDuplicates()\n            .sink { [weak self] in self?.isPlaying = $0;")
                && sourceBytes(autoHide, contain: "$fullScreenDisplays.removeDuplicates()\n            .sink { [weak self] in self?.fullScreenDisplays = $0;")
                && sourceBytes(autoHide, contain: "$lyricsWindowMiniHideWhenNotPlaying.removeDuplicates()\n            .sink { [weak self] in self?.hideWhenNotPlaying = $0;")
                && sourceBytes(autoHide, contain: "$lyricsWindowMiniHideInFullScreen.removeDuplicates()\n            .sink { [weak self] in self?.hideInFullScreen = $0;"),
                true, "迷你自动隐藏: 四路订阅都用发布出来的值(订阅回调里回读属性是旧值)")
    expectEqual(sourceBytes(autoHide, contain: "fullScreenDisplays: fullScreenDisplays)")
                && !sourceBytes(autoHide, contain: "FullScreenSpaceMonitor.shared.fullScreenDisplays")
                && !sourceBytes(autoHide, contain: "FullScreenSpaceMonitor.shared.covers("), true,
                "迷你自动隐藏: 全屏表用订阅收下的那份")
    expectEqual(sourceBytes(autoHide, contain: "guard now != hides else { return }"), true,
                "迷你自动隐藏: 只在判据翻转那一拍动手,用户打开的窗口不被当场收回")
    expectEqual(sourceBytes(autoHide, contain: "panel.orderOut(nil)") && !sourceBytes(autoHide, contain: ".close()"), true,
                "迷你自动隐藏: 藏用 orderOut、不 close,「开着」照旧记着")
    expectEqual(sourceBytes(autoHide, contain: "forName: NSWindow.didChangeScreenNotification, object: panel"), true,
                "迷你自动隐藏: 面板换屏重算全屏")
    expectEqual(sourceBytes(panel, contain: "if atLaunch, LyricsMiniPanelAutoHide.shared.holdAtLaunch() { return }\n"
                            + "        LyricsMiniPanelAutoHide.shared.panelShownByUser()\n        panel.orderFrontRegardless()"),
                true, "迷你自动隐藏: 用户打开照常摆出来;启动重开规则要藏就只建不上屏")
    expectEqual(sourceBytes(panel, contain: "LyricsMiniPanelAutoHide.shared.attach(panel)")
                && sourceBytes(panel, contain: "guard let panel, !panel.isVisible else { return }\n        LyricsMiniPanelAutoHide.shared.detach()"),
                true, "迷你自动隐藏: 面板建出来接上、放掉时解开")
    expectEqual(sourceBytes(sceneActions, contain: "LyricsMiniPanelHost.show(atLaunch: true)"), true,
                "迷你自动隐藏: 启动重开走 atLaunch")
    expectEqual(sourceBytes(restorer, contain: "onScreen: LyricsMiniPanelAutoHide.shared.isHoldingPanel\n                ||"), true,
                "迷你自动隐藏: 启动重开把藏着的面板算作已上屏,不重试")
    expectEqual(sourceBytes(window, contain: "LyricsMiniPanelHost.closeHeldPanel()\n            openScene()"), true,
                "迷你自动隐藏: 藏着时要开完整尺寸,先关掉藏着的面板")

    expectEqual(sourceBytes(appSettings, contain: "lyricsWindowMiniHideWhenNotPlaying =\n            (defaults.object(forKey: Keys.lyricsWindowMiniHideWhenNotPlaying) as? Bool) ?? false")
                && sourceBytes(appSettings, contain: "lyricsWindowMiniHideInFullScreen =\n            (defaults.object(forKey: Keys.lyricsWindowMiniHideInFullScreen) as? Bool) ?? false"),
                true, "迷你自动隐藏: 两项默认关")
    expectEqual(sourceBytes(settingsView, contain: "Toggle(\"\", isOn: $settings.lyricsWindowMiniHideWhenNotPlaying)")
                && sourceBytes(settingsView, contain: "Toggle(\"\", isOn: $settings.lyricsWindowMiniHideInFullScreen)"), true,
                "迷你自动隐藏: 设置页迷你「行为」摆这两颗开关")
    expectEqual(sourceBytes(settingsView, contain: "(title: L10n.t(\"暂停时隐藏\"), isOn: settings.lyricsWindowMiniHideWhenNotPlaying)")
                && sourceBytes(settingsView, contain: "(title: L10n.t(\"全屏时隐藏\"), isOn: settings.lyricsWindowMiniHideInFullScreen)"),
                true, "迷你自动隐藏: 「行为」按钮摘要算这两项")
    expectEqual(sourceBytes(settingsView, contain: "s.lyricsWindowMiniHideWhenNotPlaying = false")
                && sourceBytes(settingsView, contain: "s.lyricsWindowMiniHideInFullScreen = false"), true,
                "迷你自动隐藏: 迷你「重置」恢复成关")
    expectEqual(SettingsSearchCatalog.lyricsWindowMiniOnlyTitles.isSuperset(of: ["暂停时隐藏", "全屏时隐藏"]), true,
                "迷你自动隐藏: 搜索目录标成只在迷你有")
}
