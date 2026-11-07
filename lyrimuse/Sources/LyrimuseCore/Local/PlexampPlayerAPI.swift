import AppKit
import Foundation

/// Plexamp 在本机 32500 端口开着的 Plex 播放器接口(不要令牌):读它的时间线(状态、曲目、循环、随机、音量),
/// 发播放 / 暂停、上下首、循环档、音量。随机读得到、写不进(它报的可控项里没有 shuffle)。
/// 时间线里的进度约每秒才更新一次,不拿来当位置。见 02 章决策 242。
public final class PlexampPlayerAPI: @unchecked Sendable {
    public static let shared = PlexampPlayerAPI()

    public static let port = 32500
    /// 本机回环,应答在几毫秒内;连不上(Plexamp 没开)时也很快失败。
    public static let requestTimeout: TimeInterval = 0.5
    static let clientIdentifier = "lyrimuse"

    /// 时间线里音乐那一条。
    public struct Timeline: Equatable, Sendable {
        public var state: String
        public var ratingKey: String?
        public var volume: Int?
        public var shuffle: Bool?
        public var repeatMode: Int?

        public init(state: String, ratingKey: String?, volume: Int?, shuffle: Bool?, repeatMode: Int?) {
            self.state = state
            self.ratingKey = ratingKey
            self.volume = volume
            self.shuffle = shuffle
            self.repeatMode = repeatMode
        }
    }

    private let lock = NSLock()
    private var commandID = 0
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = PlexampPlayerAPI.requestTimeout
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    private init() {}

