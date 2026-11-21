import CoreGraphics
import CoreText
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

    /// 一段排成一行的字的字形墨迹框(点;原点在基线起点、y 向上),按字形轮廓量,不栅格化。
    /// 彩色位图字形(emoji)没有轮廓、量不到,它们不出排版框。
    public static func glyphBounds(_ string: NSAttributedString) -> CGRect {
        guard string.length > 0 else { return .zero }
        let line = CTLineCreateWithAttributedString(string)
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    }

    /// 同一段字的排版上沿、下沿(点,都取正值),跟 `glyphBounds` 同一条 CoreText 行。
    public static func typographicExtent(_ string: NSAttributedString) -> (ascent: CGFloat, descent: CGFloat) {
        guard string.length > 0 else { return (0, 0) }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (ascent, descent)
    }

    /// 菜单栏单行长图上下各补多少(整点)。坐标 y 向上、以长图底边为 0,`inkTop` / `inkBottom` 是墨迹上下沿,
    /// `box` 是不补时的框高,补完的框不超过 `cap`(状态栏按钮的高)。放得下时补到盖住墨迹;放不下时补满 `cap`,
    /// 剩下出框的部分上下各裁一半。高棉、藏文、缅甸、卡纳达、泰卢固的叠字出框 1.5～4.5pt(见 06 章决策 113)。
    public static func menuBarPads(inkTop: CGFloat, inkBottom: CGFloat, box: CGFloat,
                                   cap: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        func up(_ v: CGFloat) -> CGFloat { v <= 0 ? 0 : (v - 0.001).rounded(.up) }
        let needTop = up(inkTop - box), needBottom = up(-inkBottom)
        let room = max(0, (cap - box).rounded(.down))
        guard needTop + needBottom > room else { return (needTop, needBottom) }
        let top = min(room, max(0, ((room + needTop - needBottom) / 2).rounded()))
        return (top, room - top)
    }

    /// 菜单栏单行长图上下各补多少:这段字用 `draw(at: (0, 1 + 下补))` 画,基线在框底往上 1pt + 主字体下沿处
    /// (`draw(at:)` 按主字体的下沿摆,不按回退字体的),墨迹按字形轮廓量、上下各加 0.5pt 抗锯齿。`fontDescender` 是负数。
    public static func menuBarPads(for string: NSAttributedString, fontDescender: CGFloat, box: CGFloat,
                                   cap: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let ink = glyphBounds(string)
        guard !ink.isNull, !ink.isEmpty else { return (0, 0) }
        let baseline = 1 - fontDescender
        return menuBarPads(inkTop: baseline + ink.maxY + 0.5, inkBottom: baseline + ink.minY - 0.5, box: box, cap: cap)
    }
}
