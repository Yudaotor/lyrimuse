import Foundation

/// Kaset(YouTube Music 的原生客户端)AppleScript `get player info` 的解读:一段 JSON → 一份快照。纯函数,selftest 覆盖。
///
/// 系统 Now Playing 里 Kaset 那份靠不住:播放中它把会话交给 WebKit(那份只有时长和进度,歌名歌手是空的),
/// 自己只在暂停、加载的空档发一份只有歌名歌手的,连播换歌后常停在上一首,换歌加载时整个撤掉、放起来也不一定补回。
/// 所以认出在放的是它之后,曲目与位置整份换成这里这份(`MediaControlClient.adaptedSnapshot`),系统那边只回答
/// 「是不是它在放」。见 02 章决策 81。
///
/// 位置是网页里 `video.currentTime` 每 0.5 秒推给 Kaset 一次的值:读到的只会比真值晚 0~0.5 秒、不会早,
/// 所以 Kaset 归 noisyFloored,前向棘轮把位置收到最新那次推送(`LocalPlaybackSource.shouldRatchetForward`)。
public enum KasetPlayerInfo {
    /// 一次读数里用得到的字段。
    public struct Reading: Equatable, Sendable {
        /// Kaset 原样给的歌名。开播时是队列里那份,网页播放器加载好之后可能换成视频在 YouTube 上的标题,见 `steadyIdentity`。
        public let title: String
        /// Kaset 原样给的署名。开播时是队列里那份(逐个艺人用 `, ` 连,清理见 `cleanedArtist`),网页播放器加载好之后
        /// 可能换成网页上的写法,见 `steadyIdentity`。
        public let artist: String
        public let videoID: String?
        /// 网页 video 的时长;还没加载好时是曲目元数据里的整数秒。
        public let duration: Double?
        public let position: Double
        public let isPlaying: Bool
        public let isPaused: Bool
        /// 播放器那一层报的时长(`duration`)与曲目元数据里的(`currentTrack.duration`),认广告用,见 `isAd`。
        public let playerDuration: Double?
        public let trackDuration: Double?

        public init(title: String, artist: String, videoID: String?, duration: Double?, position: Double,
                    isPlaying: Bool, isPaused: Bool, playerDuration: Double? = nil, trackDuration: Double? = nil) {
            self.title = title
            self.artist = artist
            self.videoID = videoID
            self.duration = duration
            self.position = position
            self.isPlaying = isPlaying
            self.isPaused = isPaused
            self.playerDuration = playerDuration
            self.trackDuration = trackDuration
        }

        /// 只换歌名和署名的同一份读数。
        public func withIdentity(title: String, artist: String) -> Reading {
            Reading(title: title, artist: artist, videoID: videoID, duration: duration, position: position,
                    isPlaying: isPlaying, isPaused: isPaused, playerDuration: playerDuration, trackDuration: trackDuration)
        }
    }

    private struct Payload: Decodable {
        struct Track: Decodable {
            let name: String?
            let artist: String?
            let duration: Double?
            let videoId: String?
        }
        let currentTrack: Track?
        let position: Double?
        let duration: Double?
        let isPlaying: Bool?
        let isPaused: Bool?
    }

    /// 解析 `get player info` 的输出。没有当前曲目(刚启动、队列是空的)、Kaset 没在跑(脚本回空串)、
    /// 不是那个形状时返回 nil。
    public static func reading(fromJSON data: Data) -> Reading? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let track = payload.currentTrack,
              let title = track.name?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        func positive(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        let playerDuration = positive(payload.duration), trackDuration = positive(track.duration)
        let position = payload.position.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        return Reading(title: title, artist: track.artist ?? "", videoID: track.videoId,
                       duration: playerDuration ?? trackDuration, position: position,
                       isPlaying: payload.isPlaying == true, isPaused: payload.isPaused == true,
                       playerDuration: playerDuration, trackDuration: trackDuration)
    }

    private struct ScriptOutput: Decodable {
        let readAtMs: Double
        let info: String
    }

    /// 解析 `MediaControlClient` 那段 JXA 的输出:读数原样夹在 `info` 里,`readAtMs` 是读数调用返回那一刻的墙钟(毫秒)。
    /// 读到的时刻按它算,别取调用前后的中点:JXA 每次都要先载入 Kaset 的字典,整个调用 0.1~0.6 秒,真正读数在最后,
    /// 取中点会把读数记早、位置被当成更新鲜的,外推就跑到真值前面去(只会往前追的棘轮拉不回来)。也别按子进程
    /// 退出、管道读完那一刻算,那会把位置当成更旧的。时刻不在 [now − 5s, now + 1s] 里(墙钟被调过之类)就按 now 算。
    public static func parseScriptOutput(_ data: Data, now: Date) -> (reading: Reading, readAt: Date)? {
        guard let out = try? JSONDecoder().decode(ScriptOutput.self, from: data),
              let reading = reading(fromJSON: Data(out.info.utf8)) else { return nil }
        let readAt = Date(timeIntervalSince1970: out.readAtMs / 1000)
        let age = now.timeIntervalSince(readAt)
        return (reading, age >= -1 && age <= 5 ? readAt : now)
    }

