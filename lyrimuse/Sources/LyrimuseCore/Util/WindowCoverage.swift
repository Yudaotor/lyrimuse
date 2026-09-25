import CoreGraphics

/// 一扇窗被别的窗口盖住了多少 —— 补 `NSWindow.occlusionState` 的一个盲区。
///
/// `occlusionState` 只要还有**一个像素**露在外面就报 `.visible`。实测:
/// 歌词窗口高 863、终端窗口只盖到它底边上方 16pt,于是那条 16pt 的缝让歌词窗口一直算「可见」,
/// 逐字填色照旧每秒 60 次整窗重绘 —— 盖住 98.4% 时 29.3%,最小化(真不可见)时 13.7%。
///
/// 判据:露出来的面积折算成一条跟窗口**同宽**的缝,不到 `maxGapHeight`(默认 24pt,比一行歌词还矮)
/// 就当作看不见。按面积折算而不是比例:大窗口露一条 16pt 的边和小窗口露一半,意义完全不同。
public enum WindowCoverage {
    /// 没被 `covers` 盖住的面积(点²)。按 `step` 的网格采样,每个样本代表 step² 的面积。
    public static func uncoveredArea(target: CGRect, covers: [CGRect], step: CGFloat = 4) -> CGFloat {
        guard target.width > 0, target.height > 0, step > 0 else { return 0 }
        let relevant = covers.filter { $0.intersects(target) }
        if relevant.isEmpty { return target.width * target.height }
        var uncovered = 0
        var y = target.minY + step / 2
        while y < target.maxY {
            var x = target.minX + step / 2
            while x < target.maxX {
                let p = CGPoint(x: x, y: y)
                if !relevant.contains(where: { $0.contains(p) }) { uncovered += 1 }
                x += step
            }
            y += step
        }
        return CGFloat(uncovered) * step * step
    }

    /// 露出来的部分折算成一条跟窗口同宽的缝,不到 `maxGapHeight` 高就算看不见。
    public static func isEffectivelyHidden(target: CGRect, covers: [CGRect],
                                           maxGapHeight: CGFloat = 24, step: CGFloat = 4) -> Bool {
        guard target.width > 0, target.height > 0 else { return false }
        let area = uncoveredArea(target: target, covers: covers, step: step)
        return area / target.width < maxGapHeight
    }
}
