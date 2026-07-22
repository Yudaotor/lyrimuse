import Foundation
import os

private let logger = Logger(subsystem: "com.chenyuhao.lyrimuse", category: "lyrics-search")

// "联网搜索候选歌词"——参考 LyricsX 的 SearchLyricsViewController,但不在 Swift 这边
// 重新实现网易云/QQ/酷狗/LRCLIB 的检索逻辑(那会是第二份、迟早会跟 Go collector 那份
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
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .processFailed(let msg): return String(format: L10n.t("搜索失败: %@"), msg)
            case .decodeFailed: return L10n.t("解析搜索结果失败")
            }
        }
    }

    // 跟 LoginItemManager/EnrichCacheStore 同一个约定:硬编码 build.sh 真正安装的路径,
    // 不用当前调试进程的路径。
    private static let collectorPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("applemusic-nowplaying/bin/collector").path

    private init() {}

    // durationSecs 传 0 表示"没有可靠的真实时长"——歌词管理窗口浏览的是任意历史缓存
    // 条目,enrichEntry 本来就不持久化时长;collector 侧 scoreLyricCandidate 对
    // durationSecs<=0 有专门处理,直接跳过时长匹配这档评分(不会除零/不会被误判成
    // "时长对不上"),只退化成语言/署名行过滤+逐字加分+来源优先级+行数。
    func search(artist: String, title: String, album: String, durationSecs: Double = 0) async throws -> [Candidate] {
        try await withCheckedThrowingContinuation { continuation in
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
            // write() 就会阻塞、等父进程腾出空间;如果父进程只在 terminationHandler 里才
            // readDataToEndOfFile(),子进程卡在 write() 上永远不会退出、
            // terminationHandler 也就永远不会触发,两边互相等对方先动导致死锁。这里在
            // 子进程运行期间就在后台队列持续把 stdout/stderr 读走(不等进程退出),管道
            // 缓冲区就不会被灌满。DispatchGroup.wait() 确保下面两条后台读取线程写完
            // box.value 之后、terminationHandler 才会往下读它们——这个 happens-before
            // 关系是靠 group 保证的,不是靠 Swift 并发检查器认识的机制,所以用
            // @unchecked Sendable 包一层声明这里的跨线程访问已经自行保证过安全,避免
            // Swift 6 严格并发模式下把这种直接捕获 var 的写法当成数据竞争报错。
            final class Box: @unchecked Sendable { var value = Data() }
            let outBox = Box()
            let errBox = Box()
            let pipeReadGroup = DispatchGroup()
            pipeReadGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                outBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                pipeReadGroup.leave()
            }
            pipeReadGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                errBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                pipeReadGroup.leave()
            }

            process.terminationHandler = { proc in
                // 进程已退出,两条后台读取线程读到 EOF 会自然返回;等它们真正写完
                // outBox/errBox 再继续,避免极端情况下读线程还没来得及把最后一批数据
                // 落进变量就被下面读到半份数据。
                pipeReadGroup.wait()
                let outData = outBox.value
                let errData = errBox.value
                guard proc.terminationStatus == 0 else {
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.error("search-lyrics exited \(proc.terminationStatus): \(msg ?? "", privacy: .public)")
                    continuation.resume(throwing: SearchError.processFailed(msg?.isEmpty == false ? msg! : String(format: L10n.t("退出码 %@"), "\(proc.terminationStatus)")))
                    return
                }
                guard let raw = try? JSONDecoder().decode([RawCandidate].self, from: outData) else {
                    logger.error("search-lyrics: failed to decode stdout")
                    continuation.resume(throwing: SearchError.decodeFailed)
                    return
                }
                continuation.resume(returning: raw.map(Candidate.init))
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

    enum CodingKeys: String, CodingKey {
        case source, lyrics, score
        case lyricsTr = "lyrics_tr"
        case lyricsRoma = "lyrics_roma"
        case lyricsYRC = "lyrics_yrc"
        case hasWordTiming = "has_word_timing"
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
            score: raw.score
        )
    }
}
