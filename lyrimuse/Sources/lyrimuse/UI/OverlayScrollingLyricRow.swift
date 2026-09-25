import AppKit
import CoreImage
import LyrimuseCore
import SwiftUI

// 悬浮歌词「长句处理 = 滚动」时带逐字填色的主行:整行画成长图交给 CALayer,滚动与逐字填色各是一条
// CAKeyframeAnimation,装好之后主线程不再参与(同菜单栏 `MenuBarScrollingLabel`)。
// 别改回 SwiftUI(`MarqueeText` + 30Hz `TimelineView` 整行重建):在悬浮窗的字号 / 行宽下那条会把
// 主线程打满、滚动一顿一顿。完整论证见 docs/features/04-desktop-overlay.md「长句处理」。
//
//     self.layer (masksToBounds,可视窗)
//       └ contentLayer                                     滚动 = 平移这一层
//           ├ strokeLayer                                   描边(已唱 / 未唱同色,不参与裁剪)
//           ├ baseClipLayer (只露未唱区) └ baseTextLayer    基础色长图
//           └ fillClipLayer (只露已唱区) └ fillTextLayer    强调色长图
//
// 已唱 / 未唱必须**互补裁剪**,别改成强调色那张叠在基础色上面:叠画时字形边缘的半透明像素会让
// 底下那张透出来,深底上镶一圈白边。
// 描边必须跟换行模式(`OptionalTextStroke`)同一个算法、同一组参数(`LyricsTextStrokeMetrics`):
// 剪影高斯模糊 σ = width,再按 alphaThreshold 硬阈值出实心轮廓。别换成 AppKit 的 `.strokeWidth` ——
// 那是沿轮廓居中描的细线,粗细和形状都跟换行模式对不上。
@MainActor
struct OverlayScrollingLyricRow: NSViewRepresentable {
    /// 这一行的全部渲染输入。只有它变了才重画长图 / 重装动画(`updateNSView` 会被 SwiftUI 的
    /// 任意一次重估叫到)。
    struct Spec: Equatable {
        var lineKey: String
        var words: [SyncedLyricWord]
        /// 非 nil = 开了逐词罗马音:每一列是「这一组的字 + 它的读音」上下两行,列宽取更宽的
        /// 那一行(同 SwiftUI 那边 VStack 取更宽子视图)。nil = 只有一行字。
        var groups: [SyncedLyricWordGroup]?
        var font: NSFont
        var romaFont: NSFont
        var baseColor: NSColor
        var fillColor: NSColor
        var romaBaseColor: NSColor
        var romaFillColor: NSColor
        /// nil = 不描边。
        var strokeColor: NSColor?
        var alignment: LyricDuet.Side
        var paused: Bool
        /// 非 nil = 按显示时长配速(没有逐字时间轴的行、译文 / 罗马音 / 下一句这些副行):不填色、
        /// 整行按 `fillColor` 画,滚动路径由 `MenuBarMarquee.pacedScrollPath` 按这个窗口算。
        /// nil = 跟唱:填色和滚动都跟着 `words` 的逐字时间轴走。
        var pacedWindow: PacedWindow? = nil
        /// 非 nil = 整行投一层阴影(灵动岛那条 `.compositingGroup().shadow(...)` 的图层版)。直接画进
        /// 两张长图里,之后每帧零开销。阴影只占位图四周的出血,不参与排版(见 `bleed`)。
        var shadow: TextShadow? = nil
        /// > 0 = 放不下、还没开始滚的时候,尾部留一条这么宽的渐隐带(同 `MarqueeText.edgeFadeWidth`,
        /// 判据同 `MarqueeMath.trailingFadeWidth`:一开始滚就收掉)。
        var edgeFadeWidth: CGFloat = 0
    }

    /// 整行阴影。`offsetY` 取 SwiftUI 的口径(正 = 往下)。
    struct TextShadow: Equatable {
        var color: NSColor
        var radius: CGFloat
        var offsetY: CGFloat
    }

    /// 一行的显示窗口(歌词时间轴毫秒,跟 `nowMs` 同一个基准)。
    struct PacedWindow: Equatable {
        var startMs: Int
        /// nil = 不知道会显示多久,配速退回固定速度。
        var dwellMs: Int?
    }

