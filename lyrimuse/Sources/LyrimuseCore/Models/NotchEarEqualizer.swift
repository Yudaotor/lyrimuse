import CoreGraphics

/// 音浪贴在一只耳朵外沿时,这只耳朵画不画音浪、模块那一格还剩多宽。耳朵模块枚举在 App 里(`NotchEarModule`),这里只放判据和算术。
///
/// 音浪画在耳朵外沿(远离刘海那一侧),模块排在它内侧。只有「播放控制」让位:播放 / 暂停键本身就在报播放状态,窄宽度下三键的
/// 48pt 也挤不进音浪那一截。歌词耳朵照挂音浪,歌词槽扣掉音浪占的宽,句子放得下时仍贴刘海那一侧。见 05 章决策 165。
/// 渲染(`NotchLyricsView.topRow`)、宽度下限(`NotchLyricsWindowController.minEarWidths`)、工具栏摘要、`debug/state` 都读这一份。
public enum NotchEarEqualizer {
    /// 这只耳朵画不画音浪。只看开关、贴哪一侧、这只耳朵是不是播放控制;不看歌词耳朵此刻画的是当前句还是下一句,
    /// 两耳轮流换句时音浪原地不动。
    public static func draws(showsEqualizer: Bool, onThisEar: Bool, yieldsToModule: Bool) -> Bool {
        showsEqualizer && onThisEar && !yieldsToModule
    }

    /// 音浪在这只耳朵里占的宽:条宽加它跟模块之间的间距;不画时 0。
    public static func allowance(draws: Bool, barsWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        draws ? barsWidth + spacing : 0
    }

    /// 模块那一格能用的宽 = 耳宽 − 朝刘海内缩 − 音浪占位,不小于 0。
    public static func slotWidth(earWidth: CGFloat, notchInset: CGFloat, allowance: CGFloat) -> CGFloat {
        max(0, earWidth - notchInset - allowance)
    }
}
