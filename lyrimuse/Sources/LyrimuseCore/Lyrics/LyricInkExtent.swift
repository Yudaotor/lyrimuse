import CoreGraphics
import Foundation

/// 逐词歌词行(图层行)的长图按字体的上下沿和量出来的字宽开;字形会画出这个框:泰文叠起来的元音符号 + 声调符号、
/// 阿拉伯文的元音符号、藏文和高棉文的下加字往上下出,天城文、亚美尼亚文的末字往右出,用户换了字体时拉丁字母的
/// 下伸也会出。每一行出图前按实际画法量一遍墨迹(`OverlayRowRaster.inkOverflow`),超出的部分补进长图,
/// 见 04 章决策 74、75。
public enum LyricInkExtent {
    /// 墨迹要补多少(点,已对齐到整像素)。上下分开补;左右取两边较大的那个,作为两侧对称加宽的出血。
    public struct Overflow: Equatable, Sendable {
        public var top: CGFloat
        public var bottom: CGFloat
        public var side: CGFloat

        public init(top: CGFloat, bottom: CGFloat, side: CGFloat) {
            self.top = top
            self.bottom = bottom
            self.side = side
        }

        public static let none = Overflow(top: 0, bottom: 0, side: 0)
    }

    /// 坐标 y 向上、以长图左下角为原点;允许墨迹落在 `[inset, 宽 − inset] × [inset, 高 − inset]` 之内:
    /// 四周那圈预留要装描边和阴影,字形本身不能画进去。
    public static func overflow(inkLeft: CGFloat, inkRight: CGFloat, inkBottom: CGFloat, inkTop: CGFloat,
                                boxWidth: CGFloat, boxHeight: CGFloat, inset: CGFloat,
                                scale: CGFloat) -> Overflow {
        func alignedUp(_ v: CGFloat) -> CGFloat {
            v <= 0 ? 0 : (v * scale - 0.001).rounded(.up) / scale
        }
        return Overflow(top: alignedUp(inkTop - (boxHeight - inset)),
                        bottom: alignedUp(inset - inkBottom),
                        side: alignedUp(max(inset - inkLeft, inkRight - (boxWidth - inset))))
    }
}
