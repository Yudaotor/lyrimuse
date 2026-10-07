import AppKit
import Combine
import LyrimuseCore
import SwiftUI

// 「歌词管理」窗口的界面零件:侧栏的行、胶囊、正在播放、自动匹配进度卡、拖宽度的柄,详情页的封面氛围、预览、逐句编辑。
// 状态都在 LyricsManagerView,这里只按传进来的值画,动作回调出去。

/// 右边预览 / 编辑显示哪几行。
enum LyricsManagerDisplayMode: String, CaseIterable, Identifiable {
    case original
    case translation
    case romanization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return L10n.t("原文")
        case .translation: return L10n.t("原文 + 译文")
        case .romanization: return L10n.t("原文 + 读音")
        }
    }
}

/// 右边是预览,还是在编辑(逐句格子 / 整段文本)。
enum LyricsManagerEditMode: Equatable {
    case preview
    case lines
    case text
}

/// 歌词那几样特征(逐字、译文、读音、人工修正、已校准、来源已选定、没词的原因)在标签和小标记上的颜色。歌词管理的列表行、
/// 详情页标签和搜索候选歌词面板都读这一份,不在调用点各写各的(见 11 章决策 79);来源的颜色是 sourceColor。
enum LyricsFeatureTint {
    static let wordTiming = Color.blue
    static let translation = Color.green
    static let machineTranslation = Color.purple
    static let romanization = Color.purple
    static let manual = Color.orange
    static let sourceChoice = Color.indigo
    static let pinned = Color.teal
    static let plainTextOnly = Color.orange
    static let noLyrics = Color.red
}

/// 正在放的那一句(歌词原始时间轴上的起点和它的逐字时间)、播没播、暂停在哪,给预览的「跟随播放」和当前句逐字染色用。
/// 只转发变了的那一下:`PlaybackCoordinator` 播放中每秒发布二十次,整扇窗口订阅它会把列表一起拖进去重算
/// (见 LyricsManagerNowPlayingObserver 头注)。
@MainActor
final class LyricsManagerPlaybackLine: ObservableObject {
    struct Current: Equatable {
        let timeMs: Int
        let text: String?
        /// 这一句的逐字时间,整行歌词为 nil。
        let words: [SyncedLyricWord]?
    }

    @Published private(set) var current: Current?
    @Published private(set) var isPlaying = false
    /// 暂停时的时间基准(冻结位置 + 歌词偏移),播放中 nil。
    @Published private(set) var pausedMs: Int?
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        subs.append(Publishers.CombineLatest(p.$currentLineIndex, p.$allLines)
            .map { index, lines -> Current? in
                guard let index, lines.indices.contains(index) else { return nil }
                let line = lines[index]
                return Current(timeMs: line.timeMs, text: line.line.plainText, words: line.line.words)
            }
            .removeDuplicates()
            .sink { [weak self] in self?.current = $0 })
        subs.append(p.$isPlayingNow
            .removeDuplicates()
            .sink { [weak self] in self?.isPlaying = $0 })
        subs.append(Publishers.CombineLatest3(p.$isPlayingNow, p.$pausedPositionMs, p.$currentLyricsOffsetMs)
            .map { playing, paused, offset -> Int? in
                guard !playing, let paused else { return nil }
                return paused &+ offset
            }
            .removeDuplicates()
            .sink { [weak self] in self?.pausedMs = $0 })
    }
}

/// 封面方块。没有封面地址、或者图还没取到时画一块灰底音符。
struct LyricsManagerCover: View {
    let url: URL?
    var image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                CachedImage(url: url) { placeholder }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        LinearGradient(colors: [Color(white: 0.62), Color(white: 0.46)], startPoint: .top, endPoint: .bottom)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            )
    }
}

/// 详情页头部铺的那层模糊封面:往下渐隐,歌词区保持干净底色。浅色、深色都铺,深色下浓一点。
struct LyricsManagerAmbience: View {
    static let height: CGFloat = 340

    let url: URL?
    /// 有就用这张(正在放的那首,播放器给的封面),不去取 url。
    var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                CachedImage(url: url) { Color.clear }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .blur(radius: 70)
        .saturation(1.3)
        .opacity(colorScheme == .dark ? 0.6 : 0.5)
        .mask(
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black.opacity(0.55), location: 0.55),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 侧栏和「筛选」里的胶囊(状态、歌词类型):标题 + 数,选中时实心强调色。数是中性灰(见 11 章决策 67)。
struct LyricsManagerChip: View {
    let title: String
    var count: Int?
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let count {
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
        .contentShape(Capsule())
        .fixedSize()
    }
}

/// 「筛选」里「来源」「歌手」「专辑」那种点开是一张单选表的胶囊:没选时描边 + ▾,选了某一项时强调色浅底、写出选的是什么。
struct LyricsManagerMenuChip: View {
    let title: String
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(active ? Color.accentColor.opacity(0.14) : Color.clear))
        .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.16), lineWidth: 0.5))
        .contentShape(Capsule())
        .frame(maxWidth: 200)
        .fixedSize()
    }
}

/// 「来源」「歌手」「专辑」那张单选表。项多的(歌手、专辑)顶上带搜索框。nil = 全部。
struct LyricsManagerOptionList: View {
    struct Option: Identifiable, Hashable {
        let id: String
        let title: String
    }

