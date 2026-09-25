import LyrimuseCore
import SwiftUI

/// 「歌词管理」卡里那块歌词库统计面板(「统计目前歌词数量,歌词情况,
/// 比如逐字多少,纯文本多少,逐行多少」)。
///
/// 数据全部来自 `EnrichCacheStore` 里**早就存着**的字段,没有新增任何解析 —— 这几个值
/// 「歌词管理」窗口的列表和详情页一直在显示,只是设置页这张卡此前一个数字都不给,用户想知道
/// "我这库里到底攒了多少、成色如何"必须开另一扇窗口去数。
enum LyricsLibraryStats {
    /// 成色本体(优先级阶梯、每个桶的定义)在 `LyrimuseCore.LyricsKind` —— 放那边是因为
    /// App target 不可被 selftest 引用,而那个阶梯改错了**完全不报错、只是数字悄悄变形**。
    /// 这里只补显示用的名字和配色。
    typealias Kind = LyricsKind

    static func kind(
        hasWordTiming: Bool, hasLyrics: Bool, hasPlainTextFallback: Bool, isInstrumental: Bool
    ) -> Kind {
        Kind.classify(
            hasWordTiming: hasWordTiming, hasLyrics: hasLyrics,
            hasPlainTextFallback: hasPlainTextFallback, isInstrumental: isInstrumental)
    }

    struct Counts: Equatable {
        var total = 0
        var byKind: [String: Int] = [:]
        /// 歌词源自带的社区译文(网易云 / Musixmatch)。
        var communityTranslation = 0
        /// collector 机翻补的译文(端上 Apple 翻译 helper,或网络兜底 Google / MyMemory)。
        var machineTranslation = 0
        /// **缓存里带 `lyrics_roma` 字段**的条目数。
        ///
        /// 这**不是**"有多少首歌看得到罗马音"。App 侧 `Romanizer` 有客户端现算兜底
        /// (日文形态分析 / 中文拼音 / 韩文,见第 10 章),缓存里没有的照样会在渲染时现算。
        /// 所以文案必须是「N 首**已缓存**罗马音」并挂 help 说明,不能写成「N 首有罗马音」。
        ///
        /// 这个数会明显长起来:collector 新增了预生成(`lyrics-romanize`
        /// helper,日/韩/中),而存量条目要跑一次 `collector backfill-roma -apply` 才会补上
        /// —— 在那之前它仍然只反映"源自带 + 粤拼"那一小撮(实测某台机器 114/3566 = 3.2%)。
        var bundledRomanization = 0

        func count(_ kind: Kind) -> Int { byKind[kind.rawValue] ?? 0 }
    }

    static func counts(_ summaries: [EnrichCacheStore.Summary]) -> Counts {
        var counts = Counts()
        for summary in summaries {
            // 占位行不是缓存里真实存在的条目(见 Summary.isSearching 头注:那是"正在联网搜、
            // collector 还没写出任何结论"那段窗口期的一行),把它算进库存会让总数无端多一。
            guard !summary.isSearching else { continue }
            counts.total += 1
            let kind = kind(
                hasWordTiming: summary.hasWordTiming,
                hasLyrics: summary.hasLyrics,
                hasPlainTextFallback: summary.hasPlainTextFallback,
                isInstrumental: summary.isInstrumental)
            counts.byKind[kind.rawValue, default: 0] += 1
            // 译文分两档:源自带的社区翻译 vs collector 机翻(判据和那个哨兵字符串的
            // 跨语言契约见 LyricsTranslationSource)。本机实测 1135 首有译文里 723 社区 /
            // 412 机翻,六四开 —— 不是那种"分了也全落一边"的伪区分,而且两者质量差得远。
            switch LyricsTranslationSource.classify(
                hasTranslation: summary.hasTranslation, trSource: summary.lyricsTrSource) {
            case .community: counts.communityTranslation += 1
            case .machine: counts.machineTranslation += 1
            case .none: break
            }
            if summary.hasRomanization { counts.bundledRomanization += 1 }
        }
        return counts
    }
}

extension LyricsKind {
    var label: String {
        switch self {
        case .wordByWord: return L10n.t("逐字")
        case .lineByLine: return L10n.t("逐行")
        case .plainText: return L10n.t("纯文本")
        case .instrumental: return L10n.t("纯音乐")
        case .none: return L10n.t("暂无")
        }
    }

