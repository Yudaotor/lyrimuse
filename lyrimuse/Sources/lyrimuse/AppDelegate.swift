import AppKit
import Combine
import OSLog
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
        terminateOlderInstances()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    // 同一个 App 同时跑起两份时,把**比自己老**的那几份请走,只留最新启动的这一个。
    //
    // 2026-08-09 实测抓到过双实例:开机自启走的是 LaunchAgent(label me.yudaotor.lyrimuse,
    // 直接 exec 二进制),而从访达/聚焦/Dock 再打开一次会另外注册成一个 application.* 的
    // job —— LaunchServices 那条"同一个 bundle 只开一份"的常规约束拦不住前者起的那份,
    // 于是两个实例并存。表现相当隐蔽:两扇桌面悬浮歌词窗**坐标完全重合**,两边各自独立
    // 解析歌词,切歌那几秒进度不同步,看上去就是"一次显示了两首歌的词",等两边收敛到同一句
    // 之后文字完全重叠又"自己好了"。除了显示,两份实例还会各跑一套轮询、各自 scrobble。
    //
    // 选"新的赢"而不是"老的赢":用户刚刚双击打开、或刚装了新版本重启,期待生效的都是新
    // 启动的这一份;开发时 build.sh 换完二进制重启,也该是新二进制接管。
    //
    // 只请走**严格早于**自己启动的那几份,避免两份几乎同时起来时互相踢掉、一个都不剩。
    //
    // ⚠️ 判先后**不能**用 NSRunningApplication.launchDate:那个字段只有经 LaunchServices
    // 启动(双击/open)的进程才有,而这里最要防的恰恰是 LaunchAgent 直接 exec 二进制起来的
    // 那一份 —— 它的 launchDate 是 nil。2026-08-09 第一版就是用 launchDate 写的,实测三个
    // 实例并存、守卫一次都没触发,探针打出来两个实例的 launchDate 全是 nil。
    // 改用 sysctl 读内核记的真实进程启动时间,对任何来路的进程都有效。
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
            NSLog("lyrimuse: terminating older instance pid %d", other.processIdentifier)
            other.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !other.isTerminated {
                    NSLog("lyrimuse: older instance pid %d ignored terminate, forcing",
                          other.processIdentifier)
                    other.forceTerminate()
                }
            }
        }
    }

    /// 进程启动时间(Unix 秒),取自内核的 kinfo_proc。任何来路的进程都有,不像
    /// NSRunningApplication.launchDate 只对经 LaunchServices 启动的有效。
    private var cancellables = Set<AnyCancellable>()

    /// Dock 图标右键菜单的自定义部分(设置/歌词管理/歌词窗口/Last.fm 四个跳转)。
    /// 见 DockMenu.swift 顶部注释——跟 applicationDockMenu(_:) 配对使用。
    private let dockMenuController = DockMenuController()

    /// 2026-08-26 用户对照 Apple Music 自己的 Dock 菜单要求加的常用跳转,见
    /// DockMenuController 顶部注释。这里返回的菜单会被 AppKit 摆在它自动追加的那部分
    /// (窗口列表/"选项"子菜单/显示所有窗口/隐藏/退出)**上面**,不需要在这个方法里
    /// 重复那些系统默认项。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenuController.makeMenu()
    }

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
              let url = URL(string: urlString), url.scheme == "lyrimuse" else {
            return
        }
        // 目前只有这一种回调用途,不需要按 host/path 再分流;后续如果这个 scheme 挂了
        // 别的用途,再在这里加判断。
        LastfmConnectController.shared.handleAuthCallback()
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        // 「开机启动」默认是开的(见 AppSettings.init),但那处赋值不触发 didSet,系统层面
        // 并不会因此注册登录项。这里补一次,让默认值真的算数。SMAppService 的注册是幂等的,
        // 已经注册过再调一次没有副作用;用户手动关掉之后这里读到 false,也不会偷偷再打开。
        if AppSettings.shared.launchAtLoginEnabled {
            LoginItemManager.shared.setEnabled(true)
        }
        // ⚠️ 必须是这个函数的第一件事:AppSettings 在 init 里一次性把所有属性从 UserDefaults
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
        // 重新下载(审阅确认)。给共享缓存一个像样的容量,磁盘部分跨启动依然有效。
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
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

        // ConfigStore/FeatureSettingsStore 写配置文件、collector 自己写歌词/封面缓存都
        // 假设这个目录已经存在，但谁都不会在写之前 createDirectory——这里无条件、幂等
        // 地建一次，不依赖引导流程是否跑完，第一次启动就先把这个目录建好。
        try? FileManager.default.createDirectory(
            at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lyrimuse"),
            withIntermediateDirectories: true)

        // collector 的 launchd job 对账。必须在启动路径上跑,这是 Sparkle 自动更新 /
        // Homebrew cask upgrade / 手动拖 .app 覆盖这三条路唯一的兜底 —— 它们都不经过
        // build.sh,而换掉 collector 二进制会让 launchd 缓存的 LWCR 失效、KeepAlive 一直
        // 拉不起来(完整机理见 CollectorServiceManager.reconcileAfterLaunch 的注释)。
        // 内部自己判断该不该动、并且整段跑在后台串行队列上,这里不会阻塞启动。
        CollectorServiceManager.reconcileAfterLaunch()

        // 这一句决定 App 是普通应用(占 Dock + 进 Cmd-Tab)还是菜单栏专属应用。
        //
        // ⚠️ 2026-08-13 更正:这段原来写"默认(没碰过'在 Dock 中显示'这个设置的人)是
        // .accessory"、"不需要 Info.plist 的 LSUIElement" —— 两句都不对。showInDock 的
        // 兜底是 `?? true`(AppSettings.init),所以新用户走的是 .regular、**有** Dock 图标;
        // 而 build.sh 打包时确实写了 LSUIElement=true,是这里在启动时把它翻回 .regular。
        // 两处一起看才说得通:plist 让它默认不占 Dock,这一行按用户的设置再决定要不要占。
        //
        // AppSettings.showInDock 的 didSet 不会在它自己 init() 赋初值这一步触发
        // (Swift 语义,实测见 ConfigPortability.clearAllConfig 上那段),所以这里必须
        // 显式按持久化的值应用一次。
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        LocalPlaybackSource.shared.preferWordLevelKaraoke = settings.preferWordLevelKaraoke

        LocalPlaybackSource.shared.chineseVariant = settings.lyricsChineseVariant
        // 跟上面两行同一个理由:LocalPlaybackSource 自己不读 UserDefaults(它在
        // LyrimuseCore 里,够不到 AppSettings),启动时不推一次的话它会一直用默认值,
        // 用户的选择要等到下次在设置页里改动才生效。
        LocalPlaybackSource.shared.romanizationScripts = settings.romanizationScripts
        // 「显示翻译」也得让 Core 知道 —— 它**不是**给歌词装载用的(译文转不转由
        // chineseVariant 决定,跟这个开关无关),而是给「简繁转换」那一项的显隐判据用:
        // 译文没在屏幕上时,把一首日文歌的中文机翻转成繁体是一次看不见的改动,那一项就不该
        // 出现(2026-09-02 用户报「播日文歌为什么也显示简繁转换」,见
        // LocalPlaybackSource.currentLyricsSupportsChineseVariant 的注释)。
        //
        // 这一项用**订阅**而不是像上面几行那样赋一次值:它有三个写入点(设置页的开关、
        // 歌词窗口「⋯」菜单里的显示/隐藏翻译、全局快捷键 GlobalHotkeys),双写模式漏掉
        // 任何一个都会让判据停在旧值。@Published 在订阅那一刻会先发一次当前值,所以
        // "启动时推一次"也被它一并覆盖了,不需要再单独赋一遍。
        // ⚠️ 闭包里用**参数**、不回头读 AppSettings:@Published 是 willSet 时机发布,那一刻
        // 属性还是旧值(同 startObservingVolumeBannerPreference 上那条注释)。
        settings.$showTranslation
            .sink { on in
                MainActor.assumeIsolated { LocalPlaybackSource.shared.showsTranslation = on }
            }
            .store(in: &cancellables)
        // 同一个理由:BrowserPositionProbe 也在 LyrimuseCore 里,够不到 AppSettings,
        // 启动时不推一次的话"浏览器歌词同步"卡片里配好的配对要等用户重新打开设置页
        // 才会生效。
        BrowserPositionProbe.shared.platformBrowserPairs = settings.browserPlatformPairs
        // 同上:用户手动挑进来的浏览器,它们的引擎族判定结果存在 AppSettings 里,而
        // BrowserAutomationPermission 在 LyrimuseCore 里够不到。不灌这一次的话,重启之后
        // `family(...)` 对这些浏览器返回 nil —— 表现是"我加过的浏览器重启后从配对列表里
        // 消失了",而配对本身还好端端存在 browserPlatformPairs 里。
        BrowserAutomationPermission.manuallyAddedFamilies = settings.manualBrowserFamilies
            .compactMapValues { BrowserAutomationPermission.Family(rawValue: $0) }

        // 状态栏那一项(图标/歌词/滚动歌词 + 下拉菜单)。2026-08-16 之前这是 App.swift 里
        // 的一个 MenuBarExtra 场景,现在是自建的 NSStatusItem,得在这里显式启动。
        // 生命周期自持(靠 Combine 订阅设置/播放状态),这里只需要点一次。
        //
        // 2026-09-01 从原来排在 collector 对账、悬浮歌词/灵动岛窗口创建、通知中心注册、
        // NotchMirrorManager 等一堆重活之后,挪到了这里——用户要求"把图标挪到贴近系统
        // 图标的位置",调研结论(见 MenuBarPositionHint.swift 头注 / docs/features/
        // 06-menubar.md):macOS 没有公开 API 能保证第三方状态栏图标的位置,唯一站得住脚、
        // 成本几乎为零的手段是"如果这个 App 恰好跟别的菜单栏 App 同一时刻启动(比如都是
        // 登录项),谁先把 NSStatusItem 建出来、谁就更可能落在更靠右的位置"这条经验规律——
        // 所以把创建时机尽量往前提,减少建项之前要跑的同步代码。
        //
        // 往前只能提到这里,不能再往前:PlaybackCoordinator.start() 依赖上面这几行刚灌完的
        // Core 单例快照(LocalPlaybackSource.preferWordLevelKaraoke/chineseVariant/
        // romanizationScripts/showsTranslation、BrowserPositionProbe.platformBrowserPairs、
        // BrowserAutomationPermission.manuallyAddedFamilies)——提前到这些赋值之前的话,
        // PlaybackCoordinator 启动时读到的还是默认值,后果是"用户配置的这几项设置每次
        // 启动都要等到去设置页里改一下才生效"。而往后的中文歌词粘性标记订阅、悬浮歌词/
        // 灵动岛窗口创建、通知中心注册、NotchMirrorManager 等都跟状态栏这一项的创建互不
        // 相干,能让的同步耗时都在这里让给了它。
        //
        // ⚠️ 没有任何保证:这条经验规律只在"恰好同时启动"时可能生效,对已经在运行的其他
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
            // ⚠️ 读 `notchHide*` 而不是上面悬浮歌词那两个 —— 2026-09-01 起两个形态各有一份
            // 独立的「自动隐藏」设置,见 AppSettings 里那两段注释。
            NotchLyricsWindowController.shared.setHiddenFromCapture(settings.notchHideDuringScreenCapture)
            NotchLyricsWindowController.shared.setHideWhenNotPlaying(settings.notchHideWhenNotPlaying)
        }

        // media-control 私有通道的一次性自检。只做归因、不做降级 —— 见 MediaControlHealth。
        MediaControlHealth.shared.checkInBackground()
        startObservingScreenLock()
        installScrollForwardMonitor()
        startObservingVolumeBannerPreference()
        // ⚠️ 只 start(),不在这里判断开关 —— 判断在管理器内部,因为"关着"这条路径必须
        // 在碰 NotchLyricsWindowController.shared 之前就 return(碰一下就会凭空建出窗口,
        // 见那个类文件头的不变量)。
        NotchMirrorManager.start()
        // ⚠️ 临时诊断(2026-09-03,用户报「切到别的 App 全屏就被弹回桌面」):定位到根因后
        // 连同 Diagnostics/SpaceDiagnostics.swift 整个删掉,见那个文件的头注。
        SpaceDiagnostics.start()
        // PlaybackCoordinator.shared.start() / MenuBarStatusItem.shared.start() 挪到上面
        // BrowserAutomationPermission.manuallyAddedFamilies 那一行之后了(2026-09-01,
        // 见那边的注释)——状态栏项的创建时机要尽量靠前。
        // 「发现新播放器」的系统通知(2026-08-22 用户报「没有通知机制」)。
        // registerCategory 必须在**投递之前**调:setNotificationCategories 是整表替换,
        // 投递时 categoryIdentifier 查不到的话通知照样显示但**按钮不出现**、而且不报错;
        // delegate 设晚了,冷启动时用户点按钮的回调会丢。授权**不**在这里请求 ——
        // 那只有一次机会,见 UnknownPlayerNotifier.ensureAuthorized。
        UnknownPlayerNotifier.shared.registerCategory()
        UnknownPlayerNotifier.shared.start()
        // 捕获 openSettings/openWindow 这两个环境 action 的隐藏锚点窗口。原来这件事挂在
        // MenuBarExtra 的 label 上,随 MenuBarExtra 一起没了 —— 见该文件注释。
        MenuBarSceneActions.install()

        // 打开 Lyrimuse 时顺带唤起当前选定的播放器(可选,见 AppSettings.
        // launchMusicOnLyrimuseOpen 注释)。跟着 PlaybackPlayerPreference.soleExplicitPlayer
        // 走,不再写死 Apple Music——选了 QQ 音乐时唤起的应该是 QQ 音乐,不是一个用户压根
        // 没在用的 App。2026-09-01 多选后:只有恰好能唯一确定一个具体播放器时才有明确
        // 的目标可唤起(纯 auto、或者同时选了两个以上具体播放器,都没有唯一答案,跟单选
        // 年代 .auto 的"bundleIdentifier 为空、天然 no-op"是同一个道理,不猜)。只在目标
        // App 还没运行时才启动它——已经在跑就什么都不做,不做多余的"带到前台"动作,
        // 避免用户正在用别的 App 时被意外抢焦点。
        if settings.launchMusicOnLyrimuseOpen {
            let bundleID = PlaybackPlayerPreference.soleExplicitPlayer?.bundleIdentifier ?? ""
            if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }),
               let playerURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: playerURL, configuration: config)
            }
        }

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
    }

    // 这个 App 没有传统意义上的"主窗口"(内容是菜单栏图标+悬浮歌词窗口+按需打开的
    // 设置/歌词窗口),不实现这个 delegate 方法的话,点 Dock 图标(只在"showInDock"开着、
    // 走 .regular 激活策略时才会有 Dock 图标)完全没有默认行为。
    //
    // 2026-08-21 按用户要求:点 Dock 图标**只**弹歌词窗口,任何情况下都不弹设置。
    // (原来那版参照 Bartender/iStat Menus 这类纯配置型工具"把设置页当唯一主窗口"的做法
    // —— 那类工具除了设置页没有别的可看,这里不一样;设置另有 ⌘, / 菜单栏菜单 / 主菜单
    // 三个入口,不缺这一个。)
    //
    // 两处刻意的写法,都是为了"不要冒出设置窗":
    //
    // ① **不再退回 openSettings**。歌词窗口那个 action 是 SwiftUI 环境 action,由一个隐藏
    //    锚点视图捕获进 AppActions(见 MenuBarSceneActions)。它理论上启动就捕获了,但在
    //    "刚重启、锚点视图还没挂上"那一瞬是 nil —— 上一版在那种情况下退回设置窗口,于是
    //    "点 Dock 弹出设置"照样会发生。宁可这一下什么都不发生(下一下就正常),也不要弹出
    //    用户明确说不想看的窗。
    //
    // ② **返回 false,不给 AppKit 默认行为**。返回 true 等于告诉 AppKit"按你的老规矩来",
    //    而它的老规矩是"把这个 App 的窗口恢复/带回前台" —— 包括用户之前关掉的设置窗
    //    (SwiftUI 的 Settings 场景关掉之后 NSWindow 对象仍然活着,只是 orderOut,实测
    //    `check-windows` 能看到它 onscreen=false 地挂在那儿)。返回 false = "这次 reopen
    //    我自己处理完了",AppKit 不再多做动作,于是只有歌词窗口会出来。
    //
    // 不看 hasVisibleWindows(系统给的这个参数只反映"当前有没有窗口**可见**",最小化的
    // 窗口会让它变 false,不足以回答"这几扇窗口有没有任意一扇还开着"),改看
    // AuxiliaryWindowActivation.hasAnyOpen——2026-08-25 用户进一步收窄了这条规则:
    // 只有在设置/歌词管理/歌词窗口/引导这四扇窗**一扇都没开着**时,才顺便开歌词窗口;
    // 只要还有任意一扇开着(哪怕被最小化到 Dock 里),就交还给 AppKit 的默认 reopen 行为
    // (还原被最小化的窗口、把已有窗口带到前台),不再额外抢开歌词窗口。这不会重新踩上面
    // ②警告过的坑:那个坑是"用户明确关掉的设置窗被系统默认行为带回来";而 hasAnyOpen
    // 为 true 时,意味着确实还有窗口**没被关掉**(`.onDisappear` 只在真正关闭时触发,
    // AuxiliaryWindowActivation 的 Dock 图标借用/还原逻辑早就在依赖这条),不会误判"已关闭"
    // 为"开着"。
    /// 见 applicationShouldHandleReopen —— 延后开歌词窗口的那个任务。
    private var reopenLyricsTask: Task<Void, Never>?
    private let reopenLogger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "reopen")

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // ⚠️ **点系统通知也会走到这里** —— 系统激活 App 时就会触发 reopen,而那时用户要的是
        // 设置页,不是歌词窗口(2026-08-22 用户报「点击通知怎么还打开了歌词窗口」)。
        //
        // 两次踩坑的教训都写在这儿,别再走回去:
        //  ① 第一版只做「延后 0.3 秒开窗、通知回调来了就取消」—— 只堵了"reopen 先到"
        //     那一半。实测真实顺序是反的:didReceive 10:48:46.878 → reopen 10:48:47.171,
        //     取消跑在前面、扑了个空。
        //  ② 第二版加了抑制窗口,但通知回调是用 `(NSApp.delegate as? AppDelegate)?.…`
        //     来设的 —— 那个转型在 SwiftUI 的 @NSApplicationDelegateAdaptor 下**拿不到**
        //     我们的 AppDelegate,**无声失败**(日志里那行 suppressed 从来没出现过就是证据;
        //     那也是全仓唯一一处 NSApp.delegate 用法,本来就没有先例可参照)。
        //
        // 现在的形态:标记放 AppActions(那个单例存在的意义就是这类桥接),**同一个判据
        // 查两次** —— 进来时查一次、延后任务真要开窗前再查一次。一个机制盖住两种顺序,
        // 通知那边只管设标记、不需要反过来调我们。
        //
        // 顺手记这次 reopen 的发起方:哪天想换成"按发起方精确区分"就有依据。
        // ⚠️ 实测 `open -b`(Dock 点击发的同一个事件)拿到的是 `(no AE)`,取不到发起方,
        // 所以**别**指望靠它区分 —— 这条路试过,走不通。
        let aeSender = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?
            .stringValue ?? "(no AE)"
        reopenLogger.notice("reopen: hasVisibleWindows=\(flag, privacy: .public) from=\(aeSender, privacy: .public)")
        if isLyricsOnReopenSuppressed() {
            reopenLogger.notice("reopen: lyrics window suppressed (immediate)")
            return false
        }
        // 设置/歌词管理/歌词窗口/引导四扇里只要还有一扇开着(哪怕被最小化),就交还给
        // AppKit 的默认 reopen 行为——还原被最小化的窗口、把已有窗口带到前台;只有一扇
        // 都没开时才顺便开歌词窗口。理由见上面 applicationShouldHandleReopen 声明前那段注释。
        if AuxiliaryWindowActivation.hasAnyOpen {
            reopenLogger.notice("reopen: auxiliary window(s) already open, deferring to AppKit default")
            return true
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

    /// 锁屏/解锁时暂停或恢复 20Hz 的逐字渲染。
    ///
    /// ⚠️ 这两个通知在 **DistributedNotificationCenter**,不是 NotificationCenter.default
    /// 也不是 NSWorkspace 的那个 —— 挂错地方会静默永不触发。
    /// 只暂停渲染,不碰 2 秒 poll(理由见 LocalPlaybackSource.setScreenLocked)。
    // MARK: - 滚轮兜底转发
    //
    // 2026-08-18 装的诊断探针(每个进到本 App 的滚轮事件都记一遍命中测试的完整视图层级链)
    // 已经在 2026-08-27 删掉:它当年是为了定位"设置窗某些位置滚不动"这个 bug,根因确实
    // 靠它三轮实测钉死了(见下面注释),但探针本身此后一直原样留着继续跑,诊断导出里
    // 一份 24 小时日志能出现好几条几百字符长的视图层级 dump,对当年那次调查已经没有任何
    // 价值,纯粹是噪音。真正的修复(下面的 forwardScrollIfStranded)不依赖探针,继续保留。
    private var scrollForwardMonitor: Any?

    private func installScrollForwardMonitor() {
        scrollForwardMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                AppDelegate.forwardScrollIfStranded(event)
            }
        }
    }
    //
    // 为什么需要:2026-08-18 用户连报五次「设置窗某些位置滚不动、挪到旁边就好」。三轮探针把
    // 事实钉死了 —— 事件**确实进到了设置窗**,但 hitTest 停在 NSHostingView<ColumnView> 上、
    // 没能走进滚动视图;而那个滚动视图**包含鼠标点、不隐藏、alpha 满、从它往上每一层都含点**
    // (日志里一个 ✗ 都没有)。按 AppKit 语义(点在自己范围内 → 倒序问子视图 → 全 nil 才返回
    // 自己),这只能是某个子视图的 hitTest 返回了 nil。那是 SwiftUI NavigationSplitView 内部
    // 的行为,我们改不动;而且两次采样里树的形状还不一致(辅助功能树报内容滚动区
    // (220,33 680x487),探针在同一宿主视图子树里找到的是 (0,33 900x519),不是同一个)。
    //
    // 所以不追根因,改成**替 AppKit 补一次投递**:只在"本来就没人会处理"时介入。
    //
    // 之前四轮误判的教训一并记在这:先怀疑悬浮窗胶囊热区(实际用户 lockPosition 开着、胶囊
    // 压根不渲染)、再怀疑焦点(用户实测点了没用)、再怀疑微信那扇 layer=3 透明窗和液态玻璃层
    // (探针证明事件根本没离开本 App)。**每一次都是靠日志/实测打回来的,不是靠想。**
    //
    // ⚠️ 挑目标的四条硬条件,少一条都可能滚错东西:
    //   ① frame(窗口坐标)包含鼠标点;
    //   ② 不隐藏、alpha 足;
    //   ③ **真的有东西可滚**(documentView 大于 contentView)—— 这条把那个空的残留滚动视图、
    //      以及不在指针下的侧边栏排除掉,是"别滚错"的关键;
    //   ④ 多个候选取**面积最小**的(最内层、最具体)。
    private static let scrollForwardLog = Logger(
        subsystem: "me.yudaotor.lyrimuse", category: "scroll-forward")
    private static var lastForwardLogAt = Date.distantPast

    /// 上一次判定的结果,给同一次滚动手势复用。⚠️ 存 `NSScrollView?` 而不是 Bool:
    /// "放行"和"转发给某个具体视图"都要能原样重放。
    private static var lastScrollDecision: (windowNumber: Int, point: CGPoint,
                                            at: Date, target: NSScrollView?)?

    /// 返回值直接交给监听闭包:nil = 我们已代为处理,event = 原样放行。
    private static func forwardScrollIfStranded(_ event: NSEvent) -> NSEvent? {
        guard let win = event.window else { return event }
        let loc = event.locationInWindow
        // ⚠️ **必须缓存这个判定**(2026-09-02,真机 `sample` 抓栈坐实的性能 bug)。
        //
        // 用户报「设置页 Last.fm 那一段往下滑就卡、严重时整个 App 无响应要强制退出」,两台
        // 机器都遇到。抓到的主线程栈里,这个函数下面挂着 **74/1439 个采样**,而且下面是
        // 一整条 `-[NSThemeFrame _performHitTestForContext:]` → `NSHostingView.hitTest` →
        // `PlatformHitTestingManager.hitTest` → `MultiViewResponder.containsGlobalPoints`
        // 的**深度递归** —— 也就是说下面那句 `root?.hitTest(loc)` 会把整个窗口的 SwiftUI
        // 视图树递归走一遍。
        //
        // 而这个函数装在**全局滚轮监视器**里:触控板惯性滚动每秒发几十到上百个事件,于是
        // 每秒就有几十到上百次全窗口递归命中测试压在主线程上。页面越深越卡 —— 设置页
        // Last.fm 那一段正好是最长最深的一页,所以在那儿最明显。
        //
        // ⚠️ 排查时曾经一路怀疑 Last.fm 的数据链路(冷缓存、每行的播放次数请求、封面兜底、
        // 简繁写法索引…),**全部是错的方向**:这跟 Last.fm 一点关系都没有,是个全局的、
        // 任何窗口任何页面都在付的成本,只是那一页把它放大到了看得见。**别再顺着数据层查。**
        //
        // 修法不动判定逻辑本身,只是不再每个事件都重算:滚动手势期间指针本来就不动,
        // 判定一次就够。同窗口 + 指针没挪 + 没过期 → 直接重放上次结论。
        let nowDate = Date()
        if let cached = lastScrollDecision,
           ScrollForwardDecision.canReuse(cachedWindow: cached.windowNumber,
                                          cachedPoint: cached.point, cachedAt: cached.at,
                                          window: win.windowNumber, point: loc, now: nowDate) {
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

    private func startObservingScreenLock() {
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            center.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    LocalPlaybackSource.shared.setScreenLocked(locked)
                }
            }
        }
    }


    /// 音量提示跟着灵动岛开关走 —— 灵动岛关着的话提示条根本没有地方显示,挂 CoreAudio
    /// 监听也只是白监听。
    ///
    /// 2026-08-17 去掉了它自己那个开关(原来还要 && notchVolumeBanner),固定随灵动岛开启。
    ///
    /// ⚠️ sink 闭包里用的是**参数**而不是回头去读 AppSettings:@Published 在 willSet 时机
    /// 发布,那一刻属性还是旧值(本项目已实测踩过这个坑)。
    private func startObservingVolumeBannerPreference() {
        AppSettings.shared.$notchOverlayEnabled
            .sink { notchEnabled in
                MainActor.assumeIsolated {
                    VolumeMonitor.apply(enabled: notchEnabled)
                }
            }
            .store(in: &cancellables)
    }
}
