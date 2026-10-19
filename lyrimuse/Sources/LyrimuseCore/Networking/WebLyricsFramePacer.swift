import Foundation

/// 出帧的一档:节拍间隔、JPEG 质量、编码前缩到渲染尺寸的几分之几。
public struct WebLyricsFrameStep: Equatable, Sendable {
    public let interval: TimeInterval
    public let quality: Double
    public let resolution: Double

    public init(interval: TimeInterval, quality: Double, resolution: Double) {
        self.interval = interval
        self.quality = quality
        self.resolution = resolution
    }
}

/// 这一拍为什么没画:在途的帧已满(GPU / 编码器忙不过来),或者这一尺寸的网页上一帧都还没发完(网络发不完)。
public enum WebLyricsFrameSkip: Sendable {
    case none
    case inFlight
    case backlog
}

/// 网页歌词副屏在播时的出帧档位,挑一档这台机器、这条网络撑得住的匀速节拍,先省字节、再降帧率。
///
/// 档位从高到低:60 帧原质量原尺寸 → 降 JPEG 质量 → 编码前缩到 0.75、0.5(不低于 1 倍像素)→ 30 / 20 / 15 帧。
/// 带宽不够时少发字节比少发帧流畅得多:Wi-Fi 上一帧 300KB 只够十来帧,缩到一半尺寸约 110KB。
///
/// 每秒结一次账:跳拍超过一成,或者画一帧交给 GPU 的那段就超过一拍,当场降档。降到哪一档看原因:网络发不完一档档降;
/// 跳拍主要是在途帧满(GPU、编码器忙不过来),只降质量没用,落到缩尺寸或改节拍的那一档;画一帧交给 GPU 那段(CPU)
/// 就超过一拍,缩尺寸也省不了(照旧按原尺寸画,编码前才缩),直接落到下一个帧率档。降档只认实际跳拍:开画到 JPEG 编完是延迟,不是吞吐
/// (几帧可以同时在编),拿它摊算会把跑得动 60 帧的机器也压下去。连续 `calmWindowsToRaise` 秒一拍没跳、开画到编完
/// 按在途帧数摊开也赶得上高一档的间隔,才升一档;升上去几秒内又跳拍,下次要等的秒数翻倍,最多
/// `maxCalmWindowsToRaise`,不在两档之间来回切;升上去撑过几秒没降回来,等的秒数回到起点。纯逻辑,时间由调用方传入。见 19 章决策 22、24、26。
public struct WebLyricsFramePacer: Sendable {
    public static let fullQuality = 0.75
    public static let reducedQuality = 0.55
    /// 档位全表(从高到低);每个尺寸各用自己的那份,缩到不足 1 倍像素的档按 `minResolution` 合并掉。
    public static let ladder: [WebLyricsFrameStep] = [
        .init(interval: 1.0 / 60, quality: fullQuality, resolution: 1),
        .init(interval: 1.0 / 60, quality: reducedQuality, resolution: 1),
        .init(interval: 1.0 / 60, quality: reducedQuality, resolution: 0.75),
        .init(interval: 1.0 / 60, quality: reducedQuality, resolution: 0.5),
        .init(interval: 1.0 / 30, quality: reducedQuality, resolution: 0.5),
        .init(interval: 1.0 / 20, quality: reducedQuality, resolution: 0.5),
        .init(interval: 1.0 / 15, quality: reducedQuality, resolution: 0.5),
    ]
    static let window: TimeInterval = 1
    static let skipRatioToLower = 0.1
    static let calmWindowsToRaise = 3
    static let maxCalmWindowsToRaise = 24
    /// 升档后这么多秒内又降回来,算这一档撑不住。
    static let relapseWindows = 5
    /// 两种耗时的指数平均系数。
    static let smoothing = 0.2

    /// 这个尺寸实际用的档位(从高到低)。
    public let steps: [WebLyricsFrameStep]
    public private(set) var level = 0
    public var step: WebLyricsFrameStep { steps[level] }
    public var interval: TimeInterval { step.interval }

    private let framesInFlight: Int
    /// 网络发不完的跳拍算不算数。视频流不算:码率按网页回报另控(`WebLyricsRateControl`),降帧率省不了码率。
    private let countsBacklog: Bool
    private var windowStart: TimeInterval?
    private var ticks = 0
    private var inFlightSkips = 0
    private var backlogSkips = 0
    private var calmWindows = 0
    private var calmNeeded = calmWindowsToRaise
    /// 刚开始在播(建好、或暂停后恢复)的头一秒只记账不降档:编码器头几帧慢、网页刚连上,那一秒的跳拍不代表撑不住。
    private var warmingUp = true
    /// 上次升档之后结了几次账;没升过时为 nil。
    private var windowsSinceRaise: Int?
    /// 两种耗时(指数平均)和上一次结账时跳拍的比例,换档时写进诊断日志。
    public private(set) var drawCost: TimeInterval = 0
    public private(set) var pipelineCost: TimeInterval = 0
    public private(set) var lastSkipRatio = 0.0

