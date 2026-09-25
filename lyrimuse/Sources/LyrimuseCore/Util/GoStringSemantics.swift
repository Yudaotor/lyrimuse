import Foundation

/// 按 Go 标准库口径处理字符串的几个基本操作,给「两侧必须逐字节算出同一个结果」的镜像逻辑用
/// (缓存 key、宽松 key、手动选词指纹、导出文件名)。
///
/// Swift 自带的对应写法在这些场景里会跟 Go 分歧,别换回去:
///   - `String.map` / `split` / `firstIndex(of:)` 按字素簇走,零宽连字(U+200C/U+200D)、组合符会跟
///     前一个字粘成一个 Character,按单个字符匹配永远匹配不上;Go 按 rune(= Unicode 标量)走;
///   - `.whitespacesAndNewlines` 把 U+200B 也当空白,Go 的 `unicode.IsSpace` 不认;
///   - `lowercased()` 是完整大小写映射(`İ` 变两个标量),Go 的 `strings.ToLower` 逐 rune 取简单映射。
public enum GoStringSemantics {
    /// Go `unicode.IsSpace`:Unicode White_Space 属性。
    @inline(__always)
    public static func isSpace(_ u: Unicode.Scalar) -> Bool {
        u.properties.isWhitespace
    }

    /// Go `strings.TrimSpace`。
    public static func trimSpace(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isSpace($0) })!
        return String(scalars[first...last])
    }

    /// Go `strings.TrimSpace`,作用在一段标量上。
    public static func trimSpace(_ s: Substring.UnicodeScalarView) -> String {
        guard let first = s.firstIndex(where: { !isSpace($0) }) else { return "" }
        let last = s.lastIndex(where: { !isSpace($0) })!
        return String(String.UnicodeScalarView(s[first...last]))
    }

    /// Go `unicode.ToLower` 对单个 rune 的结果(简单映射,不看上下文)。
    public static func toLower(_ u: Unicode.Scalar) -> Unicode.Scalar {
        // 完整映射多于一个标量的只有 U+0130,Go 的简单映射给的是 U+0069。
        if u == "\u{0130}" { return "i" }
        let mapped = u.properties.lowercaseMapping.unicodeScalars
        return mapped.count == 1 ? mapped.first! : u
    }

    /// Go `strings.Contains`:按字节找子串。Swift 的 `String.contains` 按字素簇和规范等价比较,
    /// 子串后面跟着组合符时两边会分歧。
    public static func contains(_ s: String, _ sub: String) -> Bool {
        let hay = Array(s.utf8), needle = Array(sub.utf8)
        if needle.isEmpty { return true }
        if needle.count > hay.count { return false }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if hay[i..<(i + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }

    /// Go `strings.ToLower`。
    public static func toLower(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars { out.append(toLower(u)) }
        return String(out)
    }
}
