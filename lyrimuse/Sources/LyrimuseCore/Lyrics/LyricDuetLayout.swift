import CoreGraphics

/// 对唱行的**两侧内缩** —— 让左右两栏真的读成两栏。
///
/// 为什么光有对齐不够(2026-08-23 实测):歌词窗口正文列按比例算只放得下约 12 个汉字,
/// 而用户库里对唱歌的行长中位数是 8 字宽、**16% 的行 ≥12 字宽**。顶满整宽的那些行,
/// 左对齐和右对齐渲染出来逐像素相同 —— 唯一的区分信号在最需要它的时候消失。
///
/// Apple Music 自己的 Duet View 也不是纯粹的"左右对齐":官方原文是
/// 「Multiple vocalists show on opposite sides of the screen」,AMLL(仿 AM 的开源实现)
/// 的做法是给对唱行**两侧各留一段固定比例的空白**,靠留白而不是靠字的落点来分栏。
/// 这样即使一行长到顶满可用宽度,它也只占到整列的 85%,偏向依然读得出来。
///
/// 几何算在这里而不是 View 里,是为了能被 selftest 直接问("给这个宽度和这个声部,
/// 你打算留多少") —— 跟 WrapLayoutMath / KaraokeFill 同样的理由。
public enum LyricDuetLayout {
    /// 内缩占可用宽度的比例。
    ///
    /// 0.15 是 AMLL 的量级。往上加会让本来就只放得下 12 字的正文列更容易折行,
    /// 往下减到 0.08 以下就基本看不出来了 —— 这个数字调整前先想清楚这两头。
    public static let insetRatio: CGFloat = 0.15

    /// 内缩的绝对上限,按**字号**算而不是按宽度。
    ///
    /// 窗口拉得很宽时 15% 会变成一大片空白,而分栏的可读性早在两三个字宽的留白处就
    /// 饱和了;再多只是白白吃掉行宽。取 4 个字宽封顶。
    public static let maxInsetInEm: CGFloat = 4

    /// 这一行左右各该留多少。
    ///
    /// - side 为 nil(没有对唱信息:普通歌的每一行、对唱歌第一个标记之前的前奏)
    ///   一律返回 0 —— 普通歌的排版必须跟没有这个功能时**逐像素一致**。
    /// - 合唱(center)两侧都留,它既不属于左也不属于右,留白让它跟两侧都区分得开。
    public static func insets(
        for side: LyricDuet.Side?, availableWidth: CGFloat, fontSize: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard let side, availableWidth > 0 else { return (0, 0) }
        let inset = max(0, min(availableWidth * insetRatio, fontSize * maxInsetInEm))
        switch side {
        case .leading: return (0, inset)
        case .trailing: return (inset, 0)
        case .center: return (inset, inset)
        }
    }
}
