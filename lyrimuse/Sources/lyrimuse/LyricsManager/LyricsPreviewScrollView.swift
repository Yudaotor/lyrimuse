import AppKit
import QuartzCore
import SwiftUI

/// 预览列表要滚到哪一行。`serial` 每发一次加一:同一行再滚一次也算新请求。
struct LyricsPreviewScrollRequest: Equatable {
    enum Anchor: Equatable {
        /// 这一行滚到可视区正中。
        case center
        /// 回到最顶上(还没唱到第一句时)。
        case top
    }

    var row: Int
    var anchor: Anchor
    var animated: Bool
    var serial: Int
}

/// 歌词管理 / 搜索候选歌词那份预览的滚动容器:AppKit `NSScrollView`,文档视图里一个托管着全部行的 `QuietHostingView`。
/// 跟随播放滚到当前句:一次落到目标位置,再给 clip view 的图层挂一条从旧位置走回来的加法动画,由渲染服务播(`slide`)。
/// 别换回 SwiftUI `ScrollView` + `scrollTo`(滚动途中会掉帧,见 11 章决策 146),也别换回 clip view 的 animator:它在主线程上
/// 逐帧推,换句那一刻主线程一忙就被吃掉前半截、一下跳过去(见 11 章决策 187)。
///
/// 滑动途中 clip view 已在目标位置、图层还在路上:点击和悬停按画面位置判(`LyricsPreviewHostingView`)。
///
/// 行的位置和内容总高都由内容自己上报(`lyricsPreviewRowFrame`、`LyricsPreviewContentHeightKey`);还没量到就先记着,量到了再滚。
/// 嵌套的托管视图不继承外面的 SwiftUI 环境,行里要用的环境值由调用方挂在 `content` 上。
struct LyricsPreviewScrollView<Content: View>: NSViewRepresentable {
    var scrollRequest: LyricsPreviewScrollRequest?
    /// 顶边渐隐多高:滚上去的行在顶边淡出,不在上面那排控件底下被齐刷刷切掉。滚动条那一列不渐隐。
    var topFadeHeight: CGFloat
    /// 用户自己滚了一下(滚轮、触控板、拖滚动条);程序滚动不算。
    var onUserScroll: () -> Void
    @ViewBuilder var content: () -> Content

