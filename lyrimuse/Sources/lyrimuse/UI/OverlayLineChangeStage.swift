import AppKit
import LyrimuseCore
import QuartzCore
import SwiftUI

/// 换句动画开着时卡片里的两格(这一句 / 下一句)。每一格的内容放进自己的托管视图,换句时 SwiftUI 一次摆好终态;
/// 新主句从上一拍下一句的位置走上来、旧的一句原地淡出、新的下一句后半程淡入,都由这里装 Core Animation 动画,
/// 装好之后主线程不按帧参与。别改回 SwiftUI 的 `matchedGeometryEffect` / `transition`:那条每一帧都要整张卡片
/// 过一遍更新、布局、重画描边(见 04 章决策 52、54)。
///
/// 格子里各行照常上报文字矩形。命名坐标空间和偏好都不跨托管视图:`LyricsOverlayView` 在每一格根部把它们接住、
/// 清零,交给 `OverlayLineChangeReports`,这里按每一格的位置换算成舞台坐标,外层再按舞台的位置统一发出。
struct OverlayLineChangeStage: NSViewRepresentable {
    struct Slot {
        var id: String
        /// 这一格内容的横向对齐;新主句以终点那一格顶边上的这一点为中心放大。
        var alignment: HorizontalAlignment
        var content: AnyView
        /// 这一句那一格:主句下面的读音、译文,单独放一个托管视图。走上来时跟主句同一个变换,另外从透明渐显 ——
        /// 它起步时落在上一拍下一句的下面,常在窗口底边以外,整块实着走会先露出被裁掉的半截。
        var tail: AnyView? = nil
        /// 下一句那一格:读音、译文是不是跟着它一起显示着(前奏 / 间奏时)。这样的格子接上来,读音、译文本来就看得见,
        /// 不再渐显。
        var carriesAnnotations = false
    }

    let main: Slot
    let next: Slot
    /// 下一句那一格的顶边离上一格底边多远。
    let spacing: CGFloat
    /// 这一拍下一句那一行:显示着就是它的编号(没显示为 nil),和它字号相对主句的比例。下一拍新主句跟它同号时
    /// 从这个比例放大回 1,否则原地淡入。
    let nextRowID: String?
    let nextRowScale: CGFloat
    let reports: OverlayLineChangeReports
    /// 舞台叫 `requestLayout` 时外层换一个值:换句时撑住的高度到点放开,要外层重算一次,SwiftUI 才会重新量尺寸。
    let layoutTick: Int
    let requestLayout: () -> Void

    func makeNSView(context: Context) -> OverlayLineChangeStageView { OverlayLineChangeStageView() }

    func updateNSView(_ view: OverlayLineChangeStageView, context: Context) {
        view.reports = reports
        view.requestLayout = requestLayout
        view.update(main: main, next: next, spacing: spacing, nextRowID: nextRowID, nextRowScale: nextRowScale)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OverlayLineChangeStageView, context: Context) -> CGSize? {
        nsView.fittingSize(width: proposal.width)
    }

    static func dismantleNSView(_ view: OverlayLineChangeStageView, coordinator: ()) {
        view.tearDown()
    }
}

/// 两格里各行上报的矩形(格子自己的坐标),按每一格在舞台里的位置换算、合并后发布。只算眼下这两格,退场中的格子不算。
/// 发布挪到下一圈运行循环:上报来自格子那份视图图的更新过程,当场发布会落进外层的更新里。
@MainActor
final class OverlayLineChangeReports: ObservableObject {
    /// 文字矩形的并集(舞台坐标),没有为 `.zero`。
    @Published private(set) var textRect: CGRect = .zero
    /// 各行的矩形(舞台坐标),设置页编辑台用。
    @Published private(set) var rowRects: [OverlayContentRow: CGRect] = [:]

    private var slotText: [String: CGRect] = [:]
    private var slotRows: [String: [OverlayContentRow: CGRect]] = [:]
    private var origins: [String: CGPoint] = [:]
    private var scheduled = false

