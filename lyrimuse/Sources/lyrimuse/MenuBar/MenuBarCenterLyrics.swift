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
/// 没授权时什么都不读、读数清空,两侧按屏幕边缘算。只在「菜单栏正中」用着、有词要显示、屏幕亮着时运行(`setActive`);
/// 停下时读数留着,再开时先按它摆,同时后台补读一轮。
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
    /// 有一轮全量扫描在后台跑着(`scanIfNotReady` 不重复发)。
    private var fullScanInFlight = false
    private var pendingRescan: DispatchWorkItem?

    private var active = false
    /// 每次打开 / 关掉加一。后台那一轮回来时代数对不上就丢掉:关了又开时,上一轮的结果不能算成这一轮的首轮扫描。
    private var generation = 0
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
        generation += 1
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
        if dropReadingsIfUntrusted() { return }
        readFrontMenus()
        scanAll()
    }

    /// 只停轮询和监听,读数和 `firstScanDone` 留着:暂停、焦点在两块屏之间来回、锁屏时会频繁关了又开,
    /// 清掉的话每次再开都要先空等一轮全量扫描(约 3 秒)。
    private func stop() {
        timer?.invalidate()
        timer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        pendingRescan?.cancel()
        pendingRescan = nil
        fullScanInFlight = false
    }

    /// 首轮还没读完时当场补一轮全量(刚授权的那一刻 `isReady` 变假,别等下一次轮询)。已经有一轮在跑就不重复发。
    func scanIfNotReady() {
        guard active, !firstScanDone, !fullScanInFlight, AXIsProcessTrusted() else { return }
        readFrontMenus()
        scanAll()
    }

    /// 屏幕排列变了、自己那一格重建了:半秒后补读已知那几家(含自己)和前台菜单。系统摆好新位置要一会儿。
    func rescanSoon() {
        guard active else { return }
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRescan = nil
            self.scan(pids: Array(Set(self.statusItemFrames.keys).union([getpid()])), full: false)
            self.readFrontMenus()
        }
        pendingRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 授权被撤销:旧读数作废(不清的话一直按撤销那一刻的位置让),两侧回到按屏幕边缘算。
    private func dropReadingsIfUntrusted() -> Bool {
        guard !AXIsProcessTrusted() else { return false }
        if !statusItemFrames.isEmpty || !frontMenuFrames.isEmpty || firstScanDone {
            statusItemFrames = [:]
            frontMenuFrames = []
            firstScanDone = false
            onChange?()
        }
        return true
    }

    private func poll() {
        if dropReadingsIfUntrusted() { return }
        pollCount += 1
        // 首轮还没扫成(打开时没授权、后来才给)就按全量补:平时那一轮只复查已知有图标的几家,这时一家都不知道。
        if pollCount % Self.fullScanEvery == 0 || !firstScanDone {
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
        let generation = generation
        if full { fullScanInFlight = true }
        queue.async { [weak self] in
            var found: [pid_t: [CGRect]] = [:]
            for pid in pids {
                if let frames = Self.extrasFrames(pid: pid), !frames.isEmpty { found[pid] = frames }
            }
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.active, self.generation == generation else { return }
                    if full { self.fullScanInFlight = false }
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
        let generation = generation
        queue.async { [weak self] in
            let frames = Self.menuBarFrames(pid: pid) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.active, self.generation == generation, frames != self.frontMenuFrames else { return }
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
        // 超时只管设过的那一个元素,往下取到的菜单栏、各项都要各设一次,不然卡住的 App 每一步按系统默认等 6 秒。
        let barElement = bar as! AXUIElement
        AXUIElementSetMessagingTimeout(barElement, messagingTimeout)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        return items.compactMap { item in
            AXUIElementSetMessagingTimeout(item, messagingTimeout)
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

/// 正中那一扇的内容视图,收这一扇上的点击:歌词标签和悬停三键那一层都 `hitTest -> nil`,点击全落到这里。
@MainActor
final class MenuBarCenterContentView: NSView {
    var onMouseDown: ((MenuBarCenterContentView, NSEvent) -> Void)?

    // 不激活的面板当不了 key,第一下点击就要算数。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?(self, event) }
    override func rightMouseDown(with event: NSEvent) { onMouseDown?(self, event) }
}

/// 「菜单栏正中」那一档的窗口:每块要放的屏一扇,透明、钉在那块屏的菜单栏上,里面各是一份跟状态栏项同款的
/// `MenuBarScrollingLabel`。画什么由 `MenuBarStatusItem.refresh()` 决定(同一套断句、配速、染色、副行),
/// 这里只管放哪几块屏、每扇多宽、摆在哪、显隐,以及这一扇上的点击与悬停(怎么响应由 `MenuBarStatusItem` 定)。
/// 窗口只盖住两侧之间那段空着的菜单栏,收点击不挡别家的菜单和图标。
///
/// 全屏 Space 里菜单栏收起,这扇窗也不跟进去:collectionBehavior 不带全屏辅助那一项。
@MainActor
final class MenuBarCenterLyrics {
    /// 一块屏上的那一扇。按屏幕 ID(`ScreenIdentity`)记,插拔、重排屏幕都不会认错。
    @MainActor
    final class Slot {
        let label = MenuBarScrollingLabel()
        let content = MenuBarCenterContentView()
        let hoverControls = MenuBarHoverControlsView(reportsAppearance: false)
        let panel: NSPanel
        var animationsPaused = false

        init(panel: NSPanel) { self.panel = panel }
    }

    enum Click {
        /// 左键:弹面板,悬停三键接管着时点在键上就是播放控制。
        case primary
        /// 右键 / ⌃左键:弹完整菜单。
        case menu
    }

    /// 点了某一扇。`view` 是那一扇的内容视图(面板、菜单挂在它下面),`point` 在它的坐标里。
    var onClick: ((Click, NSView, NSPoint) -> Void)?
    /// 指针进 / 出正中那几扇(参数是此刻在不在任何一扇上)。
    var onHoverChange: ((Bool) -> Void)?
    /// 这一扇的内容视图上此刻锚着左键面板。锚着的那一扇 `keep(only:)` / `hide` 都不收,面板收起后的那次重算再落地。
    var isAnchoringPanel: ((NSView) -> Bool)?

    private var slots: [String: Slot] = [:]
    /// 指针停在哪一扇上。
    private var hoveredKey: String?
    /// 哪一扇正换成悬停三键。
    private var engagedKey: String?
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
                guard let self else { return }
                let appearance = MenuBarAppearanceStore.shared.appearance
                for slot in self.slots.values {
                    slot.label.appearance = appearance
                    slot.hoverControls.appearance = appearance
                }
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
        let separateSpaces = NSScreen.screensHaveSeparateSpaces
        let candidates = screens.enumerated().map { index, screen in
            MenuBarCenterLayout.ScreenCandidate(
                hasMenuBar: MenuBarCenterLayout.showsMenuBar(
                    separateSpaces: separateSpaces, isPrimary: index == 0,
                    frameMaxY: screen.frame.maxY, visibleFrameMaxY: screen.visibleFrame.maxY))
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

    /// 只留这几块屏上的那一扇,别的立刻收掉、拆掉(换了「显示在」、拔了显示器、某块屏两侧挤得放不下);锚着面板的那一扇除外。
    func keep(only screens: [NSScreen]) {
        let wanted = Set(screens.map(Self.key(of:)))
        for (id, slot) in slots where !wanted.contains(id) && isAnchoringPanel?(slot.content) != true {
            slot.panel.orderOut(nil)
            slot.label.clear()
            forgetPointer(on: id)
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
        let controlsFrame = NSRect(x: 0, y: 0, width: width, height: barHeight)
        if slot.hoverControls.frame != controlsFrame { slot.hoverControls.frame = controlsFrame }
        if !slot.panel.isVisible {
            slot.panel.orderFrontRegardless()
            logger.notice("center lyrics shown screen=\(key, privacy: .public) x=\(frame.minX, privacy: .public) w=\(frame.width, privacy: .public)")
        }
        return slot.label
    }

    /// `delay` 秒后全部收起(期间又 `show` 就作罢;锚着面板的那一扇留着)。歌词消失常是一两秒的间隙或假暂停,跟状态栏那一格同样先留一会儿。
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
        for (id, slot) in slots where slot.panel.isVisible && isAnchoringPanel?(slot.content) != true {
            slot.panel.orderOut(nil)
            slot.label.clear()
            forgetPointer(on: id)
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
        // 明说 false:不设时全透明的像素照样把点击漏给底下,字缝里点不中。
        panel.ignoresMouseEvents = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let slot = Slot(panel: panel)
        let content = slot.content
        content.wantsLayer = true
        panel.contentView = content
        slot.label.alignmentOverride = .center
        slot.label.appearance = MenuBarAppearanceStore.shared.appearance
        content.addSubview(slot.label)
        slot.hoverControls.appearance = MenuBarAppearanceStore.shared.appearance
        content.addSubview(slot.hoverControls)
        slot.hoverControls.installTracking(on: content)
        slot.hoverControls.onHoverChange = { [weak self] inside in self?.pointerMoved(on: key, inside: inside) }
        content.onMouseDown = { [weak self] view, event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let menu = event.type == .rightMouseDown || flags.contains(.control)
            self?.onClick?(menu ? .menu : .primary, view, view.convert(event.locationInWindow, from: nil))
        }
        slots[key] = slot
        return slot
    }

    // MARK: - 悬停三键

    /// 指针停在某一扇上。
    var isHovered: Bool { hoveredKey != nil }
    /// 有一扇正换成悬停三键。
    var hoverEngaged: Bool { engagedKey != nil }

    private func pointerMoved(on key: String, inside: Bool) {
        if inside {
            hoveredKey = key
        } else if hoveredKey == key {
            hoveredKey = nil
        }
        onHoverChange?(isHovered)
    }

    /// 那一扇收起、拆掉时:指针和三键的记录一起作废(不回调,下一次 `refresh()` 照常画)。
    private func forgetPointer(on key: String) {
        if hoveredKey == key { hoveredKey = nil }
        guard engagedKey == key, let slot = slots[key] else { return }
        engagedKey = nil
        slot.hoverControls.setEngaged(false)
        slot.hoverControls.setSlot(nil)
    }

    /// 指针停着的那一扇换成三个键:歌词收掉(歌词旁的图标留着),三个键排在歌词那一格,纵向给满。
    /// 那一格装不下三个键就不换、返回 false。窗口一点不动;收起的倒计时作废,退出时调用方补一次重算再定收不收。
    /// 歌词格的算式跟状态栏那一格同一份(`MenuBarHoverControls.lyricsSlot`),内容宽按窗口宽减 `slotPadding` 反推。
    func engageHoverControls(icon: MenuBarScrollingLabel.IconBadge?, slotPadding: CGFloat,
                             playing: Bool, withheld: Bool) -> Bool {
        guard engagedKey == nil, let key = hoveredKey, let slot = slots[key], slot.panel.isVisible else { return false }
        let bounds = slot.content.bounds
        guard let lyrics = MenuBarHoverControls.lyricsSlot(
            buttonWidth: bounds.width, contentWidth: bounds.width - slotPadding,
            reservedIconWidth: MenuBarProgressIcon.reservedWidth(for: icon), iconLeading: icon?.position == .leading)
        else { return false }
        slot.hoverControls.setSlot(CGRect(x: lyrics.x, y: bounds.minY, width: lyrics.width, height: bounds.height))
        guard slot.hoverControls.fitsControls else {
            slot.hoverControls.setSlot(nil)
            return false
        }
        pendingHide?.cancel()
        pendingHide = nil
        if slot.label.showsIconBadge {
            slot.label.clearLyricsKeepingIcon()
        } else {
            slot.label.clear()
        }
        slot.hoverControls.setPlaying(playing)
        slot.hoverControls.setWithheld(withheld)
        slot.hoverControls.setEngaged(true)
        engagedKey = key
        return true
    }

    func releaseHoverControls() {
        guard let key = engagedKey else { return }
        engagedKey = nil
        slots[key]?.hoverControls.setEngaged(false)
        slots[key]?.hoverControls.setSlot(nil)
    }

    /// 这一下点在三个键里的哪一个。没接管、或点的不是接管着的那一扇时 nil。三键那一层铺满内容视图,坐标通用。
    func hoverControl(in view: NSView, at point: NSPoint) -> MenuBarTransportControl? {
        guard let key = engagedKey, let slot = slots[key], slot.content === view else { return nil }
        return slot.hoverControls.control(at: point)
    }

    func setHoverPlaying(_ on: Bool) { slots.values.forEach { $0.hoverControls.setPlaying(on) } }
    func setHoverWithheld(_ on: Bool) { slots.values.forEach { $0.hoverControls.setWithheld(on) } }

    // MARK: - 调试(`debug/menubar-center?hover=…&click=…`)

    /// 当作指针进 / 出第一扇摆着的窗口。
    func debugHover(_ inside: Bool) {
        guard let key = slots.first(where: { $0.value.panel.isVisible })?.key else { return }
        pointerMoved(on: key, inside: inside)
    }

    /// 当作在第一扇摆着的窗口正中点了一下。悬停三键接管着时正中是播放 / 暂停。
    func debugClick(_ click: Click) {
        guard let slot = slots.values.first(where: { $0.panel.isVisible }) else { return }
        let bounds = slot.content.bounds
        onClick?(click, slot.content, NSPoint(x: bounds.midX, y: bounds.midY))
    }
}
