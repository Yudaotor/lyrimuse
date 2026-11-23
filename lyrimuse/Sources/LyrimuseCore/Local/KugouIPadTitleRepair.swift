import Foundation

/// iPad 版酷狗自然连播时偶尔只报下一首的第一份锚点:还是上一首的歌名、歌手、专辑,时长换成新的、进度归零,新歌名一直等到
/// 下一次暂停才报。正常的两步式新歌名 0.6~0.9 秒后就到。不管的话 Lyrimuse 当成上一首从头放,拿上一首的歌词往下走。
///
/// 旧歌名下时长变了、进度归零的那一帧过了 `graceSecs` 还是这样,按引擎读出来的它的播放队列(`stateURL`,要完全磁盘访问)在
/// 时长对得上的几首里认这一首:随机抽取记录在这次换歌前后改写过、指的那首对得上就是它;其次只有一首对得上;再次排在上一首
/// 后面的那首。认不出(没有这份文件、没有或不止一首对得上)就把歌名、歌手、专辑报空,当作没在放认得出的歌,不拿上一首的歌词
/// 往下走、不再记一次上一首。歌名、歌手、专辑一变(真名到了)就作罢。
///
/// 轮询、单问会话两条路都过这里,记住的那份共用。见 02 章决策 293。
public enum KugouIPadTitleRepair {
    public struct Names: Equatable, Sendable {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var duration: Double?

