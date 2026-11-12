import Darwin
import Foundation

/// 「播放器在放、却识别不到」时分清是播放器自己没往系统 Now Playing 报会话,还是读取这一侧出了问题。只读、只出诊断,
/// 不改识别:诊断包里给每个要查的播放器列进程在不在跑、在不在出声、按 bundle id 单问到什么(`reportLines`);运行时没有任何
/// App 在报、要查的播放器却在出声时,由 `LocalPlaybackSource` 按 `UnreportedOutputThrottle` 记一行日志。见 02 章决策 255。
public enum PlayerReportingDiagnostics {
    /// 要查的播放器:勾选的内置播放器;勾了自动识别时另加全部内置播放器里 `isRunning` 为真的。同一个 bundle id 只留一个,
    /// 按 rawValue 排。纯函数,selftest 覆盖。
    public static func watchedPlayers(selected: Set<PlaybackPlayer>, isRunning: (PlaybackPlayer) -> Bool) -> [PlaybackPlayer] {
        var seen: Set<String> = []
        let explicit = selected.filter { $0 != .auto && !$0.bundleIdentifier.isEmpty }
        let autoExtra = selected.contains(.auto)
            ? PlaybackPlayer.allCases.filter { $0 != .auto && !$0.bundleIdentifier.isEmpty && !explicit.contains($0) && isRunning($0) }
            : []
        return (Array(explicit) + autoExtra).sorted { $0.rawValue < $1.rawValue }.filter {
            seen.insert(PlayerBundleAliases.canonical($0.bundleIdentifier)).inserted
        }
    }

    /// 诊断包里这一段的全部行。`pid` 只认给定的那一个 bundle id,`output` 给同一个播放器的全部 bundle id,`ask` 按 bundle id
    /// 单问(第二个参数是要不要按速率判在不在放)。哪个版本都没在跑的播放器只记一行、不单问。纯函数,selftest 覆盖。
    public static func reportLines(
        selected: Set<PlaybackPlayer>, lastFailure: String?,
        pid: (String) -> pid_t?, output: ([String]) -> ProcessAudioOutput.OutputState,
        ask: (String, Bool) -> NowPlayingClientsProbe.DiagnosticAnswer
    ) -> [String] {
        var lines = ["== Now Playing reporting (selected players) =="]
        lines.append("Last snapshot failure: \(lastFailure ?? "none")")
        let players = watchedPlayers(selected: selected) { player in
            PlayerBundleAliases.all(for: player.bundleIdentifier).contains { pid($0) != nil }
        }
        if selected.contains(.auto) { lines.append("Auto-detect is on: running built-in players are listed too") }
        if players.isEmpty { lines.append("(no selected or running built-in player)") }
        for player in players {
            let ids = PlayerBundleAliases.all(for: player.bundleIdentifier)
            let pids = ids.map(pid)
            guard pids.contains(where: { $0 != nil }) else {
                lines.append("- \(player.rawValue): not running")
                continue
            }
            let state = output(ids)
            lines.append("- \(player.rawValue): audio output \(describe(state))")
            var answers: [NowPlayingClientsProbe.DiagnosticAnswer] = []
            for (id, pid) in zip(ids, pids) {
                let running = pid.map { "running (pid \($0))" } ?? "not running"
                let answer = ask(id, player.playingFromRate)
                answers.append(answer)
                lines.append("    \(id): \(running) | Now Playing asked by bundle id: \(describe(answer))")
            }
            if let verdict = verdict(output: state, answers: answers) { lines.append("    => \(verdict)") }
        }
        return lines
    }

    /// 用真实的进程表、CoreAudio 和 helper 生成 `reportLines`。会起子进程、阻塞几百毫秒,别在主线程上调。
    public static func reportLines(selected: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected,
                                   lastFailure: String? = MediaControlClient.lastSnapshotFailure?.rawValue) -> [String] {
        let table = ProcessAudioOutput.processOutputTable()
        return reportLines(
            selected: selected, lastFailure: lastFailure, pid: { PlayerProcess.pid(exactBundleID: $0) },
            output: { ProcessAudioOutput.outputState(bundleIDs: $0, table: table) },
            ask: { NowPlayingClientsProbe.diagnosticAnswer(forBundleID: $0, ratePlaying: $1) })
    }

