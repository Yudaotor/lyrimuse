import Foundation

/// 诊断包里日志正文的脱敏。
///
/// 背景(2026-08-13 实测坐实):`DiagnosticsExporter` 开头写着一条硬约束——绝不能把任何
/// token/secret 的原文写进诊断文件,因为它就是设计给用户贴进**公开** GitHub issue 的。
/// 结构化那一段确实守住了(只写 `isXConfigured` 这类只读布尔),但报告末尾直接把
/// `~/Library/Logs/lyrimuse.log` 的最后 200 行原样附上,整个绕开了这条约束。
///
/// 实测:`lastfm.go` 里 `log.Printf("lastfmRecent: request failed: %v", err)` 打印的是
/// Go `*url.Error` 的原文,而它的 `Error()` 会把**完整 URL** 带出来 —— api_key 恰好在
/// query string 里。当时本机日志的最后 200 行内就有 3 处 Last.fm API Key 原文。
///
/// 修在**出口**而不是逐个 `log.Printf` 调用点,是因为出口只有这一个、而调用点会一直新增:
/// 任何以后新写的日志行都自动被这里兜住,不用每加一处就想一次"这行会不会带凭据"。
/// (逐个改调用点那条路是打地鼠,而且 collector 是 Go、App 是 Swift,两边都要各改一遍。)
///
/// 两层是**纵深**关系,都要跑:
///  1. `redact(_:secrets:)` —— 拿当前配置里的密钥原文去做字面替换。不依赖任何格式假设,
///     不管凭据以 query 参数、URL path、JSON 片段还是裸串的形式出现在日志里都能命中。
///  2. `redactPatterns(_:)` —— 正则兜住第一层覆盖不到的:用户换过的**旧**凭据(已经不在
///     当前配置里,但仍留在历史日志行里)、第三方服务回显的凭据、以后新接入而还没登记进
///     第一层的服务。
public enum LogRedactor {
    /// 值级脱敏的最短长度。低于这个长度的配置值不参与字面替换 —— 那种长度的值(比如用户名
    /// 缩写、平台名 "bark")极可能同时是日志里的普通词,替换掉只会让报告没法读,而它们本身
    /// 也不是凭据。真实凭据都远长于此(Last.fm key 32、ListenBrainz token 36、relay 48)。
    static let minimumSecretLength = 8

    /// 用已知的密钥原文做字面替换。
    ///
    /// - Parameter secrets: 字段名 → 该字段当前的值。字段名只用于在报告里标出"这里原本是
    ///   哪一项",本身不敏感;值为空或过短的条目会被跳过。
    ///
    /// 按值的长度**降序**替换:两个凭据互为前缀/子串时(例如 relay token 恰好以某个 key
    /// 开头),先替换短的会把长的切碎、留下一截原文在外面。
    public static func redact(_ text: String, secrets: [String: String]) -> String {
        var out = text
        let usable = secrets
            .filter { $0.value.count >= minimumSecretLength }
            .sorted { $0.value.count > $1.value.count }
        for (field, value) in usable {
            out = out.replacingOccurrences(of: value, with: "<redacted:\(field)>")
        }
        return out
    }

    /// 敏感 query 参数名。大小写不敏感匹配。
    private static let sensitiveQueryKeys = [
        "api_key", "apikey", "api_sig", "access_token", "token", "sk",
        "secret", "password", "passwd", "pwd", "sign", "signature", "key",
        "session_key", "sessionkey", "auth",
    ]

    /// 凭据长在 URL **路径**里的服务 —— 这类最危险:值级脱敏没登记时,query 那条规则也
    /// 兜不住,因为它根本不是 query 参数。Bark 的 device key 就是这种形状
    /// (`api.day.app/<KEY>/标题/正文`),而 `alerter.go` 打印 err 原文的写法跟 lastfm.go
    /// 是同一个形状 —— 目前没泄只是因为推送还没失败过,断一次网就会进日志。
    private static let pathCredentialHosts: [(host: String, pattern: String)] = [
        ("api.day.app", #"(api\.day\.app/)(?!<redacted)[^/\s"']+"#),
        ("sctapi.ftqq.com", #"(sctapi\.ftqq\.com/)(?!<redacted)[^/\s"'.]+"#),
        ("open.feishu.cn", #"(open\.feishu\.cn/open-apis/bot/v2/hook/)(?!<redacted)[^/\s"']+"#),
    ]

    /// 正则兜底:打掉常见形状的凭据,不要求它出现在当前配置里。
    public static func redactPatterns(_ text: String) -> String {
        var out = text

        // query 参数:`api_key=xxx` → `api_key=<redacted>`。值取到分隔符为止 —— & 结束下
        // 一个参数,引号/空格结束整个 URL(Go 的 *url.Error 把 URL 包在双引号里)。
        //
        // `(?!<redacted)` 不可省:第一层值级脱敏已经把命中的凭据换成了
        // `<redacted:字段名>`,而那个标记本身不含 & / 空格 / 引号,会被下面这个字符类整个
        // 吃掉,于是第二层把第一层写好的字段名冲成一个光秃秃的 <redacted> —— 排查时就
        // 看不出那里原本是哪一项了。selftest 里有这条断言。
        let joined = sensitiveQueryKeys.joined(separator: "|")
        out = replace(out, pattern: "(?i)\\b(\(joined))=(?!<redacted)[^&\\s\"'\\\\]+", template: "$1=<redacted>")

        for (_, pattern) in pathCredentialHosts {
            out = replace(out, pattern: pattern, template: "$1<redacted>")
        }

        // HTTP 头形式:`x-token: xxx` / `Authorization: Bearer xxx`
        out = replace(out, pattern: #"(?i)(authorization:\s*bearer\s+)\S+"#, template: "$1<redacted>")
        out = replace(out, pattern: #"(?i)(x-token:\s*)\S+"#, template: "$1<redacted>")

        return out
    }

    /// 两层都跑。诊断报告里的每一段日志正文都该经过这里。
    public static func redactAll(_ text: String, secrets: [String: String]) -> String {
        redactPatterns(redact(text, secrets: secrets))
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
