import Foundation

/// 网页每隔一会儿回报的收帧情况(视频流):收到的最后一帧的画帧时刻、连上以来收到的消息内容字节数(不含 WebSocket
/// 帧头)、最后一帧到了多久、此刻的放帧余量(比最快那次到达晚放多久)。消息形如 `{"fb":[画帧时刻毫秒, 字节数, 毫秒, 毫秒]}`,
/// 余量那一项可以没有。
public struct WebLyricsFeedback: Equatable, Sendable {
    public let stamp: Double
    public let receivedBytes: Int
    public let sinceArrival: TimeInterval
    public let delay: TimeInterval?

    public init(stamp: Double, receivedBytes: Int, sinceArrival: TimeInterval, delay: TimeInterval? = nil) {
        self.stamp = stamp
        self.receivedBytes = receivedBytes
        self.sinceArrival = sinceArrival
        self.delay = delay
    }

    public static func parse(_ payload: Data) -> WebLyricsFeedback? {
        guard payload.count <= 128,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let values = object["fb"] as? [NSNumber], values.count == 3 || values.count == 4 else { return nil }
        let stamp = values[0].doubleValue, bytes = values[1].doubleValue, since = values[2].doubleValue
        guard stamp.isFinite, bytes.isFinite, bytes >= 0, since.isFinite, since >= 0 else { return nil }
        var delay: TimeInterval?
        if values.count == 4 {
            let ms = values[3].doubleValue
            guard ms.isFinite, ms >= 0 else { return nil }
            delay = ms / 1000
        }
        return WebLyricsFeedback(stamp: stamp, receivedBytes: Int(bytes), sinceArrival: since / 1000, delay: delay)
    }
}

/// 副屏视频流对一个网页的码率控制和在途上限。服务端交给连接的帧先进内核发送缓冲,慢网上那里能自动长到几 MB,
/// 「发完」回调照来,看不出排队;所以按网页回报算:回报的那一帧从交出去到网页收到用了多久(扣掉回报本身晚了多少),
/// 减去连上以来最快的那次(每秒允许上浮 2ms,路由变了也跟得上),就是在路上排队的时间。
///
/// - 连着两次回报(不同的帧)排队都超过 `overuseDelay`、而且没在回落:码率降到 0.85 倍,上一秒实际送达的更少时按它的
///   0.85 倍,排队越长再往下压(积压一两秒内排得完),一次最多降到 0.3 倍;1 秒内只降一次。停顿过后积压的帧一下子
///   涌到、排队很快回落,不降:只是停了一下,路没变窄,靠网页的放帧余量扛。
/// - `bitRate` 是想要的线上码率;硬件编码器常比设的多发三到五成(开头关键帧更多),所以按上一秒实际发出与设给它的
///   比值(只认大于 1 的)折算,设给编码器的是 `encoderBitRate`。
/// - 从 `startBitRate` 起步,第一次发不完之前每次回报升 25%,好路上一秒多升满;起步高了窄路上开头先灌出一两秒积压。
/// - 排队回到 `calmDelay` 以下、离上次降已过 1 秒、编码器确实用满了码率(上一秒发出去的不少于六成):每次回报升 5%;
///   离上次发不完时的送达量只差一成上下时只升 1%,不在容量上下猛试。
/// - 在途上限,超了先不发,内核缓冲再大延迟也封顶:网页还没收到的数据里最早那一帧交出去已超过 `maxInFlightAge`,或者
///   在途字节超过「上一秒送达量与目标码率里大的那个」发 `maxInFlightAge` 的量(只限年龄的话,发得比路快几倍时积压是
///   年龄的几倍)。字节上限别只按送达量:送达量取决于自己发了多少,限住了送达量就低、上限跟着更低,越限越死。
///
/// 纯逻辑,时间由调用方传入。见 19 章决策 27。
public struct WebLyricsRateControl: Sendable {
    public static let maxBitRate = 4_000_000
    public static let minBitRate = 150_000
    public static let startBitRate = 1_000_000
    static let overuseDelay: TimeInterval = 0.2
    static let calmDelay: TimeInterval = 0.08
    /// 两次回报之间排队少了这么多以上算在回落。
    static let drainSlack: TimeInterval = 0.05
    static let decreaseGap: TimeInterval = 1
    static let increaseStep = 1.05
    static let startIncreaseStep = 1.25
    static let nearIncreaseStep = 1.01
    static let baseDrift: TimeInterval = 0.002
    static let rateWindow: TimeInterval = 1
    static let sentWindow: TimeInterval = 10
    /// 网页放帧余量最多 2 秒(`screenPage` 的 MAX_VIDEO_DELAY),停一两秒的帧照样排着送过去、由余量接住,比丢帧等关键帧好。
    static let maxInFlightAge: TimeInterval = 2.5

    public private(set) var bitRate: Int
    /// 设给编码器的码率:`bitRate` 按编码器超发的比例折算。
    public private(set) var encoderBitRate: Int
    /// 最近一次算出来的排队时间,写进诊断日志。
    public private(set) var queueDelay: TimeInterval = 0
    /// 一帧从开画到在网页上屏大约多久:交给连接前的耗时(近 10 秒最短的)+ 基准往返的一半 + 网页报的放帧余量
    /// + 半个刷新间隔。网页没报余量时 nil。副屏按它提前画。
    public private(set) var displayLatency: TimeInterval?

