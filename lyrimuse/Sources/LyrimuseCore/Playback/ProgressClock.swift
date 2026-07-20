import Foundation

// 进度外推,算法照抄 web/index.html 的 frame():连续播放时服务端锚点(progressMs/
// progressTs)不会每次都刷新,真实位置 = progressMs + 锚点年龄(ms) * rate。
// kv 锚点(采集器直推、准确)不限龄外推;lb 兜底锚点可能陈旧,封顶 90s 防止冲过头。
public struct ProgressAnchor {
    public let durationMs: Int
    public let progressMs: Int
    public let rate: Double
    public let progressTs: Int?   // 服务器锚点的 epoch 毫秒;没有 ageMs 时的兜底基准
    public let baseAgeMs: Int?    // 服务器算好的锚点年龄(Cloudflare 时钟,不受本机时钟偏差影响)
    public let fetchedAt: Date    // 本机收到这份数据的时刻
    public let fresh: Bool        // true = 来自 KV(采集器直推,准确)→ 不限龄外推

    public init(durationMs: Int, progressMs: Int, rate: Double, progressTs: Int?, baseAgeMs: Int?, fetchedAt: Date, fresh: Bool) {
        self.durationMs = durationMs
        self.progressMs = progressMs
        self.rate = rate
        self.progressTs = progressTs
        self.baseAgeMs = baseAgeMs
        self.fetchedAt = fetchedAt
        self.fresh = fresh
    }

    // 只在"当前正在播放、且有时长/进度可外推"时才构造锚点,否则(暂停/无数据)返回 nil。
    public static func from(_ state: NowPlayingState, fetchedAt: Date) -> ProgressAnchor? {
        guard state.playing == true,
              let duration = state.durationMs, duration > 0,
              let progressMs = state.progressMs else { return nil }
        return ProgressAnchor(
            durationMs: duration,
            progressMs: progressMs,
            rate: state.rate ?? 1,
            progressTs: state.progressTs,
            baseAgeMs: state.ageMs,
            fetchedAt: fetchedAt,
            fresh: state.source == "kv"
        )
    }

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
        let cap: Double = fresh ? .infinity : 90000
        var pos = Double(progressMs)
        if rate > 0, ageMs > 0, ageMs < cap {
            pos += ageMs * rate
        }
        pos = max(0, min(Double(durationMs), pos))
        return Int(pos)
    }
}
