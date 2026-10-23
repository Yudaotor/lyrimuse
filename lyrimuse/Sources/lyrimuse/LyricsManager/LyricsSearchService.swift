import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-search")

/// `search-lyrics` 子进程 stderr 里那几类源健康信号的匹配标记。stderr 只在退出码非 0 时整段进日志(terminationHandler),
/// 而手动搜索这条路径上"网易云被限流了 / 某个源在退避"只写在 stderr 里,所以正常退出时也把这几行捞出来记进 os_log,
/// 事后才查得到。
///
/// 只捞这几行、不整段转录:一次搜索的 stderr 有几十行(每个源每一轮的 `api call:`),整段
/// 打进 os_log 会把日志刷成噪声,而真正需要事后复盘的就是"谁被拒了、谁在退避"。
/// 标记选的是 Go 侧英文格式串里的固定片段(`netease.go` 的 `rejected (code %d)`、
/// `sourcebreaker.go` 的 `cooling down`),不是中文文案 —— 那几处日志措辞改了,这里跟着改;别用会随语言变的词做判据。
private let searchLyricsHealthMarkers = ["rejected (code", "backing off", "cooling down"]

// "联网搜索候选歌词"——形态是这类工具常见的双栏候选面板,但**不**在 Swift 这边
// 重新实现网易云/QQ/酷狗/Musixmatch/LRCLIB 的检索逻辑(那会是第二份、迟早会跟 Go 引擎那份
// 走样的实现)。改用一次性子进程调用 `lyrimuse-engine search-lyrics`(lyrimuse-engine/searchcli.go),
// 复用 scoredLyricCandidates(lyrimuse-engine/enrich.go)——跟自动解析路径完全同一份取分/排序
// 代码,只是把"取最高分那个"换成"把全部候选连分数一起交给用户挑"。不新增常驻服务:
// 跟 EnrichCacheStore 的 launchctl kickstart 是同一种"偶尔手动操作,一次性子进程开销
// 可以接受"的取舍。
final class LyricsSearchService {
    static let shared = LyricsSearchService()

    /// 一个发起方:一个搜索面板(「搜索歌词…」窗口里的那一个)。调用方各自在 @State 里持有一个。
    ///
    /// 在跑的子进程按发起方分开记:同一个发起方起新一轮时把自己上一轮杀掉(「重新搜索」在搜索途中也放开,
    /// 不杀的话旧那一轮会把各源的兜底轮跑完,白占网络请求,结果反正被调用方的 generation 判作废),
    /// 但不碰别的发起方 —— 只记一个全局"当前在跑的"时,关掉一个面板会把另一扇窗里的搜索一起杀掉,
    /// 被杀的那边收到非零退出码、误报"搜索失败"。全局另有并发上限,见 `maxConcurrentProcesses`。
    struct Owner: Hashable, Sendable {
        private let id = UUID()
        init() {}
    }

