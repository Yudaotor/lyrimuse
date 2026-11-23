import Foundation

/// iPad 版酷狗(iOS 应用跑在 Apple 芯片 Mac 上,bundle id `com.kugou.kugou1002`)报给系统的 Now Playing,在按酷狗 Mac 版认
/// (`PlayerBundleAliases`)之前补上它漏报、晚报的恢复播放。
///
/// 系统的「播放」指令(`play`,不是 `toggle-play-pause`)恢复时,它先只换一次时间戳(速率、进度都不变),声音随即接着放:
/// - 暂停不久(实测 6 秒以内)就到此为止,速率一直报 0,系统当它还暂停着;
/// - 暂停久了(实测 8 秒以上)约 0.55 秒后再补一份速率 1、进度只比暂停处多 0.02 秒的锚点,按它推出的起点比真实晚约 0.49 秒;
///   暂停中跳转过再按「播放」的那一份不带进度,晚约 0.47 秒。
///
/// 所以:暂停帧(或跳转那一帧)之后过了 `resumeGapSecs` 以上、同一首同一进度只换了时间戳的,当作从那个时刻起在放;紧跟着补来的
/// 那份速率 1 的锚点,时刻往前挪 `lateResumeFrameSecs`。暂停中跳转后约 0.57 秒它也会只换一次时间戳(没开播),比
/// `resumeGapSecs` 短,不算。`toggle-play-pause`、它自己界面上的播放键恢复时当场报速率 1,不经这里。
///
/// 换到听过一半的听书单集时,它先报一帧进度 0 的开播整帧,约 0.57 秒后才跳到上次听到的位置,按跳过去那一帧推出的起点晚约
/// 0.455 秒(真实从开播整帧之后约 0.12 秒起放):开播整帧之后 `resumeJumpWindowSecs` 之内同一首跳到 1 秒以后的那一帧,时刻往前挪
/// `lateResumeJumpSecs`(`resumedJump`)。
///
/// 放着歌拖进度时,跳转那一帧比真实从那个位置放起早 0.12~0.17 秒:进度跟上一帧对不上的那一帧(不是开播、换歌、续播那几种),
/// 时刻往后挪 `seekFrameLeadSecs`(`seekedWhilePlaying`)。
///
/// 轮询、媒体事件流、单问会话三条路都过这里,记住的那份共用;同一帧再过一次结果不变,先后到也一样(同一个进度只记最早的时刻)。
/// 见 02 章决策 292。
public enum KugouIPadNowPlaying {
    public static let bundleID = "com.kugou.kugou1002"

    /// 只换时间戳的那一帧离这个进度第一次出现隔了多久以上才算恢复。暂停中跳转后的那一次实测 0.57 秒,恢复最快见过 0.93 秒。
    public static let resumeGapSecs: TimeInterval = 0.8
    /// 恢复后补来的那份速率 1 的锚点晚多少:带进度的 0.489~0.506 秒(7 次),不带进度的 0.467~0.468 秒(3 次)。
    public static let lateResumeFrameSecs: TimeInterval = 0.49
    /// 补来的那份最晚在恢复帧之后多久到(实测 0.55~0.62 秒)。
    static let lateResumeFrameWindowSecs: TimeInterval = 1.2
    /// 补来的那份进度最多比暂停处多多少(实测 0~0.02 秒)。
    static let lateResumeElapsedSlackSecs: Double = 0.1
    /// 换到听过一半的单集时跳到上次位置的那一帧晚多少:0.448~0.463 秒(4 次)。
    public static let lateResumeJumpSecs: TimeInterval = 0.455
    /// 跳过去那一帧在开播整帧之后多久之内到(实测 0.57 秒)。
    static let resumeJumpWindowSecs: TimeInterval = 1.0
    /// 放着歌拖进度时跳转那一帧早多少:0.123~0.167 秒(5 次,中位 0.143)。
    public static let seekFrameLeadSecs: TimeInterval = 0.14
    /// 进度跟按上一帧推出来的差多少以上才算跳转。
    static let seekJumpSecs: Double = 1.0

    public struct Frame: Equatable, Sendable {
        public var title: String?
        public var elapsed: Double?
        public var timestamp: Date?
        public var rate: Double?
        public var playing: Bool?

