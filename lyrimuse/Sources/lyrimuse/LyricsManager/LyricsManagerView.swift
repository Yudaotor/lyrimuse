import SwiftUI
import Combine
import LyrimuseCore

/// 只转发 appLanguage 的窄代理(性能审计,照 OverlayPlayback/NotchPlayback 的
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
/// 让高亮跟着"窗口开着期间换歌"实时更新,不止在开窗那一刻和点「定位」时定位一次。这个窗口特意**不**整对象订阅
/// `PlaybackCoordinator`:那个单例还同时发布 currentLine/anchor,播放中每秒 20 次刷新,订阅整对象会
/// 把这个窗口的 body 拖进 20Hz 重渲染,所以要单独开一条窄管道,只转发 artist/title/album
/// 这三个"换歌才变一次"的属性,合成一个去重后的签名串,给 `.onChange` 当触发信号用——
/// 真正的 key 匹配逻辑仍然读 `PlaybackCoordinator.shared` 的快照(见 focusCurrentlyPlaying),
/// 这里只负责"该不该再跑一次"。封面换歌之后晚一拍才到,单独转发给「正在播放」那一行。
@MainActor
final class LyricsManagerNowPlayingObserver: ObservableObject {
    @Published private(set) var trackSignature = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var displayArtist = ""
    private var sub: AnyCancellable?
    private var artworkSub: AnyCancellable?
    private var displayArtistSub: AnyCancellable?
    init() {
        let p = PlaybackCoordinator.shared
        sub = Publishers.CombineLatest3(p.$artist, p.$title, p.$album)
            .map { artist, title, album in "\(artist)|\(title)|\(album)" }
            .removeDuplicates()
            .sink { [weak self] in self?.trackSignature = $0 }
        // 「正在播放」那一行显示的歌手:带署名纠正和引擎认出来的歌手兜底,认出来比换歌晚一拍,单独转发。
        displayArtistSub = p.$displayArtist
            .removeDuplicates()
            .sink { [weak self] in self?.displayArtist = $0 }
        artworkSub = p.$artworkImage
            .removeDuplicates { $0 === $1 }
            .sink { [weak self] in self?.artwork = $0 }
    }
}

// 歌词来源筛选。"无来源"对应老缓存(lyrics_source 字段是后来才加的,更早解析的
// 条目永久没有这个值,除非重新解析)。
//
// 必须从 LyricsSource.allCases 派生,不能手写字面量清单——手写清单会在加新源时
// 静默漏掉它,按来源筛选永远筛不到。
//
// 派生的理由:那个枚举已经是全项目
// "歌词源有哪些"的唯一真源(设置页勾选框、顺序优先排序、搜索弹窗徽章都读它),
// 派生之后以后加源这里自动跟上,不存在"忘了补"这种可能。顺序也跟着枚举走 —— 那个顺序
// 本身有语义(按实测采用率排),两处保持一致比各排各的好。
// 守卫见引擎侧 lyricsourceregistry_test.go 的 TestSwiftSourceFilterDerivesFromEnum。
private enum SourceFilter: Hashable, Identifiable {
    case all
    case named(String)
    case none

    static let all_: [SourceFilter] = [.all] + LyricsSource.allCases.map { .named($0.rawValue) } + [.none]

    /// 下拉实际列的:内置源之外,再补上条目里出现过的播放器自带来源(KKBOX、Spotify 的本地歌词,
    /// 见 EnrichCacheStore.extraSources),排在「无来源」前面。
    static func options(extraSources: [String]) -> [SourceFilter] {
        var out = all_
        out.insert(contentsOf: extraSources.map { .named($0) }, at: out.count - 1)
        return out
    }

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

// 「筛选」里的「歌词类型」:逐字 / 逐行 / 纯文本,跟设置页「歌词库」统计同一个成色阶梯(LyricsKind)。没词和纯音乐那两档
// 是外面的「缺歌词」「纯音乐」胶囊,不在这里重复(见 11 章决策 77、80)。
private enum KindFilter: Hashable {
    case all
    case only(LyricsKind)

    static let choices: [LyricsKind] = [.wordByWord, .lineByLine, .plainText]

    var id: String {
        switch self {
        case .all: return "all"
        case let .only(kind): return kind.rawValue
        }
    }
}

/// 排序方式。没选过时是「更新时间 新→旧」;在搜时这一档改按相关度排(见 11 章决策 87)。
///
/// 「更新时间」两档补上。上面那版注释曾写着"没有这个候选,
/// 缓存里没有任何时间戳字段"——**结论对、理由不全**:缓存里确实没有一个表达"更新时间"的
/// 字段(实测覆盖率 decided_at 73% / translation_ts 25% / peripheral_ts 9% /
/// lyrics_rescore_ts 7%,全是偏科的局部时间戳,而 decided_at 还只反映"自动决策",手改
/// 歌词根本不动它),但**不需要扩缓存格式** —— 导出的歌词文件 mtime 就是这个信号,而且
/// 覆盖率 3169/3210。见 `Summary.lyricsUpdatedAt` 的头注(含"为什么它不会被引擎
/// 每次启动重写冲掉"这个关键前提)。
private enum LyricsSortOption: String, CaseIterable, Identifiable {
    case titleAscending, titleDescending
    case artistAscending, artistDescending
    case albumAscending, albumDescending
    case sourceAscending, sourceDescending
    case updatedDescending, updatedAscending
    // 证据薄的排最前 —— 「当初只有两三个源应答就定了案」的那批,
    // 用户没法从任何别的列看出来。只给升序一档:降序("证据最厚的排最前")没有对应的
    // 用途,而每加一档下拉就长一行。
    case evidenceAscending

    var id: String { rawValue }

    /// 菜单里的名字。存进偏好(`np:lyricsManagerSortOption`)的是 rawValue,别拿文案当 rawValue:改一次文案,存下的排序
    /// 就认不出来、悄悄回到默认(见 11 章决策 92)。
    var title: String {
        switch self {
        case .titleAscending: return L10n.t("歌名 A→Z")
        case .titleDescending: return L10n.t("歌名 Z→A")
        case .artistAscending: return L10n.t("歌手 A→Z")
        case .artistDescending: return L10n.t("歌手 Z→A")
        case .albumAscending: return L10n.t("专辑 A→Z")
        case .albumDescending: return L10n.t("专辑 Z→A")
        case .sourceAscending: return L10n.t("来源 A→Z")
        case .sourceDescending: return L10n.t("来源 Z→A")
        case .updatedDescending: return L10n.t("更新时间 新→旧")
        case .updatedAscending: return L10n.t("更新时间 旧→新")
        case .evidenceAscending: return L10n.t("应答源最少")
        }
    }

    /// 翻译成 LyrimuseCore 里那套纯规则。**规则本身**(哪一档优先、平局怎么断、缺失值
    /// 排在哪儿)住在 `LyricsSortOrder`,不在这里 —— 那边 lyrimuse-selftest 够得到,
    /// 能逐档钉住;留在这个 private enum 里的话一行覆盖都没有(搬走的缘由见它的头注)。
    var coreOrder: LyricsSortOrder {
        switch self {
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
        case .evidenceAscending: return .evidence(ascending: true)
        }
    }

    /// 按这个选项给一份已经筛选完的列表排序。
    ///
    /// 排序键**一次性算好再排**,不在比较器里现算:`sourceDisplayName` 要走一次 L10n
    /// 查表,放进 O(N·logN) 的比较里会被调用上万次(跟 Summary 里那几个 norm* 字段
    /// 预算好的动机一样)。其余字段都是 Summary 上现成的,只是搬进一个
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
    /// 折过简体+小写)而不是列表里展示的原始写法——理由见 `Summary.displayArtist` 的注释:"筛选/排序继续按统一名归并不变,只是这一列如实展示每条记录
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
            resolvedAt: resolvedAt,
            sourcesRespondedCount: sourcesRespondedCount
        )
    }
}

// 歌手筛选下拉按"主歌手"合并——同一位歌手的合唱曲目(如"宇多田ヒカル & Skrillex")
// 不应该在下拉里单独占一行,应该并进"宇多田ヒカル"那一项里;选中某位歌手后,连同他/她
// 参与的合唱曲目也一起展示出来,不是只看完全同名的条目。分隔符跟 lyrimuse-engine/match.go 的
// artistCreditParts 用同一套(/、&,，),取分割后的第一段作为归并键,大小写/首尾空白
// 不影响判定,但下拉里展示、真正拿去比较分组的是原始未分割的 artist 全文里截出来的
// 第一段(保留原始大小写/写法,不额外转小写)。
func primaryArtist(_ full: String) -> String {
    let seps = CharacterSet(charactersIn: "/、&,，")
    let first = full.components(separatedBy: seps).first ?? full
    return first.trimmingCharacters(in: .whitespaces)
}

// 繁体折成简体,只用来算"是不是同一个人/同一张专辑"的归并键,不改动任何展示文案——
// 跟引擎那边 match.go/t2s.go 的 toSimplified 是同一个目的,但这边是 Swift 代码,
// 没有引入 gocc 那类第三方库,直接用 Foundation/ICU 内置的 "Traditional-Simplified"
// transform 就能做,不需要额外依赖(例如:"100種生活"/"100种生活" 这类
// 繁简差一个字的专辑名,之前的归并键只转小写、不管繁简,被当成两张不同专辑,在筛选下拉
// 里重复出现)。
//
// 按原串 memoize:CFStringTransform 是 ICU 调用、单次微秒级,而
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
    // LyricFind(加,检索走 YouTube Music 但只在数据真是 LyricFind 时才
    // 接受候选,见 lyrimuse-engine/ytmusic.go 头注)。红色已经被网易云占了,选粉色作为下一个
    // 未占用色。
    case "lyricfind": return .pink
    // 酷我音乐(加,见 lyrimuse-engine/kuwo.go 头注)。红/绿/蓝/紫/橙/粉都被占了,
    // 选棕色作为下一个未占用色。
    case "kuwo": return .brown
    // 咪咕音乐(加,见 lyrimuse-engine/migu.go 头注)。红/绿/青/靛/紫/橙/粉/棕都被占了,
    // 选薄荷绿作为下一个未占用色。
    case "migu": return .mint
    // Deezer(加,见 lyrimuse-engine/deezer.go 头注)。红/绿/青/靛/紫/橙/粉/棕/薄荷
    // 都被占了,选蓝绿(teal)作为下一个未占用色。
    case "deezer": return .teal
    // Apple Music(加,见 lyrimuse-engine/applemusic.go 头注)。红/绿/青/靛/紫/橙/粉/
    // 棕/薄荷/蓝绿都被占了,选蓝色作为下一个未占用色(品牌色那系的红/粉早被网易云和
    // LyricFind 占了,不硬凑)。
    case "applemusic": return .blue
    // 汽水音乐(见 lyrimuse-engine/soda.go 头注)。品牌色是青绿一系,可 .teal / .cyan / .mint 都被占了(.cyan 是酷狗),
    // 系统色里没有空位,取黄绿之间那段没人用的色相。
    case "soda": return Color(hue: 0.25, saturation: 0.7, brightness: 0.72)
    // KKBOX 本地歌词(不是歌词源:用 KKBOX 放歌时读它自己缓存里的那份,见 lyrimuse-engine/kkboxlyrics.go 头注)。
    // 品牌色是青蓝一系,.cyan / .teal / .blue 都被占了,取最后一个未占用色 .yellow。
    case "kkbox": return .yellow
    // Spotify 本地歌词(不是歌词源:Spotify 自己拉过的那份,多是 Musixmatch 供词,见 lyrimuse-engine/spotifylyrics.go)。
    // 系统色都被占了,品牌绿跟 QQ 音乐的 .green 分不开,用 .gray。
    case "spotify": return .gray
    // Amazon Music 本地歌词(不是歌词源:用它放歌时读它自己缓存里的那份,见 lyrimuse-engine/amazonlibrary.go)。
    // 品牌青色跟酷狗的 .cyan 分不开,系统色也没有空位,取偏蓝的浅天蓝。
    case "amazon": return Color(hue: 0.56, saturation: 0.55, brightness: 0.95)
    default: return .secondary
    }
}

// 歌词来源展示名——网易云音乐/QQ音乐/酷狗音乐是国内用户认得出的中文写法;Musixmatch/
// LRCLIB 都是纯西方的歌词库(品牌),没有约定俗成的中文名,保留英文原名,不强行硬翻
// 一个不存在的中文名。
func sourceDisplayName(_ source: String) -> String {
    switch source {
    case "netease": return L10n.t("网易云音乐")
    case "qq": return L10n.t("QQ 音乐")
    case "kugou": return L10n.t("酷狗音乐")
    case "musixmatch": return "Musixmatch"
    case "lrclib": return "LRCLIB"
    // amll-ttml-db 是社区维护的 TTML 歌词库(github.com/amll-dev/amll-ttml-db),
    // 跟 Musixmatch/LRCLIB 一样是没有中文名的项目名,保留原名。
    case "amll": return "AMLL"
    // LyricFind——国际品牌名,没有约定俗成的中文译名,同上保留原名。
    // 检索机制上走的是 YouTube Music,但候选过滤只留真正的 LyricFind 数据(见
    // lyrimuse-engine/ytmusic.go 头注),所以展示名如实叫 LyricFind、不叫 YouTube Music。
    case "lyricfind": return "LyricFind"
    // 酷我音乐——国内用户认得出的中文写法,同网易云/QQ/酷狗。
    case "kuwo": return L10n.t("酷我音乐")
    // 咪咕音乐——同酷我,用国内用户认得出的中文写法。
    case "migu": return L10n.t("咪咕音乐")
    // Deezer——国际品牌名,没有约定俗成的中文译名,同 LyricFind/Musixmatch
    // 保留原名。它跟 lyricfind 数据同源(都是 LyricFind 供词),但**展示成两个源**是对的:
    // 用户看到的是"哪条管道给出了这份候选",两条管道的接口与可用性都不一样(实测这台机器上
    // lyricfind 整源不可用、deezer 正常出词),见 lyrimuse-engine/deezer.go。
    case "deezer": return "Deezer"
    // Apple Music——官方中文名就是「Apple Music」,Apple 自己在简中界面里
    // 也不译,保留原名。它是全部源里唯一给**官方逐字**时间轴的一家(见 lyrimuse-engine/applemusic.go)。
    case "applemusic": return "Apple Music"
    // 汽水音乐——官方中文名,跟网易云/QQ/酷狗同一档写法。
    case "soda": return L10n.t("汽水音乐")
    // KKBOX 本地歌词——品牌名,中文界面里也写 KKBOX,保留原名。不在 LyricsSource 里(设置里没有它的开关),
    // 只在这份词确实来自 KKBOX 时显示出来。
    case "kkbox": return "KKBOX"
    // Spotify 本地歌词——品牌名,保留原名。同 KKBOX,不在 LyricsSource 里,只在这份词确实来自 Spotify 缓存时显示。
    case "spotify": return "Spotify"
    // Amazon Music 本地歌词——品牌名,保留原名。同 KKBOX,不在 LyricsSource 里,只在这份词确实来自它时显示。
    case "amazon": return "Amazon Music"
    case "": return L10n.t("无来源")
    default: return source
    }
}

// 来源格子的悬停提示。绝大多数来源就是展示名本身——`.help` 在那里的本职是给固定 4 列网格
// 里被截断的长译名兜底(见 SettingsView.sourceCheckbox 里的说明),名字没被截断时它只是把
// 同一个词重复一遍、那个槽位是空着的。
//
// lyricfind 是唯一一个"展示名 ≠ 检索对象"的源:数据是 LyricFind 的(候选过滤只留真正的
// LyricFind 数据,见 lyrimuse-engine/ytmusic.go 头注),但取数走的是 YouTube Music 这条管道。
// 界面上这两个名字此前是分开出现的——平时的展示名按**数据来源**叫 LyricFind,出事时的失败
// 文案按**管道**叫 "YouTube Music 在这个网络所在地区不可用"(LyricSourceFailureReason.swift)——
// 这个分工本身是对的(平时关心拿到谁的词,出事关心该动哪条链路),但两个名字之间的关系
// 在界面上无处可看。接完 Deezer(同样是 LyricFind 供词的另一条管道)之后用户
// 直接问到"这里该写 LyricFind 还是 YouTube Music",说明这层关系确实需要在界面上讲一句,
// 就借这个本来空着的槽位讲。展示名不动:改叫 YouTube Music 会 over-promise——实测 YTM
// 命中的候选里 6/9 是 Musixmatch 转发、全部被闸门拒掉,不是"YouTube Music 有的都能拿到"。
func sourceHelpText(_ source: String) -> String {
    switch source {
    case "lyricfind": return L10n.t("LyricFind（经由 YouTube Music 检索）")
    default: return sourceDisplayName(source)
    }
}

// 窗口位置/尺寸/所在屏幕的持久化(补——「歌词窗口」修过同一类
// 问题,这扇姐妹窗口当时漏补)。这扇窗完全靠 SwiftUI `Window(id:)` 的系统状态恢复,而
// 系统那套的问题不在"存不存",在**它不认识屏幕**:多显示器下拔插一次或换个分辨率,
// 窗口经常回到主屏、或者落在一块已经不存在的屏幕的坐标上,表现为表格标题列被从左边
// 硬切、各行掉的字符数不一样、没有省略号。
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
    private var keyObservers: [NSObjectProtocol] = []
    private var firstResponderObservation: NSKeyValueObservation?
    private var persistFrameTask: Task<Void, Never>?

    /// 列表此刻有没有键盘焦点:窗口是主窗口,第一响应者是那张表格。这时选中行铺实心强调色,行里彩色的字要换成白字那一套。
    /// `.inset` 样式的列表里 backgroundProminence 不跟着变,所以看 AppKit 自己的状态。
    @Published private(set) var listHasKeyFocus = false

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
        // AppKit 自动的"Window"菜单填充在这三扇窗(歌词管理/设置/歌词窗口)身上都不可信
        // (它们最小化后 AXSubrole 都是 AXDialog),所以三扇窗统一手动登记,不区分谁真的需要。
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
        observeListFocus(window)
    }

    private func observeListFocus(_ window: NSWindow) {
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleListFocusRefresh() }
        }
        keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main, using: refresh)
        }
        // firstResponder 支持 KVO(NSWindow.h)。
        firstResponderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleListFocusRefresh() }
        }
        scheduleListFocusRefresh()
    }

    /// 推到下一拍再发布:第一响应者可能在 SwiftUI 更新视图的当中换,不能在那时改 @Published。
    private func scheduleListFocusRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let focused = window.isKeyWindow && window.firstResponder is NSTableView
            if focused != self.listHasKeyFocus { self.listHasKeyFocus = focused }
        }
    }

    /// 等窗口成为主窗口、列表的表格装上至少 `minRows` 行,最多等 `timeout` 秒,到点照样返回。开窗定位和交焦点要等这两样:
    /// 机器忙的时候(别的程序在编译)开窗那一下它们可能都还没好,定位落空,焦点随后又被系统交给搜索框。
    func waitUntilListReady(minRows: Int, timeout: Double = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window, window.isKeyWindow,
               let table = Self.firstTable(in: window.contentView), table.numberOfRows >= minRows { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 把键盘焦点交给窗口里那张列表(侧栏的歌曲列表,窗口里唯一的 NSTableView),直接换 AppKit 的第一响应者。
    func focusList() {
        guard let window, let table = Self.firstTable(in: window.contentView) else { return }
        window.makeFirstResponder(table)
    }

    /// 窗口里那张列表的表格。
    var listTable: NSTableView? {
        guard let window else { return nil }
        return Self.firstTable(in: window.contentView)
    }

    private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

    /// 拖动/缩放停下来之后再落盘,不去抖的话拖动期间每帧一次 UserDefaults 写(侧栏宽度同样是松手才落盘)。
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
    let surface: SettingsWindowSurface

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                controller.attach(window)
                surface.attach(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            controller.attach(window)
            // 推到下一拍:attach 会改 @Published 的 isVisible,不能在视图更新当中改。
            DispatchQueue.main.async { surface.attach(window) }
        }
    }
}

// 歌词管理窗口:浏览目前引擎缓存了哪些歌的歌词、来源是什么,支持手动纠正内容、
// 联网重新搜索候选歌词(见 LyricsSearchSheet/LyricsSearchService)、
// 或整条删除(强制下次播放重新解析)。改动交给引擎执行(见 EnrichCacheStore 顶部注释)。
//
// 版面:左边一块浮起来的玻璃侧栏(搜索、状态胶囊、列表,宽度能拖,见 LyricsManagerSidebarWidth),右边是选中那首的
// 详情(封面氛围头部、预览 / 逐句编辑)、缺歌词的说明,或多选时的批量面板。场景挂 .windowStyle(.hiddenTitleBar),
// 内容铺到顶,红绿灯落在侧栏左上角。界面零件在 LyricsManagerParts.swift。
struct LyricsManagerView: View {
    @ObservedObject private var store = EnrichCacheStore.shared
    // 窗口位置/尺寸/所在屏幕的持久化,见 LyricsManagerWindowFramePersistence 类头注。
    @StateObject private var windowFrame = LyricsManagerWindowFramePersistence()
    // 窗口看不看得见(遮挡 / 最小化 / 在别的桌面)。看不见时列表那个轮询整个停掉:自动匹配期间缓存文件
    // 每搜完一首就变,不停的话被挡住的窗口也会跟着反复解析整份缓存。
    @StateObject private var windowSurface = SettingsWindowSurface()
    // 只为了让这个独立窗口(跟 SettingsView 不在同一棵视图树里)在手动切换语言时
    // 重新渲染。经 AppLanguageObserver 窄代理(见文件顶部),不整对象订阅 AppSettings。
    @ObservedObject private var languageSettings = AppLanguageObserver.shared
    // 窗口开着期间跟着换歌自动重新定位,见 LyricsManagerNowPlayingObserver 类头注。
    @StateObject private var nowPlaying = LyricsManagerNowPlayingObserver()
    // searchText 是搜索框里正在打的内容;committedSearchText 才是真正喂给 filtered 的那份,停手 150 毫秒(commitSearch)
    // 或按回车时才同步,删空时立刻同步。两者不能合并:filtered 的缓存键 filterToken 若直接拼 searchText,每敲一个字符
    // 就要把全库重新过滤、排序一遍。
    @State private var searchText = ""
    @State private var committedSearchText = ""
    @State private var searchCommitTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool
    // 多选,支持 Cmd 点选/Shift 连选。
    // 三态由 selectedKeys.count 决定:0 = 空占位,1 = 单曲详情页,≥2 = 批量操作面板。
    @State private var selectedKeys: Set<String> = []
    // 列表(SongList)绑的是这一份,跟 selectedKeys 在 songList 上互相同步,拦截见 listSelectionChanged。放在 @State 里、
    // 不当 @StateObject:列表报上来时只有列表那一层重算。别改成 @State 的 Set 再 onChange(of:) 它 —— body 读了它,
    // 每换一次选中整个窗口的 body 要多算一遍;也别换成 Binding(get:set:) 闭包绑定 —— 列表被 == 挡住不重算时,代码里改的
    // 选中(开窗定位、跟着换歌、全选、删除后收敛)到不了表格。
    @State private var listSelection = SongListSelection()
    // 选中、列表有键盘焦点的那几行,各行自己读(见 SongList)。放在 @State 里、不当 @StateObject:它一变,整个窗口的
    // body 不用跟着重算。
    @State private var listEmphasis = SongListEmphasis()
    // 待删 key 的**快照**。删除确认弹窗一律只读这一份,绝不在弹窗回调里现读 selectedKeys:
    // 弹窗弹出时 List 会失去 first responder,已知会出现 selection 被系统清空的情况,现读
    // 可能读到空集(什么都没删、用户以为删了)或读到中途被改过的集合。
    @State private var pendingDeleteKeys: [String] = []
    @State private var showBatchDeleteConfirm = false
    // 删完之后选中清空、右侧变回空占位:列表标题旁闪一下「已删除」,1 秒后收起。
    @State private var showDeletedFeedback = false
    @State private var editedLyrics = ""
    // 编辑用的**正文**(元信息标签行 / 署名行摘掉),不是 editedLyrics 本身;editedLyrics 仍是完整原文、
    // 保存 / 指纹 / 采纳都只认它。两者靠 LyricsBodyEdit 互拼,接法见其头注。
    @State private var editedLyricsBody = ""
    @State private var lyricsBodyEdit = LyricsBodyEdit(lyrics: "")
    @State private var editedTr = ""
    // 译文、读音同样只编辑正文,跟 editedLyrics/editedLyricsBody 是同一套 LyricsBodyEdit 互拼。
    @State private var editedTrBody = ""
    @State private var trBodyEdit = LyricsBodyEdit(lyrics: "")
    @State private var editedRoma = ""
    @State private var editedRomaBody = ""
    @State private var romaBodyEdit = LyricsBodyEdit(lyrics: "")
    // 逐字歌词改的不是 LRC,是逐字拼出来的每一行(只改字,见 LyricsWordTimingEdit):editedWordText 是完整的
    // 摊开文本,编辑时用的是摘掉署名行之后的正文,跟上面那几对同一套互拼。
    @State private var editedWordText = ""
    @State private var editedWordBody = ""
    @State private var wordBodyEdit = LyricsBodyEdit(lyrics: "")
    @State private var loadedWordText = ""
    /// 载入时的逐字原文,「保存修改」以它为底套回改动;空 = 这首没有能摊开的逐字行,改的是 LRC。
    @State private var loadedYRC = ""
    /// 上一次保存里有几句的逐字时间是按字数估的,保存之后说一声。
    @State private var saveEditNote: String?
    // 编辑缓冲属于哪一首、载入时是什么。编辑状态挂在整个窗口上(不是详情页自己的),详情页卸载再装回来
    // (取消选中再选另一首)时 onChange(of: key) 不触发 —— 所以异步结果(重新匹配、采纳候选、保存完成)写回编辑缓冲
    // 之前都要核对 editingKey;保存时据 loaded* 判断哪几格用户真的改过(没改的交盘上此刻的值,见 saveEdits)。
    @State private var editingKey: String?
    @State private var loadedLyrics = ""
    @State private var loadedTr = ""
    @State private var loadedRoma = ""
    // 这首的正文此刻读不回来(EnrichCacheStore.detail 的 complete == false):编辑缓冲是空的,不许保存,
    // 否则会把盘上的歌词、译文、罗马音一起清掉。
    @State private var detailIncomplete = false

