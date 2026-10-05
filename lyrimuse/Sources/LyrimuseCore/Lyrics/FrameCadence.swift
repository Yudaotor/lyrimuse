import Foundation

/// 逐帧时钟的节流判据:离上一次刷新够不够 `minimumInterval`。按帧的目标时刻比,留 `tolerance` 的余量 ——
/// 帧间隔有抖动,`minimumInterval` 恰好等于帧长(60Hz 屏上的 1/60)时不留余量会隔一帧才刷一次。
public enum FrameCadence {
    public static let tolerance: Double = 0.002

    public static func isDue(sinceLast elapsed: Double, minimumInterval: Double) -> Bool {
        elapsed >= minimumInterval - tolerance
    }
}

/// 主线程卡住、display link 漏掉帧时,过渡动画(歌词窗口的换句错开、景深、滚动指示条)的时间轴要扣掉多少:卡住那段
/// 不算进度,卡完从原处接着走,不一步跳过漏掉的几帧(07 章决策 108)。
public enum FrameStall {
    /// 两帧的目标时刻隔得超过帧长的这么多倍、又长于 `minimumGapSeconds`,才算卡住。按一倍半判的话,自适应刷新率的屏
    /// 从 120Hz 降到 60Hz 跑时每一帧都算卡住,过渡慢一半;偶尔掉一帧也不该算。
    public static let thresholdFrames = 2.5
    public static let minimumGapSeconds = 0.03
    /// 空档长过这个不算卡顿(窗口被盖住、系统睡眠、主线程卡死),过渡照真实时间走,免得滚动明显落后于演唱。
    public static let maximumGapSeconds = 0.25

    /// 这一帧的目标时刻离上一帧 `gap` 秒、帧长 `frame` 秒:漏掉的时长(多出一帧的那段),没卡住时 0。
    public static func missedSeconds(gap: Double, frame: Double) -> Double {
        guard frame > 0, gap > frame * thresholdFrames, gap > minimumGapSeconds, gap <= maximumGapSeconds else { return 0 }
        return gap - frame
    }
}
