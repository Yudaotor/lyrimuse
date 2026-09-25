import CoreGraphics
import Foundation

// 歌词窗口里不依赖视图的判定与公式。视图只负责把状态喂进来、把结果画出去;
// 放在 Core 是为了 selftest 能直接调(App target 里的逻辑只能扫源码文本)。

/// 歌词那一栏没有可画的歌词时,显示哪一档占位。
///
/// **顺序就是优先级,不能调换**:
/// - 没在放(曲名为空,停播时 LocalPlaybackSource 会把曲目信息一并清掉)排第一:这时候说"无歌词"
///   是答非所问,不是这首歌没词,是压根没有"这首歌"。
/// - 广告、口白、纯音乐必须排在"搜索中"前面:这几种情况下也没有歌词内容,排在后面的话会一直显示
///   「搜索歌词中…」而且永远没有下文;口白期间元数据还停在上一首,不先拦住就会接着报上一首的状态。
/// - 「暂无歌词」排在「网络连接失败」前面:前者是搜完的明确结论,比"此刻没网"更有信息量。断网
///   那一档必须有:collector 什么都查不到、全空又不写缓存,hasLyricsContent 永远是 false,不插
///   这一档就会一直停在「搜索歌词中…」。
public enum LyricsWindowEmptyState: Equatable, Sendable {
    case notPlaying
    case adBreak
    case radioTalk
    case instrumental
    case noLyrics
    case networkDown
    case searching
    case none

    public struct Inputs: Sendable {
        public var hasTitle: Bool
        public var isAdBreak: Bool
        public var isRadioTalkBreak: Bool
        public var isInstrumental: Bool
        public var hasNoLyrics: Bool
        public var collectorNetworkDown: Bool
        public var hasLyricsContent: Bool
        public var isPlaying: Bool

        public init(hasTitle: Bool, isAdBreak: Bool = false, isRadioTalkBreak: Bool = false,
                    isInstrumental: Bool = false, hasNoLyrics: Bool = false,
                    collectorNetworkDown: Bool = false, hasLyricsContent: Bool = false,
                    isPlaying: Bool = false) {
            self.hasTitle = hasTitle
            self.isAdBreak = isAdBreak
            self.isRadioTalkBreak = isRadioTalkBreak
            self.isInstrumental = isInstrumental
            self.hasNoLyrics = hasNoLyrics
            self.collectorNetworkDown = collectorNetworkDown
            self.hasLyricsContent = hasLyricsContent
            self.isPlaying = isPlaying
        }
    }

    public static func resolve(_ i: Inputs) -> LyricsWindowEmptyState {
        if !i.hasTitle { return .notPlaying }
        if i.isAdBreak { return .adBreak }
        if i.isRadioTalkBreak { return .radioTalk }
        if i.isInstrumental { return .instrumental }
        if i.hasNoLyrics { return .noLyrics }
        if i.collectorNetworkDown && !i.hasLyricsContent { return .networkDown }
        if i.isPlaying && !i.hasLyricsContent { return .searching }
        return .none
    }

    /// SF Symbol 名。
    public var icon: String {
        switch self {
        case .notPlaying: return "music.note"
        case .adBreak: return "megaphone"
        case .radioTalk: return "dot.radiowaves.left.and.right"
        case .instrumental: return "waveform"
        case .noLyrics: return "text.badge.xmark"
        case .networkDown: return "wifi.slash"
        case .searching: return "magnifyingglass"
        case .none: return "text.quote"
        }
    }

    /// 这一档要不要给「搜索歌词」入口:只有确定没找到(没有 / 网络失败)时才给,还在搜、
    /// 纯音乐、广告这些给了也没意义。
    public var offersSearch: Bool {
        switch self {
        case .noLyrics, .networkDown: return true
        default: return false
        }
    }
}

/// 歌词字号。
public enum LyricsWindowTypography {
    /// 整页列表(完整布局 / 迷你「多行」)的正文字号。系数从 Apple Music 歌词页整窗截图量出:
    /// 0.0598×视口高、0.0564×栏宽,取小的那个 —— 窗口偏矮时高度锚接管(保住"一屏约 7 行"),
    /// 偏窄时宽度锚接管(别让长句疯狂折行)。下限 22。
    ///
    /// 栏宽 / 视口高还没量到(≤0)时按 460 / 640 算。`cap` 是迷你档那根「字号」上限,完整布局传 nil。
    public static func listFontSize(columnWidth: CGFloat, viewportHeight: CGFloat,
                                    cap: CGFloat? = nil) -> CGFloat {
        let w = columnWidth > 0 ? columnWidth : 460
        let h = viewportHeight > 0 ? viewportHeight : 640
        let size = max(22, min(h * 0.0598, w * 0.0564))
        guard let cap else { return size }
        return min(size, cap)
    }

