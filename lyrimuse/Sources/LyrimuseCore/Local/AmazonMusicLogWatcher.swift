import Foundation
import os

/// 盯着 Amazon Music 的日志,把里面的播放事件实时喂给 `AmazonMusicPlayhead`,并在两层之间给出这一拍的位置。
///
/// - 第一次用到时(见到第一份 Amazon Music 快照)才开始:先重放日志末尾一段,把当前这首的状态找回来(App 在歌曲
///   中途重启也接得上),之后挂文件事件,有新行就读。
/// - 实时读到的行按「读到的那一刻」计时,但不晚于行首那一秒的末尾:读晚了(文件事件漏了、下一拍轮询才补读)
///   误差也不超过一秒。
/// - 暂停 / 恢复 / 拖动 / 开播 / 卡顿都会调 `onPlaybackEvent`,调用方借它立刻补一次轮询:拖动在系统 Now Playing
///   里没有任何通知,不靠这里就要等下一拍。
/// - 文件变短(Amazon Music 重启后重写)或被换掉就从头读。
/// - 自动连播开头的那首(`AmazonMusicPlayhead.needsLeadCalibration`)开播 `calibrationDelay` 之后,在后台读一次 Amazon 界面上的
///   播放时间校准提前量(`AmazonMusicUIProbe`);没有辅助功能权限就不校准。读不到隔 `calibrationRetry` 再试,最多
///   `calibrationMaxAttempts` 次。校准过的一段隔 `AmazonMusicPlayhead.leadRefineDelay` 再对一次,两次的区间叠窄
///   (`needsLeadRefinement`)。校准结果写进 `AmazonMusicLeadFile` 给 collector。
///
/// 规则本身在 `AmazonMusicPlayhead`(纯函数),这里只管读文件和记账。
public final class AmazonMusicLogWatcher: @unchecked Sendable {
    public static let shared = AmazonMusicLogWatcher()

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "amazon-music")
    /// 第一次读只看末尾这么多字节(一份日志一天能长到几 MB),但至少从最后一次开播读起,见 `AmazonMusicPlayhead.replayStart`。
    static let initialTailBytes = 256 << 10
    /// 日志不存在(没装 / 还没启动)时隔多久再看一眼。
    static let missingRetry: TimeInterval = 10
    /// 开播后隔多久开始校准。自动连播时开播后头几秒还在放上一首的尾巴,界面停在 `00:00`,探针自己等它走起来
    /// (`AmazonMusicUIProbe.startWait`);这里只让界面先换到这一首。没有前奏的歌开口就唱,别把它调回几秒。
    static let calibrationDelay: TimeInterval = 1
    /// 卡顿(含暂停后恢复跟着的那次)平息后隔多久重新校准。探针自己会丢掉界面停住那几次的读数,不用等太久。
    static let stallSettleDelay: TimeInterval = 0.5
    static let calibrationRetry: TimeInterval = 5
    static let calibrationMaxAttempts = 3
    /// 同一件事试满 `calibrationMaxAttempts` 次还没成,之后隔这么久再试一次,不放弃(连着卡顿时前几次常被打断)。
    static let calibrationBackoff: TimeInterval = 30

    /// 播放事件回调(暂停 = true 表示这一下可能让播放停了)。在私有队列上调用。
    public nonisolated(unsafe) static var onPlaybackEvent: (@Sendable (_ pause: Bool) -> Void)?

    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.amazon-music-log")
    private let lock = NSLock()
    private let path: String

    // 以下只在 queue 上读写。
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var started = false

    // 以下在 lock 里读写。
    private var state = AmazonMusicPlayhead.State()
    private var seenEvent = false
    private var fileAvailable = false
    private var timer: AmazonMusicPlayhead.SelfTimer?
    private var lastSource: AmazonMusicPlayhead.Source?
    private var calibrating = false
    /// 这首(曲目 + 开播时刻)试过几次、上次是什么时候。
    private var calibrationAttempts: (key: String, count: Int, lastAt: Date)?
    /// 自记时层:这首第一次落到自记时的时刻,以及已经按界面对过表的那件事(曲目键 + 最近一次卡顿)。
    private var timerSeen: (key: String, at: Date)?
    private var timerCalibratedKey: String?
    private let calibrationQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.amazon-music-ui")

    public init(path: String = AmazonMusicLogWatcher.defaultPath) {
        self.path = path
    }

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Amazon Music/Logs/AmazonMusic.log").path
    }

    /// 幂等。见到 Amazon Music 的快照时调用。
    public func ensureStarted() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            open(replay: true)
        }
    }

    /// 这一拍的位置。`pauseObservedAt` 是 stream watcher 记下的最近一次暂停时刻(自记时层用它把暂停落在
    /// 真正发生的那一刻,而不是这一拍轮询的时刻)。
    public func reading(trackKey: String, metadataTimestamp: Date?, playing: Bool, pauseObservedAt: Date?,
                        now: Date, pid: pid_t? = nil, duration: Double? = nil,
                        artist: String? = nil, title: String? = nil) -> AmazonMusicPlayhead.Reading {
        queue.sync { drain(live: true) }
        lock.lock()
        defer { lock.unlock() }
        // 起点换成系统时间戳这一步记进状态,别只在出位置时临时换:之后到的暂停 / 卡顿按状态里的起点记停表位置,
        // 两边起点不同(实测差近 1 秒)暂停那一下就跳一截。
        if AmazonMusicPlayhead.logCovers(state, metadataTimestamp: metadataTimestamp) {
            state = AmazonMusicPlayhead.calibrated(state, metadataTimestamp: metadataTimestamp)
        }
        var observedAt = now
        if !playing, let pauseObservedAt, now.timeIntervalSince(pauseObservedAt) < 3,
           pauseObservedAt <= now { observedAt = pauseObservedAt }
        timer = AmazonMusicPlayhead.advance(timer, trackKey: trackKey, metadataTimestamp: metadataTimestamp,
                                            playing: playing, observedAt: observedAt)
        let log = fileAvailable && seenEvent ? state : nil
        let r = AmazonMusicPlayhead.reading(log: log, timer: timer!, metadataTimestamp: metadataTimestamp, now: now)
        if !r.staleMetadata, r.source != lastSource {
            lastSource = r.source
            Self.logger.notice("amazon music clock: position from \(r.source.rawValue, privacy: .public)")
        }
        if r.source == .log, playing, let pid { scheduleCalibrationLocked(pid: pid, duration: duration, metadataTimestamp: metadataTimestamp, now: now) }
        if r.source == .selfTimer, playing, let pid {
            scheduleTimerCalibrationLocked(pid: pid, duration: duration, trackKey: trackKey, artist: artist, title: title, now: now)
        }
        return r
    }

    /// 同一件事已经试了 `count` 次、上次在 `lastAt`,现在能不能再试:前 `calibrationMaxAttempts` 次隔 `calibrationRetry`,
    /// 之后隔 `calibrationBackoff`,不放弃。纯函数。
    public static func mayRetryCalibration(count: Int, lastAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastAt) >= (count < calibrationMaxAttempts ? calibrationRetry : calibrationBackoff)
    }

    private func mayAttemptLocked(_ key: String, now: Date) -> Bool {
        if let a = calibrationAttempts, a.key == key {
            guard Self.mayRetryCalibration(count: a.count, lastAt: a.lastAt, now: now) else { return false }
            calibrationAttempts = (key, a.count + 1, now)
        } else {
            calibrationAttempts = (key, 1, now)
        }
        return true
    }

    // MARK: - 自记时层的界面对表(lock 里调)

    /// 日志对不上这首(Amazon 重写 / 轮转了日志、它自己重启过)时位置落到自记时,自记时看不见卡顿,也不知道这之前的暂停,
    /// 最容易错。界面上的播放时间就是真值:落到自记时 `calibrationDelay` 之后对一次表,之后每次卡顿平息再对一次
    /// (卡顿行照样出现在日志里,只是认不出是哪一首)。对上就把自记时整个换成界面给的位置,并写给 collector。
    private func scheduleTimerCalibrationLocked(pid: pid_t, duration: Double?, trackKey: String, artist: String?, title: String?, now: Date) {
        if timerSeen?.key != trackKey { timerSeen = (trackKey, now) }
        guard !calibrating, let seen = timerSeen, now.timeIntervalSince(seen.at) >= Self.calibrationDelay,
              state.lastStallAt.map({ now.timeIntervalSince($0) >= Self.stallSettleDelay }) ?? true else { return }
        let key = "timer:" + trackKey + "#" + String(max(state.lastStallAt?.timeIntervalSince1970 ?? 0, seen.at.timeIntervalSince1970))
        guard timerCalibratedKey != key, mayAttemptLocked(key, now: now) else { return }
        calibrating = true
        let stallBefore = state.lastStallAt
        calibrationQueue.async { [self] in
            let result = AmazonMusicUIProbe.sampleOrigin(pid: pid, duration: duration) { [self] in
                lock.lock()
                defer { lock.unlock() }
                return timer?.trackKey == trackKey
            }
            lock.lock()
            calibrating = false
            let now = Date()
            guard case .success(let range) = result, timer?.trackKey == trackKey, timer?.since != nil,
                  state.lastStallAt == stallBefore else {
                lock.unlock()
                if case .failure(let f) = result {
                    Self.logger.notice("amazon music clock: self-timer calibration failed: \(f.reason.rawValue, privacy: .public)")
                }
                return
            }
            let position = max(0, now.timeIntervalSince1970 - (range.lowerBound + range.upperBound) / 2)
            let before = timer?.position(at: now) ?? 0
            timer = AmazonMusicPlayhead.SelfTimer(trackKey: trackKey, base: position, since: now)
            timerCalibratedKey = key
            lock.unlock()
            Self.logger.notice("amazon music clock: self-timer set from the screen: \(before, format: .fixed(precision: 2))s -> \(position, format: .fixed(precision: 2))s")
            if let artist, let title {
                AmazonMusicLeadFile.write(.init(trackID: "", startedAtMs: 0, leadSecs: 0,
                                                writtenAtMs: Int64(now.timeIntervalSince1970 * 1000),
                                                artist: artist, title: title, positionSecs: position))
            }
            Self.onPlaybackEvent?(false)
        }
    }

    // MARK: - 自动连播提前量的界面校准(lock 里调)

    private func scheduleCalibrationLocked(pid: pid_t, duration: Double?, metadataTimestamp: Date?, now: Date) {
        let refining = AmazonMusicPlayhead.needsLeadRefinement(state, now: now)
        guard !calibrating, AmazonMusicPlayhead.needsLeadCalibration(state) || refining, let id = state.trackID,
              let startedAt = state.trackStartedAt, now.timeIntervalSince(startedAt) >= Self.calibrationDelay,
              state.lastStallAt.map({ now.timeIntervalSince($0) >= Self.stallSettleDelay }) ?? true else { return }
        // 卡顿之后的那次重新校准、首次校准之后再叠的那次,都另算次数(键带上最近一次卡顿的时刻、叠到第几次)。
        let key = id + "@" + String(startedAt.timeIntervalSince1970) + "#" + String(state.lastStallAt?.timeIntervalSince1970 ?? 0)
            + (refining ? "+" + String(state.leadRefinements + 1) : "")
        guard mayAttemptLocked(key, now: now) else { return }
        calibrating = true
        let stallBefore = state.lastStallAt
        let timelineOrigin = AmazonMusicPlayhead.engineTimelinePosition(state, at: now).map { now.addingTimeInterval(-$0) }
        calibrationQueue.async { [self] in
            let result = AmazonMusicUIProbe.sampleOrigin(pid: pid, duration: duration, timelineOrigin: timelineOrigin) { [self] in
                lock.lock()
                defer { lock.unlock() }
                return state.trackID == id && state.trackStartedAt == startedAt
            }
            let origin = try? result.get()
            lock.lock()
            calibrating = false
            guard state.trackID == id, state.trackStartedAt == startedAt else {
                lock.unlock()
                return
            }
            // 读界面期间又卡顿 / 暂停过:读数跨了两段时间轴,这次作废,平息后重来(新卡顿另算次数)。
            guard state.lastStallAt == stallBefore, !state.paused else {
                lock.unlock()
                Self.logger.notice("amazon music lead: calibration discarded: playback stalled or paused while reading the screen")
                return
            }
            let now = Date()
            guard let origin,
                  let done = AmazonMusicPlayhead.calibratingLead(
                    AmazonMusicPlayhead.calibrated(state, metadataTimestamp: metadataTimestamp), origin: origin, at: now) else {
                lock.unlock()
                let why: String
                switch result {
                case .failure(let f): why = "\(f.reason.rawValue) after \(f.samples) readings" + (f.detail.map { " (\($0))" } ?? "")
                case .success(let o): why = String(format: "lead out of range (origin %.3f)", (o.lowerBound + o.upperBound) / 2)
                }
                Self.logger.notice("amazon music lead: calibration failed: \(why, privacy: .public)")
                return
            }
            state.audibleLead = done.audibleLead
            state.leadRange = done.leadRange
            state.leadCalibratedAt = done.leadCalibratedAt
            state.leadRefinements = done.leadRefinements
            state.leadCalibrated = true
            state.stalledSinceCalibration = false
            let lead = done.audibleLead
            let width = done.leadRange.map { $0.upperBound - $0.lowerBound } ?? 0
            let ui = Int((now.timeIntervalSince1970 - (origin.lowerBound + origin.upperBound) / 2).rounded(.down))
            lock.unlock()
            Self.logger.notice("amazon music lead: log clock is \(lead, format: .fixed(precision: 2))s ahead of the audio, subtracting it (ui=\(ui, privacy: .public)s natural=\(done.startedNaturally, privacy: .public) origin=\((origin.lowerBound + origin.upperBound) / 2, format: .fixed(precision: 3)) width=\(width, format: .fixed(precision: 2)) pass=\(done.leadRefinements + 1, privacy: .public))")
            AmazonMusicLeadFile.write(.init(trackID: id, startedAtMs: Int64(startedAt.timeIntervalSince1970 * 1000),
                                            leadSecs: lead, writtenAtMs: Int64(Date().timeIntervalSince1970 * 1000)))
            Self.onPlaybackEvent?(false)
        }
    }

    // MARK: - 读文件(queue 上)

    private func open(replay: Bool) {
        source?.cancel()
        source = nil
        try? handle?.close()
        handle = nil
        guard let h = FileHandle(forReadingAtPath: path) else {
            setAvailable(false)
            queue.asyncAfter(deadline: .now() + Self.missingRetry) { [weak self] in
                guard let self, self.handle == nil else { return }
                self.open(replay: true)
            }
            return
        }
        handle = h
        setAvailable(true)
        let size = (try? h.seekToEnd()) ?? 0
        offset = 0
        if replay, size > UInt64(Self.initialTailBytes) {
            try? h.seek(toOffset: 0)
            let all = (try? h.readToEnd()) ?? Data()
            offset = UInt64(AmazonMusicPlayhead.replayStart(all, tailBytes: Self.initialTailBytes))
        }
        partial = Data()
        lock.lock()
        state = AmazonMusicPlayhead.State()
        seenEvent = false
        lock.unlock()
        drain(live: !replay)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: h.fileDescriptor, eventMask: [.extend, .write, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.open(replay: false)
            } else {
                self.drain(live: true)
            }
        }
        source = src
        src.resume()
    }

    private func setAvailable(_ available: Bool) {
        lock.lock()
        fileAvailable = available
        lock.unlock()
    }

    /// 把新写的部分读完并推进状态。`live` = 这些行是刚写的(按读到的时刻计),否则是历史(按行首 + 0.5)。
    private func drain(live: Bool) {
        guard let handle else { return }
        let size = (try? handle.seekToEnd()) ?? offset
        if size < offset {
            // Amazon Music 重启后重写了日志:从头读,这些行都是刚写的。
            offset = 0
            partial = Data()
            lock.lock()
            state = AmazonMusicPlayhead.State()
            seenEvent = false
            lock.unlock()
        }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.read(upToCount: Int(size - offset)), !chunk.isEmpty else { return }
        offset += UInt64(chunk.count)
        var data = partial
        data.append(chunk)
        guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else {
            partial = data
            return
        }
        partial = Data(data[data.index(after: last)...])
        let text = String(decoding: data[..<last], as: UTF8.self)
        let readAt = Date()
        var events: [AmazonMusicPlayhead.Event] = []
        lock.lock()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let (lineTime, event) = AmazonMusicPlayhead.parse(line: String(line)) else { continue }
            let at = live
                ? min(readAt, lineTime.addingTimeInterval(1))
                : lineTime.addingTimeInterval(AmazonMusicPlayhead.replayedLineOffset)
            state = AmazonMusicPlayhead.apply(event, at: max(at, lineTime), to: state)
            seenEvent = true
            events.append(event)
        }
        lock.unlock()
        guard live, !events.isEmpty, let onPlaybackEvent = Self.onPlaybackEvent else { return }
        onPlaybackEvent(events.contains(.paused) || events.contains(.stall(true)))
    }
}