        public init(title: String?, elapsed: Double?, timestamp: Date?, rate: Double?, playing: Bool?) {
            self.title = title
            self.elapsed = elapsed
            self.timestamp = timestamp
            self.rate = rate
            self.playing = playing
        }
    }

    /// 记住的那份:停在哪一首的哪个进度、这个进度最早出现在什么时刻,以及认出的那次恢复。
    public struct Memory: Equatable, Sendable {
        var title: String
        var elapsed: Double
        var since: Date
        var resumedAt: Date?

        public init(title: String, elapsed: Double, since: Date, resumedAt: Date? = nil) {
            self.title = title
            self.elapsed = elapsed
            self.since = since
            self.resumedAt = resumedAt
        }
    }

    /// 最近一次开播整帧(进度 0)是哪一首、什么时刻。
    public struct Start: Equatable, Sendable {
        var title: String
        var at: Date

        public init(title: String, at: Date) {
            self.title = title
            self.at = at
        }
    }

    /// 见到的最新一帧(原样报的):哪一首、进度、时刻、速率,以及最近几份认成跳转的帧的时刻(轮询晚一步再读到它时照样挪)。
    public struct Last: Equatable, Sendable {
        var title: String
        var elapsed: Double
        var at: Date
        var rate: Double
        var seeks: [Date]

        public init(title: String, elapsed: Double, at: Date, rate: Double, seeks: [Date] = []) {
            self.title = title
            self.elapsed = elapsed
            self.at = at
            self.rate = rate
            self.seeks = seeks
        }
    }

    /// 记住的跳转帧最多几份。
    static let rememberedSeeks = 8

    private static let lock = NSLock()
    nonisolated(unsafe) private static var memory: Memory?
    nonisolated(unsafe) private static var start: Start?
    nonisolated(unsafe) private static var last: Last?

    /// 是 iPad 版报上来的就整理,别的原样交回。
    public static func normalized(_ frame: Frame, bundleID: String?) -> Frame {
        guard bundleID == Self.bundleID else { return frame }
        lock.lock()
        defer { lock.unlock() }
        let resumed = resumedJump(normalized(frame, memory: &memory), start: &start)
        return seekedWhilePlaying(frame, normalized: resumed, last: &last)
    }

    /// 放着歌拖进度的那一帧时刻往后挪。`frame` 是原样报的(记住的那份按它算),`normalized` 是前面几步整理过的:
    /// 前面已经挪过时刻的(续播跳转、恢复晚锚点)不再挪。纯函数(状态由调用方给),selftest 覆盖。
    public static func seekedWhilePlaying(_ frame: Frame, normalized: Frame, last: inout Last?) -> Frame {
        guard let title = frame.title, !title.isEmpty, let elapsed = frame.elapsed, let at = frame.timestamp else { return normalized }
        let rate = normalized.rate ?? 0
        if let known = last {
            if known.seeks.contains(at) { return seekShifted(normalized, at: at) }
            if at <= known.at { return normalized }
        }
        var seek = false
        if let known = last, known.title == title, rate > 0, elapsed >= 1, normalized.timestamp == frame.timestamp {
            let predicted = known.elapsed + at.timeIntervalSince(known.at) * known.rate
            seek = abs(elapsed - predicted) > seekJumpSecs
        }
        var seeks = last?.seeks ?? []
        if seek { seeks = Array((seeks + [at]).suffix(rememberedSeeks)) }
        last = Last(title: title, elapsed: elapsed, at: at, rate: rate, seeks: seeks)
        return seek ? seekShifted(normalized, at: at) : normalized
    }

    private static func seekShifted(_ frame: Frame, at: Date) -> Frame {
        var out = frame
        out.timestamp = at.addingTimeInterval(seekFrameLeadSecs)
        return out
    }

    /// 换到听过一半的单集:开播整帧之后不久同一首跳到上次位置的那一帧,时刻往前挪。纯函数(状态由调用方给),selftest 覆盖。
    public static func resumedJump(_ frame: Frame, start: inout Start?) -> Frame {
        guard let title = frame.title, !title.isEmpty, let elapsed = frame.elapsed, let at = frame.timestamp,
              (frame.rate ?? 0) > 0 else { return frame }
        if elapsed <= 0.1 {
            if start.map({ $0.title != title || at < $0.at || at.timeIntervalSince($0.at) > resumeJumpWindowSecs }) ?? true {
                start = Start(title: title, at: at)
            }
            return frame
        }
        guard elapsed >= 1, let known = start, known.title == title, at > known.at,
              at.timeIntervalSince(known.at) <= resumeJumpWindowSecs else { return frame }
        var out = frame
        out.timestamp = max(known.at, at.addingTimeInterval(-lateResumeJumpSecs))
        return out
    }

