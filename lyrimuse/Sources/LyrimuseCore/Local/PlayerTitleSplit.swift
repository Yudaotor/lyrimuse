import Foundation
import os

/// 系统会话里不报歌手和专辑、把「歌手 - 歌名」拼在标题里的播放器(reAMP),在快照的公开出口换回歌手、歌名、专辑和时长。
/// 见 02 章决策 126。
///
/// 先读正在放的那个文件:按快照里的进程号找到播放器打开着的音频文件(`ProcessOpenFiles`),读它的标签
/// (`LocalAudioFileTags`),用播放器拼标题的规则核对是不是这一首(`fileMatches`),对上了就用文件里的歌手、歌名、专辑
/// 和精确时长。读不到(文件已经关了、不是 AudioToolbox 认得的格式、没写标签)时退回拆标题:只在歌手字段为空时动,
/// 按**第一个** ` - ` 拆(歌名本身带 ` - ` 时这样才对,歌手名里不带空格的 `-` 不受影响);没有标签的文件报的是文件名,
/// 先去掉音频扩展名再拆。两条路都先还原 GBK / Big5 标签被当成 Latin-1 读出来的乱码(`repairingCJKMojibake`)。
/// 网络电台流(系统会话里没有时长,`isStream`)的标题是「歌手 - 歌名 (台名和简介)」,拆之前去掉末尾那组括号
/// (`strippingTrailingParenthetical`),记下来给独立取回的载荷用(`identityParts`)。reAMP 一收到新标题就换、声音要晚几秒,
/// 出口按延迟线(`StreamDelayLine`)晚 `streamLeadSecs` 再换,进度从推算的出声时刻起算。
///
/// 内部的锚点、曲目记忆仍按播放器原样报的字段算;独立取回的载荷(封面)经 `PlayerArtistFix.correctedTrackKey` 换成
/// 同一份歌手和歌名(`identityParts`),跟换过的快照对得上。
public enum PlayerTitleSplit {
    /// 按这个规则换的播放器。只登记实测见过这种标题的。
    public static let bundleIDs: Set<String> = [PlaybackPlayer.reamp.bundleIdentifier]

