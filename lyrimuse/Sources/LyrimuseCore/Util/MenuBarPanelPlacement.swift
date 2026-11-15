import CoreGraphics

/// 菜单栏左键面板窗口摆在哪:顶边贴着锚点下沿(留 `gap`)、水平居中在锚点下面,左右钳进锚点所在屏的可用区;
/// 比可用区高时截短到可用区底边上方 `margin`(内容贴顶,下面截掉),不往上推出可用区。
///
/// 宽高按整点向上取整:窗口尺寸落在整点上(半点的宽会被系统取成整点),按像素取整的话窗口跟算出来的永远差半点,
/// 每次摆位都要再改一次窗口。整点在 1x、2x 屏上都对得齐像素,算出来的结果跟窗口此刻在哪块屏无关。见 06 章决策 102。
public enum MenuBarPanelPlacement {
    public static let margin: CGFloat = 8
    public static let gap: CGFloat = 4

    public static func frame(fitting: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        let width = fitting.width.rounded(.up)
        let top = min(anchor.minY - gap, visible.maxY)
        let height = min(fitting.height.rounded(.up), max(top - visible.minY - margin, 1))
        let x = min(max(anchor.midX - width / 2, visible.minX + margin), visible.maxX - width - margin)
        return CGRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height)
    }

    /// 宿主视图报尺寸用的比较:理想尺寸按整点取整后跟现在的尺寸差到一点才报。跟 `frame` 同一个取整口径,
    /// 不然摆好之后宿主每轮布局都觉得差半点、再摆一次。
    public static func needsReport(fitting: CGSize, current: CGSize) -> Bool {
        abs(fitting.width.rounded(.up) - current.width) >= 1 || abs(fitting.height.rounded(.up) - current.height) >= 1
    }
}
