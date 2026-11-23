import Foundation
import LyrimuseCore

func runKugouIPadTests() {
    typealias K = KugouIPadNowPlaying
    typealias Frame = KugouIPadNowPlaying.Frame
    typealias L = LocalPlaybackSource
    let mac = PlaybackPlayer.kugou.bundleIdentifier
    func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_795_401_800 + s) }
    func ms(_ d: Date?) -> Int? { d.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) } }

    // ---- 按酷狗 Mac 版认,找进程、权限行不算它 ----
    do {
        expectEqual(PlayerBundleAliases.canonical(K.bundleID), mac, "iPad 酷狗: bundle id 换成 Mac 版的")
        expectEqual(MediaControlClient.reportingPlayerBundleID(K.bundleID, owner: nil), mac, "iPad 酷狗: 系统报上来的一进来就当 Mac 版")
        expectEqual(PlayerBundleAliases.all(for: mac), [mac, K.bundleID], "iPad 酷狗: 判装没装、在不在跑把它算上")
        expectEqual(PlayerBundleAliases.all(for: mac, includingOtherClients: false), [mac], "iPad 酷狗: 按本体的菜单、界面、数据做事的地方不算它")
        expectEqual(PlayerProcess.otherClient(reporting: K.bundleID), K.bundleID, "iPad 酷狗: 认得出是另一个程序报的")
        defer { MediaControlClient.noteReportingClient(mac, forBundleID: mac) }
        MediaControlClient.noteReportingClient(K.bundleID, forBundleID: mac)
        expectEqual(PlayerProcess.pid(bundleID: mac), nil, "iPad 酷狗进程: 会话是 iPad 版报的,不去找 Mac 版的进程(不按它的菜单)")
        expectEqual(L.resumeReadingNeverLeads(bundleID: mac, client: K.bundleID), true, "iPad 酷狗位置: 恢复那一拍原样采信")
        expectEqual(L.resumeReadingNeverLeads(bundleID: mac, client: mac), false, "iPad 酷狗位置: Mac 版照旧")
    }

    // ---- 「播放」恢复只换时间戳:按录到的真实序列 ----
    do {
        var memory: K.Memory?
        func n(_ f: Frame) -> Frame { K.normalized(f, memory: &memory) }
        let song = "该怎么写我"
        let pause = Frame(title: song, elapsed: 14.3, timestamp: at(48.950), rate: 0, playing: false)
        expectEqual(n(pause), pause, "iPad 酷狗恢复: 暂停帧原样")
        let quiet = Frame(title: song, elapsed: 14.3, timestamp: at(50.943), rate: 0, playing: false)
        let resumed = n(quiet)
        expectEqual([resumed.rate, resumed.playing == true ? 1 : 0, resumed.timestamp == quiet.timestamp ? 1 : 0], [1, 1, 1],
                    "iPad 酷狗恢复: 暂停 2 秒后只换时间戳的那一帧当作从那一刻起在放")
        expectEqual(n(quiet), resumed, "iPad 酷狗恢复: 同一帧再过一次结果不变")
        let paused = Frame(title: song, elapsed: 18.6, timestamp: at(55.276), rate: 0, playing: false)
        expectEqual(n(paused), paused, "iPad 酷狗恢复: 之后的暂停帧(进度变了)照旧是暂停")

        var echo: K.Memory?
        let seek = Frame(title: song, elapsed: 52, timestamp: at(80.788), rate: 0, playing: false)
        _ = K.normalized(seek, memory: &echo)
        let seekEcho = Frame(title: song, elapsed: 52, timestamp: at(81.342), rate: 0, playing: false)
        expectEqual(K.normalized(seekEcho, memory: &echo), seekEcho, "iPad 酷狗恢复: 暂停中跳转后 0.55 秒那一次换时间戳不是恢复")
        let seekPlay = Frame(title: song, elapsed: 52, timestamp: at(83.905), rate: 0, playing: false)
        expectEqual(K.normalized(seekPlay, memory: &echo).rate, 1, "iPad 酷狗恢复: 跳转后按「播放」那一次是恢复")
        let seekLate = Frame(title: song, elapsed: 52, timestamp: at(84.457), rate: 1, playing: true)
        expectEqual(ms(K.normalized(seekLate, memory: &echo).timestamp), ms(at(84.457 - K.lateResumeFrameSecs)),
                    "iPad 酷狗恢复: 跳转后补来的速率 1(不带进度)往前挪")

        var long: K.Memory?
        _ = K.normalized(Frame(title: song, elapsed: 106.749, timestamp: at(29.817), rate: 0, playing: false), memory: &long)
        _ = K.normalized(Frame(title: song, elapsed: 106.749, timestamp: at(41.761), rate: 0, playing: false), memory: &long)
        let late = Frame(title: song, elapsed: 106.767, timestamp: at(42.341), rate: 1, playing: true)
        expectEqual(ms(K.normalized(late, memory: &long).timestamp), ms(at(42.341 - K.lateResumeFrameSecs)),
                    "iPad 酷狗恢复: 暂停 12 秒后补来的晚锚点往前挪 0.49 秒")
        let later = Frame(title: song, elapsed: 106.767, timestamp: at(43.6), rate: 1, playing: true)
        expectEqual(K.normalized(later, memory: &long), later, "iPad 酷狗恢复: 隔太久的不挪")
        let farther = Frame(title: song, elapsed: 107.0, timestamp: at(42.341), rate: 1, playing: true)
        expectEqual(K.normalized(farther, memory: &long), farther, "iPad 酷狗恢复: 进度离暂停处远的不挪(那是别的锚点)")

        var toggle: K.Memory?
        _ = K.normalized(Frame(title: song, elapsed: 74.14, timestamp: at(10), rate: 0, playing: false), memory: &toggle)
        let direct = Frame(title: song, elapsed: 74.14, timestamp: at(14.1), rate: 1, playing: true)
        expectEqual(K.normalized(direct, memory: &toggle), direct, "iPad 酷狗恢复: toggle、界面播放键当场报速率 1,不动")

        var order: K.Memory?
        _ = K.normalized(quiet, memory: &order)
        expectEqual(K.normalized(pause, memory: &order), pause, "iPad 酷狗恢复: 先见到后一帧、再见到暂停帧,暂停帧仍是暂停")
        expectEqual(K.normalized(quiet, memory: &order).rate, 1, "iPad 酷狗恢复: 同一进度记最早的时刻,后一帧随后认成恢复")

        var other: K.Memory?
        let shortGap = Frame(title: song, elapsed: 14.3, timestamp: at(49.5), rate: 0, playing: false)
        _ = K.normalized(pause, memory: &other)
        expectEqual(K.normalized(shortGap, memory: &other), shortGap, "iPad 酷狗恢复: 不到 0.8 秒的不算")
        expectEqual(K.normalized(Frame(title: "别的歌", elapsed: 14.3, timestamp: at(60), rate: 0, playing: false), memory: &other).rate, 0,
                    "iPad 酷狗恢复: 换了一首不算")
        K.resetForTesting()
        _ = K.normalized(pause, bundleID: mac)
        expectEqual(K.normalized(quiet, bundleID: mac), quiet, "iPad 酷狗恢复: Mac 版报的不动")
        K.resetForTesting()
    }

    // ---- 换到听过一半的听书单集:开播整帧之后跳到上次位置的那一帧往前挪(录到的真实序列) ----
    do {
        var start: K.Start?
        func j(_ f: Frame) -> Frame { K.resumedJump(f, start: &start) }
        let ep = "第2集 系统，我囸你奶奶！"
        let open = Frame(title: ep, elapsed: 0.012, timestamp: at(2.313), rate: 1, playing: true)
        expectEqual(j(open), open, "iPad 酷狗续播: 开播整帧原样")
        let jump = Frame(title: ep, elapsed: 10.064, timestamp: at(2.880), rate: 1, playing: true)
        expectEqual(ms(j(jump).timestamp), ms(at(2.880 - K.lateResumeJumpSecs)), "iPad 酷狗续播: 0.57 秒后跳到上次位置的那一帧往前挪")
        expectEqual(ms(j(jump).timestamp), ms(at(2.880 - K.lateResumeJumpSecs)), "iPad 酷狗续播: 同一帧再过一次结果不变")
        let later = Frame(title: ep, elapsed: 30, timestamp: at(3.6), rate: 1, playing: true)
        expectEqual(j(later), later, "iPad 酷狗续播: 开播 1 秒以后的跳转不挪")
        let small = Frame(title: ep, elapsed: 0.4, timestamp: at(2.9), rate: 1, playing: true)
        expectEqual(j(small), small, "iPad 酷狗续播: 换歌两步式那份新歌名整帧(进度不到 1 秒)不挪")
        let other = Frame(title: "别的", elapsed: 10, timestamp: at(2.9), rate: 1, playing: true)
        expectEqual(j(other), other, "iPad 酷狗续播: 别的一首不挪")
        let paused = Frame(title: ep, elapsed: 10.064, timestamp: at(2.9), rate: 0, playing: false)
        expectEqual(j(paused), paused, "iPad 酷狗续播: 暂停帧不挪")
        _ = j(Frame(title: ep, elapsed: 0, timestamp: at(60), rate: 1, playing: true))
        let again = j(Frame(title: ep, elapsed: 20, timestamp: at(60.57), rate: 1, playing: true))
        expectEqual(ms(again.timestamp), ms(at(60.57 - K.lateResumeJumpSecs)), "iPad 酷狗续播: 同一集过后再开播一次,按新的开播帧算")
        K.resetForTesting()
        _ = K.normalized(open, bundleID: K.bundleID)
        expectEqual(ms(K.normalized(jump, bundleID: K.bundleID).timestamp), ms(at(2.880 - K.lateResumeJumpSecs)),
                    "iPad 酷狗续播: 按 bundle id 整理的那一路也挪")
        K.resetForTesting()
    }

    // ---- 放着歌拖进度:跳转那一帧往后挪(录到的真实序列) ----
    do {
        var last: K.Last?
        func sk(_ f: Frame, _ n: Frame? = nil) -> Frame { K.seekedWhilePlaying(f, normalized: n ?? f, last: &last) }
        let song = "雨过后的风景"
        let playingFrame = Frame(title: song, elapsed: 6.88, timestamp: at(29.071), rate: 1, playing: true)
        expectEqual(sk(playingFrame), playingFrame, "iPad 酷狗拖动: 恢复那一帧(进度接得上)不挪")
        let seek = Frame(title: song, elapsed: 50, timestamp: at(30.346), rate: 1, playing: true)
        expectEqual(ms(sk(seek).timestamp), ms(at(30.346 + K.seekFrameLeadSecs)), "iPad 酷狗拖动: 跳转那一帧往后挪 0.14 秒")
        expectEqual(ms(sk(seek).timestamp), ms(at(30.346 + K.seekFrameLeadSecs)), "iPad 酷狗拖动: 同一帧再过一次结果不变")
        expectEqual(sk(playingFrame), playingFrame, "iPad 酷狗拖动: 轮询晚一步读到的旧帧不动、不改记住的那份")
        expectEqual(ms(sk(seek).timestamp), ms(at(30.346 + K.seekFrameLeadSecs)), "iPad 酷狗拖动: 读过旧帧之后跳转那一帧照样挪")
        let pause = Frame(title: song, elapsed: 66.43, timestamp: at(46.93), rate: 0, playing: false)
        expectEqual(sk(pause), pause, "iPad 酷狗拖动: 暂停帧不挪")
        let resume = Frame(title: song, elapsed: 66.43, timestamp: at(60), rate: 1, playing: true)
        expectEqual(sk(resume), resume, "iPad 酷狗拖动: 暂停后恢复(进度跟暂停处一样)不挪")
        let candidate = Frame(title: song, elapsed: 0.045, timestamp: at(80), rate: 1, playing: true)
        expectEqual(sk(candidate), candidate, "iPad 酷狗拖动: 换歌那份旧歌名下的锚点(进度不到 1 秒)不挪")
        let next = Frame(title: "别的歌", elapsed: 0.73, timestamp: at(80.6), rate: 1, playing: true)
        expectEqual(sk(next), next, "iPad 酷狗拖动: 换了一首不挪")
        let jumped = Frame(title: "别的歌", elapsed: 208.32, timestamp: at(81.0), rate: 1, playing: true)
        var shiftedJump = jumped
        shiftedJump.timestamp = at(81.0 - K.lateResumeJumpSecs)
        expectEqual(sk(jumped, shiftedJump), shiftedJump, "iPad 酷狗拖动: 前面已经按续播挪过的不再挪")
        K.resetForTesting()
        _ = K.normalized(playingFrame, bundleID: K.bundleID)
        expectEqual(ms(K.normalized(seek, bundleID: K.bundleID).timestamp), ms(at(30.346 + K.seekFrameLeadSecs)),
                    "iPad 酷狗拖动: 按 bundle id 整理的那一路也挪")
        K.resetForTesting()
        expectEqual([MediaControlClient.correctsFromResetAnchor(bundleID: K.bundleID), MediaControlClient.correctsFromResetAnchor(bundleID: mac)],
                    [true, true], "iPad 酷狗换歌: 旧歌名下的候选锚点那条修正按它自己的 bundle id 也开")
    }

    // ---- 事件流:真实的几行逐行喂,恢复那一行报恢复、暂停那几行报暂停、晚锚点的身份按挪过的时刻算 ----
    do {
        K.resetForTesting()
        defer { K.resetForTesting() }
        func line(_ payload: String, diff: Bool = true) -> Data {
            Data("{\"type\":\"data\",\"diff\":\(diff),\"payload\":{\(payload)}}".utf8)
        }
        let lines = [
            line("\"bundleIdentifier\":\"\(K.bundleID)\",\"title\":\"该怎么写我\",\"artist\":\"沈才华\",\"album\":\"该怎么写我\","
                + "\"playing\":true,\"playbackRate\":1,\"elapsedTimeMicros\":100000000,\"timestampEpochMicros\":1795405323000000,"
                + "\"durationMicros\":215160003", diff: false),
            line("\"playing\":false"),
            line("\"contentItemIdentifier\":\"F02C\",\"elapsedTimeMicros\":106749000,\"timestampEpochMicros\":1795405329816505,\"playbackRate\":0"),
            line("\"timestampEpochMicros\":1795405341760934,\"contentItemIdentifier\":\"BFCC\""),
            line("\"playing\":true"),
            line("\"contentItemIdentifier\":\"1BB8\",\"elapsedTimeMicros\":106766998,\"timestampEpochMicros\":1795405342341057,\"playbackRate\":1"),
            line("\"playing\":false"),
            line("\"contentItemIdentifier\":\"527E\",\"elapsedTimeMicros\":110971000,\"timestampEpochMicros\":1795405346048782,\"playbackRate\":0"),
            line("\"timestampEpochMicros\":1795405348043126,\"contentItemIdentifier\":\"86A0\""),
            line("\"timestampEpochMicros\":1795405352276464,\"contentItemIdentifier\":\"B576\",\"elapsedTimeMicros\":115200000"),
        ]
        var merged: [String: Any] = [:]
        var resumed: [Bool] = []
        var paused: [Bool] = []
        var keys: [String?] = []
        for l in lines {
            let d = MediaControlStreamWatcher.digest(line: l, merged: merged, arrivedAt: Date(timeIntervalSince1970: 1_795_405_360))
            merged = d.merged
            resumed.append(d.resumedAtArrival)
            paused.append(d.pausedAtArrival)
            keys.append(d.anchorKey)
        }
        expectEqual(resumed, [true, false, false, true, true, false, false, false, true, false],
                    "iPad 酷狗事件流: 只换时间戳的两行(暂停 12 秒、2 秒后按「播放」)报恢复")
        expectEqual(paused, [false, true, true, false, false, false, true, true, false, true],
                    "iPad 酷狗事件流: 暂停帧报暂停,补成在放之后那一帧不带速率、不报 playing:false 也认")
        let shifted = MediaControlMicros.timestampString((1_795_405_342.341057 - K.lateResumeFrameSecs) * 1_000_000)
        expectEqual(keys[5], MediaControlClient.anchorKey(artist: "沈才华", title: "该怎么写我", elapsedTime: 106.766998,
                                                          timestamp: shifted),
                    "iPad 酷狗事件流: 晚锚点的身份按挪过的时刻算,跟轮询那一路一致")
        expectEqual(merged["playbackRate"] as? Double, 0, "iPad 酷狗事件流: 合并状态留原样")
    }

    // ---- 单问那一份 ----
    do {
        K.resetForTesting()
        defer { K.resetForTesting() }
        func helper(_ ts: Double, rate: Int) -> Data {
            Data(("{\"bundleIdentifier\":\"\(K.bundleID)\",\"title\":\"该怎么写我\",\"artist\":\"沈才华\",\"album\":\"该怎么写我\","
                + "\"duration\":215.16,\"playbackRate\":\(rate),\"playing\":\(rate == 1),\"isMusicApp\":true,\"processIdentifier\":12751,"
                + "\"anchorElapsedTime\":14.3,\"elapsedTime\":14.3,\"timestamp\":\(ts)}").utf8)
        }
        _ = NowPlayingClientsProbe.decodeSnapshot(helper(1_795_401_848.950, rate: 0))
        let quiet = K.normalizedPayload(helper(1_795_401_850.943, rate: 0), now: Date(timeIntervalSince1970: 1_795_401_852.943))
        let object = (try? JSONSerialization.jsonObject(with: quiet)) as? [String: Any]
        expectEqual([object?["playbackRate"] as? Double, (object?["elapsedTime"] as? Double).map { ($0 * 1000).rounded() / 1000 }],
                    [1, 16.3], "iPad 酷狗单问: 补成在放,此刻进度按恢复那一刻外推")
        let other = Data("{\"bundleIdentifier\":\"\(mac)\",\"title\":\"x\",\"anchorElapsedTime\":1,\"timestamp\":1}".utf8)
        expectEqual(K.normalizedPayload(other), other, "iPad 酷狗单问: 别的播放器原样")
    }

    // ---- 接线契约 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func sourceText(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = sourceText("LyrimuseCore/Local/MediaControlClient.swift")
        expectEqual([sourceHas(client, "let kugou = KugouIPadNowPlaying.normalized(reportedFrame, bundleID: bundleIdentifier)"),
                     sourceHas(client, "playing = kugou.playing"),
                     sourceHas(client, "playing: playing, elapsed: names.elapsed, timestamp: reportedTimestamp, rate: kugou.rate)"),
                     sourceHas(client, "elapsedNow: !kugouRewrote && plexamp.elapsed == names.elapsed")],
                    [true, true, true, true], "iPad 酷狗接线: 轮询解码补上恢复、外推值作废")
        let probe = sourceText("LyrimuseCore/Local/NowPlayingClientsProbe.swift")
        expectEqual(sourceHas(probe, "let data = KugouIPadNowPlaying.normalizedPayload("), true, "iPad 酷狗接线: 单问那一份整理")
        let watcher = sourceText("LyrimuseCore/Local/MediaControlStreamWatcher.swift")
        expectEqual([sourceHas(watcher, "let identity = KugouIPadNowPlaying.normalizedFields("),
                     sourceHas(watcher, "let timestamp = identity[\"timestamp\"] as? String")],
                    [true, true], "iPad 酷狗接线: 事件流判恢复、算锚点身份用整理过的")
    }
}
