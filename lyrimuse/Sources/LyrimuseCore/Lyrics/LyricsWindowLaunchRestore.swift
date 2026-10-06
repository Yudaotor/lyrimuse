import Foundation

/// 启动时把上次开着的歌词窗口重新开出来:开一次,隔一会儿核对窗口上没上屏,没上屏再开,最多开
/// `checkDelays.count` 次。只管时序和判定,开窗、核对、记日志在 App 侧(`LyricsWindowLaunchRestorer`)。
/// 见 07 章决策 124。
public struct LyricsWindowLaunchRestore: Equatable {
    /// 第一次开窗前从启动等多久。启动太早 `openWindow` 静默无效,同引导那 0.5 秒。
    public static let firstDelay: TimeInterval = 0.5
    /// 第 n 次开窗之后隔多久核对。项数就是最多开几次。
    public static let checkDelays: [TimeInterval] = [1.5, 3, 5, 2]

    /// 核对那一刻的状况。
    public struct Probe: Equatable {
        /// 窗口在屏上(最小化也算)。
        public var onScreen: Bool
        /// 还该开:上次开着的记录还在(这期间用户没自己关窗),App 也没在退出。
        public var stillWanted: Bool

        public init(onScreen: Bool, stillWanted: Bool) {
            self.onScreen = onScreen
            self.stillWanted = stillWanted
        }
    }

    public enum Outcome: Equatable {
        /// 窗口上了屏。`attempts` 是开了几次,0 = 还没开它就已经在屏上。
        case restored(attempts: Int)
        /// 不该再开了:用户关了窗,或 App 在退出。
        case stopped(attempts: Int)
        /// 开满了还没上屏。
        case gaveUp(attempts: Int)
    }

    public enum Step: Equatable {
        /// 开一次窗口,隔 `checkAfter` 秒再来问下一步。
        case open(checkAfter: TimeInterval)
        case finish(Outcome)
    }

    /// 已经开了几次。
    public private(set) var attempts = 0

    public init() {}

    /// 到了核对时刻(第一次是启动后 `firstDelay`)问下一步。窗口在屏上优先于「还该不该开」。
    public mutating func next(_ probe: Probe) -> Step {
        if probe.onScreen { return .finish(.restored(attempts: attempts)) }
        if !probe.stillWanted { return .finish(.stopped(attempts: attempts)) }
        guard attempts < Self.checkDelays.count else { return .finish(.gaveUp(attempts: attempts)) }
        attempts += 1
        return .open(checkAfter: Self.checkDelays[attempts - 1])
    }
}
