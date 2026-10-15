import CoreGraphics
import Foundation

/// 自适应宽度模式下,槽宽在**同一首歌内基本只涨不缩**:小幅回缩吸收掉,换歌重置。
///
/// **为什么要它。** 自适应模式的槽宽跟着每一句的文字宽走,而 macOS 26 的菜单栏只在项**出生
/// 那一刻**给邻居排位 —— 所以每一次槽宽变化都是一次整项重建,左边所有图标跟着挪一次
/// (见 `MenuBarStatusItem.present` 头注)。光靠"少改几次"(6pt 死区、活不过静默窗的行不改几何、
/// 3 秒节流)不够:实测 25 分钟仍有 94 次放行,平均 **16 秒一次**,而且方向来回摆,三秒内
/// `106.1 → 113.1 → 106.1` 一个来回最刺眼。
///
/// 一首歌之内不缩,于是:
///   · 「缩了又扩」的乒乓没有了;
///   · 重建只发生在"出现了比之前都长的句子"那几次,而且**永远同一个方向**;
///   · 暂停 / 间隙 / 假暂停期间目标宽度 ≤ 已达最大值,`needsRebuild` 恒假 → 零重建。
/// 句长差异大的歌里几乎每一次回缩都越过下面的收缩容差、照缩,重建会回到每 2.8s 一次 —— 这是在
/// "不空"和"不晃"之间选了**不空**(见 06 章「宽度模式与占位」)。
///
/// **不能"同曲内一律不缩"**,必须留收缩容差:一旦某一句把槽顶到「最大宽度」(默认 250pt),
/// 一律不缩就让它**整首歌都顶满**,短句的时候槽里空一大片。所以只吸收**小幅回缩**:要治的本来就是
/// "小幅来回摆"(实测 7pt、17pt 两种),而不是"内容真的短了很多"。超过 `shrinkTolerance` 的收缩
/// 照缩 —— 那时候占着不放纯属浪费,用户一眼就看得见。
///
/// 容差取**绝对值**不取百分比:用户感知的是"菜单栏被占了多少",那是绝对量;
/// 30pt ≈ 两个汉字,比它小的空隙肉眼基本看不出来,而它换掉的是一次整项重建 + 邻居重排。
///
/// **换歌才重置,不是换行**。拿 `trackKey`(歌名+歌手)判:同一首歌内任何时候都不缩,
/// 包括间奏、暂停回来、「♪ 歌名」占位。换歌那一次缩窄是预期内的 —— 边界上本来就该变。
/// 只管**自适应**模式。固定宽度模式的槽宽本来就是常量,轮不到这里。
public struct MenuBarSlotFloor: Sendable, Equatable {
    private var trackKey: String?
    private var floor: CGFloat = 0

    public init() {}

    /// 比这个数还小的回缩才吸收;超过它说明内容是真的短了,照缩。理由见类型头注。
    public static let shrinkTolerance: CGFloat = 30

    /// 这一句想要 `target` 这么宽,实际给多宽。
    ///
    /// `trackKey` 变了就把地板重置成 `target`(新歌按它自己的第一句定宽,不继承上一首的);
    /// 没变就取 `max(地板, target)`,只有回缩超过 `shrinkTolerance` 才照缩。
    public mutating func width(target: CGFloat, trackKey: String) -> CGFloat {
        if trackKey != self.trackKey {
            self.trackKey = trackKey
            floor = target
            didResetOnLastCall = true
            return floor
        }
        didResetOnLastCall = false
        if target >= floor {
            floor = target                              // 更宽:涨
        } else if floor - target > Self.shrinkTolerance {
            floor = target                              // 明显变窄:照缩,别占着不放
        }                                               // 小幅回缩:保持,这才是要吸收的抖动
        return floor
    }

    /// 上一次调用是不是**换歌重置**了地板。
    ///
    /// 给调用方判「这一刻的目标还不作数」用:换歌那一瞬 `currentLineIndex` 已经清空、而 `currentLine`
    /// 还停在旧值,算出来的目标宽度是个过渡值,真实内容十几毫秒后才到;当场建的话第二次就撞进节流窗、
    /// 3 秒后才跳到位。重置这一刻跟「占位内容」是同一类东西:先别建,等落定窗。
    public private(set) var didResetOnLastCall = false

    /// 当前地板(给断言和诊断看;没定过是 0)。
    public var currentFloor: CGFloat { floor }
}
