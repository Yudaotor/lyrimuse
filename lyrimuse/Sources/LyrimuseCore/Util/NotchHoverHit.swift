import CoreGraphics

/// 灵动岛 hover 命中判定(2026-09-07)。
///
/// # 为什么不能只靠 `.contentShape(Rectangle())`
///
/// 用户报「鼠标还没移到灵动岛上、只是移到它下面,卡片就展开了」。真机探针实测(在
/// `NotchWindowRoot.updateHover` 打进入/退出边沿的坐标,一次操作四条记录,每条都跟
/// `NSEvent.mouseLocation` + 窗口 frame 交叉核对过、误差 ≤1pt):
///
/// ```
/// 窗口 494,765 482x191   稳态卡片 257x77
/// ENTER local=(11,140)  expanded=false
/// ENTER local=(177,145) expanded=false
/// ENTER local=(120,176) expanded=false
/// ENTER local=(124,177) expanded=false
/// ```
///
/// `local` 的原点是**卡片左上角**(x 已经被约束在 0…卡片宽内),但 **y 一路给到 177**,
/// 而那一刻卡片只有 77pt 高 —— 也就是说 `.contentShape(Rectangle())` 只管住了横向,
/// 纵向的命中区仍是整扇窗(191pt)。窗口为了容纳展开态常驻最大尺寸,卡片下面那一百多
/// pt 全是透明区、压着用户自己的窗口,于是"光标划过那片空白"就把灵动岛捅开了。
///
/// 这不是新问题的新形态:2026-08-16 就为**同一个现象**把命中判定从 `NotchLyricsView`
/// 自带的 `.onHover` 挪到宿主层(见 `NotchLyricsWindowController.setExpanded` 的头注,
/// 当时实测「光标停在卡片下方 24pt 的透明处,卡片照样展开」)。那次的修法是加
/// `contentShape`,而这次的实测说明那道措施只挡住了一半。
///
/// 所以改成**自己拿坐标跟卡片矩形比**,不再把这件事托付给 SwiftUI 的命中形状 ——
/// 设置页编辑台(`NotchEditorStage`)那侧本来就是这么做的(`point.y <= cardHeight`),
/// 两处现在口径一致。
///
/// # 展开之后为什么仍然"下面也算数"
///
/// 传进来的是**当前**卡片尺寸:展开态的卡片本身就长到整扇窗那么大,于是展开后光标停在
/// 原来那片透明区上仍然判 inside、维持展开。展开卡片包含稳态卡片,不会出现"进了又出"
/// 的抖动 —— 这跟 `NotchWindowRoot.cardWidth` 头注里对宽度的说明是同一条道理。
public enum NotchHoverHit {
    /// - Parameters:
    ///   - point: `onContinuousHover` 给的 local 坐标,原点在卡片左上角(实测,见上)。
    ///   - cardWidth/cardHeight: **当前**卡片尺寸(稳态/展开态各自的那一份)。
    public static func isInside(point: CGPoint, cardWidth: CGFloat, cardHeight: CGFloat) -> Bool {
        point.x >= 0 && point.x <= cardWidth && point.y >= 0 && point.y <= cardHeight
    }
}
