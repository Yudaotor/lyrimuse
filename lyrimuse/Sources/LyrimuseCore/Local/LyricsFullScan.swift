import Foundation

/// App 与引擎的「重新匹配整个歌词库」状态通道(见 lyrimuse-engine/lyricsfullscan.go 头注)。
///
/// ## 这件事跟「补空扫描」的关系
///
/// 请求和进度**共用**补空那条通道(`LyricsFillSweep`):请求文件多认一个动词 `full`,进度文件
/// 多一个 `full` 字段。一次只允许一轮在跑,两边共用同一个取消入口。这里多出来的只有一份
/// **状态文件**,因为全量扫库比补空多两件事要跨进程说清楚:
///
///   1. **待跟进的条数**。哪些条目会被扫由引擎的分层规则决定(四道硬闸、三层、续跑时跳过这一场
///      跑过的、「再搜也不会有」的空条目),条数也由它数好写进这份文件(`pending`),App 只显示。
///      读不到(引擎还没起来过、还没数完第一遍)就是 `nil`,界面据此不显示数字,而不是拿一个
///      猜来的数。
///   2. **有一轮没跑完**。全库几千首、每首之间隔 15 秒,一轮要跑一两天,期间引擎必然
///      重启若干次。这个标记让它重启后接着跑;进度本身不需要存 —— 每条跑完打分版本号就被
///      推到当前值,重新算候选时它自然不在列表里了。
///
/// 只读通道:App 从不写这份文件(要开一轮就写请求文件那个 `full`)。
public enum LyricsFullScan {
    public struct State: Decodable, Equatable, Sendable {
        /// 写这份文件时引擎的打分规则版本号。
        public let scoringVersion: Int
        /// 同一主版本下的开发修订号(引擎 `lyricsScoringRevision`),跟 `scoringVersion` 一起比新旧。
        /// 0 = 正式版,或这份文件是老引擎写的(Go 那边带 omitempty)。
        public let scoringRevision: Int
        /// 有一轮全量扫库还没跑完,引擎下次启动会接着跑。
        public let active: Bool
        /// 这一轮**最初**是什么时候被请求的(续跑不刷新它)。0 = 没有在跑的一轮。
        public let startedAt: Int64
        public let updatedAt: Int64
        /// 每首歌的粗略耗时估计(秒),由引擎发布 —— 界面那句「预计约 N 小时」用它。
        ///
        /// 跟 `scoringVersion` 同一个理由:这个数由引擎侧的常量决定
        /// (`lyricsManualSweepGap` + 一轮全源搜索的估计),**App 不该自己写死一份**。
        /// 之前界面里就硬编码着 25 秒、注释还写着「15 秒固定间隔」,引擎把
        /// 全量那一档改成 5 秒之后,那个数和那句话当场都成了错的,而没有任何东西会报错。
        ///
        /// 0 = 这份文件是老引擎写的(Go 那边带 omitempty),调用方退回自己的兜底值。
        public let secondsPerTrack: Int
        /// 这一刻真会被全量扫库挑中的条数,引擎数好发布(`publishLyricsFullScanPending`),界面上
        /// 「N 首待重新匹配」就是它。nil = 还没数过,界面不显示数字;0 = 已全部跟进。
        public let pending: Int?

        enum CodingKeys: String, CodingKey {
            case scoringVersion, scoringRevision, active, startedAt, updatedAt, secondsPerTrack, pending
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scoringVersion = try c.decodeIfPresent(Int.self, forKey: .scoringVersion) ?? 0
            scoringRevision = try c.decodeIfPresent(Int.self, forKey: .scoringRevision) ?? 0
            // active / startedAt 在 Go 那边带 omitempty,没有待续的一轮时整个键都不出现 ——
            // 非可选解码会让这份文件整个解不开,连版本号也一起读不到。
            active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
            startedAt = try c.decodeIfPresent(Int64.self, forKey: .startedAt) ?? 0
            updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
            // 同样带 omitempty:老引擎的文件里没有这个键,读成 0 交给调用方兜底。
            secondsPerTrack = try c.decodeIfPresent(Int.self, forKey: .secondsPerTrack) ?? 0
            pending = try c.decodeIfPresent(Int.self, forKey: .pending)
        }

        public init(scoringVersion: Int, scoringRevision: Int = 0, active: Bool, startedAt: Int64 = 0, updatedAt: Int64 = 0,
                    secondsPerTrack: Int = 0, pending: Int? = nil) {
            self.scoringVersion = scoringVersion
            self.scoringRevision = scoringRevision
            self.active = active
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.secondsPerTrack = secondsPerTrack
            self.pending = pending
        }
    }

    static let stateURL = LyrimusePaths.configFile("lyrimuse-lyrics-fullscan.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: State?

    /// 当前状态;文件不存在/解析失败都是 nil。按 mtime 缓存,同 `LyricsFillSweep.current`。
    public static var current: State? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: stateURL.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = FileIO.decodeJSON(State.self, from: stateURL)
        return cached
    }
}
