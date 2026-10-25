import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "backfill")

/// 「待补提交的历史收听」那一行的状态机 —— 驱动引擎的 `backfill-lastfm` 子命令。
/// (之前界面上确实有个标题叫「补提交历史收听」的独立行,已合并掉,见下。)
///
/// ## 界面上只有一行
///
/// Last.fm 卡片里那一行:条数 +(展开后的)清单 + 「补提交」按钮,三者合在一处。只要本地
/// 攒了东西它就出现,**不分连没连账号**;按钮只在连着账号时给(没连提交不到任何地方去),
/// 那时它退化成纯粹的"本地攒了些什么"清单。光说"会记在本地"是空头承诺 —— 列出来用户
/// 才能核对到底记了什么。
///
/// 出现条件别写成「没连账号」:已连接、但 Scrobble 开关关着同样在攒歌(数据层看的是
/// features.LastfmMirrorScrobble,不是连没连)。条数和「补提交」说的是同一个数字,别再拆成两行。
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

        // 手写 init(from) —— **不能**靠上面那些属性默认值:Swift 自动合成的解码器对**非可选**属性一律走
        // decode(_:forKey:),缺 key 直接 throw,**属性默认值不参与解码**。而 Go 那边
        // `Items []backfillItem json:"items,omitempty"` 只在 dry-run 分支填(backfill.go runBackfill),
        // 真跑的输出没有 items 键 → keyNotFound → run() 里那句 try? 吞成 nil → lastRunFailed:补提交其实
        // 成功了,界面却报失败。
        //
        // 所以**所有**字段一律 decodeIfPresent:今天只有 items 带 omitempty,哪天谁给 eligible 加一个也不会炸。
        // 「重新自动匹配」的结论是同一条 Go→Swift 边界上的同一类错配。selftest 里「omitempty 边界」那道守卫
        // 从 Go 的 struct tag 反推这条要求。
        private enum CodingKeys: String, CodingKey {
            case items, eligible, accepted, ignored, skippedTooOld, quarantined, abortedReason
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
            eligible = try c.decodeIfPresent(Int.self, forKey: .eligible) ?? 0
            accepted = try c.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
            ignored = try c.decodeIfPresent(Int.self, forKey: .ignored) ?? 0
            skippedTooOld = try c.decodeIfPresent(Int.self, forKey: .skippedTooOld) ?? 0
            quarantined = try c.decodeIfPresent(Int.self, forKey: .quarantined) ?? 0
            abortedReason = try c.decodeIfPresent(String.self, forKey: .abortedReason)
        }
    }

    /// 空跑得到的待补条数(nil = 还没查过)。
    @Published private(set) var pending: Outcome?
    /// 真跑之后的结果,用来显示"已补 N 条"。
    @Published private(set) var lastRun: Outcome?
    /// 真跑那次**根本没跑成**(子进程起不来/非零退出/输出解不出来)。
    ///
    /// 跟 `lastRun == nil` 分开表示,是因为那个值在"还没跑过"和"跑了但失败了"两种情形下
    /// 都是 nil,而这两种在界面上必须长得不一样:前者什么都不该显示,后者必须说一句 ——
    /// 否则用户点完按钮只看到转圈停下、界面一切如常(现象是「没有反馈」里
    /// 最糟的一种:失败得毫无声息)。
    @Published private(set) var lastRunFailed = false
    @Published private(set) var busy = false
    /// 真补交跑着时处理到第几首(子命令写的进度文件,见 `progressURL`);没在补交、或子命令还没写出第一份时是 nil。
    @Published private(set) var progress: Progress?

    struct Progress: Decodable, Equatable {
        var total: Int
        var done: Int
    }

    /// 子命令 `backfill-lastfm` 写进度的文件(lyrimuse-engine/backfillcli.go 的 backfillProgressPath,两边必须一致),
    /// 跑完它自己删掉。
    static let progressURL = LyrimusePaths.configFile("lyrimuse-backfill-progress.json")

    private init() {}

    private static var enginePath: String {
        // 用包里那份引擎(LyrimusePaths.bundledEnginePath),每次 build.sh 重新打包都会跟着更新。
        LyrimusePaths.bundledEnginePath
    }

    /// 引擎那份本地收听日志被写过的时刻。nil = 文件还不存在(从来没攒过)。
    ///
    /// 给界面当**廉价的变更信号**用:待补数只能靠 dry-run 算出来,而那要 spawn 一个子进程,
    /// 按秒轮询它是不像话的;stat 一个文件几乎免费,所以页面开着时盯 mtime,只在真的又攒进
    /// 一首那一刻才重跑 dry-run。路径跟引擎那边 initListenLog 传进去的一致
    /// (main.go:178,配置目录 + clientName + "-listens.jsonl")。
    static func listenLogModifiedAt() -> Date? {
        let url = LyrimusePaths.configFile("lyrimuse-listens.jsonl")
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
        // 上一次的结果先清掉:跑的过程中还挂着"已补 3 条"会让人以为那是这一次的结果。
        lastRun = nil
        lastRunFailed = false
        // 上一趟被杀掉时留下的进度文件不能当成这一趟的。
        _ = FileIO.remove(Self.progressURL)
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let p = FileIO.decodeJSON(Progress.self, from: Self.progressURL), p.total > 0 {
                    self?.progress = p
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        Task { @MainActor in
            let out = await Self.run(dryRun: false)
            poll.cancel()
            progress = nil
            lastRun = out
            lastRunFailed = (out == nil)
            pending = await Self.run(dryRun: true)
            busy = false
            logger.notice("""
                backfill finished: accepted=\(out?.accepted ?? -1, privacy: .public) \
                ignored=\(out?.ignored ?? -1, privacy: .public) \
                quarantined=\(out?.quarantined ?? -1, privacy: .public)
                """)
            // 真的有条目补进了 Last.fm → 统计页手里的缓存全过时了(现象是
            // "补提交后最近记录没刷新"):最近记录/今天/近7天立刻强刷,不等 2 分钟 TTL
            // 或下次换歌。补进过去那些天的条数由热力图增量同步收进来(每次重扫最近 14 天,
            // 盖住回填窗口)。accepted == 0(全被忽略/隔离)时 Last.fm 侧什么都没变,不白发请求。
            if let out, out.accepted > 0 {
                // 补进去的是过去的时间戳,插在最近记录中间:深页缓存的绝对位置全推错了(见 LastfmPageComposer.lateInsertDetected)。
                LastfmStatsService.shared.dropDeepRecentPageCache(reason: "backfill accepted \(out.accepted)")
                LastfmStatsService.shared.refreshBaseline(force: true)
                // Last.fm 把刚收到的 scrobble 并进 recenttracks 要一两秒,紧接着上面那一发强刷多半还看不到刚补的记录;
                // 最近记录的主来源是引擎落盘的 feed。主路径在引擎那边:回填子命令 touch 一个信号文件(lastfmFeedNudgePath),
                // 常驻进程消费掉它并排一个 backfillFeedNudgeDelay(5 s)之后的拉取(必须带这个延迟,当场拉回来的是旧内容),
                // App 靠 5 s 一次的 mtime 轮询几秒内拿到。
                //
                // 下面这发延迟强刷只兜引擎不在的情况,别把它当成主路径:feedIsFresh 看的是 feed 的 fetchedAt 在不在 freshWindow
                // 窗口内,而引擎只要活着就每 feedHeartbeat(60 s)重写一次 feed,跟有没有包含刚补的那几条无关,所以引擎在跑时
                // 这一发不会触发。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if !LastfmStatsService.shared.feedIsFresh {
                        LastfmStatsService.shared.refreshBaseline(force: true)
                    }
                }
            }
        }
    }

    /// 用户读完那句结果、把它关掉。下次点「补提交」也会自己清(见 runBackfill)。
    func dismissLastRun() {
        lastRun = nil
        lastRunFailed = false
    }

    /// 从本地收听日志里删掉一条(按 uts)。删完顺手刷新清单。
    ///
    /// 走引擎的 `delete-listen` 子命令,不在这边直接改那个 jsonl:那份文件是
    /// 引擎的,它一边还在往里追加(每首播完写一行),格式和折叠语义也都在那边。
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
        let path = enginePath
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            // 用 ProcessRunner:带超时,而且 stdout 会被先读空再等退出(见它的注释)。
            //
            // **environment 必须显式传**:delete-listen 要跟 App 读的是同一份收听日志,不传就按引擎自己的
            // 默认规则找配置目录(见 LyrimusePaths.engineEnvironment)。删错了目录的表现是 deleted:0 →
            // ok=false → 列表原样重拉一遍,界面上就是"点了没反应"。
            guard let r = ProcessRunner.run(
                path, ["delete-listen", "-uts", String(uts)], timeout: 15,
                environment: LyrimusePaths.engineProcessEnvironment()), r.succeeded
            else { return false }
            struct Result: Decodable { let deleted: Int }
            return (try? JSONDecoder().decode(Result.self, from: r.stdout))?.deleted ?? 0 > 0
        }.value
    }

    private static func run(dryRun: Bool) async -> Outcome? {
        let path = enginePath
        return await Task.detached(priority: .userInitiated) { () -> Outcome? in
            // 走 ProcessRunner 并接 stderr:它把两根管子并发读空。原来先读空 stdout、等退出之后才读 stderr,
            // 子命令往 stderr 写满管道缓冲(64KB,每条被忽略的记录一行日志就能写满)时会阻塞在 write 上不退出,
            // 父进程等它退出 —— 互相等死,直到看门狗杀掉它,而那时 scrobble 已经发出去了、界面却报失败。
            //
            // 超时:真跑一批 50 条、批间还要歇 2 秒,几百条可能跑上几分钟,所以给得比别处宽得多(子命令自己也有
            // -timeout 兜着);空跑纯本地读文件,20 秒够了。超时**只杀进程、不重试**:那一刻可能有一批已经发出去,
            // 重跑就是重复提交;子命令那边会把没拿到回执的批次写进隔离,不会自动重来。
            let timeout: TimeInterval = dryRun ? 20 : 15 * 60
            guard let result = ProcessRunner.run(
                path, dryRun ? ["backfill-lastfm", "-dry-run"] : ["backfill-lastfm"], timeout: timeout,
                // 子命令必须跟本 App 同一份配置目录 / 日志文件,见 LyrimusePaths.engineEnvironment。
                environment: LyrimusePaths.engineProcessEnvironment(), captureStderr: true)
            else {
                logger.error("backfill spawn failed: \(path, privacy: .public)")
                return nil
            }
            guard result.succeeded else {
                logger.error("backfill exited \(result.status, privacy: .public) timedOut=\(result.timedOut, privacy: .public): \(result.stderrText, privacy: .public)")
                return nil
            }
            do {
                return try JSONDecoder().decode(Outcome.self, from: result.stdout)
            } catch {
                // 不写成 try?:解码失败在此之前是**完全无声**的 —— 子进程 exit 0,上面两条
                // error 日志一条都不会出现,界面只报一句「没能完成」,查起来要把"哪三条路径
                // 会返回 nil"一条条排除掉才能落到这里。留一行痕,下次十秒钟定位。
                logger.error("backfill decode failed dryRun=\(dryRun, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }
}
