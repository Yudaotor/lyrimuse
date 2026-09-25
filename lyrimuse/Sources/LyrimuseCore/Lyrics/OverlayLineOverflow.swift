/// 经典桌面悬浮歌词「一行放不下时」怎么办。
///
/// - `wrap`(默认,既有行为):交给 `WrapLayout` 折到下一行,窗口按内容增高(顶边固定
///   向下长)。整块歌词因此会随句子长短忽高忽低,但一眼能看全整句。
/// - `scroll`:每一行都只占一行高,放不下的部分横向滚动(`MarqueeText`)。窗口高度不再
///   随句子长短变,代价是同一时刻看不全整句。
///
/// **经典桌面悬浮歌词和歌词窗口的迷你尺寸**各有一颗(两个设置键)。其余展示面的排法是它们
/// 各自形态的固有约束、不可配:灵动岛和菜单栏只有一行高、一直是滚动;歌词窗口完整尺寸是
/// 一整页正文、一直是换行。
public enum OverlayLineOverflow: String, Codable, Hashable, CaseIterable, Sendable, Identifiable {
    case wrap
    case scroll

    public var id: Self { self }
}