    /// 没有标签时标题里会带的音频扩展名(小写),也是找正在放的文件时认的扩展名。
    static let audioExtensions: Set<String> = [
        "mp3", "mp2", "flac", "m4a", "m4b", "mp4", "aac", "alac", "wav", "wave", "aif", "aiff", "ogg", "oga", "opus",
        "ape", "wv", "wma", "mpc", "tta", "dsf", "dff", "mod", "xm", "s3m", "it",
    ]

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "player-file")

    /// 拆出来的歌手和歌名;不归这里管(别的播放器、已经有歌手、标题为空)或者没什么可改时返回 nil。
    /// 拆不出歌手时 `artist` 是空串。纯函数,selftest 覆盖。
    public static func split(bundleID: String?, title: String?, artist: String?,
                             isStream: Bool = false) -> (artist: String, title: String)? {
        guard let bundleID, bundleIDs.contains(bundleID),
              (artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
              let title, !title.isEmpty else { return nil }
        var base = strippingAudioExtension(repairingCJKMojibake(title))
        if isStream { base = strippingTrailingParenthetical(base) }
        if let dash = base.range(of: " - ") {
            let left = base[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = base[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { return (left, right) }
        }
        return base == title ? nil : ("", base)
    }

    /// 换到快照上:先用正在放的文件的标签,读不到再拆标题;都不用换时原样返回。会读盘(同一首只读一次),在轮询的后台线程上调。
    public static func applied(to snapshot: MediaControlSnapshot?, now: Date = Date()) -> MediaControlSnapshot? {
        guard let snapshot else { return nil }
        if (snapshot.artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
           let file = fileIdentity(bundleID: snapshot.bundleIdentifier, title: snapshot.title,
                                   duration: snapshot.duration, pid: snapshot.processIdentifier) {
            var out = snapshot.withTitle(file.title)
            if !file.artist.isEmpty { out = out.withArtist(file.artist) }
            if !file.album.isEmpty { out = out.withAlbum(file.album) }
            if let duration = file.duration { out = out.withDuration(duration) }
            return out
        }
        let stream = isStream(duration: snapshot.duration)
        guard let parts = split(bundleID: snapshot.bundleIdentifier, title: snapshot.title, artist: snapshot.artist,
                                isStream: stream)
        else { return snapshot }
        if stream, let title = snapshot.title {
            streamTitles.withLock { entries in
                if entries.count > 16 { entries.removeAll() }
                entries[title] = parts
            }
        }
        var out = snapshot.withTitle(parts.title)
        if !parts.artist.isEmpty { out = out.withArtist(parts.artist) }
        if stream, let raw = snapshot.title {
            out = delayed(out, raw: raw, parts: parts, now: now)
        }
        return out
    }

    // MARK: 电台流延迟线

    /// reAMP 换电台标题比这首真正出声早多少秒:它一收到新标题就换,声音要等缓冲里前面那几秒放完。本机测试台(开头突发
    /// 0 / 16KB / 64KB / 320KB)量到 3.8~5.9 秒,多数在 4.2~4.5 秒;SomaFM 4.3 秒。电台往往在新歌开始之后才发标题、晚多少
    /// 不固定(SomaFM 每 2.8 秒才能插一次),歌词因此总是偏晚:在 4.4 秒上再提前 1.5 秒。见 02 章决策 126「电台逐行歌词」。
    public static let streamLeadSecs: TimeInterval = 2.9

    /// 电台流的延迟线:屏上在放的那首(`shown`)和收到了、还没出声的下一首(`pending`)。`start` 是推算的出声时刻;
    /// 连上后的第一首不知道从哪里进来的,为 nil(不给进度)。
    public struct StreamDelayLine: Equatable, Sendable {
        public struct Track: Equatable, Sendable {
            public var raw: String
            public var artist: String
            public var title: String
            public var start: Date?

            public init(raw: String, artist: String, title: String, start: Date?) {
                self.raw = raw
                self.artist = artist
                self.title = title
                self.start = start
            }
        }

        public var shown: Track?
        public var pending: Track?

        public init(shown: Track? = nil, pending: Track? = nil) {
            self.shown = shown
            self.pending = pending
        }
    }

    /// 走一拍。`titleAt`:reAMP 换到这个标题的时刻(它换标题时把进度归 0,所以是「现在 − 进度」)。没在放就清空,恢复后当成
    /// 刚连上。新标题先挂在 `pending`,到 `titleAt + lead` 才换上去。纯函数,selftest 覆盖。
    public static func advance(_ line: StreamDelayLine, raw: String, artist: String, title: String, titleAt: Date,
                               playing: Bool, now: Date, lead: TimeInterval = streamLeadSecs) -> StreamDelayLine {
        guard playing else { return StreamDelayLine() }
        var line = line
        if line.shown == nil {
            line.shown = .init(raw: raw, artist: artist, title: title, start: nil)
        } else if raw == line.shown?.raw {
            line.pending = nil
        } else if raw != line.pending?.raw {
            line.pending = .init(raw: raw, artist: artist, title: title, start: titleAt.addingTimeInterval(lead))
        }
        if let pending = line.pending, let start = pending.start, now >= start {
            line.shown = pending
            line.pending = nil
        }
        return line
    }

    private static let streamLine = OSAllocatedUnfairLock(initialState: StreamDelayLine())

    /// 按延迟线换掉标题、歌手和进度:进度是「现在 − 出声时刻」,起点不知道的为 nil;下一首的出声时刻填进 `republishDueBy`,
    /// 到点补查。没在放时原样交回。
    private static func delayed(_ snapshot: MediaControlSnapshot, raw: String, parts: (artist: String, title: String),
                                now: Date) -> MediaControlSnapshot {
        let titleAt = now.addingTimeInterval(-(snapshot.elapsedTime ?? 0))
        let line = streamLine.withLock { line -> StreamDelayLine in
            line = advance(line, raw: raw, artist: parts.artist, title: parts.title, titleAt: titleAt,
                           playing: snapshot.playing == true, now: now)
            return line
        }
        guard let shown = line.shown else { return snapshot }
        var out = snapshot.withTitle(shown.title).withArtist(shown.artist)
            .withElapsed(shown.start.map { max(0, now.timeIntervalSince($0)) }, capturedAt: now)
        out.processIdentifier = snapshot.processIdentifier
        out.republishDueBy = line.pending?.start
        return out
    }

    /// 回放测试用:清空延迟线。
    public static func resetStreamDelayLine() {
        streamLine.withLock { $0 = StreamDelayLine() }
    }

    /// 这份快照是延迟线排出来、起点推算过的电台流:位置解算可以拿歌词缓存里的曲长建锚点。纯函数,selftest 覆盖。
    public static func streamClockKnown(bundleID: String?, duration: Double?, elapsed: Double?) -> Bool {
        guard let bundleID, bundleIDs.contains(bundleID) else { return false }
        return isStream(duration: duration) && elapsed != nil
    }

    /// 独立取回的载荷(封面)该用的歌手和歌名,跟 `applied` 换出来的一致:这一首的文件读到过就用它(不再读盘),否则拆标题。
    /// 不归这里管时返回 nil。
    public static func identityParts(bundleID: String?, title: String?, artist: String?) -> (artist: String, title: String)? {
        guard (artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let bundleID, bundleIDs.contains(bundleID), let title,
           let file = cache.withLock({ $0[title]?.identity }) {
            return (file.artist, file.title)
        }
        if let bundleID, bundleIDs.contains(bundleID), let title,
           let stream = streamTitles.withLock({ $0[title] }) {
            return stream
        }
        return split(bundleID: bundleID, title: title, artist: artist)
    }

    /// 电台流那几串标题拆出来的结果,按播放器原样报的标题记(`applied` 记,`identityParts` 查)。
    private static let streamTitles = OSAllocatedUnfairLock<[String: (artist: String, title: String)]>(initialState: [:])

    /// 电台流里不是歌的那几种,调用方当成没在放音乐(`MediaControlClient.playerContentNotMusic`),不拿去查歌词:
    /// 标题里带网址的(「[connecting to host] 网址」:连接那一拍;没收到第一份标题时在放也一直是它);连上之前单报台名那一拍
    /// (没在放、拆不出歌手);台里插播的台标广告(歌手或歌名里带着台名,`mentionsStation`)。只认 reAMP。纯函数,selftest 覆盖。
    public static func streamPlaceholder(bundleID: String?, title: String?, artist: String?, duration: Double?,
                                         playing: Bool?) -> Bool {
        guard let bundleID, bundleIDs.contains(bundleID), isStream(duration: duration),
              (artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if let title, title.contains("://") || mentionsStation(title) { return true }
        guard playing != true else { return false }
        return (split(bundleID: bundleID, title: title, artist: artist, isStream: true)?.artist ?? "").isEmpty
    }

    /// 电台流标题「歌手 - 歌名 (台名和简介)」的前半截里提到了台名:台名取括号里冒号、方括号之前那段,至少 4 个字符,
    /// 不分大小写比。纯函数,selftest 覆盖。
    public static func mentionsStation(_ title: String) -> Bool {
        guard let (head, inner) = trailingParenthetical(title) else { return false }
        let name = inner.prefix { $0 != ":" && $0 != "[" }.trimmingCharacters(in: .whitespaces)
        guard name.count >= 4 else { return false }
        return head.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// 系统会话里没有时长(没有、不是正数或无穷大)就当网络电台流:本地文件都报时长。纯函数,selftest 覆盖。
    public static func isStream(duration: Double?) -> Bool {
        guard let duration else { return true }
        return !(duration > 0) || !duration.isFinite
    }

    /// 去掉末尾一组配对的括号(连同前面的空格,括号里可以再套括号);末尾不是这样的括号、括号前不是空格、去掉后什么都
    /// 不剩时原样返回。纯函数,selftest 覆盖。
    public static func strippingTrailingParenthetical(_ title: String) -> String {
        trailingParenthetical(title)?.head ?? title
    }

    /// 末尾那组配对的括号:括号前面那段(去掉空格)和括号里面;条件同 `strippingTrailingParenthetical`,不成立为 nil。
    static func trailingParenthetical(_ title: String) -> (head: String, inner: String)? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")") else { return nil }
        var depth = 0
        var i = trimmed.endIndex
        while i > trimmed.startIndex {
            i = trimmed.index(before: i)
            if trimmed[i] == ")" { depth += 1 } else if trimmed[i] == "(" { depth -= 1 }
            guard depth == 0 else { continue }
            let head = trimmed[..<i]
            guard head.hasSuffix(" ") else { return nil }
            let out = head.trimmingCharacters(in: .whitespaces)
            guard !out.isEmpty else { return nil }
            return (out, String(trimmed[trimmed.index(after: i)..<trimmed.index(before: trimmed.endIndex)]))
        }
        return nil
    }

    // MARK: 正在放的文件

    /// 从文件标签换来的身份(乱码已还原)。
    public struct FileIdentity: Equatable, Sendable {
        public var artist: String
        public var title: String
        public var album: String
        public var duration: Double?
    }

    /// 播放器报的这串标题(连同它报的时长)是不是这个文件:照 reAMP 拼标题的规则(有歌手「歌手 - 歌名」、只有歌名是歌名、
    /// 没写标签是带扩展名的文件名)拿文件标签原样算一遍,两边连续的空白(含换行)都压成一个空格后逐字比:reAMP 报的是标签原样,
    /// 读标签这边去过首尾空白,标签里带换行的(电台节目把主持、嘉宾分行写)只差在这儿。它只报整数秒,时长差 1.5 秒以内。
    /// 标签不还原乱码:reAMP 跟 AudioToolbox 读老 MP3 得到的是同一串乱码。纯函数,selftest 覆盖。
    public static func fileMatches(reportedTitle: String, reportedDuration: Double?, tags: LocalAudioFileTags,
                            fileName: String) -> Bool {
        let expected: String
        if !tags.artist.isEmpty, !tags.title.isEmpty {
            expected = "\(tags.artist) - \(tags.title)"
        } else if !tags.title.isEmpty {
            expected = tags.title
        } else {
            expected = fileName
        }
        guard collapsedWhitespace(expected) == collapsedWhitespace(reportedTitle) else { return false }
        if let reportedDuration, let duration = tags.duration, abs(duration - reportedDuration) > 1.5 { return false }
        return true
    }

    static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 文件标签换成快照用的身份:还原乱码(几个标签一起判);没写歌名的不用(交回拆标题,那边会去掉文件名的扩展名)。纯函数,selftest 覆盖。
    public static func identity(from tags: LocalAudioFileTags) -> FileIdentity? {
        guard !tags.title.isEmpty else { return nil }
        let fixed = repairingCJKMojibake([tags.artist, tags.title, tags.album])
        return FileIdentity(artist: fixed[0], title: fixed[1], album: fixed[2], duration: tags.duration)
    }

    private struct CacheEntry: Sendable {
        var identity: FileIdentity?
        /// 对上的那个文件;没写标签的文件也记(`identity` 为 nil,封面照样按它找)。
        var path: String?
        var checkedAt: Date
        var attempts: Int
    }

    /// 按播放器报的标题记:同一首每拍不重复读盘。没找到的隔 `retryInterval` 再找,连找 `maxAttempts` 次 —— 换歌那一拍
    /// 播放器可能还没打开新文件;还是没有就隔 `giveUpRetryInterval` 再找一轮(系统会话里挂着旧标题、它开着的却是另一个
    /// 文件时会连着对不上,之后真放这一首就对得上了)。
    private static let cache = OSAllocatedUnfairLock<[String: CacheEntry]>(initialState: [:])
    static let retryInterval: TimeInterval = 2
    static let maxAttempts = 3
    static let giveUpRetryInterval: TimeInterval = 20

    /// 这一拍要不要再去找文件:找到过的不找;没找到的按上面的节奏。纯函数,selftest 覆盖。
    public static func shouldLookUpFile(found: Bool?, attempts: Int, sinceChecked: TimeInterval) -> Bool {
        guard let found else { return true }
        if found { return false }
        return sinceChecked >= (attempts >= maxAttempts ? giveUpRetryInterval : retryInterval)
    }

    /// 按标题记下的那个文件已经不是它在放的:它此刻开着别的音频文件、记下的不在其中(同一串标题换成了另一个文件,
    /// 比如同一首的另一种格式)。一个都没开着时照旧用记下的。纯函数,selftest 覆盖。
    public static func cachedFileReplaced(cachedPath: String, openAudioPaths: [String]) -> Bool {
        !openAudioPaths.isEmpty && !openAudioPaths.contains(cachedPath)
    }

    /// 正在放的那个文件换来的身份;不归这里管、没进程号、找不到对得上的文件时为 nil。
    static func fileIdentity(bundleID: String?, title: String?, duration: Double?, pid: Int?,
                             now: Date = Date()) -> FileIdentity? {
        guard let bundleID, bundleIDs.contains(bundleID), let title, !title.isEmpty else { return nil }
        let hit = cache.withLock { $0[title] }
        if let hit, !shouldLookUpFile(found: hit.path != nil, attempts: hit.attempts,
                                      sinceChecked: now.timeIntervalSince(hit.checkedAt)) {
            guard let path = hit.path, let pid, pid > 0,
                  cachedFileReplaced(cachedPath: path, openAudioPaths: openAudioPaths(pid: pid_t(pid))) else {
                return hit.identity
            }
        }
        guard let pid, pid > 0 else { return nil }
        let found = lookUp(title: title, duration: duration, pid: pid_t(pid))
        cache.withLock { entries in
            if entries.count > 64 { entries.removeAll() }
            let previous = entries[title]?.attempts ?? 0
            let attempts = previous >= maxAttempts ? 1 : previous + 1
            entries[title] = CacheEntry(identity: found?.identity, path: found?.path, checkedAt: now, attempts: attempts)
        }
        return found?.identity
    }

    /// 播放器报的这串标题对上的那个文件(`applied` 找到过才有,不读盘)。封面取不到系统那份时按它找同目录的图。
    public static func currentFilePath(bundleID: String?, title: String?) -> String? {
        guard let bundleID, bundleIDs.contains(bundleID), let title else { return nil }
        return cache.withLock { $0[title]?.path }
    }

    /// 换过之后的这首(歌手、歌名)对上的那个文件(不读盘)。写给引擎的播放状态用(`local_file`,引擎读同名 .lrc)。
    public static func currentFilePath(bundleID: String?, artist: String, title: String) -> String? {
        guard let bundleID, bundleIDs.contains(bundleID), !title.isEmpty else { return nil }
        return cache.withLock { entries in
            entries.first { raw, entry in
                guard entry.path != nil else { return false }
                if let id = entry.identity { return id.artist == artist && id.title == title }
                return split(bundleID: bundleID, title: raw, artist: nil).map { $0.artist == artist && $0.title == title }
                    ?? (raw == title && artist.isEmpty)
            }?.value.path
        }
    }

    private static func openAudioPaths(pid: pid_t) -> [String] {
        ProcessOpenFiles.paths(pid: pid).filter { audioExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
    }

    private static func lookUp(title: String, duration: Double?, pid: pid_t) -> (identity: FileIdentity?, path: String)? {
        let candidates = openAudioPaths(pid: pid)
        for path in candidates {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            guard let tags = LocalAudioFileTags.read(path: path),
                  fileMatches(reportedTitle: title, reportedDuration: duration, tags: tags, fileName: fileName) else { continue }
            let found = identity(from: tags)
            logger.notice("player file: \(fileName, privacy: .public) matches the reported title, tags \(found == nil ? "absent" : "used", privacy: .public), album \(found?.album.isEmpty == false ? "present" : "absent", privacy: .public)")
            return (found, path)
        }
        logger.notice("player file: none of \(candidates.count) open audio files matches the reported title")
        return nil
    }

    // MARK: 同目录的封面

    /// 文件夹里当封面的图片名(不含扩展名,小写),按这个顺序挑;跟歌曲文件同名的图片排在它们前面。
    static let folderCoverNames = ["cover", "folder", "front", "album", "albumart"]
    static let folderCoverExtensions = ["jpg", "jpeg", "png"]
    /// 大过这个的不读(不是封面,或者是整张扫描图)。
    static let folderCoverMaxBytes = 20 * 1024 * 1024

    /// 从一个目录的文件名里挑封面:跟歌曲同名的图片优先,其次按 `folderCoverNames` 的顺序;大小写不敏感。纯函数,selftest 覆盖。
    public static func folderCoverName(audioFileName: String, directoryEntries: [String]) -> String? {
        let images = directoryEntries.filter { folderCoverExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        func base(_ name: String) -> String { URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.lowercased() }
        let song = base(audioFileName)
        if let same = images.first(where: { base($0) == song }) { return same }
        for name in folderCoverNames {
            if let hit = images.first(where: { base($0) == name }) { return hit }
        }
        return nil
    }

    /// 正在放的文件同目录里的封面(图片数据与类型);没有为 nil。会读盘。
    public static func folderCover(forAudioFile path: String) -> (data: Data, mimeType: String)? {
        let file = URL(fileURLWithPath: path)
        let dir = file.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let name = folderCoverName(audioFileName: file.lastPathComponent, directoryEntries: entries) else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > 0, size <= folderCoverMaxBytes, let data = FileIO.read(url) else { return nil }
        return (data, url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg")
    }

    // MARK: 字符串

    /// 按 Latin-1 读出来的 GBK / Big5 字节还原成中文或日文。同一个文件的几个标签(歌手、歌名、专辑)一起判,传一组字段;
    /// 本来就有 U+00FF 以上字符的字段不是这种乱码,原样留着、不参与判断。先排除带重音的西文(`readsAsLatinText`,几个字段连起来看);
    /// 再把字节分别按 GBK、Big5 两两成对解(`decodedFields`):每个高位字节都得跟下一个字节配成那种编码的一个双字节字,解出来只能是
    /// 汉字、常见符号和假名(假名只认 GBK);GBK 至少一个汉字或两个连着的假名,Big5 至少一个汉字。两种都解得开时比常用字区占的
    /// 比例(`commonWeight`),一样多算 GBK。都不成立原样返回。取舍按本机歌词缓存里的歌手名、歌名回放定的,见 02 章决策 126。
    /// 纯函数,selftest 覆盖。
    static func repairingCJKMojibake(_ fields: [String]) -> [String] {
        let fieldBytes = fields.map { field -> [UInt8]? in
            var bytes: [UInt8] = []
            bytes.reserveCapacity(field.unicodeScalars.count)
            for scalar in field.unicodeScalars {
                guard scalar.value <= 0xFF else { return nil }
                bytes.append(UInt8(scalar.value))
            }
            return bytes
        }
        let present = fieldBytes.compactMap { $0 }
        guard present.joined().contains(where: { $0 >= 0x80 }),
              !readsAsLatinText(Array(present.joined(separator: [0x20]))) else { return fields }
        let gbk = decodedFields(fieldBytes, gbk: true)
        let big5 = decodedFields(fieldBytes, gbk: false)
        let chosen: [String?]
        if let gbk, gbk.common >= big5?.common ?? -1 {
            chosen = gbk.texts
        } else if let big5 {
            chosen = big5.texts
        } else {
            return fields
        }
        return zip(fields, chosen).map { $1 ?? $0 }
    }

    static func repairingCJKMojibake(_ title: String) -> String {
        repairingCJKMojibake([title])[0]
    }

    /// 高位字节全是带重音的字母(0xC0~0xFF,× ÷ 除外),而且至少有一个词(连着的字母)同时有 ASCII 字母和带重音的字母:
    /// 像 `Mötley Crüe`、`Sigur Rós - Þú` 这样的西文,不当乱码。汉字的乱码总有高位字节落在 0xC0 以下,或者一个汉字也没跟
    /// ASCII 字母连写。
    static func readsAsLatinText(_ bytes: [UInt8]) -> Bool {
        let isASCIILetter = { (b: UInt8) in (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
        let isAccented = { (b: UInt8) in b >= 0xC0 && b != 0xD7 && b != 0xF7 }
        guard bytes.filter({ $0 >= 0x80 }).allSatisfy(isAccented) else { return false }
        var hasASCII = false, hasAccented = false
        for b in bytes + [0x20] {
            if isASCIILetter(b) { hasASCII = true; continue }
            if isAccented(b) { hasAccented = true; continue }
            if hasASCII && hasAccented { return true }
            hasASCII = false
            hasAccented = false
        }
        return false
    }

    /// 按 GBK(完整的双字节范围:0x81~0xFE 开头、后一字节 0x40~0xFE)或 Big5(0xA1~0xF9 开头、后一字节 0x40~0x7E 或
    /// 0xA1~0xFE)解每个字段;配不成对、解不出、解出别的字(西里尔字母、制表符、自造字区之类)为 nil。不是乱码的字段(nil)
    /// 留 nil。`common` 是常用字区的加权比例。
    private static func decodedFields(_ fields: [[UInt8]?], gbk: Bool) -> (texts: [String?], common: Double)? {
        let encoding: CFStringEncodings = gbk ? .GB_18030_2000 : .big5
        let ns = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        var texts: [String?] = [], pairs = 0, common = 0.0, ideographs = 0, kanaRun = false
        for field in fields {
            guard let bytes = field, bytes.contains(where: { $0 >= 0x80 }) else {
                texts.append(nil)
                continue
            }
            var leads: [(UInt8, UInt8)] = [], i = 0
            while i < bytes.count {
                guard bytes[i] >= 0x80 else { i += 1; continue }
                guard i + 1 < bytes.count, formsPair(gbk: gbk, lead: bytes[i], trail: bytes[i + 1]) else { return nil }
                leads.append((bytes[i], bytes[i + 1]))
                i += 2
            }
            guard let text = String(data: Data(bytes), encoding: ns) else { return nil }
            let wide = Array(text.unicodeScalars.filter { $0.value >= 0x80 })
            guard wide.count == leads.count,
                  wide.allSatisfy({ isIdeograph($0) || isCJKSymbol($0) || (gbk && isKana($0)) }) else { return nil }
            for (k, scalar) in wide.enumerated() {
                let run = isKana(scalar) && ((k > 0 && isKana(wide[k - 1])) || (k + 1 < wide.count && isKana(wide[k + 1])))
                if run { kanaRun = true }
                common += commonWeight(gbk: gbk, lead: leads[k].0, trail: leads[k].1, scalar: scalar, inKanaRun: run)
            }
            pairs += leads.count
            ideographs += wide.filter(isIdeograph).count
            texts.append(text)
        }
        guard pairs > 0, ideographs >= 1 || (gbk && kanaRun) else { return nil }
        return (texts, common / Double(pairs))
    }

    private static func formsPair(gbk: Bool, lead: UInt8, trail: UInt8) -> Bool {
        if gbk { return (0x81...0xFE).contains(lead) && (0x40...0xFE).contains(trail) && trail != 0x7F }
        return (0xA1...0xF9).contains(lead) && ((0x40...0x7E).contains(trail) || (0xA1...0xFE).contains(trail))
    }

    /// 常用字区记 1。GBK:符号(0xA1~0xA3 开头)、一级汉字(0xB0~0xD7 开头、后一字节 ≥ 0xA1);假名(含长音符「ー」)在连着
    /// 两个以上假名的串里记 1、零散的记一半 —— Big5 最常用的那批字(0xA4、0xA5 开头)按 GBK 读正好是零散的假名,日文的假名
    /// 多半成串。Big5:符号与常用字(0xA1~0xC6 开头)。纯函数,selftest 覆盖。
    static func commonWeight(gbk: Bool, lead: UInt8, trail: UInt8, scalar: Unicode.Scalar, inKanaRun: Bool) -> Double {
        guard gbk else { return (0xA1...0xC6).contains(lead) ? 1 : 0 }
        if isKana(scalar) { return inKanaRun ? 1 : 0.5 }
        if (0xA1...0xA3).contains(lead) { return 1 }
        return (0xB0...0xD7).contains(lead) && trail >= 0xA1 ? 1 : 0
    }

    private static func isKana(_ s: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(s.value)
    }

    private static func isIdeograph(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
    }

    /// 中文标题里会出现的符号:全角标点、中文标点、引号省略号、· ° ± × ÷、罗马数字、箭头、圈码、几何图形与星号。
    private static func isCJKSymbol(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F, 0xFF00...0xFFEF, 0x2010...0x203B, 0xB0, 0xB1, 0xB7, 0xD7, 0xF7,
             0x2160...0x217F, 0x2190...0x2199, 0x2460...0x24FF, 0x25A0...0x26FF: return true
        default: return false
        }
    }

    static func strippingAudioExtension(_ title: String) -> String {
        guard let dot = title.lastIndex(of: "."), dot != title.startIndex else { return title }
        let ext = title[title.index(after: dot)...].lowercased()
        return audioExtensions.contains(ext) ? String(title[..<dot]) : title
    }
}
