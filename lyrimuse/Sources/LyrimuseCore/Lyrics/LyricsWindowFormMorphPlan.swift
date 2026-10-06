import CoreGraphics

/// 歌词窗口进 / 出迷你变形动画的参数与几何(App 侧 `LyricsWindowFormMorph`),纯函数。见 07 章决策 125。
public enum LyricsWindowFormMorphPlan {
    /// 卡片从旧 frame 走到新 frame 的时长与曲线(起步快、落地软)。
    public static let duration: Double = 0.36
    public static let curve: (Float, Float, Float, Float) = (0.3, 0.8, 0.25, 1)
    /// 截切换前那一张最多等多久。超时就不做动画、直接切(截图服务冷启动时第一张要 300 多毫秒)。
    public static let firstCaptureTimeout: Double = 0.25
    /// 截切换后那一张最多等多久(从真窗口换完布局算起)。超时就不交叉淡化,卡片落地后直接淡出。
    public static let secondCaptureTimeout: Double = 0.6
    /// 新图到手时动画已经快走完,交叉淡化至少留这么长,不让它一闪而过。
    public static let minimumCrossfade: Double = 0.12
    /// 收尾时临时窗淡出:有新图时两张几乎一样,快一点;没截到新图时是旧图换成真窗口,慢一点。
    public static let fadeOutMatched: Double = 0.1
    public static let fadeOutUnmatched: Double = 0.18
    /// 截不出圆角时用的半径(macOS 26 起这类窗口约 16pt)。
    public static let fallbackCornerRadius: CGFloat = 16
    /// 临时窗比新旧两个 frame 的并集四周多留的地方,给卡片的阴影。
    public static let shadowMargin: CGFloat = 60

    /// 临时窗盖多大(屏幕坐标)。
    public static func overlayFrame(from start: CGRect, to end: CGRect, margin: CGFloat = shadowMargin) -> CGRect {
        start.union(end).insetBy(dx: -margin, dy: -margin)
    }

    /// 新图到手时剩下的交叉淡化时长:跟卡片同一刻落地,至少 `minimumCrossfade`。
    public static func crossfadeDuration(elapsed: Double, total: Double = duration,
                                         minimum: Double = minimumCrossfade) -> Double {
        max(minimum, total - elapsed)
    }

    /// 从窗口截图左上角对角线上的 alpha(从角点往里,一像素一个)量圆角半径(点)。
    /// 圆弧跟 45° 对角线交在离角点 R·(1 − 1/√2) 处,由 alpha 过半的位置反推 R。
    /// 整条都不透明(没有圆角)或都透明(背景本身透明)量不出来,返回 nil。
    public static func cornerRadius(diagonalAlpha: [UInt8], scale: CGFloat) -> CGFloat? {
        guard scale > 0, let i = diagonalAlpha.firstIndex(where: { $0 >= 128 }), i > 0 else { return nil }
        // 像素 k 的中心在 k + 0.5;过半那一处在前后两个像素中心之间按 alpha 线性插。
        let a0 = CGFloat(diagonalAlpha[i - 1]), a1 = CGFloat(diagonalAlpha[i])
        let crossing = CGFloat(i) - 0.5 + (128 - a0) / max(a1 - a0, 1)
        let radius = crossing / (1 - 1 / 2.0.squareRoot()) / scale
        return (4...40).contains(radius) ? radius : nil
    }

    /// 新旧两个 frame 落在不在同一块屏上(各自按重叠面积最大的那块算)。不在同一块就不做动画:
    /// 「每块显示器各自独立空间」打开时,一扇窗跨两块屏只会画在其中一块上。
    public static func sameScreen(_ start: CGRect, _ end: CGRect, screens: [CGRect]) -> Bool {
        func best(_ r: CGRect) -> Int? {
            let areas = screens.map { s -> CGFloat in
                let i = s.intersection(r)
                return i.isNull ? 0 : i.width * i.height
            }
            guard let m = areas.max(), m > 0 else { return nil }
            return areas.firstIndex(of: m)
        }
        guard let a = best(start), let b = best(end) else { return false }
        return a == b
    }
}