    /// 数字的颜色。只给「暂无」上橙色 —— 它是唯一一个"可以变好"的桶(重搜/换源就可能补上),
    /// 别的都是既成事实,染色只会把这一排变成一片彩灯。
    var tint: Color {
        self == .none ? .orange : .primary
    }

    /// 比例条上这一段(以及图例里那个色点)的颜色。跟上面 `tint` 是两回事:数字仍然只有「暂无」
    /// 染色;条和点没颜色就没法对应,所以这里必须有色 —— 但仍守着"别一片彩灯"那条:三个"有词"
    /// 的桶用**同一个** accent 色相、只变明度(逐字 → 逐行 → 纯文本读作时间轴精细度递减),
    /// 「纯音乐」既不是好也不是坏,给中性灰;整条只有「暂无」一处异色,眼睛自然落在它上面。
    var barColor: Color {
        switch self {
        case .wordByWord: return .accentColor
        case .lineByLine: return .accentColor.opacity(0.55)
        case .plainText: return .accentColor.opacity(0.28)
        case .instrumental: return Color.secondary.opacity(0.35)
        case .none: return .orange
        }
    }
}

/// 歌词库统计块顶行右端那个占用空间(加的;改版从「歌词库」
/// 行尾挪到「共 N 首」那一行的尾部,仍是裸值)。
///
/// 数字直接用 `EnrichCacheStore.totalSizeBytes` —— 「歌词管理」工具栏一直在显示的同一个值
/// (lyrics/ 权威源文件夹 + 缓存 JSON 本身),没有新增任何磁盘扫描。渲染口径也共用
/// `EnrichCacheStore.byteText`,免得同一个数在两扇窗口里写法不一样。
///
/// **算不出来就什么都不显示,绝不显示「零字节」**。`totalSizeBytes` 的初值是 0,而
/// `refreshSizeBytes()` 是个 detached task —— 首次打开这一页时有一小段窗口期值还是 0;
/// 另外 `clearAll()` 也会把它硬置 0。这两种情况下摆一个"0 字节"是在报一个假数字,而空库
/// 本来就有面板那句「还没有缓存任何歌词」在说话,这里再补一个 0 只会互相打架。
///
/// 单独一个小 View 的理由跟下面的统计面板一样:`EnrichCacheStore` 是个有七八个
/// `@Published` 的单例,订阅面收在真正用得到的这一小块里,别让整页跟着重画。
struct LyricsLibrarySizeLabel: View {
    @ObservedObject private var store = EnrichCacheStore.shared

    var body: some View {
        // 只放**裸数字**、不写「占用 」前缀:下一张卡「歌词文件夹」那一行的尾部也是裸路径,
        // 加了前缀反而跟邻行不齐。含义交给 help 气泡和 accessibilityLabel 带,两者都不占版面。
        if store.totalSizeBytes > 0 {
            Text(EnrichCacheStore.byteText(store.totalSizeBytes))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(L10n.t("歌词文件夹和本地记录文件加起来占用的磁盘空间"))
                .accessibilityLabel(String(
                    format: L10n.t("占用空间：%@"),
                    EnrichCacheStore.byteText(store.totalSizeBytes)))
        }
    }
}

