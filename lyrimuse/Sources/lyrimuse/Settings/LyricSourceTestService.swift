import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-source-test")

// "歌词来源可用性测试"(2026-08-30,设置页「歌词来源」卡片的每行测试按钮 + 右上角
// 「全部测试」用)。子进程调用 collector 侧新增的 `test-lyric-sources`
// (lyrimuse-collector/testlyricsourcescli.go)——跟诊断导出用的 `healthcheck` 同一套
// 探测思路(两首固定探测曲,一首华语一首英文,取并集,理由见该文件顶部注释),但输出
// 形状不一样:healthcheck 是"一次性整份报告"(给诊断导出的文本转储用),这里要的是
// "一个源一行、边测边出结果"的 NDJSON,好让设置页每一行独立从"测试中"变成"可用/疑似
// 不可用",不用等最慢的那个源测完才有任何反应。
//
// 子进程/NDJSON 读取的写法跟 LyricsSearchService(LyricsManager/ 目录,"联网搜索候选
// 歌词"用的那个)完全同一个idiom(availableData 循环 + 独立队列读 stderr 防 64KB 管道
// 死锁,虽然这里单行输出很小、实际不太可能撞上这个坑,但同一件事没有理由写两份不同的
// 实现),故意没有抽成公用基类——两处一份改了大概率也不会同步改另一份,保持各自独立、
// 各自完整可读,比省这几十行复制代码更重要。
final class LyricSourceTestService {
    static let shared = LyricSourceTestService()

    /// 上一次还在跑的测试子进程。跟 LyricsSearchService 同一个理由:新一轮开始前杀掉
    /// 旧的,不然旧一轮会继续跑满、白占网络请求,而结果反正没人要。
    private let processLock = NSLock()
    private var runningProcess: Process?

    func cancelRunning() {
        processLock.lock()
        let process = runningProcess
        runningProcess = nil
        processLock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    /// 跟 collector 侧 healthStatus 三档一一对应,语义见 testlyricsourcescli.go 的
    /// lyricSourceTestResult.Status 注释。
    enum Status: String, Decodable {
        case ok, warn, fail
    }

    struct Result {
        let source: String
        let status: Status
        let detail: String
        let networkLooksDown: Bool
    }

    enum TestError: LocalizedError {
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .processFailed(let msg): return String(format: L10n.t("测试失败: %@"), msg)
            }
        }
    }

    private static let collectorPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/collector").path

    private init() {}

    /// - source: nil = 测试所有已启用的源;非 nil = 只测这一个源。⚠️ 即便只测一个源,
    ///   底层探测仍然会把全部已启用的源一起并发打一遍(collector 侧 scoredLyricCandidates
    ///   本来就是这么设计的——AMLL 需要先从网易云/QQ 拿到平台 ID,拆开单独测反而更复杂),
    ///   所以"测一个"和"测全部"的实际等待时间没有区别,只是显示上只关心那一行——跟这个
    ///   仓库里"联网搜索候选歌词"弹窗同样是等最慢的那个源,不是这次改动新引入的体验取舍。
    /// onUpdate 每收到一行 stdout 就调用一次,回调固定在 MainActor 上执行,调用方可以
    /// 直接改 @State。
    func test(
        source: LyricsSource? = nil,
        onUpdate: @escaping @MainActor (Result) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await performTest(source: source, onUpdate: onUpdate)
        } onCancel: {
            cancelRunning()
        }
    }

    private func performTest(
        source: LyricsSource?,
        onUpdate: @escaping @MainActor (Result) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.collectorPath)
            var arguments = ["test-lyric-sources"]
            if let source {
                arguments.append(contentsOf: ["-source", source.rawValue])
            }
            process.arguments = arguments

            self.cancelRunning()
            self.processLock.lock()
            self.runningProcess = process
            self.processLock.unlock()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // 同 LyricsSearchService.performSearch 那段注释:边读边处理,不等进程退出才读,
            // 避免内核管道 64KB 缓冲区被灌满导致子进程 write() 阻塞、两边互相等对方先动。
            final class Box: @unchecked Sendable {
                var outBuffer = Data()
                var errBuffer = Data()
            }
            let box = Box()
            let readQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.test-lyric-sources.stdout", qos: .utility)
            let readGroup = DispatchGroup()

            func drainCompleteLines() {
                while let newlineRange = box.outBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = box.outBuffer.subdata(in: box.outBuffer.startIndex..<newlineRange.lowerBound)
                    box.outBuffer.removeSubrange(box.outBuffer.startIndex..<newlineRange.upperBound)
                    guard !lineData.isEmpty else { continue }
                    guard let raw = try? JSONDecoder().decode(RawTestResult.self, from: lineData) else {
                        logger.error("test-lyric-sources: failed to decode a stdout line, skipping")
                        continue
                    }
                    let result = Result(
                        source: raw.source, status: raw.status, detail: raw.detail,
                        networkLooksDown: raw.networkLooksDown)
                    Task { @MainActor in onUpdate(result) }
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
            // stderr 在独立队列读(同 LyricsSearchService 的理由——两条管道要并行排空,
            // 不能让 stdout 的 EOF 循环挡在前面)。这里的 stderr 是 collector 的网络审计
            // 日志(每次 HTTP 调用一行),量不小,更不能省这一层。
            let stderrQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.test-lyric-sources.stderr", qos: .utility)
            readGroup.enter()
            stderrQueue.async {
                box.errBuffer = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }

            process.terminationHandler = { proc in
                readGroup.wait()
                guard proc.terminationStatus == 0 else {
                    let msg = String(data: box.errBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.error("test-lyric-sources exited \(proc.terminationStatus): \(msg ?? "", privacy: .public)")
                    continuation.resume(throwing: TestError.processFailed(msg?.isEmpty == false ? msg! : String(format: L10n.t("退出码 %@"), "\(proc.terminationStatus)")))
                    return
                }
                continuation.resume(returning: ())
            }

            do {
                try process.run()
            } catch {
                // 同 LyricsSearchService.performSearch 那段注释:process.run() 失败时,
                // 上面已经派发到 readQueue/stderrQueue 的读取闭包会永久阻塞在等第一批
                // 数据/EOF 上(管道写端从没被任何人打开过也没被关闭过)——显式关闭两个
                // 管道的写端,让阻塞中的读取立刻观察到 EOF、正常退出循环。
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: TestError.processFailed(error.localizedDescription))
            }
        }
    }
}

// 对应 collector 侧 testlyricsourcescli.go 的 lyricSourceTestResult——字段名两边都是
// lowerCamelCase,不需要额外 CodingKeys。
private struct RawTestResult: Decodable {
    let source: String
    let status: LyricSourceTestService.Status
    let detail: String
    let networkLooksDown: Bool
}
