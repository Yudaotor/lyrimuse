import Foundation

/// "这份**按日历天定义**的缓存,现在该不该重拉?"
///
/// 单纯的 TTL 判据("距上次取过多久")对按天定义的数据是不够的 —— 它只知道过了多少秒,
/// 不知道有没有跨过零点。2026-08-17 用户报的就是这个:「那年今日」用 6 小时 TTL,晚上
/// 22:00 打开取到 8/16 那份,次日 02:00 再打开时 TTL 还没到期,界面就把昨天那份继续挂在
/// "今天"上,最长挂 6 小时。
///
/// 常驻不重启的 App 里这条尤其致命:缓存时间戳只在进程内存里,不会因为跨了零点自己失效,
/// 而 launchd 服务可以连着跑好几天。
///
/// 两个判据取**或**:TTL 到期,或者日历天变了。TTL 那一半仍然有用 —— 同一天之内也不该
/// 每次露面都真发一轮请求。
public enum DailyRefreshGate {
    /// - Parameters:
    ///   - lastFetchedAt: 上次**发起**取数的时刻(不是取成功的时刻 —— 失败也该占住 TTL,
    ///     否则一直失败会变成每次露面都重试)。从没取过传 nil。
    ///   - cachedDay: 手上这份数据是按哪一天算的。只用来判"是不是同一天",传当天任意时刻
    ///     都可以,不需要先归一到 0 点。
    ///   - calendar: 显式传入以便测试;默认跟随系统时区(用户看到的"今天"就是本地的今天)。
    public static func needsRefresh(
        lastFetchedAt: Date?, cachedDay: Date?, now: Date,
        ttl: TimeInterval, calendar: Calendar = .current
    ) -> Bool {
        // 任一为空都当作"没有可用缓存"。两者本该同生同死(调用方在同一处赋值),分开判
        // 只是防御:少了这一条,cachedDay 有值而 lastFetchedAt 为 nil 时下面会读到
        // nil 而不得不给个默认,反而要在这里编一个语义出来。
        guard let lastFetchedAt, let cachedDay else { return true }
        // 跨天优先:哪怕一分钟前刚取过,只要日历天变了,手上那份讲的就是别的日子。
        guard calendar.isDate(cachedDay, inSameDayAs: now) else { return true }
        return now.timeIntervalSince(lastFetchedAt) >= ttl
    }
}
