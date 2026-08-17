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
    // 三张卡各自的折叠状态。持久化 —— 这页会被反复打开,收起来的卡每次都自己弹回来
    // 就等于没收(2026-08-12 用户要求)。
    @AppStorage("np:lastfmChartCollapsed") private var chartCollapsed = false
    @AppStorage("np:lastfmRecentCollapsed") private var recentCollapsed = false
    @AppStorage("np:lastfmOnThisDayCollapsed") private var onThisDayCollapsed = false
    @AppStorage("np:lastfmChartKind") private var kindRaw = LastfmStatsService.ChartKind.artists.rawValue
    @AppStorage("np:lastfmChartPeriod") private var periodRaw = LastfmStatsService.Period.month.rawValue

    /// 页码输入框的文本。跟 stats.recentPage 单向同步(那边变了就覆盖这里),
    /// 用户输入期间不打断 —— 只在提交或页码真的换了时才回写。
    @State private var pageInput = "1"
    // 点了手动刷新之后转圈,直到这一轮真的有结果。refreshBaseline 是 fire-and-forget、
    // 没有完成回调,所以靠观察它的两个出口关掉:成功会更新 recentUpdatedAt,失败会置
    // baselineFailed。这张卡只在已连接时才挂出来,所以"没有凭据直接 return"那条早退
    // 路径在这里不会发生(否则转圈会停不下来)。
    @State private var recentRefreshing = false

    private var kind: LastfmStatsService.ChartKind {
        .init(rawValue: kindRaw) ?? .artists
    }
    private var period: LastfmStatsService.Period {
        .init(rawValue: periodRaw) ?? .month
    }

    var body: some View {
        statsCard
        // 2026-08-16 换位:「最近记录」排在「听得最多」前面 —— 前者是"刚刚听了什么"、
        // 每次打开都在变,后者是长期榜、几天才动一次,把活的放前面。
        recentCard
        // onAppear/.task 必须挂在**常驻**的卡上。onThisDayCard 是 `if let` 条件视图——
        // 没数据时它根本不在视图层级里,挂它身上的 onAppear 永远不触发,而 onThisDay
        // 的数据又只能靠这里的刷新去拉,整个区会死锁在"一个请求都没发过"的骨架态
        // (2026-08-11 实测踩坑:档案数字全是"—"、榜单永远骨架、快照文件不生成)。
            .onAppear {
                stats.refreshBaseline()
                // 榜单收起时不查(那是一次 collector 进程+网络请求);展开那一下由
                // onChange 补上。「那年今日」照常查:它的那句概述留在表头,收起来也要显示。
                if !chartCollapsed { stats.refreshChart(kind: kind, period: period) }
                stats.refreshOnThisDay()
                pageInput = "\(stats.recentPage)"
            }
            .onChange(of: stats.recentPage) { _, page in pageInput = "\(page)" }
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
                    // 只自动刷第一页:后面几页是历史,内容不会变,重拉一遍纯属打扰
                    // (正看着的那一屏被替换掉)。
                    guard stats.recentPage == 1 else { continue }
                    stats.refreshBaseline()
                }
            }
        chartCard
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
            collapsibleHeader(icon: "chart.bar", title: L10n.t("听得最多"),
                              collapsed: $chartCollapsed) {
                // 收起后分段/时段选择器既看不到内容也改不了什么,藏起来
                if !chartCollapsed {
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
            }
            if !chartCollapsed {
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
        // 收起时不查榜:那是一次 collector 进程 + 一轮网络请求,收起来了就别花
        // (展开时补上,见下面的 onChange)
        .onChange(of: chartCollapsed) { _, nowCollapsed in
            if !nowCollapsed { stats.refreshChart(kind: kind, period: period) }
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
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!interactive)
                .rowHoverHighlight(enabled: interactive)
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
            CachedImage(url: cover) {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else if e.imageURL == nil, e.detail.isEmpty, let avatar = stats.artistAvatars[e.name] {
            CachedImage(url: avatar) {
                Circle().fill(Self.stableColor(for: e.name))
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
        } else if let url = e.imageURL {
            CachedImage(url: url) {
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
            collapsibleHeader(icon: "clock", title: L10n.t("最近记录"),
                              collapsed: $recentCollapsed) {
                if let at = stats.recentUpdatedAt {
                    // 这一页的数据是轮询来的(远端会话 45 秒一轮、否则两分钟),标一下它
                    // 是什么时候的,免得看着一个不动的列表猜是不是卡住了。
                    Text(String(format: L10n.t("%@更新"), Self.coarseRelative(at)))
                        .font(.caption).foregroundStyle(.tertiary)
                        .help(String(format: L10n.t("上次刷新:%@"), Self.absolute(at)))
                }
                // 手动刷新。轮询最慢要等两分钟,而"刚听完一首歌想立刻看到它"正是这张卡
                // 最常见的用法 —— 干等不如给一颗按钮。
                //
                // ⚠️ 必须传 force:true。refreshBaseline 开头就是 `guard fresh(...) == false`,
                // 不传的话"刚拉过"会让它直接早退,按了等于没按 —— 而这恰恰是手动刷新最常
                // 发生的情形(用户就是因为刚才那次没带出新内容才来点它)。
                if recentRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        recentRefreshing = true
                        stats.refreshBaseline(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.t("立即刷新"))
                }
            }
            if !recentCollapsed {
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
                    // 实时行说的是"此刻正在记录什么",只属于第一页;翻到历史页时它跟着
                    // 出现会很怪(那一屏讲的是几小时前的事)。
                    if stats.recentPage == 1 {
                        LiveScrobbleRow()
                    }
                    // 被实时行吸收的那一行(= 当前这次播放的中途 scrobble)不再单独显示,
                    // 见 LastfmStatsService.liveAbsorbedRecentID。注意只在渲染时跳过、
                    // 不从 recentRows 的构造里剔除 —— 它下面的同曲历史行算"第几次"仍要
                    // 把它数进去。
                    ForEach(recentRows.filter { $0.track.id != stats.liveAbsorbedRecentID },
                            id: \.track.id) { entry in
                        let t = entry.track
                        Button {
                            if let url = Self.trackURL(artist: t.artist, title: t.title) { NSWorkspace.shared.open(url) }
                        } label: {
                        HStack(spacing: 10) {
                            // 封面走三级兜底(自带 → getinfo 纠正 → 同专辑兄弟),理由见
                            // LastfmStatsService.coverURL(for:)
                            CachedImage(url: stats.coverURL(for: t)) {
                                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                            }
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(t.title).font(.system(size: 13)).lineLimit(1)
                                Text(t.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let n = entry.count {
                                Text(String(format: L10n.t("第 %@ 次听"), "\(n)"))
                                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                    .help(L10n.t("这首歌在你 Last.fm 上的第几次收听"))
                            }
                            if let date = t.date {
                                Text(Self.relative(date))
                                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                    // 相对时间悬停给精确时刻 —— "1 小时前"想核对到分钟时不用去网站查
                                    .help(Self.absolute(date))
                                    .frame(minWidth: 62, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .rowHoverHighlight()
                    }
                    // 翻页(2026-08-12 取代原来的"显示更多"一路展开):一路展开会把这一卡
                    // 撑到上百行 —— 整页越滚越长、每次刷新还要给上百首查播放次数,而看历史
                    // 本来就是翻页的事。
                    if stats.recentTotalPages > 1 {
                        Divider().padding(.horizontal, 14).padding(.vertical, 4)
                        HStack(spacing: 12) {
                            pagerButton(systemImage: "chevron.left", label: L10n.t("上一页"),
                                        enabled: stats.recentPage > 1) {
                                stats.goToPage(stats.recentPage - 1)
                            }
                            Spacer()
                            if stats.recentPaging {
                                ProgressView().controlSize(.small)
                            }
                            // 页码可直接输入:一千多页只靠上/下一页翻不动(用户要求)。
                            // 回车提交,越界/乱输由 goToPage 夹到合法范围,再由 onChange 同步回来。
                            HStack(spacing: 5) {
                                Text(L10n.t("第")).font(.caption).foregroundStyle(.secondary)
                                TextField("", text: $pageInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .multilineTextAlignment(.center)
                                    .frame(width: 54)
                                    .disabled(stats.recentPaging)
                                    .onSubmit { submitPageInput() }
                                Text(String(format: L10n.t("/ %@ 页"), "\(stats.recentTotalPages)"))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            pagerButton(systemImage: "chevron.right", label: L10n.t("下一页"),
                                        enabled: stats.recentPage < stats.recentTotalPages) {
                                stats.goToPage(stats.recentPage + 1)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 5)
            }
            }
        }
        // refreshBaseline 没有完成回调,靠观察它的两个出口关掉转圈:成功会更新
        // recentUpdatedAt,失败会置 baselineFailed,两者必居其一(见 recentRefreshing 注释)。
        .onChange(of: stats.recentUpdatedAt) { _, _ in recentRefreshing = false }
        .onChange(of: stats.baselineFailed) { _, failed in if failed { recentRefreshing = false } }
    }

    /// 历史行:API 返回的 nowplaying 行(date 为 nil)丢掉 —— 那首歌由上面的实时行负责,
    /// 无论它在本机还是别的设备上放(见 LiveScrobbleRow.live 的两条分支);它还没结束、
    /// 也还没拿到 scrobble 时间,混进"最近记录"里会是一条没有时间的怪行。
    private var recentHistory: [LastfmStatsService.RecentTrack] {
        stats.recent.filter { $0.date != nil }
    }

    /// 最近记录的每一行 + 那一次是这首歌的第几次。
    ///
    /// 服务给的是**当前总数**(userplaycount,已含这一次),不是"那一刻是第几次"。换算:
    /// 当前总数 − 比这一行**更新**的同曲收听次数。列表是最近 N 条、按时间倒序,所以比
    /// 这一行更新的同曲收听必然也在这个窗口里,这个减法在窗口内精确、不需要额外请求。
    ///
    /// ⚠️ 整段**一次线性扫描**算完,不要写成"每行现算":那样每行都要重跑一遍 recentHistory
    /// 的全表 filter、还要对它前面所有行重建归一化键,20 行就是 21 次数组分配 + 210 次
    /// 字符串归一化,而这段是 SwiftUI body 的同步路径(2026-08-12 性能审阅坐实)。
    ///
    /// 正在播放那条不参与:它还没被 scrobble,不在 userplaycount 里(实时行自己 +1)。
    private var recentRows: [(track: LastfmStatsService.RecentTrack, count: Int?)] {
        var newerSame: [String: Int] = [:]
        return recentHistory.map { row in
            let key = LastfmStatsService.playCountKey(artist: row.artist, title: row.title)
            let newer = newerSame[key, default: 0]
            newerSame[key] = newer + 1
            guard let total = stats.trackPlayCounts[key] else { return (row, nil) }
            let n = total - newer
            // 竞态(刚多了一次收听、总数还没重取)时宁可不显示,不显示错的
            return (row, n > 0 ? n : nil)
        }
    }

    // MARK: - 小件

    /// 提交页码输入:非数字/越界都交给 goToPage 夹,夹完由 onChange 把框里的值同步成
    /// 真正生效的那一页 —— 用户看到的永远是"实际在第几页",不会停在一个没生效的数字上。
    private func submitPageInput() {
        let raw = Int(pageInput.trimmingCharacters(in: .whitespaces)) ?? stats.recentPage
        let target = max(1, min(raw, max(stats.recentTotalPages, 1)))
        // 先把框里的值订正成"实际会生效的那一页"再决定跳不跳:输 0 或超出总页数时,
        // 夹完可能正好等于当前页,那样 goToPage 会直接返回、onChange 也不会触发,
        // 框里就会一直挂着那个根本没生效的数字。
        pageInput = "\(target)"
        guard target != stats.recentPage else { return }
        stats.goToPage(target)
    }

    /// 卡片折叠表头。左半(图标+标题+副标题+箭头)整块可点,尾部控件只在展开时出现 ——
    /// 收起来之后分段选择器既看不到内容也改不了什么,留着只是噪音。
    ///
    /// 刻意不复用 SettingsRow:那个组件的整行不可点(它的尾部本来就放交互控件,再套一层
    /// Button 会把控件的点击吞掉)。这里手搭,但尺寸全部取自 SettingsRowMetrics,跟同一页
    /// 其它卡的图标列/文字起点/内边距严格对齐。
    /// 粗到分钟的相对时间。不到一分钟一律说"刚刚" —— 这行字每次刷新都会重算,秒级
    /// 精度会让它一直跳数字(28 秒→45 秒→刚过 1 分…),而"上次刷新是多久以前"本来也
    /// 不需要精确到秒(2026-08-12 用户反馈)。要精确时刻的话 tooltip 里有。
    private static func coarseRelative(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? L10n.t("刚刚") : relative(date)
    }

    private func collapsibleHeader<Trailing: View>(
        icon: String, title: String, subtitle: String? = nil,
        collapsed: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { collapsed.wrappedValue.toggle() }
            } label: {
                HStack(alignment: .top, spacing: SettingsRowMetrics.iconTextSpacing) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(title).font(.system(size: 13))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(collapsed.wrappedValue ? -90 : 0))
                        }
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed.wrappedValue ? L10n.t("展开") : L10n.t("收起"))
            // trailing 一律渲染:收起时要不要藏由各卡自己决定(榜单的分段选择器收起后
            // 没有意义要藏;最近记录的"几分钟前更新"收起时照样有用,不藏)。
            trailing().labelsHidden().settingsGlassButtons()
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }

    private func pagerButton(systemImage: String, label: String,
                             enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || stats.recentPaging)
    }

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
                    // 副标题留在表头:收起来之后它就是这张卡的摘要(那天听了多少),
                    // 不至于收成一个只剩标题、什么都没说的条。
                    collapsibleHeader(
                        icon: "calendar",
                        title: L10n.t("那年今日"),
                        // 不再在这里点名某一首:下面第一行就是它,重复一遍还容易让人以为
                        // 那是两件事(2026-08-12 改成"次数最多的前三首"之后)。
                        // yearsAgo 是 1 时必须走单数句:英文没有能同时读通 "1 years ago"
                        // 和 "2 years ago" 的写法,原来那条靠 "year(s)" 糊过去 —— 那是
                        // 机翻痕迹,而 1...3 的循环里 1 恰好是最常出现的一档。
                        subtitle: o.yearsAgo == 1
                            ? String(format: L10n.t("去年今天听了 %@ 次，最常循环的是这几首"), "\(o.total)")
                            : String(
                                format: L10n.t("%1$@ 年前的今天听了 %2$@ 次，最常循环的是这几首"),
                                "\(o.yearsAgo)", "\(o.total)"),
                        collapsed: $onThisDayCollapsed
                    ) { EmptyView() }
                    if !onThisDayCollapsed {
                    CardDivider()
                    VStack(spacing: 0) {
                        ForEach(o.top) { entry in
                            let t = entry.track
                            Button {
                                if let url = Self.trackURL(artist: t.artist, title: t.title) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    CachedImage(url: stats.coverURL(for: t)) {
                                        RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                                    }
                                    .frame(width: 26, height: 26)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(t.title).font(.system(size: 13)).lineLimit(1)
                                        Text(t.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    // 尾部给"那天听了几次" —— 这张卡讲的是那一天,具体时刻
                                    // 意义不大,挪进 tooltip。
                                    Text(String(format: L10n.t("%@ 次"), "\(entry.count)"))
                                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .rowHoverHighlight()
                            .help(entry.lastPlayed.map {
                                String(format: L10n.t("那天最后一次:%@"), Self.absolute($0))
                            } ?? "")
                        }
                    }
                    .padding(.vertical, 5)
                    }
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

    /// 这一行说的是「**现在正在被 Last.fm 记录的**那首歌」,不是「本机正在放的歌」——
    /// 两者只在"播放源就是这台 Mac"时才重合。2026-08-12 用户实测:手机在放、本机暂停时,
    /// Last.fm 明明有 nowplaying 条目(我们也早就拉下来存着了),这一行却整个不显示,
    /// 因为它当时只认本机播放状态。
    private struct LiveSource {
        var title: String
        var artist: String
        var artwork: NSImage?  // 本机播放才有(直接拿现成的位图,不用再下载)
        var imageURL: URL?     // 远端来源用 API 给的封面
        var confirmed: Bool    // Last.fm 是否已确认收到
        var remote: Bool       // 播放源不是这台 Mac
    }

    private var live: LiveSource? {
        // ① 本机在放、且我们确实在往 Last.fm 记录(开关关着=这首没人在记,不该显示)
        if features.lastfmMirrorScrobble, poller.isPlayingNow, !poller.title.isEmpty {
            return LiveSource(title: poller.title, artist: poller.artist,
                              artwork: poller.artworkImage, imageURL: nil,
                              confirmed: serverConfirms(poller.title), remote: false)
        }
        // ② 本机没在放,但 Last.fm 说有一首正在记录 —— 多半在手机/网页/别的设备上放。
        // 它按定义就是服务器确认过的(数据本身就来自服务器),直接红点。
        //
        // 但服务端那条跟本机当前曲目同名时不算:Last.fm 的 nowplaying 停播后不会立刻
        // 消失,这种情况几乎总是**我们自己**刚才播它时留下的残影(本机现在是暂停),
        // 拿它显示"正在记录"就是在撒谎。真在别的设备上放时,那首歌跟本机这首对不上。
        if let np = stats.apiNowPlaying, stats.apiNowPlayingIsFresh, !matchesLocalTrack(np.title) {
            return LiveSource(title: np.title, artist: np.artist, artwork: nil,
                              imageURL: stats.coverURL(for: np), confirmed: true, remote: true)
        }
        return nil
    }

    /// 本机这首是否已被 Last.fm 确认收到:recenttracks 里出现了同名的 nowplaying 条目,
    /// 说明 collector 发的 updateNowPlaying 已经到了服务器 —— 红点只看本地状态的话,
    /// 网络断了/提交失败它照样红着(2026-08-11 发散采纳,改为服务器确认制)。
    /// 标题宽松比对:大小写/首尾空白不算差异;艺人不参与(合唱串会被 collapse 改写)。
    private func serverConfirms(_ localTitle: String) -> Bool {
        guard let np = stats.apiNowPlaying else { return false }
        return looseSameTitle(np.title, localTitle)
    }

    /// 服务端这条 nowplaying 说的是不是本机播放器里当前这首(不论在放还是暂停)。
    private func matchesLocalTrack(_ title: String) -> Bool {
        !poller.title.isEmpty && looseSameTitle(title, poller.title)
    }

    private func looseSameTitle(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased()
            == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 远端会话看着还活着吗 —— 决定要不要用 45 秒的快节奏轮询。
    ///
    /// 不能只看"此刻有没有 nowplaying":换歌的空档、手机侧桥接偶尔漏发 now-playing,都会让
    /// 它瞬间为 nil,而刷新恰好落在那一刻的话,快轮询就把自己关掉了 —— 接下来只能等父视图
    /// 两分钟那一拍,期间恢复播放也看不到实时行(2026-08-12 用户反馈"怎么不更新了")。
    /// 补上"最近十分钟内有过 scrobble"这条:刚听过就说明这个会话还在,值得继续盯着。
    private var remoteSessionLikelyActive: Bool {
        if stats.apiNowPlaying != nil { return true }
        guard let newest = stats.recent.first(where: { $0.date != nil })?.date else { return false }
        return Date().timeIntervalSince(newest) < 10 * 60
    }

    /// 给 onChange 用的身份串:本机换歌、远端换歌、本机↔远端来源切换都算变化。
    private var liveKey: String {
        guard let live else { return "" }
        return "\(live.remote ? "r" : "l")|\(live.artist)|\(live.title)"
    }

    /// 最近记录里"就是当前这次播放"的那一行。长歌播到 4 分钟/过半时 Last.fm 已收到
    /// scrobble(时间戳=开播时刻),它会以历史行身份出现在列表顶上,跟实时行并存看着
    /// 像重复记录(2026-08-17 用户截图:"第 5 次听·正在记录"叠着"第 4 次听·4 分钟前")。
    /// 判定:最新一条有时间的记录、标题宽松相同、且开播时刻对得上(锚点反推的本次
    /// 开播时间 ±2 分钟 —— 单曲循环的上一次播放差整整一首歌的时长,不会误伤)。
    /// 只认本机播放:远端(手机)拿不到精确的开播时刻,宁可维持旧观感也不冒险
    /// 隐藏一条真实的历史行。
    ///
    /// count 是这一行已经落库的次数(含这一次)—— 顶替换歌时取的 nowPlayingCount:
    /// 那个数是 userplaycount+1,若取数发生在这次 scrobble 落库之后就会多算一
    /// (正是截图里 5 vs 4 的来源),而这一行的数永远是 scrobble 后的权威值。
    private var absorbedRecent: (id: String, count: Int?)? {
        guard let live, !live.remote, let anchor = poller.anchor else { return nil }
        guard let row = stats.recent.first(where: { $0.date != nil }), let date = row.date,
              looseSameTitle(row.title, live.title) else { return nil }
        let playStart = anchor.fetchedAt.addingTimeInterval(-Double(anchor.progressMs) / 1000)
        guard abs(date.timeIntervalSince(playStart)) < 120 else { return nil }
        let key = LastfmStatsService.playCountKey(artist: row.artist, title: row.title)
        return (row.id, stats.trackPlayCounts[key])
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
                            if let img = live.artwork {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            } else if let url = live.imageURL {
                                CachedImage(url: url) {
                                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                                }
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
                        // 这次播放已被 scrobble 时用落库的权威次数,否则用换歌时取的
                        // nowPlayingCount(见 absorbedRecent 注释:后者取晚了会多算一)。
                        if let n = absorbedRecent?.count ?? stats.nowPlayingCount {
                            // 老歌重逢的小情绪点:"第 208 次听"
                            Text(String(format: L10n.t("第 %@ 次听"), "\(n)"))
                                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        if live.confirmed {
                            Label(L10n.t("正在记录"), systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color(red: 0.84, green: 0.06, blue: 0.03))
                                .labelStyle(.titleAndIcon)
                                .imageScale(.small)
                                .help(live.remote
                                      ? L10n.t("在其他设备上播放，Last.fm 已收到")
                                      : L10n.t("Last.fm 已确认收到这次播放"))
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
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .onAppear {
            if let live { stats.refreshNowPlayingCount(title: live.title, artist: live.artist) }
            stats.liveAbsorbedRecentID = absorbedRecent?.id
        }
        .onChange(of: liveKey) { _, _ in
            // 本机换歌、远端换歌、来源切换都要重取"第 N 次听"
            if let live { stats.refreshNowPlayingCount(title: live.title, artist: live.artist) }
        }
        // 吸收状态是从(播放进度 × 最近记录)算出来的,两个源任何一个动了都可能翻转 ——
        // onChange 在每次 body 重算时都重评这个值,变了才写回 service(列表靠它隐藏行)。
        .onChange(of: absorbedRecent?.id) { _, id in
            if stats.liveAbsorbedRecentID != id { stats.liveAbsorbedRecentID = id }
        }
        .onChange(of: poller.title) { _, _ in
            // 本机换歌 = 上一首刚被 scrobble。给 collector 十秒把记录提交出去,然后无视缓存
            // 强刷一次 —— 刚唱完的歌马上出现在列表顶上,顺带把 apiNowPlaying 换成新歌
            // (红点的服务器确认就是靠这次刷新到位的)。
            pendingForceRefresh?.cancel()
            pendingForceRefresh = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, stats.recentPage == 1 else { return }
                stats.refreshBaseline(force: true)
            }
        }
        // 远端会话(在别的设备上放)时,这一行的唯一数据来源就是轮询:父视图那轮 2 分钟
        // 对一首三四分钟的歌太慢,整首歌可能只露一次面。这里在远端会话看着还活着时加密到
        // 45 秒;本机在放不发请求(那边由 poller 实时驱动,不需要轮询)。
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled else { break }
                // 跟父视图那条 2 分钟轮询同一条守卫:翻到历史页时别把用户正看的那屏
                // 换掉(强刷会无视 TTL,原来这两条路径都漏了这个判断)。
                guard stats.recentPage == 1, !poller.isPlayingNow, remoteSessionLikelyActive else { continue }
                stats.refreshBaseline(force: true)
            }
        }
        .onDisappear { pendingForceRefresh?.cancel() }
    }
}


/// 行级悬停高亮。
///
/// ⚠️ 刻意做成**每行自己持有 @State**,而不是父视图存一个"当前悬停的是哪一行"的字符串:
/// 那样任何一次 hover 进/出都会让整个 Section(三张卡、三十多行)的 body 重算 —— 鼠标从
/// 列表顶划到底就是四十次整段重渲染,换来的可见变化只有一行背景色(2026-08-12 性能审阅
/// 坐实)。行内化之后,hover 只让这一行的这层包装重画,顺带也省掉了每帧为每行拼
/// "recent|<id>" 这类比较用字符串。
private struct RowHoverHighlight: ViewModifier {
    var enabled: Bool = true
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered && enabled ? Color.secondary.opacity(0.10) : .clear)
                    .padding(.horizontal, 6))
            .onHover { hovered = $0 }
    }
}

extension View {
    func rowHoverHighlight(enabled: Bool = true) -> some View {
        modifier(RowHoverHighlight(enabled: enabled))
    }
}
