import Foundation

/// 歌词窗口的背景。
///
/// 默认 `.artwork` —— 也就是加这个设置之前唯一的样子,没碰过这颗设置的人升级后逐像素不变。
///
/// 三档:一档跟着封面走,两档用户自己给颜色。**没有**「系统外观」这一档 —— 拿不到封面时本来
/// 就会退回系统窗口底色(`artworkBackground` 那个 `if let` 不成立就什么都不画),那是兜底行为
/// 不是可选项。
///
/// (曾经有第四档「模糊封面」= 只画烘焙好的暗底、不叠光斑,后来去掉了。rawValue 认不出来会
///  回落到 `.artwork`(见 AppSettings 的 `flatMap(init(rawValue:)) ?? .artwork`),所以存过那个
///  值的配置不会卡住,会自然退回默认档。)
public enum LyricsWindowBackgroundMode: String, CaseIterable, Codable, Sendable {
    /// 跟随封面:暗底 + 3 片取自封面不同区域的光斑,绕偏心锚点慢转。AM 歌词页那层"流动的光"。
    case artwork
    /// 自定义纯色(带不透明度)。
    case solid
    /// 自定义渐变(两端各一个颜色,各自带不透明度)。
    case gradient
    /// 毛玻璃:一层系统材质,折射窗口背后的桌面。浓淡另有一颗设置(五档 Material)。
    case glass

    /// 这一档要不要用封面烘焙出来的图层。其余三档完全不碰封面。
    public var usesArtwork: Bool { self == .artwork }

    /// 这一档要不要用户自己给颜色。
    ///
    /// 写成正面枚举而不是 `!= .artwork`:加「毛玻璃」那次就是因为用了否定式,颜色那一行跟着
    /// 冒了出来 —— 毛玻璃只画系统材质、根本不读那个颜色,于是界面上多出一个调了没反应的控件。
    /// 以后再加档位,漏的只会是这里一处。
    public var usesCustomColor: Bool { self == .solid || self == .gradient }

    /// 这一档要不要让窗口本体透出去。
    ///
    /// 毛玻璃**必须**透 —— 材质折射的是"窗口背后有什么",窗口自己不透明的话它折射到的只有
    /// 窗口底色,看起来就是一块死灰。自定义颜色那两档另看 alpha(见 LyricsWindowView 的
    /// wantsTransparentWindow),封面那档铺的是不透明图层、没有透出去这回事。
    public var alwaysNeedsTransparentWindow: Bool { self == .glass }
}

/// 渐变的方向。
///
/// 默认竖向:歌词是从上往下读的,横向渐变会让**同一行字**的左右两半压在不同亮度上 —— 一行里
/// 越往右越难读(或越往左),这是竖向没有的问题。横向仍然开放,因为这扇窗是双列布局(左封面、
/// 右歌词),横向渐变能做出"封面那一侧深、歌词那一侧浅"这种跟布局对齐的效果。
public enum LyricsWindowGradientDirection: String, CaseIterable, Codable, Sendable {
    /// 从上到下。
    case vertical
    /// 从左到右。
    case horizontal
}

/// 背景够不够暗 —— 决定这扇窗的文字走白色还是跟随系统。
///
/// 为什么非要算:`hasArtworkBackground` 原来就是 `artworkData != nil`,而全窗十几处配色
/// (主文字/副行/时间/进度/图标/面板)都读它决定"白字还是 .primary"。那条捷径之所以一直成立,
/// 是因为封面背景**必然**是暗的(烘焙压过 EV −1.9,视图层还盖了 0.15 黑遮罩)。用户能自己填
/// 颜色之后这个前提就没了 —— 填一个浅黄背景,白字直接消失。
///
/// 放在 LyrimuseCore 而不是 AppSettings 边上,是为了 selftest 够得到:这里面有 sRGB 线性化、
/// alpha 混合、渐变取平均三处容易算错又不会崩的地方,靠肉眼看界面是发现不了边界情况的。
/// 代价是不能用 `NSColor(hexStringWithAlpha:)`(那个扩展在 lyrimuse target),自己解析 hex。
public enum LyricsWindowBackgroundLuma {
    /// 阈值:有效亮度高于它就算"浅底",文字要跟随系统(深色字);否则维持白字。
    ///
    /// 取 0.3 的依据是 WCAG 相对亮度下**大号文本**的 3:1 对比度线 —— 白字要 `L ≤ 0.3`,
    /// 黑字要 `L ≥ 0.1`,中间那段两者都勉强。歌词窗口的正文是大号粗体,落在大文本档;
    /// 取区间的上沿而不是中点,是因为这扇窗的整套设计语言(vibrancy 次级染色、0.15 遮罩)
    /// 都是为深底配的,能维持白字就维持。
    public static let lightTextThreshold = 0.3

    /// 窗口系统底色的近似相对亮度,给半透明背景做 alpha 混合用。
    ///
    /// 写成常量而不是去读 `NSColor.windowBackgroundColor`:这个类型在 LyrimuseCore 里
    /// 拿不到 AppKit 的动态颜色解析(那要 NSAppearance 上下文),而这两个值只影响"半透明
    /// 自定义色到底算深还是浅"这一个判断,近似足够。数值取自 macOS 浅色 #ECECEC / 深色
    /// #323232 线性化后的相对亮度。
    public static let lightModeBackdropLuma = 0.78
    public static let darkModeBackdropLuma = 0.03

    /// sRGB 单通道线性化(WCAG 2.x 的那条分段函数)。
    private static func linearize(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// 解析 `#RRGGBB` / `#RRGGBBAA`(井号可省)。认不出来返回 nil —— 调用方按"没设过颜色"处理,
    /// 不要自己编一个默认色,那会让"配置坏了"表现成"颜色莫名其妙变了"。
    public static func parse(hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let shift = hasAlpha ? 8 : 0
        let r = Double((v >> (16 + shift)) & 0xFF) / 255
        let g = Double((v >> (8 + shift)) & 0xFF) / 255
        let b = Double((v >> shift) & 0xFF) / 255
        let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
        return (r, g, b, a)
    }

    /// 一个颜色**盖在窗口底色上之后**的相对亮度。
    public static func effectiveLuma(hex: String, darkAppearance: Bool) -> Double? {
        guard let c = parse(hex: hex) else { return nil }
        let own = 0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
        let backdrop = darkAppearance ? darkModeBackdropLuma : lightModeBackdropLuma
        // 半透明色实际看到的是它和窗口底色的混合 —— 一个 alpha 0.2 的黑,在浅色模式下
        // 仍然是个浅背景,白字照样看不见。
        return own * c.a + backdrop * (1 - c.a)
    }

    /// 这组颜色(纯色给一个、渐变给两个)该不该用白字。
    ///
    /// 渐变取两端**平均**而不是取较亮那端:取亮端会让"深色到中灰"这种很常见的渐变被判成浅底、
    /// 整窗翻成深色字,而它的主体其实是暗的。平均在两端亮度悬殊时对某一端不利,但那种配色本来
    /// 就没有哪种文字色能同时照顾到,不该让判据为一个无解的情况牺牲常见情况。
    public static func prefersLightText(hexes: [String], darkAppearance: Bool) -> Bool {
        let lumas = hexes.compactMap { effectiveLuma(hex: $0, darkAppearance: darkAppearance) }
        guard !lumas.isEmpty else { return true } // 颜色认不出来:维持这扇窗原来的白字
        let avg = lumas.reduce(0, +) / Double(lumas.count)
        return avg <= lightTextThreshold
    }
}
