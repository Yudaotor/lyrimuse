import SwiftUI

// 歌词来源筛选——collector 只会写入这四种(见 collector/enrich.go 的 lyricCandidate
// source 取值),"无来源"对应老缓存(lyrics_source 字段是 07-11 才加的,更早解析的
// 条目永久没有这个值,除非重新解析)。
private enum SourceFilter: Hashable, Identifiable {
    case all
    case named(String)
    case none

    static let all_: [SourceFilter] = [.all, .named("netease"), .named("qq"), .named("kugou"), .named("lrclib"), .none]

    var id: String { label }
    var label: String {
        switch self {
        case .all: return "全部来源"
        case .none: return "无来源"
        case .named(let s): return s
        }
    }

    func matches(_ source: String) -> Bool {
        switch self {
        case .all: return true
        case .none: return source.isEmpty
        case .named(let s): return source == s
        }
    }
}

private enum TimingFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case wordTiming = "仅逐字"
    case lineOnly = "仅整行"
    var id: String { rawValue }
}

// 每个歌词源一个固定色,列表/详情页共用,方便肉眼快速扫源(不是随手配的——网易云红、
// QQ音乐绿、酷狗蓝、LRCLIB紫,分别贴近各自品牌主色,"无来源"用中性灰)。
private func sourceColor(_ source: String) -> Color {
    switch source {
    case "netease": return .red
    case "qq": return .green
    case "kugou": return .cyan
    case "lrclib": return .purple
    default: return .secondary
    }
}

// 歌词管理窗口:浏览目前 collector 缓存了哪些歌的歌词、来源是什么,支持手动纠正内容、
// 联网重新搜索候选歌词(见 LyricsSearchSheet/LyricsSearchService)、单独移除逐字时间轴、
// 或整条删除(强制下次播放重新解析)。改动通过 EnrichCacheStore 落盘+踢一脚重启
// collector 生效(见该文件顶部注释,解释为什么必须这么做而不是直接改内存)。
struct LyricsManagerView: View {
    @ObservedObject private var store = EnrichCacheStore.shared
    @State private var searchText = ""
    @State private var selectedKey: String?
    @State private var editedLyrics = ""
    @State private var editedTr = ""
    @State private var editedRoma = ""
    @State private var showDeleteConfirm = false
    @State private var showSearchSheet = false
    // 只有从"联网搜索候选"整条采纳时才非空/置真——保存时据此决定要不要连
    // lyrics_yrc 一起换掉(见 EnrichCacheStore.saveEdit 注释)。纯手改文本框走
    // 默认的 4 参数 saveEdit,永远不碰这两个状态。
    @State private var pendingYRC = ""
    @State private var appliedFromSearch = false
    @State private var sourceFilter: SourceFilter = .all
    @State private var timingFilter: TimingFilter = .all
    @State private var manualOnly = false
    @State private var missingLyricsOnly = false

    private var hasActiveFilters: Bool {
        sourceFilter != .all || timingFilter != .all || manualOnly || missingLyricsOnly
    }

