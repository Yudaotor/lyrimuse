import AppKit
import Combine
import LyrimuseCore

/// 盯一扇窗「是不是几乎被别的窗口整扇盖住」,给 `occlusionState` 补盲区(判据与来由见
/// `LyrimuseCore.WindowCoverage`)。
///
/// 遮挡物只算**不透明的普通窗口**(layer 0、alpha ≥ 0.95):程序坞那扇是全屏透明窗(layer 20),灵动岛 /
/// 悬浮歌词是透明的浮动窗(layer 3 / 1000),把它们算进来会让任何窗口都「被盖住」。
///
/// 什么时候重算:窗口在屏上时每 2 秒一次(别的 App 挪窗口没有通知可听;收起后停表);另外切换前台 App、这扇窗获得 / 失去焦点、
/// 移动 / 缩放、上屏 / 收起(`isVisible` 的 KVO)、屏幕锁上 / 解锁(`WindowSurfaceState.screenHidden`)时立刻重算 —— 最常见的
/// 「切回来看歌词」不用等那 2 秒。一次重算是一次
/// `CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow)` + 4pt 网格采样,平时毫秒级;这两次窗口清单是跟 WindowServer
/// 的同步往返,放在后台队列上问,WindowServer 卡住时卡的是那条队列、不是主线程(14 章决策 194)。
///
/// 每次重算都回调 `onUpdate`(不只在结果变了时):宿主在回调里按当下重读遮挡状态,不靠遮挡变化通知记下的旧值。锁屏前后系统
/// 不一定补发「又看得见了」那一条通知,只靠通知的宿主会一直停在看不见(见 11 章决策 188)。
@MainActor
final class WindowCoverageMonitor {
    private weak var window: NSWindow?
    private let onUpdate: (Bool) -> Void
    private(set) var isCovered = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var visibleObservation: NSKeyValueObservation?
    private var screenObserver: AnyCancellable?

    init(window: NSWindow, onUpdate: @escaping (Bool) -> Void) {
        self.window = window
        self.onUpdate = onUpdate
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resumeTimerIfNeeded()
                    self?.recompute()
                }
            })
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // 前台 App 刚换,窗口层级这一拍可能还没排好;晚一点再算。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated {
                    self?.resumeTimerIfNeeded()
                    self?.recompute()
                }
            }
        }
        // 上屏 / 收起不一定伴随遮挡变化通知(一上屏就被整扇盖住、锁屏期间开关窗口),计时器靠这里接上。
        visibleObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.resumeTimerIfNeeded()
                    self?.recompute()
                }
            }
        }
        screenObserver = WindowSurfaceState.screenChanges.sink { [weak self] in
            MainActor.assumeIsolated {
                self?.resumeTimerIfNeeded()
                self?.recompute()
            }
        }
        startTimer()
        recompute()
    }

    private var stopped = false

    private func startTimer() {
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 窗口收起(设置窗口关掉只是隐藏、视图不销毁)就停表,不然一直每 2 秒醒一次到 App 退出。再露面时
    /// `isVisible` 的 KVO 把它接上;收起前最后一次重算已经记成「盖住」。
    private func tick() {
        guard let window, window.isVisible else {
            recompute()
            timer?.invalidate()
            timer = nil
            return
        }
        recompute()
    }

    private func resumeTimerIfNeeded() {
        guard !stopped, timer == nil, window?.isVisible == true else { return }
        startTimer()
    }

    /// 持有方没调 stop 就放手时也得停:计时器挂在 RunLoop 上,不失效就一直每 2 秒空转。
    deinit {
        timer?.invalidate()
        visibleObservation?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        visibleObservation?.invalidate()
        visibleObservation = nil
        screenObserver = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }

    private static let windowServerQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.window-coverage", qos: .utility)
    /// 后台正在问 WindowServer;这期间又要重算的记一笔,问完再算一次(不堆积请求)。
    private var asking = false
    private var askAgain = false

    private func recompute() {
        guard let window else { return }
        if let covered = Self.quickVerdict(window) {
            // 后台那次问的是这之前的窗口层级,回来时别拿它盖掉这个判定:记一笔,回来再算一次。
            if asking { askAgain = true }
            apply(covered)
            return
        }
        guard !asking else {
            askAgain = true
            return
        }
        asking = true
        let id = CGWindowID(window.windowNumber)
        Self.windowServerQueue.async { [weak self] in
            let covered = Self.coveredByWindowsAbove(id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishAsking(covered) }
            }
        }
    }

    private func finishAsking(_ covered: Bool) {
        asking = false
        guard !stopped else { return }
        guard !askAgain else {
            askAgain = false
            recompute()
            return
        }
        apply(covered)
    }

    private func apply(_ covered: Bool) {
        guard !stopped else { return }
        isCovered = covered
        onUpdate(covered)
    }

    /// 不用问 WindowServer 就定得了的情况;nil = 要看上面压着哪些窗口。
    private static func quickVerdict(_ window: NSWindow) -> Bool? {
        // 没上屏 / 最小化 / 系统判为被遮住 / 屏幕锁着时直接算盖住:窗口一上屏就被整扇盖住时系统不发遮挡变化通知,
        // 宿主手里的遮挡初值会一直停在「可见」,靠这里每 2 秒的重算纠正(07 章决策 103)。
        guard window.isVisible, !window.isMiniaturized, WindowSurfaceState.occlusionVisible(window) else { return true }
        // 隐身开窗压在墙纸后面的验证窗口上面压着所有窗口,不算盖住(见 `WindowSurfaceState`)。
        guard !WindowActivation.isHidden(window) else { return false }
        // 前台正是它自己时上面没有别的窗口。
        guard !window.isKeyWindow else { return false }
        return nil
    }

    /// 在后台队列上调:窗口清单是跟 WindowServer 的同步往返。
    private nonisolated static func coveredByWindowsAbove(_ id: CGWindowID) -> Bool {
        guard let selfInfo = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let target = bounds(selfInfo),
              let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], id) as? [[String: Any]]
        else { return false }
        let covers = above.compactMap { info -> CGRect? in
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0, alpha >= 0.95 else { return nil }
            return bounds(info)
        }
        return WindowCoverage.isEffectivelyHidden(target: target, covers: covers)
    }

    private nonisolated static func bounds(_ info: [String: Any]) -> CGRect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict) else { return nil }
        return r
    }
}

