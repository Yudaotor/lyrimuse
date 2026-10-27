import Foundation
import os

/// QQ 音乐、网易云、酷狗用「打开文件」、Spotify 从它的「本地文件」列表放本机的音频文件时,按快照里的进程号找到它开着的
/// 那个文件(`ProcessOpenFiles`;快照没带进程号时按 bundle id 找主进程,Spotify 的快照来自脚本、不带):
/// 路径写进播放状态(`local_file`,引擎读同名 .lrc 和文件里的歌词)、没报封面时用同目录的图;标签里有歌名时换成标签里的
/// 歌手、歌名、专辑和精确时长(网易云把带扩展名的文件名报成歌名,酷狗不读标签、按文件名拆歌手歌名)。
/// 在线播放时它们开着的是自己的缓存(网易云 `.uc!`、Spotify 没有扩展名的缓存文件),不在 `PlayerTitleSplit.audioExtensions`
/// 里,不会认成本机文件。见 02 章决策 188、196。
public enum PlayerOpenFile {
    public static let bundleIDs: Set<String> = [
        PlaybackPlayer.qqMusic.bundleIdentifier, PlaybackPlayer.netease.bundleIdentifier,
        PlaybackPlayer.kugou.bundleIdentifier, PlaybackPlayer.spotify.bundleIdentifier,
    ]

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "player-file")

    /// 播放器报的这一首是不是这个文件。三种报法都认:标签里的歌名(QQ;报了歌手时还得跟标签一致)、带或不带扩展名的
    /// 文件名(网易云)、文件名在第一个 `-` 处拆开去掉空白的歌手和歌名(酷狗)。两边连续空白压成一个比;两边都有时长时差
    /// 1.5 秒以内。纯函数,selftest 覆盖。
    public static func fileMatches(reportedArtist: String, reportedTitle: String, reportedDuration: Double?,
                                   tags: LocalAudioFileTags?, fileName: String) -> Bool {
        if let reportedDuration, let duration = tags?.duration, abs(duration - reportedDuration) > 1.5 { return false }
        let title = PlayerTitleSplit.collapsedWhitespace(reportedTitle)
        let artist = PlayerTitleSplit.collapsedWhitespace(reportedArtist)
        guard !title.isEmpty else { return false }
        if let tags, !tags.title.isEmpty, PlayerTitleSplit.collapsedWhitespace(tags.title) == title,
           artist.isEmpty || PlayerTitleSplit.collapsedWhitespace(tags.artist) == artist { return true }
        let base = PlayerTitleSplit.strippingAudioExtension(fileName)
        if title == PlayerTitleSplit.collapsedWhitespace(fileName) || title == PlayerTitleSplit.collapsedWhitespace(base) {
            return true
        }
        if let dash = base.firstIndex(of: "-") {
            let left = PlayerTitleSplit.collapsedWhitespace(String(base[..<dash]))
            let right = PlayerTitleSplit.collapsedWhitespace(String(base[base.index(after: dash)...]))
            if !left.isEmpty, left == artist, right == title { return true }
        }
        return false
    }

    /// 没写歌名的文件、播放器把带扩展名的文件名报成歌名时(网易云):去掉扩展名和音轨号,按第一个 ` - ` 拆成歌手和歌名
    /// (播放器报了歌手就用它报的)。别的报法原样留着,返回 nil。纯函数,selftest 覆盖。
    public static func fileNameIdentity(reportedArtist: String, reportedTitle: String, fileName: String,
                                        duration: Double?) -> PlayerTitleSplit.FileIdentity? {
        let base = PlayerTitleSplit.strippingAudioExtension(fileName)
        guard base != fileName,
              PlayerTitleSplit.collapsedWhitespace(reportedTitle) == PlayerTitleSplit.collapsedWhitespace(fileName) else { return nil }
        let name = PlayerTitleSplit.repairingCJKMojibake(PlayerTitleSplit.strippingTrackNumber(base))
        var artist = reportedArtist.trimmingCharacters(in: .whitespaces), title = name
        if let dash = name.range(of: " - ") {
            let left = name[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = PlayerTitleSplit.strippingTrackNumber(name[dash.upperBound...].trimmingCharacters(in: .whitespaces))
            if !left.isEmpty, !right.isEmpty {
                title = right
                if artist.isEmpty { artist = left }
            }
        }
        return PlayerTitleSplit.FileIdentity(artist: artist, title: title, album: "", duration: duration)
    }

    private struct CacheEntry: Sendable {
        var identity: PlayerTitleSplit.FileIdentity?
        var path: String?
        var checkedAt: Date
        var attempts: Int
    }

    /// 按播放器报的(歌手、歌名)记,同一首每拍不重复读盘;没找到的按 `PlayerTitleSplit.shouldLookUpFile` 的节奏再找。
    private static let cache = OSAllocatedUnfairLock<[String: CacheEntry]>(initialState: [:])

    private static func cacheKey(artist: String?, title: String) -> String { (artist ?? "") + "\u{1F}" + title }

    /// 换到快照上:对上了开着的文件、标签里有歌名就换成标签那份;都不用换时原样返回。会读盘(同一首只读一次),在轮询的后台线程上调。
    public static func applied(to snapshot: MediaControlSnapshot?, now: Date = Date()) -> MediaControlSnapshot? {
        guard let snapshot, let bundleID = snapshot.bundleIdentifier, bundleIDs.contains(bundleID),
              let title = snapshot.title, !title.isEmpty,
              let file = fileIdentity(artist: snapshot.artist, title: title, duration: snapshot.duration,
                                      pid: snapshot.processIdentifier ?? PlayerProcess.pid(bundleID: bundleID).map { Int($0) },
                                      now: now) else { return snapshot }
        var out = snapshot.withTitle(file.title)
        if !file.artist.isEmpty { out = out.withArtist(file.artist) }
        if !file.album.isEmpty { out = out.withAlbum(file.album) }
        if let duration = file.duration { out = out.withDuration(duration) }
        return out
    }

    /// `pid` 只在要读盘时才取(缓存命中时不找进程)。
    static func fileIdentity(artist: String?, title: String, duration: Double?, pid: @autoclosure () -> Int?,
                             now: Date = Date()) -> PlayerTitleSplit.FileIdentity? {
        let key = cacheKey(artist: artist, title: title)
        if let hit = cache.withLock({ $0[key] }),
           !PlayerTitleSplit.shouldLookUpFile(found: hit.path != nil, attempts: hit.attempts,
                                              sinceChecked: now.timeIntervalSince(hit.checkedAt)) {
            return hit.identity
        }
        guard let pid = pid(), pid > 0 else { return nil }
        let found = lookUp(artist: artist ?? "", title: title, duration: duration, pid: pid_t(pid))
        cache.withLock { entries in
            if entries.count > 64 { entries.removeAll() }
            let previous = entries[key]?.attempts ?? 0
            let attempts = previous >= PlayerTitleSplit.maxAttempts ? 1 : previous + 1
            entries[key] = CacheEntry(identity: found?.identity, path: found?.path, checkedAt: now, attempts: attempts)
        }
        return found?.identity
    }

    /// 播放器原样报的(歌手、歌名)换成的标签身份(`applied` 找到过才有,不读盘)。独立取回的封面载荷按它算曲目标识,
    /// 跟换过的快照对得上(`PlayerArtistFix.correctedTrackKey`)。
    public static func identity(bundleID: String?, rawArtist: String?, rawTitle: String?) -> PlayerTitleSplit.FileIdentity? {
        guard let bundleID, bundleIDs.contains(bundleID), let rawTitle else { return nil }
        return cache.withLock { $0[cacheKey(artist: rawArtist, title: rawTitle)]?.identity }
    }

    /// 播放器原样报的(歌手、歌名)对上的那个文件(`applied` 找到过才有,不读盘)。封面取不到系统那份时按它找同目录的图。
    public static func currentFilePath(bundleID: String?, rawArtist: String?, rawTitle: String?) -> String? {
        guard let bundleID, bundleIDs.contains(bundleID), let rawTitle else { return nil }
        return cache.withLock { $0[cacheKey(artist: rawArtist, title: rawTitle)]?.path }
    }

    /// 换过之后的这首(歌手、歌名)对上的那个文件(不读盘)。写给引擎的播放状态用(`local_file`)。
    public static func currentFilePath(bundleID: String?, artist: String, title: String) -> String? {
        guard let bundleID, bundleIDs.contains(bundleID), !title.isEmpty else { return nil }
        return cache.withLock { entries in
            entries.first { key, entry in
                guard entry.path != nil else { return false }
                if let id = entry.identity { return id.artist == artist && id.title == title }
                return key == cacheKey(artist: artist, title: title)
            }?.value.path
        }
    }

    private static func lookUp(artist: String, title: String, duration: Double?,
                               pid: pid_t) -> (identity: PlayerTitleSplit.FileIdentity?, path: String)? {
        let candidates = ProcessOpenFiles.paths(pid: pid)
            .filter { PlayerTitleSplit.audioExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        guard !candidates.isEmpty else { return nil }
        for path in candidates {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            let tags = LocalAudioFileTags.read(path: path)
            guard fileMatches(reportedArtist: artist, reportedTitle: title, reportedDuration: duration, tags: tags,
                              fileName: fileName) else { continue }
            let found = tags.flatMap(PlayerTitleSplit.identity(from:))
                ?? fileNameIdentity(reportedArtist: artist, reportedTitle: title, fileName: fileName, duration: tags?.duration)
            logger.notice("player file: \(fileName, privacy: .public) matches the reported track, tags \(found == nil ? "absent" : "used", privacy: .public)")
            return (found, path)
        }
        logger.notice("player file: none of \(candidates.count) open audio files matches the reported track")
        return nil
    }
}
