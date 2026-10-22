import Foundation

/// 换曲时系统先发布新标题、歌手 / 专辑 / 时长 / 播放器还停在上一首的那种快照(「撕裂快照」),按住不采纳。
///
/// 判据有两种,都不判电台(电台的时长是整档节目):只换了标题、其余逐位不变;或者网易云 / 汽水 / 洛雪换了歌、时长还是上一首的
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
    /// reAMP 也是:它把标题(「歌手 - 歌名」一个字段)和时长一起发,歌手、专辑、时长从这一份标题或它开着的那个文件来,
    /// 同专辑两首时长相同时按住只会让新歌晚 12 秒才换上(02 章决策 126)。VOX 的曲目也是 AppleScript 一次读齐的(VoxPlayerInfo)。
    /// Pine Player 换歌时歌名、歌手一栏、时长同一份一起换,歌手和专辑另按它开着的文件认(PinePlayerInfo)。
    public static func arrivesWhole(bundle: String) -> Bool {
        bundle == PlaybackPlayer.kaset.bundleIdentifier || bundle == PlaybackPlayer.reamp.bundleIdentifier
            || bundle == PlaybackPlayer.vox.bundleIdentifier || bundle == PlaybackPlayer.pinePlayer.bundleIdentifier
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

    /// 网易云、汽水、洛雪换歌时,新歌的第一份快照常带着上一首的时长(歌名、歌手、专辑已经换了;汽水、洛雪连位置也是上一首的)。
    /// 时长逐位不变就当撕裂按住,等它跟上来;只认这三家。非会员试听连着几首时长相同是常态,试听段长度的不判;洛雪没有试听段,
    /// 时长是音频元素读出来的小数,两首逐位相同的情形实际碰不到。见 09 章决策 192、237,02 章决策 128。
    static func durationLags(current: Fields, next: Fields) -> Bool {
        guard current.bundle == next.bundle, current.duration > 0, abs(current.duration - next.duration) < 0.01 else {
            return false
        }
        switch next.bundle {
        case PlaybackPlayer.netease.bundleIdentifier:
            return !neteaseTrialLength.contains(next.duration)
        case PlaybackPlayer.soda.bundleIdentifier:
            return !sodaPreviewLengths.contains { $0.contains(next.duration) }
        case PlaybackPlayer.lxMusic.bundleIdentifier:
            return true
        default:
            return false
        }
    }

    /// 网易云非会员试听报的时长范围。跟引擎 neteasetrial.go 的 neteaseTrialMinSecs / neteaseTrialMaxSecs 必须一起改。
    static let neteaseTrialLength: ClosedRange<Double> = 29...31

    /// 汽水非会员试听段报的时长(30 / 60 秒)。跟引擎 sodapreview.go 的 sodaPreviewDurationTolerance 必须一起改。
    static let sodaPreviewLengths: [ClosedRange<Double>] = [28.5...31.5, 58.5...61.5]

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
