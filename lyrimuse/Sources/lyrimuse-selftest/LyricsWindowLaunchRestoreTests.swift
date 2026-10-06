import Foundation
import LyrimuseCore

/// 启动重开歌词窗口(07 章决策 124):开了核对、没上屏再开的状态机,以及 App 侧接线。
func checkLyricsWindowLaunchRestore() {
    print("\n== 歌词窗口启动重开 ==")
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
    expectEqual(sourceBytes(actions, contain: "if settings.hasCompletedOnboarding, LyricsWindowSession.shouldReopenAtLaunch {\n"
                            + "                    LyricsWindowLaunchRestorer.start {\n"
                            + "                        LyricsWindowSession.markRestoringAtLaunch()\n"
                            + "                        openWindowAction(id: \"lyrics-window\")\n"
                            + "                    }\n                }"),
                true, "启动重开: 引导走完、上次开着才启动,开窗走不激活 App 的那条(决策 123)")
    expectEqual(sourceBytes(restorer, contain: "openLyricsWindow"), false, "启动重开: 重试也不走先激活 App 的 openLyricsWindow")
    expectEqual(sourceBytes(restorer, contain: "if let window = LyricsWindowSession.window {\n            window.orderFrontRegardless()\n        } else {\n            openWindow()\n        }"),
                true, "启动重开: 窗口建出来了只是没上屏就直接摆到最前,没建出来才再开")
    expectEqual(sourceBytes(restorer, contain: "onScreen: LyricsWindowSession.window.map { $0.isVisible || $0.isMiniaturized } ?? false,")
                && sourceBytes(restorer, contain: "stillWanted: LyricsWindowSession.shouldReopenAtLaunch && !AppExit.isTerminating)"),
                true, "启动重开: 核对用登记的窗口(最小化也算),还该不该开读「开着」那个键和退出标记")
    expectEqual(sourceBytes(window, contain: "        self.window = window\n        LyricsWindowSession.window = window\n"), true,
                "启动重开: 控制器 attach 新窗口时登记")
    for line in ["launch restore: lyrics window on screen attempts=", "launch restore: lyrics window not on screen, retrying attempt=",
                 "launch restore: lyrics window still not on screen, giving up attempts=", "launch restore: stopped, window closed"] {
        expectEqual(sourceBytes(restorer, contain: line), true, "启动重开: 日志里有「\(line)」")
    }
}
