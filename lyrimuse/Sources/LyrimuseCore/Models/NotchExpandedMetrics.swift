import CoreGraphics

/// 灵动岛 hover 展开区的高度算术。
///
/// 为什么单独放在 LyrimuseCore 而不是跟 `NotchMetrics` 的其它常量待在一起:那个类型在
/// App target 里(要用 SwiftUI 的东西),而 selftest 只依赖 LyrimuseCore。这几个数值是
/// 这次改动的核心契约(尤其"三样齐必须仍然等于 76"这条),值得被断言钉住,所以把**纯
/// 算术**这一小块下沉过来。`NotchMetrics` 只是转发到这里 —— 只有一份实现,不存在两处漂移。
public enum NotchExpandedMetrics {
    /// 播放控制那一段:三键 22 + 底边距 10 + 3pt 余量。
    /// `alignment: .top` 下这一段不够高会直接把最下面那排三键裁掉。
    ///
    /// ⚠️ **不再是"恒有"**(2026-09-01 之前是):这排键 2026-08-19 从右耳搬进展开卡以来
    /// 一直无条件显示,用户这次要求"加一个控制键是否展示"的开关,于是它从 `height(...)`
    /// 里**永远加一次**的常量,变成第三个 `if 开关 { h += controlsBlock }` 分支——性质
    /// 是**用户设置**,跟下一句预览/迷你进度条那两个"曲目级数据信号"不是一回事,更接近
    /// `trackInfoHeight` 那一类(设置一变会触发 `NotchLyricsWindowController` 重算几何,
    /// 不需要按"最坏情况"钉死,`maxHeight` 的 `hasControlsPossible` 直接传当前设置值
    /// 而不是恒 true)。
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
    /// 三样齐 = 35+17+24 = 76,**跟改动前逐字相等**,所以有歌词有时长且播放控制键开着时
    /// 布局一点没动。
    ///
    /// ⚠️ `hasLyricPreview`/`hasScrubber` 两个入参刻意是**曲目级**信号(这首歌有没有歌词 /
    /// 有没有时长),不是"下一句此刻是不是空的"。用后者会让最后一句唱完时卡片突然矮 17pt、
    /// 下一首又长回来,肉眼是抽动;曲目级信号在一首歌里恒定。代价是"有歌词但此刻恰好没有
    /// 下一句"时那 17pt 是空的 —— 稳定压倒紧凑,这是有意的取舍。
    ///
    /// `hasControls`(2026-09-01)性质不一样:它是**用户设置**(播放控制键要不要显示),
    /// 不是曲目级数据信号——跟 `trackInfoHeight` 同一类,见 `controlsBlock` 声明处的注释。
    ///
    /// `trackInfoHeight`(2026-09-01,「曲目信息头部」——展开区里可选的歌名/歌手/专辑
    /// 那一块)是第三个维度,但**性质跟前两个不一样**:前两个是曲目级数据信号,这个是
    /// **用户设置**的派生值(见 `trackInfoHeight(showsArtwork:showsTitle:showsArtist:showsAlbum:)`)。
    /// 调用方(`NotchMetrics.expandedTrackInfoHeight`)按当前设置现算好传进来,这个函数不
    /// 关心它是怎么来的,只管加不加、加多少 —— 跟 `hasLyricPreview`/`hasScrubber` 一样是
    /// "只加一次、且这次的间距已经包含在值里"的一整块,0 表示这块完全不占地方(不渲染)。
    ///
    /// ⚠️ 头部占用 `trackInfoHeight + trackInfoSpacing * 2`——**两份**间距,不是一份:
    /// 一份贴在上边(2026-09-01 用户报"标题首行贴到上面边了",头部紧挨在 topRow 下面,
    /// 原来零间距),一份贴在下边(离下面歌词行的间距,加这块之前就有)。渲染那侧
    /// (`NotchLyricsView.trackInfoHeader`)只在**内容顶部**加一次 `.padding(.top:
    /// trackInfoSpacing)`——`.frame(alignment: .top)` 已经把内容锚在分配到的这块高度的
    /// 顶部,上下各留一份间距的效果因此不需要在视图那侧显式凑两次 padding,只要这里的
    /// 高度算术把两份都算进去、视图那侧把 topRow 与内容之间那一份实现出来即可。
    public static func height(
        hasLyricPreview: Bool, hasScrubber: Bool, hasControls: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        var h: CGFloat = hasControls ? controlsBlock : 0
        if hasLyricPreview { h += lyricPreviewBlock }
        if hasScrubber { h += scrubberBlock }
        if trackInfoHeight > 0 { h += trackInfoHeight + trackInfoSpacing * 2 }
        return h
    }

    // MARK: - 曲目信息头部(2026-09-01)

