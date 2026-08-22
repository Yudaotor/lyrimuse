import AppKit
import KeyboardShortcuts
import LyrimuseCore

// A 组(显示/隐藏悬浮歌词、锁定/解锁位置、打开歌词管理、打开设置)复用已有能力,纯接线;
// B 组(播放/暂停、上下一首)是这个软件第一次拥有"控制播放"能力,靠 MusicPlaybackController
// 发 AppleScript 指令,复用已经拿到的自动化权限(见 MusicAutomationPermission)。
//
// 默认不预置任何按键组合——KeyboardShortcuts.Recorder 不预注册默认值时本来就是空的
// "点击录制"状态,下面这 10 个快捷键全部必须用户自己在设置里主动录制才会生效,不会有
// 按键在用户不知情下被这个 App 抢占。
extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay")
    static let toggleLockPosition = Self("toggleLockPosition")
    static let openLyricsManagerHotkey = Self("openLyricsManagerHotkey")
    static let openLyricsWindowHotkey = Self("openLyricsWindowHotkey")
    static let openSettingsHotkey = Self("openSettingsHotkey")
    static let playPauseHotkey = Self("playPauseHotkey")
    static let nextTrackHotkey = Self("nextTrackHotkey")
    static let previousTrackHotkey = Self("previousTrackHotkey")
    static let lyricsAdvanceHotkey = Self("lyricsAdvanceHotkey")
    static let lyricsDelayHotkey = Self("lyricsDelayHotkey")
}

@MainActor
enum GlobalHotkeys {
    static func registerAll() {
        // ⚠️ 必须先判断 settings.classicOverlayEnabled 再碰 LyricsOverlayWindowController
        // .shared——2026-08-02 实测排查坐实:这里早先漏掉了这层判断,是
        // NotchLyricsWindowController.swift 顶部注释点名的"三处外部路由代码"(AppDelegate/
        // SettingsView/MenuBarMenu)之外被漏判的第 4 处。真正引用到 `.shared` 才会执行
        // init() 建窗口,而 init() 订阅 PlaybackCoordinator 的 Combine sink 在订阅瞬间
        // 就会用当下的 isVisible 触发一次显示/隐藏——下面"锁定位置"那个快捷键因此必须先
        // 判断 classicOverlayEnabled:用户只开了"灵动岛歌词"、关掉"桌面悬浮歌词"时,那个
        // 快捷键仍然可以被录制,按下后会把从未构造过的经典悬浮窗凭空建出来并常驻显示。
        //
        // 但"显示/隐藏悬浮歌词"这个快捷键**不能**加同一个判断:2026-08-05 把"这个模式开
        // 没开"合并成单一开关之后,它切换的就是 classicOverlayEnabled 本身,再 guard 一次
        // 就变成"只能关、不能开"(关掉之后 guard 直接 return,这个快捷键就再也按不动了)。
        // 这里碰 .shared 是用户主动按键要求打开/关闭它,不是被动误触构造。
        KeyboardShortcuts.onKeyUp(for: .toggleOverlay) {
            LyricsOverlayWindowController.shared.setVisible(!AppSettings.shared.classicOverlayEnabled)
        }
        KeyboardShortcuts.onKeyUp(for: .toggleLockPosition) {
            guard AppSettings.shared.classicOverlayEnabled else { return }
            let overlay = LyricsOverlayWindowController.shared
            let newValue = !overlay.isPositionLocked
            // 跟 MenuBarMenu.swift 现成的"锁定位置"Toggle 绑定逻辑完全一致:持久化
            // 偏好 + 让窗口真正生效,两步都要做,不能只做其中一步。
            AppSettings.shared.lockPosition = newValue
            overlay.setLocked(newValue)
        }
        KeyboardShortcuts.onKeyUp(for: .openLyricsManagerHotkey) {
            AppActions.shared.openLyricsManager?()
        }
        KeyboardShortcuts.onKeyUp(for: .openLyricsWindowHotkey) {
            AppActions.shared.openLyricsWindow?()
        }
        KeyboardShortcuts.onKeyUp(for: .openSettingsHotkey) {
            AppActions.shared.openSettings?()
        }
        // 播放控制三个动作:先校验自动化权限——没问过就顺手弹一次系统授权对话框,
        // 已经拒绝过就不弹窗、只用 NSSound.beep() 给一个"没有生效"的听觉反馈(跟
        // ShortcutRecorder.swift 录制失败时用的是同一个既有信号,不新引入一套提示
        // 机制)——2026-08-02 补上:早先这里权限不够时是完全静默的,用户按了没反应,
        // 分不清是没按中快捷键还是权限问题。只有选了 Apple Music 才真的会走到这个
        // 权限检查,见 MusicAutomationPermission.checkForCurrentPlayer 注释。
        //
        // ⚠️ 必须用 checkForCurrentPlayerSafely(异步)而不是 checkForCurrentPlayer
        // (同步)——2026-08-02 实测排查坐实:同步版本在还没问过时会直接触达
        // AEDeterminePermissionToAutomateTarget,这个 API 在主线程调用有据可查地
        // 可能永久挂起,详见 checkForCurrentPlayerSafely 定义处的注释。KeyboardShortcuts
        // 的 onKeyUp 回调本身是同步闭包,用 Task { ... } 包一层去调用异步版本。
        KeyboardShortcuts.onKeyUp(for: .playPauseHotkey) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                PlaybackCoordinator.shared.userTogglePlayPause()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .nextTrackHotkey) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                MusicPlaybackController.nextTrack()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .previousTrackHotkey) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                MusicPlaybackController.previousTrack()
            }
        }
        // 单曲歌词时间轴微调——不需要自动化权限(不碰 Music.app,只改本地/relay 数据源
        // 里 LyricsSyncEngine 的匹配位置),随时可用。步长现读 AppSettings(用户在设置里
        // 可调,不是写死的常量),跟 MenuBarMenu.swift 里"歌词时间轴"菜单的两个按钮共用
        // 同一个值,菜单/快捷键两条路径调出来的手感一致。
        // 改完偏移在灵动岛上闪一条"歌词 +0.5s"。在这之前按这两个键是**完全无反馈**的:
        // 偏移是否生效只能靠盯着歌词自己感觉,连按几下更是数不清累计到了多少。
        // ⚠️ 只有灵动岛这一种展示形态会显示(提示条挂在那张卡片上);只开桌面悬浮歌词的
        // 用户仍然没有反馈,那边没有可以借用的稳态区域,要做得单开一个 HUD 窗口。
        KeyboardShortcuts.onKeyUp(for: .lyricsAdvanceHotkey) {
            showOffsetBanner(PlaybackCoordinator.shared.nudgeLyricsOffset(by: AppSettings.shared.lyricsOffsetStepMs))
        }
        KeyboardShortcuts.onKeyUp(for: .lyricsDelayHotkey) {
            showOffsetBanner(PlaybackCoordinator.shared.nudgeLyricsOffset(by: -AppSettings.shared.lyricsOffsetStepMs))
        }
    }

    /// 把毫秒偏移显示成 "+0.50s" / "-0.25s"。正号要显式带上 —— 只有减号的话,用户按了
    /// "提前"却看到一个没有符号的数字,分不清方向。
    private static func showOffsetBanner(_ offsetMs: Int) {
        let seconds = Double(offsetMs) / 1000
        let text = String(format: "%@ %+.2fs", L10n.t("歌词偏移"), seconds)
        NotchTransientCenter.shared.show(.init(icon: "timer", text: text, progress: nil))
    }
}
