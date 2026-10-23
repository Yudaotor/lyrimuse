import CoreGraphics
import Foundation

/// 逐词歌词行(图层行)的长图按字体的上下沿开高;带组合附加符号的字会画出这个框:泰文叠起来的元音符号 +
/// 声调符号、阿拉伯文的元音符号、藏文的下加字。这种行出图前按实际画法量一遍墨迹(`OverlayRowRaster.inkPads`),
/// 超出的部分加进长图上下,见 04 章决策 74。
public enum LyricInkExtent {
    /// 含组合附加符号(Unicode 类别 Mn / Mc / Me)。不含的行字形都在字体上下沿之内,不用量。
    public static func mayOverflow(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }
    }

    /// 墨迹超出允许范围多少(点),向上对齐到整像素。坐标 y 向上、以长图底边为 0;允许范围是
    /// `[inset, boxHeight − inset]`:四周那圈预留要装描边和阴影,字形本身不能画进去。
    public static func pads(inkBottom: CGFloat, inkTop: CGFloat, boxHeight: CGFloat,
                            inset: CGFloat, scale: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        func alignedUp(_ v: CGFloat) -> CGFloat {
            v <= 0 ? 0 : (v * scale - 0.001).rounded(.up) / scale
        }
        return (alignedUp(inkTop - (boxHeight - inset)), alignedUp(inset - inkBottom))
    }
}