    let allTitle: String
    let options: [Option]
    let selectedID: String?
    let searchable: Bool
    let onSelect: (String?) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if searchable {
                TextField(L10n.t("搜索"), text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if LyricsManagerSearch.query(query).isEmpty {
                        row(id: nil, title: allTitle)
                    }
                    ForEach(filtered) { row(id: $0.id, title: $0.title) }
                }
            }
            .frame(height: min(CGFloat(filtered.count + 1) * 26, 320))
        }
        .padding(10)
        .frame(width: 260)
    }

    private var filtered: [Option] {
        let q = LyricsManagerSearch.query(query).lowercased()
        guard !q.isEmpty else { return options }
        return options.filter { $0.title.lowercased().contains(q) }
    }

    private func row(id: String?, title: String) -> some View {
        Button {
            onSelect(id)
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(selectedID == id ? 1 : 0)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 列表的一行:封面 + 歌名 / 歌手 · 专辑;右边是来源(或没词的原因)和几颗小标记。来源名用全局那份 sourceColor,没词的原因和
/// 小标记的颜色读 LyricsFeatureTint(见 11 章决策 79)。行上不放悬停按钮,操作在右键菜单和详情页右上角:按钮会盖住来源和
/// 小标记(见 11 章决策 66)。
struct LyricsManagerSongRow: View {
    let summary: EnrichCacheStore.Summary
    let albumDisplayName: String
    /// 列表此刻在搜的关键词,命中的字黄底高亮;没在搜为空。
    let query: String
    let isNowPlaying: Bool
    let isPinned: Bool
    /// 这一行选中、列表有键盘焦点:系统铺一层实心强调色,彩色的字、小标记和搜索高亮都换成跟着白字走的样子。
    /// 由窗口那边判断后传进来(`LyricsManagerWindowFramePersistence.listHasKeyFocus`),这种列表里 backgroundProminence 不跟着变。
    let isEmphasized: Bool
    /// 正在放的那首传播放器给的封面,有就直接画,不等缓存里的封面地址(见 11 章决策 78)。
    var artwork: NSImage? = nil

    private var emphasized: Bool { isEmphasized }

    var body: some View {
        HStack(spacing: 11) {
            LyricsManagerCover(url: summary.coverURL, image: artwork, size: 40, radius: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isNowPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(emphasized ? Color.primary : Color.accentColor)
                            .accessibilityLabel(L10n.t("正在播放"))
                    }
                    Text(highlighted(summary.title))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Text(highlighted(subtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(summary.artist.isEmpty && !summary.inferredArtist.isEmpty ? L10n.t("播放器未提供歌手，按歌名和时长推断") : "")
            }
            Spacer(minLength: 8)
            trailing
        }
        // 行高(封面 40 + 上下各 4)改了要连 LyricsManagerView.listRowHeight 一起改。
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// 歌手 · 专辑;播放器没报歌手时用引擎认出来的(悬停说明是推断的),还没认出来写「未知歌手」,不留一行空白。
    private var subtitle: String {
        let artist = summary.shownArtist.isEmpty ? L10n.t("未知歌手") : summary.shownArtist
        return albumDisplayName.isEmpty ? artist : "\(artist) · \(albumDisplayName)"
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 3) {
            status
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            badges
        }
    }

    /// 有词:来源。没词(或标了纯音乐):五档原因,判定顺序见 `Summary.lastRoundHadNoResponder` 的注释。
    @ViewBuilder
    private var status: some View {
        if summary.isSearching {
            Text(L10n.t("搜索歌词中…")).foregroundStyle(.secondary)
        } else if !summary.hasLyrics || summary.isInstrumental {
            if summary.isInstrumental {
                Text(L10n.t("纯音乐")).foregroundStyle(.secondary)
            } else if summary.hasPlainTextFallback {
                Text(L10n.t("仅纯文本")).foregroundStyle(emphasized ? Color.primary : LyricsFeatureTint.plainTextOnly)
            } else if summary.lastRoundHadNoResponder {
                Text(L10n.t("无源应答")).foregroundStyle(.secondary)
                    .help(L10n.t("最近一次解析时没有任何歌词源应答，可能是当时网络不可用，并不代表这首歌曲没有歌词。稍后会自动重试，也可立即重新自动匹配"))
            } else if summary.knownOnSources {
                Text(L10n.t("已收录、无歌词")).foregroundStyle(.secondary)
            } else {
                Text(L10n.t("无歌词")).foregroundStyle(emphasized ? Color.primary : LyricsFeatureTint.noLyrics)
            }
        } else {
            Text(sourceDisplayName(summary.lyricsSource))
                .foregroundStyle(emphasized ? Color.primary : sourceColor(summary.lyricsSource))
                .help(sourceHelpText(summary.lyricsSource))
        }
    }

    /// 人工修正 / 来源已选定 / 已校准 / 逐字或整行 / 译文 / 读音,有才画。颜色读 LyricsFeatureTint(见 11 章决策 79)。
    @ViewBuilder
    private var badges: some View {
        if !summary.isSearching {
            HStack(spacing: 5) {
                if summary.isManual {
                    badge("pencil.circle.fill", tint: LyricsFeatureTint.manual, help: L10n.t("已人工修正"))
                }
                if !summary.sourceChoice.isEmpty {
                    badge("pin.circle.fill", tint: LyricsFeatureTint.sourceChoice,
                          help: String(format: L10n.t("来源已选定：%@"), sourceDisplayName(summary.sourceChoice)))
                }
                if isPinned {
                    badge("timer", tint: LyricsFeatureTint.pinned, help: L10n.t("已校准"))
                }
                if summary.hasLyrics {
                    badge(summary.hasWordTiming ? "text.word.spacing" : "text.alignleft",
                          tint: summary.hasWordTiming ? LyricsFeatureTint.wordTiming : .secondary,
                          help: summary.hasWordTiming ? L10n.t("逐字时间轴") : L10n.t("整行时间轴"))
                }
                if summary.hasTranslation {
                    let machine = summary.lyricsTrSource == LyricsTranslationSource.machineSentinel
                    badge("character.book.closed",
                          tint: machine ? LyricsFeatureTint.machineTranslation : LyricsFeatureTint.translation,
                          help: machine ? L10n.t("译文（机器翻译）") : L10n.t("译文（歌词源自带）"))
                }
                if summary.hasRomanization {
                    badge("textformat.abc", tint: LyricsFeatureTint.romanization, help: L10n.t("读音"), latin: true)
                }
            }
            .font(.system(size: 9.5))
        }
    }

    /// 选中且列表有键盘焦点时行底是实心强调色,彩色的标记换成跟着白字走,不然看不清(见 11 章决策 67)。
    private func badge(_ symbol: String, tint: Color, help: String, latin: Bool = false) -> some View {
        Image(systemName: symbol)
            // textformat.abc 会跟着界面语言变成「甲乙丙」,读音要钉成拉丁字母那一版,同 LatinIconLabel。
            .environment(\.locale, latin ? Locale(identifier: "en") : .current)
            .foregroundStyle(emphasized ? Color.primary.opacity(0.8) : tint)
            .help(help)
            .accessibilityLabel(help)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard !query.isEmpty else { return out }
        for range in LyricsManagerSearch.matchRanges(of: query, in: text) {
            guard let r = Range(range, in: out) else { continue }
            out[r].backgroundColor = emphasized ? Color.white.opacity(0.3) : Color.yellow.opacity(0.45)
        }
        return out
    }
}

/// 按专辑分组时的组头,画成分节标题:专辑名、歌手、首数排一行,次要色,底下一条分隔线。不带封面:组里每首歌的封面就是
/// 这张专辑的,组头再画一张就跟歌曲行长得一样了(见 11 章决策 74)。
struct LyricsManagerAlbumHeader: View {
    let album: String
    let artist: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(album)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(artist)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(String(format: L10n.plural("%@ 首歌", count: count), count.formatted()))
                    .font(.system(size: 11))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            Divider()
        }
    }
}

/// 侧栏上面那一条「正在播放」:整行是一个按钮,点哪里都跳到列表里这一首;右边的「定位」只当提示,指针移上去底色加深一点
/// (见 11 章决策 82)。
struct LyricsManagerNowPlayingRow: View {
    let artwork: NSImage?
    let coverURL: URL?
    let title: String
    let artist: String
    let onLocate: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: onLocate) {
            HStack(spacing: 10) {
                LyricsManagerCover(url: coverURL, image: artwork, size: 34, radius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform").font(.system(size: 9, weight: .bold))
                        Text(L10n.t("正在播放")).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    Text(artist.isEmpty ? title : "\(title) · \(artist)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    Text(L10n.t("定位"))
                    Image(systemName: "arrow.down.forward.circle")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
            .padding(8)
            .background(shape.fill(Color.accentColor.opacity(hovered ? 0.14 : 0.08)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(L10n.t("跳转到列表中正在播放的歌曲；若被搜索或筛选隐藏，会先清除"))
    }
}

/// 侧栏底部的自动匹配进度卡:点了之后、引擎接手之前转圈;跑着时是进度、找到几首和「停止」,点卡片看详情
/// (跟设置页「歌词库」那两行同一份 `FillSweepProgressDetail`);刚跑完的一小会儿说一句结果。
struct LyricsManagerSweepCard: View {
    enum Phase {
        case preparing(full: Bool)
        case running(LyricsFillSweep.Info)
        case finished(LyricsFillSweep.Info)
    }

    let phase: Phase
    let listingMissing: Bool
    let fallbackSecondsPerTrack: Double
    let onStop: () -> Void
    @State private var showDetail = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if case let .running(status) = phase {
                Button(status.isFullScan ? L10n.t("停止扫库") : L10n.t("停止"), action: onStop)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(shape.fill(Color(nsColor: .textBackgroundColor).opacity(0.92)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .contentShape(shape)
        .onTapGesture {
            if case .running = phase { showDetail.toggle() }
        }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            if case let .running(status) = phase {
                FillSweepProgressDetail(status: status, fallbackSecondsPerTrack: fallbackSecondsPerTrack)
            }
        }
        .onChange(of: isRunning) { _, running in if !running { showDetail = false } }
        .help(isRunning ? L10n.t("查看进度详情") : "")
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    @ViewBuilder
    private var leading: some View {
        switch phase {
        case .preparing:
            ProgressView().controlSize(.small)
        case let .running(status):
            ProgressView(value: Double(status.done), total: Double(max(status.total, 1)))
                .progressViewStyle(.circular)
                .controlSize(.small)
        case let .finished(status):
            Image(systemName: status.isOffline ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(status.isOffline ? Color.orange : Color.green)
        }
    }

    private var title: String {
        switch phase {
        case let .preparing(full):
            return full ? L10n.t("全量重新扫库") : L10n.t("正在准备自动匹配…")
        case let .running(status):
            return String(format: status.isFullScan ? L10n.t("扫描中 %1$@/%2$@") : L10n.t("自动匹配中 %1$@/%2$@"),
                          status.done.formatted(), status.total.formatted())
        case let .finished(status):
            return String(format: L10n.t("自动匹配完成，找到 %@ 首"), status.filled.formatted())
        }
    }

    private var subtitle: String? {
        switch phase {
        case .preparing:
            return nil
        case let .running(status):
            if status.isOffline { return L10n.t("网络不可用，稍后重试…") }
            if status.isFullScan { return String(format: L10n.t("已更新 %@ 首"), status.filled.formatted()) }
            return String(format: listingMissing ? L10n.t("已找到 %@ 首，找到后会自动移出此列表") : L10n.t("已找到 %@ 首"),
                          status.filled.formatted())
        case let .finished(status):
            if status.isOffline { return L10n.t("因网络不可用已停止") }
            if status.cancelled == true { return L10n.t("已手动停止") }
            return nil
        }
    }
}

/// 侧栏右边缘的拖柄:指针移到边缘附近才露出来;拖动改宽度,双击回到默认宽度。
struct LyricsManagerSidebarHandle: View {
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void
    let onDoubleClick: () -> Void
    @State private var hovering = false
    @State private var dragging = false
    @State private var pushedCursor = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(dragging ? 0.42 : 0.28))
            .frame(width: 4, height: 44)
            .opacity(hovering || dragging ? 1 : 0)
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside, !pushedCursor { NSCursor.resizeLeftRight.push(); pushedCursor = true }
                if !inside, !dragging, pushedCursor { NSCursor.pop(); pushedCursor = false }
            }
            .onDisappear { if pushedCursor { NSCursor.pop(); pushedCursor = false } }
            // 位移在全局坐标里算:拖柄本身跟着宽度移动,按它自己的坐标算会把移动量吃掉一截。
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        dragging = true
                        onDrag(value.location.x - value.startLocation.x)
                    }
                    .onEnded { _ in
                        dragging = false
                        onDragEnd()
                        if !hovering, pushedCursor { NSCursor.pop(); pushedCursor = false }
                    }
            )
            .onTapGesture(count: 2, perform: onDoubleClick)
            .animation(.easeOut(duration: 0.15), value: hovering || dragging)
            .accessibilityHidden(true)
    }
}

/// 详情页头部下面那行概况里的一项。
struct LyricsManagerFact: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

/// 详情页头部那排小标签。铺在封面氛围上,底下垫一层浅底,颜色深浅不随封面漂。颜色由调用方传:来源用 sourceColor,特征标签用
/// LyricsFeatureTint,没传的是中性灰(见 11 章决策 79)。
struct LyricsManagerTag: View {
    let icon: String
    let text: String
    var tint: Color = .secondary
    var latinIcon = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .environment(\.locale, latinIcon ? Locale(identifier: "en") : .current)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.78)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        .fixedSize()
    }
}

/// 「原文 / 原文 + 译文 / 原文 + 读音」三选一。这首没有的那一档灰掉,悬停说为什么。
struct LyricsManagerModePicker: View {
    @Binding var mode: LyricsManagerDisplayMode
    /// 这首实际按哪一档显示:选的那一档这首没有时是「原文」。高亮跟它走,选择本身(mode)不改,换到有的歌又回来。
    let shown: LyricsManagerDisplayMode
    let isAvailable: (LyricsManagerDisplayMode) -> Bool
    /// 点不了的那一档,悬停时说为什么。
    let unavailableHelp: (LyricsManagerDisplayMode) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LyricsManagerDisplayMode.allCases) { option in
                let enabled = isAvailable(option)
                Button {
                    mode = option
                } label: {
                    Text(option.title)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(shown == option ? Color.primary.opacity(0.1) : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.55))
                .disabled(!enabled)
                .help(enabled ? "" : unavailableHelp(option))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .padding(3)
        .settingsCardBackground(cornerRadius: 16)
        .fixedSize()
    }
}

