import Foundation

/// 一次收听里程碑:这首歌第 N 次,或累计第 N 次收听。灵动岛报喜时画的就是它。
public struct ListenMilestone: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 这首歌(写法族合并之后)第 `count` 次。
        case track
        /// 这个 Last.fm 账号累计第 `count` 次收听。
        case total
    }

    public let kind: Kind
    public let count: Int
    /// 正在放的那首歌,报喜面板的第二行。
    public let title: String
    public let artist: String

    public init(kind: Kind, count: Int, title: String, artist: String) {
        self.kind = kind
        self.count = count
        self.title = title
        self.artist = artist
    }
}

/// 哪些次数算里程碑。
public enum ListenMilestoneRules {
    /// 单曲:100、1,000、10,000……(从 100 起的 10 的整数次幂)。
    public static func isTrackMilestone(_ count: Int) -> Bool {
        guard count >= 100 else { return false }
        var n = count
        while n % 10 == 0 { n /= 10 }
        return n == 1
    }

    /// 累计:不到 1 万时只有 1,000 和 5,000 两档,之后每满 1 万一档。
    public static func isTotalMilestone(_ count: Int) -> Bool {
        if count == 1_000 || count == 5_000 { return true }
        return count >= 10_000 && count % 10_000 == 0
    }

    /// `(from, to]` 里最大的那一档累计里程碑;一档都没跨过返回 nil。一次跳过好几档时只报最大的。
    public static func totalMilestoneCrossed(from: Int, to: Int) -> Int? {
        guard to > from else { return nil }
        if to >= 10_000 {
            let m = to / 10_000 * 10_000
            if m > from { return m }
        }
        for m in [5_000, 1_000] where m <= to && m > from {
            return m
        }
        return nil
    }

    /// 累计那一档跨过超过这么多次就不报了:灵动岛关着、或没连账号那段时间跨过的档,事后不补一个过期的喜。
    public static let staleTotalSlack = 50
}

/// 报喜的记账:哪些单曲里程碑报过、今天报了几次单曲、累计数上次看到多少。存成 JSON,机器本地状态。
public struct ListenMilestoneLedger: Codable, Equatable, Sendable {
    /// 报过的单曲里程碑(`trackKey`)。一首歌一辈子最多几档,不会长。
    public var celebratedTracks: [String]
    /// `shownToday` 记的是哪一天(本地日期 `yyyy-MM-dd`)。
    public var day: String
    public var shownToday: Int
    /// 上次看到的累计次数(含当时正在放的那一次)。nil = 还没看过:第一次只记下、不报,之前跨过的档不补报。
    public var lastSeenTotal: Int?

    /// 每天最多报几次单曲里程碑。累计那一档很稀,不占这个名额。
    public static let dailyTrackLimit = 2

    public init(celebratedTracks: [String] = [], day: String = "", shownToday: Int = 0, lastSeenTotal: Int? = nil) {
        self.celebratedTracks = celebratedTracks
        self.day = day
        self.shownToday = shownToday
        self.lastSeenTotal = lastSeenTotal
    }

    public static func trackKey(familyKey: String, count: Int) -> String {
        "\(familyKey)#\(count)"
    }

    public func allowsTrack(_ key: String, today: String) -> Bool {
        guard !celebratedTracks.contains(key) else { return false }
        return (day == today ? shownToday : 0) < Self.dailyTrackLimit
    }

    public mutating func recordTrack(_ key: String, today: String) {
        if day != today {
            day = today
            shownToday = 0
        }
        shownToday += 1
        celebratedTracks.append(key)
    }

    /// 累计数一下子比上次看到的少了这么多:多半是换了 Last.fm 账号,从新的数重新起算。
    public static let accountSwitchDrop = 1_000

    /// 这次看到的累计次数 `ordinal`(含正在放的这一次)要不要报一档。会更新 `lastSeenTotal`。
    /// 第一次看到只记下;跨过的档离现在超过 `ListenMilestoneRules.staleTotalSlack` 次不报。
    public mutating func takeTotalMilestone(ordinal: Int) -> Int? {
        guard let base = lastSeenTotal, ordinal + Self.accountSwitchDrop > base else {
            lastSeenTotal = ordinal
            return nil
        }
        lastSeenTotal = max(base, ordinal)
        guard let m = ListenMilestoneRules.totalMilestoneCrossed(from: base, to: ordinal),
              ordinal - m < ListenMilestoneRules.staleTotalSlack
        else { return nil }
        return m
    }
}
