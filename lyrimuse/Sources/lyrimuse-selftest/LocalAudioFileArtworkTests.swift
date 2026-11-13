import CoreGraphics
import Foundation
import ImageIO
import LyrimuseCore
import UniformTypeIdentifiers

/// 本地音频文件里嵌着的封面(`LocalAudioFileArtwork`)和「正在放的文件自带的封面」的先后(`PlayerTitleSplit.fileCover`)。
/// 文件按格式在测试里现造,不依赖 ffmpeg。cover-art 组调。
func checkLocalAudioFileArtwork() {
    typealias A = LocalAudioFileArtwork
    let red = testImage(red: 255, type: UTType.png), blue = testImage(red: 0, type: UTType.png)
    let jpeg = testImage(red: 128, type: UTType.jpeg)
    let broken: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x41, count: 40)
    expectEqual(red.isEmpty || blue.isEmpty || jpeg.isEmpty || red == blue, false, "嵌入封面: 测试图造得出来、两张不同")
    expectEqual(jpeg.contains(0xFF), true, "嵌入封面: JPEG 里有 0xFF,反同步那几条才测得到东西")

    // ---- 挑哪一张 ----
    expectEqual(A.choose([(4, red), (3, blue)]), blue, "嵌入封面: 正面封面(类型 3)优先")
    expectEqual(A.choose([(4, red), (5, blue)]), red, "嵌入封面: 没有正面封面取第一张")
    expectEqual(A.choose([(3, broken), (4, red)]), red, "嵌入封面: 正面封面是坏图,取下一张读得出的")
    expectEqual(A.choose([(3, broken)]), nil, "嵌入封面: 只有坏图当没有")
    expectEqual(A.choose([]), nil, "嵌入封面: 没有图")

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
    let title = frame23("TIT2", [0] + Array("Song".utf8))
    let v23 = title + frame23("APIC", apic(red, type: 4)) + frame23("APIC", apic(blue, type: 3)) + [0, 0, 0, 0]
    expectEqual(A.id3Picture(header: header(3, size: v23.count), tag: v23), blue, "嵌入封面 MP3: v2.3 两张取正面封面")
    let utf16 = title + frame23("APIC", apic(red, type: 3, encoding: 1, description: [0xFF, 0xFE, 0x01, 0x5C, 0x62, 0x97]))
    expectEqual(A.id3Picture(header: header(3, size: utf16.count), tag: utf16), red, "嵌入封面 MP3: UTF-16 描述按两个 0 结尾")
    let v22 = Array("TT2".utf8) + bigEndian(5, 3) + [0] + Array("Song".utf8)
        + Array("PIC".utf8) + bigEndian(6 + red.count, 3) + [0] + Array("PNG".utf8) + [3, 0] + red
    expectEqual(A.id3Picture(header: header(2, size: v22.count), tag: v22), red, "嵌入封面 MP3: v2.2 的 PIC")
    let jpegAPIC = apic(jpeg, type: 3), unsynced = unsynchronized(jpegAPIC)
    expectEqual(unsynced.count > jpegAPIC.count, true, "嵌入封面 MP3: 反同步真的插了字节")
    let v24 = frame24("APIC", syncsafe(jpegAPIC.count) + unsynced, format: 0x03)
    expectEqual(A.id3Picture(header: header(4, size: v24.count), tag: v24), jpeg, "嵌入封面 MP3: v2.4 帧级反同步 + 数据长度指示")
    let v23Unsync = unsynchronized(frame23("APIC", jpegAPIC))
    expectEqual(A.id3Picture(header: header(3, size: v23Unsync.count, flags: 0x80), tag: v23Unsync), jpeg,
                "嵌入封面 MP3: v2.3 整个标签反同步")
    let compressed = frame24("APIC", apic(red, type: 3), format: 0x08) + frame24("APIC", apic(blue, type: 4))
    expectEqual(A.id3Picture(header: header(4, size: compressed.count), tag: compressed), blue, "嵌入封面 MP3: 压缩过的帧不读")
    let extended = bigEndian(6, 4) + [0, 0, 0, 0, 0, 0] + frame23("APIC", apic(red, type: 3))
    expectEqual(A.id3Picture(header: header(3, size: extended.count, flags: 0x40), tag: extended), red, "嵌入封面 MP3: 跳过扩展头")
    expectEqual(A.id3Picture(header: header(3, size: title.count), tag: title), nil, "嵌入封面 MP3: 没有 APIC")
    let corrupt = frame23("APIC", apic(broken, type: 3))
    expectEqual(A.id3Picture(header: header(3, size: corrupt.count), tag: corrupt), nil, "嵌入封面 MP3: 封面坏了当没有")
    let truncated = Array(frame23("APIC", apic(red, type: 3)).dropLast(10))
    expectEqual(A.id3Picture(header: header(3, size: truncated.count), tag: truncated), nil, "嵌入封面 MP3: 帧长超出标签区不读")

    // ---- FLAC:PICTURE 块 ----
    func pictureBlock(_ picture: [UInt8], type: UInt32) -> [UInt8] {
        let mime = Array("image/png".utf8), description = Array("front".utf8)
        return bigEndian(Int(type), 4) + bigEndian(mime.count, 4) + mime + bigEndian(description.count, 4) + description
            + Array(repeating: 0, count: 16) + bigEndian(picture.count, 4) + picture
    }
    expectEqual(A.flacPictureBlock(pictureBlock(red, type: 3)).map { [$0.type: $0.data] }, [3: red], "嵌入封面 FLAC: 解 PICTURE 块")
    expectEqual(A.flacPictureBlock(Array(pictureBlock(red, type: 3).dropLast(1))) == nil, true, "嵌入封面 FLAC: 数据长度超出块不读")
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
    expectEqual(A.mp4Picture(moov: moov(covr([red]))), red, "嵌入封面 M4A: meta 带版本与标志")
    expectEqual(A.mp4Picture(moov: moov(covr([red]), fullBox: false)), red, "嵌入封面 M4A: QuickTime 写法的 meta")
    expectEqual(A.mp4Picture(moov: moov(covr([broken, blue]))), blue, "嵌入封面 M4A: 第一张坏了取第二张")
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
    let ftyp = box("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0] + Array("M4A mp42isom".utf8))
    let mdat = box("mdat", Array(repeating: 0x21, count: 4096))
    expectEqual(read(write("song.m4a", ftyp + mdat + box("moov", moov(covr([red]))))), red, "嵌入封面 文件: M4A,moov 在 mdat 后面")
    expectEqual(A.read(path: write("plain.m4a", ftyp + box("moov", moov([])) + mdat)) == nil, true, "嵌入封面 文件: M4A 没有封面")
    expectEqual(A.read(path: write("corrupt.m4a", ftyp + box("moov", moov(covr([broken]))))) == nil, true, "嵌入封面 文件: M4A 封面坏了")
    expectEqual(A.read(path: write("missing-dir/none.mp3", [])) == nil, true, "嵌入封面 文件: 文件不存在")

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

    // ---- 接线(契约):系统没给封面的四个退路都走 fileCover ----
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let client = (try? String(contentsOf: root.appendingPathComponent("LyrimuseCore/Local/MediaControlClient.swift"), encoding: .utf8)) ?? ""
    expectEqual(sourceCount(client, "PlayerTitleSplit.fileCover(forAudioFile: path)"), 4,
                "文件自带的封面 接线: 系统封面为空、占位图、VOX、Audirvana 四处都用 fileCover")
    expectEqual(sourceHas(client, "folderCover(forAudioFile:"), false, "文件自带的封面 接线: 不再只找同目录的图")
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
