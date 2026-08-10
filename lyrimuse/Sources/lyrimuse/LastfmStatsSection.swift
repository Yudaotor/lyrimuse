import SwiftUI

/// Last.fm 卡的信息展示区(设计方案 A「档案页」,2026-08-11 artifact):三个数字、
/// 一张分段榜单卡、最近记录。只在已连接时由 AccountLinkingTab 挂出来。
struct LastfmStatsSection: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    // 分段/时段都持久化 —— 这页会被反复打开,每次都跳回默认档等于没记住用户在看什么。
    @AppStorage("np:lastfmChartKind") private var kindRaw = LastfmStatsService.ChartKind.artists.rawValue
    @AppStorage("np:lastfmChartPeriod") private var periodRaw = LastfmStatsService.Period.month.rawValue

    private var kind: LastfmStatsService.ChartKind {
        .init(rawValue: kindRaw) ?? .artists
    }
    private var period: LastfmStatsService.Period {
        .init(rawValue: periodRaw) ?? .month
    }

    var body: some View {
        statsCard
        chartCard
        recentCard
        // onAppear 挂在最后一张卡上就够了(三张卡同生同灭)
            .onAppear {
                stats.refreshBaseline()
                stats.refreshChart(kind: kind, period: period)
            }
    }

    // MARK: - 三个数字

    private var statsCard: some View {
        SettingsCard {
            HStack(spacing: 0) {
                statCell(value: stats.overview?.today, label: L10n.t("今天"))
                Divider().padding(.vertical, 10)
                statCell(value: stats.overview?.week, label: L10n.t("近 7 天"))
                Divider().padding(.vertical, 10)
                statCell(value: stats.overview?.total, label: L10n.t("总 scrobble"))
            }
            if stats.baselineFailed {
                CardDivider()
                retryRow { stats.refreshBaseline() }
            }
        }
    }

    private func statCell(value: Int?, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map { $0.formatted() } ?? "—")
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - 榜单

    private var chartCard: some View {
        SettingsCard {
            SettingsRow(icon: "chart.bar", title: L10n.t("听得最多")) {
                HStack(spacing: 10) {
                    Picker("", selection: Binding(
                        get: { kindRaw },
                        set: { kindRaw = $0; stats.refreshChart(kind: kind, period: period) }
                    )) {
                        ForEach(LastfmStatsService.ChartKind.allCases) { k in
                            Text(k.displayName).tag(k.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Picker("", selection: Binding(
                        get: { periodRaw },
                        set: { periodRaw = $0; stats.refreshChart(kind: kind, period: period) }
                    )) {
                        ForEach(LastfmStatsService.Period.allCases) { p in
                            Text(p.displayName).tag(p.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            CardDivider()
            if let entries = stats.chart(kind, period) {
                if entries.isEmpty {
                    placeholderRow(L10n.t("这个时段还没有记录"))
                } else {
                    chartList(entries)
                }
            } else if stats.chartFailed {
                retryRow { stats.refreshChart(kind: kind, period: period) }
            } else {
                // 骨架:行高跟真实行一致,加载完成不跳版
                chartList((1...5).map {
                    .init(rank: $0, name: "占位占位", detail: "", playcount: 0, imageURL: nil)
                })
                .redacted(reason: .placeholder)
            }
        }
    }

    private func chartList(_ entries: [LastfmStatsService.ChartEntry]) -> some View {
        let maxCount = max(entries.map(\.playcount).max() ?? 1, 1)
        return VStack(spacing: 0) {
            ForEach(entries) { e in
                HStack(spacing: 10) {
                    Text("\(e.rank)")
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .trailing)
                    thumb(for: e)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.name).font(.system(size: 13)).lineLimit(1)
                        if !e.detail.isEmpty {
                            Text(e.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(width: 170, alignment: .leading)
                    // 播放量条:相对榜首的比例。GeometryReader 只包这一个条,不影响行布局
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(geo.size.width * CGFloat(e.playcount) / CGFloat(maxCount), 3))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 5)
                    Text(String(format: L10n.t("%d 次"), e.playcount))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            }
        }
        .padding(.vertical, 5)
    }

    /// 榜单行的图:专辑有真封面;歌手/歌曲的 API 图是白星占位(见 LastfmStatsService
    /// 的注释),画首字母色块 —— 色相由名字哈希决定,同一个名字永远同一个颜色。
    @ViewBuilder
    private func thumb(for e: LastfmStatsService.ChartEntry) -> some View {
        if let url = e.imageURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Circle()
                .fill(Self.stableColor(for: e.name))
                .frame(width: 26, height: 26)
                .overlay(
                    Text(e.name.prefix(1).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    static func stableColor(for name: String) -> Color {
        var hash: UInt32 = 5381
        for u in name.unicodeScalars { hash = hash &* 33 &+ u.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.62)
    }

    // MARK: - 最近记录

    private var recentCard: some View {
        SettingsCard {
            SettingsRow(icon: "clock", title: L10n.t("最近记录"))
            CardDivider()
            if stats.recent.isEmpty {
                if stats.baselineFailed {
                    retryRow { stats.refreshBaseline() }
                } else {
                    placeholderRow(L10n.t("还没有 scrobble 记录"))
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(stats.recent) { t in
                        HStack(spacing: 10) {
                            AsyncImage(url: t.imageURL) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                            }
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(t.title).font(.system(size: 13)).lineLimit(1)
                                Text(t.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if t.nowPlaying {
                                Label(L10n.t("正在记录"), systemImage: "circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color(red: 0.84, green: 0.06, blue: 0.03))
                                    .labelStyle(.titleAndIcon)
                                    .imageScale(.small)
                            } else if let date = t.date {
                                Text(Self.relative(date))
                                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }

    // MARK: - 小件

    private func placeholderRow(_ text: String) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }

    private func retryRow(_ action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(L10n.t("加载失败")).font(.callout).foregroundStyle(.secondary)
            Button(L10n.t("重试"), action: action).buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    /// 相对时间("4 分钟前"),locale 跟着 App 语言走 —— RelativeDateTimeFormatter
    /// 默认跟系统语言,而这个 App 的语言可以在设置里单独切。
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: L10n.current == "en" ? "en_US" : "zh_CN")
        return f.localizedString(for: date, relativeTo: Date())
    }
}
