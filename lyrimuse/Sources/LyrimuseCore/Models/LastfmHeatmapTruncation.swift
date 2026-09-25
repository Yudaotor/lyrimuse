import Foundation

/// 「收听热力图」那份按天计数是不是截断的(`LastfmStatsService.syncHistoryIfNeeded` 据此自愈重扫)。
///
/// 按天计数加起来比 Last.fm 报的总 scrobble 数少三成以上就判截断:两个数都是「这个账号全部
/// scrobble」的口径,正常只差几十条(刚落库的 / 被删的),差三成只可能是丢了历史(实测 3,124 vs
/// 24,327,只剩最近 22 天)。
public enum LastfmHeatmapTruncation {
    /// 按天计数之和低于总数的这个比例就判截断。
    public static let minimumCoverage = 0.7

    /// - Parameters:
    ///   - dailyTotal: 按天计数之和。
    ///   - reportedTotal: Last.fm 报的总数。还没取到(nil)或不是正数时不判,别在没有参照的时候把好数据当坏的。
    ///   - rescanAttempted: 这次启动已经为此重扫过一轮。一次启动只自愈一轮:万一 Last.fm 的
    ///     recenttracks 本来就给不全(总数与可翻到的历史对不上),不能每 15 分钟把一百多页重扫一遍。
    public static func looksTruncated(dailyTotal: Int, reportedTotal: Int?, rescanAttempted: Bool) -> Bool {
        guard !rescanAttempted, let total = reportedTotal, total > 0 else { return false }
        return Double(dailyTotal) < Double(total) * minimumCoverage
    }
}
