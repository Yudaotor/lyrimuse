import AppKit
import LyrimuseCore
import QuartzCore

/// 图层列表里一个会填色的元素:一个逐字 token、逐词罗马音的一组读音,或长音强调逐字形错开时的一个字形。
///
///     container          上浮(position.y 加法动画)、长音强调的放大(transform)
///       ├ glow?          长音强调的辉光:正文色 + 糊开的剪影当遮罩,透明度随时间变
///       └ fill           字形剪影当遮罩
///           └ gradient   已唱色 → 未唱色的软边渐变,平移 position.x = 填色
///
/// 遮罩挂在 `fill` 上而不是 `container` 上:挂在外层会把辉光也裁成字形的样子。渐变比词宽得多(`gradientWidth`),
/// 软边从词左走到词右的整段路程里都盖得住字形(含四周的 `LyricsLayerListText.pad`)。
@MainActor
final class LyricsLayerElement {
    let container = CALayer()
    let fill = CALayer()
    let gradient = CAGradientLayer()
    let glow: CALayer?
    /// 元素框(行坐标、y 向下)。
    let frame: CGRect
    let fillStartMs: Int
    let fillDurationMs: Int
    /// nil = 不上浮(背景人声、读音、迷你「多行」、减弱动态效果)。
    let motion: LyricsLayerTiming.Motion?
    /// 放大绕着的点,元素自己的单位坐标(同 `KaraokeWordText.emphasisAnchor`)。
    let anchor: CGPoint
    private let gradientWidth: CGFloat

    static let fillKey = "lyrimuse.layer-list.fill"
    static let liftKey = "lyrimuse.layer-list.lift"
    static let scaleKey = "lyrimuse.layer-list.scale"
    static let glowKey = "lyrimuse.layer-list.glow"

