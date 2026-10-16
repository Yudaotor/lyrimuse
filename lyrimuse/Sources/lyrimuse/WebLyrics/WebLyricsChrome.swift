import AppKit
import LyrimuseCore
import QuartzCore

/// 副屏上能点的东西。位置、尺寸、动作照歌词窗口完整布局;「…」菜单不放「前往专辑」「前往歌手」「在 XX 中显示」和「搜索歌词…」,
/// 播放记录、歌词操作胶囊、输出设备、窗口按钮这些不画。「…」菜单与它弹出的面板见 19 章决策 9。
enum WebLyricsControl: Hashable {
    case transport(WebLyricsControlsLayout.Button)
    case favorite, more
    case translation, lyricsToggle, mute
    case translationRow, romanizationRow
    case offsetReset, offsetMinus, offsetPlus
    case libraryAdd, libraryRemove, suggestLess, lastfmLove
    case showInfo, showEditorial(EditorialCard.Kind), showCharts
    case chartKind(LastfmStatsService.ChartKind), chartPeriod(LastfmStatsService.Period), chartRow(Int), chartRetry
    /// 平台页(行的 id):网页自己在手指抬起那一刻打开链接,App 这边只关菜单。
    case platform(String)
}

/// 「显示简介」面板的一行:标签 + 值;`link` 有值时值是一个可点的链接(「网页」那一行)。
struct WebLyricsInfoRow: Equatable {
    let label: String
    let value: String
    var link: URL?
}

/// 「你的常听」面板此刻的样子。
struct WebLyricsChartsState: Equatable {
    var kind: LastfmStatsService.ChartKind
    var period: LastfmStatsService.Period
    var entries: [LastfmStatsService.ChartEntry]?
    var loading: Bool
    var failed: Bool
}

/// 「…」菜单的一项,顺序同歌词窗口 `moreMenuPanel`。
enum WebLyricsMoreItem: Equatable {
    /// `trailing` 是行尾小图标(勾、重试箭头);`link` 是平台页的网址。
    case row(title: String, trailing: String?, enabled: Bool, control: WebLyricsControl, link: URL?)
    case divider
    /// 「歌词时间轴」内联控件行。
    case offset
}

/// 画副屏控件用的位图:SF Symbol、一行字。都按画面倍数画,填成一种颜色。
@MainActor
enum WebLyricsDraw {
    private static var symbolCache: [String: (image: CGImage, size: CGSize)] = [:]

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                       scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color)|\(scale)"
        if let hit = symbolCache[key] { return hit }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)),
              let made = draw(size: symbol.size, scale: scale, { rect, ctx in
                  symbol.draw(in: rect)
                  ctx.setBlendMode(.sourceIn)
                  ctx.setFillColor(color.cgColor)
                  ctx.fill(rect)
              }) else { return nil }
        if symbolCache.count > 96 { symbolCache.removeAll() }
        symbolCache[key] = (made, symbol.size)
        return (made, symbol.size)
    }

    /// 一行字。`width` 不给就按字的固有宽度画;给了放不下时末尾截成「…」。
    static func text(_ string: String, font: NSFont, color: NSColor, width: CGFloat? = nil,
                     scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color,
                                                                         .paragraphStyle: style])
        let size = CGSize(width: max(1, ceil(width ?? attributed.size().width)),
                          height: ceil(font.ascender - font.descender + font.leading))
        guard let made = draw(size: size, scale: scale, { rect, _ in
            attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }) else { return nil }
        return (made, size)
    }

    /// 一段字,按 `width` 折行;`maxLines` 给了就最多这么多行、末行截成「…」。
    static func paragraph(_ string: String, font: NSFont, color: NSColor, width: CGFloat, lineSpacing: CGFloat = 0,
                          maxLines: Int? = nil, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color,
                                                                         .paragraphStyle: style])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var bounds = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        if let maxLines {
            bounds.size.height = min(bounds.height, CGFloat(maxLines) * lineHeight + CGFloat(maxLines - 1) * lineSpacing)
        }
        let size = CGSize(width: max(1, ceil(min(width, bounds.width))), height: max(lineHeight, ceil(bounds.height)))
        guard let made = draw(size: size, scale: scale, { rect, _ in
            attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }) else { return nil }
        return (made, size)
    }

    private static func draw(size: CGSize, scale: CGFloat, _ body: (CGRect, CGContext) -> Void) -> CGImage? {
        let pw = Int(ceil(size.width * scale)), ph = Int(ceil(size.height * scale))
        guard pw > 0, ph > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(CGRect(origin: .zero, size: size), ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// 图层摆一张位图,中心落在 `center`。
    static func place(_ layer: CALayer, _ made: (image: CGImage, size: CGSize)?, center: CGPoint, scale: CGFloat) {
        guard let made else {
            layer.contents = nil
            return
        }
        layer.contents = made.image
        layer.contentsScale = scale
        layer.bounds = CGRect(origin: .zero, size: made.size)
        layer.position = center
    }

    /// 按下的反馈:缩到 `to` 再弹回(同歌词窗口按钮样式的按下缩放)。
    static func press(_ layers: [CALayer], to scale: CGFloat) {
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1, scale, 1 + (1 - scale) * 0.2, 1]
        pulse.keyTimes = [0, 0.24, 0.62, 1]
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(name: .easeInEaseOut)]
        pulse.duration = 0.42
        for l in layers { l.add(pulse, forKey: "press") }
    }

    static func noActions(_ layers: [CALayer]) {
        for l in layers {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(),
                         "hidden": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(),
                         "cornerRadius": NSNull(), "transform": NSNull(), "sublayers": NSNull()]
        }
    }
}

