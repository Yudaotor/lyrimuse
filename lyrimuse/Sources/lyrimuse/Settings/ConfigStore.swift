import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "config-store")

// 推送提醒支持的平台——绝大多数都是"群机器人 webhook"这个模子,一个 URL、POST
// 一份 JSON 就能收到消息(Server酱是个例外,走表单编码,见 lyrimuse-engine/notify.go 顶部
// 注释),Lyrimuse 这边只管选平台+填 webhook 地址,不关心具体协议。rawValue
// 必须跟引擎侧的平台字符串常量(platformBark/platformDingtalk/platformWecom/
// platformDiscord/platformFeishu/platformServerChan/platformTelegram/platformSlack/platformNtfy/platformWebhook)
// 逐字对应——这是两侧通过同一份 config.json 交换的字符串,不是各自随便定义的展示文案。
public enum NotificationPlatform: String, CaseIterable, Identifiable, Codable {
    case bark, dingtalk, wecom, discord, feishu, serverchan, telegram, slack, ntfy, webhook
    public var id: Self { self }

    /// 添加渠道时的平台排列:不分组,中文用户国内平台在前(规则见 `NotificationPlatformRegion`);通用 Webhook 不在里面。
    static var displayOrder: [NotificationPlatform] {
        let chineseFirst = LyricsSourceRegion.prefersChineseSources(
            appLanguageOverride: L10n.languageOverride, preferredLanguage: Locale.preferredLanguages.first)
        return NotificationPlatformRegion.displayOrder(chineseFirst: chineseFirst)
            .compactMap(NotificationPlatform.init(rawValue:))
    }

    public var displayName: String {
        switch self {
        case .bark: return "Bark"
        case .dingtalk: return L10n.t("钉钉")
        case .wecom: return L10n.t("企业微信")
        case .discord: return "Discord"
        case .feishu: return L10n.t("飞书")
        case .serverchan: return L10n.t("Server酱")
        case .telegram: return "Telegram"
        case .slack: return "Slack"
        case .ntfy: return "ntfy"
        case .webhook: return L10n.t("通用 Webhook")
        }
    }

    /// 指向平台时的悬浮说明:这是什么、消息会到哪里。怎么拿地址在 `setupGuide`。
    public var summary: String {
        switch self {
        case .bark: return L10n.t("iPhone 推送 App：安装后首页即显示专属地址，报告将直接推送到 iPhone。免费且开源")
        case .feishu: return L10n.t("飞书群自定义机器人：报告将发送到群聊")
        case .dingtalk: return L10n.t("钉钉群自定义机器人：报告将发送到群聊。机器人需设置关键词或加签")
        case .wecom: return L10n.t("企业微信群机器人：报告将发送到群聊，粘贴地址即可使用")
        case .serverchan: return L10n.t("将消息转发到微信的服务：使用微信扫码登录获取 SendKey，报告将显示在微信「方糖」服务号中")
        case .telegram: return L10n.t("Telegram 机器人：通过 @BotFather 创建，报告将发送给你本人或你所在的群组")
        case .discord: return L10n.t("Discord 频道 Webhook：报告将发送到你服务器中的指定频道")
        case .slack: return L10n.t("Slack Incoming Webhook：报告将发送到工作区中的指定频道")
        case .ntfy: return L10n.t("开源推送服务：在手机或电脑上安装 ntfy 并订阅主题即可接收，无需注册，也可自建服务器")
        case .webhook: return L10n.t("向指定地址 POST 一段 JSON，适用于对接 Home Assistant、n8n 或自建服务")
        }
    }

    /// 平台图标的资源名(`Resources/<名字>.png`,见 `NotificationPlatformBadge`);通用 Webhook 不是哪一家,用花括号符号,为 nil。
    /// 来路:飞书、钉钉、企业微信、Bark 取本机 App 自己的图标(按 636 导出、裁掉图标网格的透明边铺满 512,同 SpotifyIcon.png
    /// 的做法);Telegram、Discord、Slack、ntfy 是 Simple Icons(CC0)的矢量,品牌色铺底、白色标志占 62% 宽;Server酱取它
    /// 官网 sct.ftqq.com 的站点图标(300 → 512)。
    public var iconResource: String? {
        switch self {
        case .bark: return "BarkIcon"
        case .feishu: return "FeishuIcon"
        case .dingtalk: return "DingTalkIcon"
        case .wecom: return "WeComIcon"
        case .serverchan: return "ServerChanIcon"
        case .telegram: return "TelegramIcon"
        case .discord: return "DiscordIcon"
        case .slack: return "SlackIcon"
        case .ntfy: return "NtfyIcon"
        case .webhook: return nil
        }
    }

