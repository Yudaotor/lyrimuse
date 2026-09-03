import Foundation

/// 「那年今日」的取数计划(2026-09-03)。
///
/// 此前的做法是对 1/2/3 年前的**当天**各发一个 `user.getrecenttracks from/to`,整天为空就再往前
/// 一年,三年全空就显示"都没有"。两个问题:①一天的窗口太窄——账号有整年空档(实测这台机器
/// 2024/2025 两年没有记录)或那天恰好没听,卡就空了;②三个请求全是"猜",而本地热力图日桶
/// (`dailyCounts`,全量历史)早就知道哪几天有记录、有几条。
///
/// 现在先用日桶排计划:每一年先看当天,当天为空就放宽到**那一周**(当天 ±3 天),日桶里
/// 加起来仍是 0 的窗口**根本不发请求**;按"年份近 → 远、天 → 周"的顺序排,调用方沿着计划
/// 逐个请求,第一个拿到行的就是结果。日桶没同步过(首次连接的全量同步还没跑完)时退回
/// "三年、只看当天、都发"的旧计划。
///
/// 纯函数,selftest 覆盖(LastfmTests.swift「那年今日计划」)。
public enum OnThisDayPlanner {
    public enum Span: Int, Equatable, Codable, Sendable {
        case day = 1
        case week = 7
    }

    public struct Window: Equatable {
        public let yearsAgo: Int
        public let span: Span
        /// 窗口起点(那天 0 点,或那周首日 0 点)。
        public let from: Date
        /// 窗口终点(开区间)。
        public let to: Date
        /// 日桶里这段窗口的合计;日桶不可用时为 nil(不知道)。
        public let expected: Int?
    }

    /// 周窗口两侧各放宽几天:±3 = 7 天,"那年的这一周"。
    public static let weekHalfWidth = 3

