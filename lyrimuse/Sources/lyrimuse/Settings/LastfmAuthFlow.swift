import Foundation
import CryptoKit
import AppKit
import OSLog

// 这个 logger 只记"发生了哪一步、失败原因是什么"，绝不记 api_key/secret/session key
// 这些凭据原文本身(跟 ConfigStore.swift 顶部同一条纪律)——DiagnosticsExporter 导出的
// "App Log"那节靠它才能看到这条连接流程实际发生过什么。
private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lastfm-connect")

// "连接 Last.fm"自动化流程——Last.fm 经典 auth API 没有回调机制:拿到一次性 token 之后,
// 必须等用户自己在浏览器里点完"Yes, allow access",程序才能换永久 session key(见
// README 里手动 curl 步骤的同一套流程)。这里做成一个状态机,"等待用户确认已完成浏览器
// 授权"这一步渲染成一个按钮,由用户主动点击推进,不做轮询猜测。
enum LastfmConnectState: Equatable {
    case idle
    case requestingToken
    case waitingForBrowserAuth(token: String)
    case exchanging
    case success(username: String)
    case failed(String)
}

enum LastfmAuthError: Error, LocalizedError {
    case api(String)
    case parse

    var errorDescription: String? {
        switch self {
        case .api(let msg): return String(format: L10n.t("Last.fm 返回错误: %@"), msg)
        case .parse: return L10n.t("解析 Last.fm 响应失败")
        }
    }
}

enum LastfmAuthFlow {
    private static let apiRoot = "https://ws.audioscrobbler.com/2.0/"

    // 跟 collector/lastfm.go:51-65 的 sign() 逐字节对应(两处各自独立实现,理由跟
    // EnrichCacheStore 的 sanitizeLyricsFilename 一样——纯确定性算法,不属于必须收敛
    // 成一份代码的逻辑):参数(不含 format/callback)按 key 字母序排序、拼成 key+value,
    // 末尾接 shared secret,取 MD5 十六进制。
    static func signParams(_ params: [String: String], secret: String) -> String {
        let sorted = params.sorted { $0.key < $1.key }
        var s = ""
        for (k, v) in sorted {
            s += k + v
        }
        s += secret
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func buildURL(_ params: [String: String]) -> URL {
        var comps = URLComponents(string: apiRoot)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url!
    }

    // Last.fm 的错误(比如 api_key 无效)经常仍然是 HTTP 200、body 里带 message 字段,
    // 不总是用非 200 状态码表达——这里不看 HTTP 状态,只看 body 能不能解析出预期字段,
    // 更贴近 Last.fm 实际行为。
    static func requestToken(apiKey: String) async throws -> String {
        let url = buildURL(["method": "auth.gettoken", "api_key": apiKey, "format": "json"])
        let (data, _) = try await URLSession.shared.data(from: url)
        struct Resp: Decodable { let token: String?; let message: String? }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data) else { throw LastfmAuthError.parse }
        if let token = decoded.token, !token.isEmpty { return token }
        throw LastfmAuthError.api(decoded.message ?? L10n.t("未知错误"))
    }

    // cb 参数是 Last.fm 授权页文档里的回调机制:用户点完"Yes, allow access"之后,
    // 浏览器会跳转到这个地址(不带任何凭据,纯粹是"已授权"信号)。指向自定义 URL
    // scheme(build.sh 里注册的 CFBundleURLTypes、AppDelegate 里处理 GetURL 事件),
    // 浏览器会弹一次系统级"要打开 Lyrimuse 吗"确认框,用户点一下就跳回 App——比之前
    // 要求用户自己回来点"我已完成授权,继续"少一步。
    static func authorizeURL(apiKey: String, token: String) -> URL {
        var comps = URLComponents(string: "https://www.last.fm/api/auth/")!
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "cb", value: "lyrimuse://lastfm-auth-callback"),
        ]
        return comps.url!
    }

    static func exchangeSession(apiKey: String, secret: String, token: String) async throws -> (sessionKey: String, username: String) {
        let signed = signParams(["method": "auth.getsession", "api_key": apiKey, "token": token], secret: secret)
        let url = buildURL([
            "method": "auth.getsession", "api_key": apiKey, "token": token,
            "api_sig": signed, "format": "json",
        ])
        let (data, _) = try await URLSession.shared.data(from: url)
        struct Resp: Decodable {
            struct Session: Decodable { let name: String; let key: String }
            let session: Session?
            let message: String?
        }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data) else { throw LastfmAuthError.parse }
        if let session = decoded.session { return (session.key, session.name) }
        throw LastfmAuthError.api(decoded.message ?? L10n.t("未知错误"))
    }
}

