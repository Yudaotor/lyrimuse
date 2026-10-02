import AppKit
import LyrimuseCore

/// 歌词窗口的空格 / ← / → 三个按键,判据在 Core `LyricsWindowKeyCommand`。
///
/// 只在焦点在歌词窗口时接:按键发给的就是这扇窗、它是 key window,而且之后没在本 App 别的窗口里点过
/// (`LyricsWindowKeyCommand.Focus`)。按键和鼠标都走 App 级本地监听,鼠标只看不拦。
/// 动作跟窗口里那排播放按钮走同一条路:播放 / 暂停走 `userTogglePlayPause()`,切歌直接调
/// `MusicPlaybackController`,都不预检自动化权限。
@MainActor
final class LyricsWindowTransportKeys {
    private weak var window: NSWindow?
    private var focus = LyricsWindowKeyCommand.Focus()
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    nonisolated init() {}

    func install(on window: NSWindow) {
        self.window = window
        guard keyMonitor == nil else { return }
        focus = LyricsWindowKeyCommand.Focus(isFocused: window.isKeyWindow)
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focus.windowBecameKey() }
            },
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focus.windowResignedKey() }
            },
        ]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // 没有所属窗口的点击(菜单栏里的菜单)不改焦点:菜单收起后键盘照旧回到歌词窗口。
            if let target = event.window {
                MainActor.assumeIsolated { self?.noteMouseDown(in: target) }
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return consumed ? nil : event
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func noteMouseDown(in target: NSWindow) {
        focus.mouseDown(inLyricsWindow: target === window)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow, focus.isFocused,
              let command = LyricsWindowKeyCommand.command(
                  keyCode: event.keyCode,
                  hasModifiers: !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  isRepeat: event.isARepeat,
                  keyboardFocusElsewhere: Self.keyboardFocusElsewhere(in: window))
        else { return false }
        switch command {
        case .togglePlayPause: PlaybackCoordinator.shared.userTogglePlayPause()
        case .previousTrack: MusicPlaybackController.previousTrack()
        case .nextTrack: MusicPlaybackController.nextTrack()
        }
        return true
    }

    /// 输入框正在编辑(字段编辑器是 NSText)、焦点在某个控件上(滑块要自己吃方向键),或者开着全键盘操控、
    /// 焦点落在窗口本身以外的地方。
    private static func keyboardFocusElsewhere(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder, responder !== window, responder !== window.contentView else {
            return false
        }
        if responder is NSText || responder is NSControl { return true }
        return NSApp.isFullKeyboardAccessEnabled
    }
}
