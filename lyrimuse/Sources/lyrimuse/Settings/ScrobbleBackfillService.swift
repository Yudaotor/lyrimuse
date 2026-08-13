import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "backfill")

/// 「补提交历史收听」这张卡的状态机 —— 驱动 collector 的 `backfill-lastfm` 子命令。
///
/// ## 界面上有两种形态
///
/// - **没连账号时**:Last.fm 卡片里列出本地已经记下来的歌(折叠,展开才是清单)。光说
///   "会记在本地"是空头承诺 —— 列出来用户才能核对到底记了什么。
/// - **已连账号时**:只有真有待补内容时才露出"补提交"那一行;没有就完全不显示。这是个
///   一辈子可能只点一次的操作,常驻一行"没有待补的收听"纯属占地方。
///
/// 两种形态都坚持**必须人工点一下**、不做连接成功自动弹窗:回填往用户的 Last.fm 账号写
/// 数据,而 scrobble 落进去之后基本删不掉(只能在网页上一条条手删)。自动弹窗容易被顺手
/// 点掉,而顺手的代价是永久污染自己的听歌历史。
///
/// ## 两次调用,一次是空跑
///
/// 数量来自 `-dry-run`(一个请求都不发),按钮才真提交。这样"有多少条可补"这个信息是免费的,
/// 可以随时刷新;真正有副作用的那一步永远只在点击之后发生。
@MainActor
final class ScrobbleBackfillService: ObservableObject {
    static let shared = ScrobbleBackfillService()

    /// 待补清单里的一条。只有 dry-run 的返回值会带 items —— 真跑那次只需要计数。
    struct Item: Codable, Equatable, Identifiable {
        var uts: Int64
        var artist: String
        var title: String
        var album: String?
        var dur: Double?
        var id: Int64 { uts }
    }

    struct Outcome: Codable, Equatable {
        var items: [Item] = []
        var eligible = 0
        var accepted = 0
        var ignored = 0
        var skippedTooOld = 0
        var quarantined = 0
        var abortedReason: String?
    }

    /// 空跑得到的待补条数(nil = 还没查过)。
    @Published private(set) var pending: Outcome?
    /// 真跑之后的结果,用来显示"已补 N 条"。
    @Published private(set) var lastRun: Outcome?
    @Published private(set) var busy = false

    private init() {}

    private static var collectorPath: String {
        // 跟 LyricsSearchService/LastfmStatsService 同一个取法:从 Bundle 现拼,
        // 每次 build.sh 重新打包都会跟着更新。
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/collector").path
    }

    /// 刷新"有多少条可补"。空跑,不发任何网络请求,可以随便调。
    func refreshPending() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let out = await Self.run(dryRun: true)
            pending = out
            busy = false
        }
    }

    /// 真正提交。完成后顺手刷新一次待补数 —— 成功的那些已经写了回执,数字应该掉下来。
    func runBackfill() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let out = await Self.run(dryRun: false)
            lastRun = out
            pending = await Self.run(dryRun: true)
            busy = false
            logger.notice("""
                backfill finished: accepted=\(out?.accepted ?? -1, privacy: .public) \
                ignored=\(out?.ignored ?? -1, privacy: .public) \
                quarantined=\(out?.quarantined ?? -1, privacy: .public)
                """)
        }
    }

    private static func run(dryRun: Bool) async -> Outcome? {
        let path = collectorPath
        return await Task.detached(priority: .userInitiated) { () -> Outcome? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = dryRun ? ["backfill-lastfm", "-dry-run"] : ["backfill-lastfm"]
            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe
            do {
                try process.run()
                // 看门狗:真跑一批 50 条、批间还要歇 2 秒,几百条可能跑上几分钟,所以给得
                // 比别处宽得多(子命令自己也有 -timeout 兜着)。空跑纯本地读文件,给 20 秒够了。
                //
                // ⚠️ 超时**只杀进程、不重试**:那一刻可能有一批已经发出去了,重跑就是
                // 重复提交。子命令那边会把没拿到回执的批次写进隔离,不会自动重来。
                let deadline: UInt64 = dryRun ? 20 : 15 * 60
                let watchdog = Task.detached {
                    try? await Task.sleep(nanoseconds: deadline * 1_000_000_000)
                    if !Task.isCancelled, process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                guard process.terminationStatus == 0 else {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    logger.error("backfill exited \(process.terminationStatus, privacy: .public): \(err, privacy: .public)")
                    return nil
                }
                return try? JSONDecoder().decode(Outcome.self, from: data)
            } catch {
                logger.error("backfill spawn failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }
}
