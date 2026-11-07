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

/// 歌词管理 / 搜索候选歌词那份预览的滚动容器:AppKit `NSScrollView`,文档视图里一个托管着全部行的 `NSHostingController`。
/// 跟随播放滚到当前句由 AppKit 动画推进(clip view 的 animator)。别换回 SwiftUI `ScrollView` + `scrollTo`:滚动途中会掉帧
///(见 11 章决策 146)。
///
/// 行的位置由内容自己上报(`lyricsPreviewRowFrame`);还没量到就先记着,量到了再滚。嵌套的托管视图不继承外面的 SwiftUI 环境,
/// 行里要用的环境值由调用方挂在 `content` 上。
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
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        // 嵌套的托管视图别吃窗口的安全区,理由同 OverlayLineChangeStage(04 章决策 79)。
        host.safeAreaRegions = []
        document.addSubview(host.view)
        coordinator.scrollView = scrollView
        coordinator.document = document
        coordinator.host = host
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
        coordinator.host?.rootView = AnyView(
            content()
                .coordinateSpace(name: LyricsPreviewRowFrameKey.space)
                .onPreferenceChange(LyricsPreviewRowFrameKey.self) { [weak coordinator] frames in
                    coordinator?.rowFramesChanged(frames)
                })
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
        var host: NSHostingController<AnyView>?
        var onUserScroll: () -> Void = {}
        var handledSerial: Int?
        var pending: LyricsPreviewScrollRequest?
        /// 最近一次不带动画的定位(换显示档、换歌):它跟新内容同一轮到,当时用的还是旧行的位置;新行的位置送到时按它再对一次。
        /// 用户自己滚、或来了带动画的定位(换句)就作废。
        var settle: LyricsPreviewScrollRequest?
        private var rowFrames: [Int: CGRect] = [:]
        private var laidOutWidth: CGFloat = -1
        private var laidOutHeight: CGFloat = -1

        func rowFramesChanged(_ frames: [Int: CGRect]) {
            rowFrames = frames
            // 行的高度变了(换显示模式、换歌),文档视图跟着长短。
            relayout(force: true)
            if pending == nil, let settle { pending = settle }
            applyPending()
        }

        /// 文档视图跟可视区一样宽,高度按内容在这个宽度下排出来的高度。
        func relayout(force: Bool = false) {
            guard let scrollView, let document, let host else { return }
            let width = Self.documentWidth(scrollView)
            guard width > 0 else { return }
            let height = ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            guard force || width != laidOutWidth || height != laidOutHeight else { return }
            laidOutWidth = width
            laidOutHeight = height
            let size = CGSize(width: width, height: max(height, 1))
            if document.frame.size != size { document.setFrameSize(size) }
            if host.view.frame != document.bounds { host.view.frame = document.bounds }
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
            if request.animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = LyricsPreviewScrollView.scrollAnimationDuration
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                    clip.animator().setBoundsOrigin(origin)
                } completionHandler: { [weak scrollView] in
                    guard let scrollView else { return }
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            } else {
                cancelAnimation()
                clip.scroll(to: origin)
                scrollView.reflectScrolledClipView(clip)
            }
        }

        /// 停掉正在走的程序滚动:用户一动手就以他为准,别跟动画抢。
        func cancelAnimation() {
            guard let clip = scrollView?.contentView else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                clip.animator().setBoundsOrigin(clip.bounds.origin)
            }
        }
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
