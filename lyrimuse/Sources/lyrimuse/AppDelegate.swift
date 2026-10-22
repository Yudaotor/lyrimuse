import AppKit
import Combine
import OSLog
import CoreServices
import LyrimuseCore

/// 启动阶段:`applicationDidFinishLaunching` 跑完之前为真。设置窗口在这之前开出来,又没人要过它,就是 SwiftUI
/// 按默认开的,当场关掉(`LaunchWindowPlan.dropsSettingsWindow`,14 章决策 62)。
@MainActor
enum LaunchPhase {
    private(set) static var isLaunching = true
    /// 启动以来有人要过设置窗口(`MenuBarSceneActions.presentSettings`:菜单、快捷键、深链都走它)。
    static var settingsRequested = false
    static func finish() { isLaunching = false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `lyrimuse --unregister-login-item`(scripts/uninstall.sh 在删 App 包之前调):只注销登录项就退出,
    /// 不建窗口、不起服务。见 LoginItemManager.unregisterForUninstall。
    private var isUnregisterLoginItemRun: Bool {
        CommandLine.arguments.contains("--unregister-login-item")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // stdout / stderr 落到 ~/Library/Logs/lyrimuse-app.log(在进程内自己重定向):App 作为登录项由
        // LaunchServices 起,没有 launchd 替我们接管这两个流。第一件事就做,后面任何一行 Swift 运行时的报错都别漏。
        StandardStreamRedirect.installIfNeeded()
        // 退出原因日志(见 AppExit):SIGTERM 要在这里就接住,不然 launchctl kickstart -k
        // 这条最常见的退出路径连 applicationShouldTerminate 都到不了。
        AppExit.installSigtermHandler()
        if isUnregisterLoginItemRun {
            LoginItemManager.shared.unregisterForUninstall()
            AppExit.request(.unregisterLoginItemHelper)
            return
        }
        terminateOlderInstances()
        // 接住"连接 Last.fm 账号"授权页跳回来的 lyrimuse:// 回调(见 build.sh 的 CFBundleURLTypes +
        // LastfmAuthFlow.authorizeURL 的 cb= 参数)以及各条深链。用 NSAppleEventManager 注册,不用 SwiftUI 的
        // .onOpenURL:这个 App 没有 WindowGroup 这个最典型的挂载点(MenuBarExtra/Settings 这类 Scene 上是否稳定
        // 接收 GetURL 事件没有把握),Apple Event Manager 是 AppKit 官方明确支持的机制。必须在
        // applicationWillFinishLaunching(而不是 didFinishLaunching)里注册:早于 LaunchServices 把攒着的
        // GetURL 事件投递进来,注册晚了会错过"双击链接直接启动 App"这种冷启动场景。
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    // 同一个 App 同时跑起两份时,把**比自己老**的那几份请走,只留最新启动的这一个。
    //
    // 由 launchd 直接 exec 二进制起来的那份(LaunchAgent,label me.yudaotor.lyrimuse)不受 LaunchServices
    // "同一个 bundle 只开一份"的约束,从访达/聚焦/Dock 再打开一次会另外注册成一个 application.* 的 job,
    // 两个实例并存。表现相当隐蔽:两扇桌面悬浮歌词窗**坐标完全重合**,两边各自独立解析歌词,切歌那几秒
    // 进度不同步,看上去就是"一次显示了两首歌的词",等两边收敛到同一句之后文字完全重叠又"自己好了"。
    // 除了显示,两份实例还会各跑一套轮询、各自 scrobble。
    //
    // 选"新的赢"而不是"老的赢":用户刚刚双击打开、或刚装了新版本重启,期待生效的都是新
    // 启动的这一份;开发时 build.sh 换完二进制重启,也该是新二进制接管。
    //
    // 只请走**严格早于**自己启动的那几份,避免两份几乎同时起来时互相踢掉、一个都不剩。
    //
    // 判先后**不能**用 NSRunningApplication.launchDate:那个字段只有经 LaunchServices
    // 启动(双击/open)的进程才有,launchd 直接 exec 起来的那一份是 nil,守卫会一次都不触发。
    // 用 sysctl 读内核记的真实进程启动时间,对任何来路的进程都有效。
    //
    // 先 terminate()(礼貌退出,让对方有机会把缓存落盘),3 秒后还没走再 forceTerminate ——
    // 留着一个僵着不退的旧实例,等于这个守卫白做。
    private func terminateOlderInstances() {
        let me = NSRunningApplication.current
        guard let myID = me.bundleIdentifier,
              let myStart = Self.processStartTime(getpid()) else { return }
        for other in NSWorkspace.shared.runningApplications
        where other.bundleIdentifier == myID && other.processIdentifier != me.processIdentifier {
            guard let theirStart = Self.processStartTime(other.processIdentifier),
                  theirStart < myStart else { continue }
            // 走 lifecycle 分类的 Logger 不走 NSLog:诊断导出按 subsystem 查,NSLog 查不到。
            AppExit.logTerminatingOlderInstance(pid: other.processIdentifier, forced: false)
            other.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !other.isTerminated {
                    AppExit.logTerminatingOlderInstance(pid: other.processIdentifier, forced: true)
                    other.forceTerminate()
                }
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()

    /// Dock 图标右键菜单的自定义部分(设置/歌词管理/歌词窗口/Last.fm 四个跳转)。
    /// 见 DockMenu.swift 顶部注释——跟 applicationDockMenu(_:) 配对使用。
    private let dockMenuController = DockMenuController()

    /// Dock 菜单里的常用跳转(对照 Apple Music 的 Dock 菜单),见 DockMenuController 顶部注释。这里返回的
    /// 菜单会被 AppKit 摆在它自动追加的那部分(窗口列表/"选项"子菜单/显示所有窗口/隐藏/退出)**上面**,
    /// 不需要在这个方法里重复那些系统默认项。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenuController.makeMenu()
    }

    /// 进程启动时间(Unix 秒),取自内核的 kinfo_proc。任何来路的进程都有,不像
    /// NSRunningApplication.launchDate 只对经 LaunchServices 启动的有效。
    private static func processStartTime(_ pid: pid_t) -> TimeInterval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0)
        }
        guard rc == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        // 路由表在 Core `LyrimuseDeepLink`(有哪些链接、各自什么意思都在那边的头注),分派在 `DeepLinkRouter`。
        DeepLinkRouter.handle(url)
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        // 卸载辅助模式:willFinishLaunching 里已经请求退出,这里什么都不建。
        if isUnregisterLoginItemRun { return }
        // 必须是这个函数里第一个碰 AppSettings 的事之前:CustomFontStore.shared 的 init
        // 会把用户导入的字体注册进 Core Text(进程级,每次启动都要重新注册一遍)。下面一行
        // 就会第一次访问 AppSettings.shared,而它的 init() 末尾会用 fontFamilyName 算一遍
        // mainFont(recomputeFonts()) —— 这时如果自定义字体还没注册,NSFontManager 找不到
        // 那个族名,会静默落回系统字体,直到下一次设置变动才纠正过来。见 CustomFontStore 头注。
        _ = CustomFontStore.shared
        // 「开机启动」默认是开的(见 AppSettings.init),但那处赋值不触发 didSet,系统层面
        // 并不会因此注册登录项。这里补一次,让默认值真的算数。SMAppService 的注册是幂等的,
        // 已经注册过再调一次没有副作用;用户手动关掉之后这里读到 false,也不会偷偷再打开。
        // 顺带清掉旧方案留在 ~/Library/LaunchAgents 的 plist(见 LoginItemManager 头注)。
        //
        // 存过这个键时先按系统的实际状态对账,再注册:用户在「系统设置 › 登录项」里移除了它,对账把开关校正成关,
        // 不会又被注册回去。没存过(默认值)时注册之后把默认值落盘,下次启动同样走先对账那条。
        let launchAtLoginStored = UserDefaults.standard.object(forKey: "np:launchAtLoginEnabled") != nil
        if launchAtLoginStored { AppSettings.shared.syncLaunchAtLoginFromSystem() }
        LoginItemManager.shared.syncAtLaunch(enabled: AppSettings.shared.launchAtLoginEnabled)
        if !launchAtLoginStored {
            UserDefaults.standard.set(AppSettings.shared.launchAtLoginEnabled, forKey: "np:launchAtLoginEnabled")
        }
        // 外观要赶在任何窗口建出来之前定下;init 里的赋值不触发 didSet。
        AppSettings.shared.appearanceMode.apply()
        // 必须是这个函数的第一件事:AppSettings 在 init 里一次性把所有属性从 UserDefaults
        // 读进内存(下面第一次访问 AppSettings.shared 时发生),恢复晚了就只落了盘、这次启动
        // 的内存态还是空的。见 AppSettingsMirror.restoreIfPristine 的注释。
        AppSettingsMirror.restoreIfPristine()
        AppSettingsMirror.startObserving()
        // 启动时无条件写一次。只靠 startObserving 的话,一个从来没动过任何设置的用户
        // 配置文件夹里压根不会有这个文件 —— 而"拷整个文件夹换机器"恰恰是这类用户最可能
        // 走的路。幂等,内容没变时也就是重写一遍同样的字节。
        AppSettingsMirror.write()
        // 备份文件夹贴上 App 图标(仅在它已经存在时),让它在 Finder 里认得出来。
        ICloudConfigStore.ensureFolderIconIfPresent()
        // 封面/头像全走 AsyncImage(内部用 URLSession.shared),它吃的是 URLCache.shared,
        // 默认容量小得可怜 —— 最近记录展开到 100 行再切个 tab 回来,九十多张封面全部
        // 重新下载。给共享缓存一个像样的容量,磁盘部分跨启动依然有效。
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        // 焦点被网页视频占着且没有可用的定向通路(AppleScript / QQ 辅助功能菜单)时,播放控制不发,
        // 给一声提示音说明这次没生效。见 MusicPlaybackController.ControlRoute.withheld。
        MusicPlaybackController.onControlWithheld = { reason in
            NSSound.beep()
            if reason == .accessibilityPermissionRequired {
                AccessibilityPermission.shared.refresh()
                AppActions.shared.requestSettings(.tab(.player))
                AppActions.shared.openSettings?()
            }
        }
        // 两项授权在生效时就记下「授权成功过」(PermissionGrantMemory),之后失效才说得出「授权已失效」;
        // 不等设置页、引导页打开才记。见 14 章决策 67。
        AccessibilityPermission.shared.refresh()
        FullDiskAccessPermission.shared.refresh()
        // 启动后把 Last.fm 信息页那批小图(头像/封面)提前解码进内存:那一页是用户点进
        // 设置才打开的,启动到点进去之间有充足的空窗,预热完再打开就不会闪占位符了
        // (触发点是 LastfmStatsService 首次实例化 → loadSnapshot → prewarm)。
        // 延后 3 秒,不跟启动本身抢资源;没连 Last.fm 的话 loadSnapshot 直接返回,零成本。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            _ = LastfmStatsService.shared
        }
        // 系统默认的 .help(_:) 悬浮提示延迟(NSInitialToolTipDelay,大约 1~1.5 秒)
        // 太长,容易被误以为悬浮提示没工作。这个值是 AppKit 从本 App 自己的 UserDefaults
        // 域里读的,不是全局系统设置,只影响这个 App 进程内的 .help() 提示,不会改到
        // 别的 App。.register(defaults:) 只在内存里注册一个后备默认值,不会写盘持久化,
        // 每次启动都要重新设一次;调到 150ms 之后,这个 App 里所有用到 .help() 的地方
        // 悬浮后都会更快弹出提示。
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])

        let settings = AppSettings.shared

        // ConfigStore/FeatureSettingsStore 写配置文件、引擎自己写歌词/封面缓存都
        // 假设这个目录已经存在，但谁都不会在写之前 createDirectory——这里无条件、幂等
        // 地建一次，不依赖引导流程是否跑完，第一次启动就先把这个目录建好。
        FileIO.createDirectory(LyrimusePaths.configDir)

        // 引擎的 launchd job 对账。必须在启动路径上跑,这是 Sparkle 自动更新 /
        // Homebrew cask upgrade / 手动拖 .app 覆盖这三条路唯一的兜底 —— 它们都不经过
        // build.sh,而换掉引擎二进制会让 launchd 缓存的 LWCR 失效、KeepAlive 一直
        // 拉不起来(完整机理见 EngineServiceManager.reconcileAfterLaunch 的注释)。
        // 内部自己判断该不该动、并且整段跑在后台串行队列上,这里不会阻塞启动。
        EngineServiceManager.reconcileAfterLaunch()
        // 引擎预解析要问播放器的那几样(Music 的队列与专辑曲目、Spotify 随机、网页版队列)由 App 代跑,
        // 引擎自己不发 AppleEvent(见 PlayerQueryServer)。
        PlayerQueryServer.shared.start()
        // 主线程卡住几秒就记一行、卡久了采一次调用栈(见 MainThreadWatchdog)。
        MainThreadWatchdog.shared.start()

        // 这一句决定 App 是普通应用(占 Dock + 进 Cmd-Tab)还是菜单栏专属应用。build.sh 打包时写了
        // LSUIElement=true(plist 让它默认不占 Dock),这一行按用户的设置再决定要不要占:showInDock 的
        // 兜底是 `?? true`(AppSettings.init),所以新用户走的是 .regular、有 Dock 图标。
        //
        // AppSettings.showInDock 的 didSet 不会在它自己 init() 赋初值这一步触发
        // (Swift 语义,实测见 ConfigPortability.clearAllConfig 上那段),所以这里必须
        // 显式按持久化的值应用一次。
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        // LocalPlaybackSource 自己不读 UserDefaults(它在 LyrimuseCore 里,够不到 AppSettings),下面这几项
        // 启动时不推一次的话它会一直用默认值,用户的选择要等到下次在设置页里改动才生效。
        LocalPlaybackSource.shared.chineseVariant = settings.lyricsChineseVariant
        LocalPlaybackSource.shared.romanizationScripts = settings.romanizationScripts
        LocalPlaybackSource.shared.japaneseReading = settings.japaneseReadingStyle
        LocalPlaybackSource.shared.splitsLongLyricLines = settings.splitLongLyricLines
        LocalPlaybackSource.shared.mergesShortLyricLines = settings.mergeShortLyricLines
        LineLayoutBudgets.shared.start()
        // 校准名单里还没记「校正值对着哪份歌词」的,按现有的单曲偏移补记一次;引擎靠它让同一首歌的别的写法跟着那份
        // 歌词、读穿那个偏移(18 章决策 27)。之后播放到它时 syncPinToOffset 照常更新。
        LyricsOffsetStore.shared.backfillPinContent()
        // 悬浮歌词的「译文」也得让 Core 知道 —— 它**不是**给歌词装载用的(译文转不转由
        // chineseVariant 决定,跟这个开关无关),而是给悬浮歌词 ⚙ 菜单里「简繁转换」那一项的显隐判据用:
        // 译文没在悬浮歌词上时,把一首日文歌的中文机翻转成繁体是一次看不见的改动,那一项就不该
        // 出现(见 LocalPlaybackSource.currentLyricsSupportsChineseVariant 的注释)。那个菜单只在悬浮歌词上,
        // 所以看的是悬浮歌词那份,不是歌词窗口的 showTranslation(04 章决策 42)。
        //
        // 这一项用**订阅**而不是像上面几行那样赋一次值:它有好几个写入点(「内容」浮层、
        // ⚙ 菜单、全局快捷键 GlobalHotkeys、引导页),双写模式漏掉
        // 任何一个都会让判据停在旧值。@Published 在订阅那一刻会先发一次当前值,所以
        // "启动时推一次"也被它一并覆盖了,不需要再单独赋一遍。
        // 闭包里用**参数**、不回头读 AppSettings:@Published 是 willSet 时机发布,那一刻
        // 属性还是旧值(同 startObservingVolumeBannerPreference 上那条注释)。
        settings.$overlayShowTranslation
            .sink { on in
                MainActor.assumeIsolated { LocalPlaybackSource.shared.showsTranslation = on }
            }
            .store(in: &cancellables)
        // 同一个理由:BrowserPositionProbe 也在 LyrimuseCore 里,够不到 AppSettings,
        // 启动时不推一次的话「网页版」卡片里配好的配对要等用户重新打开设置页
        // 才会生效。
        BrowserPositionProbe.shared.platformBrowserPairs = settings.browserPlatformPairs
        // 引擎那几路网页平台探针也只对配对过的浏览器跑(引擎 browserpairs.go),配对关系得镜像进
        // features.json。用订阅:写配对的地方有好几处(设置页、配对 / 取消配对),订阅那一刻先发的当前值顺带把
        // 启动时那一次也写了(没变就不落盘)。闭包里用参数,理由同上面 showTranslation。
        settings.$browserPlatformPairs
            .removeDuplicates()
            .sink { pairs in
                Task { @MainActor in await FeatureSettingsStore.shared.syncBrowserPlatformPairs(pairs) }
            }
            .store(in: &cancellables)
        // 同上:用户手动挑进来的浏览器,它们的引擎族判定结果存在 AppSettings 里,而
        // BrowserAutomationPermission 在 LyrimuseCore 里够不到。不灌这一次的话,重启之后
        // `family(...)` 对这些浏览器返回 nil —— 表现是"我加过的浏览器重启后从配对列表里
        // 消失了",而配对本身还好端端存在 browserPlatformPairs 里。
        BrowserAutomationPermission.manuallyAddedFamilies = settings.manualBrowserFamilies
            .compactMapValues { BrowserAutomationPermission.Family(rawValue: $0) }

        // 状态栏那一项(图标/歌词/滚动歌词 + 下拉菜单)是自建的 NSStatusItem,得在这里显式启动。
        // 生命周期自持(靠 Combine 订阅设置/播放状态),这里只需要点一次。
        //
        // 创建时机尽量往前提:macOS 没有公开 API 能保证第三方状态栏图标的位置,唯一站得住脚、成本几乎
        // 为零的手段是"如果这个 App 恰好跟别的菜单栏 App 同一时刻启动(比如都是登录项),谁先把
        // NSStatusItem 建出来、谁就更可能落在更靠右的位置"这条经验规律(见 MenuBarPositionHint.swift 头注
        // 与 06 章)。
        //
        // 往前只能提到这里,不能再往前:PlaybackCoordinator.start() 依赖上面这几行刚灌完的
        // Core 单例快照(LocalPlaybackSource.chineseVariant/
        // romanizationScripts/showsTranslation、BrowserPositionProbe.platformBrowserPairs、
        // BrowserAutomationPermission.manuallyAddedFamilies)——提前到这些赋值之前的话,
        // PlaybackCoordinator 启动时读到的还是默认值,用户配置的这几项设置每次启动都要等到去设置页里
        // 改一下才生效。往后的中文歌词粘性标记订阅、悬浮歌词/灵动岛窗口创建、通知中心注册、
        // NotchMirrorManager 等都跟状态栏这一项的创建互不相干,能让的同步耗时都让给了它。
        //
        // 没有任何保证:这条经验规律只在"恰好同时启动"时可能生效,对已经在运行的其他
        // 菜单栏 App 完全无效。真正可靠的是引导用户自己 ⌘+拖拽——见
        // MenuBarStatusItem.start() 里那条首次启动一次性提示。
        PlaybackCoordinator.shared.start()
        MenuBarStatusItem.shared.start()

        // Core 见到中文歌词就会置一个粘性标记;这里把它持久化下来,好让"简繁切换"这一项
        // 在下次启动、还没播中文歌之前就已经该露出来(见 SettingsView 里那个条件)。
        if !settings.hasSeenChineseLyrics {
            LocalPlaybackSource.shared.$sawChineseLyrics
                .filter { $0 }
                .first()
                .sink { _ in AppSettings.shared.hasSeenChineseLyrics = true }
                .store(in: &cancellables)
        }

        // 桌面悬浮歌词、灵动岛歌词各自独立开关,互不排斥,可以同时开、只开一个、或都不开。
        // 只对确实开启的那个(些)控制器碰一下 .shared,完全不碰关闭的那个:两个控制器
        // 各自都是 static let shared,真正引用到 .shared 才会执行 init() 建窗口,不主动
        // 碰关闭的那个,它就不会凭空建一个不需要的窗口(见 NotchLyricsWindowController
        // 顶部注释里这条不变量的详细说明)。
        //
        // 别在这里调 setVisible(true):isVisible 是持久化的用户偏好,.shared 的 init() 订阅播放状态的那一刻
        // 就会按恢复出来的 isVisible 显示/隐藏一次;再无条件调 setVisible(true) 会把"用户上次关掉了"覆盖成
        // true 并重新持久化 —— 关掉的灵动岛/悬浮歌词下次打开 App 又自己出现,菜单里的勾选也被悄悄改回。
        // 下面几行 setLocked/setHiddenFromCapture/setHideWhenNotPlaying 本身已经足够触发 .shared 的构造。
        if settings.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.setLocked(settings.lockPosition)
            LyricsOverlayWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
            LyricsOverlayWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
        }
        if settings.notchOverlayEnabled {
            // 读 `notchHide*` 而不是上面悬浮歌词那两个 —— 两个形态各有一份
            // 独立的「自动隐藏」设置,见 AppSettings 里那两段注释。
            NotchLyricsWindowController.shared.setHiddenFromCapture(settings.notchHideDuringScreenCapture)
            NotchLyricsWindowController.shared.setHideWhenNotPlaying(settings.notchHideWhenNotPlaying)
        }

        // media-control 私有通道的一次性自检。只做归因、不做降级 —— 见 MediaControlHealth。
        MediaControlHealth.shared.checkInBackground()
        startObservingScreenLock()
        installScrollForwardMonitor()
        startObservingVolumeBannerPreference()
        // 只 start(),不在这里判断开关 —— 判断在管理器内部,因为"关着"这条路径必须
        // 在碰 NotchLyricsWindowController.shared 之前就 return(碰一下就会凭空建出窗口,
        // 见那个类文件头的不变量)。
        NotchMirrorManager.start()
        // 触控栏歌词(默认关,设置 › 歌词显示 › 触控栏)。开着就把图标放进功能栏。
        TouchBarLyricsController.shared.start()
        // PlaybackCoordinator.shared.start() / MenuBarStatusItem.shared.start() 在上面 BrowserAutomationPermission
        // .manuallyAddedFamilies 那一行之后(状态栏项的创建时机要尽量靠前,见那边的注释)。
        // 「发现新播放器」的系统通知。
        // registerCategory 必须在**投递之前**调:setNotificationCategories 是整表替换,
        // 投递时 categoryIdentifier 查不到的话通知照样显示但**按钮不出现**、而且不报错;
        // delegate 设晚了,冷启动时用户点按钮的回调会丢。授权**不**在这里请求 ——
        // 那只有一次机会,见 UnknownPlayerNotifier.ensureAuthorized。
        UnknownPlayerNotifier.shared.registerCategory()
        UnknownPlayerNotifier.shared.start()
        // 补搜 / 全量扫库跑完时弹一条结果通知。delegate 由上面 registerCategory 设好(点通知的分流在那边)。
        LyricsSweepNotifier.shared.start()
        // Last.fm 授权失效(打卡停了)时弹一条系统通知,点它打开 Last.fm 设置页。
        LastfmMirrorNotifier.shared.start()
        ListenBrainzAuthNotifier.shared.start()
        MediaChannelNotifier.shared.start()
        // Last.fm 账号跟 Spotify 的连接:设置里提示会不会重复记,排除了 Spotify 又过期时弹通知。
        LastfmSpotifyLinkMonitor.shared.start()
        // 换歌时弹一条系统通知(默认关,设置 › 通用 › 通知)。点通知的分流在 UnknownPlayerNotifier 的 delegate。
        NowPlayingNotifier.shared.start()
        // Discord「正在听」(默认关,设置 › Discord)。
        DiscordPresenceController.shared.start()
        // 网页歌词、OBS 输出的本地服务(默认关,设置 › 歌词显示 › 歌词窗口 / 悬浮歌词)。
        WebLyricsServer.startAll()
        // 捕获 openSettings/openWindow 这两个环境 action 的隐藏锚点窗口(见该文件注释)。
        MenuBarSceneActions.install()

        // 打开 Lyrimuse 时顺带启动用户勾选的播放器(逐播放器勾选,见 LyrimuseCore.PlayerLinkage 头注;勾选 ∩
        // 当前候选才算)。只启动还没运行的 —— 已经在跑就什么都不做,不做多余的"带到前台"动作;activates=false
        // 避免用户正在用别的 App 时被抢焦点。
        let playersToLaunch = PlayerLinkage.effective(settings.launchPlayersOnLyrimuseOpen,
                                                      selectedPlayers: FeatureSettingsStore.shared.players)
        for player in playersToLaunch where !player.bundleIdentifier.isEmpty {
            let ids = PlayerBundleAliases.all(for: player.bundleIdentifier)
            if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier.map(ids.contains) ?? false }),
               let playerURL = PlayerBundleAliases.applicationURL(forBundleID: player.bundleIdentifier) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: playerURL, configuration: config)
            }
        }
        // 「跟随播放器退出」的监听,开关空集时它只是订阅着不做事。
        PlayerQuitWatcher.shared.start()
        // 菜单栏菜单顶部「自动化权限未开启」那一行的数据源(引导结束后权限被拒或作废时提示)。
        AutomationAlertMonitor.shared.start()
        // YT Music 广告门槛与自动跳过:灵动岛没开过也得在,自动跳过才生效。没广告、没人要结果时只是订阅着。
        _ = YouTubeMusicAdSkipCenter.shared

        // 首次启动的完整引导向导——触发点在 SceneActionRegistrar.onAppear,不在这里:
        // openWindow(id:) 这个 SwiftUI 环境 action 只有挂载的 View 才能拿到,这个时机
        // (AppDelegate.applicationDidFinishLaunching)早于那扇锚点窗口真正挂载,
        // 这里调用会静默没反应。
        GlobalHotkeys.registerAll()

        // 触发 SparkleUpdaterManager 的懒加载初始化——它的 init() 会以
        // startingUpdater: true 启动 Sparkle 自己的 updater,按 Info.plist 里
        // SUEnableAutomaticChecks 的配置做周期性后台检查,不需要自己维护"查一次/
        // 记录已提示过哪个版本"这套状态(Sparkle 自己管这些)。
        _ = SparkleUpdaterManager.shared
        // 放到下一拍:启动流程里排在这之后的窗口(SwiftUI 默认开的设置窗口)也还算启动阶段。
        DispatchQueue.main.async { LaunchPhase.finish() }
    }

    // 这个 App 没有传统意义上的"主窗口"(内容是菜单栏图标+悬浮歌词窗口+按需打开的
    // 设置/歌词窗口),不实现这个 delegate 方法的话,点 Dock 图标(只在"showInDock"开着、
    // 走 .regular 激活策略时才会有 Dock 图标)完全没有默认行为。
    //
    // 点 Dock 图标**只**弹歌词窗口,任何情况下都不弹设置:设置另有 ⌘, / 菜单栏菜单 / 主菜单三个入口,
    // 不缺这一个。两处刻意的写法,都是为了"不要冒出设置窗":
    //
    // ① **不退回 openSettings**。歌词窗口那个 action 是 SwiftUI 环境 action,由一个隐藏
    //    锚点视图捕获进 AppActions(见 MenuBarSceneActions)。它理论上启动就捕获了,但在
    //    "刚重启、锚点视图还没挂上"那一瞬是 nil —— 那种情况下**不能**退回设置窗口,否则
    //    "点 Dock 弹出设置"照样会发生。宁可这一下什么都不发生(下一下就正常)。
    //
    // ② **返回 false,不给 AppKit 默认行为**。返回 true 等于告诉 AppKit"按你的老规矩来",
    //    而它的老规矩是"把这个 App 的窗口恢复/带回前台" —— 包括用户之前关掉的设置窗
    //    (SwiftUI 的 Settings 场景关掉之后 NSWindow 对象仍然活着,只是 orderOut,
    //    `check-windows` 能看到它 onscreen=false 地挂在那儿)。返回 false = "这次 reopen
    //    我自己处理完了",AppKit 不再多做动作。
    //
    // 不看 hasVisibleWindows:它对本 App **恒为 true**(悬浮/灵动岛的 NSPanel、状态栏窗口都算"可见")。
    // 改看 AuxiliaryWindowActivation.hasAnyOpen:设置/歌词管理/歌词窗口/引导这四扇窗**一扇都没开着**时
    // 才开歌词窗口;只要还有任意一扇开着(哪怕被最小化到 Dock 里),就把开着的窗口带回来(还原被最小化的、
    // 把已有窗口带到前台),不额外抢开歌词窗口。这不会踩上面②的坑:那个坑是"用户明确关掉的设置窗被系统
    // 默认行为带回来";hasAnyOpen 为 true 意味着确实还有窗口**没被关掉**(`.onDisappear` 只在真正关闭时
    // 触发、最小化不触发,AuxiliaryWindowActivation 的 Dock 图标借用/还原逻辑也依赖这条)。
    //
    // "带回来"这一步**自己做**,不能 `return true` 交给 AppKit:AppKit 默认 reopen 只在
    // **没有任何普通窗口可见**时还原**一扇**最小化窗口,有一扇可见就什么都不做——设置窗开着、
    // 歌词窗口最小化时,点 Dock 就会没反应。见 AuxiliaryWindowActivation.bringOpenWindowsForward 的注释。
    //
    // 再补一条兜底,保证**每一下点击都有可见结果**:App **本来就在前台**、开着的窗口也本来就全在
    // 最前面(比如用户正在设置窗里,又去点了一下 Dock 图标;或者上一下点击已经把窗口带回来了、
    // 用户再点一下)时,"带回来"什么都改变不了,这时落回开歌词窗口那条路:要防的是"**替代**还原动作
    // 去抢开歌词窗口",不是"设置开着就永远不准开";歌词窗口本来就在最前面时这一步只是把它再 front 一次。
    //
    // "本来就在前台"这个前提**必须**有:从别的 App 点 Dock 切回来的那一下,激活本身就把窗口带到
    // 前台了(那就是可见结果),这一下不能再多开歌词窗口。判据不能用 NSApp.isActive(reopen 跑的
    // 时候它已经是 true)、也不能只看 didBecomeActive 有没有到——它跟 reopen 谁先到两种顺序都有
    // (多数是 didBecomeActive 早 ~100ms,偶尔 reopen 早 1ms),所以两头都记:
    // didResignActive 把 isActiveForReopen 清掉、didBecomeActive 设上并记时间,reopen 时
    // 「标记还没设上」或「设上不到 1 秒」都算"这一下是切回来的点击"。
    private var isActiveForReopen = false
    private var becameActiveAt = Date.distantPast
    /// 见 applicationShouldHandleReopen —— 延后开歌词窗口的那个任务。
    private var reopenLyricsTask: Task<Void, Never>?
    private let reopenLogger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "reopen")

    func applicationDidBecomeActive(_ notification: Notification) {
        isActiveForReopen = true
        becameActiveAt = Date()
    }

    func applicationDidResignActive(_ notification: Notification) {
        isActiveForReopen = false
    }

    /// 这次 reopen 之前 App 是否早已在前台(而不是被这一下点击激活的)。
    private var wasAlreadyActiveBeforeReopen: Bool {
        isActiveForReopen && Date().timeIntervalSince(becameActiveAt) > 1.0
    }

    /// 这次 reopen 的发送方,进日志:`<pid> <进程路径>`;发送方已经退出、查不到路径时是 `<pid> (exited)`,不是 Apple Event
    /// 送来的是 `(no apple event)`。发送方读 `keySenderPIDAttr`,别读 `keyAddressAttr`:那是目标地址,LaunchServices 送来的
    /// reopen 里是 psn,取不出字符串。见 07 章决策 157。
    private static func reopenSender() -> String {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return "(no apple event)" }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        guard pid > 0 else { return "(no sender pid)" }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "\(pid) (exited)" }
        return "\(pid) \(String(cString: buffer))"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // **点系统通知也会走到这里** —— 系统激活 App 时就会触发 reopen,而那时用户要的是
        // 设置页,不是歌词窗口。
        //
        // 抑制标记放 AppActions(那个单例存在的意义就是这类桥接),**同一个判据查两次** —— 进来时查一次、
        // 延后任务真要开窗前再查一次:通知回调和 reopen 谁先到两种顺序都有(通知回调可能比 reopen 早
        // 约 0.3 秒),只做「延后开窗、通知回调来了就取消」只堵得住 reopen 先到的那一半。通知那边只管设标记、
        // 不需要反过来调我们。别用 `(NSApp.delegate as? AppDelegate)?.…` 去设:那个转型在 SwiftUI 的
        // @NSApplicationDelegateAdaptor 下拿不到我们的 AppDelegate,会无声失败。
        //
        // 顺手记这次 reopen 的发送方(`reopenSender`),查「谁让窗口弹出来」靠它。
        reopenLogger.notice("reopen: hasVisibleWindows=\(flag, privacy: .public) from=\(Self.reopenSender(), privacy: .public)")
        if isLyricsOnReopenSuppressed() {
            reopenLogger.notice("reopen: lyrics window suppressed (immediate)")
            return false
        }
        // 设置/歌词管理/歌词窗口/引导四扇里只要还有一扇开着(哪怕被最小化),就把它们带回来——
        // 还原被最小化的、把最前那扇带到前台;只有一扇都没开、或者 App 本来就在前台且开着的
        // 窗口本来就全在最前面(这一下什么都没变)时才落到下面开歌词窗口。理由见上面声明前那段注释。
        if AuxiliaryWindowActivation.hasAnyOpen {
            let wasActive = wasAlreadyActiveBeforeReopen
            let r = AuxiliaryWindowActivation.bringOpenWindowsForward()
            reopenLogger.notice("reopen: auxiliary window(s) open → restored=\(r.restored, privacy: .public) fronted=\(r.fronted, privacy: .public) alreadyFront=\(r.alreadyFront, privacy: .public) wasActive=\(wasActive, privacy: .public)")
            if r.foundNone {
                // 计数器说有窗口开着、枚举却一扇都没找到:按"一扇都没开"处理,别卡在什么都不做上。
                reopenLogger.notice("reopen: counter says open but no window found, falling through to lyrics window")
                // 顺手把账对平——这一刻正是"计数器跟现实对不上"的现场。不对的话计数器会永久
                // 停在 >0,.accessory 再也还原不回去(见 AuxiliaryWindowActivation.reconcile)。
                AuxiliaryWindowActivation.reconcile(reason: "reopen found no auxiliary window")
            } else if r.alreadyFront && wasActive {
                reopenLogger.notice("reopen: app already in front and nothing to bring forward, falling through to lyrics window")
            } else {
                return false
            }
        }
        reopenLyricsTask?.cancel()
        reopenLyricsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            // 第二道:通知回调可能在这 0.3 秒里才把标记设上(reopen 先到的那种顺序)
            if self.isLyricsOnReopenSuppressed() {
                self.reopenLogger.notice("reopen: lyrics window suppressed (deferred)")
                return
            }
            self.reopenLogger.notice("reopen: opening lyrics window")
            AppActions.shared.openLyricsWindow?()
        }
        return false
    }

    private func isLyricsOnReopenSuppressed() -> Bool {
        guard let until = AppActions.shared.suppressLyricsOnReopenUntil else { return false }
        return Date() < until
    }

    // Cmd+Q / 菜单"退出 Lyrimuse"的正常退出路径。账号设置里的文本字段(Token/API Key 等)是防抖自动保存的,
    // 用户刚打完字就立刻 Cmd+Q 的话,防抖计时器根本没机会触发,那次编辑会随着进程退出彻底丢失;SwiftUI 的
    // .onDisappear 也不保证在进程被终止时对每个视图都执行一遍。所以真正退出前先同步检查 ConfigStore 是否还有
    // 没保存的改动(isDirty):没有就直接放行,不拖慢正常退出;有就用 .terminateLater 暂缓退出,异步存盘
    // 完成后再 reply(toApplicationShouldTerminate:) 放行——不管存盘成功与否都放行,避免磁盘
    // 写入异常时把 Cmd+Q 卡死。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 退出原因日志:所有退出路径的汇合点,在这里打、只打一次。原因由 AppExit.request
        // 登记,没登记的按信号推断(Sparkle 正在装更新 → sparkle_install,否则 external_request)。
        AppExit.logTermination(sparkleInstalling: SparkleUpdaterManager.shared.isInstallingUpdate)
        // 告诉引擎 App 要走了:它据此不再按这份播放状态计时、推送(见 PlaybackStatePublisher)。
        PlaybackStatePublisher.shared.markExiting()
        // 镜像写盘有 2 秒防抖,退出前这 2 秒里改的设置还没进镜像;引导没走完的机器每次启动都会从镜像恢复
        // (restoreIfPristine),不补这一次就会把那几项改动回滚成旧值。
        AppSettingsMirror.write()
        guard ConfigStore.shared.isDirty else { return .terminateNow }
        Task {
            _ = await ConfigStore.shared.save()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - 滚轮兜底转发
    //
    // 为什么需要:设置窗某些位置滚轮滚不动、挪到旁边就好。事件**确实进到了设置窗**(没离开本 App,跟悬浮窗
    // 热区、焦点、别的 App 的透明窗都无关),但 hitTest 停在 NSHostingView<ColumnView> 上、没能走进滚动视图,
    // 而那个滚动视图**包含鼠标点、不隐藏、alpha 满、从它往上每一层都含点**。按 AppKit 语义(点在自己范围内 →
    // 倒序问子视图 → 全 nil 才返回自己),这只能是某个子视图的 hitTest 返回了 nil —— SwiftUI
    // NavigationSplitView 内部的行为,我们改不动,而且同一位置几次采样里树的形状都不一致。
    //
    // 所以不追根因,**替 AppKit 补一次投递**(forwardScrollIfStranded):只在"本来就没人会处理"时介入。
    //
    // 挑目标的四条硬条件,少一条都可能滚错东西:
    //   ① frame(窗口坐标)包含鼠标点;
    //   ② 不隐藏、alpha 足;
    //   ③ **真的有东西可滚**(documentView 大于 contentView)—— 这条把那个空的残留滚动视图、
    //      以及不在指针下的侧边栏排除掉,是"别滚错"的关键;
    //   ④ 多个候选取**面积最小**的(最内层、最具体)。
    private var scrollForwardMonitor: Any?

    private func installScrollForwardMonitor() {
        scrollForwardMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                AppDelegate.forwardScrollIfStranded(event)
            }
        }
    }
    private static let scrollForwardLog = Logger(
        subsystem: "me.yudaotor.lyrimuse", category: "scroll-forward")
    private static var lastForwardLogAt = Date.distantPast

    /// 上一次判定的结果,给同一次滚动手势复用。存 `NSScrollView?` 而不是 Bool:
    /// "放行"和"转发给某个具体视图"都要能原样重放。
    private static var lastScrollDecision: (windowNumber: Int, point: CGPoint,
                                            at: Date, target: NSScrollView?)?

    /// 返回值直接交给监听闭包:nil = 我们已代为处理,event = 原样放行。
    private static func forwardScrollIfStranded(_ event: NSEvent) -> NSEvent? {
        guard let win = event.window else { return event }
        let loc = event.locationInWindow
        // **必须缓存这个判定**:下面那句 `root?.hitTest(loc)` 会把整个窗口的 SwiftUI 视图树递归走一遍
        // (`NSThemeFrame._performHitTestForContext` → `NSHostingView.hitTest` → … → `MultiViewResponder
        // .containsGlobalPoints` 的深度递归,主线程采样里能占到 74/1439)。这个函数装在**全局滚轮监视器**里,
        // 触控板惯性滚动每秒发几十到上百个事件,每个都重算就是每秒几十到上百次全窗口递归命中测试压在主线程上,
        // 页面越深越卡(设置页 Last.fm 那一页最长最深,最明显;卡顿跟 Last.fm 的数据链路无关)。
        //
        // 滚动手势期间指针本来就不动,判定一次就够:同窗口 + 指针没挪 + 没过期 → 直接重放上次结论。
        let nowDate = Date()
        if let cached = lastScrollDecision,
           ScrollForwardDecision.canReuse(cachedWindow: cached.windowNumber,
                                          cachedPoint: cached.point, cachedAt: cached.at,
                                          window: win.windowNumber, point: loc, now: nowDate),
           cached.target == nil || cached.target?.window === win {
            // 目标得还挂在这扇窗里:0.25 秒内切了页,旧的滚动视图已经脱离窗口,再交给它就滚不动 —— 那种情况重新判。
            guard let cachedTarget = cached.target else { return event }
            cachedTarget.scrollWheel(with: event)
            return nil
        }
        let root = win.contentView?.superview ?? win.contentView
        // 命中测试本来就能走进滚动视图 → 正常路径,**绝不插手**。
        var v = root?.hitTest(loc)
        var depth = 0
        while let cur = v, depth < 12 {
            if cur is NSScrollView {
                lastScrollDecision = (win.windowNumber, loc, nowDate, nil)
                return event
            }
            v = cur.superview
            depth += 1
        }
        guard let target = fallbackScrollTarget(in: win, at: loc) else {
            lastScrollDecision = (win.windowNumber, loc, nowDate, nil)
            return event
        }
        lastScrollDecision = (win.windowNumber, loc, nowDate, target)
        let now = Date()
        if now.timeIntervalSince(lastForwardLogAt) > 0.5 {
            lastForwardLogAt = now
            let f = target.convert(target.bounds, to: nil)
            scrollForwardLog.notice("""
                兜底转发 win=\(win.title, privacy: .public) \
                at=(\(Int(loc.x), privacy: .public),\(Int(loc.y), privacy: .public)) \
                → \(String(describing: type(of: target)), privacy: .public)\
                (\(Int(f.minX), privacy: .public),\(Int(f.minY), privacy: .public) \
                \(Int(f.width), privacy: .public)x\(Int(f.height), privacy: .public))
                """)
        }
        target.scrollWheel(with: event)
        return nil
    }

    /// 见上面那段注释里的四条硬条件。
    private static func fallbackScrollTarget(in window: NSWindow, at loc: NSPoint) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        var all: [NSScrollView] = []
        var stack = root.subviews
        while let v = stack.popLast() {
            if let sv = v as? NSScrollView { all.append(sv) }
            stack.append(contentsOf: v.subviews)
        }
        return all
            .filter { sv in
                guard !sv.isHidden, sv.alphaValue > 0.99 else { return false }
                let f = sv.convert(sv.bounds, to: nil)
                guard f.contains(loc), f.width > 1, f.height > 1 else { return false }
                guard let doc = sv.documentView else { return false }
                return doc.bounds.height > sv.contentView.bounds.height + 1
                    || doc.bounds.width > sv.contentView.bounds.width + 1
            }
            .min { a, b in
                let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
                return fa.width * fa.height < fb.width * fb.height
            }
    }

    /// 看不见歌词的三种情况,任意一个成立就停逐字渲染:锁屏、熄屏(不一定锁屏,取决于「需要密码」的延迟)、
    /// 快速切换到另一个用户。分开记、合起来判:熄屏之后又锁上,醒来时屏幕亮了但还锁着,不能提前恢复。
    private var screenIsLocked = false
    private var screensAreAsleep = false
    private var sessionIsInactive = false

    private func applyScreenHidden() {
        let hidden = screenIsLocked || screensAreAsleep || sessionIsInactive
        LocalPlaybackSource.shared.setScreenLocked(hidden)
        ScreenVisibility.shared.setHidden(hidden)
    }

    /// 锁屏/解锁、熄屏/唤醒、切换用户时暂停或恢复歌词那一拍(三种情况合起来判,见 applyScreenHidden 上面那段)。
    ///
    /// 锁屏那两个通知在 **DistributedNotificationCenter**,不是 NotificationCenter.default
    /// 也不是 NSWorkspace 的那个 —— 挂错地方会静默永不触发。
    /// 只暂停渲染,不碰 2 秒 poll(理由见 LocalPlaybackSource.setScreenLocked)。
    private func startObservingScreenLock() {
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            center.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenIsLocked = locked
                    self?.applyScreenHidden()
                }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(NSNotification.Name, (AppDelegate) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.screensAreAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.screensAreAsleep = false }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.sessionIsInactive = true }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionIsInactive = false }),
        ]
        for (name, update) in workspaceEvents {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    update(self)
                    self.applyScreenHidden()
                }
            }
        }
    }


    /// 音量提示跟着灵动岛开关走 —— 灵动岛关着的话提示条根本没有地方显示,挂 CoreAudio
    /// 监听也只是白监听。
    ///
    /// sink 闭包里用的是**参数**而不是回头去读 AppSettings:@Published 在 willSet 时机
    /// 发布,那一刻属性还是旧值。
    private func startObservingVolumeBannerPreference() {
        AppSettings.shared.$notchOverlayEnabled
            .sink { notchEnabled in
                MainActor.assumeIsolated {
                    VolumeMonitor.apply(enabled: notchEnabled)
                    OutputDeviceAnnouncer.apply(enabled: notchEnabled)
                }
            }
            .store(in: &cancellables)
    }
}
