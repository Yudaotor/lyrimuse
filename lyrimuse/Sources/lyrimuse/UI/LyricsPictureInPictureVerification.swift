#if DEBUG
import AppKit
import SwiftUI

/// Runs before the real App/Delegate is constructed. UI and windowing are real;
/// playback and seek delivery use a deterministic fixture, not a live music app.
@MainActor
enum LyricsPictureInPictureVerification {
    private static var controller: LyricsPictureInPictureController?
    private static var source: NSWindow?
    private static var logURL: URL?

    /// Geometric artwork keeps visual tests independent of network and user music.
    static let artworkFixture = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
        NSColor.systemTeal.setFill()
        rect.fill()
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: 350, y: 370, width: 150, height: 150)).fill()
        NSColor.systemIndigo.setFill()
        let mountain = NSBezierPath()
        mountain.move(to: .zero)
        mountain.line(to: NSPoint(x: 190, y: 420))
        mountain.line(to: NSPoint(x: 420, y: 0))
        mountain.close()
        mountain.fill()
        NSColor.systemMint.setFill()
        let foreground = NSBezierPath()
        foreground.move(to: NSPoint(x: 180, y: 0))
        foreground.line(to: NSPoint(x: 460, y: 300))
        foreground.line(to: NSPoint(x: 600, y: 100))
        foreground.line(to: NSPoint(x: 600, y: 0))
        foreground.close()
        foreground.fill()
        return true
    }

    static func record(_ message: String) {
        if CommandLine.arguments.contains("--verify-lyrics-pip-layout")
            || CommandLine.arguments.contains("--verify-lyrics-pip-handoff") { print(message) }
        guard let logURL, let data = (message + "\n").data(using: .utf8) else { return }
        if let file = try? FileHandle(forWritingTo: logURL) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    static func run() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--verification-log"), i + 1 < args.count {
            logURL = URL(fileURLWithPath: args[i + 1])
        } else if let path = Bundle.main.object(forInfoDictionaryKey: "LyricsPiPVerificationLog") as? String {
            logURL = URL(fileURLWithPath: path)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if args.contains("--verify-lyrics-pip-layout") {
            exit(LyricsWindowView.verifyPictureInPictureTypography() ? 0 : 1)
        }
        if args.contains("--verify-lyrics-pip-handoff") {
            exit(verifyWindowHandoff() ? 0 : 1)
        }
        let suite = "me.yudaotor.lyrimuse.pip-verification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 620),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        host.title = "Lyrics Window — Verification"
        host.isReleasedWhenClosed = false
        source = host
        let pip = LyricsPictureInPictureController(defaults: defaults,
            restoreLyricsWindow: {
                host.makeKeyAndOrderFront(nil)
                record("PASS: returned to the original lyrics window")
            }, makeContent: { controller in
                NSHostingView(rootView: LyricsWindowView.verificationView(
                    pictureInPicture: true, controller: controller, onSeek: { ms in
                        record("SEEK positionMs=\(ms)")
                    }))
            })
        controller = pip
        host.contentView = NSHostingView(rootView: LyricsWindowView.verificationView(
            pictureInPicture: false, controller: pip, onSeek: { ms in record("SOURCE SEEK positionMs=\(ms)") }))
        host.orderFrontRegardless()

        let menu = NSMenu()
        let item = NSMenuItem(title: "Verification", action: nil, keyEquivalent: "")
        let actions = NSMenu()
        for (title, selector) in [("Track 2", #selector(Commands.track2)),
                                  ("No Lyrics", #selector(Commands.noLyrics)),
                                  ("Track 1", #selector(Commands.track1)),
                                  ("Long CJK", #selector(Commands.longCJK)),
                                  ("Long English", #selector(Commands.longEnglish)),
                                  ("Long Karaoke", #selector(Commands.longKaraoke)),
                                  ("Long Token", #selector(Commands.longToken)),
                                  ("Artwork", #selector(Commands.artwork)),
                                  ("Long Metadata", #selector(Commands.longMetadata)),
                                  ("Artist Only", #selector(Commands.artistOnly)),
                                  ("Album Only", #selector(Commands.albumOnly)),
                                  ("No Metadata", #selector(Commands.noMetadata)),
                                  ("Advertisement", #selector(Commands.advertisement)),
                                  ("Minimum Size", #selector(Commands.minimumSize)),
                                  ("Default Size", #selector(Commands.defaultSize)),
                                  ("Capture PiP", #selector(Commands.capture)),
                                  ("Close Source", #selector(Commands.closeSource)),
                                  ("Quit Verification", #selector(Commands.quit))] {
            let action = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            action.target = Commands.shared
            actions.addItem(action)
        }
        item.submenu = actions
        menu.addItem(item)
        app.mainMenu = menu
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            _ = LyricsWindowView.verifyPictureInPictureTypography()
            let initial = host.frame
            pip.show(replacing: host)
            let first = pip.window
            pip.show(replacing: host)
            record(pip.window === first ? "PASS: repeated PiP open reuses the panel" : "FAIL: duplicate PiP")
            record(host.frame == initial ? "PASS: opening PiP preserves the source frame" : "FAIL: source frame changed")
            record(!host.isVisible ? "PASS: entering PiP closes the source window" : "FAIL: source remains visible")
            if let first {
                let original = first.frame
                var resized = original
                resized.size = NSSize(width: 380, height: 460)
                first.setFrame(resized, display: true)
                pip.close()
                record(pip.window == nil && first.contentView == nil
                    ? "PASS: closing PiP detaches its view and clears the window"
                    : "FAIL: closed PiP retained its view")
                pip.show(on: host.screen)
                record(pip.window?.frame == resized
                    ? "PASS: reopening restores the PiP frame independently"
                    : "FAIL: PiP frame did not restore")
                pip.window?.setFrame(original, display: true)
            }
            record("READY pid=\(getpid()) panel=\(pip.window?.windowNumber ?? -1) lines=18 offsetMs=1500")
        }
        app.run()
        pip.close()
        defaults.removePersistentDomain(forName: suite)
    }

    /// Real AppKit windows and the production controller; only content and the
    /// scene-opening action are substituted. The UI entry point is checked separately.
    private static func verifyWindowHandoff() -> Bool {
        var failures = 0
        func expect(_ value: Bool, _ message: String) {
            record("\(value ? "PASS" : "FAIL"): \(message)")
            if !value { failures += 1 }
        }
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 620),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            return window
        }
        let source = makeWindow(), unrelated = makeWindow()
        let initial = source.frame
        let suite = "me.yudaotor.lyrimuse.pip-handoff.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var restores = 0
        let pip = LyricsPictureInPictureController(defaults: defaults,
            restoreLyricsWindow: { restores += 1; source.makeKeyAndOrderFront(nil) },
            makeContent: { _ in NSView() })
        defer {
            pip.close()
            source.close()
            unrelated.close()
            defaults.removePersistentDomain(forName: suite)
        }
        expect(source.isVisible && unrelated.isVisible, "source and unrelated window start visible")
        pip.show(replacing: source)
        let first = pip.window
        expect(first?.isVisible == true, "entering PiP opens a visible panel")
        expect(!source.isVisible && !source.isMiniaturized, "entering PiP closes rather than minimizes the source")
        expect(source.frame == initial, "entering PiP preserves source geometry")
        expect(unrelated.isVisible, "entering PiP leaves unrelated windows open")
        expect(restores == 0, "entering PiP does not request source restoration")
        source.orderFrontRegardless()
        pip.show(replacing: source)
        expect(pip.window === first, "repeated entry reuses the existing PiP")
        expect(!source.isVisible, "repeated entry also closes a reopened source")
        pip.returnToLyricsWindow()
        expect(pip.window == nil && first?.contentView == nil, "restore closes PiP and releases its content")
        expect(source.isVisible && restores == 1, "restore reopens the source exactly once")
        expect(source.frame == initial, "restored source retains its geometry")
        pip.show(replacing: source)
        pip.close()
        expect(pip.window == nil && !source.isVisible, "closing PiP leaves both lyrics windows closed")
        expect(restores == 1, "closing PiP does not reopen the source")
        expect(unrelated.isVisible, "closing PiP leaves unrelated windows open")
        return failures == 0
    }

    @MainActor
    private final class Commands: NSObject {
        static let shared = Commands()
        @objc func track2() { LyricsWindowView.setVerificationTrack(2); record("TRACK 2") }
        @objc func noLyrics() { LyricsWindowView.setVerificationTrack(0); record("TRACK 0") }
        @objc func track1() { LyricsWindowView.setVerificationTrack(1); record("TRACK 1") }
        @objc func longCJK() { LyricsWindowView.setVerificationTrack(3); record("TRACK 3 long CJK") }
        @objc func longEnglish() { LyricsWindowView.setVerificationTrack(4); record("TRACK 4 long English") }
        @objc func longKaraoke() { LyricsWindowView.setVerificationTrack(5); record("TRACK 5 long karaoke") }
        @objc func longToken() { LyricsWindowView.setVerificationTrack(6); record("TRACK 6 long token") }
        @objc func artwork() { LyricsWindowView.setVerificationTrack(7); record("TRACK 7 artwork") }
        @objc func longMetadata() {
            LyricsWindowView.setVerificationMetadata(
                artist: String(repeating: "とても長いアーティスト名", count: 8),
                album: String(repeating: "A very long album title ", count: 8))
        }
        @objc func artistOnly() { LyricsWindowView.setVerificationMetadata(artist: "Local fixture", album: "") }
        @objc func albumOnly() { LyricsWindowView.setVerificationMetadata(artist: "", album: "Interactive lyrics") }
        @objc func noMetadata() { LyricsWindowView.setVerificationMetadata(artist: "", album: "") }
        @objc func advertisement() {
            LyricsWindowView.setVerificationMetadata(artist: "Advertiser", album: "Campaign", adBreak: true)
        }
        @objc func minimumSize() { controller?.window?.setContentSize(LyricsPictureInPictureWindow.minimumSize) }
        @objc func defaultSize() { controller?.window?.setContentSize(LyricsPictureInPictureWindow.defaultSize) }
        @objc func capture() {
            guard let panel = controller?.window, let view = panel.contentView, let logURL,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = logURL.deletingLastPathComponent().appendingPathComponent("pip-preview.png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            record("CAPTURE frame=\(panel.frame) screen=\(String(describing: panel.screen?.visibleFrame))")
            let point = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
            record("POINTER inside=\(view.bounds.contains(point)) position=\(point)")
            func recordDragRegion(_ child: NSView) {
                if child is LyricsPictureInPictureDragHandle.Handle {
                    record("HEADER bounds=\(child.bounds) windowRect=\(child.convert(child.bounds, to: nil))")
                }
                child.subviews.forEach(recordDragRegion)
            }
            recordDragRegion(view)
        }
        @objc func closeSource() { source?.close(); record("SOURCE CLOSED") }
        @objc func quit() { controller?.close(); NSApp.stop(nil) }
    }
}
#endif
