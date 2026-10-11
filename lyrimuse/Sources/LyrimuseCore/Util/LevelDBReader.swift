import Foundation

/// 只读地取别的 App 正在用的 LevelDB 里一类 key 的当前值(Amazon Music 的资料库)。照引擎 `leveldbread.go` 的读法:
/// 不开库、不抢锁,按文件格式读 .ldb / .log 原始字节;同一个 key 在几个文件里各有一版时取 sequence 最大的那条,
/// 它是删除标记就当不存在。不读 MANIFEST:已经合并掉、还没删的旧文件里的版本 sequence 一定更小,自然被盖掉。
/// 每个文件整份读进来、每个数据块都解,只适合小库。读的途中文件被合并掉、写到一半都是常态:单个文件读失败就跳过。
/// 不校验 CRC;所有长度都先跟剩余字节比再取,坏文件只会读不出,不会越界。
/// 格式依据:LevelDB 的 table_format.md / log_format.md;Snappy 的 format_description.txt。
public enum LevelDBReader {
    /// 单个文件的读入上限,防文件异常膨胀,不是格式约束。
    static let maxFileBytes = 64 << 20

    struct Version {
        let sequence: UInt64
        /// nil = 删除标记。
        let value: [UInt8]?
    }

    /// `directory` 里 user key 满足 `match` 的当前值;已删除的不在结果里。目录读不到为空。
    public static func scan(directory: String, match: ([UInt8]) -> Bool) -> [[UInt8]: [UInt8]] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [:] }
        var best: [[UInt8]: Version] = [:]
        let keep: ([UInt8], Version) -> Void = { key, version in
            if let current = best[key], current.sequence >= version.sequence { return }
            best[key] = version
        }
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let bytes = readFile(path) else { continue }
            if name.hasSuffix(".ldb") || name.hasSuffix(".sst") {
                scanTable(bytes, match: match, keep: keep)
            } else if name.hasSuffix(".log") {
                scanLog(bytes, match: match, keep: keep)
            }
        }
        return best.compactMapValues { $0.value }
    }

    static func readFile(_ path: String) -> [UInt8]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size <= maxFileBytes,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return [UInt8](data)
    }

    // MARK: - 编码

    /// 从 `i` 起读一个 varint,不越过 `end`;读不完整为 nil。
    static func uvarint(_ b: [UInt8], _ i: inout Int, end: Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < end, i < b.count {
            let c = b[i]
            i += 1
            guard shift < 64 else { return nil }
            result |= UInt64(c & 0x7f) << shift
            if c < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    /// 调用方保证 `at + 4 <= b.count`。
    static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[at + $1]) << (8 * UInt32($1)) }
    }

    /// 调用方保证 `at + 8 <= b.count`。
    static func le64(_ b: [UInt8], _ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[at + $1]) << (8 * UInt64($1)) }
    }

    /// internal key = user key + 8 字节 tag(sequence << 8 | 类型,类型 0 是删除)。
    static func splitInternalKey(_ key: [UInt8]) -> (user: [UInt8], sequence: UInt64, deleted: Bool)? {
        guard key.count >= 8 else { return nil }
        let tag = le64(key, key.count - 8)
        return (Array(key[..<(key.count - 8)]), tag >> 8, tag & 0xff == 0)
    }

    // MARK: - SSTable

    static func scanTable(_ b: [UInt8], match: ([UInt8]) -> Bool, keep: ([UInt8], Version) -> Void) {
        guard b.count >= 48 else { return }
        let footer = b.count - 48
        guard le64(b, footer + 40) == 0xdb47_7524_8b80_fb57 else { return }
        var p = footer
        // 先是 metaindex 的位置(用不上),再是索引块的位置。
        guard uvarint(b, &p, end: b.count) != nil, uvarint(b, &p, end: b.count) != nil,
              let indexOffset = uvarint(b, &p, end: b.count), let indexSize = uvarint(b, &p, end: b.count),
              let index = block(b, offset: indexOffset, size: indexSize) else { return }
        blockEntries(index) { _, handle in
            var q = 0
            guard let offset = uvarint(handle, &q, end: handle.count), let size = uvarint(handle, &q, end: handle.count),
                  let data = block(b, offset: offset, size: size) else { return true }
            blockEntries(data) { key, value in
                if let parts = splitInternalKey(key), match(parts.user) {
                    keep(parts.user, Version(sequence: parts.sequence, value: parts.deleted ? nil : value))
                }
                return true
            }
            return true
        }
    }

    /// 按位置取一个块:块后面跟 1 字节压缩类型(0 不压缩、1 Snappy)+ 4 字节 CRC。
    static func block(_ b: [UInt8], offset: UInt64, size: UInt64) -> [UInt8]? {
        guard size <= UInt64(maxFileBytes), offset <= UInt64(b.count), size + 5 <= UInt64(b.count) - offset else { return nil }
        let start = Int(offset), end = start + Int(size)
        let raw = Array(b[start..<end])
        switch b[end] {
        case 0: return raw
        case 1: return snappyDecode(raw)
        default: return nil
        }
    }

    /// 遍历一个块的全部条目:key 前缀压缩,块尾是 restart 数组。`body` 返回 false 就停。
    static func blockEntries(_ b: [UInt8], _ body: ([UInt8], [UInt8]) -> Bool) {
        guard b.count >= 4 else { return }
        let restarts = Int(le32(b, b.count - 4))
        guard restarts <= (b.count - 4) / 4 else { return }
        let end = b.count - 4 - restarts * 4
        var key: [UInt8] = []
        var i = 0
        while i < end {
            guard let shared = uvarint(b, &i, end: end), let nonShared = uvarint(b, &i, end: end),
                  let valueLength = uvarint(b, &i, end: end),
                  shared <= UInt64(key.count), nonShared <= UInt64(end - i),
                  valueLength <= UInt64(end - i) - nonShared else { return }
            key = Array(key[..<Int(shared)]) + b[i..<(i + Int(nonShared))]
            i += Int(nonShared)
            let value = Array(b[i..<(i + Int(valueLength))])
            i += Int(valueLength)
            if !body(key, value) { return }
        }
    }

    // MARK: - 写前日志(.log)

    /// 32KB 一块,每条物理记录 7 字节头(CRC 4 + 长度 2 + 类型 1);FULL / FIRST + MIDDLE* + LAST 拼成一条 WriteBatch。
    static func scanLog(_ b: [UInt8], match: ([UInt8]) -> Bool, keep: ([UInt8], Version) -> Void) {
        let blockSize = 32768
        var record: [UInt8] = []
        var i = 0
        while i + 7 <= b.count {
            let left = blockSize - i % blockSize
            if left < 7 {
                i += left
                continue
            }
            let length = Int(b[i + 4]) | Int(b[i + 5]) << 8
            let type = b[i + 6]
            guard i + 7 + length <= b.count else { break }
            let payload = Array(b[(i + 7)..<(i + 7 + length)])
            i += 7 + length
            switch type {
            case 1: applyBatch(payload, match: match, keep: keep)
            case 2: record = payload
            case 3: record += payload
            case 4:
                record += payload
                applyBatch(record, match: match, keep: keep)
                record = []
            default: break
            }
        }
    }

    /// 一条 WriteBatch:8 字节起始 sequence + 4 字节条数 + 若干 (类型, key[, value]),类型 1 写入、0 删除。
    static func applyBatch(_ b: [UInt8], match: ([UInt8]) -> Bool, keep: ([UInt8], Version) -> Void) {
        guard b.count >= 12 else { return }
        let sequence = le64(b, 0)
        let count = le32(b, 8)
        var i = 12
        func slice() -> [UInt8]? {
            guard let n = uvarint(b, &i, end: b.count), n <= UInt64(b.count - i) else { return nil }
            defer { i += Int(n) }
            return Array(b[i..<(i + Int(n))])
        }
        var c: UInt32 = 0
        while c < count, i < b.count {
            let type = b[i]
            i += 1
            guard let key = slice() else { return }
            var value: [UInt8]?
            if type == 1 {
                guard let v = slice() else { return }
                value = v
            }
            if match(key) { keep(key, Version(sequence: sequence &+ UInt64(c), value: value)) }
            c += 1
        }
    }

    // MARK: - Snappy(块格式)

    /// 开头是解压后长度(varint),之后是 literal / copy 两类元素。声明的长度只当上限,超了就是坏块。
    public static func snappyDecode(_ src: [UInt8]) -> [UInt8]? {
        var i = 0
        guard let declared = uvarint(src, &i, end: src.count), declared <= UInt64(maxFileBytes) else { return nil }
        let n = Int(declared)
        var dst: [UInt8] = []
        dst.reserveCapacity(min(n, src.count * 4))
        while i < src.count {
            let tag = src[i]
            i += 1
            var length: Int
            var offset: Int
            switch tag & 3 {
            case 0:
                length = Int(tag >> 2)
                if length >= 60 {
                    let extra = length - 59
                    guard i + extra <= src.count else { return nil }
                    length = (0..<extra).reduce(0) { $0 | Int(src[i + $1]) << (8 * $1) }
                    i += extra
                }
                length += 1
                guard length <= src.count - i, dst.count + length <= n else { return nil }
                dst += src[i..<(i + length)]
                i += length
                continue
            case 1:
                guard i < src.count else { return nil }
                length = Int((tag >> 2) & 7) + 4
                offset = Int(tag >> 5) << 8 | Int(src[i])
                i += 1
            case 2:
                guard i + 2 <= src.count else { return nil }
                length = Int(tag >> 2) + 1
                offset = Int(src[i]) | Int(src[i + 1]) << 8
                i += 2
            default:
                guard i + 4 <= src.count else { return nil }
                length = Int(tag >> 2) + 1
                offset = Int(le32(src, i))
                i += 4
            }
            guard offset > 0, offset <= dst.count, dst.count + length <= n else { return nil }
            // 源和目标可能重叠(offset < length 是重复一段),逐字节拷。
            for _ in 0..<length { dst.append(dst[dst.count - offset]) }
        }
        return dst.count == n ? dst : nil
    }
}