    init(_ plan: LyricsLayerRowPlan.Element, scale: CGFloat) {
        frame = plan.frame
        fillStartMs = plan.fillStartMs
        fillDurationMs = plan.fillDurationMs
        motion = plan.motion
        anchor = plan.anchor
        let pad = LyricsLayerListText.pad
        gradientWidth = 3 * frame.width + 4 * pad
        let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                             "opacity": NSNull(), "contents": NSNull()]
        container.actions = noActions
        container.anchorPoint = anchor
        container.bounds = CGRect(origin: .zero, size: frame.size)
        container.position = CGPoint(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height)
        fill.actions = noActions
        fill.frame = container.bounds
        let mask = CALayer()
        mask.actions = noActions
        mask.frame = CGRect(x: -pad, y: -pad, width: frame.width + 2 * pad, height: frame.height + 2 * pad)
        mask.contents = plan.silhouette
        mask.contentsScale = scale
        fill.mask = mask
        gradient.actions = noActions
        gradient.anchorPoint = .zero
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let band = KaraokeFill.wordEdgeSoftenBand * Double(frame.width) / Double(gradientWidth)
        gradient.colors = [plan.sung, plan.sung, plan.unsung, plan.unsung]
        gradient.locations = [0, NSNumber(value: 0.5 - band), NSNumber(value: 0.5 + band), 1]
        gradient.bounds = CGRect(x: 0, y: 0, width: gradientWidth, height: frame.height + 2 * pad)
        fill.addSublayer(gradient)
        if let glowImage = plan.glow {
            let g = CALayer()
            g.actions = noActions
            g.frame = mask.frame
            g.backgroundColor = plan.sung
            let glowMask = CALayer()
            glowMask.frame = g.bounds
            glowMask.contents = glowImage
            glowMask.contentsScale = scale
            g.mask = glowMask
            g.opacity = 0
            container.addSublayer(g)
            glow = g
        } else {
            glow = nil
        }
        container.addSublayer(fill)
        if plan.hidden { container.opacity = 0 }
        setFill(center: LyricsLayerTiming.unsungCenter)
    }

    /// 软边中心在词宽里的位置 → 渐变层的 x:渐变正中那条过渡带对准中心。
    private func gradientX(center: Double) -> CGFloat {
        CGFloat(center) * frame.width - gradientWidth / 2
    }

    func setFill(center: Double) {
        gradient.position = CGPoint(x: gradientX(center: center), y: -LyricsLayerListText.pad)
    }

    /// 画成某一刻的静态样子(停着、定格、非当前行):摘掉动画、直接落值。
    func setStatic(center: Double, pose: LyricsLayerTiming.Pose) {
        for key in [Self.fillKey] { gradient.removeAnimation(forKey: key) }
        for key in [Self.liftKey, Self.scaleKey] { container.removeAnimation(forKey: key) }
        glow?.removeAnimation(forKey: Self.glowKey)
        setFill(center: center)
        applyPose(pose)
    }

    private func applyPose(_ pose: LyricsLayerTiming.Pose) {
        container.position = CGPoint(x: frame.minX + anchor.x * frame.width,
                                     y: frame.minY + anchor.y * frame.height - CGFloat(pose.lift))
        container.transform = pose.scale == 1 ? CATransform3DIdentity
            : CATransform3DMakeScale(CGFloat(pose.scale), CGFloat(pose.scale), 1)
        glow?.opacity = Float(pose.glow)
    }

    /// 从此刻起按时间轴装动画。模型值先落到终态,动画开始前用 `.backwards` 撑住起始的样子、走完自然停在终态。
    func install(nowMs: Int, rate: Double, mediaNow: CFTimeInterval, frameRange: CAFrameRateRange) {
        let track = LyricsLayerTiming.fillTrack(startMs: fillStartMs, durationMs: fillDurationMs, nowMs: nowMs, rate: rate)
        let endPose = motion.map { $0.pose(atMs: $0.activeRangeMs.upperBound) } ?? .rest
        setStatic(center: LyricsLayerTiming.sungCenter, pose: endPose)
        if track.beginOffset + track.duration > 0 {
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = gradientX(center: LyricsLayerTiming.unsungCenter)
            a.toValue = gradientX(center: LyricsLayerTiming.sungCenter)
            a.beginTime = gradient.convertTime(mediaNow, from: nil) + track.beginOffset
            a.duration = track.duration
            a.fillMode = .backwards
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            a.preferredFrameRateRange = frameRange
            gradient.add(a, forKey: Self.fillKey)
        }
        guard let motion, let poses = LyricsLayerTiming.poseTrack(motion, nowMs: nowMs, rate: rate) else { return }
        let begin = container.convertTime(mediaNow, from: nil) + poses.beginOffset
        let keyTimes = poses.keyTimes.map { NSNumber(value: $0) }
        let lift = CAKeyframeAnimation(keyPath: "position.y")
        lift.isAdditive = true
        lift.values = poses.poses.map { NSNumber(value: endPose.lift - $0.lift) }
        add(lift, keyTimes: keyTimes, begin: begin, duration: poses.duration, range: frameRange, to: container, key: Self.liftKey)
        guard motion.emphasis != nil else { return }
        let scale = CAKeyframeAnimation(keyPath: "transform")
        scale.values = poses.poses.map { NSValue(caTransform3D: CATransform3DMakeScale(CGFloat($0.scale), CGFloat($0.scale), 1)) }
        add(scale, keyTimes: keyTimes, begin: begin, duration: poses.duration, range: frameRange, to: container, key: Self.scaleKey)
        if let glow {
            let g = CAKeyframeAnimation(keyPath: "opacity")
            g.values = poses.poses.map { NSNumber(value: $0.glow) }
            add(g, keyTimes: keyTimes, begin: glow.convertTime(mediaNow, from: nil) + poses.beginOffset,
                duration: poses.duration, range: frameRange, to: glow, key: Self.glowKey)
        }
    }

    private func add(_ a: CAKeyframeAnimation, keyTimes: [NSNumber], begin: CFTimeInterval, duration: Double,
                     range: CAFrameRateRange, to layer: CALayer, key: String) {
        a.keyTimes = keyTimes
        a.calculationMode = .linear
        a.beginTime = begin
        a.duration = duration
        a.fillMode = .backwards
        a.preferredFrameRateRange = range
        layer.add(a, forKey: key)
    }
}

