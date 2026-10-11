import ApplicationServices
import Foundation

/// 酷狗音乐的「喜欢」。它没有脚本接口(无 .sdef);菜单栏「播放控制」里「喜欢歌曲」(⌘L)按一下翻转当前这首,标题却一直不变,
/// 状态读主窗口播放条上那颗心(辅助功能描述「取消收藏」= 喜欢了,「收藏」= 没喜欢)。窗口隐藏、最小化时照样读得到;主窗口关掉
/// (App 还在后台放)时那颗心不在、读不到。只有简体中文界面。没登录时按了不翻、弹登录面板。见 07 章决策 148。
public enum KugouMenuControl {
    public static let bundleID = "com.kugou.mac.Music"

    /// 播放条那颗心的辅助功能描述 → 喜欢了没有;别的键为 nil。纯函数,selftest 覆盖。
    public static func favorited(forHeartDescription description: String) -> Bool? {
        switch description.trimmingCharacters(in: .whitespaces) {
        case "取消收藏": return true
        case "收藏": return false
        default: return nil
        }
    }

    /// 播放条上「 / 03:04」那段总时长文字。播放条按它认:歌单列表各行也有心形键,跟它不在同一层。纯函数,selftest 覆盖。
    public static func isPlayBarDuration(_ description: String) -> Bool {
        description.range(of: #"^\s*/\s*\d{1,3}:\d{2}$"#, options: .regularExpression) != nil
    }

    public static let favorite = MenuTitleFavorite(bundleID: bundleID, itemTitle: "喜欢歌曲", commandKey: "L",
                                                   confirmWait: 2, readState: { playBarFavorited() })

    /// 当前这首喜欢了没有;读不到为 nil。会阻塞跨进程查询,别在主线程调。
    public static func readFavorited() -> Bool? { favorite.read() }

    /// 设成喜欢 / 不喜欢,返回到没到(见 `MenuTitleFavorite.set`)。会阻塞,别在主线程调。
    public static func setFavorited(_ value: Bool) -> Bool { favorite.set(value) }

    /// 在各窗口里找总时长文字所在的那一层,读同层(含下一层)那颗心。
    static func playBarFavorited() -> Bool? {
        guard let app = MenuBarAX.application(bundleID: bundleID) else { return nil }
        var visited = 0
        func search(_ e: AXUIElement, depth: Int) -> Bool? {
            visited += 1
            guard depth < 12, visited < 2000 else { return nil }
            let children = MenuBarAX.children(e)
            if children.contains(where: { isPlayBarDuration(MenuBarAX.string($0, kAXDescriptionAttribute) ?? "") }) {
                for child in children {
                    for candidate in [child] + MenuBarAX.children(child)
                    where MenuBarAX.string(candidate, kAXRoleAttribute) == kAXButtonRole {
                        if let value = favorited(forHeartDescription: MenuBarAX.string(candidate, kAXDescriptionAttribute) ?? "") {
                            return value
                        }
                    }
                }
                return nil
            }
            for child in children {
                if let value = search(child, depth: depth + 1) { return value }
            }
            return nil
        }
        for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute) {
            if let value = search(window, depth: 0) { return value }
        }
        return nil
    }
}
