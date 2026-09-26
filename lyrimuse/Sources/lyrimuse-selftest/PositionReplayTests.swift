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
    var route: AudioOutputRoute.Current?
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
            spotifyProbeRequestConfirmation: { _ in })
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
                          playing: Bool = true, capturedAt: Date? = nil, startCorrection: Double? = nil) -> MediaControlSnapshot {
    .forReplay(title: title, artist: "Fujii Kaze", album: "Prema", duration: duration, elapsedTime: elapsed,
               playing: playing, playbackRate: playing ? 1 : 0, bundleIdentifier: bundle, anchorElapsedTime: anchor,
               capturedAt: capturedAt, anchorStartCorrection: startCorrection)
}

@MainActor
func runPositionReplayTests() {
    replaySpotifyManualStart()
    replaySpotifyAfterAd()
    replaySpotifySameTrackJump()
    replaySpotifyStartLeadMigration()
    replaySafariResumeStall()
    replaySafariFloorReadingIgnored()
    replaySafariPreciseReadingOverNaturalBias()
    replayCaptureLag()
    replayKugouStartCorrectionPublished()
    replaySodaAnchorLag()
    replayBrowserProbeReopensOnEveryTrackChange()
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
    expectEqual(near(learned, 0.24 * 0.7 + trueLead * 0.3, 0.002), true,
                "回放·Spotify 手动点播: 暂停反推的 0.271 按 α=0.3 学进 fresh(\(learned.map { String(format: "%.4f", $0) } ?? "nil"))")
    expectEqual(rig.startLeadTable["afterAd"], nil, "回放·Spotify 手动点播: 不碰 afterAd")
}

/// 广告放完接着放:广告报 29.99s、29.09s 就结束,新曲的钟与旧曲接不上 0.5s 以内 → 旧版判成 fresh。
/// 上一首是广告时归 afterAd(先验 0.66);真实领先 0.766 学进 afterAd,fresh 不动。
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
        let expectedLead = previousWasAd ? 0.66 : 0.24
        let label = previousWasAd ? "广告之后" : "对照(上一首不是广告)"
        expectEqual(near(rig.source.replayReportedBiasSecs, expectedLead, 0.001), true,
                    "回放·Spotify \(label): 扣 \(expectedLead)(实际 \(String(format: "%.3f", rig.source.replayReportedBiasSecs)))")
        guard previousWasAd else { continue }
        rig.source.replayPlayerStateEvent(at: at(19), freeze: true)
        let frozen = raw(19) - 0.766 + LocalPlaybackSource.spotifyPauseFadeSecs
        rig.tick(spotify("還是會寂寞", artist: "陳綺貞", raw: frozen, duration: 272.29, playing: false), at: at(19.3))
        let table = rig.startLeadTable
        expectEqual(near(table["afterAd"], 0.66 * 0.7 + 0.766 * 0.3, 0.002), true,
                    "回放·Spotify 广告之后: 暂停反推的 0.766 学进 afterAd(\(table["afterAd"].map { String(format: "%.4f", $0) } ?? "nil"))")
        expectEqual(table["fresh"], nil, "回放·Spotify 广告之后: fresh 不被这个样本污染")
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

/// 旧版本学的表(没有版本号):fresh 混着广告之后的样本,读表那一刻作废、退回先验;别的档原样保留。
@MainActor
private func replaySpotifyStartLeadMigration() {
    let rig = ReplayRig("spotify-migration")
    defer { rig.tearDown() }
    rig.defaults.set(["fresh": 0.542, "gapless": 0.705, "seek": 0.466], forKey: "np:spotifyStartLeadByKind")
    rig.tick(spotify("蝴蝶", raw: 0.076, duration: 283.2), at: at(0))
    expectEqual(near(rig.source.replayReportedBiasSecs, 0.24, 0.001), true,
                "回放·起播领先表迁移: 旧 fresh 0.542 作废,按先验 0.24 扣")
    expectEqual(rig.defaults.object(forKey: "np:spotifyStartLeadSchema") as? Int, LocalPlaybackSource.spotifyStartLeadSchema,
                "回放·起播领先表迁移: 版本号写回")
    expectEqual(rig.startLeadTable, ["gapless": 0.705, "seek": 0.466], "回放·起播领先表迁移: 只删 fresh")
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
    expectEqual(rig.biasWrites.last.map { near($0.biasSecs, stall, 0.005) && $0.bundleID == safariMediaID && $0.anchorElapsed == 205 }, true,
                "回放·Safari 恢复卡顿: 偏置对着恢复锚点写给 collector")
    rig.tick(mediaControl(safariMediaID, title, anchor: 205, elapsed: stream(26.33), duration: 231, capturedAt: at(26.33)), at: at(26.33))
    expectEqual(near(rig.shown(at: at(26.33)), page(26.33)), true, "回放·Safari 恢复卡顿: 下一拍流读数扣偏置后不被伺服拽回")
    // Safari 因时长微调重发锚点(真值):偏置作废,屏上仍在页面的钟上。
    rig.tick(mediaControl(safariMediaID, title, anchor: page(40), elapsed: page(40), duration: 230.91, capturedAt: at(40)), at: at(40))
    expectEqual(rig.source.replayReportedBiasSecs, 0, "回放·Safari 恢复卡顿: Safari 重发锚点即作废偏置")
    expectEqual(near(rig.shown(at: at(40)), page(40)), true, "回放·Safari 恢复卡顿: 重发之后仍对齐")
    expectEqual(rig.biasWrites.last?.biasSecs, 0, "回放·Safari 恢复卡顿: 作废也通知 collector")
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

/// 酷狗自然切歌的起播修正在读数层补过(快照已含),collector 读的是原始锚点:要按"对着原始锚点的负偏置"写给它;
/// 下一首没有修正时写一条 0 把它作废。
@MainActor
private func replayKugouStartCorrectionPublished() {
    let rig = ReplayRig("kugou-start")
    defer { rig.tearDown() }
    let kugou = PlaybackPlayer.kugou.bundleIdentifier
    rig.tick(mediaControl(kugou, "GABBA GABBA", anchor: 0.02, elapsed: 1.5, duration: 180, startCorrection: 0.548), at: at(0))
    let record = rig.biasWrites.last
    expectEqual(record.map { near($0.biasSecs, -0.548, 0.0005) && $0.anchorElapsed == 0.02 && $0.bundleID == kugou }, true,
                "回放·酷狗起播修正: 写给 collector 的是对着原始锚点 0.02 的 −0.548")
    rig.tick(mediaControl(kugou, "天际", anchor: 0.01, elapsed: 0.3, duration: 200), at: at(2))
    expectEqual(rig.biasWrites.last?.biasSecs, 0, "回放·酷狗起播修正: 下一首没有修正就写 0 作废")
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
