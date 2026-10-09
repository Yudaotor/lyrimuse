import Foundation
import LyrimuseCore

/// 启动时开哪些窗口(14 章决策 62):静默启动一扇都不开,没走完的引导照弹。
private func checkLaunchWindowPlan() {
    typealias P = LaunchWindowPlan
    for launching in [false, true] {
        for requested in [false, true] {
            expectEqual(P.dropsSettingsWindow(launching: launching, requested: requested), launching && !requested,
                        "启动时开窗: 设置窗口在启动流程里、没人要过时关掉,跟静默启动无关(启动中 \(launching) 要过 \(requested))")
        }
    }
    let reopen = P(silentLaunch: false, hasCompletedOnboarding: true, lyricsWindowWasOpen: true)
    expectEqual([reopen.showsOnboarding, reopen.reopensLyricsWindow, reopen.forgetsOpenLyricsWindow], [false, true, false],
                "启动时开窗: 没开静默启动、上次开着,照原样重开歌词窗口")
    let silent = P(silentLaunch: true, hasCompletedOnboarding: true, lyricsWindowWasOpen: true)
    expectEqual([silent.showsOnboarding, silent.reopensLyricsWindow, silent.forgetsOpenLyricsWindow], [false, false, true],
                "启动时开窗: 静默启动不重开,把「开着」记成没开")
    let silentClosed = P(silentLaunch: true, hasCompletedOnboarding: true, lyricsWindowWasOpen: false)
    expectEqual([silentClosed.showsOnboarding, silentClosed.reopensLyricsWindow, silentClosed.forgetsOpenLyricsWindow],
                [false, false, false], "启动时开窗: 静默启动、上次没开,什么都不做")
    let closed = P(silentLaunch: false, hasCompletedOnboarding: true, lyricsWindowWasOpen: false)
    expectEqual([closed.showsOnboarding, closed.reopensLyricsWindow, closed.forgetsOpenLyricsWindow], [false, false, false],
                "启动时开窗: 上次没开就不开")
    for silentLaunch in [false, true] {
        let setup = P(silentLaunch: silentLaunch, hasCompletedOnboarding: false, lyricsWindowWasOpen: true)
        expectEqual([setup.showsOnboarding, setup.reopensLyricsWindow, setup.forgetsOpenLyricsWindow], [true, false, false],
                    "启动时开窗: 引导没走完照弹引导、不开歌词窗口(静默启动 \(silentLaunch))")
    }
}