/// 单曲时间轴偏移:− / + 按设置里的步长调,中间的数字能直接输入秒数、回车生效,不为 0 时多一颗「重置」。
struct LyricsManagerOffsetControl: View {
    @Binding var text: String
    let isNonZero: Bool
    let stepText: String
    let onStep: (Int) -> Void
    let onSubmit: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").foregroundStyle(.secondary)
            Text(L10n.t("时间轴")).foregroundStyle(.secondary)
            Button { onStep(-1) } label: {
                Image(systemName: "minus").frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .help(String(format: L10n.t("延后 %@ 秒显示"), stepText))
            TextField("0.0", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: 44)
                .onSubmit(onSubmit)
            Text(L10n.t("秒")).foregroundStyle(.secondary)
            Button { onStep(1) } label: {
                Image(systemName: "plus").frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .help(String(format: L10n.t("提前 %@ 秒显示"), stepText))
            if isNonZero {
                Button(L10n.t("重置"), action: onReset)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .settingsCardBackground(cornerRadius: 16)
        .help(L10n.t("正值提前显示，负值延后显示"))
        .fixedSize()
    }
}

/// 多选时右边那叠封面。
struct LyricsManagerStackedCovers: View {
    let urls: [URL?]

    var body: some View {
        ZStack {
            ForEach(Array(urls.prefix(4).enumerated()), id: \.offset) { index, url in
                LyricsManagerCover(url: url, size: 96, radius: 12)
                    .rotationEffect(.degrees(Double(index - 1) * 6))
                    .offset(x: CGFloat(index) * 16 - 24)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            }
        }
        .frame(width: 170, height: 120)
    }
}

/// 预览:左边时间、右边正文(开着译文 / 读音时下面再一行)。这首正在放时当前句亮起,有逐字时间的逐字染色;开着
/// 「跟随播放」就滚到视野里,手动滚一下就暂停跟随;指针停在时间上出现 ▶,点一下从这一句开始播放。
struct LyricsManagerPreviewList: View {
    let rows: [LyricsPreviewRow]
    let mode: LyricsManagerDisplayMode
    let isNowPlaying: Bool
    @Binding var follow: Bool
    let canSeek: Bool
    let onSeek: (Int) -> Void
    @StateObject private var playback = LyricsManagerPlaybackLine()

    var body: some View {
        let current = currentIndex
        let karaoke = karaokeSegments(at: current)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        let isCurrent = index == current
                        LyricsManagerPreviewRow(row: row, mode: mode, isCurrent: isCurrent,
                                                karaoke: isCurrent ? karaoke : nil,
                                                isPlaying: isCurrent && playback.isPlaying,
                                                pausedMs: isCurrent ? playback.pausedMs : nil,
                                                canSeek: canSeek, onSeek: onSeek)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
                .padding(.bottom, 60)
            }
            .modifier(LyricsManagerPauseFollowOnScroll(follow: $follow))
            .onChange(of: current) { _, _ in scrollToCurrent(proxy, animated: true) }
            .onChange(of: follow) { _, _ in scrollToCurrent(proxy, animated: true) }
            // 行换了也重新对一次位:换歌时新歌的行在预览出现之后才算好,切原文 / 译文 / 读音也换行;当前句的值可能没变,
            // 上面那条不会触发,列表就停在按旧行滚到的地方。
            .onChange(of: rows) { _, _ in scrollToCurrent(proxy, animated: false) }
            .onAppear { scrollToCurrent(proxy, animated: false) }
        }
    }

