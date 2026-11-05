import AppKit
import Foundation
import os

/// Pear Desktop 的本机接口:它「插件」菜单里的 API 服务器(默认关着),本机 HTTP,默认端口 26538。开着时补上系统会话给不了的几样:
/// 这首的 videoId(引擎按它取 YouTube Music 自己那版歌词、拼歌曲页、判播客,同 Kaset)、类型(MV / 播客)、播放队列。
/// 没开、没授权、连不上时什么都不做,各处照旧只用系统会话。见 02 章决策 226。
///
/// 开没开、端口、要不要授权读它的配置文件(按修改时间缓存),不去试端口。授权策略是「首次请求时授权」时,用固定的客户端 ID
/// 要一次令牌,Pear 会弹框问用户;允许过的 ID 它记着,以后再要不弹框。用户点了拒绝就记下来,不再自己去要,直到设置里点「重新请求」。
public final class PearDesktopAPI: @unchecked Sendable {
    public static let shared = PearDesktopAPI()

    public static let clientID = "lyrimuse"
    public static let defaultPort = 26538
    /// 一次读歌曲 / 队列最多等这么久。都在本机,连不上是立刻拒绝,慢只可能是它在忙。
    public static let requestTimeout: TimeInterval = 0.5
    /// 搜索(`POST /api/v1/search`)要它向 YouTube Music 问一趟,实测一两秒。只在用户点了「在 Pear Desktop 中播放」时用。
    public static let searchTimeout: TimeInterval = 8
    /// 要令牌最多等这么久:第一次要时 Pear 弹框,等用户点。
    public static let authorizationTimeout: TimeInterval = 120
    /// 读到的这首在这么久内直接复用(系统会话每拍都会来问)。
    public static let songReuseSecs: TimeInterval = 1.5
    /// 要令牌失败(连不上)之后隔这么久再试。
    public static let authorizationRetrySecs: TimeInterval = 10
    /// 用户在 Pear 里拒绝过授权(只有设置里「重新请求」才清掉)。
    public static let deniedDefaultsKey = "pearDesktop:apiDenied"

    public struct Config: Equatable, Sendable {
        public let enabled: Bool
        public let port: Int
        /// 它监听的地址(`hostname`,默认 0.0.0.0 = 所有网卡)。
        public let hostname: String
        /// 授权策略不是「无需授权」:要先要令牌。
        public let needsToken: Bool
        public let usesHTTPS: Bool

        public init(enabled: Bool, port: Int, hostname: String, needsToken: Bool, usesHTTPS: Bool) {
            self.enabled = enabled
            self.port = port
            self.hostname = hostname
            self.needsToken = needsToken
            self.usesHTTPS = usesHTTPS
        }

        /// 同一网络里的设备不用授权就能控制它:监听的不是本机回环地址、又选了「无需授权」。
        public var lanReachableWithoutToken: Bool {
            !needsToken && !Self.loopbackHosts.contains(hostname.lowercased())
        }

        /// 去连哪个地址:监听所有网卡或本机时连 127.0.0.1;只监听某一个地址时连那个地址。
        public var connectHost: String {
            let h = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return h.isEmpty || h == "0.0.0.0" || h == "::" || Self.loopbackHosts.contains(h) ? "127.0.0.1" : hostname
        }

        static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
    }

    /// 设置页那一行显示的状态。
    public enum Link: Equatable, Sendable {
        /// 接口没开(或者没装 Pear、读不到配置)。
        case off
        /// 开了,等用户在 Pear 里点「允许」。
        case waiting
        /// 用户在 Pear 里点了拒绝。
        case denied
        /// 开了但连不上(Pear 没在跑、开了 HTTPS)。
        case unreachable
        case connected
    }

    /// `GET /api/v1/song` 里用得到的几样。
    public struct Song: Equatable, Sendable {
        public let title: String
        public let artist: String
        public let album: String?
        public let videoID: String
        /// Pear 判的类型:`AUDIO`、`ORIGINAL_MUSIC_VIDEO`、`USER_GENERATED_CONTENT`、`PODCAST_EPISODE`、`OTHER_VIDEO`。
        public let mediaType: String?
        public let duration: Double?
        public let isPaused: Bool?
        /// 整秒的进度(它窗口在后台时可能停在旧值,只拿来认「还在开头」)。
        public let elapsed: Double?

        public init(title: String, artist: String, album: String?, videoID: String, mediaType: String?, duration: Double?, isPaused: Bool?,
                    elapsed: Double? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.videoID = videoID
            self.mediaType = mediaType
            self.duration = duration
            self.isPaused = isPaused
            self.elapsed = elapsed
        }

        public var isPodcastEpisode: Bool { mediaType == "PODCAST_EPISODE" }

        /// true = 视频版(官方 MV、用户上传),false = 歌曲版,nil = 它也说不上来(`OTHER_VIDEO`、没给)。
        public var isMusicVideo: Bool? {
            switch mediaType {
            case "AUDIO": return false
            case "ORIGINAL_MUSIC_VIDEO", "USER_GENERATED_CONTENT": return true
            default: return nil
            }
        }
    }

