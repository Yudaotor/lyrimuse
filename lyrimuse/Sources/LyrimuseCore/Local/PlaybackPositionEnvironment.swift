import Foundation

/// 位置状态机(`LocalPlaybackSource.applyPosition`)碰到的外部世界:学习表存哪、偏置文件怎么读写、
/// 两个一次性真值探针、此刻的输出设备。线上用 `.live`;selftest 换成内存里的假实现,
/// 回放一串快照时不会去问真的 Spotify / 浏览器、也不会写用户的偏好和 collector 读的偏置文件。
///
/// 只收位置状态机用得到的那几样。`apply` 前半段(歌词缓存、封面、广告复核)的副作用不经过这里,
/// 回放测试也不走那一段。
public struct PlaybackPositionEnvironment {
    /// 起播领先量 / 探针领先量 / 锚点滞后三张学习表存在哪。
    public var defaults: UserDefaults
    public var readPositionBias: () -> PositionBiasRecord?
    public var writePositionBias: (PositionBiasRecord) -> Void
    /// 此刻默认输出设备(探针领先量按它查表)。
    public var outputRoute: () -> AudioOutputRoute.Current?

    public var browserProbeTrackChanged: (_ from: String, _ to: String) -> Void
    public var browserProbeKick: (_ bundleID: String?, _ key: String, _ expectedDuration: Double) -> Void
    public var browserProbeConsume: (_ key: String, _ rate: Double, _ now: Date) -> BrowserPositionProbe.Correction?
    public var browserProbeReopenAfterResume: (_ key: String) -> Void

    public var spotifyProbeTrackChanged: (_ key: String, _ isSpotifyNative: Bool) -> Void
    public var spotifyProbeConsume: (_ key: String, _ rate: Double, _ now: Date) -> Double?
    public var spotifyProbeRequestConfirmation: (_ key: String) -> Void

    public init(
        defaults: UserDefaults,
        readPositionBias: @escaping () -> PositionBiasRecord?,
        writePositionBias: @escaping (PositionBiasRecord) -> Void,
        outputRoute: @escaping () -> AudioOutputRoute.Current?,
        browserProbeTrackChanged: @escaping (String, String) -> Void,
        browserProbeKick: @escaping (String?, String, Double) -> Void,
        browserProbeConsume: @escaping (String, Double, Date) -> BrowserPositionProbe.Correction?,
        browserProbeReopenAfterResume: @escaping (String) -> Void,
        spotifyProbeTrackChanged: @escaping (String, Bool) -> Void,
        spotifyProbeConsume: @escaping (String, Double, Date) -> Double?,
        spotifyProbeRequestConfirmation: @escaping (String) -> Void
    ) {
        self.defaults = defaults
        self.readPositionBias = readPositionBias
        self.writePositionBias = writePositionBias
        self.outputRoute = outputRoute
        self.browserProbeTrackChanged = browserProbeTrackChanged
        self.browserProbeKick = browserProbeKick
        self.browserProbeConsume = browserProbeConsume
        self.browserProbeReopenAfterResume = browserProbeReopenAfterResume
        self.spotifyProbeTrackChanged = spotifyProbeTrackChanged
        self.spotifyProbeConsume = spotifyProbeConsume
        self.spotifyProbeRequestConfirmation = spotifyProbeRequestConfirmation
    }

    public static var live: PlaybackPositionEnvironment {
        PlaybackPositionEnvironment(
            defaults: .standard,
            readPositionBias: { PositionBiasFile.read() },
            writePositionBias: { PositionBiasFile.write($0) },
            outputRoute: { AudioOutputRoute.current() },
            browserProbeTrackChanged: { BrowserPositionProbe.shared.trackChanged(from: $0, to: $1) },
            browserProbeKick: { BrowserPositionProbe.shared.kickIfNeeded(bundleIdentifier: $0, key: $1, expectedDuration: $2) },
            browserProbeConsume: { BrowserPositionProbe.shared.consumeCorrection(forKey: $0, rate: $1, now: $2) },
            browserProbeReopenAfterResume: { BrowserPositionProbe.shared.reopenAfterResume(key: $0) },
            spotifyProbeTrackChanged: { SpotifyPositionProbe.shared.trackChanged(to: $0, isSpotifyNative: $1) },
            spotifyProbeConsume: { SpotifyPositionProbe.shared.consumeCorrection(forKey: $0, rate: $1, now: $2) },
            spotifyProbeRequestConfirmation: { SpotifyPositionProbe.shared.requestConfirmation(forKey: $0) })
    }
}
