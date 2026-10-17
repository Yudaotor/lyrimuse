import Foundation
import LyrimuseCore

// ---- 位置状态机回放 ----
// 把一串快照(外加暂停 / 恢复通知)按时间喂给一个独立的 LocalPlaybackSource,断言屏上位置、
// 暂停残差、偏置与学习表。外部依赖全换成内存里的假实现(PlaybackPositionEnvironment):
// 学习表写进一个每个场景单独清空的 UserDefaults 套件,偏置文件只记在数组里,两个探针的读数由场景给。
// 场景里的数字取自 02 章记录的真机样本。

@MainActor
private final class ReplayRig {
    let suite: String
    let defaults: UserDefaults
    var biasWrites: [PositionBiasRecord] = []
    /// 网页探针下一次交出的读数:从 `readyAt` 起可消费一次,值按消费时刻算。
    var browserCorrection: (key: String, readyAt: Date, isPrecise: Bool, value: (Date) -> Double)?
    var browserReopened: [String] = []
    /// 网页探针收到的「换歌」通知(新 key),见 BrowserPositionProbe.trackChanged。
    var browserTrackChanges: [String] = []
    /// 最近到达的锚点是不是在暂停中发布的(线上由 stream watcher 记,见 MediaControlClient.latestAnchorPublishedWhilePaused)。
    var anchorPublishedWhilePaused = false
    var route: AudioOutputRoute.Current?
    /// 洛雪配置里的播放速度(线上读 `config_v2.json`,见 LXMusicPlaybackRate)。
    var lxRate: LXMusicPlaybackRate.Setting?
    /// 洛雪开放 API 推来的状态(线上由 LXMusicOpenAPI 订阅攒出来)。
    var lxAPI: LXMusicOpenAPI.State?
    private(set) var source: LocalPlaybackSource!

    init(_ name: String) {
        suite = "lyrimuse-selftest.position-replay.\(name)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let env = PlaybackPositionEnvironment(
            defaults: defaults,
            readPositionBias: { nil },
            writePositionBias: { [unowned self] in self.biasWrites.append($0) },
            outputRoute: { [unowned self] in self.route },
            browserProbeTrackChanged: { [unowned self] _, to in self.browserTrackChanges.append(to) },
            browserProbeKick: { _, _, _ in },
            browserProbeConsume: { [unowned self] key, _, now in
                guard let c = self.browserCorrection, c.key == key, now >= c.readyAt else { return nil }
                self.browserCorrection = nil
                return BrowserPositionProbe.Correction(seconds: c.value(now), isPrecise: c.isPrecise)
            },
            browserProbeReopenAfterResume: { [unowned self] in self.browserReopened.append($0) },
            spotifyProbeTrackChanged: { _, _ in },
            spotifyProbeConsume: { _, _, _ in nil },
            spotifyProbeRequestConfirmation: { _ in },
            latestAnchorPublishedWhilePaused: { [unowned self] in self.anchorPublishedWhilePaused },
            lxMusicPlaybackRate: { [unowned self] in self.lxRate },
            lxMusicOpenAPI: { [unowned self] active in active ? self.lxAPI : nil })
        source = LocalPlaybackSource.makeForPositionReplay(environment: env)
    }

    func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func tick(_ snapshot: MediaControlSnapshot, at now: Date, isAdBreak: Bool = false) {
        source.replayPosition(snapshot, now: now, isAdBreak: isAdBreak)
    }

    func shown(at now: Date) -> Double? { source.replayPositionMs(at: now).map { Double($0) / 1000 } }

    var startLeadTable: [String: Double] {
        defaults.dictionary(forKey: "np:spotifyStartLeadByKind") as? [String: Double] ?? [:]
    }
}

private let replayT0 = Date(timeIntervalSince1970: 1_790_300_000)
private func at(_ s: Double) -> Date { replayT0.addingTimeInterval(s) }
/// 位置断言统一用毫秒取整后的差,容差 `tol` 秒。
private func near(_ actual: Double?, _ expected: Double, _ tol: Double = 0.02) -> Bool {
    guard let actual else { return false }
    return abs(actual - expected) <= tol
}

private let spotifyID = PlaybackPlayer.spotify.bundleIdentifier

/// Spotify AppleScript 那份读数:读的是它自己的钟,没有锚点信息。
private func spotify(_ title: String, artist: String = "陶喆", raw: Double, duration: Double, playing: Bool = true) -> MediaControlSnapshot {
    .forReplay(title: title, artist: artist, album: "黑色柳丁", duration: duration, elapsedTime: raw,
               playing: playing, playbackRate: playing ? 1 : 0, bundleIdentifier: spotifyID, anchorElapsedTime: nil)
}

private let safariMediaID = "com.apple.WebKit.GPU"

/// media-control 那份读数:`elapsed` 是按锚点外推到读数那一刻的值,`anchor` 是原始锚点 elapsed。
private func mediaControl(_ bundle: String, _ title: String, anchor: Double, elapsed: Double, duration: Double,
                          playing: Bool = true, capturedAt: Date? = nil) -> MediaControlSnapshot {
    .forReplay(title: title, artist: "Fujii Kaze", album: "Prema", duration: duration, elapsedTime: elapsed,
               playing: playing, playbackRate: playing ? 1 : 0, bundleIdentifier: bundle, anchorElapsedTime: anchor,
               capturedAt: capturedAt)
}

@MainActor
func runPositionReplayTests() {
    replaySpotifyManualStart()
    replaySpotifyAfterAd()
    replaySpotifySameTrackJump()
    replaySpotifyStartLeadMigration()
    replaySpotifyLateResume()
    replaySafariResumeStall()
    replaySafariFloorReadingIgnored()
    replaySafariPreciseReadingOverNaturalBias()
    replayCaptureLag()
    replaySodaAnchorLag()
    replayBrowserProbeReopensOnEveryTrackChange()
    replayQQEarlyStartAnchor()
    replayQQEarlyStartGates()
    replayQQTrackEndZeroHold()
    replayQQPauseHoldsShown()
    replayQQTickAnchor()
    replayQQSameStartAnchorNotEarly()
    replayQQFlooredSeek()
    replayQQResumeAudioLag()
    replayReampResumeAnchorDistrusted()
    replayReampRestartFromTop()
    replayQQStartFromPaused()
    replayQQResumeToOtherTrack()
    replayQQLateZeroAnchor()
    replayNeteaseLateStartAnchor()
    replayKugouLateStartAnchor()
    replayLXMusicLateStartLeadHolds()
    replayLXMusicColdResume()
    replayLXMusicColdResumeStale()
    replayLXMusicRateChange()
    replayLXMusicOpenAPIClock()
    replayKKBOXFollowsRepublishedAnchor()
    replayKKBOXPauseHoldsUntilPauseAnchor()
    replayKKBOXStallHolds()
    replayKasetFollowsWebClock()
    replayKasetResumeTakesReading()
    replayPausedHelperWithResidualRate()
    replayAmazonFocusFallbackKeepsLogClock()
}

/// Amazon Music 焦点被别的 App 占走(浏览器里开视频)时,回退按 bundle id 单问到的那份换成日志时钟(`withPlayerClock`),
/// 屏上接着走;单问那份原样(没有进度)交下去的话,62 秒那拍起屏上从 0 重新走。真值 = 开播后的秒数。
@MainActor
private func replayAmazonFocusFallbackKeepsLogClock() {
    let rig = ReplayRig("amazon-focus-fallback")
    defer { rig.tearDown() }
    let amazonID = PlaybackPlayer.amazonMusic.bundleIdentifier
    func clocked(_ t: Double) -> MediaControlSnapshot {
        .forReplay(title: "夜曲", artist: "周杰伦", duration: 226, elapsedTime: t, playing: true,
                   bundleIdentifier: amazonID, anchorElapsedTime: t, capturedAt: at(t))
    }
    for t in stride(from: 2.0, through: 60, by: 2) { rig.tick(clocked(t), at: at(t)) }
    let probed = MediaControlSnapshot.forReplay(
        title: "夜曲", artist: "周杰伦", duration: 226, elapsedTime: nil, playing: true,
        bundleIdentifier: amazonID, anchorElapsedTime: nil)
    for t in stride(from: 62.0, through: 76, by: 2) { rig.tick(probed.withPlayerClock(t, capturedAt: at(t)), at: at(t)) }
    expectEqual(near(rig.shown(at: at(77)), 77, 0.1), true,
                "回放·Amazon 焦点回退: 日志时钟那份接着走(\(rig.shown(at: at(77)).map { String(format: "%.3f", $0) } ?? "nil"))")
    for t in stride(from: 78.0, through: 90, by: 2) { rig.tick(clocked(t), at: at(t)) }
    expectEqual(near(rig.shown(at: at(91)), 91, 0.1), true, "回放·Amazon 焦点回退: 焦点回来后无缝接上")
}

/// Kaset 的读数不会超前声音,恢复那一拍原样采信:换歌后先报加载(停在 0),走起来的第一拍已经是 2.67 秒;
/// 曲中暂停在 41.67,恢复时读数已经是 44.5(比冻结值多出 2 秒以上)。别的播放器这两拍都会被削到冻结值 + 2 秒。
@MainActor
private func replayKasetResumeTakesReading() {
    let rig = ReplayRig("kaset-resume")
    defer { rig.tearDown() }
    func kaset(_ title: String, _ elapsed: Double, playing: Bool, _ t: Double) -> MediaControlSnapshot {
        .forReplay(title: title, artist: "周杰倫", duration: 212.6, elapsedTime: elapsed, playing: playing,
                   playbackRate: playing ? 1 : 0, bundleIdentifier: kasetID, anchorElapsedTime: nil, capturedAt: at(t))
    }
    func shown(_ t: Double) -> String { rig.shown(at: at(t)).map { String(format: "%.3f", $0) } ?? "nil" }
    rig.tick(kaset("甲", 190, playing: true, 0), at: at(0))
    rig.tick(kaset("乙", 0, playing: false, 2), at: at(2))
    rig.tick(kaset("乙", 2.67, playing: true, 5), at: at(5))
    expectEqual(near(rig.shown(at: at(5)), 2.67), true, "回放·Kaset 开播: 走起来的第一拍原样采信(\(shown(5)))")
    rig.tick(kaset("乙", 41.67, playing: true, 44), at: at(44))
    rig.tick(kaset("乙", 41.67, playing: false, 46), at: at(46))
    rig.tick(kaset("乙", 44.5, playing: true, 52), at: at(52))
    expectEqual(near(rig.shown(at: at(52)), 44.5), true, "回放·Kaset 恢复: 恢复那一拍原样采信(\(shown(52)))")
}

private let kasetID = PlaybackPlayer.kaset.bundleIdentifier

