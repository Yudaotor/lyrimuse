import AppKit
import ApplicationServices
import Foundation

/// 汽水音乐的「喜欢」。它没有脚本接口,菜单栏里也没有;是 Electron 应用,网页树要对它设 `AXManualAccessibility` 才建。
/// 普通页面底部播放条上那颗心(`bottom-player › track › button`)里有两张图标,带 `show` 的是正在显示的那张:
/// 第一张显示 = 喜欢了,第二张 = 没喜欢;按它里面那层 `container` 翻转,树跟着实时变。
/// 停在全屏播放页(它的「推荐」页就是)时底部没有这颗心,全屏页上那颗是动画画的、喜欢前后属性完全一样,读不出 —— 这时为 nil。
/// 本地数据里没有单首的喜欢状态(只在看过的歌单缓存里有)。原来没开 `AXManualAccessibility` 的,读写时临时打开、用完关回去
/// (重建约 0.05 秒),开着的不动(可能是读屏软件开的)。见 07 章决策 151。
public enum SodaMusicFavoriteControl {
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

    /// 当前这首喜欢了没有;没有辅助功能权限、汽水没在跑、停在全屏播放页为 nil。会阻塞,别在主线程调。
    public static func readFavorited() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return withTree { ax in heart(ax).flatMap { favorited(iconClasses: icons($0)) } }
    }

    /// 设成喜欢 / 不喜欢,返回到没到(按完那两张图标翻过来才算)。会阻塞,别在主线程调。
    public static func setFavorited(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return withTree { ax -> Bool in
            guard let button = heart(ax), let now = favorited(iconClasses: icons(button)) else { return false }
            if now == value { return true }
            let target = find(button) { $0.contains("container") } ?? button
            guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { return false }
            return MenuBarAX.waitFor(value, polls: Int(confirmWait / confirmPollInterval), interval: confirmPollInterval) {
                heart(ax).flatMap { favorited(iconClasses: icons($0)) }
            }
        } ?? false
    }

    /// 网页树在的时候跑 `body`:原来没开就临时打开、跑完关回去。调用方持 `lock`。
    private static func withTree<T>(_ body: (AXUIElement) -> T?) -> T? {
        guard let ax = MenuBarAX.application(bundleID: bundleID) else { return nil }
        var current: AnyObject?
        let wasOn = AXUIElementCopyAttributeValue(ax, "AXManualAccessibility" as CFString, &current) == .success
            && (current as? Bool) == true
        if !wasOn {
            AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let deadline = Date().addingTimeInterval(treeWait)
            while heart(ax) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        }
        defer {
            if !wasOn { AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanFalse) }
        }
        return body(ax)
    }

    /// 底部播放条上那颗心(`bottom-player` 底下类名正好是 `track` 那一层的第一颗 `button`)。
    private static func heart(_ ax: AXUIElement) -> AXUIElement? {
        for window in MenuBarAX.children(ax, attribute: kAXWindowsAttribute) {
            guard let bar = find(window, { $0.contains("bottom-player") }),
                  let track = MenuBarAX.children(bar).first(where: { classes($0) == ["track"] }) else { continue }
            return MenuBarAX.children(track).first { classes($0).contains("button") }
        }
        return nil
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
