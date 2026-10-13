import Foundation

/// 引擎给正在播的那首写的单条快照(引擎 playingentry.go,`{"key": …, "entry": {…}}`,条目是完整的、带正文)。
/// 整份缓存最多攒 30 秒才落盘(引擎 enrichsave.go),新歌首次解析出的歌词在那之前只在这份里;只读整份缓存的
/// 地方(「歌词管理」)要把它并进来,不然悬浮歌词早就出词了,列表里还挂着「正在搜索」。见 11 章决策 115。
public enum PlayingEntrySnapshot {
    public static let url = LyrimusePaths.configFile("lyrimuse-playing-entry.json")

    /// 读出 key 和条目原样;文件不在、形状不对为 nil。
    public static func read(at url: URL = url) -> (key: String, entry: [String: Any])? {
        guard let data = FileIO.read(url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = obj["key"] as? String, !key.isEmpty,
              let entry = obj["entry"] as? [String: Any] else { return nil }
        return (key, entry)
    }

    /// 快照比整份缓存新才算数:整份写完之后快照就是旧的,别拿它盖住整份里后来的改动(手改、重评)。纯函数,selftest 覆盖。
    public static func supersedes(snapshotMTime: Date?, cacheMTime: Date?) -> Bool {
        guard let snapshotMTime, let cacheMTime else { return false }
        return snapshotMTime > cacheMTime
    }
}

/// 引擎整份落盘攒着的这段时间里改过的条目(引擎 enrichpending.go,`{"entries": {key: 完整条目}}`)。整份缓存最多攒
/// 10 分钟才落盘,预取、补全、补空扫描改过的条目在那之前只在这份里;读整份缓存的地方这份比缓存新时叠上去
/// (`PlayingEntrySnapshot.supersedes` 同一个判据)。见 15 章决策 36。
public enum EnrichPendingEntries {
    public static let url = LyrimusePaths.configFile("lyrimuse-enrich-pending.json")

    /// 读出全部条目(key → 原样的 JSON 对象);文件不在、形状不对为 nil。
    public static func read(at url: URL = url) -> [String: [String: Any]]? {
        guard let data = FileIO.read(url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = obj["entries"] as? [String: [String: Any]], !entries.isEmpty else { return nil }
        return entries
    }
}
