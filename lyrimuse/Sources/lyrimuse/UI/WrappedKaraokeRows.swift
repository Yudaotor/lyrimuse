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
//
// 换句时各行的长图在后台画(`OverlayRowRaster`),整句几行画好后在同一拍里一起换上(行数增减也在这一刻);
// 画好之前各行原样显示上一句。只是暂停 / 恢复 / 重锚这类不换图的变化当场处理,第一次出现时当场画。见 04 章决策 50。
struct WrappedKaraokeRows: NSViewRepresentable {
    struct Spec: Equatable {
        var lineKey: String
        var words: [SyncedLyricWord]
        /// 非 nil = 开了逐词罗马音:折行的单位是「一组」(字 + 读音一列),不会把一组拆到两行。
        var groups: [SyncedLyricWordGroup]?
        /// 同 `OverlayScrollingLyricRow.Spec.romaGap`,原样交给每一行,行距也按它算。
        var romaGap: CGFloat = 0
        var font: NSFont
        var romaFont: NSFont
        var baseColor: NSColor
        var fillColor: NSColor
        var romaBaseColor: NSColor
        var romaFillColor: NSColor
        var strokeColor: NSColor?
        var rowAlignment: WrapLayoutMath.RowAlignment
        var paused: Bool
        /// 同 OverlayScrollingLyricRow.Spec 的两项,原样交给每一行。
        var timingEpoch: Int = 0
        var rate: Double = 1
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
            nsView.sizedWidth = proposal.width
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
            let pitch = OverlayRowLayout.blockHeight(
                main: Self.textHeight(spec.font),
                roma: spec.groups == nil ? nil : Self.textHeight(spec.romaFont),
                romaGap: spec.romaGap)
            self.inset = inset
            self.pitch = pitch
            let widths: [CGFloat]
            if let groups = spec.groups {
                // 列宽 = 上下两行更宽的那个;读音两侧留白、没有读音的组按一个空格占位 ——
                // 跟 `OverlayRowLayout.layOut` 逐项一致,两边量出来的行宽才对得上。
                let pad = OverlayRowLayout.romaSidePadding(strokeInset: inset)
                widths = groups.map { g in
                    let words = g.words.reduce(CGFloat(0)) { $0 + MenuBarMarqueeRenderer.width(of: $1.text, font: spec.font) }
                    let r = MenuBarMarqueeRenderer.width(of: g.romanization ?? " ", font: spec.romaFont) + pad * 2
                    return max(words, r)
                }
            } else {
                widths = spec.words.map { MenuBarMarqueeRenderer.width(of: $0.text, font: spec.font) }
            }
            itemWidths = widths
            let sizes = widths.map { CGSize(width: $0, height: pitch) }
            // 按组折行时一组本来就是一个词;逐字时英文按音节切,不能在词中间断(见 WrapLayoutMath.rows)。
            let breakBefore = spec.groups == nil
                ? WrapLayoutMath.breakOpportunities(texts: spec.words.map(\.text)) : nil
            if let width {
                wrapWidth = max(1, width - 2 * inset)
                rows = WrapLayoutMath.rows(sizes: sizes, maxWidth: wrapWidth, horizontalSpacing: 0,
                                           breakBefore: breakBefore)
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
    /// 最近一次 `sizeThatFits` 收到的有限提议宽度,画的时候按它折行(见 `WrapLayoutMath.drawWidth`)。
    var sizedWidth: CGFloat?

    private var spec: WrappedKaraokeRows.Spec?
    private var nowMs: (() -> Int)?
    private var rowViews: [OverlayLyricScrollView] = []

    /// 一行要显示成什么:落点和规格。
    private struct RowTarget {
        var frame: CGRect
        var spec: OverlayScrollingLyricRow.Spec
    }

    /// 后台在画的那一句:各行的目标和排版。画好之前各行原样显示上一句。
    private struct PendingRows {
        var generation: Int
        var targets: [RowTarget]
        var geometries: [OverlayRowGeometry]
    }

    private var pending: PendingRows?
    private var renderGeneration = 0
    /// 一句的几行在一个任务里依次画完,再一起回主线程。
    private static let rasterQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.wrapped-rows-raster",
                                                   qos: .userInteractive)

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
        var geo = Geometry(spec: spec, width: WrapLayoutMath.drawWidth(sized: sizedWidth, bounds: bounds.width))
        geo.alignment = spec.rowAlignment
        report(geo)

