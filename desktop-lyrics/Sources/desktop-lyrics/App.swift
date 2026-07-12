import SwiftUI

@main
struct DesktopLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("桌面歌词", systemImage: "text.quote") {
            MenuBarMenu()
        }
        Settings {
            SettingsView()
        }
    }
}
