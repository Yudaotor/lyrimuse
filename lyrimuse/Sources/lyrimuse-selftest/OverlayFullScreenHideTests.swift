import Foundation
import LyrimuseCore

/// 悬浮歌词「全屏时隐藏」(见 04 章决策 65):显示判定、全屏判据、接线。
func checkOverlayFullScreenHide() {
    print("\n== 悬浮歌词全屏时隐藏 ==")
    typealias V = OverlayVisibility
    func show(visible: Bool = true, noLyrics: Bool = false, covered: Bool = false,
              pausedOn: Bool = false, playing: Bool = true) -> Bool {
        V.shouldShow(isVisible: visible, hiddenForNoLyrics: noLyrics, coveredByFullScreen: covered,
                     hideWhenNotPlaying: pausedOn, isPlaying: playing)
    }
    expectEqual(show(), true, "悬浮歌词显示: 开着、在播、没被任何规则藏 → 显示")
    expectEqual(show(visible: false), false, "悬浮歌词显示: 用户关掉了 → 不显示")
    expectEqual(show(noLyrics: true), false, "悬浮歌词显示: 无歌词时隐藏生效 → 不显示")
    expectEqual(show(covered: true), false, "悬浮歌词显示: 全屏时隐藏生效 → 不显示")
    expectEqual(show(pausedOn: true, playing: false), false, "悬浮歌词显示: 开着暂停时隐藏、没在播 → 不显示")
    expectEqual(show(pausedOn: false, playing: false), true, "悬浮歌词显示: 没开暂停时隐藏、没在播 → 照常显示")
    expectEqual(show(covered: true, pausedOn: true, playing: true), false, "悬浮歌词显示: 在播但全屏,照样藏")

    expectEqual(V.fullScreenHides(enabled: false, coveredByFullScreenApp: true), false, "悬浮歌词全屏时隐藏: 开关关着,全屏也不藏")
    expectEqual(V.fullScreenHides(enabled: true, coveredByFullScreenApp: true), true, "悬浮歌词全屏时隐藏: 开着、所在屏全屏就藏")
    expectEqual(V.fullScreenHides(enabled: true, coveredByFullScreenApp: false), false, "悬浮歌词全屏时隐藏: 开着、所在屏不是全屏不藏")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let controller = source("lyrimuse/UI/LyricsOverlayWindowController.swift")
    let rows = source("lyrimuse/UI/OverlayBehaviorSettingsRows.swift")
    let stage = source("lyrimuse/UI/OverlayEditorStage.swift")
    let appSettings = source("lyrimuse/Settings/AppSettings.swift")

    expectEqual(sourceBytes(controller, contain: "AppSettings.shared.$overlayHideInFullScreen\n            .combineLatest(FullScreenSpaceMonitor.shared.$fullScreenDisplays)"),
                true, "悬浮歌词全屏时隐藏: 控制器订阅开关 + 全屏表,两路都从 sink 参数拿")
    expectEqual(sourceBytes(controller, contain: "forName: NSWindow.didChangeScreenNotification, object: window, queue: .main"),
                true, "悬浮歌词全屏时隐藏: 窗口换屏时重算")
    expectEqual(sourceBytes(controller, contain: "let shouldShow = OverlayVisibility.shouldShow(isVisible: isVisible, hiddenForNoLyrics: hiddenForNoLyrics,\n                                                      coveredByFullScreen: coveredByFullScreen,"),
                true, "悬浮歌词全屏时隐藏: 显示判定走 Core,带上全屏那一项")
    expectEqual(sourceBytes(appSettings, contain: "overlayHideInFullScreen = (defaults.object(forKey: Keys.overlayHideInFullScreen) as? Bool) ?? false"),
                true, "悬浮歌词全屏时隐藏: 默认关")
    expectEqual(sourceBytes(rows, contain: "ForEach(OverlayBehaviorItem.allCases.filter(\\.isAutoHide))"),
                true, "悬浮歌词全屏时隐藏: 开关画在「自动隐藏」那一格")
    expectEqual(sourceBytes(stage, contain: "+ OverlayBehaviorItem.allCases.filter(\\.isAutoHide).map"),
                true, "悬浮歌词全屏时隐藏: 编辑台「行为」摘要把它算进去")
    expectEqual(SettingsSearchCatalog.entries.contains { $0.sectionValue == "overlay" && $0.titleKey == "全屏时隐藏" },
                true, "悬浮歌词全屏时隐藏: 设置搜索能搜到")
}
