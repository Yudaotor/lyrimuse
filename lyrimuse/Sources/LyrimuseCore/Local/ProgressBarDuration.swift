import ApplicationServices
import Foundation
import os

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "progress-bar-duration")

/// 系统会话在放、却没有时长时,从播放器自己界面上的进度条补:进度条的最大值是它解码出来的时长。哪些播放器走这条由
/// `PlaybackPlayer.durationFromProgressBar` 定,只给实测见过「系统那份不报时长、进度条最大值是对的」的开。
///
/// 读到的进度条不一定是这一首、这一刻的,采用前过三道闸:
/// - 换歌后 `settleSecs` 之内不读,进度条可能还没换过来;
/// - 进度条当前值跟系统那份这一刻的位置差超过 `positionToleranceSecs`,或位置不知道,不认(`matchesPosition`):
///   界面整个停住时,系统那份换了好几首,读出来仍是同一首、同一个位置;
/// - 最大值跟上一首的时长差不到 `staleToleranceSecs` 不认(`accepts`):换歌后位置在走、长度没更新。
///
/// 状态按播放器分开记。要辅助功能权限,会阻塞跨进程调用,别在主线程调。见 02 章决策 244、02 章决策 245、02 章决策 247、
/// 02 章决策 249。
public enum ProgressBarDuration {
    /// 换歌后多久才信进度条。
    public static let settleSecs: TimeInterval = 1
    /// 跟上一首的时长差不到这么多,就当进度条还停在上一首。
    public static let staleToleranceSecs: Double = 0.5
    /// 进度条当前值跟这一刻的位置差得超过这么多,就当读到的不是这一刻的界面。
    public static let positionToleranceSecs: Double = 3

