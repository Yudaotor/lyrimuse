import Foundation

/// 按「代」留东西的缓存:每一轮(比如整张表重建一次)开头领一个代号,这一轮查到的、新放进去的都记在这一代名下;
/// 这一轮的结果用上之后调 `keep(generation:)`,只留这一代碰过的,更早的全部放掉。
///
/// 哪个线程都能调。查不到时在锁外现做,两个线程同时做同一个 key 时留先放进去的那一份、两边拿到同一个值。
public final class GenerationCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Key: (value: Value, generation: Int)] = [:]
    private var latest = 0

    public init() {}

    /// 开始新的一轮,返回它的代号(从 1 起递增)。
    public func nextGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        latest += 1
        return latest
    }

    public func value(for key: Key, generation: Int, make: () -> Value) -> Value {
        if let hit = touch(key, generation: generation) { return hit }
        let made = make()
        lock.lock()
        defer { lock.unlock() }
        if let raced = entries[key] {
            entries[key] = (raced.value, max(raced.generation, generation))
            return raced.value
        }
        entries[key] = (made, generation)
        return made
    }

    /// 只留 `generation` 这一代(和更晚的)碰过的。
    public func keep(generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.value.generation >= generation }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func touch(_ key: Key, generation: Int) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = entries[key] else { return nil }
        if hit.generation < generation { entries[key] = (hit.value, generation) }
        return hit.value
    }
}
