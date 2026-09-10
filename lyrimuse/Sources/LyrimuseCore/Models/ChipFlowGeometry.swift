import CoreGraphics

/// 一排图标芯片在限定宽度内怎么换行(2026-09-10,设置页 Last.fm 卡「Scrobble 的播放器」那一行)。
///
/// 为什么把这几行算术从 SwiftUI 的 `Layout` 里抽出来:`Layout` 的 `Subviews` 在 selftest 里造不出来,
/// 而"放不放得下、往哪一行落"正是这一行**唯一**会出错的地方 —— 候选个数由用户的信任列表决定(内置
/// 播放器最多五个,信任的浏览器 / App 不设上限),写死一行会在窄窗口下把标题挤没或把芯片裁掉半个。
/// 判据落在纯函数上、selftest 直接覆盖,是这个仓一贯的做法(见 NotchExpandedMetrics / NotchWidthBounds)。
public enum ChipFlowGeometry {
    /// 一行的排布结果:这一行装了哪几个(下标,按传入顺序连续)、整行多宽。
    public struct Row: Equatable, Sendable {
        public let indices: [Int]
        public let width: CGFloat
        public init(indices: [Int], width: CGFloat) {
            self.indices = indices
            self.width = width
        }
    }

    /// 按顺序装箱:装不下就换行。**单个就比 limit 宽时仍然独占一行**(而不是丢掉或压缩)——
    /// 宁可这一行溢出一点被看见,也不要静默少画一枚芯片,那会让用户以为某个播放器不在候选里。
    /// `widths` 为空 → 空数组;`limit` ≤ 0(还没量到宽度的首帧)按"不限"处理,全塞一行。
    public static func rows(widths: [CGFloat], spacing: CGFloat, limit: CGFloat) -> [Row] {
        guard !widths.isEmpty else { return [] }
        let bound = limit > 0 ? limit : .greatestFiniteMagnitude
        var rows: [Row] = []
        var indices: [Int] = []
        var width: CGFloat = 0
        for (index, itemWidth) in widths.enumerated() {
            let widthIfAppended = indices.isEmpty ? itemWidth : width + spacing + itemWidth
            if !indices.isEmpty, widthIfAppended > bound {
                rows.append(Row(indices: indices, width: width))
                indices = []
                width = 0
            }
            width = indices.isEmpty ? itemWidth : width + spacing + itemWidth
            indices.append(index)
        }
        if !indices.isEmpty { rows.append(Row(indices: indices, width: width)) }
        return rows
    }

    /// 整块的尺寸:最宽那一行 × 行高累加(行间同样留 spacing)。`rowHeight` 是单枚芯片的高(等高)。
    public static func size(rows: [Row], rowHeight: CGFloat, spacing: CGFloat) -> CGSize {
        guard !rows.isEmpty else { return .zero }
        let width = rows.map(\.width).max() ?? 0
        let height = rowHeight * CGFloat(rows.count) + spacing * CGFloat(rows.count - 1)
        return CGSize(width: width, height: height)
    }
}
