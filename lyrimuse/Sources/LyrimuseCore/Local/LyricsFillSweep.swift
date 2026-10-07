import Foundation

/// App 与引擎的「补空扫描」通道(见 lyrimuse-engine/lyricsfillsweep.go 头注)。
///
/// 背景:引擎给空歌词条目再搜一轮的补空路径,设计上只在这首歌**再次被播放**时触发;
/// 「歌词管理」里躺着的存量空条目用户不重播就永远不会动。这条通道让用户在窗口里主动要一轮:
///   - 请求:往 `lyrimuse-lyrics-fill-request.txt` 写一份纯文本(一行 `all` / 一行 `full` /
///     一行 `cancel` / 每行一个缓存 key),引擎 2 秒内读到就消费掉(删文件)并开一轮——
///     形制同「停止搜索」那份 `lyrimuse-enrich-cancel-request.txt`
///     (LyricsManagerView.cancelPlaceholderSearch)。`full` 是「重新匹配整个歌词库」,范围比 `all`
///     大得多,见 `LyricsFullScan` 与引擎的 lyricsfullscan.go。
///   - 进度:引擎把这一轮的进度写到 `lyrimuse-lyrics-fill-status.json`,这里按 mtime 读
///     (同 EngineStatus)。文件不存在 = 这个进程还没跑过任何一轮。
///
/// 引擎没在跑时请求文件会一直留着,下次它起来先清掉(setLyricsFillPaths)——不会把
/// 上一次进程的请求当成新请求执行。
public enum LyricsFillSweep {
    public struct Info: Decodable, Equatable, Sendable {
        public let running: Bool
        public let manual: Bool
        /// 这一轮是「重新匹配整个歌词库」而不是补空。
        ///
        /// 可选而不是 `Bool`:引擎那边带 `omitempty`,补空那一轮压根不会写这个键 ——
        /// 声明成非可选会让**所有**补空进度解码失败(整个进度条哑掉),而不是读成 false。
        public let full: Bool?
        /// 全量扫库时是**整场**的分母/分子/已更新数(跨进程重启、跨"停一下再点"累计,
        /// 见引擎的 lyricsFullScanProgressBase);补空那一轮就是这一轮自己的数。
        public let total: Int
        public let done: Int
        public let filled: Int
        /// 这一轮(这次开工)跑完了多少条。
        ///
        /// 算速度只能用它,不能用 `done`:全量的 `done` 是累计值,而 `startedAt` 是**这一轮**
        /// 开工的时刻,两者相除会得出"一开工就跑完了三千首"这种荒唐速度,「大约还要」当场变成
        /// 「就快好了」。字段缺席(补空那一轮、以及旧版引擎)时退回 `done`,那时两者相等。
        public let roundDone: Int?
        public let current: String?
        public let startedAt: Int64
        public let updatedAt: Int64
        public let finishedAt: Int64?
        public let cancelled: Bool?
        /// 跑着时 = 上一首一个歌词源都没连上、引擎正在等网络回来再搜它;停下时 = 因为一直连不上
        /// 而停下(见引擎的 runLyricsFillSweepKeys)。可选:引擎带 `omitempty`,旧版也不写。
        public let offline: Bool?
        /// `done` 里轮到时已经不需要搜(被删 / 被手改 / 已有词)、没发请求的条数。可选:引擎带 `omitempty`,旧版也不写。
        public let skipped: Int?
        /// 全量扫库里「当前歌词的来源那一轮没应答、没法判断」、等整份候选跑完后再试一次的条数
        /// (见引擎的 runLyricsFullScanDeferredKeys)。可选:引擎带 `omitempty`,旧版也不写。
        public let deferred: Int?
        /// 最近跑完的几条,新的在前(引擎最多留 3 条)。可选,理由同上。
        public let recent: [Recent]?

        /// 最近跑完的一条:缓存 key 与结果。
        public struct Recent: Decodable, Equatable, Sendable {
            public let key: String
            /// filled / missed / skipped / deferred(只有全量扫库会出现);认不出的按 missed 显示。
            public let result: String

            public init(key: String, result: String) {
                self.key = key
                self.result = result
            }
        }

        /// 见 `skipped`。字段缺席读成 0。
        public var skippedCount: Int { skipped ?? 0 }

        /// 见 `deferred`。字段缺席读成 0。
        public var deferredCount: Int { deferred ?? 0 }

