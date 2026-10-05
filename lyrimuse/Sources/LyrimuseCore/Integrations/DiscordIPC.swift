import Darwin
import Foundation

/// Discord 桌面版的本地 RPC 线路:Unix 套接字 `discord-ipc-0`…`9`,每帧是操作码、载荷长度(各 4 字节小端)加 UTF-8 JSON。
/// 这里是帧的编解码和几种消息的构造 / 解读;连接在 `DiscordIPCConnection`。
public enum DiscordIPC {
    public enum Opcode: UInt32, Sendable {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    public struct Frame: Equatable, Sendable {
        public let opcode: UInt32
        public let payload: Data

        public init(opcode: UInt32, payload: Data) {
            self.opcode = opcode
            self.payload = payload
        }
    }

    /// 一帧载荷的上限。Discord 的回包(READY 带用户资料、SET_ACTIVITY 回显)都在几 KB 以内,超过它当线路坏了。
    public static let maxPayloadBytes = 64 * 1024

    public struct OversizedFrame: Error, Equatable {
        public let length: Int
    }

    public static func encode(_ opcode: Opcode, _ payload: Data) -> Data {
        var data = Data(capacity: 8 + payload.count)
        appendLittleEndian(opcode.rawValue, to: &data)
        appendLittleEndian(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    /// 从缓冲区头上取下一整帧;不够一帧时返回 nil、缓冲区不动。长度超过 `maxPayloadBytes` 抛错。
    public static func takeFrame(from buffer: inout Data) throws -> Frame? {
        guard buffer.count >= 8 else { return nil }
        let header = [UInt8](buffer.prefix(8))
        let length = Int(littleEndian(header, at: 4))
        guard length <= maxPayloadBytes else { throw OversizedFrame(length: length) }
        guard buffer.count >= 8 + length else { return nil }
        let frame = Frame(opcode: littleEndian(header, at: 0), payload: Data(buffer.dropFirst(8).prefix(length)))
        buffer = Data(buffer.dropFirst(8 + length))
        return frame
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
    }

    // MARK: - 消息

    public static func handshake(clientID: String) -> Data {
        json(Handshake(v: 1, clientID: clientID))
    }

    /// SET_ACTIVITY。activity 为 nil 时不带这个键,Discord 清掉这个进程的状态。
    public static func setActivity(_ activity: DiscordActivity?, pid: Int32, nonce: String) -> Data {
        json(Command(cmd: "SET_ACTIVITY", args: SetActivityArgs(pid: pid, activity: activity), nonce: nonce))
    }

    private struct Handshake: Encodable {
        let v: Int
        let clientID: String
        enum CodingKeys: String, CodingKey {
            case v
            case clientID = "client_id"
        }
    }

    private struct Command<Args: Encodable>: Encodable {
        let cmd: String
        let args: Args
        let nonce: String
    }

    private struct SetActivityArgs: Encodable {
        let pid: Int32
        let activity: DiscordActivity?
    }

    private static func json<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    // MARK: - 回包

    /// Discord 发来的一帧是什么。
    public enum Reply: Equatable, Sendable {
        /// 握手成功,带当前登录 Discord 的账号(回包里没有账号信息时为 nil)。
        case ready(user: DiscordUser?)
        /// 命令成功的回执,nonce 对应发出去的那条。
        case ack(nonce: String?)
        /// 命令被拒。
        case error(nonce: String?, code: Int, message: String)
        /// Discord 要关掉这条连接(握手被拒时就是这个),带关闭码和原因。
        case close(code: Int, message: String)
        /// 心跳:原样回一个 pong。
        case ping(Data)
        case other
    }

    public static func reply(to frame: Frame) -> Reply {
        let object = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any]
        switch Opcode(rawValue: frame.opcode) {
        case .ping:
            return .ping(frame.payload)
        case .close:
            return .close(code: integer(object?["code"]), message: object?["message"] as? String ?? "")
        case .frame:
            guard let object else { return .other }
            let data = object["data"] as? [String: Any]
            let nonce = object["nonce"] as? String
            if object["evt"] as? String == "ERROR" {
                return .error(nonce: nonce, code: integer(data?["code"]), message: data?["message"] as? String ?? "")
            }
            if object["cmd"] as? String == "DISPATCH" {
                guard object["evt"] as? String == "READY" else { return .other }
                return .ready(user: user(from: data?["user"] as? [String: Any]))
            }
            return .ack(nonce: nonce)
        default:
            return .other
        }
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    /// READY 里的 `user`。没有 ID 或用户名时当没有;空字符串的字段当没给。
    private static func user(from object: [String: Any]?) -> DiscordUser? {
        func text(_ key: String) -> String? {
            (object?[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let id = text("id"), let username = text("username") else { return nil }
        return DiscordUser(id: id, username: username, globalName: text("global_name"), avatar: text("avatar"),
                           discriminator: text("discriminator"))
    }

    // MARK: - 套接字位置

    /// 本机 Discord 可能在听的套接字:给出的每个临时目录下 `discord-ipc-0`…`9`(正式版、PTB、Canary 同时开着时各占一个号)。
    /// 目录去重,按给出的先后。
    public static func socketPaths(in directories: [String]) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for raw in directories where !raw.isEmpty {
            let directory = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            guard !directory.isEmpty, seen.insert(directory).inserted else { continue }
            paths += (0...9).map { "\(directory)/discord-ipc-\($0)" }
        }
        return paths
    }
}

/// 握手时 Discord 给的账号:这台 Mac 上 Discord 桌面版当前登录的那个。
public struct DiscordUser: Equatable, Sendable {
    public let id: String
    public let username: String
    /// 显示名(`global_name`);没设过时为 nil。
    public let globalName: String?
    /// 头像哈希;没传过头像时为 nil。
    public let avatar: String?
    /// 旧用户名体系的四位编号;新用户名体系是 "0"。
    public let discriminator: String?

    public init(id: String, username: String, globalName: String? = nil, avatar: String? = nil,
                discriminator: String? = nil) {
        self.id = id
        self.username = username
        self.globalName = globalName
        self.avatar = avatar
        self.discriminator = discriminator
    }

    /// 界面上写的名字:有显示名用显示名,没有用用户名。
    public var displayName: String {
        guard let globalName, !globalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return username }
        return globalName
    }

    /// 头像在 Discord 公开 CDN 上的地址。没传过头像时是 Discord 给这个账号的默认头像;ID 不是纯数字时为 nil。
    /// 头像哈希只认 Discord 的格式(32 位小写十六进制,动图前面多一个 `a_`),别的当没有,不往地址里拼。
    public func avatarURL(size: Int = 128) -> URL? {
        guard !id.isEmpty, id.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        if let avatar, Self.isAvatarHash(avatar) {
            return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).png?size=\(size)")
        }
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(defaultAvatarIndex).png")
    }

    /// 默认头像的编号:新用户名体系按 ID 右移 22 位再模 6,旧体系按四位编号模 5。
    var defaultAvatarIndex: Int {
        if let discriminator, discriminator != "0", let number = Int(discriminator) { return abs(number) % 5 }
        return Int(((UInt64(id) ?? 0) >> 22) % 6)
    }

    static func isAvatarHash(_ value: String) -> Bool {
        let hex = value.hasPrefix("a_") ? value.dropFirst(2) : Substring(value)
        return hex.utf8.count == 32 && hex.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// 一条到 Discord 桌面版的本地连接。方法都会阻塞(读写带超时),不是线程安全的,只在调用方自己的串行队列上用。
public final class DiscordIPCConnection {
    public enum Failure: Error, Equatable, Sendable {
        /// 哪个套接字都连不上:Discord 没开。
        case unavailable
        /// Discord 拒绝了握手或这条命令,带它给的代码和原因。命令被拒时连接还在。
        case rejected(code: Int, message: String)
        /// 连接断了、读写出错或超时。连接已经关掉。
        case disconnected(String)
    }

    /// 连上的那个套接字。
    public let path: String
    /// 握手用的应用 ID。
    public let clientID: String
    /// 握手回来的 Discord 账号。
    public private(set) var user: DiscordUser?
    private var fd: Int32
    private var buffer = Data()
    private var nextNonce = 0

    private init(fd: Int32, path: String, clientID: String) {
        self.fd = fd
        self.path = path
        self.clientID = clientID
    }

    deinit {
        close()
    }

    /// 依次试 `paths`,返回第一个连得上、握手成功的。都连不上抛 `unavailable`;连上了但握手被拒抛 `rejected`。
    public static func connect(paths: [String], clientID: String, timeout: TimeInterval) throws -> DiscordIPCConnection {
        for path in paths {
            guard let fd = openSocket(path, timeout: timeout) else { continue }
            let connection = DiscordIPCConnection(fd: fd, path: path, clientID: clientID)
            connection.user = try connection.handshake(clientID: clientID, timeout: timeout)
            return connection
        }
        throw Failure.unavailable
    }

    /// 发一条 SET_ACTIVITY(nil = 清掉)并等它的回执。
    public func setActivity(_ activity: DiscordActivity?, pid: Int32, timeout: TimeInterval) throws {
        nextNonce += 1
        let nonce = String(nextNonce)
        try write(.frame, DiscordIPC.setActivity(activity, pid: pid, nonce: nonce))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch DiscordIPC.reply(to: try readFrame(until: deadline)) {
            case .ack(let replyNonce) where replyNonce == nonce:
                return
            case .error(let replyNonce, let code, let message) where replyNonce == nonce:
                throw Failure.rejected(code: code, message: message)
            case .close(let code, let message):
                close()
                throw Failure.disconnected("closed by Discord (\(code)) \(message)")
            case .ping(let payload):
                try write(.pong, payload)
            default:
                continue
            }
        }
    }

    /// 不等待:把已经到了的帧处理掉(回 pong),顺便确认连接还在。断了抛 `disconnected`。
    public func service() throws {
        while try waitReadable(timeoutMs: 0) {
            try readAvailable()
        }
        while let frame = try takeFrame() {
            switch DiscordIPC.reply(to: frame) {
            case .ping(let payload):
                try write(.pong, payload)
            case .close(let code, let message):
                close()
                throw Failure.disconnected("closed by Discord (\(code)) \(message)")
            default:
                continue
            }
        }
    }

    public func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    // MARK: - 私有

    private func handshake(clientID: String, timeout: TimeInterval) throws -> DiscordUser? {
        try write(.handshake, DiscordIPC.handshake(clientID: clientID))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch DiscordIPC.reply(to: try readFrame(until: deadline)) {
            case .ready(let user):
                return user
            case .close(let code, let message), .error(_, let code, let message):
                close()
                throw Failure.rejected(code: code, message: message)
            case .ping(let payload):
                try write(.pong, payload)
            default:
                continue
            }
        }
    }

    private func write(_ opcode: DiscordIPC.Opcode, _ payload: Data) throws {
        guard fd >= 0 else { throw Failure.disconnected("connection closed") }
        let data = DiscordIPC.encode(opcode, payload)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            let reason = written < 0 ? String(cString: strerror(errno)) : "nothing written"
            close()
            throw Failure.disconnected("write failed: \(reason)")
        }
    }

    private func readFrame(until deadline: Date) throws -> DiscordIPC.Frame {
        while true {
            if let frame = try takeFrame() { return frame }
            let remainingMs = Int32(clamping: Int((deadline.timeIntervalSinceNow * 1000).rounded(.up)))
            guard remainingMs > 0 else {
                close()
                throw Failure.disconnected("timed out waiting for Discord")
            }
            if try waitReadable(timeoutMs: remainingMs) {
                try readAvailable()
            }
        }
    }

    private func takeFrame() throws -> DiscordIPC.Frame? {
        do {
            return try DiscordIPC.takeFrame(from: &buffer)
        } catch {
            close()
            throw Failure.disconnected("bad frame from Discord")
        }
    }

    /// 等到可读(true)或超时(false)。
    private func waitReadable(timeoutMs: Int32) throws -> Bool {
        guard fd >= 0 else { throw Failure.disconnected("connection closed") }
        var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = Darwin.poll(&request, 1, timeoutMs)
            if ready > 0 { return true }
            if ready == 0 { return false }
            if errno == EINTR { continue }
            let reason = String(cString: strerror(errno))
            close()
            throw Failure.disconnected("poll failed: \(reason)")
        }
    }

    private func readAvailable() throws {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                return
            }
            if count < 0, errno == EINTR { continue }
            let reason = count == 0 ? "closed by Discord" : String(cString: strerror(errno))
            close()
            throw Failure.disconnected(reason)
        }
    }

    /// 连上这个套接字;不存在、没人在听返回 nil。写入带超时,Discord 卡住时不会一直等。
    private static func openSocket(_ path: String, timeout: TimeInterval) -> Int32? {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: max(1, Int(timeout.rounded(.up))), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
