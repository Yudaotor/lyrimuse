import SwiftUI

/// Last.fm 卡的信息展示区(设计方案 A「档案页」,2026-08-11 artifact):三个数字、
/// 一张分段榜单卡、最近记录。只在已连接时由 AccountLinkingTab 挂出来。
struct LastfmStatsSection: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    // 刻意**不**订阅 PlaybackCoordinator:它在放歌时每个歌词行边界都发布一次,整个
    // Section(三张卡、最多一百多行)跟着白白重算。所有跟播放状态相关的东西(正在记录行、
    // 换歌强刷、第 N 次听)都关进 LiveScrobbleRow 子视图,只有那一行随歌词节奏重渲染
    // (2026-08-11 发散采纳)。
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
        // onAppear/.task 必须挂在**常驻**的卡上。onThisDayCard 是 `if let` 条件视图——
        // 没数据时它根本不在视图层级里,挂它身上的 onAppear 永远不触发,而 onThisDay
        // 的数据又只能靠这里的刷新去拉,整个区会死锁在"一个请求都没发过"的骨架态
        // (2026-08-11 实测踩坑:档案数字全是"—"、榜单永远骨架、快照文件不生成)。
            .onAppear {
                stats.refreshBaseline()
                stats.refreshChart(kind: kind, period: period)
                stats.refreshOnThisDay()
            }
            // 页面开着不该是一张死快照:每 2 分钟刷一轮档案数字和最近记录(服务侧
            // baselineTTL 同为 2 分钟,正好放行),recent 重新赋值触发重渲染,"6 小时前"
            // 这些相对时间跟着重算。
            //
            // 用 .task 而不是 .onReceive(Timer.publish(...)):后者的 publisher 内联在
            // body 里,每次重渲染都是新实例,SwiftUI 会掐掉旧订阅重新订阅,倒计时清零 ——
            // 而本视图订阅着 PlaybackCoordinator,放歌时歌词每推进一句就重渲染一次,
            // 120 秒永远数不满,定时刷新恰恰在放歌时(最需要活数据时)静默失效
            // (2026-08-11 审阅确认)。.task 的生命周期跟视图在场与否走,不受重渲染影响,
            // 视图移出层级自动取消。
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    guard !Task.isCancelled else { break }
                    stats.refreshBaseline()
                }
            }
        onThisDayCard
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
            } else if stats.chartFailed(kind, period) {
                retryRow { stats.refreshChart(kind: kind, period: period) }
            } else {
                // 骨架:10 行(跟真实榜单等行数),专辑/歌曲榜带第二行小字(真实行是两行),
                // 加载完成不跳版;interactive: false —— 骨架不是内容,不该能悬停、更不该
                // 点开 last.fm/music/占位占位(2026-08-11 审阅确认这真能点)。
                chartList((1...10).map {
                    .init(rank: $0, name: "占位占位", detail: kind == .artists ? "" : "占位",
                          playcount: 0, imageURL: nil)
                }, interactive: false)
                .redacted(reason: .placeholder)
            }
        }
    }

    private func chartList(_ entries: [LastfmStatsService.ChartEntry], interactive: Bool = true) -> some View {
        let maxCount = max(entries.map(\.playcount).max() ?? 1, 1)
        return VStack(spacing: 0) {
            ForEach(entries) { e in
                Button {
                    guard interactive else { return }
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
                .disabled(!interactive)
                .onHover { hovering in
                    guard interactive else { return }
                    hoveredRow = hovering ? "chart|\(e.rank)" : (hoveredRow == "chart|\(e.rank)" ? nil : hoveredRow)
                }
                .help(interactive ? L10n.t("在 Last.fm 打开") : "")
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
        // 歌曲榜(detail 非空、imageURL 为 nil 的行):用 track.getInfo 补出来的专辑封面
        if e.imageURL == nil, !e.detail.isEmpty, let cover = stats.trackCovers["\(e.detail)|\(e.name)"] {
            AsyncImage(url: cover) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else if e.imageURL == nil, e.detail.isEmpty, let avatar = stats.artistAvatars[e.name] {
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
                // LazyVStack:展开到 100 行时行视图和封面按需实例化,不一口气全建
                // (2026-08-11 发散采纳)。
                LazyVStack(spacing: 0) {
                    LiveScrobbleRow()
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
                        .help(L10n.t("在 Last.fm 打开"))
                    }
                    // 显示更多:8 → 30 → 100。到 100 就不再给按钮 —— 再往下不是"看一眼
                    // 最近在听什么"的范畴了,交给「查看主页 ↗」。
                    if stats.recentLimit < 100 {
                        Divider().padding(.horizontal, 14).padding(.vertical, 4)
                        Button {
                            stats.expandRecent()
                        } label: {
                            HStack(spacing: 6) {
                                if stats.recentExpanding {
                                    ProgressView().controlSize(.small)
                                }
                                Text(L10n.t("显示更多"))
                                    .font(.callout).foregroundStyle(Color.accentColor)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(stats.recentExpanding)
                    }
                }
                .padding(.vertical, 5)
            }
        }
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

    // Formatter 是重对象,静态复用 —— 原来每行渲染各 new 一个,展开到 100 行时一次
    // 重渲染就是 ~200 次分配(审阅指出)。语言可在设置里切,所以按 lang 失效重建;
    // 这个视图只在主线程渲染,静态可变量不需要锁。
    private static var fmtLang = ""
    private static var absFmt = DateFormatter()
    private static var relFmt = RelativeDateTimeFormatter()

    private static func ensureFormatters() {
        let lang = L10n.current == "en" ? "en_US" : "zh_CN"
        guard lang != fmtLang else { return }
        fmtLang = lang
        absFmt = DateFormatter()
        absFmt.dateStyle = .medium
        absFmt.timeStyle = .short
        absFmt.locale = Locale(identifier: lang)
        relFmt = RelativeDateTimeFormatter()
        relFmt.unitsStyle = .short
        relFmt.locale = Locale(identifier: lang)
    }

    /// 精确时刻("2026年8月11日 14:32"),给相对时间的悬停提示用。
    static func absolute(_ date: Date) -> String {
        ensureFormatters()
        return absFmt.string(from: date)
    }

    /// 相对时间("4 分钟前"),locale 跟着 App 语言走 —— RelativeDateTimeFormatter
    /// 默认跟系统语言,而这个 App 的语言可以在设置里单独切。
    static func relative(_ date: Date) -> String {
        ensureFormatters()
        return relFmt.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - 那年今日

    private var onThisDayCard: some View {
        Group {
            if let o = stats.onThisDay {
                SettingsCard {
                    SettingsRow(
                        icon: "calendar",
                        title: L10n.t("那年今日"),
                        subtitle: String(
                            format: L10n.t("%1$@ 年前的今天听了 %2$@ 次，循环最多的是《%3$@》"),
                            "\(o.yearsAgo)", "\(o.total)", o.topTitle)
                    )
                    CardDivider()
                    VStack(spacing: 0) {
                        ForEach(o.rows) { t in
                            Button {
                                if let url = Self.trackURL(artist: t.artist, title: t.title) {
                                    NSWorkspace.shared.open(url)
                                }
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
                                        // 那天的具体时刻(相对时间在跨年场景没有信息量)
                                        Text(Self.absolute(date))
                                            .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(hoveredRow == "otd|\(t.id)" ? Color.secondary.opacity(0.10) : .clear)
                                        .padding(.horizontal, 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredRow = $0 ? "otd|\(t.id)" : (hoveredRow == "otd|\(t.id)" ? nil : hoveredRow) }
                            .help(L10n.t("在 Last.fm 打开"))
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }
}

/// 「正在记录」活状态行,独立子视图:全 Section 里唯一订阅 PlaybackCoordinator 的地方,
/// 歌词逐行推进引发的 20Hz 级发布只重渲染这一行,不再拖着三张卡陪跑(2026-08-11 发散
/// 采纳)。换歌强刷和「第 N 次听」的取数也一并住在这里 —— 它们的触发源就是播放状态。
///
/// 不播放/开关关着时渲染成零高度占位而不是移出层级:onChange(poller.title) 得一直挂着,
/// 暂停状态下换歌(手动切曲再播放)也要能触发强刷。
private struct LiveScrobbleRow: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @ObservedObject private var poller = PlaybackCoordinator.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    @State private var hovered = false
    @State private var pendingForceRefresh: Task<Void, Never>?

    private var live: (title: String, artist: String)? {
        guard features.lastfmMirrorScrobble, poller.isPlayingNow, !poller.title.isEmpty else { return nil }
        return (poller.title, poller.artist)
    }

    /// 红点的真值:Last.fm 的 recenttracks 里出现了这首的 nowplaying 条目,说明
    /// collector 发的 updateNowPlaying 已被服务器收到 —— 之前红点只看本地状态,
    /// 网络断了/提交失败它照样红着(2026-08-11 发散采纳,改为服务器确认制)。
    /// 标题宽松比对:大小写/首尾空白不算差异;艺人不参与(合唱串会被 collapse 改写)。
    private var serverConfirmed: Bool {
        guard let np = stats.apiNowPlaying, let live else { return false }
        return np.title.trimmingCharacters(in: .whitespaces).lowercased()
            == live.title.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var body: some View {
        Group {
            if let live {
                Button {
                    if let url = LastfmStatsSection.trackURL(artist: live.artist, title: live.title) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
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
                        if let n = stats.nowPlayingCount {
                            // 老歌重逢的小情绪点:"第 208 次听"
                            Text(String(format: L10n.t("第 %@ 次听"), "\(n)"))
                                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        if serverConfirmed {
                            Label(L10n.t("正在记录"), systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color(red: 0.84, green: 0.06, blue: 0.03))
                                .labelStyle(.titleAndIcon)
                                .imageScale(.small)
                                .help(L10n.t("Last.fm 已确认收到这次播放"))
                        } else {
                            Label(L10n.t("正在播放"), systemImage: "circle.dotted")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                                .imageScale(.small)
                                .help(L10n.t("等待 Last.fm 确认（通常几秒内）"))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(hovered ? Color.secondary.opacity(0.10) : .clear)
                            .padding(.horizontal, 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help(L10n.t("在 Last.fm 打开"))
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .onAppear {
            if let live { stats.refreshNowPlayingCount(title: live.title, artist: live.artist) }
        }
        .onChange(of: poller.title) { _, _ in
            if let live { stats.refreshNowPlayingCount(title: live.title, artist: live.artist) }
            // 换歌 = 上一首刚被 scrobble。给 collector 十秒把记录提交出去,然后无视缓存
            // 强刷一次 —— 刚唱完的歌马上出现在列表顶上,顺带把 apiNowPlaying 换成新歌
            // (红点的服务器确认就是靠这次刷新到位的)。
            pendingForceRefresh?.cancel()
            pendingForceRefresh = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                stats.refreshBaseline(force: true)
            }
        }
        .onDisappear { pendingForceRefresh?.cancel() }
    }
}
