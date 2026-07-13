import Foundation
import os

private let logger = Logger(subsystem: "com.chenyuhao.applemusic-desktop-lyrics", category: "lyrics-search")

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
    }

    enum SearchError: LocalizedError {
        case processFailed(String)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .processFailed(let msg): return "搜索失败: \(msg)"
            case .decodeFailed: return "解析搜索结果失败"
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

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.error("search-lyrics exited \(proc.terminationStatus): \(msg ?? "", privacy: .public)")
                    continuation.resume(throwing: SearchError.processFailed(msg?.isEmpty == false ? msg! : "退出码 \(proc.terminationStatus)"))
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
