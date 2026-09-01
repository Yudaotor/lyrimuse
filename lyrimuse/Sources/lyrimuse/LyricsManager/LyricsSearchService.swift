import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-search")

// "联网搜索候选歌词"——参考 LyricsX 的 SearchLyricsViewController,但不在 Swift 这边
// 重新实现网易云/QQ/酷狗/Musixmatch/LRCLIB 的检索逻辑(那会是第二份、迟早会跟 Go collector 那份
// 走样的实现)。改用一次性子进程调用 `collector search-lyrics`(collector/searchcli.go),
// 复用 scoredLyricCandidates(collector/enrich.go)——跟自动解析路径完全同一份取分/排序
// 代码,只是把"取最高分那个"换成"把全部候选连分数一起交给用户挑"。不新增常驻服务:
// 跟 EnrichCacheStore 的 launchctl kickstart 是同一种"偶尔手动操作,一次性子进程开销
// 可以接受"的取舍。
final class LyricsSearchService {
    static let shared = LyricsSearchService()

    /// 上一次还在跑的搜索子进程。2026-08-09 把「重新搜索」按钮在搜索途中也放开之后需要它:
    /// 不杀掉的话,旧那一轮会继续跑满(最长 20 秒兜底超时),白占八个源的网络请求 —— 结果
    /// 反正会被调用方的 searchGeneration 判定作废、一行都不会显示。
    /// 用锁而不是 @MainActor:search() 的进程收尾在后台队列上,两边都要碰这个引用。
    private let processLock = NSLock()
    private var runningProcess: Process?

