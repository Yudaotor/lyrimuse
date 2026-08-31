/// 经典桌面悬浮歌词的「对齐方式」覆盖(2026-08-29,GitHub issue #2)。
///
/// 默认(`automatic`)是既有行为:歌词按对唱声部标记(`LyricDuet.Side`)自动在左/右/居中
/// 之间切换,配合两侧内缩(`LyricDuetLayout.insets`)和声部指示圆点(见
/// `LyricsOverlayView.withSpeakerIndicator`)——这套设计本身是刻意的(仿 Apple Music 的
/// Duet View),但对贴在桌面上的固定悬浮窗来说,位置来回跳会影响阅读体验(issue 原话:
/// "歌词位置来回变化会影响阅读体验")。
///
/// 三个非自动选项**不只是改对齐方向**——如果只改 VStack/文本的对齐方向,留着两侧内缩
/// 和指示圆点继续按真实声部算,文字块仍然会因为留白量随声部变化而轻微左右漂移,issue 里
/// "始终保持在同一个位置"这条没有真正达成。所以非自动选项的语义是:**当成一首没有对唱
/// 信息的普通歌来排版**(两侧内缩归零、指示圆点不出现——跟 `side == nil` 时的既有行为
/// 逐像素一致),只是「排版居中」换成「排版靠选定的这一侧」。这对没有对唱标记的普通歌
/// 同样生效(issue 原文"所有歌词强制左对齐",不是"仅对唱歌"),等价于把"永远居中"的旧
/// 兜底换成"永远靠用户选的那一边"。
///
/// 只影响悬浮窗(`LyricsOverlayView`),不影响歌词窗口(第 07 章)——按用户反馈的原话
/// 范围来实现;歌词窗口对没有声部信息的兜底本来就是靠左(悬浮窗是居中),两边默认已经
/// 不一致,这次不动它。
public enum OverlayDuetAlignmentOverride: String, Codable, Hashable, CaseIterable, Sendable {
    case automatic
    case center
    case leading
    case trailing

    /// 决定 VStack 对齐 / frame 锚点 / 文本对齐要用哪个声部值——**永远返回非 nil**,
    /// 因为这三处消费方本来就要一个确定的方向,不接受"没有意见"。
    public func effectiveAlignmentSide(realSide: LyricDuet.Side?) -> LyricDuet.Side {
        switch self {
        case .automatic: return realSide ?? .center
        case .center: return .center
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    /// 决定两侧内缩(`LyricDuetLayout.insets`)和声部指示圆点(`withSpeakerIndicator`)
    /// 要用哪个声部值——`automatic` 时原样传回真实声部(现有行为不变),否则强制传 `nil`
    /// (两处消费方对 `nil` 的既有处理正好就是"当成普通歌":内缩归零、指示圆点不显示),
    /// 不需要在这两处消费方内部各写一份"override 生效时怎么办"的分支。
    ///
    /// ⚠️ 不能直接把 `effectiveAlignmentSide` 的结果拿来当这两处的输入——`leading`/
    /// `trailing` 覆盖会让**每一行**(包括完全没有对唱标记的普通歌)都变成非 `.center`,
    /// `withSpeakerIndicator` 会误以为"这里真的有人在唱"而在每一行冒出一个圆点,这不是
    /// issue 要的效果(issue 只要求对齐方向可选,没有要求普通歌也长出装饰)。
    public func effectiveDecorationSide(realSide: LyricDuet.Side?) -> LyricDuet.Side? {
        self == .automatic ? realSide : nil
    }
}
