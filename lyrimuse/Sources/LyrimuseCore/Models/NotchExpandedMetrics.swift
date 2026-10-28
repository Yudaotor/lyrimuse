import CoreGraphics

/// 灵动岛 hover 展开区的高度算术。
///
/// 放在 LyrimuseCore 而不跟 `NotchMetrics` 的其它常量待在一起:那个类型在 App target 里(要用 SwiftUI),
/// 而 selftest 只依赖 LyrimuseCore,这几个数值要被断言钉住。`NotchMetrics` 只转发到这里,只有一份实现。
public enum NotchExpandedMetrics {
    /// 播放控制那一段:三键 22 + 底边距 10 + 3pt 余量。
    /// `alignment: .top` 下这一段不够高会直接把最下面那排三键裁掉。
    ///
    /// 由用户开关 `notchExpandedShowsControls` 决定有没有(`height` 的 `hasControls`),跟下一句预览 / 迷你进度条那两个
    /// 曲目级数据信号不是一类:设置一变控制器就重算几何,`maxHeight` 的 `hasControlsPossible` 直接传当前设置值。
    public static let controlsBlock: CGFloat = 35
    /// 下一句歌词预览:行高 13 + 间距 4。
    public static let lyricPreviewBlock: CGFloat = 17
    /// 迷你进度条:槽 6+3 + 时间行 11 + 间距 4。
    public static let scrubberBlock: CGFloat = 24

    /// 展开区**此刻**该有多高 —— 按里面真正会渲染的东西算。
    ///
    /// 下一句歌词预览(没歌词就没有)、迷你进度条(没时长就没有,见 NotchScrubber 的两个分支)、播放控制三样按段累加;
    /// 三样齐 = 35+17+24 = 76。
    ///
    /// `hasLyricPreview`/`hasScrubber` 两个入参刻意是**曲目级**信号(这首歌有没有歌词 /
    /// 有没有时长),不是"下一句此刻是不是空的"。用后者会让最后一句唱完时卡片突然矮 17pt、
    /// 下一首又长回来,肉眼是抽动;曲目级信号在一首歌里恒定。代价是"有歌词但此刻恰好没有
    /// 下一句"时那 17pt 是空的 —— 稳定压倒紧凑,这是有意的取舍。
    ///
    /// `hasControls`性质不一样:它是**用户设置**(播放控制键要不要显示),
    /// 不是曲目级数据信号——跟 `trackInfoHeight` 同一类,见 `controlsBlock` 声明处的注释。
    ///
    /// `trackInfoHeight`(「曲目信息头部」——展开区里可选的歌名/歌手/专辑
    /// 那一块)是第三个维度,但**性质跟前两个不一样**:前两个是曲目级数据信号,这个是
    /// **用户设置**的派生值(见 `trackInfoHeight(showsArtwork:showsTitle:showsArtist:showsAlbum:)`)。
    /// 调用方(`NotchExpandedMetrics.trackInfoHeight`)按当前设置现算好传进来,这个函数不
    /// 关心它是怎么来的,只管加不加、加多少 —— 跟 `hasLyricPreview`/`hasScrubber` 一样是
    /// "只加一次、且这次的间距已经包含在值里"的一整块,0 表示这块完全不占地方(不渲染)。
    ///
    /// 头部占用 `trackInfoHeight + trackInfoTopSpacing + trackInfoSpacing`——**两份**
    /// 间距,不是一份,而且 **两份不再同值**:
    /// 一份贴在上边(`trackInfoTopSpacing`,离 topRow;现象是"标题首行贴到上面
    /// 边了",头部紧挨在 topRow 下面、原来零间距),一份贴在下边(`trackInfoSpacing`,
    /// 离下面歌词行,加这块之前就有)。渲染那侧(`NotchLyricsView.trackInfoHeader`)只在
    /// **内容顶部**加一次 `.padding(.top: trackInfoTopSpacing)`——`.frame(alignment: .top)`
    /// 已经把内容锚在分配到的这块高度的顶部,上下各留一份间距的效果因此不需要在视图那侧
    /// 显式凑两次 padding,只要这里的高度算术把两份都算进去、视图那侧把 topRow 与内容之间
    /// 那一份实现出来即可。
    public static func height(
        hasLyricPreview: Bool, hasScrubber: Bool, hasControls: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        var h: CGFloat = hasControls ? controlsBlock : 0
        if hasLyricPreview { h += lyricPreviewBlock }
        if hasScrubber { h += scrubberBlock }
        if trackInfoHeight > 0 { h += trackInfoHeight + trackInfoTopSpacing + trackInfoSpacing }
        return h
    }

    // MARK: - 曲目信息头部

    /// 头部跟下面歌词之间的间距。不能小于歌词行距的两倍(`lyricListLineSpacing`):比歌词行与行之间的空隙还窄时,
    /// 灰色的专辑名看着就是歌词的第一行(05 章决策 113)。
    public static let trackInfoSpacing: CGFloat = 14

