import AppKit
import SwiftUI
import LyrimuseCore

@MainActor
final class LyricsPictureInPictureController: NSObject, NSWindowDelegate {
    static let shared = LyricsPictureInPictureController()
    private(set) var window: LyricsPictureInPictureWindow?
    private let defaults: UserDefaults
    private let makeContent: @MainActor (LyricsPictureInPictureController) -> NSView
    private let restoreLyricsWindow: @MainActor () -> Void
    private var screenObserver: NSObjectProtocol?
    private static let frameKey = "np:lyricsPictureInPictureFrame"
    private static let screenKey = "np:lyricsPictureInPictureScreenID"

    init(defaults: UserDefaults = .standard,
         restoreLyricsWindow: @escaping @MainActor () -> Void = { AppActions.shared.openLyricsWindow?() },
         makeContent: @escaping @MainActor (LyricsPictureInPictureController) -> NSView = { controller in
             NSHostingView(rootView: LyricsWindowView(pictureInPicture: true, pipController: controller))
         }) {
        self.defaults = defaults
        self.makeContent = makeContent
        self.restoreLyricsWindow = restoreLyricsWindow
        super.init()
    }

    func show(replacing sourceWindow: NSWindow? = nil, on preferredScreen: NSScreen? = nil) {
        if let window {
            window.orderFrontRegardless()
            if sourceWindow !== window { sourceWindow?.close() }
            return
        }
        guard let screen = preferredScreen ?? sourceWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = LyricsPictureInPictureWindow(contentRect: restoredFrame(on: screen))
        panel.title = L10n.t("歌词画中画")
        panel.delegate = self
        panel.contentView = makeContent(self)
        window = panel
        // PiP itself does not activate the app. Closing a fullscreen source can
        // leave its Space; AppKit owns that transition.
        panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreen() }
        }
        // Close only after PiP is ready. The source's normal close path preserves
        // its geometry and removes it from window menus and visibility tracking.
        sourceWindow?.close()
    }

    func close() { window?.close() }

    func returnToLyricsWindow() {
        close()
        restoreLyricsWindow()
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        // Release the SwiftUI tree and its playback subscriptions when PiP closes.
        window?.contentView = nil
        window = nil
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window, let screen = window.screen else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
        defaults.set(ScreenIdentity.id(of: screen), forKey: Self.screenKey)
    }

    private func restoredFrame(on fallback: NSScreen) -> NSRect {
        if let raw = defaults.string(forKey: Self.frameKey),
           let id = defaults.string(forKey: Self.screenKey),
           let screen = ScreenIdentity.screen(withID: id) {
            let saved = NSRectFromString(raw)
            let size = WindowFrameFit.miniSize(saved: saved.size,
                defaultSize: LyricsPictureInPictureWindow.defaultSize,
                minimum: LyricsPictureInPictureWindow.minimumSize, visible: screen.visibleFrame.size)
            return WindowFrameFit.clamp(NSRect(origin: saved.origin, size: size), into: screen.visibleFrame)
        }
        let size = LyricsPictureInPictureWindow.defaultSize
        let frame = NSRect(x: fallback.visibleFrame.maxX - size.width - 24,
                           y: fallback.visibleFrame.minY + 24, width: size.width, height: size.height)
        return WindowFrameFit.clamp(frame, into: fallback.visibleFrame)
    }

    private func fitToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(WindowFrameFit.clamp(window.frame, into: screen.visibleFrame), display: true)
        saveFrame()
    }
}

/// Only the header drags the panel. A drag recognizer over the lyrics would swallow
/// row clicks, scroll gestures and text interaction.
struct LyricsPictureInPictureDragHandle: NSViewRepresentable {
    final class Handle: NSView {
        private var dragStart: (cursor: NSPoint, origin: NSPoint)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let start = dragStart else { return }
            let cursor = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(x: start.origin.x + cursor.x - start.cursor.x,
                                          y: start.origin.y + cursor.y - start.cursor.y))
        }
        override func mouseUp(with event: NSEvent) {
            dragStart = nil
            guard let window, let screen = window.screen else { return }
            window.setFrame(WindowFrameFit.clamp(window.frame, into: screen.visibleFrame), display: true)
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {}
}
