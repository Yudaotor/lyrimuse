import Foundation
import os

/// 问播放器的脚本读数卡住后的退避:问一家等满超时(它主线程卡住、或者被系统压着不调度)之后,这一家隔一段再问。
/// 不退避的话每一拍都等满超时,那一家的常驻 osascript 每拍被杀掉重开,杀掉之前发出去的那条还留在它的队列里。
/// 只对实测会卡很久的几家开(`players`),它们的脚本读数缺几拍有别的来源顶着;见 02 章决策 258。
public enum PlayerScriptStall {
    /// 开退避的常驻 osascript 请求名:Audirvana 换输出设备时主线程会停 20 秒不收 Apple Event,Swinsian 被系统节流时
    /// 一次应答要十几秒。
    public static let players: Set<String> = ["audirvana", "swinsian"]

    /// 卡住之后隔多久再问。
    public static let backoffSecs: TimeInterval = 20

    private static let retryAt = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])

    /// 这一次问它算不算卡住:没问成、而且耗时到了超时的九成。没在跑、停住这种很快回 `null` 的不算。纯函数,selftest 覆盖。
    public static func stalled(succeeded: Bool, elapsed: TimeInterval, timeout: TimeInterval) -> Bool {
        !succeeded && elapsed >= timeout * 0.9
    }

    /// 这一家此刻在退避中(上一次卡住还没过 `backoffSecs`)。
    public static func backingOff(_ name: String, now: Date = Date()) -> Bool {
        retryAt.withLock { $0[name].map { now < $0 } ?? false }
    }

    /// 记一次读数结果;卡住了就从 `now` 起退避,交回 true。不在 `players` 里的一律不记。
    @discardableResult
    public static func note(_ name: String, succeeded: Bool, elapsed: TimeInterval, timeout: TimeInterval,
                            now: Date = Date()) -> Bool {
        guard players.contains(name), stalled(succeeded: succeeded, elapsed: elapsed, timeout: timeout) else { return false }
        retryAt.withLock { $0[name] = now.addingTimeInterval(backoffSecs) }
        return true
    }

    /// 清掉某一家的退避(selftest 用)。
    public static func clear(_ name: String) {
        retryAt.withLock { $0[name] = nil }
    }
}
