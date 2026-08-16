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
    let decision: LyricsResolutionDecision
    @Environment(\.dismiss) private var dismiss

    private var pathLabel: String {
        switch decision.path {
        case "first-resolve": return L10n.t("首次解析")
        case "upgrade": return L10n.t("升级重试")
        case "rescore": return L10n.t("规则换版重选")
        default: return decision.path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    metaSection
                    candidateSection
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
                Text(summary.isManual
                     ? L10n.t("记录的是手动修改之前的最后一次自动评估")
                     : L10n.t("collector 做决定那一刻的存档，与重新搜索的结果可能不同"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.t("完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                InfoChip(icon: "clock.arrow.circlepath", text: pathLabel, tint: .blue)
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
    private var candidateSection: some View {
        let candidates = decision.candidates ?? []
        if candidates.isEmpty {
            Text(L10n.t("这一轮没有任何源给出候选"))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(candidates) { c in
                    candidateRow(c)
                }
            }
        }
    }

    private func candidateRow(_ c: LyricsResolutionDecision.Candidate) -> some View {
        let isWinner = c.source == decision.winner
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
                Text(LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: terms))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