    // 地址输入框前面那个标题。Telegram 这一栏填的是机器人 Token,Bark / Server酱 是带 Key 的推送地址,
    // ntfy 是订阅时的主题地址,统一叫「Webhook 地址」会让人不知道该填什么。
    public var fieldLabel: String {
        switch self {
        case .bark, .serverchan: return L10n.t("推送地址")
        case .telegram: return L10n.t("机器人 Token")
        case .ntfy: return L10n.t("主题地址")
        case .dingtalk, .wecom, .discord, .feishu, .slack, .webhook: return L10n.t("Webhook 地址")
        }
    }

    /// 密钥那一栏的标题和说明;这个平台用不着密钥时为 nil。都是可选的。
    public var secretField: (label: String, note: String)? {
        switch self {
        case .dingtalk:
            return (L10n.t("加签密钥（可选）"), L10n.t("仅在机器人安全设置选择「加签」时需要填写，留空则按未加签处理"))
        case .feishu:
            return (L10n.t("签名密钥（可选）"), L10n.t("仅在机器人安全设置开启「签名校验」时需要填写，未开启时也能正常接收消息"))
        case .ntfy:
            return (L10n.t("访问令牌（可选）"), L10n.t("主题设置了访问控制时填写：以 tk_ 开头的令牌，或「用户名:密码」"))
        case .webhook:
            return (L10n.t("签名密钥（可选）"), L10n.t("填写后，每次请求将附带 X-Lyrimuse-Signature: sha256=…（使用此密钥对请求体计算的 HMAC-SHA256），接收端可据此校验来源"))
        case .bark, .wecom, .discord, .serverchan, .telegram, .slack:
            return nil
        }
    }

    // Picker 旁边的说明+webhook 地址输入框的 placeholder——各平台的地址形状完全不同,
    // 光看"webhook 地址"这四个字不够,给个例子避免用户填错格式。
    public var urlPlaceholder: String {
        switch self {
        case .bark: return L10n.t("https://api.day.app/你的Key")
        case .dingtalk: return "https://oapi.dingtalk.com/robot/send?access_token=..."
        case .wecom: return "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=..."
        case .discord: return "https://discord.com/api/webhooks/..."
        case .feishu: return "https://open.feishu.cn/open-apis/bot/v2/hook/..."
        case .serverchan: return L10n.t("https://sctapi.ftqq.com/你的SendKey.send")
        case .telegram: return L10n.t("机器人 Token，形如 123456789:AAH…")
        case .slack: return "https://hooks.slack.com/services/..."
        case .ntfy: return L10n.t("https://ntfy.sh/你的主题")
        case .webhook: return "https://example.com/hooks/lyrimuse"
        }
    }