/// 一扇窗此刻露没露出来,只看系统那一侧(遮挡状态、屏幕锁没锁),不含「几乎被别的窗口整扇盖住」那一项(`WindowCoverageMonitor`)。
/// 按窗口可见性停表的宿主一律经这里读,别直接读 `occlusionState`:
/// - 屏幕锁着、熄屏、切到别的用户(`ScreenVisibility`)时算看不见。解锁那一下(`screenChanges`)是可靠的边沿,
///   遮挡变化通知锁屏前后不一定补发。
/// - 隐身开窗压在墙纸后面的验证窗口(`WindowActivation.isHidden`)只要上了屏就算看得见:那是验证开的窗,当前句、跟随滚动、
///   轮询照常走。预览嵌套的托管视图在墙纸后面不一定重画,按窗口截图看到的当前句可能是旧的,以 `debug/state` 的 `previews` 为准
///  (11 章决策 188)。
@MainActor
enum WindowSurfaceState {
    /// `debug/screen-lock`:隐身开的验证窗口当作屏幕锁着,用户看得见的窗口不受影响。
    private(set) static var debugScreenLocked = false
    private static let screenChangeSubject = PassthroughSubject<Void, Never>()

    /// 屏幕锁上 / 解锁、熄屏 / 唤醒、切换用户(以及 `debug/screen-lock`)时在主线程上发,这时 `screenHidden` 已是新值
    ///(`@Published` 在赋值之前发,推到下一拍)。一秒后再发一次:解锁那一刻窗口的遮挡状态可能还没翻回来。
    static var screenChanges: AnyPublisher<Void, Never> {
        ScreenVisibility.shared.$isHidden.removeDuplicates().dropFirst().map { _ in }
            .merge(with: screenChangeSubject)
            .receive(on: DispatchQueue.main)
            .flatMap { Just(()).append(Just(()).delay(for: .seconds(1), scheduler: DispatchQueue.main)) }
            .eraseToAnyPublisher()
    }

    static func screenHidden(_ window: NSWindow) -> Bool {
        ScreenVisibility.shared.isHidden || (debugScreenLocked && WindowActivation.isHidden(window))
    }

    static func occlusionVisible(_ window: NSWindow) -> Bool {
        guard !screenHidden(window) else { return false }
        if WindowActivation.isHidden(window) { return window.isVisible }
        return window.occlusionState.contains(.visible)
    }

    static func setDebugScreenLocked(_ locked: Bool) {
        guard debugScreenLocked != locked else { return }
        debugScreenLocked = locked
        screenChangeSubject.send()
    }
}
