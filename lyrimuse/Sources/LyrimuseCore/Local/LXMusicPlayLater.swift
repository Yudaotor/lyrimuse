import Foundation
import os

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "lx-play-later")

/// 从 Lyrimuse 加进洛雪「稍后播放」的那几首(收听统计右键菜单那一项,`LXMusicLinks`)。洛雪的「稍后播放」只在它内存里,
/// 谁都读不到;Lyrimuse 自己加的自己记下,写进 `lyrimuse-lx-play-later.json`,引擎预解析时排在洛雪列表那几首前面
/// (lyrimuse-engine/lxmusic.go 的 `lxMusicPlayLaterQueued`)。洛雪放到了就从文件里划掉(`noteStartedPlaying`),
/// 超过 `maxAge` 的写的时候顺手清掉(洛雪重开过,那个队列就没了)。形状两边一起改,样例 shared/testdata/lx-play-later.json
/// 两边测试各读一遍。见 09 章决策 265。
public enum LXMusicPlayLater {
    public static let fileName = "lyrimuse-lx-play-later.json"
    /// 跟引擎的 `lxMusicPlayLaterTTL` 同一个数,两处一起改。
    public static let maxAge: TimeInterval = 6 * 3600
    /// 最多记这么多首,多了丢最早的。
    public static let maxCount = 30

    public struct Entry: Codable, Equatable, Sendable {
        public let title: String
        public let artist: String
        public let album: String
        public let addedAtMs: Int64

        enum CodingKeys: String, CodingKey {
            case title, artist, album
            case addedAtMs = "added_at_ms"
        }

        public init(title: String, artist: String, album: String, addedAtMs: Int64) {
            self.title = title
            self.artist = artist
            self.album = album
            self.addedAtMs = addedAtMs
        }
    }

    public struct File: Codable, Equatable, Sendable {
        public var schema = 1
        public var tracks: [Entry]

        public init(tracks: [Entry]) { self.tracks = tracks }
    }

    static let lock = NSLock()

    public static var url: URL { LyrimusePaths.configFile(fileName) }

    // MARK: - 纯函数

    /// 加一首:去掉过期的、跟它同名同歌手的旧记录,接在末尾,超过 `maxCount` 丢最早的。歌名、歌手有一个是空的不记。
    public static func adding(_ track: LXMusicLinks.Track, to entries: [Entry], now: Date) -> [Entry] {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return pruned(entries, now: now) }
        var out = pruned(entries, now: now).filter { !same($0, title: title, artist: artist) }
        out.append(Entry(title: title, artist: artist, album: track.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                         addedAtMs: Int64((now.timeIntervalSince1970 * 1000).rounded())))
        return Array(out.suffix(maxCount))
    }

    /// 洛雪放到了这一首:划掉它(连同过期的)。
    public static func removing(title: String?, artist: String?, from entries: [Entry], now: Date) -> [Entry] {
        pruned(entries, now: now).filter { !same($0, title: title ?? "", artist: artist ?? "") }
    }

    static func pruned(_ entries: [Entry], now: Date) -> [Entry] {
        let cutoff = Int64(((now.timeIntervalSince1970 - maxAge) * 1000).rounded())
        return entries.filter { $0.addedAtMs >= cutoff }
    }

    /// 同一首:歌名、歌手去首尾空白后不分大小写相同。
    static func same(_ e: Entry, title: String, artist: String) -> Bool {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return norm(e.title).compare(norm(title), options: [.caseInsensitive]) == .orderedSame
            && norm(e.artist).compare(norm(artist), options: [.caseInsensitive]) == .orderedSame
    }

    public static func decode(_ data: Data?) -> [Entry] {
        guard let data, let file = try? JSONDecoder().decode(File.self, from: data), file.schema == 1 else { return [] }
        return file.tracks
    }

    public static func encode(_ entries: [Entry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(File(tracks: entries))
    }

    // MARK: - 线上

    /// 用户从 Lyrimuse 把这首加进了洛雪的「稍后播放」。
    public static func record(_ track: LXMusicLinks.Track, now: Date = Date()) {
        update { adding(track, to: $0, now: now) }
        logger.notice("lx play later: recorded \(track.artist, privacy: .public) - \(track.title, privacy: .public)")
    }

    /// 洛雪开始放这一首(`LocalPlaybackSource` 换歌时调):在记录里就划掉。没有文件时什么都不做。
    public static func noteStartedPlaying(title: String?, artist: String?, now: Date = Date()) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        update { removing(title: title, artist: artist, from: $0, now: now) }
    }

    private static func update(_ change: ([Entry]) -> [Entry]) {
        lock.lock()
        defer { lock.unlock() }
        let before = decode(FileIO.read(url))
        let after = change(before)
        guard after != before else { return }
        if after.isEmpty {
            _ = FileIO.remove(url)
        } else if let data = encode(after) {
            _ = FileIO.write(data, to: url)
        }
    }
}
