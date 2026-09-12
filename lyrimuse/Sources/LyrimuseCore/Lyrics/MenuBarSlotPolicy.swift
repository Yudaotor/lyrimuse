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
/// 所以规则是:短命行不改几何。由此得到一条可以论证的不变式 —— 只有"活得比静默窗长"的行
/// 才有资格改几何,那么下一行的换行时刻必然已经离上次重建 ≥ 静默窗,它的几何变化就**一定**
/// 在换行那一刻当场落地,不会再拖到句中。
///
/// ⚠️ **2026-09-11 订正:上面这条不变式原来是不成立的,漏在"加宽"上。**
///
/// 旧实现只管收缩(函数原名 `skipsShrink`),第一行就是 `guard shrinkBy > 0 else { return false }`
/// —— **加宽完全豁免时长判据**。于是一句只活 1.5s 的短句照样能靠加宽烧掉重建配额,下一句
/// (往往活很久)的几何就被推到句中才落地。用户 2026-09-11 报的「换行时先按上一句的长度渲染,
/// 然后同一行又变一次」正是这一幕,实测抓到的现行:
///
/// ```
/// slot rebuild: icon(38.5) -> text(105.96)              ← 占位/首句建槽,配额清零
/// slot rebuild deferred 2.942s: text -> text(221.45)    ← 下一句要 221.45(2.1 倍),撞进静默窗
/// slot rebuild: text(105.96) -> text(221.45)            ← 2.94s 后才落地 = 句中,同一句变两次
/// ```
///
/// 复采 40 分钟 / 39 次重建:**14 次(36%)的相邻间隔精确落在 3.00–3.25s**(= 节流定时器自己
/// 到点触发,必然落在句中),其中 **11 次是加宽**。这个 36% 跟 2026-09-03 加 `skipsShrink`
/// **之前**记录的 37% 一模一样 —— 那次修复对"句中落地"毫无改善,因为它只堵了收缩这一半。
///
/// 两个方向都过时长判据之后,不变式才真的成立。**代价说清楚**:一句活不过静默窗、又装不下的
/// 短句,会在偏窄的槽里滚完它那 ≤3 秒,而不是加宽。这是刻意的取舍 —— 它滚 3 秒,换下一句
/// (往往活十几秒)不在用户眼前跳一下。
///
/// ⚠️ 仍然**只在两个歌词槽之间**生效(判断在调用点的 `lyricSlotClasses`)。图标↔歌词那次重建
/// 不受这里管,所以"间奏 / 暂停回来之后的第一句"仍可能句中落地 —— 上面那段现行的第一行
/// (`icon -> text(105.96)`)就是它。那要靠"占位槽按下一句定宽"(`PlaybackCoordinator.nextLineText`)
/// 另外解,不在 2026-09-11 这次范围内。
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

    /// 值得为它重建一次的最小**加宽**量(2026-09-11)。
    ///
    /// ⚠️ 这条**推翻了**本文件原来那句「只对收缩设死区:加宽方向哪怕只差几 pt 也得给 —— 差一点点
    /// 装不下,整句就会退化成跑马灯滚,那是可读性的悬崖」。推翻的依据:加宽被跳过时,跑马灯滚的
    /// 距离**恰好就是欠的那几 pt**(`MenuBarMarquee.pacing` 的 maxOffset = fullWidth - windowWidth),
    /// 6pt 摊在一句十几秒的行上是 0.x pt/s,肉眼是静止的 —— 那不是悬崖。而它换来的是一次整项
    /// 重建 + 邻居重排,还顺带把下一句的几何推进静默窗。
    ///
    /// 实测原样(2026-09-11):`text(222.909180) → fixed(223.500000)`,**0.59pt** 的加宽也在重建;
    /// 两句都长到顶着上限时,这种亚可见的差是常态(自适应下 `.text` 的槽宽=文字宽、`.fixed` 的
    /// 槽宽=最大宽度,分界只差 0.5pt 容差)。
    ///
    /// 跟收缩取同一个 6pt:两个方向"肉眼分辨不出来"的量级是同一个(本机 13pt 字号下半个汉字),
    /// 没有理由给两个数。
    public static let minimumWidenPoints: CGFloat = 6

    /// 这次**改槽宽**该不该跳过(2026-09-11 起两个方向对称;原名 `skipsShrink`,只管收缩)。
    ///
    /// - 两个方向同样对待:变化量小于该方向的死区(`minimumShrinkPoints` /
    ///   `minimumWidenPoints`)一律跳过,跟这一句活多久无关(见那两个常量的注释)。
    /// - `dwellSeconds` 是这一句**总共会显示多久**(`PlaybackCoordinator.compactDwellSeconds`),
    ///   取不到(nil)时一律照旧改 —— 判据不成立就不该改变既有行为。
    /// - 时长判据用"小于"而不是"小于等于":恰好等于静默窗的行留给"照旧改"那一侧,因为它
    ///   换到下一行时静默窗刚好走完,不会拖累下一行。
    /// - ⚠️ **长度完全没变时返回 false**(不是 true)。那种情况是"形态翻转、槽宽不动"
    ///   (`text(223.5) ↔ fixed(223.5)`),该交给调用点的 `needsRebuild` 判 —— 那条会走
    ///   `render` 把新形态正确画出来;这里若返回 true 会改走 `interim`,丢掉逐字染色 /
    ///   进度图标 / 双排这几条只有 `render` 才有的东西。
    public static func skipsResize(
        currentLength: CGFloat, targetLength: CGFloat,
        dwellSeconds: Double?, quietSecs: Double
    ) -> Bool {
        let delta = targetLength - currentLength
        guard delta != 0 else { return false }
        let deadZone = delta > 0 ? minimumWidenPoints : minimumShrinkPoints
        if abs(delta) < deadZone { return true }
        guard let dwellSeconds else { return false }
        return dwellSeconds < quietSecs
    }

    /// 占位态的槽宽该给多少(2026-09-11)。
    ///
    /// 占位文字(「♪ 歌名」兜底或间奏的 ♪)的宽度跟**即将到来的那一句**毫无关系,所以从占位
    /// 切到歌词时槽宽必然要改一次。改在哪一侧是唯一的选择:
    ///
    /// - 改在歌词出现**之后** = 那一句先按占位槽画一版、槽宽跟上再画一版 → **同一句变两次**
    ///   (用户 2026-09-11 报的就是这个,实测原样
    ///   `icon(38.5) -> text(112.423461)` 紧跟 `text(112.42) -> fixed(223.500000)`);
    /// - 改在歌词出现**之前** = 占位期间就把槽撑到下一句要的宽度 → 歌词一出现几何已经对了,
    ///   只渲染一次。这个函数选的是这一侧。
    ///
    /// 这是本文件那条不变式管不到的一半:`skipsResize` 只在两个**歌词槽**之间生效,
    /// 图标↔占位↔歌词这几跳不受它管。
    ///
    /// ⚠️ **代价**:占位期间这一项比它自己需要的宽,「♪ 歌名」居中浮在按下一句尺寸开出来的
    /// 槽里。跟自适应"省空间"的初衷有点冲突,换来的是邻居少挪一次(icon → 宽槽,而不是
    /// icon → 窄槽 → 宽槽)+ 歌词只渲染一次。用户 2026-09-11 拍板要后者。
    ///
    /// - `isPlaceholder` 为 false 时**原样返回 naturalWidth**(连上限都不夹):正常歌词句
    ///   的槽宽口径一个字不动,这条只加在占位那一侧。
    /// - 上限夹在 `maxWidth`:下一句超上限时槽就等于最大宽度,而那一句到时候会是 `.fixed`
    ///   (槽宽也是最大宽度)—— 两边同一个数,配合"长度相同不重建"连形态翻转那次都省了。
    /// - `upcomingWidth` 取不到(歌词还没解析出来)时调用方传 0,退化成 naturalWidth。
    public static func slotWidth(
        naturalWidth: CGFloat, upcomingWidth: CGFloat,
        isPlaceholder: Bool, maxWidth: CGFloat
    ) -> CGFloat {
        guard isPlaceholder else { return naturalWidth }
        return min(maxWidth, max(naturalWidth, upcomingWidth))
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
