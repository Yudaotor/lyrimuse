import LyrimuseCore
import SwiftUI

/// 「歌词管理」卡里那块歌词库统计面板(2026-09-03 用户要求:「统计目前歌词数量,歌词情况,
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
        /// 2026-09-03 起这个数会明显长起来:collector 新增了预生成(`lyrics-romanize`
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
}

/// 「歌词库」标题行尾部那个占用空间(2026-09-04 用户要求,截图指的就是这一行右端的空位)。
///
/// 数字直接用 `EnrichCacheStore.totalSizeBytes` —— 「歌词管理」工具栏一直在显示的同一个值
/// (lyrics/ 权威源文件夹 + 缓存 JSON 本身),没有新增任何磁盘扫描。渲染口径也共用
/// `EnrichCacheStore.byteText`,免得同一个数在两扇窗口里写法不一样。
///
/// ⚠️ **算不出来就什么都不显示,绝不显示「零字节」**。`totalSizeBytes` 的初值是 0,而
/// `refreshSizeBytes()` 是个 detached task —— 首次打开这一页时有一小段窗口期值还是 0;
/// 另外 `clearAll()` 也会把它硬置 0。这两种情况下摆一个"0 字节"是在报一个假数字,而空库
/// 本来就有下面面板那句「还没有缓存任何歌词」在说话,这里再补一个 0 只会互相打架。
///
/// 单独一个小 View 的理由跟下面的统计面板一样:`EnrichCacheStore` 是个有七八个
/// `@Published` 的单例,订阅面收在真正用得到的这一小块里,别让整页跟着重画。
struct LyricsLibrarySizeLabel: View {
    @ObservedObject private var store = EnrichCacheStore.shared

