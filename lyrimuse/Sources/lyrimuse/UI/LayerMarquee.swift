import AppKit
import LyrimuseCore
import QuartzCore
import SwiftUI

/// 图层版跑马灯:内容放进一个独立的 `NSHostingView`,只在内容换了时重排;滚动和右端渐隐各是一条重复播放的
/// `CAKeyframeAnimation`,装好之后由渲染服务播,主线程不参与(同 `LayerFloating`)。节奏、右端渐隐、「装得下就不动」
/// 都同 `MarqueeText`,左端渐隐随滚动长出来(07 章决策 114);周期见 `MarqueeCycle`。别换回 `MarqueeText`:进程里有 SwiftUI `ScrollView` 时,SwiftUI 的
/// 逐帧动画每帧要完整渲染两次(07 章决策 99)。
///
/// 滚动挪的是内层 `scroller` 图层的 `sublayerTransform`,内容视图本身没动,AppKit 的命中还在原位;渐隐遮罩挂在外层
/// 本视图的图层上。两样别挂在同一个图层:`sublayerTransform` 连遮罩一起挪,渐隐带跟着文字走,文字滑出左边界、
/// 左端也不淡出(07 章决策 113)。`pausesOnHover` 开着时,光标一进这一块就停住、把此刻的偏移落成内容视图的真实位置,
/// 里面能点的东西才点得准;光标离开后从停住的地方接着滚。
struct LayerMarquee<Content: View>: NSViewRepresentable {
    /// 内容身份,变了就从头滚(同 `MarqueeText.id`)。
    let id: AnyHashable
    /// 右端渐隐带的满宽:装不下、停在开头时给,滚起来线性收到 0(同 `MarqueeText.edgeFadeWidth`)。
    var edgeFadeWidth: CGFloat = 0
    /// 左端渐隐带的满宽:停在开头时不淡(第一个字贴着左缘),滚出去多远淡多宽、到这个宽度封顶(`MarqueeCycle.leadingFade`)。
    var leadingFadeWidth: CGFloat = 0
    /// false = 不滚、停在开头;变回 true 时从头来一遍。宿主传「这块此刻看不看得见」。
    var isActive: Bool = true
    /// 光标停在这一块上时暂停滚动,给里面有可点内容的行用。
    var pausesOnHover: Bool = false
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LayerMarqueeNSView { LayerMarqueeNSView() }

    func updateNSView(_ view: LayerMarqueeNSView, context: Context) {
        view.update(rootView: AnyView(content().fixedSize(horizontal: true, vertical: false)),
                    id: id, edgeFadeWidth: edgeFadeWidth, leadingFadeWidth: leadingFadeWidth,
                    animating: isActive && !reduceMotion, pausesOnHover: pausesOnHover)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerMarqueeNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.contentSize.width,
               height: proposal.height ?? nsView.contentSize.height)
    }
}