    /// 一轮搜索的子进程句柄。取消可能早于进程起跑(Task 刚创建就被取消),所以先记下"已取消",起跑前查。
    private final class RunHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// 返回 false:这一轮已经被取消了,别再起进程。
        func attach(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// 用锁而不是 @MainActor:search() 的进程收尾在后台队列上,两边都要碰这张表。
    private let processLock = NSLock()
    private var running: [Owner: RunHandle] = [:]
    /// 每个发起方上一次起进程的时刻(processLock 保护),见 `minRelaunchInterval`。
    private var lastLaunch: [Owner: Date] = [:]

    /// 同时最多几个 search-lyrics 子进程。每个子进程都把全部歌词源问一遍,按主机的限速只在它自己进程里算,
    /// 几扇窗口同时搜等于对各源成倍地发请求(Musixmatch 遇到并发会弹验证码)。留两个:歌词窗口弹出的小窗不用等
    /// 歌词管理里正在跑的那一轮(一轮连兜底可能要一两分钟);再多的排队,先来先起。
    static let maxConcurrentProcesses = 2
    /// 同一个发起方两次起进程至少隔这么久:连点「重新搜索」时上一轮被杀,但它已经发出去的请求收不回来,
    /// 隔开一点,不让几次点击叠成几整轮请求。
    static let minRelaunchInterval: TimeInterval = 1
    /// 子进程跑这么久还没退出就停掉,当作这一轮结束(已经显示的候选照旧留着)。引擎每轮有 20 秒截止,
    /// 兜底轮叠起来也到不了这里;这是引擎卡住时的保险,不然转圈会一直转到关面板。
    static let processTimeout: TimeInterval = 240

    private let slots = ProcessSlots(limit: LyricsSearchService.maxConcurrentProcesses)

    /// 子进程名额:用满了的排队,先到先得;排队时调用方的 Task 被取消就离开队列。
    private final class ProcessSlots: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var inUse = 0
        private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

        init(limit: Int) { self.limit = limit }

        func acquire() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    // 取消可能先于这里落下(那时队列里还没有它,onCancel 什么都没摘到):进来先看一眼。
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                    } else if inUse < limit {
                        inUse += 1
                        lock.unlock()
                        continuation.resume()
                    } else {
                        waiters.append((id, continuation))
                        lock.unlock()
                    }
                }
            } onCancel: {
                lock.lock()
                let waiter = waiters.firstIndex { $0.id == id }.map { waiters.remove(at: $0) }
                lock.unlock()
                waiter?.continuation.resume(throwing: CancellationError())
            }
        }

        /// 还名额:有人在排队就直接交给排在最前的那个(占用数不变)。
        func release() {
            lock.lock()
            guard !waiters.isEmpty else {
                inUse -= 1
                lock.unlock()
                return
            }
            let next = waiters.removeFirst()
            lock.unlock()
            next.continuation.resume()
        }
    }

    /// 这个发起方上一次起进程不到 `minRelaunchInterval`:还差多久。
    private func relaunchDelay(for owner: Owner, now: Date) -> TimeInterval {
        processLock.lock()
        defer { processLock.unlock() }
        guard let last = lastLaunch[owner] else { return 0 }
        return max(0, Self.minRelaunchInterval - now.timeIntervalSince(last))
    }

    private func noteLaunch(for owner: Owner, at date: Date) {
        processLock.lock()
        lastLaunch[owner] = date
        processLock.unlock()
    }

    /// 取消这个发起方正在跑的那一轮(没有就什么都不做),别的发起方的不受影响。面板关掉时调,顺带忘掉它的起进程时刻。
    func cancelRunning(for owner: Owner) {
        processLock.lock()
        let handle = running.removeValue(forKey: owner)
        lastLaunch.removeValue(forKey: owner)
        processLock.unlock()
        handle?.cancel()
    }

    /// 登记这个发起方的新一轮,顶掉(并杀掉)它上一轮。
    private func register(_ handle: RunHandle, for owner: Owner) {
        processLock.lock()
        let previous = running.updateValue(handle, forKey: owner)
        processLock.unlock()
        previous?.cancel()
    }

    /// 这一轮结束时撤下登记;已经被同一发起方的新一轮顶掉了就不动。
    private func unregister(_ handle: RunHandle, for owner: Owner) {
        processLock.lock()
        if running[owner] === handle { running.removeValue(forKey: owner) }
        processLock.unlock()
    }

    struct ScoreTerm: Equatable, Decodable {
        let kind: String
        let points: Int

        /// 界面上显示的名字。认不出来的类型原样显示 kind —— 引擎以后加了新项目
        /// 也不会在这里显示成空白。
        var label: String {
            switch kind {
            case "duration": return L10n.t("时长吻合")
            case "corroborated": return L10n.t("结束点获印证")
            case "wordTiming": return L10n.t("逐字时间轴")
            // 引擎每一种 kind 在这里都要有译名,scoretermlabel_test.go 守着。
            case "nativeSource": return L10n.t("与当前播放器同源")
            case "lines": return L10n.t("行数")
            case "versionTags": return L10n.t("版本不符")
            case "durationOff": return L10n.t("时长不符")
            // v4:跟 durationOff 量的不是同一样东西,文案必须分得开 ——
            // 那个是「歌词铺到哪儿 vs 曲长」,这个是「源自己说这首歌多长 vs 本地多长」。
            case "sourceDurationOff": return L10n.t("源自报曲长不符")
            // v5:这是全批候选打完分之后才补的一项负分,只在"逐字加分是唯一
            // 让这个候选赢的理由,而另一个候选标题更吻合"时出现,见引擎侧
            // applyWordTimingTitleOverride 的注释。
            case "wordTimingOverride": return L10n.t("存在标题更吻合的候选，撤销逐字加分")
            // v7:「两场不同演唱会」判据,见引擎侧
            // liveAlbumIdentityConflict 的注释(陈奕迅 The Easy Ride vs Get A Life 案)。
            case "liveAlbumConflict": return L10n.t("现场版场次不符")
            // v23:见引擎侧 lyrictimelineoffset.go。
            case "timelineOffset": return L10n.t("时间轴整体偏移")
            // v24:见引擎侧 lyrictimelineintrusion.go。
            case "timelineIntrusion": return L10n.t("间奏中多出一段歌词")
            // v30.1:见引擎侧 sourcedurationanchor.go。
            case "sourceDurationNearMiss": return L10n.t("源自报曲长偏离吻合版本")
            // 与引擎 match.go 的 scoreTerm kind 一一对应。引擎不再给来源先验分,没有 "source" 这一项。
            case "durationOvershoot": return L10n.t("歌词超出曲长")
            case "album": return L10n.t("专辑吻合")
            case "titleMatch": return L10n.t("标题吻合")
            case "consensus": return L10n.t("内容获印证")
            case "translation": return L10n.t("自带译文")
            case "romanization": return L10n.t("自带读音")
            case "rejectNotTimed": return L10n.t("不含时间戳")
            case "rejectWrongLanguage": return L10n.t("语言不符")
            case "rejectCreditOnly": return L10n.t("仅含署名行，无正文")
            case "rejectNoLastTimestamp": return L10n.t("无法获取末句时间")
            case "rejectDurationMismatch": return L10n.t("时长明显不符，且无其他源印证")
            // 加:跟 rejectNotTimed 是同一类症状(没有时间戳)、不同的原因——
            // 那个是"疑似解析失败",这个是"这个源明确说了只有纯文本,压根没有带时间戳的版本"
            // (见引擎 match.go 的 scoreRejectPlainTextOnly 头注)。
            case "rejectPlainTextOnly": return L10n.t("仅有纯文本，无时间戳")
            // 见引擎 match.go 的 scoreRejectContinuousMix 头注。
            case "rejectContinuousMix": return L10n.t("连续混音版，与原版编排不同")
            // 见引擎 match.go 的 scoreRejectInstrumentalTrack 头注。
            case "rejectInstrumentalTrack": return L10n.t("伴奏版，不采用人声歌词")
            default: return kind
            }
        }

        /// 一句话解释这一项**是什么**、以及它的量程。
        ///
        /// 只给名字不够:用户看到「其它源印证了结束点 +100」完全不知道那是什么意思,也
        /// 不知道 +100 算多还是算少 —— 用户就是这么问过来的。名字回答"这是
        /// 哪一项",这句回答"它凭什么给分、满分多少"。
        var detail: String {
            switch kind {
            case "duration": return L10n.t("最后一句的时间越接近曲长，得分越高，最高 300")
            case "corroborated": return L10n.t("时长不符，但其他歌词源也在同一时间结束，予以采信")
            case "wordTiming": return L10n.t("带逐字（卡拉 OK）时间轴，是衡量歌词质量最直接的依据")
            case "nativeSource": return L10n.t("该源即当前使用的播放器，时间轴基于同一音频母版（+250）")
            case "lines": return L10n.t("一行 1 分，最多 200")
            case "durationOvershoot": return L10n.t("最后一句晚于歌曲结束 5 秒以上，可能是完整版歌词对应了精简版曲目")
            case "album": return L10n.t("该源匹配到的专辑与本地专辑一致，版本很可能正确（最高 150）")
            case "titleMatch": return L10n.t("完全同名 120 · 仅括号差异 60 · 中英双语同名 30")
            case "consensus": return L10n.t("歌词内容与其他歌词源高度一致（2 家及以上 250 · 1 家 150），版本不符的候选不计")
            case "translation": return L10n.t("附带当前译文语言的可用译文，同等候选中优先")
            case "romanization": return L10n.t("日文歌词自带读音，同水平候选间优先")
            case "versionTags": return L10n.t("歌名、专辑名或歌词文件头标注的版本（Live / Remix / Demo / Club Mix 等）与本地歌曲不符")
            case "sourceDurationOff":
                return L10n.t("该源标注的曲目时长与本地相差 12% 以上，可能对应另一个录音版本")
            case "wordTimingOverride":
                return L10n.t("该候选原本凭逐字时间轴领先，但另一个候选的标题更吻合查询词。它很可能是其他录音（如另一场现场版）的逐字版本，时间轴精细并不代表与当前播放对齐")
            case "liveAlbumConflict":
                return L10n.t("两者均为现场版，但该候选的专辑名对应另一场演出（如另一次巡演），其时间轴与当前录音无法对齐")
            case "timelineOffset":
                return L10n.t("至少两个曲长与本地一致、时间轴相互吻合的歌词源显示，这份歌词整体提前或延后 2.5 秒以上，可能是基于前奏长度不同的另一个母带制作，与当前播放会整首错位")
            case "timelineIntrusion":
                return L10n.t("至少两个时长与本地一致的歌词源显示此段为间奏、无歌词，而这份歌词在此处填入了其他段落的歌词，时间轴有误，播放至中段时将错位")
            case "sourceDurationNearMiss":
                return L10n.t("其他歌词源标注的曲目时长与本地一致，该源标注的时长却相差 5% 以上，可能是现场版、混音版等其他录音")
            case "durationOff":
                return L10n.t("最后一句的时间与曲长相差 25% 以上；仍可选用，但排在所有时长相符的候选之后")
            case "rejectDurationMismatch":
                return L10n.t("最后一句的时间与曲长相差 25% 以上，可能是其他版本")
            case "rejectPlainTextOnly":
                return L10n.t("该歌词源收录了这首歌曲，但仅有无时间戳的纯文本，可在「歌词窗口」中作为静态文字阅读，无法随播放逐字 / 逐行高亮")
            case "rejectInstrumentalTrack":
                return L10n.t("当前播放的是伴奏版（歌名或专辑标注为伴奏、纯音乐或 Instrumental），不采用人声版歌词，按纯音乐显示")
            case "rejectContinuousMix":
                return L10n.t("当前播放的是 DJ Mix 专辑中的片段（歌名带 [Mixed]，专辑名带 (DJ Mix)）。此类曲目截取自完整演出，前后带有过渡，时长与原版不同，原版歌词的时间轴无法对齐，且暂无歌词源收录混音版的时间轴")
            default: return ""
            }
        }

        var isRejection: Bool { kind.hasPrefix("reject") }

        /// 分数说明整段文案。一项一行、按贡献绝对值从大到小排 —— 用户真正在问的是
        /// "它凭什么排第一",答案该第一行就出现。跟"解析决策"弹窗共用同一份实现:
        /// 两处要是各写一份,措辞和排序规则迟早漂开。
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
        /// 搜索结果一个源一条,按来源认;缓存里存着的那一版另起一个,跟同一来源搜到的那条(可能是另一个版本)不撞。
        var id: String { isStored ? "stored:" + source : source }
        let source: String
        let lyrics: String
        let lyricsTr: String
        let lyricsRoma: String
        let lyricsYRC: String
        /// 背景人声轨(引擎的 lyrics_bg)与译文语言(lyrics_tr_lang)。不展示,
        /// 采纳时原样交给 saveEdit,条目跟自动选中这条候选时写的一样。
        let lyricsBG: String
        let lyricsTrLang: String
        /// 译文是从哪个源借来的(引擎的 lyrics_tr_from);空 = 自带的。采纳时交给 saveEdit,条目照样记成借来的。
        var lyricsTrFrom: String = ""
        /// 借来的假名标注(条目的 lyrics_kana),只有「当前使用」那一份带,预览读音跟播放时一致。
        var lyricsKana: String = ""
        let hasWordTiming: Bool
        let score: Int
        /// 这个分数的构成明细;被判 -1 时只有一项,内容是原因。引擎只给机器可读的
        /// 类型 + 分值,文案在这边本地化(见 ScoreTerm.label)——App 有中英两套界面。
        let scoreTerms: [ScoreTerm]
        // 这个源实际匹配到的歌名/歌手/专辑/封面——不同源可能匹配到同一首歌的不同版本
        // (不同专辑/live/合集),各自如实展示,不做跨源统一;不是每个源都能给全,LRCLIB
        // 没有封面这个概念,留空就是这个源确实没有,不是加载失败。
        let title: String
        let artist: String
        let album: String
        let coverURL: URL?
        // true 时 lyrics 装的是没有时间戳的纯文本(见引擎
        // scoredLyricCandidateResult.PlainTextOnly 头注)。跟别的候选不同,这条**不能**
        // 用来做逐字/逐行同步展示,只能当静态文字读——「搜索候选歌词」弹窗要用它决定
        // 要不要挂"无时间戳"警示标签,「歌词窗口」采纳后要用它决定走哪条渲染路径。
        let isPlainTextOnly: Bool

        // 给候选选择界面展示的补充特性——是否逐字这一项引擎已经算好(hasWordTiming),
        // 译文/罗马音/行数纯粹是本地字段是否非空/切行数,不需要引擎额外计算。
        var hasTranslation: Bool { !lyricsTr.isEmpty }
        var hasRomanization: Bool { !lyricsRoma.isEmpty }
        // CRLF 换行(酷狗候选常见)会让 split(separator:"\n") 按 Character 比较时把整份
        // 文本当一整行切不开——见 YRCParser/LRCParser.parse 同一处注释,这里先归一化成
        // 纯 "\n" 再切,否则这类候选会显示成"1 行"这种明显错误的行数。
        //
        // 存储属性、构造时算一次:lyrics 自构造起不可变,做成计算属性会让每次行渲染/
        // 预览重算都对整首歌词(2-10KB)重新跑两遍 replacingOccurrences + 一遍 split,
        // 纯属重复计算(sheet 的 body 重算入口很多:三个查询输入框每敲一键、每批
        // NDJSON 到达都整数组替换)。
        let lineCount: Int
        /// 「只取词」的内容指纹(ManualPickLock.fingerprint:不含时间戳/YRC/译文),构造时算一次
        /// (理由同 lineCount)。跨源同词标注与「当前使用」双判据都读它;空串 = 没有词。
        let fingerprint: String
        /// 每一行挂的时间戳(LyricsCandidateDuplicates.lineTimestamps),构造时算一次(理由同 lineCount)。
        /// 跨源同词标注拿它判「每行时间也一样」。
        let timeline: [[Int]]
        /// 这个源自己标注的曲目时长(秒),0 = 没给。只展示,跟这首歌比(`LyricsCandidateDuration`)。源自己不报、引擎借了
        /// 同一条录音别家报的(目前只有 amll,见引擎 amllCandidateDuration)也放这里,`durationBorrowedFrom` 记是哪家。
        var sourceDurationSecs: Double = 0
        /// 时长是借来的时,报这个时长的那一家的源名;源自己报的是空串。
        var durationBorrowedFrom = ""
        /// 不是这一轮搜到的,是这首歌现在缓存里存着的那一版(搜索面板一打开就先摆出来,没有分数)。
        var isStored = false

        static func countLines(of lyrics: String) -> Int {
            lyrics.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    // 每一行进度。networkLooksDown 由引擎侧统计"这一轮联网搜索期间发出的请求有没有全部失败"算出来
    // (见 networkobs.go 的 networkLooksDown()),调用方据此分清"这首歌真的没有网络歌词"和"网络整体不通",
    // 给不同的空状态文案。
    struct SearchUpdate {
        let candidates: [Candidate]
        let networkLooksDown: Bool
        /// 已经回来的歌词源 / 一共要等几个。语义(为什么分母只数开着的源、为什么
        /// applecover 不算)见 lyrimuse-engine/enrich.go 的 lyricSearchUpdateFunc 注释。
        let sourcesDone: Int
        let sourcesTotal: Int
        /// 第几轮全源检索,从 1 开始。兜底轮(首歌手变体/标题反查等,见
        /// lyrimuse-engine/enrich.go)每轮都重新扫全部源,sourcesDone 每轮从 0 重数——没有这个
        /// 字段时进度显示成"8/8 之后又回到 1/8",读起来像出了错。旧引擎不发这个
        /// 字段时解码成 1(单轮语义,跟没有兜底轮的观感一致)。
        let round: Int
        /// 这一轮里没给出候选的源,查得到原因的那几个——引擎侧
        /// lyricSourceFailureReasons(searchcli.go)算出来,分两层:源特有的具体原因只覆盖
        /// netease/musixmatch/lyricfind 三个已经接了诊断旁路的源;传输层通用原因(
        /// dns_failed / connect_failed / server_error,以及 AMLL 的 upstream_unreachable)任何
        /// 启用的源都可能带。给"歌词源可用情况"明细面板和空状态的「没连上」分组用。key 是源名,
        /// value 是**稳定代码**,不是文案(从 sourceFailureReasons 改名——见
        /// `LyricSourceFailureReason` 的头注,显示给用户前要先经
        /// `LyricSourceFailureReason.text(forCode:)` 翻译);两层都没命中的源不会出现在这个
        /// 字典里(比如拿到了 200 / 404 但没这首歌),不编一个没核实过的理由。
        let sourceFailureReasonCodes: [String: String]
        /// 至少一个源明确说这首是纯音乐(不只 lrclib,网易云 pureMusic 也会置位)。
        /// 用来把"一个候选都没有"这个结局分成"这首歌本来就没词"和"真的谁都没搜到"。
        let instrumental: Bool
        /// 这一轮里**曲库里有这首歌、但平台上没有歌词文本**的那几个源(目前
        /// netease/qq 会给)。空 = 没有任何源给出这个结论。
        ///
        /// 它把原来笼统的"十个源都没找到可用的候选"再切一刀:匹配其实是**对的**,只是平台
        /// 还没收录歌词。这两种结局对用户意味着完全不同的下一步 —— 一个是"搜索词可能有问题,
        /// 改改再搜",另一个是"等平台补词,或者自己往 lyrics/ 放一份"。
        ///
        /// 别跟 `sourceFailureReasonCodes` 混为一谈:那个是"源坏了",这个是**查成功了**
        /// 的结论,所以引擎侧特意走了独立字段(见 searchcli.go 的 TracksFoundNoLyrics)。
        let tracksFoundNoLyrics: [TrackFoundNoLyrics]
    }

    /// 一个源"我这儿有这首歌,但没有词"的完整说法。除了是哪个源,还带上它**实际匹配到的**
    /// 曲目元数据 —— 用户看到"没搜到歌词"时的第一个疑问是"是不是搜错歌了",把匹配到的
    /// 歌名/歌手/专辑/时长摆出来才答得上这个问题。各字段都可能为空/0(源没给),按有什么显示什么。
    struct TrackFoundNoLyrics: Decodable, Equatable {
        let source: String
        let title: String
        let artist: String
        let album: String
        let durationSecs: Double

        // 手写 init(from:) 之后编译器不再合成 CodingKeys,得自己声明。字段名两边一致
        // (引擎侧是 lowerCamelCase 的 json tag),不需要做名字转换。
        private enum CodingKeys: String, CodingKey {
            case source, title, artist, album, durationSecs
        }

        // 引擎侧除 source 外都带 omitempty,缺字段是常态 —— 逐个 decodeIfPresent,
        // 一个字段没给不该让整行解码失败、把这一批更新整批丢掉(跟 SearchUpdate 那边同一条纪律)。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
            album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
            durationSecs = try c.decodeIfPresent(Double.self, forKey: .durationSecs) ?? 0
        }

        init(source: String, title: String = "", artist: String = "", album: String = "", durationSecs: Double = 0) {
            self.source = source
            self.title = title
            self.artist = artist
            self.album = album
            self.durationSecs = durationSecs
        }
    }

    enum SearchError: LocalizedError {
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .processFailed(let msg): return String(format: L10n.t("搜索失败：%@"), msg)
            }
        }
    }

    // 用包里那份引擎(LyrimusePaths.bundledEnginePath),每次 build.sh 重新打包都会跟着更新。
    private static let enginePath = LyrimusePaths.bundledEnginePath

    private init() {}

    // durationSecs 传 0 表示"没有可靠的真实时长"——歌词管理窗口浏览的是任意历史缓存
    // 条目,enrichEntry 本来就不持久化时长;引擎侧 scoreLyricCandidate 对
    // durationSecs<=0 有专门处理,直接跳过时长匹配这档评分(不会除零/不会被误判成
    // "时长对不上"),只退化成语言/署名行过滤+逐字加分+来源优先级+行数。
    //
    // onUpdate 按子进程 stdout 的进度行调用(NDJSON,见 searchcli.go):谁先查完谁先打印一行,每一行都是
    // 目前为止已知全部候选重新排序过的完整列表,不是只有新到的这一条(引擎侧 corroboratedEndings 是跨候选
    // 互相印证的信号,后到的源可能改变已经展示出来的某条候选的分数)。所以一批数据里攒了好几行时只交最后一行。
    // 调用方(「搜索候选歌词」面板)因此能做到"谁先搜到就先展示谁,列表随后续源陆续刷新"。回调固定在
    // MainActor 上执行,调用方可以直接改 @State,不需要自己再跳线程。
    /// - owner: 发起方,见 `Owner`。
    /// - key: 这首在缓存里的 key 原样,交给引擎查条目(见引擎 search-lyrics 的 -key);查询词被用户改过时传 nil。
    func search(
        owner: Owner,
        artist: String, title: String, album: String, durationSecs: Double = 0, key: String? = nil,
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {
        // withTaskCancellationHandler:调用方的 Task 被取消(.task 随视图消失、或 searchGeneration 换代)时顺手终结
        // 子进程,不让它对着已经消失的视图把各源跑完(面板侧另有 onDisappear,两层谁先到谁生效,取消幂等)。
        // 取消只停**这一轮**的子进程:同一发起方紧接着起的新一轮不会被旧任务迟到的取消误杀。
        let handle = RunHandle()
        register(handle, for: owner)
        defer { unregister(handle, for: owner) }
        // 连点「重新搜索」:离上一次起进程不到 minRelaunchInterval 就先等一下(上一轮已经被 register 杀掉了)。
        let delay = relaunchDelay(for: owner, now: Date())
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try await slots.acquire()
        defer { slots.release() }
        // 等名额的时候被同一发起方的新一轮顶掉了:不起进程。
        if handle.isCancelled { throw CancellationError() }
        noteLaunch(for: owner, at: Date())
        try await withTaskCancellationHandler {
            try await performSearch(handle: handle, artist: artist, title: title, album: album,
                                    durationSecs: durationSecs, key: key, onUpdate: onUpdate)
        } onCancel: {
            handle.cancel()
        }
    }

    /// 一次搜索收尾时写进 App 日志的那一行。没收到任何一行进度(进程一起来就挂了 / 被马上停掉)时各项按空写。
    fileprivate static func completionSummary(title: String, artist: String, update: RawSearchUpdate?,
                                              elapsed: TimeInterval, cancelled: Bool, status: Int32) -> String {
        let responded = update.map { Array(Set($0.candidates.map(\.source))).sorted() } ?? []
        let reasons = (update?.sourceFailureReasonCodes ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let outcome = cancelled ? "cancelled" : (status == 0 ? "done" : "exited \(status)")
        return "search-lyrics \(outcome): \"\(artist)\" - \"\(title)\" round=\(update?.round ?? 0) "
            + "sources=\(update?.sourcesDone ?? 0)/\(update?.sourcesTotal ?? 0) responded=[\(responded.joined(separator: ","))] "
            + "reasons=[\(reasons.joined(separator: ","))] candidates=\(update?.candidates.count ?? 0) "
            + "networkDown=\(update?.networkLooksDown ?? false) elapsed=\(String(format: "%.1f", elapsed))s"
    }

    /// 子进程失败时给界面看的一句:stderr 是引擎的整段日志(可能几十行英文,还带时间戳),原样塞进弹窗
    /// 会把「重试」挤出窗口。只取最后一行非空的(出错原因通常在最后)、剥掉 Go log 的时间戳前缀、截到 160 字;
    /// 全文已经进了日志。
    static func failureSummary(_ stderr: String) -> String {
        guard var line = stderr.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) else { return "" }
        if let r = line.range(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? "#, options: .regularExpression) {
            line.removeSubrange(r)
        }
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    private func performSearch(
        handle: RunHandle,
        artist: String, title: String, album: String, durationSecs: Double, key: String?,
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.enginePath)
            // 子命令必须跟本 App 同一份配置目录 / 日志文件,见 LyrimusePaths.engineEnvironment。
            process.environment = LyrimusePaths.engineProcessEnvironment()
            process.arguments = [
                "search-lyrics",
                "-artist", artist,
                "-title", title,
                "-album", album,
                "-duration", String(durationSecs),
            ]
            if let key, !key.isEmpty { process.arguments?.append(contentsOf: ["-key", key]) }
            // 同源加权(打分里那条 +250「与当前播放器同源」)要知道**现在在放的是哪个
            // 播放器** —— 它的立论是"时间轴对着同一份音频母版",那是正在播的那个播放器的
            // 属性。这条 CLI 是独立进程,拿不到播放状态,只能由这边传。
            //
            // 在此之前引擎那边是按 `features.Players`(**设置里勾了
            // 哪些播放器**)算的,六个全勾的用户会让酷狗/网易云/QQ 三个源同时拿到 +250 ——
            // 「解析决策」面板上"这个源就是你正在用的播放器"对三个都是假话,而且这一项的
            // 区分力被自己抵消掉了。详见引擎侧 match.go 里 nativeLyricSources 的注释。
            //
            // 取值沿用 `LyricsWindowView.idlePlayer` 那条既有先例:LocalPlaybackSource 把
            // 当前播放器 bundle id 落在这个键上(停播时快照清空、只有它还记得)。 取不到
            // 就**不传**,引擎那边认不出会让这一项不加分 —— 宁可少加一项也不要加错。
            if let playerBundleID = UserDefaults.standard.string(forKey: "np:lastPlayerBundleID"),
               !playerBundleID.isEmpty
            {
                process.arguments?.append(contentsOf: ["-player", playerBundleID])
            }
            // 记到这一轮的句柄上,好让取消(同一发起方的下一轮、调用方 Task 取消)能杀掉我。
            guard handle.attach(process) else {
                continuation.resume(throwing: CancellationError())
                return
            }

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
            // 用 @unchecked Sendable 包一层:outBuffer / lastUpdate 只在 readQueue 上写,errBuffer 只在 stderrQueue 上写,
            // 各自串行;terminationHandler 经 readGroup.wait() 之后才读,happens-before 由 group 保证。timedOut 由超时那一下
            // 在主队列上置位、terminationHandler 读,用 timeoutLock 护着。Swift 6 严格并发检查认不出这些先后关系,只能显式声明。
            final class Box: @unchecked Sendable {
                var outBuffer = Data()
                var errBuffer = Data()
                /// 最后一行进度,收尾时写那行汇总用。
                var lastUpdate: RawSearchUpdate?
                let timeoutLock = NSLock()
                var timedOut = false
            }
            let box = Box()
            let startedAt = Date()
            let readQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.search-lyrics.stdout", qos: .utility)
            let readGroup = DispatchGroup()

            // 按 \n 切行。半行(还没读到换行符的尾巴)留在 outBuffer 里等下一批数据补全,不会被当成一行提前误判。
            // 这一批里凑齐了好几行时只解码、只回调最后能解开的那一行:每一行都是到那时为止的完整列表,前面几行
            // 解了也是马上被盖掉(一行带着全部候选的整份歌词,解码和指纹都不便宜)。
            func drainCompleteLines() {
                var lines: [Data] = []
                while let newlineRange = box.outBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = box.outBuffer.subdata(in: box.outBuffer.startIndex..<newlineRange.lowerBound)
                    box.outBuffer.removeSubrange(box.outBuffer.startIndex..<newlineRange.upperBound)
                    if !lineData.isEmpty { lines.append(lineData) }
                }
                for lineData in lines.reversed() {
                    guard let raw = try? JSONDecoder().decode(RawSearchUpdate.self, from: lineData) else {
                        logger.error("search-lyrics: failed to decode a stdout line, skipping")
                        continue
                    }
                    box.lastUpdate = raw
                    let update = SearchUpdate(
                        candidates: raw.candidates.map(Candidate.init),
                        networkLooksDown: raw.networkLooksDown,
                        // 可选 + 兜底 0:字段缺失不该让整行解码失败、把这一批候选整批丢掉。
                        sourcesDone: raw.sourcesDone ?? 0,
                        sourcesTotal: raw.sourcesTotal ?? 0,
                        round: raw.round ?? 1, // 旧引擎不发,按单轮兜底,见 SearchUpdate.round
                        sourceFailureReasonCodes: raw.sourceFailureReasonCodes ?? [:],
                        instrumental: raw.instrumental ?? false,
                        // 引擎带 omitempty,没有时不出现 —— 解码成空数组,界面退回那句笼统的"没找到候选"。
                        tracksFoundNoLyrics: raw.tracksFoundNoLyrics ?? [])
                    // 走主队列而不是各起一个 MainActor Task:收尾的 continuation 也从主队列恢复(见 terminationHandler),
                    // 同一条串行队列先进先出,最后那行一定先于 search() 返回送到;各起 Task 的顺序语言层面不保证。
                    DispatchQueue.main.async { MainActor.assumeIsolated { onUpdate(update) } }
                    break
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
            // stderr 在**独立**队列上读:跟 stdout 排在同一条串行队列上的话,它要等 stdout 读到 EOF 才开始读,
            // stderr 写满 64KB 时上面那段说的管道死锁就出在 stderr 这一侧。两条管道并行排空。
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
                // 是这边主动停的(同一发起方起了新一轮、调用方 Task 取消、面板关了):不是失败,别报「搜索失败」。
                // 超时是这边停的:按正常结束收尾(已经显示的候选留着),不报「搜索失败」。
                box.timeoutLock.lock()
                let timedOut = box.timedOut
                box.timeoutLock.unlock()
                let cancelled = handle.isCancelled && !timedOut
                let status = proc.terminationStatus
                // 按 UTF-8 容错解码:中间夹了一个坏字节也不至于整段丢掉(丢了的话下面的源健康信号一行都不记)。
                let stderrText = String(decoding: box.errBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                // 每次搜索一行汇总:哪些源给了候选、没给的源报了什么原因、跑了几轮几秒。手动搜索只搜到两三个源时,
                // 事后能查到是哪几个源没回、为什么(见 11 章决策 97)。
                let summary = Self.completionSummary(
                    title: title, artist: artist, update: box.lastUpdate,
                    elapsed: Date().timeIntervalSince(startedAt), cancelled: cancelled, status: status)
                logger.notice("\(summary, privacy: .public)")
                if timedOut {
                    logger.error("search-lyrics still running after \(Int(Self.processTimeout))s, stopped it")
                } else if !cancelled {
                    if status == 0 {
                        Self.logSourceHealthSignals(box.errBuffer)
                    } else {
                        logger.error("search-lyrics exited \(status): \(stderrText, privacy: .public)")
                    }
                }
                // 排在所有逐行回调后面恢复(同一条主队列,见 drainCompleteLines);文案也在主线程上取 ——
                // L10n.t 的缓存没有加锁。
                DispatchQueue.main.async {
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if status != 0 && !timedOut {
                        let summary = Self.failureSummary(stderrText)
                        continuation.resume(throwing: SearchError.processFailed(
                            summary.isEmpty ? String(format: L10n.t("退出码 %@"), "\(status)") : summary))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }

            do {
                try process.run()
                // 取消落在 attach 和 run 之间时 cancel() 看到的进程还没跑、没发终止信号:起来之后再核一次,已取消就马上停,
                // 收尾照常走 terminationHandler 的取消那一支。
                if handle.isCancelled { process.terminate() }
                // 超时保险(见 processTimeout):到点还在跑就停掉,收尾走 terminationHandler 的超时那一支。
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.processTimeout) { [weak process] in
                    guard let process, process.isRunning else { return }
                    box.timeoutLock.lock()
                    box.timedOut = true
                    box.timeoutLock.unlock()
                    process.terminate()
                }
            } catch {
                // process.run() 失败(引擎二进制不存在 / 不可执行):上面两个读取闭包已经派出去、各自阻塞在读端等数据或 EOF,
                // 进程从没起来,写端也就没人关,它们会永远卡着,terminationHandler 也永远不会来。关掉两个管道的写端,
                // 让读取立刻读到 EOF 退出。
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: SearchError.processFailed(error.localizedDescription))
            }
        }
    }
}

