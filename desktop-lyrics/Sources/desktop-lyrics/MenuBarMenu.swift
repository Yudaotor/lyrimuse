import SwiftUI

// 状态栏图标本体(MenuBarExtra 的 label)——设置里关掉、没在播放、或者还没解析出这一句
// 歌词时,退回固定的图标+文字;都满足时直接显示当前这一行,单行截断到一个字数上限,
// 避免长歌词行把状态栏其它 App 的图标挤没了。
struct MenuBarLabel: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = PlaybackCoordinator.shared

    private static let maxChars = 28

    var body: some View {
        if settings.showLyricsInMenuBar,
           coordinator.isPlayingNow,
           let text = coordinator.currentLine?.plainText,
           !text.isEmpty {
            Text(truncated(text))
        } else {
            Label("桌面歌词", systemImage: "text.quote")
        }
    }

    private func truncated(_ text: String) -> String {
        guard text.count > Self.maxChars else { return text }
        return String(text.prefix(Self.maxChars)) + "…"
    }
}

struct MenuBarMenu: View {
    @ObservedObject private var overlay = LyricsOverlayWindowController.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("显示悬浮歌词", isOn: Binding(
            get: { overlay.isVisible },
            set: { overlay.setVisible($0) }
        ))
        Toggle("锁定位置(不可拖拽+点击穿透)", isOn: Binding(
            get: { overlay.isPositionLocked },
            set: { newValue in
                settings.lockPosition = newValue
                overlay.setLocked(newValue)
            }
        ))
        Divider()
        Toggle("开机启动", isOn: $settings.launchAtLoginEnabled)
        // 不用 SettingsLink——这个 App 是 .accessory 策略(没有 Dock 图标/常规激活),
        // SettingsLink 内部触发设置窗口时依赖应用正常激活的那套机制,在 accessory 策略下
        // 实测点了没反应(窗口没弹出来,不是被挡住)。改成手动先激活 App 再调
        // openSettings(),激活这一步是关键,少了这步同样打不开。
        Button("设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        // 跟"设置…"同一个坑:accessory 策略(没有 Dock 图标)下打开任何新窗口都得先
        // 手动激活 App,不然 openWindow 调了也没反应。
        Button("歌词管理…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "lyrics-manager")
        }
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
    }
}
