import AppKit
import Combine
import OSLog

/// 「别的 App 正处于全屏」这一件事的唯一判定处，供两个悬浮窗的可见性闸消费。
///
/// 为什么需要它:桌面悬浮歌词和灵动岛都是 `.canJoinAllSpaces + .fullScreenAuxiliary` 的浮层,
/// 灵动岛还额外挂在 `.screenSaver` 层(比菜单栏还高,见 NotchLyricsWindow 注释)。「盖在全屏
/// App 之上」本来就是设计意图(04 章定位第一句),但缺一个反向开关:边听歌边全屏看视频时,
/// 灵动岛就压在画面顶部那一条上;指针移到屏幕顶端想唤出菜单栏,还会先撞进它的 hover 命中区
/// 把卡片展开。既有的「暂停/无播放时隐藏」对「音乐在放 + 全屏视频」这个组合完全无效。
///
/// ⚠️ **刻意只用公开 API**。被参考的那个实现引了 MacroVisionKit(一个第三方包)来做同一件事;
/// 这里 `NSWorkspace` 的通知 + `CGWindowListCopyWindowInfo` 就够,不值得为一个开关多一个依赖。
/// 判据也不是私有的 Space API —— 那条路要 CGSGetActiveSpace 一类的私有符号。
@MainActor
final class FullscreenAppMonitor: ObservableObject {
    static let shared = FullscreenAppMonitor()

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "fullscreen-monitor")

    /// 此刻有没有**别的 App** 的窗口铺满了某一块屏幕。
    @Published private(set) var isFullscreenAppPresent = false

    private var observers: [NSObjectProtocol] = []
    /// 有没有人要这个信号。没人要就不装监听器 —— 跟 `LyricsOverlayWindowController`
    /// 那套 global monitor 的装卸原则一致:这个类的每次求值都要向 WindowServer 要一份
    /// 全系统窗口清单,不该为一个关着的开关白跑。
    private var isObserving = false
    /// 通知合并。切 Space 时 `activeSpaceDidChange` 和 `didActivateApplication` 常常连着来,
    /// 不合并就会对同一次切换连查两遍窗口清单。
    private var refreshTask: Task<Void, Never>?

    private init() {}

    /// 开关打开/关闭时调。幂等。
    func setEnabled(_ enabled: Bool) {
        if enabled {
            startObserving()
        } else {
            stopObserving()
            // 关掉时必须归位:留着 true 的话,两个控制器的可见性闸会一直以为"还有人在全屏",
            // 而已经没有人再更新它了。
            if isFullscreenAppPresent { isFullscreenAppPresent = false }
        }
    }

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        let center = NSWorkspace.shared.notificationCenter
        // 三个触发点合起来覆盖「有人进/出全屏」的全部路径:
        //   - activeSpaceDidChange:进全屏会新建一个 Space 并切过去,退出同理 —— 主力信号;
        //   - didActivateApplication:在已有的多个全屏 Space 之间切换 App;
        //   - didTerminateApplication:全屏 App 直接被退掉时不发 Space 变化(实测)。
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        refreshNow()
    }

    private func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        refreshTask?.cancel()
        refreshTask = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // 进全屏是一段动画,通知到达时窗口还没铺满 —— 立刻查会读到"没人全屏"。
            // 0.35s 是 macOS 全屏过渡的量级,查晚一点比查错强。
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    private func refreshNow() {
        let present = Self.detectFullscreenApp()
        guard present != isFullscreenAppPresent else { return }
        isFullscreenAppPresent = present
        Self.logger.notice("fullscreen app present = \(present, privacy: .public)")
    }

    /// 扫一遍屏幕上的窗口,看有没有**别人的**普通层窗口铺满了某一块屏。
    ///
    /// 三道筛选缺一不可:
    ///   - `kCGWindowLayer == 0`:只认普通应用窗口。菜单栏、Dock、我们自己的浮层都在别的层,
    ///     不筛的话灵动岛自己(`.screenSaver` 层)就可能被算成"有人全屏"。
    ///   - owner PID 不是自己:同上,而且我们的窗口确实可能跨 Space 出现在清单里。
    ///   - bounds 覆盖某块屏的**整个 frame**(不是 visibleFrame):全屏窗口连菜单栏和 Dock 的
    ///     位置一起吃掉,拿 visibleFrame 比会把"最大化但没进全屏"的窗口也算进来 —— 那种窗口
    ///     下面菜单栏还在,浮层压着它并不碍事。
    private static func detectFullscreenApp() -> Bool {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        // CoreGraphics 的窗口坐标原点在**主屏左上**、y 向下;NSScreen.frame 原点在主屏左下、
        // y 向上。不换算的话副屏(尤其是摆在主屏上方的)会整片对不上。
        guard let primaryTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
                ?? NSScreen.screens.map(\.frame.maxY).max() else { return false }
        // 允许 1pt 误差:全屏窗口的 bounds 偶尔跟 NSScreen.frame 差个亚像素(缩放屏)。
        let tolerance: CGFloat = 1
        for info in raw {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            for screen in NSScreen.screens {
                let f = screen.frame
                // CG → NSScreen 坐标:翻 y。
                let cgScreenY = primaryTop - f.maxY
                let covers = rect.width >= f.width - tolerance
                    && rect.height >= f.height - tolerance
                    && abs(rect.minX - f.minX) <= tolerance
                    && abs(rect.minY - cgScreenY) <= tolerance
                if covers { return true }
            }
        }
        return false
    }
}
