import Foundation
import zlib

/// 缓存索引的增量刷新(见 15 章决策 25):按字节切出顶层对象的每一条 key / value,每条记 CRC32 + 长度,
/// 跟已解码那一版记下的比,只解码变了 / 新增的几条,删掉不见了的 key。没变的条目字节完全相同,所以结果跟对这一版整份
/// 解码相同。纯函数,在后台跑。
public enum EnrichIndexDiff {
    /// 一段字节的校验值:高 32 位 CRC32,低 32 位长度。
    public typealias Sum = UInt64

    /// 一版文件每条的校验值。键是 key 原文(没解转义的 JSON 字符串,含两边引号)的校验值。
    public struct Fingerprints: Sendable, Equatable {
        /// key 原文校验值 → value 原文校验值。
        public var values: [Sum: Sum]
        /// key 原文校验值 → 解码后的 key(删条目时用)。
        public var keys: [Sum: String]
    }

    /// 刷新一次的结果。
    public struct Refresh: Sendable {
        public let entries: [String: EnrichCacheEntry]
        /// nil = 这一版切不开(结构跟切分对不上),下一版只能再整份解。
        public let fingerprints: Fingerprints?
        /// 相对已解码那一版改了、新增、删掉的 key;nil = 整份解码的。
        public let changedKeys: Set<String>?
        /// 派生索引(宽松匹配、两份封面索引)的输入变了没有,见 `sameDerivedInputs`。
        public let derivedInputsChanged: Bool
        /// 本机别名推断(E1 / E2)的输入变了没有,见 `sameAliasInputs`。
        public let aliasInputsChanged: Bool
    }

    /// 改了的条数超过 max(这个数, 总条数的四分之一) 就整份解。
    static let maxChangedFloor = 2000

    /// 拿新的一版刷新:有已解码的那一版(条目 + 校验值表)就先试增量,不行再整份解;整份也解不开给 nil。
    public static func refresh(_ data: Data, entries: [String: EnrichCacheEntry]?, fingerprints: Fingerprints?) -> Refresh? {
        if let entries, let fingerprints, let r = incremental(data, entries: entries, fingerprints: fingerprints) { return r }
        return full(data)
    }

    /// 整份解码,顺带算出校验值表。
    public static func full(_ data: Data) -> Refresh? {
        guard let all = try? JSONDecoder().decode([String: EnrichCacheEntry].self, from: data) else { return nil }
        return Refresh(entries: all, fingerprints: fingerprints(of: data), changedKeys: nil,
                       derivedInputsChanged: true, aliasInputsChanged: true)
    }

    /// 一版文件的校验值表;切不开、或者有两条 key 解码后相同时给 nil。
    public static func fingerprints(of data: Data) -> Fingerprints? {
        data.withUnsafeBytes { raw -> Fingerprints? in
            guard let slots = slots(raw) else { return nil }
            var values: [Sum: Sum] = [:]
            var keys: [Sum: String] = [:]
            var decoded = Set<String>()
            values.reserveCapacity(slots.count)
            keys.reserveCapacity(slots.count)
            decoded.reserveCapacity(slots.count)
            for s in slots {
                guard values.updateValue(s.valueSum, forKey: s.keySum) == nil,
                      let key = decodeKey(raw, s.key), decoded.insert(key).inserted else { return nil }
                keys[s.keySum] = key
            }
            return Fingerprints(values: values, keys: keys)
        }
    }

    /// 增量刷新;做不了(切不开、key 撞了、改得太多、哪一条解不开)给 nil,由调用方整份解。
    public static func incremental(_ data: Data, entries: [String: EnrichCacheEntry], fingerprints old: Fingerprints) -> Refresh? {
        data.withUnsafeBytes { raw -> Refresh? in
            guard let slots = slots(raw) else { return nil }
            var values: [Sum: Sum] = [:]
            values.reserveCapacity(slots.count)
            var changed: [Slot] = []
            for s in slots {
                guard values.updateValue(s.valueSum, forKey: s.keySum) == nil else { return nil }
                if old.values[s.keySum] != s.valueSum { changed.append(s) }
            }
            guard changed.count <= max(maxChangedFloor, slots.count / 4) else { return nil }
            var next = entries
            var keys = old.keys
            var changedKeys = Set<String>()
            var derived = false, alias = false
            for s in changed {
                let isNew = old.values[s.keySum] == nil
                guard let key = decodeKey(raw, s.key), !(isNew && entries[key] != nil),
                      let entry = try? JSONDecoder().decode(EnrichCacheEntry.self,
                                                            from: Data(UnsafeRawBufferPointer(rebasing: raw[s.value])))
                else { return nil }
                if let prev = next[key] {
                    derived = derived || !sameDerivedInputs(prev, entry)
                    alias = alias || !sameAliasInputs(prev, entry)
                } else {
                    derived = true
                    alias = true
                }
                next[key] = entry
                keys[s.keySum] = key
                changedKeys.insert(key)
            }
            for sum in old.values.keys where values[sum] == nil {
                guard let key = keys.removeValue(forKey: sum) else { return nil }
                next.removeValue(forKey: key)
                changedKeys.insert(key)
                derived = true
                alias = true
            }
            return Refresh(entries: next, fingerprints: Fingerprints(values: values, keys: keys), changedKeys: changedKeys,
                           derivedInputsChanged: derived, aliasInputsChanged: alias)
        }
    }

