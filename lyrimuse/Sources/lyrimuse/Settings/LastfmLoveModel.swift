import Foundation
import Combine
import OSLog
import LyrimuseCore

// 不记凭据原文(api_key / secret / session key),跟 LastfmAuthFlow 同一条纪律。
private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lastfm-love")

/// 当前曲目在 Last.fm 上的「喜欢」(love)。读写都走 Last.fm,跟在哪个播放器里放无关 —— 酷狗 /
/// QQ 音乐 / 网易云这类没有脚本接口的播放器,歌词窗口里能用的「喜欢」只有这一个(12 章 §8)。
///
/// **打在哪一首上**:collector 上送时可能改写歌手 / 歌名(合唱串收拢、「智能」档编目匹配,见
/// lastfm.go `resolveScrobbleTags`),喜欢必须打在**上送的那个写法**上,否则 Last.fm 上喜欢的是
/// 另一个实体、跟收听记录对不上。Last.fm 回报的 nowplaying 条目就是上送写法本身:它新鲜、且标题
/// 对得上本机这首时用它的歌手和歌名;对不上(还没确认收到、镜像关着、「智能」档连歌名都改了)
/// 退回本机显示的写法。
///
/// **只在有人显示它时才发请求**(`retain` / `release` 计数):换一首歌读一次状态,没有任何展示面
/// 挂着时不为它多发请求。
@MainActor
final class LastfmLoveModel: ObservableObject {
    static let shared = LastfmLoveModel()

    typealias Target = LastfmLove.Target

    /// 此刻点「喜欢」会打到的那一首。nil = 没连 Last.fm(缺授权)或者没在放歌。
    @Published private(set) var target: Target?
    /// target 在 Last.fm 上是否已喜欢。nil = 还没读到(读失败也是 nil):菜单那一行照常可点,点了按
    /// 「喜欢」处理。
    @Published private(set) var loved: Bool?

    private var consumers = 0
    /// 已经为哪一首读过(或正在读)状态,同一首不重读。
    private var loadedTarget: Target?
    /// 读 / 写的代次:换歌或又点了一下之后,晚到的旧结果一律丢掉。
    private var generation = 0
    /// 写操作串行链:连点两下(喜欢到取消)时两次写的落地顺序必须跟点击顺序一致。
    private var writeChain: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let coordinator = PlaybackCoordinator.shared
        let stats = LastfmStatsService.shared
        let config = ConfigStore.shared
        // 任何一个输入变了都重算一次 target;真变了才会动 loved(见 recomputeTarget)。
        coordinator.$title.map { _ in () }
            .merge(with: coordinator.$artist.map { _ in () },
                   stats.$apiNowPlaying.map { _ in () },
                   config.$lastfmScrobbleSessionKey.map { _ in () })
            // @Published 是 willSet 语义:回调里读到的还是旧值,推到下一拍再读。
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recomputeTarget() }
            .store(in: &cancellables)
    }

    /// 展示面出现 / 消失时调用,成对。
    func retain() {
        consumers += 1
        loadIfNeeded()
    }

    func release() {
        consumers = max(0, consumers - 1)
    }

    /// 翻转当前这首的喜欢状态。乐观更新,写失败再翻回来。
    func toggle() {
        guard let target, let creds = Self.credentials() else { return }
        let newValue = !(loved ?? false)
        loved = newValue
        // 写完就以写的结果为准,这一首不再回读(Last.fm 的读接口可能还没跟上刚才那次写)。
        loadedTarget = target
        generation &+= 1
        let gen = generation
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            let ok = await LastfmLoveAPI.setLoved(newValue, target: target, creds: creds)
            guard let self, !ok, self.generation == gen, self.target == target else { return }
            self.loved = !newValue
        }
    }

    private func recomputeTarget() {
        let next = Self.resolveTarget()
        guard next != target else { return }
        target = next
        loved = nil
        loadedTarget = nil
        generation &+= 1
        loadIfNeeded()
    }

    private func loadIfNeeded() {
        guard consumers > 0, let target, loadedTarget != target, let creds = Self.credentials() else { return }
        loadedTarget = target
        generation &+= 1
        let gen = generation
        Task { [weak self] in
            let value = await LastfmLoveAPI.fetchLoved(target: target, creds: creds)
            guard let self, self.generation == gen, self.target == target else { return }
            self.loved = value
            // 没读到:下次有展示面出现时再试,不在这里自己轮询。
            if value == nil { self.loadedTarget = nil }
        }
    }

    private static func resolveTarget() -> Target? {
        guard credentials() != nil else { return nil }
        let coordinator = PlaybackCoordinator.shared
        let stats = LastfmStatsService.shared
        // 选写法的规则在 Core(`LastfmLove.resolveTarget`,selftest 钉着)。
        return LastfmLove.resolveTarget(
            localArtist: coordinator.artist, localTitle: coordinator.title,
            nowPlaying: stats.apiNowPlaying.map { LastfmLove.Target(artist: $0.artist, title: $0.title) },
            nowPlayingFresh: stats.apiNowPlayingIsFresh)
    }

    /// 写接口要 session key + secret(读接口只要 api_key + 用户名)。四样缺一样就当没连。
    private static func credentials() -> LastfmLoveAPI.Credentials? {
        let c = ConfigStore.shared
        let user = c.lastfmScrobbleUsername.isEmpty ? c.lastfmUser : c.lastfmScrobbleUsername
        guard !c.lastfmScrobbleAPIKey.isEmpty, !c.lastfmScrobbleSecret.isEmpty,
              !c.lastfmScrobbleSessionKey.isEmpty, !user.isEmpty else { return nil }
        return .init(apiKey: c.lastfmScrobbleAPIKey, secret: c.lastfmScrobbleSecret,
                     sessionKey: c.lastfmScrobbleSessionKey, user: user)
    }
}

