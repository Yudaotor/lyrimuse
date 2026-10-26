import AppKit
import LyrimuseCore
import SwiftUI

/// 歌词管理详情页「同曲条目」(18 章决策 28、38、44)。左边是这首歌的全部写法,按当前条目 / 歌词同步 / 独立匹配 / 已拆分
/// 分组,每条两个圆点:现在的歌词跟当前这条一样吗、以后怎么处理。右边是选中那条跟当前这条的对照:两张结论卡,逐项对照(不一样
/// 的标红),歌词不是完全一致时多一块逐行对比,认成同一首的依据,拆开 / 恢复合并;选中当前这条时是这首歌的概况(18 章决策 43、61)。拆开、恢复合并都交给引擎(EnrichCacheStore.splitSong /
/// unsplitSong),列表数据见 SongVersions。
struct SongVersionsSheet: View {
    let summary: EnrichCacheStore.Summary
    /// 关掉弹窗、在列表里选中这一条。
    let onOpen: (String) -> Void
    /// 打开就展开概况里的「匹配依据」(深链带 `evidence=1`)。开着时链接换了一首也照样展开。
    var showEvidence = false
    /// 打开就选中这一条写法、显示它跟当前条目的对照(深链带 `compare=<写法键>`);不在这首歌里时照常选。
    var compareKey: String?

    @ObservedObject private var store = EnrichCacheStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [Version] = []
    @State private var edges: [SongVersions.Edge] = []
    @State private var loaded = false
    @State private var selected: String?
    @State private var diffExpanded = true
    @State private var evidenceExpanded = false
    @State private var pairEvidenceExpanded = false
    @State private var pendingSplit: String?
    @State private var confirmingSplit = false
    @State private var busy = false
    /// 第几次重读。重读里有 await,开着面板时换了一首(深链)或拆分 / 合并之后又重读,慢的那次后回来不能盖掉新的。
    @State private var reloadGeneration = 0
    /// 左边那列的宽度(存下来的那份;面板窄时实际画多宽见 `SongVersionsListWidth.shown`)。
    @State private var listWidth: Double = SongVersionsSheet.storedListWidth
    @State private var listDragStart: Double?

    private static let listWidthKey = "np:songVersionsListWidth"

    private static var storedListWidth: Double {
        let value = UserDefaults.standard.double(forKey: listWidthKey)
        return value > 0 ? SongVersionsListWidth.clamped(value) : SongVersionsListWidth.standard
    }

    /// 面板最窄多宽:左边那列加右边对照的下限,不小于 760。左列拖宽时面板跟着撑开,不用先去拖面板边。
    private var minPanelWidth: CGFloat {
        max(760, CGFloat(SongVersionsListWidth.clamped(listWidth) + SongVersionsListWidth.detailMinimum))
    }

