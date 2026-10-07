import AppKit
import Combine
import LyrimuseCore
import OSLog
import QuartzCore
import SwiftUI

/// 歌词窗口的歌词列表,图层版:每一行是图层树,逐字填色、上浮、长音强调、换句错开、景深过渡都是装给 Core Animation 的动画,
/// 由渲染服务逐帧插值,主线程只在换句、换状态那一刻装一次。滚动容器是 AppKit `NSScrollView`(原生滚轮手感;进程里没有
/// 活着的 SwiftUI `ScrollView`,也就没有每帧两次渲染那回事,见 07 章决策 99)。做法、实测与排除过的方向见 07 章决策 111。
struct LyricsLayerList: NSViewRepresentable {
    struct Spec: Equatable {
        var lines: [LyricsWindowLine]
        /// 间奏「•••」,键是 `LyricsGapMarker.index`(-1 = 前奏)。
        var gapMarkers: [Int: LyricsGapMarker]
        /// 末尾「创作者：…」的名单;迷你「多行」不显示。
        var songwriters: [String]
        var style: LyricsLayerRowStyle
        /// 行与行之间的距离。
        var lineSpacing: CGFloat
        /// 右边的滚动指示条;迷你「多行」不画。
        var showsScrollIndicator: Bool
        /// 歌词这一列离列表左右边的距离(同 SwiftUI 版 VStack 的 leading / trailing padding)。
        var leading: CGFloat
        var trailing: CGFloat
        var onArtwork: Bool
        /// 拖窗口边角期间关掉各行模糊(07 章决策 71)。
        var suspendsBlur: Bool
        var currentLineIndex: Int?
        var scrollLineIndex: Int?
        var overlapping: Set<Int>
        var currentGapIndex: Int?
        var fillSettled: Bool
        var isPlaying: Bool
        var surfaceVisible: Bool
        /// 时间基准的指纹(锚点、暂停位置、歌词偏移,`LyricsTimingEpoch`):一变就按新基准重装填色动画。
        var timingEpoch: Int
        var rate: Double
    }

    let spec: Spec
    /// 歌词窗口的「闲置隐藏」:指示条跟着按钮组一起淡入淡出(07 章决策 129)。引用类型,不进 `Spec`。
    var chromeFade: LyricsWindowChromeFade?
    /// 此刻的播放位置(歌词时间轴毫秒,含歌词偏移)。装动画、对表时各读一次。
    let nowMs: () -> Int
    let onTapLine: (Int) -> Void

    func makeNSView(context: Context) -> LyricsLayerListView { LyricsLayerListView() }

    func updateNSView(_ view: LyricsLayerListView, context: Context) {
        view.nowProvider = nowMs
        view.onTapLine = onTapLine
        view.bindChromeFade(chromeFade)
        view.apply(spec)
    }
}

@MainActor
final class LyricsLayerListView: NSView {
    var nowProvider: (() -> Int)?
    var onTapLine: ((Int) -> Void)?

    private let clip = FlippedView()
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private let rowsLayer = CALayer()
    private let fadeMask = CAGradientLayer()
    private let track = CALayer()
    private let thumb = CALayer()

    private var spec: LyricsLayerList.Spec?
    private var rows: [LyricsLayerRow] = []
    private var footer: LyricsLayerRow?
    /// 每一行(下标同 `spec.lines`)、末尾创作者行此刻的 y(文档坐标)。
    private var rowY: [CGFloat] = []
    private var footerY: CGFloat = 0
    private var gapView: (index: Int, view: GapDotsNSView)?
    private var gapY: CGFloat = 0
    private var contentHeight: CGFloat = 0
    /// 上一次排版用的输入:内容、宽度、字号这些一变就整张重建。
    private var builtKey: BuildKey?
    private var hoveredLine: Int?
    private var pressedLine: Int?
    private var pressPoint: NSPoint = .zero
    /// 当前行(们)装动画那一刻的(歌词位置, 媒体时间),对表用:动画此刻推到哪 vs 播放时钟。
    private var installed: (lines: Set<Int>, atMs: Int, media: CFTimeInterval, epoch: Int, rate: Double)?
    /// 上一笔换句落定时的滚动量,判用户有没有自己滚开(同 07 章决策 109)。
    private var landedScroll: CGFloat?
    /// 景深此刻的目标,换了才装过渡。
    private var depthTargets: [Int: (opacity: Float, blur: CGFloat, hovered: Bool)] = [:]
    private var footerDepth: (opacity: Float, blur: CGFloat)?
    private var pendingRepositionWhileHidden = false
    /// 此刻按时间轴走的行,和其余各行上一次画的「唱过没有」(nil = 当前行 / 还没画过)。
    private var activeRows = Set<Int>()
    private var sungState: [Bool?] = []
    /// 上一次排版时那一排「•••」是哪一段间奏:同一段才跟着别的行一起挪,新出现的只淡入。
    private var laidOutGap: Int?
    private var lastRebuild: CFTimeInterval = 0
    /// 正在后台排版画字的那一张:它的输入和作废标记。新的一张一开画,旧的就作废,画完也不装。
    private var building: (key: BuildKey, ticket: BuildTicket)?
    /// 各行是不是按眼下这份歌词建的(歌词换了、新的一张还在后台画时为假):为假时不动各行、不认悬停和点按。
    private var rowsCurrent = false
    /// 字形剪影,跟着这张表走。每次建表一代,装好之后只留这一代用到的:前几首歌、拖窗口时中间那几档字号画的都不留。
    private let silhouettes = GenerationCache<LyricsLayerListText.SilhouetteKey, CGImage?>()
    private var deferredApply: DispatchWorkItem?
    /// 换句位移动画的键序号:几笔叠着走,每一笔一个键,不互相顶掉。
    private var shiftSerial = 0
    private var trackingArea: NSTrackingArea?
    private weak var boundChromeFade: LyricsWindowChromeFade?
    private var chromeFadeObserver: AnyCancellable?

