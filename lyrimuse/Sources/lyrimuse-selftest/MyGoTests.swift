import Foundation
import LyrimuseCore

/// MyGo Music:开始出声那一刻报的锚点按混音缓冲和设备延迟往后挪(输出关掉后重开按另一档)、封面那份锚点沿用开播那份,
/// 以及接线契约。
@MainActor
func runMyGoTests() {
    typealias A = MyGoSessionAnchor
    let base = 1_794_163_589.901163
    func ts(_ offset: Double) -> String { MediaControlMicros.timestampString((base + offset) * 1_000_000)! }
    func secs(_ s: String?) -> Double { s.flatMap { MediaControlMicros.date(fromTimestampString: $0)?.timeIntervalSince1970 } ?? -1 }
    func near(_ s: String?, _ want: Double) -> Bool { abs(secs(s) - want) < 0.000_01 }
    let latency = 0.026
    let shift = A.mixAheadSecs + latency

    // ---- 在放的锚点往后挪 ----
    do {
        let out = A.fill(identity: "|Click A|", playing: true, elapsed: 0.018, timestamp: ts(0), rate: 1, outputLatency: latency,
                         state: A.State())
        expectEqual(out.elapsed, 0.018, "MyGo 锚点: 位置不动")
        expectEqual(near(out.timestamp, base + shift), true, "MyGo 锚点: 时刻往后挪混音缓冲加设备延迟")
        expectEqual(out.state.anchor?.rawTimestamp, ts(0), "MyGo 锚点: 记下原时刻")
        let again = A.fill(identity: "|Click A|", playing: true, elapsed: 0.018, timestamp: ts(0), rate: 1, outputLatency: latency,
                           state: out.state)
        expectEqual(again.timestamp, out.timestamp, "MyGo 锚点: 同一份锚点再解码一次不再挪")
        let seek = A.fill(identity: "|Click A|", playing: true, elapsed: 19, timestamp: ts(6), rate: 1, outputLatency: latency,
                          state: out.state)
        expectEqual(near(seek.timestamp, base + 6 + shift), true, "MyGo 锚点: 跳转那份同样挪")
        let negative = A.fill(identity: "|Click A|", playing: true, elapsed: 3, timestamp: ts(0), rate: 1, outputLatency: -1,
                              state: A.State())
        expectEqual(near(negative.timestamp, base + A.mixAheadSecs), true, "MyGo 锚点: 设备延迟读成负数按 0 算")
        let fresh = A.fill(identity: "|Click A|", playing: true, elapsed: 0, timestamp: ts(0), rate: 1, outputLatency: latency,
                           state: A.State())
        expectEqual(near(fresh.timestamp, base + shift), true, "MyGo: 没见过它停下(刚接手)按输出开着挪")
    }

    // ---- 暂停帧不动,记下停下的时刻 ----
    do {
        let last = A.Anchor(identity: "|Click A|", elapsed: 0.018, rawTimestamp: ts(0), timestamp: ts(shift), rate: 1)
        let paused = A.fill(identity: "|Click A|", playing: false, elapsed: 5.851, timestamp: ts(6), rate: 0, outputLatency: latency,
                            state: A.State(anchor: last))
        expectEqual(paused.elapsed, 5.851, "MyGo 暂停帧: 位置原样")
        expectEqual(paused.timestamp, ts(6), "MyGo 暂停帧: 时刻原样")
        expectEqual(paused.state.anchor == nil, true, "MyGo 暂停帧: 不留开播锚点")
        expectEqual(abs((paused.state.pausedAt ?? 0) - (base + 6)) < 0.000_01, true, "MyGo 暂停帧: 记下停下的时刻")
        expectEqual(paused.state.pausedIdentity, "|Click A|", "MyGo 暂停帧: 记下停下的是哪一首")
        let rateZero = A.fill(identity: "|Click A|", playing: true, elapsed: 5.851, timestamp: ts(6), rate: 0, outputLatency: latency,
                              state: A.State())
        expectEqual(rateZero.timestamp, ts(6), "MyGo: 在放但速率 0 的不挪")
        expectEqual(rateZero.state.pausedAt != nil, true, "MyGo: 在放但速率 0 的同样算停下")
        let starting = A.fill(identity: "|Click B|", playing: false, elapsed: 0, timestamp: ts(20), rate: 1, outputLatency: latency,
                              state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(starting.timestamp, base + 20 + shift), true, "MyGo: 暂停中换歌,新歌先以没在放、速率 1 到的那一拍同样挪")
        let confirmed = A.fill(identity: "|Click B|", playing: true, elapsed: 0, timestamp: ts(20), rate: 1, outputLatency: latency,
                               state: starting.state)
        expectEqual(confirmed.timestamp, starting.timestamp, "MyGo: 随后在放的那一拍是同一份锚点,不再挪")
        let coldStarting = A.fill(identity: "|Click A|", playing: false, elapsed: 6.1, timestamp: ts(66), rate: 1, outputLatency: latency,
                                  state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(coldStarting.timestamp, base + 66 + A.coldLeadSecs + latency), true, "MyGo: 同一首停久了先以速率 1 到的那一拍按重开输出那一档")
    }

    // ---- 停下不到 / 超过输出关闭的时长再出声 ----
    do {
        let warm = A.fill(identity: "|Click A|", playing: true, elapsed: 6.1, timestamp: ts(10), rate: 1, outputLatency: latency,
                          state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(warm.timestamp, base + 10 + shift), true, "MyGo 恢复: 停了 4 秒,输出还开着,照常挪")
        let cold = A.fill(identity: "|Click A|", playing: true, elapsed: 6.1, timestamp: ts(66), rate: 1, outputLatency: latency,
                          state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(cold.timestamp, base + 66 + A.coldLeadSecs + latency), true, "MyGo 恢复: 停了一分钟,输出已关,按重开输出那一档挪")
        expectEqual(cold.state.pausedAt == nil, true, "MyGo 恢复: 用过的停下时刻清掉")
        let bluetooth = A.fill(identity: "|Click A|", playing: true, elapsed: 6.1, timestamp: ts(66), rate: 1, outputLatency: latency,
                               outputBuiltIn: false, state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(bluetooth.timestamp, base + 66 + shift), true,
                    "MyGo 恢复: 输出不是内置扬声器(蓝牙耳机)时重开输出不比开着时晚,停久了照常挪(实测早 0.31~0.54 秒)")
        let coldNext = A.fill(identity: "|Click B|", playing: true, elapsed: 0, timestamp: ts(66), rate: 1, outputLatency: latency,
                              state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(coldNext.timestamp, base + 66 + shift), true, "MyGo: 停久了换成别的歌照常挪(新歌载入跟输出开着时一样早)")
    }

    // ---- 封面那份锚点 ----
    do {
        let start = A.fill(identity: "陈奕迅|浮夸|Solidays", playing: true, elapsed: 0.001, timestamp: ts(0), rate: 1,
                           outputLatency: latency, state: A.State())
        let cover = A.fill(identity: "陈奕迅|浮夸|Solidays", playing: true, elapsed: 0.000, timestamp: ts(0.544), rate: 1,
                           outputLatency: latency, state: start.state)
        expectEqual(cover.timestamp, start.timestamp, "MyGo 封面锚点: 开播后约 0.5 秒那份沿用开播那份的时刻")
        expectEqual(cover.elapsed, 0.001, "MyGo 封面锚点: 沿用开播那份的位置")
        let late = A.fill(identity: "陈奕迅|浮夸|Solidays", playing: true, elapsed: 0.000, timestamp: ts(1.5), rate: 1,
                          outputLatency: latency, state: start.state)
        expectEqual(near(late.timestamp, base + 1.5 + shift), true, "MyGo 封面锚点: 隔得久的不算(跳回开头)")
        let other = A.fill(identity: "陈奕迅|K歌之王|你的陈奕迅", playing: true, elapsed: 0.001, timestamp: ts(0.5), rate: 1,
                           outputLatency: latency, state: start.state)
        expectEqual(near(other.timestamp, base + 0.5 + shift), true, "MyGo 封面锚点: 换了一首的不算")
        let midway = A.fill(identity: "陈奕迅|浮夸|Solidays", playing: true, elapsed: 8, timestamp: ts(0.6), rate: 1,
                            outputLatency: latency, state: start.state)
        expectEqual(near(midway.timestamp, base + 0.6 + shift), true, "MyGo 封面锚点: 位置不在开头的不算(跳转)")
    }

    // ---- 焦点被占时单问的那份 ----
    do {
        let raw = MediaControlMicros.timestampString(base * 1_000_000)
        expectEqual(raw, ts(0), "MyGo 单问: 锚点秒数换成跟主路同一种时刻写法(同一份锚点两边认得出)")
        let out = A.fill(identity: "|Click M|", playing: true, elapsed: 0.2, timestamp: raw, rate: 1, outputLatency: latency,
                         state: A.State())
        let at = Date(timeIntervalSince1970: base + 3)
        let pos = A.position(elapsed: out.elapsed, timestamp: out.timestamp, rate: 1, playing: true, now: at) ?? -1
        expectEqual(abs(pos - (0.2 + 3 - shift)) < 0.000_01, true, "MyGo 单问: 位置按挪过的锚点推到此刻")
        let early = A.position(elapsed: 0, timestamp: out.timestamp, rate: 1, playing: true,
                               now: Date(timeIntervalSince1970: base + 0.1))
        expectEqual(early, 0, "MyGo 单问: 还没出声时不推到 0 以前")
        expectEqual(A.position(elapsed: 5, timestamp: ts(0), rate: 0, playing: false, now: at) == nil, true,
                    "MyGo 单问: 停着的不推,照单问那份原样用")
        expectEqual(A.position(elapsed: 5, timestamp: nil, rate: 1, playing: true, now: at) == nil, true,
                    "MyGo 单问: 缺锚点时刻的不推")
        let half = A.position(elapsed: 10, timestamp: ts(0), rate: 0.5, playing: true, now: at) ?? -1
        expectEqual(abs(half - 11.5) < 0.000_01, true, "MyGo 单问: 按速率推")
    }

    // ---- 单曲循环回绕(它回绕时一份锚点都不发) ----
    do {
        typealias MC = MediaControlClient
        let mygo = PlaybackPlayer.mygoMusic.bundleIdentifier
        expectEqual(MC.loopsWithoutNewAnchor(bundleID: mygo), true, "MyGo 循环: 回绕时不发新锚点,在名单里")
        let looped = MC.foobarLoopPosition(bundleID: mygo, playing: true, position: 30.1, duration: 22)
        expectEqual(looped.map { ($0 * 1000).rounded() / 1000 }, 8.1, "MyGo 循环: 越过曲长按曲长取余(实测每圈正好一个曲长,回绕间隙约 0.01 秒)")
        expectEqual(MC.foobarLoopPosition(bundleID: mygo, playing: true, position: 66.5, duration: 22)
                        .map { ($0 * 1000).rounded() / 1000 }, 0.5, "MyGo 循环: 第三圈起同样取余")
        expectEqual(MC.foobarLoopPosition(bundleID: mygo, playing: false, position: 30.1, duration: 22), nil, "MyGo 循环: 停着不动")
        let t = Date(timeIntervalSince1970: 2_000)
        expectEqual(MC.foobarLoopCheckAt(bundleID: mygo, playing: true, position: 20, duration: 22, now: t)
                        .map { ($0.timeIntervalSince(t) * 1000).rounded() / 1000 }, 2.15, "MyGo 循环: 离曲尾不到 3 秒时排一次补查")
    }

    // ---- 插件流没有时长:按它进度条的最大值补 ----
    do {
        typealias S = PineVolume.Slider
        expectEqual(MyGoPlayerUI.progressMax([S(min: 0, max: 315.193469387, value: 0)]), 315.193469387,
                    "MyGo 时长: 进度条的最大值就是解出来的时长(李志插件那首系统那份没有时长,进度条 315.19)")
        expectEqual(MyGoPlayerUI.progressMax([S(min: 0, max: 1, value: 0.05), S(min: 0, max: 259.3, value: 12)]), 259.3,
                    "MyGo 时长: 音量条(0~1)不算")
        expectEqual(MyGoPlayerUI.progressMax([S(min: 0, max: 200, value: 0), S(min: 0, max: 300, value: 0)]) == nil, true,
                    "MyGo 时长: 不止一根像进度条的不猜")
        expectEqual(MyGoPlayerUI.progressMax([S(min: 0, max: .infinity, value: 0)]) == nil, true, "MyGo 时长: 无限长不算")
        expectEqual(MyGoPlayerUI.progressMax([]) == nil, true, "MyGo 时长: 读不到滑块为 nil")
        expectEqual(MyGoPlayerUI.accepts(223.268571428, previous: 223.268571428), false,
                    "MyGo 时长: 换歌后进度条还是上一首的长度不认(《天空之城》→《家乡》一直停在 223.27,实际 343.3)")
        expectEqual(MyGoPlayerUI.accepts(223.27, previous: 223.06), false, "MyGo 时长: 上一首的时长是系统那份报的,差零点几秒也算同一个")
        expectEqual(MyGoPlayerUI.accepts(343.3, previous: 223.27), true, "MyGo 时长: 跟上一首不一样的照常采用")
        expectEqual(MyGoPlayerUI.accepts(315.19, previous: nil), true, "MyGo 时长: 不知道上一首多长时照常采用")
        var s = MediaControlSnapshot.forReplay(title: "山阴路的夏天", artist: "李志", album: "108个关键词", duration: nil,
                                               elapsedTime: 3, playing: true, playbackRate: 1,
                                               bundleIdentifier: PlaybackPlayer.mygoMusic.bundleIdentifier, anchorElapsedTime: 3)
        s.processIdentifier = 75789
        s.republishDueBy = Date(timeIntervalSince1970: 5)
        s.positionIsPrecise = true
        let filled = MediaControlClient.withFilledDuration(s, 315.2)
        expectEqual([filled.trackDuration, filled.elapsedTime], [315.2, 3], "MyGo 时长: 补上时长,位置不动")
        expectEqual(filled.processIdentifier == 75789 && filled.republishDueBy == s.republishDueBy && filled.positionIsPrecise == true, true,
                    "MyGo 时长: 进程号、补查时刻、精确档跟着带过去")
    }

    // ---- 接线 ----
    do {
        typealias L = LocalPlaybackSource
        let mygo = PlaybackPlayer.mygoMusic.bundleIdentifier
        expectEqual(L.resumeReadingNeverLeads(bundleID: mygo), true, "MyGo 接线: 锚点挪过之后恢复那一拍原样采信,不按暂停位置封顶")
        expectEqual(L.learnsAnchorLag(bundleID: mygo), false, "MyGo 接线: 锚点在解码时已挪准,不再学锚点滞后")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let client = (try? String(contentsOfFile: root.appendingPathComponent("LyrimuseCore/Local/MediaControlClient.swift").path,
                                  encoding: .utf8)) ?? ""
        expectEqual(sourceHas(client, "let mygo = MyGoSessionAnchor.filled("), true, "MyGo 接线: 解码系统会话时挪锚点")
        expectEqual(sourceHas(client, "timestamp = mygo.timestamp"), true, "MyGo 接线: 下游拿到的是挪过的时刻")
        expectEqual(sourceHas(client, "snapshot.republishDueBy = foobarLoopCheckAt(bundleID: probed.bundleIdentifier"), true,
                    "MyGo 接线: 焦点被占时单问那份同样取余、排补查")
        expectEqual(client.components(separatedBy: "MyGoPlayerUI.duration(trackKey: ").count - 1, 2,
                    "MyGo 接线: 主路和焦点被占时单问那份都按进度条补时长")
        expectEqual(client.components(separatedBy: "MyGoPlayerUI.noteDuration(trackKey: ").count - 1, 2,
                    "MyGo 接线: 主路和焦点被占时单问那份都记下报了的时长,给下一首认进度条是不是旧的")
        let ui = (try? String(contentsOfFile: root.appendingPathComponent("LyrimuseCore/Local/MyGoPlayerUI.swift").path,
                              encoding: .utf8)) ?? ""
        expectEqual(sourceHas(ui, "accepts(duration, previous: previous)"), true, "MyGo 接线: 进度条读数先跟上一首比过再采用")
        expectEqual(client.components(separatedBy: "snapshot = mygoProbedSnapshot(probed.snapshot, anchor: probed.anchor, now: now)").count - 1,
                    2, "MyGo 接线: 焦点被占时两处单问(暂停焦点顶替、焦点回退第二级)都过同一套挪法")
        if let latency = AudioOutputRoute.outputLatencySecs() {
            expectEqual(latency >= 0 && latency < 1, true, "MyGo 接线: 默认输出设备的延迟读得到、在合理范围")
        }
    }
}
