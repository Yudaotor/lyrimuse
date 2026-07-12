import SwiftUI

struct MenuBarMenu: View {
    @ObservedObject private var overlay = LyricsOverlayWindowController.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle("显示悬浮歌词", isOn: Binding(
            get: { overlay.isVisible },
            set: { overlay.setVisible($0) }
        ))
        Toggle("点击穿透(不拦截下层点击)", isOn: Binding(
            get: { overlay.isClickThrough },
            set: { overlay.setClickThrough($0) }
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
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
    }
}
