import SwiftUI
import Combine
import LyrimuseCore

/// 只转发 appLanguage 的窄代理(2026-08-19 性能审计,照 OverlayPlayback/NotchPlayback 的
/// 既有模式):歌词管理窗口/搜索弹窗订阅 AppSettings 的唯一目的就是「手动切换语言时重新
/// 渲染」,而 @ObservedObject 整对象订阅会让 AppSettings 47 个 @Published 里任何一个变化
/// (设置页拖字号滑杆、拖色轮……)都触发这两个视图整个 body 重算 —— 歌词管理的 body 含
/// 全量筛选,设置窗同开时拖一下滑杆就是逐帧的全表重算。
@MainActor
final class AppLanguageObserver: ObservableObject {
    static let shared = AppLanguageObserver()
    @Published private(set) var appLanguage = ""
    private var sub: AnyCancellable?
    private init() {
        // sink 用参数值,不回读源属性(@Published willSet 时机,回读是旧值)。
        sub = AppSettings.shared.$appLanguage.removeDuplicates()
            .sink { [weak self] in self?.appLanguage = $0 }
    }
}

/// 只转发"当前播放的是哪首歌"的窄代理,同上面 AppLanguageObserver 一个套路。
///
/// 2026-08-25 用户报"歌词管理开着的时候换了首歌,高亮的还是开窗那一刻的旧歌"——原来
/// 只在开窗那一刻(`pendingAutoFocus`)和点「回到当前播放」按钮时定位一次,窗口开着期间
/// 换歌不会跟着动。这个窗口特意**不**整对象订阅 `PlaybackCoordinator`(见 detailView
/// 顶部注释:那个单例还同时发布 currentLine/anchor,播放中每秒 20 次刷新,订阅整对象会
/// 把这个窗口的 body 拖进 20Hz 重渲染),所以要单独开一条窄管道,只转发 artist/title/album
/// 这三个"换歌才变一次"的属性,合成一个去重后的签名串,给 `.onChange` 当触发信号用——
/// 真正的 key 匹配逻辑仍然读 `PlaybackCoordinator.shared` 的快照(见 focusCurrentlyPlaying),
/// 这里只负责"该不该再跑一次"。
@MainActor
final class LyricsManagerNowPlayingObserver: ObservableObject {
    @Published private(set) var trackSignature = ""
    private var sub: AnyCancellable?
    init() {
        let p = PlaybackCoordinator.shared
        sub = Publishers.CombineLatest3(p.$artist, p.$title, p.$album)
            .map { artist, title, album in "\(artist)|\(title)|\(album)" }
            .removeDuplicates()
            .sink { [weak self] in self?.trackSignature = $0 }
    }
}

// 歌词来源筛选——collector 只会写入这七种(见 collector/enrich.go 的 lyricCandidate
// source 取值),"无来源"对应老缓存(lyrics_source 字段是后来才加的,更早解析的
// 条目永久没有这个值,除非重新解析)。
private enum SourceFilter: Hashable, Identifiable {
    case all
    case named(String)
    case none

    static let all_: [SourceFilter] = [.all, .named("amll"), .named("netease"), .named("qq"), .named("kugou"), .named("musixmatch"), .named("lrclib"), .named("lyricfind"), .none]

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
    // 2026-08-30 加:纯文本(无时间戳)兜底跟"整行时间戳"是两回事——前者压根没有
    // 任何时间戳,不能跟随播放高亮,见 EnrichCacheStore.Summary.hasPlainTextFallback
    // 声明处的完整说明。
    case plainTextOnly = "仅纯文本"
    var id: String { rawValue }
}

/// 排序方式(2026-09-01,用户要求"加一个排序功能",筛选栏加一个下拉、九个预设组合)。
/// 「默认排序」原样对应改动前那套写死的(歌手,专辑,歌名)固定排序——不是新行为,只是
/// 第一次开放成"用户可以主动切走、也可以切回来"的一个选项,不切它列表长得跟改动前
/// 逐条一样。
///
/// 「更新时间」两档 2026-09-01 晚补上(用户点名要)。上面那版注释曾写着"没有这个候选,
/// 缓存里没有任何时间戳字段"——**结论对、理由不全**:缓存里确实没有一个表达"更新时间"的
/// 字段(实测覆盖率 decided_at 73% / translation_ts 25% / peripheral_ts 9% /
/// lyrics_rescore_ts 7%,全是偏科的局部时间戳,而 decided_at 还只反映"自动决策",手改
/// 歌词根本不动它),但**不需要扩缓存格式** —— 导出的歌词文件 mtime 就是这个信号,而且
/// 覆盖率 3169/3210。见 `Summary.lyricsUpdatedAt` 的头注(含"为什么它不会被 collector
/// 每次启动重写冲掉"这个关键前提)。
private enum LyricsSortOption: String, CaseIterable, Identifiable {
    case defaultOrder = "默认排序"
    case titleAscending = "歌名 A→Z"
    case titleDescending = "歌名 Z→A"
    case artistAscending = "歌手 A→Z"
    case artistDescending = "歌手 Z→A"
    case albumAscending = "专辑 A→Z"
    case albumDescending = "专辑 Z→A"
    case sourceAscending = "来源 A→Z"
    case sourceDescending = "来源 Z→A"
    case updatedDescending = "更新时间 新→旧"
    case updatedAscending = "更新时间 旧→新"

    var id: String { rawValue }

    /// 翻译成 LyrimuseCore 里那套纯规则。**规则本身**(哪一档优先、平局怎么断、缺失值
    /// 排在哪儿)住在 `LyricsSortOrder`,不在这里 —— 那边 lyrimuse-selftest 够得到,
    /// 能逐档钉住;留在这个 private enum 里的话一行覆盖都没有(搬走的缘由见它的头注)。
    var coreOrder: LyricsSortOrder {
        switch self {
        case .defaultOrder: return .defaultOrder
        case .titleAscending: return .title(ascending: true)
        case .titleDescending: return .title(ascending: false)
        case .artistAscending: return .artist(ascending: true)
        case .artistDescending: return .artist(ascending: false)
        case .albumAscending: return .album(ascending: true)
        case .albumDescending: return .album(ascending: false)
        case .sourceAscending: return .source(ascending: true)
        case .sourceDescending: return .source(ascending: false)
        case .updatedAscending: return .updated(ascending: true)
        case .updatedDescending: return .updated(ascending: false)
        }
    }

    /// 按这个选项给一份已经筛选完的列表排序。
    ///
    /// 排序键**一次性算好再排**,不在比较器里现算:`sourceDisplayName` 要走一次 L10n
    /// 查表,放进 O(N·logN) 的比较里会被调用上万次(跟 Summary 里那几个 norm* 字段
    /// 2026-08-19 预算好的动机一样)。其余字段都是 Summary 上现成的,只是搬进一个
    /// 值类型里。
    func sorted(_ items: [EnrichCacheStore.Summary]) -> [EnrichCacheStore.Summary] {
        let order = coreOrder
        return items
            .map { (key: $0.lyricsSortKey, item: $0) }
            .sorted { order.less($0.key, $1.key) }
            .map(\.item)
    }
}

extension EnrichCacheStore.Summary {
    /// 映射成排序用的纯值类型。歌手/专辑取的是归一化键(`normPrimaryArtist`/`normAlbum`,
    /// 折过简体+小写)而不是列表里展示的原始写法——理由见 `LyricsManagerRow` 调用点上方
    /// 2026-08-28 那条注释:"筛选/排序继续按统一名归并不变,只是这一列如实展示每条记录
    /// 自己的原始歌手名"。同一位歌手因为原始标签写法不同(简繁/大小写)被拆成两条记录时,
    /// 按归一化键排还能让它们挨在一起;按展示字符串排就会被拆到列表两端。
    var lyricsSortKey: LyricsSortKey {
        LyricsSortKey(
            normPrimaryArtist: normPrimaryArtist,
            normAlbum: normAlbum,
            title: title,
            searchTitleLower: searchTitleLower,
            sourceDisplayName: sourceDisplayName(lyricsSource),
            hasSource: !lyricsSource.isEmpty,
            lyricsUpdatedAt: lyricsUpdatedAt,
            resolvedAt: resolvedAt
        )
    }
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
//
// 按原串 memoize(2026-08-19 性能审计):CFStringTransform 是 ICU 调用、单次微秒级,而
// 排序/筛选/归并把它放进了 O(N)~O(N·logN) 路径;歌手/专辑名的重复率极高(几百条数据
// 只有几十个不同值),备忘之后全库只为每个**不同**字符串付一次。缓存无界但输入面就是
// 缓存里的歌手/专辑/筛选值,量级几百条、常驻几十 KB,可接受。
// NSLock + nonisolated(unsafe):主线程(筛选)和 EnrichCacheStore.buildSummaries 的
// 后台构建线程都会调,照 PlayCountFold.key 的同款 memo 模式。
private let toSimplifiedCacheLock = NSLock()
nonisolated(unsafe) private var toSimplifiedCache: [String: String] = [:]

func toSimplified(_ s: String) -> String {
    toSimplifiedCacheLock.lock()
    let hit = toSimplifiedCache[s]
    toSimplifiedCacheLock.unlock()
    if let hit { return hit }
    let mutable = NSMutableString(string: s) as CFMutableString
    CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
    let result = mutable as String
    toSimplifiedCacheLock.lock()
    toSimplifiedCache[s] = result
    toSimplifiedCacheLock.unlock()
    return result
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
    case "amll": return .orange
    // LyricFind(2026-08-25 加,检索走 YouTube Music 但只在数据真是 LyricFind 时才
    // 接受候选,见 collector/ytmusic.go 头注)。红色已经被网易云占了,选粉色作为下一个
    // 未占用色。
    case "lyricfind": return .pink
    // 酷我音乐(2026-08-31 加,见 collector/kuwo.go 头注)。红/绿/蓝/紫/橙/粉都被占了,
    // 选棕色作为下一个未占用色。
    case "kuwo": return .brown
    // 咪咕音乐(2026-09-04 加,见 collector/migu.go 头注)。红/绿/青/靛/紫/橙/粉/棕都被占了,
    // 选薄荷绿作为下一个未占用色。
    case "migu": return .mint
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
    // amll-ttml-db 是社区维护的 TTML 歌词库(github.com/amll-dev/amll-ttml-db),
    // 跟 Musixmatch/LRCLIB 一样是没有中文名的项目名,保留原名。
    case "amll": return "AMLL"
    // LyricFind(2026-08-25 加)——国际品牌名,没有约定俗成的中文译名,同上保留原名。
    // 检索机制上走的是 YouTube Music,但候选过滤只留真正的 LyricFind 数据(见
    // collector/ytmusic.go 头注),所以展示名如实叫 LyricFind、不叫 YouTube Music。
    case "lyricfind": return "LyricFind"
    // 酷我音乐(2026-08-31 加)——国内用户认得出的中文写法,同网易云/QQ/酷狗。
    case "kuwo": return L10n.t("酷我音乐")
    // 咪咕音乐(2026-09-04 加)——同酷我,用国内用户认得出的中文写法。
    case "migu": return L10n.t("咪咕音乐")
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

// 窗口位置/尺寸/所在屏幕的持久化(2026-08-24 补——「歌词窗口」2026-08-22 修过同一类
// 问题,这扇姐妹窗口当时漏补)。这扇窗完全靠 SwiftUI `Window(id:)` 的系统状态恢复,而
// 系统那套的问题不在"存不存",在**它不认识屏幕**:多显示器下拔插一次或换个分辨率,
// 窗口经常回到主屏、或者落在一块已经不存在的屏幕的坐标上——用户 2026-08-24 报的
// "歌词管理打开是这样的,左边都不展示了"正是这个:表格标题列被从左边硬切、且各行掉的
// 字符数不一样、没有省略号,跟 SwiftUI 自己"行内容超宽时右边省略号截断"的行为对不上,
// 唯一解释是窗口有一截落在了当前屏幕看不见的地方。
//
// 不复制 LyricsWindowView.swift 里 LyricsWindowController 整个类——那个还带置顶/
// 伪全屏/红绿灯重定位,跟这扇窗口无关;这里只抽最小的一份:存 frame(绝对屏幕坐标)+
// 所在屏幕的稳定 ID,恢复时先认屏幕,那块屏没了就整个放弃、交回系统默认,绝不拿旧坐标
// 往现有屏幕上硬摆;认得出屏幕但分辨率/缩放变了就把 frame 夹进它当前的可见区。
// 两把 key 用独立命名空间,不跟歌词窗口那两把混。
@MainActor
private final class LyricsManagerWindowFramePersistence: ObservableObject {
    private static let frameKey = "np:lyricsManagerWindowFrame"
    private static let screenKey = "np:lyricsManagerWindowScreenID"

    private weak var window: NSWindow?
    private var frameObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var persistFrameTask: Task<Void, Never>?

    /// 首次(以及每次 SwiftUI 重新求值 NSViewRepresentable 时)调用,只在真的换了一个
    /// 窗口实例时才重新挂观察者——同一扇窗口重复 attach 是空操作。
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // 先恢复再挂观察者:顺序反过来的话,恢复这一次 setFrame 会立刻触发 didMove/
        // didResize、把刚读出来的值原样再写一遍(无害但没意义),更糟的是恢复失败
        // (屏幕不在了)时会把系统摆的那个默认位置当成用户意图存下来。
        restorePersistedFrame(window)
        // 手动挂进「Window」菜单(= Dock 图标右键菜单里的窗口列表)——理由见姐妹窗口
        // LyricsWindowView.swift 的 LyricsWindowController.addToWindowsMenu 那段注释:
        // 2026-08-25 用户反馈"Dock 右键菜单里没有'歌词管理'",现场探针实测这扇窗最小化后
        // AXSubrole 也是 AXDialog(这次连「设置」「歌词窗口」一起测,三扇窗最小化后全都是
        // AXDialog——之前只测到「歌词窗口」时误以为是它独有的,其实是这个 App 的窗口普遍
        // 现象,「设置」当时凑巧没被抓到真正最小化的状态)。既然 AppKit 的自动"Window"菜单
        // 填充信不过,不管三扇窗谁是谁非,统一手动登记。
        window.isExcludedFromWindowsMenu = false
        NSApp.addWindowsItem(window, title: window.title, filename: false)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { note in
            if let win = note.object as? NSWindow { NSApp.removeWindowsItem(win) }
        }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        // didMove 和 didResize 合用一个回调:两者要存的东西完全一样,而拖动窗口边角同时
        // 产生这两个通知,分开挂只会写两遍。
        let persist: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePersistFrame() }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main, using: persist)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main, using: persist)
    }

    /// 拖动/缩放停下来之后再落盘,不去抖的话拖动期间每帧一次 UserDefaults 写
    /// (跟这个窗口里列宽拖动那次性能审计,2026-08-19,松手才落盘,同一个坑同一个修法)。
    private func schedulePersistFrame() {
        persistFrameTask?.cancel()
        persistFrameTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistFrame()
        }
    }

    private func persistFrame() {
        // 窗口还没真正上屏时 frame 可能是 SwiftUI 给的中间值,不足为据。
        guard let window, window.isVisible else { return }
        let defaults = UserDefaults.standard
        defaults.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
        // 屏幕认不出来(极少数情况 window.screen 为 nil)时把旧值清掉,而不是留一个跟
        // 这次 frame 对不上的屏幕 ID——下次恢复会拿错屏幕做校验。
        if let screen = window.screen, let id = ScreenIdentity.id(of: screen) {
            defaults.set(id, forKey: Self.screenKey)
        } else {
            defaults.removeObject(forKey: Self.screenKey)
        }
    }

    @discardableResult
    private func restorePersistedFrame(_ window: NSWindow) -> Bool {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: Self.frameKey) else { return false }
        let saved = NSRectFromString(raw)
        guard saved.width > 0, saved.height > 0 else { return false }
        // 认屏幕:存过 ID 就必须那块屏还在。不在 = 用户换了显示器配置,旧坐标没有
        // 任何意义。
        guard let id = defaults.string(forKey: Self.screenKey),
              let screen = ScreenIdentity.screen(withID: id) else { return false }
        // 夹进那块屏的可见区。存的时候屏幕分辨率可能跟现在不同(接同一块屏但改了缩放),
        // 不夹的话窗口会有一部分挂在屏幕外。
        let visible = screen.visibleFrame
        var frame = saved
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
        return true
    }
}

