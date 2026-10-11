import AppKit
import ApplicationServices
import Foundation

/// 读别的 App 菜单栏(没有脚本接口的播放器:QQ 音乐、网易云音乐)。只读它自己的菜单项、只对那一项 `AXPress`,不发全局快捷键,
/// 不把它拉到前台;跨进程查询设 1 秒超时。没有「辅助功能」权限、它没在跑时读不到。
public enum MenuBarAX {
    public static func menuBar(bundleID: String) -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1)
        return element(ax, kAXMenuBarAttribute)
    }

    public static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    public static func string(_ e: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 菜单栏项 / 菜单项底下的菜单项:中间隔着一层 `AXMenu`,拆掉它。
    public static func menuChildren(_ e: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.flatMap { child -> [AXUIElement] in
            string(child, kAXRoleAttribute) == kAXMenuRole ? menuChildren(child) : [child]
        }
    }

    /// 每隔 `interval` 读一次,读到 `value` 返回 true;读了 `polls` 次都不是返回 false。selftest 用桩覆盖。
    public static func waitFor(_ value: Bool, polls: Int, interval: TimeInterval, read: () -> Bool?) -> Bool {
        for _ in 0..<max(polls, 0) {
            if interval > 0 { Thread.sleep(forTimeInterval: interval) }
            if read() == value { return true }
        }
        return false
    }
}

/// 靠菜单栏里一项的标题读写「喜欢」:当前这首喜欢了,那一项写「取消喜欢」,没喜欢写「喜欢歌曲」(QQ 音乐、网易云音乐都是这样);
/// 按一下翻转,标题过一会儿跟着变。按标题认那一项(网易云再加快捷键),不按下标、也不认上级菜单的名字(版本更新会挪位置)。
/// 写入一次只走一个:先排队、再读标题,按完等标题翻过来才放 —— 连点两下时第二下读到的是第一下之后的状态。
/// 见 07 章决策 138、146、147。
public final class MenuTitleFavorite: @unchecked Sendable {
    public let bundleID: String
    /// 菜单项标题 → 喜欢了没有;认不出为 nil。
    public let state: @Sendable (String) -> Bool?
    /// 那一项的快捷键字符要等于它才认(无修饰键);nil = 只看标题。英文界面「Like」这种常见短词,靠它避开别的同名项。
    public let commandKey: String?
    /// 按下之后等标题翻过来最多多久、隔多久看一次。
    public let confirmWait: TimeInterval
    public let confirmPollInterval: TimeInterval
    private let lock = NSLock()

    public init(bundleID: String, commandKey: String? = nil, confirmWait: TimeInterval,
                confirmPollInterval: TimeInterval = 0.1, state: @escaping @Sendable (String) -> Bool?) {
        self.bundleID = bundleID
        self.commandKey = commandKey
        self.confirmWait = confirmWait
        self.confirmPollInterval = confirmPollInterval
        self.state = state
    }

    /// 当前这首喜欢了没有;读不到为 nil。会阻塞一次跨进程查询,别在主线程调。
    public func read() -> Bool? {
        item().flatMap { state($0.title) }
    }

    /// 设成喜欢 / 不喜欢,返回到没到:已经是这个状态算到;按下去之后标题在 `confirmWait` 内翻过来才算到,没翻过来返回 false,
    /// 调用方回读纠正。会阻塞(最多 `confirmWait` 多一点),别在主线程调。
    public func set(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let found = item(), let now = state(found.title) else { return false }
        if now == value { return true }
        guard AXUIElementPerformAction(found.element, kAXPressAction as CFString) == .success else { return false }
        // 先读按下的那一项;它读不出来(菜单重建过)再整个找一遍。
        return MenuBarAX.waitFor(value, polls: Int(confirmWait / confirmPollInterval), interval: confirmPollInterval) {
            (MenuBarAX.string(found.element, kAXTitleAttribute) ?? item()?.title).flatMap(state)
        }
    }

    private func item() -> (title: String, element: AXUIElement)? {
        guard let bar = MenuBarAX.menuBar(bundleID: bundleID) else { return nil }
        for top in MenuBarAX.menuChildren(bar) {
            for candidate in MenuBarAX.menuChildren(top) {
                let title = MenuBarAX.string(candidate, kAXTitleAttribute) ?? ""
                guard state(title) != nil else { continue }
                if let commandKey, MenuBarAX.string(candidate, "AXMenuItemCmdChar") != commandKey { continue }
                return (title, candidate)
            }
        }
        return nil
    }
}
