import CoreGraphics
import Foundation

// 菜单栏歌词放在「菜单栏正中」时,那扇窗口落在哪块屏、哪一段(06 章「菜单栏正中」)。
//
// 状态栏项的位置由系统排、只能在右侧那一串里,放不到中间,所以这一档另开一扇透明窗口画在菜单栏上。
// 菜单栏左边是前台 App 的菜单,右边是各家的状态栏图标,歌词只能放在两者之间:优先以整块屏的中线居中,
// 一侧挤过来就往另一侧让,两侧各留 `clearance`。两侧的位置由 App 侧经辅助功能读出来(`MenuBarOccupancy`),
// 读不到(没授权、还没扫到)的那一侧按屏幕边缘算。这里只管算,不碰 AppKit。
public enum MenuBarCenterLayout {
    /// 跟两侧已有内容至少隔多远。
    public static let clearance: CGFloat = 16
    /// 中间那一段比这还窄就不放了(退回图标旁)。
    public static let minimumSpan: CGFloat = 60
    /// 读不到菜单栏高度时的兜底(菜单栏自动隐藏、全屏 Space 里 `visibleFrame` 顶到屏幕上沿),跟灵动岛同一个数。
    public static let fallbackMenuBarHeight: CGFloat = 24

    /// 一块屏能不能放居中歌词。
    public struct ScreenCandidate: Equatable, Sendable {
        public let hasNotch: Bool
        /// 灵动岛在这块屏上(它占着菜单栏正中)。
        public let islandHere: Bool
        public init(hasNotch: Bool, islandHere: Bool) {
            self.hasNotch = hasNotch
            self.islandHere = islandHere
        }
    }

    /// 选哪块屏:主屏(第 0 块,带菜单栏的那块)能用就用它,否则第一块能用的。有刘海的屏正中就是刘海,
    /// 灵动岛占着的屏正中已经有东西,都不算。nil = 没有能用的,歌词照旧在图标旁。
    public static func pickScreen(_ candidates: [ScreenCandidate]) -> Int? {
        candidates.firstIndex { !$0.hasNotch && !$0.islandHere }
    }

    /// 菜单栏里能放歌词的那一段(全局横坐标)。`menusMaxX` 是前台 App 菜单的右缘,`statusItemsMinX` 是状态栏图标的左缘,
    /// 各自 nil = 那一侧读不到、按屏幕边缘算。放不下 `minimumSpan` 时返回 nil。
    public static func usableSpan(screenMinX: CGFloat, screenMaxX: CGFloat,
                                  menusMaxX: CGFloat?, statusItemsMinX: CGFloat?) -> ClosedRange<CGFloat>? {
        let lo = max(screenMinX, menusMaxX ?? screenMinX) + clearance
        let hi = min(screenMaxX, statusItemsMinX ?? screenMaxX) - clearance
        guard hi - lo >= minimumSpan else { return nil }
        return lo...hi
    }

    /// 宽 `width` 的窗口左沿:以屏幕中线居中,出了 `span` 就往里推,整块不出 `span`。宽过 `span` 时按 `span` 宽算。
    public static func originX(width: CGFloat, screenMidX: CGFloat, span: ClosedRange<CGFloat>) -> CGFloat {
        let w = min(width, span.upperBound - span.lowerBound)
        let centered = (screenMidX - w / 2).rounded()
        return min(max(centered, span.lowerBound.rounded(.up)), (span.upperBound - w).rounded(.down))
    }

    /// 前台 App 菜单的右缘,换算到目标屏上。`menuFrames` 是辅助功能读到的各菜单项(横坐标跟 AppKit 全局坐标一致);
    /// 菜单画在哪块屏的菜单栏上就以那块屏左缘为准量出偏移,再套到目标屏 —— 每块屏的菜单栏排法一样,
    /// 而辅助功能只报当前活跃那一份。
    public static func menusMaxX(menuFrames: [CGRect], screenFrames: [CGRect], target: CGRect) -> CGFloat? {
        let visible = menuFrames.filter { $0.width > 0 }
        guard let firstX = visible.map(\.minX).min(), let maxX = visible.map(\.maxX).max() else { return nil }
        let host = screenFrames.first { firstX >= $0.minX && firstX < $0.maxX } ?? target
        return target.minX + (maxX - host.minX)
    }

    /// 状态栏图标最左那个的左缘,目标屏上的。`itemFrames` 是辅助功能读到的各家状态栏项(左上角为原点、y 向下),
    /// `primaryMaxY` 是主屏(AppKit 坐标)的上沿,用来把 y 换过去。只认落在某块屏菜单栏那一条里的项 —— 被系统收起
    /// 藏掉的项会报在屏幕底部或左上角之外。目标屏上一个都没有时,拿别的屏菜单栏上的那一串按右缘对齐换算过来。
    public static func statusItemsMinX(itemFrames: [CGRect], screenFrames: [CGRect], target: CGRect,
                                       primaryMaxY: CGFloat, menuBarHeight: CGFloat) -> CGFloat? {
        func minX(on screen: CGRect) -> CGFloat? {
            let top = primaryMaxY - screen.maxY
            return itemFrames.filter { item in
                item.width > 0 && item.height > 0
                    && item.midY >= top && item.midY <= top + menuBarHeight
                    && item.minX >= screen.minX && item.maxX <= screen.maxX + 1
            }.map(\.minX).min()
        }
        if let own = minX(on: target) { return own }
        for screen in screenFrames where screen != target {
            if let other = minX(on: screen) { return target.maxX - (screen.maxX - other) }
        }
        return nil
    }
}