/// 画一行要用的字号、字体、颜色和开关;任何一项变了整张列表重建。
struct LyricsLayerRowStyle: Equatable, @unchecked Sendable {
    var fontSize: CGFloat
    var romaFontSize: CGFloat
    var translationFontSize: CGFloat
    var fontFamily: String
    var textColor: NSColor
    var secondaryColor: NSColor
    var showRomanization: Bool
    var showTranslation: Bool
    /// 迷你「多行」:没有对唱标记的行居中;不显示背景人声和末尾创作者。
    var centered: Bool
    /// 正在唱的字要不要上浮(迷你「多行」关)。
    var wordRise: Bool
    var reduceMotion: Bool
    var duetInsetUnit: CGFloat
    var scale: CGFloat

    /// 背景人声的字号(正文的倍数)和整行透明度,同 SwiftUI 版 `LyricsLineRow`。
    static let backgroundScale: CGFloat = 0.61
    static let backgroundOpacity: Float = 0.6
    /// 译文跟正文之间多留的距离(正文字号的倍数)。
    static let translationExtraGap: CGFloat = 0.12
    /// 行内各块(正文、背景人声、读音、译文)之间的间距,同 SwiftUI 版 VStack 的 spacing。
    static let blockSpacing: CGFloat = 6
    /// 逐字折行后各行之间的行距,同 SwiftUI 版 `WrapLayout` 的 verticalSpacing。
    static let wrapRowSpacing: CGFloat = 2

    var rises: Bool { wordRise && !reduceMotion }

    /// 上浮高度,收到整数个设备像素(同 `KaraokeWordText.riseAmplitude`)。
    var riseAmplitude: Double {
        let s = max(1, Double(scale))
        return (Double(fontSize) * KaraokeLift.amplitudeEm * s).rounded() / s
    }

    @MainActor
    func font(_ size: CGFloat, _ weight: OverlayFontWeight) -> NSFont {
        NSFont.overlayFont(familyName: fontFamily, size: size, weight: weight)
    }
}

/// 建表要用的字体、颜色和文案,在主线程按这扇窗此刻的外观解析成定值(颜色里有跟着外观变的),交给后台排版画字。
struct LyricsLayerRowInk: @unchecked Sendable {
    let main: NSFont
    let background: NSFont
    let roma: NSFont
    let translation: NSFont
    let footerNames: NSFont
    let text: CGColor
    let secondary: CGColor
    /// 末尾创作者行的标签(「创作者：」)和名单分隔号,按界面语言取。
    let footerLabel: String
    let footerSeparator: String

    @MainActor
    init(style: LyricsLayerRowStyle, appearance: NSAppearance) {
        main = style.font(style.fontSize, .bold)
        background = style.font(style.fontSize * LyricsLayerRowStyle.backgroundScale, .bold)
        roma = style.font(style.romaFontSize, .medium)
        translation = style.font(style.translationFontSize, .semibold)
        footerNames = style.font(style.fontSize, .regular)
        var text = style.textColor.cgColor, secondary = style.secondaryColor.cgColor
        appearance.performAsCurrentDrawingAppearance {
            text = style.textColor.cgColor
            secondary = style.secondaryColor.cgColor
        }
        self.text = text
        self.secondary = secondary
        footerLabel = L10n.t("创作者：")
        footerSeparator = L10n.t("、")
    }
}

/// 一行排好版、画好图的样子:哪个线程都能算(整首歌在后台一起算,画字是建表最贵的一步),主线程照着它建图层
/// (`LyricsLayerRow.init`)。
struct LyricsLayerRowPlan: @unchecked Sendable {
    enum Kind: Equatable, Sendable {
        case line(Int)
        case footer
    }

