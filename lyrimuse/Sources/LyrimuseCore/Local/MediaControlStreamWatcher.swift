import Foundation
import OSLog

// 常驻订阅 media-control 的 Now Playing 变化事件,让"歌换了/暂停了"这类状态不必等下一次
// 2 秒轮询才被发现。
//
// ⚠️ 跟 LocalPlaybackSource 的分布式通知订阅完全同一个设计取舍(见那边
// startObservingPlayerInfoNotification 上那段长注释,这里不重复论证):事件**只当作
// "提前触发一次 poll()"的信号**,一个字段都不从 payload 里取来直接喂状态。这个类因此
// 只暴露一个"有动静了"的回调,连 payload 都不往外传 —— 把它解析出来放在手边,下一个人
// 就会忍不住拿它抄近路,那正是要避的东西。
//
// 为什么值得常驻一个子进程:实测(2026-08-16,稳定播放 20 秒)stream 只在**状态变化**时
// 输出,稳定播放期间一行都不推 —— 也就是说它平时不消耗 CPU,却把 QQ 音乐/网易云的换歌
// 感知从最坏 2 秒降到亚秒。⚠️ 它**没有**省掉轮询那边的 fork:事件只用来"提前触发一次
// poll()",轮询 Timer 每一拍照样 fork(这行注释原来声称"稳定播放期 fork 开销也省掉了",
// 2026-08-20 性能审计核实与实现不符,已订正)——轮询的降频靠的是 LocalPlaybackSource
// 的按播放态分档(见 PollInterval),事件唤醒是分档敢降下去的安全网。
//
// 为什么不去掉 2 秒轮询:这个子进程可能因为任何原因死掉(私有框架被系统更新改动、被
// 用户 kill、沙盒策略变化)。留着轮询,最坏情况只是退化回改动前的行为,而不是歌词彻底
// 停住 —— 跟通知订阅那边"Timer 继续独立运行作兜底"是同一条原则。
@MainActor
public final class MediaControlStreamWatcher {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "mc-stream")

    /// 退避重启的上下限。首次失败等 1 秒,之后翻倍,封顶 30 秒 —— 私有框架整个失效时
    /// 不该每秒重启一个必然失败的子进程刷屏。
    private static let minRestartDelay: TimeInterval = 1
    private static let maxRestartDelay: TimeInterval = 30

    private let onEvent: () -> Void
    private var process: Process?
    private var restartWork: DispatchWorkItem?
    private var restartDelay: TimeInterval = MediaControlStreamWatcher.minRestartDelay
    private var stopped = true
    /// 按行切分用的残留缓冲:管道给的是任意大小的数据块,一行 JSON 完全可能跨两次回调。
    private var buffer = Data()

    public init(onEvent: @escaping () -> Void) {
        self.onEvent = onEvent
    }

    public func start() {
        guard stopped else { return }
        stopped = false
        restartDelay = Self.minRestartDelay
        launch()
    }

    public func stop() {
        stopped = true
        restartWork?.cancel()
        restartWork = nil
        teardownProcess()
    }

    private func teardownProcess() {
        guard let process else { return }
        self.process = nil
        // ⚠️ 先摘掉两个回调再终止:否则终止本身会触发 readabilityHandler(EOF)和
        // terminationHandler,而那两个闭包会把已经被我们主动停掉的进程当成"意外退出"
        // 重新拉起来,stop() 就变成了"重启"。
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        buffer.removeAll()
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        guard let binary = MediaControlClient.binaryPath() else {
            // 没走 build.sh 打包时(直接 swift build 跑)拿不到二进制。这不是错误,
            // 轮询兜底照常工作,只是没有事件加速。
            Self.logger.info("media-control binary unavailable; staying on the 2s poll only")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // --no-artwork:封面数据在这条路上纯属浪费 —— 事件只当触发信号,payload 一概不读,
        // 而封面是几百 KB 的 base64,每次状态变化都白白经过管道。
        proc.arguments = ["stream", "--no-artwork"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return } // EOF,交给 terminationHandler 处理
            Task { @MainActor [weak self] in self?.consume(chunk) }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTermination() }
        }

        do {
            try proc.run()
            process = proc
            Self.logger.info("media-control stream started (pid \(proc.processIdentifier))")
        } catch {
            Self.logger.error("failed to start media-control stream: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func consume(_ chunk: Data) {
        guard !stopped else { return }
        buffer.append(chunk)
        // 一次回调可能带回多行,也可能只带回半行。只对**完整的**行(以 \n 结尾)做处理,
        // 剩下的半行留在 buffer 里等下一块数据。
        var fired = false
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            fired = true
        }
        // 一次回调里来了多行也只触发一次 —— 反正下游是"补查一次 poll()",行数没有意义。
        if fired {
            // 进程能正常吐数据,说明它是活的,把退避计时器复位;否则一次成功启动之后的
            // 偶发退出会带着上一次积累的长延迟重启。
            restartDelay = Self.minRestartDelay
            onEvent()
        }
    }

    private func handleTermination() {
        guard !stopped else { return }
        Self.logger.info("media-control stream exited; restarting in \(self.restartDelay, format: .fixed(precision: 1))s")
        process = nil
        buffer.removeAll()
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopped, restartWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork = nil
            self.launch()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: work)
        restartDelay = min(restartDelay * 2, Self.maxRestartDelay)
    }
}