/// 一行跑马灯(歌名、歌手行),照 `LayerMarquee`:装不下就按 `MarqueeCycle` 滚,左端渐隐随滚出去的距离长出来、
/// 右端渐隐只在停在开头时有;装得下就不动。内容是画好的一行字。
@MainActor
final class WebLyricsMarqueeLayer: CALayer {
    private static let scrollKey = "lyrimuse.web-marquee-scroll"
    private static let fadeKey = "lyrimuse.web-marquee-fade"

    private let scroller = CALayer()
    private let content = CALayer()
    private let fadeMask = CAGradientLayer()
    private var shownKey = ""
    private var leadingFadeWidth: CGFloat = 0
    private var edgeFadeWidth: CGFloat = 0

    override init() {
        super.init()
        addSublayer(scroller)
        scroller.addSublayer(content)
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask = fadeMask
        WebLyricsDraw.noActions([self, scroller, content, fadeMask])
        fadeMask.actions = ["locations": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, font: NSFont, color: NSColor, frame: CGRect, scale: CGFloat, leadingFade: CGFloat,
              trailingFade: CGFloat, animating: Bool) {
        let key = "\(text)|\(font)|\(color)|\(frame.size)|\(scale)|\(animating)"
        self.frame = frame
        guard key != shownKey else { return }
        shownKey = key
        leadingFadeWidth = leadingFade
        edgeFadeWidth = trailingFade
        let made = WebLyricsDraw.text(text, font: font, color: color, scale: scale)
        let contentSize = made?.size ?? .zero
        scroller.frame = bounds
        content.contents = made?.image
        content.contentsScale = scale
        content.frame = CGRect(x: 0, y: ((bounds.height - contentSize.height) / 2).rounded(),
                               width: contentSize.width, height: contentSize.height)
        scroller.removeAnimation(forKey: Self.scrollKey)
        fadeMask.removeAnimation(forKey: Self.fadeKey)
        let resting = MarqueeMath.trailingFadeWidth(configured: edgeFadeWidth, contentWidth: contentSize.width,
                                                    containerWidth: bounds.width, offset: 0)
        fadeMask.frame = bounds
        fadeMask.locations = locations(leading: 0, trailing: resting)
        guard animating,
              let cycle = MarqueeMath.cycle(contentWidth: contentSize.width, containerWidth: bounds.width) else { return }
        let move = CAKeyframeAnimation(keyPath: "sublayerTransform.translation.x")
        move.values = cycle.offsets.map { NSNumber(value: Double(-$0)) }
        move.keyTimes = cycle.keyTimes.map { NSNumber(value: $0) }
        let fades = cycle.fadeKeyframes(leading: leadingFadeWidth, trailing: resting)
        let fade = CAKeyframeAnimation(keyPath: "locations")
        fade.values = zip(fades.leading, fades.trailing).map { locations(leading: $0, trailing: $1) }
        fade.keyTimes = fades.keyTimes.map { NSNumber(value: $0) }
        for animation in [move, fade] {
            animation.duration = cycle.period
            animation.repeatCount = .infinity
            animation.calculationMode = .linear
            animation.timeOffset = cycle.firstCycleTimeOffset
        }
        scroller.add(move, forKey: Self.scrollKey)
        fadeMask.add(fade, forKey: Self.fadeKey)
    }

    private func locations(leading: CGFloat, trailing: CGFloat) -> [NSNumber] {
        let width = max(bounds.width, 1)
        let lead = min(max(leading, 0), width) / width
        let tail = max(lead, (width - trailing) / width)
        return [0, lead, tail, 1].map { NSNumber(value: Double($0)) }
    }
}

/// 浮在内容之上的控件:右上音量胶囊、右下翻译钮与歌词钮、翻译菜单与「…」菜单。位置、尺寸照歌词窗口完整布局
/// (各段数值见对应 SwiftUI 视图:`WindowVolumeCapsule`、`translationButtonLabel`、`lyricsQueuePill`、
/// `translationMenuPanel`、`lyricsOffsetRow`)。液态玻璃采样的是窗口背后的东西,离屏画不出来,胶囊和菜单底用
/// 半透明底加发丝边近似。坐标 y 向下。
@MainActor
final class WebLyricsChromeLayer: CALayer {
    enum Menu: Equatable { case none, translation, more, info, editorial(EditorialCard.Kind), charts }

    struct State: Equatable {
        var onArtwork: Bool
        /// 有封面背景时白,没有时系统前景色(已按当前外观解析)。
        var primary: NSColor
        /// 浅色外观、又没有封面背景时菜单走浅色。
        var darkPanels: Bool
        /// nil = 这个播放器读不到音量,不画胶囊。
        var volume: Int?
        var showsTranslationButton: Bool
        var translationActive: Bool
        var showsLyricsToggle: Bool
        var lyricsShown: Bool
        var menu: Menu
        var hasTranslation: Bool
        var hasRomanization: Bool
        var showTranslation: Bool
        var showRomanization: Bool
        var offsetMs: Int
        /// 「…」按钮在整幅画面里的框,「…」菜单从它右缘往右长出。
        var moreAnchor: CGRect?
        var moreItems: [WebLyricsMoreItem]
        var infoRows: [WebLyricsInfoRow]
        var editorialCard: EditorialCard?
        var charts: WebLyricsChartsState?
        /// 简介正文滚到哪了(点)。
        var panelScroll: CGFloat
        /// 系统强调色(链接、分段控件选中那一格)。
        var accent: NSColor
        /// 右下一排往上抬多少(手机那种排法给底部的播放条让位)。
        var bottomInset: CGFloat
        var size: CGSize
        var scale: CGFloat
    }

    private let volumeGroup = CALayer()
    private let volumeCapsule = CALayer()
    private let volumeTrack = CALayer()
    private let volumeFill = CALayer()
    private let volumeKnob = CALayer()
    private let speaker = CALayer()

    private let bottomGroup = CALayer()
    private let translationCircle = CALayer()
    private let translationGlyph = CALayer()
    private let lyricsCapsule = CALayer()
    private let lyricsSlot = CALayer()
    private let lyricsGlyph = CALayer()

