import AppKit
import Foundation
import os

/// 洛雪音乐的开放 API:用户在洛雪「设置 › 开放 API」里勾「启用开放 API 服务」才有(默认关着),本机 HTTP,默认端口 23330。
/// 开着时订阅它的状态推送(`/subscribe-player-status`,SSE:连上先把各项推一遍,之后哪项变了推哪项),拿到洛雪自己的播放进度、
/// 速度、收藏、音量、封面地址、当前这句歌词;音量和收藏经 `/volume`、`/collect`、`/uncollect` 写回去。没开时什么都不做,
/// 各处照旧走系统会话和本地库那一套。
///
/// 开没开、端口、允不允许局域网访问都读洛雪的 `config_v2.json`(按修改时间缓存),不去试端口。只连 127.0.0.1,不随局域网设置走。
/// 进度推送的是网页音频元素的 `currentTime`,跟 Kaset 那条网页时钟一样原样当真值、不另补提前量。见 02 章决策 131。
///
/// 同一份数据有别的来源时它是其中一级(见 02 章决策 134):系统会话不报洛雪时用它推的合成洛雪的读数(`nowPlayingSnapshot`)、
/// 播放控制直接发给洛雪(`directControl`,不行再走 `lxmusic://player/…`)、系统封面取不到时下它推的封面(`artworkData`);
/// 音量没开它时退到配置文件里那份(`configVolumePercent`,只读)。洛雪开着就保持订阅(`noteAppRunning`),不只在系统报洛雪时。
public final class LXMusicOpenAPI: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public let enabled: Bool
        public let port: Int
        public let bindLan: Bool
        /// 洛雪设置里选的输出设备(`player.mediaDeviceId`,网页那套设备 id,`default` 是跟系统走);没这一项为 nil。
        public let mediaDeviceID: String?
        /// 设置里的音量(`player.volume`,0~1)和静音(`player.isMute`)。
        public let volume: Double?
        public let isMute: Bool?
        public init(enabled: Bool, port: Int, bindLan: Bool, mediaDeviceID: String? = nil, volume: Double? = nil, isMute: Bool? = nil) {
            self.enabled = enabled
            self.port = port
            self.bindLan = bindLan
            self.mediaDeviceID = mediaDeviceID
            self.volume = volume
            self.isMute = isMute
        }
    }

    /// 推送攒出来的洛雪此刻的状态。`progressAt` 是那份进度到达的时刻;`advancing` 是最近一份进度比上一份走了(音频在出声),
    /// 恢复播放时输出设备还没转起来那一截进度停着,这时不外推。
    public struct State: Equatable, Sendable {
        public var status: String?
        public var name: String?
        public var singer: String?
        public var picURL: String?
        public var progress: Double?
        public var progressAt: Date?
        public var advancing = false
        public var albumName: String?
        public var duration: Double?
        public var playbackRate: Double?
        public var collect: Bool?
        public var volume: Double?
        public var lyricLine: String?
        public var lyricLineAt: Date?
        public init() {}
    }

    /// 哪一类状态变了:播放类(在放 / 暂停 / 出错、换歌、速度)要马上轮询一次;别的(收藏、音量)让控件回读。
    public enum Change: Sendable { case playback, controls }

    /// 收藏、音量变了(在洛雪里点的也算)时发,控件据此回读。
    public static let controlsChangedNotification = Notification.Name("LXMusicOpenAPIControlsChanged")

    public static let defaultPort = 23330
    /// 进度最多外推这么久:洛雪在放时每 0.25 秒左右推一次,再久没来多半是卡住了,别一路往前走。
    public static let maxExtrapolationSecs: TimeInterval = 1
    /// 一份进度跟上一份外推到它到达那一刻的位置差过这么多,就马上补查一次(`progressJumped`)。同网页探针的精确重锚门槛。
    public static let resyncSecs: TimeInterval = 0.1
    /// 订阅断了、或者连不上时,隔这么久再试。
    public static let retrySecs: TimeInterval = 3
    /// 推送流里一行最多攒这么多字节,还没等到换行就当流坏了、丢掉重来(订阅的字段都很短,见 `subscribedFields`)。
    public static let maxLineBytes = 1 << 20
    /// 订阅时要的字段。
    public static let subscribedFields = "status,name,singer,albumName,duration,picUrl,progress,playbackRate,collect,volume,lyricLineText"

    // MARK: - 纯函数

    /// 配置文件内容里开放 API 那几项;解不开时 nil。端口洛雪存成数字,也认字符串。
    public static func config(in data: Data?) -> Config? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let setting = object["setting"] as? [String: Any] else { return nil }
        let rawPort = setting["openAPI.port"]
        let port = (rawPort as? NSNumber)?.intValue ?? (rawPort as? String).flatMap { Int($0) } ?? defaultPort
        return Config(enabled: setting["openAPI.enable"] as? Bool ?? false,
                      port: (1...65535).contains(port) ? port : defaultPort,
                      bindLan: setting["openAPI.bindLan"] as? Bool ?? false,
                      mediaDeviceID: setting["player.mediaDeviceId"] as? String,
                      volume: (setting["player.volume"] as? NSNumber)?.doubleValue,
                      isMute: setting["player.isMute"] as? Bool)
    }

    /// 洛雪的声音走不走系统默认输出设备:设置里没选、选的是 `default` 都算走。冷恢复等「默认输出设备转起来」只对走默认设备的
    /// 有意义(见 `LocalPlaybackSource.lxMusicColdStartPosition`);选了别的设备时那台默认设备可能一直闲着。见 02 章决策 134。
    public static func outputsToDefaultDevice(_ config: Config?) -> Bool {
        let id = config?.mediaDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty || id == "default"
    }

    /// 配置文件里的音量换成 0~100,静音算 0;没这一项为 nil。开放 API 没开时音量胶囊照它灰着显示。
    public static func configVolumePercent(_ config: Config?) -> Int? {
        guard let v = config?.volume, v.isFinite else { return nil }
        if config?.isMute == true { return 0 }
        return Int((min(1, max(0, v)) * 100).rounded())
    }

    /// 一条推送(事件名 + JSON 编码的值)并进状态。认不出的事件、解不开的值原样不动。
    public static func applying(event: String, data: String, to state: State, at: Date) -> State {
        var s = state
        let value = try? JSONSerialization.jsonObject(with: Data(data.utf8), options: [.fragmentsAllowed])
        let number = (value as? NSNumber)?.doubleValue
        switch event {
        case "status": s.status = value as? String
        case "name":
            let name = value as? String
            if name != s.name {
                s.progress = nil
                s.progressAt = nil
                s.advancing = false
            }
            s.name = name
        case "singer": s.singer = value as? String
        case "albumName": s.albumName = value as? String
        case "duration": s.duration = number
        case "picUrl": s.picURL = value as? String
        case "progress":
            guard let v = number else { break }
            s.advancing = s.progress.map { abs(v - $0) > 0.001 } ?? false
            s.progress = v
            s.progressAt = at
        case "playbackRate": s.playbackRate = number
        case "collect": s.collect = value as? Bool
        case "volume": s.volume = number
        case "lyricLineText":
            s.lyricLine = value as? String
            s.lyricLineAt = at
        default: break
        }
        return s
    }

    /// 这一刻的播放位置:在放、进度在走时按最近一份外推(最多 `maxExtrapolationSecs`),否则就是最近那份。没有进度时 nil。
    public static func position(_ s: State, now: Date) -> Double? {
        guard let v = s.progress, let at = s.progressAt else { return nil }
        guard s.status == "playing", s.advancing else { return v }
        let rate = (s.playbackRate ?? 1) > 0 ? (s.playbackRate ?? 1) : 1
        return v + rate * min(max(0, now.timeIntervalSince(at)), maxExtrapolationSecs)
    }

    /// 这份进度跟上一份外推到它到达那一刻的位置差过 `resyncSecs`:恢复时进度先走一点、又停下等输出设备转起来,
    /// 或在洛雪里拖了进度条。`advancing` 没变就不会补查,只能等常规校准(约 2 秒),所以单独判。换了歌、没有进度时假。
    /// 见 02 章决策 133。
    public static func progressJumped(from before: State, to after: State) -> Bool {
        guard before.name == after.name, let v = after.progress, let at = after.progressAt,
              let expected = position(before, now: at) else { return false }
        return abs(v - expected) > resyncSecs
    }

    /// 推来的状态合成一份洛雪的读数,系统会话这一拍不报洛雪时顶上(`MediaControlClient`)。`isMusicApp` 要填 true:
    /// `LocalPlaybackSource.poll` 只收这个标记为 true 的读数(同 Kaset 那份)。在放、进度在走时位置标精确;
    /// 报在放而进度还没走按等着出声;暂停就是暂停。出错、停止、没有歌名或进度时 nil。纯函数,selftest 覆盖。
    public static func nowPlayingSnapshot(_ s: State, now: Date) -> MediaControlSnapshot? {
        guard s.status == "playing" || s.status == "paused",
              let name = s.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let position = position(s, now: now) else { return nil }
        let rate = (s.playbackRate ?? 0) > 0 ? (s.playbackRate ?? 1) : 1
        let album = s.albumName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaControlSnapshot(
            title: name, artist: s.singer, album: album?.isEmpty == false ? album : nil,
            duration: (s.duration ?? 0) > 0 ? s.duration : nil, elapsedTime: position, playing: nil, playbackRate: nil,
            isMusicApp: true, bundleIdentifier: PlaybackPlayer.lxMusic.bundleIdentifier,
            anchorElapsedTime: nil, isRadio: nil, capturedAt: now)
            .withLXMusicClock(position: position, playing: s.status == "playing", rate: rate, waiting: !s.advancing)
    }

    /// 一条播放控制直接发给洛雪本体的办法。
    public enum DirectControl: Equatable, Sendable {
        /// 开放 API 的控制接口(`/play`、`/seek?offset=…` 之类)。
        case api(path: String, query: String?)
        /// 洛雪自己的链接(`lxmusic://player/…`),后台打开。
        case link(URL)
    }

    /// 能直接发给洛雪的播放控制(media-control 的指令名)。
    public static let directControlCommands: Set<String> = ["toggle-play-pause", "play", "pause", "next-track", "previous-track", "seek"]

    /// 一条播放控制(media-control 的指令名)怎么直接发给洛雪,按先后排:开放 API 连着时先走它,再退到 `lxmusic://player/…`。
    /// 开放 API 没有「切换」,按推来的在不在放选播放或暂停(说不上来时只走链接);跳转只有开放 API 有。纯函数,selftest 覆盖。
    public static func directControl(_ command: String, arguments: [String], apiConnected: Bool, playing: Bool?) -> [DirectControl] {
        func link(_ action: String) -> DirectControl? { URL(string: "lxmusic://player/" + action).map(DirectControl.link) }
        var api: DirectControl?
        var fallback: DirectControl?
        switch command {
        case "toggle-play-pause":
            api = playing.map { .api(path: $0 ? "/pause" : "/play", query: nil) }
            fallback = link("togglePlay")
        case "play": api = .api(path: "/play", query: nil); fallback = link("play")
        case "pause": api = .api(path: "/pause", query: nil); fallback = link("pause")
        case "next-track": api = .api(path: "/skip-next", query: nil); fallback = link("skipNext")
        case "previous-track": api = .api(path: "/skip-prev", query: nil); fallback = link("skipPrev")
        case "seek":
            if let value = arguments.first, let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                api = .api(path: "/seek", query: "offset=" + value)
            }
        default: return []
        }
        return [apiConnected ? api : nil, fallback].compactMap { $0 }
    }

    /// 推送里的这一首是不是系统会话报的那一首(歌名相同;两边都有歌手时歌手也要相同)。
    public static func describes(_ s: State, title: String?, artist: String?) -> Bool {
        func norm(_ v: String?) -> String { (v ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !norm(s.name).isEmpty, norm(s.name) == norm(title) else { return false }
        return norm(s.singer).isEmpty || norm(artist).isEmpty || norm(s.singer) == norm(artist)
    }

    /// 推送里的音量(0~100 的整数:洛雪把设置里 0~1 的音量乘 100 取整推过来)。
    public static func volumePercent(_ s: State) -> Int? {
        guard let v = s.volume, v >= 0 else { return nil }
        return min(100, Int(v.rounded()))
    }

    /// 推来的这一首自己的封面(`picUrl` 换成 https,见 `httpsCover`)。占位专辑名(`PlaceholderAlbum`)下给的是歌手照片,不当封面。
    /// 纯函数,selftest 覆盖。
    public static func ownCoverURL(_ s: State) -> URL? {
        guard !PlaceholderAlbum.contains(s.albumName), let raw = s.picURL else { return nil }
        return httpsCover(raw)
    }

    /// 推来的封面地址换成 Discord 认的 https:跟引擎的 `lxMusicHTTPSCover`(lyrimuse-engine/lxmusic.go)同一张图床表,两处同步改
    /// (见 09 章决策 263)。咪咕记的多是不带主机的「/data/oss/…」,补成 d.musicapp.migu.cn。`data:` 地址、没核过的图床不给。
    public static func httpsCover(_ raw: String) -> URL? {
        var raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/data/oss/") { raw = "https://d.musicapp.migu.cn" + raw }
        guard var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        if host == "img1.kwcdn.kuwo.cn" {
            parts.host = "img1.kuwo.cn"
        } else if !(host.range(of: #"^img\d\.kuwo\.cn$"#, options: .regularExpression) != nil || host == "imge.kugou.com"
                    || host == "y.gtimg.cn" || host == "d.musicapp.migu.cn" || host.hasSuffix(".music.126.net")) {
            return nil
        }
        parts.scheme = "https"
        parts.port = nil
        return parts.url
    }

    // MARK: - 线上

    public static let shared = LXMusicOpenAPI(configURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/lx-music-desktop/LxDatas/config_v2.json"))

    private let configURL: URL
    private let lock = NSLock()
    private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "lx-openapi")
    private var readModified: Date?
    private var cachedConfig: Config?
    private var state = State()
    private var connected = false
    private var connectedPort: Int?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var buffer = Data()
    private var pendingEvent: String?
    private var lastAttempt: Date?
    private var onChange: (@Sendable (Change) -> Void)?
    private var lyricCheck = LXMusicLyricCheck()
    /// 洛雪开着、设置又认它(自动识别或勾了它):不管系统此刻报不报洛雪,都保持订阅(见 `noteAppRunning`)。
    private var appRunning = false
    /// 最近下载的那张封面,同一个地址不重下。
    private var artworkCache: (url: URL, data: Data)?

    public init(configURL: URL) {
        self.configURL = configURL
        super.init()
    }

    /// 状态变了时叫谁(只留一个)。回调在后台队列上。
    public func setChangeHandler(_ handler: (@Sendable (Change) -> Void)?) {
        lock.lock()
        onChange = handler
        lock.unlock()
    }

    /// 洛雪配置里开放 API 那几项(文件修改时间没变不重读);没有配置文件时 nil。
    public func currentConfig() -> Config? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if modified != readModified {
            readModified = modified
            cachedConfig = Self.config(in: FileIO.read(configURL))
        }
        return cachedConfig
    }

    /// 洛雪开着、设置又认它时为真,`MediaControlClient` 每拍报一次:这时订阅一直连着,系统会话不报洛雪时才有它推的可用。
    public func noteAppRunning(_ running: Bool) {
        lock.lock()
        appRunning = running
        lock.unlock()
        if running { keepAlive(active: true) }
    }

    /// 在放洛雪时每拍调(`active` 为真):开着就保持订阅,关了、端口变了就断开重来。已经连着的不因为一拍没在放洛雪、
    /// 没认出它开着就断开:`appRunning` 来自 `NSRunningApplication`,后台线程上偶尔返回空(16 章 §3 表),断了要隔
    /// `retrySecs` 才重连;洛雪退出时它那头会断开连接(`didCompleteWithError`)。
    public func keepAlive(active: Bool) {
        lock.lock()
        let wanted = active || appRunning || task != nil
        lock.unlock()
        let config = wanted ? currentConfig() : nil
        let want = config?.enabled == true ? config?.port : nil
        lock.lock()
        if task != nil, want != connectedPort {
            task?.cancel()
            resetLocked()
        }
        guard let port = want, task == nil else {
            lock.unlock()
            return
        }
        if let last = lastAttempt, Date().timeIntervalSince(last) < Self.retrySecs {
            lock.unlock()
            return
        }
        lastAttempt = Date()
        guard let url = URL(string: "http://127.0.0.1:\(port)/subscribe-player-status?filter=\(Self.subscribedFields)") else {
            lock.unlock()
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 24 * 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: url)
        self.session = session
        self.task = task
        connectedPort = port
        lock.unlock()
        task.resume()
    }

    /// 订阅连着、收到过推送时的状态;没连上时 nil。
    public func currentState() -> State? {
        lock.lock()
        defer { lock.unlock() }
        return connected ? state : nil
    }

    /// 设洛雪的音量(0~100)。会阻塞到请求结束(最多 1 秒),不要在主线程调。
    @discardableResult
    public func setVolume(_ value: Int) -> Bool {
        send(path: "/volume", query: "volume=\(min(100, max(0, value)))")
    }

    /// 收藏 / 取消收藏洛雪正在放的这首。会阻塞到请求结束(最多 1 秒),不要在主线程调。
    @discardableResult
    public func setCollected(_ on: Bool) -> Bool {
        send(path: on ? "/collect" : "/uncollect", query: nil)
    }

    /// 一条播放控制按 `directControl` 排的先后发给洛雪,前一种不成就试下一种。会阻塞(开放 API 那一种最多 1 秒),不要在主线程调。
    /// 返回发出去没有;一种都没有(没开开放 API 时的跳转)为假。
    @discardableResult
    public func sendDirect(_ command: String, arguments: [String]) -> Bool {
        let state = currentState()
        let playing = state.flatMap { $0.status == nil ? nil : $0.status == "playing" }
        for control in Self.directControl(command, arguments: arguments, apiConnected: state != nil, playing: playing) {
            switch control {
            case .api(let path, let query):
                if send(path: path, query: query) { return true }
                logger.notice("lx open api: \(path, privacy: .public) failed, falling back")
            case .link(let url):
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.open(url, configuration: configuration)
                return true
            }
        }
        return false
    }

    /// 推来的封面(`ownCoverURL`)下载下来,推来的是这一首(`describes`)才下;同一个地址不重下。下不到、不是图为 nil。
    /// 会阻塞到下载结束(最多 3 秒),不要在主线程调。
    public func artworkData(title: String?, artist: String?) -> Data? {
        guard let state = currentState(), Self.describes(state, title: title, artist: artist),
              let url = Self.ownCoverURL(state) else { return nil }
        return artworkData(url: url)
    }

    /// 下载洛雪的一张封面(开放 API 推的,或引擎从它本机列表记下的 `player_covers`);同一个地址不重下。
    /// 下不到、不是图为 nil。会阻塞到下载结束(最多 3 秒),不要在主线程调。
    public func artworkData(url: URL) -> Data? {
        lock.lock()
        let cached = artworkCache
        lock.unlock()
        if let cached, cached.url == url { return cached.data }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let started = Date()
        let done = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<(data: Data?, status: Int?, error: Error?)>(initialState: (nil, nil, nil))
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.withLock { $0 = (data, (response as? HTTPURLResponse)?.statusCode, error) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3.5)
        let got = box.withLock { $0 }
        NetworkAuditLog.record(service: "image", operation: "lxmusic.artwork", host: url.host ?? "",
                               statusCode: got.status, durationMs: Date().timeIntervalSince(started) * 1000, error: got.error)
        guard got.status == 200, let data = got.data, CoverArtReplacementGate.isImage(data) else { return nil }
        lock.lock()
        artworkCache = (url, data)
        lock.unlock()
        return data
    }

    private func send(path: String, query: String?) -> Bool {
        lock.lock()
        let port = connected ? connectedPort : nil
        lock.unlock()
        guard let port, let url = URL(string: "http://127.0.0.1:\(port)\(path)" + (query.map { "?" + $0 } ?? "")) else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let done = DispatchSemaphore(value: 0)
        let ok = OSAllocatedUnfairLock(initialState: false)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok.withLock { $0 = (response as? HTTPURLResponse)?.statusCode == 200 }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 1.5)
        return ok.withLock { $0 }
    }

    /// 我们屏上换到了这一句(对时自检用,见 `LXMusicLyricCheck`)。只在订阅连着时记。
    public func noteDisplayedLine(_ text: String, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard connected, lyricCheck.noteOurs(text, at: date) else { return }
        logLyricCheckLocked(final: false)
    }

    /// 每攒满一批、换歌时记一行:我们屏上换句比洛雪自己换句晚多少(正 = 我们晚)。
    private func logLyricCheckLocked(final: Bool) {
        guard let summary = lyricCheck.summary(), final || lyricCheck.deltas.count % LXMusicLyricCheck.logEvery == 0 else { return }
        logger.notice("lx lyric check: \(self.lyricCheck.track ?? "-", privacy: .public) ours vs LX line starts median \(summary.median, format: .fixed(precision: 2))s (n=\(summary.count), \(summary.min, format: .fixed(precision: 2))…\(summary.max, format: .fixed(precision: 2)))\(final ? " final" : "", privacy: .public)")
    }

    private func resetLocked() {
        task = nil
        session?.invalidateAndCancel()
        session = nil
        connected = false
        connectedPort = nil
        state = State()
        lyricCheck = LXMusicLyricCheck()
        buffer = Data()
        pendingEvent = nil
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
        lock.lock()
        if dataTask == task, ok {
            connected = true
            logger.notice("lx open api: subscribed on port \(self.connectedPort ?? 0)")
        }
        lock.unlock()
        completionHandler(ok ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var changes: Set<Change> = []
        lock.lock()
        guard dataTask == task else {
            lock.unlock()
            return
        }
        buffer.append(data)
        let now = Date()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .init(charactersIn: "\r")) else {
                continue
            }
            if line.hasPrefix("event: ") {
                pendingEvent = String(line.dropFirst(7))
            } else if line.hasPrefix("data: "), let event = pendingEvent {
                let before = state
                state = Self.applying(event: event, data: String(line.dropFirst(6)), to: state, at: now)
                if state.name != before.name {
                    logLyricCheckLocked(final: true)
                    lyricCheck = LXMusicLyricCheck(track: state.name)
                }
                if event == "lyricLineText", let text = state.lyricLine, lyricCheck.noteTheirs(text, at: now) {
                    logLyricCheckLocked(final: false)
                }
                if state.status != before.status || state.name != before.name || state.playbackRate != before.playbackRate
                    || state.advancing != before.advancing
                    || (event == "progress" && Self.progressJumped(from: before, to: state)) {
                    changes.insert(.playback)
                }
                if state.collect != before.collect || state.volume != before.volume { changes.insert(.controls) }
            }
        }
        if buffer.count > Self.maxLineBytes {
            logger.notice("lx open api: \(self.buffer.count) bytes without a line break, dropping them")
            buffer = Data()
            pendingEvent = nil
        }
        let handler = onChange
        lock.unlock()
        for change in changes { handler?(change) }
    }

    /// 连上过的订阅断了才算一次播放状态变化(推来的状态整个作废);洛雪没开、端口连不上时每 `retrySecs` 失败一次,
    /// 什么都没变过,不发。
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let mine = task == self.task
        let wasConnected = mine && connected
        if mine {
            if wasConnected {
                logger.notice("lx open api: subscription ended (\(error?.localizedDescription ?? "closed", privacy: .public))")
            }
            resetLocked()
        }
        let handler = onChange
        lock.unlock()
        if wasConnected { handler?(.playback) }
    }
}