    /// 一个播放器的结论;说不出结论为 nil。纯函数,selftest 覆盖。
    public static func verdict(output: ProcessAudioOutput.OutputState,
                               answers: [NowPlayingClientsProbe.DiagnosticAnswer]) -> String? {
        if answers.contains(where: { if case .reporting = $0 { return true } else { return false } }) {
            return "reporting to Now Playing"
        }
        if output == .outputting, !answers.isEmpty, answers.allSatisfy({ $0 == .notReporting }) {
            return "producing audio but not reporting Now Playing"
        }
        return nil
    }

    static func describe(_ state: ProcessAudioOutput.OutputState) -> String {
        switch state {
        case .outputting: return "outputting"
        case .silent: return "silent"
        case .noAudioObject: return "no audio object (has not opened audio)"
        case .unavailable: return "unavailable (CoreAudio process objects not readable)"
        }
    }

    static func describe(_ answer: NowPlayingClientsProbe.DiagnosticAnswer) -> String {
        switch answer {
        case .helperMissing: return "helper not bundled"
        case .failed: return "query failed or timed out"
        case .notReporting: return "not reporting"
        case .undecodable: return "unreadable answer"
        case let .reporting(playing, hasTitle, duration, elapsed):
            func seconds(_ value: Double?) -> String { value.map { String(format: "%.1fs", $0) } ?? "none" }
            return "reporting playing=\(playing.map(String.init) ?? "unknown") title=\(hasTitle ? "present" : "empty")"
                + " duration=\(seconds(duration)) elapsed=\(seconds(elapsed))"
        }
    }

    // MARK: - 运行时日志

    /// 要查的播放器里此刻在出声的,交回 rawValue 与本体 bundle id,按 rawValue 排。`outputting` 是在输出的 bundle id。
    /// 纯函数,selftest 覆盖。
    public static func outputtingPlayers(selected: Set<PlaybackPlayer>,
                                         outputting: Set<String>) -> [(name: String, bundleID: String)] {
        guard !outputting.isEmpty else { return [] }
        let candidates = selected.contains(.auto) ? Set(PlaybackPlayer.allCases) : selected
        return watchedPlayers(selected: candidates.subtracting([.auto])) { _ in false }
            .filter { PlayerBundleAliases.all(for: $0.bundleIdentifier).contains(where: outputting.contains) }
            .map { ($0.rawValue, PlayerBundleAliases.canonical($0.bundleIdentifier)) }
    }

    /// 同上,读真实的 CoreAudio 进程对象(几微秒、不起子进程)。读不到为空。
    public static func outputtingPlayers(selected: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected)
        -> [(name: String, bundleID: String)] {
        let outputting = Set((ProcessAudioOutput.processOutputTable() ?? []).filter(\.outputting).map(\.bundleID))
        return outputtingPlayers(selected: selected, outputting: outputting)
    }

    /// 「在出声但没报 Now Playing」那行日志的节流:一个播放器进入这个状态时记一次,一直这样每 `repeatSeconds` 再记一次;
    /// 离开后再进来重新算。纯值类型,selftest 覆盖。
    public struct UnreportedOutputThrottle: Sendable {
        public static let repeatSeconds: TimeInterval = 300
        private var lastLogged: [String: Date] = [:]

        public init() {}

        /// 这一拍处在这个状态的播放器(bundle id)里该记日志的那几个。不在 `current` 里的忘掉。
        public mutating func due(_ current: [String], now: Date) -> [String] {
            lastLogged = lastLogged.filter { current.contains($0.key) }
            let due = current.filter { id in
                lastLogged[id].map { now.timeIntervalSince($0) >= Self.repeatSeconds } ?? true
            }
            for id in due { lastLogged[id] = now }
            return due
        }
    }
}