    /// 跟随时把当前句滚到中间。还没唱到第一句(前奏,或刚换歌、播放位置还没对上)时回到顶上:当前句变成「没有」时
    /// 不滚的话,列表会停在上一刻滚到的地方。
    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard follow, isNowPlaying, !rows.isEmpty else { return }
        let target = currentIndex ?? 0
        let anchor: UnitPoint = currentIndex == nil ? .top : .center
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: anchor) }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }

    /// 当前句是第几行:按字找、找不到按时间(见 LyricsPreviewText.currentRow)。一次 body 只算一次,传给各行。
    private var currentIndex: Int? {
        guard isNowPlaying, let current = playback.current else { return nil }
        return LyricsPreviewText.currentRow(times: rows.map(\.timeMs), texts: rows.map(\.text),
                                            lineTimeMs: current.timeMs, lineText: current.text)
    }

    /// 当前句的逐字段:这首正在放、当前句有逐字时间、跟预览这一行的字对得上时才有(见 11 章决策 71)。
    private func karaokeSegments(at index: Int?) -> [LyricsKaraokeSegment]? {
        guard let index, let words = playback.current?.words, !words.isEmpty else { return nil }
        return LyricsPreviewText.karaokeSegments(text: rows[index].text, words: words)
    }
}

/// 预览的一行。悬停状态在行自己身上:指针在时间上移动只重画这一行,不带着整张预览重算。
private struct LyricsManagerPreviewRow: View {
    let row: LyricsPreviewRow
    let mode: LyricsManagerDisplayMode
    let isCurrent: Bool
    /// 当前句的逐字段;nil = 整行高亮(不是当前句、整行歌词,或者跟播放那边的字对不上)。
    var karaoke: [LyricsKaraokeSegment]? = nil
    var isPlaying = false
    /// 暂停时的时间基准,只交给当前句(见 LyricsManagerKaraokeOverlay.pausedMs)。
    var pausedMs: Int? = nil
    let canSeek: Bool
    let onSeek: (Int) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            timeColumn
                .frame(width: 84, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                // 逐字染色时这一层整句画成淡的强调色,唱过的部分由 overlay 那层盖上实色;两层同一段字、同一个字号。
                Text(row.text.isEmpty ? " " : row.text)
                    .font(.system(size: 16, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .topLeading) {
                        if let segments = shownKaraoke {
                            LyricsManagerKaraokeOverlay(segments: segments, isPlaying: isPlaying, pausedMs: pausedMs)
                        }
                    }
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var secondary: String? {
        let text: String?
        switch mode {
        case .original: text = nil
        case .translation: text = row.translation
        case .romanization: text = row.romanization
        }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// 逐字染色要系统画得了(macOS 15 起)才铺,否则当前句整行强调色。
    private var shownKaraoke: [LyricsKaraokeSegment]? {
        LyricsManagerKaraokeOverlay.isSupported ? karaoke : nil
    }

    private var textColor: Color {
        if shownKaraoke != nil { return Color.accentColor.opacity(WordKaraokeGradient.dimOpacity) }
        return isCurrent ? Color.accentColor : Color.primary
    }

    /// ▶ 画在时间左边留好的那一截里(overlay),不进排版:悬停前后这一格的大小和基线都一样。图标进排版的话这一格会挪,
    /// 指针一出界图标就没了、又挪回来,悬停来回切换停不下来(见 11 章决策 61)。当前句只靠强调色标出,时间前不加图标。
    @ViewBuilder
    private var timeColumn: some View {
        if let t = row.timeMs {
            let showsHover = canSeek && hovered
            Button {
                onSeek(t)
            } label: {
                Text(LyricsPreviewText.timeLabel(t))
                    .font(.system(size: 13).monospacedDigit())
                    .underline(showsHover, color: Color.accentColor.opacity(0.6))
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        if showsHover {
                            Image(systemName: "play.fill").font(.system(size: 8.5))
                        }
                    }
                    .foregroundStyle(isCurrent || showsHover ? Color.accentColor : Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(canSeek)
            .onHover { hovered = $0 }
            .help(canSeek ? L10n.t("从此句开始播放") : "")
        }
    }
}

/// 手动滚动预览就暂停「跟随播放」。滚动阶段的通知是 macOS 15 才有的,更早的系统上只能点按钮关。
private struct LyricsManagerPauseFollowOnScroll: ViewModifier {
    @Binding var follow: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting, follow { follow = false }
            }
        } else {
            content
        }
    }
}

/// 当前句逐字染色的上面那层:跟着播放时钟每秒重画三十次,只画唱过的部分,没唱到的透出底下那层淡色。逐帧变化只在
/// 这一层里、不进排版,预览列表不跟着每帧重新量尺寸(同歌词窗口,07 章决策 50)。画法要 `TextRenderer`,macOS 15 起才有。
private struct LyricsManagerKaraokeOverlay: View {
    let segments: [LyricsKaraokeSegment]
    let isPlaying: Bool
    /// 画面不直接用它,照样读协调器;它只是让这一层「输入变了」:暂停时时钟停着,暂停中拖进度、调偏移不改任何输入的话,
    /// 这一层不重画(同 KaraokeWordText.pausedMs)。
    let pausedMs: Int?

