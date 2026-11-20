import CoreGraphics

/// 灵动岛卡片此刻的形态:哪几块画不画、卡片多宽多高、收没收起。
///
/// 真窗口(`NotchLyricsWindowController`)和设置页编辑台(`NotchPreviewChrome`)都经 App 侧 `NotchChromeSource` 的协议扩展
/// 把自己的状态填进来、读这里的结果。卡片高度的预留和实际渲染必须读同一个判据:两处各写一份必然漂,表现是行不见了高度还留着,
/// 或者反过来把行裁掉半截。放在 Core 是为了让 selftest 用数值断言钉住这些公式,不钉源码原文。
public struct NotchCardLayout: Equatable, Sendable {
    /// 卡片几何里的固定尺寸(App 侧 `NotchMetrics` 那几项)。
    public struct Metrics: Equatable, Sendable {
        /// 卡片左右两侧的内边距(单侧)。
        public var cardPadding: CGFloat
        /// 展开态那一列内容(曲目信息头部、歌词、进度条、控制键)的左右内边距。
        public var contentInset: CGFloat
        /// 收起态一只耳朵的宽度。
        public var collapsedEarWidth: CGFloat
        /// 报喜面板的高度:报喜时卡片 = 顶行 + 这一块。
        public var milestonePanelHeight: CGFloat
        /// 关着歌词行时,掉出来的歌名 / 瞬态横幅让卡片多长的那一截。
        public var trackDropHeight: CGFloat
        /// 关着歌词行时,底边进度线让卡片多长的那一截。
        public var progressLineStrip: CGFloat

        public init(cardPadding: CGFloat, contentInset: CGFloat, collapsedEarWidth: CGFloat,
                    milestonePanelHeight: CGFloat, trackDropHeight: CGFloat, progressLineStrip: CGFloat) {
            self.cardPadding = cardPadding
            self.contentInset = contentInset
            self.collapsedEarWidth = collapsedEarWidth
            self.milestonePanelHeight = milestonePanelHeight
            self.trackDropHeight = trackDropHeight
            self.progressLineStrip = progressLineStrip
        }
    }

    public var metrics: Metrics
    /// 收起态(`isCollapsed(...)` 的结果):卡片只留顶行那一条,宽度收到两只耳朵。
    public var isCollapsed: Bool
    public var isExpanded: Bool
    /// 物理刘海的宽度,顶行中间给它让出空当。无刘海屏是 0。
    public var notchWidth: CGFloat
    /// 顶行高度(刘海高度,无刘海屏是菜单栏高度)。
    public var contentTopInset: CGFloat
    /// 稳态 / 展开态卡片的真实宽(已过耳朵下限与「展开 ≥ 稳态」)。
    public var steadyCardWidth: CGFloat
    public var expandedCardWidth: CGFloat
    /// 歌词行的实际高度(设定值夹到装得下当前字号和副行为止)。
    public var lyricRowHeight: CGFloat
    /// 展开时多行歌词那一格的高度,关着「多行歌词」时为 0。
    public var expandedLyricListHeight: CGFloat
    /// 此刻有没有一首曲目(有歌名 / 歌手,或者正在放广告)。不看在不在播:暂停中仍然有曲目。
    public var hasTrack: Bool
    public var isAdBreak: Bool
    /// 正在报收听里程碑。
    public var hasMilestone: Bool
    /// 换歌时有一条歌名正掉出来。
    public var hasTrackDrop: Bool
    public var transientBannerActive: Bool
    /// 「进度线」开关。
    public var showsProgressLine: Bool
    /// 进度线画在底边还是沿耳朵。
    public var progressLineStyle: NotchProgressLineStyle
    /// 「收起时显示歌词」开关(真窗口上还叠了「纯音乐 / 无歌词时收起歌词行」)。
    public var showsLyrics: Bool
    /// 这首歌有没有下一句可预览(曲目级信号,一首歌里不变,不是「此刻有没有下一句」)。
    public var trackHasLyricPreview: Bool
    /// 这首歌有没有时长(展开区那条进度条画不画)。
    public var trackHasScrubber: Bool
    /// 「展开时预览下一句」开关(已经扣掉被副行「下一句」顶掉的情况)。
    public var expandedShowsNextLine: Bool
    public var expandedShowsControls: Bool
    public var trackInfoShowsArtwork: Bool
    public var trackInfoShowsTitle: Bool
    public var trackInfoShowsArtist: Bool
    public var trackInfoShowsAlbum: Bool
    public var expandedShowsQuickActions: Bool
    /// 快捷操作用了几行(`NotchQuickSlots.usedRowCount`),决定头部高度。
    public var expandedQuickActionRows: Int
    /// 没有曲目时展开出来那块空闲面板的高度(`NotchExpandedMetrics.idlePanelHeight(showsLastTrack:showsQuote:)` 三档之一)。
    public var idlePanelHeight: CGFloat
    /// 顶行歌词那段的宽度(`NotchTopRowLyrics.Fit.lyricWidth`);0 = 这块屏、这首歌不在顶行画歌词。
    public var topRowLyricsWidth: CGFloat
    /// 稳态卡片中心比刘海中心往右偏多少(`NotchEarSpan.offset`);0 = 两耳等宽,卡片以刘海为中心。见 05 章决策 160。
    public var steadyOffset: CGFloat

