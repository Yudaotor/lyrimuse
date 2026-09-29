import CoreGraphics

/// 灵动岛卡片外轮廓的两个尺寸(纯函数,selftest 钉着)。形状本身在 App 侧 `NotchHangingShape.card`。
///
/// 照着机器刘海画:刘海底部两角是约 8pt 的圆角(32pt 高的刘海)、跟屏幕上沿相接处有约 4pt 的内凹圆角
/// (「肩膀」),两者都按刘海高度等比,见 05 章决策 #46。
///
/// **底部圆角随卡片高度走**(`bottomRadius`):卡片跟刘海一样高时(常驻 / 收起)按刘海的比例
/// (高 × `bottomRadiusPerHeight`,32pt → 8pt、16 寸 38pt → 9.5pt),高了就跟着变大、封顶
/// `maxBottomRadius`(展开态)。半径只由路径所在矩形的高度决定,展开 / 收起的尺寸动画里每一帧都按
/// 当时的高度重算,不用另给动画插值。
///
/// **肩膀按刘海高度走**(`shoulderRadius(notchHeight:)`,刘海高 × `shoulderPerNotchHeight`,32pt → 4pt、
/// 16 寸 38pt → 4.75pt)。它模仿的是刘海跟屏幕上沿相接那一处,所以只看刘海高度、不随卡片展开变大。
///
/// **肩膀往里收、不往外扩**:顶边保持卡片全宽,顶边以下两侧各往里收一个肩膀半径,中间用内凹圆弧接上。
/// 轮廓因此从不越出卡片矩形 —— 窗口尺寸、悬停区域都不用动;代价是卡片主体两侧各窄一个肩膀,那里只有
/// 背景(两耳内容离边都比肩膀宽)。
public enum NotchOutline {
    public static let bottomRadiusPerHeight: CGFloat = 0.25
    public static let maxBottomRadius: CGFloat = 20
    public static let shoulderPerNotchHeight: CGFloat = 0.125

    /// 肩膀的标称半径。`notchHeight` 是顶行高度(真刘海屏 = 刘海本身,无刘海屏 = 菜单栏高)。
    public static func shoulderRadius(notchHeight: CGFloat) -> CGFloat {
        max(0, notchHeight * shoulderPerNotchHeight)
    }

    /// 某个矩形实际用的肩膀半径:矩形太窄 / 太矮时收小(出场动画起始那一帧只有一条缝)。
    public static func shoulder(width: CGFloat, height: CGFloat, notchHeight: CGFloat) -> CGFloat {
        max(0, min(shoulderRadius(notchHeight: notchHeight), width / 4, height / 2))
    }

    /// 底部圆角半径。`bodyWidth` 是两侧收完肩膀之后的主体宽度。
    public static func bottomRadius(height: CGFloat, bodyWidth: CGFloat) -> CGFloat {
        max(0, min(maxBottomRadius, height * bottomRadiusPerHeight, bodyWidth / 2, height / 2))
    }
}