    static let isSupported: Bool = {
        if #available(macOS 15.0, *) { return true }
        return false
    }()

    var body: some View {
        if #available(macOS 15.0, *) {
            let text = segmentedText
            FrameTimeline(minimumInterval: WordKaraokeGradient.refreshInterval, paused: !isPlaying) { date in
                text
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .textRenderer(LyricsManagerKaraokeRenderer(segments: segments, ms: Self.currentMs(at: date)))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// 每一段挂上自己的序号,画的时候按序号找时间。用插值拼:`Text + Text` 在 macOS 26 SDK 里已弃用。
    private var segmentedText: Text {
        segments.indices.reduce(Text(verbatim: "")) { text, index in
            let part = Text(verbatim: segments[index].text)
                .customAttribute(LyricsManagerKaraokeSegmentIndex(value: index))
            return Text("\(text)\(part)")
        }
    }

    /// 跟歌词窗口逐字填色同一条时间基准(含歌词偏移);暂停时 anchor 是 nil,退到暂停位置(同 KaraokeWordText)。
    private static func currentMs(at date: Date) -> Int {
        let coordinator = PlaybackCoordinator.shared
        return (coordinator.anchor?.extrapolatedPositionMs(now: date) ?? coordinator.pausedPositionMs ?? 0)
            + coordinator.currentLyricsOffsetMs
    }
}

/// 逐字染色那一层里,一段字是第几段。
private struct LyricsManagerKaraokeSegmentIndex: TextAttribute {
    let value: Int
}

/// 逐字染色那一层的画法:每一段按唱它的那个字此刻唱到哪,唱过的部分画实色,没唱到的不画,交界处是跟各处同一条软边
/// (`KaraokeFill`)。一段可能被字体回退拆成几个 run(汉字和它后面的空格就是两个),软边按这一段在这一行上的整个横向
/// 范围铺,不按 run 各铺各的。
@available(macOS 15.0, *)
private struct LyricsManagerKaraokeRenderer: TextRenderer {
    let segments: [LyricsKaraokeSegment]
    let ms: Int

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let band = KaraokeFill.wordEdgeSoftenBand
        for line in layout {
            var spans: [Int: (minX: CGFloat, maxX: CGFloat)] = [:]
            for run in line {
                guard let index = run[LyricsManagerKaraokeSegmentIndex.self]?.value else { continue }
                let rect = run.typographicBounds.rect
                let span = spans[index]
                spans[index] = (min(span?.minX ?? rect.minX, rect.minX), max(span?.maxX ?? rect.maxX, rect.maxX))
            }
            for run in line {
                guard let index = run[LyricsManagerKaraokeSegmentIndex.self]?.value,
                      segments.indices.contains(index), let span = spans[index] else { continue }
                let segment = segments[index]
                let fraction = KaraokeFill.fillFraction(startMs: segment.startMs, durationMs: segment.durationMs, atMs: ms)
                let left = fraction - band
                let right = fraction + band
                if right <= 0 { continue }
                if left >= 1 {
                    ctx.draw(run)
                    continue
                }
                let rect = run.typographicBounds.rect
                let stops = KaraokeFill.stops(left: left, right: right).map {
                    Gradient.Stop(color: .black.opacity($0.intensity), location: $0.location)
                }
                var masked = ctx
                masked.clipToLayer { mask in
                    // 往外放一圈:伸出排版框的字形(重音符号、斜体的尾巴)不能被裁掉。
                    mask.fill(Path(rect.insetBy(dx: -rect.height, dy: -rect.height)),
                              with: .linearGradient(Gradient(stops: stops),
                                                    startPoint: CGPoint(x: span.minX, y: rect.midY),
                                                    endPoint: CGPoint(x: span.maxX, y: rect.midY)))
                }
                masked.draw(run)
            }
        }
    }
}

/// 逐句格子里焦点在哪一格:第几句的正文,或挂在它下面的译文 / 读音。
enum LyricsManagerLineFocus: Hashable {
    case main(Int)
    case secondary(Int)