// 对应引擎侧 searchcli.go 的 searchLyricsUpdate——字段名两边都是 lowerCamelCase,
// 不需要像下面 RawCandidate 那样额外声明 CodingKeys 做 snake_case 转换。
private struct RawSearchUpdate: Decodable {
    let candidates: [RawCandidate]
    let networkLooksDown: Bool
    let sourcesDone: Int?
    let sourcesTotal: Int?
    /// 第几轮全源检索,旧引擎不发(解码方兜底成 1),见 SearchUpdate.round。
    let round: Int?
    let sourceFailureReasonCodes: [String: String]?
    /// 有源明确说这首是纯音乐(引擎带 omitempty,不是时不出现)。搜索面板据此把"一个候选都没有"
    /// 分成"这首歌本来就没词"和"真的谁都没搜到"两种。
    let instrumental: Bool?
    /// "曲库里有这首歌、但平台上没有歌词文本"的那几个源。旧引擎不发,
    /// 可选 + 解码方兜底成空数组,见 SearchUpdate.tracksFoundNoLyrics。
    let tracksFoundNoLyrics: [LyricsSearchService.TrackFoundNoLyrics]?
}

private struct RawCandidate: Decodable {
    let source: String
    let lyrics: String
    let lyricsTr: String?
    let lyricsRoma: String?
    let lyricsYRC: String?
    let lyricsBG: String?
    let lyricsTrLang: String?
    let lyricsTrFrom: String?
    let hasWordTiming: Bool
    let score: Int
    let scoreTerms: [LyricsSearchService.ScoreTerm]?
    let title: String?
    let artist: String?
    let album: String?
    let coverURL: String?
    /// 自己没有封面时借同一条录音那条候选的(引擎 `applyBorrowedCovers`),只用来显示缩略图。
    let borrowedCoverURL: String?
    let plainTextOnly: Bool?
    let sourceReportedDurationSecs: Double?
    let borrowedDurationSecs: Double?
    let borrowedDurationFrom: String?

