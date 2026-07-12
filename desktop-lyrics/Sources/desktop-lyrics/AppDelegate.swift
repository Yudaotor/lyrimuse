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
        LocalPlaybackSource.shared.preferWordLevelKaraoke = settings.preferWordLevelKaraoke

        LyricsOverlayWindowController.shared.setVisible(true)
        LyricsOverlayWindowController.shared.setClickThrough(false)

        // 按设置里选的数据源启动对应的那一个(默认远程,保持原有行为);PlaybackCoordinator
        // 负责真正调 start()/stop(),这里不用再单独调 RelayPoller.shared.start()。
        PlaybackCoordinator.shared.applyMode(settings.dataSourceMode)
    }
}
