import SwiftUI
import LyrimuseCore

// 歌词来源筛选——collector 只会写入这五种(见 collector/enrich.go 的 lyricCandidate
// source 取值),"无来源"对应老缓存(lyrics_source 字段是后来才加的,更早解析的
// 条目永久没有这个值,除非重新解析)。
private enum SourceFilter: Hashable, Identifiable {
    case all
    case named(String)
    case none

    static let all_: [SourceFilter] = [.all, .named("netease"), .named("qq"), .named("kugou"), .named("musixmatch"), .named("lrclib"), .none]

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

// 繁体折成简体,只用来算"是不是同一个人/同一张专辑"的归并键,不改动任何展示文案——
// 跟 collector 那边 match.go/t2s.go 的 toSimplified 是同一个目的,但这边是 Swift 代码,
// 没有引入 gocc 那类第三方库,直接用 Foundation/ICU 内置的 "Traditional-Simplified"
// transform 就能做,不需要额外依赖(2026-07-30 实测坐实:"100種生活"/"100种生活" 这类
// 繁简差一个字的专辑名,之前的归并键只转小写、不管繁简,被当成两张不同专辑,在筛选下拉
// 里重复出现)。
func toSimplified(_ s: String) -> String {
    let mutable = NSMutableString(string: s) as CFMutableString
    CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
    return mutable as String
}

// 每个歌词源一个固定色,列表/详情页共用,方便肉眼快速扫源(不是随手配的——网易云红、
// QQ音乐绿、酷狗蓝、LRCLIB紫,分别贴近各自品牌主色,"无来源"用中性灰)。
//
// internal 而非 private——"歌词"设置分类里的来源启用/优先级排序 UI(FeatureSettingsStore.swift
// 的 LyricsSource 枚举)复用同一套名字/颜色,避免两处各维护一份 switch 导致漂移。
func sourceColor(_ source: String) -> Color {
    switch source {
    case "netease": return .red
    case "qq": return .green
    case "kugou": return .cyan
    case "musixmatch": return .indigo
    case "lrclib": return .purple
    default: return .secondary
    }
}

// 歌词来源展示名——网易云音乐/QQ音乐/酷狗音乐是国内用户认得出的中文写法;Musixmatch/
// LRCLIB 都是纯西方的歌词库(品牌),没有约定俗成的中文名,保留英文原名,不强行硬翻
// 一个不存在的中文名。
func sourceDisplayName(_ source: String) -> String {
    switch source {
    case "netease": return L10n.t("网易云音乐")
    case "qq": return L10n.t("QQ音乐")
    case "kugou": return L10n.t("酷狗音乐")
    case "musixmatch": return "Musixmatch"
    case "lrclib": return "LRCLIB"
    case "": return L10n.t("无来源")
    default: return source
    }
}

// 歌名/歌手/专辑/来源四列表头和每一行列表项共用同一组列宽——歌名是主列、拿剩余空间,
// 后三列固定宽度+单行截断,这样表头文字和每行内容的起始位置对得上。
// 列宽拖拽手柄:1pt 的细线 + 9pt 的命中区(线本身太细,按 HIG 可拖拽目标不该小于 8pt)。
// 单独抽成一个 View 是为了让 hover 光标的 push/pop 有地方存状态自己配平——onHover 的退出
// 事件在拖拽中/窗口切走时可能丢,无条件 pop 会把别人压进去的光标弹掉,连续 push 又会让
// 双箭头光标一直卡住不还原。
// 列宽拖拽 + 行内容边界测量共用的命名坐标空间。挂在侧栏最外层的 VStack 上(不是表头上):
// 表头的拖拽手势和列表里每一行都要在**同一个**空间里报坐标才能互相对齐。这个 VStack
// 不随列宽变化而移动,所以也是拖拽位移的可靠参照系。
private enum LyricsColumnHeaderSpace {
    static let name = "lyricsColumnHeader"
}

// 列表里"一行内容"的实际左右边界。List(.inset) 自己给每行加的 inset 是 AppKit 给的、会随
// 系统版本变(实测 leading≈16pt、trailing≈33pt,后者含滚动条留白),不能在表头那边写死一个
// 猜的数字——让行自己量出来往上报,表头据此对齐,分隔线才真的画在列边界上。
private struct RowContentBounds: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
}

private struct RowContentBoundsKey: PreferenceKey {
    static let defaultValue: RowContentBounds? = nil
    // 取第一个上报的即可——所有行的左右边界都一样,没必要合并。
    static func reduce(value: inout RowContentBounds?, nextValue: () -> RowContentBounds?) {
        if value == nil { value = nextValue() }
    }
}

