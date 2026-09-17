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
        /// collector 机翻补的译文(端上 Apple 翻译 helper 或 MyMemory 兜底)。
        var machineTranslation = 0
        /// **缓存里带 `lyrics_roma` 字段**的条目数。
        ///
        /// ⚠️ 这**不是**"有多少首歌看得到罗马音"。App 侧 `Romanizer` 有客户端现算兜底
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
/// ⚠️ **算不出来就什么都不显示,绝不显示「零字节」**。`totalSizeBytes` 的初值是 0,而
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

/// 设置页「歌词库」卡卡名行以下的整块内容:统计块 + 译文 / 罗马音两条从属行。
///
/// 改版。之前是「总数 / 逐字 / 逐行 / 纯文本 / 纯音乐 / 暂无」六格等宽数字 + 一行竖线
/// 拼接的「译文 … | … 罗马音」密文 + 一颗孤悬左下的「重新扫描」按钮。三处问题:总数跟五个桶是
/// 整体/部分关系却排成六个平级格子、看不出比例;密文像调试输出;重新扫描按钮跟它对应的橙色
/// 「暂无」数字在版面上没有关联(而它的数字 74 还跟「暂无」的 65 对不上)。
///
/// 现在的读法照系统设置「通用 → 储存空间」:一行「共 3,669 首 ／ 97 MB」,下面一条分段比例条,
/// 再一行四个"既成事实"桶的图例;「暂无」单独成一行 —— 橙色数字在左、「重新扫描（74 首）」在
/// 同一行尾部,数字旁一个 ⓘ 说清 74 为什么不是 65。译文 / 罗马音拆成两条「标签在左、裸值在右」
/// 的从属行。
///
/// ⚠️ 这个 View 自己持 `@ObservedObject EnrichCacheStore.shared`,而**不是**把它挂到
/// `LyricsSettingsTab` 上:`EnrichCacheStore` 是个有七八个 `@Published` 的单例,整页订阅它意味着
/// 任何一次 reload / 体积重算都要重画整张设置页。这个仓库为"@ObservedObject 订阅整个单例"踩过
/// 真实的过度重渲染 bug(见 OnboardingView 里 isPlayingNow 那段注释),把订阅面收在这一块里 ——
/// 也正因如此,译文 / 罗马音那两条行(它们读的是同一份 counts)也放在这里而不是 managementCard,
/// 免得为了传 counts 让外层再订阅一次。
struct LyricsLibraryStatsPanel: View {
    @ObservedObject private var store = EnrichCacheStore.shared
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
        // ⚠️ 用 VStack(spacing: 0) 而不是 Group 装这几行:修饰符挂在 Group 上会**逐个**作用到每个
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
                // 分隔线画在这一族的里面 —— 整行在 collector 还没公布过打分版本号时会整个
                // 消失,分隔线留在外面就会变成两条紧挨着的线。
                fullScanRow()
                CardDivider()
                // 译文 / 罗马音是叠在歌词之上的第二层数据,不参与上面那条比例条(它们跟五个桶不是
                // 互斥的划分),所以用从属行的语法挂在统计块下面:标签在左、裸值在右,跟系统设置一样直读。
                SettingsSubRow(title: L10n.t("译文")) {
                    Text(String(
                        format: L10n.t("%1$@ 首源自带 · %2$@ 首机翻"),
                        Self.format(counts.communityTranslation),
                        Self.format(counts.machineTranslation)))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                CardDivider()
                // 标题直接写「已缓存」:这个数**不是**"有多少首歌看得到罗马音"——App 侧 Romanizer 有
                // 客户端现算兜底,缓存里没有的照样会在渲染时现算(见 Counts.bundledRomanization 头注)。
                // ⓘ 只留两句:这个数在数什么、没被数的去哪了(原始要求
                // 「不要说那么多有的没的」;"三条来路"的枚举留在代码注释和第 10 章 §5 里)。
                SettingsSubRow(
                    title: L10n.t("已缓存罗马音"),
                    help: L10n.t("只数存进缓存、会随歌词文件一起导出的那些。其余歌曲的罗马音在播放时实时生成，不计入")
                ) {
                    Text(String(format: L10n.t("%@ 首歌"), Self.format(counts.bundledRomanization)))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        // `onlyIfChanged` 让重复进出这一页不重复解析整份缓存(全库几千条,那是一次真实的
        // 开销)。用 .task 而不是 .onAppear:reload 本身是 async 的,挂在 .task 上由 SwiftUI
        // 负责视图消失时取消。
        //
        // 之后留在这个循环里轮询补空扫描的进度:跑着的时候 2 秒一次、顺带
        // reload —— 每补上一首「暂无」那格就该少一;没在跑 5 秒一次只看进度文件的 mtime,
        // 一次 stat 的开销。视图消失即取消,没有常驻计时器。
        .task {
            await store.reload(onlyIfChanged: true)
            fullScanState = LyricsFullScan.current
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(fillSweepStatus?.running == true ? 2 : 5))
                guard !Task.isCancelled else { break }
                let sweep = LyricsFillSweep.current
                if sweep != fillSweepStatus { fillSweepStatus = sweep }
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

    /// 「共 N 首 ／ 97 MB」→ 比例条 → 四桶图例 → 「暂无」行。
    private func statsBlock(_ counts: LyricsLibraryStats.Counts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Self.totalText(counts.total)
                    .accessibilityLabel(String(format: L10n.t("共 %@ 首"), Self.format(counts.total)))
                Spacer(minLength: 12)
                LyricsLibrarySizeLabel()
            }
            SettingsProportionBar(segments: LyricsLibraryStats.Kind.allCases.map { kind in
                .init(id: kind.rawValue, value: counts.count(kind), color: kind.barColor)
            })
            // 图例分两行:上面四个是既成事实的桶,下面「暂无」独占一行 —— 它既是比例条橙色段的
            // 图例项,又是唯一带动作的桶,单拎出来才能让按钮跟橙色数字落在同一条水平线上
            // (重新扫描的入口"开在盯着橙色数字的地方")。
            HStack(spacing: 14) {
                ForEach(LyricsLibraryStats.Kind.allCases.filter { $0 != .none }, id: \.self) { kind in
                    legendItem(kind, value: counts.count(kind))
                }
            }
            noneRow(counts)
        }
    }

