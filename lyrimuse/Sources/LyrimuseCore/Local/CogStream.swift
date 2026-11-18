import Foundation
import os

/// Cog 放网络流(系统那份时长报 0)时这一首是什么、放到哪。三种标题:
///
/// - 电台里的一首:Cog 把 ICY 标题按「 - 」拆成歌手和歌名,在这段声音真正放出来时才换(早 0.13~0.20 秒,跟电台开头多推几秒无关),
///   所以不套 reAMP / VOX 的延迟线。系统那份的 elapsed 是连上以来的总秒数、换歌不归零,这一首的位置 = 现在的 elapsed − 这个标题
///   第一次出现时那份锚点的 elapsed;连上后的第一首不知道从哪里进来的,不给进度。elapsed 往回退了就是重连了。
/// - 网上的音频文件:Cog 不读 http 条目的标签,标题是地址最后一段(「歌手 - 歌名.mp3」),去扩展名再拆(`networkFile`),
///   位置就是系统那份的。
/// - 没有歌手、也不带音频扩展名的标题不当歌(`isPlaceholder`):连上那一拍的占位(地址最后一段)、只有歌名没有「 - 」的 ICY 标题。
///
/// 只认 Cog 的 bundle id、只认时长报 0 的那份(本地文件的时长都大于 0)。见 02 章决策 275。
public enum CogStream {
    public static let bundleID = PlaybackPlayer.cog.bundleIdentifier

    /// 这一份是哪种标题。
    public enum Kind: Equatable, Sendable {
        case song
        case file(artist: String, title: String)
        case placeholder
    }

    /// 不是 Cog 放流(别的播放器、本地文件)为 nil。纯函数,selftest 覆盖。
    public static func kind(bundleID: String?, title: String?, artist: String?, duration: Double?) -> Kind? {
        guard bundleID == Self.bundleID, let duration, !(duration > 0) else { return nil }
        if !(artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .song }
        guard let title, PlayerTitleSplit.hasAudioExtension(title), let named = VoxPlayerInfo.fileNameIdentity(title) else {
            return .placeholder
        }
        return .file(artist: named.artist, title: named.title)
    }

    /// 放网上文件时换上去的歌手和歌名;别的情况为 nil。纯函数,selftest 覆盖。
    public static func networkFile(bundleID: String?, title: String?, artist: String?,
                                   duration: Double?) -> (artist: String, title: String)? {
        guard case .file(let artist, let title)? = kind(bundleID: bundleID, title: title, artist: artist, duration: duration)
        else { return nil }
        return (artist, title)
    }

    /// 调用方当成没在放音乐(`MediaControlClient.playerContentNotMusic`)。纯函数,selftest 覆盖。
    public static func isPlaceholder(bundleID: String?, title: String?, artist: String?, duration: Double?) -> Bool {
        kind(bundleID: bundleID, title: title, artist: artist, duration: duration) == .placeholder
    }

    /// elapsed 往回退超过这么多秒算重连。
    static let reconnectSlackSecs: Double = 0.5

    /// 电台这一路的表。
    public struct Clock: Equatable, Sendable {
        /// 屏上这首(歌手和歌名拼成的曲目键);占位、网上文件时为 nil。
        public var song: String?
        /// 这首从连上以来的第几秒开始;连上后的第一首为 nil。
        public var start: Double?
        /// 连上以来见过电台里的歌。
        public var sawSong: Bool
        /// 上一份锚点的 elapsed。
        public var lastAnchor: Double?

        public init(song: String? = nil, start: Double? = nil, sawSong: Bool = false, lastAnchor: Double? = nil) {
            self.song = song
            self.start = start
            self.sawSong = sawSong
            self.lastAnchor = lastAnchor
        }
    }

