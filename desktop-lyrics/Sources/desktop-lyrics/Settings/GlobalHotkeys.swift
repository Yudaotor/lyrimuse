import KeyboardShortcuts
import DesktopLyricsCore

// A 组(显示/隐藏悬浮歌词、锁定/解锁位置、打开歌词管理、打开设置)复用已有能力,纯接线;
// B 组(播放/暂停、上下一首)是这个软件第一次拥有"控制播放"能力,靠 MusicPlaybackController
// 发 AppleScript 指令,复用已经拿到的自动化权限(见 MusicAutomationPermission)。
//
// 默认不预置任何按键组合——KeyboardShortcuts.Recorder 不预注册默认值时本来就是空的
// "点击录制"状态,所有 6 个快捷键必须用户自己在设置里主动录制才会生效,不会有任何
// 按键在用户不知情下被这个 App 抢占。
extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay")
    static let toggleLockPosition = Self("toggleLockPosition")
    static let openLyricsManagerHotkey = Self("openLyricsManagerHotkey")
    static let openSettingsHotkey = Self("openSettingsHotkey")
    static let playPauseHotkey = Self("playPauseHotkey")
    static let nextTrackHotkey = Self("nextTrackHotkey")
    static let previousTrackHotkey = Self("previousTrackHotkey")
    static let lyricsAdvanceHotkey = Self("lyricsAdvanceHotkey")
    static let lyricsDelayHotkey = Self("lyricsDelayHotkey")
}

// 每次按键调整的步长——跟 MenuBarMenu.swift 里"歌词时间轴"菜单的两个按钮共用同一个
// 数值,菜单/快捷键两条路径调出来的手感一致。
let lyricsOffsetStepMs = 200

@MainActor
enum GlobalHotkeys {
    static func registerAll() {
        KeyboardShortcuts.onKeyUp(for: .toggleOverlay) {
            let overlay = LyricsOverlayWindowController.shared
            overlay.setVisible(!overlay.isVisible)
        }
        KeyboardShortcuts.onKeyUp(for: .toggleLockPosition) {
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
        KeyboardShortcuts.onKeyUp(for: .openSettingsHotkey) {
            AppActions.shared.openSettings?()
        }
        // 播放控制三个动作:先校验自动化权限——没问过就顺手弹一次系统授权对话框,
        // 已经拒绝过就静默不做,不会每次按快捷键都弹一次提示打扰用户。
        KeyboardShortcuts.onKeyUp(for: .playPauseHotkey) {
            guard MusicAutomationPermission.check(askIfNeeded: true).isAuthorized else { return }
            MusicPlaybackController.playPause()
        }
        KeyboardShortcuts.onKeyUp(for: .nextTrackHotkey) {
            guard MusicAutomationPermission.check(askIfNeeded: true).isAuthorized else { return }
            MusicPlaybackController.nextTrack()
        }
        KeyboardShortcuts.onKeyUp(for: .previousTrackHotkey) {
            guard MusicAutomationPermission.check(askIfNeeded: true).isAuthorized else { return }
            MusicPlaybackController.previousTrack()
        }
        // 单曲歌词时间轴微调——不需要自动化权限(不碰 Music.app,只改本地/relay 数据源
        // 里 LyricsSyncEngine 的匹配位置),随时可用。
        KeyboardShortcuts.onKeyUp(for: .lyricsAdvanceHotkey) {
            PlaybackCoordinator.shared.nudgeLyricsOffset(by: lyricsOffsetStepMs)
        }
        KeyboardShortcuts.onKeyUp(for: .lyricsDelayHotkey) {
            PlaybackCoordinator.shared.nudgeLyricsOffset(by: -lyricsOffsetStepMs)
        }
    }
}
