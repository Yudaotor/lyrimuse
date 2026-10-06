import Foundation

/// 到 Discord 的连接:连上、握手、发状态,断了下次再连;要发给的应用换了(换了播放器)就换那个应用重连。连接和读写全在
/// 自己的串行队列上,调用方只把「这一份」交进来。
public final class DiscordPresenceLink: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        /// 没连上:Discord 没开,或者连接刚断。
        case disconnected
        case connected(user: DiscordUser?)
        /// Discord 拒绝了握手(应用 ID 不对)。
        case rejected(code: Int, message: String)
    }

    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.discord", qos: .utility)
    private let socketPaths: @Sendable () -> [String]
    private let pid: Int32
    private let timeout: TimeInterval
    private let onStatus: @Sendable (Status) -> Void
    private let log: @Sendable (String) -> Void
    // 以下只在 queue 上读写。
    private var connection: DiscordIPCConnection?
    private var reported: Status?

    public init(socketPaths: @escaping @Sendable () -> [String],
                pid: Int32 = ProcessInfo.processInfo.processIdentifier, timeout: TimeInterval = 5,
                onStatus: @escaping @Sendable (Status) -> Void, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.socketPaths = socketPaths
        self.pid = pid
        self.timeout = timeout
        self.onStatus = onStatus
        self.log = log
    }

    /// 交进来的那一份最后怎样了。
    public enum Delivery: Equatable, Sendable {
        /// Discord 此刻显示的是这一份:原样收下的;拒收后补发、收下了的精简版(去掉链接和图片);或者精简版也被拒、
        /// 补发了清空,这时为 nil。被拒不算断线,调用方不用重交 —— 原样重发也是一样的结果。
        case shown(DiscordActivity?)
        /// 没连上或连接断了,调用方过一会儿再交。
        case lost
    }

    /// 发这一份(nil = 清掉)。没连上就按它的应用先连;连着的不是它的应用就断开、按它的应用重连 —— Discord 随连接断开清掉
    /// 原来那个应用的状态,这时不报「断开」。没连上时的清空什么都不做,Discord 那边本来就没有这个进程的状态。
    /// 回调在内部队列上,带着 Discord 此刻实际显示的是哪一份(`Delivery`)。
    public func send(_ activity: DiscordActivity?, completion: @escaping @Sendable (Delivery) -> Void = { _ in }) {
        queue.async { completion(self.deliver(activity)) }
    }

    /// 连着就处理积着的帧(回心跳)、确认连接还在;没连着什么都不做。
    public func check() {
        queue.async { self.service() }
    }

    /// 没连着就按这个应用连一次,不发东西:没在放歌时也知道连不连得上。
    public func connectIfNeeded(clientID: String) {
        queue.async {
            if self.connection == nil { _ = self.connect(clientID: clientID) }
        }
    }

    /// 断开。`clearing` 时先把状态清掉。
    public func disconnect(clearing: Bool) {
        queue.async {
            if clearing, let connection = self.connection {
                try? connection.setActivity(nil, pid: self.pid, timeout: self.timeout)
            }
            self.drop(reason: nil)
        }
    }

    /// 等已经交进来的活都做完。
    public func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - 队列上

    private func deliver(_ activity: DiscordActivity?) -> Delivery {
        if let activity, let current = connection, current.clientID != activity.applicationID {
            current.close()
            connection = nil
            log("switching to application \(activity.applicationID)")
        }
        if connection == nil {
            guard let activity else { return .shown(nil) }
            guard connect(clientID: activity.applicationID) else { return .lost }
        }
        let first = attempt(activity)
        guard first == .lost else { return first }
        // 连接断了(多半是 Discord 重启过):重连一次再发,不用等下一轮。
        guard let activity, connect(clientID: activity.applicationID) else { return .lost }
        return attempt(activity)
    }

    /// 在当前连接上发一次。`.lost` = 连接断了,已经丢掉。Discord 拒收这一份时去掉链接和图片补发一次精简版
    /// (`DiscordPresence.withoutLinksAndImages`);精简版也被拒、或者本来就没有链接和图片时补发一次清空 —— 被拒的命令
    /// 不改 Discord 上的状态,不清的话这一首放完之前好友看到的都是上一首。
    private func attempt(_ activity: DiscordActivity?) -> Delivery {
        guard let connection else { return .lost }
        switch push(activity, on: connection) {
        case .delivered:
            return .shown(activity)
        case .lost:
            return .lost
        case .refused:
            // 清空被拒没见过;真遇到了也没有更退一步的办法,当清掉了。
            guard let activity else { return .shown(nil) }
            let plain = DiscordPresence.withoutLinksAndImages(activity)
            if plain != activity {
                log("resending without links and images")
                switch push(plain, on: connection) {
                case .delivered: return .shown(plain)
                case .lost: return .lost
                case .refused: break
                }
            }
            log("clearing after the activity was refused")
            return push(nil, on: connection) == .lost ? .lost : .shown(nil)
        }
    }

    private enum Outcome { case delivered, refused, lost }

    /// 发一次,看 Discord 收没收。每次都记进对外请求审计日志:内容经 Discord 发出去。连接断了的已经丢掉。
    private func push(_ activity: DiscordActivity?, on connection: DiscordIPCConnection) -> Outcome {
        let started = Date()
        let operation = activity == nil ? "clear-activity" : "set-activity"
        func audit(_ error: Error?) {
            NetworkAuditLog.recordSummarized(service: "discord", operation: operation, host: "discord-ipc",
                                             statusCode: nil, durationMs: Date().timeIntervalSince(started) * 1000,
                                             error: error)
        }
        do {
            try connection.setActivity(activity, pid: pid, timeout: timeout)
            audit(nil)
            return .delivered
        } catch DiscordIPCConnection.Failure.rejected(let code, let message) {
            audit(DiscordIPCConnection.Failure.rejected(code: code, message: message))
            log("activity refused code=\(code) message=\(message)")
            return .refused
        } catch {
            audit(error)
            drop(reason: "\(error)")
            return .lost
        }
    }

    private func connect(clientID: String) -> Bool {
        do {
            let connection = try DiscordIPCConnection.connect(paths: socketPaths(), clientID: clientID, timeout: timeout)
            self.connection = connection
            log("connected via \(connection.path)")
            report(.connected(user: connection.user))
            return true
        } catch DiscordIPCConnection.Failure.rejected(let code, let message) {
            log("handshake refused code=\(code) message=\(message)")
            report(.rejected(code: code, message: message))
        } catch DiscordIPCConnection.Failure.unavailable {
            report(.disconnected)
        } catch {
            log("connect failed: \(error)")
            report(.disconnected)
        }
        return false
    }

    private func service() {
        guard let connection else { return }
        do {
            try connection.service()
        } catch {
            drop(reason: "\(error)")
        }
    }

    private func drop(reason: String?) {
        guard let connection else { return }
        connection.close()
        self.connection = nil
        if let reason { log("disconnected: \(reason)") }
        report(.disconnected)
    }

    private func report(_ status: Status) {
        guard status != reported else { return }
        reported = status
        onStatus(status)
    }
}