        public init(title: String?, artist: String?, album: String?, duration: Double?) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
        }
    }

    /// 引擎写的名单里的一首(`kugouipadqueue.go` 的 kugouIPadQueueEntry)。`seconds` 是队列记的整秒时长。
    public struct Song: Decodable, Equatable, Sendable {
        public let title: String
        public let artist: String
        public let album: String
        public let seconds: Double

        public init(title: String, artist: String, album: String, seconds: Double) {
            self.title = title
            self.artist = artist
            self.album = album
            self.seconds = seconds
        }
    }

    /// 引擎写的名单(`kugouipadqueue.go` 的 kugouIPadQueueState)。`shuffleCurrent` 是 `songs` 里的下标,-1 = 没有;
    /// `shuffleAt` 是随机抽取记录的改写时刻(Unix 秒)。
    public struct Queue: Decodable, Equatable, Sendable {
        public let songs: [Song]
        public let shuffleCurrent: Int
        public let shuffleAt: Double

        enum CodingKeys: String, CodingKey { case songs, shuffleCurrent, shuffleAt }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
            shuffleCurrent = try c.decodeIfPresent(Int.self, forKey: .shuffleCurrent) ?? -1
            shuffleAt = try c.decodeIfPresent(Double.self, forKey: .shuffleAt) ?? 0
        }

        public init(songs: [Song], shuffleCurrent: Int = -1, shuffleAt: Double = 0) {
            self.songs = songs
            self.shuffleCurrent = shuffleCurrent
            self.shuffleAt = shuffleAt
        }
    }

    /// 上一帧原样报的名字和时长。
    public struct Seen: Equatable, Sendable {
        var names: Names

        public init(names: Names) { self.names = names }
    }

    /// 认出的那份「旧歌名下的下一首」:报的名字、新时长、那份锚点的时刻。
    public struct Pending: Equatable, Sendable {
        var names: Names
        var duration: Double
        var at: Date

        public init(names: Names, duration: Double, at: Date) {
            self.names = names
            self.duration = duration
            self.at = at
        }
    }

    /// 那份锚点之后多久还没换歌名才动手(两步式新歌名实测 0.6~0.9 秒后到)。
    public static let graceSecs: TimeInterval = 1.5
    /// 那份锚点的进度最多多少(实测 0.02~0.15 秒)。
    static let resetElapsedMax: Double = 1.0
    /// 时长变了多少以上才算换了一首。
    static let durationChangeSecs: Double = 1.0
    /// 队列记的整秒时长跟系统报的差多少以内算对得上(实测 204 对 204.814、271 对 271.493、251 对 251.0)。
    static let queueSecondsSlack: Double = 1.0
    /// 随机抽取记录比那份锚点早改写多少以内还算这次换歌写的(实测同一秒)。
    static let shuffleWriteSlackSecs: TimeInterval = 2

    public static let stateURL = LyrimusePaths.configFile("lyrimuse-kugou-ipad-queue.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: Seen?
    nonisolated(unsafe) private static var pending: Pending?

    /// 是 iPad 版报上来的就整理,别的原样交回。
    public static func repaired(_ names: Names, elapsed: Double?, timestamp: Date?, bundleID: String?,
                                now: Date = Date()) -> Names {
        guard bundleID == KugouIPadNowPlaying.bundleID else { return names }
        lock.lock()
        defer { lock.unlock() }
        return repaired(names, elapsed: elapsed, timestamp: timestamp, now: now, seen: &seen, pending: &pending,
                        queue: { FileIO.decodeJSON(Queue.self, from: stateURL) })
    }

    /// 纯函数(状态和名单由调用方给),selftest 覆盖。
    public static func repaired(_ names: Names, elapsed: Double?, timestamp: Date?, now: Date,
                                seen: inout Seen?, pending: inout Pending?, queue: () -> Queue?) -> Names {
        let previous = seen?.names
        seen = Seen(names: names)
        guard let title = names.title, !title.isEmpty, let duration = names.duration else {
            pending = nil
            return names
        }
        if let known = pending, !sameNames(known.names, names) { pending = nil }
        if let previous, sameNames(previous, names), let before = previous.duration,
           abs(duration - before) > durationChangeSecs, let elapsed, elapsed <= resetElapsedMax, let at = timestamp {
            pending = Pending(names: names, duration: duration, at: at)
        }
        guard let known = pending, duration == known.duration, now.timeIntervalSince(known.at) >= graceSecs else {
            return names
        }
        if let song = queue().flatMap({ pick($0, duration: duration, previousTitle: title, at: known.at) }) {
            return Names(title: song.title, artist: song.artist, album: song.album.isEmpty ? nil : song.album,
                         duration: duration)
        }
        return Names(title: nil, artist: nil, album: nil, duration: duration)
    }

    private static func sameNames(_ a: Names, _ b: Names) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album
    }

    /// 在名单里认时长对得上的那一首,判据见类型头注。纯函数,selftest 覆盖。
    public static func pick(_ queue: Queue, duration: Double, previousTitle: String, at: Date) -> Song? {
        let songs = queue.songs
        let fits = songs.indices.filter {
            abs(duration - songs[$0].seconds) < queueSecondsSlack && songs[$0].title != previousTitle
        }
        if fits.contains(queue.shuffleCurrent),
           Date(timeIntervalSince1970: queue.shuffleAt) >= at.addingTimeInterval(-shuffleWriteSlackSecs) {
            return songs[queue.shuffleCurrent]
        }
        if fits.count == 1 { return songs[fits[0]] }
        if let before = songs.firstIndex(where: { $0.title == previousTitle }), fits.contains(before + 1) {
            return songs[before + 1]
        }
        return nil
    }

    /// 单问会话那一份(整份 JSON 载荷)的歌名、歌手、专辑换成整理过的;认不出时去掉这三项。不是 iPad 版报的、解不开的、
    /// 没改的原样交回。
    public static func repairedPayload(_ data: Data, now: Date = Date()) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["bundleIdentifier"] as? String == KugouIPadNowPlaying.bundleID else { return data }
        let names = Names(title: object["title"] as? String, artist: object["artist"] as? String,
                          album: object["album"] as? String, duration: (object["duration"] as? NSNumber)?.doubleValue)
        let at = (object["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let elapsed = (object["anchorElapsedTime"] as? NSNumber)?.doubleValue
        let out = repaired(names, elapsed: elapsed, timestamp: at, bundleID: KugouIPadNowPlaying.bundleID, now: now)
        guard out != names else { return data }
        object["title"] = out.title
        object["artist"] = out.artist
        object["album"] = out.album
        return SafeSerialization.jsonData(object) ?? data
    }

    /// 测试用:清掉共用状态。
    public static func resetForTesting() {
        lock.lock()
        seen = nil
        pending = nil
        lock.unlock()
    }
}
