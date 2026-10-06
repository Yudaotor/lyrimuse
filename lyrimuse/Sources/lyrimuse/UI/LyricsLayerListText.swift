import Accelerate
import AppKit
import CoreText
import LyrimuseCore

/// 歌词窗口图层列表(`LyricsLayerList`)的画字与量字,哪个线程都能调(建表时整首歌在后台画)。位图按所在窗口的比例画;
/// 宽度跟悬浮歌词、灵动岛同一个量法(`MenuBarMarqueeRenderer.measure`),排字语言逐段判(`LyricTypesetting`)。
/// 一段字的剪影和其中单个字形的剪影都从同一条 CoreText 行画、同一条基线,长音强调逐字形错开时拼回去跟整段逐像素重合。
///
/// 剪影、辉光、单色的整段字一律画成单通道遮罩(每像素只有透明度一个字节),颜色交给图层:画成 RGBA 的话同一首歌的位图
/// 大四倍,而且 App 自己一份、交给渲染服务再拷一份(见 07 章决策 115)。
enum LyricsLayerListText {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// 字形四周多留的这一圈(点):字形越出行框(上下伸部分、斜体、长音强调的放大)时不被位图边缘切掉。
    static let pad: CGFloat = 6

    /// 一段排成一行的字:宽、行框高,和画字用的基线(行框顶往下 `ascent`)。
    struct Metrics: Equatable, Sendable {
        var width: CGFloat
        var ascent: CGFloat
        var height: CGFloat
    }

    static func attributes(_ text: String, font: NSFont, translation: Bool) -> [NSAttributedString.Key: Any] {
        LyricTypesetting.attributes([.font: font, .foregroundColor: NSColor.white], for: text, translation: translation)
    }

