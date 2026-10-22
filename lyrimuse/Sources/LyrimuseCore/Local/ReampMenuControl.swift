import ApplicationServices
import Foundation
import os

/// reAMP 的随机 / 循环。系统媒体遥控的随机 / 循环命令它不接,唯一的通道是菜单栏 Play 里的 Shuffle / Repeat 两项:两个互相
/// 独立的开关,开着时那一项打勾,对那一项 `AXPress` 翻转。按标题认(英文、俄文两套界面),不认上级菜单的名字和位置。
/// 需要「辅助功能」权限,没有就读不到、按钮不显示。见 02 章决策 126。
///
/// 按完要过 1~2 秒勾才跟着变(0.4 秒读到的还是旧值):刚按过的那一项在 `pendingWindow` 里以按下去的结果为准,不读勾,
/// 不然连点两下会按成反的。
public enum ReampMenuControl {
    public static let bundleID = PlaybackPlayer.reamp.bundleIdentifier
    /// 随机、列表循环;它的循环只有开 / 关,没有单曲循环。
    public static let options: MusicPlaybackController.PlaybackModeOptions = [.shuffle, .repeatAll]
    static let shuffleTitles: Set<String> = ["Shuffle", "Перемешать"]
    static let repeatTitles: Set<String> = ["Repeat", "Повтор"]
    /// 按过之后多久以内不信勾。
    public static let pendingWindow: TimeInterval = 3

    public struct Toggles: Equatable, Sendable {
        public var shuffle: Bool
        public var repeating: Bool
        public init(shuffle: Bool, repeating: Bool) {
            self.shuffle = shuffle
            self.repeating = repeating
        }
    }

    /// 两个开关 → 档位。都开着时算随机(同 `MusicPlaybackMode` 的优先级)。纯函数,selftest 覆盖。
    public static func mode(_ t: Toggles) -> MusicPlaybackController.MusicPlaybackMode {
        if t.shuffle { return .shuffle }
        return t.repeating ? .repeatAll : .list
    }

    /// 档位 → 两个开关该是什么样。随机和循环两颗键互斥(同别的播放器):切到一样就关掉另一样。没有单曲循环,为 nil。
    /// 纯函数,selftest 覆盖。
    public static func toggles(for mode: MusicPlaybackController.MusicPlaybackMode) -> Toggles? {
        switch mode {
        case .list: return Toggles(shuffle: false, repeating: false)
        case .shuffle: return Toggles(shuffle: true, repeating: false)
        case .repeatAll: return Toggles(shuffle: false, repeating: true)
        case .repeatOne: return nil
        }
    }

    /// 读到的勾叠上刚按过的结果(还在 `pendingWindow` 里的那一份)。纯函数,selftest 覆盖。
    public static func effective(read: Toggles, pending: (toggles: Toggles, at: Date)?, now: Date) -> Toggles {
        guard let pending, now.timeIntervalSince(pending.at) < pendingWindow else { return read }
        return pending.toggles
    }

    private static let pending = OSAllocatedUnfairLock<(toggles: Toggles, at: Date)?>(initialState: nil)

    /// 当前档;reAMP 没在跑、没有辅助功能权限、找不到这两项时为 nil。会阻塞一次跨进程查询,别在主线程调。
    public static func readMode(now: Date = Date()) -> MusicPlaybackController.MusicPlaybackMode? {
        guard let items = items() else { return nil }
        return mode(effective(read: marks(items), pending: pending.withLock { $0 }, now: now))
    }

    /// 切到某一档,返回该按的都按下去了没有。传 `.repeatOne` 回 false。会阻塞,别在主线程调。
    public static func setMode(_ mode: MusicPlaybackController.MusicPlaybackMode, now: Date = Date()) -> Bool {
        guard let target = toggles(for: mode), let items = items() else { return false }
        let current = effective(read: marks(items), pending: pending.withLock { $0 }, now: now)
        // 只记真按下去的那一项:没按成的也记成刚按过的话,`pendingWindow` 里回读一直报成目标档,纠正不回来。
        var applied = current
        if current.shuffle != target.shuffle, MenuBarAX.press(items.shuffle) { applied.shuffle = target.shuffle }
        if current.repeating != target.repeating, MenuBarAX.press(items.repeating) { applied.repeating = target.repeating }
        if applied != current { pending.withLock { $0 = (applied, now) } }
        return applied == target
    }

    private static func marks(_ items: (shuffle: AXUIElement, repeating: AXUIElement)) -> Toggles {
        Toggles(shuffle: !(MenuBarAX.string(items.shuffle, "AXMenuItemMarkChar") ?? "").isEmpty,
                repeating: !(MenuBarAX.string(items.repeating, "AXMenuItemMarkChar") ?? "").isEmpty)
    }

    private static func items() -> (shuffle: AXUIElement, repeating: AXUIElement)? {
        guard let bar = MenuBarAX.menuBar(bundleID: bundleID) else { return nil }
        for top in MenuBarAX.menuChildren(bar) {
            let entries = MenuBarAX.menuChildren(top)
            let titled = { (titles: Set<String>) in
                entries.first { titles.contains((MenuBarAX.string($0, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespaces)) }
            }
            if let shuffle = titled(shuffleTitles), let repeating = titled(repeatTitles) { return (shuffle, repeating) }
        }
        return nil
    }
}

/// reAMP 主窗口上的进度条:皮肤自绘,辅助功能树里那扇窗有三个 `AXSlider`(音量、平衡、进度),进度是最后一个,值是整秒。只读。
/// 它是界面每秒刷一次时取的整,当不了位置真值;只用来分「恢复播放」和「重新打开从头放」:重新打开那一刻它就归 0,
/// 恢复时停在暂停位置的整秒。见 02 章决策 126。需要「辅助功能」权限,没有就读不到。会阻塞一次跨进程查询,别在主线程调。
public enum ReampProgressBar {
    /// 进度条现在的值(秒);reAMP 没在跑、没有权限、找不到那扇窗时为 nil。
    public static func seconds() -> Double? {
        guard let app = MenuBarAX.application(bundleID: ReampMenuControl.bundleID) else { return nil }
        for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute) {
            let sliders = MenuBarAX.children(window).filter { MenuBarAX.string($0, kAXRoleAttribute) == kAXSliderRole }
            guard sliders.count == 3 else { continue }
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(sliders[2], kAXValueAttribute as CFString, &value) == .success else { return nil }
            return (value as? NSNumber)?.doubleValue
        }
        return nil
    }
}
