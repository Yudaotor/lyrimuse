import AppKit
import LyrimuseCore
import SwiftUI

// 「最近听过」:按天分组、每行带封面与「第 N 次听」、底部翻页。
//
// 2026-08-27 从 IdleStandbyView.swift 的 private IdleRecentPanel 搬出来、去掉 Idle 前缀、
// 改 internal —— 停播页(IdleStandbyView)和歌词窗口的「播放记录」面板(LyricsWindowView,
// 取代原来那个 AppleScript 拿不到目录内容时就失效的「待播清单」)现在共用同一份实现,
// 不是各写一份:「第 N 次听」那两把尺子(playCountKey vs PlayCountFold.familyKey)抄错
// 一处就是 2026-08-21 那个「第 15 次听下面紧跟第 21 次听」的成因,只该有一份能改。
//
// 同一天(2026-08-27)又加了 showsCard/onArtwork 两个外观参数:歌词窗口那边用户反馈
// "这个列表带了一张卡片背景,感觉像盖了一层东西,不是歌词真的被换掉了"——歌词文字本身
// 从来没有卡片背景,直接铺在封面模糊背景上;这个列表现在也能选择用同一种"裸铺"外观,
// 详见 showsCard/onArtwork 声明处的注释。停播页(IdleStandbyView)不传这两个参数、
// 维持原来"仪表盘式多张卡片"的样子,两处各自符合各自的视觉语言。

/// 通高的「最近听过」:按天分组、每行带封面与「第 N 次听」、底部翻页。
///
/// 两处必须知道的既有约束:
/// - **「第 N 次听」的换算走 Core 里那份共享实现**(`RecentPlayOrdinal`),不是在这里再抄一遍
///   减法 —— 那段有两把不同的尺子,抄错一处就是用户 2026-08-21 报的「第 15 次听下面紧跟
///   第 21 次听」。
/// - **`recentPage` 是服务层的共享状态**:设置页那张「最近记录」卡、停播页、歌词窗口的
///   「播放记录」面板看的都是同一个页码。所以这里退场时把它拨回第 1 页 —— 不然翻到第 7 页
///   之后,别的消费方会一直停在第 7 页,而它的自动刷新只在第 1 页才跑(等于把那边的刷新
///   悄悄关掉了)。
struct RecentListensPanel: View {
    let onOpenTrack: (String, String) -> Void
    /// 卡片外观(圆角磨砂底 + 描边)要不要画。默认 true,匹配停播页"多张卡片摆在一起"的
    /// 仪表盘式布局;歌词窗口的「播放记录」传 false —— 那边是**直接替换歌词文字本身**,
    /// 歌词从来没有卡片背景,这个列表也不该有,不然观感像"盖了一层"而不是"歌词真的
    /// 换了"(2026-08-27 用户反馈)。
    var showsCard = true
    /// 文字/图标颜色要不要走"有封面背景就固定白色系"那套(跟整扇歌词窗口同一个判据
    /// `hasArtworkBackground`)。默认 false——停播页背景是统一柔光,不是铺满的封面模糊图,
    /// 系统语义色(`.primary`/`.secondary`/`.tertiary`)本来就够用;歌词窗口传 true。
    /// ⚠️ 主要跟 `showsCard=false` 搭配用:卡片自带的磨砂材质本来就能保证系统语义色在
    /// 任意背景上可读,`onArtwork` 是给"直接铺在背景上、没有材质垫底"这种情况准备的。
    var onArtwork = false

    @ObservedObject private var stats = LastfmStatsService.shared
    @State private var hoveredID: String?

    private enum Item: Identifiable {
        case header(String)
        case row(LastfmStatsService.RecentTrack, Int?)

        var id: String {
            switch self {
            case .header(let s): return "h:" + s
            case .row(let t, _): return "r:" + t.id
            }
        }
    }