    var body: some View {
        // 尾部只放**裸数字**、不写「占用 」前缀:同一张卡里「歌词文件夹」那一行的尾部也是
        // 裸路径,加了前缀反而跟邻行不齐。含义交给 help 气泡和 accessibilityLabel 带,
        // 两者都不占版面。
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

/// 设置页「歌词管理」卡里的统计面板。
///
/// ⚠️ 单独一个 View 而不是把 `@ObservedObject` 挂到 `LyricsSettingsTab` 上:`EnrichCacheStore`
/// 是个有七八个 `@Published` 的单例,整页订阅它意味着任何一次 reload / 体积重算都要重画整张
/// 设置页。这个仓库为"@ObservedObject 订阅整个单例"踩过真实的过度重渲染 bug(见
/// OnboardingView 里 isPlayingNow 那段注释),把订阅面收在这一小块里。
struct LyricsLibraryStatsPanel: View {
    @ObservedObject private var store = EnrichCacheStore.shared
    // collector 侧补空扫描的进度快照(LyricsFillSweep,进度文件按 mtime 读),由下面那个 .task 轮询。
    // 「歌词管理」窗口里同一份状态另有自己的一份 @State,两处各自轮询同一个文件,不共享——
    // 两扇窗口生命周期独立,共享一个 ObservableObject 只会多一个单例订阅面。
    @State private var fillSweepStatus: LyricsFillSweep.Info?

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
        VStack(alignment: .leading, spacing: 8) {
            if store.summaries.isEmpty && store.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在统计歌词库…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if counts.total == 0 {
                // 空库不是错误,是新装的常态 —— 说清楚下一步会发生什么,别摆一排 0。
                Text(L10n.t("还没有缓存任何歌词。放一首歌，Lyrimuse 会自动搜好存在这里"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    cell(value: counts.total, label: L10n.t("总数"), tint: .primary)
                    ForEach(LyricsLibraryStats.Kind.allCases, id: \.self) { kind in
                        cell(value: counts.count(kind), label: kind.label, tint: kind.tint)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(
                        format: L10n.t("译文 %1$@ 首源自带 · %2$@ 首机翻　|　%3$@ 首已缓存罗马音"),
                        Self.format(counts.communityTranslation),
                        Self.format(counts.machineTranslation),
                        Self.format(counts.bundledRomanization)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // 必须配一句解释,否则用户会拿这个数当"有多少首歌能看到罗马音"来读 ——
                    // 而那个数更大(见 Counts.bundledRomanization 的头注)。
                    //
                    // ⚠️ 文案 2026-09-03 砍过一轮(用户原话「不要说那么多有的没的」)。删掉的是
                    // "三条来路"的枚举和"哪些歌走实时生成"的举例 —— 那些是**开发者**需要知道的,
                    // 记在代码和第 10 章 §5 里就够了,不该占用户的气泡。留下的两句回答的是用户
                    // 站在这个数字前面唯一会问的问题:这个数到底在数什么、没被数的去哪了。
                    HelpButton(text: L10n.t("只数存进缓存、会随歌词文件一起导出的那些。其余歌曲的罗马音在播放时实时生成，不计入"))
                }
                fillSweepRow
            }
        }
        // `onlyIfChanged` 让重复进出这一页不重复解析整份缓存(全库几千条,那是一次真实的
        // 开销)。用 .task 而不是 .onAppear:reload 本身是 async 的,挂在 .task 上由 SwiftUI
        // 负责视图消失时取消。
        //
        // 之后留在这个循环里轮询补空扫描的进度(2026-09-05):跑着的时候 2 秒一次、顺带
        // reload —— 每补上一首「暂无」那格就该少一;没在跑 5 秒一次只看进度文件的 mtime,
        // 一次 stat 的开销。视图消失即取消,没有常驻计时器。
        .task {
            await store.reload(onlyIfChanged: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(fillSweepStatus?.running == true ? 2 : 5))
                guard !Task.isCancelled else { break }
                let sweep = LyricsFillSweep.current
                if sweep != fillSweepStatus { fillSweepStatus = sweep }
                if sweep?.running == true { await store.reload(onlyIfChanged: true) }
            }
        }
    }

    /// 「重新扫描」入口(2026-09-05 用户要求"在这个页面也加一个重新扫描的入口"):对「暂无」那批
    /// 让 collector 现在就重搜一遍——跟「歌词管理」工具栏那颗「重试无歌词」是同一条通道
    /// (LyricsFillSweep,见第 09 章「补空扫描」),只是入口开在用户正盯着那个橙色数字的地方。
    /// 数字按 EnrichCacheStore.isFillSweepRetryable 算(「暂无」+ 有纯文本兜底的,人工修正过的
    /// 除外),所以可能跟左边「暂无」那格差一两首——按钮说的是"真会被搜的条数",不是重复那格。
    /// 跑着的时候换成圆环进度 + 「停止重试」;上一轮结果留一句收据。
    private var fillSweepRow: some View {
        let status = fillSweepStatus
        let retryable = store.summaries.filter(EnrichCacheStore.isFillSweepRetryable).count
        return HStack(spacing: 10) {
            if let status, status.running {
                ProgressView(value: Double(status.done), total: Double(max(status.total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(String(format: L10n.t("重试中 %1$@/%2$@"), "\(status.done)", "\(status.total)"))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button(L10n.t("停止重试")) { LyricsFillSweep.requestCancel() }
                    .controlSize(.small)
            } else {
                Button {
                    LyricsFillSweep.request(keys: [])
                } label: {
                    Label(String(format: L10n.t("重新扫描无歌词条目（%@ 首）"), Self.format(retryable)),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                .disabled(retryable == 0)
                .help(L10n.t("让采集服务现在就把没有歌词的条目重新搜一遍，不用等每首歌再次播放"))
                if let status, status.finishedAt != nil {
                    Text(String(format: L10n.t("上次：搜了 %1$@ 首，补出 %2$@ 首"), "\(status.done)", "\(status.filled)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func cell(value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(Self.format(value))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // 均分整行宽度:格子数是固定的 6 个(总数 + 五个桶),等分比按内容宽度排更稳 ——
        // 数字位数会随着库变大而变化,按内容排会让这一排每次打开都轻微错位。
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(Self.format(value))")
    }
}