    /// - Parameters:
    ///   - years: 往前探几年(1...years)。
    ///   - dailyCounts: 日桶("yyyy-MM-dd" → 条数);`synced == false` 时不看它(全部窗口都发、只看当天)。
    public static func plan(
        today: Date, years: Int, dailyCounts: [String: Int], synced: Bool,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> [Window] {
        guard years >= 1 else { return [] }
        var out: [Window] = []
        for yearsAgo in 1 ... years {
            guard let anchor = calendar.date(byAdding: .year, value: -yearsAgo, to: today) else { continue }
            let dayStart = calendar.startOfDay(for: anchor)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            if !synced {
                // 不知道哪天有记录:老办法,只看当天、每年都发。
                out.append(Window(yearsAgo: yearsAgo, span: .day, from: dayStart, to: dayEnd, expected: nil))
                continue
            }
            let dayCount = dailyCounts[dayKey(dayStart)] ?? 0
            if dayCount > 0 {
                out.append(Window(yearsAgo: yearsAgo, span: .day, from: dayStart, to: dayEnd, expected: dayCount))
                continue
            }
            guard let weekStart = calendar.date(byAdding: .day, value: -weekHalfWidth, to: dayStart),
                  let weekEnd = calendar.date(byAdding: .day, value: weekHalfWidth + 1, to: dayStart)
            else { continue }
            var weekCount = 0
            var cursor = weekStart
            while cursor < weekEnd {
                weekCount += dailyCounts[dayKey(cursor)] ?? 0
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            if weekCount > 0 {
                out.append(Window(yearsAgo: yearsAgo, span: .week, from: weekStart, to: weekEnd, expected: weekCount))
            }
        }
        return out
    }
}

/// 「收听足迹」——只从热力图日桶 + 账号总数派生的几条里程碑,零网络请求(2026-09-03)。
/// 给「那年今日」那一段垫底:那张卡一年里大半天是空的("那天没听"很正常),整段不能只剩一句
/// "没有记录"。所有算术在这里,好被 selftest 钉住;日桶只存非零天(见 IdleListeningStats)。
public enum ListeningMilestones {
    public struct DayCount: Equatable {
        public let day: String
        public let count: Int
        public init(day: String, count: Int) { self.day = day; self.count = count }
    }

    public struct Summary: Equatable {
        /// 最早有记录的一天;nil = 日桶为空。
        public let firstDay: String?
        /// 从第一天到今天(含两端)是第几天。
        public let daysSinceFirst: Int?
        /// 有记录的天数(日桶只存非零天,所以就是 count)。
        public let recordedDays: Int
        /// 单日最高。
        public let peak: DayCount?
        /// 到今天为止连续有记录的天数;今天还没记录时从昨天起算(今天还没过完)。
        public let currentStreak: Int
        /// 历史最长连续天数及其最后一天。
        public let longestStreak: Int
        public let longestStreakEnd: String?
        /// 今年 1 月 1 日到今天的合计。
        public let yearToDate: Int
        /// 最近一个"同一段日期区间(1 月 1 日 → 今天的月日)里有记录"的往年,及其合计——给"今年至今 vs 那年同期"用。
        public let priorYearSameSpan: (year: Int, count: Int)?

        /// 显式 public:合成的逐成员构造器是 internal,selftest(另一个 target)要构造期望值够不着。
        public init(firstDay: String?, daysSinceFirst: Int?, recordedDays: Int, peak: DayCount?,
                    currentStreak: Int, longestStreak: Int, longestStreakEnd: String?,
                    yearToDate: Int, priorYearSameSpan: (year: Int, count: Int)?) {
            self.firstDay = firstDay
            self.daysSinceFirst = daysSinceFirst
            self.recordedDays = recordedDays
            self.peak = peak
            self.currentStreak = currentStreak
            self.longestStreak = longestStreak
            self.longestStreakEnd = longestStreakEnd
            self.yearToDate = yearToDate
            self.priorYearSameSpan = priorYearSameSpan
        }

        public static func == (a: Summary, b: Summary) -> Bool {
            a.firstDay == b.firstDay && a.daysSinceFirst == b.daysSinceFirst && a.recordedDays == b.recordedDays
                && a.peak == b.peak && a.currentStreak == b.currentStreak && a.longestStreak == b.longestStreak
                && a.longestStreakEnd == b.longestStreakEnd && a.yearToDate == b.yearToDate
                && a.priorYearSameSpan?.year == b.priorYearSameSpan?.year && a.priorYearSameSpan?.count == b.priorYearSameSpan?.count
        }
    }

    /// 日桶键 "yyyy-MM-dd" ↔ Date(按 calendar 的时区,当天 0 点)。键的格式是建桶时定的,这里只解不造。
    static func parseDay(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps)
    }

    public static func summarize(
        dailyCounts: [String: Int], today: Date,
        calendar: Calendar = .current, dayKey: (Date) -> String
    ) -> Summary {
        let nonZero = dailyCounts.filter { $0.value > 0 }
        let keys = nonZero.keys.sorted() // "yyyy-MM-dd" 字典序即时间序
        let todayStart = calendar.startOfDay(for: today)
        let todayKey = dayKey(todayStart)

        // 起点与天数
        var daysSinceFirst: Int?
        if let first = keys.first, let firstDate = parseDay(first, calendar: calendar) {
            daysSinceFirst = (calendar.dateComponents([.day], from: firstDate, to: todayStart).day ?? 0) + 1
        }
        // 单日最高:同数取更早那天(稳定)
        var peak: DayCount?
        for k in keys {
            let v = nonZero[k]!
            if peak == nil || v > peak!.count { peak = DayCount(day: k, count: v) }
        }
        // 连续天数:按相邻键是否相差 1 天走一遍
        var longest = 0, longestEnd: String?
        var run = 0
        var prev: Date?
        for k in keys {
            guard let d = parseDay(k, calendar: calendar) else { continue }
            if let p = prev, let diff = calendar.dateComponents([.day], from: p, to: d).day, diff == 1 {
                run += 1
            } else {
                run = 1
            }
            if run > longest { longest = run; longestEnd = k }
            prev = d
        }
        // 当前连续:从今天(或昨天)往回数
        var current = 0
        var cursor = todayStart
        if (nonZero[todayKey] ?? 0) == 0, let y = calendar.date(byAdding: .day, value: -1, to: todayStart) {
            cursor = y // 今天还没记录不算断,从昨天起算
        }
        while (nonZero[dayKey(cursor)] ?? 0) > 0 {
            current += 1
            guard let prevDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prevDay
        }
        // 今年至今 / 往年同期
        let year = calendar.component(.year, from: todayStart)
        let monthDay = String(todayKey.dropFirst(5)) // "MM-dd"
        func spanTotal(_ y: Int) -> Int {
            let prefix = String(format: "%04d-", y)
            return nonZero.reduce(0) { acc, kv in
                guard kv.key.hasPrefix(prefix), String(kv.key.dropFirst(5)) <= monthDay else { return acc }
                return acc + kv.value
            }
        }
        let ytd = spanTotal(year)
        var prior: (year: Int, count: Int)?
        if let first = keys.first, let firstYear = Int(first.prefix(4)) {
            var y = year - 1
            while y >= firstYear {
                let t = spanTotal(y)
                if t > 0 { prior = (y, t); break }
                y -= 1
            }
        }
        return Summary(firstDay: keys.first, daysSinceFirst: daysSinceFirst, recordedDays: keys.count,
                       peak: peak, currentStreak: current, longestStreak: longest, longestStreakEnd: longestEnd,
                       yearToDate: ytd, priorYearSameSpan: prior)
    }

    /// 下一个整数里程碑:<1 000 按百、<10 000 按 500、之后按 1 000。total 正好落在整点上时算"刚达成",
    /// 返回下一个。
    public static func nextMilestone(total: Int) -> (target: Int, remaining: Int) {
        let step = total < 1_000 ? 100 : (total < 10_000 ? 500 : 1_000)
        let target = (total / step + 1) * step
        return (target, target - total)
    }
}