    private var primaryTextColor: Color { onArtwork ? .white : .primary }
    private var secondaryTextColor: Color { onArtwork ? .white.opacity(0.6) : .secondary }
    private var tertiaryTextColor: Color { onArtwork ? .white.opacity(0.4) : Color(nsColor: .tertiaryLabelColor) }
    private var hoverFillColor: Color { onArtwork ? .white.opacity(0.10) : Color.primary.opacity(0.07) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // ⚠️ 这里**不能**再跟一个 Spacer:ScrollView 和 Spacer 都是可伸缩的,同在一个
            // VStack 里会平分剩余高度,把列表压成半截。让 content 自己吃满,翻页条靠
            // VStack 自然排在它下面。
            content
                .frame(maxHeight: .infinity, alignment: .top)
            if stats.recentTotalPages > 1 { pager }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if showsCard {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1))
            }
        }
        .onDisappear {
            if stats.recentPage != 1 { stats.goToPage(1) }
        }
    }

    // MARK: 卡头

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t("最近听过"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondaryTextColor)
            Spacer(minLength: 0)
            if let updated = stats.recentUpdatedAt {
                // 上一轮刷新失败但列表还在:只把这行时间变暗 + 小叹号,不换成失败态
                // (跟设置页最近记录卡头同一套观感,2026-09-03)。
                HStack(spacing: 3) {
                    if stats.baselineFailed {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 9))
                    }
                    Text(Self.agoText(updated))
                }
                .font(.system(size: 10))
                .foregroundStyle(tertiaryTextColor.opacity(stats.baselineFailed ? 0.6 : 1))
                .help(stats.baselineFailed
                      ? String(format: L10n.t("上次刷新没有成功，显示的是 %@ 的内容"),
                               updated.formatted(date: .abbreviated, time: .standard))
                      : updated.formatted(date: .abbreviated, time: .standard))
            }
            Button {
                stats.refreshBaseline(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryTextColor)
            .disabled(stats.recentPaging)
            .help(L10n.t("刷新"))
        }
        .padding(.bottom, 10)
    }

    // MARK: 列表

    @ViewBuilder private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .header(let label):
                            Text(label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(tertiaryTextColor)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .padding(.horizontal, 4)
                        case .row(let track, let count):
                            row(track, count)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            // 下拉刷新手势(2026-08-26 用户要求):跟表头那颗刷新按钮完全同一个动作
            // (refreshBaselineAndWait 只是那个动作的可 await 版本,见其声明处注释)——
            // 刷新的是当前正在看的这一页,不强制跳回第 1 页,跟按钮的既有行为保持一致。
            .refreshable { await stats.refreshBaselineAndWait(force: true) }
        }
    }

    private func row(_ track: LastfmStatsService.RecentTrack, _ count: Int?) -> some View {
        let hovering = hoveredID == track.id
        return HStack(spacing: 10) {
            CachedImage(url: stats.coverURL(for: track)) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LastfmStatsSection.stableColor(for: track.artist).opacity(0.5))
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text("\(track.title) · \(track.artist)")
                .font(.system(size: 12.5))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if let count {
                Text(String(format: L10n.t("第 %@ 次"), "\(count)"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(secondaryTextColor)
            }
            if let date = track.date {
                Text(RelativeDayFormat.timeFormatter.string(from: date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(tertiaryTextColor)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? hoverFillColor : .clear))
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? track.id : (hoveredID == track.id ? nil : hoveredID) }
        // 点击 = 在 Apple Music 里**打开**这首歌的页面。刻意不说「播放」:music:// 的语义
        // 就是原生跳页、不动播放队列,它不会起播(要真起播只能走资料库 AppleScript,
        // 纯流媒体曲目查不到)。
        .onTapGesture { onOpenTrack(track.title, track.artist) }
        .help(L10n.t("在 Apple Music 中打开"))
    }

    @ViewBuilder private var emptyState: some View {
        if stats.recentPaging {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.vertical, 24)
        } else if stats.baselineFailed {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("没拉到最近记录"))
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryTextColor)
                Button(L10n.t("重试")) { stats.refreshBaseline(force: true) }
                    .controlSize(.small)
            }
            .padding(.vertical, 16)
        } else {
            Text(L10n.t("还没有收听记录"))
                .font(.system(size: 12))
                .foregroundStyle(tertiaryTextColor)
                .padding(.vertical, 16)
        }
    }

    // MARK: 翻页

    private var pager: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button(L10n.t("上一页")) { stats.goToPage(stats.recentPage - 1) }
                .disabled(stats.recentPage <= 1 || stats.recentPaging)
            Text("\(stats.recentPage) / \(max(stats.recentTotalPages, 1))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(secondaryTextColor)
            Button(L10n.t("下一页")) { stats.goToPage(stats.recentPage + 1) }
                .disabled(stats.recentPage >= stats.recentTotalPages || stats.recentPaging)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.top, 10)
    }

    // MARK: 数据

    /// 行 + 日期分隔行。正在播放那条(`date == nil`)整个排除:它还没被 scrobble,不在
    /// userplaycount 里,喂进 ordinals 会把整列次数错开一位;停播页本来也不该有它。
    private var items: [Item] {
        let rows = stats.recent.filter { $0.date != nil }
        guard !rows.isEmpty else { return [] }
        let counts = RecentPlayOrdinal.ordinals(
            rows: rows.map { (artist: $0.artist, title: $0.title) },
            totals: stats.trackPlayCounts,
            playCountKey: { LastfmStatsService.playCountKey(artist: $0, title: $1) })
        var out: [Item] = []
        var lastLabel: String?
        for (row, count) in zip(rows, counts) {
            guard let date = row.date else { continue }
            let label = Self.dayLabel(date)
            if label != lastLabel {
                out.append(.header(label))
                lastLabel = label
            }
            out.append(.row(row, count))
        }
        return out
    }

    // MARK: 格式化

    private static func dayLabel(_ date: Date) -> String { RelativeDayFormat.dayLabel(date) }

    private static func agoText(_ date: Date) -> String {
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return L10n.t("刚刚更新") }
        if mins < 60 { return String(format: L10n.t("%@ 分钟前更新"), "\(mins)") }
        return String(format: L10n.t("%@ 小时前更新"), "\(mins / 60)")
    }
}

