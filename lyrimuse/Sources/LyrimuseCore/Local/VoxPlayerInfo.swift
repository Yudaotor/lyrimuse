import Foundation
import os

/// VOX(Coppertino)的 AppleScript 读数。VOX 这条路上曲目与位置的主来源:media-control 认出在放的是它之后,
/// `MediaControlClient.adaptedSnapshot` 整份换成这一份;焦点被别的 App 占走时 `snapshotAfterFocusLost` 也问它。
/// 脚本读不到时退回系统那份(`systemFallback`:按它开着的文件认曲目、`systemAnchor` 补锚点),封面另有脚本那张
/// (`scriptArtwork`),每样数据断了一条另一条接着,见 16 章「来源冗余与拔腿测试」。
///
/// 系统 Now Playing 里 VOX 那份字段不全:歌手和专辑拼成一栏「歌手 — 专辑」(没有专辑时只有歌手)、专辑那栏空着,
/// 播放中不报位置和时长,只在暂停时报一次;恢复时报在放、速率却是 0。脚本接口则分开给歌手、专辑,位置跟真实出声差几毫秒
/// (点播开头、自动连播、暂停恢复、跳转都量过)。总时长只到整秒,另按当前文件(`trackurl`)读精确时长。
///
/// 几处读数的写法:
/// - 没写标签的文件,歌名报成全小写、带扩展名的文件名,歌手是空的:按文件名原样的大小写去掉扩展名,有「 - 」就拆成歌手、歌名
///   (`identity`)。
/// - GBK / Big5 标签被当成 Latin-1 读出来的乱码,两份读数都是,同 reAMP 那套还原(`PlayerTitleSplit.repairingCJKMojibake`)。
/// - 换歌那一拍读数会撕裂:歌名已经是新歌,位置还是上一首接着走的值,约 0.4 秒后才归零(`positionLagsTrackChange`)。
/// - 停住(列表放完)时 `player state` 是 -1、曲目全空,当没在放。
/// - 列表最后一首上按「下一首」,VOX 自己会卡住二三十秒,这期间脚本调用也卡住,靠调用超时兜。
///
/// 见 02 章决策 152。
public enum VoxPlayerInfo {
    public static var bundleID: String { PlaybackPlayer.vox.bundleIdentifier }
    /// VOX 开播、换歌时发的分布式通知(二进制里另有 `stateChanged`,实测从来不发)。
    public static let trackChangedNotification = "com.coppertino.Vox.trackChanged"

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "vox")

    /// JXA 快照脚本:没在跑、停住时回 `null`,不会把它拉起来。位置放在最后读,读数时刻按调用返回那一刻记。
    /// 字典里的 `trackUrl` 在 JXA 里叫 `trackurl`(写成 `trackUrl` 报 -1708);`player volume` 实际是 0~100。
    public static let script = """
    (() => {
        const V = Application("VOX");
        try {
            if (!V.running()) return JSON.stringify(null);
        } catch (e) {
            return JSON.stringify(null);
        }
        try {
            const state = V.playerState();
            if (state !== 0 && state !== 1) return JSON.stringify(null);
            const title = V.track();
            if (!title) return JSON.stringify(null);
            const reading = {
                title: title,
                artist: V.artist() || "",
                album: V.album() || "",
                duration: V.totalTime(),
                playing: state === 1,
                playbackRate: state === 1 ? 1 : 0,
                isMusicApp: true,
                bundleIdentifier: "com.coppertino.Vox",
                fileURL: V.trackurl() || "",
                uniqueID: V.uniqueID() || ""
            };
            reading.elapsedTime = V.currentTime();
            return JSON.stringify(reading);
        } catch (e) {
            return JSON.stringify(null);
        }
    })()
    """

    /// 快照之外的那两样:当前文件的地址和 VOX 资料库里这一首的标识。
    struct Extras: Decodable {
        let fileURL: String?
        let uniqueID: String?
    }

    /// 解出来的一次读数。
    public struct Reading: Sendable {
        public var snapshot: MediaControlSnapshot
        /// 当前文件的路径;不是本地文件(读不出 `file:` 地址)为 nil。
        public var filePath: String?
        /// 这一首在 VOX 资料库里的标识(`unique ID`),换歌认得出来;读不到为空串。
        public var uniqueID: String
    }

    /// 脚本输出 → 读数;`null`、解不开为 nil。身份与时长在这里换好(`identity`、`fileDuration`)。会读盘(同一个文件只读一次)。
    public static func reading(fromScriptOutput data: Data, capturedAt: Date,
                        fileDuration: (String) -> Double? = cachedFileDuration) -> Reading? {
        guard let raw = try? JSONDecoder().decode(MediaControlSnapshot.self, from: data),
              let extras = try? JSONDecoder().decode(Extras.self, from: data)
        else { return nil }
        let path = filePath(fromTrackURL: extras.fileURL)
        let id = identity(title: raw.title ?? "", artist: raw.artist ?? "", album: raw.album ?? "", filePath: path)
        var snapshot = raw.withTitle(id.title).withArtist(id.artist).withAlbum(id.album)
        if let duration = preciseDuration(reported: raw.duration, file: path.flatMap(fileDuration)) {
            snapshot = snapshot.withDuration(duration)
        }
        snapshot.capturedAt = capturedAt
        return Reading(snapshot: snapshot, filePath: path, uniqueID: extras.uniqueID ?? "")
    }

    /// `trackurl` 读出来的地址(`file:/Users/…`,百分号编码)→ 文件路径;不是本地文件为 nil。纯函数,selftest 覆盖。
    public static func filePath(fromTrackURL text: String?) -> String? {
        guard let text, !text.isEmpty, let url = URL(string: text), url.isFileURL, !url.path.isEmpty else { return nil }
        return url.path
    }

    /// 读数里的歌名、歌手、专辑换成快照用的:先还原乱码(三个字段一起判);没写标签的文件(歌手空、歌名就是文件名的全小写)
    /// 改用文件名原样的大小写、去掉扩展名,有「 - 」按第一个拆成歌手和歌名。纯函数,selftest 覆盖。
    public static func identity(title: String, artist: String, album: String,
                                filePath: String?) -> (title: String, artist: String, album: String) {
        let fixed = PlayerTitleSplit.repairingCJKMojibake([artist, title, album])
        var (outArtist, outTitle, outAlbum) = (fixed[0], fixed[1], fixed[2])
        if outArtist.trimmingCharacters(in: .whitespaces).isEmpty, let filePath {
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent
            if !fileName.isEmpty, title == fileName.lowercased() {
                let base = PlayerTitleSplit.strippingAudioExtension(fileName)
                outTitle = base
                outArtist = ""
                if let dash = base.range(of: " - ") {
                    let left = base[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
                    let right = base[dash.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !left.isEmpty, !right.isEmpty { (outArtist, outTitle) = (left, right) }
                }
                outAlbum = ""
            }
        }
        return (outTitle, outArtist, outAlbum)
    }

    /// 精确时长:脚本只报整秒(220.29 报成 220),文件读出来的跟它差不到 1.5 秒就用文件的;对不上(文件读错了、换了文件)
    /// 照用脚本的。纯函数,selftest 覆盖。
    public static func preciseDuration(reported: Double?, file: Double?) -> Double? {
        guard let file, file > 0 else { return nil }
        guard let reported, reported > 0 else { return file }
        return abs(file - reported) < 1.5 ? file : nil
    }

    private static let durations = OSAllocatedUnfairLock<[String: Double?]>(initialState: [:])

    /// 按路径记的文件时长,同一个文件只读一次。
    public static func cachedFileDuration(_ path: String) -> Double? {
        if let hit = durations.withLock({ $0[path] }) { return hit }
        let duration = LocalAudioFileTags.read(path: path)?.duration
        durations.withLock { entries in
            if entries.count > 64 { entries.removeAll() }
            entries[path] = duration
        }
        return duration
    }

    // MARK: 换歌那一拍的撕裂

    /// 上一次读数里跟撕裂判断有关的几样。
    public struct Mark: Equatable, Sendable {
        public var trackID: String
        public var elapsed: Double
        public var playing: Bool
        public var at: Date

        public init(trackID: String, elapsed: Double, playing: Bool, at: Date) {
            self.trackID = trackID
            self.elapsed = elapsed
            self.playing = playing
            self.at = at
        }
    }

    /// 换歌那一拍歌名已经是新歌、位置还是上一首接着走的值:曲目换了、上一次在放,这次位置不在开头,而且正好是上一次的位置
    /// 按墙钟走过来的(差 0.6 秒以内)。拖到别处、自动连播到开头的都不算。纯函数,selftest 覆盖。
    public static func positionLagsTrackChange(previous: Mark?, current: Mark) -> Bool {
        guard let previous, previous.playing, current.trackID != previous.trackID, current.elapsed > 0.5 else { return false }
        let carried = previous.elapsed + current.at.timeIntervalSince(previous.at)
        return abs(current.elapsed - carried) < 0.6
    }

    /// 撕裂时隔多久再读、最多读几次。实测撕裂那份 0.4 秒内换过来。
    static let settleDelay: TimeInterval = 0.25
    static let settleRereads = 3

    // MARK: 当前文件

    /// 最近一次读到的那首:换过之后的歌名、歌手,和它的文件。写播放状态(`local_file`)、取封面时找同目录的图用。
    private static let current = OSAllocatedUnfairLock<(title: String, artist: String, album: String, path: String?)?>(
        initialState: nil)

    /// 读到一次之后记下(撕裂判断也用上一次的)。
    private static let lastMark = OSAllocatedUnfairLock<Mark?>(initialState: nil)

    static func remember(_ reading: Reading) {
        let s = reading.snapshot
        current.withLock { $0 = (s.title ?? "", s.artist ?? "", s.album ?? "", reading.filePath) }
        lastMark.withLock {
            $0 = Mark(trackID: trackID(reading), elapsed: s.elapsedTime ?? 0, playing: s.playing == true,
                      at: s.capturedAt ?? Date())
        }
    }

    static func previousMark() -> Mark? { lastMark.withLock { $0 } }

    /// 最近一次读到的那首(脚本读数或 `systemFallback` 记下的)。
    static func currentEntry() -> (title: String, artist: String, album: String, path: String?)? {
        current.withLock { $0 }
    }

    public static func trackID(_ reading: Reading) -> String {
        reading.uniqueID.isEmpty ? (reading.filePath ?? reading.snapshot.trackKey) : reading.uniqueID
    }

    public static func mark(_ reading: Reading) -> Mark {
        let s = reading.snapshot
        return Mark(trackID: trackID(reading), elapsed: s.elapsedTime ?? 0, playing: s.playing == true,
                    at: s.capturedAt ?? Date())
    }

    /// 换过之后的这首(歌手、歌名)对上最近一次读数时,它的文件(不读盘)。
    public static func currentFilePath(artist: String, title: String) -> String? {
        current.withLock { entry in
            guard let entry, !title.isEmpty, entry.title == title, entry.artist == artist else { return nil }
            return entry.path
        }
    }

    // MARK: 系统那份会话

    /// 系统那份会话里的歌手一栏(「歌手 — 专辑」)拆回歌手和专辑。最近一次脚本读数是同一首、拼出来正好是这一栏时照它拆
    /// (歌手名本身带「 — 」也拆得对);对不上时按最后一个「 — 」拆,没有就原样当歌手。纯函数,selftest 覆盖。
    public static func splitSystemArtist(_ artist: String, title: String,
                                         known: (title: String, artist: String, album: String)?) -> (artist: String, album: String) {
        if let known, known.title == title {
            if !known.album.isEmpty, artist == known.artist + systemArtistSeparator + known.album {
                return (known.artist, known.album)
            }
            if artist == known.artist { return (artist, "") }
        }
        guard let range = artist.range(of: systemArtistSeparator, options: .backwards) else { return (artist, "") }
        let left = String(artist[..<range.lowerBound]), right = String(artist[range.upperBound...])
        guard !left.trimmingCharacters(in: .whitespaces).isEmpty, !right.trimmingCharacters(in: .whitespaces).isEmpty
        else { return (artist, "") }
        return (left, right)
    }

    /// VOX 在系统那份会话里拼歌手和专辑用的分隔(前后各一个空格的 em dash)。
    public static let systemArtistSeparator = " \u{2014} "

    /// 系统那份会话的锚点补成能外推的,脚本读不到时位置靠它:在放、没报位置、带着时刻的(开播、自然连播那一份,时刻就是
    /// 开播那一刻)当 0 秒;在放、速率 0 的(恢复那一份,位置和时刻都对)当速率 1,media-control 按速率 0 外推出来的那个
    /// 冻结值作废。暂停着的、别的播放器原样返回。纯函数,selftest 覆盖。
    public static func systemAnchor(bundleID: String?, playing: Bool?, elapsed: Double?, elapsedNow: Double?,
                                    rate: Double?, hasTimestamp: Bool)
        -> (elapsed: Double?, elapsedNow: Double?, rate: Double?) {
        guard bundleID == Self.bundleID, playing == true else { return (elapsed, elapsedNow, rate) }
        if elapsed == nil {
            return hasTimestamp ? (0, nil, rate == 0 ? 1 : rate) : (nil, elapsedNow, rate)
        }
        return rate == 0 ? (elapsed, nil, 1) : (elapsed, elapsedNow, rate)
    }

    /// 系统那份会话的快照换成拆好的歌手、专辑:不是 VOX、已经有专辑(脚本读数)的原样返回。
    public static func splittingSystemArtist(_ snapshot: MediaControlSnapshot?) -> MediaControlSnapshot? {
        guard let snapshot, snapshot.bundleIdentifier == bundleID, (snapshot.album ?? "").isEmpty,
              let artist = snapshot.artist, artist.contains(systemArtistSeparator) else { return snapshot }
        let known = current.withLock { $0.map { (title: $0.title, artist: $0.artist, album: $0.album) } }
        let split = splitSystemArtist(artist, title: snapshot.title ?? "", known: known)
        var out = snapshot.withArtist(split.artist)
        if !split.album.isEmpty { out = out.withAlbum(split.album) }
        return out
    }

    /// 取封面那份载荷(系统会话)报的歌名、歌手 → 跟快照同一份歌名、歌手(算出来的曲目标识才对得上),连同这一首的文件
    /// (系统没带图时按它找同目录的图)。系统报的歌名是最近一次读数那首的歌名、或者它文件名的全小写(没写标签)时,
    /// 用那次读数的;否则只拆歌手、没有文件。不读盘。
    public static func artworkIdentity(title: String?, artist: String?) -> (title: String?, artist: String?, path: String?) {
        let entry = current.withLock { $0.map { (title: $0.title, artist: $0.artist, path: $0.path) } }
        return artworkIdentity(title: title, artist: artist, known: entry)
    }

    /// 同上,最近一次读数由调用方给。纯函数,selftest 覆盖。
    public static func artworkIdentity(title: String?, artist: String?,
                                       known entry: (title: String, artist: String, path: String?)?)
        -> (title: String?, artist: String?, path: String?) {
        if let entry, let title, !title.isEmpty,
           title == entry.title || entry.path.map({ URL(fileURLWithPath: $0).lastPathComponent.lowercased() }) == title {
            return (entry.title, entry.artist, entry.path)
        }
        guard let artist else { return (title, nil, nil) }
        return (title, splitSystemArtist(artist, title: title ?? "", known: nil).artist, nil)
    }

    // MARK: 脚本读不到时

    /// 脚本读不到(没授「自动化」权限、超时、`SourceKnockout` 关掉了这条)时,系统那份快照换成能用的:按 VOX 打开着的音频文件
    /// 认出这一首(`systemFile`),拿文件的标签当已知读数拆「歌手 — 专辑」,再过脚本那条路同一套 `identity`(两条路写出同一份
    /// 歌名、歌手,歌词缓存才是同一条),时长取文件的;记下这首和它的文件,写播放状态(`local_file`)、取封面时用。找不到文件时
    /// 只拆歌手。不是 VOX 的原样返回。会读盘(同一首只找一次),在轮询的后台线程上调。
    public static func systemFallback(_ snapshot: MediaControlSnapshot?, now: Date = Date()) -> MediaControlSnapshot? {
        guard let snapshot, snapshot.bundleIdentifier == bundleID, let title = snapshot.title, !title.isEmpty,
              let pid = snapshot.processIdentifier,
              let file = systemFile(title: title, pid: pid_t(pid), now: now)
        else { return splittingSystemArtist(snapshot) }
        let out = systemFallback(snapshot, file: file)
        current.withLock { $0 = (out.title ?? "", out.artist ?? "", out.album ?? "", file.path) }
        return out
    }

    /// 同上,文件已经找好。纯函数,selftest 覆盖。
    public static func systemFallback(_ snapshot: MediaControlSnapshot,
                                      file: (path: String, tags: LocalAudioFileTags)) -> MediaControlSnapshot {
        let title = snapshot.title ?? ""
        let split = splitSystemArtist(snapshot.artist ?? "", title: title,
                                      known: (title: title, artist: file.tags.artist, album: file.tags.album))
        let id = identity(title: title, artist: split.artist, album: split.album, filePath: file.path)
        var out = snapshot.withTitle(id.title).withArtist(id.artist).withAlbum(id.album)
        if let duration = preciseDuration(reported: snapshot.duration, file: file.tags.duration) {
            out = out.withDuration(duration)
        }
        return out
    }

    /// 按 bundle id 单问到的那份(焦点被别的 App 占着、脚本又读不到时):在放、没报位置的按锚点时刻(开播那一刻)起算,
    /// 进程号从锚点补上(按它找文件)。不是 VOX 的原样返回。纯函数,selftest 覆盖。
    public static func probedSnapshot(_ snapshot: MediaControlSnapshot, anchorTimestamp: Double?, pid: Int32?,
                                      now: Date) -> MediaControlSnapshot {
        guard snapshot.bundleIdentifier == bundleID else { return snapshot }
        var out = snapshot
        if snapshot.playing == true, snapshot.elapsedTime == nil, let anchorTimestamp {
            out = snapshot.withPlayerClock(max(0, now.timeIntervalSince1970 - anchorTimestamp), capturedAt: now)
        }
        if out.processIdentifier == nil { out.processIdentifier = snapshot.processIdentifier ?? pid.map { Int($0) } }
        return out
    }

    /// VOX 打开着的音频文件里,系统那份报的歌名对得上的那一个(`fileMatchesSystemTitle`)。按歌名记,找到了就不再找;
    /// 没找到的隔 `systemFileRetry` 再找(VOX 换歌时可能还没打开新文件)。
    static func systemFile(title: String, pid: pid_t, now: Date) -> (path: String, tags: LocalAudioFileTags)? {
        if let hit = systemFiles.withLock({ $0[title] }),
           hit.found != nil || now.timeIntervalSince(hit.checkedAt) < systemFileRetry {
            return hit.found
        }
        var found: (path: String, tags: LocalAudioFileTags)?
        for path in ProcessOpenFiles.paths(pid: pid)
        where PlayerTitleSplit.audioExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            guard let tags = LocalAudioFileTags.read(path: path),
                  fileMatchesSystemTitle(title, tagsTitle: tags.title, fileName: URL(fileURLWithPath: path).lastPathComponent)
            else { continue }
            found = (path, tags)
            break
        }
        systemFiles.withLock { entries in
            if entries.count > 32 { entries.removeAll() }
            entries[title] = (found, now)
        }
        logger.notice("vox: no script reading, \(found == nil ? "no open file matches" : "found the open file for", privacy: .public) the system title")
        return found
    }

    static let systemFileRetry: TimeInterval = 3
    private static let systemFiles = OSAllocatedUnfairLock<[String: (found: (path: String, tags: LocalAudioFileTags)?, checkedAt: Date)]>(
        initialState: [:])

    /// 系统那份报的歌名是不是这个文件的:VOX 报的是标签里的歌名(乱码照原样),没写标签时是文件名的全小写。纯函数,selftest 覆盖。
    public static func fileMatchesSystemTitle(_ title: String, tagsTitle: String, fileName: String) -> Bool {
        guard !title.isEmpty else { return false }
        if !tagsTitle.isEmpty, tagsTitle == title
            || PlayerTitleSplit.repairingCJKMojibake(tagsTitle) == PlayerTitleSplit.repairingCJKMojibake(title) {
            return true
        }
        return fileName.lowercased() == title
    }

    // MARK: 脚本里的封面

    /// 读 VOX 此刻那首的封面(`tiff artwork data`:它自己显示的那张,文件嵌着的或它挑的同目录图)写进 argv 第一项那个文件,
    /// 回它此刻的歌名;没在跑、没有图回空串。先判在不在跑,`tell` 不会把它拉起来。
    public static let artworkScriptLines = [
        "on run argv",
        "if application id \"com.coppertino.Vox\" is not running then return \"\"",
        "tell application id \"com.coppertino.Vox\"",
        "set t to track",
        "set d to tiff artwork data",
        "end tell",
        "if d is missing value then return \"\"",
        "set fh to open for access POSIX file (item 1 of argv) with write permission",
        "try",
        "set eof fh to 0",
        "write d to fh",
        "end try",
        "close access fh",
        "return t",
        "end run",
    ]

    /// 系统那份给不了封面时(焦点被别的 App 占着、media-control 通道坏了、系统那份没带图)问脚本要的那张,转成 JPEG。脚本回的歌名
    /// 不是记下的这首(`artworkBelongs`,已经换歌了)就不要。读不到、关掉了这条来源返回 nil。会起一个 osascript,只在换歌那一刻调。
    static func scriptArtwork(for entry: (title: String, path: String?)) -> Data? {
        guard !SourceKnockout.isOut(.voxScript) else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-vox-artwork-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let arguments = artworkScriptLines.flatMap { ["-e", $0] } + [file.path]
        guard let r = ProcessRunner.run("/usr/bin/osascript", arguments, timeout: MusicPlaybackController.appleScriptTimeout),
              r.succeeded,
              let rawTitle = String(data: r.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              artworkBelongs(rawTitle: rawTitle, to: entry),
              let tiff = FileIO.read(file), let jpeg = CoverArtReplacementGate.jpegData(tiff),
              CoverArtReplacementGate.isImage(jpeg)
        else { return nil }
        return jpeg
    }

    /// 脚本回的歌名(VOX 原样报的:乱码、没写标签时文件名全小写)是不是记下的这首。纯函数,selftest 覆盖。
    public static func artworkBelongs(rawTitle: String, to entry: (title: String, path: String?)) -> Bool {
        guard !rawTitle.isEmpty else { return false }
        if rawTitle == entry.title || PlayerTitleSplit.repairingCJKMojibake(rawTitle) == entry.title { return true }
        return entry.path.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } == rawTitle
    }

    static func logTornReading(rereads: Int, settled: Bool) {
        logger.notice("vox: track changed but the position was still the previous track's, re-read \(rereads, privacy: .public)x, \(settled ? "settled" : "still carried over", privacy: .public)")
    }
}