    enum CodingKeys: String, CodingKey {
        case source, lyrics, score, title, artist, album
        case lyricsTr = "lyrics_tr"
        case lyricsRoma = "lyrics_roma"
        case lyricsYRC = "lyrics_yrc"
        case lyricsBG = "lyrics_bg"
        case lyricsTrLang = "lyrics_tr_lang"
        case lyricsTrFrom = "lyrics_tr_from"
        case hasWordTiming = "has_word_timing"
        case scoreTerms = "score_terms"
        case coverURL = "cover_url"
        case borrowedCoverURL = "borrowed_cover_url"
        case plainTextOnly = "plain_text_only"
        case sourceReportedDurationSecs = "source_reported_duration_secs"
        case borrowedDurationSecs = "borrowed_duration_secs"
        case borrowedDurationFrom = "borrowed_duration_from"
    }
}

private extension LyricsSearchService.Candidate {
    init(_ raw: RawCandidate) {
        let reported = raw.sourceReportedDurationSecs ?? 0
        let borrowed = reported > 0 ? 0 : raw.borrowedDurationSecs ?? 0
        self.init(
            source: raw.source,
            lyrics: raw.lyrics,
            lyricsTr: raw.lyricsTr ?? "",
            lyricsRoma: raw.lyricsRoma ?? "",
            lyricsYRC: raw.lyricsYRC ?? "",
            lyricsBG: raw.lyricsBG ?? "",
            lyricsTrLang: raw.lyricsTrLang ?? "",
            lyricsTrFrom: raw.lyricsTrFrom ?? "",
            hasWordTiming: raw.hasWordTiming,
            score: raw.score,
            scoreTerms: raw.scoreTerms ?? [],
            title: raw.title ?? "",
            artist: raw.artist ?? "",
            album: raw.album ?? "",
            coverURL: [raw.coverURL, raw.borrowedCoverURL].compactMap { $0 }.first { !$0.isEmpty }.flatMap(URL.init(string:)),
            isPlainTextOnly: raw.plainTextOnly ?? false,
            lineCount: LyricsSearchService.Candidate.countLines(of: raw.lyrics),
            fingerprint: ManualPickLock.fingerprint(lyrics: raw.lyrics),
            timeline: LyricsCandidateDuplicates.lineTimestamps(raw.lyrics),
            sourceDurationSecs: reported > 0 ? reported : borrowed,
            durationBorrowedFrom: borrowed > 0 ? raw.borrowedDurationFrom ?? "" : ""
        )
    }
}