/// 上面那块的宿主:内容视图(挂在内层 `scroller` 里)+ 渐隐遮罩 + 两条动画。
@MainActor
final class LayerMarqueeNSView: NSView {
    private static let scrollKey = "lyrimuse.layer-marquee-scroll"
    private static let fadeKey = "lyrimuse.layer-marquee-fade"
    private static let scrollKeyPath = "sublayerTransform.translation.x"

    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    /// 内容视图的父视图,跟本视图一样大:滚动动画挂在它的图层上,遮罩不在这一层。
    private let scroller = NSView()
    /// 遮罩四个色标:透明 → 左端渐隐 → 不透明 → 右端渐隐 → 透明;两端渐隐带的宽度都跟着滚动动画走。
    private let fadeMask = CAGradientLayer()
    private var id: AnyHashable?
    private var edgeFadeWidth: CGFloat = 0
    private var leadingFadeWidth: CGFloat = 0
    private var animating = false
    private var pausesOnHover = false
    /// 内容的固有尺寸(点)。
    private(set) var contentSize: CGSize = .zero
    /// 周期和遮罩是按这个宽度排的;宽度变了要重排。
    private var laidOutWidth: CGFloat = -1
    /// 正在用的周期;nil = 装得下。
    private var cycle: MarqueeCycle?
    /// 光标停在上面、滚动停住时的偏移;nil = 没停。
    private var frozenOffset: CGFloat?
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scroller.wantsLayer = true
        addSubview(scroller)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        scroller.addSubview(hosting)
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.actions = ["locations": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.mask = fadeMask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(rootView: AnyView, id: AnyHashable, edgeFadeWidth: CGFloat, leadingFadeWidth: CGFloat,
                animating: Bool, pausesOnHover: Bool) {
        hosting.rootView = rootView
        let idChanged = id != self.id
        let changed = idChanged || edgeFadeWidth != self.edgeFadeWidth || leadingFadeWidth != self.leadingFadeWidth
            || animating != self.animating || pausesOnHover != self.pausesOnHover
        self.id = id
        self.edgeFadeWidth = edgeFadeWidth
        self.leadingFadeWidth = leadingFadeWidth
        self.animating = animating
        if pausesOnHover != self.pausesOnHover {
            self.pausesOnHover = pausesOnHover
            updateTrackingAreas()
        }
        if idChanged || contentSize == .zero { contentSize = hosting.fittingSize }
        if changed { restart() }
    }

    override func layout() {
        super.layout()
        if scroller.frame != bounds { scroller.frame = bounds }
        if abs(bounds.width - laidOutWidth) > 0.5 {
            restart()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        placeHosting(offset: frozenOffset ?? 0)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        contentSize = hosting.fittingSize
        restart()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard pausesOnHover else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        freeze()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        resume()
    }

    /// 从头来一遍:撤掉动画、内容回到开头;该滚就从首轮起点装上。
    private func restart() {
        laidOutWidth = bounds.width
        frozenOffset = nil
        cycle = MarqueeMath.cycle(contentWidth: contentSize.width, containerWidth: bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if scroller.frame != bounds { scroller.frame = bounds }
        scroller.layer?.removeAnimation(forKey: Self.scrollKey)
        fadeMask.removeAnimation(forKey: Self.fadeKey)
        fadeMask.frame = bounds
        fadeMask.locations = maskLocations(leading: 0, trailing: restingFade)
        placeHosting(offset: 0)
        CATransaction.commit()
        guard animating, let cycle, window != nil else { return }
        if pausesOnHover, hovering {
            frozenOffset = 0
            return
        }
        install(cycle, from: cycle.firstCycleTimeOffset)
    }

    /// 停在此刻屏幕上的位置,并把偏移落成内容视图的真实位置。
    private func freeze() {
        guard pausesOnHover, frozenOffset == nil, let cycle,
              scroller.layer?.animation(forKey: Self.scrollKey) != nil else { return }
        let shown = (scroller.layer?.presentation()?.value(forKeyPath: Self.scrollKeyPath) as? NSNumber)?.doubleValue ?? 0
        let offset = min(max(CGFloat(-shown), 0), cycle.distance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scroller.layer?.removeAnimation(forKey: Self.scrollKey)
        fadeMask.removeAnimation(forKey: Self.fadeKey)
        fadeMask.locations = maskLocations(leading: cycle.leadingFade(forOffset: offset, full: leadingFadeWidth),
                                           trailing: cycle.trailingFade(forOffset: offset, full: restingFade))
        placeHosting(offset: offset)
        CATransaction.commit()
        frozenOffset = offset
    }

    /// 从停住的偏移接着滚。
    private func resume() {
        guard let offset = frozenOffset else { return }
        frozenOffset = nil
        guard animating, let cycle, window != nil else {
            restart()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeHosting(offset: 0)
        install(cycle, from: cycle.resumeTime(forOffset: offset))
        CATransaction.commit()
    }

    /// 两条动画同一个事务里装,开播时刻相同,滚动和渐隐对得上。
    private func install(_ cycle: MarqueeCycle, from time: Double) {
        let move = CAKeyframeAnimation(keyPath: Self.scrollKeyPath)
        move.values = cycle.offsets.map { NSNumber(value: Double(-$0)) }
        move.keyTimes = cycle.keyTimes.map { NSNumber(value: $0) }
        let fades = cycle.fadeKeyframes(leading: leadingFadeWidth, trailing: restingFade)
        let fade = CAKeyframeAnimation(keyPath: "locations")
        fade.values = zip(fades.leading, fades.trailing).map { maskLocations(leading: $0, trailing: $1) }
        fade.keyTimes = fades.keyTimes.map { NSNumber(value: $0) }
        for animation in [move, fade] {
            animation.duration = cycle.period
            animation.repeatCount = .infinity
            animation.calculationMode = .linear
            animation.timeOffset = time
            MenuBarAnimation.capped(animation, fps: MenuBarAnimation.scrollFPS)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scroller.layer?.add(move, forKey: Self.scrollKey)
        fadeMask.add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
    }

    /// 停在开头时右端渐隐带的宽度(装得下时 0)。
    private var restingFade: CGFloat {
        MarqueeMath.trailingFadeWidth(configured: edgeFadeWidth, contentWidth: contentSize.width,
                                      containerWidth: bounds.width, offset: 0)
    }

    /// 遮罩色标的位置:左端渐隐带宽 `leading`、右端宽 `trailing`(点)。
    private func maskLocations(leading: CGFloat, trailing: CGFloat) -> [NSNumber] {
        let width = max(bounds.width, 1)
        let lead = min(max(leading, 0), width) / width
        let tail = max(lead, (width - trailing) / width)
        return [0, lead, tail, 1].map { NSNumber(value: Double($0)) }
    }

    /// 内容视图摆在左端(再往左挪 `offset`)、竖直居中,对齐到设备像素。
    private func placeHosting(offset: CGFloat) {
        let height = contentSize.height
        let frame = backingAlignedRect(NSRect(x: -offset, y: (bounds.height - height) / 2,
                                              width: contentSize.width, height: height),
                                       options: .alignAllEdgesNearest)
        if hosting.frame != frame { hosting.frame = frame }
    }
}