    private var sent: [(stamp: Double, at: TimeInterval, total: Int)] = []
    private var sentTotal = 0
    private var receivedTotal = 0
    private var received: [(at: TimeInterval, bytes: Int)] = []
    private var base: (trip: TimeInterval, at: TimeInterval)?
    private var lastDecrease: TimeInterval = -.infinity
    private var lastReportedStamp: Double?
    /// 上次发不完时网页实际收到的码率。
    private var overuseRate: Double?
    /// 编码器实际发出与设给它的码率之比(指数平均,不小于 1)。
    private var overshoot = 1.0

    public init(bitRate: Int = startBitRate) {
        self.bitRate = min(Self.maxBitRate, max(Self.minBitRate, bitRate))
        encoderBitRate = self.bitRate
    }

    /// 这一刻再交帧给这条连接会不会超过在途上限。
    public func admits(at now: TimeInterval) -> Bool {
        guard let oldest = sent.first(where: { $0.total > receivedTotal }) else { return sentTotal <= receivedTotal }
        let rate = max(deliveredBitRate(at: now) ?? 0, Double(bitRate))
        return now - oldest.at <= Self.maxInFlightAge && Double(sentTotal - receivedTotal) <= rate / 8 * Self.maxInFlightAge
    }

    /// 一帧(消息内容字节数,不含帧头)交给了这条连接。同一画帧时刻的(关键帧前的解码配置)记在一起。
    public mutating func noteSent(stamp: Double, bytes: Int, at now: TimeInterval) {
        sentTotal += bytes
        if let last = sent.last, last.stamp == stamp {
            sent[sent.count - 1].total = sentTotal
        } else {
            sent.append((stamp, now, sentTotal))
        }
        if let drop = sent.firstIndex(where: { $0.at >= now - Self.sentWindow }), drop > 0 { sent.removeFirst(drop) }
    }

    /// 网页的一次回报。设给编码器的码率变了返回 true。
    public mutating func noteFeedback(_ feedback: WebLyricsFeedback, at now: TimeInterval) -> Bool {
        receivedTotal = max(receivedTotal, feedback.receivedBytes)
        received.append((now, receivedTotal))
        if let drop = received.firstIndex(where: { $0.at >= now - Self.rateWindow * 1.5 }), drop > 0 { received.removeFirst(drop) }
        guard let frame = sent.last(where: { $0.stamp <= feedback.stamp }), frame.stamp == feedback.stamp else { return false }
        let trip = max(0, now - feedback.sinceArrival - frame.at)
        let floor = base.map { $0.trip + ($0.at.distance(to: now)) * Self.baseDrift } ?? trip
        if trip <= floor { base = (trip, now) }
        let previous = queueDelay
        queueDelay = max(0, trip - min(floor, trip))
        if let delay = feedback.delay, let base {
            let handoff = max(0, sent.map { $0.at - $0.stamp / 1000 }.min() ?? 0)
            displayLatency = handoff + base.trip / 2 + delay + 1.0 / 120
        }
        guard frame.stamp != lastReportedStamp else { return false }
        lastReportedStamp = frame.stamp
        let before = encoderBitRate
        let delivered = deliveredBitRate(at: now)
        if let first = sent.first, now - first.at >= Self.rateWindow {
            let ratio = max(1, sentBitRate(at: now) / Double(encoderBitRate))
            overshoot = min(3, overshoot + (ratio - overshoot) * 0.2)
        }
        if queueDelay > Self.overuseDelay, previous > Self.overuseDelay, queueDelay >= previous - Self.drainSlack,
           now - lastDecrease >= Self.decreaseGap {
            var next = Double(bitRate) * 0.85
            if let delivered {
                let drain = min(1, max(0.4, 1 - (queueDelay - Self.overuseDelay) / 2))
                next = min(next, delivered * 0.85 * drain)
            }
            bitRate = Int(max(Double(Self.minBitRate), max(next, Double(bitRate) * 0.3)))
            lastDecrease = now
            overuseRate = delivered
        } else if queueDelay < Self.calmDelay, now - lastDecrease >= Self.decreaseGap,
                  sentBitRate(at: now) >= Double(bitRate) * 0.6 {
            let step: Double
            if let overuseRate {
                let near = Double(bitRate) * Self.increaseStep > overuseRate * 0.9 && Double(bitRate) < overuseRate * 1.2
                step = near ? Self.nearIncreaseStep : Self.increaseStep
            } else {
                step = lastDecrease == -.infinity ? Self.startIncreaseStep : Self.increaseStep
            }
            bitRate = min(Self.maxBitRate, Int(Double(bitRate) * step))
        }
        encoderBitRate = max(Self.minBitRate, Int(Double(bitRate) / overshoot))
        return encoderBitRate != before
    }

    /// 上一秒网页实际收到的码率;回报不够一秒时 nil。
    private func deliveredBitRate(at now: TimeInterval) -> Double? {
        guard let first = received.first(where: { $0.at >= now - Self.rateWindow * 1.5 }),
              let last = received.last, last.at - first.at >= Self.rateWindow * 0.8 else { return nil }
        return Double(last.bytes - first.bytes) * 8 / (last.at - first.at)
    }

    /// 上一秒实际发出去的码率,写进诊断日志。
    public func sentBitRate(at now: TimeInterval) -> Double {
        guard let start = sent.last(where: { $0.at < now - Self.rateWindow }) else {
            // 连上还不满一秒:按实际经过的时间算,别按一秒摊薄(起步那几次回报会被当成编码器没用满码率、不升)
            let elapsed = max(0.2, now - (sent.first?.at ?? now))
            return Double(sentTotal) * 8 / min(elapsed, Self.rateWindow)
        }
        return Double(sentTotal - start.total) * 8 / Self.rateWindow
    }
}
