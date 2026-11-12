import Foundation
import LyrimuseCore

// 诊断包「Now Playing reporting」一段和「在出声但没报 Now Playing」那行日志的判据。由 runOpsDiagnosticsTests 调用。
@MainActor
func playerReportingDiagnosticsChecks() {
    print("\n== 播放器报不报 Now Playing 的诊断 ==")
    let qq = PlaybackPlayer.qqMusic.bundleIdentifier
    let qqIPad = QQIPadNowPlaying.bundleID

    // ---- 出声三态 ----
    do {
        let ids = PlayerBundleAliases.all(for: qq)
        expectEqual(ProcessAudioOutput.outputState(bundleIDs: ids, table: nil), .unavailable, "出声: 进程对象表读不到")
        expectEqual(ProcessAudioOutput.outputState(bundleIDs: ids, table: [("com.other", true)]), .noAudioObject,
                    "出声: 表里没有这个播放器")
        expectEqual(ProcessAudioOutput.outputState(bundleIDs: ids, table: [(qq, false)]), .silent, "出声: 有进程对象、没在输出")
        expectEqual(ProcessAudioOutput.outputState(bundleIDs: ids, table: [(qq, false), (qqIPad, true)]), .outputting,
                    "出声: 别的版本在输出也算")
    }

    // ---- 诊断单问的输出 ----
    do {
        typealias P = NowPlayingClientsProbe
        expectEqual(P.decodeDiagnosticAnswer(Data("null\n".utf8)), .notReporting, "单问: null 是没在报")
        expectEqual(P.decodeDiagnosticAnswer(Data(#"{"title":"A","playing":true,"duration":200,"elapsedTime":12.5}"#.utf8)),
                    .reporting(playing: true, hasTitle: true, duration: 200, elapsed: 12.5), "单问: 在报")
        expectEqual(P.decodeDiagnosticAnswer(Data(#"{"title":"","playing":false}"#.utf8)),
                    .reporting(playing: false, hasTitle: false, duration: nil, elapsed: nil), "单问: 标题空的也照实交回")
        expectEqual(P.decodeDiagnosticAnswer(Data("oops".utf8)), .undecodable, "单问: 解不出来")
    }

    // ---- 要查哪几个播放器 ----
    do {
        typealias D = PlayerReportingDiagnostics
        expectEqual(D.watchedPlayers(selected: [.qqMusic]) { _ in true }, [.qqMusic], "要查: 只看勾选的")
        expectEqual(D.watchedPlayers(selected: [.auto]) { $0 == .spotify }, [.spotify], "要查: 自动识别时加上在跑的内置播放器")
        expectEqual(D.watchedPlayers(selected: [.auto, .qqMusic]) { $0 == .netease }, [.netease, .qqMusic],
                    "要查: 勾选的不在跑也列,按 rawValue 排")
    }

    // ---- 诊断包那一段 ----
    do {
        typealias D = PlayerReportingDiagnostics
        func lines(_ output: ProcessAudioOutput.OutputState, _ answer: NowPlayingClientsProbe.DiagnosticAnswer) -> [String] {
            D.reportLines(selected: [.qqMusic], lastFailure: "no app is reporting Now Playing",
                          pid: { $0 == qq ? 812 : nil }, output: { _ in output }, ask: { _, _ in answer })
        }
        let silentReporter = lines(.outputting, .notReporting)
        expectEqual(silentReporter.first, "== Now Playing reporting (selected players) ==", "报告: 段标题")
        expectEqual(silentReporter.contains("Last snapshot failure: no app is reporting Now Playing"), true, "报告: 最近一次失败原因")
        expectEqual(silentReporter.contains("- qq_music: audio output outputting"), true, "报告: 出声状态")
        expectEqual(silentReporter.contains("    \(qq): running (pid 812) | Now Playing asked by bundle id: not reporting"), true,
                    "报告: 本体在跑、单问没在报")
        expectEqual(silentReporter.contains("    \(qqIPad): not running | Now Playing asked by bundle id: not reporting"), true,
                    "报告: 别的版本各列一行")
        expectEqual(silentReporter.last, "    => producing audio but not reporting Now Playing", "报告: 在出声却没报")
        expectEqual(lines(.outputting, .helperMissing).contains { $0.contains("=>") }, false, "报告: helper 不在时不下结论")
        expectEqual(lines(.silent, .notReporting).contains { $0.contains("=>") }, false, "报告: 没出声、没报不下结论")
        expectEqual(lines(.silent, .reporting(playing: false, hasTitle: true, duration: nil, elapsed: nil)).last,
                    "    => reporting to Now Playing", "报告: 在报")
        expectEqual(lines(.silent, .reporting(playing: false, hasTitle: false, duration: nil, elapsed: nil)).last,
                    "    => registered with Now Playing but no track title", "报告: 有会话但标题空,主链路当没在报")
        var asked: [String] = []
        expectEqual(D.reportLines(selected: [.qqMusic], lastFailure: nil, pid: { _ in nil }, output: { _ in .outputting },
                                  ask: { id, _ in asked.append(id); return .notReporting }).last,
                    "- qq_music: not running", "报告: 哪个版本都没在跑只记一行")
        expectEqual(asked, [], "报告: 没在跑的不单问")
        expectEqual(Array(D.reportLines(selected: [.auto], lastFailure: nil, pid: { _ in nil }, output: { _ in .unavailable },
                                        ask: { _, _ in .notReporting }).suffix(2)),
                    ["Auto-detect is on: running built-in players are listed too", "(no selected or running built-in player)"],
                    "报告: 自动识别、没有在跑的")
    }

    // ---- 运行时那行日志 ----
    do {
        typealias D = PlayerReportingDiagnostics
        let hits = D.outputtingPlayers(selected: [.qqMusic], outputting: [qqIPad, "com.other"])
        expectEqual(hits.map(\.name), ["qq_music"], "日志: 别的版本在出声也算勾选的这个")
        expectEqual(hits.map(\.bundleID), [qq], "日志: 报本体 bundle id")
        expectEqual(D.outputtingPlayers(selected: [.netease], outputting: [qq]).isEmpty, true, "日志: 没勾选的不算")
        expectEqual(D.outputtingPlayers(selected: [.auto], outputting: [PlaybackPlayer.spotify.bundleIdentifier]).map(\.name),
                    ["spotify"], "日志: 自动识别时内置播放器都算")

        var throttle = D.UnreportedOutputThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        expectEqual(throttle.due([qq], now: t0), [qq], "节流: 进入时记一次")
        expectEqual(throttle.due([qq], now: t0.addingTimeInterval(10)), [], "节流: 持续时不每拍记")
        expectEqual(throttle.due([qq], now: t0.addingTimeInterval(D.UnreportedOutputThrottle.repeatSeconds)), [qq],
                    "节流: 持续到间隔再记一次")
        expectEqual(throttle.due([], now: t0.addingTimeInterval(400)), [], "节流: 离开")
        expectEqual(throttle.due([qq], now: t0.addingTimeInterval(401)), [qq], "节流: 离开后再进来重新记")
    }
}
