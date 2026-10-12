import AppKit
import KeyboardShortcuts
import LyrimuseCore

// A 组(显示/隐藏悬浮歌词、锁定/解锁位置、打开歌词管理、打开设置)复用已有能力,纯接线;
// B 组(播放/暂停、上下一首)是这个软件第一次拥有"控制播放"能力,靠 MusicPlaybackController
// 发 AppleScript 指令,复用已经拿到的自动化权限(见 MusicAutomationPermission)。
//
// 默认不预置任何按键组合——KeyboardShortcuts.Recorder 不预注册默认值时本来就是空的
// "点按录制"状态,下面这 18 个快捷键全部必须用户自己在设置里主动录制才会生效,不会有
// 按键在用户不知情下被这个 App 抢占。
extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay")
    static let toggleLockPosition = Self("toggleLockPosition")
    static let openLyricsManagerHotkey = Self("openLyricsManagerHotkey")
    static let openLyricsWindowHotkey = Self("openLyricsWindowHotkey")
    static let toggleLyricsWindowMiniHotkey = Self("toggleLyricsWindowMiniHotkey")
    static let openSettingsHotkey = Self("openSettingsHotkey")
    static let playPauseHotkey = Self("playPauseHotkey")
    static let nextTrackHotkey = Self("nextTrackHotkey")
    static let previousTrackHotkey = Self("previousTrackHotkey")
    static let lyricsAdvanceHotkey = Self("lyricsAdvanceHotkey")
    static let lyricsDelayHotkey = Self("lyricsDelayHotkey")
    // 加的六个。挑选判据是「别的 App 占着焦点时你还想按」—— 只在某扇窗已经
    // 在前台时才有意义的动作(随机/循环、置顶、全屏)刻意不给全局键,那是本地键该管的。
    static let lyricsQuickSearchHotkey = Self("lyricsQuickSearchHotkey")
    static let toggleTranslationHotkey = Self("toggleTranslationHotkey")
    static let toggleRomanizationHotkey = Self("toggleRomanizationHotkey")
    static let toggleNotchOverlayHotkey = Self("toggleNotchOverlayHotkey")
    static let toggleMenuBarLyricsHotkey = Self("toggleMenuBarLyricsHotkey")
    static let lyricsOffsetResetHotkey = Self("lyricsOffsetResetHotkey")
    // 设置页那一行只在这台 Mac 此刻有触控栏时出现(17 章决策 40)。
    static let toggleTouchBarLyricsHotkey = Self("toggleTouchBarLyricsHotkey")

    /// 全部全局快捷键。撞键检查(见 ShortcutConflict)要遍历它——`KeyboardShortcuts.Name`
    /// 是个 struct 不是 enum,拿不到自动的 allCases,只能手工维护。
    ///
    /// 新增快捷键时**必须**同时加进这里和下面的 `title(for:)`,否则:漏了这里 =
    /// 新键跟别人撞了不会被发现;漏了 title = 撞键提示里显示成一个原始标识符。
    ///
    /// **这两条没有自动化测试兜底**,只能靠这段注释 + 下面 `registerAll()` 末尾那条
    /// debug 断言(它只能查出"登记了但没写标题",查不出"压根没登记")。原因:
    /// lyrimuse-selftest 只依赖 LyrimuseCore(见 Package.swift),而这个文件在 app target
    /// 里、还要 import KeyboardShortcuts,selftest 够不着;而 `KeyboardShortcuts.Name`
    /// 是 struct 不是 enum,也没有办法在运行时反射出"一共声明了几个"来跟这份清单对账。
    static let allLyrimuseNames: [Self] = [
        .toggleOverlay, .toggleLockPosition, .openLyricsManagerHotkey,
        .openLyricsWindowHotkey, .toggleLyricsWindowMiniHotkey, .openSettingsHotkey, .playPauseHotkey,
        .nextTrackHotkey, .previousTrackHotkey, .lyricsAdvanceHotkey, .lyricsDelayHotkey,
        .lyricsQuickSearchHotkey, .toggleTranslationHotkey, .toggleRomanizationHotkey,
        .toggleNotchOverlayHotkey, .toggleMenuBarLyricsHotkey, .toggleTouchBarLyricsHotkey, .lyricsOffsetResetHotkey,
    ]

    /// 给用户看的动作名。撞键提示要说"这个组合已经给了『歌词提前』",光报
    /// `lyricsAdvanceHotkey` 这种内部标识符等于没说。
    ///
    /// 文案必须跟 `SettingsView` 里那三张快捷键卡的 `SettingsRow(title:)` 一字不差 ——
    /// 提示里说的名字跟他在设置页看到的对不上,就得自己去猜是哪一行。
    /// (没有做成"从设置页反查"是因为那边的标题跟图标/副标题写在一起、还分三张卡,
    /// 抽出来要动 10 行 UI;这里只登记名字,由上面那条 selftest 保证不漏。)
    static func title(for name: Self) -> String {
        switch name {
        case .toggleOverlay: return L10n.t("显示/隐藏悬浮歌词")
        case .toggleLockPosition: return L10n.t("锁定/解锁位置")
        case .openLyricsManagerHotkey: return L10n.t("打开歌词管理")
        case .openLyricsWindowHotkey: return L10n.t("打开歌词窗口")
        case .toggleLyricsWindowMiniHotkey: return L10n.t("切换迷你 / 完整尺寸")
        case .openSettingsHotkey: return L10n.t("打开设置")
        case .playPauseHotkey: return L10n.t("播放/暂停")
        case .nextTrackHotkey: return L10n.t("下一首")
        case .previousTrackHotkey: return L10n.t("上一首")
        case .lyricsAdvanceHotkey: return L10n.t("歌词提前")
        case .lyricsDelayHotkey: return L10n.t("歌词延后")
        case .lyricsQuickSearchHotkey: return L10n.t("搜索歌词")
        case .toggleTranslationHotkey: return L10n.t("显示/隐藏译文")
        case .toggleRomanizationHotkey: return L10n.t("显示/隐藏读音")
        case .toggleNotchOverlayHotkey: return L10n.t("显示/隐藏灵动岛歌词")
        case .toggleMenuBarLyricsHotkey: return L10n.t("显示/隐藏菜单栏歌词")
        case .toggleTouchBarLyricsHotkey: return L10n.t("展开/收起触控栏歌词")
        case .lyricsOffsetResetHotkey: return L10n.t("歌词偏移归零")
        default: return name.rawValue
        }
    }
}

