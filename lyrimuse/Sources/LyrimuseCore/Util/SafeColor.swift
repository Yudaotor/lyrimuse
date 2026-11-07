import AppKit

extension NSColor {
    /// 读 RGB 分量之前用的那份:转成 sRGB;转不过去的(图案色这类)退回 sRGB 白。别退回 `NSColor.white`:它在灰度色彩空间里,
    /// 读 `redComponent` 一样抛 Objective-C 异常。见 15 章决策 105。
    public var sRGBOrWhite: NSColor {
        usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }
}
