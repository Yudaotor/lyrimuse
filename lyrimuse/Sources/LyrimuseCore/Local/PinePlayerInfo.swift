import Foundation
import os

/// Pine Player(DigiPine)系统 Now Playing 那份的曲目解读。它没有脚本字典,曲目和位置都只从系统那份来:曲目在这里按它开着的
/// 文件换,位置换成 `PinePlayhead` 那块表。
///
/// 系统那份的写法:
/// - 歌手一栏是「歌手∙专辑」(U+2219,两边不空格),专辑那栏空着;没有专辑时只有歌手。
/// - 写了歌名、没写歌手时,歌手一栏填的也是歌名。
/// - 没写标签时歌名是带扩展名的文件名,歌手一栏是一个空格。
/// - GBK / Big5 标签被当成 Latin-1 读出来的乱码,同 reAMP 那套还原(`PlayerTitleSplit.repairingCJKMojibake`)。
/// - 时长只到整秒。
///
/// 它开着的音频文件不止当前这首(放过的文件一直开着),按标签算出系统那份该是什么样(`systemFields`)逐个比,歌名和歌手一栏
/// 都对上的才是(`pickFile`),用文件里的歌名、歌手、专辑和精确时长;找不到时只按这一栏的写法拆(`identity(title:artist:)`)。
/// 两条路写出同一份歌名、歌手,歌词缓存是同一条。见 02 章决策 155。
public enum PinePlayerInfo {
    public static var bundleID: String { PlaybackPlayer.pinePlayer.bundleIdentifier }
    /// 系统那份里拼歌手和专辑用的字符。
    public static let systemArtistSeparator = "\u{2219}"

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "pine")

    // MARK: 按文件认

    /// 这个文件放起来时,系统那份会报的歌名和歌手一栏。没写歌名时歌手一栏不定,为 nil(只比歌名)。纯函数,selftest 覆盖。
    public static func systemFields(tags: LocalAudioFileTags, fileName: String) -> (title: String, artist: String?) {
        guard !tags.title.isEmpty else { return (fileName, tags.artist.isEmpty ? " " : nil) }
        if tags.artist.isEmpty { return (tags.title, tags.title) }
        if tags.album.isEmpty { return (tags.title, tags.artist) }
        return (tags.title, tags.artist + systemArtistSeparator + tags.album)
    }

    /// 系统那份报的歌名、歌手一栏是不是这个文件的:跟 `systemFields` 逐字比(两边都可能是乱码,原样比不上再各自还原了比),
    /// 歌手一栏去掉首尾空白。纯函数,selftest 覆盖。
    public static func fileMatches(title: String, artist: String, tags: LocalAudioFileTags, fileName: String) -> Bool {
        let expected = systemFields(tags: tags, fileName: fileName)
        guard sameText(title, expected.title) else { return false }
        guard let expectedArtist = expected.artist else { return true }
        return sameText(artist.trimmingCharacters(in: .whitespaces), expectedArtist.trimmingCharacters(in: .whitespaces))
    }

    private static func sameText(_ a: String, _ b: String) -> Bool {
        a == b || PlayerTitleSplit.repairingCJKMojibake(a) == PlayerTitleSplit.repairingCJKMojibake(b)
    }

    /// 开着的文件里是哪一个:歌名和歌手一栏都对上的第一个;没有的话,只有歌名对上的恰好一个就是它。纯函数,selftest 覆盖。
    public static func pickFile(title: String, artist: String,
                                candidates: [(fileName: String, tags: LocalAudioFileTags)]) -> Int? {
        if let i = candidates.firstIndex(where: { fileMatches(title: title, artist: artist, tags: $0.tags, fileName: $0.fileName) }) {
            return i
        }
        let titled = candidates.indices.filter { sameText(title, systemFields(tags: candidates[$0].tags, fileName: candidates[$0].fileName).title) }
        return titled.count == 1 ? titled[0] : nil
    }

    /// 文件标签换成快照用的歌名、歌手、专辑:还原乱码(三个一起判);没写歌名的按文件名去掉扩展名,有「 - 」按第一个拆。纯函数,selftest 覆盖。
    public static func identity(tags: LocalAudioFileTags, fileName: String) -> (title: String, artist: String, album: String) {
        guard !tags.title.isEmpty else {
            let named = namedByFile(fileName)
            return (named.title, named.artist, "")
        }
        let fixed = PlayerTitleSplit.repairingCJKMojibake([tags.artist, tags.title, tags.album])
        return (fixed[1], fixed[0], fixed[2])
    }

    /// 找不到文件时只按系统那份拆:没写标签的(歌手一栏是空白、歌名带音频扩展名)按文件名拆;歌手一栏跟歌名一样的是没写歌手;
    /// 有「∙」按最后一个拆成歌手和专辑。拆完再还原乱码。纯函数,selftest 覆盖。
    public static func identity(title: String, artist: String) -> (title: String, artist: String, album: String) {
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, PlayerTitleSplit.strippingAudioExtension(title) != title {
            let named = namedByFile(PlayerTitleSplit.repairingCJKMojibake(title))
            return (named.title, named.artist, "")
        }
        var outArtist = trimmed, album = ""
        if trimmed == title {
            outArtist = ""
        } else if let range = trimmed.range(of: systemArtistSeparator, options: .backwards) {
            let left = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { (outArtist, album) = (left, right) }
        }
        let fixed = PlayerTitleSplit.repairingCJKMojibake([outArtist, title, album])
        return (fixed[1], fixed[0], fixed[2])
    }

    /// 没写标签的文件名:去掉扩展名,有「 - 」按第一个拆成歌手、歌名(Pine 自己界面上也这样拆)。
    static func namedByFile(_ fileName: String) -> (title: String, artist: String) {
        let base = PlayerTitleSplit.strippingAudioExtension(fileName)
        if let dash = base.range(of: " - ") {
            let left = base[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = base[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { return (right, left) }
        }
        return (base, "")
    }

    // MARK: 快照

    /// 最近一次换好的那首:换过之后的歌名、歌手、专辑,系统原样报的歌名和歌手一栏,和它的文件(没找到为 nil)。
    private static let current = OSAllocatedUnfairLock<(title: String, artist: String, album: String,
                                                         rawTitle: String, rawArtist: String, path: String?)?>(initialState: nil)

    /// 系统那份的快照换成这一首:先按开着的文件认(`systemFile`),认不出只拆歌手一栏。不是 Pine 的原样返回。会读盘(同一首只找
    /// 一次),在轮询的后台线程上调。
    public static func adapted(_ snapshot: MediaControlSnapshot?, now: Date = Date()) -> MediaControlSnapshot? {
        guard let snapshot, snapshot.bundleIdentifier == bundleID, let title = snapshot.title, !title.isEmpty else { return snapshot }
        let artist = snapshot.artist ?? ""
        let file = systemFile(title: title, artist: artist, pid: snapshot.processIdentifier.map { pid_t($0) }, now: now)
        let id = file.map { identity(tags: $0.tags, fileName: URL(fileURLWithPath: $0.path).lastPathComponent) }
            ?? identity(title: title, artist: artist)
        var out = snapshot.withTitle(id.title).withArtist(id.artist).withAlbum(id.album)
        out.processIdentifier = snapshot.processIdentifier
        if let duration = VoxPlayerInfo.preciseDuration(reported: snapshot.duration, file: file?.tags.duration) {
            out = out.withDuration(duration)
        }
        current.withLock { $0 = (id.title, id.artist, id.album, title, artist, file?.path) }
        return out
    }

    /// 换过之后的这首(歌手、歌名)对上最近一次换好的那首时,它的文件(不读盘)。写播放状态(`local_file`)用。
    public static func currentFilePath(artist: String, title: String) -> String? {
        current.withLock { entry in
            guard let entry, !title.isEmpty, entry.title == title, entry.artist == artist else { return nil }
            return entry.path
        }
    }

    /// 取封面那份载荷报的歌名、歌手一栏 → 跟快照同一份歌名、歌手(曲目标识才对得上),连同这一首的文件(系统没带图时按它找
    /// 同目录的图)。是最近换好的那首就用它的,否则只拆这一栏、没有文件。不读盘。
    public static func artworkIdentity(title: String?, artist: String?) -> (title: String?, artist: String?, path: String?) {
        guard let title else { return (nil, artist, nil) }
        if let entry = current.withLock({ $0 }), entry.rawTitle == title, entry.rawArtist == (artist ?? "") {
            return (entry.title, entry.artist, entry.path)
        }
        let id = identity(title: title, artist: artist ?? "")
        return (id.title, id.artist, nil)
    }

    /// 开着的音频文件里对得上这一首的那个(`pickFile`)。按歌名和歌手一栏记,找到了就不再找;没找到的隔 `fileRetry` 再找
    /// (换歌那一拍可能还没打开新文件)。没有进程号(切歌空档交回的旧快照)时只查记下的。`SourceKnockout` 关掉了这条时返回 nil。
    static func systemFile(title: String, artist: String, pid: pid_t?, now: Date) -> (path: String, tags: LocalAudioFileTags)? {
        guard !SourceKnockout.isOut(.pineFile) else { return nil }
        let key = title + "\u{1F}" + artist
        let hit = files.withLock { $0[key] }
        if let hit, hit.found != nil || now.timeIntervalSince(hit.checkedAt) < fileRetry { return hit.found }
        guard let pid else { return hit?.found }
        var seen = Set<String>()
        let candidates: [(path: String, tags: LocalAudioFileTags)] = ProcessOpenFiles.paths(pid: pid)
            .filter { PlayerTitleSplit.audioExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .filter { seen.insert($0).inserted }
            .compactMap { path in LocalAudioFileTags.read(path: path).map { (path, $0) } }
        let picked = pickFile(title: title, artist: artist, candidates: candidates.map {
            (fileName: URL(fileURLWithPath: $0.path).lastPathComponent, tags: $0.tags)
        })
        let found = picked.map { candidates[$0] }
        files.withLock { entries in
            if entries.count > 32 { entries.removeAll() }
            entries[key] = (found, now)
        }
        logger.notice("pine: \(found == nil ? "none" : "one", privacy: .public) of \(candidates.count, privacy: .public) open audio files matches the system title")
        return found
    }

    static let fileRetry: TimeInterval = 3
    private static let files = OSAllocatedUnfairLock<[String: (found: (path: String, tags: LocalAudioFileTags)?, checkedAt: Date)]>(
        initialState: [:])
}