    /// 取消正在跑的那一轮(没有就什么都不做)。
    func cancelRunning() {
        processLock.lock()
        let process = runningProcess
        runningProcess = nil
        processLock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    struct ScoreTerm: Equatable, Decodable {
        let kind: String
        let points: Int

        /// 界面上显示的名字。认不出来的类型原样显示 kind —— collector 以后加了新项目
        /// 也不会在这里显示成空白。
        var label: String {
            switch kind {
            case "duration": return L10n.t("时长吻合")
            case "corroborated": return L10n.t("结束点获印证")
            case "wordTiming": return L10n.t("逐字时间轴")
            // 2026-08-22 补:这一项自 2026-08-15 就在打分里,却一直没有译名 ——
            // 是新加的 scoretermlabel_test.go 守卫测试当场逮出来的既有漏网。
            case "nativeSource": return L10n.t("与当前播放器同源")
            case "lines": return L10n.t("行数")
            case "versionTags": return L10n.t("版本不符")
            case "durationOff": return L10n.t("时长不符")
            // v4(2026-08-22):跟 durationOff 量的不是同一样东西,文案必须分得开 ——
            // 那个是「歌词铺到哪儿 vs 曲长」,这个是「源自己说这首歌多长 vs 本地多长」。
            case "sourceDurationOff": return L10n.t("源自报曲长不符")
            // v5(2026-08-27):这是全批候选打完分之后才补的一项负分,只在"逐字加分是唯一
            // 让这个候选赢的理由,而另一个候选标题更吻合"时出现,见 collector 侧
            // applyWordTimingTitleOverride 的注释。
            case "wordTimingOverride": return L10n.t("标题吻合度更高的候选存在，撤销逐字加分")
            // v7(2026-09-01):「两场不同演唱会」判据,见 collector 侧
            // liveAlbumIdentityConflict 的注释(陈奕迅 The Easy Ride vs Get A Life 案)。
            case "liveAlbumConflict": return L10n.t("是另一场演出的现场版")
            // v3(2026-08-12)新维度,与 collector match.go 的 scoreTerm kind 一一对应。
            // 旧 "source" case 已删:来源先验分 2026-08-09 从引擎移除后,score_terms 只来自
            // 实时搜索(不落缓存),不存在还带着旧字段的数据,这个分支是死代码。
            case "durationOvershoot": return L10n.t("歌词超出曲长")
            case "album": return L10n.t("专辑吻合")
            case "titleMatch": return L10n.t("标题吻合")
            case "consensus": return L10n.t("内容获印证")
            case "translation": return L10n.t("自带译文")
            case "romanization": return L10n.t("自带罗马音")
            case "rejectNotTimed": return L10n.t("不是带时间戳的歌词")
            case "rejectWrongLanguage": return L10n.t("语言跟这首歌对不上")
            case "rejectCreditOnly": return L10n.t("整份只有署名行，没有正文")
            case "rejectNoLastTimestamp": return L10n.t("取不到最后一句的时间")
            case "rejectDurationMismatch": return L10n.t("时长明显对不上，也没有别的源印证")
            // 2026-08-30 加:跟 rejectNotTimed 是同一类症状(没有时间戳)、不同的原因——
            // 那个是"疑似解析失败",这个是"这个源明确说了只有纯文本,压根没有带时间戳的版本"
            // (见 collector match.go 的 scoreRejectPlainTextOnly 头注)。
            case "rejectPlainTextOnly": return L10n.t("仅有纯文本，没有时间戳")
            default: return kind
            }
        }

        /// 一句话解释这一项**是什么**、以及它的量程。
        ///
        /// 只给名字不够:用户看到「其它源印证了结束点 +100」完全不知道那是什么意思,也
        /// 不知道 +100 算多还是算少 —— 2026-08-09 用户就是这么问过来的。名字回答"这是
        /// 哪一项",这句回答"它凭什么给分、满分多少"。
        var detail: String {
            switch kind {
            case "duration": return L10n.t("最后一句的时间跟曲长越接近分越高，最多 300")
            case "corroborated": return L10n.t("时长对不上，但别的源也在这个时间结束，改信这个印证")
            case "wordTiming": return L10n.t("带逐字（卡拉OK）时间轴，是歌词质量最直接的证据")
            case "nativeSource": return L10n.t("这个源就是你正在用的播放器，时间轴对着同一份音频母版（+250）")
            case "lines": return L10n.t("一行 1 分，最多 200")
            case "durationOvershoot": return L10n.t("最后一句比歌曲结束还晚 5 秒以上，多半是完整版歌词配了精简版曲目")
            case "album": return L10n.t("这个源匹配到的专辑跟本地专辑一致，版本大概率对（最多 150）")
            case "titleMatch": return L10n.t("完全同名 120 · 仅括号差异 60 · 中英双语同名 30")
            case "consensus": return L10n.t("歌词内容跟其它来源高度一致（2 家以上 250 · 1 家 150），串版本的拿不到")
            case "translation": return L10n.t("自带可用的中文译文，同水平候选间优先")
            case "romanization": return L10n.t("日文歌词自带罗马音，同水平候选间优先")
            case "versionTags": return L10n.t("括号里的 Live / Remix / Demo / Club Mix 等跟本地曲名对不上")
            case "sourceDurationOff":
                return L10n.t("这个源自己声明的曲目时长跟本地差了 12% 以上，多半挂在另一次录音上")
            case "wordTimingOverride":
                return L10n.t("逐字时间轴本来赢在这上面，但另一个候选的标题更吻合查询词——大概率是另一次录音（比如不同现场版）的逐字版本，时间轴细不代表轴对得上这次播放")
            case "liveAlbumConflict":
                return L10n.t("两边都是现场版，但这个候选的专辑名指向另一场不同命名的演出（比如另一次巡演）——时间轴是那场演出的，套在这次播放的录音上会对不上")
            case "durationOff":
                return L10n.t("最后一句的时间跟曲长差了 25% 以上；仍可选用，但会排在所有时长对得上的后面")
            case "rejectDurationMismatch":
                return L10n.t("最后一句的时间跟曲长差了 25% 以上，多半是另一个版本")
            case "rejectPlainTextOnly":
                return L10n.t("这个源确实收录了这首歌，但只有不带时间戳的纯文本——可以在「歌词窗口」里当静态文字阅读，无法逐字/逐行跟随播放高亮")
            default: return ""
            }
        }

        var isRejection: Bool { kind.hasPrefix("reject") }

        /// 分数说明整段文案。一项一行、按贡献绝对值从大到小排 —— 用户真正在问的是
        /// "它凭什么排第一",答案该第一行就出现。原来是 LyricsSearchSheet 的私有方法,
        /// 2026-08-17 抽到这里跟"解析决策"弹窗共用:两处要是各写一份,措辞和排序规则
        /// 迟早漂开。
        static func explanation(score: Int, terms: [ScoreTerm]) -> String {
            guard let first = terms.first else { return "" }
            if first.isRejection {
                let detail = first.detail
                return String(format: L10n.t("不可用：%@"), first.label)
                    + (detail.isEmpty ? "" : "\n" + detail)
            }
            var lines = [String(format: L10n.t("总分 %@"), "\(score)")]
            for term in terms.sorted(by: { abs($0.points) > abs($1.points) }) {
                let signed = "\(term.points > 0 ? "+" : "")\(term.points)"
                let detail = term.detail
                lines.append(detail.isEmpty
                    ? "\(signed)  \(term.label)"
                    : "\(signed)  \(term.label) · \(detail)")
            }
            return lines.joined(separator: "\n")
        }
    }

    struct Candidate: Identifiable, Equatable {
        var id: String { source }
        let source: String
        let lyrics: String
        let lyricsTr: String
        let lyricsRoma: String
        let lyricsYRC: String
        let hasWordTiming: Bool
        let score: Int
        /// 这个分数的构成明细;被判 -1 时只有一项,内容是原因。collector 只给机器可读的
        /// 类型 + 分值,文案在这边本地化(见 ScoreTerm.label)——App 有中英两套界面。
        let scoreTerms: [ScoreTerm]
        // 这个源实际匹配到的歌名/歌手/专辑/封面——不同源可能匹配到同一首歌的不同版本
        // (不同专辑/live/合集),各自如实展示,不做跨源统一;不是每个源都能给全,LRCLIB
        // 没有封面这个概念,留空就是这个源确实没有,不是加载失败。
        let title: String
        let artist: String
        let album: String
        let coverURL: URL?
        // 2026-08-30 加——true 时 lyrics 装的是没有时间戳的纯文本(见 collector
        // scoredLyricCandidateResult.PlainTextOnly 头注)。跟别的候选不同,这条**不能**
        // 用来做逐字/逐行同步展示,只能当静态文字读——「搜索候选歌词」弹窗要用它决定
        // 要不要挂"无时间戳"警示标签,「歌词窗口」采纳后要用它决定走哪条渲染路径。
        let isPlainTextOnly: Bool

        // 给候选选择界面展示的补充特性——是否逐字这一项 collector 已经算好(hasWordTiming),
        // 译文/罗马音/行数纯粹是本地字段是否非空/切行数,不需要 collector 额外计算。
        var hasTranslation: Bool { !lyricsTr.isEmpty }
        var hasRomanization: Bool { !lyricsRoma.isEmpty }
        // CRLF 换行(酷狗候选常见)会让 split(separator:"\n") 按 Character 比较时把整份
        // 文本当一整行切不开——见 YRCParser/LRCParser.parse 同一处注释,这里先归一化成
        // 纯 "\n" 再切,否则这类候选会显示成"1 行"这种明显错误的行数。
        //
        // 存储属性、构造时算一次(2026-08-19 性能审计):原来是计算属性,每次行渲染/
        // 预览重算都对整首歌词(2-10KB)完整跑两遍 replacingOccurrences + 一遍 split,
        // 而 lyrics 自构造起不可变,纯属重复计算(sheet 的 body 重算入口很多:三个查询
        // 输入框每敲一键、每批 NDJSON 到达都整数组替换)。
        let lineCount: Int

        static func countLines(of lyrics: String) -> Int {
            lyrics.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    // 2026-08-02 补上——之前 onUpdate 只传候选数组,八个源都没查到候选时,弹窗只能显示
    // 一句笼统的"都没找到",分不清是这首歌真的没有网络歌词,还是网络整体不通导致八个源
    // 的请求全部发不出去。networkLooksDown 由 collector 侧统计"这一轮联网搜索期间发出
    // 的请求有没有全部失败"算出来(见 networkobs.go 的 networkLooksDown()),这里原样
    // 转发给调用方决定展示哪种空状态文案。
    /// `-pick` 模式下 collector 给出的"按自动解析规则重选一次"的结论。只有最后那行 stdout 才有。
    ///
    /// 冠军**必须**由 collector 那边算,不能在这里取 max(score):`pickLyricCandidate` 带一个
    /// 设置分支(「匹配算法」选「顺序优先」时取的是"配置顺序里第一个 Score>=0 的源",不是最高
    /// 分),还要过启用源过滤、跳掉 Score<0 的废候选。在 Swift 侧复制一遍就是第二份会漂的决策
    /// 规则,而漂的表现是"手动匹配完、下一拍自愈路径又给换回去"。
    struct Pick: Decodable {
        /// 空串 = 一个能用的候选都没有(全被判废/全没搜到)。调用方**不许**退回"取第一条"。
        var winner: String = ""
        var winnerScore: Int = 0
        var scoringVersion: Int = 0
        /// 复刻 collector 的 rescoreDecidable:当前生效的那个源这一轮没应答时为 false ——
        /// 它可能本来就是最优的、只是这次超时了,此时下结论有降级风险。
        var decidable: Bool = false
        var sourcesSeen: [String] = []
        var sourcesResponded: [String] = []
        var resolvedDurationSecs: Double = 0
        /// smart / priority —— 结果文案如实说明这轮按哪套规则选的。
        var mode: String = ""
        /// lyricsDecision 的 JSON 原文,原样写进 enrich-cache 的 lyrics_decision。走字符串是
        /// 为了不在 Swift 侧再镜像一遍那个结构(镜像就会漂)。
        var decisionJSON: String = ""

        // 2026-08-25 改成手写 init(from:)——原来的合成 Decodable 表面上给每个属性都设了
        // 默认值,但 Swift 的自动合成解码器**不会**在 key 缺失时退回属性默认值,缺 key 会
        // 直接 throw(实测验证过,不是猜的)。而 searchLyricsPick 在 Go 那边几乎每个字段都
        // 带 `omitempty`——winner 在"没有可用候选"时是空串会被省略、sourcesSeen/
        // sourcesResponded 在"啥都没应答"时是空切片会被省略、resolvedDurationSecs 在
        // "浏览历史缓存条目、没有可靠真实时长"时是 0 会被省略、decisionJSON 在
        // **decidable==false 这个完全正常的分支**(当前源这轮没应答)时干脆整个不写。
        // 于是"这一轮没拿到结论"这句本该保底的兜底文案,实际上吞掉了好几种明确该有专属
        // 文案的正常结局("这轮没应答没有换""这轮没有能用的候选"等)——因为那一行 JSON
        // 解码直接整行失败被跳过,调用方拿到的是上一条流式更新(pick 恒为 nil)。改成显式
        // decodeIfPresent + ?? 默认值,跟 Go 的 omitempty 语义对齐。
        private enum CodingKeys: String, CodingKey {
            case winner, winnerScore, scoringVersion, decidable
            case sourcesSeen, sourcesResponded, resolvedDurationSecs, mode, decisionJSON
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            winner = try c.decodeIfPresent(String.self, forKey: .winner) ?? ""
            winnerScore = try c.decodeIfPresent(Int.self, forKey: .winnerScore) ?? 0
            scoringVersion = try c.decodeIfPresent(Int.self, forKey: .scoringVersion) ?? 0
            decidable = try c.decodeIfPresent(Bool.self, forKey: .decidable) ?? false
            sourcesSeen = try c.decodeIfPresent([String].self, forKey: .sourcesSeen) ?? []
            sourcesResponded = try c.decodeIfPresent([String].self, forKey: .sourcesResponded) ?? []
            resolvedDurationSecs = try c.decodeIfPresent(Double.self, forKey: .resolvedDurationSecs) ?? 0
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
            decisionJSON = try c.decodeIfPresent(String.self, forKey: .decisionJSON) ?? ""
        }
    }

    struct SearchUpdate {
        let candidates: [Candidate]
        let networkLooksDown: Bool
        /// 已经回来的歌词源 / 一共要等几个。语义(为什么分母只数开着的源、为什么
        /// applecover 不算)见 collector/enrich.go 的 lyricSearchUpdateFunc 注释。
        let sourcesDone: Int
        let sourcesTotal: Int
        /// 第几轮全源检索,从 1 开始(2026-09-02)。兜底轮(首歌手变体/标题反查等,见
        /// collector/enrich.go)每轮都重新扫全部源,sourcesDone 每轮从 0 重数——没有这个
        /// 字段时进度显示成"8/8 之后又回到 1/8",读起来像出了错。旧 collector 不发这个
        /// 字段时解码成 1(单轮语义,跟没有兜底轮的观感一致)。
        let round: Int
        /// 这一轮里没给出候选的源,查得到具体原因的那几个(2026-08-31)——collector 侧
        /// lyricSourceFailureReasons(searchcli.go)算出来,只覆盖 netease/musixmatch/
        /// lyricfind 三个已经接了诊断旁路的源,给"歌词源可用情况"明细面板用。key 是源名,
        /// value 是**稳定代码**,不是文案(2026-09-01 从 sourceFailureReasons 改名——见
        /// `LyricSourceFailureReason` 的头注,显示给用户前要先经
        /// `LyricSourceFailureReason.text(forCode:)` 翻译);没查到具体原因的源不会出现
        /// 在这个字典里(不代表"没有原因",只是这个仓库目前没有对应信号,不编一个没核实
        /// 过的理由)。
        let sourceFailureReasonCodes: [String: String]
        /// 至少一个源明确说这首是纯音乐(不只 lrclib,网易云 pureMusic 也会置位)。
        /// 用来把"一个候选都没有"这个结局分成"这首歌本来就没词"和"真的谁都没搜到"。
        let instrumental: Bool
        /// 只有 pickWinner: true 且只有最后那行才非 nil,见 Pick。
        let pick: Pick?
    }

    enum SearchError: LocalizedError {
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .processFailed(let msg): return String(format: L10n.t("搜索失败: %@"), msg)
            }
        }
    }

    // 2026-07-23 修正:原来硬编码的是 ~/applemusic-nowplaying/bin/collector——这是
    // 项目改名前遗留的路径,压根不是 build.sh 实际维护的产物(build.sh 只往
    // Lyrimuse.app/Contents/Resources/collector 里装新构建),这个路径下的二进制早就
    // 没人更新过,"联网搜索候选歌词"用的实际上是一份过时的旧构建。改用
    // CollectorServiceManager.bundledCollectorPath 同一条规则(Bundle.main.bundleURL
    // 拼 Contents/Resources/collector),这样每次 build.sh 重新打包都会跟着更新。
    private static let collectorPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/collector").path

    private init() {}

    // durationSecs 传 0 表示"没有可靠的真实时长"——歌词管理窗口浏览的是任意历史缓存
    // 条目,enrichEntry 本来就不持久化时长;collector 侧 scoreLyricCandidate 对
    // durationSecs<=0 有专门处理,直接跳过时长匹配这档评分(不会除零/不会被误判成
    // "时长对不上"),只退化成语言/署名行过滤+逐字加分+来源优先级+行数。
    //
    // onUpdate 每收到子进程一整行 stdout 就调用一次(不是等进程退出才调一次)——
    // collector 那边(searchcli.go)改成了 NDJSON:谁先查完谁先打印一行,后面每一行是
    // 目前为止已知全部候选重新排序过的完整列表,不是只有新到的这一条(collector 侧
    // corroboratedEndings 是跨候选互相印证的信号,后到的源可能改变已经展示出来的某条
    // 候选的分数,所以每次都要整份重新展示,不能只追加新的那一条)。调用方(desktop-
    // lyrics 的"搜索候选歌词"弹窗)因此能做到"谁先搜到就先展示谁,列表随后续源陆续
    // 刷新",不用等最慢的源(或者 20 秒兜底超时)才看到任何东西。回调固定在
    // MainActor 上执行,调用方可以直接改 @State,不需要自己再跳线程。
    /// - pickWinner: 传 true 时给 collector 加 `-pick`,让它顺便按自动解析那套规则选出冠军
    ///   (见 Pick)。候选列表照常流式返回,冠军只在最后那行带回来。
    /// - currentSource: 这首歌眼下生效的歌词源,只在 pickWinner 时有意义(喂给 collector 的
    ///   decidable 判定)。
    func search(
        artist: String, title: String, album: String, durationSecs: Double = 0,
        pickWinner: Bool = false, currentSource: String = "",
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {
        // withTaskCancellationHandler:调用方的 Task 被取消(.task 随视图消失、或
        // searchGeneration 换代)时顺手终结子进程 —— 原来没有任何取消接线,sheet 关掉/
        // 采纳候选后 collector 子进程照跑满(八个源、20 秒兜底),NDJSON 还在往已消失的
        // 视图里灌,全是无人消费的废工(2026-08-19 性能审计;sheet 侧另有 onDisappear
        // 兜底,两层都在,谁先到谁生效——cancelRunning 幂等)。
        try await withTaskCancellationHandler {
            try await performSearch(artist: artist, title: title, album: album,
                                    durationSecs: durationSecs, pickWinner: pickWinner,
                                    currentSource: currentSource, onUpdate: onUpdate)
        } onCancel: {
            cancelRunning()
        }
    }

    private func performSearch(
        artist: String, title: String, album: String, durationSecs: Double,
        pickWinner: Bool = false, currentSource: String = "",
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.collectorPath)
            process.arguments = [
                "search-lyrics",
                "-artist", artist,
                "-title", title,
                "-album", album,
                "-duration", String(durationSecs),
            ]
            if pickWinner {
                process.arguments?.append("-pick")
                if !currentSource.isEmpty {
                    process.arguments?.append(contentsOf: ["-current-source", currentSource])
                }
            }
            // 新一轮开始前先把上一轮杀掉,并记下自己,好让下一轮也能杀掉我。
            self.cancelRunning()
            self.processLock.lock()
            self.runningProcess = process
            self.processLock.unlock()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // 内核管道缓冲区只有 64KB,四源都命中+带逐字 YRC 数据的候选(比如 Michael
            // Jackson - You Rock My World,合计输出 65KB+)一旦超过这个缓冲区,子进程的
            // write() 就会阻塞、等父进程腾出空间;如果父进程只在进程退出后才读,子进程
            // 卡在 write() 上永远不会退出、进程也就永远不会终止,两边互相等对方先动
            // 导致死锁。这里在子进程运行期间就持续把 stdout 读走(用 availableData 循环,
            // 不是一次性 readDataToEndOfFile——后者要等到 EOF 才返回,等于还是"攒到最后
            // 才读",会跟"边读边逐行展示"的目标自相矛盾),管道缓冲区就不会被灌满。
            //
            // 用 @unchecked Sendable 包一层是因为 outBuffer/pendingUpdate 只在下面这一条
            // 后台队列(readQueue,串行)里被写,不会有真正的并发访问——Swift 6 严格并发
            // 检查器认不出"同一个串行队列内先后执行"这种 happens-before 关系,只能显式
            // 声明这里的跨线程访问已经自行保证过安全。
            final class Box: @unchecked Sendable {
                var outBuffer = Data()
                var errBuffer = Data()
            }
            let box = Box()
            let readQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.search-lyrics.stdout", qos: .utility)
            let readGroup = DispatchGroup()

            // 按 \n 切行,每凑齐一整行就尝试解码成 RawSearchUpdate 并回调——半行(还没读到
            // 换行符的尾巴)留在 outBuffer 里等下一批数据补全,不会被当成一行提前误判。
            func drainCompleteLines() {
                while let newlineRange = box.outBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = box.outBuffer.subdata(in: box.outBuffer.startIndex..<newlineRange.lowerBound)
                    box.outBuffer.removeSubrange(box.outBuffer.startIndex..<newlineRange.upperBound)
                    guard !lineData.isEmpty else { continue }
                    guard let raw = try? JSONDecoder().decode(RawSearchUpdate.self, from: lineData) else {
                        logger.error("search-lyrics: failed to decode a stdout line, skipping")
                        continue
                    }
                    let update = SearchUpdate(
                        candidates: raw.candidates.map(Candidate.init),
                        networkLooksDown: raw.networkLooksDown,
                        // 可选 + 兜底 0:字段缺失不该让整行解码失败、把这一批候选整批丢掉。
                        sourcesDone: raw.sourcesDone ?? 0,
                        sourcesTotal: raw.sourcesTotal ?? 0,
                        round: raw.round ?? 1, // 旧 collector 不发,按单轮兜底,见 SearchUpdate.round
                        sourceFailureReasonCodes: raw.sourceFailureReasonCodes ?? [:],
                        // 优先新 key,缺失才退回旧 key —— 两个二进制各自独立部署,可能
                        // 出现「新 App + 旧 collector」(只重建了 App 没换 collector)。
                        instrumental: raw.instrumental ?? raw.lrclibInstrumental ?? false,
                        pick: raw.pick)
                    Task { @MainActor in onUpdate(update) }
                }
            }

            readGroup.enter()
            readQueue.async {
                let handle = stdoutPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF
                    box.outBuffer.append(chunk)
                    drainCompleteLines()
                }
                readGroup.leave()
            }
            // stderr 必须在**独立**队列上读(2026-08-19):readQueue 是串行的,原来这条
            // 任务排在 stdout 的 EOF 循环后面,等于把上面那段注释自防的 64KB 管道死锁在
            // stderr 侧原样引回 —— 当前 search-lyrics 路径的 stderr 写入量 <2KB 触发不了,
            // 但将来任何人给搜索路径加 verbose 日志就会无声引爆。两条管道并行排空,
            // errBuffer 只在这条队列写、terminationHandler 经 readGroup.wait() 后才读,
            // happens-before 由 group 保证。
            let stderrQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.search-lyrics.stderr", qos: .utility)
            readGroup.enter()
            stderrQueue.async {
                box.errBuffer = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }

