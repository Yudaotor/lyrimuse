import Foundation

/// iPad 版网易云(iOS 应用跑在 Apple 芯片 Mac 上,bundle id `com.netease.cloudmusic`)报给系统的 Now Playing,在按网易云 Mac 版认
/// (`PlayerBundleAliases`)之前整理成真名。
///
/// - 它设置里的「锁屏歌词」默认开着:在放时 title 是当前这一句歌词、每句一换,artist 是「歌手/歌名」;真名只在换歌那一两帧
///   (暂停、进度 0)出现。记住最近一份真名,artist 正好是「真歌手/真歌名」、专辑相同的帧还原回真名。没记到真名(歌放到一半才开始读)
///   时,连着两帧歌手、专辑、时长都没变、只有 title 在变,而且 artist 里有「/」,按最后一个「/」拆出真名。关掉这个开关时 title 不会变,
///   碰不到这一条。
/// - 换歌那一刻第一帧还是上一首的 title / artist、时长已经是新歌的:按上一首的时长报,不然新歌那一帧会被当成「时长没跟上」的撕裂按住
///   (`TornTrackHold.durationLags`)。「锁屏歌词」开着时第一帧多半是 title 还是上一首的某一句歌词(它在后台时不逐句重报,未必是报过的
///   那句)、artist 已是新歌的「歌手/歌名」写法、专辑时长也是新歌的:整帧按上一首报,不然它被当成新歌,紧跟着的真名帧只换了 title,
///   会被当成撕裂按住十几秒。真名帧之后紧跟的歌词帧(artist 正好是上一帧的「歌手/歌名」)把上一帧认回真名。撕裂帧只出现在手动换歌
///   那一帧暂停帧里;自动连播整帧开播的那一行(多位歌手的 artist 也带「/」)不按撕裂帧认。
/// - 含不良内容的歌 title 末尾带「🅴」,去掉。
/// - 开播那一行比真实起播晚:手动换歌多数只补一行速率翻 1 的差量(不带进度,进度还是暂停帧那个 0),晚约 0.45 秒;自动连播是整帧
///   带着进度 0、速率 1 报,晚 0~0.46 秒、多在 0.3 上下。这一行只有媒体事件流看得到:它认出这一行(`isBareStart`)就记下时间戳和
///   是哪一种(`noteBareStart`),之后哪条路整理到这个时间戳、进度 0 的锚点都补上那一种的提前量(`bareStartLead` / `fullStartLead`)。
/// - 开播后头几秒逐句重报的进度报小了 0.1~0.5 秒,之后的才准:进度不到 `earlyReportMaxElapsed`、跟开播锚点推过来的差不出
///   `earlyReportMaxDrift` 的,按开播锚点推过来的报。
///
/// 轮询、媒体事件流、单问会话和封面几条路都过这里,状态共用一份;同一帧再过一次结果不变(事件流会把上一帧再整理一次来比)。
/// 见 02 章决策 198。
public enum NetEaseIPadNowPlaying {
    public static let bundleID = "com.netease.cloudmusic"

    public struct Frame: Equatable, Sendable {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var duration: Double?
        public var elapsed: Double?
        /// 锚点时间戳(media-control 的字符串原样),只拿来认开播差量记下的那一个。
        public var timestamp: String?

        public init(title: String?, artist: String?, album: String?, duration: Double?, elapsed: Double?,
                    timestamp: String? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.elapsed = elapsed
            self.timestamp = timestamp
        }
    }

    public struct Memory: Equatable, Sendable {
        /// 最近一份真名。
        public var real: Frame?
        /// 上一帧原样报上来的。
        public var last: Frame?
        /// 最近一次开播那一行的时间戳。
        public var bareStartTimestamp: String?
        /// 那一行是整帧带着进度 0 报的(自动连播)。
        public var fullStart: Bool
        /// 这份真名报过的最近一句歌词(歌词帧的 title);不为空 = 「锁屏歌词」开着。
        public var lyricTitle: String?

        public init(real: Frame? = nil, last: Frame? = nil, bareStartTimestamp: String? = nil,
                    fullStart: Bool = false, lyricTitle: String? = nil) {
            self.real = real
            self.last = last
            self.bareStartTimestamp = bareStartTimestamp
            self.fullStart = fullStart
            self.lyricTitle = lyricTitle
        }
    }

    /// 换歌那一帧的进度上限:撕裂那一帧报在开头。
    static let tornFrameMaxElapsed: Double = 0.5