private struct ColumnDividerHandle: View {
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void
    let onDoubleClick: () -> Void
    @State private var pushedCursor = false

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.28))
            .frame(width: 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, !pushedCursor { NSCursor.resizeLeftRight.push(); pushedCursor = true }
                if !inside, pushedCursor { NSCursor.pop(); pushedCursor = false }
            }
            .onDisappear { if pushedCursor { NSCursor.pop(); pushedCursor = false } }
            // minimumDistance: 1 而不是 0——0 会让双击的第一次按下就被当成拖拽开始,
            // 下面那个双击复位手势永远收不到。
            //
            // ⚠️ 位移必须在**表头这个固定坐标空间**里算(location - startLocation),不能用
            // value.translation:translation 是相对手势所在视图算的,而这个手柄正是随列宽
            // 变化而移动的那个视图——拖宽一点手柄就往右跑一点,光标相对它的偏移被吃掉,
            // 形成反馈回路。2026-08-05 真机实测坐实:拖 40pt 只涨了 22pt,而且本该守恒的
            // "歌手+专辑总宽"也被破坏(歌名被反向挤窄 13.5pt)。命名坐标空间挂在表头容器上,
            // 它不随列宽改变,量出来的位移才跟鼠标实际移动一致。
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(LyricsColumnHeaderSpace.name))
                    .onChanged { onDrag($0.location.x - $0.startLocation.x) }
                    .onEnded { _ in onDragEnd() }
            )
            .onTapGesture(count: 2, perform: onDoubleClick)
    }
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
    // 多选。原来是单选的 `String?`,那种绑定下 List 完全不响应 Cmd 点选/Shift 连选。
    // 三态由 selectedKeys.count 决定:0 = 空占位,1 = 原来的单曲详情页,≥2 = 批量操作面板。
    @State private var selectedKeys: Set<String> = []
    // 待删 key 的**快照**。删除确认弹窗一律只读这一份,绝不在弹窗回调里现读 selectedKeys:
    // 弹窗弹出时 List 会失去 first responder,已知会出现 selection 被系统清空的情况,现读
    // 可能读到空集(什么都没删、用户以为删了)或读到中途被改过的集合。
    @State private var pendingDeleteKeys: [String] = []
    @State private var showBatchDeleteConfirm = false
    // 删完之后 selectedKeys 清空、右侧面板变回空占位,如果一点反馈都没有,用户看到的就是
    // "列表少了一批、面板莫名变空"。跟这个文件里已有的 showRefreshedFeedback/
    // showSaveEditFeedback 是同一套写法:短暂切换成"已删除"+对勾,1 秒后自动变回去。
    @State private var showDeletedFeedback = false
    @State private var editedLyrics = ""
    @State private var editedTr = ""
    @State private var editedRoma = ""
    // 单曲歌词时间轴偏移——输入框显示/编辑的秒数字符串。跟下面两个"persisted"字段
    // 分开存,是因为算 LyricsOffsetStore 的 key 必须用磁盘上实际持久化的歌词内容,不能
    // 用 editedLyrics(用户可能正在编辑框里改还没点"保存修改",这时候的文本还没生效到
    // 播放端,拿它算出来的 key 会跟真正播放时用的 key 对不上)。
    @State private var editedOffsetSeconds = ""
    @State private var persistedLyricsForOffset = ""
    @State private var persistedYRCForOffset = ""
    // 列宽(可拖拽调节 + 持久化,见 LyricsColumnWidthsStore)。
    @ObservedObject private var columnWidths = LyricsColumnWidthsStore.shared
    // 表头实际渲染宽度,拖拽夹值要用;首帧还没量到时是 0。
    @State private var headerWidth: CGFloat = 0
    // 一次拖拽开始那一刻的列宽快照——必须按"起点 + 累计位移"算,不能每次 onChanged 都在
    // 当前值上叠加增量:DragGesture 的 translation 是相对手势起点的累计值,不是帧间增量,
    // 叠加会让列宽以平方速度飞出去。
    @State private var dragStartWidths: LyricsColumnWidths?
    // List 里一行内容的实际左右边界(由行自己通过 preference 上报,见 RowContentBoundsKey)。
    @State private var rowContentBounds: RowContentBounds?
    @State private var showSearchSheet = false
    // 2026-08-02 补上——"保存修改"/"移除逐字时间轴"点了之前完全没有任何肉眼可见的
    // 反馈,跟上面 showRefreshedFeedback("刷新"按钮已有的做法)是同一类问题、同一个
    // 修法:短暂切换成"已保存"/"已移除"+对勾图标,1秒后自动变回去。
    @State private var showSaveEditFeedback = false
    @State private var showRemoveWordTimingFeedback = false
    // "移除逐字时间轴"补一道二次确认——这是破坏性操作(重新解析很可能又抓到同一份不准
    // 的逐字时间轴，不一定找得回来),跟同页面"删除本地记录"/工具栏"清空全部缓存"都有
    // confirmationDialog 二次确认相比，这里之前是唯一没有的，破坏程度相近、防护级别
    // 却不一致。
    @State private var showRemoveWordTimingConfirm = false
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
    @State private var showClearAllConfirm = false

    private var hasActiveFilters: Bool {
        sourceFilter != .all || timingFilter != .all || manualOnly || missingLyricsOnly
            || artistFilter != nil || albumFilter != nil
    }

    // primaryArtist 只按分隔符取第一段合并合唱曲目,不处理大小写/繁简——同一位歌手偶尔
    // 因为不同歌词源的候选写法不一致而长得不一样(比如"周杰倫" vs "周杰伦"),不加这层
    // 归并的话筛选下拉会重复出现,跟 albumDisplayNames 是完全同一个"归并键跟展示值
    // 分开"的思路(2026-07-30 用户反馈专辑那边先出现过这个问题,顺手把歌手这边也补上,
    // 避免以后复现同一类 bug)。
    // 一行/一条记录该显示哪个歌手名:优先 collector 核实过的官方名,没有(合唱曲目、或者
    // 还没解析出来)才退回播放器报的原始写法。见 Summary.canonicalArtist 的注释。
    private func artistName(_ s: EnrichCacheStore.Summary) -> String {
        s.canonicalArtist.isEmpty ? s.artist : s.canonicalArtist
    }

    private var artistDisplayNames: [String: String] {
        var seen: [String: String] = [:] // 归并键(小写+简体) -> 第一次出现时的原始写法
        for s in store.summaries {
            let raw = primaryArtist(artistName(s))
            guard !raw.isEmpty else { continue }
            let key = toSimplified(raw).lowercased()
            if seen[key] == nil { seen[key] = raw }
        }
        return seen
    }

    private var distinctArtists: [String] {
        Array(Set(artistDisplayNames.values)).sorted()
    }

    // 同一张专辑在不同缓存条目里,专辑名偶尔因为各自歌词源的候选写法不一致而长得不一样——
    // 大小写不同(如"BLOOD ON THE DANCE FLOOR..." vs "Blood on the Dance Floor..."),或者
    // 繁简不同(如"100種生活" vs "100种生活",2026-07-30 用户实测反馈)。归并键统一转小写
    // 再折成简体比较,取第一次遇到(按 summaries 已有的排序)那条的原始写法当这一组的
    // 统一展示文案——不只是筛选下拉要合并,列表每一行、详情页头部凡是要展示专辑名的地方
    // 都用这份映射。跟 primaryArtist 合并合唱曲目是同一个"归并键跟展示值分开"的思路,
    // 只是这里归并键是转小写+折简体而不是按分隔符取第一段。
    private var albumDisplayNames: [String: String] {
        var seen: [String: String] = [:] // 归并键(小写+简体) -> 第一次出现时的原始写法
        for s in store.summaries where !s.album.isEmpty {
            let key = toSimplified(s.album).lowercased()
            if seen[key] == nil { seen[key] = s.album }
        }
        return seen
    }

    private var distinctAlbums: [String] {
        Array(Set(albumDisplayNames.values)).sorted()
    }

    private func albumDisplay(_ album: String) -> String {
        albumDisplayNames[toSimplified(album).lowercased()] ?? album
    }

    private var filtered: [EnrichCacheStore.Summary] {
        store.summaries.filter { s in
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                // 搜索两个写法都认:用户可能按原始写法搜(播放器里看到的那个),也可能按
                // 官方名搜(列表里显示的那个)。
                guard s.artist.lowercased().contains(q)
                    || artistName(s).lowercased().contains(q)
                    || s.title.lowercased().contains(q) else { return false }
            }
            // 大小写/繁简不敏感比较,跟上面 album 那条同一个理由(见 artistDisplayNames 注释)。
            if let artistFilter, toSimplified(primaryArtist(artistName(s))).lowercased() != toSimplified(artistFilter).lowercased() { return false }
            // 大小写/繁简不敏感比较——albumFilter 存的是 distinctAlbums 归并后选中的那个
            // 展示写法,同一张专辑大小写或繁简不同的条目(s.album)也要匹配上,不能要求
            // 逐字相等,跟 albumDisplayNames 用同一套归并规则(见其注释)。
            if let albumFilter, toSimplified(s.album).lowercased() != toSimplified(albumFilter).lowercased() { return false }
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

    // 只有恰好选中一条时才显示单曲详情页——detail 侧整条链(编辑缓冲区、offset 输入框、
    // 联网搜索 sheet)都建立在"当前就这一条"上,不能把多选硬塞进去。
    private var singleSelectedKey: String? {
        selectedKeys.count == 1 ? selectedKeys.first : nil
    }

    // 把全部筛选状态拼成一个字符串,只为了给 onChange 当变化信号用——否则要给七个 @State
    // 各挂一个 onChange 做同一件事(收敛选中项)。
    //
    // 分隔符用 U+001F(ASCII 单元分隔符)而不是 "|":searchText、歌手名、专辑名里都可能出现
    // "|",那样两个不同的筛选状态理论上能拼出同一个 token,onChange 就不会触发、选中项不会
    // 被收敛(而这个收敛正是防误删的那道防线)。虽然要真撞上得刻意构造,但换个用户输入里
    // 不可能出现的控制字符是零成本的,不用去论证"实际撞不上"。
    private var filterToken: String {
        let sep = "\u{1F}"
        return [
            searchText, sourceFilter.id, timingFilter.rawValue,
            String(manualOnly), String(missingLyricsOnly),
            artistFilter ?? "", albumFilter ?? "",
        ].joined(separator: sep)
    }

    // 选中集合里"当前筛选结果中真的看得见"的那些,按列表显示顺序返回。
    //
    // ⚠️ 这是防误删的关键一道:filtered 是计算属性,selectedKeys 是独立 @State,行从筛选
    // 结果里消失后 SwiftUI 不保证替你把 key 从 selection 里剪掉。真实误操作路径:搜
    // "Jackson" 多选 8 条 → 清空搜索框 → 点删除,此时那 8 条一条也看不见,弹窗却写着 8 条,
    // 删完用户完全不知道删了什么,而这个删除是不可逆的(连 lyrics/ 下导出文件一起删)。
    // 所有删除入口和所有计数都走这个函数,保证"弹窗说删 N 条" == "列表里看得见的 N 条"。
    // 按 filtered 顺序而不是 Set 顺序,是为了让删除计划稳定可复现。
    private func orderedVisibleKeys(_ keys: Set<String>) -> [String] {
        filtered.compactMap { keys.contains($0.key) ? $0.key : nil }
    }

    private var selectedVisibleKeys: [String] { orderedVisibleKeys(selectedKeys) }

    // 触发删除确认:先把待删清单快照下来再弹窗(理由见 pendingDeleteKeys 的注释)。
    private func requestDelete(_ keys: Set<String>) {
        let victims = orderedVisibleKeys(keys)
        guard !victims.isEmpty else { return }
        pendingDeleteKeys = victims
        showBatchDeleteConfirm = true
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

                // 「全选筛选结果」给一个显式按钮,不能只靠 ⌘A:这个窗口的核心动线正是"在筛选
                // 栏勾出一批 → 立刻想全选删掉",此时焦点大概率还在上面那个原生搜索框上,⌘A
                // 会变成"全选搜索框里的文字"。按钮上带的数字跟标题栏副标题「N / 852 首」左边
                // 那个数完全一致,用户一眼能对上"我选的就是筛出来的这批"。
                if selectedKeys.isEmpty {
                    if !filtered.isEmpty {
                        Button(String(format: L10n.t("全选 %@ 首"), "\(filtered.count)")) {
                            selectedKeys = Set(filtered.map(\.key))
                        }
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(format: L10n.t("已选 %@ 首"), "\(selectedVisibleKeys.count)"))
                        .foregroundStyle(.secondary)
                    Button(L10n.t("取消选择")) { selectedKeys.removeAll() }
                        .foregroundStyle(.secondary)
                }

                if hasActiveFilters {
                    Divider().frame(height: 14)
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

    // 列名表头——歌名/歌手/专辑/来源,跟 LyricsManagerRow 共用 shownWidths 这一组列宽
    // 常量,保证表头文字跟每行对应列对得齐。水平内边距(12pt)特意跟 List(.inset 样式)
    // 默认给每行内容的左右留白对齐,不然表头会跟下面的行错位。
    private var listColumnHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.t("歌名")).frame(maxWidth: .infinity, alignment: .leading)
            // 三条分隔条都挂成对应列的 .overlay(alignment: .leading) ——overlay 不参与布局,
            // 所以表头的列宽/间距跟下面每一行仍然逐 pt 对齐(这一点很关键:如果把手柄当成
            // HStack 的一个真实子视图,它自己的 9pt 宽度会把表头整体右推,表头和行就错位了)。
            Text(L10n.t("歌手")).frame(width: shownWidths.artist, alignment: .leading)
                .overlay(alignment: .leading) { columnDivider(0) }
            Text(L10n.t("专辑")).frame(width: shownWidths.album, alignment: .leading)
                .overlay(alignment: .leading) { columnDivider(1) }
            Text(L10n.t("来源")).frame(width: shownWidths.source, alignment: .leading)
                .overlay(alignment: .leading) { columnDivider(2) }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        // 左右内边距跟着 List 里"行内容的实际左右边界"走,而不是写死 12pt。
        // List(.inset) 给每行加的 inset 跟表头的内边距本来就不相等(实测 leading≈16pt、
        // trailing≈33pt——后者还含滚动条留白),两边一直是错开的;以前表头没有分隔线,错开
        // 20pt 看不出来,现在分隔线画的就是列边界,错开就直接可见了。这两个值是 AppKit 给的、
        // 会随系统版本变,所以运行时量(见 RowContentBoundsKey),不硬编码。
        .padding(.leading, headerLeading)
        .padding(.trailing, headerTrailing)
        .padding(.vertical, 5)
        // 量出表头这一行的实际可用宽度,拖拽时用来算"歌名列还剩多少"(见
        // LyricsColumnWidths.dragged 的 totalWidth 参数)。放在 .background 里的
        // GeometryReader 不影响布局,是量宽度又不改版式的标准做法。
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { headerWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in headerWidth = w }
            }
        )
        .contextMenu {
            Button(L10n.t("重置列宽")) { columnWidths.reset() }
        }
    }

    // 量不到行内容边界时的兜底内边距(首帧、或列表还没渲染出任何一行)。
    private static let fallbackHPadding: CGFloat = 12

    private var headerLeading: CGFloat { rowContentBounds?.minX ?? Self.fallbackHPadding }
    private var headerTrailing: CGFloat {
        guard let b = rowContentBounds, headerWidth > 0 else { return Self.fallbackHPadding }
        return max(0, headerWidth - b.maxX)
    }
    // 表头左右内边距 + 三个 8pt 列间距 = 这一行里不属于任何列的固定开销,算歌名列剩余
    // 宽度时要先扣掉它(见 LyricsColumnWidths.dragged/fitted 的 chrome 参数)。
    private var headerChrome: CGFloat { headerLeading + headerTrailing + 8 * 3 }

    // 真正拿去渲染的列宽:窗口/侧栏被拖窄后,用户存下来的列宽可能已经把歌名挤没,fitted
    // 会临时等比收敛(不改存下来的值)。headerWidth 还没量到(=0)时 fitted 原样返回,
    // 首帧不会算出奇怪的宽度。
    private var shownWidths: LyricsColumnWidths {
        LyricsColumnWidths.fitted(columnWidths.widths, totalWidth: headerWidth, chrome: headerChrome)
    }

    private func columnDivider(_ index: Int) -> some View {
        // 手柄 9pt 宽、居中压在两列之间那个 8pt 间距的正中:overlay 的 leading 让手柄左边缘
        // 贴着本列左边缘,而间距中点在本列左边缘往左 4pt 处,所以整体左移 9/2 + 4 = 8.5pt。
        ColumnDividerHandle(
            onDrag: { dx in
                if dragStartWidths == nil { dragStartWidths = columnWidths.widths }
                guard let start = dragStartWidths else { return }
                columnWidths.widths = LyricsColumnWidths.dragged(
                    from: start, divider: index, dx: dx,
                    totalWidth: headerWidth, chrome: headerChrome
                )
            },
            onDragEnd: { dragStartWidths = nil },
            onDoubleClick: { resetDivider(index) }
        )
        .offset(x: -8.5)
    }

    // 双击某条分隔条 = 把这条边界两侧的列恢复默认宽度(不是全部三列——只动用户正在操作的
    // 那条边界更符合预期;要整体恢复用表头右键菜单里的「重置列宽」)。
    private func resetDivider(_ index: Int) {
        let d = LyricsColumnWidths.defaults
        var w = columnWidths.widths
        switch index {
        case 0: w.artist = d.artist                       // 左边是弹性的歌名列,只需复位歌手
        case 1: w.artist = d.artist; w.album = d.album
        default: w.album = d.album; w.source = d.source
        }
        columnWidths.widths = w
    }

    var body: some View {
        NavigationSplitView {
            // ScrollViewReader 包住整个侧栏(而不是只包 List)——工具栏的"回到当前播放"
            // 按钮跟 List 是 VStack 里的兄弟节点、跟 .toolbar 修饰符也不在同一层,要让
            // scrollProxy 在这两者共同的外层作用域里可见,闭包需要整个包住 VStack+.toolbar。
            // ScrollViewReader 只是个透明包装,不影响布局。
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    filterBar
                    Divider()
                    listColumnHeader
                    Divider()
                    List(filtered, selection: $selectedKeys) { summary in
                        LyricsManagerRow(summary: summary, artistDisplayName: artistName(summary), albumDisplayName: albumDisplay(summary.album), widths: shownWidths)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    // ⚠️ 菜单闭包里只用参数 keys,一个字都不能读 selectedKeys。官方文档明确:
                    // 从空白处唤出菜单时 keys 是空集(即使当前有选中项也一样);图省事读
                    // selectedKeys 就会变成"右键点空白 → 菜单显示『删除 8 条』 → 删掉 8 条
                    // 根本不在右键位置的条目"。空集时整个菜单不给任何项(= 文档说的停用菜单)。
                    // 右键点某个未被选中的行时系统会把选中收敛到那一行、keys 就是那一行;
                    // 右键点已选中区内任一行则 keys 是整个选区——这正是需要的原生行为,给每行
                    // 单独挂 .contextMenu 拿不到。
                    // 不传 primaryAction:macOS 上它绑的是双击,这个列表双击目前没有语义,
                    // 绑上破坏性操作等于给它配一个极易误触的手势。
                    .contextMenu(forSelectionType: String.self) { keys in
                        if !keys.isEmpty {
                            Button(role: .destructive) {
                                requestDelete(keys)
                            } label: {
                                Text(keys.count == 1
                                    ? L10n.t("删除本地记录")
                                    : String(format: L10n.t("删除选中的 %@ 条"), "\(keys.count)"))
                            }
                        }
                    }
                    // 筛选条件一变就把选中项收敛到当前可见集合。用 formIntersection 而不是
                    // 无条件清空:用户只是微调搜索词时保住已有选择更符合预期。
                    .onChange(of: filterToken) { _, _ in
                        selectedKeys.formIntersection(Set(filtered.map(\.key)))
                    }
                    // 删除确认弹窗挂在 List 上——不能挂在 detailView 里(多选时右侧渲染的是批量
                    // 面板、detailView 根本不在视图树里,置 isPresented 会静默无效),也故意不跟
                    // 下面「清空全部缓存」那个弹窗挂在同一条修饰符链上:SwiftUI 对同一条链上叠加
                    // 多个同类型呈现修饰符历史上有互相顶掉的问题,挂在层级明确不同的两个视图上
                    // 就不用去论证"这个版本到底会不会冲突"。List 在侧栏里始终存在、生命周期稳定。
                    // title/actions/message 一律只读 pendingDeleteKeys 这份快照,不读 selectedKeys。
                    .confirmationDialog(
                        batchDeleteTitle,
                        isPresented: $showBatchDeleteConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(
                            pendingDeleteKeys.count == 1
                                ? L10n.t("删除")
                                : String(format: L10n.t("删除 %@ 条"), "\(pendingDeleteKeys.count)"),
                            role: .destructive
                        ) {
                            performPendingDelete()
                        }
                        Button(L10n.t("取消"), role: .cancel) {}
                    } message: {
                        Text(batchDeleteMessage)
                    }
                    .onAppear {
                        // reload 必须先于定位——刚打开窗口时 summaries 可能还是上次
                        // 关闭时的旧内容(或空的),定位逻辑要按最新磁盘内容匹配当前
                        // 播放的这首歌。reload() 是 async(读文件+解析在后台线程,避免
                        // 缓存文件变大之后开窗卡顿),这里用 Task 包一层、await 完了再定位。
                        Task {
                            await store.reload()
                            focusCurrentlyPlaying(scrollProxy: scrollProxy)
                        }
                    }

                    // store.lastError 原来只在右侧详情页里渲染(见 detailView)——批量删完
                    // selectedKeys 清空、右侧变回空占位,「写入本地记录文件失败」和「重启
                    // collector 失败」两条就都没有宿主视图了。后者尤其要命:collector 没重启
                    // 成功时它内存里还持有整份旧缓存,下次它自己存盘就会把刚删的条目整体写回
                    // 磁盘(见 EnrichCacheStore 顶部注释),用户看到的是"删了一批、过一会儿又
                    // 全回来了",而全程零提示。这条横幅挂在列表下面,跟选中状态无关、永远在。
                    if let error = store.lastError {
                        Divider()
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial)
                    }
                }
                // 坐标空间挂在这里(不是表头上):表头的拖拽手势和列表每一行都要在同一个空间
                // 里报坐标,才能让分隔线对齐到行内容的真实列边界。见 LyricsColumnHeaderSpace。
                .coordinateSpace(.named(LyricsColumnHeaderSpace.name))
                .onPreferenceChange(RowContentBoundsKey.self) { bounds in
                    if let bounds { rowContentBounds = bounds }
                }
                // placement: .sidebar——默认 .automatic 会把这个本地过滤用的原生
                // .searchable 解析成挂在整个窗口的顶部工具栏,而 filterBar 是贴在内容区
                // (这一栏)顶部的一条 HStack,两者分处"窗口级"和"内容级"两个不同层次,
                // 离得太远不像一组。指定 .sidebar 把搜索框的锚点改成这一栏
                // (NavigationSplitView 的 sidebar 闭包)自己的顶部,紧贴 filterBar,
                // 仍是系统原生搜索框,只是挂载位置变了。
                .searchable(text: $searchText, placement: .sidebar, prompt: L10n.t("搜索歌手/歌名"))
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
                    ToolbarItem {
                        // 常驻 + 空选时置灰,不做"选中才出现"——按钮凭空插进来会把旁边几个
                        // 工具栏项整排挤位移,而 Mac 上(邮件的废纸篓按钮)的惯例本来就是
                        // 常驻置灰。文案固定不带数字,避免每次改选中都抖动。
                        //
                        // 快捷键取 ⌘⌫ 而不是裸 ⌫:惯例上裸 ⌫ 是给"删除可撤销/进废纸篓"用的
                        // (邮件删完 ⌘Z 能回来),⌘⌫ 才是给不可逆或直接动文件系统的删除用的
                        // (Finder 移到废纸篓、照片删除),而这里两条都占——没有撤销,还真的
                        // unlink lyrics/ 下的文件。更实际的理由是:.keyboardShortcut 挂在按钮上
                        // 是**窗口级**快捷键,跟焦点在哪无关,绑裸 ⌫ 会把这个窗口里搜索框和三个
                        // 歌词文本框的退格键全抢掉——在搜索框里退一个字符就弹出删除确认。
                        // .disabled 让空选时按 ⌘⌫ 毫无反应,天然挡住误触。
                        Button {
                            requestDelete(selectedKeys)
                        } label: {
                            Label(showDeletedFeedback ? L10n.t("已删除") : L10n.t("删除记录"),
                                  systemImage: showDeletedFeedback ? "checkmark" : "trash")
                        }
                        .disabled(selectedVisibleKeys.isEmpty)
                        .keyboardShortcut(.delete, modifiers: .command)
                    }
                    ToolbarItem {
                        // 缓存占用查看 + 一键清空——这份缓存设计上"解析一次永久保留",
                        // 之前只能在下面列表里逐条删,没有总大小展示、也没有批量清空的入口。
                        //
                        // ⚠️ 2026-08-05 修:这里原来只有 `Label(cacheSizeText, systemImage:)`
                        // 当 Menu 的标签,旧注释还写着"菜单本身的标题就是总大小,不需要另外找
                        // 地方展示这个数字"——但 macOS 工具栏里的 Label **默认只画图标、把标题
                        // 整个丢掉**(跟 MenuBarMenu.swift 里"下拉菜单默认不画 Label 图标"是相反
                        // 方向的同一类默认行为),所以那个数字从来没真的出现在界面上,工具栏上
                        // 只有一个硬盘图标 + 展开箭头。补 .labelStyle(.titleAndIcon) 让标题真的
                        // 画出来。
                        //
                        // 菜单里再放一行"共 N 条,占用 X":用户点开这个菜单本来就是想看占用,而且
                        // 这一行紧贴着"清空全部缓存"这个不可撤销的操作,让人在点下去之前先看清
                        // 自己要删掉多少东西。
                        Menu {
                            Section {
                                Button(role: .destructive) {
                                    showClearAllConfirm = true
                                } label: {
                                    Label(L10n.t("清空全部缓存"), systemImage: "trash")
                                }
                            } header: {
                                Text(String(format: L10n.t("共 %d 条，占用 %@"),
                                            store.summaries.count, cacheSizeText))
                            }
                        } label: {
                            Label(cacheSizeText, systemImage: "internaldrive")
                                .labelStyle(.titleAndIcon)
                        }
                        // 光看一个数字说不清算的是什么——说明它同时含缓存 JSON 和已导出的
                        // lyrics/ 文件夹(见 EnrichCacheStore.totalSizeBytes)。
                        .help(L10n.t("歌词缓存文件，加上已导出的 .lrc 歌词文件夹，合计占用的磁盘空间"))
                    }
                }
                // 列表这一栏(歌名/歌手/专辑/来源四列)给个够宽的默认/理想宽度——不然
                // NavigationSplitView 默认分给侧栏的宽度偏窄,歌名(尤其是带 feat./remix
                // 后缀的长标题)会被裁成省略号。630pt 能让歌名基本完整露出来,拿来当
                // ideal 默认值。
                .navigationSplitViewColumnWidth(min: 480, ideal: 630, max: 900)
                .confirmationDialog(
                    L10n.t("确定要清空全部歌词缓存吗?"),
                    isPresented: $showClearAllConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L10n.t("清空全部缓存"), role: .destructive) {
                        Task {
                            await store.clearAll()
                            selectedKeys.removeAll()
                        }
                    }
                    Button(L10n.t("取消"), role: .cancel) {}
                } message: {
                    Text(String(format: L10n.t("这会删除当前全部 %d 条本地记录,包括你手动编辑、联网搜索采纳过的内容,已导出到本地的歌词文件也会一并删除,且无法撤销。下次播放会重新走一遍匹配解析"), store.summaries.count))
                }
            }
        } detail: {
            if let key = singleSelectedKey, let summary = store.summaries.first(where: { $0.key == key }) {
                detailView(key: key, summary: summary)
            } else if selectedKeys.count > 1 {
                batchSelectionPanel
            } else {
                ContentUnavailableView(L10n.t("选择左侧一首歌"), systemImage: "text.quote")
            }
        }
        .frame(minWidth: 780, idealWidth: 1040, minHeight: 540, idealHeight: 640)
        // 见 AuxiliaryWindowActivation 注释——.accessory 策略下临时借一个 Dock 图标。
        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        .onDisappear { AuxiliaryWindowActivation.windowDidDisappear() }
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
    // 交互闷在这阵持续重渲染里,表现成"点了跟没点一样"。这里只需要开窗那一刻的快照,
    // 普通函数内直接访问单例属性即可,不用建立订阅。
    private func refreshWithFeedback() {
        Task {
            await store.reload()
            // 重新读盘之后缓存内容可能已经变了(collector 自己写过、或别处删过),选中集合里
            // 可能残留已经不存在的 key——跟筛选变化那条 onChange 同一个道理,收敛一次。
            selectedKeys.formIntersection(Set(store.summaries.map(\.key)))
            withAnimation { showRefreshedFeedback = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showRefreshedFeedback = false }
        }
    }

    // N == 1 时沿用原来那条带歌名的单曲文案(既有词条,不新造);N ≥ 2 只给数量,不列歌名——
    // confirmationDialog 的 message 是不可滚动的小字,列十几首要么撑爆要么截断,而左侧列表里
    // 那些行本来就正高亮着,弹窗再列一遍是重复且更难读(Finder/照片/邮件都是只给数量)。
    private var batchDeleteTitle: String {
        if pendingDeleteKeys.count == 1,
           let summary = store.summaries.first(where: { $0.key == pendingDeleteKeys[0] }) {
            return String(format: L10n.t("确定要删除「%@ - %@」的本地记录吗?"), summary.artist, summary.title)
        }
        return String(format: L10n.t("确定要删除选中的 %@ 条本地记录吗?"), "\(pendingDeleteKeys.count)")
    }

    // 三条完整独立的句子,不在运行时拼接——拼出来的句子英文侧语序没法翻。
    // "其中 N 条是人工修正过的" 单独成一条:那是这批里唯一删了真找不回来的东西(其余条目
    // 下次播放会重新解析),属于决策信息,值得在确认这一刻单独点出来。
    private var batchDeleteMessage: String {
        if pendingDeleteKeys.count == 1 {
            return L10n.t("已导出到本地的歌词文件也会一并删除,下次播放这首歌会重新走一遍匹配解析,不保证一定能找到一样的歌词")
        }
        let pending = Set(pendingDeleteKeys)
        let manual = store.summaries.filter { pending.contains($0.key) && $0.isManual }.count
        if manual > 0 {
            return String(format: L10n.t("其中 %@ 条是你手动修正过的,删掉之后找不回来。已导出到本地的歌词文件也会一并删除,且无法撤销。下次播放这些歌会重新走一遍匹配解析,不保证能找到一样的歌词"), "\(manual)")
        }
        return L10n.t("已导出到本地的歌词文件也会一并删除,且无法撤销。下次播放这些歌会重新走一遍匹配解析,不保证能找到一样的歌词")
    }

    private func performPendingDelete() {
        let victims = Set(pendingDeleteKeys)
        guard !victims.isEmpty else { return }
        Task {
            await store.delete(keys: victims)
            // 已删的 key 必须自己从选中集合里拿掉,别指望 SwiftUI 替你收拾。
            selectedKeys.subtract(victims)
            // 故意不清空 pendingDeleteKeys:弹窗的标题/按钮文案都读它的 count,在关闭动画
            // 还没走完时清掉会让按钮文字闪一下"删除 0 条"。它每次 requestDelete 都会被整体
            // 覆盖,留着上一批的内容不会被误用。
            // 失败时不叠加"已删除"反馈——列表下面那条红色 lastError 横幅已经在说了,
            // 两套反馈同时出现互相矛盾(跟采纳联网候选那里的处理一致)。
            guard store.lastError == nil else { return }
            withAnimation { showDeletedFeedback = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showDeletedFeedback = false }
        }
    }

    // 多选时右侧显示什么:只放"确认我选中的就是我以为的那批" + 一个够明确的删除按钮。
    // 不放歌名清单(左侧列表就是权威视图)、不放编辑器、不放占用空间——算这批的真实体积要对
    // lyrics/ 目录做 4N 次 stat,而"删歌词"本来也不是为了腾空间,工具栏那个菜单标题已经是
    // 总大小了。
    private var batchSelectionPanel: some View {
        let victims = Set(selectedVisibleKeys)
        let picked = store.summaries.filter { victims.contains($0.key) }
        let manual = picked.filter(\.isManual).count
        let wordTiming = picked.filter(\.hasWordTiming).count
        let missing = picked.filter { !$0.hasLyrics }.count
        return VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(String(format: L10n.t("已选择 %@ 首"), "\(picked.count)"))
                .font(.title2.weight(.semibold))
            // 三个统计各自独立成词条,不在运行时拼成一句长句(同 batchDeleteMessage 的理由);
            // 为 0 的那项整个不显示,不写"0 首"。
            HStack(spacing: 8) {
                if manual > 0 {
                    InfoChip(icon: "pencil.circle.fill", text: String(format: L10n.t("人工修正 %@ 首"), "\(manual)"), tint: .orange)
                }
                if wordTiming > 0 {
                    InfoChip(icon: "text.word.spacing", text: String(format: L10n.t("逐字时间轴 %@ 首"), "\(wordTiming)"), tint: .blue)
                }
                if missing > 0 {
                    InfoChip(icon: "text.badge.xmark", text: String(format: L10n.t("无歌词 %@ 首"), "\(missing)"), tint: .red)
                }
            }
            if manual > 0 {
                Text(L10n.t("人工修正过的歌词删掉之后找不回来"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                requestDelete(selectedKeys)
            } label: {
                Label(String(format: L10n.t("删除选中的 %@ 条"), "\(picked.count)"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Button(L10n.t("取消选择")) { selectedKeys.removeAll() }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // .useAll 而不是限定 .useMB——总大小从几百 KB(刚起步)到几十 MB(用了很久)跨度
    // 很大,让系统自己选最合适的单位,不用手动判断该显示 KB 还是 MB。
    private var cacheSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: store.totalSizeBytes)
    }

    // force:true 是给工具栏"回到当前播放"按钮用的——绕开"已经选中别的行就不动"这道
    // 只为"开窗自动定位"场景设的门槛(见调用点注释)。找不到当前播放曲目的缓存条目时
    // 两种调用方式都一样静默不做任何事,不额外弹提示——开窗自动定位场景本来就不该弹,
    // 手动点按钮那次不做区分只是图简单,真找不到时用户自己也看得出列表没跳。
    private func focusCurrentlyPlaying(scrollProxy: ScrollViewProxy, force: Bool = false) {
        guard force || selectedKeys.isEmpty else { return }
        let playback = PlaybackCoordinator.shared
        let key = "\(playback.artist)|\(playback.title)|\(playback.album)"
        guard store.summaries.contains(where: { $0.key == key }) else { return }
        // 整体替换成这一条、不是追加:"回到当前播放"的语义是聚焦到这首歌。追加的话用户点完
        // 之后工具栏删除按钮上还挂着之前选的一堆,极易误删。
        selectedKeys = [key]
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
                offsetSection(summary)

                if summary.hasWordTiming {
                    wordTimingHint
                }

                editorSection(title: L10n.t("歌词(LRC)"), icon: "text.alignleft", text: $editedLyrics, minHeight: 220, monospaced: true, disabled: summary.hasWordTiming)
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
        .sheet(isPresented: $showSearchSheet) {
            // 采纳候选直接保存,不需要再手动点"保存修改"——避免让人误以为选了就已经
            // 存上了,结果只是填进了编辑框,还得再点一下保存才真正落盘。
            LyricsSearchSheet(artist: summary.artist, title: summary.title, album: summary.album, currentSource: summary.lyricsSource, durationSecs: summary.durationSecs) { candidate in
                editedLyrics = candidate.lyrics
                editedTr = candidate.lyricsTr
                editedRoma = candidate.lyricsRoma
                Task {
                    await store.saveEdit(key: key, lyrics: candidate.lyrics, tr: candidate.lyricsTr, roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC, source: candidate.source)
                    // 采纳的候选歌词内容跟原来不一样,offset 的 key(内容指纹)也跟着变——
                    // 输入框要显示"新内容对应的偏移值",不能继续显示采纳前那份内容的值。
                    refreshOffsetState(artist: summary.artist, title: summary.title, lyrics: candidate.lyrics, yrc: candidate.lyricsYRC)
                    // 2026-08-02 补上——采纳候选之前点了就直接关闭弹窗,真正的保存+重启
                    // collector 在后台异步跑,用户看不到任何进度,失败时只能在下面
                    // store.lastError 那行小字里发现。复用"保存修改"同一个反馈机制:
                    // 成功就闪一下"已保存",失败不闪(已经有 lastError 的红字提示,不需要
                    // 叠加两套反馈互相矛盾)。
                    if store.lastError == nil {
                        withAnimation { showSaveEditFeedback = true }
                        try? await Task.sleep(for: .seconds(1))
                        withAnimation { showSaveEditFeedback = false }
                    }
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
            // 常用操作挪到顶部,不用翻到页面最下面才能点。.fixedSize() 强制这一组按钮
            // 永远按自己的完整期望宽度渲染,不参与跟左边歌名/歌手/专辑那个 VStack 的
            // 空间压缩——否则歌名一长(比如带 feat./罗马数字后缀),会把这两个按钮的
            // 文字挤到只剩省略号("联网搜..."/"删除本...")。空间不够时优先满足按钮
            // 宽度,歌名那边靠 Text 自然换行让出空间。
            HStack(spacing: 8) {
                Button {
                    showSearchSheet = true
                } label: {
                    Label(L10n.t("联网搜索候选歌词"), systemImage: "magnifyingglass")
                }
                // 跟工具栏按钮、右键菜单走同一条 requestDelete → 侧栏那个确认弹窗的路径:
                // 只留一处弹窗,文案/统计/快照逻辑不会两处漂移。N==1 时 batchDeleteTitle 会
                // 自动用带歌名的那条既有文案,跟改动之前一模一样。
                Button(role: .destructive) {
                    requestDelete([summary.key])
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

    // 单曲歌词时间轴偏移——跟菜单栏"歌词时间轴"(边听边点着调)是同一份数据
    // (LyricsOffsetStore),这里是给想直接敲一个精确数值的场景用的输入框,不用先听
    // 一遍再一点点试。回车或点"应用"才真正写入+让当前播放立刻生效,不是敲一个字符
    // 就实时应用(半个数字、负号打到一半时不该被当成有效值提交)。
    private func offsetSection(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 8) {
            Label(L10n.t("歌词时间轴偏移"), systemImage: "timer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("0.0", text: $editedOffsetSeconds)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .onSubmit { applyOffsetEdit(summary) }
            Text(L10n.t("秒"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(L10n.t("应用")) { applyOffsetEdit(summary) }
            if LyricsOffsetStore.shared.offset(forKey: currentOffsetKey(summary)) != 0 {
                Button(L10n.t("重置")) { resetOffsetEdit(summary) }
            }
            Spacer()
            Text(L10n.t("正数=提前显示,负数=延后显示"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var wordTimingHint: some View {
        Label(
            L10n.t("这首歌带逐字时间轴,播放时优先用它渲染——下面直接改「歌词(LRC)」文本框不会生效。如需手改主歌词,请先点「移除逐字时间轴」。译文/罗马音编辑不受影响,随时生效"),
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func editorSection(title: String, icon: String, text: Binding<String>, minHeight: CGFloat, monospaced: Bool, disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(monospaced ? .system(.body, design: .monospaced) : .system(.body))
                .frame(minHeight: minHeight)
                .padding(8)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                // 2026-08-02 补上——带逐字时间轴的歌曲,上面 wordTimingHint 已经用一段
                // 蓝色提示文字警告"改这个文本框不会生效",但文本框本身依然完全可编辑,
                // 容易被跳过阅读直接开始改,做一次看似成功、实际无效的修改。真正禁用
                // 输入(而不是仅靠文字提示),配合降低不透明度给出"这里现在改不了"的
                // 直观视觉反馈——想改主歌词得先点"移除逐字时间轴"(跟提示文字说的一致)。
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
        }
    }

    private func actionsRow(key: String, summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await store.saveEdit(key: key, lyrics: editedLyrics, tr: editedTr, roma: editedRoma)
                    // 歌词(LRC)内容可能改了,offset 的 key(内容指纹)也跟着变——重新
                    // 从磁盘读一遍权威内容(而不是假设"这条路径不碰 yrc 所以沿用旧值"),
                    // 保证跟真正持久化下来的内容一致。
                    let d = store.detail(for: key)
                    refreshOffsetState(artist: summary.artist, title: summary.title, lyrics: d.lyrics, yrc: d.yrc)
                    withAnimation { showSaveEditFeedback = true }
                    try? await Task.sleep(for: .seconds(1))
                    withAnimation { showSaveEditFeedback = false }
                }
            } label: {
                Label(showSaveEditFeedback ? L10n.t("已保存") : L10n.t("保存修改"),
                      systemImage: showSaveEditFeedback ? "checkmark" : "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)

            if summary.hasWordTiming {
                Button(role: .destructive) {
                    showRemoveWordTimingConfirm = true
                } label: {
                    Label(showRemoveWordTimingFeedback ? L10n.t("已移除") : L10n.t("移除逐字时间轴"),
                          systemImage: showRemoveWordTimingFeedback ? "checkmark" : "xmark.circle")
                }
                .confirmationDialog(
                    L10n.t("确定要移除逐字时间轴吗?"),
                    isPresented: $showRemoveWordTimingConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L10n.t("移除"), role: .destructive) {
                        Task {
                            await store.removeWordTiming(key: key)
                            // 逐字时间轴被清空了,内容指纹跟着变——同上,重新读一遍权威内容。
                            let d = store.detail(for: key)
                            refreshOffsetState(artist: summary.artist, title: summary.title, lyrics: d.lyrics, yrc: d.yrc)
                            withAnimation { showRemoveWordTimingFeedback = true }
                            try? await Task.sleep(for: .seconds(1))
                            withAnimation { showRemoveWordTimingFeedback = false }
                        }
                    }
                    Button(L10n.t("取消"), role: .cancel) {}
                } message: {
                    Text(L10n.t("重新解析很可能又抓到同一份不准的逐字时间轴，不一定能找回更准确的版本"))
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
        if let summary = store.summaries.first(where: { $0.key == key }) {
            refreshOffsetState(artist: summary.artist, title: summary.title, lyrics: d.lyrics, yrc: d.yrc)
        }
    }

    // 跟 loadDetail 共用——"保存修改"/采纳联网候选歌词之后也要重新调这个:磁盘上的
    // 歌词内容变了,LyricsOffsetStore 的 key(内容指纹的一部分)跟着变,输入框要显示
    // "新内容对应的偏移值"(通常是 0,内容变了旧的校正值自然对不上、查不到),而不是
    // 继续显示改之前那份内容的偏移值。
    private func refreshOffsetState(artist: String, title: String, lyrics: String, yrc: String) {
        persistedLyricsForOffset = lyrics
        persistedYRCForOffset = yrc
        let key = LyricsOffsetStore.trackKey(artist: artist, title: title, lyrics: lyrics, lyricsYRC: yrc)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: LyricsOffsetStore.shared.offset(forKey: key))
    }

    private func currentOffsetKey(_ summary: EnrichCacheStore.Summary) -> String {
        LyricsOffsetStore.trackKey(artist: summary.artist, title: summary.title, lyrics: persistedLyricsForOffset, lyricsYRC: persistedYRCForOffset)
    }

    private func applyOffsetEdit(_ summary: EnrichCacheStore.Summary) {
        // 解析失败(打错字/用逗号当小数点/粘贴带单位的字符串)不能悄悄当成 0 秒——
        // 2026-08-02 实测排查坐实:这会把已经手动校正过的非零偏移值直接静默清空,且
        // 没有任何提示。改成解析失败就什么都不做,把输入框重新显示回当前实际生效的
        // 偏移值,不写入任何改动——用户能立刻从"输入框弹回原来的数字"这个视觉反馈里
        // 看出刚才那次输入没有被接受,不需要额外弹窗打扰。
        guard let seconds = Double(editedOffsetSeconds.trimmingCharacters(in: .whitespaces)) else {
            editedOffsetSeconds = AppSettings.formattedSeconds(ms: LyricsOffsetStore.shared.offset(forKey: currentOffsetKey(summary)))
            return
        }
        let ms = Int((seconds * 1000).rounded())
        LyricsOffsetStore.shared.setOffset(ms, forKey: currentOffsetKey(summary))
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: ms)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
    }

    private func resetOffsetEdit(_ summary: EnrichCacheStore.Summary) {
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey(summary))
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: 0)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
    }
}

// 列表"来源"列的展示——2026-07-30 之前是裸文字直接染色(见 sourceColor),在这种密集
// 列表里五颜六色的整词文字看着比较粗糙,跟这个窗口别处已经在用的胶囊徽章风格
// (InfoChip,详情页顶部那几个"QQ音乐/逐字时间轴"小标签)不一致。改成同一路子的迷你
// 胶囊徽章——只是详情页 InfoChip 是给单独一行的大标签设计的(图标+文字+较大内边距),
// 这里要塞进列表一整列、还要跟其它 9 行对齐,用更紧凑的内边距/字号,不带图标(色块本身
// 已经足够跟旁边几种来源区分,加图标在这么窄的列里反而显得挤)。
private struct SourceBadge: View {
    let source: String
    // 行被选中时系统会铺一层高饱和度蓝底(backgroundProminence 变成 .increased)——固定的
    // 品牌色(浅绿/浅红背景+同色系文字)跟这层蓝底混在一起,深浅都对不上,糊成一团看不清
    // (2026-07-30 用户实测反馈)。跟 AccountLinkingTab.swift 的 DestinationStatusLabel
    // 同一个思路:选中时退回系统的 .primary(会跟着蓝底自动换成白色,天然清晰),不铺蓝底
    // 的正常状态才用来源自己的品牌色,保持"一眼看出是哪个来源"这个设计意图不变。
    @Environment(\.backgroundProminence) private var backgroundProminence
    private var dimmed: Bool { backgroundProminence == .increased }

    var body: some View {
        Text(sourceDisplayName(source))
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(dimmed ? .primary : sourceColor(source))
            .background(dimmed ? Color.primary.opacity(0.18) : sourceColor(source).opacity(0.12), in: Capsule())
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
    // 跟 albumDisplayName 同一个道理:展示用的歌手名由外面算好传进来(优先 canonical),
    // 行视图自己不重复那套判断。
    let artistDisplayName: String
    let albumDisplayName: String
    // 列宽由调用方传入(而不是各自读单例):表头和每一行必须拿到**同一组**值才对得齐,
    // 而调用方那份已经过 fitted 收敛(窗口变窄时的临时等比缩放),行这边不能绕过它。
    let widths: LyricsColumnWidths

    // 图标槽位固定宽度(没有对应状态时用透明占位撑住位置,而不是整个不渲染)——保证
    // 不管某行是否人工修正、是逐字还是整行,几行的图标起始位置都对得齐。这两个图标算是
    // "歌名"这一列的附加信息(是否手工修正过/是逐字还是整行),跟着歌名走,不单独占一列
    // ——歌手/专辑/来源三列的宽度由调用方传入的 widths 决定(可拖拽调节)。
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

            Text(artistDisplayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: widths.artist, alignment: .leading)

            Text(albumDisplayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: widths.album, alignment: .leading)

            SourceBadge(source: summary.lyricsSource)
                .frame(width: widths.source, alignment: .leading)
        }
        .padding(.vertical, 3)
        // 让整行(含上下 3pt 内边距)都算命中这一行。不加的话在内边距上右键会被判成"点在
        // 空白处",而 contextMenu(forSelectionType:) 在空白处给的是空集 → 菜单不出现,
        // 表现成"右键有时候没反应"。
        .contentShape(Rectangle())
        // 把这一行内容的实际左右边界报给上层,表头照它对齐(见 RowContentBoundsKey 注释)。
        // 放在 .background 里,不影响布局。
        .background(
            GeometryReader { g in
                let f = g.frame(in: .named(LyricsColumnHeaderSpace.name))
                Color.clear.preference(key: RowContentBoundsKey.self,
                                       value: RowContentBounds(minX: f.minX, maxX: f.maxX))
            }
        )
    }
}
