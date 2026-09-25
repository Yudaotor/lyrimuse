import AppKit
import LyrimuseCore
import SwiftUI

// 悬浮歌词「长句处理 = 换行」时带逐字填色的主行:按可用宽度把这一句切成几行,每一行是一条
// `OverlayLyricScrollView`(滚动模式那一套图层行,装得下所以不滚),各自按自己那几个字的时间轴
// 用 CAKeyframeAnimation 填色 —— 装好之后主线程不再按帧参与。
//
// 之前是 30Hz `TimelineView` 包整个 `WrapLayout`、每个字一个渐变 `Text`:悬浮窗里任何一个逐帧
// 子视图都会带着整窗每拍布局 + 显示列表 + 图层提交一遍。实测只开悬浮歌词、
// 播放中,换行模式 9.3%、滚动模式(已经是图层路)4.0%。新用户默认就是换行模式。
//
// 折行跟 `WrapLayout` 同一个算法(`WrapLayoutMath.rows`:贪心、字间距 0),量宽跟滚动模式的图层行
// 同一个量法(`MenuBarMarqueeRenderer.width`),所以每一行的宽度跟那一行图层里画出来的长图逐点一致。
// 行高用图层行自己的式子(字高 +2 接住下伸部分,见 `OverlayLyricScrollView.textHeight`),行间不再
// 另加 `WrapLayout` 那 2pt:两者的行距因此相等。
//
// 描边:每一行的长图四周各留一圈 `LyricsTextStrokeMetrics.inset`,行与行的这圈预留**互相重叠**
// (行距只算字高),整块的外沿跟 SwiftUI 那条「整句套一次 lyricsTextStroke、四周 padding 一圈」一样。
//
// 鼠标命中:布局时把「文字实际占据的矩形」写进 `WrapContentRectSink`(同 `WrapLayout` 的约定,
// owner 用调用方给的那一行的身份),悬浮窗的「划过让开」/ 控制排热区照旧读它。
struct WrappedKaraokeRows: NSViewRepresentable {
    struct Spec: Equatable {
        var lineKey: String
        var words: [SyncedLyricWord]
        /// 非 nil = 开了逐词罗马音:折行的单位是「一组」(字 + 读音一列),不会把一组拆到两行。
        var groups: [SyncedLyricWordGroup]?
        var font: NSFont
        var romaFont: NSFont
        var baseColor: NSColor
        var fillColor: NSColor
        var romaBaseColor: NSColor
        var romaFillColor: NSColor
        var strokeColor: NSColor?
        var rowAlignment: WrapLayoutMath.RowAlignment
        var paused: Bool
    }

    let spec: Spec
    let nowMs: () -> Int
    var contentRectSink: WrapContentRectSink? = nil
    var sinkOwner: AnyHashable? = nil

    func makeNSView(context: Context) -> WrappedKaraokeRowsView { WrappedKaraokeRowsView() }

    func updateNSView(_ view: WrappedKaraokeRowsView, context: Context) {
        view.contentRectSink = contentRectSink
        view.sinkOwner = sinkOwner
        view.apply(spec: spec, nowMs: nowMs)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WrappedKaraokeRowsView, context: Context) -> CGSize? {
        let geo = WrappedKaraokeRowsView.Geometry(spec: spec, width: proposal.width.flatMap { $0.isFinite ? $0 : nil })
        if proposal.width.map({ $0.isFinite }) == true {
            // 跟 `WrapLayout.placeSubviews` 同一个时机的等价物:悬浮窗读热区的那条 GeometryReader
            // 在这一行定尺寸之后才求值,这里先写好,不必等 AppKit 那一趟 layout。
            nsView.report(geo)
        }
        return geo.size
    }
}

@MainActor
final class WrappedKaraokeRowsView: NSView {
    /// 一句歌词按某个宽度折好之后的几何。纯计算,`sizeThatFits` 与 `layout` 共用。
    struct Geometry {
        /// 每一行的条目下标(条目 = 字,或开了逐词罗马音时的一组)。
        var rows: [WrapLayoutMath.Row]
        var itemWidths: [CGFloat]
        var inset: CGFloat
        var pitch: CGFloat
        var wrapWidth: CGFloat
        var size: CGSize