/// 用一个零尺寸的 NSView 拿到真实 NSWindow 交给 controller——跟 LyricsWindowView.swift
/// 的 LyricsWindowCapture 同一个套路。
private struct LyricsManagerWindowCapture: NSViewRepresentable {
    let controller: LyricsManagerWindowFramePersistence

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { controller.attach(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { controller.attach(window) }
    }
}

// 歌词管理窗口:浏览目前 collector 缓存了哪些歌的歌词、来源是什么,支持手动纠正内容、
// 联网重新搜索候选歌词(见 LyricsSearchSheet/LyricsSearchService)、
// 或整条删除(强制下次播放重新解析)。改动通过 EnrichCacheStore 落盘+踢一脚重启
// collector 生效(见该文件顶部注释,解释为什么必须这么做而不是直接改内存)。
struct LyricsManagerView: View {
    @ObservedObject private var store = EnrichCacheStore.shared
    // 窗口位置/尺寸/所在屏幕的持久化,见 LyricsManagerWindowFramePersistence 类头注。
    @StateObject private var windowFrame = LyricsManagerWindowFramePersistence()
    // 只为了让这个独立窗口(跟 SettingsView 不在同一棵视图树里)在手动切换语言时
    // 重新渲染。经 AppLanguageObserver 窄代理(见文件顶部),不整对象订阅 AppSettings。
    @ObservedObject private var languageSettings = AppLanguageObserver.shared
    // 窗口开着期间跟着换歌自动重新定位,见 LyricsManagerNowPlayingObserver 类头注。
    @StateObject private var nowPlaying = LyricsManagerNowPlayingObserver()
    // searchText 是搜索框里**正在打字**的内容(见 searchBar,手写 TextField 绑定,每敲一个
    // 字符都会变);committedSearchText 才是真正喂给 filtered 的那份,只在按下回车/点搜索
    // 按钮(两者都调 commitSearch())或者搜索框被清空时才更新。2026-08-26 用户反馈"输入就
    // 卡"——原因是 filtered 的缓存键
    // filterToken 里原来直接拼了 searchText,每敲一个字符 token 就变、缓存作废,store.summaries
    // 上百条全量重过滤一遍(还要重算 4~5 处引用点,见 FilteredCache 类头注),这在几百条记录规模
    // 下逐字符都能感觉到卡顿。拆成两份状态之后,没敲完之前 committedSearchText 不变、
    // filterToken 不变、filtered 直接命中缓存,真正的过滤只在用户明确"搜索完了"这一下发生。
    @State private var searchText = ""
    @State private var committedSearchText = ""
    // 搜索框的焦点态,只用来给 searchBar 的边框上一圈强调色高亮(2026-08-27 视觉细化)——
    // 纯展示用途，不影响 committedSearchText 那套提交逻辑。
    @FocusState private var searchFieldFocused: Bool
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
    // 单曲时间轴校正值:工具栏那个「已校准 N 首 / 清空」要跟着实时变(整对象订阅是安全的
    // —— 它只在用户动作时发布,不在播放热路径上,见 LyricsOffsetStore.trackOffsetCount)。
    @ObservedObject private var offsets = LyricsOffsetStore.shared
    // 已校准名单:详情页那颗「已校准」徽章和它下面那句说明认它(见 LyricsPinStore)。
    @ObservedObject private var pins = LyricsPinStore.shared
    // 一次拖拽开始那一刻的列宽快照——必须按"起点 + 累计位移"算,不能每次 onChanged 都在
    // 当前值上叠加增量:DragGesture 的 translation 是相对手势起点的累计值,不是帧间增量,
    // 叠加会让列宽以平方速度飞出去。
    @State private var dragStartWidths: LyricsColumnWidths?
    // List 里一行内容的实际左右边界(由行自己通过 preference 上报,见 RowContentBoundsKey)。
    @State private var rowContentBounds: RowContentBounds?
    @State private var showSearchSheet = false

    // MARK: - 「重新自动匹配」(2026-08-21)
    //
    // 跟隔壁「联网搜索候选歌词」的区别:那个是把候选摆出来让人挑,这个是**按 collector 自动
    // 解析那一套规则直接选冠军**(collector search-lyrics -pick,冠军由 Go 侧 pickLyricCandidate
    // 算 —— 那个函数带「匹配算法:智能/顺序优先」的设置分支,在 Swift 侧自己取最高分会跟自动
    // 决策给出不同答案,于是刚匹配好的结果又被后台自愈路径换掉)。
    //
    // 所有状态都带 key:详情页的状态是 View 级 @State、靠 onChange(of: key) 重载,不带 key 的话
    // A 歌跑出来的结果会画在 B 歌的页面上。
    @State private var rematchRunningKey: String?
    @State private var rematchDone = 0
    @State private var rematchTotal = 0
    @State private var rematchResult: RematchOutcome?
    /// 单调换代:回调和收尾都 guard 它,防"上一轮的收尾把新一轮的进行中状态关掉"
    /// (照抄 LyricsSearchSheet.load 里 searchGeneration 那套)。
    @State private var rematchGeneration = 0

    private struct RematchOutcome {
        enum Kind { case changed, unchanged, kept, empty, failed }
        let key: String
        let kind: Kind
        let text: String

        var icon: String {
            switch kind {
            case .changed: return "checkmark.circle.fill"
            case .unchanged: return "equal.circle"
            case .kept: return "hand.raised.fill"
            case .empty: return "text.badge.xmark"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch kind {
            case .changed: return .green
            case .unchanged: return .secondary
            case .kept, .empty, .failed: return .orange
            }
        }
    }
    @State private var showDecisionSheet = false
    // 2026-08-02 补上——"保存修改"点了之前完全没有任何肉眼可见的反馈,跟上面
    // showRefreshedFeedback("刷新"按钮已有的做法)是同一类问题、同一个修法:短暂切换成
    // "已保存"+对勾图标,1秒后自动变回去。
    // (原来这段还讲了「移除逐字时间轴」那个按钮的同款反馈,2026-08-18 那个按钮已去掉。)
    @State private var showSaveEditFeedback = false
    // 「歌词(LRC)」文本框标题行的拷贝按钮反馈,跟 showSaveEditFeedback 同一个理由:拷贝
    // 一大段文本到剪贴板本身没有任何肉眼可见的变化,不给反馈用户会怀疑点了没反应。
    @State private var showCopyLyricsFeedback = false
    @State private var sourceFilter: SourceFilter = .all
    @State private var timingFilter: TimingFilter = .all
    @State private var manualOnly = false
    @State private var missingLyricsOnly = false
    @State private var instrumentalOnly = false
    // nil = 全部歌手/专辑。跟 SourceFilter/TimingFilter 不同,歌手/专辑的候选值不是固定
    // 的几种,是从当前缓存数据里现算出来的(见 distinctArtists/distinctAlbums),所以
    // 这两个直接用 String? 而不是另建一个枚举。
    @State private var artistFilter: String?
    @State private var albumFilter: String?
    // 排序不是筛选(不改变"看得见哪些",只改变"看到的顺序"),所以特意不并进 filterToken——
    // 那个 token 是 filtered 结果集的缓存键/selectedKeys 收敛的触发信号,两者都只关心
    // "集合",不关心顺序,混进去只会让缓存判断多背一个跟"集合"无关的维度。
    @State private var sortOption: LyricsSortOption = .defaultOrder
    // 点了"刷新"却没有任何肉眼可见的变化时(比如内容根本没变),用户很容易以为按钮没
    // 反应——短暂切换成"已刷新"+对勾图标给个明确反馈,1秒后自动变回去。
    @State private var showRefreshedFeedback = false
    @State private var showClearAllConfirm = false
    // 跟上面那个刻意分开:清缓存(歌词内容)和清时间轴校正是两件独立的事,两条路都开着、
    // 互不连带 —— 校正值是用户一句句听出来的,比歌词内容宝贵得多(见 LyricsOffsetStore
    // 类型注释里"故意跟 EnrichCacheStore 彻底分开存"那一段)。
    @State private var showClearOffsetsConfirm = false
    // 「从自动备份恢复」用的三个状态。快照列表在 Menu 打开那一刻现读(autoSnapshots() 只
    // stat 目录,廉价),不常驻 @State —— 常驻的话清空之后新打的那份不会出现在菜单里。
    @State private var pendingRestoreSnapshot: LyricsBackupStore.Snapshot?
    @State private var showRestoreSnapshotConfirm = false
    @State private var restoreSnapshotResult: String?
    // "这次开窗还没有自动定位过当前播放的歌"。⚠️ 不能靠"selectedKeys 是空的"来判断这是不是
    // 一次全新的开窗——2026-08-07 实测坐实(加文件日志抓到 `focus bail: selection not empty`,
    // 第二次开窗时 sel=1):SwiftUI 的 Window scene 关掉之后**并不销毁根视图**,@State 原样
    // 留着,第二次打开时 selectedKeys 还是上次选的那一条。原来那道 `guard selectedKeys.isEmpty`
    // 于是从第二次开窗起就把定位整个挡掉了(选中不刷新、列表也不滚),表现成"选中的还是当前
    // 播放这首、但列表不会滚过去"——因为上次开窗时自动选中的本来就是它。
    // 窗口关闭时(根视图 .onDisappear)置回 true,所以是"每次开窗定位一次"而不是"整个 App
    // 生命周期只定位一次";用它当闸也顺带挡住侧栏被折叠/展开时 List 重新 onAppear 把用户
    // 当前选中项抢走这种误伤。
    @State private var pendingAutoFocus = true

    /// "这首歌正在联网搜歌词、collector 还没写出任何结论"这段窗口期的占位行(2026-08-27
    /// 用户反馈"首次搜索期间歌词管理完全看不到这条记录")。nil = 当前没有需要补的占位——
    /// 可能是没在播、也可能是缓存里已经有真实条目了。见 `refreshPlaceholder()`。
    @State private var placeholderSummary: EnrichCacheStore.Summary?

    private var hasActiveFilters: Bool {
        sourceFilter != .all || timingFilter != .all || manualOnly || missingLyricsOnly
            || instrumentalOnly || artistFilter != nil || albumFilter != nil
    }

    // 归并字典(歌手/专辑展示名、筛选下拉候选)2026-08-19 起全部下沉进 EnrichCacheStore,
    // 随 summaries 重建一次 —— 原来是这里的计算属性,每次访问全量重建:List 每物化一行
    // 就为专辑归并付一次 O(N) 次 ICU 变换,是本模块审计里最重的一条(锚点见
    // EnrichCacheStore.albumDisplayMap 的注释)。展示歌手名同样下沉(Summary.displayArtist)。

    private func albumDisplay(_ album: String) -> String {
        store.albumDisplayMap[toSimplified(album).lowercased()] ?? album
    }

    /// filtered 的缓存盒。@State 里包一个引用类型,让下面的计算属性能在 body 求值过程中
    /// 写缓存(View struct 本身不可变)—— filtered 在一次 body 构建里被独立求值 4~5 处
    /// (List 数据源/副标题计数/全选按钮/删除禁用/批量面板),不缓存就是 4~5 遍全量过滤。
    private final class FilteredCache {
        var token = "\u{0}"
        var generation = -1
        var result: [EnrichCacheStore.Summary] = []
    }
    @State private var filteredCache = FilteredCache()

    private var filtered: [EnrichCacheStore.Summary] {
        // 缓存键 = 全部筛选状态(filterToken,本来就为 onChange 拼好了)+ summaries 代数。
        let generation = store.summariesGeneration
        let token = filterToken
        if filteredCache.token == token, filteredCache.generation == generation {
            return filteredCache.result
        }
        // 循环不变量提到过滤循环外算一次(原来写在逐行闭包里,每行各付一遍);逐行侧
        // 全部用 Summary 的预计算归一化键,谓词只剩字符串比较。
        let q = committedSearchText.lowercased()
        let af = artistFilter.map { toSimplified($0).lowercased() }
        let bf = albumFilter.map { toSimplified($0).lowercased() }
        // 「正在搜索」占位行(见 refreshPlaceholder)并进同一份基础列表——刻意不给它开
        // 特例绕过下面这套筛选谓词:它没歌词/没来源/不是人工修正,该被"仅人工修正"筛掉
        // 就该被筛掉,跟真实条目一视同仁,不需要另外维护一套"占位行永远显示"的逻辑。
        let base = placeholderSummary.map { store.summaries + [$0] } ?? store.summaries
        let result = base.filter { s in
            if !q.isEmpty {
                // 歌手搜索两个写法都认:用户可能按原始写法搜(播放器里看到的那个),也可能按
                // 官方名搜(列表里显示的那个)。专辑名一起搜(2026-08-26):专辑筛选下拉已经
                // 能按专辑筛,但那是"选一个精确专辑名",搜索框是"打几个字模糊找",两者互补。
                guard s.searchArtistLower.contains(q)
                    || s.searchDisplayArtistLower.contains(q)
                    || s.searchTitleLower.contains(q)
                    || s.searchAlbumLower.contains(q) else { return false }
            }
            // 大小写/繁简不敏感比较(归并键口径,见 Summary.normPrimaryArtist/normAlbum)。
            if let af, s.normPrimaryArtist != af { return false }
            if let bf, s.normAlbum != bf { return false }
            guard sourceFilter.matches(s.lyricsSource) else { return false }
            switch timingFilter {
            case .all: break
            case .wordTiming: guard s.hasWordTiming else { return false }
            // 2026-08-30 补 s.hasLyrics 这道闸:改之前"仅整行"只看 !hasWordTiming,会把
            // 完全没有歌词/只有纯文本兜底的行也算进来(它们同样 hasWordTiming==false)——
            // "整行时间戳"该指真的有逐行 LRC 的那批,不是"反正不是逐字的都算"。
            case .lineOnly: guard s.hasLyrics && !s.hasWordTiming else { return false }
            case .plainTextOnly: guard s.hasPlainTextFallback else { return false }
            }
            // 「仅人工修正」现在并入「已校准」(手动调过时间轴偏移,见 LyricsPinStore):
            // 两者语义上并列,都是"用户已经亲手把这首歌弄对了",分开筛选只会让用户漏看
            // 那些只调过时间轴、没碰过歌词正文的行。
            if manualOnly && !s.isManual && !pins.isPinned(s.key) { return false }
            // 跟徽章/统计同口径:确证过的纯音乐、有纯文本兜底的都不是"缺歌词"
            // (2026-08-30 加后者)——这个筛选是用来找**该修的**,这两类行上已经显示着
            // 明确的结论("纯音乐"/"仅纯文本"),不该跟"真的一条候选都没有"混在一起。
            if missingLyricsOnly && (s.hasLyrics || s.isInstrumental || s.hasPlainTextFallback) { return false }
            // 「仅纯音乐」反过来找**已确证纯音乐**的那批——跟上面那条互斥但不合并:
            // 一个是"该修的"(缺歌词又不是纯音乐),一个是"不用修、只是想看看有哪些"
            // (确证过的纯音乐列表,比如核对专辑预取抓了哪些纯乐器曲目)。
            if instrumentalOnly && !s.isInstrumental { return false }
            return true
        }
        filteredCache.token = token
        filteredCache.generation = generation
        filteredCache.result = result
        return result
    }

