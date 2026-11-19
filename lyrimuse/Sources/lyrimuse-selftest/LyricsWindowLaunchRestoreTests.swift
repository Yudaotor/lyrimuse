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

/// 隐身开窗(`invisible=1`)开的歌词窗口重启不重开;用户原本开着的照常重开(14 章决策 234)。
private func checkLyricsWindowOpenRecord() {
    typealias R = LyricsWindowOpenRecord
    func fresh(open: Bool, mini: Bool) -> UserDefaults {
        let defaults = InMemoryUserDefaults.make()!
        defaults.set(open, forKey: R.openKey)
        defaults.set(mini, forKey: R.miniModeKey)
        return defaults
    }
    /// 深链隐身开窗走的那一串:开窗入口先记形态、再改写「是不是迷你」,窗口 attach 时记开着。
    func openInvisibly(_ defaults: UserDefaults, mini: Bool) {
        R.noteInvisibleOpen(defaults)
        defaults.set(mini, forKey: R.miniModeKey)
        R.markOpen(defaults, invisibly: true)
    }

    let closed = fresh(open: false, mini: false)
    openInvisibly(closed, mini: true)
    expectEqual([R.isOpen(closed), R.isInvisibleOpen(closed)], [true, true], "隐身开窗: 开着期间照实记开着,另记隐身标记")
    R.settleAtLaunch(closed)
    expectEqual([R.isOpen(closed), R.isInvisibleOpen(closed), closed.bool(forKey: R.miniModeKey)], [false, false, false],
                "隐身开窗: 原本没开、隐身开着时重启,启动时记成没开(不重开),形态还回隐身开之前")

    let userOpen = fresh(open: true, mini: false)
    openInvisibly(userOpen, mini: false)
    R.markOpen(userOpen, invisibly: true)
    R.settleAtLaunch(userOpen)
    expectEqual([R.isOpen(userOpen), R.isInvisibleOpen(userOpen)], [true, false],
                "隐身开窗: 用户原本开着、验证再隐身操作,重启照原样重开")

    let attachOnly = fresh(open: false, mini: true)
    expectEqual(R.markOpen(attachOnly, invisibly: true), true, "隐身开窗: 从没开变成开着仍算一次打开")
    R.settleAtLaunch(attachOnly)
    expectEqual([R.isOpen(attachOnly), attachOnly.bool(forKey: R.miniModeKey)], [false, true],
                "隐身开窗: 不经开窗入口、窗口 attach 时才认出隐身的,重启同样不重开")

    let claimed = fresh(open: false, mini: false)
    openInvisibly(claimed, mini: true)
    R.claim(claimed)
    R.settleAtLaunch(claimed)
    expectEqual([R.isOpen(claimed), claimed.bool(forKey: R.miniModeKey)], [true, true],
                "隐身开窗: 之后用户正常打开了这扇,算用户的,重启照常重开")

    let closedAfter = fresh(open: false, mini: false)
    openInvisibly(closedAfter, mini: true)
    R.forget(closedAfter)
    expectEqual([R.isOpen(closedAfter), R.isInvisibleOpen(closedAfter), closedAfter.bool(forKey: R.miniModeKey)], [false, false, false],
                "隐身开窗: 隐身开的那扇关掉,记成没开、形态还回去")

    let normal = fresh(open: false, mini: true)
    expectEqual(R.markOpen(normal, invisibly: false), true, "正常打开: 从没开变成开着")
    expectEqual(R.markOpen(normal, invisibly: false), false, "正常打开: 已经开着不再算一次")
    R.settleAtLaunch(normal)
    expectEqual([R.isOpen(normal), R.isInvisibleOpen(normal)], [true, false], "正常打开: 重启照常重开")
    R.forget(normal)
    expectEqual([R.isOpen(normal), normal.bool(forKey: R.miniModeKey)], [false, true], "正常打开: 关窗只记没开,形态不动")
}

