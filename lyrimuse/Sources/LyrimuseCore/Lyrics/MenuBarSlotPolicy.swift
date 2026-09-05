import CoreGraphics
import Foundation

/// 菜单栏这一项**值不值得为这一句改槽宽**的判据(2026-09-03)。
///
/// 背景:自适应宽度模式下,槽宽跟着每一句的文字宽走,而 macOS 的菜单栏只在项**出生那一刻**
/// 给邻居排位 —— 所以每一次槽宽变化都是一次"整项拆掉重建"(见 `MenuBarStatusItem.present`
/// 头注的两条铁律)。重建又不能连发(两次相隔 ~1s 会把邻居像素晾在旧位置且不自愈),于是有
/// 了 3 秒静默窗:窗内的几何变化先推迟、内容照旧实时画进**还没变**的槽里。
///
/// 用户 2026-09-03 报的抖动就出在这条推迟上,实测抓到的现行(菜单栏 debug 日志):
///
/// ```
/// 12:16:49.953  rebuild:  text(121.19) -> text(56.70)     ← 换行,为一句只活 1.2s 的短句缩槽
/// 12:16:51.189  deferred 1.763s:       -> text(134.09)    ← 下一句要 134.09,撞在静默窗里
/// 12:16:53.154  rebuild:  text(56.70)  -> text(134.09)    ← 唱到第 2 秒才落地,槽宽当场 ×2.4
/// ```
///
/// 40 分钟 91 次重建里,**37%(32/86)的相邻间隔精确落在 3.00–3.25s** —— 压在静默窗地板
/// (3.05s)上的一个尖峰,而真实换行间隔是 4~40s 的长尾。也就是说约三分之一的槽宽变化根本
/// 不是换行触发的,是节流定时器自己到点触发的,**必然落在句中**。
///
/// 病根不是节流本身,是**为一句活不过静默窗的短句花掉了重建配额**:那次收缩对可读性零收益
/// (文字本来就装得下,只是槽偏宽),却害得下一句(往往长得多)的加宽被推到句中才落地。
///
/// 所以规则是:**短命行只许加宽、不许收窄**。由此得到一条可以论证的不变式 ——
/// 只有"活得比静默窗长"的行才有资格改几何,那么下一行的换行时刻必然已经离上次重建 ≥ 静默窗,
/// 它的几何变化就**一定**在换行那一刻当场落地,不会再拖到句中。
public enum MenuBarSlotPolicy {
    /// 值得为它重建一次的最小收缩量。
    ///
    /// 上面那条规则上线后复采日志,抓到另一种同源的浪费:`text(250.749512) → text(250.438477)`
    /// —— **0.31pt** 的差也触发了一次整项重建,而且照样花掉一次配额、把下一句的几何推进静默窗。
    /// 两句长度接近上限的长句之间,这种亚像素级的差是常态。
    ///
    /// 取 6pt ≈ 本机菜单栏字号(13pt)下半个汉字:比它小的收缩肉眼分辨不出来,却要付一次
    /// 重建 + 邻居重排。**只对收缩设死区**:加宽方向哪怕只差几 pt 也得给 —— 差一点点装不下,
    /// 整句就会退化成跑马灯滚(`MenuBarMarqueeRenderer.presentation` 的判据是 0.5pt 容差),
    /// 那是可读性的悬崖,不是观感差异。
    ///
    /// 死区不会累积成"永远缩不回去":每次都拿**当前槽宽**跟目标比,连着几句各小一点的话,
    /// 差额是相对同一个基准累加的,一旦越过 6pt 就照常收缩。
    public static let minimumShrinkPoints: CGFloat = 6

    /// 这次**收缩**该不该跳过。
    ///
    /// - 只管收缩:加宽意味着这一句在当前槽里装不下、正被迫当跑马灯滚,那是可读性问题,
    ///   值得一次重建;收缩只是"槽比文字宽一截"的观感问题,再急也不急在这 3 秒。
    /// - 收缩量小于 `minimumShrinkPoints` 一律跳过,跟这一句活多久无关(见该常量的注释)。
    /// - `dwellSeconds` 是这一句**总共会显示多久**(`PlaybackCoordinator.compactDwellSeconds`),
    ///   取不到(nil)时一律照旧收缩 —— 判据不成立就不该改变既有行为。
    /// - 时长判据用"小于"而不是"小于等于":恰好等于静默窗的行留给"照旧收缩"那一侧,因为它
    ///   换到下一行时静默窗刚好走完,不会拖累下一行。
    public static func skipsShrink(
        currentLength: CGFloat, targetLength: CGFloat,
        dwellSeconds: Double?, quietSecs: Double
    ) -> Bool {
        let shrinkBy = currentLength - targetLength
        guard shrinkBy > 0 else { return false }
        if shrinkBy < minimumShrinkPoints { return true }
        guard let dwellSeconds else { return false }
        return dwellSeconds < quietSecs
    }

    /// 「这一刻菜单栏该显示什么文字」的兜底(2026-09-04):有歌词句就显示歌词句(包括间奏的 ♪);
    /// 压根没有可显示的行、这首歌又在播放且不是广告,就用「♪ 歌名」占住槽位,而不是收回成小图标。
    ///
    /// 为什么值得:`compactShowsPlaceholder` 只在「唱完了、下一句还早」为真,整首没歌词 / 还在搜的歌
    /// 文字为空,菜单栏会把槽收回成图标 —— 搜索超过 3s 观察窗就先塌再撑(一对状态项重建,见
    /// `MenuBarStatusItem.present` 头注的铁律),没歌词的歌整首只剩图标。灵动岛 / 悬浮歌词都有占位
    /// 文案,菜单栏是唯一直接塌回图标的展示面。固定宽度模式下有词没词几何完全不变。
    ///
    /// 三条刻意保留的边界:① `isPlaying` 为 false 一律 nil —— 2026-08-19 用户定的「暂停不占宽」,
    /// 参考做法"暂停仍显示当前句"不学;② 广告态不显示广告标题;③ 没歌名就还是图标,不做品牌兜底。
    /// 返回 nil = 照旧收回图标;`isFallback` 告诉调用方这不是歌词句(配速不按歌词时长算)。
    public static func displayText(
        lyricText: String, title: String, isPlaying: Bool, isAdBreak: Bool,
        showsTitleWhenNoLyrics: Bool, placeholderGlyph: String
    ) -> (text: String, isFallback: Bool)? {
        guard isPlaying else { return nil }
        if !lyricText.isEmpty { return (lyricText, false) }
        guard showsTitleWhenNoLyrics, !isAdBreak else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (placeholderGlyph + " " + trimmed, true)
    }
}
