import Foundation

/// 网易云音乐的「喜欢」。它没有脚本接口(无 .sdef);唯一的通道是它自己菜单栏「控制」里「喜欢歌曲」那一项(快捷键 ⌘L):
/// 标题就是当前这首的状态,跟着当前曲目走,按一下翻转(读写约定见 `MenuTitleFavorite`)。它只有简体和英文两套界面,标题取自
/// 它自己的语言包(`Like` / `Dislike`)。同一个菜单里的随机 / 循环不打勾、读不出当前档,不接。见 07 章决策 146、147。
public enum NetEaseMenuControl {
    public static let bundleID = "com.netease.163music"

    /// 「喜欢歌曲」那一项的标题 → 当前这首喜欢了没有(简体、英文两套界面)。纯函数,selftest 覆盖。
    public static func favorited(forTitle title: String) -> Bool? {
        switch title.trimmingCharacters(in: .whitespaces) {
        case "取消喜欢", "Dislike": return true
        case "喜欢歌曲", "Like": return false
        default: return nil
        }
    }

    /// 按下之后标题实测 1.5 秒内翻过来;认那一项时连同快捷键 ⌘L 一起认(英文界面的标题是常见短词)。
    public static let favorite = MenuTitleFavorite(bundleID: bundleID, commandKey: "L", confirmWait: 2.5,
                                                   state: { favorited(forTitle: $0) })

    /// 当前这首喜欢了没有;读不到为 nil。会阻塞一次跨进程查询,别在主线程调。
    public static func readFavorited() -> Bool? { favorite.read() }

    /// 设成喜欢 / 不喜欢,返回到没到(见 `MenuTitleFavorite.set`)。会阻塞,别在主线程调。
    public static func setFavorited(_ value: Bool) -> Bool { favorite.set(value) }
}
