import AppKit
import ApplicationServices
import Foundation

/// 网易云音乐的「喜欢」。它没有脚本接口(无 .sdef);唯一的通道是它自己菜单栏「控制」里「喜欢歌曲」那一项(快捷键 ⌘L):
/// 标题就是当前这首的状态(喜欢了写「取消喜欢」),跟着当前曲目走,按一下翻转,标题 1.5 秒内跟着变 —— 写入要排队、按完等标题
/// 翻过来(同 `QQMusicMenuControl` 的「喜欢」)。按标题认这一项,不按下标、也不认上级菜单的名字(版本更新会挪位置)。
/// 同一个菜单里的随机 / 循环不打勾、读不出当前档,不接。需要「辅助功能」权限,没有就读不到、按钮不显示。
/// 不在前台、窗口关着也照样读得到、按得动。见 07 章决策 146。
public enum NetEaseMenuControl {
    public static let bundleID = "com.netease.163music"

    /// 「喜欢歌曲」那一项的标题 → 当前这首喜欢了没有(简体、繁体两套写法)。纯函数,selftest 覆盖。
    public static func favorited(forTitle title: String) -> Bool? {
        switch title.trimmingCharacters(in: .whitespaces) {
        case "取消喜欢", "取消喜歡": return true
        case "喜欢歌曲", "喜歡歌曲": return false
        default: return nil
        }
    }

    /// 当前这首喜欢了没有;读不到为 nil。会阻塞一次跨进程查询,别在主线程调。
    public static func readFavorited() -> Bool? {
        favoriteItem().flatMap { favorited(forTitle: $0.title) }
    }

    /// 「喜欢」的写入一次只走一个,按下之后等标题翻过来才放。
    private static let favoriteLock = NSLock()
    /// 按下之后等标题翻过来最多多久(实测 1.5 秒内)、隔多久看一次。
    static let favoriteConfirmWait: TimeInterval = 2.5
    static let favoriteConfirmPollInterval: TimeInterval = 0.1

    /// 设成喜欢 / 不喜欢,返回到没到:已经是这个状态算到;按下去之后标题在 `favoriteConfirmWait` 内翻过来才算到,没翻过来
    /// 返回 false,调用方回读纠正。会阻塞(最多两秒多),别在主线程调。
    public static func setFavorited(_ value: Bool) -> Bool {
        favoriteLock.lock()
        defer { favoriteLock.unlock() }
        guard let item = favoriteItem(), let now = favorited(forTitle: item.title) else { return false }
        if now == value { return true }
        guard AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success else { return false }
        return QQMusicMenuControl.waitFor(value, polls: Int(favoriteConfirmWait / favoriteConfirmPollInterval),
                                          interval: favoriteConfirmPollInterval) {
            (string(item.element, kAXTitleAttribute) ?? favoriteItem()?.title).flatMap(favorited(forTitle:))
        }
    }

    private static func favoriteItem() -> (title: String, element: AXUIElement)? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1)
        guard let bar = element(ax, kAXMenuBarAttribute) else { return nil }
        for top in menuChildren(bar) {
            for item in menuChildren(top) {
                let title = string(item, kAXTitleAttribute) ?? ""
                if favorited(forTitle: title) != nil { return (title, item) }
            }
        }
        return nil
    }

    private static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 菜单栏项 / 菜单项底下的菜单项:中间隔着一层 `AXMenu`,拆掉它。
    private static func menuChildren(_ e: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.flatMap { child -> [AXUIElement] in
            string(child, kAXRoleAttribute) == kAXMenuRole ? menuChildren(child) : [child]
        }
    }
}
