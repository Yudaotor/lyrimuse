import Darwin
import Foundation

/// 一次停顿里主线程用掉的 CPU 时间:接近停顿时长是主线程在忙着算,接近 0 是它在等(等 WindowServer、等锁、等回复),
/// 或者轮不到 CPU。看门狗投探测时记一次累计值,报卡顿时、恢复时取差值。见 14 章决策 238。
public enum MainThreadCPU {
    /// 上限(毫秒),多出来的按上限报。Worker(telemetry-worker/src/index.js 的 MAX_HANG_MAIN_CPU_MS)同值,两处一起改。
    public static let maxMilliseconds = 3_600_000

    /// 线程到现在为止累计的 CPU 时间(`THREAD_BASIC_INFO` 的 user + system,微秒);端口为 nil 或读不到为 nil。
    /// 看门狗在自己的队列上读主线程用 `start()` 时记下的端口(`pthread_mach_thread_np`)。
    public static func readMicroseconds(thread: mach_port_t?) -> UInt64? {
        guard let thread else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return microseconds(info.user_time) + microseconds(info.system_time)
    }

    /// 当前线程累计的 CPU 时间(微秒),主线程执行到探测任务时读自己用。
    public static func readMicrosecondsOnCurrentThread() -> UInt64? {
        readMicroseconds(thread: pthread_mach_thread_np(pthread_self()))
    }

    /// 两次累计读数(微秒)之间的毫秒数:任一读不到、或读数倒退时为 nil;超过 `maxMilliseconds` 按上限。
    public static func millisecondsBetween(_ start: UInt64?, _ end: UInt64?) -> Int? {
        guard let start, let end, end >= start else { return nil }
        return Int(min((end - start) / 1_000, UInt64(maxMilliseconds)))
    }

    /// 日志行尾的说明:` (main thread CPU 4870 ms)`;读不到时是空串。
    public static func logNote(milliseconds: Int?) -> String {
        milliseconds.map { " (main thread CPU \($0) ms)" } ?? ""
    }

    /// `time_value_t`(秒 + 微秒)→ 微秒。
    public static func microseconds(_ time: time_value_t) -> UInt64 {
        UInt64(max(time.seconds, 0)) * 1_000_000 + UInt64(max(time.microseconds, 0))
    }
}
