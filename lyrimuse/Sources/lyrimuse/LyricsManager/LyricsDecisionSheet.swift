import SwiftUI
import LyrimuseCore

// 「解析决策」只读弹窗(2026-08-17,吸收自对 lyra 的对比审阅 C2)——把 collector 在
// **真正做决定那一刻**固化下来的候选表摊开:哪些源应答了、各自得了多少分、为什么被拒、
// 最后为什么是它赢。跟「联网搜索候选歌词」的本质区别:那个是**现在**重新抽一轮签
// (候选集受 20 秒期限影响,跟当初不一定一样),这个是当初那一轮的**存档**,离线、
// 零网络、几个月后照样一字不差。
//
// 刻意只读:这里不提供"改用某条候选"按钮 —— 想换歌词走「联网搜索候选歌词」那条路,
// 它拿的是新鲜正文;决策记录里根本没有正文(collector 侧三条铁律之一,见 decision.go),
// 也就不存在"从存档采纳"这种操作。
// collector 当前的打分算法版本(match.go 的 lyricsScoringVersion 常量)——两边手工保持
// 一致,collector 每次改动打分公式就同步改一次这里。跟 EnrichCacheKeys.swift 里那些
// 手工镜像 collector 常量的字段(crc32 表、归一化规则)是同一种做法:这个数字纯粹是
// "存档那一刻用的是第几版算法",不是需要在界面上展示给用户看的版本号(2026-08-31 用户
// 反馈"v4"这种裸编号没有对照、看不出新旧),只用来判断存档是不是用旧算法跑的。
private let currentLyricsScoringVersion = 18

struct LyricsDecisionSheet: View {
    let summary: EnrichCacheStore.Summary
    /// 展示页签:「当前歌词的出处」在前、「最近一次评估」在后;同一轮只留一份(见 init)。
    private let records: [(label: String, record: LyricsResolutionDecision)]
    @State private var selectedRecord = 0
    /// 哪几条候选是展开的(按源名)。**折叠态给差值、展开态给绝对明细带解释** ——
    /// 见 candidateRow 头注。默认全折:判词卡已经回答了"为什么是它",明细是第二层。
    @State private var expanded: Set<String> = []
    /// 「这一轮的输入与经过」是不是展开的。默认折:它是上下文,不是答案。
    @State private var inputsOpen = false
    @Environment(\.dismiss) private var dismiss

    /// - latest: lyrics_decision(最近一次评估 —— 可能维持原状,甚至输入本身是脏的,比如
    ///   换曲窗口串扰进来的错误时长那轮);
    /// - applied: lyrics_decision_applied(当前歌词的出处)。collector 2026-08-22 起分槽,
    ///   老条目没有后者:退回"最近评估恰好 applied"那份 —— 单槽时代它就是出处。
    /// 两份是同一轮(decidedAt+path 一致)就只展示一份,免得多出一个内容相同的页签。
    init(summary: EnrichCacheStore.Summary,
         latest: LyricsResolutionDecision?,
         applied: LyricsResolutionDecision?) {
        self.summary = summary
        let origin = applied ?? ((latest?.applied == true) ? latest : nil)
        var tabs: [(label: String, record: LyricsResolutionDecision)] = []
        if let origin {
            tabs.append((L10n.t("当前歌词的出处"), origin))
        }
        if let latest, origin == nil || origin?.decidedAt != latest.decidedAt || origin?.path != latest.path {
            tabs.append((L10n.t("最近一次评估"), latest))
        }
        self.records = tabs
    }

    private var decision: LyricsResolutionDecision? {
        records.isEmpty ? nil : records[min(selectedRecord, records.count - 1)].record
    }

    private func pathLabel(_ decision: LyricsResolutionDecision) -> String {
        switch decision.path {
        case "first-resolve": return L10n.t("首次解析")
        case "upgrade": return L10n.t("升级重试")
        case "rescore": return L10n.t("规则换版重选")
        // 「当初一条歌词都没搜到、后来又试了一次」那条路径(collector 的
        // needsLyricsFirstFill)。跟「升级重试」分开显示:那个是"本来有、想换更好的",
        // 这个是"本来没有、这次才填上"。
        case "refill": return L10n.t("补搜缺失歌词")
        // 用户在详情页点「重新自动匹配」那一次(collector search-lyrics -pick 写下的存档)。
        // 跟上面三条自动路径分开显示:它是手动触发的,但用的是**同一套**自动决策规则。
        case "manual-rematch": return L10n.t("手动重新匹配")
        // 兜底显示原始值:collector 那边新增一条路径、这边忘了补译名时,至少还看得出是哪条
        // (而不是空白)。但那就是漏了 —— 这张表跟 collector 里 buildLyricsDecision 的 path
        // 取值必须成对改,2026-08-21 的 manual-rematch 就是这么漏出来一个英文串的。
        default: return decision.path
        }
    }


    /// 查询词那一组是哪一轮问的(借鉴清单 V1)。取值全集在 collector 的 querylog.go
    /// `lyricQueryReason*`,那边的 lyricQueryReasons() 与本 switch 由
    /// `TestLyricQueryReasonsHaveChineseLabels` 双向对账 —— 跟 pathLabel 同一套约定:
    /// **default 是"原样显示原始值"**,漏补译名就是界面上直接印一个英文串给用户看。
    private func queryReasonLabel(_ reason: String?) -> String {
        switch reason ?? "" {
        case "": return L10n.t("首轮")
        case "title-split": return L10n.t("按「署名 - 曲名」拆分")
        case "alias-rescue": return L10n.t("别名轮：一个候选都没有")
        // 「缺罗马音」三个字 2026-09-12 被用户问「这里说的缺罗马音是什么意思？」——
        // 它像在描述一个结果状态,其实说的是**触发原因**,而且省掉了主语(谁缺)。
        // 真实判据在 collector `enrich.go` 的 needsRomanizationRetry:这一轮拿回来的歌词
        // 是中日韩文字(dominantScript 判 Han/Kana/Hangul),而**没有任何一个源**给出
        // 罗马音字段、也没有源标出语种(标了的话本地能自己注音,不用再查)。
        case "alias-roma": return L10n.t("别名轮：中日韩歌词但没有源给出罗马音")
        case "alias-missing": return L10n.t("别名轮：补缺席的源")
        case "primary-artist-variant": return L10n.t("只用第一位歌手")
        case "title-from-album": return L10n.t("标题反查：专辑曲目表")
        case "title-from-artist-search": return L10n.t("标题反查：歌手泛搜")
        case "title-from-apple-storefront": return L10n.t("标题反查：Apple 原产地商店")
        default: return reason ?? ""
        }
    }

