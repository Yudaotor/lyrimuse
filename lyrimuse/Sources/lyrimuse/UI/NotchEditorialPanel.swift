import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 灵动岛展开态点专辑名 / 歌手名弹出的简介浮框(`EditorialCard`,专辑简介与歌手简介共用一扇)。
///
/// 单独一扇无边框面板,贴在卡片正下方:灵动岛窗口是固定尺寸的,装不下一段正文;系统 popover 在这扇
/// `.screenSaver` 层级的非激活面板上位置与层级都不可靠。层级、跨 Space、截屏隐藏跟灵动岛窗口一致。
///
/// 它算展开态的一部分:指针在浮框上时卡片保持展开(`onHover` 回报给控制器,跟卡片自己的悬停合并判定),
/// 卡片一收起浮框就关(控制器在收起那一刻叫 `close(ifOwner:)`)。另外点灵动岛上任何地方、点浮框和灵动岛以外的
/// 地方、换歌、灵动岛窗口藏起来也关。再点同一类(又点专辑名)= 关;点另一类(开着专辑、点歌手)= 换内容。
@MainActor
final class NotchEditorialPanel {
    static let shared = NotchEditorialPanel()

    private static let width: CGFloat = 320
    /// 与卡片下沿的间隙。要小于指针从卡片移到浮框途中能容忍的空档(卡片收起延迟 0.1s)。
    private static let gap: CGFloat = 4

    private var panel: NSPanel?
    private var shownKind: EditorialCard.Kind?
    private var ownerWindow: NSWindow?
    private var onHover: ((Bool) -> Void)?
    private var monitors: [Any] = []
    /// 按下灵动岛那一刻关掉的是哪一类、什么时候。按钮在**松手**时才触发 `toggle`,而浮框在按下时就关了 ——
    /// 不记这一笔,再点同一个专辑名会变成"按下关、松手又开"。
    private var closedByOwnerClick: (kind: EditorialCard.Kind, at: Date)?
    /// 按下到松手之间最多隔多久还算同一下点击。
    private static let clickWindow: TimeInterval = 1.0
    /// 那一笔只对**这一下**点击有效:下一次按下就清掉(先点空白关掉、紧接着又点专辑名,是要重新打开)。
    private var pendingClickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    /// `cardFrame`:灵动岛卡片在屏幕上的矩形。同一扇窗、同一类再点一次 = 关。
    /// `onHover`:指针进出浮框;关掉时也会回报一次 false。
    func toggle(card: EditorialCard, cardFrame: NSRect, owner: NSWindow,
                onHover: @escaping (Bool) -> Void) {
        if let closed = closedByOwnerClick {
            forgetOwnerClick()
            // 这一下的按下已经把浮框关了:点的是同一类就到此为止(= 关),另一类照常换内容。
            if closed.kind == card.kind, Date().timeIntervalSince(closed.at) < Self.clickWindow { return }
        }
        let sameSpot = panel != nil && ownerWindow === owner
        let sameKind = shownKind == card.kind
        close()
        if sameSpot && sameKind { return }
        show(card: card, cardFrame: cardFrame, owner: owner, onHover: onHover)
    }

    private func rememberOwnerClick(_ kind: EditorialCard.Kind, eventTime: TimeInterval) {
        forgetOwnerClick()
        closedByOwnerClick = (kind, Date())
        // 按时间戳认出「这一下自己的按下」,只有之后的按下才清掉。
        pendingClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.timestamp != eventTime { MainActor.assumeIsolated { self?.forgetOwnerClick() } }
            return event
        }
    }

    private func forgetOwnerClick() {
        closedByOwnerClick = nil
        if let monitor = pendingClickMonitor { NSEvent.removeMonitor(monitor) }
        pendingClickMonitor = nil
    }

    /// 卡片收起时由控制器叫:只关这扇窗自己开的那一个。
    func close(ifOwner owner: NSWindow?) {
        guard panel != nil, ownerWindow === owner else { return }
        close()
    }

    /// 这扇窗(`owner`)开着的浮框在屏幕上的矩形;没开着或不是它开的为 nil。
    func frame(ifOwner owner: NSWindow?) -> NSRect? {
        guard let panel, ownerWindow === owner else { return nil }
        return panel.frame
    }

    func close() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        cancellables = []
        panel?.orderOut(nil)
        panel = nil
        shownKind = nil
        ownerWindow = nil
        let hover = onHover
        onHover = nil
        hover?(false)
    }

    private func show(card: EditorialCard, cardFrame: NSRect, owner: NSWindow,
                      onHover: @escaping (Bool) -> Void) {
        let content = EditorialNotesContent(card: card, primary: .white, secondary: .white.opacity(0.6))
            .padding(14)
            .frame(width: Self.width, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .onHover { onHover($0) }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        let height = max(40, hosting.fittingSize.height)
        var x = cardFrame.midX - Self.width / 2
        if let visible = owner.screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        }
        let frame = NSRect(x: x, y: cardFrame.minY - Self.gap - height, width: Self.width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = owner.level
        panel.collectionBehavior = owner.collectionBehavior
        // 按设置写,别抄灵动岛那扇窗的 sharingType:运行中读回来的值不可靠(见 NotchLyricsWindowController.applyBehaviorSettings)。
        panel.sharingType = AppSettings.shared.notchHideDuringScreenCapture ? .none : .readWrite
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        self.panel = panel
        self.shownKind = card.kind
        self.ownerWindow = owner
        self.onHover = onHover
        panel.orderFrontRegardless()

        // 换歌就关:按歌名 + 歌手 + 专辑认,只看歌名的话换到同名的另一首(翻唱、别的版本)浮框还挂着上一首的简介。
        let p = PlaybackCoordinator.shared
        Publishers.CombineLatest3(p.$title, p.$artist, p.$album)
            .map { "\($0)|\($1)|\($2)" }
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.close() }
            .store(in: &cancellables)
        // 灵动岛挪了位置或改了尺寸(换屏、改宽度):浮框是按当时的卡片位置摆的,留着就悬在原处,关掉。
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.publisher(for: name, object: owner)
                .sink { [weak self] _ in self?.close() }
                .store(in: &cancellables)
        }
        // 浮框开着时改了「截屏时隐藏」:跟着改,不然要关了重开才生效。
        AppSettings.shared.$notchHideDuringScreenCapture
            .dropFirst()
            .removeDuplicates()
            .sink { [weak panel] hide in panel?.sharingType = hide ? .none : .readWrite }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: owner)
            .sink { [weak self] note in
                guard let win = note.object as? NSWindow, !win.occlusionState.contains(.visible) else { return }
                self?.close()
            }
            .store(in: &cancellables)

        // 点在别的 App 上:关。点在本 App 别的窗口上、或灵动岛上任何地方:关;点在浮框自己身上不关。
        // 点的若正是专辑名 / 歌手名,松手时的 toggle 靠 closedByOwnerClick 认出"刚关的就是这一类",不再重开。
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard event.window !== self.panel else { return }
                if event.window === self.ownerWindow, let kind = self.shownKind {
                    self.rememberOwnerClick(kind, eventTime: event.timestamp)
                }
                self.close()
            }
            return event
        }) {
            monitors.append(local)
        }
    }
}
