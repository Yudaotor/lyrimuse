import AppKit
import LyrimuseCore
import os

/// 「在 Spotify 中显示」(2026-09-09):让 Spotify 客户端跳到当前曲目的页面。
///
/// Apple Music 那边是一句 AppleScript `reveal current track`;Spotify 的脚本字典没有同类命令(只有会从头重播的
/// `play track`),能定位的路只有它注册的 `spotify` URL scheme:后台读一次 `spotify url of current track`
/// (~150ms 的 osascript 往返,跟 AM 的 reveal 同量级,不阻塞主线程),经 `SpotifyURI.deepLink` 转成
/// `spotify:track:<id>` 深链,交给**正在跑的那个** Spotify 打开。读不到 / 不是曲目(广告、本地文件)就退回
/// 原来的"只把 App 带到前台"(调用方传进来的 fallback,即 `PlaybackCoordinator.openResolvedPlayerApp`)。
///
/// 不走歌词窗口的 `runAppleMusicMenuAction` 外壳:那个外壳的权限确认是 Music.app 专用的;Spotify 这边本仓没有
/// 权限探测,脚本失败即 nil、退回激活 App —— 与扩展控制(随机 / 音量)的读取走同一条降级路。
///
/// 网页版 Spotify 不进这里:它的播放器 bundle 是浏览器,页面 DOM 里也没有曲目链接(2026-09-09 实测只有专辑 /
/// 歌手链接),「在 Safari 中显示」照旧只激活浏览器。
enum SpotifyReveal {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "spotify-reveal")

    static func revealCurrentTrack(fallback: @escaping @MainActor @Sendable () -> Void) {
        Task.detached(priority: .userInitiated) {
            let uri = MusicPlaybackController.spotifyCurrentTrackURI()
            let link = uri.flatMap(SpotifyURI.deepLink)
            await MainActor.run {
                guard let link else {
                    logger.notice("spotify reveal: no deep link for uri=\(uri ?? "nil", privacy: .public); activating the app instead")
                    fallback()
                    return
                }
                open(link)
            }
        }
    }

    /// 深链交给正在跑的那份 Spotify.app。⚠️ 不按 scheme 的默认处理器开:lsregister 里 `spotify:` 有两份注册
    /// (/Applications 那份,以及 ~/Library/Application Support/Spotify/PersistentCache/Update 里自更新留下的
    /// 那份),默认处理器可能落到后者、把另一个 Spotify 实例拉起来;用户眼前正在播的那个进程才是要跳页的对象。
    /// `activates = true` 与 openResolvedPlayerApp 同款 —— accessory App 请求把别的 App 带到前台,
    /// LaunchServices 这条是系统认可的路(NSRunningApplication.activate 会被协作式激活静默拒绝)。
    @MainActor
    private static func open(_ link: URL) {
        let bundleID = PlaybackPlayer.spotify.bundleIdentifier
        let appURL = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let appURL else {
            logger.notice("spotify reveal: Spotify.app not found, opening \(link.absoluteString, privacy: .public) by scheme")
            NSWorkspace.shared.open(link)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error {
                logger.notice("spotify reveal: \(link.absoluteString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            } else {
                logger.notice("spotify reveal: opened \(link.absoluteString, privacy: .public) in \(appURL.path, privacy: .public)")
            }
        }
    }
}