    /// 只翻速率的开播差量比真实起播晚多少秒,以它开播几秒后逐句重报的进度为准(见 02 章决策 198)。
    public static let bareStartLead: Double = 0.45

    /// 整帧带进度 0 的开播(自动连播)比真实起播晚多少秒,同上。
    public static let fullStartLead: Double = 0.3

    /// 开播后进度不到这么多秒的重报不准。
    static let earlyReportMaxElapsed: Double = 4

    /// 不准的重报跟开播锚点推过来的最多差这么多秒;差得更多的是拖动过,照原样。
    static let earlyReportMaxDrift: Double = 1

    /// 两个时间戳差这么多秒以内算开播那一行:单问会话报的秒数跟事件流截成的整微秒,同一刻也会差 1 微秒。
    static let startStampTolerance: TimeInterval = 0.001

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared = Memory()

    /// 是 iPad 版报上来的就整理,别的原样交回。
    public static func normalized(_ frame: Frame, bundleID: String?) -> Frame {
        guard bundleID == Self.bundleID else { return frame }
        lock.lock()
        defer { lock.unlock() }
        return normalized(frame, memory: &shared)
    }

    /// 整份 JSON 载荷(单问会话那一路,解出来的快照字段不能改)里的 title / artist / 时长 / 进度换成整理过的,别的键原样留着。
    /// 不是 iPad 版报的、解不开的原样交回。时长键带 `Micros` 后缀的(`--micros`)按微秒读写。
    /// helper 那份的时间戳是 epoch 秒数(换成事件流同一种写法再比),锚点进度在 `anchorElapsedTime`、`elapsedTime` 是外推到此刻的:
    /// 按锚点进度整理,补的提前量几个进度键一起挪。
    public static func normalizedPayload(_ data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["bundleIdentifier"] as? String == Self.bundleID else { return data }
        func seconds(_ key: String) -> Double? {
            if let micros = (object[key + "Micros"] as? NSNumber)?.doubleValue { return micros / 1_000_000 }
            return (object[key] as? NSNumber)?.doubleValue
        }
        func write(_ key: String, _ value: Double) {
            if object[key + "Micros"] != nil {
                object[key + "Micros"] = Int64((value * 1_000_000).rounded())
            } else {
                object[key] = value
            }
        }
        let anchor = seconds("anchorElapsedTime") ?? seconds("elapsedTime")
        let timestamp = object["timestamp"] as? String
            ?? (object["timestamp"] as? NSNumber).flatMap { MediaControlMicros.timestampString(($0.doubleValue * 1_000_000).rounded()) }
            ?? MediaControlMicros.timestampString((object["timestampEpochMicros"] as? NSNumber)?.doubleValue)
        let frame = normalized(
            Frame(title: object["title"] as? String, artist: object["artist"] as? String, album: object["album"] as? String,
                  duration: seconds("duration"), elapsed: anchor, timestamp: timestamp),
            bundleID: Self.bundleID)
        object["title"] = frame.title ?? NSNull()
        object["artist"] = frame.artist ?? NSNull()
        if let duration = frame.duration { write("duration", duration) }
        if let anchor, let lead = frame.elapsed.map({ $0 - anchor }), lead != 0 {
            for key in ["anchorElapsedTime", "elapsedTime", "elapsedTimeNow"] {
                if let value = seconds(key) { write(key, value + lead) }
            }
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    /// 媒体事件流的合并状态(键名同 media-control 输出,时间已换成秒)里的 title / artist / duration / elapsedTime 换成整理过的,
    /// 别的键原样留着。
    public static func normalizedFields(_ fields: [String: Any]) -> [String: Any] {
        guard fields["bundleIdentifier"] as? String == Self.bundleID else { return fields }
        let elapsed = (fields["elapsedTime"] as? NSNumber)?.doubleValue
        let frame = normalized(
            Frame(title: fields["title"] as? String, artist: fields["artist"] as? String, album: fields["album"] as? String,
                  duration: (fields["duration"] as? NSNumber)?.doubleValue, elapsed: elapsed,
                  timestamp: fields["timestamp"] as? String),
            bundleID: Self.bundleID)
        var out = fields
        out["title"] = frame.title
        out["artist"] = frame.artist
        out["duration"] = frame.duration
        if elapsed != nil { out["elapsedTime"] = frame.elapsed }
        return out
    }

    /// 媒体事件流这一行是不是开播:iPad 版报的、这一行带速率 1 和时间戳,合并之后进度是 0(只翻速率的差量,或整帧带进度 0)。
    /// `payload` 是这一行(时间已换成秒),`merged` 是合并了这一行之后的状态。恢复播放也是只翻速率的差量,但进度不是 0。
    /// 纯函数,selftest 覆盖。
    public static func isBareStart(payload: [String: Any], merged: [String: Any]) -> Bool {
        guard merged["bundleIdentifier"] as? String == Self.bundleID,
              (payload["playbackRate"] as? NSNumber)?.doubleValue == 1,
              payload["timestamp"] is String,
              let elapsed = (merged["elapsedTime"] as? NSNumber)?.doubleValue else { return false }
        return abs(elapsed) < 0.001
    }

    /// 记下开播那一行的时间戳(见 `isBareStart`);`full`:这一行整帧带着进度 0(自动连播)。
    public static func noteBareStart(timestamp: String, full: Bool) {
        lock.lock()
        shared.bareStartTimestamp = timestamp
        shared.fullStart = full
        lock.unlock()
    }

    /// 只有歌名、歌手的那几份(封面载荷)按记住的真名还原,不改状态:没有专辑、时长,拿它更新状态会把歌词当成真名记下。
    public static func names(title: String?, artist: String?, bundleID: String?) -> (title: String?, artist: String?) {
        guard bundleID == Self.bundleID else { return (title, artist) }
        lock.lock()
        defer { lock.unlock() }
        return names(title: title, artist: artist, memory: shared)
    }

    /// 纯函数,selftest 覆盖。
    public static func names(title: String?, artist: String?, memory: Memory) -> (title: String?, artist: String?) {
        var frame = withoutExplicitMark(Frame(title: title, artist: artist, album: nil, duration: nil, elapsed: nil))
        if let real = memory.real {
            frame.album = real.album
            if isLyricLine(frame, real: real) { return (real.title, real.artist) }
        }
        return (frame.title, frame.artist)
    }

    /// 纯函数(状态由调用方给),selftest 覆盖。
    public static func normalized(_ raw: Frame, memory: inout Memory) -> Frame {
        var frame = normalizedNames(raw, memory: &memory)
        guard let timestamp = raw.timestamp, let start = memory.bareStartTimestamp, let elapsed = frame.elapsed else { return frame }
        let lead = memory.fullStart ? fullStartLead : bareStartLead
        if isStartStamp(timestamp, start: start) {
            if abs(elapsed) < 0.001 { frame.elapsed = lead }
        } else if let carried = carriedFromStart(elapsed: elapsed, timestamp: timestamp, start: start, lead: lead) {
            frame.elapsed = carried
        }
        return frame
    }

    /// 是不是开播那一行的时间戳(差 `startStampTolerance` 以内)。纯函数,selftest 覆盖。
    public static func isStartStamp(_ timestamp: String?, start: String?) -> Bool {
        guard let timestamp, let start else { return false }
        if timestamp == start { return true }
        guard let at = MediaControlClient.parseTimestamp(timestamp), let startAt = MediaControlClient.parseTimestamp(start) else {
            return false
        }
        return abs(at.timeIntervalSince(startAt)) <= startStampTolerance
    }

    /// 开播后头几秒的重报按开播锚点推过来的进度;不是那种重报的给 nil。
    static func carriedFromStart(elapsed: Double, timestamp: String, start: String, lead: Double) -> Double? {
        guard elapsed < earlyReportMaxElapsed, let at = MediaControlClient.parseTimestamp(timestamp),
              let startAt = MediaControlClient.parseTimestamp(start) else { return nil }
        let since = at.timeIntervalSince(startAt)
        guard since > 0 else { return nil }
        let carried = since + lead
        return abs(carried - elapsed) <= earlyReportMaxDrift ? carried : nil
    }

    static func normalizedNames(_ raw: Frame, memory: inout Memory) -> Frame {
        let frame = withoutExplicitMark(raw)
        defer { memory.last = frame }
        if let real = memory.real, isLyricLine(frame, real: real) {
            memory.lyricTitle = frame.title
            return Frame(title: real.title, artist: real.artist, album: frame.album, duration: frame.duration,
                         elapsed: frame.elapsed)
        }
        if let last = memory.last, let split = lyricLineSplit(frame, last: last) ?? lyricLineOfLast(frame, last: last) {
            memory.real = split
            memory.lyricTitle = frame.title
            return Frame(title: split.title, artist: split.artist, album: frame.album, duration: frame.duration, elapsed: frame.elapsed)
        }
        if let real = memory.real, isTornFirstFrame(frame, real: real) {
            return Frame(title: frame.title, artist: frame.artist, album: frame.album, duration: real.duration,
                         elapsed: frame.elapsed)
        }
        let isFullStart = memory.fullStart && isStartStamp(raw.timestamp, start: memory.bareStartTimestamp)
        if !isFullStart, let real = memory.real,
           isTornLyricFrame(frame, real: real, lyricTitle: memory.lyricTitle, last: memory.last) {
            return Frame(title: real.title, artist: real.artist, album: real.album, duration: real.duration,
                         elapsed: frame.elapsed)
        }
        memory.real = frame
        memory.lyricTitle = nil
        return frame
    }

    /// artist 正好是「真歌手/真歌名」、专辑相同。
    static func isLyricLine(_ frame: Frame, real: Frame) -> Bool {
        guard let artist = frame.artist, let realArtist = real.artist, let realTitle = real.title,
              !realArtist.isEmpty, !realTitle.isEmpty, frame.album == real.album else { return false }
        return artist == realArtist + "/" + realTitle && frame.title != realTitle
    }

    /// 没记到真名时,从连着两帧认出歌词模式:歌手、专辑、时长都没变,只有 title 在变,artist 里有「/」。拆出来的真名。
    static func lyricLineSplit(_ frame: Frame, last: Frame) -> Frame? {
        guard let artist = frame.artist, let title = frame.title, !title.isEmpty, artist == last.artist,
              frame.album == last.album, frame.duration == last.duration, title != last.title,
              let slash = artist.lastIndex(of: "/") else { return nil }
        let realArtist = String(artist[..<slash]), realTitle = stripExplicitMark(String(artist[artist.index(after: slash)...]))
        guard !realArtist.isEmpty, !realTitle.isEmpty else { return nil }
        return Frame(title: realTitle, artist: realArtist, album: frame.album, duration: frame.duration, elapsed: frame.elapsed)
    }

    /// title、artist 还是上一首的,时长换了、进度在开头。
    static func isTornFirstFrame(_ frame: Frame, real: Frame) -> Bool {
        guard frame.title == real.title, frame.artist == real.artist, let duration = frame.duration,
              let realDuration = real.duration, abs(duration - realDuration) >= 0.01 else { return false }
        return (frame.elapsed ?? 0) <= tornFrameMaxElapsed
    }

    /// 「锁屏歌词」开着时新歌的第一帧:artist 是带「/」的歌词帧写法、不是这份真名的,进度在开头。上一帧的 artist 正好是这一帧的
    /// 「歌手/歌名」的,是紧跟在撕裂帧后面的真名帧(多位歌手的 artist 本身也带「/」),不算。
    static func isTornLyricFrame(_ frame: Frame, real: Frame, lyricTitle: String?, last: Frame?) -> Bool {
        guard lyricTitle != nil, let artist = frame.artist, artist.contains("/"), let realArtist = real.artist,
              let realTitle = real.title, artist != realArtist + "/" + realTitle, artist != realArtist else { return false }
        if let title = frame.title, let lastArtist = last?.artist, lastArtist == artist + "/" + title { return false }
        return (frame.elapsed ?? 0) <= tornFrameMaxElapsed
    }

    /// 上一帧是真名帧、这一帧是它的歌词帧:artist 正好是上一帧的「歌手/歌名」、专辑相同、title 变了。认回上一帧的真名。
    static func lyricLineOfLast(_ frame: Frame, last: Frame) -> Frame? {
        guard let artist = frame.artist, let lastArtist = last.artist, let lastTitle = last.title, !lastArtist.isEmpty,
              !lastTitle.isEmpty, artist == lastArtist + "/" + lastTitle, frame.album == last.album,
              frame.title != lastTitle else { return nil }
        return Frame(title: lastTitle, artist: lastArtist, album: last.album, duration: last.duration, elapsed: frame.elapsed)
    }

    static func withoutExplicitMark(_ frame: Frame) -> Frame {
        var out = frame
        out.title = frame.title.map(stripExplicitMark)
        if let artist = frame.artist, let slash = artist.lastIndex(of: "/") {
            out.artist = String(artist[...slash]) + stripExplicitMark(String(artist[artist.index(after: slash)...]))
        }
        return out
    }

    /// 末尾的「🅴」连同前面的空白去掉。纯函数,selftest 覆盖。
    public static func stripExplicitMark(_ title: String) -> String {
        guard title.hasSuffix("🅴") else { return title }
        return String(title.dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// 测试用:清掉共用状态。
    public static func resetForTesting() {
        lock.lock()
        shared = Memory()
        lock.unlock()
    }
}