            process.terminationHandler = { proc in
                // 进程已退出,两条后台读取任务读到 EOF 会自然结束;等它们真正跑完再继续,
                // 避免极端情况下读任务还没来得及把最后一批数据处理完就被下面读到半份状态。
                readGroup.wait()
                guard proc.terminationStatus == 0 else {
                    let msg = String(data: box.errBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.error("search-lyrics exited \(proc.terminationStatus): \(msg ?? "", privacy: .public)")
                    continuation.resume(throwing: SearchError.processFailed(msg?.isEmpty == false ? msg! : String(format: L10n.t("退出码 %@"), "\(proc.terminationStatus)")))
                    return
                }
                continuation.resume(returning: ())
            }

            do {
                try process.run()
            } catch {
                // process.run() 失败(collector 二进制不存在/不可执行——比如没跑过
                // build.sh 就直接 swift run/.build/debug 调试,或者 Contents/Resources/
                // collector 被误删/损坏)——2026-08-02 实测排查坐实:早先这里只
                // resume 了 continuation,完全没有清理上面已经派发到 readQueue 的两个
                // 读取闭包。这两个闭包在 process.run() 之前就已经提交(为了不错过子
                // 进程刚起来就开始写的早期输出),它们各自阻塞在 fileHandleForReading
                // 的 availableData/readDataToEndOfFile 上等第一批数据/EOF——但 Process
                // 从未真正 fork/exec,写端从头到尾没有任何人写过、也没有任何人关闭过,
                // 读端永远读不到 EOF,这两个闭包会永久阻塞在 readQueue 上,且
                // process.terminationHandler 因为进程从未启动/终止而永远不会被调用,
                // 没有任何地方能发现或清理这个卡死状态——每次重试都会再泄漏一次。显式
                // 关闭两个管道的写端,让阻塞中的读取立刻观察到 EOF、正常退出循环。
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: SearchError.processFailed(error.localizedDescription))
            }
        }
    }
}