    /// - Parameter minResolution: 编码尺寸最多缩到渲染尺寸的几分之几,让像素倍数不低于 1(2 倍像素的网页是 0.5,1 倍的是 1)。
    public init(maxFramesInFlight: Int, minResolution: Double = 0.5, countsBacklog: Bool = true) {
        framesInFlight = max(1, maxFramesInFlight)
        self.countsBacklog = countsBacklog
        let floor = min(1, max(minResolution, 0.01))
        var made: [WebLyricsFrameStep] = []
        for s in Self.ladder {
            let step = WebLyricsFrameStep(interval: s.interval, quality: s.quality, resolution: max(s.resolution, floor))
            if made.last != step { made.append(step) }
        }
        steps = made
    }

    /// 升到 `faster` 那一档时两种耗时都赶得上。
    private func keepsUp(with faster: TimeInterval) -> Bool {
        drawCost <= faster && pipelineCost / Double(framesInFlight) <= faster
    }

    /// 画一帧交给 GPU 的那段(出帧线程上的 CPU 耗时)。
    public mutating func noteDraw(_ seconds: TimeInterval) {
        drawCost = Self.smoothed(drawCost, seconds)
    }

    /// 一帧从开画到 JPEG 编完。
    public mutating func noteEncoded(pipeline seconds: TimeInterval) {
        pipelineCost = Self.smoothed(pipelineCost, seconds)
    }

    /// 在播时每一拍报一次。返回档位有没有变,变了调用方按新的 `step` 重排节拍、换编码质量和尺寸。
    public mutating func tick(at now: TimeInterval, skipped skip: WebLyricsFrameSkip) -> Bool {
        guard let start = windowStart else {
            windowStart = now
            ticks = 1
            count(skip)
            return false
        }
        ticks += 1
        count(skip)
        guard now - start >= Self.window else { return false }
        let skipped = inFlightSkips + backlogSkips
        let skipRatio = Double(skipped) / Double(ticks)
        lastSkipRatio = skipRatio
        if warmingUp {
            warmingUp = false
            windowStart = now
            ticks = 0
            inFlightSkips = 0
            backlogSkips = 0
            return false
        }
        let machineBound = drawCost > interval
        let tooSlow = skipRatio > Self.skipRatioToLower || machineBound
        let before = level
        if let n = windowsSinceRaise {
            windowsSinceRaise = n + 1
            // 升上去撑过了这几秒没降回来:网络或机器缓过来了,升档要等的秒数回到起点
            if n + 1 > Self.relapseWindows { calmNeeded = Self.calmWindowsToRaise }
        }
        if tooSlow {
            calmWindows = 0
            if let n = windowsSinceRaise, n <= Self.relapseWindows {
                calmNeeded = min(calmNeeded * 2, Self.maxCalmWindowsToRaise)
            }
            windowsSinceRaise = nil
            level = lowered(drawBound: machineBound, workBound: inFlightSkips > backlogSkips)
        } else if skipped == 0, level > 0, keepsUp(with: steps[level - 1].interval) {
            calmWindows += 1
            if calmWindows >= calmNeeded {
                calmWindows = 0
                windowsSinceRaise = 0
                level -= 1
            }
        } else {
            calmWindows = 0
        }
        windowStart = now
        ticks = 0
        inFlightSkips = 0
        backlogSkips = 0
        return level != before
    }

    /// 离开在播节拍(暂停、停播、网页都看不见)时清掉这一秒的账,档位和耗时留着:机器的能耐不会因为暂停变。
    public mutating func resetWindow() {
        windowStart = nil
        warmingUp = true
        ticks = 0
        inFlightSkips = 0
        backlogSkips = 0
        calmWindows = 0
    }

    private mutating func count(_ skip: WebLyricsFrameSkip) {
        switch skip {
        case .none: break
        case .inFlight: inFlightSkips += 1
        case .backlog: if countsBacklog { backlogSkips += 1 }
        }
    }

    /// 降一档。`drawBound`(CPU 那段超过一拍)落到下一个帧率档;`workBound`(在途帧满)跳过只降质量的档,落到改尺寸
    /// 或改节拍的那一档;都不是(网络发不完)降一档。
    private func lowered(drawBound: Bool, workBound: Bool) -> Int {
        guard level < steps.count - 1 else { return level }
        guard drawBound || workBound else { return level + 1 }
        let current = steps[level]
        for i in (level + 1)..<steps.count
        where steps[i].interval != current.interval || (!drawBound && steps[i].resolution != current.resolution) {
            return i
        }
        return steps.count - 1
    }

    private static func smoothed(_ old: TimeInterval, _ sample: TimeInterval) -> TimeInterval {
        old == 0 ? sample : old + (sample - old) * smoothing
    }
}
