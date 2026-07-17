import Foundation
import CryptoKit
import AppKit

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
        case .api(let msg): return "Last.fm 返回错误: \(msg)"
        case .parse: return "解析 Last.fm 响应失败"
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
        throw LastfmAuthError.api(decoded.message ?? "未知错误")
    }

    static func authorizeURL(apiKey: String, token: String) -> URL {
        var comps = URLComponents(string: "https://www.last.fm/api/auth/")!
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
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
        throw LastfmAuthError.api(decoded.message ?? "未知错误")
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

    func start(apiKey: String) {
        guard !apiKey.isEmpty else {
            state = .failed("请先填写 API Key")
            return
        }
        state = .requestingToken
        Task {
            do {
                let token = try await LastfmAuthFlow.requestToken(apiKey: apiKey)
                NSWorkspace.shared.open(LastfmAuthFlow.authorizeURL(apiKey: apiKey, token: token))
                state = .waitingForBrowserAuth(token: token)
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func confirmBrowserAuth(apiKey: String, secret: String) {
        guard case .waitingForBrowserAuth(let token) = state else { return }
        guard !secret.isEmpty else {
            state = .failed("请先填写 Secret")
            return
        }
        state = .exchanging
        Task {
            do {
                let result = try await LastfmAuthFlow.exchangeSession(apiKey: apiKey, secret: secret, token: token)
                ConfigStore.shared.lastfmScrobbleSessionKey = result.sessionKey
                ConfigStore.shared.lastfmScrobbleUsername = result.username
                await ConfigStore.shared.save()
                state = .success(username: result.username)
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // 用户手误关掉了浏览器标签页、或者想再看一遍授权页——重新打开同一个 token 对应的
    // 授权链接,不用整个流程从头(重新请求 token)开始,state 保持在 waitingForBrowserAuth。
    func reopenBrowserAuth(apiKey: String) {
        guard case .waitingForBrowserAuth(let token) = state else { return }
        NSWorkspace.shared.open(LastfmAuthFlow.authorizeURL(apiKey: apiKey, token: token))
    }

    // "取消"——退出当前流程回到 idle,不留下 requestingToken/waitingForBrowserAuth 这类
    // 卡住的中间态。之前实现里一旦发起了流程就只能硬着头皮走完或者放着不管,这里补上
    // 主动退出的路径。
    func reset() {
        state = .idle
    }
}
