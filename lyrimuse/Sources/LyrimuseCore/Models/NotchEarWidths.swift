import CoreGraphics

/// 灵动岛卡片左右两侧各伸出刘海多少:外露宽 = 刘海边沿到卡片外沿,含卡片内边距和朝刘海那侧的内缩
/// (歌词槽 = 外露宽 − 内边距 − 内缩)。没有刘海的屏把中线当成宽 0 的刘海,从中线往两侧量。
///
/// 两耳等宽时两侧相等,卡片以刘海为中心;关掉「两耳等宽」后两侧各按自己的设定值,稳态卡片偏向宽的那一侧(`offset`)。
/// 见 05 章决策 160。
public struct NotchEarSpan: Equatable, Sendable {
    public var left: CGFloat
    public var right: CGFloat

    public init(left: CGFloat, right: CGFloat) {
        self.left = left
        self.right = right
    }

    /// 以刘海为中心、宽 `cardWidth` 的卡片两侧各伸出多少。
    public static func symmetric(cardWidth: CGFloat, notchWidth: CGFloat) -> NotchEarSpan {
        let side = (cardWidth - notchWidth) / 2
        return NotchEarSpan(left: side, right: side)
    }

    /// 宽 `cardWidth`、中心比刘海中心往右偏 `offset` 的卡片两侧各伸出多少。
    public static func of(cardWidth: CGFloat, offset: CGFloat, notchWidth: CGFloat) -> NotchEarSpan {
        let half = (cardWidth - notchWidth) / 2
        return NotchEarSpan(left: half - offset, right: half + offset)
    }

    /// 卡片宽:刘海加两侧外露宽。
    public func cardWidth(notchWidth: CGFloat) -> CGFloat {
        notchWidth + left + right
    }

    /// 卡片中心比刘海中心往右偏多少(右侧宽时为正)。
    public var offset: CGFloat {
        (right - left) / 2
    }
}

/// 关掉「两耳等宽」后每只耳朵各自的宽度算术。设定值是上限,每侧只按自己那侧的菜单栏空位和自己那只耳朵的模块下限夹;
/// 收起、展开仍以刘海为中心。真窗口、编辑台、菜单栏快捷面板都走这里。见 05 章决策 160。
public enum NotchEarWidths {
    /// 外露宽设定值的合法区间(存储层)。0 = 没设过(按当时的稳态宽对称起步)。
    public static let storageRange: ClosedRange<Double> = 0 ... 400

    /// 每只耳朵宽度滑杆的步长,同编辑台宽度调整条。
    public static let step: Double = NotchWidthBounds.step

    /// 一侧稳态外露宽:设定值按这一侧的上限 `cap` 夹,不窄于这一侧的下限 `floor`(上限比下限还窄时停在下限)。
    /// `cap` 为 nil 时不夹。
    public static func steady(setting: CGFloat, floor: CGFloat, cap: CGFloat?) -> CGFloat {
        guard let cap else { return max(floor, setting) }
        return max(floor, min(setting, cap))
    }

    /// 两侧各按 `steady(setting:floor:cap:)` 夹。
    public static func steady(setting: NotchEarSpan, floor: NotchEarSpan, cap: NotchEarSpan?) -> NotchEarSpan {
        NotchEarSpan(left: steady(setting: setting.left, floor: floor.left, cap: cap?.left),
                     right: steady(setting: setting.right, floor: floor.right, cap: cap?.right))
    }

    /// 收起态两侧:每侧 `min(稳态外露宽, 收起那一段)`。有刘海时收起那一段 = 收起耳宽 + 内边距;没有刘海的屏中间按
    /// `NotchCardLayout.collapsedGapWithoutNotch` 留空(05 章决策 128),从中线量起先加一半空当。两侧相等时等于两耳等宽的收起宽。
    public static func collapsed(_ steady: NotchEarSpan, notchWidth: CGFloat, collapsedEarWidth: CGFloat,
                                 cardPadding: CGFloat) -> NotchEarSpan {
        let gapHalf = notchWidth > 0 ? 0 : NotchCardLayout.collapsedGapWithoutNotch / 2
        let limit = gapHalf + collapsedEarWidth + cardPadding
        return NotchEarSpan(left: min(steady.left, limit), right: min(steady.right, limit))
    }

    /// 展开态卡片宽:以刘海为中心,取展开设定和「刘海 + 两倍较宽那一侧」的大者,展开卡片一定包住稳态卡片。
    public static func expandedWidth(steady: NotchEarSpan, notchWidth: CGFloat, expandedSetting: CGFloat) -> CGFloat {
        max(expandedSetting, notchWidth + 2 * max(steady.left, steady.right))
    }

    /// 菜单栏两侧各留给这一侧多宽:左 = 刘海左沿到可用区间左界,右 = 可用区间右界到刘海右沿。`span` 是
    /// `MenuBarCenterLayout.usableSpan` 给的那一段(已经各让开 `clearance`);nil(两侧挤得放不下)时两侧都是 0。
    public static func caps(centerX: CGFloat, notchWidth: CGFloat, span: ClosedRange<CGFloat>?) -> NotchEarSpan {
        guard let span else { return NotchEarSpan(left: 0, right: 0) }
        return NotchEarSpan(left: max(0, centerX - notchWidth / 2 - span.lowerBound),
                            right: max(0, span.upperBound - centerX - notchWidth / 2))
    }

    /// 一只耳朵宽度滑杆能拖的区间:下界抬到这一侧的下限(向上取整到 `step`),上界同 `storageRange`;下界至少一个 step、
    /// 不越过上界。
    public static func usableRange(floor: Double) -> ClosedRange<Double> {
        let ceiled = (floor / step).rounded(.up) * step
        let lower = min(max(ceiled, step), storageRange.upperBound - step)
        return lower ... storageRange.upperBound
    }

    /// 设定值没设过(0)时用 `fallback`(两耳等宽时的稳态外露宽)。
    public static func resolvedSetting(_ setting: Double, fallback: CGFloat) -> CGFloat {
        setting > 0 ? CGFloat(setting) : fallback
    }

    /// 关掉「两耳等宽」那一刻两侧的起点:当时稳态卡片(以刘海为中心)两侧的外露宽,卡片不跳。
    public static func unlinkStart(steadyCardWidth: CGFloat, notchWidth: CGFloat) -> NotchEarSpan {
        NotchEarSpan.symmetric(cardWidth: steadyCardWidth, notchWidth: notchWidth)
    }
}