/// Kaset:头两拍只有它自己的读数(比真值晚 0.165 秒);之后在走的拍位置来自内嵌网页那份会话的播放时钟(精确),第一拍
/// 就对齐真值;中间夹一拍那份时钟用不上、退回 Kaset 自己的读数(晚 0.4 秒),屏上不被拽回去;网页时钟比屏上晚不到
/// 0.1 秒时不重锚;某一拍 Kaset 的读数记早了、屏上跟着快了 0.25 秒,下一拍网页时钟把它拉回真值(前向棘轮只往前追,
/// 往回拉只有精确真值那条通道做得到)。真值 = 开播后的秒数。
@MainActor
private func replayKasetFollowsWebClock() {
    let rig = ReplayRig("kaset-web-clock")
    defer { rig.tearDown() }
    func kaset(_ elapsed: Double, precise: Bool, _ t: Double) -> MediaControlSnapshot {
        .forReplay(title: "太陽之子", artist: "周杰伦", duration: 418.14, elapsedTime: elapsed, playing: true,
                   bundleIdentifier: kasetID, anchorElapsedTime: nil, capturedAt: at(t), positionIsPrecise: precise ? true : nil)
    }
    func shown(_ t: Double) -> String { rig.shown(at: at(t)).map { String(format: "%.3f", $0) } ?? "nil" }
    rig.tick(kaset(1 - 0.165, precise: false, 1), at: at(1))
    rig.tick(kaset(3 - 0.165, precise: false, 3), at: at(3))
    expectEqual(near(rig.shown(at: at(3)), 2.835), true, "回放·Kaset: 只有它自己的读数时晚 0.165 秒(\(shown(3)))")
    rig.tick(kaset(5, precise: true, 5), at: at(5))
    expectEqual(near(rig.shown(at: at(5)), 5), true, "回放·Kaset: 换成网页时钟第一拍就对齐真值(\(shown(5)))")
    rig.tick(kaset(7, precise: true, 7), at: at(7))
    rig.tick(kaset(9 - 0.4, precise: false, 9), at: at(9))
    expectEqual(near(rig.shown(at: at(9.5)), 9.5), true, "回放·Kaset: 夹一拍退回它自己的读数(晚 0.4 秒)不被拽回去(\(shown(9.5)))")
    rig.tick(kaset(11 - 0.05, precise: true, 11), at: at(11))
    expectEqual(near(rig.shown(at: at(11)), 11), true, "回放·Kaset: 网页时钟只晚 0.05 秒不重锚(\(shown(11)))")
    rig.tick(kaset(13, precise: true, 13), at: at(13))
    expectEqual(near(rig.shown(at: at(13)), 13), true, "回放·Kaset: 之后照旧跟着网页时钟(\(shown(13)))")
    rig.tick(kaset(15 + 0.25, precise: false, 15), at: at(15))
    expectEqual(near(rig.shown(at: at(15)), 15.25), true, "回放·Kaset: 某一拍它自己的读数记早了,棘轮跟上去、屏上快 0.25 秒(\(shown(15)))")
    rig.tick(kaset(17, precise: true, 17), at: at(17))
    expectEqual(near(rig.shown(at: at(17)), 17), true, "回放·Kaset: 网页时钟把屏上拉回真值(\(shown(17)))")
}

private let qqID = PlaybackPlayer.qqMusic.bundleIdentifier

/// QQ 开播锚点比出声早 0.48 秒(真机《Silver Lining》:`0@T0`,1.48 秒后补 `1.000` 那个锚点,真起点 = 补的那个 − 1):
/// 补的锚点一到就对齐,之后整首按它走;开播那条一首只对齐一次,之后曲中的整秒锚点按决策 118 照常纠。网易云同一串读数照旧(对照)。
@MainActor
private func replayQQEarlyStartAnchor() {
    for (bundle, corrects) in [(qqID, true), (PlaybackPlayer.netease.bundleIdentifier, false)] {
        let rig = ReplayRig("qq-early-start-\(corrects)")
        defer { rig.tearDown() }
        func shown(_ t: Double) -> String { rig.shown(at: at(t)).map { String(format: "%.3f", $0) } ?? "nil" }
        rig.tick(mediaControl(bundle, "Silver Lining", anchor: 0, elapsed: 0.4, duration: 233), at: at(0.4))
        for t in stride(from: 1.6, through: 20, by: 2) {
            rig.tick(mediaControl(bundle, "Silver Lining", anchor: 1, elapsed: 1 + (t - 1.48), duration: 233), at: at(t))
        }
        if corrects {
            expectEqual(near(rig.shown(at: at(20)), 19.52), true, "回放·QQ 开播早打: 补的锚点一到就对齐(\(shown(20)))")
            for t in stride(from: 21.6, through: 26, by: 2) {
                rig.tick(mediaControl(bundle, "Silver Lining", anchor: 20, elapsed: 20 + (t - 20.88), duration: 233), at: at(t))
            }
            expectEqual(near(rig.shown(at: at(26)), 25.12, 0.02), true, "回放·QQ 开播早打: 之后曲中的整秒锚点照常纠(\(shown(26)))")
        } else {
            expectEqual(near(rig.shown(at: at(20)), 20), true, "回放·网易云: 同一串读数照旧按开播锚点走(\(shown(20)))")
        }
    }
}

/// QQ 开播早打那条只管「从开播锚点一路外推下来」的歌:中途接手(App 重启时歌已经放到 50 秒)的不动;
/// 起点准时、整秒跳变那一刻少报一秒(落后整 1 秒)的锚点也不采信。
@MainActor
private func replayQQEarlyStartGates() {
    let midway = ReplayRig("qq-early-start-midway")
    defer { midway.tearDown() }
    midway.tick(mediaControl(qqID, "哎呀 爱呀", anchor: 50, elapsed: 50, duration: 192), at: at(0))
    midway.tick(mediaControl(qqID, "哎呀 爱呀", anchor: 51, elapsed: 51.6, duration: 192), at: at(2))
    expectEqual(near(midway.shown(at: at(2)), 52), true,
                "回放·QQ 中途接手: 落后 0.4 不对齐(\(midway.shown(at: at(2)).map { String(format: "%.3f", $0) } ?? "nil"))")

    let oneLess = ReplayRig("qq-early-start-one-less")
    defer { oneLess.tearDown() }
    oneLess.tick(mediaControl(qqID, "醉", anchor: 0, elapsed: 0.3, duration: 266), at: at(0.3))
    oneLess.tick(mediaControl(qqID, "醉", anchor: 0, elapsed: 2, duration: 266), at: at(2))
    oneLess.tick(mediaControl(qqID, "醉", anchor: 8, elapsed: 8, duration: 266), at: at(9))
    expectEqual(near(oneLess.shown(at: at(9)), 9), true,
                "回放·QQ 少报一秒: 落后整 1 秒的锚点不采信(\(oneLess.shown(at: at(9)).map { String(format: "%.3f", $0) } ?? "nil"))")
}

/// QQ 自然放完:旧歌名下先发 `elapsed=0`,约 0.5 秒后才换歌名。这段按住旧歌的位置(停在曲长),不写成「同一首从头放」;
/// 1.5 秒后还是这一首才当成重播。网易云同一串读数照旧当场跳回开头(对照)。见 02 章决策 118。
@MainActor
private func replayQQTrackEndZeroHold() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    for (bundle, holds) in [(qqID, true), (PlaybackPlayer.netease.bundleIdentifier, false)] {
        let rig = ReplayRig("qq-end-zero-\(holds)")
        defer { rig.tearDown() }
        for t in stride(from: 0.0, through: 6, by: 2) {
            rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 220, elapsed: 220 + t, duration: 226), at: at(t))
        }
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 0, elapsed: 0.05, duration: 226), at: at(6.3))
        if holds {
            expectEqual(near(rig.shown(at: at(6.3)), 226, 0.05), true, "回放·QQ 曲尾归零: 换歌名之前停在曲尾(\(fmt(rig.shown(at: at(6.3)))))")
            rig.tick(mediaControl(bundle, "再见以前先说再见", anchor: 0, elapsed: 0.05, duration: 272), at: at(6.8))
            expectEqual(near(rig.shown(at: at(7.8)), 1.05, 0.05), true, "回放·QQ 曲尾归零: 换了歌名照常从开头走(\(fmt(rig.shown(at: at(7.8)))))")
        } else {
            expectEqual(near(rig.shown(at: at(6.3)), 0.05, 0.05), true, "回放·网易云: 照旧跳回开头(\(fmt(rig.shown(at: at(6.3)))))")
        }
    }
    let loop = ReplayRig("qq-end-zero-loop")
    defer { loop.tearDown() }
    for t in stride(from: 0.0, through: 6, by: 2) {
        loop.tick(mediaControl(qqID, "A.I.N.Y.", anchor: 220, elapsed: 220 + t, duration: 226), at: at(t))
    }
    loop.tick(mediaControl(qqID, "A.I.N.Y.", anchor: 0, elapsed: 0.05, duration: 226), at: at(6.3))
    loop.tick(mediaControl(qqID, "A.I.N.Y.", anchor: 0, elapsed: 0.85, duration: 226), at: at(7.1))
    loop.tick(mediaControl(qqID, "A.I.N.Y.", anchor: 0, elapsed: 1.65, duration: 226), at: at(7.9))
    expectEqual(near(loop.shown(at: at(7.9)), 1.65, 0.05), true, "回放·QQ 真重播: 1.5 秒后还是这一首就从开头走(\(fmt(loop.shown(at: at(7.9)))))")
}

/// QQ 暂停:暂停事件冻住外推,快照里还是之前的锚点(没重发)→ 停在屏上位置;之后补发的下取整值不换,暂停中拖到别处的换。
/// 酷狗照旧按快照冻结值(对照)。见 02 章决策 118。
@MainActor
private func replayQQPauseHoldsShown() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    for (bundle, holds) in [(qqID, true), (PlaybackPlayer.kugou.bundleIdentifier, false)] {
        let rig = ReplayRig("qq-pause-hold-\(holds)")
        defer { rig.tearDown() }
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 109, elapsed: 109, duration: 226), at: at(0))
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 109, elapsed: 110, duration: 226), at: at(1))
        rig.source.replayPlayerStateEvent(at: at(1.3), freeze: true)
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 109, elapsed: 109, duration: 226, playing: false), at: at(1.4))
        let paused = rig.source.pausedPositionMs.map { Double($0) / 1000 }
        if holds {
            expectEqual(near(paused, 110.3, 0.03), true, "回放·QQ 暂停: 不退回旧锚点 109,停在屏上 110.3(\(fmt(paused)))")
            rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 110, elapsed: 110, duration: 226, playing: false), at: at(1.6))
            let floored = rig.source.pausedPositionMs.map { Double($0) / 1000 }
            expectEqual(near(floored, 110.3, 0.03), true, "回放·QQ 暂停: 补发的下取整值 110 不换(\(fmt(floored)))")
            rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 150, elapsed: 150, duration: 226, playing: false), at: at(5))
            let moved = rig.source.pausedPositionMs.map { Double($0) / 1000 }
            expectEqual(near(moved, 150, 0.03), true, "回放·QQ 暂停: 暂停中拖到 150 照换(\(fmt(moved)))")
        } else {
            expectEqual(near(paused, 109, 0.03), true, "回放·酷狗 暂停: 照旧按快照冻结值(\(fmt(paused)))")
        }
    }
}

