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
/// 卡片一收起浮框就关(控制器在收起那一刻叫 `close(ifOwner:)`)。另外再点一次专辑名、点浮框和灵动岛以外的
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
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    /// `cardFrame`:灵动岛卡片在屏幕上的矩形。同一扇窗、同一类再点一次 = 关。
    /// `onHover`:指针进出浮框;关掉时也会回报一次 false。
    func toggle(card: EditorialCard, cardFrame: NSRect, owner: NSWindow,
                onHover: @escaping (Bool) -> Void) {
        let sameSpot = panel != nil && ownerWindow === owner
        let sameKind = shownKind == card.kind
        close()
        if sameSpot && sameKind { return }
        show(card: card, cardFrame: cardFrame, owner: owner, onHover: onHover)
    }

    /// 卡片收起时由控制器叫:只关这扇窗自己开的那一个。
    func close(ifOwner owner: NSWindow?) {
        guard panel != nil, ownerWindow === owner else { return }
        close()
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
        panel.sharingType = owner.sharingType
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

        PlaybackCoordinator.shared.$title
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.close() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: owner)
            .sink { [weak self] note in
                guard let win = note.object as? NSWindow, !win.occlusionState.contains(.visible) else { return }
                self?.close()
            }
            .store(in: &cancellables)

        // 点在别的 App 上:关。点在本 App 别的窗口上:关;点在浮框自己或灵动岛上不关 ——
        // 专辑名 / 歌手名那一下由 toggle 自己处理,在这里关掉会变成"关了又立刻开"。
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window !== self.panel, event.window !== self.ownerWindow { self.close() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }
}
