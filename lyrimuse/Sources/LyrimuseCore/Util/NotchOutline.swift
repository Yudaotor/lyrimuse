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

    /// 「圆角 / 展开圆角」两个设置的存盘值。`defaultRadiusSetting` = 默认(上面按卡片高度算的那套),
    /// `notchRadiusSetting` = 跟随刘海(机器刘海本身的圆角,两态一样),>= 0 = 固定的 pt。
    public static let defaultRadiusSetting: Double = -1
    public static let notchRadiusSetting: Double = -2
    /// 固定圆角的范围上限。实际画出来还要过 `clampedCornerRadius`;滑杆按卡片高度收窄,见
    /// `customRadiusRange(cardHeight:notchHeight:)`。
    public static let customRadiusRange: ClosedRange<Double> = 0...32

    /// 设了「圆角 / 展开圆角」时实际画的底角:夹进主体半宽和「卡片高 − 肩膀」。后者是侧边从肩膀下面起整段都是
    /// 圆弧的那个值,再大路径就要往回折。默认那套(`bottomRadius`)本来就小于这两个界,不走这里。
    public static func clampedCornerRadius(_ radius: CGFloat, height: CGFloat, bodyWidth: CGFloat,
                                           shoulder: CGFloat) -> CGFloat {
        max(0, min(radius, bodyWidth / 2, height - shoulder))
    }

    /// 高为 `height` 的卡片底角最大能画多大(卡片够宽时),即 `clampedCornerRadius` 的高度那一界。
    public static func cornerRadiusLimit(height: CGFloat, notchHeight: CGFloat) -> CGFloat {
        let s = shoulder(width: .greatestFiniteMagnitude, height: height, notchHeight: notchHeight)
        return clampedCornerRadius(.greatestFiniteMagnitude, height: height, bodyWidth: .greatestFiniteMagnitude, shoulder: s)
    }

    /// 高为 `cardHeight` 的那一态,固定圆角的滑杆能拖的范围:上限取 `customRadiusRange` 与这张卡片画得出的最大圆角
    /// (向下取整)中的小者,滑杆上不留拖了不变的那一段。
    public static func customRadiusRange(cardHeight: CGFloat, notchHeight: CGFloat) -> ClosedRange<Double> {
        let limit = Double(cornerRadiusLimit(height: cardHeight, notchHeight: notchHeight)).rounded(.down)
        let upper = max(customRadiusRange.lowerBound + 1, min(customRadiusRange.upperBound, limit))
        return customRadiusRange.lowerBound...upper
    }

    /// 默认那套:这个高度的卡片用多大的圆角(只看高度,窄到要按宽度夹的情况交给形状自己)。
    public static func proportionalRadius(height: CGFloat) -> CGFloat {
        bottomRadius(height: height, bodyWidth: .greatestFiniteMagnitude)
    }

    /// 机器刘海本身的底角:刘海高 × `bottomRadiusPerHeight`(32pt → 8pt、16 寸 38pt → 9.5pt)。
    public static func notchCornerRadius(notchHeight: CGFloat) -> CGFloat {
        max(0, notchHeight * bottomRadiusPerHeight)
    }

    /// 两态的圆角规则与卡片高度;两个设置都是默认时返回 nil(形状照旧按高度算,跟没有这两个设置时一样)。
    /// `collapsedHeight` / `expandedHeight` 是没展开 / 展开两种形态的卡片高度。
    public static func cornerProfile(collapsedSetting: Double, expandedSetting: Double,
                                     collapsedHeight: CGFloat, expandedHeight: CGFloat,
                                     notchHeight: CGFloat, isExpanded: Bool) -> NotchCornerProfile? {
        let collapsed = NotchCornerRule(setting: collapsedSetting)
        let expanded = NotchCornerRule(setting: expandedSetting)
        guard collapsed != .proportional || expanded != .proportional else { return nil }
        return NotchCornerProfile(collapsed: collapsed, expanded: expanded, collapsedHeight: collapsedHeight,
                                  expandedHeight: expandedHeight, notchHeight: notchHeight, isExpanded: isExpanded)
    }
}

/// 一种形态的底部圆角规则。
public enum NotchCornerRule: Equatable, Sendable {
    /// 默认:按卡片高度算(`NotchOutline.proportionalRadius`)。
    case proportional
    /// 跟随刘海:机器刘海本身的底角(`NotchOutline.notchCornerRadius`),跟卡片多高无关。
    case notch
    /// 固定值(pt)。
    case fixed(CGFloat)

    /// 存盘值 → 规则。固定值夹进 `customRadiusRange`;认不出的负数按默认处理。
    public init(setting: Double) {
        if setting >= 0 {
            let r = min(max(setting, NotchOutline.customRadiusRange.lowerBound), NotchOutline.customRadiusRange.upperBound)
            self = .fixed(CGFloat(r))
        } else if setting == NotchOutline.notchRadiusSetting {
            self = .notch
        } else {
            self = .proportional
        }
    }

    public func radius(height: CGFloat, notchHeight: CGFloat) -> CGFloat {
        switch self {
        case .proportional: return NotchOutline.proportionalRadius(height: height)
        case .notch: return NotchOutline.notchCornerRadius(notchHeight: notchHeight)
        case .fixed(let r): return r
        }
    }
}

/// 卡片底部圆角的完整描述:没展开 / 展开两条规则,加两种形态的卡片高度。
///
/// 圆角只由**这一帧的卡片高度**决定:停在哪一态就是哪一态的规则;两态之间的尺寸动画里按高度走到哪儿,把两条
/// 规则按比例混合。所以圆角跟着高度连续变,不靠动画插值;卡片停着时只看自己那一态的规则,改另一态的设置碰不到它。
/// 出场动画那几帧比没展开的卡片还矮,按没展开那一态的规则算。
public struct NotchCornerProfile: Equatable, Sendable {
    public var collapsed: NotchCornerRule
    public var expanded: NotchCornerRule
    public var collapsedHeight: CGFloat
    public var expandedHeight: CGFloat
    public var notchHeight: CGFloat
    /// 两态一样高时(展开区什么都不显示)高度分不出形态,按这个挑规则。
    public var isExpanded: Bool

    public init(collapsed: NotchCornerRule, expanded: NotchCornerRule, collapsedHeight: CGFloat,
                expandedHeight: CGFloat, notchHeight: CGFloat, isExpanded: Bool) {
        self.collapsed = collapsed
        self.expanded = expanded
        self.collapsedHeight = collapsedHeight
        self.expandedHeight = expandedHeight
        self.notchHeight = notchHeight
        self.isExpanded = isExpanded
    }

    /// 高为 `height` 的卡片用多大的圆角(还没夹,那一步在形状里,见 `NotchOutline.clampedCornerRadius`)。
    public func radius(height: CGFloat) -> CGFloat {
        let low = collapsed.radius(height: height, notchHeight: notchHeight)
        let high = expanded.radius(height: height, notchHeight: notchHeight)
        guard expandedHeight > collapsedHeight else { return isExpanded ? high : low }
        let t = min(max((height - collapsedHeight) / (expandedHeight - collapsedHeight), 0), 1)
        return low + (high - low) * t
    }
}
