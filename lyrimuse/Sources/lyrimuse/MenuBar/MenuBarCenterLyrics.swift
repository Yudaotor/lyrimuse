import AppKit
import ApplicationServices
import Combine
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "menubar-center")

/// 菜单栏上两侧已经被占掉的地方:前台 App 的菜单(左边)、各家的状态栏图标(右边)。「菜单栏正中」那一档
/// 据此让开(`MenuBarCenterLayout`)。
///
/// 两样都只能经辅助功能读:状态栏项从 macOS 27 起由系统 MenuBarAgent 托管,窗口列表里已经没有它们的窗口。
/// 读状态栏项要挨个问每个 App 要 `AXExtrasMenuBar`,全量问一遍约 3 秒(一部分进程到超时才回),所以:
/// 全量只在打开时和每 `fullScanEvery` 轮做一次、放在后台队列;平时每 `pollSeconds` 秒只复查已知有图标的那几家,
/// 新开的 App 单独问。前台 App 的菜单每次切换前台时读一次,菜单常在激活后才换好,隔一会儿再读一次。
/// 没授权时什么都不读,两侧按屏幕边缘算。只在「菜单栏正中」用着时运行(`setActive`)。
@MainActor
final class MenuBarOccupancy {
    static let shared = MenuBarOccupancy()

    /// 有状态栏图标的那几家:pid → 各图标的框(辅助功能坐标,左上角为原点、y 向下)。
    private(set) var statusItemFrames: [pid_t: [CGRect]] = [:]
    /// 前台 App 菜单栏各项的框(同上)。
    private(set) var frontMenuFrames: [CGRect] = []
    /// 读数变了(值真的变了才调)。
    var onChange: (() -> Void)?

    private var active = false
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollCount = 0
    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.menubar-occupancy", qos: .utility)

    private static let pollSeconds: TimeInterval = 20
    private static let fullScanEvery = 15
    /// 问一个 App 最多等多久。不回的多半是没有界面的后台进程。
    nonisolated private static let messagingTimeout: Float = 0.1

    private init() {}

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { start() } else { stop() }
    }

    private func start() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readFrontMenus()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.readFrontMenus() }
                }
            },
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                // 状态栏图标在 App 起来之后才建,隔两拍各问一次。
                MainActor.assumeIsolated {
                    for delay in [2.0, 6.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.scan(pids: [pid], full: false) }
                    }
                }
            },
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated {
                    guard let self, self.statusItemFrames.removeValue(forKey: pid) != nil else { return }
                    self.onChange?()
                }
            },
        ]
        let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        readFrontMenus()
        scanAll()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        statusItemFrames = [:]
        frontMenuFrames = []
    }

    private func poll() {
        pollCount += 1
        if pollCount % Self.fullScanEvery == 0 {
            scanAll()
        } else {
            scan(pids: Array(statusItemFrames.keys), full: false)
        }
        readFrontMenus()
    }

    private func scanAll() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map(\.processIdentifier)
        scan(pids: pids, full: true)
    }

    /// `full`:这一批是全部有界面的 App,没出现在结果里的旧记录一并清掉。
    private func scan(pids: [pid_t], full: Bool) {
        guard active, AXIsProcessTrusted(), !pids.isEmpty else { return }
        let started = Date()
        queue.async { [weak self] in
            var found: [pid_t: [CGRect]] = [:]
            for pid in pids {
                if let frames = Self.extrasFrames(pid: pid), !frames.isEmpty { found[pid] = frames }
            }
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.active else { return }
                    var next = self.statusItemFrames
                    if full {
                        next = found
                    } else {
                        for pid in pids { next[pid] = found[pid] }
                    }
                    if full {
                        logger.debug("""
                            status items scanned: apps=\(pids.count, privacy: .public) \
                            holders=\(next.count, privacy: .public) secs=\(elapsed, privacy: .public)
                            """)
                    }
                    guard next != self.statusItemFrames else { return }
                    self.statusItemFrames = next
                    self.onChange?()
                }
            }
        }
    }

    private func readFrontMenus() {
        guard active, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        queue.async { [weak self] in
            let frames = Self.menuBarFrames(pid: pid) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.active, frames != self.frontMenuFrames else { return }
                    self.frontMenuFrames = frames
                    self.onChange?()
                }
            }
        }
    }

    nonisolated private static func extrasFrames(pid: pid_t) -> [CGRect]? {
        childFrames(pid: pid, attribute: kAXExtrasMenuBarAttribute)
    }

    nonisolated private static func menuBarFrames(pid: pid_t) -> [CGRect]? {
        childFrames(pid: pid, attribute: kAXMenuBarAttribute)
    }

    nonisolated private static func childFrames(pid: pid_t, attribute: String) -> [CGRect]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        return items.compactMap { item in
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: point, size: extent)
        }
    }
}