    func setText(_ rect: CGRect, slot: String) {
        guard slotText[slot] != rect else { return }
        slotText[slot] = rect
        schedule()
    }

    func setRows(_ rows: [OverlayContentRow: CGRect], slot: String) {
        guard slotRows[slot] != rows else { return }
        slotRows[slot] = rows
        schedule()
    }

    /// 眼下两格的编号和左上角(舞台坐标)。不在这里头的格子(已退场)的上报一并丢掉。
    func setOrigins(_ current: [String: CGPoint]) {
        guard current != origins else { return }
        origins = current
        slotText = slotText.filter { current[$0.key] != nil }
        slotRows = slotRows.filter { current[$0.key] != nil }
        schedule()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    private func publish() {
        scheduled = false
        var text = CGRect.zero
        var rows: [OverlayContentRow: CGRect] = [:]
        for (slot, origin) in origins {
            if let r = slotText[slot], r.width > 0, r.height > 0 {
                let moved = r.offsetBy(dx: origin.x, dy: origin.y)
                text = text == .zero ? moved : text.union(moved)
            }
            for (row, r) in slotRows[slot] ?? [:] {
                let moved = r.offsetBy(dx: origin.x, dy: origin.y)
                rows[row] = rows[row].map { $0.union(moved) } ?? moved
            }
        }
        if text != textRect { textRect = text }
        if rows != rowRects { rowRects = rows }
    }
}

@MainActor
final class OverlayLineChangeStageView: NSView {
    /// 一格:编号、托管控制器、横向对齐。高度按宽度缓存,内容一换就清。
    @MainActor
    private final class Cell {
        let id: String
        let host: NSHostingController<AnyView>
        /// 主句下面的读音、译文(只有这一句那一格有),摆在 `host` 正下方。
        private(set) var tailHost: NSHostingController<AnyView>?
        var alignment: HorizontalAlignment
        var carriesAnnotations: Bool
        private var heights: [CGFloat: CGFloat] = [:]
        private var tailHeights: [CGFloat: CGFloat] = [:]

        init(_ slot: OverlayLineChangeStage.Slot) {
            id = slot.id
            alignment = slot.alignment
            carriesAnnotations = slot.carriesAnnotations
            host = NSHostingController(rootView: Self.root(slot.content, slot.alignment))
            host.sizingOptions = []
            if let tail = slot.tail { tailHost = Self.makeHost(Self.root(tail, slot.alignment)) }
        }

        var view: NSView { host.view }
        var tailView: NSView? { tailHost?.view }
        /// 读音、译文那一块上报矩形用的编号。
        var tailID: String { id + "#tail" }

        func update(_ slot: OverlayLineChangeStage.Slot) {
            alignment = slot.alignment
            carriesAnnotations = slot.carriesAnnotations
            host.rootView = Self.root(slot.content, slot.alignment)
            heights.removeAll()
            tailHeights.removeAll()
            if let tail = slot.tail {
                if let tailHost {
                    tailHost.rootView = Self.root(tail, slot.alignment)
                } else {
                    let made = Self.makeHost(Self.root(tail, slot.alignment))
                    tailHost = made
                    host.view.superview?.addSubview(made.view)
                }
            } else if let tailHost {
                tailHost.view.removeFromSuperview()
                self.tailHost = nil
            }
        }

        func height(width: CGFloat) -> CGFloat {
            if let h = heights[width] { return h }
            let h = host.sizeThatFits(in: CGSize(width: width, height: 100_000)).height
            heights[width] = h
            return h
        }

        func tailHeight(width: CGFloat) -> CGFloat {
            guard let tailHost else { return 0 }
            if let h = tailHeights[width] { return h }
            let h = tailHost.sizeThatFits(in: CGSize(width: width, height: 100_000)).height
            tailHeights[width] = h
            return h
        }

        private static func makeHost(_ root: AnyView) -> NSHostingController<AnyView> {
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            host.view.wantsLayer = true
            return host
        }