    // MARK: - 纯函数

    /// 配置文件里 `plugins.api-server` 那几项;解不开、没有这一段时 nil(插件从没开过时配置里没有这一段)。
    public static func config(in data: Data?) -> Config? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = object["plugins"] as? [String: Any],
              let api = plugins["api-server"] as? [String: Any] else { return nil }
        let rawPort = api["port"]
        let port = (rawPort as? NSNumber)?.intValue ?? (rawPort as? String).flatMap { Int($0) } ?? defaultPort
        return Config(enabled: api["enabled"] as? Bool ?? false,
                      port: (1...65535).contains(port) ? port : defaultPort,
                      hostname: api["hostname"] as? String ?? "0.0.0.0",
                      needsToken: (api["authStrategy"] as? String ?? "AUTH_AT_FIRST") != "NONE",
                      usesHTTPS: api["useHttps"] as? Bool ?? false)
    }

    /// `GET /api/v1/song` 的应答;没有歌(204)、解不开、没有 videoId 时 nil。
    public static func song(from data: Data?) -> Song? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let videoID = object["videoId"] as? String, isVideoID(videoID),
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let album = (object["album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = (object["songDuration"] as? NSNumber)?.doubleValue
        return Song(title: title, artist: (object["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    album: album?.isEmpty == false ? album : nil, videoID: videoID,
                    mediaType: object["mediaType"] as? String,
                    duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                    isPaused: object["isPaused"] as? Bool, elapsed: (object["elapsedSeconds"] as? NSNumber)?.doubleValue)
    }

    /// 系统会话这一首像不像广告:接口说在放的是另一首(前贴片广告期间它报的是接下来那首,进度跟着广告走、可能暂停着),而系统
    /// 会话这一首从没跟接口对上过(`everMatched`;挡换歌那一下接口先跳到新歌、系统会话还停在上一首)。要连着像上
    /// `adSettleSecs` 才认(`reading(for:)`):接口偶尔慢半拍时新歌也会像一拍。纯函数,selftest 覆盖。
    public static func looksLikeAd(systemTitle: String?, systemArtist: String?, systemDuration: Double?, apiSong: Song,
                                   everMatched: Bool) -> Bool {
        !everMatched && !describes(apiSong, title: systemTitle, artist: systemArtist, duration: systemDuration)
    }

    /// 一首要连着像广告这么久才认成广告;在这之前压着不报(`Reading.undecided`)。广告最短也有几秒。
    public static let adSettleSecs: TimeInterval = 1.5

    /// 接口读到的这首是不是系统会话正报的这一首:歌名一样(不分大小写、去首尾空白);歌名对不上时,歌手一样、时长差不过 2 秒也算
    /// (同一首两边的歌名写法偶尔不一样)。
    public static func describes(_ song: Song, title: String?, artist: String?, duration: Double?) -> Bool {
        func norm(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if !norm(title).isEmpty, norm(title) == norm(song.title) { return true }
        guard !norm(artist).isEmpty, norm(artist) == norm(song.artist),
              let a = duration, let b = song.duration else { return false }
        return abs(a - b) <= 2
    }

    /// YouTube 的 videoId:11 位字母数字加 `-` `_`(同 `PlatformLinks.youtubeMusicWatchURL` 那道闸)。
    public static func isVideoID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `GET /api/v1/queue` 的应答(YouTube Music 网页的队列原样)连同 `GET /api/v1/repeat-mode` 的 `mode`,整理成跟 Kaset
    /// 同一种回包(引擎 kasetqueue.go 解)。每一格是 `playlistPanelVideoRenderer`,或包在 `playlistPanelVideoWrapperRenderer`
    /// 的 `primaryRenderer` 里(那种还带着另一个版本:歌曲版 / 视频版);放的是 `primaryRenderer`。当前这首是 `selected` 的那一格。
    /// 署名那一串(`longBylineText`)是「歌手 • 专辑 • 年份」,歌手取第一个「 • 」之前的,专辑取跳到专辑页的那一段。
    public static func queueReply(queueJSON: Data?, repeatMode: String?) -> KasetPlayerInfo.QueueReply? {
        queueItems(queueJSON).flatMap { queueReply(items: $0, repeatMode: repeatMode) }
    }

    /// 队列应答里的各格;解不开、没有格子时 nil。
    static func queueItems(_ queueJSON: Data?) -> [[String: Any]]? {
        guard let queueJSON, let object = try? JSONSerialization.jsonObject(with: queueJSON) as? [String: Any],
              let items = object["items"] as? [[String: Any]], !items.isEmpty else { return nil }
        return items
    }

    /// 这一格放的那个版本(`playlistPanelVideoRenderer` 本身,或 wrapper 的 `primaryRenderer`)。
    static func primaryRenderer(_ item: [String: Any]) -> [String: Any]? {
        (item["playlistPanelVideoRenderer"] as? [String: Any])
            ?? (((item["playlistPanelVideoWrapperRenderer"] as? [String: Any])?["primaryRenderer"] as? [String: Any])?[
                "playlistPanelVideoRenderer"] as? [String: Any])
    }

    /// 队列里认得出的各格,按接口 `/song` 的写法交成 `Song`(类型由这一格的版本类型换算,同 Pear 自己的 `mediaType`)。换歌那一拍
    /// 接口还停在上一首时拿它认新歌(`reading(for:)`)。纯函数,selftest 覆盖。
    public static func queueSongs(queueJSON: Data?) -> [Song] {
        queueItems(queueJSON).map(queueSongs(items:)) ?? []
    }

    static func queueSongs(items: [[String: Any]]) -> [Song] {
        items.compactMap { item in
            guard let r = primaryRenderer(item), let id = r["videoId"] as? String, isVideoID(id) else { return nil }
            let title = runsText(r["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let byline = bylineParts(r["longBylineText"])
            return Song(title: title, artist: byline.artist, album: byline.album, videoID: id,
                        mediaType: musicVideoType(r).flatMap { queueMediaTypes[$0] },
                        duration: durationSecs(runsText(r["lengthText"])), isPaused: nil)
        }
    }

    /// 队列格的版本类型 → 接口 `mediaType`;不在表里的给 nil(说不上是不是视频版)。
    static let queueMediaTypes = [
        "MUSIC_VIDEO_TYPE_ATV": "AUDIO",
        "MUSIC_VIDEO_TYPE_OMV": "ORIGINAL_MUSIC_VIDEO",
        "MUSIC_VIDEO_TYPE_UGC": "USER_GENERATED_CONTENT",
        "MUSIC_VIDEO_TYPE_PODCAST_EPISODE": "PODCAST_EPISODE",
    ]

    /// 队列里歌名跟系统会话这一首一样的那一格(不分大小写、去首尾空白);只认歌名,同一张专辑里时长相近的别的歌不算。纯函数,selftest 覆盖。
    public static func queuedSong(in songs: [Song], title: String?) -> Song? {
        songs.first { describes($0, title: title, artist: nil, duration: nil) }
    }

    static func queueReply(items: [[String: Any]], repeatMode: String?) -> KasetPlayerInfo.QueueReply? {
        var tracks: [KasetPlayerInfo.QueueReply.Track] = []
        var current: Int?
        for item in items {
            let wrapper = item["playlistPanelVideoWrapperRenderer"] as? [String: Any]
            guard let r = primaryRenderer(item) else {
                tracks.append(.init(title: "", artist: "", duration: nil, videoID: nil))
                continue
            }
            if r["selected"] as? Bool == true, current == nil { current = tracks.count }
            let videoID = (r["videoId"] as? String).flatMap { isVideoID($0) ? $0 : nil }
            // 歌曲版的 videoId:这一格本身是歌曲版就是它,否则取配对的另一个版本里是歌曲版的那个。
            var audioVideoID: String? = musicVideoType(r) == "MUSIC_VIDEO_TYPE_ATV" ? videoID : nil
            if audioVideoID == nil, let counterparts = wrapper?["counterpart"] as? [[String: Any]] {
                for c in counterparts {
                    guard let cr = (c["counterpartRenderer"] as? [String: Any])?["playlistPanelVideoRenderer"] as? [String: Any],
                          musicVideoType(cr) == "MUSIC_VIDEO_TYPE_ATV",
                          let id = cr["videoId"] as? String, isVideoID(id) else { continue }
                    audioVideoID = id
                    break
                }
            }
            let byline = bylineParts(r["longBylineText"])
            tracks.append(.init(title: runsText(r["title"]).trimmingCharacters(in: .whitespacesAndNewlines),
                                artist: byline.artist, duration: durationSecs(runsText(r["lengthText"])),
                                videoID: videoID, audioVideoID: audioVideoID ?? videoID, album: byline.album))
        }
        guard tracks.contains(where: { !$0.title.isEmpty }) else { return nil }
        let repeating: String
        switch repeatMode {
        case "ONE": repeating = "one"
        case "ALL": repeating = "all"
        default: repeating = "off"
        }
        return KasetPlayerInfo.QueueReply(currentIndex: current, repeating: repeating, tracks: tracks)
    }

    /// 随机开关(`GET /api/v1/shuffle`,读的是播放条的 `shuffle-on`,能保持)加循环档(`GET /api/v1/repeat-mode` 的 NONE / ALL / ONE)
    /// 换成播放模式,规则同 Kaset(`MusicPlaybackController.kasetPlaybackMode`:单曲循环优先,其次随机);任一项读不到为 nil。
    public static func playbackMode(shuffle: Bool?, repeatMode: String?) -> MusicPlaybackController.MusicPlaybackMode? {
        let repeating: String?
        switch repeatMode {
        case "NONE": repeating = "off"
        case "ALL": repeating = "all"
        case "ONE": repeating = "one"
        default: repeating = nil
        }
        return MusicPlaybackController.kasetPlaybackMode(shuffling: shuffle, repeating: repeating)
    }

    public static let modeOptions: MusicPlaybackController.PlaybackModeOptions = .all

    /// 换到某一档要做什么:随机开关要不要按(`POST /api/v1/shuffle` 是切换)、循环键按几下(它按一下:关 → 列表循环 → 单曲循环 → 关),
    /// 以及按完应该读到的两项。语义同 Kaset(`kasetPlaybackModeScript`):随机和循环互斥,「列表」「随机」只把单曲循环关掉,
    /// 列表循环开着就留着。读不到现在的状态时为 nil。
    public struct ModePlan: Equatable, Sendable {
        public let toggleShuffle: Bool
        public let repeatPresses: Int
        public let shuffle: Bool
        public let repeatMode: String

        public init(toggleShuffle: Bool, repeatPresses: Int, shuffle: Bool, repeatMode: String) {
            self.toggleShuffle = toggleShuffle
            self.repeatPresses = repeatPresses
            self.shuffle = shuffle
            self.repeatMode = repeatMode
        }
    }

    public static func modePlan(shuffle: Bool?, repeatMode: String?,
                                to target: MusicPlaybackController.MusicPlaybackMode) -> ModePlan? {
        let order = ["NONE", "ALL", "ONE"]
        guard let shuffle, let repeatMode, let from = order.firstIndex(of: repeatMode) else { return nil }
        let wantShuffle = target == .shuffle
        let wantRepeat: String
        switch target {
        case .list, .shuffle: wantRepeat = repeatMode == "ONE" ? "NONE" : repeatMode
        case .repeatAll: wantRepeat = "ALL"
        case .repeatOne: wantRepeat = "ONE"
        }
        let to = order.firstIndex(of: wantRepeat)!
        return ModePlan(toggleShuffle: shuffle != wantShuffle, repeatPresses: (to - from + order.count) % order.count,
                        shuffle: wantShuffle, repeatMode: wantRepeat)
    }

    /// 读到的音量换成它播放条滑块的位置(0~100)。接口写的是滑块位置(`updateVolume`),读回来的是播放器的音量(`getVolume`),
    /// YouTube Music 在两者之间套了一条曲线:读数 = 100 × (16^(滑块/100) − 1) / 15(实测 10→2、50→20、80→55、90→74、100→100)。
    /// 读数只到整数,低音量那头反算会差一两格。静音算 0。
    public static func sliderVolume(fromPlayerVolume volume: Double, muted: Bool) -> Int {
        guard !muted, volume.isFinite, volume > 0 else { return 0 }
        let v = min(100, volume)
        return Int((100 * log(1 + 0.15 * v) / log(16)).rounded())
    }

    /// `{"runs": [{"text": …}, …]}` 拼成一串;也认 `{"simpleText": …}`。
    static func runsText(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else { return "" }
        if let simple = dict["simpleText"] as? String { return simple }
        return (dict["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }

    /// 署名串里的歌手与专辑。歌手是第一个「 • 」之前的各段原样连起来(「A & B」);专辑是跳到专辑页那一段,没有为 nil(MV、单曲)。
    static func bylineParts(_ value: Any?) -> (artist: String, album: String?) {
        let runs = (value as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        var artist = ""
        var album: String?
        var beforeSeparator = true
        for run in runs {
            let text = run["text"] as? String ?? ""
            if text.trimmingCharacters(in: .whitespaces) == "•" {
                beforeSeparator = false
                continue
            }
            if beforeSeparator { artist += text }
            let pageType = ((((run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?[
                "browseEndpointContextSupportedConfigs"] as? [String: Any])?["browseEndpointContextMusicConfig"] as? [String: Any])?[
                "pageType"] as? String
            if pageType == "MUSIC_PAGE_TYPE_ALBUM", album == nil {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { album = t }
            }
        }
        return (artist.trimmingCharacters(in: .whitespacesAndNewlines), album)
    }

    /// 「4:03」「1:02:03」换成秒;认不出为 nil。
    static func durationSecs(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let secs = parts.reduce(0) { $0 * 60 + $1! }
        return secs > 0 ? Double(secs) : nil
    }

    /// 队列里这一格的版本类型(`MUSIC_VIDEO_TYPE_ATV` 是歌曲版)。
    static func musicVideoType(_ renderer: [String: Any]) -> String? {
        ((((renderer["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?[
            "watchEndpointMusicSupportedConfigs"] as? [String: Any])?["watchEndpointMusicConfig"] as? [String: Any])?[
            "musicVideoType"] as? String
    }

    // MARK: - 状态

    private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "pear-api")
    private let lock = NSLock()
    private var cachedConfig: (modified: Date, config: Config?)?
    private var token: String?
    private var authorizing = false
    private var lastAuthorizationFailure: Date?
    private var reachable = false
    private var lastSong: (song: Song?, at: Date)?
    private var lastVideo: (trackKey: String, videoID: String)?
    /// 跟接口对上过的系统会话曲目(`trackKey`),认广告时排除。
    private var matchedTrackKeys: Set<String> = []
    /// 正在看像不像广告的那一段(歌名,归一过)和开始像的时刻。
    private var adCandidate: (title: String, since: Date)?
    /// 最近一次读到的队列(引擎预取代读时、或换歌那一拍现读时存下)。
    private var queueCache: [Song]?
    /// 现读过一次队列也没找到的那个歌名(归一过):同一段不再现读,广告期间不会每拍拉一次整个队列。
    private var queueMissTitle: String?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = PearDesktopAPI.authorizationTimeout
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    private init() {}

    public static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/YouTube Music/config.json")
    }

    /// 它配置里的接口设置(按修改时间缓存)。没装、没开过插件时 nil。
    public func currentConfig() -> Config? {
        let url = Self.configURL
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
            return nil
        }
        lock.lock()
        if let cached = cachedConfig, cached.modified == modified {
            lock.unlock()
            return cached.config
        }
        lock.unlock()
        let config = Self.config(in: FileIO.read(url))
        lock.lock()
        cachedConfig = (modified, config)
        lock.unlock()
        return config
    }

    /// 设置页那一行的状态。
    public func link() -> Link {
        guard let config = currentConfig(), config.enabled else { return .off }
        lock.lock()
        defer { lock.unlock() }
        if config.needsToken && token == nil {
            if UserDefaults.standard.bool(forKey: Self.deniedDefaultsKey) { return .denied }
            if authorizing { return .waiting }
        }
        return reachable && !config.usesHTTPS ? .connected : .unreachable
    }

    /// 每拍轮询时调(设置认 Pear 时):Pear 开着、接口开着、要授权又还没令牌,就去要;推送(`PearDesktopPush`)能连就保持连着,
    /// Pear 没开、接口不能用时断开。读配置按修改时间缓存,没开时只是一次 stat。
    public func noteAppRunning(_ running: Bool) {
        if running, let config = currentConfig(), config.enabled, config.needsToken, !config.usesHTTPS {
            authorizeIfNeeded(config)
        }
        PearDesktopPush.shared.keepAlive(url: running ? pushURL() : nil)
    }

    /// 推送的地址:`ws://<接口地址>/api/v1/ws`,要授权时带上令牌。接口不能用、还没令牌时 nil。
    func pushURL() -> URL? {
        guard let config = usableConfig(), let base = baseURL(config)?.appendingPathComponent("/api/v1/ws"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "ws"
        if config.needsToken {
            lock.lock()
            let token = self.token
            lock.unlock()
            guard let token else { return nil }
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components.url
    }

    /// 设置里「重新请求」:清掉拒绝的记录,马上再要一次令牌。
    public func requestAuthorizationAgain() {
        UserDefaults.standard.removeObject(forKey: Self.deniedDefaultsKey)
        lock.lock()
        lastAuthorizationFailure = nil
        lock.unlock()
        if let config = currentConfig(), config.enabled { authorizeIfNeeded(config) }
    }

    /// 系统会话这一拍报的 Pear 那一首,按接口认出来的结论。
    public enum Reading: Equatable, Sendable {
        /// 接口说的就是这一首。
        case song(Song)
        /// 系统会话这一首是广告(连着像了 `adSettleSecs`)。
        case ad
        /// 像广告、还没像够 `adSettleSecs`:这一拍压着不报,免得把一拍真歌当广告写进播放状态(引擎看到一次就整首不搜词、不记收听)。
        case undecided
    }

    /// 系统会话这一拍报的是 Pear:读它此刻的这首(`songReuseSecs` 内复用),是同一首就记下 videoId;不是同一首时先到队列里找,
    /// 找不到再看是不是广告。接口没开、没授权、连不上、对不上又不像广告时 nil。在轮询线程上调,每次读接口最多等 `requestTimeout`。
    public func reading(for snapshot: MediaControlSnapshot) -> Reading? {
        if let song = song(matching: snapshot) {
            lock.lock()
            adCandidate = nil
            lock.unlock()
            return .song(song)
        }
        lock.lock()
        let everMatched = matchedTrackKeys.contains(snapshot.trackKey)
        let suspicious = lastSong?.song.map {
            Self.looksLikeAd(systemTitle: snapshot.title, systemArtist: snapshot.artist, systemDuration: snapshot.duration,
                             apiSong: $0, everMatched: everMatched)
        } ?? false
        if !suspicious { adCandidate = nil }
        lock.unlock()
        guard suspicious else { return nil }
        // 换歌时系统会话比接口的 `/song` 早一秒多换成新歌:新歌在队列里就按那一格认,不等接口;广告不在队列里(02 章决策 233)。
        if let queued = queuedSong(matching: snapshot) {
            noteMatched(queued, snapshot: snapshot, via: "queue")
            lock.lock()
            adCandidate = nil
            lock.unlock()
            return .song(queued)
        }
        lock.lock()
        defer { lock.unlock() }
        // 按歌名认是不是同一段:广告第一帧常常没有歌手、下一帧才补上,两种写法的快照还会交替出现,按 trackKey 认会一直重来。
        let title = Self.normalizedTitle(snapshot.title)
        guard let candidate = adCandidate, candidate.title == title else {
            adCandidate = (title, Date())
            return .undecided
        }
        return Date().timeIntervalSince(candidate.since) >= Self.adSettleSecs ? .ad : .undecided
    }

    static func normalizedTitle(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 队列里跟系统会话这一首同名的那一格:先查存下的队列,没有再现读一次(同一个歌名只现读一次)。
    private func queuedSong(matching snapshot: MediaControlSnapshot) -> Song? {
        let title = Self.normalizedTitle(snapshot.title)
        guard !title.isEmpty else { return nil }
        lock.lock()
        let cached = queueCache
        let missed = queueMissTitle == title
        lock.unlock()
        if let hit = cached.flatMap({ Self.queuedSong(in: $0, title: snapshot.title) }) { return hit }
        guard !missed, let config = currentConfig(), config.enabled, !config.usesHTTPS else { return nil }
        lock.lock()
        let missingToken = config.needsToken && token == nil
        lock.unlock()
        guard !missingToken, let data = get("/api/v1/queue", config: config) else { return nil }
        let songs = Self.queueSongs(queueJSON: data)
        let hit = Self.queuedSong(in: songs, title: snapshot.title)
        lock.lock()
        queueCache = songs
        queueMissTitle = hit == nil ? title : nil
        lock.unlock()
        return hit
    }

    /// 记下系统会话这一首对上了哪个 videoId(写播放状态时带给引擎,认广告时排除它)。
    private func noteMatched(_ song: Song, snapshot: MediaControlSnapshot, via source: String) {
        lock.lock()
        defer { lock.unlock() }
        if lastVideo?.videoID != song.videoID {
            logger.notice("pear api: \(song.videoID, privacy: .public) is \(song.mediaType ?? "unknown", privacy: .public) (\(source, privacy: .public))")
        }
        lastVideo = (snapshot.trackKey, song.videoID)
        matchedTrackKeys.insert(snapshot.trackKey)
        if matchedTrackKeys.count > 64 { matchedTrackKeys = [snapshot.trackKey] }
    }

    private func song(matching snapshot: MediaControlSnapshot) -> Song? {
        guard let config = currentConfig(), config.enabled, !config.usesHTTPS else { return nil }
        lock.lock()
        let needsToken = config.needsToken && token == nil
        let reuse = lastSong.flatMap { Date().timeIntervalSince($0.at) < Self.songReuseSecs ? $0.song : nil }
        lock.unlock()
        if needsToken {
            authorizeIfNeeded(config)
            return nil
        }
        var song = reuse.flatMap { Self.describes($0, title: snapshot.title, artist: snapshot.artist, duration: snapshot.duration) ? $0 : nil }
        if song == nil {
            let fetched = get("/api/v1/song", config: config).map { Self.song(from: $0) } ?? nil
            lock.lock()
            lastSong = (fetched, Date())
            lock.unlock()
            song = fetched.flatMap { Self.describes($0, title: snapshot.title, artist: snapshot.artist, duration: snapshot.duration) ? $0 : nil }
        }
        if let song { noteMatched(song, snapshot: snapshot, via: "song") }
        return song
    }

    /// 最近一次对上的那首(按快照的 `trackKey` 认)的 videoId;不是这首、没对上过为 nil。
    public func videoID(forTrackKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastVideo, last.trackKey == key else { return nil }
        return last.videoID
    }

    /// 队列连同循环模式(引擎经 `PlayerQueryServer` 来问)。接口没开、没授权、读不到时 nil。
    public func queueReply() -> KasetPlayerInfo.QueueReply? {
        guard let config = currentConfig(), config.enabled, !config.usesHTTPS else { return nil }
        lock.lock()
        let missingToken = config.needsToken && token == nil
        lock.unlock()
        guard !missingToken, let queue = get("/api/v1/queue", config: config) else { return nil }
        let mode = get("/api/v1/repeat-mode", config: config)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["mode"] as? String
        guard let items = Self.queueItems(queue) else { return nil }
        let songs = Self.queueSongs(items: items)
        lock.lock()
        queueCache = songs
        queueMissTitle = nil
        lock.unlock()
        return Self.queueReply(items: items, repeatMode: mode)
    }

    /// 现在的随机开关和循环档;接口没开、没授权、读不到时 nil。
    private func modeParts(_ config: Config) -> (shuffle: Bool?, repeatMode: String?) {
        let shuffle = get("/api/v1/shuffle", config: config)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["state"] as? Bool
        let repeatMode = get("/api/v1/repeat-mode", config: config)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["mode"] as? String
        return (shuffle, repeatMode)
    }

    /// 现在的播放模式(随机 + 循环);接口没开、没授权、读不到时 nil。
    public func playbackMode() -> MusicPlaybackController.PlaybackModeState? {
        guard let config = usableConfig() else { return nil }
        let parts = modeParts(config)
        return Self.playbackMode(shuffle: parts.shuffle, repeatMode: parts.repeatMode).map { .init(mode: $0, options: Self.modeOptions) }
    }

    /// 换到这一档:按 `modePlan` 切随机、按循环键,再把两项读回来,合成的档位就是要的那一档才回 true。从列表循环要「列表」时
    /// 列表循环按规则留着,合成出来是列表循环,回 false,调用方据此回读、把乐观画上的「列表」纠回去。
    public func setPlaybackMode(_ mode: MusicPlaybackController.MusicPlaybackMode) -> Bool {
        guard let config = usableConfig() else { return false }
        let parts = modeParts(config)
        guard let plan = Self.modePlan(shuffle: parts.shuffle, repeatMode: parts.repeatMode, to: mode) else { return false }
        if plan.toggleShuffle, post("/api/v1/shuffle", body: [:], config: config) != 204 { return false }
        if plan.repeatPresses > 0, post("/api/v1/switch-repeat", body: ["iteration": plan.repeatPresses], config: config) != 204 { return false }
        let after = modeParts(config)
        return Self.playbackMode(shuffle: after.shuffle, repeatMode: after.repeatMode) == mode
    }

    /// `GET /api/v1/like-state` 的值 → 赞了没有(踩过算没赞);认不出为 nil。
    public static func liked(fromState state: String?) -> Bool? {
        switch state {
        case "LIKE": return true
        case "DISLIKE", "INDIFFERENT": return false
        default: return nil
        }
    }

    /// 当前这首赞了没有;接口没开、没授权、读不到时 nil。
    public func liked() -> Bool? {
        guard let config = usableConfig() else { return nil }
        let state = get("/api/v1/like-state", config: config)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["state"] as? String
        return Self.liked(fromState: state)
    }

    /// 赞 / 取消赞。`POST /api/v1/like` 是切换(赞过再发就取消,踩过的发了变成赞,实测),跟要的不一样才发;发完读回,
    /// 不是要的样子就回 false(没登录 YouTube Music 时它不理这条),调用方据此回读纠正。
    public func setLiked(_ value: Bool) -> Bool {
        guard let config = usableConfig(), let current = liked() else { return false }
        if current != value, post("/api/v1/like", body: [:], config: config) != 204 { return false }
        return liked() == value
    }

    /// 现在的音量,按它播放条滑块的位置(0~100,见 `sliderVolume`);读不到 nil。
    public func volume() -> Int? {
        guard let config = usableConfig(),
              let object = get("/api/v1/volume", config: config).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let state = (object["state"] as? NSNumber)?.doubleValue else { return nil }
        return Self.sliderVolume(fromPlayerVolume: state, muted: object["isMuted"] as? Bool ?? false)
    }

    /// 设它播放条滑块的位置(0~100)。
    public func setVolume(_ value: Int) -> Bool {
        guard let config = usableConfig() else { return false }
        return post("/api/v1/volume", body: ["volume": min(100, max(0, value))], config: config) == 204
    }

    /// 能不能直接经接口让它干活:它开着、接口开着、该有的令牌有了。不发请求,主线程上也能调。停播页据此给不给「继续播放」:
    /// 它冷启动时自己跳到前台(同 reAMP、VOX),没开着时只给「打开」。
    public func canControl() -> Bool {
        guard usableConfig() != nil else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: PlaybackPlayer.pearDesktop.bundleIdentifier).isEmpty
    }

    /// 搜索结果(`POST /api/v1/search` 回的 YouTube Music 搜索应答)里歌名对得上的那首歌的 videoId:只认标成「歌曲」的音轨版
    /// (`MUSIC_VIDEO_TYPE_ATV`),排第一的热门结果常是 MV,不拿。歌名先找去掉空白和大小写后完全一样的,没有再找以它开头的
    /// (「晴天 (Live)」这类)。纯函数,selftest 覆盖。
    public static func songVideoID(inSearch data: Data, title: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var songs: [(title: String, videoID: String)] = []
        func firstString(_ key: String, in object: Any) -> String? {
            if let dict = object as? [String: Any] {
                if let value = dict[key] as? String { return value }
                for value in dict.values { if let hit = firstString(key, in: value) { return hit } }
            } else if let array = object as? [Any] {
                for value in array { if let hit = firstString(key, in: value) { return hit } }
            }
            return nil
        }
        func walk(_ object: Any) {
            if let dict = object as? [String: Any] {
                if let item = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                    let columns = item["flexColumns"] as? [[String: Any]]
                    let runs = ((columns?.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]
                        as? [String: Any])?["runs"] as? [[String: Any]]
                    if firstString("musicVideoType", in: item) == "MUSIC_VIDEO_TYPE_ATV",
                       let name = runs?.first?["text"] as? String,
                       let videoID = (item["playlistItemData"] as? [String: Any])?["videoId"] as? String ?? firstString("videoId", in: item) {
                        songs.append((name, videoID))
                    }
                    return
                }
                dict.values.forEach(walk)
            } else if let array = object as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)
        func folded(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let want = folded(title)
        guard !want.isEmpty else { return nil }
        return songs.first { folded($0.title) == want }?.videoID ?? songs.first { folded($0.title).hasPrefix(want) }?.videoID
    }

    /// 链接里的 videoId(`kaset://play?v=…`、`music.youtube.com/watch?v=…` 都认)。
    public static func videoID(fromLink url: URL?) -> String? {
        guard let url, let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
              !v.isEmpty else { return nil }
        return v
    }

    /// 在它里面放这一首:有 videoId 用它,没有就按歌名歌手搜(`songVideoID(inSearch:title:)`)。插在当前这首后面;`now` 为真时
    /// 再按一次下一首(下一首放的就是队列里的下一格,实测),否则就是「稍后播放」。会阻塞,别在主线程调。
    public func playOrQueue(videoID: String?, title: String, artist: String, now: Bool) -> Bool {
        guard let config = usableConfig() else { return false }
        var id = videoID
        if id == nil {
            let query = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
            id = postData("/api/v1/search", body: ["query": query], config: config).flatMap { Self.songVideoID(inSearch: $0, title: title) }
        }
        guard let id else {
            logger.notice("queue: no song for \(title, privacy: .public)")
            return false
        }
        guard post("/api/v1/queue", body: ["videoId": id, "insertPosition": "INSERT_AFTER_CURRENT_VIDEO"], config: config) == 204 else { return false }
        return !now || post("/api/v1/next", body: [:], config: config) == 204
    }

    /// 开播(`POST /api/v1/play`)。
    public func play() -> Bool {
        guard let config = usableConfig() else { return false }
        return post("/api/v1/play", body: [:], config: config) == 204
    }

    /// 接口开着、不是 HTTPS、该有的令牌有了,才去请求。
    private func usableConfig() -> Config? {
        guard let config = currentConfig(), config.enabled, !config.usesHTTPS else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return config.needsToken && token == nil ? nil : config
    }

    // MARK: - 请求

    private func baseURL(_ config: Config) -> URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = config.connectHost
        c.port = config.port
        return c.url
    }

    /// 同步 GET,最多等 `requestTimeout`;200 才交回正文,401 当令牌失效清掉,204 / 连不上 / 超时都是 nil。
    private func get(_ path: String, config: Config) -> Data? {
        guard let url = baseURL(config)?.appendingPathComponent(path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        lock.lock()
        let token = self.token
        lock.unlock()
        if config.needsToken, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let done = DispatchSemaphore(value: 0)
        var result: (data: Data?, status: Int?, failed: Bool) = (nil, nil, true)
        session.dataTask(with: request) { data, response, error in
            result = (data, (response as? HTTPURLResponse)?.statusCode, error != nil)
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + Self.requestTimeout + 0.1) == .success else { return nil }
        lock.lock()
        reachable = !result.failed
        if result.status == 401 { self.token = nil }
        lock.unlock()
        return result.status == 200 ? result.data : nil
    }

    /// 同步 POST 一段 JSON,最多等 `requestTimeout`;返回状态码,连不上 / 超时为 nil。
    private func post(_ path: String, body: [String: Any], config: Config) -> Int? {
        postRaw(path, body: body, config: config, timeout: Self.requestTimeout)?.status
    }

    /// 同 `post`,200 时交回正文(搜索要等它向 YouTube Music 问一趟,最多等 `searchTimeout`)。
    private func postData(_ path: String, body: [String: Any], config: Config) -> Data? {
        guard let reply = postRaw(path, body: body, config: config, timeout: Self.searchTimeout), reply.status == 200 else { return nil }
        return reply.data
    }

    private func postRaw(_ path: String, body: [String: Any], config: Config,
                         timeout: TimeInterval) -> (status: Int?, data: Data?)? {
        guard let url = baseURL(config)?.appendingPathComponent(path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        lock.lock()
        let token = self.token
        lock.unlock()
        if config.needsToken, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let done = DispatchSemaphore(value: 0)
        var status: Int?
        var reply: Data?
        session.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            reply = data
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 0.1) == .success else { return nil }
        if status == 401 {
            lock.lock()
            self.token = nil
            lock.unlock()
        }
        return (status, reply)
    }

    /// 要令牌(在后台等,第一次要时 Pear 弹框问用户)。在要、用户拒绝过、刚失败过时不再要。
    private func authorizeIfNeeded(_ config: Config) {
        guard !UserDefaults.standard.bool(forKey: Self.deniedDefaultsKey),
              let url = baseURL(config)?.appendingPathComponent("/auth/\(Self.clientID)") else { return }
        lock.lock()
        if authorizing || token != nil
            || lastAuthorizationFailure.map({ Date().timeIntervalSince($0) < Self.authorizationRetrySecs }) == true {
            lock.unlock()
            return
        }
        authorizing = true
        lock.unlock()
        var request = URLRequest(url: url, timeoutInterval: Self.authorizationTimeout)
        request.httpMethod = "POST"
        logger.notice("pear api: requesting a token (Pear Desktop may ask the user)")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode
            let token = status == 200
                ? (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["accessToken"] as? String) : nil
            self.lock.lock()
            self.authorizing = false
            self.reachable = error == nil
            if let token, !token.isEmpty {
                self.token = token
            } else {
                self.lastAuthorizationFailure = Date()
            }
            self.lock.unlock()
            if status == 403 {
                UserDefaults.standard.set(true, forKey: Self.deniedDefaultsKey)
                self.logger.notice("pear api: the user denied access in Pear Desktop")
            } else if token == nil {
                self.logger.notice("pear api: no token (status \(status ?? -1, privacy: .public))")
            }
        }.resume()
    }
}