    public init(metrics: Metrics, isCollapsed: Bool, isExpanded: Bool, notchWidth: CGFloat, contentTopInset: CGFloat,
                steadyCardWidth: CGFloat, expandedCardWidth: CGFloat, lyricRowHeight: CGFloat,
                expandedLyricListHeight: CGFloat, hasTrack: Bool, isAdBreak: Bool, hasMilestone: Bool,
                hasTrackDrop: Bool, transientBannerActive: Bool, showsProgressLine: Bool,
                progressLineStyle: NotchProgressLineStyle, showsLyrics: Bool, trackHasLyricPreview: Bool, trackHasScrubber: Bool, expandedShowsNextLine: Bool,
                expandedShowsControls: Bool, trackInfoShowsArtwork: Bool, trackInfoShowsTitle: Bool,
                trackInfoShowsArtist: Bool, trackInfoShowsAlbum: Bool, expandedShowsQuickActions: Bool,
                expandedQuickActionRows: Int = 1,
                idlePanelHeight: CGFloat = NotchExpandedMetrics.idlePanelHeight(showsLastTrack: false, showsQuote: false),
                topRowLyricsWidth: CGFloat = 0, steadyOffset: CGFloat = 0) {
        self.metrics = metrics
        self.isCollapsed = isCollapsed
        self.isExpanded = isExpanded
        self.notchWidth = notchWidth
        self.contentTopInset = contentTopInset
        self.steadyCardWidth = steadyCardWidth
        self.expandedCardWidth = expandedCardWidth
        self.lyricRowHeight = lyricRowHeight
        self.expandedLyricListHeight = expandedLyricListHeight
        self.hasTrack = hasTrack
        self.isAdBreak = isAdBreak
        self.hasMilestone = hasMilestone
        self.hasTrackDrop = hasTrackDrop
        self.transientBannerActive = transientBannerActive
        self.showsProgressLine = showsProgressLine
        self.progressLineStyle = progressLineStyle
        self.showsLyrics = showsLyrics
        self.trackHasLyricPreview = trackHasLyricPreview
        self.trackHasScrubber = trackHasScrubber
        self.expandedShowsNextLine = expandedShowsNextLine
        self.expandedShowsControls = expandedShowsControls
        self.trackInfoShowsArtwork = trackInfoShowsArtwork
        self.trackInfoShowsTitle = trackInfoShowsTitle
        self.trackInfoShowsArtist = trackInfoShowsArtist
        self.trackInfoShowsAlbum = trackInfoShowsAlbum
        self.expandedShowsQuickActions = expandedShowsQuickActions
        self.expandedQuickActionRows = expandedQuickActionRows
        self.idlePanelHeight = idlePanelHeight
        self.topRowLyricsWidth = topRowLyricsWidth
        self.steadyOffset = steadyOffset
    }

    /// 收起态判据。`collapsesWhenPaused` 关掉暂停时就不收;`hideWhenNotPlaying` 开着时暂停直接缩进刘海、不经过收起态,
    /// 例外是从收起的样子缩进去的那一次(`vanishesFromCollapsed`,暂停着、已经收起时才打开「暂停时隐藏」)照旧算收起;
    /// 广告插播看 `collapsesDuringAds`。展开时一律不算收起:收起态 hover 照样展开出完整内容。
    /// 真窗口要写成计算属性现算:hover 改展开态那条路不重算几何,存成存储属性的话暂停时 hover 不会展开。
    public static func isCollapsed(collapsesWhenPaused: Bool, isPlaying: Bool, hideWhenNotPlaying: Bool,
                                   vanishesFromCollapsed: Bool, collapsesDuringAds: Bool, isAdBreak: Bool,
                                   isExpanded: Bool) -> Bool {
        ((collapsesWhenPaused && !isPlaying && (!hideWhenNotPlaying || vanishesFromCollapsed))
            || (collapsesDuringAds && isAdBreak)) && !isExpanded
    }