/// QQ 同一首放完又重播:起点按 0 锚点、实际超前 0.36;之后 QQ 在整秒跳变那一刻重发的锚点(少报一秒的 8@9.36、准的 11@11.36)
/// 一到就对齐,两种都折成超前 0.36。重播后 2.5 秒之内的锚点不看。网易云不动(对照)。见 02 章决策 118。
@MainActor
private func replayQQTickAnchor() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    for (bundle, corrects) in [(qqID, true), (PlaybackPlayer.netease.bundleIdentifier, false)] {
        let rig = ReplayRig("qq-tick-anchor-\(corrects)")
        defer { rig.tearDown() }
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 0, elapsed: 0.02, duration: 226), at: at(0.02))
        for t in stride(from: 2.0, through: 8, by: 2) {
            rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 0, elapsed: t, duration: 226), at: at(t))
        }
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 8, elapsed: 8.04, duration: 226), at: at(9.4))
        let shown = rig.shown(at: at(9.4))
        if corrects {
            expectEqual(near(shown, 9.04, 0.02), true, "回放·QQ 整秒锚点: 少报一秒的锚点也折成超前 0.36 对齐(\(fmt(shown)))")
            rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 11, elapsed: 11.2, duration: 226), at: at(11.56))
            expectEqual(near(rig.shown(at: at(11.56)), 11.2, 0.03), true, "回放·QQ 整秒锚点: 对齐之后下一个准锚点不再动(\(fmt(rig.shown(at: at(11.56)))))")
        } else {
            expectEqual(near(shown, 9.4, 0.02), true, "回放·网易云: 不按整秒锚点纠(\(fmt(shown)))")
        }
    }
    let early = ReplayRig("qq-tick-anchor-settle")
    defer { early.tearDown() }
    early.tick(mediaControl(qqID, "A.I.N.Y.", anchor: 50, elapsed: 50, duration: 226), at: at(0))
    early.tick(mediaControl(qqID, "A.I.N.Y.", anchor: 51, elapsed: 51.64, duration: 226), at: at(2))
    expectEqual(near(early.shown(at: at(2)), 52, 0.02), true, "回放·QQ 整秒锚点: 接手后 2.5 秒之内的锚点不看(\(fmt(early.shown(at: at(2)))))")
}

/// 开播锚点没换,读数只是口径变了一点(落后 0.158),决策 115 那条不该采信:要 QQ 发了值不小于 1 的新锚点才看。
@MainActor
private func replayQQSameStartAnchorNotEarly() {
    let rig = ReplayRig("qq-same-start-anchor")
    defer { rig.tearDown() }
    rig.tick(mediaControl(qqID, "KID AGAIN", anchor: 0, elapsed: 0.3, duration: 200), at: at(0.3))
    for t in stride(from: 2.0, through: 12, by: 2) {
        rig.tick(mediaControl(qqID, "KID AGAIN", anchor: 0, elapsed: t, duration: 200), at: at(t))
    }
    rig.tick(mediaControl(qqID, "KID AGAIN", anchor: 0, elapsed: 13.842, duration: 200), at: at(14))
    expectEqual(near(rig.shown(at: at(14)), 14, 0.02), true,
                "回放·QQ 同一个开播锚点: 读数口径变了不当成打早(\(rig.shown(at: at(14)).map { String(format: "%.3f", $0) } ?? "nil"))")
}

/// 在 QQ 里拖动:报的锚点是下取整的(拖到 89.9 报 89),按中点补半秒。网易云不补(对照)。见 02 章决策 118。
@MainActor
private func replayQQFlooredSeek() {
    for (bundle, adds) in [(qqID, true), (PlaybackPlayer.netease.bundleIdentifier, false)] {
        let rig = ReplayRig("qq-floored-seek-\(adds)")
        defer { rig.tearDown() }
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 40, elapsed: 40, duration: 226), at: at(0))
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 40, elapsed: 42, duration: 226), at: at(2))
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 89, elapsed: 89, duration: 226), at: at(4))
        expectEqual(near(rig.shown(at: at(4)), adds ? 89.5 : 89, 0.02), true,
                    "回放·\(adds ? "QQ" : "网易云") 拖动: \(adds ? "下取整的锚点补半秒" : "不补")(\(rig.shown(at: at(4)).map { String(format: "%.3f", $0) } ?? "nil"))")
    }
}

/// QQ 恢复:报在放之后约 0.12 秒才出声,起点按「冻结值 + 恢复信号至今 − 0.12」。酷狗照旧(对照)。见 02 章决策 118。
@MainActor
private func replayQQResumeAudioLag() {
    for (bundle, lag) in [(qqID, 0.12), (PlaybackPlayer.kugou.bundleIdentifier, 0.0)] {
        let rig = ReplayRig("qq-resume-lag-\(lag)")
        defer { rig.tearDown() }
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 30, elapsed: 30, duration: 226), at: at(0))
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 30, elapsed: 32, duration: 226), at: at(2))
        rig.source.replayPlayerStateEvent(at: at(3), freeze: true)
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 30, elapsed: 33, duration: 226, playing: false), at: at(3.1))
        rig.source.replayResumeSignal(at: at(10))
        rig.tick(mediaControl(bundle, "A.I.N.Y.", anchor: 30, elapsed: 40.3, duration: 226), at: at(10.3))
        expectEqual(near(rig.shown(at: at(10.3)), 33.3 - lag, 0.02), true,
                    "回放·\(lag > 0 ? "QQ" : "酷狗") 恢复: 起点扣 \(lag) 秒出声延迟(\(rig.shown(at: at(10.3)).map { String(format: "%.3f", $0) } ?? "nil"))")
    }
}

/// reAMP 恢复:先报进度 0,约 0.6 秒后补报一份比真声慢 0.5 秒的锚点。屏上按暂停位置接着走,不被伺服拽到那份锚点上
/// (伺服 1 秒一拍时第 5 拍就会跟过去);之后拖动换了锚点照常采信。见 02 章决策 126。
@MainActor
private func replayReampResumeAnchorDistrusted() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    let reamp = PlaybackPlayer.reamp.bundleIdentifier
    let rig = ReplayRig("reamp-resume-anchor")
    defer { rig.tearDown() }
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 20, elapsed: 20, duration: 150), at: at(0))
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 20, elapsed: 28, duration: 150), at: at(8))
    rig.source.replayPlayerStateEvent(at: at(8.9), freeze: true)
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 28.9, elapsed: 28.9, duration: 150, playing: false), at: at(9))
    rig.source.replayResumeSignal(at: at(10))
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 0, elapsed: 0.27, duration: 150), at: at(10.27))
    guard let seeded = rig.shown(at: at(10.27)) else {
        expectEqual(false, true, "回放·reAMP 恢复: 恢复那一拍屏上没有位置")
        return
    }
    expectEqual(seeded > 28.9 && seeded < 29.2, true, "回放·reAMP 恢复: 先报 0 时按暂停位置接着走(\(fmt(seeded)))")
    for t in stride(from: 10.6, through: 20.6, by: 1) {
        rig.tick(mediaControl(reamp, "Click C.wav", anchor: 29.0, elapsed: 29.0 + (t - 10.6), duration: 150), at: at(t))
    }
    expectEqual(near(rig.shown(at: at(20.6)), seeded + 10.33, 0.02), true,
                "回放·reAMP 恢复: 补报的那份慢 0.5 秒的锚点 10 秒内不拿来伺服(\(fmt(rig.shown(at: at(20.6)))),想要 \(fmt(seeded + 10.33)))")
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 60, elapsed: 60, duration: 150), at: at(21))
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 60, elapsed: 61, duration: 150), at: at(22))
    expectEqual(near(rig.shown(at: at(22)), 61, 0.02), true, "回放·reAMP 恢复后拖动: 新锚点照常采信(\(fmt(rig.shown(at: at(22)))))")
}

/// reAMP 暂停在 20 秒时重新打开同一个文件(从头放):先报 0,之后不再补。按住 1.2 秒就放开,屏上回到开头;
/// 按 QQ 那 1.5 秒的话 1.3 秒那拍还停在 21 秒附近。见 02 章决策 126。
@MainActor
private func replayReampRestartFromTop() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    let reamp = PlaybackPlayer.reamp.bundleIdentifier
    let rig = ReplayRig("reamp-restart-top")
    defer { rig.tearDown() }
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 10, elapsed: 10, duration: 150), at: at(0))
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 10, elapsed: 18, duration: 150), at: at(8))
    rig.source.replayPlayerStateEvent(at: at(10), freeze: true)
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 20, elapsed: 20, duration: 150, playing: false), at: at(10.1))
    rig.source.replayResumeSignal(at: at(12))
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 0, elapsed: 0.1, duration: 150), at: at(12.1))
    expectEqual((rig.shown(at: at(12.1)) ?? 0) > 19, true, "回放·reAMP 从头重开: 先报 0 那一拍照旧按住(\(fmt(rig.shown(at: at(12.1)))))")
    rig.tick(mediaControl(reamp, "Click C.wav", anchor: 0, elapsed: 1.4, duration: 150), at: at(13.4))
    expectEqual(near(rig.shown(at: at(13.4)), 1.4, 0.05), true,
                "回放·reAMP 从头重开: 1.3 秒后没补锚点就回到开头(\(fmt(rig.shown(at: at(13.4)))))")

    // 读得到进度条时:按住那一拍读到它归 0,下一拍就回到开头,不等到点。
    let bar = ReplayRig("reamp-restart-bar")
    defer { bar.tearDown() }
    bar.tick(mediaControl(reamp, "Click C.wav", anchor: 10, elapsed: 10, duration: 150), at: at(0))
    bar.tick(mediaControl(reamp, "Click C.wav", anchor: 10, elapsed: 18, duration: 150), at: at(8))
    bar.source.replayPlayerStateEvent(at: at(10), freeze: true)
    bar.tick(mediaControl(reamp, "Click C.wav", anchor: 20, elapsed: 20, duration: 150, playing: false), at: at(10.1))
    bar.source.replayResumeSignal(at: at(12))
    bar.tick(mediaControl(reamp, "Click C.wav", anchor: 0, elapsed: 0.1, duration: 150), at: at(12.1))
    bar.source.replayRestartBar(0)
    bar.tick(mediaControl(reamp, "Click C.wav", anchor: 0, elapsed: 0.25, duration: 150), at: at(12.25))
    expectEqual(near(bar.shown(at: at(12.25)), 0.25, 0.05), true,
                "回放·reAMP 从头重开: 进度条归 0 就当场放开(\(fmt(bar.shown(at: at(12.25)))))")

    // 先补一份暂停时的锚点「在放」(当成恢复),0.5 秒后才报晚了 0.49 秒的开头锚点:按恢复信号至今算,不跟那份晚的。
    let late = ReplayRig("reamp-restart-late-zero")
    defer { late.tearDown() }
    late.tick(mediaControl(reamp, "Click C.wav", anchor: 10, elapsed: 10, duration: 150), at: at(0))
    late.tick(mediaControl(reamp, "Click C.wav", anchor: 10, elapsed: 12, duration: 150), at: at(2))
    late.source.replayPlayerStateEvent(at: at(2), freeze: true)
    late.tick(mediaControl(reamp, "Click C.wav", anchor: 12, elapsed: 12, duration: 150, playing: false), at: at(2.1))
    late.source.replayResumeSignal(at: at(14.67))
    late.tick(mediaControl(reamp, "Click C.wav", anchor: 12, elapsed: 12.2, duration: 150), at: at(14.88))
    late.tick(mediaControl(reamp, "Click C.wav", anchor: 0, elapsed: 0.268, duration: 150), at: at(15.377))
    expectEqual(near(late.shown(at: at(15.377)), 0.707, 0.02), true,
                "回放·reAMP 从头重开: 晚到的开头锚点按恢复信号至今算(\(fmt(late.shown(at: at(15.377)))))")
    // 同一种重开,读得到进度条:恢复那一拍之后就按恢复信号至今走,不等那份晚到的开头锚点。
    let early = ReplayRig("reamp-restart-bar-early")
    defer { early.tearDown() }
    early.tick(mediaControl(reamp, "Click C.wav", anchor: 10, elapsed: 10, duration: 150), at: at(0))
    early.tick(mediaControl(reamp, "Click C.wav", anchor: 10, elapsed: 12, duration: 150), at: at(2))
    early.source.replayPlayerStateEvent(at: at(2), freeze: true)
    early.tick(mediaControl(reamp, "Click C.wav", anchor: 12, elapsed: 12, duration: 150, playing: false), at: at(2.1))
    early.source.replayResumeSignal(at: at(14.67))
    early.tick(mediaControl(reamp, "Click C.wav", anchor: 12, elapsed: 12.2, duration: 150), at: at(14.88))
    early.source.replayRestartBar(0)
    early.tick(mediaControl(reamp, "Click C.wav", anchor: 12, elapsed: 12.3, duration: 150), at: at(14.95))
    expectEqual(near(early.shown(at: at(14.95)), 0.28, 0.02), true,
                "回放·reAMP 从头重开: 进度条归 0,旧锚点还在时按恢复信号至今走(\(fmt(early.shown(at: at(14.95)))))")
    early.tick(mediaControl(reamp, "Click C.wav", anchor: 0, elapsed: 0.268, duration: 150), at: at(15.377))
    expectEqual(near(early.shown(at: at(15.377)), 0.707, 0.02), true,
                "回放·reAMP 从头重开: 之后晚到的开头锚点不拽它(\(fmt(early.shown(at: at(15.377)))))")

    for t in stride(from: 16.4, through: 26.4, by: 1) {
        late.tick(mediaControl(reamp, "Click C.wav", anchor: 0, elapsed: 0.268 + (t - 15.377), duration: 150), at: at(t))
    }
    expectEqual(near(late.shown(at: at(26.4)), 0.707 + 11.023, 0.02), true,
                "回放·reAMP 从头重开: 之后不被那份晚的锚点拽回去(\(fmt(late.shown(at: at(26.4)))))")
}

