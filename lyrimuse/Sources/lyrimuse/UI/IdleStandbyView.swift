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
/// 2026-08-27 用户要求把右列的"连没连 Last.fm 二选一"也接到这里(歌词窗口那颗「播放
/// 记录」按钮已经是这个逻辑,见 `docs/features/07-lyrics-window.md`「播放记录取代播放
/// 队列」一节):未连 Last.fm 时左上「收听总览」仍然没有数据可画(没有本地替代来源,
/// 那张卡的三个数字全靠 Last.fm 的每日归档),继续省略;但右列不再跟着一起消失——改成
/// `PendingListensPanel`(本地静默记的、还没提交的收听,数据源 `ScrobbleBackfillService`,
/// 跟歌词窗口那边共用同一份实现,不重写)。两列布局因此**恒定**,只是左上那张卡有没有、
/// 右列内容是哪一种,各自独立按连接状态判断。
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
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 20) {
                // 收听总览没有本地替代来源(三个数字全靠 Last.fm 的每日归档),
                // 未连接就没有东西可画,直接省略——不画空卡、不画破折号,沿用
                // 「没连账号也不难看」那条既有契约。
                if stats.isConnected { IdleOverviewCard() }
                IdleLastTrackHero(player: player, onResume: onResume,
                                  onOpenPlayer: onOpenPlayer, onOpenAlbum: onOpenAlbum)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 右列连没连 Last.fm 二选一(2026-08-27,与歌词窗口「播放记录」按钮同一套
            // 逻辑):已连接=`RecentListensPanel`(最近听过);未连接=`PendingListensPanel`
            // (本地静默记的、还没提交的收听)。跟原来"未连接时右列跟着整段消失"不同——
            // 右列现在恒有内容,两列布局不再随连接状态整体切换结构。
            Group {
                if stats.isConnected {
                    RecentListensPanel(onOpenTrack: onOpenTrack)
                } else {
                    PendingListensPanel(onOpenTrack: onOpenTrack)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 右上角那颗音量/AirPlay 胶囊是**窗级 overlay**、浮在内容之上,现在有
            // `!isIdle` 守卫了(停播页不会再冒出来,见 07-lyrics-window.md 那条
            // 2026-08-25 的坑)。这 18pt 顶部间距原本是留出来躲它的,但停播页跟播放态
            // 用的是**同一个**右上角锚点区域,窗口顶边到内容之间那段留白本身作为视觉
            // 呼吸感也说得通,不为了这一条不再成立就去掉。
            .padding(.top, 18)
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
    /// 走势图高度。同步中的占位骨架要跟它**严格一致**,分开写两个 52 迟早对不上、
    /// 抖动就又回来了(2026-08-29)。
    private static let sparkHeight: CGFloat = 52
    /// 悬停在走势图第几天上(nil = 没悬停)。读数换到图下面那行说明里,不叠浮层。
    @State private var hoverIndex: Int?
    // 悬停读数跟着游标走所需的三个量(2026-08-29)。原来读数固定在左下角:鼠标在图右侧
    // 时视线要横跨整条图去找那行小灰字,加上样式悬停前后完全一样,用户反馈"以为移上去
    // 没反应"。hoverX 存的是**吸附后那一天的点位**(不是鼠标裸坐标),读数才会跟竖线对齐。
    @State private var hoverX: CGFloat?
    @State private var chartWidth: CGFloat = 0
    @State private var captionWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 34) {
                bigStat(value: stats.overview?.today, label: L10n.t("今天"))
                bigStat(value: weekValue, label: weekLabel)
                bigStat(value: stats.overview?.total, label: totalLabel)
            }
            // 首次同步(bootstrapState)跟日常 top-up(dailySyncing)分开措辞(2026-08-25)
            // ——前者是"这个账号第一次连接",用户需要知道这是一次性的、会自己好;后者
            // 通常一闪而过,不用强调"首次"。
            //
            // ⚠️ 2026-08-25 顺手修复:这里原来是
            // `String(format: "正在同步历史（%@）", stats.dailySyncProgress)`,而
            // dailySyncProgress 自己已经是 LastfmStatsService 格式化好的完整句子
            // "正在同步历史（N/M 页）"——两层格式化叠在一起会显示成"正在同步历史（正在
            // 同步历史（N/M 页）」"。直接显示 dailySyncProgress 本身即可,不用再包一层。
            // 走势区。⚠️ 这里的**三种状态高度必须一致**,否则窗口会在数据到位的那一刻
            // 往下弹一格。这张卡本身只在 `stats.isConnected` 时才渲染(见 body 里的
            // 调用处),也就是说进到这里就意味着"迟早会有数据",所以没数据/还在同步都
            // 该先把图的位置占住,而不是等数据到了再撑开。
            if let note = syncNote {
                // ⚠️ 这里必须**把走势图的位置预留出来**(2026-08-29,用户报"首次进入这个页面
                // 时上面折线图区域会加载一下,加载完窗口会抖动一下")。同步中原来只渲染一行
                // 11pt 文字(≈13pt 高),数据一到就换成 52pt 图 + 13 spacing + 13 说明
                // (≈78pt),整个窗口当场往下弹一格。占位骨架跟数据态用同一套结构:
                // sparkHeight 的图位 + 一行说明,数据到了在**原地**换上,高度不变。
                //
                // 空白之外补一条基线:跟图里那条(primary 0.10、1pt)同款,让这块在加载时
                // 也读得出"这里将来是一张图",而不是一片莫名其妙的留白。
                Color.clear
                    .frame(height: Self.sparkHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 1)
                    }
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    // 说明换行会让占位高度重新对不上,钉死单行。
                    .lineLimit(1)
            } else if !series.isEmpty, series.contains(where: { $0 > 0 }) {
                trendChart
                // 悬停时这行整行换成那一天的读数(见 trendCaption)。三处让"有反应"看得见:
                // ① 换强调色 + 加粗 —— 原来悬停前后字号/颜色/位置全不变,只有内容变,
                //    等于没有任何响应信号;② 水平跟到游标正下方,视线不用横跨整条图;
                //    ③ 位置变化不做动画(跟内容一样),跟手才不显得拖沓。
                Text(trendCaption)
                    .font(.system(size: 11, weight: hoverIndex == nil ? .regular : .semibold))
                    .foregroundStyle(hoverIndex == nil
                                     ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                     : AnyShapeStyle(Color.accentColor))
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TrendCaptionWidthKey.self, value: g.size.width)
                    })
                    .onPreferenceChange(TrendCaptionWidthKey.self) { captionWidth = $0 }
                    .offset(x: trendCaptionOffsetX)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(nil, value: hoverIndex)
            } else {
                // 已连接、但桶还没回来(或这个账号确实还没有播放记录)。同样占住图位 ——
                // 少了这一档,"刚进页面还没拉到数据"这条最常见的路径照样会抖:它既不在
                // 同步中、也还没有 series。说明行用一个空格撑行高,空串的 Text 高度是 0。
                Color.clear
                    .frame(height: Self.sparkHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 1)
                    }
                Text(" ")
                    .font(.system(size: 11))
                    .lineLimit(1)
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

    /// 「近 7 天」的数值 —— 跟紧挨着的那个环比百分比**同源**(见 lastSevenDays 的注释)。
    /// 桶还没同步完时退回 API 值:那时候桶是残缺的,拿它算只会给出一个偏低的假数字,
    /// 而这一档下面那个百分比本来也不显示(weekLabel 的 dailySyncing 守卫),不存在
    /// "数值和百分比不同源"的问题。
    private var weekValue: Int? {
        guard !stats.dailySyncing else { return stats.overview?.week }
        return IdleListeningStats.lastSevenDays(
            dailyCounts: stats.dailyCounts, today: Date(),
            todayCount: stats.overview?.today,
            dayKey: { LastfmStatsService.dayKey($0) })
    }

    private var weekLabel: String {
        let base = L10n.t("近 7 天")
        guard !stats.dailySyncing,
              let d = IdleListeningStats.weekOverWeekDelta(
                dailyCounts: stats.dailyCounts, today: Date(),
                // 跟上面 series 里那句 `s[s.count-1] = today` 补的是同一格:桶同步到
                // 昨天为止,今天这一格得靠 overview 的实时值,否则环比会把今天算成 0。
                todayCount: stats.overview?.today,
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
        .frame(height: Self.sparkHeight)
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
                .stroke(Color.primary.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    // 描边同「今天」那个端点:压在折线上也分得清点和线。
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                   lineWidth: 2))
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
                let idx = min(max(0, Int(raw.rounded())), max(0, s.count - 1))
                hoverIndex = idx
                // 用吸附后的点位而不是 p.x:读数要对齐竖线,不是对齐鼠标。
                hoverX = inset + usable * CGFloat(idx) / CGFloat(n)
                chartWidth = w
            case .ended:
                hoverIndex = nil
                hoverX = nil
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

    /// 同步中要显示的那行说明(nil = 没在同步)。首次同步(bootstrapState)跟日常 top-up
    /// (dailySyncing)分开措辞 —— 前者是"这个账号第一次连接",用户需要知道这是一次性的、
    /// 会自己好;后者通常一闪而过,不用强调"首次"。合成一个属性是为了让上面那段能用
    /// `if let` 一次判完,占位骨架只写一份。
    private var syncNote: String? {
        if case .syncing(let page, let total) = stats.bootstrapState {
            return String(format: L10n.t("首次同步历史中（%1$@/%2$@ 页）"), "\(page)", "\(total)")
        }
        if stats.dailySyncing {
            // ⚠️ dailySyncProgress 自己已经是格式化好的完整句子("正在同步历史（N/M 页）"),
            // 再包一层 format 会显示成"正在同步历史（正在同步历史（N/M 页））"(2026-08-25 修过)。
            return stats.dailySyncProgress ?? L10n.t("正在同步历史")
        }
        return nil
    }

    /// 读数跟随游标的水平偏移:让文字**中心**对准那一天的点,再钳进图宽,免得贴边时
    /// 半截跑到图外面去。没在悬停(或还没测到宽度)时回到最左,跟原来的版式一致。
    private var trendCaptionOffsetX: CGFloat {
        guard let hx = hoverX, chartWidth > 0, captionWidth > 0 else { return 0 }
        return min(max(0, hx - captionWidth / 2), max(0, chartWidth - captionWidth))
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

/// 待机屏趋势图那行读数的宽度上报(2026-08-29)。读数要水平跟到游标下方并钳进图宽,
/// 必须知道它自己多宽 —— 拿固定值估会在中英文/位数变化时钳错边。
private struct TrendCaptionWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
