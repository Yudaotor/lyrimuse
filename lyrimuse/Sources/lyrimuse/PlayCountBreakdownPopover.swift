import LyrimuseCore
import SwiftUI

// 「第 N 次听」的合并明细弹框。
//
// 起因:那一格数字是**写法族合并后**的总数(繁简 / 括号风格 / 合唱署名……,见 12 章 §7),用户
// 看得到「第 8 次」,看不到这 8 次是由哪几个 Last.fm 条目凑出来的、每个几次、为什么算同一首。
// 点开这个弹框:顶上是次数 / 首次 / 上次三格,行上的数跟明细合计对不上时紧跟一张提示(那正是「一边合并了、
// 另一边没合并」的信号);有几种写法时列出每种写法(次数、为什么并进来);最后是按月分组的逐次收听,
// 点的那一条高亮并滚到中间。布局取舍见 12 章决策 86。
//
// 数据面见 PlayCountBreakdownLoader / PlayCountBreakdown(Core,纯函数,selftest 钉住编号与合并)。

/// 最近记录里那格「第 N 次听」:一颗可点的小按钮 + 弹框宿主。
/// `nil` 次数时照旧显示 `···` 占位(没确认「那边没有」才显示,理由见 unavailable)。
struct PlayCountBadge: View {
    let artist: String
    let title: String
    /// 行上显示的 N;nil = 还没解析出来。
    let count: Int?
    /// 已确认 Last.fm 那边没有这一项 → 连 `···` 都不显示,否则这个占位会在极少数确实查不到
    /// 次数的行上永远挂着,变成一个说谎的"正在加载"(沿用原来那格的判断)。
    let unavailable: Bool
    /// 这一行自己那条 scrobble 的时刻,明细里高亮它。实时行传 nil(这一次还没落库)。
    let anchorDate: Date?
    /// 行上的合计口径(`trackPlayCounts` 里整族合并总数),明细合计跟它对账。实时行传 nil ——
    /// 那边的数是 userplaycount + 1,含还没落库的这一次,跟明细对不上是正常的、不该报。
    let expectedTotal: Int?

    @State private var showing = false
    @State private var hovered = false