    private var filtered: [EnrichCacheStore.Summary] {
        store.summaries.filter { s in
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                guard s.artist.lowercased().contains(q) || s.title.lowercased().contains(q) else { return false }
            }
            guard sourceFilter.matches(s.lyricsSource) else { return false }
            switch timingFilter {
            case .all: break
            case .wordTiming: guard s.hasWordTiming else { return false }
            case .lineOnly: guard !s.hasWordTiming else { return false }
            }
            if manualOnly && !s.isManual { return false }
            if missingLyricsOnly && s.hasLyrics { return false }
            return true
        }
    }

    private func resetFilters() {
        sourceFilter = .all
        timingFilter = .all
        manualOnly = false
        missingLyricsOnly = false
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)

            Picker("来源", selection: $sourceFilter) {
                ForEach(SourceFilter.all_) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 130)

            Picker("时间轴", selection: $timingFilter) {
                ForEach(TimingFilter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 100)

            Divider().frame(height: 14)

            Toggle("仅人工修正", isOn: $manualOnly)
            Toggle("仅无歌词", isOn: $missingLyricsOnly)

            Spacer()

            if hasActiveFilters {
                Button("清除筛选", action: resetFilters)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                ScrollViewReader { scrollProxy in
                    List(filtered, selection: $selectedKey) { summary in
                        LyricsManagerRow(summary: summary)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .onAppear {
                        // reload 必须先于定位——刚打开窗口时 summaries 可能还是上次
                        // 关闭时的旧内容(或空的),定位逻辑要按最新磁盘内容匹配当前
                        // 播放的这首歌。
                        store.reload()
                        focusCurrentlyPlaying(scrollProxy: scrollProxy)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索歌手/歌名")
            .navigationTitle("歌词管理")
            .navigationSubtitle("\(filtered.count) / \(store.summaries.count) 首")
            .toolbar {
                ToolbarItem {
                    Button {
                        store.reload()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        } detail: {
            if let key = selectedKey, let summary = store.summaries.first(where: { $0.key == key }) {
                detailView(key: key, summary: summary)
            } else {
                ContentUnavailableView("选择左侧一首歌", systemImage: "text.quote")
            }
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    // 打开窗口时自动定位到当前正在播放的这首歌(如果它已经被缓存过)——跟
    // EnrichCacheStore.splitKey 用的是同一套 "歌手|歌名|专辑" 拼法,PlaybackCoordinator
    // 转发的 artist/title/album 本来就来自 media-control/relay,跟 collector 当初写入
    // 缓存时用的是同一份数据,能精确对上。selectedKey == nil 这个门槛只是防御性的——
    // Window scene 每次重新打开都是全新的 @State,首次 onAppear 时必然是 nil。
    //
    // 只在这里读一次 PlaybackCoordinator.shared 的当前值,不声明成 @ObservedObject——
    // 那个单例还同时发布 currentLine/anchor,播放中每秒 20 次刷新(本地模式的快速
    // 计时器),整个窗口订阅它会导致 body 跟着每秒重算 20 次,把手动点选/刷新按钮的
    // 交互直接闷在这阵持续重渲染里,表现成"点了跟没点一样"(实测坐实的真 bug,不是
    // 自动化环境的假象)。这里只需要开窗那一刻的快照,普通函数内直接访问单例属性即可,
    // 不用建立订阅。
    private func focusCurrentlyPlaying(scrollProxy: ScrollViewProxy) {
        guard selectedKey == nil else { return }
        let playback = PlaybackCoordinator.shared
        let key = "\(playback.artist)|\(playback.title)|\(playback.album)"
        guard store.summaries.contains(where: { $0.key == key }) else { return }
        selectedKey = key
        DispatchQueue.main.async {
            withAnimation { scrollProxy.scrollTo(key, anchor: .center) }
        }
    }

    @ViewBuilder
    private func detailView(key: String, summary: EnrichCacheStore.Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(summary)
                infoStrip(summary)

                if summary.hasWordTiming {
                    wordTimingHint
                }

                editorSection(title: "歌词(LRC)", icon: "text.alignleft", text: $editedLyrics, minHeight: 220, monospaced: true)
                editorSection(title: "译文", icon: "character.book.closed", text: $editedTr, minHeight: 70, monospaced: false)
                editorSection(title: "罗马音", icon: "textformat.abc", text: $editedRoma, minHeight: 70, monospaced: false)

                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                actionsRow(key: key, summary: summary)
            }
            .padding(20)
        }
        .onAppear { loadDetail(key: key) }
        .onChange(of: key) { _, newKey in loadDetail(key: newKey) }
        .confirmationDialog(
            "确定要删除「\(summary.artist) - \(summary.title)」的缓存吗?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                store.delete(key: key)
                selectedKey = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次播放这首歌会重新走一遍匹配解析,不保证一定能找到一样的歌词。")
        }
        .sheet(isPresented: $showSearchSheet) {
            LyricsSearchSheet(artist: summary.artist, title: summary.title, album: summary.album) { candidate in
                editedLyrics = candidate.lyrics
                editedTr = candidate.lyricsTr
                editedRoma = candidate.lyricsRoma
                pendingYRC = candidate.lyricsYRC
                appliedFromSearch = true
            }
        }
    }

    private func header(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title).font(.title2.weight(.bold))
                Text(summary.artist).font(.title3).foregroundStyle(.secondary)
                if !summary.album.isEmpty {
                    Text(summary.album).font(.callout).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            // 挪到顶部——常用操作,原来放在底部操作栏每次都要翻到页面最下面才能点。
            Button {
                showSearchSheet = true
            } label: {
                Label("联网搜索候选歌词", systemImage: "magnifyingglass")
            }
        }
    }

    private func infoStrip(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 8) {
            InfoChip(
                icon: "arrow.down.circle",
                text: summary.lyricsSource.isEmpty ? "无来源" : summary.lyricsSource,
                tint: sourceColor(summary.lyricsSource)
            )
            InfoChip(
                icon: summary.hasWordTiming ? "text.word.spacing" : "text.alignleft",
                text: summary.hasWordTiming ? "逐字时间轴" : "整行歌词",
                tint: summary.hasWordTiming ? .blue : .secondary
            )
            if summary.isManual {
                InfoChip(icon: "pencil.circle.fill", text: "人工修正", tint: .orange)
            }
            if !summary.hasLyrics {
                InfoChip(icon: "text.badge.xmark", text: "无歌词", tint: .red)
            }
            Spacer()
        }
    }

    private var wordTimingHint: some View {
        Label(
            "这首歌带逐字时间轴,播放时优先用它渲染——下面直接改「歌词(LRC)」文本框不会生效。如需手改主歌词,请先点「移除逐字时间轴」。译文/罗马音编辑不受影响,随时生效。",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func editorSection(title: String, icon: String, text: Binding<String>, minHeight: CGFloat, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(monospaced ? .system(.body, design: .monospaced) : .system(.body))
                .frame(minHeight: minHeight)
                .padding(8)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func actionsRow(key: String, summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 10) {
            Button("保存修改") {
                store.saveEdit(key: key, lyrics: editedLyrics, tr: editedTr, roma: editedRoma, yrc: appliedFromSearch ? pendingYRC : nil)
                appliedFromSearch = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)

            if summary.hasWordTiming {
                Button("移除逐字时间轴") {
                    store.removeWordTiming(key: key)
                }
            }

            Spacer()

            Button("删除此缓存", role: .destructive) {
                showDeleteConfirm = true
            }
        }
    }

    private func loadDetail(key: String) {
        let d = store.detail(for: key)
        editedLyrics = d.lyrics
        editedTr = d.tr
        editedRoma = d.roma
        pendingYRC = ""
        appliedFromSearch = false
    }
}

private struct InfoChip: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct LyricsManagerRow: View {
    let summary: EnrichCacheStore.Summary

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(summary.artist) - \(summary.title)")
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !summary.hasLyrics {
                    Text("无歌词").font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                if summary.isManual {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                }
                if summary.hasWordTiming {
                    Image(systemName: "text.word.spacing").foregroundStyle(.blue)
                }
                Text(summary.lyricsSource.isEmpty ? "?" : summary.lyricsSource)
                    .foregroundStyle(sourceColor(summary.lyricsSource))
            }
            .font(.caption2)
        }
        .padding(.vertical, 3)
    }
}
