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
        case .all: return L10n.t("全部来源")
        case .none: return L10n.t("无来源")
        case .named(let s): return sourceDisplayName(s) // 展示用中文名,matches(_:) 仍按原始的 s 比较
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

// 歌手筛选下拉按"主歌手"合并——同一位歌手的合唱曲目(如"宇多田ヒカル & Skrillex")
// 不应该在下拉里单独占一行,应该并进"宇多田ヒカル"那一项里;选中某位歌手后,连同他/她
// 参与的合唱曲目也一起展示出来,不是只看完全同名的条目。分隔符跟 collector/match.go 的
// artistCreditParts 用同一套(/、&,，),取分割后的第一段作为归并键,大小写/首尾空白
// 不影响判定,但下拉里展示、真正拿去比较分组的是原始未分割的 artist 全文里截出来的
// 第一段(保留原始大小写/写法,不额外转小写)。
func primaryArtist(_ full: String) -> String {
    let seps = CharacterSet(charactersIn: "/、&,，")
    let first = full.components(separatedBy: seps).first ?? full
    return first.trimmingCharacters(in: .whitespaces)
}

// 每个歌词源一个固定色,列表/详情页共用,方便肉眼快速扫源(不是随手配的——网易云红、
// QQ音乐绿、酷狗蓝、LRCLIB紫,分别贴近各自品牌主色,"无来源"用中性灰)。
//
// 2026-07-16:从 private 改成 internal——"歌词"设置分类里新增的来源启用/优先级排序
// UI(FeatureSettingsStore.swift 的 LyricsSource 枚举)要复用同一套名字/颜色,不想在
// 第二个地方再维护一份一模一样的 switch,两边一旦某天改了色值/译名容易漂移。
func sourceColor(_ source: String) -> Color {
    switch source {
    case "netease": return .red
    case "qq": return .green
    case "kugou": return .cyan
    case "lrclib": return .purple
    default: return .secondary
    }
}

// 歌词来源展示名——网易云音乐/QQ音乐/酷狗音乐是国内用户认得出的中文写法;LRCLIB 是纯
// 西方的开源歌词库,没有约定俗成的中文名,保留英文原名(用户明确要求"只有英文的就用英文",
// 不强行硬翻一个不存在的中文名)。
func sourceDisplayName(_ source: String) -> String {
    switch source {
    case "netease": return L10n.t("网易云音乐")
    case "qq": return L10n.t("QQ音乐")
    case "kugou": return L10n.t("酷狗音乐")
    case "lrclib": return "LRCLIB"
    case "": return L10n.t("无来源")
    default: return source
    }
}

// 歌名/歌手/专辑/来源四列表头和每一行列表项共用同一组列宽——歌名是主列、拿剩余空间,
// 后三列固定宽度+单行截断,这样表头文字和每行内容的起始位置对得上。
private enum LyricsListColumns {
    static let artistWidth: CGFloat = 96
    static let albumWidth: CGFloat = 110
    static let sourceWidth: CGFloat = 68
}