    /// 头部本身跟下一行内容之间的间距。
    public static let trackInfoSpacing: CGFloat = 4
    /// 头部里封面缩略图的边长——跟歌词行尾端那枚同一档(`NotchMetrics.artworkSide` 的
    /// 上限 32),两处都在同一张卡片里,没理由长得不一样大。
    public static let trackInfoArtworkSide: CGFloat = 32
    /// 歌名/歌手/专辑三行各自的行高。歌名字号最大(跟卡片其它"主要信息"一个字号台阶),
    /// 歌手/专辑依次收一档——观感上是"标题 + 两行注解",不是三行同等重量的文字。
    public static let trackInfoTitleLineHeight: CGFloat = 14
    public static let trackInfoArtistLineHeight: CGFloat = 12
    public static let trackInfoAlbumLineHeight: CGFloat = 11
    /// 文字块内部,行与行之间的间距(跟耳朵/歌词那些跑马灯文字的紧凑行距是同一个尺度)。
    public static let trackInfoLineSpacing: CGFloat = 1

    /// 曲目信息头部要占多高 —— 四个开关(封面/歌名/歌手/专辑)现算,不查表。
    ///
    /// ⚠️ **封面落点反复过**:最初设计里就带一枚,用户看过效果后指出"跟歌词行末尾已有的
    /// 那枚封面重复了",要求并回那一枚(`notchLyricRowShowsArtwork`,只影响
    /// `NotchLyricsView.lyricRowContent` 内部排列,曾一度不参与这个函数的高度算术);过了
    /// 几轮之后用户又要求"在展开态里面多增加一个显示封面",重新给头部配上**自己**的一枚,
    /// 这次没有位置四选一——固定贴文字块左边,所以高度算术只需要"封面和文字块谁更高"的
    /// `max`,不需要"并排/堆叠"两种模式的复杂度(那是上一版设计出来、后来被撤掉的东西)。
    ///
    /// ⚠️ 每一项的高度只看"这个开关开没开",不看"这首歌这个字段是不是空字符串/有没有
    /// 封面数据"——跟 `height(hasLyricPreview:hasScrubber:)` 那条"曲目级信号,不是此刻
    /// 有没有内容"的纪律同源:开关是稳定的会话级配置,按它留出的高度不该因为某一首歌
    /// 恰好没有专辑名/封面就抽一下。
    public static func trackInfoHeight(showsArtwork: Bool, showsTitle: Bool, showsArtist: Bool, showsAlbum: Bool) -> CGFloat {
        var textHeight: CGFloat = 0
        var lineCount = 0
        if showsTitle { textHeight += trackInfoTitleLineHeight; lineCount += 1 }
        if showsArtist { textHeight += trackInfoArtistLineHeight; lineCount += 1 }
        if showsAlbum { textHeight += trackInfoAlbumLineHeight; lineCount += 1 }
        if lineCount > 1 { textHeight += CGFloat(lineCount - 1) * trackInfoLineSpacing }
        let artworkHeight: CGFloat = showsArtwork ? trackInfoArtworkSide : 0
        return max(artworkHeight, textHeight)
    }

    /// 展开区的**最大**高度,给定当前设置。窗口恒按这个尺寸开(卡片在里面自己变大变小),
    /// 设置页那条预览的容器也按它定高 —— 两处都不能跟着曲目内容变,否则窗口/整页会被
    /// 顶一下。
    ///
    /// 40 → 72 → 76(2026-08-19):展开区从「预览 + 进度条」加了一排完整三键(设计评审把
    /// 控制从右耳挪进展开卡),按 预览13 + 间距4 + 进度条槽6+3+时间行11 + 间距4 + 三键22 +
    /// 底边距10 累出来的;进度条布局槽后来钉成恒定 6pt(悬停变粗不再推邻居)多占了 3pt,
    /// 一并加上余量——默认参数下这个函数返回值仍是 76,逐字延续那笔账。
    ///
    /// 2026-09-01 之前这是一个写死常量,因为两个输入(`hasLyricPreview`/`hasScrubber`)
    /// 都是"每首歌都可能不一样、但不会主动触发重算窗口"的曲目级数据,只能按"两样都在"的
    /// 最坏情况钉死,否则换到内容更多的歌时卡片会被窗口边界硬裁。
    ///
    /// 现在多了两个**用户设置**维度,处理方式不同:
    ///   - `hasLyricPreviewPossible`(= `notchExpandedShowsNextLine` 这个开关):设置一变
    ///     会触发 `NotchLyricsWindowController` 重算几何(见该文件的订阅),不存在"改完
    ///     设置卡片却来不及长高"的风险,所以**不必**按最坏情况钉死——关掉之后窗口可以
    ///     真的省下 `lyricPreviewBlock` 这 17pt。`hasScrubber` 没有对应的开关(进度条纯
    ///     由曲目时长决定),所以仍然按"恒有"处理,不接受这里的参数。
    ///   - `hasControlsPossible`(2026-09-01,= `notchExpandedShowsControls` 这个开关):
    ///     同 `hasLyricPreviewPossible` 一个道理——设置驱动、设置一变就会重算,直接传
    ///     当前设置值即可,不用按"恒有"钉死。
    ///   - `trackInfoHeight`:同样是设置驱动、设置一变就会重算,直接把当前配置算出来的
    ///     值原样加进去即可,不需要"最坏情况"这层保护——这块内容本来就不随曲目变。
    public static func maxHeight(
        hasLyricPreviewPossible: Bool = true, hasControlsPossible: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        height(hasLyricPreview: hasLyricPreviewPossible, hasScrubber: true,
               hasControls: hasControlsPossible, trackInfoHeight: trackInfoHeight)
    }
}