    struct Element {
        var frame: CGRect
        var silhouette: CGImage?
        var glow: CGImage?
        var sung: CGColor
        var unsung: CGColor
        var fillStartMs: Int
        var fillDurationMs: Int
        var motion: LyricsLayerTiming.Motion?
        var anchor: CGPoint
        /// 逐词读音里没有读音的那一组:占位、不显示。
        var hidden: Bool
    }

    /// 整段画成一张图的(没有逐字时间轴的正文、整行读音、译文、创作者行),框含四周的 `LyricsLayerListText.pad`。
    struct Picture {
        var frame: CGRect
        var image: CGImage
        var contentsScale: CGFloat
    }

    var kind: Kind
    var size: CGSize
    /// 正文的逐字元素(含逐词读音、长音强调的字形)。
    var elements: [Element]
    /// 背景人声的逐字元素,整组挂在一个半透明的容器里。
    var background: [Element]
    var pictures: [Picture]
    var textFrame: CGRect
    var accessibilityText: String
}

/// 列表里的一项:一句歌词、末尾的创作者行。间奏「•••」不是这个类型(它是 `GapDotsNSView`,见 `LyricsLayerListView`)。
@MainActor
final class LyricsLayerRow {
    typealias Kind = LyricsLayerRowPlan.Kind

    let kind: Kind
    /// 整行容器(文档坐标、y 向下):景深(透明度 + 模糊)、换句错开都挂在它身上。
    let layer = CALayer()
    let size: CGSize
    /// 正文的逐字元素(含逐词罗马音、长音强调的字形)和背景人声的逐字元素。没有逐字时间轴的行为空。
    let elements: [LyricsLayerElement]
    /// 正文那几行字实际占的框(行坐标),鼠标悬停 / 点按只认整行宽,这个只给无障碍用。
    let textFrame: CGRect
    let accessibilityText: String

    init(_ plan: LyricsLayerRowPlan, scale: CGFloat) {
        kind = plan.kind
        size = plan.size
        textFrame = plan.textFrame
        accessibilityText = plan.accessibilityText
        layer.anchorPoint = .zero
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "filters": NSNull(),
                         "sublayers": NSNull(), "transform": NSNull()]
        layer.masksToBounds = false
        for p in plan.pictures {
            let l = CALayer()
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
            l.frame = p.frame
            l.contents = p.image
            l.contentsScale = p.contentsScale
            layer.addSublayer(l)
        }
        let main = plan.elements.map { LyricsLayerElement($0, scale: scale) }
        let background = plan.background.map { LyricsLayerElement($0, scale: scale) }
        if !background.isEmpty {
            let holder = CALayer()
            holder.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
            holder.anchorPoint = .zero
            holder.position = .zero
            holder.opacity = LyricsLayerRowStyle.backgroundOpacity
            for e in background { holder.addSublayer(e.container) }
            layer.addSublayer(holder)
        }
        for e in main { layer.addSublayer(e.container) }
        elements = main + background
    }

    // MARK: - 逐字状态

    /// 非当前行:整行定格全填色;唱过的行字停在上浮的高度(`raised`,07 章决策 83)。
    func showRest(raised: Bool, style: LyricsLayerRowStyle) {
        let lifted = LyricsLayerTiming.Pose(lift: style.riseAmplitude, scale: 1, glow: 0)
        for e in elements {
            e.setStatic(center: LyricsLayerTiming.sungCenter, pose: raised && e.motion != nil ? lifted : .rest)
        }
    }

    /// 当前行停着(暂停、窗口看不见):画成 `atMs` 那一刻的样子。
    func showFrozen(atMs ms: Int) {
        for e in elements {
            e.setStatic(center: LyricsLayerTiming.fillCenter(startMs: e.fillStartMs, durationMs: e.fillDurationMs, atMs: ms),
                        pose: e.motion?.pose(atMs: Double(ms)) ?? .rest)
        }
    }

    /// 当前行整行已定格(所有词填满、浮到顶):直接画终态,不依赖任何时间基准(07 章「定格即钉死」)。
    func showSettled(style: LyricsLayerRowStyle) {
        let lifted = LyricsLayerTiming.Pose(lift: style.riseAmplitude, scale: 1, glow: 0)
        for e in elements {
            e.setStatic(center: LyricsLayerTiming.sungCenter, pose: e.motion != nil ? lifted : .rest)
        }
    }

    /// 当前行在播:从此刻起按时间轴装动画。
    func play(nowMs: Int, rate: Double, mediaNow: CFTimeInterval, frameRange: CAFrameRateRange) {
        for e in elements { e.install(nowMs: nowMs, rate: rate, mediaNow: mediaNow, frameRange: frameRange) }
    }
}

