import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "github-stars")

/// 「关于」页 GitHub 仓库那一行右边那个 star 数(2026-09-03 用户要求:「帮我在这里加一个
/// star 数,代表我这个仓库目前实际的 star 数」)。
///
/// 只做三件事:读缓存、按需取一次数、把结果发布给那一行。判据(要不要取、怎么解析、限流
/// 退避到什么时候)全在 `LyrimuseCore.GitHubStars` 里,被 selftest 钉住 —— 这边只剩
/// URLSession 和 `@Published`。
///
/// ⚠️ **取不到就什么都不显示**,不显示 0、不显示占位符、不显示错误态。0 是个**看起来很确定
/// 的错数字**,而这一行的语境是"你的 ⭐ 是最大的鼓励",显示成 0 star 比不显示糟得多;
/// 转圈或者感叹号则是拿一个装饰性数字去打扰用户。首次成功之后数字落进 UserDefaults,
/// 之后每次开页先显示存量、后台再决定要不要更新,不会闪。
///
/// ⚠️ **单例**:这一页是 `@ObservedObject` 引用它。做成每个视图各自 `@StateObject` 的话,
/// 离开设置页再回来就是个新实例、缓存要重读、还可能重复发请求 —— ListenBrainz 那边
/// "切进去还在转圈"就是这个坑(见 `ListenBrainzTokenCheck.tokenChanged` 的注释)。
@MainActor
final class GitHubStarsService: ObservableObject {
    static let shared = GitHubStarsService()

    /// nil = 还没成功取到过(或者本机从没联网成功过)。UI 见到 nil 就整个不画那个角标。
    @Published private(set) var starCount: Int?

    private var fetchedAt: Date?
    /// 失败/限流之后的最早重试时刻。**故意只存在内存里**:重启 App 本来就该重新试一次,
    /// 而"上次断网"这件事没有跨进程记住的价值。
    private var retryNotBefore: Date?
    private var inflight: Task<Void, Never>?

    private static let countKey = "githubStarCount"
    private static let fetchedAtKey = "githubStarCountFetchedAt"

    private init() {
        let defaults = UserDefaults.standard
        // `object(forKey:)` 而不是 `integer(forKey:)`:后者把"没存过"和"存过 0"混成同一个
        // 0,而这两者在这里的含义完全不同(不画角标 vs 画一个 0)。
        if let stored = defaults.object(forKey: Self.countKey) as? Int, stored >= 0 {
            starCount = stored
        }
        if let stamp = defaults.object(forKey: Self.fetchedAtKey) as? Date {
            fetchedAt = stamp
        }
    }

    /// 「关于」页出现时调一次。真正发不发请求由 `GitHubStars.shouldRefresh` 决定。
    func refreshIfStale() async {
        guard GitHubStars.shouldRefresh(now: Date(), fetchedAt: fetchedAt, retryNotBefore: retryNotBefore) else {
            return
        }
        // 同一时刻只允许有一个在飞:这一页可能被快速切进切出好几次。
        if let inflight {
            await inflight.value
            return
        }
        // 强引用 self 是刻意的:这是个单例、活得比这个 task 长,而 `[weak self]` 会让闭包
        // 返回 `Void?`(编译不过),再为它套一层 guard 只是为了绕类型、换不来任何生命周期收益。
        let task = Task { await self.fetch() }
        inflight = task
        await task.value
        inflight = nil
    }

    private func fetch() async {
        let url = GitHubStars.repoAPIURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub 对没有 User-Agent 的请求直接回 403。URLSession 默认会带一个,但那串是
        // 系统拼的、随系统版本变 —— 显式给一个稳定的,出问题时对面日志里也认得出是谁。
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        request.setValue("Lyrimuse/\(version)", forHTTPHeaderField: "User-Agent")

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode
            // 每一次真的发出去的请求都记一笔——见 NetworkAuditLog 头注(用户要求"所有对外
            // 请求都要记日志")。只给 host 和一个语义标签,不给完整 URL。
            NetworkAuditLog.record(service: "github", operation: "repo-stars", host: url.host ?? "api.github.com",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            // 403/429 = 撞了匿名配额。按响应里的 X-RateLimit-Reset 退避,别自己拍一个数。
            if status == 403 || status == 429 {
                let reset = http?.value(forHTTPHeaderField: "X-RateLimit-Reset")
                retryNotBefore = GitHubStars.retryDate(now: Date(), rateLimitReset: reset)
                logger.notice("repo-stars: http \(status ?? -1, privacy: .public), backing off until \(self.retryNotBefore?.description ?? "-", privacy: .public)")
                return
            }
            guard status == 200, let count = GitHubStars.parseStarCount(data) else {
                retryNotBefore = Date().addingTimeInterval(GitHubStars.failureBackoff)
                logger.notice("repo-stars: http \(status ?? -1, privacy: .public) or response parse failed, keeping cached value")
                return
            }
            let now = Date()
            starCount = count
            fetchedAt = now
            retryNotBefore = nil
            UserDefaults.standard.set(count, forKey: Self.countKey)
            UserDefaults.standard.set(now, forKey: Self.fetchedAtKey)
        } catch {
            NetworkAuditLog.record(service: "github", operation: "repo-stars", host: url.host ?? "api.github.com",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            retryNotBefore = Date().addingTimeInterval(GitHubStars.failureBackoff)
        }
    }
}
