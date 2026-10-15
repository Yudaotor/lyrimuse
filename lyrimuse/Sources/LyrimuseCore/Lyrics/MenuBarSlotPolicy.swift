import CoreGraphics
import Foundation

/// 菜单栏这一项**值不值得为这一句改槽宽**的判据。
///
/// 自适应宽度模式下,槽宽跟着每一句的文字宽走,而 macOS 的菜单栏只在项**出生那一刻**
/// 给邻居排位 —— 所以每一次槽宽变化都是一次"整项拆掉重建"(见 `MenuBarStatusItem.present`
/// 头注的两条铁律)。重建又不能连发(两次相隔 ~1s 会把邻居像素晾在旧位置且不自愈),于是有
/// 了 3 秒静默窗:窗内的几何变化先推迟、内容照旧实时画进**还没变**的槽里。
///
/// 推迟会让槽宽在**句中**才落地:为一句活不过静默窗的短句改了槽宽,花掉的是重建配额,下一句
/// (往往长得多)的几何就撞进静默窗、唱到一半才跳(实测约三分之一的槽宽变化是节流定时器自己到点
/// 触发的,必然落在句中)。所以规则是:短命行不改几何。由此得到一条可以论证的不变式 —— 只有
/// "活得比静默窗长"的行才有资格改几何,那么下一行的换行时刻必然已经离上次重建 ≥ 静默窗,它的
/// 几何变化就**一定**在换行那一刻当场落地。
///
/// **收缩和加宽都受这条时长判据约束**:只挡收缩的话,一句只活 1.5s 的短句照样能靠加宽烧掉重建
/// 配额,下一句的几何被推到句中才落地,换行时先按上一句的长度画一版、同一行又变一次(实测落在
/// 静默窗地板上的句中重建大多是加宽)。**代价**:一句活不过静默窗、又装不下的短句,会在偏窄的槽里
/// 滚完它那 ≤3 秒,而不是加宽 —— 它滚 3 秒,换下一句(往往活十几秒)不在眼前跳一下。
///
/// 只在**两个歌词槽之间**生效(判断在调用点的 `lyricSlotClasses`)。图标与歌词那次重建不归这里管,
/// 由 `slotWidth`(占位槽按下一句定宽)和调用方的落定窗管。实测与统计见 06 章决策 22、
/// 06 章「宽度模式与占位」。
public enum MenuBarSlotPolicy {
    /// 值得为它重建一次的最小收缩量。两句长度都接近上限的长句之间,亚像素级的差是常态(实测 0.31pt
    /// 的差也触发过一次整项重建),照样花掉一次配额、把下一句的几何推进静默窗。
    ///
    /// 取 6pt ≈ 本机菜单栏字号(13pt)下半个汉字:比它小的收缩肉眼分辨不出来,却要付一次
    /// 重建 + 邻居重排。
    ///
    /// 死区不会累积成"永远缩不回去":每次都拿**当前槽宽**跟目标比,连着几句各小一点的话,
    /// 差额是相对同一个基准累加的,一旦越过 6pt 就照常收缩。
    public static let minimumShrinkPoints: CGFloat = 6

    /// 值得为它重建一次的最小**加宽**量。加宽被跳过时,跑马灯滚的距离**恰好就是欠的那几 pt**
    /// (`MenuBarMarquee.pacing` 的 maxOffset = fullWidth - windowWidth),6pt 摊在一句十几秒的行上是
    /// 0.x pt/s,肉眼是静止的 —— 不是可读性的悬崖。而它换来的是一次整项重建 + 邻居重排,还顺带把
    /// 下一句的几何推进静默窗。两句都长到顶着上限时,这种亚可见的差是常态(实测 0.59pt 的加宽也在
    /// 重建;自适应下 `.text` 的槽宽=文字宽、`.fixed` 的槽宽=最大宽度,分界只差 0.5pt 容差)。
    ///
    /// 跟收缩取同一个 6pt:两个方向"肉眼分辨不出来"的量级是同一个(本机 13pt 字号下半个汉字),
    /// 没有理由给两个数。
    public static let minimumWidenPoints: CGFloat = 6

