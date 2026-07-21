import AppKit
import LyrimuseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.shared

        // 裸可执行文件(没打成 .app 包)也能表现成菜单栏专属应用,不占 Dock/Cmd-Tab——
        // 已实测确认,不需要 Info.plist 的 LSUIElement。默认(没碰过"在 Dock 中显示"这个
        // 设置的人)是 .accessory,保持这个 App 一直以来的既有体验；AppSettings.
        // showInDock 的 didSet 不会在它自己 init() 赋初值这一步触发(Swift 语义),
        // 所以这里必须显式按持久化的值应用一次,不能指望 didSet 帮忙补上这一步。
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        LocalPlaybackSource.shared.preferWordLevelKaraoke = settings.preferWordLevelKaraoke

        // 桌面悬浮歌词、灵动岛歌词各自独立开关,互不排斥,可以同时开、只开一个、或都不开。
        // 只对确实开启的那个(些)控制器调 setVisible(true),完全不碰关闭的那个:两个
        // 控制器各自都是 static let shared,真正引用到 .shared 才会执行 init() 建窗口,
        // 不主动碰关闭的那个,它就不会凭空建一个不需要的窗口(见
        // NotchLyricsWindowController 顶部注释里这条不变量的详细说明)。
        if settings.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.setVisible(true)
            LyricsOverlayWindowController.shared.setLocked(settings.lockPosition)
            LyricsOverlayWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
            LyricsOverlayWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
        }
        if settings.notchOverlayEnabled {
            NotchLyricsWindowController.shared.setVisible(true)
            NotchLyricsWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
            NotchLyricsWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
        }

        PlaybackCoordinator.shared.start()

        // 首次启动的完整引导向导(欢迎/数据源模式/自动化权限/语言/完成)——触发点在
        // MenuBarLabel.onAppear,不在这里:openWindow(id:) 这个 SwiftUI 环境 action
        // 只有挂载的 View 才能拿到,这个时机(AppDelegate.applicationDidFinishLaunching)
        // 早于 MenuBarExtra 的 label 真正挂载,这里调用会静默没反应。旧版单独的"自动化
        // 权限"NSAlert(曾经放在这里)正是为了绕开这个时序问题才用 NSAlert 而不是
        // SwiftUI 窗口,现在整段引导折进新向导后,连带这个绕开时序问题的写法一起废弃。
        GlobalHotkeys.registerAll()
    }
}
