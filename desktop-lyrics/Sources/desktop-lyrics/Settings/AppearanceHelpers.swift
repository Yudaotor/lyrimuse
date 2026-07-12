import SwiftUI
import AppKit
import CoreText

// 十六进制颜色字符串 <-> Color/NSColor 互转。macOS 14+ 更"地道"的做法是 Color.Resolved
// (编码成 JSON Data 存 UserDefaults),但 AppSettings 现在所有持久化字段都是纯 String/
// Bool/enum 原语,没有任何 Data/JSON 形态——十六进制字符串完全够用,还额外换来一个好处:
// `defaults read` 能直接看懂颜色是什么,调试更方便。选它是为了不给这个本来很简单的单例
// 引入一种新的持久化形状。
extension NSColor {
    /// 必须先转换到已知的 RGB 色彩空间——ColorPicker/NSColorPanel 选出来的颜色不保证
    /// 已经是 RGB-based(可能是 pattern/grayscale),直接读 .redComponent 会在非 RGB
    /// 颜色上触发运行时 trap。
    var hexStringWithAlpha: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#FFFFFFFF" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let a = Int(round(rgb.alphaComponent * 255))
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    convenience init?(hexStringWithAlpha hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 24) & 0xFF) / 255,
            green: CGFloat((v >> 16) & 0xFF) / 255,
            blue: CGFloat((v >> 8) & 0xFF) / 255,
            alpha: CGFloat(v & 0xFF) / 255
        )
    }
}

extension Color {
    /// 解析失败(比如手改坏了 UserDefaults 里的字符串)兜底成 fallback,而不是让整个
    /// 悬浮窗因为一个坏字符串崩溃或者变得不可见。
    init(hexWithAlpha hex: String, fallback: Color = .white) {
        guard let ns = NSColor(hexStringWithAlpha: hex) else {
            self = fallback
            return
        }
        self.init(nsColor: ns)
    }

    var hexStringWithAlpha: String { NSColor(self).hexStringWithAlpha }
}

// 字体族名+字号 -> SwiftUI Font,带显式的、可推理的降级——不用 Font.custom(name:size:)
// 那种"取不到就默默换系统字体、你毫无感知"的隐式行为,而是先用 NSFontManager 显式查一次
// 是否真的装了这个字体族。
enum OverlayFontWeight {
    case bold, medium, regular

    fileprivate var appKitWeight: Int { // AppKit 的 0...15 权重刻度,5 是标准 regular
        switch self {
        case .bold: return 9
        case .medium: return 6
        case .regular: return 5
        }
    }
    fileprivate var swiftUIWeight: Font.Weight {
        switch self {
        case .bold: return .bold
        case .medium: return .medium
        case .regular: return .regular
        }
    }
}

extension Font {
    /// familyName 为空字符串 = "跟随系统",直接走 .system 分支,和悬浮窗改动前的硬编码
    /// 视觉完全一致。familyName 非空但这台 Mac 没装(比如从别的 Mac 抄的配置)时,
    /// NSFontManager 干净地返回 nil,这里显式兜底到系统字体。
    static func overlayFont(familyName: String, size: CGFloat, weight: OverlayFontWeight) -> Font {
        guard !familyName.isEmpty,
              let nsFont = NSFontManager.shared.font(
                  withFamily: familyName, traits: [], weight: weight.appKitWeight, size: size
              )
        else {
            return .system(size: size, weight: weight.swiftUIWeight)
        }
        return Font(nsFont as CTFont)
    }
}

// 派生便捷属性——都读同一批 @Published hex 字符串,SwiftUI 已经会在这些字符串变化时
// 重新算,不需要单独再标 @Published。
extension AppSettings {
    var foregroundColor: Color { Color(hexWithAlpha: foregroundColorHex, fallback: .white) }
    var backgroundColor: Color { Color(hexWithAlpha: backgroundColorHex, fallback: .clear) }

    /// 阈值给点余量而不是判断 == 0——ColorPicker 拖 alpha 滑杆拖到接近全透明但不是恰好
    /// 整数 0 很常见;只有超过这条线才值得画一块圆角卡片背景,避免几乎看不见的颜色也
    /// 硬要画一块方形背景挡住桌面。
    var backgroundIsVisible: Bool {
        (NSColor(hexStringWithAlpha: backgroundColorHex)?.alphaComponent ?? 0) > 0.02
    }

    // 罗马音(原硬编码 13pt)、译文/下一句预览(原硬编码 14pt)相对主歌词行(原硬编码
    // 20pt)的比例——借用类似软件里"根字号 * 固定倍率"的缩放思路,但不做成通用基础
    // 设施,这个 App 只有 4 个固定文字角色,两个算好的比例就够。
    var romanizationFontSize: CGFloat { CGFloat(fontSize) * 0.65 } // 原 13/20
    var secondaryFontSize: CGFloat { CGFloat(fontSize) * 0.7 } // 原 14/20,译文+预览共用
}
