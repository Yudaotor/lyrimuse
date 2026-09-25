import AppKit
import LyrimuseCore

/// 盯一扇窗「是不是几乎被别的窗口整扇盖住」,给 `occlusionState` 补盲区(判据与来由见
/// `LyrimuseCore.WindowCoverage`)。
///
/// 遮挡物只算**不透明的普通窗口**(layer 0、alpha ≥ 0.95):程序坞那扇是全屏透明窗(layer 20),灵动岛 /
/// 悬浮歌词是透明的浮动窗(layer 3 / 1000),把它们算进来会让任何窗口都「被盖住」。
///
/// 什么时候重算:每 2 秒一次(别的 App 挪窗口没有通知可听);另外切换前台 App、这扇窗获得 / 失去焦点、
/// 移动 / 缩放时立刻重算 —— 最常见的「切回来看歌词」不用等那 2 秒。一次重算是一次
/// `CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow)` + 4pt 网格采样,毫秒级。
@MainActor
final class WindowCoverageMonitor {
    private weak var window: NSWindow?
    private let onChange: (Bool) -> Void
    private(set) var isCovered = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?

    init(window: NSWindow, onChange: @escaping (Bool) -> Void) {
        self.window = window
        self.onChange = onChange
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            })
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // 前台 App 刚换,窗口层级这一拍可能还没排好;晚一点再算。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { self?.recompute() }
            }
        }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        recompute()
    }

    /// 持有方没调 stop 就放手时也得停:计时器挂在 RunLoop 上,不失效就一直每 2 秒空转。
    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }

    private func recompute() {
        guard let window else { return }
        let covered = Self.computeCovered(window)
        guard covered != isCovered else { return }
        isCovered = covered
        onChange(covered)
    }

    private static func computeCovered(_ window: NSWindow) -> Bool {
        // 看不见 / 最小化 / 前台正是它自己时不必算:occlusionState 已经管着前者,后者上面没有别的窗口。
        guard window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
              !window.isKeyWindow else { return false }
        let id = CGWindowID(window.windowNumber)
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

    private static func bounds(_ info: [String: Any]) -> CGRect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict) else { return nil }
        return r
    }
}