// MARK: - 排版与画字

extension LyricsLayerRowPlan {
    /// 一句歌词排成一行。`width` 是这一列的宽(对唱留白在里面扣)。
    static func line(index: Int, line: SyncedLyricLine, width: CGFloat, style: LyricsLayerRowStyle,
                     ink: LyricsLayerRowInk) -> LyricsLayerRowPlan {
        let side = line.side ?? (style.centered ? .center : .leading)
        let insets = duetInsets(line.side, unit: style.duetInsetUnit)
        let blockX = insets.leading
        let blockW = max(1, width - insets.leading - insets.trailing)
        var elements: [Element] = []
        var background: [Element] = []
        var pictures: [Picture] = []
        var y: CGFloat = 0
        var textFrame = CGRect.zero
        let perWordRoma = style.showRomanization && line.wordGroups?.isEmpty == false && line.words != nil
        if let words = line.words, !words.isEmpty {
            let block = wordBlock(words: words, groups: perWordRoma ? line.wordGroups : nil, font: ink.main,
                                  romaFont: ink.roma, color: ink.text, rises: style.rises,
                                  origin: CGPoint(x: blockX, y: y), width: blockW, side: side, style: style)
            elements += block.elements
            textFrame = CGRect(x: blockX, y: y, width: blockW, height: block.height)
            y += block.height
        } else if let para = paragraph(line.plainText ?? line.mainText ?? "", font: ink.main, color: ink.text,
                                       translation: false, width: blockW, side: side, scale: style.scale) {
            pictures.append(placed(para, x: blockX, y: y))
            textFrame = CGRect(x: blockX, y: y, width: blockW, height: para.size.height)
            y += para.size.height
        }
        if style.wordRise, let bg = backgroundDisplayWords(line.backgroundWords) {
            y += LyricsLayerRowStyle.blockSpacing
            let block = wordBlock(words: bg, groups: nil, font: ink.background, romaFont: ink.roma, color: ink.text,
                                  rises: false, origin: CGPoint(x: blockX, y: y), width: blockW, side: side, style: style)
            background = block.elements
            y += block.height
        }
        if style.showRomanization, !perWordRoma, let roma = line.romanization, !roma.isEmpty,
           let para = paragraph(roma, font: ink.roma, color: ink.secondary, translation: false, width: blockW,
                                side: side, scale: style.scale) {
            y += LyricsLayerRowStyle.blockSpacing
            pictures.append(placed(para, x: blockX, y: y))
            y += para.size.height
        }
        if style.showTranslation, let tr = line.translation, !tr.isEmpty,
           let para = paragraph(tr, font: ink.translation, color: ink.secondary, translation: true, width: blockW,
                                side: side, scale: style.scale) {
            y += LyricsLayerRowStyle.blockSpacing + style.fontSize * LyricsLayerRowStyle.translationExtraGap
            pictures.append(placed(para, x: blockX, y: y))
            y += para.size.height
        }
        return LyricsLayerRowPlan(kind: .line(index), size: CGSize(width: width, height: max(1, y)), elements: elements,
                                  background: background, pictures: pictures, textFrame: textFrame,
                                  accessibilityText: line.plainText ?? line.mainText ?? "")
    }

