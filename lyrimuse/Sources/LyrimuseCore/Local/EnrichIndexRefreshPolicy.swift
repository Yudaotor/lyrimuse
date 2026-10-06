import Foundation

/// App 整份重解歌词缓存索引的节奏(见 15 章决策 23):引擎存一次盘,App 就要把整份索引重读重解一遍,一次 1 秒上下的
/// CPU。正在播的那首先读单条快照,不靠整份;别的歌晚一点更新没人等着看。
public enum EnrichIndexRefreshPolicy {
    /// 两次整份重解至少隔这么久。
    public static let minimumInterval: TimeInterval = 20

    /// 文件变了之后,这一拍要不要起整份重解。`lastKick` / `now` 是 `ProcessInfo.systemUptime`(单调时钟,不跟着
    /// 系统时间走);还没解过(冷启动、内存压力让出之后)一律要解。
    public static func shouldRedecode(hasDecoded: Bool, lastKick: TimeInterval?, now: TimeInterval) -> Bool {
        guard hasDecoded, let lastKick else { return true }
        return now - lastKick >= minimumInterval
    }

    /// 查不到这首时要不要不等间隔当场重解:磁盘上那份比解出来的新,而且这一版还没为查不到提前解过。
    public static func shouldRedecodeOnMiss(fileMTime: Date?, decodedMTime: Date?, lastForcedMTime: Date?) -> Bool {
        guard let fileMTime, fileMTime != decodedMTime else { return false }
        return fileMTime != lastForcedMTime
    }
}
