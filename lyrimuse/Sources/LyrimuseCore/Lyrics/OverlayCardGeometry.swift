import CoreGraphics

/// 悬浮窗里**卡片内容块**和它上方那排**控制按钮**的横向落点 —— 两者必须贴同一条边。
///
/// 为什么要单独一个类型(2026-09-03,用户实机反馈:「在对唱模式下,这个悬浮菜单不是显示
/// 对应歌词上面的,看起来是在整个窗口的居中位置」):
///
/// 控制排原来挂在 `LyricsOverlayView` 最外层那个 `VStack(spacing: 0)` 上,吃的是 VStack
/// 默认的 `.center` 对齐;而歌词卡片是 `.frame(maxWidth: .infinity, alignment: duetFrameAlignment)`
/// —— 对唱歌一旦把歌词甩到右半边,按钮排还钉在整扇窗的正中,两者差出大半个窗宽。
/// 普通歌看不出来纯属巧合:`duetSide` 兜底就是 `.center`,两边算出来正好同一个位置。
///
/// 落点的算法很短,但它**必须和卡片那一边逐字一致**,而这个仓库已经为"同一个视觉属性
/// 两条渲染路径"付过三次账(见第 04 章:预览条的对齐写死 `leading`、灵动岛手搓预览、
/// 编辑台简化复刻件)。所以把这份几何搬到 core 里当唯一出处,让 selftest 能直接问它
/// "卡片贴哪条边、按钮贴哪条边",而不是等下一次视觉回归被用户截图抓出来 —— 跟
/// `LyricDuetLayout` / `WrapLayoutMath` 摆在 core 而不是 View 里是同一条理由。
///
/// ⚠️ 这里收的 `side` 是**装饰声部**(`OverlayDuetAlignmentOverride.effectiveDecorationSide`
/// 的结果,`nil` = 当成没有对唱信息的普通歌),不是对齐方向。两者在非自动的「对齐方式」
/// 覆盖下会分叉:那时对齐方向是用户选的那一边,而内缩必须整个归零。
public enum OverlayCardGeometry {
    /// **对唱舞台**的基准宽度(2026-09-10,用户:「如果歌词已经拉得很宽,这时候遇上对唱类歌词,
    /// 左右两句就会分得很开……哪怕宽度拉得很宽,也尽量还是居中显示;剩余的宽度留给很长的歌词
    /// 做冗余」)。
    ///
    /// 左右声部原来贴的是**卡片**两边:卡片拉到 1400pt,左声部的字从 x≈20 起、右声部的字到
    /// x≈1380 止,两句隔着一整个窗宽。现在左右声部只在卡片正中一条**固定宽度的带**(舞台)里
    /// 分栏:左声部贴舞台左边、右声部贴舞台右边,舞台两侧多出来的宽度是长句的冗余 —— 长句
    /// 从舞台边缘起笔、越过舞台往外长(左声部往右、右声部往左),到远侧内缩处才换行,所以
    /// 换行点跟改动前一样,只是短句不再被推到卡片两端。
    ///
    /// 舞台宽 = `max(基准宽度, 字号 × duetStageMinEm)`,再被可用宽度封顶。基准 448 = 默认窗宽
    /// 488 − 两侧 20pt 卡片内边距:对唱分栏的观感就是按默认窗宽调出来的,窄于或等于默认宽度时
    /// 舞台就是整张卡片、**逐像素不变**,只有用户把窗口拉得比默认宽,多出来的部分才变成冗余。
    /// 字号很大时按 12 个字宽兜底(两侧各放得下 6 个字),免得大字号下舞台窄到两句叠在一起。
    public static let duetStageReferenceWidth: CGFloat = 448
    public static let duetStageMinEm: CGFloat = 12

    /// 舞台两侧各让出多少 —— 就是卡片内容块**近侧**要多缩进的量。可用宽度 ≤ 舞台宽时为 0。
    public static func duetStageInset(availableWidth: CGFloat, fontSize: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 0 }
        let stage = min(availableWidth, max(duetStageReferenceWidth, max(0, fontSize) * duetStageMinEm))
        return max(0, (availableWidth - stage) / 2)
    }

    /// 卡片内容块按声部留出的两侧内缩。
    ///
    /// 远侧留 `unit`(由 `LyricDuetLayout.insets` 按窗宽和字号算好):左声部在右边留、右声部
    /// 在左边留、合唱两边都留;近侧留 `stageInset`(舞台在卡片里居中后两侧各让出的量,见
    /// `duetStageInset`;窗口不比默认宽时为 0)—— 合唱本来就居中,不需要舞台,两侧仍只留
    /// `unit`。`nil`(普通歌、前奏、覆盖生效)一律 0,排版跟没有这个功能时逐像素一致。
    /// 近侧的呼吸空间由卡片自己的 `cardHorizontalPadding` 提供,不在这里重复。
    public static func cardInsets(
        for side: LyricDuet.Side?, unit: CGFloat, stageInset: CGFloat = 0
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard let side else { return (0, 0) }
        let near = max(0, stageInset)
        switch side {
        case .leading: return (near, unit)
        case .trailing: return (unit, near)
        case .center: return (unit, unit)
        }
    }

    /// 控制排(播放控制胶囊,锁定态则是解锁按钮)该在两侧留多少白。
    ///
    /// = 卡片内缩 + 卡片自己的水平内边距。这两项加起来正好是"从窗口边缘到卡片内容块边缘"
    /// 的距离 —— 控制排套上同一份留白、再按同一个方向 `.frame(maxWidth:.infinity, alignment:)`
    /// 靠边,它的近侧边缘就跟歌词块的近侧边缘**严格重合**,不是靠肉眼凑。
    ///
    /// 合唱/普通歌(两侧相等)算出来左右对称,`.center` 对齐下位置跟改动前逐像素相同 ——
    /// 这是这次改动的回归护栏:绝大多数歌不该因为修对唱而挪动一个像素。
    public static func controlsInsets(
        for side: LyricDuet.Side?, unit: CGFloat, stageInset: CGFloat = 0, cardHorizontalPadding: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let card = cardInsets(for: side, unit: unit, stageInset: stageInset)
        return (card.leading + cardHorizontalPadding, card.trailing + cardHorizontalPadding)
    }
}
