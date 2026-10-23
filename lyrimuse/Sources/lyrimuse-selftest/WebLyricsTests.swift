import AppKit
import Foundation
import JavaScriptCore
import LyrimuseCore

/// 网页歌词(19 章):HTTP 解析 / WebSocket 握手与分帧 / 谁能打开 / 副屏尺寸 / OBS 消息 / 离屏拼图层树,外加几条接线契约。
@MainActor
func runWebLyricsTests() {
    // ---- 出帧档位(WebLyricsFramePacer) ----
    do {
        // 按出帧线程的规则模拟:每拍先收掉已编完的帧;网络令牌不够这一档一帧的字节就是「网络发不完」,在途已满(2 帧)
        // 是「机器忙不过来」,否则开画一帧、pipeline 秒后编完。bandwidth 为 nil 时网络不限。返回模拟结束的时刻。
        // 一帧的字节按原尺寸、原质量 300KB 算,降质量乘 0.7,缩尺寸按面积。
        func frameBytes(_ s: WebLyricsFrameStep) -> Double {
            300_000 * (s.quality < WebLyricsFramePacer.fullQuality ? 0.7 : 1) * s.resolution * s.resolution
        }
        func run(_ p: inout WebLyricsFramePacer, from start: Double, seconds: Double, draw: Double, pipeline: Double,
                 bandwidth: Double? = nil, extraBacklog: (Int) -> Bool = { _ in false }) -> Double {
            var t = start, i = 0, credit = 0.0
            var inFlight: [Double] = []
            while t < start + seconds {
                inFlight.removeAll { $0 <= t }
                let bytes = frameBytes(p.step)
                if let bandwidth { credit = min(credit + bandwidth * p.interval, bytes * 2) }
                let skip: WebLyricsFrameSkip
                if extraBacklog(i) || (bandwidth != nil && credit < bytes) {
                    skip = .backlog
                } else if inFlight.count >= 2 {
                    skip = .inFlight
                } else {
                    skip = .none
                    if bandwidth != nil { credit -= bytes }
                    inFlight.append(t + pipeline)
                    p.noteDraw(draw)
                    p.noteEncoded(pipeline: pipeline)
                }
                _ = p.tick(at: t, skipped: skip)
                t += p.interval
                i += 1
            }
            return t
        }
        let sixty = 1.0 / 60

        var twoX = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 0.5)
        expectEqual(twoX.steps.count, 7, "网页歌词档位: 2 倍像素的网页有降质量、缩到 0.75 / 0.5、再降帧率共 7 档")
        expectEqual(twoX.step, WebLyricsFrameStep(interval: sixty, quality: WebLyricsFramePacer.fullQuality, resolution: 1),
                    "网页歌词档位: 起步是 60 帧、原质量、原尺寸")
        _ = run(&twoX, from: 0, seconds: 6, draw: 0.003, pipeline: 0.028)
        expectEqual(twoX.level, 0, "网页歌词档位: 编完一帧要 28ms,两帧在途照样 60 帧不跳拍,不降")

        let oneX = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 1)
        expectEqual(oneX.steps.map(\.resolution).allSatisfy { $0 == 1 } && oneX.steps.count == 5, true,
                    "网页歌词档位: 1 倍像素的网页不再缩尺寸,那几档合并掉")

        // 网络只有 4MB/s:原尺寸一帧 300KB 只够 13 帧,先省字节,缩到一半尺寸后 60 帧发得完,不降帧率。
        var wifi = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 0.5)
        var t = run(&wifi, from: 0, seconds: 2.02, draw: 0.003, pipeline: 0.02, bandwidth: 4_000_000)
        expectEqual(wifi.step.quality, WebLyricsFramePacer.reducedQuality, "网页歌词档位: 网络发不完,先降 JPEG 质量")
        expectEqual(wifi.interval, sixty, "网页歌词档位: 网络发不完时先不降帧率")
        t = run(&wifi, from: t, seconds: 4, draw: 0.003, pipeline: 0.02, bandwidth: 4_000_000)
        expectEqual(wifi.step.resolution, 0.5, "网页歌词档位: 质量降了还发不完,接着缩尺寸,缩到一半")
        expectEqual(wifi.interval, sixty, "网页歌词档位: 缩到一半尺寸 60 帧就发得完,帧率不动")
        t = run(&wifi, from: t, seconds: 30, draw: 0.003, pipeline: 0.02, bandwidth: 4_000_000)
        expectEqual(wifi.interval, sixty, "网页歌词档位: 试着升回去又发不完时退回,一直保住 60 帧")
        _ = run(&wifi, from: t, seconds: 60, draw: 0.003, pipeline: 0.02, bandwidth: 40_000_000)
        expectEqual(wifi.level, 0, "网页歌词档位: 网络恢复后一档档升回原质量、原尺寸")

        // 机器忙不过来:编完一帧 80ms。只降质量的那档跳过,直接缩尺寸;模拟里缩尺寸不省时间,最后降到 20 帧稳住。
        var slow = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 0.5)
        var s = run(&slow, from: 0, seconds: 2.02, draw: 0.003, pipeline: 0.08)
        expectEqual(slow.step.resolution, 0.75, "网页歌词档位: 在途帧满跳拍,不走只降质量的那档,直接缩尺寸")
        s = run(&slow, from: s, seconds: 8, draw: 0.003, pipeline: 0.08)
        expectEqual(slow.interval, 1.0 / 20, "网页歌词档位: 尺寸缩到底还在跳拍就降帧率,20 帧撑得住就稳住")
        _ = run(&slow, from: s, seconds: 6, draw: 0.003, pipeline: 0.08)
        expectEqual(slow.interval, 1.0 / 20, "网页歌词档位: 快一档赶不上时不升")

        var cpuBound = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 0.5)
        _ = run(&cpuBound, from: 0, seconds: 2.05, draw: 0.02, pipeline: 0.025)
        expectEqual(cpuBound.interval, 1.0 / 30,
                    "网页歌词档位: 画一帧交给 GPU 就超过一拍,不在 60 帧上逐档缩尺寸(省不了 CPU),一次降到 30 帧")

        var fewSkips = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 0.5)
        _ = run(&fewSkips, from: 0, seconds: 3, draw: 0.003, pipeline: 0.02, extraBacklog: { $0 % 30 == 0 })
        expectEqual(fewSkips.level, 0, "网页歌词档位: 偶尔跳一拍不降")

        var floor = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 0.5)
        _ = run(&floor, from: 0, seconds: 12, draw: 0.003, pipeline: 0.5)
        expectEqual(floor.level, floor.steps.count - 1, "网页歌词档位: 最慢停在 15 帧")

        var warm = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 0.5)
        var w = run(&warm, from: 0, seconds: 1.01, draw: 0.003, pipeline: 0.08)
        expectEqual(warm.level, 0, "网页歌词档位: 开播头一秒跳拍再多也不降(编码器头几帧慢、网页刚连上)")
        w = run(&warm, from: w, seconds: 1.01, draw: 0.003, pipeline: 0.08)
        expectEqual(warm.level > 0, true, "网页歌词档位: 第二秒还在跳拍才降")
        warm.resetWindow()
        let before = warm.level
        _ = run(&warm, from: w + 5, seconds: 1.01, draw: 0.003, pipeline: 0.5)
        expectEqual(warm.level, before, "网页歌词档位: 暂停后恢复的头一秒同样只记账不降")

        var paused = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 0.5)
        _ = paused.tick(at: 0, skipped: .backlog)
        _ = paused.tick(at: 0.5, skipped: .backlog)
        paused.resetWindow()
        _ = paused.tick(at: 10, skipped: .none)
        expectEqual(paused.tick(at: 11.1, skipped: .none), false, "网页歌词档位: 暂停前那一秒的跳拍不算进恢复后的账")
        expectEqual(paused.level, 0, "网页歌词档位: 清账后档位不动")

        var video = WebLyricsFramePacer(maxFramesInFlight: 2, minResolution: 1, countsBacklog: false)
        _ = run(&video, from: 0, seconds: 5, draw: 0.003, pipeline: 0.02, bandwidth: 100_000)
        expectEqual(video.level, 0, "网页歌词档位: 视频流网络发不完不降帧率(码率另由网页回报控制,降帧率省不了码率)")
    }

    // ---- 视频码率(WebLyricsRateControl) ----
    do {
        // 链路按先进先出模拟:每秒送 capacity(t) 字节,单程 10ms,stalls 里的时段一个字节都送不出。60 帧,一帧按设给编码器的
        // 码率乘 overshoot(编码器超发)摊,
        // 每 2 秒一个关键帧(普通帧的 5 倍),超过在途上限的帧不发。网页每 0.2 秒回报一次。返回末 5 秒里最长的排队时间、
        // 最低码率和平均码率。
        func simulate(_ rc: inout WebLyricsRateControl, from start: Double = 0, seconds: Double, overshoot: Double = 1,
                      capacity: (Double) -> Double, stalls: [(at: Double, length: Double)] = [])
            -> (queue: Double, low: Int, mean: Double) {
            var arrivals: [(stamp: Double, at: Double, total: Int)] = []
            var linkFree = start, total = 0, nextReport = start + 0.2
            var worstQueue = 0.0, low = Int.max, rateSum = 0.0, rateCount = 0
            var i = 0
            while Double(i) / 60 < seconds {
                let now = start + Double(i) / 60
                while nextReport + 0.01 <= now {
                    if let last = arrivals.last(where: { $0.at <= nextReport }) {
                        _ = rc.noteFeedback(WebLyricsFeedback(stamp: last.stamp * 1000, receivedBytes: last.total,
                                                              sinceArrival: nextReport - last.at), at: nextReport + 0.01)
                    }
                    nextReport += 0.2
                }
                if now > start + seconds - 5 {
                    low = min(low, rc.bitRate)
                    rateSum += Double(rc.bitRate)
                    rateCount += 1
                }
                let bytes = Int(Double(rc.encoderBitRate) * overshoot / 8 / 60 * (i % 120 == 0 ? 5 : 1))
                guard rc.admits(at: now) else {
                    i += 1
                    continue
                }
                rc.noteSent(stamp: now * 1000, bytes: bytes, at: now)
                var begin = max(now, linkFree)
                for stall in stalls where begin >= stall.at && begin < stall.at + stall.length { begin = stall.at + stall.length }
                var end = begin + Double(bytes) / capacity(begin)
                for stall in stalls where begin < stall.at && end > stall.at { end += stall.length }
                linkFree = end
                total += bytes
                arrivals.append((now, linkFree + 0.01, total))
                if now > start + seconds - 5 { worstQueue = max(worstQueue, linkFree - now) }
                i += 1
            }
            return (worstQueue, low, rateSum / Double(max(1, rateCount)))
        }

        var narrow = WebLyricsRateControl()
        let n = simulate(&narrow, seconds: 30, capacity: { _ in 150_000 })
        expectEqual(n.mean <= 1_250_000 && n.low >= 600_000, true,
                    "网页歌词码率: 路只有 1.2Mbps 时降到它以内,不压到底(末 5 秒平均 \(Int(n.mean)),最低 \(n.low))")
        expectEqual(n.queue < 0.5, true, "网页歌词码率: 降下来之后排队消掉,不越积越迟(末 5 秒最长 \(n.queue)s)")

        var greedy = WebLyricsRateControl()
        let g = simulate(&greedy, seconds: 30, overshoot: 1.5, capacity: { _ in 150_000 })
        expectEqual(g.queue < 0.5 && greedy.encoderBitRate < greedy.bitRate, true,
                    "网页歌词码率: 编码器多发五成时按比例少设,排队照样消掉(末 5 秒最长 \(g.queue)s)")

        var tiny = WebLyricsRateControl()
        let tq = simulate(&tiny, seconds: 40, capacity: { _ in 40_000 })
        expectEqual(tq.mean <= 340_000 && tq.queue < 0.8, true,
                    "网页歌词码率: 320kbps 的路也降得进去(末 5 秒平均 \(Int(tq.mean)),最长排队 \(tq.queue)s)")

        var start = WebLyricsRateControl()
        let sq = simulate(&start, seconds: 10, capacity: { _ in 150_000 })
        expectEqual(sq.queue < 1, true, "网页歌词码率: 刚连上灌进窄路的积压几秒内消掉(第 5～10 秒最长排队 \(sq.queue)s)")

        var quick = WebLyricsRateControl()
        _ = simulate(&quick, seconds: 1.5, capacity: { _ in 5_000_000 })
        expectEqual(quick.bitRate, WebLyricsRateControl.maxBitRate, "网页歌词码率: 好路上从起步码率一秒多升满")

        var wide = WebLyricsRateControl()
        _ = simulate(&wide, seconds: 20, capacity: { _ in 5_000_000 })
        expectEqual(wide.bitRate, WebLyricsRateControl.maxBitRate, "网页歌词码率: 路够宽一直用满上限")

        var stalled = WebLyricsRateControl()
        let stalls = stride(from: 3.0, to: 60, by: 3).map { (at: $0, length: 1.0) }
        let st = simulate(&stalled, seconds: 60, capacity: { _ in 5_000_000 }, stalls: stalls)
        expectEqual(st.low >= 2_000_000, true,
                    "网页歌词码率: 路够宽、只是每 3 秒停 1 秒,码率不跟着压下去(末 5 秒最低 \(st.low))")

        var recover = WebLyricsRateControl()
        _ = simulate(&recover, seconds: 60, capacity: { $0 < 10 || $0 >= 30 ? 5_000_000 : 150_000 })
        expectEqual(recover.bitRate, WebLyricsRateControl.maxBitRate, "网页歌词码率: 路变窄又变宽,码率跟着升回上限")

        expectEqual(WebLyricsFeedback.parse(Data(#"{"fb":[1234.5,6789,12]}"#.utf8)),
                    WebLyricsFeedback(stamp: 1234.5, receivedBytes: 6789, sinceArrival: 0.012), "网页歌词码率: 解析网页回报")
        expectEqual(WebLyricsFeedback.parse(Data(#"{"fb":[1,-1,0]}"#.utf8)), nil, "网页歌词码率: 字节数是负的不认")
        expectEqual(WebLyricsFeedback.parse(Data(#"{"fb":[1,2,3,450]}"#.utf8))?.delay, 0.45, "网页歌词码率: 回报带着放帧余量")

        var latency = WebLyricsRateControl()
        latency.noteSent(stamp: 990, bytes: 100, at: 1.0)
        _ = latency.noteFeedback(WebLyricsFeedback(stamp: 990, receivedBytes: 100, sinceArrival: 0, delay: 0.3), at: 1.04)
        expectEqual(abs((latency.displayLatency ?? 0) - (0.01 + 0.02 + 0.3 + 1.0 / 120)) < 0.0001, true,
                    "网页歌词提前画: 从画到上屏 = 交出前的耗时 + 往返的一半 + 网页的放帧余量 + 半个刷新间隔(\(latency.displayLatency ?? -1))")
        var noDelay = WebLyricsRateControl()
        noDelay.noteSent(stamp: 990, bytes: 100, at: 1.0)
        _ = noDelay.noteFeedback(WebLyricsFeedback(stamp: 990, receivedBytes: 100, sinceArrival: 0), at: 1.04)
        expectEqual(noDelay.displayLatency, nil, "网页歌词提前画: 网页没报余量就不提前")

        func cutWindow(lead: Int = 800, previous: (positionMs: Int, at: TimeInterval, playing: Bool)? = (10_000, 100.0, true),
                       position: Int, now: TimeInterval = 100.4, playing: Bool, rate: Double = 1) -> [Double]? {
            WebLyricsPredictionCut.window(leadMs: lead, previous: previous, positionMs: position, now: now, playing: playing,
                                          rate: rate).map { [$0.from, $0.to] }
        }
        // 上一次提交在 100.0s、位置 10.000s;此刻 100.4s 发现停了,实际停在 10.100s(照原样该到 10.400s,晚发现了 300ms)
        expectEqual(cutWindow(position: 10_100, playing: false), [100_400 - 800 - 300 - 200, 100_400],
                    "网页歌词提前画: 暂停时丢掉押过头的帧,起点按晚发现的那一截再往前挪,再多留 200ms")
        expectEqual(cutWindow(position: 40_000, playing: true), [100_000 - 800 - 200, 100_400],
                    "网页歌词提前画: 跳转也算押错,起点取上一次提交的时刻")
        expectEqual(cutWindow(position: 10_550, playing: true), nil, "网页歌词提前画: 锚点小幅校正不算跳转")
        expectEqual(cutWindow(position: 10_800, playing: true, rate: 2), nil, "网页歌词提前画: 按播放速率外推")
        expectEqual(cutWindow(lead: 250, position: 10_100, playing: false), nil,
                    "网页歌词提前画: 提前量不到 300ms 不丢(押过头看不出,丢帧反而要停一下)")
        expectEqual(cutWindow(position: 1_200, playing: true), nil,
                    "网页歌词提前画: 跳到开头 3 秒以内(开播时的位置校正、自动换下一首)不算跳转")
        expectEqual(cutWindow(previous: (10_000, 100.0, false), position: 40_000, playing: true), nil,
                    "网页歌词提前画: 原来就停着(恢复播放)不用丢")
        expectEqual(WebLyricsPredictionCut.message((1234.5, 2000)), #"{"type":"cut","from":1234.5,"t":2000.0}"#,
                    "网页歌词提前画: 丢帧通知的格式")

        expectEqual(WebLyricsStats.parseToggle(Data(#"{"stats":1}"#.utf8)), true, "网页歌词诊断: 网页打开诊断浮层")
        expectEqual(WebLyricsStats.parseToggle(Data(#"{"stats":0}"#.utf8)), false, "网页歌词诊断: 网页关掉诊断浮层")
        expectEqual(WebLyricsStats.parseToggle(Data(#"{"vis":1}"#.utf8)), nil, "网页歌词诊断: 可见性不当浮层开关")
        expectEqual(WebLyricsStats.message(renderFps: 60, bitRate: 3_900_000, encoderBitRate: 3_500_000, queueMs: 40, leadMs: 300,
                                           leadTargetMs: 320, dropped: 2),
                    #"{"drop":2,"enc":3500,"fps":60,"kbps":3900,"lead":300,"queue":40,"target":320,"type":"stats"}"#,
                    "网页歌词诊断: 视频流的统计带码率、编码器码率、排队")
        expectEqual(WebLyricsStats.message(renderFps: 30, bitRate: nil, encoderBitRate: nil, queueMs: nil, leadMs: 0,
                                           leadTargetMs: 0, dropped: 0),
                    #"{"drop":0,"fps":30,"lead":0,"target":0,"type":"stats"}"#, "网页歌词诊断: 逐帧 JPEG 不带码率那几项")
        expectEqual(WebLyricsFeedback.parse(Data(#"{"vis":1}"#.utf8)), nil, "网页歌词码率: 可见性不当回报")
    }

    // ---- 副屏视频流(WebLyricsVideo) ----
    do {
        let sps = Data([0x67, 0x64, 0x00, 0x33, 0xAC, 0xD9])
        let pps = Data([0x68, 0xEB, 0xE3])
        let avcC = WebLyricsVideo.decoderConfiguration(sps: sps, pps: pps)
        expectEqual(avcC.map([UInt8].init), [1, 0x64, 0x00, 0x33, 0xFF, 0xE1, 0, 6, 0x67, 0x64, 0x00, 0x33, 0xAC, 0xD9,
                                             1, 0, 3, 0x68, 0xEB, 0xE3, 0xFD, 0xF8, 0xF8, 0],
                    "网页歌词视频: avcC 按 SPS、PPS 拼,High 档次补色度格式和位深")
        let baseline = WebLyricsVideo.decoderConfiguration(sps: Data([0x67, 0x42, 0xC0, 0x1E, 0x01]), pps: pps)
        expectEqual(baseline?.count, 6 + 2 + 5 + 3 + 3, "网页歌词视频: Baseline 档次不补那几个字节")
        expectEqual(WebLyricsVideo.decoderConfiguration(sps: Data([0x67, 0x64]), pps: pps) == nil, true, "网页歌词视频: SPS 太短给 nil")
        expectEqual(WebLyricsVideo.codecString(decoderConfiguration: avcC ?? Data()), "avc1.640033", "网页歌词视频: codec 字符串取档次、约束、级别")
        let message = [UInt8](WebLyricsVideo.message(.keyFrame, stamp: 1.5, payload: Data([9, 8])))
        expectEqual(message.count == 11 && message[0] == 2 && message[9] == 9 && message[10] == 8, true,
                    "网页歌词视频: 消息是 1 字节类型 + 8 字节时刻 + 数据")
        var stampBits = (1.5).bitPattern.bigEndian
        expectEqual(Data(message[1..<9]), Data(bytes: &stampBits, count: 8), "网页歌词视频: 时刻是大端 Float64")
        expectEqual(WebLyricsVideo.wantsVideo(["codec": "avc"]) && !WebLyricsVideo.wantsVideo([:]), true, "网页歌词视频: codec=avc 才推视频流")

        let fresh = WebLyricsVideo.deliver(isKeyFrame: false, needsKeyFrame: true, previousStillSending: false)
        expectEqual(fresh, .init(send: false, needsKeyFrame: true, wantsKeyFrame: true), "网页歌词视频: 刚连上的网页不发普通帧,要关键帧")
        let start = WebLyricsVideo.deliver(isKeyFrame: true, needsKeyFrame: true, previousStillSending: false)
        expectEqual(start, .init(send: true, needsKeyFrame: false, wantsKeyFrame: false), "网页歌词视频: 关键帧到了就发、开始接着发")
        let flowing = WebLyricsVideo.deliver(isKeyFrame: false, needsKeyFrame: false, previousStillSending: false)
        expectEqual(flowing.send && !flowing.needsKeyFrame, true, "网页歌词视频: 在流里的网页普通帧照发")
        let dropped = WebLyricsVideo.deliver(isKeyFrame: false, needsKeyFrame: false, previousStillSending: true)
        expectEqual(dropped, .init(send: false, needsKeyFrame: true, wantsKeyFrame: true), "网页歌词视频: 上一帧没发完丢了这帧,等下一个关键帧")
        let droppedKey = WebLyricsVideo.deliver(isKeyFrame: true, needsKeyFrame: false, previousStillSending: true)
        expectEqual(droppedKey.needsKeyFrame, true, "网页歌词视频: 关键帧丢了也得等下一个(后面的帧参照它)")
    }

    // ---- HTTP 请求头 ----
    do {
        let raw = Data("GET /ws?k=abc&w=390&h=844&dpr=3&x=%E4%B8%AD HTTP/1.1\r\nHost: 192.168.1.5:3939\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\nrest".utf8)
        guard case let .request(request, consumed) = WebLyricsHTTP.parse(raw) else {
            expectEqual(false, true, "网页歌词: 完整请求头能解析")
            return
        }
        expectEqual(request.method, "GET", "网页歌词: 方法")
        expectEqual(request.path, "/ws", "网页歌词: 路径不含查询串")
        expectEqual(request.query["k"], "abc", "网页歌词: 查询串")
        expectEqual(request.query["x"], "中", "网页歌词: 查询串去掉百分号编码")
        expectEqual(request.headers["host"], "192.168.1.5:3939", "网页歌词: 头名转小写")
        expectEqual(request.isWebSocketUpgrade, true, "网页歌词: 认出 WebSocket 升级(Connection 里带别的值也认)")
        expectEqual(consumed, raw.count - 4, "网页歌词: 消耗到空行为止,后面的字节留着")
        expectEqual(WebLyricsHTTP.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)), .needMore, "网页歌词: 没收到空行时等更多")
        expectEqual(WebLyricsHTTP.parse(Data("NOT A REQUEST\r\n\r\n".utf8)), .invalid, "网页歌词: 请求行不对")
        expectEqual(WebLyricsHTTP.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)), .invalid, "网页歌词: 只认以 / 开头的路径")
        expectEqual(WebLyricsHTTP.parse(Data(repeating: 0x41, count: WebLyricsHTTP.maxHeaderBytes + 1)), .invalid,
                    "网页歌词: 请求头超长当坏请求")
        let plain = Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        if case let .request(r, _) = WebLyricsHTTP.parse(plain) {
            expectEqual(r.isWebSocketUpgrade, false, "网页歌词: 普通请求不是升级")
        }
    }

    // ---- WebSocket ----
    do {
        // RFC 6455 §1.3 的示例。
        expectEqual(WebLyricsHTTP.webSocketAccept(key: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
                    "网页歌词: Sec-WebSocket-Accept 跟 RFC 示例一致")
        let small = WebSocketFrame.encode(Data(repeating: 1, count: 5), opcode: .text)
        expectEqual(Array(small.prefix(2)), [0x81, 5], "网页歌词: 短帧两字节头、不加掩码")
        let medium = WebSocketFrame.encode(Data(repeating: 1, count: 300), opcode: .binary)
        expectEqual(Array(medium.prefix(4)), [0x82, 126, 0x01, 0x2C], "网页歌词: 126 档长度用两字节")
        let large = WebSocketFrame.encode(Data(repeating: 1, count: 70_000), opcode: .binary)
        expectEqual(Array(large.prefix(10)), [0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70], "网页歌词: 大帧长度用八字节")
        expectEqual(large.count, 70_010, "网页歌词: 大帧总长")

        func clientFrame(_ payload: [UInt8], opcode: UInt8, masked: Bool = true) -> Data {
            var frame: [UInt8] = [0x80 | opcode, (masked ? 0x80 : 0) | UInt8(payload.count)]
            let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
            if masked { frame += mask }
            frame += payload.enumerated().map { masked ? $0.element ^ mask[$0.offset % 4] : $0.element }
            return Data(frame)
        }
        let ping = clientFrame(Array("hi".utf8), opcode: 0x9)
        expectEqual(WebSocketFrame.decode(ping), .frame(.init(opcode: 0x9, payload: Data("hi".utf8), consumed: ping.count)),
                    "网页歌词: 解开客户端的掩码")
        expectEqual(WebSocketFrame.decode(ping.prefix(4)), .needMore, "网页歌词: 帧没收全时等更多")
        expectEqual(WebSocketFrame.decode(clientFrame([1, 2], opcode: 0x1, masked: false)), .invalid, "网页歌词: 客户端帧不带掩码算坏连接")
        let huge = Data([0x82, 0xFF, 0, 0, 0, 0, 0, 0x10, 0, 0])
        expectEqual(WebSocketFrame.decode(huge), .invalid, "网页歌词: 客户端大帧算坏连接")
    }

    // ---- 系统防火墙挡不挡局域网设备(socketfilterfw 的输出) ----
    do {
        let F = ApplicationFirewall.self
        expectEqual(F.globalState(from: "Firewall is blocking all non-essential incoming connections. (State = 2)"), 2,
                    "防火墙: 阻止所有传入连接是 2")
        expectEqual(F.globalState(from: "Firewall is enabled. (State = 1)"), 1, "防火墙: 开着是 1")
        expectEqual(F.globalState(from: "Firewall is disabled. (State = 0)"), 0, "防火墙: 关着是 0")
        expectEqual(F.globalState(from: "garbage"), nil, "防火墙: 认不出的输出为 nil")
        expectEqual(F.appBlocked(from: "Incoming connection to /Applications/Lyrimuse.app/Contents/MacOS/lyrimuse is blocked."), true,
                    "防火墙: 程序被挡")
        expectEqual(F.appBlocked(from: "Incoming connection to /Applications/Lyrimuse.app/Contents/MacOS/lyrimuse is permitted."), false,
                    "防火墙: 程序放行")
        expectEqual(F.appBlocked(from: "The application is not part of the firewall"), nil, "防火墙: 不在列表里为 nil")
        expectEqual(F.blocksIncoming(globalState: 2, appBlocked: false), true, "防火墙: 阻止所有传入时放行的程序也连不进来")
        expectEqual(F.blocksIncoming(globalState: 1, appBlocked: true), true, "防火墙: 开着且程序被挡")
        expectEqual(F.blocksIncoming(globalState: 1, appBlocked: false), false, "防火墙: 开着但程序放行")
        expectEqual(F.blocksIncoming(globalState: 1, appBlocked: nil), false, "防火墙: 认不出程序状态时不报")
        expectEqual(F.blocksIncoming(globalState: 0, appBlocked: true), false, "防火墙: 关着时不报")
        expectEqual(F.blocksIncoming(globalState: nil, appBlocked: true), false, "防火墙: 读不出总状态时不报")
    }

    // ---- 局域网链接那几行显示的地址 ----
    do {
        let link = WebLyricsLinks.url(host: "DJ-Mac.local", port: 3940, token: "abc")
        expectEqual(link.flatMap(WebLyricsLANAddress.text(of:)), "DJ-Mac.local:3940", "网页歌词: 只写名字和端口,不带密钥")
        let ip = WebLyricsLinks.url(host: "192.168.1.8", port: 3939, token: "abc")
        expectEqual(ip.flatMap(WebLyricsLANAddress.text(of:)), "192.168.1.8:3939", "网页歌词: IP 链接同样只写地址和端口")
        expectEqual(WebLyricsLANAddress.text(of: URL(string: "mailto:x")!), nil, "网页歌词: 没有主机名的链接不出地址")
    }

    // ---- 谁能打开 ----
    do {
        let token = WebLyricsAccess.makeToken()
        expectEqual(token.count, 32, "网页歌词: 密钥 128 位十六进制")
        expectNotEqual(token, WebLyricsAccess.makeToken(), "网页歌词: 每次生成的密钥不同")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: true, lanEnabled: false, token: token, query: [:]), true,
                    "网页歌词: 本机回环不要密钥")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: false, token: token, query: ["k": token]), false,
                    "网页歌词: 局域网没开时别的设备带对的密钥也不行")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: true, token: token, query: ["k": "nope"]), false,
                    "网页歌词: 密钥不对")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: true, token: token, query: [:]), false,
                    "网页歌词: 没带密钥")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: true, token: token, query: ["k": token]), true,
                    "网页歌词: 局域网开着、密钥对")
        expectEqual(WebLyricsAccess.permits(remoteIsLoopback: false, lanEnabled: true, token: "", query: ["k": ""]), false,
                    "网页歌词: 空密钥一律不认")

        let names: Set<String> = ["DJ-Mac.local"]
        let allowed = ["localhost", "localhost:3939", "127.0.0.1:3939", "[::1]:3939", "192.168.31.24", "dj-mac.local:3939", "DJ-MAC.LOCAL"]
        for host in allowed {
            expectEqual(WebLyricsAccess.hostAllowed(host, localNames: names), true, "网页歌词: Host \(host) 放行")
        }
        let denied: [String?] = [nil, "", "evil.example", "evil.example:3939", "localhost:abc", "256.1.1.1", "1.2.3", "[::1", "other.local"]
        for host in denied {
            expectEqual(WebLyricsAccess.hostAllowed(host, localNames: names), false, "网页歌词: Host \(host ?? "nil") 挡住")
        }

        // Origin:没带的放行(地址栏、OBS 浏览器源、命令行),带了就要跟 Host 同源。
        let sameOrigin: [(String?, String)] = [
            (nil, "localhost:3939"), ("", "localhost:3939"),
            ("http://localhost:3939", "localhost:3939"), ("http://LOCALHOST:3939", "localhost:3939"),
            ("http://127.0.0.1:3940", "127.0.0.1:3940"), ("http://[::1]:3939", "[::1]:3939"),
            ("http://dj-mac.local:3939", "DJ-Mac.local:3939"), ("http://192.168.31.24", "192.168.31.24"),
            ("http://192.168.31.24:80", "192.168.31.24"),
        ]
        for (origin, host) in sameOrigin {
            expectEqual(WebLyricsAccess.originAllowed(origin, host: host), true, "网页歌词: Origin \(origin ?? "nil") → Host \(host) 放行")
        }
        let crossOrigin: [(String?, String?)] = [
            ("https://evil.example", "localhost:3939"), ("http://evil.example:3939", "localhost:3939"),
            ("http://localhost:3940", "localhost:3939"), ("http://127.0.0.1:3939", "localhost:3939"),
            ("http://localhost", "localhost:3939"), ("null", "localhost:3939"), ("file://", "localhost:3939"),
            ("http://localhost:3939/x", "localhost:3939"), ("http://localhost:99999", "localhost:3939"),
            ("http://localhost:3939", nil), ("http://[::1]:3939", "localhost:3939"), ("chrome-extension://abc", "localhost:3939"),
        ]
        for (origin, host) in crossOrigin {
            expectEqual(WebLyricsAccess.originAllowed(origin, host: host), false,
                        "网页歌词: Origin \(origin ?? "nil") → Host \(host ?? "nil") 挡住")
        }
    }

    // ---- 副屏尺寸 ----
    do {
        let phone = WebLyricsViewport(query: ["w": "390", "h": "844", "dpr": "3"])
        expectEqual([phone.width, phone.height, phone.pixelWidth, phone.pixelHeight], [390, 844, 1170, 2532], "网页歌词: 手机竖屏原样")
        expectEqual(phone.scale, 3, "网页歌词: 手机 3x 原样")
        expectEqual(phone.showsPlayerPane, false, "网页歌词: 窄于 640 不摆左栏(同歌词窗口)")
        let tablet = WebLyricsViewport(query: ["w": "1180", "h": "820", "dpr": "2"])
        expectEqual(tablet.showsPlayerPane, true, "网页歌词: 平板横屏摆左栏")
        func arrangement(_ w: Int, _ h: Int) -> WebLyricsViewport.Arrangement { WebLyricsViewport(width: w, height: h, scale: 2).arrangement }
        expectEqual([arrangement(1180, 820), arrangement(1512, 900), arrangement(844, 390)], [.columns, .columns, .columns],
                    "网页歌词: 够宽又横着的照歌词窗口左右两栏(手机横放也是)")
        expectEqual([arrangement(820, 1180), arrangement(744, 1133), arrangement(1024, 1366)], [.stacked, .stacked, .stacked],
                    "网页歌词: 够宽但竖着(平板竖放)播放器在上、歌词在下")
        expectEqual([arrangement(390, 844), arrangement(430, 932), arrangement(375, 667), arrangement(390, 600)],
                    [.phoneStacked, .phoneStacked, .phoneStacked, .phoneStacked],
                    "网页歌词: 手机竖放(高至少是宽的 1.5 倍)顶上一列封面、歌名、播放键,歌词在下")
        expectEqual([arrangement(600, 400), arrangement(500, 600), arrangement(390, 580)], [.compact, .compact, .compact],
                    "网页歌词: 窄于 640 又不够高(手机横放、方形小窗)是顶上一行歌名、底部播放条")
        let screenSource = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lyrimuse/WebLyrics/WebLyricsScreen.swift"), encoding: .utf8)) ?? ""
        expectEqual(sourceHas(screenSource, "case .phoneStacked: return .column")
                        && sourceHas(screenSource, "height: WebLyricsPlayerPane.columnHeight(width: side))")
                        && sourceHas(screenSource, "let top = phoneStackedPaneRect.maxY + 16")
                        && sourceHas(screenSource, "let total = Self.columnHeight(width: w)")
                        && sourceHas(screenSource, "centered: arrangement == .phoneStacked, wordRise: true,")
                        && sourceHas(screenSource, "showsScrollIndicator: arrangement != .phoneStacked,"), true,
                    "网页歌词: 手机竖放顶上那一块用歌词窗口左栏那一列,块高和那一列整组高同一个函数,歌词从它下面开始")
        expectEqual(arrangement(640, 640), .columns, "网页歌词: 正方形按横着算(高大于宽才算竖)")
        let laptop = WebLyricsViewport(query: ["w": "1512", "h": "900", "dpr": "2"])
        expectEqual([laptop.pixelWidth, laptop.pixelHeight], [3024, 1800], "网页歌词: 笔记本全屏浏览器照样 2x")
        let big = WebLyricsViewport(width: 2560, height: 1440, scale: 3)
        expectEqual(big.scale > 1.3 && big.scale < 1.4, true, "网页歌词: 像素超上限时按比例压倍数,不整档降到 1x")
        expectEqual(big.pixelWidth * big.pixelHeight <= WebLyricsViewport.maxPixels, true, "网页歌词: 压倍后像素在上限内")
        expectEqual(big.pixelWidth % 2 == 0 && big.pixelHeight % 2 == 0, true, "网页歌词: 像素宽高取偶数")
        let tiny = WebLyricsViewport(width: 10, height: 99_999, scale: 9)
        expectEqual([tiny.width, tiny.height], [WebLyricsViewport.pointRange.lowerBound, WebLyricsViewport.pointRange.upperBound],
                    "网页歌词: 宽高夹进范围")
        expectEqual(tiny.scale >= 1, true, "网页歌词: 倍数至少 1")
        let fallback = WebLyricsViewport(query: ["w": "abc", "dpr": "1.5"])
        expectEqual([fallback.width, fallback.height, fallback.pixelWidth], [1180, 820, 1770], "网页歌词: 认不出的取默认,小数倍数原样用")
        let junk = WebLyricsViewport(query: ["dpr": "nan"])
        expectEqual(junk.scale, 2, "网页歌词: 倍数认不出按 2x")
        // 查询串是外部输入:超出 Int 的数先夹再转,不能崩。
        let huge = WebLyricsViewport(query: ["w": "1e300", "h": "-1e300", "dpr": "1e300"])
        expectEqual([huge.width, huge.height], [WebLyricsViewport.pointRange.upperBound, WebLyricsViewport.pointRange.lowerBound],
                    "网页歌词: 极大极小的宽高夹进范围")
        expectEqual(huge.pixelWidth * huge.pixelHeight <= WebLyricsViewport.maxPixels, true, "网页歌词: 极大倍数也压在像素上限内")
        let overflow = WebLyricsViewport(query: ["w": "9223372036854775807", "h": "1e400"])
        expectEqual([overflow.width, overflow.height], [WebLyricsViewport.pointRange.upperBound, 820],
                    "网页歌词: 刚好溢出 Int 的宽夹到上限,inf 按默认")
        let notch = WebLyricsViewport(query: ["w": "393", "h": "852", "dpr": "3", "st": "59", "sb": "34"])
        expectEqual(notch.safeArea, .init(top: 59, left: 0, bottom: 34, right: 0), "网页歌词: 安全区四边原样读出(缺的那边按 0)")
        expectEqual(phone.safeArea, .zero, "网页歌词: 没报安全区按 0")
        let sideways = WebLyricsViewport(query: ["w": "852", "h": "393", "sl": "59.4", "sr": "1e300", "sb": "-21", "st": "nan"])
        expectEqual(sideways.safeArea, .init(top: 0, left: 59, bottom: 0, right: WebLyricsViewport.maxSafeInset),
                    "网页歌词: 安全区取整、夹进 0…上限,认不出按 0")
        expectEqual(WebLyricsViewport(width: 400, height: 300, scale: 2, safeArea: .init(top: 200, left: 0, bottom: 0, right: 0)).safeArea.top,
                    75, "网页歌词: 安全区不超过那一边高的四分之一")
        expectEqual(notch == WebLyricsViewport(query: ["w": "393", "h": "852", "dpr": "3"]), false,
                    "网页歌词: 安全区不同的网页各画各的(同尺寸不合并成一份)")
    }

    // ---- 副屏点按 ----
    do {
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["d",0.25,0.75]}"#.utf8)),
                    WebLyricsPointer(phase: .down, point: CGPoint(x: 0.25, y: 0.75)), "网页歌词: 按下位置原样读出")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["m",1.2,-0.1]}"#.utf8)),
                    WebLyricsPointer(phase: .move, point: CGPoint(x: 1, y: 0)), "网页歌词: 拖出画面的位置夹回 0…1")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["u",3,0.5]}"#.utf8)), nil, "网页歌词: 离画面太远不认")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["x",0.5,0.5]}"#.utf8)), nil, "网页歌词: 不认识的阶段不认")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["d",0.5]}"#.utf8)), nil, "网页歌词: 缺一维不认")
        expectEqual(WebLyricsPointer.parse(Data("ptr".utf8)), nil, "网页歌词: 不是 JSON 不认")
        expectEqual(WebLyricsPointer.parse(Data(#"{"ptr":["c",0,1]}"#.utf8))?.phase, .cancel, "网页歌词: 取消")
        expectEqual(WebLyricsWheel.parse(Data(#"{"whl":[0.5,0.25,0.1]}"#.utf8)),
                    WebLyricsWheel(point: CGPoint(x: 0.5, y: 0.25), dy: 0.1), "网页歌词: 滚轮位置和滚动量原样读出")
        expectEqual(WebLyricsWheel.parse(Data(#"{"whl":[0.5,0.5,9]}"#.utf8))?.dy, 2, "网页歌词: 一次滚动最多算两屏")
        expectEqual(WebLyricsWheel.parse(Data(#"{"whl":[1.5,0.5,0.1]}"#.utf8)), nil, "网页歌词: 滚轮在画面外不认")
        expectEqual(WebLyricsPointer.parse(Data(#"{"whl":[0.5,0.5,0.1]}"#.utf8)), nil, "网页歌词: 滚轮消息不当指针事件")
        expectEqual(WebLyricsVisibility.parse(Data(#"{"vis":0}"#.utf8)), false, "网页歌词: 副屏报不可见")
        expectEqual(WebLyricsVisibility.parse(Data(#"{"vis":1}"#.utf8)), true, "网页歌词: 副屏报看得见")
        expectEqual(WebLyricsVisibility.parse(Data(#"{"vis":0.5}"#.utf8)), nil, "网页歌词: 可见性只认 0 / 1")
        expectEqual(WebLyricsVisibility.parse(Data(#"{"ptr":["d",0.5,0.5]}"#.utf8)), nil, "网页歌词: 指针事件不当可见性")
        expectEqual(WebLyricsPointer.permits(remoteIsLoopback: true, lanControlEnabled: false), true, "网页歌词: 本机副屏一律能点")
        expectEqual(WebLyricsPointer.permits(remoteIsLoopback: false, lanControlEnabled: false), false,
                    "网页歌词: 别的设备默认不能控制播放")
        expectEqual(WebLyricsPointer.permits(remoteIsLoopback: false, lanControlEnabled: true), true, "网页歌词: 开了控制开关别的设备能点")

        // 平板 1180 宽:封面边长 0.279W ≈ 329
        let layout = WebLyricsControlsLayout(width: 329, rowTop: 500, rowHeight: 32, skipGlyphWidth: 24)
        let cells = layout.cells
        expectEqual(cells[.shuffle]?.minX, 0, "网页歌词: 随机贴左缘")
        expectEqual(cells[.repeatMode]?.maxX, 329, "网页歌词: 循环贴右缘")
        let play = cells[.playPause] ?? .zero
        expectEqual(abs(play.midX - 329 / 2) < 0.01, true, "网页歌词: 播放键居中")
        expectEqual([layout.modeFontSize, layout.skipFontSize, layout.playFontSize].map { ($0 * 100).rounded() / 100 },
                    [14.15, 19.74, 25.99], "网页歌词: 控制键字号照歌词窗口的比例")
        expectEqual(layout.button(at: CGPoint(x: play.midX, y: 516)), .playPause, "网页歌词: 点播放键")
        expectEqual(layout.button(at: CGPoint(x: (cells[.next] ?? .zero).midX, y: 495)), .next,
                    "网页歌词: 点在键上方一点也算(命中区扩到 44)")
        expectEqual(layout.button(at: CGPoint(x: 2, y: 516)), .shuffle, "网页歌词: 点随机")
        expectEqual(layout.button(at: CGPoint(x: play.midX, y: 600)), nil, "网页歌词: 控制排以外不算")
        let gapX = ((cells[.previous] ?? .zero).maxX + play.minX) / 2
        let between = layout.button(at: CGPoint(x: gapX, y: 516))
        expectEqual(between == .previous || between == .playPause, true, "网页歌词: 两键之间只归一颗")
    }

    // ---- 端口与链接 ----
    do {
        expectEqual(WebLyricsPort.parse(" 8080 "), 8080, "网页歌词: 端口输入去掉空格")
        expectEqual(WebLyricsPort.parse("80"), nil, "网页歌词: 1024 以下的端口不收")
        expectEqual(WebLyricsPort.parse("65536"), nil, "网页歌词: 超出 65535 不收")
        expectEqual(WebLyricsPort.parse("abc"), nil, "网页歌词: 不是数字不收")
        expectEqual(WebLyricsPort.clamped(70_000), WebLyricsPort.standard, "网页歌词: 存坏了的端口按默认")
        expectEqual(WebLyricsLinks.url(host: "localhost", port: 3939)?.absoluteString, "http://localhost:3939/", "网页歌词: 本机链接不带密钥")
        expectEqual(WebLyricsLinks.url(host: "localhost", port: 3940, preview: true)?.absoluteString,
                    "http://localhost:3940/?preview=1", "网页歌词: OBS 预览链接")
        expectEqual(WebLyricsLinks.url(host: "Studio-Mac.local", port: 3940, token: "ab12")?.absoluteString,
                    "http://Studio-Mac.local:3940/?k=ab12", "网页歌词: 别的电脑上 OBS 用的链接带密钥")
        expectEqual(WebLyricsPort.clamped(80, fallback: WebLyricsPort.obsStandard), WebLyricsPort.obsStandard,
                    "网页歌词: OBS 端口存坏了按 OBS 的默认")
        expectEqual(WebLyricsPort.standard == WebLyricsPort.obsStandard, false, "网页歌词: 网页、OBS 默认端口不同")
        expectEqual(WebLyricsAccess.hostAllowed("studio-mac.local:3939", localNames: ["Studio-Mac.local"]), true,
                    "网页歌词: .local 名字不分大小写")
    }

    // ---- OBS 消息 ----
    do {
        expectEqual(WebLyricsObsPayload.obsTimelineMs(timelineMs: 10_000, bundleID: "com.apple.Music", playerOffsets: [:], globalOffsetMs: 180),
                    9_820, "网页歌词: OBS 扣掉「全部播放器」那档(耳机延迟)")
        expectEqual(WebLyricsObsPayload.obsTimelineMs(timelineMs: 10_000, bundleID: "com.google.Chrome",
                                                      playerOffsets: ["com.google.Chrome": 400], globalOffsetMs: 180),
                    10_000, "网页歌词: 这个播放器单独配过偏移时照常算")
        expectEqual(WebLyricsObsPayload.obsTimelineMs(timelineMs: 10_000, bundleID: nil, playerOffsets: ["x": 1], globalOffsetMs: 180),
                    9_820, "网页歌词: 不知道是哪个播放器时按「全部」那档扣")
        expectEqual(WebLyricsObsPayload.cssColor(red: 1, green: 0.5, blue: 0, alpha: 0.35), "rgba(255,128,0,0.35)", "网页歌词: CSS 颜色")
        expectEqual(WebLyricsObsPayload.cssColor(red: 2, green: -1, blue: 0, alpha: 3), "rgba(255,0,0,1.0)", "网页歌词: CSS 颜色夹值")
        expectEqual(OverlayFontWeight.allCases.map(WebLyricsObsPayload.cssWeight), [300, 400, 500, 600, 700, 800], "网页歌词: 字重映射")
        expectEqual(WebLyricsObsPayload.cssWeights(.semibold), [600, 400, 300, 400], "网页歌词: 读音 / 译文 / 下一句的字重照悬浮歌词的档位差")
        let styleJSON = WebLyricsObsPayload.style(.init(
            fontFamily: "", fontSize: 31, weights: [600, 400, 300, 400], sung: "rgba(0,0,0,1.0)", unsung: "rgba(0,0,0,0.55)",
            stroke: nil, card: nil, showRomanization: true, showTranslation: false, showNextLine: true, karaoke: true,
            alignment: .leading, overflow: .scroll, spacing: .init(romanization: 4, translation: 6, nextLine: 99),
            width: 640, hideWhenPaused: true, lineChangeAnimation: true, duetStageInset: 76, duetCenterInset: 84))
        let styleObject = (try? JSONSerialization.jsonObject(with: Data(styleJSON.utf8))) as? [String: Any]
        expectEqual(styleObject?["next"] as? Bool, true, "网页歌词: style 带下一句开关")
        expectEqual(styleObject?["align"] as? String, "leading", "网页歌词: style 带对齐方式")
        expectEqual(styleObject?["overflow"] as? String, "scroll", "网页歌词: style 带换行或滚动")
        expectEqual(styleObject?["width"] as? Double, 640, "网页歌词: style 带悬浮歌词宽度")
        expectEqual(styleObject?["hidePaused"] as? Bool, true, "网页歌词: style 带暂停时隐藏")
        expectEqual(styleObject?["anim"] as? Bool, true, "网页歌词: style 带换句动画")
        let duet = WebLyricsObsPayload.duetInsets(overlayWidth: 640, fontSize: 31)
        expectEqual(duet.stage, Double(OverlayCardGeometry.duetStageInset(availableWidth: 600, fontSize: 31)),
                    "网页歌词: 对唱舞台缩进同悬浮歌词(可用宽度 = 宽度 − 40)")
        expectEqual(duet.center, Double(LyricDuetLayout.insets(for: .leading, availableWidth: 600, fontSize: 31).trailing),
                    "网页歌词: 合唱两侧留白同悬浮歌词")
        expectEqual(styleObject?["spacing"] as? [Double], [4, 6, OverlayRowSpacing.range.upperBound], "网页歌词: style 行距夹回范围")

        let withWords = LyricsSyncEngine()
        _ = withWords.load(lyrics: "[00:01.00]あい\n[00:05.00]うえ", lyricsTr: "[00:01.00]啊\n[00:05.00]呜", lyricsRoma: "",
                           lyricsYRC: "[1000,800](1000,400,0)あ(1400,400,0)い\n[5000,800](5000,400,0)う(5400,400,0)え")
        let json = WebLyricsObsPayload.track(id: "t", lines: withWords.allLines(idPrefix: "t"), gaps: withWords.gapMarkers())
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let encoded = object?["lines"] as? [[String: Any]] ?? []
        expectEqual(object?["type"] as? String, "track", "网页歌词: track 消息类型")
        expectEqual(encoded.count, 2, "网页歌词: 行数")
        expectEqual(encoded.first?["t"] as? Int, 1_000, "网页歌词: 行起点")
        expectEqual(encoded.first?["text"] as? String, "あい", "网页歌词: 整行文字")
        expectEqual((encoded.first?["w"] as? [[Any]])?.count, 2, "网页歌词: 逐字每个字一项")
        expectEqual((encoded.first?["w"] as? [[Any]])?.first?.count, 3, "网页歌词: 逐字是 [起点, 时长, 字]")
        expectEqual(encoded.first?["tr"] as? String, "啊", "网页歌词: 译文")
        expectEqual(encoded.first?["s"] == nil, true, "网页歌词: 没有对唱声部的行省略 s")
        let groups = encoded.first?["g"] as? [[Any]]
        expectEqual(groups?.compactMap { $0.first as? Int }.reduce(0, +), (encoded.first?["w"] as? [[Any]])?.count,
                    "网页歌词: 日文逐词读音按顺序覆盖整行的字")
        let segmented = withWords.surfaceWindowLines(.overlay, idPrefix: "t")
        expectEqual(segmented.map(\.timeMs), [1_000, 5_000], "网页歌词: 悬浮歌词断好的段带开始时刻(没开拆分时一行一段)")
        expectEqual(object?["gaps"] is [Any], true, "网页歌词: 带间奏列表")
        let lineLevel = LyricsSyncEngine()
        _ = lineLevel.load(lyrics: "[00:01.00]整行歌词", lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        let plainObject = (try? JSONSerialization.jsonObject(with: Data(
            WebLyricsObsPayload.track(id: "p", lines: lineLevel.allLines(idPrefix: "p"), gaps: []).utf8))) as? [String: Any]
        let plainLines = plainObject?["lines"] as? [[String: Any]] ?? []
        expectEqual(plainLines.first?["text"] as? String, "整行歌词", "网页歌词: 整行歌词的文字")
        expectEqual(plainLines.first?["w"] == nil, true, "网页歌词: 没有逐字时间的行省略 w")
        let pos = WebLyricsObsPayload.position(timelineMs: 1_234, rate: 1, state: .paused)
        expectEqual(pos, #"{"pos":1234,"rate":1,"state":"paused","type":"pos"}"#, "网页歌词: pos 消息")

        expectEqual(styleObject?["songCard"] as? String, "off", "网页歌词: style 带歌名卡档位(没给时按不显示)")
        let songObject = (try? JSONSerialization.jsonObject(with: Data(WebLyricsObsPayload.song(
            id: "七里香\u{1F}周杰伦", title: "七里香", artist: "周杰伦", album: "七里香", cover: nil).utf8))) as? [String: Any]
        expectEqual(songObject?["type"] as? String, "song", "网页歌词: song 消息类型")
        expectEqual(songObject?["id"] as? String, "七里香\u{1F}周杰伦", "网页歌词: song 的 id 跟 track 同一种拼法")
        expectEqual(songObject?["album"] as? String, "七里香", "网页歌词: song 带专辑")
        expectEqual(songObject?["cover"] == nil, true, "网页歌词: 没有封面时省略 cover")
        let bigCover: Data? = {
            guard let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            guard let image = ctx.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }()
        let coverURL = bigCover.flatMap { WebLyricsObsPayload.coverDataURL($0) }
        let coverBytes = coverURL.flatMap { Data(base64Encoded: String($0.dropFirst("data:image/jpeg;base64,".count))) }
        expectEqual(coverURL?.hasPrefix("data:image/jpeg;base64,"), true, "网页歌词: 封面转成 JPEG 的 data URL")
        expectEqual(coverBytes.map { CoverArtReplacementGate.pixelSize(of: $0).width }, WebLyricsObsPayload.coverMaxPixels,
                    "网页歌词: 封面最长边缩到上限")
        expectEqual(coverBytes.map { CoverArtReplacementGate.pixelSize(of: $0).height }, 171, "网页歌词: 封面缩放保持比例")
        expectEqual(WebLyricsObsPayload.coverDataURL(Data("not an image".utf8)) == nil, true, "网页歌词: 读不出来的封面返回 nil")
    }

    // ---- 离屏拼图层树 ----
    do {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        root.wantsLayer = true
        let child = Flipped(frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        child.wantsLayer = true
        child.bounds.origin = CGPoint(x: 0, y: 30)
        let grandchild = NSView(frame: CGRect(x: 5, y: 6, width: 20, height: 10))
        root.addSubview(child)
        child.addSubview(grandchild)
        expectEqual(root.layer?.sublayers?.contains { $0 === child.layer } ?? false, false,
                    "网页歌词: 不挂窗口时 AppKit 确实不把子视图图层挂上去(拼树的前提)")
        DetachedLayerTree.assemble(root)
        expectEqual(child.layer?.superlayer === root.layer, true, "网页歌词: 子视图图层挂到父图层下")
        expectEqual(grandchild.layer?.superlayer === child.layer, true, "网页歌词: 孙视图没开图层也补上并挂好")
        expectEqual(child.layer?.position, CGPoint(x: 10, y: 20), "网页歌词: 位置取视图 frame 原点")
        expectEqual(child.layer?.bounds.origin, CGPoint(x: 0, y: 30), "网页歌词: 滚动偏移(bounds.origin)同步到图层")
        expectEqual(child.layer?.isGeometryFlipped, true, "网页歌词: 翻转视图在不翻转的父视图下翻转坐标")
        expectEqual(grandchild.layer?.isGeometryFlipped, true, "网页歌词: 不翻转的视图在翻转的父视图下也翻一次")
        grandchild.removeFromSuperview()
        DetachedLayerTree.assemble(root)
        expectEqual(child.layer?.sublayers?.contains { $0 === grandchild.layer } ?? false, false,
                    "网页歌词: 拿掉的子视图,它的图层一并摘掉")
        let plain = CALayer()
        child.layer?.addSublayer(plain)
        DetachedLayerTree.assemble(root)
        expectEqual(plain.superlayer === child.layer, true, "网页歌词: 组件自己加的普通图层不动")
    }

    // ---- 接线契约 ----
    do {
        let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func app(_ path: String) -> String {
            let text = (try? String(contentsOf: appDir.appendingPathComponent(path), encoding: .utf8)) ?? ""
            expectEqual(text.isEmpty, false, "网页歌词: 读到了 \(path)")
            return text
        }
        let server = app("WebLyrics/WebLyricsServer.swift")
        expectEqual(sourceBytes(server, contain: "params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)"), true,
                    "网页歌词: 局域网没开时只绑 127.0.0.1")
        expectEqual(sourceBytes(server, contain: "WebLyricsAccess.permits(remoteIsLoopback: connection.isLoopback"), true,
                    "网页歌词: 每个请求都过访问控制")
        expectEqual(sourceBytes(server, contain: "WebLyricsAccess.hostAllowed(request.headers[\"host\"]"), true,
                    "网页歌词: 每个请求都核 Host 头")
        expectEqual(sourceBytes(server, contain: "WebLyricsAccess.originAllowed(request.headers[\"origin\"], host: request.headers[\"host\"])"),
                    true, "网页歌词: 每个请求都核 Origin 与 Host 同源(挡别的网页连本机回环)")
        expectEqual(sourceBytes(server, contain: "frame-ancestors 'none'"), true, "网页歌词: 页面不让别的网页嵌进 iframe")
        expectEqual(sourceBytes(server, contain: "guard let self, !self.requestReceived else { return }"), true,
                    "网页歌词: 连上后迟迟不发请求头的连接到点断开,不占名额")
        expectEqual(sourceBytes(server, contain: "if idle >= Self.sendStallTimeout {"), true,
                    "网页歌词: 发出去的东西长时间没被收走就断开")
        expectEqual(sourceHas(app("WebLyrics/WebLyricsScreen.swift"), "if sendBacklogged {\n notePace(.backlog)"), true,
                    "网页歌词: 这一尺寸的网页全都没发完上一帧时出帧线程跳拍")
        expectEqual(sourceBytes(app("AppDelegate.swift"), contain: "WebLyricsServer.startAll()"), true, "网页歌词: 启动时接上两个服务")
        let pages = app("WebLyrics/WebLyricsPages.swift")
        expectEqual(sourceBytes(pages, contain: "get('preview') === '1') document.body.classList.add('preview');"), true,
                    "网页歌词: OBS 页带 preview=1 时铺棋盘格底")
        expectEqual(sourceBytes(pages, contain: "height: 100vh") || sourceBytes(pages, contain: "height:100vh"), false,
                    "网页歌词: 画布、视频别按 100vh 铺(iOS Safari 比看得见的高度多出工具栏那截,上下留黑边)")
        expectEqual(sourceBytes(pages, contain: "const box = canvas.getBoundingClientRect();")
                        && sourceBytes(pages, contain: "url.searchParams.set('h', Math.round(box.height || innerHeight));"), true,
                    "网页歌词: 画面按画布实际铺开的大小要")
        expectEqual(sourceBytes(pages, contain: #"<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">"#)
                        && sourceBytes(pages, contain: "env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)")
                        && sourceBytes(pages, contain: "[['st', 'paddingTop'], ['sr', 'paddingRight'], ['sb', 'paddingBottom'], ['sl', 'paddingLeft']]"), true,
                    "网页歌词: 添加到主屏幕后铺到状态栏底下,安全区报给 App")
        expectEqual(sourceBytes(server, contain: "token.dropFirst().removeDuplicates()"), true,
                    "网页歌词: 换了密钥就断开别的设备")
        expectEqual(sourceBytes(server, contain: "Publishers.CombineLatest4(enabled, lan, port, other)"), true,
                    "网页歌词: 改端口重新监听,另一个的端口变了也重新核")
        expectEqual(sourceBytes(server, contain: "if Self.otherPort(of: channel) == port {"), true,
                    "网页歌词: 两个服务端口相同时都不监听")
        expectEqual(sourceBytes(server, contain: "let page = channel == .obs ? WebLyricsPages.obsPage() : WebLyricsPages.screenPage()"), true,
                    "网页歌词: 网页、OBS 各占一个端口,根路径就是各自的页面")
        expectEqual(sourceBytes(pages, contain: "--sung:var(--sung-reading)"), true,
                    "网页歌词: 逐词读音的已唱色走单独的变量(写成引用自己的 --sung 会整段失效、读音看不见)")
        expectEqual(sourceBytes(pages, contain: "setInterval(() => { if (performance.now() - lastTick > 50) tick(); }, 33);"), true,
                    "网页歌词: OBS 页 rAF 停了由定时器接着刷(OBS 失焦时 rAF 会停)")
        expectEqual(sourceBytes(pages, contain: "<feGaussianBlur id=\"lmBlur\" in=\"SourceAlpha\""), true,
                    "网页歌词: OBS 页描边照悬浮歌词用模糊剪影")
        expectEqual(sourceBytes(pages, contain: "html += '<div class=\"row dots\"><i></i><i></i><i></i></div>';"), true,
                    "网页歌词: OBS 页前奏 / 间奏画「•••」")
        // 不连外部地址:任何「scheme://」(http、https、ws、wss…)、引号 / 括号 / 等号后面的协议相对地址(`src="//cdn…"`、
        // `url(//…)`)、外链样式表都不许有。连回 App 的 WebSocket 由 location 推出来,不写地址。
        let externalRefs = [#"[A-Za-z][A-Za-z0-9+.\-]*://"#, #"["'(=]\s*//[A-Za-z0-9]"#, #"@import|<link\b"#]
            .map { try! NSRegularExpression(pattern: $0) }
        func referencesExternal(_ text: String) -> Bool {
            externalRefs.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        }
        for sample in ["<script src=\"https://cdn.example/x.js\">", "new WebSocket('wss://evil.example/ws')",
                       "<img src=\"//cdn.example/a.png\">", "background: url(//cdn.example/a.png)", "@import 'x.css';"] {
            expectEqual(referencesExternal(sample), true, "网页歌词: 外部地址扫描认得 \(sample)")
        }
        expectEqual(referencesExternal("url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'; // 跟着页面走"), false,
                    "网页歌词: 由 location 推出协议、行尾注释不算外部地址")
        expectEqual(referencesExternal(pages), false, "网页歌词: 网页不连外部地址")
        let gapDots = app("UI/LyricsGapDots.swift")
        expectEqual(sourceBytes(gapDots, contain: "guard c.running, window != nil || rendersDetached else { return }"), true,
                    "网页歌词: 间奏点离屏时也装动画")
        let pagesSource = app("WebLyrics/WebLyricsPages.swift")
        expectEqual(sourceBytes(pagesSource, contain: "ws.send(JSON.stringify({ ptr: [phase,"), true, "网页歌词: 副屏把按下、拖动、抬起发回 App")
        expectEqual(sourceBytes(pagesSource, contain: "if (downLink && linkAt(u, v) === downLink) window.open(downLink, '_blank', 'noopener');"),
                    true, "网页歌词: 平台页在手指抬起那一刻由网页自己打开(等 App 回话再开会被浏览器拦掉)")
        expectEqual(sourceBytes(app("UI/LyricsWindowView.swift"), contain: "@StateObject private var moreMenu = LyricsMoreMenuModel()"),
                    true, "网页歌词: 歌词窗口「…」菜单的直接动作跟副屏共用 LyricsMoreMenuModel")
        expectEqual(sourceBytes(pagesSource, contain: "touch-action: none;"), true, "网页歌词: 副屏画布自己接拖动,浏览器不拿去滚页面、缩放")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsServer.swift"),
                                contain: "if case .screen = role { server?.screens.message(self, payload: frame.payload) }"), true,
                    "网页歌词: 只有副屏连接的文本帧当点按 / 可见性")
        expectEqual(sourceBytes(pagesSource, contain: "document.addEventListener('visibilitychange', sendVisibility);"), true,
                    "网页歌词: 副屏网页可见性一变就报给 App")
        expectEqual(sourceBytes(pagesSource, contain: "socket.onopen = () => { retry = 1000; sendVisibility(); if (statsOn) sendStatsToggle(); };"), true,
                    "网页歌词: 副屏网页连上时先报一次可见性(后台标签页重连上来也算数)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"),
                                contain: "let active = viewersVisible && (playback.isPlayingNow || now < fastUntil)"), true,
                    "网页歌词: 这一尺寸的网页全看不见时按暂停那一档出帧")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"),
                                contain: "lanControlEnabled: AppSettings.shared.webLyricsAllowLANControl"), true,
                    "网页歌词: 点按过控制开关")
        let screenSource = app("WebLyrics/WebLyricsScreen.swift")
        // 暂停通知先到、锚点已冻而 isPlayingNow 还没翻:按歌词时钟停表、不再提前画、当场报暂停(19 章决策 41)。
        expectEqual(sourceBytes(screenSource, contain: "let playing = playback.lyricsClockRunning")
                    && sourceBytes(screenSource, contain: "let next = playing && leadMs > 0 ? PlaybackCoordinator.shared.lyricsLookahead(leadMs: leadMs) : nil")
                    && sourceBytes(screenSource, contain: "isPlaying: playback.lyricsClockRunning, surfaceVisible: true,"),
                    true, "网页歌词: 副屏按歌词时钟停表,锚点冻住就不再提前画、当场发现暂停")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsObsFeed.swift"), contain: "state = p.lyricsClockRunning ? .playing : .paused"),
                    true, "网页歌词: OBS 那条锚点冻住就报暂停(网页把速率 0 当 1 倍速往前推)")
        expectEqual(sourceBytes(screenSource, contain: "timer = DispatchSource.makeTimerSource(queue: queue)"), true,
                    "网页歌词: 副屏出帧在自己的队列上按节拍画,不挂在主线程定时器上")
        expectEqual(sourceBytes(screenSource, contain: "private let titleLayer = CATextLayer()"), false,
                    "网页歌词: 歌名不用 CATextLayer(截断过长的一行时整行错位)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsServer.swift"), contain: "connection.sendText(WebLyricsPages.helloMessage())"), true,
                    "网页歌词: 连上后先告诉网页这一版的 revision,旧网页自己刷新")
        expectEqual(sourceBytes(pagesSource, contain: "if (m.type === 'hello') checkRevision(m.rev);"), true,
                    "网页歌词: 副屏网页认 hello")
        expectEqual(sourceBytes(pagesSource, contain: "else if (m.type === 'hello') checkRevision(m.rev);"), true,
                    "网页歌词: OBS 网页认 hello")
        expectEqual(sourceBytes(pagesSource, contain: "setInterval(() => { if (performance.now() - lastFrame > 50) present(); }, 16);"), true,
                    "网页歌词: 副屏 rAF 不来时由定时器接着放(从别的 App 打开的浏览器小窗里 rAF 可能一直不来)")
        expectEqual(sourceBytes(pagesSource, contain: "queue[i].t + wait <= now")
                        && sourceBytes(pagesSource, contain: "const now = performance.now(), wait = offset + delay();"), true,
                    "网页歌词: 副屏网页按画帧时刻匀速放,余量按到帧的抖动自适应")
        expectEqual(sourceHas(pagesSource, "if (late >= jitter) { jitter = late; jitterAt = now; }")
                        && sourceHas(pagesSource, "else if (now - jitterAt > PEAK_HOLD) jitter = Math.max(late, jitter - (now - lastArrival) * PEAK_DECAY);"), true,
                    "网页歌词: 副屏到帧晚了立刻放宽余量,近 20 秒最晚那次撑着,之后每秒收回一点")
        expectEqual(sourceHas(pagesSource, "const cap = useVideo ? MAX_VIDEO_DELAY : Math.min(gap * bufferCap(), MAX_DELAY);"), true,
                    "网页歌词: 视频流排的是没解的数据,余量能放到 2 秒;逐帧 JPEG 受内存限制")
        expectEqual(sourceHas(pagesSource, "return Math.max(MIN_DELAY, Math.min(jitter + 16 + (useVideo ? (viaMse ? MSE_MARGIN : decodeCost) : 0), cap));")
                        && sourceHas(pagesSource, "const until = now - offset - delay() + decodeLead();")
                        && sourceHas(pagesSource, "decodeCost = sorted[Math.floor(sorted.length * 0.95)];"), true,
                    "网页歌词: 视频按实测解一帧的耗时(p95)提前送去解,余量也留出这段(报给 App,提前画把解码算进去);走 MediaSource 的固定多留一段")
        expectEqual(sourceHas(pagesSource, "let statsOn = new URLSearchParams(location.search).get('stats') === '1';")
                        && sourceHas(pagesSource, "if (e.metaKey || e.ctrlKey || e.altKey || (e.key !== 'd' && e.key !== 'D')) return;")
                        && sourceHas(pagesSource, "else if (m.type === 'stats') statsServer = m;")
                        && sourceHas(pagesSource, "socket.onopen = () => { retry = 1000; sendVisibility(); if (statsOn) sendStatsToggle(); };"), true,
                    "网页歌词诊断: 按 D 或网址带 stats=1 开关浮层,重连后照旧要统计")
        expectEqual(sourceHas(pagesSource, "if (delay() < TOUCH_DOT_DELAY) return;")
                        && sourceHas(pagesSource, "sendPointer('d', e);\n showTouchDot(e);")
                        && sourceHas(pagesSource, "sendPointer('u', e);\n hideTouchDot();"), true,
                    "网页歌词: 放帧余量 150ms 以上时按下就在手指底下画圆点、抬起淡掉(画面上的反馈要晚这么久才到)")
        expectEqual(sourceHas(app("WebLyrics/WebLyricsScreen.swift"), "if let wanted = WebLyricsStats.parseToggle(payload) {")
                        && sourceHas(app("WebLyrics/WebLyricsScreen.swift"), "let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in\n MainActor.assumeIsolated { self?.sendStats() }"), true,
                    "网页歌词诊断: 网页开着浮层时 App 每秒发统计,都关了就停")
        expectEqual(sourceHas(pagesSource, "if (!window.VideoDecoder && !mseSupported()) return false;")
                        && sourceHas(pagesSource, "const viaMse = !window.VideoDecoder;")
                        && sourceHas(pagesSource, "if (viaMse) { receiveMse(type, t, data); return; }"), true,
                    "网页歌词 MSE: 没有 WebCodecs 的浏览器(非安全上下文里的 Firefox / Chromium)照样要视频流,封成分段 MP4 交给 MediaSource")
        expectEqual(sourceHas(pagesSource, "if (held) mse.pending.push(mseSegment(++mse.seq, held.time, Math.max(1, time - held.time), held.key, held.data));"), true,
                    "网页歌词 MSE: 每帧扣到下一帧来了按两帧画帧时刻之差填时长,时间轴首尾相接")
        expectEqual(sourceHas(pagesSource, "if (ahead > MSE_AHEAD) { v.pause(); return; }")
                        && sourceHas(pagesSource, "if (ahead < -MSE_SEEK) { v.currentTime = target; return; }"), true,
                    "网页歌词 MSE: 播放位置超前就停住等、不往回跳,落后太多才跳过去")
        expectEqual(sourceHas(pagesSource, "steerMse(now);\n drawMse();")
                        && sourceBytes(pagesSource, contain: "requestVideoFrameCallback("), false,
                    "网页歌词 MSE: 每次刷新时按播放位置画,不靠 requestVideoFrameCallback(Firefox 里它一秒只回调二十几次)")
        expectEqual(pagesSource.components(separatedBy: "closeMse();").count, 2,
                    "网页歌词 MSE: 只在出错退回 JPEG 时拆 <video>,重连接着用同一条时间轴")
        expectEqual(sourceHas(pagesSource, "if (mse.baseMs !== null && cutOut(mse.baseMs + v.currentTime * 1000)) return;"), true,
                    "网页歌词 MSE: 播放位置落在暂停、跳转的丢帧窗口里时不画")
        expectEqual(sourceHas(pagesSource, "const q = mse.video.getVideoPlaybackQuality(), shown = q.totalVideoFrames - q.droppedVideoFrames;"), true,
                    "网页歌词诊断: MSE 的上屏帧数取 <video> 的播放统计(每次刷新都画,画的次数不代表新帧)")
        expectEqual(sourceHas(app("WebLyrics/WebLyricsServer.swift"), "img-src blob: data:; media-src blob:;"), true,
                    "网页歌词 MSE: 副屏页面的 CSP 放行 blob: 媒体地址(Chromium 按 CSP 拦 MediaSource 的地址)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsVideoEncoder.swift"), contain: "VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ReferenceBufferCount"), false,
                    "网页歌词: 编码器不设参考帧数(有的机器设 1 就每帧都是关键帧)")
        expectEqual(sourceHas(app("Settings/WebLyricsSettingsCard.swift"), "subtitle: L10n.t(\"在浏览器中显示歌词窗口\"), beta: true) {")
                        && sourceHas(app("SettingsView.swift"), "SettingsGroupCard(title: L10n.t(\"网页歌词\"), beta: true) { LyricsWindowWebSettingsRows() }")
                        && sourceHas(app("SettingsView.swift"), "summary: settings.webLyricsEnabled ? L10n.t(\"已开启\") : L10n.t(\"未开启\"), beta: true)")
                        && sourceHas(app("SettingsView.swift"), "SettingsPopoverShell(title: L10n.t(\"网页歌词\"), beta: true, width: 460) {"), true,
                    "网页歌词: 设置行、全部设置的分组、编辑台工具栏按钮、浮层标题四处入口都标 Beta")
        let webCard = app("Settings/WebLyricsSettingsCard.swift")
        expectEqual(sourceHas(webCard, "qrTile(host, label: links.ip == nil ? nil : L10n.t(\"iPhone、iPad\"))")
                        && sourceHas(webCard, "if let ip = links.ip { qrTile(ip, label: L10n.t(\"安卓\")) }")
                        && sourceHas(webCard, "private static var cache: [String: NSImage] = [:]"), true,
                    "网页歌词: 有 IP 链接时二维码并排两个(主机名给 iPhone、IP 给安卓),按链接各缓存一张")
        expectEqual(sourceHas(pagesSource, "<canvas id=\"gl\" width=\"0\" height=\"0\" style=\"display: none; pointer-events: none\"></canvas>")
                        && sourceHas(pagesSource, "if (!glPaint(src, w, h)) ctx.drawImage(src, 0, 0);")
                        && sourceBytes(pagesSource, contain: "ctx.drawImage(item.frame") == false
                        && sourceBytes(pagesSource, contain: "ctx.drawImage(v, 0, 0)") == false, true,
                    "网页歌词去色带: 三种推法都经 paint 上屏,有 WebGL 走着色器、叠在 2D 画布上面不接指针,不行就画 2D 画布")
        expectEqual(sourceHas(pagesSource, "'    if (max(max(far(s1, res), far(s2, res)), max(far(s3, res), far(s4, res))) < thr) res = (s1 + s2 + s3 + s4) * 0.25;',"), true,
                    "网页歌词去色带: 周围 4 点都跟当前值差在阈值以内才换成平均(只比平均会抹掉文字边缘)")
        expectEqual(sourceHas(pagesSource, "if (glFrames >= GL_COST_SAMPLES && glCost > gap * GL_MAX_SHARE) {\n glOff();")
                        && sourceHas(pagesSource, "if (gl.getError() !== gl.NO_ERROR) throw new Error('texImage2D');")
                        && sourceHas(pagesSource, "glCanvas.addEventListener('webglcontextlost', glOff);")
                        && sourceHas(pagesSource, "if (new URLSearchParams(location.search).get('deband') === '0') return;"), true,
                    "网页歌词去色带: 传纹理加绘制超过帧间隔的四分之三、某种帧传不上去、上下文丢了都改回 2D 画布;deband=0 关掉")
        expectEqual(sourceHas(app("WebLyrics/WebLyricsScreen.swift"),
                              "JSONSerialization.data(withJSONObject: [\"type\": \"links\", \"items\": items], options: [.sortedKeys]),"), true,
                    "网页歌词: 链接位置消息按排好序的键序列化,没变就不重发")
        // 歌名卡什么时候显示:取出 OBS 页里那个纯函数,在 JavaScriptCore 里跑
        do {
            let obsPage = pagesSource
            let helper: String? = {
                guard let a = obsPage.range(of: "const SONG_HOLD = 5000;"),
                      let b = obsPage.range(of: "function applySong(", range: a.upperBound..<obsPage.endIndex) else { return nil }
                return String(obsPage[a.lowerBound..<b.lowerBound])
            }()
            let ctx = JSContext()
            if let helper { ctx?.evaluateScript(helper) }
            func shown(_ args: String) -> String { ctx?.evaluateScript("String(songCardShown(\(args)))")?.toString() ?? "nil" }
            expectEqual(helper != nil && ctx?.exception == nil, true, "网页歌词 歌名卡: 显示判断在 JavaScriptCore 里跑得起来")
            expectEqual(shown("'always', true, 0, 60000, true"), "true", "网页歌词 歌名卡: 一直显示")
            expectEqual(shown("'always', false, 0, 0, true"), "false", "网页歌词 歌名卡: 停播 / 暂停隐藏时不显示")
            expectEqual(shown("'off', true, 0, 0, false"), "false", "网页歌词 歌名卡: 不显示")
            expectEqual(shown("'songChange', true, 1000, 5999, true"), "true", "网页歌词 歌名卡: 换歌后 5 秒内显示")
            expectEqual(shown("'songChange', true, 1000, 6000, true"), "false", "网页歌词 歌名卡: 换歌 5 秒后收起")
            expectEqual(shown("'songChange', true, 1000, 60000, false"), "true", "网页歌词 歌名卡: 换歌时显示那档里,没歌词时一直显示")
            expectEqual(shown("undefined, true, 0, 0, false"), "false", "网页歌词 歌名卡: 还没收到 style 时不显示")
            expectEqual(sourceHas(obsPage, "else if (m.type === 'song') { if (!song || song.id !== m.id) songSince = 0; song = m; applySong(); }")
                            && sourceHas(obsPage, "const hasLyrics = !!(track && song && track.id === song.id && track.lines.length > 0);"), true,
                        "网页歌词 歌名卡: 换了一首才重新计时;有没有歌词按同一首的 track 判")
            expectEqual(sourceHas(app("WebLyrics/WebLyricsObsFeed.swift"), "songCard: s.obsSongCard))")
                            && sourceHas(app("WebLyrics/WebLyricsObsFeed.swift"), "s.$obsSongCard.map { _ in () }.eraseToAnyPublisher(),")
                            && sourceHas(app("WebLyrics/WebLyricsObsFeed.swift"), "for message in [lastStyle, lastTrack, lastPosition, lastSong] where !message.isEmpty"), true,
                        "网页歌词 歌名卡: 档位随 style 发、改了就重发;新连上的网页补发 song")
            expectEqual(sourceHas(app("Settings/AppSettings.swift"),
                                  "obsSongCard = defaults.string(forKey: Keys.obsSongCard).flatMap(WebLyricsObsPayload.SongCard.init(rawValue:)) ?? .always"), true,
                        "网页歌词 歌名卡: 默认一直显示")
        }
        // MediaSource 封装:从页面脚本里取出 viaMse 到 receiveMse 之前那段纯函数,在 JavaScriptCore 里拿 App 实际发出的 avcC 跑
        do {
            let helpers: String? = {
                guard let a = pagesSource.range(of: "const viaMse = !window.VideoDecoder;"),
                      let b = pagesSource.range(of: "function receiveMse(", range: a.upperBound..<pagesSource.endIndex) else { return nil }
                return String(pagesSource[a.lowerBound..<b.lowerBound])
            }()
            let ctx = JSContext()
            if let helpers { ctx?.evaluateScript("var window = {};\n" + helpers + """

            function hexBytes(h) { return Uint8Array.from(h.match(/../g), function (x) { return parseInt(x, 16); }); }
            function boxes(buf) {
              var dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength), out = [], at = 0;
              while (at + 8 <= buf.length) { var n = dv.getUint32(at); out.push(String.fromCharCode(buf[at + 4], buf[at + 5], buf[at + 6], buf[at + 7]) + ':' + n); at += n; }
              return out.join(',') + (at === buf.length ? '' : ',trailing');
            }
            function find(buf, type) {
              for (var i = buf.length - 4; i >= 4; i--) if (String.fromCharCode(buf[i], buf[i + 1], buf[i + 2], buf[i + 3]) === type) return i - 4;
              return -1;
            }
            function field(buf, type, at, size) { var dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength), p = find(buf, type) + at; return size === 2 ? dv.getUint16(p) : dv.getUint32(p); }
            var big = hexBytes('01640034ffe1001527640034ac1314802e40dbfb9a81010103c2010a8001000428ee3cb0fdf8f800');
            var hd = hexBytes('01640020ffe1001327640020ac1314805005ba6a0404040f08042a01000428ee3cb0fdf8f800');
            var cropped = hexBytes('0164002affe100142764002aac13148056061e6e6a0404040f08042a01000428ee3cb0fdf8f800');
            var payload = Uint8Array.from([0, 0, 0, 1, 101]);
            var init = mseInit(big), key = mseSegment(7, 4294967296 + 5, 1500, true, payload), delta = mseSegment(8, 90, 1500, false, payload);
            """) }
            func js(_ expr: String) -> String { ctx?.evaluateScript(expr)?.toString() ?? "nil" }
            expectEqual(helpers != nil && ctx?.exception == nil, true, "网页歌词 MSE: 封装函数在 JavaScriptCore 里跑得起来")
            expectEqual(js("spsSize(big).join('x')"), "2960x1740", "网页歌词 MSE: 从 SPS 读出编码尺寸(2960×1740,下边裁 4 行)")
            expectEqual(js("spsSize(hd).join('x')"), "1280x720", "网页歌词 MSE: 从 SPS 读出编码尺寸(1280×720)")
            expectEqual(js("spsSize(cropped).join('x')"), "1366x768", "网页歌词 MSE: 从 SPS 读出编码尺寸(右边裁 10 列)")
            expectEqual(js("avcCodec(big)"), "avc1.640034", "网页歌词 MSE: 编码类型按 avcC 的档次与级别写")
            expectEqual(js("boxes(init).replace(/moov:[0-9]+/, 'moov')"), "ftyp:32,moov", "网页歌词 MSE: 初始化段是 ftyp + moov,长度首尾相接")
            expectEqual(js("[field(init, 'avc1', 32, 2), field(init, 'avc1', 34, 2), field(init, 'tkhd', 84) / 65536, field(init, 'tkhd', 88) / 65536].join(',')"),
                        "2960,1740,2960,1740", "网页歌词 MSE: 样本描述和轨道头写的是 SPS 里的尺寸")
            expectEqual(js("Array.from(init.subarray(find(init, 'avcC') + 8, find(init, 'avcC') + 8 + big.length)).join(',') === Array.from(big).join(',')"),
                        "true", "网页歌词 MSE: avcC 原样放进样本描述")
            expectEqual(js("boxes(key)"), "moof:100,mdat:13", "网页歌词 MSE: 一帧一段 moof + mdat")
            expectEqual(js("[field(key, 'mfhd', 12), field(key, 'tfdt', 12), field(key, 'tfdt', 16), field(key, 'trun', 16), field(key, 'trun', 20), field(key, 'trun', 24)].join(',')"),
                        "7,1,5,108,1500,5", "网页歌词 MSE: 序号、64 位起点、数据偏移(moof 长度 + 8)、时长、字节数")
            expectEqual(js("Array.from(key.subarray(108)).join(',')"), "0,0,0,1,101", "网页歌词 MSE: mdat 里原样是这一帧的数据")
            expectEqual(js("[field(key, 'trun', 28), field(delta, 'trun', 28)].map(function (x) { return x.toString(16); }).join(',')"),
                        "2000000,1010000", "网页歌词 MSE: 关键帧标成不依赖别的帧,普通帧标成依赖、非同步点")
        }
        let frameSource = app("WebLyrics/WebLyricsScreen.swift")
        expectEqual(sourceHas(frameSource, "if sendBacklogged {\n notePace(.backlog)\n return\n }\n guard framesInFlight < Self.maxFramesInFlight else {\n notePace(.inFlight)\n return\n }"), true,
                    "网页歌词: 出帧线程跳过的拍报给节拍器,分清网络发不完和在途帧满")
        expectEqual(sourceHas(frameSource, "self.framesInFlight -= 1\n self.pacer.noteEncoded(pipeline: pipeline)"), true,
                    "网页歌词: JPEG 编完时报开画到编完的整段耗时")
        expectEqual(sourceHas(frameSource, "let target = fast ? pacer.interval : Self.idleInterval"), true,
                    "网页歌词: 在播节拍按节拍器的档位")
        expectEqual(sourceHas(frameSource, "let jpeg = video == nil ? encoder(for: pacer.step) : nil")
                        && sourceHas(frameSource, "countsBacklog: !video)"), true,
                    "网页歌词: 每拍按节拍器这一档取 JPEG 编码器;视频流网络发不完不降帧率")
        let hubSource = app("WebLyrics/WebLyricsScreen.swift")
        expectEqual(sourceHas(hubSource, "let delivery = WebLyricsVideo.deliver(isKeyFrame: frame.isKeyFrame, needsKeyFrame: entry.needsKeyFrame,"), true,
                    "网页歌词: 分发按 WebLyricsVideo.deliver 判这一帧发不发给这个网页")
        expectEqual(sourceHas(hubSource, "viewers[ObjectIdentifier(connection)] = Viewer(connection: connection, key: key,\n rate: key.video ? WebLyricsRateControl() : nil)")
                        && sourceHas(hubSource, "renderers[key]?.requestKeyFrame()"), true,
                    "网页歌词: 新网页从关键帧开始,连上就要一个关键帧")
        expectEqual(sourceHas(app("WebLyrics/WebLyricsServer.swift"),
                              "screens.add(connection, viewport: viewport, video: WebLyricsVideo.wantsVideo(request.query))"), true,
                    "网页歌词: 连接带 codec=avc 的推视频流")
        expectEqual(sourceHas(pagesSource, "if (useVideo) url.searchParams.set('codec', 'avc');")
                        && sourceHas(pagesSource, "return !(Date.now() - (Number(sessionStorage.getItem('lyrimuse.noVideo')) || 0) < NO_VIDEO_MS);")
                        && sourceHas(pagesSource, "if (performance.now() - videoSince < VIDEO_TRUST_MS) {")
                        && sourceHas(pagesSource, "useVideo = videoAllowed();\n videoSince = performance.now();"), true,
                    "网页歌词: 副屏网页能硬解就要视频流;连上就解码出错的标签页 10 分钟内改走 JPEG,用了一阵才出错的接着要视频(不记成永久的)")
        expectEqual(sourceHas(pagesSource, "decoder = new VideoDecoder({ output: (f) => { noteDecoded(f.timestamp); accept(f.timestamp / 1000, f); }, error: dropVideo });"), true,
                    "网页歌词: 解出来的视频帧跟 JPEG 进同一个按画帧时刻放的队列,解码出错退回 JPEG")
        expectEqual(sourceHas(pagesSource, "if (type !== 2 && needKey) return;"), true,
                    "网页歌词: 网页在关键帧之前不解普通帧")
        expectEqual(sourceHas(pagesSource, "if (useVideo) decodeDue(now);")
                        && sourceHas(pagesSource, "chunks.push(new EncodedVideoChunk("), true,
                    "网页歌词: 视频帧先按没解的数据排着,快到放的时候才送去解(解好的帧占着解码器输出缓冲,压多了解码器停住)")
        expectEqual(sourceHas(hubSource, "previousStillSending: !admitted || entry.connection.frameBacklogged(video: key.video))")
                        && sourceHas(hubSource, "$0.connection.frameBacklogged(video: key.video) || !($0.rate?.admits(at: now) ?? true)"), true,
                    "网页歌词: 排没排满按推法判(视频按字节排几帧,逐帧 JPEG 只排一帧);视频流超在途上限也算排满")
        expectEqual(sourceHas(hubSource, "let anyAdmitted = viewers.values.contains { $0.key == key && ($0.rate?.admits(at: now) ?? true) }")
                        && sourceHas(hubSource, "let admitted = !anyAdmitted || (entry.rate?.admits(at: now) ?? true)")
                        && sourceHas(hubSource, "viewers[id]?.rate?.noteSent(stamp: frame.stamp, bytes: frame.payloadBytes, at: now)"), true,
                    "网页歌词: 视频流超在途上限时,只在这一尺寸还有别的网页没超时丢它的帧(全都超了由出帧线程停画,参考链不断、不等关键帧),发出去的记进码率控制")
        expectEqual(sourceHas(hubSource, "refreshLead(entry.key)\n refreshBacklog(entry.key)\n guard changed else { return }"), true,
                    "网页歌词: 每次回报都重判排没排满(在途上限随回报变)")
        expectEqual(sourceHas(hubSource, "if let feedback = WebLyricsFeedback.parse(payload) {")
                        && sourceHas(hubSource, "renderers[key]?.setVideoBitRate(lowest)"), true,
                    "网页歌词: 网页回报进码率控制,编码器码率取这一尺寸网页里最低的")
        expectEqual(sourceHas(hubSource, "let longest = viewers.values.filter { $0.key == key }.compactMap { $0.rate?.displayLatency }.max()")
                        && sourceHas(pagesSource, "Math.round(performance.now() - rxAt), Math.round(delay())] }));"), true,
                    "网页歌词提前画: 网页回报放帧余量,提前量取这一尺寸网页里从画到上屏最久的")
        expectEqual(sourceHas(hubSource, "list.nowProvider = { [weak self] in PlaybackCoordinator.shared.lyricsTimelineMs() + (self?.appliedLeadMs ?? 0) }")
                        && sourceHas(hubSource, "currentLineIndex: lookahead.map(\\.index) ?? playback.currentLineIndex,")
                        && sourceHas(hubSource, "offsetMs: PlaybackCoordinator.shared.currentLyricsOffsetMs + appliedLeadMs),")
                        && sourceHas(hubSource, "?? currentPositionMs() + appliedLeadMs,"), true,
                    "网页歌词提前画: 填色时钟、当前行、填色动画的时间基准、进度条一起按提前量画")
        expectEqual(sourceHas(hubSource, "PlaybackCoordinator.shared.lyricsLookahead(leadMs: leadMs)")
                        && sourceHas(hubSource, "guard let wait = next?.nextChangeInMs else { return }"), true,
                    "网页歌词提前画: 在播时按提前量重解歌词行,并在下一次换行的时刻补一次提交")
        expectEqual(sourceHas(hubSource, "CATransaction.flush()\n if let from = pendingCutFrom {\n pendingCutFrom = nil\n onText?(WebLyricsPredictionCut.message((from, CACurrentMediaTime() * 1000 + WebLyricsPredictionCut.settleMs)))")
                        && sourceHas(pagesSource, "else if (m.type === 'cut') cut(m.from, m.t);")
                        && sourceHas(pagesSource, "if (t <= lastShown || cutOut(t)) { release(item); return; }"), true,
                    "网页歌词提前画: 暂停、跳转时通知网页,网页把押错的帧解了不放")
        expectEqual(sourceHas(pagesSource, "let jitter = remote ? START_DELAY - 16 : 0, jitterAt = performance.now(), lastArrival = 0;"), true,
                    "网页歌词: 别的设备上开的副屏余量从 300ms 起步,头一次停顿就接得住")
        expectEqual(sourceHas(pagesSource, "ws.send(JSON.stringify({ fb: [rxStamp, rxBytes, Math.round(performance.now() - rxAt),")
                        && sourceHas(pagesSource, "rxBytes += buffer.byteLength;"), true,
                    "网页歌词: 副屏网页定时回报收到的最后一帧和字节数(按消息内容数,跟 App 记的同一个数法)")
        let serverSource = app("WebLyrics/WebLyricsServer.swift")
        expectEqual(sourceHas(serverSource, "video ? pendingFrameBytes >= Self.videoQueueBytes : pendingFrames > 0")
                        && sourceHas(serverSource, "self.pendingFrames -= 1\n self.pendingFrameBytes -= bytes"), true,
                    "网页歌词: 连接按帧数和字节数记还没发完的,发完减回去")
        expectEqual(sourceHas(app("WebLyrics/WebLyricsVideoEncoder.swift"),
                              "let force = keyFrameWanted && now - lastForcedKeyFrame >= Self.minForcedKeyFrameGap\n if force {\n keyFrameWanted = false"), true,
                    "网页歌词: 关键帧请求在限频期间记着,满 1 秒那一帧补出,不作废")
        expectEqual(sourceHas(pagesSource, "if (useVideo) url.searchParams.set('codec', 'avc');\n needKey = true;\n chunks = [];"), true,
                    "网页歌词: 副屏网页重连时清空没解的视频帧、从关键帧重新开始")
        expectEqual(sourceHas(frameSource, "commandBuffer.addCompletedHandler { [weak self] _ in encodeQueue.async {"), true,
                    "网页歌词: GPU 画完只把缩放、编码转到专用串行队列(完成回调不保证串行,编码器和缓冲池不能并发用)")
        expectEqual(sourceHas(frameSource, "VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled)"), true,
                    "网页歌词: 缩尺寸在编码前用硬件缩放,渲染照旧按原尺寸")
        expectEqual(sourceHas(frameSource, "minResolution: 1 / viewport.scale"), true,
                    "网页歌词: 编码尺寸最多缩到 1 倍像素")
        let motionSource = app("WebLyrics/WebLyricsMotionCover.swift")
        expectEqual(sourceBytes(motionSource, contain: "AVPlayerLooper("), false,
                    "网页歌词: 动态封面不用 AVPlayerLooper(挂在它那几份副本上的视频输出一帧都取不到)")
        expectEqual(sourceHas(motionSource, "item.add(output)") && sourceHas(motionSource, "player.insert(item, after: nil)"), true,
                    "网页歌词: 动态封面自己排队、每份播放项挂自己的视频输出")
        expectEqual(sourceHas(motionSource, "layer.contents = surface"), true,
                    "网页歌词: 动态封面把视频帧的 IOSurface 贴成图层内容(离屏渲染画不进 AVPlayerLayer)")
        expectEqual(sourceHas(frameSource, "prepare()\n let started = CACurrentMediaTime()"), true,
                    "网页歌词: 出帧线程每拍开画前先取动态封面那一帧")
        expectEqual(sourceHas(frameSource, "motion.update(file: next.controls.reduceMotion ? nil : next.motionFile, playing: next.motionPlaying)"), true,
                    "网页歌词: 左栏动态封面跟歌词窗口一样认减弱动态效果")
        expectEqual(sourceHas(frameSource, "motionPlaying: playback.isPlayingSmoothed && viewersVisible"), true,
                    "网页歌词: 动态封面只在放歌、有网页看着时动")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "coverHost.frame ="), false,
                    "网页歌词: 封面卡带缩放变换,不能设 frame(会按缩放反算 bounds,继续播放时封面变大)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "layer.frame = Self.timeFrame(in: slot)")
                        && sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "elapsedLayer.frame = Self.timeFrame(in: elapsedSlot)")
                        && !sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "frame: elapsedLayer.frame"), true,
                    "网页歌词: 进度时间布局和更新都从固定格子算位置(拿图层自己的 frame 当基准,重排时两个时间上下跳)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsChrome.swift"), contain: "4 + max(value?.size.width ?? 0, widestValue)")
                        && sourceBytes(app("WebLyrics/WebLyricsChrome.swift"), contain: "4 + widestButtons + 10 + 6)"), true,
                    "网页歌词: 「…」菜单宽度按出现「重置」、数值最长时留足(偏移一变就变宽的话 ± 跟着右移,连点「＋」落空)")
        expectEqual(sourceHas(app("WebLyrics/WebLyricsObsFeed.swift"), "if subs.isEmpty { subscribe() }\n        clients[ObjectIdentifier(connection)] = connection"), true,
                    "网页歌词: OBS 第一条连接先订阅再登记(登记在前会把样式、整首歌词、位置各收两份)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "moved: false, seeks: chromeShown)")
                        && sourceBytes(app("WebLyrics/WebLyricsScreen.swift"), contain: "if !moved, seeks { seekToLine(at: p) }"), true,
                    "网页歌词: 控件收着时点歌词只唤出控件、不跳转(触屏上本想点一下叫出控件,会把歌跳走)")
        expectEqual(sourceBytes(app("WebLyrics/WebLyricsScreen.swift"),
                                contain: "private var coverWidth: CGFloat { max(80, min(width * 0.279, 460, height - 216)) }"), true,
                    "网页歌词: 封面边长另按高度封顶(手机横放时左栏整组放不下,封面上缘出画)")
        let chromeSource = app("WebLyrics/WebLyricsChrome.swift")
        expectEqual(chromeSource.components(separatedBy: "panel.frame = panelFrame(width: width, height: height, anchor: anchor, in: s)").count - 1,
                    4, "网页歌词: 「…」菜单和三种面板都按 panelFrame 摆(竖排时「…」在顶上,上方放不下要挂到下方、右边要收回画面)")
        expectEqual(sourceBytes(chromeSource, contain: "let y = above >= top ? above : (below + height <= bottom ? below : top)"), true,
                    "网页歌词: 面板上方放不下时挂在「…」下方")
        expectEqual(sourceBytes(chromeSource, contain: "y: 8 + CGFloat(s.safeArea.top)")
                        && sourceBytes(chromeSource, contain: "(s.bottomInset > 0 ? s.bottomInset : CGFloat(s.safeArea.bottom))")
                        && sourceBytes(chromeSource, contain: "let top = 8 + CGFloat(s.safeArea.top), bottom = s.size.height - 8 - CGFloat(s.safeArea.bottom)"), true,
                    "网页歌词: 音量胶囊、右下一排、菜单都让开安全区")
        let paneSource = app("WebLyrics/WebLyricsScreen.swift")
        expectEqual(sourceBytes(paneSource, contain: "top = Self.compactTop + CGFloat(safe.top)")
                        && sourceBytes(paneSource, contain: "y: bounds.height - max(margin, CGFloat(safe.bottom)) - panelHeight")
                        && sourceBytes(paneSource, contain: "let top = WebLyricsPlayerPane.compactHeaderBottom + safeTop + 12")
                        && sourceBytes(paneSource, contain: "y: Self.stackedTop + safeTop,"), true,
                    "网页歌词: 手机顶上一行、歌词起点、底部播放条和平板竖放顶上那一块从安全区量起")
        expectEqual(sourceBytes(paneSource, contain: "guard pane.transportInteractive else { return nil }")
                        && sourceBytes(paneSource, contain: "pane.transportAbsorbs(CGPoint(x: p.x - paneRect.minX, y: p.y - paneRect.minY))")
                        && sourceBytes(paneSource, contain: "pane.setTransportVisible(chromeVisible, animated: true)"), true,
                    "网页歌词: 手机底部播放条跟着控件闲置收起;收着时点那里只唤出控件,露着时点空白处不落到歌词上跳句")
        expectEqual(sourceBytes(paneSource, contain: "list.frame = wrapperFrame(listFrame)")
                        && sourceBytes(paneSource, contain: "pane.frame = wrapperFrame(paneRect)"), true,
                    "网页歌词: 竖排时设给外层画布的 frame 要上下翻一次(外层 y 向上),命中仍按 y 向下的框")
        expectEqual(sourceBytes(app("UI/LyricsLayerList.swift"), contain: "r.layer.shouldRasterize = d != 0"), true,
                    "网页歌词: 离屏时不在唱的行缓存成位图(每个逐字遮罩都是主线程上的一趟绘制)")
        expectEqual(sourceBytes(app("UI/LyricsLayerList.swift"), contain: "v.rendersDetached = rendersDetached"), true,
                    "网页歌词: 歌词列表把离屏开关传给间奏点")
        let screen = app("WebLyrics/WebLyricsScreen.swift")
        expectEqual(sourceBytes(screen, contain: "list.rendersDetached = true"), true, "网页歌词: 副屏那份歌词列表标成离屏")
        expectEqual(sourceBytes(screen, contain: "DetachedLayerTree.assemble(list)"), true, "网页歌词: 每帧给歌词列表拼树")
    }
}
