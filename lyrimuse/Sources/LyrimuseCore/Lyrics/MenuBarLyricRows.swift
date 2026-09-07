import CoreGraphics
import Foundation

/// 菜单栏歌词双排(副行开着)时两行的几何(2026-09-06,借鉴清单 #57,用户在五档 HTML 对比里选了 B 方案)。
///
/// 硬约束:状态栏项的按钮**恒 22pt 高**(`NSStatusBar.system.thickness`;带刘海的机器菜单栏本身 33pt、
/// 外接屏 24pt,按钮都是 22),两行只能塞进这 22pt。本机实测 SF 字面高(ascender − descender):
/// 8→9.42、9→10.60、9.5→11.19、10→11.78、11→12.96、13→15.31。任何「主 ≥10 + 副 ≥9」的组合两行字面
/// 合计 22.4pt、超框 0.4pt,但汉字 / 假名墨迹只占字面框约九成、拉丁字只有 g/y 的下伸部分贴边,实际不裁;
/// 唯一不超框的是 10 + 8(21.2),看起来跟 10 + 9 差别很小、副行反而更小。五档对比(A 现状 13 单行 /
/// B 10+9 / C 9.5+9.5 参考实现的等分 / D 11+8 / E 10+8)用 App 同一套字体离屏真渲后,用户选 B:
/// Retina 上两行都清楚、主副有别;C 分不出主次;D/E 的 8pt 副行在 1x 外接屏上会糊。
///
/// 所以双排下**两行字号是常量**、不听「字号」滑杆(那根滑杆的上限 16 本来就是按"行高 ≤ 22"推出来的,
/// 同一条约束在双排下把每行压到 ≤10)。粗细仍听用户的。
///
/// 纯函数、无状态,selftest 覆盖。渲染侧(`MenuBarScrollingLabel.contentGeometry`)按这里的布局摆
/// 两个图层,位图高度就是各自字体的 ceil(字面高)。
public enum MenuBarLyricRows {
    /// 状态栏项按钮的高度。渲染侧实际传的是 `bounds.height`(它就是这个数),这里的常量给 selftest 和
    /// 设置页预览(那条仿菜单栏里 Representable 的 frame 高)用。
    public static let buttonHeight: CGFloat = 22
    /// 主行字号(B 方案)。
    public static let mainPointSize: CGFloat = 10
    /// 副行字号(B 方案)。
    public static let secondaryPointSize: CGFloat = 9
    /// 副行装不下时右端渐隐的宽度。副行**不滚**:两行各滚各的会乱,而副行本来就是辅助信息,
    /// 尾部看不全可以接受(跟灵动岛副行同一条规则)。
    public static let tailFadeWidth: CGFloat = 14

    /// 两行在按钮里的纵向落点(视图坐标,原点左下、y 向上)。主行在上、副行在下。
    public struct Layout: Equatable, Sendable {
        public let mainY: CGFloat
        public let mainHeight: CGFloat
        public let secondaryY: CGFloat
        public let secondaryHeight: CGFloat
    }

    /// - Parameters:
    ///   - mainHeight / secondaryHeight: 两行位图的点高(= 各自字体 ceil(ascender − descender))。
    ///   - buttonHeight: 按钮高(22)。
    ///
    /// 装得下(两行合计 ≤ 按钮高):整块垂直居中(余量取整到整点,跟单行那条 `((h − lineHeight) / 2).rounded()`
    /// 同一口径),主行在上。装不下(10pt/9pt 实测 12 + 11 = 23 > 22):主行贴顶、副行贴底,中间重叠
    /// 合计 − 按钮高(=1pt)—— 重叠落在主行的下伸区与副行的上伸区,墨迹不撞(见类型注释里的字面高账)。
    public static func layout(mainHeight: CGFloat, secondaryHeight: CGFloat, buttonHeight: CGFloat) -> Layout {
        let total = mainHeight + secondaryHeight
        if total <= buttonHeight {
            let gap = ((buttonHeight - total) / 2).rounded()
            return Layout(mainY: buttonHeight - gap - mainHeight, mainHeight: mainHeight,
                          secondaryY: gap, secondaryHeight: secondaryHeight)
        }
        return Layout(mainY: buttonHeight - mainHeight, mainHeight: mainHeight,
                      secondaryY: 0, secondaryHeight: secondaryHeight)
    }

    /// 副行图层的不透明度:译文最清楚、罗马音次之、下一句最淡(它是"预告",不该跟正在唱的这句抢眼),
    /// 不显示为 0。跟灵动岛副行的三档(0.75 / 0.6 / 0.45)同一个梯度,下一句这一档略提亮到 0.55 ——
    /// 9pt 在菜单栏上比灵动岛的 11pt 小,0.45 已经读不清。
    public static func secondaryOpacity(for kind: LyricSecondaryLine) -> Float {
        switch kind {
        case .off: return 0
        case .nextLine: return 0.55
        case .translation: return 0.75
        case .romanization: return 0.6
        }
    }
}
