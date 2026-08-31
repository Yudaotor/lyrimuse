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

    /// 近侧(文字实际贴的那一边)也留一点白,别让字贴在卡片的物理边缘上
    /// (2026-08-26,用户反馈"左右两块太分开、顶到边了")。取远侧的一半:
    /// 短句(不会被远侧内缩顶到)之前是贴着卡片真边缘的——`.leading` 是
    /// `(0, inset)`,近侧完全没有留白,视觉上两边的字几乎钉死在卡片两端,
    /// 显得比实际"往哪边偏"更分裂。近侧留一半远侧的量,把整块内容往中间拉一截,
    /// 同时保持"远侧比近侧宽"这条不变式——分栏的方向感(偏左/偏右)还在,
    /// 只是不再顶边。
    public static let nearInsetRatio: CGFloat = insetRatio / 2

    /// 这一行左右各该留多少。
    ///
    /// - side 为 nil(没有对唱信息:普通歌的每一行、对唱歌第一个标记之前的前奏)
    ///   一律返回 0 —— 普通歌的排版必须跟没有这个功能时**逐像素一致**。
    /// - 合唱(center)两侧都留,它既不属于左也不属于右,留白让它跟两侧都区分得开。
    /// - 左右声部**近侧也留(nearInsetRatio)、远侧照旧多留(insetRatio)** ——
    ///   两者都非零,但远侧恒大于近侧,分栏的方向感不会被磨平。
    public static func insets(
        for side: LyricDuet.Side?, availableWidth: CGFloat, fontSize: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard let side, availableWidth > 0 else { return (0, 0) }
        let farInset = max(0, min(availableWidth * insetRatio, fontSize * maxInsetInEm))
        let nearInset = max(0, min(availableWidth * nearInsetRatio, fontSize * maxInsetInEm / 2))
        switch side {
        case .leading: return (nearInset, farInset)
        case .trailing: return (farInset, nearInset)
        case .center: return (farInset, farInset)
        }
    }
}
