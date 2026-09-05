import AppKit
import KeyboardShortcuts
import LyrimuseCore

// A 组(显示/隐藏悬浮歌词、锁定/解锁位置、打开歌词管理、打开设置)复用已有能力,纯接线;
// B 组(播放/暂停、上下一首)是这个软件第一次拥有"控制播放"能力,靠 MusicPlaybackController
// 发 AppleScript 指令,复用已经拿到的自动化权限(见 MusicAutomationPermission)。
//
// 默认不预置任何按键组合——KeyboardShortcuts.Recorder 不预注册默认值时本来就是空的
// "点击录制"状态,下面这 16 个快捷键全部必须用户自己在设置里主动录制才会生效,不会有
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
    // 2026-08-31 加的六个。挑选判据是「别的 App 占着焦点时你还想按」—— 只在某扇窗已经
    // 在前台时才有意义的动作(随机/循环、置顶、全屏)刻意不给全局键,那是本地键该管的。
    static let lyricsQuickSearchHotkey = Self("lyricsQuickSearchHotkey")
    static let toggleTranslationHotkey = Self("toggleTranslationHotkey")
    static let toggleRomanizationHotkey = Self("toggleRomanizationHotkey")
    static let toggleNotchOverlayHotkey = Self("toggleNotchOverlayHotkey")
    static let toggleMenuBarLyricsHotkey = Self("toggleMenuBarLyricsHotkey")
    static let lyricsOffsetResetHotkey = Self("lyricsOffsetResetHotkey")

    /// 全部全局快捷键。撞键检查(见 ShortcutConflict)要遍历它——`KeyboardShortcuts.Name`
    /// 是个 struct 不是 enum,拿不到自动的 allCases,只能手工维护。
    ///
    /// ⚠️ 新增快捷键时**必须**同时加进这里和下面的 `title(for:)`,否则:漏了这里 =
    /// 新键跟别人撞了不会被发现;漏了 title = 撞键提示里显示成一个原始标识符。
    ///
    /// ⚠️ **这两条没有自动化测试兜底**,只能靠这段注释 + 下面 `registerAll()` 末尾那条
    /// debug 断言(它只能查出"登记了但没写标题",查不出"压根没登记")。原因:
    /// lyrimuse-selftest 只依赖 LyrimuseCore(见 Package.swift),而这个文件在 app target
    /// 里、还要 import KeyboardShortcuts,selftest 够不着;而 `KeyboardShortcuts.Name`
    /// 是 struct 不是 enum,也没有办法在运行时反射出"一共声明了几个"来跟这份清单对账。
    static let allLyrimuseNames: [Self] = [
        .toggleOverlay, .toggleLockPosition, .openLyricsManagerHotkey,
        .openLyricsWindowHotkey, .openSettingsHotkey, .playPauseHotkey,
        .nextTrackHotkey, .previousTrackHotkey, .lyricsAdvanceHotkey, .lyricsDelayHotkey,
        .lyricsQuickSearchHotkey, .toggleTranslationHotkey, .toggleRomanizationHotkey,
        .toggleNotchOverlayHotkey, .toggleMenuBarLyricsHotkey, .lyricsOffsetResetHotkey,
    ]

    /// 给用户看的动作名。撞键提示要说"这个组合已经给了『歌词提前』",光报
    /// `lyricsAdvanceHotkey` 这种内部标识符等于没说。
    ///
    /// ⚠️ 文案必须跟 `SettingsView` 里那三张快捷键卡的 `SettingsRow(title:)` 一字不差 ——
    /// 提示里说的名字跟他在设置页看到的对不上,就得自己去猜是哪一行。
    /// (没有做成"从设置页反查"是因为那边的标题跟图标/副标题写在一起、还分三张卡,
    /// 抽出来要动 10 行 UI;这里只登记名字,由上面那条 selftest 保证不漏。)
    static func title(for name: Self) -> String {
        switch name {
        case .toggleOverlay: return L10n.t("显示/隐藏悬浮歌词")
        case .toggleLockPosition: return L10n.t("锁定/解锁位置")
        case .openLyricsManagerHotkey: return L10n.t("打开歌词管理")
        case .openLyricsWindowHotkey: return L10n.t("打开歌词窗口")
        case .openSettingsHotkey: return L10n.t("打开设置")
        case .playPauseHotkey: return L10n.t("播放/暂停")
        case .nextTrackHotkey: return L10n.t("下一首")
        case .previousTrackHotkey: return L10n.t("上一首")
        case .lyricsAdvanceHotkey: return L10n.t("歌词提前")
        case .lyricsDelayHotkey: return L10n.t("歌词延后")
        case .lyricsQuickSearchHotkey: return L10n.t("搜索歌词")
        case .toggleTranslationHotkey: return L10n.t("显示/隐藏译文")
        case .toggleRomanizationHotkey: return L10n.t("显示/隐藏发音")
        case .toggleNotchOverlayHotkey: return L10n.t("显示/隐藏灵动岛歌词")
        case .toggleMenuBarLyricsHotkey: return L10n.t("显示/隐藏菜单栏歌词")
        case .lyricsOffsetResetHotkey: return L10n.t("歌词偏移归零")
        default: return name.rawValue
        }
    }
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
            // ⚠️ 这个键只对桌面悬浮歌词有意义(灵动岛贴着刘海,没有"位置"可锁)。原来
            // 这里是**静默** return —— 只开灵动岛的用户按下去什么都不发生,分不清是没
            // 按中还是不适用。2026-08-31 补一条说明,理由跟下面偏移那两个键一样:全局
            // 快捷键最忌讳"按了没动静"。
            guard AppSettings.shared.classicOverlayEnabled else {
                flashHint(icon: "lock.slash", text: L10n.t("锁定位置只对桌面悬浮歌词有效"))
                return
            }
            let overlay = LyricsOverlayWindowController.shared
            let newValue = !overlay.isPositionLocked
            // 跟 MenuBarStatusMenu.swift 现成的"锁定位置"Toggle 绑定逻辑完全一致:持久化
            // 偏好 + 让窗口真正生效,两步都要做,不能只做其中一步。
            AppSettings.shared.lockPosition = newValue
            overlay.setLocked(newValue)
            // 成功时也要有回声。原来只有本机**第一次**解锁才弹一条 4 秒手势提示
            // (maybeShowDragHintOnFirstUnlock,UserDefaults 记了标记只弹一次),之后
            // 锁没锁全靠去拖一下试。
            flashHint(icon: newValue ? "lock" : "lock.open",
                      text: newValue ? L10n.t("已锁定位置") : L10n.t("已解锁位置"))
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
        // 跟上面 ± 两个键成组:调歪了一键回正。用的是三处菜单共用的那个
        // resetLyricsOffset(),不自己复制一份"把偏移写回 0"的逻辑。
        KeyboardShortcuts.onKeyUp(for: .lyricsOffsetResetHotkey) {
            PlaybackCoordinator.shared.resetLyricsOffset()
            showOffsetBanner(0)
        }
        // 「歌词错了/没有」这件事恰恰是在写别的东西时发现的,是全局键最典型的用法。
        // 在这之前它的**唯一**入口是悬浮窗右键菜单(状态栏菜单里都没有)。
        KeyboardShortcuts.onKeyUp(for: .lyricsQuickSearchHotkey) {
            AppActions.shared.openLyricsQuickSearch?()
        }
        // 译文/发音两个显示开关。都带回声——它们改的是"看得见的东西",但如果当下这首歌
        // 压根没有译文/没有注音,画面不会有任何变化,没有提示就分不清是没按中还是没内容。
        KeyboardShortcuts.onKeyUp(for: .toggleTranslationHotkey) {
            let on = !AppSettings.shared.showTranslation
            AppSettings.shared.showTranslation = on
            flashHint(icon: on ? "character.book.closed" : "character.book.closed.fill",
                      text: on ? L10n.t("已显示译文") : L10n.t("已隐藏译文"))
        }
        // ⚠️ 绑的是**总开关** `showRomanization`,不是在 拼音/粤拼/日文/韩文 之间轮换
        // (2026-08-31 用户明确要求:「应该改为开关罗马音的功能而不是切换」)。
        // 分语言那四个勾选留在设置页,它们是"配置",不是随手按的东西。
        KeyboardShortcuts.onKeyUp(for: .toggleRomanizationHotkey) {
            let on = !AppSettings.shared.showRomanization
            AppSettings.shared.showRomanization = on
            flashHint(icon: "textformat.abc",
                      text: on ? L10n.t("已显示发音") : L10n.t("已隐藏发音"))
        }
        // 灵动岛/菜单栏歌词的显隐。跟「显示/隐藏悬浮歌词」凑齐三种形态 —— 原来只有悬浮
        // 那一个有键,另外两个没有,不对称。
        //
        // ⚠️ 灵动岛走 setVisible(_:) 而不是直接翻 AppSettings 那个布尔值:那个方法是
        // 打开/关闭一种悬浮歌词的**唯一入口**,连"顺手把已配置好的隐藏偏好也应用上"
        // 这一步都在里面(照抄 MenuBarStatusMenu.toggleNotchOverlay 的注释与做法,
        // 菜单/设置页/快捷键三处不各自复制一遍)。
        KeyboardShortcuts.onKeyUp(for: .toggleNotchOverlayHotkey) {
            let on = !AppSettings.shared.notchOverlayEnabled
            NotchLyricsWindowController.shared.setVisible(on)
            flashHint(icon: on ? "inset.filled.topthird.square" : "square.slash",
                      text: on ? L10n.t("已显示灵动岛歌词") : L10n.t("已隐藏灵动岛歌词"))
        }
        // 菜单栏歌词没有独立的 WindowController(就画在状态栏那一行上),直接读写
        // AppSettings 就够 —— 同 MenuBarStatusMenu.toggleMenuBarLyrics。
        KeyboardShortcuts.onKeyUp(for: .toggleMenuBarLyricsHotkey) {
            let on = !AppSettings.shared.showLyricsInMenuBar
            AppSettings.shared.showLyricsInMenuBar = on
            flashHint(icon: "menubar.rectangle",
                      text: on ? L10n.t("已显示菜单栏歌词") : L10n.t("已隐藏菜单栏歌词"))
        }

        // 见 allLyrimuseNames 注释:登记了名字却忘了写标题时,撞键提示会把内部标识符
        // 端给用户。这里只能查出这一半(另一半"压根没登记"没有办法自动发现)。
        #if DEBUG
        for name in KeyboardShortcuts.Name.allLyrimuseNames {
            assert(KeyboardShortcuts.Name.title(for: name) != name.rawValue,
                   "快捷键 \(name.rawValue) 没有在 KeyboardShortcuts.Name.title(for:) 里登记显示名")
        }
        #endif
    }

    /// 把毫秒偏移显示成 "+0.50s" / "-0.25s"。正号要显式带上 —— 只有减号的话,用户按了
    /// "提前"却看到一个没有符号的数字,分不清方向。
    private static func showOffsetBanner(_ offsetMs: Int) {
        let seconds = Double(offsetMs) / 1000
        flashHint(icon: "timer", text: String(format: "%@ %+.2fs", L10n.t("歌词偏移"), seconds))
    }

    /// 把一条操作回声送到**用户实际开着的那个展示形态**上。
    ///
    /// ⚠️ 2026-08-31 加。在这之前这里只发 `NotchTransientCenter`,而那条横幅只有灵动岛
    /// 渲染(`NotchLyricsView` 里的 `NotchTransientHost` 是它全仓唯一的消费者)——于是
    /// **只开桌面悬浮歌词的用户按快捷键是完全没有反馈的**,偏移调到哪了只能靠盯着歌词
    /// 猜。两边都发、各自按自己开没开决定显不显示,不需要在这里判断"该给谁"。
    ///
    /// ⚠️ 碰 `LyricsOverlayWindowController.shared` 之前**必须**先判
    /// `classicOverlayEnabled`:那是个 static let,光读一下属性就会 init() 把窗口建出来
    /// 并常驻显示(这个坑本文件顶部 registerAll 的注释里已经记过一次,这里是同一条)。
    static func flashHint(icon: String, text: String) {
        NotchTransientCenter.shared.show(.init(icon: icon, text: text, progress: nil))
        if AppSettings.shared.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.flashTransientHint(text)
        }
    }
}