/// 启动重开歌词窗口(07 章决策 124):开了核对、没上屏再开的状态机,以及 App 侧接线。
func checkLyricsWindowLaunchRestore() {
    print("\n== 歌词窗口启动重开 ==")
    checkLaunchWindowPlan()
    typealias R = LyricsWindowLaunchRestore
    let hidden = R.Probe(onScreen: false, stillWanted: true)
    let shown = R.Probe(onScreen: true, stillWanted: true)
    let closed = R.Probe(onScreen: false, stillWanted: false)
    /// 按给定的核对结果一步步问,走到结局为止。
    func walk(_ probes: [R.Probe]) -> [R.Step] {
        var restore = R()
        var steps: [R.Step] = []
        for probe in probes {
            let step = restore.next(probe)
            steps.append(step)
            if case .finish = step { break }
        }
        return steps
    }
    expectEqual(walk([hidden, shown]), [.open(checkAfter: 1.5), .finish(.restored(attempts: 1))],
                "启动重开: 第一次就上屏,开一次就停")
    expectEqual(walk([hidden, hidden, hidden, shown]),
                [.open(checkAfter: 1.5), .open(checkAfter: 3), .open(checkAfter: 5), .finish(.restored(attempts: 3))],
                "启动重开: 第三次才上屏")
    expectEqual(walk(Array(repeating: hidden, count: 6)),
                [.open(checkAfter: 1.5), .open(checkAfter: 3), .open(checkAfter: 5), .open(checkAfter: 2),
                 .finish(.gaveUp(attempts: 4))],
                "启动重开: 一直不上屏,开 4 次后放弃")
    expectEqual(walk([hidden, closed]), [.open(checkAfter: 1.5), .finish(.stopped(attempts: 1))],
                "启动重开: 开过一次后用户关了窗(或 App 在退出)就不再开")
    expectEqual(walk([shown]), [.finish(.restored(attempts: 0))], "启动重开: 开之前窗口已经在屏上,一次都不开")
    expectEqual(walk([closed]), [.finish(.stopped(attempts: 0))], "启动重开: 开之前就不该开了,一次都不开")
    expectEqual(walk([hidden, R.Probe(onScreen: true, stillWanted: false)]),
                [.open(checkAfter: 1.5), .finish(.restored(attempts: 1))], "启动重开: 上屏优先于还该不该开")
    let total = R.firstDelay + R.checkDelays.reduce(0, +)
    expectEqual(total <= 15, true, "启动重开: 前后不超过 15 秒(实际 \(total))")
    expectEqual(R.firstDelay, 0.5, "启动重开: 首开等 0.5 秒,同引导")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let actions = source("lyrimuse/MenuBar/MenuBarSceneActions.swift")
    let restorer = source("lyrimuse/UI/LyricsWindowLaunchRestorer.swift")
    let window = source("lyrimuse/UI/LyricsWindowView.swift")
    expectEqual(sourceBytes(actions, contain: "let plan = LaunchWindowPlan(silentLaunch: settings.silentLaunch,\n"
                            + "                                            hasCompletedOnboarding: settings.hasCompletedOnboarding,\n"
                            + "                                            lyricsWindowWasOpen: LyricsWindowSession.shouldReopenAtLaunch)\n"
                            + "                if plan.reopensLyricsWindow {\n"
                            + "                    // 上次是迷你就直接开面板(不开场景,07 章决策 133)。\n"
                            + "                    LyricsWindowLaunchRestorer.start {\n"
                            + "                        if UserDefaults.standard.bool(forKey: LyricsWindowSession.miniModeKey) {\n"
                            + "                            LyricsMiniPanelHost.show(atLaunch: true)\n"
                            + "                        } else {\n"
                            + "                            LyricsWindowSession.markRestoringAtLaunch()\n"
                            + "                            openWindowAction(id: \"lyrics-window\")\n"
                            + "                        }\n"
                            + "                    }\n"
                            + "                } else if plan.forgetsOpenLyricsWindow {\n"
                            + "                    LyricsWindowSession.forgetOpen()\n"
                            + "                }\n"
                            + "                if plan.showsOnboarding {"),
                true, "启动重开: 照 LaunchWindowPlan 办(引导走完、上次开着、没开静默启动才重开;静默启动时把「开着」记成没开),开窗走不激活 App 的那条(决策 123)")
    expectEqual(sourceBytes(actions, contain: "if !settings.hasCompletedOnboarding {"), false,
                "启动时开窗: 引导也照 LaunchWindowPlan 判,不另写一份条件")
    expectEqual(sourceBytes(window, contain: "static func forgetOpen() { UserDefaults.standard.set(false, forKey: openKey) }"), true,
                "静默启动: 没重开时把「开着」记成没开")
    let delegate = source("lyrimuse/AppDelegate.swift")
    let settingsView = source("lyrimuse/SettingsView.swift")
    expectEqual(sourceBytes(delegate, contain: "_ = SparkleUpdaterManager.shared\n"
                            + "        // 放到下一拍:启动流程里排在这之后的窗口(SwiftUI 默认开的设置窗口)也还算启动阶段。\n"
                            + "        DispatchQueue.main.async { LaunchPhase.finish() }\n    }"),
                true, "静默启动: applicationDidFinishLaunching 末尾的下一拍才算启动流程走完")
    expectEqual(sourceBytes(actions, contain: "static func presentSettings(fallback: () -> Void) {\n        LaunchPhase.settingsRequested = true\n"),
                true, "静默启动: 菜单、快捷键、深链要设置窗口时记一笔,那扇不关")
    expectEqual(sourceBytes(settingsView, contain: "if LaunchWindowPlan.dropsSettingsWindow(launching: LaunchPhase.isLaunching,\n"
                            + "                                                    requested: LaunchPhase.settingsRequested) {\n"
                            + "                window.alphaValue = 0\n"
                            + "                DispatchQueue.main.async {\n"
                            + "                    window.close()\n"
                            + "                    window.alphaValue = 1\n"
                            + "                }\n"
                            + "            }"),
                true, "启动时开窗: SwiftUI 默认开的设置窗口先透明、下一拍关掉,关完还原透明度")
    let settings = source("lyrimuse/Settings/AppSettings.swift")
    expectEqual(sourceBytes(settings, contain: "defaults.set(silentLaunch, forKey: Keys.silentLaunch)\n"
                            + "            // 打开时顺带关掉「在 Dock 中显示」,只留菜单栏图标;之后用户再把 Dock 打开不拦(14 章决策 62)。\n"
                            + "            if silentLaunch, !oldValue { showInDock = false }"),
                true, "静默启动: 打开时顺带关掉「在 Dock 中显示」")
    expectEqual(sourceBytes(delegate, contain: "applicationShouldOpenUntitledFile"), false,
                "静默启动: 不靠 applicationShouldOpenUntitledFile(SwiftUI 不经过 App 委托问它)")
    expectEqual(sourceBytes(restorer, contain: "openLyricsWindow"), false, "启动重开: 重试也不走先激活 App 的 openLyricsWindow")
    expectEqual(sourceBytes(restorer, contain: "if let window = LyricsWindowSession.window {\n            window.orderFrontRegardless()\n        } else {\n            openWindow()\n        }"),
                true, "启动重开: 窗口建出来了只是没上屏就直接摆到最前,没建出来才再开")
    expectEqual(sourceBytes(restorer, contain: "|| (LyricsWindowSession.window.map { $0.isVisible || $0.isMiniaturized } ?? false),")
                && sourceBytes(restorer, contain: "stillWanted: LyricsWindowSession.shouldReopenAtLaunch && !AppExit.isTerminating)"),
                true, "启动重开: 核对用登记的窗口(最小化也算),还该不该开读「开着」那个键和退出标记")
    expectEqual(sourceBytes(window, contain: "        self.window = window\n        LyricsWindowSession.window = window\n"), true,
                "启动重开: 控制器 attach 新窗口时登记")
    for line in ["launch restore: lyrics window on screen attempts=", "launch restore: lyrics window not on screen, retrying attempt=",
                 "launch restore: lyrics window still not on screen, giving up attempts=", "launch restore: stopped, window closed"] {
        expectEqual(sourceBytes(restorer, contain: line), true, "启动重开: 日志里有「\(line)」")
    }
}
