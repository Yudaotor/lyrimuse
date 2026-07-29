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

    struct Candidate: Identifiable, Equatable {
        var id: String { source }
        let source: String
        let lyrics: String
        let lyricsTr: String
        let lyricsRoma: String
        let lyricsYRC: String
        let hasWordTiming: Bool
        let score: Int
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
        onUpdate: @escaping @MainActor ([Candidate]) -> Void
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

            // 按 \n 切行,每凑齐一整行就尝试解码成 [RawCandidate] 并回调——半行(还没读到
            // 换行符的尾巴)留在 outBuffer 里等下一批数据补全,不会被当成一行提前误判。
            func drainCompleteLines() {
                while let newlineRange = box.outBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = box.outBuffer.subdata(in: box.outBuffer.startIndex..<newlineRange.lowerBound)
                    box.outBuffer.removeSubrange(box.outBuffer.startIndex..<newlineRange.upperBound)
                    guard !lineData.isEmpty else { continue }
                    guard let raw = try? JSONDecoder().decode([RawCandidate].self, from: lineData) else {
                        logger.error("search-lyrics: failed to decode a stdout line, skipping")
                        continue
                    }
                    let candidates = raw.map(Candidate.init)
                    Task { @MainActor in onUpdate(candidates) }
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
                continuation.resume(throwing: SearchError.processFailed(error.localizedDescription))
            }
        }
    }
}

private struct RawCandidate: Decodable {
    let source: String
    let lyrics: String
    let lyricsTr: String?
    let lyricsRoma: String?
    let lyricsYRC: String?
    let hasWordTiming: Bool
    let score: Int
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
            title: raw.title ?? "",
            artist: raw.artist ?? "",
            album: raw.album ?? "",
            coverURL: raw.coverURL.flatMap(URL.init(string:))
        )
    }
}
