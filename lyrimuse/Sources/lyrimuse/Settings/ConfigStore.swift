import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "config-store")

// 推送提醒目前支持的平台——绝大多数都是"群机器人 webhook"这个模子,一个 URL、POST
// 一份 JSON 就能收到消息(Server酱是个例外,走表单编码,见 collector/notify.go 顶部
// 注释),Lyrimuse 这边只管选平台+填 webhook 地址,不关心具体协议。rawValue
// 必须跟 collector 侧的平台字符串常量(platformBark/platformDingtalk/platformWecom/
// platformDiscord/platformFeishu/platformServerChan)逐字对应——这是两侧通过同一份
// config.json 交换的字符串,不是各自随便定义的展示文案。
public enum NotificationPlatform: String, CaseIterable, Identifiable, Codable {
    case bark, dingtalk, wecom, discord, feishu, serverchan
    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .bark: return "Bark"
        case .dingtalk: return L10n.t("钉钉")
        case .wecom: return L10n.t("企业微信")
        case .discord: return "Discord"
        case .feishu: return L10n.t("飞书")
        case .serverchan: return L10n.t("Server酱")
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
        }
    }

    // 每个平台"怎么拿到 webhook 地址"的操作指引,配一个 HelpButton 用——写成两三句够
    // 照做的步骤,不追求跟官方文档一样全,细节交给下面的 docURL。
    public var setupGuide: String {
        switch self {
        case .bark:
            return L10n.t("在 iPhone 上安装 Bark App，首页显示的就是你的专属推送地址，复制粘贴过来即可，不需要额外设置")
        case .dingtalk:
            return L10n.t("在钉钉群里：群设置 → 智能群助手 → 添加机器人 → 自定义，创建后复制 Webhook 地址。安全设置建议选「加签」，把生成的密钥填进下面的「加签密钥」")
        case .wecom:
            return L10n.t("在企业微信群里：群设置 → 群机器人 → 添加机器人，创建后复制 Webhook 地址，不需要额外的签名设置")
        case .discord:
            return L10n.t("服务器设置 → 整合(Integrations) → Webhook → 新建 Webhook，选好要发到的频道后复制 Webhook URL")
        case .feishu:
            return L10n.t("在飞书群里：设置 → 群机器人 → 添加机器人 → 自定义机器人，创建后复制 Webhook 地址。想加一层校验可以开启「签名校验」，把密钥填进下面的「签名密钥」")
        case .serverchan:
            return L10n.t("打开 sct.ftqq.com，用微信扫码登录，首页会显示你的 SendKey，完整地址是 https://sctapi.ftqq.com/你的SendKey.send，把这一整串填进上面")
        }
    }

    public var setupDocURL: URL {
        switch self {
        case .bark: return URL(string: "https://bark.day.app/")!
        case .dingtalk: return URL(string: "https://open.dingtalk.com/document/group/custom-robot-access")!
        case .wecom: return URL(string: "https://developer.work.weixin.qq.com/document/path/91770")!
        case .discord: return URL(string: "https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks")!
        case .feishu: return URL(string: "https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot?lang=zh-CN")!
        case .serverchan: return URL(string: "https://sct.ftqq.com/")!
        }
    }
}

// "推送账号"tab 管理 collector 推送目的地凭据的数据层——读写 collector 自己的
// ~/.config/lyrimuse/config.json(见 collector/config.go 的 `config`
// struct)。照抄 EnrichCacheStore.swift 的模式:用 JSONSerialization 读写整份原始
// 字典而不是用 Codable 精确建模——这份文件里还有 api_root/media_control_path/
// bundle_ids 这几个这次 UI 不管的字段,整字典读写才能保证保存时原样保留它们,不会
// 被这里没声明的字段悄悄丢掉。
//
// 文本字段不走 Toggle 那种"改了立刻存盘+重启"的即时保存——不能每敲一个字符就重启一次
// collector,所以持久化是一个显式调用点,由"推送账号"tab 底部的保存栏触发。
//
// isDirty 判定专门跟"已保存快照"比较,不看别的——如果直接读 @Published 字段是否非空,
// 用户刚敲进去几个字符、还没点保存,状态就会被误判成"已配置/生效中",这里刻意避开
// 这个坑。
@MainActor
public final class ConfigStore: ObservableObject {
    public static let shared = ConfigStore()