    // 每个平台"怎么拿到 webhook 地址"的操作指引,配一个 HelpButton 用——写成两三句够
    // 照做的步骤,不追求跟官方文档一样全,细节交给下面的 docURL。
    public var setupGuide: String {
        switch self {
        case .bark:
            return L10n.t("在 iPhone 上安装 Bark App，首页即显示专属推送地址，拷贝后粘贴到此处即可，无需额外设置")
        case .dingtalk:
            return L10n.t("在钉钉群中：群设置 → 智能群助手 → 添加机器人 → 自定义，创建后拷贝 Webhook 地址。安全设置建议选择「加签」，并将生成的密钥填入下方的「加签密钥」")
        case .wecom:
            return L10n.t("在企业微信群中：群设置 → 群机器人 → 添加机器人，创建后拷贝 Webhook 地址，无需额外的签名设置")
        case .discord:
            return L10n.t("服务器设置 → 整合（Integrations） → Webhook → 新建 Webhook，选择要发送到的频道后拷贝 Webhook URL")
        case .feishu:
            return L10n.t("在飞书群中：设置 → 群机器人 → 添加机器人 → 自定义机器人，创建后拷贝 Webhook 地址。如需额外校验，可开启「签名校验」，并将密钥填入下方的「签名密钥」")
        case .serverchan:
            return L10n.t("打开 sct.ftqq.com，使用微信扫码登录，首页将显示 SendKey。完整地址为 https://sctapi.ftqq.com/你的SendKey.send，请将完整地址填入上方")
        case .telegram:
            return L10n.t("在 Telegram 中向 @BotFather 发送 /newbot 创建机器人，并将获得的 Token 填入「机器人 Token」。然后向机器人发送任意消息，在浏览器中打开 https://api.telegram.org/bot你的Token/getUpdates，chat 下的 id 即为 Chat ID")
        case .slack:
            return L10n.t("在 api.slack.com/apps 新建应用（From scratch）并选择工作区，开启 Incoming Webhooks，点按「Add New Webhook」并选择目标频道，授权后拷贝 Webhook URL")
        case .ntfy:
            return L10n.t("在手机或电脑上安装 ntfy，订阅一个他人难以猜到的主题名，然后将主题地址（如 https://ntfy.sh/你的主题）填入此处。使用自建服务器时填写其地址")
        case .webhook:
            return L10n.t("Lyrimuse 将向此地址 POST 一段 JSON，包含 app、event（如 weekly_digest）、title、body、sent_at，适用于对接 Home Assistant、n8n 或自建服务")
        }
    }

    /// 通用 Webhook 没有官方文档,收的字段在 setupGuide 里写全了。
    public var setupDocURL: URL? {
        switch self {
        case .bark: return URL(string: "https://bark.day.app/")!
        case .dingtalk: return URL(string: "https://open.dingtalk.com/document/group/custom-robot-access")!
        case .wecom: return URL(string: "https://developer.work.weixin.qq.com/document/path/91770")!
        case .discord: return URL(string: "https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks")!
        case .feishu: return URL(string: "https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot?lang=zh-CN")!
        case .serverchan: return URL(string: "https://sct.ftqq.com/")!
        case .telegram: return URL(string: "https://core.telegram.org/bots/tutorial")!
        case .slack: return URL(string: "https://api.slack.com/messaging/webhooks")!
        case .ntfy: return URL(string: "https://docs.ntfy.sh/subscribe/phone/")!
        case .webhook: return nil
        }
    }
}

// "推送账号"tab 管理引擎推送目的地凭据的数据层——读写引擎自己的
// ~/.config/lyrimuse/config.json(见 lyrimuse-engine/config.go 的 `config`
// struct)。照抄 EnrichCacheStore.swift 的模式:用 JSONSerialization 读写整份原始
// 字典而不是用 Codable 精确建模——这份文件里还有 api_root 这类 UI 不管的字段,整字典读写
// 才能保证保存时原样保留它们,不会被这里没声明的字段悄悄丢掉。
//
// 文本字段不走 Toggle 那种"改了立刻存盘+重启"的即时保存——不能每敲一个字符就重启一次
// 引擎,所以持久化是一个显式调用点。
//
// 触发者**不再是**"底部保存栏"(那个 UI 已经不存在了):现在是
// AccountLinkingTab 的 1.2 秒输入防抖自动保存(`performAutoSave` → `save()`),
// 界面上只剩一个只读的 `autosaveStatusBar` 显示保存状态。
//
// isDirty 判定专门跟"已保存快照"比较,不看别的——如果直接读 @Published 字段是否非空,
// 用户刚敲进去几个字符、还没点保存,状态就会被误判成"已配置/生效中",这里刻意避开
// 这个坑。
//
// 读写字节这一层走 Core 的 `JSONConfigDocument`:读盘分**三态**(不存在 / 正常 / 损坏),
// 损坏时 `persistFile()` 拒绝保存、`loadFailure` 亮起(设置窗口顶部横幅给出口);写盘成功后镜像才更新。
// 为什么必须分三态、原来那版会怎么把 14 个空串覆盖上去,见 `JSONConfigDocument` 头注。这里只剩字段映射。
@MainActor
public final class ConfigStore: ObservableObject {
    public static let shared = ConfigStore()

