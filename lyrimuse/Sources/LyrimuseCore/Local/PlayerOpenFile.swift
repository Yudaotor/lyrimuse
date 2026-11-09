import Foundation
import os

/// QQ 音乐、网易云、酷狗用「打开文件」、Spotify 从它的「本地文件」列表放本机的音频文件时,以及 foobar2000、Swinsian(只放本机文件,
/// 只开着正在放的那一个;它们自己报的标签已经齐全,这里主要为了拿到路径)、MyGo Music 放本机文件时,按快照里的进程号找到它开着的
/// 那个文件(`ProcessOpenFiles`;快照没带进程号时按 bundle id 找主进程,Spotify 的快照来自脚本、不带):
/// 路径写进播放状态(`local_file`,引擎读同名 .lrc 和文件里的歌词)、没报封面时用同目录的图;标签里有歌名时换成标签里的
/// 歌手、歌名、专辑和精确时长(网易云把带扩展名的文件名报成歌名,酷狗不读标签、按文件名拆歌手歌名)。
/// 在线播放时它们开着的是自己的缓存(网易云 `.uc!`、Spotify 没有扩展名的缓存文件),不在 `PlayerTitleSplit.audioExtensions`
/// 里,不会认成本机文件;MyGo 插件音源的缓存是带完整标签的 .mp3,按目录排除(`isPlayerCache`)。见 02 章决策 188、196、206、241、248。
public enum PlayerOpenFile {
    public static let bundleIDs: Set<String> = [
        PlaybackPlayer.qqMusic.bundleIdentifier, PlaybackPlayer.netease.bundleIdentifier,
        PlaybackPlayer.kugou.bundleIdentifier, PlaybackPlayer.spotify.bundleIdentifier,
        PlaybackPlayer.foobar2000.bundleIdentifier, PlaybackPlayer.swinsian.bundleIdentifier,
        PlaybackPlayer.mygoMusic.bundleIdentifier,
    ]

    /// 没写歌名的文件报成不带扩展名的文件名的播放器(`fileNameIdentity` 的 `acceptsBaseName`)。
    static let baseNameBundleIDs: Set<String> = [
        PlaybackPlayer.foobar2000.bundleIdentifier, PlaybackPlayer.swinsian.bundleIdentifier,
        PlaybackPlayer.mygoMusic.bundleIdentifier,
    ]

