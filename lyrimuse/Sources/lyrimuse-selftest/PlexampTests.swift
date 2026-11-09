import Foundation
import LyrimuseCore

/// Plexamp:本机播放器接口(32500)的时间线解析、循环档、失焦控制的路径,以及接线契约。时间线样本照真机录到的应答。
@MainActor
func runPlexampTests() {
    typealias A = PlexampPlayerAPI
    typealias C = MusicPlaybackController

    // ---- 时间线 ----
    do {
        let playing = #"<MediaContainer commandID="7"><Timeline state="playing" duration="246674" time="10000" playQueueItemID="1" key="/library/metadata/39" ratingKey="39" playQueueID="2" type="music" itemType="music" volume="0" shuffle="0" repeat="2" controllable="volume,repeat,skipPrevious,seekTo,stepBack,stepForward,stop,playPause,skipNext" port="32400"/><Timeline type="video" state="stopped"/><Timeline type="photo" state="stopped"/></MediaContainer>"#
        let t = A.parseTimeline(playing)
        expectEqual(t, A.Timeline(state: "playing", ratingKey: "39", volume: 0, shuffle: false, repeatMode: 2),
                    "Plexamp 时间线: 取音乐那一条的状态、曲目、音量、随机、循环")
        let stopped = #"<MediaContainer commandID="1"><Timeline state="stopped" time="0" type="music" itemType="music" volume="100" shuffle="1" repeat="0" controllable="volume"/><Timeline type="video" state="stopped"/></MediaContainer>"#
        expectEqual(A.parseTimeline(stopped), A.Timeline(state: "stopped", ratingKey: nil, volume: 100, shuffle: true, repeatMode: 0),
                    "Plexamp 时间线: 停着时没有曲目")
        expectEqual(A.parseTimeline(#"<MediaContainer><Timeline type="video" state="playing"/></MediaContainer>"#) == nil, true,
                    "Plexamp 时间线: 没有音乐那一条为 nil")
        expectEqual(A.parseTimeline("") == nil, true, "Plexamp 时间线: 空应答为 nil")
    }

    // ---- 循环档 ----
    do {
        expectEqual([A.playbackMode(repeatMode: 0), A.playbackMode(repeatMode: 1), A.playbackMode(repeatMode: 2), A.playbackMode(repeatMode: nil)],
                    [.list, .repeatOne, .repeatAll, nil], "Plexamp 循环档: 0 关、1 单曲、2 列表")
        expectEqual([A.repeatValue(for: .list), A.repeatValue(for: .repeatOne), A.repeatValue(for: .repeatAll), A.repeatValue(for: .shuffle)],
                    [0, 1, 2, nil], "Plexamp 循环档: 写回同一套值,随机写不进")
        expectEqual(A.modeOptions.allows(.shuffle), false, "Plexamp 循环档: 不给随机键")
        expectEqual(A.modeOptions.allows(.repeatOne) && A.modeOptions.allows(.repeatAll), true, "Plexamp 循环档: 两种循环都有")
        expectEqual(C.supportsExtendedControls(.plexamp) && C.supportsRepeatOne(.plexamp), true, "Plexamp: 有循环和音量")
        expectEqual(C.supportsFavorite(.plexamp), false, "Plexamp: 没有喜欢")
    }

    // ---- 失焦控制 ----
    do {
        expectEqual([A.commandPath(.playPause, state: "playing"), A.commandPath(.playPause, state: "paused"),
                     A.commandPath(.playPause, state: nil), A.commandPath(.nextTrack, state: nil),
                     A.commandPath(.previousTrack, state: nil)],
                    ["/player/playback/pause", "/player/playback/play", "/player/playback/play",
                     "/player/playback/skipNext", "/player/playback/skipPrevious"],
                    "Plexamp 失焦控制: 播放 / 暂停按此刻状态选,上下首直接发")
        for command in [PlaybackMenuControl.Command.playPause, .nextTrack, .previousTrack] {
            expectEqual(C.controlRoute(exclusivelyAppleMusic: false, focusFallback: nil, focusHeldElsewhere: true,
                                       directQueryFallback: .plexamp, mediaControlCommand: command.rawValue),
                        .plexampAPI(command), "Plexamp 失焦控制: \(command.rawValue) 发到本机接口")
        }
        expectEqual(C.controlRoute(exclusivelyAppleMusic: false, focusFallback: nil, focusHeldElsewhere: true,
                                   directQueryFallback: .plexamp, mediaControlCommand: "seek"),
                    .withheld, "Plexamp 失焦控制: 跳转不走这条")
        expectEqual(C.controlRoute(exclusivelyAppleMusic: false, focusFallback: nil, focusHeldElsewhere: false,
                                   directQueryFallback: .plexamp, mediaControlCommand: "togglePlayPause"),
                    .mediaControl, "Plexamp 焦点正常: 照旧走系统指令")
    }

    // ---- 开播锚点 ----
    do {
        typealias L = LocalPlaybackSource
        let b = PlaybackPlayer.plexamp.bundleIdentifier
        expectEqual([L.plexampFreshStartLead(bundleID: b, anchorElapsed: 0, previousPlayedToEnd: false, electron: true),
                     L.plexampFreshStartLead(bundleID: b, anchorElapsed: 0, previousPlayedToEnd: false, electron: false),
                     L.plexampFreshStartLead(bundleID: b, anchorElapsed: 0, previousPlayedToEnd: true, electron: true),
                     L.plexampFreshStartLead(bundleID: b, anchorElapsed: 214, previousPlayedToEnd: false, electron: true),
                     L.plexampFreshStartLead(bundleID: b, anchorElapsed: nil, previousPlayedToEnd: false, electron: true),
                     L.plexampFreshStartLead(bundleID: PlaybackPlayer.foobar2000.bundleIdentifier, anchorElapsed: 0,
                                             previousPlayedToEnd: false, electron: true)],
                    [0.4, 0, 0, 0, 0, 0], "Plexamp 开播: Electron 那一代新起一首、锚点 0 补 0.4 秒;Tauri、自然连播、从中段点播、别的播放器不补")
        expectEqual(L.carriesGaplessLead(tier: .precise, bundleID: b), true, "Plexamp 开播: 自然连播 / 单曲循环回绕按连续性估超前量")
        let w = Date(timeIntervalSince1970: 1_794_000_000)
        expectEqual([L.plexampRenameFollowsWrap(wrapAt: w, now: w.addingTimeInterval(0.5)),
                     L.plexampRenameFollowsWrap(wrapAt: w, now: w.addingTimeInterval(2.5)),
                     L.plexampRenameFollowsWrap(wrapAt: w, now: w.addingTimeInterval(-0.1))],
                    [true, false, false], "Plexamp 开播: 回绕后 2 秒内换歌名算同一次自然过渡")
        expectEqual(L.carriesGaplessLead(tier: .precise, bundleID: PlaybackPlayer.foobar2000.bundleIdentifier), false,
                    "Plexamp 开播: 别的精确档照旧不开")
    }

    // ---- 4.50 起系统会话的位置补全 ----
    do {
        typealias S = PlexampSessionAnchor
        func ts(_ x: Double) -> String { MediaControlMicros.timestampString(1_794_080_000_000_000 + x * 1_000_000)! }
        // 开播:在放、带时刻、没位置 → 从 0 起算
        let start = S.fill(identity: "a", playing: true, elapsed: nil, timestamp: ts(0.79), rate: 1, last: nil)
        expectEqual([start.elapsed, start.rate], [0, 1], "Plexamp 会话补全: 新起一首没位置,从 0 起算")
        // 恢复:带位置的锚点原样、速率缺了按在放补 1;0.5 秒后清空位置的回声沿用它;之后读到同一时刻的也沿用
        let resume = S.fill(identity: "a", playing: true, elapsed: 128.69, timestamp: ts(21.786), rate: nil, last: start.remember)
        expectEqual([resume.elapsed, resume.rate], [128.69, 1], "Plexamp 会话补全: 带位置的原样,速率缺了补 1")
        let echo = S.fill(identity: "a", playing: true, elapsed: nil, timestamp: ts(22.332), rate: 1, last: resume.remember)
        expectEqual([echo.elapsed, echo.rate], [128.69, 1], "Plexamp 会话补全: 锚点后 0.5 秒清空位置的那份沿用锚点")
        expectEqual(echo.timestamp, ts(21.786), "Plexamp 会话补全: 时刻也沿用锚点那一刻")
        let later = S.fill(identity: "a", playing: true, elapsed: nil, timestamp: ts(22.332), rate: 1, last: echo.remember)
        expectEqual(later.elapsed, 128.69, "Plexamp 会话补全: 之后读到同一个回声时刻的照样沿用")
        // 暂停:速率缺了按没在放补 0
        let pause = S.fill(identity: "a", playing: false, elapsed: 128.389, timestamp: ts(17.114), rate: nil, last: later.remember)
        expectEqual(pause.rate, 0, "Plexamp 会话补全: 暂停那份速率缺了补 0")
        // 自然连播:新歌的锚点先带着上一首的歌名到,约 0.5 秒后换歌名、不带位置 → 接过锚点、扣 0.5
        let early = S.fill(identity: "a", playing: true, elapsed: 1.606, timestamp: ts(9.113), rate: 1, last: later.remember)
        let renamed = S.fill(identity: "b", playing: true, elapsed: nil, timestamp: ts(9.655), rate: 1, last: early.remember)
        expectEqual(renamed.elapsed.map { ($0 * 1000).rounded() / 1000 }, 1.106, "Plexamp 会话补全: 自然连播接过上一份锚点、扣掉 0.5 秒超前")
        expectEqual(renamed.timestamp, ts(9.113), "Plexamp 会话补全: 自然连播沿用那份锚点的时刻")
        // 隔了好几秒才换的一首:不是自然连播,当新起一首
        let fresh = S.fill(identity: "c", playing: true, elapsed: nil, timestamp: ts(30), rate: 1, last: renamed.remember)
        expectEqual(fresh.elapsed, 0, "Plexamp 会话补全: 隔久了才来的新一首从 0 起算")
        // 点播另一首:换歌前先报旧歌停下的位置(大),不当自然连播
        let stopAt = S.fill(identity: "a", playing: true, elapsed: 109.179, timestamp: ts(3.518), rate: 1, last: nil)
        let picked = S.fill(identity: "e", playing: true, elapsed: nil, timestamp: ts(4.061), rate: 1, last: stopAt.remember)
        expectEqual(picked.elapsed, 0, "Plexamp 会话补全: 点播另一首时旧歌停下的位置不接,新歌从 0 起算")
        // 旧歌刚放 2.5 秒就点播另一首:停下的位置也小,但接得上旧歌自己推到这一刻的位置,不当自然连播
        let justStarted = S.fill(identity: "f", playing: true, elapsed: nil, timestamp: ts(40), rate: 1, last: nil)
        let stoppedEarly = S.fill(identity: "f", playing: true, elapsed: 2.5, timestamp: ts(42.5), rate: 1,
                                  last: justStarted.remember)
        expectEqual(stoppedEarly.remember?.continuesLast, true, "Plexamp 会话补全: 位置接得上上一份推到这一刻的,算这首自己报的")
        let pickedEarly = S.fill(identity: "g", playing: true, elapsed: nil, timestamp: ts(43), rate: 1, last: stoppedEarly.remember)
        expectEqual(pickedEarly.elapsed, 0, "Plexamp 会话补全: 旧歌开头几秒就点播另一首,新歌从 0 起算、不接旧歌的锚点")
        expectEqual(early.remember?.continuesLast, false, "Plexamp 会话补全: 新歌带着旧歌名先到的那份接不上旧歌的位置")
        // 跟过回声的锚点不再被下一首接走
        let afterEcho = S.fill(identity: "d", playing: true, elapsed: nil, timestamp: ts(22.5), rate: 1, last: echo.remember)
        expectEqual(afterEcho.elapsed, 0, "Plexamp 会话补全: 已经跟过回声的锚点不当自然连播接走")
    }

    // ---- 本机接口的端口:优先 32500,被占时换端口,按进程找正在监听的 ----
    do {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        _ = listen(fd, 1)
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: got.sin_port))
        expectEqual(bound == 0 && port > 0 && ProcessOpenFiles.listeningTCPPorts(pid: getpid()).contains(port), true,
                    "Plexamp 端口: 按进程读得到正在监听的 TCP 端口")
        close(fd)
        expectEqual(ProcessOpenFiles.listeningTCPPorts(pid: getpid()).contains(port), false, "Plexamp 端口: 关掉的不再列出")
        expectEqual(A.preferredPort, 32500, "Plexamp 端口: 优先 32500")
    }

    // ---- 接线 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let api = src("LyrimuseCore/Local/PlexampPlayerAPI.swift")
        expectEqual(sourceHas(api, "if let data = request(path, query: query, port: current) { return data }\nguard let found = discoverPort(), found != current else { return nil }"), true,
                    "Plexamp 接线: 连不上时找一次端口再试")
        let controller = src("LyrimuseCore/Local/MusicPlaybackController.swift")
        expectEqual(sourceHas(controller, "case .plexampAPI(let command):\ncommandQueue.async {\ncommandSerial &+= 1\nif !PlexampPlayerAPI.shared.send(command) {\n_ = withhold(mediaControlCommand, reason: \"Plexamp: player API unreachable\")"), true,
                    "Plexamp 接线: 失焦控制在命令队列上发,不卡主线程;送不到时报控制不可用")
        expectEqual(sourceHas(controller, "case .plexamp:\nreturn PlexampPlayerAPI.shared.setPlaybackMode(mode)")
                    && sourceHas(controller, "case .plexamp:\nreturn PlexampPlayerAPI.shared.setVolume(v)"), true,
                    "Plexamp 接线: 循环档和音量写到本机接口")
        let idle = src("lyrimuse/UI/IdlePlaybackActions.swift")
        expectEqual(sourceHas(idle, "case .plexamp"), false, "Plexamp 接线: 停播页不给「继续播放」(列表放完后发 play 放不起来)")
    }
}
