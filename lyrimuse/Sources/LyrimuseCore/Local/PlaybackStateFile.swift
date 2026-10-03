import CryptoKit
import Foundation
import os

/// App → collector 的播放状态文件:「此刻在放什么、放到哪」由 App 整份写出,collector 只读、从不删改。
///
/// 契约(字段含义、序号语义、新鲜度)与 collector 侧 `appstate.go` 一致,样例在
/// `shared/testdata/playback-state/`,两侧测试各跑一遍;改字段两边一起改。
///
/// - 位置是播放器的真实播放时间(已含各播放器的修正),**不含**任何歌词偏移。
/// - `play_seq`:每开始播一首加一,同一首重新起播(单曲循环、拖回开头)也加一;从停播回到同一首不加。
/// - `anchor_seq`:位置出现一次不连续(拖动、恢复、校准跳变)加一。位置在连续播放期间不重写,
///   读方按 `secs + (now - at_ms) × rate` 外推。
/// - 平时每 `heartbeatInterval` 秒重写一次(`seq` 与 `written_at_ms` 前进),读方据此判 App 还在。
/// - `holding`:App 这几拍读不到播放器、还在宽限期里按住上一份状态(单拍读空、焦点被别的 App 占走),
///   内容是旧的,读方不该按它继续累计收听时长。
public enum PlaybackStateFile {
    public static let fileName = "lyrimuse-playback-state.json"
    public static let artworkFileName = "lyrimuse-now-playing-artwork"
    public static var url: URL { LyrimusePaths.configFile(fileName) }
    public static var artworkURL: URL { LyrimusePaths.configFile(artworkFileName) }

    public static let schema = 1
    public static let heartbeatInterval: TimeInterval = 5

    /// 位置跟上一份写出的外推值差出这么多才重写位置(并让 `anchor_seq` 加一)。
    public static let positionRepublishToleranceSecs = 0.25
    /// 单曲循环判据:上一拍放到曲长的这个比例之后、这一拍回到开头这么多秒以内,算同一首重新起播(play_seq 加一)。
    public static let loopRestartMinElapsedFrac = 0.9
    public static let loopRestartMaxNewElapsedSecs = 10.0

    public enum State: String, Codable, Sendable {
        case playing, paused, idle, exiting
    }

    public struct Tags: Codable, Equatable, Sendable {
        public var title: String
        public var artist: String
        public var album: String

        public init(title: String, artist: String, album: String) {
            self.title = title
            self.artist = artist
            self.album = album
        }
    }

    public struct Radio: Codable, Equatable, Sendable {
        public var stationHash: String
        public var stationName: String?
        public var talkBreak: Bool
        public var stationCard: Bool

        public init(stationHash: String, stationName: String?, talkBreak: Bool, stationCard: Bool) {
            self.stationHash = stationHash
            self.stationName = stationName
            self.talkBreak = talkBreak
            self.stationCard = stationCard
        }

        enum CodingKeys: String, CodingKey {
            case stationHash = "station_hash"
            case stationName = "station_name"
            case talkBreak = "talk_break"
            case stationCard = "station_card"
        }
    }

    public struct Track: Codable, Equatable, Sendable {
        public var playSeq: Int
        public var title: String
        public var artist: String
        public var album: String
        public var raw: Tags
        public var appliedFixRev: Int64
        public var durationSecs: Double?
        public var catalogTrackID: Int64?
        public var trackNumber: Int?
        public var mediaType: String?
        public var musicVideo: Bool
        public var radio: Radio?
        public var ad: Bool
        /// Spotify 原生播放时这首的曲目 ID(`spotify:track:` 之后那段),来自 Spotify 自己的播放通知、按歌名歌手核对过;
        /// 别的播放器 / 没收到通知为 nil。
        public var spotifyTrackID: String? = nil
        /// Amazon Music 时这首在它日志里的曲目标识(`asin://…`),位置是按日志算出来的那一拍才有。
        public var amazonTrackID: String? = nil
        /// Kaset 放这首时它报的 YouTube Music videoId(collector 拼成歌曲页存进缓存);别的播放器为 nil。
        public var youtubeMusicVideoID: String? = nil

        enum CodingKeys: String, CodingKey {
            case playSeq = "play_seq"
            case title, artist, album, raw
            case appliedFixRev = "applied_fix_rev"
            case durationSecs = "duration_secs"
            case catalogTrackID = "catalog_track_id"
            case trackNumber = "track_number"
            case mediaType = "media_type"
            case musicVideo = "music_video"
            case radio, ad
            case spotifyTrackID = "spotify_track_id"
            case amazonTrackID = "amazon_track_id"
            case youtubeMusicVideoID = "youtube_music_video_id"
        }
    }