    static var scrollAnimationDuration: TimeInterval { 0.45 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LyricsPreviewNSScrollView {
        let coordinator = context.coordinator
        let scrollView = LyricsPreviewNSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.topFadeHeight = topFadeHeight
        let document = LyricsPreviewDocumentView()
        scrollView.documentView = document
        let host = LyricsPreviewHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        // 嵌套的托管视图别吃窗口的安全区,理由同 OverlayLineChangeStage(04 章决策 79)。
        host.safeAreaRegions = []
        document.addSubview(host)
        coordinator.scrollView = scrollView
        coordinator.document = document
        coordinator.host = host
        host.shownOffset = { [weak coordinator] in coordinator?.shownOffset() }
        host.stopSlide = { [weak coordinator] in coordinator?.cancelAnimation() }
        scrollView.onUserScroll = { [weak coordinator] in
            coordinator?.cancelAnimation()
            coordinator?.settle = nil
            coordinator?.onUserScroll()
        }
        scrollView.onLayout = { [weak coordinator] in coordinator?.relayout() }
        return scrollView
    }

    func updateNSView(_ scrollView: LyricsPreviewNSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onUserScroll = onUserScroll
        scrollView.topFadeHeight = topFadeHeight
        // 纵向按理想高度排,总高由内容自己报上来(不在这里量整份内容,见 11 章决策 187);不固定的话 VStack 每一行都要按弹性试排
        //(见 11 章决策 172)。文档视图比内容高时(新高度还没报到)内容贴顶,行的位置跟画出来的一致。
        coordinator.host?.rootView = AnyView(
            content()
                .fixedSize(horizontal: false, vertical: true)
                .coordinateSpace(name: LyricsPreviewRowFrameKey.space)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: LyricsPreviewContentHeightKey.self, value: proxy.size.height)
                })
                .onPreferenceChange(LyricsPreviewRowFrameKey.self) { [weak coordinator] frames in
                    coordinator?.rowFramesChanged(frames)
                }
                .onPreferenceChange(LyricsPreviewContentHeightKey.self) { [weak coordinator] height in
                    coordinator?.contentHeightChanged(height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        coordinator.relayout()
        if let request = scrollRequest, request.serial != coordinator.handledSerial {
            coordinator.handledSerial = request.serial
            coordinator.pending = request
            coordinator.settle = request.animated ? nil : request
            coordinator.applyPending()
        }
    }

    static func dismantleNSView(_ scrollView: LyricsPreviewNSScrollView, coordinator: Coordinator) {
        scrollView.onUserScroll = nil
        scrollView.onLayout = nil
    }

    @MainActor
    final class Coordinator {
        weak var scrollView: LyricsPreviewNSScrollView?
        weak var document: LyricsPreviewDocumentView?
        var host: LyricsPreviewHostingView?
        var onUserScroll: () -> Void = {}
        var handledSerial: Int?
        var pending: LyricsPreviewScrollRequest?
        /// 最近一次不带动画的定位(换显示档、换歌):它跟新内容同一轮到,当时用的还是旧行的位置;新行的位置送到时按它再对一次。
        /// 用户自己滚、或来了带动画的定位(换句)就作废。
        var settle: LyricsPreviewScrollRequest?
        private var rowFrames: [Int: CGRect] = [:]
        /// 内容在当前宽度下排出来的总高(内容自己报的);还没报到时 nil。
        private var contentHeight: CGFloat?
        private var laidOutWidth: CGFloat = -1
        private var laidOutHeight: CGFloat = -1

        func rowFramesChanged(_ frames: [Int: CGRect]) {
            rowFrames = frames
            if pending == nil, let settle { pending = settle }
            applyPending()
        }

        /// 行的高度变了(换显示模式、换歌、换宽度),文档视图跟着长短,再按新位置对一次。
        func contentHeightChanged(_ height: CGFloat) {
            contentHeight = height
            relayout()
            if pending == nil, let settle { pending = settle }
            applyPending()
        }

        /// 文档视图跟可视区一样宽,高度是内容报上来的总高。宽度一变内容按新宽度重排、报来新高度,再走一次这里。
        /// 滚动容器每轮布局都来调,只比尺寸、不量内容。
        func relayout() {
            guard let scrollView, let document, let host else { return }
            let width = Self.documentWidth(scrollView)
            guard width > 0 else { return }
            let height = ceil(contentHeight ?? scrollView.contentSize.height)
            guard width != laidOutWidth || height != laidOutHeight else { return }
            laidOutWidth = width
            laidOutHeight = height
            let size = CGSize(width: width, height: max(height, 1))
            if document.frame.size != size { document.setFrameSize(size) }
            if host.frame != document.bounds { host.frame = document.bounds }
        }

        /// 按「竖滚动条一直占着位置」的宽度排:传统滚动条出没会改 `contentSize.width`,按它排的话内容高度跟着变,
        /// 又决定滚动条出不出来。悬浮滚动条不占宽度,两种算法一样。
        static func documentWidth(_ scrollView: NSScrollView) -> CGFloat {
            guard scrollView.hasVerticalScroller, scrollView.scrollerStyle == .legacy else { return scrollView.contentSize.width }
            return NSScrollView.contentSize(forFrameSize: scrollView.frame.size, horizontalScrollerClass: nil,
                                            verticalScrollerClass: NSScroller.self, borderType: scrollView.borderType,
                                            controlSize: .regular, scrollerStyle: .legacy).width
        }

        func applyPending() {
            guard let request = pending, let scrollView else { return }
            let clip = scrollView.contentView
            let target: CGFloat
            switch request.anchor {
            case .top:
                target = 0
            case .center:
                guard let frame = rowFrames[request.row] else { return }
                target = frame.midY - clip.bounds.height / 2
            }
            pending = nil
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let origin = NSPoint(x: 0, y: min(max(0, target.rounded()), maxY))
            guard origin != clip.bounds.origin else { return }
            let animated = request.animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            // 从此刻画在屏上的位置起滑:上一段还没走完时接着走,不先跳回它的终点。
            let shown = animated ? shownOriginY(clip) : clip.bounds.origin.y
            cancelAnimation()
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            if animated { slide(clip, by: shown - origin.y) }
            if DebugDeepLinks.isEnabled, animated, let probe = LyricsPreviewClickProbe.take() {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(probe.delayMs)) { [weak self] in
                    self?.probeClick(dy: probe.dy)
                }
            }
        }

        /// 画面位置减落点位置(文档坐标,向下为正):滑动还在走时非 nil。
        func shownOffset() -> CGFloat? {
            guard let scrollView, let layer = scrollView.contentView.layer,
                  layer.animation(forKey: Self.slideKey) != nil else { return nil }
            let clip = scrollView.contentView
            let offset = shownOriginY(clip) - clip.bounds.origin.y
            return abs(offset) < 0.5 ? nil : offset
        }

        /// `debug/preview-click`:往可视区正中(加 `dy`)此刻画着的那一行的时间按钮点一下,跟真点击同一条路
        /// (按窗口命中、交给命中的视图按下再松开),记下画面上是哪一行、按落点算是哪一行、命中了谁。
        private func probeClick(dy: CGFloat) {
            guard let scrollView, let window = scrollView.window, let host, var top = window.contentView else { return }
            while let parent = top.superview { top = parent }
            let clip = scrollView.contentView
            let target = clip.bounds.origin.y
            let shown = shownOriginY(clip)
            let probeY = clip.bounds.height / 2 + dy
            // 行间空白算上面那一行。
            func row(at y: CGFloat) -> Int? { rowFrames.filter { $0.value.minY <= y }.max { $0.value.minY < $1.value.minY }?.key }
            guard let drawnRow = row(at: shown + probeY), let frame = rowFrames[drawnRow] else {
                LyricsPreviewClickProbe.finish(["error": "no row at probe point"])
                return
            }
            // 时间按钮在行首那一栏、靠右排(`LyricsCompareLayout.timeWidth`),点在字上;纵向点在第一行字的中间。
            let drawnY = frame.minY + 10
            let docPoint = NSPoint(x: frame.minX + LyricsCompareLayout.timeWidth - 20, y: drawnY - shown + target)
            let windowPoint = host.convert(docPoint, to: nil)
            let modelRow = row(at: docPoint.y)
            let hit = top.hitTest(windowPoint)
            let report: [String: Any] = [
                "sliding": abs(shown - target) >= 0.5, "shownY": shown, "targetY": target,
                "drawnRow": drawnRow, "modelRow": modelRow.map { $0 as Any } ?? NSNull(),
                "hitView": hit.map { String(describing: type(of: $0)) } ?? "nil",
            ]
            LyricsPreviewClickProbe.seekedRow = nil
            if let hit {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                    if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let seeked: Any = LyricsPreviewClickProbe.seekedRow.map { $0 as Any } ?? NSNull()
                LyricsPreviewClickProbe.finish(report.merging(["seekedRow": seeked]) { $1 })
            }
        }

        /// clip view 的图层此刻画在屏上的滚动位置(滑动动画走到哪了);图层的 bounds 原点就是 clip view 的 bounds 原点。
        private func shownOriginY(_ clip: NSClipView) -> CGFloat {
            clip.layer?.presentation()?.bounds.origin.y ?? clip.bounds.origin.y
        }

        /// 已经落到目标位置的 clip view 挂一条加法动画:从差 `delta` 的地方走回 0,时长和曲线不变。起步时刻是这一轮提交那一刻,
        /// 之后主线程再卡也不影响,渲染服务逐帧插值。
        private func slide(_ clip: NSClipView, by delta: CGFloat) {
            guard let layer = clip.layer, abs(delta) > 0.5 else { return }
            let animation = CABasicAnimation(keyPath: "bounds.origin.y")
            animation.isAdditive = true
            animation.fromValue = delta
            animation.toValue = 0
            animation.duration = LyricsPreviewScrollView.scrollAnimationDuration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            animation.fillMode = .backwards
            layer.add(animation, forKey: Self.slideKey)
        }

        private static var slideKey: String { "lyricsPreviewSlide" }

        /// 停掉正在走的程序滚动:用户一动手就以他为准,别跟动画抢。停在此刻画在屏上的位置,不跳到终点。
        func cancelAnimation() {
            guard let scrollView, let layer = scrollView.contentView.layer,
                  layer.animation(forKey: Self.slideKey) != nil else { return }
            let clip = scrollView.contentView
            let shown = shownOriginY(clip)
            layer.removeAnimation(forKey: Self.slideKey)
            clip.scroll(to: NSPoint(x: 0, y: shown.rounded()))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

/// 预览的内容宿主。换句滚动时 clip view 先落到目标位置、图层再从旧位置滑过来(`slide`),那 0.45 秒里
/// 画面和点击判定差一个滑动量:按下鼠标先把滑动停在画面所在处再往下交(命中的就是画面上那一句,按住时它也不再挪),
/// 指针移动按画面位置换算后交给 SwiftUI(悬停标记画在指针底下那一行)。只挪事件、不碰滑动本身,见 11 章决策 189。
final class LyricsPreviewHostingView: QuietHostingView<AnyView> {
    /// 画面位置减落点位置(文档坐标,向下为正);没在滑为 nil。
    var shownOffset: () -> CGFloat? = { nil }
    /// 把还在走的滑动停在画面所在处。
    var stopSlide: () -> Void = {}
    /// 这次滑动里按画面位置换算过悬停:滑完按真实位置再对一次,指针不动时悬停也落到停稳后指针底下那一行。
    private var hoverResyncPending = false

    override func mouseDown(with event: NSEvent) {
        stopSlide()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        stopSlide()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        stopSlide()
        super.otherMouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let offset = shownOffset(), let shifted = Self.shifted(event, by: offset, in: self) else {
            super.mouseMoved(with: event)
            return
        }
        super.mouseMoved(with: shifted)
        guard !hoverResyncPending else { return }
        hoverResyncPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + LyricsPreviewScrollView<EmptyView>.scrollAnimationDuration) { [weak self] in
            self?.resyncHover()
        }
    }

    private func resyncHover() {
        hoverResyncPending = false
        guard let window, shownOffset() == nil else { return }
        let point = window.mouseLocationOutsideOfEventStream
        guard visibleRect.contains(convert(point, from: nil)),
              let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 0, pressure: 0) else { return }
        super.mouseMoved(with: event)
    }

    /// 同一个事件挪到画面上那一点:文档坐标里纵向加 `offset`。
    static func shifted(_ event: NSEvent, by offset: CGFloat, in view: NSView) -> NSEvent? {
        var point = view.convert(event.locationInWindow, from: nil)
        point.y += view.isFlipped ? offset : -offset
        return NSEvent.mouseEvent(with: event.type, location: view.convert(point, to: nil), modifierFlags: event.modifierFlags,
                                  timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                  eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)
    }
}

/// `debug/preview-click` 的一次性请求和结果:下一次跟随滑动开始 `delayMs` 毫秒后点一下(`probeClick`),结果写进
/// `preview-click.json`。只在调试深链开着时用。
@MainActor
enum LyricsPreviewClickProbe {
    struct Request {
        var delayMs: Int
        var dy: CGFloat
    }