    /// 末尾「创作者：甲、乙」:标签加粗、名单常规字重,字号和颜色跟正文一样(07 章「列表末尾的创作者」)。
    static func footer(names: [String], width: CGFloat, style: LyricsLayerRowStyle, ink: LyricsLayerRowInk) -> LyricsLayerRowPlan? {
        guard !names.isEmpty else { return nil }
        let list = names.joined(separator: ink.footerSeparator)
        let color = NSColor(cgColor: ink.text) ?? .white
        let text = NSMutableAttributedString(
            string: ink.footerLabel,
            attributes: LyricTypesetting.attributes([.font: ink.main, .foregroundColor: color], for: list, translation: false))
        text.append(NSAttributedString(
            string: list,
            attributes: LyricTypesetting.attributes([.font: ink.footerNames, .foregroundColor: color], for: list, translation: false)))
        guard let image = LyricsLayerListText.paragraph(text, width: width, alignment: .left, scale: style.scale) else { return nil }
        return LyricsLayerRowPlan(kind: .footer, size: CGSize(width: width, height: image.size.height), elements: [], background: [],
                                  pictures: [placed(image, x: 0, y: 0)], textFrame: CGRect(origin: .zero, size: image.size),
                                  accessibilityText: ink.footerLabel + list)
    }

    private static func duetInsets(_ side: LyricDuet.Side?, unit: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        guard let side else { return (0, 0) }
        switch side {
        case .leading: return (0, unit)
        case .trailing: return (unit, 0)
        case .center: return (unit, unit)
        }
    }

    private static func rowAlignment(_ side: LyricDuet.Side) -> WrapLayoutMath.RowAlignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private static func textAlignment(_ side: LyricDuet.Side) -> NSTextAlignment {
        switch side {
        case .leading: return .left
        case .trailing: return .right
        case .center: return .center
        }
    }

    /// 背景人声显示用的词:去掉整段首尾的括号、去掉空白词(同 SwiftUI 版 `LyricsLineRow.backgroundDisplayWords`)。
    private static func backgroundDisplayWords(_ raw: [SyncedLyricWord]?) -> [SyncedLyricWord]? {
        guard var words = raw, !words.isEmpty else { return nil }
        func replaced(_ w: SyncedLyricWord, _ text: String) -> SyncedLyricWord {
            SyncedLyricWord(text: text, startMs: w.startMs, durationMs: w.durationMs)
        }
        if let first = words.first, let c = first.text.first, c == "(" || c == "（" {
            words[0] = replaced(first, String(first.text.dropFirst()))
        }
        if let last = words.last, let c = last.text.last, c == ")" || c == "）" {
            words[words.count - 1] = replaced(last, String(last.text.dropLast()))
        }
        words.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return words.isEmpty ? nil : words
    }

    private static func paragraph(_ text: String, font: NSFont, color: CGColor, translation: Bool, width: CGFloat,
                                  side: LyricDuet.Side, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        guard !text.isEmpty else { return nil }
        let attrs = LyricTypesetting.attributes([.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white],
                                                for: text, translation: translation)
        return LyricsLayerListText.paragraph(NSAttributedString(string: text, attributes: attrs), width: width,
                                             alignment: textAlignment(side), scale: scale)
    }

    private static func placed(_ p: (image: CGImage, size: CGSize), x: CGFloat, y: CGFloat) -> Picture {
        let pad = LyricsLayerListText.pad
        return Picture(frame: CGRect(x: x - pad, y: y - pad, width: p.size.width + 2 * pad, height: p.size.height + 2 * pad),
                       image: p.image, contentsScale: CGFloat(p.image.width) / (p.size.width + 2 * pad))
    }

