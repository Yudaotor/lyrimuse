import Foundation

/// 实测帧率取样器 —— 挂在既有的逐字填色 `TimelineView` 闭包里，量「SwiftUI 实际多久给我们
/// 一帧」。
///
/// 为什么需要它:这个项目最贵的两个渲染结论都是靠一次性搭的外部探针量出来的 ——
/// 07 章 #13「macOS 对这类长时程慢动画只以 ~20Hz 提交」(ScreenCaptureKit 逐帧探针)、
/// 04 章 #2 的 30Hz 上限(那次还漏掉了悬浮窗整整一天)。量完探针就没了,07 章因此写着
/// 「将来重试排程式填色,先用 SCK 探针核实提交频率再谈」。更要命的是**用户机器上无法
/// 取证**:报"歌词卡顿"时,没有任何一项能区分"帧率掉了"和"位置读数在抖"。
///
/// 成本:闭包本来就每帧在跑,这里只多一次减法和一次乘加,没有新的定时器、没有新的订阅。
/// 只在隐藏开关打开时才被调用(见 `AppSettings.debugHUDEnabled`)。
///
/// 纯值类型放在 Core 里而不是塞进 View:这样它能被 selftest 无屏覆盖 —— 跟 `KaraokeFill`
/// / `MarqueeMath` 拆出来的理由一样(那几个的文件头写了同一句)。
public struct FrameRateProbe {
    /// 指数滑动平均的权重。0.1 = 大约十帧的记忆:够平滑到读得出来,又不至于掉帧时半天不动。
    public static let smoothing = 0.1
    /// 认为"这一帧跟上一帧不连续"的间隔上限。超过就重新起算 —— 暂停/切窗/停表之后
    /// TimelineView 会隔很久才给下一帧,把那个间隔算进平均值会让读数长时间失真。
    public static let discontinuityThreshold: TimeInterval = 1.0

    private var lastFrameAt: Date?
    private(set) public var smoothedInterval: TimeInterval?

    public init() {}

    /// 实测帧率。还没攒够样本时返回 nil。
    public var fps: Double? {
        guard let interval = smoothedInterval, interval > 0 else { return nil }
        return 1 / interval
    }

    /// 每帧调一次。返回自身是为了让调用方能在 `@State` 上原地更新(struct 值语义)。
    public mutating func tick(at now: Date) {
        defer { lastFrameAt = now }
        guard let last = lastFrameAt else { return }
        let delta = now.timeIntervalSince(last)
        // 非正的间隔(同一帧被调两次/时钟回拨)直接丢弃,别让它污染平均值。
        guard delta > 0 else { return }
        guard delta <= Self.discontinuityThreshold else {
            smoothedInterval = nil
            return
        }
        guard let current = smoothedInterval else {
            smoothedInterval = delta
            return
        }
        smoothedInterval = current + (delta - current) * Self.smoothing
    }
}