    public struct Position: Codable, Equatable, Sendable {
        public var secs: Double
        public var atMs: Int64
        public var rate: Double
        public var anchorSeq: Int

        enum CodingKeys: String, CodingKey {
            case secs
            case atMs = "at_ms"
            case rate
            case anchorSeq = "anchor_seq"
        }
    }

    public struct Artwork: Codable, Equatable, Sendable {
        public var sha256: String
        public var mime: String
        public var bytes: Int
        public var playSeq: Int

        enum CodingKeys: String, CodingKey {
            case sha256, mime, bytes
            case playSeq = "play_seq"
        }
    }

    /// 除序号与写入时刻之外的全部内容 —— 它没变就不重写(只剩保活)。
    public struct Content: Equatable, Sendable {
        public var state: State
        public var player: String
        public var track: Track?
        public var position: Position?
        public var artwork: Artwork?
        public var holding = false

        public static let idle = Content(state: .idle, player: "", track: nil, position: nil, artwork: nil)
        public static let exiting = Content(state: .exiting, player: "", track: nil, position: nil, artwork: nil)
    }

    public struct Record: Codable, Equatable, Sendable {
        public var schema: Int
        public var appPID: Int32
        public var appStartedAtMs: Int64
        public var seq: Int64
        public var writtenAtMs: Int64
        public var state: State
        public var player: String
        public var track: Track?
        public var position: Position?
        public var artwork: Artwork?
        /// 只在为真时写出(见 `Content.holding`)。
        public var holding: Bool?

        enum CodingKeys: String, CodingKey {
            case schema
            case appPID = "app_pid"
            case appStartedAtMs = "app_started_at_ms"
            case seq
            case writtenAtMs = "written_at_ms"
            case state, player, track, position, artwork, holding
        }

        public init(content: Content, appPID: Int32, appStartedAtMs: Int64, seq: Int64, writtenAtMs: Int64) {
            schema = PlaybackStateFile.schema
            self.appPID = appPID
            self.appStartedAtMs = appStartedAtMs
            self.seq = seq
            self.writtenAtMs = writtenAtMs
            state = content.state
            player = content.player
            track = content.track
            position = content.position
            artwork = content.artwork
            holding = content.holding ? true : nil
        }
    }

    public static func encode(_ record: Record) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(record)
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    // MARK: - 每拍的输入与推导

    /// App 这一拍认定的播放状态。`title` 为空 = 此刻没有可认的音乐在放(写成 `idle`)。
    public struct Input: Equatable, Sendable {
        public var player: String
        public var title: String
        public var artist: String
        public var album: String
        public var raw: Tags
        public var appliedFixRev: Int64
        public var playing: Bool
        public var durationSecs: Double?
        public var catalogTrackID: Int64?
        public var trackNumber: Int?
        public var mediaType: String?
        public var musicVideo: Bool
        public var radio: Radio?
        public var ad: Bool
        /// 此刻的播放位置(秒);没有位置(播着但还没有时长的那一拍)为 nil。
        public var positionSecs: Double?
        public var spotifyTrackID: String?
        public var amazonTrackID: String?
        public var youtubeMusicVideoID: String?

        public init(player: String, title: String, artist: String, album: String, raw: Tags,
                    appliedFixRev: Int64, playing: Bool, durationSecs: Double?,
                    catalogTrackID: Int64? = nil, trackNumber: Int? = nil, mediaType: String? = nil,
                    musicVideo: Bool = false, radio: Radio? = nil, ad: Bool = false, positionSecs: Double?,
                    spotifyTrackID: String? = nil, amazonTrackID: String? = nil, youtubeMusicVideoID: String? = nil) {
            self.player = player
            self.title = title
            self.artist = artist
            self.album = album
            self.raw = raw
            self.appliedFixRev = appliedFixRev
            self.playing = playing
            self.durationSecs = durationSecs
            self.catalogTrackID = catalogTrackID
            self.trackNumber = trackNumber
            self.mediaType = mediaType
            self.musicVideo = musicVideo
            self.radio = radio
            self.ad = ad
            self.positionSecs = positionSecs
            self.spotifyTrackID = spotifyTrackID
            self.amazonTrackID = amazonTrackID
            self.youtubeMusicVideoID = youtubeMusicVideoID
        }

        public static func idle() -> Input {
            Input(player: "", title: "", artist: "", album: "", raw: Tags(title: "", artist: "", album: ""),
                  appliedFixRev: 0, playing: false, durationSecs: nil, positionSecs: nil)
        }

