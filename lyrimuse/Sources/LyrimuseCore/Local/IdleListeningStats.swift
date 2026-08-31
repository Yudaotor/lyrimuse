import Foundation

/// 停播页「收听总览」那三个参照数字的派生算术(2026-08-24)。
///
/// 为什么落在 Core 而不是写在 View 里:按本项目纪律,几何/算术进 Core 纯函数 + selftest 钉住。
/// 现存的迷你热力图把周锚算术写在 View 里、没有任何回归保护,这里不重复那个做法。
///
/// 数据源统一是 `LastfmStatsService.dailyCounts`(天粒度桶,键 "yyyy-MM-dd" 本地时区)。
/// ⚠️ 那份桶**只存非零天**(实测 316 个键、没有一个 0 值),所以 `dailyCounts.count` 就是
/// 「有记录多少天」,而某一天查不到 = 那天没听,不是数据缺失。
public enum IdleListeningStats {
    /// 最近 `days` 天(含 `today`)每天的收听数,按时间**正序**返回,缺的天补 0。
    ///
    /// dayKey 由调用方注入 —— 键的格式/时区必须跟建桶时**同一个** formatter,
    /// 在 Core 里另起一个 DateFormatter 就是第二把尺子。
    public static func series(
        dailyCounts: [String: Int], endingAt today: Date, days: Int,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> [Int] {
        guard days > 0 else { return [] }
        let start = calendar.startOfDay(for: today)
        return (0 ..< days).compactMap { i -> Int? in
            guard let d = calendar.date(byAdding: .day, value: i - (days - 1), to: start) else { return nil }
            return dailyCounts[dayKey(d)] ?? 0
        }
    }

    /// `series` 那几天各自是哪一天(同一套对齐口径)。走势图要拿它标出「最高那天是几号」、
    /// 以及悬停时报出具体日期 —— 在 View 里另算一遍日期偏移就是第二把尺子。
    public static func days(
        endingAt today: Date, days: Int, calendar: Calendar = .current
    ) -> [Date] {
        guard days > 0 else { return [] }
        let start = calendar.startOfDay(for: today)
        return (0 ..< days).compactMap {
            calendar.date(byAdding: .day, value: $0 - (days - 1), to: start)
        }
    }

    /// 「近 7 天」的**自然日对齐**口径:今天往回数 7 个自然日的收听总数。
    ///
    /// 存在的理由(2026-08-30 用户拍板):界面上那个「近 7 天」数字块,**数值**原来取的是
    /// API 的 `overview.week`(从此刻往回滚动 168 小时),而紧挨着的**百分比**是本地桶按
    /// 自然日算的 —— 两个窗口定义不同,永远对不上。实测这台机器:API 给 781,桶给 669,
    /// 差 112 次(约 17%),用户看到「781 · 近 7 天 · 较上周 -47%」却核对不出来。
    /// 改成两者同源:数值也走这里,跟 `weekOverWeekDelta` 用**同一个窗口、同一份数据**。
    ///
    /// ⚠️ 代价必须知道:这个数会比 Last.fm 网页上的「last 7 days」略低,因为那边是滚动
    /// 168 小时、这边是自然日对齐 —— 不是算错了,是口径不同。宁可要「块内自洽、用户能
    /// 自己核对」,也不要「跟网页对得上但自己跟自己对不上」。
    ///
    /// `todayCount` 同 `weekOverWeekDelta`:桶同步到昨天为止,今天那一格要靠实时值补。
    /// 桶还没同步完时(dailySyncing)调用方应该退回 API 值 —— 那时候桶本身就是残缺的。
    public static func lastSevenDays(
        dailyCounts: [String: Int], today: Date, todayCount: Int? = nil,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> Int {
        var s = series(dailyCounts: dailyCounts, endingAt: today, days: 7,
                       calendar: calendar, dayKey: dayKey)
        if let todayCount, let last = s.indices.last {
            s[last] = todayCount
        }
        return s.reduce(0, +)
    }

    /// 滚动 7 天的环比:(最近 7 天 − 前一个 7 天) ÷ 前一个 7 天。
    ///
    /// 分母为 0 时返回 nil ——「从 0 涨到 N」没有百分比可言,这时整行该缺席而不是显示 ∞ 或 0%。
    /// 两个窗口都在同一份桶里算,所以这个比值自洽;⚠️ 但它**跟界面上那个「近 7 天」大数字不同源**
    /// (那个取的是 API 的 @attr.total),别把它当成「大数字 ÷ 上周大数字」的结果去核对。
    ///
    /// `todayCount`(2026-08-30 加):今天那一格的实时值。**桶是同步到昨天为止的**,今天
    /// 的格子通常压根不存在 —— 不传这个参数的话,今天会被当成 0 计进最近 7 天,把环比
    /// 系统性地拉低。走势图早就在补这一格了(`IdleStandbyView.series` 用 `overview.today`
    /// 盖掉最后一根),而这里没补,同一个「今天还没进桶」的问题两处处理方式不一致 ——
    /// 实测这台机器:不补是 -48%,补上是 -47%,差得不多但方向是系统性偏负。
    /// 传 nil = 明确表示"今天的实时值也拿不到",这时维持旧行为(当 0)。
    public static func weekOverWeekDelta(
        dailyCounts: [String: Int], today: Date, todayCount: Int? = nil,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> Double? {
        var s = series(dailyCounts: dailyCounts, endingAt: today, days: 14,
                       calendar: calendar, dayKey: dayKey)
        // 跟走势图同一个补法:只盖最后一格(今天),不动历史 —— 历史那些天桶里是权威的。
        if let todayCount, let last = s.indices.last {
            s[last] = todayCount
        }
        guard s.count == 14 else { return nil }
        let prev = s[0 ..< 7].reduce(0, +)
        let last = s[7 ..< 14].reduce(0, +)
        guard prev > 0 else { return nil }
        return (Double(last) - Double(prev)) / Double(prev)
    }

    /// 「日均 N · 共 M 天」。两个数都只在桶里算,自洽。
    ///
    /// 桶还没同步完时算出来的是**假日均**(只同步了 60 天就会得到一个虚高的值),
    /// 所以调用方必须先用 `dailySyncing` 把这一行挡掉 —— 这里不知道同步状态,不负责这件事。
    public static func dailyAverage(dailyCounts: [String: Int]) -> (average: Int, days: Int)? {
        let days = dailyCounts.count
        guard days > 0 else { return nil }
        let total = dailyCounts.values.reduce(0, +)
        return (Int((Double(total) / Double(days)).rounded()), days)
    }
}
