import CoreGraphics
import Foundation
import ImageIO
import LyrimuseCore
import UniformTypeIdentifiers

/// 本地音频文件里嵌着的封面(`LocalAudioFileArtwork`)、「正在放的文件自带的封面」的先后(`PlayerTitleSplit.fileCover`)、
/// 取封面时认哪个文件(`PlayerOpenFile.playingFile`)和退路的曲目标识(`MediaControlClient.localFileArtwork`)。
/// 文件按格式在测试里现造,不依赖 ffmpeg。cover-art 组调。
func checkLocalAudioFileArtwork() {
    typealias A = LocalAudioFileArtwork
    let red = testImage(red: 255, type: UTType.png), blue = testImage(red: 0, type: UTType.png)
    let jpeg = testImage(red: 128, type: UTType.jpeg)
    let broken: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x41, count: 40)
    expectEqual(red.isEmpty || blue.isEmpty || jpeg.isEmpty || red == blue, false, "嵌入封面: 测试图造得出来、两张不同")
    expectEqual(jpeg.contains(0xFF), true, "嵌入封面: JPEG 里有 0xFF,反同步那几条才测得到东西")
    func bytes(_ data: Data?) -> [UInt8]? { data.map { [UInt8]($0) } }
    func choose(_ pictures: [(UInt32, [UInt8])]) -> [UInt8]? { bytes(A.choose(pictures.map { ($0.0, Data($0.1)) })) }

    // ---- 挑哪一张 ----
    expectEqual(choose([(4, red), (3, blue)]), blue, "嵌入封面: 正面封面(类型 3)优先")
    expectEqual(choose([(4, red), (5, blue)]), red, "嵌入封面: 没有正面封面取第一张")
    expectEqual(choose([(3, broken), (4, red)]), red, "嵌入封面: 正面封面是坏图,取下一张读得出的")
    expectEqual(choose([(3, broken)]), nil, "嵌入封面: 只有坏图当没有")
    expectEqual(choose([]), nil, "嵌入封面: 没有图")
    expectEqual(choose([(3, Array(blue.dropLast(12))), (4, red)]), red, "嵌入封面: 正面封面是截断的半张,取下一张完整的")

    // ---- 图片结尾完整 ----
    expectEqual(A.isComplete(Data(jpeg)), true, "截断的图: 完整的 JPEG")
    expectEqual(A.isComplete(Data(jpeg + [0, 0, 0])), true, "截断的图: JPEG 后面补的 0 不算")
    expectEqual(A.isComplete(Data(jpeg.dropLast(2))), false, "截断的图: JPEG 没有 FF D9")
    expectEqual(A.isComplete(Data(jpeg.prefix(jpeg.count / 2))), false, "截断的图: 前一半 JPEG")
    expectEqual(A.isComplete(Data(red)), true, "截断的图: 完整的 PNG")
    expectEqual(A.isComplete(Data(red.dropLast(12))), false, "截断的图: PNG 没有 IEND")
    expectEqual(CoverArtReplacementGate.isImage(Data(jpeg.prefix(jpeg.count - 2))), true,
                "截断的图: 图头照样读得出,只靠图头判拦不住")
    expectEqual(A.isComplete(Data("GIF89a".utf8)), true, "截断的图: 别的格式不判")

    // ---- MP3:ID3v2 ----
    func apic(_ picture: [UInt8], type: UInt8, encoding: UInt8 = 0, description: [UInt8] = Array("Cover".utf8)) -> [UInt8] {
        let terminator: [UInt8] = encoding == 1 || encoding == 2 ? [0, 0] : [0]
        return [encoding] + Array("image/png".utf8) + [0, type] + description + terminator + picture
    }
    func frame23(_ id: String, _ body: [UInt8], format: UInt8 = 0) -> [UInt8] {
        Array(id.utf8) + bigEndian(body.count, 4) + [0, format] + body
    }
    func frame24(_ id: String, _ body: [UInt8], format: UInt8 = 0) -> [UInt8] {
        Array(id.utf8) + syncsafe(body.count) + [0, format] + body
    }
    func header(_ version: UInt8, size: Int, flags: UInt8 = 0) -> [UInt8] {
        Array("ID3".utf8) + [version, 0, flags] + syncsafe(size)
    }
    func id3(_ header: [UInt8], _ tag: [UInt8]) -> [UInt8]? { bytes(A.id3Picture(header: header, tag: tag)) }
    let title = frame23("TIT2", [0] + Array("Song".utf8))
    let v23 = title + frame23("APIC", apic(red, type: 4)) + frame23("APIC", apic(blue, type: 3)) + [0, 0, 0, 0]
    expectEqual(id3(header(3, size: v23.count), v23), blue, "嵌入封面 MP3: v2.3 两张取正面封面")
    let utf16 = title + frame23("APIC", apic(red, type: 3, encoding: 1, description: [0xFF, 0xFE, 0x01, 0x5C, 0x62, 0x97]))
    expectEqual(id3(header(3, size: utf16.count), utf16), red, "嵌入封面 MP3: UTF-16 描述按两个 0 结尾")
    let v22 = Array("TT2".utf8) + bigEndian(5, 3) + [0] + Array("Song".utf8)
        + Array("PIC".utf8) + bigEndian(6 + red.count, 3) + [0] + Array("PNG".utf8) + [3, 0] + red
    expectEqual(id3(header(2, size: v22.count), v22), red, "嵌入封面 MP3: v2.2 的 PIC")
    let jpegAPIC = apic(jpeg, type: 3), unsynced = unsynchronized(jpegAPIC)
    expectEqual(unsynced.count > jpegAPIC.count, true, "嵌入封面 MP3: 反同步真的插了字节")
    let v24 = frame24("APIC", syncsafe(jpegAPIC.count) + unsynced, format: 0x03)
    expectEqual(id3(header(4, size: v24.count), v24), jpeg, "嵌入封面 MP3: v2.4 帧级反同步 + 数据长度指示")
    let v23Unsync = unsynchronized(frame23("APIC", jpegAPIC))
    expectEqual(id3(header(3, size: v23Unsync.count, flags: 0x80), v23Unsync), jpeg, "嵌入封面 MP3: v2.3 整个标签反同步")
    let compressed = frame24("APIC", apic(red, type: 3), format: 0x08) + frame24("APIC", apic(blue, type: 4))
    expectEqual(id3(header(4, size: compressed.count), compressed), blue, "嵌入封面 MP3: 压缩过的帧不读")
    let extended = bigEndian(6, 4) + [0, 0, 0, 0, 0, 0] + frame23("APIC", apic(red, type: 3))
    expectEqual(id3(header(3, size: extended.count, flags: 0x40), extended), red, "嵌入封面 MP3: 跳过扩展头")
    expectEqual(id3(header(3, size: title.count), title), nil, "嵌入封面 MP3: 没有 APIC")
    let corrupt = frame23("APIC", apic(broken, type: 3))
    expectEqual(id3(header(3, size: corrupt.count), corrupt), nil, "嵌入封面 MP3: 封面坏了当没有")
    let truncated = Array(frame23("APIC", apic(red, type: 3)).dropLast(10))
    expectEqual(id3(header(3, size: truncated.count), truncated), nil, "嵌入封面 MP3: 帧长超出标签区不读")
    let halfPicture = frame23("APIC", apic(Array(jpeg.dropLast(jpeg.count / 3)), type: 3))
    expectEqual(id3(header(3, size: halfPicture.count), halfPicture), nil, "截断的图 MP3: APIC 里只有前一截 JPEG 不挂")

    // ---- v2.4 帧长写成普通大端整数(iTunes 等老写法)----
    let album24 = frame24("TALB", [0] + Array("Album".utf8))
    func plain24(_ body: [UInt8]) -> [UInt8] { Array("APIC".utf8) + bigEndian(body.count, 4) + [0, 0] + body }
    let bigJPEG = apic(jpeg, type: 3)
    expectEqual(bigJPEG.count >= 128 && bigEndian(bigJPEG.count, 4).contains { $0 & 0x80 != 0 }, true,
                "v2.4 帧长: 测试帧够长、帧长字节带最高位,两种读法不一样")
    let plainHigh = frame24("TIT2", [0] + Array("Song".utf8)) + plain24(bigJPEG) + album24 + [0, 0, 0, 0]
    expectEqual(id3(header(4, size: plainHigh.count), plainHigh), jpeg, "v2.4 帧长: 普通大端整数(字节带最高位)读出整张")
    let plainJunk = plain24(bigJPEG) + [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C]
    expectEqual(id3(header(4, size: plainJunk.count), plainJunk), jpeg, "v2.4 帧长: 字节带最高位的只可能是普通整数(后面是杂字节也认)")
    // 四个字节都没有最高位:按同步安全读是 675、按普通整数读是 1315,读完前者落在描述里那串 Z 上(像帧 ID,帧长却超出标签区)。
    let fixed = 1 + 9 + 1 + 1 + 1 + red.count
    let lowBody = apic(red, type: 3, description: Array(repeating: 0x5A, count: max(1, 0x523 - fixed)))
    expectEqual(lowBody.count == 0x523 && 10 + 675 + 10 <= 12 + 0x523 - fixed, true, "v2.4 帧长: 测试帧正好 1315 字节、同步安全读法落在 Z 里")
    let plainLow = plain24(lowBody) + album24
    expectEqual(id3(header(4, size: plainLow.count), plainLow), red, "v2.4 帧长: 普通大端整数(字节没有最高位)看下一帧头认出")
    let plainLast = frame24("TIT2", [0] + Array("Song".utf8)) + plain24(lowBody) + Array(repeating: 0, count: 64)
    expectEqual(id3(header(4, size: plainLast.count), plainLast), red, "v2.4 帧长: 普通大端整数,读完正好落在补白上")
    let plainEnd = frame24("TIT2", [0] + Array("Song".utf8)) + plain24(lowBody)
    expectEqual(id3(header(4, size: plainEnd.count), plainEnd), red, "v2.4 帧长: 普通大端整数,读完正好是标签区末尾")
    let safeLow = frame24("APIC", lowBody) + album24
    expectEqual(id3(header(4, size: safeLow.count), safeLow), red, "v2.4 帧长: 规范的同步安全整数照旧")

    // ---- FLAC:PICTURE 块 ----
    func pictureBlock(_ picture: [UInt8], type: UInt32) -> [UInt8] {
        let mime = Array("image/png".utf8), description = Array("front".utf8)
        return bigEndian(Int(type), 4) + bigEndian(mime.count, 4) + mime + bigEndian(description.count, 4) + description
            + Array(repeating: 0, count: 16) + bigEndian(picture.count, 4) + picture
    }
    expectEqual(A.flacPictureBlock(pictureBlock(red, type: 3)[...]).map { [$0.type: Array($0.data)] }, [3: red],
                "嵌入封面 FLAC: 解 PICTURE 块")
    expectEqual(A.flacPictureBlock(pictureBlock(red, type: 3).dropLast(1)) == nil, true, "嵌入封面 FLAC: 数据长度超出块不读")
    func metadataBlock(_ type: UInt8, _ body: [UInt8], last: Bool) -> [UInt8] {
        [type | (last ? 0x80 : 0)] + bigEndian(body.count, 3) + body
    }
    let streamInfo = metadataBlock(0, Array(repeating: 0, count: 34), last: false)

    // ---- MP4:moov › udta › meta › ilst › covr ----
    func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { box(Array(type.utf8), payload) }
    func box(_ type: [UInt8], _ payload: [UInt8]) -> [UInt8] { bigEndian(8 + payload.count, 4) + type + payload }
    let hdlr = box("hdlr", Array(repeating: 0, count: 8) + Array("mdirappl".utf8) + Array(repeating: 0, count: 9))
    func covr(_ pictures: [[UInt8]]) -> [UInt8] {
        box("covr", pictures.flatMap { box("data", [0, 0, 0, 14, 0, 0, 0, 0] + $0) })
    }
    func moov(_ covrBox: [UInt8], fullBox: Bool = true) -> [UInt8] {
        let ilst = box("ilst", box([0xA9] + Array("nam".utf8), box("data", [0, 0, 0, 1, 0, 0, 0, 0] + Array("Song".utf8))) + covrBox)
        return box("udta", box("meta", (fullBox ? [0, 0, 0, 0] : []) + hdlr + ilst))
    }
    expectEqual(bytes(A.mp4Picture(moov: moov(covr([red])))), red, "嵌入封面 M4A: meta 带版本与标志")
    expectEqual(bytes(A.mp4Picture(moov: moov(covr([red]), fullBox: false))), red, "嵌入封面 M4A: QuickTime 写法的 meta")
    expectEqual(bytes(A.mp4Picture(moov: moov(covr([broken, blue])))), blue, "嵌入封面 M4A: 第一张坏了取第二张")
    expectEqual(A.mp4Picture(moov: moov([])), nil, "嵌入封面 M4A: 没有 covr")

    // ---- 整个文件读 ----
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrimuse-embedded-art-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func write(_ name: String, _ bytes: [UInt8]) -> String {
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
        return path
    }
    func read(_ path: String) -> [UInt8]? { A.read(path: path).map { [UInt8]($0.data) } }
    let mpegFrames: [UInt8] = Array([0xFF, 0xFB, 0x90, 0x64] + Array(repeating: 0, count: 413)).repeated(4)
    let mp3 = write("song.mp3", header(3, size: v23.count) + v23 + mpegFrames)
    expectEqual(read(mp3), blue, "嵌入封面 文件: MP3")
    expectEqual(A.read(path: mp3)?.mimeType, "image/png", "嵌入封面 文件: 类型按图头认")
    let mp3Footer = write("footer.mp3", header(4, size: v24.count, flags: 0x10) + v24 + Array("3DI".utf8) + [4, 0, 0x10] + syncsafe(v24.count) + mpegFrames)
    expectEqual(read(mp3Footer), jpeg, "嵌入封面 文件: v2.4 带尾部标签")
    expectEqual(A.read(path: write("bare.mp3", mpegFrames)) == nil, true, "嵌入封面 文件: MP3 没有标签")
    expectEqual(A.read(path: write("corrupt.mp3", header(3, size: corrupt.count) + corrupt + mpegFrames)) == nil, true,
                "嵌入封面 文件: MP3 封面坏了")
    expectEqual(read(write("plain24.mp3", header(4, size: plainHigh.count) + plainHigh + mpegFrames)), jpeg,
                "v2.4 帧长 文件: 普通大端整数的 APIC 读出整张")
    expectEqual(A.read(path: write("half.mp3", header(3, size: halfPicture.count) + halfPicture + mpegFrames)) == nil, true,
                "截断的图 文件: 只有前一截 JPEG 不挂")

    // ---- 两个 ID3v2 标签、只在文件尾的标签 ----
    let firstTag = header(3, size: title.count) + title
    let coverTag = frame23("APIC", apic(blue, type: 3))
    expectEqual(read(write("two-tags.mp3", firstTag + header(3, size: coverTag.count) + coverTag + mpegFrames)), blue,
                "两个 ID3 标签: 封面在第二个里")
    expectEqual(read(write("two-tags.flac", firstTag + header(3, size: title.count) + title + Array("fLaC".utf8) + streamInfo
                           + metadataBlock(6, pictureBlock(red, type: 3), last: true))), red,
                "两个 ID3 标签: 后面接着 FLAC")
    let tailBody = frame24("TIT2", [0] + Array("Song".utf8)) + frame24("APIC", apic(red, type: 3))
    let tailTag = Array("ID3".utf8) + [4, 0, 0x10] + syncsafe(tailBody.count) + tailBody
        + Array("3DI".utf8) + [4, 0, 0x10] + syncsafe(tailBody.count)
    expectEqual(read(write("tail.mp3", mpegFrames + tailTag)), red, "尾部 ID3: 只在文件尾、带 3DI 尾标")
    let v1 = Array("TAG".utf8) + Array(repeating: 0x20, count: 124) + [0xFF]
    expectEqual(read(write("tail-v1.mp3", mpegFrames + tailTag + v1)), red, "尾部 ID3: 后面还挂着 128 字节的 ID3v1")
    expectEqual(A.read(path: write("tail-bad.mp3", mpegFrames + Array(tailTag.dropFirst(3)))) == nil, true,
                "尾部 ID3: 尾标对不上标签头不读")

    // ---- FLAC 文件 ----
    let flacHead = Array("fLaC".utf8) + streamInfo
    expectEqual(read(write("song.flac", flacHead + metadataBlock(1, Array(repeating: 0, count: 64), last: false)
                           + metadataBlock(6, pictureBlock(red, type: 4), last: false)
                           + metadataBlock(6, pictureBlock(blue, type: 3), last: true) + [0xFF, 0xF8])), blue,
                "嵌入封面 文件: FLAC 跳过别的块、取正面封面")
    expectEqual(read(write("id3.flac", header(3, size: title.count) + title + flacHead
                           + metadataBlock(6, pictureBlock(red, type: 3), last: true))), red,
                "嵌入封面 文件: FLAC 前面挂着 ID3v2")
    expectEqual(A.read(path: write("plain.flac", Array("fLaC".utf8) + metadataBlock(0, Array(repeating: 0, count: 34), last: true)))
                == nil, true, "嵌入封面 文件: FLAC 没有 PICTURE 块")
    expectEqual(A.read(path: write("corrupt.flac", flacHead + metadataBlock(6, pictureBlock(broken, type: 3), last: true))) == nil,
                true, "嵌入封面 文件: FLAC 封面坏了")
    let zeros = write("zeros.flac", Array("fLaC".utf8) + Array(repeating: 0, count: 4 << 20))
    let zerosStart = Date()
    expectEqual(A.read(path: zeros) == nil, true, "畸形 FLAC: fLaC 后面全是 0")
    expectEqual(Date().timeIntervalSince(zerosStart) < 0.2, true, "畸形 FLAC: 4MB 全零不逐 4 字节走到底(耗时有上限)")
    let padding = metadataBlock(1, [], last: false)
    expectEqual(read(write("blocks-ok.flac", flacHead + padding.repeated(100) + metadataBlock(6, pictureBlock(red, type: 3), last: true))),
                red, "畸形 FLAC: 100 块以内照读")
    expectEqual(A.read(path: write("blocks-many.flac", flacHead + padding.repeated(200)
                                   + metadataBlock(6, pictureBlock(red, type: 3), last: true))) == nil, true,
                "畸形 FLAC: 块数超过上限就停")
    expectEqual(A.read(path: write("type127.flac", flacHead + metadataBlock(127, [], last: false)
                                   + metadataBlock(6, pictureBlock(red, type: 3), last: true))) == nil, true,
                "畸形 FLAC: 遇到类型 127 就停")
    expectEqual(A.read(path: write("streaminfo2.flac", flacHead + streamInfo
                                   + metadataBlock(6, pictureBlock(red, type: 3), last: true))) == nil, true,
                "畸形 FLAC: 第二块又是 STREAMINFO 就停")

    // ---- M4A、Ogg(AudioToolbox)----
    let ftyp = box("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0] + Array("M4A mp42isom".utf8))
    let mdat = box("mdat", Array(repeating: 0x21, count: 4096))
    expectEqual(read(write("song.m4a", ftyp + mdat + box("moov", moov(covr([red]))))), red, "嵌入封面 文件: M4A,moov 在 mdat 后面")
    expectEqual(A.read(path: write("plain.m4a", ftyp + box("moov", moov([])) + mdat)) == nil, true, "嵌入封面 文件: M4A 没有封面")
    expectEqual(A.read(path: write("corrupt.m4a", ftyp + box("moov", moov(covr([broken]))))) == nil, true, "嵌入封面 文件: M4A 封面坏了")
    expectEqual(read(write("song.opus", oggOpus(picture: pictureBlock(blue, type: 3)))), blue,
                "嵌入封面 AudioToolbox: Ogg Opus 的 METADATA_BLOCK_PICTURE")
    expectEqual(A.read(path: write("plain.opus", oggOpus(picture: nil))) == nil, true, "嵌入封面 AudioToolbox: Ogg Opus 没有封面")
    expectEqual(A.read(path: write("missing-dir/none.mp3", [])) == nil, true, "嵌入封面 文件: 文件不存在")

    // ---- 解析结果按文件记 ----
    let cached = write("cached.mp3", header(3, size: v23.count) + v23 + mpegFrames)
    let before = A.parseCount
    _ = A.read(path: cached)
    expectEqual(read(cached), blue, "解析缓存: 第二次读照样有图")
    expectEqual(A.parseCount - before, 1, "解析缓存: 同一个文件读两次只解析一次")
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: cached)
    _ = A.read(path: cached)
    expectEqual(A.parseCount - before, 2, "解析缓存: 修改时间变了重新解析")
    let sameSize = header(3, size: v23.count) + v23.map { $0 == 0x53 ? 0x54 : $0 } + mpegFrames
    FileManager.default.createFile(atPath: cached, contents: Data(sameSize))
    try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: cached)
    _ = A.read(path: cached)
    expectEqual(A.parseCount - before, 3, "解析缓存: 同样大小、同样修改时间,换了文件编号也重新解析")
    FileManager.default.createFile(atPath: cached, contents: Data(header(3, size: utf16.count) + utf16 + mpegFrames))
    expectEqual(read(cached), red, "解析缓存: 换了内容读到新的封面")
    let noCover = write("nocover.mp3", mpegFrames)
    let beforeMiss = A.parseCount
    _ = A.read(path: noCover)
    _ = A.read(path: noCover)
    expectEqual(A.parseCount - beforeMiss, 1, "解析缓存: 「没有封面」也记,不定时重读")

    // ---- 文件自带的封面:嵌着的优先,其次同目录 ----
    let album = dir.appendingPathComponent("album")
    try? FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: album.appendingPathComponent("cover.png").path, contents: Data(red))
    let embeddedPath = album.appendingPathComponent("embedded.mp3").path
    FileManager.default.createFile(atPath: embeddedPath, contents: Data(header(3, size: v23.count) + v23 + mpegFrames))
    let barePath = album.appendingPathComponent("bare.mp3").path
    FileManager.default.createFile(atPath: barePath, contents: Data(mpegFrames))
    expectEqual(PlayerTitleSplit.fileCover(forAudioFile: embeddedPath).map { [UInt8]($0.data) }, blue,
                "文件自带的封面: 嵌着的压过同目录的 cover.png")
    expectEqual(PlayerTitleSplit.fileCover(forAudioFile: barePath).map { [UInt8]($0.data) }, red,
                "文件自带的封面: 没嵌的用同目录的图")

    // ---- 退路:文件自带的封面,曲目标识跟系统那份同样算 ----
    let spotify = PlaybackPlayer.spotify.bundleIdentifier
    let fallback = MediaControlClient.localFileArtwork(path: embeddedPath, bundleID: spotify, keyArtist: "Probe", keyTitle: "Song")
    expectEqual(fallback.map { [UInt8]($0.data) }, blue, "退路: 用正在放的文件嵌着的封面")
    expectEqual(fallback?.trackKey, PlayerArtistFix.correctedTrackKey(bundle: spotify, artist: "Probe", title: "Song"),
                "退路: 曲目标识跟系统那份同样算")
    expectEqual(MediaControlClient.localFileArtwork(path: barePath, bundleID: spotify, keyArtist: "Probe", keyTitle: "Song")
                .map { [UInt8]($0.data) }, red, "退路: 没嵌的用同目录的图")
    expectEqual(MediaControlClient.localFileArtwork(path: nil, bundleID: spotify, keyArtist: "Probe", keyTitle: "Song") == nil, true,
                "退路: 没认出文件为空")

    // ---- 取封面时认哪个文件:同名同歌手的两个文件、在线放同名的歌 ----
    typealias O = PlayerOpenFile
    var lookUps = 0
    func playing(_ cachedPath: String, _ open: [String], found: String? = "/m/album.mp3") -> String? {
        O.playingFile(cachedPath: cachedPath, openAudioPaths: open) { lookUps += 1; return found }
    }
    expectEqual(playing("/m/single.mp3", ["/m/single.mp3", "/m/other.flac"]), "/m/single.mp3", "同名双文件: 记下的还开着就用它")
    expectEqual(lookUps, 0, "同名双文件: 记下的还开着不重找")
    expectEqual(playing("/m/single.mp3", ["/m/album.mp3"]), "/m/album.mp3", "同名双文件: 换成另一个文件时重找到它")
    expectEqual(lookUps, 1, "同名双文件: 记下的没开着才重找")
    expectEqual(playing("/m/single.mp3", ["/m/unrelated.mp3"], found: nil), nil, "同名双文件: 开着的都对不上为空")
    expectEqual(playing("/m/single.mp3", []), nil, "同名双文件: 一个音频文件都没开着(在线放同名的歌)不挂记下的那张")
    expectEqual(lookUps, 2, "同名双文件: 什么都没开着不重找")
    expectEqual(O.cachedFileMatches(fileDuration: 40, reportedDuration: 55), false, "同名双文件: 报的时长对不上记下的文件就重找")
    expectEqual(O.cachedFileMatches(fileDuration: 40, reportedDuration: 41.2), true, "同名双文件: 时长差 1.5 秒以内算同一个")
    expectEqual(O.cachedFileMatches(fileDuration: nil, reportedDuration: 55), true, "同名双文件: 文件没有时长不判")
    expectEqual(O.cachedFileMatches(fileDuration: 40, reportedDuration: 0), true, "同名双文件: 播放器还没报时长不判")

    // ---- 接线(契约):取封面不信按(歌手、歌名)记下的路径,焦点被占的两条退路也走文件 ----
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let client = (try? String(contentsOf: root.appendingPathComponent("LyrimuseCore/Local/MediaControlClient.swift"), encoding: .utf8)) ?? ""
    expectEqual(sourceHas(client, "PlayerOpenFile.currentFilePath("), false, "文件自带的封面 接线: 取封面用 playingFilePath")
    expectEqual(sourceHas(client, "folderCover(forAudioFile:"), false, "文件自带的封面 接线: 不再只找同目录的图")
    expectEqual(sourceHas(client, "NowPlayingClientsProbe.artwork(forBundleID:"), false,
                "文件自带的封面 接线: 焦点被占时单问那一家都经 focusTargetArtwork(没给图也交回歌名)")
    expectEqual(sourceHas(sourceBody("private static func focusTargetArtwork(", in: client),
                          "return localFileArtwork(path: localFilePath(bundleID: target.bundleID, rawTitle: title, rawArtist: report.rawArtist),"),
                true, "文件自带的封面 接线: 焦点被占、那一家没给图时按开着的文件退回")
    let openFile = (try? String(contentsOf: root.appendingPathComponent("LyrimuseCore/Local/PlayerOpenFile.swift"), encoding: .utf8)) ?? ""
    expectEqual(sourceHas(sourceBody("static func fileIdentity(artist: String?", in: openFile),
                          "hit.path == nil || cachedFileMatches(fileDuration: hit.identity?.duration, reportedDuration: duration)"),
                true, "同名双文件 接线: 命中缓存时报的时长对不上记下的文件就重找")
}