    @Published public var listenbrainzToken = ""
    @Published public var listenbrainzUser = ""
    @Published public var stateRelayURL = ""
    @Published public var stateRelayToken = ""
    @Published public var lastfmUser = ""
    // 合并之前独立存在的只读 API Key——UI 上已经不再单独收这个字段(桥接
    // 现在复用下面的 lastfmScrobbleAPIKey),这里保留只是为了老用户已经存盘的值不会
    // 在读写这份 JSON 时被悄悄丢掉,见 lastfmBridgeMissingHint() 的兜底判断。
    @Published public var lastfmAPIKey = ""
    @Published public var lastfmScrobbleAPIKey = ""
    @Published public var lastfmScrobbleSecret = ""
    @Published public var lastfmScrobbleSessionKey = ""
    // 只在"连接 Last.fm"成功那一刻才会有值(来自 auth.getsession 返回的 session.name)——
    // 持久化下来是为了 App 重启后"已连接:xxx"这句话不会退化成不带用户名的泛化文案
    // (LastfmConnectController 的 state 是内存态,重启即丢)。
    @Published public var lastfmScrobbleUsername = ""
    /// 推送提醒的渠道(`notification_channels`,见 Core `NotificationChannel`)。旧版的单渠道字段在 load 时换成这个列表,
    /// 旧键留在文件里不删、也不再写。
    @Published public var notificationChannels: [NotificationChannel] = []

    @Published public private(set) var lastError: String?
    /// 同 FeatureSettingsStore.pendingUntilServiceEnabled:落盘成功、因后台服务被主动停用而没重启。
    @Published public private(set) var pendingUntilServiceEnabled = false
    /// 启动时 config.json 判定为**损坏**(文件在、但读不懂)的原因;nil = 正常或文件不存在。非 nil 期间
    /// `persistFile()` 一律拒绝,设置窗口顶部的 `ConfigFileDamageBanner` 据此显示告示与出口。
    @Published public private(set) var loadFailure: String?

    static let fileURL = LyrimusePaths.configFile("config.json")

    /// 磁盘上那份对象的内存镜像 + 三态(见 Core `JSONConfigDocument`)。JSON → 字段的映射在 load,
    /// 字段 → JSON 在 persistFile,这里只管字节与字典。
    private var document = JSONConfigDocument(url: ConfigStore.fileURL)

    /// 诊断导出用:磁盘上那份文件的三态。
    public var fileState: JSONConfigDocument.LoadState { document.state }

    private struct Snapshot: Equatable {
        var listenbrainzToken, listenbrainzUser: String
        var stateRelayURL, stateRelayToken: String
        var lastfmUser, lastfmAPIKey: String
        var lastfmScrobbleAPIKey, lastfmScrobbleSecret, lastfmScrobbleSessionKey, lastfmScrobbleUsername: String
        var notificationChannels: [NotificationChannel]
    }
    private var savedSnapshot = Snapshot(
        listenbrainzToken: "", listenbrainzUser: "", stateRelayURL: "", stateRelayToken: "",
        lastfmUser: "", lastfmAPIKey: "", lastfmScrobbleAPIKey: "", lastfmScrobbleSecret: "",
        lastfmScrobbleSessionKey: "", lastfmScrobbleUsername: "",
        notificationChannels: []
    )
    private var currentSnapshot: Snapshot {
        Snapshot(
            listenbrainzToken: listenbrainzToken, listenbrainzUser: listenbrainzUser,
            stateRelayURL: stateRelayURL, stateRelayToken: stateRelayToken,
            lastfmUser: lastfmUser, lastfmAPIKey: lastfmAPIKey,
            lastfmScrobbleAPIKey: lastfmScrobbleAPIKey, lastfmScrobbleSecret: lastfmScrobbleSecret,
            lastfmScrobbleSessionKey: lastfmScrobbleSessionKey, lastfmScrobbleUsername: lastfmScrobbleUsername,
            notificationChannels: notificationChannels
        )
    }
    public var isDirty: Bool { currentSnapshot != savedSnapshot }

