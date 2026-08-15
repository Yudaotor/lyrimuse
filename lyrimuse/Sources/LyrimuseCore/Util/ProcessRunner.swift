import Foundation

/// 跑一个外部命令,拿到退出码和 stdout,**并且保证它不会永远卡在那儿**。
///
/// 为什么需要它:这个 App 靠子进程干活 —— osascript 问 Music/Spotify 要播放状态,
/// media-control 读系统 Now Playing。原来每个调用点都是自己 new 一个 Process、
/// `waitUntilExit()` 等到天荒地老,**一处超时都没有**。
///
/// AppleScript 的默认超时是 60 秒:Music.app 一旦无响应(大曲库、iCloud 同步时不算罕见),
/// 一次 osascript 就能把这条链路堵满一分钟,表现为悬浮歌词莫名其妙停住。
/// (verse-bar 那个项目的轮询代码里记着同一类教训:对挂起的浏览器标签页执行 JS
/// "can hang the polling loop for minutes"。)
///
/// 另外统一修掉一个到处都在犯的错:那些调用点都写 `process.standardError = Pipe()`
/// 然后**从不读它**。管道缓冲区(64KB)一满,子进程就阻塞在 write 上不退出,而父进程正卡在
/// waitUntilExit 等它退出 —— 互相等死。只是 osascript/media-control 平时输出很小才没炸。
/// 这里 stderr 直接丢 nullDevice:调用方要的信息退出码和 stdout 已经给全了。
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        /// 超时被杀掉的。此时 status 没有意义(是被信号终止的),调用方应该当作失败。
        public let timedOut: Bool

        public var succeeded: Bool { status == 0 && !timedOut }
        public var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    }

    /// 同步跑完一条命令。**会阻塞到子进程结束或超时**,别在主线程上调。
    ///
    /// 返回 nil 只代表"进程根本没起来"(可执行文件不存在/没有执行权限),跟"跑了但失败"
    /// 是两回事,后者由 Result.status 表达。
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // 到点就杀。用 DispatchWorkItem 而不是起一个 sleep 线程 —— 正常结束时
        // cancel() 掉,不留悬挂的定时器。
        //
        // timedOut 用一个显式标志,不靠 terminationReason 反推:被我们杀掉是
        // .uncaughtSignal,但**进程自己崩溃也是**,两者混在一起会把 crash 报成超时。
        let flag = TimeoutFlag()
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            flag.fire()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        // ⚠️ 顺序:先把管道读空,再 waitUntilExit()。反过来的话,子进程写满 64KB 缓冲区
        // 之后会阻塞在 write 上永远不退出,而我们正等着它退出。被 terminate 杀掉时管道
        // 关闭,这里的读也会正常返回,不会挂住。
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        return Result(status: process.terminationStatus, stdout: data, timedOut: flag.fired)
    }
}

/// "超时那一刻真的开火了没有"的线程安全标志。杀进程的动作发生在 Dispatch 队列上,
/// 读取发生在调用线程,两边必须有同步。
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func fire() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