    private static var pending: Request?
    /// 预览的时间按钮最近一次跳到第几行(`LyricsManagerPreviewList` 报)。
    static var seekedRow: Int?

    static func arm(delayMs: Int, dy: CGFloat) {
        pending = Request(delayMs: delayMs, dy: dy)
    }

    static func take() -> Request? {
        defer { pending = nil }
        return pending
    }

    static func finish(_ report: [String: Any]) {
        DebugDeepLinks.writeJSON(report, name: "preview-click.json")
    }
}

/// 预览内容的总高,文档视图按它定高。
struct LyricsPreviewContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 嵌在别的 SwiftUI 窗口里的托管视图:自己刷新时不置 `needsUpdateConstraints`。NSHostingView 每次刷新都置它,
/// 这一下沿父视图一路报到窗口根的 SwiftUI 宿主,整扇窗跟着重排、重算最小尺寸(逐字染色每帧一次就是整窗每帧重排)。
/// 只给 `sizingOptions = []`、尺寸由外面定的宿主用:约束那一趟对它没有活可干,刷新照样走 layout。见 11 章决策 187。
class QuietHostingView<Content: View>: NSHostingView<Content> {
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set { if !newValue { super.needsUpdateConstraints = false } }
    }
}

/// 预览里每一行在内容里的位置(按行号),滚到当前句用。
struct LyricsPreviewRowFrameKey: PreferenceKey {
    static let space = "lyricsPreviewContent"
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// 把这一行在预览内容里的位置报给 `LyricsPreviewScrollView`。
    func lyricsPreviewRowFrame(_ index: Int) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: LyricsPreviewRowFrameKey.self,
                                   value: [index: proxy.frame(in: .named(LyricsPreviewRowFrameKey.space))])
        })
    }
}

