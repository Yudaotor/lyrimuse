import Foundation

/// 换曲时系统先发布新标题、歌手 / 专辑 / 时长 / 播放器还停在上一首的那种快照(「撕裂快照」),按住不采纳。
///
/// 判据有两种,都不判电台(电台的时长是整档节目):只换了标题、其余逐位不变;或者网易云换了歌、时长还是上一首的
/// (`durationLags`)。按住最多 `maxHold`;形态解除(身份变了或时长跟上来了)立即放行。
/// 见 09 章决策 69。
public struct TornTrackHold: Sendable {
    public static let maxHold: TimeInterval = 12

    public struct Fields: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var album: String
        public var bundle: String
        public var duration: Double
        public var isRadio: Bool

        public init(title: String, artist: String, album: String, bundle: String, duration: Double, isRadio: Bool) {
            self.title = title
            self.artist = artist
            self.album = album
            self.bundle = bundle
            self.duration = duration
            self.isRadio = isRadio
        }

        public init(_ snapshot: MediaControlSnapshot) {
            self.init(title: snapshot.title ?? "", artist: snapshot.artist ?? "", album: snapshot.album ?? "",
                      bundle: snapshot.bundleIdentifier ?? "", duration: snapshot.duration ?? 0,
                      isRadio: snapshot.isRadio == true)
        }

        var key: String { "\(title)|\(artist)|\(album)" }
    }

    public enum Decision: Equatable, Sendable {
        case accept
        /// 这一拍开始按住(打一行日志)。
        case holdStarted
        case holding
        /// 按满 `maxHold` 放行(打一行日志)。
        case released
    }

    private var holdKey: String?
    private var holdSince: Date?

    public init() {}

    /// 这个播放器的快照是整份读来的,不会撕裂:Kaset 走 AppleScript `get player info`,歌名中途换了没有、换了算不算
    /// 另一段录音,`KasetPlayerInfo.steadyIdentity` 已经判过。按住只会让界面停在上一拍(02 章决策 84)。
    public static func arrivesWhole(bundle: String) -> Bool {
        bundle == PlaybackPlayer.kaset.bundleIdentifier
    }

    public static func isTorn(current: Fields, next: Fields) -> Bool {
        if arrivesWhole(bundle: next.bundle) { return false }
        if current.isRadio || next.isRadio || current.title.isEmpty || next.title.isEmpty || current.title == next.title {
            return false
        }
        if durationLags(current: current, next: next) { return true }
        if current.artist.isEmpty || current.artist != next.artist || current.album != next.album
            || current.bundle != next.bundle {
            return false
        }
        return current.duration > 0 && abs(current.duration - next.duration) < 0.01
    }

    /// 网易云换歌时,新歌的第一份快照常带着上一首的时长(歌名、歌手、专辑已经换了)。时长逐位不变就当撕裂按住,
    /// 等它跟上来;只认网易云。非会员试听报的都是 30 秒左右,连着几首试听时长相同是常态,不判。见 09 章决策 192。
    static func durationLags(current: Fields, next: Fields) -> Bool {
        next.bundle == PlaybackPlayer.netease.bundleIdentifier && current.bundle == next.bundle
            && current.duration > 0 && abs(current.duration - next.duration) < 0.01
            && !neteaseTrialLength.contains(next.duration)
    }

    /// 网易云非会员试听报的时长范围。跟引擎 neteasetrial.go 的 neteaseTrialMinSecs / neteaseTrialMaxSecs 必须一起改。
    static let neteaseTrialLength: ClosedRange<Double> = 29...31

    public mutating func decide(current: Fields?, next: Fields, now: Date) -> Decision {
        guard let current, Self.isTorn(current: current, next: next) else {
            holdKey = nil
            holdSince = nil
            return .accept
        }
        let key = next.key
        guard holdKey == key, let since = holdSince else {
            holdKey = key
            holdSince = now
            return .holdStarted
        }
        if now.timeIntervalSince(since) < Self.maxHold { return .holding }
        holdKey = nil
        holdSince = nil
        return .released
    }
}