    /// 「正在播放」那一行歌词行画不画。关着「显示歌词」时稳态不画(退化成贴着刘海的状态栏),但展开后照常画:
    /// 只放开「下一句预览」不够,这一行也被同一个开关挡着的话,展开后有下一句、却看不到正在播放的当前行。
    public var showsLyricRow: Bool { hasTrack && (showsLyrics || isExpanded) }

    /// 顶行两只耳朵之间此刻画不画歌词:只在稳态(没收起、没展开、没报喜)、有曲目时画。展开时歌词在下面那份歌词行里,
    /// 收起时跟歌词行一样不画。
    public var showsTopRowLyrics: Bool {
        topRowLyricsWidth > 0 && hasTrack && !isCollapsed && !isExpanded && !hasMilestone
    }

    /// 耳朵里的「当前句」「下一句」此刻画不画:只在稳态(没收起、没展开)、有曲目、不在放广告时画。展开时下面的歌词行
    /// 和下一句预览已经有这两句;收起态耳朵本来就不按配置画。见 05 章决策 159。
    public var showsEarLyrics: Bool {
        hasTrack && !isCollapsed && !isExpanded && !isAdBreak
    }

    /// 瞬态横幅画在卡片为它多长的那一截里:关着歌词行、没展开、没收起、没报喜时(开着歌词行或展开时横幅盖在歌词行上)。
    public var showsBannerStrip: Bool {
        transientBannerActive && hasTrack && !showsLyrics && !isExpanded && !isCollapsed && !hasMilestone
    }

    /// 底边那根进度线画不画:开着「进度线」、选的是底边、有曲目,没展开(展开区有自己那条进度条)、没收起、没报喜。
    public var showsBottomProgressLine: Bool {
        showsProgressLine && progressLineStyle == .bottom && hasTrack && !isExpanded && !isCollapsed && !hasMilestone
    }

    /// 沿耳朵那根进度线画不画:条件同底边那根,另外关着歌词行时掉歌名 / 横幅那一截伸出来的时候让开
    /// (卡片临时多长一截,底边离开刘海,线的终点会从刘海边挪到正中、整根跟着变长)。
    public var showsEarProgressLine: Bool {
        showsProgressLine && progressLineStyle == .ears && hasTrack && !isExpanded && !isCollapsed && !hasMilestone
            && (showsLyrics || !(hasTrackDrop || transientBannerActive))
    }

    /// 展开区那行「下一句预览」画不画:这首有下一句、开关开着、没开「多行歌词」(列表里本来就有下一句)。
    /// 不看「显示歌词」:展开是主动选的动作,不该被「平时不想被歌词挡视线」连累。
    public var showsExpandedLyricPreview: Bool {
        trackHasLyricPreview && expandedShowsNextLine && expandedLyricListHeight == 0
    }

    /// 展开时歌词那一格换成多行列表:开着「多行歌词」、有曲目、这首有歌词、不在放广告。「有歌词」是曲目级信号,
    /// 一首歌里不变,卡片不会唱着唱着跳一下。
    public var showsExpandedLyricList: Bool {
        expandedLyricListHeight > 0 && hasTrack && trackHasLyricPreview && !isAdBreak
    }

    /// 展开头部的四项曲目字段(封面 / 歌名 / 歌手 / 专辑)此刻能不能画:广告期间一律不画,头部只剩快捷操作。
    public var trackInfoShowsTrackFields: Bool { !isAdBreak }

    /// 展开头部画不画:有曲目,且五项(四项曲目字段 + 快捷操作)里至少一项此刻画得出来。
    public var showsExpandedTrackInfo: Bool {
        hasTrack
            && ((trackInfoShowsTrackFields
                 && (trackInfoShowsArtwork || trackInfoShowsTitle || trackInfoShowsArtist || trackInfoShowsAlbum))
                || expandedShowsQuickActions)
    }

