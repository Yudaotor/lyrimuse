import Foundation

/// 歌词窗口的文字色怎么定。
///
/// 加这颗设置之前,文字色是**背景的派生物**:`LyricsWindowBackgroundLuma` 按背景亮度算出"该白
/// 还是该跟随系统",全窗十几处配色都读那一个布尔。在默认档(跟随封面)下那套是对的 —— 封面背景
/// 必然够暗,白字必然成立。但它把两件事绑死了:**想要"深色背景配深色字""毛玻璃上钉死白字"
/// 这类搭配,根本表达不出来**,而用户能自己填背景之后,这恰恰是最常见的诉求。
///
/// 现在文字色是自己的一颗设置,只有 `.auto` 才回去问背景。
///
/// **它只管歌词文字(正文 / 译文 / 罗马音),不管窗口 chrome。** 音量胶囊、进度条、玻璃描边
/// 那些仍然按背景亮度走 —— 那几样要跟**背景**有对比度才看得见,跟用户给歌词挑了什么颜色无关。
/// 把它们也接上去的话,选一个深色文字会顺手把玻璃胶囊的亮边也翻黑,那圈亮边正是玻璃质感的来源。
public enum LyricsWindowTextColorMode: String, CaseIterable, Codable, Sendable {
    /// 跟着背景亮度走 —— 加这颗设置之前的唯一行为,也是默认,没碰过设置的人升级后逐像素不变。
    case auto
    /// 钉死浅色(白)。
    case light
    /// 钉死深色。
    case dark
    /// 用户自己给一个颜色。
    case custom

    /// 这一档要不要那颗调色盘。写成正面枚举而不是 `== .custom`,是照 `LyricsWindowBackgroundMode`
    /// 的前车之鉴:那边用否定式(`!= .artwork`)判"要不要颜色行",加「毛玻璃」档时颜色行跟着
    /// 冒了出来,界面上多了一个调了没反应的控件。
    public var usesCustomColor: Bool { self == .custom }

    /// 解析出来的色调,视图再把它映射成具体颜色(正文 / 副行各有各的透明度)。
    public enum Tone: Equatable, Sendable {
        case white
        /// 跟随系统前景色(`.primary` / `.secondary`)。
        case systemPrimary
        case dark
        case custom
    }

    /// 只有 `.auto` 看背景:有封面背景用白,否则跟随系统前景色 —— 这是加这颗设置之前的唯一
    /// 行为,没碰过设置的人升级后观感必须逐像素不变。其余三档钉死,不看背景。
    public func tone(hasArtworkBackground: Bool) -> Tone {
        switch self {
        case .auto: return hasArtworkBackground ? .white : .systemPrimary
        case .light: return .white
        case .dark: return .dark
        case .custom: return .custom
        }
    }
}
