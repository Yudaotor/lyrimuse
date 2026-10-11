import AppKit
import LyrimuseCore
import SwiftUI

/// 歌词管理详情页「同一首歌的其他写法」(18 章决策 28、38)。左边是这首歌的全部写法,按当前这条 / 共用歌词 / 各自选词 / 已拆开
/// 分组,每条两个圆点:现在的歌词跟当前这条一样吗、以后怎么处理。右边是选中那条跟当前这条的对照:两张结论卡,逐项对照(不一样
/// 的标橙),歌词不一样时多一块逐句对照,认成同一首的依据,拆开 / 恢复合并。拆开、恢复合并都交给引擎(EnrichCacheStore.splitSong /
/// unsplitSong),列表数据见 SongVersions。
struct SongVersionsSheet: View {
    let summary: EnrichCacheStore.Summary
    /// 关掉弹窗、在列表里选中这一条。
    let onOpen: (String) -> Void

    @ObservedObject private var store = EnrichCacheStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [Version] = []
    @State private var edges: [SongVersions.Edge] = []
    @State private var loaded = false
    @State private var selected: String?
    @State private var diffExpanded = true
    @State private var pendingSplit: String?
    @State private var confirmingSplit = false
    @State private var busy = false

    enum Relation: CaseIterable {
        case current, shared, own, split
    }