    /// 短命行"不值得为它改槽宽"的**偏差上限**:`skipsResize` 的时长判据只在偏差小于它时才跳过。
    /// 没有这条上限,句子**普遍**短于静默窗的歌("短句是少数、下一句活得久"这个假设整首不成立)
    /// 整首都不改槽宽,每一句都画在一个不属于自己的槽里(实测槽卡在一个宽度十几秒到两分钟,
    /// 最短那句右边空 76pt)。
    ///
    /// **120,跟 `MenuBarSlotFloor.shrinkTolerance` 解绑**:两个常量回答的不是同一个问题。地板的容差
    /// 决定**目标宽度**该不该缩(管留白);这条上限决定**一次改动值不值一次重建**(管闪烁)。一次重建
    /// 约 250ms 内容空窗,其中约 240ms 是系统 MenuBarAgent 在重排,优化我们这侧对闪烁毫无帮助,唯一能
    /// 减少闪烁的办法就是**少重建**。拿真实决策序列离线模拟:上限从 30 提到 120,重建从每 5.4s 一次
    /// 降到每 15.4s 一次(闪烁砍掉 65%),留白和欠宽只动了 ±4pt —— 留白的根源是句长本身大幅波动,
    /// 不是跳过了多少次改动。120 之后再大也没收益(剩下那几次是 dwell ≥ 静默窗的长句触发的)。
    ///
    /// **代价**:短命行欠宽到 120pt 之前都不会为它重建,它在偏窄的槽里滚完自己那 ≤3 秒(欠多少就滚
    /// 多少,见 `MenuBarMarquee.pacing` 的 maxOffset)。实测这一档的欠宽均值 42pt,跟 30pt 那档的
    /// 39pt 几乎一样。
    public static let shortLineDriftCeiling: CGFloat = 120

    /// 没开按宽度断句时,自适应宽度的起步槽宽取整首哪一行:按宽度从窄到宽排,取这个比例处的那一行
    /// (`LyricsSyncEngine.rowWidth`)。这一行以内的句子都不改槽宽;更宽的少数几句照旧撑宽、唱完按地板的
    /// 收缩容差缩回来。取整首最宽会让一句长句把整首都撑满,见 06 章决策 34。
    public static let songRowQuantile: Double = 0.9