/// 歌词对时自检:洛雪推来的「当前这句」每换一句、我们屏上每换一句各记一次时刻,文字归一后相同的一对算差值(我们 − 洛雪,
/// 正 = 我们晚)。两边歌词来源不同、字对不上的句子不算;差过 `maxPairSecs` 的不算(多半是副歌重复那句配错了对)。只进日志,
/// 排查「歌词不准」时有现成的证据。纯数据,selftest 直接覆盖。
public struct LXMusicLyricCheck: Sendable {
    public static let maxPairSecs: TimeInterval = 10
    /// 每攒这么多对记一行。
    public static let logEvery = 8

    public private(set) var track: String?
    public private(set) var deltas: [Double] = []
    private var theirs: [String: Date] = [:]
    private var ours: [String: Date] = [:]

    public init(track: String? = nil) { self.track = track }

    /// 洛雪换到了这一句;配上一对时返回 true。
    @discardableResult
    public mutating func noteTheirs(_ text: String, at date: Date) -> Bool {
        var mine = theirs, other = ours
        defer { theirs = mine; ours = other }
        guard let delta = Self.pair(text, at: date, mine: &mine, other: &other) else { return false }
        deltas.append(-delta)
        return true
    }

    /// 我们屏上换到了这一句;配上一对时返回 true。
    @discardableResult
    public mutating func noteOurs(_ text: String, at date: Date) -> Bool {
        var mine = ours, other = theirs
        defer { ours = mine; theirs = other }
        guard let delta = Self.pair(text, at: date, mine: &mine, other: &other) else { return false }
        deltas.append(delta)
        return true
    }

    /// 对面记着这一句、离得够近就配成一对,返回「这一边 − 对面」;否则记下这一边。
    private static func pair(_ text: String, at date: Date, mine: inout [String: Date], other: inout [String: Date]) -> Double? {
        let key = normalized(text)
        guard !key.isEmpty else { return nil }
        if let then = other[key], abs(date.timeIntervalSince(then)) <= maxPairSecs {
            other[key] = nil
            return date.timeIntervalSince(then)
        }
        mine[key] = date
        return nil
    }

    /// 中位数、对数、最小、最大;一对都没有时 nil。
    public func summary() -> (median: Double, count: Int, min: Double, max: Double)? {
        guard !deltas.isEmpty else { return nil }
        let sorted = deltas.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        return (median, sorted.count, sorted[0], sorted[sorted.count - 1])
    }

    /// 比字之前去掉空白和标点、统一大小写:两边来源不同,标点、空格常不一样。
    public static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }.map(Character.init))
    }
}
