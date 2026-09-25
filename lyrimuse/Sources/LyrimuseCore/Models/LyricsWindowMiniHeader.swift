import Foundation

/// 迷你尺寸歌词窗口顶部那一行要显示哪几样。
///
/// 只管**迷你尺寸**。完整尺寸的曲目信息在左栏(封面下面那块 `trackInfoRow`),是另一套排版,
/// 不吃这个设置。
///
/// 做成 OptionSet 而不是三个 Bool:三个 Bool 要三个 `Keys`、三个 `@Published`、三条订阅、
/// 三次 init 赋值,而它们永远一起读、一起写。位掩码只占一个存储键,加第四样(比如年份)也只是
/// 多一个 case。
///
/// 存进 UserDefaults 的是 `rawValue`(Int)。**位的值一旦定下就不能改**——改了等于把老用户存的
/// 选择错位解读(比如把"歌名+歌手"读成"歌手+专辑")。要废弃某一样就让那个位空着,别复用。
public struct LyricsWindowMiniHeaderFields: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let title = LyricsWindowMiniHeaderFields(rawValue: 1 << 0)
    public static let artist = LyricsWindowMiniHeaderFields(rawValue: 1 << 1)
    public static let album = LyricsWindowMiniHeaderFields(rawValue: 1 << 2)

    /// 默认「歌名 · 歌手」—— 就是加这颗设置之前写死的那两样,没碰过设置的人升级后观感不变。
    public static let `default`: LyricsWindowMiniHeaderFields = [.title, .artist]

    /// 渲染顺序固定:歌名 → 歌手 → 专辑。
    ///
    /// **不做成可排序的**:这一行是"这是哪首歌"的一句话交代,歌名在前是所有播放器的共识;
    /// 让它可排序只会多一份状态、多一处 UI,换不来什么。
    public static let orderedAll: [LyricsWindowMiniHeaderFields] = [.title, .artist, .album]

    /// 按固定顺序挑出要显示的那几样,空串(比如这首歌没有专辑名)自动跳过。
    ///
    /// 放在 Core 而不是视图里,是因为"选了但值是空"这条边界最容易漏 —— 漏了就会画出
    /// 「歌名 - 」这种尾巴挂着分隔符的行。selftest 钉着它。
    public func visibleValues(title: String, artist: String, album: String) -> [String] {
        visibleParts(title: title, artist: artist, album: album).map(\.value)
    }

    /// 同 `visibleValues`,每一段带上它是哪一样 —— 歌手 / 专辑那两段要各自接「看简介」的点击。
    public struct Part: Equatable, Sendable {
        public let field: LyricsWindowMiniHeaderFields
        public let value: String

        public init(field: LyricsWindowMiniHeaderFields, value: String) {
            self.field = field
            self.value = value
        }
    }

    public func visibleParts(title: String, artist: String, album: String) -> [Part] {
        let source: [LyricsWindowMiniHeaderFields: String] =
            [.title: title, .artist: artist, .album: album]
        return Self.orderedAll.compactMap { field in
            guard contains(field), let v = source[field] else { return nil }
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Part(field: field, value: trimmed)
        }
    }
}