// 对应 collector 侧 searchcli.go 的 searchLyricsUpdate——字段名两边都是 lowerCamelCase,
// 不需要像下面 RawCandidate 那样额外声明 CodingKeys 做 snake_case 转换。
private struct RawSearchUpdate: Decodable {
    let candidates: [RawCandidate]
    let networkLooksDown: Bool
    let sourcesDone: Int?
    let sourcesTotal: Int?
    /// 第几轮全源检索,旧 collector 不发(解码方兜底成 1),见 SearchUpdate.round。
    let round: Int?
    let sourceFailureReasonCodes: [String: String]?
    /// collector 一直在输出这个信号,Swift 侧 2026-08-21 才开始接:它把"一个候选都没有"
    /// 分成"这首歌本来就没词"和"真的谁都没搜到"两种,「重新自动匹配」的结果文案要区分。
    ///
    /// 2026-08-22 起 collector 输出的正名是 `instrumental` —— 这个信号的来源早就不只 lrclib
    /// (网易云的 pureMusic、QQ 的占位断言),旧名字名不副实。两个 key 都读:
    /// 新 App + 旧 collector 时只有旧 key,旧 App + 新 collector 时靠 collector 那边的
    /// 同值别名兜住(见 searchcli.go 的 LegacyLrclibInstrumental,含删除条件)。
    let instrumental: Bool?
    /// 旧名,只为兼容尚未重建的 collector。collector 那边的同值别名删掉之后,这个也可以删。
    let lrclibInstrumental: Bool?
    /// 只有 -pick 且只有最后那行才有。
    let pick: LyricsSearchService.Pick?
}