    struct Version: Identifiable {
        let key: String
        let relation: Relation
        let title: String
        let artist: String
        let album: String
        let players: [String]
        let playersInferred: Bool
        let durationSecs: Double?
        let source: String
        let score: Int?
        let features: [String]
        let lyrics: String
        let yrc: String
        /// 正文读得回来(读不回来时歌词按不知道算,不拿来比)。
        let lyricsKnown: Bool
        /// 现在的歌词(正文加逐字)跟当前这条一字不差。
        let sameLyrics: Bool
        /// 已拆开那条恢复合并时交给引擎的写法。
        let mergeKeys: [String]
        var id: String { key }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if versions.count < 2 {
                Text(L10n.t("没有认成同一首歌的其他写法"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    versionList.frame(width: 270)
                    Divider()
                    ScrollView {
                        detail
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity,
               minHeight: 480, idealHeight: 620, maxHeight: .infinity)
        .background(WindowResizeEnabler(minWidth: 760, minHeight: 480))
        // 拆开、恢复合并之后歌词管理会重读一遍(summariesGeneration 变),跟着重算。
        .task(id: store.summariesGeneration) { await reload() }
        // 要拆的那条经 presenting 交给按钮:关确认框时会先把开关置回去,按钮里再读 @State 可能已经晚了。
        .alert(splitTitle, isPresented: $confirmingSplit, presenting: pendingSplit) { key in
            Button(L10n.t("拆开"), role: .destructive) {
                run { await store.splitSong(keys: [key]) }
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: { _ in
            Text(L10n.t("拆开后它单独算一首歌：播放次数分开，歌词不再跟这首共用；从这首同步过去的歌词会换回它原来那份。之后可以在这里恢复合并。"))
        }
    }

    // MARK: - 标题

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("同一首歌的其他写法")).font(.headline)
                Group {
                    if loaded, versions.count > 1 {
                        let inSong = versions.filter { $0.relation != .split }
                        Text(String(format: L10n.t("%1$d 种写法 · 现在 %2$d 种用同一份歌词 · %3$d 种跟当前这条共用歌词"),
                                    inSong.count, inSong.filter(\.sameLyrics).count, inSong.filter { $0.relation == .shared }.count))
                    } else {
                        Text(L10n.t("这些写法算作同一首歌，播放次数合在一起。认错了就拆开。"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.t("完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(WindowDragHandle())
    }

    // MARK: - 左边:全部写法

    private var selectedKey: String? {
        if let selected, versions.contains(where: { $0.key == selected }) { return selected }
        return versions.first { $0.relation != .current }?.key ?? versions.first?.key
    }

    private var versionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Relation.allCases, id: \.self) { relation in
                    let group = versions.filter { $0.relation == relation }
                    if !group.isEmpty {
                        Text(relation == .current ? L10n.t("当前这条") : Self.relationTitle(relation))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(group) { listRow($0) }
                    }
                }
            }
            .padding(8)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func listRow(_ v: Version) -> some View {
        let isSelected = v.key == selectedKey
        return Button {
            selected = v.key
        } label: {
            HStack(spacing: 8) {
                playerIcon(v.players.first)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(v.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if v.relation == .current { currentTag }
                    }
                    Text([v.artist, v.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if v.relation != .current {
                    HStack(spacing: 4) {
                        Circle().fill(lyricsColor(v)).frame(width: 8, height: 8)
                            .help(lyricsVerdict(v))
                        Circle().fill(Self.relationColor(v.relation)).frame(width: 8, height: 8)
                            .help(Self.relationTitle(v.relation))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.primary.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var currentTag: some View {
        Text(L10n.t("当前"))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
    }

    // MARK: - 右边:跟当前这条对照

    @ViewBuilder
    private var detail: some View {
        if let v = versions.first(where: { $0.key == selectedKey }), let current = versions.first(where: { $0.relation == .current }) {
            if v.relation == .current {
                Text(L10n.t("这是当前这条。点左边别的写法，跟它对照。"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 10) {
                        lyricsCard(v)
                        relationCard(v)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    compareTable(current, v)
                    if v.lyricsKnown, current.lyricsKnown, !v.sameLyrics, !v.lyrics.isEmpty, !current.lyrics.isEmpty {
                        lyricDiffSection(current, v)
                    }
                    if v.relation != .split { evidenceSection(v) }
                    actions(v)
                }
            }
        }
    }

    private func card<Content: View>(_ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func lyricsCard(_ v: Version) -> some View {
        card(L10n.t("现在的歌词跟当前这条")) {
            Label(lyricsVerdict(v), systemImage: !v.lyricsKnown || v.lyrics.isEmpty ? "questionmark" : v.sameLyrics ? "checkmark" : "notequal")
                .font(.title3.weight(.semibold))
                .foregroundStyle(lyricsColor(v))
            Text([sourceText(v), featuresText(v)].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func relationCard(_ v: Version) -> some View {
        card(L10n.t("以后")) {
            Label(Self.relationTitle(v.relation), systemImage: Self.relationSymbol(v.relation))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Self.relationColor(v.relation))
            Text(Self.relationExplanation(v.relation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func compareTable(_ c: Version, _ v: Version) -> some View {
        let rows: [(String, String, String)] = [
            (L10n.t("歌名"), c.title, v.title),
            (L10n.t("歌手"), c.artist, v.artist),
            (L10n.t("专辑"), c.album, v.album),
            (L10n.t("收录于"), playersText(c), playersText(v)),
            (L10n.t("时长"), durationText(c), durationText(v)),
            (L10n.t("歌词来源"), sourceText(c), sourceText(v)),
            (L10n.t("内容"), featuresText(c), featuresText(v)),
        ]
        let differing = rows.filter { $0.1 != $0.2 }.count
        return VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text(L10n.t("当前这条"))
                    Text(L10n.t("这条写法"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let same = row.1 == row.2
                    GridRow {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Text(row.1).foregroundStyle(same ? Color.secondary : Color.primary)
                        Text(row.2)
                            .fontWeight(same ? .regular : .medium)
                            .foregroundStyle(same ? Color.secondary : Color.orange)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            if differing > 0 {
                Text(String(format: L10n.t("%d 项不一样，已标橙"), differing))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func lyricDiffSection(_ c: Version, _ v: Version) -> some View {
        let diff = SongVersions.lyricDiff(current: c.lyrics, other: v.lyrics)
        return DisclosureGroup(isExpanded: $diffExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(diff.rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().opacity(0.5) }
                        HStack(alignment: .top, spacing: 0) {
                            diffCell(row.current, highlight: false)
                            Divider()
                            diffCell(row.other, highlight: row.differs)
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))
                Text(diffSummary(diff, c, v))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            Text(L10n.t("歌词逐句对照")).font(.callout.weight(.semibold))
        }
    }

    private func diffCell(_ line: LyricLine?, highlight: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.map { Self.timestamp($0.timeMs) } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(line?.text ?? "—")
                .font(.callout)
                .foregroundStyle(line == nil ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight ? Color.orange.opacity(0.12) : Color.clear)
    }

    private func diffSummary(_ diff: SongVersions.LyricDiff, _ c: Version, _ v: Version) -> String {
        var parts: [String] = []
        if let shift = diff.shiftMs, abs(shift) >= 100 {
            let seconds = String(format: "%.1f", Double(abs(shift)) / 1000)
            parts.append(String(format: L10n.t(shift > 0 ? "时间整体晚 %@ 秒" : "时间整体早 %@ 秒"), seconds))
        }
        if diff.differentLines > 0 {
            parts.append(String(format: L10n.t("有 %d 句文字不同"), diff.differentLines))
        }
        if !c.yrc.isEmpty, v.yrc.isEmpty {
            parts.append(L10n.t("这条没有逐字时间轴"))
        }
        if parts.isEmpty {
            parts.append(L10n.t("文字和整行时间一样，逐字时间轴不同"))
        }
        return parts.joined(separator: L10n.t("；"))
    }

    private func evidenceSection(_ v: Version) -> some View {
        let direct = edges.filter { ($0.a == summary.key && $0.b == v.key) || ($0.b == summary.key && $0.a == v.key) }
        var seen: Set<String> = []
        let kinds = (SongVersions.evidenceOrder + direct.map(\.kind)).filter { kind in
            direct.contains { $0.kind == kind } && seen.insert(kind).inserted
        }
        let current = versions.first { $0.relation == .current }
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("播放器或曲库直接给的编号最可靠；按歌名搜到的可能搜错，只作参考。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if kinds.isEmpty {
                    Text(L10n.t("经由同一首歌的其他写法连着")).foregroundStyle(.secondary)
                }
                ForEach(kinds, id: \.self) { kind in
                    let countOnly = direct.filter { $0.kind == kind }.allSatisfy(\.countOnly)
                    let strong = SongVersions.strongKinds.contains(kind)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(evidenceSentence(kind, current, v))
                            Text(strong ? L10n.t("可靠") : countOnly ? L10n.t("仅参考") : L10n.t("参考"))
                                .font(.caption)
                                .foregroundStyle(strong ? Color.green : Color.secondary)
                                .padding(.horizontal, 5)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                        }
                        if countOnly {
                            Text(L10n.t("搜到的那首跟这条的歌名对不上号，只用来合并播放次数，不让歌词共用。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(.top, 6)
        } label: {
            Text(L10n.t("为什么认成同一首")).font(.callout)
        }
    }

    /// 一条依据的整句说法;「歌手相同、歌名相同」那条两边时长都知道时写出差几秒。
    private func evidenceSentence(_ kind: String, _ current: Version?, _ v: Version) -> String {
        if kind == "family", let a = current?.durationSecs, let b = v.durationSecs {
            let gap = abs(a - b)
            return String(format: L10n.t("歌手相同、歌名相同，时长只差 %@ 秒"), gap < 0.95 ? String(format: "%.1f", gap) : String(Int(gap.rounded())))
        }
        return Self.evidenceLabel(kind)
    }

    private func actions(_ v: Version) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button(L10n.t("在列表里查看")) {
                dismiss()
                onOpen(v.key)
            }
            .disabled(store.summary(forKey: v.key) == nil)
            if v.relation == .split {
                Button(L10n.t("恢复合并")) { run { await store.unsplitSong(keys: v.mergeKeys) } }
                    .disabled(busy)
            } else {
                Button(L10n.t("拆开…")) {
                    pendingSplit = v.key
                    confirmingSplit = true
                }
                .disabled(busy)
            }
        }
    }

    // MARK: - 文字

    private func lyricsVerdict(_ v: Version) -> String {
        if !v.lyricsKnown { return L10n.t("读不到这条的歌词") }
        if v.lyrics.isEmpty { return L10n.t("这条没有歌词") }
        return v.sameLyrics ? L10n.t("一字不差") : L10n.t("不一样")
    }

    private func lyricsColor(_ v: Version) -> Color {
        if !v.lyricsKnown || v.lyrics.isEmpty { return .secondary }
        return v.sameLyrics ? .green : .orange
    }

    private func sourceText(_ v: Version) -> String {
        guard !v.source.isEmpty else { return "" }
        guard let score = v.score else { return sourceDisplayName(v.source) }
        return String(format: L10n.t("%1$@ · %2$d 分"), sourceDisplayName(v.source), score)
    }

    private func featuresText(_ v: Version) -> String { v.features.joined(separator: " · ") }

    private func durationText(_ v: Version) -> String {
        guard let secs = v.durationSecs else { return L10n.t("播放器没报") }
        let total = Int(secs.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func playerName(_ bundleID: String) -> String {
        PlaybackPlayer.builtin(forBundleID: bundleID)?.displayName
            ?? FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
    }

    private func playersText(_ v: Version) -> String {
        guard !v.players.isEmpty else { return L10n.t("未记录") }
        let names = v.players.map(playerName).joined(separator: " · ")
        return v.playersInferred ? String(format: L10n.t("%@（推断）"), names) : names
    }

    @ViewBuilder
    private func playerIcon(_ bundleID: String?) -> some View {
        if let bundleID, let image = AppIconResolver.icon(forBundleID: bundleID)
            ?? PlaybackPlayer.builtin(forBundleID: bundleID)?.bundledIconResourceName.flatMap(AppIconResolver.icon(bundledResourceName:)) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.35))
                .overlay(Image(systemName: "questionmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
        }
    }

    private var splitTitle: String {
        guard let key = pendingSplit else { return "" }
        let title = versions.first { $0.key == key }?.title ?? key
        return String(format: L10n.t("把「%@」拆出去？"), title)
    }

    static func relationTitle(_ relation: Relation) -> String {
        switch relation {
        case .current: return L10n.t("当前这条")
        case .shared: return L10n.t("共用歌词")
        case .own: return L10n.t("各自选词")
        case .split: return L10n.t("已拆开")
        }
    }

    static func relationSymbol(_ relation: Relation) -> String {
        switch relation {
        case .current: return "circle"
        case .shared: return "arrow.left.arrow.right"
        case .own: return "arrow.triangle.branch"
        case .split: return "scissors"
        }
    }

    static func relationColor(_ relation: Relation) -> Color {
        switch relation {
        case .current: return .accentColor
        case .shared: return .accentColor
        case .own: return Color.secondary.opacity(0.6)
        case .split: return .purple
        }
    }

    static func relationExplanation(_ relation: Relation) -> String {
        switch relation {
        case .current: return ""
        case .shared: return L10n.t("自动选的歌词跟当前这条共用一份，换词时一起换，手改也一起同步。")
        case .own: return L10n.t("以后自动选词各选各的，不跟当前这条一起换；你在这首歌上的手改仍会同步过去。")
        case .split: return L10n.t("你把它从这首歌里拆了出去：单独算一首歌，播放次数分开，歌词不再相关。认错了可以恢复合并。")
        }
    }

    static func timestamp(_ ms: Int) -> String {
        let total = max(ms, 0)
        return String(format: "%02d:%02d.%02d", total / 60_000, total / 1000 % 60, total % 1000 / 10)
    }

    // MARK: - 读数据

    private func run(_ action: @escaping () async -> Bool) {
        busy = true
        Task {
            _ = await action()
            busy = false
            await reload()
        }
    }

    /// 写法 → 实体与共享组取自播放那一侧的读取(EnrichCacheReader,整份在内存里),涉及的几条再用歌词管理刚重读的快照
    /// 校正一遍:拆开之后播放那一侧要等下一拍才读到。证据、拆开记录在后台读文件;各条的正文按需从小文件补,只补这首歌的几条。
    private func reload() async {
        let key = summary.key
        let (edges, splits) = await Task.detached(priority: .userInitiated) {
            let edges = FileIO.read(SongVersions.tableURL).map { SongVersions.edges(tableData: $0, key: key) } ?? []
            let splits = FileIO.read(SongVersions.userURL).map(SongVersions.splits(userData:)) ?? []
            return (edges, splits)
        }.value
        var memberships = EnrichCacheReader.songMemberships()
        func refresh(_ keys: [String]) {
            for k in keys {
                memberships[k] = store.songMembership(forKey: k)
            }
        }
        refresh([key])
        if let first = SongVersions.listing(key: key, memberships: memberships, edges: edges, splits: splits) {
            refresh(first.rows.map(\.key) + first.splits.flatMap(\.mergeKeys))
        }
        let listing = SongVersions.listing(key: key, memberships: memberships, edges: edges, splits: splits)
        var out: [Version] = []
        if let current = makeVersion(key, .current, mergeKeys: [], against: nil) {
            out.append(current)
            for row in listing?.rows ?? [] {
                if let v = makeVersion(row.key, row.sharesLyrics ? .shared : .own, mergeKeys: [], against: current) { out.append(v) }
            }
            for split in listing?.splits ?? [] {
                if let v = makeVersion(split.key, .split, mergeKeys: split.mergeKeys, against: current) { out.append(v) }
            }
        }
        self.edges = edges
        versions = out
        loaded = true
    }

    private func makeVersion(_ key: String, _ relation: Relation, mergeKeys: [String], against current: Version?) -> Version? {
        guard let s = store.summary(forKey: key), let facts = store.versionFacts(forKey: key) else { return nil }
        var features: [String] = []
        if s.hasLyrics {
            features.append(s.hasWordTiming ? L10n.t("逐字") : L10n.t("整行"))
        } else {
            features.append(s.hasPlainTextFallback ? L10n.t("纯文本") : L10n.t("无歌词"))
        }
        if s.hasTranslation { features.append(L10n.t("译文")) }
        if s.hasRomanization { features.append(L10n.t("读音")) }
        let same: Bool
        if let current {
            same = facts.complete && current.lyricsKnown && !facts.lyrics.isEmpty
                && facts.lyrics == current.lyrics && facts.yrc == current.yrc
        } else {
            same = true
        }
        return Version(key: key, relation: relation, title: s.shownTitle, artist: s.shownArtist, album: s.displayAlbum,
                       players: facts.players, playersInferred: facts.playersInferred, durationSecs: facts.durationSecs,
                       source: s.lyricsSource, score: facts.score, features: features,
                       lyrics: facts.lyrics, yrc: facts.yrc, lyricsKnown: facts.complete, sameLyrics: same, mergeKeys: mergeKeys)
    }

    static func evidenceLabel(_ kind: String) -> String {
        switch kind {
        case "isrc": return L10n.t("两条的录音编号（ISRC）相同")
        case "mb_recording": return L10n.t("两条在 MusicBrainz 上是同一个录音")
        case "spotify_track": return L10n.t("Spotify 给的曲目编号相同")
        case "amazon_asin": return L10n.t("Amazon Music 给的曲目编号相同")
        case "kkbox_song": return L10n.t("KKBOX 给的歌曲编号相同")
        case "soda_track": return L10n.t("汽水音乐给的歌曲编号相同")
        case "youtube_video": return L10n.t("YouTube Music 给的视频编号相同")
        case "apple_song": return L10n.t("两条的歌名在 Apple Music 上搜到同一首歌")
        case "netease_song": return L10n.t("两条的歌名在网易云音乐上搜到同一首歌")
        case "qq_song": return L10n.t("两条的歌名在 QQ 音乐上搜到同一首歌")
        case "family": return L10n.t("歌手相同、歌名相同、时长相近")
        case "lyrics": return L10n.t("两条各自找到的歌词一致")
        case "apple_name": return L10n.t("Apple Music 登记的名字跟这条对得上")
        case "netease_name": return L10n.t("网易云音乐登记的名字跟这条对得上")
        default: return kind
        }
    }
}
