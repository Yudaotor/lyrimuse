import Foundation

/// 「第 N 次听」里"那边没有这一项"结论的**退避重探**日程(2026-09-03)。
///
/// 此前 `LastfmStatsService.playCountUnavailable` 是一张只进不出的表:`track.getinfo` 对一首
/// 够老(≥15 分钟)的行返回 `userplaycount = 0` 或 error 6,就永久记成"没有",且随最近记录
/// 快照落盘、重启也不重问;唯一解除路径是再播一次这首歌。而 Last.fm 的按用户计数对**新条目**
/// 滞后可达几十分钟(2026-09-03 实测:陳綺貞《慢歌 3》16:36 落库,16:36/16:38/16:40/16:46/
/// 16:50 五次查都还是 0,过了 15 分钟那一轮把它钉死;Last.fm 网页那边当时已显示 1 次)。
/// 一次滞后 = 永久空白,而且不显示「···」占位(占位只给"还在解析"的行),用户看到的就是
/// 一行没有次数、也没有任何解释。
///
/// 现在"没有"是一个**带时间戳、可过期**的结论:第 1 次判 0 之后 1 小时允许重探,仍是 0 →
/// 6 小时,再 → 24 小时封顶。重探只发生在 `resolvePlayCounts` 本来就会看的行上(当前页 /
/// 预取页),所以对真正没有的曲目(Last.fm 压根没这首)成本是每天最多一个请求。
///
/// 纯函数,selftest 覆盖(LastfmTests.swift「次数不可用退避」)。
public enum PlayCountUnavailableBackoff {
    /// 第 n 次连续判"没有"之后,再等多久才允许重探(n 从 1 起;超出表长取最后一档)。
    public static let delays: [TimeInterval] = [60 * 60, 6 * 60 * 60, 24 * 60 * 60]

    public static func delay(strikes: Int) -> TimeInterval {
        guard strikes >= 1 else { return delays[0] }
        return delays[min(strikes, delays.count) - 1]
    }

    /// 上次判"没有"的时刻 `markedAt`、连续次数 `strikes`,到 `now` 是否该重探。
    public static func isDue(markedAt: Date, strikes: Int, now: Date) -> Bool {
        now.timeIntervalSince(markedAt) >= delay(strikes: strikes)
    }
}
