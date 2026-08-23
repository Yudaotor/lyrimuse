import Foundation

/// 单行展示面(灵动岛 / 菜单栏)「这一刻该显示哪一句」的规则。
///
/// ## 为什么不复用歌词窗口那套 scrollLeadIndex
///
/// 两者解决的是同一个诉求的两种形态,但**答案不一样**,别合并:
///
/// - 歌词窗口是**多行**列表,间奏里有「•••」那排点可以停靠,所以它的规则是「点亮期间滚动
///   停在点上、窗口结束前 leadMs 才指向下一句」(照抄 Apple Music)。
/// - 灵动岛/菜单栏只有**一行**。同样的规则搬过来,长间奏里屏幕上就一直挂着一句**已经唱完
///   的**歌词,而且没有任何视觉线索告诉你它唱完了 —— 用户 2026-08-23 提的正是这件事:
///   「一句完整结束、下一句开始的时候才会换行」,想要的是唱完就切走、提前看到下一句好跟唱。
///
/// ## 规则
///
/// 设本行唱完于 `end`、下一句开始于 `next`:
///
/// - `pos < end`:还在唱,显示本行。
/// - `pos >= end` 且 `next - pos <= revealMs`:显示**下一句**(未染色)——这就是提前量。
/// - `pos >= end` 且离下一句还远:显示 `.placeholder`(调用方画 ♪)。已经唱完的句子不该
///   继续占着那一行冒充"正在唱"。
///
/// 短间隙(`next - end <= revealMs`,实测占 97.7%)天然落进第二档,表现就是**唱完即切**。
///
/// ## 两条刻意的保守边界
///
/// 1. **行级 LRC 不抢跑**(`lineEndMs == nil`):不知道一行唱多久就不猜。猜早了会在你还在
///    唱这句的时候把它换掉,比现状更糟。实测用户曲库 96% 的歌有逐字,这条只影响剩下 4%。
///    (`gapWindow` 里那个 `assumedEnd = start + (next-start)/3` 的估计是给「•••」用的 ——
///    点亮早一点无伤大雅,换掉正在唱的那句不行,两者容错完全不同,别拿来复用。)
/// 2. **最后一句不切走**(`nextStartMs == nil`):后面没有句子可提前,切成 ♪ 只会让尾奏
///    变成空屏。保持现状显示最后一句。
public enum CompactLyricLead {
    /// 提前多久亮出下一句。5 秒 = 用户 2026-08-23 拍板的值:够读完一句、又不至于长到
    /// 让人以为播放卡住了。
    public static let revealMs = 5000

    public enum Outcome: Equatable {
        /// 显示这一行(下标可能是当前行,也可能是下一行)。
        case line(Int)
        /// 本行唱完了、下一句还早 —— 调用方画 ♪ 占位。
        case placeholder
    }

    /// - Parameters:
    ///   - activeIdx: 按时间戳定位到的当前行下标(<0 表示还没到第一句)。
    ///   - posMs: 已经加过歌词偏移的播放位置。
    ///   - lineEndMs: 第 activeIdx 行唱完的时刻;行级 LRC 不可知,传 nil。
    ///   - nextStartMs: 第 activeIdx+1 行开始的时刻;没有下一行传 nil。
    public static func resolve(activeIdx: Int, posMs: Int,
                               lineEndMs: Int?, nextStartMs: Int?) -> Outcome {
        // 还没到第一句:维持现状(调用方那边 lineAt(-1) 是 nil,画 ♪/前奏态)。刻意不在
        // 前奏里提前亮出第一句 —— 那是另一个场景(整首歌的开场),行为变化面比"句间"大得多,
        // 用户这次要的只是句间的提前量。
        guard activeIdx >= 0 else { return .line(activeIdx) }
        // 行级 LRC / 还在唱这一句 → 显示本行。见上面「保守边界 1」。
        guard let end = lineEndMs, posMs >= end else { return .line(activeIdx) }
        // 最后一句唱完 → 仍显示它。见上面「保守边界 2」。
        guard let next = nextStartMs else { return .line(activeIdx) }
        // 进入提前量窗口(短间隙天然一进 end 就满足)→ 亮出下一句。
        if posMs >= next - revealMs { return .line(activeIdx + 1) }
        // 长间奏中段:唱完了,但下一句还远。
        return .placeholder
    }

    /// 某一行在单行展示面上**总共会显示多久**(毫秒)。菜单栏跑马灯拿它配速。
    ///
    /// 为什么不能继续用 PlaybackCoordinator.currentLineDwellSeconds 那套「本句时间戳 →
    /// 下句时间戳」:显示窗口已经变了。长句后面紧跟一段长间奏时,那套算法会把 dwell 算成
    /// 「一直显示到下一句开始」,而实际上这一句在**唱完那一刻**就被换走了 —— MenuBarMarquee
    /// .pacing 按偏大的 dwell 配速,长句会只滚出开头一小截就被切掉,**比改动前更糟**。
    ///
    /// 窗口 = [出现, 消失):
    /// - 出现:上一行唱完时 `max(上一行结束, 本行开始 - revealMs)`(不早于此 —— 上一行还在
    ///   唱的时候轮不到它);上一行结束不可知(行级 LRC)就是本行自己的开始时刻。
    /// - 消失:本行唱完(`lineEndMs`)——那一刻不是切到下一句就是切成 ♪,总之它下场了;
    ///   行级 LRC 不可知则退回下一句开始;没有下一句则用曲末兜底。
    public static func displayDurationMs(prevLineEndMs: Int?, startMs: Int,
                                         lineEndMs: Int?, nextStartMs: Int?,
                                         fallbackEndMs: Int?) -> Int? {
        // 出现时刻:夹在 (本行开始 - revealMs) 和 本行开始 之间 —— 上一行结束得晚
        // (时间戳交叠/脏数据)时不能算成"比本行开始还晚出现"。
        let appear: Int
        if let prevEnd = prevLineEndMs {
            appear = min(startMs, max(prevEnd, startMs - revealMs))
        } else {
            appear = startMs
        }
        let vanish: Int?
        if let end = lineEndMs, nextStartMs != nil {
            vanish = end
        } else if let next = nextStartMs {
            vanish = next
        } else {
            vanish = fallbackEndMs
        }
        guard let v = vanish, v > appear else { return nil }
        return v - appear
    }
}
