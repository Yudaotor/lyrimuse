import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-search")

/// `search-lyrics` 子进程 stderr 里那几类**源健康信号**的匹配标记。
///
/// 此前 stderr 只在**退出码非 0** 时才被打进日志(见 terminationHandler
/// 里那句 `logger.error`),正常退出时整段丢掉 —— 而手动搜索这条路径上所有的"网易云被限流
/// 了/某个源在退避"都只写在那段 stderr 里,于是 `~/Library/Logs/lyrimuse.log`(常驻
/// 引擎那半边)里**一条都查不到**:实测 `grep -c "code 405"` = 0,而同一时刻界面上
/// 正显示着「网易云接口限流」。事后复盘"到底有没有被限流过"这件事,在这条路径上做不到。
///
/// 只捞这几行、不整段转录:一次搜索的 stderr 有几十行(每个源每一轮的 `api call:`),整段
/// 打进 os_log 会把日志刷成噪声,而真正需要事后复盘的就是"谁被拒了、谁在退避"。
/// 标记选的是 Go 侧**英文格式串里的固定片段**(`netease.go` 的 `rejected (code %d)`、
/// `sourcebreaker.go` 的 `cooling down`),不是中文文案 —— 那几处日志将来要是本地化了、
/// 或者措辞改了,这里跟着改;别用会随语言变的词做判据。
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

    /// 一个发起方:一个搜索面板(歌词管理里的、悬浮窗「搜索歌词…」小窗里的各算一个)、详情页的
    /// 「重新自动匹配」。调用方各自在 @State 里持有一个。
    ///
    /// 在跑的子进程按发起方分开记:同一个发起方起新一轮时把自己上一轮杀掉(「重新搜索」在搜索途中也放开,
    /// 不杀的话旧那一轮会跑满 20 秒兜底,白占九个源的网络请求,结果反正被调用方的 generation 判作废),
    /// 但不碰别的发起方 —— 只记一个全局"当前在跑的"时,关掉一个面板会把另一扇窗里的搜索、或者正在跑的
    /// 自动匹配一起杀掉,被杀的那边收到非零退出码、误报"搜索失败"。
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

    /// 取消这个发起方正在跑的那一轮(没有就什么都不做),别的发起方的不受影响。
    func cancelRunning(for owner: Owner) {
        processLock.lock()
        let handle = running.removeValue(forKey: owner)
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
            // 补:这一项自就在打分里,却一直没有译名 ——
            // 是新加的 scoretermlabel_test.go 守卫测试当场逮出来的既有漏网。
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
            // v3新维度,与引擎 match.go 的 scoreTerm kind 一一对应。
            // 旧 "source" case 已删:来源先验分从引擎移除后,score_terms 只来自
            // 实时搜索(不落缓存),不存在还带着旧字段的数据,这个分支是死代码。
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
            // 加,见引擎 match.go 的 scoreRejectContinuousMix 头注。
            case "rejectContinuousMix": return L10n.t("连续混音版，与原版编排不同")
            // 见引擎 match.go 的 scoreRejectInstrumentalTrack 头注。
            case "rejectInstrumentalTrack": return L10n.t("伴奏版，不用人声歌词")
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
            case "translation": return L10n.t("自带当前译文语言的可用译文，同水平候选间优先")
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
                return L10n.t("至少两个曲长与本地一致的歌词源显示这一段是间奏、没有歌词，而这份歌词在此处放入了其他段落的歌词，时间轴有误，播放到中段时会错位")
            case "durationOff":
                return L10n.t("最后一句的时间与曲长相差 25% 以上；仍可选用，但排在所有时长相符的候选之后")
            case "rejectDurationMismatch":
                return L10n.t("最后一句的时间与曲长相差 25% 以上，可能是其他版本")
            case "rejectPlainTextOnly":
                return L10n.t("该源收录了这首歌曲，但只有不带时间戳的纯文本，可在「歌词窗口」中作为静态文字阅读，无法随播放逐字 / 逐行高亮")
            case "rejectInstrumentalTrack":
                return L10n.t("当前播放的是伴奏版（歌名或专辑标着伴奏 / 纯音乐 / Instrumental），没有人声，人声版歌词不采用，按纯音乐显示")
            case "rejectContinuousMix":
                return L10n.t("当前播放的是 DJ Mix 专辑中的一段（歌名带 [Mixed]、专辑带 (DJ Mix)）。这类曲目截取自整场演出，前后带有过渡，长度与原版不同，原版歌词的时间轴无法对齐，且没有歌词源收录混音版的时间轴")
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
        var id: String { source }
        let source: String
        let lyrics: String
        let lyricsTr: String
        let lyricsRoma: String
        let lyricsYRC: String
        /// 背景人声轨(引擎的 lyrics_bg,只有 amll / applemusic 给)与译文语言(lyrics_tr_lang)。不展示,
        /// 采纳时原样交给 saveEdit,条目跟自动选中这条候选时写的一样。
        let lyricsBG: String
        let lyricsTrLang: String
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
        // 加——true 时 lyrics 装的是没有时间戳的纯文本(见引擎
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

        static func countLines(of lyrics: String) -> Int {
            lyrics.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    // 补上——之前 onUpdate 只传候选数组,九个源都没查到候选时,弹窗只能显示
    // 一句笼统的"都没找到",分不清是这首歌真的没有网络歌词,还是网络整体不通导致九个源
    // 的请求全部发不出去。networkLooksDown 由引擎侧统计"这一轮联网搜索期间发出
    // 的请求有没有全部失败"算出来(见 networkobs.go 的 networkLooksDown()),这里原样
    // 转发给调用方决定展示哪种空状态文案。
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
    // onUpdate 每收到子进程一整行 stdout 就调用一次(不是等进程退出才调一次)——
    // 引擎那边(searchcli.go)改成了 NDJSON:谁先查完谁先打印一行,后面每一行是
    // 目前为止已知全部候选重新排序过的完整列表,不是只有新到的这一条(引擎侧
    // corroboratedEndings 是跨候选互相印证的信号,后到的源可能改变已经展示出来的某条
    // 候选的分数,所以每次都要整份重新展示,不能只追加新的那一条)。调用方(desktop-
    // lyrics 的"搜索候选歌词"弹窗)因此能做到"谁先搜到就先展示谁,列表随后续源陆续
    // 刷新",不用等最慢的源(或者 20 秒兜底超时)才看到任何东西。回调固定在
    // MainActor 上执行,调用方可以直接改 @State,不需要自己再跳线程。
    /// - owner: 发起方,见 `Owner`。
    func search(
        owner: Owner,
        artist: String, title: String, album: String, durationSecs: Double = 0,
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {
        // withTaskCancellationHandler:调用方的 Task 被取消(.task 随视图消失、或
        // searchGeneration 换代)时顺手终结子进程 —— 原来没有任何取消接线,sheet 关掉/
        // 采纳候选后引擎子进程照跑满(九个源、20 秒兜底),NDJSON 还在往已消失的
        // 视图里灌,全是无人消费的废工(性能审计;sheet 侧另有 onDisappear
        // 兜底,两层都在,谁先到谁生效——取消幂等)。取消只停**这一轮**的子进程:同一发起方
        // 紧接着起的新一轮不会被旧任务迟到的取消误杀。
        let handle = RunHandle()
        register(handle, for: owner)
        defer { unregister(handle, for: owner) }
        try await withTaskCancellationHandler {
            try await performSearch(handle: handle, artist: artist, title: title, album: album,
                                    durationSecs: durationSecs, onUpdate: onUpdate)
        } onCancel: {
            handle.cancel()
        }
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
        artist: String, title: String, album: String, durationSecs: Double,
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.enginePath)
            // 子命令必须跟本 App 同一份配置目录 / 日志文件(Dev 构建是另一套),见 LyrimusePaths.engineEnvironment。
            process.environment = LyrimusePaths.engineProcessEnvironment()
            process.arguments = [
                "search-lyrics",
                "-artist", artist,
                "-title", title,
                "-album", album,
                "-duration", String(durationSecs),
            ]
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
                        round: raw.round ?? 1, // 旧引擎不发,按单轮兜底,见 SearchUpdate.round
                        sourceFailureReasonCodes: raw.sourceFailureReasonCodes ?? [:],
                        instrumental: raw.instrumental ?? false,
                        // 引擎带 omitempty,没有时不出现 —— 解码成空数组,界面退回那句笼统的"没找到候选"。
                        tracksFoundNoLyrics: raw.tracksFoundNoLyrics ?? [])
                    // 走主队列而不是各起一个 MainActor Task:收尾的 continuation 也从主队列恢复(见 terminationHandler),
                    // 同一条串行队列先进先出,最后那行一定先于 search() 返回送到;各起 Task 的顺序语言层面不保证。
                    DispatchQueue.main.async { MainActor.assumeIsolated { onUpdate(update) } }
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
            // stderr 必须在**独立**队列上读:readQueue 是串行的,原来这条
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
                // 是这边主动停的(同一发起方起了新一轮、调用方 Task 取消、面板关了):不是失败,别报「搜索失败」。
                let cancelled = handle.isCancelled
                let status = proc.terminationStatus
                let stderrText = String(data: box.errBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cancelled {
                    if status == 0 {
                        Self.logSourceHealthSignals(box.errBuffer)
                    } else {
                        logger.error("search-lyrics exited \(status): \(stderrText ?? "", privacy: .public)")
                    }
                }
                // 排在所有逐行回调后面恢复(同一条主队列,见 drainCompleteLines);文案也在主线程上取 ——
                // L10n.t 的缓存没有加锁。
                DispatchQueue.main.async {
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if status != 0 {
                        let summary = Self.failureSummary(stderrText ?? "")
                        continuation.resume(throwing: SearchError.processFailed(
                            summary.isEmpty ? String(format: L10n.t("退出码 %@"), "\(status)") : summary))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }

            do {
                try process.run()
            } catch {
                // process.run() 失败(引擎二进制不存在/不可执行——比如没跑过
                // build.sh 就直接 swift run/.build/debug 调试,或者 Contents/Resources/
                // 引擎被误删/损坏)——实测排查坐实:早先这里只
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
        case lyricsBG = "lyrics_bg"
        case lyricsTrLang = "lyrics_tr_lang"
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
            lyricsBG: raw.lyricsBG ?? "",
            lyricsTrLang: raw.lyricsTrLang ?? "",
            hasWordTiming: raw.hasWordTiming,
            score: raw.score,
            scoreTerms: raw.scoreTerms ?? [],
            title: raw.title ?? "",
            artist: raw.artist ?? "",
            album: raw.album ?? "",
            coverURL: raw.coverURL.flatMap(URL.init(string:)),
            isPlainTextOnly: raw.plainTextOnly ?? false,
            lineCount: LyricsSearchService.Candidate.countLines(of: raw.lyrics),
            fingerprint: ManualPickLock.fingerprint(lyrics: raw.lyrics),
            timeline: LyricsCandidateDuplicates.lineTimestamps(raw.lyrics)
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
        guard !stderr.isEmpty, let text = String(data: stderr, encoding: .utf8) else { return }
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