    @Published public var listenbrainzToken = ""
    @Published public var listenbrainzUser = ""
    @Published public var stateRelayURL = ""
    @Published public var stateRelayToken = ""
    @Published public var lastfmUser = ""
    // 2026-07-29 合并之前独立存在的只读 API Key——UI 上已经不再单独收这个字段(桥接
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
    @Published public var notificationPlatform: NotificationPlatform = .bark
    @Published public var notificationWebhookURL = ""
    // 只有对应平台的机器人开了"加签"安全设置时才需要填,留空则按未加签处理——钉钉/
    // 飞书两个平台的签名算法不同(见 collector/notify.go),分开两个字段存,切换平台
    // 不会互相污染。
    @Published public var dingtalkSignSecret = ""
    @Published public var feishuSignSecret = ""

    @Published public private(set) var lastError: String?

    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/config.json")

    private var raw: [String: Any] = [:]

    private struct Snapshot: Equatable {
        var listenbrainzToken, listenbrainzUser: String
        var stateRelayURL, stateRelayToken: String
        var lastfmUser, lastfmAPIKey: String
        var lastfmScrobbleAPIKey, lastfmScrobbleSecret, lastfmScrobbleSessionKey, lastfmScrobbleUsername: String
        var notificationPlatform: NotificationPlatform
        var notificationWebhookURL: String
        var dingtalkSignSecret: String
        var feishuSignSecret: String
    }
    private var savedSnapshot = Snapshot(
        listenbrainzToken: "", listenbrainzUser: "", stateRelayURL: "", stateRelayToken: "",
        lastfmUser: "", lastfmAPIKey: "", lastfmScrobbleAPIKey: "", lastfmScrobbleSecret: "",
        lastfmScrobbleSessionKey: "", lastfmScrobbleUsername: "",
        notificationPlatform: .bark, notificationWebhookURL: "", dingtalkSignSecret: "", feishuSignSecret: ""
    )
    private var currentSnapshot: Snapshot {
        Snapshot(
            listenbrainzToken: listenbrainzToken, listenbrainzUser: listenbrainzUser,
            stateRelayURL: stateRelayURL, stateRelayToken: stateRelayToken,
            lastfmUser: lastfmUser, lastfmAPIKey: lastfmAPIKey,
            lastfmScrobbleAPIKey: lastfmScrobbleAPIKey, lastfmScrobbleSecret: lastfmScrobbleSecret,
            lastfmScrobbleSessionKey: lastfmScrobbleSessionKey, lastfmScrobbleUsername: lastfmScrobbleUsername,
            notificationPlatform: notificationPlatform, notificationWebhookURL: notificationWebhookURL,
            dingtalkSignSecret: dingtalkSignSecret, feishuSignSecret: feishuSignSecret
        )
    }
    public var isDirty: Bool { currentSnapshot != savedSnapshot }

    /// 给诊断导出**脱敏**用:字段名 → 该字段当前的值。
    ///
    /// ⚠️ 这批值只有一个正当用途:交给 `LogRedactor` 去把它们从日志正文里**抹掉**。
    /// 任何把它们写进报告、日志或界面的用法都直接违反 `DiagnosticsExporter` 开头那条
    /// 硬约束(诊断文件会被贴进公开 issue)。字段名本身不敏感,打码后会以
    /// `<redacted:lastfmScrobbleAPIKey>` 的形式留在报告里,方便排查时知道那里原本是哪一项。
    ///
    /// 刻意读 `currentSnapshot` 而不是 `savedSnapshot`:用户可能刚在界面上粘了一把新
    /// 密钥还没点保存,而 collector 侧的日志里已经可能有它 —— 脱敏要按"可能出现过的值"
    /// 取全集,宁可多抹一个。
    ///
    /// 不收进来的两类,都是有意的:
    /// - **用户名**(lastfmUser / listenbrainzUser 等):是公开信息,而且排查"scrobble 到
    ///   了哪个账号"这类问题时正需要它。
    /// - **stateRelayURL**:host 本身对排查网络问题有用;它的凭据部分是另一个字段
    ///   (stateRelayToken)。反过来 `notificationWebhookURL` 必须收 —— Bark/Server酱/
    ///   飞书的 webhook 地址里凭据就长在 URL 自己身上,整条即凭据。
    public var secretsForRedaction: [String: String] {
        [
            "listenbrainzToken": listenbrainzToken,
            "stateRelayToken": stateRelayToken,
            "lastfmAPIKey": lastfmAPIKey,
            "lastfmScrobbleAPIKey": lastfmScrobbleAPIKey,
            "lastfmScrobbleSecret": lastfmScrobbleSecret,
            "lastfmScrobbleSessionKey": lastfmScrobbleSessionKey,
            "notificationWebhookURL": notificationWebhookURL,
            "dingtalkSignSecret": dingtalkSignSecret,
            "feishuSignSecret": feishuSignSecret,
        ].filter { !$0.value.isEmpty }
    }

