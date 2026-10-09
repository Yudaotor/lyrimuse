import AppKit
import Combine
import LyrimuseCore
import SwiftUI

// "联网搜索候选歌词"弹窗。左边一块浮起来的侧栏:查询词(歌名 / 歌手 / 专辑)、「重新搜索」和搜出来的
// 候选(来源 + 分数 + 是否逐字);右边是选中候选的预览,"采用此候选"把内容交回调用方
// (调用方负责真正写回缓存,这里只管搜索和展示)。onApply 是可等待的、回报有没有真的落盘:
// 面板据此挪「当前使用」徽标、给一条回声;`keepsOpenAfterApply` 决定采纳后关窗还是留着
// (只有悬浮窗 ⚙ 的独立小窗传 true,理由见 apply(_:))。
//
// 两种宿主:悬浮窗 ⚙ 的独立小窗(`standaloneWindow: true`)标题栏透明、内容铺到最顶上,红绿灯落在
// 侧栏顶部那一截里,「关闭」交给红灯和 Esc;歌词管理、歌词窗口弹出的是 sheet,没有标题栏,右上角留
// 「关闭」。版面与取舍见 11 章决策 51。
//
// 歌名/歌手/专辑是可编辑字段,默认沿用这首歌本身的元数据,也支持改关键词后重新联网
// 查(比如原始元数据不准/有别名,想换个关键词试试能不能搜到更好的候选)。改这三个
// 字段只影响"拿什么关键词去查",不影响写回哪条缓存记录——onApply 只回传选中的
// candidate,真正决定写入 key 的是调用方 LyricsManagerView.swift 里早就捕获好的稳定
// key,跟 artist/title/album 这三个字段无关。
struct LyricsSearchSheet: View {
    // 原始值——用来在用户改乱查询关键词之后一键恢复,也是"默认查询"这句里"默认"的
    // 具体所指(初次打开时 artist/title/album 就是从这三个值来的)。
    let originalArtist: String
    let originalTitle: String
    let originalAlbum: String
    /// 面板为之打开的那一首的缓存 key(跟宿主写回的是同一条)。正在放的就是这首时,预览标出此刻唱到哪一句、能点时间跳过去。
    /// 三个入口都得传(contracts 组守卫钉着)。
    let songKey: String
    // 这首歌眼下实际生效的歌词来源(EnrichCacheStore.Summary.lyricsSource,比如"qq")——
    // 默认选中它,而不是"搜索结果里谁先到就选谁":默认选中的
    // 候选应该是眼下正在用的这一份,不是随便哪个候选,不然明明已经在用 QQ 音乐的歌词,
    // 打开这个弹窗却默认高亮着完全不相关的 kugou,容易误导成"当前用的就是这个"。
    let currentSource: String?
    /// 这首歌当前正文的「只取词」指纹(ManualPickLock.fingerprint),nil = 调用方拿不到正文。
    /// 「当前使用」徽标是来源 + 词双判据(LyricsCandidateDuplicates.isCurrent):同源但
    /// 正文被手改过的不再标当前;拿不到指纹时退回只比来源。三个入口都得传(contracts 组守卫钉着)。
    let currentFingerprint: String?
    /// 曲目真实时长(秒),0 表示未知。必须传:打分里时长匹配那一档权重很重,传 0 时整档对所有候选跳过,面板里的排名
    /// 就跟自动选歌词时用的那组分数对不上。候选的源自报曲长也拿它比(`durationLabel`)。
    let durationSecs: Double
    /// 采纳后面板留着不关。三个入口里只有悬浮窗 ⚙ 的独立小窗传 true:那是边听边换词的入口,留着的话同一批候选还在,
    /// 点即切,不用关窗重开、再等各个源重搜。歌词管理(编辑器上方的模态,留着会挡住刚回填的编辑器)和歌词窗口的 sheet
    /// (关了才看得到背后的歌词)采纳后关窗。
    let keepsOpenAfterApply: Bool
    /// 宿主是悬浮窗 ⚙ 的独立小窗,不是 sheet:侧栏顶上给红绿灯让出一截、不画「关闭」(红灯和 Esc 都能关)。
    /// 窗口那一侧:场景挂 `.windowStyle(.hiddenTitleBar)`(标题栏透明、内容铺到顶),宿主再挂 EmptyUnifiedToolbar
    /// 把标题栏撑高、红绿灯挪进侧栏的圆角里。
    let standaloneWindow: Bool

    /// 窗口 / sheet 能拖到的最小内容尺寸。宽:侧栏连外边距约 404pt,右边预览至少留 ~400pt;高:独立小窗里侧栏
    /// 上半截(红绿灯那一截 + 查询卡 + 按钮 + 表头)约 240pt,剩下的放得下三条候选。独立小窗的宿主在面板出来之前也用这一对。
    static let minimumSize = CGSize(width: 800, height: 580)
    /// 打开时的尺寸:右侧标题行的三颗按钮连同采纳后的回声放得下(宽度怎么量的见 11 章决策 56)。sheet 按它开,
    /// 独立小窗第一次开也按它,之后窗口自己记尺寸。
    static let defaultSize = CGSize(width: 1040, height: 680)
    /// 侧栏宽度,固定、不能拖。
    private static let sidebarWidth: CGFloat = 396
    /// 侧栏离窗口边缘的距离。
    private static let panelInset: CGFloat = 8
    /// 侧栏的圆角。
    private static let panelCornerRadius: CGFloat = 22
    /// 调用方真正写回缓存,回报有没有落盘。面板等它结束再决定:成功 → 挪「当前使用」徽标,
    /// 留着的话给一条回声、关窗模式直接关;失败 → 关窗模式照旧关(调用方那边的 lastError 红字
    /// 负责说明),留着的话在标题栏说一句、让人直接重试。
    let onApply: (LyricsSearchService.Candidate) async -> Bool
    /// 打开面板时这首歌是不是标成了纯音乐(宿主读缓存给的)。
    let isMarkedInstrumental: Bool
    /// 标 / 撤「纯音乐」:调用方按打开面板时那首歌写回,回报有没有落盘。三个入口都得传(contracts 组守卫钉着)。
    let onSetInstrumental: (Bool) async -> Bool
    /// 「重新自动匹配」:请引擎按设置里的「匹配算法」重挑一轮、等结论(宿主转给 LyricsRematchRunner,跟歌词管理那颗
    /// 按钮同一条路),不经过这里的候选列表。参数是进度回调(回过话的源数 / 一共几个源);返回 nil = 没拿到结论。
    /// 三个入口都得传(contracts 组守卫钉着)。
    let onAutoMatch: (@escaping (Int, Int) -> Void) async -> LyricsRematch.Line?

    /// 正在写回的那条候选的来源(按钮禁用 + 文案变「正在采用…」);nil = 没有在飞的采纳。
    @State private var applyingSource: String?
    /// 本次面板存活期间最后一次采纳成功的来源。「当前使用」徽标认 `appliedSource ?? currentSource`
    /// —— `currentSource` 由宿主给,宿主不跟着刷新时就是打开面板那一刻的快照。换歌时重置;宿主给的
    /// 来源 / 指纹变了也重置,那份比这里记的新(后台重打分换了正文,或者宿主读到了刚采纳的那条)。
    @State private var appliedSource: String?
    /// 跟 appliedSource 配对:刚采纳那条的指纹,「当前使用」双判据的另一半。
    @State private var appliedFingerprint: String?
    @State private var applyFeedback: ApplyFeedback?
    @State private var applyFeedbackGeneration = 0
    /// 本次面板存活期间切过的纯音乐标记;nil = 没切过,认宿主给的。换歌、宿主给的值变了都重置。
    @State private var instrumentalOverride: Bool?
    /// 纯音乐标记正在写回(标记按钮禁用)。
    @State private var settingInstrumental = false
    /// 「重新自动匹配」在飞:按钮禁用,标题行下面出进度;采纳、标纯音乐也置灰(期间改了条目,引擎这一轮就作废)。
    @State private var autoMatching = false
    @State private var autoMatchDone = 0
    @State private var autoMatchTotal = 0
    /// 上一轮自动匹配的结论,挂在标题行下面;换歌、再点一次、采纳成功时收掉。
    @State private var autoMatchLine: LyricsRematch.Line?

    private struct ApplyFeedback: Equatable {
        let text: String
        let ok: Bool
    }

    @Environment(\.dismiss) private var dismiss
    // 只为了让这个弹窗在手动切换语言时重新渲染,同 LyricsManagerView 的理由 ——
    // 经 AppLanguageObserver 窄代理,不整对象订阅 AppSettings(那样设置页
    // 拖任何滑杆/色轮都会打醒这个 sheet 的整个 body,含候选列表和预览面板)。
    @ObservedObject private var languageSettings = AppLanguageObserver.shared
    // candidates / isSearching 分开存,不揉成一个「加载中 / 已加载 / 失败」三态:结果是陆续到达的(引擎按 NDJSON 逐行
    // 输出,见 LyricsSearchService.search 的 onUpdate),「还在搜」和「已经有哪些候选」是两个独立维度。
    @State private var candidates: [LyricsSearchService.Candidate] = []
    /// 这首歌现在缓存里存着的那一版(`isStored`),打开面板就摆进「当前使用」那一块、先选中它,其他源接着搜;搜到同一份(来源和
    /// 正文都一样)就换成搜到的那条,没搜到(手改过、来源是播放器本地歌词、那个源这次没回)就一直留着。见 currentShown、11 章决策 99、100。
    @State private var storedCandidate: LyricsSearchService.Candidate?
    /// 这个面板作为搜索发起方的身份,见 `LyricsSearchService.Owner`。
    @State private var searchOwner = LyricsSearchService.Owner()
    /// 预览区那份按行拆好的正文(`LyricsPreviewText.rows` 要整首走一遍播放引擎),而查询词每敲一个字、
    /// 每到一批候选都会重算 body;选中的候选没变就沿用上一次的结果。
    @State private var previewMemo = PreviewRowsMemo()
    /// 预览显示原文 / 原文 + 译文 / 原文 + 读音;选中的候选没有那一档时按原文显示,选择本身不改,换到有的候选又回来。
    /// 跟歌词管理详情页记在同一个偏好键,两边改一处另一处跟着变,下次打开照旧。
    @AppStorage(LyricsManagerDisplayMode.defaultsKey) private var displayMode: LyricsManagerDisplayMode = .translation
    /// 预览跟着播放滚到当前句(只在正在放的就是这首时有这颗开关),手动滚一下就暂停。
    @State private var followPlayback = true
    @StateObject private var nowPlaying = LyricsSearchNowPlaying()
    /// 查询对象(换歌)换了几次,见 apply 里那道守卫。
    @State private var subjectGeneration = 0
    /// 候选列表有没有焦点:点一行时交给它,方向键才换得了行(onMoveCommand)。
    @FocusState private var candidateListFocused: Bool
    /// 「内容与其他候选相同」「不可用」两个折叠组展开了没有(LyricsCandidateGroups)。选中的那条落在收起的组里时自动展开。
    @State private var showsSameGroup = false
    @State private var showsExcludedGroup = false

    /// 一条候选在预览里要的东西,按候选内容和设置里开着读音的文字种类算一次。
    private struct PreviewRows {
        let plain: [LyricsPreviewRow]
        /// 带读音的那份(候选自带的,加上按设置现算的,跟采纳后歌词窗口显示的一样);这份歌词里没有能标读音的字时是空的。
        let romanized: [LyricsPreviewRow]
        let hasTranslation: Bool
        let hasRomanization: Bool
        /// 没有读音只是因为设置里没开这种语言(候选自带读音,或者有能标读音的字)。
        let romanizationOffInSettings: Bool
        /// 有没有一行带时间;纯文本候选没有,不画时间列、不标当前句。
        let timed: Bool
        /// 候选自带的 `[offset:]`,算法同 LyricsSyncEngine.load:先看整行歌词,为 0 再看逐字。
        let embeddedOffsetMs: Int
    }

    private final class PreviewRowsMemo {
        private var inputs: [String] = []
        private var cached: PreviewRows?

