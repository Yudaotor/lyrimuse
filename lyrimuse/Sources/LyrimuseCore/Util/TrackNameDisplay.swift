import Foundation

/// 歌名 / 歌手 / 专辑画到界面上之前的清洗。只给显示用:缓存 key、搜索、链接、打卡一律用原串。
///
/// 去掉跟在汉字 / 假名 / 韩文后面的组合包围符号(Unicode 类别 Me,如 U+20E0「⃠」、U+20DD「⃝」):
/// 字和叠在上面的符号必须用同一款字体画,苹方没有这些符号,系统会把这个字整个换成 Arial Unicode MS,
/// 而那款字体摆不正符号,画出来是一团糊。拉丁字母、数字后面的照留:它们画得出来,
/// 数字键帽表情(1️⃣ = 数字 + U+FE0F + U+20E3)也靠这一类符号。
public enum TrackNameDisplay {
    public static func cleaned(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isEnclosingMark) else { return text }
        var out = String.UnicodeScalarView()
        var base: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if isEnclosingMark(scalar), let base, isEastAsian(base) { continue }
            out.append(scalar)
            if !attachesToBase(scalar) { base = scalar }
        }
        return String(out)
    }

    private static func isEnclosingMark(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .enclosingMark
    }

    /// 组合符号和变体选择符挂在前一个字上,不换「前一个字」。
    private static func attachesToBase(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return scalar.properties.isVariationSelector
        }
    }

    private static func isEastAsian(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true  // 假名
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF: return true  // 韩文
        default: return false
        }
    }
}
