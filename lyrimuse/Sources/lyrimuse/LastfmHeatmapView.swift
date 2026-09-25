import SwiftUI

/// Last.fm 播放热力图(GitHub 贡献图风格):列=周、行=周一到周日、色深=当日播放量。
/// 画在「足迹」段第一张卡的卡身里(见 LastfmStatsSection.heatmapCard),卡头那颗年份
/// 选择器改的就是 `year`。
///
/// 数据是 LastfmStatsService.dailyCounts(本地时区的天粒度桶,全量历史缓存+增量同步,
/// 见 refreshDailyCounts 注释)。这里只做展示:按年切片、算色阶、排格子。
struct LastfmHeatmapView: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @Environment(\.colorScheme) private var colorScheme
    /// 要画哪一年。宿主持有 —— 年份选择器在卡头那一段,不在这个 View 的层级里。
    @Binding var year: Int
    /// 量到的卡身宽度,格子边长按它反算(见 cellSize)。首帧量不到,先按保守档画。
    @State private var width: CGFloat = 0

    // GitHub 的两套官方色阶(浅/深色模式),第 0 档(零播放)用系统填充色融入设置页背景。
    private static let lightLevels = ["#9be9a8", "#40c463", "#30a14e", "#216e39"]
    private static let darkLevels = ["#0e4429", "#006d32", "#26a641", "#39d353"]

    /// 有记录的年份 + 今年,倒序。宿主画年份选择器要用,所以是 static —— 这个 View
    /// 收起时根本不在视图层级里,而卡头一直在。
    static func availableYears(in dailyCounts: [String: Int]) -> [Int] {
        let ys = Set(dailyCounts.keys.compactMap { Int($0.prefix(4)) })
        let current = Calendar.current.component(.year, from: Date())
        return ys.union([current]).sorted(by: >)
    }

    /// 默认选最近一个**有数据**的年份——当前年可能还全空(刚换账号/年初)。
    static func defaultYear(in dailyCounts: [String: Int]) -> Int {
        let years = availableYears(in: dailyCounts)
        let fallback = Calendar.current.component(.year, from: Date())
        return years.first(where: { y in
            dailyCounts.contains { $0.key.hasPrefix("\(y)-") && $0.value > 0 }
        }) ?? years.first ?? fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            grid
            HStack(spacing: 10) {
                if stats.dailySyncing {
                    ProgressView().controlSize(.small)
                    Text(stats.dailySyncProgress ?? L10n.t("正在同步…"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if stats.dailySyncFailed {
                    Text(L10n.t("同步失败")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.t("重试")) { stats.refreshDailyCounts() }
                        .controlSize(.small)
                } else {
                    Text(String(format: L10n.t("%1$@ 年共 %2$@ 次"), "\(year)", yearTotal.formatted()))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Text(L10n.t("少")).font(.caption2).foregroundStyle(.tertiary)
                HStack(spacing: 3) {
                    cellShape(fill: emptyColor)
                    ForEach(levelColors, id: \.self) { c in cellShape(fill: c) }
                }
                Text(L10n.t("多")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 12)
        // 量的是**卡身给出来的**宽度,不是内容自己撑开的宽度 —— 所以 GeometryReader 挂在
        // `.frame(maxWidth: .infinity)` 之后的 background 里。挂在里层会绕成一个环:格子边长
        // 由宽度算、宽度又由格子撑出来,量到多少就锁死在多少。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: HeatmapWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(HeatmapWidthKey.self) { width = $0 }
        .onAppear { stats.refreshDailyCounts() }
    }

    // MARK: - 网格

    private static let horizontalPadding: CGFloat = 14
    /// 一年最多跨 53 个周列。**按这个常数算边长,不按当年真实列数** —— 今年只画到今天
    /// (列数不满),按真实列数算的话今年的格子会比往年大一圈,切年份时整幅图跳一下。
    private static let columnCount = 53
    private static let cellGap: CGFloat = 2
    private static let weekdayLabelWidth: CGFloat = 12
    private static let maxCell: CGFloat = 11
    private static let minCell: CGFloat = 5
    private static let fallbackCell: CGFloat = 7

    /// 格子边长按可用宽度反算。**别钉回固定值**:53 列 ×(11+3)要 750pt,而这张卡所在的
    /// 卡片列上限只有 600pt(SettingsPage.maxCardColumnWidth)、窄窗口下更小,钉死的结果是
    /// 右边小半年被卡片裁掉。取半像素栅格是因为非整数边长会让相邻格子的边界落到不同物理
    /// 像素上,看着一大一小。
    private var cellSize: CGFloat {
        guard width > 0 else { return Self.fallbackCell }
        let columns = CGFloat(Self.columnCount)
        // 列间 52 档 + 星期标签列后面那一档 = 53 档
        let forCells = width - 2 * Self.horizontalPadding - Self.weekdayLabelWidth
            - Self.cellGap * columns
        let raw = ((forCells / columns) * 2).rounded(.down) / 2
        return min(Self.maxCell, max(Self.minCell, raw))
    }

    private var grid: some View {
        let weeks = weekColumns(year: year)
        let thresholds = levelThresholds(year: year)
        let cell = cellSize
        return VStack(alignment: .leading, spacing: 3) {
            // 月份标签行:在包含每月 1 号的那一列上方标注。标签宽度超出列宽,靠
            // fixedSize 溢出绘制、不推挤布局;相邻月至少隔 4 列,不会叠字。
            HStack(spacing: Self.cellGap) {
                // 这一格不能省:下面那行格子的左边还有星期标签列,不给同宽的占位,
                // 整行月份标签就会**左移一列**,「1 月」压在星期标签上方。
                Color.clear.frame(width: Self.weekdayLabelWidth, height: 1)
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    Text(week.monthLabel ?? " ")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: cell, alignment: .leading)
                }
            }
            .frame(height: 10)
            HStack(alignment: .top, spacing: Self.cellGap) {
                // 星期标签列(周一起始;只标一/三/五,GitHub 同款疏密)
                VStack(spacing: Self.cellGap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row == 0 ? L10n.t("一") : row == 2 ? L10n.t("三") : row == 4 ? L10n.t("五") : " ")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .frame(width: Self.weekdayLabelWidth, height: cell)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: Self.cellGap) {
                        ForEach(0..<7, id: \.self) { row in
                            if let day = week.days[row] {
                                let n = stats.dailyCounts[day.key] ?? 0
                                cellShape(fill: color(for: n, thresholds: thresholds))
                                    .help("\(day.label) · \(n.formatted()) \(L10n.t("次"))")
                            } else {
                                // 年头/年尾不属于本年的格子:占位保持列对齐,完全透明。
                                cellShape(fill: .clear)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cellShape(fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .frame(width: cellSize, height: cellSize)
    }

    // MARK: - 数据切片

    private struct WeekColumn {
        var days: [DayCell?] // 7 格,周一=0
        var monthLabel: String?
    }
    private struct DayCell {
        var key: String   // "yyyy-MM-dd"
        var label: String // 悬停提示里的人话日期
    }

    /// 把一年切成周列(周一起始)。只生成 1/1 到 12/31(未来的天不生成格子)。
    private func weekColumns(year: Int) -> [WeekColumn] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // 周一
        guard let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let dec31 = cal.date(from: DateComponents(year: year, month: 12, day: 31))
        else { return [] }
        let today = cal.startOfDay(for: Date())
        let end = min(dec31, today)
        // 回退到 1/1 所在周的周一
        var cursor = cal.startOfDay(for: jan1)
        let weekdayRow = { (d: Date) -> Int in (cal.component(.weekday, from: d) + 5) % 7 } // 周一=0
        cursor = cal.date(byAdding: .day, value: -weekdayRow(cursor), to: cursor) ?? cursor
        var weeks: [WeekColumn] = []
        var lastLabeledMonth = 0
        while cursor <= end {
            var days: [DayCell?] = Array(repeating: nil, count: 7)
            var label: String?
            for row in 0..<7 {
                guard let d = cal.date(byAdding: .day, value: row, to: cursor) else { continue }
                let comps = cal.dateComponents([.year, .month, .day], from: d)
                guard comps.year == year, d <= end else { continue }
                days[row] = DayCell(
                    key: LastfmStatsService.dayKey(d),
                    label: String(format: L10n.t("%1$@ 年 %2$@ 月 %3$@ 日"),
                                  "\(comps.year!)", "\(comps.month!)", "\(comps.day!)"))
                if comps.day! <= 7, comps.month! != lastLabeledMonth {
                    label = String(format: L10n.t("%@ 月"), "\(comps.month!)")
                    lastLabeledMonth = comps.month!
                }
            }
            weeks.append(WeekColumn(days: days, monthLabel: label))
            cursor = cal.date(byAdding: .day, value: 7, to: cursor) ?? end.addingTimeInterval(1)
        }
        return weeks
    }

    /// GitHub 的色阶取法:非零值的四分位数当三道门槛。全年才几个不同值时(刚起步)
    /// 四分位会挤在一起,门槛去重兜底。
    private func levelThresholds(year: Int) -> [Int] {
        let prefix = "\(year)-"
        let values = stats.dailyCounts.filter { $0.key.hasPrefix(prefix) && $0.value > 0 }
            .map(\.value).sorted()
        guard !values.isEmpty else { return [1, 2, 3] }
        func q(_ p: Double) -> Int { values[min(values.count - 1, Int(Double(values.count) * p))] }
        var t = [q(0.25), q(0.5), q(0.75)]
        for i in 1..<3 where t[i] <= t[i - 1] { t[i] = t[i - 1] + 1 }
        return t
    }

    private var levelColors: [Color] {
        (colorScheme == .dark ? Self.darkLevels : Self.lightLevels)
            .compactMap { NSColor(hexStringWithAlpha: $0 + "FF").map(Color.init) }
    }
    private var emptyColor: Color { Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07) }

    private func color(for count: Int, thresholds: [Int]) -> Color {
        guard count > 0 else { return emptyColor }
        let levels = levelColors
        if count <= thresholds[0] { return levels[0] }
        if count <= thresholds[1] { return levels[1] }
        if count <= thresholds[2] { return levels[2] }
        return levels[3]
    }

    private var yearTotal: Int {
        let prefix = "\(year)-"
        return stats.dailyCounts.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
    }
}

private struct HeatmapWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
