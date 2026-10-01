import Foundation

/// 换曲时系统先发布新标题、歌手 / 专辑 / 时长 / 播放器还停在上一首的那种快照(「撕裂快照」),按住不采纳。
///
/// 判据:只换了标题,其余逐位不变,
/// 不是电台(电台的时长是整档节目,不参与判定)。按住最多 `maxHold`;形态解除(身份变了或时长跟上来了)立即放行。
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

    public static func isTorn(current: Fields, next: Fields) -> Bool {
        if current.isRadio || next.isRadio || current.title.isEmpty || next.title.isEmpty || current.title == next.title {
            return false
        }
        if current.artist.isEmpty || current.artist != next.artist || current.album != next.album
            || current.bundle != next.bundle {
            return false
        }
        return current.duration > 0 && abs(current.duration - next.duration) < 0.01
    }

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