    /// 位置最近一次变化:哪一首、停在哪个值、第一次读到这个值是什么时候。认「报在放、位置却不动」用。
    public struct LastMove: Equatable, Sendable {
        public let videoID: String?
        public let position: Double
        public let seenAt: Date

        public init(videoID: String?, position: Double, seenAt: Date) {
            self.videoID = videoID
            self.position = position
            self.seenAt = seenAt
        }
    }

    /// 读到这一份之后 `LastMove` 怎么变:曲目或位置变了就换成这一份;都没变就留着原来那份,保住第一次读到的时刻。
    public static func nextMove(after previous: LastMove?, reading: Reading, at now: Date) -> LastMove {
        if let previous, previous.videoID == reading.videoID, previous.position == reading.position {
            return previous
        }
        return LastMove(videoID: reading.videoID, position: reading.position, seenAt: now)
    }

    /// 报在放、位置却超过这么久没动,就当没在走。网页每 0.5 秒推一次位置,1.5 秒是连着三次都没推到。
    public static let stallSeconds: TimeInterval = 1.5

    /// 这一拍声音是不是真在走。
    /// - 没报在放(暂停、加载、一首放完还没接上下一首):不在走。
    /// - 报在放、位置是 0:广告或开播缓冲,这首还没开始。
    /// - 报在放、同一首的位置超过 `stallSeconds` 没动:卡住了(缓冲、曲尾没接上下一首)。
    public static func isAdvancing(_ reading: Reading, lastMove: LastMove?, now: Date) -> Bool {
        guard reading.isPlaying, reading.position > 0 else { return false }
        guard let lastMove, lastMove.videoID == reading.videoID, lastMove.position == reading.position else {
            return true
        }
        return now.timeIntervalSince(lastMove.seenAt) < stallSeconds
    }

    /// 这一拍在放的是不是广告。Kaset 放前贴片广告时只更新「在放」,位置和时长都不动:位置停在 0,时长还是这首
    /// 元数据里的那个(整数秒);正片一开始,时长就换成网页 video 的(带小数)。所以「报在放 + 位置是 0 + 时长等于
    /// 元数据里的」= 广告;开播缓冲那半秒时长已经是网页的,不算。
    public static func isAd(_ reading: Reading) -> Bool {
        guard reading.isPlaying, reading.position == 0, let player = reading.playerDuration else { return false }
        return player == reading.trackDuration
    }

    /// 夹在两个艺人中间、其实是连接词的那几项。Kaset 只认英文的 `,` `&`,界面是别的语言时连接词会被当成一个艺人。
    /// 比较前转小写。
    static let artistJoinWords: Set<String> = [
        "、", "，", ",", "&", "＆", "和", "与", "與", "及", "跟", "と", "및", "와", "과",
        "and", "y", "e", "et", "und", "en", "och", "og", "i", "и", "ve", "dan", "và",
    ]