        /// 搜了、没找到的条数。
        public var missedCount: Int { max(done - filled - skippedCount, 0) }

        /// 这一轮是不是全量扫库。字段缺席(补空那一轮)读成 false。
        public var isFullScan: Bool { full == true }

        /// 见 `offline`。字段缺席读成 false。
        public var isOffline: Bool { offline == true }

        /// 这一轮跑完的条数,拿不到就退回 `done`(补空那一轮两者本来就相等)。
        public var roundDoneOrDone: Int { roundDone ?? done }

        public init(running: Bool, manual: Bool, full: Bool? = nil, total: Int, done: Int, filled: Int,
                    roundDone: Int? = nil,
                    current: String?, startedAt: Int64, updatedAt: Int64, finishedAt: Int64?,
                    cancelled: Bool?, offline: Bool? = nil, skipped: Int? = nil, deferred: Int? = nil,
                    recent: [Recent]? = nil) {
            self.running = running
            self.manual = manual
            self.full = full
            self.total = total
            self.done = done
            self.filled = filled
            self.roundDone = roundDone
            self.current = current
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.finishedAt = finishedAt
            self.cancelled = cancelled
            self.offline = offline
            self.skipped = skipped
            self.deferred = deferred
            self.recent = recent
        }
    }

    /// 一轮扫描收尾时弹哪一种系统通知(App 侧 `LyricsSweepNotifier` 按它投递)。
    public enum FinishNotice: Equatable, Sendable {
        /// 手动补搜跑完:搜了几首、补全 / 没找到 / 跳过各几首。
        case fillDone(done: Int, filled: Int, missed: Int, skipped: Int)
        /// 手动补搜因为一直连不上歌词源而停下(补搜不自动续跑,要用户再点一次)。
        case fillOffline(done: Int, filled: Int)
        /// 全量重新扫库整场跑完:`done` / `filled` 是整场累计的数。
        case fullDone(done: Int, filled: Int)
        /// 全量重新扫库因为断网暂停;引擎过一会儿会自己接着跑。
        case fullOffline
    }

    /// 这份进度该不该弹收尾通知、弹哪一种。纯函数,selftest 覆盖。
    ///
    /// - `startedSince`:通知器开始盯的时刻(unix 秒)。在那之前开工、也没被看见在跑的一轮不算 ——
    ///   App 启动时读到的是上一轮的收据,不是刚刚结束的事。
    /// - `sawRunning`:这一轮(按 `startedAt` 认)被看见过在跑。App 在一轮中途重启时靠它补上。
    ///
    /// 不弹的:还在跑的;被停下的(用户自己按的「停止」,或进程重启打断 —— 全量扫库会自己接着跑);
    /// 每天自动跑的那一轮补空(`manual == false`,没人在等它,天天弹就是打扰)。
    public static func finishNotice(_ info: Info, startedSince: Int64, sawRunning: Bool) -> FinishNotice? {
        guard !info.running, info.finishedAt != nil, info.cancelled != true else { return nil }
        guard sawRunning || info.startedAt >= startedSince else { return nil }
        if info.isFullScan {
            return info.isOffline ? .fullOffline : .fullDone(done: info.done, filled: info.filled)
        }
        guard info.manual else { return nil }
        if info.isOffline { return .fillOffline(done: info.done, filled: info.filled) }
        return .fillDone(done: info.done, filled: info.filled, missed: info.missedCount, skipped: info.skippedCount)
    }

    /// 缓存 key(`歌手|歌名|专辑`)在进度里的显示:「歌名 — 歌手」;歌手空就只写歌名,拆不开原样返回。纯函数,selftest 覆盖。
    public static func displayName(key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[1].isEmpty else { return key }
        return parts[0].isEmpty ? parts[1] : "\(parts[1]) — \(parts[0])"
    }

    /// 这一轮大约还要多少秒:按这一轮已经跑出来的速度(`roundDoneOrDone` / 已用时间)外推剩下的 `total - done`,
    /// 还没跑完一首时按 `fallbackSecondsPerTrack` 估。纯函数,selftest 覆盖。
    public static func remainingSeconds(_ info: Info, now: Date, fallbackSecondsPerTrack: Double) -> Double {
        let left = max(info.total - info.done, 0)
        let elapsed = now.timeIntervalSince1970 - Double(info.startedAt)
        let perTrack = info.roundDoneOrDone > 0 && elapsed > 0
            ? elapsed / Double(info.roundDoneOrDone)
            : fallbackSecondsPerTrack
        return Double(left) * perTrack
    }

