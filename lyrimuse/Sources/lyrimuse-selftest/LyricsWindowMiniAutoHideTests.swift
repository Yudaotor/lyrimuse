import Foundation
import LyrimuseCore

/// 迷你窗「暂停时隐藏」「纯音乐/无歌词时隐藏」「广告时隐藏」「全屏时隐藏」「截屏时隐藏」(07 章决策 142、190、209):
/// 判据、翻转动作、接线。
func checkLyricsWindowMiniAutoHide() {
    print("\n== 迷你窗暂停 / 无歌词 / 广告 / 全屏 / 截屏时隐藏 ==")
    typealias H = LyricsWindowMiniAutoHide
    func hides(_ pausedOn: Bool, playing: Bool, _ fullOn: Bool, covered: Bool,
               noLyricsOn: Bool = false, lacks: Bool = false, adsOn: Bool = false, ad: Bool = false) -> Bool {
        H.hides(hideWhenNotPlaying: pausedOn, isPlaying: playing, hideWhenNoLyrics: noLyricsOn, lacksLyrics: lacks,
                hideDuringAds: adsOn, isAdBreak: ad, hideInFullScreen: fullOn, coveredByFullScreen: covered)
    }
    expectEqual(hides(false, playing: false, false, covered: true), false, "迷你自动隐藏: 两项都关,暂停、全屏都不藏")
    expectEqual(hides(true, playing: false, false, covered: false), true, "迷你自动隐藏: 开着暂停时隐藏,没在播就藏")
    expectEqual(hides(true, playing: true, false, covered: false), false, "迷你自动隐藏: 开着暂停时隐藏,在播不藏")
    expectEqual(hides(false, playing: true, true, covered: true), true, "迷你自动隐藏: 开着全屏时隐藏,所在屏全屏就藏")
    expectEqual(hides(false, playing: true, true, covered: false), false, "迷你自动隐藏: 开着全屏时隐藏,所在屏不是全屏不藏")
    expectEqual(hides(true, playing: true, true, covered: true), true, "迷你自动隐藏: 在播但全屏,照样藏")
    expectEqual(hides(false, playing: true, false, covered: false, noLyricsOn: true, lacks: true), true,
                "迷你自动隐藏: 开着无歌词时隐藏,这首没词就藏")
    expectEqual(hides(false, playing: true, false, covered: false, noLyricsOn: true, lacks: false), false,
                "迷你自动隐藏: 开着无歌词时隐藏,有词(或还在搜)不藏")
    expectEqual(hides(false, playing: true, false, covered: false, noLyricsOn: false, lacks: true), false,
                "迷你自动隐藏: 无歌词时隐藏关着,没词也不藏")
    expectEqual(hides(false, playing: true, false, covered: false, adsOn: true, ad: true), true,
                "迷你自动隐藏: 开着广告时隐藏,在放广告就藏")
    expectEqual(hides(false, playing: true, false, covered: false, adsOn: true, ad: false), false,
                "迷你自动隐藏: 开着广告时隐藏,放的是歌不藏")
    expectEqual(hides(false, playing: true, false, covered: false, adsOn: false, ad: true), false,
                "迷你自动隐藏: 广告时隐藏关着,放广告也不藏")
    expectEqual(hides(true, playing: false, false, covered: false, adsOn: true, ad: true), true,
                "迷你自动隐藏: 广告暂停着,两条规则任一成立就藏")

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
    let morph = source("lyrimuse/UI/LyricsWindowFormMorph.swift")
    let debugLinks = source("lyrimuse/Settings/DebugDeepLinks.swift")

    expectEqual(sourceHas(autoHide, "$isPlayingSmoothed.removeDuplicates()\n            .sink { [weak self] in self?.isPlaying = $0;")
                && sourceHas(autoHide, "$fullScreenDisplays.removeDuplicates()\n            .sink { [weak self] in self?.fullScreenDisplays = $0;")
                && sourceHas(autoHide, "$lyricsWindowMiniHideWhenNotPlaying.removeDuplicates()\n            .sink { [weak self] in self?.hideWhenNotPlaying = $0;")
                && sourceHas(autoHide, "$lyricsWindowMiniHideInFullScreen.removeDuplicates()\n            .sink { [weak self] in self?.hideInFullScreen = $0;")
                && sourceHas(autoHide, "$currentTrackLacksLyrics.removeDuplicates()\n            .sink { [weak self] in self?.lacksLyrics = $0;")
                && sourceHas(autoHide, "$lyricsWindowMiniHideWhenNoLyrics.removeDuplicates()\n            .sink { [weak self] in self?.hideWhenNoLyrics = $0;")
                && sourceHas(autoHide, "$isCurrentTrackAdBreak.removeDuplicates()\n            .sink { [weak self] in self?.isAdBreak = $0;")
                && sourceHas(autoHide, "$lyricsWindowMiniHideDuringAds.removeDuplicates()\n            .sink { [weak self] in self?.hideDuringAds = $0;"),
                true, "迷你自动隐藏: 八路订阅都用发布出来的值(订阅回调里回读属性是旧值)")
    expectEqual(sourceHas(autoHide, "hideDuringAds: hideDuringAds, isAdBreak: isAdBreak,"), true,
                "迷你自动隐藏: 判据带上广告那一项")
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
    expectEqual(sourceHas(panel, "if atLaunch, LyricsMiniPanelAutoHide.shared.holdAtLaunch() { return }\n"
                            + "        LyricsMiniPanelAutoHide.shared.panelShownByUser()\n        panel.orderFrontRegardless()"),
                true, "迷你自动隐藏: 用户打开照常摆出来;启动重开规则要藏就只建不上屏")
    expectEqual(sourceBytes(panel, contain: "LyricsMiniPanelAutoHide.shared.attach(panel)")
                && sourceHas(panel, "guard let panel, !panel.isVisible else { return }\n        LyricsMiniPanelAutoHide.shared.detach()"),
                true, "迷你自动隐藏: 面板建出来接上、放掉时解开")
    // 截屏时隐藏(照灵动岛 NotchTests 那条):建窗即按设置写、之后每次直接写、不判等;关着回到面板默认的 .readOnly。
    let makeBody = sourceBody("static func make(frame: NSRect) -> LyricsMiniPanel {", in: panel)
    expectEqual(sourceHas(makeBody, "captureHideObserver = AppSettings.shared.$lyricsWindowMiniHideDuringScreenCapture\n"
                            + " .sink { [weak panel] hide in panel?.sharingType = hide ? .none : .readOnly }"), true,
                "迷你截屏时隐藏: 建面板时订阅开关,订阅那一下就按当前值写 sharingType")
    expectEqual(!panel.contains("sharingType != ") && !panel.contains("sharingType == ")
                && !sourceHas(panel, "$lyricsWindowMiniHideDuringScreenCapture\n .dropFirst()")
                && !sourceHas(panel, "$lyricsWindowMiniHideDuringScreenCapture\n .removeDuplicates()"), true,
                "迷你截屏时隐藏: 直接写 sharingType、不判等、不去重(运行中读回来的值不可靠)")
    expectEqual(sourceHas(sourceBody("private static func release() {", in: panel), "captureHideObserver = nil"), true,
                "迷你截屏时隐藏: 放掉面板时一起放掉订阅")
    expectEqual(sourceHas(sourceBody("static func canAnimate(_ window: NSWindow, to target: NSRect) -> Bool {", in: morph),
                          "return !AppSettings.shared.lyricsWindowMiniHideDuringScreenCapture\n &&"), true,
                "迷你截屏时隐藏: 开着时进出迷你不做变形动画(面板截出来是空白)")
    expectEqual(sourceHas(debugLinks, "if let mini { AppSettings.shared.lyricsWindowMiniHideDuringScreenCapture = mini }")
                && sourceHas(debugLinks, "if let mini { AppSettings.shared.lyricsWindowMiniHideDuringAds = mini }"), true,
                "迷你截屏 / 广告时隐藏: debug 深链写同一个设置")
    expectEqual(sourceBytes(sceneActions, contain: "LyricsMiniPanelHost.show(atLaunch: true)"), true,
                "迷你自动隐藏: 启动重开走 atLaunch")
    expectEqual(sourceHas(restorer, "onScreen: LyricsMiniPanelAutoHide.shared.isHoldingPanel\n                ||"), true,
                "迷你自动隐藏: 启动重开把藏着的面板算作已上屏,不重试")
    expectEqual(sourceHas(window, "LyricsMiniPanelHost.closeHeldPanel()\n            openScene()"), true,
                "迷你自动隐藏: 藏着时要开完整尺寸,先关掉藏着的面板")

    expectEqual(sourceHas(appSettings, "lyricsWindowMiniHideWhenNotPlaying =\n            (defaults.object(forKey: Keys.lyricsWindowMiniHideWhenNotPlaying) as? Bool) ?? false")
                && sourceHas(appSettings, "lyricsWindowMiniHideInFullScreen =\n            (defaults.object(forKey: Keys.lyricsWindowMiniHideInFullScreen) as? Bool) ?? false")
                && sourceHas(appSettings, "lyricsWindowMiniHideWhenNoLyrics =\n            (defaults.object(forKey: Keys.lyricsWindowMiniHideWhenNoLyrics) as? Bool) ?? false")
                && sourceHas(appSettings, "lyricsWindowMiniHideDuringScreenCapture =\n (defaults.object(forKey: Keys.lyricsWindowMiniHideDuringScreenCapture) as? Bool) ?? false")
                && sourceHas(appSettings, "lyricsWindowMiniHideDuringAds =\n (defaults.object(forKey: Keys.lyricsWindowMiniHideDuringAds) as? Bool) ?? false"),
                true, "迷你自动隐藏: 五项默认关(截屏、广告同悬浮歌词那两颗)")
    expectEqual(sourceHas(appSettings, "static let lyricsWindowMiniHideDuringScreenCapture = \"np:lyricsWindowMiniHideDuringScreenCapture\"")
                && sourceHas(appSettings, "static let lyricsWindowMiniHideDuringAds = \"np:lyricsWindowMiniHideDuringAds\"")
                && sourceHas(appSettings, "didSet { defaults.set(lyricsWindowMiniHideDuringScreenCapture, forKey: Keys.lyricsWindowMiniHideDuringScreenCapture) }")
                && sourceHas(appSettings, "didSet { defaults.set(lyricsWindowMiniHideDuringAds, forKey: Keys.lyricsWindowMiniHideDuringAds) }"),
                true, "迷你截屏 / 广告时隐藏: 各存一个 np: 键,改了就写回")
    expectEqual(sourceBytes(settingsView, contain: "isOn: $settings.lyricsWindowMiniHideWhenNotPlaying)")
                && sourceBytes(settingsView, contain: "isOn: $settings.lyricsWindowMiniHideInFullScreen)")
                && sourceBytes(settingsView, contain: "isOn: $settings.lyricsWindowMiniHideWhenNoLyrics)")
                && sourceBytes(settingsView, contain: "isOn: $settings.lyricsWindowMiniHideDuringScreenCapture)")
                && sourceBytes(settingsView, contain: "isOn: $settings.lyricsWindowMiniHideDuringAds)"), true,
                "迷你自动隐藏: 设置页迷你「行为」摆这五颗开关")
    expectEqual(sourceBytes(settingsView, contain: "(title: L10n.t(\"暂停时隐藏\"), isOn: settings.lyricsWindowMiniHideWhenNotPlaying)")
                && sourceBytes(settingsView, contain: "(title: L10n.t(\"全屏时隐藏\"), isOn: settings.lyricsWindowMiniHideInFullScreen)")
                && sourceBytes(settingsView, contain: "(title: L10n.t(\"纯音乐/无歌词时隐藏\"), isOn: settings.lyricsWindowMiniHideWhenNoLyrics)")
                && sourceBytes(settingsView, contain: "(title: L10n.t(\"截屏时隐藏\"), isOn: settings.lyricsWindowMiniHideDuringScreenCapture)")
                && sourceBytes(settingsView, contain: "(title: L10n.t(\"广告时隐藏\"), isOn: settings.lyricsWindowMiniHideDuringAds)"),
                true, "迷你自动隐藏: 「行为」按钮摘要算这五项")
    expectEqual(sourceBytes(settingsView, contain: "s.lyricsWindowMiniHideWhenNotPlaying = false")
                && sourceBytes(settingsView, contain: "s.lyricsWindowMiniHideInFullScreen = false")
                && sourceBytes(settingsView, contain: "s.lyricsWindowMiniHideWhenNoLyrics = false")
                && sourceBytes(settingsView, contain: "s.lyricsWindowMiniHideDuringScreenCapture = false")
                && sourceBytes(settingsView, contain: "s.lyricsWindowMiniHideDuringAds = false"), true,
                "迷你自动隐藏: 迷你「重置」恢复成关")
    expectEqual(SettingsSearchCatalog.lyricsWindowMiniOnlyTitles.isSuperset(of: ["截屏时隐藏", "暂停时隐藏", "纯音乐/无歌词时隐藏",
                                                                                "广告时隐藏", "全屏时隐藏"]), true,
                "迷你自动隐藏: 搜索目录标成只在迷你有")
}