    /// `filtered` 按当前排序方式排好的版本——List 的数据源、以及一切"顺序对用户可见"的
    /// 地方(比如 orderedVisibleKeys 那份删除计划)都该用这个,而不是 `filtered` 本身。
    ///
    /// 不另外包一层缓存盒:`filtered` 那份缓存是为了避开"每行现算一次 ICU 归并"这个
    /// 真正昂贵的操作(见 FilteredCache 声明处的注释),这里排序比较的全是预算好的
    /// normPrimaryArtist/normAlbum/searchTitleLower 字段,是廉价的字符串/元组比较,
    /// 一次 body 里被求值 2~3 遍(List 数据源 + orderedVisibleKeys)的成本可以忽略——
    /// 为它单独维护一套 token/generation 缓存盒反而是这次改动里最不值得的复杂度。
    private var sortedFiltered: [EnrichCacheStore.Summary] {
        sortOption.sorted(filtered)
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
            committedSearchText, sourceFilter.id, timingFilter.rawValue,
            String(manualOnly), String(missingLyricsOnly), String(instrumentalOnly),
            artistFilter ?? "", albumFilter ?? "",
            // 占位行的 key 也要算进去——它的出现/消失/换成另一首歌不会让
            // store.summariesGeneration 变(那条代数只跟 raw/真实条目有关),漏了这一项
            // filtered 的缓存盒就会在占位行刚补上/刚被真实条目顶替的那一刻还显示旧结果。
            placeholderSummary?.key ?? "",
        ].joined(separator: sep)
    }

    // 选中集合里"当前筛选结果中真的看得见"的那些,按列表显示顺序返回。
    //
    // ⚠️ 这是防误删的关键一道:filtered 是计算属性,selectedKeys 是独立 @State,行从筛选
    // 结果里消失后 SwiftUI 不保证替你把 key 从 selection 里剪掉。真实误操作路径:搜
    // "Jackson" 多选 8 条 → 清空搜索框 → 点删除,此时那 8 条一条也看不见,弹窗却写着 8 条,
    // 删完用户完全不知道删了什么,而这个删除是不可逆的(连 lyrics/ 下导出文件一起删)。
    // 所有删除入口和所有计数都走这个函数,保证"弹窗说删 N 条" == "列表里看得见的 N 条"。
    // 按 sortedFiltered 顺序(= 列表当前实际显示的顺序)而不是 Set 顺序,是为了让删除
    // 计划稳定可复现,并且跟用户在屏幕上看到的顺序一致(2026-09-01 加排序功能之前这里
    // 用的是 filtered,那时"filtered 顺序"=="显示顺序"是同一件事;加了排序之后两者
    // 分开了,这里必须跟着换成 sortedFiltered,否则"删除计划"的顺序会跟屏幕上看到的
    // 顺序对不上)。
    private func orderedVisibleKeys(_ keys: Set<String>) -> [String] {
        // 占位行永远排除在"可删除/可批量操作"范围之外——它不对应任何 raw 条目,删它没有
        // 意义(EnrichCacheStore.delete 本身会安全地把不存在的 key 过滤掉,这里提前排除
        // 是为了让"删除 N 条"这个数字如实反映真的会被删掉几条,不是靠下游兜底凑数)。
        sortedFiltered.compactMap { !$0.isSearching && keys.contains($0.key) ? $0.key : nil }
    }

    private var selectedVisibleKeys: [String] { orderedVisibleKeys(selectedKeys) }

    // 「全选」按钮和标题栏副标题「N / 总数 首」共用这份计数(见各自调用点的注释)——
    // 占位行不算进来,理由跟 orderedVisibleKeys 排除它一样:它不是一条真实记录,"全选 N
    // 首"和"N / 总数 首"这两个数字承诺的都是"真实记录"这件事,不该被一条临时状态行
    // 拉高。列表本身(filtered)仍然把占位行画出来,只是不计入这两处计数。
    private var selectableFiltered: [EnrichCacheStore.Summary] { filtered.filter { !$0.isSearching } }

    // 触发删除确认:先把待删清单快照下来再弹窗(理由见 pendingDeleteKeys 的注释)。
    private func requestDelete(_ keys: Set<String>) {
        let victims = orderedVisibleKeys(keys)
        guard !victims.isEmpty else { return }
        pendingDeleteKeys = victims
        showBatchDeleteConfirm = true
    }

    private func commitSearch() {
        committedSearchText = searchText
    }

    private func resetFilters() {
        sourceFilter = .all
        timingFilter = .all
        manualOnly = false
        missingLyricsOnly = false
        instrumentalOnly = false
        artistFilter = nil
        albumFilter = nil
    }