    /// 逐字的那一块(正文或背景人声):按宽度折行(`WrapLayoutMath`,同 SwiftUI 版 `WrapLayout`)、每个 token 一个元素。
    /// 开了逐词罗马音时折行单位是一组(字 + 读音一列),列宽取字和读音里更宽的那个。
    private static func wordBlock(words: [SyncedLyricWord], groups: [SyncedLyricWordGroup]?, font: NSFont, romaFont: NSFont,
                                  color: CGColor, rises: Bool, origin: CGPoint, width: CGFloat,
                                  side: LyricDuet.Side, style: LyricsLayerRowStyle) -> (elements: [Element], height: CGFloat) {
        let dim = CGFloat(WordKaraokeGradient.windowDimOpacity)
        let unsung = color.copy(alpha: color.alpha * dim) ?? color
        let romaColor = color.copy(alpha: color.alpha * 0.75) ?? color
        let romaUnsung = romaColor.copy(alpha: romaColor.alpha * dim) ?? romaColor
        let spans: [LyricsWordEmphasis.Span?] = rises && groups == nil
            ? LyricsWordEmphasis.spans(for: words) : Array(repeating: nil, count: words.count)
        let slots = LyricsWordEmphasis.glyphSlots(for: words, spans: spans)
        let wordMetrics = words.map { LyricsLayerListText.metrics($0.text, font: font) }
        let anchors = emphasisAnchors(words: words, spans: spans, metrics: wordMetrics)
        // 每个折行单位:一组(带读音)或一个 token
        struct Unit { var tokens: [Int]; var roma: (text: String, metrics: LyricsLayerListText.Metrics, startMs: Int, durationMs: Int, visible: Bool)?; var size: CGSize; var mainHeight: CGFloat }
        var units: [Unit] = []
        if let groups, !groups.isEmpty {
            var cursor = 0
            for g in groups {
                let ids = Array(cursor..<min(words.count, cursor + g.words.count))
                cursor += g.words.count
                let mainW = ids.reduce(CGFloat(0)) { $0 + wordMetrics[$1].width }
                let mainH = ids.map { wordMetrics[$0].height }.max() ?? 0
                let text = g.romanization ?? " "
                let rm = LyricsLayerListText.metrics(text, font: romaFont)
                units.append(Unit(tokens: ids,
                                  roma: (text, rm, g.startMs, max(1, g.endMs - g.startMs), g.romanization != nil),
                                  size: CGSize(width: max(mainW, rm.width + 4), height: mainH + rm.height), mainHeight: mainH))
            }
        } else {
            units = words.indices.map { i in
                Unit(tokens: [i], roma: nil, size: CGSize(width: wordMetrics[i].width, height: wordMetrics[i].height),
                     mainHeight: wordMetrics[i].height)
            }
        }
        let breakBefore = groups?.isEmpty == false ? nil : WrapLayoutMath.breakOpportunities(texts: words.map(\.text))
        let rows = WrapLayoutMath.rows(sizes: units.map(\.size), maxWidth: width, horizontalSpacing: 0, breakBefore: breakBefore)
        let placements = WrapLayoutMath.placements(rows: rows, sizes: units.map(\.size),
                                                   bounds: CGRect(x: origin.x, y: origin.y, width: width, height: .greatestFiniteMagnitude),
                                                   horizontalSpacing: 0, verticalSpacing: LyricsLayerRowStyle.wrapRowSpacing,
                                                   rowAlignment: rowAlignment(side))
        var elements: [Element] = []
        for p in placements {
            let unit = units[p.index]
            var x = p.origin.x
            for i in unit.tokens {
                let m = wordMetrics[i]
                let frame = CGRect(x: x, y: p.origin.y + (unit.mainHeight - m.height) / 2, width: m.width, height: m.height)
                elements += tokenElements(words[i], metrics: m, frame: frame, font: font, sung: color, unsung: unsung,
                                          rises: rises, emphasis: spans[i], slot: slots[i], anchor: anchors[i], style: style)
                x += m.width
            }
            if let roma = unit.roma {
                let frame = CGRect(x: p.origin.x + 2, y: p.origin.y + unit.mainHeight, width: roma.metrics.width, height: roma.metrics.height)
                elements.append(Element(
                    frame: frame,
                    silhouette: LyricsLayerListText.silhouette(roma.text, font: romaFont, translation: false,
                                                               metrics: roma.metrics, scale: style.scale),
                    glow: nil, sung: romaColor, unsung: romaUnsung,
                    fillStartMs: roma.startMs, fillDurationMs: roma.durationMs, motion: nil,
                    anchor: CGPoint(x: 0.5, y: 0.5), hidden: !roma.visible))
            }
        }
        let height = WrapLayoutMath.totalSize(rows: rows, maxWidth: width, verticalSpacing: LyricsLayerRowStyle.wrapRowSpacing).height
        return (elements, height)
    }

