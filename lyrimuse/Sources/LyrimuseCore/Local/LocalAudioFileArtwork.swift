import AudioToolbox
import Foundation
import os

/// 本地音频文件里嵌着的封面。三种格式自己解:MP3 的 ID3v2(v2.3 / v2.4 的 APIC、v2.2 的 PIC;文件开头连着的几个标签、只在文件尾的
/// v2.4 标签、FLAC 前面挂着的都读)、FLAC 的 PICTURE 块、MP4 / M4A 的 `moov › udta › meta › ilst › covr`;别的格式问 AudioToolbox
/// (`kAudioFilePropertyAlbumArtwork`,它认得 M4A、FLAC、Ogg 里的 `METADATA_BLOCK_PICTURE`,不认 MP3 的 APIC,AVFoundation 正好反过来,
/// 所以前三种不交给系统框架)。一个文件嵌了几张时取正面封面(图片类型 3),没有正面封面取第一张;只收读得出图头、结尾完整的
/// (`isComplete`),坏图当没有、接着看下一张。解析结果按文件记(`read`)。见 02 章决策 260。
public enum LocalAudioFileArtwork {
    /// 标签区、单个 PICTURE 块、`moov` 大过这个的不读。
    static let maxBytes = 32 << 20
    /// ID3v2 / FLAC 的图片类型:正面封面。
    static let frontCover: UInt32 = 3
    /// 文件开头连着的 ID3v2 标签最多看几个。
    static let maxLeadingTags = 4
    /// FLAC 元数据块最多看几块。
    static let maxFLACBlocks = 128
    /// 解析结果记几个文件。
    static let cacheLimit = 4

    struct Cover: Sendable {
        let data: Data
        let mimeType: String
    }

    /// 文件身份:路径、设备与文件编号、大小、修改时间。换了内容(重写、覆盖)至少有一项会变。
    struct FileStamp: Equatable, Sendable {
        let path: String
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard statFile(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            self.path = path
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private struct CacheEntry: Sendable {
        let stamp: FileStamp
        let cover: Cover?
    }

    private static let cache = OSAllocatedUnfairLock<[CacheEntry]>(initialState: [])
    private static let parses = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// 文件里嵌着的封面(图片数据与类型);没有、读不出、不是图为 nil。同一个文件(`FileStamp` 不变)只解析一次,「没有封面」也记。
    /// 会读盘,别在主线程调。
    public static func read(path: String) -> (data: Data, mimeType: String)? {
        guard let stamp = FileStamp(path: path) else { return nil }
        if let hit = cache.withLock({ entries in entries.first { $0.stamp == stamp } }) {
            return hit.cover.map { ($0.data, $0.mimeType) }
        }
        parses.withLock { $0 += 1 }
        let cover = parse(path: path)
        cache.withLock { entries in
            entries.removeAll { $0.stamp.path == stamp.path }
            entries.append(CacheEntry(stamp: stamp, cover: cover))
            if entries.count > cacheLimit { entries.removeFirst(entries.count - cacheLimit) }
        }
        return cover.map { ($0.data, $0.mimeType) }
    }

    /// `read` 真去解析文件的次数(没命中缓存的那几次)。selftest 用。
    public static var parseCount: Int { parses.withLock { $0 } }

    static func parse(path: String) -> Cover? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return nil }
        let file = FileBytes(fd: fd, size: UInt64(info.st_size))
        guard let head = file.read(0, Int(min(12, file.size))), head.count >= 8 else { return nil }
        var picture: Data?
        var offset: UInt64 = 0
        var tags = 0
        while tags < maxLeadingTags, let header = file.read(offset, 10), let length = id3TagLength(header) {
            tags += 1
            if picture == nil { picture = id3Picture(file, at: offset, header: header) }
            offset += 10 + UInt64(length) + (header[3] == 4 && header[5] & 0x10 != 0 ? 10 : 0)
        }
        if picture == nil {
            if file.read(offset, 4) == Array("fLaC".utf8) {
                picture = flacPicture(file, at: offset)
            } else if tags == 0, String(decoding: head[4..<8], as: UTF8.self) == "ftyp" {
                picture = MP4VideoTrack.moov(path: path, limit: UInt64(maxBytes)).flatMap(mp4Picture)
            } else {
                picture = trailingID3Picture(file)
                if picture == nil, tags == 0 { picture = audioToolboxPicture(path: path) }
            }
        }
        return picture.map { Cover(data: $0, mimeType: mimeType(of: $0)) }
    }

