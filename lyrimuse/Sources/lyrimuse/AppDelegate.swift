import AppKit
import CoreServices
import LyrimuseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 2026-07-29 新增:接住"连接 Last.fm 账号"授权页跳回来的 lyrimuse:// 回调(见
    // build.sh 的 CFBundleURLTypes + LastfmAuthFlow.authorizeURL 的 cb= 参数)。
    // 用最传统的 NSAppleEventManager 注册方式,而不是 SwiftUI 的 .onOpenURL——这个
    // App 没有 WindowGroup 承载这个修饰符最典型的挂载点(MenuBarExtra/Settings 这类
    // Scene 上是否稳定接收 GetURL 事件没有十足把握),Apple Event Manager 是 AppKit
    // 官方文档明确支持、且这个项目里 MusicAutomationPermission 已经在用的同一层
    // 机制,更可靠。必须在 applicationWillFinishLaunching(而不是 didFinishLaunching)
    // 里注册——早于 launchServices 把已经攒着的 GetURL 事件投递进来,注册晚了会
    // 错过"双击链接直接启动 App"这种冷启动场景(虽然这次的场景是 App 已经在跑,但
    // 仍然照 Apple 官方推荐的时机来,不留隐患)。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString), url.scheme == "lyrimuse" else {
            return
        }
        // 目前只有这一种回调用途,不需要按 host/path 再分流;后续如果这个 scheme 挂了
        // 别的用途,再在这里加判断。
        LastfmConnectController.shared.handleAuthCallback()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 系统默认的 .help(_:) 悬浮提示延迟(NSInitialToolTipDelay,大约 1~1.5 秒)
        // 太长,容易被误以为悬浮提示没工作。这个值是 AppKit 从本 App 自己的 UserDefaults
        // 域里读的,不是全局系统设置,只影响这个 App 进程内的 .help() 提示,不会改到
        // 别的 App。.register(defaults:) 只在内存里注册一个后备默认值,不会写盘持久化,
        // 每次启动都要重新设一次;调到 150ms 之后,这个 App 里所有用到 .help() 的地方
        // 悬浮后都会更快弹出提示。
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])

        let settings = AppSettings.shared

        // ConfigStore/FeatureSettingsStore 写配置文件、collector 自己写歌词/封面缓存都
        // 假设这个目录已经存在，但谁都不会在写之前 createDirectory——这里无条件、幂等
        // 地建一次，不依赖引导流程是否跑完，第一次启动就先把这个目录建好。
        try? FileManager.default.createDirectory(
            at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lyrimuse"),
            withIntermediateDirectories: true)

        // 裸可执行文件(没打成 .app 包)也能表现成菜单栏专属应用,不占 Dock/Cmd-Tab,
        // 不需要 Info.plist 的 LSUIElement。默认(没碰过"在 Dock 中显示"这个设置的人)
        // 是 .accessory；AppSettings.showInDock 的 didSet 不会在它自己 init() 赋初值
        // 这一步触发(Swift 语义),所以这里必须显式按持久化的值应用一次。
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        LocalPlaybackSource.shared.preferWordLevelKaraoke = settings.preferWordLevelKaraoke

        // 桌面悬浮歌词、灵动岛歌词各自独立开关,互不排斥,可以同时开、只开一个、或都不开。
        // 只对确实开启的那个(些)控制器碰一下 .shared,完全不碰关闭的那个:两个控制器
        // 各自都是 static let shared,真正引用到 .shared 才会执行 init() 建窗口,不主动
        // 碰关闭的那个,它就不会凭空建一个不需要的窗口(见 NotchLyricsWindowController
        // 顶部注释里这条不变量的详细说明)。
        //
        // 2026-08-03 实测排查坐实、删掉这里原来的 setVisible(true) 调用:isVisible 现在
        // 是持久化的用户偏好(见两个控制器各自的 restoredVisible()),.shared 的 init()
        // 本身已经会用恢复出来的这个值触发一次 updateActualVisibility(见
        // NotchLyricsWindowController.init() 里 isPlayingObserver 那段注释——订阅
        // PlaybackCoordinator.$isPlayingNow 的一瞬间就会拿当下的 isVisible 显示/隐藏
        // 一次)。这里如果还调 setVisible(true),会在 init() 刚刚正确恢复出"用户上次关掉
        // 了"这个状态之后,立刻无条件覆盖成 true 并重新持久化——用户明明关掉了灵动岛/
        // 悬浮歌词,下次打开 App 它又会自己重新出现,菜单里的勾选状态也会被这一行悄悄
        // 改回勾选,这正是之前的真实 bug。下面几行 setLocked/setHiddenFromCapture/
        // setHideWhenNotPlaying 本身已经足够触发 .shared 的构造,不需要再额外调
        // setVisible 才能"顺便"建出窗口。
        if settings.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.setLocked(settings.lockPosition)
            LyricsOverlayWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
            LyricsOverlayWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
        }
        if settings.notchOverlayEnabled {
            NotchLyricsWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
            NotchLyricsWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
        }

        PlaybackCoordinator.shared.start()
        // 菜单栏歌词跑马灯的驱动器——生命周期自持(靠 Combine 自己决定何时开停计时器),
        // 这里只需要在启动时点一次,见 MenuBarMarqueeTicker 顶部注释。
        MenuBarMarqueeTicker.shared.start()

        // 打开 Lyrimuse 时顺带唤起当前选定的播放器(可选,见 AppSettings.
        // launchMusicOnLyrimuseOpen 注释)。跟着 PlaybackPlayerPreference.current 走,
        // 不再写死 Apple Music——选了 QQ 音乐时唤起的应该是 QQ 音乐,不是一个用户压根
        // 没在用的 App。只在目标 App 还没运行时才启动它——已经在跑就什么都不做,不做
        // 多余的"带到前台"动作,避免用户正在用别的 App 时被意外抢焦点。
        if settings.launchMusicOnLyrimuseOpen {
            let bundleID = PlaybackPlayerPreference.current.bundleIdentifier
            if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }),
               let playerURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: playerURL, configuration: config)
            }
        }

        // 首次启动的完整引导向导——触发点在 MenuBarLabel.onAppear,不在这里:
        // openWindow(id:) 这个 SwiftUI 环境 action 只有挂载的 View 才能拿到,这个时机
        // (AppDelegate.applicationDidFinishLaunching)早于 MenuBarExtra 的 label 真正
        // 挂载,这里调用会静默没反应。
        GlobalHotkeys.registerAll()

        // 触发 SparkleUpdaterManager 的懒加载初始化——它的 init() 会以
        // startingUpdater: true 启动 Sparkle 自己的 updater,按 Info.plist 里
        // SUEnableAutomaticChecks 的配置做周期性后台检查,不需要自己维护"查一次/
        // 记录已提示过哪个版本"这套状态(Sparkle 自己管这些)。
        _ = SparkleUpdaterManager.shared
    }

    // 这个 App 没有传统意义上的"主窗口"(内容是菜单栏图标+悬浮歌词窗口+按需打开的
    // 设置窗口),不实现这个 delegate 方法的话,点 Dock 图标(只在"showInDock"开着、
    // 走 .regular 激活策略时才会有 Dock 图标)完全没有默认行为。参考同类"菜单栏常驻+
    // 可选 Dock 图标"工具(Bartender/iStat Menus)的通行做法,把设置窗口当成这个 App
    // 唯一的"主窗口"——hasVisibleWindows 为 false 时才主动打开,已有可见窗口时让系统
    // 默认的"带到前台"行为接管。openSettings() 是 SwiftUI 环境 action,AppDelegate
    // 不在 View 上下文里拿不到,借道 AppActions 这个桥(见该文件注释)。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppActions.shared.openSettings?()
        }
        return true
    }

    // Cmd+Q / 菜单"退出 Lyrimuse"的正常退出路径——2026-08-02 补上:AccountLinkingTab
    // 里文本字段(Token/API Key 等)的自动保存是 1.2 秒防抖(见该文件 performAutoSave
    // 的 onReceive),如果用户刚打完字就立刻 Cmd+Q,防抖计时器根本没机会触发,那次
    // 编辑连磁盘都没写进去就随着进程退出彻底丢失——同一个文件里 .onDisappear 那道
    // 兜底只覆盖"切换到别的账号卡片/关掉设置窗口"这两种场景,不覆盖"直接退出整个
    // App":SwiftUI 的 .onDisappear 不保证在进程被终止时对每个视图都执行一遍,尤其是
    // Settings 这类按需构造的 Scene。这里在真正退出前先同步检查 ConfigStore 是否还有
    // 没保存的改动:没有就直接放行,不拖慢正常退出;有就用 .terminateLater 暂缓退出,
    // 异步存盘(顺带重启 collector)完成后再 reply(toApplicationShouldTerminate:) 放行
    // ——不管存盘成功与否都放行,避免磁盘写入异常时把 Cmd+Q 卡死。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ConfigStore.shared.isDirty else { return .terminateNow }
        Task {
            _ = await ConfigStore.shared.save()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
