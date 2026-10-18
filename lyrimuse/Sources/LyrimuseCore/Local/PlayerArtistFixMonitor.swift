import Combine
import Foundation

extension PlayerArtistFix {
    /// 纠正文件换了一版就在主线程发一次。盯配置目录的目录事件(引擎原子写会改名,目录项一变就叫醒),事件来了 stat
    /// 一次、修改时间变了才发;目录盯不了或被删了退回每 `PlayerArtistFixMonitor.fallbackInterval` 看一次。第一次取用时
    /// 开始盯。见 02 章决策 139。
    public static var changes: AnyPublisher<Void, Never> {
        PlayerArtistFixMonitor.shared.start()
        return PlayerArtistFixMonitor.shared.subject.eraseToAnyPublisher()
    }
}

/// 状态(watcher、定时器、上次看到的修改时间)只在 `queue` 上读写;`subject` 只在主线程发。
final class PlayerArtistFixMonitor: @unchecked Sendable {
    static let shared = PlayerArtistFixMonitor()
    static let fallbackInterval: TimeInterval = 5

    let subject = PassthroughSubject<Void, Never>()
    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.player-artist-fix", qos: .utility)
    private var watcher: DirectoryChangeWatcher?
    private var timer: DispatchSourceTimer?
    private var lastMTime: Date?
    private var started = false

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            lastMTime = Self.mtime()
            watcher = DirectoryChangeWatcher(directory: PlayerArtistFix.stateURL.deletingLastPathComponent(), queue: queue,
                                             onChange: { [weak self] in self?.check() },
                                             onGone: { [weak self] in self?.watcherGone() })
            if watcher == nil { startPolling() }
        }
    }

    private func watcherGone() {
        watcher = nil
        startPolling()
        check()
    }

    private func startPolling() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval = Self.fallbackInterval
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 200)))
        source.setEventHandler { [weak self] in self?.check() }
        source.resume()
        timer = source
    }

    private func check() {
        let mtime = Self.mtime()
        guard mtime != lastMTime else { return }
        lastMTime = mtime
        DispatchQueue.main.async { [subject] in subject.send(()) }
    }

    private static func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: PlayerArtistFix.stateURL.path))?[.modificationDate] as? Date
    }
}