/// 「今天 / 昨天 / 8月16日」这套日期分隔行文案,和 HH:mm 时间戳格式化——歌词窗口的
/// 「播放记录」面板两种状态(已连 Last.fm 的 RecentListensPanel / 未连的
/// PendingListensPanel,见 LyricsWindowView.swift)共用同一份,不各写一份让两个列表
/// 的日期分组标准跑偏。
///
/// 分隔行**刻意不带条数** —— 一页可能只有一部分数据,写「今天 · 12 首」容易被读成
/// 全天真值。
enum RelativeDayFormat {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()

    static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L10n.t("今天") }
        if cal.isDateInYesterday(date) { return L10n.t("昨天") }
        return dayFormatter.string(from: date)
    }
}

// MARK: - 没连 Last.fm 时的替代内容:本地待补提交

/// 没连 Last.fm 时,「播放记录」类面板显示的内容:本地静默记的、还没提交的收听
/// (collector 不管连没连账号都在往本地记,见 ScrobbleBackfillService 类头注释)。
/// 跟设置页「账号 → Last.fm」标签的 pendingListensRow 共用同一个数据源、同一套
/// "多久算太旧"的规则,不在这里另起一份判定;比那边多了一段 5 秒 mtime 轮询——那边
/// 挂在整张设置卡上跟着卡的生命周期走,这里没有更外层的卡可挂,自己管自己的。
///
/// 2026-08-27 起两处消费:歌词窗口的「播放记录」按钮(LyricsWindowView.ListenHistoryPane)
/// 和停播页右列(IdleStandbyView),跟 RecentListensPanel 同一个道理放在同一个文件——
/// 「连了 Last.fm 用哪份数据、没连用哪份数据」这套判断只该有一处。`showsCard`/`onArtwork`
/// 两个外观参数跟 RecentListensPanel 同一套,理由见那边的声明处注释。
///
/// 只读:不提供补提交/删除。补提交需要连账号(没连提交不到任何地方去,跟
/// pendingListensRow 里"按钮只在连着账号时给"同一个理由);删除留给设置页那边
/// 已有的、更完整的管理入口(能悬停删单条),这里给一个"去连接"的入口就够了。
struct PendingListensPanel: View {
    /// 点一行 = 在 Apple Music 里打开这首歌——跟 RecentListensPanel 的 onOpenTrack 同一个
    /// 语义、同一份实现(两处调用点本来就把同一个闭包传给了两个面板,见其声明处注释)。
    /// 2026-08-27 补上:之前这个面板是纯只读展示,没有点击跳转,跟"已连接"那份体验不一致。
    var onOpenTrack: (String, String) -> Void
    var showsCard = true
    var onArtwork = false

    @ObservedObject private var backfill = ScrobbleBackfillService.shared
    @State private var hoveredID: String?

    private enum Item: Identifiable {
        case header(String)
        case row(ScrobbleBackfillService.Item)
        var id: String {
            switch self {
            case .header(let s): return "h:" + s
            case .row(let i): return "r:\(i.uts)"
            }
        }
    }