@MainActor
enum GlobalHotkeys {
    static func registerAll() {
        // 每个快捷键执行的都是 LyrimuseActionRunner.perform,跟 lyrimuse://action/… 同一份逻辑(各动作的约束写在那边)。
        // LyrimuseAction 的 rawValue 就是这里的快捷键名,selftest deep-links 组逐个核对。
        for action in LyrimuseAction.allCases {
            KeyboardShortcuts.onKeyUp(for: KeyboardShortcuts.Name(action.rawValue)) {
                LyrimuseActionRunner.perform(action)
            }
        }

        // 见 allLyrimuseNames 注释:登记了名字却忘了写标题时,撞键提示会把内部标识符
        // 端给用户。这里只能查出这一半(另一半"压根没登记"没有办法自动发现)。
        pauseWhileMenuTracking()
        #if DEBUG
        for name in KeyboardShortcuts.Name.allLyrimuseNames {
            assert(KeyboardShortcuts.Name.title(for: name) != name.rawValue,
                   "快捷键 \(name.rawValue) 没有在 KeyboardShortcuts.Name.title(for:) 里登记显示名")
        }
        #endif
    }

    private static var menuTrackingObservers: [NSObjectProtocol] = []

    /// 本 App 的任何 `NSMenu` 跟踪期间(悬浮窗 ⚙ 菜单、菜单栏菜单、设置页下拉)关掉全局快捷键。
    ///
    /// KeyboardShortcuts 1.15.0 在 macOS 14+ 菜单打开时会装一个 `.eventTracking` 模式的 runloop
    /// 观察者(`RunLoopLocalEventMonitor`),每轮把事件队列**整个**取空再逐个塞回。菜单跟踪期间
    /// 队列里全是 mouseMoved,这一取一塞抢掉菜单自己的事件处理,表现是指针在菜单里移动时高亮
    /// 一顿一顿。`isEnabled = false` 走库里 `updateEventHandler()` 的禁用分支,那个观察者随之停掉;
    /// 两边收同一对通知,谁先谁后最终状态都一样。代价是菜单开着时全局快捷键不响应,跟系统原生
    /// 菜单的行为一致;这些快捷键里没有要在菜单打开时触发的(没有「开关菜单」这一类)。
    /// 升级到带上游修复的版本需要 swift-tools 6.2,且 2.x 用了本机编不过的宏,见 Package.swift。
    private static func pauseWhileMenuTracking() {
        guard menuTrackingObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuTrackingObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { KeyboardShortcuts.isEnabled = false }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { KeyboardShortcuts.isEnabled = true }
            },
        ]
    }

    /// 把一条操作回声送到**用户实际开着的那个展示形态**上。
    ///
    /// 灵动岛(`NotchTransientCenter`,消费者是 `NotchLyricsView` 里的 `NotchTransientHost`)和悬浮歌词两边都发,
    /// 各自按自己开没开决定显不显示,这里不判断"该给谁"。两个都没开时交给触控栏(展开着时)、菜单栏歌词(槽里正显示
    /// 歌词时)和歌词窗口(开着、看得见时,07 章决策 132);这几处都没在显示,这条回声就没有地方出现(14 章决策 60)。
    ///
    /// 碰 `LyricsOverlayWindowController.shared` 之前**必须**先判
    /// `classicOverlayEnabled`:那是个 static let,光读一下属性就会 init() 把窗口建出来
    /// 并常驻显示(这个坑本文件顶部 registerAll 的注释里已经记过一次,这里是同一条)。
    static func flashHint(icon: String, text: String) {
        NotchTransientCenter.shared.show(.init(icon: icon, text: text, progress: nil), for: hintSeconds)
        let settings = AppSettings.shared
        if settings.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.flashTransientHint(text)
        }
        // 灵动岛、悬浮歌词都没开时,同一条提示交给触控栏(展开着时)和菜单栏歌词;有一个开着就不发,
        // 那两处是回声的主场,别的面再闪一遍是噪音(14 章决策 60)。
        guard !settings.notchOverlayEnabled, !settings.classicOverlayEnabled else { return }
        TouchBarLyricsController.shared.flashHint(text, seconds: hintSeconds)
        MenuBarStatusItem.shared.flashHint(text, seconds: hintSeconds)
        if LyricsWindowHintSurface.visible {
            LyricsWindowActionNotes.shared.flashHint(text, symbol: icon, seconds: hintSeconds)
        }
    }

    /// 快捷键回声显示多久:灵动岛横幅、触控栏、菜单栏歌词同一个数。
    static let hintSeconds: TimeInterval = 1.4
}