// 驱动"连接 Last.fm"这一步 UI 的控制器——独立于 View 持有 async Task,避免 View 结构体
// 被 SwiftUI 重建时丢失正在进行中的请求状态。成功后直接把 session key 写进
// ConfigStore.shared 并保存(会顺带触发 collector 重启)。
//
// 改成单例(跟 ConfigStore.shared 同款):账号连接的侧边栏行(显示"连接中/已连接/失败"
// 状态徽标)和详情页(实际驱动授权流程的按钮)现在是两个独立的 View,却要认同一份连接
// 状态——如果各自 `@StateObject` 一份,状态就分裂了(侧边栏看不到详情页正在进行的授权
// 流程)。全局只会有一份"正在连接 Last.fm"的流程,单例合情合理。
@MainActor
final class LastfmConnectController: ObservableObject {
    static let shared = LastfmConnectController()

    @Published private(set) var state: LastfmConnectState = .idle

    // 本次流程用的密钥,start() 时**钉死**在这里 —— confirm/reopen/回调一律用这份,
    // 不再读输入框的现值。原来 confirm 用的是调用那一刻输入框里的 Key/Secret:授权页
    // 开着的时候改一下密钥再点"继续",换 session 必败还查不出为什么(审阅指出)。
    private var pendingAPIKey = ""
    private var pendingSecret = ""

    // 代际计数器:reset()/新一轮 start() 都会自增。所有 async 收尾在写状态/开浏览器/
    // 写配置之前核对代际 —— 原来"取消"只是把 state 扳回 idle,在途的 requestToken
    // 完成后照样开浏览器+把状态改成 waitingForBrowserAuth,整个流程被复活(审阅确认)。
    private var gen = 0

    func start(apiKey: String, secret: String) {
        // 2026-07-29 起"账号信息"只有一套 API Key/Secret(合并了原来单独存在的只读
        // Key),这里不再需要用"Scrobble API Key"这个名字跟另一个字段区分,直接叫
        // "API Key"就够。
        guard !apiKey.isEmpty else {
            logger.error("start: blocked — API Key is empty")
            state = .failed(L10n.t("请先填写 API Key"))
            return
        }
        // Secret 到 exchange 那步才真正用到,但现在就校验 —— 空着走完浏览器授权才失败,
        // 一次性 token 白白作废,用户还得重走一遍(审阅指出)。
        guard !secret.isEmpty else {
            logger.error("start: blocked — Secret is empty")
            state = .failed(L10n.t("请先填写 Secret"))
            return
        }
        pendingAPIKey = apiKey
        pendingSecret = secret
        gen += 1
        let myGen = gen
        logger.info("start: requesting token")
        state = .requestingToken
        Task {
            do {
                let token = try await LastfmAuthFlow.requestToken(apiKey: apiKey)
                guard myGen == self.gen else { return } // 已被取消/重开,别复活流程
                logger.info("start: got token, opening browser auth page")
                NSWorkspace.shared.open(LastfmAuthFlow.authorizeURL(apiKey: apiKey, token: token))
                state = .waitingForBrowserAuth(token: token)
            } catch {
                guard myGen == self.gen else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("start: requestToken failed — \(message, privacy: .public)")
                state = .failed(message)
            }
        }
    }

