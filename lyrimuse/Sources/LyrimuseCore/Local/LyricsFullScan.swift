import Foundation

/// App ⇄ collector 的「全量重新扫库」状态通道(2026-09-16,见 collector/lyricsfullscan.go 头注)。
///
/// ## 这件事跟「补空扫描」的关系
///
/// 请求和进度**共用**补空那条通道(`LyricsFillSweep`):请求文件多认一个动词 `full`,进度文件
/// 多一个 `full` 字段。一次只允许一轮在跑,两边共用同一个取消入口。这里多出来的只有一份
/// **状态文件**,因为全量扫库比补空多两件事要跨进程说清楚:
///
///   1. **当前打分版本号**。界面要显示「N 首待跟进」,就得知道"跟上"是跟上哪个版本 ——
///      而 `lyricsScoringVersion` 那个常量住在 collector 里。collector 每次启动把它写进这份
///      文件,App 读。读不到(collector 还没起来过、或版本太老不认识这个文件)就是 `nil`,
///      界面据此把整行藏掉,而不是拿一个猜来的版本号算出一个假数字。
///   2. **有一轮没跑完**。全库几千首、每首之间隔 15 秒,一轮要跑一两天,期间 collector 必然
///      重启若干次。这个标记让它重启后接着跑;进度本身不需要存 —— 每条跑完打分版本号就被
///      推到当前值,重新算候选时它自然不在列表里了。
///
/// 只读通道:App 从不写这份文件(要开一轮就写请求文件那个 `full`)。
public enum LyricsFullScan {
    public struct State: Decodable, Equatable, Sendable {
        /// 写这份文件时 collector 的打分规则版本号。
        public let scoringVersion: Int
        /// 有一轮全量扫库还没跑完,collector 下次启动会接着跑。
        public let active: Bool
        /// 这一轮**最初**是什么时候被请求的(续跑不刷新它)。0 = 没有在跑的一轮。
        public let startedAt: Int64
        public let updatedAt: Int64
        /// 每首歌的粗略耗时估计(秒),由 collector 发布 —— 界面那句「预计约 N 小时」用它。
        ///
        /// 跟 `scoringVersion` 同一个理由:这个数由 collector 侧的常量决定
        /// (`lyricsFullScanGap` + 一轮全源搜索的估计),**App 不该自己写死一份**。
        /// 2026-09-17 之前界面里就硬编码着 25 秒、注释还写着「15 秒固定间隔」,collector 把
        /// 全量那一档改成 5 秒之后,那个数和那句话当场都成了错的,而没有任何东西会报错。
        ///
        /// 0 = 这份文件是老 collector 写的(Go 那边带 omitempty),调用方退回自己的兜底值。
        public let secondsPerTrack: Int

        enum CodingKeys: String, CodingKey {
            case scoringVersion, active, startedAt, updatedAt, secondsPerTrack
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scoringVersion = try c.decodeIfPresent(Int.self, forKey: .scoringVersion) ?? 0
            // active / startedAt 在 Go 那边带 omitempty,没有待续的一轮时整个键都不出现 ——
            // 非可选解码会让这份文件整个解不开,连版本号也一起读不到。
            active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
            startedAt = try c.decodeIfPresent(Int64.self, forKey: .startedAt) ?? 0
            updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
            // 同样带 omitempty:老 collector 的文件里没有这个键,读成 0 交给调用方兜底。
            secondsPerTrack = try c.decodeIfPresent(Int.self, forKey: .secondsPerTrack) ?? 0
        }

        public init(scoringVersion: Int, active: Bool, startedAt: Int64 = 0, updatedAt: Int64 = 0,
                    secondsPerTrack: Int = 0) {
            self.scoringVersion = scoringVersion
            self.active = active
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.secondsPerTrack = secondsPerTrack
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
        cached = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        return cached
    }

    /// 一条条目会不会被全量扫库拿去重跑,以及它落在哪一层。
    ///
    /// ⚠️ 这是 collector 侧 `lyricsFullScanTier` 的**镜像**,两边必须逐条对得上 —— 界面上
    /// 那个「N 首待跟进」说的就是"真会被扫的条数",分歧会直接表现为"点了扫描,数字对不上"。
    /// 放在 LyrimuseCore 而不是 `EnrichCacheStore`(App target,selftest 引用不到)正是为了
    /// 让这份镜像能被单测钉住:层分错了扫描照样跑完,只是把该修的歌漏掉,完全不报错。
    ///
    /// 层的含义(收益递减,扫描按这个顺序跑,好让中途停掉时留下的是最值钱的那部分):
    ///   - 0 = 一条歌词都没有(只有纯文本兜底的也算);
    ///   - 1 = 有词但没逐字 —— 唯一可能升一档成色的一批;
    ///   - 2 = 有逐字、只是打分版本落后;
    ///   - nil = 这一轮不碰它。
    public enum Tier: Int, CaseIterable, Sendable {
        case empty = 0
        case lineOnly = 1
        case staleVersion = 2
    }

    public static func tier(
        hasLyrics: Bool, hasWordTiming: Bool, scoringVersion: Int, currentScoringVersion: Int,
        isManual: Bool, isInstrumental: Bool, isPinned: Bool
    ) -> Tier? {
        // 四道硬闸,跟 collector 一字不差。手改过的、确证纯音乐的、校准过时间轴的一律不碰;
        // 校准那道是全量扫库相对补空扫描**多出来**的一道(补空只碰没词的条目,没词就没有
        // 校正值可作废),缺了它一轮扫描会把用户一句句听出来的几百毫秒集体作废。
        if isManual || isInstrumental || isPinned { return nil }
        if !hasLyrics { return .empty }
        if !hasWordTiming { return .lineOnly }
        if scoringVersion < currentScoringVersion { return .staleVersion }
        // 已经是逐字**且**版本追平:同一套规则重跑必然得出同一个结论,纯粹白烧网络。
        return nil
    }
}
