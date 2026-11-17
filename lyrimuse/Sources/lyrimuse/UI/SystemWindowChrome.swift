import SwiftUI

/// 系统给窗口画的那一圈:窗外投影、贴着外沿的一像素暗线、贴着内沿的亮线。设置页的预览把真窗口画在设置窗口里,
/// 这几样系统不会替它画,照这里的数模拟(歌词窗口预览、悬浮歌词编辑台)。参数只有这一份。
///
/// 数是真机量的,不是系统 API 给的:同一扇窗按窗口号截两张(`screencapture -l` 带系统阴影、`-o` 不带),
/// 不带阴影那张比圆角,带阴影那张取窗外每 2pt 的 alpha 拟合成高斯边缘(SwiftUI `shadow` 的 radius 就是高斯的 σ)。
/// 只量非焦点窗口:设置窗口开着时歌词窗口不是焦点窗口,悬浮歌词那扇面板从不当焦点窗口。对齐的是系统的画法,
/// 升级 macOS 大版本后要重量,量法和各组数见 07 章决策 207。
struct SystemWindowChrome: Equatable {
    enum Kind {
        /// 带标题栏的普通窗口(歌词窗口)。
        case titled
        /// 无边框面板(悬浮歌词),外形按窗口内容的 alpha 算。
        case borderless
    }

    var shadowOpacity: Double
    /// 高斯的 σ(点)。
    var shadowRadius: CGFloat
    /// 投影往下偏多少(点)。
    var shadowY: CGFloat
    /// 窗外贴边那一像素黑线。
    var outerEdgeOpacity: Double
    /// 窗内贴边的白线,宽 `innerEdgePixels` 像素。
    var innerEdgeOpacity: Double
    var innerEdgePixels: CGFloat

    /// 带标题栏的普通窗口的圆角(连续曲率)。
    static let titledCornerRadius: CGFloat = 16.5

    /// 深色外观下投影更深,外沿黑线几乎不透明;无边框面板的投影比普通窗口浅、往下偏得少。
    static func of(_ kind: Kind, dark: Bool) -> Self {
        switch (kind, dark) {
        case (.titled, false):
            return Self(shadowOpacity: 0.21, shadowRadius: 8, shadowY: 8,
                        outerEdgeOpacity: 0.21, innerEdgeOpacity: 0.1, innerEdgePixels: 1)
        case (.titled, true):
            return Self(shadowOpacity: 0.44, shadowRadius: 8, shadowY: 7,
                        outerEdgeOpacity: 0.83, innerEdgeOpacity: 0.08, innerEdgePixels: 2)
        case (.borderless, false):
            return Self(shadowOpacity: 0.22, shadowRadius: 7.5, shadowY: 4,
                        outerEdgeOpacity: 0.27, innerEdgeOpacity: 0.1, innerEdgePixels: 1)
        case (.borderless, true):
            return Self(shadowOpacity: 0.3, shadowRadius: 7.5, shadowY: 3.5,
                        outerEdgeOpacity: 0.85, innerEdgeOpacity: 0.08, innerEdgePixels: 2)
        }
    }

    /// 投影在窗口下沿以下伸出多远(点,按 `scale` 缩)。两倍 σ 之外不到峰值的 3%,看不出来;预览底下按它留地方。
    func shadowExtentBelow(scale: CGFloat) -> CGFloat { (shadowY + 2 * shadowRadius) * scale }
}

extension View {
    /// 在一块代表窗口的视图外面画 `SystemWindowChrome`:投影垫在下面(挖掉窗口那块,半透明的窗口里面不被压暗),
    /// 两道边线叠在上面。深浅按这一层的 `colorScheme` 取,跟真窗口的外观走同一个来源的放在它外面。
    ///
    /// `shape` 是窗口外形(圆角已按 `scale` 缩好)。`scale`:预览把整扇窗缩小画时,投影跟着缩,边线保持一像素。
    /// `opacity`:窗口内容的不透明度。系统的投影和边线按窗口内容的 alpha 算,全透明的窗口两样都没有。
    func systemWindowChrome<S: InsettableShape>(_ kind: SystemWindowChrome.Kind, shape: S,
                                                scale: CGFloat = 1, opacity: Double = 1) -> some View {
        modifier(SystemWindowChromeModifier(kind: kind, shape: shape, scale: scale, opacity: opacity))
    }
}

private struct SystemWindowChromeModifier<S: InsettableShape>: ViewModifier {
    let kind: SystemWindowChrome.Kind
    let shape: S
    let scale: CGFloat
    let opacity: Double
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let chrome = SystemWindowChrome.of(kind, dark: colorScheme == .dark)
        let pixel = 1 / max(displayScale, 1)
        let outset = chrome.shadowExtentBelow(scale: scale) + chrome.shadowRadius * scale
        return content
            .background {
                if opacity > 0 {
                    shape.fill(Color.black)
                        .shadow(color: .black.opacity(chrome.shadowOpacity * opacity),
                                radius: chrome.shadowRadius * scale, y: chrome.shadowY * scale)
                        .mask(SystemWindowOutsideShape(inner: shape, outset: outset).fill(style: FillStyle(eoFill: true)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if opacity > 0 {
                    ZStack {
                        shape.inset(by: -pixel)
                            .strokeBorder(Color.black.opacity(chrome.outerEdgeOpacity * opacity), lineWidth: pixel)
                        shape.strokeBorder(Color.white.opacity(chrome.innerEdgeOpacity * opacity),
                                           lineWidth: pixel * chrome.innerEdgePixels)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

/// 窗口外面那一圈(四周外扩 `outset`、挖掉窗口本身),偶奇填充。
private struct SystemWindowOutsideShape<S: Shape>: Shape {
    let inner: S
    let outset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -outset, dy: -outset))
        path.addPath(inner.path(in: rect))
        return path
    }
}
