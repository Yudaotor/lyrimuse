import ApplicationServices
import Foundation
import os

/// Cog 放网络流(系统那份时长报 0)时这一首是什么、放到哪。三种标题:
///
/// - 电台里的一首:Cog 把 ICY 标题按「 - 」拆成歌手和歌名,放到这段声音时才换标题(按解码块落地,比真正出声晚 -0.03~+0.95 秒,
///   跟电台开头多推几秒无关),所以不套 reAMP / VOX 的延迟线,只补一个固定量 `titleLagSecs`。系统那份的 elapsed 是连上以来的
///   总秒数、换歌不归零,这一首的位置 = 现在的 elapsed − 这个标题第一次出现时那份锚点的 elapsed + `titleLagSecs`;连上后的第一首
///   不知道从哪里进来的,不给进度。elapsed 往回退了就是重连了。
/// - 同一次连接里只有歌名、没有「 - 」的 ICY 标题,Cog 发给系统的那份不带歌手键,系统会话留着上一首的歌手(`checkedArtist` 读
///   Cog 播放列表那一行核对)。
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

    /// Cog 换标题比这段声音真正出声平均晚这么多秒(锯齿 -0.03~+0.95 取中点),电台里的歌位置都加上它。见 02 章决策 275。
    public static let titleLagSecs: Double = 0.46

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
            return max(0, elapsed - start + titleLagSecs)
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

    /// 回放测试用:清空表和歌手核对。
    public static func reset() {
        clock.withLock { $0 = Clock() }
        artistCheck.withLock { $0 = ArtistCheck() }
    }

    // MARK: 上一首留下的歌手

    /// Cog 播放列表里这个标题那一行的 Artist 列。
    public enum PlaylistArtist: Equatable, Sendable {
        case empty, present, unreadable
    }

    /// 歌手核对:当前标题和它报的歌手、上一个标题报的歌手、这一份核对的结果(没核对为 nil)。
    public struct ArtistCheck: Equatable, Sendable {
        public var title: String?
        public var artist: String
        public var previousArtist: String?
        public var verdict: PlaylistArtist?

        public init(title: String? = nil, artist: String = "", previousArtist: String? = nil, verdict: PlaylistArtist? = nil) {
            self.title = title
            self.artist = artist
            self.previousArtist = previousArtist
            self.verdict = verdict
        }
    }

    /// 走一拍:标题变了换成新的一份,同一个标题歌手变了重新核对。要读列表 = 有歌手、跟上一个标题报的完全相同、还没核对过。
    /// 纯函数,selftest 覆盖。
    public static func step(_ check: ArtistCheck, title: String, artist: String) -> (check: ArtistCheck, needsRead: Bool) {
        var next = check
        if title != check.title {
            next = ArtistCheck(title: title, artist: artist, previousArtist: check.artist)
        } else if artist != check.artist {
            next.artist = artist
            next.verdict = nil
        }
        return (next, !artist.isEmpty && next.previousArtist == artist && next.verdict == nil)
    }

    private static let artistCheck = OSAllocatedUnfairLock(initialState: ArtistCheck())

    /// 这一拍该用的歌手。Cog 放流、标题变了、歌手跟上一个标题完全相同时,`read` 读一次 Cog 播放列表里这个标题那一行:
    /// 读到空就当没有歌手,读到有、读不到照系统那份。每个标题(连同它报的歌手)最多读一次。不是 Cog 放流原样返回。
    public static func checkedArtist(bundleID: String?, title: String?, artist: String?, duration: Double?,
                                     read: (String) -> PlaylistArtist) -> String? {
        guard bundleID == Self.bundleID, let duration, !(duration > 0), let title else { return artist }
        let reported = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let (check, needsRead) = artistCheck.withLock { state -> (ArtistCheck, Bool) in
            let (next, needsRead) = step(state, title: title, artist: reported)
            state = next
            if needsRead { state.verdict = .unreadable }
            return (next, needsRead)
        }
        var verdict = check.verdict
        if needsRead {
            let found = read(title)
            verdict = found
            artistCheck.withLock { state in
                if state.title == title, state.artist == reported { state.verdict = found }
            }
            logger.notice("cog stream: title \(title, privacy: .public) reports the previous title's artist \(reported, privacy: .public), playlist row artist \(String(describing: found), privacy: .public)")
        }
        return verdict == .empty ? nil : artist
    }

    /// 主路径和按 bundle id 单问的那份都过这里:读列表用 Cog 的进程号。
    public static func checkedArtist(bundleID: String?, title: String?, artist: String?, duration: Double?,
                                     pid: Int?) -> String? {
        checkedArtist(bundleID: bundleID, title: title, artist: artist, duration: duration) { title in
            pid.map { Playlist.artist(pid: pid_t($0), title: title) } ?? .unreadable
        }
    }

    /// Cog 主窗口播放列表的可见行。列按标识(`title` / `artist`)认,跟界面语言、列顺序无关;状态列那个正在放的图标读不出来,
    /// 所以按标题列认行。只读属性,不做任何动作。
    public enum Playlist {
        /// 跨进程查询超时,App 元素和往下取到的每个元素都设。
        static let axTimeout: Float = 0.25
        /// 往下找几层找表格(实测窗口 → 滚动区 → 表格)。
        static let maxDepth = 6

        /// 没授辅助功能、拔了 `cog-playlist`、窗口关着、没有这一行(不在可见范围)、Artist 列藏起来了为 `.unreadable`。
        static func artist(pid: pid_t, title: String) -> PlaylistArtist {
            guard !SourceKnockout.isOut(.cogPlaylist), AXIsProcessTrusted() else { return .unreadable }
            let app = MenuBarAX.timed(AXUIElementCreateApplication(pid), timeout: axTimeout)
            for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute, timeout: axTimeout) {
                guard let table = table(in: window, depth: 0) else { continue }
                let columns = MenuBarAX.children(table, attribute: kAXColumnsAttribute, timeout: axTimeout)
                    .map { MenuBarAX.string($0, kAXIdentifierAttribute) }
                guard let titleColumn = columns.firstIndex(of: "title"), let artistColumn = columns.firstIndex(of: "artist")
                else { continue }
                var artists: [String] = []
                for row in MenuBarAX.children(table, attribute: kAXVisibleRowsAttribute, timeout: axTimeout) {
                    let cells = MenuBarAX.children(row, timeout: axTimeout)
                    guard cells.count > max(titleColumn, artistColumn), text(cells[titleColumn]) == title else { continue }
                    artists.append(text(cells[artistColumn]))
                }
                return verdict(rowArtists: artists)
            }
            return .unreadable
        }

        /// 标题对上的那几行的歌手:没有这一行为 `.unreadable`,都是空为 `.empty`,有一行不空为 `.present`。纯函数,selftest 覆盖。
        public static func verdict(rowArtists: [String]) -> PlaylistArtist {
            guard !rowArtists.isEmpty else { return .unreadable }
            return rowArtists.allSatisfy { $0.isEmpty } ? .empty : .present
        }

        private static func table(in element: AXUIElement, depth: Int) -> AXUIElement? {
            for child in MenuBarAX.children(element, timeout: axTimeout) {
                if MenuBarAX.string(child, kAXRoleAttribute) == kAXTableRole { return child }
                if depth + 1 < maxDepth, let hit = table(in: child, depth: depth + 1) { return hit }
            }
            return nil
        }

        /// 单元格里那段文字(去掉首尾空白);读不到为空。
        private static func text(_ cell: AXUIElement) -> String {
            for child in MenuBarAX.children(cell, timeout: axTimeout) {
                if let value = MenuBarAX.string(child, kAXValueAttribute) {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return ""
        }
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