private struct RawCandidate: Decodable {
    let source: String
    let lyrics: String
    let lyricsTr: String?
    let lyricsRoma: String?
    let lyricsYRC: String?
    let hasWordTiming: Bool
    let score: Int
    let scoreTerms: [LyricsSearchService.ScoreTerm]?
    let title: String?
    let artist: String?
    let album: String?
    let coverURL: String?
    let plainTextOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case source, lyrics, score, title, artist, album
        case lyricsTr = "lyrics_tr"
        case lyricsRoma = "lyrics_roma"
        case lyricsYRC = "lyrics_yrc"
        case hasWordTiming = "has_word_timing"
        case scoreTerms = "score_terms"
        case coverURL = "cover_url"
        case plainTextOnly = "plain_text_only"
    }
}

private extension LyricsSearchService.Candidate {
    init(_ raw: RawCandidate) {
        self.init(
            source: raw.source,
            lyrics: raw.lyrics,
            lyricsTr: raw.lyricsTr ?? "",
            lyricsRoma: raw.lyricsRoma ?? "",
            lyricsYRC: raw.lyricsYRC ?? "",
            hasWordTiming: raw.hasWordTiming,
            score: raw.score,
            scoreTerms: raw.scoreTerms ?? [],
            title: raw.title ?? "",
            artist: raw.artist ?? "",
            album: raw.album ?? "",
            coverURL: raw.coverURL.flatMap(URL.init(string:)),
            isPlainTextOnly: raw.plainTextOnly ?? false,
            lineCount: LyricsSearchService.Candidate.countLines(of: raw.lyrics)
        )
    }
}
