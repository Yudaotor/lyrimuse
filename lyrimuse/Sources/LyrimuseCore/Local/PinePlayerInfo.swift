import Foundation
import os

/// Pine Player(DigiPine)系统 Now Playing 那份的曲目解读。它没有脚本字典,曲目和位置都只从系统那份来:曲目在这里按它开着的
/// 文件换,位置换成 `PinePlayhead` 那块表。
///
/// 系统那份的写法:
/// - 歌手一栏是「歌手∙专辑」(U+2219,两边不空格),专辑那栏空着;没有专辑时只有歌手。
/// - 写了歌名、没写歌手时,歌手一栏填的也是歌名。
/// - 没写标签时,刚加进它的列表那几遍歌名是带扩展名的文件名、歌手一栏是一个空格;它在后台解析过文件名之后(放到中途就会换)
///   改报不带扩展名的文件名、歌手一栏是「 - 」前面那段,跟它界面上一样。两种写法都认成同一首。
/// - GBK / Big5 标签被当成 Latin-1 读出来的乱码,同 reAMP 那套还原(`PlayerTitleSplit.repairingCJKMojibake`)。
/// - 时长只到整秒。
///
/// 它开着的音频文件不止当前这首(放过的文件一直开着),按标签算出系统那份该是什么样(`systemFields`)逐个比,歌名和歌手一栏
/// 都对上的才是(`pickFile`;几个都对得上时取最后打开的那个),用文件里的歌名、歌手、专辑和精确时长;找不到时只按这一栏的写法拆
/// (`identity(title:artist:)`)。
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
    /// 歌手一栏去掉首尾空白;没写标签的文件另认它解析过文件名之后那种写法(`parsedUntaggedMatches`)。纯函数,selftest 覆盖。
    public static func fileMatches(title: String, artist: String, tags: LocalAudioFileTags, fileName: String) -> Bool {
        if tags.title.isEmpty, parsedUntaggedMatches(title: title, artist: artist, fileName: fileName) { return true }
        let expected = systemFields(tags: tags, fileName: fileName)
        guard sameText(title, expected.title) else { return false }
        guard let expectedArtist = expected.artist else { return true }
        return sameText(artist.trimmingCharacters(in: .whitespaces), expectedArtist.trimmingCharacters(in: .whitespaces))
    }

    /// 没写标签的文件、它解析过文件名之后的写法:歌名是不带扩展名的文件名,歌手一栏是「 - 」前面那段(文件名里没有「 - 」时
    /// 空着或者也是歌名)。
    static func parsedUntaggedMatches(title: String, artist: String, fileName: String) -> Bool {
        let base = PlayerTitleSplit.strippingAudioExtension(fileName)
        guard base != fileName, title == base else { return false }
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        let named = namedByFile(fileName)
        return trimmed == named.artist || trimmed.isEmpty || trimmed == base
    }

    private static func sameText(_ a: String, _ b: String) -> Bool {
        a == b || PlayerTitleSplit.repairingCJKMojibake(a) == PlayerTitleSplit.repairingCJKMojibake(b)
    }

    /// 开着的文件里是哪一个:歌名和歌手一栏都对上的最后一个(候选按文件描述符排,它放过的文件不关,新打开的排在最后:同一首放在
    /// 两个目录里时,后打开的才是在放的);没有的话,只有歌名对上的恰好一个就是它。纯函数,selftest 覆盖。
    public static func pickFile(title: String, artist: String,
                                candidates: [(fileName: String, tags: LocalAudioFileTags)]) -> Int? {
        if let i = candidates.lastIndex(where: { fileMatches(title: title, artist: artist, tags: $0.tags, fileName: $0.fileName) }) {
            return i
        }
        let titled = candidates.indices.filter {
            sameText(title, systemFields(tags: candidates[$0].tags, fileName: candidates[$0].fileName).title)
                || (candidates[$0].tags.title.isEmpty && title == PlayerTitleSplit.strippingAudioExtension(candidates[$0].fileName))
        }
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

    /// 找不到文件时只按系统那份拆:没写标签的(歌手一栏是空白、歌名带音频扩展名)按文件名拆;歌名以「歌手一栏 + 「 - 」」开头的是
    /// 它解析过文件名的没写标签的文件,去掉这段;歌手一栏跟歌名一样的是没写歌手;有「∙」按最后一个拆成歌手和专辑。拆完再还原乱码。
    /// 纯函数,selftest 覆盖。
    public static func identity(title: String, artist: String) -> (title: String, artist: String, album: String) {
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, PlayerTitleSplit.strippingAudioExtension(title) != title {
            let named = namedByFile(PlayerTitleSplit.repairingCJKMojibake(title))
            return (named.title, named.artist, "")
        }
        var outArtist = trimmed, album = ""
        if !trimmed.isEmpty, title.hasPrefix(trimmed + " - "),
           !title.dropFirst(trimmed.count + 3).trimmingCharacters(in: .whitespaces).isEmpty {
            let rest = String(title.dropFirst(trimmed.count + 3)).trimmingCharacters(in: .whitespaces)
            let fixed = PlayerTitleSplit.repairingCJKMojibake([trimmed, rest])
            return (fixed[1], fixed[0], "")
        }
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
        let id = file.flatMap { file in file.tags.map { identity(tags: $0, fileName: URL(fileURLWithPath: file.path).lastPathComponent) } }
            ?? identity(title: title, artist: artist)
        var out = snapshot.withTitle(id.title).withArtist(id.artist).withAlbum(id.album)
        if let duration = VoxPlayerInfo.preciseDuration(reported: snapshot.duration, file: file?.tags?.duration) {
            out = out.withDuration(duration)
        }
        // `with…` 副本不带这几样;解码那一拍(`PinePlayhead`)设好的在加载、补查时刻、精确读数要原样带过来。
        out.processIdentifier = snapshot.processIdentifier
        out.isWaitingToPlay = snapshot.isWaitingToPlay
        out.republishDueBy = snapshot.republishDueBy
        out.positionIsPrecise = snapshot.positionIsPrecise
        out.isMusicVideo = snapshot.isMusicVideo
        current.withLock { $0 = (id.title, id.artist, id.album, title, artist, file?.path) }
        return out
    }

    /// 网络电台(`radioShaped`,开着的文件里也找不到它:流走的是网络连接):Pine 不读流里的 ICY 标题,歌名只是地址最后一段,
    /// 这一拍算不是歌,不拿去搜歌词。形状对上时才列开着的文件(同一首只找一次)。
    static func isNetworkRadio(_ snapshot: MediaControlSnapshot, now: Date = Date()) -> Bool {
        guard radioShaped(bundleID: snapshot.bundleIdentifier, title: snapshot.title, artist: snapshot.artist,
                          duration: snapshot.duration), let title = snapshot.title else { return false }
        return systemFile(title: title, artist: snapshot.artist ?? "", pid: snapshot.processIdentifier.map { pid_t($0) }, now: now) == nil
    }

    /// 系统那份像网络电台:Pine、歌名不空、歌手一栏空(没写标签那种写法)、没有时长(它给网络流报 Int64 最大值那么长,
    /// 过 `MediaControlSnapshot.endlessDurationSecs` 的也算)。本地文件都报真实时长。纯函数,selftest 覆盖。
    public static func radioShaped(bundleID: String?, title: String?, artist: String?, duration: Double?) -> Bool {
        let endless = PlayerTitleSplit.isStream(duration: duration) || (duration ?? 0) >= MediaControlSnapshot.endlessDurationSecs
        guard bundleID == self.bundleID, let title, !title.isEmpty, endless else { return false }
        return (artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty
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

    /// 开着的音频文件里对得上这一首的那个(`pickOpenFile`;读不出标签的那个没有标签,曲目只拆系统那份)。只记当前这一首(歌名、歌手一栏和第几次开播):同一首换了个文件再放
    /// 要重新挑。找到了这一首放着就不再找;没找到的隔 `fileRetry` 再找(换歌那一拍可能还没打开新文件)。
    /// 没有进程号(切歌空档交回的旧快照)时只查记下的。`SourceKnockout` 关掉了这条时返回 nil。
    static func systemFile(title: String, artist: String, pid: pid_t?, now: Date) -> (path: String, tags: LocalAudioFileTags?)? {
        guard !SourceKnockout.isOut(.pineFile) else { return nil }
        let key = title + "\u{1F}" + artist + "\u{1F}" + String(PinePlayhead.startCount)
        let hit = files.withLock { $0?.key == key ? $0 : nil }
        if let hit, hit.found != nil || now.timeIntervalSince(hit.checkedAt) < fileRetry { return hit.found }
        guard let pid else { return hit?.found }
        let opened = keepingLastOccurrence(ProcessOpenFiles.paths(pid: pid)
            .filter { openFileExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) })
            .map { (path: $0, tags: LocalAudioFileTags.read(path: $0)) }
        let found = pickOpenFile(title: title, artist: artist, files: opened.map {
            (fileName: URL(fileURLWithPath: $0.path).lastPathComponent, tags: $0.tags)
        }).map { opened[$0] }
        files.withLock { $0 = (key, found, now) }
        let outcome = found.map { $0.tags == nil ? "one unreadable" : "one" } ?? "none"
        logger.notice("pine: \(outcome, privacy: .public) of \(opened.count, privacy: .public) open audio files matches the system title")
        return found
    }

    /// 开着的文件(按打开先后排)里是哪一个:读得出标签的按 `pickFile`,读不出的按 `unreadableMatch`,两边都有就取后打开的那个
    /// (同一首另有一份读得出标签的旧文件开着时,新打开的读不出标签的才是在放的)。纯函数,selftest 覆盖。
    public static func pickOpenFile(title: String, artist: String, files: [(fileName: String, tags: LocalAudioFileTags?)]) -> Int? {
        let tagged = files.indices.compactMap { i in files[i].tags.map { (index: i, fileName: files[i].fileName, tags: $0) } }
        let picked = pickFile(title: title, artist: artist, candidates: tagged.map { (fileName: $0.fileName, tags: $0.tags) })
            .map { tagged[$0].index }
        let unreadable = files.indices.filter { files[$0].tags == nil }
        let fallback = unreadableMatch(title: title, fileNames: unreadable.map { files[$0].fileName }).map { unreadable[$0] }
        return [picked, fallback].compactMap { $0 }.max()
    }

    /// 读不出标签的文件里是哪一个:文件名(去掉扩展名)含这个歌名的最后一个(新打开的排在最后)。纯函数,selftest 覆盖。
    public static func unreadableMatch(title: String, fileNames: [String]) -> Int? {
        let wanted = PlayerTitleSplit.strippingAudioExtension(title).trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        return fileNames.lastIndex { name in
            name.range(of: wanted, options: .caseInsensitive) != nil
        }
    }

    /// 开着的文件按扩展名筛:通用那张表加上 Pine 能放、那张表里没有的几种。
    public static let openFileExtensions = PlayerTitleSplit.audioExtensions.union(["aifc", "amr", "bwf", "caf", "dts", "ac3", "m4r", "mka", "w64"])

    static let fileRetry: TimeInterval = 3
    private static let files = OSAllocatedUnfairLock<(key: String, found: (path: String, tags: LocalAudioFileTags?)?, checkedAt: Date)?>(
        initialState: nil)

    /// 去掉重复的路径,每个留最后出现的那次(同一个文件开过两次时,后开的那个描述符才代表它最近一次被打开),顺序照旧。纯函数,selftest 覆盖。
    public static func keepingLastOccurrence(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.reversed().filter { seen.insert($0).inserted }.reversed()
    }
}
