import Foundation

/// 源码契约的宽松比对:源码和片段都把连续空白(空格、Tab、换行)压成一个空格,片段再去掉首尾空白,然后按字节找。
/// 缩进、断行变了不算违约 —— 给视图多套一层、整段缩进变了,钉着原文的断言不该红。要判「单独一行」「行首」这类版式的
/// 别用它,还用 contains / range(of:)。片段压完是空的返回 false。
func sourceHas<S: StringProtocol>(_ text: S, _ snippet: String) -> Bool {
    let needle = collapsedWhitespace(snippet.utf8, trim: true)
    guard !needle.isEmpty else { return false }
    return SourceMatchCache.shared.collapsed(String(text)).withUnsafeBufferPointer { hay in
        needle.withUnsafeBufferPointer { p in
            hay.count >= p.count && memmem(hay.baseAddress, hay.count, p.baseAddress, p.count) != nil
        }
    }
}

/// 把连续的空格 / Tab / 换行压成一个空格。trim 时去掉首尾空白。
private func collapsedWhitespace<C: Collection>(_ bytes: C, trim: Bool) -> [UInt8] where C.Element == UInt8 {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var pendingSpace = false
    for b in bytes {
        if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
            pendingSpace = true
            continue
        }
        if pendingSpace && !(trim && out.isEmpty) { out.append(0x20) }
        pendingSpace = false
        out.append(b)
    }
    if pendingSpace && !trim { out.append(0x20) }
    return out
}

/// 同一份源码文本压一次就记住:一个文件常被同一段里几十条断言比对。
private final class SourceMatchCache: @unchecked Sendable {
    static let shared = SourceMatchCache()
    private let lock = NSLock()
    private var memo: [String: [UInt8]] = [:]

    func collapsed(_ text: String) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = memo[text] { return hit }
        let value = collapsedWhitespace(text.utf8, trim: false)
        memo[text] = value
        return value
    }
}

/// 片段在源码里出现几次,比对口径同 sourceHas(不重叠地数)。片段压完是空的返回 0。
func sourceCount<S: StringProtocol>(_ text: S, _ snippet: String) -> Int {
    let needle = collapsedWhitespace(snippet.utf8, trim: true)
    guard !needle.isEmpty else { return 0 }
    return SourceMatchCache.shared.collapsed(String(text)).withUnsafeBufferPointer { hay in
        needle.withUnsafeBufferPointer { p in
            var count = 0
            var offset = 0
            while offset + p.count <= hay.count,
                  let hit = memmem(hay.baseAddress! + offset, hay.count - offset, p.baseAddress, p.count) {
                count += 1
                offset = hay.baseAddress!.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + p.count
            }
            return count
        }
    }
}

/// 从 `signature` 起、到它之后第一个 `{` 配对的 `}` 为止的那一段(含两头);找不到返回空串。按括号配对、不看缩进:
/// 函数挪进别的类型、外面多套一层,切出来的还是同一段。字符串字面量里的括号不另作处理。
func sourceBody<S: StringProtocol>(_ signature: String, in text: S) -> String {
    let text = String(text)
    guard let start = text.range(of: signature), let open = text[start.lowerBound...].firstIndex(of: "{") else { return "" }
    var depth = 0
    var i = open
    while i < text.endIndex {
        if text[i] == "{" {
            depth += 1
        } else if text[i] == "}" {
            depth -= 1
            if depth == 0 { return String(text[start.lowerBound...i]) }
        }
        i = text.index(after: i)
    }
    return ""
}