    var line: Int {
        switch self {
        case let .main(index), let .secondary(index): return index
        }
    }
}

/// 「编辑歌词」的逐句格子:左边时间(逐字歌词上锁,只改字;整行歌词点时间就能改),右边一句一格,开着译文 / 读音时
/// 下面再一格。改过的格子标强调色,行尾「还原」只还原这一句。↑↓ 换句,Tab / ⇧Tab 到下一格 / 上一格。
///
/// 只有正在编辑的那一句是输入框,其余画成同样大小的文字,点上去才换成输入框、光标落在点的那个字上。每句都做成输入框的话
/// 滚动时边滚边建输入框,主线程开销是文字的三到五倍,会掉帧(见 11 章决策 65)。一进来就把光标放进一句,读屏把静态的格子
/// 当按钮读:只用键盘、读屏也能开始改(见 11 章决策 92)。
struct LyricsManagerLineEditor: View {
    let main: LyricsEditableLines
    let mainBase: LyricsEditableLines
    let secondary: LyricsEditableLines?
    let secondaryBase: LyricsEditableLines?
    let timeLocked: Bool
    let onMainText: (Int, String) -> Void
    let onMainStamps: (Int, String) -> Void
    let onSecondaryText: (Int, String) -> Void
    let onRevert: (Int) -> Void
    var focus: FocusState<LyricsManagerLineFocus?>.Binding
    /// 编辑的是正在放的那首:正在唱的那一句的时间和正文标强调色(见 11 章决策 81)。
    var isNowPlaying = false
    @StateObject private var playback = LyricsManagerPlaybackLine()
    @State private var editingStamps: Int?
    @State private var stampDraft = ""
    @FocusState private var stampFieldFocused: Bool
    /// 回车时时间戳不合法:接下来那一下失焦不当成「点到别处」,框留着接着改。
    @State private var stampSubmitRejected = false
    /// 画成输入框的那一句。跟焦点分开记:焦点值先设、输入框随后才出现的话,焦点落不上去(离屏量过),
    /// 所以先把这一句换成输入框,下一拍再给焦点(activate)。
    @State private var activeLine: Int?
    /// 要滚到的那一句:键盘换到看不见的那一句时先滚过去,输入框才建得出来。
    @State private var scrollRequest: Int?
    /// 点在文字上那一刻算出的光标位置;那一格换成输入框、拿到焦点之后放过去。text 用来认第一响应者是不是这一格。
    @State private var pendingCaret: (field: LyricsManagerLineFocus, offset: Int, text: String)?
    private static let cellInset: CGFloat = 8

