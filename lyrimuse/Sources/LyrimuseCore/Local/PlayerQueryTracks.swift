import Foundation

/// App 代 collector 跑的播放器查询里,交回「一串曲目」的那几种 —— Music.app 的系统待播队列、当前列表往后几首、资料库里
/// 一张专辑的曲目,浏览器里 YouTube Music / Spotify 网页版的待播队列 —— 统一整理成这一份,`PlayerQueryServer` 把它的
/// JSON 放进应答的 `output`。加载器、AppleScript、网页 JS 的原始输出都在这里解析;collector 只解这份 JSON
/// (appquery.go 的 appQueryTracks),只做「当前这首对不对得上、往后取几首」。键名两边一起改,样例在
/// shared/testdata/player-query/。Kaset 的队列另有一份(`KasetPlayerInfo.QueueReply`)。
///
/// 这里只认形状:格式不对的记录丢掉,其余原样交出去(没有歌手的、MV 也交)—— 哪些能拿去预取由 collector 判。
public struct PlayerQueryTracks: Codable, Equatable, Sendable {
    public struct Track: Codable, Equatable, Sendable {
        public var title: String
        public var artist: String
        public var album: String?
        /// 秒;不知道是 nil。
        public var duration: Double?
        /// YouTube Music 队列里高亮的那一首(页面认为正在播的)。
        public var selected: Bool?
        /// YouTube Music 的 videoId。
        public var videoID: String?
        /// YouTube Music:这一首是 MV(`MusicVideoTimeline.isMusicVideoType`),时长是视频的长度,不是歌的长度。
        public var musicVideo: Bool?
        /// Spotify 网页版的曲目 uri。
        public var uri: String?

        enum CodingKeys: String, CodingKey {
            case title, artist, album, duration, selected, uri
            case videoID = "video_id"
            case musicVideo = "music_video"
        }

        public init(title: String, artist: String, album: String? = nil, duration: Double? = nil, selected: Bool? = nil,
                    videoID: String? = nil, musicVideo: Bool? = nil, uri: String? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.selected = selected
            self.videoID = videoID
            self.musicVideo = musicVideo
            self.uri = uri
        }
    }

    /// 播放器认为正在播的那首,collector 拿它跟手上那首核对;这一种查询不报(专辑曲目表;YouTube Music 看 `selected`)是 nil。
    public var current: Track?
    public var tracks: [Track]

    public init(current: Track? = nil, tracks: [Track] = []) {
        self.current = current
        self.tracks = tracks
    }

    /// 系统待播队列:App 包里那套加载器的输出 `{"items":[…]}`(`NowPlayingClientsProbe.queue`),第一项是 Music.app
    /// 认为正在播的那首,之后是打乱后的真实顺序。加载器报 null、不是 JSON 都当没有。
    public static func appleMusicSystemQueue(_ output: String) -> PlayerQueryTracks {
        struct Payload: Decodable {
            struct Item: Decodable {
                var title: String?
                var artist: String?
                var album: String?
                var duration: Double?
            }
            var items: [Item]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(output.utf8)),
              let first = payload.items.first else { return PlayerQueryTracks() }
        func track(_ item: Payload.Item) -> Track {
            Track(title: item.title ?? "", artist: item.artist ?? "", album: nonEmpty(item.album), duration: item.duration)
        }
        return PlayerQueryTracks(current: track(first), tracks: payload.items.dropFirst().map(track))
    }

