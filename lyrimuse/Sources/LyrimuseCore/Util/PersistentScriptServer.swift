import Darwin
import Foundation
import os

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "script-server")

/// 常驻的脚本进程:起一次,之后每次往它的 stdin 写一行请求、从 stdout 读回答,替代「每次起一个子进程跑同一段脚本」
/// (见 02 章决策 111)。
///
/// 协议:请求是一行文字(不含换行)。脚本对每一行先把回答原样写到 stdout,再写结束行 `\n<endMarker> <状态码>\n`;
/// 回答里不能出现 `\n<endMarker> `。状态码照子进程退出码的口径,0 = 成功。
///
/// - 一个进程答满 `recycleAfterRequests` 次就换新的(长跑的脚本进程会涨内存):关掉它的 stdin,`exitGrace` 之后还在就 SIGKILL。
/// - 一次请求超时:SIGKILL 掉进程,这次按超时交回(`timedOut = true`,同 `ProcessRunner`),下次重开。
/// - 起不来、半路退出:这次返回 nil,调用方自己退回每次起子进程那条路。连着 `disableAfterFailures` 次就停用
///   `disabledInterval`,这段时间一律返回 nil、不起进程。
/// - 脚本必须在 stdin 读到 EOF 时自己退出:App 退出(含被杀)时靠这一条不留孤儿。
/// - 请求串行处理,同一时刻只有一次在飞。会阻塞调用线程,别在主线程上调。
public final class PersistentScriptServer: @unchecked Sendable {
    public struct Launch: Sendable {
        public var executable: String
        public var arguments: [String]

        public init(executable: String, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// 换进程时关掉 stdin 之后,等它自己退出多久。
    public static let exitGrace: TimeInterval = 2

    public let label: String
    public let endMarker: String
    public let recycleAfterRequests: Int
    public let disableAfterFailures: Int
    public let disabledInterval: TimeInterval
    private let launch: @Sendable () -> Launch?

    private let lock = NSLock()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var answeredByCurrent = 0
    private var consecutiveFailures = 0
    private var disabledUntil: Date?
    private var launched = 0

    public init(label: String, endMarker: String, recycleAfterRequests: Int,
                disableAfterFailures: Int = 3, disabledInterval: TimeInterval = 600,
                launch: @escaping @Sendable () -> Launch?) {
        self.label = label
        self.endMarker = endMarker
        self.recycleAfterRequests = max(1, recycleAfterRequests)
        self.disableAfterFailures = max(1, disableAfterFailures)
        self.disabledInterval = disabledInterval
        self.launch = launch
    }

    /// 起过几次进程。
    public var launchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return launched
    }

    /// 正在用的那个进程的 pid,没有时为 nil。
    public var currentPID: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process?.processIdentifier
    }

    /// 问一次。nil = 这次用不上(停用中、起不来、半路退出、请求里带换行),调用方自己退回起子进程。
    public func request(_ line: String, timeout: TimeInterval) -> ProcessRunner.Result? {
        guard !line.contains("\n") else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let until = disabledUntil {
            guard Date() >= until else { return nil }
            disabledUntil = nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        if process == nil, !startLocked() { return failLocked("could not start") }
        guard let fd = input?.fileHandleForWriting.fileDescriptor, Self.writeAll(Data((line + "\n").utf8), to: fd) else {
            stopLocked(force: true)
            return failLocked("stdin is closed")
        }
        switch readLocked(until: deadline) {
        case .answered(let status, let body):
            consecutiveFailures = 0
            answeredByCurrent += 1
            if answeredByCurrent >= recycleAfterRequests {
                logger.notice("\(self.label, privacy: .public) recycled after \(self.answeredByCurrent) requests")
                stopLocked(force: false)
            }
            return ProcessRunner.Result(status: status, stdout: body, stderr: Data(), timedOut: false)
        case .timedOut:
            logger.notice("\(self.label, privacy: .public) timed out after \(timeout, format: .fixed(precision: 1))s; killed")
            stopLocked(force: true)
            return ProcessRunner.Result(status: SIGKILL, stdout: Data(), stderr: Data(), timedOut: true)
        case .closed:
            stopLocked(force: true)
            return failLocked("exited before answering")
        }
    }

    /// 关掉当前进程,下一次请求再起。
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked(force: false)
    }

    /// 从读到的字节里切出一次完整的回答:结束行之前是回答,结束行里是状态码,结束行之后的字节原样交回。
    /// 还没读到完整的结束行时为 nil;状态码不是整数按 -1 算。纯函数,selftest 覆盖。
    public static func parseResponse(_ data: Data, endMarker: String) -> (status: Int32, body: Data, rest: Data)? {
        let marker = Data(("\n" + endMarker + " ").utf8)
        guard let found = data.range(of: marker),
              let lineEnd = data[found.upperBound...].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let status = Int32(String(decoding: data[found.upperBound..<lineEnd], as: UTF8.self)) ?? -1
        return (status, Data(data[data.startIndex..<found.lowerBound]), Data(data[(lineEnd + 1)...]))
    }

    // MARK: - 进程

    private func startLocked() -> Bool {
        guard let spec = launch() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("\(self.label, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        launched += 1
        // 对面退出之后再写 stdin 要拿到 EPIPE,不能让 SIGPIPE 把 App 打死;两端都别带进之后起的子进程,
        // 不然关掉 stdin 之后脚本等不到 EOF。
        let writeFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        self.process = process
        self.input = input
        self.output = output
        buffer.removeAll()
        answeredByCurrent = 0
        logger.notice("\(self.label, privacy: .public) started (pid \(process.processIdentifier), launch \(self.launched))")
        return true
    }

    /// `force` = 直接 SIGKILL(超时、对面已经坏了);否则关掉 stdin 让脚本自己退出,宽限过后还在才 SIGKILL。
    private func stopLocked(force: Bool) {
        guard let process else { return }
        let pid = process.processIdentifier
        if force, process.isRunning { Darwin.kill(pid, SIGKILL) }
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        self.process = nil
        input = nil
        output = nil
        buffer.removeAll()
        answeredByCurrent = 0
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.exitGrace) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    private func failLocked(_ reason: String) -> ProcessRunner.Result? {
        consecutiveFailures += 1
        guard consecutiveFailures >= disableAfterFailures else {
            logger.notice("\(self.label, privacy: .public) unavailable (\(reason, privacy: .public)); this request falls back")
            return nil
        }
        consecutiveFailures = 0
        disabledUntil = Date().addingTimeInterval(disabledInterval)
        logger.notice("\(self.label, privacy: .public) disabled for \(Int(self.disabledInterval))s after \(self.disableAfterFailures) failures in a row (last: \(reason, privacy: .public))")
        return nil
    }

    // MARK: - 读写

    private enum ReadOutcome {
        case answered(Int32, Data)
        case timedOut
        case closed
    }

    private func readLocked(until deadline: Date) -> ReadOutcome {
        guard let fd = output?.fileHandleForReading.fileDescriptor else { return .closed }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let parsed = Self.parseResponse(buffer, endMarker: endMarker) {
                buffer = parsed.rest
                return .answered(parsed.status, parsed.body)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timedOut }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pfd, 1, Int32(max(1, min(remaining * 1000, 60_000).rounded(.up))))
            if ready < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            if ready == 0 { continue }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .closed
            }
            if n == 0 { return .closed }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                left -= n
                p = p.advanced(by: n)
            }
            return true
        }
    }
}
