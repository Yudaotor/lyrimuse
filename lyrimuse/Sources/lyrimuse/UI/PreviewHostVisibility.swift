import AppKit
import SwiftUI

// 设置页里那几块预览(悬浮歌词 / 灵动岛 / 歌词窗口)跑的都是真视图,逐字填色、音浪、进度条
// 各有一张按帧刷新的 TimelineView。它们原本只按"在不在播放"停表,而 SwiftUI 不会替被遮住 /
// 最小化 / 在别的桌面上的窗口停 TimelineView(离屏探针实测不可见时仍是 ~63 次/秒,见
// LyricsWindowController 里 occlusionState 那段)—— 设置窗口停在「歌词显示」页、被别的窗口
// 盖住时,预览就一直在白画。真窗口各自按自己的 occlusionState 停表,预览没有自己的窗口,
// 所以由宿主把设置窗口的可见性推下来。

private struct PreviewHostVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 设置窗口此刻看不看得见。两类读者:嵌在设置页里的预览(看不见就停表),以及设置页各处的定时
    /// 刷新(`settingsPolling`、「关于」页背景动画、歌词库 / 账号页的轮询,看不见就停)。默认 true ——
    /// 真窗口里的同一份视图读到的永远是 true,停不停表照旧由它们自己的可见性信号管。
    var previewHostVisible: Bool {
        get { self[PreviewHostVisibleKey.self] }
        set { self[PreviewHostVisibleKey.self] = newValue }
    }
}

/// 设置窗口的可见性,按 occlusionState 算(遮挡、最小化、切到别的桌面都会让它失去 .visible)。
/// 由 `SettingsWindowConfigurator` 拿到窗口后接上。
@MainActor
final class SettingsWindowSurface: ObservableObject {
    @Published private(set) var isVisible = true
    private var observer: NSObjectProtocol?

    func attach(_ window: NSWindow) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        // 接上时窗口可能还没 orderFront(此时 occlusionState 也是"不可见"),先按可见算,
        // 首次显示后系统会补一次通知。同 LyricsWindowController.attach。
        isVisible = window.isVisible ? window.occlusionState.contains(.visible) : true
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let win = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                let visible = win.occlusionState.contains(.visible)
                if self?.isVisible != visible { self?.isVisible = visible }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
