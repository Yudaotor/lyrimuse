import SwiftUI

struct MenuBarMenu: View {
    @ObservedObject private var overlay = LyricsOverlayWindowController.shared
    @ObservedObject private var settings = AppSettings.shared

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
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
    }
}