    /// 把存档里的查询词记录压成分组摘要(2026-09-12,用户报「这部分可读性很差」)。
    ///
    /// 逐条平铺的老写法在真实案例上彻底失效:宇多田光《Beautiful World (Da Capo Version)
    /// [Instrumental]》一轮问了 9 组词,屏幕上 20 多个视觉行,而其中曲名重复 9 遍、
    /// 那串七个源的名单重复 8 遍 —— 真正的信息只有「曲名没变,换了 9 个歌手名」。
    /// 压缩规则与"曲名变过就不提取"这类边界都在 `LyricQueryDigestBuilder`(Core,selftest 覆盖)。
    private func queryDigest(_ decision: LyricsResolutionDecision) -> LyricQueryDigest? {
        guard let tried = decision.queriesTried, !tried.isEmpty else { return nil }
        // 只有首轮一组时不显示:那是绝大多数情况,常驻一段"这一轮实际问过:<跟上面查询词一样>"
        // 是纯噪音 —— 跟搜索弹窗那个轮次前缀「［2］」只从第 2 轮起才出现是同一个道理。
        guard tried.count > 1 || tried.first?.reason?.isEmpty == false else { return nil }
        return LyricQueryDigestBuilder.build(tried.map {
            LyricQueryRound(artist: $0.artist, title: $0.title ?? "",
                            reason: $0.reason ?? "", sources: $0.sources ?? [])
        })
    }

