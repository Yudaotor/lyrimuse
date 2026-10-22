import Foundation

/// 「临时展开灵动岛」快捷键:灵动岛撑开几秒,看一眼当前这一句和进度,再按一下提前收回。各灵动岛实例(含「所有屏幕」的副本)
/// 订阅 `isPeeking` 自己撑开;这里不碰控制器单例(`NotchLyricsWindowController.shared` 一引用就建窗口)。
@MainActor
final class NotchPeekCenter: ObservableObject {
    static let shared = NotchPeekCenter()
    static let duration: TimeInterval = 4

    @Published private(set) var isPeeking = false

    private var endTask: Task<Void, Never>?

    private init() {}

    /// 没撑着就撑开 `duration` 秒,撑着就收回。
    func toggle() {
        endTask?.cancel()
        endTask = nil
        guard !isPeeking else {
            isPeeking = false
            return
        }
        isPeeking = true
        endTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isPeeking = false
        }
    }
}