    private let panel = CALayer()
    private var panelItems: [CALayer] = []

    private(set) var state: State?
    private var hits: [(WebLyricsControl, CGRect)] = []
    /// 菜单里平台页那几行的框(整幅画面坐标)和网址,告诉网页哪一块点了要开哪个链接。
    private(set) var linkTargets: [(rect: CGRect, url: URL)] = []
    /// 简介正文那块能拖着滚的区域(整幅画面坐标)和最多滚多远。
    private(set) var scrollArea: (rect: CGRect, maxScroll: CGFloat)?
    /// 音量滑杆可拖的那一段(滑块中心能走到的范围)与它的命中框。
    private var sliderTravel: (minX: CGFloat, width: CGFloat, hit: CGRect)?

    override init() {
        super.init()
        isGeometryFlipped = true
        addSublayer(volumeGroup)
        for l in [volumeCapsule, volumeTrack, volumeFill, volumeKnob, speaker] { volumeGroup.addSublayer(l) }
        addSublayer(bottomGroup)
        for l in [translationCircle, translationGlyph, lyricsCapsule, lyricsSlot, lyricsGlyph] { bottomGroup.addSublayer(l) }
        addSublayer(panel)
        WebLyricsDraw.noActions([self, volumeGroup, volumeCapsule, volumeTrack, volumeFill, volumeKnob, speaker, bottomGroup,
                                 translationCircle, translationGlyph, lyricsCapsule, lyricsSlot, lyricsGlyph, panel])
        volumeKnob.backgroundColor = NSColor.white.cgColor
        volumeKnob.shadowColor = NSColor.black.cgColor
        volumeKnob.shadowOpacity = 0.25
        volumeKnob.shadowRadius = 1.5
        volumeKnob.shadowOffset = CGSize(width: 0, height: 0.5)
        panel.cornerCurve = .continuous
        panel.cornerRadius = 18
        panel.shadowColor = NSColor.black.cgColor
        panel.shadowOpacity = 0.35
        panel.shadowRadius = 24
        panel.shadowOffset = CGSize(width: 0, height: 10)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - 命中

    func control(at point: CGPoint) -> WebLyricsControl? {
        hits.last { $0.1.contains(point) }?.0
    }

    /// 点在音量滑杆上时,这一点对应的音量(0…100)。
    func volume(at point: CGPoint, requireHit: Bool) -> Int? {
        guard let travel = sliderTravel, travel.width > 0, !requireHit || travel.hit.contains(point) else { return nil }
        let x = min(travel.width, max(0, point.x - travel.minX))
        return Int((x / travel.width * 100).rounded())
    }

    func menuContains(_ point: CGPoint) -> Bool {
        !panel.isHidden && panel.frame.contains(point)
    }

    // MARK: - 闲置隐藏

    /// 音量胶囊和右下一排跟着「闲置隐藏」淡入淡出(时长同 `LyricsWindowChromeIdle`)。菜单开着时不收。
    func setChromeVisible(_ visible: Bool, animated: Bool) {
        let target: Float = visible ? 1 : 0
        for layer in [volumeGroup, bottomGroup] {
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = target
            guard animated, from != target else { continue }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from
            a.toValue = target
            a.duration = visible ? LyricsWindowChromeIdle.fadeInSeconds : LyricsWindowChromeIdle.fadeOutSeconds
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "lyrimuse.web-chrome-fade")
        }
    }

    func press(_ control: WebLyricsControl) {
        switch control {
        case .translation: WebLyricsDraw.press([translationCircle, translationGlyph], to: 0.9)
        case .lyricsToggle: WebLyricsDraw.press([lyricsCapsule, lyricsSlot, lyricsGlyph], to: 0.9)
        case .mute: WebLyricsDraw.press([speaker], to: 0.9)
        default: break
        }
    }

    // MARK: - 布局

    func apply(_ s: State) {
        state = s
        hits = []
        linkTargets = []
        scrollArea = nil
        sliderTravel = nil
        let rim = s.onArtwork ? NSColor.white.withAlphaComponent(0.28) : s.primary.withAlphaComponent(0.10)
        let iconColor = s.onArtwork ? NSColor.white.withAlphaComponent(0.9) : s.primary.withAlphaComponent(0.75)
        layoutVolume(s, rim: rim, iconColor: iconColor)
        layoutBottomRow(s, rim: rim, iconColor: iconColor)
        layoutPanel(s)
    }

    private func glass(_ layer: CALayer, frame: CGRect, rim: NSColor, onArtwork: Bool) {
        layer.frame = frame
        layer.cornerRadius = frame.height / 2
        layer.backgroundColor = (onArtwork ? NSColor.white.withAlphaComponent(0.10)
                                           : NSColor.black.withAlphaComponent(0.04)).cgColor
        layer.borderWidth = 0.5
        layer.borderColor = rim.cgColor
    }

