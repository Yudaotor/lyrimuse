import AppKit
import SwiftUI

/// 系统符号库里没有的两枚展示面图标,自己画(颜色由用的地方给,同 SF Symbol):
/// - 灵动岛(`notch`):屏幕外框里,顶边下方悬着一颗实心药丸;
/// - 触控栏(`touchBar`):键盘上方一条差不多同宽的实心长条,键盘是系统的 `keyboard` 符号。
///
/// 名字(rawValue)当符号名用:`SymbolImage` 和 `NSImage.symbol(named:pointSize:weight:)` 先认这两个,认不出再当系统
/// 符号,所以面板格子、设置行、菜单项这些按符号名画图标的地方不用分两条路。同一个展示面在哪儿都是同一枚,名字只从这里取。
///
/// 两种画法共用一份几何(`layout(pointSize:weight:)`):SwiftUI 里用它自己的形状拼(`SurfaceGlyphView`),菜单项用画好的
/// 模板图(`image(pointSize:weight:)`)。
enum SurfaceGlyph: String {
    case notch = "lyrimuse.notch"
    case touchBar = "lyrimuse.touchbar"

    /// 某个字号、字重下每一笔落在哪儿,左上为原点。跟 SF Symbol 排在同一列、同一排,所以画布取系统 `rectangle` 符号在
    /// 同一字号下的大小,线宽取实测的系统符号线宽(regular 约字号的 0.076、semibold 约 0.11)。
    struct Layout {
        var canvas: CGSize
        var lineWidth: CGFloat
        /// 灵动岛:屏幕外框(描边中线)、它的圆角、顶上那颗药丸。
        var screen = CGRect.zero
        var screenCorner: CGFloat = 0
        var island = CGRect.zero
        /// 触控栏:上面那根长条、下面那块键盘,键盘是系统 `keyboard` 符号按 `keyboardPointSize` 排进这个框。
        var bar = CGRect.zero
        var keyboard = CGRect.zero
        var keyboardPointSize: CGFloat = 0
    }

