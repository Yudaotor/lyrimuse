import Foundation

/// Last.fm 2.0 端点的 GET query 编码。
///
/// 为什么不能直接用 `URLComponents.queryItems`(2026-08-22 实测坐实):**这个端点会对
/// query value 多解一次码**。它先做一遍标准 percent-decode,再对结果做一遍
/// form-urlencoded 解码——后面那一遍会把 `+` 当成空格。于是含加号的歌名/歌手名走标准
/// 编码必然查不到:
///
///     track=夜曲%2B窃爱 (Live)    → 两遍解完是「夜曲 窃爱 (Live)」→ error 6 Track not found
///     track=夜曲%252B窃爱 (Live)  → 两遍解完是「夜曲+窃爱 (Live)」→ 命中,userplaycount=2
///
/// 这是**端点级**行为,不是某一首歌的问题:拿真实存在的乐队 `+44`(733,475 听众)单测过
/// —— `artist=%2B44` 同样报 error 6,`artist=%252B44` 才命中。
///
/// ⚠️ 只有 GET query 这样。scrobble 那条走 POST form body(collector 的 lastfm.go),
/// 只解一遍,**不能**套这里的规则——套了会把字面 `%2B` 写进 Last.fm 的曲名。
/// 「记得对、却查不到」这个不对称正是本坑的表征:用户 2026-08-22 报的《夜曲+窃爱 (Live)》
/// 在最近记录里永远不显示「第 N 次听」,而它的 scrobble 本身记得好好的。
///
/// 做法:先把 value 里的 `%` 和 `+` 各多编一层,再按 RFC 3986 unreserved 做严格
/// percent-encoding。不含这两个字符的 value 编出来跟标准编码逐字节相同,所以对既有请求
/// 是零影响(回归实测:开不了口 (live)/十年/光辉岁月 三首照常命中)。
public enum LastfmQuery {
    /// RFC 3986 unreserved。刻意比 `CharacterSet.urlQueryAllowed` 严格得多——后者放行
    /// `+`,那正是这个坑的入口(URLComponents 用的就是它)。
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// 一个 query 分量的编码:`+` → `%252B`、`%` → `%2525`,其余按 unreserved 严格转义。
    ///
    /// ⚠️ 两次 replace 的顺序不能反。先换 `%` 再换 `+`:反过来的话第一步产出的 `%2B`
    /// 里那个 `%` 会被第二步再啃一遍,变成 `%252525…`。
    public static func escape(_ value: String) -> String {
        let doubled = value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "+", with: "%2B")
        return doubled.addingPercentEncoding(withAllowedCharacters: unreserved) ?? doubled
    }

    /// 拼成完整的 query 串(不含开头的 `?`)。按传入顺序拼,不排序——调用方给的顺序就是
    /// 日志/抓包里看到的顺序。Last.fm 的读接口不签名,顺序对结果没有影响。
    public static func queryString(_ pairs: [(name: String, value: String)]) -> String {
        pairs.map { escape($0.name) + "=" + escape($0.value) }.joined(separator: "&")
    }
}