    /// Music.app 当前列表往后几首(`PlayerQueryServer.appleMusicUpcomingScript` 的输出):第一行是它认为正在播的那首
    /// (名、歌手),其余每行 名、歌手、专辑、时长(秒),tab 分隔。守卫拦下时脚本回空串,当没有;没有歌名、列数不对的行丢掉。
    public static func appleMusicUpcoming(_ output: String) -> PlayerQueryTracks {
        let lines = output.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        guard let head = lines.first, !head.trimmingCharacters(in: .whitespaces).isEmpty else { return PlayerQueryTracks() }
        let h = head.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard h.count == 2 else { return PlayerQueryTracks() }
        var tracks: [Track] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, !parts[0].isEmpty else { continue }
            tracks.append(Track(title: parts[0], artist: parts[1], album: nonEmpty(parts[2]), duration: appleScriptReal(parts[3])))
        }
        return PlayerQueryTracks(current: Track(title: h[0], artist: h[1]), tracks: tracks)
    }

    /// 资料库里一张专辑的曲目(`PlayerQueryServer.appleMusicAlbumTracksScript`):每行 名、歌手、时长(秒),tab 分隔。
    /// 时长解不出按不知道,不丢这一行;列数不对的行丢掉。Music.app 没在跑时脚本回空串,曲目表是空的。
    public static func appleMusicAlbumTracks(_ output: String) -> PlayerQueryTracks {
        var tracks: [Track] = []
        for raw in output.components(separatedBy: "\n") {
            var line = Substring(raw)
            while line.hasSuffix("\r") { line = line.dropLast() }
            if line.isEmpty { continue }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            tracks.append(Track(title: parts[0], artist: parts[1], duration: appleScriptReal(parts[2])))
        }
        return PlayerQueryTracks(tracks: tracks)
    }

    /// YouTube Music 页面的待播队列(`PlayerQueryServer.youTubeMusicQueueJS`):每首一条记录,记录之间 RS、字段之间 US,
    /// 字段 selected(0/1)、title、artist、album、lengthText、videoId、musicVideoType(读不到为空,老页面没有这一段)。
    /// 找不到队列是 NOTFOUND。名字是任意文本,里面的换行压成空格;字段数不对、没有歌名的记录丢掉。
    public static func youTubeMusicQueue(_ output: String) -> PlayerQueryTracks {
        let s = unwrapBrowserOutput(output)
        guard !s.isEmpty, !s.contains("NOTFOUND") else { return PlayerQueryTracks() }
        var tracks: [Track] = []
        for record in s.components(separatedBy: "\u{1e}") {
            let f = record.components(separatedBy: "\u{1f}")
            guard f.count == 6 || f.count == 7 else { continue }
            let title = flattened(f[1])
            guard !title.isEmpty else { continue }
            let seconds = clockSeconds(f[4])
            let musicVideo = f.count == 7 && MusicVideoTimeline.isMusicVideoType(f[6].trimmingCharacters(in: .whitespaces))
            tracks.append(Track(title: title, artist: flattened(f[2]), album: nonEmpty(flattened(f[3])),
                                duration: seconds > 0 ? seconds : nil,
                                selected: f[0].trimmingCharacters(in: .whitespaces) == "1" ? true : nil,
                                videoID: nonEmpty(f[5].trimmingCharacters(in: .whitespaces)),
                                musicVideo: musicVideo ? true : nil))
        }
        return PlayerQueryTracks(tracks: tracks)
    }

    /// Spotify 网页版的待播队列(`PlayerQueryServer.spotifyWebQueueJS`):第一条记录是当前这首,之后按播放顺序;记录之间 RS、
    /// 字段之间 US,字段 title、artist、album、毫秒、uri。找不到播放器接口是 NOTFOUND;当前这首解不开(字段数不对、没有歌名)
    /// 就整份不信。后面字段数不对的记录丢掉。
    public static func spotifyWebQueue(_ output: String) -> PlayerQueryTracks {
        let s = unwrapBrowserOutput(output)
        guard !s.isEmpty, !s.contains("NOTFOUND") else { return PlayerQueryTracks() }
        var current: Track?
        var tracks: [Track] = []
        for (i, record) in s.components(separatedBy: "\u{1e}").enumerated() {
            let f = record.components(separatedBy: "\u{1f}")
            guard f.count == 5 else {
                if i == 0 { return PlayerQueryTracks() }
                continue
            }
            let ms = Double(f[3].trimmingCharacters(in: .whitespaces)) ?? 0
            let track = Track(title: flattened(f[0]), artist: flattened(f[1]), album: nonEmpty(flattened(f[2])),
                              duration: ms > 0 ? ms / 1000 : nil, uri: nonEmpty(f[4].trimmingCharacters(in: .whitespaces)))
            if i == 0 { current = track } else { tracks.append(track) }
        }
        guard let current, !current.title.isEmpty else { return PlayerQueryTracks() }
        return PlayerQueryTracks(current: current, tracks: tracks)
    }

    /// AppleScript 里实数转成的文本跟随系统地区的小数分隔符:德 / 法 / 俄等地区下 243.826 输出 "243,826"、12345.5 输出
    /// "1,23455E+4"。实数文本不带千分位,出现的逗号只可能是小数点。解不出是 nil。
    public static func appleScriptReal(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = s.firstIndex(of: ",") { s.replaceSubrange(comma...comma, with: ".") }
        return Double(s)
    }

    /// 浏览器 JS 探针的原始输出。Chromium 系的 `execute … javascript` 有时把返回的字符串再包一层双引号、并把里面的双引号
    /// 转义成真的反斜杠(见 BrowserTabProbeScript 头注);Safari 原样返回。歌名、专辑名里带双引号很常见,所以只在整段
    /// 首尾都是双引号时才当成包了一层:去掉外层、把转义的双引号还原。不能无条件去掉首尾引号,那会把以引号开头的歌名削掉一个字。
    static func unwrapBrowserOutput(_ raw: String) -> String {
        let quote = "\""
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.hasPrefix(quote), s.hasSuffix(quote) {
            s = String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\" + quote, with: quote)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "3:21" / "1:02:03" 换成秒;解不出是 0。
    static func clockSeconds(_ text: String) -> Double {
        let segments = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(segments.count) else { return 0 }
        var total = 0.0
        for segment in segments {
            guard let n = Int(segment), n >= 0 else { return 0 }
            total = total * 60 + Double(n)
        }
        return total
    }

    private static func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

/// Spotify 有没有开随机(`PlayerQueryServer.spotifyShuffleScript` 的输出 `true` / `false`)。没在跑时脚本回空,当问不到。
public struct PlayerQueryShuffle: Codable, Equatable, Sendable {
    public var shuffling: Bool

    public init(shuffling: Bool) {
        self.shuffling = shuffling
    }

    public static func parse(_ output: String) -> PlayerQueryShuffle? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return PlayerQueryShuffle(shuffling: true)
        case "false": return PlayerQueryShuffle(shuffling: false)
        default: return nil
        }
    }
}