    private func persistListWidth() {
        UserDefaults.standard.set(listWidth, forKey: Self.listWidthKey)
    }

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
        /// 歌词窗口里显示的行(SongVersions.displayed:不含抬头、署名、演唱者标注):整行一份、逐字一份。比对、判一致都只看它们。
        let shown: SongVersions.Shown
        /// 正文读得回来(读不回来时歌词按不知道算,不拿来比)。
        let lyricsKnown: Bool
        /// 跟当前条目的歌词比;当前条目自己没有。
        let comparison: SongVersions.LyricComparison?
        /// 已拆开那条恢复合并时交给引擎的写法。
        let mergeKeys: [String]
        /// 各播放器原样报的写法(跟写法键不一样时才有)。
        let reported: [SongVersions.ReportedName]
        var id: String { key }
        /// 跟当前条目比的结论;当前条目自己算完全一致。
        var match: SongVersions.LyricsMatch { comparison?.match ?? .identical }
        /// 本机没放过这条写法:没记下播放器,也没有播放器报的时长。待播队列里提前解析、同专辑预取建的条目是这样,
        /// 引擎只在真放到这条时才记这两样。
        var neverPlayed: Bool { players.isEmpty && durationSecs == nil }
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
                Text(L10n.t("暂无同曲条目"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let shownListWidth = CGFloat(SongVersionsListWidth.shown(stored: listWidth,
                                                                             panelWidth: Double(geometry.size.width)))
                    HStack(spacing: 0) {
                        versionList
                            .frame(width: shownListWidth)
                            // 拖柄同歌词管理侧栏那一条:拖动改宽度,双击回默认,松手记下。
                            .overlay(alignment: .trailing) {
                                LyricsManagerSidebarHandle(
                                    onDrag: { dx in
                                        if listDragStart == nil { listDragStart = Double(shownListWidth) }
                                        guard let start = listDragStart else { return }
                                        listWidth = SongVersionsListWidth.clamped(start + Double(dx))
                                    },
                                    onDragEnd: {
                                        listDragStart = nil
                                        persistListWidth()
                                    },
                                    onDoubleClick: {
                                        listWidth = SongVersionsListWidth.standard
                                        persistListWidth()
                                    })
                                .offset(x: 6)
                            }
                            .zIndex(1)
                        Divider()
                        ScrollView {
                            detail
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                        }
                    }
                }
            }
        }
        .frame(minWidth: minPanelWidth, idealWidth: 900, maxWidth: .infinity,
               minHeight: 480, idealHeight: 620, maxHeight: .infinity)
        .background(WindowResizeEnabler(minWidth: minPanelWidth, minHeight: 480))
        // 拆开、恢复合并之后歌词管理会重读一遍(summariesGeneration 变),跟着重算;开着时链接换了一首(summary 变)也重算。
        .task(id: "\(summary.key)#\(store.summariesGeneration)") { await reload() }
        .onChange(of: "\(summary.key)#\(showEvidence)", initial: true) { _, _ in if showEvidence { evidenceExpanded = true } }
        .onChange(of: "\(summary.key)#\(compareKey ?? "")", initial: true) { _, _ in if let compareKey { selected = compareKey } }
        // 要拆的那条经 presenting 交给按钮:关确认框时会先把开关置回去,按钮里再读 @State 可能已经晚了。
        .alert(splitTitle, isPresented: $confirmingSplit, presenting: pendingSplit) { key in
            Button(L10n.t("拆分"), role: .destructive) {
                run { await store.splitSong(keys: [key]) }
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: { _ in
            Text(L10n.t("拆分后，该条目将作为独立歌曲：播放次数单独统计，不再同步歌词；此前同步过去的歌词将恢复为原有版本。之后可在此恢复合并"))
        }
    }

    // MARK: - 标题

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("同曲条目")).font(.headline)
                Group {
                    if loaded, versions.count > 1 {
                        let inSong = versions.filter { $0.relation != .split }.count
                        Text(String(format: L10n.plural("%d 个条目已识别为同一首歌，播放次数合并统计", count: inSong), inSong))
                    } else {
                        Text(L10n.t("以下条目已识别为同一首歌，播放次数合并统计；如有误识别，可将其拆分"))
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
        // 打开时默认选正在放的那一条(它在这首歌里时),不然选当前条目(概况)。
        if let playing = Self.nowPlayingKey, versions.contains(where: { $0.key == playing }) { return playing }
        return versions.first { $0.relation == .current }?.key ?? versions.first?.key
    }

    /// 正在放的那首的写法键(播放器报的歌手 / 歌名 / 专辑归一化后);没在放时为 nil。
    static var nowPlayingKey: String? {
        let playback = PlaybackCoordinator.shared
        guard playback.resolvedPlayerBundleID != nil, !playback.title.isEmpty else { return nil }
        return EnrichCacheReader.resolvedKey(artist: playback.artist, title: playback.title, album: playback.album)
            ?? EnrichCacheKeys.normalizedKey(artist: playback.artist, title: playback.title, album: playback.album)
    }

    private var versionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Relation.allCases, id: \.self) { relation in
                    let group = versions.filter { $0.relation == relation }
                    if !group.isEmpty {
                        Text(relation == .current ? L10n.t("当前条目") : Self.relationTitle(relation))
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
                playerIcons(v, size: 22)
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
                        statusDot(lyricsSymbol(v), lyricsColor(v), size: 11, label: lyricsVerdict(v))
                        statusDot(Self.relationDotSymbol(v.relation), Self.relationColor(v.relation), size: 11,
                                  label: Self.relationTitle(v.relation))
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
        .buttonStyle(.glassListRow)
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
                overview(current)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 10) {
                        lyricsCard(v)
                        relationCard(v)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    compareTable(current, v)
                    if v.lyricsKnown, current.lyricsKnown, v.match != .identical, !v.lyrics.isEmpty, !current.lyrics.isEmpty {
                        lyricDiffSection(current, v)
                    }
                    if v.relation != .split { evidenceSection(v) }
                    actions(v)
                }
            }
        }
    }

    // MARK: - 右边:选中当前这条时,这首歌的概况

    private func overview(_ c: Version) -> some View {
        let others = versions.filter { $0.relation != .current }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                overviewCard(L10n.t("歌词一致性"), lyricsOverview(c, others.filter { $0.relation != .split }))
                overviewCard(L10n.t("同步策略"), syncOverview(others))
            }
            .fixedSize(horizontal: false, vertical: true)
            factsTable(c)
            allVersionsTable(c)
            if !edges.isEmpty { evidenceSummary }
            Text(L10n.t("选择左侧或表格中的其他条目，可与当前条目逐项对比"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 概况卡上的一个结论:大字说这首歌整体怎样,小字说是其他几个条目、各几个。
    private struct Verdict {
        let title: String
        let symbol: String
        let color: Color
        var detail = ""
    }

    /// 跟对照页那两张卡同名、同图标、同配色,只是说的是其他全部条目。
    private func overviewCard(_ caption: String, _ verdict: Verdict) -> some View {
        card(caption) {
            Label(verdict.title, systemImage: verdict.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(verdict.color)
                .fixedSize(horizontal: false, vertical: true)
            if !verdict.detail.isEmpty {
                Text(verdict.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 其他条目(已拆分的不算)的歌词跟当前条目比:有差异的先说,其次是比不了的(没有歌词、正文读不回来),全都完全一致或文字
    /// 一致才是全部一致。
    private func lyricsOverview(_ c: Version, _ inSong: [Version]) -> Verdict {
        if !c.lyricsKnown { return Verdict(title: L10n.t("歌词无法读取"), symbol: "questionmark", color: .secondary) }
        if c.lyrics.isEmpty { return Verdict(title: L10n.t("当前条目无歌词"), symbol: "questionmark", color: .secondary) }
        if inSong.isEmpty { return Verdict(title: L10n.t("仅当前条目"), symbol: "questionmark", color: .secondary) }
        let compared = inSong.filter { $0.lyricsKnown && !$0.lyrics.isEmpty }
        let identical = compared.filter { $0.match == .identical }.count
        let sameText = compared.filter { $0.match == .sameText }.count
        let same = identical + sameText
        let differ = compared.count - same
        let empty = inSong.filter { $0.lyricsKnown && $0.lyrics.isEmpty }.count
        let unreadable = inSong.count - compared.count - empty
        if same == inSong.count {
            let detail = sameText == 0
                ? String(format: L10n.plural("其他 %d 个条目的歌词与当前条目完全一致", count: identical), identical)
                : identical == 0
                ? String(format: L10n.plural("其他 %d 个条目的歌词与当前条目文字一致", count: sameText), sameText)
                : [String(format: L10n.t("%d 个完全一致"), identical), String(format: L10n.t("%d 个文字一致"), sameText)]
                .joined(separator: " · ")
            return Verdict(title: L10n.t("全部一致"), symbol: "checkmark", color: .green, detail: detail)
        }
        if differ == inSong.count {
            return Verdict(title: String(format: L10n.plural("%d 个条目存在差异", count: differ), differ),
                           symbol: "notequal", color: .red,
                           detail: String(format: L10n.plural("其他 %d 个条目的歌词与当前条目不同，选择后可逐行对比", count: differ), differ))
        }
        var parts: [String] = []
        if identical > 0 { parts.append(String(format: L10n.t("%d 个完全一致"), identical)) }
        if sameText > 0 { parts.append(String(format: L10n.t("%d 个文字一致"), sameText)) }
        if differ > 0 { parts.append(String(format: L10n.t("%d 个存在差异"), differ)) }
        if empty > 0 { parts.append(String(format: L10n.t("%d 个无歌词"), empty)) }
        if unreadable > 0 { parts.append(String(format: L10n.t("%d 个无法读取"), unreadable)) }
        let detail = parts.joined(separator: " · ")
        if differ > 0 {
            return Verdict(title: String(format: L10n.plural("%d 个条目存在差异", count: differ), differ),
                           symbol: "notequal", color: .red, detail: detail)
        }
        return Verdict(title: String(format: L10n.plural("%d 个条目无法比较", count: empty + unreadable), empty + unreadable),
                       symbol: "questionmark", color: .secondary, detail: detail)
    }

    /// 其他条目以后跟不跟着当前条目换歌词:全都跟才是全部同步,有不跟的就数不跟的几个(跟歌词那张卡数差异的一样)。
    /// 全都拆分了只剩已拆分;设置里关了「同曲条目共用歌词」时谁都不跟,先说这个。
    private func syncOverview(_ others: [Version]) -> Verdict {
        let shared = others.filter { $0.relation == .shared }.count
        let own = others.filter { $0.relation == .own }.count
        let split = others.filter { $0.relation == .split }.count
        if shared + own == 0 {
            return Verdict(title: Self.relationTitle(.split), symbol: Self.relationSymbol(.split), color: Self.relationColor(.split),
                           detail: String(format: L10n.t("%d 个已拆分"), split))
        }
        if !EnrichCacheReader.sharesEntityLyrics {
            return Verdict(title: L10n.t("同步已关闭"), symbol: Self.relationSymbol(.own), color: .secondary,
                           detail: L10n.t("已在设置中关闭「同曲条目共用歌词」，各条目分别匹配歌词"))
        }
        let relation: Relation = own == 0 ? .shared : .own
        let title = own == 0 ? L10n.t("全部同步")
            : shared == 0 ? L10n.t("均为独立匹配")
            : String(format: L10n.plural("%d 个条目独立匹配", count: own), own)
        let detail: String
        if split == 0, own == 0 {
            detail = String(format: L10n.plural("更换或手动修改歌词时，其他 %d 个条目一并更新", count: shared), shared)
        } else if split == 0, shared == 0 {
            detail = String(format: L10n.plural("其他 %d 个条目各自匹配歌词，不随当前条目更新", count: own), own)
        } else {
            var parts: [String] = []
            if shared > 0 { parts.append(String(format: L10n.t("%d 个歌词同步"), shared)) }
            if own > 0 { parts.append(String(format: L10n.t("%d 个独立匹配"), own)) }
            if split > 0 { parts.append(String(format: L10n.t("%d 个已拆分"), split)) }
            detail = parts.joined(separator: " · ")
        }
        return Verdict(title: title, symbol: Self.relationSymbol(relation), color: Self.relationColor(relation), detail: detail)
    }

    private func factsTable(_ c: Version) -> some View {
        let rows: [(String, String)] = [
            (L10n.t("曲名"), c.title),
            (L10n.t("艺人"), c.artist),
            (L10n.t("专辑"), c.album),
        ] + (c.reported.isEmpty ? [] : [(L10n.t("原始写法"), reportedText(c))]) + [
            (L10n.t("播放来源"), playersText(c)),
            (L10n.t("时长"), durationText(c)),
            (L10n.t("歌词来源"), sourceText(c)),
            (L10n.t("歌词格式"), featuresText(c)),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("当前条目")).font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Text(row.1.isEmpty ? "—" : row.1)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }

    /// 全部写法一行一条:播放器、名字、时长、歌词来源、现在的歌词跟当前这条、以后。点一行切到它的对照。
    private func allVersionsTable(_ c: Version) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("全部条目")).font(.callout.weight(.semibold))
            HStack(spacing: 10) {
                Text(L10n.t("条目")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.t("时长")).frame(width: Self.durationColumn, alignment: .leading)
                Text(L10n.t("歌词来源")).frame(width: Self.sourceColumn, alignment: .leading)
                Text(L10n.t("歌词一致性")).frame(width: Self.lyricsColumn, alignment: .leading)
                Text(L10n.t("同步策略")).frame(width: Self.relationColumn, alignment: .leading)
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            VStack(spacing: 0) {
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, v in
                    if index > 0 { Divider().opacity(0.5) }
                    overviewRow(v)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))
        }
    }

    /// 一览表各列的宽度。弹窗最窄时(760)右边约 450 点,名字那列要留够两行字。
    static let durationColumn: CGFloat = 40
    static let sourceColumn: CGFloat = 92
    static let lyricsColumn: CGFloat = 70
    static let relationColumn: CGFloat = 62

    private func overviewRow(_ v: Version) -> some View {
        let isCurrent = v.relation == .current
        return Button {
            selected = v.key
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    playerIcons(v, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.title).lineLimit(1)
                        Text([v.artist, v.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(v.durationSecs == nil ? "—" : durationText(v))
                    .monospacedDigit()
                    .help(v.durationSecs == nil ? L10n.t("未提供") : "")
                    .frame(width: Self.durationColumn, alignment: .leading)
                Text(v.source.isEmpty ? "—" : sourceDisplayName(v.source))
                    .help(sourceText(v))
                    .frame(width: Self.sourceColumn, alignment: .leading)
                HStack(spacing: 4) {
                    if !isCurrent { statusDot(lyricsSymbol(v), lyricsColor(v), size: 10, label: nil) }
                    Text(isCurrent ? "—" : lyricsVerdict(v))
                }
                .frame(width: Self.lyricsColumn, alignment: .leading)
                Text(isCurrent ? L10n.t("当前条目") : Self.relationTitle(v.relation))
                    .foregroundStyle(Self.relationColor(v.relation))
                    .frame(width: Self.relationColumn, alignment: .leading)
            }
            .lineLimit(1)
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isCurrent ? Color.accentColor.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glassListRow)
        .allowsHitTesting(!isCurrent)
        .help(isCurrent ? "" : L10n.t("与当前条目对比"))
    }

    /// 这首歌里全部证据按种类数:几对写法靠它连着,强弱跟对照页那块同一个口径。
    private var evidenceSummary: some View {
        var seen: Set<String> = []
        let kinds = (SongVersions.evidenceOrder + edges.map(\.kind)).filter { kind in
            seen.insert(kind).inserted && edges.contains { $0.kind == kind }
        }
        return DisclosureGroup(isExpanded: $evidenceExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("播放器或曲库提供的标识符可信度最高；按曲名检索得到的结果可能有误，仅供参考"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(kinds, id: \.self) { kind in
                    let ofKind = edges.filter { $0.kind == kind }
                    let countOnly = ofKind.allSatisfy(\.countOnly)
                    let strong = SongVersions.strongKinds.contains(kind)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.evidenceLabel(kind))
                        Text("×\(ofKind.count)").monospacedDigit().foregroundStyle(.secondary)
                        Text(strong ? L10n.t("高可信") : countOnly ? L10n.t("仅计数") : L10n.t("参考"))
                            .font(.caption)
                            .foregroundStyle(strong ? Color.green : Color.secondary)
                            .padding(.horizontal, 5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                    }
                }
            }
            .font(.callout)
            .padding(.top, 6)
        } label: {
            disclosureLabel(L10n.t("匹配依据"), font: .callout, isExpanded: $evidenceExpanded)
        }
    }

    private func card<Content: View>(_ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .settingsCardBackground(cornerRadius: 12, inSheet: true)
    }

    private func lyricsCard(_ v: Version) -> some View {
        card(L10n.t("歌词一致性")) {
            Label(lyricsVerdict(v), systemImage: lyricsCardSymbol(v))
                .font(.title3.weight(.semibold))
                .foregroundStyle(lyricsColor(v))
            Text([sourceText(v), featuresText(v)].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func relationCard(_ v: Version) -> some View {
        card(L10n.t("同步策略")) {
            Label(Self.relationTitle(v.relation), systemImage: Self.relationSymbol(v.relation))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Self.relationColor(v.relation))
            Text(Self.relationExplanation(v.relation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 逐项对照的一行。不一样才标红、算进「存在差异」:原始写法本来就各不相同,不比;一边缺这一项(没专辑、没记播放器、
    /// 没报时长、没歌词来源)时缺的那边用最淡的字,也不算不一样。
    private struct CompareRow {
        let label: String
        let current: String
        let other: String
        var compared = true
        var currentMissing = false
        var otherMissing = false

        var differs: Bool { compared && !currentMissing && !otherMissing && current != other }
    }

    private func compareTable(_ c: Version, _ v: Version) -> some View {
        var rows = [
            CompareRow(label: L10n.t("曲名"), current: c.title, other: v.title),
            CompareRow(label: L10n.t("艺人"), current: c.artist, other: v.artist),
            CompareRow(label: L10n.t("专辑"), current: c.album, other: v.album,
                       currentMissing: c.album.isEmpty, otherMissing: v.album.isEmpty),
            CompareRow(label: L10n.t("播放来源"), current: playersText(c), other: playersText(v),
                       currentMissing: c.players.isEmpty, otherMissing: v.players.isEmpty),
            CompareRow(label: L10n.t("时长"), current: durationText(c), other: durationText(v),
                       currentMissing: c.durationSecs == nil, otherMissing: v.durationSecs == nil),
            CompareRow(label: L10n.t("歌词来源"), current: sourceText(c), other: sourceText(v),
                       currentMissing: c.source.isEmpty, otherMissing: v.source.isEmpty),
            CompareRow(label: L10n.t("歌词格式"), current: featuresText(c), other: featuresText(v)),
        ]
        // 原始写法放在专辑后面。
        if !c.reported.isEmpty || !v.reported.isEmpty {
            rows.insert(CompareRow(label: L10n.t("原始写法"), current: reportedText(c), other: reportedText(v), compared: false), at: 3)
        }
        let differing = rows.filter(\.differs).count
        return VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text(L10n.t("当前条目"))
                    Text(L10n.t("所选条目"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                        compareValue(row.current, missing: row.currentMissing, color: row.differs ? .primary : .secondary)
                        compareValue(row.other, missing: row.otherMissing, color: row.differs ? .red : .secondary)
                            .fontWeight(row.differs ? .medium : .regular)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            if differing > 0 {
                Text(String(format: L10n.t("%d 项存在差异（以红色标示）"), differing))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 逐行对比:按块排(`SongVersions.compareLyrics`),左边当前条目、右边所选条目各是这一块的几句;所选条目这一块有字对不上、
    /// 或者只有一边有时右边整格标红,对不上的字两边都标红;块开头那句时间差超过 0.5 秒时右边那个时间标红。
    /// 逐项对照的一格:缺的用最淡的字,空的写一道短横。
    private func compareValue(_ text: String, missing: Bool, color: Color) -> some View {
        Text(text.isEmpty ? "—" : text)
            .foregroundStyle(missing ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(color))
    }

    private func lyricDiffSection(_ c: Version, _ v: Version) -> some View {
        let blocks = v.comparison?.blocks ?? []
        return DisclosureGroup(isExpanded: $diffExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        if index > 0 { Divider().opacity(0.5) }
                        HStack(alignment: .top, spacing: 0) {
                            diffCell(block.current, marks: block.currentMarks, highlight: false, retimed: false)
                            Divider()
                            diffCell(block.other, marks: block.otherMarks, highlight: block.differs, retimed: block.deltaMs != nil)
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))
                Text(diffSummary(c, v))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            disclosureLabel(L10n.t("逐行歌词对比"), font: .callout.weight(.semibold), isExpanded: $diffExpanded)
        }
    }

    /// 折叠区的标题:点文字也能展开 / 收起。macOS 的 DisclosureGroup 默认只认左边的箭头,标题要自己接点击,占满整行好点。
    private func disclosureLabel(_ title: String, font: Font, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
        } label: {
            Text(title)
                .font(font)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glassListRow)
    }

    /// 对比表的一格:这一块里这一边的几句,一句一行带时间;一句都没有时一道短横。
    private func diffCell(_ lines: [LyricLine], marks: [Set<Int>], highlight: Bool, retimed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty { diffLine(nil, marks: [], retimed: false) }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                diffLine(line, marks: index < marks.count ? marks[index] : [], retimed: retimed && index == 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight ? Color.red.opacity(0.12) : Color.clear)
    }

    private func diffLine(_ line: LyricLine?, marks: Set<Int>, retimed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.map { Self.timestamp($0.timeMs) } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(retimed ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                .frame(width: 56, alignment: .leading)
            Text(line.map { Self.marked($0.text, marks: marks) } ?? AttributedString("—"))
                .font(.callout)
                .foregroundStyle(line == nil ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 对不上的字(按 `Character` 下标)标红,其余用调用方的颜色。
    static func marked(_ text: String, marks: Set<Int>) -> AttributedString {
        var out = AttributedString()
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if marks.contains(offset) { piece.foregroundColor = .red }
            out += piece
        }
        return out
    }

    /// 对比表下面一句:先说词的差别(改了字、多几句、少几句),再说时间,最后说只是写法不同的(分行、繁简)。这些都没有时
    /// 说差在哪:标点空格这类写法、行时间的小出入,或者只有逐字时间轴。
    private func diffSummary(_ c: Version, _ v: Version) -> String {
        guard let comparison = v.comparison else { return "" }
        let s = comparison.summary
        var parts: [String] = []
        if s.changed > 0 { parts.append(String(format: L10n.plural("%@ 处文字不同", count: s.changed), "\(s.changed)")) }
        if comparison.extraLines > 0 {
            parts.append(String(format: L10n.plural("多 %@ 句", count: comparison.extraLines), "\(comparison.extraLines)"))
        }
        if comparison.missingLines > 0 {
            parts.append(String(format: L10n.plural("少 %@ 句", count: comparison.missingLines), "\(comparison.missingLines)"))
        }
        if s.retimed > 0 {
            parts.append(String(format: L10n.plural("%@ 处时间相差超过 0.5 秒", count: s.retimed), "\(s.retimed)"))
        }
        if let shift = comparison.shiftMs, abs(shift) >= 100 {
            let seconds = String(format: "%.1f", Double(abs(shift)) / 1000)
            parts.append(String(format: L10n.t(shift > 0 ? "整体延后 %@ 秒" : "整体提前 %@ 秒"), seconds))
        }
        if s.resegmented > 0 { parts.append(L10n.t("分行不同")) }
        if s.scriptVariants > 0 { parts.append(L10n.t("繁简写法不同")) }
        if !c.shown.words.isEmpty, v.shown.words.isEmpty { parts.append(L10n.t("所选条目无逐字时间轴")) }
        if parts.isEmpty {
            let a = c.shown.text, b = v.shown.text
            parts.append(a.map(\.text) != b.map(\.text) ? L10n.t("标点、空格写法不同")
                : a.map(\.timeMs) != b.map(\.timeMs) ? L10n.t("行时间略有出入")
                : L10n.t("文本与行时间一致，仅逐字时间轴不同"))
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
        return DisclosureGroup(isExpanded: $pairEvidenceExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("播放器或曲库提供的标识符可信度最高；按曲名检索得到的结果可能有误，仅供参考"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if kinds.isEmpty {
                    Text(L10n.t("经由其他同曲条目间接关联")).foregroundStyle(.secondary)
                }
                ForEach(kinds, id: \.self) { kind in
                    let countOnly = direct.filter { $0.kind == kind }.allSatisfy(\.countOnly)
                    let strong = SongVersions.strongKinds.contains(kind)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(evidenceSentence(kind, current, v))
                            Text(strong ? L10n.t("高可信") : countOnly ? L10n.t("仅计数") : L10n.t("参考"))
                                .font(.caption)
                                .foregroundStyle(strong ? Color.green : Color.secondary)
                                .padding(.horizontal, 5)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                        }
                        if countOnly {
                            Text(L10n.t("检索到的曲目与本条目曲名不符，仅用于合并播放次数，不参与歌词同步"))
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
            disclosureLabel(L10n.t("匹配依据"), font: .callout, isExpanded: $pairEvidenceExpanded)
        }
    }

    /// 一条依据的整句说法;「歌手相同、歌名相同」「除括号里的说明外歌名相同」两条两边时长都知道时写出差几秒。
    private func evidenceSentence(_ kind: String, _ current: Version?, _ v: Version) -> String {
        if kind == "family" || kind == "bare_title", let a = current?.durationSecs, let b = v.durationSecs {
            let gap = abs(a - b)
            let seconds = gap < 0.95 ? String(format: "%.1f", gap) : String(Int(gap.rounded()))
            return String(format: kind == "family" ? L10n.t("艺人、曲名一致，时长相差 %@ 秒")
                : L10n.t("艺人一致，曲名除括号内说明外一致，时长相差 %@ 秒"), seconds)
        }
        return Self.evidenceLabel(kind)
    }

    private func actions(_ v: Version) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button(L10n.t("在列表中显示")) {
                dismiss()
                onOpen(v.key)
            }
            .disabled(store.summary(forKey: v.key) == nil)
            if v.relation == .split {
                Button(L10n.t("恢复合并")) { run { await store.unsplitSong(keys: v.mergeKeys) } }
                    .disabled(busy)
            } else {
                Button(L10n.t("拆分…")) {
                    pendingSplit = v.key
                    confirmingSplit = true
                }
                .disabled(busy)
            }
        }
    }

    // MARK: - 文字

    private func lyricsVerdict(_ v: Version) -> String {
        if !v.lyricsKnown { return L10n.t("歌词无法读取") }
        if v.lyrics.isEmpty { return L10n.t("无歌词") }
        switch v.match {
        case .identical: return L10n.t("完全一致")
        case .sameText: return L10n.t("文字一致")
        case .different: return L10n.t("存在差异")
        }
    }

    /// 整张面板只用一套状态色:绿 = 跟当前条目一样 / 同步,红 = 不一样 / 不同步,灰 = 比不了或不适用(没歌词、读不到、
    /// 已拆分、同步关着);蓝只标哪一条是当前条目,不表示状态(18 章决策 62)。逐项对照、逐行对比里不一样的也标红。
    private func lyricsColor(_ v: Version) -> Color {
        if !v.lyricsKnown || v.lyrics.isEmpty { return .secondary }
        return v.match == .different ? .red : .green
    }

    /// 文字一致用等号,跟完全一致的勾分得开。
    private func lyricsSymbol(_ v: Version) -> String {
        if !v.lyricsKnown || v.lyrics.isEmpty { return "minus.circle.fill" }
        switch v.match {
        case .identical: return "checkmark.circle.fill"
        case .sameText: return "equal.circle.fill"
        case .different: return "xmark.circle.fill"
        }
    }

    private func lyricsCardSymbol(_ v: Version) -> String {
        if !v.lyricsKnown || v.lyrics.isEmpty { return "questionmark" }
        switch v.match {
        case .identical: return "checkmark"
        case .sameText: return "equal"
        case .different: return "notequal"
        }
    }

    /// 列表、一览表里的状态点:勾 = 一样 / 同步,等号 = 文字一致,叉 = 不一样 / 不同步,横杠 = 比不了或不适用。形状本身分得开,不只靠颜色
    /// (红绿色弱也认得出)。label 为 nil 时旁边已经有文字,读屏跳过它。
    @ViewBuilder
    private func statusDot(_ symbol: String, _ color: Color, size: CGFloat, label: String?) -> some View {
        let dot = Image(systemName: symbol)
            .font(.system(size: size))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.white, color)
        if let label {
            dot.help(label).accessibilityLabel(label)
        } else {
            dot.accessibilityHidden(true)
        }
    }

    private func sourceText(_ v: Version) -> String {
        guard !v.source.isEmpty else { return "" }
        guard let score = v.score else { return sourceDisplayName(v.source) }
        return String(format: L10n.t("%1$@ · %2$d 分"), sourceDisplayName(v.source), score)
    }

    private func featuresText(_ v: Version) -> String { v.features.joined(separator: " · ") }

    private func durationText(_ v: Version) -> String {
        guard let secs = v.durationSecs else { return L10n.t("未提供") }
        return LyricsCandidateDuration.clock(secs)
    }

    private func playerName(_ bundleID: String) -> String { Self.playerDisplayName(bundleID) }

    static func playerDisplayName(_ bundleID: String) -> String {
        PlaybackPlayer.builtin(forBundleID: bundleID)?.displayName
            ?? FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
    }

    /// 一份原始写法:「歌名 · 歌手 · 专辑（播放器）」,空的那段不写。
    static func reportedLine(_ r: SongVersions.ReportedName) -> String {
        String(format: L10n.t("%1$@（%2$@）"), reportedName(r), playerDisplayName(r.bundleID))
    }

    private static func reportedName(_ r: SongVersions.ReportedName) -> String {
        [r.title, r.artist, r.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 信息表、对照表的「原始写法」:放过这条的播放器各一行,按播放来源的顺序。引擎只记跟条目名不一样的写法,没记的那家写
    /// 「与条目名相同」;播放器是按 id 推断的不下这个结论,只列记下的。
    private func reportedText(_ v: Version) -> String {
        let players = v.playersInferred ? [] : v.players
        let ids = players + v.reported.map(\.bundleID).filter { !players.contains($0) }
        return ids.map { id in
            let name = v.reported.first { $0.bundleID == id }.map(Self.reportedName) ?? L10n.t("与条目名相同")
            return String(format: L10n.t("%1$@：%2$@"), playerName(id), name)
        }.joined(separator: "\n")
    }

    private func playersText(_ v: Version) -> String {
        guard !v.players.isEmpty else { return v.neverPlayed ? L10n.t("未播放过") : L10n.t("未记录") }
        let names = v.players.map(playerName).joined(separator: " · ")
        return v.playersInferred ? String(format: L10n.t("%@（推断）"), names) : names
    }

    /// 这条记录过的播放器,最多叠三个图标(正在放这条的那个排最前,见 makeVersion);一个都没有时是问号。
    private func playerIcons(_ v: Version, size: CGFloat) -> some View {
        let ids: [String?] = v.players.isEmpty ? [nil] : v.players.prefix(3).map { $0 }
        let step = (size * 0.45).rounded()
        return ZStack(alignment: .leading) {
            ForEach(Array(ids.enumerated()).reversed(), id: \.offset) { index, id in
                playerIcon(id)
                    .frame(width: size, height: size)
                    .offset(x: CGFloat(index) * step)
            }
        }
        .frame(width: size + step * 2, height: size, alignment: .leading)
        .help(playersText(v))
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
        return String(format: L10n.t("拆分「%@」？"), title)
    }

    static func relationTitle(_ relation: Relation) -> String {
        switch relation {
        case .current: return L10n.t("当前条目")
        case .shared: return L10n.t("歌词同步")
        case .own: return L10n.t("独立匹配")
        case .split: return L10n.t("已拆分")
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

    /// 列表里同步那个状态点的形状,跟 lyricsSymbol 同一套。
    static func relationDotSymbol(_ relation: Relation) -> String {
        switch relation {
        case .shared: return "checkmark.circle.fill"
        case .own: return "xmark.circle.fill"
        case .current, .split: return "minus.circle.fill"
        }
    }

    /// 状态色同 lyricsColor 那一套;当前条目是身份标记,用强调色。
    static func relationColor(_ relation: Relation) -> Color {
        switch relation {
        case .current: return .accentColor
        case .shared: return .green
        case .own: return .red
        case .split: return .secondary
        }
    }

    static func relationExplanation(_ relation: Relation) -> String {
        switch relation {
        case .current: return ""
        case .shared: return L10n.t("自动匹配的歌词与当前条目同步：更换歌词时一并更新，手动修改也会同步")
        case .own: return L10n.t("歌词独立匹配，不随当前条目更换；手动修改也不会同步")
        case .split: return L10n.t("已从此歌曲拆分：作为独立歌曲单独统计播放次数，歌词不再关联。如拆分有误，可恢复合并")
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
        reloadGeneration += 1
        let generation = reloadGeneration
        let (edges, splits) = await Task.detached(priority: .userInitiated) {
            let edges = FileIO.read(SongVersions.tableURL).map { SongVersions.edges(tableData: $0, key: key) } ?? []
            let splits = FileIO.read(SongVersions.userURL).map(SongVersions.splits(userData:)) ?? []
            return (edges, splits)
        }.value
        guard !Task.isCancelled, generation == reloadGeneration else { return }
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
        // 这首歌各条目的歌名、歌手都拿来认歌词开头的抬头(跟歌词窗口同一套,见 EnrichCacheReader.headerAliases)。
        var aliases: [LRCParser.HeaderIdentity] = []
        for s in ([key] + (listing?.rows.map(\.key) ?? [])).compactMap(store.summary(forKey:)) {
            let identity = LRCParser.HeaderIdentity(title: s.title, artist: s.artist)
            if !aliases.contains(identity) { aliases.append(identity) }
        }
        var out: [Version] = []
        if let current = makeVersion(key, .current, mergeKeys: [], against: nil, aliases: aliases) {
            out.append(current)
            // 设置里关了「同曲条目共用歌词」时谁都不跟,同组的也按独立匹配显示(同 syncOverview)。
            let sharing = EnrichCacheReader.sharesEntityLyrics
            for row in listing?.rows ?? [] {
                if let v = makeVersion(row.key, row.sharesLyrics && sharing ? .shared : .own, mergeKeys: [], against: current, aliases: aliases) {
                    out.append(v)
                }
            }
            for split in listing?.splits ?? [] {
                if let v = makeVersion(split.key, .split, mergeKeys: split.mergeKeys, against: current, aliases: aliases) { out.append(v) }
            }
        }
        self.edges = edges
        versions = out
        loaded = true
    }

    private func makeVersion(_ key: String, _ relation: Relation, mergeKeys: [String], against current: Version?,
                             aliases: [LRCParser.HeaderIdentity]) -> Version? {
        guard let s = store.summary(forKey: key), let facts = store.versionFacts(forKey: key) else { return nil }
        var features: [String] = []
        if s.hasLyrics {
            features.append(s.hasWordTiming ? L10n.t("逐字") : L10n.t("整行"))
        } else {
            features.append(s.hasPlainTextFallback ? L10n.t("纯文本") : L10n.t("无歌词"))
        }
        if s.hasTranslation { features.append(L10n.t("译文")) }
        if s.hasRomanization { features.append(L10n.t("读音")) }
        let shown = SongVersions.displayed(lyrics: facts.lyrics, yrc: facts.yrc, title: s.title, artist: s.artist, aliases: aliases)
        let comparison = current.map { SongVersions.compareLyrics(current: $0.shown, other: shown) }
        // 正在放的就是这条时,当前这个播放器排最前(引擎按第一次放的先后记)。
        var players = facts.players
        if let bundle = PlaybackCoordinator.shared.resolvedPlayerBundleID, Self.nowPlayingKey == key {
            players.removeAll { $0 == bundle }
            players.insert(bundle, at: 0)
        }
        return Version(key: key, relation: relation, title: s.shownTitle, artist: s.shownArtist, album: s.displayAlbum,
                       players: players, playersInferred: facts.playersInferred, durationSecs: facts.durationSecs,
                       source: s.lyricsSource, score: facts.score, features: features,
                       lyrics: facts.lyrics, yrc: facts.yrc, shown: shown,
                       lyricsKnown: facts.complete, comparison: comparison, mergeKeys: mergeKeys, reported: s.reportedNames)
    }

    static func evidenceLabel(_ kind: String) -> String {
        switch kind {
        case "isrc": return L10n.t("ISRC 一致")
        case "mb_recording": return L10n.t("MusicBrainz 录音 ID 一致")
        case "spotify_track": return L10n.t("Spotify 曲目 ID 一致")
        case "amazon_asin": return L10n.t("Amazon Music 曲目 ID 一致")
        case "kkbox_song": return L10n.t("KKBOX 歌曲 ID 一致")
        case "soda_track": return L10n.t("汽水音乐歌曲 ID 一致")
        case "youtube_video": return L10n.t("YouTube Music 视频 ID 一致")
        case "apple_song_player": return L10n.t("Apple Music 播放的曲目 ID 一致")
        case "netease_song_player": return L10n.t("网易云音乐播放的歌曲 ID 一致")
        case "qq_song_player": return L10n.t("QQ 音乐播放的歌曲 ID 一致")
        case "kugou_song_player": return L10n.t("酷狗音乐播放的歌曲 ID 一致")
        case "apple_song": return L10n.t("Apple Music 检索结果为同一曲目")
        case "netease_song": return L10n.t("网易云音乐检索结果为同一曲目")
        case "qq_song": return L10n.t("QQ 音乐检索结果为同一曲目")
        case "family": return L10n.t("艺人、曲名一致，时长相近")
        case "bare_title": return L10n.t("艺人一致，曲名除括号内说明外一致，时长相近")
        case "lyrics": return L10n.t("两条独立匹配的歌词一致")
        case "apple_name": return L10n.t("与 Apple Music 目录中的曲名吻合")
        case "netease_name": return L10n.t("与网易云音乐目录中的曲名吻合")
        default: return kind
        }
    }
}
