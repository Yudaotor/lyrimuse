import ApplicationServices
import Foundation

/// Audirvana 的随机、循环、音量:脚本字典里都没有,读写它主窗口(AXIdentifier `MainWindow`)播放条上的三个控件,要辅助功能权限。
/// - 随机:勾选框,描述「Shuffle Playback Button: Active / Not active」。
/// - 循环:勾选框,按一下换一档,三档轮转「Not active → Set to Repeat All → Set to Repeat One → Not active」;它的值不跟档位走
///   (转回 Not active 时仍是 1),档位只认描述。
/// - 音量:描述「Audio volume slider」的滑块,取值 0~1,直接写值生效。
/// 窗口隐藏、没在放时照样读写。会阻塞跨进程调用,别在主线程调。见 02 章决策 254。
public enum AudirvanaControls {
    /// 循环键的三档。
    public enum Loop: Equatable, Sendable {
        case off, all, one
    }

    public static let options: MusicPlaybackController.PlaybackModeOptions = .all

    static let shufflePrefix = "Shuffle Playback Button"
    static let loopPrefix = "Loop Playback Button"
    static let volumeDescription = "Audio volume slider"

    /// 随机键的描述 → 开没开;认不出为 nil。纯函数,selftest 覆盖。
    public static func shuffleOn(description: String) -> Bool? {
        guard description.hasPrefix(shufflePrefix) else { return nil }
        if description.hasSuffix("Not active") { return false }
        return description.hasSuffix("Active") ? true : nil
    }

    /// 循环键的描述 → 档位;认不出为 nil。纯函数,selftest 覆盖。
    public static func loop(description: String) -> Loop? {
        guard description.hasPrefix(loopPrefix) else { return nil }
        if description.hasSuffix("Not active") { return .off }
        if description.hasSuffix("Repeat All") { return .all }
        if description.hasSuffix("Repeat One") { return .one }
        return nil
    }

    /// 从 `from` 按到 `to` 要按几下(三档轮转)。纯函数,selftest 覆盖。
    public static func presses(from: Loop, to: Loop) -> Int {
        let order: [Loop] = [.off, .all, .one]
        let i = order.firstIndex(of: from)!, j = order.firstIndex(of: to)!
        return (j - i + order.count) % order.count
    }

    /// 两个键的状态 → Lyrimuse 的播放模式:随机开着就是随机(跟 Apple Music 一样只显示一档),否则按循环档。纯函数,selftest 覆盖。
    public static func mode(shuffle: Bool, loop: Loop) -> MusicPlaybackController.MusicPlaybackMode {
        if shuffle { return .shuffle }
        switch loop {
        case .off: return .list
        case .all: return .repeatAll
        case .one: return .repeatOne
        }
    }

    /// 切到某一档时两个键该在的状态:点亮循环就关随机,选随机就关循环(同 Swinsian 的约定)。纯函数,selftest 覆盖。
    public static func target(for mode: MusicPlaybackController.MusicPlaybackMode) -> (shuffle: Bool, loop: Loop) {
        switch mode {
        case .list: return (false, .off)
        case .shuffle: return (true, .off)
        case .repeatAll: return (false, .all)
        case .repeatOne: return (false, .one)
        }
    }

    /// 当前播放模式;没在跑、没授权、找不到那两个键为 nil。
    public static func readMode() -> MusicPlaybackController.MusicPlaybackMode? {
        guard let c = controls(), let s = c.shuffle.flatMap({ shuffleOn(description: description($0)) }),
              let l = c.loop.flatMap({ loop(description: description($0)) }) else { return nil }
        return mode(shuffle: s, loop: l)
    }

    /// 切到某一档:按需要的次数按两个键,按完核对描述到了目标档才算成。
    public static func setMode(_ mode: MusicPlaybackController.MusicPlaybackMode) -> Bool {
        guard let c = controls(), let shuffleKey = c.shuffle, let loopKey = c.loop,
              let s = shuffleOn(description: description(shuffleKey)), let l = loop(description: description(loopKey))
        else { return false }
        let want = target(for: mode)
        if s != want.shuffle { _ = AXUIElementPerformAction(shuffleKey, kAXPressAction as CFString) }
        for _ in 0..<presses(from: l, to: want.loop) { _ = AXUIElementPerformAction(loopKey, kAXPressAction as CFString) }
        return shuffleOn(description: description(shuffleKey)) == want.shuffle && loop(description: description(loopKey)) == want.loop
    }

    /// 当前音量 0~100;没在跑、没授权、找不到滑块为 nil。
    public static func readVolume() -> Int? {
        guard let slider = controls()?.volume,
              let value = (attribute(slider, kAXValueAttribute) as? NSNumber)?.doubleValue else { return nil }
        return PineVolume.percent(value)
    }

    /// 音量设成 0~100(越界夹住)。写成了为 true。
    public static func setVolume(_ percent: Int) -> Bool {
        guard let slider = controls()?.volume else { return false }
        let value = Double(Swift.min(100, Swift.max(0, percent))) / 100
        return AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, value as CFNumber) == .success
    }

    static let axTimeout: Float = 0.25

    private static func controls() -> (shuffle: AXUIElement?, loop: AXUIElement?, volume: AXUIElement?)? {
        guard AXIsProcessTrusted(), let appID = AudirvanaPlayerInfo.runningBundleID(),
              let pid = PlayerProcess.pid(bundleID: appID) else { return nil }
        let app = MenuBarAX.timed(AXUIElementCreateApplication(pid), timeout: axTimeout)
        var out: (shuffle: AXUIElement?, loop: AXUIElement?, volume: AXUIElement?) = (nil, nil, nil)
        for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute, timeout: axTimeout)
        where (attribute(window, kAXIdentifierAttribute) as? String) == "MainWindow" {
            for element in MenuBarAX.children(window, timeout: axTimeout) {
                let text = description(element)
                if text.hasPrefix(shufflePrefix) { out.shuffle = element }
                if text.hasPrefix(loopPrefix) { out.loop = element }
                if text == volumeDescription { out.volume = element }
            }
        }
        return out
    }

    private static func description(_ element: AXUIElement) -> String {
        (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