    static let requestURL = LyrimusePaths.configFile("lyrimuse-lyrics-fill-request.txt")
    static let statusURL = LyrimusePaths.configFile("lyrimuse-lyrics-fill-status.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: Info?

    /// 最近一轮的进度;文件不存在/解析失败都是 nil。
    public static var current: Info? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: statusURL.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = (try? Data(contentsOf: statusURL)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
        return cached
    }

    /// 请求文件的内容——纯函数,selftest 覆盖(引擎侧 parseLyricsFillRequest 是它的读方)。
    /// keys 为空 = 全部;非空 = 只这些。key 原样写,一行一个;含换行的 key 不存在
    /// (EnrichCacheKeys 由 media tag 拼成,tag 里不会有换行)。
    public static func requestBody(keys: [String]) -> String {
        if keys.isEmpty { return "all\n" }
        return keys.joined(separator: "\n") + "\n"
    }

    /// 要一轮补空:keys 为空 = 全部符合条件的空条目。返回写文件是否成功。
    @discardableResult
    public static func request(keys: [String]) -> Bool {
        write(requestBody(keys: keys), startsRound: true)
    }

    /// 要一轮「重新匹配整个歌词库」。范围、分层与跨重启续跑全在引擎侧(lyricsfullscan.go),
    /// 这里只负责写下那个动词 —— 候选是**跑的那一刻**现算的,App 不预先把几千个 key 列进
    /// 请求文件:那份列表在一两天的扫描期间会不断过时(歌被播到就自己升级了)。
    @discardableResult
    public static func requestFullScan() -> Bool {
        write("full\n", startsRound: true)
    }

    /// 停掉正在跑的这一轮。
    @discardableResult
    public static func requestCancel() -> Bool {
        write("cancel\n", startsRound: false)
    }

    private static func write(_ body: String, startsRound: Bool) -> Bool {
        let ok = (try? body.write(to: requestURL, atomically: true, encoding: .utf8)) != nil
        lock.lock()
        requestedAt = ok && startsRound ? Date() : nil
        lock.unlock()
        return ok
    }

    // MARK: - 请求写下、引擎还没接手的那几秒

    /// 引擎每 2 秒读一次请求文件,读到后先挑候选、再写状态文件;点下「开始」到界面上出现进度
    /// 之间有几秒空档。这段时间按钮要置灰、给个在忙的样子,否则用户会再点一次(第二份请求被
    /// 引擎静默丢掉)。等太久(引擎没在跑)就放弃,按钮恢复可点。
    public static let pendingTimeout: TimeInterval = 10

    nonisolated(unsafe) private static var requestedAt: Date?

    /// 此刻是不是「请求写下了、引擎还没接手」。两个入口(歌词管理侧栏「⋯」、设置页歌词库)共用。
    public static var isPending: Bool {
        lock.lock()
        let at = requestedAt
        lock.unlock()
        return isPending(requestedAt: at, status: current, now: Date())
    }

    /// 判据本体,纯函数,selftest 覆盖。状态文件里出现了开工时刻不早于请求的一轮(含一条候选都没有、
    /// 一开工就收尾的那种)就算接手了。比较按整秒:引擎写的 startedAt 是 Unix 秒。
    public static func isPending(requestedAt: Date?, status: Info?, now: Date) -> Bool {
        guard let requestedAt, now.timeIntervalSince(requestedAt) < pendingTimeout else { return false }
        guard let status else { return true }
        return status.startedAt < Int64(requestedAt.timeIntervalSince1970)
    }

    // MARK: - 扫描期间要不要重读缓存

    /// 扫描跑着时缓存文件每搜完一首都会变(没补出东西也要记重试时间和决策留痕),而重读整份缓存
    /// 一次要一两秒 CPU、内存临时涨两三百 MB。列表和统计上看得见的东西只在这几个时刻变:
    /// 补出了一首(`filled` 变了)、一轮开始或结束、换了一轮。其余时候按平时的节奏读就够。纯函数,selftest 覆盖。
    public static func changesVisibleRows(previous: Info?, current: Info?) -> Bool {
        guard let current else { return previous != nil }
        guard let previous else { return true }
        return current.filled != previous.filled
            || current.running != previous.running
            || current.startedAt != previous.startedAt
    }
}