        /// 身份比较用的 key,与 collector 会话 key(`Title|Artist|Album`)同形。
        var identityKey: String { "\(title)|\(artist)|\(album)" }
    }

    /// 把每拍的输入推成要写出的内容:序号、位置要不要重写、封面对应哪一首。纯状态机,selftest 直接覆盖。
    public struct Tracker: Sendable {
        public private(set) var playSeq = 0
        public private(set) var anchorSeq = 0
        private var identityKey: String?
        private var published: Position?
        /// 上一拍算出的位置(不论写没写出),判单曲循环用。换歌 / 停播时清掉。
        private var lastObservedSecs: Double?
        private var artwork: Artwork?

        public init() {}

        public mutating func advance(_ input: Input, now: Date) -> Content {
            guard !input.title.isEmpty else {
                // 停播不清身份:回到同一首时 play_seq 不加,会话续接由 collector 自己的宽限决定。
                lastObservedSecs = nil
                published = nil
                return .idle
            }
            let key = input.identityKey
            var restarted = false
            if key != identityKey {
                playSeq += 1
                identityKey = key
                restarted = true
            } else if Self.loopRestarted(previous: lastObservedSecs, current: input.positionSecs,
                                         durationSecs: input.durationSecs, playing: input.playing) {
                playSeq += 1
                restarted = true
            }
            lastObservedSecs = input.positionSecs
            if let secs = input.positionSecs {
                let rate = input.playing ? 1.0 : 0.0
                if restarted || Self.needsRepublish(published, secs: secs, rate: rate, now: now) {
                    anchorSeq += 1
                    published = Position(secs: (secs * 1000).rounded() / 1000, atMs: PlaybackStateFile.millis(now),
                                         rate: rate, anchorSeq: anchorSeq)
                }
            } else {
                published = nil
            }
            let track = Track(
                playSeq: playSeq, title: input.title, artist: input.artist, album: input.album, raw: input.raw,
                appliedFixRev: input.appliedFixRev, durationSecs: input.durationSecs,
                catalogTrackID: input.catalogTrackID, trackNumber: input.trackNumber, mediaType: input.mediaType,
                musicVideo: input.musicVideo, radio: input.radio, ad: input.ad, spotifyTrackID: input.spotifyTrackID,
                amazonTrackID: input.amazonTrackID, youtubeMusicVideoID: input.youtubeMusicVideoID)
            return Content(state: input.playing ? .playing : .paused, player: input.player, track: track,
                           position: published, artwork: artwork)
        }

        /// 记下这一首刚换上的封面(nil = 这首没有封面)。封面带着当时的 `play_seq`,换歌后读方据此认出它属于上一首。
        public mutating func noteArtwork(sha256: String?, mime: String, bytes: Int) {
            artwork = sha256.map { Artwork(sha256: $0, mime: mime, bytes: bytes, playSeq: playSeq) }
        }

        public var currentArtwork: Artwork? { artwork }

        /// 上一拍已过 90%、这一拍回到开头 10 秒内才算重新起播。位置停在 / 越过曲长不算:那是这首还没结束、或位置读数卡在了曲末,
        /// 按它判会每拍都加一。
        public static func loopRestarted(previous: Double?, current: Double?, durationSecs: Double?, playing: Bool) -> Bool {
            guard playing, let previous, let current, let duration = durationSecs, duration > 0 else { return false }
            return previous >= duration * loopRestartMinElapsedFrac && current <= loopRestartMaxNewElapsedSecs
        }

        static func needsRepublish(_ published: Position?, secs: Double, rate: Double, now: Date) -> Bool {
            guard let published else { return true }
            if published.rate != rate { return true }
            let elapsed = Double(PlaybackStateFile.millis(now) - published.atMs) / 1000
            let expected = published.secs + elapsed * published.rate
            return abs(secs - expected) > positionRepublishToleranceSecs
        }
    }

    // MARK: - 封面

    public static func artworkMime(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return "image/heic" }
        return "application/octet-stream"
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 播放状态文件的写方:内容变了就写,没变时每 `heartbeatInterval` 秒保活一次;退出时写 `exiting`。
///
/// 保活计时器跑在主线程上:主线程卡住时保活也停,collector 据此判 App 不可用,而不是按一份冻住的「在播」继续计时。
/// 保活离上一次写出晚到 `lateHeartbeatSeconds` 以上记一行 notice(collector 15 秒判过期);对照 MainThreadWatchdog
/// 的记录,分得清是主线程卡住了还是计时器被系统推迟了。间隔按不含睡眠的系统运行时长算。
///
/// 只在以 Lyrimuse.app 身份运行时落盘:selftest 与 `swift run` 起的进程共用同一个配置目录,
/// 让它们写会盖掉正在运行的 App 那份,collector 就会读到测试数据。
@MainActor
public final class PlaybackStatePublisher {
    public static let shared = PlaybackStatePublisher()
    public static let lateHeartbeatSeconds: TimeInterval = 10

