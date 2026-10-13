import Foundation
import os

/// 系统会话里不报歌手和专辑、把「歌手 - 歌名」拼在标题里的播放器(reAMP),在快照的公开出口换回歌手、歌名、专辑和时长。
/// 见 02 章决策 126。
///
/// 先读正在放的那个文件:按快照里的进程号找到播放器打开着的音频文件(`ProcessOpenFiles`),读它的标签
/// (`LocalAudioFileTags`),用播放器拼标题的规则核对是不是这一首(`fileMatches`),对上了就用文件里的歌手、歌名、专辑
/// 和精确时长。读不到(文件已经关了、不是 AudioToolbox 认得的格式、没写标签)时退回拆标题:只在歌手字段为空时动,
/// 按**第一个** ` - ` 拆(歌名本身带 ` - ` 时这样才对,歌手名里不带空格的 `-` 不受影响);没有标签的文件报的是文件名,
/// 先去掉音频扩展名再拆。两条路都先还原 GBK 标签被当成 Latin-1 读出来的乱码(`repairingGBKMojibake`)。
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
    public static func split(bundleID: String?, title: String?, artist: String?) -> (artist: String, title: String)? {
        guard let bundleID, bundleIDs.contains(bundleID),
              (artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
              let title, !title.isEmpty else { return nil }
        let base = strippingAudioExtension(repairingGBKMojibake(title))
        if let dash = base.range(of: " - ") {
            let left = base[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = base[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { return (left, right) }
        }
        return base == title ? nil : ("", base)
    }

    /// 换到快照上:先用正在放的文件的标签,读不到再拆标题;都不用换时原样返回。会读盘(同一首只读一次),在轮询的后台线程上调。
    public static func applied(to snapshot: MediaControlSnapshot?) -> MediaControlSnapshot? {
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
        guard let parts = split(bundleID: snapshot.bundleIdentifier, title: snapshot.title, artist: snapshot.artist)
        else { return snapshot }
        var out = snapshot.withTitle(parts.title)
        if !parts.artist.isEmpty { out = out.withArtist(parts.artist) }
        return out
    }

    /// 独立取回的载荷(封面)该用的歌手和歌名,跟 `applied` 换出来的一致:这一首的文件读到过就用它(不再读盘),否则拆标题。
    /// 不归这里管时返回 nil。
    public static func identityParts(bundleID: String?, title: String?, artist: String?) -> (artist: String, title: String)? {
        guard (artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let bundleID, bundleIDs.contains(bundleID), let title,
           let file = cache.withLock({ $0[title]?.identity }) {
            return (file.artist, file.title)
        }
        return split(bundleID: bundleID, title: title, artist: artist)
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
    /// 没写标签是带扩展名的文件名)拿文件标签原样算一遍,跟报的逐字比;它只报整数秒,时长差 1.5 秒以内。
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
        guard expected == reportedTitle.trimmingCharacters(in: .whitespaces) else { return false }
        if let reportedDuration, let duration = tags.duration, abs(duration - reportedDuration) > 1.5 { return false }
        return true
    }

    /// 文件标签换成快照用的身份:还原乱码;没写歌名的不用(交回拆标题,那边会去掉文件名的扩展名)。纯函数,selftest 覆盖。
    public static func identity(from tags: LocalAudioFileTags) -> FileIdentity? {
        guard !tags.title.isEmpty else { return nil }
        return FileIdentity(artist: repairingGBKMojibake(tags.artist), title: repairingGBKMojibake(tags.title),
                            album: repairingGBKMojibake(tags.album), duration: tags.duration)
    }

    private struct CacheEntry: Sendable {
        var identity: FileIdentity?
        /// 对上的那个文件;没写标签的文件也记(`identity` 为 nil,封面照样按它找)。
        var path: String?
        var checkedAt: Date
        var attempts: Int
    }

    /// 按播放器报的标题记:同一首每拍不重复读盘。没找到的隔 `retryInterval` 再找,最多 `maxAttempts` 次 —— 换歌那一拍
    /// 播放器可能还没打开新文件。
    private static let cache = OSAllocatedUnfairLock<[String: CacheEntry]>(initialState: [:])
    static let retryInterval: TimeInterval = 2
    static let maxAttempts = 3

    /// 正在放的那个文件换来的身份;不归这里管、没进程号、找不到对得上的文件时为 nil。
    static func fileIdentity(bundleID: String?, title: String?, duration: Double?, pid: Int?,
                             now: Date = Date()) -> FileIdentity? {
        guard let bundleID, bundleIDs.contains(bundleID), let title, !title.isEmpty else { return nil }
        if let hit = cache.withLock({ $0[title] }),
           hit.path != nil || hit.attempts >= maxAttempts || now.timeIntervalSince(hit.checkedAt) < retryInterval {
            return hit.identity
        }
        guard let pid, pid > 0 else { return nil }
        let found = lookUp(title: title, duration: duration, pid: pid_t(pid))
        cache.withLock { entries in
            if entries.count > 64 { entries.removeAll() }
            let attempts = (entries[title]?.attempts ?? 0) + 1
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

    private static func lookUp(title: String, duration: Double?, pid: pid_t) -> (identity: FileIdentity?, path: String)? {
        let candidates = ProcessOpenFiles.paths(pid: pid)
            .filter { audioExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
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

    /// 按 Latin-1 读出来的 GBK 字节还原成中文。只在这三样都成立时换:每个字符都在 U+0000~U+00FF;高位字节两两成对、
    /// 都落在 GB2312 的 0xA1~0xFE(带重音的西文是一个高位字节挨着 ASCII,过不了这一条);按 GB18030 解出来含汉字。
    /// 别的一律原样。Big5 存的认不出(同一串字节按 GBK 也解得开,分不清)。纯函数,selftest 覆盖。
    static func repairingGBKMojibake(_ title: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(title.unicodeScalars.count)
        for scalar in title.unicodeScalars {
            guard scalar.value <= 0xFF else { return title }
            bytes.append(UInt8(scalar.value))
        }
        guard bytes.contains(where: { $0 >= 0x80 }) else { return title }
        var i = 0
        while i < bytes.count {
            if bytes[i] < 0x80 { i += 1; continue }
            guard i + 1 < bytes.count, (0xA1...0xFE).contains(bytes[i]), (0xA1...0xFE).contains(bytes[i + 1]) else { return title }
            i += 2
        }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let decoded = String(data: Data(bytes), encoding: gb18030),
              decoded.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return title }
        return decoded
    }

    static func strippingAudioExtension(_ title: String) -> String {
        guard let dot = title.lastIndex(of: "."), dot != title.startIndex else { return title }
        let ext = title[title.index(after: dot)...].lowercased()
        return audioExtensions.contains(ext) ? String(title[..<dot]) : title
    }
}
