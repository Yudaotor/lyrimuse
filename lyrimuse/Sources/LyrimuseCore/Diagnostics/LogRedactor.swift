import Foundation

/// 诊断包里日志正文的脱敏。诊断导出设计给贴进**公开** GitHub issue,任何 token / secret 的原文都不能进去。
///
/// 日志正文里会出现凭据:Go `*url.Error` 的 `Error()` 带完整 URL,Last.fm 的 api_key 就在 query string 里。
/// 引擎写日志时已经脱敏过一道(logscrub.go),这里是导出出口上的第二道,两道都要留。
///
/// 修在**出口**而不是逐个 `log.Printf` 调用点:出口只有这一个,调用点会一直新增,新写的日志行自动被这里兜住。
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
    ///
    /// 值先去首尾空白:用户粘贴的 token 常带尾随空格 / 换行,引擎用的(也就是日志里出现的)是去掉之后的那串。
    public static func redact(_ text: String, secrets: [String: String]) -> String {
        var out = text
        let usable = secrets
            .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.value.count >= minimumSecretLength }
            .sorted { $0.value.count > $1.value.count }
        for (field, value) in usable {
            out = out.replacingOccurrences(of: value, with: "<redacted:\(field)>")
        }
        return out
    }

    /// URL 查询参数(前面是 `?` 或 `&`)按**词根**认,跟引擎 logscrub.go 的 sensitiveQueryRe 同一条:
    /// 参数名里含 key / token / secret / sig / sign / password / passwd / pwd / auth 的都算
    /// (client_secret、refresh_token、api_sig 都在内),`sk` 不含任何词根,单列 —— 它是 Last.fm session key。
    private static let sensitiveQueryParamPattern =
        #"(?i)([?&](?:sk|[a-z0-9_.\-]*(?:key|token|secret|sig|sign|password|passwd|pwd|auth)[a-z0-9_.\-]*)=)(?!<redacted)[^&\s"'\\`]+"#

    /// 不在 URL 里的裸 `名=值`(日志自己拼的)只认这份名单:按词根认会把 signal=、design= 这类普通日志词一起打掉。
    private static let sensitiveQueryKeys = [
        "api_key", "apikey", "api_sig", "access_token", "refresh_token", "id_token", "token", "sk",
        "secret", "client_secret", "password", "passwd", "pwd", "sign", "signature", "key",
        "session_key", "sessionkey", "auth",
    ]

    /// JSON 里的 `"名":"值"`。词根只取 token / secret / password 几个 —— key 太常见(日志里的缓存 key
    /// 「歌手|歌名|专辑」就叫 key),只认明确是凭据的几个全名。
    private static let sensitiveJSONPattern =
        #"(?i)("(?:[a-z0-9_.\-]*(?:token|secret|password|passwd|pwd)[a-z0-9_.\-]*|api_key|apikey|api_sig|sk|session_key|sessionkey|authorization)"\s*:\s*")(?!<redacted)[^"]+"#

    /// 凭据长在 URL **路径**里的服务 —— 这类最危险:值级脱敏没登记时,query 那条规则也
    /// 兜不住,因为它根本不是 query 参数。Bark 的 device key 就是这种形状
    /// (`api.day.app/<KEY>/标题/正文`),而 `alerter.go` 打印 err 原文的写法跟 lastfm.go
    /// 是同一个形状 —— 目前没泄只是因为推送还没失败过,断一次网就会进日志。
    private static let pathCredentialHosts: [(host: String, pattern: String)] = [
        ("api.day.app", #"(api\.day\.app/)(?!<redacted)[^/\s"']+"#),
        ("sctapi.ftqq.com", #"(sctapi\.ftqq\.com/)(?!<redacted)[^/\s"'.]+"#),
        ("open.feishu.cn", #"(open\.feishu\.cn/open-apis/bot/v2/hook/)(?!<redacted)[^/\s"']+"#),
        // Telegram:`/bot<机器人 token>/sendMessage`(引擎 notify.go 的 telegramSendURL)。
        ("api.telegram.org", #"(api\.telegram\.org/bot)(?!<redacted)[^/\s"']+"#),
        // Discord:`/api/webhooks/<id>/<token>`,id 不是凭据,token 是。
        ("discord.com", #"(discord(?:app)?\.com/api/webhooks/[0-9]+/)(?!<redacted)[^/\s"'?]+"#),
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
        out = replace(out, pattern: sensitiveQueryParamPattern, template: "$1<redacted>")
        let joined = sensitiveQueryKeys.joined(separator: "|")
        out = replace(out, pattern: "(?i)\\b(\(joined))=(?!<redacted)[^&\\s\"'\\\\]+", template: "$1=<redacted>")
        out = replace(out, pattern: sensitiveJSONPattern, template: "$1<redacted>")

        for (_, pattern) in pathCredentialHosts {
            out = replace(out, pattern: pattern, template: "$1<redacted>")
        }

        // HTTP 头形式:`x-token: xxx` / `Authorization: Bearer xxx`
        // ListenBrainz 的请求头是 `Authorization: Token <token>`,不是 Bearer。
        out = replace(out, pattern: #"(?i)(authorization:\s*(?:bearer|token|basic)\s+)(?!<redacted)\S+"#, template: "$1<redacted>")
        out = replace(out, pattern: #"(?i)(x-token:\s*)\S+"#, template: "$1<redacted>")

        return out
    }

    /// 两层都跑。诊断报告里的每一段日志正文都该经过这里。
    public static func redactAll(_ text: String, secrets: [String: String]) -> String {
        redactPatterns(redact(text, secrets: secrets))
    }

    /// 本机家目录换成 `~`。诊断包要贴进公开 issue,而日志里满是 `/Users/<本机用户名>/…`(歌词目录、配置文件、
    /// 播放器缓存)—— 用户名本身就是个人信息。只换**路径**:后面紧跟的必须是路径分隔符或不能出现在用户名里的字符,
    /// `/Users/ann` 不会把 `/Users/anna` 切掉一截。
    public static func redactHomePath(_ text: String, home: String) -> String {
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard trimmed.count > 1 else { return text }
        let pattern = NSRegularExpression.escapedPattern(for: trimmed) + #"(?![A-Za-z0-9._\-])"#
        return replace(text, pattern: pattern, template: "~")
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
