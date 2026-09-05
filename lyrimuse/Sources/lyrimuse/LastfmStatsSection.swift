import Combine
import LyrimuseCore
import SwiftUI

/// Last.fm 卡的信息展示区(设计方案 A「档案页」,2026-08-11 artifact):三个数字、
/// 一张分段榜单卡、最近记录。只在已连接时由 AccountLinkingTab 挂出来。
///
/// 2026-08-23 从"四张卡顺序平铺"改成"AccountLinkingTab 那个 tab 选择器里的三段"
/// (「连接」不是 tab,常驻在 AccountLinkingTab 那边的选择器外面,见那边 LastfmSection
/// 头注)。⚠️ **这个 View 本身必须始终挂载,不能塞进外层按 tab 切换的 switch/if 分支
/// 里**——`selected` 只决定 `body` 画哪张卡,下面那段 onAppear/.task 常驻刷新逻辑
/// (数字/榜单/最近记录/那年今日共用同一轮拉取)靠的正是这个 View **从不因为切 tab 被
/// 卸载重建**——AccountLinkingTab 侧因此让它跟三段 tab 选择器同级、自己不套任何条件
/// 分支(仅在整体断开连接时不挂载,那时确实什么都不用刷)。早前的写法是四张卡一次性
/// 全部平铺,`.onAppear`/`.task` 挂在其中"常驻"的那张卡(`recentCard`)身上就够;
/// 拆 tab 之后同一个前提("这个锚点不会被拆掉重建")改由整个 View 的挂载/卸载来保证,
/// 不能再指望"其中一张卡"。
///
/// 「统计」段同时画 statsCard + recentCard(2026-08-23 用户反馈拆开后这两个数字/列表
/// 本来就是连着看的一件事,合回一段;原来的长滚动里它们也确实紧挨着)。
struct LastfmStatsSection: View {
    /// 各段的 tab 标识,跟 AccountLinkingTab.LastfmSection 一一对应。
    enum Tab: String, CaseIterable, Identifiable {
        case stats, chart, onThisDay
        /// 「设置」段(2026-09-01):这一段的内容**不在这个 View 里**,由
        /// `AccountLinkingTab` 自己画(那些设置读的是 FeatureSettingsStore,跟统计数据
        /// 没关系)。这里加一个 case 只为了让这个 View 在那一段被选中时画**空**。
        ///
        /// ⚠️ 为什么不干脆在那一段不挂载这个 View:它的整套刷新逻辑建立在"从不因为切 tab
        /// 被卸载重建"上(见类型头注),卸载一次就会把已拉到的统计丢掉、回来重拉一轮。
        /// 所以照旧常驻,只是这一段什么都不画。
        case settings
        var id: Self { self }
    }

    /// 这一刻要画哪张卡。AccountLinkingTab 只在已连接时才挂这个 View,所以这里
    /// 不需要"没有选中项"这一态。
    var selected: Tab

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
    @AppStorage("np:lastfmFootprintCollapsed") private var footprintCollapsed = false
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
    /// 档案卡右上角日历按钮弹出的播放热力图(LastfmHeatmapView)。
    @State private var showHeatmap = false

    private var kind: LastfmStatsService.ChartKind {
        .init(rawValue: kindRaw) ?? .artists
    }
    private var period: LastfmStatsService.Period {
        .init(rawValue: periodRaw) ?? .month
    }

