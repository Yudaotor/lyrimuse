import Foundation

/// 按 mtime 缓存的一份小状态文件:文件没变时只是一次 stat,变了才重读重解。带锁,哪个线程都能读;
/// 界面上的观察器在后台读它、回主线程只拿结果(14 章决策 194)。
public final class MTimeCachedFile<Value: Sendable>: @unchecked Sendable {
    public let url: URL
    private let parse: @Sendable (Data) -> Value?
    private let lock = NSLock()
    private var mtime: Date?
    private var value: Value?

    public init(url: URL, parse: @escaping @Sendable (Data) -> Value?) {
        self.url = url
        self.parse = parse
    }

    /// 文件此刻的内容;不存在、读不出、解不开都是 nil。会碰磁盘,别在主线程调。
    public func read() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = FileIO.modificationDate(url) else {
            mtime = nil
            value = nil
            return nil
        }
        if current == mtime { return value }
        mtime = current
        value = FileIO.read(url).flatMap(parse)
        return value
    }
}

/// 主线程上派一次后台读、读完回主线程交结果。上一次还没回来就不再派(磁盘卡住时不堆积);每次按派出顺序编号,
/// 只采用比已采用的更新的那次,先派的读得慢也盖不掉后派的结果。写法同 `LastfmMirrorStatusWatcher`(14 章决策 194)。
@MainActor
public final class SingleFlightBackgroundRead<Value> {
    private var inFlight = false
    private var issued = 0
    private var applied = 0

    public init() {}

    /// 有一次后台读还没回来。
    public var isInFlight: Bool { inFlight }

    /// 在后台跑 `read`,回主线程把结果交给 `apply`。上一次还没回来时什么都不做,返回 false。
    @discardableResult
    public func start(priority: TaskPriority = .utility, read: @escaping @Sendable () -> Value,
                      apply: @escaping @MainActor (Value) -> Void) -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        issued += 1
        let ticket = issued
        let deliver = UncheckedBox(apply)
        Task.detached(priority: priority) { [weak self] in
            let value = UncheckedBox(read())
            await self?.finish(value.value, ticket: ticket, apply: deliver.value)
        }
        return true
    }

    /// 调用方刚在主线程上把结果改成了更新的值(删了文件、写了新请求):还在飞的那次作废。
    public func invalidate() {
        applied = issued
    }

    private func finish(_ value: Value, ticket: Int, apply: @MainActor (Value) -> Void) {
        inFlight = false
        guard ticket > applied else { return }
        applied = ticket
        apply(value)
    }
}

/// 把不是 Sendable 的值交给后台任务再交回来:读出来的值只在两头各被碰一次,不并发访问。
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
