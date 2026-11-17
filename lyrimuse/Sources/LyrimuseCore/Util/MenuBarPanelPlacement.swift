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

    /// 锚点所在的窗口已经摆上屏:有高度、跟某块屏有交集。系统还没给新建的状态栏项排好位置时,它的窗口在 (0, 0) 高 0 或在
    /// 屏幕下沿外面(冷启动后主线程忙时能拖好几秒),按它摆出来的面板只有 1 点高、在屏外,宿主每轮布局都报尺寸、主线程一直在
    /// 摆窗口。要判窗口的 frame,别判按钮换算到屏幕的矩形:按钮自己有高度,窗口高 0 时它照样落在屏幕左下角里。见 06 章决策 109。
    public static func anchorIsPlaced(_ anchorWindow: CGRect, screens: [CGRect]) -> Bool {
        anchorWindow.height > 0 && screens.contains { $0.intersects(anchorWindow) }
    }

    /// 锚点还没摆上屏时借用的锚点:这块屏菜单栏下沿正中。
    public static func fallbackAnchor(screen: CGRect, visible: CGRect) -> CGRect {
        CGRect(x: screen.midX, y: visible.maxY, width: 0, height: 0)
    }

    /// 宿主视图报尺寸用的比较:理想尺寸按整点取整后跟现在的尺寸差到一点才报。跟 `frame` 同一个取整口径,
    /// 不然摆好之后宿主每轮布局都觉得差半点、再摆一次。
    public static func needsReport(fitting: CGSize, current: CGSize) -> Bool {
        abs(fitting.width.rounded(.up) - current.width) >= 1 || abs(fitting.height.rounded(.up) - current.height) >= 1
    }
}
