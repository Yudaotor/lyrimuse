import Darwin
import Foundation

/// 卡顿期间的内存情况:系统内存压力的档位(停顿期间看到的最紧的一档),和 App 进程在这段时间里的换页次数
/// (page-in:从磁盘或交换文件把内存页读回来)。栈顶只要几微秒的计算却卡了十几秒时,用它分辨是在等换页、机器内存紧,
/// 还是代码自己慢。看门狗在自己的队列上读,两样都是一次几微秒的系统调用,不经过主线程。见 14 章决策 222。
public enum HangMemory {
    public static let normal = "normal", warning = "warning", critical = "critical"
    /// 从松到紧。Worker(telemetry-worker/src/index.js 的 HANG_MEMORY_PRESSURE)认的取值,两处一起改。
    public static let pressureLevels = [normal, warning, critical]
    /// 换页次数的上限,多出来的按上限报。Worker 的 MAX_HANG_PAGEINS 同值,两处一起改。
    public static let maxPageins = 10_000_000

    /// `kern.memorystatus_vm_pressure_level` 的读数(1 / 2 / 4,跟 `DispatchSource` 内存压力事件是同一套)→ 档位;认不出为 nil。
    public static func pressureTag(kernelLevel: Int32) -> String? {
        switch kernelLevel {
        case 1: return normal
        case 2: return warning
        case 4: return critical
        default: return nil
        }
    }

    /// 两档里紧的那个;读不到的(nil、名单外的)不算。
    public static func tighter(_ a: String?, _ b: String?) -> String? {
        let rank = { (tag: String?) in tag.flatMap { pressureLevels.firstIndex(of: $0) } ?? -1 }
        let best = max(rank(a), rank(b))
        return best >= 0 ? pressureLevels[best] : nil
    }

    /// 两次累计读数之间的换页次数:任一读不到、或计数倒退时为 nil;超过 `maxPageins` 按上限。
    public static func pageinsBetween(_ start: UInt64?, _ end: UInt64?) -> Int? {
        guard let start, let end, end >= start else { return nil }
        return Int(min(end - start, UInt64(maxPageins)))
    }

    /// 日志行尾的说明:` (memory pressure warning, 120 page-ins)`;两样都没有时是空串。
    public static func logNote(pressure: String?, pageins: Int?) -> String {
        let parts = [pressure.map { "memory pressure \($0)" }, pageins.map { "\($0) page-ins" }].compactMap { $0 }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    /// 此刻系统内存压力的档位,读不到为 nil。
    public static func readPressure() -> String? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return pressureTag(kernelLevel: level)
    }

    /// 本进程到现在为止累计的换页次数(`TASK_EVENTS_INFO` 的 `pageins`),读不到为 nil。
    public static func readPageins() -> UInt64? {
        var info = task_events_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return UInt64(UInt32(bitPattern: info.pageins))
    }

    /// 一次探测期间的读数:投出时的换页累计,这期间看到过的最紧的内存压力,和 `/usr/bin/sample` 采栈造成的换页。
    public struct Stall: Equatable, Sendable {
        public var pageinsAtStart: UInt64?
        public private(set) var pressure: String?
        /// 采栈那几秒的换页次数:没采为 0;还在采、或读不到时为 nil(扣不出来)。采栈读目标进程的内存,换页记在 App 头上。
        public private(set) var samplePageins: Int? = 0

        public init(pageinsAtStart: UInt64? = nil, pressure: String? = nil) {
            self.pageinsAtStart = pageinsAtStart
            self.pressure = pressure
        }

        public mutating func observe(pressure reading: String?) {
            pressure = HangMemory.tighter(pressure, reading)
        }

        /// 从投出到读数 `now` 之间的换页次数。
        public func pageins(now: UInt64?) -> Int? {
            HangMemory.pageinsBetween(pageinsAtStart, now)
        }

        public mutating func sampleStarted() {
            samplePageins = nil
        }

        public mutating func sampleFinished(pageins: Int?) {
            samplePageins = pageins
        }

        /// 恢复时报的整段换页次数:扣掉采栈那几秒的(同一时段主线程自己的换页一起扣掉,只会少报);采栈还没跑完、
        /// 或它的换页读不到时为 nil,概况留着报卡顿时的那个数。
        public func pageinsExcludingSample(now: UInt64?) -> Int? {
            guard let sample = samplePageins, let total = pageins(now: now) else { return nil }
            return max(0, total - sample)
        }
    }
}