private func testImage(red: UInt8, type: UTType) -> [UInt8] {
    guard let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return [] }
    context.setFillColor(red: CGFloat(red) / 255, green: 0.3, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let out = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return [] }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return [] }
    return [UInt8](out as Data)
}

/// 最小的 Ogg Opus:OpusHead 一页、OpusTags 一页(`picture` 是 FLAC PICTURE 块,base64 后写成 `METADATA_BLOCK_PICTURE`)、一个静音包。
private func oggOpus(picture: [UInt8]?) -> [UInt8] {
    func page(_ packet: [UInt8], sequence: UInt32, flags: UInt8, granule: UInt64) -> [UInt8] {
        let lacing = Array(repeating: UInt8(255), count: packet.count / 255) + [UInt8(packet.count % 255)]
        var out = Array("OggS".utf8) + [0, flags] + littleEndian(granule, 8) + littleEndian(1234, 4)
            + littleEndian(UInt64(sequence), 4) + [0, 0, 0, 0] + [UInt8(lacing.count)] + lacing + packet
        var crc: UInt32 = 0
        for byte in out {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        out.replaceSubrange(22..<26, with: littleEndian(UInt64(crc), 4))
        return out
    }
    let head = Array("OpusHead".utf8) + [1, 1] + littleEndian(312, 2) + littleEndian(48000, 4) + [0, 0, 0]
    let comments = picture.map { [Array("METADATA_BLOCK_PICTURE=".utf8) + Array(Data($0).base64EncodedString().utf8)] }
        ?? [Array("TITLE=Song".utf8)]
    let tags = Array("OpusTags".utf8) + littleEndian(4, 4) + Array("test".utf8) + littleEndian(UInt64(comments.count), 4)
        + comments.flatMap { littleEndian(UInt64($0.count), 4) + $0 }
    return page(head, sequence: 0, flags: 2, granule: 0) + page(tags, sequence: 1, flags: 0, granule: 0)
        + page([0xF8, 0xFF, 0xFE], sequence: 2, flags: 4, granule: 960 + 312)
}

private func littleEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8((value >> ($0 * 8)) & 0xFF) }
}

private func bigEndian(_ value: Int, _ count: Int) -> [UInt8] {
    (0..<count).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) }
}

private func syncsafe(_ value: Int) -> [UInt8] {
    (0..<4).reversed().map { UInt8((value >> ($0 * 7)) & 0x7F) }
}

private func unsynchronized(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    for (i, byte) in bytes.enumerated() {
        out.append(byte)
        if byte == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0 || bytes[i + 1] >= 0xE0 { out.append(0) }
    }
    return out
}

private extension Array {
    func repeated(_ times: Int) -> [Element] { (0..<times).flatMap { _ in self } }
}