    let spec: Spec
    /// 这一刻的播放位置(毫秒,含歌词时间轴偏移)。装动画时读一次,之后不按帧调。
    let nowMs: () -> Int
    /// 所在那一层此刻显示着没有。灵动岛的稳态 / 展开两份歌词行靠透明度轮流显示(`NotchCardLayerActive`),
    /// 窗口看不见时整卡也是 false;别的宿主恒为默认值 true。它是本视图的输入,翻回 true 时 SwiftUI 会
    /// 重新调 updateNSView,在那一层露面之前把这一句补画上。
    @Environment(\.notchCardLayerActive) private var layerActive

    func makeNSView(context: Context) -> OverlayLyricScrollView { OverlayLyricScrollView() }

    func updateNSView(_ view: OverlayLyricScrollView, context: Context) {
        view.nowProvider = nowMs
        // 藏着的那一层不重画位图、不重装动画:换句时这两件事都等它显示出来再做。
        guard layerActive else { return }
        view.apply(spec: spec, nowMs: nowMs())
    }
}

/// 上面那套图层树的宿主。
@MainActor
final class OverlayLyricScrollView: NSView {
    private static let scrollKey = "lyrimuse.overlay-marquee"
    private static let fillKey = "lyrimuse.overlay-karaoke-fill"
    private static let basePositionKey = "lyrimuse.overlay-karaoke-base-pos"
    private static let baseBoundsKey = "lyrimuse.overlay-karaoke-base-bounds"
    /// 重装动画的漂移门(毫秒):动画在跑、且"动画此刻推到哪"与新时钟之差小于它时不打断。
    private static let resyncToleranceMs = 250
    /// 位图一律按 sRGB 画、按 sRGB 标记 —— 跟 SwiftUI 那条路同一套色彩管理,两种模式同一个
    /// 颜色值在屏幕上才是同一个颜色(用 DeviceRGB 的话宽色域屏上会偏色)。
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private let contentLayer = CALayer()
    private let strokeLayer = CALayer()
    private let baseClipLayer = CALayer()
    private let baseTextLayer = CALayer()
    private let fillClipLayer = CALayer()
    private let fillTextLayer = CALayer()

