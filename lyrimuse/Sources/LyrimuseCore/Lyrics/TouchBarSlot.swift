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
    /// App 自己的收起键:隐藏功能栏时系统不给左端的 ✕,换成样子相同的这一颗
    /// (`TouchBarLyricsStyle.collapseItemWidth`)。
    case collapse
    case artwork
    case controls
    case lyrics

    /// 从左到右排哪几项:摆在左边的、歌词、摆在右边的;同一边上封面在三键左边。关掉的那一项拿掉;
    /// 隐藏功能栏时最左边加上收起键。
    public static func order(artworkSide: TouchBarSide, controlsSide: TouchBarSide,
                             showsArtwork: Bool, showsControls: Bool, hidesControlStrip: Bool) -> [TouchBarSlot] {
        func items(on side: TouchBarSide) -> [TouchBarSlot] {
            (showsArtwork && artworkSide == side ? [.artwork] : [])
                + (showsControls && controlsSide == side ? [.controls] : [])
        }
        return (hidesControlStrip ? [.collapse] : []) + items(on: .leading) + [.lyrics] + items(on: .trailing)
    }
}