    /// 展开头部按当前设置的内容高度,0 = 不画。
    public var expandedTrackInfoHeight: CGFloat {
        guard showsExpandedTrackInfo else { return 0 }
        let fields = trackInfoShowsTrackFields
        return NotchExpandedMetrics.trackInfoHeight(
            showsArtwork: fields && trackInfoShowsArtwork, showsTitle: fields && trackInfoShowsTitle,
            showsArtist: fields && trackInfoShowsArtist, showsAlbum: fields && trackInfoShowsAlbum,
            showsActions: expandedShowsQuickActions, actionRows: expandedQuickActionRows)
    }

    /// 展开头部的总高度:内容加上下各一份间距(头部画在歌词行之上,它自己的 frame 要含离下面歌词行的那一截);不画时 0。
    public var expandedTrackInfoHeaderHeight: CGFloat {
        let height = expandedTrackInfoHeight
        return height > 0 ? height + NotchExpandedMetrics.trackInfoTopSpacing + NotchExpandedMetrics.trackInfoSpacing : 0
    }

    /// 展开区按当前设置**最多**占多高(这首有没有下一句、有没有时长一律按「有」算)。真窗口常驻最大形态,窗口高度按它留;
    /// 编辑台舞台卡片那一格也按它留。不看广告态:广告只是此刻少画四项。
    public var expandedExtraHeightMax: CGFloat {
        NotchExpandedMetrics.maxHeight(
            hasLyricPreviewPossible: expandedShowsNextLine && expandedLyricListHeight == 0,
            hasControlsPossible: expandedShowsControls,
            trackInfoHeight: NotchExpandedMetrics.trackInfoHeight(
                showsArtwork: trackInfoShowsArtwork, showsTitle: trackInfoShowsTitle,
                showsArtist: trackInfoShowsArtist, showsAlbum: trackInfoShowsAlbum,
                showsActions: expandedShowsQuickActions, actionRows: expandedQuickActionRows))
    }

    /// 顶行两侧此刻的内边距,规则见 `NotchWidthBounds.topRowPadding`。
    public var topRowPadding: CGFloat {
        NotchWidthBounds.topRowPadding(expanded: isExpanded, steadyWidth: steadyCardWidth, expandedWidth: expandedCardWidth,
                                       cardPadding: metrics.cardPadding, contentInset: metrics.contentInset)
    }

    /// 一只耳朵的宽度(两只恒等宽):卡片宽扣掉刘海空当(画顶行歌词时再扣歌词那段)和两侧内边距后平分。真窗口按此刻(动画中)的
    /// 卡片宽算,编辑台热区按目标卡片宽算。内边距不能漏扣:漏了顶行比卡片宽 2×padding,背景形状超出窗口,底部圆角被窗口裁成直角。
    public func earWidth(cardWidth: CGFloat) -> CGFloat {
        max(0, (cardWidth - topRowGap - topRowPadding * 2) / 2)
    }

    /// 左右两只耳朵各自的宽度。两耳等宽(`offset` 为 0)或画着顶行歌词时两只相等,同 `earWidth(cardWidth:)`;否则刘海空当
    /// 跟着卡片偏移挪,窄的那一侧少、宽的那一侧多。`offset` 是此刻(动画中)卡片中心比刘海中心往右偏多少。
    public func earWidths(cardWidth: CGFloat, offset: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let base = earWidth(cardWidth: cardWidth)
        guard offset != 0, !showsTopRowLyrics else { return (base, base) }
        let half = (cardWidth - topRowGap - topRowPadding * 2) / 2
        return (max(0, half - offset), max(0, half + offset))
    }

    /// 稳态卡片两侧各伸出刘海多少。
    public var steadySpan: NotchEarSpan {
        NotchEarSpan.of(cardWidth: steadyCardWidth, offset: steadyOffset, notchWidth: notchWidth)
    }

    /// 两耳不等宽时收起态两侧各伸出多少(`NotchEarWidths.collapsed`)。
    public var collapsedSpan: NotchEarSpan {
        NotchEarWidths.collapsed(steadySpan, notchWidth: notchWidth, collapsedEarWidth: metrics.collapsedEarWidth,
                                 cardPadding: metrics.cardPadding)
    }

