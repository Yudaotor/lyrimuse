import CoreGraphics

/// 灵动岛 hover 展开区的高度算术。
///
/// 为什么单独放在 LyrimuseCore 而不是跟 `NotchMetrics` 的其它常量待在一起:那个类型在
/// App target 里(要用 SwiftUI 的东西),而 selftest 只依赖 LyrimuseCore。这几个数值是
/// 这次改动的核心契约(尤其"三样齐必须仍然等于 76"这条),值得被断言钉住,所以把**纯
/// 算术**这一小块下沉过来。`NotchMetrics` 只是转发到这里 —— 只有一份实现,不存在两处漂移。
public enum NotchExpandedMetrics {
    /// 展开区的**最大**高度(三样内容都在时)。
    ///
    /// 窗口恒按这个尺寸开(卡片在里面自己变大变小),设置页那条预览的容器也按它定高 ——
    /// 两处都不能跟着内容变,否则窗口/整页会被顶一下。
    ///
    /// 40 → 72 → 76(2026-08-19):展开区从「预览 + 进度条」加了一排完整三键(设计评审把
    /// 控制从右耳挪进展开卡),按 预览13 + 间距4 + 进度条槽6+3+时间行11 + 间距4 + 三键22 +
    /// 底边距10 累出来的;进度条布局槽后来钉成恒定 6pt(悬停变粗不再推邻居)多占了 3pt,
    /// 一并加上余量。
    public static let maxHeight: CGFloat = 76

    /// 恒有的那一段:三键 22 + 底边距 10 + 3pt 余量。
    /// `alignment: .top` 下这一段不够高会直接把最下面那排三键裁掉。
    public static let controlsBlock: CGFloat = 35
    /// 下一句歌词预览:行高 13 + 间距 4。
    public static let lyricPreviewBlock: CGFloat = 17
    /// 迷你进度条:槽 6+3 + 时间行 11 + 间距 4。
    public static let scrubberBlock: CGFloat = 24

    /// 展开区**此刻**该有多高 —— 按里面真正会渲染的东西算。
    ///
    /// 2026-08-21 用户报「没有歌词的时候这块太大、很多空的地方」。展开区原来恒高 76 且
    /// `alignment: .top`,而三样内容里有两样是条件渲染的:下一句歌词预览(没歌词就没有)、
    /// 迷你进度条(没时长就没有,见 NotchScrubber 的两个分支)。两样都缺时里面只剩一排三键,
    /// 剩下 41pt 全是底部的空白 —— 正是用户截图里那一大片。
    ///
    /// 三样齐 = 35+17+24 = 76,**跟改动前逐字相等**,所以有歌词有时长时布局一点没动。
    ///
    /// ⚠️ 两个入参刻意是**曲目级**信号(这首歌有没有歌词 / 有没有时长),不是"下一句此刻
    /// 是不是空的"。用后者会让最后一句唱完时卡片突然矮 17pt、下一首又长回来,肉眼是抽动;
    /// 曲目级信号在一首歌里恒定。代价是"有歌词但此刻恰好没有下一句"时那 17pt 是空的 ——
    /// 稳定压倒紧凑,这是有意的取舍。
    public static func height(hasLyricPreview: Bool, hasScrubber: Bool) -> CGFloat {
        var h = controlsBlock
        if hasLyricPreview { h += lyricPreviewBlock }
        if hasScrubber { h += scrubberBlock }
        return h
    }
}
