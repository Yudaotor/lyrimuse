import Foundation
import os

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "pear-api")

/// Pear Desktop 本机接口的 WebSocket 推送(`/api/v1/ws`):换歌、播放 / 暂停、拖进度一来就叫播放源补查一次,不等系统会话
/// (02 章决策 232)。只当「有动静了」的信号,曲目、位置照旧从系统会话和接口读。
///
/// 它连上先推一份 `PLAYER_INFO`,之后 `VIDEO_CHANGED`(换歌)、`PLAYER_STATE_CHANGED`(播放 / 暂停)、`POSITION_CHANGED`
/// (每秒一次,拖进度时也是它)。拖进度从进度跳变里认(`PositionTracker`)。令牌放在地址参数 `token` 里。
/// 连接由 `PearDesktopAPI.noteAppRunning` 每拍维持:Pear 开着、接口能用就连着,断了隔 `retrySecs` 再连;Pear 退出时那头会断。
public final class PearDesktopPush: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public static let shared = PearDesktopPush()

    public enum Event: Equatable, Sendable {
        case trackChanged
        case playState(playing: Bool)
        case seeked
    }

    /// 一条推送里用得上的几样。
    public struct Message: Equatable, Sendable {
        public let type: String
        public let isPlaying: Bool?
        public let position: Double?

        public init(type: String, isPlaying: Bool?, position: Double?) {
            self.type = type
            self.isPlaying = isPlaying
            self.position = position
        }
    }

    /// 连不上时隔多久再试。
    public static let retrySecs: TimeInterval = 5
    /// 进度比按时间推算的位置差出这么多秒就算拖了进度(每秒那条推送自己会抖几百毫秒)。
    public static let seekJumpSecs: Double = 1.5

    /// 推送正文 → `Message`;不是 JSON、没有 `type` 时 nil。纯函数,selftest 覆盖。
    public static func message(from text: String) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        return Message(type: type, isPlaying: object["isPlaying"] as? Bool, position: (object["position"] as? NSNumber)?.doubleValue)
    }

    /// 按在放 / 暂停和上一次的进度推算现在该在哪,认拖进度。纯数据,selftest 覆盖。
    public struct PositionTracker: Equatable, Sendable {
        public private(set) var playing = false
        public private(set) var last: (position: Double, at: Date)?

        public init() {}

        public static func == (a: Self, b: Self) -> Bool {
            a.playing == b.playing && a.last?.position == b.last?.position && a.last?.at == b.last?.at
        }

        /// 一条推送进来,返回要发的事件(没有为 nil)。
        public mutating func handle(_ message: Message, at now: Date) -> Event? {
            switch message.type {
            case "PLAYER_INFO":
                playing = message.isPlaying ?? playing
                last = message.position.map { ($0, now) }
                return nil
            case "VIDEO_CHANGED":
                last = (message.position ?? 0, now)
                return .trackChanged
            case "PLAYER_STATE_CHANGED":
                guard let isPlaying = message.isPlaying else { return nil }
                playing = isPlaying
                last = message.position.map { ($0, now) } ?? last
                return .playState(playing: isPlaying)
            case "POSITION_CHANGED":
                guard let position = message.position else { return nil }
                defer { last = (position, now) }
                guard let last else { return nil }
                let expected = last.position + (playing ? now.timeIntervalSince(last.at) : 0)
                return abs(position - expected) > PearDesktopPush.seekJumpSecs ? .seeked : nil
            default:
                return nil
            }
        }
    }

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var connectedURL: URL?
    private var lastAttempt: Date?
    private var tracker = PositionTracker()
    private var onEvent: (@Sendable (Event) -> Void)?

    /// 有事件时叫谁(只留一个)。回调在后台队列上。
    public func setEventHandler(_ handler: (@Sendable (Event) -> Void)?) {
        lock.lock()
        onEvent = handler
        lock.unlock()
    }

    /// 每拍调:`url` 是该连的地址(带令牌),nil = 不该连(Pear 没开、接口不能用),连着的就断开。
    public func keepAlive(url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        if task != nil, url != connectedURL {
            task?.cancel(with: .goingAway, reason: nil)
            resetLocked()
        }
        guard let url, task == nil else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.retrySecs { return }
        lastAttempt = Date()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        connectedURL = url
        tracker = PositionTracker()
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let frame):
                let text: String?
                switch frame {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                self.lock.lock()
                let mine = task === self.task
                let event = mine ? text.flatMap(Self.message(from:)).flatMap { self.tracker.handle($0, at: Date()) } : nil
                let handler = self.onEvent
                self.lock.unlock()
                guard mine else { return }
                if let event { handler?(event) }
                self.receive(task)
            case .failure(let error):
                self.lock.lock()
                let mine = task === self.task
                if mine { self.resetLocked() }
                self.lock.unlock()
                if mine { logger.notice("pear push: closed (\(error.localizedDescription, privacy: .public))") }
            }
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        logger.notice("pear push: connected")
    }

    private func resetLocked() {
        task = nil
        session?.invalidateAndCancel()
        session = nil
        connectedURL = nil
    }
}