    /// 几张候选里挑一张:能用的(读得出图头、结尾完整)正面封面优先,没有就取第一张能用的。纯函数,selftest 覆盖。
    public static func choose(_ pictures: [(type: UInt32, data: Data)]) -> Data? {
        func usable(_ data: Data) -> Bool { isComplete(data) && CoverArtReplacementGate.isImage(data) }
        return pictures.first { $0.type == frontCover && usable($0.data) }?.data ?? pictures.first { usable($0.data) }?.data
    }

    /// 图片结尾完整:JPEG 以 `FF D9` 结尾、PNG 最后一块是 `IEND`(末尾补的 0 不算);别的格式不判。帧长算错、文件截断时挂上的
    /// 半张图过不了这道(图头照样读得出)。纯函数,selftest 覆盖。
    public static func isComplete(_ image: Data) -> Bool {
        var end = image.endIndex
        while end > image.startIndex, image[end - 1] == 0 { end -= 1 }
        let body = image[image.startIndex..<end]
        if image.starts(with: [0xFF, 0xD8]) {
            return body.count >= 4 && body.suffix(2).elementsEqual([0xFF, 0xD9])
        }
        if image.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return body.count >= 20 && body.suffix(8).prefix(4).elementsEqual(Array("IEND".utf8))
        }
        return true
    }

    static func mimeType(of picture: Data) -> String {
        picture.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    // MARK: ID3v2

    /// 标签头(10 字节)→ 标签区长度(不含头和尾标);不是 ID3v2 标签头为 nil。
    static func id3TagLength(_ header: [UInt8]) -> Int? {
        guard header.count >= 10, header.starts(with: Array("ID3".utf8)), (2...4).contains(header[3]),
              header[6..<10].allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return syncsafe(header[6..<10])
    }

    /// 文件里 `offset` 处这个标签的封面。只读帧头和 APIC 帧;v2.2 / v2.3 整个标签做过反同步的才把整个标签读进来。
    private static func id3Picture(_ file: FileBytes, at offset: UInt64, header: [UInt8]) -> Data? {
        guard let length = id3TagLength(header), length <= maxBytes else { return nil }
        let version = header[3], flags = header[5]
        if version < 4, flags & 0x80 != 0 {
            guard let tag = file.read(offset + 10, length) else { return nil }
            return id3Picture(header: header, tag: tag)
        }
        return id3Frames(version: version, flags: flags, length: length) { file.read(offset + 10 + UInt64($0), $1) }
    }

    /// 只在文件尾的 v2.4 标签(带 `3DI` 尾标;后面还可能挂着 128 字节的 ID3v1)。
    private static func trailingID3Picture(_ file: FileBytes) -> Data? {
        var ends = [file.size]
        if file.size >= 128, file.read(file.size - 128, 3) == Array("TAG".utf8) { ends.append(file.size - 128) }
        for end in ends {
            guard end >= 20, let footer = file.read(end - 10, 10), footer.starts(with: Array("3DI".utf8)), footer[3] == 4,
                  footer[6..<10].allSatisfy({ $0 & 0x80 == 0 }) else { continue }
            let length = UInt64(syncsafe(footer[6..<10]))
            guard end >= 20 + length, let header = file.read(end - 20 - length, 10),
                  id3TagLength(header) == Int(length), header[3] == 4 else { continue }
            return id3Picture(file, at: end - 20 - length, header: header)
        }
        return nil
    }

    /// 标签头(10 字节)和标签区 → 封面。v2.2 / v2.3 整个标签做过反同步的先还原;v2.4 按每帧自己的标志还原、跳过数据长度指示。
    /// 压缩、加密的帧不读。纯函数,selftest 覆盖。
    public static func id3Picture(header: [UInt8], tag: [UInt8]) -> Data? {
        guard header.count >= 10, header.starts(with: Array("ID3".utf8)) else { return nil }
        let version = header[3], flags = header[5]
        let tag = version < 4 && flags & 0x80 != 0 ? resynchronized(tag[...]) : tag
        return id3Frames(version: version, flags: flags, length: tag.count) { pos, count in
            pos >= 0 && count >= 0 && pos + count <= tag.count ? Array(tag[pos..<(pos + count)]) : nil
        }
    }

    /// 逐帧走一个标签区(`read(位置, 字节数)` 按标签区内的位置取,越界为 nil),只把 APIC / PIC 帧的内容读进来。
    /// v2.2 / v2.3 的整标签反同步由调用方先还原。
    static func id3Frames(version: UInt8, flags: UInt8, length: Int, read: (Int, Int) -> [UInt8]?) -> Data? {
        guard (2...4).contains(version), !(version == 2 && flags & 0x40 != 0) else { return nil }
        let frameHead = version == 2 ? 6 : 10
        var pos = 0
        if version > 2, flags & 0x40 != 0 {
            // 扩展头:v2.4 的长度含自己、是同步安全整数;v2.3 的不含那 4 字节。
            guard let size = read(0, 4) else { return nil }
            pos = version == 4 ? syncsafe(size[...]) : bigEndian(size[...]) + 4
        }
        var pictures: [(type: UInt32, data: Data)] = []
        while pos + frameHead <= length, let head = read(pos, frameHead), head[0] != 0 {
            let id = String(decoding: head[0..<(version == 2 ? 3 : 4)], as: UTF8.self)
            let size: Int
            switch version {
            case 2: size = bigEndian(head[3..<6])
            case 4: size = v24FrameSize(head, at: pos, length: length, read: read)
            default: size = bigEndian(head[4..<8])
            }
            let start = pos + frameHead
            guard start + size <= length else { break }
            pos = start + size
            guard id == "APIC" || id == "PIC" else { continue }
            var skip = 0, resync = false
            if version > 2 {
                let format = head[9]
                if version == 3 {
                    guard format & 0xC0 == 0 else { continue }
                    if format & 0x20 != 0 { skip = 1 }
                } else {
                    guard format & 0x0C == 0 else { continue }
                    if format & 0x40 != 0 { skip += 1 }
                    if format & 0x01 != 0 { skip += 4 }
                    resync = format & 0x02 != 0 || flags & 0x80 != 0
                }
            }
            guard let raw = read(start, size) else { break }
            let body = resync ? resynchronized(raw.dropFirst(skip))[...] : raw.dropFirst(skip)
            if let picture = apicPicture(body, v22: version == 2) { pictures.append((picture.type, Data(picture.data))) }
        }
        return choose(pictures)
    }

    /// v2.4 的帧长按规范是同步安全整数,iTunes 等老写法写的是普通大端整数。两种读法不一样时,看哪种读法读完这一帧正好落在下一个帧头、
    /// 补白或标签区末尾(同 mutagen 的兼容做法);字节里有最高位的只可能是普通整数。
    static func v24FrameSize(_ head: [UInt8], at pos: Int, length: Int, read: (Int, Int) -> [UInt8]?) -> Int {
        let raw = head[4..<8]
        let plain = bigEndian(raw)
        if raw.contains(where: { $0 & 0x80 != 0 }) { return plain }
        let safe = syncsafe(raw)
        guard safe != plain else { return safe }
        func lands(_ size: Int) -> Bool {
            let end = pos + 10 + size
            if end == length { return true }
            guard end < length else { return false }
            if end + 10 <= length, let next = read(end, 10), isFrameHeader(next, at: end, length: length) { return true }
            return isPadding(from: end, length: length, read: read)
        }
        return lands(safe) || !lands(plain) ? safe : plain
    }

    /// 像一个 v2.4 帧头:ID 是四个大写字母或数字、打头的是字母,帧长按两种读法至少有一种不超出标签区。
    static func isFrameHeader(_ head: [UInt8], at pos: Int, length: Int) -> Bool {
        guard head.count >= 10, (0x41...0x5A).contains(head[0]),
              head[0..<4].allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }) else { return false }
        let room = length - pos - 10
        return syncsafe(head[4..<8]) <= room || bigEndian(head[4..<8]) <= room
    }

    /// 从 `start` 到标签区末尾全是 0。
    private static func isPadding(from start: Int, length: Int, read: (Int, Int) -> [UInt8]?) -> Bool {
        var pos = start
        while pos < length {
            guard let chunk = read(pos, min(4096, length - pos)), chunk.allSatisfy({ $0 == 0 }) else { return false }
            pos += chunk.count
        }
        return true
    }

    /// APIC:编码 1 字节、MIME(Latin-1,以 0 结尾)、图片类型 1 字节、描述(按编码结尾)、图片数据。
    /// v2.2 的 PIC 把 MIME 换成 3 字节图片格式(`JPG` / `PNG`)。
    static func apicPicture(_ body: ArraySlice<UInt8>, v22: Bool) -> (type: UInt32, data: ArraySlice<UInt8>)? {
        guard let encoding = body.first else { return nil }
        var i = body.startIndex + 1
        if v22 {
            i += 3
        } else {
            guard let end = body[i...].firstIndex(of: 0) else { return nil }
            i = end + 1
        }
        guard i < body.endIndex else { return nil }
        let type = UInt32(body[i])
        i += 1
        if encoding == 1 || encoding == 2 {
            var j = i
            while j + 1 < body.endIndex, !(body[j] == 0 && body[j + 1] == 0) { j += 2 }
            guard j + 1 < body.endIndex else { return nil }
            i = j + 2
        } else {
            guard let end = body[i...].firstIndex(of: 0) else { return nil }
            i = end + 1
        }
        guard i < body.endIndex else { return nil }
        return (type, body[i...])
    }

    /// 反同步还原:`FF 00` → `FF`。
    static func resynchronized(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var previous: UInt8 = 0
        for byte in bytes {
            if !(previous == 0xFF && byte == 0) { out.append(byte) }
            previous = byte
        }
        return out
    }

    // MARK: FLAC

    /// 从 `offset` 处的 `fLaC` 起逐块读元数据,只把 PICTURE 块(类型 6)读进来,别的跳过。遇到最后一块的标志、类型 127(非法)、
    /// 不在第一块的 STREAMINFO(类型 0)或看满 `maxFLACBlocks` 块就停:块头连着是 0 的坏文件每块只前进 4 字节。
    private static func flacPicture(_ file: FileBytes, at offset: UInt64) -> Data? {
        guard file.read(offset, 4) == Array("fLaC".utf8) else { return nil }
        var position = offset + 4
        var pictures: [(type: UInt32, data: Data)] = []
        for index in 0..<maxFLACBlocks {
            guard let head = file.read(position, 4) else { break }
            let type = head[0] & 0x7F, length = bigEndian(head[1..<4])
            if type == 127 || (type == 0 && index > 0) { break }
            if type == 6, length <= maxBytes, let body = file.read(position + 4, length),
               let picture = flacPictureBlock(body[...]) {
                pictures.append((picture.type, Data(picture.data)))
            }
            if head[0] & 0x80 != 0 { break }
            position += 4 + UInt64(length)
        }
        return choose(pictures)
    }

    /// PICTURE 块:图片类型、MIME 长度与 MIME、描述长度与描述、宽高色深色数各 4 字节、数据长度与数据,整数都是 32 位大端。
    /// 纯函数,selftest 覆盖。
    public static func flacPictureBlock(_ block: ArraySlice<UInt8>) -> (type: UInt32, data: ArraySlice<UInt8>)? {
        var i = block.startIndex
        func number() -> Int? {
            guard i + 4 <= block.endIndex else { return nil }
            defer { i += 4 }
            return bigEndian(block[i..<(i + 4)])
        }
        guard let type = number(), let mimeLength = number() else { return nil }
        i += mimeLength
        guard let descriptionLength = number() else { return nil }
        i += descriptionLength + 16
        guard let length = number(), i + length <= block.endIndex else { return nil }
        return (UInt32(type), block[i..<(i + length)])
    }

    // MARK: MP4

    /// `moov` 的内容 → `udta › meta › ilst › covr` 里的 `data` 盒子。`meta` 按标准带 4 字节版本与标志;QuickTime 写法没有这 4 字节、
    /// 第一个子盒子直接是 `hdlr`,两种都认。`covr` 里的图都当正面封面。纯函数,selftest 覆盖。
    public static func mp4Picture(moov: [UInt8]) -> Data? {
        func child(_ bytes: ArraySlice<UInt8>, _ type: String) -> ArraySlice<UInt8>? {
            MP4VideoTrack.children(bytes).first { $0.type == type }?.payload
        }
        guard let udta = child(moov[...], "udta"), let meta = child(udta, "meta") else { return nil }
        let startsWithBox = meta.count >= 8
            && String(decoding: meta[(meta.startIndex + 4)..<(meta.startIndex + 8)], as: UTF8.self) == "hdlr"
        guard let ilst = child(startsWithBox ? meta : meta.dropFirst(4), "ilst"), let covr = child(ilst, "covr") else { return nil }
        let pictures = MP4VideoTrack.children(covr)
            .filter { $0.type == "data" && $0.payload.count > 8 }
            .map { (type: frontCover, data: Data($0.payload.dropFirst(8))) }
        return choose(pictures)
    }

    // MARK: 别的格式

    private static func audioToolboxPicture(path: String) -> Data? {
        var file: AudioFileID?
        guard AudioFileOpenURL(URL(fileURLWithPath: path) as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        var artwork: Unmanaged<CFData>?
        guard AudioFileGetProperty(file, kAudioFilePropertyAlbumArtwork, &size, &artwork) == noErr,
              let data = artwork?.takeRetainedValue() as Data? else { return nil }
        return choose([(frontCover, data)])
    }

    // MARK: 读盘

    /// 按位置读文件。小块读从 64KB 的窗口里取(帧头、块头一个接一个读,不每次都进内核),大块直接读。
    private final class FileBytes {
        let fd: Int32
        let size: UInt64
        private var window: [UInt8] = []
        private var windowStart: UInt64 = 0
        static let windowSize = 64 << 10

        init(fd: Int32, size: UInt64) {
            self.fd = fd
            self.size = size
        }

        /// 从 `offset` 起正好 `count` 字节;超出文件、读不全为 nil。
        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else { return nil }
            if offset >= windowStart, offset + UInt64(count) <= windowStart + UInt64(window.count) {
                let start = Int(offset - windowStart)
                return Array(window[start..<(start + count)])
            }
            guard count <= Self.windowSize / 2 else { return direct(offset, count) }
            guard let filled = direct(offset, Int(min(UInt64(Self.windowSize), size - offset))) else { return nil }
            window = filled
            windowStart = offset
            return Array(filled[0..<count])
        }

        private func direct(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard count > 0 else { return [] }
            var done = 0
            let out = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
                while done < count {
                    let n = pread(fd, buffer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                    guard n > 0 else { break }
                    done += n
                }
                initialized = done
            }
            return done == count ? out : nil
        }
    }

    private static func syncsafe(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 8 | Int($1) }
    }
}

private func statFile(_ path: String, _ info: inout stat) -> Int32 {
    stat(path, &info)
}
