import Foundation

/// 「这一行歌词位现在该显示什么」——歌词展示面共用的那条判定链。
///
/// 抽出来的理由是**顺序**。这条链里有三处"必须排在谁前面"的硬约束,在
/// LyricsOverlayView / NotchLyricsView / LyricsWindowView 三处的注释里各写了一遍:
///   * 「广告中」「纯音乐」要排在「搜索歌词中…」**前面** —— 这两种情况本来就不会有词,
///     落到"搜索中"就会一直转圈;
///   * 「暂无歌词」要排在「网络连接失败」和「搜索歌词中…」**前面** —— 搜完了确实没有,
///     不是网断了、也不是还没搜到;
///   * 「网络连接失败」要排在「搜索歌词中…」**前面** —— 搜不动是因为网断了。
///
/// 顺序错了不编译报错、不崩、不报警,只会长期显示一句**似是而非**的状态(比如一首纯音乐
/// 永远停在"搜索歌词中…")。所以它值得被 selftest 钉住,而不是靠每个 View 各自誊一遍。
///
/// 2026-08-19 加菜单栏面板那一行歌词时抽的:那是第四个要走同一条链的地方,再誊一遍就是
/// 四份。另外三处暂时还是各自的内联版本(它们各有描边/阴影/配色的包装),要收敛得另开一刀。
public enum LyricsLineDisplay: Equatable, Sendable {
    /// 有逐字时间轴 —— 调用方按 words 做卡拉OK填色。
    case words
    /// 只有整行文本(行级 LRC,没有逐字数据)。
    case plain
    case adBreak
    case instrumental
    case noLyrics
    case networkDown
    case searching
    /// 没在放 / 这一刻确实没什么可显示的(间奏、还没开始)。
    case idle

    /// 入参全部是"事实"布尔量,由各个 View 从 PlaybackCoordinator 读;这里只排顺序。
    public static func resolve(
        hasWordTiming: Bool,
        hasCurrentLine: Bool,
        isAdBreak: Bool,
        isInstrumental: Bool,
        hasNoLyrics: Bool,
        networkDown: Bool,
        hasLyricsContent: Bool,
        isPlaying: Bool
    ) -> LyricsLineDisplay {
        // 有词就直接唱 —— 排在所有状态之前,跟另外三处一致。
        if hasWordTiming { return .words }
        if isAdBreak { return .adBreak }
        if isInstrumental { return .instrumental }
        if hasNoLyrics { return .noLyrics }
        if networkDown, !hasLyricsContent { return .networkDown }
        if isPlaying, !hasLyricsContent { return .searching }
        return hasCurrentLine ? .plain : .idle
    }
}
