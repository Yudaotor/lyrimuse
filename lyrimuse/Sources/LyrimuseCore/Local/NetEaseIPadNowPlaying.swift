import Foundation

/// iPad 版网易云(iOS 应用跑在 Apple 芯片 Mac 上,bundle id `com.netease.cloudmusic`)报给系统的 Now Playing,在按网易云 Mac 版认
/// (`PlayerBundleAliases`)之前整理成真名。
///
/// - 它设置里的「锁屏歌词」默认开着:在放时 title 是当前这一句歌词、每句一换,artist 是「歌手/歌名」;真名只在换歌那一两帧
///   (暂停、进度 0)出现。记住最近一份真名,artist 正好是「真歌手/真歌名」、专辑相同的帧还原回真名。没记到真名(歌放到一半才开始读)
///   时,连着两帧歌手、专辑、时长都没变、只有 title 在变,而且 artist 里有「/」,按最后一个「/」拆出真名。关掉这个开关时 title 不会变,
///   碰不到这一条。
/// - 换歌那一刻第一帧还是上一首的 title / artist、时长已经是新歌的:按上一首的时长报,不然新歌那一帧会被当成「时长没跟上」的撕裂按住
///   (`TornTrackHold.durationLags`)。另一种第一帧是 title 还是上一首最后一句歌词、artist / 专辑 / 时长已是新歌的:整帧按上一首报,
///   不然它被当成新歌,紧跟着的真名帧只换了 title,会被当成撕裂按住十几秒。
/// - 含不良内容的歌 title 末尾带「🅴」,去掉。
/// - 换歌开播时多数只补一行速率翻 1 的差量(不带进度,进度还是暂停帧那个 0),比真实起播晚约 0.45 秒;整帧带着进度 0 一起报的
///   那种不晚。差量带不带进度只有媒体事件流看得到:它认出这一行(`isBareStart`)就记下时间戳(`noteBareStart`),之后哪条路
///   整理到这个时间戳、进度 0 的锚点都报成 `bareStartLead`。
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
        /// 最近一次只翻速率的开播差量的时间戳。
        public var bareStartTimestamp: String?
        /// 这份真名最近一句歌词(歌词帧的 title)。
        public var lyricTitle: String?

        public init(real: Frame? = nil, last: Frame? = nil, bareStartTimestamp: String? = nil, lyricTitle: String? = nil) {
            self.real = real
            self.last = last
            self.bareStartTimestamp = bareStartTimestamp
            self.lyricTitle = lyricTitle
        }
    }

    /// 换歌那一帧的进度上限:撕裂那一帧报在开头。
    static let tornFrameMaxElapsed: Double = 0.5

    /// 只翻速率的开播差量比真实起播晚多少秒,以它自己暂停帧、逐句重报的进度为准(见 02 章决策 198)。
    public static let bareStartLead: Double = 0.45

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared = Memory()

    /// 是 iPad 版报上来的就整理,别的原样交回。
    public static func normalized(_ frame: Frame, bundleID: String?) -> Frame {
        guard bundleID == Self.bundleID else { return frame }
        lock.lock()
        defer { lock.unlock() }
        return normalized(frame, memory: &shared)
    }

    /// 整份 JSON 载荷(单问会话那一路,解出来的快照字段不能改)里的 title / artist / 时长换成整理过的,别的键原样留着。
    /// 不是 iPad 版报的、解不开的原样交回。时长键带 `Micros` 后缀的(`--micros`)按微秒读写。
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
        let elapsed = seconds("elapsedTime")
        let timestamp = object["timestamp"] as? String
            ?? MediaControlMicros.timestampString((object["timestampEpochMicros"] as? NSNumber)?.doubleValue)
        let frame = normalized(
            Frame(title: object["title"] as? String, artist: object["artist"] as? String, album: object["album"] as? String,
                  duration: seconds("duration"), elapsed: elapsed, timestamp: timestamp),
            bundleID: Self.bundleID)
        object["title"] = frame.title ?? NSNull()
        object["artist"] = frame.artist ?? NSNull()
        if let duration = frame.duration { write("duration", duration) }
        if let elapsed, let lead = frame.elapsed.map({ $0 - elapsed }), lead != 0 {
            write("elapsedTime", elapsed + lead)
            if let now = seconds("elapsedTimeNow") { write("elapsedTimeNow", now + lead) }
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

    /// 媒体事件流这一行是不是只翻速率的开播差量:iPad 版报的、这一行带速率 1 和时间戳、不带进度,合并之后进度是 0。
    /// `payload` 是这一行(时间已换成秒),`merged` 是合并了这一行之后的状态。恢复播放也是这种差量,但进度不是 0。
    /// 纯函数,selftest 覆盖。
    public static func isBareStart(payload: [String: Any], merged: [String: Any]) -> Bool {
        guard merged["bundleIdentifier"] as? String == Self.bundleID,
              (payload["playbackRate"] as? NSNumber)?.doubleValue == 1, payload["elapsedTime"] == nil,
              payload["timestamp"] is String,
              let elapsed = (merged["elapsedTime"] as? NSNumber)?.doubleValue else { return false }
        return abs(elapsed) < 0.001
    }

    /// 记下开播差量的时间戳(见 `isBareStart`)。
    public static func noteBareStart(timestamp: String) {
        lock.lock()
        shared.bareStartTimestamp = timestamp
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
        if let timestamp = raw.timestamp, timestamp == memory.bareStartTimestamp,
           let elapsed = frame.elapsed, abs(elapsed) < 0.001 {
            frame.elapsed = bareStartLead
        }
        return frame
    }

    static func normalizedNames(_ raw: Frame, memory: inout Memory) -> Frame {
        let frame = withoutExplicitMark(raw)
        defer { memory.last = frame }
        if let real = memory.real, isLyricLine(frame, real: real) {
            memory.lyricTitle = frame.title
            return Frame(title: real.title, artist: real.artist, album: frame.album, duration: frame.duration,
                         elapsed: frame.elapsed)
        }
        if let last = memory.last, let split = lyricLineSplit(frame, last: last) {
            memory.real = split
            memory.lyricTitle = frame.title
            return split
        }
        if let real = memory.real, isTornFirstFrame(frame, real: real) {
            return Frame(title: frame.title, artist: frame.artist, album: frame.album, duration: real.duration,
                         elapsed: frame.elapsed)
        }
        if let real = memory.real, isTornLyricFrame(frame, real: real, lyricTitle: memory.lyricTitle) {
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

    /// title 还是这份真名最近一句歌词,artist 已不是它的「歌手/歌名」,进度在开头。
    static func isTornLyricFrame(_ frame: Frame, real: Frame, lyricTitle: String?) -> Bool {
        guard let lyricTitle, frame.title == lyricTitle, let realArtist = real.artist, let realTitle = real.title,
              frame.artist != realArtist + "/" + realTitle else { return false }
        return (frame.elapsed ?? 0) <= tornFrameMaxElapsed
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