/// 设置页「歌词库」卡卡名行以下的整块内容:一块只读的统计面板 + 两条可操作的主行。
///
/// **这张卡只有两族东西,各自一种语法,不混排**:
///   1. **统计块**(`statsBlock`,`SettingsRawRow`):「共 N 首 ／ N MB」+ 分段比例条 + 五桶图例
///      + 译文 / 已缓存罗马音那一排叠加指标。全部只读,一个按钮都没有。总数跟五个桶是
///      整体/部分关系,排成平级格子看不出比例,所以画成条 —— 精确值交给图例。
///   2. **两条动作行**(`fillSweepRow` / `fullScanRow`,`SettingsRow`):各带一个前导图标、
///      一个待办数、一颗「开始」,结构逐项对称 —— 它们是同一条通道(`LyricsFillSweep`)的
///      窄档和宽档。
///
/// **别把只读的数字做成第三条行**。可操作的行(动作行)和纯显示的数字混在一起、
/// 只靠"有没有按钮"区分,会让设计语言不统一,右端也对不齐(动作行的数字被
/// 按钮推着左移,数据行顶到卡片右缘,没有共同的右边界)。只读的数字归统计块,可操作的
/// 归主行,这条界线别再跨回去。
///
/// 这个 View 自己持 `@ObservedObject EnrichCacheStore.shared`,而**不是**把它挂到
/// `LyricsSettingsTab` 上:`EnrichCacheStore` 是个有七八个 `@Published` 的单例,整页订阅它意味着
/// 任何一次 reload / 体积重算都要重画整张设置页。这个仓库为"@ObservedObject 订阅整个单例"踩过
/// 真实的过度重渲染 bug(见 OnboardingView 里 isPlayingNow 那段注释),把订阅面收在这一块里 ——
/// 也正因如此,译文 / 罗马音那两条行(它们读的是同一份 counts)也放在这里而不是 managementCard,
/// 免得为了传 counts 让外层再订阅一次。
struct LyricsLibraryStatsPanel: View {
    @ObservedObject private var store = EnrichCacheStore.shared
    /// 设置窗口看不见时不轮询:补搜 / 全量扫库期间每写一首缓存就变,这一页会跟着反复解析整份缓存。
    @Environment(\.previewHostVisible) private var windowVisible
    // collector 侧补空扫描的进度快照(LyricsFillSweep,进度文件按 mtime 读),由下面那个 .task 轮询。
    // 「歌词管理」窗口里同一份状态另有自己的一份 @State,两处各自轮询同一个文件,不共享——
    // 两扇窗口生命周期独立,共享一个 ObservableObject 只会多一个单例订阅面。
    @State private var fillSweepStatus: LyricsFillSweep.Info?
    // collector 公布的「全量重新扫库」状态(当前打分版本号 + 有没有一轮没跑完),同一个
    // .task 一起轮询。nil = collector 还没起来过、或版本老到不写这份文件 —— 那种情况下
    // 「N 首待跟进」算不出来,整行藏掉(同 LyricsLibrarySizeLabel 那条"算不出来就什么都
    // 不显示"的规矩,摆一个猜出来的数字比不摆更糟)。
    @State private var fullScanState: LyricsFullScan.State?
    @State private var confirmFullScan = false
    @ObservedObject private var pins = LyricsPinStore.shared
    /// 补空扫描"开始"按钮点击后、扫描真正开始前的过渡状态(显示 loading 动画)。
    /// 点击「开始」时置 true,下一次轮询读到 running = true 时清空。
    @State private var fillSweepStarting = false
    /// 全量扫描"开始"按钮点击后、扫描真正开始前的过渡状态(显示 loading 动画)。
    @State private var fullScanStarting = false