    private let writesEnabled = Bundle.main.bundleIdentifier == LyrimuseIdentity.bundleIdentifier
    private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "playback-state")
    private var lastWriteUptime: TimeInterval?

    private let appPID = getpid()
    private let appStartedAtMs = PlaybackStateFile.millis(Date())
    private var seq: Int64 = 0
    private var tracker = PlaybackStateFile.Tracker()
    private var lastContent: PlaybackStateFile.Content?
    private var heartbeat: Timer?
    private var exiting = false
    private let artworkQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.playback-state-artwork", qos: .utility)
    /// 最近一次写出的封面校验和,同一张图不重复落盘。
    private var writtenArtworkSHA: String?

    private init() {}

    public func publish(_ input: PlaybackStateFile.Input, now: Date = Date()) {
        guard !exiting else { return }
        let content = tracker.advance(input, now: now)
        startHeartbeatIfNeeded()
        guard content != lastContent else { return }
        lastContent = content
        write(content, now: now)
    }

    /// 交给 collector 的设备封面:不像封面的图(太小、不是方形,见 `CoverArtReplacementGate.isUsableDeviceArtwork`)
    /// 按没有封面发,collector 退回按歌名找封面。播放器的内置占位图走不到这里:`LocalPlaybackSource` 认出来就不采纳。
    public nonisolated static func artworkForCollector(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        let size = CoverArtReplacementGate.pixelSize(of: data)
        return CoverArtReplacementGate.isUsableDeviceArtwork(width: size.width, height: size.height) ? data : nil
    }

    /// 这一首换上了新封面(nil = 确认没有封面)。交给 collector 的那份(`artworkForCollector`)落到
    /// `lyrimuse-now-playing-artwork`,状态里记校验和。
    public func noteArtwork(_ data: Data?) {
        guard !exiting else { return }
        guard let data = Self.artworkForCollector(data) else {
            tracker.noteArtwork(sha256: nil, mime: "", bytes: 0)
            republishArtwork()
            return
        }
        let sha = PlaybackStateFile.sha256Hex(data)
        tracker.noteArtwork(sha256: sha, mime: PlaybackStateFile.artworkMime(data), bytes: data.count)
        if writesEnabled, sha != writtenArtworkSHA {
            writtenArtworkSHA = sha
            let url = PlaybackStateFile.artworkURL
            artworkQueue.async { try? data.write(to: url, options: .atomic) }
        }
        republishArtwork()
    }

    /// 读不到播放器、还在宽限期里按住上一份状态时置真;下一次正常发布自动清掉。
    public func setHolding(_ holding: Bool) {
        guard !exiting, var content = lastContent, content.state == .playing || content.state == .paused,
              content.holding != holding else { return }
        content.holding = holding
        lastContent = content
        write(content, now: Date())
    }

    public func markExiting() {
        guard !exiting else { return }
        exiting = true
        heartbeat?.invalidate()
        heartbeat = nil
        write(.exiting, now: Date())
    }

    /// 封面在换歌之后异步到,落在两拍之间:只换封面、不推进序号与位置。
    private func republishArtwork() {
        guard var content = lastContent, content.state == .playing || content.state == .paused else { return }
        content.artwork = tracker.currentArtwork
        guard content != lastContent else { return }
        lastContent = content
        write(content, now: Date())
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: PlaybackStateFile.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.exiting, let content = self.lastContent else { return }
                if let last = self.lastWriteUptime {
                    let gap = ProcessInfo.processInfo.systemUptime - last
                    if gap >= Self.lateHeartbeatSeconds {
                        self.logger.notice("playback state: heartbeat \(String(format: "%.1f", gap), privacy: .public)s after the last write")
                    }
                }
                self.write(content, now: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func write(_ content: PlaybackStateFile.Content, now: Date) {
        guard writesEnabled else { return }
        lastWriteUptime = ProcessInfo.processInfo.systemUptime
        seq += 1
        let record = PlaybackStateFile.Record(content: content, appPID: appPID, appStartedAtMs: appStartedAtMs,
                                              seq: seq, writtenAtMs: PlaybackStateFile.millis(now))
        guard let data = PlaybackStateFile.encode(record) else { return }
        try? data.write(to: PlaybackStateFile.url, options: .atomic)
    }
}
