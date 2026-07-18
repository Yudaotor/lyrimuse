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
        LocalPlaybackSource.shared.preciseAppleMusicPosition = settings.preciseAppleMusicPosition

        // 两种悬浮窗样式互斥——只对 settings.overlayStyle 当下选中的那一个控制器调
        // setVisible(true),另一个保持完全不碰:两个控制器各自都是 static let
        // shared,真正引用到 .shared 才会执行 init() 建窗口,这里不主动碰未启用的
        // 那个,它就不会凭空建一个不需要的窗口(见 NotchLyricsWindowController 顶部
        // 注释里这条不变量的详细说明)。
        switch settings.overlayStyle {
        case "notch":
            NotchLyricsWindowController.shared.setVisible(true)
            NotchLyricsWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
            NotchLyricsWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
        default:
            LyricsOverlayWindowController.shared.setVisible(true)
            LyricsOverlayWindowController.shared.setLocked(settings.lockPosition)
            LyricsOverlayWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
            LyricsOverlayWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
        }

        // 按设置里选的数据源启动对应的那一个(默认远程,保持原有行为);PlaybackCoordinator
        // 负责真正调 start()/stop(),这里不用再单独调 RelayPoller.shared.start()。
        PlaybackCoordinator.shared.applyMode(settings.dataSourceMode)

        showAutomationOnboardingIfNeeded(settings: settings)
        GlobalHotkeys.registerAll()
    }

    // 首次启动主动引导一次"自动化"权限(控制 Music.app,给精确播放进度用)——只弹这
    // 一次,不管用户选哪个按钮都会把 hasShownAutomationOnboarding 置 true。用 NSAlert
    // 而不是 SwiftUI 的 .alert(...)(这个项目其它地方一律用后者):这一步发生在这里,
    // 这时候不一定已经有任何 SwiftUI 窗口打开着,没有地方可以挂 .alert 修饰符,NSAlert
    // 自带一个隐式窗口、不需要依赖任何已存在的视图,是这一个特殊时机下刻意的例外。
    //
    // 只在当前状态是"还没问过"时才弹——已经是已授权/已拒绝,说明用户之前已经有过
    // 明确结果(不管是通过这个引导框还是直接用到功能触发的系统弹窗),没有必要重复
    // 打扰,直接标记成"已展示过"。
    private func showAutomationOnboardingIfNeeded(settings: AppSettings) {
        guard !settings.hasShownAutomationOnboarding else { return }
        guard MusicAutomationPermission.check(askIfNeeded: false) == .notDetermined else {
            settings.hasShownAutomationOnboarding = true
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.t("开启 Apple Music 自动化权限？")
        alert.informativeText = L10n.t("desktop-lyrics 可以在本地模式下读取 Apple Music 的精确播放进度(误差 <0.1 秒)，需要系统「自动化」权限允许控制 Music.app。不授权也能正常使用——播放进度会改用估算值，可能有 1-2 秒误差。可以随时在设置里再次开启。")
        alert.addButton(withTitle: L10n.t("请求权限"))
        alert.addButton(withTitle: L10n.t("以后再说"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            MusicAutomationPermission.check(askIfNeeded: true)
        }
        settings.hasShownAutomationOnboarding = true
    }
}
