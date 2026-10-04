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
        /// 当前曲目的封面地址(原样)。网页播放器加载好之后可能换成视频截图,能不能当封面见 `coverArtworkURL`。
        public let artworkURL: String?

        public init(title: String, artist: String, videoID: String?, duration: Double?, position: Double,
                    isPlaying: Bool, isPaused: Bool, playerDuration: Double? = nil, trackDuration: Double? = nil,
                    artworkURL: String? = nil) {
            self.title = title
            self.artist = artist
            self.videoID = videoID
            self.duration = duration
            self.position = position
            self.isPlaying = isPlaying
            self.isPaused = isPaused
            self.playerDuration = playerDuration
            self.trackDuration = trackDuration
            self.artworkURL = artworkURL
        }

        /// 只换歌名和署名的同一份读数。
        public func withIdentity(title: String, artist: String) -> Reading {
            Reading(title: title, artist: artist, videoID: videoID, duration: duration, position: position,
                    isPlaying: isPlaying, isPaused: isPaused, playerDuration: playerDuration, trackDuration: trackDuration,
                    artworkURL: artworkURL)
        }
    }

    private struct Payload: Decodable {
        struct Track: Decodable {
            let name: String?
            let artist: String?
            let duration: Double?
            let videoId: String?
            let artworkURL: String?
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
                       playerDuration: playerDuration, trackDuration: trackDuration, artworkURL: track.artworkURL)
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

    /// 播放器状态里喜欢 / 随机 / 循环 / 音量这几项(`get player info` 的 `likeStatus` / `shuffling` / `repeating` /
    /// `volume`)。某一项没有就是 nil。
    public struct Controls: Equatable, Sendable {
        /// 赞过(`liked`)为 true,没评价(`none`)、点了踩(`disliked`)为 false。
        public let liked: Bool?
        public let shuffling: Bool?
        /// `off` / `all` / `one`。
        public let repeating: String?
        /// 0~100。
        public let volume: Int?

        public init(liked: Bool?, shuffling: Bool?, repeating: String?, volume: Int?) {
            self.liked = liked
            self.shuffling = shuffling
            self.repeating = repeating
            self.volume = volume
        }
    }

    private struct ControlsPayload: Decodable {
        let likeStatus: String?
        let shuffling: Bool?
        let repeating: String?
        let volume: Int?
    }

    /// 解析 `get player info` 里那几项。不是 JSON 返回 nil。
    public static func controls(fromJSON data: Data) -> Controls? {
        guard let p = try? JSONDecoder().decode(ControlsPayload.self, from: data) else { return nil }
        return Controls(liked: p.likeStatus.map { $0 == "liked" }, shuffling: p.shuffling, repeating: p.repeating,
                        volume: p.volume)
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

    /// 这首最先报的歌名与署名,连同报它时的 videoId。按队列补的那份另带队列里这一格的封面地址(入队时那份,是这首的
    /// 专辑图;网页播放器加载好之后读数里的那份可能换成视频截图)。
    public struct FirstReport: Equatable, Sendable {
        public let videoID: String
        public let title: String
        public let artist: String
        public let artworkURL: String?

        public init(videoID: String, title: String, artist: String, artworkURL: String? = nil) {
            self.videoID = videoID
            self.title = title
            self.artist = artist
            self.artworkURL = artworkURL
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
        return FirstReport(videoID: videoID, title: title, artist: artist, artworkURL: track.artworkURL)
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
    /// `(Official Audio)` 这类括号,或者前后多一段别的语言的歌名(《太陽之子》→《Children of the Sun 太陽之子》)。各自去掉
    /// 开头那段(破折号前得是这首的第一位歌手)和结尾的括号,剩下的忽略大小写、不分弯直引号:相等,或者短的那个按词完整
    /// 出现在长的里面(`containsAsWords`;短的至少 `minContainedTitleWeight`,一个汉字算 2、别的字母数字算 1,免得「Sun」
    /// 这种短名误配)才算。
    public static func sameSongTitle(_ a: String, _ b: String, artist: String) -> Bool {
        let x = titleCore(a, artist: artist), y = titleCore(b, artist: artist)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        return titleWeight(short) >= minContainedTitleWeight && containsAsWords(long, short)
    }

    /// 按词包含时短的那个至少多重(见 `titleWeight`)。
    static let minContainedTitleWeight = 4

    /// 按空白和括号切开后,短的那串词连续出现在长的里面。长的里有单独的破折号就不算:那多半是「另一位歌手 - 歌名」
    /// (破折号前不是这首的歌手,`titleCore` 没去掉)。
    private static func containsAsWords(_ long: String, _ short: String) -> Bool {
        let l = titleWords(long), s = titleWords(short)
        guard !s.isEmpty, s.count < l.count, !l.contains(where: { dashWords.contains($0) }) else { return false }
        return (0...(l.count - s.count)).contains { Array(l[$0..<($0 + s.count)]) == s }
    }

    private static let titleWordSeparators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "()[]（）【】「」『』《》"))
    private static let dashWords: Set<String> = ["-", "\u{2013}", "\u{2014}"]

    private static func titleWords(_ s: String) -> [String] {
        s.components(separatedBy: titleWordSeparators).filter { !$0.isEmpty }
    }

    /// 一个汉字算 2,别的字母数字算 1,标点空白不算。
    private static func titleWeight(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { sum, u in
            sum + (u.properties.isIdeographic ? 2 : (CharacterSet.alphanumerics.contains(u) ? 1 : 0))
        }
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
            let artworkURL: String?
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

    /// Kaset 内嵌网页此刻在放的那段媒体:WebKit 的媒体进程替 Kaset 报的那份系统会话。没有歌名歌手,只有时长和在不在放。
    /// 广告就在这里放:前贴片时 Kaset 自己还报加载,两首之间那段广告期间它还报着上一首、停在结尾,网页这边报的是广告自己
    /// 的时长、进度在走。
    public struct WebMedia: Equatable, Sendable {
        public let duration: Double?
        public let isPlaying: Bool
        /// 查询那一刻的进度,广告倒计时用(`MediaControlSnapshot.adElapsed`)。
        public let elapsed: Double?
        /// 锚点(那份会话最近一次发布时的进度、时刻、速率):正片在走时拿它当位置的时钟(`webClockPosition`)。
        public let anchorElapsed: Double?
        public let anchorAt: Date?
        public let rate: Double?

        public init(duration: Double?, isPlaying: Bool, elapsed: Double? = nil,
                    anchorElapsed: Double? = nil, anchorAt: Date? = nil, rate: Double? = nil) {
            self.duration = duration
            self.isPlaying = isPlaying
            self.elapsed = elapsed
            self.anchorElapsed = anchorElapsed
            self.anchorAt = anchorAt
            self.rate = rate
        }
    }

    /// WebKit 媒体进程的 bundle id。每个用到网页的 App 各有一个,同一个 bundle id,按负责进程分。
    public static let webMediaBundleID = "com.apple.WebKit.GPU"

    /// 从系统里各 App 报的会话里挑出 Kaset 内嵌网页的那一份:WebKit 媒体进程、负责进程是 Kaset(Safari 等别的 App 放视频
    /// 时也有一份,不拿)。挑不到返回 nil。
    public static func webMedia(in sessions: [NowPlayingClientsProbe.ClientSession], kasetPID: Int32) -> WebMedia? {
        let mine = sessions.filter { $0.bundleIdentifier == webMediaBundleID && $0.responsibleProcessIdentifier == kasetPID }
        guard let session = mine.first(where: { $0.playing == true }) ?? mine.first else { return nil }
        return WebMedia(duration: session.duration, isPlaying: session.playing == true, elapsed: session.elapsedTime,
                        anchorElapsed: session.anchorElapsedTime,
                        anchorAt: session.timestamp.map { Date(timeIntervalSince1970: $0) }, rate: session.playbackRate)
    }

    /// 网页那段跟这首的时长差不超过这么多秒,或者不超过这首时长的 `webMediaRelativeTolerance`,算同一段:网页 video 的
    /// 时长跟元数据的整数秒常差不到 1 秒,开播那一拍元数据还没更新时差几秒(《西西里》230 对 234)。
    public static let webMediaDurationTolerance: TimeInterval = 2
    public static let webMediaRelativeTolerance = 0.03

    /// 网页那边在放的是不是这首:跟这首的(网页那层或元数据里的)对得上 = 正片(false,还在缓冲);不到这首的一半 =
    /// 广告(true;广告 6~30 秒,歌是几分钟);别的(网页那段更长,放的是比元数据长的 MV 之类)、网页没在放、时长还没出来
    /// = 说不上来(nil)。
    public static func adByWebMedia(_ reading: Reading, web: WebMedia?) -> Bool? {
        guard let web, web.isPlaying, let duration = web.duration, duration > 0 else { return nil }
        let own = [reading.playerDuration, reading.trackDuration].compactMap { $0 }
        guard let shortest = own.min() else { return nil }
        if own.contains(where: { abs($0 - duration) <= max(webMediaDurationTolerance, $0 * webMediaRelativeTolerance) }) {
            return false
        }
        return duration < shortest / 2 ? true : nil
    }

    /// 网页时钟比 Kaset 自己的读数超前多少算对得上(秒):Kaset 的读数是网页每 0.5 秒推一次的 `video.currentTime`,只会
    /// 比真值晚 0~0.5 秒,再加一段消息往返;超出这个范围多半是那份锚点没跟上拖动 / 暂停,这一拍不用。
    public static let webClockLeadRange: ClosedRange<Double> = -0.3...1.0

    /// 这一拍按内嵌网页那份会话的播放时钟算位置(连续、精确;Kaset 自己的读数每 0.5 秒才变一次):网页在放的就是这首
    /// (`adByWebMedia` 判成正片)、速率大于 0、外推到 t 那一刻跟 Kaset 自己的读数对得上(`webClockLeadRange`)。
    /// 用得上返回 t 那一刻的位置,否则 nil。纯函数,selftest 覆盖。
    public static func webClockPosition(_ reading: Reading, web: WebMedia?, at t: Date) -> Double? {
        guard let web, web.isPlaying, adByWebMedia(reading, web: web) == false,
              let anchor = web.anchorElapsed, let anchorAt = web.anchorAt, let rate = web.rate, rate > 0 else { return nil }
        let position = anchor + t.timeIntervalSince(anchorAt) * rate
        guard webClockLeadRange.contains(position - reading.position) else { return nil }
        return position
    }

    /// 封面地址换成这么大见方的那一档。
    public static let coverArtworkEdge = 1200

    /// 能当封面用的封面地址,换成 `coverArtworkEdge` 见方的那一档:YouTube Music 曲库给音轨版本的方形专辑图在
    /// `*.googleusercontent.com`,地址结尾 `=w544-h544-l90-rj` 这样一段是尺寸参数,换成别的边长就给那个尺寸(实测 1200 档
    /// 1200×1200、3000 档 3000×3000)。视频截图(`i.ytimg.com`,16:9 或带黑边)不是封面,不要;没有尺寸参数的也不要。
    public static func coverArtworkURL(_ raw: String?) -> URL? {
        guard let raw, var components = URLComponents(string: raw), components.scheme == "https",
              let host = components.host, host.hasSuffix(".googleusercontent.com") else { return nil }
        let path = components.path
        guard let sizeStart = path.lastIndex(of: "="), path[path.index(after: sizeStart)...].hasPrefix("w") else { return nil }
        components.path = String(path[..<sizeStart]) + "=w\(coverArtworkEdge)-h\(coverArtworkEdge)-l90-rj"
        return components.url
    }

    /// 两份时长(网页 video 的、队列里登记的)差出这么多秒以上,放的就不是登记的那一版(元数据是整数秒)。
    public static let musicVideoLengthTolerance: TimeInterval = 3

    /// 这一拍放的是不是视频版(MV、用户上传的视频),跟网页播放器那边按视频类型认的是同一回事
    /// (`MusicVideoTimeline.isMusicVideoType`)。Kaset 不交视频类型,按它报的两样认,有一样就算:
    /// - 封面是这个 videoId 的视频截图(`i.ytimg.com/vi/<videoId>/…`):Kaset 的封面取自网页播放条,视频版是视频截图,
    ///   音轨版本是 googleusercontent 的方形专辑图。只认这一首的 videoId,换歌那一拍播放条上还是上一首的截图。
    /// - 网页 video 的时长跟队列里登记的差出 `musicVideoLengthTolerance` 以上:专辑页那一格链到 MV 时,登记的是歌曲版的
    ///   时长,放出来的是另一个长度的 MV。Kaset 换歌时先把时长设成新这首登记的,网页 video 加载好才换成它自己的。
    /// 纯函数,selftest 覆盖。
    public static func isMusicVideo(_ reading: Reading) -> Bool {
        if let id = reading.videoID, !id.isEmpty, let raw = reading.artworkURL, let url = URL(string: raw),
           url.scheme == "https", url.host?.lowercased() == "i.ytimg.com", url.path.hasPrefix("/vi/\(id)/") {
            return true
        }
        guard let player = reading.playerDuration, let track = reading.trackDuration else { return false }
        return abs(player - track) > musicVideoLengthTolerance
    }

    /// 换成下游用的快照。专辑一栏不用:放歌单时 Kaset 在这里填的是歌单名,不是这首的专辑。
    /// 没在走、又不是暂停(加载、广告、卡住)时标 `isWaitingToPlay`:轮询照播放中的节拍走,声音一走起来就接上。
    /// 广告结论(`isAd`):在放广告为 true,正片在走为 false,别的时候(加载、暂停、卡住)说不上来,为 nil。没在走时先看
    /// 内嵌网页在放什么(`adByWebMedia`,`webMedia` 是调用方这一拍问到的),说不上来再按读数自己认(`isAd`)。看网页判成广告时
    /// 快照另带广告自己的时长与进度(`adDuration` / `adElapsed`),倒计时用。在走、又有网页时钟算出的位置(`clockPosition`,
    /// 见 `webClockPosition`)时,位置用它,快照标精确(`positionIsPrecise`)。放的是视频版(`isMusicVideo`)时标 `isMusicVideo`。
    public static func snapshot(_ reading: Reading, lastMove: LastMove?, capturedAt: Date,
                                webMedia: WebMedia? = nil, clockPosition: Double? = nil) -> MediaControlSnapshot {
        let advancing = isAdvancing(reading, lastMove: lastMove, now: capturedAt)
        let precisePosition = advancing ? clockPosition : nil
        let webSaysAd = advancing ? nil : adByWebMedia(reading, web: webMedia)
        let ad: Bool? = advancing ? false : (webSaysAd ?? (isAd(reading) ? true : nil))
        return MediaControlSnapshot(
            title: reading.title, artist: cleanedArtist(reading.artist), album: nil, duration: reading.duration,
            elapsedTime: precisePosition ?? reading.position, playing: advancing, playbackRate: advancing ? 1 : 0,
            isMusicApp: true, bundleIdentifier: PlaybackPlayer.kaset.bundleIdentifier,
            anchorElapsedTime: nil, isRadio: nil, capturedAt: capturedAt,
            isMusicVideo: isMusicVideo(reading) ? true : nil,
            isWaitingToPlay: !advancing && !reading.isPaused, isAd: ad,
            adDuration: webSaysAd == true ? webMedia?.duration : nil, adElapsed: webSaysAd == true ? webMedia?.elapsed : nil,
            positionIsPrecise: precisePosition == nil ? nil : true)
    }
}
