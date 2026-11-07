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

    // ---- 接线 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let controller = src("LyrimuseCore/Local/MusicPlaybackController.swift")
        expectEqual(sourceHas(controller, "case .plexampAPI(let command):\ncommandQueue.async { PlexampPlayerAPI.shared.send(command) }"), true,
                    "Plexamp 接线: 失焦控制在命令队列上发,不卡主线程")
        expectEqual(sourceHas(controller, "case .plexamp:\nreturn PlexampPlayerAPI.shared.setPlaybackMode(mode)")
                    && sourceHas(controller, "case .plexamp:\nreturn PlexampPlayerAPI.shared.setVolume(v)"), true,
                    "Plexamp 接线: 循环档和音量写到本机接口")
        let idle = src("lyrimuse/UI/IdlePlaybackActions.swift")
        expectEqual(sourceHas(idle, "case .plexamp: PlayerProcess.pid(bundleID: player.bundleIdentifier) != nil")
                    && sourceHas(idle, "case .plexamp:\nok = PlexampPlayerAPI.shared.resume()"), true,
                    "Plexamp 接线: 停播页「继续播放」开着才给,判开没开不发网络请求")
    }
}
