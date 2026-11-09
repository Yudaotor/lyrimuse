import Foundation
import LyrimuseCore

/// 系统会话不报时长时按播放器界面上的进度条补(`ProgressBarDuration`、`MediaControlClient.progressBarFilled`):认哪根滑块、
/// 三道闸、按播放器开关、单问那份的位置,以及接线契约。
@MainActor
func runProgressBarDurationTests() {
    typealias P = ProgressBarDuration
    typealias S = PineVolume.Slider

    // ---- 认哪根滑块 ----
    do {
        expectEqual(P.progressSlider([S(min: 0, max: 315.193469387, value: 0)])?.max, 315.193469387,
                    "进度条时长: 进度条的最大值就是解出来的时长(MyGo 李志插件那首系统那份没有时长,进度条 315.19)")
        expectEqual(P.progressSlider([S(min: 0, max: 1, value: 0.5), S(min: 0, max: 223.27, value: 131.04)]),
                    S(min: 0, max: 223.27, value: 131.04), "进度条时长: 音量条(0~1)不算,进度条连当前值一起交出")
        expectEqual(P.progressSlider([S(min: 0, max: 200, value: 0), S(min: 0, max: 300, value: 0)]) == nil, true,
                    "进度条时长: 不止一根像进度条的不猜")
        expectEqual(P.progressSlider([S(min: 0, max: .infinity, value: 0)]) == nil, true, "进度条时长: 无限长不算")
        expectEqual(P.progressSlider([]) == nil, true, "进度条时长: 读不到滑块为 nil")
    }

    // ---- 两道闸 ----
    do {
        expectEqual(P.accepts(223.268571428, previous: 223.268571428), false,
                    "进度条时长: 换歌后进度条还是上一首的长度不认(MyGo《天空之城》→《家乡》一直停在 223.27,实际 343.3)")
        expectEqual(P.accepts(223.27, previous: 223.06), false, "进度条时长: 上一首的时长是系统那份报的,差零点几秒也算同一个")
        expectEqual(P.accepts(343.3, previous: 223.27), true, "进度条时长: 跟上一首不一样的照常采用")
        expectEqual(P.accepts(315.19, previous: nil), true, "进度条时长: 不知道上一首多长时照常采用")
        expectEqual(P.matchesPosition(barValue: 131.04, position: 12.5), false,
                    "进度条时长: 界面停住了(系统那份已换到下一首放到 12 秒,进度条还是上一首的 131 秒)不认")
        expectEqual(P.matchesPosition(barValue: 12.1, position: 13.4), true, "进度条时长: 当前值跟位置差一两秒照常认")
        expectEqual(P.matchesPosition(barValue: 9.9, position: 13.4), false, "进度条时长: 差 3 秒以上不认")
        expectEqual(P.matchesPosition(barValue: 12, position: nil), false, "进度条时长: 不知道位置时不认")
    }

    // ---- 单问那份这一刻的位置 ----
    do {
        let now = Date(timeIntervalSince1970: 1_000)
        func snap(elapsed: Double?, anchor: Double?, playing: Bool, rate: Double = 1) -> MediaControlSnapshot {
            MediaControlSnapshot.forReplay(title: "t", artist: "a", album: nil, duration: nil, elapsedTime: elapsed, playing: playing,
                                           playbackRate: rate, bundleIdentifier: "x", anchorElapsedTime: anchor)
        }
        expectEqual(P.probedPosition(snap(elapsed: 10, anchor: 10, playing: true), anchorTimestamp: 996, now: now), 14,
                    "进度条时长: 单问那份在放时按锚点外推到此刻")
        expectEqual(P.probedPosition(snap(elapsed: 10, anchor: 10, playing: true, rate: 2), anchorTimestamp: 996, now: now), 18,
                    "进度条时长: 外推按速率")
        expectEqual(P.probedPosition(snap(elapsed: 10, anchor: 10, playing: false), anchorTimestamp: 996, now: now), 10,
                    "进度条时长: 暂停着不外推")
        expectEqual(P.probedPosition(snap(elapsed: 10, anchor: 10, playing: true).withPlayerClock(42, capturedAt: now),
                                     anchorTimestamp: 996, now: now), 42,
                    "进度条时长: 播放器自己的钟换过的(带读数时刻)直接用")
        expectEqual(P.probedPosition(snap(elapsed: nil, anchor: nil, playing: true), anchorTimestamp: 996, now: now) == nil, true,
                    "进度条时长: 没有位置为 nil")
    }

    // ---- 补上时长时带过去的几项 ----
    do {
        var s = MediaControlSnapshot.forReplay(title: "山阴路的夏天", artist: "李志", album: "108个关键词", duration: nil,
                                               elapsedTime: 3, playing: true, playbackRate: 1,
                                               bundleIdentifier: PlaybackPlayer.mygoMusic.bundleIdentifier, anchorElapsedTime: 3)
        s.processIdentifier = 75789
        s.republishDueBy = Date(timeIntervalSince1970: 5)
        s.positionIsPrecise = true
        let filled = MediaControlClient.withFilledDuration(s, 315.2)
        expectEqual([filled.trackDuration, filled.elapsedTime], [315.2, 3], "进度条时长: 补上时长,位置不动")
        expectEqual(filled.processIdentifier == 75789 && filled.republishDueBy == s.republishDueBy && filled.positionIsPrecise == true,
                    true, "进度条时长: 进程号、补查时刻、精确档跟着带过去")
    }

    // ---- 整套流程:换歌、长度没更新、界面停住、正常补上、只对开了开关的播放器 ----
    do {
        let mygo = PlaybackPlayer.mygoMusic.bundleIdentifier
        let run = UUID().uuidString
        let t0 = Date(timeIntervalSince1970: 2_000)
        var bar: [S] = []
        var reads = 0
        let read: (String) -> [S] = { _ in reads += 1; return bar }
        func snap(_ title: String, duration: Double?, elapsed: Double, playing: Bool = true, bundleID: String = mygo) -> MediaControlSnapshot {
            MediaControlSnapshot.forReplay(title: run + title, artist: "李志", album: "我爱南京", duration: duration, elapsedTime: elapsed,
                                           playing: playing, playbackRate: 1, bundleIdentifier: bundleID, anchorElapsedTime: elapsed)
        }
        func fill(_ s: MediaControlSnapshot, at offset: Double) -> Double? {
            MediaControlClient.progressBarFilled(s, bundleID: s.bundleIdentifier, trackKey: s.trackKey, position: s.elapsedTime,
                                                 now: t0.addingTimeInterval(offset), read: read).trackDuration
        }

        expectEqual(fill(snap("天空之城", duration: 223.27, elapsed: 200), at: 0), 223.27, "进度条时长流程: 系统那份报了时长的原样交回")
        expectEqual(reads, 0, "进度条时长流程: 报了时长的不读界面")

        bar = [S(min: 0, max: 223.27, value: 1.2)]
        expectEqual(fill(snap("家乡", duration: nil, elapsed: 1), at: 10) == nil, true, "进度条时长流程: 换歌头一秒不读")
        expectEqual(reads, 0, "进度条时长流程: 换歌头一秒连界面都不碰")
        bar = [S(min: 0, max: 223.27, value: 3.1)]
        expectEqual(fill(snap("家乡", duration: nil, elapsed: 3), at: 12) == nil, true,
                    "进度条时长流程: 位置在走、长度还是上一首的不认")

        bar = [S(min: 0, max: 223.27, value: 131.04)]
        expectEqual(fill(snap("结婚", duration: nil, elapsed: 0.5), at: 20) == nil, true, "进度条时长流程: 下一首换歌头一秒不读")
        expectEqual(fill(snap("结婚", duration: nil, elapsed: 2.5), at: 22) == nil, true,
                    "进度条时长流程: 界面停住(当前值 131 秒、这首才放到 2.5 秒)不认")

        bar = [S(min: 0, max: 149.4, value: 0.2)]
        _ = fill(snap("美丽的梭罗河", duration: nil, elapsed: 0.1), at: 30)
        bar = [S(min: 0, max: 149.4, value: 2.0)]
        expectEqual(fill(snap("美丽的梭罗河", duration: nil, elapsed: 2.1), at: 32), 149.4,
                    "进度条时长流程: 当前值对得上、长度跟上一首不同的补上")
        bar = [S(min: 0, max: 999, value: 999)]
        expectEqual(fill(snap("美丽的梭罗河", duration: nil, elapsed: 5), at: 35), 149.4, "进度条时长流程: 同一首补过就用记着的")
        expectEqual(fill(snap("美丽的梭罗河", duration: nil, elapsed: 5, playing: false), at: 36) == nil, true,
                    "进度条时长流程: 暂停着不补")

        let before = reads
        let spotify = PlaybackPlayer.spotify.bundleIdentifier
        expectEqual(fill(snap("别家", duration: nil, elapsed: 5, bundleID: spotify), at: 40) == nil, true,
                    "进度条时长流程: 没开开关的播放器原样交回")
        expectEqual(fill(snap("别家", duration: nil, elapsed: 7, bundleID: spotify), at: 42) == nil, true,
                    "进度条时长流程: 没开开关的播放器过了头一秒也不补")
        expectEqual(reads, before, "进度条时长流程: 没开开关的播放器不碰它的界面")
    }

    // ---- 开关与接线 ----
    do {
        expectEqual(PlaybackPlayer.allCases.filter(\.durationFromProgressBar), [.mygoMusic],
                    "进度条时长接线: 只给实测见过的播放器开(MyGo Music 的插件流)")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = source("LyrimuseCore/Local/MediaControlClient.swift")
        expectEqual(client.components(separatedBy: "snapshot = Self.progressBarFilled(snapshot, bundleID: bundleID").count - 1, 1,
                    "进度条时长接线: 主路解码时过一次")
        expectEqual(sourceCount(client, "snapshot = snapshot.map { progressBarFilled($0, bundleID: target.bundleID"), 2,
                    "进度条时长接线: 焦点被占时两处单问(暂停焦点顶替、焦点回退第二级)都过,补上的结果赋回去")
        expectEqual(client.components(separatedBy: "ProgressBarDuration.probedPosition($0, anchorTimestamp: probed.anchor.timestamp").count - 1,
                    2, "进度条时长接线: 单问那份按锚点外推到此刻再核对")
        expectEqual(sourceHas(client, "guard let bundleID, PlaybackPlayer.builtin(forBundleID: bundleID)?.durationFromProgressBar == true"),
                    true, "进度条时长接线: 按播放器开关走,不按 bundle id 写死")
        let core = source("LyrimuseCore/Local/ProgressBarDuration.swift")
        expectEqual(sourceHas(core, "guard fresh, accepts(bar.max, previous: previous) else {"), true,
                    "进度条时长接线: 读数先对过这一刻的位置、再跟上一首比过才采用")
        expectEqual(sourceHas(core, "let fresh = matchesPosition(barValue: bar.value, position: position)"), true,
                    "进度条时长接线: 拿进度条当前值核对位置")
    }
}
