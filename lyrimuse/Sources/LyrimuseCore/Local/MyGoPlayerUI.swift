import ApplicationServices
import Foundation
import os

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "mygo-ui")

/// MyGo Music 推给系统的会话里,时长取的是音源报的那个;有的插件报 0(按文件大小算长度的流),系统那份就一直没有时长,
/// 位置也就一直算不了。它自己界面上进度条的最大值是解码得出的时长(带小数),在放、系统那份没有时长时从这里补。
/// 要辅助功能权限;窗口关着(只留菜单栏图标)时读不到。换歌后 `settleSecs` 之内进度条可能还是上一首的,这段不读;
/// 有的流它换歌后进度条一直停在上一首的长度,跟上一首时长一样的读数不认(`accepts`);它的辅助功能界面还会整个停住
/// (系统那份换了好几首,读出来仍是同一首、同一个位置),进度条当前值跟这一刻的位置对不上的读数不认(`matchesPosition`)。
/// 会阻塞跨进程调用,别在主线程调。见 02 章决策 244、02 章决策 245、02 章决策 247。
public enum MyGoPlayerUI {
    /// 换歌后多久才信进度条。
    public static let settleSecs: TimeInterval = 1

    /// 几根滑块里哪一根是进度条:从 0 起、最大值超过 1.5 秒的那一根(音量是 0~1);没有或不止一根为 nil。纯函数,selftest 覆盖。
    public static func progressSlider(_ sliders: [PineVolume.Slider]) -> PineVolume.Slider? {
        let hits = sliders.filter {
            $0.min == 0 && $0.max.isFinite && $0.max > 1.5 && $0.max < MediaControlSnapshot.endlessDurationSecs
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 进度条的最大值,见 `progressSlider`。
    public static func progressMax(_ sliders: [PineVolume.Slider]) -> Double? {
        progressSlider(sliders)?.max
    }

    /// 进度条当前值跟这一刻的位置差得超过这么多,就当读到的不是这一刻的界面。
    public static let positionToleranceSecs: Double = 3

    /// 进度条当前值跟系统那份这一刻的位置对不对得上;位置不知道时不认。纯函数,selftest 覆盖。
    public static func matchesPosition(barValue: Double, position: Double?) -> Bool {
        guard let position, position.isFinite else { return false }
        return abs(barValue - position) <= positionToleranceSecs
    }

    /// 跟上一首的时长差不到这么多,就当进度条还停在上一首。
    public static let staleToleranceSecs: Double = 0.5

    /// 进度条读到的最大值能不能当这一首的时长:`previous` 是上一首的时长(系统那份报的或进度条读到的),差不到
    /// `staleToleranceSecs` 的不认,这一首就当没有时长。纯函数,selftest 覆盖。
    public static func accepts(_ max: Double, previous: Double?) -> Bool {
        guard let previous else { return true }
        return abs(max - previous) >= staleToleranceSecs
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var firstSeen: (key: String, at: Date, previous: Double?)?
    nonisolated(unsafe) private static var cached: (key: String, duration: Double)?
    /// 最近一首有时长的歌:换歌时它就是「上一首」(`accepts`)。
    nonisolated(unsafe) private static var last: (key: String, duration: Double)?
    /// 这一首已经记过一行「不认」的日志,同一首不再重复记。
    nonisolated(unsafe) private static var loggedRejection: String?

    /// 系统那份带着时长的 MyGo 读数:记下来,下一首拿它比进度条是不是还停在这一首。
    public static func noteDuration(trackKey: String, duration: Double) {
        lock.lock()
        last = (trackKey, duration)
        lock.unlock()
    }

    /// 这一首的时长:同一首读到过就用记着的;刚换歌不到 `settleSecs`、读不到、读到的不认为 nil。`position` 是系统那份
    /// 这一刻的位置。
    public static func duration(trackKey: String, position: Double?, now: Date) -> Double? {
        lock.lock()
        if let cached, cached.key == trackKey {
            lock.unlock()
            return cached.duration
        }
        if firstSeen?.key != trackKey { firstSeen = (trackKey, now, last.flatMap { $0.key == trackKey ? nil : $0.duration }) }
        let ready = now.timeIntervalSince(firstSeen?.at ?? now) >= settleSecs
        let previous = firstSeen?.previous
        lock.unlock()
        guard ready, let bar = progressSlider(sliders()) else { return nil }
        let fresh = matchesPosition(barValue: bar.value, position: position)
        guard fresh, accepts(bar.max, previous: previous) else {
            lock.lock()
            let first = loggedRejection != trackKey
            loggedRejection = trackKey
            lock.unlock()
            if first {
                let reason = fresh ? "still the previous song's length" : "out of step with the session position"
                logger.notice("progress bar not used (\(reason, privacy: .public)): max=\(bar.max, format: .fixed(precision: 3)) value=\(bar.value, format: .fixed(precision: 3)) position=\(position ?? -1, format: .fixed(precision: 3)) previous=\(previous ?? -1, format: .fixed(precision: 3))")
            }
            return nil
        }
        let duration = bar.max
        lock.lock()
        cached = (trackKey, duration)
        last = (trackKey, duration)
        lock.unlock()
        return duration
    }

    private static func sliders() -> [PineVolume.Slider] {
        guard AXIsProcessTrusted(), let pid = PlayerProcess.pid(bundleID: PlaybackPlayer.mygoMusic.bundleIdentifier) else { return [] }
        let app = MenuBarAX.timed(AXUIElementCreateApplication(pid), timeout: PineVolume.axTimeout)
        var found: [PineVolume.Slider] = []
        for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute, timeout: PineVolume.axTimeout) {
            for element in MenuBarAX.children(window, timeout: PineVolume.axTimeout) {
                guard (FoobarSliders.attribute(element, kAXRoleAttribute) as? String) == kAXSliderRole,
                      let min = (FoobarSliders.attribute(element, kAXMinValueAttribute) as? NSNumber)?.doubleValue,
                      let max = (FoobarSliders.attribute(element, kAXMaxValueAttribute) as? NSNumber)?.doubleValue,
                      let value = (FoobarSliders.attribute(element, kAXValueAttribute) as? NSNumber)?.doubleValue else { continue }
                found.append(PineVolume.Slider(min: min, max: max, value: value))
            }
            if !found.isEmpty { break }
        }
        return found
    }
}
