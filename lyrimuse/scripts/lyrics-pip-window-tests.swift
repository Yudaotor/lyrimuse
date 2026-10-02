// Compile with the production BackgroundCursor.swift and LyricsPictureInPictureWindow.swift.
// No XCTest dependency, player connection or user preferences are needed.
import AppKit

@main
struct LyricsPictureInPictureWindowTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let panel = LyricsPictureInPictureWindow(contentRect: NSRect(x: 20, y: 20, width: 440, height: 540))
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if !condition { failures += 1 }
        }
        expect(panel.level > .normal, "PiP is above normal windows")
        expect(panel.collectionBehavior.contains(.canJoinAllSpaces), "PiP joins all native Spaces")
        expect(panel.collectionBehavior.contains(.fullScreenAuxiliary), "PiP can accompany fullscreen apps")
        expect(!panel.collectionBehavior.contains(.fullScreenPrimary), "PiP does not create its own fullscreen Space")
        expect(panel.styleMask.contains(.nonactivatingPanel), "PiP does not activate the app on a lyric click")
        expect(panel.styleMask.contains(.resizable), "PiP is resizable")
        expect(panel.isMovable, "PiP can be moved using its header")
        expect(!panel.hidesOnDeactivate, "PiP remains visible when another app becomes active")
        expect(!panel.canBecomeMain, "PiP is not a main window")
        expect(panel.canBecomeKey, "PiP supports keyboard and accessibility focus")
        expect(!panel.ignoresMouseEvents, "PiP receives lyric clicks and scrolling")
        expect(!panel.isMovableByWindowBackground, "lyrics do not drag the window")
        expect(panel.contentMinSize.height >= 300, "minimum height leaves room for a lyrics list")
        expect(panel.standardWindowButton(.miniaturizeButton) == nil, "PiP is separate from normal minimization")
        expect(panel.standardWindowButton(.zoomButton) == nil, "PiP has no fullscreen control")
        expect(panel.acceptsMouseMovedEvents, "PiP receives pointer motion without a click")
        let content = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.contentView = content
        var pointerInside = false
        panel.onPointerPresenceChange = { pointerInside = $0 }
        expect(content.trackingAreas.contains { $0.options.contains(.activeAlways) },
               "border tracking also works when PiP is not the key window")
        expect(!content.trackingAreas.contains { $0.options.contains([.activeAlways, .cursorUpdate]) },
               "cursor updates do not use AppKit's unsupported activeAlways combination")
        let movementOwner = content.trackingAreas.first { $0.options.contains(.activeAlways) }?.owner as? NSResponder
        let cursorOwner = content.trackingAreas.first { $0.options.contains(.cursorUpdate) }?.owner as? NSResponder
        func event(at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        func move(to point: NSPoint) {
            panel.sendEvent(event(at: point))
        }
        // Inactive-window tracking calls the area's owner directly. It doesn't
        // necessarily pass through the window's sendEvent override.
        if let owner = content.trackingAreas.first(where: { $0.options.contains(.activeAlways) })?.owner as? NSResponder {
            let trackingEvent = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 2, y: 270),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0)!
            NSCursor.arrow.set()
            owner.mouseMoved(with: trackingEvent)
            expect(NSCursor.current != .arrow, "tracking-area owner shows a resize cursor without sendEvent")
        } else {
            expect(false, "activeAlways tracking has a responder owner")
        }
        for (name, point) in [("left", NSPoint(x: 2, y: 270)),
                              ("right", NSPoint(x: 438, y: 270)),
                              ("top", NSPoint(x: 220, y: 538)),
                              ("bottom", NSPoint(x: 220, y: 2)),
                              ("top left", NSPoint(x: 2, y: 538)),
                              ("top right", NSPoint(x: 438, y: 538)),
                              ("bottom left", NSPoint(x: 2, y: 2)),
                              ("bottom right", NSPoint(x: 438, y: 2))] {
            NSCursor.arrow.set()
            move(to: point)
            expect(NSCursor.current != .arrow, "\(name) border shows a resize cursor on pointer movement")
            NSCursor.arrow.set()
            movementOwner?.mouseEntered(with: event(at: point))
            expect(NSCursor.current != .arrow, "\(name) tracking entry sets its resize cursor")
            NSCursor.arrow.set()
            movementOwner?.mouseMoved(with: event(at: point))
            expect(NSCursor.current != .arrow, "\(name) tracking movement sets its resize cursor")
            NSCursor.arrow.set()
            cursorOwner?.cursorUpdate(with: event(at: point))
            expect(NSCursor.current != .arrow, "\(name) key-window cursor update sets its resize cursor")
            if #available(macOS 15.0, *) {
                let positions: [String: NSCursor.FrameResizePosition] = ["left": .left, "right": .right,
                    "top": .top, "bottom": .bottom, "top left": .topLeft, "top right": .topRight,
                    "bottom left": .bottomLeft, "bottom right": .bottomRight]
                expect(NSCursor.current == .frameResize(position: positions[name]!, directions: .all),
                       "\(name) uses the matching native resize direction")
            }
        }
        move(to: NSPoint(x: 220, y: 270))
        expect(pointerInside, "pointer entry reveals controls even when PiP isn't key")
        expect(NSCursor.current == .arrow, "moving into lyrics releases the resize cursor")
        move(to: NSPoint(x: 2, y: 270))
        NSCursor.openHand.set()
        move(to: NSPoint(x: 200, y: 521))
        expect(NSCursor.current == .openHand, "the header keeps its own drag cursor")
        panel.setContentSize(NSSize(width: 600, height: 400))
        move(to: NSPoint(x: 598, y: 200))
        expect(NSCursor.current != .arrow && NSCursor.current != .openHand,
               "resize hit regions follow the current window size")
        move(to: NSPoint(x: 650, y: 200))
        expect(!pointerInside, "pointer exit hides controls")
        expect(NSCursor.current == .arrow, "leaving the panel releases its resize cursor")
        movementOwner?.mouseEntered(with: event(at: NSPoint(x: 2, y: 200)))
        movementOwner?.mouseExited(with: event(at: NSPoint(x: -20, y: 200)))
        expect(!pointerInside && NSCursor.current == .arrow, "tracking exit clears cursor and hover state")
        movementOwner?.mouseEntered(with: event(at: NSPoint(x: 2, y: 200)))
        panel.orderOut(nil)
        expect(!pointerInside && NSCursor.current == .arrow, "hiding PiP clears its cursor and hover state")
        // Verify ownership through the existing helper's accepted request state.
        // NSCursor.currentSystem images are deprecated and can show intermediate
        // animation frames; actual pointer/display checks belong in UI verification.
        let observer = NSObject()
        let backgroundSupported = BackgroundCursor.setEnabled(true, for: observer)
        BackgroundCursor.setEnabled(false, for: observer)
        if backgroundSupported {
            expect(!NSApp.isActive, "background cursor checks run with the app inactive")
            move(to: NSPoint(x: 2, y: 200))
            expect(BackgroundCursor.setEnabled(false, for: observer),
                   "inactive PiP requests background cursor control on a resize border")
            move(to: NSPoint(x: 300, y: 200))
            expect(!BackgroundCursor.setEnabled(false, for: observer),
                   "leaving the border releases background cursor control")
            BackgroundCursor.setEnabled(true)
            move(to: NSPoint(x: 2, y: 200))
            move(to: NSPoint(x: 300, y: 200))
            expect(BackgroundCursor.setEnabled(false, for: observer),
                   "PiP exit preserves the overlay's background cursor request")
            BackgroundCursor.setEnabled(false)
            move(to: NSPoint(x: 2, y: 200))
            panel.orderOut(nil)
            expect(!BackgroundCursor.setEnabled(false, for: observer),
                   "hiding PiP releases background cursor control")
            move(to: NSPoint(x: 2, y: 200))
            panel.close()
            expect(!pointerInside && NSCursor.current == .arrow, "closing PiP clears its resize cursor")
            expect(!BackgroundCursor.setEnabled(false, for: observer),
                   "closing PiP releases background cursor control")
        } else {
            print("SKIP: this OS does not support the existing background cursor helper")
        }
        panel.contentView = nil
        expect(content.trackingAreas.isEmpty, "closing PiP removes its tracking area")
        NSCursor.arrow.set()
        exit(failures == 0 ? 0 : 1)
    }
}
