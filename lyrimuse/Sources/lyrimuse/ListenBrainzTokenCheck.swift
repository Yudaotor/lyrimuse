import Foundation
import LyrimuseCore

// 拿 Token 反查用户名 —— 用户不用再手抄一遍自己的用户名。
//
// ListenBrainz 有个专门干这件事的接口:GET /1/validate-token,带上 Token 就会返回它属于谁。
// 原来「账户信息」里除了 Token 还有一个"用户名(听歌报告需要)"输入框,那是把服务端已经
// 知道的东西再让用户手打一遍 —— 打错了还只会在几天后的听歌报告里才暴露出来。
//
// 校验结果同时兼作这张卡的连接状态:填对了当场显示"已连接:某某",填错了当场说 Token 无效,
// 不用等到下一次真正提交播放记录时才知道。
@MainActor
final class ListenBrainzTokenCheck: ObservableObject {
    enum State: Equatable {
        case empty
        case checking
        case valid(user: String)
        case invalid
        /// 网络层面就没问过去(断网/超时)。跟"Token 无效"必须分开:前者不代表 Token 有问题,
        /// 显示成无效会让人白白去重新生成一个。
        case unreachable
    }

    @Published private(set) var state: State = .empty

    private var task: Task<Void, Never>?
    private var lastChecked = ""

    /// Token 变化时调。自带防抖 —— 输入框每敲一个字符都会来一次,不防抖就是一串废请求。
    ///
    /// knownUser 传已经持久化下来的用户名(ConfigStore.listenbrainzUser)。有它的话**首次**
    /// 调用直接认,不转圈也不发请求 —— 这个对象是页面上的 @StateObject,离开设置页再回来
    /// 就是个新实例、state 退回 .empty,而 Token 一个字都没变。2026-08-16 用户报的正是这个:
    /// "这个 yudaotor 没有持久化吗,为什么我刚才切进去看的时候还在转圈"。
    func tokenChanged(_ token: String, knownUser: String = "", onResolvedUser: @escaping (String) -> Void) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard !trimmed.isEmpty else {
            lastChecked = ""
            state = .empty
            return
        }
        // 同一个 Token 已经查过就别再查(切换页面/重绘都会走到这里)。
        if trimmed == lastChecked, case .valid = state { return }

        // 新实例 + 手上已经有存好的用户名:先当它有效,页面立刻是"已连接:xxx"。
        //
        // ⚠️ 只在 lastChecked 为空(= 这个实例还没查过任何东西)时才走这条快速路径。用户在
        // 输入框里改 Token 时 lastChecked 早就被设成旧 Token 了,不会命中,照常走校验 ——
        // 否则改完 Token 会一直显示旧用户名。
        if lastChecked.isEmpty, !knownUser.isEmpty {
            lastChecked = trimmed
            state = .valid(user: knownUser)
            // 仍然在后台**静默**复核一次(不置 .checking、不转圈):Token 可能是从别处导进来的,
            // 跟存着的用户名对不上;真对不上时下面会把 state 纠正过来。
            task = Task { [weak self] in
                let outcome = await Self.validate(token: trimmed)
                guard !Task.isCancelled, let self else { return }
                if outcome != .valid(user: knownUser) {
                    self.state = outcome
                    if case .valid(let user) = outcome { onResolvedUser(user) }
                }
            }
            return
        }

        state = .checking
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let outcome = await Self.validate(token: trimmed)
            guard !Task.isCancelled else { return }
            self?.lastChecked = trimmed
            self?.state = outcome
            if case .valid(let user) = outcome { onResolvedUser(user) }
        }
    }

    private static func validate(token: String) async -> State {
        guard let url = URL(string: "https://api.listenbrainz.org/1/validate-token") else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "listenbrainz", operation: "validate-token", host: url.host ?? "api.listenbrainz.org",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            // ⚠️ 实测(2026-08-15 直接打这个接口核对过):Token 不对时服务端回的是
            // **HTTP 200 + {"valid":false}**,不是 401。所以真正的判据是下面那个 valid 字段,
            // 这一行只是兜底 —— 万一哪天它改成标准的鉴权失败,也别把 401 当成"网络没问到"。
            if status == 401 { return .invalid }
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .unreachable }
            guard object["valid"] as? Bool == true else { return .invalid }
            // valid 为真却没给用户名,当成没问到 —— 别把空字符串写进配置。
            guard let user = object["user_name"] as? String, !user.isEmpty else {
                return .unreachable
            }
            return .valid(user: user)
        } catch {
            NetworkAuditLog.record(service: "listenbrainz", operation: "validate-token", host: url.host ?? "api.listenbrainz.org",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return .unreachable
        }
    }
}
