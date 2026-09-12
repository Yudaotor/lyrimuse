import Foundation
import OSLog

// 常驻订阅 media-control 的 Now Playing 变化事件,让"歌换了/暂停了"这类状态不必等下一次
// 2 秒轮询才被发现。
//
// ⚠️ 跟 LocalPlaybackSource 的分布式通知订阅完全同一个设计取舍(见那边
// startObservingPlayerInfoNotification 上那段长注释,这里不重复论证):事件**只当作
// "提前触发一次 poll()"的信号**,一个字段的**数值**都不从 payload 里取来直接喂状态。这个类
// 因此只暴露一个"有动静了"的回调,payload 不往外传。
//
// 唯一的例外(2026-09-07,刻意划得很窄):payload 会被解析,但只为回答"**哪个**锚点、**什么
// 时候**到的"—— 把 artist/title/elapsedTime/timestamp 拼成锚点身份(MediaControlClient.
// anchorKey,跟轮询路径同一个构造),连同这一行**到达的时刻**记进 MediaControlClient 的锚点
// 目击表。之后轮询路径查表拿到"这个锚点几十毫秒前刚打好",据此把整秒时间戳抹掉的小数补回来。
// 位置数值本身仍然全部来自轮询那份快照,状态机没有第二条喂数路径。为什么值得开这个口子:
// media-control 的 timestamp 恒无小数,Spotify 暂停后恢复播放又会让 elapsedTimeNow 不再外推,
// 只剩"elapsedTime + (now − 整秒 ts)"这条路,抹掉的小数(实测 .914/.724/.560)就是那首歌余下
// 部分整段偏快的量;stream 事件在锚点打好后 17~26ms 就到,是这台机器上唯一能把那个小数量出来
// 的东西(通知里 Spotify 自带的位置更直接,但那就真是"从 payload 取数值喂状态"了)。
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
/// `MediaControlStreamWatcher.digest` 的结果:更新后的合并状态,以及这一行若是一次锚点目击时
/// 的身份 / 是否 tight / 到达时锚点整秒时间戳的年龄(秒,解析不出时间戳为 nil)。
public struct MediaControlAnchorDigest {
    public let merged: [String: Any]
    public let anchorKey: String?
    public let tight: Bool
    public let anchorAge: Double?
    /// 这一行带着 `playing:false` —— 播放器在这一刻进入暂停(暂停分支要用这个时刻,见
    /// `MediaControlClient.pausedPositionSeconds(elapsedTime:anchorTimestamp:lastPlaying:pauseObservedAt:now:)`)。
    public let pausedAtArrival: Bool
    /// 这一行把曲目换成了哪一首(`MediaControlSnapshot.trackKey` 那一套)。nil = 这一行没换曲目。
    /// 电台那块曲内表要靠它起表,见 `RadioTrackClock` 头注「起表时刻」一节。
    public let trackChangeKey: String?
    /// 换曲目发生在哪一刻。锚点是**刚打好的**(tight)就用锚点时刻(带亚秒估计),否则只能用这一行的
    /// 到达时刻 —— 陈旧锚点的时刻可能是几分钟前的,当成换歌时刻会把位置推走一大截。
    public let trackChangeAt: Date?

