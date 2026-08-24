import AppKit
import LyrimuseCore
import SwiftUI

/// 停播页的「三区版」(2026-08-24 用户按选型册定的排布):
///
/// ```
/// ┌───────────────┬───────────────┐
/// │ 收听总览       │               │
/// ├───────────────┤  最近听过      │  ← 右列通高
/// │ 上次那首       │               │
/// │ + 一句歌词     │               │
/// └───────────────┴───────────────┘
/// ```
///
/// 只在**窗口够宽**时用(判据在 LyricsWindowView.body,跟播放态那条 640pt 断点同一个思路 ——
/// 窄窗硬塞两列会挤成一团);窄窗仍走原来的居中 `idleWelcomeView`。
///
/// 未连 Last.fm 时左上和右列都没有数据,整页退化成「只有唱片 hero 居中」——不画空卡、
/// 不画破折号,沿用「没连账号也不难看」那条既有契约。
struct IdleStandbyView: View {
    let player: PlaybackPlayer
    /// 「继续播放」:AM 三段式 / Spotify 自带恢复,失败兜底激活 App。逻辑留在
    /// LyricsWindowView(与原欢迎态同一份),这里只负责按钮。
    let onResume: () -> Void
    let onOpenPlayer: () -> Void
    /// (歌名, 歌手) → 经 iTunes Search 解析后 music:// 打开那张专辑页。
    let onOpenAlbum: (String, String) -> Void
    /// (歌名, 歌手) → 打开这首歌在 Apple Music 的曲目页。
    let onOpenTrack: (String, String) -> Void

    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {
        Group {
            if stats.isConnected {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 20) {
                        IdleOverviewCard()
                        IdleLastTrackHero(player: player, onResume: onResume,
                                          onOpenPlayer: onOpenPlayer, onOpenAlbum: onOpenAlbum)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    IdleRecentPanel(onOpenTrack: onOpenTrack)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // 右上角那颗音量/AirPlay 胶囊是**窗级 overlay**、浮在内容之上,
                        // 而且没有 !isIdle 守卫(停播时读得到音量就照样在场)。实测它的下缘
                        // 落在窗顶 ~50pt,正好压着这张卡的顶边 —— 往下让 18pt 躲开它。
                        .padding(.top, 18)
                }
            } else {
                IdleLastTrackHero(player: player, onResume: onResume,
                                  onOpenPlayer: onOpenPlayer, onOpenAlbum: onOpenAlbum)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 34, bottom: 26, trailing: 34))
        // 停播页可能一挂几小时,只靠 onAppear 一次会让「今天 N 首」越挂越旧(与原
        // IdleLastfmSection 同一套节流):3 分钟轮一次档案数字;refreshDailyCounts
        // **没有 TTL**(每次都真发请求 + 落盘),每 20 轮(约 1 小时)才带它一次 ——
        // 走势条和日均都吃这份桶,但绝不能因为多了一个消费方就调快。
        .task {
            var tick = 0
            while !Task.isCancelled {
                // 守卫放在**循环里**而不是循环外:放外面的话,页面开着期间在设置里连上/断开
                // 账号都要等视图重建才生效(连上→永远不开始轮询,断开→白轮但拉不到)。
                // 服务侧那几个 refresh 自己也 guard credentials,所以断开后这里是空转。
                if stats.isConnected {
                    stats.refreshBaseline()
                    if tick % 20 == 0 { stats.refreshDailyCounts() }
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 180_000_000_000)
            }
        }
    }
}

// MARK: - 背景