    /// 编辑缓冲里有没保存的改动。
    private var isEditorDirty: Bool {
        editedLyrics != loadedLyrics || editedTr != loadedTr || editedRoma != loadedRoma || editedWordText != loadedWordText
    }
    // 单曲歌词时间轴偏移——输入框显示/编辑的秒数字符串。跟下面两个"persisted"字段
    // 分开存,是因为算 LyricsOffsetStore 的 key 必须用磁盘上实际持久化的歌词内容,不能
    // 用 editedLyrics(编辑中还没保存的文本还没生效到播放端,拿它算出来的 key 会跟真正播放时用的 key 对不上)。
    @State private var editedOffsetSeconds = ""
    @State private var persistedLyricsForOffset = ""
    @State private var persistedYRCForOffset = ""
    // 单曲时间轴校正值:「⋯」菜单里「已校准 N 首 / 清空」要跟着实时变(整对象订阅是安全的
    // —— 它只在用户动作时发布,不在播放热路径上,见 LyricsOffsetStore.trackOffsetCount)。
    @ObservedObject private var offsets = LyricsOffsetStore.shared
    // 已校准名单:列表的「已校准」胶囊、详情页那颗「已校准」标签和它下面那句说明认它(见 LyricsPinStore)。
    @ObservedObject private var pins = LyricsPinStore.shared
    /// 「搜索候选歌词」面板为哪一首开着;nil = 没开。
    @State private var searchTarget: SearchTarget?

    /// 搜索面板为哪一首开的:打开那一刻拍下歌名、歌手、专辑和时长,面板开着期间不随列表重读改动(引擎补写了专辑,查询词也
    /// 不重置、不重搜,见 11 章决策 92)。「当前使用」的来源和指纹、纯音乐标记照常按这一首此刻的记录算。
    private struct SearchTarget: Identifiable {
        let key: String
        let artist: String
        let title: String
        /// 面板里预填的专辑(给人看的那份)。
        let album: String
        /// 缓存键里的专辑,查「当前使用」那份正文用。
        let keyAlbum: String
        let durationSecs: Double
        var id: String { key }
    }

    // MARK: - 「重新自动匹配」
    //
    // 跟隔壁「搜索候选歌词」的区别:那个是把候选摆出来让人挑,这个是**请引擎对这一首跑一轮重评**
    // (LyricsRematch):冠军按设置里的「匹配算法」选,换不换、写哪些字段跟后台重评是同一个函数,这里只发请求、
    // 报进度、按结论说一句话。
    //
    // 所有状态都带 key:详情页的状态是 View 级 @State、靠 onChange(of: key) 重载,不带 key 的话
    // A 歌跑出来的结果会画在 B 歌的页面上。
    @State private var rematchRunningKey: String?
    /// 在等的那一轮的请求 id,换歌时拿它叫停。
    @State private var rematchRequestID: String?
    @State private var rematchDone = 0
    @State private var rematchTotal = 0
    @State private var rematchResult: RematchOutcome?
    /// 单调换代:轮询和收尾都 guard 它,防"上一轮的收尾把新一轮的进行中状态关掉"
    /// (照抄 LyricsSearchSheet.load 里 searchGeneration 那套)。
    @State private var rematchGeneration = 0

    private struct RematchOutcome {
        let key: String
        let tone: LyricsRematch.Tone
        let text: String

        var icon: String { LyricsRematchRunner.icon(tone) }
        var tint: Color { LyricsRematchRunner.tint(tone) }
    }
    @State private var showDecisionSheet = false
    // 「保存修改」点了之后闪一下「已保存」+ 对勾,1 秒后变回去。
    @State private var showSaveEditFeedback = false
    // 整段文本编辑里「拷贝」按钮的同款反馈:拷贝一大段文本到剪贴板本身没有任何肉眼可见的变化。
    @State private var showCopyLyricsFeedback = false
    @State private var sourceFilter: SourceFilter = .all
    @State private var kindFilter: KindFilter = .all
    /// 侧栏状态胶囊选的那一类,判定在 LyricsManagerStatus。
    @State private var statusFilter: LyricsManagerStatus = .all
    // 引擎侧「补空扫描」的进度快照(LyricsFillSweep,进度文件按 mtime 读),由列表那个
    // 轮询 .task 刷新;nil = 这个引擎进程还没跑过任何一轮。「⋯」里的自动匹配、侧栏底部的进度卡、
    // 多选面板的「重新自动匹配选中的…」都按它判"正在跑"来置灰/显示进度。
    @State private var fillSweepStatus: LyricsFillSweep.Info?
    // 点了自动匹配、引擎还没接手的那几秒(LyricsFillSweep.isPending):按钮置灰、进度卡先转起来,
    // 免得用户以为没点上再点一次。由点击处置 true,轮询按 isPending 清掉。
    @State private var fillSweepPending = false
    /// 点下去的是不是「全量重新扫库」:接手前那几秒进度卡上说哪一句。
    @State private var fillSweepPendingIsFull = false
    /// 进度卡上「自动匹配完了」那句说过了的那一轮(按结束时刻认),说过就收起。
    @State private var dismissedSweepReceipt: Int64?
    /// 引擎公布的全量扫库状态(打分版本号、有没有一轮没跑完);nil = 引擎还没起来过或版本太老,
    /// 那时「全量重新扫库」入口不出现(同设置页那一行)。跟自动匹配进度同一个轮询节拍读,开销是一次 stat。
    @State private var fullScanState: LyricsFullScan.State?
    @State private var confirmFullScan = false
    /// 上一次「闲时」问磁盘的时刻,见 `LyricsManagerRefresh`。
    @State private var lastIdleRefresh = Date.distantPast
    // nil = 全部歌手/专辑。歌手/专辑的候选值不是固定的几种,是从当前缓存数据里现算出来的
    // (见 distinctArtists/distinctAlbums),所以这两个直接用 String? 而不是另建一个枚举。
    @State private var artistFilter: String?
    @State private var albumFilter: String?
    // 排序不是筛选(不改变"看得见哪些",只改变"看到的顺序"),所以特意不并进 filterToken——
    // 那个 token 是 filtered 结果集的缓存键/selectedKeys 收敛的触发信号,两者都只关心
    // "集合",不关心顺序,混进去只会让缓存判断多背一个跟"集合"无关的维度。
    /// 排序和分组记在 UserDefaults,下次开窗照旧;存的值认不出来时回到「更新时间 新→旧」(见 11 章决策 84、87)。
    @AppStorage("np:lyricsManagerSortOption") private var sortOption: LyricsSortOption = .updatedDescending
    /// 列表按专辑分组。
    @AppStorage("np:lyricsManagerGroupByAlbum") private var groupByAlbum = false
    // 点了「刷新」却没有任何肉眼可见的变化时(比如内容根本没变),用户很容易以为按钮没
    // 反应——短暂切换成对勾,1 秒后自动变回去。
    @State private var showRefreshedFeedback = false
    @State private var showClearAllConfirm = false
    /// 「清理无效记录」确认框开着时要删的那几条,点菜单那一刻拍下来(确认框开着期间列表可能重读)。
    @State private var pendingCleanupKeys: [String] = []
    @State private var showCleanupConfirm = false
    // 跟上面那个刻意分开:清缓存(歌词内容)和清时间轴校正是两件独立的事,两条路都开着、
    // 互不连带 —— 校正值是用户一句句听出来的,比歌词内容宝贵得多(见 LyricsOffsetStore
    // 类型注释里"故意跟 EnrichCacheStore 彻底分开存"那一段)。
    @State private var showClearOffsetsConfirm = false
    @State private var showClearRadioOffsetsConfirm = false
    // 「从自动备份恢复」用的三个状态。快照列表在菜单打开那一刻现读(autoSnapshots() 只
    // stat 目录,廉价),不常驻 @State —— 常驻的话清空之后新打的那份不会出现在菜单里。
    @State private var pendingRestoreSnapshot: LyricsBackupStore.Snapshot?
    @State private var showRestoreSnapshotConfirm = false
    @State private var restoreSnapshotResult: String?
    // "这次开窗还没有自动定位过当前播放的歌"。不能靠"selectedKeys 是空的"来判断这是不是
    // 一次全新的开窗——SwiftUI 的 Window scene 关掉之后**并不销毁根视图**,@State 原样
    // 留着,第二次打开时 selectedKeys 还是上次选的那一条。
    // 窗口关闭时(根视图 .onDisappear)置回 true,所以是"每次开窗定位一次"而不是"整个 App
    // 生命周期只定位一次";用它当闸也顺带挡住 List 重新 onAppear 把用户当前选中项抢走这种误伤。
    @State private var pendingAutoFocus = true

    /// "这首歌正在联网搜歌词、引擎还没写出任何结论"这段窗口期的占位行。nil = 当前没有需要补的占位——
    /// 可能是没在播、也可能是缓存里已经有真实条目了。见 `refreshPlaceholder()`。
    @State private var placeholderSummary: EnrichCacheStore.Summary?

    /// 侧栏宽度(存下来的那份;窗口窄时实际画多宽见 LyricsManagerSidebarWidth.shown)。
    @State private var sidebarWidth: Double = LyricsManagerView.storedSidebarWidth
    /// 一次拖拽开始那一刻的宽度:按"起点 + 累计位移"算,不在当前值上叠增量。
    @State private var sidebarDragStart: Double?
    @State private var showSourcePicker = false
    @State private var showArtistPicker = false
    @State private var showAlbumPicker = false
    @State private var showFilterPopover = false
    /// 正在放的这首在列表里对应哪一条(含占位行),见 resolveNowPlayingKey。
    @State private var nowPlayingKey: String?

    /// 右边是预览还是在编辑,见 LyricsManagerEditMode。
    @State private var editMode: LyricsManagerEditMode = .preview
    /// 打开编辑那一刻的正文,逐句格子据此标哪几句改过、「还原」还原到哪。
    @State private var editBase: EditBase?
    @FocusState private var focusedLine: LyricsManagerLineFocus?
    @State private var displayMode: LyricsManagerDisplayMode = .translation
    @State private var followPlayback = true
    /// 预览的行:不带读音的一份,带读音的一份(「原文 + 读音」那一档)。只在这首的正文、读音或设置里读音的文字种类变了时重算。
    @State private var previewRows: [LyricsPreviewRow] = []
    @State private var romanizedRows: [LyricsPreviewRow] = []
    @State private var previewInputs: [String] = []
    /// 这首按设置里开着的文字种类,有没有至少一句读音显示得出来;没有时「原文 + 读音」灰掉。
    @State private var romanizationAvailable = false
    /// 灰掉是因为设置里没给这首的语言标读音(缓存里存着读音,或者歌词里有能标读音的字),不是这首本来就标不了。
    @State private var romanizationOffInSettings = false
    /// 只有纯文本兜底的那首,右边显示的就是它。
    @State private var plainLyricsText = ""
    /// 编辑里有没保存的改动时,点到的那一批先记在这里,等用户在提示里选了再换。
    @State private var pendingSelection: Set<String>?
    @State private var showUnsavedEditAlert = false
    @State private var showDiscardEditConfirm = false
    @State private var markingInstrumental = false

    private struct EditBase: Equatable {
        let key: String
        /// 逐字歌词是 editedWordBody,其余是 editedLyricsBody。
        let main: String
        let tr: String
        let roma: String
    }

    private var hasActiveFilters: Bool {
        statusFilter != .all || sourceFilter != .all || kindFilter != .all || artistFilter != nil || albumFilter != nil
    }

    /// 「筛选」弹出层里有没有选着东西(歌词类型、来源、歌手、专辑):按钮上标一个点。
    private var hasPopoverFilters: Bool {
        kindFilter != .all || sourceFilter != .all || artistFilter != nil || albumFilter != nil
    }

    // 归并字典(歌手/专辑展示名、筛选下拉候选)全部下沉进 EnrichCacheStore,
    // 随 summaries 重建一次,不按行现算——按行现算要为专辑归并付一次 O(N) 次 ICU 变换
    // (锚点见 EnrichCacheStore.albumDisplayMap 的注释)。展示歌手名同样下沉(Summary.displayArtist)。

    private func albumDisplay(_ album: String) -> String {
        Self.albumDisplay(album, in: store.albumDisplayMap)
    }

    private static func albumDisplay(_ album: String, in map: [String: String]) -> String {
        map[toSimplified(album).lowercased()] ?? album
    }

    /// filtered 的缓存盒。@State 里包一个引用类型,让下面的计算属性能在 body 求值过程中
    /// 写缓存(View struct 本身不可变)—— filtered 在一次 body 构建里被独立求值好几处
    /// (列表数据源、标题计数、右键菜单、批量面板),不缓存就是每处一遍全量过滤。
    private final class FilteredCache {
        var token = "\u{0}"
        var generation = -1
        var result: [EnrichCacheStore.Summary] = []
        /// sortedFiltered 的缓存:result 重算过(置 nil)或排序方式变了才重排。
        var sortedFor: LyricsSortOption?
        var sorted: [EnrichCacheStore.Summary] = []
        // 下面几份都从上面两份派生,一次 body 里各要求值好几遍(⋯ 菜单、标题、快捷键、批量面板),
        // 而编辑格子每敲一个字都重算 body:不缓存就是每个键把全库再过好几遍。
        // result 重算时清 selectable,sorted 重排时清后三份;retryableAll 和胶囊计数只跟 summaries 代数走。
        var selectable: [EnrichCacheStore.Summary]?
        var selectedVisible: (keys: Set<String>, result: [String])?
        var retryableVisible: [String]?
        var groups: [AlbumGroup]?
        var albumEntries: [AlbumListEntry]?
        var retryableAllGeneration = -1
        var retryableAll: [String] = []
        var countsGeneration = -1
        var counts: [LyricsManagerStatus: Int] = [:]
        var cleanupGeneration = -1
        var cleanup: [String] = []
        var kindCounts: [LyricsKind: Int] = [:]
        // 三份结果各自记下算的时候那份校准名单:「手动调整」和清理判据按名单算,在歌词窗口、菜单栏调偏移时名单会变而
        // summaries 代数不变,只认代数的话计数、筛选和清理名单要等下一次列表重读才跟上(见 11 章决策 92)。
        var pins: [String: Int]?
        var countsPins: [String: Int]?
        var cleanupPins: [String: Int]?
    }
    @State private var filteredCache = FilteredCache()

    private var filtered: [EnrichCacheStore.Summary] {
        // 缓存键 = 全部筛选状态(filterToken,本来就为 onChange 拼好了)+ summaries 代数 + 校准名单。
        let generation = store.summariesGeneration
        let token = filterToken
        let pinned = pins.pins
        if filteredCache.token == token, filteredCache.generation == generation, filteredCache.pins == pinned {
            return filteredCache.result
        }
        // 基线埋点(临时,见 LyricsManagerBaseline)。只量这条"真重算"的路 —— 命中缓存
        // 那条一次 body 求值要走好几遍,记了只会把日志刷爆、也没有信息量。
        let recomputeStart = CFAbsoluteTimeGetCurrent()
        // 循环不变量提到过滤循环外算一次;逐行侧全部用 Summary 的预计算归一化键,谓词只剩字符串比较。
        let q = committedSearchText.lowercased()
        let af = artistFilter.map { toSimplified($0).lowercased() }
        let bf = albumFilter.map { toSimplified($0).lowercased() }
        // 「正在搜索」占位行(见 refreshPlaceholder)并进同一份基础列表,跟真实条目过同一套筛选谓词。
        let base = placeholderSummary.map { store.summaries + [$0] } ?? store.summaries
        // 正在编辑的那一首始终留在列表里:筛掉的话选中跟着收掉,详情页和保存条一起不见(见 11 章决策 92)。
        let kept = editMode == .preview ? nil : editingKey
        let result = base.filter { s in
            if s.key == kept { return true }
            if !q.isEmpty {
                // 歌手搜索两个写法都认:用户可能按原始写法搜(播放器里看到的那个),也可能按
                // 官方名搜。专辑名一起搜:「筛选」里的专辑是"选一个精确专辑名",搜索框是"打几个字模糊找",两者互补。
                guard s.searchArtistLower.contains(q)
                    || s.searchDisplayArtistLower.contains(q)
                    || s.searchTitleLower.contains(q)
                    || s.searchAlbumLower.contains(q) else { return false }
            }
            // 大小写/繁简不敏感比较(归并键口径,见 Summary.normPrimaryArtist/normAlbum)。
            if let af, s.normPrimaryArtist != af { return false }
            if let bf, s.normAlbum != bf { return false }
            guard sourceFilter.matches(s.lyricsSource) else { return false }
            // 歌词类型和「缺歌词」都跟设置页「歌词库」统计同一个阶梯(LyricsKind.classify):标了纯音乐的条目存着歌词也只算
            // 纯音乐,有歌词的条目不算纯文本,筛出来的数跟统计对得上。
            let kind = Self.kind(s)
            if case let .only(wanted) = kindFilter, kind != wanted { return false }
            // 「正在搜索」占位行只在「全部」里出现:它还没有任何结论。
            if statusFilter != .all {
                guard !s.isSearching, statusFilter.matches(statusFacts(s, kind: kind)) else { return false }
            }
            return true
        }
        filteredCache.token = token
        filteredCache.generation = generation
        filteredCache.pins = pinned
        filteredCache.result = result
        filteredCache.sortedFor = nil
        filteredCache.selectable = nil
        LyricsManagerBaseline.logFilter(
            inCount: base.count, outCount: result.count,
            elapsedMS: LyricsManagerBaseline.ms(since: recomputeStart))
        return result
    }

    private static func kind(_ s: EnrichCacheStore.Summary) -> LyricsKind {
        LyricsKind.classify(hasWordTiming: s.hasWordTiming, hasLyrics: s.hasLyrics,
                            hasPlainTextFallback: s.hasPlainTextFallback, isInstrumental: s.isInstrumental)
    }

    private func statusFacts(_ s: EnrichCacheStore.Summary, kind: LyricsKind) -> LyricsManagerStatus.Facts {
        LyricsManagerStatus.Facts(kind: kind, isManual: s.isManual, isPinned: pins.isPinned(s.key))
    }

    /// 每个状态胶囊上的数,全库口径(跟设置页「歌词库」一样,不随搜索和别的筛选变)。
    private var statusCounts: [LyricsManagerStatus: Int] {
        refreshCounts()
        return filteredCache.counts
    }

    /// 「清理无效记录」会删的那几条(判据见 LyricsManagerCleanup),正在放的那首不算。跟胶囊计数一样随 summaries 代数和校准名单
    /// 重算。歌手传给人看的那个:网易云云盘里的歌播放器不报歌手,引擎认出来了就不算「没有歌手」。
    private var cleanupKeys: [String] {
        let generation = store.summariesGeneration
        let pinned = pins.pins
        if filteredCache.cleanupGeneration != generation || filteredCache.cleanupPins != pinned {
            filteredCache.cleanup = store.summaries.filter {
                LyricsManagerCleanup.isInvalid(artist: $0.shownArtist, kind: Self.kind($0), isManual: $0.isManual,
                                               isPinned: pins.isPinned($0.key), durationSecs: $0.durationSecs)
            }.map(\.key)
            filteredCache.cleanupGeneration = generation
            filteredCache.cleanupPins = pinned
        }
        return filteredCache.cleanup.filter { $0 != nowPlayingKey }
    }

    /// 「歌词类型」每一档的数,口径同 statusCounts。
    private var kindCounts: [LyricsKind: Int] {
        refreshCounts()
        return filteredCache.kindCounts
    }

    private func refreshCounts() {
        let generation = store.summariesGeneration
        let pinned = pins.pins
        guard filteredCache.countsGeneration != generation || filteredCache.countsPins != pinned else { return }
        let facts = store.summaries.map { statusFacts($0, kind: Self.kind($0)) }
        filteredCache.counts = LyricsManagerStatus.counts(facts)
        filteredCache.kindCounts = Dictionary(facts.map { ($0.kind, 1) }, uniquingKeysWith: +)
        filteredCache.countsGeneration = generation
        filteredCache.countsPins = pinned
    }

    /// 在搜、排序又是默认的「更新时间 新→旧」时按相关度排(歌名开头命中 > 歌名里命中 > 歌手 > 专辑,同档按更新时间)。
    private var sortsByRelevance: Bool { !committedSearchText.isEmpty && sortOption == .updatedDescending }

