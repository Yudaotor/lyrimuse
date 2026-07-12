import AppKit
import DesktopLyricsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 裸可执行文件(没打成 .app 包)也能表现成菜单栏专属应用,不占 Dock/Cmd-Tab——
        // 已实测确认,不需要 Info.plist 的 LSUIElement。
        NSApp.setActivationPolicy(.accessory)

        let settings = AppSettings.shared
        RelayPoller.shared.updateBaseURL(settings.relayBaseURL)
        RelayPoller.shared.preferWordLevelKaraoke = settings.preferWordLevelKaraoke

        LyricsOverlayWindowController.shared.setVisible(true)
        LyricsOverlayWindowController.shared.setClickThrough(false)

        RelayPoller.shared.start()
    }
}
