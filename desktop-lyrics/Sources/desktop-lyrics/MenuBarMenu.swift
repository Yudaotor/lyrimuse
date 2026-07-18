import SwiftUI

// 状态栏图标本体(MenuBarExtra 的 label)——设置里关掉、没在播放、或者还没解析出这一句
// 歌词时,退回固定的图标+文字;都满足时直接显示当前这一行,上限可以在设置里调
// (settings.menuBarLyricsMaxChars,见「歌词」tab「展示」分组)。
struct MenuBarLabel: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = PlaybackCoordinator.shared
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow) private var openWindowAction

    var body: some View {
        Group {
            if settings.showLyricsInMenuBar,
               coordinator.isPlayingNow,
               let text = coordinator.currentLine?.plainText,
               !text.isEmpty {
                // 状态栏空间有限,截断是必须的,不能像悬浮窗那样直接自动换行——但截断不该等于
                // "看不到剩下的部分",鼠标悬停时用系统原生 tooltip 把完整这一行显示出来。
                Text(truncated(text)).help(text)
            } else {
                Label(L10n.t("桌面歌词"), systemImage: "text.quote")
            }
        }
        // label: 是 MenuBarExtra 真正常驻状态栏的那部分,整个 App 运行期间只挂载一次
        // (不像 content: 那样只在点开菜单时才有内容)——这里是"从非 View 上下文触发
        // SwiftUI 环境 action"这个问题(见 AppActions.swift)里,唯一确定只会跑一次的
        // 挂载点。跟 MenuBarMenu 里"设置…"按钮已经验证过的写法一致:accessory 策略
        // (没有 Dock 图标)下,不先手动激活 App,openSettings()/openWindow(id:) 都会
        // 静默没反应。
        .onAppear {
            AppActions.shared.openSettings = {
                NSApp.activate(ignoringOtherApps: true)
                openSettingsAction()
            }
            AppActions.shared.openLyricsManager = {
                NSApp.activate(ignoringOtherApps: true)
                openWindowAction(id: "lyrics-manager")
            }
        }
    }

    private func truncated(_ text: String) -> String {
        let maxChars = settings.menuBarLyricsMaxChars
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "…"
    }
}

struct MenuBarMenu: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // "显示悬浮歌词"/"锁定位置"这两个 Toggle 具体读/写哪个控制器,取决于
        // settings.overlayStyle 当下的值——用 if/else 各自拆成独立的小 View,而不是
        // 在这里直接同时持有两个控制器的 @ObservedObject:两个控制器各自都是
        // `static let shared`,真正引用到才会执行 init() 建窗口,而 init() 里订阅
        // PlaybackCoordinator 的 Combine sink 在订阅的一瞬间就会用当下的 isVisible
        // (默认 true)触发一次 orderFront——如果不管当前样式是哪个都无条件持有两份
        // @ObservedObject,只是点开一次菜单就会把没在用的那个控制器也构造出来、连带
        // 把它的窗口显示到屏幕上。SwiftUI 的 if/else 只会真正构建被选中的那个分支
        // 对应的 View,没被选中的分支连初始化都不会跑,借这个机制保证永远不会误碰
        // 不该碰的那个控制器(这条不变量详见 NotchLyricsWindowController 顶部注释)。
        if settings.overlayStyle == "notch" {
            NotchOverlayMenuSection()
        } else {
            ClassicOverlayMenuSection()
        }
        Divider()
        Toggle(L10n.t("开机启动"), isOn: $settings.launchAtLoginEnabled)
        // 不用 SettingsLink——这个 App 是 .accessory 策略(没有 Dock 图标/常规激活),
        // SettingsLink 内部触发设置窗口时依赖应用正常激活的那套机制,在 accessory 策略下
        // 实测点了没反应(窗口没弹出来,不是被挡住)。改成手动先激活 App 再调
        // openSettings(),激活这一步是关键,少了这步同样打不开。
        Button(L10n.t("设置…")) {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        // 跟"设置…"同一个坑:accessory 策略(没有 Dock 图标)下打开任何新窗口都得先
        // 手动激活 App,不然 openWindow 调了也没反应。
        Button(L10n.t("歌词管理…")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "lyrics-manager")
        }
        Divider()
        Button(L10n.t("退出")) { NSApplication.shared.terminate(nil) }
    }
}

// 经典悬浮窗样式生效时的菜单项——"显示悬浮歌词"+"锁定位置"。只在这个子 View 里持有
// LyricsOverlayWindowController.shared,不放在 MenuBarMenu 本体上:MenuBarMenu.body
// 的 if/else 只会构建被选中分支对应的 View,把控制器引用限制在这个分支专属的小
// View 里,才能保证灵动岛样式生效时永远不会误触构造经典控制器。
private struct ClassicOverlayMenuSection: View {
    @ObservedObject private var overlay = LyricsOverlayWindowController.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(L10n.t("显示悬浮歌词"), isOn: Binding(
            get: { overlay.isVisible },
            set: { overlay.setVisible($0) }
        ))
        Toggle(L10n.t("锁定位置(不可拖拽+点击穿透)"), isOn: Binding(
            get: { overlay.isPositionLocked },
            set: { newValue in
                settings.lockPosition = newValue
                overlay.setLocked(newValue)
            }
        ))
    }
}

// 灵动岛样式生效时的菜单项——只有"显示悬浮歌词"一项:灵动岛的位置是算出来的、贴死
// 在屏幕顶部,没有"锁定位置"这个概念(见 NotchLyricsWindow 里
// isMovableByWindowBackground = false 那段注释)。同理只在这个子 View 里持有
// NotchLyricsWindowController.shared,理由跟 ClassicOverlayMenuSection 对称。
private struct NotchOverlayMenuSection: View {
    @ObservedObject private var overlay = NotchLyricsWindowController.shared

    var body: some View {
        Toggle(L10n.t("显示悬浮歌词"), isOn: Binding(
            get: { overlay.isVisible },
            set: { overlay.setVisible($0) }
        ))
    }
}
