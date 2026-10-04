import Foundation
import LyrimuseCore

/// 播放状态文件(App 写、引擎读):契约样例 / 序号与位置状态机 / 撕裂快照守卫 / 封面标识。
/// 样例 `shared/testdata/playback-state/` 与引擎的 appstate_test.go 共用。
func runPlaybackStateTests() {
    typealias F = PlaybackStateFile

    // ---- 契约样例:解码再编码,逐键与样例一致(字段名拼错一个就对不上) ----
    let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shared/testdata/playback-state")
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    expectEqual(names.count >= 10, true, "播放状态样例: 读得到 shared/testdata/playback-state 下的样例")
    for name in names {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let fixture = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            expectEqual(false, true, "播放状态样例 \(name): 是合法 JSON")
            continue
        }
        let record = try? JSONDecoder().decode(F.Record.self, from: data)
        expectEqual(record != nil, true, "播放状态样例 \(name): App 解得开")
        guard let record, let reencoded = F.encode(record),
              let again = try? JSONSerialization.jsonObject(with: reencoded) as? NSDictionary else { continue }
        expectEqual(again.isEqual(fixture), true, "播放状态样例 \(name): 再编码与样例逐键一致")
    }

    // ---- 序号与位置状态机 ----
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func input(_ title: String = "honeybee", playing: Bool = true, pos: Double?, duration: Double? = 223.5,
               player: String = "com.spotify.client") -> F.Input {
        F.Input(player: player, title: title, artist: "Olivia Rodrigo", album: "you seem pretty sad",
                raw: F.Tags(title: title, artist: "Olivia Rodrigo", album: "you seem pretty sad"),
                appliedFixRev: 0, playing: playing, durationSecs: duration, positionSecs: pos)
    }
    var tracker = F.Tracker()
    let c1 = tracker.advance(input(pos: 0.5), now: t0)
    expectEqual(c1.state, .playing, "播放状态: 在播写 playing")
    expectEqual(c1.track?.playSeq, 1, "播放状态: 第一首 play_seq = 1")
    expectEqual(c1.position?.anchorSeq, 1, "播放状态: 第一份位置 anchor_seq = 1")
    expectEqual(c1.position?.secs, 0.5, "播放状态: 位置原样写出")
    expectEqual(c1.position?.rate, 1, "播放状态: 在播 rate = 1")
    expectEqual(c1.track?.spotifyTrackID, nil, "播放状态: 没有 Spotify 曲目 ID 时不写")
    var spotifyTracker = F.Tracker()
    var withSpotifyID = input(pos: 0.5)
    withSpotifyID.spotifyTrackID = "4iJyoBOLtHqaGxP12qzhQI"
    expectEqual(spotifyTracker.advance(withSpotifyID, now: t0).track?.spotifyTrackID, "4iJyoBOLtHqaGxP12qzhQI",
                "播放状态: Spotify 曲目 ID 原样写进 track")
    var amazonTracker = F.Tracker()
    var withAmazonID = input(pos: 0.5, player: "com.amazon.music")
    withAmazonID.amazonTrackID = "asin://B09GYHYMRR"
    expectEqual(amazonTracker.advance(withAmazonID, now: t0).track?.amazonTrackID, "asin://B09GYHYMRR",
                "播放状态: Amazon 日志曲目标识原样写进 track")
    let c2 = tracker.advance(input(pos: 2.5), now: t0.addingTimeInterval(2))
    expectEqual(c2, c1, "播放状态: 连续播放不重写位置(读方外推),整份内容不变")
    let c3 = tracker.advance(input(pos: 2.6), now: t0.addingTimeInterval(2))
    expectEqual(c3, c1, "播放状态: 差不到 0.25 秒不重写位置")
    let c4 = tracker.advance(input(pos: 6.0), now: t0.addingTimeInterval(4))
    expectEqual(c4.position?.anchorSeq, 2, "播放状态: 位置跳了 1.5 秒,anchor_seq 加一")
    expectEqual(c4.position?.secs, 6.0, "播放状态: 跳变后写新位置")
    expectEqual(c4.track?.playSeq, 1, "播放状态: 位置跳变不算重新起播")
    let c5 = tracker.advance(input(playing: false, pos: 7.5), now: t0.addingTimeInterval(6))
    expectEqual(c5.state, .paused, "播放状态: 暂停写 paused")
    expectEqual(c5.position?.rate, 0, "播放状态: 暂停 rate = 0")
    expectEqual(c5.position?.anchorSeq, 3, "播放状态: 暂停(速率变了)anchor_seq 加一")
    let idle = tracker.advance(.idle(), now: t0.addingTimeInterval(8))
    expectEqual(idle, .idle, "播放状态: 没有曲目写 idle")
    let c6 = tracker.advance(input(pos: 7.5), now: t0.addingTimeInterval(20))
    expectEqual(c6.track?.playSeq, 1, "播放状态: 停播后回到同一首,play_seq 不加(会话续接交给引擎)")
    expectEqual(c6.position?.anchorSeq, 4, "播放状态: 停播后回来重新写位置")
    let c7 = tracker.advance(input("stupid song", pos: 0.2), now: t0.addingTimeInterval(30))
    expectEqual(c7.track?.playSeq, 2, "播放状态: 换歌 play_seq 加一")
    expectEqual(c7.position?.anchorSeq, 5, "播放状态: 换歌重写位置")
    // 单曲循环:上一拍已过 90%,这一拍回到开头 10 秒内。
    _ = tracker.advance(input("stupid song", pos: 205, duration: 210), now: t0.addingTimeInterval(240))
    let loop = tracker.advance(input("stupid song", pos: 1.5, duration: 210), now: t0.addingTimeInterval(246))
    expectEqual(loop.track?.playSeq, 3, "播放状态: 单曲循环重新起播 play_seq 加一")
    let seekBack = tracker.advance(input("stupid song", pos: 3, duration: 210), now: t0.addingTimeInterval(250))
    expectEqual(seekBack.track?.playSeq, 3, "播放状态: 起播之后再往回拖一点不算重新起播")
    expectEqual(F.Tracker.loopRestarted(previous: 100, current: 3, durationSecs: 210, playing: true), false,
                "播放状态: 从中段拖回开头不算单曲循环")
    expectEqual(F.Tracker.loopRestarted(previous: 200, current: 210, durationSecs: 210, playing: true), false,
                "播放状态: 位置到了 / 越过曲长不算重新起播,要真回到开头")
    var stuck = F.Tracker()
    _ = stuck.advance(input("ring finger", pos: 270, duration: 284), now: t0)
    let stuckSeqs = (1...5).map { i in
        stuck.advance(input("ring finger", pos: 284 + Double(i), duration: 284), now: t0.addingTimeInterval(Double(i) * 2)).track?.playSeq
    }
    expectEqual(Set(stuckSeqs), [1], "播放状态: 位置读数卡在曲末连着几拍,play_seq 不动")
    expectEqual(F.Tracker.loopRestarted(previous: 200, current: 2, durationSecs: 210, playing: false), false,
                "播放状态: 暂停中不判单曲循环")
    expectEqual(F.Tracker.loopRestarted(previous: 200, current: 2, durationSecs: nil, playing: true), false,
                "播放状态: 不知道曲长不判单曲循环")
    // 在播但还没有位置(没有时长的那一拍)。
    var fresh = F.Tracker()
    let noPos = fresh.advance(input(pos: nil, duration: nil), now: t0)
    expectEqual(noPos.position == nil, true, "播放状态: 没有位置就不写位置")
    expectEqual(noPos.track?.playSeq, 1, "播放状态: 没有位置照样认曲目")
    let firstPos = fresh.advance(input(pos: 1.0), now: t0.addingTimeInterval(1))
    expectEqual(firstPos.position?.anchorSeq, 1, "播放状态: 有了位置就写第一份")

    // ---- 封面标识带着当时的 play_seq ----
    var art = F.Tracker()
    _ = art.advance(input(pos: 0.5), now: t0)
    art.noteArtwork(sha256: "aa", mime: "image/jpeg", bytes: 10)
    expectEqual(art.currentArtwork?.playSeq, 1, "播放状态: 封面记着它属于哪一首")
    let afterSwitch = art.advance(input("stupid song", pos: 0.1), now: t0.addingTimeInterval(5))
    expectEqual(afterSwitch.artwork?.playSeq, 1, "播放状态: 换歌后新封面没到时,旧封面的 play_seq 还是上一首")
    expectEqual(afterSwitch.track?.playSeq, 2, "播放状态: 读方据 play_seq 不一致认出封面属于上一首")
    art.noteArtwork(sha256: nil, mime: "", bytes: 0)
    expectEqual(art.currentArtwork == nil, true, "播放状态: 确认没有封面就清掉")

    // ---- 顶层记录 ----
    let rec = F.Record(content: c1, appPID: 4321, appStartedAtMs: 1_790_000_000_000, seq: 1, writtenAtMs: 1_790_000_000_100)
    let recJSON = F.encode(rec).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    expectEqual(recJSON["schema"] as? Int, F.schema, "播放状态: 记录带契约版本")
    expectEqual(recJSON["holding"] == nil, true, "播放状态: 不在按住时不写 holding")
    var held = c1
    held.holding = true
    let heldJSON = F.encode(F.Record(content: held, appPID: 1, appStartedAtMs: 1, seq: 2, writtenAtMs: 2))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    expectEqual(heldJSON["holding"] as? Bool, true, "播放状态: 按住上一份状态时写 holding = true")
    let exitJSON = F.encode(F.Record(content: .exiting, appPID: 1, appStartedAtMs: 1, seq: 3, writtenAtMs: 3))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    expectEqual(exitJSON["state"] as? String, "exiting", "播放状态: 退出写 exiting")
    expectEqual(exitJSON["track"] == nil, true, "播放状态: 退出不带曲目")

    // ---- 撕裂快照守卫 ----
    typealias T = TornTrackHold
    let cur = T.Fields(title: "Song A", artist: "Singer", album: "Album", bundle: "com.apple.Music", duration: 200, isRadio: false)
    var torn = cur
    torn.title = "Song B"
    expectEqual(T.isTorn(current: cur, next: torn), true, "撕裂快照: 只换了标题、其余逐位不变")
    var other = torn
    other.duration = 180
    expectEqual(T.isTorn(current: cur, next: other), false, "撕裂快照: 时长也换了就是真换歌")
    other = torn
    other.artist = "Other"
    expectEqual(T.isTorn(current: cur, next: other), false, "撕裂快照: 歌手也换了就是真换歌")
    other = torn
    other.isRadio = true
    expectEqual(T.isTorn(current: cur, next: other), false, "撕裂快照: 电台不参与判定")
    var noArtist = cur
    noArtist.artist = ""
    var noArtistNext = noArtist
    noArtistNext.title = "Song B"
    expectEqual(T.isTorn(current: noArtist, next: noArtistNext), false, "撕裂快照: 上一首没有歌手不判")
    expectEqual(T.isTorn(current: cur, next: cur), false, "撕裂快照: 标题没变不判")
    // 真机:Kaset 广告放完、正片开始那一拍把歌名改成网页写法,时长、署名都没变(放的是 418 秒的 MV)。
    let kasetBefore = T.Fields(title: "太陽之子", artist: "周杰伦", album: "", bundle: PlaybackPlayer.kaset.bundleIdentifier,
                               duration: 418.14, isRadio: false)
    var kasetAfter = kasetBefore
    kasetAfter.title = "Children of the Sun 太陽之子"
    expectEqual(T.isTorn(current: kasetBefore, next: kasetAfter), false, "撕裂快照: Kaset 的快照整份读来,改名不按住")
    var kasetHold = T()
    expectEqual(kasetHold.decide(current: kasetBefore, next: kasetAfter, now: t0), .accept, "撕裂快照: Kaset 改名当场采纳")
    var hold = T()
    expectEqual(hold.decide(current: cur, next: torn, now: t0), .holdStarted, "撕裂快照: 第一拍开始按住")
    expectEqual(hold.decide(current: cur, next: torn, now: t0.addingTimeInterval(5)), .holding, "撕裂快照: 12 秒内继续按住")
    expectEqual(hold.decide(current: cur, next: torn, now: t0.addingTimeInterval(12)), .released, "撕裂快照: 按满 12 秒放行")
    expectEqual(hold.decide(current: nil, next: torn, now: t0), .accept, "撕裂快照: 没有上一首直接采纳")
    var hold2 = T()
    _ = hold2.decide(current: cur, next: torn, now: t0)
    expectEqual(hold2.decide(current: cur, next: other, now: t0.addingTimeInterval(1)), .accept,
                "撕裂快照: 形态解除立即放行")

    // ---- 放歌时持有系统活动(防 App Nap 推迟保活),别的状态不持有(02 章决策 89)----
    expectEqual(PlaybackStatePublisher.holdsActivity(for: .playing), true, "防节能: 放歌时持有活动")
    for state in [F.State.paused, .idle, .exiting] {
        expectEqual(PlaybackStatePublisher.holdsActivity(for: state), false, "防节能: \(state.rawValue) 不持有")
    }
    let publisherSource = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("LyrimuseCore/Local/PlaybackStateFile.swift"), encoding: .utf8)) ?? ""
    expectEqual(publisherSource.contains("options: .userInitiatedAllowingIdleSystemSleep"), true,
                "防节能: 活动只免 App Nap(.userInitiatedAllowingIdleSystemSleep)")
    expectEqual(publisherSource.contains("options: .userInitiated,") || publisherSource.contains("idleSystemSleepDisabled"), false,
                "防节能: 不拦系统空闲睡眠")

    // ---- 封面文件的类型与校验和 ----
    expectEqual(F.artworkMime(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])), "image/jpeg", "封面类型: JPEG")
    expectEqual(F.artworkMime(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])), "image/png", "封面类型: PNG")
    expectEqual(F.artworkMime(Data([0x00, 0x01])), "application/octet-stream", "封面类型: 认不出")
    expectEqual(F.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "封面校验和: SHA-256 小写十六进制")
}
