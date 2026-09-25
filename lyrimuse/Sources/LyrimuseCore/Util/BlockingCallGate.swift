import Foundation

/// 把一个可能无限期阻塞的同步调用挪到专用线程上跑,调用方按超时拿结果、不陪它卡住。
///
/// 硬约束:
/// - 被包的调用只在自己的 GCD 队列上跑,别改成 `Task.detached` / `withTaskGroup` 子任务。
///   Swift 协作线程池宽度等于 CPU 核数、卡住的线程不会被补,占满以后所有 async 代码
///   (包括计时用的 `Task.sleep`)一起停摆;GCD 队列的线程被内核阻塞时会另起新线程。
/// - 同一个 key 同一时刻只有一次调用在飞;在飞期间再来的请求挂在它后面等同一个结果,
///   不另起线程。卡死时被占住的线程数以 key 的个数为上限。
/// - 超时只让这一个等待者拿到 nil,不取消底下那次调用;它迟早返回时,还在等的人照常拿结果,
///   之后同一个 key 的下一次请求才会重新发起调用。
/// - `completion` 在后台线程回调,调用方自己切回需要的线程。
public final class BlockingCallGate<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    public typealias Completion = @Sendable (Value?) -> Void

    private struct Waiter {
        let id: UInt64
        let completion: Completion
    }

    private let queue: DispatchQueue
    private let timerQueue: DispatchQueue
    private let lock = NSLock()
    /// key 在表里 = 这个 key 有一次调用在飞(等待者可能已全部超时、列表为空)。
    private var waiters: [Key: [Waiter]] = [:]
    private var nextID: UInt64 = 0

    public init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos, attributes: .concurrent)
        timerQueue = DispatchQueue(label: label + ".timeout", qos: qos)
    }

    public func run(key: Key, timeout: TimeInterval,
                    work: @escaping @Sendable () -> Value,
                    completion: @escaping Completion) {
        lock.lock()
        let id = nextID
        nextID &+= 1
        let startsCall = waiters[key] == nil
        waiters[key, default: []].append(Waiter(id: id, completion: completion))
        lock.unlock()

        if startsCall {
            queue.async { [self] in
                let value = work()
                lock.lock()
                let pending = waiters.removeValue(forKey: key) ?? []
                lock.unlock()
                for waiter in pending { waiter.completion(value) }
            }
        }

        timerQueue.asyncAfter(deadline: .now() + timeout) { [self] in
            lock.lock()
            var expired: Waiter?
            if var list = waiters[key], let index = list.firstIndex(where: { $0.id == id }) {
                expired = list.remove(at: index)
                waiters[key] = list
            }
            lock.unlock()
            expired?.completion(nil)
        }
    }

    /// 这个 key 眼下有没有一次调用在飞(含等待者都已超时、调用本身还没返回的情况)。
    public func isInFlight(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiters[key] != nil
    }
}