    private static let snapshotHolder = "settings-library-stats"

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func format(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    var body: some View {
        let counts = LyricsLibraryStats.counts(store.summaries)
        // 用 VStack(spacing: 0) 而不是 Group 装这几行:修饰符挂在 Group 上会**逐个**作用到每个
        // 子视图 —— 下面那个 .task 就会跑出三份轮询循环。外层卡片本身就是 VStack(spacing: 0),
        // 这里再套一层对布局零影响。
        VStack(spacing: 0) {
            if store.summaries.isEmpty && store.isLoading {
                SettingsRawRow(insetToText: true, icon: "music.note.list") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("正在统计歌词库…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if counts.total == 0 {
                // 空库不是错误,是新装的常态 —— 说清楚下一步会发生什么,别摆一排 0、也别画一条空比例条。
                SettingsRawRow(insetToText: true, icon: "music.note.list") {
                    Text(L10n.t("还没有缓存任何歌词。放一首歌，Lyrimuse 会自动搜好存在这里"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SettingsRawRow(insetToText: true, icon: "music.note.list") {
                    statsBlock(counts)
                }
                CardDivider()
                // 「补搜缺失歌词」「全量重新扫库」是同一条通道的窄档和宽档,排在一起、长得一样。
                fillSweepRow()
                // 分隔线画在这一族的里面 —— 整行在 collector 还没公布过打分版本号时会整个
                // 消失,分隔线留在外面就会变成两条紧挨着的线。
                fullScanRow()
            }
        }
        // `onlyIfChanged` 让重复进出这一页不重复解析整份缓存(全库几千条,那是一次真实的
        // 开销)。用 .task 而不是 .onAppear:reload 本身是 async 的,挂在 .task 上由 SwiftUI
        // 负责视图消失时取消。
        //
        // 之后留在这个循环里轮询补空扫描的进度:跑着的时候 2 秒一次、顺带
        // reload —— 每补上一首「暂无」那格就该少一;没在跑 5 秒一次只看进度文件的 mtime,
        // 一次 stat 的开销。视图消失即取消,没有常驻计时器。设置窗口看不见时整个循环停掉,
        // 重新看得见时从头来一遍(先按指纹 reload,再接着轮询)。
        // 这一页看得见时握着「歌词管理」那份快照,看不见 / 离开这一页就放手(见 EnrichCacheStore.snapshotHolders)。
        // 设置窗口隐藏时视图不一定消失,所以按 windowVisible 走,onDisappear 兜离开这一页。
        .onAppear { if windowVisible { store.holdSnapshot(Self.snapshotHolder) } }
        .onChange(of: windowVisible) { _, visible in
            if visible { store.holdSnapshot(Self.snapshotHolder) } else { store.releaseSnapshot(Self.snapshotHolder) }
        }
        .onDisappear { store.releaseSnapshot(Self.snapshotHolder) }
        .task(id: windowVisible) {
            guard windowVisible else { return }
            await store.reload(onlyIfChanged: true)
            fullScanState = LyricsFullScan.current
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(fillSweepStatus?.running == true ? 2 : 5))
                guard !Task.isCancelled else { break }
                let sweep = LyricsFillSweep.current
                if sweep != fillSweepStatus { fillSweepStatus = sweep }
                // 扫描真正开始后,清除"正在启动"状态(让 loading 动画消失、切换到进度条)
                if sweep?.running == true {
                    if fillSweepStarting { fillSweepStarting = false }
                    if fullScanStarting && sweep?.isFullScan == true { fullScanStarting = false }
                }
                // 这份文件一轮里只在开头/结尾各写一次(外加 collector 每次启动),按 mtime
                // 读的开销就是一次 stat,跟着同一个节拍走即可。
                let full = LyricsFullScan.current
                if full != fullScanState { fullScanState = full }
                if sweep?.running == true { await store.reload(onlyIfChanged: true) }
            }
        }
        // 确认框而不是直接开跑:这一轮要联网重搜几千首、跑一两天,而且**会改写已经有词的
        // 条目** —— 前两点用户点之前有权知道,第三点是这个功能跟隔壁「重新扫描」的本质区别
        // (那颗只碰空条目,点错了最坏也就是白费点网络)。
        .confirmationDialog(
            L10n.t("全量重新扫库？"),
            isPresented: $confirmFullScan,
            titleVisibility: .visible
        ) {
            Button(L10n.t("开始扫描")) { LyricsFillSweep.requestFullScan() }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(fullScanConfirmMessage)
        }
    }

    // MARK: 统计块

    /// 「共 N 首 ／ 191 MB」→ 分段比例条 → 五桶图例 → 一排叠加指标。
    ///
    /// 读法照系统设置「通用 → 储存空间」:一个大数 + 一条条 + 两排指标。整块**全是只读的**
    /// —— 卡里凡是能点的都在下面那两条动作主行上,一块面板里不掺按钮,两族才不会串味。
    ///
    /// 四条约束:
    ///   - 总数是这一块唯一的大字号,层级全靠字号差拉开(20pt vs 指标的 11pt),不靠分隔线
    ///     也不靠给指标加粗 —— 一块统计面板里有两个抢眼的东西就等于一个都不抢眼;
    ///   - 五个桶**全在图例里**,包括「暂无」。图例是那条比例条的注解,少画一段就对不上;
    ///     带动作的那一档另有自己的一行(`fillSweepRow`),不必在图例里再兼一个入口;
    ///   - 第二排(译文 / 已缓存罗马音)**不带色板**。它们跟五个桶不是互斥划分 —— 一首歌可以
    ///     既是逐字又有译文 —— 给了色板就会被读成比例条上又两段;
    ///   - 两排都流式排布。英文标签比中文长近一倍(Word-timed / Instrumental),写死一行会在
    ///     窗口拖到 minWidth 时把末尾几项裁掉。
    private func statsBlock(_ counts: LyricsLibraryStats.Counts) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Self.totalText(counts.total)
                    .accessibilityLabel(String(format: L10n.t("共 %@ 首"), Self.format(counts.total)))
                Spacer(minLength: 12)
                LyricsLibrarySizeLabel()
            }
            // 9pt 而不是默认的 6pt:三个"有词"的桶是同一色相变明度,条太细就分不出深浅,
            // 一整条读起来只剩"蓝的"。段间隙同步放到 2pt,免得加高之后段与段糊在一起。
            SettingsProportionBar(
                segments: LyricsLibraryStats.Kind.allCases.map { kind in
                    .init(id: kind.rawValue, value: counts.count(kind), color: kind.barColor)
                },
                height: 9, gap: 2, minSegmentWidth: 4)
            SettingsFlowRow(spacing: 14) {
                ForEach(LyricsLibraryStats.Kind.allCases, id: \.self) { kind in
                    legendItem(kind, value: counts.count(kind))
                }
            }
            SettingsFlowRow(spacing: 16) {
                // 两档译文合成一个数,细分进 ⓘ:这一排要跟上面的图例读法一致(一个标签配一个数),
                // 「2,078 首源自带 · 532 首机翻」在这个位置是三段文字对两段,一排就歪了。
                // 合计数还能直接跟总数对读("六千多首里两千多首有译文"),那是分开写时读不出来的。
                metricItem(
                    label: L10n.t("译文"),
                    value: counts.communityTranslation + counts.machineTranslation,
                    help: String(format: L10n.t("%1$@ 首源自带，%2$@ 首机翻"),
                                 Self.format(counts.communityTranslation),
                                 Self.format(counts.machineTranslation)))
                // 标题直接写「已缓存」:这个数**不是**"有多少首歌看得到罗马音"——App 侧 Romanizer 有
                // 客户端现算兜底,缓存里没有的照样会在渲染时现算(见 Counts.bundledRomanization 头注)。
                // ⓘ 只留两句:这个数在数什么、没被数的去哪了。
                metricItem(
                    label: L10n.t("已缓存罗马音"),
                    value: counts.bundledRomanization,
                    help: L10n.t("只数存进缓存、会随歌词文件一起导出的那些。其余歌曲的罗马音在播放时实时生成，不计入"))
            }
            .padding(.top, 2)
        }
    }

