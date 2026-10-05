import Foundation

/// Last.fm 统计里「那边没有封面」的结论:`track.getinfo` 成功返回却没带图,或 Apple Music 目录挑不出对得上的那一条。
/// 每个键记下判「没有」的时刻和连续次数,按 `delays` 到期才再问;拿到图就整条清掉。随最近记录的翻页缓存落盘
/// (`LastfmStatsService.RecentPageCacheSnapshot`),见 12 章决策 47。
///
/// 纯值类型,selftest 覆盖(LastfmTests.swift「封面没有的退避」)。
public struct CoverUnavailableLedger: Equatable {
    /// 第 n 次连续判「没有」之后,再等多久才重问(n 从 1 起;超出表长取最后一档)。封面比「第 N 次听」的次数稳定得多,
    /// 档位比 `PlayCountUnavailableBackoff` 长。
    public static let delays: [TimeInterval] = [24 * 60 * 60, 7 * 24 * 60 * 60, 30 * 24 * 60 * 60]

    public private(set) var markedAt: [String: Date] = [:]
    public private(set) var strikes: [String: Int] = [:]

    public init() {}

    public static func delay(strikes: Int) -> TimeInterval {
        guard strikes >= 1 else { return delays[0] }
        return delays[min(strikes, delays.count) - 1]
    }

    /// 这个键判过「没有」(不管到没到期)。
    public func contains(_ key: String) -> Bool { markedAt[key] != nil }

    /// 该不该为这一行再问一次:没判过「没有」,或退避已到期。时钟倒退(now 早于记录时刻)不算到期。
    public func shouldAsk(_ key: String, now: Date) -> Bool {
        guard let at = markedAt[key] else { return true }
        return now.timeIntervalSince(at) >= Self.delay(strikes: strikes[key] ?? 1)
    }

    /// 记一次「没有」:连续次数 +1、时刻刷新。
    public mutating func mark(_ key: String, at stamp: Date) {
        markedAt[key] = stamp
        strikes[key] = (strikes[key] ?? 0) + 1
    }

    /// 拿到图了:整条清掉。
    public mutating func clear(_ key: String) {
        markedAt[key] = nil
        strikes[key] = nil
    }

    /// 落盘那一份:只留 `keys` 里的,时刻写成 unix 秒。
    public func persisted(scope keys: Set<String>) -> (markedAt: [String: Double], strikes: [String: Int]) {
        var at: [String: Double] = [:]
        var n: [String: Int] = [:]
        for (k, t) in markedAt where keys.contains(k) {
            at[k] = t.timeIntervalSince1970
            n[k] = strikes[k] ?? 1
        }
        return (at, n)
    }

    /// 读盘:只补内存里还没有记录的键。没有次数的键按 1 次算。
    public mutating func restore(markedAt saved: [String: Double]?, strikes savedStrikes: [String: Int]?) {
        for (k, t) in saved ?? [:] where markedAt[k] == nil {
            markedAt[k] = Date(timeIntervalSince1970: t)
            strikes[k] = max(savedStrikes?[k] ?? 1, 1)
        }
    }
}
