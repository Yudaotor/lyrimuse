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
    /// 读数变了(值真的变了才调;打开后第一轮全量扫完也调一次)。
    var onChange: (() -> Void)?
    /// 打开后第一轮全量扫完了(或没授权、不扫)。没扫完之前右侧按屏幕边缘算,刘海屏上会先落到刘海右边、扫完再跳到左边,
    /// 所以正中那几扇等它为真再出来。
    var isReady: Bool { firstScanDone || !AXIsProcessTrusted() }
    private var firstScanDone = false

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
        firstScanDone = false
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
                    let firstFull = full && !self.firstScanDone
                    if full { self.firstScanDone = true }
                    guard next != self.statusItemFrames || firstFull else { return }
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

/// 「菜单栏正中」那一档的窗口:每块要放的屏一扇,透明、不接点击、钉在那块屏的菜单栏上,里面各是一份跟状态栏项同款的
/// `MenuBarScrollingLabel`。画什么由 `MenuBarStatusItem.refresh()` 决定(同一套断句、配速、染色、副行),
/// 这里只管放哪几块屏、每扇多宽、摆在哪、显隐。
///
/// 全屏 Space 里菜单栏收起,这扇窗也不跟进去:collectionBehavior 不带全屏辅助那一项。
@MainActor
final class MenuBarCenterLyrics {
    /// 一块屏上的那一扇。按屏幕 ID(`ScreenIdentity`)记,插拔、重排屏幕都不会认错。
    @MainActor
    final class Slot {
        let label = MenuBarScrollingLabel()
        let panel: NSPanel
        var animationsPaused = false

        init(panel: NSPanel) { self.panel = panel }
    }

    private var slots: [String: Slot] = [:]
    /// 每块屏最近一次算出的那一段与两侧读数,给 `debug/state` 看。
    private var readings: [String: (span: ClosedRange<CGFloat>, menusMaxX: CGFloat?, statusItemsMinX: CGFloat?)] = [:]
    private var pendingHide: DispatchWorkItem?
    private var appearanceSink: AnyCancellable?

    /// 本机验证用(`debug/menubar-center?ignore-notch=1`):当作没有刘海、直接压在正中,刘海屏的开发机才验得到无刘海屏的摆法。
    static var ignoresNotchForDebug = false

    /// 每一扇里的标签(对表、换色、冻住动画都要挨个喂)。
    var labels: [MenuBarScrollingLabel] { slots.values.map(\.label) }
    var windows: [NSWindow] { slots.values.map(\.panel) }
    /// 至少一扇摆在屏上、没在收的路上。
    var isShowing: Bool { pendingHide == nil && slots.values.contains { $0.panel.isVisible } }
    /// 给 `debug/state` 看:每一扇的屏幕、窗口与两侧读数。
    var debugSlots: [[String: Any]] {
        slots.map { id, slot in
            var out: [String: Any] = ["screenID": id, "visible": slot.panel.isVisible,
                                      "frame": [slot.panel.frame.minX, slot.panel.frame.minY,
                                                slot.panel.frame.width, slot.panel.frame.height]]
            if let reading = readings[id] {
                out["span"] = [reading.span.lowerBound, reading.span.upperBound]
                out["menusMaxX"] = reading.menusMaxX.map { $0 as Any } ?? NSNull()
                out["statusItemsMinX"] = reading.statusItemsMinX.map { $0 as Any } ?? NSNull()
            }
            return out
        }
    }

