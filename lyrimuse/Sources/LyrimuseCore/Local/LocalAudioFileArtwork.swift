import AudioToolbox
import Foundation

/// 本地音频文件里嵌着的封面。三种格式自己解:MP3 开头的 ID3v2(v2.3 / v2.4 的 APIC、v2.2 的 PIC;FLAC 前面挂着的 ID3v2 也读)、
/// FLAC 的 PICTURE 块、MP4 / M4A 的 `moov › udta › meta › ilst › covr`;别的格式问 AudioToolbox(`kAudioFilePropertyAlbumArtwork`,
/// 它认得 M4A、FLAC,不认 MP3 的 APIC,AVFoundation 正好反过来,所以前三种不交给系统框架)。
/// 一个文件嵌了几张时取正面封面(图片类型 3),没有正面封面取第一张;只收读得出图头的(`CoverArtReplacementGate.isImage`),
/// 坏图当没有、接着看下一张。见 02 章决策 260。
public enum LocalAudioFileArtwork {
    /// 标签区、单个 PICTURE 块、`moov` 大过这个的不读。
    static let maxBytes = 32 << 20
    /// ID3v2 / FLAC 的图片类型:正面封面。
    static let frontCover: UInt32 = 3

    /// 文件里嵌着的封面(图片数据与类型);没有、读不出、不是图为 nil。会读盘,别在主线程调。
    public static func read(path: String) -> (data: Data, mimeType: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count >= 8 else { return nil }
        let bytes = [UInt8](head)
        var picture: [UInt8]?
        if bytes.starts(with: Array("ID3".utf8)), bytes.count >= 10 {
            let tagSize = syncsafe(bytes[6..<10]) + (bytes[5] & 0x10 != 0 ? 10 : 0)
            if tagSize <= maxBytes, (try? handle.seek(toOffset: 10)) != nil,
               let tag = try? handle.read(upToCount: tagSize), tag.count == tagSize {
                picture = id3Picture(header: Array(bytes[0..<10]), tag: [UInt8](tag))
            }
            if picture == nil { picture = flacPicture(handle: handle, at: UInt64(10 + tagSize)) }
        } else if bytes.starts(with: Array("fLaC".utf8)) {
            picture = flacPicture(handle: handle, at: 0)
        } else if String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" {
            picture = MP4VideoTrack.moov(path: path, limit: UInt64(maxBytes)).flatMap(mp4Picture)
        } else {
            picture = audioToolboxPicture(path: path)
        }
        guard let picture else { return nil }
        return (Data(picture), mimeType(of: picture))
    }

    /// 几张候选里挑一张:读得出图头的正面封面优先,没有就取第一张读得出图头的。纯函数,selftest 覆盖。
    public static func choose(_ pictures: [(type: UInt32, data: [UInt8])]) -> [UInt8]? {
        let images = pictures.filter { CoverArtReplacementGate.isImage(Data($0.data)) }
        return (images.first { $0.type == frontCover } ?? images.first)?.data
    }

    static func mimeType(of picture: [UInt8]) -> String {
        picture.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    // MARK: ID3v2

    /// 标签头(10 字节)和标签区 → 封面。v2.2 / v2.3 整个标签做过反同步的先还原;v2.4 按每帧自己的标志还原、跳过数据长度指示。
    /// 压缩、加密的帧不读。纯函数,selftest 覆盖。
    public static func id3Picture(header: [UInt8], tag: [UInt8]) -> [UInt8]? {
        guard header.count >= 10, header.starts(with: Array("ID3".utf8)) else { return nil }
        let version = header[3], flags = header[5]
        guard (2...4).contains(version), !(version == 2 && flags & 0x40 != 0) else { return nil }
        let tag = version < 4 && flags & 0x80 != 0 ? resynchronized(tag[...]) : tag
        let frameHead = version == 2 ? 6 : 10
        var pos = 0
        if version > 2, flags & 0x40 != 0, tag.count >= 4 {
            // 扩展头:v2.4 的长度含自己、是同步安全整数;v2.3 的不含那 4 字节。
            pos = version == 4 ? syncsafe(tag[0..<4]) : bigEndian(tag[0..<4]) + 4
        }
        var pictures: [(type: UInt32, data: [UInt8])] = []
        while pos >= 0, pos + frameHead <= tag.count, tag[pos] != 0 {
            let id = String(decoding: tag[pos..<(pos + (version == 2 ? 3 : 4))], as: UTF8.self)
            let size: Int
            switch version {
            case 2: size = bigEndian(tag[(pos + 3)..<(pos + 6)])
            case 4: size = syncsafe(tag[(pos + 4)..<(pos + 8)])
            default: size = bigEndian(tag[(pos + 4)..<(pos + 8)])
            }
            let start = pos + frameHead
            guard size >= 0, start + size <= tag.count else { break }
            var body = tag[start..<(start + size)]
            var readable = id == "APIC" || id == "PIC"
            if version > 2 {
                let format = tag[pos + 9]
                if version == 3 {
                    readable = readable && format & 0xC0 == 0
                    if format & 0x20 != 0 { body = body.dropFirst() }
                } else {
                    readable = readable && format & 0x0C == 0
                    if format & 0x40 != 0 { body = body.dropFirst() }
                    if format & 0x01 != 0 { body = body.dropFirst(4) }
                    if format & 0x02 != 0 || flags & 0x80 != 0 { body = resynchronized(body)[...] }
                }
            }
            if readable, let picture = apicPicture(body, v22: version == 2) { pictures.append(picture) }
            pos = start + size
        }
        return choose(pictures)
    }

    /// APIC:编码 1 字节、MIME(Latin-1,以 0 结尾)、图片类型 1 字节、描述(按编码结尾)、图片数据。
    /// v2.2 的 PIC 把 MIME 换成 3 字节图片格式(`JPG` / `PNG`)。
    static func apicPicture(_ body: ArraySlice<UInt8>, v22: Bool) -> (type: UInt32, data: [UInt8])? {
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
        return (type, Array(body[i...]))
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

    /// 从 `offset` 处的 `fLaC` 起逐块读元数据,只把 PICTURE 块(类型 6)读进来,别的跳过。会读盘。
    static func flacPicture(handle: FileHandle, at offset: UInt64) -> [UInt8]? {
        guard (try? handle.seek(toOffset: offset)) != nil, let magic = try? handle.read(upToCount: 4),
              magic == Data("fLaC".utf8) else { return nil }
        var position = offset + 4
        var pictures: [(type: UInt32, data: [UInt8])] = []
        while let head = try? handle.read(upToCount: 4), head.count == 4 {
            let h = [UInt8](head)
            let length = bigEndian(h[1..<4])
            if h[0] & 0x7F == 6, length <= maxBytes, let body = try? handle.read(upToCount: length), body.count == length,
               let picture = flacPictureBlock([UInt8](body)) {
                pictures.append(picture)
            }
            if h[0] & 0x80 != 0 { break }
            position += 4 + UInt64(length)
            guard (try? handle.seek(toOffset: position)) != nil else { break }
        }
        return choose(pictures)
    }

    /// PICTURE 块:图片类型、MIME 长度与 MIME、描述长度与描述、宽高色深色数各 4 字节、数据长度与数据,整数都是 32 位大端。
    /// 纯函数,selftest 覆盖。
    public static func flacPictureBlock(_ block: [UInt8]) -> (type: UInt32, data: [UInt8])? {
        var i = 0
        func number() -> Int? {
            guard i + 4 <= block.count else { return nil }
            defer { i += 4 }
            return bigEndian(block[i..<(i + 4)])
        }
        guard let type = number(), let mimeLength = number() else { return nil }
        i += mimeLength
        guard let descriptionLength = number() else { return nil }
        i += descriptionLength + 16
        guard let length = number(), i + length <= block.count else { return nil }
        return (UInt32(type), Array(block[i..<(i + length)]))
    }

    // MARK: MP4

    /// `moov` 的内容 → `udta › meta › ilst › covr` 里的 `data` 盒子。`meta` 按标准带 4 字节版本与标志;QuickTime 写法没有这 4 字节、
    /// 第一个子盒子直接是 `hdlr`,两种都认。`covr` 里的图都当正面封面。纯函数,selftest 覆盖。
    public static func mp4Picture(moov: [UInt8]) -> [UInt8]? {
        func child(_ bytes: ArraySlice<UInt8>, _ type: String) -> ArraySlice<UInt8>? {
            MP4VideoTrack.children(bytes).first { $0.type == type }?.payload
        }
        guard let udta = child(moov[...], "udta"), let meta = child(udta, "meta") else { return nil }
        let startsWithBox = meta.count >= 8
            && String(decoding: meta[(meta.startIndex + 4)..<(meta.startIndex + 8)], as: UTF8.self) == "hdlr"
        guard let ilst = child(startsWithBox ? meta : meta.dropFirst(4), "ilst"), let covr = child(ilst, "covr") else { return nil }
        let pictures = MP4VideoTrack.children(covr)
            .filter { $0.type == "data" && $0.payload.count > 8 }
            .map { (type: frontCover, data: Array($0.payload.dropFirst(8))) }
        return choose(pictures)
    }

    // MARK: 别的格式

    private static func audioToolboxPicture(path: String) -> [UInt8]? {
        var file: AudioFileID?
        guard AudioFileOpenURL(URL(fileURLWithPath: path) as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        var artwork: Unmanaged<CFData>?
        guard AudioFileGetProperty(file, kAudioFilePropertyAlbumArtwork, &size, &artwork) == noErr,
              let data = artwork?.takeRetainedValue() as Data? else { return nil }
        return choose([(frontCover, [UInt8](data))])
    }

    private static func syncsafe(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 8 | Int($1) }
    }
}
