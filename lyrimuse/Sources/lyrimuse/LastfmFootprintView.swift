import AppKit
import LyrimuseCore
import SwiftUI

/// Last.fm 详情页「足迹」段:上半一组大小不一的玻璃方块(当前连续做主角,里程碑、今年至今、单日最高、起点、总数)加一块
/// 热力图;下半「什么时候听、听谁」两块并排的摘要(收听时段、歌手地区),点开一块换成整宽的完整图表;最后是那年今日。
/// 两块摘要共用一颗范围切换。数据全部来自 LastfmStatsService,这里只画。见 12 章决策 63。
struct LastfmFootprintView: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @Environment(\.colorScheme) private var colorScheme
    /// 热力图年份,0 = 最近一个有数据的年。宿主(常驻的 LastfmStatsSection)持有,切到别的段再回来不重置。
    @Binding var heatmapYear: Int
    @AppStorage("np:lastfmHoursSpan") private var spanRaw = ListeningHours.Span.month.rawValue
    /// 点开成整宽的那块摘要,空串 = 两块都是摘要。
    @AppStorage("np:lastfmFootprintDetail") private var detailRaw = ""

    private enum Detail: String { case hours, regions }

    static let tileSpacing: CGFloat = 10

    private var span: ListeningHours.Span { ListeningHours.Span(rawValue: spanRaw) ?? .month }
    private var detail: Detail? { Detail(rawValue: detailRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.tileSpacing) {
            sectionTitle(L10n.t("收听足迹"))
            milestoneTiles
            heatmapTile
            HStack(alignment: .center, spacing: 8) {
                sectionTitle(L10n.t("什么时候听、听谁"))
                Spacer(minLength: 8)
                SettingsPillSegmentedControl(
                    selection: Binding(get: { span }, set: { spanRaw = $0.rawValue }),
                    options: ListeningHours.Span.allCases,
                    label: Self.spanLabel
                )
            }
            .padding(.top, 10)
            whenWhoTiles
            onThisDayTile
        }
        // 玻璃的样子取决于背后有什么:窗口底色是一整片纯色,方块压在上面只是一层浅灰。垫几团很淡的色光给它折射。
        .background { LastfmGlassGlow() }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .padding(.horizontal, 4)
    }

    // MARK: - 收听足迹

    /// 全部从热力图日桶 + 账号总数派生(ListeningMilestones,Core 纯函数),零请求;日桶还在首次全量同步时不算,
    /// 那时算出来的日均、连续都是残缺数据上的假数。
    @ViewBuilder
    private var milestoneTiles: some View {
        if stats.dailyFullSyncing || stats.dailyCounts.isEmpty {
            FootprintTile {
                HStack(spacing: 8) {
                    if stats.dailyFullSyncing { ProgressView().controlSize(.small) }
                    Text(L10n.t("首次同步历史记录后，将在此显示收听足迹"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        } else {
            let sum = ListeningMilestones.summarize(
                dailyCounts: stats.dailyCounts, today: Date(),
                dayKey: { LastfmStatsService.dayKey($0) })
            VStack(spacing: Self.tileSpacing) {
                HStack(alignment: .top, spacing: Self.tileSpacing) {
                    streakTile(sum)
                    VStack(spacing: Self.tileSpacing) {
                        milestoneTile
                        HStack(spacing: Self.tileSpacing) {
                            yearToDateTile(sum)
                            peakTile(sum)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Self.tileSpacing) {
                    sinceTile(sum)
                    totalTile
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func streakTile(_ sum: ListeningMilestones.Summary) -> some View {
        let n = sum.currentStreak.formatted()
        return FootprintTile {
            VStack(alignment: .leading, spacing: 0) {
                tileLabel(L10n.t("当前连续"), icon: "flame.fill", tint: .orange)
                headline(String(format: L10n.plural("%@ 天", count: sum.currentStreak), n), number: n, size: 40)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 1) {
                    if sum.currentStreak > 0, sum.currentStreak == sum.longestStreak {
                        Text(L10n.t("这也是你最长的一次连续"))
                    } else {
                        Text(String(format: L10n.plural("最长 %@ 天", count: sum.longestStreak), sum.longestStreak.formatted()))
                    }
                    if let today = stats.overview?.today {
                        Text(String(format: L10n.plural("今天已听 %@ 次", count: today), today.formatted()))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                Spacer(minLength: 14)
                recentDaysStrip
            }
        }
    }

    /// 最近 14 天每天一个点,今天在最右、外面套一圈。
    private var recentDaysStrip: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days: [(key: String, count: Int)] = (0..<14).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let key = LastfmStatsService.dayKey(d)
            return (key, stats.dailyCounts[key] ?? 0)
        }
        let on = greens.last ?? .green
        return HStack(spacing: 5) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                Circle()
                    .fill(day.count > 0 ? on : Color.primary.opacity(0.09))
                    .overlay {
                        if i == days.count - 1 { Circle().stroke(on, lineWidth: 1.5).padding(-3) }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 14)
                    .help(String(format: L10n.plural("%1$@ · %2$@ 次", count: day.count),
                                 Self.dayLabel(day.key), day.count.formatted()))
            }
        }
        .padding(.horizontal, 3)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var milestoneTile: some View {
        FootprintTile {
            HStack(spacing: 12) {
                if let total = stats.overview?.total, total > 0 {
                    let next = ListeningMilestones.nextMilestone(total: total)
                    let remaining = next.remaining.formatted()
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.1), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: CGFloat(ListeningMilestones.milestoneProgress(total: total)))
                            .stroke(greens.count == 4 ? greens[2] : .green,
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 44, height: 44)
                    .padding(3)
                    VStack(alignment: .leading, spacing: 2) {
                        tileLabel(L10n.t("下一个里程碑"))
                        headline(String(format: L10n.t("还需 %@ 次"), remaining), number: remaining, size: 22)
                        Text(String(format: L10n.t("到第 %@ 次 Scrobble"), next.target.formatted()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        tileLabel(L10n.t("下一个里程碑"))
                        Text(verbatim: "—").font(.system(size: 22, weight: .bold, design: .rounded))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func yearToDateTile(_ sum: ListeningMilestones.Summary) -> some View {
        let n = sum.yearToDate.formatted()
        return FootprintTile {
            VStack(alignment: .leading, spacing: 2) {
                tileLabel(L10n.t("今年至今"))
                headline(String(format: L10n.plural("%@ 次收听", count: sum.yearToDate), n), number: n, size: 22)
                if let prior = sum.priorYearSameSpan {
                    Text(String(format: L10n.t("%1$@ 年同期 %2$@ 次"), "\(prior.year)", prior.count.formatted()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func peakTile(_ sum: ListeningMilestones.Summary) -> some View {
        FootprintTile {
            VStack(alignment: .leading, spacing: 2) {
                tileLabel(L10n.t("单日最高"))
                if let peak = sum.peak {
                    let n = peak.count.formatted()
                    headline(String(format: L10n.plural("%@ 次收听", count: peak.count), n), number: n, size: 22)
                    Text(Self.dayLabel(peak.day)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sinceTile(_ sum: ListeningMilestones.Summary) -> some View {
        let avg = IdleListeningStats.dailyAverage(dailyCounts: stats.dailyCounts)?.average ?? 0
        return FootprintTile {
            VStack(alignment: .leading, spacing: 2) {
                if let days = sum.daysSinceFirst, let first = sum.firstDay {
                    let n = days.formatted()
                    tileLabel(String(format: L10n.t("自 %@ 起"), Self.dayLabel(first)))
                    headline(String(format: L10n.t("第 %@ 天"), n), number: n, size: 22)
                }
                Text(String(format: L10n.plural("其中 %1$@ 天有记录，日均 %2$@ 次", count: sum.recordedDays),
                            sum.recordedDays.formatted(), avg.formatted()))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var totalTile: some View {
        FootprintTile {
            VStack(alignment: .leading, spacing: 2) {
                tileLabel(L10n.t("总 Scrobble"))
                if let total = stats.overview?.total {
                    let n = total.formatted()
                    headline(String(format: L10n.plural("%@ 次收听", count: total), n), number: n, size: 22)
                } else {
                    Text(verbatim: "—").font(.system(size: 22, weight: .bold, design: .rounded))
                }
                // 「近 7 天」跟统计段、待机页同一个口径(自然日对齐,IdleListeningStats.lastSevenDays)。
                let week = IdleListeningStats.lastSevenDays(
                    dailyCounts: stats.dailyCounts, today: Date(),
                    todayCount: stats.overview?.today,
                    dayKey: { LastfmStatsService.dayKey($0) })
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())
                    .map { stats.dailyCounts[LastfmStatsService.dayKey($0)] ?? 0 } ?? 0
                Text(String(format: L10n.t("近 7 天 %1$@ 次 · 昨天 %2$@ 次"), week.formatted(), yesterday.formatted()))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 播放热力图

    private var heatmapTile: some View {
        FootprintTile(padded: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    tileLabel(L10n.t("播放热力图"), icon: "square.grid.3x3.fill")
                    Spacer(minLength: 8)
                    heatmapYearPicker
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                LastfmHeatmapView(year: heatmapYearBinding)
            }
        }
    }

    /// 读的时候把 0 折成"最近一个有数据的年":刚换账号 / 年初时今年可能一格都没有。
    private var heatmapYearBinding: Binding<Int> {
        Binding(
            get: { heatmapYear != 0 ? heatmapYear : LastfmHeatmapView.defaultYear(in: stats.dailyCounts) },
            set: { heatmapYear = $0 }
        )
    }

    /// 年数少时用玻璃分段,多了换玻璃下拉:分段的宽度随段数长,听了十几年的账号会把方块头撑出去。
    @ViewBuilder
    private var heatmapYearPicker: some View {
        let years = LastfmHeatmapView.availableYears(in: stats.dailyCounts)
        if years.count <= 8 {
            SettingsGlassTabPicker(selection: heatmapYearBinding, options: years, label: { "\($0)" }, compact: true)
        } else {
            SettingsGlassMenuPicker(selection: heatmapYearBinding, options: years, label: { "\($0)" }, compact: true)
        }
    }

    // MARK: - 什么时候听、听谁

    @ViewBuilder
    private var whenWhoTiles: some View {
        switch detail {
        // 点开的那块换成整宽图表,下面排的是**另一块**的摘要。
        case .hours:
            detailTile(.hours)
            regionsSummaryTile
        case .regions:
            detailTile(.regions)
            hoursSummaryTile
        case nil:
            HStack(alignment: .top, spacing: Self.tileSpacing) {
                hoursSummaryTile
                regionsSummaryTile
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setDetail(_ d: Detail?) {
        withAnimation(.settingsCardReveal) { detailRaw = d?.rawValue ?? "" }
    }

    /// 摘要方块整块可点,点开换成整宽的完整图表。
    private func summaryButton<Content: View>(_ d: Detail, @ViewBuilder content: () -> Content) -> some View {
        let body = content()
        return Button { setDetail(d) } label: {
            FootprintTile(interactive: true) {
                VStack(alignment: .leading, spacing: 0) {
                    body
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("展开"))
    }

    private func summaryHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            tileLabel(title, icon: icon)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var hoursSummaryTile: some View {
        if !stats.dailyFullSyncing, !stats.hourlyCounts.isEmpty {
            summaryButton(.hours) {
                summaryHeader(L10n.t("收听时段"), icon: "clock")
                if let s = ListeningHours.summarize(hourly: stats.hourlyCounts, span: span, today: Date(),
                                                    dayKey: { LastfmStatsService.dayKey($0) }) {
                    let hour = "\(s.peakHour)"
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        headline(String(format: L10n.t("%@ 点"), hour), number: hour, size: 22)
                        Text(L10n.t("收听高峰")).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                    miniHourBars(s)
                        .frame(height: 52)
                        .padding(.top, 10)
                    Text(String(format: L10n.t("收听最多 %@"), LastfmListeningHoursView.weekdayNames[s.peakWeekday]))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    Text(L10n.t("此期间暂无收听记录"))
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        } else {
            FootprintTile {
                VStack(alignment: .leading, spacing: 8) {
                    tileLabel(L10n.t("收听时段"), icon: "clock")
                    HStack(spacing: 8) {
                        if stats.dailyFullSyncing { ProgressView().controlSize(.small) }
                        Text(L10n.t("首次同步历史记录后，将在此显示收听时段"))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func miniHourBars(_ s: ListeningHours.Summary) -> some View {
        let peak = max(1, s.hours.max() ?? 1)
        let bar = greens.count == 4 ? greens[2] : .green
        let strong = greens.last ?? .green
        return GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<ListeningHours.hoursPerDay, id: \.self) { h in
                    UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5, style: .continuous)
                        .fill(h == s.peakHour ? strong : bar)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(1.5, geo.size.height * CGFloat(s.hours[h]) / CGFloat(peak)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L10n.t("收听高峰 %@"), String(format: L10n.t("%@ 点"), "\(s.peakHour)")))
    }

    /// 地区摘要的四个颜色:比例条要分得开,所以不用热力图那一套同色深浅。
    private static let regionColors: [Color] = [.blue, .orange, .green, .purple]

    @ViewBuilder
    private var regionsSummaryTile: some View {
        Group {
            if let p = stats.artistRegions[ArtistRegions.period(for: span)], p.covered > 0 {
                let segments = regionSegments(p)
                summaryButton(.regions) {
                    summaryHeader(L10n.t("歌手地区分布"), icon: "globe.asia.australia")
                    if let first = p.regions.first(where: { $0.plays > 0 }) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.regionName(first.code))
                                .font(.system(size: 22, weight: .bold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(LastfmArtistRegionsView.percent(first.plays, of: p.covered))
                                .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    regionShareBar(segments)
                        .frame(height: 10)
                        .padding(.top, 10)
                    regionLegend(segments, covered: p.covered)
                        .padding(.top, 10)
                }
            } else {
                FootprintTile {
                    VStack(alignment: .leading, spacing: 8) {
                        tileLabel(L10n.t("歌手地区分布"), icon: "globe.asia.australia")
                        Text(L10n.t("正在查询歌手所属地区，稍后将在此显示"))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        // 出现就读一次:统计页那条 2 分钟的定时刷新是先等再刷,只靠它的话页面打开后要空等两分钟。
        .onAppear { stats.refreshArtistRegionsIfChanged() }
    }

    /// 比例条和图例的一段:前四个地区各一段,其余地区并成「其他」,还没查完的「查询中」和查不到国家的「未查到」各自单列。
    private struct RegionSegment {
        var name: String
        var plays: Int
        var color: Color
        var help: String
        var muted = false
    }

    private func regionSegments(_ p: ArtistRegions.Period) -> [RegionSegment] {
        let regions = p.regions.filter { $0.plays > 0 }
        var out = regions.prefix(Self.regionColors.count).enumerated().map { i, r in
            RegionSegment(name: Self.regionName(r.code), plays: r.plays, color: Self.regionColors[i],
                          help: r.artists.joined(separator: L10n.t("、")))
        }
        let rest = regions.dropFirst(Self.regionColors.count)
        let restPlays = rest.reduce(0) { $0 + $1.plays }
        if restPlays > 0 {
            // 悬停列出并进来的每个地区和占比,按次数从多到少。
            let list = rest.map { "\(Self.regionName($0.code)) \(LastfmArtistRegionsView.percent($0.plays, of: p.covered))" }
            out.append(RegionSegment(name: L10n.t("其他"), plays: restPlays,
                                     color: Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                     help: list.joined(separator: L10n.t("、"))))
        }
        let unknownColor = Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
        if p.pending > 0 {
            out.append(RegionSegment(name: L10n.t("查询中"), plays: p.pending, color: unknownColor,
                                     help: p.pendingArtists.prefix(6).joined(separator: L10n.t("、")), muted: true))
        }
        if p.unresolved > 0 {
            out.append(RegionSegment(name: L10n.t("未查到"), plays: p.unresolved, color: unknownColor,
                                     help: p.unresolvedArtists.prefix(6).joined(separator: L10n.t("、")), muted: true))
        }
        return out
    }

    private func regionShareBar(_ segments: [RegionSegment]) -> some View {
        let total = CGFloat(max(1, segments.reduce(0) { $0 + $1.plays }))
        let gaps = CGFloat(max(0, segments.count - 1)) * 2
        return GeometryReader { geo in
            let usable = max(0, geo.size.width - gaps)
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.color)
                        .frame(width: usable * CGFloat(s.plays) / total)
                }
            }
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }

    private func regionLegend(_ segments: [RegionSegment], covered: Int) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(stride(from: 0, to: segments.count, by: 2)), id: \.self) { start in
                GridRow {
                    legendCell(start, segments: segments, covered: covered)
                    legendCell(start + 1, segments: segments, covered: covered)
                }
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func legendCell(_ i: Int, segments: [RegionSegment], covered: Int) -> some View {
        if i < segments.count {
            let s = segments[i]
            legendItem(color: s.color, name: s.name,
                       share: LastfmArtistRegionsView.percent(s.plays, of: covered), muted: s.muted)
                .help(s.help)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func legendItem(color: Color, name: String, share: String, muted: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(color).frame(width: 9, height: 9)
            Text(name).lineLimit(1).foregroundStyle(muted ? .secondary : .primary)
            Spacer(minLength: 4)
            Text(share).fontWeight(.semibold).monospacedDigit().foregroundStyle(muted ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity)
        // 整格都能悬停,不只是文字那一小块。
        .contentShape(Rectangle())
    }

    private static func regionName(_ code: String) -> String {
        L10n.locale.localizedString(forRegionCode: code) ?? code
    }

    /// 点开后的整宽方块:里面就是原来那两张卡的完整内容,头部整行可点、收回摘要。
    private func detailTile(_ d: Detail) -> some View {
        FootprintTile(padded: false) {
            VStack(alignment: .leading, spacing: 0) {
                Button { setDetail(nil) } label: {
                    HStack(spacing: 6) {
                        switch d {
                        case .hours: tileLabel(L10n.t("收听时段"), icon: "clock")
                        case .regions: tileLabel(L10n.t("歌手地区分布"), icon: "globe.asia.australia")
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("收起"))
                switch d {
                case .hours:
                    LastfmListeningHoursView(span: span)
                case .regions:
                    LastfmArtistRegionsView(span: span)
                    Text(L10n.t("按 MusicBrainz 登记的所属国家或地区统计，而非出生地"))
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .padding(.top, -4)
                }
            }
        }
    }

    // MARK: - 那年今日

    /// `onThisDay == nil` 有四种成因(还没取 / 那几天确实没听 / 请求全挂 / 未连接),**必须**各画一句,不能留空白;
    /// 失败那支的重试必须 `force: true`,失败同样占住 6 小时 TTL。见 12 章「那年今日」四态那一条。
    private var onThisDayTile: some View {
        FootprintTile {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    tileLabel(L10n.t("那年今日"), icon: "calendar")
                    Spacer(minLength: 8)
                    if stats.onThisDay != nil, let at = stats.onThisDayUpdatedAt {
                        Text(String(format: L10n.t("%@更新"), LastfmStatsSection.coarseRelative(at)))
                            .font(.caption).foregroundStyle(.tertiary)
                            .help(String(format: L10n.t("上次刷新：%@"), LastfmStatsSection.absolute(at)))
                    }
                }
                if let o = stats.onThisDay {
                    Text(Self.onThisDaySubtitle(o))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(0..<3, id: \.self) { i in
                            if i < o.top.count {
                                onThisDayCover(o.top[i])
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                    .padding(.top, 2)
                } else {
                    HStack(spacing: 8) {
                        switch stats.onThisDayOutcome {
                        case .pending, .loaded:
                            ProgressView().controlSize(.small)
                            Text(L10n.t("正在查询那年今日…")).foregroundStyle(.secondary)
                        case .empty:
                            Label(L10n.t("过去三年的今天及前后一周均无收听记录"),
                                  systemImage: "calendar.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        case .failed:
                            Label(L10n.t("无法获取「那年今日」：Last.fm 未响应"), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button(L10n.t("重试")) { stats.refreshOnThisDay(force: true) }
                        }
                        if stats.onThisDayOutcome != .failed { Spacer(minLength: 0) }
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func onThisDayCover(_ entry: LastfmStatsService.OnThisDayResult.TopTrack) -> some View {
        let t = entry.track
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            if let url = LastfmStatsSection.trackURL(artist: t.artist, title: t.title) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        CachedImage(url: stats.coverURL(for: t), variant: .original) {
                            shape.fill(.quaternary)
                        }
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .padding(.bottom, 4)
                Text(t.title).font(.system(size: 12)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(t.artist).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(String(format: L10n.t("%@ 次"), "\(entry.count)")).monospacedDigit()
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.lastPlayed.map { String(format: L10n.t("当天最后一次收听：%@"), LastfmStatsSection.absolute($0)) } ?? "")
    }

    /// yearsAgo 是 1 时走单数句:英文没有能同时读通 "1 years ago" 和 "2 years ago" 的写法。当天为空时结果是放宽到
    /// ±3 天的"那一周"(见 OnThisDayPlanner),句子要说清楚。
    private static func onThisDaySubtitle(_ o: LastfmStatsService.OnThisDayResult) -> String {
        if o.isWeek {
            return o.yearsAgo == 1
                ? String(format: L10n.plural("去年这一周收听 %@ 次，循环最多的是以下歌曲", count: o.total), "\(o.total)")
                : String(format: L10n.plural("%1$@ 年前的这一周收听 %2$@ 次，循环最多的是以下歌曲", count: o.total),
                         "\(o.yearsAgo)", "\(o.total)")
        }
        return o.yearsAgo == 1
            ? String(format: L10n.plural("去年今天收听 %@ 次，循环最多的是以下歌曲", count: o.total), "\(o.total)")
            : String(format: L10n.plural("%1$@ 年前的今天收听 %2$@ 次，循环最多的是以下歌曲", count: o.total),
                     "\(o.yearsAgo)", "\(o.total)")
    }

    // MARK: - 小件

    private func tileLabel(_ text: String, icon: String? = nil, tint: Color = .secondary) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            }
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// 整句按 App 语言格式化好(单位、语序随语言),只把里面的数字放大加粗、其余缩小成次要色。
    private func headline(_ text: String, number: String, size: CGFloat) -> some View {
        var a = AttributedString(text)
        a.font = .system(size: max(11, size * 0.42), weight: .semibold)
        a.foregroundColor = .secondary
        if let r = a.range(of: number) {
            a[r].font = .system(size: size, weight: .bold, design: .rounded)
            a[r].foregroundColor = .primary
        }
        return Text(a).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
    }

    private var greens: [Color] {
        (colorScheme == .dark ? LastfmHeatmapView.darkLevels : LastfmHeatmapView.lightLevels)
            .compactMap { NSColor(hexStringWithAlpha: $0 + "FF").map(Color.init) }
    }

    /// 跟榜单同名时段共用文案(`LastfmStatsService.Period.displayName`)。
    private static func spanLabel(_ span: ListeningHours.Span) -> String {
        switch span {
        case .month: return LastfmStatsService.Period.month.displayName
        case .year: return LastfmStatsService.Period.year.displayName
        case .overall: return LastfmStatsService.Period.overall.displayName
        }
    }

    /// 日桶键 "yyyy-MM-dd" → 按 App 语言格式化的日期(不带时间)。
    static func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return key }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L10n.locale))
    }
}

/// 「足迹」段的一块方块:玻璃底 + 发丝描边(`settingsCardBackground`),圆角比设置卡大一档。
/// 在横排里配 `.fixedSize(horizontal: false, vertical: true)` 用:`maxHeight: .infinity` 让同一排的方块一样高。
private struct FootprintTile<Content: View>: View {
    var padded = true
    /// 整块可点的方块用可交互玻璃,悬停 / 按下有系统自己的反馈。
    var interactive = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padded ? EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14) : EdgeInsets())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .settingsCardBackground(cornerRadius: 18, interactive: interactive)
    }
}

/// 垫在玻璃卡片后面的几团淡色光,设置页各段用玻璃卡的地方共用这一份。只为让玻璃看得出透光,不该读出颜色:
/// 浓度别往上调(12 章决策 63 下记着从 14% / 20% 减半的那次)。
struct LastfmGlassGlow: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let a = colorScheme == .dark ? 0.10 : 0.07
        GeometryReader { geo in
            let r = max(geo.size.width, 1) * 0.5
            ZStack {
                RadialGradient(colors: [Color.green.opacity(a), .clear], center: UnitPoint(x: 0.18, y: 0.06), startRadius: 0, endRadius: r)
                RadialGradient(colors: [Color.blue.opacity(a * 0.8), .clear], center: UnitPoint(x: 0.9, y: 0.2), startRadius: 0, endRadius: r)
                RadialGradient(colors: [Color.orange.opacity(a * 0.7), .clear], center: UnitPoint(x: 0.22, y: 0.62), startRadius: 0, endRadius: r)
                RadialGradient(colors: [Color.purple.opacity(a * 0.6), .clear], center: UnitPoint(x: 0.85, y: 0.9), startRadius: 0, endRadius: r)
            }
        }
        .padding(-24)
        // 四边淡出:径向渐变到了边上还没散尽,不遮的话整片色光是一个看得见边的矩形。
        .mask {
            RoundedRectangle(cornerRadius: 80, style: .continuous)
                .padding(40)
                .blur(radius: 36)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