    /// 一个 token 的元素:平常一个;长音强调逐字形错开时每个可见字形一个,每个字形画一份只显示自己那个字形的剪影,
    /// 位置照整段排好的原样(同 `SingleGlyphRenderer`)。
    private static func tokenElements(_ word: SyncedLyricWord, metrics m: LyricsLayerListText.Metrics, frame: CGRect,
                                      font: NSFont, sung: CGColor, unsung: CGColor, rises: Bool,
                                      emphasis: LyricsWordEmphasis.Span?, slot: LyricsWordEmphasis.GlyphSlot?,
                                      anchor: CGPoint, style: LyricsLayerRowStyle) -> [Element] {
        let amplitude = style.riseAmplitude
        if rises, let emphasis, let slot {
            let count = LyricsWordEmphasis.glyphCount(word.text)
            if count > 0 {
                let glowRadius = style.fontSize * 0.12
                return (0..<count).map { k in
                    let index = slot.offset + k
                    let window = LyricsWordEmphasis.glyphWindow(for: emphasis, glyph: index, of: slot.count)
                    let silhouette = LyricsLayerListText.silhouette(word.text, font: font, translation: false, metrics: m,
                                                                    glyph: k, scale: style.scale)
                    return Element(
                        frame: frame, silhouette: silhouette,
                        glow: silhouette.flatMap { LyricsLayerListText.glow($0, radius: glowRadius, scale: style.scale) },
                        sung: sung, unsung: unsung, fillStartMs: word.startMs, fillDurationMs: word.durationMs,
                        motion: LyricsLayerTiming.Motion(riseStartMs: window.startMs, amplitude: amplitude,
                                                         emphasis: emphasis, glyph: (index, slot.count)),
                        anchor: anchor, hidden: false)
                }
            }
        }
        return [Element(
            frame: frame,
            silhouette: LyricsLayerListText.silhouette(word.text, font: font, translation: false, metrics: m, scale: style.scale),
            glow: nil, sung: sung, unsung: unsung, fillStartMs: word.startMs, fillDurationMs: word.durationMs,
            motion: rises ? LyricsLayerTiming.Motion(riseStartMs: Double(word.startMs), amplitude: amplitude) : nil,
            anchor: anchor, hidden: false)]
    }

    /// 长音强调绕着放大的点:同一个词的几个 token 都绕整词中心(同 `KaraokeLineText.emphasisAnchors`)。
    private static func emphasisAnchors(words: [SyncedLyricWord], spans: [LyricsWordEmphasis.Span?],
                                        metrics: [LyricsLayerListText.Metrics]) -> [CGPoint] {
        var out = [CGPoint](repeating: CGPoint(x: 0.5, y: 0.5), count: words.count)
        guard spans.contains(where: { $0 != nil }) else { return out }
        var i = 0
        while i < words.count {
            guard let span = spans[i] else { i += 1; continue }
            var end = i + 1
            while end < words.count, spans[end] == span { end += 1 }
            let widths = (i..<end).map { Double(metrics[$0].width) }
            for (k, x) in LyricsWordEmphasis.scaleAnchorXs(widths: widths).enumerated() {
                out[i + k] = CGPoint(x: x, y: 0.5)
            }
            i = end
        }
        return out
    }
}
