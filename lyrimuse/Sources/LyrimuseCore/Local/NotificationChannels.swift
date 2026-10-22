import Foundation

/// 推送提醒的渠道(config.json 的 `notification_channels`,引擎 notifychannel.go 的 notifyChannel)。
/// 想推到几个地方就配几个,各自启用 / 停用。`secret` 按平台是不同的东西:钉钉加签密钥、飞书签名密钥、
/// ntfy 访问令牌、通用 Webhook 的签名密钥;`chatID` 只有 Telegram 用。
///
/// 渠道列表之前只有一个渠道,字段散在顶层(`notification_platform`、`bark_url`、`dingtalk_sign_secret`、
/// `feishu_sign_secret`、`telegram_chat_id`,其余平台的地址在 `notification_webhook_urls`)。读到没有
/// `notification_channels` 的配置时用 `migrated(fromLegacy:)` 换成渠道列表,旧键留在文件里不删(装回旧版还能用)。
/// 引擎看的是 `notification_channels` 这个键在不在,不是列表空不空,所以渠道删光了要写 `[]`。
public struct NotificationChannel: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 平台 rawValue,跟引擎 notify.go 的平台常量逐字对应。
    public var platform: String
    public var url: String
    public var secret: String
    public var chatID: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String = "", platform: String, url: String = "",
                secret: String = "", chatID: String = "", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.platform = platform
        self.url = url
        self.secret = secret
        self.chatID = chatID
        self.enabled = enabled
    }

    /// 从旧的单渠道字段拼出来的那个渠道的 id(引擎 legacyNotifyChannelID)。
    public static let legacyID = "legacy"

    /// 填齐了能发(启用与否另算),同引擎 notifyChannel.complete。
    public var isComplete: Bool {
        !Self.trim(url).isEmpty && (platform != "telegram" || !Self.trim(chatID).isEmpty)
    }

    /// 落盘用的形状。地址、密钥、Chat ID 去掉首尾空白(粘贴进来的常带换行)。
    public var jsonObject: [String: Any] {
        var o: [String: Any] = ["id": id, "platform": platform, "url": Self.trim(url), "enabled": enabled]
        if !name.isEmpty { o["name"] = name }
        if !Self.trim(secret).isEmpty { o["secret"] = Self.trim(secret) }
        if !Self.trim(chatID).isEmpty { o["chat_id"] = Self.trim(chatID) }
        return o
    }

    public init?(jsonObject o: [String: Any]) {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, name: o["name"] as? String ?? "", platform: (o["platform"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "bark",
                  url: o["url"] as? String ?? "", secret: o["secret"] as? String ?? "", chatID: o["chat_id"] as? String ?? "",
                  enabled: o["enabled"] as? Bool ?? false)
    }

    /// config.json 里的渠道列表;没有这个键时为 nil(还是旧配置)。认不出的项跳过。
    public static func list(fromConfig raw: [String: Any]) -> [NotificationChannel]? {
        guard let items = raw["notification_channels"] as? [Any] else { return nil }
        return items.compactMap { ($0 as? [String: Any]).flatMap(NotificationChannel.init(jsonObject:)) }
    }

    /// 旧的单渠道字段换成渠道列表:正在用的那个平台(`bark_url` 填了的话)启用;别的平台存过的地址也各成一个渠道,
    /// 停用着 —— 旧版里切到别的平台时那些地址只是另存着、没在推,迁过来不能突然开始往那边推,也不能丢。
    public static func migrated(fromLegacy raw: [String: Any]) -> [NotificationChannel] {
        let active = (raw["notification_platform"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "bark"
        var urls = raw["notification_webhook_urls"] as? [String: String] ?? [:]
        let activeURL = trim(raw["bark_url"] as? String ?? "")
        if !activeURL.isEmpty { urls[active] = activeURL }
        func secret(_ platform: String) -> String {
            switch platform {
            case "dingtalk": return trim(raw["dingtalk_sign_secret"] as? String ?? "")
            case "feishu": return trim(raw["feishu_sign_secret"] as? String ?? "")
            default: return ""
            }
        }
        let chatID = trim(raw["telegram_chat_id"] as? String ?? "")
        // 正在用的排第一,其余按平台名排,每次迁出来的顺序一样。
        let order = urls.keys.sorted { a, b in a == active ? true : b == active ? false : a < b }
        return order.compactMap { platform in
            let url = trim(urls[platform] ?? "")
            guard !url.isEmpty else { return nil }
            let isActive = platform == active && !activeURL.isEmpty
            return NotificationChannel(
                id: isActive ? legacyID : "\(legacyID)-\(platform)", platform: platform, url: url, secret: secret(platform),
                chatID: platform == "telegram" ? chatID : "", enabled: isActive)
        }
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 粘贴一整段地址时认平台。只认各平台官方的地址形状(和 Telegram 的机器人 Token),认不出返回 nil,
/// 由用户自己选:自建的 Bark、ntfy 服务器跟通用 Webhook 从地址上分不出来。
public enum NotificationPlatformDetector {
    public struct Detection: Equatable, Sendable {
        public let platform: String
        /// 地址里顺带带着的 Telegram Chat ID(`…/sendMessage?chat_id=…`),没有为空。
        public let chatID: String
    }

    public static func detect(_ text: String) -> Detection? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: #"^\d{5,}:[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil {
            return Detection(platform: "telegram", chatID: "")
        }
        guard let comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = comps.host?.lowercased() else { return nil }
        let path = comps.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let platform: String?
        switch true {
        case host == "api.day.app": platform = "bark"
        case host == "oapi.dingtalk.com" && path.hasPrefix("/robot/"): platform = "dingtalk"
        case host == "qyapi.weixin.qq.com" && path.hasPrefix("/cgi-bin/webhook/"): platform = "wecom"
        case (on("discord.com") || on("discordapp.com")) && path.hasPrefix("/api/webhooks/"): platform = "discord"
        case (host == "open.feishu.cn" || host == "open.larksuite.com") && path.hasPrefix("/open-apis/bot/"): platform = "feishu"
        case host == "sctapi.ftqq.com" || on("push.ft07.com"): platform = "serverchan"
        case host == "api.telegram.org" && path.hasPrefix("/bot"): platform = "telegram"
        case host == "hooks.slack.com": platform = "slack"
        case host == "ntfy.sh": platform = "ntfy"
        default: platform = nil
        }
        guard let platform else { return nil }
        let chatID = platform == "telegram" ? (comps.queryItems?.first { $0.name == "chat_id" }?.value ?? "") : ""
        return Detection(platform: platform, chatID: chatID)
    }
}

/// 引擎的推送记录 `lyrimuse-notify-log.json`(notifylog.go):每往一个渠道推一次记一条,留最近 100 条,旧的在前。
/// 形状两边一起改,样例在 shared/testdata/notify/。
public enum NotificationDeliveryLog {
    public static let fileName = "lyrimuse-notify-log.json"
    public static let currentSchema = 1

    public struct Entry: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        /// unix 秒
        public let at: Int64
        public let channel: String
        public let channelName: String?
        public let platform: String
        /// daily_digest / weekly_digest / monthly_digest / yearly_digest / test,见引擎 notifyEvent*。
        public let event: String?
        public let title: String?
        public let ok: Bool
        /// 见 `NotificationFailure.Kind`。
        public let kind: String
        public let status: Int?
        public let code: String?
        public let detail: String?
        public let elapsedMS: Int64
        /// 只有没推成的才有,「重发」用的就是它(App 不显示)。
        public let body: String?

        enum CodingKeys: String, CodingKey {
            case id, at, channel, platform, event, title, ok, kind, status, code, detail, body
            case channelName = "channel_name"
            case elapsedMS = "elapsed_ms"
        }

        public init(id: String, at: Int64, channel: String, channelName: String? = nil, platform: String, event: String? = nil,
                    title: String? = nil, ok: Bool, kind: String, status: Int? = nil, code: String? = nil, detail: String? = nil,
                    elapsedMS: Int64 = 0, body: String? = nil) {
            self.id = id
            self.at = at
            self.channel = channel
            self.channelName = channelName
            self.platform = platform
            self.event = event
            self.title = title
            self.ok = ok
            self.kind = kind
            self.status = status
            self.code = code
            self.detail = detail
            self.elapsedMS = elapsedMS
            self.body = body
        }

        public var date: Date { Date(timeIntervalSince1970: TimeInterval(at)) }
        public var failure: NotificationFailure? { ok ? nil : NotificationFailure(kind: kind, status: status, code: code, detail: detail) }
    }

    private struct File: Decodable {
        let schema: Int
        let entries: [Entry]?
    }

    /// 解开推送记录,新的在前。版本不认识、解不开都当作没有记录。
    public static func parse(_ data: Data) -> [Entry] {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.schema == currentSchema else { return [] }
        return (file.entries ?? []).reversed()
    }

    /// 每个渠道最近一次推送(entries 新的在前)。
    public static func latestByChannel(_ entries: [Entry]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for e in entries where out[e.channel] == nil { out[e.channel] = e }
        return out
    }
}

/// 一次推送没成的原因,引擎 classifyNotifyResponse 归的类。句子在 App 侧(按平台说该去哪儿改)。
public struct NotificationFailure: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case auth
        case rateLimited = "rate_limited"
        case rejected
        case notFound = "not_found"
        case server, network, config
    }

    /// 认不出的类别(新引擎加了类、App 还是旧的)当成 rejected。
    public let kind: Kind
    public let status: Int?
    public let code: String?
    /// 平台的原话(已截短、去掉密钥)。
    public let detail: String?

    public init(kind: String, status: Int?, code: String?, detail: String?) {
        self.kind = Kind(rawValue: kind) ?? .rejected
        self.status = status.flatMap { $0 == 0 ? nil : $0 }
        self.code = code.flatMap { $0.isEmpty ? nil : $0 }
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// 推送页「测一下」和推送记录「重发」的 App ↔ 引擎通道(引擎 notifytest.go)。
///   - 请求 `lyrimuse-notify-test-request.json`:`{"id","channel":{…}}` 测一个渠道(带着密钥,0600 写),
///     `{"id","resend":"<推送记录 id>"}` 重发一条没推成的。
///   - 结果 `lyrimuse-notify-test-result.json`:最近 10 次的结论,按 id 找。
public enum NotificationTest {
    public static let requestFileName = "lyrimuse-notify-test-request.json"
    public static let resultFileName = "lyrimuse-notify-test-result.json"

    public struct Result: Decodable, Equatable, Sendable {
        public let id: String
        public let ok: Bool
        public let kind: String
        public let status: Int?
        public let code: String?
        public let detail: String?
        public let elapsedMS: Int64
        public let at: Int64

        enum CodingKeys: String, CodingKey {
            case id, ok, kind, status, code, detail, at
            case elapsedMS = "elapsed_ms"
        }

        public var failure: NotificationFailure? { ok ? nil : NotificationFailure(kind: kind, status: status, code: code, detail: detail) }
    }

    private struct File: Decodable {
        let results: [Result]?
    }

    public static func result(id: String, in data: Data) -> Result? {
        (try? JSONDecoder().decode(File.self, from: data))?.results?.last { $0.id == id }
    }

    public static func testBody(id: String, channel: NotificationChannel) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id, "channel": channel.jsonObject], options: [.sortedKeys])) ?? Data()
    }

    public static func resendBody(id: String, entryID: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id, "resend": entryID], options: [.sortedKeys])) ?? Data()
    }

    // MARK: 预览(引擎 digestpreview.go)

    /// 预览的结果另写一个文件(最近 6 次),按 id 找。
    public static let previewResultFileName = "lyrimuse-notify-preview-result.json"

    /// 请引擎按真推送同一套取数算一份这一期的报告(不推送)。
    public static func previewBody(id: String, kind: NotificationPreview.Kind) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id, "preview": kind.rawValue], options: [.sortedKeys])) ?? Data()
    }

    public struct PreviewResult: Equatable, Sendable {
        /// 取不到真实数据的原因,同引擎 digestPreviewNoAccount 等。
        public enum Reason: String, Sendable {
            case noAccount = "no_account", empty, fetch
        }

        public let id: String
        public let title: String
        /// 取到了就有;取不到时 `reason` 说为什么。
        public let stats: NotificationPreview.Stats?
        public let reason: Reason?
    }

    public static func previewResult(id: String, in data: Data) -> PreviewResult? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let r = (root["results"] as? [[String: Any]])?.last(where: { $0["id"] as? String == id }) else { return nil }
        let ok = r["ok"] as? Bool ?? false
        let stats = ok ? (r["digest"] as? [String: Any]).map(NotificationPreview.Stats.init(digestJSON:)) : nil
        return PreviewResult(id: id, title: r["title"] as? String ?? "", stats: stats,
                             reason: stats == nil ? PreviewResult.Reason(rawValue: r["reason"] as? String ?? "") ?? .fetch : nil)
    }

    /// 预览要取账号全部歌手(判新听的歌手),第一次一二十秒;等这么久还没有结果就当没取到。
    public static let previewTimeout: TimeInterval = 60

    /// 引擎每 0.5 秒看一次请求;Telegram 一次推送走代理回退最长十几秒,排过版的被拒还要再推一次纯文本,前后能到三十秒。
    /// 过了这么久还没有结果就当引擎没接手(没在跑)。
    public static let timeout: TimeInterval = 45
}