    /// `filtered` 按当前排序方式排好的版本——List 的数据源、以及一切"顺序对用户可见"的
    /// 地方(比如 orderedVisibleKeys 那份删除计划)都该用这个,而不是 `filtered` 本身。
    ///
    /// 跟 `filtered` 共用缓存盒:一次 body 里要求值好几遍,而编辑格子在同一个视图里,每敲一个字都会重算 body。
    /// 全库八千多条时重排一遍默认顺序约 20ms、别的排序约 100ms,不缓存就是每个键几十到几百毫秒的卡顿。
    private var sortedFiltered: [EnrichCacheStore.Summary] {
        let base = filtered
        if filteredCache.sortedFor == sortOption { return filteredCache.sorted }
        var sorted = sortOption.sorted(base)
        if sortsByRelevance {
            let q = committedSearchText.lowercased()
            let ranks = sorted.map { s in
                LyricsManagerSearch.relevance(query: q, title: s.searchTitleLower,
                                              artists: [s.searchArtistLower, s.searchDisplayArtistLower],
                                              album: s.searchAlbumLower) ?? Int.max
            }
            sorted = sorted.indices.sorted { a, b in ranks[a] != ranks[b] ? ranks[a] < ranks[b] : a < b }.map { sorted[$0] }
        }
        filteredCache.sortedFor = sortOption
        filteredCache.sorted = sorted
        filteredCache.selectedVisible = nil
        filteredCache.retryableVisible = nil
        filteredCache.groups = nil
        filteredCache.albumEntries = nil
        return sorted
    }

    /// 按专辑分组时的一组:同一张专辑(归并键同 albumDisplay)、同一位主歌手的歌。
    private struct AlbumGroup: Identifiable {
        let id: String
        let album: String
        let artist: String
        var items: [EnrichCacheStore.Summary]
    }

    /// 按专辑分组时列表里的一行:组头,或者一首歌。
    private enum AlbumListEntry: Identifiable {
        case header(AlbumGroup)
        case song(EnrichCacheStore.Summary)

        /// 组头的 id 带前缀,跟歌曲的缓存键(「歌手|歌名|专辑」)撞不上。
        var id: String {
            switch self {
            case let .header(group): return "album-header\u{1F}" + group.id
            case let .song(summary): return summary.key
            }
        }
    }

    /// albumGroups 摊平成一层:组头后面跟这一组的歌。跟 albumGroups 一起缓存,外层视图重算时交给 List 的是同一份数组,
    /// 不然每次重算都要整表重新比对一遍。
    private var albumEntries: [AlbumListEntry] {
        let groups = albumGroups
        if let cached = filteredCache.albumEntries { return cached }
        let result = groups.flatMap { group in [AlbumListEntry.header(group)] + group.items.map(AlbumListEntry.song) }
        filteredCache.albumEntries = result
        return result
    }

    /// 组的先后跟着当前排序里各组第一首走,组里的顺序就是当前排序。
    private var albumGroups: [AlbumGroup] {
        let base = sortedFiltered
        if let cached = filteredCache.groups { return cached }
        var order: [String] = []
        var groups: [String: AlbumGroup] = [:]
        for s in base {
            let id = s.normAlbum + "\u{1F}" + s.normPrimaryArtist
            if groups[id] == nil {
                order.append(id)
                let album = s.isListedMV ? L10n.t("MV")
                    : (s.displayAlbum.isEmpty ? L10n.t("未知专辑") : albumDisplay(s.displayAlbum))
                groups[id] = AlbumGroup(id: id, album: album, artist: s.displayArtist, items: [])
            }
            groups[id]?.items.append(s)
        }
        let result = order.compactMap { groups[$0] }
        filteredCache.groups = result
        return result
    }

    /// 自动匹配的两个数:全库可自动匹配的、当前筛选出来可自动匹配的(见 autoMatchMenuSections)。
    private var retryableAllKeys: [String] {
        let generation = store.summariesGeneration
        if filteredCache.retryableAllGeneration != generation {
            filteredCache.retryableAll = store.summaries.filter(EnrichCacheStore.isFillSweepRetryable).map(\.key)
            filteredCache.retryableAllGeneration = generation
        }
        return filteredCache.retryableAll
    }

    private var retryableVisibleKeys: [String] {
        let base = sortedFiltered
        if let cached = filteredCache.retryableVisible { return cached }
        let keys = base.filter(EnrichCacheStore.isFillSweepRetryable).map(\.key)
        filteredCache.retryableVisible = keys
        return keys
    }

    // 只有恰好选中一条时才显示单曲详情页——detail 侧整条链(编辑缓冲区、offset 输入框、
    // 联网搜索 sheet)都建立在"当前就这一条"上,不能把多选硬塞进去。
    private var singleSelectedKey: String? {
        selectedKeys.count == 1 ? selectedKeys.first : nil
    }

    // 把全部筛选状态拼成一个字符串,只为了给 onChange 当变化信号用——否则要给每个 @State
    // 各挂一个 onChange 做同一件事(收敛选中项)。
    //
    // 分隔符用 U+001F(ASCII 单元分隔符)而不是 "|":搜索词、歌手名、专辑名里都可能出现
    // "|",那样两个不同的筛选状态理论上能拼出同一个 token,onChange 就不会触发、选中项不会
    // 被收敛(而这个收敛正是防误删的那道防线)。
    private var filterToken: String {
        let sep = "\u{1F}"
        return [
            committedSearchText, sourceFilter.id, kindFilter.id, statusFilter.rawValue,
            artistFilter ?? "", albumFilter ?? "",
            // 占位行的 key 也要算进去——它的出现/消失/换成另一首歌不会让
            // store.summariesGeneration 变(那条代数只跟 raw/真实条目有关),漏了这一项
            // filtered 的缓存盒就会在占位行刚补上/刚被真实条目顶替的那一刻还显示旧结果。
            placeholderSummary?.key ?? "",
            // 正在编辑的那一首不受筛选(见 filtered),进出编辑时结果集会变。
            editMode == .preview ? "" : (editingKey ?? ""),
        ].joined(separator: sep)
    }

    // 选中集合里"当前筛选结果中真的看得见"的那些,按列表显示顺序返回。
    //
    // 这是防误删的关键一道:filtered 是计算属性,selectedKeys 是独立 @State,行从筛选
    // 结果里消失后 SwiftUI 不保证替你把 key 从 selection 里剪掉——选中的行被筛选筛没时,
    // 界面上看不见却还留在 selection 里,而删除是不可逆的(连 lyrics/ 下导出文件一起删)。
    // 所有删除入口和所有计数都走这个函数,保证"弹窗说删 N 条" == "列表里看得见的 N 条"。
    // 按 sortedFiltered 顺序(= 列表当前实际显示的顺序)而不是 Set 顺序,这样删除计划
    // 才跟屏幕上看到的顺序一致。
    private func orderedVisibleKeys(_ keys: Set<String>) -> [String] {
        // 占位行永远排除在"可删除/可批量操作"范围之外——它不对应任何 raw 条目,删它没有
        // 意义(EnrichCacheStore.delete 本身会安全地把不存在的 key 过滤掉,这里提前排除
        // 是为了让"删除 N 条"这个数字如实反映真的会被删掉几条,不是靠下游兜底凑数)。
        sortedFiltered.compactMap { !$0.isSearching && keys.contains($0.key) ? $0.key : nil }
    }

    private var selectedVisibleKeys: [String] {
        _ = sortedFiltered // 先让缓存盒跟上当前筛选/排序,过期的 selectedVisible 会在这里被清掉
        if let cached = filteredCache.selectedVisible, cached.keys == selectedKeys { return cached.result }
        let result = orderedVisibleKeys(selectedKeys)
        filteredCache.selectedVisible = (selectedKeys, result)
        return result
    }

    // 「全选」和列表标题的计数共用这份——占位行不算进来,理由跟 orderedVisibleKeys 排除它一样:它不是一条真实记录。
    // 列表本身(filtered)仍然把占位行画出来,只是不计入计数。
    private var selectableFiltered: [EnrichCacheStore.Summary] {
        let base = filtered
        if let cached = filteredCache.selectable { return cached }
        let result = base.filter { !$0.isSearching }
        filteredCache.selectable = result
        return result
    }

    // 触发删除确认:先把待删清单快照下来再弹窗(理由见 pendingDeleteKeys 的注释)。
    private func requestDelete(_ keys: Set<String>) {
        let victims = orderedVisibleKeys(keys)
        guard !victims.isEmpty else { return }
        pendingDeleteKeys = victims
        showBatchDeleteConfirm = true
    }

    private func commitSearch() {
        // 只有拿去过滤的那份去掉首尾空白,框里打的内容不动。
        let query = LyricsManagerSearch.query(searchText)
        committedSearchText = query
    }

    /// 列表一行都没有时:筛选 / 关键词把全部条目滤掉了,就说清楚并给出清除的入口;真的一条记录都没有,说一句从哪来。
    @ViewBuilder
    private var emptyListState: some View {
        let searching = !committedSearchText.isEmpty
        if hasActiveFilters || searching {
            ContentUnavailableView {
                Label(L10n.t("没有符合条件的歌曲"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(L10n.t("请尝试其他筛选条件或关键词"))
            } actions: {
                if hasActiveFilters {
                    Button(L10n.t("清除筛选"), action: resetFilters)
                }
                if searching {
                    Button(L10n.t("清空搜索"), action: clearSearch)
                }
            }
        } else {
            ContentUnavailableView(L10n.t("暂无歌词记录"), systemImage: "music.note.list",
                                   description: Text(L10n.t("播放过的歌曲将显示在这里")))
        }
    }

    private func resetFilters() {
        statusFilter = .all
        sourceFilter = .all
        kindFilter = .all
        artistFilter = nil
        albumFilter = nil
    }

    private func clearSearch() {
        searchCommitTask?.cancel()
        searchText = ""
        committedSearchText = ""
    }

    // MARK: - 侧栏

    /// 侧栏离窗口边缘的距离、圆角。红绿灯落在侧栏左上角那一截里。
    private static let panelInset: CGFloat = 10
    /// 列表一行的实际高度:行内容 48(LyricsManagerSongRow:封面 40 + 上下各 4)加 `.inset` 样式每行自带的上下 8。
    /// 改行高要连这个数一起改。
    private static let listRowHeight: CGFloat = 56
    private static let panelCornerRadius: CGFloat = 22
    private static let sidebarWidthKey = "np:lyricsManagerSidebarWidth"

    private static var storedSidebarWidth: Double {
        let value = UserDefaults.standard.double(forKey: sidebarWidthKey)
        return value > 0 ? LyricsManagerSidebarWidth.clamped(value) : LyricsManagerSidebarWidth.standard
    }

    private func persistSidebarWidth() {
        UserDefaults.standard.set(sidebarWidth, forKey: Self.sidebarWidthKey)
    }

    private func sidebar(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sidebarHeader
            searchRow
            statusChips
            if nowPlayingKey != nil {
                nowPlayingRow(scrollProxy: scrollProxy)
            }
            listHeader
            songList(scrollProxy: scrollProxy)
        }
        .padding(.horizontal, 12)
        // 列表滚到底时别把行画到侧栏圆角外面。
        .clipShape(RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous))
        .settingsCardBackground(cornerRadius: Self.panelCornerRadius)
        .confirmationDialog(
            L10n.t("确定要清空全部歌词缓存吗？"),
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
            // 不能写成"随时可以恢复"——快照只保留最近 3 份、库本来是空的时候压根打不出来,承诺过头比不承诺更危险。
            Text(String(format: L10n.t("将删除全部 %d 条本地记录，包括手动编辑和从候选中采纳的歌词，已导出的歌词文件也会一并删除。清空前会自动备份，可通过此菜单中的「从自动备份恢复」找回。之后播放的歌曲会重新匹配歌词"), store.summaries.count))
        }
    }

