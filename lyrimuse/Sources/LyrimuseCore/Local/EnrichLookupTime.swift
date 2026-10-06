import Foundation

/// 一条歌词缓存记录最近一次搜歌词的时刻(`EnrichCacheStore.Summary.resolvedAt`)。
///
/// 引擎 `enrichEntry` 有四个字段记搜歌词的时刻,都是 Unix 秒:`ts` 只记首次解析;`lyrics_fill_ts` 是没词时每一轮补搜
/// (手动「重新自动匹配」也写它),`lyrics_retry_ts` 是有词时的升级重试,`lyrics_rescore_ts` 是按新打分规则重选。
/// 取最晚的一个,别只读 `ts`:重新匹配之后它不会变。字段名必须跟 enrich.go 的 JSON 标签逐字一致。
public enum EnrichLookupTime {
    public static let fields = ["ts", "lyrics_fill_ts", "lyrics_retry_ts", "lyrics_rescore_ts"]

    /// `entry` 是 JSONSerialization 解出来的一条记录(整数是 NSNumber);缺失或不大于 0 的字段不算,四个都没有为 nil。
    public static func latest(in entry: [String: Any]) -> Date? {
        let latest = fields.map { (entry[$0] as? Double) ?? 0 }.max() ?? 0
        return latest > 0 ? Date(timeIntervalSince1970: latest) : nil
    }
}