    private var rows: [Int] { main.lines.indices.filter { !main.lines[$0].isBlank } }

    /// 正在唱的是哪一句(main 里的下标),找法同预览(LyricsPreviewText.currentRow)。
    private var currentLine: Int? {
        guard isNowPlaying, let current = playback.current else { return nil }
        let indices = rows
        let found = LyricsPreviewText.currentRow(times: indices.map { main.lines[$0].timeMs },
                                                 texts: indices.map { main.lines[$0].text },
                                                 lineTimeMs: current.timeMs, lineText: current.text)
        return found.map { indices[$0] }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let current = currentLine
                    let changed = changedLines
                    ForEach(rows, id: \.self) { index in
                        row(index, isCurrent: index == current, changed: changed)
                            .id(index)
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 120)
            }
            .onChange(of: scrollRequest) { _, line in
                guard let line else { return }
                proxy.scrollTo(line)
                scrollRequest = nil
            }
            .onChange(of: focus.wrappedValue) { _, field in
                guard let field else { return }
                if activeLine != field.line { activeLine = field.line }
                placePendingCaret(in: field)
            }
            // 焦点离开时间戳输入框(点到别处):合法就照样改上,不合法当没改。
            .onChange(of: stampFieldFocused) { _, focused in
                guard !focused, !stampSubmitRejected, let index = editingStamps else { return }
                if LyricsEditableLines.isValidStamps(stampDraft) { onMainStamps(index, stampDraft) }
                editingStamps = nil
            }
            .onAppear(perform: activateInitialLine)
        }
    }

    /// 哪几句改过或是新加的(正文、挂在下面的译文 / 读音),按行对齐算,不按下标(见 LyricsEditableLines.alignment)。
    private var changedLines: (main: Set<Int>, secondary: Set<Int>) {
        let changedMain = Set(main.changedIndices(from: mainBase))
        guard let secondary, let secondaryBase else { return (changedMain, []) }
        return (changedMain, Set(secondary.changedIndices(from: secondaryBase)))
    }

    /// 一进逐句编辑就把光标放进一句(正在唱的那句,没有就第一句)的句尾:只用键盘也能直接改;放在句尾、不全选,
    /// 不然一敲就把整句盖掉。
    private func activateInitialLine() {
        guard activeLine == nil, let index = currentLine ?? rows.first else { return }
        let text = main.lines[index].text
        pendingCaret = (.main(index), (text as NSString).length, text)
        activate(.main(index))
    }

    private func secondaryIndex(for index: Int) -> Int? {
        guard let secondary, let t = main.lines[index].timeMs else { return nil }
        return secondary.index(matching: t)
    }

    private func row(_ index: Int, isCurrent: Bool, changed: (main: Set<Int>, secondary: Set<Int>)) -> some View {
        let line = main.lines[index]
        let mainChanged = changed.main.contains(index)
        let sIndex = secondaryIndex(for: index)
        let secondaryChanged = sIndex.map { changed.secondary.contains($0) } ?? false
        let active = activeLine == index
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            stampColumn(index: index, line: line, isCurrent: isCurrent)
                .frame(width: 84, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                cell(.main(index), text: line.text, changed: mainChanged, size: 15, active: active,
                     isCurrent: isCurrent) { onMainText(index, $0) }
                if let sIndex, let secondary {
                    cell(.secondary(index), text: secondary.lines[sIndex].text, changed: secondaryChanged, size: 12.5,
                         active: active) { onSecondaryText(sIndex, $0) }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            if mainChanged || secondaryChanged {
                Button { onRevert(index) } label: {
                    Label(L10n.t("还原"), systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.t("将此句恢复为编辑前的内容"))
            }
            Spacer(minLength: 0)
        }
    }

    /// 正在编辑的那一句是输入框,别的句子画成文字;两者行高、字形位置一致,换的那一下不跳。整格(含内边距)都能点。
    @ViewBuilder
    private func cell(_ field: LyricsManagerLineFocus, text: String, changed: Bool, size: CGFloat, active: Bool,
                      isCurrent: Bool = false, onChange: @escaping (String) -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let box = Group {
            if active {
                TextField("", text: Binding(get: { text }, set: onChange))
                    .textFieldStyle(.plain)
                    .focused(focus, equals: field)
                    .onKeyPress(phases: [.down, .repeat]) { handleKey($0, at: field) }
            } else {
                // 行高钉成输入框的行高:中文回落字体的行高比系统字体高 1pt,不钉住的话点进去那一句会跳一下。
                Text(text.isEmpty ? " " : text)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: Self.lineHeight(size), maxHeight: Self.lineHeight(size),
                           alignment: .leading)
            }
        }
        .font(.system(size: size))
        .padding(.horizontal, Self.cellInset)
        .padding(.vertical, 4)
        .background(shape.fill(changed ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.045)))
        .overlay(shape.strokeBorder(changed ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                                    lineWidth: changed ? 1 : 0.5))
        if active {
            box
        } else {
            // 读屏把它当按钮读,按一下跟点一下一样换成输入框(光标在句尾)。
            box
                .contentShape(shape)
                .onTapGesture { location in
                    pendingCaret = (field, Self.characterOffset(in: text, size: size, x: location.x - Self.cellInset), text)
                    activate(field)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    pendingCaret = (field, (text as NSString).length, text)
                    activate(field)
                }
        }
    }