// MARK: - 子进程 stderr 里的源健康信号

extension LyricsSearchService {
    /// 把 `search-lyrics` 的 stderr 里"某个源被拒/在退避"那几行收进 App 日志。
    ///
    /// 用 `.notice` 而不是 `.debug`:`.debug` 在 os_log 里默认**不落盘**(内存环形缓冲、随时
    /// 被丢),而 `DiagnosticsExporter.recentAppLogLines()` 是按 subsystem 事后查询的 ——
    /// 用 debug 等于白记。也正因为会落盘,这里必须限量:只捞匹配标记的行、最多 12 行。
    ///
    /// 只在**退出码 0** 那条路径上调它。非 0 时 terminationHandler 已经把整段 stderr
    /// 原样打进 `logger.error` 了,再捞一遍就是重复。
    fileprivate static func logSourceHealthSignals(_ stderr: Data) {
        guard !stderr.isEmpty else { return }
        let text = String(decoding: stderr, as: UTF8.self)
        let hits = text.split(separator: "\n").filter { line in
            searchLyricsHealthMarkers.contains { line.contains($0) }
        }
        guard !hits.isEmpty else { return }
        let shown = hits.prefix(12)
        for line in shown {
            logger.notice("search-lyrics: \(line.trimmingCharacters(in: .whitespaces), privacy: .public)")
        }
        if hits.count > shown.count {
            logger.notice("search-lyrics: \(hits.count - shown.count, privacy: .public) more lines of the same signal not logged (cap 12 per run)")
        }
    }
}