/// QQ 在暂停态开播一首:暂停态发 `0`、开播后 1.2 秒补 `1.000`(真起点比开播信号晚 0.22 秒)。补的锚点一到就按决策 115 对齐,
/// 不再整首快 0.2 秒。见 02 章决策 120。
@MainActor
private func replayQQStartFromPaused() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    let rig = ReplayRig("qq-start-from-paused")
    defer { rig.tearDown() }
    rig.tick(mediaControl(qqID, "孤勇者", anchor: 0, elapsed: 0, duration: 256, playing: false), at: at(0))
    rig.source.replayResumeSignal(at: at(0.6))
    rig.tick(mediaControl(qqID, "孤勇者", anchor: 0, elapsed: 0.1, duration: 256), at: at(0.7))
    rig.tick(mediaControl(qqID, "孤勇者", anchor: 1, elapsed: 1.0, duration: 256), at: at(1.82))
    expectEqual(near(rig.shown(at: at(1.82)), 1.0, 0.03), true, "回放·QQ 暂停态开播: 补的 1.000 锚点一到就对齐(\(fmt(rig.shown(at: at(1.82)))))")
}

/// QQ 暂停在《再见以前先说再见》7.27 秒时开播另一首:先报这一首在放、读数掉回 0.224,0.6 秒后才换歌名。界面接着按暂停位置走,
/// 不先跳回这一首开头;到点还是这一首(暂停中拖回开头)才采信读数。见 02 章决策 120。
@MainActor
private func replayQQResumeToOtherTrack() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    for switchesTrack in [true, false] {
        let rig = ReplayRig("qq-resume-other-\(switchesTrack)")
        defer { rig.tearDown() }
        rig.tick(mediaControl(qqID, "再见以前先说再见", anchor: 5, elapsed: 5, duration: 272), at: at(0))
        rig.tick(mediaControl(qqID, "再见以前先说再见", anchor: 5, elapsed: 7, duration: 272), at: at(2))
        rig.source.replayPlayerStateEvent(at: at(2.27), freeze: true)
        rig.tick(mediaControl(qqID, "再见以前先说再见", anchor: 5, elapsed: 7.27, duration: 272, playing: false), at: at(2.3))
        rig.source.replayResumeSignal(at: at(10))
        rig.tick(mediaControl(qqID, "再见以前先说再见", anchor: 0, elapsed: 0.224, duration: 272), at: at(10.06))
        expectEqual(near(rig.shown(at: at(10.06)), 7.27, 0.05), true, "回放·QQ 恢复掉回开头: 不先跳回这一首开头(\(fmt(rig.shown(at: at(10.06)))))")
        rig.tick(mediaControl(qqID, "再见以前先说再见", anchor: 0, elapsed: 0.4, duration: 272), at: at(10.24))
        expectEqual(near(rig.shown(at: at(10.24)), 7.45, 0.05), true, "回放·QQ 恢复掉回开头: 换歌名之前再来一拍也接着按住(\(fmt(rig.shown(at: at(10.24)))))")
        if switchesTrack {
            rig.tick(mediaControl(qqID, "A.I.N.Y.", anchor: 0, elapsed: 0.05, duration: 226), at: at(10.6))
            // 在放信号比新歌的 0 锚点早 0.6 秒到,也是「先报在放、再发 0」那种开播:起点往前补 0.12(qqLateZeroAnchorLead)。
            expectEqual(near(rig.shown(at: at(11.6)), 1.17, 0.05), true, "回放·QQ 恢复掉回开头: 换了歌名照常从开头走(\(fmt(rig.shown(at: at(11.6)))))")
        } else {
            rig.tick(mediaControl(qqID, "再见以前先说再见", anchor: 0, elapsed: 0.8, duration: 272), at: at(10.6))
            rig.tick(mediaControl(qqID, "再见以前先说再见", anchor: 0, elapsed: 1.9, duration: 272), at: at(11.7))
            expectEqual(near(rig.shown(at: at(11.7)), 1.9, 0.05), true, "回放·QQ 恢复掉回开头: 到点还是这一首就采信读数(\(fmt(rig.shown(at: at(11.7)))))")
        }
    }
}

/// QQ「先报在放、再发 0」:在放信号 10.30 到,0 锚点 10.65 才发(晚 0.35 秒)→ 起点往前补 0.12;只晚 0.05 秒的不补。
/// 带新歌名和 0 锚点的那一行同样带 `playing:true`(10.65 又来一次在放信号),不能拿它当这段在放的起点。
/// 汽水同一串读数不补(对照)。见 02 章决策 120。
@MainActor
private func replayQQLateZeroAnchor() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    for (bundle, signalAt, expected) in [(qqID, 10.30, 0.17), (qqID, 10.60, 0.05), (PlaybackPlayer.soda.bundleIdentifier, 10.30, 0.05)] {
        let rig = ReplayRig("qq-late-zero-\(bundle)-\(signalAt)")
        defer { rig.tearDown() }
        rig.tick(mediaControl(bundle, "Mmm", anchor: 0, elapsed: 0, duration: 200), at: at(0))
        rig.tick(mediaControl(bundle, "Mmm", anchor: 0, elapsed: 10, duration: 200), at: at(10))
        rig.source.replayPlayerStateEvent(at: at(signalAt - 0.01), freeze: true)
        rig.source.replayResumeSignal(at: at(signalAt))
        rig.source.replayResumeSignal(at: at(10.65))
        rig.tick(mediaControl(bundle, "孤勇者", anchor: 0, elapsed: 0.05, duration: 256), at: at(10.7))
        expectEqual(near(rig.shown(at: at(10.7)), expected, 0.02), true,
                    "回放·晚到的 0 锚点(\(bundle == qqID ? "QQ" : "汽水"),信号 \(signalAt)): 起点 \(expected)(\(fmt(rig.shown(at: at(10.7)))))")
    }
}

/// 网易云按「下一个」开播:43.95 报在放(紧跟着上一首的暂停信号),44.375 才发新歌的 `0` 锚点,带歌名的那一行也带
/// `playing:true`。真起点是报在放那一刻:起点补上晚到的 0.42。汽水同一串读数不补(对照)。见 02 章决策 121。
@MainActor
private func replayNeteaseLateStartAnchor() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    for (bundle, lead) in [(PlaybackPlayer.netease.bundleIdentifier, 0.425), (PlaybackPlayer.soda.bundleIdentifier, 0.0)] {
        let rig = ReplayRig("netease-late-start-\(lead)")
        defer { rig.tearDown() }
        rig.tick(mediaControl(bundle, "u got me", anchor: 40, elapsed: 40, duration: 212), at: at(30))
        rig.tick(mediaControl(bundle, "u got me", anchor: 40, elapsed: 52, duration: 212), at: at(42))
        rig.source.replayPlayerStateEvent(at: at(43.79), freeze: true)
        rig.source.replayResumeSignal(at: at(43.95))
        rig.source.replayResumeSignal(at: at(44.375))
        rig.tick(mediaControl(bundle, "Pretty Eyes", anchor: 0, elapsed: 0.025, duration: 209), at: at(44.4))
        expectEqual(near(rig.shown(at: at(44.4)), 0.025 + lead, 0.02), true,
                    "回放·\(lead > 0 ? "网易云" : "汽水") 开播锚点晚到: 起点补 \(lead)(\(fmt(rig.shown(at: at(44.4)))))")
    }
}

/// 酷狗拖出试听片段的结尾、跳到下一首的试听片段(从 54.86 放起):10.959 停、11.047 报在放、声音同时响起,
/// 11.483 才发新歌的锚点(位置 54.86)。起点补上晚到的 0.44。见 02 章决策 123。
@MainActor
private func replayKugouLateStartAnchor() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    let rig = ReplayRig("kugou-late-start")
    defer { rig.tearDown() }
    let kugou = PlaybackPlayer.kugou.bundleIdentifier
    rig.tick(mediaControl(kugou, "One Call Away", anchor: 0, elapsed: 0, duration: 194), at: at(0))
    rig.tick(mediaControl(kugou, "One Call Away", anchor: 0, elapsed: 8, duration: 194), at: at(8))
    rig.source.replayPlayerStateEvent(at: at(10.959), freeze: true)
    rig.source.replayResumeSignal(at: at(11.047))
    rig.source.replayResumeSignal(at: at(11.488))
    rig.tick(mediaControl(kugou, "Boys", anchor: 54.86, elapsed: 54.865, duration: 163), at: at(11.49))
    expectEqual(near(rig.shown(at: at(11.49)), 54.865 + 0.443, 0.02), true,
                "回放·酷狗 开播锚点晚到: 起点补 0.44(\(fmt(rig.shown(at: at(11.49)))))")
}