    public init(merged: [String: Any], anchorKey: String?, tight: Bool, anchorAge: Double?,
                pausedAtArrival: Bool = false, trackChangeKey: String? = nil, trackChangeAt: Date? = nil) {
        self.merged = merged
        self.anchorKey = anchorKey
        self.tight = tight
        self.anchorAge = anchorAge
        self.pausedAtArrival = pausedAtArrival
        self.trackChangeKey = trackChangeKey
        self.trackChangeAt = trackChangeAt
    }
}

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
            // 到达时刻在这条读管道的线程上立刻取:hop 到主线程可能被 20Hz 渲染挡住几十毫秒,
            // 而锚点目击要的就是这几十毫秒的精度(见 MediaControlClient.streamAnchorLatency)。
            let arrivedAt = Date()
            guard !chunk.isEmpty else { return } // EOF,交给 terminationHandler 处理
            Task { @MainActor [weak self] in self?.consume(chunk, arrivedAt: arrivedAt) }
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

    /// stream 输出里"当前 Now Playing"的合并状态:`diff:false` 的行整份替换,`diff:true` 的行
    /// 只带变化的字段。只留拼锚点身份要用的四个键(artist/title/elapsedTime/timestamp),别的
    /// 字段一概不存 —— 见文件头那段"唯一的例外"。
    private var mergedPayload: [String: Any] = [:]

    private func consume(_ chunk: Data, arrivedAt: Date) {
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
            let digest = Self.digest(line: Data(line), merged: mergedPayload, arrivedAt: arrivedAt)
            mergedPayload = digest.merged
            if digest.pausedAtArrival {
                MediaControlClient.notePauseObserved(at: arrivedAt)
            }
            if let changed = digest.trackChangeKey, let at = digest.trackChangeAt {
                MediaControlClient.noteTrackChangeObserved(key: changed, at: at)
            }
            if let key = digest.anchorKey {
                MediaControlClient.noteStreamAnchorSighting(anchorKey: key, at: arrivedAt, tight: digest.tight)
                // 每个新锚点一行(换歌/暂停/恢复才有),不是每拍都打。年龄是"到达时锚点整秒时间戳
                // 已经多老",tight 与否就看它。
                Self.logger.notice("anchor sighting tight=\(digest.tight) ageAtArrival=\(digest.anchorAge ?? -1, format: .fixed(precision: 3)) key=\(key, privacy: .public)")
            }
        }
        // 一次回调里来了多行也只触发一次 —— 反正下游是"补查一次 poll()",行数没有意义。
        if fired {
            // 进程能正常吐数据,说明它是活的,把退避计时器复位;否则一次成功启动之后的
            // 偶发退出会带着上一次积累的长延迟重启。
            restartDelay = Self.minRestartDelay
            onEvent()
        }
    }

    /// 消化 stream 的一行:更新合并状态,并判断这一行是不是一次"锚点目击"。纯函数,selftest
    /// 直接覆盖。
    ///
    /// - 行的形状是 `{"type":"data","diff":Bool,"payload":{...}}`;`diff:false` 整份替换合并
    ///   状态(payload 为空 `{}` 时就是"没人在报 Now Playing"),`diff:true` 只合并出现的键,
    ///   值为 null 的键视作删除。
    /// - 只有 payload 里**带了** elapsedTime 或 timestamp 的行才算锚点有变(只翻 playing、只改
    ///   duration 的 diff 不算)。恢复播放的实测形态是 `{elapsedTime, timestamp, playbackRate:null}`,
    ///   曲目要从合并状态里拿。
    /// - tight 的前提是"刚打好被看到":到达时整秒时间戳的年龄 ≤ tightSightingMaxAge。watcher
    ///   (重)启时 media-control 会把当前状态整份吐一遍,里面的锚点可能已经几分钟老,那只能算
    ///   loose(交给中点法),否则会把一个几分钟前的锚点钉到"到达前 25ms"。
    public nonisolated static func digest(line: Data, merged: [String: Any], arrivedAt: Date) -> MediaControlAnchorDigest {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data",
              let payload = object["payload"] as? [String: Any]
        else { return MediaControlAnchorDigest(merged: merged, anchorKey: nil, tight: false, anchorAge: nil) }
        let isDiff = object["diff"] as? Bool ?? false
        var next: [String: Any] = isDiff ? merged : [:]
        for key in ["artist", "title", "elapsedTime", "timestamp"] where payload.keys.contains(key) {
            if payload[key] is NSNull {
                next.removeValue(forKey: key)
            } else {
                next[key] = payload[key]
            }
        }
        // 只看这一行**带不带** playing:false —— 取的是"暂停发生在这一刻"这个时刻,不是状态值本身
        // (状态仍由轮询快照决定,见文件头"唯一的例外")。
        let paused = (payload["playing"] as? Bool) == false
        // 曲目换没换,跟锚点判定完全无关:只带 title/artist 的 diff 行(实测电台换歌就有这种形态)会在
        // 下面那道"没有 elapsedTime/timestamp 就早退"的闸之前返回,所以这一步必须在闸之前算。
        let changed = changedTrackKey(before: merged, after: next)
        guard payload.keys.contains("elapsedTime") || payload.keys.contains("timestamp") else {
            return MediaControlAnchorDigest(merged: next, anchorKey: nil, tight: false, anchorAge: nil,
                                            pausedAtArrival: paused,
                                            trackChangeKey: changed, trackChangeAt: changed == nil ? nil : arrivedAt)
        }
        let elapsed = (next["elapsedTime"] as? NSNumber)?.doubleValue
        let timestamp = next["timestamp"] as? String
        guard elapsed != nil || timestamp != nil else {
            return MediaControlAnchorDigest(merged: next, anchorKey: nil, tight: false, anchorAge: nil,
                                            pausedAtArrival: paused,
                                            trackChangeKey: changed, trackChangeAt: changed == nil ? nil : arrivedAt)
        }
        let key = MediaControlClient.anchorKey(
            artist: next["artist"] as? String, title: next["title"] as? String,
            elapsedTime: elapsed, timestamp: timestamp)
        let age = MediaControlClient.parseTimestamp(timestamp).map { arrivedAt.timeIntervalSince($0) }
        // 年龄略负(时钟毛刺)也放行;没有可解析的时间戳就没法判"刚打好",只能 loose。
        let tight = age.map { $0 >= -1 && $0 <= MediaControlClient.tightSightingMaxAge } ?? false
        return MediaControlAnchorDigest(merged: next, anchorKey: key, tight: tight, anchorAge: age,
                                        pausedAtArrival: paused, trackChangeKey: changed,
                                        trackChangeAt: changed == nil ? nil
                                            : trackChangeInstant(anchorTimestamp: MediaControlClient.parseTimestamp(timestamp),
                                                                 tight: tight, arrivedAt: arrivedAt))
    }

    /// 合并状态里的曲目换了没有。纯函数,selftest 直接覆盖。
    ///
    /// 换到**空标题**不算换歌:电台切台/加载中实测会先吐几行 `title` 为空、只有 artist 的载荷
    /// (2026-09-10 日志里 `|NCT 127|0.000` 那三行),把它当一首歌会白起一次表。
    public nonisolated static func changedTrackKey(before: [String: Any], after: [String: Any]) -> String? {
        let title = (after["title"] as? String) ?? ""
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let now = MediaControlSnapshot.trackKey(artist: after["artist"] as? String, title: title)
        let was = MediaControlSnapshot.trackKey(artist: before["artist"] as? String, title: before["title"] as? String)
        return now == was ? nil : now
    }

    /// 换歌发生在哪一刻。纯函数,selftest 直接覆盖。
    ///
    /// 锚点刚打好(tight)时它就是这次换歌的时刻,而且比"这一行到达"更早、更准 —— 整秒时间戳的亚秒
    /// 部分交给 `estimatedAnchorInstant` 估(那套已经在用了)。锚点陈旧(电台换歌常见:系统压根没重打
    /// 锚点,实测 age 236s / 487s)时只能退回到达时刻,绝不能拿几分钟前的锚点当换歌时刻。
    public nonisolated static func trackChangeInstant(anchorTimestamp: Date?, tight: Bool, arrivedAt: Date) -> Date {
        guard tight, let anchorTimestamp else { return arrivedAt }
        let instant = MediaControlClient.estimatedAnchorInstant(
            timestamp: anchorTimestamp,
            sighting: MediaControlClient.AnchorSighting(at: arrivedAt, tight: true))
        return min(instant, arrivedAt)
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
