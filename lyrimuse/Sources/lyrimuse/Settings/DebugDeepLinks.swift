import AppKit
import CryptoKit
import LyrimuseCore
import os

/// `lyrimuse://debug/…`:本机验证时不打扰用户的几样工具(状态快照、窗口快照、记下 / 恢复、模拟播放、喜欢与音量、关掉一条来源)。见 14 章决策 98。
///
/// **只在本机偏好 `debug:deepLinks` 为真时执行**(`defaults write me.yudaotor.lyrimuse debug:deepLinks -bool true`):
/// 任何网页都能拉起 `lyrimuse://`,而这里会把正在听什么、开着哪些窗口写到盘上,还能关窗、改开关。网页改不了本机偏好;
/// 键不带 `np:` 前缀,导出配置不会把它带到别的机器上(ConfigPortability 只导 `np:` / `KeyboardShortcuts_`)。
///
/// 输出都写在 `~/Library/Caches/<bundle id>/debug/`,不碰数据目录里的用户数据。
@MainActor
enum DebugDeepLinks {
    static let enabledKey = "debug:deepLinks"
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "deep-link")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// `debug/settings-search` 的搜索词,设置窗口收到后按搜索结果的第一条跳过去。
    static let settingsSearchNotification = Notification.Name("lyrimuse.debug.settingsSearch")

    static var outputDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "lyrimuse").appendingPathComponent("debug")
    }

    static func handle(_ command: LyrimuseDeepLink.DebugCommand) {
        guard isEnabled else {
            logger.notice("debug deep link ignored: \(enabledKey, privacy: .public) is off")
            return
        }
        switch command {
        case let .snapshot(window): snapshot(window)
        case .state: writeState()
        case .checkpoint: checkpoint()
        case .restore: restore()
        case let .simulate(title, artist, album, duration, position, playing, ad):
            PlaybackSimulation.begin(PlaybackSimulation(
                title: title, artist: artist, album: album, duration: duration, position: position, playing: playing, ad: ad))
            LocalPlaybackSource.shared.simulationChanged()
            logger.notice("debug simulate on ad=\(ad, privacy: .public)")
        case .simulateIdle:
            PlaybackSimulation.begin(.nothingPlaying())
            LocalPlaybackSource.shared.simulationChanged()
            logger.notice("debug simulate idle")
        case .simulateOff:
            endSimulation()
        case .toggleFavorite:
            PlaybackCoordinator.shared.toggleFavorited()
            logger.notice("debug favorite toggle")
        case let .volume(percent):
            PlaybackCoordinator.shared.setVolume(percent)
            logger.notice("debug volume \(percent, privacy: .public)")
        case let .settingsSearch(query):
            NotificationCenter.default.post(name: settingsSearchNotification, object: query)
            logger.notice("debug settings search \(query, privacy: .public)")
        case .saveConfig:
            Task { @MainActor in
                let ok = await ConfigStore.shared.save()
                logger.notice("debug config save ok=\(ok, privacy: .public)")
            }
        case let .knockout(leg, on):
            SourceKnockout.set(leg, out: !on)
            LocalPlaybackSource.shared.simulationChanged()
        case let .menuBarCenter(center, ignoreNotch, screen):
            if let ignoreNotch { MenuBarCenterLyrics.ignoresNotchForDebug = ignoreNotch }
            if let center { AppSettings.shared.menuBarLyricsPlacement = center ? .screenCenter : .statusItem }
            if let screen { AppSettings.shared.menuBarCenterScreen = screen }
            MenuBarStatusItem.shared.setNeedsRefresh()
            logger.notice("debug menubar center=\(String(describing: center), privacy: .public) ignoreNotch=\(String(describing: ignoreNotch), privacy: .public)")
        case let .menuBarDisplay(artwork, content):
            if let artwork { AppSettings.shared.menuBarIconShowsArtwork = artwork }
            if let value = content.flatMap(MenuBarLyricsContent.init(rawValue:)) { AppSettings.shared.menuBarLyricsContent = value }
            logger.notice("debug menubar display artwork=\(String(describing: artwork), privacy: .public) content=\(content ?? "-", privacy: .public)")
        case let .japaneseReading(style):
            AppSettings.shared.japaneseReadingStyle = style
            LocalPlaybackSource.shared.japaneseReading = style
            logger.notice("debug japanese reading \(style.rawValue, privacy: .public)")
        }
    }

    // MARK: 状态快照

    /// 验证脚本读这一份断言,不靠截图:开着哪些窗口、各自在哪、面板翻在哪一格、当前播放到哪一句、各开关。
    static func state() -> [String: Any] {
        let s = AppSettings.shared
        let p = PlaybackCoordinator.shared
        let defaults = UserDefaults.standard
        let windows: [[String: Any]] = NSApp.windows.filter(\.isVisible).map { w in
            [
                "identifier": w.identifier?.rawValue ?? "",
                "title": w.title,
                "class": String(describing: type(of: w)),
                "frame": [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height],
                "isKey": w.isKeyWindow,
                "onActiveSpace": w.isOnActiveSpace,
                "occlusionVisible": w.occlusionState.contains(.visible),
                "level": w.level.rawValue,
                "appearance": w.effectiveAppearance.name.rawValue,
            ]
        }
        let position = p.anchor?.extrapolatedPositionMs() ?? p.pausedPositionMs
        return [
            // isActive 在菜单栏面板当 key 时也是真(面板不激活 App);前台是不是本 App 看 isFrontmost。
            "app": ["pid": ProcessInfo.processInfo.processIdentifier, "isActive": NSApp.isActive,
                    "isFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == ProcessInfo.processInfo.processIdentifier],
            "windows": windows,
            "menuBarCenter": MenuBarStatusItem.shared.centerDebugState,
            "menuBarPanel": ["open": MenuBarStatusItem.shared.isPanelOpen,
                             "quick": MenuBarPanelDebugState.quickTarget.map { $0 as Any } ?? NSNull()],
            "knockedOut": SourceKnockout.knockedOut,
            // 播放源交出来的那张封面(高清替代之前),验证封面退到了哪一条来源时跟文件的哈希对。
            "artwork": LocalPlaybackSource.shared.artworkData.map { data -> Any in
                ["bytes": data.count,
                 "sha256": SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()]
            } ?? NSNull(),
            "playback": [
                "title": p.title, "artist": p.artist, "album": p.album, "playing": p.isPlayingNow,
                "player": p.resolvedPlayerDisplayName ?? "",
                "positionMs": position.map { $0 as Any } ?? NSNull(),
                "lineIndex": p.currentLineIndex.map { $0 as Any } ?? NSNull(),
                "line": p.currentLine?.plainText ?? "",
                "lineRomanization": p.currentLine?.romanization ?? "",
                "trackLyricsOffsetMs": p.trackLyricsOffsetMs,
                "playMode": p.playbackMode.map { $0.rawValue as Any } ?? NSNull(),
                "favorited": p.isFavorited.map { $0 as Any } ?? NSNull(),
                "volume": p.soundVolume.map { $0 as Any } ?? NSNull(),
                "volumeHint": p.volumeHint ?? NSNull(),
                "volumeHintLevel": p.volumeHintLevel ?? NSNull(),
            ],
            "settings": [
                "overlay": s.classicOverlayEnabled, "notch": s.notchOverlayEnabled, "menuBar": s.showLyricsInMenuBar,
                "touchBar": s.showLyricsInTouchBar, "lockPosition": s.lockPosition,
                "overlayTranslation": s.overlayShowTranslation, "windowTranslation": s.showTranslation,
                "overlayRomanization": s.overlayShowRomanization, "windowRomanization": s.showRomanization,
                "lyricsWindowOpen": defaults.bool(forKey: LyricsWindowSession.openKey),
                "lyricsWindowMini": defaults.bool(forKey: LyricsWindowSession.miniModeKey),
            ],
            "appearance": ["mode": s.appearanceMode.rawValue, "app": NSApp.effectiveAppearance.name.rawValue,
                           "systemDark": SystemAppearanceStore.shared.isDark,
                           "menuBarDark": MenuBarAppearanceStore.shared.isDark],
            "checkpoint": checkpointSaved != nil,
            "simulation": PlaybackSimulation.current.map { sim -> Any in
                ["title": sim.title, "artist": sim.artist, "positionSecs": sim.elapsed(at: Date()),
                 "playing": sim.isPlaying(at: Date()), "ad": sim.ad, "idle": sim.idle]
            } ?? NSNull(),
        ]
    }

    private static func writeState() {
        let url = outputDir.appendingPathComponent("state.json")
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state(), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            logger.notice("debug state written: \(url.path, privacy: .public)")
        } catch {
            logger.error("debug state failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 窗口快照

    /// 名字认这几个:settings / lyrics-manager / lyrics-window / lyrics-search / onboarding(SwiftUI 场景 id)、
    /// panel(菜单栏面板)、overlay(悬浮歌词)、notch(灵动岛);都不是时按窗口标识、标题、类名里含这个名字找。
    /// 只找看得见的窗口,不为了拍照把窗口建出来。
    static func window(named name: String) -> NSWindow? {
        let visible = NSApp.windows.filter(\.isVisible)
        let key: String
        switch name {
        case "lyrics-search": key = "lyrics-quick-search"
        case "panel": key = "MenuBarPanelWindow"
        default: key = name
        }
        func matches(_ w: NSWindow) -> Bool {
            (w.identifier?.rawValue.localizedCaseInsensitiveContains(key) ?? false)
                || w.title.localizedCaseInsensitiveCompare(key) == .orderedSame
                || String(describing: type(of: w)).localizedCaseInsensitiveContains(key)
        }
        return visible.first(where: matches)
    }

    /// App 自己把这扇窗画进位图(`cacheDisplay`):不需要屏幕录制权限,窗口被挡住、在别的桌面空间也画得出,锁屏时同样能用。
    /// 毛玻璃这类靠窗口服务器合成的效果画不进来(会是底色),判布局、文字、尺寸够用;要看真实合成效果仍用 `screencapture -l`。
    private static func snapshot(_ name: String) {
        guard let window = window(named: name), let view = window.contentView else {
            logger.notice("debug snapshot: no visible window named \(name, privacy: .public)")
            return
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let url = outputDir.appendingPathComponent("snapshot-\(name)-\(stamp).png")
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(to: url, options: .atomic)
            logger.notice("debug snapshot written: \(url.path, privacy: .public)")
        } catch {
            logger.error("debug snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 记下 / 恢复

    private struct Checkpoint {
        let sceneWindows: Set<String>
        let panelOpen: Bool
        let overlay: Bool
        let notch: Bool
        let menuBar: Bool
        let lockPosition: Bool
        let overlayTranslation: Bool
        let windowTranslation: Bool
        let overlayRomanization: Bool
        let windowRomanization: Bool
        let japaneseReading: JapaneseReadingStyle
    }

    private static var checkpointSaved: Checkpoint?

    /// 验证时会开、会关的那几种窗口(SwiftUI 场景)。悬浮歌词、灵动岛、菜单栏这些常驻窗口不在这里:恢复时不碰它们的窗口,
    /// 只按开关设回去。
    private static let sceneIDs = ["settings", "lyrics-manager", "lyrics-window", "lyrics-quick-search", "lyrics-share", "onboarding"]

    private static func openSceneWindows() -> [String: NSWindow] {
        var found: [String: NSWindow] = [:]
        for w in NSApp.windows where w.isVisible {
            guard let raw = w.identifier?.rawValue else { continue }
            if let id = sceneIDs.first(where: { raw.localizedCaseInsensitiveContains($0) }) { found[id] = w }
        }
        return found
    }

    private static func checkpoint() {
        let s = AppSettings.shared
        checkpointSaved = Checkpoint(
            sceneWindows: Set(openSceneWindows().keys), panelOpen: MenuBarStatusItem.shared.isPanelOpen,
            overlay: s.classicOverlayEnabled, notch: s.notchOverlayEnabled, menuBar: s.showLyricsInMenuBar,
            lockPosition: s.lockPosition,
            overlayTranslation: s.overlayShowTranslation, windowTranslation: s.showTranslation,
            overlayRomanization: s.overlayShowRomanization, windowRomanization: s.showRomanization,
            japaneseReading: s.japaneseReadingStyle)
        logger.notice("debug checkpoint saved")
    }

    /// 关掉记下之后才开出来的场景窗口、收起记下时没开的面板;开关只设有变化的那几个(走同一套开关动作,不一下闪一串回声)。
    private static func endSimulation() {
        guard PlaybackSimulation.isActive else { return }
        PlaybackSimulation.end()
        LocalPlaybackSource.shared.simulationChanged()
        logger.notice("debug simulate off")
    }

    /// 模拟播放不管记下时开没开,一律收掉。
    private static func restore() {
        endSimulation()
        guard let saved = checkpointSaved else {
            logger.notice("debug restore: no checkpoint")
            return
        }
        for (id, window) in openSceneWindows() where !saved.sceneWindows.contains(id) {
            window.close()
        }
        if MenuBarStatusItem.shared.isPanelOpen && !saved.panelOpen {
            MenuBarStatusItem.shared.togglePanelFromDeepLink()
        }
        let s = AppSettings.shared
        if s.classicOverlayEnabled != saved.overlay { LyrimuseActionRunner.perform(.toggleOverlay, on: saved.overlay) }
        if s.notchOverlayEnabled != saved.notch { LyrimuseActionRunner.perform(.toggleNotchOverlayHotkey, on: saved.notch) }
        if s.showLyricsInMenuBar != saved.menuBar { s.showLyricsInMenuBar = saved.menuBar }
        if s.classicOverlayEnabled, s.lockPosition != saved.lockPosition {
            LyrimuseActionRunner.perform(.toggleLockPosition, on: saved.lockPosition)
        }
        if s.overlayShowTranslation != saved.overlayTranslation { s.overlayShowTranslation = saved.overlayTranslation }
        if s.showTranslation != saved.windowTranslation { s.showTranslation = saved.windowTranslation }
        if s.overlayShowRomanization != saved.overlayRomanization { s.overlayShowRomanization = saved.overlayRomanization }
        if s.showRomanization != saved.windowRomanization { s.showRomanization = saved.windowRomanization }
        if s.japaneseReadingStyle != saved.japaneseReading {
            s.japaneseReadingStyle = saved.japaneseReading
            LocalPlaybackSource.shared.japaneseReading = saved.japaneseReading
        }
        checkpointSaved = nil
        logger.notice("debug restore done")
    }
}

/// 菜单栏面板此刻翻在哪一格(深链取值,nil = 钮块网格或面板没开)。只给 `debug/state` 读,面板自己不读它。
@MainActor
enum MenuBarPanelDebugState {
    static var quickTarget: String?
}
