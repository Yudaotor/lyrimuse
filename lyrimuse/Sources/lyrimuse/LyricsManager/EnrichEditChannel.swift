import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-manager")

/// 把一次歌词缓存改动交给 collector 执行。
///
/// collector 是 enrich-cache.json 和 lyrics/ 歌词文件唯一的写入方(见 lyrimuse-collector/enrichedit.go):
/// 它把整份缓存握在内存里,每次存盘都整份写回,App 在它背后改文件的话下一次存盘就被盖掉。所以 App 这边
/// 只描述「要做什么」(op + 参数),字段规则、导出文件、删文件都在 collector 里。别在 App 侧再加直接写
/// 缓存或歌词文件的路径。
///
/// 后台服务在跑:请求原子写进 `lyrimuse-enrich-requests/<id>.json`,等 `<id>.result.json`。
/// 没在跑:用同一个 collector 二进制跑 `apply-enrich-edit <请求文件>`,它先拿单实例锁再执行同一段代码。
enum EnrichEditChannel {
    struct Result: Sendable {
        var ok: Bool
        var changed: Int
        var error: String?
    }

    /// 跟 collector main.go 里 setEnrichEditDir 的目录名逐字节一致。
    static let directoryName = "lyrimuse-enrich-requests"
    /// 等 collector 取走请求的上限。collector 那边比 1 分钟还老的请求不再执行(enrichEditStaleAfter),
    /// 这里必须比它短:超时撤回之后,请求不能再被悄悄执行。
    static let resultTimeout: TimeInterval = 20
    /// 请求已被取走(collector 正在执行)时继续等结果的上限。取走了就一定会执行完,这时报失败就是假话,
    /// 所以超过 resultTimeout 也接着等;清空、恢复这类要搬几千个文件的操作会超过 20 秒。
    static let executingTimeout: TimeInterval = 120
    private static let pollInterval: Duration = .milliseconds(100)

    private static let collectorPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/collector").path

    /// 执行一个 op。`fields` 的键名跟 collector 侧 enrichEditRequest 的 json tag 一致。
    static func send(_ op: String, _ fields: [String: Any] = [:]) async -> Result {
        var body = fields
        body["op"] = op
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return Result(ok: false, changed: 0, error: "invalid request")
        }
        let path = collectorPath
        let isRunning = await Task.detached(priority: .userInitiated) { CollectorServiceManager.isRunning }.value
        if isRunning {
            return await viaRequestDirectory(data)
        }
        let cli = await Task.detached(priority: .userInitiated) { viaCLI(data, collectorPath: path) }.value
        // 判断「没在跑」和执行之间后台服务刚好起来了:CLI 拿不到锁,改走请求目录。
        if !cli.ok, cli.error == "collector is running" {
            return await viaRequestDirectory(data)
        }
        return cli
    }

    /// id 以纳秒时间戳开头:collector 按文件名顺序处理,顺序即提交顺序。
    private static func makeID() -> String {
        let nanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        return String(format: "%020llu-%@", nanos, String(UUID().uuidString.prefix(8)))
    }

    /// 等结果用 Task.sleep 而不是 Thread.sleep:一次改动最长要等两分钟,不能一直占着并发池里的线程。
    private static func viaRequestDirectory(_ data: Data) async -> Result {
        let dir = LyrimusePaths.configFile(directoryName)
        let id = makeID()
        let request = dir.appendingPathComponent("\(id).json")
        let result = dir.appendingPathComponent("\(id).result.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 先写临时名(不以 .json 结尾,collector 不认)再改名:collector 不会读到半截请求。
            let tmp = dir.appendingPathComponent(".\(id).tmp")
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.moveItem(at: tmp, to: request)
        } catch {
            logger.error("enrich edit: writing the request failed: \(error.localizedDescription, privacy: .public)")
            return Result(ok: false, changed: 0, error: error.localizedDescription)
        }
        if let answer = await waitForResult(result, timeout: resultTimeout) { return answer }
        // 超时:撤回还没被取走的请求,免得它过后被执行。撤不回说明 collector 已经取走、正在执行,那就等它做完 ——
        // 这时报失败,改动过后照样生效。
        if (try? FileManager.default.removeItem(at: request)) != nil {
            logger.error("enrich edit: collector did not pick up the request within \(Int(resultTimeout), privacy: .public)s")
            return Result(ok: false, changed: 0, error: L10n.t("歌词引擎没有响应"))
        }
        logger.notice("enrich edit: collector is still executing the request, waiting for it")
        if let answer = await waitForResult(result, timeout: executingTimeout) { return answer }
        logger.error("enrich edit: collector did not finish within \(Int(resultTimeout + executingTimeout), privacy: .public)s")
        return Result(ok: false, changed: 0, error: L10n.t("歌词引擎没有响应"))
    }

    private static func waitForResult(_ url: URL, timeout: TimeInterval) async -> Result? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? Data(contentsOf: url) {
                try? FileManager.default.removeItem(at: url)
                return decode(raw)
            }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    private static func viaCLI(_ data: Data, collectorPath: String) -> Result {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lyrimuse-enrich-edit-\(makeID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            return Result(ok: false, changed: 0, error: error.localizedDescription)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: collectorPath)
        process.arguments = ["apply-enrich-edit", tmp.path]
        process.environment = LyrimusePaths.collectorProcessEnvironment()
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("enrich edit: launching collector failed: \(error.localizedDescription, privacy: .public)")
            return Result(ok: false, changed: 0, error: error.localizedDescription)
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 结果是 stdout 最后一行 JSON;前面可能有日志行。
        let lastLine = String(decoding: out, as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? ""
        return decode(Data(lastLine.utf8))
    }

    private static func decode(_ raw: Data) -> Result {
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return Result(ok: false, changed: 0, error: "unreadable result")
        }
        return Result(ok: obj["ok"] as? Bool ?? false,
                      changed: (obj["changed"] as? NSNumber)?.intValue ?? 0,
                      error: obj["error"] as? String)
    }
}