        private static func root(_ content: AnyView, _ alignment: HorizontalAlignment) -> AnyView {
            AnyView(content.frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top)))
        }
    }

    /// 换句那一拍排好版之后要装的进场动画。
    private enum Entry {
        /// 从上一拍下一句那一格(`from`,舞台坐标)按它的字号比例起步,走上来、放大到位。`tailFades`:读音、译文从透明渐显
        /// (上一拍下一句那一格没带着它们时)。`ghost`:上一拍下一句那一格(预览样式),跟新主句走同一条路、同时淡出,
        /// 新主句同时淡入 —— 两份在同一处交叉淡化,这一句的样子在路上从预览变成主句,起步那一帧不会原地变粗变亮。
        case rise(from: CGRect, scale: CGFloat, tailFades: Bool, ghost: Cell)
        /// 原地淡入(跳句、拖进度、换歌、没开下一句)。
        case fade
    }

    var reports: OverlayLineChangeReports?
    var requestLayout: (() -> Void)?

    private var main: Cell?
    private var next: Cell?
    private var spacing: CGFloat = 0
    private var lastNextRow: (id: String?, scale: CGFloat, carriesAnnotations: Bool) = (nil, 1, false)
    private var pendingEntry: Entry?
    private var pendingLateIn = false
    /// 正在淡出、淡完就拆的旧格子。
    private var retiring: [NSView] = []
    /// 跟着新主句走、正在淡出的上一拍下一句那一格,走完就拆。留着格子本身,托管控制器在它淡完之前别先释放。
    private var ghosts: [Cell] = []
    /// 换句前的高度:比换句后高时撑住到新主句走完,不然窗口先变矮、走上来的那一句起步时被下沿裁掉。
    private var heldHeight: CGFloat?
    private var holdGeneration = 0
    private var lastWidth: CGFloat = 0

    private static let riseCurve = CAMediaTimingFunction(
        controlPoints: OverlayLineRise.curve.x1, OverlayLineRise.curve.y1, OverlayLineRise.curve.x2, OverlayLineRise.curve.y2)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// 不接鼠标:悬浮窗的命中全由控制器按上报的矩形自己判。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(main m: OverlayLineChangeStage.Slot, next n: OverlayLineChangeStage.Slot, spacing: CGFloat,
                nextRowID: String?, nextRowScale: CGFloat) {
        let firstUpdate = main == nil
        let heightBefore = lastWidth > 0 && !firstUpdate ? contentHeight(width: lastWidth) : nil
        self.spacing = spacing
        if let cell = main, cell.id == m.id {
            cell.update(m)
        } else {
            if let old = main {
                // 上一次换句的动画还没装上又换了一句:那一次要跟着走的格子没人拆了,这里拆掉。
                if case .rise(_, _, _, let stale)? = pendingEntry { stale.view.removeFromSuperview() }
                if lastNextRow.id == m.id, let oldNext = next, oldNext.id == m.id {
                    pendingEntry = .rise(from: oldNext.view.frame, scale: lastNextRow.scale,
                                         tailFades: !lastNextRow.carriesAnnotations, ghost: oldNext)
                } else {
                    pendingEntry = .fade
                }
                retire(old)
                if let heightBefore { hold(heightBefore) }
            }
            main = install(m)
        }
        if let cell = next, cell.id == n.id {
            cell.update(n)
        } else {
            // 旧的下一句当场收掉(要跟着新主句走的那一格除外),新的等走上来的那一句到位、后半程才淡入。
            if let old = next, !Self.isGhost(old, of: pendingEntry) { old.view.removeFromSuperview() }
            next = install(n)
            pendingLateIn = !firstUpdate
        }
        lastNextRow = (nextRowID, nextRowScale, n.carriesAnnotations)
        needsLayout = true
    }

    func fittingSize(width proposed: CGFloat?) -> CGSize? {
        let width: CGFloat
        if let proposed, proposed.isFinite {
            width = proposed
        } else if lastWidth > 0 {
            width = lastWidth
        } else {
            return nil
        }
        return CGSize(width: width, height: max(contentHeight(width: width), heldHeight ?? 0))
    }

    func tearDown() {
        holdGeneration += 1
        for view in retiring { view.removeFromSuperview() }
        retiring.removeAll()
        for ghost in ghosts { ghost.view.removeFromSuperview() }
        ghosts.removeAll()
        main?.view.removeFromSuperview()
        main?.tailView?.removeFromSuperview()
        next?.view.removeFromSuperview()
        main = nil
        next = nil
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        lastWidth = width
        let mainHeight = main?.height(width: width) ?? 0
        let tailHeight = main?.tailHeight(width: width) ?? 0
        let mainFrame = CGRect(x: 0, y: 0, width: width, height: mainHeight)
        let tailFrame = CGRect(x: 0, y: mainHeight, width: width, height: tailHeight)
        let nextFrame = CGRect(x: 0, y: mainHeight + tailHeight + spacing, width: width, height: next?.height(width: width) ?? 0)
        if let main, main.view.frame != mainFrame { main.view.frame = mainFrame }
        if let tail = main?.tailView, tail.frame != tailFrame { tail.frame = tailFrame }
        if let next, next.view.frame != nextFrame { next.view.frame = nextFrame }
        var origins: [String: CGPoint] = [:]
        if let main {
            origins[main.id] = mainFrame.origin
            if main.tailView != nil { origins[main.tailID] = tailFrame.origin }
        }
        if let next { origins[next.id] = nextFrame.origin }
        reports?.setOrigins(origins)
        installEntry(mainFrame: mainFrame)
    }

    private func contentHeight(width: CGFloat) -> CGFloat {
        (main?.height(width: width) ?? 0) + (main?.tailHeight(width: width) ?? 0) + spacing + (next?.height(width: width) ?? 0)
    }

    private func install(_ slot: OverlayLineChangeStage.Slot) -> Cell {
        let cell = Cell(slot)
        cell.view.wantsLayer = true
        addSubview(cell.view)
        if let tail = cell.tailView { addSubview(tail) }
        return cell
    }

    /// 旧的一句(连同读音、译文)原地淡完再拆。
    private func retire(_ cell: Cell) {
        retire(view: cell.view)
        if let tail = cell.tailView { retire(view: tail) }
    }

    private func retire(view: NSView) {
        view.alphaValue = 0
        view.layer?.add(Self.fade(from: 1, to: 0, duration: OverlayLineRise.fadeOutDuration,
                                  curve: CAMediaTimingFunction(name: .easeOut)), forKey: "lineFadeOut")
        retiring.append(view)
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayLineRise.fadeOutDuration) { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let view else { return }
                view.removeFromSuperview()
                self?.retiring.removeAll { $0 === view }
            }
        }
    }

    /// 撑住换句前的高度,新主句走完之后放开,再请外层重算一次。
    private func hold(_ height: CGFloat) {
        heldHeight = max(heldHeight ?? 0, height)
        holdGeneration += 1
        let generation = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayLineRise.duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.holdGeneration == generation, self.heldHeight != nil else { return }
                self.heldHeight = nil
                self.invalidateIntrinsicContentSize()
                self.requestLayout?()
            }
        }
    }

    private func installEntry(mainFrame: CGRect) {
        if let entry = pendingEntry, let main, let layer = main.view.layer {
            pendingEntry = nil
            // 格子图层挂在舞台自己的图层下(刚加进来的格子这一刻可能还没挂上),舞台图层跟舞台视图一样上下翻转时,
            // 舞台视图坐标就是格子 `position` 所在的坐标系。没翻转时坐标对不上,退回原地淡入,别按错的起点走。
            let flipped = self.layer?.isGeometryFlipped == true
            let tailLayer = main.tailView?.layer
            switch entry {
            case .rise(let from, let scale, let tailFades, let ghost) where flipped:
                // 主句和下面的读音、译文是同一个变换:以终点那一格顶边上按对齐取的一点为中心缩放、整体挪到上一拍下一句那里。
                let anchor = CGPoint(x: mainFrame.minX + mainFrame.width * Self.anchorFraction(main.alignment), y: mainFrame.minY)
                let offset = CGVector(dx: 0, dy: from.minY - mainFrame.minY)
                layer.add(Self.fade(from: 0, to: 1, duration: OverlayLineRise.crossfadeDuration, curve: Self.riseCurve),
                          forKey: "lineCrossfadeIn")
                accompany(ghost, from: from, to: mainFrame, scale: scale)
                for target in [layer, tailLayer].compactMap({ $0 }) {
                    let start = OverlayLineRise.startTransform(scale: scale, anchor: anchor, position: target.position,
                                                               offset: offset)
                    let rise = CABasicAnimation(keyPath: "transform")
                    rise.fromValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(start))
                    rise.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                    rise.duration = OverlayLineRise.duration
                    rise.timingFunction = Self.riseCurve
                    target.add(rise, forKey: "lineRise")
                }
                if tailFades, let tailLayer {
                    tailLayer.add(Self.fade(from: 0, to: 1, duration: OverlayLineRise.tailFadeInDuration, curve: Self.riseCurve),
                                  forKey: "lineTailFadeIn")
                }
            case .rise(_, _, _, let ghost):
                ghost.view.removeFromSuperview()
                for target in [layer, tailLayer].compactMap({ $0 }) {
                    target.add(Self.fade(from: 0, to: 1, duration: OverlayLineRise.duration, curve: Self.riseCurve),
                               forKey: "lineFadeIn")
                }
            case .fade:
                for target in [layer, tailLayer].compactMap({ $0 }) {
                    target.add(Self.fade(from: 0, to: 1, duration: OverlayLineRise.duration, curve: Self.riseCurve),
                               forKey: "lineFadeIn")
                }
            }
        }
        if pendingLateIn, let next, let layer = next.view.layer {
            pendingLateIn = false
            let lateIn = Self.fade(from: 0, to: 1, duration: OverlayLineRise.lateInDuration,
                                   curve: CAMediaTimingFunction(name: .easeOut))
            lateIn.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + OverlayLineRise.lateInDelay
            lateIn.fillMode = .backwards
            layer.add(lateIn, forKey: "lineLateIn")
        }
    }

    /// 上一拍下一句那一格跟着新主句走:从它自己的位置走到新主句终点那一格、按字号比例的倒数放大(跟新主句起步的变换
    /// 正好互逆),同时淡出,走完拆掉。
    private func accompany(_ ghost: Cell, from: CGRect, to mainFrame: CGRect, scale: CGFloat) {
        guard let layer = ghost.view.layer, scale > 0 else {
            ghost.view.removeFromSuperview()
            return
        }
        let anchor = CGPoint(x: from.minX + from.width * Self.anchorFraction(ghost.alignment), y: from.minY)
        let end = OverlayLineRise.startTransform(scale: 1 / scale, anchor: anchor, position: layer.position,
                                                 offset: CGVector(dx: 0, dy: mainFrame.minY - from.minY))
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        move.toValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(end))
        move.duration = OverlayLineRise.duration
        move.timingFunction = Self.riseCurve
        layer.transform = CATransform3DMakeAffineTransform(end)
        layer.add(move, forKey: "lineAccompany")
        ghost.view.alphaValue = 0
        layer.add(Self.fade(from: 1, to: 0, duration: OverlayLineRise.crossfadeDuration, curve: Self.riseCurve),
                  forKey: "lineCrossfadeOut")
        ghosts.append(ghost)
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayLineRise.duration) { [weak self] in
            MainActor.assumeIsolated {
                ghost.view.removeFromSuperview()
                self?.ghosts.removeAll { $0 === ghost }
            }
        }
    }

    private static func isGhost(_ cell: Cell, of entry: Entry?) -> Bool {
        if case .rise(_, _, _, let ghost)? = entry { return ghost === cell }
        return false
    }

    private static func anchorFraction(_ alignment: HorizontalAlignment) -> CGFloat {
        switch alignment {
        case .leading: return 0
        case .trailing: return 1
        default: return 0.5
        }
    }

    private static func fade(from: Float, to: Float, duration: Double, curve: CAMediaTimingFunction) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = curve
        return fade
    }
}
