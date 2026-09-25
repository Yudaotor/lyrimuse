/// 歌词窗口迷你尺寸中间那块歌词怎么排。
///
/// - `compact`(默认,既有行为):只有当前句 + 下一句,换句直接替上来。
/// - `list`:跟完整尺寸同一份整页滚动列表,当前行锚在偏上位置,上面是唱过的、下面是接下来的。
///
/// 只有迷你有这一项:完整尺寸本来就是整页列表。
public enum LyricsWindowMiniLyricsLayout: String, Codable, Hashable, CaseIterable, Sendable, Identifiable {
    case compact
    case list

    public var id: Self { self }
}
