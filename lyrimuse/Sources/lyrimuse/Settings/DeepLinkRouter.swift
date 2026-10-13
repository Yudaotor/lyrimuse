import AppKit
import LyrimuseCore
import os

/// `lyrimuse://…` 的唯一分派处。解析在 Core(`LyrimuseDeepLink`),这里只把解析结果交给各入口;每一条都走
/// 跟界面上那颗按钮 / 那个菜单项同一个入口,不另写一套。见 14 章「深链」。
@MainActor
enum DeepLinkRouter {
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "deep-link")

    static func handle(_ url: URL) {
        // 日志只记 host 和路径,不记查询参数:Last.fm 授权回跳带着 `?token=…`,导出诊断会把 App 日志一起打包。
        let logged = (url.host ?? "") + url.path
        guard let link = LyrimuseDeepLink(url: url, scheme: LyrimuseIdentity.urlScheme) else {
            // 认不出的不往 Last.fm 授权回调里落:正在等浏览器授权时,一条拼错的链接会被当成授权完成。
            logger.notice("unrecognized deep link: \(logged, privacy: .public)")
            GlobalHotkeys.flashHint(icon: "link", text: L10n.t("无法识别的链接"))
            return
        }
        logger.info("deep link: \(logged, privacy: .public)")
        let background = LyrimuseDeepLink.wantsBackground(url)
        if background { WindowActivation.beginBackground() }
        defer {
            if background, let scene = sceneID(for: link) { WindowActivation.surface(identifier: scene) }
        }
        switch link {
        case let .settings(path, checkForUpdates):
            openSettings(path: path, checkForUpdates: checkForUpdates)
        case .lyricsManager:
            AppActions.shared.openLyricsManager?()
        case let .lyricsManagerSongVersions(key, showEvidence):
            AppActions.shared.openLyricsManager?()
            AppActions.shared.requestSongVersions(key: key, showEvidence: showEvidence)
        case .lyricsWindow:
            AppActions.shared.openLyricsWindow?()
        case .lyricsWindowSearch:
            AppActions.shared.openLyricsWindow?()
            AppActions.shared.requestLyricsWindowSearch()
        case .lyricsSearch:
            AppActions.shared.openLyricsQuickSearch?()
        case let .menuBarPanel(quick):
            // 认不出的 quick 当没带(只开面板)。
            MenuBarStatusItem.shared.togglePanelFromDeepLink(quick: quick.flatMap(PanelQuickTarget.init(deepLinkValue:)))
        case .onboarding:
            AppActions.shared.openOnboarding?()
        case let .action(action, on, stepSeconds):
            LyrimuseActionRunner.perform(action, on: on, stepMs: stepSeconds.map { Int(($0 * 1000).rounded()) })
        case let .copyLyric(includeTranslation):
            copyCurrentLyric(includeTranslation: includeTranslation)
        case .openPlayer:
            IdlePlaybackActions.openPlayerApp(IdlePlaybackActions.player)
        case let .setSurfaces(overlay, notch, menuBar):
            // 逐个走开关动作(跟快捷键同一份逻辑);只动带了的那几个。
            if let overlay { LyrimuseActionRunner.perform(.toggleOverlay, on: overlay) }
            if let notch { LyrimuseActionRunner.perform(.toggleNotchOverlayHotkey, on: notch) }
            if let menuBar { LyrimuseActionRunner.perform(.toggleMenuBarLyricsHotkey, on: menuBar) }
        case let .setLyricsOffset(ms):
            LyrimuseActionRunner.setLyricsOffset(ms: ms)
        case let .nowPlayingCallback(success):
            replyNowPlaying(to: success)
        case let .debug(command):
            DebugDeepLinks.handle(command)
        case .lastfmAuthCallback:
            LastfmConnectController.shared.handleAuthCallback()
        }
    }

    /// 开窗类链接开的是哪一扇 SwiftUI 场景窗(`background=1` 时开完摆到最前用);不开窗的是 nil。
    private static func sceneID(for link: LyrimuseDeepLink) -> String? {
        switch link {
        case .settings: return "settings"
        case .lyricsManager, .lyricsManagerSongVersions, .action(.openLyricsManagerHotkey, _, _): return "lyrics-manager"
        case .lyricsWindow, .lyricsWindowSearch, .action(.openLyricsWindowHotkey, _, _),
             .action(.toggleLyricsWindowMiniHotkey, _, _): return "lyrics-window"
        case .lyricsSearch, .action(.lyricsQuickSearchHotkey, _, _): return "lyrics-quick-search"
        case .onboarding: return "onboarding"
        case .action(.openSettingsHotkey, _, _): return "settings"
        default: return nil
        }
    }

    /// 当前这句(纯文本,可连译文)放进剪贴板;没在放、或者这一刻不在任何一句上时说一声,不清空剪贴板。
    private static func copyCurrentLyric(includeTranslation: Bool) {
        let line = PlaybackCoordinator.shared.currentLine
        let text = (line?.plainText ?? line?.mainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            GlobalHotkeys.flashHint(icon: "text.badge.xmark", text: L10n.t("当前没有歌词"))
            return
        }
        var copied = text
        if includeTranslation, let translation = line?.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translation.isEmpty {
            copied += "\n" + translation
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
        GlobalHotkeys.flashHint(icon: "doc.on.doc", text: L10n.t("已拷贝当前歌词"))
    }

    /// x-callback-url 回传。没在放时照样回传(各项空、`playing=0`),调用方按 `playing` 判断;没给本机 App 的回传地址时
    /// 什么都不做(`LyrimuseDeepLink` 已经把网页地址挡在外面)。
    private static func replyNowPlaying(to success: URL?) {
        guard let success else {
            logger.notice("now-playing callback without a local x-success target")
            return
        }
        let p = PlaybackCoordinator.shared
        let playing = !p.title.isEmpty
        let line = p.currentLine
        guard let url = LyrimuseDeepLink.callbackURL(
            success, title: p.title, artist: p.artist, album: p.album,
            lyric: (line?.plainText ?? line?.mainText ?? ""),
            player: playing ? (p.resolvedPlayerDisplayName ?? "") : "", playing: playing) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 软件更新页另认 `?check=1`(支持回复里「点这个链接检查更新」)。带分段的先写分段键、再翻页:反过来会先画一帧
    /// 那一页上次停的分段(同设置窗口 `navigate(to:)` 的顺序)。认不出的路径只把设置窗口叫出来。
    private static func openSettings(path: String, checkForUpdates: Bool) {
        if path == "/software-update" {
            if checkForUpdates {
                SparkleUpdaterManager.shared.checkForUpdates()
            } else {
                SparkleUpdaterManager.shared.showUpdatePage()
            }
            return
        }
        if let section = SettingsDeepLink.section(in: path) {
            UserDefaults.standard.set(section.value, forKey: section.storageKey)
        }
        if let item = SettingsDeepLink(path: SettingsDeepLink.pagePath(of: path)).flatMap(SettingsSidebarItem.init(deepLink:)) {
            AppActions.shared.requestSettings(item)
        }
        AppActions.shared.openSettings?()
    }
}
