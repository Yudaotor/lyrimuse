import AppKit
import Combine
import LyrimuseCore
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
    /// 「判定说没人全屏了」到「真的翻回 false」之间的宽限期任务,退出全屏前再复核一次
    /// (2026-08-22 加,见 exitGraceSeconds 注释)。
    private var pendingExit: DispatchWorkItem?
    /// 伪全屏的兜底轮询;它不发任何通知,见 startObserving 里那段注释。
    private var pollTimer: Timer?
    /// 屏幕参数变化的观察者。**单独存**而不是塞进 `observers` —— 它挂在
    /// NotificationCenter.default 上,跟那个数组里其余三条(NSWorkspace 的 center)不是同一个
    /// center,混在一起摘会摘错地方、留下野观察者。
    private var screenParamsObserver: NSObjectProtocol?
    /// 从"判定说没人全屏了"到真的翻回 false 的宽限期——伪全屏那条判据(见
    /// detectFullscreenApp)天生比"整块物理屏幕"那条更容易被抖:视频通话类 App 常见的
    /// 悬浮控制条(静音/摄像头/挂断按钮)随鼠标移动淡入淡出,实测(2026-08-22,微信通话
    /// 全屏)每次控制条一现身,窗口 bounds 就短暂缩进那么几像素,`present` 在 true/false
    /// 之间连续 ping-pong,灵动岛跟着一起闪——比一直不隐藏更扎眼。翻 true 不设宽限(想
    /// 隐藏就该马上隐藏);只有翻 false 才等这段时间、且到期时重新查一遍(宽限期内又回到
    /// 全屏就地取消),真退出全屏时晚这么一点点重新出现,换来不因为控制条闪现就来回蹦跶。
    private static let exitGraceSeconds: TimeInterval = 1.5

    private init() {}

    /// 开关打开/关闭时调。幂等。
    func setEnabled(_ enabled: Bool) {
        if enabled {
            startObserving()
        } else {
            stopObserving()
            pendingExit?.cancel()
            pendingExit = nil
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
        // 屏幕增删/分辨率/缩放变化会让上一次算出来的屏幕矩形整个作废。
        // ⚠️ 这条是 NSApplication 的通知,挂在 NotificationCenter.default 上,不在
        // NSWorkspace 那个 center 里 —— 摘的时候两边都要摘(见 stopObserving)。
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        // ⚠️ **伪全屏一个通知都不发**:App 自己的全屏按钮(微信视频通话那种)不新建 Space、
        // 不切换前台 App、也不改屏幕参数 —— 上面四个通知全都静默。没有这条兜底轮询的话,
        // 专门为伪全屏加的那条判据实际上要等一次**无关的** App 切换才会被跑到,表现就是
        // "点了全屏,浮层要过很久才让开、甚至压根不让开"。
        //
        // 2 秒是刻意的粗粒度:一次求值就是一次 CGWindowListCopyWindowInfo,不是热路径;
        // "全屏了但晚 2 秒才让开"完全可以接受,比"永远不让开"好得多。挂 .common mode,
        // 否则拖窗口/开着菜单时这条会停摆(跟 20Hz 那条 fastTimer 同一个坑)。
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refreshNow()
    }

    private func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        refreshTask?.cancel()
        refreshTask = nil
        pendingExit?.cancel()
        pendingExit = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if let screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
            self.screenParamsObserver = nil
        }
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
        if present {
            // 想隐藏就该立刻隐藏,不设宽限;顺手撤掉还没到期的"翻回 false"意图——
            // 宽限期内重新判定成全屏,是"控制条闪一下"而不是"真退出了"。
            pendingExit?.cancel()
            pendingExit = nil
            guard !isFullscreenAppPresent else { return }
            isFullscreenAppPresent = true
            Self.logger.notice("fullscreen app present = true")
            return
        }
        // 已经是 false、且没有已排期的退出任务,没什么好做的。
        guard isFullscreenAppPresent, pendingExit == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingExit = nil
            guard self.isFullscreenAppPresent else { return }
            // 到期时重新查一遍而不是直接信之前那次判定——这段时间里随时可能有新的
            // NSWorkspace 通知把状态重新判成 true(那条路已经在上面提前 return 了),
            // 这里只处理"true → 一直没人再报回 true → 真的退出了"这一种情况。
            guard !Self.detectFullscreenApp() else { return }
            self.isFullscreenAppPresent = false
            Self.logger.notice("fullscreen app present = false")
        }
        pendingExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGraceSeconds, execute: work)
    }

    /// 扫一遍屏幕上的窗口,看有没有**别人的**窗口铺满了某一块屏。
    ///
    /// ## 判据
    ///
    /// 一块屏被"铺满"要同时满足:宽度顶格 + 左边缘对齐 + 底边探到屏幕最底 + **顶边落在三个
    /// 合法位置之一**。三个顶边分别对应三种真实形态(同一台机器上三种都会出现):
    ///
    ///   1. `屏幕顶`       —— 原生全屏、且内容延伸进刘海两侧(App 没开安全区兼容模式);
    ///   2. `刘海下沿`     —— 原生全屏、但内容避开刘海(safeAreaInsets.top,刘海区留黑);
    ///   3. `菜单栏下沿`   —— 「伪全屏」:App 自己的全屏按钮(微信视频通话、部分播放器)根本
    ///                        不走 macOS 原生全屏 API,不新建 Space、菜单栏也不收起,只是把
    ///                        窗口拉到"整块屏减去菜单栏那一条"。
    ///
    /// ⚠️ 形态 2 是 2026-08-22 补的,**此前会漏判**。原来只认形态 1 和 3,而形态 3 用的是
    /// 「菜单栏下沿」——原生全屏时菜单栏已经收起,那个值变成 0,于是期望顶边算成屏幕顶,
    /// 跟实际的刘海下沿(本机 32pt)差 32pt,超出容差直接漏掉。第三方实现 Lyriam 的注释一语
    /// 中的:「CGWindow bounds are unreliable on notched displays because full-screen content
    /// sits below the notch」。桌面状态下形态 2 和 3 的顶边只差 1pt(本机 32 vs 33),看着像
    /// 同一条,但那 1pt 是本机实测特例、不是系统契约,换机型/换系统版本就不成立 —— 必须分开列。
    ///
    /// ## 为什么"底边探到屏幕最底"是关键的一条
    ///
    /// 它把**标准最大化窗口**挡在外面:绿键 zoom 铺的是 `visibleFrame`,底边停在 Dock 的保留区
    /// 上方。本机实测(2026-08-22,桌面态):音乐 (0,33,1470,858) 底边 891、Arc/Code/Edge 底边 878,
    /// 而屏幕高 956 —— 全部不命中;微信视频通话伪全屏则是 (0,33,1470,923),底边正好 956,命中。
    /// ⚠️ 已知不可判定的边界:用户若把 Dock 设成自动隐藏,最大化窗口的底边也会探到屏幕最底,
    /// 那时它跟伪全屏在**公开 API 下几何完全同构**,分不开。接受这个误判 —— 代价只是浮层临时
    /// 让开(移开窗口即恢复),而反方向(漏判)是用户已经报过的"全屏时隐藏根本不生效"。
    ///
    /// ## 坐标系
    ///
    /// 全程留在 **CG 坐标系**(原点主屏左上、y 向下):屏幕矩形用 `CGDisplayBounds(displayID)`,
    /// 跟 `CGWindowListCopyWindowInfo` 报的 bounds **同源**。原来是手工拿 NSScreen.frame 翻 y,
    /// 而 `lyrimuse/scripts/check-windows.swift` 文件头记着 2026-08-21 的实测:外接屏上
    /// CGWindowList 报的 bounds 与 NSWindow.frame **差 0.98 倍**(900→882、120→118)——那是 CG
    /// 空间与 AppKit 点空间的换算差,±1pt 的等值判据在这种差下必然失败,外接屏上的真全屏
    /// 大概率一直是漏判的。同源之后这个差整个消失。
    ///
    /// 两道前置筛选:`kCGWindowLayer == 0`(只认普通应用窗口——菜单栏、Dock、我们自己的浮层
    /// 都在别的层)、owner PID 不是自己。
    private static func detectFullscreenApp() -> Bool {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // 先把每块屏在 CG 坐标系下的矩形和合法顶边算好,避免在窗口循环里重复算。
        // 判据本身是纯几何,住在 LyrimuseCore 的 `FullscreenGeometry`(selftest 无屏覆盖);
        // 这里只负责把 AppKit/CoreGraphics 的现实喂给它。
        let boxes: [(rect: CGRect, legalTops: [CGFloat])] = NSScreen.screens.compactMap { screen in
            guard let displayID = ScreenIdentity.displayID(of: screen) else { return nil }
            let rect = CGDisplayBounds(displayID)
            // 菜单栏此刻在这块屏上占多高。全屏 Space 里系统会把它收起来 → 0;副屏通常也是 0
            // (菜单栏只画在一块屏上)。为 0 时第 ③ 个顶边跟第 ① 个重合,不会多判什么。
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            return (rect, FullscreenGeometry.legalTops(screen: rect,
                                                       safeAreaTop: screen.safeAreaInsets.top,
                                                       menuBarHeight: menuBarHeight))
        }
        guard !boxes.isEmpty else { return false }

        for info in raw {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let win = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            for box in boxes where FullscreenGeometry.covers(window: win,
                                                             screen: box.rect,
                                                             legalTops: box.legalTops) {
                return true
            }
        }
        return false
    }
}