    var body: some View {
        Group {
            switch selected {
            case .stats:
                statsCard
                recentCard
            case .chart: chartCard
            case .onThisDay:
                // 「足迹」段(2026-09-03 由「那年今日」改名):足迹卡在上——它天天有内容、全部从本地
                // 日桶派生零请求;那年今日在下——一年里大半天是空的("那天没听"很正常),放上面会让
                // 整段先看到一句"没有记录"(用户反馈「花样太少」后加足迹卡,随后定下这个顺序)。
                listeningFootprintCard
                onThisDayCard
            // 见 Tab.settings:内容由 AccountLinkingTab 画,这里只保持挂载不掉线。
            case .settings: EmptyView()
            }
        }
        // onAppear/.task 必须挂在**这整个 View**上,不能挂在 switch 里的某一张卡上——
        // 那样切 tab 就相当于把它卸载重挂,详见类型头注。
        //
        // onThisDayCard 是 `if let` 条件视图——没数据时它根本不在视图层级里,挂它身上的
        // onAppear 永远不触发,而 onThisDay 的数据又只能靠这里的刷新去拉,整个区会死锁在
        // "一个请求都没发过"的骨架态(2026-08-11 实测踩坑:档案数字全是"—"、榜单永远骨架、
        // 快照文件不生成)。
        .onAppear {
            stats.refreshBaseline()
            // 榜单收起时不查(那是一次 collector 进程+网络请求);展开那一下由
            // onChange 补上。「那年今日」照常查:它的那句概述留在表头,收起来也要显示。
            if !chartCollapsed { stats.refreshChart(kind: kind, period: period) }
            stats.refreshOnThisDay()
            pageInput = "\(stats.recentPage)"
        }
        .onChange(of: stats.recentPage) { _, page in pageInput = "\(page)" }
        // 切回 App 时补刷一次(2026-09-02 加)。此前**只有** onAppear 和那个 120 秒的轮询
        // 两条路:设置窗口一直开着、人去干别的事再切回来,最坏要干等 120 秒才看到新数据,
        // 而"切回来"恰恰是最想看到活数据的那一刻。
        //
        // 不怕被点爆:`refreshBaseline` 开头就是 TTL 闸(baselineTTL 110s),频繁切换只是
        // 几次字典查找;也刻意**不传** force —— force 是"用户明确要求现在就刷"那颗按钮的
        // 语义,切窗口不是。
        // 用 NSApplication.didBecomeActiveNotification 而不是 scenePhase:这个 App 是
        // .accessory,全仓已有 8 处用的都是这个通知(见 SettingsView / LyricsManagerView),
        // 不为这一处另起一套。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            stats.refreshBaseline()
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
                // 「那年今日」也在这里过一遍,专为**跨零点**:它只在 .onAppear 里拉过
                // 一次,而设置窗口开着不动时 .onAppear 不会再触发 —— 页面开到第二天
                // 就会一直挂着昨天那份(2026-08-17 用户报)。放在 recentPage 那道
                // guard 前面:翻到第二页看历史跟这张卡没有关系,不该把它一起冻住。
                //
                // 平时的开销是一次字典查找:服务侧同时判 TTL 和日历天,没跨天就直接
                // 早退,不会每 2 分钟真发一轮请求(那是三年 ×最多三页的量)。
                stats.refreshOnThisDay()
                // 本机封面兜底表:enrich 缓存自己变了(collector 解析出封面 / 同专辑
                // 预取)不伴随任何 Last.fm 响应,得单独在这里过一遍,否则那些行会一直
                // 灰着(见 refreshLocalCoversIfCacheChanged)。mtime 没变就是一次 stat。
                stats.refreshLocalCoversIfCacheChanged()
                // ⚠️ **这里原来有一道 `guard stats.recentPage == 1 else { continue }`,
                // 2026-09-02 删掉了。** 原注释的理由是"只自动刷第一页:后面几页是历史,内容
                // 不会变,重拉一遍纯属打扰(正看着的那一屏被替换掉)"。那句话对**最近记录那
                // 一列**成立,但它把整条 `refreshBaseline` 一起早退了 —— 而那一次调用同时还
                // 刷着上面三个数字(今天/近 7 天/总 scrobble),那三个跟页码毫无关系。后果是
                // 用户翻到第 2 页之后停在那儿,这整张卡(含三个数字)就**再也不会自动更新**,
                // 而回到第 1 页只发生在 `RecentListensPanel.onDisappear`(卡片离开视图层级时)。
                // 用户 2026-09-02 报的正是这个:「一直停留在十几小时之前,直到我手动点击刷新
                // 才去刷新」—— 手动那颗按钮走 `refreshBaseline(force: true)`,直接绕过了这道
                // guard,所以只有它有效。
                //
                // 现在无条件调。`refreshBaseline` 内部请求的本来就是**当前这一页**
                // (`let requestedPage = recentPage`),所以不会把人从第 5 页弹回第 1 页;
                // 代价是停在历史页时那一屏可能被"当前真实的第 5 页"替换掉 —— 而那只会在
                // **确实有新打卡、页边界移动了**的时候发生,那种时候显示移动后的内容比继续
                // 端着一份陈快照更接近事实。用"永远不会静默冻住"换"历史页可能被原地刷新",
                // 这个取舍是有意的,别再把 guard 加回来。
                stats.refreshBaseline()
            }
        }
    }

    // MARK: - 三个数字

    private var statsCard: some View {
        SettingsCard {
            // 热力图入口放这张卡右上角:热力图就是"今天/近7天/总量"这三个数字沿时间轴的
            // 完整展开,语义同源。⚠️ 按钮必须放在卡片**内容里**(ZStack 角标),不能
            // .overlay 挂在 SettingsCard 外面——macOS 26 的液态玻璃背景(glassEffect)
            // 下外挂 overlay 不渲染(2026-08-18 实测:截图里角标整个不出现)。
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    statCell(value: stats.overview?.today, label: L10n.t("今天"))
                    Divider().padding(.vertical, 10)
                    // 跟待机页那个「近 7 天」用**同一个口径**(自然日对齐,见
                    // IdleListeningStats.lastSevenDays)—— 两处显示同一个名字的数字,
                    // 算法必须一致,否则用户在设置页和待机页会看到两个不同的「近 7 天」。
                    statCell(value: weekValue, label: L10n.t("近 7 天"))
                    Divider().padding(.vertical, 10)
                    statCell(value: stats.overview?.total, label: L10n.t("总 scrobble"))
                }
                Button {
                    showHeatmap = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("播放热力图"))
                .padding(8)
                .popover(isPresented: $showHeatmap, arrowEdge: .bottom) {
                    LastfmHeatmapView()
                }
            }
            // 首次连接的后台引导同步(2026-08-25)。数字/最近记录本身不依赖这轮扫描
            // (轻请求,见 LastfmStatsService 的说明),这里只是说明"热力图/次数合并
            // 还在补全中",不是遮挡整卡的阻塞态。total > 3 跟 syncHistoryIfNeeded 里
            // dailySyncProgress 的既有分界线一致,日常 1-3 页 top-up 不弹这行字。
            if case .syncing(let page, let total) = stats.bootstrapState, total > 3 {
                CardDivider()
                // 2026-09-02 用户问"大概要多久、要不要加进度":这轮扫描本来就有页码
                // (bootstrapState 从 syncHistoryIfNeeded 逐页更新),之前这里只显示一句
                // 通用文案、把页码丢在一边——待机页(IdleStandbyView.syncNote)早就在用
                // 同一个状态画"首次同步历史中（N/M 页）",这里改成同一句、同一个 key,
                // 不是新造一条文案。
                Text(String(format: L10n.t("首次同步历史中（%1$@/%2$@ 页）"), "\(page)", "\(total)"))
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            // 只在**手上什么都没有**时画失败态(2026-09-03)。有快照/上一轮数据在显示时,一次
            // 超时不该让这张卡长出一行「重试」——本机链路 16% 超时,设置页常开时这行会反复
            // 冒出来又消失;失败的观感交给最近记录卡头那处"N 分钟前更新"变暗 + 小图标。
            if stats.baselineFailed, stats.overview == nil {
                CardDivider()
                retryRow { stats.refreshBaseline() }
            }
        }
    }

    /// 「近 7 天」的数值。跟待机页 `IdleStandbyView.weekValue` 是同一份逻辑 —— 两处显示
    /// 同一个名字的数字,口径必须一致(见 IdleListeningStats.lastSevenDays 的注释:
    /// 2026-08-30 从 API 的滚动 168 小时改成自然日对齐,为的是跟环比百分比同源)。
    /// 桶还没同步完时退回 API 值。
    private var weekValue: Int? {
        guard !stats.dailySyncing else { return stats.overview?.week }
        return IdleListeningStats.lastSevenDays(
            dailyCounts: stats.dailyCounts, today: Date(),
            todayCount: stats.overview?.today,
            dayKey: { LastfmStatsService.dayKey($0) })
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
            // 表头挂一条门槛说明。2026-08-18 用户问"刚才那首 Welcome 为什么没记" ——
            // 那是《危险世界》里 7 秒的过场轨,被 minTrackSecs(30 秒)挡掉了。这类
            // "东西没出现"的疑问在界面上完全没有线索可循,只能主动写出来。
            collapsibleHeader(icon: "clock", title: L10n.t("最近记录"),
                              help: L10n.t("Last.fm 规则：需长于 30 秒且播完一半（或满 4 分钟）。专辑过场轨常达不到。"),
                              collapsed: $recentCollapsed) {
                if let at = stats.recentUpdatedAt {
                    // 这一页的数据是轮询来的(远端会话 45 秒一轮、否则两分钟),标一下它
                    // 是什么时候的,免得看着一个不动的列表猜是不是卡住了。
                    //
                    // 上一轮刷新失败但手上有内容时,失败的观感就只在这里:文字变暗 + 一个小叹号,
                    // 悬停说明"显示的是缓存"(2026-09-03)。不弹整行「重试」——列表明明在,
                    // 说"失败"是吓人;而"这份内容是几分钟前的"才是用户真正需要知道的。
                    HStack(spacing: 3) {
                        if stats.baselineFailed {
                            Image(systemName: "exclamationmark.circle").font(.system(size: 9))
                        }
                        Text(String(format: L10n.t("%@更新"), Self.coarseRelative(at)))
                    }
                    .font(.caption)
                    .foregroundStyle(stats.baselineFailed ? .quaternary : .tertiary)
                    .help(stats.baselineFailed
                          ? String(format: L10n.t("上次刷新没有成功，显示的是 %@ 的内容"), Self.absolute(at))
                          : String(format: L10n.t("上次刷新:%@"), Self.absolute(at)))
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
                        // 整行 = 打开 Last.fm 上这首歌的页面;「第 N 次听」那一格是自己的按钮(弹合并
                        // 明细,2026-09-04)。所以整行不再是 Button:Button 会吞掉 label 里一切内嵌
                        // 控件的点击(见 collapsibleHeader 那个 "?" 的注释),改成容器 onTapGesture +
                        // 内嵌 Button —— SwiftUI 里子视图的手势优先,点数字弹明细、点别处开网页。
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
                            // 次数没解析出来时它自己画 `···` 占位(安静的,不转、不闪):不是没有,
                            // 是还没查到 —— 用户反馈"翻到新页这里空一截,看着像坏了"。已确定没有
                            // 次数的曲目连占位都不给,不然它会在极少数确实查不到次数的行上永远挂着,
                            // 变成一个说谎的"正在加载"。
                            PlayCountBadge(
                                artist: t.artist, title: t.title, count: entry.count,
                                unavailable: stats.isPlayCountUnavailable(artist: t.artist, title: t.title),
                                anchorDate: t.date,
                                expectedTotal: stats.trackPlayCounts[
                                    LastfmStatsService.playCountKey(artist: t.artist, title: t.title)])
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
                        .onTapGesture {
                            if let url = Self.trackURL(artist: t.artist, title: t.title) { NSWorkspace.shared.open(url) }
                        }
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
    /// 正在播放那条不参与:它还没被 scrobble,不在 userplaycount 里(实时行自己 +1)。
    ///
    /// ⚠️ 换算本体 2026-08-24 **下沉到 Core**(`RecentPlayOrdinal.ordinals`):停播页的
    /// 「最近听过」是第二个消费方,而这段里有两把不同的尺子(取总数用 playCountKey、数
    /// 「更新的同曲收听」用 PlayCountFold.familyKey 的折叠族),复制一份就等于把用户
    /// 2026-08-21 报的「第 15 次听下面紧跟第 21 次听」的成因复制一份。细节与理由见那边的注释。
    private var recentRows: [(track: LastfmStatsService.RecentTrack, count: Int?)] {
        let counts = RecentPlayOrdinal.ordinals(
            rows: recentHistory.map { (artist: $0.artist, title: $0.title) },
            totals: stats.trackPlayCounts,
            playCountKey: { LastfmStatsService.playCountKey(artist: $0, title: $1) })
        return zip(recentHistory, counts).map { (track: $0, count: $1) }
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

    /// - Parameter help: 非 nil 时在折叠箭头后面挂一个 "?",悬停 0.5 秒或点一下弹出说明。
    ///   这个 "?" 必须留在折叠按钮**外面**——放进 Button 的 label 里点它只会折叠卡片,
    ///   Button 会吃掉 label 内部的 tap,说明根本弹不出来。为此 label 里那个撑满宽度的
    ///   Spacer 也要一并挪出来(否则 "?" 会被顶到最右边、离标题十万八千里),代价是标题
    ///   右侧那段空白不再能点着折叠。这个代价只落在传了 help 的那张卡上,其余保持原样。
    private func collapsibleHeader<Trailing: View>(
        icon: String, title: String, subtitle: String? = nil,
        help: String? = nil,
        collapsed: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: help == nil ? 12 : 5) {
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
                    if help == nil { Spacer(minLength: 12) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed.wrappedValue ? L10n.t("展开") : L10n.t("收起"))
            if let help {
                // 用 QuickHelpLabel 而不是 .help():后者落到 NSView.toolTip,延迟由系统全局
                // 控制、又只认悬停,正是 2026-08-17 用户报过"出得太慢、想点一下就出"的那两点。
                QuickHelpLabel(text: help) { EmptyView() }
                    .font(.system(size: 11))
                    .padding(.top, 2)
                Spacer(minLength: 12)
            }
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

    /// ⚠️ **这里必须有 else** —— 2026-09-01 用户报「那年今日有时候点进去是会空白」的根因就是
    /// 没有:原来整段是 `Group { if let o = stats.onThisDay { ... } }`,而 `onThisDay == nil`
    /// 有四种完全不同的成因(还没取 / 取到了但那几天没听歌 / 请求全挂 / 未连接),全渲染成
    /// **一片什么都没有的空白**,连个"为什么"都没有。
    ///
    /// 其中"请求全挂"那支最毒:`fetchedAt["onthisday"]` 在发请求**之前**就写(刻意的,否则
    /// 一直失败会变成每次露面都重试),于是一次失败占住 6 小时 —— 那 2 分钟一轮的轮询会连着
    /// 6 小时全部早退,界面一直空白,除非重启 App。所以失败态那颗按钮走
    /// `refreshOnThisDay(force: true)` 绕过 TTL,不然点了什么都不会发生。
    ///
    /// 实测这次用户遇到的**不是**"没记录":他的账号 1/2 年前的今天是 0 条,但 3 年前有 111 条
    /// (直接打 Last.fm API 核过),循环本该在 yearsAgo=3 命中 —— 也就是说他看到的空白属于
    /// "还在取"或"取挂了被 TTL 锁住"这两支,而那两支原来都长得跟"没数据"一模一样。
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
                        // 当天为空时结果是放宽到 ±3 天的"那一周"(见 OnThisDayPlanner),句子要说清楚。
                        subtitle: o.isWeek
                            ? (o.yearsAgo == 1
                                ? String(format: L10n.t("去年的这一周听了 %@ 次，最常循环的是这几首"), "\(o.total)")
                                : String(format: L10n.t("%1$@ 年前的这一周听了 %2$@ 次，最常循环的是这几首"),
                                         "\(o.yearsAgo)", "\(o.total)"))
                            : (o.yearsAgo == 1
                                ? String(format: L10n.t("去年今天听了 %@ 次，最常循环的是这几首"), "\(o.total)")
                                : String(format: L10n.t("%1$@ 年前的今天听了 %2$@ 次，最常循环的是这几首"),
                                         "\(o.yearsAgo)", "\(o.total)")),
                        collapsed: $onThisDayCollapsed
                    ) {
                        if let at = stats.onThisDayUpdatedAt {
                            // 跟「最近记录」同一个位置、同一套写法。这张卡 6 小时才重拉一次
                            // (那一天的记录本来也不会变),不标一下的话看着就是一份不知道
                            // 什么时候来的数据。
                            //
                            // 这行相对时间不需要自己的定时器:同一个 section 里最近记录几十秒
                            // 就刷一次、每次都会重算整个 body,它跟着一起更新。
                            Text(String(format: L10n.t("%@更新"), Self.coarseRelative(at)))
                                .font(.caption).foregroundStyle(.tertiary)
                                .help(String(format: L10n.t("上次刷新:%@"), Self.absolute(at)))
                        }
                    }
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
            } else {
                SettingsCard {
                    SettingsRawRow(insetToText: true) {
                        HStack(spacing: 8) {
                            switch stats.onThisDayOutcome {
                            case .pending, .loaded:
                                // .loaded 不该走到这一支(有内容就进上面那支了);真到了也当
                                // "正在取"处理,不要空白。
                                ProgressView().controlSize(.small)
                                Text(L10n.t("正在查那年今日…"))
                                    .foregroundStyle(.secondary)
                            case .empty:
                                Label(L10n.t("过去三年的今天和那几周都没有收听记录"),
                                      systemImage: "calendar.badge.exclamationmark")
                                    .foregroundStyle(.secondary)
                            case .failed:
                                Label(L10n.t("没能取到那年今日——Last.fm 没有响应"),
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                // ⚠️ 必须 force:失败已经占住 6 小时 TTL,不绕过的话这颗按钮
                                // 点下去会被那道闸直接早退,什么都不发生。
                                Button(L10n.t("重试")) { stats.refreshOnThisDay(force: true) }
                            }
                            if stats.onThisDayOutcome != .failed { Spacer() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 收听足迹(2026-09-03)

    /// 全部从热力图日桶 + 账号总数派生(ListeningMilestones,Core 纯函数),零请求;日桶还在首次
    /// 全量同步时不算——那时算出来的"日均/连续"都是残缺数据上的假数。
    @ViewBuilder
    private var listeningFootprintCard: some View {
        if stats.dailySyncing || stats.dailyCounts.isEmpty {
            SettingsCard {
                SettingsRawRow(insetToText: true) {
                    HStack(spacing: 8) {
                        if stats.dailySyncing { ProgressView().controlSize(.small) }
                        Text(L10n.t("首次同步历史之后，这里会出现你的收听足迹"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        } else {
            let today = Date()
            let sum = ListeningMilestones.summarize(
                dailyCounts: stats.dailyCounts, today: today,
                dayKey: { LastfmStatsService.dayKey($0) })
            let avg = IdleListeningStats.dailyAverage(dailyCounts: stats.dailyCounts)
            SettingsCard {
                collapsibleHeader(icon: "figure.walk", title: L10n.t("收听足迹"),
                                  collapsed: $footprintCollapsed) { EmptyView() }
                if !footprintCollapsed {
                    CardDivider()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                        if let days = sum.daysSinceFirst, let first = sum.firstDay {
                            footprintCell(value: String(format: L10n.t("%@ 天"), days.formatted()),
                                          label: String(format: L10n.t("自 %@ 起"), Self.dayLabel(first)))
                        }
                        footprintCell(value: String(format: L10n.t("%@ 天"), sum.recordedDays.formatted()),
                                      label: String(format: L10n.t("有记录 · 日均 %@ 首"), (avg?.average ?? 0).formatted()))
                        if let peak = sum.peak {
                            footprintCell(value: String(format: L10n.t("%@ 首"), peak.count.formatted()),
                                          label: String(format: L10n.t("单日最高 · %@"), Self.dayLabel(peak.day)))
                        }
                        footprintCell(value: String(format: L10n.t("%@ 天"), sum.currentStreak.formatted()),
                                      label: String(format: L10n.t("当前连续 · 最长 %@ 天"), sum.longestStreak.formatted()))
                        footprintCell(value: String(format: L10n.t("%@ 首"), sum.yearToDate.formatted()),
                                      label: sum.priorYearSameSpan.map {
                                          String(format: L10n.t("今年至今 · %1$@ 年同期 %2$@ 首"), "\($0.year)", $0.count.formatted())
                                      } ?? L10n.t("今年至今"))
                        if let total = stats.overview?.total, total > 0 {
                            let next = ListeningMilestones.nextMilestone(total: total)
                            footprintCell(value: String(format: L10n.t("还差 %@ 首"), next.remaining.formatted()),
                                          label: String(format: L10n.t("到第 %@ 次 scrobble"), next.target.formatted()))
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func footprintCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    /// 日桶键 "yyyy-MM-dd" → 按 App 语言格式化的日期(不带时间)。
    private static func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return key }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L10n.locale))
    }
}

/// Last.fm 的品牌红。**不要"顺手规范化"成 `.red` / `systemRed`** —— 这个值不是随手挑的
/// 警告红:原来写的 0.84/0.06/0.03,正是 Last.fm logo 红 #D51007 (213,16,7) 归一化后
/// 四舍五入到两位小数的结果,三个通道全部精确吻合。这一行点下去打开的就是 last.fm 的
/// 曲目页,拿它的品牌色当来源标识是刻意的,不是"红=出错"那套语义色。
///
/// 深色模式换一个更亮的值。品牌红自身相对亮度只有 0.145,压在深色卡片上只有 2.3~2.7:1,
/// 而这个 Label 连图标带「正在记录」四个 caption 字都吃这个颜色。深色值 #FF2419 跟品牌红
/// **同色相**(HSV 色相都是 2.6°),只是推到满明度、饱和度降到 0.90,在 #1E1E1E~#343432
/// 这一带的卡片底色上拿到 3.3~4.4:1。
///
/// 为什么不追 4.5:1:红在 WCAG 亮度公式里的系数只有 0.2126,同色相下把饱和度从 1.00 一路
/// 降到 0.75,相对亮度也只从 0.215 爬到 0.263 —— 任何还看得出是"红"的颜色在深色底上都
/// 够不到 4.5,Apple 自己的 systemRed 深色版(#FF4245)也只有 3.6~4.2。硬凑 4.5 得稀释成
/// #E77570 那种浅鲑鱼粉,品牌识别就没了。取 WCAG 对非文本图形/UI 部件的 3:1 门槛。
private let lastfmBrandRed = Color(nsColor: NSColor(name: "LastfmBrandRed") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 255 / 255, green: 36 / 255, blue: 25 / 255, alpha: 1)  // #FF2419
        : NSColor(srgbRed: 213 / 255, green: 16 / 255, blue: 7 / 255, alpha: 1)   // #D51007
})

/// LiveScrobbleRow 的窄订阅代理(2026-08-19 性能审计 #3):这一行只需要下面六个**低频**
/// 字段,直接 @ObservedObject 整个 PlaybackCoordinator 会让它跟着 currentLine /
/// currentLineIndex / allLines / anchor 这些歌词级高频源一起重算 body —— 统计页开着时
/// 每句歌词一次。这里只转发去重后的所需字段,行的重渲染频率降到"换歌/播放态翻转/
/// 封面到货"。同款教训见「歌词管理 20Hz 过度重渲染」那次。
///
/// ⚠️ assign 的是 publisher 发出的**元素值**(新值),不是回头读属性 —— @Published 在
/// willSet 发射,回读属性拿到的是旧值(项目里实测踩过的坑,见 MenuBarStatusItem 订阅注释)。
@MainActor
private final class LiveRowPlayback: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var isAdBreak = false
    @Published private(set) var artworkImage: NSImage?
    /// 高清替代(见 `PlaybackCoordinator.highResArtworkImage`)。这一行只画到 26pt、分辨率
    /// 无所谓,但**画的是不是同一张图**有所谓:Chrome 里放 YouTube Music 时系统给的可能是
    /// 一帧 MV 画面(实测方大同《白发》给的是 150×84 的 MV 截帧),不取高清替代就会跟
    /// 歌词窗口/灵动岛显示成两张不同的图(用户 2026-09-02 报的就是这类不一致)。
    @Published private(set) var highResArtworkImage: NSImage?
    /// 该显示的那张 —— 别在调用点各写一遍 `?? `。
    var displayArtworkImage: NSImage? { highResArtworkImage ?? artworkImage }
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isAdBreak = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            // 高清替代是换歌后异步下载的,不订阅的话这一行会一直停在系统原图上。
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
        ]
    }
}

/// 「正在记录」活状态行,独立子视图:全 Section 里唯一挂着播放状态订阅的地方(经
/// LiveRowPlayback 窄化),歌词逐行推进引发的高频发布不再拖着这一行陪跑,更不拖三张卡
/// (2026-08-11 发散采纳,2026-08-19 再窄化)。换歌强刷和「第 N 次听」的取数也一并住在
/// 这里 —— 它们的触发源就是播放状态。
///
/// 不播放/开关关着时渲染成零高度占位而不是移出层级:onChange(poller.title) 得一直挂着,
/// 暂停状态下换歌(手动切曲再播放)也要能触发强刷。
private struct LiveScrobbleRow: View {
    @ObservedObject private var stats = LastfmStatsService.shared
    @StateObject private var playback = LiveRowPlayback()
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
        /// 本机播放器现成的位图。**只是兜底** —— 列表里给得出封面时不用它,理由见下面
        /// LiveSource 的构造处和 LastfmStatsService.liveCoverURL。
        var artwork: NSImage?
        var imageURL: URL?     // 跟列表其它行同一张封面(或远端来源时 API 给的那张)
        var confirmed: Bool    // Last.fm 是否已确认收到
        var remote: Bool       // 播放源不是这台 Mac
    }

    private var live: LiveSource? {
        // ① 本机在放、且我们确实在往 Last.fm 记录(开关关着=这首没人在记,不该显示)。
        // 广告不显示(2026-08-19,两次用户截图的"广告正在播放行"都是**这一行**渲染的
        // 本机实时行,不是 Last.fm 数据 —— 空心圆=服务器从未确认,collector 侧其实拦住了):
        // 广告不会被记录,这一行的语义是"正在被 Last.fm 记录的歌",广告不配出现。
        // 判定来自 LocalPlaybackSource(字段启发式+棘轮+AppleScript 权威),SwiftUI 观察
        // 该标记,异步确认晚到几百毫秒也会即时把行收掉。
        if features.lastfmMirrorScrobble, playback.isPlayingNow, !playback.title.isEmpty,
           !playback.isAdBreak {
            // 封面优先跟列表里这首歌/这张专辑的历史行**用同一张**,本机位图只在列表给不出
            // 时兜底(第一次听这首歌 / 这张专辑的第一首)。
            //
            // 2026-08-17 改。原来这里无条件用 poller.artworkImage —— 那是 media-control 从
            // Apple Music 的 Now Playing 会话读到的 600×600 图,跟下面历史行走的
            // coverURL(for:)(第一级是 Last.fm scrobble 自带的 174px 图)是两条毫不相干的
            // 链路。同一首歌因此在同一张卡里显示两张不同的图,等它被 scrobble 成历史行才
            // "变回来"(用户报的现象)。实测这两张不是同一个文件:Prince《1999》,Apple 那版
            // 偏暗紫、Last.fm 那版偏亮蓝,缩到 26pt 一眼能看出色调不同,不是清晰度差别。
            let listCover = stats.liveCoverURL(artist: playback.artist, title: playback.title,
                                               album: playback.album)
            return LiveSource(title: playback.title,
                              artist: canonicalLiveArtist(localArtist: playback.artist),
                              artwork: playback.displayArtworkImage, imageURL: listCover,
                              confirmed: serverConfirms(playback.title), remote: false)
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
    /// 实时行的歌手名:优先用 Last.fm 认的规范写法。
    ///
    /// 2026-08-21 用户截图:实时行写「周杰伦」(Apple Music 的本地标签)、紧接着的历史行全是
    /// 「周杰倫」(Last.fm 规范名),同一首歌两种写法上下并排。本机标签只说明"我们这台机器
    /// 怎么写",而这一行的语义是"**Last.fm 正在记录的**那首歌"(见 LiveSource 的注释),
    /// 用它自己的写法才自洽 —— 而且下面历史行迟早会以规范名出现,提前统一就不会看着像
    /// 两首歌。
    ///
    /// 只在服务器那条 nowplaying 确实是同一首(标题对得上)时才换,否则退回本机写法,不猜。
    private func canonicalLiveArtist(localArtist: String) -> String {
        guard let np = stats.apiNowPlaying, !np.artist.isEmpty,
              matchesLocalTrack(np.title) else { return localArtist }
        return np.artist
    }

    private func matchesLocalTrack(_ title: String) -> Bool {
        !playback.title.isEmpty && looseSameTitle(title, playback.title)
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
        guard let live, !live.remote, let anchor = PlaybackCoordinator.shared.anchor else { return nil }
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
                // 容器 onTapGesture + 内嵌「第 N 次听」按钮,不再套 Button —— 理由同历史行(Button 会
                // 吞掉 label 内嵌控件的点击),2026-09-04 改。
                HStack(spacing: 10) {
                    Group {
                        // 顺序刻意是 URL 优先、本机位图兜底(2026-08-17 从反过来改成
                        // 这样):这一行要跟它下面那些历史行长一样,而那些行用的就是
                        // 这个 URL。本机位图只在列表里找不到参照时才上场 —— 见
                        // LiveSource.artwork 与 LastfmStatsService.liveCoverURL。
                        if let url = live.imageURL {
                            CachedImage(url: url) {
                                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                            }
                        } else if let img = live.artwork {
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
                    // 这次播放已被 scrobble 时用落库的权威次数,否则用换歌时取的
                    // nowPlayingCount(见 absorbedRecent 注释:后者取晚了会多算一)。
                    // 老歌重逢的小情绪点:"第 208 次听" —— 点一下看这 208 次是哪几种写法凑的。
                    // unavailable 传 true:实时行没有次数时什么都不画,不给 `···` 占位(原样)。
                    // expectedTotal 传 nil:这个数含还没落库的这一次,跟明细合计对不上是正常的。
                    PlayCountBadge(
                        artist: live.artist, title: live.title,
                        count: absorbedRecent?.count ?? stats.nowPlayingCount,
                        unavailable: true, anchorDate: nil, expectedTotal: nil)
                    if live.confirmed {
                        Label(L10n.t("正在记录"), systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(lastfmBrandRed)
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
                .onTapGesture {
                    if let url = LastfmStatsSection.trackURL(artist: live.artist, title: live.title) {
                        NSWorkspace.shared.open(url)
                    }
                }
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
        .onChange(of: playback.title) { _, _ in
            // 本机换歌 = 上一首刚被 scrobble。给 collector 十秒把记录提交出去,然后无视缓存
            // 强刷一次 —— 刚唱完的歌马上出现在列表顶上,顺带把 apiNowPlaying 换成新歌
            // (红点的服务器确认就是靠这次刷新到位的)。
            pendingForceRefresh?.cancel()
            pendingForceRefresh = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, stats.recentPage == 1 else { return }
                // collector 的 feed 活着时不发:它在镜像 scrobble 成功后 5 s 就会提前拉一次、
                // 落盘,这边 ≤5 s 内读到——同样 ~10 s 见到上一首,却是 0 个 App 请求
                // (2026-09-03,见 LastfmStatsService 的 collector feed 一节)。
                guard !stats.feedIsFresh else { return }
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
                // feed 活着时也不发:远端会话正是 collector 15 s 一拍在盯的东西,这里再拉是重复。
                guard stats.recentPage == 1, !playback.isPlayingNow, remoteSessionLikelyActive,
                      !stats.feedIsFresh else { continue }
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
