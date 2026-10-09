import Foundation

/// 引擎发布的各歌词源近况:`lyrimuse-lyric-source-stats.json` 的 `summary` 段。写入方和判定规则都在
/// lyrimuse-engine/lyricsourcestats.go(见 09 章决策 147),计数只有常驻进程手里有,App 不自己重算。
///
/// 只读通道:App 从不写这份文件。
public enum LyricSourceHealth {
    /// 取值与引擎的 lyricSourceAlert* 同一套。
    public enum Alert: String, Sendable {
        /// 同类曲库至少两家找得到的歌,它几乎一首都没给。
        case barely
        /// 同类条件下给出歌词的比例掉到平时的六成以下。
        case belowUsual = "below_usual"
        /// 大部分查询因为接连出错被熔断跳过。
        case cooling
        /// 冷却原因是网络错误,而且同时还有别的源也这样。
        case network
        /// 没问它的那些轮大半是因为被它的反爬拦下了(引擎已暂停它,到点自动再试)。
        case blocked
        /// 最近连续一段里一首词都没给,按它平时的收录这不该发生。
        case stopped
    }

    public struct Summary: Decodable, Equatable, Sendable {
        public let source: String
        public let enabled: Bool
        /// 近 7 天这个源开着的现查次数、交出候选的次数、胜出的次数。
        public let rounds: Int
        public let responded: Int
        public let won: Int
        /// 认不得的取值(更新版引擎加的判定)解成 nil,按没有异常处理。
        public let alert: Alert?
        public let peerRate: Double
        public let peerRounds: Int
        public let usualRate: Double
        public let skipRate: Double
        public let networkPeers: [String]
        /// `stopped`(和按最近几轮判的 `blocked`):最近连续多少次查询它一首都没给。
        public let streak: Int
        /// `stopped`:按它平时的收录,这一段本该给出几次。
        public let expectedHits: Int
        /// `blocked`:因为被反爬拦下而没问它的查询次数。
        public let blockedRounds: Int

        enum CodingKeys: String, CodingKey {
            case source, enabled, rounds, responded, won, alert
            case peerRate = "peer_rate", peerRounds = "peer_rounds", usualRate = "usual_rate"
            case skipRate = "skip_rate", networkPeers = "network_peers"
            case streak, expectedHits = "expected_hits", blockedRounds = "blocked_rounds"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(String.self, forKey: .source)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            rounds = try c.decodeIfPresent(Int.self, forKey: .rounds) ?? 0
            responded = try c.decodeIfPresent(Int.self, forKey: .responded) ?? 0
            won = try c.decodeIfPresent(Int.self, forKey: .won) ?? 0
            alert = try c.decodeIfPresent(String.self, forKey: .alert).flatMap(Alert.init(rawValue:))
            peerRate = try c.decodeIfPresent(Double.self, forKey: .peerRate) ?? 0
            peerRounds = try c.decodeIfPresent(Int.self, forKey: .peerRounds) ?? 0
            usualRate = try c.decodeIfPresent(Double.self, forKey: .usualRate) ?? 0
            skipRate = try c.decodeIfPresent(Double.self, forKey: .skipRate) ?? 0
            networkPeers = try c.decodeIfPresent([String].self, forKey: .networkPeers) ?? []
            streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
            expectedHits = try c.decodeIfPresent(Int.self, forKey: .expectedHits) ?? 0
            blockedRounds = try c.decodeIfPresent(Int.self, forKey: .blockedRounds) ?? 0
        }

        public init(
            source: String, enabled: Bool = true, rounds: Int = 0, responded: Int = 0, won: Int = 0,
            alert: Alert? = nil, peerRate: Double = 0, peerRounds: Int = 0, usualRate: Double = 0,
            skipRate: Double = 0, networkPeers: [String] = [], streak: Int = 0, expectedHits: Int = 0,
            blockedRounds: Int = 0
        ) {
            self.source = source
            self.enabled = enabled
            self.rounds = rounds
            self.responded = responded
            self.won = won
            self.alert = alert
            self.peerRate = peerRate
            self.peerRounds = peerRounds
            self.usualRate = usualRate
            self.skipRate = skipRate
            self.networkPeers = networkPeers
            self.streak = streak
            self.expectedHits = expectedHits
            self.blockedRounds = blockedRounds
        }
    }

    /// 文件里的 `days`(逐日计数)不解:App 只用摘要。
    public struct State: Decodable, Equatable, Sendable {
        public let updatedAt: Int64
        public let summary: [Summary]

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at", summary
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
            summary = try c.decodeIfPresent([Summary].self, forKey: .summary) ?? []
        }

        public init(updatedAt: Int64 = 0, summary: [Summary] = []) {
            self.updatedAt = updatedAt
            self.summary = summary
        }
    }

    /// 摘要超过这么久没更新就不再提醒:引擎没在跑时判定停在最后一次,可能早已不成立。
    /// 引擎有新数据时每分钟、没有时每小时重写一次。与引擎的 lyricSourceStatsStaleAfter 同一个数,两处一起改。
    public static let staleAfter: TimeInterval = 2 * 24 * 3600

    /// 这个源该不该亮提醒;该亮就返回它的摘要。没有文件、文件太旧、没有判定一律 nil ——
    /// 拿不准就不说。源开没开由调用方按当前设置判(摘要里的 `enabled` 是引擎上次落盘时的)。
    public static func attention(for source: String, state: State?, now: Date = Date()) -> Summary? {
        guard let state, now.timeIntervalSince1970 - TimeInterval(state.updatedAt) <= staleAfter,
              let summary = state.summary.first(where: { $0.source == source }), summary.alert != nil
        else { return nil }
        return summary
    }

    /// 比例换成整数百分比,四舍五入口径与引擎的 math.Round 一致。
    public static func percent(_ rate: Double) -> Int { Int((rate * 100).rounded()) }

    public static func percent(_ part: Int, of total: Int) -> Int {
        total > 0 ? percent(Double(part) / Double(total)) : 0
    }

    public static let stateURL = LyrimusePaths.configFile("lyrimuse-lyric-source-stats.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: State?

    /// 当前状态;文件不存在 / 解析失败都是 nil。按 mtime 缓存,同 `LocalCacheAccess.current`。
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