    /// 一组的组头:「别名轮：补缺席的源 · 只问 X、Y」。
    ///
    /// 别名轮有三档,**问的源范围不一样**,而这件事原来在界面上看不出来:
    /// 「补缺席的源」只定向问还缺着的那几个(带源名单),「一个候选都没有」和
    /// 「没有源给出罗马音」是全源重查(不带源名单)。实测全库存档里这个对应关系是死的:
    /// alias-missing 57 组全部带源名单,alias-rescue 57 组 / alias-roma 14 组全部不带。
    /// 所以后者缀一句「全部源重问」,跟前者的「只问 X、Y」对称 —— 不然读的人只看到
    /// 一个歌手名,不知道这一轮的动作范围有多大。
    private func groupHeading(_ g: LyricQueryGroup) -> String {
        var head = queryReasonLabel(g.reason)
        if !g.sources.isEmpty {
            head += " · " + String(format: L10n.t("只问 %@"),
                                   g.sources.map { sourceDisplayName($0) }.joined(separator: "、"))
        } else if g.reason.hasPrefix("alias-") {
            head += " · " + L10n.t("全部源重问")
        }
        return head
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if records.count > 1 {
                        // 「出处」解释现状,「最近一次评估」解释后来又评过什么、为什么没换
                        // (比如一轮维持原状的升级重试)。正是这两份对不上号让用户困惑
                        // (2026-08-22:一轮被换曲窗口串扰时长的重试盖掉了首解存档,记录
                        // 跟生效歌词说不到一块去),所以两份并排都给看,不再只剩最后一轮。
                        Picker("", selection: $selectedRecord) {
                            ForEach(records.indices, id: \.self) { i in
                                Text(records[i].label).tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if let decision {
                        // 顺序即「三层」:先一句判词回答"为什么是它",再摊候选表(每条一行,
                        // 落选的带差值分解),最后才是这一轮的输入。老版把输入放在最上面 ——
                        // 那是"数据的顺序",不是"看的人想问的顺序"。
                        verdictSection(decision)
                        chipsRow(decision)
                        candidateSection(decision)
                        sharedTermsLine(decision)
                        inputsSection(decision)
                    }
                }
                .padding(16)
            }
        }
        // 2026-09-05 用户要求这扇也「可拖拽可调整大小」(搜索候选那张 09-04 先做的)。
        // 两块能力都在 SheetWindowAffordances.swift,理由与实测在那边:sheet 既不可拖也
        // 不可缩放,都得落到底层 NSWindow 上补。maxWidth/maxHeight 必须一起放开——只留
        // 下限的话窗口拖大了内容仍停在 520×560,四周留白。
        .frame(
            minWidth: 460, idealWidth: 520, maxWidth: .infinity,
            minHeight: 420, idealHeight: 560, maxHeight: .infinity)
        .background(WindowResizeEnabler(minWidth: 460, minHeight: 420))
        // 切页签时把展开状态清掉:两份存档的候选集不一定相同,留着会让另一份里同名的源
        // 莫名其妙是展开的。
        .onChange(of: selectedRecord) { _, _ in expanded.removeAll() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("解析决策")).font(.headline)
                // 手动改过歌词的条目,这份存档描述的是人工覆盖**之前**那次自动评估。
                //
                // 2026-08-17 文案里原来直接写着 "collector"(用户报"这英文一点都不可读")。
                // 那是内部组件名 —— 它在界面上的正式称呼是「后台采集服务」(见设置页
                // 「播放器」那一栏)。但这句话压根不需要点名是谁干的:用户要知道的是
                // "这是当初自动挑歌词那一刻的快照,不是现在重新搜的结果",主语换成动作本身
                // 就够了,还省掉一个要解释的名词。
                Text(summary.isManual
                     ? L10n.t("记录的是手动修改之前的最后一次自动评估")
                     : L10n.t("当初自动挑选歌词那一刻的存档，现在重新搜索结果可能不同"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 替代 .textSelection(.enabled)(见 candidateRow 里那段注释:那个修饰符会让被点到
            // 的段落整段往下跳)。一次拷走整份决策,比拖选一段更贴合"贴进 issue 复盘"这个用途。
            Button(L10n.t("拷贝")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(plainTextDump, forType: .string)
            }
            .help(L10n.t("把整份决策记录拷到剪贴板（纯文本）"))
            Button(L10n.t("完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        // 垫在标题行背后:这扇窗口没有系统标题栏,不垫这块就整扇钉死在依附点挪不动。
        // 背景层不影响上面「拷贝」/「完成」接收点击(SwiftUI 命中测试前景优先)。
        .background(WindowDragHandle())
    }

    /// 整份决策记录的纯文本形态,给标题栏那个「拷贝」按钮用。
    ///
    /// 刻意跟界面上显示的东西一一对应(同一批字段、同样的顺序、同样的来源名翻译),而不是
    /// 直接把 JSON 倒出来:JSON 里是 netease/kugou 这类内部源名和一堆下划线字段名,贴进
    /// issue 之后还得有人翻译一遍。歌词正文本来就不在决策记录里(collector 侧三条铁律之一),
    /// 所以这份文本不含任何歌词内容。
    private var plainTextDump: String {
        var lines: [String] = []
        lines.append("\(summary.title) — \(summary.artist)")
        if !summary.album.isEmpty { lines.append(summary.album) }
        // 两槽都有就都拷 —— 这份文本的用途是复盘,"出处"和"最近评估"对不上号本身往往就是
        // 要复盘的问题,只拷当前页签会丢掉另一半证据。
        for (i, item) in records.enumerated() {
            if records.count > 1 {
                if i > 0 { lines.append("") }
                lines.append("== \(item.label) ==")
            }
            lines.append(contentsOf: dumpLines(item.record))
        }
        return lines.joined(separator: "\n")
    }
    // MARK: - 分析(界面与「拷贝」共用同一份)

    /// 界面上的一条候选:存档模型 + 映射给 Core 的分析输入。
    private struct Row: Identifiable {
        var id: String { core.source }
        let model: LyricsResolutionDecision.Candidate
        let core: LyricsScoredCandidate
    }

    /// 这一份存档的全部分析结果。界面和「拷贝」出去的纯文本**共用**同一份 —— 两边各算
    /// 一遍的话,措辞和口径迟早漂开(查询词摘要那次就是这么约定的,见 queryDigest 头注)。
    private struct Analysis {
        /// 参赛候选,按分数降序(冠军在最前)。
        let rows: [Row]
        /// 不参赛的:纯音乐标记 / 被判不可用。排在参赛候选之后。
        let sidelined: [Row]
        let champion: Row?
        /// 落选候选相对冠军的差值分解,按源名索引。
        let deltas: [String: LyricsScoreDelta]
        let verdict: LyricsVerdict?
        /// 每条参赛候选上完全相同的项 —— 折成一行说一次。
        let shared: [LyricsScoreTermValue]
    }

    private func analysis(_ decision: LyricsResolutionDecision) -> Analysis {
        let models = decision.candidates ?? []
        let all = models.map { c in
            Row(model: c,
                core: LyricsScoredCandidate(
                    source: c.source,
                    score: c.score,
                    terms: (c.scoreTerms ?? []).map {
                        LyricsScoreTermValue(kind: $0.kind, points: $0.points)
                    },
                    instrumental: c.instrumental,
                    consensusPeers: c.consensusPeers ?? []))
        }
        let cores = all.map(\.core)
        let rankedSources = LyricsVerdictBuilder.ranked(cores, winner: decision.winner).map(\.source)
        // 按 Core 排好的次序把 Row 摆回去。用 source 查表而不是让 Core 认识 Row ——
        // Core 不该知道 App 的解码模型长什么样。
        let bySource = Dictionary(all.map { ($0.core.source, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = rankedSources.compactMap { bySource[$0] }
        let sidelined = all.filter { !$0.core.isContender }
        let championCore = LyricsVerdictBuilder.champion(among: cores, winner: decision.winner)
        let champion = championCore.flatMap { bySource[$0.source] }
        var deltas: [String: LyricsScoreDelta] = [:]
        if let championCore {
            let losers = rows.map(\.core).filter { $0.source != championCore.source }
            for d in LyricsVerdictBuilder.deltas(champion: championCore, others: losers) {
                deltas[d.source] = d
            }
        }
        return Analysis(
            rows: rows,
            sidelined: sidelined,
            champion: champion,
            deltas: deltas,
            verdict: LyricsVerdictBuilder.build(candidates: cores, winner: decision.winner),
            shared: LyricsVerdictBuilder.sharedTerms(among: cores))
    }

    /// 把「歌手 / 歌名 / 专辑」这类**异质**字段拼成一行:每个值带标签、用「」框住。
    ///
    /// 2026-09-12 用户截图报「需要能看出来分别是歌名、歌手、专辑」。原来是拿 `" / "` 或
    /// `" · "` 把几个值直接拼起来,读的人只能靠位置猜是谁 —— 而这几个值经常长得几乎一样
    /// (截图那次:歌名 `JANE DOE`、专辑 `JANE DOE - Single`),更要命的是**值里本来就有
    /// 分隔符**(`米津玄師、宇多田ヒカル` 里的顿号、`JANE DOE - Single` 里的连字符),
    /// 跟拼接用的分隔符混成一片,连"这是几个值"都读不出来。
    /// 标签回答「谁是谁」,「」回答「到哪儿为止」,两个都需要。
    private func labeledFields(_ fields: [(String, String?)]) -> String {
        fields.compactMap { label, value -> String? in
            guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return label + "「" + v + "」"
        }.joined()
    }

    /// 这个源匹配到的是哪首 / 哪个版本 —— 排查「串版本」的关键一行,同上加标签。
    private func matchedText(_ c: LyricsResolutionDecision.Candidate) -> String {
        labeledFields([(L10n.t("歌名"), c.title), (L10n.t("歌手"), c.artist), (L10n.t("专辑"), c.album)])
    }

    /// 决策的完整输入:发出去的查询词(已转简体,可能跟本地标签不同)。
    private func queryText(_ decision: LyricsResolutionDecision) -> String {
        labeledFields([(L10n.t("歌手"), decision.queryArtist),
                       (L10n.t("歌名"), decision.queryTitle),
                       (L10n.t("专辑"), decision.queryAlbum)])
    }

    /// 一组查询词那一行。
    ///
    /// 全组都没带曲名(曲名全程没变、已经在上面「曲名始终是…」说过一次)时,「歌手」只说
    /// 一次、后面一串「」框住的名字 —— 截图那次的 `米津玄師 · 米津玄師、宇多田ヒカル`
    /// 于是变成 `歌手「米津玄師」「米津玄師、宇多田ヒカル」`,一眼看得出是两个名字。
    private func groupQueriesText(_ g: LyricQueryGroup) -> String {
        if g.queries.allSatisfy({ $0.title.isEmpty }) {
            return L10n.t("歌手") + g.queries.map { "「\($0.artist)」" }.joined()
        }
        return g.queries
            .map { labeledFields([(L10n.t("歌手"), $0.artist), (L10n.t("歌名"), $0.title)]) }
            .joined(separator: "  ")
    }

    /// 打分项的中文名。跟候选明细里那段 explanation 用的是**同一份** label
    /// (LyricsSearchService.ScoreTerm),漏译一个 kind 两处一起漏,不会一边对一边错。
    private func termLabel(_ kind: String) -> String {
        LyricsSearchService.ScoreTerm(kind: kind, points: 0).label
    }

    private func signedText(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }

    /// 一行紧凑的打分项:「逐字时间轴 +400 · 时长吻合 +276 · 行数 +39」。
    /// 冠军那行摊的是**绝对**分值,落选那行摊的是**相对冠军的差值** —— 后者里
    /// 相同的项自动消失(差值为 0),那正是实测那 32% 冗余的来源。
    private func compactTerms(_ terms: [LyricsScoreTermValue]) -> String {
        terms.map { "\(termLabel($0.kind)) \(signedText($0.points))" }.joined(separator: " · ")
    }

    /// 冠军那行的绝对分项,按绝对值从大到小 —— 跟 explanation 的排序规则一致
    /// (用户真正在问的是"它凭什么排第一",答案该第一项就出现)。
    private func championTerms(_ row: Row) -> [LyricsScoreTermValue] {
        row.core.terms.sorted { abs($0.points) > abs($1.points) }
    }

    /// 「曲名是反查出来的」——(本地曲名, 反查出来的曲名)。两者相同或缺一就是 nil。
    ///
    /// 全库只有 13 份存档(0.3%)会命中。罕见,但发生时它是关于这次解析最重要的一个事实:
    /// 本地那个曲名压根搜不到,这份词是用**另一个曲名**找回来的 —— 所以给它一条独立横幅,
    /// 而不是让它当查询词摘要里一个跟「按 286 秒校验」同灰度的组头。
    private func titleRewrite(_ decision: LyricsResolutionDecision) -> (from: String, to: String)? {
        let to = (decision.correctedTitle ?? "").trimmingCharacters(in: .whitespaces)
        let from = (decision.queryTitle ?? "").trimmingCharacters(in: .whitespaces)
        guard !to.isEmpty, !from.isEmpty, to != from else { return nil }
        return (from, to)
    }

    /// 分差那句话里的百分比后缀。分差为 0、或冠军分非正(理论上不会)时不显示 ——
    /// 「0 分（0.0%）」是废话,而分母非正时百分比没有意义。
    private func gapPercentText(gap: Int, percent: Double?) -> String {
        guard gap > 0, let percent else { return "" }
        return String(format: "%.1f%%", percent)
    }

    /// 判词的两行文案。Core 只给结构(它不做本地化),措辞在这儿。
    ///
    /// ⚠️ **不归因**:`.multiple` 那一档刻意什么都不说 —— 此前实测否掉过一版
    /// 「用一句话解释胜者凭什么赢」,只有 13.2% 的对局存在单一强势维度能真的解释分差。
    /// 这里只在 `.single`(唯一一项有差)和 `.identical`(完全平局)时才开口。
    private func verdictText(_ v: LyricsVerdict) -> (title: String, detail: String) {
        switch v {
        case let .sameLyrics(contenders, gap, percent, nearTie, separator):
            var detail = gapSentence(gap: gap, percent: percent, nearTie: nearTie,
                                     sayNearTie: true, separator: separator)
            // 内容一致意味着分差比的是包装,不是词本身 —— 这句话是这一档判词的全部价值。
            detail += " " + L10n.t("分差比的是包装（有没有逐字轴、有没有译文），不是内容。")
            return (String(format: L10n.t("%d 个源给的是同一份词"), contenders), detail)

        case let .decisiveNegative(term, loser, gap):
            return (String(format: L10n.t("「%@」是胜负手"), termLabel(term.kind)),
                    String(format: L10n.t("%1$@ 在这一项上被扣 %2$d 分，胜者没有这一项——%3$d 分的分差全在这里。"),
                           sourceDisplayName(loser), abs(term.points), gap))

        case let .tooClose(contenders, corroborated, gap, percent, separator):
            // 标题已经说了「几乎打平」,正文那句就别再复述一遍(sayNearTie: false)。
            var detail = gapSentence(gap: gap, percent: percent, nearTie: true,
                                     sayNearTie: false, separator: separator)
            // 跟 .sameLyrics 的分水岭:那边每条候选都拿到了别的源的内容印证,这边没有。
            // ⚠️ 给出**计数**而不是只说「不是每条都有」——读的人眼睛正盯着冠亚两行,
            // 光说"不是每条"很容易读成"这两份不是同一份词",而它们往往恰恰是同一份。
            detail += " " + String(format: L10n.t("%1$d 条候选里只有 %2$d 条拿到了内容印证，未必都是同一份词。"),
                                   contenders, corroborated)
            // 标题两件事都说全:分差极小 **且** 内容印证不全 —— 后者才是这一档跟
            // .sameLyrics 的分水岭,也是真正值得人工看一眼的原因。
            return (L10n.t("几乎打平，但内容印证不全"), detail)
        }
    }

    /// 「差多少」那句话 + 「差在哪」那半句。
    ///
    /// ⚠️ 打分项完全相同时**不说分差** —— 「分差只有 0 分，几乎打平」不是人话,
    /// 而 separator 那句「两边打分完全相同，先后由来源顺序决定」已经把话说全了
    /// (实测:方大同《1234567》酷狗与 QQ 同为 1219 分,原措辞就是这么露出来的)。
    /// - sayNearTie: 句尾要不要缀「，几乎打平」。判词标题本身已经这么说时传 false,
    ///   否则一句话里同一件事说两遍。
    private func gapSentence(gap: Int, percent: Double?, nearTie: Bool, sayNearTie: Bool,
                             separator: LyricsVerdictSeparator) -> String {
        if case .identical = separator {
            return L10n.t("两边打分完全相同，先后由来源顺序决定。")
        }
        let pct = gapPercentText(gap: gap, percent: percent)
        var s: String
        if gap == 0 {
            // 分项有差但加起来正好抵平 —— 罕见,但不能说成「分差只有 0 分」。
            s = L10n.t("两边同分。")
        } else if nearTie && sayNearTie {
            s = pct.isEmpty
                ? String(format: L10n.t("分差只有 %d 分，几乎打平。"), gap)
                : String(format: L10n.t("分差只有 %1$d 分（%2$@），几乎打平。"), gap, pct)
        } else if nearTie {
            s = pct.isEmpty
                ? String(format: L10n.t("分差只有 %d 分。"), gap)
                : String(format: L10n.t("分差只有 %1$d 分（%2$@）。"), gap, pct)
        } else {
            s = pct.isEmpty
                ? String(format: L10n.t("分差 %d 分。"), gap)
                : String(format: L10n.t("分差 %1$d 分（%2$@）。"), gap, pct)
        }
        if let extra = separatorText(separator) { s += " " + extra }
        return s
    }

    /// 冠亚「差在哪」那半句。`.multiple` 返回 nil —— 见 verdictText 头注。
    private func separatorText(_ s: LyricsVerdictSeparator) -> String? {
        switch s {
        case .identical:
            return L10n.t("两边打分完全相同，先后由来源顺序决定。")
        case let .single(term) where term.points > 0:
            return String(format: L10n.t("唯一的差别是胜者在「%1$@」上多 %2$d 分。"),
                          termLabel(term.kind), term.points)
        case let .single(term):
            // 理论上冠军在唯一有差的那项上不该更低(会输)——除非分数被夹过。兜底说一句
            // 中性的,别印一个"多 −30 分"。
            return String(format: L10n.t("唯一的差别在「%@」这一项上。"), termLabel(term.kind))
        case .multiple:
            return nil
        }
    }

    /// 单份决策记录的纯文本行(plainTextDump 按页签逐份拼接)。
    /// 内容跟界面一一对应 —— 判词、差值分解、共有项都用 analysis() 那一份,
    /// 贴进 issue 的人和看界面的人读到的是同一个结论。
    private func dumpLines(_ decision: LyricsResolutionDecision) -> [String] {
        let a = analysis(decision)
        var lines: [String] = []
        var head = [pathLabel(decision)]
        if let applied = decision.applied {
            head.append(applied ? L10n.t("已采用") : L10n.t("评估后维持原状"))
        }
        if let version = decision.scoringVersion, version < currentLyricsScoringVersion {
            head.append(L10n.t("旧打分算法"))
        }
        if let ts = decision.decidedAt, ts > 0 {
            // ⚠️ 必须显式传 L10n.locale,不能让它隐式落到 Locale.current(2026-09-02
            // 用户报:界面语言切成英文之后,这里的日期还是"2026年8月22日"中文格式)——
            // Date.formatted(date:time:) 不传 locale 时默认走系统区域设置,跟不走 .strings
            // 表的其它系统 API 是同一类坑,见 L10n.locale 头注那次"语言名中英混排"案例。
            head.append(Date(timeIntervalSince1970: TimeInterval(ts))
                .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))
        }
        lines.append(head.joined(separator: " · "))
        // 判词跟界面上是同一句 —— 贴进 issue 的人和看界面的人读到的是同一个结论。
        if let v = a.verdict {
            let t = verdictText(v)
            lines.append(t.title + " —— " + t.detail)
        }
        if let rewrite = titleRewrite(decision) {
            lines.append(String(format: L10n.t("曲名对不上：本地叫「%1$@」，找到的是《%2$@》"),
                                rewrite.from, rewrite.to))
            if let how = titleRewriteHow(decision) { lines.append("  " + how) }
        }
        let query = queryText(decision)
        if !query.isEmpty { lines.append(String(format: L10n.t("查询词：%@"), query)) }
        // 首轮那一组之外还问过什么(借鉴清单 V1)。只有一组、且就是首轮时不重复印。
        // 跟界面用同一份 digest,拷出去的文本和屏幕上看到的是同一个形状。
        if let digest = queryDigest(decision) {
            lines.append(String(format: L10n.t("这一轮实际问过 %d 组"), digest.total))
            if let t = digest.sharedTitle {
                lines.append("  " + String(format: L10n.t("曲名始终是「%@」"), t))
            }
            for g in digest.groups {
                lines.append("  " + groupHeading(g))
                lines.append("    " + groupQueriesText(g))
            }
        }
        if let secs = decision.durationSecs, secs > 0 {
            lines.append(String(format: L10n.t("按 %@ 秒的曲目时长校验"), String(format: "%.0f", secs)))
        }
        if let responded = decision.sourcesResponded, !responded.isEmpty {
            lines.append(String(format: L10n.t("本轮应答的源：%@"),
                                responded.map { sourceDisplayName($0) }.joined(separator: "、")))
            if let silent = silentSourcesText(responded) { lines.append("  " + silent) }
        }
        if !a.shared.isEmpty {
            lines.append(String(format: L10n.t("所有候选都相同的项：%@"), compactTerms(a.shared)))
        }
        for row in a.rows + a.sidelined {
            lines.append("")
            let c = row.model
            // 跟界面同一个判据:纯音乐标记和被拒的候选都不印分数。贴进 issue 复盘时,
            // 一行 "LRCLIB · -1" 一样是看不懂的 —— 那个 -1 是内部手段,不是评价。
            if row.core.isInstrumentalMarker {
                lines.append(sourceDisplayName(c.source) + " · " + L10n.t("纯音乐"))
                lines.append(L10n.t("这个源明确说这首是纯音乐，所以它没有参与打分"))
                continue
            }
            if row.core.isRejected {
                lines.append(sourceDisplayName(c.source))
                if let terms = c.scoreTerms, !terms.isEmpty {
                    lines.append(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
                }
                let matched = matchedText(c)
                if !matched.isEmpty { lines.append(matched) }
                continue
            }
            var tag = [sourceDisplayName(c.source), "\(c.score)"]
            if row.core.source == a.champion?.core.source { tag.append(L10n.t("胜者")) }
            if c.hasWordTiming == true { tag.append(L10n.t("逐字")) }
            lines.append(tag.joined(separator: " · "))
            // 落选的先给差值分解(「差在哪」),再给绝对明细 —— 顺序跟界面一致。
            if let d = a.deltas[row.core.source] {
                lines.append(String(format: L10n.t("落后 %d 分"), abs(d.scoreGap)))
                if !d.terms.isEmpty {
                    lines.append(String(format: L10n.t("差在：%@"), compactTerms(d.terms)))
                }
                if let raw = d.clampedRawSum {
                    lines.append("  " + clampNote(rawSum: raw, score: c.score))
                }
            }
            let matched = matchedText(c)
            if !matched.isEmpty { lines.append(matched) }
            if let terms = c.scoreTerms, !terms.isEmpty {
                lines.append(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
            }
            if let peers = c.consensusPeers, !peers.isEmpty {
                lines.append(String(format: L10n.t("跟 %@ 是同一份词"),
                                    peers.map { sourceDisplayName($0) }.joined(separator: "、")))
            }
        }
        return lines
    }

    // MARK: - 判词 / 输入 / 共有项

    /// 判词卡 + 「曲名是反查出来的」条件横幅。两块都**命不中就不渲染** ——
    /// 常驻一块「暂无判词」的灰框只会占地方,跟「只有首轮一组时不显示查询词摘要」同理。
    @ViewBuilder
    private func verdictSection(_ decision: LyricsResolutionDecision) -> some View {
        let a = analysis(decision)
        let rewrite = titleRewrite(decision)
        if a.verdict != nil || rewrite != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let v = a.verdict {
                    let t = verdictText(v)
                    VerdictCard(title: t.title, detail: t.detail, tint: verdictTint(v))
                }
                if let rewrite {
                    VerdictCard(
                        title: String(format: L10n.t("曲名对不上：本地叫「%1$@」，找到的是《%2$@》"),
                                      rewrite.from, rewrite.to),
                        detail: titleRewriteHow(decision) ?? "",
                        tint: .orange)
                }
            }
        }
    }

    /// 判词卡的底色。`.decisiveNegative` 用橙色 —— 它说的是「有个候选配错了」,
    /// 跟另外两档「大家其实差不多」的语气不一样,不该长得一样。
    private func verdictTint(_ v: LyricsVerdict) -> Color {
        if case .decisiveNegative = v { return .orange }
        return .accentColor
    }

    /// 「怎么问出真名的」那半句。retry_method 跟查询词摘要的 reason 是同一套取值,
    /// 所以复用同一张译名表(queryReasonLabel)——漏补译名两处一起漏,不会一边对一边错。
    private func titleRewriteHow(_ decision: LyricsResolutionDecision) -> String? {
        guard let m = decision.retryMethod, !m.isEmpty else { return nil }
        return String(format: L10n.t("本地那个曲名没搜到，最后靠「%@」问出真名。"),
                      queryReasonLabel(m))
    }

    /// 路径 / 是否采用 / 算法是否过期 / 时间 —— 这一轮的"身份信息",一行胶囊。
    @ViewBuilder
    private func chipsRow(_ decision: LyricsResolutionDecision) -> some View {
        HStack(spacing: 8) {
            InfoChip(icon: "clock.arrow.circlepath", text: pathLabel(decision), tint: .blue)
            if let applied = decision.applied {
                InfoChip(icon: applied ? "checkmark.circle" : "equal.circle",
                         text: applied ? L10n.t("已采用") : L10n.t("评估后维持原状"),
                         tint: applied ? .green : .secondary)
            }
            // 不展示具体版本号(裸编号没有对照、用户看不出新旧,见
            // currentLyricsScoringVersion 头注),只在存档确实比当前算法旧时提示一句——
            // 呼应面板副标题"现在重新搜索结果可能不同"那句话,给出具体原因。
            if let version = decision.scoringVersion, version < currentLyricsScoringVersion {
                InfoChip(icon: "arrow.triangle.2.circlepath", text: L10n.t("旧打分算法"), tint: .orange)
            }
            if let ts = decision.decidedAt, ts > 0 {
                // ⚠️ 同 dumpLines 那处——必须显式传 L10n.locale,不能落到 Locale.current。
                InfoChip(icon: "calendar",
                         text: Date(timeIntervalSince1970: TimeInterval(ts))
                             .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)),
                         tint: .secondary)
            }
        }
    }

    /// 「所有候选都相同的项」折成一行说一次。
    ///
    /// 实测:打分项**种类**的共有率中位 71%、完全相同的行占全部明细的 32% —— 逐条摊开时
    /// 这些项在每条候选上重复一遍,是冗余的主要来源。落选候选的差值分解里它们本来就
    /// 自动消失(差值为 0),这一行是把"它们去哪了"交代清楚,免得让人以为漏了。
    @ViewBuilder
    private func sharedTermsLine(_ decision: LyricsResolutionDecision) -> some View {
        let a = analysis(decision)
        if !a.shared.isEmpty, a.rows.count >= 2 {
            Text(String(format: L10n.t("%1$d 条候选在这些项上完全相同：%2$@"),
                        a.rows.count, compactTerms(a.shared)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.07)))
        }
    }

    /// 「当前启用的源里，这几个没有应答」。
    ///
    /// ⚠️ 分母是**当前**启用的源,存档里没有记「当时启用了哪些」——所以措辞只说
    /// "当前启用的"、不说"没露面"那种像是在陈述历史事实的话,并在 tooltip 里点明。
    /// 跟列表里那个「3/9」角标是同一个取舍(见 LyricsManagerView 里那段注释)。
    private func silentSourcesText(_ responded: [String]) -> String? {
        let enabled = FeatureSettingsStore.shared.lyricsSources.map(\.rawValue)
        let silent = enabled.filter { !responded.contains($0) }
        guard !silent.isEmpty else { return nil }
        return String(format: L10n.t("当前启用的其余源没有应答：%@"),
                      silent.map { sourceDisplayName($0) }.joined(separator: "、"))
    }

    /// 分项之和被夹过时的说明。
    ///
    /// collector 在 match.go 里把负分**统一夹到 1**(注释原话:重扣表达「差」不是「不能用」)。
    /// 全库 644 行(3.74%)、443 份存档(10%)因此"分项加起来对不上总分" —— 不说这一句的话,
    /// 谁真去加一遍都会以为界面算错了(现状就是不说,藏得住只是因为没人去加)。
    private func clampNote(rawSum: Int, score: Int) -> String {
        String(format: L10n.t("分项合计 %1$d，被夹到最低分 %2$d"), rawSum, score)
    }

    /// 「这一轮的输入与经过」——查询词 / 曲长 / 应答的源 / 问过哪几组词。
    ///
    /// 默认折叠:它是**上下文**,不是答案。老版把它放在最上面、常年摊开,占掉一屏里
    /// 最值钱的那几行,而看的人第一个问题几乎总是"为什么是它"。
    /// 折叠态那一行摘要:「5/9 个源应答 · 问过 3 组词 · 按 286 秒校验」。
    /// 抽成普通函数而不是写在 @ViewBuilder 里 —— 那里面放不了 var / append 这类语句。
    private func inputsSummary(_ decision: LyricsResolutionDecision) -> String {
        var parts: [String] = []
        let responded = decision.sourcesResponded ?? []
        if !responded.isEmpty {
            parts.append(String(format: L10n.t("%1$d/%2$d 个源应答"),
                                responded.count, LyricsSource.allCases.count))
        }
        if let digest = queryDigest(decision) {
            parts.append(String(format: L10n.t("问过 %d 组词"), digest.total))
        }
        if let secs = decision.durationSecs, secs > 0 {
            parts.append(String(format: L10n.t("按 %@ 秒校验"), String(format: "%.0f", secs)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func inputsSection(_ decision: LyricsResolutionDecision) -> some View {
        let digest = queryDigest(decision)
        let responded = decision.sourcesResponded ?? []
        let total = LyricsSource.allCases.count
        let summary = inputsSummary(decision)
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { inputsOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: inputsOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2).frame(width: 10)
                    Text(L10n.t("这一轮的输入与经过")).font(.caption)
                    if !inputsOpen, !summary.isEmpty {
                        Text("· " + summary)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(String(format: L10n.t("源数分母是当前启用的 %d 个源；老条目当年可用的源可能更少"), total))

            if inputsOpen {
                VStack(alignment: .leading, spacing: 4) {
                    let query = queryText(decision)
                    if !query.isEmpty {
                        Text(String(format: L10n.t("查询词：%@"), query))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let secs = decision.durationSecs, secs > 0 {
                        Text(String(format: L10n.t("按 %@ 秒的曲目时长校验"), String(format: "%.0f", secs)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !responded.isEmpty {
                        // "谁应答了"是排查的第一问 —— 没露面的源(超时/网络)根本不在候选表里,
                        // 单看上面那张表会误以为它压根不存在。
                        Text(String(format: L10n.t("本轮应答的源：%@"),
                                    responded.map { sourceDisplayName($0) }.joined(separator: "、")))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let silent = silentSourcesText(responded) {
                            Text(silent)
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // "我到底拿哪些词问的"(借鉴清单 V1)。上面那行查询词只是**首轮**那一组,而一轮
                    // 解析最多换五种问法 —— 09 章里五条真实的"搜不到 / 配错了"根因全是问错了词。
                    if let digest {
                        Text(String(format: L10n.t("这一轮实际问过 %d 组"), digest.total))
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.top, 2)
                        // 曲名全程没变时提到最上面说一次,组内就只剩歌手名 —— 这一条是把
                        // 那 20 个视觉行压掉一半的主力。曲名变过(标题反查轮)时 sharedTitle
                        // 为 nil,曲名并回每一条里,不丢信息。
                        if let t = digest.sharedTitle {
                            Text(String(format: L10n.t("曲名始终是「%@」"), t))
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(digest.groups) { g in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(groupHeading(g))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(groupQueriesText(g))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 10)
                            }
                        }
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    // MARK: - 候选表

    @ViewBuilder
    private func candidateSection(_ decision: LyricsResolutionDecision) -> some View {
        let a = analysis(decision)
        if a.rows.isEmpty && a.sidelined.isEmpty {
            Text(L10n.t("这一轮没有任何源给出候选"))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            // 只要**这一轮里有任何一条**候选带封面,就给所有行都留出封面位;一条都没有
            // 就整轮不留 —— 这样:
            //   - 老存档(2026-09-01 之前固化的,压根没有 cover_url 字段)不会变成一列
            //     灰色音符占位符,那看着像坏了;
            //   - 新存档里 LRCLIB/QQ 这种本来就不给封面的源留一个占位符,行左边缘仍然
            //     对齐,不会参差。
            let showsCover = (decision.candidates ?? []).contains { !($0.coverUrl ?? "").isEmpty }
            let top = a.rows.first?.core.score ?? 0
            VStack(alignment: .leading, spacing: 4) {
                ForEach(a.rows) { row in
                    candidateRow(row,
                                 delta: a.deltas[row.core.source],
                                 isChampion: row.core.source == a.champion?.core.source,
                                 topScore: top,
                                 showsCover: showsCover)
                }
                // 不参赛的排在最后:纯音乐标记和被拒的候选没有分数可比,混在有分数的行里
                // 会让那一列参差,而它们本身是"信号"不是"对手"。
                ForEach(a.sidelined) { row in
                    sidelinedRow(row, showsCover: showsCover)
                }
            }
        }
    }

    /// 一条参赛候选。
    ///
    /// **折叠态 = 差值,展开态 = 绝对明细带解释。** 这是整个重设计的落点:
    /// 落选的候选,用户不关心它得了多少,只关心它**差在哪** —— 「行数 −1」比
    /// 「+400 / +250 / +164 / +51 / +50 / +30」有用得多,而且相同的项在差值里
    /// 自动消失。要看全量(每一项什么意思、匹配到哪个版本)就点开。
    private func candidateRow(_ row: Row, delta: LyricsScoreDelta?, isChampion: Bool,
                              topScore: Int, showsCover: Bool) -> some View {
        let isOpen = expanded.contains(row.core.source)
        let c = row.model
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    if isOpen { expanded.remove(row.core.source) }
                    else { expanded.insert(row.core.source) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 10)
                    if showsCover { candidateCover(c.coverUrl, size: 22) }
                    Text(sourceDisplayName(c.source))
                        .font(.callout.weight(isChampion ? .semibold : .regular))
                        .foregroundStyle(sourceColor(c.source))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(sourceColor(c.source).opacity(0.12), in: Capsule())
                    if isChampion {
                        Label(L10n.t("胜者"), systemImage: "crown.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if c.hasWordTiming == true {
                        Text(L10n.t("逐字")).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Text("\(c.score)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    // 差值列固定宽度、冠军留空 —— 分数列才对得齐,一眼能比长短。
                    Text(delta.map { signedText($0.scoreGap) } ?? "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    scoreBar(score: c.score, top: topScore, tint: sourceColor(c.source))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 可点时换手型光标 —— 没有它,「能点」这件事在 macOS 上没有任何视觉线索
            // (列表里那个「3/9」角标第一版就是这么丢的,用户报「我点击也没有反应」)。
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            if isOpen {
                expandedDetail(row, delta: delta)
            } else {
                // 折叠态那一行紧凑摘要:冠军摊绝对分项,落选的摊相对冠军的差值。
                let terms = delta?.terms ?? championTerms(row)
                if !terms.isEmpty {
                    Text(compactTerms(terms))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, showsCover ? 39 : 17)
                }
                if let raw = delta?.clampedRawSum {
                    Text(clampNote(rawSum: raw, score: c.score))
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.leading, showsCover ? 39 : 17)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isChampion ? Color.orange.opacity(0.07) : Color.secondary.opacity(0.05)))
    }

    /// 展开态:这个源匹配到的是哪首/哪个版本 + 全量打分明细(带每一项的解释) + 内容印证。
    @ViewBuilder
    private func expandedDetail(_ row: Row, delta: LyricsScoreDelta?) -> some View {
        let c = row.model
        VStack(alignment: .leading, spacing: 4) {
            let matched = matchedText(c)
            if !matched.isEmpty {
                Text(matched).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let terms = c.scoreTerms, !terms.isEmpty {
                // 直接摊开,不做悬停 —— 这是复盘界面,把证据全亮出来正是它存在的目的。
                //
                // ⚠️ 这里**刻意不用** .textSelection(.enabled)。2026-08-17 用户报"点了哪个框,
                // 哪个框的文字就被挤到下面一个位置":那个修饰符会让 SwiftUI 在点击时把这段
                // 文字从静态 Text 切到可选中的渲染路径,而两条路径的竖向度量(基线/内边距)
                // 不一致,于是整段往下跳一截。先试过给它配 .frame(maxWidth:.infinity) —— 那
                // 治的是横向重新折行,对这个竖向位移无效(实测无变化)。
                //
                // 想复制这些证据走上面标题栏那个「拷贝」按钮:它一次拷走整份决策,
                // 比拖选一段更实用 —— 这个面板的用途本来就是"贴进 issue 里复盘"。
                Text(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let raw = delta?.clampedRawSum ?? row.core.clampedRawSum {
                Text(clampNote(rawSum: raw, score: c.score))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // 「内容获印证 +250」只说了有几家,这一行说**跟谁**(借鉴清单 V2)。
            // 冠亚军分差中位只有 24 分,而分差小的时候真正要问的是"这两份是不是同一份
            // 词"——是的话选谁都行,不是的话这 24 分就是在两份不同的歌词之间抛硬币。
            if let peers = c.consensusPeers, !peers.isEmpty {
                Text(String(format: L10n.t("跟 %@ 是同一份词"),
                            peers.map { sourceDisplayName($0) }.joined(separator: "、")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 17)
        .padding(.top, 2)
    }

    /// 不参赛的那两类:collector 塞的「纯音乐」信号,和被判不可用的候选。
    ///
    /// 两类**都刻意不显示分数**。存档里它们的 score 恒为 -1,那个 -1 是 collector 用来让
    /// 选词函数跳过这条的**手段**,不是对这份"歌词"的评价 —— 印给用户看只会让人以为
    /// 某个源给了份很烂的词。2026-09-12 用户截图问过「它怎么是空的,并且是 -1?」,当时
    /// 只把纯音乐标记那一支改掉了;被拒这一支还印着红色 -1,而它**常见 4 倍**
    /// (全库 604 行 / 301 个条目,对 148 行纯音乐标记)。
    ///
    /// 也刻意**不删掉整行**:理由见 LyricsDecisionRow 头注 —— 这是证据,不是可采纳的候选。
    /// 「某个源明确说这首是纯音乐」「某个源只有纯文本」恰恰是复盘时最想看到的一句话。
    private func sidelinedRow(_ row: Row, showsCover: Bool) -> some View {
        let c = row.model
        let isInstrumental = row.core.isInstrumentalMarker
        return HStack(alignment: .top, spacing: 7) {
            // 占掉披露箭头那 10pt,让这些行的左边缘跟上面的候选对齐。
            Color.clear.frame(width: 10, height: 1)
            if showsCover {
                // 跟普通候选的占位换个图标:那边的灰音符是"这个源没给封面",这里是"压根
                // 没有这首歌的歌词",两件事不该长得一样。
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: isInstrumental ? "speaker.wave.2" : "text.badge.xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary))
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(sourceDisplayName(c.source))
                        .font(.callout)
                        .foregroundStyle(sourceColor(c.source))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(sourceColor(c.source).opacity(0.12), in: Capsule())
                    if isInstrumental {
                        Label(L10n.t("纯音乐"), systemImage: "music.note.list")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if isInstrumental {
                    Text(L10n.t("这个源明确说这首是纯音乐，所以它没有参与打分"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if row.core.isRejected, let terms = c.scoreTerms, !terms.isEmpty {
                    // explanation 对被拒的候选吐的是「不可用：X」+ 那一项的解释,
                    // 正好是这里要说的话 —— 不用另写一份措辞。
                    // ⚠️ 显式判 isRejected,不靠"走到 else 了就一定是被拒":这一行的措辞
                    // (「不可用：…」)只对被拒的候选成立,哪天 isContender 多出第三类,
                    // 不判的话会给它印一句错的话。
                    Text(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                let matched = matchedText(c)
                if !matched.isEmpty {
                    Text(matched).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.05)))
    }

    /// 分数条 —— 给「945」一个对照。945 分算高还是低,用户没有参照系;跟冠军比多长
    /// 是有参照系的。负分 / 被夹到 1 的候选条长归零,不画成负的。
    private func scoreBar(score: Int, top: Int, tint: Color) -> some View {
        let ratio = top > 0 ? max(0, min(1, Double(score) / Double(top))) : 0
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.18))
            Capsule().fill(tint.opacity(0.7)).frame(width: 62 * ratio)
        }
        .frame(width: 62, height: 5)
    }

    /// 候选封面。用 CachedImage 而不是 AsyncImage:存档里的封面 URL 是**当时**那一刻的,
    /// 隔一段时间失效很正常,而 CachedImage 带失败负缓存(10 分钟内不重试同一个坏 URL)
    /// 和同 URL 并发合流 —— 这个面板一屏就有四五条候选,还可能来回切换存档记录,用
    /// AsyncImage 会对着一堆死链反复发真实请求。
    private func candidateCover(_ raw: String?, size: CGFloat) -> some View {
        CachedImage(url: raw.flatMap(URL.init(string:))) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.caption2)
                        .foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// 判词卡 —— 面板第一眼看到的那块。
///
/// 它回答的是「为什么是它」,而这正是这个面板存在的唯一目的。老版把这个问题的答案
/// 埋在中位 27 行、最长 49 行的打分明细里,要靠肉眼 diff 两段七行文字才看得出来。
private struct VerdictCard: View {
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1))
    }
}
