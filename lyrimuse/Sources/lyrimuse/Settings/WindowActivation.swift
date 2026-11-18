import AppKit

/// 开窗时激活不激活 App。各开窗入口(设置、歌词管理、歌词窗口、搜索歌词小窗、引导)一律走 `activateApp()`,
/// 不直接调 `NSApp.activate`。
///
/// 深链带 `background=1` 时(本机验证用,见 14 章决策 98):接下来一小段时间里不激活 App,
/// 窗口建好后 `orderFrontRegardless()` 摆到最前、不当 key —— 用户正在别的 App 里打字,键盘焦点不被抢走。做法同启动时
/// 重开歌词窗口(07 章决策 123):accessory 策略下 `openWindow` 不激活也会把窗口建出来,只是不会自己到前台。
///
/// 深链带 `invisible=1` 时在后台开窗之外,把这次开出来的窗口压到墙纸后面(`invisibleLevel`):用户屏幕上看不见,
/// `screencapture -l <窗口号>` 照样截得到;窗口里弹出的气泡(NSPopover)是它的子窗口,AppKit 自动跟着同一层级。
/// 压下去的窗口关掉、或之后被正常打开时还回原层级。见 14 章决策 218。
@MainActor
enum WindowActivation {
    private static var backgroundUntil: Date?
    private static var invisibleUntil: Date?
    /// 这次隐身开窗开的是哪一扇场景(`DeepLinkRouter.sceneID`);期间新冒出来的窗口(迷你歌词面板这类)记在它名下。
    private static var invisibleScene: String?
    /// 隐身开窗开始前就在屏上的窗口:不压,用户正看着的不能被收走。
    private static var visibleBeforeInvisible: Set<ObjectIdentifier> = []
    private static var hidden: [ObjectIdentifier: HiddenWindow] = [:]

    private struct HiddenWindow {
        weak var window: NSWindow?
        /// 压下去之前、或压着期间别处想设的层级,还回去时用。
        var level: NSWindow.Level
        let scene: String?
        var observers: [NSObjectProtocol]
    }