    /// 这次**改槽宽**该不该跳过(两个方向对称)。
    ///
    /// - 两个方向同样对待:变化量小于该方向的死区(`minimumShrinkPoints` /
    ///   `minimumWidenPoints`)一律跳过,跟这一句活多久无关(见那两个常量的注释)。
    /// - `dwellSeconds` 是这一句**总共会显示多久**(`PlaybackCoordinator.compactDwellSeconds`),
    ///   取不到(nil)时一律照改 —— 判据不成立就不跳过。
    /// - 时长判据**有偏差上限**:短命行只在偏差小于 `shortLineDriftCeiling`
    ///   时才跳过。没有这条上限,句子普遍短于静默窗的歌整首都不改槽宽。
    /// - 时长判据用"小于"而不是"小于等于":恰好等于静默窗的行留给"照旧改"那一侧,因为它
    ///   换到下一行时静默窗刚好走完,不会拖累下一行。
    /// - **长度完全没变时返回 false**(不是 true)。那种情况是"形态翻转、槽宽不动"
    ///   (`text(223.5) 与 fixed(223.5)`),该交给调用点的 `needsRebuild` 判 —— 那条会走
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
        guard dwellSeconds < quietSecs else { return false }
        // 短命行本身不值得改槽宽 —— 前提是"不改"之后屏幕上还说得过去。
        // 偏差大到地板自己都判该缩(/该涨)的程度,就不是"省一次重建"而是"整首歌画在错的槽里"了。
        // 理由与实测现行见 `shortLineDriftCeiling`。
        return abs(delta) < shortLineDriftCeiling
    }

    /// 自适应槽位「这一句」自然要多宽(占位兜底之前那一步)。菜单栏本体和设置页预览共用这一个算式,
    /// 别各写一份:两份一漂开,预览的格子跟真机就不一样宽。
    ///
    /// - 单行:就是主行宽。
    /// - 双排:取两行里宽的那个、上限「最大宽度」—— 但副行是**「下一句」**时不许它撑宽:那一句马上会变成
    ///   主行、到时候自然撑宽,现在为它占地方等于短句也按下一句的长度占着。译文 / 罗马音是**这一句自己的**
    ///   内容,不给宽度就永远只看得到半截,照旧 max(主行, 副行)。
    public static func naturalWidth(
        mainWidth: CGFloat, secondaryWidth: CGFloat, twoRows: Bool,
        secondaryKind: LyricSecondaryLine, maxWidth: CGFloat
    ) -> CGFloat {
        guard twoRows else { return mainWidth }
        return min(maxWidth, secondaryKind != .nextLine ? max(mainWidth, secondaryWidth) : mainWidth)
    }

    /// 占位态的槽宽该给多少。
    ///
    /// 占位文字(「♪ 歌名」兜底、或前奏/间奏那三颗点)的宽度跟**即将到来的那一句**毫无关系,所以从占位
    /// 切到歌词时槽宽必然要改一次。改在哪一侧是唯一的选择:
    ///
    /// - 改在歌词出现**之后** = 那一句先按占位槽画一版、槽宽跟上再画一版 → **同一句变两次**;
    /// - 改在歌词出现**之前** = 占位期间就把槽撑到下一句要的宽度 → 歌词一出现几何已经对了,
    ///   只渲染一次。这个函数选的是这一侧。
    ///
    /// 这是 `skipsResize` 管不到的一半:它只在两个**歌词槽**之间生效,图标与占位与歌词这几跳不受它管。
    ///
    /// **代价**:占位期间这一项比它自己需要的宽,「♪ 歌名」画在按下一句尺寸开出来的槽里。跟自适应
    /// "省空间"的初衷有点冲突,换来的是邻居少挪一次(icon → 宽槽,而不是 icon → 窄槽 → 宽槽)+ 歌词只
    /// 渲染一次。
    ///
    /// - `isPlaceholder` 为 false 时**原样返回 naturalWidth**(连上限都不夹):正常歌词句的槽宽不受影响。
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

    /// 「这一刻菜单栏该显示什么文字」的兜底:有歌词句就显示歌词句(包括前奏/间奏那个三点记号串);
    /// 压根没有可显示的行、这首歌又在播放且不是广告,就用「♪ 歌名」占住槽位,而不是收回成小图标。
    ///
    /// 为什么值得:`compactShowsPlaceholder` 只在「唱完了、下一句还早」为真,整首没歌词 / 还在搜的歌
    /// 文字为空,菜单栏会把槽收回成图标 —— 搜索超过 3s 观察窗就先塌再撑(一对状态项重建,见
    /// `MenuBarStatusItem.present` 头注的铁律),没歌词的歌整首只剩图标。灵动岛 / 悬浮歌词都有占位
    /// 文案,菜单栏是唯一直接塌回图标的展示面。固定宽度模式下有词没词几何完全不变。
    ///
    /// 三条刻意保留的边界:① `isPlaying` 为 false 一律 nil —— 口径是「暂停不占宽」,
    /// 参考做法"暂停仍显示当前句"不学;② 广告态不显示广告标题;③ 没歌名就还是图标,不做品牌兜底。
    /// 返回 nil = 照旧收回图标;`isFallback` 告诉调用方这不是歌词句(配速不按歌词时长算)。
    ///
    /// `iconBesideLyrics`(歌词旁那枚进度图标开着)为真时**不加 ♪ 前缀**:那个前缀是为了
    /// 让这行字一眼看出"这是歌名不是歌词",而旁边那枚图标已经在说同一件事,两个音符并排
    /// (`♪≡ ♪ 歌名`)纯属重复。前奏/间奏的占位不受这里管辖 —— 它是三颗呼吸圆点,以一个
    /// 记号串(`MenuBarMarqueeRenderer.gapDotsToken`)的身份走 `lyricText` 那条路
    /// (上面第二行就返回了),而且它必须是非空文本才能把槽留住,见 06 章决策 11。
    ///
    /// **这里这个音符跟那三颗点是两件事**,别一起换:这个说的是"这首歌没词",
    /// 那个说的是"有词、只是此刻在间奏";写成「••• 歌名」读起来会变成在报间奏。
    public static func displayText(
        lyricText: String, title: String, isPlaying: Bool, isAdBreak: Bool,
        showsTitleWhenNoLyrics: Bool, placeholderGlyph: String, iconBesideLyrics: Bool
    ) -> (text: String, isFallback: Bool)? {
        guard isPlaying else { return nil }
        if !lyricText.isEmpty { return (lyricText, false) }
        guard showsTitleWhenNoLyrics, !isAdBreak else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (iconBesideLyrics ? trimmed : placeholderGlyph + " " + trimmed, true)
    }
}