    private var primaryTextColor: Color { onArtwork ? .white : .primary }
    private var secondaryTextColor: Color { onArtwork ? .white.opacity(0.6) : .secondary }
    private var tertiaryTextColor: Color { onArtwork ? .white.opacity(0.4) : Color(nsColor: .tertiaryLabelColor) }
    private var hoverFillColor: Color { onArtwork ? .white.opacity(0.10) : Color.primary.opacity(0.07) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if showsCard {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1))
            }
        }
        .onAppear { backfill.refreshPending() }
        // 面板开着的这段时间里盯住收听日志:同 AccountLinkingTab.pendingListensRow
        // 那份 5 秒 mtime 轮询(理由同它的注释:按秒轮询 collector 子进程太重,
        // stat 一个文件几乎免费,变了才真去重算)。
        .task {
            var seen = ScrobbleBackfillService.listenLogModifiedAt()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                let now = ScrobbleBackfillService.listenLogModifiedAt()
                guard now != seen, !backfill.busy else { continue }
                seen = now
                backfill.refreshPending()
            }
        }
    }

    // MARK: 卡头

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t("待推送的收听"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondaryTextColor)
            Spacer(minLength: 0)
            if backfill.busy { ProgressView().controlSize(.small) }
            // 深链到设置的 Last.fm 详情页——跟歌词窗口"收听次数"那行(见
            // InfoPanelListeningRows)同一套跳转机制:requestSettings 落信箱 +
            // NSApp.activate + openSettings,两条路都要发,窗口未建/已开着都能对
            // (见 AppActions.requestSettings 注释)。
            Button {
                AppActions.shared.requestSettings(.account(.lastfm))
                NSApp.activate(ignoringOtherApps: true)
                AppActions.shared.openSettings?()
            } label: {
                Text(L10n.t("连接 Last.fm…"))
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryTextColor)
        }
        .padding(.bottom, 10)
    }

    // MARK: 列表

    @ViewBuilder private var content: some View {
        if items.isEmpty {
            Text(L10n.t("本地还没有待推送的收听"))
                .font(.system(size: 12))
                .foregroundStyle(tertiaryTextColor)
                .padding(.vertical, 16)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .header(let label):
                            Text(label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(tertiaryTextColor)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .padding(.horizontal, 4)
                        case .row(let listen):
                            row(listen)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func row(_ item: ScrobbleBackfillService.Item) -> some View {
        let hovering = hoveredID == "r:\(item.uts)"
        return HStack(spacing: 10) {
            // 这份数据本身没有封面字段(collector 记录待补收听时不取图,只记
            // 歌手/歌名/专辑),但这几首歌**本机确实播过**——不然不会进这份待补清单。
            // 播放当时 collector 解析歌词早就顺手把封面存进本机 enrich 缓存了,直接照
            // RecentListensPanel「本机命中」那一级(LastfmStatsService.coverURL 的
            // localCovers 分支)查一次同一份缓存即可,不需要等提交成功、也不需要
            // Last.fm 那几级(scrobble 自带图/getinfo/同专辑兄弟)——待补条目压根不在
            // Last.fm 那边,那几级本来就查不到东西。查不到时退回原来那个音符占位色块,
            // 跟 RecentListensPanel 未命中时的观感一致。
            CachedImage(url: EnrichCacheReader.coverURL(
                artist: item.artist, title: item.title, album: item.album ?? "")) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LastfmStatsSection.stableColor(for: item.artist).opacity(0.5))
                    Image(systemName: "music.note")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text("\(item.title) · \(item.artist)")
                .font(.system(size: 12.5))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(RelativeDayFormat.timeFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(item.uts))))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(tertiaryTextColor)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? hoverFillColor : .clear))
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? "r:\(item.uts)" : (hoveredID == "r:\(item.uts)" ? nil : hoveredID) }
        // 跟 RecentListensPanel 同一个语义:music:// 原生跳页,不动播放队列、不算起播。
        .onTapGesture { onOpenTrack(item.title, item.artist) }
        .help(L10n.t("在 Apple Music 中打开"))
    }

    // MARK: 数据

    /// 行 + 日期分隔行,倒序(最近的在最上面,跟 RecentListensPanel 一致)。
    private var items: [Item] {
        let rows = (backfill.pending?.items ?? []).sorted { $0.uts > $1.uts }
        guard !rows.isEmpty else { return [] }
        var out: [Item] = []
        var lastLabel: String?
        for listen in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(listen.uts))
            let label = RelativeDayFormat.dayLabel(date)
            if label != lastLabel {
                out.append(.header(label))
                lastLabel = label
            }
            out.append(.row(listen))
        }
        return out
    }
}