    /// 给诊断导出**脱敏**用:字段名 → 该字段当前的值。
    ///
    /// 这批值只有一个正当用途:交给 `LogRedactor` 去把它们从日志正文里**抹掉**。
    /// 任何把它们写进报告、日志或界面的用法都直接违反 `DiagnosticsExporter` 开头那条
    /// 硬约束(诊断文件会被贴进公开 issue)。字段名本身不敏感,打码后会以
    /// `<redacted:lastfmScrobbleAPIKey>` 的形式留在报告里,方便排查时知道那里原本是哪一项。
    ///
    /// 刻意读 `currentSnapshot` 而不是 `savedSnapshot`:用户可能刚在界面上粘了一把新
    /// 密钥还没点保存,而引擎侧的日志里已经可能有它 —— 脱敏要按"可能出现过的值"
    /// 取全集,宁可多抹一个。
    ///
    /// 不只是凭据:**用户名**(lastfmUser / lastfmScrobbleUsername / listenbrainzUser)和
    /// **stateRelayURL** 也收。用户名把诊断包连到一个公开的收听主页上;网页中继地址是用户自己的
    /// 域名,同样认得出是谁。引擎日志里两样都常见(Last.fm 请求失败时整条 URL 带着 `user=…`,
    /// 中继每次写入都打地址),而诊断包是要贴进公开 issue 的。中继的主机名另收一项:请求汇总那类日志行
    /// 只带主机名,整条地址替换不到它们。打码后留着字段名(`<redacted:lastfmUser>`),排查时仍看得出
    /// 那里原本是哪一项。
    /// 见 15 章决策 70。推送渠道的地址一直整条收 —— Bark/Server酱/飞书的 webhook 地址里
    /// 凭据就长在 URL 自己身上,整条即凭据。
    public var secretsForRedaction: [String: String] {
        var out = [
            "listenbrainzToken": listenbrainzToken,
            "stateRelayToken": stateRelayToken,
            "lastfmAPIKey": lastfmAPIKey,
            "lastfmScrobbleAPIKey": lastfmScrobbleAPIKey,
            "lastfmScrobbleSecret": lastfmScrobbleSecret,
            "lastfmScrobbleSessionKey": lastfmScrobbleSessionKey,
            "lastfmUser": lastfmUser,
            "lastfmScrobbleUsername": lastfmScrobbleUsername,
            "listenbrainzUser": listenbrainzUser,
            "stateRelayURL": stateRelayURL,
            "stateRelayHost": URL(string: stateRelayURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "",
        ]
        for (i, ch) in notificationChannels.enumerated() {
            out["notificationChannel\(i).url"] = ch.url
            out["notificationChannel\(i).secret"] = ch.secret
        }
        // 旧版的单渠道字段还留在文件里(见 notificationChannels),引擎早先的日志里可能有它们。
        for (key, value) in document.raw where Self.legacyPushSecretKeys.contains(key) {
            if let value = value as? String { out["legacy.\(key)"] = value }
            if let urls = value as? [String: String] {
                for (platform, url) in urls { out["legacy.\(key).\(platform)"] = url }
            }
        }
        return out.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static let legacyPushSecretKeys: Set<String> = [
        "bark_url", "notification_webhook_urls", "dingtalk_sign_secret", "feishu_sign_secret",
    ]

    // 以下几个只读判断专给"推送账号"tab 的状态徽标用——刻意读 savedSnapshot(已保存的
    // 值)而不是当前 @Published 字段,道理跟 isDirty 一样:用户刚敲了几个字符还没点
    // 保存,不该被判定成"已配置"。返回值是具体缺哪个字段的提示文案,全部配置齐全时
    // 返回 nil。
    /// 能不能**往** ListenBrainz 提交收听。提交只需要 token,所以这里只看 token。
    public var isListenBrainzConfigured: Bool { !savedSnapshot.listenbrainzToken.isEmpty }

    /// 能不能**从** ListenBrainz 读回统计(听歌报告的数据源、Last.fm 桥接的去重比对)。
    ///
    /// 读统计必须带用户名 —— 引擎侧 daily.go / weekly.go 是把它当 API 参数传进
    /// `listenbrainzDigestStats(…, p.cfg.User, …)` 的,没有用户名根本无从查起。所以它跟
    /// "能提交"是两个不同的条件,不能共用 isListenBrainzConfigured。
    ///
    /// 在此之前 Swift 全程只看 token,而 Go 三处(weekly.go:200 /
    /// daily.go:82 / poller.go:711)都要求 user 和 token 同时非空 —— 于是一个只填了 token
    /// 的用户(UI 上用户名那栏当时还写着"选填"),在设置页看到开关能开、数据源显示
    /// ListenBrainz,而 daemon 侧周报、日报、桥接三件事全部静默跳过,没有任何提示。
    public var isListenBrainzReadable: Bool {
        !savedSnapshot.listenbrainzToken.isEmpty && !savedSnapshot.listenbrainzUser.isEmpty
    }

    // 两句 hint 都带"（可选）"——网页展示页的"正在播放"/历史这两项基础功能光配
    // ListenBrainz 就够用,state-worker 完全是可选的加分项(留言墙/表情反应/访客计数/
    // Top10 歌手这几个模块才真的依赖它),不该让人误以为不配它是"没配置完"。
    /// 网页推送一个字段都没填 —— 用户压根没碰过这个可选功能,不是"配错了"。
    /// 徽标据此决定不显示任何东西(见 DestinationStatus.notConfigured)。
    public var isStateRelayUntouched: Bool {
        savedSnapshot.stateRelayURL.isEmpty && savedSnapshot.stateRelayToken.isEmpty
    }

    public func stateRelayMissingHint() -> String? {
        if savedSnapshot.stateRelayURL.isEmpty { return L10n.t("未填写服务地址（可选）") }
        if savedSnapshot.stateRelayToken.isEmpty { return L10n.t("未填写访问令牌（可选）") }
        return nil
    }

    // 合并之前,桥接单独要求一把只读 API Key(lastfmAPIKey);合并之后桥接
    // 复用"账号信息"里那一套 API Key(lastfmScrobbleAPIKey——Last.fm 的只读接口不需要
    // 签名,同一对凭据够用),这里两个字段任一非空都算满足,老用户已经填过的 lastfmAPIKey
    // 继续有效,不强制重新操作。
    //
    // 故意只判断 Last.fm 侧凭据,不管 ListenBrainz——这个函数同时被两处调用:
    // ①AccountLinkingTab 判断"桥接读取"是否真的在跑(那边额外自己叠一层
    // isListenBrainzConfigured,见 destinationStatus 的 bridgeOK 注释);②听歌报告的
    // resolvedDigestSource/引擎侧 weekly.go 判断"Last.fm 能不能当数据源",这个
    // 场景完全不需要 ListenBrainz。两个用途混进同一个判断会互相伤害,所以这里保持
    // 语义狭窄,"要不要额外查 ListenBrainz"交给各自调用点自己决定。
    public func lastfmBridgeMissingHint() -> String? {
        // 用户名输入框已删(见 AccountLinkingTab.lastfmFields 注释)——用户名
        // 和 API Key 现在都来自"连接 Last.fm"向导(授权成功自动回填),所以两种缺失对
        // 用户是同一个动作:去连接。原来还有一个 lastfmMirrorMissingHint 给写入开关做
        // 前置校验,新设计里开关自己就是配置入口,那个函数一并删了。
        if savedSnapshot.lastfmUser.isEmpty
            || (savedSnapshot.lastfmScrobbleAPIKey.isEmpty && savedSnapshot.lastfmAPIKey.isEmpty) {
            return L10n.t("尚未连接 Last.fm 账号")
        }
        return nil
    }

    /// 有没有能推的渠道(启用着、填齐了);没有时返回缺什么的提示:有启用着的、但都没填齐(比如 Telegram 没填
    /// Chat ID)报「信息不完整」,一个都没启用才报「均已停用」。见 15 章决策 69。
    public func pushMissingHint() -> String? {
        let saved = savedSnapshot.notificationChannels
        if saved.isEmpty { return L10n.t("尚未添加推送渠道") }
        if saved.contains(where: { $0.enabled && $0.isComplete }) { return nil }
        if saved.contains(where: { $0.enabled }) { return L10n.t("推送渠道信息不完整") }
        return L10n.t("推送渠道均已停用")
    }

    /// 已保存的、启用着且填齐了的渠道。
    public var activeNotificationChannels: [NotificationChannel] {
        savedSnapshot.notificationChannels.filter { $0.enabled && $0.isComplete }
    }

    private init() {
        load()
    }

    public func load() {
        document = JSONConfigDocument.load(url: Self.fileURL)
        switch document.state {
        case .loaded, .missing:
            // 不存在 = 全新机器 / 引擎还没跑过:字段留空,首次保存会创建文件。
            loadFailure = nil
        case .corrupt(let reason):
            // 文件在但读不懂。字段照样留空只是为了界面不崩;**保存被拒**(见 persistFile),直到用户修好
            // 文件或在横幅上放弃它。原来这里把它跟「不存在」混成一回事、注释还写着「理论上不会发生」——
            // 后果是之后任何一次保存都用 14 个空串覆盖原文件。
            loadFailure = reason
            logger.error("config.json is unusable, saves refused until it is fixed or discarded: \(reason, privacy: .public)")
        }
        let raw = document.raw
        listenbrainzToken = raw["listenbrainz_token"] as? String ?? ""
        listenbrainzUser = raw["listenbrainz_user"] as? String ?? ""
        stateRelayURL = raw["state_relay_url"] as? String ?? ""
        stateRelayToken = raw["state_relay_token"] as? String ?? ""
        lastfmUser = raw["lastfm_user"] as? String ?? ""
        lastfmAPIKey = raw["lastfm_api_key"] as? String ?? ""
        lastfmScrobbleAPIKey = raw["lastfm_scrobble_api_key"] as? String ?? ""
        lastfmScrobbleSecret = raw["lastfm_scrobble_secret"] as? String ?? ""
        lastfmScrobbleSessionKey = raw["lastfm_scrobble_session_key"] as? String ?? ""
        lastfmScrobbleUsername = raw["lastfm_scrobble_username"] as? String ?? ""
        // 还没有渠道列表的旧配置:换成渠道列表。快照按换好的算(没有要保存的改动),下一次保存时才写进文件;
        // 那之前引擎照样读旧字段,推的是同一个渠道。
        notificationChannels = NotificationChannel.list(fromConfig: raw) ?? NotificationChannel.migrated(fromLegacy: raw)
        savedSnapshot = currentSnapshot
    }

    // 只把当前字段写回磁盘,不重启引擎。抛出的错误里带具体原因,调用方决定怎么
    // 呈现给用户。
    //
    // 原注释说"底部保存栏会先把两个 store 都写完盘、再统一重启一次" —— **那个保存栏
    // 已经不存在了**,而且全仓 grep 确认本方法**只被自己的 save() 调用**,没有任何外部
    // 协调者。"只重启一次"这件事现在由 EngineRestartCoordinator
    // 负责——两个 store 的 save() 都走它,它去抖合并。
    public func persistFile() throws {
        // 凭据和地址落盘前去掉首尾空白:粘贴进来的 token 常带尾随空格 / 换行,界面上的校验去掉了空白所以显示
        // 「已连接」,引擎却原样拼进请求头。引擎读配置时也会再去一次(config.go trimCredentials)。
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let fields: [String: Any] = [
            "listenbrainz_token": t(listenbrainzToken),
            "listenbrainz_user": t(listenbrainzUser),
            "state_relay_url": t(stateRelayURL),
            "state_relay_token": t(stateRelayToken),
            "lastfm_user": t(lastfmUser),
            "lastfm_api_key": t(lastfmAPIKey),
            "lastfm_scrobble_api_key": t(lastfmScrobbleAPIKey),
            "lastfm_scrobble_secret": t(lastfmScrobbleSecret),
            "lastfm_scrobble_session_key": t(lastfmScrobbleSessionKey),
            "lastfm_scrobble_username": t(lastfmScrobbleUsername),
            // 删光了也写 []:没有这个键时引擎会退回去读旧的单渠道字段。
            "notification_channels": notificationChannels.map(\.jsonObject),
        ]
        do {
            // 合并进磁盘镜像(api_root / bundle_ids 这些 UI 不管的字段原样保留)→ 原子写 + 0600(这份就是
            // 凭据本体)→ 成功后镜像才更新。磁盘上那份判定为损坏时这里直接抛,一个字节不碰。
            try document.save(fields: fields, secure: true)
        } catch JSONConfigDocument.Failure.refusedCorruptFile {
            throw ConfigFileSaveError.refusedCorruptFile
        } catch JSONConfigDocument.Failure.notSerializable {
            throw ConfigFileSaveError.notSerializable
        }
    }

    /// 横幅上的「放弃坏文件并重建」:把损坏的 config.json 挪到旁边(`config.json.corrupt-<时间>`,不删 ——
    /// 里面可能还有能手工抢救的凭据),然后用当前内存里的值(损坏时全是空)重建并保存。
    @discardableResult
    public func discardCorruptFileAndSave() async -> Bool {
        do {
            if let moved = try document.quarantineCorruptFile() {
                logger.notice("corrupt config.json moved aside as \(moved.lastPathComponent, privacy: .public)")
            }
        } catch {
            lastError = String(format: L10n.t("无法移动损坏的配置文件：%@"), error.localizedDescription)
            logger.error("quarantine failed: \(String(describing: error), privacy: .public)")
            return false
        }
        loadFailure = nil
        return await save()
    }

    // 保存成功后调用,把"已保存快照"推进到当前值——之后 isDirty 会重新变 false,状态徽标
    // 才会认为这些字段已经生效。
    public func commitSnapshot() {
        savedSnapshot = currentSnapshot
    }

    /// 设置窗口底部状态条的「关闭」:清掉上一次保存的失败原因 / 「服务已停用」提示。不改任何数据。
    public func clearApplyStatus() {
        lastError = nil
        pendingUntilServiceEnabled = false
    }

    // 保存入口:持久化 + 重启引擎 + 提交快照,一步到位。
    //
    // 原注释说这是"给不经过底部保存栏的场景用"、"目前只有连接 Last.fm 会调用" ——
    // 两句都已过时。保存栏没了,本方法现在是**唯一**的保存路径,
    // 四个调用点:AccountLinkingTab 的输入自动保存(1480)与账号切换兜底(1062)、
    // LastfmAuthFlow 授权成功那一刻(220)、以及 AppDelegate 退出前的兜底存盘(377,
    // 走 .terminateLater 等这里返回才放行,所以重启去抖不会被进程退出打断)。
    @discardableResult
    public func save() async -> Bool {
        do {
            try persistFile()
        } catch ConfigFileSaveError.refusedCorruptFile {
            // 不是「写失败」,是刻意不写:文案直说原因,横幅里有出口。
            lastError = ConfigFileSaveError.refusedCorruptFile.errorDescription
            logger.notice("save refused: config.json on disk is corrupt")
            return false
        } catch {
            lastError = String(format: L10n.t("写入 config.json 失败：%@"), error.localizedDescription)
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // 不重启引擎:它按 mtime 自己热重读 config.json(configreload.go)。见 EngineRestartPolicy 头注。
        lastError = nil
        // 同 FeatureSettingsStore.save():后台服务被停用时下次启用读盘生效,状态条提示「服务已停用」。
        // 看开关、不问 launchctl,理由见那边。
        pendingUntilServiceEnabled = !AppSettings.shared.engineServiceEnabled
        commitSnapshot()
        return true
    }
}

/// 两个共享配置文件 Store 保存被拒的两种情况。`save()` 把文案放进 lastError;AppDelegate 那条退出兜底只看
/// 返回值,不展示。「拒绝」和「写失败」刻意分开:前者磁盘一个字节没碰、是保护动作,文案不该说成「失败」。
public enum ConfigFileSaveError: LocalizedError {
    /// 磁盘上那份文件启动时判定为损坏,拒绝覆盖(见各 Store 的 loadFailure 与 Core JSONConfigDocument)。
    case refusedCorruptFile
    /// 内部字典序列化不了(编程错误,不是用户数据的问题)。
    case notSerializable

    public var errorDescription: String? {
        switch self {
        case .refusedCorruptFile: return L10n.t("配置文件无法解析，为避免覆盖已取消保存")
        case .notSerializable: return L10n.t("内部数据不是有效的 JSON，已取消保存")
        }
    }
}
