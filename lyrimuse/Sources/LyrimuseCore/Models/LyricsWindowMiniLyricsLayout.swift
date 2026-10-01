/// 歌词窗口迷你尺寸中间那块歌词怎么排。
///
/// - `oneLine`:只有当前句。还没唱到第一句、又不在前奏三点里时,那一格用下一句(压暗缩小)顶上,
///   不留一块空白(判据见 `MiniLyricsSelection.showsNextLine`)。
/// - `twoLines`(默认):当前句 + 下一句,换句直接替上来。
/// - `list`:跟完整尺寸同一份整页滚动列表,当前行锚在偏上位置,上面是唱过的、下面是接下来的。
///
/// `twoLines` 的存盘值固定是 `compact`:已存的设置靠它认,改了就全落回默认。
/// case 的声明顺序就是设置页分段控件的顺序。
///
/// 只有迷你有这一项:完整尺寸本来就是整页列表。
public enum LyricsWindowMiniLyricsLayout: String, Codable, Hashable, CaseIterable, Sendable, Identifiable {
    case oneLine
    case twoLines = "compact"
    case list

    public var id: Self { self }
}