    private var spec: OverlayScrollingLyricRow.Spec?
    /// 长图(= contentLayer)的点宽 / 点高。描边开着时四周各含一圈 `inset`。
    private var boxWidth: CGFloat = 0
    private var boxHeight: CGFloat = 0
    /// 长图四周的预留 = 描边预留(开着 = `LyricsTextStrokeMetrics.inset`,同 `OptionalTextStroke` 的
    /// padding)+ 阴影出血 `bleed`。
    private var inset: CGFloat = 0
    /// 阴影出血:长图四周多留的这一圈只为了装下阴影,**不参与排版** —— 摆位时整张图往外挪
    /// 这么多,字落在跟没有阴影时同一个位置上(SwiftUI 的 `.shadow` 也不改变布局)。
    private var bleed: CGFloat = 0
    /// 放不下时的尾部渐隐:遮罩 = 左边整块不透明 + 右端一条渐隐带 + 一块盖住渐隐带的不透明「盖子」。
    /// 盖子透明 = 渐隐带生效;滚动一起步就把盖子淡入,等于收掉渐隐(同 `MarqueeText` 的规则)。
    private let fadeMask = CALayer()
    private let fadeSolid = CALayer()
    private let fadeRamp = CAGradientLayer()
    private let fadeCover = CALayer()
    private static let fadeCoverKey = "lyrimuse.overlay-marquee-fade"
    /// 逐词起止 x(长图坐标,已含 `inset`)。量宽和画字用的是同一份坐标,填色边界跟字形不会漂。
    /// 起点必须单独存:开了逐词罗马音时列宽可能比这一组的字宽,跨组时起点 ≠ 上一个词的末端。
    private var wordStartXs: [CGFloat] = []
    private var wordEndXs: [CGFloat] = []
    /// 罗马音那一行各段的落点(列起点 + 文本)。
    private var romaPlacements: [OverlayRowLayout.RomaPlacement] = []
    /// 填色路径用的逐词表。有词组时一律用词组摊平后的这一份,保证跟 `wordEndXs` 一一对应。
    private var flatWords: [SyncedLyricWord] = []
    private var mainHeight: CGFloat = 0
    private var romaHeight: CGFloat = 0
    private var readingPath: [MenuBarMarquee.KaraokeFillPoint] = []
    private var scrollPath: [MenuBarMarquee.KaraokeFillPoint] = []
    private var installedAtMs: Int?
    /// 装动画那一刻的墙钟。漂移门靠它外推"动画此刻推到哪" —— 别直接拿装动画时的歌词位置跟
    /// 新位置比,那个差会随时间自然拉开,每过一个容差就白重装一次。
    private var installedAtTime: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for l in [contentLayer, strokeLayer, baseClipLayer, baseTextLayer, fillClipLayer, fillTextLayer] {
            l.anchorPoint = .zero
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        }
        baseClipLayer.masksToBounds = true
        fillClipLayer.masksToBounds = true
        baseClipLayer.addSublayer(baseTextLayer)
        fillClipLayer.addSublayer(fillTextLayer)
        contentLayer.addSublayer(strokeLayer)
        contentLayer.addSublayer(baseClipLayer)
        contentLayer.addSublayer(fillClipLayer)
        layer?.addSublayer(contentLayer)
        for l in [fadeMask, fadeSolid, fadeRamp, fadeCover] {
            l.anchorPoint = .zero
            l.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        }
        fadeSolid.backgroundColor = NSColor.black.cgColor
        fadeCover.backgroundColor = NSColor.black.cgColor
        fadeRamp.colors = [NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeRamp.startPoint = CGPoint(x: 0, y: 0.5)
        fadeRamp.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.addSublayer(fadeSolid)
        fadeMask.addSublayer(fadeRamp)
        fadeMask.addSublayer(fadeCover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        guard spec != nil else { return }
        place(nowMs: layoutMs, reinstall: true)
    }

    /// 位图比例跟着**这个视图所在窗口**走,不猜屏(同菜单栏 `menuBarBitmapScale`)。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let spec else { return }
        rebuildImages(spec: spec)
        place(nowMs: layoutMs, reinstall: true)
    }

    /// 读此刻播放位置的入口,由 `updateNSView` 每次带进来。
    var nowProvider: (() -> Int)?

    /// 排版 / 换屏时重装动画用哪一刻:装过就沿用已装动画外推的那一刻(不打断正在跑的动画),
    /// **没装过就问真时钟**。首次 `apply` 时视图宽度常常还是 0、`place` 直接返回、一条都没装上,
    /// 这时候拿 `predictedMs`(没装过恒为 0)去装,等于按整首歌第 0 毫秒装填色 —— 这一句要等上
    /// 几十秒才开始染色。宿主刷新频繁时下一次 `apply` 的漂移判断会把它纠回来,刷新少的宿主
    /// (歌词窗口迷你那层挡了 Equatable)就一直错下去。
    private var layoutMs: Int {
        if installedAtMs == nil, let nowProvider { return nowProvider() }
        return predictedMs
    }

    func apply(spec next: OverlayScrollingLyricRow.Spec, nowMs: Int) {
        let imagesChanged = spec.map { !Self.sameImages($0, next) } ?? true
        let timingChanged = spec?.paused != next.paused || spec?.pacedWindow != next.pacedWindow
        spec = next
        if imagesChanged { rebuildImages(spec: next) }
        // 在跑时动画不在(首次装上 / 上一轮判成不用滚)要重装;停着时本来就不装动画,不算缺。
        // 配速行装得下(路径为空)本来就没有动画,也不算缺 —— 不然每次重估都白摆一遍。
        let nothingToAnimate = next.pacedWindow != nil && installedAtMs != nil && scrollPath.isEmpty
        let missing = !next.paused && !nothingToAnimate
            && contentLayer.animation(forKey: Self.scrollKey) == nil
            && fillClipLayer.animation(forKey: Self.fillKey) == nil
        guard imagesChanged || timingChanged || missing || drifted(nowMs: nowMs) else { return }
        place(nowMs: nowMs, reinstall: true)
    }