    /// 卡片此刻中心比刘海中心往右偏多少:展开态 0(以刘海为中心),稳态 `steadyOffset`,收起态按两侧各自收起后算。
    /// 卡片宽度和这个偏移走同一条弹簧。
    public var cardOffset: CGFloat {
        if isCollapsed { return steadyOffset == 0 ? 0 : collapsedSpan.offset }
        return isExpanded ? 0 : steadyOffset
    }

    /// 顶行两只耳朵中间空出来的宽度:刘海,加上此刻画着的顶行歌词那段。
    public var topRowGap: CGFloat {
        notchWidth + (showsTopRowLyrics ? topRowLyricsWidth : 0)
    }

    /// 没有刘海的屏(外接屏)收起时,两只耳朵中间按这么宽的一块刘海留空,跟 MacBook 内建屏(刘海约 180pt)收起时一样大。
    /// 别按真实刘海宽 0 算:那样只剩两只耳朵、缩成 88pt 一小块。见 05 章决策 128。
    public static let collapsedGapWithoutNotch: CGFloat = 180

    /// 卡片当前宽度:收起态收到刘海加两只耳朵(不比稳态宽),展开态取展开宽。
    public var cardWidth: CGFloat {
        if isCollapsed {
            if steadyOffset != 0 { return collapsedSpan.cardWidth(notchWidth: notchWidth) }
            let gap = notchWidth > 0 ? notchWidth : Self.collapsedGapWithoutNotch
            return min(steadyCardWidth, gap + 2 * metrics.collapsedEarWidth + 2 * metrics.cardPadding)
        }
        return isExpanded ? expandedCardWidth : steadyCardWidth
    }

    /// 卡片底边伸出顶行(刘海 / 菜单栏)超过这么多,没展开时也画发丝描边和浅投影:挂着歌词行(≥ 26)、掉歌名 / 横幅、报喜都够,
    /// 只多 4pt 的底边进度线那一截不够。见 05 章决策 155。
    public static let cardEdgeMinOverhang: CGFloat = 12

    /// 发丝描边和浅投影(App 侧 `NotchCardEdge`)画不画:展开时总画;没展开时看卡片底边伸出顶行多少,收起态和只剩顶行的状态栏不画。
    /// 按目标高度判,不按动画中的高度:形态切换时透明度单独淡入淡出,展开 / 收回之间两头都画就一直不灭。
    public var showsCardEdge: Bool {
        isExpanded || cardHeight - contentTopInset > Self.cardEdgeMinOverhang
    }

    /// 卡片当前高度:收起只留顶行,报喜是顶行 + 报喜面板,其余按展开与否走 `cardHeight(expanded:)`。
    public var cardHeight: CGFloat {
        if isCollapsed { return contentTopInset }
        if hasMilestone { return contentTopInset + metrics.milestonePanelHeight }
        return cardHeight(expanded: isExpanded)
    }

    /// 没展开 / 展开某一种形态下的卡片高度(不看收起态)。
    ///
    /// 没有曲目时展开只长出「空闲面板」那一块:那时歌词行和展开区的内容整个被 `hasTrack` 挡掉,照通式留「三键 + 进度条」
    /// 就是一大块空黑。有曲目时 = 顶行 + 歌词那一格(稳态按「显示歌词」、展开总留;展开且开着多行歌词时换成列表高度;
    /// 关着歌词行时只给掉出来的歌名 / 横幅留一截)+ 关着歌词行时底边进度线那一截 + 展开区。
    public func cardHeight(expanded: Bool) -> CGFloat {
        if !hasTrack {
            return contentTopInset + (expanded ? idlePanelHeight : 0)
        }
        let lyricCell: CGFloat
        if showsLyrics || expanded {
            lyricCell = expanded && showsExpandedLyricList ? expandedLyricListHeight : lyricRowHeight
        } else {
            lyricCell = hasTrackDrop || transientBannerActive ? metrics.trackDropHeight : 0
        }
        let progressStrip = !expanded && !showsLyrics && showsProgressLine && progressLineStyle == .bottom
            ? metrics.progressLineStrip : 0
        let expandedArea = expanded
            ? NotchExpandedMetrics.height(hasLyricPreview: showsExpandedLyricPreview, hasScrubber: trackHasScrubber,
                                          hasControls: expandedShowsControls, trackInfoHeight: expandedTrackInfoHeight)
            : 0
        return contentTopInset + lyricCell + progressStrip + expandedArea
    }
}
