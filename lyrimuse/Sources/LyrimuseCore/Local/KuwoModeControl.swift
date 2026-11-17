import ApplicationServices
import Foundation

/// 酷我音乐的播放模式。它没有脚本接口,菜单里没有模式项,偏好里的 `keyPlayMode` 运行中不更新;只能读、按主窗口或迷你窗口
/// 播放条上那颗模式键(窗口的直接子元素 `AXButton`),它的 AXHelp 就是当前档名。按一下进一档,四档轮转
/// 「列表循环 → 随机播放 → 顺序播放 → 单曲循环 → 列表循环」。快速连按会丢一下,所以每按一下都等它的档名变了再按下一下,
/// 到目标档才算成;写入一次只走一个(`writeLock`)。主窗口关掉、只剩菜单栏时窗口列表是空的,读不到就当没有这组键,不去开窗口。
/// 要辅助功能权限;会阻塞跨进程调用,别在主线程调。见 02 章决策 264。
public enum KuwoModeControl {
    public typealias Mode = MusicPlaybackController.MusicPlaybackMode

    public static let options: MusicPlaybackController.PlaybackModeOptions = .all
    /// 按一下进一档的顺序。
    public static let cycle: [Mode] = [.repeatAll, .shuffle, .list, .repeatOne]
    /// 每按一下等档名变化:最多等这么久、隔这么久看一次。
    public static let confirmWait: TimeInterval = 1.0
    public static let confirmPollInterval: TimeInterval = 0.05
    /// 一次切换最多按几下:绕一圈三下,再给丢掉的那下留重按。
    public static let maxPresses = 6

    private static let writeLock = NSLock()

    /// 模式键的 AXHelp → 档位;认不出为 nil。纯函数,selftest 覆盖。
    public static func mode(help: String) -> Mode? {
        switch help {
        case "顺序播放": return .list
        case "列表循环": return .repeatAll
        case "单曲循环": return .repeatOne
        case "随机播放": return .shuffle
        default: return nil
        }
    }

    /// 从 `from` 按到 `to` 要按几下。纯函数,selftest 覆盖。
    public static func presses(from: Mode, to: Mode) -> Int {
        guard let i = cycle.firstIndex(of: from), let j = cycle.firstIndex(of: to) else { return 0 }
        return (j - i + cycle.count) % cycle.count
    }

    /// 当前播放模式;没在跑、没授权、窗口都关着为 nil。
    public static func readMode() -> Mode? {
        modeKey().flatMap { mode(help: help($0)) }
    }

    /// 切到某一档:按一下读一下,档名变了才按下一下,读回到目标档才算成。
    public static func setMode(_ target: Mode) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let key = modeKey(), let start = mode(help: help(key)) else { return false }
        return pressUntil(target, from: start, polls: Int(confirmWait / confirmPollInterval), pollInterval: confirmPollInterval,
                          read: { mode(help: help(key)) },
                          press: { _ = AXUIElementPerformAction(key, kAXPressAction as CFString) }) == target
    }

    /// 从 `start` 一下一下按到 `target`:每按一下最多读 `polls` 次,档名变了才按下一下,最多按 `maxPresses` 下;返回最后读到的档。
    /// 读不出的那一拍当没变。selftest 用桩测。
    public static func pressUntil(_ target: Mode, from start: Mode, polls: Int, pollInterval: TimeInterval,
                                  read: () -> Mode?, press: () -> Void) -> Mode {
        var current = start
        var pressed = 0
        while current != target, pressed < maxPresses {
            press()
            pressed += 1
            let before = current
            for _ in 0..<max(polls, 0) where current == before {
                if pollInterval > 0 { Thread.sleep(forTimeInterval: pollInterval) }
                if let now = read() { current = now }
            }
        }
        return current
    }

    static let axTimeout: Float = 0.25

    /// 主窗口或迷你窗口里那颗模式键:窗口的直接子元素里 AXHelp 是四个档名之一的那颗。
    private static func modeKey() -> AXUIElement? {
        guard AXIsProcessTrusted(), let pid = PlayerProcess.pid(bundleID: PlaybackPlayer.kuwo.bundleIdentifier) else { return nil }
        let app = MenuBarAX.timed(AXUIElementCreateApplication(pid), timeout: axTimeout)
        for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute, timeout: axTimeout) {
            for element in MenuBarAX.children(window, timeout: axTimeout)
            where (attribute(element, kAXRoleAttribute) as? String) == kAXButtonRole && mode(help: help(element)) != nil {
                return element
            }
        }
        return nil
    }

    private static func help(_ element: AXUIElement) -> String {
        (attribute(element, kAXHelpAttribute) as? String) ?? ""
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
