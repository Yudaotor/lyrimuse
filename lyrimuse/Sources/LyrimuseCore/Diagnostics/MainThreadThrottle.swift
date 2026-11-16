import CoreGraphics
import Darwin
import Foundation

/// 主线程这会儿是不是被系统压着跑:屏幕锁着,或者主线程的调度优先级落到了后台档(App Nap、后台节流把整个进程压到 4)。
/// 这时主线程空着也要隔好几秒才轮到一次,看门狗量到的停顿不是 App 自己卡住的,遥测照报但打上标记。见 14 章决策 202。
public enum MainThreadThrottle {
    public static let locked = "locked"
    public static let lowPriority = "low_priority"
    /// Worker(telemetry-worker/src/index.js 的 HANG_THROTTLE)认的取值,两处一起改。
    public static let reasons = [locked, lowPriority]
    /// 后台档的调度优先级;主线程平常在 31～47。
    public static let lowPriorityCeiling: Int32 = 4

    /// 一次读数。`priority` 是主线程当前优先级与基础优先级里小的那个,读不到为 nil。
    public struct Reading: Equatable, Sendable {
        public var screenLocked: Bool
        public var priority: Int32?

        public init(screenLocked: Bool, priority: Int32?) {
            self.screenLocked = screenLocked
            self.priority = priority
        }

        /// 锁着屏记 `locked`,优先级不高于 `lowPriorityCeiling` 记 `lowPriority`;读不到优先级的不算低。
        public var reasons: Set<String> {
            var out = Set<String>()
            if screenLocked { out.insert(MainThreadThrottle.locked) }
            if let priority, priority <= MainThreadThrottle.lowPriorityCeiling { out.insert(MainThreadThrottle.lowPriority) }
            return out
        }

        /// 调试深链造的读数:`reason` 是 `reasons` 里的一个。
        public init?(simulating reason: String) {
            switch reason {
            case MainThreadThrottle.locked: self.init(screenLocked: true, priority: nil)
            case MainThreadThrottle.lowPriority: self.init(screenLocked: false, priority: MainThreadThrottle.lowPriorityCeiling)
            default: return nil
            }
        }
    }

    /// 给日志用的一段:`locked,low_priority`,没有为空串。
    public static func describe(_ reasons: Set<String>) -> String {
        reasons.sorted().joined(separator: ",")
    }

    /// 日志行尾的说明:` (throttled: locked,low_priority; main thread priority 4)`;`reasons` 为空时是空串。
    public static func logNote(_ reasons: Set<String>, priority: Int32?) -> String {
        guard !reasons.isEmpty else { return "" }
        return " (throttled: \(describe(reasons))\(priority.map { "; main thread priority \($0)" } ?? ""))"
    }

    /// 读这一刻的状态。`thread` 是要看的那条线程的 mach 端口(看门狗传主线程的),可以在别的线程上读。
    public static func read(thread: mach_port_t?) -> Reading {
        Reading(screenLocked: screenIsLocked(), priority: thread.flatMap(priority(ofThread:)))
    }

    /// 在主线程上调:读主线程自己。
    public static func readOnCurrentThread() -> Reading {
        read(thread: pthread_mach_thread_np(pthread_self()))
    }

    /// 会话字典里没有 `CGSSessionScreenIsLocked` 这一项就是没锁(解锁状态下这一项不存在)。
    public static func screenIsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// `THREAD_EXTENDED_INFO` 的当前优先级与基础优先级取小的;读不到为 nil。
    public static func priority(ofThread port: mach_port_t) -> Int32? {
        var info = thread_extended_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return min(info.pth_curpri, info.pth_priority)
    }
}