    /// 迷你「简洁」两行那套的正文字号:跟着窗口长,但比列表比例大得多(只排一行半)。
    /// `cap` 是用户设的上限,不是定值;窗口被拖小时仍由宽高压下来。下限 12 保证认得出字。
    public static func miniFontSize(_ size: CGSize, cap: CGFloat) -> CGFloat {
        max(12, min(cap, size.height * 0.17, size.width * 0.075))
    }
}

/// 歌词列表每行的景深(远近靠透明度 + 模糊区分,不靠字号)。
public enum LyricsWindowDepth {
    /// 距离封顶:再远的行都按这一档画。
    public static let maxDistance = 4

    /// 第 `index` 行离"当前"几行。锚点用**滚动锚**(空档里提前指向下一句),没有锚点返回 nil。
    /// 间奏进行中整体退一档 —— 此刻的"当前"是那排「•••」,唱完的那行不该再保持全亮。
    public static func distance(index: Int, anchorIndex: Int?, inGap: Bool) -> Int? {
        guard let anchorIndex else { return nil }
        return min(abs(index - anchorIndex) + (inGap ? 1 : 0), maxDistance)
    }

    /// 不透明度:当前行 1;d1/d2 0.42,之后每行再降 0.10,最低 0.22。没有锚点 0.45。
    public static func opacity(distance: Int?) -> Double {
        guard let d = distance else { return 0.45 }
        if d == 0 { return 1 }
        return max(0.22, 0.42 - 0.10 * Double(max(0, d - 2)))
    }

    /// 模糊半径:σ = 0.0148 × (d+1) × 字号(从 AM 截图解出的严格线性关系);当前行不糊,
    /// 没有锚点按 0.03 × 字号。
    public static func blurRadius(distance: Int?, fontSize: CGFloat) -> CGFloat {
        guard let d = distance else { return fontSize * 0.03 }
        if d == 0 { return 0 }
        return fontSize * 0.0148 * CGFloat(d + 1)
    }
}

/// 迷你「简洁」两行那套显示哪两句。
public enum MiniLyricsSelection {
    /// 当前行:引擎给的下标有效才有。
    public static func currentIndex(currentLineIndex: Int?, lineCount: Int) -> Int? {
        guard let i = currentLineIndex, i >= 0, i < lineCount else { return nil }
        return i
    }

    /// 下一行:当前行的下一句;还没唱到第一句(当前行为 nil)时把第一句当预告。
    public static func nextIndex(currentLineIndex: Int?, lineCount: Int) -> Int? {
        guard let i = currentLineIndex else { return lineCount > 0 ? 0 : nil }
        let j = i + 1
        return j >= 0 && j < lineCount ? j : nil
    }
}

/// Apple Music 式 vibrancy 的亮度档:次级文字用背景色相的亮化低饱和版,亮度按元素档位给,
/// 再保证跟背景的亮度差。
public enum AMVibrancy {
    /// - Parameters:
    ///   - brightness: 这类元素的基础亮度档(从暗封面反解出来的)。
    ///   - backgroundBrightness / backgroundSaturation: 烘焙背景的平均色(HSB)。
    ///   - minContrast: 跟背景的最小亮度差;nil = 不做对比度保护(控件类)。
    ///
    /// 方向是**提亮**:背景亮起来时把文字推到背景亮度 + minContrast(封顶 0.97)。唯一压暗分支是
    /// 背景又亮又淡(亮度 > 0.75 且饱和 < 0.5,近白封面),淡奶油提不出对比,退成背景亮度 − 0.32
    /// (不低于 0.22)的深色。
    public static func brightness(base brightness: Double, backgroundBrightness bgV: Double,
                                  backgroundSaturation bgS: Double, minContrast: Double?) -> Double {
        guard let minC = minContrast, bgV > 0, brightness - bgV < minC else { return brightness }
        if bgV <= 0.75 || bgS >= 0.5 {
            return min(0.97, max(bgV + minC, brightness))
        }
        return max(0.22, bgV - 0.32)
    }
}