/// 启动重开歌词窗口(07 章决策 124):开了核对、没上屏再开的状态机,以及 App 侧接线。
func checkLyricsWindowLaunchRestore() {
    print("\n== 歌词窗口启动重开 ==")
    checkLaunchWindowPlan()
    checkLyricsWindowOpenRecord()
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
    expectEqual(sourceHas(actions, "let plan = LaunchWindowPlan(silentLaunch: settings.silentLaunch,\n"
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
    expectEqual(sourceBytes(window, contain: "static func forgetOpen() { LyricsWindowOpenRecord.forget(.standard) }"), true,
                "静默启动: 没重开时把「开着」记成没开")
    let delegate = source("lyrimuse/AppDelegate.swift")
    expectEqual(sourceHas(sourceBody("func applicationWillFinishLaunching(", in: delegate),
                          "terminateOlderInstances()\n        // 上次开着的歌词窗口是隐身开的就记成没开,要赶在启动重开、深链读「开着」之前。\n        LyricsWindowSession.settleAtLaunch()"),
                true, "隐身开窗: 启动时最早一拍就把隐身开的那扇记成没开(早于启动重开和深链)")
    expectEqual(sourceHas(sourceBody("@MainActor static func open(scene openScene: () -> Void)", in: window),
                          "if WindowActivation.isInvisible(scene: \"lyrics-window\") {\n            LyricsWindowOpenRecord.noteInvisibleOpen(.standard)\n        } else {\n            LyricsWindowOpenRecord.claim(.standard)\n        }"),
                true, "隐身开窗: 开窗入口隐身时先记原本的形态,正常打开时把隐身开的那扇认作用户的")
    expectEqual(sourceHas(window, "WindowActivation.isInvisible(scene: \"lyrics-window\") || window.map(WindowActivation.isHidden) == true"),
                true, "隐身开窗: 记开着时,隐身那一小段要开歌词窗口、或那扇正被压着,都算隐身开的")
    let settingsView = source("lyrimuse/SettingsView.swift")
    expectEqual(sourceHas(delegate, "_ = SparkleUpdaterManager.shared\n"
                            + "        // 放到下一拍:启动流程里排在这之后的窗口(SwiftUI 默认开的设置窗口)也还算启动阶段。\n"
                            + "        DispatchQueue.main.async { LaunchPhase.finish() }\n    }"),
                true, "静默启动: applicationDidFinishLaunching 末尾的下一拍才算启动流程走完")
    expectEqual(sourceHas(actions, "static func presentSettings(fallback: () -> Void) {\n        LaunchPhase.settingsRequested = true\n"),
                true, "静默启动: 菜单、快捷键、深链要设置窗口时记一笔,那扇不关")
    expectEqual(sourceHas(settingsView, "if LaunchWindowPlan.dropsSettingsWindow(launching: LaunchPhase.isLaunching,\n"
                            + "                                                    requested: LaunchPhase.settingsRequested) {\n"
                            + "                let animation = window.animationBehavior\n"
                            + "                window.animationBehavior = .none\n"
                            + "                window.alphaValue = 0\n"
                            + "                DispatchQueue.main.async {\n"
                            + "                    window.close()\n"
                            + "                    window.alphaValue = 1\n"
                            + "                    window.animationBehavior = animation\n"
                            + "                }\n"
                            + "            }"),
                true, "启动时开窗: SwiftUI 默认开的设置窗口先透明、下一拍关掉,关完还原透明度;期间关掉窗口动画,"
                    + "不然动画结束时透明度被还原成 0,再开设置是一扇看不见的窗(14 章决策 141)")
    let settings = source("lyrimuse/Settings/AppSettings.swift")
    expectEqual(sourceHas(settings, "defaults.set(silentLaunch, forKey: Keys.silentLaunch)\n"
                            + "            // 打开时顺带关掉「在 Dock 中显示」,只留菜单栏图标;之后用户再把 Dock 打开不拦(14 章决策 62)。\n"
                            + "            if silentLaunch, !oldValue { showInDock = false }"),
                true, "静默启动: 打开时顺带关掉「在 Dock 中显示」")
    expectEqual(sourceBytes(delegate, contain: "applicationShouldOpenUntitledFile"), false,
                "静默启动: 不靠 applicationShouldOpenUntitledFile(SwiftUI 不经过 App 委托问它)")
    expectEqual(sourceBytes(restorer, contain: "openLyricsWindow"), false, "启动重开: 重试也不走先激活 App 的 openLyricsWindow")
    expectEqual(sourceHas(restorer, "if let window = LyricsWindowSession.window {\n            window.orderFrontRegardless()\n        } else {\n            openWindow()\n        }"),
                true, "启动重开: 窗口建出来了只是没上屏就直接摆到最前,没建出来才再开")
    expectEqual(sourceBytes(restorer, contain: "|| (LyricsWindowSession.window.map { $0.isVisible || $0.isMiniaturized } ?? false),")
                && sourceBytes(restorer, contain: "stillWanted: LyricsWindowSession.shouldReopenAtLaunch && !AppExit.isTerminating)"),
                true, "启动重开: 核对用登记的窗口(最小化也算),还该不该开读「开着」那个键和退出标记")
    expectEqual(sourceHas(window, "        self.window = window\n        LyricsWindowSession.window = window\n"), true,
                "启动重开: 控制器 attach 新窗口时登记")
    for line in ["launch restore: lyrics window on screen attempts=", "launch restore: lyrics window not on screen, retrying attempt=",
                 "launch restore: lyrics window still not on screen, giving up attempts=", "launch restore: stopped, window closed"] {
        expectEqual(sourceBytes(restorer, contain: line), true, "启动重开: 日志里有「\(line)」")
    }
    // reopen 日志记发送方:读 keySenderPIDAttr 再查进程路径;keyAddressAttr 是目标地址,取不出发送方(07 章决策 157)。
    expectEqual(sourceBytes(delegate, contain: "event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value")
                    && sourceBytes(delegate, contain: "proc_pidpath(pid, &buffer, UInt32(buffer.count))")
                    && sourceBytes(delegate, contain: "from=\\(Self.reopenSender(), privacy: .public)"), true,
                "reopen 日志: 发送方按 pid 读、再查进程路径")
    expectEqual(sourceBytes(delegate, contain: "AEKeyword(keyAddressAttr)"), false, "reopen 日志: 不拿目标地址当发送方")
}