// 歌词管理窗口:浏览目前 collector 缓存了哪些歌的歌词、来源是什么,支持手动纠正内容、
// 联网重新搜索候选歌词(见 LyricsSearchSheet/LyricsSearchService)、单独移除逐字时间轴、
// 或整条删除(强制下次播放重新解析)。改动通过 EnrichCacheStore 落盘+踢一脚重启
// collector 生效(见该文件顶部注释,解释为什么必须这么做而不是直接改内存)。
struct LyricsManagerView: View {
    @ObservedObject private var store = EnrichCacheStore.shared
    // 只为了让这个独立窗口(跟 SettingsView 不在同一棵视图树里)在手动切换语言时
    // 重新渲染——这个窗口原来不观察 AppSettings,加了才会响应 appLanguage 的变化。
    @ObservedObject private var languageSettings = AppSettings.shared
    @State private var searchText = ""
    @State private var selectedKey: String?
    @State private var editedLyrics = ""
    @State private var editedTr = ""
    @State private var editedRoma = ""
    @State private var showDeleteConfirm = false
    @State private var showSearchSheet = false
    @State private var sourceFilter: SourceFilter = .all
    @State private var timingFilter: TimingFilter = .all
    @State private var manualOnly = false
    @State private var missingLyricsOnly = false
    // nil = 全部歌手/专辑。跟 SourceFilter/TimingFilter 不同,歌手/专辑的候选值不是固定
    // 的几种,是从当前缓存数据里现算出来的(见 distinctArtists/distinctAlbums),所以
    // 这两个直接用 String? 而不是另建一个枚举。
    @State private var artistFilter: String?
    @State private var albumFilter: String?
    // 点了"刷新"却没有任何肉眼可见的变化时(比如内容根本没变),用户很容易以为按钮没
    // 反应——短暂切换成"已刷新"+对勾图标给个明确反馈,1秒后自动变回去。
    @State private var showRefreshedFeedback = false

    private var hasActiveFilters: Bool {
        sourceFilter != .all || timingFilter != .all || manualOnly || missingLyricsOnly
            || artistFilter != nil || albumFilter != nil
    }

    private var distinctArtists: [String] {
        Array(Set(store.summaries.map { primaryArtist($0.artist) })).sorted()
    }

    // 同一张专辑在不同缓存条目里,专辑名偶尔因为各自歌词源的候选写法大小写不一致
    // (实测坐实:"BLOOD ON THE DANCE FLOOR/ HIStory In The Mix" vs "Blood on the Dance
    // Floor/ HIStory in the Mix"、"HIStory Continues" vs "History Continues")而长得不
    // 一样。归并键统一转小写比较,取第一次遇到(按 summaries 已有的排序)那条的原始写法
    // 当这一组的统一展示文案——不只是筛选下拉要合并,列表每一行、详情页头部凡是要展示
    // 专辑名的地方都用这份映射,同一张专辑不管底层哪条记录的原始大小写是什么,肉眼看到
    // 的都是同一种写法。跟 primaryArtist 合并合唱曲目是同一个"归并键跟展示值分开"的
    // 思路,只是这里归并键是转小写而不是按分隔符取第一段。
    private var albumDisplayNames: [String: String] {
        var seen: [String: String] = [:] // 小写归并键 -> 第一次出现时的原始写法
        for s in store.summaries where !s.album.isEmpty {
            let key = s.album.lowercased()
            if seen[key] == nil { seen[key] = s.album }
        }
        return seen
    }

    private var distinctAlbums: [String] {
        Array(Set(albumDisplayNames.values)).sorted()
    }

    private func albumDisplay(_ album: String) -> String {
        albumDisplayNames[album.lowercased()] ?? album
    }

    private var filtered: [EnrichCacheStore.Summary] {
        store.summaries.filter { s in
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                guard s.artist.lowercased().contains(q) || s.title.lowercased().contains(q) else { return false }
            }
            if let artistFilter, primaryArtist(s.artist) != artistFilter { return false }
            // 大小写不敏感比较——albumFilter 存的是 distinctAlbums 归并后选中的那个
            // 展示写法,同一张专辑大小写不同的条目(s.album)也要匹配上,不能要求逐字相等。
            if let albumFilter, s.album.lowercased() != albumFilter.lowercased() { return false }
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
        artistFilter = nil
        albumFilter = nil
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)