    init() {
        appearanceSink = MenuBarAppearanceStore.shared.$isDark.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let appearance = MenuBarAppearanceStore.shared.appearance
                self?.labels.forEach { $0.appearance = appearance }
            }
    }

    /// 刘海横跨的那一段(全局横坐标,跟灵动岛量刘海同一套 API);没有刘海、或调试开关打开时 nil。
    static func notchRange(of screen: NSScreen) -> ClosedRange<CGFloat>? {
        guard !ignoresNotchForDebug, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return left.maxX...right.minX
    }

    /// 居中歌词这一刻放哪几块屏(按「显示在」那一项)。空 = 一块都不放,歌词照旧在图标旁。
    static func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        let settings = AppSettings.shared
        let islandScreen: NSScreen? = settings.notchOverlayEnabled && !settings.notchAllScreens
            ? NotchLyricsWindowController.targetScreen() : nil
        let separateSpaces = NSScreen.screensHaveSeparateSpaces
        let candidates = screens.enumerated().map { index, screen in
            MenuBarCenterLayout.ScreenCandidate(
                islandHere: settings.notchOverlayEnabled && (settings.notchAllScreens || screen == islandScreen),
                hasMenuBar: separateSpaces || index == 0)
        }
        let choice: MenuBarCenterLayout.ScreenChoice
        switch settings.menuBarCenterScreen {
        case AppSettings.menuBarCenterAllScreens: choice = .all
        case AppSettings.menuBarCenterAutoScreen: choice = .auto
        case let id: choice = .specific(screens.firstIndex { ScreenIdentity.id(of: $0) == id })
        }
        return MenuBarCenterLayout.pickScreens(candidates, choice: choice).map { screens[$0] }
    }

    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height > 0 ? height : MenuBarCenterLayout.fallbackMenuBarHeight
    }

    private static func key(of screen: NSScreen) -> String {
        ScreenIdentity.id(of: screen) ?? "\(screen.frame.minX),\(screen.frame.minY)"
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
            menusMaxX: menusMaxX, statusItemsMinX: statusItemsMinX, notch: Self.notchRange(of: screen))
        readings[Self.key(of: screen)] = span.map { ($0, menusMaxX, statusItemsMinX) }
        return span
    }

    /// 只留这几块屏上的那一扇,别的立刻收掉、拆掉(换了「显示在」、拔了显示器、某块屏两侧挤得放不下)。
    func keep(only screens: [NSScreen]) {
        let wanted = Set(screens.map(Self.key(of:)))
        for (id, slot) in slots where !wanted.contains(id) {
            slot.panel.orderOut(nil)
            slot.label.clear()
            slots[id] = nil
            logger.notice("center lyrics dropped screen \(id, privacy: .public)")
        }
    }

    /// 把 `screen` 上那一扇摆到菜单栏的 `span` 里、宽 `contentWidth`(以屏幕中线居中)并显示,返回它的标签。
    /// 标签的高按状态栏按钮算、在菜单栏里竖直居中 —— 跟状态栏那一格同一套行高与双排落位。
    func show(on screen: NSScreen, span: ClosedRange<CGFloat>, contentWidth: CGFloat) -> MenuBarScrollingLabel {
        pendingHide?.cancel()
        pendingHide = nil
        let key = Self.key(of: screen)
        let slot = slots[key] ?? makeSlot(key: key)
        let barHeight = Self.menuBarHeight(of: screen)
        let width = min(contentWidth.rounded(.up), span.upperBound - span.lowerBound)
        let x = MenuBarCenterLayout.originX(width: width, screenMidX: screen.frame.midX, span: span)
        let frame = NSRect(x: x, y: screen.frame.maxY - barHeight, width: width, height: barHeight)
        if slot.panel.frame != frame { slot.panel.setFrame(frame, display: false) }
        let labelHeight = min(NSStatusBar.system.thickness, barHeight)
        let labelFrame = NSRect(x: 0, y: ((barHeight - labelHeight) / 2).rounded(), width: width, height: labelHeight)
        if slot.label.frame != labelFrame { slot.label.frame = labelFrame }
        if !slot.panel.isVisible {
            slot.panel.orderFrontRegardless()
            logger.notice("center lyrics shown screen=\(key, privacy: .public) x=\(frame.minX, privacy: .public) w=\(frame.width, privacy: .public)")
        }
        return slot.label
    }

    /// `delay` 秒后全部收起(期间又 `show` 就作罢)。歌词消失常是一两秒的间隙或假暂停,跟状态栏那一格同样先留一会儿。
    func hide(after delay: TimeInterval = 0) {
        guard slots.values.contains(where: { $0.panel.isVisible }) else { return }
        if delay > 0 {
            guard pendingHide == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.hideNow() }
            pendingHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            hideNow()
        }
    }

    /// 按每一扇此刻看不看得见冻住 / 恢复它的动画。返回 true = 有一扇刚恢复,调用方该强制对一次表。
    func applyAnimationPause(screensHidden: Bool) -> Bool {
        var resumed = false
        for slot in slots.values {
            let paused = screensHidden || !slot.panel.occlusionState.contains(.visible)
            guard paused != slot.animationsPaused else { continue }
            slot.animationsPaused = paused
            slot.label.setAnimationsPaused(paused)
            if !paused { resumed = true }
        }
        return resumed
    }

    private func hideNow() {
        pendingHide?.cancel()
        pendingHide = nil
        var hidden = false
        for slot in slots.values where slot.panel.isVisible {
            slot.panel.orderOut(nil)
            slot.label.clear()
            hidden = true
        }
        if hidden { logger.notice("center lyrics hidden") }
    }

    private func makeSlot(key: String) -> Slot {
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
        let slot = Slot(panel: panel)
        slot.label.alignmentOverride = .center
        slot.label.appearance = MenuBarAppearanceStore.shared.appearance
        content.addSubview(slot.label)
        slots[key] = slot
        return slot
    }
}
