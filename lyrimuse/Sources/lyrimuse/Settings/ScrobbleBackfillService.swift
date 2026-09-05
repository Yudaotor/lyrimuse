import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "backfill")

/// 「待补提交的历史收听」那一行的状态机 —— 驱动 collector 的 `backfill-lastfm` 子命令。
/// (2026-08-18 之前界面上确实有个标题叫「补提交历史收听」的独立行,已合并掉,见下。)
///
/// ## 界面上只有一行
///
/// Last.fm 卡片里那一行:条数 +(展开后的)清单 + 「补提交」按钮,三者合在一处。只要本地
/// 攒了东西它就出现,**不分连没连账号**;按钮只在连着账号时给(没连提交不到任何地方去),
/// 那时它退化成纯粹的"本地攒了些什么"清单。光说"会记在本地"是空头承诺 —— 列出来用户
/// 才能核对到底记了什么。
///
/// 两次演化都记一下,免得被拆回去:2026-08-18 之前清单的出现条件写的是"没连账号",漏掉了
/// "已连接、但 Scrobble 开关关着"这条同样在攒歌的路径(数据层看的是
/// features.LastfmMirrorScrobble,不是连没连);放宽之后它一度跟「补提交历史收听」并列成
/// 两行、说的是同一个数字,当天合并成一行。
///
/// 坚持**必须人工点一下**、不做连接成功自动弹窗:回填往用户的 Last.fm 账号写数据,而
/// scrobble 落进去之后基本删不掉(只能在网页上一条条手删)。自动弹窗容易被顺手点掉,
/// 而顺手的代价是永久污染自己的听歌历史。
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

    /// collector 那份本地收听日志被写过的时刻。nil = 文件还不存在(从来没攒过)。
    ///
    /// 给界面当**廉价的变更信号**用:待补数只能靠 dry-run 算出来,而那要 spawn 一个子进程,
    /// 按秒轮询它是不像话的;stat 一个文件几乎免费,所以页面开着时盯 mtime,只在真的又攒进
    /// 一首那一刻才重跑 dry-run。路径跟 collector 那边 initListenLog 传进去的一致
    /// (main.go:178,配置目录 + clientName + "-listens.jsonl")。
    static func listenLogModifiedAt() -> Date? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lyrimuse/lyrimuse-listens.jsonl")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
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
            // 真的有条目补进了 Last.fm → 统计页手里的缓存全过时了(2026-08-18 用户报
            // "补提交后最近记录没刷新"):最近记录/今天/近7天立刻强刷,不等 2 分钟 TTL
            // 或下次换歌;热力图的增量水位拨回回填窗口起点,不拨的话补进历史那些天会被
            // 增量同步永远漏掉(见 rewindDailySyncForBackfill 注释)。accepted == 0
            // (全被忽略/隔离)时 Last.fm 侧什么都没变,不白发请求。
            if let out, out.accepted > 0 {
                LastfmStatsService.shared.refreshBaseline(force: true)
                LastfmStatsService.shared.rewindDailySyncForBackfill()
                // 2026-09-03 补。Last.fm 把刚收到的 scrobble 并进 recenttracks 要一两秒,紧接着上面
                // 那一发强刷多半还看不到刚补的记录;而 feed 时代最近记录的主来源是 collector 落盘的
                // feed(每 15 s/60 s 一拉),那次强刷之后就没有别的"马上"了 —— 用户报「刚连上补提交
                // 之后最近记录没有马上刷新」。collector 侧现在由回填子命令 touch 一个信号文件
                // (lastfmFeedNudgePath),常驻进程下一拍(≤5 s)就重拉 feed,App 靠 5 s 一次的 mtime
                // 轮询几秒内拿到;这里再补一发**延迟**强刷兜底,只在 feed 不新鲜(collector 不在、或
                // 还没写过)时发 —— feed 活着的话新内容会自己到,不重复打 3 个请求。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if !LastfmStatsService.shared.feedIsFresh {
                        LastfmStatsService.shared.refreshBaseline(force: true)
                    }
                }
            }
        }
    }

    /// 从本地收听日志里删掉一条(按 uts)。删完顺手刷新清单。
    ///
    /// 走 collector 的 `delete-listen` 子命令,不在这边直接改那个 jsonl:那份文件是
    /// collector 的,它一边还在往里追加(每首播完写一行),格式和折叠语义也都在那边。
    /// 让 App 去读-改-写一个正在被追加的文件是在自找竞态。
    func deleteListen(uts: Int64) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let ok = await Self.runDelete(uts: uts)
            // 不管成没成都重新拉一次清单 —— 界面显示的必须是磁盘上的真实状态,
            // 而不是我们以为删掉之后的样子。
            pending = await Self.run(dryRun: true)
            busy = false
            logger.notice("delete listen uts=\(uts, privacy: .public) ok=\(ok, privacy: .public)")
        }
    }

    private static func runDelete(uts: Int64) async -> Bool {
        let path = collectorPath
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            // 用 ProcessRunner:带超时,而且 stdout 会被先读空再等退出(见它的注释)。
            guard let r = ProcessRunner.run(
                path, ["delete-listen", "-uts", String(uts)], timeout: 15), r.succeeded
            else { return false }
            struct Result: Decodable { let deleted: Int }
            return (try? JSONDecoder().decode(Result.self, from: r.stdout))?.deleted ?? 0 > 0
        }.value
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