/// 洛雪手动下一首:43.95 报在放、声音同时响起,44.475 才发新歌的 0 锚点。起点补上晚到的 0.525,之后每 2 秒一拍、锚点不再变:
/// 补上的这一截 20 秒后还在,伺服不拿锚点外推把它拉回去(不折进偏置时第 5 拍就拉回去了)。见 02 章决策 129。
@MainActor
private func replayLXMusicLateStartLeadHolds() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    let lx = PlaybackPlayer.lxMusic.bundleIdentifier
    let rig = ReplayRig("lx-late-start-holds")
    defer { rig.tearDown() }
    rig.tick(mediaControl(lx, "特别的人", anchor: 40, elapsed: 40, duration: 259), at: at(30))
    rig.tick(mediaControl(lx, "特别的人", anchor: 40, elapsed: 52, duration: 259), at: at(42))
    rig.source.replayPlayerStateEvent(at: at(43.79), freeze: true)
    rig.source.replayResumeSignal(at: at(43.95))
    rig.tick(mediaControl(lx, "离开我的依赖", anchor: 0, elapsed: 0.025, duration: 263), at: at(44.5))
    expectEqual(near(rig.shown(at: at(44.5)), 0.55, 0.02), true, "回放·洛雪 开播锚点晚到: 起点补 0.525(\(fmt(rig.shown(at: at(44.5)))))")
    for t in stride(from: 46.5, through: 64.5, by: 2) {
        rig.tick(mediaControl(lx, "离开我的依赖", anchor: 0, elapsed: t - 44.475, duration: 263), at: at(t))
    }
    expectEqual(near(rig.shown(at: at(64.5)), 20.55, 0.02), true,
                "回放·洛雪 开播锚点晚到: 补上的那一截 20 秒后还在(\(fmt(rig.shown(at: at(64.5)))),想要 20.550)")
    // 暂停:系统按晚到的锚点外推出 20.525,真停在 21.05;恢复的锚点是真停住的位置。补的那一截随暂停作废,恢复后照真值走。
    rig.source.replayPlayerStateEvent(at: at(65), freeze: true)
    rig.tick(mediaControl(lx, "离开我的依赖", anchor: 20.525, elapsed: 20.525, duration: 263, playing: false), at: at(65.1))
    expectEqual(near(rig.shown(at: at(65.1)), 21.05, 0.02), true, "回放·洛雪 暂停: 按屏上位置停住(\(fmt(rig.shown(at: at(65.1)))))")
    rig.source.replayResumeSignal(at: at(70))
    for t in stride(from: 70.3, through: 90.3, by: 2) {
        rig.tick(mediaControl(lx, "离开我的依赖", anchor: 21.05, elapsed: 21.05 + t - 70, duration: 263), at: at(t))
    }
    expectEqual(near(rig.shown(at: at(90.3)), 41.35, 0.02), true,
                "回放·洛雪 暂停后恢复: 补的那一截随暂停作废,20 秒后照真值走(\(fmt(rig.shown(at: at(90.3)))),想要 41.350)")
    rig.tick(mediaControl(lx, "离开我的依赖", anchor: 100, elapsed: 100, duration: 263), at: at(92))
    expectEqual(near(rig.shown(at: at(92)), 100, 0.02), true, "回放·洛雪 拖动: 跟新锚点(\(fmt(rig.shown(at: at(92)))))")
}

/// 洛雪停了一分半再放、蓝牙耳机闲着:100 报在放,锚点是它停住的真进度 28.9(暂停时系统外推出的是 28.95),101.0 设备才转起来、
/// 这时才出声。设备转起来之前停在暂停位置,转起来之后从锚点起算,20 秒后还对得上;设备在转时照旧(对照)。见 02 章决策 129。
@MainActor
private func replayLXMusicColdResume() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    let lx = PlaybackPlayer.lxMusic.bundleIdentifier
    for coldDevice in [true, false] {
        let rig = ReplayRig("lx-cold-resume-\(coldDevice)")
        defer { rig.tearDown() }
        rig.tick(mediaControl(lx, "特别的人", anchor: 20, elapsed: 20, duration: 259), at: at(0))
        rig.tick(mediaControl(lx, "特别的人", anchor: 20, elapsed: 28, duration: 259), at: at(8))
        rig.source.replayPlayerStateEvent(at: at(8.9), freeze: true)
        rig.tick(mediaControl(lx, "特别的人", anchor: 28.95, elapsed: 28.95, duration: 259, playing: false), at: at(9))
        rig.source.replayResumeSignal(at: at(100))
        if coldDevice { rig.source.replayLXMusicColdStartSignal(at: at(100)) }
        rig.tick(mediaControl(lx, "特别的人", anchor: 28.9, elapsed: 29.2, duration: 259), at: at(100.3))
        guard coldDevice else {
            expectEqual(near(rig.shown(at: at(100.3)), 29.2, 0.02), true,
                        "回放·洛雪 恢复(设备在转): 照旧按恢复信号至今走(\(fmt(rig.shown(at: at(100.3)))))")
            continue
        }
        expectEqual(near(rig.shown(at: at(100.3)), 28.9, 0.02), true,
                    "回放·洛雪 冷恢复: 设备转起来之前停在暂停位置(\(fmt(rig.shown(at: at(100.3)))))")
        rig.source.replayLXMusicAudioStarted(at: at(101.0))
        rig.tick(mediaControl(lx, "特别的人", anchor: 28.9, elapsed: 29.95, duration: 259), at: at(101.05))
        expectEqual(near(rig.shown(at: at(101.05)), 28.95, 0.02), true,
                    "回放·洛雪 冷恢复: 设备转起来后从锚点起算(\(fmt(rig.shown(at: at(101.05)))))")
        for t in stride(from: 103.0, through: 121.0, by: 2) {
            rig.tick(mediaControl(lx, "特别的人", anchor: 28.9, elapsed: 28.9 + t - 100.3, duration: 259), at: at(t))
        }
        expectEqual(near(rig.shown(at: at(121)), 48.9, 0.02), true,
                    "回放·洛雪 冷恢复: 20 秒后还对得上,伺服不拉回锚点外推(\(fmt(rig.shown(at: at(121)))),想要 48.900)")
        // 再停一次、马上恢复(设备在转):系统按恢复锚点外推出 50.6,真停在 49.9;冷恢复折进的偏置随暂停作废。
        rig.source.replayPlayerStateEvent(at: at(122), freeze: true)
        rig.tick(mediaControl(lx, "特别的人", anchor: 50.6, elapsed: 50.6, duration: 259, playing: false), at: at(122.1))
        rig.source.replayResumeSignal(at: at(130))
        for t in stride(from: 130.3, through: 150.3, by: 2) {
            rig.tick(mediaControl(lx, "特别的人", anchor: 49.9, elapsed: 49.9 + t - 130, duration: 259), at: at(t))
        }
        expectEqual(near(rig.shown(at: at(150.3)), 70.2, 0.02), true,
                    "回放·洛雪 冷恢复后再暂停、恢复: 偏置随暂停作废(\(fmt(rig.shown(at: at(150.3)))),想要 70.200)")
    }
}

/// 洛雪冷恢复记下了,设备 101.0 转起来,新锚点却跟在放信号那一刻的一样(用不上);半分钟后拖到 60 秒:跟新锚点走,
/// 不按 101.0 那个转起来的时刻再补 30 秒。
@MainActor
private func replayLXMusicColdResumeStale() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    let lx = PlaybackPlayer.lxMusic.bundleIdentifier
    let rig = ReplayRig("lx-cold-resume-stale")
    defer { rig.tearDown() }
    rig.tick(mediaControl(lx, "特别的人", anchor: 20, elapsed: 20, duration: 259), at: at(0))
    rig.tick(mediaControl(lx, "特别的人", anchor: 20, elapsed: 28, duration: 259), at: at(8))
    rig.source.replayPlayerStateEvent(at: at(8.9), freeze: true)
    rig.tick(mediaControl(lx, "特别的人", anchor: 28.95, elapsed: 28.95, duration: 259, playing: false), at: at(9))
    rig.source.replayResumeSignal(at: at(100))
    rig.source.replayLXMusicColdStartSignal(at: at(100))
    rig.tick(mediaControl(lx, "特别的人", anchor: 28.95, elapsed: 29.25, duration: 259), at: at(100.3))
    rig.source.replayLXMusicAudioStarted(at: at(101.0))
    for t in stride(from: 101.05, through: 131.05, by: 2) {
        rig.tick(mediaControl(lx, "特别的人", anchor: 28.95, elapsed: 28.95 + t - 100.3, duration: 259), at: at(t))
    }
    rig.tick(mediaControl(lx, "特别的人", anchor: 60, elapsed: 60, duration: 259), at: at(131.5))
    rig.tick(mediaControl(lx, "特别的人", anchor: 60, elapsed: 62, duration: 259), at: at(133.5))
    expectEqual(near(rig.shown(at: at(133.5)), 62, 0.1), true,
                "回放·洛雪 冷恢复没用上、半分钟后拖动: 跟新锚点走,不按很久以前的转起来时刻补(\(fmt(rig.shown(at: at(133.5)))),想要 62.000)")
}

/// 洛雪 10.5 秒时从 1 倍改成 1.25 倍:系统那份速度和锚点不变(20 秒处、1 倍),配置 0.3 秒后写盘。下一拍从改的那一刻起按 1.25 倍走,
/// 20 秒后还对得上;之后暂停、恢复,它按 1.25 倍重报,照真值走。见 02 章决策 130。
@MainActor
private func replayLXMusicRateChange() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    let lx = PlaybackPlayer.lxMusic.bundleIdentifier
    let rig = ReplayRig("lx-rate-change")
    defer { rig.tearDown() }
    rig.lxRate = LXMusicPlaybackRate.Setting(rate: 1, changedAt: at(-600))
    for t in stride(from: 0.0, through: 10.0, by: 2) {
        rig.tick(mediaControl(lx, "特别的人", anchor: 20, elapsed: 20 + t, duration: 259), at: at(t))
    }
    rig.lxRate = LXMusicPlaybackRate.Setting(rate: 1.25, changedAt: at(10.5))
    rig.tick(mediaControl(lx, "特别的人", anchor: 20, elapsed: 32, duration: 259), at: at(12))
    expectEqual(near(rig.shown(at: at(12)), 32.375, 0.02), true, "回放·洛雪 中途改 1.25 倍: 下一拍从改的那一刻起按新速度(\(fmt(rig.shown(at: at(12)))))")
    for t in stride(from: 14.0, through: 30.0, by: 2) {
        rig.tick(mediaControl(lx, "特别的人", anchor: 20, elapsed: 20 + t, duration: 259), at: at(t))
    }
    expectEqual(near(rig.shown(at: at(30)), 54.875, 0.02), true,
                "回放·洛雪 中途改 1.25 倍: 20 秒后还对得上(\(fmt(rig.shown(at: at(30)))),想要 54.875)")
    rig.source.replayPlayerStateEvent(at: at(31), freeze: true)
    rig.tick(mediaControl(lx, "特别的人", anchor: 56.125, elapsed: 56.125, duration: 259, playing: false), at: at(31.1))
    rig.source.replayResumeSignal(at: at(40))
    for t in stride(from: 40.3, through: 50.3, by: 2) {
        rig.tick(.forReplay(title: "特别的人", artist: "Fujii Kaze", album: "Prema", duration: 259, elapsedTime: 56.125 + (t - 40) * 1.25,
                            playing: true, playbackRate: 1.25, bundleIdentifier: lx, anchorElapsedTime: 56.125), at: at(t))
    }
    // 容差 0.1:恢复那一拍的前跳上界按秒算、不乘速度(resumeSeedSeconds),1.25 倍时少走 0.3 × 0.25 = 0.075。
    expectEqual(near(rig.shown(at: at(50.3)), 56.125 + 10.3 * 1.25, 0.1), true,
                "回放·洛雪 改速度后暂停、恢复: 它按新速度重报,照真值走(\(fmt(rig.shown(at: at(50.3)))))")
}

