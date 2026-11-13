import Darwin
import Foundation

/// 「播放器在放、却识别不到」时分清是播放器自己没往系统 Now Playing 报会话,还是读取这一侧出了问题。只读、只出诊断,
/// 不改识别:诊断包里给每个要查的播放器列进程在不在跑、在不在出声、按 bundle id 单问到什么(`reportLines`);运行时没有任何
/// App 在报、要查的播放器却在出声时,由 `LocalPlaybackSource` 按 `UnreportedOutputThrottle` 记一行日志。见 02 章决策 255。
/// 自己设置里有开关能让它不报的那几个(`reportingSwitchCauses`),这样持续 `ReportingSwitchHintTimer.hintAfterSeconds`
/// 就发 `reportingSwitchHintNotification`,App 提示一次去看那个开关。见 02 章决策 259。
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
            if let verdict = verdict(output: state, answers: answers) {
                lines.append("    => \(verdict)")
                if verdict == unreportedVerdict {
                    for (id, pid) in zip(ids, pids) where pid != nil {
                        if let cause = reportingSwitchCauses[id] { lines.append("    possible cause (\(id)): \(cause)") }
                    }
                }
            }
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
        let titles = answers.compactMap { answer -> Bool? in
            if case let .reporting(_, hasTitle, _, _) = answer { return hasTitle } else { return nil }
        }
        if titles.contains(true) { return "reporting to Now Playing" }
        // 标题空的会话主链路按没在报处理(`decodeSnapshot`)。
        if !titles.isEmpty { return "registered with Now Playing but no track title" }
        if output == .outputting, !answers.isEmpty, answers.allSatisfy({ $0 == .notReporting }) {
            return unreportedVerdict
        }
        return nil
    }

    static let unreportedVerdict = "producing audio but not reporting Now Playing"

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

    /// 此刻在出声的进程的 bundle id,读真实的 CoreAudio 进程对象(几微秒、不起子进程)。读不到为空。
    public static func outputtingBundleIDs() -> Set<String> {
        Set((ProcessAudioOutput.processOutputTable() ?? []).filter(\.outputting).map(\.bundleID))
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

    // MARK: - 播放器自己的开关让它不报

    /// 自己设置里有开关、开关在某一档时不往系统 Now Playing 报会话的那几个(按实际出声的 bundle id,不折成本体),值是诊断包里
    /// 写的可能原因。QQ 音乐 Mac 版取消「启用媒体键/远程控制事件」后不给系统媒体指令挂处理程序,只写播放信息不挂指令的程序
    /// 不进系统的会话列表,按 bundle id 单问也问不到;iPad 版 QQ 音乐、iPad 版网易云开了「允许同时播放」一类开关后不报。
    /// 只认这几个:别的播放器在出声却没报时没有能指给用户的开关。
    public static let reportingSwitchCauses: [String: String] = [
        "com.tencent.QQMusicMac": "QQ Music setting 启用媒体键/远程控制事件 (media keys / remote control events) unchecked",
        QQIPadNowPlaying.bundleID: "QQ Music (iPad) setting 允许多应用同时播放 (play alongside other apps) turned on",
        NetEaseIPadNowPlaying.bundleID: "NetEase Cloud Music (iPad) setting 允许与其他应用同时播放 (play alongside other apps) turned on",
    ]

    /// 这一拍在出声却没报的播放器里,实际出声的、有那种开关的 bundle id,按字母序。`unreported` 是 `outputtingPlayers` 交回的,
    /// `outputting` 是在出声的 bundle id。纯函数,selftest 覆盖。
    public static func reportingSwitchCandidates(unreported: [(name: String, bundleID: String)],
                                                 outputting: Set<String>) -> [String] {
        unreported.flatMap { PlayerBundleAliases.all(for: $0.bundleID) }
            .filter { outputting.contains($0) && reportingSwitchCauses[$0] != nil }
            .sorted()
    }

    /// App 跨段、跨启动的去重:同一个 bundle id 在同一个播放器版本上只提示一次,播放器更新后再提示一次。MV、付费弹窗挡着
    /// 这类误报每个版本也最多一次。`hinted` 是提示过的 bundle id → 当时的版本。纯函数,selftest 覆盖。
    public static func shouldHintReportingSwitch(bundleID: String, version: String, hinted: [String: String]) -> Bool {
        hinted[bundleID] != version
    }

    /// `LocalPlaybackSource` 该提示时发的进程内通知,`userInfo[reportingSwitchBundleIDKey]` 是实际出声的 bundle id。
    public static let reportingSwitchHintNotification = Notification.Name("lyrimuse.playerReporting.switchHint")
    public static let reportingSwitchBundleIDKey = "bundleID"

    /// 在出声却没报持续多久才提示:开播、换歌那一两拍也会没人报,MV、付费弹窗挡着时同样在出声不报,一拍就提示误报太多。
    /// 每一段只交一次,离开后再进来从头算;跨段、跨启动的去重归 App 那边。纯值类型,selftest 覆盖。
    public struct ReportingSwitchHintTimer: Sendable {
        public static let hintAfterSeconds: TimeInterval = 15
        private var since: [String: Date] = [:]
        private var hinted: Set<String> = []

        public init() {}

        /// 这一拍该提示的 bundle id。不在 `current` 里的忘掉。
        public mutating func due(_ current: [String], now: Date) -> [String] {
            since = since.filter { current.contains($0.key) }
            hinted.formIntersection(current)
            var due: [String] = []
            for id in current {
                let start = since[id] ?? now
                since[id] = start
                if now.timeIntervalSince(start) >= Self.hintAfterSeconds, hinted.insert(id).inserted { due.append(id) }
            }
            return due
        }
    }
}