    /// 头部跟**上面** topRow 之间的间距(封面 + 歌名 / 歌手 / 专辑那一整块离刘海的距离)。
    public static let trackInfoTopSpacing: CGFloat = 12
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
    /// 头部右侧那排「快捷操作」按钮(搜索歌词、显示歌词、设置、关闭)的高度。22 = 展开区播放控制三键的
    /// 命中尺寸(`NotchLyricsView.expandedContent` 里 `controlButton(hitSize: 22)`),同一张卡上
    /// 的图标键用同一档。它参与头部高度的 `max`:四个曲目信息项全关、只开快捷操作时,头部退化成
    /// 一条 22pt 高、靠右的按钮行。
    public static let trackInfoActionsHeight: CGFloat = 22

    /// 曲目信息头部要占多高 —— 四个开关(封面/歌名/歌手/专辑)现算,不查表。
    ///
    /// 头部封面是**自己**的一枚,跟歌词行末尾那枚(`notchLyricRowShowsArtwork`,只影响歌词行内部排列、不进这里的算术)
    /// 是两个独立开关。它固定贴文字块左边、没有位置可选,所以高度只要「封面和文字块谁更高」的 `max`。
    ///
    /// 每一项的高度只看"这个开关开没开",不看"这首歌这个字段是不是空字符串/有没有
    /// 封面数据"——跟 `height(hasLyricPreview:hasScrubber:)` 那条"曲目级信号,不是此刻
    /// 有没有内容"的纪律同源:开关是稳定的会话级配置,按它留出的高度不该因为某一首歌
    /// 恰好没有专辑名/封面就抽一下。
    ///
    /// `showsActions`:头部右侧那排快捷操作按钮。跟封面一样是**并排**的第三块,
    /// 取 `max` 不取和 —— 三行文字(14+12+11+2 = 39)本来就比它(22)高,常见配置下开关它不改高度;
    /// 只有文字项全关(或只开一两行矮的)时它才是决定高度的那一块。
    public static func trackInfoHeight(showsArtwork: Bool, showsTitle: Bool, showsArtist: Bool, showsAlbum: Bool,
                                       showsActions: Bool = false) -> CGFloat {
        var textHeight: CGFloat = 0
        var lineCount = 0
        if showsTitle { textHeight += trackInfoTitleLineHeight; lineCount += 1 }
        if showsArtist { textHeight += trackInfoArtistLineHeight; lineCount += 1 }
        if showsAlbum { textHeight += trackInfoAlbumLineHeight; lineCount += 1 }
        if lineCount > 1 { textHeight += CGFloat(lineCount - 1) * trackInfoLineSpacing }
        let artworkHeight: CGFloat = showsArtwork ? trackInfoArtworkSide : 0
        let actionsHeight: CGFloat = showsActions ? trackInfoActionsHeight : 0
        return max(artworkHeight, textHeight, actionsHeight)
    }

    // MARK: - 多行歌词

    /// 「多行歌词」可选的行数(`AppSettings.notchExpandedLyricListLines`)。
    public static let lyricListLineCounts = [3, 5, 7]
    public static let defaultLyricListLineCount = 5
    /// 列表的字号固定,不跟「字号」走:那一项只调主行,展开区「下一句」预览也是固定的。译文 / 读音同副行 11pt。
    public static let lyricListFontSize: CGFloat = 13
    /// 行与行之间的距离。
    public static let lyricListLineSpacing: CGFloat = 7
    /// 正文一行(13pt)、译文 / 读音一行(11pt)的行高,系统字体实测 16 / 13。
    static let lyricListMainLineHeight: CGFloat = 16
    static let lyricListSecondaryLineHeight: CGFloat = 13
    /// 正文与译文 / 读音之间:块间距 6 + 译文前多留 0.12 个正文字号(同歌词窗口图层列表的行排法),往上取整。
    static let lyricListSecondaryGap: CGFloat = 8

    /// 每一行占的高度(含行距)。带译文 / 读音时每行多一行小字。
    public static func lyricListPitch(secondaryRow: Bool) -> CGFloat {
        lyricListMainLineHeight + lyricListLineSpacing
            + (secondaryRow ? lyricListSecondaryGap + lyricListSecondaryLineHeight : 0)
    }

    /// 存下来的行数不在可选的几档里时,取最近的一档(一样近取小的)。
    public static func clampedLyricListLineCount(_ count: Int) -> Int {
        lyricListLineCounts.min { abs($0 - count) < abs($1 - count) } ?? defaultLyricListLineCount
    }

    /// 列表那一格的高度:行数 × 每行高度。长句折成两行时这一格放得下的句数会少一句,高度不跟着变。
    public static func lyricListHeight(lineCount: Int, secondaryRow: Bool) -> CGFloat {
        CGFloat(clampedLyricListLineCount(lineCount)) * lyricListPitch(secondaryRow: secondaryRow)
    }

