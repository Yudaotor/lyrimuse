import CryptoKit
import Foundation
import LyrimuseCore

// 逐码点跨语言对拍:读 collector 生成的 lyrimuse-collector/testdata/keyparity/sweep.txt,用 Swift 实现
// 重算每个窗口的哈希逐窗比对。文件格式、七段输出、上下文字符串必须跟 collector
// keyparitysweep_test.go 逐字一致,改一边必须改另一边。

@MainActor
func runKeyParitySweepTests() {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Sources/lyrimuse-selftest
        .deletingLastPathComponent()   // …/Sources
        .deletingLastPathComponent()   // …/lyrimuse
        .deletingLastPathComponent()   // 仓库根
        .appendingPathComponent("lyrimuse-collector/testdata/keyparity/sweep.txt")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        expectEqual(false, true, "逐码点对拍: 读不到 lyrimuse-collector/testdata/keyparity/sweep.txt")
        return
    }
    struct Window { let start: UInt32; let bitmap: [UInt8]; let want: String }
    var parsed: [Window] = []
    var mismatched: [String] = []
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: " ")
        guard fields.count == 3, let start = UInt32(fields[0], radix: 16),
              let bitmap = keyParityHexBytes(fields[1]), bitmap.count == 32 else {
            mismatched.append("格式错误: \(line.prefix(40))")
            continue
        }
        parsed.append(Window(start: start, bitmap: bitmap, want: String(fields[2])))
    }
    // 全是纯函数,逐窗口并行算:串行在 debug 构建下要十几秒。
    let results = KeyParitySweepResults(count: parsed.count)
    DispatchQueue.concurrentPerform(iterations: parsed.count) { idx in
        let w = parsed[idx]
        var hasher = SHA256()
        var n = 0
        for i in 0..<256 where w.bitmap[i / 8] & (1 << UInt8(i % 8)) != 0 {
            guard let u = Unicode.Scalar(w.start + UInt32(i)) else { continue }
            hasher.update(data: keyParitySweepRecord(u))
            n += 1
        }
        results.slots[idx] = (hasher.finalize().map { String(format: "%02x", $0) }.joined(), n)
    }
    var scalars = 0
    for (idx, w) in parsed.enumerated() {
        let (got, n) = results.slots[idx]
        scalars += n
        if got != w.want { mismatched.append(String(w.start, radix: 16)) }
    }
    let windows = parsed.count
    expectEqual(windows > 500 && scalars > 100_000, true,
                "逐码点对拍: 真的核过了(\(windows) 个窗口、\(scalars) 个码点)")
    expectEqual(mismatched, [],
                "逐码点对拍: 与 collector 不一致的窗口(起点十六进制)。定位单个码点:两边各跑 keyParitySweepRecord 逐个比")
}

/// 并行写结果用:每个下标只由一个工作线程写一次,读发生在 concurrentPerform 返回之后。
private final class KeyParitySweepResults: @unchecked Sendable {
    let slots: UnsafeMutableBufferPointer<(String, Int)>
    init(count: Int) {
        slots = .allocate(capacity: count)
        slots.initialize(repeating: ("", 0))
    }
    deinit {
        slots.deinitialize()
        slots.deallocate()
    }
}

/// 一个码点的七段输出,段之间 0x1F、记录末尾 0x1E。与 collector keyParitySweepRecord 逐字一致。
private func keyParitySweepRecord(_ scalar: Unicode.Scalar) -> Data {
    let u = String(scalar)
    let parts = [
        EnrichCacheKeys.cleanTag(" " + u + "A" + u + u + "B" + u),
        EnrichCacheKeys.looseKey(u + "Ab" + u + "|" + u),
        EnrichCacheKeys.normalizedTitle("T" + u + "(" + u + "x" + u + ")" + u),
        EnrichCacheKeys.normalizedTitle("T (" + u + "live)"),
        EnrichCacheKeys.sanitizeFilename(u + "a|b" + u),
        ManualPickLock.canonicalLyrics(u + "[00:01.00]" + u + "w" + u + "\n[" + u + "]x" + u),
        GoStringSemantics.toLower(u),
    ]
    var data = Data()
    for (i, p) in parts.enumerated() {
        if i > 0 { data.append(0x1F) }
        data.append(contentsOf: Array(p.utf8))
    }
    data.append(0x1E)
    return data
}

private func keyParityHexBytes(_ s: Substring) -> [UInt8]? {
    let chars = Array(s.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    var i = 0
    while i < chars.count {
        guard let b = UInt8(String(decoding: chars[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
        out.append(b)
        i += 2
    }
    return out
}