    /// 右上音量胶囊:贴右缘 5、顶 8,高 36;滑杆 114 宽、轨道 6、已填段与滑块连成一体,滑块 23×14;右边喇叭 17pt、
    /// 格宽 24 左对齐,点了静音。AirPlay 键(弹输出设备面板)不画。
    private func layoutVolume(_ s: State, rim: NSColor, iconColor: NSColor) {
        guard let volume = s.volume else {
            volumeGroup.isHidden = true
            return
        }
        volumeGroup.isHidden = false
        let width: CGFloat = 14 + 114 + 10 + 24 + 14
        let capsule = CGRect(x: s.size.width - 5 - width, y: 8, width: width, height: 36)
        volumeGroup.frame = CGRect(origin: .zero, size: s.size)
        glass(volumeCapsule, frame: capsule, rim: rim, onArtwork: s.onArtwork)
        let slider = CGRect(x: capsule.minX + 14, y: capsule.minY + 7, width: 114, height: 22)
        let knob: CGFloat = 23, knobHeight: CGFloat = 14, track: CGFloat = 6
        let travel = slider.width - knob
        let f = CGFloat(min(1, max(0, Double(volume) / 100)))
        volumeTrack.frame = CGRect(x: slider.minX, y: slider.midY - track / 2, width: slider.width, height: track)
        volumeTrack.cornerRadius = track / 2
        volumeTrack.backgroundColor = (s.onArtwork ? NSColor.white.withAlphaComponent(0.20)
                                                   : s.primary.withAlphaComponent(0.14)).cgColor
        volumeFill.frame = CGRect(x: slider.minX, y: volumeTrack.frame.minY, width: knob / 2 + travel * f, height: track)
        volumeFill.cornerRadius = track / 2
        volumeFill.backgroundColor = (s.onArtwork ? NSColor.white.withAlphaComponent(0.80)
                                                  : s.primary.withAlphaComponent(0.55)).cgColor
        volumeKnob.frame = CGRect(x: slider.minX + travel * f, y: slider.midY - knobHeight / 2, width: knob, height: knobHeight)
        volumeKnob.cornerRadius = knobHeight / 2
        sliderTravel = (slider.minX + knob / 2, travel, slider.insetBy(dx: 0, dy: -7))
        let icon: String
        switch volume {
        case 0: icon = "speaker.slash.fill"
        case 1...33: icon = "speaker.wave.1.fill"
        case 34...66: icon = "speaker.wave.2.fill"
        default: icon = "speaker.wave.3.fill"
        }
        let speakerCell = CGRect(x: slider.maxX + 10, y: slider.minY, width: 24, height: 22)
        let glyph = WebLyricsDraw.symbol(icon, size: 17, color: iconColor, scale: s.scale)
        WebLyricsDraw.place(speaker, glyph,
                            center: CGPoint(x: speakerCell.minX + (glyph?.size.width ?? 0) / 2, y: speakerCell.midY),
                            scale: s.scale)
        hits.append((.mute, speakerCell.insetBy(dx: -4, dy: -7)))
    }

    /// 右下一排:贴右 10、底 11;最右是 [歌词] 胶囊(36 高、一格 30 圆,显示着歌词时是白圆 + 深色字形),
    /// 左边隔 8.5 是 36 圆的翻译钮(译文正在显示时是白圆 + 深色字形)。播放记录那一格、歌词操作胶囊不画。
    private func layoutBottomRow(_ s: State, rim: NSColor, iconColor: NSColor) {
        bottomGroup.frame = CGRect(origin: .zero, size: s.size)
        let y = s.size.height - 11 - 36 - s.bottomInset
        var right = s.size.width - 10
        lyricsCapsule.isHidden = !s.showsLyricsToggle
        lyricsSlot.isHidden = !s.showsLyricsToggle
        lyricsGlyph.isHidden = !s.showsLyricsToggle
        if s.showsLyricsToggle {
            let capsule = CGRect(x: right - 36, y: y, width: 36, height: 36)
            glass(lyricsCapsule, frame: capsule, rim: rim, onArtwork: s.onArtwork)
            lyricsSlot.frame = capsule.insetBy(dx: 3, dy: 3)
            lyricsSlot.cornerRadius = 15
            lyricsSlot.backgroundColor = s.lyricsShown ? NSColor.white.withAlphaComponent(0.84).cgColor : nil
            let color = s.lyricsShown ? NSColor.black.withAlphaComponent(0.75) : iconColor
            WebLyricsDraw.place(lyricsGlyph, WebLyricsDraw.symbol("quote.bubble.fill", size: 14, weight: .semibold,
                                                                  color: color, scale: s.scale),
                                center: CGPoint(x: capsule.midX, y: capsule.midY), scale: s.scale)
            hits.append((.lyricsToggle, capsule))
            right = capsule.minX - 8.5
        }
        translationCircle.isHidden = !s.showsTranslationButton
        translationGlyph.isHidden = !s.showsTranslationButton
        if s.showsTranslationButton {
            let circle = CGRect(x: right - 36, y: y, width: 36, height: 36)
            if s.translationActive {
                translationCircle.frame = circle
                translationCircle.cornerRadius = 18
                translationCircle.backgroundColor = NSColor.white.withAlphaComponent(0.84).cgColor
                translationCircle.borderWidth = 0
            } else {
                glass(translationCircle, frame: circle, rim: rim, onArtwork: s.onArtwork)
            }
            let color = s.translationActive ? NSColor.black.withAlphaComponent(0.75) : iconColor
            WebLyricsDraw.place(translationGlyph, WebLyricsDraw.symbol("translate", size: 16, weight: .semibold,
                                                                       color: color, scale: s.scale),
                                center: CGPoint(x: circle.midX, y: circle.midY), scale: s.scale)
            hits.append((.translation, circle))
        }
    }