        @MainActor
        init(spec: WrappedKaraokeRows.Spec, width: CGFloat?) {
            let inset = spec.strokeColor == nil ? 0 : LyricsTextStrokeMetrics.inset
            let main = Self.textHeight(spec.font)
            let roma = spec.groups == nil ? 0 : Self.textHeight(spec.romaFont)
            let pitch = main + roma
            self.inset = inset
            self.pitch = pitch
            let widths: [CGFloat]
            if let groups = spec.groups {
                // 列宽 = 上下两行更宽的那个;读音左右各留 2pt、没有读音的组按一个空格占位 ——
                // 跟 `OverlayLyricScrollView.layOut` 逐项一致,两边量出来的行宽才对得上。
                widths = groups.map { g in
                    let words = g.words.reduce(CGFloat(0)) { $0 + MenuBarMarqueeRenderer.width(of: $1.text, font: spec.font) }
                    let r = MenuBarMarqueeRenderer.width(of: g.romanization ?? " ", font: spec.romaFont) + 4
                    return max(words, r)
                }
            } else {
                widths = spec.words.map { MenuBarMarqueeRenderer.width(of: $0.text, font: spec.font) }
            }
            itemWidths = widths
            let sizes = widths.map { CGSize(width: $0, height: pitch) }
            if let width {
                wrapWidth = max(1, width - 2 * inset)
                rows = WrapLayoutMath.rows(sizes: sizes, maxWidth: wrapWidth, horizontalSpacing: 0)
                size = CGSize(width: width, height: CGFloat(rows.count) * pitch + 2 * inset)
            } else {
                // 没有宽度限制 = 在问「不折行要多宽」(`DuetStageInsetLayout` 拿它量自然宽),铺成一行如实作答。
                let natural = WrapLayoutMath.unconstrainedSize(sizes: sizes, horizontalSpacing: 0)
                wrapWidth = natural.width
                rows = WrapLayoutMath.rows(sizes: sizes, maxWidth: .infinity, horizontalSpacing: 0)
                size = CGSize(width: natural.width + 2 * inset, height: pitch + 2 * inset)
            }
        }

        /// 同 `OverlayLyricScrollView.textHeight`:行框和位图必须同一个式子,否则字会被裁。
        static func textHeight(_ font: NSFont) -> CGFloat {
            ceil(font.ascender - font.descender + font.leading) + 2
        }

        /// 文字实际占据的矩形(本视图坐标,y 向下),给鼠标命中判定用。
        var contentRect: CGRect {
            WrapLayoutMath.contentBounds(
                rows: rows, bounds: CGRect(x: inset, y: inset, width: wrapWidth, height: size.height - 2 * inset),
                verticalSpacing: 0, rowAlignment: alignment)
        }

        var alignment: WrapLayoutMath.RowAlignment = .center
    }

    var contentRectSink: WrapContentRectSink?
    var sinkOwner: AnyHashable?

    private var spec: WrappedKaraokeRows.Spec?
    private var nowMs: (() -> Int)?
    private var rowViews: [OverlayLyricScrollView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func apply(spec next: WrappedKaraokeRows.Spec, nowMs: @escaping () -> Int) {
        self.nowMs = nowMs
        let changed = spec != next
        spec = next
        if changed { needsLayout = true }
        // 每一行自己有漂移门与去重(`OverlayLyricScrollView.apply`),这里按原样把这一刻的时钟递下去:
        // 暂停 / 恢复 / 锚点重发都靠它重装动画。
        layoutRows(nowMs: nowMs())
    }

    override func layout() {
        super.layout()
        if let nowMs { layoutRows(nowMs: nowMs()) }
    }

    func report(_ geo: Geometry) {
        guard let sink = contentRectSink else { return }
        var g = geo
        g.alignment = spec?.rowAlignment ?? .center
        sink.rect = g.contentRect
        sink.owner = sinkOwner
    }

    private func layoutRows(nowMs: Int) {
        guard let spec, bounds.width > 0 else { return }
        var geo = Geometry(spec: spec, width: bounds.width)
        geo.alignment = spec.rowAlignment
        report(geo)

        while rowViews.count < geo.rows.count {
            let v = OverlayLyricScrollView()
            addSubview(v)
            rowViews.append(v)
        }
        while rowViews.count > geo.rows.count {
            rowViews.removeLast().removeFromSuperview()
        }

        for (i, row) in geo.rows.enumerated() {
            let slack = max(0, geo.wrapWidth - row.width)
            let indent: CGFloat
            switch spec.rowAlignment {
            case .leading: indent = 0
            case .trailing: indent = slack
            case .center: indent = slack / 2
            }
            // 行框 = 这一行的长图(含四周描边预留)再宽 1pt:图层行判「装得下」用的是 `<=`,留 1pt
            // 余量免得浮点误差把它判成要滚。长图按 .leading 静置,多出来那 1pt 落在右边、是透明的。
            let frame = CGRect(x: indent, y: CGFloat(i) * geo.pitch,
                               width: row.width + 2 * geo.inset + 1, height: geo.pitch + 2 * geo.inset)
            let view = rowViews[i]
            if view.frame != frame { view.frame = frame }
            view.nowProvider = self.nowMs
            view.apply(spec: rowSpec(spec, row: row, index: i), nowMs: nowMs)
        }
    }

    private func rowSpec(_ spec: WrappedKaraokeRows.Spec, row: WrapLayoutMath.Row, index: Int) -> OverlayScrollingLyricRow.Spec {
        let groups = spec.groups.map { all in row.indices.map { all[$0] } }
        let words = groups.map { $0.flatMap(\.words) } ?? row.indices.map { spec.words[$0] }
        return OverlayScrollingLyricRow.Spec(
            lineKey: "\(spec.lineKey)#\(index)",
            words: words,
            groups: groups,
            font: spec.font,
            romaFont: spec.romaFont,
            baseColor: spec.baseColor,
            fillColor: spec.fillColor,
            romaBaseColor: spec.romaBaseColor,
            romaFillColor: spec.romaFillColor,
            strokeColor: spec.strokeColor,
            alignment: .leading,
            paused: spec.paused)
    }
}