/// 停播页背景(2026-08-24,用户从七版简约方案里选的 V2「中心柔光」)。
///
/// 三层:深底 + 一团锚在唱片后面的柔光 + 四周压暗。它是那七版里**唯一参与版面层级**的一版 ——
/// 这一页有三块内容(数字 / 唱片 / 列表),谁是主角本来没有交代;柔光把重心定在唱片上、四角退开。
/// 相对「拼贴专辑封面」那条路线,统一背景白拿三件:零网络(封面存的是远端 URL、靠不住)、
/// 不必再做「量亮度反算黑罩」的闭环(随机封面抽到亮的会让文字读不了)、以及浅色外观下
/// **不用切固定白字**(系统语义色继续可用,省掉一次全窗配色重构)。
///
/// ⚠️ 深浅两套**显式钉死**,刻意不用 `Color.primary.opacity()` 那种「自动适配」的写法:
/// 它在深色下会把压暗层变成**提亮**层、方向正好相反。原型第一版就是这么错的 —— 实测深色下
/// 四角 0.232、中心 0.071,角比中心亮三倍多,跟「四周压暗」的意图完全反了。压暗层一律用黑色。
///
/// 半径按窗口尺寸取**比例**、不写死点值:原型是在 1470×858 上调的,而这扇窗最小能拖到 520 宽,
/// 写死的 620/380/980 在窄窗上会糊成一片。系数就是原型那几个值除以 1470。
struct IdleStandbyBackground: View {
    /// 宽窗时唱片在左栏下半、窄窗时它居中 —— 柔光要跟着它走,否则光和主体分家。
    let wide: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let dark = scheme == .dark
            let unit = max(geo.size.width, geo.size.height)
            ZStack {
                (dark ? Color(red: 0.043, green: 0.039, blue: 0.039)
                      : Color(red: 0.867, green: 0.859, blue: 0.851))
                RadialGradient(
                    colors: [Color.white.opacity(dark ? 0.075 : 0.85), .clear],
                    center: wide ? UnitPoint(x: 0.26, y: 0.62) : UnitPoint(x: 0.5, y: 0.52),
                    startRadius: unit * 0.014, endRadius: unit * 0.42)
                RadialGradient(
                    colors: [.clear, Color.black.opacity(dark ? 0.30 : 0.06)],
                    center: .center, startRadius: unit * 0.26, endRadius: unit * 0.67)
            }
        }
    }
}

// MARK: - 左上:收听总览

/// 三个大数字 + 近 30 天走势条。
///
/// 口径上有三处必须说清楚(否则同屏两个数字会当场打架):
/// - **「今天」只有一个来源**:大数字和走势条最后那根柱子都取 `overview.today`(API 的
///   @attr.total,TTL 110s)。天粒度桶那边也有「今天」,但它没有 TTL、可能滞后近一小时,
///   两处各取一个就会自相矛盾。
/// - **「近 7 天」是滚动 7 天**,不是自然周(`overview.week` 取的是 now − 7×86400)。原来
///   界面上写的是「本周」,那句话本身在撒谎,这里改成「近 7 天」。
/// - **环比与日均都只在桶里算**,跟上面那两个大数字不同源;而且桶没同步完时算出来是假的,
///   所以 `dailySyncing` 期间这两行整体缺席、宁可不显示。
private struct IdleOverviewCard: View {
    @ObservedObject private var stats = LastfmStatsService.shared