    /// 两份输入画出来的长图是不是同一张 —— 除了 `paused` / `pacedWindow` 全都一样。这两项只影响
    /// 动画,不重画位图。
    private static func sameImages(_ a: OverlayScrollingLyricRow.Spec, _ b: OverlayScrollingLyricRow.Spec) -> Bool {
        var a = a
        a.paused = b.paused
        a.pacedWindow = b.pacedWindow
        return a == b
    }

    private func drifted(nowMs: Int) -> Bool {
        guard installedAtMs != nil else { return true }
        return abs(nowMs - predictedMs) > Self.resyncToleranceMs
    }

    /// 已装的那条动画此刻推到哪一毫秒:在跑时线性外推墙钟,停着时就是装的那一刻。
    private var predictedMs: Int {
        guard let installed = installedAtMs else { return 0 }
        if spec?.paused == true { return installed }
        return installed + Int((CACurrentMediaTime() - installedAtTime) * 1000)
    }

    // MARK: - 长图

    private var bitmapScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2
    }

    /// 一行字本身的高度。必须跟 `OverlayPlayback.scrollTextHeight` 同一个式子,否则视图框和
    /// 位图对不上、字会被裁。
    private static func textHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 2
    }

    private func rebuildImages(spec: OverlayScrollingLyricRow.Spec) {
        let scale = bitmapScale
        bleed = spec.shadow.map { ceil($0.radius * 2 + abs($0.offsetY)) } ?? 0
        inset = (spec.strokeColor == nil ? 0 : LyricsTextStrokeMetrics.inset) + bleed
        mainHeight = Self.textHeight(spec.font)
        romaHeight = spec.groups == nil ? 0 : Self.textHeight(spec.romaFont)
        boxHeight = mainHeight + romaHeight + 2 * inset
        layOut(spec: spec)
        baseTextLayer.contents = drawText(spec: spec, main: spec.baseColor, roma: spec.romaBaseColor, scale: scale)
        fillTextLayer.contents = drawText(spec: spec, main: spec.fillColor, roma: spec.romaFillColor, scale: scale)
        strokeLayer.contents = spec.strokeColor.flatMap { drawStroke(spec: spec, color: $0, scale: scale) }
        for l in [strokeLayer, baseTextLayer, fillTextLayer] {
            l.contentsScale = scale
            l.position = .zero
            l.bounds = CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight)
        }
        // 阅读位置按"不含预留"的坐标算、再整体平移 inset:否则开头那一截填色边界会先在左侧预留里
        // 空走一段(followReadingPath 的首点 x 恒为 0)。
        // 配速行没有阅读位置:不填色,滚动在 `place` 里按显示窗口另算。
        readingPath = spec.pacedWindow != nil ? [] : MenuBarMarquee.followReadingPath(
            words: flatWords, wordEndXs: wordEndXs.map { $0 - inset })
            .map { MenuBarMarquee.KaraokeFillPoint(ms: $0.ms, x: $0.x + inset) }
    }

    /// 逐词 / 逐组排版:每个词的起止 x、罗马音每段的落点、长图总宽。规则在 Core 的
    /// `OverlayRowLayout`(selftest 钉着),这里只把字体测宽喂进去。
    private func layOut(spec: OverlayScrollingLyricRow.Spec) {
        let r = OverlayRowLayout.layOut(
            words: spec.words, groups: spec.groups, inset: inset,
            measureMain: { MenuBarMarqueeRenderer.width(of: $0, font: spec.font) },
            measureRoma: { MenuBarMarqueeRenderer.width(of: $0, font: spec.romaFont) })
        wordStartXs = r.wordStartXs
        wordEndXs = r.wordEndXs
        romaPlacements = r.romaPlacements
        flatWords = r.flatWords
        boxWidth = r.boxWidth
    }

    /// 一张空白长图的绘制上下文(sRGB、预乘 alpha、已按 scale 缩放到点坐标)。
    private func makeContext(scale: CGFloat) -> CGContext? {
        let pxW = Int((boxWidth * scale).rounded(.up))
        let pxH = Int((boxHeight * scale).rounded(.up))
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: pxW * 4, space: Self.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        return ctx
    }

    /// 整行字(不含描边)。
    /// `withShadow`:两张字图带上 `spec.shadow`;描边的剪影不带(否则阴影也会被阈值成描边)。
    private func drawText(spec: OverlayScrollingLyricRow.Spec,
                          main: NSColor, roma: NSColor, scale: CGFloat, withShadow: Bool = true) -> CGImage? {
        guard let ctx = makeContext(scale: scale) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        // flipped: false → 原点在左下、y 向上。主行在上、罗马音在下(同 SwiftUI 那边 VStack 的顺序),
        // 各自在自己那一格里底部留 1pt;整块再往里让出一圈 inset。
        let mainY = inset + romaHeight + 1
        let romaY = inset + 1
        var mainAttrs: [NSAttributedString.Key: Any] = [.font: spec.font, .foregroundColor: main]
        var romaAttrs: [NSAttributedString.Key: Any] = [.font: spec.romaFont, .foregroundColor: roma]
        if withShadow, let s = spec.shadow {
            // 位图坐标 y 向上,SwiftUI 的 offsetY 正值是往下,这里取反。阴影按每一笔的 alpha 投 ——
            // 跟 SwiftUI 那边 `.compositingGroup().shadow` 一样,半透明的未唱字投出来的阴影也跟着淡。
            let shadow = NSShadow()
            shadow.shadowColor = s.color
            shadow.shadowBlurRadius = s.radius
            shadow.shadowOffset = NSSize(width: 0, height: -s.offsetY)
            mainAttrs[.shadow] = shadow
            romaAttrs[.shadow] = shadow
        }
        for (i, w) in flatWords.enumerated() where i < wordStartXs.count {
            (w.text as NSString).draw(at: NSPoint(x: wordStartXs[i], y: mainY), withAttributes: mainAttrs)
        }
        for r in romaPlacements {
            (r.text as NSString).draw(at: NSPoint(x: r.x, y: romaY), withAttributes: romaAttrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// 描边:剪影高斯模糊 σ = width,透明度 ≥ alphaThreshold 的像素整片涂成描边色 —— 跟
    /// `OptionalTextStroke`(Canvas `.alphaThreshold` + `.blur(radius:)`)同一个算法、同一组参数。
    /// 模糊结果裁回长图范围,对应那边 Canvas 裁在"内容 + inset"之内。
    private func drawStroke(spec: OverlayScrollingLyricRow.Spec, color: NSColor, scale: CGFloat) -> CGImage? {
        guard let silhouette = drawText(spec: spec, main: .black, roma: .black, scale: scale, withShadow: false),
              let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let source = CIImage(cgImage: silhouette)
        let blurred = source.clampedToExtent()
            .applyingGaussianBlur(sigma: LyricsTextStrokeMetrics.width * scale)
            .cropped(to: source.extent)
        guard let soft = Self.ciContext.createCGImage(blurred, from: source.extent, format: .RGBA8,
                                                      colorSpace: Self.colorSpace),
              let ctx = CGContext(data: nil, width: soft.width, height: soft.height, bitsPerComponent: 8,
                                  bytesPerRow: soft.width * 4, space: Self.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.draw(soft, in: CGRect(x: 0, y: 0, width: soft.width, height: soft.height))
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        let alpha = rgb.alphaComponent
        let fill = (r: byte(rgb.redComponent * alpha), g: byte(rgb.greenComponent * alpha),
                    b: byte(rgb.blueComponent * alpha), a: byte(alpha))
        // 8 位下 ≥ alphaThreshold 的精确等价:0.01 × 255 = 2.55,取整到 3。
        let threshold = UInt8((LyricsTextStrokeMetrics.alphaThreshold * 255).rounded(.up))
        let count = soft.width * soft.height * 4
        let px = data.bindMemory(to: UInt8.self, capacity: count)
        for i in stride(from: 0, to: count, by: 4) {
            if px[i + 3] >= threshold {
                px[i] = fill.r; px[i + 1] = fill.g; px[i + 2] = fill.b; px[i + 3] = fill.a
            } else {
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
            }
        }
        return ctx.makeImage()
    }

    // MARK: - 摆位与动画

    private func place(nowMs: Int, reinstall: Bool) {
        guard let spec else { return }
        let viewW = bounds.width
        guard viewW > 0, boxWidth > 0 else { return }
        // 排版宽度 = 长图宽减掉两侧阴影出血。放不放得下、滚多远、静置落点都按它算;长图整体再往左
        // 挪一个 `bleed`,字就落在跟没有阴影时同一个位置(见 `bleed` 注释)。没有阴影时两者相等。
        let layoutW = boxWidth - 2 * bleed
        if let window = spec.pacedWindow {
            let chars = max(1, flatWords.reduce(0) { $0 + $1.text.count })
            scrollPath = MenuBarMarquee.pacedScrollPath(
                startMs: window.startMs, dwellMs: window.dwellMs, maxOffset: layoutW - viewW,
                averageCharWidth: (boxWidth - 2 * inset) / CGFloat(chars))
        } else {
            let reading = bleed == 0 ? readingPath
                : readingPath.map { MenuBarMarquee.KaraokeFillPoint(ms: $0.ms, x: $0.x - bleed) }
            scrollPath = MenuBarMarquee.followScrollPath(reading: reading,
                                                         windowWidth: viewW, textWidth: layoutW)
        }
        installedAtMs = nowMs
        installedAtTime = CACurrentMediaTime()
        // 装不下才滚;装得下时按对齐方式静置。溢出时一律从左起滚:靠右摆等于一上来就把开头几个字
        // 挂到可视窗外面(同 `MarqueeText.restingAlignment`)。
        let restingX: CGFloat = (layoutW <= viewW ? restingOriginX(viewWidth: viewW, layoutWidth: layoutW) : 0) - bleed
        // 静置时(暂停 / 这一句唱完、等下一句)必须摆在**此刻该在的滚动位置**,不能摆回起点:
        // 唱完那一刻 `paused` 翻 true、动画被摘掉,摆回起点就是"滚到底又跳回开头"。
        // 过了路径末尾 `karaokeFillX` 取末值(= 最大偏移),正好停在句尾。
        let offset = MenuBarMarquee.karaokeFillX(atMs: nowMs, path: scrollPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight)
        contentLayer.position = CGPoint(x: restingX - offset, y: (bounds.height - boxHeight) / 2)
        // 配速行整行都是"已唱"那张(fillColor),不走填色边界。
        applyFill(x: spec.pacedWindow != nil ? boxWidth : MenuBarMarquee.karaokeFillX(atMs: nowMs, path: readingPath))
        CATransaction.commit()
        for (layer, key) in [(contentLayer, Self.scrollKey), (fillClipLayer, Self.fillKey),
                             (baseClipLayer, Self.basePositionKey), (baseClipLayer, Self.baseBoundsKey),
                             (fadeCover, Self.fadeCoverKey)] {
            layer.removeAnimation(forKey: key)
        }
        let running = reinstall && !spec.paused
        applyEdgeFade(viewWidth: viewW, layoutWidth: layoutW, offset: offset, nowMs: nowMs, running: running)
        guard running else { return }
        installFill(nowMs: nowMs)
        installScroll(nowMs: nowMs, restingX: restingX)
    }

    private func restingOriginX(viewWidth: CGFloat, layoutWidth: CGFloat) -> CGFloat {
        switch spec?.alignment ?? .center {
        case .leading: return 0
        case .center: return (viewWidth - layoutWidth) / 2
        case .trailing: return viewWidth - layoutWidth
        }
    }

    /// 尾部渐隐(`Spec.edgeFadeWidth`)。判据同 `MarqueeMath.trailingFadeWidth`:配了宽度、放不下、
    /// 还停在起点才有;带宽封顶在可视窗的一半。在跑且此刻还在起点时,按滚动路径算出「第一次离开
    /// 起点」的那一刻,到点把盖子淡入(0.2s,同 `MarqueeText` 起步时渐隐带跟着平滑收掉)。
    private func applyEdgeFade(viewWidth: CGFloat, layoutWidth: CGFloat, offset: CGFloat,
                               nowMs: Int, running: Bool) {
        let configured = spec?.edgeFadeWidth ?? 0
        guard configured > 0, layoutWidth > viewWidth else {
            if layer?.mask != nil { layer?.mask = nil }
            return
        }
        let band = min(configured, viewWidth / 2)
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeSolid.frame = CGRect(x: 0, y: 0, width: viewWidth - band, height: h)
        fadeRamp.frame = CGRect(x: viewWidth - band, y: 0, width: band, height: h)
        fadeCover.frame = fadeRamp.frame
        let atStart = offset <= 0.5
        fadeCover.opacity = atStart ? 0 : 1
        CATransaction.commit()
        if layer?.mask !== fadeMask { layer?.mask = fadeMask }
        // 路径点之间是线性插值:真正离开起点的是「第一个非零点」的前一个点(还在 0 的最后一刻)。
        guard running, atStart,
              let firstMoving = scrollPath.firstIndex(where: { $0.x > 0.5 }) else { return }
        let leave = scrollPath[max(0, firstMoving - 1)]
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = 0
        reveal.toValue = 1
        reveal.beginTime = fadeCover.convertTime(CACurrentMediaTime(), from: nil)
            + Double(max(0, leave.ms - nowMs)) / 1000
        reveal.duration = 0.2
        reveal.fillMode = .both
        reveal.isRemovedOnCompletion = false
        fadeCover.add(reveal, forKey: Self.fadeCoverKey)
    }

    /// 互补裁剪:已唱区 [0, x] 只显示强调色那张,未唱区 [x, 末端] 只显示基础色那张。
    /// 基础色那张的裁剪层要**同时**挪 position 和 bounds.origin —— 只挪 position 的话里面的
    /// 长图会跟着一起走,字就跑了。
    private func applyFill(x: CGFloat) {
        let clamped = min(max(0, x), boxWidth)
        fillClipLayer.position = .zero
        fillClipLayer.bounds = CGRect(x: 0, y: 0, width: clamped, height: boxHeight)
        baseClipLayer.position = CGPoint(x: clamped, y: 0)
        baseClipLayer.bounds = CGRect(x: clamped, y: 0,
                                      width: max(0, boxWidth - clamped), height: boxHeight)
    }

    private func installFill(nowMs: Int) {
        guard let frames = MenuBarMarquee.karaokeFillKeyframes(path: readingPath, nowMs: nowMs, rate: 1)
        else { return }
        let widths = frames.widths.map { min(max(0, $0), boxWidth) }
        let fill = CAKeyframeAnimation(keyPath: "bounds")
        fill.values = widths.map { CGRect(x: 0, y: 0, width: $0, height: boxHeight) }
        let basePos = CAKeyframeAnimation(keyPath: "position")
        basePos.values = widths.map { CGPoint(x: $0, y: 0) }
        let baseBounds = CAKeyframeAnimation(keyPath: "bounds")
        baseBounds.values = widths.map {
            CGRect(x: $0, y: 0, width: max(0, boxWidth - $0), height: boxHeight)
        }
        for a in [fill, basePos, baseBounds] {
            a.keyTimes = frames.keyTimes.map(NSNumber.init(value:))
            a.duration = frames.duration
            a.calculationMode = .linear
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        }
        fillClipLayer.add(fill, forKey: Self.fillKey)
        baseClipLayer.add(basePos, forKey: Self.basePositionKey)
        baseClipLayer.add(baseBounds, forKey: Self.baseBoundsKey)
    }

    /// 滚动。跟填色是同一条 reading 路径派生、同一个 nowMs,两者天然同步。
    private func installScroll(nowMs: Int, restingX: CGFloat) {
        guard !scrollPath.isEmpty,
              let frames = MenuBarMarquee.karaokeFillKeyframes(path: scrollPath, nowMs: nowMs, rate: 1)
        else { return }
        let y = (bounds.height - boxHeight) / 2
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = frames.widths.map { CGPoint(x: restingX - $0, y: y) }
        move.keyTimes = frames.keyTimes.map(NSNumber.init(value:))
        move.duration = frames.duration
        move.calculationMode = .linear
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false
        contentLayer.add(move, forKey: Self.scrollKey)
    }
}