                Picker(L10n.t("歌手"), selection: $artistFilter) {
                    Text(L10n.t("全部歌手")).tag(String?.none)
                    ForEach(distinctArtists, id: \.self) { a in Text(a).tag(String?.some(a)) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)

                Picker(L10n.t("专辑"), selection: $albumFilter) {
                    Text(L10n.t("全部专辑")).tag(String?.none)
                    ForEach(distinctAlbums, id: \.self) { a in Text(a).tag(String?.some(a)) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)

                Spacer()
            }

            HStack(spacing: 12) {
                Picker(L10n.t("来源"), selection: $sourceFilter) {
                    ForEach(SourceFilter.all_) { f in Text(f.label).tag(f) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 130)

                Picker(L10n.t("时间轴"), selection: $timingFilter) {
                    ForEach(TimingFilter.allCases) { f in Text(L10n.t(f.rawValue)).tag(f) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 100)

                Divider().frame(height: 14)

                Toggle(L10n.t("仅人工修正"), isOn: $manualOnly)
                Toggle(L10n.t("仅无歌词"), isOn: $missingLyricsOnly)

                Spacer()

                if hasActiveFilters {
                    Button(L10n.t("清除筛选"), action: resetFilters)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    // 列名表头——歌名/歌手/专辑/来源,跟 LyricsManagerRow 共用 LyricsListColumns 的列宽
    // 常量,保证表头文字跟每行对应列对得齐。水平内边距(12pt)特意跟 List(.inset 样式)
    // 默认给每行内容的左右留白对齐,不然表头会跟下面的行错位。
    private var listColumnHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.t("歌名")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.t("歌手")).frame(width: LyricsListColumns.artistWidth, alignment: .leading)
            Text(L10n.t("专辑")).frame(width: LyricsListColumns.albumWidth, alignment: .leading)
            Text(L10n.t("来源")).frame(width: LyricsListColumns.sourceWidth, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    var body: some View {
        NavigationSplitView {
            // ScrollViewReader 挪到包住整个侧栏(而不是只包 List)——工具栏的"回到当前播放"
            // 按钮跟 List 是 VStack 里的兄弟节点、跟 .toolbar 修饰符也不在同一层,要拿到
            // scrollProxy 就必须让它在这两者共同的外层作用域里可见,所以让 ScrollViewReader
            // 的闭包整个包住 VStack+.toolbar,而不是像原来那样只包 List 本身。ScrollViewReader
            // 只是个透明包装,不影响布局,包多包少视觉上没有区别。
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    filterBar
                    Divider()
                    listColumnHeader
                    Divider()
                    List(filtered, selection: $selectedKey) { summary in
                        LyricsManagerRow(summary: summary, albumDisplayName: albumDisplay(summary.album))
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .onAppear {
                        // reload 必须先于定位——刚打开窗口时 summaries 可能还是上次
                        // 关闭时的旧内容(或空的),定位逻辑要按最新磁盘内容匹配当前
                        // 播放的这首歌。reload() 2026-07-17 起改成 async(读文件+解析
                        // 挪到后台线程,避免缓存文件变大之后开窗卡一下),这里用 Task
                        // 包一层、await 完了再定位,保持"先 reload 再定位"这个顺序不变。
                        Task {
                            await store.reload()
                            focusCurrentlyPlaying(scrollProxy: scrollProxy)
                        }
                    }
                }
                .searchable(text: $searchText, prompt: L10n.t("搜索歌手/歌名"))
                .navigationTitle(L10n.t("歌词管理"))
                .navigationSubtitle(String(format: L10n.t("%@ / %@ 首"), "\(filtered.count)", "\(store.summaries.count)"))
                .toolbar {
                    ToolbarItem {
                        Button(action: refreshWithFeedback) {
                            Label(showRefreshedFeedback ? L10n.t("已刷新") : L10n.t("刷新"),
                                  systemImage: showRefreshedFeedback ? "checkmark" : "arrow.clockwise")
                        }
                    }
                    ToolbarItem {
                        // 跟开窗时自动定位复用同一个 focusCurrentlyPlaying,但 force:true——
                        // 那个 selectedKey==nil 的门槛是给"刚开窗别覆盖用户已经选中的行"这个
                        // 场景挡的,手动点这个按钮时用户往往正选着别的歌、就是想跳回来,不能
                        // 被同一个门槛拦住。
                        Button {
                            focusCurrentlyPlaying(scrollProxy: scrollProxy, force: true)
                        } label: {
                            Label(L10n.t("回到当前播放"), systemImage: "location.fill")
                        }
                    }
                }
                // 列表这一栏(歌名/歌手/专辑/来源四列)给个够宽的默认/理想宽度——不然
                // NavigationSplitView 默认分给侧栏的宽度偏窄,歌名(尤其是带 feat./remix
                // 后缀的长标题)会被裁成省略号。630pt 是用户截图里实际截到的、歌名基本能
                // 完整露出来的比例,拿来当 ideal 默认值。
                .navigationSplitViewColumnWidth(min: 480, ideal: 630, max: 900)
            }
        } detail: {
            if let key = selectedKey, let summary = store.summaries.first(where: { $0.key == key }) {
                detailView(key: key, summary: summary)
            } else {
                ContentUnavailableView(L10n.t("选择左侧一首歌"), systemImage: "text.quote")
            }
        }
        .frame(minWidth: 780, idealWidth: 1040, minHeight: 540, idealHeight: 640)
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
    private func refreshWithFeedback() {
        Task {
            await store.reload()
            withAnimation { showRefreshedFeedback = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showRefreshedFeedback = false }
        }
    }

    // force:true 是给工具栏"回到当前播放"按钮用的——绕开"已经选中别的行就不动"这道
    // 只为"开窗自动定位"场景设的门槛(见调用点注释)。找不到当前播放曲目的缓存条目时
    // 两种调用方式都一样静默不做任何事,不额外弹提示——开窗自动定位场景本来就不该弹,
    // 手动点按钮那次不做区分只是图简单,真找不到时用户自己也看得出列表没跳。
    private func focusCurrentlyPlaying(scrollProxy: ScrollViewProxy, force: Bool = false) {
        guard force || selectedKey == nil else { return }
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

                editorSection(title: L10n.t("歌词(LRC)"), icon: "text.alignleft", text: $editedLyrics, minHeight: 220, monospaced: true)
                editorSection(title: L10n.t("译文"), icon: "character.book.closed", text: $editedTr, minHeight: 70, monospaced: false)
                editorSection(title: L10n.t("罗马音"), icon: "textformat.abc", text: $editedRoma, minHeight: 70, monospaced: false)

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
            String(format: L10n.t("确定要删除「%@ - %@」的本地记录吗?"), summary.artist, summary.title),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("删除"), role: .destructive) {
                Task { await store.delete(key: key) }
                selectedKey = nil
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(L10n.t("已导出到本地的歌词文件也会一并删除,下次播放这首歌会重新走一遍匹配解析,不保证一定能找到一样的歌词。"))
        }
        .sheet(isPresented: $showSearchSheet) {
            // 采纳候选直接保存,不需要再手动点"保存修改"——用户反馈选了以为就存上了,
            // 结果只是填进了编辑框,得再点一下保存才真正落盘,体验上是个多余的确认步骤。
            LyricsSearchSheet(artist: summary.artist, title: summary.title, album: summary.album) { candidate in
                editedLyrics = candidate.lyrics
                editedTr = candidate.lyricsTr
                editedRoma = candidate.lyricsRoma
                Task {
                    await store.saveEdit(key: key, lyrics: candidate.lyrics, tr: candidate.lyricsTr, roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC, source: candidate.source)
                }
            }
        }
    }

    private func header(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title).font(.title2.weight(.bold))
                Text(summary.artist).font(.title3).foregroundStyle(.secondary)
                if !summary.album.isEmpty {
                    Text(albumDisplay(summary.album)).font(.callout).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            // 都挪到顶部——常用操作,原来放在底部操作栏每次都要翻到页面最下面才能点。
            // .fixedSize() 强制这一组按钮永远按自己的完整期望宽度渲染,不参与跟左边
            // 歌名/歌手/专辑那个 VStack 的空间压缩——之前歌名一长(比如带 feat./罗马数字
            // 后缀),会连带把这两个按钮的文字挤到只剩省略号("联网搜..."/"删除本...")。
            // 现在反过来:空间不够时,先紧着按钮拿够它们要的全部宽度,歌名那边(本来就
            // 没有单行限制,靠 Text 自然换行)让出空间。
            HStack(spacing: 8) {
                Button {
                    showSearchSheet = true
                } label: {
                    Label(L10n.t("联网搜索候选歌词"), systemImage: "magnifyingglass")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(L10n.t("删除本地记录"), systemImage: "trash")
                }
            }
            .fixedSize()
        }
    }

    private func infoStrip(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 8) {
            InfoChip(
                icon: "arrow.down.circle",
                text: sourceDisplayName(summary.lyricsSource),
                tint: sourceColor(summary.lyricsSource)
            )
            InfoChip(
                icon: summary.hasWordTiming ? "text.word.spacing" : "text.alignleft",
                text: summary.hasWordTiming ? L10n.t("逐字时间轴") : L10n.t("整行歌词"),
                tint: summary.hasWordTiming ? .blue : .secondary
            )
            if summary.isManual {
                InfoChip(icon: "pencil.circle.fill", text: L10n.t("人工修正"), tint: .orange)
            }
            if !summary.hasLyrics {
                InfoChip(icon: "text.badge.xmark", text: L10n.t("无歌词"), tint: .red)
            }
            Spacer()
        }
    }

    private var wordTimingHint: some View {
        Label(
            L10n.t("这首歌带逐字时间轴,播放时优先用它渲染——下面直接改「歌词(LRC)」文本框不会生效。如需手改主歌词,请先点「移除逐字时间轴」。译文/罗马音编辑不受影响,随时生效。"),
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
            Button(L10n.t("保存修改")) {
                Task { await store.saveEdit(key: key, lyrics: editedLyrics, tr: editedTr, roma: editedRoma) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)

            if summary.hasWordTiming {
                Button(L10n.t("移除逐字时间轴")) {
                    Task { await store.removeWordTiming(key: key) }
                }
            }

            Spacer()
        }
    }

    private func loadDetail(key: String) {
        let d = store.detail(for: key)
        editedLyrics = d.lyrics
        editedTr = d.tr
        editedRoma = d.roma
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
    // 同一张专辑在不同条目里原始大小写可能不一致(见 LyricsManagerView.albumDisplayNames
    // 的注释),这里传入调用方算好的统一展示文案,而不是自己再拿 summary.album 原样显示。
    let albumDisplayName: String

    // 每行的图标槽位固定宽度——之前"人工修正"图标只在有的行才占位,导致有些行少一个
    // 图标,后面的内容整体往左挪一截,几行错落对不齐看着乱。改成图标槽位固定宽度(没有
    // 就用透明占位撑住位置,而不是整个不渲染),这样不管具体哪行有没有人工修正、是逐字
    // 还是整行,几行的图标起始位置都对得齐。这两个图标算是"歌名"这一列的附加信息(是否
    // 手工修正过/是逐字还是整行),跟着歌名走,不单独占一列——歌手/专辑/来源三列见
    // LyricsListColumns。
    private static let badgeIconWidth: CGFloat = 14

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(summary.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .opacity(summary.isManual ? 1 : 0)
                        .font(.caption2)
                        .frame(width: Self.badgeIconWidth)
                    Image(systemName: summary.hasWordTiming ? "text.word.spacing" : "text.alignleft")
                        .foregroundStyle(summary.hasWordTiming ? .blue : .secondary)
                        .font(.caption2)
                        .frame(width: Self.badgeIconWidth)
                }
                if !summary.hasLyrics {
                    Text(L10n.t("无歌词")).font(.caption2).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(summary.artist)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: LyricsListColumns.artistWidth, alignment: .leading)

            Text(albumDisplayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: LyricsListColumns.albumWidth, alignment: .leading)

            Text(sourceDisplayName(summary.lyricsSource))
                .font(.caption)
                .foregroundStyle(sourceColor(summary.lyricsSource))
                .lineLimit(1)
                .frame(width: LyricsListColumns.sourceWidth, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}