    // 侧栏顶部的品牌抬头(2026-08-27 用户对照方案A细化稿点名要这一块)：图标+"歌词管理"
    // 四个字，贴在 searchBar 上方。窗口本身已经有原生标题栏的 .navigationTitle("歌词管理")，
    // 这里再画一遍算是有意的重复——原生标题栏在失焦/全屏/无边框等场景下不一定显眼，这一行
    // 是内容区自己的、稳定可见的身份标记，很多打磨过的原生 App（Mail、提醒事项……）的侧栏
    // 顶部都有同样的"图标+名字"抬头，不是网页 demo 独有的装饰。
    // 图标沿用菜单栏"歌词管理…"那一项已经在用的 SF Symbol（MenuBarStatusMenu.swift），
    // 同一个功能在两个入口用同一个图标，不新造一套语言。
    private var brandHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "music.note.list")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            Text(L10n.t("歌词管理"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // 搜索栏——独立一行,贴在 filterBar 上方(2026-08-27 从原生 .searchable 换成手写行,
    // 见 searchBar 声明处注释)。
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                // 不用 .onSubmit(of: .search)(那是配 .searchable 原生搜索框专用的触发器,
                // 2026-08-27 实测在这扇窗口里不生效)——普通 TextField 配不带 of: 参数的
                // .onSubmit 是这个文件里已经验证过能用的既有写法(见 offsetSection 里
                // "歌词时间轴偏移"那个输入框的同款用法),回车会可靠触发。
                TextField(L10n.t("搜索歌手/歌名/专辑"), text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onSubmit(commitSearch)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                // 聚焦态描边换成强调色+略粗一档(视觉细化，2026-08-27)——原来无论有没有
                // 焦点都是同一条 8% 灰描边，输入框拿到键盘焦点这件事在视觉上完全没有反馈。
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(searchFieldFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                            lineWidth: searchFieldFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: searchFieldFocused)
            .frame(maxWidth: .infinity)

            // 搜索触发按钮挪到输入框右边(2026-08-27 用户要求"放到这里",并把输入框
            // 相应缩短腾出位置)——按钮本身是最朴素的 Button.action,不依赖 .searchable/
            // .onSubmit 那套内部机制,点了必定生效;禁用态 = 当前搜索已经是最新,没有
            // 新东西要查。
            Button(action: commitSearch) {
                Image(systemName: "magnifyingglass")
            }
            .help(L10n.t("搜索(或在搜索框按回车)"))
            .disabled(searchText == committedSearchText)
        }
        .font(.callout)
        // 搜索词一清空就立刻回到全量列表,不需要等按钮/回车——这个方向零过滤开销,
        // 理由见 committedSearchText 声明处的注释。
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty && !committedSearchText.isEmpty {
                committedSearchText = ""
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)

                Picker(L10n.t("歌手"), selection: $artistFilter) {
                    Text(L10n.t("全部歌手")).tag(String?.none)
                    ForEach(store.distinctArtists, id: \.self) { a in Text(a).tag(String?.some(a)) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)

                Picker(L10n.t("专辑"), selection: $albumFilter) {
                    Text(L10n.t("全部专辑")).tag(String?.none)
                    ForEach(store.distinctAlbums, id: \.self) { a in Text(a).tag(String?.some(a)) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)

                // 「排序」(2026-09-01,用户要求加排序功能,选的是"筛选栏加一个下拉"而不是
                // 点列表头排序那个方案)。宽度同样是量出来的(离屏 NSHostingView.fittingSize,
                // `.font(.caption)` + `.controlSize(.small)`,取九个选项里最长的一条):
                // 中文最长("专辑 A→Z" 这一档)118.0pt、英文最长("Default Order")140.0pt,
                // 跟「来源」「时间轴」同一个套路多留 30pt 余量给箭头/内边距/系统版本差异。
                //
                // ⚠️ 跟「来源」「时间轴」不同,这一行(歌手/专辑/排序)**没有**挂
                // `ViewThatFits` 反应窗口变窄——那套机制是 2026-08-31 专为下面那一行
                // (`filterControlsGroup` + `selectionAndFilterActions`)排的,这一行至今没有
                // 类似的处理:改动前只有「歌手」「专辑」两个下拉时也是同一个状况,只是
                // Spacer() 一直吃掉多余宽度、没人测过窗口缩到多窄会溢出。多这一个下拉之后
                // 触发溢出的窗口宽度阈值会更早一些,如果以后真收到"窗口缩到很窄这里挤成一团"
                // 的反馈,再照下面那一行的方法论(ViewThatFits + 固定宽度候选)补一套。
                Picker(L10n.t("排序"), selection: $sortOption) {
                    ForEach(LyricsSortOption.allCases) { option in
                        Text(L10n.t(option.rawValue)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Spacer()
            }

            // ⚠️ 2026-08-31 重排,修的是用户报的"这一排会随着点击选中变来变去"。三个成因,
            // 缺一不可地一起改掉(只改其中一个仍然会晃):
            //
            //  1. 两个 Picker 用的是 `.frame(maxWidth:)` —— maxWidth 只是**上限**,不是
            //     承诺。这一排一挤,它就往下掉,于是「来源」在不同状态下分别显示成
            //     "A..." / "All So..." / "All Sour..."。改成固定 `width:`。
            //  2. 三个胶囊没有行数限制,挤到一定程度就**换行成两行**,整排高度跟着跳。
            //     行数上限加在 PillChipToggleStyle 里(见那边)。
            //  3. 尾部那组控件的**组成本身**会变(未选中=「全选 N 首」;选中=「已选 N 首」+
            //     「取消选择」;有筛选再多一条分隔线+「清除筛选」),宽度需求跟着变,于是
            //     每点一下就把左边那半挤出不同的形状 —— 这才是"随点击变来变去"的直接原因。
            //     修法是给它一个**固定宽度**的槽位,内容在槽里换,槽不变。
            //
            // 为什么"固定宽度"这条特别重要:下面 `header(_:)` 那段注释已经为同一件事付过
            // 一次账 —— `ViewThatFits(in: .horizontal)` 比的是**理想宽度**,只要某个候选的
            // 宽度随状态变,候选就会来回翻,"转圈出现/消失会让整个顶部跳一下"。所以这里
            // 两个候选的理想宽度都必须与选中状态、与筛选状态无关,只跟窗口宽度有关。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterControlsGroup
                    Spacer(minLength: 12)
                    selectionAndFilterActions
                }
                // 装不下就把尾部那组挪到第二行(右对齐,位置感不变)。两个候选的宽度都是
                // 常量,所以选哪个只取决于窗口宽度 —— 点选歌曲不会让它在一行/两行之间翻。
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        filterControlsGroup
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        selectionAndFilterActions
                    }
                }
            }
        }
        // 三个筛选 chip("仅人工修正"/"仅无歌词"/"仅纯音乐")换成胶囊样式（2026-08-27
        // 用户对照方案A细化稿点名要），原来的 .toggleStyle(.button) 是系统原生按钮式
        // Toggle（矩形圆角、选中态是实心蓝底），这里这三个是这个 VStack 里仅有的三个
        // Toggle，直接在这一层换样式即可，不影响别处。
        .toggleStyle(PillChipToggleStyle())
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    /// 筛选控件本体(两个下拉 + 三个胶囊)。宽度是常量:下拉固定宽、胶囊单行不换行。
    ///
    /// 下拉的宽度是**量出来的**,不是拍的(2026-08-31,`.font(.caption)` 在这台机器上解析
    /// 成 10pt,用 NSFont 实测):
    ///   - 「来源」最长值 "Musixmatch" 58pt / "All Sources" 54pt,加菜单箭头与内边距约 28pt,
    ///     再加左边"Source"标签约 35pt → 需要约 121pt,给 150。
    ///   - 「时间轴」最长值 **"Word Timing Only" 86pt**(英文!),同样加箭头/内边距/标签
    ///     → 需要约 149pt,给 175。原来写的 110 连这个值本身都装不下 —— 那条注释里
    ///     "最长 4 字"量的是中文,英文这一档从来没被算进去过。
    @ViewBuilder
    private var filterControlsGroup: some View {
        Picker(L10n.t("来源"), selection: $sourceFilter) {
            ForEach(SourceFilter.all_) { f in Text(f.label).tag(f) }
        }
        .pickerStyle(.menu)
        .frame(width: 150)

        Picker(L10n.t("时间轴"), selection: $timingFilter) {
            ForEach(TimingFilter.allCases) { f in Text(L10n.t(f.rawValue)).tag(f) }
        }
        .pickerStyle(.menu)
        .frame(width: 175)

        Divider().frame(height: 14)

        Toggle(L10n.t("仅人工修正"), isOn: $manualOnly)
        Toggle(L10n.t("仅无歌词"), isOn: $missingLyricsOnly)
        Toggle(L10n.t("仅纯音乐"), isOn: $instrumentalOnly)
    }

    /// 选择状态 + 清除筛选。**内容随状态变,宽度不变** —— 固定宽度的槽位是这次修复的核心,
    /// 理由见上面 ViewThatFits 那段注释第 3 条。
    ///
    /// 280 的来历(同样是量的,取英文最坏情况):"2572 selected" 约 72pt + 间距 12 +
    /// 「Deselect All」按钮 57.5+20 + 间距 12 + 分隔线 1 + 间距 12 + 「Clear Filters」
    /// 按钮 58+20 ≈ 265,留一点余量给不同系统版本的按钮内边距差异。
    private var selectionAndFilterActions: some View {
        HStack(spacing: 12) {
            // 「全选筛选结果」给一个显式按钮,不能只靠 ⌘A:这个窗口的核心动线正是"在筛选
            // 栏勾出一批 → 立刻想全选删掉",此时焦点大概率还在上面那个原生搜索框上,⌘A
            // 会变成"全选搜索框里的文字"。按钮上带的数字跟标题栏副标题「N / 852 首」左边
            // 那个数完全一致,用户一眼能对上"我选的就是筛出来的这批"。
            if selectedKeys.isEmpty {
                if !selectableFiltered.isEmpty {
                    Button(String(format: L10n.t("全选 %@ 首"), "\(selectableFiltered.count)")) {
                        selectedKeys = Set(selectableFiltered.map(\.key))
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
        // 单行,不许因为数字变长(852 → 2572)而换行。
        .lineLimit(1)
        // 固定槽位 + 右对齐:内容少的时候空在左边,右缘永远咬着同一条线。
        .frame(width: 280, alignment: .trailing)
    }

    // 胶囊筛选 chip：未选中=描边+次要色文字，选中=强调色浅底+强调色文字（贴方案A细化稿）。
    // 用 Button 而不是原生 Toggle 的默认渲染——ToggleStyle 协议本来就是"给同一份
    // isOn/label 换一套画法"，这是它的标准用法，不是绕开 SwiftUI。
    private struct PillChipToggleStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                configuration.label
                    // ⚠️ 2026-08-31:这两行是"整排高度忽高忽低"的直接原因。原来标签没有
                    // 任何行数/尺寸约束,整排一挤,"Manually Edited Only"/"Missing Lyrics
                    // Only"这些英文长标签就**折成两行**,胶囊变高、整排跟着变高;中文标签
                    // 短,所以只在英文界面暴露。钉成单行 + 按内容取自然宽度之后,一个胶囊
                    // 的尺寸只跟它自己的文字有关,与这一排剩多少空间无关。
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(configuration.isOn
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        Capsule().stroke(configuration.isOn
                            ? Color.accentColor.opacity(0.45)
                            : Color.primary.opacity(0.12))
                    )
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
        }
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
            // 「偏移」是固定宽度、不可拖拽的第五列——跟另外三列不是一回事,没必要为了一个
            // 纯展示的数字列去扩 LyricsColumnWidths 那套拖拽夹值算术(见 offsetColumnWidth
            // 的注释),所以这里不挂 columnDivider。
            Text(L10n.t("偏移")).frame(width: Self.offsetColumnWidth, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        // 表头的横向范围**就是**行内容的横向范围([minX, maxX],由行自己上报,见
        // RowContentBoundsKey)。List(.inset) 给每行加的 inset 跟表头默认的内边距本来就
        // 不相等(实测 leading≈12pt、trailing 还含滚动条留白),错开的话分隔线就画不在
        // 列边界上了;这两个值是 AppKit 给的、会随系统版本变,所以运行时量,不硬编码。
        //
        // 用"定宽 + 左内边距"钉住右边界,而不是"左右内边距":右内边距只能由
        // (表头自身宽度 - maxX) 推出来,那就得**另外再量一次表头的宽度**——多出来的那个
        // 测量正是 2026-08-14 那个 bug 的来源,见 columnAreaWidth 的注释。
        .frame(width: columnAreaWidth > 0 ? columnAreaWidth : nil, alignment: .leading)
        .padding(.leading, headerLeading)
        // 还没量到行内容边界时(首帧/列表为空)退回对称的兜底内边距;量到之后右边界由上面
        // 的定宽决定,这里不能再加内边距,否则会把表头往左推、跟行错开。
        .padding(.trailing, columnAreaWidth > 0 ? 0 : Self.fallbackHPadding)
        .padding(.vertical, 5)
        // 定宽之后表头本身不再撑满整栏,补一个"占满、内容靠左"的外框,右键菜单和将来可能
        // 加的表头背景才覆盖整行宽度。
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(L10n.t("重置列宽")) { columnWidths.reset() }
        }
    }

    // 量不到行内容边界时的兜底内边距(首帧、或列表还没渲染出任何一行)。
    private static let fallbackHPadding: CGFloat = 12

    private var headerLeading: CGFloat { rowContentBounds?.minX ?? Self.fallbackHPadding }

    // 四列可以摊开的横向空间 = 行内容的宽度。列宽的收敛(fitted)和拖拽夹值(dragged)都只
    // 认这一个测量值。
    //
    // ⚠️ 2026-08-14 修的就是这里。原来这里用的是另一个 @State headerWidth,由表头
    // .background 里的 GeometryReader 通过 .onAppear/.onChange(of: g.size.width) 更新——
    // 而那对回调在首帧拿到一个很窄的宽度之后就**再也没有跟上后续布局**。真机证据:侧栏实际
    // 渲染宽度约 725pt(表头和每一行都按这个宽度画出来),但 fitted 拿到的宽度 ≤218pt,于是
    // budget 掉到三列下限之和以下、走进"极窄"分支,把三列**恒定**钳到各自下限(56/56/70)。
    // 存下来的值当时是 56/137.66/70:专辑存的是 137.66、画出来却是 56 —— 也就是说无论怎么
    // 拖、往哪个方向拖,存进去的值都被这一步抹平成同一组常量,界面纹丝不动,表现成"列宽根本
    // 拖不动",而且全程没有任何报错。
    //
    // 换成 rowContentBounds 之后只剩这**一个**几何输入,而它走的是 PreferenceKey ——
    // 布局每跑一遍就重新上报一次(这个文件里表头对齐一直用它,实测始终是准的),不像
    // GeometryReader 里的 onChange 会漏。少一个测量,就少一个能悄悄失效的东西。
    private var columnAreaWidth: CGFloat {
        guard let b = rowContentBounds else { return 0 }
        return max(0, b.maxX - b.minX)
    }
    // 「偏移」列固定宽度,不进 LyricsColumnWidths(那套拖拽夹值只管歌名/歌手/专辑/来源
    // 这三条可拖拽分隔条)——加宽这一列不用碰那段本来就最容易出错的算术,行为完全等价于
    // 把它当成 chrome 的一部分(下面 headerChrome 已经把它算进去了)。
    private static let offsetColumnWidth: CGFloat = 56

    // 四个 8pt 列间距(歌名/歌手/专辑/来源/偏移共 5 列、4 条间距)+ 偏移列固定宽度 =
    // 这一行里不属于三条可拖拽列、也不属于弹性歌名列的固定开销,算歌名列剩余宽度时要先
    // 扣掉它(见 LyricsColumnWidths.dragged/fitted 的 chrome 参数)。左右内边距不在
    // 其中——columnAreaWidth 量的已经是内边距**以内**的那一段。
    private var headerChrome: CGFloat { 8 * 4 + Self.offsetColumnWidth }

    // 真正拿去渲染的列宽:窗口/侧栏被拖窄后,用户存下来的列宽可能已经把歌名挤没,fitted
    // 会临时等比收敛(不改存下来的值)。还没量到宽度(=0)时 fitted 原样返回,首帧不会算出
    // 奇怪的宽度。
    private var shownWidths: LyricsColumnWidths {
        LyricsColumnWidths.fitted(columnWidths.widths, totalWidth: columnAreaWidth, chrome: headerChrome)
    }

    private func columnDivider(_ index: Int) -> some View {
        // 手柄 9pt 宽、居中压在两列之间那个 8pt 间距的正中:overlay 的 leading 让手柄左边缘
        // 贴着本列左边缘,而间距中点在本列左边缘往左 4pt 处,所以整体左移 9/2 + 4 = 8.5pt。
        ColumnDividerHandle(
            onDrag: { dx in
                if dragStartWidths == nil {
                    dragStartWidths = columnWidths.widths
                    // 拖动全程只更新内存值(@Published 照发,行实时重画),UserDefaults 的
                    // 三个 key 等松手一次性落盘 —— 原来每个鼠标事件写三笔中间态
                    // (2026-08-19 性能审计,onDragEnd 本来就在却没用来收口)。
                    columnWidths.beginDragging()
                }
                guard let start = dragStartWidths else { return }
                columnWidths.widths = LyricsColumnWidths.dragged(
                    from: start, divider: index, dx: dx,
                    totalWidth: columnAreaWidth, chrome: headerChrome
                )
            },
            onDragEnd: {
                dragStartWidths = nil
                columnWidths.endDragging()
            },
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
                    brandHeader
                    Divider()
                    searchBar
                    filterBar
                    Divider()
                    listColumnHeader
                    Divider()
                    List(sortedFiltered, selection: $selectedKeys) { summary in
                        // 2026-08-28 改用 summary.artist(原始写法)而不是 displayArtist
                        // (统一后的官方名)——理由见 EnrichCacheStore.Summary.displayArtist
                        // 的注释:筛选/排序继续按统一名归并不变,只是这一列如实展示每条记录
                        // 自己的原始歌手名,好让"同一首歌因原始标签不同被拆成两条记录"这种
                        // 情况在列表里能被用户一眼看出区别,而不是显示成一模一样。
                        LyricsManagerRow(summary: summary, artistDisplayName: summary.artist, albumDisplayName: albumDisplay(summary.album), widths: shownWidths, offsetColumnWidth: Self.offsetColumnWidth)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    // 首次开窗、summaries 还没任何内容时叠一个"正在加载"提示,不让空 List
                    // 看着像一片白屏(2026-08-26,用户反馈"打开歌词管理页面列表会白一会")。
                    // 用 .overlay 而不是拿 if/else 把 List 整个换掉:那样要把下面 .onAppear
                    // (真正触发 reload() 的地方)挪到一个"loading 分支和 loaded 分支都在
                    // 的容器"上才不会死锁(loading 时 List 不存在→onAppear 不触发→永远
                    // loading)——.overlay 直接叠在同一个 List 上,List 本身、它的 onAppear
                    // 一个字都不用动,只是内容还是空的那几百毫秒里多画一层提示。
                    .overlay {
                        if store.isLoading {
                            VStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L10n.t("正在加载…"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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
                        // orderedVisibleKeys 已经把「正在搜索」占位行排除在外(见其注释)——
                        // 右键点的这批选区如果全是占位行,deletable 就是空集,菜单不给任何
                        // 项,跟"空白处右键"是同一套既有行为,不需要额外分支。
                        let deletable = orderedVisibleKeys(keys)
                        if !deletable.isEmpty {
                            Button(role: .destructive) {
                                requestDelete(keys)
                            } label: {
                                Text(deletable.count == 1
                                    ? L10n.t("删除本地记录")
                                    : String(format: L10n.t("删除选中的 %@ 条"), "\(deletable.count)"))
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
                            // 跟 pendingAutoFocus 那道闸分开:占位行每次开窗/回到前台都要
                            // 重新核对(不像自动定位只做一次)——收起来的旧占位行可能早就
                            // 该顶替成真实条目了,也可能换了首新歌还在搜。
                            refreshPlaceholder()
                            guard pendingAutoFocus else { return }
                            pendingAutoFocus = false
                            // animated: false——开窗那一刻用户还没看过这个列表,从顶部一路
                            // 滚下去的动画没有任何信息量,只会让人等;而且首帧行高还没量完,
                            // 不带动画才好在量准之后补一次定位(见函数内注释)。
                            focusCurrentlyPlaying(scrollProxy: scrollProxy, animated: false)
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
                // 搜索框本身已经不是原生 .searchable 了(2026-08-27 换成 searchBar 手写行,
                // 见该属性声明处注释:原生 .sidebar 搜索框的 .onSubmit(of: .search) 实测在
                // 这扇窗口里按回车没反应,而且用户明确要求搜索按钮挪到输入框右边、输入框
                // 相应缩短——原生搜索框不支持这种自定义布局,只能手写)。
                .navigationTitle(L10n.t("歌词管理"))
                .navigationSubtitle(String(format: L10n.t("%@ / %@ 首"), "\(selectableFiltered.count)", "\(store.summaries.count)"))
                .toolbar {
                    ToolbarItem {
                        Button(action: refreshWithFeedback) {
                            Label(showRefreshedFeedback ? L10n.t("已刷新") : L10n.t("刷新"),
                                  systemImage: showRefreshedFeedback ? "checkmark" : "arrow.clockwise")
                        }
                    }
                    ToolbarItem {
                        // 跟开窗时自动定位复用同一个 focusCurrentlyPlaying,只是这次带动画:
                        // 用户正看着列表点的这个按钮,滚动过程本身就是"往哪儿跳了"的反馈。
                        Button {
                            focusCurrentlyPlaying(scrollProxy: scrollProxy)
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
                            // 时间轴校正值单独一段、单独一个清空入口:它跟歌词内容存在两个
                            // 完全不同的地方(UserDefaults vs 缓存 JSON + lyrics/ 文件夹),
                            // 清哪一个都不该连带另一个 —— 校正值是用户一句句听出来的,
                            // 比"下次播放会自动重新解析"的歌词内容宝贵得多。
                            Section {
                                Button(role: .destructive) {
                                    showClearOffsetsConfirm = true
                                } label: {
                                    Label(L10n.t("清空全部时间轴校正"), systemImage: "timer")
                                }
                                .disabled(offsets.trackOffsetCount == 0)
                            } header: {
                                Text(String(format: L10n.t("已校准 %d 首歌的歌词时间轴"),
                                            offsets.trackOffsetCount))
                            }
                            // 清空/批量删除之前自动打的快照,就地给一个恢复入口。
                            //
                            // 为什么必须在**同一个菜单**里:这两个不可撤销的按钮就在上面两段,
                            // 手滑之后第一反应是回到刚才点错的地方找后悔药。放进设置页的
                            // 「配置备份」里(那是"换机器"的语境)等于让人在最慌的时候去猜。
                            //
                            // 列表现读、不缓存:上面那颗「清空全部缓存」刚打的那份必须立刻
                            // 出现在这里。
                            let snapshots = LyricsBackupStore.autoSnapshots()
                            if !snapshots.isEmpty {
                                Section {
                                    ForEach(snapshots) { snapshot in
                                        Button {
                                            pendingRestoreSnapshot = snapshot
                                            showRestoreSnapshotConfirm = true
                                        } label: {
                                            // 纯排版,不进 L10n —— 两侧都是已本地化好的
                                            // 片段(DateFormatter / ByteCountFormatter),
                                            // 加一条只有括号的翻译条目没有意义。
                                            Label("\(Self.snapshotDateText(snapshot.date))（\(Self.byteText(snapshot.bytes))）",
                                                  systemImage: "clock.arrow.circlepath")
                                        }
                                    }
                                } header: {
                                    Text(L10n.t("从自动备份恢复"))
                                }
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
                // 去掉系统自动加的「隐藏边栏」按钮。
                //
                // NavigationSplitView 会自己往工具栏塞这一颗,而这个窗口的两栏是"歌曲列表 +
                // 选中那首的详情",不是"导航栏 + 内容" —— 把列表整个折叠起来之后剩下的详情页
                // 没有任何切歌入口,是个走不出去的状态。2026-08-14 用户实测点了直接卡死。
                //
                // 不是靠隐藏来回避卡死:这个窗口本来就不该有折叠侧栏这个动作,按钮存在本身
                // 就是 NavigationSplitView 的默认行为漏出来的,不是设计。
                .toolbar(removing: .sidebarToggle)
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
                    // 文案从"无法撤销"改成"会先自动备份":2026-08-22 起 clearAll 动手之前
                    // 一定先打一份快照(EnrichCacheStore.clearAll)。⚠️ 不能改成"随时可以
                    // 恢复"——快照只保留最近 3 份、库本来是空的时候压根打不出来,承诺过头
                    // 比不承诺更危险。
                    Text(String(format: L10n.t("这会删除当前全部 %d 条本地记录,包括你手动编辑、联网搜索采纳过的内容,已导出到本地的歌词文件也会一并删除。清空之前会自动备份一份,能从这个菜单里的「从自动备份恢复」找回来。下次播放会重新走一遍匹配解析"), store.summaries.count))
                }
                // 窗口开着期间换歌就跟着重新定位——不然停留在"开窗那一刻播的那首",见
                // LyricsManagerNowPlayingObserver 类头注。首次挂载时 trackSignature 已经是
                // 当前播放那首(CombineLatest3 订阅即发一次),不会跟 pendingAutoFocus 那次
                // 开窗定位重复触发;这里只在**后续**换歌时才会再跑一次。挂在这里(还在
                // ScrollViewReader 的 scrollProxy 作用域内)而不是外层 NavigationSplitView
                // 的修饰符链上——那边已经出了 scrollProxy 的可见范围。
                .onChange(of: nowPlaying.trackSignature) { _, _ in
                    // 必须先刷占位行再定位——focusCurrentlyPlaying 里"占位行也能被定位到"
                    // 那道判断读的是 placeholderSummary,换歌那一刻它还是上一首的,先刷新
                    // 才能让新歌(如果也在搜索中)被正确定位到。
                    refreshPlaceholder()
                    focusCurrentlyPlaying(scrollProxy: scrollProxy)
                }
                // 占位行等 collector 写完缓存才能自动"顶替"成真实条目——但换歌/reload 都
                // 不会在"同一首歌搜索完成"这一刻自动发生,得有个人主动再问一次磁盘。5 秒
                // 轮询一次(跟 PendingListensPanel 的 mtime 轮询同一个量级),reload
                // (onlyIfChanged: true) 本身很便宜——文件没变时只是一次 stat,只有真的
                // 搜完、文件真的变了才会有那一次解析开销。窗口关掉这个 .task 自动取消,
                // 不会有常驻计时器漏在后台。
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled, placeholderSummary != nil else { continue }
                        await store.reload(onlyIfChanged: true)
                        refreshPlaceholder()
                    }
                }
            }
        } detail: {
            Group {
                if let key = singleSelectedKey, let summary = store.summaries.first(where: { $0.key == key }) {
                    detailView(key: key, summary: summary)
                } else if let placeholder = placeholderSummary, singleSelectedKey == placeholder.key {
                    // 占位行没有对应的 raw 条目,不能走 detailView 那整套编辑/删除/重新自动匹配——
                    // 那些操作全部直接读写 raw[key],喂一个不存在的 key 进去没有意义。给一个
                    // 干净的只读说明就够了,等 collector 写完缓存,下一次 reload 会让这一行自然
                    // 变成真的一行,到时候点开就是正常的 detailView。
                    placeholderDetailView(placeholder)
                } else if selectedKeys.count > 1 {
                    batchSelectionPanel
                } else {
                    ContentUnavailableView(L10n.t("选择左侧一首歌"), systemImage: "text.quote")
                }
            }
            // NavigationSplitView 在 macOS 上会把侧栏那条 .navigationTitle 顺带在
            // detail 分栏顶部再画一遍(独立于真正的原生标题栏,两者都在,是重复渲染
            // 不是原生标题栏本身)——2026-08-27 用户对照方案A细化稿反馈"既然左边
            // brandHeader 已经有了,右边这个可以删掉"。给 detail 分支单独设一个空
            // 标题,盖掉这层继承来的重复,不影响侧栏那条 .navigationTitle 继续控制
            // 真正的窗口标题栏文字。
            .navigationTitle("")
        }
        .frame(minWidth: 780, idealWidth: 1040, minHeight: 540, idealHeight: 640)
        // 零尺寸探针拿真实 NSWindow 交给 windowFrame——放哪一层都行(只借视图树把
        // NSView 挂进窗口,不参与布局),挂在这里离上面 .frame 最近,读起来是同一件事。
        .background(LyricsManagerWindowCapture(controller: windowFrame).frame(width: 0, height: 0))
        // 刻意挂在最外层 NavigationSplitView 上 —— 跟侧栏那条链上的「清空全部缓存」、
        // List 上的「删除」分处三个不同层级。同一条修饰符链上叠多个呈现修饰符历史上有
        // 互相顶掉的问题(见那两处各自的注释),分层挂就不用去论证"这个版本会不会冲突"。
        .confirmationDialog(
            L10n.t("确定要清空全部歌词时间轴校正吗?"),
            isPresented: $showClearOffsetsConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("清空全部时间轴校正"), role: .destructive) {
                LyricsOffsetStore.shared.clearAllTrackOffsets()
                PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(String(format: L10n.t("这会清掉你为 %d 首歌手动调出来的歌词时间轴校正值,无法撤销。歌词内容本身不受影响;设置里的全局偏移和按播放器补偿也不会被清掉。清掉之后,这些歌会重新交给后台自动更新歌词源"), offsets.trackOffsetCount))
        }
        // 恢复确认。跟上面两个确认弹窗一样各挂各的层级,不叠在同一条修饰符链上。
        .confirmationDialog(
            L10n.t("确定要从这份备份恢复歌词库吗?"),
            isPresented: $showRestoreSnapshotConfirm,
            titleVisibility: .visible
        ) {
            // key 用「从备份恢复」而不是复用已有的「恢复」—— 那条的英文是 "Reset"
            // (「恢复默认」语境),这里是 restore,复用直接翻错。
            Button(L10n.t("从备份恢复")) {
                guard let snapshot = pendingRestoreSnapshot else { return }
                Task {
                    restoreSnapshotResult = await store.restoreFromAutoSnapshot(snapshot)
                        ?? L10n.t("这份备份读不出来")
                    pendingRestoreSnapshot = nil
                }
            }
            Button(L10n.t("取消"), role: .cancel) { pendingRestoreSnapshot = nil }
        } message: {
            // 说清楚它**不是**"回到那一刻的状态":铺文件是覆盖+新增,不删除备份里没有的
            // 条目(restore 走的是 LyricsBackupArchive.plan,只有 added/overwritten 两类)。
            // 用户以为是整体回滚、结果发现之后新解析的歌还在,那是另一种惊吓。
            Text(L10n.t("备份里的歌词文件会铺回歌词文件夹：同名的覆盖，缺的补上；备份之后新解析出来的歌不会被删掉。恢复完 collector 会重启一次，把它们重新读进缓存"))
        }
        .alert(L10n.t("恢复歌词库"), isPresented: Binding(
            get: { restoreSnapshotResult != nil },
            set: { if !$0 { restoreSnapshotResult = nil } }
        )) {
            Button(L10n.t("好")) { restoreSnapshotResult = nil }
        } message: {
            Text(restoreSnapshotResult ?? "")
        }
        // 见 AuxiliaryWindowActivation 注释——.accessory 策略下临时借一个 Dock 图标。
        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        // 切回 App 时重新读一次盘。
        //
        // 列表是**开窗那一刻的快照**,而 collector 在窗口开着期间会持续往同一个文件写:新歌
        // 是新增条目,给已有歌补机翻译文/逐字时间轴则是原地更新。不刷新的话,一首刚补上译文
        // 的歌在列表里始终不亮绿色的译文标记 —— 用户的原话是"这首歌明明有翻译,但没有译文
        // 的 tag",而歌词本身在悬浮窗里是正常显示的(那条路径读的是实时数据)。
        //
        // 挑"App 重新激活"当触发点,而不是上文件监听:典型用法就是切出去听歌、过一阵切回来,
        // 这个时机覆盖得住,而且 reload() 会把读盘+解析(缓存大了要 30ms 以上)放后台线程,
        // 不像 FSEvent 那样需要自己做防抖。窗口一直摆在副屏、人从不切走的情况仍然要靠工具栏
        // 的「刷新」—— 那颗按钮本来就在。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // onlyIfChanged:绝大多数激活时缓存文件根本没变,mtime 指纹相同就整条链
            // (读盘/解析/重建/summaries 重发布 → List 全量 diff)都不跑(2026-08-19)。
            Task { await store.reload(onlyIfChanged: true) }
        }
        .onDisappear {
            AuxiliaryWindowActivation.windowDidDisappear()
            // 见 pendingAutoFocus 的注释:@State 会跨关窗存活,得自己把这个闸复位,
            // 下次开窗才会重新定位一次。
            pendingAutoFocus = true
        }
    }

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
        // 「无歌词」这颗只数**真的缺**的:确证过的纯音乐、有纯文本兜底的都不该算进去,
        // 否则数字跟行上的徽章互相矛盾(行显示「纯音乐」/「仅纯文本」、上面却说它是无歌词)。
        let missing = picked.filter { !$0.hasLyrics && !$0.isInstrumental && !$0.hasPlainTextFallback }.count
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

    // 口径本体挪到 EnrichCacheStore.byteText —— 设置页「歌词库」那一行是第三处要显示同一个
    // 字节数的地方,再各自 new 一个 ByteCountFormatter 迟早分叉(见那边的头注)。
    private var cacheSizeText: String {
        EnrichCacheStore.byteText(store.totalSizeBytes)
    }

    // 自动备份那一行的两段文字。static 是因为它们在 Menu 的 ForEach 里被调,不碰任何
    // 实例状态;跟 cacheSizeText 同一套 ByteCountFormatter 口径,免得同一个菜单里两种写法。
    //
    // 日期用 .short + .short:这几份快照全是"刚刚/今天"的量级(只留 3 份),用户要分辨的是
    // "哪一次操作",精确到分钟就够,写全年月日反而把菜单撑宽。
    private static func snapshotDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func byteText(_ bytes: Int) -> String {
        EnrichCacheStore.byteText(Int64(bytes))
    }

    // 补/收「正在搜索歌词」占位行(2026-08-27,用户反馈"一首歌还在首次歌词搜索的时候,
    // 歌词管理页面看不到那条记录")。根因是这个列表的数据源(EnrichCacheStore.summaries)
    // 完全来自 collector 写的缓存文件——collector 联网搜索期间什么都不往文件里写(只保留
    // "搜到结果"的那次落盘,见 collector/enrich.go 的守卫),所以搜索还没出结论这段窗口期,
    // 这首歌在缓存文件里压根不存在,不是"存在但没显示"。
    //
    // 修法是在 Swift 侧合成一条**不落盘、不进 raw**的临时行,只在这个视图内部存在,展示层
    // 尽量复用现有的 Summary/筛选/排序管线(而不是另起一套"占位行专用渲染"),这样它天然
    // 能被搜索框/筛选/排序接住,也天然会被"回到当前播放"定位到——见下面几处对
    // `placeholderSummary` 的接线点。**不**在 collector 侧提前写占位:那会把"只保留有结果
    // 的解析"这条数据完整性设计复杂化,还要处理"占位条目 vs 真实条目"两套生命周期同时存在
    // 于同一份持久化文件里的一致性问题,风险明显更高,收益(仅仅是省下这个 Swift 侧的合成
    // 步骤)配不上。
    private func refreshPlaceholder() {
        let playback = PlaybackCoordinator.shared
        guard !playback.artist.isEmpty, !playback.title.isEmpty else {
            placeholderSummary = nil
            return
        }
        let key = EnrichCacheKeys.normalizedKey(
            artist: playback.artist, title: playback.title, album: playback.album)
        // 缓存里已经有真实条目了(collector 搜完了,不管搜到没搜到)——占位行让位,
        // 真实那一行会随下一次 summaries 重建自然出现在列表里。
        guard !store.hasEntry(forKey: key) else {
            if placeholderSummary?.key == key { placeholderSummary = nil }
            return
        }
        // 已经是同一首歌的占位行,不用重新构造一份新实例(纯避免无意义的 diff)。
        guard placeholderSummary?.key != key else { return }
        let display = playback.artist
        placeholderSummary = EnrichCacheStore.Summary(
            key: key,
            artist: playback.artist,
            canonicalArtist: "",
            durationSecs: Double(playback.currentDurationMs ?? 0) / 1000,
            title: playback.title,
            album: playback.album,
            lyricsSource: "",
            hasWordTiming: false,
            isManual: false,
            sourceChoice: "",
            offsetMs: 0,
            lyricsTrSource: "",
            hasTranslation: false,
            hasRomanization: false,
            hasLyrics: false,
            isInstrumental: false,
            hasPlainTextFallback: false,
            isSearching: true,
            hasDecision: false,
            // 这一行是「正在搜索这首歌的歌词」占位,磁盘上还没有它的歌词文件,
            // 缓存里也还没有这个 key(所以也没有 ts)。
            lyricsUpdatedAt: nil,
            resolvedAt: nil,
            normPrimaryArtist: toSimplified(primaryArtist(display)).lowercased(),
            normAlbum: toSimplified(playback.album).lowercased(),
            searchArtistLower: playback.artist.lowercased(),
            searchDisplayArtistLower: display.lowercased(),
            searchTitleLower: playback.title.lowercased(),
            searchAlbumLower: playback.album.lowercased()
        )
    }

    // 选中并滚动到当前正在播放的这首歌(如果它已经被缓存过)——开窗时自动跑一次
    // (见 pendingAutoFocus),工具栏"回到当前播放"按钮手动跑。key 跟
    // EnrichCacheStore.splitKey 用的是同一套 "歌手|歌名|专辑" 拼法,PlaybackCoordinator
    // 转发的 artist/title/album 本来就来自 media-control/relay,跟 collector 当初写入
    // 缓存时用的是同一份数据,能精确对上。找不到对应缓存条目时静默不做任何事,不弹提示——
    // 开窗自动定位场景本来就不该弹,手动点按钮那次真找不到时用户自己也看得出列表没跳。
    //
    // 只在这里读一次 PlaybackCoordinator.shared 的当前值,不声明成 @ObservedObject——
    // 那个单例还同时发布 currentLine/anchor,播放中每秒 20 次刷新(本地模式的快速
    // 计时器),整个窗口订阅它会导致 body 跟着每秒重算 20 次,把手动点选/刷新按钮的
    // 交互闷在这阵持续重渲染里,表现成"点了跟没点一样"。这里只需要调用那一刻的快照,
    // 普通函数内直接访问单例属性即可,不用建立订阅。
    private func focusCurrentlyPlaying(scrollProxy: ScrollViewProxy, animated: Bool = true) {
        let playback = PlaybackCoordinator.shared
        // ⚠️ key 必须走 EnrichCacheKeys.normalizedKey —— 那是缓存 key 在 Swift 侧的**唯一
        // 构造点**(逐字节镜像 collector 的 enrichKey)。手拼 "artist|title|album" 会漏掉
        // 两道清洗:cleanTag(各类空格/零宽字符)和 normalizedTitle(循环剥结尾括号里的副题)。
        //
        // 2026-08-20 用户报「进歌词管理不会自动定位到正在播的曲目」,实测就是这条:
        // Apple Music 报的是「Dynasties and Dystopia (from the series Arcane League of
        // Legends)」,而缓存里那条 key 是剥掉副题的「Dynasties and Dystopia」——精确匹配
        // 落空,而 looseKey 只折大小写/空格/繁简、折不掉那段副题,于是本函数静默返回,
        // 表现成"开窗压根没定位"。悬浮窗/灵动岛那边没事:EnrichCacheReader 一直走的是
        // normalizedKey。
        let normalizedKey = EnrichCacheKeys.normalizedKey(
            artist: playback.artist, title: playback.title, album: playback.album)
        // 原样拼的那个仍留作第二候选:key 归一化上线前入库的老条目按未清洗的写法存着
        // (磁盘上那份 .pre-keynorm.bak 就是那次迁移留下的),迁移漏掉的个案还能靠它命中。
        let rawKey = "\(playback.artist)|\(playback.title)|\(playback.album)"
        // 先精确命中,不中再按 looseKey(小写 + 去空格 + 繁转简)兜一次。
        //
        // ⚠️ 缓存里的 key 是**当初写进去那一刻**播放器报的原样,而播放器报的大小写/空格
        // 会漂。2026-08-19 用户报「歌词管理里定位不到 Shhh」,查下来正是这个:那条 08-17
        // 入库时上报的是 `Prince|Shhh|The Gold Experience`,而今天整张 The Gold Experience
        // 重播时报的是 `PRINCE|…`(同专辑今天新入库的 15 条全是 PRINCE)。精确比较落空、
        // 而且这个函数**找不到就静默返回**,看起来就像这首歌根本没被缓存过。
        //
        // 悬浮窗那边没事,是因为 EnrichCacheReader 早就有同一道兜底;collector 也有,所以
        // 它没有重复入库一条 PRINCE 的 —— 少的只有这一处。
        let candidates = normalizedKey == rawKey ? [normalizedKey] : [normalizedKey, rawKey]
        let key: String
        // 「正在搜索」占位行也要能被定位到——它此刻就是这首歌在列表里**唯一**存在的样子,
        // 见 refreshPlaceholder() 的注释。占位行的 key 恒等于 normalizedKey,直接判等即可。
        if let exact = candidates.first(where: { candidate in
            store.summaries.contains(where: { $0.key == candidate }) || placeholderSummary?.key == candidate
        }) {
            key = exact
        } else {
            let looseWanted = Set(candidates.map(EnrichCacheKeys.looseKey))
            guard let match = store.summaries.first(where: {
                looseWanted.contains(EnrichCacheKeys.looseKey($0.key))
            })?.key else { return }
            key = match
        }
        // 整体替换成这一条、不是追加:"回到当前播放"的语义是聚焦到这首歌。追加的话用户点完
        // 之后工具栏删除按钮上还挂着之前选的一堆,极易误删。
        selectedKeys = [key]
        DispatchQueue.main.async {
            if animated {
                withAnimation { scrollProxy.scrollTo(key, anchor: .center) }
            } else {
                scrollProxy.scrollTo(key, anchor: .center)
                // 开窗那一次要补一发。2026-08-07 实测(临时文件日志量 NSScrollView 的
                // documentVisibleRect + NSTableView.rect(ofRow:)):冷启动第一次滚的时候
                // List 还在陆续量后面那些行的真实高度(行高先按 24 估、量完是 31,
                // documentView 高度从 2639 变到 2800),按当时的行高算出来的落点差了两三行、
                // 没能真的居中。等这一轮布局走完再按最终行高定一次位,居中误差归零。
                // 不带动画,所以这次补正在视觉上就是"一开窗就已经在那儿"。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollProxy.scrollTo(key, anchor: .center)
                }
            }
        }
    }

    // 「正在搜索」占位行的详情——只读,不带任何编辑/删除/重新自动匹配按钮:这些操作全部
    // 直接读写 raw[key],喂一个不存在的 key 进去没有意义。等 collector 写完缓存、下一次
    // reload 把这一行换成真实条目之后,点开就是正常的 detailView,不需要用户做任何事。
    //
    // 2026-08-28 加「停止搜索」:用户反馈这段等待没有上限(见 cancelPlaceholderSearch 的
    // 注释),之前唯一的出路是干等。
    private func placeholderDetailView(_ summary: EnrichCacheStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            headerTitleBlock(summary)
            ContentUnavailableView {
                Label(L10n.t("正在搜索歌词…"), systemImage: "magnifyingglass")
            } description: {
                Text(L10n.t("这首歌第一次播放，正在联网搜索歌词，完成后会自动显示，不需要手动刷新。"))
            } actions: {
                Button(L10n.t("停止搜索")) { cancelPlaceholderSearch() }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 通知 collector"别再等这首歌的搜索结果了"。
    ///
    /// 起因(2026-08-28 用户反馈):这段"搜索歌词中…"的等待此前**没有任何上限**——
    /// `resolveTrackEnrichment` 内部歌词那一步有 20s 兜底,但整个函数(还跟着
    /// MusicBrainz/Apple Music/QQ 兜底封面这几步顺序网络请求)没有总超时,某一步卡住时
    /// 占位行会一直挂着,用户没有任何退出方式。
    ///
    /// 机制:写一个纯文本文件到 collector 的配置目录,里面就是这首歌的缓存 key——collector
    /// 有一个专门的后台 ticker(见 enrichcancel.go)按固定间隔检查这个文件,读到 key 就去
    /// `context.CancelFunc` 登记表里找,找到就调用,真正让还在飞的网络请求中断(不是"隔着
    /// 进程装个样子")。检查间隔意味着**不是瞬时生效**,但比完全没有退出方式好得多。
    ///
    /// App 侧不主动清空占位行,等 collector 真正写完再让位:collector 现在的取消分支
    /// (`resolveEnrichAsync` 里 `ctx.Err() != nil` 那支)不再是"什么都不写",而是跟"自然
    /// 查无"走同一条落盘路径,把这一轮标记成"暂无歌词"永久写回缓存(2026-08-28 改,起因是
    /// 用户反馈"点了停止搜索,记录不该直接消失,应该保留、标成无歌词,灵动岛/悬浮歌词也
    /// 不该继续显示搜索中")。既然缓存那边真的会有一条新记录,这里就不能再乐观地把
    /// `placeholderSummary` 清空——那样只会让这一行凭空消失,而下面 `.task` 里那个 5 秒
    /// 轮询是靠 `placeholderSummary != nil` 才会继续去问磁盘的(见那段注释),清空之后反而
    /// 没人再检查,除非用户碰巧做了别的触发 reload 的操作(换歌/重开窗口)。写完取消信号
    /// 什么都不做就够了:collector 落盘之后,现成的 5 秒轮询会自然探测到
    /// `store.hasEntry(forKey:)` 变 true,`refreshPlaceholder()` 里已有的"真实条目出现就
    /// 让位"逻辑会把这一行接手过去,变成一条正常的、标着"无歌词"的记录——不需要在这里
    /// 加任何新状态。灵动岛/桌面悬浮歌词走的是完全独立的一套刷新节奏(`LocalPlaybackSource`
    /// 的 2 秒轮询,靠 enrich 缓存文件 mtime 变化触发重读),不依赖这个窗口开不开,collector
    /// 落盘之后它们会各自在下一拍自动从"搜索歌词中…"切到"暂无歌词",不需要额外接线。
    private func cancelPlaceholderSearch() {
        guard let key = placeholderSummary?.key else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lyrimuse/lyrimuse-enrich-cancel-request.txt")
        try? key.write(to: url, atomically: true, encoding: .utf8)
    }

    @ViewBuilder
    private func detailView(key: String, summary: EnrichCacheStore.Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(summary)
                // 故意**不**放进 header 里的 actionTileGrid 那组方块:header 用的是
                // ViewThatFits(in: .horizontal),而它比的是理想宽度 —— 混进一句长文案会把
                // "标题和方块同一行"那个候选的理想宽度撑爆,方块组从此永久掉到第二行,而且
                // 转圈出现/消失会让整个顶部跳一下。放在 header 外面只影响竖向高度。
                rematchStatusRow(key: key, summary: summary)
                infoStrip(summary)
                offsetSection(summary)

                if summary.hasWordTiming {
                    wordTimingHint
                }

                editorSection(title: L10n.t("歌词(LRC)"), icon: "text.alignleft", text: $editedLyrics, minHeight: 220, monospaced: true, disabled: summary.hasWordTiming, showCopyButton: true)
                editorSection(title: L10n.t("译文"), icon: "character.book.closed", text: $editedTr, minHeight: 70, monospaced: false)
                editorSection(title: L10n.t("罗马音"), icon: "textformat.abc", text: $editedRoma, minHeight: 70, monospaced: false, latinIcon: true)

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
        .onChange(of: key) { _, newKey in
            loadDetail(key: newKey)
            // 换歌就把上一首的进行中/结果状态收掉,并把子进程停掉(它的结果已经没人要了)。
            // rematchGeneration 换代顺带让在飞的那一轮的回调和收尾全部失效。
            if rematchRunningKey != nil {
                rematchGeneration += 1
                rematchRunningKey = nil
                LyricsSearchService.shared.cancelRunning()
            }
            rematchResult = nil
        }
        .sheet(isPresented: $showDecisionSheet) {
            // 按钮只在 hasDecision 时出现;完整结构懒解码 —— 只在打开弹窗这一刻按 key
            // 解(2026-08-19,原来 rebuild 时全量急算,见 Summary.hasDecision 注释)。
            // 两槽都解:latest=最近一次评估,applied=当前歌词的出处(分槽语义见
            // collector/decision.go;老条目只有前者,弹窗 init 里自己退化)。
            let latest = store.decodedDecision(for: key)
            let applied = store.decodedAppliedDecision(for: key)
            if latest != nil || applied != nil {
                LyricsDecisionSheet(summary: summary, latest: latest, applied: applied)
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            // 采纳候选直接保存,不需要再手动点"保存修改"——避免让人误以为选了就已经
            // 存上了,结果只是填进了编辑框,还得再点一下保存才真正落盘。
            LyricsSearchSheet(
                artist: summary.artist, title: summary.title, album: summary.album,
                currentSource: summary.lyricsSource,
                // 「当前使用」双判据要的正文指纹(2026-09-04)。store.raw 是私有的,跟另外两个入口一样走
                // EnrichCacheReader.lookup(store 刚 persist 过的就是这份文件),三处口径一致。
                currentFingerprint: EnrichCacheReader.lookup(artist: summary.artist, title: summary.title, album: summary.album)
                    .map { ManualPickLock.fingerprint(lyrics: $0.lyrics) }.flatMap { $0.isEmpty ? nil : $0 },
                durationSecs: summary.durationSecs
            ) { candidate in
                // 仅纯文本的候选(2026-08-30 加)走完全独立的一条路——不写 editedLyrics/
                // editedTr/editedRoma(那三个编辑框是给带时间戳的 LRC 内容准备的,纯文本
                // 塞进去只会让用户以为能像平时一样调 offset/看逐字,其实什么都不对得上)、
                // 不 refreshOffsetState(offset 的整套机制建立在"对内容做 SHA256 指纹"上,
                // 纯文本没有时间戳、没有这个概念)、不经 saveEdit 的 markManual/sourceChoice
                // 这些"带时间戳歌词"专属的字段。见 EnrichCacheStore.savePlainTextEdit 头注。
                guard !candidate.isPlainTextOnly else {
                    let saved = await store.savePlainTextEdit(
                        key: key, plainLyrics: candidate.lyrics, source: candidate.source)
                    if saved { flashSaveEditFeedback() }
                    return saved
                }
                editedLyrics = candidate.lyrics
                editedTr = candidate.lyricsTr
                editedRoma = candidate.lyricsRoma
                // 「采纳候选」要不要顺带冻结这首歌,由 `manualPickLocksLyrics` 决定 ——
                // 而**两种状态都不写** lyrics_source_choice(空串 = 显式清掉)。
                //
                // 2026-08-22 这里曾有第三态:开关关着时记下"选了哪个源",自愈路径照常跑
                // 但被约束在该源内(collector 侧 pickLyricCandidatePreferring)。当时的想法
                // 是把"我手改过正文"和"我不同意这次选源"拆成强弱两级约束。
                //
                // 2026-09-01 用户看到设置里写出来的说明后当场否掉了这个中间态:他要的
                // 两态是「关 = 之后所有自动更新/优化照常调整这首歌,**不限制源**;
                // 开 = 就定在这份歌词上不动」。中间那档除了不是他想要的,本身也讲不清楚
                // —— 它是一个看不见的约束,只能靠歌词管理里事后一枚 pin 徽章解释"为什么
                // 这首歌一直是这个源"。于是关态改成什么痕迹都不留;存量缓存里那 6 条
                // lyrics_source_choice 也一并清掉了(清理记录见 docs/features/11)。
                //
                // ⚠️ 直接编辑正文那条路径(「保存修改」)**永远**置 manual_lyrics,不受这个
                // 开关影响——那份内容删了就找不回来,自动逻辑没有任何理由觉得自己比人工更懂。
                let saved = await store.saveEdit(key: key, lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                                                 roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                                                 source: candidate.source, markManual: AppSettings.shared.manualPickLocksLyrics,
                                                 sourceChoice: "", fromManualPick: true)
                // 采纳的候选歌词内容跟原来不一样,offset 的 key(内容指纹)也跟着变——
                // 输入框要显示"新内容对应的偏移值",不能继续显示采纳前那份内容的值。
                refreshOffsetState(artist: summary.artist, title: summary.title, lyrics: candidate.lyrics, yrc: candidate.lyricsYRC)
                // 2026-08-02 补上——采纳候选之前点了就直接关闭弹窗,真正的保存+重启
                // collector 在后台异步跑,用户看不到任何进度,失败时只能在下面
                // store.lastError 那行小字里发现。复用"保存修改"同一个反馈机制:
                // 成功就闪一下"已保存",失败不闪(已经有 lastError 的红字提示,不需要
                // 叠加两套反馈互相矛盾)。
                if saved { flashSaveEditFeedback() }
                return saved
            }
        }
    }

    /// 采纳候选成功后闪一下「已保存」—— 跟「保存修改」同一个反馈机制(showSaveEditFeedback)。
    /// 抽出来是因为 onApply 从 2026-09-04 起要**等保存结束再回报成败**(面板据此决定关不关窗、
    /// 挪不挪「当前使用」徽标),这 1 秒的收尾不能再挂在同一个 Task 里阻塞回报。
    private func flashSaveEditFeedback() {
        Task {
            withAnimation { showSaveEditFeedback = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showSaveEditFeedback = false }
        }
    }

    /// 详情页顶部:左边歌名/歌手/专辑,右边四个常用操作。
    ///
    /// 2026-08-27 操作区从"文字长条按钮"换成下面的固定尺寸图标方块 2×2 网格
    /// （`actionTileGrid`，用户对照 button-group-options.html 的方案 B 选定）——顺带
    /// 简化了这里:旧版按钮是文字长条,英文文案实测比中文长一截("Resolution decision /
    /// Auto re-match / Search Online for Lyrics / Delete Saved Lyrics"逐个都比中文长),
    /// 逼出过一版"一排/折两排/由 ViewThatFits 兜底"的三级布局,还是在英文下出过整页错位的
    /// bug（当时的教训注释見 git 历史）。方块网格从根上不受这个变量影响——每块固定
    /// `ActionTile.size` 宽高,标签超长就 `.lineLimit(2)` 截断,4 块的**总宽度是常量**,
    /// 跟中文/英文/任何语言都无关,所以这里只需要「标题和网格并排」/「标题在上、网格在下」
    /// 两种候选就够了,不再需要"网格自己再折两排"那一档。
    private func header(_ summary: EnrichCacheStore.Summary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                headerTitleBlock(summary)
                Spacer(minLength: 12)
                actionTileGrid(summary)
            }
            VStack(alignment: .leading, spacing: 10) {
                headerTitleBlock(summary)
                actionTileGrid(summary)
            }
        }
    }

    private func headerTitleBlock(_ summary: EnrichCacheStore.Summary) -> some View {
        // 三个 lineLimit 是兜底,不是主要防线(主要防线是上面那两种布局)。留着的理由:
        // 万一以后有人往这一行再塞一个按钮、或者出现某种极端窄的容器,把两种布局都挤穿,
        // 有行数上限至少只是被截断,不会退化成一字一行的竖排长龙。上限给得很宽松 ——
        // 按钮挪到第二行之后标题有整个面板宽度可用,正常内容根本碰不到。
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.title).font(.title2.weight(.bold)).lineLimit(3)
            Text(summary.artist).font(.title3).foregroundStyle(.secondary).lineLimit(2)
            if !summary.album.isEmpty {
                Text(albumDisplay(summary.album)).font(.callout).foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    /// 「解析决策」只在有存档时才出现（老条目没有），LazyVGrid 按行主序自动补位——
    /// 3 块时第 4 格自然留空，不会把其余三块的位置往前顶或重新洗牌，这正是"位置稳定"
    /// 这条要求要的效果:少一块只是网格右下角空一格，不是整组重新排列。
    private func actionTileGrid(_ summary: EnrichCacheStore.Summary) -> some View {
        LazyVGrid(
            columns: [GridItem(.fixed(ActionTile.size.width), spacing: 8),
                      GridItem(.fixed(ActionTile.size.width), spacing: 8)],
            spacing: 8
        ) {
            if summary.hasDecision {
                ActionTile(icon: "list.number", title: L10n.t("解析决策"),
                           help: L10n.t("当初为什么选了这份歌词：当时的候选、得分与拒绝原因")) {
                    showDecisionSheet = true
                }
            }
            // 「重新自动匹配」——按自动解析那套规则重跑一轮、直接采用算法选出的那一份。
            // 文案刻意不写「智能」:「智能算法」在这个产品里是设置页「匹配算法」的一个具体
            // 档位(另一档是「顺序优先」),写上去对选了顺序优先的用户就是在说谎(真正的
            // 冠军由 collector 按他选的那一档算,见 searchLyricsPick)。
            ActionTile(icon: "wand.and.stars", title: L10n.t("重新自动匹配"),
                       help: L10n.t("重新联网跑一遍匹配，直接采用算法选出的那一份，不用自己挑；跟设置里的「匹配算法」一致"),
                       disabled: rematchRunningKey != nil) {
                Task { await runRematch(key: summary.key, summary: summary) }
            }
            // 同一时刻只允许一个 collector 子进程(LyricsSearchService 每次 performSearch
            // 开头无条件 cancelRunning)。自动匹配飞行途中打开这个弹窗会把它杀掉,自动那边
            // 收到非零退出码、误报"搜索失败" —— 索性挡住,跟旧版 searchButton 的
            // .disabled(rematchRunningKey != nil) 是同一条约束。
            ActionTile(icon: "magnifyingglass", title: L10n.t("联网搜索候选歌词"),
                       help: L10n.t("联网搜索候选歌词"), disabled: rematchRunningKey != nil) {
                showSearchSheet = true
            }
            // 跟工具栏按钮、右键菜单走同一条 requestDelete → 侧栏那个确认弹窗的路径:
            // 只留一处弹窗,文案/统计/快照逻辑不会两处漂移。
            ActionTile(icon: "trash", title: L10n.t("删除本地记录"),
                       help: L10n.t("删除本地记录"), destructive: true) {
                requestDelete([summary.key])
            }
        }
        .fixedSize()
    }

    private func infoStrip(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 8) {
            InfoChip(
                icon: "arrow.down.circle",
                text: sourceDisplayName(summary.lyricsSource),
                tint: sourceColor(summary.lyricsSource)
            )
            // ⚠️ 跟列表那颗同名徽章同一个坑:hasWordTiming 在"完全没有歌词"时也是
            // false,不加 hasLyrics 这道闸的话,无歌词的条目也会显示一个看起来像真结论
            // 的"整行歌词"——下面 `!summary.hasLyrics` 那组分支才是这种情况该显示的内容。
            if summary.hasLyrics {
                InfoChip(
                    icon: summary.hasWordTiming ? "text.word.spacing" : "text.alignleft",
                    text: summary.hasWordTiming ? L10n.t("逐字时间轴") : L10n.t("整行歌词"),
                    tint: summary.hasWordTiming ? .blue : .secondary
                )
            }
            if summary.isManual {
                InfoChip(icon: "pencil.circle.fill", text: L10n.t("人工修正"), tint: .orange)
            }
            // 「来源已选定」= 用户在「联网搜索候选歌词」里挑过一次源(2026-08-22)。跟
            // 「人工修正」分开显示,因为它们的约束强度差一个量级:那个一票否决全部自动路径,
            // 这个只把重选**约束在这个源内** —— 打分改进、这个源后来给出逐字,照样能升上来。
            // 之所以也必须标出来,理由跟「已校准」一样:它同样是一个看不见的约束,不说清楚
            // 的话"为什么这首歌一直是这个源"查不出来。解除办法是那颗「重新自动匹配」。
            //
            // ⚠️ 2026-09-01 起这枚徽章**永远不会亮**:这个字段没有写入方了,而且 collector
            // 每次启动都会把存量清空并转成 manual_pick_sha(见 manualpickmigrate.go)。
            // 留着纯粹是因为"删掉这套机制"是一次独立的清理(字段 + preferring 函数 + 单测 +
            // 详情面板和列表两枚徽章),不该混进改开关语义那次改动;留着也不产生任何行为
            // 差异。要删就跟 collector 侧一起整套删。
            if !summary.sourceChoice.isEmpty {
                InfoChip(icon: "pin.circle.fill",
                         text: String(format: L10n.t("来源已选定：%@"),
                                      sourceDisplayName(summary.sourceChoice)),
                         tint: .indigo)
            }
            // 「已校准」= 用户手动调过这首歌的时间轴偏移。必须显式标出来,因为它带一个
            // **看不见的副作用**:collector 从此不再自动给这首歌重选歌词源(见
            // LyricsPinStore)。不说清楚的话,"为什么这首歌不跟着升级了"是个查不出来的状态。
            if pins.isPinned(summary.key) {
                InfoChip(icon: "timer", text: L10n.t("已校准"), tint: .teal)
            }
            // 机翻的译文单独标出来,不让它冒充歌词源自带的社区翻译 —— 跟"人工修正"徽章
            // 同一个原则:凡是"这份内容是哪来的"能影响用户判断的,就如实说。
            if summary.hasTranslation
                && summary.lyricsTrSource == LyricsTranslationSource.machineSentinel {
                InfoChip(icon: "character.book.closed", text: L10n.t("机器翻译"), tint: .purple)
            }
            if !summary.hasLyrics {
                // 图标跟歌词窗口的纯音乐占位保持一致(waveform),颜色也从红色降成中性。
                if summary.isInstrumental {
                    InfoChip(icon: "waveform", text: L10n.t("纯音乐"), tint: .secondary)
                } else if summary.hasPlainTextFallback {
                    // 2026-08-30 加,理由同 isInstrumental 那档:有纯文本兜底不是"什么都
                    // 没有",不该跟真的一条候选都没有共用刺眼的红色。
                    InfoChip(icon: "text.quote", text: L10n.t("仅纯文本"), tint: .orange)
                } else {
                    InfoChip(icon: "text.badge.xmark", text: L10n.t("无歌词"), tint: .red)
                }
            }
            Spacer()
        }
    }

    // 单曲歌词时间轴偏移——跟菜单栏"歌词时间轴"(边听边点着调)是同一份数据
    // (LyricsOffsetStore),这里是给想直接敲一个精确数值的场景用的输入框,不用先听
    // 一遍再一点点试。回车或点"应用"才真正写入+让当前播放立刻生效,不是敲一个字符
    // 就实时应用(半个数字、负号打到一半时不该被当成有效值提交)。
    private func offsetSection(_ summary: EnrichCacheStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
        // 校准过之后行为会变,就在动手的地方说清楚 —— 别让用户事后去猜。
        if pins.isPinned(summary.key) {
            Text(L10n.t("已校准的歌不再自动更换歌词源:后台一换歌词内容,这个校正值就会失效。把偏移改回 0 即解除"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        }
        // 卡片化(视觉细化，2026-08-27)：这一块本来是裸露的一行控件+一行说明，直接贴在
        // 上下相邻内容之间，跟旁边 infoStrip 的徽章行、wordTimingHint 的提示横幅比显得
        // 没有边界感。加一层跟 wordTimingHint 同量级的圆角卡片背景，形状语言统一。
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }

    private var wordTimingHint: some View {
        Label(
            // 2026-08-18 改文案:原来这句让用户"先点「移除逐字时间轴」",而那个按钮已经去掉
            // 了(见 actionsRow 里的注释)。现在指向仍然存在的那条路——换一份不带逐字的候选。
            L10n.t("播放用的是逐字时间轴,改「歌词(LRC)」不生效。要手改主歌词,先用「联网搜索候选歌词」换一份不带逐字的;译文/罗马音不受影响"),
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        // 描边（视觉细化，2026-08-27）：原来只有一层淡蓝底色，跟页面背景在浅色模式下
        // 对比度本来就低，加一圈同色系描边让这块"提示卡片"的边界更肯定。
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.18)))
    }

    /// latinIcon:图标必须画成拉丁字母才说得通(「罗马音」),理由见 LatinIconLabel。
    private func editorSection(title: String, icon: String, text: Binding<String>, minHeight: CGFloat, monospaced: Bool, disabled: Bool = false, latinIcon: Bool = false, showCopyButton: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Group {
                    if latinIcon {
                        LatinIconLabel(title, systemImage: icon)
                    } else {
                        Label(title, systemImage: icon)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                if showCopyButton {
                    Spacer()
                    // 文案跟着「解析决策」弹窗那个"拷贝"按钮统一(LyricsDecisionSheet),
                    // 全 App 只有这一个词表达"复制到剪贴板",不再多出一个"复制"当同义词。
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text.wrappedValue, forType: .string)
                        withAnimation { showCopyLyricsFeedback = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            withAnimation { showCopyLyricsFeedback = false }
                        }
                    } label: {
                        Label(showCopyLyricsFeedback ? L10n.t("已拷贝") : L10n.t("拷贝"),
                              systemImage: showCopyLyricsFeedback ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .disabled(text.wrappedValue.isEmpty)
                }
            }
            TextEditor(text: text)
                .font(monospaced ? .system(.body, design: .monospaced) : .system(.body))
                .frame(minHeight: minHeight)
                .padding(8)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                // 2026-08-02 补上——带逐字时间轴的歌曲,上面 wordTimingHint 已经用一段
                // 蓝色提示文字警告"改这个文本框不会生效",但文本框本身依然完全可编辑,
                // 容易被跳过阅读直接开始改,做一次看似成功、实际无效的修改。真正禁用
                // 输入(而不是仅靠文字提示),配合降低不透明度给出"这里现在改不了"的
                // 直观视觉反馈——想改主歌词得先换一份不带逐字的候选(跟 wordTimingHint 说的一致)。
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

            // 2026-08-18 去掉了「移除逐字时间轴」按钮(用户要求)。它做的事是把这条的逐字
            // 数据清空、好让主歌词文本框可编辑,但那个入口本身的收益很薄:逐字时间轴是这套
            // 打分里最值钱的东西(400 分),而清掉之后想找回更准的版本要靠重新解析、很可能
            // 又抓到同一份。想换歌词走「联网搜索候选歌词」那条路更直接。
            // EnrichCacheStore.removeWordTiming 暂时留着(见那边注释),没有调用方。

            Spacer()
        }
    }

    // MARK: - 「重新自动匹配」实现

    @ViewBuilder
    private func rematchStatusRow(key: String, summary: EnrichCacheStore.Summary) -> some View {
        if rematchRunningKey == key {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(rematchTotal > 0
                     ? String(format: L10n.t("正在重新匹配…（%1$@/%2$@）"), "\(rematchDone)", "\(rematchTotal)")
                     : L10n.t("正在重新匹配…"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let result = rematchResult, result.key == key {
            Label(result.text, systemImage: result.icon)
                .font(.caption)
                .foregroundStyle(result.tint)
        }
    }

    /// 跑一轮"按自动解析规则重选"。冠军由 collector 算(-pick),这里只负责:决定要不要采纳、
    /// 采纳时把 collector 自动路径会写的那一整套字段一起写、以及如实告诉用户发生了什么。
    private func runRematch(key: String, summary: EnrichCacheStore.Summary) async {
        rematchGeneration += 1
        let generation = rematchGeneration
        rematchRunningKey = key
        rematchResult = nil
        rematchDone = 0
        rematchTotal = 0
        // 歌词打分对时长极其敏感(时长档 +100~300 / overshoot -700,还是源内选歌的输入):
        // 实测同一首歌传 0 时 qq 482 第一、传真实 270.8s 时是 Musixmatch 962 胜出。所以优先
        // 用真实播放时长,老条目没有才退到 resolved(它可能是专辑预取时抓到的错版本时长)。
        let duration = summary.durationSecs > 0 ? summary.durationSecs : store.resolvedDurationSecs(for: key)
        var last: LyricsSearchService.SearchUpdate?
        do {
            try await LyricsSearchService.shared.search(
                artist: summary.artist, title: summary.title, album: summary.album,
                durationSecs: duration, pickWinner: true, currentSource: summary.lyricsSource
            ) { update in
                guard generation == rematchGeneration else { return }
                last = update
                rematchDone = update.sourcesDone
                rematchTotal = update.sourcesTotal
            }
        } catch {
            guard generation == rematchGeneration else { return }
            rematchRunningKey = nil
            rematchResult = RematchOutcome(key: key, kind: .failed, text: error.localizedDescription)
            return
        }
        guard generation == rematchGeneration else { return }
        rematchRunningKey = nil
        await finishRematch(key: key, summary: summary, update: last)
    }

    private func finishRematch(key: String, summary: EnrichCacheStore.Summary,
                               update: LyricsSearchService.SearchUpdate?) async {
        func done(_ kind: RematchOutcome.Kind, _ text: String) {
            rematchResult = RematchOutcome(key: key, kind: kind, text: text)
        }
        guard let update, let pick = update.pick else {
            done(.failed, L10n.t("这一轮没拿到结论，可以再点一次"))
            return
        }
        let currentName = sourceDisplayName(summary.lyricsSource)
        let winner = update.candidates.first(where: { $0.source == pick.winner })
        let detail = store.detail(for: key)
        // 五条分支的判定全在 LyrimuseCore.LyricsRematchDecision(纯函数,selftest 覆盖)——
        // 其中"不可判"和"逐字保护"两条是**不该动**的分支,它们失效时的表现是"用户看得见的
        // 东西被悄悄弄没了"、不是报错,靠反复点按钮碰运气验证不了。
        let outcome = LyricsRematchDecision.decide(
            decidable: pick.decidable,
            winnerSource: winner == nil ? "" : pick.winner,
            currentHasWordTiming: summary.hasWordTiming,
            winnerHasWordTiming: !(winner?.lyricsYRC.isEmpty ?? true),
            sameSource: winner?.source == summary.lyricsSource,
            sameLyrics: winner?.lyrics == detail.lyrics,
            sameWordTiming: winner?.lyricsYRC == detail.yrc
        )
        switch outcome {
        case .keptNotDecidable:
            done(.kept, String(format: L10n.t("这一轮「%@」没应答，没有换（避免误降级），可以再点一次"), currentName))
            return
        case .keptNoCandidate:
            // 三种成因分开说。
            if update.instrumental {
                // ⚠️ 2026-08-30 订正:上面这句"自动路径此时也是一个字都不写"已经不对了——
                // collector 的 rescoreLyrics 在这个局面下早就会把 instrumental 写回缓存
                // (enrich.go 那段"纯音乐结论也要在这条路径上落地",2026-08-20 补),这颗
                // 按钮走的是独立的 -pick 路径,之前只弹 toast、从没跟着写,导致「歌词管理」
                // 列表永远停在红色「无歌词」。见 markInstrumental 声明处的完整案例。
                await store.markInstrumental(key: key)
                done(.empty, L10n.t("有源明确说这首是纯音乐，没有可用的歌词候选"))
            } else if !summary.hasPlainTextFallback,
                      let plain = update.candidates.first(where: { $0.isPlainTextOnly }) {
                // 2026-08-30 补:collector 的 rescoreLyrics/resolveEnrichAsync 那两条
                // 后台路径已经会在"picked==nil 且有纯文本候选"时自动采纳(用户明确要求
                // 的行为,见 PlainLyrics 字段定义处的完整说明),但那两条只在**真实播放**
                // 触发的后台解析里跑——这颗按钮走的是独立的 -pick 路径,不会经过它们,
                // 之前只弹 toast、什么都不写,导致用户点了"重新自动匹配"却发现"还是
                // 没有"。这里镜像后台那条同一条"只在为空时写、绝不覆盖"规矩,把这颗按钮
                // 接上同一个能力——跟弹窗里手动点"采纳为静态文本"调用的是同一个方法。
                await store.savePlainTextEdit(key: key, plainLyrics: plain.lyrics, source: plain.source)
                done(.empty, L10n.t("没有找到带时间戳的版本，已自动采纳一份纯文本兜底（可在「歌词窗口」里查看）"))
            } else if update.networkLooksDown {
                done(.empty, L10n.t("网络似乎不通，这一轮没搜到任何候选"))
            } else {
                done(.empty, L10n.t("这一轮没有一个能用的候选，保留现有的"))
            }
            return
        case .keptWouldLoseWordTiming:
            done(.kept, String(format: L10n.t("这一轮没搜到逐字歌词，保留现有的「%@」（逐字）——换过去会丢掉逐字时间轴"), currentName))
            return
        case .unchanged:
            // 内容没换,但这一轮评估本身要留痕——见 EnrichCacheStore.recordUnchangedRematchDecision
            // 的头注(2026-09-01,呼应 collector 侧"可判的两个分支都写"那条既定规则)。
            await store.recordUnchangedRematchDecision(key: key, decisionJSON: pick.decisionJSON)
            done(.unchanged, String(format: L10n.t("已重新匹配：仍然是「%1$@」（%2$@ 分），没有更好的"),
                                    sourceDisplayName(pick.winner), "\(pick.winnerScore)"))
            return
        case .adopt:
            break
        }
        guard let winner else {
            done(.failed, L10n.t("这一轮没拿到结论，可以再点一次"))
            return
        }
        let winnerName = sourceDisplayName(winner.source)
        // 采纳。markManual: false 是这颗按钮跟「采纳候选」最本质的区别 —— 这是算法自己的选择,
        // 不该被标成人工修正、更不该因此把这首歌永久排除在后续自动升级之外(见 saveEdit 的
        // 参数注释)。打分留痕那几个字段照 collector rescoreLyrics 写的那一套一起写。
        var decision: [String: Any]?
        if let data = pick.decisionJSON.data(using: .utf8),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // ⚠️ 覆写 applied:collector 那边**看不到缓存里的正文**,只能拿"冠军是否换了源"近似
            // (searchLyricsPick 里写明了这是近似值)。同源换内容时它会算成 false,而「解析决策」
            // 弹窗把 false 渲染成「评估后维持原状」—— 跟结果行直接打架(2026-08-21 用户实测
            // 撞到:结果行说"换了一份"、存档说"维持原状")。走到这里就是真的采纳了,只有采纳
            // 这一条路径会写存档,所以无条件置 true。
            obj["applied"] = true
            decision = obj
        }
        editedLyrics = winner.lyrics
        editedTr = winner.lyricsTr
        editedRoma = winner.lyricsRoma
        await store.saveEdit(
            key: key, lyrics: winner.lyrics, tr: winner.lyricsTr, roma: winner.lyricsRoma,
            yrc: winner.lyricsYRC, source: winner.source, markManual: false,
            // 空串 = 显式清掉「用户选定的源」(2026-08-22)。这颗按钮的语义就是**完全**交回
            // 算法管理:留着 choice 的话,以后的自愈会被约束在"上次手动选的那个源"里,而用户
            // 刚刚明确说了"按算法重算一次"。它跟 manual_lyrics 一起被清,两个标记同进同出。
            sourceChoice: "",
            score: pick.winnerScore, scoringVersion: pick.scoringVersion,
            resolvedDurationSecs: pick.resolvedDurationSecs,
            sourcesSeen: pick.sourcesSeen, sourcesResponded: pick.sourcesResponded,
            decision: decision
        )
        refreshOffsetState(artist: summary.artist, title: summary.title,
                           lyrics: winner.lyrics, yrc: winner.lyricsYRC)
        guard store.lastError == nil else {
            // 落盘/重启失败不在这里重复报:store.lastError 那条红字横幅已经在说了。
            rematchResult = nil
            return
        }
        if winner.source == summary.lyricsSource {
            // 别说"更新的一份" —— 代码只知道"内容不一样",不知道哪份更新:同一个源完全可能
            // 这一轮匹配到**另一个版本**(不同 song id / 重新上传过的歌词)。实测坐实同源两轮
            // 返回的东西会变:周杰伦《I Do》点按钮那轮酷狗带逐字(wordTiming 400 分),十分钟后
            // 同一首同一个源一个逐字都不返回。所以如实说"哪里不一样",让用户自己判断。
            //
            // 三句完整句子而不是拼接:中文的"都"和英文的语序都拼不出来(同 batchDeleteMessage
            // 那条注释)。
            let textChanged = winner.lyrics != detail.lyrics
            let timingChanged = winner.lyricsYRC != detail.yrc
            let template: String
            if textChanged && timingChanged {
                template = L10n.t("已重新匹配：还是「%1$@」，但正文和逐字时间轴都跟原来那份不一样，已换成这一轮抓到的（%2$@ 分）")
            } else if timingChanged {
                template = L10n.t("已重新匹配：还是「%1$@」，但逐字时间轴跟原来那份不一样，已换成这一轮抓到的（%2$@ 分）")
            } else {
                template = L10n.t("已重新匹配：还是「%1$@」，但正文跟原来那份不一样，已换成这一轮抓到的（%2$@ 分）")
            }
            done(.changed, String(format: template, winnerName, "\(pick.winnerScore)"))
        } else {
            done(.changed, String(format: L10n.t("已换成「%1$@」（%2$@ 分），原来是「%3$@」"),
                                  winnerName, "\(pick.winnerScore)", currentName))
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
        // pinKey 用 summary.key(缓存 key 本身,已归一化)—— 播放侧算的是
        // EnrichCacheKeys.normalizedKey,两边必须是同一个身份,否则在这里校准的歌跟播放时
        // 钉住的歌是两条记录(见 LocalPlaybackSource.currentPinKey 的注释)。
        LyricsOffsetStore.shared.setOffset(ms, forKey: currentOffsetKey(summary), pinKey: summary.key)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: ms)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
        // 偏移改在 LyricsOffsetStore 里,不是这里的 raw 字典——summaries 里预算好的
        // offsetMs 和「仅人工修正」筛选的已校准判定都不会自己跟着变,得显式重建一次。
        store.rebuildSummaries()
    }

    private func resetOffsetEdit(_ summary: EnrichCacheStore.Summary) {
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey(summary), pinKey: summary.key)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: 0)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
        store.rebuildSummaries()
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

// 详情页顶部四个操作(解析决策/重新自动匹配/联网搜索候选歌词/删除本地记录)的固定尺寸
// 图标方块——2026-08-27 取代原来的文字长条按钮,理由见 LyricsManagerView.header 的注释。
// 图标在上、短标签在下,尺寸固定(见下面 Self.size),标签超长时 .lineLimit(2) 截断+
// .help() 兜底完整文案,不会像旧版文字按钮那样把整行撑宽。
private struct ActionTile: View {
    // 尺寸挂在这个类型自己身上(而不是 LyricsManagerView 那边)：Swift 的 private 是
    // 按"所在声明"限定作用域,不是按文件——LyricsManagerView 里的 private 常量,这个
    // 同文件但不同类型的 struct 是拿不到的。actionTileGrid 那边要用同一个宽度算
    // GridItem,直接读 ActionTile.size。
    static let size = CGSize(width: 92, height: 54)

    let icon: String
    let title: String
    let help: String
    var destructive: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(destructive ? Color.red : Color.secondary)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(destructive ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(destructive ? Color.red.opacity(0.22) : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
    }
}

// internal 而非 private——「解析决策」弹窗(LyricsDecisionSheet)复用同一个胶囊样式,
// 跟 sourceColor/sourceDisplayName 放开成 internal 是同一个理由。
struct InfoChip: View {
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
    // 「偏移」列固定宽度、不进 LyricsColumnWidths(见 LyricsManagerView.offsetColumnWidth
    // 的注释),但表头和行仍然要用同一个值才对得齐,所以照样由调用方传入。
    let offsetColumnWidth: CGFloat

    // 每个标记一个固定宽度的槽位,没有对应状态时放**透明占位**而不是整个不渲染 ——
    // 槽位数和宽度对每一行都一样,配合下面把整组推到歌名列尾,所有行的标记就落在同一条
    // 竖线上。
    //
    // 2026-08-10 之前这组图标是紧跟在标题文字后面的,于是 x 位置随标题长短浮动,一列
    // 看下来参差不齐(用户反馈"整齐一点")。固定槽位只能保证组**内部**对齐,保证不了组
    // 跟组之间 —— 那要靠 Spacer 把整组顶到列尾。
    private static let badgeIconWidth: CGFloat = 16

    // 这四个标记跟"搜索候选歌词"弹窗、详情页编辑区**共用同一组图标和配色**(蓝=逐字、
    // 绿=译文、紫=罗马音、橙=人工修正),用户在三个地方看到的是同一套语言。
    //
    // 译文/罗马音是 2026-08-10 补上的:值一直在缓存里(实测这台机器 11 条里 10 条有译文、
    // 1 条有罗马音),详情页和搜索弹窗都显示,唯独列表看不出来。
    @ViewBuilder
    private func badge(_ systemName: String, tint: Color, on: Bool, help: String,
                       forceLatinIcon: Bool = false) -> some View {
        Image(systemName: systemName)
            // textformat.abc 会跟着 locale 变成"甲乙丙"(中文)/"あいう"(日文),用在
            // 罗马音上正好跟含义相反 —— 钉成拉丁变体,理由见 LatinIconLabel。
            .environment(\.locale, forceLatinIcon ? Locale(identifier: "en") : .current)
            .foregroundStyle(tint)
            .font(.caption2)
            .frame(width: Self.badgeIconWidth)
            .opacity(on ? 1 : 0)
            // 没这个状态时连提示也别弹,否则鼠标划过一片透明占位会冒出一堆解释
            .help(on ? help : "")
            .accessibilityHidden(!on)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(summary.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    // 把标记整组顶到歌名列的尾部 —— 这一步才是"几行之间对得齐"的关键。
                    // minLength 留 8pt,标题长到顶格时也不会跟标记挤在一起。
                    Spacer(minLength: 8)
                    // 「正在搜索」占位行(2026-08-28 去掉转圈,只留文字):人工修正/逐字/
                    // 译文/罗马音这些字段此刻全是默认值,显示成"关"跟真的查出来是关是两件事,
                    // 干脆一个标记都不给——下面副标题那行的"搜索歌词中…"已经说明白了状态,
                    // 用户反馈"这几个字就够了,不用再加一个转圈"。
                    if !summary.isSearching {
                        badge("pencil.circle.fill", tint: .orange, on: summary.isManual,
                              help: L10n.t("人工修正过"))
                        // 「来源已选定」= 用户在「联网搜索候选歌词」里挑过一次源(2026-08-22),
                        // 跟上面「人工修正」是两件事——那个一票否决全部自动路径,这个只把
                        // 重选约束在这个源内(见详情面板同名 InfoChip 的注释)。2026-09-01
                        // 用户反馈补上:之前这个约束只在展开详情才看得到,列表本身完全没有
                        // 提示,容易让人误以为"选了却什么都没记住"。图标/颜色跟详情面板那颗
                        // 保持一致,help 文案里带上具体选的是哪个源。
                        badge("pin.circle.fill", tint: .indigo, on: !summary.sourceChoice.isEmpty,
                              help: String(format: L10n.t("来源已选定：%@"),
                                           sourceDisplayName(summary.sourceChoice)))
                        // ⚠️ on 不能写死 true:hasWordTiming 在"完全没有歌词"时也是 false,
                        // 会跟"整行时间戳"撞成同一个默认值——之前就是这么把"无歌词"的行也
                        // 画上了一个看起来很像真结论的"整行时间戳"图标。真正的判据是
                        // hasLyrics(有没有正文,不管是不是逐字),同一行下方的红色"无歌词"
                        // 文案用的也是这个字段,两处必须口径一致。
                        badge(summary.hasWordTiming ? "text.word.spacing" : "text.alignleft",
                              tint: summary.hasWordTiming ? .blue : .secondary, on: summary.hasLyrics,
                              help: summary.hasWordTiming ? L10n.t("逐字时间戳") : L10n.t("整行时间戳"))
                        // 2026-08-26 加机译/源自带区分:颜色跟详情页顶部的 InfoChip(见下方
                        // "机器翻译"那颗紫色小方块)统一,列表原来不管来源一律绿色,详情页却早就用
                        // 紫色标机译——同一份数据在两个地方讲两套语言。图标形状(书本)跟旁边罗马音
                        // 的 textformat.abc 已经不同,共用紫色不会认错是哪个标记。
                        badge("character.book.closed",
                              tint: summary.lyricsTrSource == LyricsTranslationSource.machineSentinel ? .purple : .green,
                              on: summary.hasTranslation,
                              help: summary.lyricsTrSource == LyricsTranslationSource.machineSentinel
                                  ? L10n.t("译文(机器翻译)") : L10n.t("译文(歌词源自带)"))
                        badge("textformat.abc", tint: .purple, on: summary.hasRomanization,
                              help: L10n.t("罗马音"), forceLatinIcon: true)
                    }
                }
                if summary.isSearching {
                    // ⚠️ 不能落进下面 !hasLyrics 那个分支:占位行的 hasLyrics/isInstrumental
                    // 都是默认值 false,会显示成刺眼的红色"无歌词"——那是"确认没有"的结论,
                    // 而这里连问都还没问完,两者不能混为一谈(正是这次要修的问题本身)。
                    Text(L10n.t("搜索歌词中…")).font(.caption2).foregroundStyle(.secondary)
                } else if !summary.hasLyrics {
                    // 确证过的纯音乐不算"缺东西":同一格换成中性色的「纯音乐」,别用红色
                    // 报警——它没什么要修的(2026-08-20 用户报「一堆显示无歌词、其实都是
                    // 纯音乐」)。判据是 collector 联网拿到的明确结论,不是猜的。
                    if summary.isInstrumental {
                        Text(L10n.t("纯音乐")).font(.caption2).foregroundStyle(.secondary)
                    } else if summary.hasPlainTextFallback {
                        // 2026-08-30 加:有纯文本兜底(「歌词窗口」已经在展示了)不是
                        // "什么都没有",不该跟真的一条候选都没有共用刺眼的红色。
                        Text(L10n.t("仅纯文本")).font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text(L10n.t("无歌词")).font(.caption2).foregroundStyle(.red)
                    }
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

            // 「来源」「偏移」两列在搜索中都还没有意义(没有来源、没有偏移可言)——留白
            // 而不是显示 SourceBadge("")/"0.0",那两种都会被误读成"已经查清楚了、结果
            // 就是空/零",跟"还没查完"是两个不同的结论。
            if summary.isSearching {
                Color.clear.frame(width: widths.source, alignment: .leading)
                Color.clear.frame(width: offsetColumnWidth, alignment: .leading)
            } else {
                SourceBadge(source: summary.lyricsSource)
                    .frame(width: widths.source, alignment: .leading)

                // 时间轴校正值,正数=提前显示、负数=延后显示(跟详情页「歌词时间轴偏移」
                // 输入框旁边那句说明同一个语义)。没调过/没歌词都会算成 0,展示上不特殊区分——
                // "0.0" 本身就如实说明了"没有偏移"。
                Text(AppSettings.signedSeconds(ms: summary.offsetMs))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: offsetColumnWidth, alignment: .leading)
            }
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