    /// 先把这一句换成输入框(必要时滚过去),下一拍再给焦点。
    private func activate(_ field: LyricsManagerLineFocus) {
        activeLine = field.line
        scrollRequest = field.line
        DispatchQueue.main.async { focus.wrappedValue = field }
    }

    @MainActor private static var lineHeights: [CGFloat: CGFloat] = [:]

    /// plain 输入框一行的高度:系统字体的默认行高,按字号记下来。
    @MainActor private static func lineHeight(_ size: CGFloat) -> CGFloat {
        if let height = lineHeights[size] { return height }
        let height = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size))
        lineHeights[size] = height
        return height
    }

    /// 点在文字上的横坐标对应第几个字(UTF-16 位置,跟输入框的选区同一个单位)。
    private static func characterOffset(in text: String, size: CGFloat, x: CGFloat) -> Int {
        let length = (text as NSString).length
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]))
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        return index == kCFNotFound ? length : min(max(index, 0), length)
    }

    /// 换成输入框、拿到焦点之后把光标放到点的那个字上。拿焦点时系统会先全选,所以等下一拍再放;第一响应者的内容
    /// 跟这一格对不上(焦点还没过去)就再等一拍,还对不上就不动。
    private func placePendingCaret(in field: LyricsManagerLineFocus) {
        guard let pending = pendingCaret else { return }
        pendingCaret = nil
        guard pending.field == field else { return }
        func place(retries: Int) {
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == pending.text else {
                    if retries > 0 { place(retries: retries - 1) }
                    return
                }
                editor.setSelectedRange(NSRange(location: min(pending.offset, (editor.string as NSString).length), length: 0))
            }
        }
        place(retries: 1)
    }

    /// ↑↓ 到上一句 / 下一句的同一格(那一句没有译文格时落到正文);Tab / ⇧Tab 按「正文 → 译文 → 下一句正文」走。
    private func handleKey(_ press: KeyPress, at field: LyricsManagerLineFocus) -> KeyPress.Result {
        switch press.key {
        case .downArrow: return moveLine(from: field, by: 1)
        case .upArrow: return moveLine(from: field, by: -1)
        case .tab: return moveField(from: field, forward: !press.modifiers.contains(.shift))
        default:
            // ⇧Tab 送来的是 backtab(U+0019)。
            return press.characters == "\u{19}" ? moveField(from: field, forward: false) : .ignored
        }
    }

    private func moveLine(from field: LyricsManagerLineFocus, by delta: Int) -> KeyPress.Result {
        guard let position = rows.firstIndex(of: field.line) else { return .ignored }
        let next = position + delta
        guard rows.indices.contains(next) else { return .handled }
        let target = rows[next]
        if case .secondary = field, secondaryIndex(for: target) != nil {
            activate(.secondary(target))
        } else {
            activate(.main(target))
        }
        return .handled
    }

    /// 首尾再往外走交回系统(焦点去保存条的按钮)。
    private func moveField(from field: LyricsManagerLineFocus, forward: Bool) -> KeyPress.Result {
        let order = rows.flatMap { index -> [LyricsManagerLineFocus] in
            secondaryIndex(for: index) == nil ? [.main(index)] : [.main(index), .secondary(index)]
        }
        guard let position = order.firstIndex(of: field) else { return .ignored }
        let next = position + (forward ? 1 : -1)
        guard order.indices.contains(next) else { return .ignored }
        activate(order[next])
        return .handled
    }

    @ViewBuilder
    private func stampColumn(index: Int, line: LyricsEditableLines.Line, isCurrent: Bool) -> some View {
        let label = line.timeMs.map(LyricsPreviewText.timeLabel) ?? ""
        if timeLocked {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill").font(.system(size: 8.5))
                Text(label).font(.system(size: 13).monospacedDigit())
            }
            .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            .help(L10n.t("逐字歌词仅修改文字，时间保持不变"))
        } else if editingStamps == index {
            // 回车:合法才改上、收起;不合法响一声,留在框里接着改。Esc 放弃。焦点离开见 body 里那条 onChange。
            TextField("", text: $stampDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
                .focused($stampFieldFocused)
                .onSubmit {
                    guard LyricsEditableLines.isValidStamps(stampDraft) else {
                        stampSubmitRejected = true
                        NSSound.beep()
                        DispatchQueue.main.async {
                            stampFieldFocused = true
                            stampSubmitRejected = false
                        }
                        return
                    }
                    onMainStamps(index, stampDraft)
                    editingStamps = nil
                }
                .onExitCommand { editingStamps = nil }
        } else if !line.stamps.isEmpty {
            Button {
                stampDraft = line.stamps
                editingStamps = index
                DispatchQueue.main.async { stampFieldFocused = true }
            } label: {
                Text(label)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .underline(true, color: Color.secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .help(L10n.t("修改此句的时间戳"))
        }
    }
}