/// 洛雪开了开放 API:系统那份锚点慢 0.5 秒(晚到的开播锚点),它推的进度是准的 —— 屏上照它推的走,不再补晚到锚点那一截;
/// 停了一分半再放、声音还没走起来那段进度停着,屏上等着,走起来后接上。见 02 章决策 131。
@MainActor
private func replayLXMusicOpenAPIClock() {
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "nil" }
    let lx = PlaybackPlayer.lxMusic.bundleIdentifier
    let rig = ReplayRig("lx-open-api")
    defer { rig.tearDown() }
    func api(_ progress: Double, at t: Double, advancing: Bool = true, status: String = "playing") -> LXMusicOpenAPI.State {
        var s = LXMusicOpenAPI.State()
        s.status = status; s.name = "离开我的依赖"; s.singer = "Fujii Kaze"; s.progress = progress; s.progressAt = at(t)
        s.advancing = advancing; s.playbackRate = 1
        return s
    }
    rig.source.replayResumeSignal(at: at(43.95))
    for t in stride(from: 44.5, through: 60.5, by: 2) {
        rig.lxAPI = api(t - 43.95 - 0.1, at: t - 0.1)
        rig.tick(mediaControl(lx, "离开我的依赖", anchor: 0, elapsed: t - 44.475, duration: 263), at: at(t))
    }
    expectEqual(near(rig.shown(at: at(60.5)), 16.55, 0.03), true,
                "回放·洛雪 开放 API: 照它推的进度走,不跟慢 0.5 秒的系统锚点(\(fmt(rig.shown(at: at(60.5)))),想要 16.550)")
    rig.source.replayPlayerStateEvent(at: at(61), freeze: true)
    rig.lxAPI = api(17.05, at: 61, advancing: false, status: "paused")
    rig.tick(mediaControl(lx, "离开我的依赖", anchor: 16.5, elapsed: 16.5, duration: 263, playing: false), at: at(61.1))
    rig.source.replayResumeSignal(at: at(150))
    rig.lxAPI = api(17.05, at: 150.2, advancing: false)
    rig.tick(mediaControl(lx, "离开我的依赖", anchor: 17.05, elapsed: 17.35, duration: 263), at: at(150.3))
    expectEqual(near(rig.shown(at: at(150.3)), 17.05, 0.02), true,
                "回放·洛雪 开放 API: 恢复后声音没走起来,停在那份进度(\(fmt(rig.shown(at: at(150.3)))))")
    for t in stride(from: 151.3, through: 171.3, by: 2) {
        rig.lxAPI = api(17.05 + (t - 0.1 - 151.0), at: t - 0.1)
        rig.tick(mediaControl(lx, "离开我的依赖", anchor: 17.05, elapsed: 17.05 + t - 150.2, duration: 263), at: at(t))
    }
    expectEqual(near(rig.shown(at: at(171.3)), 37.35, 0.03), true,
                "回放·洛雪 开放 API: 声音 151.0 走起来后照它推的走(\(fmt(rig.shown(at: at(171.3)))),想要 37.350)")
}

private let kkboxID = PlaybackPlayer.kkbox.bundleIdentifier

/// KKBOX 开播第一个锚点晚 0.18s(真实位置 = 读数 + 0.18),之后每秒重发的锚点都准:几拍之内对齐读数,
/// 而不是按 cleanExtrapolated 那档 0.4s 的门槛整首慢 0.18s。读数盖了读到的时刻(capturedAt)。
@MainActor
private func replayKKBOXFollowsRepublishedAnchor() {
    let rig = ReplayRig("kkbox-follow")
    defer { rig.tearDown() }
    rig.tick(mediaControl(kkboxID, "屬於我們的故事", anchor: 0.19, elapsed: 0.19, duration: 280, capturedAt: at(0)), at: at(0))
    for t in stride(from: 2.0, through: 12.0, by: 2) {
        let truth = 0.37 + t
        rig.tick(mediaControl(kkboxID, "屬於我們的故事", anchor: truth - 0.3, elapsed: truth, duration: 280, capturedAt: at(t)), at: at(t))
    }
    expectEqual(near(rig.shown(at: at(12)), 12.37, 0.01), true,
                "回放·KKBOX: 开播锚点晚 0.18s,几拍之内对齐每秒重发的准锚点(\(rig.shown(at: at(12)).map { String(format: "%.3f", $0) } ?? "nil"))")
}

/// KKBOX 暂停:暂停事件先到、冻住外推;这一拍快照里还是播放时最后那个锚点(旧一秒),真正的暂停锚点 0.2s 后才到。
/// 屏上先停在事件冻住的位置,锚点换了再换 —— 不先往回跳半秒多再跳回来。酷狗照旧按快照冻结值(对照)。
@MainActor
private func replayKKBOXPauseHoldsUntilPauseAnchor() {
    for (bundle, holds) in [(kkboxID, true), (PlaybackPlayer.kugou.bundleIdentifier, false)] {
        let rig = ReplayRig("pause-hold-\(holds)")
        defer { rig.tearDown() }
        for t in stride(from: 0.0, through: 20.0, by: 2) {
            rig.tick(mediaControl(bundle, "甲乙丙丁", anchor: 60 + t, elapsed: 60 + t, duration: 280, capturedAt: at(t)), at: at(t))
        }
        rig.source.replayPlayerStateEvent(at: at(21.0), freeze: true)
        rig.anchorPublishedWhilePaused = false
        rig.tick(mediaControl(bundle, "甲乙丙丁", anchor: 80.3, elapsed: 80.3, duration: 280, playing: false, capturedAt: at(21.05)), at: at(21.05))
        let held = rig.source.pausedPositionMs.map { Double($0) / 1000 }
        if holds {
            expectEqual(near(held, 81.0, 0.02), true,
                        "回放·KKBOX 暂停: 快照还是旧锚点时停在事件冻住的位置(\(held.map { String(format: "%.3f", $0) } ?? "nil"))")
        } else {
            expectEqual(near(held, 80.3, 0.001), true, "回放·酷狗暂停: 照旧按快照冻结值(对照)")
        }
        rig.anchorPublishedWhilePaused = true
        rig.tick(mediaControl(bundle, "甲乙丙丁", anchor: 80.85, elapsed: 80.85, duration: 280, playing: false, capturedAt: at(23)), at: at(23))
        let settled = rig.source.pausedPositionMs.map { Double($0) / 1000 }
        expectEqual(near(settled, 80.85, 0.001), true, "回放·暂停锚点到了换成它(\(bundle))")
    }
}

/// KKBOX 卡在加载:每秒重发的锚点断了,`MediaControlClient.republishHold` 交「停住」快照(没在走、位置停在锚点 + 1.5s、
/// `isWaitingToPlay`)。屏上停在那里,不再往前跑;下一份锚点到了从它接着走,往回只退一小段。
/// 数字取自真机《自由的你》:4.700 那份之后 7.44s 才到 5.141。
@MainActor
private func replayKKBOXStallHolds() {
    let rig = ReplayRig("kkbox-stall")
    defer { rig.tearDown() }
    for i in 0...4 {
        let t = Double(i) * 1.06
        rig.tick(mediaControl(kkboxID, "自由的你", anchor: 0.46 + t, elapsed: 0.46 + t, duration: 297, capturedAt: at(t)), at: at(t))
    }
    var held = mediaControl(kkboxID, "自由的你", anchor: 4.70, elapsed: 6.20, duration: 297, playing: false, capturedAt: at(5.79))
    held.isWaitingToPlay = true
    rig.tick(held, at: at(5.79))
    let during = rig.shown(at: at(9.0))
    expectEqual(near(during, 6.20, 0.01), true,
                "回放·KKBOX 卡在加载: 屏上停在锚点 + 1.5s、不往前跑(\(during.map { String(format: "%.3f", $0) } ?? "nil"))")
    rig.tick(held, at: at(7.79))
    rig.tick(mediaControl(kkboxID, "自由的你", anchor: 5.141, elapsed: 5.141, duration: 297, capturedAt: at(11.68)), at: at(11.68))
    let resumed = rig.shown(at: at(12.68))
    expectEqual(near(resumed, 6.141, 0.05), true,
                "回放·KKBOX 卡在加载: 下一份锚点到了从它接着走(\(resumed.map { String(format: "%.3f", $0) } ?? "nil"))")
}

/// 页面内换歌(YouTube Music 在同一个标签页里切到下一首):新曲头一拍常常还没有时长。
/// 这一拍也要通知探针换歌,否则 A → B → A 切回来时探针还记着「A 已经探过」,一次都不探。
@MainActor
private func replayBrowserProbeReopensOnEveryTrackChange() {
    let rig = ReplayRig("browser-probe-reopen")
    defer { rig.tearDown() }
    rig.tick(mediaControl(safariMediaID, "My Universe", anchor: 0, elapsed: 40, duration: 282.181), at: at(0))
    rig.tick(.forReplay(title: "Dynamite", artist: "Fujii Kaze", album: "Prema", duration: nil, elapsedTime: 0,
                        playing: true, bundleIdentifier: safariMediaID, anchorElapsedTime: 0), at: at(2))
    rig.tick(.forReplay(title: "My Universe", artist: "Fujii Kaze", album: "Prema", duration: nil, elapsedTime: 0,
                        playing: false, bundleIdentifier: safariMediaID, anchorElapsedTime: 0), at: at(4))
    rig.tick(mediaControl(safariMediaID, "My Universe", anchor: 0, elapsed: 2, duration: 282.181), at: at(6))
    expectEqual(rig.browserTrackChanges, ["Fujii Kaze|My Universe", "Fujii Kaze|Dynamite", "Fujii Kaze|My Universe"],
                "回放·网页探针: 没有时长 / 没在播的换歌那一拍也重开额度")
}

