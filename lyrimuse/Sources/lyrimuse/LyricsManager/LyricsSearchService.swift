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
    /// 不杀掉的话,旧那一轮会继续跑满(最长 20 秒兜底超时),白占五个源的网络请求 —— 结果
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
            case "lines": return L10n.t("行数")
            case "versionTags": return L10n.t("版本不符")
            case "durationOff": return L10n.t("时长不符")
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
            case "lines": return L10n.t("一行 1 分，最多 200")
            case "durationOvershoot": return L10n.t("最后一句比歌曲结束还晚 5 秒以上，多半是完整版歌词配了精简版曲目")
            case "album": return L10n.t("这个源匹配到的专辑跟本地专辑一致，版本大概率对（最多 150）")
            case "titleMatch": return L10n.t("完全同名 120 · 仅括号差异 60 · 中英双语同名 30")
            case "consensus": return L10n.t("歌词内容跟其它来源高度一致（2 家以上 250 · 1 家 150），串版本的拿不到")
            case "translation": return L10n.t("自带可用的中文译文，同水平候选间优先")
            case "romanization": return L10n.t("日文歌词自带罗马音，同水平候选间优先")
            case "versionTags": return L10n.t("括号里的 Live / Remix / Demo 等跟本地曲名对不上")
            case "durationOff":
                return L10n.t("最后一句的时间跟曲长差了 25% 以上；仍可选用，但会排在所有时长对得上的后面")
            case "rejectDurationMismatch":
                return L10n.t("最后一句的时间跟曲长差了 25% 以上，多半是另一个版本")
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

        // 给候选选择界面展示的补充特性——是否逐字这一项 collector 已经算好(hasWordTiming),
        // 译文/罗马音/行数纯粹是本地字段是否非空/切行数,不需要 collector 额外计算。
        var hasTranslation: Bool { !lyricsTr.isEmpty }
        var hasRomanization: Bool { !lyricsRoma.isEmpty }
        // CRLF 换行(酷狗候选常见)会让 split(separator:"\n") 按 Character 比较时把整份
        // 文本当一整行切不开——见 YRCParser/LRCParser.parse 同一处注释,这里先归一化成
        // 纯 "\n" 再切,否则这类候选会显示成"1 行"这种明显错误的行数。
        var lineCount: Int {
            lyrics.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    // 2026-08-02 补上——之前 onUpdate 只传候选数组,五个源都没查到候选时,弹窗只能显示
    // 一句笼统的"都没找到",分不清是这首歌真的没有网络歌词,还是网络整体不通导致五个源
    // 的请求全部发不出去。networkLooksDown 由 collector 侧统计"这一轮联网搜索期间发出
    // 的请求有没有全部失败"算出来(见 networkobs.go 的 networkLooksDown()),这里原样
    // 转发给调用方决定展示哪种空状态文案。
    struct SearchUpdate {
        let candidates: [Candidate]
        let networkLooksDown: Bool
        /// 已经回来的歌词源 / 一共要等几个。语义(为什么分母只数开着的源、为什么
        /// applecover 不算)见 collector/enrich.go 的 lyricSearchUpdateFunc 注释。
        let sourcesDone: Int
        let sourcesTotal: Int
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
    func search(
        artist: String, title: String, album: String, durationSecs: Double = 0,
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
                        sourcesTotal: raw.sourcesTotal ?? 0)
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
            readGroup.enter()
            readQueue.async {
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

    enum CodingKeys: String, CodingKey {
        case source, lyrics, score, title, artist, album
        case lyricsTr = "lyrics_tr"
        case lyricsRoma = "lyrics_roma"
        case lyricsYRC = "lyrics_yrc"
        case hasWordTiming = "has_word_timing"
        case scoreTerms = "score_terms"
        case coverURL = "cover_url"
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
            coverURL: raw.coverURL.flatMap(URL.init(string:))
        )
    }
}
