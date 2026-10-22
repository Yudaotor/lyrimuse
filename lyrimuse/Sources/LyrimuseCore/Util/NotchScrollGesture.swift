import Foundation

/// 灵动岛卡片上的触控板手势:两指左右滑切歌,上下滑调系统音量。输入是一串滚动事件,输出是该做的动作;窗口那边只管把
/// `NSEvent` 拆成这几个数喂进来、照结果执行。
///
/// 规则:
/// - 方向按手指算,不按内容滚动的方向:系统「自然滚动」开着时 `scrollingDelta` 跟手指同向,关着时反向,
///   `invertedFromDevice` 就是那个开关,翻过来以后两种设置下手指往左都是下一首、往上都是调大。鼠标滚轮同理。
/// - 一次滑动只认一个方向:刚开始滑的那几 pt 里哪个方向位移大就是哪个(`axisLockDistance`),之后另一个方向的位移全部忽略,
///   斜着滑不会一边切歌一边调音量。
/// - 左右滑一次最多切一首:累计过 `skipDistance` 就切,到这次滑动结束前不再切。
/// - 惯性阶段一律不算:手指离开以后的余势既不切歌也不调音量。
/// - 上下滑按位移连续调,`volumePerPoint`;没有阶段的滚动(鼠标滚轮)每一格按 `wheelStep` 调,不切歌。
public struct NotchScrollGesture: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// 手指刚放上去开始滑。
        case began
        case changed
        /// 手指离开或手势被取消。
        case ended
        /// 手指离开后的惯性余势。
        case momentum
        /// 没有阶段信息:鼠标滚轮那类一格一格的滚动。
        case none
    }

    public enum Action: Equatable, Sendable {
        case nextTrack
        case previousTrack
        /// 系统音量加减多少(0...1 的量纲)。
        case volume(Float)
    }

    enum Axis: Equatable, Sendable { case horizontal, vertical }

    public static let axisLockDistance: Double = 6
    public static let skipDistance: Double = 40
    public static let volumePerPoint: Float = 0.004
    public static let wheelStep: Float = 1.0 / 16

    private var axis: Axis?
    private var lockX: Double = 0
    private var lockY: Double = 0
    private var accumX: Double = 0
    private var skipped = false

    public init() {}

    /// 喂一个滚动事件。`dx`/`dy` 是 `scrollingDeltaX`/`scrollingDeltaY`。
    public mutating func feed(dx: Double, dy: Double, phase: Phase, invertedFromDevice: Bool) -> Action? {
        let fingerX = invertedFromDevice ? dx : -dx
        // 手指往上为正。
        let fingerUp = invertedFromDevice ? -dy : dy
        switch phase {
        case .momentum:
            return nil
        case .none:
            guard fingerUp != 0, abs(fingerUp) >= abs(fingerX) else { return nil }
            return .volume(fingerUp > 0 ? Self.wheelStep : -Self.wheelStep)
        case .ended:
            reset()
            return nil
        case .began:
            reset()
        case .changed:
            break
        }
        if axis == nil {
            lockX += abs(fingerX)
            lockY += abs(fingerUp)
            guard max(lockX, lockY) >= Self.axisLockDistance else {
                accumX += fingerX
                return nil
            }
            axis = lockX > lockY ? .horizontal : .vertical
            if axis == .vertical { accumX = 0 }
        }
        switch axis {
        case .horizontal:
            accumX += fingerX
            guard !skipped, abs(accumX) >= Self.skipDistance else { return nil }
            skipped = true
            return accumX < 0 ? .nextTrack : .previousTrack
        case .vertical:
            guard fingerUp != 0 else { return nil }
            return .volume(Float(fingerUp) * Self.volumePerPoint)
        case nil:
            return nil
        }
    }

    private mutating func reset() {
        axis = nil
        lockX = 0
        lockY = 0
        accumX = 0
        skipped = false
    }
}
