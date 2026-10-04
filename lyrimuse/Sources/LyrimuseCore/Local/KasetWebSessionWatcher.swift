import Foundation
import OSLog

/// 常驻盯着 Kaset 内嵌网页那份系统会话(WebKit 媒体进程替它报的那份,见 `KasetPlayerInfo.webMedia`)在不在放。Kaset 不发
/// 分布式通知,系统里它自己那份会话又常停在旧状态,暂停、恢复只能等轮询(播放档 2 秒、暂停档 6 秒)发现。
///
/// helper(`nowplaying-clients` 的 watch 模式)常驻,在自己进程里问(在放时每 0.25 秒、没在放时每 0.5 秒一次)、变了才输出
/// 一行(开销见 02 章决策 88)。这里只把「在不在放」的变化翻成信号交出去,跟别的事件一样只当「提前 poll 一次」
/// (`LocalPlaybackSource.handlePlayerInfoChanged`),一个数值都不拿去喂状态。只在 Kaset 是当前播放器时开着;helper
/// 按 bundle id 自己认进程号,发现父进程没了自己退出。
@MainActor
public final class KasetWebSessionWatcher {
    /// 一行报的那份会话:没有这份会话、在、不在放。
    public enum SessionState: Equatable, Sendable { case absent, paused, playing }

    /// 交出去的信号:`paused` = 在放 → 没在放(暂停或这一首放完,外推该冻住);`changed` = 别的值得马上 poll 一次的变化
    /// (开始放、在放的会话没了)。
    public enum Signal: Equatable, Sendable { case paused, changed }

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "kaset-web-watch")
    /// 退避重启的上下限:helper 起不来时别每秒重起一个。
    private static let minRestartDelay: TimeInterval = 1
    private static let maxRestartDelay: TimeInterval = 30
    /// 活过这么久才退出的,不算起不来,退避复位。
    private static let stableRunSeconds: TimeInterval = 10

    private let onSignal: @MainActor (Signal) -> Void
    private var process: Process?
    private var watchedBundleID: String?
    private var launchedAt: Date?
    private var restartWork: DispatchWorkItem?
    private var restartDelay = KasetWebSessionWatcher.minRestartDelay
    /// 按行切分用的残留缓冲:一行可能跨两次回调。
    private var buffer = Data()
    /// 上一行报的状态;nil = 这个 helper 还没输出过。
    private var lastState: SessionState?
    private var terminateObserver: NSObjectProtocol?

    public init(onSignal: @escaping @MainActor (Signal) -> Void) {
        self.onSignal = onSignal
    }

    /// 盯 bundle id 是这个的 App(进程号由 helper 现找,App 主线程上 NSRunningApplication 常查不到,见 02 章决策 88);
    /// nil = 不盯了。已经在盯同一个时什么都不做。
    public func watch(bundleID: String?) {
        guard bundleID != watchedBundleID else { return }
        stopWatching()
        guard let bundleID else { return }
        watchedBundleID = bundleID
        if terminateObserver == nil {
            // 正常退出时把 helper 一起带走。LyrimuseCore 不引 AppKit,按通知名字取。
            terminateObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.watch(bundleID: nil) }
            }
        }
        launch()
    }

    private func stopWatching() {
        if watchedBundleID != nil { Self.logger.notice("kaset web session watch stopped") }
        watchedBundleID = nil
        restartWork?.cancel()
        restartWork = nil
        restartDelay = Self.minRestartDelay
        teardownProcess()
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
    }

    private func teardownProcess() {
        guard let process else { return }
        self.process = nil
        // 先摘掉两个回调再终止,不然终止本身会被当成意外退出、又拉起来。
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        buffer.removeAll()
        lastState = nil
    }

    private func launch() {
        guard let bundleID = watchedBundleID, process == nil else { return }
        guard let paths = NowPlayingClientsProbe.helperPaths() else {
            Self.logger.notice("nowplaying-clients helper unavailable; Kaset pauses wait for the poll")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // 第三个参数是 bundle id 那一格,watch 模式不按 bundle id 挑,留空。
        proc.arguments = [paths.script, paths.library, "", "watch=\(bundleID)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // EOF:摘掉自己再交给 terminationHandler,留着的话会拿空数据一直回调。
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.consume(chunk) }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTermination() }
        }
        do {
            try proc.run()
            process = proc
            launchedAt = Date()
            Self.logger.notice("kaset web session watch started (pid \(proc.processIdentifier))")
        } catch {
            Self.logger.error("failed to start kaset web session watch: \(error.localizedDescription, privacy: .public)")
            scheduleRestart()
        }
    }

    private func consume(_ chunk: Data) {
        guard process != nil else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let state = Self.state(fromLine: line) else { continue }
            let signal = Self.signal(from: lastState, to: state)
            lastState = state
            guard let signal else { continue }
            Self.logger.notice("kaset web session \(String(describing: state), privacy: .public); polling now")
            onSignal(signal)
        }
    }

    private func handleTermination() {
        guard process != nil else { return }
        let ranFor = launchedAt.map { Date().timeIntervalSince($0) } ?? 0
        teardownProcess()
        if ranFor >= Self.stableRunSeconds { restartDelay = Self.minRestartDelay }
        Self.logger.notice("kaset web session watch exited after \(ranFor, format: .fixed(precision: 1))s; restarting in \(self.restartDelay, format: .fixed(precision: 0))s")
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard watchedBundleID != nil else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, Self.maxRestartDelay)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.restartWork = nil
                self?.launch()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// helper 输出的一行:`null` 是没有这份会话;解析不出返回 nil(这一行不算)。纯函数,selftest 覆盖。
    public nonisolated static func state(fromLine line: Data) -> SessionState? {
        if String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces) == "null" { return .absent }
        guard let session = try? JSONDecoder().decode(NowPlayingClientsProbe.ClientSession.self, from: line) else { return nil }
        return session.playing == true ? .playing : .paused
    }

    /// 上一行到这一行交出什么信号:在放 → 没在放交 `paused`;变成在放、在放的会话没了交 `changed`;helper 输出的头一行、
    /// 没在放 ↔ 没有会话不交。纯函数,selftest 覆盖。
    public nonisolated static func signal(from previous: SessionState?, to current: SessionState) -> Signal? {
        switch (previous, current) {
        case (.playing?, .paused): return .paused
        case (.playing?, .absent), (.paused?, .playing), (.absent?, .playing): return .changed
        default: return nil
        }
    }
}