    /// 两个菜单同一种底:圆角 18、发丝边、投影;有封面背景时强制深色。内边距 6、行间 2;行是 14pt 字、
    /// 左右 10 上下 7,行尾小图标 11pt 半粗(`MoreMenuRow`),不可点的行压暗到 0.55;分隔线左右缩 6、上下各 2
    /// (`menuDivider`)。翻译菜单右缘对齐翻译钮、悬在它上方 8;「…」菜单按 `panelFrame` 摆,最少 200 宽,
    /// 末行「歌词时间轴」(`lyricsOffsetRow`:左右 10 上下 5,± 与重置钮 24×22 圆角 6)。
    private func layoutPanel(_ s: State) {
        for l in panelItems { l.removeFromSuperlayer() }
        panelItems = []
        guard s.menu != .none else {
            panel.isHidden = true
            return
        }
        panel.isHidden = false
        let ink = s.darkPanels ? NSColor.white : NSColor.black.withAlphaComponent(0.85)
        let secondaryInk = ink.withAlphaComponent(s.darkPanels ? 0.6 : 0.5)
        panel.backgroundColor = (s.darkPanels ? NSColor(white: 0.13, alpha: 0.82) : NSColor(white: 0.97, alpha: 0.9)).cgColor
        panel.borderWidth = 0.5
        panel.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        let rowFont = NSFont.systemFont(ofSize: 14)
        let rowHeight = ceil(rowFont.ascender - rowFont.descender + rowFont.leading) + 14

        func item(_ made: (image: CGImage, size: CGSize)?, at origin: CGPoint) {
            let l = CALayer()
            WebLyricsDraw.noActions([l])
            l.contents = made?.image
            l.contentsScale = s.scale
            l.frame = CGRect(origin: origin, size: made?.size ?? .zero)
            panel.addSublayer(l)
            panelItems.append(l)
        }

        switch s.menu {
        case .translation:
            let rows: [(String, Bool, WebLyricsControl)] = [
                (L10n.t(s.showTranslation ? "隐藏译文" : "显示译文"), s.hasTranslation, .translationRow),
                (L10n.t(s.showRomanization ? "隐藏读音" : "显示读音"), s.hasRomanization, .romanizationRow),
            ]
            let texts = rows.map { WebLyricsDraw.text($0.0, font: rowFont, color: ink.withAlphaComponent($0.1 ? 1 : 0.55),
                                                      scale: s.scale) }
            let width = max(150, (texts.map { $0?.size.width ?? 0 }.max() ?? 0) + 20 + 12)
            let height = 6 + rowHeight * 2 + 2 + 6
            guard let anchor = hits.first(where: { $0.0 == .translation })?.1 else {
                panel.isHidden = true
                return
            }
            panel.frame = CGRect(x: anchor.maxX - width, y: anchor.minY - 8 - height, width: width, height: height)
            for (i, row) in rows.enumerated() {
                let top = 6 + CGFloat(i) * (rowHeight + 2)
                item(texts[i], at: CGPoint(x: 6 + 10, y: top + 7))
                if row.1 {
                    hits.append((row.2, CGRect(x: panel.frame.minX + 6, y: panel.frame.minY + top,
                                               width: width - 12, height: rowHeight)))
                }
            }
        case .more, .info, .editorial, .charts:
            guard let anchor = s.moreAnchor else {
                panel.isHidden = true
                return
            }
            switch s.menu {
            case .info: layoutInfoPanel(s, anchor: anchor, ink: ink, secondaryInk: secondaryInk, place: item)
            case .editorial: layoutEditorialPanel(s, anchor: anchor, ink: ink, secondaryInk: secondaryInk, place: item)
            case .charts: layoutChartsPanel(s, anchor: anchor, ink: ink, secondaryInk: secondaryInk, place: item)
            default:
                layoutMoreMenu(s, anchor: anchor, ink: ink, secondaryInk: secondaryInk, rowFont: rowFont, rowHeight: rowHeight,
                               place: item)
            }
        case .none:
            break
        }
    }