    func layout(pointSize: CGFloat, weight: NSFont.Weight) -> Layout {
        var layout = Layout(canvas: CGSize(width: (pointSize * 23 / 16).rounded(), height: (pointSize * 18 / 16).rounded()),
                            lineWidth: Self.lineWidth(pointSize: pointSize, weight: weight))
        let box = CGRect(origin: .zero, size: layout.canvas)
        let line = layout.lineWidth
        switch self {
        case .notch:
            // 屏幕外框跟系统 `rectangle` 符号落在同一个位置:四周内收字号的 0.10 / 0.13,再让出半根线。
            let screen = box.insetBy(dx: pointSize * 0.10 + line / 2, dy: pointSize * 0.13 + line / 2)
            layout.screen = screen
            layout.screenCorner = pointSize * 0.2
            // 药丸占屏幕宽的四成,跟顶边那根线之间空一根线宽;小字号下至少 1.6 根线宽高,再薄就成了一条线。
            let width = screen.width * 0.42
            let height = max(pointSize * 0.21, line * 1.6)
            layout.island = CGRect(x: screen.midX - width / 2, y: screen.minY + line * 1.5, width: width, height: height)
        case .touchBar:
            // 长条取键盘宽的九成,跟键盘之间空一根线宽,两样合起来在画布里上下居中。
            layout.keyboardPointSize = pointSize * 0.84
            let keyboardSize = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: layout.keyboardPointSize, weight: weight))?
                .size ?? CGSize(width: pointSize * 1.3, height: pointSize * 0.8)
            let barHeight = max(pointSize * 0.16, line * 1.3)
            let top = (box.midY - (barHeight + line + keyboardSize.height) / 2).rounded(.down)
            let barWidth = keyboardSize.width * 0.9
            layout.bar = CGRect(x: box.midX - barWidth / 2, y: top, width: barWidth, height: barHeight)
            layout.keyboard = CGRect(x: box.midX - keyboardSize.width / 2, y: top + barHeight + line,
                                     width: keyboardSize.width, height: keyboardSize.height)
        }
        return layout
    }

    private static func lineWidth(pointSize: CGFloat, weight: NSFont.Weight) -> CGFloat {
        switch weight.rawValue {
        case NSFont.Weight.bold.rawValue...: return pointSize * 0.125
        case NSFont.Weight.semibold.rawValue...: return pointSize * 0.11
        case NSFont.Weight.medium.rawValue...: return pointSize * 0.094
        default: return pointSize * 0.076
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    /// 菜单项用的模板图,按需画(矢量,哪个倍率都清楚)。同一组参数只建一次。SwiftUI 里别用它,见 `SurfaceGlyphView`。
    @MainActor func image(pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
        let key = "\(rawValue)|\(pointSize)|\(weight.rawValue)"
        if let cached = Self.cache[key] { return cached }
        let layout = layout(pointSize: pointSize, weight: weight)
        let glyph = self
        let image = NSImage(size: layout.canvas, flipped: true) { _ in
            NSColor.black.set()
            switch glyph {
            case .notch:
                let outline = NSBezierPath(roundedRect: layout.screen, xRadius: layout.screenCorner, yRadius: layout.screenCorner)
                outline.lineWidth = layout.lineWidth
                outline.stroke()
                let radius = layout.island.height / 2
                NSBezierPath(roundedRect: layout.island, xRadius: radius, yRadius: radius).fill()
            case .touchBar:
                let radius = layout.bar.height / 2
                NSBezierPath(roundedRect: layout.bar, xRadius: radius, yRadius: radius).fill()
                NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: layout.keyboardPointSize, weight: weight))?
                    .draw(in: layout.keyboard, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return true
        }
        image.isTemplate = true
        Self.cache[key] = image
        return image
    }
}

/// SwiftUI 里的那一枚:用 SwiftUI 自己的形状和系统 `keyboard` 符号按 `SurfaceGlyph.layout` 拼,颜色走前景色。
/// 别换成把 `SurfaceGlyph.image` 那张模板图塞进 `Image(nsImage:)`:那条路着色比旁边的系统符号暗一截(深色下次要色最亮
/// 0.45 对 0.69、主色 0.79 对 0.90),这样拼出来的跟系统符号一样。
///
/// 实心的药丸、长条也用描边画(`RoundBar`,一根线宽等于高的圆头线),别写成 `Capsule()` 填充:设置页那种磨砂底上,
/// 填充比描边和系统符号浅一截(真机实测次要色:描边 0.60、填充 0.81),描边跟它们一样深。
struct SurfaceGlyphView: View {
    let glyph: SurfaceGlyph
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        let layout = glyph.layout(pointSize: size, weight: SymbolImage.appKitWeight(weight))
        ZStack(alignment: .topLeading) {
            switch glyph {
            case .notch:
                RoundedRectangle(cornerRadius: layout.screenCorner)
                    .stroke(lineWidth: layout.lineWidth)
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .offset(x: layout.screen.minX, y: layout.screen.minY)
                RoundBar(rect: layout.island)
            case .touchBar:
                RoundBar(rect: layout.bar)
                Image(systemName: "keyboard")
                    .font(.system(size: layout.keyboardPointSize, weight: weight))
                    .frame(width: layout.keyboard.width, height: layout.keyboard.height)
                    .offset(x: layout.keyboard.minX, y: layout.keyboard.minY)
            }
        }
        .frame(width: layout.canvas.width, height: layout.canvas.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// 占满 `rect` 的实心长圆,画成一根线宽等于高的圆头线(理由见上面)。
    private struct RoundBar: View {
        let rect: CGRect

        var body: some View {
            Path { path in
                path.move(to: CGPoint(x: rect.height / 2, y: rect.height / 2))
                path.addLine(to: CGPoint(x: rect.width - rect.height / 2, y: rect.height / 2))
            }
            .stroke(style: StrokeStyle(lineWidth: rect.height, lineCap: .round))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
    }
}

/// 按符号名画一枚图标:`SurfaceGlyph` 的名字画自画的那枚,其余当系统符号。用法同
/// `Image(systemName:)` + `.font(.system(size:weight:))`,颜色照样由外面的 `.foregroundStyle` 给。
struct SymbolImage: View {
    let name: String
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        if let glyph = SurfaceGlyph(rawValue: name) {
            SurfaceGlyphView(glyph: glyph, size: size, weight: weight)
        } else {
            Image(systemName: name).font(.system(size: size, weight: weight))
        }
    }

    static func appKitWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

extension NSImage {
    /// 菜单项用:按符号名出一张模板图,`SurfaceGlyph` 的名字画自画的那枚,其余当系统符号。
    @MainActor static func symbol(named name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        if let glyph = SurfaceGlyph(rawValue: name) { return glyph.image(pointSize: pointSize, weight: weight) }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) ?? image
    }
}
