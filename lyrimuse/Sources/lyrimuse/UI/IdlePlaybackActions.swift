import AppKit
import LyrimuseCore

/// 停播(没有曲目)时「该指哪家播放器」+「继续播放 / 打开播放器」这组动作。
///
/// 从 `LyricsWindowView`(停播页 `idleWelcomeView` / `IdleStandbyView` 的回调)原样抽出来,
/// 因为灵动岛没有曲目时的 hover 展开卡(`NotchLyricsView.idleExpandedPanel`)要放同一颗「继续播放」
/// —— 两处各写一份"AM 三段式 → 兜底激活 App"必然漂(这个仓库为同类漂移付过几次账)。逻辑一个字没改,
/// 歌词窗口那三个成员现在只是转发到这里。
@MainActor
enum IdlePlaybackActions {
    /// 停播态该指哪家播放器:恰好一个具体播放器就用它;「自动识别」、或者多选后同时勾了两个以上
    /// 具体播放器(没有唯一答案,跟纯 auto 归为同一类)时,用停播前最后认下来的那家
    /// (LocalPlaybackSource 落在 UserDefaults,停播时快照已清空、只有它还记得);全新用户兜底 Apple Music。
    static var player: PlaybackPlayer {
        if let only = PlaybackPlayerPreference.soleExplicitPlayer { return only }
        if let bid = UserDefaults.standard.string(forKey: "np:lastPlayerBundleID"),
           let p = PlaybackPlayer.allCases.first(where: { $0 != .auto && $0.bundleIdentifier == bid }) {
            return p
        }
        return .appleMusic
    }

    /// 有没有真的「继续播放」可给:AM / Spotify 有 AppleScript(AM = 三段式,Spotify 自带恢复上下文);酷狗、QQ、网易云、
    /// Pine 按它菜单里的播放 / 暂停,冷启动后按也放上次那首(`resumeViaMenu`);洛雪直接发给它本体。reAMP、VOX、汽水一启动就
    /// 自己跳到前台,Kaset 冷启动后不到前台开不了播(隐藏或不激活启动时内嵌网页播放器一直停在加载,见 02 章决策 190),都不给;别的只能「打开」。
    static func canResume(_ player: PlaybackPlayer) -> Bool {
        switch player {
        case .appleMusic, .spotify, .kugou, .qqMusic, .netease, .pinePlayer, .lxMusic: true
        default: false
        }
    }

    /// 「继续播放」:AM 走三段式(裸 play → 上次那首 → 都不行),Spotify 自带恢复;任何失败都兜底把
    /// 播放器 App 带到前台 —— 点了必须有可见反应(实测"点了没反应":裸 play 对空队列
    /// 静默 no-op)。
    static func resume(player: PlaybackPlayer) {
        let lastTitle = UserDefaults.standard.string(forKey: "np:lastTrackTitle")
        let lastArtist = UserDefaults.standard.string(forKey: "np:lastTrackArtist")
        Task.detached(priority: .userInitiated) {
            var ok = false
            switch player {
            case .appleMusic:
                if await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                    ok = MusicPlaybackController.resumePlayback(
                        lastTitle: lastTitle, lastArtist: lastArtist)
                }
            case .spotify:
                ok = MusicPlaybackController.resumeSpotifyPlayback()
            case .kugou, .qqMusic, .netease, .pinePlayer:
                ok = await resumeViaMenu(player)
            case .lxMusic:
                ok = LXMusicOpenAPI.shared.sendDirect("play", arguments: [])
            default:
                ok = false
            }
            if !ok {
                await MainActor.run { openPlayerApp(player) }
            }
        }
    }

    /// 没开着就后台启动(不激活、隐藏窗口),等菜单出现再按播放 / 暂停。冷启动到菜单出现:Pine 约 2 秒、QQ 约 4 秒、酷狗约
    /// 6 秒、网易云约 12 秒,最多等 25 秒。停播页说明它这时没在放,按一下就是开播。标题随状态变的(QQ、网易云)按完读回标题确认
    /// 放起来了:网易云菜单刚出现时按了常不接,隔 2 秒还没放就再按,最多按 4 次。
    nonisolated static func resumeViaMenu(_ player: PlaybackPlayer) async -> Bool {
        guard await launchHiddenIfNeeded(player) else { return false }
        let deadline = Date().addingTimeInterval(25)
        var presses = 0
        func playing() -> Bool? {
            PlaybackMenuControl.playPauseTitle(for: player).flatMap { PlaybackMenuControl.showsPlaying(menuTitle: $0, player: player) }
        }
        while true {
            if presses > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                switch playing() {
                case false?: guard presses < 4, Date() < deadline else { return false }
                default: return true
                }
            }
            let outcome = PlaybackMenuControl.press(.playPause, for: player)
            if outcome == .pressed {
                guard PlaybackMenuControl.titleShowsState(player) else { return true }
                presses += 1
                continue
            }
            guard outcome == .playerNotRunning || outcome == .menuUnavailable, Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// 没开着就后台启动(不激活、隐藏窗口)。开着、启动成了为 true。
    nonisolated static func launchHiddenIfNeeded(_ player: PlaybackPlayer) async -> Bool {
        guard PlayerProcess.pid(bundleID: player.bundleIdentifier) == nil else { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
    }

    static func openPlayerApp(_ player: PlaybackPlayer) {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: player.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