/// App → collector:自动连播那首校准出的提前量(collector 读不了界面,见 AmazonMusicUIProbe)。跟 Go 侧 amazonmusic.go
/// `amazonLeadFileName` 逐字节一致,字段名同 json tag。只对同一首(日志曲目标识 + 开播时刻)生效。
public struct AmazonMusicLeadRecord: Codable, Equatable, Sendable {
    public var trackID: String
    public var startedAtMs: Int64
    public var leadSecs: Double
    public var writtenAtMs: Int64
    /// 自记时层按界面对的表:这一首(歌手 + 歌名,collector 按它认)在 `writtenAtMs` 那一刻的真实位置。提前量那种记录不带。
    public var artist: String?
    public var title: String?
    public var positionSecs: Double?

    public init(trackID: String, startedAtMs: Int64, leadSecs: Double, writtenAtMs: Int64,
                artist: String? = nil, title: String? = nil, positionSecs: Double? = nil) {
        self.trackID = trackID
        self.startedAtMs = startedAtMs
        self.leadSecs = leadSecs
        self.writtenAtMs = writtenAtMs
        self.artist = artist
        self.title = title
        self.positionSecs = positionSecs
    }

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case startedAtMs = "started_at_ms"
        case leadSecs = "lead_secs"
        case writtenAtMs = "written_at_ms"
        case artist, title
        case positionSecs = "position_secs"
    }
}

public enum AmazonMusicLeadFile {
    public static let fileName = "lyrimuse-amazon-lead.json"
    public static var url: URL { LyrimusePaths.configFile(fileName) }

    public static func write(_ record: AmazonMusicLeadRecord) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