    /// 「共 3,669 首」:数字加粗、前后的字常规。三种语言各自决定数字前后写什么(英文是
    /// "3,669 songs"),所以按格式键里的 `%@` 切开再拼,而不是写死"数字 + 首"。
    private static func totalText(_ count: Int) -> Text {
        let number = Text(format(count))
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
        let parts = L10n.t("共 %@ 首").components(separatedBy: "%@")
        guard parts.count == 2 else { return number }
        let body = Font.system(size: 13)
        return Text(parts[0]).font(body) + number + Text(parts[1]).font(body)
    }

    /// 一个图例项:色点 + 标签 + 数字。数字一律 primary —— 只有「暂无」染色的规矩没变,见 LyricsKind.tint。
    private func legendItem(_ kind: LyricsLibraryStats.Kind, value: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(kind.barColor)
                .frame(width: 7, height: 7)
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

    /// 「暂无」行 = 图例项 + ⓘ + 尾部的「重新扫描」入口("在这个页面也加一个
    /// 重新扫描的入口"):对没歌词那批让 collector 现在就重搜一遍 —— 跟「歌词管理」工具栏那颗
    /// 「重试无歌词」是同一条通道(LyricsFillSweep,见第 09 章「补空扫描」)。
    ///
    /// 按钮上的数按 EnrichCacheStore.isFillSweepRetryable 算:「暂无」+ 只有纯文本兜底的,人工修正过的
    /// 除外 —— 所以它跟左边「暂无」那个数**就是**对不上的(本机 65 vs 74),ⓘ 一句话说清范围;
    /// 按钮说的是"真会被搜的条数",这一点是定下的,别为了让两个数一致去改它。
    /// 跑着的时候按钮原位换成圆环进度 + 「扫描中 12/74」+ 「停止」;上一轮结果在按钮左边留一句收据。
    ///
    /// ⚠️ **进度和收据都必须先判 `isFullScan`**(修):「全量重新扫库」为了跨重启续跑
    /// 复用了补空这条通道(见 collector/lyricsfullscan.go 头注),两轮共用**同一份**
    /// `lyrimuse-lyrics-fill-status.json`。不判的话,全量在跑时这一行会照着那份状态画出一模一样的
    /// 「扫描中 42/5318 + 停止」,跟下面「全量重新扫库」那行**逐字重复**;
    /// 当时两行连数字格式都不一样 —— 这里没走 `Self.format`、那边走了,一眼能看出是
    /// 两段代码在画同一份数据)。收据同理:全量跑完那句「过了 N 首」不该落在补空这一行。
    private func noneRow(_ counts: LyricsLibraryStats.Counts) -> some View {
        let status = fillSweepStatus
        // running = 任意一轮(collector 一次只准跑一轮);sweepRunning = 跑的是补空这一轮。
        // 两个量分开,正是因为这一行只该画补空那一轮,而按钮要对**任意**一轮置灰。
        let running = status?.running == true
        let sweepRunning = running && status?.isFullScan != true
        let retryable = store.summaries.filter(EnrichCacheStore.isFillSweepRetryable).count
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                legendItem(.none, value: counts.count(.none))
                HelpButton(text: L10n.t("重新扫描的范围：没有歌词的，加上只有纯文本的；人工修正过的不动"))
            }
            Spacer(minLength: 12)
            if sweepRunning, let status {
                ProgressView(value: Double(status.done), total: Double(max(status.total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(String(format: L10n.t("扫描中 %1$@/%2$@"), "\(status.done)", "\(status.total)"))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(L10n.t("停止")) { LyricsFillSweep.requestCancel() }
                    .controlSize(.small)
                    .fixedSize()
            } else {
                if let status, status.isFullScan != true, status.finishedAt != nil {
                    Text(String(format: L10n.t("上次：搜了 %1$@ 首，补出 %2$@ 首"), "\(status.done)", "\(status.filled)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                // 不带 SF Symbol:同一行左边已经写着「暂无」,再叠一个 ⟳ 是往控件上加装饰
                // (结论:要强调就改文字,别叠图标)。
                Button(String(format: L10n.t("重新扫描（%@ 首）"), Self.format(retryable))) {
                    LyricsFillSweep.request(keys: [])
                }
                // 全量那一轮跑着的时候也置灰,跟「全量重新扫库」那颗「开始」对称:collector
                // 一次只允许一轮在跑(runLyricsFillSweep 开头那道闸),这时点下去只会被静默丢掉。
                .disabled(running)
                .help(running ? L10n.t("另一轮扫描正在进行，等它结束再来") : "")
                // 跟卡名行的「打开歌词管理」同一档 .small:这一行别的内容都是 11pt,常规尺寸的按钮
                // 在这里显得笨重(真机截图对比过);主行「歌词文件夹」尾部那两颗仍是常规尺寸,它们配的是 13pt 标题。
                .controlSize(.small)
                .fixedSize()
                .disabled(retryable == 0)
                .help(L10n.t("让采集服务现在就把没有歌词的条目重新搜一遍，不用等每首歌再次播放"))
            }
        }
        // 这一行的按钮跟主行尾部的按钮是同一族控件,套同一套玻璃样式(它不在 SettingsRow 的
        // trailing 插槽里,那层修饰符够不着这里)。
        .settingsGlassButtons()
    }

    // MARK: 全量重新扫库

    /// 每首的平均耗时**由 collector 发布**(`LyricsFullScan.State.secondsPerTrack`,
    /// = lyricsFullScanGap + 一轮全源搜索的估计)。这里只留一个兜底值,给老 collector
    /// 或状态文件还没写出来的那一拍用。
    ///
    /// ⚠️ 别把它改回写死一份:之前这里是 `25.0`、注释还写着「15 秒固定间隔
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
        return store.summaries.reduce(into: 0) { total, summary in
            if EnrichCacheStore.fullScanTier(
                summary, currentScoringVersion: currentVersion, pinnedKeys: pinnedKeys) != nil {
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
    /// 为什么另起一行、不跟「重新扫描（N 首）」挤在「暂无」那一行:那颗按钮是**钉在橙色
    /// 「暂无」数字旁边**的("开在盯着橙色数字的地方"),而全量扫库跟
    /// 「暂无」没有从属关系 —— 它的对象是整个库,其中"没词的"只是第一层。跟「译文」「已缓存
    /// 罗马音」并列成一条"标签在左、值在右"的从属行,读法才对得上它真正的范围。
    @ViewBuilder
    private func fullScanRow() -> some View {
        if let state = fullScanState {
            CardDivider()
            let status = fillSweepStatus
            let running = status?.running == true
            let fullRunning = running && status?.isFullScan == true
            let pending = fullScanPending(state.scoringVersion)
            SettingsSubRow(
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
                        Button(L10n.t("开始")) { confirmFullScan = true }
                            .controlSize(.small)
                            .fixedSize()
                            // 补空那一轮跑着的时候也置灰:collector 一次只允许一轮在跑
                            // (runLyricsFillSweep 开头那道闸),这时点下去只会被静默丢掉。
                            .disabled(pending == 0 || running)
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
    private static func remainingText(_ status: LyricsFillSweep.Info,
                                     fallbackSecondsPerTrack: Double) -> String {
        let left = max(status.total - status.done, 0)
        guard left > 0 else { return L10n.t("就快好了") }
        let elapsed = Double(Date().timeIntervalSince1970) - Double(status.startedAt)
        let perTrack = status.done > 0 && elapsed > 0
            ? elapsed / Double(status.done)
            : fallbackSecondsPerTrack
        // 直接按实测速度算,不再绕"换算成等效首数"那一道:hoursText 现在收显式的每首秒数,
        // 把实测值原样传进去就行。
        return String(format: L10n.t("大约还要%@"), hoursText(left, secondsPerTrack: perTrack))
    }
}