    private struct BuildKey: Equatable, @unchecked Sendable {
        var lines: [LyricsWindowLine]
        var songwriters: [String]
        var style: LyricsLayerRowStyle
        var columnWidth: CGFloat
    }

    /// 动画的帧率:跟显示刷新走满(渲染服务对长时程慢动画会自己降档,别靠默认值)。
    private static let frameRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    /// 重装填色动画的漂移门:动画此刻推到的位置跟播放时钟差过它才重装(同悬浮歌词 `resyncToleranceMs`)。
    private static let resyncToleranceMs = 250
    /// 当前行滚到视口从上往下这个比例处(同 SwiftUI 版 `activeLineAnchor`,07 章决策 87);开场滚第一句、锚 0.52。
    private static let activeAnchor: CGFloat = 0.37
    private static let introAnchor: CGFloat = 0.52
    private static let staggerKey = "lyrimuse.layer-list.shift"
    /// 整张重建一次各花了多久(debug 级,`log stream --level debug` 才看得到)。
    private static let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-layer-list")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clip.wantsLayer = true
        clip.autoresizingMask = [.width, .height]
        addSubview(clip)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.autoresizingMask = [.width, .height]
        scrollView.wantsLayer = true
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        document.wantsLayer = true
        document.layerUsesCoreImageFilters = true
        scrollView.documentView = document
        clip.addSubview(scrollView)
        rowsLayer.anchorPoint = .zero
        rowsLayer.actions = ["position": NSNull(), "bounds": NSNull(), "sublayers": NSNull()]
        document.layer?.addSublayer(rowsLayer)
        document.onMouse = { [weak self] event, kind in self?.handleMouse(event, kind) }
        // 上下边缘渐隐:顶部一直全透明到胶囊下沿之后才显现、底边被窗口直切处淡掉(同 SwiftUI 版那条 mask)。
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor,
                           NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.075, 0.2, 0.9, 1]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.actions = ["position": NSNull(), "bounds": NSNull()]
        clip.layer?.mask = fadeMask
        for l in [track, thumb] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            l.cornerRadius = 3
            layer?.addSublayer(l)
        }
        thumb.cornerRadius = 6
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        clip.frame = bounds
        scrollView.frame = clip.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = clip.bounds
        CATransaction.commit()
        // 宿主随时会叫 layout,尺寸真变了才重排(折行、锚位都跟着尺寸走)
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        if let spec { apply(spec, force: true) }
    }

    private var laidOutSize: CGSize = .zero

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        discardBuilds()
        if let spec { apply(spec, force: true) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        discardBuilds()
        if let spec { apply(spec, force: true) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - 状态

    func apply(_ next: LyricsLayerList.Spec, force: Bool = false) {
        let previous = spec
        spec = next
        let width = max(1, bounds.width - next.leading - next.trailing)
        guard bounds.width > 0, bounds.height > 0 else { return }
        var style = next.style
        style.scale = window?.backingScaleFactor ?? style.scale
        let key = BuildKey(lines: next.lines, songwriters: next.style.centered ? [] : next.songwriters,
                           style: style, columnWidth: width)
        if key != builtKey, building?.key != key {
            // 拖窗口边角期间折行跟着宽度变,但别每一帧都整张重建:隔一小段才重建一次,松手那一刻再按最终宽度建一次
            let wait = Self.liveResizeRebuildInterval - (CACurrentMediaTime() - lastRebuild)
            if inLiveResize, builtKey != nil, wait > 0 {
                scheduleDeferredApply(after: wait)
            } else {
                startBuild(key)
            }
        }
        // 歌词换了、新的一张还在后台画:旧的那张原样留着(装上的动画照走),新的下标对不上它,先不动
        rowsCurrent = builtKey?.lines == next.lines
        guard rowsCurrent else { return }
        let gapChanged = previous?.currentGapIndex != next.currentGapIndex
        let anchorChanged = previous?.scrollLineIndex != next.scrollLineIndex
        if gapChanged || force {
            syncGapView(next)
        }
        if force {
            relayout(next, transition: .none)
        } else if gapChanged || anchorChanged {
            if !next.surfaceVisible {
                pendingRepositionWhileHidden = true
                relayout(next, transition: .none)
            } else {
                relayout(next, transition: transitionStyle(previous: previous, next: next, gapChanged: gapChanged))
            }
        } else if previous?.surfaceVisible == false, next.surfaceVisible, pendingRepositionWhileHidden {
            pendingRepositionWhileHidden = false
            relayout(next, transition: .none)
        }
        if let g = gapView?.view, let marker = next.gapMarkers[gapView?.index ?? .min] {
            g.apply(gapConfig(marker, next))
        }
        updateDepth(next, previous: previous, animated: next.surfaceVisible)
        updateKaraoke(next, previous: previous, force: force)
        updateIndicator(animated: false)
    }

    private static let liveResizeRebuildInterval: CFTimeInterval = 0.15

    private func scheduleDeferredApply(after seconds: Double) {
        guard deferredApply == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredApply = nil
            if let spec = self.spec { self.apply(spec, force: true) }
        }
        deferredApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if let spec { apply(spec, force: true) }
    }

    private enum Transition {
        case none
        /// 换句:各行从上往下依次晚一点归位(`LyricsLineStagger`,07 章决策 94)。
        case stagger
        /// 进出间奏、跳得远、用户滚开过:整页一起走 0.45 秒的那条曲线。
        case page
    }

    private func transitionStyle(previous: LyricsLayerList.Spec?, next: LyricsLayerList.Spec, gapChanged: Bool) -> Transition {
        guard !next.style.reduceMotion else { return .page }
        if gapChanged { return .page }
        guard let old = previous?.scrollLineIndex, let new = next.scrollLineIndex else { return .page }
        if abs(new - old) > LyricsLineStagger.maxStaggerJumpRows { return .page }
        let viewport = scrollView.contentView.bounds.height
        if let landed = landedScroll, abs(scrollY - landed) > viewport * CGFloat(LyricsLineStagger.maxStaggerDriftFraction) {
            return .page
        }
        return .stagger
    }

    // MARK: - 建表与排版

    /// 整张重建。排版、量字、画剪影(建表最贵的部分)在后台按行并行算,画好之后回主线程一次换上(`install`),
    /// 主线程只建图层。颜色(`.primary` 这类会跟着外观变的)先在主线程按这扇窗此刻的外观解析成定值;外观一变整张重建
    /// (见 viewDidChangeEffectiveAppearance)。
    private func startBuild(_ key: BuildKey) {
        building?.ticket.cancel()
        let ticket = BuildTicket()
        building = (key, ticket)
        lastRebuild = CACurrentMediaTime()
        let started = lastRebuild
        let ink = LyricsLayerRowInk(style: key.style, appearance: effectiveAppearance)
        let pass = LyricsLayerListText.Silhouettes(cache: silhouettes, generation: silhouettes.nextGeneration())
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = key.lines
            var plans = [LyricsLayerRowPlan?](repeating: nil, count: lines.count)
            plans.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: lines.count) { i in
                    guard !ticket.isCancelled else { return }
                    out[i] = LyricsLayerRowPlan.line(index: i, line: lines[i].line, width: key.columnWidth,
                                                     style: key.style, ink: ink, silhouettes: pass)
                }
            }
            let footer = lines.isEmpty || ticket.isCancelled ? nil
                : LyricsLayerRowPlan.footer(names: key.songwriters, width: key.columnWidth, style: key.style, ink: ink)
            let planMs = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self, !ticket.isCancelled, self.building?.ticket === ticket else { return }
                let installStart = CACurrentMediaTime()
                self.building = nil
                let built = plans.compactMap { $0 }
                self.install(built, footer: footer, key: key)
                self.silhouettes.keep(generation: pass.generation)
                if let spec = self.spec { self.apply(spec, force: true) }
                let elements = self.rows.reduce(0) { $0 + $1.elements.count }
                let installMs = (CACurrentMediaTime() - installStart) * 1000
                let bitmapMB = Double(LyricsLayerRowPlan.bitmapBytes(built + [footer].compactMap { $0 })) / 1_048_576
                Self.log.debug("rebuilt \(self.rows.count, privacy: .public) rows, \(elements, privacy: .public) elements, bitmaps \(bitmapMB, format: .fixed(precision: 1), privacy: .public) MB: plan \(planMs, format: .fixed(precision: 1), privacy: .public) ms in background, install \(installMs, format: .fixed(precision: 1), privacy: .public) ms")
            }
        }
    }

    private func install(_ plans: [LyricsLayerRowPlan], footer footerPlan: LyricsLayerRowPlan?, key: BuildKey) {
        builtKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for r in rows { r.layer.removeFromSuperlayer() }
        footer?.layer.removeFromSuperlayer()
        rows = plans.map { LyricsLayerRow($0, scale: key.style.scale) }
        footer = footerPlan.map { LyricsLayerRow($0, scale: key.style.scale) }
        for r in rows { rowsLayer.addSublayer(r.layer) }
        if let footer { rowsLayer.addSublayer(footer.layer) }
        CATransaction.commit()
        depthTargets = [:]
        footerDepth = nil
        installed = nil
        hoveredLine = nil
        landedScroll = nil
        activeRows = []
        sungState = []
    }

    /// 外观、比例变了:建好的和正在画的都不算数,下一次 apply 整张重画(画好之前旧的那张原样留着)。
    private func discardBuilds() {
        builtKey = nil
        building?.ticket.cancel()
        building = nil
    }

    private var scrollY: CGFloat { scrollView.contentView.bounds.origin.y }

    /// 排版(各行的 y、内容总高)+ 滚到当前行。`transition` 非 `.none` 时:先记下每一行此刻在屏幕上的位置,一次落到新位置,
    /// 再给每一行挂一条从旧位置走回来的加法动画 —— 换句错开、进出间奏、整页滚动都是这一套,只是起步延迟和曲线不同;
    /// 几笔叠在一起时各自走完(加法动画相加),不会互相打断。
    private func relayout(_ s: LyricsLayerList.Spec, transition: Transition) {
        let viewport = scrollView.contentView.bounds.height
        let oldScroll = scrollY
        let oldRowY = rowY
        let oldFooterY = footerY
        let oldGapY = gapY
        let previousGap = laidOutGap
        laidOutGap = gapView?.index
        let fontSize = s.style.fontSize
        // 顶 / 底留白按视口比例(同 SwiftUI 版 VStack 的 padding):offset 0 就是开场版式,最后一句也能锚到 41%。
        var y = max(88, viewport * 0.395)
        var placed = false
        func next(_ h: CGFloat) -> CGFloat {
            if placed { y += s.lineSpacing }
            placed = true
            let top = y
            y += h
            return top
        }
        let gapHeight = fontSize * 0.5
        let activeGap = gapView?.index
        if activeGap == -1 { gapY = next(gapHeight) }
        rowY = rows.indices.map { i in
            let top = next(rows[i].size.height)
            if activeGap == i { gapY = next(gapHeight) }
            return top
        }
        if let footer { footerY = next(footer.size.height) }
        contentHeight = y + max(88, viewport * 0.55)
        let target = targetScroll(s, viewport: viewport)
        // 滑块此刻画在哪(滚动一落位它就被同步到新位置,得在那之前记下)
        let thumbFrom = thumb.presentation()?.position.y ?? thumb.position.y
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        document.frame = CGRect(x: 0, y: 0, width: scrollView.contentView.bounds.width, height: max(contentHeight, viewport))
        rowsLayer.frame = document.bounds
        for (i, r) in rows.enumerated() { r.layer.position = CGPoint(x: s.leading, y: rowY[i]) }
        footer?.layer.position = CGPoint(x: s.leading, y: footerY)
        if let g = gapView?.view { g.frame = gapFrame(s) }
        if let target { scrollTo(target) }
        CATransaction.commit()
        guard transition != .none, !oldRowY.isEmpty else {
            if transition == .none { landedScroll = target }
            return
        }
        let newScroll = scrollY
        // 只给屏幕上看得见(换之前或换之后在视口附近)的项挂动画,远处的直接落位。起步时刻留给提交那一刻(beginTime 为 0):
        // 装完动画之后主线程这一轮更新再卡多久,起步都不会一下跳过一截;各行的错开延迟放在组动画里面算。
        func animate(_ layer: CALayer, oldScreen: CGFloat, newScreen: CGFloat, height: CGFloat) {
            let delta = oldScreen - newScreen
            guard abs(delta) > 0.5 else { return }
            let near: (CGFloat) -> Bool = { $0 + height > -viewport && $0 < 2 * viewport }
            guard near(oldScreen) || near(newScreen) else { return }
            let spring = CASpringAnimation(keyPath: "position.y")
            spring.isAdditive = true
            spring.fromValue = delta
            spring.toValue = 0
            spring.mass = 1
            var delay = 0.0
            switch transition {
            case .stagger:
                let omega = 2 * Double.pi / LyricsLineStagger.springResponse
                spring.stiffness = omega * omega
                spring.damping = 2 * LyricsLineStagger.springDampingRatio * omega
                delay = LyricsLineStagger.delayMs(distanceFromTop: Double(oldScreen), fontSize: Double(fontSize)) / 1000
            case .page, .none:
                // 同 `.smooth(duration: 0.45)`:临界阻尼,响应 0.45 秒(`LyricsDepthMotion.line` 同一条)
                let omega = 2 * Double.pi / LyricsDepthMotion.lineResponse
                spring.stiffness = omega * omega
                spring.damping = 2 * omega
            }
            spring.duration = spring.settlingDuration
            spring.beginTime = delay
            spring.fillMode = .backwards
            let group = CAAnimationGroup()
            group.animations = [spring]
            group.duration = delay + spring.duration
            group.preferredFrameRateRange = Self.frameRange
            layer.add(group, forKey: Self.staggerKey + ".\(shiftSerial)")
            shiftSerial &+= 1
        }
        for (i, r) in rows.enumerated() where i < oldRowY.count {
            animate(r.layer, oldScreen: oldRowY[i] - oldScroll, newScreen: rowY[i] - newScroll, height: r.size.height)
        }
        if let footer {
            animate(footer.layer, oldScreen: oldFooterY - oldScroll, newScreen: footerY - newScroll, height: footer.size.height)
        }
        if let g = gapView?.view, let gl = g.layer, gapView?.index == previousGap {
            animate(gl, oldScreen: oldGapY - oldScroll, newScreen: gapY - newScroll, height: gapHeight)
        }
        animateThumb(from: thumbFrom)
        // 定下这一笔的落点:下一次换句前拿它判用户有没有自己滚开。
        landedScroll = newScroll
    }

    /// 当前行(滚动锚)对到视口的锚位,对不上内容范围时钳住。没有滚动锚、有前奏点时滚第一句、锚 0.52(开场版式)。
    private func targetScroll(_ s: LyricsLayerList.Spec, viewport: CGFloat) -> CGFloat? {
        let maxScroll = max(0, contentHeight - viewport)
        func aligned(_ top: CGFloat, _ height: CGFloat, _ anchor: CGFloat) -> CGFloat {
            min(maxScroll, max(0, top + anchor * height - anchor * viewport))
        }
        if let g = gapView?.index, g >= 0 { return aligned(gapY, s.style.fontSize * 0.5, Self.activeAnchor) }
        if let i = s.scrollLineIndex ?? s.currentLineIndex, rowY.indices.contains(i) {
            return aligned(rowY[i], rows[i].size.height, Self.activeAnchor)
        }
        if !rowY.isEmpty, s.gapMarkers[-1] != nil { return aligned(rowY[0], rows[0].size.height, Self.introAnchor) }
        return nil
    }

    private func scrollTo(_ y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - 间奏「•••」

    private func gapConfig(_ marker: LyricsGapMarker, _ s: LyricsLayerList.Spec) -> GapDotsNSView.Config {
        .init(startMs: marker.startMs, endMs: marker.endMs, dotSize: s.style.fontSize * 0.32,
              spacing: s.style.fontSize * 0.23, color: s.style.textColor,
              running: s.isPlaying && s.surfaceVisible, reduceMotion: s.style.reduceMotion, shadow: nil, style: .window)
    }

    private func gapFrame(_ s: LyricsLayerList.Spec) -> CGRect {
        let dot = s.style.fontSize * 0.32, spacing = s.style.fontSize * 0.23
        let w = CGFloat(GapDotsCurve.dotCount) * dot + CGFloat(GapDotsCurve.dotCount - 1) * spacing
        let column = max(1, bounds.width - s.leading - s.trailing)
        let x = s.style.centered ? s.leading + (column - w) / 2 : s.leading
        return CGRect(x: x, y: gapY + (s.style.fontSize * 0.5 - dot) / 2, width: w, height: dot)
    }

    /// 间奏开始时在原位展开一排点(只淡入,Apple 出现时没有放大那一下),结束时缩小淡出(同 SwiftUI 版 gapDotsRow 的过渡)。
    private func syncGapView(_ s: LyricsLayerList.Spec) {
        let want = s.currentGapIndex.flatMap { g in s.gapMarkers[g].map { (g, $0) } }
        if let current = gapView, current.index == want?.0 { return }
        if let old = gapView?.view {
            gapView = nil
            fadeOut(old, centered: s.style.centered)
        }
        guard let (index, marker) = want else { return }
        let v = GapDotsNSView()
        v.positionProvider = { [weak self] _ in
            self?.nowProvider?() ?? marker.startMs
        }
        document.addSubview(v)
        gapView = (index, v)
        v.apply(gapConfig(marker, s))
        if let l = v.layer, !s.style.reduceMotion {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.duration = 0.45
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(a, forKey: "lyrimuse.layer-list.gap-in")
        }
    }

    private func fadeOut(_ v: GapDotsNSView, centered: Bool) {
        guard let l = v.layer, spec?.style.reduceMotion == false else {
            v.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { v.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform")
        let scale = CATransform3DMakeScale(0.4, 0.4, 1)
        let ax = centered ? v.bounds.width / 2 : 0, ay = v.bounds.height / 2
        shrink.toValue = NSValue(caTransform3D: CATransform3DConcat(CATransform3DConcat(
            CATransform3DMakeTranslation(-ax, -ay, 0), scale), CATransform3DMakeTranslation(ax, ay, 0)))
        for a in [fade, shrink] {
            a.duration = 0.45
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(a, forKey: "lyrimuse.layer-list.gap-out.\(a.keyPath ?? "")")
        }
        CATransaction.commit()
    }

    // MARK: - 景深

    /// 各行的透明度 / 模糊:按离滚动锚几行(`LyricsWindowDepth`),悬停那一行恢复清晰。换句沿 `.smooth(duration: 0.45)` 那条弹簧
    /// 过去、当前行的透明度瞬时到位;悬停 0.16 秒 easeOut(同 SwiftUI 版 RowDepth,07 章决策 106)。
    private func updateDepth(_ s: LyricsLayerList.Spec, previous: LyricsLayerList.Spec?, animated: Bool) {
        let anchor = s.scrollLineIndex ?? s.currentLineIndex
        let inGap = s.currentGapIndex != nil
        for (i, r) in rows.enumerated() {
            let hovered = hoveredLine == i
            let d: Int? = s.overlapping.contains(i) ? 0 : LyricsWindowDepth.distance(index: i, anchorIndex: anchor, inGap: inGap)
            let opacity = hovered ? 1 : Float(LyricsWindowDepth.opacity(distance: d))
            let blur = (s.style.reduceMotion || hovered || s.suspendsBlur) ? 0
                : LyricsWindowDepth.blurRadius(distance: d, fontSize: s.style.fontSize)
            let old = depthTargets[i]
            guard old?.opacity != opacity || old?.blur != blur else { continue }
            depthTargets[i] = (opacity, blur, hovered)
            let curve: DepthCurve = !animated || old == nil ? .instant : (old?.hovered != hovered ? .hover : .line)
            // 换句时当前行的透明度瞬时到位(跟着爬会跟填色相乘出先暗一拍的凹陷),模糊照样「对焦」
            let opacityCurve: DepthCurve = curve == .line && d == 0 ? .instant : curve
            setDepth(r.layer, opacity: opacity, blur: blur, opacityCurve: opacityCurve, blurCurve: curve)
        }
        if let footer {
            let d = LyricsWindowDepth.distance(index: rows.count, anchorIndex: anchor, inGap: inGap)
            let opacity = Float(LyricsWindowDepth.opacity(distance: d))
            let blur = (s.style.reduceMotion || s.suspendsBlur) ? 0 : LyricsWindowDepth.blurRadius(distance: d, fontSize: s.style.fontSize)
            if footerDepth?.opacity != opacity || footerDepth?.blur != blur {
                let curve: DepthCurve = !animated || footerDepth == nil ? .instant : .line
                footerDepth = (opacity, blur)
                setDepth(footer.layer, opacity: opacity, blur: blur, opacityCurve: curve, blurCurve: curve)
            }
        }
    }

    private enum DepthCurve { case instant, line, hover }

    private func setDepth(_ layer: CALayer, opacity: Float, blur: CGFloat, opacityCurve: DepthCurve, blurCurve: DepthCurve) {
        let presented = layer.presentation()
        let fromOpacity = presented?.opacity ?? layer.opacity
        let fromBlur = (presented?.value(forKeyPath: "filters.blur.inputRadius") as? CGFloat)
            ?? (layer.value(forKeyPath: "filters.blur.inputRadius") as? CGFloat) ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if blur > 0 || fromBlur > 0 {
            if layer.filters == nil {
                layer.filters = [LyricsLayerBlur.make()]
            }
            layer.setValue(blur, forKeyPath: "filters.blur.inputRadius")
        }
        layer.opacity = opacity
        CATransaction.commit()
        add(depthAnimation("opacity", from: Double(fromOpacity), to: Double(opacity), curve: opacityCurve), to: layer)
        if layer.filters != nil {
            add(depthAnimation("filters.blur.inputRadius", from: Double(fromBlur), to: Double(blur), curve: blurCurve), to: layer)
        }
        if blur == 0, blurCurve == .instant { layer.filters = nil }
    }

    private func depthAnimation(_ key: String, from: Double, to: Double, curve: DepthCurve) -> CAAnimation? {
        guard from != to else { return nil }
        switch curve {
        case .instant:
            return nil
        case .line:
            let a = CASpringAnimation(keyPath: key)
            let omega = 2 * Double.pi / LyricsDepthMotion.lineResponse
            a.mass = 1
            a.stiffness = omega * omega
            a.damping = 2 * omega
            a.fromValue = from
            a.toValue = to
            a.duration = a.settlingDuration
            a.preferredFrameRateRange = Self.frameRange
            return a
        case .hover:
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = LyricsDepthMotion.hoverDuration
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.preferredFrameRateRange = Self.frameRange
            return a
        }
    }

    private func add(_ a: CAAnimation?, to layer: CALayer) {
        guard let a, let key = (a as? CAPropertyAnimation)?.keyPath else { return }
        layer.add(a, forKey: "lyrimuse.layer-list.depth." + key)
    }

    // MARK: - 逐字

    /// 当前行(滚动锚那一句,和跟它重叠着还在唱的行)按时间轴走;其余行定格全填色,唱过的字停在上浮的高度。
    /// 整行定格只认正在染色的那一句(`currentLineIndex`):滚动锚提前到下一句的空档里,下一句清晰但还没开始染色。
    private func updateKaraoke(_ s: LyricsLayerList.Spec, previous: LyricsLayerList.Spec?, force: Bool) {
        let anchor = s.scrollLineIndex ?? s.currentLineIndex
        var active = Set<Int>()
        if s.currentGapIndex == nil {
            if let anchor, rows.indices.contains(anchor) { active.insert(anchor) }
            for i in s.overlapping where rows.indices.contains(i) { active.insert(i) }
        }
        if force || sungState.count != rows.count { sungState = Array(repeating: nil, count: rows.count) }
        for (i, r) in rows.enumerated() where !active.contains(i) {
            let raised = sung(i, s)
            if force || activeRows.contains(i) || sungState[i] != raised {
                r.showRest(raised: raised, style: s.style)
                sungState[i] = raised
            }
        }
        for i in active { sungState[i] = nil }
        let running = s.isPlaying && s.surfaceVisible
        let nowMs = nowProvider?() ?? 0
        let media = CACurrentMediaTime()
        let timingChanged = force || previous?.isPlaying != s.isPlaying || previous?.surfaceVisible != s.surfaceVisible
            || previous?.fillSettled != s.fillSettled || previous?.timingEpoch != s.timingEpoch || previous?.rate != s.rate
            || previous?.currentLineIndex != s.currentLineIndex
        let drifted: Bool = {
            guard running, let inst = installed else { return true }
            let predicted = inst.atMs + Int((media - inst.media) * 1000 * inst.rate)
            return abs(predicted - nowMs) > Self.resyncToleranceMs
        }()
        let changedRows = active.subtracting(activeRows)
        activeRows = active
        guard timingChanged || drifted || !changedRows.isEmpty else { return }
        var playing = false
        for i in active {
            let settled = s.fillSettled && i == s.currentLineIndex
            if settled {
                rows[i].showSettled(style: s.style)
            } else if !running {
                rows[i].showFrozen(atMs: nowMs)
            } else if timingChanged || drifted || changedRows.contains(i) {
                rows[i].play(nowMs: nowMs, rate: s.rate, mediaNow: media, frameRange: Self.frameRange)
                playing = true
            } else {
                playing = true
            }
        }
        installed = playing ? (active, nowMs, media, s.timingEpoch, s.rate) : nil
    }

    /// 这一行已经唱过(或正在唱):不是当前行时字停在上浮的高度(07 章决策 83)。
    private func sung(_ index: Int, _ s: LyricsLayerList.Spec) -> Bool {
        s.style.rises && (s.currentLineIndex.map { index <= $0 } ?? false)
    }

    // MARK: - 滚动指示条

    @objc private func boundsChanged() {
        updateIndicator(animated: false)
        if let p = window?.mouseLocationOutsideOfEventStream {
            updateHover(at: convert(p, from: nil))
        }
    }

    /// 自绘指示条(暗轨道 6pt + 滑块 12pt、常显,中心距右缘 59pt,同 SwiftUI 版 `LyricsScrollIndicator`)。不在渐隐遮罩里。
    private func updateIndicator(animated: Bool) {
        let viewH = bounds.height
        let topInset: CGFloat = 90, bottomInset: CGFloat = 40
        let trackH = viewH - topInset - bottomInset
        let content = contentHeight
        let visible = (spec?.showsScrollIndicator ?? false) && content > viewH + 4 && trackH > 80
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.isHidden = !visible
        thumb.isHidden = !visible
        guard visible else {
            CATransaction.commit()
            return
        }
        let onArtwork = spec?.onArtwork ?? true
        let ink = onArtwork ? NSColor.white : NSColor.labelColor
        track.backgroundColor = ink.withAlphaComponent(onArtwork ? 0.08 : 0.10).cgColor
        thumb.backgroundColor = ink.withAlphaComponent(onArtwork ? 0.30 : 0.35).cgColor
        let centerX = bounds.width - 59
        track.frame = CGRect(x: centerX - 3, y: topInset, width: 6, height: trackH)
        let thumbH = min(trackH, max(40, trackH * viewH / content))
        let maxScroll = content - viewH
        let f = maxScroll > 0 ? min(1, max(0, scrollY / maxScroll)) : 0
        thumb.bounds = CGRect(x: 0, y: 0, width: 12, height: thumbH)
        thumb.position = CGPoint(x: centerX, y: topInset + (trackH - thumbH) * f + thumbH / 2)
        CATransaction.commit()
    }

    /// 指示条跟着歌词窗口的「闲置隐藏」淡入淡出(07 章决策 129)。动的是两层的 `opacity`,`isHidden` 仍归 `updateIndicator`。
    func bindChromeFade(_ fade: LyricsWindowChromeFade?) {
        guard fade !== boundChromeFade else { return }
        boundChromeFade = fade
        chromeFadeObserver = fade?.$visible.removeDuplicates().sink { [weak self] visible in
            self?.fadeIndicator(visible: visible)
        }
        if fade == nil { fadeIndicator(visible: true) }
    }

    private func fadeIndicator(visible: Bool) {
        let target: Float = visible ? 1 : 0
        for layer in [track, thumb] {
            let from = layer.presentation()?.opacity ?? layer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = target
            CATransaction.commit()
            guard from != target else { continue }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from
            a.toValue = target
            a.duration = visible ? LyricsWindowChromeIdle.fadeInSeconds : LyricsWindowChromeIdle.fadeOutSeconds
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "lyrimuse.layer-list.indicator-fade")
        }
    }

    /// 换句那一下滑块沿各行景深那条弹簧补间过去(同 SwiftUI 版指示条换句时的补间),用户自己滚时直接跟手。
    private func animateThumb(from: CGFloat) {
        updateIndicator(animated: false)
        let to = thumb.position.y
        guard abs(from - to) > 0.5 else { return }
        let a = CASpringAnimation(keyPath: "position.y")
        let omega = 2 * Double.pi / LyricsDepthMotion.lineResponse
        a.mass = 1
        a.stiffness = omega * omega
        a.damping = 2 * omega
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        a.preferredFrameRateRange = Self.frameRange
        thumb.add(a, forKey: "lyrimuse.layer-list.thumb")
    }

    // MARK: - 悬停与点按

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    /// 行的命中区是整行宽的一块不动的矩形(按排版位置算,不跟着错开的位移走,07 章决策 98)。
    private func line(at point: NSPoint) -> Int? {
        guard rowsCurrent, let s = spec, bounds.contains(point) else { return nil }
        let doc = document.convert(point, from: self)
        guard doc.x >= s.leading, doc.x <= bounds.width - s.trailing else { return nil }
        for (i, y) in rowY.enumerated() where doc.y >= y && doc.y < y + rows[i].size.height {
            return i
        }
        return nil
    }

    private func updateHover(at point: NSPoint) {
        setHovered(line(at: point))
    }

    private func setHovered(_ i: Int?) {
        guard i != hoveredLine, let s = spec else { return }
        hoveredLine = i
        updateDepth(s, previous: s, animated: true)
    }

    private func handleMouse(_ event: NSEvent, _ kind: FlippedView.MouseKind) {
        let point = convert(event.locationInWindow, from: nil)
        switch kind {
        case .down:
            pressedLine = line(at: point)
            pressPoint = point
        case .up:
            defer { pressedLine = nil }
            guard let i = pressedLine, line(at: point) == i,
                  hypot(point.x - pressPoint.x, point.y - pressPoint.y) < 6 else { return }
            onTapLine?(i)
        }
    }

    // MARK: - 无障碍

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? {
        rows.enumerated().map { i, r in
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(.staticText)
            e.setAccessibilityLabel(r.accessibilityText)
            e.setAccessibilityParent(self)
            if rowY.indices.contains(i) {
                let docRect = CGRect(x: spec?.leading ?? 0, y: rowY[i], width: r.size.width, height: r.size.height)
                let inSelf = convert(document.convert(docRect, to: nil), from: nil)
                e.setAccessibilityFrameInParentSpace(inSelf)
            }
            return e
        }
    }
}

/// 各行景深的高斯模糊,名字是 "blur"(键路径 `filters.blur.inputRadius`)。用 Core Animation 自己的 gaussianBlur 滤镜
/// (渲染服务原生实现);取不到时退回 `CIGaussianBlur`,同样的半径在渲染服务里要过 Core Image,帧率掉一半(07 章决策 111)。
enum LyricsLayerBlur {
    static func make() -> Any {
        if let type = NSClassFromString("CAFilter") as? NSObject.Type,
           let f = type.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject {
            f.setValue("blur", forKey: "name")
            f.setValue(0, forKey: "inputRadius")
            return f
        }
        return coreImage()
    }

    private static func coreImage() -> CIFilter {
        let f = CIFilter(name: "CIGaussianBlur")!
        f.name = "blur"
        f.setValue(0, forKey: kCIInputRadiusKey)
        return f
    }
}

/// 文档视图与裁剪容器:y 向下;鼠标按下 / 抬起交回列表判点哪一行。
@MainActor
final class FlippedView: NSView {
    enum MouseKind { case down, up }
    var onMouse: ((NSEvent, MouseKind) -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if let onMouse { onMouse(event, .down) } else { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if let onMouse { onMouse(event, .up) } else { super.mouseUp(with: event) }
    }
}

/// 一次后台建表的作废标记:主线程置位,后台每画一行前看一眼。
private final class BuildTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
