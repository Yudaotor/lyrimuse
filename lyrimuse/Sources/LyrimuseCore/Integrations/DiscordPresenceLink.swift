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

    /// 发这一份(nil = 清掉)。没连上就按它的应用先连;连着的不是它的应用就断开、按它的应用重连 —— Discord 随连接断开清掉
    /// 原来那个应用的状态,这时不报「断开」。没连上时的清空什么都不做,Discord 那边本来就没有这个进程的状态。
    /// 回调在内部队列上:true = Discord 收下了,或者拒收了这一份(只记日志,原样重发也是一样的结果);
    /// false = 没连上或连接断了,调用方过一会儿再交。
    public func send(_ activity: DiscordActivity?, completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
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

    private func deliver(_ activity: DiscordActivity?) -> Bool {
        if let activity, let current = connection, current.clientID != activity.applicationID {
            current.close()
            connection = nil
            log("switching to application \(activity.applicationID)")
        }
        if connection == nil {
            guard let activity else { return true }
            guard connect(clientID: activity.applicationID) else { return false }
        }
        if attempt(activity) { return true }
        // 连接断了(多半是 Discord 重启过):重连一次再发,不用等下一轮。
        guard let activity, connect(clientID: activity.applicationID) else { return false }
        return attempt(activity)
    }

    /// 在当前连接上发一次。false = 连接断了,已经丢掉。每次都记进对外请求审计日志:内容经 Discord 发出去。
    private func attempt(_ activity: DiscordActivity?) -> Bool {
        guard let connection else { return false }
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
            return true
        } catch DiscordIPCConnection.Failure.rejected(let code, let message) {
            audit(DiscordIPCConnection.Failure.rejected(code: code, message: message))
            log("activity refused code=\(code) message=\(message)")
            return true
        } catch {
            audit(error)
            drop(reason: "\(error)")
            return false
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
