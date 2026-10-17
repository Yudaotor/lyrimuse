import AppKit
import LyrimuseCore

/// 全局快捷键和 `lyrimuse://action/…` 共用的执行入口:同一件事两条路走到这里,行为和回声一致(14 章「深链」)。
/// `on`:开关类的目标状态,nil = 翻转(快捷键永远是 nil);`stepMs`:歌词提前 / 延后这一下的步长,nil = 设置里的步长。
@MainActor
enum LyrimuseActionRunner {
    static func perform(_ action: LyrimuseAction, on: Bool? = nil, stepMs: Int? = nil) {
        switch action {
        // 必须先判断 settings.classicOverlayEnabled 再碰 LyricsOverlayWindowController.shared:真正引用到 `.shared`
        // 才会执行 init() 建窗口,而 init() 订阅 PlaybackCoordinator 的 Combine sink 在订阅瞬间就会用当下的 isVisible
        // 触发一次显示 / 隐藏 —— 下面「锁定位置」因此必须先判断 classicOverlayEnabled:用户只开了灵动岛、关掉桌面悬浮
        // 歌词时,那个动作仍然可以被触发,按下后会把从未构造过的经典悬浮窗凭空建出来并常驻显示。
        //
        // 但「显示/隐藏悬浮歌词」**不能**加同一个判断:它切换的就是 classicOverlayEnabled 本身,再 guard 一次就变成
        // 「只能关、不能开」。这里碰 .shared 是用户主动要求打开 / 关闭它,不是被动误触构造。
        case .toggleOverlay:
            LyricsOverlayWindowController.shared.setVisible(on ?? !AppSettings.shared.classicOverlayEnabled)
        case .toggleLockPosition:
            // 只对桌面悬浮歌词有意义(灵动岛贴着刘海,没有「位置」可锁);不适用时说一句,全局动作最忌讳「按了没动静」。
            guard AppSettings.shared.classicOverlayEnabled else {
                GlobalHotkeys.flashHint(icon: "lock.slash", text: L10n.t("锁定位置仅对桌面悬浮歌词有效"))
                return
            }
            let overlay = LyricsOverlayWindowController.shared
            let newValue = on ?? !overlay.isPositionLocked
            // 跟 MenuBarStatusMenu.swift 的「锁定位置」Toggle 绑定逻辑一致:持久化偏好 + 让窗口真正生效,两步都要做。
            AppSettings.shared.lockPosition = newValue
            overlay.setLocked(newValue)
            GlobalHotkeys.flashHint(icon: newValue ? "lock" : "lock.open",
                                    text: newValue ? L10n.t("已锁定位置") : L10n.t("已解锁位置"))
        case .openLyricsManagerHotkey:
            AppActions.shared.openLyricsManager?()
        case .openLyricsWindowHotkey:
            AppActions.shared.openLyricsWindow?()
        case .toggleLyricsWindowMiniHotkey:
            // 开着就切到另一种形态,没开就直接开成迷你(07 章决策 117);`on` 给了就是「要不要迷你」。
            // 开着时窗口控制器收 requestForm 的通知当场切。
            let defaults = UserDefaults.standard
            let mini = on ?? LyricsWindowMiniToggle.targetIsMini(
                windowOpen: defaults.bool(forKey: LyricsWindowSession.openKey),
                isMini: defaults.bool(forKey: LyricsWindowSession.miniModeKey))
            LyricsWindowSession.requestForm(mini: mini)
            AppActions.shared.openLyricsWindow?()
        case .openSettingsHotkey:
            AppActions.shared.openSettings?()
        // 播放控制三个动作:先校验自动化权限 —— 没问过就顺手弹一次系统授权对话框,已经拒绝过就不弹窗、只用
        // NSSound.beep() 给一个「没有生效」的听觉反馈(跟 ShortcutRecorder.swift 录制失败时同一个信号)。只有选了
        // Apple Music 才真的会走到这个权限检查,见 MusicAutomationPermission.checkForCurrentPlayer 注释。
        //
        // 必须用 checkForCurrentPlayerSafely(异步)而不是 checkForCurrentPlayer(同步):同步版本在还没问过时会直接
        // 触达 AEDeterminePermissionToAutomateTarget,这个 API 在主线程调用可能永久挂起,见那边定义处的注释。
        case .playPauseHotkey:
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                // 乐观回声版:歌词窗封面缩放 / 图标点击即动(见 userTogglePlayPause)。
                PlaybackCoordinator.shared.userTogglePlayPause()
            }
        case .nextTrackHotkey:
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                MusicPlaybackController.nextTrack()
            }
        case .previousTrackHotkey:
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                MusicPlaybackController.previousTrack()
            }
        // 单曲歌词时间轴微调 —— 不需要自动化权限(不碰播放器,只改 LyricsSyncEngine 的匹配位置),随时可用。步长默认
        // 现读 AppSettings,跟菜单里的偏移行(`MenuStepperRowView.lyricsOffset`)共用同一个值。改完闪一条「歌词偏移 +0.50s」(累计值)。
        case .lyricsAdvanceHotkey:
            showOffsetBanner(PlaybackCoordinator.shared.nudgeLyricsOffset(by: stepMs ?? AppSettings.shared.lyricsOffsetStepMs))
        case .lyricsDelayHotkey:
            showOffsetBanner(PlaybackCoordinator.shared.nudgeLyricsOffset(by: -(stepMs ?? AppSettings.shared.lyricsOffsetStepMs)))
        // 跟 ± 两个成组:调歪了一键回正。用三处菜单共用的 resetLyricsOffset(),不自己复制一份「写回 0」的逻辑。
        case .lyricsOffsetResetHotkey:
            PlaybackCoordinator.shared.resetLyricsOffset()
            showOffsetBanner(0)
        // 「歌词错了 / 没有」恰恰是在写别的东西时发现的,是全局动作最典型的用法。
        case .lyricsQuickSearchHotkey:
            AppActions.shared.openLyricsQuickSearch?()
        // 译文 / 读音两个显示开关都带回声:当下这首没有译文 / 没有注音时画面不会有任何变化,没有提示就分不清是没按中
        // 还是没内容。悬浮歌词、歌词窗口各有一份(04 章决策 42),两份一起切:有一处开着就都关,都关着就都开。
        case .toggleTranslationHotkey:
            let s = AppSettings.shared
            let show = on ?? !(s.overlayShowTranslation || s.showTranslation)
            s.overlayShowTranslation = show
            s.showTranslation = show
            GlobalHotkeys.flashHint(icon: show ? "character.book.closed" : "character.book.closed.fill",
                                    text: show ? L10n.t("已显示译文") : L10n.t("已隐藏译文"))
        // 绑的是两面的「读音」开关,不是在拼音 / 粤拼 / 日文 / 韩文之间轮换;分语言那四个勾选留在设置页。
        case .toggleRomanizationHotkey:
            let s = AppSettings.shared
            let show = on ?? !(s.overlayShowRomanization || s.showRomanization)
            s.overlayShowRomanization = show
            s.showRomanization = show
            GlobalHotkeys.flashHint(icon: "textformat.abc",
                                    text: show ? L10n.t("已显示读音") : L10n.t("已隐藏读音"))
        // 灵动岛走 setVisible(_:) 而不是直接翻 AppSettings 那个布尔值:那个方法是打开 / 关闭的唯一入口,连「顺手把已
        // 配置好的隐藏偏好也应用上」这一步都在里面(同 MenuBarStatusMenu.toggleNotchOverlay)。
        case .toggleNotchOverlayHotkey:
            let show = on ?? !AppSettings.shared.notchOverlayEnabled
            NotchLyricsWindowController.shared.setVisible(show)
            GlobalHotkeys.flashHint(icon: show ? "inset.filled.topthird.square" : "square.slash",
                                    text: show ? L10n.t("已显示灵动岛歌词") : L10n.t("已隐藏灵动岛歌词"))
        // 菜单栏歌词没有独立的 WindowController(就画在状态栏那一行上),直接读写 AppSettings 就够。
        case .toggleMenuBarLyricsHotkey:
            let show = on ?? !AppSettings.shared.showLyricsInMenuBar
            AppSettings.shared.showLyricsInMenuBar = show
            GlobalHotkeys.flashHint(icon: "menubar.rectangle",
                                    text: show ? L10n.t("已显示菜单栏歌词") : L10n.t("已隐藏菜单栏歌词"))
        // 触控栏歌词:照此刻看不看得见来展开 / 收起,总开关关着就先打开;别改成翻总开关(17 章决策 40)。
        // 没有触控栏、系统没有触控栏接口时不会有任何变化,同样回声说明。
        case .toggleTouchBarLyricsHotkey:
            let text: String
            switch TouchBarLyricsController.shared.toggleFromHotkey() {
            case .noTouchBar: text = L10n.t("未检测到触控栏")
            case .unavailable: text = L10n.t("本机系统未提供触控栏接口")
            case .turnOn, .expand: text = L10n.t("已展开触控栏歌词")
            case .collapse: text = L10n.t("已收起触控栏歌词")
            }
            GlobalHotkeys.flashHint(icon: SurfaceGlyph.touchBar.rawValue, text: text)
        // 悬浮歌词主字号一档档调,跟 ⚙ 菜单「字号」同一个步长和范围;悬浮歌词关着时不改,只说一句(同「锁定位置」)。
        // 到了上下限照样回声当前字号,不然分不清是没按中还是调不动了。
        case .overlayFontLargerHotkey, .overlayFontSmallerHotkey:
            let settings = AppSettings.shared
            guard settings.classicOverlayEnabled else {
                GlobalHotkeys.flashHint(icon: "textformat.size", text: L10n.t("调字号仅对桌面悬浮歌词有效"))
                return
            }
            let larger = action == .overlayFontLargerHotkey
            let next = AppSettings.steppedOverlayFontSize(from: settings.fontSize, direction: larger ? 1 : -1)
            if next != settings.fontSize { settings.fontSize = next }
            GlobalHotkeys.flashHint(icon: larger ? "textformat.size.larger" : "textformat.size.smaller",
                                    text: String(format: L10n.t("字号 %@pt"), "\(Int(next))"))
        // 一键收起悬浮歌词、灵动岛、菜单栏歌词(开会、共享屏幕),再按一下照收起前的样子恢复。
        case .toggleAllLyricsHotkey:
            toggleAllLyrics(on: on)
        // 先读这一首此刻的状态再写,界面都没开时也不会按反;按下去看不到星,做了什么都回声。
        case .toggleFavoriteHotkey:
            PlaybackCoordinator.shared.toggleFavoritedFromShortcut(on: on) { result in
                switch result {
                case .liked: GlobalHotkeys.flashHint(icon: "heart.fill", text: L10n.t("已喜欢"))
                case .unliked: GlobalHotkeys.flashHint(icon: "heart", text: L10n.t("已取消喜欢"))
                case .notPlaying: GlobalHotkeys.flashHint(icon: "heart.slash", text: L10n.t("未在播放"))
                case .unsupported: GlobalHotkeys.flashHint(icon: "heart.slash", text: L10n.t("当前播放器不支持喜欢"))
                case .needsPermission:
                    GlobalHotkeys.flashHint(icon: "heart.slash", text: L10n.t("需要在系统设置中允许控制 Apple Music"))
                }
            }
        case .openPlayerHotkey:
            IdlePlaybackActions.openPlayerApp(IdlePlaybackActions.player)
        }
    }

    /// 「隐藏/恢复全部歌词」收起前开着哪几个面。存在偏好里,重启之后也恢复得回来;键不带 `np:`,不随配置导出。
    static let hiddenSurfacesKey = "hotkey:hiddenLyricsSurfaces"

    /// 有面开着就全收起、记下是哪几个;都关着就按记下的打开,没记下就说一句。`on` = 要不要显示(0 收起、1 恢复)。
    /// 开关都走各自的唯一入口(同单独那几个快捷键),碰悬浮歌词的 `.shared` 前先看它开没开(见 `perform` 头上那段)。
    private static func toggleAllLyrics(on: Bool?) {
        let settings = AppSettings.shared
        let shown = [("overlay", settings.classicOverlayEnabled), ("notch", settings.notchOverlayEnabled),
                     ("menuBar", settings.showLyricsInMenuBar)].filter(\.1).map(\.0)
        let defaults = UserDefaults.standard
        if on.map({ !$0 }) ?? !shown.isEmpty {
            guard !shown.isEmpty else { return }
            defaults.set(shown, forKey: hiddenSurfacesKey)
            if shown.contains("overlay") { LyricsOverlayWindowController.shared.setVisible(false) }
            if shown.contains("notch") { NotchLyricsWindowController.shared.setVisible(false) }
            if shown.contains("menuBar") { settings.showLyricsInMenuBar = false }
            GlobalHotkeys.flashHint(icon: "eye.slash", text: L10n.t("已隐藏全部歌词"))
            return
        }
        let saved = defaults.stringArray(forKey: hiddenSurfacesKey) ?? []
        guard !saved.isEmpty else {
            if shown.isEmpty { GlobalHotkeys.flashHint(icon: "eye.slash", text: L10n.t("没有可恢复的歌词")) }
            return
        }
        defaults.removeObject(forKey: hiddenSurfacesKey)
        if saved.contains("overlay") { LyricsOverlayWindowController.shared.setVisible(true) }
        if saved.contains("notch") { NotchLyricsWindowController.shared.setVisible(true) }
        if saved.contains("menuBar") { settings.showLyricsInMenuBar = true }
        GlobalHotkeys.flashHint(icon: "eye", text: L10n.t("已恢复歌词显示"))
    }

    /// 这首歌的歌词时间轴直接设成 `ms`(`lyrimuse://action/lyrics-offset`)。按跟当前值的差走同一个 nudge,
    /// 不另写一份落盘;回声同提前 / 延后。
    static func setLyricsOffset(ms: Int) {
        let p = PlaybackCoordinator.shared
        showOffsetBanner(p.nudgeLyricsOffset(by: ms - p.trackLyricsOffsetMs))
    }

    /// 把毫秒偏移显示成 "+0.50s" / "-0.25s"。正号要显式带上 —— 只有减号的话,按了「提前」却看到一个没有符号的数字,
    /// 分不清方向。
    private static func showOffsetBanner(_ offsetMs: Int) {
        let seconds = Double(offsetMs) / 1000
        GlobalHotkeys.flashHint(icon: "timer", text: String(format: "%@ %+.2fs", L10n.t("歌词偏移"), seconds))
    }
}
