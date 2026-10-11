import Foundation

/// 触控栏歌词的自动展开 / 收起(设置 › 歌词显示 › 触控栏 › 行为,三个开关默认都关,见 17 章决策 45)。
///
/// 只在情况变了的那一刻判一次:开始播放、暂停满 `pauseCollapseDelayMs`、这首确认没有歌词、之后又有了。不按此刻的状态
/// 一直压着 —— 手动展开 / 收起之后保持原样,等下一次变化。展开会占掉前台 App 自己的触控栏按钮,所以:
/// - 自动收起的(暂停、没歌词)在原因解除时自动展开回来;
/// - 手动收起的,只有「开始播放时自动展开」在下一次真正开始播放时才展开;播放中自然换歌不展开;
/// - 停不到 `resumeDebounceMs` 就又放起来的(切歌、缓冲那一下)不算开始播放。
///
/// 控制器每次播放状态变了调 `update`,暂停满时长调 `pauseDelayElapsed`,看到不是自己发起的展开 / 收起时调
/// `userChangedVisibility`;返回的动作照做。
public struct TouchBarAutoPresent: Equatable, Sendable {
    public struct Options: Equatable, Sendable {
        /// 开始播放时自动展开。
        public var expandOnPlay: Bool
        /// 暂停时收起(暂停满 `pauseCollapseDelayMs`),继续播放时展开回来。
        public var collapseWhenPaused: Bool
        /// 纯音乐 / 无歌词时收起(判据 `NoLyricsAutoHide.lacksLyrics`),之后有歌词时展开回来。
        public var collapseWhenNoLyrics: Bool

        public init(expandOnPlay: Bool, collapseWhenPaused: Bool, collapseWhenNoLyrics: Bool) {
            self.expandOnPlay = expandOnPlay
            self.collapseWhenPaused = collapseWhenPaused
            self.collapseWhenNoLyrics = collapseWhenNoLyrics
        }
    }

    public enum Action: Equatable, Sendable {
        case none
        case expand
        case collapse
        /// 刚暂停:`pauseCollapseDelayMs` 之后调 `pauseDelayElapsed`;期间开始播放、或者用户自己展开 / 收起了,作废。
        case schedulePauseCollapse
    }

    /// 这一次是因为什么自动收起的。
    public enum Reason: Equatable, Sendable {
        case paused
        case noLyrics
    }

    /// 暂停多久收起。在触控栏上按了暂停、想再按播放,收得太快就得先点功能栏图标。
    public static let pauseCollapseDelayMs = 10_000
    /// 停不到这么久就又放起来的,算切歌 / 缓冲,不算开始播放。
    public static let resumeDebounceMs = 2_000

    /// 现在收着是不是自己收的、因为什么;nil = 没收,或者是用户收的。
    public private(set) var autoCollapsed: Reason?
    private var playing: Bool?
    private var lacksLyrics = false
    private var trackKey: String?
    private var pausedAtMs: Int?

    public init() {}

    /// 启用那一刻(App 启动、触控栏出现、开关打开):从此刻的状态开始记。正在播放、开了「开始播放时自动展开」、还收着
    /// 就展开(这首已知没歌词、又开了「无歌词时收起」的除外)。
    public mutating func start(isPlaying: Bool, lacksLyrics: Bool, trackKey: String?, nowMs: Int, visible: Bool,
                               options: Options) -> Action {
        self = TouchBarAutoPresent()
        playing = isPlaying
        self.lacksLyrics = lacksLyrics
        self.trackKey = trackKey
        if !isPlaying { pausedAtMs = nowMs }
        guard isPlaying, !visible, options.expandOnPlay, !(lacksLyrics && options.collapseWhenNoLyrics) else { return .none }
        return .expand
    }

    /// 播放状态有变化(在不在播、这首有没有歌词、换没换歌)。值没变时调用也没关系,不会重复动作。
    public mutating func update(isPlaying: Bool, lacksLyrics: Bool, trackKey: String?, nowMs: Int, visible: Bool,
                                options: Options) -> Action {
        let wasPlaying = playing
        let lacked = self.lacksLyrics
        let newTrack = trackKey != self.trackKey
        playing = isPlaying
        self.lacksLyrics = lacksLyrics
        self.trackKey = trackKey
        let paused = wasPlaying == true && !isPlaying
        let resumed = wasPlaying == false && isPlaying
        let pausedFor = pausedAtMs.map { nowMs - $0 } ?? Int.max
        if paused { pausedAtMs = nowMs }
        if resumed { pausedAtMs = nil }

        // 刚确认没歌词,或者换到一首已知没歌词的。
        if lacksLyrics, !lacked || newTrack, options.collapseWhenNoLyrics {
            guard visible else { return .none }
            autoCollapsed = .noLyrics
            return .collapse
        }
        if paused {
            return options.collapseWhenPaused && visible ? .schedulePauseCollapse : .none
        }
        if resumed {
            guard !visible, !(lacksLyrics && options.collapseWhenNoLyrics) else { return .none }
            // 自动收起的(暂停时收的;或者没歌词收的、暂停期间换到了有歌词的一首)都展开回来。
            if autoCollapsed != nil {
                autoCollapsed = nil
                return .expand
            }
            return options.expandOnPlay && pausedFor >= Self.resumeDebounceMs ? .expand : .none
        }
        // 没歌词收起的,换到下一首(搜索期间照常算有)、或者这首后来有了歌词:展开回来。暂停着又开了「暂停时收起」的不展开。
        if !lacksLyrics, lacked || newTrack, autoCollapsed == .noLyrics, !visible {
            guard isPlaying || !options.collapseWhenPaused else { return .none }
            autoCollapsed = nil
            return .expand
        }
        return .none
    }

    /// 暂停满 `pauseCollapseDelayMs`:还在暂停、还展开着、开关还开着就收起。
    public mutating func pauseDelayElapsed(isPlaying: Bool, visible: Bool, options: Options) -> Action {
        guard !isPlaying, visible, options.collapseWhenPaused else { return .none }
        autoCollapsed = .paused
        return .collapse
    }

    /// 用户自己展开或收起了(功能栏图标、✕、收起键、快捷键):之前自动收起的原因作废,手动的结果保持到下一次变化。
    public mutating func userChangedVisibility() {
        autoCollapsed = nil
    }
}