    /// 纯函数(状态由调用方给),selftest 覆盖。
    public static func normalized(_ frame: Frame, memory: inout Memory?) -> Frame {
        guard let title = frame.title, !title.isEmpty, let elapsed = frame.elapsed, let at = frame.timestamp else { return frame }
        let stopped = (frame.rate ?? 0) == 0 && frame.playing != true
        if stopped {
            if var known = memory, known.title == title, known.elapsed == elapsed {
                if at < known.since { known.since = at }
                if at.timeIntervalSince(known.since) >= resumeGapSecs {
                    if known.resumedAt.map({ at < $0 }) ?? true { known.resumedAt = at }
                    memory = known
                    var out = frame
                    out.rate = 1
                    out.playing = true
                    return out
                }
                memory = known
            } else {
                memory = Memory(title: title, elapsed: elapsed, since: at)
            }
            return frame
        }
        guard let known = memory, known.title == title, let resumedAt = known.resumedAt,
              elapsed >= known.elapsed, elapsed - known.elapsed <= lateResumeElapsedSlackSecs,
              at > resumedAt, at.timeIntervalSince(resumedAt) <= lateResumeFrameWindowSecs else { return frame }
        var out = frame
        out.timestamp = max(resumedAt, at.addingTimeInterval(-lateResumeFrameSecs))
        return out
    }

    /// 事件流合并状态里的速率、在放、时刻换成整理过的,别的键原样留着。
    public static func normalizedFields(_ fields: [String: Any]) -> [String: Any] {
        guard fields["bundleIdentifier"] as? String == Self.bundleID else { return fields }
        let raw = Frame(title: fields["title"] as? String, elapsed: (fields["elapsedTime"] as? NSNumber)?.doubleValue,
                        timestamp: MediaControlClient.parseTimestamp(fields["timestamp"] as? String),
                        rate: (fields["playbackRate"] as? NSNumber)?.doubleValue, playing: fields["playing"] as? Bool)
        let frame = normalized(raw, bundleID: Self.bundleID)
        guard frame != raw else { return fields }
        var out = fields
        out["playbackRate"] = frame.rate
        out["playing"] = frame.playing
        if frame.timestamp != raw.timestamp, let at = frame.timestamp {
            out["timestamp"] = MediaControlMicros.timestampString(at.timeIntervalSince1970 * 1_000_000)
        }
        return out
    }

    /// 单问会话那一份(整份 JSON 载荷,解出来的快照字段不能改)换成整理过的:速率、在放、锚点时刻,以及按它们重算的此刻进度
    /// (`elapsedTime`,helper 按报上来的速率外推过)。不是 iPad 版报的、解不开的原样交回。
    public static func normalizedPayload(_ data: Data, now: Date = Date()) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["bundleIdentifier"] as? String == Self.bundleID,
              let anchor = (object["anchorElapsedTime"] as? NSNumber)?.doubleValue,
              let seconds = (object["timestamp"] as? NSNumber)?.doubleValue else { return data }
        let raw = Frame(title: object["title"] as? String, elapsed: anchor, timestamp: Date(timeIntervalSince1970: seconds),
                        rate: (object["playbackRate"] as? NSNumber)?.doubleValue, playing: object["playing"] as? Bool)
        let frame = normalized(raw, bundleID: Self.bundleID)
        guard frame != raw, let at = frame.timestamp else { return data }
        object["playbackRate"] = frame.rate
        object["playing"] = frame.playing
        object["timestamp"] = at.timeIntervalSince1970
        if (frame.rate ?? 0) > 0 { object["elapsedTime"] = anchor + max(0, now.timeIntervalSince(at)) }
        return SafeSerialization.jsonData(object) ?? data
    }

    /// 测试用:清掉共用状态。
    public static func resetForTesting() {
        lock.lock()
        memory = nil
        start = nil
        last = nil
        lock.unlock()
    }
}
