import Foundation
import LyrimuseCore

/// Cog:位置那块表(开播、跳转、恢复补 0.33 秒、暂停接上、重发续接、按 Position 滑块校准与量速率)、认滑块、
/// Playlist 菜单里随机 / 循环两个子菜单的读写计划、音量滑块、失焦时的菜单标题、接线契约。数照真机录到的锚点时序。
@MainActor
func runCogTests() {
    typealias H = CogPlayhead
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func anchor(_ el: Double, _ s: Double, playing: Bool = true, track: String = "a") -> H.Anchor {
        H.Anchor(track: track, elapsed: el, at: at(s), playing: playing)
    }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    // ---- 来了锚点之后的表 ----
    do {
        let start = H.advance(nil, anchor: anchor(0, 0), now: at(0.01))
        expectEqual([start.kind == .start, start.base == 0, start.baseAt == at(0), start.sampleAt == at(0.01), !start.precise],
                    [true, true, true, true, true], "Cog 表: 0 秒锚点是开播,马上排一次读滑块")
        expectEqual(H.advance(start, anchor: anchor(0, 0.03), now: at(1)), start, "Cog 表: 时刻差 50 毫秒以内的同一份锚点原样交回")
        expectEqual(H.advance(start, anchor: anchor(0, 0.2), now: at(1)).kind, .start, "Cog 表: 隔开 0.2 秒的第二份 0 秒锚点重新开表")

        let seek = H.advance(start, anchor: anchor(42, 5), now: at(5))
        expectEqual([seek.kind == .seek, seek.base == 42, seek.sampleAt == at(5)], [true, true, true], "Cog 表: 对不上推算的锚点是跳转")

        let republish = H.advance(start, anchor: anchor(10, 10.1), now: at(10.1))
        expectEqual([republish.kind == .start, republish.base == 0, republish.baseAt == at(0), republish.anchor.elapsed == 10],
                    [true, true, true, true], "Cog 表: 每 10 秒那次重发落在推算 0.3 秒以内,接着用原来那块表")
        expectEqual(H.advance(start, anchor: anchor(10, 11), now: at(11)).kind, .seek, "Cog 表: 重发差出 1 秒算跳转")
        expectEqual(H.advance(start, anchor: anchor(10, 10.1, track: "b"), now: at(10.1)).kind, .seek, "Cog 表: 换了歌不续接上一首的表")

        let carried = H.advance(start, anchor: anchor(0, 0, playing: false), now: at(5))
        expectEqual([carried.kind == .paused, carried.pausedPosition.map { near($0, 5) } == true, carried.sampleAt == nil],
                    [true, true, true], "Cog 表: 刚报停、锚点还是在放时那份,停在表推到现在的位置")
        expectEqual(H.position(carried, now: at(30)), 5, "Cog 表: 暂停中位置不走")

        let paused = H.advance(nil, anchor: anchor(20, 0, playing: false), now: at(0))
        expectEqual(paused.pausedPosition.map { near($0, 20.33) }, true, "Cog 表: 没有表时暂停锚点补上恢复那 0.33 秒")
        expectEqual(H.advance(nil, anchor: anchor(0, 0, playing: false), now: at(0)).pausedPosition, 0, "Cog 表: 0 秒的暂停锚点不补")

        let resumed = H.advance(paused, anchor: anchor(20.001, 8), now: at(8.02))
        expectEqual([resumed.kind == .resume, near(resumed.base, 20.331), resumed.baseAt == at(8), resumed.sampleAt == at(8.02)],
                    [true, true, true, true], "Cog 表: 恢复锚点照报暂停那一刻的旧值,补 0.33 秒")
        expectEqual(H.advance(paused, anchor: anchor(20.5, 8), now: at(8)).kind, .seek, "Cog 表: 暂停后跳到别处再放不算恢复")

        // 暂停时没补发暂停锚点:表停在推到报停那一刻的 12.517,恢复锚点报暂停前最后一格滑块值 12.066
        let running = H.Clock(anchor: anchor(0, 0), kind: .start, base: 0.04, baseAt: at(0), precise: true)
        let carriedPause = H.advance(running, anchor: anchor(0, 0, playing: false), now: at(12.477))
        let staleResume = H.advance(carriedPause, anchor: anchor(12.066, 28), now: at(28.01))
        expectEqual([staleResume.kind == .resume, near(staleResume.base, 12.517), staleResume.sampleAt == at(28.01)], [true, true, true],
                    "Cog 表: 没补发暂停锚点时,恢复锚点落在停住位置往下 0.8 秒内算恢复,位置取停住的那个")
        expectEqual(near(H.advance(carriedPause, anchor: anchor(12.3, 28), now: at(28)).base, 12.63), true,
                    "Cog 表: 锚点补 0.33 秒比停住的位置靠后时取补过的")
        expectEqual(H.advance(carriedPause, anchor: anchor(11.6, 28), now: at(28)).kind, .seek, "Cog 表: 比停住的位置小 0.8 秒以上算跳转")
        expectEqual(H.advance(carriedPause, anchor: anchor(12.6, 28), now: at(28)).kind, .seek, "Cog 表: 比停住的位置靠后算跳转")
        let pausedSeek = H.advance(carriedPause, anchor: anchor(30, 20, playing: false), now: at(20))
        expectEqual([pausedSeek.kind == .paused, pausedSeek.pausedPosition == 30], [true, true],
                    "Cog 表: 停着时跳到别处,停住的位置就是跳到的值、不补")
        expectEqual(H.advance(carriedPause, anchor: anchor(12.2, 13, playing: false), now: at(13)).pausedPosition.map { near($0, 12.53) }, true,
                    "Cog 表: 停住后补发的暂停锚点(停住位置往下 0.8 秒内)照旧补 0.33 秒")
        let seekResume = H.advance(pausedSeek, anchor: anchor(30, 25), now: at(25))
        expectEqual([seekResume.kind == .resume, near(seekResume.base, 30.33)], [true, true],
                    "Cog 表: 停着跳转后恢复,恢复锚点照补 0.33 秒")
        let lateRepublish = H.advance(H.advance(start, anchor: anchor(10, 10.1), now: at(10.1)), anchor: anchor(10, 10.1, playing: false), now: at(15))
        let sameValue = H.advance(lateRepublish, anchor: anchor(10, 30), now: at(30))
        expectEqual([sameValue.kind == .resume, sameValue.base == 15], [true, true],
                    "Cog 表: 恢复锚点跟暂停那份同值,停住的位置远在其后也算恢复,位置取停住的那个")
        expectEqual(H.advance(H.advance(nil, anchor: anchor(0, 0, playing: false), now: at(0)), anchor: anchor(0, 3), now: at(3)).kind, .start,
                    "Cog 表: 0 秒暂停后开播算开播、不补")

        var fast = start
        fast.rate = 1.5
        expectEqual(H.advance(fast, anchor: anchor(42, 5), now: at(5)).rate, 1.5, "Cog 表: 跳转后沿用量到的速率")
        expectEqual(H.advance(fast, anchor: anchor(42, 5, track: "b"), now: at(5)).rate, 1.5, "Cog 表: 换歌后沿用量到的速率")
    }

    // ---- 位置与读滑块的时机 ----
    do {
        expectEqual([H.firstCheck(now: at(0)) == at(0.3), H.pendingCheck(at(0.3), sampling: true, now: at(0.2)) == at(0.3),
                     H.pendingCheck(at(0.3), sampling: true, now: at(0.31)).map { abs($0.timeIntervalSince(at(0.46))) < 1e-6 } == true, H.pendingCheck(at(0.3), sampling: false, now: at(0.31)) == nil,
                     H.pendingCheck(nil, sampling: true, now: at(1)) == nil],
                    [true, true, true, true, true], "Cog 补查: 开读 0.3 秒后查,到点还在读隔 0.15 秒再查,读完不排")
        var c = H.Clock(anchor: anchor(10, 0), kind: .seek, base: 10, baseAt: at(0), rate: 1.5, sampleAt: at(2))
        expectEqual(near(H.position(c, now: at(4)), 16), true, "Cog 位置: 按速率推")
        c.base = -1
        expectEqual(H.position(c, now: at(0)), 0, "Cog 位置: 不报负数")
        expectEqual([H.wantsSlider(c, now: at(1.9)), H.wantsSlider(c, now: at(2))], [false, true], "Cog 读滑块: 到了排的时刻才读")
        c.sampleAt = nil
        expectEqual(H.wantsSlider(c, now: at(9)), false, "Cog 读滑块: 没排就不读")
        let paused = H.Clock(anchor: anchor(10, 0, playing: false), kind: .paused, base: 10, baseAt: at(0), sampleAt: at(0))
        expectEqual(H.wantsSlider(paused, now: at(9)), false, "Cog 读滑块: 暂停中不读")
    }

    // ---- 量速率 ----
    do {
        func rate(_ dv: Double, _ dt: Double) -> Double? {
            H.measuredRate(from: H.Tick(value: 10, at: at(0)), to: H.Tick(value: 10 + dv, at: at(dt)))
        }
        expectEqual(rate(3.9, 3.9), nil, "Cog 速率: 隔不够 4 秒不量")
        expectEqual(rate(4.04, 4), 1, "Cog 速率: 差 2% 以内算原速")
        expectEqual(rate(6, 4), 1.5, "Cog 速率: 1.5 倍")
        expectEqual(rate(3.333, 5), 0.67, "Cog 速率: 保留两位")
        expectEqual(rate(0.8, 4), nil, "Cog 速率: 慢得离谱不采信")
        expectEqual(rate(-2, 5), nil, "Cog 速率: 倒退不采信")
    }

    // ---- 滑块跳格校准 ----
    do {
        let start = H.advance(nil, anchor: anchor(0, 0), now: at(0))
        let first = H.calibrated(start, tick: H.Tick(value: 3, at: at(3.4)))
        expectEqual([near(first.base, 3.04), first.baseAt == at(3.4), first.precise, first.rate == 1,
                     first.rateFrom == H.Tick(value: 3, at: at(3.4)), first.sampleAt == at(8.4)],
                    [true, true, true, true, true, true], "Cog 校准: 跳格值加滑块滞后 0.04 秒当基准,5 秒后再读")
        let steady = H.calibrated(first, tick: H.Tick(value: 8, at: at(8.4)))
        expectEqual([steady.rate == 1, near(steady.base, 8.04), steady.rateFrom == H.Tick(value: 8, at: at(8.4))], [true, true, true],
                    "Cog 校准: 第二次跳格隔够 4 秒,原速仍是 1、量完从这一跳起重新量")
        let faster = H.calibrated(steady, tick: H.Tick(value: 15.5, at: at(13.4)))
        let slower = H.calibrated(faster, tick: H.Tick(value: 19.25, at: at(18.4)))
        expectEqual([faster.rate, slower.rate], [1.5, 0.75], "Cog 校准: 中途改速,下一跳就按最近一段量")
        let tempo = H.calibrated(first, tick: H.Tick(value: 10.5, at: at(8.4)))
        expectEqual([tempo.rate == 1.5, near(tempo.base, 10.56)], [true, true], "Cog 校准: 开了变速量出 1.5 倍,滞后也按速率折")
        let back = H.calibrated(first, tick: H.Tick(value: 1, at: at(5)))
        expectEqual([back.rateFrom == H.Tick(value: 1, at: at(5)), back.rate == 1], [true, true], "Cog 校准: 读数倒退(循环回开头)从这里重新量")
        let wild = H.calibrated(start, tick: H.Tick(value: 30, at: at(3.4)))
        expectEqual([wild.precise, wild.base == 0, wild.sampleAt == at(8.4)], [false, true, true], "Cog 校准: 离推算太远不采信,只排下一次")
        let paused = H.Clock(anchor: anchor(10, 0, playing: false), kind: .paused, base: 10, baseAt: at(0))
        expectEqual(H.calibrated(paused, tick: H.Tick(value: 10, at: at(1))), paused, "Cog 校准: 暂停中不动")
        expectEqual(H.missed(start, found: true, now: at(1)).sampleAt, at(1.5), "Cog 校准: 滑块在、没跳格,0.5 秒后再试")
        expectEqual(H.missed(start, found: false, now: at(1)).sampleAt, at(6), "Cog 校准: 找不到滑块,5 秒后再试")
        expectEqual(H.missed(paused, found: true, now: at(1)), paused, "Cog 校准: 暂停中不排")
    }

    // ---- 认滑块 ----
    do {
        expectEqual([H.isPositionSlider(description: "Position", max: 200, duration: 200.5),
                     H.isPositionSlider(description: "Posición", max: 200, duration: 200),
                     H.isPositionSlider(description: nil, max: 200, duration: 200)],
                    [true, true, true], "Cog 进度条: 描述是 Position(西文 Posición)或认不出、最大值对得上时长")
        expectEqual([H.isPositionSlider(description: "Volume", max: 100, duration: 100),
                     H.isPositionSlider(description: nil, max: 100, duration: 100),
                     H.isPositionSlider(description: "Position", max: 200, duration: 210),
                     H.isPositionSlider(description: "Position", max: .nan, duration: 200)],
                    [false, false, false, false], "Cog 进度条: 音量那根、最大值对不上时长、NaN 都不认")
        expectEqual([CogVolume.isVolumeSlider(description: "Volume", min: 0, max: 100),
                     CogVolume.isVolumeSlider(description: "Volumen", min: 0, max: 100)],
                    [true, true], "Cog 音量: 描述是 Volume(西文 Volumen)、取值 0~100")
        expectEqual([CogVolume.isVolumeSlider(description: "Volume", min: 0, max: 1),
                     CogVolume.isVolumeSlider(description: "Position", min: 0, max: 100),
                     CogVolume.isVolumeSlider(description: nil, min: 0, max: 100)],
                    [false, false, false], "Cog 音量: 取值不是 0~100、描述不是音量都不认")
        typealias O = CogVolume.StepOutcome
        expectEqual([CogVolume.direction(target: 50, current: 50), CogVolume.direction(target: 60, current: 50),
                     CogVolume.direction(target: 40, current: 50)], [nil, true, false],
                    "Cog 音量: 到了不按,要大按 Volume Up,要小按 Volume Down")
        expectEqual([CogVolume.outcome(target: 60, before: 50, after: 50), CogVolume.outcome(target: 60, before: 50, after: 60),
                     CogVolume.outcome(target: 60, before: 50, after: 55), CogVolume.outcome(target: 60, before: 58, after: 63),
                     CogVolume.outcome(target: 60, before: 57, after: 61), CogVolume.outcome(target: 99, before: 98, after: 100),
                     CogVolume.outcome(target: 5, before: 22, after: 0), CogVolume.outcome(target: 60, before: 50, after: 45)],
                    [O.stop, .stop, .keepGoing, .stepBack, .stop, .stop, .stop, .stop],
                    "Cog 音量: 没动、到了、走反都停,越过时上一格更近才退回,碰到 0 / 100 那头不退")
        // Cog 的步进:增益 0~100 每下 ±5(调小不够 5 落到 0、调大封顶 100),滑块是增益开方 × 10。
        func run(from slider: Double, to target: Double) -> (final: Double, presses: Int, ok: Bool) {
            var gain = slider * slider / 100, presses = 0
            let ok = CogVolume.approach(target: target, from: slider) { up in
                presses += 1
                gain = up ? Swift.min(100, gain + 5) : (gain < 5 ? 0 : gain - 5)
                return (gain / 100).squareRoot() * 100
            }
            return ((gain / 100).squareRoot() * 100, presses, ok)
        }
        func best(from slider: Double, to target: Double) -> Double {
            let g0 = slider * slider / 100
            let ups = (0...20).map { Swift.min(100, g0 + Double($0) * 5) }
            let downs = (0...20).map { Swift.max(0, g0 - Double($0) * 5) } + [0]
            let reach = (target >= slider ? ups : downs).map { ($0 / 100).squareRoot() * 100 }
            return reach.map { abs($0 - target) }.min() ?? 0
        }
        var misses: [String] = [], maxPresses = 0
        for start in stride(from: 0.0, through: 100, by: 7) {
            for target in stride(from: 0.0, through: 100, by: 3) {
                let r = run(from: start, to: target)
                maxPresses = Swift.max(maxPresses, r.presses)
                let atBound = r.final <= 0 || r.final >= 100
                if !r.ok || !atBound && abs(abs(r.final - target) - best(from: start, to: target)) > 1e-9 { misses.append("\(start)→\(target)") }
            }
        }
        expectEqual(misses, [], "Cog 音量: 按菜单一下一下逼近,停在这个方向上能到的格里离目标最近的那格(落到 0 / 100 的另算)")
        expectEqual([run(from: 7, to: 6).final, run(from: 14, to: 99).final], [0, 100],
                    "Cog 音量: 越过目标落到 0 / 100 就停在那头(增益被夹住,反向一下回不到原格)")
        expectEqual(maxPresses <= 22, true, "Cog 音量: 从头到尾最多按 20 下出头(越过再退一下)")
        var calls = 0
        expectEqual(CogVolume.approach(target: 80, from: 50) { _ in calls += 1; return nil }, false,
                    "Cog 音量: 按不动或读不回整次算失败")
        expectEqual(calls, 1, "Cog 音量: 按不动就不再按")
    }

    // ---- 随机 / 循环 ----
    do {
        typealias M = CogMenuControl
        expectEqual([M.mode(repeat: .all, shuffle: .off), M.mode(repeat: .album, shuffle: .off),
                     M.mode(repeat: .one, shuffle: .off), M.mode(repeat: .off, shuffle: .off),
                     M.mode(repeat: .one, shuffle: .all), M.mode(repeat: .off, shuffle: .albums)],
                    [.repeatAll, .repeatAll, .repeatOne, .list, .shuffle, .shuffle],
                    "Cog 模式: 整张专辑循环算列表循环,随机(含按专辑)开着算随机")
        func plan(_ m: MusicPlaybackController.MusicPlaybackMode, _ r: M.Repeat, _ s: M.Shuffle) -> String {
            let p = M.presses(for: m, repeat: r, shuffle: s)
            return "\(p.repeat.map { "\($0)" } ?? "-")|\(p.shuffle.map { "\($0)" } ?? "-")"
        }
        expectEqual([plan(.shuffle, .all, .off), plan(.shuffle, .album, .albums), plan(.shuffle, .one, .off), plan(.shuffle, .one, .albums),
                     plan(.repeatAll, .album, .off), plan(.repeatAll, .off, .all),
                     plan(.repeatOne, .all, .off), plan(.repeatOne, .one, .albums),
                     plan(.list, .all, .all), plan(.list, .off, .off)],
                    ["-|all", "-|-", "off|all", "off|-", "-|-", "all|off", "one|-", "-|off", "off|off", "-|-"],
                    "Cog 模式: 只按要变的项,随机档关掉单曲循环、列表 / 专辑循环不动,其余档先关随机")
        expectEqual([M.checkedIndex(marks: ["", "\u{2713}", "", ""], count: 4),
                     M.checkedIndex(marks: [nil, nil, "\u{2713}", nil, nil, "\u{2713}"], count: 4),
                     M.checkedIndex(marks: ["\u{2713}", "\u{2713}", "", ""], count: 4),
                     M.checkedIndex(marks: ["", "", "", ""], count: 4),
                     M.checkedIndex(marks: ["\u{2713}", ""], count: 4)],
                    [1, 2, nil, nil, nil], "Cog 模式: 前几项里恰好一项打勾才认,分隔线后面的不看")
        expectEqual(M.options, [.shuffle, .repeatAll, .repeatOne], "Cog 模式: 三档都给")
    }

    // ---- 失焦时按的菜单项、档位登记 ----
    do {
        let titles = ["Play/Pause", "Reproducir/Pausar", "Next Song", "Próxima canción", "Previous Song", "Canción anterior", "Stop"]
        expectEqual(titles.map { PlaybackMenuControl.command(forMenuTitle: $0, player: .cog) },
                    [.playPause, .playPause, .nextTrack, .nextTrack, .previousTrack, .previousTrack, nil],
                    "Cog 菜单: Control 菜单的英文、西文标题(标题不随播放状态变)")
        expectEqual([MusicPlaybackController.supportsExtendedControls(.cog), MusicPlaybackController.supportsRepeatOne(.cog),
                     PlaybackPlayer.cog.accessibilityUse == .calibratesAndPressesPlayMode],
                    [true, true, true], "Cog 登记: 有模式和音量、能单曲循环、辅助功能用途")
    }

    // ---- 接线契约 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func sourceText(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = sourceText("LyrimuseCore/Local/MediaControlClient.swift")
        expectEqual(client.components(separatedBy: "snapshot = cogProbedSnapshot(probed.snapshot, anchor: probed.anchor, now: now)").count - 1, 2,
                    "Cog 接线: 焦点被占时单问的两条路都过那块表")
        expectEqual([sourceHas(client, "let cog = bundleID == CogPlayhead.bundleID && !isRadio"),
                     sourceHas(client, "cogRate ?? raw.playbackRate"),
                     sourceHas(client, "|| cog?.precise == true ||"),
                     sourceHas(client, "?? cog?.dueBy ??")],
                    [true, true, true, true], "Cog 接线: 位置、速率、精确档、补查时刻都从那块表来")
        expectEqual(sourceHas(sourceText("LyrimuseCore/Local/CogPlayhead.swift"), "guard !SourceKnockout.isOut(.cogSlider), AXIsProcessTrusted() else { return false }"),
                    true, "Cog 接线: 读滑块能拔掉(拔腿测试)")
        expectEqual(sourceHas(sourceText("lyrimuse/UI/IdlePlaybackActions.swift"), "case .swinsian, .kuwo, .cog: PlayerProcess.pid(bundleID: player.bundleIdentifier) != nil"),
                    true, "Cog 接线: 停播页只在它开着时给继续播放")
    }
}