/// 「菜单栏正中」那一档的窗口:透明、不接点击、钉在菜单栏那一条上,里面是一份跟状态栏项同款的
/// `MenuBarScrollingLabel`。画什么由 `MenuBarStatusItem.refresh()` 决定(同一套断句、配速、染色、副行),
/// 这里只管窗口放哪块屏、多宽、摆在哪、显隐。
///
/// 全屏 Space 里菜单栏收起,这扇窗也不跟进去:collectionBehavior 不带全屏辅助那一项。
@MainActor
final class MenuBarCenterLyrics {
    let label = MenuBarScrollingLabel()
    private var panel: NSPanel?
    private var pendingHide: DispatchWorkItem?
    private var appearanceSink: AnyCancellable?
    /// 最近一次摆窗用的那一段与两侧读数,给 `debug/state` 看。
    private(set) var lastLayout: (screen: CGRect, span: ClosedRange<CGFloat>, menusMaxX: CGFloat?, statusItemsMinX: CGFloat?)?

    /// 本机验证用(`debug/menubar-center?ignore-notch=1`):把有刘海的屏也当成能用的,这台只有刘海屏的开发机才验得到。
    static var ignoresNotchForDebug = false

    var window: NSWindow? { panel }
    /// 窗口此刻摆在屏上、没在收的路上。
    var isShowing: Bool { panel?.isVisible == true && pendingHide == nil }

    init() {
        label.alignmentOverride = .center
        appearanceSink = MenuBarAppearanceStore.shared.$isDark.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.label.appearance = MenuBarAppearanceStore.shared.appearance }
    }

    /// 这块屏算不算有刘海(调试开关打开时一律不算)。
    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 && !ignoresNotchForDebug
    }

    /// 居中歌词这一刻该落在哪块屏。nil = 没有能用的,歌词照旧在图标旁。
    static func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let settings = AppSettings.shared
        let islandScreen: NSScreen? = settings.notchOverlayEnabled && !settings.notchAllScreens
            ? NotchLyricsWindowController.targetScreen() : nil
        let candidates = screens.map { screen in
            MenuBarCenterLayout.ScreenCandidate(
                hasNotch: hasNotch(screen),
                islandHere: settings.notchOverlayEnabled && (settings.notchAllScreens || screen == islandScreen))
        }
        return MenuBarCenterLayout.pickScreen(candidates).map { screens[$0] }
    }

    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height > 0 ? height : MenuBarCenterLayout.fallbackMenuBarHeight
    }

    /// 这块屏的菜单栏里能放歌词的那一段。nil = 两侧挤得放不下。
    func span(on screen: NSScreen) -> ClosedRange<CGFloat>? {
        let occupancy = MenuBarOccupancy.shared
        let screenFrames = NSScreen.screens.map(\.frame)
        let menusMaxX = MenuBarCenterLayout.menusMaxX(
            menuFrames: occupancy.frontMenuFrames, screenFrames: screenFrames, target: screen.frame)
        let statusItemsMinX = MenuBarCenterLayout.statusItemsMinX(
            itemFrames: occupancy.statusItemFrames.values.flatMap { $0 }, screenFrames: screenFrames,
            target: screen.frame, primaryMaxY: NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY,
            menuBarHeight: Self.menuBarHeight(of: screen))
        let span = MenuBarCenterLayout.usableSpan(
            screenMinX: screen.frame.minX, screenMaxX: screen.frame.maxX,
            menusMaxX: menusMaxX, statusItemsMinX: statusItemsMinX)
        if let span { lastLayout = (screen.frame, span, menusMaxX, statusItemsMinX) }
        return span
    }

    /// 把窗口摆到 `screen` 菜单栏的 `span` 里、宽 `contentWidth`(以屏幕中线居中)并显示。标签的高按状态栏按钮算、
    /// 在菜单栏里竖直居中 —— 跟状态栏那一格同一套行高与双排落位。
    func show(on screen: NSScreen, span: ClosedRange<CGFloat>, contentWidth: CGFloat) {
        pendingHide?.cancel()
        pendingHide = nil
        let panel = panel ?? makePanel()
        let barHeight = Self.menuBarHeight(of: screen)
        let width = min(contentWidth.rounded(.up), span.upperBound - span.lowerBound)
        let x = MenuBarCenterLayout.originX(width: width, screenMidX: screen.frame.midX, span: span)
        let frame = NSRect(x: x, y: screen.frame.maxY - barHeight, width: width, height: barHeight)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        let labelHeight = min(NSStatusBar.system.thickness, barHeight)
        let labelFrame = NSRect(x: 0, y: ((barHeight - labelHeight) / 2).rounded(), width: width, height: labelHeight)
        if label.frame != labelFrame { label.frame = labelFrame }
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            logger.notice("center lyrics shown x=\(frame.minX, privacy: .public) w=\(frame.width, privacy: .public)")
        } else if panel.alphaValue < 1 {
            panel.alphaValue = 1
        }
    }

    /// `delay` 秒后收起(期间又 `show` 就作罢)。歌词消失常是一两秒的间隙或假暂停,跟状态栏那一格同样先留一会儿。
    func hide(after delay: TimeInterval = 0) {
        guard let panel, panel.isVisible else { return }
        if delay > 0 {
            guard pendingHide == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.hideNow() }
            pendingHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            hideNow()
        }
    }

    private func hideNow() {
        pendingHide?.cancel()
        pendingHide = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        label.clear()
        logger.notice("center lyrics hidden")
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.identifier = NSUserInterfaceItemIdentifier("menubar-center-lyrics")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let content = NSView()
        content.wantsLayer = true
        panel.contentView = content
        label.appearance = MenuBarAppearanceStore.shared.appearance
        content.addSubview(label)
        self.panel = panel
        return panel
    }
}
