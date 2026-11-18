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
    /// `debug/lyrics-writeback` 的步骤(open / confirm / cancel),歌词管理收到后对正显示的那首照做。
    static let lyricsWritebackNotification = Notification.Name("lyrimuse.debug.lyricsWriteback")
    /// `debug/hover-note` 的匹配文字(空串 = 收回),悬停气泡收到后按自己的说明文案比对。
    static let hoverNoteNotification = Notification.Name("lyrimuse.debug.hoverNote")
    /// 最近一次 `debug/hover-note` 的匹配文字,晚于它出现的气泡锚点挂载时也按它比对。
    static var hoverNoteQuery = ""
    /// `debug/notify-channel` 的渠道 id(空串 = 第一个),推送渠道卡收到后打开那个渠道的编辑弹窗。
    static let editNotifyChannelNotification = Notification.Name("lyrimuse.debug.editNotifyChannel")
    /// `debug/manager-visibility`:object 是 NSNumber(true = 当作露出来,false = 当作挡住),nil = 交还给遮挡状态。
    static let managerVisibilityNotification = Notification.Name("lyrimuse.debug.managerVisibility")
    /// `debug/manager-list`:object 是动作原文(String),歌词管理收(`LyricsManagerDebugOp`)。
    static let managerListNotification = Notification.Name("lyrimuse.debug.managerList")
    /// `debug/settings-visibility`:同上,对设置窗口。
    static let settingsVisibilityNotification = Notification.Name("lyrimuse.debug.settingsVisibility")
    /// `debug/onboarding-step`:object 是 `OnboardingStep`,引导窗口收到后翻到那一步。
    static let onboardingStepNotification = Notification.Name("lyrimuse.debug.onboardingStep")

    /// 屏上露着的那扇歌词窗口(迷你面板或完整窗口)。`LyricsWindowSession.window` 是最近 attach 的那扇、弱引用,
    /// 启动时直接开成迷你那次读到的是空,它不在屏上时按窗口类型找。完整窗口按场景 id 前缀认:有的系统上标识是
    /// `lyrics-window-AppWindow-N`。
    private static var visibleLyricsWindow: NSWindow? {
        if let window = LyricsWindowSession.window, window.isVisible { return window }
        return NSApp.windows.first {
            $0.isVisible && ($0 is LyricsMiniPanel || $0.identifier?.rawValue.hasPrefix("lyrics-window") == true)
        }
    }

    /// `debug/lyrics-window-traffic-hover`:当作指针停在歌词窗口红绿灯附近 `point`(窗口坐标,左上原点;nil = 离开)。
    private static func trafficHover(at point: CGPoint?) {
        guard let window = visibleLyricsWindow else {
            logger.notice("debug lyrics window traffic hover: no lyrics window")
            return
        }
        let inside = TitlebarButtonPlacement.simulateGroupHover(in: window, at: point)
        let area = TitlebarButtonPlacement.hoverGeometry(in: window)?.hoverArea.map { NSStringFromRect($0) } ?? "-"
        logger.notice("debug lyrics window traffic hover at=\(point.map { "\($0.x),\($0.y)" } ?? "off", privacy: .public) inside=\(inside.map { String($0) } ?? "no-area", privacy: .public) area=\(area, privacy: .public)")
    }

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
        case let .dragRegion(window): writeDragRegion(window)
        case .state: writeState()
        case .telemetryPreview: writeTelemetryPreview()
        case let .playCountFamily(artist, title, counts): writePlayCountFamily(artist: artist, title: title, counts: counts)
        case let .appMove(source, destination, answer): appMove(source: source, destination: destination, answer: answer)
        case .diagnostics: writeDiagnostics()
        case .checkpoint: checkpoint()
        case .restore: restore()
        case let .simulate(title, artist, album, duration, position, playing, ad, artworkPath, localFile, localFilePlayer, volume):
            // 封面只读本机文件,限 20MB;读不到就当没有封面。
            let artwork = artworkPath.flatMap { path -> Data? in
                let url = URL(fileURLWithPath: path)
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 20_000_000 else { return nil }
                return FileIO.read(url)
            }
            PlaybackSimulation.begin(PlaybackSimulation(
                title: title, artist: artist, album: album, duration: duration, position: position, playing: playing, ad: ad,
                artwork: artwork, volume: volume))
            NowPlayingLocalFileModel.shared.update(localFile.map {
                NowPlayingLocalFile(player: localFilePlayer ?? PlaybackSimulation.bundleIdentifier, path: $0)
            })
            LocalPlaybackSource.shared.simulationChanged()
            PlaybackCoordinator.shared.refreshVolume()
            logger.notice("debug simulate on ad=\(ad, privacy: .public)")
        case .simulateIdle:
            PlaybackSimulation.begin(.nothingPlaying())
            NowPlayingLocalFileModel.shared.update(nil)
            LocalPlaybackSource.shared.simulationChanged()
            logger.notice("debug simulate idle")
        case .simulateOff:
            endSimulation()
        case .toggleFavorite:
            PlaybackCoordinator.shared.toggleFavorited()
            logger.notice("debug favorite toggle")
        case let .seek(seconds):
            PlaybackCoordinator.shared.seek(toMs: Int((seconds * 1000).rounded()))
            logger.notice("debug seek \(seconds, privacy: .public)")
        case .idleResume:
            let player = IdlePlaybackActions.player
            guard IdlePlaybackActions.canResume(player) else {
                logger.notice("debug idle resume: \(player.rawValue, privacy: .public) has no resume")
                return
            }
            IdlePlaybackActions.resume(player: player)
            logger.notice("debug idle resume \(player.rawValue, privacy: .public)")
        case let .volume(percent):
            PlaybackCoordinator.shared.setVolume(percent)
            logger.notice("debug volume \(percent, privacy: .public)")
        case let .notchVolume(up):
            VolumeMonitor.adjustSystemVolume(by: up ? NotchScrollGesture.wheelStep : -NotchScrollGesture.wheelStep)
            logger.notice("debug notch volume \(up ? "up" : "down", privacy: .public)")
        case let .settingsSearch(query):
            NotificationCenter.default.post(name: settingsSearchNotification, object: query)
            logger.notice("debug settings search \(query, privacy: .public)")
        case let .hoverNote(query):
            hoverNoteQuery = query ?? ""
            NotificationCenter.default.post(name: hoverNoteNotification, object: hoverNoteQuery)
            logger.notice("debug hover note \(query ?? "off", privacy: .public)")
        case let .editNotifyChannel(id):
            NotificationCenter.default.post(name: editNotifyChannelNotification, object: id ?? "")
            logger.notice("debug edit notify channel")
        case let .stall(ms):
            logger.notice("debug stall: blocking main thread \(ms, privacy: .public) ms")
            usleep(UInt32(ms) * 1000)
        case let .notchBehavior(collapse, hide, progressLine, allScreens, showLyrics, lyricRowFade, volumeKeyBanner, realAudio):
            if let volumeKeyBanner { AppSettings.shared.notchVolumeBannerForVolumeKeys = volumeKeyBanner }
            if let realAudio { AppSettings.shared.notchEqualizerFollowsAudio = realAudio }
            if let showLyrics { AppSettings.shared.notchShowLyrics = showLyrics }
            if let lyricRowFade { AppSettings.shared.notchFadeLyricRowOnHover = lyricRowFade }
            if let collapse { AppSettings.shared.notchCollapsesWhenPaused = collapse }
            if let allScreens { AppSettings.shared.notchAllScreens = allScreens }
            if let hide { AppSettings.shared.notchHideWhenNotPlaying = hide }
            if let progressLine {
                if let style = progressLine.style { AppSettings.shared.notchProgressLineStyle = style }
                AppSettings.shared.notchShowsProgressLine = progressLine.shows
            }
            logger.notice("debug notch behavior collapse=\(String(describing: collapse), privacy: .public) hide=\(String(describing: hide), privacy: .public) progressLine=\(progressLine?.rawValue ?? "nil", privacy: .public) allScreens=\(String(describing: allScreens), privacy: .public) showLyrics=\(String(describing: showLyrics), privacy: .public) lyricRowFade=\(String(describing: lyricRowFade), privacy: .public) volumeKeyBanner=\(String(describing: volumeKeyBanner), privacy: .public) realAudio=\(String(describing: realAudio), privacy: .public)")
        case let .moveWindow(title, x, y, width, height):
            // 全局坐标的原点是主屏左上角;NSWindow 的原点在左下角、y 朝上。
            guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }),
                  let mainHeight = NSScreen.screens.first?.frame.height else {
                logger.notice("debug move window: no visible window titled \(title, privacy: .public)")
                return
            }
            let size = NSSize(width: max(width ?? window.frame.width, window.minSize.width),
                              height: max(height ?? window.frame.height, window.minSize.height))
            window.setFrame(NSRect(x: x, y: mainHeight - y - size.height, width: size.width, height: size.height), display: true)
            logger.notice("debug move window \(title, privacy: .public) to \(x, privacy: .public),\(y, privacy: .public) size=\(size.width, privacy: .public)x\(size.height, privacy: .public)")
        case let .overlayLayout(width, lineChange, nextLine, overflow, arrangement):
            if let width {
                let snapped = OverlayEditorStage.snappedWidth(width)
                AppSettings.shared.overlayWidth = snapped
                // 同抽屉那根宽度滑杆:开着时窗口当场跟着变,关着时不碰 `.shared`(读一下就会建出窗口)。
                if AppSettings.shared.classicOverlayEnabled { LyricsOverlayWindowController.shared.setWidth(snapped) }
            }
            if let lineChange { AppSettings.shared.overlayLineChangeAnimation = lineChange }
            if let nextLine {
                AppSettings.shared.overlayNextLineScale = OverlayRowFontScale.clamped(nextLine, item: .nextLine)
            }
            if let overflow { AppSettings.shared.overlayLineOverflow = overflow }
            if let arrangement { AppSettings.shared.overlayNextLineArrangement = arrangement }
            logger.notice("debug overlay layout width=\(width.map { String($0) } ?? "nil", privacy: .public) lineChange=\(String(describing: lineChange), privacy: .public) nextLine=\(nextLine.map { String($0) } ?? "nil", privacy: .public) overflow=\(overflow?.rawValue ?? "nil", privacy: .public) nextArrangement=\(arrangement?.rawValue ?? "nil", privacy: .public)")
        case let .overlayText(opacity, color, stroke, strokeWidth):
            if let opacity { AppSettings.shared.overlayTextOpacity = OverlayTextOpacity.clamped(opacity) }
            // 同设置页「文字颜色」那颗下拉(`OverlayColorSettingsRows.textColorSource`)。
            if let color {
                AppSettings.shared.overlayRainbow = color == "rainbow"
                if color != "rainbow" { AppSettings.shared.followsCoverArt = color == "cover" }
            }
            if let stroke { AppSettings.shared.textStrokeEnabled = stroke }
            if let strokeWidth { AppSettings.shared.textStrokeWidth = strokeWidth }
            logger.notice("debug overlay text opacity=\(opacity.map { String($0) } ?? "nil", privacy: .public) color=\(color ?? "nil", privacy: .public) stroke=\(stroke.map { String($0) } ?? "nil", privacy: .public) strokeWidth=\(strokeWidth?.rawValue ?? "nil", privacy: .public)")
        case let .notchStyle(style, expanded):
            if let style, let parsed = NotchCardStyle(rawValue: style) { AppSettings.shared.notchCardStyle = parsed }
            if let expanded {
                if expanded == "same" {
                    AppSettings.shared.notchExpandedCardStyle = nil
                } else if let parsed = NotchCardStyle(rawValue: expanded) {
                    AppSettings.shared.notchExpandedCardStyle = parsed
                }
            }
            logger.notice("debug notch style style=\(style ?? "nil", privacy: .public) expanded=\(expanded ?? "nil", privacy: .public)")
        case let .notchQuickActions(layout):
            AppSettings.shared.notchQuickSlots = layout == "default" ? .default
                : NotchQuickSlots.fromStored(layout.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } },
                                             legacy: nil)
            logger.notice("debug notch quick slots=\(AppSettings.shared.notchQuickSlots.stored.map { $0.joined(separator: ",") }.joined(separator: "|"), privacy: .public)")
        case let .labsWriteback(auto, overwrite):
            let features = FeatureSettingsStore.shared
            if let auto { features.lyricsAutoWriteback = auto }
            if let overwrite { features.lyricsAutoWritebackOverwrite = overwrite }
            Task { await features.save() }
            logger.notice("debug labs writeback auto=\(features.lyricsAutoWriteback, privacy: .public) overwrite=\(features.lyricsAutoWritebackOverwrite, privacy: .public)")
        case let .notchPreview(state):
            NotchCornerLive.shared.pinPreview(state == "expanded" ? .expanded : state == "collapsed" ? .collapsed : nil)
            logger.notice("debug notch preview state=\(state, privacy: .public)")
        case let .notchLyricList(on, lines, secondary):
            let s = AppSettings.shared
            if let on { s.notchExpandedLyricList = on }
            if let lines { s.notchExpandedLyricListLines = NotchExpandedMetrics.clampedLyricListLineCount(lines) }
            if let secondary { s.notchSecondaryLine = secondary }
            logger.notice("debug notch lyric list on=\(s.notchExpandedLyricList, privacy: .public) lines=\(s.notchExpandedLyricListLines, privacy: .public) secondary=\(s.notchSecondaryLine.rawValue, privacy: .public)")
        case let .wordFormatSwitch(state, format, done, total, removing):
            let formats = format.flatMap(LyricsWordFormat.init(rawValue:)).map { [$0] }
                ?? Array(FeatureSettingsStore.shared.lyricsWordFormats.prefix(1))
            let display: LyricsWordFormatSwitchMonitor.Display? = switch state {
            case "idle": .idle
            case "backup": .backingUp
            case "waiting": .phase(.waiting)
            case "converting": .phase(.converting(done: min(done ?? 0, total ?? 0), total: total ?? 0))
            case "finished": .phase(.finished(total: total ?? 0))
            case "queued": .phase(.queued)
            default: nil
            }
            if state == "poll" {
                LyricsWordFormatSwitchMonitor.shared.requested(formats, removing: removing.compactMap(LyricsWordFormat.init(rawValue:)))
            } else if let display {
                LyricsWordFormatSwitchMonitor.shared.simulate(display, formats: formats,
                                                              removing: removing.compactMap(LyricsWordFormat.init(rawValue:)))
            }
            logger.notice("debug word format switch state=\(state, privacy: .public)")
        case let .notchPassThrough(x, y):
            NotchLyricsWindowController.shared.simulatePassThrough(at: CGPoint(x: x, y: y))
            logger.notice("debug notch pass-through x=\(x, privacy: .public) y=\(y, privacy: .public)")
        case let .notchPointer(x, y):
            NotchLyricsWindowController.shared.simulatePointer(at: CGPoint(x: x, y: y))
            logger.notice("debug notch pointer x=\(x, privacy: .public) y=\(y, privacy: .public)")
        case .notchPassThroughOff:
            NotchLyricsWindowController.shared.simulatePassThrough(at: nil)
            logger.notice("debug notch pass-through off")
        case let .notchHover(path, stepSecs):
            NotchLyricsWindowController.shared.simulateHover(path: path, stepSecs: stepSecs)
            logger.notice("debug notch hover points=\(path.count, privacy: .public) step=\(stepSecs, privacy: .public)")
        case .notchHoverOff:
            NotchLyricsWindowController.shared.endSimulatedHover()
            logger.notice("debug notch hover off")
        case let .notchHint(key):
            NotchDebugHover.hintKeys.send(key)
            logger.notice("debug notch hint key=\(key ?? "-", privacy: .public)")
        case .importLibrary:
            AppActions.shared.requestLyricsManagerSheet(.importLibrary, open: false)
            logger.notice("debug import library")
        case let .managerDecision(key):
            AppActions.shared.requestLyricsManagerSheet(.decision(key: key), open: false)
            logger.notice("debug manager decision key=\(key == nil ? "selected" : "given", privacy: .public)")
        case let .lyricsSearch(key):
            lyricsSearchGeneration += 1
            openLyricsSearch(key: key, background: WindowActivation.isBackground, invisible: WindowActivation.isInvisible,
                             generation: lyricsSearchGeneration, attempt: 0)
        case let .lyricsWriteback(step):
            NotificationCenter.default.post(name: lyricsWritebackNotification, object: step)
            logger.notice("debug lyrics writeback step=\(step, privacy: .public)")
        case let .importWatch(path):
            LyricsImportWatcher.shared.setFolder(path.map { URL(fileURLWithPath: $0, isDirectory: true) })
            logger.notice("debug import watch on=\(path != nil, privacy: .public)")
        case let .importLyricsFolder(path):
            AppActions.shared.requestLyricsManagerSheet(.importFolder(URL(fileURLWithPath: path, isDirectory: true)), open: false)
            logger.notice("debug import lyrics folder")
        case let .importLyrics(paths):
            AppActions.shared.requestLyricsImport(key: nil, urls: paths.map { URL(fileURLWithPath: $0) })
            logger.notice("debug import lyrics files=\(paths.count, privacy: .public)")
        case let .fontImport(path):
            let url = URL(fileURLWithPath: path)
            do {
                try CustomFontStore.shared.importFont(from: url)
                logger.notice("debug font import ok file=\(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.notice("debug font import failed file=\(url.lastPathComponent, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        case let .fontRemove(family):
            guard let font = CustomFontStore.shared.fonts.first(where: { $0.familyName == family }) else {
                logger.notice("debug font remove: not an imported family \(family, privacy: .public)")
                return
            }
            logger.notice("debug font remove family=\(family, privacy: .public)")
            CustomFontStore.shared.remove(font)
        case let .fontFamily(surface, family):
            setFontFamily(surface: surface, family: family)
        case .milestonePreview:
            ListenMilestoneCenter.shared.preview()
            logger.notice("debug milestone preview")
        case .releaseClosedWindows:
            ClosedWindowContent.releaseDeferred(reason: "debug")
            logger.notice("debug release closed windows")
        case let .managerList(op):
            MainThreadGapProbe.label = op
            logger.notice("debug manager list op=\(op, privacy: .public)")
            NotificationCenter.default.post(name: managerListNotification, object: op)
        case let .mainThreadGaps(on, minMs):
            MainThreadGapProbe.setRunning(on, minMs: minMs ?? 100)
            logger.notice("debug main thread gaps on=\(on, privacy: .public) min=\(minMs ?? 100, privacy: .public)")
        case let .mainThreadStall(seconds, throttle):
            logger.notice("debug main thread stall seconds=\(seconds, privacy: .public) throttle=\(throttle ?? "-", privacy: .public)")
            MainThreadWatchdog.shared.simulateThrottle(throttle.flatMap(MainThreadThrottle.Reading.init(simulating:)))
            Thread.sleep(forTimeInterval: seconds)
            MainThreadWatchdog.shared.simulateThrottle(nil)
        case .saveConfig:
            Task { @MainActor in
                let ok = await ConfigStore.shared.save()
                logger.notice("debug config save ok=\(ok, privacy: .public)")
            }
        case let .panelDrag(from, to, via, inGallery):
            panelDrag(from: from, to: to, via: via, inGallery: inGallery)
        case let .panelClick(at, inGallery):
            panelClick(at: at, inGallery: inGallery)
        case let .windowClick(window, at):
            windowClick(named: window, at: at)
        case let .windowKey(window, key, command):
            windowKey(named: window, key: key, command: command)
        case let .panelScroll(at, dy, trackpad, steps):
            panelScroll(at: at, dy: dy, trackpad: trackpad, steps: steps)
        case let .panelPin(on):
            MenuBarPanelDebugState.pinned = on
            logger.notice("debug panel pin \(on, privacy: .public)")
        case let .holdOpens(on):
            DebugExternalOpens.holding = on
            if on { DebugExternalOpens.held = [] }
            logger.notice("debug hold opens \(on, privacy: .public)")
        case let .panelLayout(json):
            AppSettings.shared.menuBarPanelLayout = MenuBarPanelLayout.decode(json)
            logger.notice("debug panel layout \(AppSettings.shared.menuBarPanelLayout.encoded(), privacy: .public)")
        case let .reportingSwitchHint(bundleID):
            NotificationCenter.default.post(name: PlayerReportingDiagnostics.reportingSwitchHintNotification, object: nil,
                                            userInfo: [PlayerReportingDiagnostics.reportingSwitchBundleIDKey: bundleID])
            logger.notice("debug reporting switch hint \(bundleID, privacy: .public)")
        case let .knockout(leg, on):
            SourceKnockout.set(leg, out: !on)
            LocalPlaybackSource.shared.simulationChanged()
        case let .scrobbleHold(minutes, id):
            applyScrobbleHold(minutes: minutes, id: id)
        case let .menuBarCenter(center, ignoreNotch, screen, hover, click):
            if let ignoreNotch { MenuBarCenterLyrics.ignoresNotchForDebug = ignoreNotch }
            if let center { AppSettings.shared.menuBarLyricsPlacement = center ? .screenCenter : .statusItem }
            if let screen { AppSettings.shared.menuBarCenterScreen = screen }
            MenuBarStatusItem.shared.setNeedsRefresh()
            MenuBarStatusItem.shared.debugCenterInput(
                hover: hover, click: click.map { $0 == "right" ? MenuBarCenterLyrics.Click.menu : .primary })
            logger.notice("debug menubar center=\(String(describing: center), privacy: .public) ignoreNotch=\(String(describing: ignoreNotch), privacy: .public)")
        case let .menuBarDisplay(artwork, content, iconSize, iconStyle, hoverControls, secondary, alignment, iconAnimates,
                                 keepPaused):
            if let artwork { AppSettings.shared.menuBarIconShowsArtwork = artwork }
            if let iconAnimates { AppSettings.shared.menuBarIconAnimates = iconAnimates }
            if let value = content.flatMap(MenuBarLyricsContent.init(rawValue:)) { AppSettings.shared.menuBarLyricsContent = value }
            if let value = iconSize.flatMap(MenuBarIconSize.init(rawValue:)) { AppSettings.shared.menuBarIconSize = value }
            if let value = iconStyle.flatMap(MenuBarIconStyle.init(rawValue:)) { AppSettings.shared.menuBarIconStyle = value }
            if let hoverControls { AppSettings.shared.menuBarHoverShowsControls = hoverControls }
            if let keepPaused { AppSettings.shared.menuBarKeepsLyricsWhenPaused = keepPaused }
            if let value = secondary.flatMap(MenuBarSecondaryChoice.init(rawValue:)) { AppSettings.shared.menuBarSecondaryChoice = value }
            if let value = alignment.flatMap(LyricsRestingAlignment.init(rawValue:)),
               LyricsRestingAlignment.menuBarOptions.contains(value) {
                AppSettings.shared.menuBarLyricsAlignment = value
            }
            logger.notice("debug menubar display artwork=\(String(describing: artwork), privacy: .public) content=\(content ?? "-", privacy: .public) iconSize=\(iconSize ?? "-", privacy: .public) iconStyle=\(iconStyle ?? "-", privacy: .public) secondary=\(secondary ?? "-", privacy: .public) alignment=\(alignment ?? "-", privacy: .public) iconAnimates=\(String(describing: iconAnimates), privacy: .public) keepPaused=\(String(describing: keepPaused), privacy: .public)")
        case let .japaneseReading(style):
            AppSettings.shared.japaneseReadingStyle = style
            LocalPlaybackSource.shared.japaneseReading = style
            logger.notice("debug japanese reading \(style.rawValue, privacy: .public)")
        case let .lyricsWindowControls(percent, draft):
            if draft {
                LyricsWindowControlScaleDraft.shared.percent = percent
            } else {
                LyricsWindowControlScaleDraft.shared.percent = nil
                AppSettings.shared.lyricsWindowControlScalePercent = percent
            }
            logger.notice("debug lyrics window controls \(percent, privacy: .public)% draft=\(draft, privacy: .public)")
        case let .lyricsWindowPointer(inside):
            LyricsWindowRemote.shared.simulatePointer(inside: inside)
            logger.notice("debug lyrics window pointer inside=\(inside, privacy: .public)")
        case let .lyricsWindowTrafficHover(x, y):
            trafficHover(at: CGPoint(x: x, y: y))
        case .lyricsWindowTrafficHoverOff:
            trafficHover(at: nil)
        case let .lyricsWindowTrafficHoverLegacy(on):
            guard let window = visibleLyricsWindow else {
                logger.notice("debug lyrics window traffic hover legacy=\(on, privacy: .public): no lyrics window")
                return
            }
            let done = TitlebarButtonPlacement.rehangGroupHover(in: window, atSystemDefault: on)
            logger.notice("debug lyrics window traffic hover legacy=\(on, privacy: .public) rehung=\(done, privacy: .public)")
        case let .lyricsWindowKey(override):
            LyricsWindowRemote.shared.setKeyOverride(override)
            logger.notice("debug lyrics window key override=\(override.map { String($0) } ?? "auto", privacy: .public)")
        case let .lyricsWindowFullScreen(on):
            LyricsWindowRemote.shared.setFullScreen(on)
            logger.notice("debug lyrics window fullscreen on=\(on, privacy: .public)")
        case let .lyricsWindowPreview(mini):
            UserDefaults.standard.set(mini, forKey: LyricsWindowPreviewStage.showsMiniStorageKey)
            logger.notice("debug lyrics window preview mini=\(mini, privacy: .public)")
        case let .rainbow(overlay, notch, menuBar):
            if let overlay { AppSettings.shared.overlayRainbow = overlay }
            if let notch { AppSettings.shared.notchLyricsColor = notch ? .rainbow : .accent }
            if let menuBar { AppSettings.shared.menuBarLyricsRainbow = menuBar }
            logger.notice("debug rainbow overlay=\(String(describing: overlay), privacy: .public) notch=\(String(describing: notch), privacy: .public) menubar=\(String(describing: menuBar), privacy: .public)")
        case let .captureHide(overlay, notch, mini):
            // 悬浮歌词那颗经设置页同一个 Binding:写设置之后还要让开着的窗口生效。
            if let overlay { AutoHideItem.duringScreenCapture.binding(for: .desktopOverlay).wrappedValue = overlay }
            if let notch { AutoHideItem.duringScreenCapture.binding(for: .notch).wrappedValue = notch }
            if let mini { AppSettings.shared.lyricsWindowMiniHideDuringScreenCapture = mini }
            logger.notice("debug capture hide overlay=\(String(describing: overlay), privacy: .public) notch=\(String(describing: notch), privacy: .public) mini=\(String(describing: mini), privacy: .public)")
        case let .adHide(overlay, notch, mini):
            if let overlay { AutoHideItem.duringAds.binding(for: .desktopOverlay).wrappedValue = overlay }
            if let notch { AutoHideItem.duringAds.binding(for: .notch).wrappedValue = notch }
            if let mini { AppSettings.shared.lyricsWindowMiniHideDuringAds = mini }
            logger.notice("debug ad hide overlay=\(String(describing: overlay), privacy: .public) notch=\(String(describing: notch), privacy: .public) mini=\(String(describing: mini), privacy: .public)")
        case let .noLyricsHide(overlay, notch, mini):
            if let overlay { AutoHideItem.whenNoLyrics.binding(for: .desktopOverlay).wrappedValue = overlay }
            if let notch { AutoHideItem.whenNoLyrics.binding(for: .notch).wrappedValue = notch }
            if let mini { AppSettings.shared.lyricsWindowMiniHideWhenNoLyrics = mini }
            logger.notice("debug no-lyrics hide overlay=\(String(describing: overlay), privacy: .public) notch=\(String(describing: notch), privacy: .public) mini=\(String(describing: mini), privacy: .public)")
        case let .noLyricsTitle(overlay, menuBar):
            if let overlay { AppSettings.shared.overlayShowsTitleWhenNoLyrics = overlay }
            if let menuBar { AppSettings.shared.menuBarShowsTitleWhenNoLyrics = menuBar }
            logger.notice("debug no-lyrics title overlay=\(String(describing: overlay), privacy: .public) menubar=\(String(describing: menuBar), privacy: .public)")
        case let .touchBarDisplay(color):
            AppSettings.shared.touchBarLyricsColorMode = color
            logger.notice("debug touch bar display color=\(color.rawValue, privacy: .public)")
        case let .notchLyricsColor(color, hex):
            if let hex { AppSettings.shared.notchLyricsColorHex = hex }
            AppSettings.shared.notchLyricsColor = color
            logger.notice("debug notch lyrics color=\(color.rawValue, privacy: .public) hex=\(hex ?? "nil", privacy: .public)")
        case let .touchBarTyping(override):
            TouchBarLyricsController.shared.setTypingOverride(override)
            logger.notice("debug touch bar typing override=\(override.map { String($0) } ?? "auto", privacy: .public)")
        case let .managerInstrumental(key, on):
            Task {
                let ok = await EnrichCacheStore.shared.setInstrumental(key: key, on)
                logger.notice("debug manager instrumental on=\(on, privacy: .public) ok=\(ok, privacy: .public)")
            }
        case let .externalEdit(key):
            let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            LyricsExternalEditor.shared.open(artist: parts.first ?? "", title: parts.count > 1 ? parts[1] : "",
                                             album: parts.count > 2 ? parts[2] : "", key: key, launchesEditor: false)
            logger.notice("debug external edit opened")
        case let .managerVisibility(override):
            NotificationCenter.default.post(name: managerVisibilityNotification, object: override.map { NSNumber(value: $0) })
            logger.notice("debug manager visibility override=\(override.map { String($0) } ?? "auto", privacy: .public)")
        case let .settingsVisibility(override):
            NotificationCenter.default.post(name: settingsVisibilityNotification, object: override.map { NSNumber(value: $0) })
            logger.notice("debug settings visibility override=\(override.map { String($0) } ?? "auto", privacy: .public)")
        case let .engineAlive(override):
            LocalPlaybackSource.shared.setEngineDaemonPresenceOverride(override)
        case let .engineBackgroundItem(disabled):
            EngineServiceManager.setBackgroundItemDisabledOverride(disabled)
        case let .onboardingStep(step):
            NotificationCenter.default.post(name: onboardingStepNotification, object: step)
            logger.notice("debug onboarding step=\(String(describing: step), privacy: .public)")
        }
    }

    /// `debug/font-family`:名单同 `LyrimuseDeepLink.fontFamilySurfaces`,两处同步改。
    private static func setFontFamily(surface: String, family: String) {
        let s = AppSettings.shared
        switch surface {
        case "overlay": s.fontFamilyName = family
        case "notch": s.notchFontFamilyName = family
        case "menubar": s.menuBarLyricsFontFamily = family
        case "window": s.lyricsWindowFontFamily = family
        case "mini": s.lyricsWindowMiniFontFamily = family
        default:
            logger.notice("debug font family: unknown surface \(surface, privacy: .public)")
            return
        }
        logger.notice("debug font family surface=\(surface, privacy: .public) family=\(family.isEmpty ? "system" : family, privacy: .public)")
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
                "styleMask": w.styleMask.rawValue,
                "resizable": w.styleMask.contains(.resizable),
                "contentMinSize": [w.contentMinSize.width, w.contentMinSize.height],
                "isKey": w.isKeyWindow,
                "onActiveSpace": w.isOnActiveSpace,
                "occlusionVisible": w.occlusionState.contains(.visible),
                "level": w.level.rawValue,
                // `screencapture -x -o -l <windowNumber>` 用的窗口号;invisible = 隐身开窗压在墙纸后面(14 章决策 218)。
                "windowNumber": w.windowNumber,
                "invisible": WindowActivation.isHidden(w),
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
            "notch": NotchLyricsWindowController.shared.debugState,
            "realAudio": RealAudioMeter.shared.debugState,
            "lyricsWindowChrome": LyricsWindowRemote.shared.chromeDebugState,
            // 悬浮歌词关着时不碰 `.shared`:读一下就会建出窗口。
            "overlay": AppSettings.shared.classicOverlayEnabled ? LyricsOverlayWindowController.shared.debugState as Any : NSNull(),
            "menuBarPanel": ["open": MenuBarStatusItem.shared.isPanelOpen,
                             "quick": MenuBarPanelDebugState.quickTarget.map { $0 as Any } ?? NSNull(),
                             "editing": MenuBarPanelDebugState.editing,
                             "layout": AppSettings.shared.menuBarPanelLayout.encoded()],
            "knockedOut": SourceKnockout.knockedOut,
            // 导入字体(字体选单「已导入」区)、此刻能用的字体族(后台重读好之前是 null)、五处字体设置(空串 = 系统字体)。
            "fonts": [
                "imported": CustomFontStore.shared.fonts.map { ["family": $0.familyName, "files": $0.fileNames] },
                "available": CustomFontStore.shared.availableFamilies.map { $0.sorted() as Any } ?? NSNull(),
                "settings": ["overlay": s.fontFamilyName, "notch": s.notchFontFamilyName, "menubar": s.menuBarLyricsFontFamily,
                             "window": s.lyricsWindowFontFamily, "mini": s.lyricsWindowMiniFontFamily],
            ] as [String: Any],
            // `debug/hold-opens` 开着时点了没打开、只记下的外部链接,按点的先后。
            "heldOpens": ["holding": DebugExternalOpens.holding, "urls": DebugExternalOpens.held],
            // 读取器此刻解到哪一版;`published` 是按版本重算的各处订阅的那个信号(`enrichContentVersion`)。
            "enrichCache": EnrichCacheReader.debugState.merging(
                ["published": LocalPlaybackSource.shared.enrichContentVersion?.description ?? NSNull()]) { a, _ in a },
            // 设置页「网页版」卡每个平台配了哪些浏览器、「+」菜单列哪些(跟菜单同一个函数)、
            // 引导页「配对浏览器」那一步铺哪些(含已配对),都按界面上的顺序。
            "webPlayers": Dictionary(uniqueKeysWithValues: BrowserPositionProbe.supportedPlatforms.map { platform in
                (platform.id, ["paired": BrowserPairing.pairedBrowsers(platformID: platform.id),
                               "menu": BrowserPairing.addableBrowsers(platformID: platform.id),
                               "candidates": BrowserPairing.candidateBrowsers(platformID: platform.id)])
            }),
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
            "fullDiskAccess": FullDiskAccessPermission.shared.debugState,
            "touchBarAvailability": TouchBarAvailability.shared.debugState,
            // 后台读的状态文件此刻发布出来的结论:Last.fm 镜像(`loaded` 为 false = 第一次还没读完)、引擎报的网络不通、
            // ListenBrainz 令牌被拒、网页推送判定、Last.fm 统计读到的 feed、逐字格式切换那一行、登录项上次问到的系统状态。
            "stateFiles": [
                "lastfmMirror": ["loaded": LastfmMirrorStatusWatcher.shared.loaded,
                                 "error": LastfmMirrorStatusWatcher.shared.info.map { $0.error as Any } ?? NSNull(),
                                 "at": LastfmMirrorStatusWatcher.shared.info.map { $0.at as Any } ?? NSNull(),
                                 "keyRejected": LastfmMirrorStatusWatcher.shared.info.map { $0.keyRejected as Any } ?? NSNull()],
                "engineNetworkDown": LocalPlaybackSource.shared.engineNetworkDown,
                "engineNotRunning": LocalPlaybackSource.shared.engineNotRunning,
                "listenBrainz": ["loaded": ListenBrainzSubmitStatusWatcher.shared.loaded,
                                 "since": ListenBrainzSubmitStatusWatcher.shared.info.map { $0.since as Any } ?? NSNull()],
                "relayPush": String(describing: RelayPushStatusWatcher.shared.verdict),
                "lastfmStats": LastfmStatsService.shared.debugState,
                "wordFormatSwitch": String(describing: LyricsWordFormatSwitchMonitor.shared.display),
                "loginItem": LoginItemManager.shared.lastStatus.map { String(describing: $0) as Any } ?? NSNull(),
            ],
            "simulation": PlaybackSimulation.current.map { sim -> Any in
                ["title": sim.title, "artist": sim.artist, "positionSecs": sim.elapsed(at: Date()),
                 "playing": sim.isPlaying(at: Date()), "ad": sim.ad, "idle": sim.idle]
            } ?? NSNull(),
        ]
    }

    private static func writeDiagnostics() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let url = outputDir.appendingPathComponent("diagnostics-\(stamp).zip")
        Task { @MainActor in
            guard FileIO.createDirectory(outputDir) else { return }
            await DiagnosticsExporter.export(to: url)
            let written = FileManager.default.fileExists(atPath: url.path)
            logger.notice("debug diagnostics \(written ? "written" : "failed", privacy: .public): \(url.path, privacy: .public)")
        }
    }

    /// `debug/app-move`:同启动时那一问,只是不重开、不退出,目标默认不是「应用程序」文件夹。
    private static func appMove(source: String?, destination: String?, answer: Bool?) {
        let sourceURL = source.map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL
        let directory = destination.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? outputDir.appendingPathComponent("app-move-target")
        guard directory.standardizedFileURL.path != AppLocationPrompt.applicationsDirectory.path else {
            logger.error("debug app-move refused: the target must not be /Applications")
            return
        }
        Task { @MainActor in
            let location = AppLocationPrompt.kind(of: sourceURL)
            let declined = UserDefaults.standard.string(forKey: AppLocationPrompt.declinedVersionKey)
            let asks = AppLocation.shouldPrompt(location, declinedVersion: declined, currentVersion: AppLocationPrompt.currentVersion)
            var outcome = AppLocationPrompt.Outcome.notNeeded
            if asks {
                FileIO.createDirectory(directory)
                outcome = await NestedLoopLaunch.run {
                    AppLocationPrompt.ask(location: location, source: sourceURL, into: directory,
                                          activate: !WindowActivation.isBackground, answer: answer)
                }
                if outcome == .declined {
                    UserDefaults.standard.set(AppLocationPrompt.currentVersion, forKey: AppLocationPrompt.declinedVersionKey)
                }
            }
            var report: [String: Any] = ["source": sourceURL.path, "location": String(describing: location), "asks": asks,
                                         "declinedVersionBefore": declined ?? NSNull(), "outcome": String(describing: outcome)]
            if case let .moved(destination, replaced) = outcome {
                report["destination"] = destination.path
                report["replaced"] = replaced?.path ?? NSNull()
            }
            let url = outputDir.appendingPathComponent("app-move.json")
            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                guard let data = SafeSerialization.jsonData(report, options: [.prettyPrinted, .sortedKeys]) else { return }
                try data.write(to: url, options: .atomic)
                logger.notice("debug app-move written: \(url.path, privacy: .public)")
            } catch {
                logger.error("debug app-move failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `debug/scrobble-hold`:改数据目录里的租约表(空了就删文件),再把改完的样子写进 debug 输出目录的 `scrobble-hold.json`,
    /// 脚本按它确认开关真的开上了。
    private static func applyScrobbleHold(minutes: Int, id: String?) {
        let url = LyrimusePaths.configFile(ScrobbleHold.fileName)
        let leases = ScrobbleHold.updated(ScrobbleHold.leases(from: FileIO.read(url)), minutes: minutes, id: id, now: Date())
        let saved: Bool
        if leases.isEmpty {
            saved = !FileManager.default.fileExists(atPath: url.path) || FileIO.remove(url)
        } else {
            saved = ScrobbleHold.encode(leases).map { FileIO.write($0, to: url) } ?? false
        }
        if saved { DiscordPresenceController.shared.scrobbleHoldChanged(leases) }
        let report = ScrobbleHold.encode(saved ? leases : []) ?? Data()
        if FileIO.createDirectory(outputDir) {
            _ = FileIO.write(report, to: outputDir.appendingPathComponent("scrobble-hold.json"))
        }
        logger.notice("debug scrobble hold minutes=\(minutes, privacy: .public) id=\(id ?? "-", privacy: .public) saved=\(saved, privacy: .public) holds=\(leases.count, privacy: .public)")
    }

    private static func writeTelemetryPreview() {
        let url = outputDir.appendingPathComponent("telemetry-preview.json")
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                try await TelemetryService.shared.previewHeartbeat().write(to: url, options: .atomic)
                logger.notice("debug telemetry preview written: \(url.path, privacy: .public)")
            } catch {
                logger.error("debug telemetry preview failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 写 `playcount-family.json`;带次数时等 Last.fm 答完才写,写完记一行日志。
    private static func writePlayCountFamily(artist: String, title: String, counts: Bool) {
        let url = outputDir.appendingPathComponent("playcount-family.json")
        Task { @MainActor in
            let probe = await LastfmStatsService.shared.probePlayCountFamily(artist: artist, title: title, withCounts: counts)
            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(probe).write(to: url, options: .atomic)
                logger.notice("debug playcount family written: \(url.path, privacy: .public) forms=\(probe.forms.count, privacy: .public)")
            } catch {
                logger.error("debug playcount family failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func writeState() {
        let url = outputDir.appendingPathComponent("state.json")
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let data = try SafeSerialization.jsonDataThrowing(state(), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            logger.notice("debug state written: \(url.path, privacy: .public)")
        } catch {
            logger.error("debug state failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 窗口快照

    /// 名字认这几个:settings / lyrics-manager / lyrics-search / onboarding(SwiftUI 场景 id)、lyrics-window(屏上那扇歌词窗口,
    /// 迷你面板或完整窗口)、panel(菜单栏面板)、overlay(悬浮歌词)、notch(灵动岛);都不是时按窗口标识、标题、类名里含这个名字找。
    /// 只找看得见的窗口,不为了拍照把窗口建出来。
    static func window(named name: String) -> NSWindow? {
        let visible = NSApp.windows.filter(\.isVisible)
        let key: String
        switch name {
        case "lyrics-search": key = "lyrics-quick-search"
        case "lyrics-window": return visibleLyricsWindow
        case "panel": return PanelEditBridge.shared.mainWindow.flatMap { $0.isVisible ? $0 : nil }
        case "panel-gallery": return PanelEditBridge.shared.galleryWindow.flatMap { $0.isVisible ? $0 : nil }
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
        let lyricsWindow: DebugLyricsWindowForm?
        let lyricsWindowMini: Bool
    }

    private static var checkpointSaved: Checkpoint?

    /// 验证时会开、会关的那几种窗口(SwiftUI 场景)。悬浮歌词、灵动岛、菜单栏这些常驻窗口不在这里:恢复时不碰它们的窗口,
    /// 只按开关设回去。歌词窗口也不在这里:它有迷你、完整两种形态,按形态记、按形态恢复(`restoreLyricsWindow`)。
    private static let sceneIDs = ["settings", "lyrics-manager", "lyrics-quick-search", "lyrics-share", "whats-new", "onboarding"]

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
            japaneseReading: s.japaneseReadingStyle,
            lyricsWindow: lyricsWindowForm(),
            lyricsWindowMini: UserDefaults.standard.bool(forKey: LyricsWindowSession.miniModeKey))
        logger.notice("debug checkpoint saved")
    }

    /// 此刻歌词窗口的形态:迷你面板在就是迷你(被「暂停时隐藏」这类规则藏着、最小化着也算,面板关掉后才放掉),
    /// 否则看完整那扇在不在屏上。
    private static func lyricsWindowForm() -> DebugLyricsWindowForm? {
        if LyricsMiniPanelHost.panel != nil { return .mini }
        return fullLyricsWindow() != nil ? .full : nil
    }

    /// 屏上的完整歌词窗口。按场景 id 前缀认,同 `visibleLyricsWindow`。
    private static func fullLyricsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && !($0 is LyricsMiniPanel) && $0.identifier?.rawValue.hasPrefix("lyrics-window") == true
        }
    }

    /// 歌词窗口回到记下时的形态。切回 / 开回走「切换迷你」那条动作:开着就两扇交接,「开着」(`np:lyricsWindowOpen`)照旧记着;
    /// 别写成关窗再开。回到完整那扇时不激活 App,开好摆到最前不当 key;迷你面板自己上屏,不摆(07 章决策 213)。
    private static func restoreLyricsWindow(_ saved: Checkpoint) {
        let now = lyricsWindowForm()
        switch DebugLyricsWindowRestore.plan(saved: saved.lyricsWindow, now: now) {
        case .keep:
            break
        case .close:
            (now == .mini ? LyricsMiniPanelHost.panel : fullLyricsWindow())?.close()
            UserDefaults.standard.set(saved.lyricsWindowMini, forKey: LyricsWindowSession.miniModeKey)
        case let .show(mini):
            WindowActivation.beginBackground()
            LyrimuseActionRunner.perform(.toggleLyricsWindowMiniHotkey, on: mini)
            if !mini { WindowActivation.surface(identifier: "lyrics-window") }
        }
        logger.notice("debug restore lyrics window saved=\(String(describing: saved.lyricsWindow), privacy: .public) now=\(String(describing: now), privacy: .public)")
    }

    private static func endSimulation() {
        guard PlaybackSimulation.isActive else { return }
        PlaybackSimulation.end()
        NowPlayingLocalFileModel.shared.update(nil)
        LocalPlaybackSource.shared.simulationChanged()
        logger.notice("debug simulate off")
    }

    /// 关掉记下之后才开出来的场景窗口、歌词窗口回到记下时的形态、收起记下时没开的面板;开关只设有变化的那几个
    /// (走同一套开关动作,不一下闪一串回声)。模拟播放不管记下时开没开,一律收掉。
    /// 隐身开窗压在墙纸后面的场景窗(`WindowActivation.isHidden`)不管有没有记下、记下时开没开,一律关掉:用户看不见它,
    /// 只可能是验证开的。还在等列表的 `debug/lyrics-search` 作废,悬停气泡收回。见 14 章决策 227。
    private static func restore() {
        endSimulation()
        lyricsSearchGeneration += 1
        if !hoverNoteQuery.isEmpty {
            hoverNoteQuery = ""
            NotificationCenter.default.post(name: hoverNoteNotification, object: hoverNoteQuery)
        }
        let saved = checkpointSaved
        for (id, window) in openSceneWindows() where WindowActivation.isHidden(window) || saved?.sceneWindows.contains(id) == false {
            window.close()
        }
        guard let saved else {
            logger.notice("debug restore: no checkpoint")
            return
        }
        restoreLyricsWindow(saved)
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

extension DebugDeepLinks {
    /// `debug/panel-drag`:往面板窗口送一串按下 → 拖动(经过 `via` 的每一段各 20 步)→ 松开,每步之间让出主线程一拍
    /// (SwiftUI 的拖动手势按事件逐个处理)。
    /// `inGallery`:按在编辑时旁边那块「可添加」面板上(坐标按那扇窗算,拖出窗外也照算)。
    static func panelDrag(from: CGPoint, to: CGPoint, via: [CGPoint] = [], inGallery: Bool = false) {
        let bridge = PanelEditBridge.shared
        guard let window = inGallery ? bridge.galleryWindow : bridge.mainWindow, window.isVisible else {
            logger.notice("debug panel drag: panel is not open")
            return
        }
        // 窗口高度每个事件现读:拖动中格子让位会多出一排,面板当场长高,拿开头那个高度换算,后面的点就整体偏一排。
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: window.frame.height - p.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        Task { @MainActor in
            if let e = event(.mouseMoved, from) { window.sendEvent(e) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let e = event(.leftMouseDown, from) { window.sendEvent(e) }
            let steps = 20
            var start = from
            for end in via + [to] {
                for i in 1...steps {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    let t = CGFloat(i) / CGFloat(steps)
                    let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    if let e = event(.leftMouseDragged, p) { window.sendEvent(e) }
                }
                start = end
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let e = event(.leftMouseUp, to) { window.sendEvent(e) }
            logger.notice("debug panel drag done")
        }
    }

    /// `debug/panel-click`:往面板窗口送一次按下 → 30 毫秒后松开(格子按住久了算长按,`panelDrag` 那样按着拖 0.4 秒点不成)。
    static func panelClick(at point: CGPoint, inGallery: Bool = false) {
        let bridge = PanelEditBridge.shared
        guard let window = inGallery ? bridge.galleryWindow : bridge.mainWindow, window.isVisible else {
            logger.notice("debug panel click: panel is not open")
            return
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: window.frame.height - point.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        Task { @MainActor in
            if let e = event(.mouseMoved) { window.sendEvent(e) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let e = event(.leftMouseDown) { window.sendEvent(e) }
            try? await Task.sleep(nanoseconds: 30_000_000)
            if let e = event(.leftMouseUp) { window.sendEvent(e) }
            logger.notice("debug panel click done")
        }
    }

    /// 最近一次 `debug/lyrics-search` 的代号。还在等列表读完的那一次代号对不上(来了新的一次,或 `restore` 作废)就不再开窗。
    private static var lyricsSearchGeneration = 0

    /// `debug/lyrics-search`:按写法键开「搜索歌词…」窗口。歌词管理的列表还没读完时每 0.5 秒再找一次、最多 6 秒;
    /// 链接带了 `background=1` / `invisible=1` 的,晚开的那一次同样不激活 App、同样隐身(深链那一段时限已经过了)。
    private static func openLyricsSearch(key: String, background: Bool, invisible: Bool = false, generation: Int, attempt: Int) {
        guard generation == lyricsSearchGeneration else { return }
        let store = EnrichCacheStore.shared
        guard let summary = store.summary(forKey: key) else {
            let listReady = !store.isLoading && !store.summaries.isEmpty
            if !listReady, attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    openLyricsSearch(key: key, background: background, invisible: invisible, generation: generation, attempt: attempt + 1)
                }
                return
            }
            logger.notice("debug lyrics search: \(listReady ? "key not in lyrics manager list" : "lyrics manager list not loaded, open lyrics-manager first", privacy: .public)")
            return
        }
        let late = attempt > 0 && background
        if late, invisible { WindowActivation.beginInvisible(scenes: ["lyrics-quick-search"]) }
        if late { WindowActivation.beginBackground() }
        AppActions.shared.openLyricsSearch(for: LyricsSearchTarget(summary: summary))
        if late { WindowActivation.surface(identifier: "lyrics-quick-search") }
        logger.notice("debug lyrics search attempt=\(attempt, privacy: .public) background=\(background, privacy: .public)")
    }

    /// `debug/window-key`:往窗口里送一次按键(按下 → 30 毫秒后松开),经 `NSWindow.sendEvent`,跟真实按键同一条路;带 ⌘ 的先走
    /// `performKeyEquivalent`(SwiftUI 的 `.keyboardShortcut` 在那条路上),没人接再照普通按键送。不把窗口提到前面、不激活 App。
    /// 日志记下有没有被当快捷键接走、窗口是不是 key、App 在不在前台。
    static func windowKey(named name: String, key: String, command: Bool) {
        guard let window = window(named: name) else {
            logger.notice("debug window key: no visible window named \(name, privacy: .public)")
            return
        }
        guard let stroke = keyStroke(key) else { return }
        var flags: NSEvent.ModifierFlags = stroke.function ? [.function, .numericPad] : []
        if command { flags.insert(.command) }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                             characters: stroke.characters, charactersIgnoringModifiers: stroke.characters,
                             isARepeat: false, keyCode: stroke.keyCode)
        }
        Task { @MainActor in
            var equivalent = false
            if let down = event(.keyDown) {
                equivalent = command && window.performKeyEquivalent(with: down)
                if !equivalent { window.sendEvent(down) }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            if !equivalent, let up = event(.keyUp) { window.sendEvent(up) }
            logger.notice("debug window key done window=\(name, privacy: .public) key=\(key, privacy: .public) cmd=\(command, privacy: .public) equivalent=\(equivalent, privacy: .public) key window=\(window.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
        }
    }

    /// `debug/window-key` 的键:字符、键码(ANSI 键盘)、是不是功能键(方向键要带 `.function` / `.numericPad`,不然认不成移动)。
    private static func keyStroke(_ key: String) -> (characters: String, keyCode: UInt16, function: Bool)? {
        func function(_ scalar: Int) -> String { String(Character(UnicodeScalar(UInt16(scalar))!)) }
        switch key {
        case "up": return (function(NSUpArrowFunctionKey), 126, true)
        case "down": return (function(NSDownArrowFunctionKey), 125, true)
        case "left": return (function(NSLeftArrowFunctionKey), 123, true)
        case "right": return (function(NSRightArrowFunctionKey), 124, true)
        case "return": return ("\r", 36, false)
        case "escape": return ("\u{1B}", 53, false)
        case "tab": return ("\t", 48, false)
        case "space": return (" ", 49, false)
        default:
            let codes: [Character: UInt16] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
                "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            ]
            guard let c = key.first, key.count == 1, let code = codes[c] else { return nil }
            return (key, code, false)
        }
    }

    /// `debug/window-click`:往窗口里 (x, y) 处送一次按下 → 30 毫秒后松开,经 `NSWindow.sendEvent`,跟真实点按同一条路
    /// (SwiftUI 按钮只认这条路送来的事件,直接调视图的 `mouseDown` 不响应)。按下前 `preventWindowOrdering`:窗口不被提到前面,
    /// App 不激活。日志记下点按前后窗口是不是 key、App 在不在前台。
    static func windowClick(named name: String, at point: CGPoint) {
        guard let window = window(named: name) else {
            logger.notice("debug window click: no visible window named \(name, privacy: .public)")
            return
        }
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        let keyBefore = window.isKeyWindow
        Task { @MainActor in
            NSApp.preventWindowOrdering()
            if let e = event(.leftMouseDown) { window.sendEvent(e) }
            try? await Task.sleep(nanoseconds: 30_000_000)
            if let e = event(.leftMouseUp) { window.sendEvent(e) }
            logger.notice("debug window click done window=\(name, privacy: .public) at=\(point.x, privacy: .public),\(point.y, privacy: .public) keyBefore=\(keyBefore, privacy: .public) keyAfter=\(window.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
        }
    }
}

extension DebugDeepLinks {
    /// `debug/panel-scroll`:往面板窗口 (x, y) 处送滚动事件(坐标同 `panelDrag`),经 `MenuBarPanelWindow.sendEvent`,跟真实滚动
    /// 同一条路。滚轮:`steps` 格、每格 `dy` 行,没有阶段;触控板:began → `steps` 次 changed(每次 `dy` pt,带精确位移)→ ended。
    /// 造出来的事件不带「自然滚动」标记,`dy` 为正就是手指往上、调大。每步之间隔 16 毫秒。
    static func panelScroll(at point: CGPoint, dy: Double, trackpad: Bool, steps: Int) {
        guard let window = PanelEditBridge.shared.mainWindow, window.isVisible else {
            logger.notice("debug panel scroll: panel is not open")
            return
        }
        func event(phase: Int64, delta: Double) -> NSEvent? {
            let cocoa = window.convertPoint(toScreen: NSPoint(x: point.x, y: window.frame.height - point.y))
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: trackpad ? .pixel : .line, wheelCount: 1,
                                   wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0) else { return nil }
            cg.location = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
            if trackpad {
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: delta)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            }
            return NSEvent(cgEvent: cg)
        }
        // CGScrollPhase:1 began、2 changed、4 ended。
        let sequence: [(Int64, Double)] = trackpad
            ? [(1, 0)] + Array(repeating: (2, dy), count: steps) + [(4, 0)]
            : Array(repeating: (0, dy), count: steps)
        Task { @MainActor in
            for (phase, delta) in sequence {
                guard let e = event(phase: phase, delta: delta) else { continue }
                logger.notice("debug panel scroll event phase=\(e.phase.rawValue, privacy: .public) dy=\(e.scrollingDeltaY, privacy: .public) precise=\(e.hasPreciseScrollingDeltas, privacy: .public) inverted=\(e.isDirectionInvertedFromDevice, privacy: .public) at=\(e.locationInWindow.x, privacy: .public),\(e.locationInWindow.y, privacy: .public)")
                window.sendEvent(e)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            let anchors = PanelVolumeScrollAnchor.debugSummary(in: window)
            VolumeMonitor.readSystemVolume { state in
                logger.notice("debug panel scroll done volume=\(state.volume ?? -1, privacy: .public) muted=\(state.muted, privacy: .public) \(anchors, privacy: .public)")
            }
        }
    }
}

/// 菜单栏面板此刻翻在哪一格(深链取值,nil = 钮块网格或面板没开)。只给 `debug/state` 读,面板自己不读它。
/// `debug/hold-opens`:开着时外部链接只记下、不打开(不落盘),见 `LyricsSourceLinkOpener`。
@MainActor
enum DebugExternalOpens {
    static var holding = false
    static var held: [String] = []
}

@MainActor
enum MenuBarPanelDebugState {
    static var quickTarget: String?
    /// 面板在不在编辑布局。
    static var editing = false
    /// `debug/panel-pin`:开着时点到外面、切 App、切桌面空间都不收面板(不落盘)。
    static var pinned = false
}

/// `debug/main-thread-gaps` 的主线程心跳:每 10 毫秒一拍,两拍隔了门槛(默认 100 毫秒)以上记一行,带上最近一次 `debug/manager-list` 动作
/// 和这段时间里主线程自己用掉的 CPU 时间(`cpu`):墙钟停得比 CPU 久,多出来的是等页面换入、排不上核这类机器上的等待。
/// 挂在 `.common` 模式上,菜单、拖动期间照样打拍。只给本机量停顿用,默认不开。
@MainActor
enum MainThreadGapProbe {
    static var label = "idle"
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "main-thread-gaps")
    private static var timer: Timer?
    private static var last = CFAbsoluteTimeGetCurrent()
    private static var threshold = 0.1
    private static var lastCPU: UInt64 = 0

    static func setRunning(_ on: Bool, minMs: Int = 100) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        threshold = Double(minMs) / 1000
        lastCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        last = CFAbsoluteTimeGetCurrent()
        let t = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let gap = now - last
        last = now
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let cpuMs = Int((cpu &- lastCPU) / 1_000_000)
        lastCPU = cpu
        guard gap > threshold else { return }
        let reading = MainThreadThrottle.readOnCurrentThread()
        let note = MainThreadThrottle.logNote(reading.reasons, priority: reading.priority)
        logger.notice("gap \(Int(gap * 1000), privacy: .public) ms after [\(label, privacy: .public)] cpu \(cpuMs, privacy: .public) ms\(note, privacy: .public)")
    }
}
