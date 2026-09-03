import SwiftUI
import AppKit
import CoreText
import LyrimuseCore

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
//
// ⚠️ `OverlayFontWeight` **本体在 LyrimuseCore**(`Util/OverlayFontWeight.swift`),不在这里。
// 2026-09-02 加「字重」设置时搬过去的:四行字重从"各自硬编码"变成"用户选主行、其余三行按固定
// 档位差推导",推导规则是纯逻辑而且带一条必须钉住的兼容性不变量(默认档位要逐个复现改动前那
// 四个权重),selftest 只依赖 LyrimuseCore,判据不下沉就覆盖不到。留在这里的只有三件真正需要
// SwiftUI / AppKit / L10n 的事:`Font.Weight` / `NSFont.Weight` 两份映射和本地化显示名。
extension OverlayFontWeight {
    fileprivate var swiftUIWeight: Font.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    /// AppKit 侧的 `NSFont.Weight`(菜单栏歌词用,2026-09-03):菜单栏那条路画的是 NSString + NSFont
    /// 的位图,不经 SwiftUI,所以要有一份跟 `swiftUIWeight` 平行的映射。两份都是逐名对应的枚举
    /// 翻译、不含数值,不会各自漂。
    var nsWeight: NSFont.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    /// 设置页那个下拉里的显示名。
    ///
    /// ⚠️ 刻意**不用**「Light / Regular / Medium / Semibold…」这套字体行业术语的中文直译。这一栏
    /// 面向的是"我想让歌词看起来粗一点/细一点"的人,不是排版从业者;真正的权重刻度在
    /// `appKitWeight` 里,不需要用界面文案去复述它。
    ///
    /// 中文取的是一条**单调的强度阶梯**:细 → 常规 → 稍粗 → 较粗 → 加粗 → 特粗,稍 / 较 / 加 /
    /// 特 四个程度副词自己就把顺序说清楚了,不用读者去记"semibold 比 medium 粗"。
    /// (2026-09-02 第一版写的是「中等 / 半粗」—— 前者读不出方向、后者是 semibold 直译,
    ///  跟这一行原来叫「字重」是同一类毛病,同一次一起改掉。英文保持行业术语不动:那边
    ///  Light/Regular/Medium/Semibold/Bold/Heavy 就是用户在任何字体选择器里看惯的说法。)
    var displayName: String {
        switch self {
        case .light: return L10n.t("细")
        case .regular: return L10n.t("常规")
        case .medium: return L10n.t("稍粗")
        case .semibold: return L10n.t("较粗")
        case .bold: return L10n.t("加粗")
        case .heavy: return L10n.t("特粗")
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