    /// 当前句滚到视口从上往下的哪个比例(传给图层列表,含义同它的 `activeAnchor`:行内这个比例的点对到视口这个比例处)。
    /// 让当前句上面正好放下 (行数 − 1) / 2 整行(3 行时上一句、当前句、下一句各占一行),不按歌词窗口的 37%:
    /// 视口只有几行高时 37% 会把上一句顶出去半截(05 章决策 112)。
    public static func lyricListActiveAnchor(lineCount: Int, secondaryRow: Bool) -> CGFloat {
        let count = clampedLyricListLineCount(lineCount)
        let pitch = lyricListPitch(secondaryRow: secondaryRow)
        let rowHeight = pitch - lyricListLineSpacing
        let viewport = CGFloat(count) * pitch
        return CGFloat((count - 1) / 2) * pitch / (viewport - rowHeight)
    }

    /// 列表上下边渐隐的宽度:行距的一半,只淡掉行与行之间那道缝,不吃进整行的字。
    public static let lyricListEdgeFade: CGFloat = lyricListLineSpacing / 2

    /// 多行歌词在这一格里的摆法(比例都按视口高度):当前句锚位,上下边渐隐的四个停靠点。
    public struct LyricListPlacement: Equatable, Sendable {
        public let activeAnchor: CGFloat
        public let topClear: CGFloat
        public let topOpaque: CGFloat
        public let bottomOpaque: CGFloat
        public let bottomClear: CGFloat
    }

    /// 这一格放得下几整行就排几行,当前句上面放 (行数 − 1) / 2 整行,渐隐只淡行距那道缝(`lyricListActiveAnchor` /
    /// `lyricListEdgeFade`)。格高按「带小字」定、这首歌却一句小字都没有时行距变小、放不满整数行:多出来的那截平分到上下、
    /// 整段透明,边上不露半截行。格高正好是整数行时跟 `lyricListActiveAnchor` 一致。
    public static func lyricListPlacement(height: CGFloat, secondaryRow: Bool) -> LyricListPlacement {
        let pitch = lyricListPitch(secondaryRow: secondaryRow)
        let rowHeight = pitch - lyricListLineSpacing
        guard height >= pitch else {
            return LyricListPlacement(activeAnchor: 0, topClear: 0, topOpaque: 0, bottomOpaque: 1, bottomClear: 1)
        }
        let count = Int(height / pitch + 1e-6)
        let margin = max(0, (height - CGFloat(count) * pitch) / 2)
        let currentTop = margin + CGFloat((count - 1) / 2) * pitch
        let opaque = min(0.5, (margin + lyricListEdgeFade) / height)
        return LyricListPlacement(activeAnchor: currentTop / (height - rowHeight),
                                  topClear: margin / height, topOpaque: opaque,
                                  bottomOpaque: 1 - opaque, bottomClear: 1 - margin / height)
    }

    // MARK: - 没有曲目时的空闲面板

    /// 空闲面板离卡片**底边**的间距。它是展开态最下面(也是唯一)的一块,跟播放控制三键那块的
    /// 10pt 底边距(`controlsBlock` 里那份)取同一档。
    public static let idlePanelBottomSpacing: CGFloat = 10

    /// 没有曲目时 hover 展开只长出这一块:两行字(「没有在播放」+ 一句提示,按头部的
    /// 歌名 / 歌手两档行高)+ 右侧一排 22pt 快捷键,上面留 `trackInfoTopSpacing`、下面留
    /// `idlePanelBottomSpacing`。复用头部的行高账,是为了让这一块跟有曲目时的头部看起来是
    /// 同一个位置上的同一种东西,而不是另起一套尺寸。
    ///
    /// 改这个值之前先看 selftest 那条「空闲面板放得进窗口」:窗口恒按 `顶行 + 歌词行 44 + maxHeight`
    /// 开,空闲面板必须 ≤ 歌词行 + 最省配置下的 maxHeight(只剩进度条那 24pt),否则会被窗口硬裁。
    public static var idlePanelHeight: CGFloat {
        trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: false, showsActions: true)
            + trackInfoTopSpacing + idlePanelBottomSpacing
    }

    /// 展开区的**最大**高度,给定当前设置。窗口恒按这个尺寸开(卡片在里面自己变大变小),
    /// 设置页那条预览的容器也按它定高 —— 两处都不能跟着曲目内容变,否则窗口/整页会被
    /// 顶一下。
    ///
    /// 默认参数下返回 76(预览 13 + 间距 4 + 进度条槽 6+3 + 时间行 11 + 间距 4 + 三键 22 + 底边距 10 + 余量 3)。
    ///
    /// 曲目级数据(`hasScrubber`:有没有时长)每首歌都可能不一样、却不会主动触发重算窗口,只能按"有"钉死,否则换到内容更多的歌时
    /// 卡片会被窗口边界硬裁。用户设置维度一变控制器就重算几何,直接传当前值:
    ///   - `hasLyricPreviewPossible`(= `notchExpandedShowsNextLine` 开关且没被副行顶掉):关掉之后窗口省下
    ///     `lyricPreviewBlock` 这 17pt。
    ///   - `hasControlsPossible`(= `notchExpandedShowsControls` 这个开关):
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