    /// 桌面层往下两层,压在墙纸窗口(桌面层下一层)后面:坐标在屏幕内、照常画,被不透明的墙纸整片盖住。别写成桌面层减一:
    /// 那是墙纸自己的层级,同层里后摆上来的窗口排在墙纸前面,桌面露出来的地方用户看得见。挪到屏幕外截图会报 `could not create image`。
    /// 歌词窗口变形动画藏真窗口也用这一层(`LyricsWindowFormMorph.hiddenLevel`);别处要把窗口藏到用户看不见的地方同样引用它,不另写桌面层的算式。
    static let invisibleLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 2)

    /// 「后台开窗」那一小段:开窗入口里的激活被跳过。足够覆盖开窗入口里的异步一拍,又不至于让之后用户自己点的开窗也不激活。
    private static let backgroundWindow: TimeInterval = 2

    static var isBackground: Bool {
        guard let until = backgroundUntil else { return false }
        return Date() < until
    }

    static var isInvisible: Bool {
        guard let until = invisibleUntil else { return false }
        return Date() < until
    }

    static func beginBackground() {
        backgroundUntil = Date().addingTimeInterval(backgroundWindow)
    }

    /// 隐身开窗(隐含后台开窗)。`scene` 是这次要开的场景 id,不开窗的链接传 nil。
    static func beginInvisible(scene: String?) {
        beginBackground()
        invisibleUntil = backgroundUntil
        invisibleScene = scene
        visibleBeforeInvisible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    }

    static func activateApp() {
        guard !isBackground else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 开一扇 SwiftUI 场景窗(歌词管理、歌词窗口、搜索歌词小窗、分享、本次更新、引导;设置走 `presentSettings`)。
    /// 后台开窗时那扇窗已经在屏上就只摆到最前、不调 `open`:`openWindow` 对开着的窗口 `makeKeyAndOrderFront`,
    /// 处理深链的那一拍里这一下会让窗口服务器把 App 切到前台,不经过 `NSApp.activate`(见 14 章决策 197)。
    static func openScene(_ identifier: String, open: () -> Void) {
        ClosedWindowContent.finishPendingReshows()
        prepareOpen(identifier)
        if surfaceIfOnScreen(identifier) { return }
        activateApp()
        open()
        hideNewWindows()
    }

    /// 开窗入口在真正开窗之前调。隐身开窗:SwiftUI 留着的那扇(关掉后没销毁)先压下去再上屏,不在原层级闪一下。
    /// 正常开窗:这扇之前被隐身压下去的话还回原层级,用户自己打开的窗口得看得见。
    static func prepareOpen(_ identifier: String) {
        if isInvisible {
            if let reused = window(matching: identifier, visibleOnly: false), !reused.isVisible { hide(reused) }
        } else {
            reveal(scene: identifier)
        }
    }

    /// 后台开窗、且 `identifier` 那扇窗已经在屏上:`orderFrontRegardless()` 摆到最前(不当 key),返回 true。
    /// 隐身开窗时那扇窗本来就在用户屏幕上(不是隐身压下去的)就原样不动,也返回 true:不把用户正看着的窗口收走。
    /// 别的情况什么都不做、返回 false,由调用方照常开窗。
    static func surfaceIfOnScreen(_ identifier: String) -> Bool {
        guard isBackground, let window = window(matching: identifier, visibleOnly: true) else { return false }
        if isInvisible, !isHidden(window) { return true }
        window.orderFrontRegardless()
        return true
    }

    /// `identifier` 认 SwiftUI `Window(id:)` 的场景 id(窗口标识里含它)和设置窗口。
    private static func window(matching identifier: String, visibleOnly: Bool) -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue.localizedCaseInsensitiveContains(identifier) == true && (!visibleOnly || $0.isVisible)
        }
    }

    /// 后台开窗之后把那扇窗摆到最前(不当 key)。窗口是 SwiftUI 场景现建的,要等一拍,隔 0.25 秒找一次、最多两秒。
    static func surface(identifier: String, attempt: Int = 0) {
        hideNewWindows()
        if let match = window(matching: identifier, visibleOnly: false) {
            if !(isInvisible && match.isVisible && !isHidden(match)) { match.orderFrontRegardless() }
            if match.isVisible { return }
        }
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { surface(identifier: identifier, attempt: attempt + 1) }
    }

    // MARK: - 隐身压下去的窗口

    static func isHidden(_ window: NSWindow) -> Bool { hidden[ObjectIdentifier(window)] != nil }

    /// 隐身开窗期间新上屏的、这次要开的那扇场景窗压下去(开始前就在屏上的不动;歌词窗口连迷你面板)。开窗入口开完当场扫一次,
    /// 之后每 1/120 秒再扫,直到这一小段结束:SwiftUI 头一次建场景窗可能晚一拍才上屏。
    /// 只认场景窗:提示浮条这类反复复用、只 orderOut 不 close 的窗口压下去就还不回来了。
    static func hideNewWindows() {
        guard isInvisible, let scene = invisibleScene else { return }
        for window in NSApp.windows where window.isVisible && !visibleBeforeInvisible.contains(ObjectIdentifier(window)) {
            let matches = window.identifier?.rawValue.localizedCaseInsensitiveContains(scene) == true
                || (scene == "lyrics-window" && window is LyricsMiniPanel)
            if matches { hide(window) }
        }
        guard sweepTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard isInvisible else {
                    sweepTimer?.invalidate()
                    sweepTimer = nil
                    return
                }
                hideNewWindows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    private static var sweepTimer: Timer?

    private static func hide(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard hidden[key] == nil else { return }
        let original = window.level == invisibleLevel ? .normal : window.level
        let center = NotificationCenter.default
        // 压着期间别处改层级(歌词窗口「置顶」、变形动画收尾)当作想要的层级记下,窗口仍留在桌面以下。
        let pin = center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard window.level != invisibleLevel else { return }
                hidden[key]?.level = window.level
                window.level = invisibleLevel
            }
        }
        let close = center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { restore(key) }
        }
        hidden[key] = HiddenWindow(window: window, level: original, scene: invisibleScene, observers: [pin, close])
        window.level = invisibleLevel
    }

    /// 正常开 `scene` 那扇窗时调:之前隐身压下去、记在它名下的窗口全部还回原层级。
    static func reveal(scene: String) {
        for (key, entry) in hidden where entry.scene == scene || entry.window?.identifier?.rawValue
            .localizedCaseInsensitiveContains(scene) == true {
            restore(key)
        }
    }

    /// 压着期间别处要设层级(歌词窗口「置顶」):压着的窗口只记下、不当场改,免得抬到桌面以上闪一下。
    static func setLevel(_ level: NSWindow.Level, of window: NSWindow) {
        let key = ObjectIdentifier(window)
        if hidden[key] != nil {
            hidden[key]?.level = level
        } else {
            window.level = level
        }
    }

    private static func restore(_ key: ObjectIdentifier) {
        guard let entry = hidden.removeValue(forKey: key) else { return }
        entry.observers.forEach(NotificationCenter.default.removeObserver)
        if let window = entry.window, window.level == invisibleLevel { window.level = entry.level }
    }
}
