import Foundation
import LyrimuseCore

/// foobar2000:开播锚点随封面重报那一份不采信、按开着的文件认当前文件、光盘占位图、没封面时用匹配到的、播放顺序与音量、
/// 失焦时的菜单、播放列表、没写标签的文件名、接线契约。
/// 锚点照真机录到的数(media-control `--micros`,咔哒文件 2 秒一声,第一份锚点跟出声差 0.03~0.06 秒)。
@MainActor
func runFoobarTests() {
    typealias MC = MediaControlClient
    let foobar = PlaybackPlayer.foobar2000.bundleIdentifier
    func micros(_ seconds: Double) -> String { MediaControlMicros.timestampPrefix + String(Int64((seconds * 1_000_000).rounded())) }

    // ---- 开播锚点随封面重报 ----
    do {
        let startTS = 1_793_281_213.250
        let start = MC.PlayingAnchor(track: "Lyrimuse格式测试|稻香 AAC", elapsed: 0, timestamp: micros(startTS),
                                     instant: Date(timeIntervalSince1970: startTS))
        let now = Date(timeIntervalSince1970: 1_793_281_213.9)
        func stale(_ elapsed: Double, at ts: Double, bundleID: String? = PlaybackPlayer.foobar2000.bundleIdentifier,
                   last: MC.PlayingAnchor? = nil, track: String = "Lyrimuse格式测试|稻香 AAC") -> Bool {
            MC.isStaleAnchorRepublish(last: last ?? start, track: track, elapsed: elapsed, timestamp: micros(ts),
                                      duration: 223.453, bundleID: bundleID, now: now)
        }
        expectEqual(stale(0.083117, at: 1_793_281_213.883), true, "foobar 重报: 封面到时位置 0.08 秒、起播点晚 0.55 秒的那份不采信(实测样本)")
        expectEqual(stale(0, at: 1_793_281_213.792), true, "foobar 重报: 位置报成 0 的那份按 republishesZeroAnchor 不采信(实测样本)")
        expectEqual(PlaybackPlayer.foobar2000.republishesZeroAnchor, true, "foobar 重报: 开播 0 锚点会重报")
        expectEqual(stale(0.083117, at: 1_793_281_213.883, bundleID: PlaybackPlayer.soda.bundleIdentifier), false,
                    "foobar 重报: 位置不为 0 的那条只对 foobar2000")
        expectEqual(stale(0.35, at: 1_793_281_214.1), false, "foobar 重报: 位置到 0.3 秒以上的是真锚点(拖动)")
        expectEqual(stale(0.2, at: 1_793_281_215.0), false, "foobar 重报: 推出的起播点晚过 1.5 秒的是真锚点")
        expectEqual(stale(0.2, at: 1_793_281_213.4), false, "foobar 重报: 推出的起播点没往后挪的是真锚点")
        let playing = MC.PlayingAnchor(track: "Lyrimuse格式测试|稻香 AAC", elapsed: 8.5, timestamp: micros(startTS),
                                       instant: Date(timeIntervalSince1970: startTS))
        expectEqual(stale(0.083117, at: 1_793_281_213.883, last: playing), false, "foobar 重报: 上一份不是开播锚点时不认")
        expectEqual(stale(0.083117, at: 1_793_281_213.883, track: "Lyrimuse格式测试|稻香 FLAC"), false, "foobar 重报: 换了歌不认")
        expectEqual(MC.isFoobarArtworkRepublish(last: start, elapsed: 0, timestamp: micros(1_793_281_213.792), bundleID: foobar),
                    false, "foobar 重报: 位置为 0 的不归这条(归 republishesZeroAnchor 那条)")
    }

    // ---- 单曲循环绕回开头 ----
    do {
        func loop(_ position: Double?, playing: Bool? = true, bundle: String? = PlaybackPlayer.foobar2000.bundleIdentifier,
                  duration: Double? = 12) -> Double? {
            MC.foobarLoopPosition(bundleID: bundle, playing: playing, position: position, duration: duration)
        }
        expectEqual(loop(26.5).map { ($0 * 1000).rounded() / 1000 }, 2.5, "foobar 循环: 第二圈起不再发锚点,越过曲长按曲长取余(实测每圈正好 12.000 秒)")
        expectEqual(loop(12.1), nil, "foobar 循环: 第一圈它自己会重发锚点(晚 0.07~0.13 秒),余量之内不动")
        expectEqual(loop(11.9), nil, "foobar 循环: 没越过曲长不动")
        expectEqual(loop(26.5, playing: false), nil, "foobar 循环: 暂停着不动")
        expectEqual(loop(26.5, bundle: PlaybackPlayer.pinePlayer.bundleIdentifier), nil, "foobar 循环: 回绕时会发新锚点的播放器不动")
        expectEqual(loop(26.5, duration: nil), nil, "foobar 循环: 没有时长(电台)不动")
        let t = Date(timeIntervalSince1970: 1_000)
        func check(_ position: Double) -> Double? {
            MC.foobarLoopCheckAt(bundleID: foobar, playing: true, position: position, duration: 12, now: t).map { $0.timeIntervalSince(t) }
        }
        expectEqual(check(11).map { ($0 * 1000).rounded() / 1000 }, 1.15, "foobar 循环: 离曲尾不到 3 秒时排一次补查,刚过绕回点那一刻")
        expectEqual([check(5), check(12.2)].map { $0 == nil }, [true, true], "foobar 循环: 离曲尾还远、已经过了绕回点都不排")

        func probed(_ elapsed: Double, playing: Bool = true, bundle: String = PlaybackPlayer.foobar2000.bundleIdentifier,
                    stretch: Double = 1) -> MediaControlSnapshot {
            var s = MediaControlSnapshot.forReplay(title: "Click Loop", artist: "Lyrimuse", album: "", duration: 12,
                                                   elapsedTime: elapsed, playing: playing, playbackRate: 1,
                                                   bundleIdentifier: bundle, anchorElapsedTime: 0.055)
            s.processIdentifier = 4242
            return MC.foobarProbedSnapshot(s, now: t, stretch: stretch)
        }
        let wrapped = probed(26.5)
        expectEqual([wrapped.elapsedTime, wrapped.anchorElapsedTime].map { $0.map { ($0 * 1000).rounded() / 1000 } }, [2.5, 2.5],
                    "foobar 单问: 焦点被占时单问那份越过曲长同样取余,位置和锚点一起换")
        expectEqual([wrapped.capturedAt == t, wrapped.processIdentifier == 4242], [true, true], "foobar 单问: 带上读到的时刻,进程号不丢")
        expectEqual(probed(11).republishDueBy.map { ($0.timeIntervalSince(t) * 1000).rounded() / 1000 }, 1.15,
                    "foobar 单问: 离曲尾不到 3 秒时同样排补查")
        expectEqual(probed(26.5, playing: false).elapsedTime, 26.5, "foobar 单问: 暂停着不动")
        expectEqual(probed(26.5, bundle: PlaybackPlayer.pinePlayer.bundleIdentifier).elapsedTime, 26.5, "foobar 单问: 只对 foobar2000")
        // 开着 DSP 变速、焦点被占着:按记着的速度换算锚点以来那段,速率交出去;换算后越过曲长再取余。
        let stretched = probed(8, stretch: 1.32)
        expectEqual([stretched.elapsedTime, stretched.playbackRate].map { $0.map { ($0 * 1000).rounded() / 1000 } }, [10.542, 1.32],
                    "foobar 单问: 变速时位置按记着的速度换算,速率也交出去")
        expectEqual(stretched.anchorElapsedTime, 0.055, "foobar 单问: 只变速、没取余时锚点留原值(同主路径)")
        let stretchedLoop = probed(10, stretch: 1.32)
        expectEqual([stretchedLoop.elapsedTime, stretchedLoop.anchorElapsedTime].map { $0.map { ($0 * 1000).rounded() / 1000 } },
                    [1.182, 1.182], "foobar 单问: 变速换算后越过曲长再取余,位置和锚点一起换")
        expectEqual(probed(8, playing: false, stretch: 1.32).elapsedTime, 8, "foobar 单问: 暂停着不按速度换算")
    }

    // ---- 当前文件、封面、轮询 ----
    do {
        expectEqual(PlayerOpenFile.bundleIDs.contains(foobar), true, "foobar 当前文件: 按它开着的文件认,路径交引擎读 .lrc")
        expectEqual(CoverArtReplacementGate.missingArtworkUsesMatchedCover(bundleID: foobar), true,
                    "foobar 封面: 文件没封面时用匹配到的")
        let disc = KnownPlaceholderArtwork.entries.filter { $0.player == foobar }
        expectEqual(disc.map(\.byteCount), [26589], "foobar 封面: 光盘占位图登记了一张")
        expectEqual(LocalPlaybackSource.pollsFastWhilePaused(bundleID: foobar, pausedFor: 30), true,
                    "foobar 轮询: 刚暂停那段按播放档轮询(恢复只有事件流一条即时信号)")
        expectEqual(LocalPlaybackSource.positionSourceTier(forBundleID: foobar), .precise, "foobar 位置: 锚点准,归 precise")
        expectEqual([foobar, PlaybackPlayer.lxMusic.bundleIdentifier, PlaybackPlayer.soda.bundleIdentifier].map {
            LocalPlaybackSource.waitsForOutputDeviceOnColdStart(bundleID: $0) }, [true, true, false],
                    "foobar 冷恢复: 设备停着时等它转起来才算起点(按下后锚点早 0.3~0.6 秒),跟洛雪一样;别家不动")
        expectEqual(TornTrackHold.arrivesWhole(bundle: foobar), true, "foobar 换歌: 一帧报齐,不按撕裂快照按住")
    }

    // ---- 播放顺序、音量、失焦时的菜单 ----
    do {
        typealias F = FoobarMenuControl
        expectEqual(["Default", "Repeat (playlist)", "Repeat (track)", "Random", "Shuffle (tracks)", "Shuffle (albums)",
                     "Shuffle (folders)", "Stop After Current"].map { F.mode(checkedTitle: $0)?.rawValue ?? "nil" },
                    ["list", "repeatAll", "repeatOne", "shuffle", "shuffle", "shuffle", "shuffle", "nil"],
                    "foobar 顺序: Order 七项对到四档,Random 和三种 Shuffle 都是随机")
        expectEqual(F.titleToPress(for: .shuffle, current: .list), "Shuffle (tracks)", "foobar 顺序: 开随机按 Shuffle (tracks)")
        expectEqual(F.titleToPress(for: .shuffle, current: .shuffle), nil, "foobar 顺序: 已经是随机(哪一种都算)不按")
        expectEqual(F.titleToPress(for: .list, current: .repeatOne), "Default", "foobar 顺序: 关循环按 Default")
        expectEqual(F.titleToPress(for: .repeatOne, current: nil), "Repeat (track)", "foobar 顺序: 读不出当前档也按")
        let t0 = Date(timeIntervalSince1970: 1_000)
        expectEqual(F.effective(read: .list, pending: (.repeatAll, t0), now: t0.addingTimeInterval(1)), .repeatAll,
                    "foobar 顺序: 刚按过 1 秒内以按下去的为准(勾 0.9 秒后才跟上)")
        expectEqual(F.effective(read: .list, pending: (.repeatAll, t0), now: t0.addingTimeInterval(3.5)), .list,
                    "foobar 顺序: 过了 3 秒照读到的勾")
        expectEqual(F.options, [.shuffle, .repeatAll, .repeatOne], "foobar 顺序: 随机、列表循环、单曲循环都有")
        let sliders = [PineVolume.Slider(min: 0, max: 223.453, value: 8), PineVolume.Slider(min: 0, max: 100, value: 10)]
        expectEqual(FoobarVolume.volumeIndex(sliders), 1, "foobar 音量: 取值 0~100 的那根")
        expectEqual(FoobarVolume.volumeIndex([PineVolume.Slider(min: 0, max: 100, value: 3), PineVolume.Slider(min: 0, max: 100, value: 10)]),
                    nil, "foobar 音量: 这首恰好 100 秒、两根都是 0~100 时不猜")
        expectEqual([FoobarVolume.percent(10.00000048932983), FoobarVolume.percent(-1), FoobarVolume.percent(130)], [10, 0, 100],
                    "foobar 音量: 四舍五入、越界夹住")
        expectEqual(MusicPlaybackController.supportsExtendedControls(.foobar2000), true, "foobar 顺序: 歌词窗口出随机、循环、音量")
        expectEqual(MusicPlaybackController.supportsRepeatOne(.foobar2000), true, "foobar 顺序: 有单曲循环")
        expectEqual(PlaybackPlayer.foobar2000.accessibilityUse == .pressesPlayMode, true, "foobar 权限: 跟 reAMP 同一条说明")
        typealias PMC = PlaybackMenuControl
        expectEqual(["Pause", "Play", "Next", "Previous", "Stop", "Random"].map { PMC.command(forMenuTitle: $0, player: .foobar2000)?.rawValue ?? "nil" },
                    ["toggle-play-pause", "nil", "next-track", "previous-track", "nil", "nil"],
                    "foobar 菜单: 播放 / 暂停只按 Pause(暂停着按也是接着放),Play 不认")
        expectEqual(PMC.players.contains(.foobar2000), true, "foobar 菜单: 失焦时能按菜单")
        expectEqual([PMC.startTitle(for: .foobar2000), PMC.startTitle(for: .pinePlayer), PMC.startTitle(for: .qqMusic)], ["Play", nil, nil],
                    "foobar 菜单: 停住 / 冷启动后开播按 Play(Pause 不理),别家照旧按播放 / 暂停")
        expectEqual(MusicPlaybackController.controlRoute(exclusivelyAppleMusic: false, focusFallback: nil, focusHeldElsewhere: true,
                                                         directQueryFallback: .foobar2000, mediaControlCommand: "next-track"),
                    .menuAccessibility(.foobar2000, .nextTrack), "foobar 菜单: 焦点被占时下一首按它的菜单")
    }

    // ---- 播放列表、没写标签的文件 ----
    do {
        typealias PL = FoobarPlaylist
        let text = "\u{FEFF}file:///Users/a/Music/Lyrimuse测试/reAMP/Click A.wav\nfile:///Users/a/Music/100%/b.flac\n\nhttp://x/y.mp3\n/Users/a/c.mp3\n"
        expectEqual(PL.paths(fplite: text), ["/Users/a/Music/Lyrimuse测试/reAMP/Click A.wav", "/Users/a/Music/100%/b.flac", "/Users/a/c.mp3"],
                    "foobar 列表: 去掉 BOM 和 file://,空格、中文、百分号原样留,网络地址跳过")
        let lists = [["/a/1.mp3", "/a/2.mp3"], ["/b/1.mp3", "/b/2.mp3", "/b/3.mp3"]]
        expectEqual(PL.pick(lists, current: "/b/2.mp3")?.count, 3, "foobar 列表: 挑含着当前文件的那一份")
        expectEqual(PL.pick(lists, current: "/c/9.mp3") == nil && PL.pick(lists, current: nil) == nil, true,
                    "foobar 列表: 哪份都不含、不知道当前文件时不交")
        let tagged = PL.track(path: "/m/x.mp3", tags: LocalAudioFileTags(title: "稻香", artist: "周杰伦", album: "魔杰座", duration: 223.4))
        expectEqual("\(tagged.title)|\(tagged.artist)|\(tagged.album)", "稻香|周杰伦|魔杰座", "foobar 列表: 有标签用标签")
        let untagged = PL.track(path: "/m/无标签 Mezzamo - Happy Boy.mp3", tags: LocalAudioFileTags(title: "", artist: "", album: "", duration: 40))
        expectEqual("\(untagged.title)|\(untagged.artist)|\(untagged.duration)", "Happy Boy|无标签 Mezzamo|40.0",
                    "foobar 列表: 没写标签的按文件名拆,跟真放到时同一份")
        expectEqual([PL.repeating(.shuffle), PL.repeating(.repeatAll), PL.repeating(.repeatOne), PL.repeating(.list), PL.repeating(nil)],
                    ["shuffle", "all", "one", "off", nil], "foobar 列表: 菜单的档交给引擎的写法")
        let id = PlayerOpenFile.fileNameIdentity(reportedArtist: "", reportedTitle: "无标签 Mezzamo - Happy Boy",
                                                 fileName: "无标签 Mezzamo - Happy Boy.mp3", duration: 40, acceptsBaseName: true)
        expectEqual("\(id?.artist ?? "nil")|\(id?.title ?? "nil")", "无标签 Mezzamo|Happy Boy", "foobar 没写标签: 不带扩展名的文件名也拆")
        expectEqual(PlayerOpenFile.fileNameIdentity(reportedArtist: "", reportedTitle: "无标签 Mezzamo - Happy Boy",
                                                    fileName: "无标签 Mezzamo - Happy Boy.mp3", duration: 40) == nil, true,
                    "foobar 没写标签: 别的播放器照旧只认带扩展名的")
        expectEqual(PlayerOpenFile.underscoringControls("回车检查\r\n第二行\t制表"), "回车检查__第二行_制表",
                    "foobar 标签里的控制字符: 各换成一个下划线,回车换行是两个")
        let multiline = LocalAudioFileTags(title: "换行检查\n第二行", artist: "测试\n歌手", album: "测试专辑", duration: 40)
        expectEqual(PlayerOpenFile.fileMatches(reportedArtist: "测试_歌手", reportedTitle: "换行检查_第二行", reportedDuration: 40,
                                               tags: multiline, fileName: "newline.mp3", underscoresControls: true), true,
                    "foobar 标签带换行: 它报成下划线也认得出是这个文件")
        expectEqual(PlayerOpenFile.fileMatches(reportedArtist: "测试_歌手", reportedTitle: "换行检查_第二行", reportedDuration: 40,
                                               tags: multiline, fileName: "newline.mp3"), false,
                    "foobar 标签带换行: 别的播放器照旧不把下划线当换行")

        // DSP 变速(Audio-Stretch)时它照报速率 1:按进度条量速度(见 02 章决策 211)。
        typealias S = FoobarStretch
        let t0 = Date(timeIntervalSince1970: 1_000)
        func sample(_ value: Double, _ secs: Double) -> S.Sample { S.Sample(value: value, at: t0.addingTimeInterval(secs)) }
        expectEqual(S.measuredRate(from: sample(10, 0), to: sample(15.28, 4)), 1.32, "foobar 变速: 隔 4 秒的两次读数算出 1.32 倍")
        expectEqual(S.measuredRate(from: sample(10, 0), to: sample(14, 3)) == nil, true, "foobar 变速: 间隔不到 4 秒不算")
        expectEqual(S.measuredRate(from: sample(10, 0), to: sample(14.12, 4)), 1, "foobar 变速: 偏离不到 5% 算 1 倍")
        expectEqual(S.measuredRate(from: sample(10, 0), to: sample(3, 4)) == nil, true, "foobar 变速: 读数倒退(跳转过)不算")
        expectEqual(abs(S.position(anchor: 10, oneX: 20, rate: 1.32) - 23.2) < 1e-9, true, "foobar 变速: 锚点以来那段乘速度")
        func at(_ secs: Double) -> Date { t0.addingTimeInterval(secs) }
        var tracker = S.step(S.Tracker(), anchorKey: "a", playing: true, sample: sample(0, 0), now: at(0))
        expectEqual(tracker.first == nil && tracker.probe == nil && tracker.rate == 1, true,
                    "foobar 变速: 锚点之后头 3 秒不取细量起点(进度条的落后还在涨),头一次读数也不当粗量起点")
        tracker = S.step(tracker, anchorKey: "a", playing: true, sample: sample(0.6, 0.5), now: at(0.5))
        tracker = S.step(tracker, anchorKey: "a", playing: true, sample: sample(3.6, 3), now: at(3))
        expectEqual(tracker.first == sample(3.6, 3) && tracker.rate == 1.2, true, "foobar 变速: 3 秒后取细量起点,粗量偏离够大先用粗量的")
        tracker = S.step(tracker, anchorKey: "a", playing: true, sample: sample(10.2, 8), now: at(8))
        expectEqual(tracker.rate, 1.32, "foobar 变速: 同一份锚点下隔 5 秒算出速度")
        tracker = S.step(tracker, anchorKey: "a", playing: true, sample: sample(16.9, 13), now: at(13))
        expectEqual(tracker.rate == 1.33 && tracker.first == sample(3.6, 3), true, "foobar 变速: 起点不动、拿更长的间隔重算")
        tracker = S.step(tracker, anchorKey: "b", playing: true, sample: sample(30, 14), now: at(14))
        expectEqual(tracker.rate == 1.33 && tracker.first == nil, true, "foobar 变速: 换锚点从头量、速度记着")
        tracker = S.step(tracker, anchorKey: "b", playing: false, sample: nil, now: at(20))
        expectEqual(tracker.first == nil && tracker.rate == 1.33, true, "foobar 变速: 停着不量")
        tracker = S.step(tracker, anchorKey: "c", playing: true, sample: sample(40, 20), now: at(20))
        tracker = S.step(tracker, anchorKey: "c", playing: true, sample: sample(40.3, 20.3), now: at(20.3))
        tracker = S.step(tracker, anchorKey: "c", playing: true, sample: sample(42.5, 22.5), now: at(22.5))
        expectEqual(tracker.rate, 1, "foobar 变速: 记着变速、锚点后头两次读数粗量是 1 倍就马上放掉")
        var looped = S.step(S.Tracker(), anchorKey: "l", playing: true, sample: sample(0.1, 0), now: at(0))
        for (value, secs) in [(3.1, 3.0), (7.1, 7.0), (11.1, 11.0), (1.1, 13.0), (5.1, 17.0), (9.1, 21.0)] {
            looped = S.step(looped, anchorKey: "l", playing: true, sample: sample(value, secs), now: at(secs))
        }
        expectEqual(looped.rate == 1 && looped.first == sample(5.1, 17), true,
                    "foobar 变速: 单曲循环绕回(同一份锚点下进度条往回跳)从那里重新量,跨圈的读数不算成慢放(实测量成 0.25~0.45 倍)")
        var gapped = S.step(S.Tracker(), anchorKey: "g", playing: true, sample: sample(0.1, 0), now: at(0))
        for (value, secs) in [(3.1, 3.0), (5.1, 5.0), (7.1, 37.0), (9.1, 39.0), (11.1, 41.0)] {
            gapped = S.step(gapped, anchorKey: "g", playing: true, sample: sample(value, secs), now: at(secs))
        }
        expectEqual(gapped.rate == 1 && gapped.first == sample(11.1, 41) && gapped.probe == sample(7.1, 37), true,
                    "foobar 变速: 隔了 30 秒才再读到(焦点被占那段不读)从那里重新量,不拿跨了几圈的旧读数算(实测量成 0.28 倍)")
        var fresh = S.step(S.Tracker(), anchorKey: "d", playing: true, sample: sample(0.5, 0), now: at(0))
        fresh = S.step(fresh, anchorKey: "d", playing: true, sample: sample(0.63, 0.1), now: at(0.1))
        fresh = S.step(fresh, anchorKey: "d", playing: true, sample: sample(3.23, 2.1), now: at(2.1))
        expectEqual(fresh.rate, 1.3, "foobar 变速: 记着 1 倍、粗量偏离 15% 以上先用粗量的")
        var slight = S.step(S.Tracker(), anchorKey: "e", playing: true, sample: sample(0.5, 0), now: at(0))
        slight = S.step(slight, anchorKey: "e", playing: true, sample: sample(0.6, 0.1), now: at(0.1))
        slight = S.step(slight, anchorKey: "e", playing: true, sample: sample(2.8, 2.1), now: at(2.1))
        expectEqual(slight.rate, 1, "foobar 变速: 粗量偏离不到 15% 不改,等细量")
        var resumed = S.Tracker()
        for (value, secs) in [(8.11, 0.0), (8.11, 0.6), (9.6, 1.1), (10.6, 2.1), (11.6, 3.1)] {
            resumed = S.step(resumed, anchorKey: "r", playing: true, sample: sample(value, secs), now: at(secs))
        }
        expectEqual(resumed.rate == 1 && resumed.probe == sample(9.6, 1.1), true,
                    "foobar 变速: 冷启动接着放时进度条先停在存下的位置再跳上来,停着那次读数不当粗量起点(实测误量成 1.26 倍)")
        let bars = [PineVolume.Slider(min: 0, max: 100, value: 40), PineVolume.Slider(min: 0, max: 223.453, value: 34.02)]
        expectEqual(FoobarSliders.progressIndex(bars, duration: 223.4), 1, "foobar 进度条: 最大值对上时长的那一根")
        expectEqual(FoobarSliders.progressIndex([bars[0], PineVolume.Slider(min: 0, max: 100, value: 7)], duration: 100) == nil, true, "foobar 进度条: 恰好 100 秒跟音量分不出时不认")
    }

    // ---- 接线契约 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func sourceText(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = sourceText("LyrimuseCore/Local/MediaControlClient.swift")
        expectEqual(sourceHas(client, "if isFoobarArtworkRepublish(last: last, elapsed: elapsed, timestamp: timestamp, bundleID: bundleID) { return true }"),
                    true, "foobar 接线: 重报判定排在「位置逐毫秒相等」那道之前")
        expectEqual(sourceHas(client, "if bundleID == PinePlayerInfo.bundleID || bundleID == PlaybackPlayer.foobar2000.bundleIdentifier,"),
                    true, "foobar 接线: 推的是光盘时先找同目录的图")
        let idle = sourceText("lyrimuse/UI/IdlePlaybackActions.swift")
        expectEqual(sourceHas(sourceBody("static func resume(player: PlaybackPlayer) {", in: idle), "guard !resuming.contains(player) else { return }\nresuming.insert(player)")
                    && sourceHas(idle, "resuming.remove(player)\nif !ok { openPlayerApp(player) }"), true,
                    "停播页「继续播放」: 冷启动期间再点不另起一轮")
        expectEqual(sourceHas(idle, "PlayerBundleAliases.applicationURL(forBundleID: player.bundleIdentifier, includingOtherClients: false)")
                    && sourceHas(idle, "guard let url = PlayerBundleAliases.applicationURL(forBundleID: id) else { return }")
                    && !idle.contains("urlForApplication(withBundleIdentifier:"), true,
                    "停播页「继续播放」: 找 App 认别名(只装了别的版本也能启动、打开)")
        expectEqual(sourceHas(idle, "let outcome = PlaybackMenuControl.pressStart(for: player)"), true,
                    "foobar 接线: 停播页「继续播放」按开播那一项")
        expectEqual(sourceHas(idle, "return PlaybackMenuControl.isStopped(for: player) == false"), true,
                    "foobar 接线: 按了还停着(列表是空的)就算没放起来,退回打开它")
        expectEqual(sourceHas(client, "? FoobarStretch.rate(anchorKey: anchorKey, playing: playing == true && republish.hold == nil,"), true,
                    "foobar 接线: 在放、没卡住时按进度条量速度")
        expectEqual(sourceHas(client, "playbackRate: held ? 0 : (foobarRate != 1 && playing == true ? foobarRate : raw.playbackRate),"), true,
                    "foobar 接线: 量出的速度交给下游外推")
        expectEqual(sourceHas(client, "Self.foobarLoopPosition(bundleID: bundleID, playing: playing, position: stretched, duration: raw.duration)"), true,
                    "foobar 接线: 单曲循环按变速后的位置取余")
        expectEqual(sourceHas(client, "|| bundleID == PlaybackPlayer.foobar2000.bundleIdentifier {"), true,
                    "foobar 接线: 快照一律带上读到的时刻(冷启动接着放时换歌那一拍主线程晚 0.12 秒处理,不补就一直慢这么多)")
        let focusLost = sourceBody("private static func snapshotAfterFocusLost()", in: client)
        let pausedFocus = sourceBody("private static func pausedFocusReading(", in: client)
        expectEqual([focusLost.contains("snapshot = snapshot.map { foobarProbedSnapshot($0, now: now) }"),
                     pausedFocus.contains("snapshot = foobarProbedSnapshot(probed.snapshot, now: now)")], [true, true],
                    "foobar 接线: 焦点被占时单问的两条路(焦点回退、暂停焦点顶替)都过单曲循环取余")
        expectEqual(sourceHas(sourceText("LyrimuseCore/Local/FoobarStretch.swift"),
                              "let value = playing && !SourceKnockout.isOut(.foobarSlider) ? FoobarSliders.progress(duration: duration) : nil"), true,
                    "foobar 接线: 进度条那条腿能拔(foobar-slider)")
        let openFile = sourceText("LyrimuseCore/Local/PlayerOpenFile.swift")
        expectEqual(sourceHas(openFile, "foobar: bundleID == PlaybackPlayer.foobar2000.bundleIdentifier,"), true,
                    "foobar 接线: 按开着的文件认曲目时打开 foobar 那两条(不带扩展名的文件名、控制字符换下划线)")
        expectEqual(sourceHas(openFile, "fileName: fileName, underscoresControls: foobar)"), true,
                    "foobar 接线: 找文件时把控制字符那条交给比对")
        expectEqual(sourceHas(openFile, "guard let snapshot, !SourceKnockout.isOut(.playerFile),"), true,
                    "foobar 接线: 开着的文件那条腿能拔(player-file)")
        expectEqual(sourceHas(openFile, "guard !SourceKnockout.isOut(.playerFile), let bundleID, bundleIDs.contains(bundleID), let rawTitle"), true,
                    "foobar 接线: 拔了 player-file 不按开着的文件找同目录封面")
        expectEqual(sourceHas(openFile, "guard !SourceKnockout.isOut(.playerFile), let bundleID, bundleIDs.contains(bundleID), !title.isEmpty"), true,
                    "foobar 接线: 拔了 player-file 不写 local_file")
        expectEqual(sourceHas(openFile, "out.republishDueBy = snapshot.republishDueBy"), true,
                    "foobar 接线: 换成标签那份要带上补查时刻,不然曲尾那一查排不上")
        expectEqual(sourceHas(client, "elapsedTime: amazonPosition ?? radioPosition ?? pine?.position ?? swinsian?.position ?? foobarLoop ?? stretched,"), true,
                    "foobar 接线: 解码那一拍位置换成取余后的")
        expectEqual(sourceHas(openFile, "acceptsBaseName: baseName)") && sourceHas(openFile, "static let baseNameBundleIDs: Set<String> = [\nPlaybackPlayer.foobar2000.bundleIdentifier,"), true,
                    "foobar 接线: 认当前文件时没写标签的按不带扩展名的文件名拆")
    }
}