    /// 从 `/player/timeline/poll` 的应答里取 `type="music"` 那一条。认不出为 nil。纯函数,selftest 覆盖。
    public static func parseTimeline(_ xml: String) -> Timeline? {
        guard let element = xml.components(separatedBy: "<Timeline ").dropFirst()
            .first(where: { $0.contains("type=\"music\"") }) else { return nil }
        let head = element.components(separatedBy: ">").first ?? element
        func attribute(_ name: String) -> String? {
            guard let range = head.range(of: " \(name)=\"") ?? (head.hasPrefix("\(name)=\"") ? head.range(of: "\(name)=\"") : nil)
            else { return nil }
            let rest = head[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        guard let state = attribute("state") else { return nil }
        return Timeline(state: state, ratingKey: attribute("ratingKey"), volume: attribute("volume").flatMap { Int($0) },
                        shuffle: attribute("shuffle").map { $0 == "1" }, repeatMode: attribute("repeat").flatMap { Int($0) })
    }

    /// 循环档:Plex 的约定 0 关、1 单曲、2 列表。随机不进档位(写不进,开着也只影响下一首是谁)。纯函数,selftest 覆盖。
    public static func playbackMode(repeatMode: Int?) -> MusicPlaybackController.MusicPlaybackMode? {
        switch repeatMode {
        case 0?: return .list
        case 1?: return .repeatOne
        case 2?: return .repeatAll
        default: return nil
        }
    }

    /// 切到某一档要写的 `repeat` 值;随机写不进,为 nil。纯函数,selftest 覆盖。
    public static func repeatValue(for mode: MusicPlaybackController.MusicPlaybackMode) -> Int? {
        switch mode {
        case .list: return 0
        case .repeatOne: return 1
        case .repeatAll: return 2
        case .shuffle: return nil
        }
    }

    public static let modeOptions: MusicPlaybackController.PlaybackModeOptions = [.repeatAll, .repeatOne]

    nonisolated(unsafe) private static var electronByPID: [Int: Bool] = [:]
    private static let electronLock = NSLock()

    /// 这个进程是不是 Electron 那一代(4.13 及以前):包里带 `Electron Framework`。4.50 起是 Tauri,两代的系统会话锚点不一样
    /// (见 LocalPlaybackSource.plexampFreshStartLead)。按进程号记一次。
    public static func isElectronBuild(pid: Int?) -> Bool {
        guard let pid, pid > 0 else { return false }
        electronLock.lock()
        defer { electronLock.unlock() }
        if let known = electronByPID[pid] { return known }
        let bundle = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleURL
        let electron = bundle.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        electronByPID[pid] = electron
        return electron
    }

    /// 失焦时发的那一条的路径。播放 / 暂停按它此刻的状态选 play 或 pause;状态读不到时发 play。纯函数,selftest 覆盖。
    public static func commandPath(_ command: PlaybackMenuControl.Command, state: String?) -> String {
        switch command {
        case .playPause: return state == "playing" ? "/player/playback/pause" : "/player/playback/play"
        case .nextTrack: return "/player/playback/skipNext"
        case .previousTrack: return "/player/playback/skipPrevious"
        }
    }

    /// 读时间线。Plexamp 没开、连不上、认不出为 nil。最多等 `requestTimeout`,别在主线程调。
    public func timeline() -> Timeline? {
        guard let data = request("/player/timeline/poll", query: [("wait", "0")]),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        return Self.parseTimeline(xml)
    }

    public func playbackMode() -> MusicPlaybackController.PlaybackModeState? {
        Self.playbackMode(repeatMode: timeline()?.repeatMode).map { .init(mode: $0, options: Self.modeOptions) }
    }

    public func setPlaybackMode(_ mode: MusicPlaybackController.MusicPlaybackMode) -> Bool {
        guard let value = Self.repeatValue(for: mode) else { return false }
        return request("/player/playback/setParameters", query: [("repeat", String(value)), ("type", "music")]) != nil
    }

    public func volume() -> Int? { timeline()?.volume }

    public func setVolume(_ value: Int) -> Bool {
        let clamped = min(100, max(0, value))
        return request("/player/playback/setParameters", query: [("volume", String(clamped)), ("type", "music")]) != nil
    }

    /// 失焦时的播放 / 暂停、上下首。连不上为 false。
    @discardableResult
    public func send(_ command: PlaybackMenuControl.Command) -> Bool {
        let state = command == .playPause ? timeline()?.state : nil
        return request(Self.commandPath(command, state: state), query: [("type", "music")]) != nil
    }

    /// 同步 GET,最多等 `requestTimeout`;200 才交回正文。每次带递增的 `commandID` 和客户端标识(Plex 播放器接口按它们认请求方)。
    private func request(_ path: String, query: [(String, String)]) -> Data? {
        lock.lock()
        commandID += 1
        let id = commandID
        lock.unlock()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Self.port
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } + [URLQueryItem(name: "commandID", value: String(id))]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("Lyrimuse", forHTTPHeaderField: "X-Plex-Device-Name")
        let done = DispatchSemaphore(value: 0)
        var result: (data: Data?, status: Int?) = (nil, nil)
        session.dataTask(with: request) { data, response, _ in
            result = (data, (response as? HTTPURLResponse)?.statusCode)
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + Self.requestTimeout + 0.1) == .success else { return nil }
        return result.status == 200 ? result.data : nil
    }
}

/// Plexamp 4.50 起(Tauri)系统那份会话的位置补全:每发一份带位置的锚点,约 0.5 秒后紧跟一份把位置清空的(时刻是那一刻、
/// 歌名不变),之后再读会话也一直没有位置;新起一首那一份本来就没有位置。不补的话每读到一份没位置的就当位置 0、按跳转处理,
/// 屏上位置隔一两秒归零一次。见 02 章决策 242。
public enum PlexampSessionAnchor {
    public struct Anchor: Equatable, Sendable {
        public var identity: String
        public var elapsed: Double
        /// media-control 那份时刻原文(`MediaControlMicros.timestampString` 的写法)。
        public var timestamp: String
        public var rate: Double
        /// 跟着这份锚点来的那份清空位置的会话的时刻;之后读到同一个时刻的都是它。
        public var echoTimestamp: String?

        public init(identity: String, elapsed: Double, timestamp: String, rate: Double, echoTimestamp: String? = nil) {
            self.identity = identity
            self.elapsed = elapsed
            self.timestamp = timestamp
            self.rate = rate
            self.echoTimestamp = echoTimestamp
        }
    }

