import AppKit
import ApplicationServices
import Foundation

/// QQ 音乐的随机 / 循环和「喜欢」。它没有脚本接口(无 .sdef),系统媒体遥控的随机 / 循环命令也不接;唯一的通道是它自己菜单栏
/// 「播放控制」:「播放模式」那三项(顺序播放 / 随机播放 / 单曲循环)读当前档看哪一项打了勾、切换对那一项 `AXPress`;
/// 「喜欢歌曲」那一项的标题就是状态(喜欢了写「取消喜欢」),按一下翻转,标题 1 秒内跟着变 —— 所以「喜欢」的写入要排队、
/// 按完等标题翻过来(见 `setFavorited`)。
/// 需要「辅助功能」权限,没有就读不到、按钮不显示。见 07 章决策 130、138。
///
/// 按标题认这三项,不按下标、也不认上级菜单的名字(版本更新会挪位置):哪个子菜单里认得出至少两项,就是它。
/// 按下之后 QQ 过 0.6~2 秒才把勾挪过去,所以写完不回读(同 `MusicPlaybackController.setPlaybackMode` 的约定)。
/// 不在后台、窗口关着也照样读得到、按得动,不会把 QQ 拉到前台。
public enum QQMusicMenuControl {
    public static let bundleID = "com.tencent.QQMusicMac"
    /// QQ 只有这三档,没有列表循环:循环键只在「关 ↔ 单曲循环」之间切。
    public static let options: MusicPlaybackController.PlaybackModeOptions = [.shuffle, .repeatOne]

    /// 菜单项标题 → 档位(简体、繁体两套界面)。
    public static func mode(forTitle title: String) -> MusicPlaybackController.MusicPlaybackMode? {
        switch title.trimmingCharacters(in: .whitespaces) {
        case "顺序播放", "順序播放": return .list
        case "随机播放", "隨機播放": return .shuffle
        case "单曲循环", "單曲循環": return .repeatOne
        default: return nil
        }
    }

    /// 一个子菜单里的各项(标题、勾)→ 当前档。认不出至少两项就不是「播放模式」那个子菜单;没有一项打勾也读不出来。
    public static func markedMode(_ items: [(title: String, mark: String?)]) -> MusicPlaybackController.MusicPlaybackMode? {
        let known = items.filter { mode(forTitle: $0.title) != nil }
        guard known.count >= 2 else { return nil }
        return known.first { !($0.mark ?? "").isEmpty }.flatMap { mode(forTitle: $0.title) }
    }

    /// 「喜欢歌曲」那一项的标题 → 当前这首喜欢了没有(简体、繁体两套界面)。
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

    /// 「喜欢」的写入一次只走一个,按下之后等标题翻过来才放。见 07 章决策 138。
    private static let favoriteLock = NSLock()
    /// 按下「喜欢」之后等标题翻过来最多多久(实测 1 秒内)、隔多久看一次。
    static let favoriteConfirmWait: TimeInterval = 2
    static let favoriteConfirmPollInterval: TimeInterval = 0.1

    /// 设成喜欢 / 不喜欢,返回到没到:已经是这个状态算到;按下去之后标题在 `favoriteConfirmWait` 内翻过来才算到,
    /// 没翻过来返回 false,调用方回读纠正。会阻塞(最多两秒多),别在主线程调。
    public static func setFavorited(_ value: Bool) -> Bool {
        favoriteLock.lock()
        defer { favoriteLock.unlock() }
        guard let item = favoriteItem(), let now = favorited(forTitle: item.title) else { return false }
        if now == value { return true }
        guard AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success else { return false }
        // 先读按下的那一项;它读不出来(菜单重建过)再整个找一遍。
        return waitFor(value, polls: Int(favoriteConfirmWait / favoriteConfirmPollInterval),
                       interval: favoriteConfirmPollInterval) {
            (string(item.element, kAXTitleAttribute) ?? favoriteItem()?.title).flatMap(favorited(forTitle:))
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

    /// 当前档;QQ 没在跑、没有辅助功能权限、找不到那个子菜单时为 nil。会阻塞一次跨进程查询,别在主线程调。
    public static func readMode() -> MusicPlaybackController.MusicPlaybackMode? {
        guard let items = modeItems() else { return nil }
        return markedMode(items.map { (title: $0.title, mark: string($0.element, "AXMenuItemMarkChar")) })
    }

    /// 切到某一档,返回按没按下去。QQ 没有列表循环,传 `.repeatAll` 回 false。
    public static func setMode(_ mode: MusicPlaybackController.MusicPlaybackMode) -> Bool {
        guard let item = modeItems()?.first(where: { Self.mode(forTitle: $0.title) == mode }) else { return false }
        return AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    private static func menuBar() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1)
        return element(ax, kAXMenuBarAttribute)
    }

    private static func favoriteItem() -> (title: String, element: AXUIElement)? {
        guard let bar = menuBar() else { return nil }
        for top in menuChildren(bar) {
            for item in menuChildren(top) {
                let title = string(item, kAXTitleAttribute) ?? ""
                if favorited(forTitle: title) != nil { return (title, item) }
            }
        }
        return nil
    }

    private static func modeItems() -> [(title: String, element: AXUIElement)]? {
        guard let bar = menuBar() else { return nil }
        for top in menuChildren(bar) {
            for item in menuChildren(top) {
                let subs = menuChildren(item).map { (title: string($0, kAXTitleAttribute) ?? "", element: $0) }
                if subs.filter({ mode(forTitle: $0.title) != nil }).count >= 2 { return subs }
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