/// 手动点播:上一首放到一半时点了另一首 → fresh 档。真实领先 0.271,
/// 扣先验 0.24 之后屏上只差 0.03;暂停冻结值 = 出声位置 + 淡出 0.27,反推出 0.271 学进 fresh。
@MainActor
private func replaySpotifyManualStart() {
    let rig = ReplayRig("spotify-manual")
    defer { rig.tearDown() }
    rig.tick(spotify("還是會寂寞", raw: 90, duration: 272), at: at(0))
    rig.tick(spotify("還是會寂寞", raw: 92, duration: 272), at: at(2))
    let trueLead = 0.271
    func raw(_ t: Double) -> Double { t - 3 + 0.076 }
    for t in stride(from: 3.0, through: 19.0, by: 2) {
        rig.tick(spotify("蝴蝶", raw: raw(t), duration: 283.2), at: at(t))
    }
    expectEqual(near(rig.source.replayReportedBiasSecs, 0.24, 0.001), true, "回放·Spotify 手动点播: 按 fresh 先验扣 0.24")
    expectEqual(near(rig.shown(at: at(19)), raw(19) - 0.24), true, "回放·Spotify 手动点播: 屏上 = 自己的钟 − 0.24")
    // 暂停:通知先到(冻住外推),0.3s 后读到 Spotify 发布的冻结值。
    rig.source.replayPlayerStateEvent(at: at(19.5), freeze: true)
    let frozen = raw(19.5) - trueLead + LocalPlaybackSource.spotifyPauseFadeSecs
    rig.tick(spotify("蝴蝶", raw: frozen, duration: 283.2, playing: false), at: at(19.8))
    expectEqual(near(rig.shown(at: at(19.8)), frozen, 0.001), true, "回放·Spotify 手动点播: 暂停后屏上 = 冻结值")
    expectEqual(rig.source.replayReportedBiasSecs, 0, "回放·Spotify 手动点播: 暂停作废偏置")
    let learned = rig.startLeadTable["fresh"]
    expectEqual(near(learned, 0.24 * 0.5 + trueLead * 0.5, 0.002), true,
                "回放·Spotify 手动点播: 暂停反推的 0.271 按头几个样本的 α=0.5 学进 fresh(\(learned.map { String(format: "%.4f", $0) } ?? "nil"))")
    expectEqual(rig.startLeadTable["afterAd"], nil, "回放·Spotify 手动点播: 不碰 afterAd")
}

/// 广告放完接着放:广告报 29.99s、29.09s 就结束。上一首是广告时归 afterAd(先验 0.66),暂停反推的真实领先 0.766
/// 学进 afterAd;对照组上一首不是广告,新曲的钟差 0.92s、在预载容差以内,归 gapless(先验同为 0.66)、学进 gapless。
/// 两组都不碰 fresh。
@MainActor
private func replaySpotifyAfterAd() {
    for previousWasAd in [true, false] {
        let rig = ReplayRig("spotify-after-ad-\(previousWasAd)")
        defer { rig.tearDown() }
        let ad = "広告ナシで音楽を聴こう。"
        rig.tick(spotify(ad, artist: "Spotify", raw: 27.0, duration: 29.99), at: at(0), isAdBreak: previousWasAd)
        rig.tick(spotify(ad, artist: "Spotify", raw: 29.0, duration: 29.99), at: at(2), isAdBreak: previousWasAd)
        func raw(_ t: Double) -> Double { t - 2.6 + 0.527 }
        for t in stride(from: 2.6, through: 18.6, by: 2) {
            rig.tick(spotify("還是會寂寞", artist: "陳綺貞", raw: raw(t), duration: 272.29), at: at(t))
        }
        let label = previousWasAd ? "广告之后" : "对照(上一首不是广告)"
        expectEqual(near(rig.source.replayReportedBiasSecs, 0.66, 0.001), true,
                    "回放·Spotify \(label): 扣 0.66(实际 \(String(format: "%.3f", rig.source.replayReportedBiasSecs)))")
        rig.source.replayPlayerStateEvent(at: at(19), freeze: true)
        let frozen = raw(19) - 0.766 + LocalPlaybackSource.spotifyPauseFadeSecs
        rig.tick(spotify("還是會寂寞", artist: "陳綺貞", raw: frozen, duration: 272.29, playing: false), at: at(19.3))
        let table = rig.startLeadTable
        let learnedKind = previousWasAd ? "afterAd" : "gapless"
        let otherKind = previousWasAd ? "gapless" : "afterAd"
        expectEqual(near(table[learnedKind], 0.66 * 0.5 + 0.766 * 0.5, 0.002), true,
                    "回放·Spotify \(label): 暂停反推的 0.766 学进 \(learnedKind)(\(table[learnedKind].map { String(format: "%.4f", $0) } ?? "nil"))")
        expectEqual(table[otherKind], nil, "回放·Spotify \(label): 不碰 \(otherKind)")
        expectEqual(table["fresh"], nil, "回放·Spotify \(label): fresh 不被这个样本污染")
    }
}

/// 同一首里读数跳回开头:3s 内收到过「Playing、位置 0」通知 → 重新起播(fresh 先验 0.24);
/// 没有通知的大跳 → 拖动(seek 先验 0.45)。
@MainActor
private func replaySpotifySameTrackJump() {
    let rig = ReplayRig("spotify-jump")
    defer { rig.tearDown() }
    rig.tick(spotify("蝴蝶", raw: 60, duration: 283.2), at: at(0))
    rig.tick(spotify("蝴蝶", raw: 62, duration: 283.2), at: at(2))
    rig.source.replaySpotifyPlayingFromStartNotice(at: at(3.0))
    rig.tick(spotify("蝴蝶", raw: 0.25, duration: 283.2), at: at(3.3))
    expectEqual(near(rig.source.replayReportedBiasSecs, 0.24, 0.001), true,
                "回放·Spotify 同曲重新起播: 按 fresh 扣 0.24(实际 \(String(format: "%.3f", rig.source.replayReportedBiasSecs)))")
    rig.tick(spotify("蝴蝶", raw: 2.25, duration: 283.2), at: at(5.3))
    rig.tick(spotify("蝴蝶", raw: 90.5, duration: 283.2), at: at(10))
    expectEqual(near(rig.source.replayReportedBiasSecs, 0.45, 0.001), true,
                "回放·Spotify 同曲拖动: 按 seek 扣 0.45(实际 \(String(format: "%.3f", rig.source.replayReportedBiasSecs)))")
    expectEqual(near(rig.shown(at: at(10)), 90.5 - 0.45), true, "回放·Spotify 同曲拖动: 屏上 = 自己的钟 − 0.45")
}

/// 恢复播放看到晚了:暂停在 8.043,恢复信号先到,5.6s 后轮询才看到在播(media-control 卡满超时那一种)。
/// 按恢复信号的年龄播种、量出恢复领先,下一拍不当成拖动。
@MainActor
private func replaySpotifyLateResume() {
    let rig = ReplayRig("spotify-late-resume")
    defer { rig.tearDown() }
    rig.tick(spotify("APT.", artist: "ROSÉ", raw: 4.0, duration: 169.9), at: at(0))
    rig.tick(spotify("APT.", artist: "ROSÉ", raw: 6.0, duration: 169.9), at: at(2))
    rig.source.replayPlayerStateEvent(at: at(4.0), freeze: true)
    rig.tick(spotify("APT.", artist: "ROSÉ", raw: 8.043, duration: 169.9, playing: false), at: at(4.3))
    rig.source.replayResumeSignal(at: at(20))
    let lead = 0.349
    func raw(_ t: Double) -> Double { 8.043 + (t - 20) + lead }
    rig.tick(spotify("APT.", artist: "ROSÉ", raw: raw(25.597), duration: 169.9), at: at(25.597))
    expectEqual(near(rig.shown(at: at(25.597)), 13.640, 0.01), true,
                "回放·Spotify 恢复看到晚了: 按恢复信号的年龄播种(实际 \(rig.shown(at: at(25.597)).map { String(format: "%.3f", $0) } ?? "nil"))")
    expectEqual(near(rig.source.replayReportedBiasSecs, lead, 0.01), true,
                "回放·Spotify 恢复看到晚了: 量出恢复领先 0.349(实际 \(String(format: "%.3f", rig.source.replayReportedBiasSecs)))")
    rig.tick(spotify("APT.", artist: "ROSÉ", raw: raw(25.959), duration: 169.9), at: at(25.959))
    expectEqual(near(rig.source.replayReportedBiasSecs, lead, 0.01), true, "回放·Spotify 恢复看到晚了: 下一拍不当成拖动、偏置不变")
    expectEqual(near(rig.shown(at: at(25.959)), raw(25.959) - lead), true, "回放·Spotify 恢复看到晚了: 屏上 = 自己的钟 − 恢复领先")

    // 对照:没收到恢复信号、只有暂停那一刻的旧信号(轮询自己发现的恢复),照旧最多往前补 2 秒、不量恢复领先。
    let control = ReplayRig("spotify-late-resume-control")
    defer { control.tearDown() }
    control.tick(spotify("APT.", artist: "ROSÉ", raw: 4.0, duration: 169.9), at: at(0))
    control.tick(spotify("APT.", artist: "ROSÉ", raw: 6.0, duration: 169.9), at: at(2))
    control.source.replayPlayerStateEvent(at: at(4.0), freeze: true)
    control.tick(spotify("APT.", artist: "ROSÉ", raw: 8.043, duration: 169.9, playing: false), at: at(4.3))
    control.tick(spotify("APT.", artist: "ROSÉ", raw: raw(25.597), duration: 169.9), at: at(25.597))
    expectEqual(near(control.shown(at: at(25.597)), 8.043 + LocalPlaybackSource.resumeMaxForwardCapSecs, 0.01), true,
                "回放·Spotify 恢复看到晚了(对照): 没有恢复信号照旧封顶 2 秒")
    expectEqual(control.source.replayReportedBiasSecs, 0, "回放·Spotify 恢复看到晚了(对照): 没有恢复信号不量恢复领先")
}

/// 旧版本学的表:fresh 混着别的起播方式的样本,读表那一刻作废、退回先验,它的样本数一起清掉;别的档原样保留。
@MainActor
private func replaySpotifyStartLeadMigration() {
    let rig = ReplayRig("spotify-migration")
    defer { rig.tearDown() }
    rig.defaults.set(["fresh": 0.598, "gapless": 0.705, "seek": 0.466], forKey: "np:spotifyStartLeadByKind")
    rig.defaults.set(["fresh": 5, "gapless": 2, "seek": 2], forKey: "np:spotifyStartLeadSamplesByKind")
    rig.defaults.set(2, forKey: "np:spotifyStartLeadSchema")
    rig.tick(spotify("蝴蝶", raw: 0.076, duration: 283.2), at: at(0))
    expectEqual(near(rig.source.replayReportedBiasSecs, 0.24, 0.001), true,
                "回放·起播领先表迁移: 旧 fresh 0.598 作废,按先验 0.24 扣")
    expectEqual(rig.defaults.object(forKey: "np:spotifyStartLeadSchema") as? Int, LocalPlaybackSource.spotifyStartLeadSchema,
                "回放·起播领先表迁移: 版本号写回")
    expectEqual(rig.startLeadTable, ["gapless": 0.705, "seek": 0.466], "回放·起播领先表迁移: 只删 fresh")
    expectEqual(rig.defaults.dictionary(forKey: "np:spotifyStartLeadSamplesByKind") as? [String: Int], ["gapless": 2, "seek": 2],
                "回放·起播领先表迁移: fresh 的样本数一起清掉")
}

