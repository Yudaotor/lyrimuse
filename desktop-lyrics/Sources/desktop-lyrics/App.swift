import SwiftUI

@main
struct DesktopLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 用 content:label: 形式而不是固定标题+图标——状态栏显示当前歌词这个设置项
        // 开着时,label 要能动态换成歌词文字(见 MenuBarLabel)。
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarLabel()
        }
        Settings {
            SettingsView()
        }
        Window(L10n.t("歌词管理"), id: "lyrics-manager") {
            LyricsManagerView()
        }
    }
}
