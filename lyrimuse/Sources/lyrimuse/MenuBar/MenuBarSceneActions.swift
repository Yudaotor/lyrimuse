import AppKit
import SwiftUI

// `openSettings()` / `openWindow(id:)` 这两个"打开某扇 SwiftUI 窗口"的能力,只能从一个
// **挂载着的 SwiftUI 视图**里拿到(它们是 @Environment action)。
//
// 2026-08-16 之前这个挂载点是 MenuBarExtra 的 label(MenuBarLabel.onAppear)——它是整个
// App 生命周期里唯一确定"只挂载一次且一直在"的视图。换成自建 NSStatusItem 之后 label
// 没了,而设置/歌词管理/歌词窗口/引导这四扇窗仍然是 SwiftUI 的 Settings/Window(id:) 场景
// (**故意不改**:Settings 场景顺带给了"Lyrimuse ▸ 设置… ⌘,"那个主菜单项,自己用
// NSWindow 重搭会把它弄丢,而且 Window(id:) 的位置/尺寸存档也是白拿的)。
//
// 所以需要一个新的挂载点。这里的做法:建一扇**永远不显示**的 1×1 窗口,里面挂一个空的
// SwiftUI 视图,专门用来把这几个环境 action 捕获进 AppActions。
//
// ⚠️ "场景树之外的 NSHostingView 里,openWindow 还灵不灵" 这件事是**实测**过的,不是
// 想当然(2026-08-16 探针):窗口从头到尾没有 orderFront、isVisible 一直是 false,
// 视图的 onAppear 照常触发,openWindow(id:) 也确实把目标窗口开了出来。
//
// 窗口不显示这一点很要紧:它一旦算"可见",AppDelegate.applicationShouldHandleReopen 收到的
// hasVisibleWindows 就会恒为 true,点 Dock 图标再也打不开设置窗口。
@MainActor
enum MenuBarSceneActions {
    private static var anchorWindow: NSWindow?

    /// 主菜单「Lyrimuse ▸ 设置…」那一条(SwiftUI 见到 Settings 场景自动装上去的)。
    ///
    /// ⚠️ 为什么打开设置窗口非得绕这一圈,不能跟另外三扇窗一样直接用环境 action:
    /// 2026-08-16 实测坐实,`openWindow(id:)` 从场景树外的锚点视图里调**有效**,而
    /// `openSettings()` 在同样的位置是个**静默空操作** —— 而且它的失败方式很有欺骗性:
    /// 设置窗口**已经开着**时它能把窗口带到前台(看起来一切正常),只有窗口被关掉之后
    /// 才暴露"再也开不回来"。当时差点因此误判成"没问题"。
    /// `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` 那个
    /// 老写法同样不行:它返回 true(确实有响应者接下了),但窗口照样没出来。
    /// 唯一实测有效的是**直接触发主菜单里 SwiftUI 自己那一条** —— 它的 target 才是真正
    /// 会创建窗口的那个对象。
    ///
    /// 按 ⌘, 认这一项,不按标题(会随语言变)、也不按 selector 名(showSettingsWindow: 是
    /// 私有的,而且 macOS 13 上还叫 showPreferencesWindow:)。
    ///
    /// 主菜单在 .accessory 策略(没有 Dock 图标、菜单栏上看不到它)下**依然存在**,这一条
    /// 也照样找得到 —— 探针在两种策略下各验过一遍。
    private static func mainMenuSettingsItem() -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            if let hit = submenu.items.first(where: {
                $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
            }) {
                return hit
            }
        }
        return nil
    }

    /// 打开设置窗口。见 mainMenuSettingsItem 上那段说明。
    static func presentSettings(fallback: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let item = mainMenuSettingsItem(), let action = item.action,
           NSApp.sendAction(action, to: item.target, from: item) {
            return
        }
        // 找不到那一项(SwiftUI 换了主菜单的搭法?)就退回环境 action —— 它至少能把已经
        // 开着的设置窗口带到前台,聊胜于无。
        fallback()
    }

    /// AppDelegate 启动时调一次。
    static func install() {
        guard anchorWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SceneActionRegistrar())
        // 下面几行都是"让它彻底消失在系统的各种窗口清单里":不进 Cmd-Tab/调度中心的
        // 循环、不进「窗口」菜单、不吃鼠标事件、关掉也不释放(这扇窗要活到进程结束)。
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.ignoresCycle, .stationary]
        window.isReleasedWhenClosed = false
        // 刻意**不调** orderFront/setIsVisible(true)。
        anchorWindow = window
    }
}

/// 空视图,只干两件事:把环境 action 存进 AppActions;首次启动时把引导向导拉起来。
private struct SceneActionRegistrar: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow) private var openWindowAction

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                // accessory 策略(没有 Dock 图标)下,不先手动激活 App,openSettings()/
                // openWindow(id:) 都会静默没反应 —— 所以激活这一步包进闭包里,让所有
                // 调用方(菜单、全局快捷键、AppDelegate 的 Dock 点击回调)都免费拿到。
                AppActions.shared.openSettings = {
                    MenuBarSceneActions.presentSettings { openSettingsAction() }
                }
                AppActions.shared.openLyricsManager = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindowAction(id: "lyrics-manager")
                }
                AppActions.shared.openLyricsWindow = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindowAction(id: "lyrics-window")
                }
                AppActions.shared.openLyricsQuickSearch = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindowAction(id: "lyrics-quick-search")
                    // 窗口已经开着(没被真关掉)时,上面这行只是把它带到前台,不会让
                    // LyricsQuickSearchWindow 的 .task 重跑——靠这一下 send 补上"点一次
                    // 就该看到当前这首歌"这个诉求,见 AppActions.quickSearchRefreshRequests
                    // 的注释。
                    AppActions.shared.quickSearchRefreshRequests.send()
                }
                AppActions.shared.openOnboarding = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindowAction(id: "onboarding")
                }
                // 首次启动的完整引导向导——放在这里而不是 AppDelegate.
                // applicationDidFinishLaunching 里直接调用,是因为 openWindow(id:) 这个
                // SwiftUI 环境 action 只有在某个 View 的挂载点才能拿到;AppDelegate 那个
                // 时机早于这扇锚点窗口真正挂载,这时候调用会静默没反应。
                //
                // 坑:直接在这个 onAppear 里同步调 NSApp.activate + openWindow 完全不生效——
                // 这一刻是启动过程里最早的时间点之一,系统还没走完 accessory 策略 App
                // 真正"启动完成"的流程,两个调用本身不报错,但窗口要么没建出来、要么建出来
                // 立刻被吞掉,肉眼看不到。"设置…"/"歌词管理…"这两个菜单项没踩到这个坑,
                // 是因为它们永远是用户手动点出来的、那时候 App 早已完全启动稳定。加一个
                // 不长的延迟,让启动流程先跑完再发起,就能稳定弹出来。
                if !settings.hasCompletedOnboarding {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // 换电脑这条路先走一步:iCloud 里已经有配置就先问要不要导入,导入了
                        // 就重启(引导在重启之后照样走,理由见 ICloudConfigImportPrompt);
                        // 没有/跳过/还没下载好就原样走引导。
                        ICloudConfigImportPrompt.offerIfNeeded {
                            AppActions.shared.openOnboarding?()
                        }
                    }
                }
            }
    }
}
