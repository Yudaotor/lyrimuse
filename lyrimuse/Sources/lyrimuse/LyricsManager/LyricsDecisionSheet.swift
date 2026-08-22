import SwiftUI

// 「解析决策」只读弹窗(2026-08-17,吸收自对 lyra 的对比审阅 C2)——把 collector 在
// **真正做决定那一刻**固化下来的候选表摊开:哪些源应答了、各自得了多少分、为什么被拒、
// 最后为什么是它赢。跟「联网搜索候选歌词」的本质区别:那个是**现在**重新抽一轮签
// (候选集受 20 秒期限影响,跟当初不一定一样),这个是当初那一轮的**存档**,离线、
// 零网络、几个月后照样一字不差。
//
// 刻意只读:这里不提供"改用某条候选"按钮 —— 想换歌词走「联网搜索候选歌词」那条路,
// 它拿的是新鲜正文;决策记录里根本没有正文(collector 侧三条铁律之一,见 decision.go),
// 也就不存在"从存档采纳"这种操作。
struct LyricsDecisionSheet: View {
    let summary: EnrichCacheStore.Summary
    /// 展示页签:「当前歌词的出处」在前、「最近一次评估」在后;同一轮只留一份(见 init)。
    private let records: [(label: String, record: LyricsResolutionDecision)]
    @State private var selectedRecord = 0
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                        metaSection(decision)
                        candidateSection(decision)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
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

    /// 单份决策记录的纯文本行(plainTextDump 按页签逐份拼接)。
    private func dumpLines(_ decision: LyricsResolutionDecision) -> [String] {
        var lines: [String] = []
        var head = [pathLabel(decision)]
        if let applied = decision.applied {
            head.append(applied ? L10n.t("已采用") : L10n.t("评估后维持原状"))
        }
        if let version = decision.scoringVersion { head.append("v\(version)") }
        if let ts = decision.decidedAt, ts > 0 {
            head.append(Date(timeIntervalSince1970: TimeInterval(ts))
                .formatted(date: .abbreviated, time: .shortened))
        }
        lines.append(head.joined(separator: " · "))
        let query = [decision.queryArtist, decision.queryTitle, decision.queryAlbum]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        if !query.isEmpty { lines.append(String(format: L10n.t("查询词：%@"), query)) }
        if let secs = decision.durationSecs, secs > 0 {
            lines.append(String(format: L10n.t("按 %@ 秒的曲目时长校验"), String(format: "%.0f", secs)))
        }
        if let responded = decision.sourcesResponded, !responded.isEmpty {
            lines.append(String(format: L10n.t("本轮应答的源：%@"),
                                responded.map { sourceDisplayName($0) }.joined(separator: "、")))
        }
        for c in decision.candidates ?? [] {
            lines.append("")
            var tag = [sourceDisplayName(c.source), "\(c.score)"]
            if c.source == decision.winner { tag.append(L10n.t("胜者")) }
            if c.hasWordTiming == true { tag.append(L10n.t("逐字")) }
            lines.append(tag.joined(separator: " · "))
            let matched = [c.title, c.artist, c.album]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !matched.isEmpty { lines.append(matched) }
            if let terms = c.scoreTerms, !terms.isEmpty {
                lines.append(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
            }
        }
        return lines
    }

    @ViewBuilder
    private func metaSection(_ decision: LyricsResolutionDecision) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                InfoChip(icon: "clock.arrow.circlepath", text: pathLabel(decision), tint: .blue)
                if let applied = decision.applied {
                    InfoChip(icon: applied ? "checkmark.circle" : "equal.circle",
                             text: applied ? L10n.t("已采用") : L10n.t("评估后维持原状"),
                             tint: applied ? .green : .secondary)
                }
                if let version = decision.scoringVersion {
                    InfoChip(icon: "number", text: "v\(version)", tint: .secondary)
                }
                if let ts = decision.decidedAt, ts > 0 {
                    InfoChip(icon: "calendar",
                             text: Date(timeIntervalSince1970: TimeInterval(ts))
                                 .formatted(date: .abbreviated, time: .shortened),
                             tint: .secondary)
                }
            }
            // 决策的完整输入:发出去的查询词(已转简体,可能跟本地标签不同)和校验曲长。
            let query = [decision.queryArtist, decision.queryTitle, decision.queryAlbum]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
            if !query.isEmpty {
                Text(String(format: L10n.t("查询词：%@"), query))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let secs = decision.durationSecs, secs > 0 {
                Text(String(format: L10n.t("按 %@ 秒的曲目时长校验"), String(format: "%.0f", secs)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let responded = decision.sourcesResponded, !responded.isEmpty {
                // "谁应答了"是排查的第一问 —— 没露面的源(超时/网络)根本不在候选表里,
                // 单看下面那张表会误以为它压根不存在。
                Text(String(format: L10n.t("本轮应答的源：%@"),
                            responded.map { sourceDisplayName($0) }.joined(separator: "、")))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func candidateSection(_ decision: LyricsResolutionDecision) -> some View {
        let candidates = decision.candidates ?? []
        if candidates.isEmpty {
            Text(L10n.t("这一轮没有任何源给出候选"))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(candidates) { c in
                    candidateRow(c, winner: decision.winner)
                }
            }
        }
    }

    private func candidateRow(_ c: LyricsResolutionDecision.Candidate, winner: String?) -> some View {
        let isWinner = c.source == winner
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(sourceDisplayName(c.source))
                    .font(.callout.weight(isWinner ? .semibold : .regular))
                    .foregroundStyle(sourceColor(c.source))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(sourceColor(c.source).opacity(0.12), in: Capsule())
                if isWinner {
                    Label(L10n.t("胜者"), systemImage: "crown.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if c.hasWordTiming == true {
                    Text(L10n.t("逐字")).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text("\(c.score)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(c.score < 0 ? .red : .primary)
            }
            // 这个源匹配到的是哪首/哪个版本 —— 排查"串版本"的关键一行。
            let matched = [c.title, c.artist, c.album]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !matched.isEmpty {
                Text(matched).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                // 想复制这些证据走上面标题栏那个「拷贝」按钮:它一次拷走整份决策(路径/是否
                // 采用/规则版本/查询词/应答的源 + 所有候选的完整明细),比拖选一段更实用 ——
                // 这个面板的用途本来就是"贴进 issue 里复盘"。
                Text(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isWinner ? Color.orange.opacity(0.07) : Color.secondary.opacity(0.05))
        )
    }
}
