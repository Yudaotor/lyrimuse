import SwiftUI

/// Last.fm 卡的信息展示区(设计方案 A「档案页」,2026-08-11 artifact):三个数字、
/// 一张分段榜单卡、最近记录。只在已连接时由 AccountLinkingTab 挂出来。
struct LastfmStatsSection: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    // "正在记录"行接本地播放状态,不用 API 的 nowplaying 标记 —— API 那份要等下一次
    // 拉取才更新(缓存 15 分钟),本地这份换歌瞬间就变。这也正是设计方案里"活状态"
    // 一节定的做法。
    @ObservedObject private var poller = PlaybackCoordinator.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    // 分段/时段都持久化 —— 这页会被反复打开,每次都跳回默认档等于没记住用户在看什么。
    @AppStorage("np:lastfmChartKind") private var kindRaw = LastfmStatsService.ChartKind.artists.rawValue
    @AppStorage("np:lastfmChartPeriod") private var periodRaw = LastfmStatsService.Period.month.rawValue

    // 悬停行的高亮(说明"这里能点"),chart|N / recent|id 两个列表共用一个变量
    @State private var hoveredRow: String?

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
                Button {
                    if let url = Self.lastfmURL(kind: kind, entry: e) { NSWorkspace.shared.open(url) }
                } label: {
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
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hoveredRow == "chart|\(e.rank)" ? Color.secondary.opacity(0.10) : .clear)
                        .padding(.horizontal, 6))
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredRow = $0 ? "chart|\(e.rank)" : (hoveredRow == "chart|\(e.rank)" ? nil : hoveredRow) }
                .help(L10n.t("在 Last.fm 打开"))
            }
        }
        .padding(.vertical, 5)
    }

    /// Last.fm 的实体页地址。路径段里的 "/" 必须转义 —— 专辑名里带斜杠(The Hits/The
    /// B-Sides)会把路径切开;urlPathAllowed 本身放行 "/",要从集合里挖掉。
    static func lastfmURL(kind: LastfmStatsService.ChartKind, entry: LastfmStatsService.ChartEntry) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        func enc(_ s: String) -> String? { s.addingPercentEncoding(withAllowedCharacters: allowed) }
        switch kind {
        case .artists:
            guard let a = enc(entry.name) else { return nil }
            return URL(string: "https://www.last.fm/music/\(a)")
        case .albums:
            guard let a = enc(entry.detail), let al = enc(entry.name) else { return nil }
            return URL(string: "https://www.last.fm/music/\(a)/\(al)")
        case .tracks:
            guard let a = enc(entry.detail), let t = enc(entry.name) else { return nil }
            return URL(string: "https://www.last.fm/music/\(a)/_/\(t)")
        }
    }

    static func trackURL(artist: String, title: String) -> URL? {
        lastfmURL(kind: .tracks, entry: .init(rank: 0, name: title, detail: artist, playcount: 0, imageURL: nil))
    }

    /// 榜单行的图:专辑有真封面;歌手/歌曲的 API 图是白星占位(见 LastfmStatsService
    /// 的注释),画首字母色块 —— 色相由名字哈希决定,同一个名字永远同一个颜色。
    @ViewBuilder
    private func thumb(for e: LastfmStatsService.ChartEntry) -> some View {
        // 歌手榜(detail 为空的就是歌手行)优先用 collector 解析的真头像,圆形;
        // 还没解析出来/查不到时落回首字母色块 —— 头像是异步补上的,先字母后照片。
        if e.imageURL == nil, e.detail.isEmpty, let avatar = stats.artistAvatars[e.name] {
            AsyncImage(url: avatar) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(Self.stableColor(for: e.name))
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
        } else if let url = e.imageURL {
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
                    if let live = liveRow {
                        HStack(spacing: 10) {
                            Group {
                                if let img = poller.artworkImage {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                                }
                            }
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(live.title).font(.system(size: 13)).lineLimit(1)
                                Text(live.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Label(L10n.t("正在记录"), systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color(red: 0.84, green: 0.06, blue: 0.03))
                                .labelStyle(.titleAndIcon)
                                .imageScale(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                    }
                    ForEach(recentHistory) { t in
                        Button {
                            if let url = Self.trackURL(artist: t.artist, title: t.title) { NSWorkspace.shared.open(url) }
                        } label: {
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
                            if let date = t.date {
                                Text(Self.relative(date))
                                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                    // 相对时间悬停给精确时刻 —— "1 小时前"想核对到分钟时不用去网站查
                                    .help(Self.absolute(date))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(hoveredRow == "recent|\(t.id)" ? Color.secondary.opacity(0.10) : .clear)
                                .padding(.horizontal, 6))
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hoveredRow = $0 ? "recent|\(t.id)" : (hoveredRow == "recent|\(t.id)" ? nil : hoveredRow) }
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }

    /// 本地"正在记录"行:正在播放、且 scrobble 开着才显示 —— 开关关着时这首歌不会被
    /// 记录,标一句"正在记录"就是撒谎。
    private var liveRow: (title: String, artist: String)? {
        guard features.lastfmMirrorScrobble, poller.isPlayingNow, !poller.title.isEmpty else { return nil }
        return (poller.title, poller.artist)
    }

    /// 历史行:API 返回的 nowplaying 行(date 为 nil)丢掉 —— 它跟上面的本地行说的是
    /// 同一首歌;本地行没显示时(暂停/开关关着)它也照丢,暂停中的歌不该以"正在播"的
    /// 形态出现在历史里。
    private var recentHistory: [LastfmStatsService.RecentTrack] {
        stats.recent.filter { $0.date != nil }
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

    /// 精确时刻("2026年8月11日 14:32"),给相对时间的悬停提示用。
    static func absolute(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: L10n.current == "en" ? "en_US" : "zh_CN")
        return f.string(from: date)
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