    /// 第二排的一项:标签 + 数字 + ⓘ。跟 `legendItem` 同一种读法(标签 secondary、数字 semibold
    /// 等宽),**不带色板** —— 理由见 `statsBlock` 的第三条约束。
    ///
    /// ⓘ 必须留在 `accessibilityElement(children: .combine)` **外面**:合并会把它一起吞掉,
    /// 旁白用户就再也够不到那段说明了(而这两项的说明恰恰是数字本身讲不清的那部分)。
    private func metricItem(label: String, value: Int, help: String) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(Self.format(value))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label)：\(Self.format(value))")
            HelpButton(text: help)
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// 「共 3,669 首」:数字 20pt semibold、前后的字 13pt。三种语言各自决定数字前后写什么(英文是
    /// "3,669 songs"),所以按格式键里的 `%@` 切开再拼,而不是写死"数字 + 首"。
    private static func totalText(_ count: Int) -> Text {
        let number = Text(format(count))
            .font(.system(size: 20, weight: .semibold))
            .monospacedDigit()
        let parts = L10n.t("共 %@ 首").components(separatedBy: "%@")
        guard parts.count == 2 else { return number }
        let body = Font.system(size: 13)
        return Text(parts[0]).font(body) + number + Text(parts[1]).font(body)
    }

    /// 一个图例项:色板 + 标签 + 数字。数字一律 primary —— 只有「暂无」染色的规矩没变,见 LyricsKind.tint。
    ///
    /// 色板是 3×10 的小竖条,不是圆点:它注解的是上面那条比例条的**分段**,同一种形状(矩形、
    /// 同一种圆角)才对得起来;圆点是通用图例语汇,跟矩形的段各说各话。
    private func legendItem(_ kind: LyricsLibraryStats.Kind, value: Int) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(kind.barColor)
                .frame(width: 3, height: 10)
            Text(kind.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Self.format(value))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? kind.tint : Color.primary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label)：\(Self.format(value))")
    }

    // MARK: 补搜缺失歌词

    /// 让 collector 现在就把没有歌词的条目重搜一遍 —— 跟「歌词管理」工具栏那颗「补搜歌词」
    /// 是同一条通道(`LyricsFillSweep`,见第 09 章「补空扫描」)。
    ///
    /// 跟下面「全量重新扫库」**逐项对称**(标题 + ⓘ + 待办数 + 「开始」)。两者是同一件事的窄档
    /// 和宽档 —— 让采集服务跑一轮扫描,区别只在范围,而范围本身是包含关系:待搜那批正是待跟进
    /// 那批的第 0 层。两行长得一样,这层关系才读得出来。
    ///
    /// 别把这个入口挪进图例里「暂无」那个数字旁边。待搜数按 `EnrichCacheStore.isFillSweepRetryable`
    /// 算(「暂无」+ 只有纯文本兜底的,人工修正过的除外),跟「暂无」那个数**就是**对不上的
    /// (本机 65 vs 74);两个口径不同的数并排摆着只会让人以为其中一个是错的,再拿 ⓘ 去解释也救不回来。
    /// 按钮上的口径是"真会被搜的条数",这一点别为了让两个数一致去改。
    ///
    /// 进度和收据都必须先判 `isFullScan`:「全量重新扫库」为了跨重启续跑复用了这条通道
    /// (见 collector/lyricsfullscan.go 头注),两轮共用**同一份** `lyrimuse-lyrics-fill-status.json`。
    /// 不判的话,全量在跑时这一行会照着那份状态画出跟下面那行逐字重复的「扫描中 42/5318 + 停止」。
    private func fillSweepRow() -> some View {
        let status = fillSweepStatus
        // running = 任意一轮(collector 一次只准跑一轮);sweepRunning = 跑的是补空这一轮。
        // 两个量分开,正是因为这一行只该画补空那一轮,而按钮要对**任意**一轮置灰。
        let running = status?.running == true
        let sweepRunning = running && status?.isFullScan != true
        let retryable = store.summaries.filter(EnrichCacheStore.isFillSweepRetryable).count
        return SettingsRow(
            icon: "text.magnifyingglass",
            title: L10n.t("补搜缺失歌词"),
            subtitle: Self.sweepReceipt(status),
            help: L10n.t("重新扫描的范围：没有歌词的，加上只有纯文本的；人工修正过的不动")
        ) {
            HStack(spacing: 10) {
                if sweepRunning, let status {
                    ProgressView(value: Double(status.done), total: Double(max(status.total, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(String(format: L10n.t("扫描中 %1$@/%2$@"),
                                Self.format(status.done), Self.format(status.total)))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // 剩余时间按**这一轮的实测速度**算。放 tooltip 不放正文:这一行 11pt
                        // 的空间塞不下第三段文字。
                        .help(Self.remainingText(status, fallbackSecondsPerTrack: secondsPerTrack))
                    Button(L10n.t("停止")) { LyricsFillSweep.requestCancel() }
                        .controlSize(.small)
                        .fixedSize()
                } else {
                    Text(retryable > 0
                         ? String(format: L10n.t("%@ 首待搜"), Self.format(retryable))
                         : L10n.t("没有缺失"))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // 点击后、扫描真正开始前显示 loading 动画
                    if fillSweepStarting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    }
                    // 不带 SF Symbol:同一行左边已经写着这一行在干什么,再叠一个 ⟳ 是往控件上
                    // 加装饰(要强调就改文字,别叠图标)。
                    Button(L10n.t("开始")) {
                        fillSweepStarting = true
                        LyricsFillSweep.request(keys: [])
                    }
                        .controlSize(.small)
                        .fixedSize()
                        // 全量那一轮跑着的时候也置灰,跟「全量重新扫库」那颗「开始」对称:collector
                        // 一次只允许一轮在跑(runLyricsFillSweep 开头那道闸),这时点下去只会被静默丢掉。
                        .disabled(retryable == 0 || running || fillSweepStarting)
                        .help(running
                              ? L10n.t("另一轮扫描正在进行，等它结束再来")
                              : L10n.t("立即联网补搜缺失的歌词，不必等歌曲再次播放"))
                }
            }
            .settingsGlassButtons()
        }
    }

    /// 补空那一轮的收据,挂在标题下面当副标题。没跑过、正在跑、或者那份状态属于全量那一轮的,
    /// 一律不给 —— 全量跑完那句「过了 N 首」归它自己那一行,两轮共用同一份状态文件。
    ///
    /// 一首都没搜的那一轮**也不给**。「上次:搜了 0 首,补出 0 首」两个数都是 0,占着一行
    /// 副标题却一个字的信息都没有(库里当时没有可搜的条目,或者刚点下就被停了);这一行本来
    /// 就该跟「全量重新扫库」等高,凭空多出来的那一行还把两行的对称打破了。
    private static func sweepReceipt(_ status: LyricsFillSweep.Info?) -> String? {
        guard let status, status.running != true, status.isFullScan != true,
              status.finishedAt != nil, status.done > 0 else { return nil }
        return String(format: L10n.t("上次搜索 %1$@ 首，补全 %2$@ 首"),
                      format(status.done), format(status.filled))
    }

    // MARK: 全量重新扫库

    /// 每首的平均耗时**由 collector 发布**(`LyricsFullScan.State.secondsPerTrack`,
    /// = lyricsFullScanGap + 一轮全源搜索的估计)。这里只留一个兜底值,给老 collector
    /// 或状态文件还没写出来的那一拍用。
    ///
    /// 别把它改回写死一份:之前这里是 `25.0`、注释还写着「15 秒固定间隔
    /// (lyricsFillSweepGap)」,而那天 collector 把全量那一档换成 lyricsFullScanGap(5 秒),
    /// 这个数和那句话当场都成了错的 —— 界面凭空多报一倍时长,没有任何东西会报错。
    /// 这跟 `scoringVersion` 不能硬编码是同一条理由,走的也是同一份状态文件。
    ///
    /// 只用来在确认框和 tooltip 里说一句"大概多久",不参与任何判断。
    private static let fallbackSecondsPerTrack = 10.0

    /// collector 发布的值;没有(老版本 / 文件还没写出来)就退回兜底。
    private var secondsPerTrack: Double {
        let published = fullScanState?.secondsPerTrack ?? 0
        return published > 0 ? Double(published) : Self.fallbackSecondsPerTrack
    }

    private static func hoursText(_ tracks: Int, secondsPerTrack: Double) -> String {
        let hours = Int((Double(tracks) * secondsPerTrack / 3600).rounded())
        if hours < 1 { return L10n.t("不到 1 小时") }
        return String(format: L10n.t("约 %@ 小时"), format(hours))
    }

    /// 真会被这一轮扫到的条数。口径与 collector 侧 `lyricsFullScanCandidates` 同源
    /// (`LyricsFullScan.tier`,selftest 覆盖),所以按钮上的数就是真会被扫的条数 ——
    /// 跟隔壁「重新扫描（N 首）」那个数是**包含**关系:那 N 首正是这里的第 0 层。
    private func fullScanPending(_ currentVersion: Int) -> Int {
        let pinnedKeys = Set(pins.pins.keys)
        let polluted = EnrichCacheStore.pollutedKeys(store.summaries)
        let passStart = fullScanState?.startedAt ?? 0
        return store.summaries.reduce(into: 0) { total, summary in
            if EnrichCacheStore.fullScanTier(
                summary, currentScoringVersion: currentVersion, pinnedKeys: pinnedKeys,
                passStart: passStart, pollutedKeys: polluted) != nil {
                total += 1
            }
        }
    }

    private var fullScanConfirmMessage: String {
        let pending = fullScanState.map { fullScanPending($0.scoringVersion) } ?? 0
        return String(
            format: L10n.t("%1$@ 首，预计%2$@。已经有歌词的也会重新选一次；人工修正过的、校准过时间轴的、纯音乐的不动。随时可以停，关掉也不用重来"),
            Self.format(pending), Self.hoursText(pending, secondsPerTrack: secondsPerTrack))
    }

    /// 「全量重新扫库」这一行。collector 没公布过打分版本号(还没起来过 / 版本太老)时整行
    /// 不出现 —— 那种情况下「N 首待跟进」是算不出来的,而摆一个猜出来的数字比不摆更糟。
    ///
    /// 跟上面「补搜缺失歌词」**逐项对称**(前导图标 + 标题 + ⓘ + 待办数 + 「开始」):两者是同一条
    /// 通道的宽档和窄档,对象一个是整个库、一个只是其中"没词的"那一层,而这层包含关系正是靠
    /// 两行长得一样才读得出来。
    @ViewBuilder
    private func fullScanRow() -> some View {
        if let state = fullScanState {
            CardDivider()
            let status = fillSweepStatus
            let running = status?.running == true
            let fullRunning = running && status?.isFullScan == true
            let pending = fullScanPending(state.scoringVersion)
            SettingsRow(
                icon: "arrow.clockwise",
                title: L10n.t("全量重新扫库"),
                help: L10n.t("连已经有歌词的也重新过一遍；人工修正过的、校准过时间轴的、纯音乐的不动")
            ) {
                HStack(spacing: 10) {
                    if fullRunning, let status {
                        ProgressView(value: Double(status.done), total: Double(max(status.total, 1)))
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text(String(format: L10n.t("扫描中 %1$@/%2$@"),
                                    Self.format(status.done), Self.format(status.total)))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // 剩余时间按**这一轮的实测速度**算,不用上面那个估计常量:真实
                            // 速度受源的响应快慢影响很大,而这一轮自己跑出来的数是自校正的。
                            // 放 tooltip 不放正文:这一行 11pt 的空间塞不下第三段文字。
                            .help(Self.remainingText(status, fallbackSecondsPerTrack: secondsPerTrack))
                        Button(L10n.t("停止")) { LyricsFillSweep.requestCancel() }
                            .controlSize(.small)
                            .fixedSize()
                    } else {
                        Text(pending > 0
                             ? String(format: L10n.t("%@ 首待跟进"), Self.format(pending))
                             : L10n.t("已全部跟进"))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // 点击后、扫描真正开始前显示 loading 动画
                        if fullScanStarting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        }
                        Button(L10n.t("开始")) {
                            fullScanStarting = true
                            confirmFullScan = true
                        }
                            .controlSize(.small)
                            .fixedSize()
                            // 补空那一轮跑着的时候也置灰:collector 一次只允许一轮在跑
                            // (runLyricsFillSweep 开头那道闸),这时点下去只会被静默丢掉。
                            .disabled(pending == 0 || running || fullScanStarting)
                            .help(running
                                  ? L10n.t("另一轮扫描正在进行，等它结束再来")
                                  : String(format: L10n.t("预计%@，随时可以停"),
                                             Self.hoursText(pending, secondsPerTrack: secondsPerTrack)))
                    }
                }
                .settingsGlassButtons()
            }
            // collector 记着有一轮没跑完、但此刻并没有在跑 —— 它还在启动后的那 10 分钟等待
            // 期里(或者刚被 launchd 拉起来)。不说一句的话,界面看起来就是"我明明点过了,
            // 怎么什么都没发生"。
            if state.active && !fullRunning {
                SettingsSubRow(title: nil, subtitle: L10n.t("上一轮还没跑完，稍后会自动接着跑")) {
                    EmptyView()
                }
            } else if let status, status.isFullScan, status.finishedAt != nil, !fullRunning {
                SettingsSubRow(
                    title: nil,
                    subtitle: status.cancelled == true
                        ? String(format: L10n.t("上次：过了 %1$@ 首就被停下，更新 %2$@ 首"),
                                 Self.format(status.done), Self.format(status.filled))
                        : String(format: L10n.t("上次：过了 %1$@ 首，更新 %2$@ 首"),
                                 Self.format(status.done), Self.format(status.filled))
                ) {
                    EmptyView()
                }
            }
        }
    }

    /// 「大约还要 N 小时」——用这一轮**已经跑出来的**速度外推,不用那个固定估计值。
    /// 还没跑完一首时没有速度可言,退回按常量估。
    ///
    /// 剩余条数按 `total - done`(整场的累计值),而速度按 `roundDoneOrDone / (now-startedAt)`
    /// (这一轮自己的)—— 两个分子不是同一个口径,别图省事合成一个。`startedAt` 是这一轮开工的
    /// 时刻,拿累计的 `done` 除它会得出"一开工就跑了三千首"的假速度。
    private static func remainingText(_ status: LyricsFillSweep.Info,
                                     fallbackSecondsPerTrack: Double) -> String {
        let left = max(status.total - status.done, 0)
        guard left > 0 else { return L10n.t("就快好了") }
        let elapsed = Double(Date().timeIntervalSince1970) - Double(status.startedAt)
        let thisRound = status.roundDoneOrDone
        let perTrack = thisRound > 0 && elapsed > 0
            ? elapsed / Double(thisRound)
            : fallbackSecondsPerTrack
        // 直接按实测速度算,不再绕"换算成等效首数"那一道:hoursText 现在收显式的每首秒数,
        // 把实测值原样传进去就行。
        return String(format: L10n.t("大约还要%@"), hoursText(left, secondsPerTrack: perTrack))
    }
}
