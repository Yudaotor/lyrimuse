import Accelerate
import AppKit
import CoreText
import LyrimuseCore

/// 歌词窗口图层列表(`LyricsLayerList`)的画字与量字,哪个线程都能调(建表时整首歌在后台画)。位图一律按 sRGB 画、
/// 按所在窗口的比例画;宽度跟悬浮歌词、灵动岛同一个量法(`MenuBarMarqueeRenderer.measure`),排字语言逐段判
/// (`LyricTypesetting`)。一段字的剪影和其中单个字形的剪影都从同一条 CoreText 行画、同一条基线,长音强调逐字形错开时
/// 拼回去跟整段逐像素重合。
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

    /// 一段字的字形剪影(白字、预乘 alpha),当遮罩用。位图比行框四周各大 `pad`。
    /// `glyph` 非 nil 时只画第几个可见字形(空白不算,口径同 `LyricsWordEmphasis.glyphCount`),其余字形不画。
    static func silhouette(_ text: String, font: NSFont, translation: Bool, metrics m: Metrics,
                           glyph: Int? = nil, scale: CGFloat) -> CGImage? {
        let key = SilhouetteKey(text: text, font: font, translation: translation, glyph: glyph, scale: scale,
                                language: LyricTypesetting.language(for: text, translation: translation))
        cacheLock.lock()
        let hit = silhouetteCache[key]
        cacheLock.unlock()
        if let hit { return hit }
        let image = renderSilhouette(text, font: font, translation: translation, metrics: m, glyph: glyph, scale: scale)
        cacheLock.lock()
        if silhouetteCache.count >= silhouetteCacheLimit { silhouetteCache.removeAll(keepingCapacity: true) }
        silhouetteCache[key] = image
        cacheLock.unlock()
        return image
    }

    /// 剪影按「文字 + 字体 + 第几个字形 + 比例 + 标的语言」记住:换窗口宽度、换句时整张表重建,同一批字不必重画。
    private struct SilhouetteKey: Hashable {
        let text: String
        let font: NSFont
        let translation: Bool
        let glyph: Int?
        let scale: CGFloat
        let language: String?
    }

    private static let silhouetteCacheLimit = 3000
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var silhouetteCache: [SilhouetteKey: CGImage?] = [:]

    private static func renderSilhouette(_ text: String, font: NSFont, translation: Bool, metrics m: Metrics,
                                         glyph: Int?, scale: CGFloat) -> CGImage? {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes(text, font: font, translation: translation)))
        let target = glyph.flatMap { g -> Range<Int>? in
            let ranges = visibleGlyphRanges(text)
            return g >= 0 && g < ranges.count ? ranges[g] : nil
        }
        if glyph != nil, target == nil { return nil }
        return draw(width: m.width + 2 * pad, height: m.height + 2 * pad, scale: scale) { ctx in
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
        func canvas() -> CGContext? {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard w > 0, h > 0, let a = canvas(), let b = canvas() else { return nil }
        a.draw(silhouette, in: CGRect(x: 0, y: 0, width: w, height: h))
        var first = vImage_Buffer(data: a.data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: a.bytesPerRow)
        var second = vImage_Buffer(data: b.data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: b.bytesPerRow)
        let sigma = Double(radius * scale) / 2
        let box = UInt32(Int((4 * sigma * sigma + 1).squareRoot().rounded()) | 1)
        let flags = vImage_Flags(kvImageEdgeExtend)
        vImageBoxConvolve_ARGB8888(&first, &second, nil, 0, 0, box, box, nil, flags)
        vImageBoxConvolve_ARGB8888(&second, &first, nil, 0, 0, box, box, nil, flags)
        vImageBoxConvolve_ARGB8888(&first, &second, nil, 0, 0, box, box, nil, flags)
        return b.makeImage()
    }

    /// 多行字(按宽度折行、按对齐摆),画成彩色图。返回图和文字框的点尺寸(不含 `pad`)。
    static func paragraph(_ text: NSAttributedString, width: CGFloat, alignment: NSTextAlignment,
                          scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        guard width > 0, text.length > 0 else { return nil }
        let styled = NSMutableAttributedString(attributedString: text)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: styled.length))
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = styled.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options)
        let size = CGSize(width: width, height: ceil(bounds.height))
        guard let image = draw(width: size.width + 2 * pad, height: size.height + 2 * pad, scale: scale, body: { _ in
            NSGraphicsContext.saveGraphicsState()
            styled.draw(with: CGRect(x: pad, y: pad, width: width, height: size.height), options: options)
            NSGraphicsContext.restoreGraphicsState()
        }) else { return nil }
        return (image, size)
    }

    /// 空白位图上画一笔。坐标系左上为原点、y 向下。
    private static func draw(width: CGFloat, height: CGFloat, scale: CGFloat, body: (CGContext) -> Void) -> CGImage? {
        let pxW = Int((width * scale).rounded(.up)), pxH = Int((height * scale).rounded(.up))
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: pxW * 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body(ctx)
        NSGraphicsContext.current = previous
        return ctx.makeImage()
    }
}