    /// 派生索引的输入:`buildDerivedIndexes` 读的封面两项,加上 `betterEntry` 排序用的几项。改那两处的输入要同步改这里。
    static func sameDerivedInputs(_ a: EnrichCacheEntry, _ b: EnrichCacheEntry) -> Bool {
        a.coverURL == b.coverURL && a.coverAlbum == b.coverAlbum && a.manualLyrics == b.manualLyrics
            && a.hasLyrics == b.hasLyrics && a.lyricsScore == b.lyricsScore && a.hasWordTiming == b.hasWordTiming
            && a.ts == b.ts
    }

    /// 别名推断的输入:`computeLocalAliasTables` 从条目里取的几项(key 本身不会变)。改那边的输入要同步改这里。
    static func sameAliasInputs(_ a: EnrichCacheEntry, _ b: EnrichCacheEntry) -> Bool {
        a.neteaseURL == b.neteaseURL && a.qqMusicURL == b.qqMusicURL && a.durationSecs == b.durationSecs
            && a.resolvedDurationSecs == b.resolvedDurationSecs && a.hasLyrics == b.hasLyrics && a.bodyCRC == b.bodyCRC
            && a.lyrics == b.lyrics
    }

    // MARK: 切分

    struct Slot {
        /// key 原文的范围,含两边引号。
        let key: Range<Int>
        let value: Range<Int>
        let keySum: Sum
        let valueSum: Sum
    }

    static func sum(_ p: UnsafePointer<UInt8>, _ r: Range<Int>) -> Sum {
        Sum(crc32(0, p + r.lowerBound, uInt(r.count))) << 32 | Sum(UInt32(truncatingIfNeeded: r.count))
    }

    /// 解码一条 key 原文(含引号)。没有转义符的直接按 UTF-8 取,有的交给 JSONDecoder。
    static func decodeKey(_ raw: UnsafeRawBufferPointer, _ r: Range<Int>) -> String? {
        let inner = UnsafeRawBufferPointer(rebasing: raw[(r.lowerBound + 1)..<(r.upperBound - 1)])
        if !inner.contains(0x5C) { return String(decoding: inner, as: UTF8.self) }
        return try? JSONDecoder().decode(String.self, from: Data(UnsafeRawBufferPointer(rebasing: raw[r])))
    }

    @inline(__always) static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }

    /// 从开引号 `start` 跳到闭引号后一位;没闭合给 nil。用 memchr 找下一个引号,再数它前面连着几个反斜杠。
    static func skipString(_ p: UnsafePointer<UInt8>, _ n: Int, _ start: Int) -> Int? {
        var i = start + 1
        while i < n {
            guard let q = memchr(p + i, 0x22, n - i) else { return nil }
            let j = q.assumingMemoryBound(to: UInt8.self) - UnsafeMutablePointer(mutating: p)
            var k = j - 1, slashes = 0
            while k > start, p[k] == 0x5C { slashes += 1; k -= 1 }
            if slashes % 2 == 0 { return j + 1 }
            i = j + 1
        }
        return nil
    }

    /// 顶层对象逐条切开;不是一个完整的 JSON 对象(截断、尾部多出字节、少了冒号逗号)给 nil。value 只按括号配对
    /// 找边界,内容对不对留给解码那一步。
    static func slots(_ raw: UnsafeRawBufferPointer) -> [Slot]? {
        guard let base = raw.baseAddress else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let n = raw.count
        var i = 0
        func ws() { while i < n, isSpace(p[i]) { i += 1 } }
        ws()
        guard i < n, p[i] == 0x7B else { return nil }
        i += 1
        ws()
        var out: [Slot] = []
        out.reserveCapacity(16384)
        if i < n, p[i] == 0x7D {
            i += 1
            ws()
            return i == n ? out : nil
        }
        while true {
            ws()
            guard i < n, p[i] == 0x22, let ke = skipString(p, n, i) else { return nil }
            let ks = i
            i = ke
            ws()
            guard i < n, p[i] == 0x3A else { return nil }
            i += 1
            ws()
            guard i < n else { return nil }
            let vs = i
            let c = p[i]
            if c == 0x22 {
                guard let e = skipString(p, n, i) else { return nil }
                i = e
            } else if c == 0x7B || c == 0x5B {
                var depth = 0
                while i < n {
                    let d = p[i]
                    if d == 0x22 {
                        guard let e = skipString(p, n, i) else { return nil }
                        i = e
                        continue
                    }
                    if d == 0x7B || d == 0x5B {
                        depth += 1
                    } else if d == 0x7D || d == 0x5D {
                        depth -= 1
                        if depth == 0 { i += 1; break }
                    }
                    i += 1
                }
                guard depth == 0 else { return nil }
            } else {
                while i < n, !(p[i] == 0x2C || p[i] == 0x7D || isSpace(p[i])) { i += 1 }
                guard i > vs else { return nil }
            }
            out.append(Slot(key: ks..<ke, value: vs..<i, keySum: sum(p, ks..<ke), valueSum: sum(p, vs..<i)))
            ws()
            guard i < n else { return nil }
            if p[i] == 0x2C { i += 1; continue }
            if p[i] == 0x7D { i += 1; break }
            return nil
        }
        ws()
        return i == n ? out : nil
    }
}