    var body: some View {
        if let count {
            Button {
                showing.toggle()
            } label: {
                Text(String(format: L10n.t("第 %@ 次收听"), "\(count)"))
                    .font(.caption)
                    .foregroundStyle(hovered || showing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .monospacedDigit()
                    .underline(hovered || showing, color: .secondary.opacity(0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(L10n.t("这首歌曲在 Last.fm 上的收听序号，点按查看已合并的条目"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                PlayCountBreakdownPopover(artist: artist, title: title,
                                          anchorDate: anchorDate, expectedTotal: expectedTotal)
            }
        } else if !unavailable {
            Text("···")
                .font(.caption).foregroundStyle(.quaternary).monospacedDigit()
                .help(L10n.t("正在解析收听次数"))
        }
    }
}

struct PlayCountBreakdownPopover: View {
    @StateObject private var loader: PlayCountBreakdownLoader
    let anchorDate: Date?
    let expectedTotal: Int?

    init(artist: String, title: String, anchorDate: Date?, expectedTotal: Int?) {
        _loader = StateObject(wrappedValue: PlayCountBreakdownLoader(artist: artist, title: title))
        self.anchorDate = anchorDate
        self.expectedTotal = expectedTotal
    }

    /// 写法的标识色,按清单里的位置取;本尊永远是第 0 个。9 种写法之后循环 —— 族封顶 8 + 本尊,
    /// 到不了。
    private static let palette: [Color] = [.accentColor, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint]
    private static func color(_ index: Int) -> Color { palette[index % palette.count] }

    /// 分组框的圆角和左右外边距,跟 `SettingsRowGroup` 在浮层里的画法一致。
    private static let groupRadius: CGFloat = 12
    private static let groupInset: CGFloat = 10

    var body: some View {
        // 480:正文 13pt 时一行收听要放下「第 N 次」「10月13日 周一 11:07」和专辑名,440 会把常见的专辑名截掉。
        SettingsPopoverShell(
            title: L10n.t("合并明细"),
            help: L10n.t("「第 N 次收听」会将同一首歌曲的不同写法（繁简、括号风格、合唱署名等）合并计数。此处列出合并到这一行的每种写法、各自的次数与原因，以及每次收听的时间"),
            width: 480,
            scrollTarget: anchorRowID
        ) {
            switch loader.state {
            case .loading:
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 22)
            case .failed:
                HStack(spacing: 8) {
                    Text(L10n.t("加载失败")).font(.callout).foregroundStyle(.secondary)
                    Button(L10n.t("重试")) { Task { await loader.load() } }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            case .loaded:
                if let b = loader.breakdown { content(b) }
            }
        }
        .task { await loader.load() }
    }

    /// 点的那一条(同一秒即同一条,scrobble 时间戳精度就是秒)。加载完才有,外壳据此滚过去;排在最前几条时
    /// 不滚,打开时顶上的次数和写法就在眼前,那一行也已经看得见。
    private var anchorRowID: AnyHashable? {
        guard loader.state == .loaded, let anchorDate, let b = loader.breakdown,
              let i = b.plays.firstIndex(where: { abs($0.date.timeIntervalSince(anchorDate)) < 1 }),
              i >= Self.visibleOnOpen else { return nil }
        return AnyHashable(b.plays[i].id)
    }
    /// 打开时不用滚就看得见的大约条数。
    private static let visibleOnOpen = 4

    // MARK: 内容

    /// 收听记录按月分组、月份标题滚动时固定在顶上;每一行都是 `LazyVStack` 的直接子视图,外壳的 `scrollTarget` 才滚得到。
    @ViewBuilder private func content(_ b: PlayCountBreakdown) -> some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            header(b)
            notices(b)
            variantsGroup(b)
            sectionTitle(L10n.t("收听记录"))
                .padding(.top, 14)
            let ordinals = b.ordinals
            ForEach(Self.months(b), id: \.key) { month in
                Section {
                    ForEach(month.range, id: \.self) { i in
                        playRow(b.plays[i], ordinal: ordinals[i], multi: b.variants.count > 1)
                            .background(groupedRowBackground(first: i == month.range.lowerBound,
                                                             last: i == month.range.upperBound - 1))
                            .padding(.horizontal, Self.groupInset)
                            .id(b.plays[i].id)
                    }
                } header: {
                    monthHeader(month, isOldestLoaded: b.canLoadOlder && month.range.upperBound == b.plays.count)
                }
            }
            if b.canLoadOlder { loadOlder(b) }
        }
    }

    private func header(_ b: PlayCountBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(loader.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(loader.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            HStack(spacing: 0) {
                statCell(L10n.t("收听次数"), value: "\(b.total)")
                Divider()
                // 首次只在全部拉完时才知道:没拉完时已拉到的最早一条不是第一次。
                statCell(L10n.t("首次收听"),
                         value: b.canLoadOlder || b.hasFailure ? nil : b.plays.last.map { Self.format($0.date, "yMd") })
                Divider()
                statCell(L10n.t("上次收听"),
                         value: b.plays.first.map { "\(Self.rowDay($0.date)) \(Self.timeLabel($0.date))" })
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, Self.groupInset)
        }
        .padding(.top, 2)
    }

    /// nil = 还不知道,写「尚未加载」。
    private func statCell(_ label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            if let value {
                Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
            } else {
                Text(L10n.t("尚未加载")).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// 取数没取全、两边合计对不上:放在最上面,滚到底才看得到的话等于没说。
    @ViewBuilder private func notices(_ b: PlayCountBreakdown) -> some View {
        if b.hasFailure {
            notice(L10n.t("部分写法未能获取"), detail: nil) {
                Button(L10n.t("重试")) { Task { await loader.load() } }.buttonStyle(.link)
            }
        }
        if !b.hasFailure, let expected = expectedTotal, expected != b.total {
            notice(String(format: L10n.t("行上按 %1$@ 次计，明细合计 %2$@ 次"), "\(expected)", "\(b.total)"),
                   detail: L10n.t("有一种写法只在其中一边被合并时会这样")) {
                HelpButton(text: L10n.t("两个数字来自 Last.fm 的两个接口：行上的次数由 track.getInfo（autocorrect）按写法族求和，明细由 user.getTrackScrobbles 按精确写法逐条列出。两者不一致通常是因为某种写法只在其中一边被合并"))
            }
        }
    }

    private func notice<Accessory: View>(_ text: String, detail: String?,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 13)).monospacedDigit()
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous)
            .fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
        .padding(.horizontal, Self.groupInset)
        .padding(.top, 10)
    }

    private func sectionTitle(_ text: String, trailing: String? = nil) -> some View {
        HStack {
            Text(text)
            Spacer()
            if let trailing { Text(trailing).fontWeight(.regular) }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding + 2)
        .padding(.bottom, 6)
    }

    // MARK: 写法

    /// 只有一种写法时不列:跟顶上的歌名是同一条信息。
    @ViewBuilder private func variantsGroup(_ b: PlayCountBreakdown) -> some View {
        if b.variants.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle(String(format: L10n.plural("%@ 种写法", count: b.variants.count), "\(b.variants.count)"))
                    .padding(.top, 14)
                VStack(spacing: 0) {
                    ForEach(Array(b.variants.enumerated()), id: \.element.id) { i, v in
                        if i > 0 { Divider().padding(.leading, 12) }
                        variantRow(i, v)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, Self.groupInset)
            }
        }
    }

    /// 色点对应下面收听记录里的行;本尊不写原因,其余写为什么并进来。
    private func variantRow(_ index: Int, _ v: PlayCountBreakdown.Variant) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Self.color(index)).frame(width: 7, height: 7)
            Text("\(v.artist) · \(v.title)").lineLimit(1)
            if !v.isSelf {
                Text(Self.variantReason(v)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if v.failed {
                Text(L10n.t("未获取")).foregroundStyle(.secondary)
            } else {
                Text(String(format: L10n.t("%@ 次"), "\(v.total)")).monospacedDigit()
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    /// 写法完全一致却是两条 —— 只可能是 Last.fm 那边按大小写/空格分开存的、我们这边折到同一个键,
    /// 归到最轻的那一档。
    private static func variantReason(_ v: PlayCountBreakdown.Variant) -> String {
        L10n.list((v.reasons.isEmpty ? [PlayCountFoldReason.caseOrSpacing] : v.reasons).map(reasonLabel))
    }

    static func reasonLabel(_ r: PlayCountFoldReason) -> String {
        switch r {
        case .caseOrSpacing: return L10n.t("大小写/空格")
        case .fullwidth: return L10n.t("全角/半角")
        case .hanScript: return L10n.t("繁简")
        case .catalogNoise: return L10n.t("Remaster/feat. 等标注")
        case .versionSuffix: return L10n.t("版本尾缀写法")
        case .bilingualTitle: return L10n.t("双语歌名")
        case .artistCredit: return L10n.t("合唱署名")
        case .artistAlias: return L10n.t("歌手别名")
        case .titleAlias: return L10n.t("歌名别名")
        case .other: return L10n.t("其他折叠规则")
        }
    }

    // MARK: 收听记录

    private struct Month {
        let key: Int
        let date: Date
        /// 在 `plays` 里的下标区间(倒序列表里同一个月连续)。
        let range: Range<Int>
    }

    private static func months(_ b: PlayCountBreakdown) -> [Month] {
        let cal = Calendar.current
        var out: [Month] = []
        var start = 0
        for i in b.plays.indices {
            let c = cal.dateComponents([.year, .month], from: b.plays[i].date)
            let key = (c.year ?? 0) * 12 + (c.month ?? 0)
            if let last = out.last, last.key == key {
                out[out.count - 1] = Month(key: key, date: last.date, range: start..<(i + 1))
            } else {
                start = i
                out.append(Month(key: key, date: b.plays[i].date, range: i..<(i + 1)))
            }
        }
        return out
    }

    /// 最后一个已加载的月份没拉完时次数前加「至少」。
    private func monthHeader(_ month: Month, isOldestLoaded: Bool) -> some View {
        PinnedMonthHeader(
            title: Self.format(month.date, "yMMMM"),
            count: String(format: isOldestLoaded ? L10n.t("至少 %@ 次") : L10n.t("%@ 次"), "\(month.range.count)"))
    }

    private func playRow(_ p: PlayCountBreakdown.Play, ordinal: Int?, multi: Bool) -> some View {
        let isAnchor = anchorDate.map { abs($0.timeIntervalSince(p.date)) < 1 } ?? false
        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                if multi {
                    Circle().fill(Self.color(p.variantIndex)).frame(width: 6, height: 6)
                }
                Text(ordinal.map { String(format: L10n.t("第 %@ 次"), "\($0)") } ?? "—")
                    .foregroundStyle(isAnchor ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .fontWeight(isAnchor ? .semibold : .regular)
            }
            .frame(width: 84, alignment: .leading)
            HStack(spacing: 5) {
                Text(Self.rowDay(p.date))
                Text(Self.timeLabel(p.date)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .help(LastfmStatsSection.absolute(p.date))
            Spacer(minLength: 8)
            Text(p.album ?? L10n.t("未注明专辑"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(p.album ?? "")
        }
        .font(.system(size: 13))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(isAnchor ? Color.accentColor.opacity(0.14) : .clear)
    }

    /// 同一个月的行拼成一个圆角分组框:首行圆上角、末行圆下角,中间的行之间画分隔线。
    private func groupedRowBackground(first: Bool, last: Bool) -> some View {
        let r = Self.groupRadius
        return UnevenRoundedRectangle(topLeadingRadius: first ? r : 0, bottomLeadingRadius: last ? r : 0,
                                      bottomTrailingRadius: last ? r : 0, topTrailingRadius: first ? r : 0,
                                      style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(alignment: .top) {
                if !first { Divider().padding(.horizontal, 12) }
            }
    }

    @ViewBuilder private func loadOlder(_ b: PlayCountBreakdown) -> some View {
        VStack(spacing: 6) {
            Group {
                if loader.loadingOlder {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.t("加载更早的记录")) { Task { await loader.loadOlder() } }
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
            if b.ordinalCutoff != nil {
                Text(L10n.t("更早的记录尚未加载，这些行暂不编号"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Self.groupInset)
        .padding(.top, 10)
    }

    // MARK: 格式化

    /// 收听记录里的日期:今天 / 昨天,其余「10月13日 周一」—— 同一个月的行在一个框里,月份标题已经写了年份。
    private static func rowDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) || cal.isDateInYesterday(date) { return RelativeDayFormat.dayLabel(date) }
        return format(date, "MMMdEEE")
    }

    private static func timeLabel(_ date: Date) -> String { RelativeDayFormat.timeFormatter.string(from: date) }

    /// 跟 App 界面语言走(`L10n.locale`),不跟系统语言。
    private static var formatters: [String: DateFormatter] = [:]
    private static func format(_ date: Date, _ template: String) -> String {
        let key = L10n.locale.identifier + "|" + template
        if let f = formatters[key] { return f.string(from: date) }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = f
        return f.string(from: date)
    }
}

/// 收听记录的月份标题。吸在顶上时才铺一层材质底,挡住滚到它底下的行;没吸顶时跟上面的分组标题一样没有底。
private struct PinnedMonthHeader: View {
    let title: String
    let count: String
    @State private var pinned = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(count).fontWeight(.regular)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding + 2)
        .padding(.top, 10)
        .padding(.bottom, 5)
        .background { if pinned { Rectangle().fill(.regularMaterial) } }
        .onGeometryChange(for: Bool.self, of: { $0.frame(in: .scrollView).minY <= 0.5 }) { pinned = $0 }
    }
}
