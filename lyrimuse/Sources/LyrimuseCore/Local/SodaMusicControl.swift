import AppKit
import ApplicationServices
import Foundation

/// 汽水音乐的「喜欢」与失焦时的三项播放控制。它没有脚本接口,菜单栏里也没有这些项;是 Electron 应用,网页树要对它设
/// `AXManualAccessibility` 才建。两样都靠普通页面底部的播放条(`bottom-player`):
/// - 喜欢:`track` 那一层的第一颗 `button` 里有两张图标,带 `show` 的是正在显示的那张 —— 第一张显示 = 喜欢了,第二张 = 没喜欢;
///   按它里面那层 `container` 翻转,树跟着实时变。
/// - 播放控制:中间那组 `controls center` 的三颗键,依次是上一首、播放 / 暂停(带 `large`)、下一首。键上没有文字,只能按位置认,
///   所以组里不是正好三颗、或者带 `large` 的不在中间就不按。
/// 停在全屏播放页(它的「推荐」页就是)时底部没有播放条,两样都读不到、按不了;全屏页上那颗心是动画画的、喜欢前后属性完全一样。
/// 本地数据里没有单首的喜欢状态(只在看过的歌单缓存里有)。原来没开 `AXManualAccessibility` 的,读写时临时打开、用完关回去
/// (重建约 0.05 秒),开着的不动(可能是读屏软件开的)。见 07 章决策 151、02 章决策 125。
public enum SodaMusicControl {
    public static let bundleID = "com.soda.music"
    /// 按完等那两张图标翻过来:最多等这么久、隔这么久看一次。
    static let confirmWait: TimeInterval = 2.5
    static let confirmPollInterval: TimeInterval = 0.1
    /// 打开 `AXManualAccessibility` 之后等树建好最多多久。
    static let treeWait: TimeInterval = 0.5

    /// 读写都只走一个:临时打开、关回去那一段不能叠在一起,按的是开关。
    private static let lock = NSLock()

    /// 那颗心两张图标的类名 → 喜欢了没有;认不出(不是两张、两张都显示或都不显示)为 nil。纯函数,selftest 覆盖。
    public static func favorited(iconClasses: [[String]]) -> Bool? {
        guard iconClasses.count == 2 else { return nil }
        switch (iconClasses[0].contains("show"), iconClasses[1].contains("show")) {
        case (true, false): return true
        case (false, true): return false
        default: return nil
        }
    }

    /// `controls center` 那组键的类名 → 这项控制按第几颗;认不出(不是正好三颗 `button`、`large` 不是只在中间那颗)为 nil。
    /// 纯函数,selftest 覆盖。
    public static func transportIndex(_ command: PlaybackMenuControl.Command, buttonClasses: [[String]]) -> Int? {
        guard buttonClasses.count == 3, buttonClasses.allSatisfy({ $0.contains("button") }),
              buttonClasses.map({ $0.contains("large") }) == [false, true, false] else { return nil }
        switch command {
        case .previousTrack: return 0
        case .playPause: return 1
        case .nextTrack: return 2
        }
    }

