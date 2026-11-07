import Foundation

public extension NSString {
    /// 范围在字符串里才取子串,否则 nil。`substring(with:)` 越界(负长度转 NSRange 后也是越界)抛 NSRangeException,Swift 接不住;
    /// 偏移来自另一份字符串、或靠上游「同一份 UTF-16 偏移」这种不变量撑着的地方用它。见 15 章决策 105。
    func substringIfInBounds(location: Int, length: Int) -> String? {
        guard location >= 0, length >= 0, location <= self.length, length <= self.length - location else { return nil }
        return substring(with: NSRange(location: location, length: length))
    }
}
