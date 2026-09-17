import SwiftUI

/// 悬浮歌词毛玻璃背景的「浓淡」档位(2026-09-17,GitHub discussions#6)。
///
/// discussion 原话要的是"给背景/毛玻璃加一根 alpha/opacity 滑杆,而不是只有一个二元开关"。
/// 背景颜色那半已经有(`backgroundColorHex` 的 `ColorPicker(supportsOpacity: true)`,玻璃开着时
/// 这颗颜色就是叠在材质上的着色深浅);玻璃本身的"材质浓淡"这半在这颗设置加之前是写死的
/// `.regularMaterial`,没有任何调节口——这颗设置补的是这一半。
///
/// ⚠️ **做不成连续滑杆**:没有"模糊半径"这种可以连续插值的底层参数暴露出来。真要连续调,
/// 得抛开 SwiftUI 的 `Material`,自己包一层 `NSVisualEffectView` 的 `NSViewRepresentable`——
/// 那是明显更大的一次改动(还要接住"系统「减少透明度」开着时材质自动退成近乎不透明底色"这条
/// `LyricsOverlayView.overlayBackground` 里已经在吃的系统兜底,换成手搭的 NSVisualEffectView
/// 未必还能白得)。这里退而求其次,把 SwiftUI `Material` 本身**全部五档**离散预设
/// (`.ultraThin` / `.thin` / `.regular` / `.thick` / `.ultraThick`)都开出来给用户选——
/// 2026-09-17 当天最初只开了三档(薄/常规/厚),用户当场要求"既然系统本来就有 5 档,就不要
/// 缩成 3 档":系统给了多少粒度,就该原样透给用户,没有理由替用户多做一次取舍。
///
/// 默认 `.regular`:跟这颗设置加之前 `LyricsOverlayView` 硬编码的 `.regularMaterial` 完全
/// 一致,没碰过这颗设置的人升级后毛玻璃观感逐像素不变。
enum OverlayGlassIntensity: String, CaseIterable, Codable {
    case ultraThin
    case thin
    case regular
    case thick
    case ultraThick

    static let `default`: OverlayGlassIntensity = .regular

    /// L10n 键「常规」复用既有词:它已经是 `OverlayFontWeight.regular` 在用的那个键
    /// (English "Regular" / 繁体「標準」),同一个词在"浓淡"这个语境下含义没有分叉,
    /// 没必要另开一条只字面不同的翻译。其余四档是这颗设置专属的新键。
    var displayName: String {
        switch self {
        case .ultraThin: return L10n.t("超薄")
        case .thin: return L10n.t("薄")
        case .regular: return L10n.t("常规")
        case .thick: return L10n.t("厚")
        case .ultraThick: return L10n.t("特厚")
        }
    }

    var material: Material {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        case .ultraThick: return .ultraThickMaterial
        }
    }
}
