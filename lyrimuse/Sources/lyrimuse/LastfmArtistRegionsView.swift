import AppKit
import LyrimuseCore
import SwiftUI

/// 「足迹」段的「歌手来自哪里」卡内容:每个国家或地区一行横条(占比 + 次数),下面一行是这个地区播放最多的几位。
///
/// 数据是引擎后台汇总的 `LastfmStatsService.artistRegions`(歌手榜前若干位,位数随文件给,按 MusicBrainz 登记的
/// 所属国家或地区加权),这里只画。范围选择器在卡头,由宿主持有(理由同 LastfmListeningHoursView)。
struct LastfmArtistRegionsView: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @Environment(\.colorScheme) private var colorScheme
    let span: ListeningHours.Span

    var body: some View {
        // 出现就读一次:统计页那条 2 分钟的定时刷新是先等再刷,只靠它的话页面打开后要空等两分钟。
        content.onAppear { stats.refreshArtistRegionsIfChanged() }
    }

    @ViewBuilder
    private var content: some View {
        if let p = stats.artistRegions[ArtistRegions.period(for: span)], p.covered > 0 {
            let rows = ArtistRegions.rows(p)
            let peak = max(1, rows.map(\.plays).max() ?? 1)
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        GridRow {
                            Text(label(row.kind))
                                .font(.callout)
                                .foregroundStyle(row.kind == .unresolved || row.kind == .pending ? .secondary : .primary)
                                .lineLimit(1)
                            bar(fraction: CGFloat(row.plays) / CGFloat(peak), color: color(row.kind, isTop: i == 0))
                            Text(Self.percent(row.plays, of: p.covered))
                                .font(.callout.weight(.semibold)).monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text(String(format: L10n.t("%@ 次"), row.plays.formatted()))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                        if !row.artists.isEmpty {
                            GridRow {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                Text(row.artists.joined(separator: L10n.t("、")))
                                    .font(.caption).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.tail)
                                    .gridCellColumns(3)
                            }
                            .padding(.bottom, 5)
                        }
                    }
                }
                if let note = footnote(p) {
                    Text(note)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else {
            Text(L10n.t("后台正在查歌手来自哪里，稍后会出现在这里"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    private func bar(fraction: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: max(2, geo.size.width * min(1, fraction)))
        }
        .frame(height: 9)
        .frame(maxWidth: .infinity)
    }

    private func label(_ kind: ArtistRegions.Row.Kind) -> String {
        switch kind {
        case .region(let code): return L10n.locale.localizedString(forRegionCode: code) ?? code
        case .other: return L10n.t("其他")
        case .pending: return L10n.t("还在查")
        case .unresolved: return L10n.t("未查到")
        }
    }

    private func color(_ kind: ArtistRegions.Row.Kind, isTop: Bool) -> Color {
        guard case .region = kind else { return Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.18) }
        let levels = (colorScheme == .dark ? LastfmHeatmapView.darkLevels : LastfmHeatmapView.lightLevels)
            .compactMap { NSColor(hexStringWithAlpha: $0 + "FF").map(Color.init) }
        guard levels.count == 4 else { return .green }
        return isTop ? levels[3] : levels[2]
    }

    /// 占比:≥10% 取整,不足 10% 留一位小数(2.1% 取整成 2% 会跟 2.4% 分不开)。
    static func percent(_ plays: Int, of covered: Int) -> String {
        guard covered > 0 else { return "" }
        let r = Double(plays) / Double(covered)
        return r.formatted(.percent.precision(.fractionLength(r >= 0.1 ? 0 : 1)).locale(L10n.locale))
    }

    /// 「按前 N 位歌手统计」(N 是引擎写进文件的位数,老文件没写就不显示这一句);日桶同步好了再补「占这段时间
    /// X% 的收听」(日桶按本地天算,跟 Last.fm 的滚动窗口差不到一天,只作说明用)。
    private func footnote(_ p: ArtistRegions.Period) -> String? {
        guard p.topArtists > 0 else { return nil }
        let total = spanTotal()
        guard total > 0, !stats.dailyFullSyncing else {
            return String(format: L10n.t("按听得最多的前 %@ 位歌手统计"), "\(p.topArtists)")
        }
        return String(format: L10n.t("按听得最多的前 %1$@ 位歌手统计，占这段时间 %2$@ 的收听"),
                      "\(p.topArtists)", Self.percent(min(p.covered, total), of: total))
    }

    private func spanTotal() -> Int {
        let days: Int? = switch span {
        case .month: 30
        case .year: 365
        case .overall: nil
        }
        guard let days else { return stats.dailyCounts.values.reduce(0, +) }
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date())) else { return 0 }
        let cutoff = LastfmStatsService.dayKey(start)
        return stats.dailyCounts.reduce(0) { $0 + ($1.key >= cutoff ? $1.value : 0) }
    }
}
