import Foundation

/// 触控栏歌词的字号:默认 16pt,可调 13~20pt。上限按触控栏 30pt 的高定:图层行的位图高 = 字体上下伸 + 2pt,
/// 系统字体 20pt 约 26pt,23pt 就顶满 30pt(selftest 按系统字体逐档核着)。存着的值越界时,用的地方夹回区间。
/// 副行开着时两行的字号不听这一项,见下面「副行开着时的两行」。
public enum TouchBarLyricsStyle {
    public static let fontSizeRange: ClosedRange<Double> = 13...20
    public static let defaultFontSize: Double = 16

    /// 夹进 `fontSizeRange`;不是有限数(存坏了)时用默认值。
    public static func clampedFontSize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultFontSize }
        return min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    // MARK: - 副行开着时的两行(实测)
    //
    // 两行一起放进触控栏的 30pt 高,字号由这个高定:主行 14pt(字重同单行)、副行 11pt(细一档)。图层行的位图高是
    // 字体上下伸 + 2pt(系统字体 14pt → 19pt、11pt → 15pt),两张合计 34pt 放不进 30pt,所以两格上下叠一点:主行那一格
    // 上缘探出触控栏 1.5pt、副行那一格下缘探出 1pt,探出去的是位图上下那 1pt 留白和大写字母上的重音符(顶出 0.5pt)。
    // 按这两个落点量过墨迹(中日韩字、带下伸的拉丁字母,selftest 照图层行画字的办法逐项量着):主行汉字顶离上缘 1.5pt,
    // 副行汉字底离下缘 1.5pt,两行汉字之间空 2.5pt,主行 g / y 的下伸离副行汉字顶 1pt。

    public static let twoRowMainFontSize: Double = 14
    public static let twoRowSecondaryFontSize: Double = 11
    /// 两行各自那一格的上缘(离触控栏上缘多少点,负数 = 探出去)和高。高就是那一行的位图高:图层行把位图垂直居中在
    /// 自己那一格里,两者相等时位图正好落在这一格上。
    public static let twoRowMainTop: Double = -1.5
    public static let twoRowMainHeight: Double = 19
    public static let twoRowSecondaryTop: Double = 16
    public static let twoRowSecondaryHeight: Double = 15

    /// 副行的不透明度(乘在歌词色上),同灵动岛副行那三档:译文 75%、读音 60%、下一句 45%(它是预告,不跟正在唱的
    /// 这一句抢眼)。不显示是 0。
    public static func secondaryRowOpacity(for kind: LyricSecondaryLine) -> Double {
        switch kind {
        case .off: return 0
        case .nextLine: return 0.45
        case .translation: return 0.75
        case .romanization: return 0.6
        }
    }

    /// 黑底上打折的歌词色(未唱的部分、副行):效果同在黑底上打 `opacity` 这个透明度,但压暗之后的感知亮度(Rec.709
    /// luma)不低于白色打同一个折 —— 封面色本来就比白暗,直接打折在黑底上发糊。不够时朝白色混到那个亮度(同
    /// `LocalPlaybackSource.accentForDarkBackdrop` 的提法),色相族不变、饱和度跟着变淡;白色进来就是白打这个折的灰。
    /// 结果按不透明色用,只对恒黑的触控栏底成立。见 17 章决策 30。
    public static func dimmedOnBlack(r: Double, g: Double, b: Double, opacity: Double) -> (r: Double, g: Double, b: Double) {
        LocalPlaybackSource.accentForDarkBackdrop(r: r * opacity, g: g * opacity, b: b * opacity, lumaFloor: opacity)
    }

    // MARK: - 展开态的版面(实测)
    //
    // 系统模态条默认只占触控栏左边给 App 的那一块,右边收起的功能栏一直在;开了「展开时隐藏功能栏」时占满整条,
    // 功能栏和系统左端的 ✕ 一起收起(✕ 换成 App 自己的收起键)。真触控栏上歌词那一格填满剩下的宽度,由系统按
    // 此刻实际给 App 多宽来分;下面这几个数是默认的那一种(Xcode 触控栏模拟器 2nd generation、功能栏收起、里面多一枚
    // 第三方图标时实测),只给设置页预览和「本句会横向滚动」的判断用。左右怎么排(`TouchBarSlot.order`)不改宽度。

    /// 系统模态条给 App 的那一块的宽(左端的收起键也在里面)。
    public static let systemModalWidth: Double = 685
    /// 隐藏功能栏时系统模态条的宽:整条触控栏,左端没有系统的收起键。
    public static let fullWidthModalWidth: Double = 1004
    /// 第一项的左缘(收起键连同它两侧的留白)。隐藏功能栏时是 App 自己那颗收起键连同它后面的间距,数一样。
    public static let firstItemX: Double = 64
    /// 相邻两项之间的间距(系统定的)。
    public static let itemSpacing: Double = 8
    /// App 自己那颗收起键的宽:连同后面的间距正好等于 `firstItemX`,两种模式下封面、三键、歌词的左缘对得上。
    public static let collapseItemWidth: Double = 56
    /// 封面那一项(30pt)连同它后面的间距(8pt)。
    public static let artworkSlot: Double = 38
    /// 三键加设置键那一项(4 × 44 的分段控件,实测 182pt;只有三键时是 136pt)连同它后面的间距。
    public static let controlsSlot: Double = 190

    // MARK: - 1st generation:左端是一颗虚拟 Esc 键(实测)
    //
    // 左端 0~80pt 是系统的 Esc 那一格。系统模态条一展开就占掉它(默认展开时换成系统的 ✕,隐藏功能栏时整条盖住);
    // App 用 `escapeKeyReplacementItemIdentifier` 放回自己那颗 esc 键之后,两种展开方式下都是 esc 键贴左缘、收起键
    // 从 80pt 起排,封面、三键、歌词的左缘一样。Xcode 触控栏模拟器 1st generation 实测,见 17 章决策 36。

    /// App 自己那颗 esc 键的宽,同系统的 Esc 键。
    public static let escapeKeyWidth: Double = 64
    /// 系统的 Esc 那一格:esc 键连同它后面的间距(系统定的 16pt)。
    public static let escapeSlotWidth: Double = 80
    /// 1st generation 上系统模态条给 App 的那一块(从左缘算起,Esc 那一格也在里面)。
    public static let systemModalWidthWithEscapeKey: Double = 765
    /// 1st generation 上隐藏功能栏时系统模态条的宽:整条触控栏。
    public static let fullWidthModalWidthWithEscapeKey: Double = 1085

    /// 歌词那一格分到的宽:收起键、封面、三键之后剩下的全给它。`escapeKey`(1st generation,左端放了自己的 esc 键)时
    /// 前面多一个 Esc 那一格。
    public static func lyricsWidth(showsArtwork: Bool, showsControls: Bool, hidesControlStrip: Bool = false,
                                   escapeKey: Bool = false) -> Double {
        let modal = escapeKey
            ? (hidesControlStrip ? fullWidthModalWidthWithEscapeKey : systemModalWidthWithEscapeKey)
            : (hidesControlStrip ? fullWidthModalWidth : systemModalWidth)
        return modal - (escapeKey ? escapeSlotWidth : 0) - firstItemX
            - (showsArtwork ? artworkSlot : 0) - (showsControls ? controlsSlot : 0)
    }
}