        let scale = window?.backingScaleFactor ?? 2
        let targets = geo.rows.enumerated().map { i, row in
            RowTarget(frame: rowFrame(row, index: i, geo: geo, alignment: spec.rowAlignment, scale: scale),
                      spec: rowSpec(spec, row: row, index: i))
        }
        // 每一行装着的都已经是要的长图:只更新落点与时机(暂停 / 恢复 / 重锚都靠这条重装动画)。
        if targets.count == rowViews.count, zip(rowViews, targets).allSatisfy({ $0.showsImages(of: $1.spec) }) {
            pending = nil
            for (view, target) in zip(rowViews, targets) {
                if view.frame != target.frame { view.frame = target.frame }
                view.nowProvider = self.nowMs
                view.apply(spec: target.spec, nowMs: nowMs)
            }
            return
        }
        // 后台在画的就是这几张长图:记下最新的落点与时机,画好时照它装。
        if let p = pending, p.targets.count == targets.count,
           zip(p.targets, targets).allSatisfy({ OverlayLyricScrollView.sameImages($0.spec, $1.spec) }) {
            pending?.targets = targets
            return
        }
        let geometries = targets.map { OverlayLyricScrollView.geometry(spec: $0.spec, scale: scale) }
        // 一行都还没有(刚出现):当场画,不留一拍空白。
        if rowViews.isEmpty {
            pending = nil
            let images = zip(geometries, targets).map { OverlayRowRaster.render($0, spec: $1.spec) }
            install(targets, geometries: geometries, images: images, nowMs: nowMs)
            return
        }
        renderGeneration &+= 1
        let generation = renderGeneration
        pending = PendingRows(generation: generation, targets: targets, geometries: geometries)
        let batch = RowRasterBatch(items: zip(geometries, targets).map { ($0, $1.spec) })
        // 后台任务只拿弱引用:视图在画的这段时间里被拆掉时,最后一次释放不能落在出图队列上。
        let owner = WeakRowsView(self)
        Self.rasterQueue.async {
            let result = RowRasterResult(images: batch.items.map { OverlayRowRaster.render($0.0, spec: $0.1) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { owner.view?.finishRender(generation: generation, images: result.images) }
            }
        }
    }

    /// 后台画好了:还是最新的那一句就整句换上,否则丢掉(更新的一句已经在画)。
    private func finishRender(generation: Int, images: [OverlayRowImages]) {
        guard let p = pending, p.generation == generation, p.targets.count == images.count else { return }
        pending = nil
        // 画的这段时间里窗口换到了比例不同的屏:按新比例重排重画。
        if let scale = window?.backingScaleFactor, p.geometries.contains(where: { $0.scale != scale }) {
            if let nowMs { layoutRows(nowMs: nowMs()) }
            return
        }
        install(p.targets, geometries: p.geometries, images: images, nowMs: nowMs?() ?? 0)
    }

    /// 按目标行数增减行视图,逐行换上长图、摆位、重装动画。
    private func install(_ targets: [RowTarget], geometries: [OverlayRowGeometry],
                         images: [OverlayRowImages], nowMs: Int) {
        while rowViews.count < targets.count {
            let v = OverlayLyricScrollView()
            addSubview(v)
            rowViews.append(v)
        }
        while rowViews.count > targets.count {
            rowViews.removeLast().removeFromSuperview()
        }
        for (i, target) in targets.enumerated() {
            let view = rowViews[i]
            if view.frame != target.frame { view.frame = target.frame }
            view.nowProvider = self.nowMs
            view.install(spec: target.spec, geometry: geometries[i], images: images[i], nowMs: nowMs)
        }
    }

    private func rowFrame(_ row: WrapLayoutMath.Row, index: Int, geo: Geometry,
                          alignment: WrapLayoutMath.RowAlignment, scale: CGFloat) -> CGRect {
        let slack = max(0, geo.wrapWidth - row.width)
        var indent: CGFloat
        switch alignment {
        case .leading: indent = 0
        case .trailing: indent = slack
        case .center: indent = slack / 2
        }
        // 行框落在整像素上,理由同 `OverlayLyricScrollView.pixelAligned`。
        indent = (indent * scale).rounded() / scale
        // 行框 = 这一行的长图(含四周描边预留)再宽 1pt:图层行判「装得下」用的是 `<=`,留 1pt
        // 余量免得浮点误差把它判成要滚。长图按 .leading 静置,多出来那 1pt 落在右边、是透明的。
        return CGRect(x: indent, y: CGFloat(index) * geo.pitch,
                      width: row.width + 2 * geo.inset + 1, height: geo.pitch + 2 * geo.inset)
    }

    private func rowSpec(_ spec: WrappedKaraokeRows.Spec, row: WrapLayoutMath.Row, index: Int) -> OverlayScrollingLyricRow.Spec {
        let groups = spec.groups.map { all in row.indices.map { all[$0] } }
        let words = groups.map { $0.flatMap(\.words) } ?? row.indices.map { spec.words[$0] }
        return OverlayScrollingLyricRow.Spec(
            lineKey: "\(spec.lineKey)#\(index)",
            words: words,
            groups: groups,
            romaGap: spec.romaGap,
            font: spec.font,
            romaFont: spec.romaFont,
            baseColor: spec.baseColor,
            fillColor: spec.fillColor,
            romaBaseColor: spec.romaBaseColor,
            romaFillColor: spec.romaFillColor,
            strokeColor: spec.strokeColor,
            alignment: .leading,
            paused: spec.paused,
            timingEpoch: spec.timingEpoch,
            rate: spec.rate)
    }
}

/// 交给出图队列的一句(几行的排版和规格)。里面的 NSFont / NSColor 是不可变对象,只读不写。
private struct RowRasterBatch: @unchecked Sendable {
    var items: [(OverlayRowGeometry, OverlayScrollingLyricRow.Spec)]
}

/// 出图队列画好的几行。
private struct RowRasterResult: @unchecked Sendable {
    var images: [OverlayRowImages]
}

/// 出图任务对行视图的弱引用,只在主线程上解引用。
private final class WeakRowsView: @unchecked Sendable {
    weak var view: WrappedKaraokeRowsView?
    init(_ view: WrappedKaraokeRowsView) { self.view = view }
}