    static func metrics(_ text: String, font: NSFont, translation: Bool = false) -> Metrics {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes(text, font: font, translation: translation)))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Metrics(width: MenuBarMarqueeRenderer.measure(text, font: font, translation: translation),
                       ascent: ascent, height: ceil(ascent + descent + leading))
    }

    /// 剪影按「文字 + 字体 + 第几个字形 + 比例 + 标的语言」记住:同一首歌里重复的字只画一次,字号没变的整张重建不必重画。
    struct SilhouetteKey: Hashable {
        let text: String
        let font: NSFont
        let translation: Bool
        let glyph: Int?
        let scale: CGFloat
        let language: String?
    }

    /// 一次建表用的剪影:查到的、新画的都记在这一代名下。缓存跟着列表视图走,装好之后只留这一代(见 `LyricsLayerListView.startBuild`)。
    struct Silhouettes: @unchecked Sendable {
        let cache: GenerationCache<SilhouetteKey, CGImage?>
        let generation: Int
    }

    /// 一段字的字形剪影(单通道遮罩)。位图比行框四周各大 `pad`。
    /// `glyph` 非 nil 时只画第几个可见字形(空白不算,口径同 `LyricsWordEmphasis.glyphCount`),其余字形不画。
    static func silhouette(_ text: String, font: NSFont, translation: Bool, metrics m: Metrics,
                           glyph: Int? = nil, scale: CGFloat, in silhouettes: Silhouettes) -> CGImage? {
        let key = SilhouetteKey(text: text, font: font, translation: translation, glyph: glyph, scale: scale,
                                language: LyricTypesetting.language(for: text, translation: translation))
        return silhouettes.cache.value(for: key, generation: silhouettes.generation) {
            renderSilhouette(text, font: font, translation: translation, metrics: m, glyph: glyph, scale: scale)
        }
    }

    private static func renderSilhouette(_ text: String, font: NSFont, translation: Bool, metrics m: Metrics,
                                         glyph: Int?, scale: CGFloat) -> CGImage? {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes(text, font: font, translation: translation)))
        let target = glyph.flatMap { g -> Range<Int>? in
            let ranges = visibleGlyphRanges(text)
            return g >= 0 && g < ranges.count ? ranges[g] : nil
        }
        if glyph != nil, target == nil { return nil }
        return draw(width: m.width + 2 * pad, height: m.height + 2 * pad, scale: scale, mask: true) { ctx in
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: pad, y: pad + m.ascent)
            guard let target else {
                CTLineDraw(line, ctx)
                return
            }
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
                for i in 0..<count where target.contains(indices[i]) {
                    ctx.textPosition = CGPoint(x: pad, y: pad + m.ascent)
                    CTRunDraw(run, ctx, CFRange(location: i, length: 1))
                }
            }
        }
    }

    /// 可见字形(非空白字符)各自占的 UTF-16 下标范围。
    static func visibleGlyphRanges(_ text: String) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var offset = 0
        for ch in text {
            let length = ch.utf16.count
            if !ch.isWhitespace { out.append(offset..<(offset + length)) }
            offset += length
        }
        return out
    }

    /// 剪影糊开,给长音强调的辉光用(同 SwiftUI 版逐字那份的 `.shadow(color: 底色, radius:)`:高斯模糊,σ 取半径的一半)。
    /// 三遍同宽的方框模糊叠出高斯(方差相加:每遍 (宽² − 1) / 12),在 CPU 上算、各行并行。别换成 Core Image:
    /// 它要排 GPU 的队再读回来,整首歌几十上百个字形并行也快不了。
    static func glow(_ silhouette: CGImage, radius: CGFloat, scale: CGFloat) -> CGImage? {
        let w = silhouette.width, h = silhouette.height
        guard w > 0, h > 0, silhouette.bitsPerPixel == 8, let source = silhouette.dataProvider?.data,
              let bytes = CFDataGetBytePtr(source), let a = canvas(w, h, mask: true), let b = canvas(w, h, mask: true)
        else { return nil }
        var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bytes), height: vImagePixelCount(h),
                                  width: vImagePixelCount(w), rowBytes: silhouette.bytesPerRow)
        var first = vImage_Buffer(data: a.data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: a.bytesPerRow)
        var second = vImage_Buffer(data: b.data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: b.bytesPerRow)
        let sigma = Double(radius * scale) / 2
        let box = UInt32(Int((4 * sigma * sigma + 1).squareRoot().rounded()) | 1)
        let flags = vImage_Flags(kvImageEdgeExtend)
        vImageBoxConvolve_Planar8(&input, &second, nil, 0, 0, box, box, 0, flags)
        vImageBoxConvolve_Planar8(&second, &first, nil, 0, 0, box, box, 0, flags)
        vImageBoxConvolve_Planar8(&first, &second, nil, 0, 0, box, box, 0, flags)
        return b.makeImage()
    }

    /// 一段排好的多行字:文字框的高,和画好的图。
    struct Paragraph {
        var height: CGFloat
        /// 左右裁到墨迹外各留 `pad` 的图;整段没有墨迹(全是空白)时为 nil,文字框照样占 `height`。
        var image: CGImage?
        /// `image` 在文字框里的框(点;文字框左上为原点,上下各伸出 `pad`)。
        var frame: CGRect
    }

    /// 多行字(按宽度折行、按对齐摆)。`mask` 为真时画成单通道遮罩(字一律按不透明画,颜色由图层上),否则按字自带的颜色
    /// 画成 RGBA。
    static func paragraph(_ text: NSAttributedString, width: CGFloat, alignment: NSTextAlignment, mask: Bool,
                          scale: CGFloat) -> Paragraph? {
        guard width > 0, text.length > 0 else { return nil }
        let styled = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: styled.length)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        styled.addAttribute(.paragraphStyle, value: style, range: whole)
        if mask { styled.addAttribute(.foregroundColor, value: NSColor.white, range: whole) }
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = styled.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options)
        let height = ceil(bounds.height)
        guard let full = draw(width: width + 2 * pad, height: height + 2 * pad, scale: scale, mask: mask, body: { _ in
            NSGraphicsContext.saveGraphicsState()
            styled.draw(with: CGRect(x: pad, y: pad, width: width, height: height), options: options)
            NSGraphicsContext.restoreGraphicsState()
        }) else { return nil }
        guard let cropped = croppedToInk(full, margin: Int((pad * scale).rounded(.up))) else {
            return Paragraph(height: height, image: nil, frame: .zero)
        }
        return Paragraph(height: height, image: cropped.image,
                         frame: CGRect(x: CGFloat(cropped.originX) / scale - pad, y: -pad,
                                       width: CGFloat(cropped.image.width) / scale, height: CGFloat(cropped.image.height) / scale))
    }

    /// 这段字里有没有彩色字形(emoji 这类):有的话整段画成 RGBA,遮罩画不出它的颜色。
    static func hasColorGlyphs(_ text: NSAttributedString) -> Bool {
        guard text.string.unicodeScalars.contains(where: { $0.value > 0x7F && $0.properties.isEmoji }) else { return false }
        let line = CTLineCreateWithAttributedString(text)
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { continue }
            let font = value as! CTFont
            if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) { return true }
        }
        return false
    }

    /// 左右裁到墨迹外再留 `margin` 像素,拷进一张刚好这么宽的新图(只取一块子图不省内存,底下还是整张)。
    /// 整张没有墨迹时返回 nil;读不到像素时原样返回。
    private static func croppedToInk(_ image: CGImage, margin: Int) -> (image: CGImage, originX: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return (image, 0) }
        let bpp = image.bitsPerPixel / 8
        let raw = UnsafeRawBufferPointer(start: bytes, count: CFDataGetLength(data))
        guard let ink = BitmapInk.columns(in: raw, width: image.width, height: image.height, bytesPerRow: image.bytesPerRow,
                                          bytesPerPixel: bpp, alphaOffset: bpp == 1 ? 0 : 3) else { return nil }
        let lo = max(0, ink.lowerBound - margin), hi = min(image.width, ink.upperBound + margin)
        guard lo > 0 || hi < image.width, let out = canvas(hi - lo, image.height, mask: bpp == 1), let dst = out.data
        else { return (image, 0) }
        for y in 0..<image.height {
            memcpy(dst + y * out.bytesPerRow, bytes + y * image.bytesPerRow + lo * bpp, (hi - lo) * bpp)
        }
        guard let cropped = out.makeImage() else { return (image, 0) }
        return (cropped, lo)
    }

    /// `mask` 为真:单通道(只有透明度,每像素 1 字节);否则 sRGB 预乘 RGBA。
    private static func canvas(_ w: Int, _ h: Int, mask: Bool) -> CGContext? {
        mask
            ? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            : CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 空白位图上画一笔。坐标系左上为原点、y 向下。
    private static func draw(width: CGFloat, height: CGFloat, scale: CGFloat, mask: Bool, body: (CGContext) -> Void) -> CGImage? {
        let pxW = Int((width * scale).rounded(.up)), pxH = Int((height * scale).rounded(.up))
        guard pxW > 0, pxH > 0, let ctx = canvas(pxW, pxH, mask: mask) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body(ctx)
        NSGraphicsContext.current = previous
        return ctx.makeImage()
    }
}
