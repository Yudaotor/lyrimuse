import Foundation

/// 有上限的「原串 → 结果」记忆表:记满 limit 条就整表清空重来。加锁,哪个线程都能用。只给纯函数用(结果只取决于
/// 输入),不然记住的会过期。
public final class BoundedMemo<Value>: @unchecked Sendable {
    public let limit: Int
    private let lock = NSLock()
    private var table: [String: Value] = [:]

    public init(limit: Int) {
        self.limit = limit
    }

    /// 记过就直接给,没记过用 compute 算一次再记。compute 在锁外跑,两个线程同时算同一个 key 只是多算一次。
    public func value(for key: String, compute: (String) -> Value) -> Value {
        lock.lock()
        let hit = table[key]
        lock.unlock()
        if let hit { return hit }
        let value = compute(key)
        lock.lock()
        if table.count >= limit { table.removeAll(keepingCapacity: true) }
        table[key] = value
        lock.unlock()
        return value
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return table.count
    }
}
