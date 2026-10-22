import AppKit
import ApplicationServices
import Foundation

/// QQ 音乐的随机 / 循环和「喜欢」。它没有脚本接口(无 .sdef),系统媒体遥控的随机 / 循环命令也不接;唯一的通道是它自己菜单栏
/// 「播放控制」:「播放模式」那三项(顺序播放 / 随机播放 / 单曲循环)读当前档看哪一项打了勾、切换对那一项 `AXPress`;
/// 「喜欢歌曲」那一项的标题就是状态(喜欢了写「取消喜欢」),按一下翻转,标题 1 秒内跟着变(读写约定见 `MenuTitleFavorite`,
/// 网易云同一种做法)。
/// 需要「辅助功能」权限,没有就读不到、按钮不显示。见 07 章决策 130、138、147。
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

    /// 按下「喜欢」之后标题实测 1 秒内翻过来。
    public static let favorite = MenuTitleFavorite(bundleID: bundleID, confirmWait: 2, state: { favorited(forTitle: $0) })

    /// 当前这首喜欢了没有;读不到为 nil。会阻塞一次跨进程查询,别在主线程调。
    public static func readFavorited() -> Bool? { favorite.read() }

    /// 设成喜欢 / 不喜欢,返回到没到(见 `MenuTitleFavorite.set`)。会阻塞,别在主线程调。
    public static func setFavorited(_ value: Bool) -> Bool { favorite.set(value) }

    /// 当前档;QQ 没在跑、没有辅助功能权限、找不到那个子菜单时为 nil。会阻塞一次跨进程查询,别在主线程调。
    public static func readMode() -> MusicPlaybackController.MusicPlaybackMode? {
        guard let items = modeItems() else { return nil }
        return markedMode(items.map { (title: $0.title, mark: string($0.element, "AXMenuItemMarkChar")) })
    }

    /// 切到某一档,返回按没按下去。QQ 没有列表循环,传 `.repeatAll` 回 false。
    public static func setMode(_ mode: MusicPlaybackController.MusicPlaybackMode) -> Bool {
        guard let item = modeItems()?.first(where: { Self.mode(forTitle: $0.title) == mode }) else { return false }
        return MenuBarAX.press(item.element)
    }

    private static func menuBar() -> AXUIElement? { MenuBarAX.menuBar(bundleID: bundleID) }

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

    private static func string(_ e: AXUIElement, _ name: String) -> String? { MenuBarAX.string(e, name) }

    private static func menuChildren(_ e: AXUIElement) -> [AXUIElement] { MenuBarAX.menuChildren(e) }
}
