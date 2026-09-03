import CoreGraphics
import Foundation

/// 灵动岛卡片「从刘海撑开」出场动画的纯几何与时序常数(2026-09-03)。
///
/// 动画本体在 App 侧 `NotchWindowRoot`(keyframeAnimator 驱动 `NotchRevealShape` 裁剪),这里只放
/// selftest 能钉住的两个纯函数和时间常数。**只裁剪、不缩放**:被参考的做法是"横向裁剪撑开 + 纵向缩放
/// 弹一下",但这块卡片在 `.coverArt` 风格下背景就是封面模糊图,任何整卡缩放都会让封面跟着被重新裁切 ——
/// 2026-09-03 上午用户报的「封面平移过来」正是缩放路线的副作用。所以内容始终在终态位置,只有可见区域在长。
public enum NotchReveal {
    /// 起始可见宽度占卡片宽度的比例:从**真刘海两侧**撑开(t = 0 时整卡藏在物理刘海后面,先撑出两只耳朵)。
    /// 无刘海屏(notchWidth = 0:外接屏、镜像副本)给一条 12% 的细缝,否则第一帧什么都看不见、观感是
    /// "凭空出现";上限 0.9:刘海比卡片还宽的怪配置下仍留一点可见的撑开量。
    public static func startWidthFraction(notchWidth: CGFloat, cardWidth: CGFloat) -> CGFloat {
        guard cardWidth > 0 else { return 1 }
        return min(0.9, max(0.12, notchWidth / cardWidth))
    }

    /// 起始可见高度占卡片高度的比例:只露顶行(耳朵那一条,高 = 刘海 / 菜单栏高),歌词行随后"滴"下来。
    public static func startHeightFraction(topRowHeight: CGFloat, cardHeight: CGFloat) -> CGFloat {
        guard cardHeight > 0 else { return 1 }
        return min(0.9, max(0.1, topRowHeight / cardHeight))
    }

    /// 横向撑开时长。
    public static let widthDuration: Double = 0.20
    /// 纵向先按住这么久再开始往下长 —— 先横后纵,才有"先撑开、再滴下"的次序感。
    public static let heightDelay: Double = 0.06
    public static let heightDuration: Double = 0.24
    /// 内容(文字 / 封面)延后淡入:先看到卡片形状长出来,再看到字。参考做法取 130ms,配合更短的整体时长取 100ms。
    public static let contentDelay: Double = 0.10
    public static let contentDuration: Double = 0.16
    /// 整段动画的总时长(最晚结束的那条轨)。文档引用这个数,别各自算。
    public static var totalDuration: Double {
        max(widthDuration, heightDelay + heightDuration, contentDelay + contentDuration)
    }
}
