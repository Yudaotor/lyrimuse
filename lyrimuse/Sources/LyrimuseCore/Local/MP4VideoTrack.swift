import Foundation

/// MP4 / QuickTime 文件里有没有画面轨:在顶层找 `moov`,在它里面按 `trak › mdia › hdlr` 读每条轨的处理类型,有 `vide` 就是。
/// 只读顶层盒子头和 `moov` 本身(`mdat` 跳过);`moov` 超过 `moovLimit` 不读、当没有。读不出(不是这种格式、截断)为 false。
public enum MP4VideoTrack {
    static let moovLimit: UInt64 = 16 << 20

    /// 会读盘,别在主线程调。
    public static func present(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        var offset: UInt64 = 0
        while offset + 8 <= size {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let head = try? handle.read(upToCount: 16),
                  let box = header([UInt8](head), remaining: size - offset) else { return false }
            if box.type == "moov" {
                let length = box.size - box.headerSize
                guard length <= moovLimit, (try? handle.seek(toOffset: offset + box.headerSize)) != nil,
                      let payload = try? handle.read(upToCount: Int(length)), UInt64(payload.count) == length else { return false }
                return moovHasVideo([UInt8](payload))
            }
            offset += box.size
        }
        return false
    }

    /// 盒子头:大小(含头;1 = 后面 8 字节是 64 位大小,0 = 到 `remaining` 为止)、类型、头长。比 8 字节短、大小比头还小或超出
    /// `remaining` 时为 nil。纯函数,selftest 覆盖。
    public static func header(_ bytes: [UInt8], remaining: UInt64) -> (size: UInt64, type: String, headerSize: UInt64)? {
        guard bytes.count >= 8 else { return nil }
        var size = bigEndian(bytes[0..<4])
        var headerSize: UInt64 = 8
        if size == 1 {
            guard bytes.count >= 16 else { return nil }
            size = bigEndian(bytes[8..<16])
            headerSize = 16
        } else if size == 0 {
            size = remaining
        }
        guard size >= headerSize, size <= remaining else { return nil }
        return (size, String(decoding: bytes[4..<8], as: UTF8.self), headerSize)
    }

    /// `moov` 的内容里有没有一条轨的 `hdlr` 处理类型是 `vide`(`hdlr` 内容依次是版本 1 字节、标志 3 字节、4 字节保留、
    /// 4 字节处理类型)。纯函数,selftest 覆盖。
    public static func moovHasVideo(_ moov: [UInt8]) -> Bool {
        children(moov[...]).contains { trak in
            trak.type == "trak" && children(trak.payload).contains { mdia in
                mdia.type == "mdia" && children(mdia.payload).contains { hdlr in
                    hdlr.type == "hdlr" && hdlr.payload.count >= 12
                        && String(decoding: hdlr.payload.dropFirst(8).prefix(4), as: UTF8.self) == "vide"
                }
            }
        }
    }

    /// 一段内容里依次排着的盒子;遇到不合法的头就停。
    static func children(_ bytes: ArraySlice<UInt8>) -> [(type: String, payload: ArraySlice<UInt8>)] {
        var out: [(type: String, payload: ArraySlice<UInt8>)] = []
        var i = bytes.startIndex
        while i + 8 <= bytes.endIndex {
            guard let box = header(Array(bytes[i..<min(i + 16, bytes.endIndex)]), remaining: UInt64(bytes.endIndex - i)) else { break }
            out.append((box.type, bytes[(i + Int(box.headerSize))..<(i + Int(box.size))]))
            i += Int(box.size)
        }
        return out
    }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