    private static let sparkDays = 30
    /// 悬停在走势图第几天上(nil = 没悬停)。读数换到图下面那行说明里,不叠浮层。
    @State private var hoverIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 34) {
                bigStat(value: stats.overview?.today, label: L10n.t("今天"))
                bigStat(value: stats.overview?.week, label: weekLabel)
                bigStat(value: stats.overview?.total, label: totalLabel)
            }
            if stats.dailySyncing {
                Text(stats.dailySyncProgress.map {
                    String(format: L10n.t("正在同步历史（%@）"), $0)
                } ?? L10n.t("正在同步历史"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if !series.isEmpty, series.contains(where: { $0 > 0 }) {
                trendChart
                Text(trendCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .animation(nil, value: hoverIndex)
            }
        }
    }

    private func bigStat(value: Int?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // 大号独立数值用**比例字形**:等宽会把每个数字撑成 0 的宽度,`107` 这种在
            // 30pt 上看起来松垮。等宽只留给需要纵向对齐的列(最近听过那边的次数/时间)。
            Text(value.map { Self.grouped($0) } ?? "—")
                .font(.system(size: 30, weight: .semibold))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 数值

    /// 近 30 天每天一根,正序。最后那根用 `overview.today` 盖掉桶里的值 —— 见类型注释里
    /// 「今天只有一个来源」那条。
    private var series: [Int] {
        var s = IdleListeningStats.series(
            dailyCounts: stats.dailyCounts, endingAt: Date(), days: Self.sparkDays,
            dayKey: { LastfmStatsService.dayKey($0) })
        if let today = stats.overview?.today, !s.isEmpty { s[s.count - 1] = today }
        return s
    }

    private var weekLabel: String {
        let base = L10n.t("近 7 天")
        guard !stats.dailySyncing,
              let d = IdleListeningStats.weekOverWeekDelta(
                dailyCounts: stats.dailyCounts, today: Date(),
                dayKey: { LastfmStatsService.dayKey($0) })
        else { return base }
        let pct = Int((d * 100).rounded())
        // 0% 时不写「较上周 +0%」,直接只留标题 —— 一个恒等式没有信息量。
        guard pct != 0 else { return base }
        return base + " · " + String(format: L10n.t("较上周 %@"), pct > 0 ? "+\(pct)%" : "\(pct)%")
    }

    private var totalLabel: String {
        let base = L10n.t("累计")
        guard !stats.dailySyncing,
              let avg = IdleListeningStats.dailyAverage(dailyCounts: stats.dailyCounts)
        else { return base }
        return base + " · " + String(format: L10n.t("日均 %1$@ · %2$@ 天"),
                                     "\(avg.average)", "\(avg.days)")
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: 走势

    /// 近 30 天走势。
    ///
    /// 2026-08-24 从「30 根柱子」改成**面积 + 折线**(用户实测反馈「可读性不好以及不好看」)。
    /// 柱子在这个尺寸下必然难看:左栏约 660pt 宽、30 个点,每根摊到 22pt 却只有 40pt 高 ——
    /// 宽高相当,读出来是一排色块而不是趋势。按「数据的职责挑图形」:这里的职责是
    /// **时间上的走势**,单序列的默认形式就是面积图;柱子适合的是「比大小」。
    ///
    /// 同时修掉三处:
    /// - 原来那条「日均线」注释写虚线、实际画成一条通宽实线,读起来像边框 —— **整条删掉**:
    ///   52pt 高的带子上,一条没有标签的通宽细线只会被当成分隔线;而「日均」这个数本来就写在
    ///   第三个大数字的说明里(「累计 · 日均 112 · 316 天」),不必在图上再画一遍;
    /// - 0 的那天留了 2pt 地板,在左端变成几道莫名的小横杠 —— 面积图不需要地板,
    ///   曲线回到基线本身就是「那天没听」;
    /// - 最高那根染成饱和蓝块,又大又跳 —— 饱和色只该用在**小标记**上,所以改成只点亮
    ///   「今天」那一个端点(它也才是这一栏真正要回答的「今天算多还是少」)。
    private var trendChart: some View {
        let s = series
        let peak = max(1, s.max() ?? 1)
        // 左右各留 7pt:「今天」那个端点(8pt 直径 + 2pt 描边)正好压在最右边一个点上,
        // 不留边它会贴着边缘、描边糊成一团。
        let inset: CGFloat = 7
        // ⚠️ 绘制放在独立方法里而不是直接写在 GeometryReader 的闭包中:ViewBuilder 闭包
        // 里不允许声明 func(算点位要一个),硬塞会报 "closure containing a declaration"。
        return GeometryReader { geo in
            plot(size: geo.size, series: s, peak: peak, inset: inset)
        }
        .frame(height: 52)
    }

    private func plot(size: CGSize, series s: [Int], peak: Int,
                      inset: CGFloat) -> some View {
        let w = size.width
        let h = size.height
        let n = max(1, s.count - 1)
        let usable = max(1, w - inset * 2)
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: inset + usable * CGFloat(i) / CGFloat(n),
                    y: h - (h - 3) * CGFloat(s[i]) / CGFloat(peak))
        }
        return ZStack {
            // 基线:实心细线、只比底色重一档,最收敛的一层
            Path {
                $0.move(to: CGPoint(x: 0, y: h))
                $0.addLine(to: CGPoint(x: w, y: h))
            }
            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            // 面积:同一个色相的**淡淡一层**,不是饱和块
            Path { p in
                guard !s.isEmpty else { return }
                p.move(to: CGPoint(x: inset, y: h))
                for i in s.indices { p.addLine(to: pt(i)) }
                p.addLine(to: CGPoint(x: inset + usable, y: h))
                p.closeSubpath()
            }
            .fill(LinearGradient(
                colors: [Color.accentColor.opacity(0.38), Color.accentColor.opacity(0.03)],
                startPoint: .top, endPoint: .bottom))
            // 折线:2pt、圆头圆角
            Path { p in
                guard !s.isEmpty else { return }
                p.move(to: pt(0))
                for i in s.indices.dropFirst() { p.addLine(to: pt(i)) }
            }
            .stroke(Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            // 悬停那一天:竖线 + 点(不弹浮层,读数直接换到下面那行说明里 ——
            // 40pt 高的带子上再叠一个气泡必然要处理裁切和碰撞,不值得)
            if let hi = hoverIndex, s.indices.contains(hi) {
                Path {
                    $0.move(to: CGPoint(x: pt(hi).x, y: 0))
                    $0.addLine(to: CGPoint(x: pt(hi).x, y: h))
                }
                .stroke(Color.primary.opacity(0.22), lineWidth: 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .position(pt(hi))
            }
            // 「今天」那个端点:小标记才配得上饱和色。2pt 同底色描边,压在折线上也看得清
            if let last = s.indices.last {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                   lineWidth: 2))
                    .position(pt(last))
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let raw = (p.x - inset) / usable * CGFloat(n)
                hoverIndex = min(max(0, Int(raw.rounded())), max(0, s.count - 1))
            case .ended:
                hoverIndex = nil
            }
        }
    }

    /// 图下面那行说明。平时报口径与峰值(**带日期** —— 「最高 241」不如「最高 241 · 8月16日」
    /// 有用);悬停时整行换成那一天的读数,这样不必在图上叠气泡。
    private var trendCaption: String {
        let s = series
        let dates = IdleListeningStats.days(endingAt: Date(), days: Self.sparkDays)
        if let hi = hoverIndex, s.indices.contains(hi), dates.indices.contains(hi) {
            return String(format: L10n.t("%1$@ · %2$@ 首"),
                          Self.dayFormatter.string(from: dates[hi]), Self.grouped(s[hi]))
        }
        guard let peak = s.max(), peak > 0,
              let idx = s.firstIndex(of: peak), dates.indices.contains(idx)
        else { return "" }
        return String(format: L10n.t("近 %1$@ 天 · 最高 %2$@（%3$@）"),
                      "\(Self.sparkDays)", Self.grouped(peak),
                      Self.dayFormatter.string(from: dates[idx]))
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()
}


// MARK: - 左下:上次那首 + 一句歌词

/// 唱片 hero:上一首歌的**真封面**(本机 enrich 缓存直出,零网络) + 曲名歌手 + 按钮排,
/// 下面挂一句从这首歌歌词里挑出来的话。
///
/// 三级空态:
/// 1. 有上次那首、缓存里有封面 → 唱片;
/// 2. 有上次那首、没有封面 → 同尺寸的色块 + 大号首字母(封面存的是**远端** URL,
///    断网/冷启动拿不到图是常态而不是意外,所以这一级是常客);
/// 3. 连 UserDefaults 都没有(全新用户/清过 defaults)→ 退回呼吸音符 + 原来那句提示。
private struct IdleLastTrackHero: View {
    let player: PlaybackPlayer
    let onResume: () -> Void
    let onOpenPlayer: () -> Void
    let onOpenAlbum: (String, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coverURL: URL?
    /// 候选乐句。每条是 1~3 行原文 —— **不是单行**:LRC 的行是打轴单位不是句子单位,
    /// 一句话常被拆到两三行上,只摆一行就是半句(2026-08-24 用户实测反馈)。
    @State private var quotes: [[String]] = []
    @State private var quoteIndex = 0
    @State private var breath = false

    private var lastTitle: String { UserDefaults.standard.string(forKey: "np:lastTrackTitle") ?? "" }
    private var lastArtist: String { UserDefaults.standard.string(forKey: "np:lastTrackArtist") ?? "" }
    /// 2026-08-24 新加的键。此前只存了 曲名/歌手/播放器 三个,所以**旧安装第一次看到这一页时
    /// 它是空的**(要等下一次停播才写上)——空就只显示歌手,不显示「· 专辑」,不影响封面
    /// (coverURL 第三级本来就忽略专辑)。
    private var lastAlbum: String { UserDefaults.standard.string(forKey: "np:lastTrackAlbum") ?? "" }

    private var canResume: Bool { player == .appleMusic || player == .spotify }
    private var trackKey: String { lastArtist + "|" + lastTitle + "|" + lastAlbum }

    var body: some View {
        VStack(spacing: 0) {
            if lastTitle.isEmpty {
                noTrackHero
            } else {
                trackHero
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: trackKey) { load() }
    }

    // MARK: 有上次那首

    private var trackHero: some View {
        VStack(spacing: 0) {
            cover
                .frame(width: 216, height: 216)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            Text(L10n.t("刚才在听"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
            Text(lastTitle)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 2)
            Text(lastAlbum.isEmpty ? lastArtist : "\(lastArtist) · \(lastAlbum)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 10) {
                if canResume {
                    Button(action: onResume) {
                        Label(L10n.t("继续播放"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                // 没有「继续播放」可给的播放器(QQ/网易云/酷狗没有 AppleScript),
                // 「前往专辑」升格为主按钮 —— 与原欢迎态里「打开 X」的同一条规则。
                if canResume {
                    Button(L10n.t("前往专辑")) { onOpenAlbum(lastTitle, lastArtist) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                } else {
                    Button(L10n.t("前往专辑")) { onOpenAlbum(lastTitle, lastArtist) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button(String(format: L10n.t("打开 %@"), player.displayName), action: onOpenPlayer)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            .padding(.top, 18)
            if !quotes.isEmpty {
                quoteBand
                    .padding(.top, 30)
            }
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder private var cover: some View {
        if let coverURL {
            CachedImage(url: coverURL, variant: .original) { coverPlaceholder }
        } else {
            coverPlaceholder
        }
    }

    /// 第二级空态:同尺寸色块 + 首字母。颜色按歌手名恒定(同一个人永远同一色),
    /// 复用榜单那边的 stableColor,不另起一套调色。
    private var coverPlaceholder: some View {
        ZStack {
            LastfmStatsSection.stableColor(for: lastArtist.isEmpty ? lastTitle : lastArtist)
                .opacity(0.65)
            Text(String(lastTitle.prefix(1)))
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    /// 一句歌词。不做卡片、不加边框 —— 它是氛围不是控件。
    private var quoteBand: some View {
        VStack(spacing: 7) {
            // 保留乐句自己的换行、不拼成一行 —— 看起来就是歌词本来的样子
            Text(quotes[quoteIndex % quotes.count].joined(separator: "\n"))
                .font(.system(size: 17))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary.opacity(0.82))
                .id(quoteIndex)
                .transition(.opacity)
            HStack(spacing: 10) {
                Text("—《\(lastTitle)》\(lastArtist)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if quotes.count > 1 {
                    Button(L10n.t("换一句")) {
                        withAnimation(.easeInOut(duration: 0.28)) { quoteIndex += 1 }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 440)
    }

    // MARK: 全新用户

    private var noTrackHero: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(0.12), .clear],
                                         center: .center, startRadius: 8, endRadius: 90))
                    .frame(width: 180, height: 180)
                Image(systemName: "music.note")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .scaleEffect(breath ? 1.05 : 0.96)
            .opacity(breath ? 1 : 0.8)
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                       value: breath)
            .onAppear { breath = true }
            .onDisappear { breath = false }
            Text(L10n.t("没有在播放"))
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 4)
            Text(String(format: L10n.t("在 %@ 播放任意歌曲，歌词会自动出现"), player.displayName))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Button(String(format: L10n.t("打开 %@"), player.displayName), action: onOpenPlayer)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 20)
        }
    }

    // MARK: 取数

    /// 封面 + 选句一次取完,全在后台线程:首次会解析整份 enrich 缓存 JSON(几 MB),
    /// 之后靠 mtime 缓存是 µs 级。两件事共用同一次解析,别分两个 task。
    private func load() {
        let a = lastArtist, t = lastTitle, al = lastAlbum
        guard !t.isEmpty else {
            coverURL = nil
            quotes = []
            return
        }
        Task.detached(priority: .userInitiated) {
            let raw = EnrichCacheReader.coverURL(artist: a, title: t, album: al)
            // 去掉网易云那个 `?param=600y600`(只降不升,对 216pt = 432px 的大图是白扔分辨率)
            let cover = raw.map { EnrichCacheReader.nativeSizedCoverURL($0) }
            var picked: [[String]] = []
            if let entry = EnrichCacheReader.lookup(artist: a, title: t, album: al),
               !entry.lyrics.isEmpty {
                // ⚠️ 必须走 LRCParser:酷狗那批 CRLF 歌词自己 split("\n") 切不开,会把整首歌
                // 当成一行(「整个桌面都是歌词」那个 bug 的同一个坑)。
                //
                // 排序 / 剥对唱标记 / 挡署名 / **把被拆成多行的碎片并回整句** / 收尾复验,
                // 整条链都在 LyricQuotePicker 里(纯函数,被 selftest 钉住),这里只喂解析结果。
                let parsed = LRCParser.parse(entry.lyrics)
                    .map { LyricQuotePicker.Line(timeMs: $0.timeMs, text: $0.text) }
                picked = LyricQuotePicker.phrases(parsed, trackTitle: t, trackArtist: a)
            }
            await MainActor.run {
                coverURL = cover
                quotes = picked
                quoteIndex = picked.isEmpty ? 0 : Int.random(in: 0 ..< picked.count)
            }
        }
    }
}

// MARK: - 右列:最近听过

/// 通高的「最近听过」:按天分组、每行带封面与「第 N 次听」、底部翻页。
///
/// 两处必须知道的既有约束:
/// - **「第 N 次听」的换算走 Core 里那份共享实现**(`RecentPlayOrdinal`),不是在这里再抄一遍
///   减法 —— 那段有两把不同的尺子,抄错一处就是用户 2026-08-21 报的「第 15 次听下面紧跟
///   第 21 次听」。
/// - **`recentPage` 是服务层的共享状态**:设置页那张「最近记录」卡看的是同一个页码。所以这里
///   退场时把它拨回第 1 页 —— 不然停播页翻到第 7 页之后,设置页那边会一直停在第 7 页,而它的
///   自动刷新只在第 1 页才跑(等于把那边的刷新悄悄关掉了)。
private struct IdleRecentPanel: View {
    let onOpenTrack: (String, String) -> Void

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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1))
        )
        .onDisappear {
            if stats.recentPage != 1 { stats.goToPage(1) }
        }
    }

    // MARK: 卡头

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t("最近听过"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let updated = stats.recentUpdatedAt {
                Text(Self.agoText(updated))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help(updated.formatted(date: .abbreviated, time: .standard))
            }
            Button {
                stats.refreshBaseline(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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
                                .foregroundStyle(.tertiary)
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
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if let count {
                Text(String(format: L10n.t("第 %@ 次"), "\(count)"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let date = track.date {
                Text(Self.timeFormatter.string(from: date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear))
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
                    .foregroundStyle(.secondary)
                Button(L10n.t("重试")) { stats.refreshBaseline(force: true) }
                    .controlSize(.small)
            }
            .padding(.vertical, 16)
        } else {
            Text(L10n.t("还没有收听记录"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
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
                .foregroundStyle(.secondary)
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()

    /// 分隔行只写「今天 / 昨天 / 8月16日」,**刻意不带条数** —— 一页只有 20 行,写
    /// 「今天 · 12 首」必然被读成全天真值(本机今天实际 107 首)。
    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L10n.t("今天") }
        if cal.isDateInYesterday(date) { return L10n.t("昨天") }
        return dayFormatter.string(from: date)
    }

    private static func agoText(_ date: Date) -> String {
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return L10n.t("刚刚更新") }
        if mins < 60 { return String(format: L10n.t("%@ 分钟前更新"), "\(mins)") }
        return String(format: L10n.t("%@ 小时前更新"), "\(mins / 60)")
    }
}
