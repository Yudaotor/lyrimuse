import AppKit
import ApplicationServices
import Foundation

/// 读别的 App 菜单栏(没有脚本接口的播放器:QQ 音乐、网易云音乐、酷狗音乐)。只读它自己的菜单项、只对那一项 `AXPress`,不发全局快捷键,
/// 不把它拉到前台;跨进程查询每个元素 1 秒超时(超时只属于设它的那个元素,不会从 App 元素带到下面取到的菜单项上,
/// 取到一个设一个)。没有「辅助功能」权限、它没在跑时读不到。
public enum MenuBarAX {
    static let messagingTimeout: Float = 1

    public static func menuBar(bundleID: String) -> AXUIElement? {
        application(bundleID: bundleID).flatMap { element($0, kAXMenuBarAttribute) }
    }

    /// 它的 App 元素(跨进程查询 1 秒超时);没有权限、没在跑为 nil。
    public static func application(bundleID: String) -> AXUIElement? {
        guard AXIsProcessTrusted(), let pid = PlayerProcess.pid(bundleID: bundleID) else { return nil }
        return timed(AXUIElementCreateApplication(pid))
    }

    /// 给取到的元素设上跨进程查询超时。
    @discardableResult
    public static func timed(_ e: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(e, messagingTimeout)
        return e
    }

    /// 按一项:灰着的(`AXEnabled` 为 false,比如 QQ 弹着会员窗时整组菜单都灰)不按、返回 false,按下去也会回成功、其实没用。
    public static func press(_ e: AXUIElement) -> Bool {
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(e, kAXEnabledAttribute as CFString, &value) == .success, (value as? Bool) == false {
            return false
        }
        return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }

    /// 一组子元素(默认 `AXChildren`,也可以是 `AXWindows`);读不到为空。
    public static func children(_ e: AXUIElement, attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return [] }
        return ((value as? [AXUIElement]) ?? []).map(timed)
    }

    public static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return timed(value as! AXUIElement)
    }

    public static func string(_ e: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 菜单栏项 / 菜单项底下的菜单项:中间隔着一层 `AXMenu`,拆掉它。
    public static func menuChildren(_ e: AXUIElement) -> [AXUIElement] {
        children(e).flatMap { child -> [AXUIElement] in
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

/// 按菜单栏里一项写「喜欢」,按一下翻转。状态有两种读法:QQ 音乐、网易云音乐读那一项的标题(喜欢了写「取消喜欢」,
/// 没喜欢写「喜欢歌曲」,按完过一会儿跟着变);酷狗那一项的标题不变,状态从别处读(`init(bundleID:itemTitle:…)`)。
/// 按标题认那一项(网易云、酷狗再加快捷键),不按下标、也不认上级菜单的名字(版本更新会挪位置)。
/// 写入一次只走一个:先排队、再读状态,按完等状态翻过来才放 —— 连点两下时第二下读到的是第一下之后的状态。
/// 见 07 章决策 138、146、147、148。
public final class MenuTitleFavorite: @unchecked Sendable {
    public let bundleID: String
    /// 那一项的快捷键字符要等于它才认(无修饰键);nil = 只看标题。英文界面「Like」这种常见短词,靠它避开别的同名项。
    public let commandKey: String?
    /// 按下之后等标题翻过来最多多久、隔多久看一次。
    public let confirmWait: TimeInterval
    public let confirmPollInterval: TimeInterval
    private let recognizes: @Sendable (String) -> Bool
    private let source: Source
    private let lock = NSLock()

    private enum Source {
        /// 菜单项标题 → 喜欢了没有;认不出为 nil。
        case title(@Sendable (String) -> Bool?)
        /// 标题不变,状态从别处读;读不到为 nil。
        case elsewhere(@Sendable () -> Bool?)
    }

    /// 标题就是状态:`state` 把标题读成喜欢了没有,认不出的项为 nil。
    public init(bundleID: String, commandKey: String? = nil, confirmWait: TimeInterval,
                confirmPollInterval: TimeInterval = 0.1, state: @escaping @Sendable (String) -> Bool?) {
        self.bundleID = bundleID
        self.commandKey = commandKey
        self.confirmWait = confirmWait
        self.confirmPollInterval = confirmPollInterval
        recognizes = { state($0) != nil }
        source = .title(state)
    }

    /// 标题固定是 `itemTitle`,状态由 `readState` 从别处读。
    public init(bundleID: String, itemTitle: String, commandKey: String?, confirmWait: TimeInterval,
                confirmPollInterval: TimeInterval = 0.1, readState: @escaping @Sendable () -> Bool?) {
        self.bundleID = bundleID
        self.commandKey = commandKey
        self.confirmWait = confirmWait
        self.confirmPollInterval = confirmPollInterval
        recognizes = { $0.trimmingCharacters(in: .whitespaces) == itemTitle }
        source = .elsewhere(readState)
    }

    /// 当前这首喜欢了没有;读不到为 nil。会阻塞一次跨进程查询,别在主线程调。
    public func read() -> Bool? {
        switch source {
        case .title(let state): return item().flatMap { state($0.title) }
        case .elsewhere(let readState): return readState()
        }
    }

    /// 设成喜欢 / 不喜欢,返回到没到:已经是这个状态算到;按下去之后标题在 `confirmWait` 内翻过来才算到,没翻过来返回 false,
    /// 调用方回读纠正。会阻塞(最多 `confirmWait` 多一点),别在主线程调。
    public func set(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let found = item(), let now = state(after: found) else { return false }
        if now == value { return true }
        guard MenuBarAX.press(found.element) else { return false }
        return MenuBarAX.waitFor(value, polls: Int(confirmWait / confirmPollInterval), interval: confirmPollInterval) {
            state(after: found)
        }
    }

    /// 按过(或要按)`found` 那一项之后的状态。读标题时先读那一项本身,它读不出来(菜单重建过)再整个找一遍。
    private func state(after found: (title: String, element: AXUIElement)) -> Bool? {
        switch source {
        case .title(let state):
            return (MenuBarAX.string(found.element, kAXTitleAttribute) ?? item()?.title).flatMap(state)
        case .elsewhere(let readState):
            return readState()
        }
    }

    private func item() -> (title: String, element: AXUIElement)? {
        guard let bar = MenuBarAX.menuBar(bundleID: bundleID) else { return nil }
        for top in MenuBarAX.menuChildren(bar) {
            for candidate in MenuBarAX.menuChildren(top) {
                let title = MenuBarAX.string(candidate, kAXTitleAttribute) ?? ""
                guard recognizes(title) else { continue }
                if let commandKey, MenuBarAX.string(candidate, "AXMenuItemCmdChar") != commandKey { continue }
                return (title, candidate)
            }
        }
        return nil
    }
}
