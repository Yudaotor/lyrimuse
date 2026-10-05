import Foundation

/// 一条缓存歌词的**成色**。「歌词管理」窗口的列表/详情页和设置页的歌词库统计面板都按它分类。
///
/// 这是一次**有优先级的判定**,不是四个独立布尔 —— 一条条目常常同时满足好几个条件
/// (`lyrics_yrc` 是在 `lyrics` 之上补的,所以"有逐字"的条目几乎一定也"有逐行"),必须只落进
/// 一个桶,否则统计面板里各项之和会超过总数,用户一眼就看出它在瞎报。
///
/// 放在 LyrimuseCore 而不是跟统计面板放一起:App target 不可被 `lyrimuse-selftest` 引用
/// (它只依赖 LyrimuseCore),而"优先级阶梯"正是那种改错了**完全不报错、只是数字悄悄变形**
/// 的东西,值得有机械闸钉着。显示用的名字和配色留在 App 侧(那边要 L10n / SwiftUI)。
public enum LyricsKind: String, CaseIterable, Sendable {
    /// 有 `lyrics_yrc`:逐字时间轴,悬浮歌词能做逐字填色。
    case wordByWord
    /// 有带时间戳的 LRC(但没有逐字):能跟着播放滚动。
    case lineByLine
    /// 只有 `plain_lyrics`(引擎侧的纯文本兜底):有词可读,但没有任何时间戳。
    case plainText
    /// 按纯音乐处理:引擎联网确证过"这首本来就没有词"(lrclib 的 instrumental / 网易云的 pureMusic),
    /// 或者用户手动标的。
    ///
    /// 排在最前:标了纯音乐就不显示歌词(EnrichCacheReader.makeLyrics),条目里留着的歌词不算数。
    /// 跟"没搜到"(`.none`)是两回事,统计面板不能把确证过的纯音乐算进「无歌词」。
    case instrumental
    /// 什么都还没有 —— 没搜到,或者还没轮到它。
    case none

    /// 判定一条条目的成色。四个入参对应 `EnrichCacheStore.Summary` 上的同名字段;刻意收成
    /// 裸 `Bool` 而不是收整个 Summary —— 那个类型在 App target 里,而这里要能被 selftest 穷举。
    public static func classify(
        hasWordTiming: Bool,
        hasLyrics: Bool,
        hasPlainTextFallback: Bool,
        isInstrumental: Bool
    ) -> LyricsKind {
        if isInstrumental { return .instrumental }
        if hasWordTiming { return .wordByWord }
        if hasLyrics { return .lineByLine }
        if hasPlainTextFallback { return .plainText }
        return .none
    }
}