        func rows(_ c: LyricsSearchService.Candidate, scripts: RomanizationScripts) -> PreviewRows {
            let inputs = [c.lyrics, c.lyricsTr, c.lyricsRoma, c.lyricsYRC, c.title, c.artist, String(scripts.rawValue)]
            if let cached, inputs == self.inputs { return cached }
            // 当前句逐字染色的字取自这条候选自己的逐字轨(见 11 章决策 101)。
            func withKaraoke(_ rows: [LyricsPreviewRow]) -> [LyricsPreviewRow] {
                LyricsPreviewText.attachingKaraoke(rows, lyrics: c.lyrics, yrc: c.lyricsYRC, title: c.title, artist: c.artist)
            }
            let plain = withKaraoke(
                LyricsPreviewText.rows(lyrics: c.lyrics, translation: c.lyricsTr, title: c.title, artist: c.artist))
            let mayRomanize = c.hasRomanization || LyricsPreviewText.mayHaveRomanization(c.lyrics, scripts: scripts)
            let romanized = mayRomanize
                ? withKaraoke(LyricsPreviewText.rows(lyrics: c.lyrics, translation: c.lyricsTr, romanization: c.lyricsRoma,
                                                     romanizationScripts: scripts, title: c.title, artist: c.artist))
                : []
            let hasRomanization = romanized.contains { !($0.romanization ?? "").isEmpty }
            let embedded = LRCParser.parseOffsetMs(c.lyrics)
            let rows = PreviewRows(
                plain: plain, romanized: romanized,
                hasTranslation: plain.contains { !($0.translation ?? "").isEmpty },
                hasRomanization: hasRomanization,
                romanizationOffInSettings: !hasRomanization && (c.hasRomanization
                    || LyricsPreviewText.mayHaveRomanization(c.lyrics, scripts: [.japanese, .korean, .chinese, .cantonese])),
                timed: plain.contains { $0.timeMs != nil },
                embeddedOffsetMs: embedded != 0 ? embedded : LRCParser.parseOffsetMs(c.lyricsYRC))
            self.inputs = inputs
            cached = rows
            return rows
        }
    }
    /// 给侧栏那一行"还在搜索"提示缀的进度,形如 "（2/5）"。还没收到任何一行时是空串。
    ///
    /// 轮次标识:引擎的兜底轮(首歌手变体/标题反查,见
    /// 第 09 章)每轮都重新扫全部源,进度"到 8/8 又回到 1/8"——数字回跳没有任何标注,
    /// 读起来像出了错。第 2 轮起在进度后面缀"［2］"标出轮次(放后面是刻意的);
    /// 第 1 轮不缀——绝大多数搜索只有一轮,常驻一个"［1］"是噪音,而标识恰好在数字
    /// 回跳那一刻出现,自己解释自己。
    private var searchProgressSuffix: String {
        guard sourcesTotal > 0 else { return "" }
        // 全角括号只配中文文案;英文界面用半角,前面空一格。
        if L10n.current == "en" {
            let roundSuffix = searchRound >= 2 ? " [\(searchRound)]" : ""
            return " (\(sourcesDone)/\(sourcesTotal))\(roundSuffix)"
        }
        let roundSuffix = searchRound >= 2 ? "［\(searchRound)］" : ""
        return "（\(sourcesDone)/\(sourcesTotal)）\(roundSuffix)"
    }

    // 歌词源的完整名单,直接读 LyricsSource.allCases(FeatureSettingsStore.swift),别在这里手抄一份。Go / Swift 两份名单
    // 逐个相等、这个文件里没有手抄名单、空状态那句的数字等于源数,由 selftest contracts 组「歌词源名单」守卫钉住。
    // 顺序跟设置页「歌词源」列表一致(同一个 enum)。
    private static let allLyricSourceNames = LyricsSource.allCases.map(\.rawValue)

    // 这一轮里哪些源真的给出过候选(哪怕候选被判-1分),哪些一条
    // 候选都没给——直接从已经收到的 candidates 里反推,跟引擎侧
    // lyricSourcesResponded(enrich.go)同一个判据("给没给"不看分数),不需要额外的
    // 网络请求或后端改动:candidates 本来就包含被拒绝的候选(比如"无时间戳"那些),
    // 每一行 stdout 都会带着目前收到的全部候选重新发一遍。
    private var respondedSources: Set<String> {
        Set(candidates.map(\.source))
    }

    // 传输层就没打通的源:引擎对这一轮一个 HTTP 响应都没拿到的源报 dns_failed / connect_failed / server_error
    // (sourcebreaker.go 的传输层分类),对上游不可用的 AMLL 报 upstream_unreachable(searchcli.go),经
    // sourceFailureReasonCodes 传到这里。空状态据此把「连不上」和「未返回候选」分开说:networkLooksDown 要求进程内
    // 所有请求都失败,只有部分源的域名解析不了时它是 false。
    // 四个代码的顺序就是展示顺序。这份表是 Go 侧 lyricSourceTransportFailureOrder + upstream_unreachable 的手抄,
    // lyricsourcefailure_test.go(TestSwiftSearchSheetTransportCodesMatchGo)钉着两边一致;少一个,那个代码的源会
    // 掉进「其余 N 个源」。
    private static let transportFailureCodes = ["dns_failed", "connect_failed", "server_error", "upstream_unreachable"]

    /// 按失败代码分组的没连上的源;组内源的顺序跟名单一致。给过候选的源无论代码如何都不算
    /// (引擎那边本来就不会给它们代码,这里再守一道)。
    private var unreachableSourcesByCode: [(code: String, sources: [String])] {
        Self.transportFailureCodes.compactMap { code in
            let sources = Self.allLyricSourceNames.filter {
                !respondedSources.contains($0) && sourceFailureReasonCodes[$0] == code
            }
            return sources.isEmpty ? nil : (code, sources)
        }
    }

    /// 空状态里一行一组:「**原因**：源 A、源 B」,原因加粗、源名常规。跟 LyricSourceFailureReason 给「歌词源可用情况」
    /// 明细用的整句解释是两个场合,这里只要一个名词短语。源名用「、」拼,同 LyricsDecisionSheet「本轮应答的源：%@」。
    ///
    /// 模板只有一个 key:拿 U+FFFC(对象替换符,正文里不会出现)当占位符格式化一次,再按它切开、照原顺序拼回去,
    /// `%@` 以外的部分就是原因。某种语言把 `%@` 挪到句首或句中也只加粗原因那部分,按标点切分做不到这一点。
    private static func transportFailureLine(_ code: String, sources: [String]) -> Text {
        let names = sources.map(sourceDisplayName).joined(separator: "、")
        // `case "<code>":` 这几个字面量是跨语言契约的锚点,lyricsourcefailure_test.go 的
        // TestSwiftSearchSheetTransportCodesMatchGo 直接在源码里搜它们 —— 改写法前先改那个测试。
        let template: String
        switch code {
        case "dns_failed": template = L10n.t("域名解析失败（DNS）：%@")
        case "connect_failed": template = L10n.t("连接失败或超时：%@")
        case "server_error": template = L10n.t("服务器报错（5xx）：%@")
        case "upstream_unreachable": template = L10n.t("无法连接上游源，未能查询：%@")
        default: template = code + ": %@"
        }
        let sentinel = "\u{FFFC}"
        let parts = String(format: template, sentinel).components(separatedBy: sentinel)
        // 模板里没有 `%@`(翻译把占位符漏了)时只切得出一段:整段加粗、源名照旧补在后面,
        // 宁可样式不完美也不能把源名吞掉。
        guard parts.count >= 2 else { return Text(parts[0]).bold() + Text("：" + names) }
        return Text(parts[0]).bold() + Text(names) + Text(parts.dropFirst().joined(separator: sentinel))
    }

    @State private var showSourceAvailability = false

    /// 这一轮**开着**的源(rawValue)。开搜那一刻从 FeatureSettingsStore 快照——引擎子进程
    /// 起跑时读的是同一份 features.json,所以这份集合就是它这一轮**采用结果**的那几个;搜索中途在
    /// 设置里开关源不改这一轮的标注(下次「重新搜索」才生效),跟候选一样是"这一轮"的事实。
    /// 也就是引擎这一轮**真正发了请求**的那几个:fetchScoredLyricCandidatesStreaming
    /// 的 skipSource 对关掉的源直接回空结果、不发请求(enrich.go)。引擎那边改成「查了但不采用」时,这条注释和
    /// disabledSourceRow 的 .help 措辞要一起改。
    /// 用途只有一个:「歌词源可用情况」把没开的源标成「未启用」而不是「未返回候选」,不藏掉。徽标的分母**不**用它,
    /// 用引擎报的 sourcesTotal,见下。
    /// 空集 = 还没开搜(徽标那时也不显示);行列表把空集当"全开"处理,别把九行全标成未启用。
    @State private var enabledSources: Set<String> = []

    // 候选表头右边那颗「x/y」+ 点开的可用情况列表。一打开面板就在(表头不能等第一行才冒出来,下面的列表会跟着跳)。
    //
    // 分母是引擎报的 sourcesTotal(它只数用户开着的源,见 enrich.go lyricSearchUpdateFunc
    // 的注释),跟进度那对「(x/y)」同一个数,用户关掉一个源时两处的分母一致。还没收到第一行时先用这一轮开着的
    // 源数(availabilityDenominator)。那时分子是 0,但正下方那行写着「正在查询各个歌词源…」,读不成「零个可用」。
    // 分子数"给过候选的源":引擎的 filterEnabledLyricSources 保证候选里没有关掉的源,不用再交集一次。
    private var sourceAvailabilityBadge: some View {
        Button {
            showSourceAvailability = true
        } label: {
            Label {
                Text("\(respondedSources.count)/\(availabilityDenominator)").monospacedDigit()
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
            }
        }
        .controlSize(.small)
        .settingsGlassButtons(inSheet: presentedAsSheet)
        .help(L10n.t("本轮给出候选的歌词源数量，点按查看详情"))
        .popover(isPresented: $showSourceAvailability, arrowEdge: .bottom) {
            sourceAvailabilityList
        }
    }

    /// 徽标的分母:引擎报了就用它;还没收到第一行时先用这一轮开着的源数(引擎子进程读的是同一份 features.json,
    /// 随后报的通常就是这个数),还没开搜过时用设置里开着的源数。
    private var availabilityDenominator: Int {
        if sourcesTotal > 0 { return sourcesTotal }
        return enabledSources.isEmpty ? FeatureSettingsStore.shared.lyricsSources.count : enabledSources.count
    }

    /// 列表行序:开着的源在前(名单序),关掉的沉底——用户看这张表是想知道"查了的那几个怎么样",
    /// 没查的排后面不打断视线。enabledSources 为空(还没开搜)按全开处理。
    private var sourceAvailabilityRows: [(source: String, enabled: Bool)] {
        let names = Self.allLyricSourceNames
        let enabled = enabledSources.isEmpty ? Set(names) : enabledSources
        return names.filter { enabled.contains($0) }.map { ($0, true) }
            + names.filter { !enabled.contains($0) }.map { ($0, false) }
    }

