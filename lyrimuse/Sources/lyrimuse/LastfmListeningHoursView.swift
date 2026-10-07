import AppKit
import LyrimuseCore
import SwiftUI

/// 「足迹」段的收听时段卡内容:一天 24 小时一张条形图、一周 7 天一张条形图,卡底一行结论。
///
/// 数据是 `LastfmStatsService.hourlyCounts`(跟热力图日桶同一次历史扫描写入),汇总在 Core
/// `ListeningHours.summarize`。范围选择器在卡头,由宿主持有,跟热力图的年份选择器同一个理由:
/// 卡收起时这个 View 不在视图层级里。
struct LastfmListeningHoursView: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @Environment(\.colorScheme) private var colorScheme
    let span: ListeningHours.Span

    private static let hourChartHeight: CGFloat = 96
    /// 条形上方留给悬停气泡的空,最高那根的气泡也不出图。
    private static let bubbleHeadroom: CGFloat = 24

    /// 鼠标所在的那一列(整列都算,矮条不用对准)。
    @State private var hoverHour: Int?
    @State private var bubbleWidth: CGFloat = 0

    var body: some View {
        if let s = ListeningHours.summarize(hourly: stats.hourlyCounts, span: span, today: Date(),
                                            dayKey: { LastfmStatsService.dayKey($0) }) {
            VStack(alignment: .leading, spacing: 14) {
                hourChart(s)
                weekdayChart(s)
                summaryLine(s)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else {
            Text(L10n.t("此期间暂无收听记录"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    private func hourChart(_ s: ListeningHours.Summary) -> some View {
        let peak = max(1, s.hours.max() ?? 1)
        let barHeight = { (h: Int) in max(1, Self.hourChartHeight * CGFloat(s.hours[h]) / CGFloat(peak)) }
        return VStack(spacing: 3) {
            GeometryReader { geo in
                let slot = geo.size.width / CGFloat(ListeningHours.hoursPerDay)
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<ListeningHours.hoursPerDay, id: \.self) { h in
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                                .fill(h == s.peakHour || h == hoverHour ? strongColor : barColor)
                                .opacity(hoverHour == nil || hoverHour == h ? 1 : 0.45)
                                .frame(maxWidth: .infinity)
                                .frame(height: barHeight(h))
                        }
                    }
                    .frame(width: geo.size.width, height: Self.hourChartHeight, alignment: .bottom)
                    .overlay(alignment: .bottom) { Divider() }
                    .offset(y: Self.bubbleHeadroom)
                    if let h = hoverHour {
                        hourBubble(h, count: s.hours[h])
                            .position(
                                // 贴着柱顶;左右夹在图内,两端那几根的气泡不被裁掉。
                                x: min(max(slot * (CGFloat(h) + 0.5), bubbleWidth / 2), geo.size.width - bubbleWidth / 2),
                                y: max(10, Self.bubbleHeadroom + Self.hourChartHeight - barHeight(h) - 12))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        hoverHour = min(ListeningHours.hoursPerDay - 1, max(0, Int(p.x / slot)))
                    case .ended:
                        hoverHour = nil
                    }
                }
            }
            .frame(height: Self.bubbleHeadroom + Self.hourChartHeight)
            .animation(nil, value: hoverHour)
            HStack(spacing: 2) {
                ForEach(0..<ListeningHours.hoursPerDay, id: \.self) { h in
                    Text(verbatim: h % 3 == 0 ? "\(h)" : "")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L10n.t("收听高峰 %@"), hourText(s.peakHour)))
    }

    private func hourBubble(_ h: Int, count: Int) -> some View {
        Text(String(format: L10n.plural("%1$@–%2$@ 点 · %3$@ 次", count: count), "\(h)", "\(h + 1)", count.formatted()))
            .font(.caption.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.preference(key: HourBubbleWidthKey.self, value: g.size.width)
            })
            .onPreferenceChange(HourBubbleWidthKey.self) { bubbleWidth = $0 }
    }

    private func weekdayChart(_ s: ListeningHours.Summary) -> some View {
        let peak = max(1, s.weekdays.max() ?? 1)
        let names = Self.weekdayNames
        return VStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 8) {
                    Text(names[d])
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(width: 36, alignment: .leading)
                    GeometryReader { geo in
                        UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3, style: .continuous)
                            .fill(d == s.peakWeekday ? strongColor : barColor)
                            .frame(width: max(1, geo.size.width * CGFloat(s.weekdays[d]) / CGFloat(peak)))
                    }
                    .frame(height: 9)
                    Text(s.weekdays[d].formatted())
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .help(String(format: L10n.plural("%1$@ · %2$@ 次", count: s.weekdays[d]), names[d], s.weekdays[d].formatted()))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L10n.t("收听最多 %@"), names[s.peakWeekday]))
    }

    private func summaryLine(_ s: ListeningHours.Summary) -> some View {
        HStack(spacing: 14) {
            Text(emphasized(L10n.t("收听高峰 %@"), hourText(s.peakHour)))
            Text(emphasized(L10n.t("收听最多 %@"), Self.weekdayNames[s.peakWeekday]))
            Text(emphasized(L10n.t("收听最少 %@"), hourText(s.quietestHour)))
            Text(String(format: L10n.plural("共 %@ 次", count: s.total), s.total.formatted()))
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    /// 格式串里的 `%@` 换成加粗、主色的值,其余保持次要色。
    private func emphasized(_ format: String, _ value: String) -> AttributedString {
        let parts = format.components(separatedBy: "%@")
        var out = AttributedString(parts.first ?? "")
        var v = AttributedString(value)
        v.font = .caption.weight(.semibold)
        v.foregroundColor = .primary
        out += v
        out += AttributedString(parts.dropFirst().joined(separator: "%@"))
        return out
    }

    private func hourText(_ h: Int) -> String {
        String(format: L10n.t("%@ 点"), "\(h)")
    }

    /// 周一在前,跟 Summary.weekdays 的下标一致。星期名跟着 App 语言走,不跟系统语言。
    private static var weekdayNames: [String] {
        let f = DateFormatter()
        f.locale = L10n.locale
        let sundayFirst = f.shortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        return Array(sundayFirst[1...]) + [sundayFirst[0]]
    }

    private var levels: [Color] {
        (colorScheme == .dark ? LastfmHeatmapView.darkLevels : LastfmHeatmapView.lightLevels)
            .compactMap { NSColor(hexStringWithAlpha: $0 + "FF").map(Color.init) }
    }
    private var barColor: Color { levels.count == 4 ? levels[2] : .green }
    private var strongColor: Color { levels.count == 4 ? levels[3] : .green }
}

private struct HourBubbleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
