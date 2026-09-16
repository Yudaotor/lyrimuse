import CoreGraphics
import Foundation

/// 自适应宽度模式下,槽宽在**同一首歌内单调不减**(2026-09-16,用户要求「视觉效果也要好,
/// 不能跳来跳去」)。
///
/// **为什么要它。** 自适应模式的槽宽跟着每一句的文字宽走,而 macOS 26 的菜单栏只在项**出生
/// 那一刻**给邻居排位 —— 所以每一次槽宽变化都是一次整项重建,左边所有图标跟着挪一次
/// (见 `MenuBarStatusItem.present` 头注)。此前的缓解全是"少改几次":6pt 死区、
/// 活不过静默窗的行不改几何、3 秒节流。实测(25 分钟)仍有 94 次放行,平均 **16 秒一次**,
/// 而且方向来回摆 —— 抓到过 `106.1 → 113.1 → 106.1` 三秒内一个来回,那是最刺眼的一种。
///
/// **改法**:一首歌之内只涨不缩,换歌重置。于是
///   · 「缩了又扩」的乒乓**从根上没有了**(缩这个动作不存在);
///   · 重建只发生在"出现了比之前都长的句子"那几次,一首歌通常三五次,而且**永远同一个方向**;
///   · 暂停 / 间隙 / 假暂停期间目标宽度 ≤ 已达最大值,`needsRebuild` 恒假 → 零重建。
///
/// **代价说清楚**:一首歌里只要出现过一句长的,这一项就按那个宽度占到这首歌结束 —— 自适应
/// 模式的"只占需要的宽度"被削弱了,接近固定宽度。这是**刻意**用紧凑换稳定:用户明确要的是
/// 不跳。上限仍是「最大宽度」那个设置(`.text` 分支本来就只在装得下时才走,所以天然封顶)。
///
/// ⚠️ **换歌才重置,不是换行**。拿 `trackKey`(歌名+歌手)判:同一首歌内任何时候都不缩,
/// 包括间奏、暂停回来、「♪ 歌名」占位。换歌那一次缩窄是预期内的 —— 边界上本来就该变。
/// ⚠️ 只管**自适应**模式。固定宽度模式的槽宽本来就是常量,轮不到这里。
public struct MenuBarSlotFloor: Sendable, Equatable {
    private var trackKey: String?
    private var floor: CGFloat = 0

    public init() {}

    /// 这一句想要 `target` 这么宽,实际给多宽。
    ///
    /// `trackKey` 变了就把地板重置成 `target`(新歌按它自己的第一句定宽,不继承上一首的);
    /// 没变就取 `max(地板, target)`。
    public mutating func width(target: CGFloat, trackKey: String) -> CGFloat {
        if trackKey != self.trackKey {
            self.trackKey = trackKey
            floor = target
            didResetOnLastCall = true
        } else {
            didResetOnLastCall = false
        }
        floor = max(floor, target)
        return floor
    }

    /// 上一次调用是不是**换歌重置**了地板。
    ///
    /// 给调用方判「这一刻的目标还不作数」用(2026-09-16 终验抓到):换歌那一瞬 `currentLineIndex`
    /// 已经清空、而 `currentLine` 还停在旧值,算出来的目标宽度是个过渡值 —— 实测 `237.7 → 98.4`
    /// 当场建了一次,**16 毫秒后**真实内容(215.6)才到,第二次撞进节流窗、3 秒后才跳到位。
    /// 重置这一刻跟「占位内容」是同一类东西:先别建,等落定窗。
    public private(set) var didResetOnLastCall = false

    /// 当前地板(给断言和诊断看;没定过是 0)。
    public var currentFloor: CGFloat { floor }
}
