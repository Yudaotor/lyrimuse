import Foundation

/// 封面、三键各自摆在歌词哪一边(「显示封面」「显示播放控制」旁边那颗设置键里的「位置」,两项各管各的)。
///
/// rawValue 直接落 UserDefaults(`np:touchBarArtworkSide` / `np:touchBarControlsSide`),改名就是改存量用户的配置,别动。
public enum TouchBarSide: String, CaseIterable, Sendable {
    /// 歌词左边(默认,加这一项之前的排法)。
    case leading
    /// 歌词右边。
    case trailing
}

/// 展开态从左到右的一项。
public enum TouchBarSlot: Hashable, Sendable {
    /// App 自己的收起键:系统不给左端的 ✕ 时(`showsCollapseKey`)换成样子相同的这一颗
    /// (`TouchBarLyricsStyle.collapseItemWidth`)。
    case collapse
    case artwork
    case controls
    case lyrics

    /// 从左到右排哪几项:摆在左边的、歌词、摆在右边的;同一边上封面在三键左边。关掉的那一项拿掉;
    /// 要自己的收起键时(`showsCollapseKey`)最左边加上它。
    public static func order(artworkSide: TouchBarSide, controlsSide: TouchBarSide,
                             showsArtwork: Bool, showsControls: Bool, showsCollapseKey: Bool) -> [TouchBarSlot] {
        func items(on side: TouchBarSide) -> [TouchBarSlot] {
            (showsArtwork && artworkSide == side ? [.artwork] : [])
                + (showsControls && controlsSide == side ? [.controls] : [])
        }
        return (showsCollapseKey ? [.collapse] : []) + items(on: .leading) + [.lyrics] + items(on: .trailing)
    }

    /// 左端放不放 App 自己的收起键:系统不给 ✕ 的时候放 —— 展开条占满整条(`fullWidth`,隐藏功能栏),或者本 App
    /// 在前台(系统模态条在发起它的 App 处于前台时不画 ✕,一转到后台又画;`DFRSystemModalShowsCloseBoxWhenFrontMost`
    /// 传什么、什么时候传都一样。Xcode 触控栏模拟器实测,见 17 章)。收起靠系统的 `minimizeSystemModalTouchBar:`,
    /// 这个入口缺了(`canMinimize`)就不放。这一颗连间距 64pt,跟 2nd generation 上系统 ✕ 那一块一样宽,前后台切换时
    /// 歌词那一格的宽不变(1st generation 上系统那一块是 80pt,差 16pt)。
    public static func showsCollapseKey(fullWidth: Bool, appIsActive: Bool, canMinimize: Bool) -> Bool {
        canMinimize && (fullWidth || appIsActive)
    }
}
