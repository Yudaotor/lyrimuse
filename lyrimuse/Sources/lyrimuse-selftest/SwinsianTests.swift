import Foundation
import LyrimuseCore

/// Swinsian:通知与脚本读数的解法、位置表(两份锚点取最新、脚本整秒核对出跳转、盯整秒跳变对时)、按开着的文件认曲目、接线契约。
/// 时刻照真机录到的数(咔哒文件 2 秒一声,声音从 0 秒起出在 11.049;`t(x)` = 1793959900 + x)。
@MainActor
func runSwinsianTests() {
    typealias I = SwinsianPlayerInfo
    typealias H = SwinsianPlayhead
    func t(_ x: Double) -> Date { Date(timeIntervalSince1970: 1_793_959_900 + x) }
    func near(_ a: Double, _ b: Double, _ tol: Double = 0.03) -> Bool { abs(a - b) <= tol }

    // ---- 通知 ----
    do {
        let info: [AnyHashable: Any] = ["title": "Click A", "artist": "", "currentTime": NSNumber(value: 4.8625),
                                        "path": "/m/Click A.wav", "length": NSNumber(value: 12.0)]
        let paused = I.Notice(name: I.pausedNotification, userInfo: info, at: t(24.1145))
        expectEqual([paused?.playing, paused?.stopped], [false, false], "Swinsian 通知: 暂停那条")
        expectEqual(paused?.position, 4.8625, "Swinsian 通知: currentTime 是那一刻的位置")
        expectEqual(paused?.path, "/m/Click A.wav", "Swinsian 通知: 带当前文件")
        expectEqual(I.Notice(name: I.playingNotification, userInfo: info, at: t(0))?.playing, true, "Swinsian 通知: 在放那条")
        expectEqual(I.Notice(name: "com.swinsian.Swinsian-Other", userInfo: info, at: t(0)) == nil, true,
                    "Swinsian 通知: 别的名字不认")
        expectEqual(I.Notice(name: I.playingNotification, userInfo: ["currentTime": NSNumber(value: 1)], at: t(0)) == nil, true,
                    "Swinsian 通知: 没有歌名不认")
        let notice = I.Notice(name: I.playingNotification, userInfo: ["title": "Orange Moon", "artist": "方大同",
                                                                      "currentTime": NSNumber(value: 0)], at: t(1))!
        expectEqual([I.matches(notice, title: "Orange Moon", artist: "方大同"), I.matches(notice, title: "Orange Moon", artist: "别人"),
                     I.matches(notice, title: "Karma", artist: "方大同")], [true, false, false],
                    "Swinsian 通知: 歌名、歌手都对上才算这一首")
        expectEqual(I.anchor(from: notice, track: "k", title: "Orange Moon", artist: "方大同"),
                    H.Anchor(track: "k", elapsed: 0, at: t(1), playing: true), "Swinsian 通知: 换成锚点")
        let stopped = I.Notice(name: I.stoppedNotification, userInfo: ["title": "Orange Moon", "currentTime": NSNumber(value: 0)],
                               at: t(2))
        expectEqual(I.anchor(from: stopped, track: "k", title: "Orange Moon", artist: "方大同") == nil, true,
                    "Swinsian 通知: 停住那条不当锚点")
    }

    // ---- 脚本读数 ----
    do {
        let reading = I.scriptReading(from: Data(#"{"state":"playing","title":"Click A","path":"/m/Click A.wav","position":4}"#.utf8))
        expectEqual(reading?.playing, true, "Swinsian 脚本: 解出在放")
        expectEqual(reading.flatMap { I.check($0, title: "Click A", from: t(1), to: t(1.02)) },
                    H.Check(position: 4, from: t(1), to: t(1.02)), "Swinsian 脚本: 说的是这一首就换成核对")
        expectEqual(reading.flatMap { I.check($0, title: "Click B", from: t(1), to: t(1.02)) } == nil, true,
                    "Swinsian 脚本: 不是这一首不核对(换歌那一拍)")
        let pausedReading = I.scriptReading(from: Data(#"{"state":"paused","title":"Click A","path":"","position":4}"#.utf8))
        expectEqual(pausedReading.flatMap { I.check($0, title: "Click A", from: t(1), to: t(1.02)) } == nil, true,
                    "Swinsian 脚本: 暂停着不核对")
        expectEqual(I.scriptReading(from: Data("null".utf8)) == nil, true, "Swinsian 脚本: 没在放回 null")
        expectEqual(I.tick(from: Data(#"{"value":1,"before":1793959912033,"after":1793959912051}"#.utf8)),
                    H.Tick(value: 1, at: t(12.042)), "Swinsian 脚本: 跳变时刻取前后两次读数的中间")
        expectEqual(I.tick(from: Data("null".utf8)) == nil, true, "Swinsian 脚本: 没盯到")
    }

    // ---- 位置表的几个零件 ----
    do {
        let a = H.Anchor(track: "k", elapsed: 0, at: t(10.8548), playing: true)
        let b = H.Anchor(track: "k", elapsed: 0, at: t(11.3032), playing: true)
        expectEqual(H.newest([a, b, nil], track: "k", playing: true), b, "Swinsian 表: 两份锚点取最新的")
        expectEqual(H.newest([a, H.Anchor(track: "other", elapsed: 0, at: t(20), playing: true)], track: "k", playing: true), a,
                    "Swinsian 表: 别的曲目的锚点不算")
        expectEqual(H.newest([a, H.Anchor(track: "k", elapsed: 3, at: t(20), playing: false)], track: "k", playing: true), a,
                    "Swinsian 表: 播放状态跟这一拍不一样的不算")

        let clock = H.adopt(nil, anchor: b)
        expectEqual([clock.base, clock.precise ? 1 : 0, clock.wantsTick ? 1 : 0], [0, 0, 1],
                    "Swinsian 表: 新锚点先按它走,不准、要盯跳变")
        expectEqual(H.adopt(clock, anchor: a), clock, "Swinsian 表: 比采信那份旧的锚点不换")
        var precise = H.calibrated(clock, tick: H.Tick(value: 1, at: t(12.042)))
        expectEqual([precise.base, precise.precise ? 1 : 0, precise.wantsTick ? 1 : 0], [1, 1, 0],
                    "Swinsian 表: 盯到跳变,从那一刻起是准的")
        expectEqual(near(H.position(precise, now: t(15.049)), 4.0), true, "Swinsian 表: 准的表推到第 4 秒那一声")
        let sameEvent = H.Anchor(track: "k", elapsed: 1.2, at: t(12.3), playing: true)
        let kept = H.adopt(precise, anchor: sameEvent)
        expectEqual([kept.base, kept.precise ? 1 : 0], [1, 1], "Swinsian 表: 准的表遇到差不过 0.45 秒的锚点不换")
        expectEqual(kept.anchor, sameEvent, "Swinsian 表: 但记下它,下一拍不再拿它比")
        let jumped = H.adopt(precise, anchor: H.Anchor(track: "k", elapsed: 1, at: t(19.9533), playing: true))
        expectEqual([jumped.base, jumped.precise ? 1 : 0], [1, 0], "Swinsian 表: 差得远的是跳转了,重起一段")

        // 脚本整秒核对
        let consistent = H.checked(precise, H.Check(position: 3, from: t(14.5), to: t(14.52)))
        expectEqual(consistent, precise, "Swinsian 核对: 推出来落在报的那一秒里,不动")
        let seek = H.checked(precise, H.Check(position: 1, from: t(16.5), to: t(16.52)))
        expectEqual([seek.base, seek.precise ? 1 : 0, seek.wantsTick ? 1 : 0], [1.5, 0, 1],
                    "Swinsian 核对: 差得远按报的那一秒中间重起,再盯跳变")
        expectEqual(abs(seek.baseAt.timeIntervalSince(t(16.51))) < 0.001, true, "Swinsian 核对: 从读数那一段的中间起算")
        let lateAnchor = H.adopt(nil, anchor: H.Anchor(track: "k", elapsed: 0, at: t(11.6), playing: true))
        let nudged = H.checked(lateAnchor, H.Check(position: 1, from: t(12.2), to: t(12.22)))
        expectEqual(near(nudged.base, 1.05, 0.001), true, "Swinsian 核对: 差得近的挪进报的那一秒")
        precise.playing = false
        expectEqual(H.checked(precise, H.Check(position: 9, from: t(30), to: t(30.02))), precise,
                    "Swinsian 核对: 停着的表不核对")

        // 盯跳变的边界
        let far = H.calibrated(clock, tick: H.Tick(value: 9, at: t(12)))
        expectEqual([far.precise ? 1 : 0, far.wantsTick ? 1 : 0, far.tickAttempts], [0, 1, 1],
                    "Swinsian 跳变: 跟这一段差太多的不采信,下一拍再盯")
        var live = precise
        live.playing = true
        let due = H.rechecked(live, now: t(12.042 + H.recheckSecs))
        expectEqual([due.precise ? 1 : 0, due.wantsTick ? 1 : 0], [1, 1],
                    "Swinsian 复核: 量准的表隔一段再盯一次跳变(不到一秒的跳转整秒核对看不出来),盯的时候仍算准")
        expectEqual(H.rechecked(live, now: t(12.042 + H.recheckSecs - 1)), live, "Swinsian 复核: 没到时候不盯")
        expectEqual(H.rechecked(clock, now: t(60)), clock, "Swinsian 复核: 还没量准的不另起复核")
        let corrected = H.calibrated(due, tick: H.Tick(value: 22, at: t(33.4)))
        expectEqual([corrected.base, corrected.precise ? 1 : 0, corrected.wantsTick ? 1 : 0], [22, 1, 0],
                    "Swinsian 复核: 盯到的跳变跟表差零点几秒,按跳变改过来")
        var tries = clock
        for _ in 0..<H.maxTickAttempts { tries = H.calibrated(tries, tick: nil) }
        expectEqual([H.wantsTick(tries) ? 1 : 0, tries.tickAttempts], [0, H.maxTickAttempts], "Swinsian 跳变: 盯满次数不再盯")
    }

    // ---- 真机录到的一段,逐拍回放 ----
    // A 从暂停的 0 秒开播:通知 10.8548、系统 11.3032(晚 0.25 秒);整秒跳到 1 在 12.042。
    // B 播放中脚本跳到 1 秒(两份锚点都不报):15.85 下的指令,声音在 16.065 到 1 秒。
    // C 系统指令跳到 1 秒:系统锚点 19.9533(早 0.22 秒),跳到 1 在 20.1995。
    // D 暂停在 4.8625(两份一致),25.6588 恢复(系统),通知 25.7589 才到(晚 0.11 秒),跳到 5 在 25.8。
    // E 自然连到 Click B:系统 32.2146(早 0.38 秒)、通知 32.3804(早 0.215 秒),声音从 0 秒起出在 32.595,跳到 1 在 33.597。
    do {
        let a = "Click A", b = "Click B"
        func sys(_ track: String, _ e: Double, _ x: Double, _ playing: Bool = true) -> H.Anchor {
            H.Anchor(track: track, elapsed: e, at: t(x), playing: playing)
        }
        func check(_ s: Int, _ x: Double) -> H.Check { H.Check(position: s, from: t(x), to: t(x + 0.02)) }
        var clock: H.Clock?

        clock = H.advance(clock, track: a, playing: true, system: sys(a, 0, 11.3032), notice: sys(a, 0, 10.8548),
                          check: check(0, 11.9))
        expectEqual(clock.map { near(H.position($0, now: t(12)), 0.951, 0.3) }, true, "Swinsian 回放 A: 开播先按最新那份锚点")
        clock = clock.map { H.calibrated($0, tick: H.Tick(value: 1, at: t(12.042))) }
        expectEqual(clock.map { near(H.position($0, now: t(15.049)), 4) }, true, "Swinsian 回放 A: 对过时之后第 4 秒那一声对上")

        clock = H.advance(clock, track: a, playing: true, system: sys(a, 0, 11.3032), notice: sys(a, 0, 10.8548),
                          check: check(1, 16.5))
        expectEqual(clock.map { near(H.position($0, now: t(16.51)), 1.445, 0.1) }, true,
                    "Swinsian 回放 B: 锚点没动、脚本整秒对不上,认出播放中跳转")
        clock = clock.map { H.calibrated($0, tick: H.Tick(value: 2, at: t(17.065))) }
        expectEqual(clock.map { near(H.position($0, now: t(19.065)), 4) }, true, "Swinsian 回放 B: 跳转后对时")

        clock = H.advance(clock, track: a, playing: true, system: sys(a, 1, 19.9533), notice: sys(a, 0, 10.8548),
                          check: check(0, 20.1))
        expectEqual(clock?.precise, false, "Swinsian 回放 C: 系统指令跳转的锚点重起一段")
        clock = clock.map { H.calibrated($0, tick: H.Tick(value: 1, at: t(20.1995))) }
        expectEqual(clock.map { near(H.position($0, now: t(23.175)), 4) }, true, "Swinsian 回放 C: 对时后第 4 秒那一声对上")

        clock = H.advance(clock, track: a, playing: false, system: sys(a, 4.86252, 24.0747, false),
                          notice: sys(a, 4.8625, 24.1145, false), check: nil)
        expectEqual(clock.map { H.position($0, now: t(25)) }, 4.8625, "Swinsian 回放 D: 暂停着报暂停锚点的位置")
        clock = H.advance(clock, track: a, playing: true, system: sys(a, 4.86252, 25.6588), notice: nil, check: nil)
        clock = H.advance(clock, track: a, playing: true, system: sys(a, 4.86252, 25.6588), notice: sys(a, 4.8625, 25.7589),
                          check: check(4, 25.77))
        clock = clock.map { H.calibrated($0, tick: H.Tick(value: 5, at: t(25.8))) }
        expectEqual(clock.map { near(H.position($0, now: t(26.785)), 6) }, true, "Swinsian 回放 D: 恢复后对时,第 6 秒那一声对上")
        let resumed = clock
        clock = H.advance(clock, track: a, playing: true, system: sys(a, 4.86252, 25.6588), notice: sys(a, 4.8625, 25.7589),
                          check: check(8, 28.9))
        expectEqual(clock, resumed, "Swinsian 回放 D: 同一份锚点、核对对得上,表不动")

        clock = H.advance(clock, track: b, playing: true, system: sys(b, 0, 32.2146), notice: sys(b, 0, 32.3804),
                          check: check(0, 32.9))
        expectEqual(clock.map { near(H.position($0, now: t(32.595)), 0, 0.25) }, true, "Swinsian 回放 E: 换歌按通知那份锚点起")
        clock = clock.map { H.calibrated($0, tick: H.Tick(value: 1, at: t(33.597))) }
        expectEqual(clock.map { near(H.position($0, now: t(36.595)), 4) }, true, "Swinsian 回放 E: 对时后第 4 秒那一声对上")
        clock = H.advance(clock, track: b, playing: true, system: sys(b, 0, 32.2146), notice: sys(b, 0, 32.3804), check: nil)
        expectEqual(clock?.precise, true, "Swinsian 回放 E: 准了之后同一份锚点不再把它打回去")
        expectEqual(H.advance(nil, track: b, playing: true, system: nil, notice: nil, check: check(3, 35)) == nil, true,
                    "Swinsian 回放: 一份锚点都没有不起表(照用系统那份)")
    }

    // ---- 按开着的文件认曲目 ----
    do {
        let swinsian = PlaybackPlayer.swinsian.bundleIdentifier
        expectEqual(PlayerOpenFile.bundleIDs.contains(swinsian), true, "Swinsian 文件: 按开着的文件认当前文件")
        let split = PlayerOpenFile.fileNameIdentity(reportedArtist: "", reportedTitle: "AJR - Karma", fileName: "AJR - Karma.mp3",
                                                    duration: nil, acceptsBaseName: true)
        expectEqual([split?.artist, split?.title], ["AJR", "Karma"], "Swinsian 文件: 没写标签时报的是去扩展名的文件名,按「 - 」拆")
        expectEqual(CoverArtReplacementGate.missingArtworkUsesMatchedCover(bundleID: swinsian), true,
                    "Swinsian 封面: 文件里没嵌、同目录也没有,用匹配到的封面")
    }

    // ---- 接线 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let source = src("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(sourceHas(source, "guard !SourceKnockout.isOut(.swinsianNotice),\nlet notice = SwinsianPlayerInfo.Notice(name: note.name.rawValue, userInfo: note.userInfo, at: Date())")
                    && sourceHas(source, "SwinsianPlayerInfo.note(notice)"),
                    true, "Swinsian 接线: 收到通知记下当锚点(能拔掉)")
        expectEqual(sourceHas(source, "self?.handlePlayerInfoChanged(freezeExtrapolation: !notice.playing, stateSignal: true,\nresumeSignal: notice.playing)"),
                    true, "Swinsian 接线: 通知是暂停、恢复的即时信号")
        expectEqual(sourceHas(source, "SwinsianPlayerInfo.currentFilePath(rawTitle: snapshot.title)"), true,
                    "Swinsian 接线: 开着的文件认不到时按通知、脚本给的路径写 local_file")
        let client = src("LyrimuseCore/Local/MediaControlClient.swift")
        expectEqual(sourceHas(client, "swinsian: () => \\(SwinsianPlayerInfo.script)"), true, "Swinsian 接线: 常驻 osascript 能跑它的脚本")
        expectEqual(sourceHas(client, "elapsedTime: amazonPosition ?? radioPosition ?? pine?.position ?? swinsian?.position ?? foobarLoop ?? stretched,")
                    && sourceHas(client, "if pine?.precise == true || swinsian?.precise == true { snapshot.positionIsPrecise = true }"),
                    true, "Swinsian 接线: 主路径的位置换成那块表,量准了标精确")
        expectEqual(sourceHas(client, "if target.bundleID == SwinsianPlayerInfo.bundleID {\nsnapshot = swinsianProbedSnapshot(probed.snapshot, anchor: probed.anchor, now: now)"),
                    true, "Swinsian 接线: 焦点被占时单问到的那份也过那块表")
        let head = src("LyrimuseCore/Local/SwinsianPlayhead.swift")
        expectEqual(sourceHas(head, "guard !SourceKnockout.isOut(.swinsianScript) else { return false }"), true,
                    "Swinsian 接线: 盯跳变能拔掉")
    }
}