    // 以下几个只读判断专给"推送账号"tab 的状态徽标用——刻意读 savedSnapshot(已保存的
    // 值)而不是当前 @Published 字段,道理跟 isDirty 一样:用户刚敲了几个字符还没点
    // 保存,不该被判定成"已配置"。返回值是具体缺哪个字段的提示文案,全部配置齐全时
    // 返回 nil。
    /// 能不能**往** ListenBrainz 提交收听。提交只需要 token,所以这里只看 token。
    public var isListenBrainzConfigured: Bool { !savedSnapshot.listenbrainzToken.isEmpty }

    /// 能不能**从** ListenBrainz 读回统计(听歌报告的数据源、Last.fm 桥接的去重比对)。
    ///
    /// 读统计必须带用户名 —— collector 侧 daily.go / weekly.go 是把它当 API 参数传进
    /// `listenbrainzDigestStats(…, p.cfg.User, …)` 的,没有用户名根本无从查起。所以它跟
    /// "能提交"是两个不同的条件,不能共用 isListenBrainzConfigured。
    ///
    /// 2026-08-13 补。在此之前 Swift 全程只看 token,而 Go 三处(weekly.go:200 /
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
        if savedSnapshot.stateRelayURL.isEmpty { return L10n.t("还没填服务地址（可选）") }
        if savedSnapshot.stateRelayToken.isEmpty { return L10n.t("还没填访问令牌（可选）") }
        return nil
    }

    // 2026-07-29 合并之前,桥接单独要求一把只读 API Key(lastfmAPIKey);合并之后桥接
    // 复用"账号信息"里那一套 API Key(lastfmScrobbleAPIKey——Last.fm 的只读接口不需要
    // 签名,同一对凭据够用),这里两个字段任一非空都算满足,老用户已经填过的 lastfmAPIKey
    // 继续有效,不强制重新操作。
    //
    // 故意只判断 Last.fm 侧凭据,不管 ListenBrainz——这个函数同时被两处调用:
    // ①AccountLinkingTab 判断"桥接读取"是否真的在跑(那边额外自己叠一层
    // isListenBrainzConfigured,见 destinationStatus 的 bridgeOK 注释);②听歌报告的
    // resolvedDigestSource/collector 侧 weekly.go 判断"Last.fm 能不能当数据源",这个
    // 场景完全不需要 ListenBrainz。两个用途混进同一个判断会互相伤害,所以这里保持
    // 语义狭窄,"要不要额外查 ListenBrainz"交给各自调用点自己决定。
    public func lastfmBridgeMissingHint() -> String? {
        // 2026-08-11:用户名输入框已删(见 AccountLinkingTab.lastfmFields 注释)——用户名
        // 和 API Key 现在都来自"连接 Last.fm"向导(授权成功自动回填),所以两种缺失对
        // 用户是同一个动作:去连接。原来还有一个 lastfmMirrorMissingHint 给写入开关做
        // 前置校验,新设计里开关自己就是配置入口,那个函数一并删了。
        if savedSnapshot.lastfmUser.isEmpty
            || (savedSnapshot.lastfmScrobbleAPIKey.isEmpty && savedSnapshot.lastfmAPIKey.isEmpty) {
            return L10n.t("还没连接 Last.fm 账号")
        }
        return nil
    }

    // 推送提醒支持多个平台,这个判断跟具体平台无关,只看 webhook 地址填没填
    // (平台本身有默认值 .bark,不会缺失)。
    public func pushMissingHint() -> String? {
        savedSnapshot.notificationWebhookURL.isEmpty ? L10n.t("还没填 webhook 地址") : nil
    }

    private init() {
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: Self.configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 文件不存在/解析失败——理论上不会发生(collector 非 dry-run 必须有 token
            // 才能启动),但防御性处理跟其它 store 一致:留空,不崩溃。
            raw = [:]
            savedSnapshot = currentSnapshot
            return
        }
        raw = obj
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
        // notification_platform 是这次新加的字段——旧配置文件里没有,缺失/无法识别的
        // 字符串都按 .bark 处理(这个字段加平台选择之前唯一支持过的形态)。
        notificationPlatform = (raw["notification_platform"] as? String).flatMap(NotificationPlatform.init) ?? .bark
        // JSON key 还是历史上的 bark_url——见 collector/config.go 里 NotificationWebhookURL
        // 字段上的注释,两边保持一致,不单独给 Lyrimuse 这边改名。
        notificationWebhookURL = raw["bark_url"] as? String ?? ""
        dingtalkSignSecret = raw["dingtalk_sign_secret"] as? String ?? ""
        feishuSignSecret = raw["feishu_sign_secret"] as? String ?? ""
        savedSnapshot = currentSnapshot
    }

    // 只把当前字段写回磁盘,不重启 collector——"推送账号"tab 的底部保存栏需要先把
    // ConfigStore 和 FeatureSettingsStore 都写完盘,再统一重启一次 collector(避免
    // 两个 store 各自重启一次、白白重启两遍)。抛出的错误里带具体原因,调用方决定怎么
    // 呈现给用户。
    public func persistFile() throws {
        raw["listenbrainz_token"] = listenbrainzToken
        raw["listenbrainz_user"] = listenbrainzUser
        raw["state_relay_url"] = stateRelayURL
        raw["state_relay_token"] = stateRelayToken
        raw["lastfm_user"] = lastfmUser
        raw["lastfm_api_key"] = lastfmAPIKey
        raw["lastfm_scrobble_api_key"] = lastfmScrobbleAPIKey
        raw["lastfm_scrobble_secret"] = lastfmScrobbleSecret
        raw["lastfm_scrobble_session_key"] = lastfmScrobbleSessionKey
        raw["lastfm_scrobble_username"] = lastfmScrobbleUsername
        raw["notification_platform"] = notificationPlatform.rawValue
        raw["bark_url"] = notificationWebhookURL
        raw["dingtalk_sign_secret"] = dingtalkSignSecret
        raw["feishu_sign_secret"] = feishuSignSecret

        guard JSONSerialization.isValidJSONObject(raw) else {
            throw NSError(domain: "ConfigStore", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.t("内部数据不是合法 JSON,已放弃保存")])
        }
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted])
        // 这份就是凭据本体(Last.fm session key / ListenBrainz token / relay token…)。
        try data.writeSecurely(to: Self.configURL)
    }

    // 保存成功后调用,把"已保存快照"推进到当前值——之后 isDirty 会重新变 false,状态徽标
    // 才会认为这些字段已经生效。
    public func commitSnapshot() {
        savedSnapshot = currentSnapshot
    }

    // 独立的便捷保存入口(持久化+重启+提交快照一步到位),给不经过底部保存栏的场景用——
    // 目前只有"连接 Last.fm"成功那一刻会调用:那是一次独立的、以拿到 session key 为
    // 终点的操作,不需要等用户去点底部的"保存并应用"。
    @discardableResult
    public func save() async -> Bool {
        do {
            try persistFile()
        } catch {
            lastError = String(format: L10n.t("写入 config.json 失败: %@"), error.localizedDescription)
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        if await CollectorControl.restartAndWaitAsync() {
            lastError = nil
            commitSnapshot()
            return true
        } else {
            lastError = L10n.t("重启 collector 失败")
            return false
        }
    }
}