    /// 清空位置的那份比锚点晚到多久之内算它的回声(实测 0.45~0.56 秒)。
    public static let echoWindowSecs: Double = 1.5
    /// 自然连播时新歌的锚点先带着上一首的歌名到、约 0.5 秒后歌名才换(换的那份不带位置),这份锚点比声音早这么多。
    public static let naturalStartLeadSecs: Double = 0.5
    /// 自然连播那份锚点的位置是新歌刚开头(实测 1.6 秒);换歌前先报旧歌停下位置的(点播另一首)大得多,不接。
    public static let naturalStartMaxElapsedSecs: Double = 4

    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: Anchor?

    static func seconds(_ timestamp: String) -> Double? {
        MediaControlMicros.date(fromTimestampString: timestamp)?.timeIntervalSince1970
            ?? ISO8601DateFormatter().date(from: timestamp)?.timeIntervalSince1970
    }

    /// 补全后的位置、时刻、速率,和要记下的锚点。带位置的原样交回(速率缺了按在不在放补成 1 / 0)并记下;
    /// 没位置的:同一首、是上一份锚点的回声的沿用那份锚点;换了一首、上一份锚点刚到(还没跟过回声)的是自然连播,接过那份锚点;
    /// 在放、带时刻、不是这两种的当新起一首,从 0 起算。纯函数,selftest 覆盖。
    public static func fill(identity: String, playing: Bool?, elapsed: Double?, timestamp: String?, rate: Double?, last: Anchor?)
        -> (elapsed: Double?, timestamp: String?, rate: Double?, remember: Anchor?) {
        let effectiveRate = rate ?? (playing == true ? 1 : 0)
        if let elapsed, let timestamp {
            let anchor = Anchor(identity: identity, elapsed: elapsed, timestamp: timestamp, rate: effectiveRate)
            return (elapsed, timestamp, effectiveRate, anchor)
        }
        guard elapsed == nil else { return (elapsed, timestamp, rate, last) }
        if let last, last.identity != identity, last.echoTimestamp == nil, last.elapsed <= naturalStartMaxElapsedSecs,
           let ts = timestamp,
           let t = seconds(ts), let a = seconds(last.timestamp), t >= a, t - a <= echoWindowSecs {
            // 自然连播:上一份锚点是这首新歌的(先带着上一首的歌名到),接过来、扣掉它的超前量。
            let anchor = Anchor(identity: identity, elapsed: last.elapsed - naturalStartLeadSecs, timestamp: last.timestamp,
                                rate: last.rate, echoTimestamp: ts)
            return (anchor.elapsed, anchor.timestamp, anchor.rate, anchor)
        }
        if let last, last.identity == identity {
            let isEcho = timestamp.map { ts -> Bool in
                if ts == last.echoTimestamp { return true }
                guard let t = seconds(ts), let a = seconds(last.timestamp) else { return false }
                return t >= a && t - a <= echoWindowSecs
            } ?? true
            if isEcho {
                var kept = last
                if kept.echoTimestamp == nil { kept.echoTimestamp = timestamp }
                return (last.elapsed, last.timestamp, last.rate, kept)
            }
        }
        if playing == true, let timestamp {
            let anchor = Anchor(identity: identity, elapsed: 0, timestamp: timestamp, rate: effectiveRate)
            return (0, timestamp, effectiveRate, anchor)
        }
        return (elapsed, timestamp, rate, last)
    }

    /// 解码系统会话时调:不是 Plexamp 的原样交回。
    static func filled(bundleID: String?, identity: String, playing: Bool?, elapsed: Double?, timestamp: String?, rate: Double?)
        -> (elapsed: Double?, timestamp: String?, rate: Double?) {
        guard bundleID == PlaybackPlayer.plexamp.bundleIdentifier else { return (elapsed, timestamp, rate) }
        lock.lock()
        defer { lock.unlock() }
        let out = fill(identity: identity, playing: playing, elapsed: elapsed, timestamp: timestamp, rate: rate, last: last)
        last = out.remember
        return (out.elapsed, out.timestamp, out.rate)
    }
}
