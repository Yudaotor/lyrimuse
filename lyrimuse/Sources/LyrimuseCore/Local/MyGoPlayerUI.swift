import ApplicationServices
import Foundation

/// MyGo Music 推给系统的会话里,时长取的是音源报的那个;有的插件报 0(按文件大小算长度的流),系统那份就一直没有时长,
/// 位置也就一直算不了。它自己界面上进度条的最大值是解码得出的时长(带小数),在放、系统那份没有时长时从这里补。
/// 要辅助功能权限;窗口关着(只留菜单栏图标)时读不到。换歌后 `settleSecs` 之内进度条可能还是上一首的,这段不读。
/// 会阻塞跨进程调用,别在主线程调。见 02 章决策 244。
public enum MyGoPlayerUI {
    /// 换歌后多久才信进度条。
    public static let settleSecs: TimeInterval = 1

    /// 几根滑块里哪一根是进度条:从 0 起、最大值超过 1.5 秒的那一根(音量是 0~1);没有或不止一根为 nil。纯函数,selftest 覆盖。
    public static func progressMax(_ sliders: [PineVolume.Slider]) -> Double? {
        let hits = sliders.filter {
            $0.min == 0 && $0.max.isFinite && $0.max > 1.5 && $0.max < MediaControlSnapshot.endlessDurationSecs
        }
        return hits.count == 1 ? hits[0].max : nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var firstSeen: (key: String, at: Date)?
    nonisolated(unsafe) private static var cached: (key: String, duration: Double)?

    /// 这一首的时长:同一首读到过就用记着的;刚换歌不到 `settleSecs`、读不到为 nil。
    public static func duration(trackKey: String, now: Date) -> Double? {
        lock.lock()
        if let cached, cached.key == trackKey {
            lock.unlock()
            return cached.duration
        }
        if firstSeen?.key != trackKey { firstSeen = (trackKey, now) }
        let ready = now.timeIntervalSince(firstSeen?.at ?? now) >= settleSecs
        lock.unlock()
        guard ready, let duration = progressMax(sliders()) else { return nil }
        lock.lock()
        cached = (trackKey, duration)
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
