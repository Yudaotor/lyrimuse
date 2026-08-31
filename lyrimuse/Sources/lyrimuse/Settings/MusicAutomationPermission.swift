import AppKit
import CoreServices
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "automation-permission")

// 查/请求"自动化"权限(允许这个 App 用 Apple Event 控制 Music.app)——只覆盖
// Lyrimuse 自己这一份身份,给 AppleMusicPositionClient 读精确播放进度用。
// collector 采集器是完全独立的系统进程/独立签名身份,自己也会发同类 Apple Event
// (专辑预取、它自己的精确进度),但那是 TCC 数据库里单独一条记录——这里没有任何
// API 能查到或触发它,设置页面对 collector 那份只给一句说明文字+跳系统设置的按钮。
//
// 用到的 AEDeterminePermissionToAutomateTarget/AECreateDesc 是老的 Apple Event
// Manager API:noErr(0)=已授权、errAEEventNotPermitted(-1743)=已拒绝、
// errAEEventWouldRequireUserConsent(-1744)=还没问过(askIfNeeded=false 时不会弹窗,
// 只读现状)、procNotFound(-600)=目标应用标识符查不到(极端情况,当"还没问过"处理)。
// event class/id 用 typeWildCard 是 Apple 文档里"查这个 App 整体自动化权限"的标准
// 写法,不是针对某个具体事件。
enum MusicAutomationPermissionStatus {
    case authorized
    case denied
    case notDetermined

    var isAuthorized: Bool { self == .authorized }
}

enum MusicAutomationPermission {
    private static let musicBundleID = "com.apple.Music"

    // askIfNeeded=true 且当前还没问过时,这一步会真的弹出系统的自动化授权对话框——
    // 跟第一次真的发送 Apple Event 弹出的是同一个系统机制,不是自己画的假弹窗。
    // 已经问过(不管授权还是拒绝)时,系统不会重复弹窗,直接照原样返回结果。
    @discardableResult
    static func check(askIfNeeded: Bool) -> MusicAutomationPermissionStatus {
        check(bundleID: musicBundleID, askIfNeeded: askIfNeeded)
    }

    /// 同上,但目标可以是任意 App(2026-08-31 加:浏览器歌词同步也要问同一份权限 ——
    /// `BrowserPositionProbe` 靠 Apple Event 让浏览器执行 JS,跟读 Music.app 播放头是
    /// **同一个** TCC 类别,只是目标换成了 Chrome/Edge/Arc/Safari)。
    ///
    /// ⚠️ **目标 App 没在运行时问不出来** —— 见 `requestWithTimeout` 上那段 2026-07-24 的
    /// 实测记录:那时 `AECreateDesc` 按 bundle id 解析不到进程,落进下面的 `procNotFound`
    /// 分支被当成"还没问过"静默返回,**系统弹窗压根不出现**。所以 `.notDetermined` 有两种
    /// 完全不同的含义(真没问过 / 目标没跑),调用方要自己用 `isRunning` 区分,别把后者
    /// 显示成"未授权"——那是假阴性。
    @discardableResult
    static func check(bundleID: String, askIfNeeded: Bool) -> MusicAutomationPermissionStatus {
        var target = AEAddressDesc()
        let bundleIDBytes = Array(bundleID.utf8)
        guard AECreateDesc(
            DescType(typeApplicationBundleID),
            bundleIDBytes,
            bundleIDBytes.count,
            &target
        ) == noErr else {
            return .notDetermined
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askIfNeeded
        )
        switch status {
        case noErr:
            return .authorized
        case OSStatus(errAEEventNotPermitted):
            return .denied
        default:
            // errAEEventWouldRequireUserConsent(-1744)/procNotFound(-600)/其它任何
            // 没见过的返回值,都当"还没有确定结果"处理——宁可多问一次,也不要把
            // 一个模糊状态误判成"已拒绝"从而永远不再给用户开口的机会。
            return .notDetermined
        }
    }