    func confirmBrowserAuth() {
        guard case .waitingForBrowserAuth(let token) = state else {
            logger.error("confirmBrowserAuth: called while not waitingForBrowserAuth (state=\(String(describing: self.state), privacy: .public)) — ignored")
            return
        }
        // 密钥用 start() 钉死的那份,不读输入框现值(见 pendingAPIKey 注释)
        let apiKey = pendingAPIKey
        let secret = pendingSecret
        let myGen = gen
        logger.info("confirmBrowserAuth: exchanging session")
        state = .exchanging
        Task {
            do {
                let result = try await LastfmAuthFlow.exchangeSession(apiKey: apiKey, secret: secret, token: token)
                guard myGen == self.gen else { return } // 已被取消,不写任何东西
                logger.info("confirmBrowserAuth: connected successfully")
                ConfigStore.shared.lastfmScrobbleSessionKey = result.sessionKey
                ConfigStore.shared.lastfmScrobbleUsername = result.username
                // 换到了新 session key,上一把钥匙的"授权失效"红标(如果有)立刻作废 ——
                // 不等 collector 下一次成功提交再删,界面反馈要即时。
                LastfmMirrorStatus.clear()
                // 可能连的是另一个账号:上一个账号的统计/头像/榜单全部作废,让信息页
                // 按新身份重拉(审阅指出旧账号数据会一直挂着)。
                LastfmStatsService.shared.resetAll()
                // 桥接用的"用户名"字段自动回填——只在还没手动填过时才带过去,不覆盖用户
                // 已经显式填的值(理论上极少见:桥接一个跟镜像不同的 Last.fm 账号)。
                if ConfigStore.shared.lastfmUser.isEmpty {
                    ConfigStore.shared.lastfmUser = result.username
                }
                await ConfigStore.shared.save()
                state = .success(username: result.username)
            } catch {
                guard myGen == self.gen else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("confirmBrowserAuth: exchangeSession failed — \(message, privacy: .public)")
                state = .failed(message)
            }
        }
    }

    // 用户手误关掉了浏览器标签页、或者想再看一遍授权页——重新打开同一个 token 对应的
    // 授权链接,不用整个流程从头(重新请求 token)开始,state 保持在 waitingForBrowserAuth。
    func reopenBrowserAuth() {
        guard case .waitingForBrowserAuth(let token) = state else { return }
        NSWorkspace.shared.open(LastfmAuthFlow.authorizeURL(apiKey: pendingAPIKey, token: token))
    }

    // "取消"——退出当前流程回到 idle,不留下 requestingToken/waitingForBrowserAuth 这类
    // 卡住的中间态。之前实现里一旦发起了流程就只能硬着头皮走完或者放着不管,这里补上
    // 主动退出的路径。
    func reset() {
        gen += 1 // 作废一切在途收尾 —— 光扳状态挡不住它们回来复活流程(见 gen 注释)
        state = .idle
    }

    // 2026-07-29 新增:浏览器授权页(见 authorizeURL 的 cb= 参数)完成授权后会自动
    // 跳转回 lyrimuse://lastfm-auth-callback,AppDelegate 收到这个 URL 事件后调这里,
    // 免去用户手动点"我已完成授权,继续"这一步。回调 URL 本身不带任何凭据,只是"用户
    // 已经点了 Yes, allow access"的信号——真正换 session key 仍然是重新调一次
    // auth.getsession,跟手动点按钮走的是同一段逻辑,只是触发方式从"用户点击"变成
    // "系统事件"。只在当前确实处于 waitingForBrowserAuth 时才生效:重复回调/陈旧回调
    // (比如用户已经手动点过按钮、连接早就成功了)会被安全地忽略,不会误触发第二次
    // 交换。手动按钮继续保留在 UI 上作为兜底——某些浏览器/安全软件可能拦截自定义
    // URL scheme 跳转,不能假设这条自动化路径 100% 会触发。
    func handleAuthCallback() {
        guard case .waitingForBrowserAuth = state else {
            logger.notice("handleAuthCallback: ignored — not currently waiting for browser auth (state=\(String(describing: self.state), privacy: .public))")
            return
        }
        logger.info("handleAuthCallback: browser redirected back automatically, confirming without user click")
        confirmBrowserAuth()
    }
}