/// Safari 恢复播放卡顿:恢复锚点按按下播放那一刻打、页面的钟晚 0.27s 才走。
/// 精确读数量出来折进偏置 → 屏上对齐页面的钟;Safari 下一次重发锚点(真值)时偏置作废;暂停残差归零。
@MainActor
private func replaySafariResumeStall() {
    let rig = ReplayRig("safari-resume-stall")
    defer { rig.tearDown() }
    let title = "Okay, Goodbye"
    for t in [0.0, 2, 4] {
        rig.tick(mediaControl(safariMediaID, title, anchor: 200, elapsed: 200 + t, duration: 231, capturedAt: at(t)), at: at(t))
    }
    rig.source.replayPlayerStateEvent(at: at(5), freeze: true)
    rig.tick(mediaControl(safariMediaID, title, anchor: 205, elapsed: 205, duration: 231, playing: false, capturedAt: at(5.3)), at: at(5.3))
    expectEqual(near(rig.shown(at: at(5.3)), 205, 0.001), true, "回放·Safari 恢复卡顿: 暂停位置 = Safari 冻结值")
    // 恢复:锚点 205 @ 20.0,页面的钟 20.27 才开始走。
    let stall = 0.27
    func page(_ t: Double) -> Double { 205 + (t - 20 - stall) }
    func stream(_ t: Double) -> Double { 205 + (t - 20) }
    rig.source.replayPlayerStateEvent(at: at(20), freeze: false)
    let resumed = mediaControl(safariMediaID, title, anchor: 205, elapsed: stream(20.33), duration: 231, capturedAt: at(20.33))
    rig.tick(resumed, at: at(20.33))
    expectEqual(rig.browserReopened, [resumed.identityKey], "回放·Safari 恢复卡顿: 恢复那一拍重开探测额度")
    rig.browserCorrection = (resumed.identityKey, at(22.5), true, { page($0.timeIntervalSince(replayT0)) })
    for t in [22.33, 24.33] {
        rig.tick(mediaControl(safariMediaID, title, anchor: 205, elapsed: stream(t), duration: 231, capturedAt: at(t)), at: at(t))
    }
    expectEqual(near(rig.source.replayReportedBiasSecs, stall, 0.005), true,
                "回放·Safari 恢复卡顿: 精确读数量出锚点领先 0.27 折进偏置(实际 \(String(format: "%.3f", rig.source.replayReportedBiasSecs)))")
    expectEqual(near(rig.shown(at: at(24.33)), page(24.33)), true, "回放·Safari 恢复卡顿: 重锚到页面的钟")
    expectEqual(rig.biasWrites.isEmpty, true, "回放·Safari 恢复卡顿: 网页的偏置不落盘(只有 Spotify 的会在重启后接回)")
    rig.tick(mediaControl(safariMediaID, title, anchor: 205, elapsed: stream(26.33), duration: 231, capturedAt: at(26.33)), at: at(26.33))
    expectEqual(near(rig.shown(at: at(26.33)), page(26.33)), true, "回放·Safari 恢复卡顿: 下一拍流读数扣偏置后不被伺服拽回")
    // Safari 因时长微调重发锚点(真值):偏置作废,屏上仍在页面的钟上。
    rig.tick(mediaControl(safariMediaID, title, anchor: page(40), elapsed: page(40), duration: 230.91, capturedAt: at(40)), at: at(40))
    expectEqual(rig.source.replayReportedBiasSecs, 0, "回放·Safari 恢复卡顿: Safari 重发锚点即作废偏置")
    expectEqual(near(rig.shown(at: at(40)), page(40)), true, "回放·Safari 恢复卡顿: 重发之后仍对齐")
    rig.source.replayPlayerStateEvent(at: at(45), freeze: true)
    let shownAtPause = rig.shown(at: at(45))
    rig.tick(mediaControl(safariMediaID, title, anchor: page(45), elapsed: page(45), duration: 230.91, playing: false, capturedAt: at(45.3)), at: at(45.3))
    expectEqual(shownAtPause.map { near(page(45), $0, 0.02) }, true,
                "回放·Safari 恢复卡顿: 暂停残差归零(屏上 \(shownAtPause.map { String(format: "%.3f", $0) } ?? "nil") 对冻结值 \(String(format: "%.3f", page(45))))")
}

/// 整秒读数在 Safari 上不用:后台标签页的文字晚 2~3s,本来要被拉回 1.45s。Chrome 照旧采信。
@MainActor
private func replaySafariFloorReadingIgnored() {
    for bundle in [safariMediaID, "com.google.Chrome"] {
        let rig = ReplayRig("floor-\(bundle)")
        defer { rig.tearDown() }
        let first = mediaControl(bundle, "Boston", anchor: 100, elapsed: 100, duration: 170.86, capturedAt: at(0))
        rig.tick(first, at: at(0))
        rig.browserCorrection = (first.identityKey, at(1), false, { 100 + $0.timeIntervalSince(replayT0) - 1.45 })
        rig.tick(mediaControl(bundle, "Boston", anchor: 100, elapsed: 102, duration: 170.86, capturedAt: at(2)), at: at(2))
        if bundle == safariMediaID {
            expectEqual(near(rig.shown(at: at(2)), 102), true, "回放·整秒读数: Safari 忽略,屏上仍是 Safari 的钟")
        } else {
            expectEqual(near(rig.shown(at: at(2)), 100.55), true, "回放·整秒读数: Chrome 采信(锚点会冻住,仍要靠它)")
        }
    }
}

/// 读数时刻补偿:App 启动那一拍主线程晚处理 0.87s,Safari 的读数按读到的时刻补到处理那一刻。
@MainActor
private func replayCaptureLag() {
    let rig = ReplayRig("capture-lag")
    defer { rig.tearDown() }
    rig.tick(mediaControl(safariMediaID, "Miree", anchor: 120.431, elapsed: 160.0, duration: 242.61, capturedAt: at(-0.87)), at: at(0))
    expectEqual(near(rig.shown(at: at(0)), 160.87), true, "回放·读数时刻: 补上 0.87s 处理延迟")
    let late = ReplayRig("capture-lag-stale")
    defer { late.tearDown() }
    late.tick(mediaControl(safariMediaID, "Miree", anchor: 120.431, elapsed: 160.0, duration: 242.61, capturedAt: at(-3)), at: at(0))
    expectEqual(near(late.shown(at: at(0)), 160.0), true, "回放·读数时刻: 超过 2s 当读数不可信,不补")
}

/// 汽水音乐:开播锚点晚打、整首恒定落后;播放器曲中重发一次真值锚点时学到滞后量(第一份直接采信),
/// 下一首开播直接预置(滞后 0.43)。
@MainActor
private func replaySodaAnchorLag() {
    let rig = ReplayRig("soda-lag")
    defer { rig.tearDown() }
    let soda = PlaybackPlayer.soda.bundleIdentifier
    let lag = 0.43
    for t in stride(from: 0.0, through: 98, by: 2) {
        rig.tick(mediaControl(soda, "My Anata", anchor: 0, elapsed: 0.3 + t, duration: 104), at: at(t))
    }
    rig.tick(mediaControl(soda, "My Anata", anchor: 100.3 + lag, elapsed: 100.3 + lag, duration: 104), at: at(100))
    let table = rig.defaults.string(forKey: "np:anchorLagByPlayer")
        .flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
    expectEqual(near(table[soda], lag, 0.01), true,
                "回放·汽水锚点滞后: 曲中重发的真值锚点学到 0.43(\(table[soda].map { String(format: "%.3f", $0) } ?? "nil"))")
    rig.tick(mediaControl(soda, "情话", anchor: 0, elapsed: 0.2, duration: 200), at: at(104.2))
    expectEqual(near(rig.shown(at: at(104.2)), 0.2 + lag, 0.01), true, "回放·汽水锚点滞后: 下一首开播预置 +0.43")
}

/// 精确读数是页面自己的钟,不在流读数的钟域里:流上已有自然切歌估的偏置时,不能先扣那份旧偏置再比。
/// 场景:上一首自然放完,新曲锚点比页面早打 0.5s → 自然切歌估出偏置 0.5;之后精确读数与屏上一致,不该动。
@MainActor
private func replaySafariPreciseReadingOverNaturalBias() {
    let rig = ReplayRig("safari-precise-over-natural")
    defer { rig.tearDown() }
    for t in stride(from: 0.0, through: 28, by: 2) {
        rig.tick(mediaControl(safariMediaID, "Intro", anchor: 0, elapsed: t, duration: 30, capturedAt: at(t)), at: at(t))
    }
    func stream(_ t: Double) -> Double { t - 29.5 }
    func page(_ t: Double) -> Double { t - 30 }
    let next = mediaControl(safariMediaID, "Miree", anchor: 0, elapsed: stream(30.4), duration: 242.61, capturedAt: at(30.4))
    rig.tick(next, at: at(30.4))
    expectEqual(near(rig.source.replayReportedBiasSecs, 0.5, 0.01), true,
                "回放·Safari 精确读数叠自然切歌: 自然切歌先估出偏置 0.5(实际 \(String(format: "%.3f", rig.source.replayReportedBiasSecs)))")
    rig.browserCorrection = (next.identityKey, at(32), true, { page($0.timeIntervalSince(replayT0)) })
    rig.tick(mediaControl(safariMediaID, "Miree", anchor: 0, elapsed: stream(32.4), duration: 242.61, capturedAt: at(32.4)), at: at(32.4))
    expectEqual(near(rig.shown(at: at(32.4)), page(32.4)), true,
                "回放·Safari 精确读数叠自然切歌: 与页面的钟一致就不动(扣了旧偏置会被拉回 0.5s)")
}

/// helper 的暂停状态是权威值:元数据速率仍为 1 时,App 消费结果后也不能继续推进位置。
@MainActor
private func replayPausedHelperWithResidualRate() {
    for bundle in [PlaybackPlayer.qqMusic, .netease, .soda, .kkbox, .amazonMusic, .spotify, .appleMusic].map(\.bundleIdentifier) {
        let rig = ReplayRig("paused-helper-\(bundle)")
        defer { rig.tearDown() }
        rig.tick(mediaControl(bundle, "Song", anchor: 0, elapsed: 18, duration: 232), at: at(0))
        let payload: [String: Any] = ["title": "Song", "artist": "Fujii Kaze", "album": "Prema", "duration": 232,
                                     "elapsedTime": 20, "anchorElapsedTime": 20, "playing": false,
                                     "playbackRate": 1, "isMusicApp": true, "bundleIdentifier": bundle]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let paused = try? JSONDecoder().decode(MediaControlSnapshot.self, from: data) else {
            expectEqual(false, true, "helper 暂停快照能解码(\(bundle))")
            continue
        }
        rig.tick(paused, at: at(2))
        expectEqual(near(rig.shown(at: at(62)), 20, 0.001), true,
                    "helper 暂停且 rate=1: 一分钟后位置仍冻结在 20 秒(\(bundle))")
    }
}