    /// 走一拍。`song`:这一份的曲目键;`anchorElapsed`:系统那份锚点的 elapsed(不是外推过的)。纯函数,selftest 覆盖。
    public static func advance(_ clock: Clock, kind: Kind, song: String, anchorElapsed: Double?) -> Clock {
        var clock = clock
        if let anchorElapsed, let last = clock.lastAnchor, anchorElapsed + reconnectSlackSecs < last { clock = Clock() }
        if let anchorElapsed { clock.lastAnchor = anchorElapsed }
        switch kind {
        case .song:
            guard song != clock.song else { break }
            clock.start = clock.sawSong ? anchorElapsed : nil
            clock.song = song
            clock.sawSong = true
        case .file:
            clock = Clock(lastAnchor: clock.lastAnchor)
        case .placeholder:
            clock.song = nil
            clock.start = nil
        }
        return clock
    }

    /// 这一拍报的位置。`elapsed`:系统那份外推到这一拍的 elapsed。纯函数,selftest 覆盖。
    public static func position(_ clock: Clock, kind: Kind, elapsed: Double?) -> Double? {
        switch kind {
        case .file: return elapsed
        case .song:
            guard let start = clock.start, let elapsed else { return nil }
            return max(0, elapsed - start)
        case .placeholder: return nil
        }
    }

    public struct Reading: Equatable, Sendable {
        public var kind: Kind
        /// 这一拍的位置;不知道(连上后的第一首、占位)为 nil。
        public var position: Double?
        /// 锚点那一刻的位置,同上。
        public var anchorPosition: Double?
    }

    private static let clock = OSAllocatedUnfairLock(initialState: Clock())
    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "player-file")

    /// 主路径和按 bundle id 单问的那份都过这里。不是 Cog 放流为 nil。
    public static func reading(bundleID: String?, title: String?, artist: String?, duration: Double?,
                               anchorElapsed: Double?, elapsed: Double?) -> Reading? {
        guard let kind = kind(bundleID: bundleID, title: title, artist: artist, duration: duration) else { return nil }
        let song = MediaControlSnapshot.trackKey(artist: artist, title: title)
        let (before, after) = clock.withLock { state -> (Clock, Clock) in
            let before = state
            state = advance(state, kind: kind, song: song, anchorElapsed: anchorElapsed)
            return (before, state)
        }
        if let anchorElapsed, let last = before.lastAnchor, anchorElapsed + reconnectSlackSecs < last {
            logger.notice("cog stream: elapsed went back \(last, format: .fixed(precision: 3)) → \(anchorElapsed, format: .fixed(precision: 3)), reconnected")
        }
        let newTitle = loggedTitle.withLock { last in
            defer { last = title }
            return last != title
        }
        if newTitle || before.song != after.song || before.start != after.start {
            log(kind: kind, title: title, clock: after, anchorElapsed: anchorElapsed)
        }
        let anchorPosition = position(after, kind: kind, elapsed: anchorElapsed)
        return Reading(kind: kind, position: position(after, kind: kind, elapsed: elapsed), anchorPosition: anchorPosition)
    }

    /// 回放测试用:清空表。
    public static func reset() {
        clock.withLock { $0 = Clock() }
    }

    /// 打过日志的那个标题,同一个只打一次。
    private static let loggedTitle = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static func log(kind: Kind, title: String?, clock: Clock, anchorElapsed: Double?) {
        let anchor = anchorElapsed ?? -1
        switch kind {
        case .song:
            if let start = clock.start {
                logger.notice("cog stream: title \(title ?? "", privacy: .public) starts at stream second \(start, format: .fixed(precision: 3))")
            } else {
                logger.notice("cog stream: first title after connect \(title ?? "", privacy: .public) at stream second \(anchor, format: .fixed(precision: 3)), no position")
            }
        case .file(let artist, let name):
            logger.notice("cog stream: network file \(title ?? "", privacy: .public) → artist=\(artist, privacy: .public) title=\(name, privacy: .public)")
        case .placeholder:
            logger.notice("cog stream: artistless title without an audio extension \(title ?? "", privacy: .public), not reported as a song")
        }
    }
}
