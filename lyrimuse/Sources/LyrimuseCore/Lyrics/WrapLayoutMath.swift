import CoreGraphics

/// 逐字歌词那个自动换行容器的**几何计算**。不认识 SwiftUI —— 把结果喂给
/// `subviews[i].place(...)` 是 UI 层那个 Layout 壳子的事(见 WrapLayout)。
///
/// 拆出来的理由跟 KaraokeFill 一样:这段算法出过真问题(一行装不下时整行文字被压成一串
/// 省略号"消失"),但它长在 View 文件里,除了盯着屏幕看没有别的办法验证。现在
/// `lyrimuse-selftest` 可以直接问它:给这些尺寸和这个宽度,你打算怎么排。
public enum WrapLayoutMath {
    /// 行内的水平对齐——悬浮歌词/灵动岛是居中排版;"歌词窗口"2026-08-04 改成 Apple Music
    /// 歌词页同款的左对齐后用 leading。trailing 是 2026-08-14 为对唱歌词右侧那位加的
    /// (见 LyricDuet)。
    public enum RowAlignment: Sendable {
        case center, leading, trailing
    }

    public struct Row: Equatable, Sendable {
        public let indices: [Int]
        public let width: CGFloat
        public let height: CGFloat
    }

    /// 一个子视图最终落在哪儿。`index` 是它在输入 sizes 里的下标。
    public struct Placement: Equatable, Sendable {
        public let index: Int
        public let origin: CGPoint
        public let size: CGSize
    }

    /// 按顺序把子视图塞进每行,塞不下就换行。
    ///
    /// ⚠️ 单个子视图本身就比 maxWidth 宽时,它**独占一行并且原样保留**,不会被丢掉也不
    /// 会被压缩——`!indices.isEmpty` 那个条件就是干这个的:一行还空着的时候永远先放进去
    /// 再说。这一条正是"长歌词行变成一串省略号"那个 bug 的修法,别在这里加"太宽就跳过"
    /// 之类的判断。
    public static func rows(
        sizes: [CGSize], maxWidth: CGFloat, horizontalSpacing: CGFloat
    ) -> [Row] {
        var rows: [Row] = []
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            let spacingIfContinuing = indices.isEmpty ? 0 : horizontalSpacing
            if !indices.isEmpty && width + spacingIfContinuing + size.width > maxWidth {
                rows.append(Row(indices: indices, width: width, height: height))
                indices = []
                width = 0
                height = 0
            }
            let spacing = indices.isEmpty ? 0 : horizontalSpacing
            width += spacing + size.width
            height = max(height, size.height)
            indices.append(i)
        }
        if !indices.isEmpty {
            rows.append(Row(indices: indices, width: width, height: height))
        }
        return rows
    }

    /// 换行之后整块占多大。宽度直接取给定的 maxWidth(容器给多少用多少),高度是各行行高
    /// 加行距。
    public static func totalSize(
        sizes: [CGSize], maxWidth: CGFloat, horizontalSpacing: CGFloat, verticalSpacing: CGFloat
    ) -> CGSize {
        totalSize(
            rows: rows(sizes: sizes, maxWidth: maxWidth, horizontalSpacing: horizontalSpacing),
            maxWidth: maxWidth, verticalSpacing: verticalSpacing)
    }

    /// 带 rows 的版本:调用方(WrapLayout 的 Layout 壳)把换行分组缓存住之后直接喂进来,
    /// sizeThatFits/placeSubviews 不再各自重算一遍 rows(2026-08-20 性能审计)。
    public static func totalSize(
        rows: [Row], maxWidth: CGFloat, verticalSpacing: CGFloat
    ) -> CGSize {
        let totalHeight = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        return CGSize(width: maxWidth, height: totalHeight)
    }

    /// 排完之后**文字真正占据**的那块矩形(在 bounds 坐标系里)。
    ///
    /// 跟 totalSize 是两回事:那个返回的是**布局尺寸**,宽度恒等于容器给的 maxWidth
    /// (撑满是刻意的 —— 对唱左右对齐要靠它才有地方可对)。这个返回的是内容自己的
    /// 包围盒,宽度 = 最宽那一行的宽度。
    ///
    /// 给"鼠标划过歌词才让开"用(2026-08-23):原来的判据是整个窗口矩形
    /// `window.frame.contains(鼠标)`,而窗口比文字大得多 —— 上下有卡片内边距和播放
    /// 控制槽位、左右是 WrapLayout 撑满留下的空白,于是指针在歌词**附近**就触发了淡出。
    ///
    /// 每一行各自按 rowAlignment 对齐,所以并集的宽度就是最宽行的宽度、位置随对齐方式:
    /// 靠左时贴 bounds.minX、靠右时贴 bounds.maxX、居中时两边等分。
    public static func contentBounds(
        rows: [Row], bounds: CGRect, verticalSpacing: CGFloat, rowAlignment: RowAlignment
    ) -> CGRect {
        guard !rows.isEmpty else { return .zero }
        let widest = rows.reduce(CGFloat(0)) { max($0, $1.width) }
        let height = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        guard widest > 0, height > 0 else { return .zero }
        let slack = max(0, bounds.width - widest)
        let x: CGFloat
        switch rowAlignment {
        case .leading: x = bounds.minX
        case .trailing: x = bounds.minX + slack
        case .center: x = bounds.minX + slack / 2
        }
        return CGRect(x: x, y: bounds.minY, width: min(widest, bounds.width), height: height)
    }

    /// 没有宽度约束时的兜底尺寸:全部铺成一行。理论上走不到——调用方所在的 VStack 总会
    /// 给一个有限宽度。
    public static func unconstrainedSize(sizes: [CGSize], horizontalSpacing: CGFloat) -> CGSize {
        let totalWidth = sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, sizes.count - 1)) * horizontalSpacing
        return CGSize(width: totalWidth, height: sizes.map(\.height).max() ?? 0)
    }

    /// 每个子视图的最终位置。行内按 rowAlignment 居中/靠左/靠右,竖直方向在本行内居中。
    public static func placements(
        sizes: [CGSize], bounds: CGRect, horizontalSpacing: CGFloat, verticalSpacing: CGFloat,
        rowAlignment: RowAlignment
    ) -> [Placement] {
        placements(
            rows: rows(sizes: sizes, maxWidth: bounds.width, horizontalSpacing: horizontalSpacing),
            sizes: sizes, bounds: bounds,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing,
            rowAlignment: rowAlignment)
    }

    /// 带 rows 的版本,理由见 totalSize(rows:) 注释。
    public static func placements(
        rows: [Row], sizes: [CGSize], bounds: CGRect,
        horizontalSpacing: CGFloat, verticalSpacing: CGFloat,
        rowAlignment: RowAlignment
    ) -> [Placement] {
        var result: [Placement] = []
        result.reserveCapacity(sizes.count)
        var y = bounds.minY
        for row in rows {
            let slack = max(0, bounds.width - row.width)
            let indent: CGFloat
            switch rowAlignment {
            case .center: indent = slack / 2
            case .leading: indent = 0
            case .trailing: indent = slack
            }
            var x = bounds.minX + indent
            for i in row.indices {
                let size = sizes[i]
                result.append(Placement(
                    index: i,
                    origin: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    size: size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
        return result
    }
}
