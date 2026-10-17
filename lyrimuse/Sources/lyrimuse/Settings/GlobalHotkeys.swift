import AppKit
import KeyboardShortcuts
import LyrimuseCore

// 每个动作见 Core `LyrimuseAction`:快捷键的内部名就是它的 rawValue(存在用户偏好里,不能改),名字、图标、在快捷键页的
// 哪张卡也在那边,这里只把它们接到 KeyboardShortcuts 上。
//
// 默认不预置任何按键组合 —— 录制框不预注册默认值时就是空的「点按录制」状态,所有快捷键都要用户自己在设置里录了
// 才生效,不会有按键在用户不知情下被这个 App 抢占。
extension KeyboardShortcuts.Name {
    init(_ action: LyrimuseAction) {
        self.init(action.rawValue)
    }

    /// 全部全局快捷键,撞键检查(ShortcutConflict)遍历它。
    static let allLyrimuseNames: [Self] = LyrimuseAction.allCases.map { Self($0) }

    /// 撞键提示里给用户看的动作名,跟快捷键页那一格同一份(`LyrimuseAction.titleKey`)。
    static func title(for name: Self) -> String {
        LyrimuseAction(rawValue: name.rawValue).map { L10n.t($0.titleKey) } ?? name.rawValue
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

        pauseWhileMenuTracking()
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
