import Foundation

/// 「关于」页 GitHub 仓库那一行右边那个 star 数的**纯逻辑**部分:请求地址、新鲜度判据、
/// 响应解析、限流退避。发请求和 UI 那一半在 `Settings/GitHubStarsService.swift`。
///
/// 为什么拆到 Core 而不是就近写在那个 service 里:selftest 只能 `import LyrimuseCore`
/// (App 是可执行目标,导不进来),接缝画在数值上、纯逻辑放这边才能被断言钉住 ——
/// 这条是 AGENTS.md 的既有纪律,不是为这个功能新发明的。
///
/// ⚠️ **`shouldRefresh` 为什么要单独处理"取数时间在未来"**:2026-09-03 同一天在 Last.fm
/// 统计那边真栽过 —— `fresh()` 只算 `now - fetchedAt < ttl`,系统时钟往回拨(或者
/// 时间戳被写坏)之后 `fetchedAt` 落在未来,那个差值恒为负、恒小于 TTL,于是缓存
/// **永远判定为新鲜**,界面就一直停在十几个小时前的数字上,只有手动刷新才动。这里的
/// 判据反过来:年龄为负一律当过期、立刻重取。一个时钟异常最多让我们多发一次请求,
/// 而不是让这个数字永远冻住。
public enum GitHubStars {
    /// 只读这一个接口,拿 `stargazers_count`。匿名调用即可(公开仓库),因此**不带任何
    /// 凭据** —— 这一行请求里没有 token、没有用户信息,审计日志里也只会出现 host。
    /// 匿名配额是每 IP 每小时 60 次,而下面的 TTL 是 6 小时,离配额差着两个数量级。
    public static let repoAPIURL = URL(string: "https://api.github.com/repos/Yudaotor/lyrimuse")!

    /// 多久重取一次。star 数是个慢变量,6 小时足够 —— 这个数字存在的意义是"开源免费,
    /// 你的 star 是最大的鼓励"那句话的凭据,不是实时看板。
    public static let refreshTTL: TimeInterval = 6 * 3600

    /// 失败(断网/超时/非 200)之后多久才允许再试。
    ///
    /// 有它是因为「关于」页每次出现都会调一次 `refreshIfStale()`:没有退避的话,断网状态下
    /// 用户来回切几次分类就是几次必然失败的请求,白占系统的网络栈、也把审计日志刷满。
    public static let failureBackoff: TimeInterval = 30 * 60

    /// 解析 `/repos/{owner}/{repo}` 的响应,只取 `stargazers_count` 一个字段。
    ///
    /// 用 `JSONSerialization` 而不是 `Codable`:这个响应有一百多个字段,为一个整数定义
    /// 一个 struct(还要跟着 GitHub 的字段变动走)不划算,同 `ListenBrainzTokenCheck`。
    /// 负数和非整数一律判为解析失败 —— 宁可不显示,也不显示一个看起来很确定的错数字
    /// (这条是 Last.fm 那边"API key 失效返回 200 + error,不识别就会显示 0 scrobble"
    ///  那次留下的教训)。
    public static func parseStarCount(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["stargazers_count"] as? Int,
              raw >= 0
        else { return nil }
        return raw
    }

    /// 该不该现在发这一次请求。
    ///
    /// - Parameters:
    ///   - fetchedAt: 上一次**成功**取到的时刻;从没成功过传 nil。
    ///   - retryNotBefore: 上一次失败/被限流后算出来的"最早重试时刻";没有失败过传 nil。
    public static func shouldRefresh(now: Date, fetchedAt: Date?, retryNotBefore: Date?) -> Bool {
        // 退避优先:限流期内连"从没取到过"也不许发 —— 那正是最容易连着撞配额的场景。
        if let retryNotBefore, now < retryNotBefore { return false }
        guard let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        // 见类型头注:年龄为负 = 时钟异常,当过期处理,别让缓存永远冻住。
        if age < 0 { return true }
        return age >= refreshTTL
    }

    /// 被限流(403/429)时,下一次最早什么时候再试。
    ///
    /// GitHub 在限流响应里给 `X-RateLimit-Reset`(配额重置的 Unix 秒)。认它而不是一律
    /// 退避半小时:重置点可能就在一分钟后,也可能在一小时后,自己拍一个数两头都不对。
    /// 头缺失/解析不出/已经过去了,才退回 `failureBackoff`。
    public static func retryDate(now: Date, rateLimitReset: String?) -> Date {
        let fallback = now.addingTimeInterval(failureBackoff)
        guard let rateLimitReset, let epoch = TimeInterval(rateLimitReset.trimmingCharacters(in: .whitespaces))
        else { return fallback }
        let reset = Date(timeIntervalSince1970: epoch)
        return reset > now ? reset : fallback
    }
}