final class LyricsPreviewDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// 认得出用户自己滚动的 `NSScrollView`;顶边渐隐是一层图层蒙版,滚动条那一列不蒙。
final class LyricsPreviewNSScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    var onLayout: (() -> Void)?
    var topFadeHeight: CGFloat = 0 {
        didSet { if topFadeHeight != oldValue { needsLayout = true } }
    }

    private let fadeMask = CALayer()
    private let fadeGradient = CAGradientLayer()
    private let fadeBody = CALayer()
    private let scrollerColumn = CALayer()
    private var liveScrollObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fadeGradient.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        fadeGradient.startPoint = CGPoint(x: 0.5, y: 0)
        fadeGradient.endPoint = CGPoint(x: 0.5, y: 1)
        fadeBody.backgroundColor = NSColor.black.cgColor
        scrollerColumn.backgroundColor = NSColor.black.cgColor
        for layer in [fadeGradient, fadeBody, scrollerColumn] { fadeMask.addSublayer(layer) }
        // 拖滚动条也算用户在滚。
        liveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onUserScroll?() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
    }

    override func scrollWheel(with event: NSEvent) {
        // 只认用户手上在滚的那几下:触控板松手后的惯性(momentumPhase 非空)不算,老式滚轮 phase 为空也算。
        if event.momentumPhase.isEmpty, event.phase.isEmpty || event.phase.contains(.began) || event.phase.contains(.changed) {
            onUserScroll?()
        }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        updateFadeMask()
        onLayout?()
    }

    private func updateFadeMask() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = layer.bounds
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
        let contentWidth = max(0, bounds.width - scrollerWidth)
        let fade = min(topFadeHeight, bounds.height)
        fadeMask.frame = bounds
        // 图层坐标按视图是否翻转走;这个视图不翻转,顶边在 maxY。
        let flipped = layer.contentsAreFlipped()
        fadeGradient.frame = CGRect(x: 0, y: flipped ? 0 : bounds.height - fade, width: contentWidth, height: fade)
        fadeGradient.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        fadeGradient.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        fadeBody.frame = CGRect(x: 0, y: flipped ? fade : 0, width: contentWidth, height: bounds.height - fade)
        scrollerColumn.frame = CGRect(x: contentWidth, y: 0, width: bounds.width - contentWidth, height: bounds.height)
        if layer.mask !== fadeMask { layer.mask = fadeMask }
        CATransaction.commit()
    }
}