    /// 当前这首喜欢了没有;没有辅助功能权限、汽水没在跑、停在全屏播放页为 nil。会阻塞,别在主线程调。
    public static func readFavorited() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return withTree(ready: { heart($0) != nil }) { ax in heart(ax).flatMap { favorited(iconClasses: icons($0)) } }
    }

    /// 设成喜欢 / 不喜欢,返回到没到(按完那两张图标翻过来才算)。会阻塞,别在主线程调。
    public static func setFavorited(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return withTree(ready: { heart($0) != nil }) { ax -> Bool in
            guard let button = heart(ax), let now = favorited(iconClasses: icons(button)) else { return false }
            if now == value { return true }
            let target = find(button) { $0.contains("container") } ?? button
            guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { return false }
            return MenuBarAX.waitFor(value, polls: Int(confirmWait / confirmPollInterval), interval: confirmPollInterval) {
                heart(ax).flatMap { favorited(iconClasses: icons($0)) }
            }
        } ?? false
    }

    /// 按播放条上的一项播放控制。只回报 AXPress 送没送出,不等播放状态变(那由下一拍轮询读回)。不激活汽水、不发按键。
    /// 会阻塞跨进程调用,别在主线程调;由 `PlaybackMenuControl.press` 转来,排在播放控制的命令队列里。
    public static func press(_ command: PlaybackMenuControl.Command) -> PlaybackMenuControl.Outcome {
        guard AXIsProcessTrusted() else { return .notTrusted }
        lock.lock()
        defer { lock.unlock() }
        return withTree(ready: { transportButtons($0) != nil }) { ax -> PlaybackMenuControl.Outcome in
            guard let buttons = transportButtons(ax),
                  let index = transportIndex(command, buttonClasses: buttons.map(classes)) else { return .menuUnavailable }
            let result = AXUIElementPerformAction(buttons[index], kAXPressAction as CFString)
            return result == .success ? .pressed : .pressFailed(code: result.rawValue)
        } ?? .playerNotRunning
    }

    /// 网页树在的时候跑 `body`:原来没开就临时打开、等到 `ready` 或超时、跑完关回去。汽水没在跑为 nil。调用方持 `lock`。
    private static func withTree<T>(ready: (AXUIElement) -> Bool, _ body: (AXUIElement) -> T?) -> T? {
        guard let ax = MenuBarAX.application(bundleID: bundleID) else { return nil }
        var current: AnyObject?
        let wasOn = AXUIElementCopyAttributeValue(ax, "AXManualAccessibility" as CFString, &current) == .success
            && (current as? Bool) == true
        if !wasOn {
            AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let deadline = Date().addingTimeInterval(treeWait)
            while !ready(ax), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        }
        defer {
            if !wasOn { AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanFalse) }
        }
        return body(ax)
    }

    /// 各窗口里的底部播放条。
    private static func bottomPlayer(_ ax: AXUIElement) -> AXUIElement? {
        for window in MenuBarAX.children(ax, attribute: kAXWindowsAttribute) {
            if let bar = find(window, { $0.contains("bottom-player") }) { return bar }
        }
        return nil
    }

    /// 底部播放条上那颗心(类名正好是 `track` 那一层的第一颗 `button`)。
    private static func heart(_ ax: AXUIElement) -> AXUIElement? {
        guard let bar = bottomPlayer(ax),
              let track = MenuBarAX.children(bar).first(where: { classes($0) == ["track"] }) else { return nil }
        return MenuBarAX.children(track).first { classes($0).contains("button") }
    }

    /// 底部播放条中间那组 `controls center` 的键(按出现顺序)。
    private static func transportButtons(_ ax: AXUIElement) -> [AXUIElement]? {
        guard let bar = bottomPlayer(ax),
              let group = MenuBarAX.children(bar).first(where: { Set(classes($0)).isSuperset(of: ["controls", "center"]) })
        else { return nil }
        return MenuBarAX.children(group)
    }

    private static func icons(_ e: AXUIElement) -> [[String]] {
        (MenuBarAX.string(e, kAXRoleAttribute) == kAXImageRole ? [classes(e)] : []) + MenuBarAX.children(e).flatMap(icons)
    }

    private static func classes(_ e: AXUIElement) -> [String] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(e, "AXDOMClassList" as CFString, &value)
        return (value as? [String]) ?? []
    }

    private static func find(_ e: AXUIElement, _ matches: ([String]) -> Bool, depth: Int = 0) -> AXUIElement? {
        guard depth < 40 else { return nil }
        if matches(classes(e)) { return e }
        for child in MenuBarAX.children(e) {
            if let hit = find(child, matches, depth: depth + 1) { return hit }
        }
        return nil
    }
}