    private func layoutMoreMenu(_ s: State, anchor: CGRect, ink: NSColor, secondaryInk: NSColor, rowFont: NSFont,
                                rowHeight: CGFloat, place item: ((image: CGImage, size: CGSize)?, CGPoint) -> Void) {
        struct Placed {
            let item: WebLyricsMoreItem
            let text: (image: CGImage, size: CGSize)?
            let icon: (image: CGImage, size: CGSize)?
            let height: CGFloat
        }
        let label = WebLyricsDraw.text(L10n.t("歌词时间轴"), font: rowFont, color: ink, scale: s.scale)
        let value = s.offsetMs != 0
            ? WebLyricsDraw.text(AppSettings.signedSeconds(ms: s.offsetMs) + "s",
                                 font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: secondaryInk,
                                 scale: s.scale)
            : nil
        var buttons: [(String, WebLyricsControl)] = []
        if s.offsetMs != 0 { buttons.append(("arrow.counterclockwise", .offsetReset)) }
        buttons += [("minus", .offsetMinus), ("plus", .offsetPlus)]
        let buttonsWidth = CGFloat(buttons.count) * 24 + CGFloat(buttons.count - 1) * 4
        // 菜单宽度按出现「重置」、数值最长时留足:偏移一变菜单就变宽的话,右锚定的 ± 跟着右移,连点「＋」第二下落到别处
        // (同歌词窗口 `lyricsOffsetRow`)。
        let widestValue = [10_250, -10_250].map { ms in
            ceil((AppSettings.signedSeconds(ms: ms) + "s" as NSString)
                .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]).width)
        }.max() ?? 0
        let widestButtons: CGFloat = 3 * 24 + 2 * 4
        let offsetInner = max(22, rowHeight - 14)
        var placed: [Placed] = []
        var width: CGFloat = 200
        for entry in s.moreItems {
            switch entry {
            case let .row(title, trailing, enabled, _, _):
                let color = ink.withAlphaComponent(enabled ? 1 : 0.55)
                let text = WebLyricsDraw.text(title, font: rowFont, color: color, scale: s.scale)
                let icon = trailing.flatMap {
                    WebLyricsDraw.symbol($0, size: 11, weight: .semibold,
                                         color: secondaryInk.withAlphaComponent(enabled ? secondaryInk.alphaComponent : 0.3),
                                         scale: s.scale)
                }
                width = max(width, 12 + 20 + (text?.size.width ?? 0) + (icon.map { 6 + $0.size.width } ?? 0))
                placed.append(Placed(item: entry, text: text, icon: icon, height: rowHeight))
            case .divider:
                placed.append(Placed(item: entry, text: nil, icon: nil, height: 5))
            case .offset:
                let labelWidth = (label?.size.width ?? 0) + 4 + max(value?.size.width ?? 0, widestValue)
                width = max(width, 6 + 10 + labelWidth + 4 + 16 + 4 + widestButtons + 10 + 6)
                placed.append(Placed(item: entry, text: nil, icon: nil, height: offsetInner + 10))
            }
        }
        let height = 12 + placed.map(\.height).reduce(0, +) + CGFloat(max(0, placed.count - 1)) * 2
        panel.frame = panelFrame(width: width, height: height, anchor: anchor, in: s.size)
        var top: CGFloat = 6
        for p in placed {
            switch p.item {
            case let .row(_, _, enabled, control, link):
                if let text = p.text { item(text, CGPoint(x: 16, y: (top + (p.height - text.size.height) / 2).rounded())) }
                if let icon = p.icon {
                    item(icon, CGPoint(x: width - 16 - icon.size.width, y: (top + (p.height - icon.size.height) / 2).rounded()))
                }
                let rect = CGRect(x: panel.frame.minX + 6, y: panel.frame.minY + top, width: width - 12, height: p.height)
                if enabled { hits.append((control, rect)) }
                if let link { linkTargets.append((rect, link)) }
            case .divider:
                let line = CALayer()
                WebLyricsDraw.noActions([line])
                line.frame = CGRect(x: 12, y: top + 2, width: width - 24, height: 1)
                line.backgroundColor = ink.withAlphaComponent(0.12).cgColor
                panel.addSublayer(line)
                panelItems.append(line)
            case .offset:
                let midY = top + p.height / 2
                if let label { item(label, CGPoint(x: 16, y: (midY - label.size.height / 2).rounded())) }
                if let value, let label {
                    item(value, CGPoint(x: 16 + label.size.width + 4, y: (midY - value.size.height / 2).rounded()))
                }
                var x = width - 6 - 10 - buttonsWidth
                for (symbol, control) in buttons {
                    let box = CALayer()
                    WebLyricsDraw.noActions([box])
                    box.frame = CGRect(x: x, y: midY - 11, width: 24, height: 22)
                    box.cornerRadius = 6
                    box.cornerCurve = .continuous
                    box.backgroundColor = ink.withAlphaComponent(0.07).cgColor
                    panel.addSublayer(box)
                    panelItems.append(box)
                    let glyph = CALayer()
                    WebLyricsDraw.noActions([glyph])
                    WebLyricsDraw.place(glyph, WebLyricsDraw.symbol(symbol, size: 11, weight: .semibold, color: ink,
                                                                    scale: s.scale),
                                        center: CGPoint(x: box.frame.midX, y: box.frame.midY), scale: s.scale)
                    panel.addSublayer(glyph)
                    panelItems.append(glyph)
                    hits.append((control, box.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
                        .insetBy(dx: -2, dy: -6)))
                    x += 28
                }
            }
            top += p.height + 2
        }
    }


    /// 「…」菜单和它弹出的面板:从「…」右缘往右长出、悬在它上方 8;上方放不下就挂在它下方 8(竖排时「…」在画面顶上
    /// 那一块),上下都放不下时贴着画面上沿;右边超出画面时往左挪回来。
    private func panelFrame(width: CGFloat, height: CGFloat, anchor: CGRect, in size: CGSize) -> CGRect {
        let x = max(8, min(anchor.maxX, size.width - 8 - width))
        let above = anchor.minY - 8 - height
        let below = anchor.maxY + 8
        let y = above >= 8 ? above : (below + height <= size.height - 8 ? below : 8)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 「显示简介」(`trackInfoPanel`):内边距 12、行间 6,宽 240…360;标签 12pt、52 宽,值 13pt 中粗、放不下折行;
    /// 「网页」那一行的值是强调色的「平台名 ↗」,点了在看副屏的那台设备上打开。
    private func layoutInfoPanel(_ s: State, anchor: CGRect, ink: NSColor, secondaryInk: NSColor,
                                 place item: ((image: CGImage, size: CGSize)?, CGPoint) -> Void) {
        let labelFont = NSFont.systemFont(ofSize: 12)
        let valueFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let natural = s.infoRows.map { row in
            52 + 10 + ceil(NSAttributedString(string: row.value + (row.link == nil ? "" : " ↗"),
                                              attributes: [.font: valueFont]).size().width)
        }.max() ?? 0
        let width = min(360, max(240, natural + 24))
        let valueWidth = width - 24 - 62
        var laid: [(label: (image: CGImage, size: CGSize)?, value: (image: CGImage, size: CGSize)?, row: WebLyricsInfoRow)] = []
        for row in s.infoRows {
            let label = WebLyricsDraw.text(row.label, font: labelFont, color: secondaryInk, scale: s.scale)
            let value = row.link == nil
                ? WebLyricsDraw.paragraph(row.value, font: valueFont, color: ink, width: valueWidth, scale: s.scale)
                : WebLyricsDraw.text(row.value + " ↗", font: valueFont, color: s.accent, width: min(valueWidth,
                                     ceil(NSAttributedString(string: row.value + " ↗", attributes: [.font: valueFont]).size().width)),
                                     scale: s.scale)
            laid.append((label, value, row))
        }
        let heights = laid.map { max($0.label?.size.height ?? 0, $0.value?.size.height ?? 0) }
        let height = 24 + heights.reduce(0, +) + CGFloat(max(0, laid.count - 1)) * 6
        panel.frame = panelFrame(width: width, height: height, anchor: anchor, in: s.size)
        let baselineShift = (valueFont.ascender - labelFont.ascender).rounded()
        var top: CGFloat = 12
        for (i, entry) in laid.enumerated() {
            item(entry.label, CGPoint(x: 12, y: top + baselineShift))
            item(entry.value, CGPoint(x: 12 + 62, y: top))
            if let url = entry.row.link, let size = entry.value?.size {
                let rect = CGRect(x: panel.frame.minX + 74, y: panel.frame.minY + top, width: size.width, height: size.height)
                linkTargets.append((rect.insetBy(dx: -4, dy: -6), url))
            }
            top += heights[i] + 6
        }
    }

    /// 歌曲 / 歌手 / 专辑简介(`EditorialNotesContent`):宽 340、内边距 14、段间 8;标题 13pt 半粗最多两行,副标题 11pt;
    /// 「标签 / 值」10pt 中粗 / 12pt;正文 12pt、行距 3,超过 400 字放进 260 高的区域、手指拖着滚;末尾 10pt 出处。
    private func layoutEditorialPanel(_ s: State, anchor: CGRect, ink: NSColor, secondaryInk: NSColor,
                                      place item: ((image: CGImage, size: CGSize)?, CGPoint) -> Void) {
        guard let card = s.editorialCard else {
            panel.isHidden = true
            return
        }
        let width: CGFloat = 340, inner = width - 28
        var blocks: [(made: (image: CGImage, size: CGSize)?, gapBefore: CGFloat)] = []
        blocks.append((WebLyricsDraw.paragraph(card.title, font: .systemFont(ofSize: 13, weight: .semibold), color: ink,
                                               width: inner, maxLines: 2, scale: s.scale), 0))
        if !card.subtitle.isEmpty {
            blocks.append((WebLyricsDraw.text(card.subtitle, font: .systemFont(ofSize: 11), color: secondaryInk, width: inner,
                                              scale: s.scale), 2))
        }
        for (i, fact) in card.facts.enumerated() {
            blocks.append((WebLyricsDraw.text(fact.label, font: .systemFont(ofSize: 10, weight: .medium), color: secondaryInk,
                                              width: inner, scale: s.scale), i == 0 ? 8 : 6))
            blocks.append((WebLyricsDraw.paragraph(fact.value, font: .systemFont(ofSize: 12), color: ink, width: inner,
                                                   scale: s.scale), 1))
        }
        let body = WebLyricsDraw.paragraph(card.text, font: .systemFont(ofSize: 12), color: ink.withAlphaComponent(0.9),
                                           width: inner, lineSpacing: 3, scale: s.scale)
        let bodyHeight = body?.size.height ?? 0
        let scrolls = card.text.count > 400
        let bodyBox = scrolls ? min(260, bodyHeight) : bodyHeight
        let attribution = card.source.attribution.flatMap {
            WebLyricsDraw.text($0, font: .systemFont(ofSize: 10), color: secondaryInk, width: inner, scale: s.scale)
        }
        let headHeight = blocks.reduce(CGFloat(0)) { $0 + $1.gapBefore + ($1.made?.size.height ?? 0) }
        let height = 14 + headHeight + 8 + bodyBox + (attribution.map { 8 + $0.size.height } ?? 0) + 14
        panel.frame = panelFrame(width: width, height: height, anchor: anchor, in: s.size)
        var top: CGFloat = 14
        for block in blocks {
            top += block.gapBefore
            item(block.made, CGPoint(x: 14, y: top))
            top += block.made?.size.height ?? 0
        }
        top += 8
        let clip = CALayer()
        WebLyricsDraw.noActions([clip])
        clip.frame = CGRect(x: 14, y: top, width: inner, height: bodyBox)
        clip.masksToBounds = true
        let text = CALayer()
        WebLyricsDraw.noActions([text])
        let maxScroll = max(0, bodyHeight - bodyBox)
        let offset = min(max(s.panelScroll, 0), maxScroll)
        text.contents = body?.image
        text.contentsScale = s.scale
        text.frame = CGRect(x: 0, y: -offset, width: body?.size.width ?? 0, height: bodyHeight)
        clip.addSublayer(text)
        panel.addSublayer(clip)
        panelItems.append(clip)
        if maxScroll > 0 {
            scrollArea = (clip.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY), maxScroll)
        }
        top += bodyBox
        if let attribution { item(attribution, CGPoint(x: 14, y: top + 8)) }
    }

    /// 「你的常听」(`ChartsPanelView`):宽 300、内边距 10、段间 8;小标题 11pt 半粗;两排分段(`SettingsPillSegmentedControl`:
    /// 12pt,选中那格强调色底白字半粗,每格最少 52 宽、左右 6 上下 4,格间 2,外圈 2 的淡底);下面最多 10 行
    /// (名次 11pt 半粗右对齐 18 宽,名字 12.5pt、副行 10.5pt,右边「N 次」11pt,左右 6 上下 4),点一行在 Mac 上的
    /// Apple Music 里打开;没取到时是加载中 / 重试 / 暂无数据。
    private func layoutChartsPanel(_ s: State, anchor: CGRect, ink: NSColor, secondaryInk: NSColor,
                                   place item: ((image: CGImage, size: CGSize)?, CGPoint) -> Void) {
        guard let charts = s.charts else {
            panel.isHidden = true
            return
        }
        let width: CGFloat = 300, inner = width - 20
        var rows: [(rank: (image: CGImage, size: CGSize)?, name: (image: CGImage, size: CGSize)?,
                    detail: (image: CGImage, size: CGSize)?, count: (image: CGImage, size: CGSize)?, height: CGFloat)] = []
        let entries = Array((charts.entries ?? []).prefix(10))
        for entry in entries {
            let count = WebLyricsDraw.text(String(format: L10n.t("%@ 次"), "\(entry.playcount)"),
                                           font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: secondaryInk,
                                           scale: s.scale)
            let textWidth = max(40, inner - 12 - 18 - 8 - 8 - (count?.size.width ?? 0))
            let name = WebLyricsDraw.text(entry.name, font: .systemFont(ofSize: 12.5), color: ink, width: textWidth, scale: s.scale)
            let detail = entry.detail.isEmpty ? nil
                : WebLyricsDraw.text(entry.detail, font: .systemFont(ofSize: 10.5), color: secondaryInk, width: textWidth,
                                     scale: s.scale)
            let rank = WebLyricsDraw.text("\(entry.rank)", font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                          color: secondaryInk, scale: s.scale)
            let h = 8 + (name?.size.height ?? 0) + (detail.map { 1 + $0.size.height } ?? 0)
            rows.append((rank, name, detail, count, h))
        }
        let title = WebLyricsDraw.text(L10n.t("你的常听"), font: .systemFont(ofSize: 11, weight: .semibold), color: secondaryInk,
                                       scale: s.scale)
        let pillHeight: CGFloat = 2 + 4 + ceil(NSFont.systemFont(ofSize: 12).ascender - NSFont.systemFont(ofSize: 12).descender) + 4 + 2
        let contentHeight: CGFloat = rows.isEmpty ? 48 : rows.map(\.height).reduce(0, +)
        let height = 10 + (title?.size.height ?? 0) + 8 + pillHeight + 8 + pillHeight + 8 + contentHeight + 10
        panel.frame = panelFrame(width: width, height: height, anchor: anchor, in: s.size)
        var top: CGFloat = 10
        item(title, CGPoint(x: 14, y: top))
        top += (title?.size.height ?? 0) + 8
        segmented(LastfmStatsService.ChartKind.allCases.map { ($0.displayName, WebLyricsControl.chartKind($0), $0 == charts.kind) },
                  at: CGPoint(x: 10, y: top), height: pillHeight, s: s, ink: ink)
        top += pillHeight + 8
        segmented(LastfmStatsService.Period.allCases.map { ($0.displayName, WebLyricsControl.chartPeriod($0), $0 == charts.period) },
                  at: CGPoint(x: 10, y: top), height: pillHeight, s: s, ink: ink)
        top += pillHeight + 8
        if rows.isEmpty {
            if charts.loading {
                // 小号转圈(同 `ProgressView().controlSize(.small)`),Core Animation 按时间转,离屏也画得出来。
                let spinner = CAShapeLayer()
                WebLyricsDraw.noActions([spinner])
                spinner.frame = CGRect(x: (width - 16) / 2, y: top + 16, width: 16, height: 16)
                spinner.path = CGPath(ellipseIn: spinner.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
                spinner.fillColor = nil
                spinner.strokeColor = secondaryInk.cgColor
                spinner.lineWidth = 2
                spinner.lineCap = .round
                spinner.strokeEnd = 0.75
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = 2 * Double.pi
                spin.duration = 0.9
                spin.repeatCount = .infinity
                spinner.add(spin, forKey: "spin")
                panel.addSublayer(spinner)
                panelItems.append(spinner)
                return
            }
            let message = L10n.t(charts.failed ? "重试" : "暂无数据")
            let made = WebLyricsDraw.text(message, font: .systemFont(ofSize: 12),
                                          color: charts.failed ? s.accent : secondaryInk, scale: s.scale)
            let size = made?.size ?? .zero
            let origin = CGPoint(x: ((width - size.width) / 2).rounded(), y: (top + (48 - size.height) / 2).rounded())
            item(made, origin)
            if charts.failed {
                hits.append((.chartRetry, CGRect(origin: origin, size: size).insetBy(dx: -16, dy: -10)
                    .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)))
            }
            return
        }
        for (i, row) in rows.enumerated() {
            let left: CGFloat = 10 + 6
            if let rank = row.rank {
                item(rank, CGPoint(x: left + 18 - rank.size.width, y: top + 4 + 1))
            }
            item(row.name, CGPoint(x: left + 18 + 8, y: top + 4))
            if let detail = row.detail {
                item(detail, CGPoint(x: left + 18 + 8, y: top + 4 + (row.name?.size.height ?? 0) + 1))
            }
            if let count = row.count {
                item(count, CGPoint(x: width - 10 - 6 - count.size.width, y: (top + (row.height - count.size.height) / 2).rounded()))
            }
            hits.append((.chartRow(i), CGRect(x: panel.frame.minX + 10, y: panel.frame.minY + top, width: inner, height: row.height)))
            top += row.height
        }
    }

    private func segmented(_ options: [(String, WebLyricsControl, Bool)], at origin: CGPoint, height: CGFloat, s: State,
                           ink: NSColor) {
        let cells = options.map { option -> (made: (image: CGImage, size: CGSize)?, width: CGFloat) in
            let made = WebLyricsDraw.text(option.0, font: .systemFont(ofSize: 12, weight: option.2 ? .semibold : .regular),
                                          color: option.2 ? .white : ink, scale: s.scale)
            return (made, max(52, made?.size.width ?? 0) + 12)
        }
        let total = 2 + cells.map(\.width).reduce(0, +) + CGFloat(max(0, cells.count - 1)) * 2 + 2
        let track = CALayer()
        WebLyricsDraw.noActions([track])
        track.frame = CGRect(x: origin.x, y: origin.y, width: total, height: height)
        track.cornerRadius = height / 2
        track.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        panel.addSublayer(track)
        panelItems.append(track)
        var x = origin.x + 2
        for (i, cell) in cells.enumerated() {
            let frame = CGRect(x: x, y: origin.y + 2, width: cell.width, height: height - 4)
            if options[i].2 {
                let fill = CALayer()
                WebLyricsDraw.noActions([fill])
                fill.frame = frame
                fill.cornerRadius = frame.height / 2
                fill.backgroundColor = s.accent.cgColor
                panel.addSublayer(fill)
                panelItems.append(fill)
            }
            let glyph = CALayer()
            WebLyricsDraw.noActions([glyph])
            WebLyricsDraw.place(glyph, cell.made, center: CGPoint(x: frame.midX, y: frame.midY), scale: s.scale)
            panel.addSublayer(glyph)
            panelItems.append(glyph)
            hits.append((options[i].1, frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY).insetBy(dx: 0, dy: -6)))
            x += cell.width + 2
        }
    }

}
