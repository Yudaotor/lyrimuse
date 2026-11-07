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
