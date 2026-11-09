import Foundation

/// MyGo Music 在开始出声的那一刻(新起一首、自然连播、跳转、恢复)就报锚点,声音要等它自己的混音缓冲(`mixAheadSecs`)
/// 和输出设备的延迟走完才出来,播放中又不再补报,不挪的话整首都比声音早这么多。在放的锚点按这两截把时刻往后挪;
/// 停了 `idleCloseSecs` 以上它会关掉音频输出,输出是内置扬声器时恢复同一首重开输出,锚点只早 `coldLeadSecs` 左右,
/// 按这一档挪;蓝牙等外接设备重开输出更慢,照常挪;换成别的歌照常挪。
/// 暂停帧报的是已经听到的位置,不动。带内嵌封面的歌封面读出来后会再报一份「在放、位置接近 0」的锚点,这份比声音晚,
/// 沿用开播那份。见 02 章决策 244。
public enum MyGoSessionAnchor {
    public struct Anchor: Equatable, Sendable {
        public var identity: String
        public var elapsed: Double
        /// media-control 报的时刻原文;同一份锚点重复解码时按它认。
        public var rawTimestamp: String
        /// 挪过之后的时刻。
        public var timestamp: String
        public var rate: Double

        public init(identity: String, elapsed: Double, rawTimestamp: String, timestamp: String, rate: Double) {
            self.identity = identity
            self.elapsed = elapsed
            self.rawTimestamp = rawTimestamp
            self.timestamp = timestamp
            self.rate = rate
        }
    }

    /// MyGo 播放器的混音缓冲:它的音频框架按播放器档位固定提前混这么多。
    public static let mixAheadSecs: Double = 0.25
    /// 它的音频框架没声音放多久就关掉输出。
    public static let idleCloseSecs: Double = 5
    /// 输出关掉之后恢复同一首,锚点比声音早的那截(不含设备延迟)。实测 0.07~0.12 秒。
    public static let coldLeadSecs: Double = 0.075
    /// 封面那份锚点比开播那份晚到多久之内算它(实测约 0.55 秒)。
    public static let coverEchoWindowSecs: Double = 1.2
    /// 封面那份和开播那份的位置都在这之内才算(都是这首刚开头)。
    public static let coverEchoMaxElapsedSecs: Double = 0.3

    /// 要跨帧记住的:上一份在放的锚点,最近一次暂停帧的时刻(秒)和那时是哪一首。
    public struct State: Equatable, Sendable {
        public var anchor: Anchor?
        public var pausedAt: Double?
        public var pausedIdentity: String?
        public init(anchor: Anchor? = nil, pausedAt: Double? = nil, pausedIdentity: String? = nil) {
            self.anchor = anchor
            self.pausedAt = pausedAt
            self.pausedIdentity = pausedIdentity
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func seconds(_ timestamp: String) -> Double? {
        MediaControlMicros.date(fromTimestampString: timestamp)?.timeIntervalSince1970
            ?? ISO8601DateFormatter().date(from: timestamp)?.timeIntervalSince1970
    }

    /// 挪过之后的位置、时刻,和要记下的状态。`outputLatency` 是默认输出设备的延迟(秒)。纯函数,selftest 覆盖。
    public static func fill(identity: String, playing: Bool?, elapsed: Double?, timestamp: String?, rate: Double?,
                            outputLatency: Double, outputBuiltIn: Bool = true, state: State)
        -> (elapsed: Double?, timestamp: String?, state: State) {
        // 按速率认:停下的那份速率是 0(在放标志可能还是真);暂停中换歌时新歌的锚点先以「没在放、速率 1」到,同样挪。
        let moving = (rate ?? (playing == true ? 1 : 0)) > 0
        guard moving, let elapsed, let timestamp, let t = seconds(timestamp) else {
            guard !moving else { return (elapsed, timestamp, State(pausedAt: state.pausedAt, pausedIdentity: state.pausedIdentity)) }
            return (elapsed, timestamp, State(pausedAt: timestamp.flatMap(seconds) ?? state.pausedAt, pausedIdentity: identity))
        }
        if let last = state.anchor, last.identity == identity {
            if last.rawTimestamp == timestamp, last.elapsed == elapsed { return (last.elapsed, last.timestamp, state) }
            if let a = seconds(last.rawTimestamp), t > a, t - a <= coverEchoWindowSecs,
               last.elapsed <= coverEchoMaxElapsedSecs, elapsed <= coverEchoMaxElapsedSecs {
                return (last.elapsed, last.timestamp, state)
            }
        }
        let cold = outputBuiltIn && state.anchor == nil && state.pausedIdentity == identity
            && state.pausedAt.map { t - $0 >= idleCloseSecs } == true
        let lead = (cold ? coldLeadSecs : mixAheadSecs) + max(outputLatency, 0)
        let shifted = MediaControlMicros.timestampString((t + lead) * 1_000_000) ?? timestamp
        let anchor = Anchor(identity: identity, elapsed: elapsed, rawTimestamp: timestamp, timestamp: shifted, rate: rate ?? 1)
        return (elapsed, shifted, State(anchor: anchor))
    }

    /// 焦点被别的 App 占着时按 bundle id 单问到的那份:它不走主路的解码,锚点(1970 年起的秒数)在这里过同一套挪法,
    /// 返回按挪过的锚点推到 `now` 的位置。没在走、缺锚点为 nil(照单问那份原样用)。
    static func probedPosition(identity: String, playing: Bool?, elapsed: Double?, anchorAt: Double?, rate: Double?, now: Date)
        -> Double? {
        let raw = anchorAt.flatMap { MediaControlMicros.timestampString($0 * 1_000_000) }
        let out = filled(bundleID: PlaybackPlayer.mygoMusic.bundleIdentifier, identity: identity, playing: playing,
                         elapsed: elapsed, timestamp: raw, rate: rate)
        return position(elapsed: out.elapsed, timestamp: out.timestamp, rate: rate, playing: playing, now: now)
    }

    /// 锚点推到 `now` 的位置:没在走、缺锚点为 nil,不推到 0 以前。纯函数,selftest 覆盖。
    public static func position(elapsed: Double?, timestamp: String?, rate: Double?, playing: Bool?, now: Date) -> Double? {
        let speed = rate ?? (playing == true ? 1 : 0)
        guard speed > 0, let elapsed, let at = timestamp.flatMap(seconds) else { return nil }
        return max(0, elapsed + (now.timeIntervalSince1970 - at) * speed)
    }

    /// 解码系统会话时调:不是 MyGo 的原样交回。
    static func filled(bundleID: String?, identity: String, playing: Bool?, elapsed: Double?, timestamp: String?, rate: Double?)
        -> (elapsed: Double?, timestamp: String?) {
        guard bundleID == PlaybackPlayer.mygoMusic.bundleIdentifier else { return (elapsed, timestamp) }
        lock.lock()
        defer { lock.unlock() }
        let out = fill(identity: identity, playing: playing, elapsed: elapsed, timestamp: timestamp, rate: rate,
                       outputLatency: AudioOutputRoute.outputLatencySecs() ?? 0,
                       outputBuiltIn: AudioOutputRoute.current()?.transport == .builtIn, state: state)
        state = out.state
        return (out.elapsed, out.timestamp)
    }
}
