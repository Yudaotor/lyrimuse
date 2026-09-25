import AppKit
import OSLog

/// 主线程卡顿探测(临时诊断,排查完就删)。
///
/// 60Hz 在主 runloop 上打点,两次打点间隔超过阈值就记一条。探测器自己就跑在主线程上,
/// 所以"没被按时叫到"等价于"主线程这段时间在忙别的"——正是悬浮歌词/灵动岛/菜单栏/
/// 歌词窗口一起停的那一下。它只回答"什么时候、卡了多久";是谁干的靠逐个关掉展示面去夹。
@MainActor
enum MainThreadStallProbe {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "stall")
    private static let tickInterval: TimeInterval = 1.0 / 60
    /// 打点自身是 60Hz,基线间隔就是 16.7ms;25ms 相当于"被别的活挤掉了一帧多",
    /// 再低就分不清定时器自身的抖动了。
    private static let threshold: TimeInterval = 0.025
    private static var lastTick = CFAbsoluteTimeGetCurrent()
    private static var timer: Timer?

    static func start() {
        guard timer == nil else { return }
        lastTick = CFAbsoluteTimeGetCurrent()
        // .common 模式:菜单打开、拖窗口期间照样要测 —— 那几种情况本来就是卡顿高发区。
        let t = Timer(timeInterval: tickInterval, repeats: true) { _ in
            // Timer 挂在 RunLoop.main 上,回调必然在主线程;assumeIsolated 免掉一次
            // Task 跳板 —— 跳板本身会引入调度延迟,把要测的东西搅进测量里。
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                let gap = now - lastTick
                lastTick = now
                guard gap > threshold else { return }
                logger.notice("main stall \(gap * 1000, format: .fixed(precision: 1))ms")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
