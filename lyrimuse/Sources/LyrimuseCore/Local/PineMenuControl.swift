import ApplicationServices
import Foundation

/// Pine Player 的循环。系统媒体遥控的循环命令它不接,通道是菜单栏「控制」里「重复模式」的子菜单:四项恰好一项打勾,依次是列表循环、
/// 列表放一遍就停(简体界面误译成「选中的列表」,内部名 `repeat_mode_list_once`)、单曲循环、放完当前这首就停(「无」),对那一项 `AXPress` 切过去,勾 0.2 秒内跟上。它的菜单标题有十种语言、不在它的语言包里,所以按
/// 位置认:「控制」那个菜单按播放控制的快捷键认(`PlaybackMenuControl.command(forMenuKey:)`),子菜单是里面恰好四项、
/// 恰好一项打勾的那一个。随机那一项没有勾、读不出开没开,不接。需要「辅助功能」权限,没有就读不到、按钮不显示。见 02 章决策 156、174。
public enum PineMenuControl {
    public static let bundleID = PlaybackPlayer.pinePlayer.bundleIdentifier
    /// 列表循环、单曲循环;没有随机。
    public static let options: MusicPlaybackController.PlaybackModeOptions = [.repeatAll, .repeatOne]

    /// 子菜单里打勾的那一项(序号)→ 档位:放一遍就停和「无」都显示成不循环。纯函数,selftest 覆盖。
    public static func mode(checkedIndex: Int) -> MusicPlaybackController.MusicPlaybackMode? {
        switch checkedIndex {
        case 0: return .repeatAll
        case 1, 3: return .list
        case 2: return .repeatOne
        default: return nil
        }
    }

    /// 切到某一档该按哪一项;已经是这一档(「无」也算不循环)不用按,为 nil;随机为 nil。关循环按「放一遍就停」,不按「无」:
    /// 「无」放完当前这首就停,不接下一首。纯函数,selftest 覆盖。
    public static func indexToPress(for mode: MusicPlaybackController.MusicPlaybackMode, checkedIndex: Int) -> Int? {
        guard self.mode(checkedIndex: checkedIndex) != mode else { return nil }
        switch mode {
        case .repeatAll: return 0
        case .repeatOne: return 2
        case .list: return 1
        case .shuffle: return nil
        }
    }

    /// 当前档;Pine 没在跑、没有辅助功能权限、找不到子菜单时为 nil。会阻塞跨进程查询,别在主线程调。
    public static func readMode() -> MusicPlaybackController.MusicPlaybackMode? {
        readCheckedIndex().flatMap(mode(checkedIndex:))
    }

    /// 子菜单里打勾的那一项的序号;读不到为 nil(同 `readMode`)。预解析要分出「无」(放完就停),用它。
    public static func readCheckedIndex() -> Int? {
        guard let sub = submenu() else { return nil }
        return checkedIndex(sub)
    }

    /// 切到某一档,返回按下去了没有(已经是这一档也算)。传 `.shuffle` 回 false。会阻塞,别在主线程调。
    public static func setMode(_ mode: MusicPlaybackController.MusicPlaybackMode) -> Bool {
        guard mode != .shuffle, let sub = submenu(), let checked = checkedIndex(sub) else { return false }
        guard let index = indexToPress(for: mode, checkedIndex: checked) else { return true }
        return MenuBarAX.press(sub[index])
    }

    private static func checkedIndex(_ items: [AXUIElement]) -> Int? {
        let marked = items.indices.filter { !(MenuBarAX.string(items[$0], "AXMenuItemMarkChar") ?? "").isEmpty }
        return marked.count == 1 ? marked[0] : nil
    }

    /// 「控制」菜单里「重复模式」子菜单的四项。
    private static func submenu() -> [AXUIElement]? {
        guard let bar = MenuBarAX.menuBar(bundleID: bundleID) else { return nil }
        for top in MenuBarAX.menuChildren(bar) {
            let entries = MenuBarAX.menuChildren(top)
            let transport = entries.compactMap { item -> PlaybackMenuControl.Command? in
                guard let key = MenuBarAX.string(item, kAXMenuItemCmdCharAttribute) else { return nil }
                return PlaybackMenuControl.command(forMenuKey: key, modifiers: modifiers(item), player: .pinePlayer)
            }
            guard PlaybackMenuControl.isTransportMenu(transport) else { continue }
            for entry in entries {
                let sub = MenuBarAX.menuChildren(entry)
                if sub.count == 4, checkedIndex(sub) != nil { return sub }
            }
        }
        return nil
    }

    private static func modifiers(_ item: AXUIElement) -> Int {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &value) == .success else { return -1 }
        return (value as? NSNumber)?.intValue ?? -1
    }
}