    private var sourceAvailabilityList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("歌词源可用情况"))
                .font(.headline)
            // "给过候选"≠"这条候选能用"——一个源明确回过一份被拒绝的候选(比如没时间戳、
            // 语言不对),跟它压根没回应(超时/限速/真的没收录这首歌),是两回事,分开
            // 标出来才不会把"回应了但不好"和"根本没回应"混为一谈。用户关掉的源又是第三回事
            // ——这一轮压根没查它,单独一档,见 disabledSourceRow。
            ForEach(sourceAvailabilityRows, id: \.source) { row in
                if row.enabled {
                    sourceAvailabilityRow(row.source)
                } else {
                    disabledSourceRow(row.source)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: 360)
    }

    private func sourceAvailabilityRow(_ source: String) -> some View {
        // "曲库里有这首歌、但平台没有歌词"是第四档,排在最前面判:它比下面
        // 「已返回候选 / 未返回候选」那对二分**更确定**——那两档只说了"给没给候选",而这一档
        // 说的是"为什么没给"。这个源不会同时出现在 respondedSources 里(引擎侧的搭车
        // 标记被 filterEnabledLyricSources 过滤掉了,不算候选),所以两者不会打架。
        if let found = tracksFoundNoLyrics.first(where: { $0.source == source }) {
            return AnyView(noLyricsSourceRow(source, found: found))
        }
        return AnyView(respondedSourceRow(source))
    }

    /// 命中了曲目、但平台没有歌词的那一行。图标用信息感的感叹号而不是叉:这不是失败,
    /// 是一个有内容的答复。副标题如实列出它匹配到的是哪首歌 —— 用户的疑问正是"是不是搜错了"。
    private func noLyricsSourceRow(_ source: String, found: LyricsSearchService.TrackFoundNoLyrics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.blue)
                Text(sourceDisplayName(source))
                Spacer()
                Text(L10n.t("已匹配，无歌词"))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            // 源一个元数据都没给时 noLyricsMatchDescription 返回空串 —— 那时整行不显示,
            // 别留一条占着 spacing 的空 Text(状态列已经把结论说完了)。
            let matched = Self.noLyricsMatchDescription(found)
            if !matched.isEmpty {
                Text(matched)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22) // 跟上面图标对齐,不是贴着面板左缘(同 reason 那行)
            }
        }
    }

    /// "已匹配：歌名 · 歌手 · 2:47"——冒号后只列**拿得到**的那几项(各字段都可能为空,见
    /// TrackFoundNoLyrics),一项都没有时整行不显示(返回空串,调用方据此跳过)。结论右侧状态列已经写着
    /// 「已匹配，无歌词」,这一行只交代匹配到的是哪一条。
    static func noLyricsMatchDescription(_ found: LyricsSearchService.TrackFoundNoLyrics) -> String {
        var parts: [String] = []
        if !found.title.isEmpty { parts.append(found.title) }
        if !found.artist.isEmpty { parts.append(found.artist) }
        if found.durationSecs > 0 {
            let total = Int(found.durationSecs.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        guard !parts.isEmpty else { return "" }
        return String(format: L10n.t("已匹配：%@"), parts.joined(separator: " · "))
    }

    private func respondedSourceRow(_ source: String) -> some View {
        let responded = respondedSources.contains(source)
        // 失败原因分两层(见 searchcli.go 的 lyricSourceFailureReasons 头注):三个源
        // (netease/musixmatch/lyricfind)特有的具体原因(限流、token 失效这类),加上任何源
        // 都可能报的传输层通用原因(dns_failed / connect_failed / server_error,分类在
        // sourcebreaker.go 的传输层失败分类)。两层都没命中才是 nil,如实只显示
        // "未返回候选",不编一个没核实过的理由。sourceFailureReasonCodes 里存的是稳定代码,经
        // LyricSourceFailureReason 翻成当前 App 界面语言的人话再显示,见该类型的头注。
        let reason = responded ? nil : sourceFailureReasonCodes[source]
            .map(LyricSourceFailureReason.text(forCode:))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: responded ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(responded ? .green : .secondary)
                Text(sourceDisplayName(source))
                Spacer()
                Text(responded ? L10n.t("已返回候选") : L10n.t("未返回候选"))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22) // 跟上面图标对齐,不是贴着面板左缘
            }
        }
    }

    /// 用户在设置里关掉的源:引擎这一轮根本没查它(enrich.go skipSource,见 enabledSources 的注释),既不是「已返回候选」
    /// 也不是「未返回候选」,别并进「未返回候选」。
    /// 空心减号 + 第三级灰,比「未返回候选」的叉再退一级:它不是结果。不给失败原因(引擎的
    /// lyricSourceFailureReasons 对没开的源不发代码)。文案复用账号页那条「未启用」;悬停说明在哪开。
    private func disabledSourceRow(_ source: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
            Text(sourceDisplayName(source))
                .foregroundStyle(.secondary)
            Spacer()
            Text(L10n.t("未启用"))
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .help(L10n.t("已在「设置 → 歌词 → 歌词来源」中关闭，本轮未查询"))
    }

    // 未返回候选的源,查得到具体原因的那几个——给 sourceAvailabilityList
    // 那颗弹出面板用,见 LyricsSearchService.SearchUpdate.sourceFailureReasonCodes 的注释。
    @State private var sourceFailureReasonCodes: [String: String] = [:]

    @State private var isSearching = false
    // 已经回来几个源 / 一共几个 —— 只用来在"还在搜"的提示后面缀一个 (X/Y),让干等的时候
    // 知道进度在动。总数为 0(还没收到任何一行)时不显示,不写成 (0/0)。
    @State private var sourcesDone = 0
    @State private var sourcesTotal = 0
    // 第几轮全源检索(引擎兜底轮每轮重扫 9 个源),给 searchProgressSuffix 的
    // 轮次前缀用,语义见 LyricsSearchService.SearchUpdate.round。
    @State private var searchRound = 1
    // searchGeneration:第几轮搜索。load() 有三个入口(.task 首次进入、「重新搜索」按钮、输入框 .onSubmit),
    // 上一轮没结束时都能开下一轮。每轮发一个自增序号,进度回调和收尾都先核对自己还是不是最新那一轮,不是就整段丢弃:
    // 不然慢的旧一轮后返回会把新查询词的候选盖掉,还把 isSearching 提前关掉。
    @State private var searchGeneration = 0
    /// 候选封面的预热:每批候选到达时换成新的一份,换轮次、关面板时取消。
    @State private var coverPrewarm: Task<Void, Never>?
    @State private var loadError: String?
    /// 这一轮的请求是不是全部失败(引擎侧统计,见 LyricsSearchService.SearchUpdate):一个候选都没有时,据此把
    /// 「网络不通」跟「这首歌没有网络歌词」分开说。
    @State private var networkLooksDown = false
    /// 有源明确说这首是纯音乐(SearchUpdate.instrumental):一个候选都没有时单独说,不跟「都没找到」共用一句。
    @State private var instrumental = false
    /// 曲库里有这首歌、但平台上没有歌词文本的那几个源(SearchUpdate.tracksFoundNoLyrics):匹配是对的,空状态里说清
    /// 是哪几个源、匹配到了哪一条,别跟「都没找到」共用一句。
    @State private var tracksFoundNoLyrics: [LyricsSearchService.TrackFoundNoLyrics] = []
    /// 选中的候选的 id(搜索结果就是来源名,存着的那一版见 Candidate.id)。
    @State private var selectedSource: String?
    /// selectedSource 现在的值是用户自己选的(点了一行或按了方向键)。还是自动选的时候,每来一批候选都重新评估一次
    /// 该选哪条(在用的那条不一定第一批就到);用户选过之后不再自动改选。
    @State private var userPickedSource = false

    // 候选列表的点选、方向键都经这层 Binding 写回,只有经这层写回的(用户点了一行或按了方向键)
    // 才会把 userPickedSource 标记为 true;代码自己改选中(load 里的自动选)直接写 selectedSource。
    private var selectedSourceBinding: Binding<String?> {
        Binding(
            get: { selectedSource },
            set: { newValue in
                selectedSource = newValue
                userPickedSource = true
            }
        )
    }

    // 可编辑的查询关键词,初始值取自 originalXxx——默认就是"现有逻辑"那套查询。
    @State private var artist: String
    @State private var title: String
    @State private var album: String

    init(artist: String, title: String, album: String, songKey: String, currentSource: String?, currentFingerprint: String? = nil,
         durationSecs: Double, keepsOpenAfterApply: Bool = false, standaloneWindow: Bool = false,
         isMarkedInstrumental: Bool, onSetInstrumental: @escaping (Bool) async -> Bool,
         onAutoMatch: @escaping (@escaping (Int, Int) -> Void) async -> LyricsRematch.Line?,
         onApply: @escaping (LyricsSearchService.Candidate) async -> Bool) {
        self.originalArtist = artist
        self.originalTitle = title
        self.originalAlbum = album
        self.songKey = songKey
        self.currentSource = currentSource
        self.currentFingerprint = currentFingerprint
        self.durationSecs = durationSecs
        self.keepsOpenAfterApply = keepsOpenAfterApply
        self.standaloneWindow = standaloneWindow
        self.isMarkedInstrumental = isMarkedInstrumental
        self.onSetInstrumental = onSetInstrumental
        self.onAutoMatch = onAutoMatch
        self.onApply = onApply
        self._artist = State(initialValue: artist)
        self._title = State(initialValue: title)
        self._album = State(initialValue: album)
    }

    private var isDirty: Bool {
        artist != originalArtist || title != originalTitle || album != originalAlbum
    }

    /// 从歌词管理 / 歌词窗口弹出的 sheet(不是悬浮窗 ⚙ 的独立小窗)。sheet 里的玻璃一直是失焦那一档,侧栏和玻璃
    /// 按钮改画设计系统的替身(决策 57)。
    private var presentedAsSheet: Bool { !standaloneWindow }

    /// 这首歌眼下是不是标成了纯音乐:面板里切过就认切过之后的,没切过认宿主给的。
    private var markedInstrumental: Bool { instrumentalOverride ?? isMarkedInstrumental }

    /// 「这次搜索是为哪首歌开的」——三个原始字段拼成的标识,给下面 `.task(id:)` / `.onChange`
    /// 用。三个入口里,歌词管理(`sheet(isPresented:)`)与歌词窗口(`sheet(item:)`)在面板存活
    /// 期间它不会变;只有悬浮窗 ⚙ 的独立小窗
    /// (`LyricsQuickSearchWindow`)会在窗口开着期间换歌再点一次时把新曲目喂进来。
    private var searchSubject: String {
        originalArtist + "\u{1F}" + originalTitle + "\u{1F}" + originalAlbum
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .padding(.leading, Self.panelInset)
                .padding(.vertical, Self.panelInset)
            detail
        }
        // 独立小窗的标题栏是透明的(场景挂 .windowStyle(.hiddenTitleBar)),内容铺到最顶上,红绿灯压在侧栏
        // 顶部那一截里;sheet 没有标题栏,这句不改什么。
        .ignoresSafeArea()
        .frame(minWidth: Self.minimumSize.width, idealWidth: Self.defaultSize.width, maxWidth: .infinity,
               minHeight: Self.minimumSize.height, idealHeight: Self.defaultSize.height, maxHeight: .infinity)
        // 从歌词管理 / 歌词窗口弹出的这张是 sheet,AppKit 给 sheet 的默认 styleMask 里没有 .resizable,
        // 窗口边缘对拖拽完全没反应:这颗探针把标志插回去,同时把最小尺寸写进窗口(同 WindowDragHandle
        // 的路子:垫在背景层拿到底层 NSWindow)。上面的 frame 要带 maxWidth / maxHeight: .infinity,
        // 不然窗口拖大了内容仍停在最小尺寸。
        .background(WindowResizeEnabler(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height))
        // 悬浮窗 ⚙ 的独立小窗是 `if let context { LyricsSearchSheet(...) }`,开着时换歌再点一次会把新 context 喂进来,
        // 而 Optional 从 A 换成 B 是同一个视图身份:@State 不会重取 initialValue,`.task {}` 也不会重跑。换歌时这里把
        // 查询词、采纳记录重置,搜索挂在 `.task(id: searchSubject)` 上;不然面板留着上一首的候选,onApply 却已经捕获
        // 新曲目的 key,采纳会把上一首的歌词写进这一首。
        // 别改成让宿主 `.id(context.key)` 整棵重建:重建时新面板的 .task 先起、旧面板的任务取消与 onDisappear 后到,
        // 两边的收尾交错。`.task(id:)` 先取消旧任务再起新任务;`.onChange` 在更新阶段同步触发,load() 起跑时查询词
        // 已经是新曲目的。
        .onChange(of: searchSubject) { _, _ in
            subjectGeneration += 1
            artist = originalArtist
            title = originalTitle
            album = originalAlbum
            // 换了歌,上一首采纳过什么跟这一首无关;回声也别留着误导。
            appliedSource = nil
            appliedFingerprint = nil
            applyFeedback = nil
            instrumentalOverride = nil
            autoMatchLine = nil
        }
        .onChange(of: currentSource) { _, _ in
            appliedSource = nil
            appliedFingerprint = nil
            storedCandidate = makeStoredCandidate()
        }
        .onChange(of: currentFingerprint) { _, _ in
            appliedSource = nil
            appliedFingerprint = nil
            storedCandidate = makeStoredCandidate()
        }
        .onChange(of: isMarkedInstrumental) { _, _ in instrumentalOverride = nil }
        .onChange(of: selectedSource) { _, _ in revealSelection() }
        .task(id: searchSubject) { await load() }
        // 关闭/采纳/Esc 任何一条退出路径都把还在跑的引擎子进程停掉 —— 不停的话
        // 它会继续对九个源发请求直到 20 秒兜底,NDJSON 还在往已消失的视图里灌
        // (search 内的 withTaskCancellationHandler 是第二层,取消幂等,两层谁先到都行)。
        // 只停这个面板自己发起的那一轮,另一扇窗里的搜索、详情页在跑的自动匹配不受影响。
        .onDisappear {
            LyricsSearchService.shared.cancelRunning(for: searchOwner)
            coverPrewarm?.cancel()
        }
    }

    // MARK: - 侧栏(查询词 + 候选)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if standaloneWindow {
                // 独立小窗的红绿灯落在这一截里;垫拖拽区,按住这里能拖窗口。高度让查询卡从标题栏(连工具栏
                // 66pt)下面开始:那一条是系统的拖拽区,在里面按住拖动挪的是窗口,输入框里拖选文字会变成拖窗口。
                Color.clear
                    .frame(height: 48)
                    .background(WindowDragHandle())
            }
            queryCard
            searchActions
            currentSection
            candidatesHeader
            candidatesSection
            reportLyricsLink
        }
        .padding(.horizontal, 12)
        .padding(.top, standaloneWindow ? 0 : 12)
        // 列表滚到底时别把行画到侧栏圆角外面。
        .clipShape(RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous))
        .settingsCardBackground(cornerRadius: Self.panelCornerRadius, inSheet: presentedAsSheet)
    }

    /// 「找不到对的歌词？」:打开 GitHub 的歌词类 issue 表单,歌名、歌手、专辑、现在用的来源、这一轮返回了候选的来源已经
    /// 填好(见 14 章决策 59)。歌曲信息用打开面板时那首歌的,不用改过的查询词。
    private var reportLyricsLink: some View {
        Button {
            FeedbackReporter.openLyricsIssue(FeedbackLinks.LyricsReport(
                song: originalTitle, artist: originalArtist, album: originalAlbum,
                source: reportedCurrentSource,
                answered: Self.allLyricSourceNames.filter(respondedSources.contains).map(sourceDisplayName)
                    .joined(separator: L10n.t("、"))))
        } label: {
            Label(L10n.t("找不到正确的歌词？在 GitHub 反馈"), systemImage: "exclamationmark.bubble")
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.horizontal, 4)
        .padding(.bottom, 10)
    }

    /// 歌词反馈里「现在用的来源」,跟「当前使用」徽标同一个判据:本次面板里采纳过就是刚采纳的那条;标成纯音乐时这首
    /// 没有在用的歌词,留空。
    private var reportedCurrentSource: String {
        guard !markedInstrumental, let source = effectiveCurrentSource, !source.isEmpty else { return "" }
        return sourceDisplayName(source)
    }

    // 三个可编辑的查询维度——默认展示这首歌本身的元数据,.task(id:) 直接拿这三个初始值发起搜索;
    // 改了之后要显式点"重新搜索"(或者在任一输入框按下 Enter)才会真的重新发起查询,不会敲一个字就
    // 发一次网络请求。一栏一行:栏名在左(框里有内容时占位文字就看不见了,单看内容分不清哪栏是歌名
    // 哪栏是专辑),输入框占满剩下的宽度;栏名那一列由 Grid 对齐、宽度跟着最长的栏名走(英文的
    // Artist / Album 比中文长)。挂 help:很长的歌名 / 专辑在侧栏里装不下,悬停看全文。
    private var queryCard: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            queryRow(L10n.t("歌名"), text: $title)
            Divider()
            queryRow(L10n.t("歌手"), text: $artist)
            Divider()
            queryRow(L10n.t("专辑"), text: $album)
        }
        .padding(.horizontal, 12)
        .background(shape.fill(Color.primary.opacity(0.045)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .onSubmit { Task { await load() } }
    }

    private func queryRow(_ label: String, text: Binding<String>) -> GridRow<some View> {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .accessibilityLabel(label)
                .help(text.wrappedValue)
                .frame(minHeight: 32)
        }
    }

    // 搜索途中也允许再点:上一轮会被 load() 里的 searchGeneration 判作废,子进程
    // 也会被 LyricsSearchService 按同一发起方顶掉、杀掉。改了关键词却要等上一轮跑完
    // (最长 20 秒)才能重搜,是没道理的等待。
    private var searchActions: some View {
        HStack(spacing: 8) {
            Button { Task { await load() } } label: {
                Label(L10n.t("重新搜索"), systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .settingsGlassButtons(inSheet: presentedAsSheet)
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            if isDirty {
                Button(L10n.t("恢复原信息")) {
                    artist = originalArtist
                    title = originalTitle
                    album = originalAlbum
                }
                .buttonStyle(.link)
            }
        }
    }

    /// 候选列表的表头:「候选 N」,右边是歌词源可用情况徽标,下面一行是搜索进度(右边不另放)。整块一打开就在、
    /// 高度不变:候选陆续到达、搜完收起进度时,下面的列表都不跳。
    private var candidatesHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.t("候选"))
                    .font(.headline)
                Text("\(searchResults.count)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                sourceAvailabilityBadge
            }
            // 一条候选都还没到时说「正在查询」,到了几条之后说「其它源仍在搜索」;搜完这一行留空,高度照留。
            HStack(spacing: 6) {
                if isSearching {
                    ProgressView().controlSize(.small)
                    Text((candidates.isEmpty ? L10n.t("正在查询各个歌词源…") : L10n.t("其他歌词源仍在搜索中…"))
                         + searchProgressSuffix)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 18)
        }
        .padding(.top, 6)
        .padding(.horizontal, 4)
    }

    /// 「当前使用」那一块:这首现在用的那一版单独摆在候选表头上面,跟搜索结果分开。没有在用的歌词时整块不出。
    @ViewBuilder
    private var currentSection: some View {
        if let current = currentShown {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("当前使用"))
                    .font(.headline)
                    .padding(.horizontal, 4)
                candidateRow(current)
            }
            .padding(.top, 6)
        }
    }

    /// 侧栏下半截。有搜索结果时是列表,中途出错的一行提示挂在列表上面。一条搜索结果都没有时:右边有「当前使用」那条的
    /// 预览,搜完的结论挂在这里(`searchConclusion`);连那条都没有时右边是整页的结论(detailContent)。
    @ViewBuilder
    private var candidatesSection: some View {
        if let msg = loadError, !shownCandidates.isEmpty {
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .padding(.horizontal, 4)
        }
        if searchResults.isEmpty {
            searchConclusion
            Spacer(minLength: 0)
        } else {
            candidateList
        }
    }

    /// 搜完、除了「当前使用」那条没有别的候选时,侧栏里一张小卡说这一轮的结论。判断顺序同 detailContent 的空状态;
    /// 右边被那条的预览占着,整页的空状态出不来。见 11 章决策 102。
    @ViewBuilder
    private var searchConclusion: some View {
        if !isSearching, loadError == nil, searchResults.isEmpty, currentShown != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !candidates.isEmpty {
                    conclusionTitle(L10n.t("搜索结果只有现在使用的这一份"), systemImage: "checkmark.circle")
                } else if networkLooksDown {
                    conclusionTitle(L10n.t("无法连接任何歌词源"), systemImage: "wifi.slash")
                } else if !unreachableSourcesByCode.isEmpty {
                    let groups = unreachableSourcesByCode
                    let unreachableCount = groups.reduce(0) { $0 + $1.sources.count }
                    conclusionTitle(sourcesTotal > 0 && unreachableCount >= sourcesTotal
                                    ? L10n.t("所有歌词源均无法连接")
                                    : String(format: L10n.plural("%@ 个歌词源无法连接", count: unreachableCount),
                                             "\(unreachableCount)"),
                                    systemImage: "wifi.exclamationmark")
                    ForEach(groups, id: \.code) { group in
                        Self.transportFailureLine(group.code, sources: group.sources)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if instrumental {
                    conclusionTitle(L10n.t("有歌词源将这首歌曲标记为纯音乐，无可用的候选歌词"), systemImage: "waveform")
                } else if !tracksFoundNoLyrics.isEmpty {
                    let names = tracksFoundNoLyrics.map { sourceDisplayName($0.source) }.joined(separator: "、")
                    conclusionTitle(String(format: L10n.t("%@ 已匹配到该曲目，无歌词文本"), names), systemImage: "music.note.list")
                } else {
                    conclusionTitle(L10n.t("已启用的歌词源均未找到可用的候选"), systemImage: "text.badge.xmark")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }

    private func conclusionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 候选列表。不用 `List`:选中底要画成侧栏这一套的圆角浅底,`List` 的系统选中在列表拿到焦点时换成
    /// 实心强调色、字变白,行里彩色的来源名和标签会被盖住。方向键换行由 onMoveCommand 接,点一行就把焦点
    /// 交给列表。
    private var candidateList: some View {
        let layout = sidebarLayout
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(layout.main) { c in
                        candidateRow(c)
                            .id(c.id)
                    }
                    if !layout.same.isEmpty {
                        groupHeader(L10n.t("内容与其他候选相同"), count: layout.same.count, expanded: $showsSameGroup,
                                    help: L10n.t("歌词文字和每行时间都与列表中的某条候选相同，也没有多出逐字时间轴、译文或读音"))
                        if layout.sameExpanded {
                            ForEach(layout.same) { c in
                                candidateRow(c)
                                    .id(c.id)
                            }
                        }
                    }
                    if !layout.excluded.isEmpty {
                        groupHeader(L10n.t("不可用"), count: layout.excluded.count,
                                    expanded: layout.excludedForced ? nil : $showsExcludedGroup,
                                    help: L10n.t("评分时被排除的候选（如无时间戳、语言或时长不符），自动匹配不会选用；仍可预览和采用"))
                        if layout.excludedExpanded {
                            ForEach(layout.excluded) { c in
                                candidateRow(c)
                                    .id(c.id)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
                .focusable()
                .focused($candidateListFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in moveSelection(direction, proxy: proxy) }
            }
        }
    }

    /// 「当前使用」那一块摆的:搜索结果里有同一份(来源和正文都一样)就是搜到的那条(带分数),否则是缓存里存着的那一版。
    private var currentShown: LyricsSearchService.Candidate? {
        if let hit = candidates.first(where: isCurrentCandidate) { return hit }
        guard let stored = storedCandidate, isCurrentCandidate(stored) else { return nil }
        return stored
    }

    /// 候选列表摆的:这一轮的搜索结果,去掉已经摆进「当前使用」的那条。
    private var searchResults: [LyricsSearchService.Candidate] {
        guard let current = currentShown else { return candidates }
        return candidates.filter { $0.id != current.id }
    }

    /// 侧栏的分组:「当前使用」那条,列表里正常的一组,两个折叠组(LyricsCandidateGroups)和它们展没展开。
    private struct SidebarLayout {
        var current: LyricsSearchService.Candidate?
        var main: [LyricsSearchService.Candidate] = []
        var same: [LyricsSearchService.Candidate] = []
        var excluded: [LyricsSearchService.Candidate] = []
        var sameExpanded = false
        var excludedExpanded = false
        /// 除了「不可用」那一组没有别的可看:那一组一直展开,组头不给收起。
        var excludedForced = false

        /// 屏上看得见的,按屏上顺序。
        var visible: [LyricsSearchService.Candidate] {
            (current.map { [$0] } ?? []) + main + (sameExpanded ? same : []) + (excludedExpanded ? excluded : [])
        }
    }

    private var sidebarLayout: SidebarLayout {
        var layout = SidebarLayout(current: currentShown)
        let groups = LyricsCandidateGroups.groups(
            candidates.map {
                LyricsCandidateGroups.Traits(
                    source: $0.source, excluded: Self.isExcluded($0), hasWordTiming: $0.hasWordTiming,
                    hasTranslation: $0.hasTranslation, hasRomanization: $0.hasRomanization)
            },
            duplicates: duplicates)
        for c in searchResults {
            switch groups[c.source] ?? .main {
            case .main: layout.main.append(c)
            case .sameAsAnother: layout.same.append(c)
            case .excluded: layout.excluded.append(c)
            }
        }
        layout.sameExpanded = showsSameGroup
        layout.excludedForced = layout.current == nil && layout.main.isEmpty && layout.same.isEmpty
        layout.excludedExpanded = showsExcludedGroup || layout.excludedForced
        return layout
    }

    /// 评分时被排除(分数 -1,`scoreTerms` 第一项是原因)。存着的那一版没有分数,不算。
    private static func isExcluded(_ c: LyricsSearchService.Candidate) -> Bool {
        !c.isStored && (c.score < 0 || c.scoreTerms.first?.isRejection == true)
    }

    /// 侧栏里看得见、能选的,按屏上的顺序:「当前使用」那条在前,搜索结果在后,收起的组不算。↑ / ↓ 换行按它。
    private var shownCandidates: [LyricsSearchService.Candidate] {
        sidebarLayout.visible
    }

    /// 右边预览的那一条:选中的那条(在收起的组里也算),还没选中任何一条时是看得见的第一条。列表里画选中底的也是它。
    /// 选中的是存着的那一版、而它已经换成搜到的同一份时,落到搜到的那一条上。
    private var previewedCandidate: LyricsSearchService.Candidate? {
        let current = currentShown
        if let hit = ((current.map { [$0] } ?? []) + searchResults).first(where: { $0.id == selectedSource }) { return hit }
        if selectedSource != nil, selectedSource == storedCandidate?.id, let current { return current }
        return shownCandidates.first
    }

    /// 选中的那条落在收起的组里(自动选中、或者后到的候选把它挤进了组)时把那一组展开,列表里看得见选中底。
    private func revealSelection() {
        guard let id = selectedSource else { return }
        let layout = sidebarLayout
        if !layout.sameExpanded, layout.same.contains(where: { $0.id == id }) { showsSameGroup = true }
        if !layout.excludedExpanded, layout.excluded.contains(where: { $0.id == id }) { showsExcludedGroup = true }
    }

    /// 折叠组的组头,点一下展开 / 收起。`expanded` 为 nil 时这一组一直展开,只画组名和条数。
    private func groupHeader(_ title: String, count: Int, expanded: Binding<Bool>?, help: String) -> some View {
        let label = HStack(spacing: 6) {
            if let expanded {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
            }
            Text(title)
            Text("\(count)")
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        return Group {
            if let expanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
                } label: {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
        .help(help)
    }

    /// 点一行:经 selectedSourceBinding 写回(记下"用户点过",之后不再自动改选),并把焦点交给列表。
    private func select(_ id: String) {
        selectedSourceBinding.wrappedValue = id
        candidateListFocused = true
    }

    /// ↑ / ↓ 换到上一条 / 下一条,跟点选同一条写回路径;滚到刚好露出那一行。
    private func moveSelection(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let shown = shownCandidates
        guard let current = shown.firstIndex(where: { $0.id == previewedCandidate?.id }) else { return }
        let next: Int
        switch direction {
        case .up: next = current - 1
        case .down: next = current + 1
        default: return
        }
        guard shown.indices.contains(next) else { return }
        let id = shown[next].id
        selectedSourceBinding.wrappedValue = id
        proxy.scrollTo(id)
    }

    /// 缓存里这首现在存着的那一版,做成一条候选(没有分数)。条目读不全、标成纯音乐、没有正文、不知道来源时没有。
    /// 只有纯文本时按纯文本候选摆。
    private func makeStoredCandidate() -> LyricsSearchService.Candidate? {
        guard let source = currentSource, !source.isEmpty,
              let entry = EnrichCacheReader.storedEntry(forKey: songKey), entry.complete, !entry.instrumental
        else { return nil }
        let plainOnly = entry.lyrics.isEmpty
        let text = plainOnly ? entry.plainLyrics : entry.lyrics
        guard !text.isEmpty else { return nil }
        // 引擎预生成的读音不算这一版自带的(搜到的同一份候选也不带),预览的「原文 + 读音」照样按设置现算。
        let roma = plainOnly ? "" : LyricsRomanization.sourceProvidedRomanization(entry.lyricsRoma, lyrics: text)
        return LyricsSearchService.Candidate(
            source: source, lyrics: text,
            lyricsTr: plainOnly ? "" : entry.lyricsTr, lyricsRoma: roma,
            lyricsYRC: plainOnly ? "" : entry.lyricsYRC, lyricsBG: "", lyricsTrLang: "",
            hasWordTiming: !plainOnly && !entry.lyricsYRC.isEmpty, score: 0, scoreTerms: [],
            title: originalTitle, artist: originalArtist, album: originalAlbum,
            coverURL: EnrichCacheReader.coverURL(artist: originalArtist, title: originalTitle, album: originalAlbum),
            isPlainTextOnly: plainOnly,
            lineCount: LyricsSearchService.Candidate.countLines(of: text),
            fingerprint: ManualPickLock.fingerprint(lyrics: text),
            timeline: LyricsCandidateDuplicates.lineTimestamps(text),
            isStored: true)
    }

    // MARK: - 右侧(标题行 + 预览 / 空状态)

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailToolbar
            instrumentalBanner
            autoMatchStatus
            detailContent
        }
        // 说明条随标记出现 / 消失,按钮文字跟着换,一起过渡。
        .animation(.easeInOut(duration: 0.2), value: markedInstrumental)
    }

    /// 右侧顶上那一行:标题、回声、「标为纯音乐」,sheet 里再加「关闭」。独立小窗里这一行正好压在透明
    /// 标题栏那一截(52pt)上。
    ///
    /// 背后垫 WindowDragHandle,按住这一行能拖窗口:sheet 默认**不可拖**——AppKit 故意把它钉死在依附点,
    /// 不是漏配了 isMovableByWindowBackground 能补的(那个修饰符对 sheet 样式的窗口不生效);独立小窗的
    /// 透明标题栏整片被内容盖住,点到的是内容,也靠这块拖。垫在背景层不影响上面的按钮各自接收点击
    /// (SwiftUI 命中测试是前景优先,背景只接住前景没吃掉的点击)。
    private var detailToolbar: some View {
        HStack(spacing: 8) {
            // 放得下就是「标题 + 带文字的按钮」;右栏窄(面板拖到最窄、英文文案更长)时先收起标题,再窄才把两颗按钮
            // 收成图标(悬停说明、无障碍标签照留)——「标为纯音乐」要带文字,能留就留(决策 50)。
            ViewThatFits(in: .horizontal) {
                toolbarRow(showsTitle: true, iconOnly: false)
                toolbarRow(showsTitle: false, iconOnly: false)
                toolbarRow(showsTitle: false, iconOnly: true)
            }
            if !standaloneWindow {
                Button(L10n.t("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .settingsGlassButtons(inSheet: presentedAsSheet)
                    .fixedSize()
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .frame(height: 52)
        .background(WindowDragHandle())
        .background {
            if standaloneWindow {
                // 独立小窗不画「关闭」(左上角的红灯就是),Esc 照样关:一颗不可见的按钮接 cancelAction,
                // 同设置页 ⌘F 那颗。
                Button("") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    // candidates 陆续到达、isSearching 才是"是否还没结束"的唯一依据——不能用
    // "candidates.isEmpty"反过来判断有没有搜索完:目前为止一个候选都还没到手,不代表
    // 九个源已经查完了(可能只是跑得快的那几个还没轮到),那样会把"还在搜"误判成
    // "查完了、真的什么都没有",提前弹出"没找到候选"的空状态提示。
    @ViewBuilder
    private var detailContent: some View {
        // 已经收到候选时出错(比如后面的源把子进程带崩了)不整页换成报错:到手的候选照样能挑,报错挪到侧栏列表上方一行。
        if let msg = loadError, shownCandidates.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(msg).font(.callout).multilineTextAlignment(.center).padding(.horizontal, 40)
                Button(L10n.t("重试")) { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shownCandidates.isEmpty {
            if isSearching {
                // 还没有候选:右边空着,进度在侧栏(candidatesSection)。占满这一栏,标题行才留在顶上。
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if networkLooksDown {
                // 跟下面「查了但没有」分开:网络不通时重试多半能查到。
                ContentUnavailableView {
                    Label(L10n.t("无法连接任何歌词源"), systemImage: "wifi.slash")
                } description: {
                    Text(L10n.t("所有已启用的歌词源请求均失败，可能是网络连接问题，并不代表这首歌曲没有歌词。检查网络后可点按下方的「重试」"))
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !unreachableSourcesByCode.isEmpty {
                // 排在「网络不通」(全部请求都失败)之后、「纯音乐」之前:部分源在传输层就没打通(DNS 不答 / 连不上 /
                // 只回 5xx / 上游不可用),不是查过了没有,是没查到。一组一行列出是哪些源、为什么;其余源只说「未返回候选」,
                // 别写成「没有这首歌」:里面可能有限流的、地区限制的、被 20 秒截止砍掉的。口径同「歌词源可用情况」,
                // 每个源的整句解释在头部徽标点开的明细里。
                let groups = unreachableSourcesByCode
                let unreachableCount = groups.reduce(0) { $0 + $1.sources.count }
                // sourcesTotal 是引擎报的启用源数(未启用的源不会有代码),一个不剩才算"全都"。
                let allUnreachable = sourcesTotal > 0 && unreachableCount >= sourcesTotal
                let otherCount = max(0, sourcesTotal - unreachableCount)
                ContentUnavailableView {
                    Label(allUnreachable
                          ? L10n.t("所有歌词源均无法连接")
                          : String(format: L10n.plural("%@ 个歌词源无法连接", count: unreachableCount), "\(unreachableCount)"),
                          systemImage: "wifi.exclamationmark")
                } description: {
                    VStack(spacing: 4) {
                        ForEach(groups, id: \.code) { group in
                            // 已经是拼好的 Text(理由段加粗 + 源名段常规),别再往外套一层 Text。
                            Self.transportFailureLine(group.code, sources: group.sources)
                        }
                        if groups.contains(where: { $0.code == "dns_failed" }) {
                            Text(L10n.t("常见于 VPN 或公司网络接管 DNS 的情况；浏览器能打开网页并不代表此处可以连接"))
                        }
                        if instrumental {
                            // 有源明确说这首是纯音乐,比「其余源未返回候选」更确定,不能被这个分支盖掉。复用纯音乐分支那句 key。
                            Text(L10n.t("有歌词源将这首歌曲标记为纯音乐，无可用的候选歌词"))
                        } else if !tracksFoundNoLyrics.isEmpty {
                            // 同理,「匹配到了曲目、没有歌词」也比「没连上」更确定,补一行。这里只放得下一句,不用标签-值那张表,
                            // 用词跟主分支同一套(已匹配 / 无歌词文本)。
                            let names = tracksFoundNoLyrics.map { sourceDisplayName($0.source) }
                                .joined(separator: "、")
                            Text(String(format: L10n.t("%@ 已匹配到该曲目，无歌词文本"), names))
                        } else if !allUnreachable {
                            Text(String(format: L10n.plural("其余 %@ 个源未返回候选", count: otherCount), "\(otherCount)"))
                        }
                    }
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if instrumental {
                // 排在"无法连接任何歌词源"之后、笼统兜底之前:这是比"真没搜到"更确定的结论——
                // 至少一个源明确断言过"这首歌没有词"(见 instrumental 声明处注释),不是
                // 九个源都交白卷说不出理由,不该跟那种情况共用同一句轻描淡写的"没找到"。
                // 文案复用「重新自动匹配」toast 三分支(LyricsManagerView.swift)已经在用的
                // 同一条 L10n key,同一个结论在两处别各写一套措辞。
                ContentUnavailableView {
                    Label(L10n.t("纯音乐"), systemImage: "waveform")
                } description: {
                    Text(L10n.t("有歌词源将这首歌曲标记为纯音乐，无可用的候选歌词"))
                } actions: {
                    markInstrumentalAction
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !tracksFoundNoLyrics.isEmpty {
                // 排在「纯音乐」之后、笼统兜底之前:有源匹配到了这首歌、只是平台上没有歌词文本(见 tracksFoundNoLyrics)。
                // 命中的那几个源可以把话说死,其余源只说「未返回候选」,别替它们下「没收录这首歌」的判断(口径同「歌词源
                // 可用情况」)。标题给结论、正文给标签-值对,不写成句子,也不写「过一阵会补上词」这类无法保证的建议。
                let sources = tracksFoundNoLyrics.map { sourceDisplayName($0.source) }
                    .joined(separator: "、")
                let otherCount = max(0, sourcesTotal - tracksFoundNoLyrics.count)
                ContentUnavailableView {
                    Label(L10n.t("已匹配曲目 · 无歌词文本"), systemImage: "music.note.list")
                } description: {
                    // 用 Grid,别写死标签列宽:三种语言的标签长短不一。gridColumnAlignment 设在第一行、作用于整列。
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            Text(L10n.t("已匹配，无歌词"))
                                .foregroundStyle(.tertiary)
                                .gridColumnAlignment(.trailing)
                            Text(sources)
                        }
                        if otherCount > 0 {
                            GridRow {
                                Text(L10n.t("未返回候选"))
                                    .foregroundStyle(.tertiary)
                                Text(String(format: L10n.plural("其余 %@ 个源", count: otherCount), "\(otherCount)"))
                            }
                        }
                    }
                    .padding(.top, 2)
                } actions: {
                    HStack {
                        // 跟侧栏那颗按钮同名:说的是同一件事,不该一个叫"重试"、一个叫"重新搜索"。
                        Button(L10n.t("重新搜索")) { Task { await load() } }
                        markInstrumentalAction
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L10n.t("已启用的歌词源均未找到可用的候选"), systemImage: "text.badge.xmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let c = previewedCandidate {
            previewPane(c)
        }
    }

    private func candidateRow(_ c: LyricsSearchService.Candidate) -> some View {
        let isSelected = c.id == previewedCandidate?.id
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        // 标签排放在"封面+文字"这一整条 HStack **下面**、贴着整行的左缘(也就是封面的左缘,不是文字的
        // 左缘)——不管这一行标题/歌手·专辑多长、封面下面空多少,标签排永远钉在同一个 x、同一个
        // "这一行内容结束后"的 y,一列看下来是一条直线。
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                coverThumbnail(c.coverURL, size: 42, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    // 第一行放这个候选**实际匹配到的歌名**,不放来源名 —— 挑候选时最要紧的
                    // 判断是"这条到底对上了哪首歌/哪个版本",来源只是附带信息。
                    candidateMatchInfo(c, titleFont: .body.weight(.medium))
                    metaLine(c, font: .caption2)
                        .padding(.top, 1)
                }
                Spacer(minLength: 0)
                // 来源标钉在每行**右上角**,不混在下面那排标签里:那几个标签说的是"这条候选有什么"
                // (越多越好的加分项),来源说的是"这条是谁给的"(身份),身份钉在行的右上角、各行右缘
                // 对齐,扫起来最省事;混在标签排里的话,它前面站着几个标签全看这条候选的成色,每行落在
                // 不同的 x。
                //
                // `fixedSize()`:侧栏里一行只有约 350pt 宽,不钉住的话 SwiftUI 会先压这个胶囊(「网易云
                // 音乐」折成两行、「Musixmatch」被截成「Musixmat…」)。来源名截半个字等于没标,宁可让上面的
                // 歌名先换行——它本来就允许两行 + 悬停看全文。
                sourceBadge(c.source)
                    .fixedSize()
            }
            // showsSource: false —— 这一处的来源标已经在上面的右上角了,别在标签排里再来一遍。
            characteristicBadges(c, source: c.source, showsSource: false, isCurrent: isCurrentCandidate(c),
                                 duplicate: c.isStored ? nil : duplicates[c.source])
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .background(shape.fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(shape)
        // 整行可点;分数旁的问号自己接点击(QuickHelpLabel),子视图的手势先于这里。
        .onTapGesture { select(c.id) }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// 这首歌眼下实际生效的来源:本次面板里采纳过就是刚采纳的那条,否则是打开时的快照。
    private var effectiveCurrentSource: String? { appliedSource ?? currentSource }
    /// 跟 effectiveCurrentSource 配对:采纳过就是刚采纳那条的指纹,否则是打开时调用方算的。
    private var effectiveCurrentFingerprint: String? { appliedSource != nil ? appliedFingerprint : currentFingerprint }

    private func isCurrentCandidate(_ c: LyricsSearchService.Candidate) -> Bool {
        // 标成纯音乐时这首没有在用的歌词。
        guard !markedInstrumental else { return false }
        return LyricsCandidateDuplicates.isCurrent(
            candidateSource: c.source, candidateFingerprint: c.fingerprint,
            currentSource: effectiveCurrentSource, currentFingerprint: effectiveCurrentFingerprint)
    }

    /// source → 排在它前面、跟它一样的那个源(LyricsCandidateDuplicates.firstMatches)。候选最多九条,
    /// 每次 body 算一遍不贵;指纹和每行时间都在 Candidate 构造时算好了。
    private var duplicates: [String: LyricsCandidateDuplicates.Match] {
        LyricsCandidateDuplicates.firstMatches(
            candidates.map { (source: $0.source, fingerprint: $0.fingerprint, timeline: $0.timeline) })
    }

    private func applyButtonTitle(for c: LyricsSearchService.Candidate) -> String {
        if applyingSource == c.source { return L10n.t("正在采用…") }
        // 选中的就是这首现在在用的那一份:按钮只说明状态,另挂 .disabled(isCurrentCandidate(c)) 点不了(11 章决策 55)。
        if isCurrentCandidate(c) { return L10n.t("当前使用") }
        // 纯文本那条采纳后不会跟播放逐字 / 逐行同步,按钮文案说清楚。
        return c.isPlainTextOnly ? L10n.t("采纳为静态文本") : L10n.t("采用此候选")
    }

    /// 「采用此候选」的整条流程(等调用方写完再收尾,而不是 `onApply(c); dismiss`
    /// 一把关掉——那样写盘在背后跑、面板上什么反馈都没有):
    /// ① 防重入 —— 写盘 + 排引擎重启在飞时不再叠一笔,按钮禁用、文案变「正在采用…」;
    /// ② 等待期间换了歌(小窗再按一次热键会换 context)这一笔写的是上一首,不挪徽标、不回声;
    /// ③ 成功 → `appliedSource` 挪「当前使用」徽标;关窗模式到此关窗(失败也关,调用方那边
    ///    的 lastError 红字负责说明),留着的模式给标题栏一条回声、不重搜 —— 候选本来就在。
    private func apply(_ c: LyricsSearchService.Candidate) async {
        guard applyingSource == nil, !autoMatching else { return }
        // 比 @State 里的代数,不比 searchSubject:这个方法跑在按钮闭包捕获的那份视图副本上,副本的 let 属性
        // 永远是旧值,前后比较恒等;@State 读的是共享存储,换了歌(onChange(of: searchSubject))这里看得见。
        let subject = subjectGeneration
        applyingSource = c.source
        let saved = await onApply(c)
        applyingSource = nil
        guard subject == subjectGeneration else { return }
        if saved {
            appliedSource = c.source
            appliedFingerprint = c.fingerprint
            autoMatchLine = nil
            // 存进歌词时引擎顺带撤掉纯音乐标记(enrichedit.go 的 save_edit / save_plain_text)。
            instrumentalOverride = false
        }
        guard keepsOpenAfterApply else {
            dismiss()
            return
        }
        if saved {
            let name = sourceDisplayName(c.source)
            showApplyFeedback(String(format: L10n.t("已采用 %@ 的歌词"), name), ok: true)
        } else {
            showApplyFeedback(L10n.t("保存失败，请重试"), ok: false)
        }
    }

    /// 标题行左半边(标题、回声)加两颗按钮,`detailToolbar` 按放不放得下挑一档。回声的理想宽度记 0:它不参与
    /// 「放不放得下」的判断,占剩下的地方,太长就自己截断,不会把按钮挤成图标。按钮(连「关闭」)都按完整宽度排
    /// (`fixedSize`):不然同一行里那块可伸缩的回声区会跟它们平分宽度,先把按钮压成「重新自动…」,`ViewThatFits`
    /// 量出来的「放得下」也就跟实际排出来的对不上。
    private func toolbarRow(showsTitle: Bool, iconOnly: Bool) -> some View {
        HStack(spacing: 8) {
            if showsTitle {
                Text(L10n.t("搜索候选歌词"))
                    .font(.headline)
                    .fixedSize()
            }
            ZStack(alignment: .leading) {
                applyFeedbackView
            }
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            autoMatchButton(iconOnly: iconOnly)
            instrumentalButton(iconOnly: iconOnly)
        }
    }

    /// 标题行按钮的标签:`iconOnly` 时只留图标(标题仍是无障碍标签)。
    @ViewBuilder
    private func toolbarLabel(_ title: String, systemImage: String, iconOnly: Bool) -> some View {
        if iconOnly {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    /// 右侧标题行里标 / 撤「纯音乐」的按钮:图标 + 文字,文字写的是点下去会做什么;标没标上由下面的 `instrumentalBanner` 说。
    /// 标上之后这首按纯音乐处理:各处不显示歌词,也不再自动搜歌词;歌词留在缓存里,撤掉就回来。有没有搜到候选都在:
    /// 没搜到不等于纯音乐,标不标由用户定。图标跟歌词管理详情页那对按钮同一组(pianokeys / pianokeys.inverse)。
    private func instrumentalButton(iconOnly: Bool) -> some View {
        Button {
            let value = !markedInstrumental
            Task { await setInstrumental(value) }
        } label: {
            toolbarLabel(markedInstrumental ? L10n.t("取消纯音乐标记") : L10n.t("标为纯音乐"),
                         systemImage: markedInstrumental ? "pianokeys.inverse" : "pianokeys", iconOnly: iconOnly)
        }
        .help(markedInstrumental
              ? L10n.t("取消「纯音乐」标记：已有歌词的恢复显示，无歌词的重新加入自动匹配队列")
              : L10n.t("按纯音乐处理：不显示歌词，也不会自动搜索；原有歌词仍会保留，取消标记即可恢复"))
        .disabled(settingInstrumental || applyingSource != nil || autoMatching)
        .settingsGlassButtons(inSheet: presentedAsSheet)
        .fixedSize()
    }

    /// 右侧标题行里的「重新自动匹配」:交给引擎按设置里的「匹配算法」重挑一份,不用自己从列表里挑。图标、文案、
    /// 悬停说明跟歌词管理那颗一样(文案不写「智能」,理由见那边)。
    private func autoMatchButton(iconOnly: Bool) -> some View {
        Button {
            Task { await runAutoMatch() }
        } label: {
            toolbarLabel(L10n.t("重新自动匹配"), systemImage: "wand.and.stars", iconOnly: iconOnly)
        }
        .help(L10n.t("重新联网匹配，直接采用算法选出的结果，依据设置中的「匹配算法」"))
        .disabled(autoMatching || applyingSource != nil || settingInstrumental)
        .settingsGlassButtons(inSheet: presentedAsSheet)
        .fixedSize()
    }

    /// 标题行下面那一行:自动匹配跑着时是进度,跑完是结论(说法和颜色同歌词管理详情页那一行)。
    @ViewBuilder
    private var autoMatchStatus: some View {
        if autoMatching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(autoMatchTotal > 0
                     ? String(format: L10n.t("正在重新匹配…（%1$@/%2$@）"), "\(autoMatchDone)", "\(autoMatchTotal)")
                     : L10n.t("正在重新匹配…"))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        } else if let line = autoMatchLine {
            Label(LyricsRematchRunner.text(line), systemImage: LyricsRematchRunner.icon(line.tone))
                .font(.callout)
                .foregroundStyle(LyricsRematchRunner.tint(line.tone))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
        }
    }

    /// 「重新自动匹配」的整条流程:等宿主跑完一轮(进度经回调写进来)。改写了歌词时 sheet 跟采纳一样关掉(歌词管理
    /// 的编辑框、歌词窗口的正文都在背后),独立小窗留着、挂结论,「当前使用」随宿主重读挪过去;没改写时都留着、挂结论,
    /// 用户可以接着自己挑。等待期间换了歌,这一轮的结论不挂。
    private func runAutoMatch() async {
        guard !autoMatching, applyingSource == nil, !settingInstrumental else { return }
        let subject = subjectGeneration
        autoMatching = true
        autoMatchLine = nil
        autoMatchDone = 0
        autoMatchTotal = 0
        let line = await onAutoMatch { sourcesDone, sourcesTotal in
            guard subject == subjectGeneration else { return }
            autoMatchDone = sourcesDone
            autoMatchTotal = sourcesTotal
        }
        autoMatching = false
        guard subject == subjectGeneration, let line else { return }
        if LyricsRematchRunner.rewroteLyrics(line), !keepsOpenAfterApply {
            dismiss()
            return
        }
        autoMatchLine = line
    }

    /// 标成纯音乐时挂在右侧标题行下面的说明条:标没标上一眼看得出,也说清这时采用候选会怎样。卡片样式同歌词管理的
    /// `wordTimingHint`。
    @ViewBuilder
    private var instrumentalBanner: some View {
        if markedInstrumental {
            Label(L10n.t("已标为纯音乐：不显示歌词，也不会自动搜索。采用任一候选将取消标记"),
                  systemImage: "pianokeys.inverse")
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.18)))
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
                .transition(.opacity)
        }
    }

    /// 空状态里的「标为纯音乐」:有源说这首是纯音乐、或者匹配到了曲目却没有歌词文本,用户多半就在这里拍板。
    /// 已经标上就不给(标题栏下面的说明条在说)。
    @ViewBuilder
    private var markInstrumentalAction: some View {
        if !markedInstrumental {
            Button {
                Task { await setInstrumental(true) }
            } label: {
                Label(L10n.t("标为纯音乐"), systemImage: "pianokeys")
            }
            .disabled(settingInstrumental || applyingSource != nil || autoMatching)
        }
    }

    /// 写回纯音乐标记,等调用方落盘再收尾。等待期间换了歌(小窗再点一次会换 context)这一笔写的是上一首,
    /// 不改面板上的标记、不回声。
    private func setInstrumental(_ value: Bool) async {
        guard !settingInstrumental, !autoMatching else { return }
        let subject = subjectGeneration
        settingInstrumental = true
        let saved = await onSetInstrumental(value)
        settingInstrumental = false
        guard subject == subjectGeneration else { return }
        if saved {
            instrumentalOverride = value
            // 标上时不回声:标题栏下面那条说明条说的就是这件事。撤掉时说明条收起,回一声。
            if !value {
                showApplyFeedback(L10n.t("已取消纯音乐标记"), ok: true)
            }
        } else {
            showApplyFeedback(L10n.t("保存失败，请重试"), ok: false)
        }
    }

    private func showApplyFeedback(_ text: String, ok: Bool) {
        applyFeedbackGeneration += 1
        let generation = applyFeedbackGeneration
        withAnimation { applyFeedback = ApplyFeedback(text: text, ok: ok) }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard generation == applyFeedbackGeneration else { return }
            withAnimation { applyFeedback = nil }
        }
    }

    /// 右侧标题行里的回声:「已采用 X 的歌词」/「未能保存」,2.5 秒后自己消失。放标题行而不是另起一层
    /// toast 浮层:这个面板没有第二层浮层机制,标题后面那段本来就是空的,而且它跟「当前使用」徽标
    /// 的移动同一刻出现。
    @ViewBuilder
    private var applyFeedbackView: some View {
        if let applyFeedback {
            Label(applyFeedback.text,
                  systemImage: applyFeedback.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(applyFeedback.ok ? Color.secondary : Color.orange)
                .lineLimit(1)
                .padding(.leading, 8)
                .transition(.opacity)
        }
    }

    private func previewPane(_ c: LyricsSearchService.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                coverThumbnail(c.coverURL, size: 76, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    candidateMatchInfo(c, titleFont: .title2.weight(.semibold), detailFont: .callout)
                    metaLine(c, font: .caption)
                        .padding(.top, 2)
                }
                Spacer(minLength: 12)
                // 纯文本那条写「采纳为静态文本」(applyButtonTitle):点下去之前按钮本身就说清楚,不只靠警示标签。
                Button(applyButtonTitle(for: c)) {
                    Task { await apply(c) }
                }
                .controlSize(.large)
                .settingsProminentGlassButton(tint: isCurrentCandidate(c) ? Color.secondary : .accentColor)
                .keyboardShortcut(.return, modifiers: .command)
                .help(isCurrentCandidate(c) ? "" : L10n.t("快捷键：⌘↩"))
                .disabled(applyingSource != nil || settingInstrumental || autoMatching)
                .disabled(isCurrentCandidate(c))
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            // showsSource: true —— 右侧详情**不跟着**把来源挪去右上角:挪的收益是"多行之间对齐、好扫",
            // 而这里永远只有一条候选,没有可对齐的对象;这一行的右上角又被「采用此候选」这颗主按钮占着,
            // 塞个胶囊进去只会跟它抢视线。
            characteristicBadges(c, source: c.source, showsSource: true, isCurrent: isCurrentCandidate(c),
                                 duplicate: c.isStored ? nil : duplicates[c.source])
                .padding(.horizontal, 24)
                .padding(.top, 12)
            if c.isPlainTextOnly {
                Label(
                    L10n.t("这份歌词无时间戳，采纳后仅在「歌词窗口」中作为静态文字显示，不会随播放逐字 / 逐行高亮"),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            let rows = previewMemo.rows(c, scripts: LocalPlaybackSource.shared.romanizationScripts)
            if rows.timed {
                previewControls(rows)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            lyricsPreview(c, rows: rows)
        }
    }

    /// 正在放的就是面板里这首。
    private var isSongPlaying: Bool { nowPlaying.key == songKey }

    /// 原文 / 原文 + 译文 / 原文 + 读音(这条候选没有的那一档灰掉,悬停说为什么),正在放这首时再加「跟随播放」。
    /// 跟歌词管理详情页同一套零件。
    private func previewControls(_ rows: PreviewRows) -> some View {
        HStack(spacing: 10) {
            LyricsManagerModePicker(mode: $displayMode, shown: shownMode(rows),
                                    isAvailable: { isModeAvailable($0, rows) },
                                    unavailableHelp: { unavailableModeHelp($0, rows) })
            if isSongPlaying {
                LyricsManagerFollowButton(follow: $followPlayback)
            }
            Spacer(minLength: 0)
        }
    }

    private func isModeAvailable(_ mode: LyricsManagerDisplayMode, _ rows: PreviewRows) -> Bool {
        switch mode {
        case .original: return true
        case .translation: return rows.hasTranslation
        case .romanization: return rows.hasRomanization
        }
    }

    private func unavailableModeHelp(_ mode: LyricsManagerDisplayMode, _ rows: PreviewRows) -> String {
        switch mode {
        case .original: return ""
        case .translation: return L10n.t("这条候选歌词无译文")
        case .romanization:
            return rows.romanizationOffInSettings
                ? L10n.t("这首歌曲的语言未在设置的「标注读音的语言」中开启") : L10n.t("这条候选歌词无读音")
        }
    }

    private func shownMode(_ rows: PreviewRows) -> LyricsManagerDisplayMode {
        isModeAvailable(displayMode, rows) ? displayMode : .original
    }

    /// 预览正文:左边一列时间、右边正文,开着译文 / 读音时排在那一句下面。行取自 `LyricsPreviewText.rows`,
    /// 跟歌词窗口实际显示的是同一批行(署名过滤、多时间戳展开、译文挂靠都走播放引擎);行取自整行 LRC,
    /// 时间列就是这份 LRC 自己的时间戳,逐字轨只用来给当前句逐字染色。没有时间戳的纯文本候选不画时间列。采纳落盘的仍是
    /// 候选原始文本,这里只管看(边界见 LyricsPreviewText 头注)。
    ///
    /// 正在放的就是这首时,按这条候选自己的时间轴标出此刻唱到哪一句(`.ownTimeline`),不按在用那份歌词的当前句找字:
    /// 要比的正是各条候选的轴准不准,而在用的那份可能是错的、也可能没有。点时间从那一句播放。见 11 章决策 98。
    private func lyricsPreview(_ c: LyricsSearchService.Candidate, rows: PreviewRows) -> some View {
        let mode = shownMode(rows)
        let highlight = LyricsPreviewHighlight.ownTimeline(embeddedOffsetMs: rows.embeddedOffsetMs,
                                                           isCurrent: isCurrentCandidate(c))
        let playing = isSongPlaying && rows.timed
        return LyricsManagerPreviewList(
            rows: mode == .romanization ? rows.romanized : rows.plain,
            mode: mode,
            isNowPlaying: playing,
            follow: $followPlayback,
            canSeek: playing && PlaybackCoordinator.shared.acceptsSeek,
            onSeek: { ms in PlaybackCoordinator.shared.seek(toMs: max(0, ms - highlight.offsetMs)) },
            highlight: highlight,
            showsTimeColumn: rows.timed,
            horizontalInset: 24)
        // 换一条候选重建:没在放这首、或者关了跟随时从头看起,在跟随时直接落到当前句。
        .id(c.id)
    }

    // 这个候选实际匹配到的歌名 / 歌手 / 专辑,各占一行;哪一项是空的就不显示那一行,不留空白占位。歌手和专辑别合并成
    // 一行:侧栏窄,合并后专辑名几乎必被截断,而同名候选之间往往只有专辑名分得出版本。
    // 每项最多两行、挂 `help` 看全文:截掉的总是尾巴,尾巴恰恰是版本信息(「(2023 Remaster)」「feat. …」),所以宁可
    // 换行;不用居中省略(一行中间挖个洞读着费劲);封顶两行,不然一条候选能撑出五六行。
    @ViewBuilder
    private func candidateMatchInfo(
        _ c: LyricsSearchService.Candidate, titleFont: Font, detailFont: Font = .caption2
    ) -> some View {
        if !c.title.isEmpty {
            Text(c.title)
                .font(titleFont)
                .lineLimit(2)
                .help(c.title)
        }
        if !c.artist.isEmpty {
            Text(c.artist)
                .font(detailFont)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(c.artist)
        }
        if !c.album.isEmpty {
            Text(c.album)
                .font(detailFont)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(c.album)
        }
    }

    // 封面缩略图——没有 URL(这个源本来就没给,比如 LRCLIB 恒无)或者加载失败/加载中,
    // 一律显示同一个占位图标,不特意区分"没有"和"加载中"这两种状态,用户不需要关心
    // 这个区别。候选封面地址是各源的原图(可到 3000px),必须走 CachedImage 的缩略档在解码期
    // 降采样,别换成 AsyncImage:那会整张解码,十几条候选就是几百 MB。
    @ViewBuilder
    private func coverThumbnail(_ url: URL?, size: CGFloat, cornerRadius: CGFloat) -> some View {
        CachedImage(url: url) { coverPlaceholder(cornerRadius: cornerRadius) }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func coverPlaceholder(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary)
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
    }

    // 逐字/译文/罗马音——分别对应"是否有逐字时间戳""是否带翻译""是否带罗马音标注",
    // 跟 LyricsManagerView 详情页三个编辑区(歌词/译文/罗马音)用同一组图标,方便用户
    // 把候选列表里的图标和保存后详情页里的字段对上号。
    ///
    /// `showsSource`:来源标算不算这一排里的一员。左侧列表传 false —— 那边
    /// 把来源单独钉在行的右上角(理由见 `candidateRow`);右侧详情仍是 true。
    @ViewBuilder
    private func characteristicBadges(
        _ c: LyricsSearchService.Candidate, source: String, showsSource: Bool,
        isCurrent: Bool, duplicate: LyricsCandidateDuplicates.Match?
    ) -> some View {
        // 一个标签都没有时整排不渲染(而不是渲染一个空的 WrapLayout):空 Layout 高度是 0
        // 但外层 VStack 照样给它算 4pt 间距,那一行看起来就比别的行多垫了一截。来源标从
        // 这排挪走之后这种"全空"是真会发生的——一条有逐行时间戳、没译文没罗马音、既不
        // 重复也不是当前使用的普通候选,剩下的就是空。
        if hasAnyCharacteristicBadge(c, showsSource: showsSource, isCurrent: isCurrent, duplicate: duplicate) {
            // WrapLayout 而不是 HStack:最多可能同时有六个标签(逐字/译文/罗马音/来源/内容或文字相同/当前使用),
            // 侧栏里一行只有 ~350pt 宽,挤不下时该折行,不该被裁掉。
            WrapLayout(horizontalSpacing: 5, verticalSpacing: 4, rowAlignment: .leading) {
                // 橙色、放在最前:后面几个说这条候选有什么,这一个是用之前必须知道的限制。
                if c.isPlainTextOnly {
                    characteristicBadge(L10n.t("无时间戳"), "exclamationmark.triangle.fill", .orange)
                }
                if c.hasWordTiming {
                    characteristicBadge(L10n.t("逐字时间轴"), "text.word.spacing", LyricsFeatureTint.wordTiming)
                }
                if c.hasTranslation {
                    characteristicBadge(L10n.t("译文"), "character.book.closed", LyricsFeatureTint.translation)
                }
                if c.hasRomanization {
                    characteristicBadge(L10n.t("读音"), "textformat.abc", LyricsFeatureTint.romanization, latinIcon: true)
                }
                // 来源:用它在别处(歌词管理列表、设置里的来源勾选)一贯的身份色,一眼能对上号。
                if showsSource {
                    sourceBadge(source)
                }
                if let duplicate {
                    // 跟排在前面的某个源一样(见 LyricsCandidateDuplicates):词和每行时间都一样写「内容相同」,只有词一样
                    // 写「文字相同」;逐字时间与译文不比,所以不写「完全相同」,悬停说明把口径讲清。**只标注不隐藏**——
                    // 用户可能就是要这个源的译文/逐字轨,参考做法整条丢弃的路子不学。灰色:它是"这条跟别人重复"的
                    // 提示,不是加分项。
                    let anchor = sourceDisplayName(duplicate.anchor)
                    characteristicBadge(
                        String(format: duplicate.sameTimeline ? L10n.t("歌词内容与 %@ 相同") : L10n.t("歌词文字与 %@ 相同"),
                               anchor),
                        "equal.circle", .secondary)
                        .help(duplicate.sameTimeline
                              ? L10n.t("歌词文字和每行时间均相同（未比较逐字时间和译文）；该候选仍可能包含其他来源没有的逐字时间轴或译文")
                              : L10n.t("歌词文字相同，每行时间不同；该候选仍可能包含其他来源没有的逐字时间轴或译文"))
                }
                if isCurrent {
                    // 这首歌眼下真正在用的就是这一条。实心填充,跟上面几个描述性标签区分开 ——
                    // 那几个说的是"这条候选有什么",这一个说的是"你现在用的是它"。
                    Label(L10n.t("当前使用"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .font(.caption2)
        }
    }

    /// 上面那排里这条候选到底会不会长出至少一个标签 —— 判断顺序、判断条件跟
    /// `characteristicBadges` 的渲染体一一对应,改那边记得改这里(漏一项 = 那一排明明
    /// 有内容却被整个跳过)。
    private func hasAnyCharacteristicBadge(
        _ c: LyricsSearchService.Candidate, showsSource: Bool, isCurrent: Bool,
        duplicate: LyricsCandidateDuplicates.Match?
    ) -> Bool {
        c.isPlainTextOnly || c.hasWordTiming || c.hasTranslation || c.hasRomanization
            || showsSource || duplicate != nil || isCurrent
    }

    /// 名字和颜色走全局那一份:Spotify、Amazon Music、KKBOX 的本地歌词不在 `LyricsSource` 里,别改回按枚举取名
    /// (取不到就露出小写的原始 id)。
    private func sourceBadge(_ source: String) -> some View {
        let tint = sourceColor(source)
        return Text(sourceDisplayName(source))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    /// 「分数 742 · 82 行」那一行,带一个悬停说明,摊开分数是怎么加出来的。被排除的候选(分数 -1)不写分数,直接写原因
    /// (「不可用：不含时间戳」):-1 不是分很低,是这条被判定不能自动选用。
    @ViewBuilder
    private func scoreLine(_ c: LyricsSearchService.Candidate, font: Font) -> some View {
        let label = if c.isStored {
            Text(String(format: L10n.plural("已保存的版本 · %@ 行", count: c.lineCount), "\(c.lineCount)"))
        } else if Self.isExcluded(c), let reason = c.scoreTerms.first, reason.isRejection {
            Text(String(format: L10n.t("不可用：%@"), reason.label)).foregroundStyle(.orange)
        } else {
            Text(String(format: L10n.plural("分数 %@ · %@ 行", count: c.lineCount), "\(c.score)", "\(c.lineCount)"))
        }
        Group {
            if c.isStored {
                QuickHelpLabel(text: L10n.t("这首歌曲现在使用的歌词，从本机缓存读取，未参与本轮评分。搜索结果中出现同一份时换成那一条")) { label }
            } else if c.scoreTerms.isEmpty {
                // 没有可摊开的明细就别摆一个点了什么都没有的问号。
                label
            } else {
                // 悬停(短延迟)或点问号都能弹出明细;别换成 .help():系统 tooltip 要悬停约两秒才出,点击也没反应。
                QuickHelpLabel(text: scoreExplanation(c)) { label }
            }
        }
        .font(font)
        .foregroundStyle(.secondary)
    }

    /// 分数那一行,后面接源自报的曲长(`durationLabel`)。
    private func metaLine(_ c: LyricsSearchService.Candidate, font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            scoreLine(c, font: font)
            durationLabel(c, font: font)
        }
    }

    /// 「 · 4:31（+12 秒）」:这个源标注的曲长,跟这首差 2 秒以上时写差多少,差到算另一个版本(LyricsCandidateDuration)
    /// 时标橙。源没给时长时不出;借的是同一条录音别家报的(`durationBorrowedFrom`)时悬停说明写是哪家。
    @ViewBuilder
    private func durationLabel(_ c: LyricsSearchService.Candidate, font: Font) -> some View {
        if c.sourceDurationSecs > 0 {
            Text(" · " + durationText(c))
                .font(font)
                .foregroundStyle(LyricsCandidateDuration.isOff(candidate: c.sourceDurationSecs, song: durationSecs)
                                 ? Color.orange : Color.secondary)
                .lineLimit(1)
                .help(durationHelp(c))
        }
    }

    private func durationHelp(_ c: LyricsSearchService.Candidate) -> String {
        let reported = durationSecs > 0
            ? String(format: L10n.t("歌词源标注的曲目时长，这首歌曲时长 %@"), LyricsCandidateDuration.clock(durationSecs))
            : L10n.t("歌词源标注的曲目时长")
        guard !c.durationBorrowedFrom.isEmpty else { return reported }
        let borrowed = String(format: L10n.t("该歌词源不提供时长，这是同一条录音在 %@ 标注的时长"),
                              sourceDisplayName(c.durationBorrowedFrom))
        return durationSecs > 0
            ? borrowed + "\n" + String(format: L10n.t("这首歌曲时长 %@"), LyricsCandidateDuration.clock(durationSecs))
            : borrowed
    }

    private func durationText(_ c: LyricsSearchService.Candidate) -> String {
        let clock = LyricsCandidateDuration.clock(c.sourceDurationSecs)
        guard let diff = LyricsCandidateDuration.differenceSecs(candidate: c.sourceDurationSecs, song: durationSecs),
              abs(diff) >= LyricsCandidateDuration.negligibleSecs else { return clock }
        let signed = String(format: L10n.t("%@ 秒"), (diff > 0 ? "+" : "\u{2212}") + "\(abs(diff))")
        // 全角括号只配中文文案,英文界面用半角、前面空一格。
        return L10n.current == "en" ? "\(clock) (\(signed))" : "\(clock)（\(signed)）"
    }

    /// 分数说明文案本体在 ScoreTerm.explanation(跟「解析决策」弹窗共用),这里只是转发。
    private func scoreExplanation(_ c: LyricsSearchService.Candidate) -> String {
        LyricsSearchService.ScoreTerm.explanation(score: c.score, terms: c.scoreTerms)
    }

    /// latinIcon:图标必须画成拉丁字母才说得通(「罗马音」),理由见 LatinIconLabel。
    @ViewBuilder
    private func characteristicBadge(
        _ text: String, _ icon: String, _ tint: Color, latinIcon: Bool = false
    ) -> some View {
        Group {
            if latinIcon {
                LatinIconLabel(text, systemImage: icon)
            } else {
                Label(text, systemImage: icon)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private func load() async {
        searchGeneration += 1
        let generation = searchGeneration
        // 没有歌名就不搜(没在播放时打开、或者用户把歌名清空了):空歌名交给引擎只会回一串英文报错。
        guard !LyricsManagerSearch.query(title).isEmpty else {
            isSearching = false
            return
        }
        candidates = []
        coverPrewarm?.cancel()
        coverPrewarm = nil
        storedCandidate = makeStoredCandidate()
        loadError = nil
        // 先选中存着的那一版:搜索结果陆续到达期间右边一直是现在用的歌词。
        selectedSource = shownCandidates.first?.id
        userPickedSource = false
        networkLooksDown = false
        instrumental = false
        tracksFoundNoLyrics = []
        sourcesDone = 0
        sourcesTotal = 0
        searchRound = 1
        sourceFailureReasonCodes = [:]
        showsSameGroup = false
        showsExcludedGroup = false
        // 这一轮开着的源,跟引擎子进程读同一份 features.json;语义见 enabledSources 的注释。
        enabledSources = Set(FeatureSettingsStore.shared.lyricsSources.map(\.rawValue))
        isSearching = true
        do {
            // 交出去搜的三项去掉首尾空白(框里打的内容不动):多出来的空格会原样进各个源的查询。
            try await LyricsSearchService.shared.search(owner: searchOwner, artist: LyricsManagerSearch.query(artist),
                                                        title: LyricsManagerSearch.query(title),
                                                        album: LyricsManagerSearch.query(album),
                                                        durationSecs: durationSecs) { update in
                guard generation == searchGeneration else { return } // 已经有更新的一轮在跑,这批结果作废
                defer { revealSelection() }
                candidates = update.candidates
                // 列表是懒加载的:不预热,封面要等滚到那一行才开始下。上一批的预热先停,新一批按排序从头取图,
                // 前几张多半就是上一批正在下的,会并进同一个请求。
                coverPrewarm?.cancel()
                coverPrewarm = ImageMemoryCache.shared.prewarm(update.candidates.compactMap(\.coverURL))
                networkLooksDown = update.networkLooksDown
                instrumental = update.instrumental
                tracksFoundNoLyrics = update.tracksFoundNoLyrics
                sourcesDone = update.sourcesDone
                sourcesTotal = update.sourcesTotal
                searchRound = update.round
                sourceFailureReasonCodes = update.sourceFailureReasonCodes
                // 默认项优先选"这首歌眼下实际生效的来源"(currentSource)——候选是陆续
                // 到达的,currentSource 对应的那条不一定在第一批就到,所以只要用户还没
                // 手动点过(userPickedSource),每来一批新候选都重新评估一次,等它一出现
                // 就切过去,不是只在第一次到达时判断一锤子买卖。用户已经手动点过之后这里
                // 整段直接跳过,不会倒回去抢用户已经选定的行(原有设计的这条原则不变)。
                // currentSource 为空(比如这首歌还没有任何已生效来源)或它对应的候选
                // 始终没搜到时,退回"目前排最前"兜底,且只兜底一次(已经选中过东西就不再
                // 因为"还是没等到 currentSource"而重新改选)。
                // 存着的那一版先占着选中;搜到同一份(来源和正文都一样)时换到那一条上,同来源但正文不一样
                // (手改过)时仍停在存着的那一版。
                guard !userPickedSource else { return }
                if let current = update.candidates.first(where: isCurrentCandidate) {
                    selectedSource = current.id
                } else if let stored = storedCandidate, shownCandidates.first?.id == stored.id {
                    selectedSource = stored.id
                } else if let current = effectiveCurrentSource, update.candidates.contains(where: { $0.source == current }) {
                    selectedSource = current
                } else if selectedSource == nil {
                    selectedSource = shownCandidates.first?.id
                }
            }
        } catch {
            if generation == searchGeneration { loadError = error.localizedDescription }
        }
        guard generation == searchGeneration else { return } // 别让旧一轮的收尾把新一轮的"正在搜索"关掉
        isSearching = false
    }
}

/// 正在放的那首对应的缓存 key(实际命中优先,没有条目退 normalizedKey,跟三个入口算写回 key 同一套),换歌才变。
/// 搜索面板拿它跟自己那首比,决定预览要不要标出此刻唱到哪一句。
@MainActor
private final class LyricsSearchNowPlaying: ObservableObject {
    @Published private(set) var key: String?
    private var sub: AnyCancellable?

    init() {
        let p = PlaybackCoordinator.shared
        sub = Publishers.CombineLatest3(p.$artist, p.$title, p.$album)
            .map { artist, title, album -> String? in
                guard !artist.isEmpty || !title.isEmpty else { return nil }
                return EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album)
                    ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
            }
            .removeDuplicates()
            .sink { [weak self] in self?.key = $0 }
    }
}