    /// 播放器放在线音源时开着的缓存文件:MyGo 插件音源下到 `~/Library/Caches/MyGo Music/songs/`,文件带完整标签、按标签对得上,
    /// 不算本机文件(不交引擎读 .lrc、不拿正在下的文件估时长)。纯函数,selftest 覆盖。
    public static func isPlayerCache(_ path: String) -> Bool {
        path.contains("/Library/Caches/MyGo Music/")
    }

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "player-file")

    /// 播放器报的这一首是不是这个文件。三种报法都认:标签里的歌名(QQ;报了歌手时还得跟标签一致)、带或不带扩展名的
    /// 文件名(网易云)、文件名在第一个 `-` 处拆开去掉空白的歌手和歌名(酷狗)。两边连续空白压成一个比;两边都有时长时差
    /// 1.5 秒以内。`underscoresControls`:标签先照 `underscoringControls` 换过再比(foobar2000)。纯函数,selftest 覆盖。
    public static func fileMatches(reportedArtist: String, reportedTitle: String, reportedDuration: Double?,
                                   tags: LocalAudioFileTags?, fileName: String, underscoresControls: Bool = false) -> Bool {
        if let reportedDuration, let duration = tags?.duration, abs(duration - reportedDuration) > 1.5 { return false }
        let title = PlayerTitleSplit.collapsedWhitespace(reportedTitle)
        let artist = PlayerTitleSplit.collapsedWhitespace(reportedArtist)
        guard !title.isEmpty else { return false }
        func shown(_ tag: String) -> String {
            PlayerTitleSplit.collapsedWhitespace(underscoresControls ? underscoringControls(tag) : tag)
        }
        if let tags, !tags.title.isEmpty, shown(tags.title) == title, artist.isEmpty || shown(tags.artist) == artist { return true }
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

    /// foobar2000 报标签时每个控制字符(换行、回车、制表符)各换成一个 `_`(`\r\n` 是两个),见 02 章决策 210。纯函数,selftest 覆盖。
    public static func underscoringControls(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { out.append(scalar.value < 0x20 ? "_" : scalar) }
        return String(out)
    }

    /// 没写歌名的文件、播放器把带扩展名的文件名报成歌名时(网易云;`acceptsBaseName` 时不带扩展名的也认,foobar2000):
    /// 去掉扩展名和音轨号,按第一个 ` - ` 拆成歌手和歌名(播放器报了歌手就用它报的)。别的报法原样留着,返回 nil。纯函数,selftest 覆盖。
    public static func fileNameIdentity(reportedArtist: String, reportedTitle: String, fileName: String,
                                        duration: Double?, acceptsBaseName: Bool = false) -> PlayerTitleSplit.FileIdentity? {
        let base = PlayerTitleSplit.strippingAudioExtension(fileName)
        let reported = PlayerTitleSplit.collapsedWhitespace(reportedTitle)
        guard base != fileName,
              reported == PlayerTitleSplit.collapsedWhitespace(fileName)
                || (acceptsBaseName && reported == PlayerTitleSplit.collapsedWhitespace(base)) else { return nil }
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

    /// MyGo 上一拍报的那一首(缓存键);换了就重找。
    private static let lastMyGoKey = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// 换到快照上:对上了开着的文件、标签里有歌名就换成标签那份;都不用换时原样返回。会读盘(同一首只读一次),在轮询的后台线程上调。
    public static func applied(to snapshot: MediaControlSnapshot?, now: Date = Date()) -> MediaControlSnapshot? {
        guard let snapshot, !SourceKnockout.isOut(.playerFile), let bundleID = snapshot.bundleIdentifier, bundleIDs.contains(bundleID),
              let title = snapshot.title, !title.isEmpty,
              let file = fileIdentity(artist: snapshot.artist, title: title, duration: snapshot.duration,
                                      pid: snapshot.processIdentifier ?? PlayerProcess.pid(bundleID: bundleID).map { Int($0) },
                                      foobar: bundleID == PlaybackPlayer.foobar2000.bundleIdentifier,
                                      baseName: baseNameBundleIDs.contains(bundleID),
                                      mygo: bundleID == PlaybackPlayer.mygoMusic.bundleIdentifier, now: now) else { return snapshot }
        var out = snapshot.withTitle(file.title)
        if !file.artist.isEmpty { out = out.withArtist(file.artist) }
        if !file.album.isEmpty { out = out.withAlbum(file.album) }
        if let duration = file.duration { out = out.withDuration(duration) }
        out.republishDueBy = snapshot.republishDueBy
        return out
    }

    /// `pid` 只在要读盘时才取(缓存命中时不找进程)。`foobar`:标签里的控制字符按 `_` 比;`baseName`:不带扩展名的文件名也拆。
    /// `mygo`:MyGo 放过的本机文件一直开着,插件音源放同名同歌手的歌时按(歌手、歌名)记的那份会认错:每换一首重找一次,
    /// 缓存目录里开着的文件对得上这一首就是插件音源、不算本机文件(`matchingOpenFile`)。见 02 章决策 251。
    static func fileIdentity(artist: String?, title: String, duration: Double?, pid: @autoclosure () -> Int?,
                             foobar: Bool = false, baseName: Bool = false, mygo: Bool = false,
                             now: Date = Date()) -> PlayerTitleSplit.FileIdentity? {
        let key = cacheKey(artist: artist, title: title)
        let newTrack = mygo && lastMyGoKey.withLock { last in
            defer { last = key }
            return last != key
        }
        if !newTrack, let hit = cache.withLock({ $0[key] }),
           !PlayerTitleSplit.shouldLookUpFile(found: hit.path != nil, attempts: hit.attempts,
                                              sinceChecked: now.timeIntervalSince(hit.checkedAt)) {
            return hit.identity
        }
        guard let pid = pid(), pid > 0 else { return nil }
        let found = lookUp(artist: artist ?? "", title: title, duration: duration, pid: pid_t(pid), foobar: foobar,
                           baseName: baseName, skipsWhenCacheMatches: mygo)
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
        guard !SourceKnockout.isOut(.playerFile), let bundleID, bundleIDs.contains(bundleID), let rawTitle else { return nil }
        return cache.withLock { $0[cacheKey(artist: rawArtist, title: rawTitle)]?.path }
    }

    /// 换过之后的这首(歌手、歌名)对上的那个文件(不读盘)。写给引擎的播放状态用(`local_file`)。
    public static func currentFilePath(bundleID: String?, artist: String, title: String) -> String? {
        guard !SourceKnockout.isOut(.playerFile), let bundleID, bundleIDs.contains(bundleID), !title.isEmpty else { return nil }
        return cache.withLock { entries in
            entries.first { key, entry in
                guard entry.path != nil else { return false }
                if let id = entry.identity { return id.artist == artist && id.title == title }
                return key == cacheKey(artist: artist, title: title)
            }?.value.path
        }
    }

    /// 当场按播放器开着的文件再核一次:报的这一首此刻对上的就是 `path`(缓存目录里没有对得上的)。改播放器里的数据之前用,
    /// 不信按(歌手、歌名)记下的那份。会读盘,不要在主线程调用。
    public static func confirmsCurrentFile(bundleID: String, path: String, artist: String, title: String) -> Bool {
        guard let pid = PlayerProcess.pid(bundleID: bundleID) else { return false }
        let audio = ProcessOpenFiles.paths(pid: pid)
            .filter { PlayerTitleSplit.audioExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        let match = matchingOpenFile(paths: audio, artist: artist, title: title, duration: nil,
                                     foobar: bundleID == PlaybackPlayer.foobar2000.bundleIdentifier,
                                     baseName: baseNameBundleIDs.contains(bundleID), skipsWhenCacheMatches: true,
                                     tags: { LocalAudioFileTags.read(path: $0) })
        if case .file(_, let found) = match { return found == path }
        return false
    }

    private static func lookUp(artist: String, title: String, duration: Double?, pid: pid_t, foobar: Bool, baseName: Bool,
                               skipsWhenCacheMatches: Bool) -> (identity: PlayerTitleSplit.FileIdentity?, path: String)? {
        let audio = ProcessOpenFiles.paths(pid: pid)
            .filter { PlayerTitleSplit.audioExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        let match = matchingOpenFile(paths: audio, artist: artist, title: title, duration: duration, foobar: foobar,
                                     baseName: baseName, skipsWhenCacheMatches: skipsWhenCacheMatches,
                                     tags: { LocalAudioFileTags.read(path: $0) })
        switch match {
        case .file(let identity, let path):
            logger.notice("player file: \(URL(fileURLWithPath: path).lastPathComponent, privacy: .public) matches the reported track, tags \(identity == nil ? "absent" : "used", privacy: .public)")
            return (identity, path)
        case .playerCache:
            logger.notice("player file: an open player cache file matches the reported track, not a local file")
            return nil
        case .none:
            if audio.contains(where: { !isPlayerCache($0) }) {
                logger.notice("player file: none of the open audio files matches the reported track")
            }
            return nil
        }
    }

    public enum OpenFileMatch: Equatable {
        case file(identity: PlayerTitleSplit.FileIdentity?, path: String)
        /// 播放器缓存目录里开着的文件对得上这一首:在放的是在线音源。
        case playerCache
        case none
    }

    /// 播放器开着的音频文件里哪个是报的这一首。缓存目录里的不算本机文件;`skipsWhenCacheMatches` 时缓存目录里有对得上的,
    /// 就是在放那一份(MyGo 放过的本机文件一直开着,同名同歌手的本机文件不算)。`tags` 读一个文件的标签。纯函数,selftest 覆盖。
    public static func matchingOpenFile(paths: [String], artist: String, title: String, duration: Double?, foobar: Bool,
                                        baseName: Bool, skipsWhenCacheMatches: Bool,
                                        tags: (String) -> LocalAudioFileTags?) -> OpenFileMatch {
        func matches(_ path: String, _ fileTags: LocalAudioFileTags?) -> Bool {
            fileMatches(reportedArtist: artist, reportedTitle: title, reportedDuration: duration, tags: fileTags,
                        fileName: URL(fileURLWithPath: path).lastPathComponent, underscoresControls: foobar)
        }
        if skipsWhenCacheMatches, paths.contains(where: { isPlayerCache($0) && matches($0, tags($0)) }) { return .playerCache }
        for path in paths where !isPlayerCache(path) {
            let fileTags = tags(path)
            guard matches(path, fileTags) else { continue }
            let found = fileTags.flatMap(PlayerTitleSplit.identity(from:))
                ?? fileNameIdentity(reportedArtist: artist, reportedTitle: title,
                                    fileName: URL(fileURLWithPath: path).lastPathComponent, duration: fileTags?.duration,
                                    acceptsBaseName: baseName)
            return .file(identity: found, path: path)
        }
        return .none
    }
}