    /// 署名:按 `, ` 拆开,去掉夹在两个艺人中间的连接词,再用 `, ` 连回去。排在头尾的不动:
    /// 真有叫这个名字的艺人时,至少独唱、排第一个的不会被误删。
    public static func cleanedArtist(_ raw: String) -> String {
        let parts = raw.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return raw.trimmingCharacters(in: .whitespaces) }
        let kept = parts.enumerated().filter { index, part in
            if part.isEmpty { return false }
            let inner = index > 0 && index < parts.count - 1
            return !(inner && artistJoinWords.contains(part.lowercased()))
        }
        return kept.map(\.element).joined(separator: ", ")
    }

    // MARK: - 同一首的身份

    /// 这首最先报的歌名与署名,连同报它时的 videoId。
    public struct FirstReport: Equatable, Sendable {
        public let videoID: String
        public let title: String
        public let artist: String

        public init(videoID: String, title: String, artist: String) {
            self.videoID = videoID
            self.title = title
            self.artist = artist
        }
    }

    /// 这一份读数用哪个歌名和署名(原样,署名清理照旧在 `snapshot` 里做),以及之后记住哪一份。Kaset 开播先报队列里
    /// 那份(跟着界面语言),网页播放器加载好之后把当前曲目的显示信息换成网页上的(跟界面语言无关:署名是频道名、歌名是
    /// 视频原标题,有时还多一段「歌手 - 」和 `(Official Audio)`;署名的连法也不同,`A, 和, B` → `A和B`)。同一个 videoId
    /// 下,下面任一条成立就沿用最先报的那份,缓存键才不会在一首歌中途换掉(待播预解析按队列那份取的):歌名是同一首的
    /// 两种写法(`sameSongTitle`);网页 video 的时长跟队列里的元数据时长对得上(`sameRecording`,放的就是那一段录音);
    /// 网页时长还没出来(先按住)。时长对不上、歌名也换成了别的,在放的就是那支视频本身,照收新的。最先那份署名是空的
    /// 不沿用;没有 videoId 时原样、不记。
    public static func steadyIdentity(_ reading: Reading, first: FirstReport?) -> (title: String, artist: String, first: FirstReport?) {
        guard let id = reading.videoID, !id.isEmpty else { return (reading.title, reading.artist, nil) }
        if let first, first.videoID == id, !first.artist.isEmpty,
           first.title == reading.title || sameSongTitle(reading.title, first.title, artist: first.artist)
            || sameRecording(reading) != false {
            return (first.title, first.artist, first)
        }
        return (reading.title, reading.artist, FirstReport(videoID: id, title: reading.title, artist: reading.artist))
    }

    /// Kaset 队列里这个 videoId 那一格入队时的歌名与署名(原样),当作这首最先报的那份。换歌后第一拍读到、或者 App 在一首
    /// 歌中途起来时,Kaset 可能已经换成网页上的写法了,不按队列补的话开播那份就丢了。队列里没有这首、解析不出返回 nil。
    public static func queueFirstReport(fromQueueJSON data: Data, videoID: String) -> FirstReport? {
        guard let queue = try? JSONDecoder().decode(QueuePayload.self, from: data),
              let track = queue.tracks?.first(where: { $0.videoId == videoID }),
              let title = track.name?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let artist = track.artist, !artist.isEmpty
        else { return nil }
        return FirstReport(videoID: videoID, title: title, artist: artist)
    }

    /// 网页 video 的时长跟元数据时长差不超过这么多秒,就是同一段录音(元数据是整数秒)。
    static let sameRecordingTolerance: Double = 3

    /// 网页这一拍放的是不是队列里那一首的录音:网页 video 的时长跟元数据时长对得上。Kaset 换显示信息时元数据时长
    /// 不动、留着队列那份,所以换写法前后都能这么比。两个时长缺一个就说不上来(nil)。
    public static func sameRecording(_ reading: Reading) -> Bool? {
        guard let player = reading.playerDuration, let track = reading.trackDuration else { return nil }
        return abs(player - track) <= sameRecordingTolerance
    }

    /// 两个歌名是不是同一首的两种写法。网页播放器报的常是视频在 YouTube 上的标题:开头多一段「歌手 - 」,结尾多一串
    /// `(Official Audio)` 这类括号。各自去掉开头那段(破折号前得是这首的第一位歌手)和结尾的括号,剩下的忽略大小写、
    /// 不分弯直引号相等才算。
    public static func sameSongTitle(_ a: String, _ b: String, artist: String) -> Bool {
        let x = titleCore(a, artist: artist), y = titleCore(b, artist: artist)
        return !x.isEmpty && x == y
    }

    private static func titleCore(_ raw: String, artist: String) -> String {
        var s = raw.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .trimmingCharacters(in: .whitespaces)
        let lead = (artist.components(separatedBy: ", ").first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        for dash in [" - ", " \u{2013} ", " \u{2014} "] {
            guard !lead.isEmpty, let r = s.range(of: dash) else { continue }
            let prefix = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            if !prefix.isEmpty, prefix.hasPrefix(lead) || lead.hasPrefix(prefix) {
                s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let pairs: [Character: Character] = [")": "(", "]": "[", "\u{FF09}": "\u{FF08}", "\u{3011}": "\u{3010}"]
        while let last = s.last, let open = pairs[last], let start = s.lastIndex(of: open), start != s.startIndex {
            s = String(s[..<start]).trimmingCharacters(in: .whitespaces)
        }
        return s.lowercased()
    }

    // MARK: - 待播队列

    /// 预解析要的待播队列(`PlayerQueryServer` 代引擎跑 `get play queue`)。曲目身份按这一侧的口径整理好再交出去
    /// (署名清理同 `cleanedArtist`、歌名去首尾空白、不给专辑):引擎拿它预取歌词,缓存键得跟这首真播到时 App 写进
    /// 播放状态的一字不差,整理只在这一侧做一份。字段名两边一起改(引擎 `kasetQueueReply`,样例
    /// `shared/testdata/kaset-queue/`)。
    public struct QueueReply: Codable, Equatable, Sendable {
        public struct Track: Codable, Equatable, Sendable {
            public let title: String
            public let artist: String
            /// 曲目元数据里的整数秒;没有为 nil。
            public let duration: Double?
            public let videoID: String?
            /// 音轨版本的 videoId(Kaset 的 `audioVideoId`):队列里那一格常是 MV / 视频版本,YouTube Music 只给音轨版本
            /// 登记专辑。没有配对的音轨时就是 `videoID` 自己。
            public let audioVideoID: String?

            enum CodingKeys: String, CodingKey {
                case title, artist, duration
                case videoID = "video_id"
                case audioVideoID = "audio_video_id"
            }

            public init(title: String, artist: String, duration: Double?, videoID: String?, audioVideoID: String? = nil) {
                self.title = title
                self.artist = artist
                self.duration = duration
                self.videoID = videoID
                self.audioVideoID = audioVideoID
            }
        }

        /// 当前这首在 `tracks` 里的下标(从 0 起);Kaset 说没有当前曲目时为 nil。
        public let currentIndex: Int?
        /// 循环模式,Kaset 原样:`off` / `all` / `one`。
        public let repeating: String
        /// 播放顺序(开着随机时 Kaset 把打乱后的顺序就排在队列里)。歌名为空的也留着,下标才对得上。
        public let tracks: [Track]

        enum CodingKeys: String, CodingKey {
            case tracks, repeating
            case currentIndex = "current_index"
        }
    }

    private struct QueueScriptOutput: Decodable {
        let queue: String
        let info: String
    }

    private struct QueuePayload: Decodable {
        struct Track: Decodable {
            let name: String?
            let artist: String?
            let duration: Double?
            let videoId: String?
            let audioVideoId: String?
        }
        let currentIndex: Int?
        let tracks: [Track]?
    }

    private struct RepeatPayload: Decodable {
        let repeating: String?
    }

    /// 把 `PlayerQueryServer` 那段 JXA 的输出(`{"queue": get play queue 原样, "info": get player info 原样}`)整理成
    /// `QueueReply`。解析不出、队列是空的返回 nil。Kaset 的 `currentIndex` 从 1 起,0 = 没有当前曲目。
    public static func queueReply(fromScriptOutput data: Data) -> QueueReply? {
        guard let out = try? JSONDecoder().decode(QueueScriptOutput.self, from: data),
              let queue = try? JSONDecoder().decode(QueuePayload.self, from: Data(out.queue.utf8)),
              let raw = queue.tracks, !raw.isEmpty
        else { return nil }
        let repeating = (try? JSONDecoder().decode(RepeatPayload.self, from: Data(out.info.utf8)))?.repeating ?? "off"
        let tracks = raw.map { t in
            QueueReply.Track(title: t.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                             artist: cleanedArtist(t.artist ?? ""),
                             duration: t.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, videoID: t.videoId,
                             audioVideoID: t.audioVideoId)
        }
        let index = (queue.currentIndex ?? 0) - 1
        return QueueReply(currentIndex: tracks.indices.contains(index) ? index : nil, repeating: repeating, tracks: tracks)
    }

    /// 换成下游用的快照。专辑一栏不用:放歌单时 Kaset 在这里填的是歌单名,不是这首的专辑。
    /// 没在走、又不是暂停(加载、广告、卡住)时标 `isWaitingToPlay`:轮询照播放中的节拍走,声音一走起来就接上。
    /// 广告结论(`isAd`):在放广告为 true,正片在走为 false,别的时候(加载、暂停、卡住)说不上来,为 nil。
    public static func snapshot(_ reading: Reading, lastMove: LastMove?, capturedAt: Date) -> MediaControlSnapshot {
        let advancing = isAdvancing(reading, lastMove: lastMove, now: capturedAt)
        let ad: Bool? = isAd(reading) ? true : (advancing ? false : nil)
        return MediaControlSnapshot(
            title: reading.title, artist: cleanedArtist(reading.artist), album: nil, duration: reading.duration,
            elapsedTime: reading.position, playing: advancing, playbackRate: advancing ? 1 : 0,
            isMusicApp: true, bundleIdentifier: PlaybackPlayer.kaset.bundleIdentifier,
            anchorElapsedTime: nil, isRadio: nil, capturedAt: capturedAt,
            isWaitingToPlay: !advancing && !reading.isPaused, isAd: ad)
    }
}
