import Foundation
import LyrimuseCore

/// Amazon Music 的位置:日志重放 / 自记时 / 开播校准 / 陈旧元数据。样例 `shared/testdata/amazonmusic.log`
/// 跟 collector 的 amazonmusic_test.go 共用,两侧断言的数必须一致。
func runAmazonMusicTests() {
    typealias P = AmazonMusicPlayhead
    func at(_ hhmmss: String, _ frac: Double = 0) -> Date {
        P.lineTimestamp("260928:" + hhmmss)!.addingTimeInterval(frac)
    }
    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }

    // ---- 逐行解析 ----
    do {
        let started = P.parse(line: "260928:025131      Browser INFO in Harley : DT:M [TrackPreFetcher.cpp:74] new track playing : asin://B0TESTAAA1:13:87015")
        expectEqual(started?.event, .trackStarted("asin://B0TESTAAA1"), "Amazon 日志: 开播取 ASIN,去掉后面的内部编号")
        expectEqual(started?.lineTime, at("025131"), "Amazon 日志: 行首时刻按 UTC 解析")
        expectEqual(P.parse(line: "260928:030035      Browser INFO in Harley : DT:M [TrackPreFetcher.cpp:74] new track playing : podcast://dts.podtrac.com:443/redirect.mp3/x.mp3")?.event,
                    .trackStarted("podcast://dts.podtrac.com:443/redirect.mp3/x.mp3"), "Amazon 日志: 播客整段 URI 当标识")
        expectEqual(P.parse(line: "260928:025218      Browser INFO in Harley : 0x3151c8000 [PlaybackEngine.cpp:1127] setPaused(1)")?.event,
                    .paused, "Amazon 日志: 引擎那行 setPaused(1) 是暂停")
        expectEqual(P.parse(line: "260928:025218 MorphoBrowser : I HarleyPlayerController : PlayerFlow : PausingPlayer : function = setPaused , paused = true : line 391, ") == nil,
                    true, "Amazon 日志: 控制层那行暂停不认,免得算两次")
        expectEqual(P.parse(line: "260928:025456      Browser INFO in HarleyPlayerController : PlayerFlow line 878, function seek : Seeking to: 127990")?.event,
                    .seek(127.99), "Amazon 日志: 拖动目标毫秒换成秒")
        expectEqual(P.parse(line: "260928:025456      Browser INFO in Harley : 0x3151c8000 [PlaybackEngine.cpp:1193] seek ( id: 14 uri: asin://B0X, seek_time: 127990 )") == nil,
                    true, "Amazon 日志: 引擎那行 seek 不认,只认一行")
        expectEqual(P.parse(line: "260928:025131      Browser INFO in PlaybackListener line 255, function playbackStalled : Received callback with stalled state: 1 track_id: 13")?.event,
                    .stall(true), "Amazon 日志: 卡顿开始")
        expectEqual(P.parse(line: "[SystemInfo]") == nil, true, "Amazon 日志: 没有行首时刻的不认")
        expectEqual(P.parse(line: "260928:025132      Browser INFO in Harley : DT:M [DASHRangeFragmentLoader.cpp:100] Fetching fragment: <Track: asin://B0TESTAAA1:13:87015, FragmentIndex: 0>") == nil,
                    true, "Amazon 日志: 预读分片不是播放事件")
    }

    // ---- 整份样例重放(历史行取该秒 + 0.5) ----
    let sample = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shared/testdata/amazonmusic.log")
    let lines = ((try? String(contentsOf: sample, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    expectEqual(lines.count > 20, true, "Amazon 样例: 读得到 shared/testdata/amazonmusic.log")
    func replay(until end: Date) -> P.State {
        var s = P.State()
        for line in lines {
            guard let (t, e) = P.parse(line: line) else { continue }
            let when = t.addingTimeInterval(P.replayedLineOffset)
            if when > end { break }
            s = P.apply(e, at: when, to: s)
        }
        return s
    }
    do {
        var s = replay(until: at("025200"))
        expectEqual(s.trackID, "asin://B0TESTAAA1", "Amazon 重放: 第一首")
        expectEqual(near(P.position(s, at: at("025200")), 25.5), true, "Amazon 重放: 缓冲完(34.5)才起表")
        s = replay(until: at("025220"))
        expectEqual(near(P.position(s, at: at("025220")), 44.0), true, "Amazon 重放: 暂停冻结在 44 秒")
        expectEqual(s.paused, true, "Amazon 重放: 暂停中")
        s = replay(until: at("025300"))
        expectEqual(near(P.position(s, at: at("025300")), 81.5), true, "Amazon 重放: 恢复后接着走(卡顿同一秒起止不吃时间)")
        s = replay(until: at("025400"))
        expectEqual(s.trackID, "asin://B0TESTAAA2", "Amazon 重放: 切到下一首")
        expectEqual(near(P.position(s, at: at("025400")), 22.5), true, "Amazon 重放: 下一首从 0 起")
        s = replay(until: at("025500"))
        expectEqual(near(P.position(s, at: at("025500")), 130.49), true,
                    "Amazon 重放: 拖到 127.99,等到 kStarting(57.5)才接着走")
        let mid = replay(until: at("025456", 0.9))
        expectEqual(near(P.position(mid, at: at("025456", 0.9)), 127.99), true, "Amazon 重放: 拖动后没出声前停在目标位置")
        expectEqual(s.pristine, false, "Amazon 重放: 拖动过就不能再拿系统时间戳校准")
        s = replay(until: at("025700"))
        expectEqual(s.trackID, "asin://B0TESTAAA3", "Amazon 重放: 自然播完接下一首")
        expectEqual(near(P.position(s, at: at("025700")), 41.5), true, "Amazon 重放: 自然接歌从 0 起")
        s = replay(until: at("030100"))
        expectEqual(s.trackID?.hasPrefix("podcast://"), true, "Amazon 重放: 播客")
        expectEqual(near(P.position(s, at: at("030100")), 21.5), true, "Amazon 重放: 播客缓冲完才起表")
    }

    // ---- 开播校准 / 陈旧元数据 / 日志对不上 ----
    do {
        let s = replay(until: at("025200"))
        let md = at("025134", 0.872885)
        let c = P.calibrated(s, metadataTimestamp: md)
        expectEqual(near(P.position(c, at: at("025200")), 25.127115), true, "Amazon 校准: 起点换成系统微秒时间戳")
        let paused = replay(until: at("025300"))
        expectEqual(P.calibrated(paused, metadataTimestamp: md), paused, "Amazon 校准: 暂停过的不校准")
        expectEqual(P.metadataIsStale(s, metadataTimestamp: at("024343")), true,
                    "Amazon 陈旧: 元数据时间戳比日志开播早几分钟 = 上一次会话的旧曲目")
        expectEqual(P.metadataIsStale(s, metadataTimestamp: md), false, "Amazon 陈旧: 缓冲完才发的元数据不算旧")
        expectEqual(P.metadataIsStale(paused, metadataTimestamp: md), false, "Amazon 陈旧: 暂停恢复后元数据时间戳不动,也不算旧")
        expectEqual(P.logCovers(s, metadataTimestamp: md), true, "Amazon 覆盖: 同一次开播")
        expectEqual(P.logCovers(s, metadataTimestamp: at("030000")), false, "Amazon 覆盖: 日志没记到这首(开播对不上)")

        let timer = P.SelfTimer(trackKey: "k", base: 0, since: md)
        let r = P.reading(log: s, timer: timer, metadataTimestamp: md, now: at("025200"))
        expectEqual(r.source, .log, "Amazon 选层: 日志对得上用日志")
        expectEqual(near(r.position, 25.127115), true, "Amazon 选层: 日志层带校准")
        let stale = P.reading(log: s, timer: timer, metadataTimestamp: at("024343"), now: at("025200"))
        expectEqual(stale.staleMetadata, true, "Amazon 选层: 旧曲目标出来")
        let noLog = P.reading(log: nil, timer: timer, metadataTimestamp: md, now: at("025200"))
        expectEqual(noLog.source, .selfTimer, "Amazon 选层: 没有日志退回自记时")
        expectEqual(near(noLog.position, 25.127115), true, "Amazon 选层: 自记时从系统时间戳起算")
    }

    // ---- 拖动后等不到 kStarting ----
    do {
        var s = P.apply(.trackStarted("asin://B0TESTAAA1"), at: at("030000"), to: P.State())
        s = P.apply(.seek(60), at: at("030010"), to: s)
        expectEqual(near(P.position(s, at: at("030011")), 60), true, "Amazon 拖动: 等 kStarting 期间停着")
        expectEqual(near(P.position(s, at: at("030015")), 63), true, "Amazon 拖动: 等不到就按拖动 + 2 秒起表")
        let paused = P.apply(.seek(60), at: at("030010"), to: P.apply(.paused, at: at("030005"), to: s))
        expectEqual(near(P.position(paused, at: at("030030")), 60), true, "Amazon 拖动: 暂停着拖动不起表")
        let started = P.apply(.starting, at: at("030011", 0.4), to: s)
        expectEqual(near(P.position(started, at: at("030012", 0.4)), 61), true, "Amazon 拖动: kStarting 那一刻起表")
    }

    // ---- 自动连播的提前量 ----
    do {
        var s = P.apply(.endOfStream, at: at("025618", 0.5), to: P.State())
        s = P.apply(.trackStarted("asin://B0TESTAAA3"), at: at("025618", 0.5), to: s)
        expectEqual(s.startedNaturally, true, "Amazon 连播: End of stream 紧跟着开播 = 自然连播")
        expectEqual(P.needsLeadCalibration(s), true, "Amazon 连播: 自然连播的要校准")
        let clicked = P.apply(.trackStarted("asin://B0TESTAAA1"), at: at("025131", 0.5), to: P.State())
        expectEqual(P.needsLeadCalibration(clicked), false, "Amazon 连播: 点播开头不用校准")
        // 界面在 `edge` 那一刻跳到 `secs` 秒 = 真实起点就是 edge − secs(退化成一个点的区间)。
        func calibrating(_ s: P.State, edge: Date, secs: Int) -> P.State? {
            let o = edge.timeIntervalSince1970 - Double(secs)
            return P.calibratingLead(s, origin: o...o, at: edge)
        }
        // 界面在 02:56:30.3 跳到 9 秒,日志时钟那一刻是 11.8 → 提前 2.8 秒。
        let cal = calibrating(s, edge: at("025630", 0.3), secs: 9)
        expectEqual(cal.map { abs($0.audibleLead - 2.8) < 0.001 }, true, "Amazon 连播: 提前量 = 日志时钟 − 界面秒数")
        expectEqual(cal.flatMap { P.position($0, at: at("025630", 0.3)) }.map { abs($0 - 9) < 0.001 }, true,
                    "Amazon 连播: 校准后位置对上界面")
        expectEqual(cal.map { P.needsLeadCalibration($0) }, false, "Amazon 连播: 校准过不再校准")
        expectEqual(calibrating(s, edge: at("025630", 0.3), secs: 0) == nil, true,
                    "Amazon 连播: 提前量离谱(读错 / 读到别的曲目)不采信")
        let seeked = P.apply(.seek(30), at: at("025700"), to: cal!)
        expectEqual(seeked.audibleLead, 0, "Amazon 连播: 拖动清空缓冲,提前量归零")
        expectEqual(P.needsLeadCalibration(seeked), false, "Amazon 连播: 拖动之后不用再校准")
        let paused = P.apply(.paused, at: at("025740"), to: cal!)
        expectEqual(paused.audibleLead, cal!.audibleLead, "Amazon 连播: 暂停不影响提前量")
        // 02:57:40 暂停时日志时钟 81.5,扣一次提前量 = 78.7;停住的位置不能再扣一遍。
        expectEqual(near(P.position(paused, at: at("025750")), 78.7), true, "Amazon 连播: 暂停着的位置只扣一次提前量")
        let resumed = P.apply(.resumed, at: at("025800"), to: paused)
        expectEqual(resumed.audibleLead, cal!.audibleLead, "Amazon 连播: 暂停不清缓冲,恢复后提前量照扣")
        expectEqual(near(P.position(resumed, at: at("025810")), 88.7), true, "Amazon 连播: 恢复那一刻接着暂停的位置走")
        var stalledCal = P.apply(.stall(true), at: at("025700"), to: cal!)
        stalledCal = P.apply(.stall(false), at: at("025702"), to: stalledCal)
        expectEqual(near(P.position(stalledCal, at: at("025712")), 48.7), true,
                    "Amazon 连播: 卡顿停住的位置同样只扣一次提前量")
        // 卡顿之后要重新对一次界面,点播开头的也一样;卡顿后模型可能反过来慢,提前量可以是负的。
        var clickedStall = P.apply(.stall(true), at: at("025200"), to: clicked)
        clickedStall = P.apply(.stall(false), at: at("025200"), to: clickedStall)
        expectEqual(P.needsLeadCalibration(clickedStall), true, "Amazon 卡顿: 卡过就要重新校准")
        let behind = calibrating(clickedStall, edge: at("025210"), secs: 40)
        expectEqual(behind.map { abs($0.audibleLead - (-1.5)) < 0.001 }, true, "Amazon 卡顿: 模型慢了 1.5 秒,提前量 −1.5")
        expectEqual(behind.map { P.needsLeadCalibration($0) }, false, "Amazon 卡顿: 校准过就不再校准")
        // 缓冲见底卡了 47 秒:卡着的时候不读界面(界面时间停着,读了必失败),结束后再等 settle。
        let longStall = P.apply(.stall(true), at: at("072333"), to: clicked)
        expectEqual(P.mayStartCalibration(longStall, now: at("072351"), settle: 0.5), false,
                    "Amazon 卡顿: 卡顿开始过了 settle 但还没结束,不读界面")
        let recovered = P.apply(.stall(false), at: at("072420"), to: longStall)
        expectEqual(P.mayStartCalibration(recovered, now: at("072420", 0.2), settle: 0.5), false,
                    "Amazon 卡顿: 刚结束、没过 settle 不读")
        expectEqual(P.mayStartCalibration(recovered, now: at("072421"), settle: 0.5), true,
                    "Amazon 卡顿: 结束过了 settle 就读")
        expectEqual(P.mayStartCalibration(clicked, now: at("025140"), settle: 0.5), true, "Amazon 卡顿: 没卡过随时能读")

        // 一次校准只收到 0.45 秒宽的区间,隔 leadRefineDelay 再对一次、两次区间取交集。
        // 自然连播 02:56:18.5 开播,02:56:30.3 那一刻日志时钟 11.8;真实起点区间 [..., ...] 换成提前量区间 [2.5, 2.9]。
        let t1 = at("025630", 0.3)
        let o1 = t1.timeIntervalSince1970 - 11.8
        let first = P.calibratingLead(s, origin: (o1 + 2.5)...(o1 + 2.9), at: t1)
        expectEqual(first.map { abs($0.audibleLead - 2.7) < 0.001 }, true, "Amazon 叠窄: 首次取区间中点")
        expectEqual(first.map { P.needsLeadRefinement($0, now: t1.addingTimeInterval(P.leadRefineDelay - 1)) }, false,
                    "Amazon 叠窄: 没到 leadRefineDelay 不叠")
        let t2 = t1.addingTimeInterval(P.leadRefineDelay)
        expectEqual(first.map { P.needsLeadRefinement($0, now: t2) }, true, "Amazon 叠窄: 到点且区间比 leadRefineWidth 宽就再对一次")
        // 第二次量到提前量区间 [2.75, 3.15],与 [2.5, 2.9] 交出 [2.75, 2.9] → 2.825。起点区间按 t2 那一刻的日志时钟换算。
        let o2 = t2.timeIntervalSince1970 - (11.8 + P.leadRefineDelay)
        let second = first.flatMap { P.calibratingLead($0, origin: (o2 + 2.75)...(o2 + 3.15), at: t2) }
        expectEqual(second.map { abs($0.audibleLead - 2.825) < 0.001 }, true, "Amazon 叠窄: 两次区间取交集再取中点")
        expectEqual(second.flatMap { $0.leadRange }.map { abs($0.upperBound - $0.lowerBound - 0.15) < 0.001 }, true,
                    "Amazon 叠窄: 叠完区间变窄")
        expectEqual(second.map { P.needsLeadRefinement($0, now: t2.addingTimeInterval(60)) }, false,
                    "Amazon 叠窄: 每段只叠 maxLeadRefinements 次")
        let disjoint = first.flatMap { P.calibratingLead($0, origin: (o2 + 3.5)...(o2 + 3.9), at: t2) }
        expectEqual(disjoint.map { abs($0.audibleLead - 3.7) < 0.001 }, true, "Amazon 叠窄: 两次不相交只信新的")
        let pausedFirst = first.map { P.apply(.resumed, at: t1.addingTimeInterval(5), to: P.apply(.paused, at: t1.addingTimeInterval(2), to: $0)) }
        expectEqual(pausedFirst.map { P.needsLeadRefinement($0, now: t2.addingTimeInterval(10)) }, false,
                    "Amazon 叠窄: 暂停过的不再叠(日志时钟零点可能挪了)")
        var stalledFirst = first.map { P.apply(.stall(true), at: t1.addingTimeInterval(3), to: $0) }!
        stalledFirst = P.apply(.stall(false), at: t1.addingTimeInterval(4), to: stalledFirst)
        expectEqual(P.needsLeadRefinement(stalledFirst, now: t2), false, "Amazon 叠窄: 卡顿过的走重新校准,不叠")
        let recal = P.calibratingLead(stalledFirst, origin: (o2 + 3.5)...(o2 + 3.9), at: t2)
        expectEqual(recal.map { $0.leadRefinements == 0 && $0.leadRange.map { abs($0.upperBound - $0.lowerBound - 0.4) < 0.001 } == true },
                    true, "Amazon 叠窄: 卡顿后的重新校准从头量,不跟卡顿前的区间叠")

        typealias U = AmazonMusicUIProbe
        expectEqual(U.parseClock("02:24").map { $0.seconds }, 144, "Amazon 界面: 已播 mm:ss")
        expectEqual(U.parseClock("-01:05").map { [$0.seconds, $0.negative ? 1 : 0] }, [65, 1], "Amazon 界面: 剩余带负号")
        expectEqual(U.parseClock("1:02:03").map { $0.seconds }, 3723, "Amazon 界面: 带小时")
        expectEqual(U.parseClock("2:75") == nil && U.parseClock("abc") == nil && U.parseClock("") == nil, true,
                    "Amazon 界面: 认不出的不认")
        // 真实起点在 t=1000.0(位置 = t − 1000)。每次读数在 [切换, 建好] 之间某一刻取得,读到整秒。
        func sample(_ toggled: Double, _ ready: Double) -> U.Sample {
            U.Sample(toggledAt: Date(timeIntervalSince1970: toggled), readAt: Date(timeIntervalSince1970: ready),
                     seconds: Int((ready - 0.1) - 1000))
        }
        let samples = [sample(1010.40, 1010.63), sample(1010.85, 1011.05), sample(1010.95, 1011.18), sample(1011.20, 1011.43)]
        let range = U.originInterval(samples)
        expectEqual(range.map { $0.contains(1000.0) }, true, "Amazon 界面: 交集包含真实起点")
        expectEqual(range.map { $0.upperBound - $0.lowerBound < 0.5 }, true, "Amazon 界面: 跨过一次跳变后交集收窄")
        expectEqual(U.settledOrigin(samples).map { abs($0 - 1000) < 0.25 }, true, "Amazon 界面: 跨过一次跳变、收窄了就给起点")
        let frozen = [1020.0, 1020.4, 1020.8, 1021.2].map {
            U.Sample(toggledAt: Date(timeIntervalSince1970: $0), readAt: Date(timeIntervalSince1970: $0 + 0.2), seconds: 20)
        }
        expectEqual(U.originInterval(frozen).map { $0.upperBound - $0.lowerBound <= U.targetWidth }, true,
                    "Amazon 界面: 停住的读数也能把区间收窄")
        expectEqual(U.settledOrigin(frozen) == nil, true, "Amazon 界面: 读数没跳过一次整秒不算数(界面时间可能停着)")
        let stalledSamples = samples + [U.Sample(toggledAt: Date(timeIntervalSince1970: 1015), readAt: Date(timeIntervalSince1970: 1015.2), seconds: 11)]
        expectEqual(U.originInterval(stalledSamples) == nil, true, "Amazon 界面: 中途停住了(读数不跟时间走)交集为空,放弃")
        expectEqual(U.matchesTrack(elapsed: 144, remaining: 65, duration: 211), true, "Amazon 界面: 已播 + 剩余对得上时长")
        expectEqual(U.matchesTrack(elapsed: 49, remaining: 2602, duration: 211), false, "Amazon 界面: 对不上 = 读到的不是这首")
        // 页面别处还有一个时间(比如卡片上的时长),进度条那一对在后面、两段文字隔两个节点。
        let pairs = U.pairClocks([(300, 226, false), (1298, 61, false), (1300, 112, true)])
        expectEqual(pairs, [U.ClockPair(elapsed: 226, remaining: nil), U.ClockPair(elapsed: 61, remaining: 112)],
                    "Amazon 界面: 剩余只配挨着它的那个已播")
        expectEqual(U.pickPair(pairs, duration: 173).map { $0.elapsed }, 61, "Amazon 界面: 挑对得上时长的那一对")
        expectEqual(U.pickPair([U.ClockPair(elapsed: 5, remaining: 300)], duration: 173) == nil, true,
                    "Amazon 界面: 没有一对对得上 = 读到的不是这首")
        expectEqual(U.pickIndex(pairs, duration: 173), 1, "Amazon 界面: 挑中的是第几对(按它记路径)")
        // 下一次开关:两种读数结果的切点(开关 − 0.1、开关 + 0.23)对称夹住区间中点 + 整秒,取不早于 notBefore 的最近一刻。
        let nt = U.nextToggleTime(origin: 1000.2...1001.0, notBefore: 1010.0)
        expectEqual(abs(nt - 1010.535) < 0.001, true, "Amazon 界面: 下一次开关对准中点 + 整秒(\(nt))")
        // 模拟:真实起点落在一秒里的不同位置,开关后 0~0.23 秒里某一刻读到整秒(界面晚 0~0.1 秒),按新策略取样。
        for (k, frac) in [0.03, 0.27, 0.5, 0.71, 0.96].enumerated() {
            let truth = 2000 + frac
            var got: [U.Sample] = []
            var tg = 2020.0 + Double(k) * 0.37
            var settled: Double?
            for n in 0..<U.maxSampleToggles {
                let capture = tg + 0.23 * Double((n * 7 + k * 3) % 5) / 4
                let lag = 0.1 * Double((n + k) % 3) / 2
                got.append(U.Sample(toggledAt: Date(timeIntervalSince1970: tg), readAt: Date(timeIntervalSince1970: tg + 0.23),
                                    seconds: Int((capture - truth - lag).rounded(.down))))
                if let o = U.settledOrigin(got) { settled = o; break }
                guard let r = U.originInterval(got) else { break }
                tg = U.nextToggleTime(origin: r, notBefore: tg + 0.28)
            }
            expectEqual(settled.map { abs($0 - truth) < 0.25 }, true,
                        "Amazon 界面: 二分取样 \(U.maxSampleToggles) 次内收住、起点准(真值 +\(frac),读了 \(got.count) 次)")
        }
        expectEqual(U.plausibleElapsed(230, timelinePosition: 1.2), false,
                    "Amazon 界面: 切歌后一秒读到 230 秒 = 还是上一首的时间")
        expectEqual(U.plausibleElapsed(185, timelinePosition: 181.5), true,
                    "Amazon 界面: 卡顿后模型可能慢,界面超前几秒还认(拖动过也按日志位置比)")
        expectEqual(U.plausibleElapsed(8, timelinePosition: 2.9), false, "Amazon 界面: 超出余量的不认")
        expectEqual(U.plausibleElapsed(900, timelinePosition: nil), true, "Amazon 界面: 不知道日志位置就不拦")
    }

    // ---- 曲目页 ----
    do {
        let ok = PlatformLinks.amazonTrackURL("https://music.amazon.com/tracks/B0H9LD5H83")
        expectEqual(ok?.absoluteString, "https://music.amazon.com/tracks/B0H9LD5H83", "Amazon 曲目页: ASIN 形状对就原样用")
        for bad in ["https://music.amazon.com/tracks/b0h9ld5h83", "https://music.amazon.com/tracks/B0H9LD5H8",
                    "https://evil.example/tracks/B0H9LD5H83", "https://music.amazon.com/albums/B0H9LD5H83", ""] {
            expectEqual(PlatformLinks.amazonTrackURL(bad) == nil, true, "Amazon 曲目页: \(bad) 不认")
        }
        let links = PlatformLinks(appleMusic: nil, qqSong: nil, qqAlbum: nil, qqArtist: nil, neteaseSong: nil, amazonSong: ok)
        expectEqual(links.isEmpty, false, "Amazon 曲目页: 只有它也不算空")
        expectEqual(links.songLink(forPlayerBundleID: PlaybackPlayer.amazonMusic.bundleIdentifier)?.platform, .amazonMusic,
                    "Amazon 曲目页: 用 Amazon Music 放时给它自己的")
        expectEqual(links.songLink(forPlayerBundleID: PlaybackPlayer.spotify.bundleIdentifier) == nil, true,
                    "Amazon 曲目页: 别的播放器不拿它顶上")
    }

    // ---- 自记时 ----
    do {
        let t0 = at("025134")
        var timer = P.advance(nil, trackKey: "a", metadataTimestamp: t0, playing: true, observedAt: at("025136"))
        expectEqual(near(timer.position(at: at("025200")), 26), true, "Amazon 自记时: 从系统时间戳起算")
        timer = P.advance(timer, trackKey: "a", metadataTimestamp: t0, playing: false, observedAt: at("025218"))
        expectEqual(near(timer.position(at: at("025230")), 44), true, "Amazon 自记时: 暂停冻结")
        timer = P.advance(timer, trackKey: "a", metadataTimestamp: t0, playing: true, observedAt: at("025222"))
        expectEqual(near(timer.position(at: at("025300")), 82), true, "Amazon 自记时: 恢复后扣掉暂停的 4 秒")
        timer = P.advance(timer, trackKey: "b", metadataTimestamp: at("025338"), playing: true, observedAt: at("025339"))
        expectEqual(near(timer.position(at: at("025400")), 22), true, "Amazon 自记时: 换歌从头起")
        let pausedStart = P.advance(nil, trackKey: "c", metadataTimestamp: at("025000"), playing: false, observedAt: at("025010"))
        expectEqual(near(pausedStart.position(at: at("025100")), 10), true,
                    "Amazon 自记时: 第一次见到就是暂停着的,按时间戳到现在估一个停着的位置")
    }

    // ---- 校准重试:前三次隔 5 秒,之后隔 30 秒,不放弃 ----
    do {
        typealias W = AmazonMusicLogWatcher
        let t0 = at("030000")
        expectEqual(W.mayRetryCalibration(count: 1, lastAt: t0, now: t0.addingTimeInterval(5)), true, "Amazon 校准: 头几次隔 5 秒再试")
        expectEqual(W.mayRetryCalibration(count: 1, lastAt: t0, now: t0.addingTimeInterval(4)), false, "Amazon 校准: 不到 5 秒不试")
        expectEqual(W.mayRetryCalibration(count: 3, lastAt: t0, now: t0.addingTimeInterval(10)), false, "Amazon 校准: 试满三次后不再 5 秒一试")
        expectEqual(W.mayRetryCalibration(count: 7, lastAt: t0, now: t0.addingTimeInterval(30)), true, "Amazon 校准: 之后每 30 秒还试,不放弃")
    }

    // ---- 写给 collector 的记录:字段名同 Go 侧 amazonLeadRecord 的 json tag ----
    do {
        let rec = AmazonMusicLeadRecord(trackID: "", startedAtMs: 0, leadSecs: 0, writtenAtMs: 5,
                                        artist: "Benson Boone", title: "Beautiful Things", positionSecs: 42)
        let obj = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(rec))) as? [String: Any]
        expectEqual(Set(obj?.keys.map { $0 } ?? []), Set(["track_id", "started_at_ms", "lead_secs", "written_at_ms", "artist", "title", "position_secs"]),
                    "Amazon 记录: 自记时对表那种带上歌手 / 歌名 / 位置,字段名同 Go 侧")
        let lead = AmazonMusicLeadRecord(trackID: "asin://B0TESTAAA1", startedAtMs: 1, leadSecs: 1.5, writtenAtMs: 2)
        let leadObj = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(lead))) as? [String: Any]
        expectEqual(leadObj?["position_secs"] == nil && leadObj?["artist"] == nil, true, "Amazon 记录: 提前量那种不带这几项")
    }

    // ---- 重放起点:开播后暂停得久,开播行被推到末尾那段之前 ----
    do {
        let start = "260928:122914      Browser INFO in Harley : DT:M [Filter.cpp:157] End of stream reached\n" +
            "260928:122914      Browser INFO in Harley : DT:M [TrackPreFetcher.cpp:74] new track playing : asin://B0TESTAAA1:286:87015\n"
        let filler = String(repeating: "260928:123000      Browser INFO in Harley : DT:M idle while paused\n", count: 400)
        let data = Data((String(repeating: "260928:120000 earlier line\n", count: 200) + start + filler).utf8)
        let from = P.replayStart(data, tailBytes: 1000)
        let rest = String(decoding: data[from...], as: UTF8.self)
        expectEqual(rest.contains("new track playing") && rest.contains("End of stream"), true,
                    "Amazon 重放: 开播行在末尾那段之前,往前读到它(连同 End of stream)")
        expectEqual(from == 0 || data[from - 1] == UInt8(ascii: "\n"), true, "Amazon 重放: 从一行的开头读起")
        let recent = data + Data((start + "260928:130000 after\n").utf8)
        expectEqual(P.replayStart(recent, tailBytes: 1000), recent.count - 1000, "Amazon 重放: 末尾那段里就有开播,照旧只读末尾")
        let none = Data(filler.utf8)
        expectEqual(P.replayStart(none, tailBytes: 1000), none.count - 1000, "Amazon 重放: 整份都没有开播,照旧只读末尾")
    }

    // ---- 拖进度:Amazon 不吃外部跳转指令 ----
    do {
        expectEqual(LocalPlaybackSource.acceptsSeek(bundleID: PlaybackPlayer.amazonMusic.bundleIdentifier), false,
                    "Amazon 拖进度: 不吃 seek,进度条只显示不能拖")
        expectEqual(LocalPlaybackSource.acceptsSeek(bundleID: PlaybackPlayer.spotify.bundleIdentifier), true, "Amazon 拖进度: 别家照常能拖")
        expectEqual(LocalPlaybackSource.acceptsSeek(bundleID: nil), true, "Amazon 拖进度: 认不出来的不拦(发出去没反应也无害)")
    }

    // ---- 暂停不跳:起点换成系统时间戳这一步要记进 watcher 的状态 ----
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrimuse-amazon-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("AmazonMusic.log")
        let start = "260928:025134      Browser INFO in Harley : DT:M [TrackPreFetcher.cpp:74] new track playing : asin://B0TESTAAA1:13:87015\n"
        try? start.write(to: log, atomically: false, encoding: .utf8)
        let watcher = AmazonMusicLogWatcher(path: log.path)
        watcher.ensureStarted()
        // 历史行按行首 + 0.5 = 02:51:34.5 起算;系统时间戳 02:51:34.9 更准,播放中按它算。
        let ts = at("025134", 0.9)
        let playing = watcher.reading(trackKey: "k", metadataTimestamp: ts, playing: true, pauseObservedAt: nil, now: at("025200"))
        expectEqual(near(playing.position, 25.1), true, "Amazon 暂停: 播放中按系统时间戳起算")
        // 实时读到的暂停行按「不晚于行首那一秒末」计,这里就是 02:52:11。
        let pause = "260928:025210      Browser INFO in Harley : 0x3151c8000 [PlaybackEngine.cpp:1127] setPaused(1)\n"
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            h.write(pause.data(using: .utf8)!)
            try? h.close()
        }
        let paused = watcher.reading(trackKey: "k", metadataTimestamp: ts, playing: false, pauseObservedAt: nil, now: at("025220"))
        expectEqual(near(paused.position, 36.1), true,
                    "Amazon 暂停: 停表位置跟播放中同一个起点(按日志起点算会多出 0.4 秒,暂停那一下就跳)")
    }
}
