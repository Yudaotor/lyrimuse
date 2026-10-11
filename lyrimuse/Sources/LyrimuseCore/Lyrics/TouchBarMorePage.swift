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
        /// 播放进度:知道时长就显示,播放器不接受跳转时只显示、不能拖(同灵动岛的进度条)。
        case progress
        /// 歌词校准:− 读数 +,步长同设置里的「微调步长」。广告期间不放(广告没有歌词可校,同灵动岛)。
        case offset
        case favorite
        case shuffle
        case `repeat`
        case volume
    }

    /// 这一页没有操作多久回到歌词那一页。
    public static let autoReturnDelayMs = 8_000
    /// 这一页每颗键的宽(同三键的一格)。不占满整条时只有约 621pt,按默认宽度排,末尾几项会被系统藏掉(17 章决策 48)。
    public static let keyWidth: Double = 44
    /// 歌词校准中间那一格读数的宽:英文「Lyrics +10.0s」13pt 等宽数字放得下。
    public static let offsetReadoutWidth: Double = 96
    /// 两条滑杆最窄缩到多少。
    public static let progressMinWidth: Double = 100
    public static let volumeMinWidth: Double = 80

    /// 这一页放哪几项:返回一直在;进度只在知道这首多长时放;歌词校准广告期间不放;喜欢、随机、循环、音量只放当前播放器
    /// 支持的(同灵动岛展开区:读数是 nil / 不能切那一档就不显示)。
    public static func items(hasDuration: Bool, isAdBreak: Bool, supportsFavorite: Bool, canShuffle: Bool,
                             canRepeat: Bool, supportsVolume: Bool) -> [Item] {
        [.back]
            + (hasDuration ? [.progress] : [])
            + (isAdBreak ? [] : [.offset])
            + (supportsFavorite ? [.favorite] : [])
            + (canShuffle ? [.shuffle] : [])
            + (canRepeat ? [.repeat] : [])
            + (supportsVolume ? [.volume] : [])
    }
}