/// `track.getInfo`(读 userloved)与 `track.love` / `track.unlove`(签名写)。
/// 过全局限速队列、每次请求记一笔 NetworkAuditLog,跟 LastfmStatsService.request 同一套约束。
enum LastfmLoveAPI {
    struct Credentials: Sendable {
        let apiKey: String
        let secret: String
        let sessionKey: String
        let user: String
    }

    private static let apiRoot = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    /// nil = 没读到(网络 / 限流 / 其它 API 错误)。Last.fm 没有这首(error 6)算「没喜欢」——
    /// track.love 对没收录的曲目照样能喜欢。
    static func fetchLoved(target: LastfmLoveModel.Target, creds: Credentials) async -> Bool? {
        let pairs: [(name: String, value: String)] = [
            ("method", "track.getInfo"),
            ("artist", target.artist),
            ("track", target.title),
            ("username", creds.user),
            ("api_key", creds.apiKey),
            ("format", "json"),
        ]
        var comps = URLComponents(url: apiRoot, resolvingAgainstBaseURL: false)!
        // 读接口的 query 得走 LastfmQuery 的双重转义(含 `+` 的歌名,见该类型头注)。
        comps.percentEncodedQuery = LastfmQuery.queryString(pairs)
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let json = await send(req, operation: "track.getInfo") else { return nil }
        return LastfmLove.parseUserLoved(json)
    }

    /// 写成功返回 true。
    static func setLoved(_ loved: Bool, target: LastfmLoveModel.Target, creds: Credentials) async -> Bool {
        let method = loved ? "track.love" : "track.unlove"
        var params = [
            "method": method,
            "artist": target.artist,
            "track": target.title,
            "api_key": creds.apiKey,
            "sk": creds.sessionKey,
        ]
        // 签名用原值、不含 format(同 collector lastfm.go sign())。
        params["api_sig"] = LastfmAuthFlow.signParams(params, secret: creds.secret)
        params["format"] = "json"
        var req = URLRequest(url: apiRoot)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = LastfmLove.formBody(params).data(using: .utf8)
        guard let json = await send(req, operation: method) else { return false }
        guard LastfmLove.writeSucceeded(json) else {
            logger.notice("\(method, privacy: .public): api error \((json["error"] as? Int) ?? -1, privacy: .public)")
            return false
        }
        return true
    }

    private static func send(_ req: URLRequest, operation: String) async -> [String: Any]? {
        await LastfmRateLimiter.shared.acquire(priority: .interactive)
        let start = Date()
        let host = req.url?.host ?? "ws.audioscrobbler.com"
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            NetworkAuditLog.record(service: "lastfm", operation: operation, host: host, statusCode: status,
                                   durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            // Last.fm 的 API 错误多以 200 + {"error":N} 返回,也有 4xx 带同样 body 的;两种都交给
            // 调用方按 body 判。body 读不出来才算失败。
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.notice("\(operation, privacy: .public): http \(status, privacy: .public), unreadable body")
                return nil
            }
            return obj
        } catch {
            NetworkAuditLog.record(service: "lastfm", operation: operation, host: host, statusCode: nil,
                                   durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            logger.notice("\(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
