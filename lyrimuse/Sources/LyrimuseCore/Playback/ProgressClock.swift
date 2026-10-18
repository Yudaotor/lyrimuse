import Foundation

// 进度外推:锚点(progressMs)不会每一拍都刷新,真实位置 = progressMs + 锚点年龄(ms) * rate,
// 不限龄,夹在 [0, durationMs]。
public struct ProgressAnchor {
    public let durationMs: Int
    public let progressMs: Int
    public let rate: Double
    public let progressTs: Int?   // 服务器锚点的 epoch 毫秒;没有 ageMs 时的兜底基准
    public let baseAgeMs: Int?    // 服务器算好的锚点年龄(Cloudflare 时钟,不受本机时钟偏差影响)
    public let fetchedAt: Date    // 本机收到这份数据的时刻
    /// 暂停类通知先到、把外推冻在那一刻(rate 0),下一次轮询才知道是不是真停了。rate 0 本身不能当这个信号:
    /// 播放器没报速率时锚点也是 0,别处都按 1 倍速算。
    public let isFrozen: Bool

    public init(durationMs: Int, progressMs: Int, rate: Double, progressTs: Int?, baseAgeMs: Int?, fetchedAt: Date,
                isFrozen: Bool = false) {
        self.durationMs = durationMs
        self.progressMs = progressMs
        self.rate = rate
        self.progressTs = progressTs
        self.baseAgeMs = baseAgeMs
        self.fetchedAt = fetchedAt
        self.isFrozen = isFrozen
    }

    // from(_ state: NowPlayingState, fetchedAt:) 工厂方法已删:它与
    // NowPlayingState/NowPlayingClient 是远程模式的遗留,全仓零调用方,一起清掉。
    // 本地模式的锚点由 LocalPlaybackSource 直接用 memberwise init 构造。

    public func extrapolatedPositionMs(now: Date = Date()) -> Int {
        let ageMs: Double
        if let base = baseAgeMs {
            // 服务器锚点年龄 + 本设备收到后走过的相对时间——只用本机时钟的相对差,
            // 不看绝对时钟,消除跨设备时钟偏差。
            ageMs = Double(base) + now.timeIntervalSince(fetchedAt) * 1000
        } else if let ts = progressTs {
            // 没有 ageMs(比如 LB 直连兜底)才退回本机绝对时钟跟服务器时间戳比较。
            ageMs = now.timeIntervalSince1970 * 1000 - Double(ts)
        } else {
            ageMs = 0
        }
        var pos = Double(progressMs)
        if rate > 0, ageMs > 0 {
            pos += ageMs * rate
        }
        pos = max(0, min(Double(durationMs), pos))
        return Int(pos)
    }
}
