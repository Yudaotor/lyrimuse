import AppKit

/// Interactive lyrics need an AppKit panel; AVKit PiP only presents video content.
/// Keep this independent of the normal window's fullscreen and frame restoration.
final class LyricsPictureInPictureWindow: NSPanel {
    static let minimumSize = CGSize(width: 320, height: 320)
    static let defaultSize = CGSize(width: 440, height: 540)
    private var resizeTrackingAreas: [NSTrackingArea] = []
    private var lastResizeCursor: NSCursor?
    private var resizeCursorTimer: Timer?
    var onPointerPresenceChange: ((Bool) -> Void)? {
        didSet { reportPointer(at: mouseLocationOutsideOfEventStream) }
    }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentMinSize = Self.minimumSize
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        identifier = NSUserInterfaceItemIdentifier("lyrics-picture-in-picture")
    }

    override var contentView: NSView? {
        didSet {
            releaseResizeCursor()
            for area in resizeTrackingAreas { oldValue?.removeTrackingArea(area) }
            resizeTrackingAreas = []
            guard let contentView else { return }
            // activeAlways delivers movement directly to the owner, including in
            // inactive apps, but explicitly does not deliver cursorUpdate events.
            // Keep the key-window cursor-update path in a separate tracking area.
            resizeTrackingAreas = [
                NSTrackingArea(rect: .zero,
                    options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited],
                    owner: self, userInfo: nil),
                NSTrackingArea(rect: .zero,
                    options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate],
                    owner: self, userInfo: nil),
            ]
            for area in resizeTrackingAreas { contentView.addTrackingArea(area) }
        }
    }

    // NSTrackingArea can dispatch straight to its owner without sendEvent. These
    // callbacks are required for hover feedback over a nonactivating PiP panel.
    override func mouseMoved(with event: NSEvent) { trackPointer(event) }
    override func mouseEntered(with event: NSEvent) { trackPointer(event) }
    override func mouseExited(with event: NSEvent) {
        onPointerPresenceChange?(false)
        releaseResizeCursor()
    }
    override func cursorUpdate(with event: NSEvent) { updateResizeCursor(at: event.locationInWindow) }

    private func trackPointer(_ event: NSEvent) {
        reportPointer(at: event.locationInWindow)
        updateResizeCursor(at: event.locationInWindow)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            reportPointer(at: event.locationInWindow)
        default: break
        }
        super.sendEvent(event)
        switch event.type {
        case .mouseMoved, .mouseEntered, .cursorUpdate, .leftMouseUp:
            // AppKit still owns native resizing. Set the border cursor after child
            // views handle the event, including when this nonactivating panel isn't key.
            updateResizeCursor(at: event.locationInWindow)
        default: break
        }
    }

    private func updateResizeCursor(at point: NSPoint) {
        guard let cursor = resizeCursor(at: point) else {
            releaseResizeCursor()
            return
        }
        // PiP deliberately leaves the owning app inactive. Without this existing
        // helper, NSCursor.current changes but WindowServer keeps the foreground
        // app's cursor on screen.
        BackgroundCursor.setEnabled(true, for: self)
        cursor.set()
        lastResizeCursor = cursor
        if isVisible && resizeCursorTimer == nil {
            // Foreground redraws may reset the cursor even without mouse motion.
            // Refresh only while the pointer remains on this panel's border.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    let point = self.mouseLocationOutsideOfEventStream
                    guard self.isVisible, !NSApp.isHidden,
                          NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == self.windowNumber,
                          self.resizeCursor(at: point) != nil else {
                        self.releaseResizeCursor()
                        return
                    }
                    self.updateResizeCursor(at: point)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            resizeCursorTimer = timer
        }
    }

    private func releaseResizeCursor() {
        resizeCursorTimer?.invalidate()
        resizeCursorTimer = nil
        if let lastResizeCursor, NSCursor.current == lastResizeCursor { NSCursor.arrow.set() }
        lastResizeCursor = nil
        BackgroundCursor.setEnabled(false, for: self)
    }

    override func orderOut(_ sender: Any?) {
        releaseResizeCursor()
        onPointerPresenceChange?(false)
        super.orderOut(sender)
    }

    override func close() {
        releaseResizeCursor()
        onPointerPresenceChange?(false)
        super.close()
    }

    private func reportPointer(at point: NSPoint) {
        onPointerPresenceChange?(NSRect(origin: .zero, size: frame.size).contains(point))
    }

    private func resizeCursor(at point: NSPoint) -> NSCursor? {
        let bounds = NSRect(origin: .zero, size: frame.size)
        guard bounds.contains(point) else { return nil }
        let left = point.x < 6, right = point.x >= bounds.width - 6
        let bottom = point.y < 6, top = point.y >= bounds.height - 6
        guard left || right || bottom || top else { return nil }
        let nearLeft = point.x < 16, nearRight = point.x >= bounds.width - 16
        let nearBottom = point.y < 16, nearTop = point.y >= bounds.height - 16
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            if nearTop && nearLeft { position = .topLeft }
            else if nearTop && nearRight { position = .topRight }
            else if nearBottom && nearLeft { position = .bottomLeft }
            else if nearBottom && nearRight { position = .bottomRight }
            else if left { position = .left }
            else if right { position = .right }
            else if top { position = .top }
            else { position = .bottom }
            return .frameResize(position: position, directions: .all)
        }
        if (nearTop && nearLeft) || (nearBottom && nearRight) { return Self.downwardDiagonal }
        if (nearTop && nearRight) || (nearBottom && nearLeft) { return Self.upwardDiagonal }
        return left || right ? .resizeLeftRight : .resizeUpDown
    }

    // Public AppKit diagonal resize cursors arrived in macOS 15. Draw a small,
    // outlined double arrow for macOS 14 instead of relying on private selectors.
    private static let upwardDiagonal = diagonalCursor(angle: 45)
    private static let downwardDiagonal = diagonalCursor(angle: -45)

    private static func diagonalCursor(angle: CGFloat) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let path = NSBezierPath()
            let points: [NSPoint] = [.init(x: 10, y: 0), .init(x: 4, y: 6), .init(x: 4, y: 2),
                .init(x: -4, y: 2), .init(x: -4, y: 6), .init(x: -10, y: 0),
                .init(x: -4, y: -6), .init(x: -4, y: -2), .init(x: 4, y: -2), .init(x: 4, y: -6)]
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.close()
            var transform = AffineTransform()
            transform.translate(x: 12, y: 12)
            transform.rotate(byDegrees: angle)
            path.transform(using: transform)
            path.lineWidth = 2
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.stroke()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }

    // Allow keyboard/accessibility interaction without activating the app or making
    // this a main window. Ordinary mouse clicks on lyrics don't need keyboard focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
