import AppKit
import LyrimuseCore
import SwiftUI

// "联网搜索候选歌词"弹窗,参考 LyricsX 的 SearchLyricsViewController:左侧候选列表
// (来源+分数+是否逐字),右侧选中候选的完整预览,"采用此候选"把内容交回调用方
// (调用方负责真正写回缓存,这里只管搜索和展示)。onApply 是可等待的、回报有没有真的落盘:
// 面板据此挪「当前使用」徽标、给一条回声;`keepsOpenAfterApply` 决定采纳后关窗还是留着
// (只有悬浮窗 ⚙ 的独立小窗传 true,理由见 apply(_:))。
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
    // 这首歌眼下实际生效的歌词来源(EnrichCacheStore.Summary.lyricsSource,比如"qq")——
    // 默认选中它,而不是"搜索结果里谁先到就选谁":2026-07-30 用户实测反馈,默认选中的
    // 候选应该是眼下正在用的这一份,不是随便哪个候选,不然明明已经在用 QQ 音乐的歌词,
    // 打开这个弹窗却默认高亮着完全不相关的 kugou,容易误导成"当前用的就是这个"。
    let currentSource: String?
    /// 这首歌当前正文的「只取词」指纹(ManualPickLock.fingerprint),nil = 调用方拿不到正文。
    /// 「当前使用」徽标 2026-09-04 起是来源 + 词双判据(LyricsCandidateDuplicates.isCurrent):同源但
    /// 正文被手改过的不再标当前;拿不到指纹时退回只比来源。三个入口都得传(contracts 组守卫钉着)。
    let currentFingerprint: String?
    // 曲目真实时长(秒),0 表示未知。必须传 —— 打分里时长匹配那一档权重很重,传 0 会
    // 让整档对所有候选一律跳过,弹窗里显示的排名就跟当初自动决策用的那组分数对不上。
    // 2026-08-07 实测:同一首歌传 0 时 qq 482 排第一,传真实时长(270.8s)时 qq 是 582、
    // 而当初胜出的 Musixmatch 拿的是 962 —— 用户看着"分最高的没被选",其实看的是另一套数。
    let durationSecs: Double
    /// 采纳后面板留着不关。三个入口里只有悬浮窗 ⚙ 的独立小窗传 true —— 那是"边听边换词"的
    /// 入口,换一个源听两句不对再换,原来要关窗→重开→再等九个源重搜(最坏 20 秒);留着的话
    /// 同一批候选还在,点即切。歌词管理(编辑器上方的模态,留着会挡住刚回填的编辑器)和歌词窗口
    /// 的 sheet(关了才看得到背后的歌词)维持关窗。
    let keepsOpenAfterApply: Bool
    /// 调用方真正写回缓存,回报有没有落盘。面板等它结束再决定:成功 → 挪「当前使用」徽标,
    /// 留着的话给一条回声、关窗模式直接关;失败 → 关窗模式照旧关(调用方那边的 lastError 红字
    /// 负责说明),留着的话在标题栏说一句、让人直接重试。
    let onApply: (LyricsSearchService.Candidate) async -> Bool

    /// 正在写回的那条候选的来源(按钮禁用 + 文案变「正在采用…」);nil = 没有在飞的采纳。
    @State private var applyingSource: String?
    /// 本次面板存活期间最后一次采纳成功的来源。「当前使用」徽标认 `appliedSource ?? currentSource`
    /// —— `currentSource` 是打开面板那一刻的快照(let),采纳之后不会自己变。换歌时重置。
    @State private var appliedSource: String?
    /// 跟 appliedSource 配对:刚采纳那条的指纹,「当前使用」双判据的另一半。
    @State private var appliedFingerprint: String?
    @State private var applyFeedback: ApplyFeedback?
    @State private var applyFeedbackGeneration = 0

    private struct ApplyFeedback: Equatable {
        let text: String
        let ok: Bool
    }

    @Environment(\.dismiss) private var dismiss
    // 只为了让这个弹窗在手动切换语言时重新渲染,同 LyricsManagerView 的理由 ——
    // 经 AppLanguageObserver 窄代理,不整对象订阅 AppSettings(2026-08-19,那样设置页
    // 拖任何滑杆/色轮都会打醒这个 sheet 的整个 body,含候选列表和预览面板)。
    @ObservedObject private var languageSettings = AppLanguageObserver.shared
    // candidates/isSearching 分开存,而不是揉进一个"loading/loaded/failed"三态 enum——
    // 现在结果是陆续到达的(collector 那边改成 NDJSON 流式输出,谁先查完谁先展示,见
    // LyricsSearchService.search 的 onUpdate),搜索"进行中"和"目前已经有哪些候选"是
    // 两个独立维度:可能已经有几条候选摆在那了、但后面的源还没回来。用一个三态 enum
    // 表达不了"进行中 + 已经有部分结果"这个中间状态。
    @State private var candidates: [LyricsSearchService.Candidate] = []
    /// 给"还在搜索"那两处提示缀的进度,形如 "（2/5）"。还没收到任何一行时是空串。
    ///
    /// 轮次标识(2026-09-02,用户反馈):collector 的兜底轮(首歌手变体/标题反查,见
    /// 第 09 章)每轮都重新扫全部源,进度"到 8/8 又回到 1/8"——数字回跳没有任何标注,
    /// 读起来像出了错。第 2 轮起在进度后面缀"［2］"标出轮次(放后面是用户定的位置);
    /// 第 1 轮不缀——绝大多数搜索只有一轮,常驻一个"［1］"是噪音,而标识恰好在数字
    /// 回跳那一刻出现,自己解释自己。
    private var searchProgressSuffix: String {
        guard sourcesTotal > 0 else { return "" }
        let roundSuffix = searchRound >= 2 ? "［\(searchRound)］" : ""
        return "（\(sourcesDone)/\(sourcesTotal)）\(roundSuffix)"
    }

    // 九个歌词源的完整名单——跟 collector 侧 enrich.go 的 lyricSourceNames 手工保持一致
    // (同一种做法见 LyricsDecisionSheet.swift 的 currentLyricsScoringVersion)。2026-08-31
    // 加 kuwo 时验证过:它跟 amll/lyricfind 走的是同一条 fetchScoredLyricCandidatesStreaming
    // 并发拉取路径,search-lyrics 这条 CLI 子命令(searchcli.go)确实会去查它,所以这里要
    // 跟 LyricsSource.allCases(FeatureSettingsStore.swift)保持同步,不是刻意留一个不查。
    private static let allLyricSourceNames = ["netease", "qq", "kugou", "lrclib", "musixmatch", "amll", "lyricfind", "kuwo"]

    // 2026-08-31 用户要求:这一轮里哪些源真的给出过候选(哪怕候选被判-1分),哪些一条
    // 候选都没给——直接从已经收到的 candidates 里反推,跟 collector 侧
    // lyricSourcesResponded(enrich.go)同一个判据("给没给"不看分数),不需要额外的
    // 网络请求或后端改动:candidates 本来就包含被拒绝的候选(比如"无时间戳"那些),
    // 每一行 stdout 都会带着目前收到的全部候选重新发一遍。
    private var respondedSources: Set<String> {
        Set(candidates.map(\.source))
    }

    @State private var showSourceAvailability = false

    // 头部"(x/y)"标记 + 点开的可用情况列表。sourcesTotal 为 0(还没收到任何一行)时不
    // 显示——那不是"零个可用",是"还没开始",跟 searchProgressSuffix 同一条准则。
    @ViewBuilder
    private var sourceAvailabilityBadge: some View {
        if sourcesTotal > 0 {
            Button {
                showSourceAvailability = true
            } label: {
                Text("\(respondedSources.count)/\(Self.allLyricSourceNames.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("这一轮有几个歌词源给出了候选，点击查看明细"))
            .popover(isPresented: $showSourceAvailability, arrowEdge: .bottom) {
                sourceAvailabilityList
            }
        }
    }

    private var sourceAvailabilityList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("歌词源可用情况"))
                .font(.headline)
            // "给过候选"≠"这条候选能用"——一个源明确回过一份被拒绝的候选(比如没时间戳、
            // 语言不对),跟它压根没回应(超时/限速/真的没收录这首歌),是两回事,分开
            // 标出来才不会把"回应了但不好"和"根本没回应"混为一谈。
            ForEach(Self.allLyricSourceNames, id: \.self) { source in
                let responded = respondedSources.contains(source)
                // 只有三个源(netease/musixmatch/lyricfind)接了具体失败原因诊断,见
                // searchcli.go 的 lyricSourceFailureReasons 头注——其它源没查到具体原因
                // 时这里就是 nil,如实只显示"未给出候选",不编一个没核实过的理由。
                // sourceFailureReasonCodes 里存的是稳定代码,经 LyricSourceFailureReason
                // 翻成当前 App 界面语言的人话再显示,见该类型的头注。
                let reason = responded ? nil : sourceFailureReasonCodes[source]
                    .map(LyricSourceFailureReason.text(forCode:))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: responded ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(responded ? .green : .secondary)
                        Text(sourceDisplayName(source))
                        Spacer()
                        Text(responded ? L10n.t("已给出候选") : L10n.t("未给出候选"))
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
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: 360)
    }

    // 未给出候选的源,查得到具体原因的那几个(2026-08-31)——给 sourceAvailabilityList
    // 那颗弹出面板用,见 LyricsSearchService.SearchUpdate.sourceFailureReasonCodes 的注释。
    @State private var sourceFailureReasonCodes: [String: String] = [:]

    @State private var isSearching = false
    // 已经回来几个源 / 一共几个 —— 只用来在"还在搜"的提示后面缀一个 (X/Y),让干等的时候
    // 知道进度在动。总数为 0(还没收到任何一行)时不显示,不写成 (0/0)。
    @State private var sourcesDone = 0
    @State private var sourcesTotal = 0
    // 第几轮全源检索(collector 兜底轮每轮重扫 9 个源),给 searchProgressSuffix 的
    // 轮次前缀用,语义见 LyricsSearchService.SearchUpdate.round。
    @State private var searchRound = 1
    // searchGeneration:第几轮搜索。load() 有三个入口(.task 首次进入、"重新搜索"按钮、
    // 输入框 .onSubmit),按钮有 .disabled(isSearching) 挡着,但 .onSubmit 没有——改完
    // 查询词直接回车就能在上一轮还没结束时开第二轮。两轮各自持有自己的进度回调,
    // 谁后返回谁的结果就留在界面上:慢的旧一轮(旧查询词)后返回时会把新查询词的候选
    // 整个盖掉,并且把 isSearching 提前关成 false。这里给每轮发一个自增序号,回调和
    // 收尾都先核对"我还是最新那一轮吗",不是就整段丢弃(不需要真去 cancel 子进程——
    // 让它自己跑完、结果丢掉即可,搜索本身没有副作用)。
    @State private var searchGeneration = 0
    @State private var loadError: String?
    // 2026-08-02 补上——所有源都没查到候选时,原来只有一句笼统的"都没找到",分不清是
    // 这首歌真的没有网络歌词还是网络整体不通。collector 侧统计"这一轮请求是否全部
    // 失败"算出这个信号,见 LyricsSearchService.SearchUpdate 的注释。
    @State private var networkLooksDown = false
    // 2026-08-30 补上——SearchUpdate.instrumental 这个信号早就算出来、也早就传到这里了
    // (见其声明处注释:"用来把'一个候选都没有'这个结局分成'这首歌本来就没词'和'真的
    // 谁都没搜到'"),但下面 content 的空状态分支只认 isSearching/networkLooksDown 两种,
    // 从没读过它——实测案例(蛋堡《收敛水》第 1 轨「关键字: Intro」,QQ 明确回过"此歌曲
    // 为没有填词的纯音乐"占位)真的搜出了 instrumental=true,弹窗却仍然显示笼统的
    // "七个源都没找到可用的候选",跟真没搜到的情况没有任何区别,等于白算了这个信号。
    @State private var instrumental = false
    @State private var selectedSource: String?
    // 候选是陆续到达的(见下面 candidates 那条注释),currentSource 对应的候选不一定在
    // 第一批就到——这个 flag 标记"selectedSource 现在的值是自动选出来的,还是用户自己
    // 点的",只要还是自动选的,每来一批新候选就重新评估一次能不能换成 currentSource;
    // 用户一旦手动点过任意一行就永远置为 true,此后不管后面来什么候选都不再自动改选中项
    // (原有设计的"不抢用户已经手动点开看的那个候选"这条原则不能因为这次改动而失效)。
    @State private var userPickedSource = false

    // List(selection:) 直接绑 $selectedSource 拿不到"这次赋值是用户点的还是代码自己设的"
    // 这个区分——包一层 Binding,只有真正经这层写回的(等价于用户在 List 里点了一行)
    // 才会把 userPickedSource 标记为 true。
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

    init(artist: String, title: String, album: String, currentSource: String?, currentFingerprint: String? = nil,
         durationSecs: Double, keepsOpenAfterApply: Bool = false,
         onApply: @escaping (LyricsSearchService.Candidate) async -> Bool) {
        self.originalArtist = artist
        self.originalTitle = title
        self.originalAlbum = album
        self.currentSource = currentSource
        self.currentFingerprint = currentFingerprint
        self.durationSecs = durationSecs
        self.keepsOpenAfterApply = keepsOpenAfterApply
        self.onApply = onApply
        self._artist = State(initialValue: artist)
        self._title = State(initialValue: title)
        self._album = State(initialValue: album)
    }

    private var isDirty: Bool {
        artist != originalArtist || title != originalTitle || album != originalAlbum
    }

    /// 「这次搜索是为哪首歌开的」——三个原始字段拼成的标识,给下面 `.task(id:)` / `.onChange`
    /// 用。三个入口里,歌词管理(`sheet(isPresented:)`)与歌词窗口(`sheet(item:)`)在面板存活
    /// 期间它不会变,行为等同于原来的 `.task {}`;只有悬浮窗 ⚙ 的独立小窗
    /// (`LyricsQuickSearchWindow`)会在窗口开着期间换歌再点一次时把新曲目喂进来。
    private var searchSubject: String {
        originalArtist + "\u{1F}" + originalTitle + "\u{1F}" + originalAlbum
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("搜索候选歌词")).font(.title3.weight(.semibold))
                applyFeedbackView
                Spacer()
                sourceAvailabilityBadge
                Button(L10n.t("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            // 2026-08-31 用户要求:这个面板(sheet 弹出,没有系统标题栏)能拖动。sheet 默认
            // 不可拖——AppKit 故意把它钉死在依附点,不是漏配了 isMovableByWindowBackground
            // 能补的(那个修饰符对 sheet 样式的窗口不生效)。WindowDragHandle 垫在标题栏这行
            // 背后,直接对底层 NSWindow 发起编程式拖动(performDrag),不问它是不是 sheet;
            // 垫在背景层不影响上面"关闭"/来源徽标按钮各自接收点击(SwiftUI 命中测试是
            // 前景优先,背景只接住前景没吃掉的点击)。
            .background(WindowDragHandle())

            Divider()

            queryFieldsBar

            Divider()

            content
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        // 2026-09-04 用户要求"这个页面要支持扩大边框"。独立小窗那条路径本来就能拖,
        // 从歌词管理/歌词窗口弹出的这张是 **sheet** —— AppKit 给 sheet 的默认 styleMask
        // 里没有 .resizable,窗口边缘对拖拽完全没反应。补一颗探针把这个标志插回去
        // (同 WindowDragHandle 的路子:垫在背景层拿到底层 NSWindow)。上面的 frame 同时
        // 从"只有下限"改成"下限 + 可无限撑大",不然窗口拖大了内容仍停在 720×480。
        .background(WindowResizeEnabler(minWidth: 720, minHeight: 480))
        // ⚠️ 2026-09-02 真实bug修复(悬浮窗 ⚙「搜索歌词…」小窗切歌后串 key):那扇窗口是
        // `if let context { LyricsSearchSheet(...) }`,2026-08-31 让它再点一次就重查曲目、把新
        // context 喂进来——但 SwiftUI 里 Optional 从 A 换成 B 是**同一个视图身份**:上面三个
        // 查询词 @State 只在首次创建时取 initialValue,`.task {}` 也只跑首次挂载那一遍,于是
        // 面板还显示上一首的查询词与候选(顺带让「恢复原信息」凭空出现,因为 @State 与新的
        // originalXxx 不相等被判成用户改过),而 onApply 已捕获新曲目的 key——采纳会把上一首
        // 的歌词写进当前这首的条目(lyrics/ 文件族随之落盘,开了「采纳即锁定」还会冻结)。
        //
        // 修在面板这一层,而不是让宿主加 `.id(context.key)` 整棵重建:离屏 NSHostingView 探针
        // 实测重建时**新面板的 .task 先起、旧面板的任务取消与 onDisappear 后到**,而两者都调
        // 全局 `cancelRunning()`(它杀的是"当前在跑的那个"),新起的 collector 子进程会被旧面板
        // 的收尾杀掉,3/3 复现。`.task(id:)` 的语义是先取消旧任务再起新任务,顺序由 SwiftUI
        // 保证,同一探针下新搜索每次都能跑完。`.onChange` 在更新阶段同步触发、`.task(id:)` 的
        // 任务体在其后异步起跑,所以 load() 起跑时查询词已经是新曲目的。
        .onChange(of: searchSubject) { _, _ in
            artist = originalArtist
            title = originalTitle
            album = originalAlbum
            // 换了歌,上一首采纳过什么跟这一首无关;回声也别留着误导。
            appliedSource = nil
            appliedFingerprint = nil
            applyFeedback = nil
        }
        .task(id: searchSubject) { await load() }
        // 关闭/采纳/Esc 任何一条退出路径都把还在跑的 collector 子进程停掉 —— 不停的话
        // 它会继续对九个源发请求直到 20 秒兜底,NDJSON 还在往已消失的视图里灌
        // (2026-08-19 性能审计;search() 内的 withTaskCancellationHandler 是第二层,
        // cancelRunning 幂等,两层谁先到都行)。
        .onDisappear { LyricsSearchService.shared.cancelRunning() }
    }

    // 三个可编辑的查询维度——默认展示这首歌本身的元数据,.task { await load() } 直接
    // 拿这三个初始值发起搜索;改了之后要显式点"重新搜索"(或者在任一输入框按下 Enter)
    // 才会真的重新发起查询,不会敲一个字就发一次网络请求。
    private var queryFieldsBar: some View {
        HStack(spacing: 10) {
            // 三栏**按内容长度分宽**,不等分(2026-09-04 用户反馈"输入框放不下内容")。
            // 等分那版最常见的一幕:歌手栏「PRINCE」六个字母后面空着大半格,旁边歌名
            // 「Around the World in a Day (2025 Remaster)」和专辑双双被截断——三栏的
            // 内容长度天然不对等,均分等于把宽度分给了最不需要的那栏。分法(含放不下时
            // 的下限保护)在 LyricsQueryFieldLayout,这里只负责按实际字体把"想要多宽"量
            // 出来。挂 help:再怎么分也有装不下的时候,悬停能看全文。
            ProportionalFieldsLayout(
                desired: [
                    Self.desiredFieldWidth(title, placeholder: L10n.t("歌名")),
                    Self.desiredFieldWidth(artist, placeholder: L10n.t("歌手")),
                    Self.desiredFieldWidth(album, placeholder: L10n.t("专辑")),
                ],
                spacing: 10, minWidth: 88
            ) {
                TextField(L10n.t("歌名"), text: $title).textFieldStyle(.roundedBorder).help(title)
                TextField(L10n.t("歌手"), text: $artist).textFieldStyle(.roundedBorder).help(artist)
                TextField(L10n.t("专辑"), text: $album).textFieldStyle(.roundedBorder).help(album)
            }
            if isDirty {
                Button(L10n.t("恢复原信息")) {
                    artist = originalArtist
                    title = originalTitle
                    album = originalAlbum
                }
                .buttonStyle(.link)
            }
            // 搜索途中也允许再点:上一轮会被 load() 里的 searchGeneration 判作废,子进程
            // 也会被 LyricsSearchService.cancelRunning 杀掉。改了关键词却要等上一轮跑完
            // (最长 20 秒)才能重搜,是没道理的等待。
            Button(L10n.t("重新搜索")) { Task { await load() } }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onSubmit { Task { await load() } }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // candidates 陆续到达、isSearching 才是"是否还没结束"的唯一依据——不能用
    // "candidates.isEmpty"反过来判断有没有搜索完:目前为止一个候选都还没到手,不代表
    // 九个源已经查完了(可能只是跑得快的那几个还没轮到),那样会把"还在搜"误判成
    // "查完了、真的什么都没有",提前弹出"没找到候选"的空状态提示。
    @ViewBuilder
    private var content: some View {
        if let msg = loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(msg).font(.callout).multilineTextAlignment(.center).padding(.horizontal, 40)
                Button(L10n.t("重试")) { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            if isSearching {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.t("正在查询网易云 / QQ音乐 / 酷狗 / Musixmatch / LRCLIB…")
                        + searchProgressSuffix)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if networkLooksDown {
                // 2026-08-02 补上——跟下面"真的查了但没有"分开展示,别让用户以为这首歌
                // 真没有网络歌词、白白灰心,其实只是网络本身有问题,重试大概率能查到。
                ContentUnavailableView {
                    Label(L10n.t("网络似乎不通"), systemImage: "wifi.slash")
                } description: {
                    Text(L10n.t("九个源的请求全部失败，很可能是网络连接有问题，不是这首歌真的没有歌词——检查网络后可以点下面的「重试」"))
                } actions: {
                    Button(L10n.t("重试")) { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if instrumental {
                // 排在"网络似乎不通"之后、笼统兜底之前:这是比"真没搜到"更确定的结论——
                // 至少一个源明确断言过"这首歌没有词"(见 instrumental 声明处注释),不是
                // 九个源都交白卷说不出理由,不该跟那种情况共用同一句轻描淡写的"没找到"。
                // 文案复用「重新自动匹配」toast 三分支(LyricsManagerView.swift)已经在用的
                // 同一条 L10n key,同一个结论在两处别各写一套措辞。
                ContentUnavailableView {
                    Label(L10n.t("纯音乐"), systemImage: "waveform")
                } description: {
                    Text(L10n.t("有源明确说这首是纯音乐，没有可用的歌词候选"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L10n.t("九个源都没找到可用的候选"), systemImage: "text.badge.xmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                if isSearching {
                    // 已经有候选可看了,但还有源没回来——小小一条提示,不用整页占用
                    // ProgressView 挡住已经到手的结果。
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("其它源仍在搜索中…") + searchProgressSuffix)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                }
                HSplitView {
                    List(candidates, selection: selectedSourceBinding) { c in
                        candidateRow(c)
                    }
                    // 2026-09-04 把理想/上限各放宽一档(280→300、320→380):这一列要放
                    // 歌名/歌手/专辑三行,长专辑名在 280pt 下必换行甚至截断;右侧预览
                    // 有 minWidth 380 兜着,拖不塌。
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)

                    if let c = candidates.first(where: { $0.source == selectedSource }) ?? candidates.first {
                        previewPane(c)
                    }
                }
            }
        }
    }

    private func candidateRow(_ c: LyricsSearchService.Candidate) -> some View {
        // 2026-08-26 用户要求把标签排挪到封面下面、统一一个位置:原来它跟在标题/歌手·
        // 专辑/分数后面,起点 x 跟着**文字列**走,而每一行的标题/歌手·专辑长短不一
        // (有的一行占满、有的很短),标签排看起来就没个准地方。改成外层 VStack 包一层,
        // 标签排放在"封面+文字"这一整条 HStack **下面**、贴着整行的左缘(也就是封面的
        // 左缘,不是文字的左缘)——不管这一行标题/歌手·专辑多长、封面下面空多少,
        // 标签排永远钉在同一个 x、同一个"这一行内容结束后"的 y,五行看下来是一条直线。
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                coverThumbnail(c.coverURL, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    // 第一行放这个候选**实际匹配到的歌名**,不再放来源名 —— 挑候选时最要紧的
                    // 判断是"这条到底对上了哪首歌/哪个版本",来源只是附带信息,挪到下面的标签排。
                    candidateMatchInfo(c, titleFont: .body.weight(.medium))
                    scoreLine(c, font: .caption2)
                }
                Spacer(minLength: 0)
            }
            characteristicBadges(c, source: c.source, isCurrent: isCurrentCandidate(c), duplicateOf: duplicateAnchors[c.source])
        }
        .tag(c.source)
        .padding(.vertical, 3)
    }

    /// 这首歌眼下实际生效的来源:本次面板里采纳过就是刚采纳的那条,否则是打开时的快照。
    private var effectiveCurrentSource: String? { appliedSource ?? currentSource }
    /// 跟 effectiveCurrentSource 配对:采纳过就是刚采纳那条的指纹,否则是打开时调用方算的。
    private var effectiveCurrentFingerprint: String? { appliedSource != nil ? appliedFingerprint : currentFingerprint }

    private func isCurrentCandidate(_ c: LyricsSearchService.Candidate) -> Bool {
        LyricsCandidateDuplicates.isCurrent(
            candidateSource: c.source, candidateFingerprint: c.fingerprint,
            currentSource: effectiveCurrentSource, currentFingerprint: effectiveCurrentFingerprint)
    }

    /// source → 排在它前面、词逐字相同的那个源(LyricsCandidateDuplicates.firstMatches)。候选最多九条,
    /// 每次 body 算一遍不贵;指纹本身在 Candidate 构造时算好了。
    private var duplicateAnchors: [String: String] {
        LyricsCandidateDuplicates.firstMatches(candidates.map { (source: $0.source, fingerprint: $0.fingerprint) })
    }

    private func applyButtonTitle(for c: LyricsSearchService.Candidate) -> String {
        if applyingSource == c.source { return L10n.t("正在采用…") }
        // 按钮文案跟着"这条候选到底能干什么"走——2026-08-30 加:纯文本那条采纳后不会像别的
        // 候选一样逐字/逐行跟播放同步,措辞不该让人以为跟别的候选是同一回事。
        return c.isPlainTextOnly ? L10n.t("采纳为静态文本") : L10n.t("采用此候选")
    }

    /// 「采用此候选」的整条流程(2026-09-04 起等调用方写完再收尾,原来是 `onApply(c); dismiss()`
    /// 一把关掉、写盘在背后跑、面板上什么反馈都没有):
    /// ① 防重入 —— 写盘 + 排 collector 重启在飞时不再叠一笔,按钮禁用、文案变「正在采用…」;
    /// ② 等待期间换了歌(小窗再按一次热键会换 context)这一笔写的是上一首,不挪徽标、不回声;
    /// ③ 成功 → `appliedSource` 挪「当前使用」徽标;关窗模式到此关窗(失败也关,调用方那边
    ///    的 lastError 红字负责说明),留着的模式给标题栏一条回声、不重搜 —— 候选本来就在。
    private func apply(_ c: LyricsSearchService.Candidate) async {
        guard applyingSource == nil else { return }
        let subject = searchSubject
        applyingSource = c.source
        let saved = await onApply(c)
        applyingSource = nil
        guard subject == searchSubject else { return }
        if saved {
            appliedSource = c.source
            appliedFingerprint = c.fingerprint
        }
        guard keepsOpenAfterApply else {
            dismiss()
            return
        }
        if saved {
            let name = LyricsSource(rawValue: c.source)?.displayName ?? c.source
            showApplyFeedback(String(format: L10n.t("已采用 %@ 的歌词"), name), ok: true)
        } else {
            showApplyFeedback(L10n.t("未能保存，请再试一次"), ok: false)
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

    /// 标题栏里的回声:「已采用 X 的歌词」/「未能保存」,2.5 秒后自己消失。放标题栏而不是另起一层
    /// toast 浮层:这个面板没有第二层浮层机制,标题右侧那段本来就是空的,而且它跟「当前使用」徽标
    /// 的移动同一刻出现,视线不用离开列表。
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                coverThumbnail(c.coverURL, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    candidateMatchInfo(c, titleFont: .headline)
                    scoreLine(c, font: .caption)
                }
                Spacer()
                // 按钮文案跟着"这条候选到底能干什么"走——2026-08-30 加:纯文本那条采纳后
                // 不会像别的候选一样逐字/逐行跟播放同步,措辞不该让人以为跟别的候选是同一
                // 回事,得在真正点下去之前再确认一次,不能只靠上面那个警示标签。
                Button(applyButtonTitle(for: c)) {
                    Task { await apply(c) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(applyingSource != nil)
            }
            characteristicBadges(c, source: c.source, isCurrent: isCurrentCandidate(c), duplicateOf: duplicateAnchors[c.source])
            if c.isPlainTextOnly {
                Label(
                    L10n.t("这份歌词没有时间戳，采纳后只能在「歌词窗口」里作为静态文字展示，不会逐字/逐行跟随播放高亮"),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ScrollView {
                // 摘掉 [ti:]/[by:]/[offset:] 这类元信息标签行和署名行再显示——它们播放时
                // 一个字都不会出现,却占满预览框顶部,把用户真正要判断的"第一句词对不对、
                // 轴准不准"挤到看不见的地方(2026-09-04 用户提)。只影响预览,采纳落盘的
                // 仍是候选原始文本;判据与理由见 LyricsPreviewText。
                Text(LyricsPreviewText.forPreview(c.lyrics, title: c.title, artist: c.artist))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .frame(minWidth: 380)
    }

    /// 一栏输入框「装下自己的内容需要多宽」:按输入框实际用的系统字体量一次文字宽度,
    /// 再加上 roundedBorder 的左右内边距与描边。空栏按占位符量(不然它会被压到下限,
    /// 而用户点进去要打字的正是这一栏)。
    private static func desiredFieldWidth(_ text: String, placeholder: String) -> CGFloat {
        let shown = text.isEmpty ? placeholder : text
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let width = (shown as NSString).size(withAttributes: [.font: font]).width
        return width + 22
    }

    // 这个候选实际匹配到的歌名 / 歌手 / 专辑,**各占一行**——不是每个源都能给全,哪一项
    // 是空的就不显示那一行,不留空白占位;title 单独一行是因为它通常跟搜索关键词的歌名
    // 差不多、但偶尔不同(比如带 Live/Remix 后缀),值得单独看清楚。
    //
    // 2026-09-04 歌手和专辑从"合并一行、用「·」分隔"拆成两行(用户要求)。合并那版在
    // 左侧列表里几乎必然被截断:列宽只有 250–320pt,而歌手本身就可能长到
    // 「Prince/The New Power Generation」这种,后面跟着的专辑名往往只剩「Diamond…」
    // 几个字——恰恰是同名候选之间唯一能分辨"这条是哪个版本"的信息。拆开后两行各自
    // 有整行宽度,截断概率大降;代价是每条候选高一行,九条也就多九行,这一列本来就
    // 是纵向滚动的。
    // 2026-09-04 再补:拆成三行之后仍然会有单项撑不下的(实测「Diamonds and Pearls
    // (Super Deluxe Edition)」在 300pt 的列里还差几个字),所以三行都放开到**最多两行**
    // 并挂 `help` 兜底。三个取舍:
    //  · **宁可换行不肯截断**——这三项被截掉的永远是尾巴,而尾巴恰恰是版本信息
    //    (「(Super Deluxe Edition)」「(2023 Remaster)」「feat. …」),同名候选之间往往
    //    只有这一处不同;截掉尾巴等于把这一列最该看的字先扔了。
    //  · **不用居中省略(.truncationMode(.middle))**——它确实能同时留住头和尾,但一行里
    //    挖个洞读起来费劲,而且这一列是纵向滚动的、多一行的代价很低。
    //  · **封顶两行**——真到两行还放不下(整段 feat. 名单那种)才截断,再由 `help` 悬停
    //    看全文;不封顶的话一条候选能自己撑出五六行,九条排下来列表就没法扫了。
    @ViewBuilder
    private func candidateMatchInfo(
        _ c: LyricsSearchService.Candidate, titleFont: Font
    ) -> some View {
        if !c.title.isEmpty {
            Text(c.title)
                .font(titleFont)
                .lineLimit(2)
                .help(c.title)
        }
        if !c.artist.isEmpty {
            Text(c.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(c.artist)
        }
        if !c.album.isEmpty {
            Text(c.album)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(c.album)
        }
    }

    // 封面缩略图——没有 URL(这个源本来就没给,比如 LRCLIB 恒无)或者加载失败/加载中,
    // 一律显示同一个占位图标,不特意区分"没有"和"加载中"这两种状态,用户不需要关心
    // 这个区别。
    @ViewBuilder
    private func coverThumbnail(_ url: URL?, size: CGFloat) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        coverPlaceholder
                    }
                }
            } else {
                coverPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.quaternary)
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
    }

    // 逐字/译文/罗马音——分别对应"是否有逐字时间戳""是否带翻译""是否带罗马音标注",
    // 跟 LyricsManagerView 详情页三个编辑区(歌词/译文/罗马音)用同一组图标,方便用户
    // 把候选列表里的图标和保存后详情页里的字段对上号。
    @ViewBuilder
    private func characteristicBadges(
        _ c: LyricsSearchService.Candidate, source: String, isCurrent: Bool, duplicateOf: String?
    ) -> some View {
        // WrapLayout 而不是 HStack:最多可能同时有六个标签(逐字/译文/罗马音/来源/文字相同/当前使用),
        // 左侧那一列只有 ~300pt 宽,挤不下时该折行,不该被裁掉。
        WrapLayout(horizontalSpacing: 5, verticalSpacing: 4, rowAlignment: .leading) {
            // 2026-08-30 加:警示色（橙）跟下面几个"这条候选有什么特性"的描述性标签区分
            // 开——那几个都是"越多越好"的加分项,这一个反过来是"用之前必须知道的限制"。
            // 放在最前面,不用等用户扫完整排标签才注意到。
            if c.isPlainTextOnly {
                characteristicBadge(L10n.t("无时间戳"), "exclamationmark.triangle.fill", .orange)
            }
            if c.hasWordTiming {
                characteristicBadge(L10n.t("逐字时间戳"), "text.word.spacing", .blue)
            }
            if c.hasTranslation {
                characteristicBadge(L10n.t("译文"), "character.book.closed", .green)
            }
            if c.hasRomanization {
                characteristicBadge(L10n.t("罗马音"), "textformat.abc", .purple, latinIcon: true)
            }
            // 来源:用它在别处(歌词管理列表、设置里的来源勾选)一贯的身份色,一眼能对上号。
            sourceBadge(source)
            if let duplicateOf {
                // 2026-09-04:跟排在前面的某个源逐字同词(ManualPickLock 指纹,只比词)。**只标注不隐藏**——
                // 用户可能就是要这个源的译文/逐字轨,参考做法整条丢弃的路子不学;所以文案写「文字相同」
                // 不写「完全相同」,悬停说明把口径讲清。灰色:它是"这条跟别人重复"的提示,不是加分项。
                characteristicBadge(
                    String(format: L10n.t("歌词文字与 %@ 相同"), LyricsSource(rawValue: duplicateOf)?.displayName ?? duplicateOf),
                    "equal.circle", .secondary)
                    .help(L10n.t("只比对歌词文字，不含时间戳、逐字与译文；这条候选仍可能带别的来源没有的逐字轨或译文"))
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

    private func sourceBadge(_ source: String) -> some View {
        let known = LyricsSource(rawValue: source)
        let tint = known?.color ?? .secondary
        return Text(known?.displayName ?? source)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    /// 「分数 742 · 82 行」那一行,分数带一个悬停说明,摊开它是怎么加出来的。
    ///
    /// 加这个是因为分数单独摆着完全不可读:742 不知道高在哪,-1 更是会被当成"分很低",
    /// 其实它是"这条被判定不可用"的标记(歌词没时间戳、语言对不上、时长明显对不上等),
    /// 跟 741 分不是同一个量级上的东西。
    @ViewBuilder
    private func scoreLine(_ c: LyricsSearchService.Candidate, font: Font) -> some View {
        let label = Text(String(format: L10n.t("分数 %@ · %@ 行"), "\(c.score)", "\(c.lineCount)"))
        Group {
            if c.scoreTerms.isEmpty {
                // 没有可摊开的明细就别摆一个点了什么都没有的问号。
                label
            } else {
                // 悬停(短延迟)或点问号都能弹出明细。原来这里是 .help(),系统 tooltip 要
                // 悬停约两秒才出、且点击完全没反应 —— 用户报的就是这个(2026-08-17)。
                QuickHelpLabel(text: scoreExplanation(c)) { label }
            }
        }
        .font(font)
        .foregroundStyle(.secondary)
    }

    /// 分数说明文案本体抽到了 ScoreTerm.explanation(跟"解析决策"弹窗共用),这里只是转发。
    /// (原来这里还给 "source" 那一项拼来源名 —— 来源先验分 2026-08-09 已从引擎移除,
    /// 那段是死代码,抽取时一并删了。)
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
        candidates = []
        loadError = nil
        selectedSource = nil
        userPickedSource = false
        networkLooksDown = false
        instrumental = false
        sourcesDone = 0
        sourcesTotal = 0
        searchRound = 1
        sourceFailureReasonCodes = [:]
        isSearching = true
        do {
            try await LyricsSearchService.shared.search(artist: artist, title: title, album: album, durationSecs: durationSecs) { update in
                guard generation == searchGeneration else { return } // 已经有更新的一轮在跑,这批结果作废
                candidates = update.candidates
                networkLooksDown = update.networkLooksDown
                instrumental = update.instrumental
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
                guard !userPickedSource else { return }
                if let current = effectiveCurrentSource, update.candidates.contains(where: { $0.source == current }) {
                    selectedSource = current
                } else if selectedSource == nil {
                    selectedSource = update.candidates.first?.source
                }
            }
        } catch {
            if generation == searchGeneration { loadError = error.localizedDescription }
        }
        guard generation == searchGeneration else { return } // 别让旧一轮的收尾把新一轮的"正在搜索"关掉
        isSearching = false
    }
}

/// 一排等高、**按各自内容长度分宽**的输入框。分宽的算术在 `LyricsQueryFieldLayout`
/// (纯函数、有 selftest),这里只做两件 SwiftUI 侧的事:把整行可用宽度交给它,再按
/// 结果摆位置。
private struct ProportionalFieldsLayout: Layout {
    let desired: [CGFloat]
    let spacing: CGFloat
    let minWidth: CGFloat

    private func widths(for subviews: Subviews, in total: CGFloat) -> [CGFloat] {
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        // desired 少给了就按下限补齐,多给了就截断——布局不该因为调用方数错了个数而崩。
        let want = (0..<subviews.count).map { $0 < desired.count ? desired[$0] : minWidth }
        return LyricsQueryFieldLayout.widths(
            desired: want, available: max(total - gaps, 0), minWidth: minWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        // 没有被提议宽度时(比如量"理想宽")报三栏都装得下的那个宽度。
        let natural = desired.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width ?? natural, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let ws = widths(for: subviews, in: bounds.width)
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() {
            let w = i < ws.count ? ws[i] : 0
            sub.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}