    /// 几根滑块里哪一根是进度条:从 0 起、最大值超过 1.5 秒的那一根(音量是 0~1);没有或不止一根为 nil。纯函数,selftest 覆盖。
    public static func progressSlider(_ sliders: [PineVolume.Slider]) -> PineVolume.Slider? {
        let hits = sliders.filter {
            $0.min == 0 && $0.max.isFinite && $0.max > 1.5 && $0.max < MediaControlSnapshot.endlessDurationSecs
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 进度条当前值跟系统那份这一刻的位置对不对得上;位置不知道时不认。纯函数,selftest 覆盖。
    public static func matchesPosition(barValue: Double, position: Double?) -> Bool {
        guard let position, position.isFinite else { return false }
        return abs(barValue - position) <= positionToleranceSecs
    }

    /// 进度条的最大值能不能当这一首的时长:`previous` 是上一首的时长(系统那份报的或进度条读到的),差不到
    /// `staleToleranceSecs` 的不认。纯函数,selftest 覆盖。
    public static func accepts(_ max: Double, previous: Double?) -> Bool {
        guard let previous else { return true }
        return abs(max - previous) >= staleToleranceSecs
    }

    private struct State {
        var firstSeen: (key: String, at: Date, previous: Double?)?
        var cached: (key: String, duration: Double)?
        /// 最近一首有时长的歌:换歌时它就是「上一首」(`accepts`)。
        var last: (key: String, duration: Double)?
        /// 这一首已经记过一行「不认」的日志,同一首不再重复记。
        var loggedRejection: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]

    /// 系统那份带着时长的读数:记下来,下一首拿它比进度条是不是还停在这一首。
    public static func noteDuration(bundleID: String, trackKey: String, duration: Double) {
        lock.lock()
        states[bundleID, default: State()].last = (trackKey, duration)
        lock.unlock()
    }

    /// 这一首的时长:同一首读到过就用记着的;刚换歌不到 `settleSecs`、读不到、读到的不认为 nil。`position` 是系统那份
    /// 这一刻的位置。`read` 交回这个播放器界面上的滑块,默认按辅助功能读(`sliders(bundleID:)`),selftest 换成假的。
    public static func duration(bundleID: String, trackKey: String, position: Double?, now: Date,
                                read: (String) -> [PineVolume.Slider] = sliders(bundleID:)) -> Double? {
        lock.lock()
        var state = states[bundleID, default: State()]
        if let cached = state.cached, cached.key == trackKey {
            lock.unlock()
            return cached.duration
        }
        if state.firstSeen?.key != trackKey {
            state.firstSeen = (trackKey, now, state.last.flatMap { $0.key == trackKey ? nil : $0.duration })
            states[bundleID] = state
        }
        let ready = now.timeIntervalSince(state.firstSeen?.at ?? now) >= settleSecs
        let previous = state.firstSeen?.previous
        lock.unlock()
        guard ready, let bar = progressSlider(read(bundleID)) else { return nil }
        let fresh = matchesPosition(barValue: bar.value, position: position)
        guard fresh, accepts(bar.max, previous: previous) else {
            lock.lock()
            let first = states[bundleID]?.loggedRejection != trackKey
            states[bundleID, default: State()].loggedRejection = trackKey
            lock.unlock()
            if first {
                let reason = fresh ? "still the previous song's length" : "out of step with the session position"
                logger.notice("progress bar not used for \(bundleID, privacy: .public) (\(reason, privacy: .public)): max=\(bar.max, format: .fixed(precision: 3)) value=\(bar.value, format: .fixed(precision: 3)) position=\(position ?? -1, format: .fixed(precision: 3)) previous=\(previous ?? -1, format: .fixed(precision: 3))")
            }
            return nil
        }
        lock.lock()
        states[bundleID, default: State()].cached = (trackKey, bar.max)
        states[bundleID, default: State()].last = (trackKey, bar.max)
        lock.unlock()
        return bar.max
    }

    /// 单问那份这一刻的位置:带着读数时刻的(各播放器换过自己的钟)就是 `elapsedTime`;没带的在放时按锚点外推到 `now`。
    /// 纯函数,selftest 覆盖。
    public static func probedPosition(_ snapshot: MediaControlSnapshot, anchorTimestamp: Double?, now: Date) -> Double? {
        if snapshot.capturedAt != nil { return snapshot.elapsedTime }
        guard let elapsed = snapshot.anchorElapsedTime ?? snapshot.elapsedTime else { return nil }
        guard snapshot.playing == true, let anchorTimestamp else { return elapsed }
        let rate = snapshot.playbackRate ?? 1
        return elapsed + rate * max(0, now.timeIntervalSince1970 - anchorTimestamp)
    }

    /// 读滑块的层数和个数上限:进度条在窗口里几层之内,别把整棵界面树走一遍。
    private static let maxDepth = 4
    private static let maxElements = 400

    /// 这个播放器各窗口里的滑块(从窗口往下按层找,哪一层先找到就停在那一层);没授辅助功能、播放器没开为空。
    public static func sliders(bundleID: String) -> [PineVolume.Slider] {
        guard AXIsProcessTrusted(), let pid = PlayerProcess.pid(bundleID: bundleID) else { return [] }
        let app = MenuBarAX.timed(AXUIElementCreateApplication(pid), timeout: PineVolume.axTimeout)
        for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute, timeout: PineVolume.axTimeout) {
            var level = [window]
            var visited = 0
            for _ in 0..<maxDepth where !level.isEmpty && visited < maxElements {
                var next: [AXUIElement] = []
                var found: [PineVolume.Slider] = []
                for parent in level {
                    for element in MenuBarAX.children(parent, timeout: PineVolume.axTimeout) {
                        visited += 1
                        if (FoobarSliders.attribute(element, kAXRoleAttribute) as? String) == kAXSliderRole {
                            if let min = (FoobarSliders.attribute(element, kAXMinValueAttribute) as? NSNumber)?.doubleValue,
                               let max = (FoobarSliders.attribute(element, kAXMaxValueAttribute) as? NSNumber)?.doubleValue,
                               let value = (FoobarSliders.attribute(element, kAXValueAttribute) as? NSNumber)?.doubleValue {
                                found.append(PineVolume.Slider(min: min, max: max, value: value))
                            }
                        } else {
                            next.append(element)
                        }
                    }
                }
                if !found.isEmpty { return found }
                level = next
            }
        }
        return []
    }
}