    /// 侧栏顶上一行:左边让出红绿灯,标题和首数,右边「刷新」和「⋯」(自动匹配、占用与清理、从自动备份恢复)。
    /// 高度 32、贴着侧栏顶边,中线正好跟红绿灯对齐;这一行压在标题栏那一截(系统的拖拽区)里,只放按钮。
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 62, height: 1)
            Text(L10n.t("歌词管理"))
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
            Text(String(format: L10n.t("共 %@ 首"), store.summaries.count.formatted()))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: refreshWithFeedback) {
                Image(systemName: showRefreshedFeedback ? "checkmark" : "arrow.clockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showRefreshedFeedback ? L10n.t("已刷新") : L10n.t("刷新"))
            Menu {
                libraryMenu
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.t("更多"))
        }
        .font(.system(size: 14, weight: .medium))
        .frame(height: 32)
        // 「清理无效记录」的确认框挂在这一行:侧栏、List、根上各有自己的确认框,不叠在同一条修饰符链上。
        .confirmationDialog(
            String(format: L10n.t("确定要清理 %@ 条无效记录吗？"), pendingCleanupKeys.count.formatted()),
            isPresented: $showCleanupConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("清理"), role: .destructive, action: performCleanup)
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            if showCleanupConfirm { Text(cleanupMessage) }
        }
    }

    /// 清理确认框的正文:判据和不受影响的几类,下面列出前几条的歌名。
    private var cleanupMessage: String {
        let shown = pendingCleanupKeys.prefix(6)
        var lines = [L10n.t("这些记录没有歌词，且没有歌手或时长超过 20 分钟，通常是广告、播客或有声书。人工修正、标为纯音乐、校准过时间轴的记录和正在播放的歌曲不在其中；再次播放时会重新匹配。"), ""]
        for key in shown {
            let title = store.summary(forKey: key)?.title ?? ""
            lines.append(title.isEmpty ? key : title)
        }
        if pendingCleanupKeys.count > shown.count {
            lines.append(String(format: L10n.t("还有 %@ 条"), (pendingCleanupKeys.count - shown.count).formatted()))
        }
        return lines.joined(separator: "\n")
    }

    private func performCleanup() {
        // 确认框开着期间可能有一条刚补到歌词、或者成了正在放的那首:按此刻的判据再筛一遍,只删仍然无效的。
        let victims = Set(pendingCleanupKeys).intersection(cleanupKeys)
        guard !victims.isEmpty else { return }
        Task {
            await store.delete(keys: victims)
            selectedKeys.subtract(victims)
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            searchField
            filterButton
        }
    }

    /// 搜索框。边打边筛:停手 150 毫秒才真的过滤一次(commitSearch),删空立刻回到全量列表;Esc 清空,⌘F 聚焦。
    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.t("搜索歌手/歌名/专辑"), text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit(commitSearch)
                .onExitCommand(perform: clearSearch)
            if !searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(L10n.t("清空搜索"))
            } else if !searchFieldFocused {
                Text(verbatim: "⌘F")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(shape.fill(Color.primary.opacity(0.06)))
        .overlay(shape.strokeBorder(searchFieldFocused ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.12), value: searchFieldFocused)
        .onChange(of: searchText) { _, newValue in
            searchCommitTask?.cancel()
            if LyricsManagerSearch.query(newValue).isEmpty && !committedSearchText.isEmpty {
                committedSearchText = ""
                return
            }
            searchCommitTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                commitSearch()
            }
        }
    }

    /// 「筛选」:歌词类型和来源、歌手、专辑收在这里,状态胶囊都在下面那一行(见 11 章决策 73、77、80)。
    /// 选了东西按钮上标一个点。
    private var filterButton: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            showFilterPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(L10n.t("筛选"))
                if hasPopoverFilters {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(shape.fill(hasPopoverFilters ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) { filterPopover }
    }

    private var filterPopover: some View {
        let kinds = kindCounts
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                filterLabel(L10n.t("歌词类型"))
                SettingsFlowRow(spacing: 6) {
                    ForEach(KindFilter.choices, id: \.self) { kind in
                        Button {
                            kindFilter = kindFilter == .only(kind) ? .all : .only(kind)
                        } label: {
                            LyricsManagerChip(title: kind.label, count: (kinds[kind] ?? 0) > 0 ? kinds[kind] : nil,
                                              selected: kindFilter == .only(kind))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    filterLabel(L10n.t("来源"))
                    sourceChip
                }
                GridRow {
                    filterLabel(L10n.t("歌手"))
                    artistChip
                }
                GridRow {
                    filterLabel(L10n.t("专辑"))
                    albumChip
                }
            }
            if hasActiveFilters {
                Button(L10n.t("清除筛选"), action: resetFilters)
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func filterLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// 侧栏那一行状态胶囊的顺序,LyricsManagerStatus 的每一档都在(见 11 章决策 80)。
    private static let statusOrder: [LyricsManagerStatus] = [.all, .missing, .instrumental, .adjusted]

    /// 状态胶囊,一次只看一类,再点一下回到「全部」。
    private var statusChips: some View {
        let counts = statusCounts
        return SettingsFlowRow(spacing: 6) {
            ForEach(Self.statusOrder, id: \.self) { statusChip($0, count: counts[$0]) }
        }
    }

    private static func statusTitle(_ status: LyricsManagerStatus) -> String {
        switch status {
        case .all: return L10n.t("全部")
        case .missing: return L10n.t("歌词缺失")
        case .instrumental: return L10n.t("纯音乐")
        case .adjusted: return L10n.t("手动调整")
        }
    }

    private func statusChip(_ status: LyricsManagerStatus, count: Int?) -> some View {
        Button {
            statusFilter = statusFilter == status ? .all : status
        } label: {
            LyricsManagerChip(title: Self.statusTitle(status),
                              count: (count ?? 0) > 0 || status == .all ? count : nil,
                              selected: statusFilter == status)
        }
        .buttonStyle(.plain)
        .help(Self.statusHelp(status))
    }

    private static func statusHelp(_ status: LyricsManagerStatus) -> String {
        switch status {
        case .adjusted: return L10n.t("改过歌词或调过时间轴偏移的歌曲")
        case .all, .missing, .instrumental: return ""
        }
    }

    private var sourceChip: some View {
        Button {
            showSourcePicker.toggle()
        } label: {
            LyricsManagerMenuChip(title: sourceFilter.label, active: sourceFilter != .all)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSourcePicker, arrowEdge: .bottom) {
            let options = SourceFilter.options(extraSources: store.extraSources).filter { $0 != .all }
            LyricsManagerOptionList(
                allTitle: L10n.t("全部来源"),
                options: options.map { .init(id: $0.id, title: $0.label) },
                selectedID: sourceFilter == .all ? nil : sourceFilter.id, searchable: false
            ) { id in
                sourceFilter = options.first { $0.id == id } ?? .all
            }
        }
    }

    private var artistChip: some View {
        Button {
            showArtistPicker.toggle()
        } label: {
            LyricsManagerMenuChip(title: artistFilter ?? L10n.t("全部歌手"), active: artistFilter != nil)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showArtistPicker, arrowEdge: .bottom) {
            LyricsManagerOptionList(
                allTitle: L10n.t("全部歌手"),
                options: store.distinctArtists.map { .init(id: $0, title: $0) },
                selectedID: artistFilter, searchable: true
            ) { artistFilter = $0 }
        }
    }

    private var albumChip: some View {
        Button {
            showAlbumPicker.toggle()
        } label: {
            LyricsManagerMenuChip(title: albumFilter ?? L10n.t("全部专辑"), active: albumFilter != nil)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAlbumPicker, arrowEdge: .bottom) {
            LyricsManagerOptionList(
                allTitle: L10n.t("全部专辑"),
                options: store.distinctAlbums.map { .init(id: $0, title: $0) },
                selectedID: albumFilter, searchable: true
            ) { albumFilter = $0 }
        }
    }

    private func nowPlayingRow(scrollProxy: ScrollViewProxy) -> some View {
        let playback = PlaybackCoordinator.shared
        return LyricsManagerNowPlayingRow(
            artwork: nowPlaying.artwork, coverURL: nil,
            title: playback.title, artist: nowPlaying.displayArtist,
            onLocate: { locateNowPlaying(scrollProxy: scrollProxy) })
    }

    /// 「定位」:这首被搜索或筛选挡住时先清掉,再跳过去。
    private func locateNowPlaying(scrollProxy: ScrollViewProxy) {
        guard let key = nowPlayingKey else { return }
        guard sortedFiltered.contains(where: { $0.key == key }) else {
            resetFilters()
            clearSearch()
            // 等这一拍的筛选生效、列表换成全量之后再定位。
            DispatchQueue.main.async { focusCurrentlyPlaying(scrollProxy: scrollProxy) }
            return
        }
        focusCurrentlyPlaying(scrollProxy: scrollProxy)
    }

    /// 正在放的这首在列表里对应哪一条:跟 focusCurrentlyPlaying 同一套候选(归一化 key、原样拼的 key、各自的宽松 key),
    /// 占位行也算。换歌、列表重读、占位行变了之后各算一次,不在 body 里现算。
    private func refreshNowPlayingKey() {
        let playback = PlaybackCoordinator.shared
        guard !playback.artist.isEmpty || !playback.title.isEmpty else {
            if nowPlayingKey != nil { nowPlayingKey = nil }
            return
        }
        let normalizedKey = EnrichCacheKeys.normalizedKey(
            artist: playback.artist, title: playback.title, album: playback.album)
        let rawKey = "\(playback.artist)|\(playback.title)|\(playback.album)"
        let candidates = normalizedKey == rawKey ? [normalizedKey] : [normalizedKey, rawKey]
        let resolved: String?
        if let placeholder = placeholderSummary, candidates.contains(placeholder.key) {
            resolved = placeholder.key
        } else if let exact = candidates.first(where: { candidate in
            store.summaries.contains(where: { $0.key == candidate })
        }) {
            resolved = exact
        } else {
            resolved = candidates.lazy.compactMap({ store.key(matchingLoose: $0) }).first
        }
        if resolved != nowPlayingKey { nowPlayingKey = resolved }
    }

    /// 列表上面那一行:在看哪一类、几首(在搜时是「找到 N 首」),多选时「已选 N 首」,右边是排序 / 分组。
    private var listHeader: some View {
        HStack(spacing: 6) {
            Text(listTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if committedSearchText.isEmpty {
                Text(selectableFiltered.count.formatted())
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if selectedVisibleKeys.count > 1 {
                Text(String(format: L10n.t("已选 %@ 首"), selectedVisibleKeys.count.formatted()))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            if showDeletedFeedback {
                Label(L10n.t("已删除"), systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            sortMenu
        }
        .padding(.top, 2)
        .padding(.horizontal, 4)
    }

    private var listTitle: String {
        if !committedSearchText.isEmpty {
            return String(format: L10n.t("找到 %@ 首"), selectableFiltered.count.formatted())
        }
        if statusFilter != .all { return Self.statusTitle(statusFilter) }
        if case let .only(kind) = kindFilter { return kind.label }
        return L10n.t("全部歌曲")
    }

    private var sortMenu: some View {
        Menu {
            Picker(L10n.t("分组"), selection: $groupByAlbum) {
                Text(L10n.t("不分组")).tag(false)
                Text(L10n.t("按专辑分组")).tag(true)
            }
            .pickerStyle(.inline)
            Picker(L10n.t("排序"), selection: $sortOption) {
                ForEach(LyricsSortOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(sortsByRelevance ? L10n.t("按相关度") : sortOption.title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .help(sortsByRelevance ? L10n.t("搜索时默认按相关度排序：歌名开头匹配的优先，其次是歌名、歌手、专辑中匹配的") : "")
    }

    /// 列表报上来的选中。编辑里有没保存的改动时,点别的歌先问一句(保存 / 不保存 / 取消),这时选中先不换,列表退回原来那几首。
    private func listSelectionChanged(_ keys: Set<String>) {
        guard keys != selectedKeys else { return }
        // 点回正在编辑的那一首不算换歌,不问。
        if isEditorDirty, editingKey.map({ keys != [$0] }) ?? true {
            pendingSelection = keys
            showUnsavedEditAlert = true
            // 这时还在列表那一次赋值的发布当中(@Published 在赋值之前发),当场改回去会被那次赋值盖掉,推到下一拍。
            DispatchQueue.main.async {
                if listSelection.keys != selectedKeys { listSelection.keys = selectedKeys }
            }
            return
        }
        selectedKeys = keys
    }

    /// 强调色跟着选中和键盘焦点走:列表没焦点时选中行是灰底,照常彩色。
    private func refreshListEmphasis() {
        listEmphasis.update(windowFrame.listHasKeyFocus ? selectedKeys : [])
    }

    /// 代码里改了选中之后,表格上的选中按数据重新对一遍。SwiftUI 把选中同步到表格时只管滚到过的行:屏幕外那行旧选中
    /// 它取消不掉,滚回去还亮着,再 ⌘ 点选会被一起选进来。列表第 i 行就是数据里第 i 条(组头也算一行),对不上就整份换掉;
    /// 行数对不上(列表还没换成新数据)就不动(见 11 章决策 91)。
    private func alignTableSelection() {
        guard let table = windowFrame.listTable else { return }
        let keys: [String] = groupByAlbum ? albumEntries.map(\.id) : sortedFiltered.map(\.key)
        guard table.numberOfRows == keys.count else { return }
        let current = table.selectedRowIndexes
        if current.count == selectedKeys.count, current.allSatisfy({ selectedKeys.contains(keys[$0]) }) { return }
        table.selectRowIndexes(IndexSet(keys.indices.filter { selectedKeys.contains(keys[$0]) }), byExtendingSelection: false)
    }

    /// 选中这一首;编辑里有没保存的改动、要换到别的歌时先问一句,问的时候返回 false(这一下的动作不做)。
    private func select(_ key: String) -> Bool {
        if isEditorDirty, editingKey != key {
            pendingSelection = [key]
            showUnsavedEditAlert = true
            return false
        }
        selectedKeys = [key]
        return true
    }

    private func songList(scrollProxy: ScrollViewProxy) -> some View {
        SongList(rows: SongRows(entries: groupByAlbum ? .grouped(albumEntries) : .flat(sortedFiltered),
                                query: committedSearchText,
                                nowPlayingKey: nowPlayingKey,
                                nowPlayingArtwork: nowPlaying.artwork,
                                pins: pins.pins,
                                albumDisplayMap: store.albumDisplayMap,
                                language: languageSettings.appLanguage,
                                emphasis: listEmphasis),
                 selection: listSelection,
                 // 菜单闭包里只用参数 keys,一个字都不能读 selectedKeys。官方文档明确:
                 // 从空白处唤出菜单时 keys 是空集(即使当前有选中项也一样);图省事读
                 // selectedKeys 就会变成"右键点空白 → 菜单显示『删除 8 条』 → 删掉 8 条
                 // 根本不在右键位置的条目"。空白处只给「全选」。
                 // 右键点某个未被选中的行时系统会把选中收敛到那一行、keys 就是那一行;
                 // 右键点已选中区内任一行则 keys 是整个选区。
                 menu: { keys in listMenu(keys) })
        .equatable()
        // 首次开窗、summaries 还没任何内容时叠一个"正在加载"提示,不让空 List 看着像一片白屏。
        // 用 .overlay 而不是拿 if/else 把 List 整个换掉:下面 .onAppear(真正触发 reload() 的地方)要挂在一直存在的 List 上。
        .overlay {
            if store.isLoading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在加载…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if sortedFiltered.isEmpty, placeholderSummary == nil {
                emptyListState
            }
        }
        // 筛选条件一变就把选中项收敛到当前可见集合。用 formIntersection 而不是
        // 无条件清空:用户只是微调搜索词时保住已有选择更符合预期。
        .onChange(of: filterToken) { _, _ in
            selectedKeys.formIntersection(Set(filtered.map(\.key)))
        }
        // 换分组、换排序之后每一行的位置都变了,滚回选中的那一首(见 11 章决策 75)。
        .onChange(of: groupByAlbum) { _, _ in revealSelection(scrollProxy: scrollProxy) }
        .onChange(of: sortOption) { _, _ in revealSelection(scrollProxy: scrollProxy) }
        .onReceive(listSelection.$keys) { keys in listSelectionChanged(keys) }
        .onChange(of: selectedKeys) { _, keys in
            if listSelection.keys != keys {
                listSelection.keys = keys
                // 代码里改的选中:等列表这一拍按它同步完,再把表格对一遍。
                DispatchQueue.main.async { alignTableSelection() }
            }
            refreshListEmphasis()
        }
        .onChange(of: windowFrame.listHasKeyFocus) { _, _ in refreshListEmphasis() }
        // 删除确认弹窗挂在 List 上——不能挂在 detailView 里(多选时右侧渲染的是批量
        // 面板、detailView 根本不在视图树里,置 isPresented 会静默无效),也故意不跟
        // 「清空全部缓存」那个弹窗挂在同一条修饰符链上:SwiftUI 对同一条链上叠加
        // 多个同类型呈现修饰符历史上有互相顶掉的问题。List 在侧栏里始终存在、生命周期稳定。
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
            // 同「全量重新扫库」那处:只在确认框开着时算。
            if showBatchDeleteConfirm { Text(batchDeleteMessage) }
        }
        .onAppear {
            refreshListEmphasis()
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
                refreshNowPlayingKey()
                guard pendingAutoFocus else { return }
                pendingAutoFocus = false
                await windowFrame.waitUntilListReady(minRows: sortedFiltered.count)
                // 只把详情换成正在放的这首,列表停在顶上:滚到它那一行要点「正在播放」那一行的「定位」(见 11 章决策 64)。
                focusCurrentlyPlaying(scrollProxy: scrollProxy, scroll: false)
                // 开窗时 AppKit 把键盘焦点给第一个输入框(搜索框),交给列表:方向键直接换歌,⌘F 再去搜索。
                DispatchQueue.main.async { windowFrame.focusList() }
            }
        }
        // 自动匹配的进度卡、写入失败的红字挂在列表底下,列表的最后几行能滚到它们上面。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    /// 侧栏的歌曲列表,单独一个视图、按 == 比对。外层 body 里任何一个状态变了都要整个重算(换选中、编辑格子每敲一个字、
    /// 自动匹配的进度),列表要是跟着重算,上万行的行闭包全部重跑、整表重新比对。== 只比画在行上的东西;选中强调各行
    /// 自己读 emphasis,别再从这一层把选中传进行里(见 11 章决策 89)。
    private struct SongList<Menu: View>: View, Equatable {
        let rows: SongRows
        @ObservedObject var selection: SongListSelection
        let menu: (Set<String>) -> Menu

        static func == (a: Self, b: Self) -> Bool {
            a.rows == b.rows && a.selection === b.selection
        }

        var body: some View {
            List(selection: $selection.keys) {
                rows
            }
            // 用 .inset 不用 .sidebar:.sidebar 会把行里的字画淡,在玻璃侧栏上读起来像灰掉了。
            .listStyle(.inset)
            // 估算行高必须等于实际行高:没滚到过的行按它算,默认的 24 比实际小一半多,几千首时 scrollTo 落点差上百行(见 11 章决策 62)。
            .environment(\.defaultMinListRowHeight, LyricsManagerView.listRowHeight)
            .scrollContentBackground(.hidden)
            // 不传 primaryAction:macOS 上它绑的是双击,这个列表双击目前没有语义。
            .contextMenu(forSelectionType: String.self) { keys in menu(keys) }
        }
    }

    /// 列表里的行(ForEach 那一层)。单独一个视图:SongList 观察着选中、每换一次选中都重算,ForEach 写在那一层的话
    /// 它跟着重建,分组时上万行的行闭包又要全部重跑一遍。这一层没有选中、没有闭包,比对相等就整个跳过。
    /// 别给它加 .equatable():EquatableView 夹在 List 和 ForEach 中间,列表一行都选不中(见 11 章决策 89)。
    private struct SongRows: View, Equatable {
        enum Entries {
            case flat([EnrichCacheStore.Summary])
            case grouped([AlbumListEntry])

            /// 同一份数组(缓存盒里取出来的那份)才算没变,不逐条比。
            func isSameArray(as other: Entries) -> Bool {
                switch (self, other) {
                case let (.flat(a), .flat(b)): return Self.sameStorage(a, b)
                case let (.grouped(a), .grouped(b)): return Self.sameStorage(a, b)
                default: return false
                }
            }

            private static func sameStorage<T>(_ a: [T], _ b: [T]) -> Bool {
                a.count == b.count && a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pa.baseAddress == $0.baseAddress } }
            }
        }

        let entries: Entries
        let query: String
        let nowPlayingKey: String?
        let nowPlayingArtwork: NSImage?
        let pins: [String: Int]
        /// 跟 summaries 一起重建:它变了,entries 一定也换了一份,== 里不另外比。
        let albumDisplayMap: [String: String]
        /// 行里的字是现取的界面语言,切换语言时整张表重画。
        let language: String
        let emphasis: SongListEmphasis

        static func == (a: Self, b: Self) -> Bool {
            a.entries.isSameArray(as: b.entries) && a.query == b.query && a.nowPlayingKey == b.nowPlayingKey
                && a.nowPlayingArtwork === b.nowPlayingArtwork && a.pins == b.pins && a.language == b.language
                && a.emphasis === b.emphasis
        }

        var body: some View {
            switch entries {
            case let .grouped(albumEntries):
                // 组头当作一行不能选中的条目,跟歌排在同一层 ForEach 里。别写成 Section 里再套 ForEach:List 每次比对都要
                // 从第一组数起找第 i 行,上万首、几千组时插一条占位行就要卡几秒(见 11 章决策 70)。
                ForEach(albumEntries) { entry in
                    switch entry {
                    case let .header(group):
                        LyricsManagerAlbumHeader(album: group.album, artist: group.artist, count: group.items.count)
                            // 行高跟歌曲行一样(内容 48 + .inset 自带的 8),估算行高才准;组头贴着下面那组歌。
                            .frame(height: LyricsManagerView.listRowHeight - 8, alignment: .bottom)
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                    case let .song(summary):
                        row(summary)
                    }
                }
            case let .flat(summaries):
                ForEach(summaries) { row($0) }
            }
        }

        private func albumDisplay(_ album: String) -> String {
            LyricsManagerView.albumDisplay(album, in: albumDisplayMap)
        }

        private func row(_ summary: EnrichCacheStore.Summary) -> some View {
            SongListRow(
                summary: summary,
                albumDisplayName: summary.isListedMV ? L10n.t("MV") : albumDisplay(summary.displayAlbum),
                query: query,
                isNowPlaying: summary.key == nowPlayingKey,
                isPinned: pins[summary.key] != nil,
                artwork: summary.key == nowPlayingKey ? nowPlayingArtwork : nil,
                emphasis: emphasis)
            .tag(summary.key)
            .listRowSeparator(.hidden)
        }
    }

    /// 列表的一行。强调色自己从 emphasis 读:换选中时屏幕上那几行重算这一层,里面那层(LyricsManagerSongRow)只有强调
    /// 真的变了的一两行重画。
    private struct SongListRow: View {
        let summary: EnrichCacheStore.Summary
        let albumDisplayName: String
        let query: String
        let isNowPlaying: Bool
        let isPinned: Bool
        let artwork: NSImage?
        @ObservedObject var emphasis: SongListEmphasis

        var body: some View {
            LyricsManagerSongRow(
                summary: summary,
                albumDisplayName: albumDisplayName,
                query: query,
                isNowPlaying: isNowPlaying,
                isPinned: isPinned,
                isEmphasized: emphasis.keys.contains(summary.key),
                artwork: artwork)
        }
    }

    /// 列表那一份选中(见 listSelection)。
    @MainActor
    private final class SongListSelection: ObservableObject {
        @Published var keys: Set<String> = []
    }

    /// 选中、列表有键盘焦点的那几行(见 LyricsManagerSongRow.isEmphasized)。集合真的变了才发布。
    @MainActor
    private final class SongListEmphasis: ObservableObject {
        @Published private(set) var keys: Set<String> = []

        func update(_ keys: Set<String>) {
            if keys != self.keys { self.keys = keys }
        }
    }

    /// 列表的右键菜单:空白处是「全选」,一首是这首的全部操作,几首是批量能做的那几样。
    @ViewBuilder
    private func listMenu(_ keys: Set<String>) -> some View {
        // orderedVisibleKeys 已经把「正在搜索」占位行排除在外:右键点的全是占位行时菜单是空的。
        let visible = orderedVisibleKeys(keys)
        if keys.isEmpty {
            if !selectableFiltered.isEmpty {
                Button(String(format: L10n.t("全选 %@ 首"), selectableFiltered.count.formatted())) {
                    selectedKeys = Set(selectableFiltered.map(\.key))
                }
            }
        } else if visible.count == 1, let summary = store.summary(forKey: visible[0]) {
            singleItemMenu(summary)
        } else if !visible.isEmpty {
            multiItemMenu(visible)
        }
    }

    /// 一首歌能做的事(右键菜单)。
    @ViewBuilder
    private func singleItemMenu(_ summary: EnrichCacheStore.Summary) -> some View {
        Button(L10n.t("搜索候选歌词")) { openSearch(for: summary.key) }
            .disabled(rematchRunningKey != nil)
        Button(L10n.t("重新自动匹配")) { startRematch(for: summary.key) }
            .disabled(rematchBlocked)
        if summary.hasDecision {
            Button(L10n.t("解析决策")) { openDecision(for: summary.key) }
        }
        Divider()
        if summary.isInstrumental {
            Button(L10n.t("取消纯音乐标记")) { Task { await store.setInstrumental(key: summary.key, false) } }
        } else {
            Button(L10n.t("标为纯音乐")) { Task { await store.setInstrumental(key: summary.key, true) } }
        }
        Button(L10n.t("拷贝歌名与歌手")) { copySongName(summary) }
        if summary.hasLyrics {
            Button(L10n.t("在访达中显示歌词文件")) { revealLyricsFile(summary.key) }
            Button(L10n.t("在外部编辑器中编辑歌词")) {
                LyricsExternalEditor.shared.open(artist: summary.artist, title: summary.title, album: summary.album)
            }
        }
        Divider()
        // 跟批量删除、⌘⌫ 走同一条 requestDelete → 侧栏那个确认弹窗的路径:只留一处弹窗,文案/统计/快照逻辑不会两处漂移。
        Button(L10n.t("删除本地记录…"), role: .destructive) { requestDelete([summary.key]) }
    }

    /// 选了几首时能做的事:自动匹配其中没词的、标为纯音乐、删除。
    @ViewBuilder
    private func multiItemMenu(_ keys: [String]) -> some View {
        let picked = Set(keys)
        let retryable = store.summaries.filter { picked.contains($0.key) && EnrichCacheStore.isFillSweepRetryable($0) }
            .map(\.key)
        if !retryable.isEmpty {
            Button(String(format: L10n.t("重新自动匹配选中的 %@ 首"), retryable.count.formatted())) {
                requestFillSweep(retryable)
            }
            .disabled(fillSweepStatus?.running == true || fillSweepPending)
        }
        Button(L10n.t("全部标为纯音乐")) { markInstrumental(keys) }
            .disabled(markingInstrumental)
        Divider()
        Button(String(format: L10n.t("删除选中的 %@ 条"), keys.count.formatted()), role: .destructive) {
            requestDelete(picked)
        }
    }

    /// 「重新自动匹配」点不了的时候:一首正在匹配,或者自动匹配 / 全量扫库在跑(引擎那时不接)。
    private var rematchBlocked: Bool {
        rematchRunningKey != nil || fillSweepStatus?.running == true || fillSweepPending
    }

    private func openSearch(for key: String) {
        guard select(key), let summary = store.summary(forKey: key) else { return }
        openSearchSheet(summary)
    }

    private func openSearchSheet(_ summary: EnrichCacheStore.Summary) {
        searchTarget = SearchTarget(key: summary.key, artist: summary.artist, title: summary.title,
                                    album: summary.displayAlbum, keyAlbum: summary.album, durationSecs: summary.durationSecs)
    }

    private func openDecision(for key: String) {
        guard select(key) else { return }
        showDecisionSheet = true
    }

    private func startRematch(for key: String) {
        guard select(key) else { return }
        Task { await runRematch(key: key) }
    }

    private func copySongName(_ summary: EnrichCacheStore.Summary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(summary.title) - \(summary.shownArtist)", forType: .string)
    }

    private func revealLyricsFile(_ key: String) {
        guard let url = store.lyricsFileURL(forKey: key) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func requestFillSweep(_ keys: [String]) {
        if LyricsFillSweep.request(keys: keys) { fillSweepPending = true; fillSweepPendingIsFull = false }
    }

    private func markInstrumental(_ keys: [String]) {
        markingInstrumental = true
        Task {
            await store.setInstrumental(keys: keys, true)
            markingInstrumental = false
        }
    }

    /// 侧栏底部:自动匹配的进度卡,写入失败时的红字。
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            if let phase = sweepPhase {
                LyricsManagerSweepCard(
                    phase: phase,
                    listingMissing: statusFilter == .missing,
                    fallbackSecondsPerTrack: fillSweepStatus?.isFullScan == true
                        ? fullScanFallbackSecondsPerTrack : FillSweepProgressText.fillFallbackSecondsPerTrack,
                    onStop: { LyricsFillSweep.requestCancel() })
            }
            // store.lastError 跟选中状态无关、永远有地方显示:批量删完选中清空、右侧变回空占位时,
            // 「写入本地记录文件失败」这类错误没有别的宿主。
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.08)))
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// 进度卡此刻该说什么:点了之后、引擎接手之前;跑着;刚跑完的几秒(全量那一轮的收尾不在这里说,设置页那一行有)。
    private var sweepPhase: LyricsManagerSweepCard.Phase? {
        if fillSweepPending { return .preparing(full: fillSweepPendingIsFull) }
        guard let status = fillSweepStatus else { return nil }
        if status.running { return .running(status) }
        if let finished = status.finishedAt, !status.isFullScan, dismissedSweepReceipt != finished,
           status.done > 0 || status.isOffline,
           Date().timeIntervalSince1970 - Double(finished) < Self.sweepReceiptSeconds {
            return .finished(status)
        }
        return nil
    }

    /// 「自动匹配完了」那句在进度卡上留几秒。
    private static let sweepReceiptSeconds: Double = 8

    var body: some View {
        GeometryReader { geometry in
            let shownSidebarWidth = CGFloat(LyricsManagerSidebarWidth.shown(
                stored: sidebarWidth, windowWidth: Double(geometry.size.width), inset: Double(Self.panelInset)))
            ScrollViewReader { scrollProxy in
                HStack(spacing: 0) {
                    sidebar(scrollProxy: scrollProxy)
                        .frame(width: shownSidebarWidth)
                        .padding(.leading, Self.panelInset)
                        .padding(.vertical, Self.panelInset)
                        .overlay(alignment: .trailing) {
                            LyricsManagerSidebarHandle(
                                onDrag: { dx in
                                    if sidebarDragStart == nil { sidebarDragStart = Double(shownSidebarWidth) }
                                    guard let start = sidebarDragStart else { return }
                                    sidebarWidth = LyricsManagerSidebarWidth.clamped(start + Double(dx))
                                },
                                onDragEnd: {
                                    sidebarDragStart = nil
                                    persistSidebarWidth()
                                },
                                onDoubleClick: {
                                    sidebarWidth = LyricsManagerSidebarWidth.standard
                                    persistSidebarWidth()
                                })
                            .offset(x: 6)
                        }
                    detailColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                // 窗口开着期间换歌就跟着重新定位——不然停留在"开窗那一刻播的那首",见
                // LyricsManagerNowPlayingObserver 类头注。首次挂载时 trackSignature 已经是
                // 当前播放那首(CombineLatest3 订阅即发一次),不会跟 pendingAutoFocus 那次
                // 开窗定位重复触发;这里只在**后续**换歌时才会再跑一次。挂在 ScrollViewReader 里面:
                // focusCurrentlyPlaying 要用 scrollProxy。
                .onChange(of: nowPlaying.trackSignature) { _, _ in
                    // 必须先刷占位行再定位——focusCurrentlyPlaying 里"占位行也能被定位到"
                    // 那道判断读的是 placeholderSummary,换歌那一刻它还是上一首的,先刷新
                    // 才能让新歌(如果也在搜索中)被正确定位到。
                    refreshPlaceholder()
                    let previous = nowPlayingKey
                    refreshNowPlayingKey()
                    // 选中的正是上一首正在放的歌(或什么都没选)才跟着换,点了别的歌就不动;列表不滚动(见 11 章决策 64)。
                    // 正在改歌词或多选了一批时也不动:选中整个换成新歌,编辑缓冲随之重载,敲的内容没有任何提示就没了。
                    // 解析决策面板开着时也不动:它读的是选中那首。搜索候选歌词面板开着时同样不动:面板自己记着为哪首开的
                    // (SearchTarget),背后的详情却会换成新歌,采纳之后看到的不是刚采纳的那首(见 11 章决策 86、92)。
                    let followsPlayback = selectedKeys.isEmpty || previous.map { selectedKeys == [$0] } == true
                    guard followsPlayback, !isEditorDirty, editMode == .preview, searchTarget == nil, !showDecisionSheet else { return }
                    focusCurrentlyPlaying(scrollProxy: scrollProxy, scroll: false)
                }
                // 窗口开着期间引擎一直在写缓存:占位行等它写完才能「顶替」成真实条目,补空扫描每条
                // 搜完都会改文件,平时也会给已有的歌补译文、加新歌。换歌 / reload 都不会在这些时刻自动
                // 发生,得有个人主动再问一次磁盘。占位行在等、或扫描刚补出一首 / 一轮开始或结束时每拍都问,
                // 其余时候放慢到 LyricsManagerRefresh.idleInterval 一次;reload(onlyIfChanged: true) 在文件没变时
                // 只是一次 stat。窗口关掉这个 .task 自动取消,不会有常驻计时器漏在后台;窗口看不见
                // (windowSurface)时整个停掉,重新看得见时从头来一遍(先按指纹读一次,再接着轮询)。
                .task(id: windowSurface.isVisible) {
                    guard windowSurface.isVisible else { return }
                    // 两份状态文件先读,再重读缓存:后读的话扫描明明在跑,进度卡头几秒是空着的。
                    fillSweepStatus = LyricsFillSweep.current
                    fullScanState = LyricsFullScan.current
                    await store.reload(onlyIfChanged: true)
                    refreshPlaceholder()
                    while !Task.isCancelled {
                        // 扫描跑着时 2 秒一次(进度文件每条都推进,进度卡要跟着动),刚点了自动匹配、
                        // 等引擎接手那几秒 1 秒一次,没在跑就 5 秒。
                        let interval: Double = fillSweepPending ? 1 : (fillSweepStatus?.running == true ? 2 : 5)
                        try? await Task.sleep(for: .seconds(interval))
                        guard !Task.isCancelled else { continue }
                        // 进度文件按 mtime 读(LyricsFillSweep.current 内部缓存),Equatable
                        // 没变就不赋值——不制造无意义的重渲染。
                        let previous = fillSweepStatus
                        let sweep = LyricsFillSweep.current
                        if sweep != fillSweepStatus { fillSweepStatus = sweep }
                        let full = LyricsFullScan.current
                        if full != fullScanState { fullScanState = full }
                        if fillSweepPending && !LyricsFillSweep.isPending { fillSweepPending = false }
                        // 扫描期间缓存文件每搜完一首都会变,可列表上看得见的东西只在补出一首、一轮开始或结束
                        // 时才变(LyricsFillSweep.changesVisibleRows);每条都整份重读一次要一两秒 CPU。
                        let busy = placeholderSummary != nil
                            || LyricsFillSweep.changesVisibleRows(previous: previous, current: sweep)
                        guard LyricsManagerRefresh.shouldPoll(busy: busy,
                                                              sinceLastIdle: Date().timeIntervalSince(lastIdleRefresh))
                        else { continue }
                        if !busy { lastIdleRefresh = Date() }
                        await store.reload(onlyIfChanged: true)
                        refreshPlaceholder()
                    }
                }
            }
        }
        // 标题栏透明、内容铺到顶(场景挂 .windowStyle(.hiddenTitleBar)),红绿灯落在侧栏左上角。
        .ignoresSafeArea()
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: Self.minimumWindowSize.width, idealWidth: 1360,
               minHeight: Self.minimumWindowSize.height, idealHeight: 820)
        // 窗口标题跟着界面语言走:App.swift 里 Window 的标题只在构造场景时求值一次,body 随 languageSettings 重算时这里
        // 每次重新应用(同欢迎页)。标题栏藏着,标题出现在 Dock 右键的窗口列表、调度中心和辅助功能里。
        .navigationTitle(L10n.t("歌词管理"))
        // 撑高标题栏(有工具栏时 52pt),红绿灯落在离左上角约 19pt 处、正好在侧栏圆角里。见 EmptyUnifiedToolbar。
        .background(EmptyUnifiedToolbar())
        // 零尺寸探针拿真实 NSWindow 交给 windowFrame——只借视图树把 NSView 挂进窗口,不参与布局。
        .background(LyricsManagerWindowCapture(controller: windowFrame, surface: windowSurface).frame(width: 0, height: 0))
        .background(shortcutButtons)
        // 刻意挂在最外层 —— 跟侧栏上的「清空全部缓存」、List 上的「删除」、详情那一栏的放弃修改
        // 分处不同层级。同一条修饰符链上叠多个呈现修饰符历史上有
        // 互相顶掉的问题(见那两处各自的注释),分层挂就不用去论证"这个版本会不会冲突"。
        .confirmationDialog(
            L10n.t("确定要清空全部歌词时间轴校正吗？"),
            isPresented: $showClearOffsetsConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("清空全部时间轴校正"), role: .destructive) {
                LyricsOffsetStore.shared.clearAllTrackOffsets()
                PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
                // 详情页输入框也归零,不然还显示旧值,这时回车会把刚清掉的值写回去。
                editedOffsetSeconds = AppSettings.formattedSeconds(ms: 0)
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(String(format: L10n.t("将清除 %d 首歌曲的手动时间轴校正，此操作无法撤销。歌词内容和设置中的「时间轴偏移」不受影响。清除后，这些歌曲将恢复自动更新歌词源"), offsets.trackOffsetCount))
        }
        // 侧栏「⋯」菜单里的「全量重新扫库」。文案、待扫首数与预计时长跟设置页那一行共用同一份
        // (LyricsLibraryStatsPanel 的几个静态函数),两个入口说的数不能分叉。
        .confirmationDialog(
            L10n.t("全量重新扫库？"),
            isPresented: $confirmFullScan,
            titleVisibility: .visible
        ) {
            Button(L10n.t("开始扫描")) {
                if LyricsFillSweep.requestFullScan() { fillSweepPending = true; fillSweepPendingIsFull = true }
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            // message 闭包不管确认框弹没弹,每次 body 求值都会执行;按开关门住,不弹时一次都不算。
            if confirmFullScan { Text(fullScanConfirmMessage) }
        }
        // 电台校准的清空确认。同样单独挂一层,理由见上面那条。
        .confirmationDialog(
            L10n.t("确定要清空全部电台校正吗？"),
            isPresented: $showClearRadioOffsetsConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("清空全部电台校正"), role: .destructive) {
                LyricsOffsetStore.shared.clearAllRadioOffsets()
                PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(String(format: L10n.t("将清除 %d 首歌曲的电台时间轴校正，此操作无法撤销。这些校正仅在播放电台时生效，清除后不影响正常播放时的歌词"), offsets.radioOffsetCount))
        }
        // 恢复确认。跟上面两个确认弹窗一样各挂各的层级,不叠在同一条修饰符链上。
        .confirmationDialog(
            L10n.t("确定要从此备份恢复歌词库吗？"),
            isPresented: $showRestoreSnapshotConfirm,
            titleVisibility: .visible
        ) {
            // key 用「从备份恢复」而不是复用已有的「恢复」—— 那条的英文是 "Reset"
            // (「恢复默认」语境),这里是 restore,复用直接翻错。
            Button(L10n.t("从备份恢复")) {
                guard let snapshot = pendingRestoreSnapshot else { return }
                Task {
                    restoreSnapshotResult = await store.restoreFromAutoSnapshot(snapshot)
                        ?? L10n.t("无法读取这份备份")
                    pendingRestoreSnapshot = nil
                }
            }
            Button(L10n.t("取消"), role: .cancel) { pendingRestoreSnapshot = nil }
        } message: {
            // 说清楚它**不是**"回到那一刻的状态":铺文件是覆盖+新增,不删除备份里没有的
            // 条目(restore 走的是 LyricsBackupArchive.plan,只有 added/overwritten 两类)。
            // 用户以为是整体回滚、结果发现之后新解析的歌还在,那是另一种惊吓。
            Text(L10n.t("备份中的歌词文件将写回歌词文件夹：同名文件会被覆盖，缺少的文件会补齐；备份之后新增的歌曲不受影响。恢复后立即生效，无需重启"))
        }
        .alert(L10n.t("恢复歌词库"), isPresented: Binding(
            get: { restoreSnapshotResult != nil },
            set: { if !$0 { restoreSnapshotResult = nil } }
        )) {
            Button(L10n.t("好")) { restoreSnapshotResult = nil }
        } message: {
            Text(restoreSnapshotResult ?? "")
        }
        // 见 AuxiliaryWindowActivation 注释——只记账,不碰 Dock 图标。
        .onAppear {
            AuxiliaryWindowActivation.windowDidAppear("lyrics-manager")
            store.holdSnapshot("lyrics-manager")
        }
        // 切回 App 时重新读一次盘。
        //
        // 列表是**开窗那一刻的快照**,而引擎在窗口开着期间会持续往同一个文件写:新歌
        // 是新增条目,给已有歌补机翻译文/逐字时间轴则是原地更新。不刷新的话,一首刚补上译文
        // 的歌在列表里始终不亮绿色的译文标记,而歌词本身在悬浮窗里是正常显示的
        // (那条路径读的是实时数据)。
        //
        // 挑"App 重新激活"当触发点,而不是上文件监听:典型用法就是切出去听歌、过一阵切回来,
        // 这个时机覆盖得住,而且 reload() 会把读盘+解析(缓存大了要 30ms 以上)放后台线程,
        // 不像 FSEvent 那样需要自己做防抖。窗口一直摆在副屏、人从不切走的情况由列表那条轮询的
        // 闲时档兜住(见 LyricsManagerRefresh)。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // onlyIfChanged:绝大多数激活时缓存文件根本没变,mtime 指纹相同就整条链
            // (读盘/解析/重建/summaries 重发布 → List 全量 diff)都不跑。
            Task {
                await store.reload(onlyIfChanged: true)
                refreshPlaceholder()
            }
        }
        // 重读之后选着的歌手 / 专辑可能已经不在了(那几首被删了、改了标签):下拉会指着一个不存在的项,
        // 列表空着也看不出为什么。回到「全部」。
        .onChange(of: store.summariesGeneration) { _, _ in
            if let a = artistFilter, !store.distinctArtists.contains(a) { artistFilter = nil }
            if let b = albumFilter, !store.distinctAlbums.contains(b) { albumFilter = nil }
        }
        .onDisappear {
            AuxiliaryWindowActivation.windowDidDisappear("lyrics-manager")
            // 关窗后快照(连同列表约 300 MB)由 store 延时清掉,下次开窗重新读盘(约 0.7 秒)。
            store.releaseSnapshot("lyrics-manager")
            // 见 pendingAutoFocus 的注释:@State 会跨关窗存活,得自己把这个闸复位,
            // 下次开窗才会重新定位一次。
            pendingAutoFocus = true
        }
        .onChange(of: store.summariesGeneration) { _, _ in refreshNowPlayingKey() }
        .onChange(of: placeholderSummary?.key) { _, _ in refreshNowPlayingKey() }
        // 「自动匹配完了」那句在进度卡上留一会儿就收起。
        .task(id: fillSweepStatus?.finishedAt) {
            guard let finished = fillSweepStatus?.finishedAt else { return }
            let age = Date().timeIntervalSince1970 - Double(finished)
            if age < Self.sweepReceiptSeconds {
                try? await Task.sleep(for: .seconds(Self.sweepReceiptSeconds - age))
                guard !Task.isCancelled else { return }
            }
            dismissedSweepReceipt = finished
        }
    }

    /// 窗口最小尺寸:侧栏最窄 440、右边至少 480,加上侧栏外边距。
    private static let minimumWindowSize = CGSize(width: 940, height: 620)

    /// 不画出来的几颗按钮,只为接窗口级快捷键:⌘F 聚焦搜索、⌘⌫ 删除选中、⌘E 编辑歌词。
    private var shortcutButtons: some View {
        ZStack {
            Button("") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            // 快捷键取 ⌘⌫ 而不是裸 ⌫:.keyboardShortcut 是**窗口级**快捷键,跟焦点在哪无关,绑裸 ⌫ 会把搜索框和
            // 歌词编辑格子的退格键全抢掉。空选时禁用,按了毫无反应。
            Button("") { deleteSelectionShortcut() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selectedVisibleKeys.isEmpty)
            Button("") { beginLineEditing() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!canEditLyrics)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func deleteSelectionShortcut() {
        // 窗口级快捷键会先于文本框拿到 ⌘⌫:焦点在搜索框或歌词编辑框里时,这一下是「删到行首」,
        // 替文本框做完就返回,别弹删除确认。
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView,
           NSApp.currentEvent?.type == .keyDown {
            text.deleteToBeginningOfLine(nil)
            return
        }
        requestDelete(selectedKeys)
    }

    private func refreshWithFeedback() {
        Task {
            await store.reload()
            // 占位行跟着磁盘核对一次:引擎刚写完那首的话,不刷新会跟真实行在列表里各占一行。
            refreshPlaceholder()
            // 重新读盘之后缓存内容可能已经变了(引擎自己写过、或别处删过),选中集合里
            // 可能残留已经不存在的 key——跟筛选变化那条 onChange 同一个道理,收敛一次。占位行不在 summaries 里,
            // 还在的话别把它的选中收掉。
            var valid = Set(store.summaries.map(\.key))
            if let placeholder = placeholderSummary { valid.insert(placeholder.key) }
            selectedKeys.formIntersection(valid)
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
           let summary = store.summary(forKey: pendingDeleteKeys[0]) {
            return String(format: L10n.t("确定要删除「%@ - %@」的本地记录吗？"), summary.artist, summary.title)
        }
        return String(format: L10n.t("确定要删除选中的 %@ 条本地记录吗？"), "\(pendingDeleteKeys.count)")
    }

    // 三条完整独立的句子,不在运行时拼接——拼出来的句子英文侧语序没法翻。
    // "其中 N 条是人工修正过的" 单独成一条:那是这批里唯一删了真找不回来的东西(其余条目
    // 下次播放会重新解析),属于决策信息,值得在确认这一刻单独点出来。
    private var batchDeleteMessage: String {
        if pendingDeleteKeys.count == 1 {
            return L10n.t("已导出的歌词文件将一并删除。再次播放这首歌曲时会重新匹配，结果可能不同")
        }
        let pending = Set(pendingDeleteKeys)
        let manual = store.summaries.filter { pending.contains($0.key) && $0.isManual }.count
        if manual > 0 {
            return String(format: L10n.t("其中 %@ 条经过人工修正，删除后无法恢复。已导出的歌词文件将一并删除，此操作无法撤销。再次播放这些歌曲时会重新匹配，结果可能不同"), "\(manual)")
        }
        return L10n.t("已导出的歌词文件将一并删除，此操作无法撤销。再次播放这些歌曲时会重新匹配，结果可能不同")
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

    // 多选时右侧:先确认「选中的就是我以为的那批」(叠起来的封面、首数、各档数量、清单),再给批量能做的那几样。
    // 不放编辑器、不放占用空间——算这批的真实体积要对 lyrics/ 目录做 4N 次 stat,而"删歌词"本来也不是为了腾空间。
    private var batchSelectionPanel: some View {
        let ordered = selectedVisibleKeys
        let victims = Set(ordered)
        let picked = store.summaries.filter { victims.contains($0.key) }
        let byKey = Dictionary(picked.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let pickedInOrder = ordered.compactMap { byKey[$0] }
        let manual = picked.filter(\.isManual).count
        let wordTiming = picked.filter(\.hasWordTiming).count
        // 「无歌词」这颗只数**真的缺**的:确证过的纯音乐、有纯文本兜底的都不该算进去,
        // 否则数字跟行上的徽章互相矛盾(行显示「纯音乐」/「仅纯文本」、上面却说它是无歌词)。
        // 「源里有歌、无词」同理单独一颗,跟行上的徽章一一对应。
        let noLyrics = picked.filter { !$0.hasLyrics && !$0.isInstrumental && !$0.hasPlainTextFallback }
        // 「最近一轮零应答」再切一档,顺序必须跟行徽章的判定链一致
        // (零应答 → 源里有歌无词 → 真的没有),否则面板上的数字跟行上的徽章又会互相矛盾。
        let noResponder = noLyrics.filter(\.lastRoundHadNoResponder).count
        let indexed = noLyrics.filter { !$0.lastRoundHadNoResponder && $0.knownOnSources }.count
        let missing = noLyrics.count - indexed - noResponder
        // 「重新自动匹配选中的…」喂给引擎的 key,口径见 EnrichCacheStore.isFillSweepRetryable。
        let retryable = picked.filter(EnrichCacheStore.isFillSweepRetryable).map(\.key)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    selectedKeys.removeAll()
                } label: {
                    Label(L10n.t("取消选择"), systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .settingsGlassButtons()
            }
            .frame(height: 52)
            .background(WindowDragHandle())
            HStack(alignment: .center, spacing: 22) {
                LyricsManagerStackedCovers(urls: pickedInOrder.prefix(4).map(\.coverURL))
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: L10n.t("已选择 %@ 首"), "\(picked.count)"))
                        .font(.system(size: 28, weight: .bold))
                    // 几个统计各自独立成词条,不在运行时拼成一句长句;为 0 的那项整个不显示。
                    SettingsFlowRow(spacing: 6) {
                        if manual > 0 {
                            InfoChip(icon: "pencil.circle.fill", text: String(format: L10n.t("人工修正 %@ 首"), "\(manual)"), tint: .secondary)
                        }
                        if wordTiming > 0 {
                            InfoChip(icon: "text.word.spacing", text: String(format: L10n.t("逐字时间轴 %@ 首"), "\(wordTiming)"), tint: .secondary)
                        }
                        if missing > 0 {
                            InfoChip(icon: "text.badge.xmark", text: String(format: L10n.t("无歌词 %@ 首"), "\(missing)"), tint: .secondary)
                        }
                        if noResponder > 0 {
                            InfoChip(icon: "antenna.radiowaves.left.and.right.slash",
                                     text: String(format: L10n.t("无源应答 %@ 首"), "\(noResponder)"), tint: .secondary)
                        }
                        if indexed > 0 {
                            InfoChip(icon: "music.note", text: String(format: L10n.t("已收录、无歌词 %@ 首"), "\(indexed)"), tint: .secondary)
                        }
                    }
                    if manual > 0 {
                        Text(L10n.t("人工修正过的歌词删除后无法恢复"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            HStack(spacing: 10) {
                // 让引擎现在就把这批里没词的重新匹配一遍,不用等每首歌各自再被播到。走 LyricsFillSweep 请求文件,
                // 进度在侧栏底部那张卡上。一次只允许一轮在跑,跑着的时候置灰。
                if !retryable.isEmpty {
                    Button {
                        requestFillSweep(retryable)
                    } label: {
                        Label(String(format: L10n.t("重新自动匹配选中的 %@ 首"), "\(retryable.count)"),
                              systemImage: "wand.and.stars")
                    }
                    .settingsProminentGlassButton(tint: .accentColor)
                    .disabled(fillSweepStatus?.running == true || fillSweepPending)
                }
                Group {
                    Button {
                        markInstrumental(ordered)
                    } label: {
                        Label(L10n.t("全部标为纯音乐"), systemImage: "pianokeys")
                    }
                    .disabled(markingInstrumental)
                    Button(role: .destructive) {
                        requestDelete(selectedKeys)
                    } label: {
                        Label(String(format: L10n.t("删除选中的 %@ 条"), "\(picked.count)"), systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                }
                .settingsGlassButtons()
            }
            .controlSize(.large)
            .padding(.top, 22)
            Divider().padding(.top, 22)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(pickedInOrder) { summary in
                        batchRow(summary)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 22)
    }

    private func batchRow(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 11) {
            LyricsManagerCover(url: summary.coverURL, image: summary.key == nowPlayingKey ? nowPlaying.artwork : nil,
                               size: 32, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(summary.shownArtist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if summary.isManual {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                    .help(L10n.t("已人工修正"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// 侧栏「⋯」菜单里的东西:自动匹配缺失的歌词,占用与清理,从自动备份恢复。
    @ViewBuilder
    private var libraryMenu: some View {
        autoMatchMenuSections
        storageMenuSections
    }

    /// 「自动匹配缺失歌词」:让引擎现在就把没歌词的存量条目重新匹配一遍,不用等每首歌各自再被播到(补空路径设计上
    /// 只在重播时触发,见 lyrimuse-engine/lyricsfillsweep.go 头注)。两个入口:全库、或当前筛选出来的那批(只在筛选
    /// 真的缩小了范围时才出现,免得两个数字一样的项并排);另一节是「全量重新扫库…」。跑着的时候这里是这一轮的详情和
    /// 「停止」——一次只允许一轮;侧栏底部那张进度卡说的是同一轮。
    /// 上一轮的结果留在菜单里当收据:搜了几首、找到几首,不然点完只看到列表里几行悄悄变了。
    @ViewBuilder
    private var autoMatchMenuSections: some View {
        let status = fillSweepStatus
        let running = status?.running == true
        let retryableAll = retryableAllKeys
        let retryableVisible = retryableVisibleKeys
        // 菜单照 macOS 菜单的写法:菜单项是动作(动词开头,弹确认框的带「…」),状态是菜单顶上 / 底下
        // 各一两行灰字(Time Machine 那种「最近备份：…」),规则说明放进悬停提示和确认框,不占菜单行。
        if let status, running {
            // 这一轮**不一定**是自动匹配:「全量重新扫库」复用同一条通道(状态文件、
            // 单轮互斥、取消都共用,见 lyrimuse-engine/lyricsfullscan.go 头注),所以文案都得
            // 按 isFullScan 分流。
            let isFull = status.isFullScan
            // 顶上是此刻在做什么(标题)+ 进度与结果分布 + 大约还要多久;文字跟设置页那两行的进度详情共用
            // (FillSweepProgressText)。
            Section {
                ForEach(FillSweepProgressText.lines(status, fallbackSecondsPerTrack: isFull
                        ? fullScanFallbackSecondsPerTrack : FillSweepProgressText.fillFallbackSecondsPerTrack),
                        id: \.self) { Text($0) }
            } header: {
                Text(FillSweepProgressText.title(status))
            }
            // 最近几首:结果只用图标说,行里只放「歌名 — 歌手」。
            if let recent = status.recent, !recent.isEmpty {
                Section {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, item in
                        Label(LyricsFillSweep.displayName(key: item.key),
                              systemImage: FillSweepProgressText.recentSymbol(item, isFullScan: isFull))
                    }
                } header: {
                    Text(L10n.t("最近完成"))
                }
            }
            Section {
                Button(role: .destructive) {
                    LyricsFillSweep.requestCancel()
                } label: {
                    Label(isFull ? L10n.t("停止扫库") : L10n.t("停止自动匹配"),
                          systemImage: "stop.circle")
                }
            }
        } else {
            // 窄档:只搜没词的。数量写进动作里(「自动匹配 165 首缺失的歌词」)。规则(逐首、间隔、跳过哪些)放悬停提示;
            // 这里点出来的是手动那一轮,间隔是引擎的 lyricsManualSweepGap,改那边记得改提示。
            Section {
                Button {
                    if LyricsFillSweep.request(keys: []) { fillSweepPending = true; fillSweepPendingIsFull = false }
                } label: {
                    Label(String(format: L10n.t("自动匹配 %@ 首缺失的歌词"), "\(retryableAll.count)"),
                          systemImage: "wand.and.stars")
                }
                .disabled(retryableAll.isEmpty || fillSweepPending)
                .help(L10n.t("逐首联网搜索，每首间隔约 5 秒；跳过纯音乐和人工修正过的歌曲"))
                // 只靠搜索框缩小范围也算(hasActiveFilters 不含关键词)。
                if (hasActiveFilters || !committedSearchText.isEmpty) && retryableVisible.count != retryableAll.count {
                    Button {
                        if LyricsFillSweep.request(keys: retryableVisible) { fillSweepPending = true; fillSweepPendingIsFull = false }
                    } label: {
                        Label(String(format: L10n.t("仅自动匹配筛选出的 %@ 首"), "\(retryableVisible.count)"),
                              systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .disabled(retryableVisible.isEmpty || fillSweepPending)
                    .help(L10n.t("逐首联网搜索，每首间隔约 5 秒；跳过纯音乐和人工修正过的歌曲"))
                }
            }
            // 宽档:连已有歌词的也重新选一遍(设置页「歌词库」那一行的同一个入口)。弹确认框,所以带「…」;
            // 范围说明、待扫首数和预计时长都在确认框里。引擎还没数过待扫首数时不给这个入口(同设置页那一行)。
            if fullScanState?.pending != nil {
                Section {
                    Button {
                        confirmFullScan = true
                    } label: {
                        Label(L10n.t("全量重新扫库…"), systemImage: "arrow.clockwise")
                    }
                    .disabled(fillSweepPending)
                    .help(L10n.t("已有歌词的歌曲也会重新匹配；人工修正、已校准时间轴和纯音乐的歌曲除外"))
                }
            }
            // 上一轮自动匹配的收据,一行灰字。全量扫库那一轮的收据不在这里给:两轮共用同一份状态文件,而全量的
            // done/filled 是整场累计的几千首,放在这里会被读成自动匹配搜了几千首(设置页那一行同一道判断)。
            // 一首都没搜的那一轮也不给,除非是断网停下的 —— 那时要说清楚为什么停。
            if let status, status.finishedAt != nil, !status.isFullScan,
               status.done > 0 || status.isOffline {
                Section {
                    Text(String(format: L10n.t("上次自动匹配 %1$@ 首，找到 %2$@ 首"), "\(status.done)", "\(status.filled)"))
                    // 停下的两种情形另说一句,免得"搜了 12 首"被当成全部。
                    if status.isOffline {
                        Text(L10n.t("因网络不可用已停止"))
                    } else if status.cancelled == true {
                        Text(L10n.t("已手动停止"))
                    }
                }
            }
        }
    }

    /// 占用与清理:清空全部缓存、清空时间轴校正(单曲 / 电台两层),以及清空或批量删除之前自动打的快照。
    @ViewBuilder
    private var storageMenuSections: some View {
        // 「共 N 条，占用 X」紧贴着「清空全部缓存」这个不可撤销的操作,让人在点下去之前先看清自己要删掉多少东西。
        Section {
            let cleanup = cleanupKeys
            Button {
                pendingCleanupKeys = cleanup
                showCleanupConfirm = true
            } label: {
                Label(cleanup.isEmpty ? L10n.t("没有无效记录")
                                      : String(format: L10n.t("清理 %@ 条无效记录…"), cleanup.count.formatted()),
                      systemImage: "sparkles")
            }
            .disabled(cleanup.isEmpty)
            Button(role: .destructive) {
                showClearAllConfirm = true
            } label: {
                Label(L10n.t("清空全部缓存"), systemImage: "trash")
            }
        } header: {
            Text(String(format: L10n.t("共 %d 条，占用 %@"),
                        store.summaries.count, cacheSizeText))
        }
        // 时间轴校正值单独一段、单独一个清空入口:它跟歌词内容存在两个完全不同的地方
        // (UserDefaults vs 缓存 JSON + lyrics/ 文件夹),清哪一个都不该连带另一个。
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
        // 电台那一层再单独一段:上面修的是"这份歌词自己的时间轴不准",这里修的是"电台的元数据比
        // 声音晚"(见 LyricsOffsetStore.radioOffsets)。整段只在真的调过时才出现。
        if offsets.radioOffsetCount > 0 {
            Section {
                Button(role: .destructive) {
                    showClearRadioOffsetsConfirm = true
                } label: {
                    Label(L10n.t("清空全部电台校正"), systemImage: "dot.radiowaves.left.and.right")
                }
            } header: {
                Text(String(format: L10n.t("已校正 %d 首歌在电台上的时间轴"),
                            offsets.radioOffsetCount))
            }
        }
        // 清空/批量删除之前自动打的快照,就地给一个恢复入口:必须在**同一个菜单**里,这两个不可撤销的按钮就在
        // 上面两段,手滑之后第一反应是回到刚才点错的地方找后悔药。列表现读、不缓存:刚打的那份必须立刻出现在这里。
        let snapshots = LyricsBackupStore.autoSnapshots()
        if !snapshots.isEmpty {
            Section {
                ForEach(snapshots) { snapshot in
                    Button {
                        pendingRestoreSnapshot = snapshot
                        showRestoreSnapshotConfirm = true
                    } label: {
                        // 纯排版,不进 L10n —— 两侧都是已本地化好的片段(DateFormatter / ByteCountFormatter)。
                        Label("\(Self.snapshotDateText(snapshot.date))（\(Self.byteText(snapshot.bytes))）",
                              systemImage: "clock.arrow.circlepath")
                    }
                }
            } header: {
                Text(L10n.t("从自动备份恢复"))
            }
        }
    }

    /// 全量扫库还没跑完一首时估剩余时长用的每首秒数(引擎发布的值,没有时是设置页同一个兜底)。
    private var fullScanFallbackSecondsPerTrack: Double {
        LyricsLibraryStatsPanel.fullScanSecondsPerTrack(fullScanState)
    }

    /// 「全量重新扫库？」确认框正文。首数是引擎数好发布的(`LyricsFullScan.State.pending`)。
    private var fullScanConfirmMessage: String {
        guard let state = fullScanState else { return "" }
        return LyricsLibraryStatsPanel.fullScanConfirmMessage(
            pending: state.pending ?? 0, secondsPerTrack: LyricsLibraryStatsPanel.fullScanSecondsPerTrack(state))
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
        // 跟界面语言走(设置里可以单独选),不跟系统区域。
        formatter.locale = L10n.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func byteText(_ bytes: Int) -> String {
        EnrichCacheStore.byteText(Int64(bytes))
    }

    // 补/收「正在搜索歌词」占位行。根因是这个列表的数据源(EnrichCacheStore.summaries)
    // 完全来自引擎写的缓存文件——引擎联网搜索期间什么都不往文件里写(只保留
    // "搜到结果"的那次落盘,见 lyrimuse-engine/enrich.go 的守卫),所以搜索还没出结论这段窗口期,
    // 这首歌在缓存文件里压根不存在,不是"存在但没显示"。
    //
    // 修法是在 Swift 侧合成一条**不落盘、不进 raw**的临时行,只在这个视图内部存在,展示层
    // 尽量复用现有的 Summary/筛选/排序管线(而不是另起一套"占位行专用渲染"),这样它天然
    // 能被搜索框/筛选/排序接住,也天然会被「定位」找到——见下面几处对
    // `placeholderSummary` 的接线点。**不**在引擎侧提前写占位:那会把"只保留有结果
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
        // 缓存里已经有真实条目了(引擎搜完了,不管搜到没搜到)——占位行让位,
        // 真实那一行会随下一次 summaries 重建自然出现在列表里。
        guard !store.hasEntry(forKey: key) else {
            if placeholderSummary?.key == key { placeholderSummary = nil }
            return
        }
        // 已经是同一首歌的占位行,不用重新构造一份新实例(纯避免无意义的 diff)。
        guard placeholderSummary?.key != key else { return }
        let display = playback.artist
        let displayAlbum = LocalPlaybackSource.albumOrListed(album: playback.album, youtubeMusicAlbum: playback.youtubeMusicAlbum)
        placeholderSummary = EnrichCacheStore.Summary(
            key: key,
            artist: playback.artist,
            canonicalArtist: "",
            inferredArtist: "",
            durationSecs: Double(playback.currentDurationMs ?? 0) / 1000,
            title: playback.title,
            album: playback.album,
            displayAlbum: displayAlbum,
            isListedMV: false,
            coverURL: nil,
            lyricsSource: "",
            hasWordTiming: false,
            isManual: false,
            sourceChoice: "",
            lyricsTrSource: "",
            hasTranslation: false,
            hasRomanization: false,
            hasLyrics: false,
            isInstrumental: false,
            hasPlainTextFallback: false,
            knownOnSources: false,
            // 占位行还没有任何一轮解析,谈不上"几个源应答过",也谈不上"这一轮没人应答"
            // (它正在搜,isSearching 那一档会先接住它)。
            lastRoundHadNoResponder: false,
            sourcesRespondedCount: 0,
            isSearching: true,
            hasDecision: false,
            // 这一行是「正在搜索这首歌的歌词」占位,磁盘上还没有它的歌词文件,
            // 缓存里也还没有这个 key(所以也没有 ts)。
            lyricsUpdatedAt: nil,
            resolvedAt: nil,
            normPrimaryArtist: toSimplified(primaryArtist(display)).lowercased(),
            normAlbum: toSimplified(displayAlbum).lowercased(),
            searchArtistLower: playback.artist.lowercased(),
            searchDisplayArtistLower: display.lowercased(),
            searchTitleLower: playback.title.lowercased(),
            searchAlbumLower: displayAlbum.lowercased()
        )
    }

    // 选中当前正在播放的这首歌(如果它已经被缓存过),scroll 时再把列表滚过去——开窗、窗口开着期间换歌只选中
    // (见 pendingAutoFocus、trackSignature 那条),侧栏「正在播放」那一行的「定位」才滚动。key 跟
    // EnrichCacheStore.splitKey 用的是同一套 "歌手|歌名|专辑" 拼法,PlaybackCoordinator
    // 转发的 artist/title/album 本来就来自 media-control/relay,跟引擎当初写入
    // 缓存时用的是同一份数据,能精确对上。找不到对应缓存条目时静默不做任何事,不弹提示——
    // 开窗自动定位场景本来就不该弹,手动点按钮那次真找不到时用户自己也看得出列表没跳。
    //
    // 只在这里读一次 PlaybackCoordinator.shared 的当前值,不声明成 @ObservedObject——
    // 那个单例还同时发布 currentLine/anchor,播放中每秒 20 次刷新(本地模式的快速
    // 计时器),整个窗口订阅它会导致 body 跟着每秒重算 20 次,把手动点选/刷新按钮的
    // 交互闷在这阵持续重渲染里,表现成"点了跟没点一样"。这里只需要调用那一刻的快照,
    // 普通函数内直接访问单例属性即可,不用建立订阅。
    private func focusCurrentlyPlaying(scrollProxy: ScrollViewProxy, scroll: Bool = true) {
        let playback = PlaybackCoordinator.shared
        // key 必须走 EnrichCacheKeys.normalizedKey —— 那是缓存 key 在 Swift 侧的**唯一
        // 构造点**(逐字节镜像引擎的 enrichKey)。手拼 "artist|title|album" 会漏掉
        // 两道清洗:cleanTag(各类空格/零宽字符)和 normalizedTitle(循环剥结尾括号里的副题)。
        //
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
        // 缓存里的 key 是**当初写进去那一刻**播放器报的原样,而播放器报的大小写/空格
        // 会漂(如 `Prince` 可能今天报成 `PRINCE`)。精确比较落空,而且这个函数**找不到就
        // 静默返回**,看起来就像这首歌根本没被缓存过——悬浮窗和引擎都有同一道兜底,
        // 这里缺了只影响歌词管理这一处。
        let candidates = normalizedKey == rawKey ? [normalizedKey] : [normalizedKey, rawKey]
        let key: String
        // 「正在搜索」占位行也要能被定位到——它此刻就是这首歌在列表里**唯一**存在的样子,
        // 见 refreshPlaceholder() 的注释。占位行的 key 恒等于 normalizedKey,直接判等即可。
        if let exact = candidates.first(where: { candidate in
            store.summaries.contains(where: { $0.key == candidate }) || placeholderSummary?.key == candidate
        }) {
            key = exact
        } else {
            guard let match = candidates.lazy.compactMap({ store.key(matchingLoose: $0) }).first else { return }
            key = match
        }
        // 整体替换成这一条、不是追加:「定位」的语义是聚焦到这首歌。追加的话用户点完
        // 之后 ⌘⌫ 删的还是之前选的一堆,极易误删。
        selectedKeys = [key]
        guard scroll else { return }
        centerListRow(key, scrollProxy: scrollProxy)
    }

    /// 把选中的那一首滚到列表中间;多选时取当前顺序里排在最前的那一首。没选中、或者选中的不在当前列表里就不动。
    private func revealSelection(scrollProxy: ScrollViewProxy) {
        guard !selectedKeys.isEmpty,
              let key = sortedFiltered.first(where: { selectedKeys.contains($0.key) })?.key else { return }
        centerListRow(key, scrollProxy: scrollProxy)
    }

    /// 把这一行滚到列表中间。补一发校正:List 的行高是懒量的,没被滚到过的行一直按估算高度算。列表几千条、目标又在视口外
    /// 老远时,一次 scrollTo 按估算落点走,停下来的位置差着一截;等这一轮布局按真实行高走完之后再定一次位。0.35s 比默认
    /// 动画略长,让第一发滚完再校正;校正给一个很短的动画,已经居中时是空操作。
    private func centerListRow(_ key: String, scrollProxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation { scrollProxy.scrollTo(key, anchor: .center) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeOut(duration: 0.12)) {
                    scrollProxy.scrollTo(key, anchor: .center)
                }
            }
        }
    }

    // 「正在搜索」占位行的详情——只读,不带任何编辑/删除/重新自动匹配按钮:这些操作全部
    // 直接读写 raw[key],喂一个不存在的 key 进去没有意义。等引擎写完缓存、下一次
    // reload 把这一行换成真实条目之后,点开就是正常的 detailView,不需要用户做任何事。
    //
    // 「停止搜索」按钮:这段等待没有上限(见 cancelPlaceholderSearch 的注释),没有这颗
    // 按钮用户只能干等。
    private func placeholderDetailView(_ summary: EnrichCacheStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 52)
                .background(WindowDragHandle())
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)
                Text(summary.artist)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !summary.displayAlbum.isEmpty {
                    Text(summary.displayAlbum)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            ContentUnavailableView {
                Label(L10n.t("正在搜索歌词…"), systemImage: "magnifyingglass")
            } description: {
                Text(L10n.t("首次播放，正在联网搜索歌词，完成后将自动显示"))
            } actions: {
                Button(L10n.t("停止搜索")) { cancelPlaceholderSearch() }
                    .settingsGlassButtons()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.leading, 30)
        .padding(.trailing, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 通知引擎"别再等这首歌的搜索结果了"。
    ///
    /// "搜索歌词中…"的等待**没有总上限**——
    /// `resolveTrackEnrichment` 内部歌词那一步有 20s 兜底,但整个函数(还跟着
    /// MusicBrainz/Apple Music/QQ 兜底封面这几步顺序网络请求)没有总超时,某一步卡住时
    /// 占位行会一直挂着,用户没有任何退出方式。
    ///
    /// 机制:写一个纯文本文件到引擎的配置目录,里面就是这首歌的缓存 key——引擎
    /// 有一个专门的后台 ticker(见 enrichcancel.go)按固定间隔检查这个文件,读到 key 就去
    /// `context.CancelFunc` 登记表里找,找到就调用,真正让还在飞的网络请求中断(不是"隔着
    /// 进程装个样子")。检查间隔意味着**不是瞬时生效**,但比完全没有退出方式好得多。
    ///
    /// App 侧不主动清空占位行,等引擎真正写完再让位:引擎现在的取消分支
    /// (`resolveEnrichAsync` 里 `ctx.Err() != nil` 那支)不再是"什么都不写",而是跟"自然
    /// 查无"走同一条落盘路径,把这一轮标记成"暂无歌词"永久写回缓存(要求:点了停止搜索,
    /// 记录不该直接消失,应该保留、标成无歌词,灵动岛/悬浮歌词也
    /// 不该继续显示搜索中)。既然缓存那边真的会有一条新记录,这里就不能再乐观地把
    /// `placeholderSummary` 清空——那样只会让这一行凭空消失,而下面 `.task` 里那个 5 秒
    /// 轮询是靠 `placeholderSummary != nil` 才会继续去问磁盘的(见那段注释),清空之后反而
    /// 没人再检查,除非用户碰巧做了别的触发 reload 的操作(换歌/重开窗口)。写完取消信号
    /// 什么都不做就够了:引擎落盘之后,现成的 5 秒轮询会自然探测到
    /// `store.hasEntry(forKey:)` 变 true,`refreshPlaceholder()` 里已有的"真实条目出现就
    /// 让位"逻辑会把这一行接手过去,变成一条正常的、标着"无歌词"的记录——不需要在这里
    /// 加任何新状态。灵动岛/桌面悬浮歌词走的是完全独立的一套刷新节奏(`LocalPlaybackSource`
    /// 的 2 秒轮询,靠 enrich 缓存文件 mtime 变化触发重读),不依赖这个窗口开不开,引擎
    /// 落盘之后它们会各自在下一拍自动从"搜索歌词中…"切到"暂无歌词",不需要额外接线。
    private func cancelPlaceholderSearch() {
        guard let key = placeholderSummary?.key else { return }
        let url = LyrimusePaths.configFile("lyrimuse-enrich-cancel-request.txt")
        try? key.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 详情

    /// 右边:单曲详情、搜索中的占位、多选的批量面板,或者什么都没选时的空状态。
    @ViewBuilder
    private var detailColumn: some View {
        Group {
            if let key = singleSelectedKey, let summary = store.summary(forKey: key) {
                detailView(key: key, summary: summary)
            } else if let placeholder = placeholderSummary, singleSelectedKey == placeholder.key {
                // 占位行没有对应的 raw 条目,不能走 detailView 那整套编辑/删除/重新自动匹配——
                // 那些操作全部直接读写 raw[key]。等引擎写完缓存,下一次 reload 会让这一行自然变成真的一行。
                placeholderDetailView(placeholder)
            } else if selectedKeys.count > 1 {
                batchSelectionPanel
            } else {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 52)
                        .background(WindowDragHandle())
                    ContentUnavailableView(L10n.t("从左侧选择一首歌曲"), systemImage: "text.quote")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // 跟侧栏的「清空全部缓存」、List 上的「删除」、根上那几个确认框分处不同层级,不叠在同一条修饰符链上。
        .confirmationDialog(
            L10n.t("要放弃对歌词的修改吗？"),
            isPresented: $showDiscardEditConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("放弃修改"), role: .destructive) { discardEdits() }
            Button(L10n.t("继续编辑"), role: .cancel) {}
        }
        .alert(unsavedEditTitle, isPresented: $showUnsavedEditAlert) {
            Button(L10n.t("保存")) { saveThenSwitch() }
            Button(L10n.t("不保存"), role: .destructive) {
                let next = pendingSelection
                pendingSelection = nil
                discardEdits()
                if let next { selectedKeys = next }
            }
            Button(L10n.t("取消"), role: .cancel) { pendingSelection = nil }
        } message: {
            Text(L10n.t("切换到其他歌曲前是否保存修改？"))
        }
    }

    private var unsavedEditTitle: String {
        let title = editingKey.flatMap { store.summary(forKey: $0) }?.title ?? ""
        return String(format: L10n.t("「%@」有未保存的修改"), title)
    }

    private func saveThenSwitch() {
        let next = pendingSelection
        pendingSelection = nil
        guard let key = editingKey, let summary = store.summary(forKey: key) else { return }
        Task {
            guard await saveEdits(key: key, summary: summary) else { return }
            endEditing()
            if let next { selectedKeys = next }
        }
    }

    @ViewBuilder
    private func detailView(key: String, summary: EnrichCacheStore.Summary) -> some View {
        songPage(key: key, summary: summary)
            .onAppear { loadDetail(key: key) }
            // 引擎期间改了这首(补了机翻、重新打分换了词、别处采纳了候选):用户没动过编辑缓冲就跟着换成盘上的新内容,
            // 免得看着旧的、存的时候又拿旧的比。动过就不碰,保存时再按格合并(见 saveEdits)。
            // 正文读不回来的那首不跟:每次重读都要在主线程上把整份主缓存再解一遍去碰运气,重新选中它再试。
            .onChange(of: store.summariesGeneration) { _, _ in
                if editingKey == key, !isEditorDirty, !detailIncomplete { loadDetail(key: key) }
            }
            .onChange(of: key) { _, newKey in
                store.dismissEditError()
                endEditing()
                loadDetail(key: newKey)
                // 换歌就把上一首的进行中/结果状态收掉,并叫引擎停掉那一轮(它的结果已经没人要了)。
                // rematchGeneration 换代顺带让在飞的那一轮的轮询和收尾全部失效。
                if rematchRunningKey != nil {
                    rematchGeneration += 1
                    rematchRunningKey = nil
                    if let id = rematchRequestID { LyricsRematch.cancel(id: id) }
                }
                rematchResult = nil
            }
            // 编辑用的正文 ↔ 完整原文,四对两条 onChange 互不打圈,理由见 LyricsBodyEdit 头注:外部写进来的完整原文
            // (换曲 / 采纳候选 / 重新匹配)才重算正文;正文拼回去的那次(值恰好等于 reassembled)跳过,不然用户敲的
            // 回车会被归一化吃掉。
            .onChange(of: editedLyrics, initial: true) { _, raw in
                if raw == lyricsBodyEdit.reassembled(body: editedLyricsBody) { return }
                lyricsBodyEdit = LyricsBodyEdit(lyrics: raw, title: summary.title, artist: summary.artist)
                editedLyricsBody = lyricsBodyEdit.body
            }
            .onChange(of: editedLyricsBody) { _, newBody in
                let full = lyricsBodyEdit.reassembled(body: newBody)
                if full != editedLyrics { editedLyrics = full }
            }
            .onChange(of: editedWordText, initial: true) { _, raw in
                if raw == wordBodyEdit.reassembled(body: editedWordBody) { return }
                wordBodyEdit = LyricsBodyEdit(lyrics: raw, title: summary.title, artist: summary.artist)
                editedWordBody = wordBodyEdit.body
            }
            .onChange(of: editedWordBody) { _, newBody in
                let full = wordBodyEdit.reassembled(body: newBody)
                if full != editedWordText { editedWordText = full }
            }
            .onChange(of: editedTr, initial: true) { _, raw in
                if raw == trBodyEdit.reassembled(body: editedTrBody) { return }
                trBodyEdit = LyricsBodyEdit(lyrics: raw, title: summary.title, artist: summary.artist)
                editedTrBody = trBodyEdit.body
            }
            .onChange(of: editedTrBody) { _, newBody in
                let full = trBodyEdit.reassembled(body: newBody)
                if full != editedTr { editedTr = full }
            }
            .onChange(of: editedRoma, initial: true) { _, raw in
                if raw == romaBodyEdit.reassembled(body: editedRomaBody) { return }
                romaBodyEdit = LyricsBodyEdit(lyrics: raw, title: summary.title, artist: summary.artist)
                editedRomaBody = romaBodyEdit.body
            }
            .onChange(of: editedRomaBody) { _, newBody in
                let full = romaBodyEdit.reassembled(body: newBody)
                if full != editedRoma { editedRoma = full }
            }
            .sheet(isPresented: $showDecisionSheet) {
                // 按钮只在 hasDecision 时出现;完整结构懒解码 —— 只在打开弹窗这一刻按 key
                // 解(原来 rebuild 时全量急算,见 Summary.hasDecision 注释)。
                // 两槽都解:latest=最近一次评估,applied=当前歌词的出处(分槽语义见
                // lyrimuse-engine/decision.go;老条目只有前者,弹窗 init 里自己退化)。
                let latest = store.decodedDecision(for: key)
                let applied = store.decodedAppliedDecision(for: key)
                if latest != nil || applied != nil {
                    LyricsDecisionSheet(summary: summary, latest: latest, applied: applied)
                }
            }
            .sheet(item: $searchTarget) { target in
                // 采纳候选直接保存,不需要再手动点"保存修改"——避免让人误以为选了就已经
                // 存上了,结果只是填进了编辑框,还得再点一下保存才真正落盘。下面的 key 是面板为之打开的那一首。
                let key = target.key
                let live = store.summary(forKey: key)
                LyricsSearchSheet(
                    artist: target.artist, title: target.title, album: target.album,
                    currentSource: live?.lyricsSource,
                    // 「当前使用」双判据要的正文指纹。store.raw 是私有的,跟另外两个入口一样走
                    // EnrichCacheReader.lookup(store 刚 persist 过的就是这份文件),三处口径一致。
                    currentFingerprint: EnrichCacheReader.lookup(artist: target.artist, title: target.title, album: target.keyAlbum)
                        .map { ManualPickLock.fingerprint(lyrics: $0.lyrics) }.flatMap { $0.isEmpty ? nil : $0 },
                    durationSecs: target.durationSecs,
                    isMarkedInstrumental: live?.isInstrumental ?? false,
                    onSetInstrumental: { value in await store.setInstrumental(key: key, value) },
                    onAutoMatch: { progress in
                        // 跟详情页「重新自动匹配」同一条路、同一个收尾:列表重读,换了词换掉编辑框,结论挂在详情页那一行
                        // (面板换了词会关掉,关掉之后看得到)。
                        guard let line = await LyricsRematchRunner.run(key: key, onProgress: progress) else { return nil }
                        await store.reload(onlyIfChanged: true)
                        finishRematch(key: key, line: line)
                        return line
                    }
                ) { candidate in
                    // 仅纯文本的候选走完全独立的一条路——不写 editedLyrics/
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
                    if editingKey == key {
                        editedLyrics = candidate.lyrics
                        editedTr = candidate.lyricsTr
                        editedRoma = candidate.lyricsRoma
                    }
                    // 「采纳候选」要不要顺带冻结这首歌,由 `manualPickLocksLyrics` 决定 ——
                    // 而**两种状态都不写** lyrics_source_choice(空串 = 显式清掉)。
                    //
                    // 这里曾有第三态:开关关着时记下"选了哪个源",自愈路径照常跑
                    // 但被约束在该源内(引擎侧 pickLyricCandidatePreferring)。当时的想法
                    // 是把"我手改过正文"和"我不同意这次选源"拆成强弱两级约束。
                    //
                    // 用户看到设置里写出来的说明后当场否掉了这个中间态:他要的
                    // 两态是「关 = 之后所有自动更新/优化照常调整这首歌,**不限制源**;
                    // 开 = 就定在这份歌词上不动」。中间那档除了不是他想要的,本身也讲不清楚
                    // —— 它是一个看不见的约束,只能靠歌词管理里事后一枚 pin 徽章解释"为什么
                    // 这首歌一直是这个源"。于是关态改成什么痕迹都不留;存量缓存里那 6 条
                    // lyrics_source_choice 也一并清掉了(清理记录见 docs/features/11)。
                    //
                    // 直接编辑正文那条路径(「保存修改」)**永远**置 manual_lyrics,不受这个
                    // 开关影响——那份内容删了就找不回来,自动逻辑没有任何理由觉得自己比人工更懂。
                    let saved = await store.saveEdit(key: key, lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                                                     roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                                                     source: candidate.source, markManual: AppSettings.shared.manualPickLocksLyrics,
                                                     sourceChoice: "", fromManualPick: true, bg: candidate.lyricsBG, trLang: candidate.lyricsTrLang)
                    guard saved else {
                        // 没存上:编辑框和偏移退回盘上那份。留着候选的话,下一次 ⌘S 会把它当手改存进去并锁定。
                        // 这期间切到了别的歌就不动 —— 编辑框已经是那一首的了。
                        if editingKey == key { loadDetail(key: key) }
                        return false
                    }
                    // 采纳的候选歌词内容跟原来不一样,offset 的 key(内容指纹)也跟着变——输入框要显示"新内容对应的
                    // 偏移值"。按盘上刚落下的那份重载(不再算未保存);这期间切到了别的歌就不动。
                    if editingKey == key { loadDetail(key: key) }
                    // 补上——采纳候选之前点了就直接关闭弹窗,真正的保存+重启
                    // 引擎在后台异步跑,用户看不到任何进度,失败时只能在下面
                    // store.lastError 那行小字里发现。复用"保存修改"同一个反馈机制:
                    // 成功就闪一下"已保存",失败不闪(已经有 lastError 的红字提示,不需要
                    // 叠加两套反馈互相矛盾)。
                    flashSaveEditFeedback()
                    return true
                }
            }
    }

    /// 采纳候选成功后闪一下「已保存」—— 跟「保存修改」同一个反馈机制(showSaveEditFeedback)。
    /// 抽出来是因为 onApply 从要**等保存结束再回报成败**(面板据此决定关不关窗、
    /// 挪不挪「当前使用」徽标),这 1 秒的收尾不能再挂在同一个 Task 里阻塞回报。
    private func flashSaveEditFeedback() {
        Task {
            withAnimation { showSaveEditFeedback = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showSaveEditFeedback = false }
        }
    }
    /// 一首歌的详情页:头部铺封面氛围,下面是概况,再往下按这首的情况是预览 / 编辑、缺歌词的说明、纯音乐或纯文本。
    private func songPage(key: String, summary: EnrichCacheStore.Summary) -> some View {
        ZStack(alignment: .top) {
            // 正在放的这首用播放器给的那张封面:随时都在,也比缓存里的缩略图清楚。
            LyricsManagerAmbience(url: summary.coverURL, image: summary.key == nowPlayingKey ? nowPlaying.artwork : nil)
            VStack(alignment: .leading, spacing: 0) {
                detailTopBar(summary)
                headerBlock(summary)
                factsRow(summary)
                    .padding(.top, 16)
                // 故意不放进顶上那排按钮:一句长文案会把按钮排挤窄,转圈出现/消失也会让整排跳一下。
                if rematchRunningKey == key || rematchResult?.key == key {
                    rematchStatusRow(key: key, summary: summary)
                        .padding(.top, 10)
                }
                pageBody(key: key, summary: summary)
            }
            .padding(.leading, 30)
            .padding(.trailing, 22)
        }
        .overlay(alignment: .bottom) {
            if editMode != .preview {
                saveBar(key: key, summary: summary)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: editMode)
    }

    /// 右上角那排按钮。放不下时收成只有图标(悬停说明、无障碍标签照留)。背后垫拖拽区:这一行在标题栏那一截里。
    private func detailTopBar(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                topBarButtons(summary, iconOnly: false)
                topBarButtons(summary, iconOnly: true)
            }
        }
        .frame(height: 52)
        .background(WindowDragHandle())
    }

    private func topBarButtons(_ summary: EnrichCacheStore.Summary, iconOnly: Bool) -> some View {
        HStack(spacing: 8) {
            // 「重新自动匹配」——请引擎按自动解析那套规则重跑一轮、直接采用算法选出的那一份。文案刻意不写「智能」:
            // 那是设置页「匹配算法」的一个具体档位,真正的冠军由引擎按用户选的那一档算。编辑中、自动匹配在跑时点不了。
            Button {
                Task { await runRematch(key: summary.key) }
            } label: {
                topBarLabel(L10n.t("重新自动匹配"), icon: "wand.and.stars", iconOnly: iconOnly)
            }
            .disabled(rematchBlocked || editMode != .preview)
            .help(L10n.t("重新联网匹配，直接采用算法选出的结果，依据设置中的「匹配算法」"))
            // 自动匹配飞行途中不开这个弹窗:在弹窗里采纳的那份会让这一轮作废(引擎见到期间改过就不写)。
            Button {
                openSearchSheet(summary)
            } label: {
                topBarLabel(L10n.t("搜索候选歌词"), icon: "magnifyingglass", iconOnly: iconOnly)
            }
            .disabled(rematchRunningKey != nil || editMode != .preview)
            .help(L10n.t("联网搜索候选歌词"))
            // 「解析决策」只在有存档时才出现(老条目没有)。
            if summary.hasDecision {
                Button {
                    showDecisionSheet = true
                } label: {
                    topBarLabel(L10n.t("解析决策"), icon: "list.number", iconOnly: iconOnly)
                }
                .help(L10n.t("查看选用这份歌词的依据：当时的候选、得分与淘汰原因"))
            }
            moreMenuButton(summary)
        }
        .settingsGlassButtons()
        .fixedSize()
    }

    /// 右上角「⋯」,跟旁边的玻璃按钮同高同样式(见 11 章决策 68)。
    private func moreMenuButton(_ summary: EnrichCacheStore.Summary) -> some View {
        Menu {
            detailMoreMenu(summary)
        } label: {
            Text(Image(systemName: "ellipsis"))
        }
        .menuIndicator(.hidden)
        .settingsGlassMenu()
        .accessibilityLabel(L10n.t("更多"))
        .help(L10n.t("更多"))
    }

    @ViewBuilder
    private func topBarLabel(_ title: String, icon: String, iconOnly: Bool) -> some View {
        if iconOnly {
            Image(systemName: icon)
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: icon)
        }
    }

    /// 「⋯」:标 / 撤纯音乐、拷贝歌名与歌手、以文本方式编辑、用外部编辑器改、在访达中显示,删除。
    @ViewBuilder
    private func detailMoreMenu(_ summary: EnrichCacheStore.Summary) -> some View {
        // 「标为纯音乐」/「取消纯音乐标记」:有没有歌词都能标。标上之后各处不显示歌词,引擎也不再自动搜;
        // 歌词留在条目里,撤掉就回来(见 EnrichCacheStore.setInstrumental)。搜索候选歌词面板标题栏有同一对动作。
        if summary.isInstrumental {
            Button(L10n.t("取消纯音乐标记")) { Task { await store.setInstrumental(key: summary.key, false) } }
                .help(L10n.t("取消「纯音乐」标记：已有歌词的恢复显示，没有歌词的重新加入自动匹配队列"))
        } else {
            Button(L10n.t("标为纯音乐")) { Task { await store.setInstrumental(key: summary.key, true) } }
                .help(L10n.t("按纯音乐处理：不再显示歌词，也不再自动搜索；现有歌词会保留，取消标记后恢复"))
        }
        Button(L10n.t("拷贝歌名与歌手")) { copySongName(summary) }
        if summary.hasLyrics && !summary.isInstrumental {
            Divider()
            Button(L10n.t("以文本方式编辑")) { beginTextEditing() }
                .disabled(!(canEditLyrics || editMode == .lines))
            Button(L10n.t("在外部编辑器中编辑歌词")) {
                LyricsExternalEditor.shared.open(artist: summary.artist, title: summary.title, album: summary.album)
            }
            Button(L10n.t("在访达中显示歌词文件")) { revealLyricsFile(summary.key) }
        }
        Divider()
        Button(L10n.t("删除本地记录…"), role: .destructive) { requestDelete([summary.key]) }
    }

    /// 封面 + 歌名 / 歌手 / 专辑 + 一排标签。
    private func headerBlock(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(alignment: .top, spacing: 20) {
            LyricsManagerCover(url: summary.coverURL, image: summary.key == nowPlayingKey ? nowPlaying.artwork : nil,
                               size: 128, radius: 14)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(summary.shownArtist.isEmpty ? L10n.t("未知歌手") : summary.shownArtist)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(summary.artist.isEmpty && !summary.inferredArtist.isEmpty ? L10n.t("播放器未提供歌手，按歌名和时长推断") : "")
                if !summary.displayAlbum.isEmpty || summary.isListedMV {
                    Text(summary.isListedMV ? L10n.t("MV") : albumDisplay(summary.displayAlbum))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                headerTags(summary)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }

    /// 正在播放、来源、逐字 / 整行、译文、读音、人工修正、已校准,没词的那几档。来源用全局那份 sourceColor,其余标签的颜色读
    /// LyricsFeatureTint,跟列表行、搜索候选歌词面板同一份(见 11 章决策 79)。
    private func headerTags(_ summary: EnrichCacheStore.Summary) -> some View {
        SettingsFlowRow(spacing: 6) {
            if summary.key == nowPlayingKey {
                LyricsManagerTag(icon: "waveform", text: L10n.t("正在播放"), tint: .accentColor)
            }
            if !summary.lyricsSource.isEmpty {
                LyricsManagerTag(icon: "arrow.down.circle", text: sourceDisplayName(summary.lyricsSource),
                                 tint: sourceColor(summary.lyricsSource))
            }
            // hasWordTiming 在"完全没有歌词"时也是 false,不加 hasLyrics 这道闸的话无歌词的条目会显示一个像真结论的「整行时间轴」。
            if summary.hasLyrics && !summary.isInstrumental {
                LyricsManagerTag(icon: summary.hasWordTiming ? "text.word.spacing" : "text.alignleft",
                                 text: summary.hasWordTiming ? L10n.t("逐字时间轴") : L10n.t("整行时间轴"),
                                 tint: summary.hasWordTiming ? LyricsFeatureTint.wordTiming : .secondary)
            }
            // 机翻的译文单独标出来,不让它冒充歌词源自带的社区翻译。
            if summary.hasTranslation {
                if summary.lyricsTrSource == LyricsTranslationSource.machineSentinel {
                    LyricsManagerTag(icon: "character.book.closed", text: L10n.t("机器翻译"), tint: LyricsFeatureTint.machineTranslation)
                } else {
                    LyricsManagerTag(icon: "character.book.closed", text: L10n.t("译文"), tint: LyricsFeatureTint.translation)
                }
            }
            if summary.hasRomanization {
                LyricsManagerTag(icon: "textformat.abc", text: L10n.t("读音"), tint: LyricsFeatureTint.romanization, latinIcon: true)
            }
            if summary.isManual {
                LyricsManagerTag(icon: "pencil.circle.fill", text: L10n.t("人工修正"), tint: LyricsFeatureTint.manual)
            }
            // 「来源已选定」:这个字段已经没有写入方,引擎每次启动都会把存量转成 manual_pick_sha;读取侧整套跟引擎一起删,
            // 在那之前照常显示。
            if !summary.sourceChoice.isEmpty {
                LyricsManagerTag(icon: "pin.circle.fill",
                                 text: String(format: L10n.t("来源已选定：%@"), sourceDisplayName(summary.sourceChoice)),
                                 tint: LyricsFeatureTint.sourceChoice)
            }
            // 「已校准」带一个看不见的副作用:引擎从此不再自动给这首歌重选歌词源(见 LyricsPinStore),必须显式标出来。
            if pins.isPinned(summary.key) {
                LyricsManagerTag(icon: "timer", text: L10n.t("已校准"), tint: LyricsFeatureTint.pinned)
            }
            // 标了纯音乐的条目存着歌词也显示「纯音乐」,跟列表行同一口径(各处按纯音乐显示,见 LyricsKind.instrumental)。
            if !summary.hasLyrics || summary.isInstrumental {
                if summary.isInstrumental {
                    LyricsManagerTag(icon: "waveform", text: L10n.t("纯音乐"))
                } else if summary.hasPlainTextFallback {
                    LyricsManagerTag(icon: "text.quote", text: L10n.t("仅纯文本"), tint: LyricsFeatureTint.plainTextOnly)
                } else if summary.lastRoundHadNoResponder {
                    LyricsManagerTag(icon: "antenna.radiowaves.left.and.right.slash", text: L10n.t("本轮无歌词源应答"))
                } else if summary.knownOnSources {
                    LyricsManagerTag(icon: "music.note", text: L10n.t("已收录、无歌词"))
                } else {
                    LyricsManagerTag(icon: "text.badge.xmark", text: L10n.t("无歌词"), tint: LyricsFeatureTint.noLyrics)
                }
            }
        }
    }

    /// 头部下面那行概况:时长、歌词更新时间(没词的写解析时间)、当初几个源应答选了谁(见 11 章决策 76)。
    private func factsRow(_ summary: EnrichCacheStore.Summary) -> some View {
        SettingsFlowRow(spacing: 18) {
            if summary.durationSecs > 0 {
                LyricsManagerFact(icon: "clock",
                                  text: String(format: L10n.t("时长 %@"), Self.durationText(summary.durationSecs)))
            }
            if let updated = summary.lyricsUpdatedAt {
                LyricsManagerFact(icon: "arrow.clockwise",
                                  text: String(format: L10n.t("歌词更新于 %@"), Self.dayText(updated)))
            } else if let resolved = summary.resolvedAt {
                LyricsManagerFact(icon: "calendar", text: String(format: L10n.t("上次解析于 %@"), Self.dayText(resolved)))
            }
            // 这个数为 0 是老条目没这个字段,不是"零个源应答",不显示。
            if summary.hasDecision, summary.hasLyrics, summary.sourcesRespondedCount > 0, !summary.lyricsSource.isEmpty {
                LyricsManagerFact(icon: "checkmark.seal",
                                  text: String(format: L10n.t("解析时 %1$@ 个源应答，选用「%2$@」"),
                                               "\(summary.sourcesRespondedCount)", sourceDisplayName(summary.lyricsSource)))
            }
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 「10 月 6 日」这种写法,不是今年的带上年份;跟界面语言走。
    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    /// 头部以下:有词的是控制行 + 预览 / 编辑;纯音乐、只有纯文本、缺歌词的各有一页说明。
    @ViewBuilder
    private func pageBody(key: String, summary: EnrichCacheStore.Summary) -> some View {
        if summary.isInstrumental {
            Divider().padding(.top, 18)
            instrumentalState(summary)
        } else if !summary.hasLyrics {
            Divider().padding(.top, 18)
            if summary.hasPlainTextFallback {
                plainTextState(summary)
            } else {
                missingState(summary)
            }
        } else {
            controlsRow(summary)
                .padding(.top, 16)
            notices(summary)
            Divider().padding(.top, 14)
            lyricsArea(summary)
        }
    }

    /// 时间轴偏移、原文 / 译文 / 读音、跟随播放,右边「编辑歌词」。放不下时左边那几样折行。
    private func controlsRow(_ summary: EnrichCacheStore.Summary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SettingsFlowRow(spacing: 10) {
                LyricsManagerOffsetControl(
                    text: $editedOffsetSeconds,
                    isNonZero: LyricsOffsetStore.shared.offset(forKey: currentOffsetKey(summary)) != 0,
                    stepText: AppSettings.formattedSeconds(ms: AppSettings.shared.lyricsOffsetStepMs),
                    onStep: { direction in nudgeOffset(summary, direction: direction) },
                    onSubmit: { applyOffsetEdit(summary) },
                    onReset: { resetOffsetEdit(summary) })
                    .disabled(editMode != .preview)
                LyricsManagerModePicker(mode: $displayMode,
                                        shown: effectiveDisplayMode(summary),
                                        isAvailable: { isDisplayModeAvailable($0, summary) },
                                        unavailableHelp: unavailableModeHelp)
                if summary.key == nowPlayingKey && editMode == .preview {
                    Button {
                        followPlayback.toggle()
                    } label: {
                        Label(L10n.t("跟随播放"), systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(followPlayback ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(followPlayback ? Color.accentColor : Color.secondary)
                    .help(L10n.t("高亮当前句并保持在可见范围内；手动滚动时暂停，再次点按可恢复"))
                }
            }
            Spacer(minLength: 8)
            if editMode == .preview {
                Button {
                    beginLineEditing()
                } label: {
                    Label(L10n.t("编辑歌词"), systemImage: "pencil")
                }
                .settingsGlassButtons()
                .disabled(!canEditLyrics)
                .fixedSize()
            } else {
                LyricsManagerTag(icon: "pencil", text: L10n.t("编辑中"), tint: .secondary)
            }
        }
    }

    /// 控制行下面几句要紧的话:已校准的后果、正文读不回来、写入失败、刚保存时逐字时间按字数分配了几句。
    @ViewBuilder
    private func notices(_ summary: EnrichCacheStore.Summary) -> some View {
        // 校准过之后行为会变,就在动手的地方说清楚 —— 别让用户事后去猜。
        if pins.isPinned(summary.key) {
            Text(L10n.t("已校准的歌曲不再自动更换歌词源，以免歌词变化后校正失效。将偏移设回 0 即可解除"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        if detailIncomplete {
            Label(L10n.t("无法读取这首歌曲的歌词内容（歌词文件缺失或损坏）。为避免覆盖磁盘上的内容，暂时无法保存修改。可通过「搜索候选歌词」重新采纳"),
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        if let error = store.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .padding(.top, 8)
        }
        if let saveEditNote {
            Text(saveEditNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func lyricsArea(_ summary: EnrichCacheStore.Summary) -> some View {
        switch editMode {
        case .preview:
            let nowPlayingThis = summary.key == nowPlayingKey
            LyricsManagerPreviewList(
                rows: shownRows(summary),
                mode: effectiveDisplayMode(summary),
                isNowPlaying: nowPlayingThis,
                follow: $followPlayback,
                canSeek: nowPlayingThis && PlaybackCoordinator.shared.acceptsSeek,
                onSeek: { seek(toLyricsMs: $0) })
            .id(summary.key)
        case .lines:
            lineEditor(summary)
        case .text:
            textEditors(summary)
        }
    }

    /// 这首有没有这一档:译文看有没有译文,读音看缓存里有没有、或者歌词里有没有设置里开着读音的那几种字。
    private func isDisplayModeAvailable(_ mode: LyricsManagerDisplayMode, _ summary: EnrichCacheStore.Summary) -> Bool {
        switch mode {
        case .original: return true
        case .translation: return summary.hasTranslation
        case .romanization: return romanizationAvailable
        }
    }

    private func unavailableModeHelp(_ mode: LyricsManagerDisplayMode) -> String {
        switch mode {
        case .original: return ""
        case .translation: return L10n.t("这首歌曲没有译文")
        case .romanization:
            return romanizationOffInSettings ? L10n.t("这首歌曲的语言未在设置的「标注读音的语言」中开启") : L10n.t("这首歌曲没有读音")
        }
    }

    /// 选的那一档这首没有时按「原文」显示,选择本身不改,换到有的歌又回来。
    private func effectiveDisplayMode(_ summary: EnrichCacheStore.Summary) -> LyricsManagerDisplayMode {
        isDisplayModeAvailable(displayMode, summary) ? displayMode : .original
    }

    private func shownRows(_ summary: EnrichCacheStore.Summary) -> [LyricsPreviewRow] {
        effectiveDisplayMode(summary) == .romanization ? romanizedRows : previewRows
    }

    /// 预览的两份行都走播放引擎(LyricsPreviewText.rows),跟歌词窗口显示的同一批。带读音那份用缓存里存的读音,加上按设置里
    /// 开着的文字种类现算的;「原文 + 读音」能不能点就看它有没有一句读音。输入没变就不重算:列表每重读一次都会走到这里。
    private func refreshPreviewRows(key: String, summary: EnrichCacheStore.Summary, lyrics: String, tr: String, roma: String) {
        let scripts = LocalPlaybackSource.shared.romanizationScripts
        let inputs = [key, lyrics, tr, roma, String(scripts.rawValue)]
        guard inputs != previewInputs else { return }
        previewInputs = inputs
        previewRows = LyricsPreviewText.rows(lyrics: lyrics, translation: tr, title: summary.title, artist: summary.artist)
        let mayRomanize = summary.hasRomanization || LyricsPreviewText.mayHaveRomanization(lyrics, scripts: scripts)
        romanizedRows = mayRomanize
            ? LyricsPreviewText.rows(lyrics: lyrics, translation: tr, romanization: roma, romanizationScripts: scripts,
                                     title: summary.title, artist: summary.artist)
            : []
        romanizationAvailable = romanizedRows.contains { !($0.romanization ?? "").isEmpty }
        romanizationOffInSettings = !romanizationAvailable && (summary.hasRomanization
            || LyricsPreviewText.mayHaveRomanization(lyrics, scripts: [.japanese, .korean, .chinese, .cantonese]))
    }

    /// 从这一句开始播放。减去当前歌词偏移:引擎判定当前句时把偏移加到播放位置上,不减回去跳过去会落在隔壁行(同歌词窗口点一行)。
    private func seek(toLyricsMs ms: Int) {
        PlaybackCoordinator.shared.seek(toMs: max(0, ms - PlaybackCoordinator.shared.currentLyricsOffsetMs))
    }

    // MARK: - 编辑

    /// 有词、不是纯音乐、正文读得回来、还没在编辑时才能进编辑。
    private var canEditLyrics: Bool {
        guard editMode == .preview, !detailIncomplete, let key = singleSelectedKey, key == editingKey,
              let summary = store.summary(forKey: key) else { return false }
        return summary.hasLyrics && !summary.isInstrumental
    }

    private func captureEditBase() {
        guard let key = editingKey else { return }
        editBase = EditBase(key: key, main: loadedYRC.isEmpty ? editedLyricsBody : editedWordBody,
                            tr: editedTrBody, roma: editedRomaBody)
    }

    /// 「编辑歌词」/ ⌘E:逐句格子。
    private func beginLineEditing() {
        guard canEditLyrics else { return }
        captureEditBase()
        editMode = .lines
    }

    /// 「⋯ → 以文本方式编辑」:整段改(粘贴替换整份、加句、删句时用),跟逐句格子改的是同一份。
    private func beginTextEditing() {
        guard canEditLyrics || editMode == .lines else { return }
        if editBase == nil { captureEditBase() }
        editMode = .text
    }

    /// Esc / 「放弃修改」:改过就先问一句,没改过直接退出编辑。
    private func requestDiscardEdits() {
        if isEditorDirty {
            showDiscardEditConfirm = true
        } else {
            endEditing()
        }
    }

    private func discardEdits() {
        if let key = editingKey { loadDetail(key: key) }
        endEditing()
    }

    private func endEditing() {
        editMode = .preview
        editBase = nil
        focusedLine = nil
    }

    @ViewBuilder
    private func lineEditor(_ summary: EnrichCacheStore.Summary) -> some View {
        let wordTimed = !loadedYRC.isEmpty
        let mainBody = wordTimed ? editedWordBody : editedLyricsBody
        let mode = effectiveDisplayMode(summary)
        // 读音只编辑缓存里存着的那份;现算出来的读音不在条目里,改不了。
        let secondaryBody: String? = mode == .translation ? editedTrBody : (mode == .romanization && !editedRoma.isEmpty ? editedRomaBody : nil)
        let secondaryBaseBody: String? = mode == .translation ? editBase?.tr : (mode == .romanization ? editBase?.roma : nil)
        VStack(alignment: .leading, spacing: 0) {
            editorBar(hint: wordTimed ? L10n.t("逐字歌词仅修改文字，每个字保留原有时间；新增或修改了时间戳的句子按字数分配时间")
                                      : L10n.t("点按时间可修改此句的时间戳"),
                      icon: wordTimed ? "lock.fill" : "info.circle",
                      switchTitle: L10n.t("以文本方式编辑"), onSwitch: beginTextEditing)
                .padding(.top, 12)
            LyricsManagerLineEditor(
                main: LyricsEditableLines(body: mainBody),
                mainBase: LyricsEditableLines(body: editBase?.main ?? mainBody),
                secondary: secondaryBody.map { LyricsEditableLines(body: $0) },
                secondaryBase: secondaryBaseBody.map { LyricsEditableLines(body: $0) },
                timeLocked: wordTimed,
                onMainText: { index, text in setMainLine(index, text: text, wordTimed: wordTimed) },
                onMainStamps: { index, stamps in setMainLine(index, stamps: stamps, wordTimed: wordTimed) },
                onSecondaryText: { index, text in setSecondaryLine(index, text: text, mode: mode) },
                onRevert: { index in revertLine(index, wordTimed: wordTimed) },
                focus: $focusedLine,
                isNowPlaying: summary.key == nowPlayingKey)
        }
    }

    private func setMainLine(_ index: Int, text: String? = nil, stamps: String? = nil, wordTimed: Bool) {
        if wordTimed {
            editedWordBody = LyricsEditableLines(body: editedWordBody).replacing(index, stamps: stamps, text: text).joined
        } else {
            editedLyricsBody = LyricsEditableLines(body: editedLyricsBody).replacing(index, stamps: stamps, text: text).joined
        }
    }

    private func setSecondaryLine(_ index: Int, text: String, mode: LyricsManagerDisplayMode) {
        switch mode {
        case .translation:
            editedTrBody = LyricsEditableLines(body: editedTrBody).replacing(index, text: text).joined
        case .romanization:
            editedRomaBody = LyricsEditableLines(body: editedRomaBody).replacing(index, text: text).joined
        case .original:
            break
        }
    }

    /// 「还原」:这一句的正文,和挂在它下面的译文、读音,改回打开编辑时的样子;打开编辑之后新加的那一句直接去掉。
    /// 按 `LyricsEditableLines.alignment` 找打开时对应的那一句,别按下标找:整段文本里增删过行就对到别的句子上了。
    private func revertLine(_ index: Int, wordTimed: Bool) {
        guard let base = editBase else { return }
        let mainBase = LyricsEditableLines(body: base.main)
        let current = LyricsEditableLines(body: wordTimed ? editedWordBody : editedLyricsBody)
        guard current.lines.indices.contains(index) else { return }
        guard let baseIndex = current.alignment(to: mainBase)[index] else {
            let removed = current.removing(index).joined
            if wordTimed { editedWordBody = removed } else { editedLyricsBody = removed }
            return
        }
        let original = mainBase.lines[baseIndex]
        let reverted = current.replacing(index, stamps: original.stamps, text: original.text).joined
        if wordTimed { editedWordBody = reverted } else { editedLyricsBody = reverted }
        guard let time = original.timeMs else { return }
        editedTrBody = Self.revertSecondary(editedTrBody, base: base.tr, timeMs: time)
        editedRomaBody = Self.revertSecondary(editedRomaBody, base: base.roma, timeMs: time)
    }

    private static func revertSecondary(_ body: String, base: String, timeMs: Int) -> String {
        let current = LyricsEditableLines(body: body)
        let original = LyricsEditableLines(body: base)
        guard let index = current.index(matching: timeMs), let baseIndex = original.index(matching: timeMs) else { return body }
        let line = original.lines[baseIndex]
        return current.replacing(index, stamps: line.stamps, text: line.text).joined
    }

    /// 编辑区顶上那一条:左边一句说明,右边切到另一种编辑方式。逐句格子和整段文本两边同一个样子(见 11 章决策 68)。
    private func editorBar(hint: String, icon: String, switchTitle: String, onSwitch: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Label(hint, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(switchTitle, action: onSwitch)
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    /// 整段文本编辑:歌词(整行 LRC,或逐字拼出来的每一行)、译文、读音各一个框。
    private func textEditors(_ summary: EnrichCacheStore.Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                editorBar(hint: loadedYRC.isEmpty ? L10n.t("整段编辑可粘贴替换、增删句子；每行开头是这一句的时间戳")
                                                  : L10n.t("逐字歌词仅修改文字，每个字保留原有时间；新增或修改了时间戳的句子按字数分配时间"),
                          icon: loadedYRC.isEmpty ? "info.circle" : "lock.fill",
                          switchTitle: L10n.t("回到逐句编辑"), onSwitch: { editMode = .lines })
                if loadedYRC.isEmpty {
                    editorSection(title: L10n.t("歌词（LRC）"), icon: "text.alignleft", text: $editedLyricsBody, minHeight: 260, monospaced: true, showCopyButton: true)
                } else {
                    editorSection(title: L10n.t("歌词（逐字）"), icon: "text.word.spacing", text: $editedWordBody, minHeight: 260, monospaced: true, showCopyButton: true)
                }
                editorSection(title: L10n.t("译文"), icon: "character.book.closed", text: $editedTrBody, minHeight: 90, monospaced: false)
                editorSection(title: L10n.t("读音"), icon: "textformat.abc", text: $editedRomaBody, minHeight: 90, monospaced: false, latinIcon: true)
            }
            .padding(.top, 14)
            .padding(.bottom, 120)
        }
    }

    /// latinIcon:图标必须画成拉丁字母才说得通(「罗马音」),理由见 LatinIconLabel。
    private func editorSection(title: String, icon: String, text: Binding<String>, minHeight: CGFloat, monospaced: Bool, latinIcon: Bool = false, showCopyButton: Bool = false) -> some View {
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
        }
    }
    /// 底部浮着的保存条:改了几处、快捷键,「放弃修改」(没改过时是「完成」)和「保存修改」。
    private func saveBar(key: String, summary: EnrichCacheStore.Summary) -> some View {
        let changes = editChangeCount
        return HStack(spacing: 12) {
            Image(systemName: "pencil.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(changes > 0 ? String(format: L10n.t("已修改 %@ 处"), "\(changes)") : L10n.t("尚未修改"))
                    .font(.system(size: 13, weight: .semibold))
                // 整段文本里方向键是移动光标,不提示换句。
                Text(editMode == .text ? L10n.t("⌘S 保存 · Esc 放弃") : L10n.t("⌘S 保存 · Esc 放弃 · ↑↓ 换句"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(isEditorDirty ? L10n.t("放弃修改") : L10n.t("完成")) { requestDiscardEdits() }
                .keyboardShortcut(.cancelAction)
                .settingsGlassButtons()
            Button {
                Task {
                    guard await saveEdits(key: key, summary: summary) else { return }
                    endEditing()
                }
            } label: {
                Label(showSaveEditFeedback ? L10n.t("已保存") : L10n.t("保存修改"),
                      systemImage: showSaveEditFeedback ? "checkmark" : "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .settingsProminentGlassButton(tint: .accentColor)
            .disabled(detailIncomplete || !isEditorDirty)
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: 680)
        // 不用液态玻璃:它太通透,滚到下面的歌词会透出来糊成一片。跟侧栏自动匹配进度卡同一套底(见 11 章决策 68)。
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
    }

    /// 改了几处:正文、译文、读音里改过、新加、删掉的句数加起来(按行对齐算,见 LyricsEditableLines.changeCount)。
    private var editChangeCount: Int {
        guard let base = editBase else { return 0 }
        let main = LyricsEditableLines(body: loadedYRC.isEmpty ? editedLyricsBody : editedWordBody)
            .changeCount(from: LyricsEditableLines(body: base.main))
        let tr = LyricsEditableLines(body: editedTrBody).changeCount(from: LyricsEditableLines(body: base.tr))
        let roma = LyricsEditableLines(body: editedRomaBody).changeCount(from: LyricsEditableLines(body: base.roma))
        return main + tr + roma
    }

    /// 「保存修改」。存好了返回 true(调用方据此退出编辑);没存上编辑缓冲原样留着,红字横幅已经在说。
    private func saveEdits(key: String, summary: EnrichCacheStore.Summary) async -> Bool {
        // 用户没动的那几格交**盘上此刻**的值,不交编辑缓冲里的:编辑缓冲是打开这一页时载入的,这期间
        // 引擎可能补了机翻、重新打分换了更好的词;三格原样交回去会把那些新内容盖掉(连同译文记录)。
        let disk = store.detail(for: key)
        guard disk.complete, editingKey == key else { return false }
        var lyrics = editedLyrics != loadedLyrics ? editedLyrics : disk.lyrics
        let tr = editedTr != loadedTr ? editedTr : disk.tr
        let roma = editedRoma != loadedRoma ? editedRoma : disk.roma
        // 逐字歌词改了字:以载入时那份逐字为底套回去,整行歌词里对得上的行跟着换(LyricsWordTimingEdit)。
        var yrc: String?
        var word: LyricsWordTimingEdit.Result?
        if !loadedYRC.isEmpty, editedWordText != loadedWordText {
            let result = LyricsWordTimingEdit.apply(edited: editedWordText, yrc: loadedYRC, lrc: lyrics)
            yrc = result.yrc
            lyrics = result.lrc
            word = result
        }
        let before = (lyrics: persistedLyricsForOffset, yrc: persistedYRCForOffset)
        // 没存上就到此为止:红字横幅已经在说,编辑缓冲里用户敲的内容原样留着,别闪「已保存」。
        guard await store.saveEdit(key: key, lyrics: lyrics, tr: tr, roma: roma, yrc: yrc) else { return false }
        // 存的过程中切到了别的歌:编辑缓冲和偏移已经是那一首的了,别用这首的结果去改。
        guard editingKey == key else { return true }
        // 只改了字、时间轴没动:单曲偏移按正文指纹存,搬到新正文下,不然调好的偏移看着像没了。
        let after = store.detail(for: key)
        if word?.timingUnchanged ?? (yrc == nil && LyricsWordTimingEdit.sameLineTimes(before.lyrics, after.lyrics)) {
            carryOffset(summary, from: before, to: (after.lyrics, after.yrc))
        }
        // 编辑缓冲换成刚落盘的权威内容(不再算未保存);歌词内容可能改了,offset 的 key(内容指纹)也跟着
        // 变,loadDetail 顺带按盘上那份重算偏移状态。
        loadDetail(key: key)
        if let estimated = word?.estimatedLines, estimated > 0 {
            let note = String(format: L10n.t("%@ 句为新增或修改了时间戳，已按字数分配逐字时间"), "\(estimated)")
            saveEditNote = note
            Task {
                try? await Task.sleep(for: .seconds(5))
                if saveEditNote == note { withAnimation { saveEditNote = nil } }
            }
        }
        flashSaveEditFeedback()
        return true
    }

    /// 时间轴偏移 − / +:按设置里的步长在当前值上加减,跟敲一个数回车走同一条写入路径。
    private func nudgeOffset(_ summary: EnrichCacheStore.Summary, direction: Int) {
        let current = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey(summary))
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: current + direction * AppSettings.shared.lyricsOffsetStepMs)
        applyOffsetEdit(summary)
    }

    // MARK: - 没有歌词时的几页

    /// 缺歌词:为什么没词、下一步做什么。三个出口:重新自动匹配(最常用)、搜索候选歌词、标为纯音乐。
    private func missingState(_ summary: EnrichCacheStore.Summary) -> some View {
        let reason = MissingReason(summary)
        return VStack(spacing: 14) {
            Image(systemName: reason.icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(reason.title)
                .font(.system(size: 19, weight: .semibold))
            Text(reason.explanation(resolvedAt: summary.resolvedAt.map(Self.dayText)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    Task { await runRematch(key: summary.key) }
                } label: {
                    Label(L10n.t("重新自动匹配"), systemImage: "wand.and.stars")
                }
                .settingsProminentGlassButton(tint: .accentColor)
                .disabled(rematchBlocked)
                Group {
                    Button {
                        openSearchSheet(summary)
                    } label: {
                        Label(L10n.t("搜索候选歌词"), systemImage: "magnifyingglass")
                    }
                    .disabled(rematchRunningKey != nil)
                    Button {
                        Task { await store.setInstrumental(key: summary.key, true) }
                    } label: {
                        Label(L10n.t("标为纯音乐"), systemImage: "pianokeys")
                    }
                }
                .settingsGlassButtons()
            }
            .controlSize(.large)
            .padding(.top, 6)
            if summary.lastRoundHadNoResponder {
                noResponderBatchLine(summary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    /// 没词的三种原因(纯音乐、只有纯文本的另有一页),判定顺序跟列表行的标签一致。
    private enum MissingReason {
        case noResponder
        case indexed
        case none

        init(_ summary: EnrichCacheStore.Summary) {
            if summary.lastRoundHadNoResponder {
                self = .noResponder
            } else if summary.knownOnSources {
                self = .indexed
            } else {
                self = .none
            }
        }

        var icon: String {
            switch self {
            case .noResponder: return "antenna.radiowaves.left.and.right.slash"
            case .indexed: return "music.note"
            case .none: return "text.badge.xmark"
            }
        }

        var title: String {
            switch self {
            case .noResponder: return L10n.t("本轮无歌词源应答")
            case .indexed: return L10n.t("歌词源已收录这首歌曲，但暂无歌词")
            case .none: return L10n.t("未找到歌词")
            }
        }

        func explanation(resolvedAt day: String?) -> String {
            switch self {
            case .noResponder:
                if let day {
                    return String(format: L10n.t("%@解析时没有任何歌词源应答，可能是当时网络不可用，并不代表这首歌曲没有歌词。重新自动匹配通常可以找到"), day)
                }
                return L10n.t("上次解析时没有任何歌词源应答，可能是当时网络不可用，并不代表这首歌曲没有歌词。重新自动匹配通常可以找到")
            case .indexed:
                return L10n.t("网易云音乐或 QQ 音乐已收录这首歌曲，但尚未提供歌词，新发行的歌曲常见这种情况。重新匹配效果有限，可搜索候选歌词或稍后再试")
            case .none:
                return L10n.t("已搜索的歌词源均未提供这首歌曲的歌词。可搜索候选歌词手动选择；若为纯音乐，可标为纯音乐")
            }
        }
    }

    /// 「无源应答」那一页底下一行:同样没有源应答的还有几首,一起自动匹配;已经在跑就说进度在哪。
    @ViewBuilder
    private func noResponderBatchLine(_ summary: EnrichCacheStore.Summary) -> some View {
        if fillSweepStatus?.running == true || fillSweepPending {
            Text(L10n.t("自动匹配正在进行，可在左下角查看进度"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let keys = store.summaries.filter { $0.lastRoundHadNoResponder && EnrichCacheStore.isFillSweepRetryable($0) }
                .map(\.key)
            let others = keys.filter { $0 != summary.key }.count
            if others > 0 {
                Button(String(format: L10n.t("另有 %@ 首歌曲无源应答 · 全部自动匹配"), "\(others)")) {
                    requestFillSweep(keys)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    /// 标了纯音乐:各处不显示歌词、不再自动搜;有词的话词还留着,取消标记就回来。
    private func instrumentalState(_ summary: EnrichCacheStore.Summary) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.t("纯音乐"))
                .font(.system(size: 19, weight: .semibold))
            Text(summary.hasLyrics
                 ? L10n.t("不再显示这首歌曲的歌词，也不再自动搜索。歌词仍会保留，取消标记后恢复显示")
                 : L10n.t("不再显示这首歌曲的歌词，也不再自动搜索"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
            HStack(spacing: 10) {
                Button {
                    Task { await store.setInstrumental(key: summary.key, false) }
                } label: {
                    Label(L10n.t("取消纯音乐标记"), systemImage: "pianokeys.inverse")
                }
                .help(L10n.t("取消「纯音乐」标记：已有歌词的恢复显示，没有歌词的重新加入自动匹配队列"))
                Button {
                    openSearchSheet(summary)
                } label: {
                    Label(L10n.t("搜索候选歌词"), systemImage: "magnifyingglass")
                }
                .disabled(rematchRunningKey != nil)
            }
            .settingsGlassButtons()
            .controlSize(.large)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    /// 只有纯文本兜底(没有时间轴):照常显示文本,顶上一句话加「搜索候选歌词」。
    private func plainTextState(_ summary: EnrichCacheStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label(L10n.t("这首歌曲只有纯文本歌词，没有时间轴。可搜索带时间轴的歌词"), systemImage: "text.quote")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    openSearchSheet(summary)
                } label: {
                    Label(L10n.t("搜索候选歌词"), systemImage: "magnifyingglass")
                }
                .settingsGlassButtons()
                .disabled(rematchRunningKey != nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .padding(.top, 14)
            ScrollView {
                Text(plainLyricsText)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
            }
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

    /// 请引擎对这一首跑一轮「重新自动匹配」(见 LyricsRematch),等它的结论。
    private func runRematch(key: String) async {
        rematchGeneration += 1
        let generation = rematchGeneration
        rematchRunningKey = key
        rematchResult = nil
        rematchDone = 0
        rematchTotal = 0
        let id = UUID().uuidString
        rematchRequestID = id
        guard let line = await LyricsRematchRunner.run(
            key: key, id: id, isCurrent: { generation == rematchGeneration },
            onProgress: { sourcesDone, sourcesTotal in
                rematchDone = sourcesDone
                rematchTotal = sourcesTotal
            }) else { return }
        // 「正在重新匹配」撑到列表重读完再清:中途清掉的话状态行会空一下、按钮也提前解禁。
        await store.reload(onlyIfChanged: true)
        guard generation == rematchGeneration else { return }
        finishRematch(key: key, line: line)
    }

    /// 一轮重新匹配的收尾(详情页那颗按钮、搜索面板那颗共用):换了词就把编辑框换成盘上的新内容(编辑框此刻属于
    /// 别的歌就不碰),结论挂在详情页那一行。调用前列表要先重读过。
    private func finishRematch(key: String, line: LyricsRematch.Line) {
        if line.tone == .changed, editingKey == key { loadDetail(key: key) }
        rematchResult = RematchOutcome(key: key, tone: line.tone, text: LyricsRematchRunner.text(line))
        rematchRunningKey = nil
    }


    private func loadDetail(key: String) {
        let d = store.detail(for: key)
        editingKey = key
        loadedLyrics = d.lyrics
        loadedTr = d.tr
        loadedRoma = d.roma
        detailIncomplete = !d.complete
        editedLyrics = d.lyrics
        editedTr = d.tr
        editedRoma = d.roma
        loadedYRC = LyricsWordTimingEdit.hasWordLines(d.yrc) ? d.yrc : ""
        loadedWordText = loadedYRC.isEmpty ? "" : LyricsWordTimingEdit.editableText(yrc: loadedYRC)
        editedWordText = loadedWordText
        saveEditNote = nil
        if let summary = store.summary(forKey: key) {
            refreshOffsetState(artist: summary.artist, title: summary.title, lyrics: d.lyrics, yrc: d.yrc)
            refreshPreviewRows(key: key, summary: summary, lyrics: d.lyrics, tr: d.tr, roma: d.roma)
            plainLyricsText = !summary.hasLyrics && summary.hasPlainTextFallback ? store.plainLyrics(for: key) : ""
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

    /// 只改了字的保存:这首的单曲偏移从旧正文的指纹搬到新正文下(新指纹下已经有值就不动)。
    private func carryOffset(_ summary: EnrichCacheStore.Summary, from old: (lyrics: String, yrc: String),
                             to new: (lyrics: String, yrc: String)) {
        let oldKey = LyricsOffsetStore.trackKey(artist: summary.artist, title: summary.title, lyrics: old.lyrics, lyricsYRC: old.yrc)
        let newKey = LyricsOffsetStore.trackKey(artist: summary.artist, title: summary.title, lyrics: new.lyrics, lyricsYRC: new.yrc)
        let ms = LyricsOffsetStore.shared.offset(forKey: oldKey)
        guard ms != 0, oldKey != newKey, LyricsOffsetStore.shared.offset(forKey: newKey) == 0 else { return }
        LyricsOffsetStore.shared.setOffset(0, forKey: oldKey, pinKey: "")
        LyricsOffsetStore.shared.setOffset(ms, forKey: newKey, pinKey: summary.key)
    }

    private func currentOffsetKey(_ summary: EnrichCacheStore.Summary) -> String {
        LyricsOffsetStore.trackKey(artist: summary.artist, title: summary.title, lyrics: persistedLyricsForOffset, lyricsYRC: persistedYRCForOffset)
    }

    private func applyOffsetEdit(_ summary: EnrichCacheStore.Summary) {
        // 解析不了、不是有限数或超出范围(见 LyricsOffsetInput)时不写入,输入框改回当前生效的值:别当成 0 秒,那会把手动
        // 校正过的偏移悄悄清掉;输入框弹回原来的数字,就看得出这次输入没被接受。
        guard let ms = LyricsOffsetInput.milliseconds(from: editedOffsetSeconds) else {
            editedOffsetSeconds = AppSettings.formattedSeconds(ms: LyricsOffsetStore.shared.offset(forKey: currentOffsetKey(summary)))
            return
        }
        // pinKey 用 summary.key(缓存 key 本身,已归一化)—— 播放侧算的是
        // EnrichCacheKeys.normalizedKey,两边必须是同一个身份,否则在这里校准的歌跟播放时
        // 钉住的歌是两条记录(见 LocalPlaybackSource.currentPinKey 的注释)。
        LyricsOffsetStore.shared.setOffset(ms, forKey: currentOffsetKey(summary), pinKey: summary.key)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: ms)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
    }

    private func resetOffsetEdit(_ summary: EnrichCacheStore.Summary) {
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey(summary), pinKey: summary.key)
        editedOffsetSeconds = AppSettings.formattedSeconds(ms: 0)
        PlaybackCoordinator.shared.refreshLyricsOffsetForCurrentTrack()
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
