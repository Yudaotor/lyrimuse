import Foundation

/// 触控栏的「更多」页:点歌词旁边的「⋯」键,整条换成这一页;左端收起键照旧(见 17 章决策 47)。
///
/// 系统的弹出式触控栏项(`NSPopoverTouchBarItem`,含长按弹出)在系统模态条里弹不出来:模拟器里调 `showPopover`,
/// 它自己报看得见,画面不变。所以换页是改展开条的 `defaultItemIdentifiers`,跟拨「显示封面」同一个入口。
public enum TouchBarMorePage {
    /// 这一页从左到右的一项。
    public enum Item: Hashable, Sendable {
        /// 回到歌词那一页。
        case back
        /// 歌词校准:− 读数 +,步长同设置里的「微调步长」。
        case offset
        case favorite
        case shuffle
        case `repeat`
        case volume
    }

    /// 这一页没有操作多久回到歌词那一页。
    public static let autoReturnDelayMs = 8_000

    /// 这一页放哪几项:返回、歌词校准一直在;喜欢、随机、循环、音量只放当前播放器支持的(同灵动岛展开区:读数是 nil /
    /// 不能切那一档就不显示)。
    public static func items(supportsFavorite: Bool, canShuffle: Bool, canRepeat: Bool,
                             supportsVolume: Bool) -> [Item] {
        [.back, .offset]
            + (supportsFavorite ? [.favorite] : [])
            + (canShuffle ? [.shuffle] : [])
            + (canRepeat ? [.repeat] : [])
            + (supportsVolume ? [.volume] : [])
    }
}