    // 系统设置里"隐私与安全性 → 自动化"面板——被拒绝后官方没有 API 能再触发一次
    // 系统弹窗,只能引导用户自己去这里手动打开;跟 collector 那份权限共用同一个
    // 面板,一个跳转按钮足够覆盖两边的"去看看"需求。
    static var systemSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    }

    // LyricsOverlayView/GlobalHotkeys 两处"播放控制按钮/快捷键点了才校验权限"逻辑
    // 共用这一个入口——只有选了 Apple Music 才需要真的查这个权限(MusicPlaybackController
    // 也只在这个分支发 AppleScript);QQ 音乐/网易云音乐走 media-control(系统级
    // MediaRemote),完全不需要"自动化"权限。2026-07-29 之前这两处都直接调
    // check(askIfNeeded:),QQ 音乐/网易云音乐用户从没被问过、也永远不会被问这个权限
    // (他们的播放器压根不需要),check() 对他们只会返回 .notDetermined/.denied——
    // 导致播放控制按钮/快捷键在选了这两个播放器时永远进不了下面这一步,是接入这两个
    // 播放器时遗留下来一直没修的坑,这次一起补上。
    static func checkForCurrentPlayer(askIfNeeded: Bool) -> Bool {
        guard PlaybackPlayerPreference.current == .appleMusic else { return true }
        return check(askIfNeeded: askIfNeeded).isAuthorized
    }

    // GlobalHotkeys(播放/暂停/上一首/下一首)+ LyricsOverlayView/NotchLyricsView 的
    // 播放控制按钮,一共 5 个调用点专用的安全版本——2026-08-02 实测排查坐实:这几处
    // 以前直接同步调用上面的 checkForCurrentPlayer(askIfNeeded: true),而这个函数在
    // 还没问过、真的需要询问系统时会触达 AEDeterminePermissionToAutomateTarget,正是
    // requestWithTimeout() 那段注释里点名"在主线程调用有据可查地可能永久挂起"的同一个
    // 风险点——SettingsView/OnboardingView 已经为此专门包了安全封装,这几处播放控制
    // 入口却全部绕开、直接同步调,理论上足以把整个 App UI 冻住。已经确定过的状态
    // (authorized/denied)不碰这条风险路径,直接同步返回;只有真的还没问过、且调用方
    // 明确要求"可以顺便问一下"时,才走 requestWithTimeout() 同一套"真正检查 vs 超时"
    // 赛跑机制——传 launchMusicAppIfNeeded: false,不像"设置/引导页显式点请求权限
    // 按钮"那样为了拿到弹窗去后台拉起 Music.app:播放控制快捷键是被动触发的日常操作,
    // 不该有"按一下播放/暂停,Music.app 却在后台悄悄启动"这种意料之外的副作用。
    static func checkForCurrentPlayerSafely(askIfNeeded: Bool) async -> Bool {
        guard PlaybackPlayerPreference.current == .appleMusic else { return true }
        return await checkAppleMusicSafely(askIfNeeded: askIfNeeded)
    }

    /// 跟上面同一套"安全检查",但**不看设置里选的是哪个播放器**——给"这一刻实际在播的就是
    /// Apple Music"这种场景用。
    ///
    /// 为什么需要它:上面那个函数在设置值不是 .appleMusic 时直接返回 true(前提是"别的播放器
    /// 不需要这个权限")。但设置成"自动识别"时,实际在播的完全可能就是 Apple Music —— 这时
    /// 那个前提不成立,直接返回 true 等于跳过了真正需要的权限检查,后面的 AppleScript 会静默
    /// 失败。悬浮窗那颗"喜欢"就是这种情况(见 PlaybackCoordinator.toggleFavorited)。
    static func checkAppleMusicSafely(askIfNeeded: Bool) async -> Bool {
        let current = check(askIfNeeded: false)
        if current != .notDetermined { return current.isAuthorized }
        guard askIfNeeded else { return false }
        let result = await requestWithTimeout(launchMusicAppIfNeeded: false)
        return result?.isAuthorized ?? false
    }

    // 2026-07-23 实测坐实:全新安装(TCC 对这个 App 完全没有历史记录)的机器上,
    // OnboardingView/SettingsView 直接在按钮点击回调里同步调 check(askIfNeeded: true)
    // 会把整个 App UI 冻结、表现成"点了没反应"——这不是这个 App 自己写错了什么,是
    // AEDeterminePermissionToAutomateTarget 本身有据可查的系统级已知问题:在主线程
    // 调用时有时会直接永久挂起(SpamSieve 也踩过同一个坑,见开发时调研到的
    // Michael Tsai 博客记录),官方建议是挪到后台线程调,并且要接受"结果可能压根
    // 不会来"这个现实,不能让 UI 死等。
    //
    // 这里用 withTaskGroup 做"真正的检查 vs 超时"两个子任务的竞速:谁先完成就用谁
    // 的结果,超时分支赢的话返回 nil(代表"还不确定",不是"已拒绝",不能瞎猜)。
    // group.cancelAll() 对赢了比赛的另一个任务是"尽力而为"——如果是那个真正卡在
    // C API 里的检查任务被取消,Swift 的协作式取消对不认取消信号的同步 C 调用没有
    // 意义,那个线程依然会在后台陪跑下去,只是这次调用不再等它,调用方应该在后续别的
    // 时机(比如.onAppear、App重新变为前台)用 askIfNeeded:false 再读一次最新状态，
    // 覆盖"用户后来自己去系统设置手动开了、但这次请求已经放弃等待"这种情况。
    // launchMusicAppIfNeeded 默认 true(SettingsView/OnboardingView 这两个"用户显式点
    // 请求权限按钮"的场景需要——不然 Music.app 没在运行时权限弹窗根本不出现,见下面
    // ensureMusicAppRunning 调用点的注释);checkForCurrentPlayerSafely(播放控制快捷键/
    // 按钮专用)传 false,理由见那边的注释。
    static func requestWithTimeout(seconds: Double = 8, launchMusicAppIfNeeded: Bool = true) async -> MusicAutomationPermissionStatus? {
        await requestWithTimeout(bundleID: musicBundleID, seconds: seconds,
                                 launchIfNeeded: launchMusicAppIfNeeded)
    }

    /// 同上,目标任意。浏览器那条路(设置页「网页播放器」卡)走这个。
    static func requestWithTimeout(bundleID: String, seconds: Double = 8,
                                   launchIfNeeded: Bool = true) async -> MusicAutomationPermissionStatus? {
        // 2026-07-24 实测坐实(用户报告+复现):Music.app 没在运行时点"请求权限",
        // 系统授权对话框根本不弹——不是超时/挂起,是压根没问。AECreateDesc 按
        // bundle ID 解析目标时,如果找不到对应的运行中进程,大概率直接落到下面
        // procNotFound(-600)分支,被当成"还没问过"静默返回,从来没有真正触发过
        // TCC 的系统弹窗。AEDeterminePermissionToAutomateTarget 的文档说它不需要
        // 目标在运行,但这台机器上的实际行为对不上文档——所以在真正发起检查之前,
        // 先确保 Music.app 处于运行状态,让 bundle ID 一定能解析到一个真实进程。
        // 用 activates=false 后台启动,不抢用户当前焦点,跟 AppDelegate.swift 里
        // launchMusicOnLyrimuseOpen 那半用的是同一个"后台起、别抢前台"的做法。
        if launchIfNeeded {
            await ensureAppRunning(bundleID: bundleID)
        }
        return await withTaskGroup(of: MusicAutomationPermissionStatus?.self) { group in
            group.addTask { check(bundleID: bundleID, askIfNeeded: true) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    /// 不再是 private(2026-08-23):「前往专辑/艺人」「你的常听」那两条 music:// 深链
    /// 跳转也需要同一件事——Music.app 没在跑时直接 `NSWorkspace.shared.open(music://…)`
    /// 会被吞:LaunchServices 把"启动 App"和"打开这个 URL"两件事一起扔过去,冷启动流程
    /// 走到能接 Apple Event 那一步之前 URL 就丢了,用户看到的是"App 打开了,但停在上次
    /// 退出时的页面"而不是跳到链接指的那一页(2026-08-23 用户实测反馈)。跟这里已经解决
    /// 过的"TCC 查权限前必须先让 Music.app 存在"是同一个根因,直接复用。
    static func ensureMusicAppRunning() async {
        await ensureAppRunning(bundleID: musicBundleID)
    }

    /// 这个 bundle id 在跑没跑。`.notDetermined` 的两种含义要靠它区分(见 `check(bundleID:)`)。
    static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// 同 `ensureMusicAppRunning`,目标任意。
    ///
    /// ⚠️ 这一步会**后台启动别人的 App**(`activates = false`,不抢焦点)。只在用户**显式点了
    /// "请求授权"**时才调 —— 别把它挂在"配对成功"这种顺带的路径上:用户点的是"把这个浏览器
    /// 加进列表",不是"现在把我的浏览器打开"。
    static func ensureAppRunning(bundleID: String) async {
        guard !isRunning(bundleID: bundleID) else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.error("cannot resolve app URL by bundle id, skip pre-launch")
            return
        }
        logger.notice("target app not running, launching in background before requesting automation permission")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            logger.error("failed to launch app before permission request: \(error.localizedDescription, privacy: .public)")
        }
    }
}
