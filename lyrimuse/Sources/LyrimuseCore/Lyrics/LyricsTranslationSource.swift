import Foundation

/// 一份译文是**歌词源自带的社区翻译**还是 **collector 机翻补的**。
///
/// 权威源是 enrich 缓存里的 `lyrics_tr_source` 字段(collector 侧 `enrichEntry.LyricsTrSource`):
/// 空 = 社区翻译(网易云 / Musixmatch 随冠军候选一起带过来的),`"machine"` = collector 的
/// translate.go 补的(端上 Apple 翻译 helper 或 MyMemory 兜底)。老条目没有这个字段,读成空
/// **正是事实** —— 机翻这条路是后加的,那之前所有译文都来自歌词源。
public enum LyricsTranslationSource: String, CaseIterable, Sendable {
    /// 没有译文。
    case none
    /// 歌词源自带的社区翻译。
    case community
    /// collector 机翻补的。
    case machine

    /// ⚠️ **这个字符串必须跟 collector 的 `lyricsTrSourceMachine`(translate.go)逐字节一致。**
    /// 两边没有任何编译期耦合 —— 哪天 Go 那边把它改成 "auto"/"mt"/别的,Swift 这边不会报错,
    /// 只会**静默**把所有机翻译文重新算成社区译文:统计面板的两个数字对调、歌词管理里那枚
    /// 紫色徽章集体变绿,而且没有任何东西会红。selftest 有一条闸直接去扫 Go 源码对账。
    public static let machineSentinel = "machine"

    /// - Parameters:
    ///   - hasTranslation: 这条到底有没有译文正文(`lyrics_tr` 非空)。**必须先判它** ——
    ///     `lyrics_tr_source` 为空既可能是"社区译文",也可能是"压根没有译文",光看那个字段
    ///     分不出来,会把三千多条没译文的歌全算成社区译文。
    ///   - trSource: `lyrics_tr_source` 的原始值。
    public static func classify(hasTranslation: Bool, trSource: String) -> LyricsTranslationSource {
        guard hasTranslation else { return .none }
        return trSource == machineSentinel ? .machine : .community
    }
}
