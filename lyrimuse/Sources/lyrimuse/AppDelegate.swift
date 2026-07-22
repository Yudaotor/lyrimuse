import AppKit
import LyrimuseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 2026-07-22:系统默认的 .help(_:) 悬浮提示延迟(NSInitialToolTipDelay,大约
        // 1~1.5 秒)对"设置"里"实验室功能"那个"?"图标来说太长了——用户反馈"悬浮
        // 半天不出来",一度以为是悬浮提示压根没工作,后来才弄清楚其实是等待时间太长
        // 被当成了没反应。这个值是 AppKit 从本 App 自己的 UserDefaults 域里读的,不是
        // 全局系统设置,只影响这个 App 进程内的 .help() 提示,不会改到别的 App 的悬浮
        // 提示体验。.register(defaults:) 只在内存里注册一个后备默认值,不会写盘持久化,
        // 每次启动都要重新设一次;调到 150ms 之后,这个 App 里所有用到 .help() 的地方
        // (不只是这一个"?"图标)悬浮后都会更快弹出提示。
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])

        let settings = AppSettings.shared

        // ConfigStore/FeatureSettingsStore 写配置文件、collector 自己写歌词/封面缓存都
        // 假设这个目录已经存在，但谁都没有在写之前 createDirectory 过——以前全靠 README
        // 里那句手动 `mkdir -p ~/.config/applemusic-nowplaying` 兜底，2026-07-21 起这个
        // 手动步骤从安装指引里去掉了（collector 常驻服务改成引导流程里点一下就装好），
        // 所以这里补上：无条件、幂等，不依赖引导是否跑完，第一次启动就先把这个目录建好。
        try? FileManager.default.createDirectory(
            at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/applemusic-nowplaying"),
            withIntermediateDirectories: true)

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

    // 2026-07-22:用户反馈"点 Dock 里的图标没有任何反应"——这个 App 没有传统意义上的
    // "主窗口"(内容是菜单栏图标+悬浮歌词窗口+按需打开的设置窗口),之前也从没实现过
    // 这个 delegate 方法,所以点 Dock 图标(只在"showInDock"开着、走 .regular 激活策略
    // 时才会有 Dock 图标)完全没有任何默认行为。参考同类"菜单栏常驻+可选 Dock 图标"
    // 工具(Bartender/iStat Menus 这类)的通行做法,把设置窗口当成这个 App 唯一称得上
    // "主窗口"的东西——hasVisibleWindows 为 false(没有任何可见窗口,包括设置窗口本身
    // 没开着)时才主动打开,已经有可见窗口时让系统默认的"带到前台"行为接管,不重复处理。
    // openSettings() 是 SwiftUI 环境 action,AppDelegate 不在 View 上下文里拿不到,借道
    // AppActions 这个桥(本来就是为 GlobalHotkeys 这类同样处境的调用方搭的,见该文件
    // 注释),不用另起一套机制。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppActions.shared.openSettings?()
        }
        return true
    }
}
