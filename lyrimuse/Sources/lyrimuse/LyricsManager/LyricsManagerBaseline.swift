import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-manager")

/// 「歌词管理」改造前后的对比测量点。
///
/// 为什么单独开一个文件:这批埋点是**临时**的 —— 等
/// `docs/proposals/lyrics-manager-load-and-memory.md` 那个改造做完、三条轴的前后对比
/// 数据落定,整个文件连同调用点一起摘掉。散在各处的话摘不干净。
///
/// 为什么非量不可:那批加载优化被整批回退(「现在更差了」),直接原因
/// 就是**只量了开窗加载时间、交互手感一次没量**,而改动恰好影响交互。这次三条轴
/// (开窗 / 交互 / 内存)都要有改造前的基线数,否则改完没有东西可比,也就无法判断是真变好
/// 还是又一次"平均值变好、最难受的那几下变差"。
///
/// 日志前缀统一 `baseline:`,一条 predicate 就能把这批全捞出来:
/// ```
/// /usr/bin/log show --last 30m \
///   --predicate 'subsystem == "me.yudaotor.lyrimuse" AND category == "lyrics-manager"' \
///   --style compact | /usr/bin/grep baseline:
/// ```
enum LyricsManagerBaseline {
    /// 当前进程的常驻内存(MB)。读的是 `MACH_TASK_BASIC_INFO.resident_size`,跟
    /// `ps -o rss` 同一个口径,好跟外部观测对得上。
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }

    static func ms(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    /// 开窗那条轴。分段是为了能归因:读文件 / JSON 解析 / 建 Summary 三段里哪一段是大头,
    /// 直接决定改造该往哪使劲(预期是 parse 段占绝大多数)。
    static func logReload(bytes: Int, count: Int,
                          readMS: Double, parseMS: Double, buildMS: Double, totalMS: Double) {
        logger.notice("""
            baseline: reload bytes=\(bytes, privacy: .public) entries=\(count, privacy: .public) \
            read=\(readMS, format: .fixed(precision: 1), privacy: .public)ms \
            parse=\(parseMS, format: .fixed(precision: 1), privacy: .public)ms \
            build=\(buildMS, format: .fixed(precision: 1), privacy: .public)ms \
            total=\(totalMS, format: .fixed(precision: 1), privacy: .public)ms \
            rss=\(residentMB(), format: .fixed(precision: 0), privacy: .public)MB
            """)
    }

    /// 交互那条轴之一:筛选/搜索重算。只在**缓存未命中、真的重算了**时才记 —— 命中缓存
    /// 那条路一次 body 求值就走好几遍,记了会把日志刷爆、也没有信息量。
    static func logFilter(inCount: Int, outCount: Int, elapsedMS: Double) {
        logger.notice("""
            baseline: filter recompute in=\(inCount, privacy: .public) \
            out=\(outCount, privacy: .public) \
            took=\(elapsedMS, format: .fixed(precision: 1), privacy: .public)ms
            """)
    }

    /// 交互那条轴之二:点一条看详情。**这正是翻车的那一下** —— 当时惰性化
    /// 之后首次点候选要等异步加载,编辑框先清空再填,像"点了没反应"。基线必须把它量下来。
    static func logDetail(key: String, totalChars: Int, elapsedMS: Double) {
        logger.notice("""
            baseline: detail chars=\(totalChars, privacy: .public) \
            took=\(elapsedMS, format: .fixed(precision: 2), privacy: .public)ms \
            key=\(key, privacy: .private)
            """)
    }
}
