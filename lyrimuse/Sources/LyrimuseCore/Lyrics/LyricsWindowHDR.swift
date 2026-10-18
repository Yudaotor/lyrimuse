import CoreGraphics

/// 歌词窗口「HDR 高亮」:当前行已唱的那一端提亮到普通白以上。屏幕的 EDR 余量不够这个倍数时,系统压到它给得出的上限;
/// 没有余量的屏幕上跟普通白一样。只提亮白、灰这类不带颜色的:有颜色的各通道在没有余量的屏幕上分别截断,色相会偏。
/// 见 07 章决策 165、167。
public enum LyricsWindowHDR {
    /// 提亮倍数:颜色换到扩展线性 sRGB 后三个通道一起乘它,透明度不动。
    public static let gain: CGFloat = 2
    /// 三个通道的最大差不超过最亮通道的这个比例,算不带颜色。
    public static let neutralTolerance: CGFloat = 0.1

    /// 提亮后的颜色;带颜色的、换不了色彩空间的原样返回。
    public static func boosted(_ color: CGColor, gain: CGFloat = gain) -> CGColor {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let linear = color.converted(to: space, intent: .defaultIntent, options: nil),
              let c = linear.components, c.count >= 4, isNeutral(c[0], c[1], c[2])
        else { return color }
        return CGColor(colorSpace: space, components: [c[0] * gain, c[1] * gain, c[2] * gain, c[3]]) ?? color
    }

    /// 线性分量是不是白 / 灰(不带颜色)。
    public static func isNeutral(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
        let top = max(r, g, b)
        return top <= 0 || (top - min(r, g, b)) <= top * neutralTolerance
    }

    /// 颜色有没有超过普通白(任一通道大于 1)。超过的图层要声明扩展范围,不声明的话屏幕不提亮,看起来还是普通白。
    public static func exceedsStandardRange(_ color: CGColor) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let c = color.converted(to: space, intent: .defaultIntent, options: nil)?.components, c.count >= 3
        else { return false }
        return c.prefix(3).contains { $0 > 1.0001 }
    }
}
