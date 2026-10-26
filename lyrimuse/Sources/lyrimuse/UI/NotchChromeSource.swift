import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

/// 灵动岛卡片的固定尺寸。
///
/// 放在泛型视图**外面**有两个原因:泛型类型不能有 static stored property(编译器直接
/// 拒绝);而且预览那边(SectionPreviewBars)要用同样的数值算容器高度,单独一个命名空间
/// 比从视图里翻出来更直白。
enum NotchMetrics {
    // 歌词行的高度不在这里:它是用户设置合成出来的(`NotchChromeSource.lyricRowHeight`),别再加一个固定常量 ——
    // 拿它去排版的地方会在用户调过「行高」之后跟卡片对不上。
    /// 副行关着时主行往上提的量。行框竖直居中时字的上下留白差不到 1px,可整行阴影朝下
    /// (下移 1、半径 2),看上去下面更窄;提 1pt 让字连同阴影落在歌词行正中。见 05 章决策 73。
    static let singleLineOpticalLift: CGFloat = 1
    /// 收听里程碑报喜面板(`NotchMilestonePanel`)的高度:报喜时卡片 = 顶行 + 这一块。窗口高度也按它兜底。
    static let milestonePanelHeight: CGFloat = 76
    /// 报喜碎屑从卡片下沿往下落的距离;窗口在报喜卡片下面至少留出 `milestoneConfettiReach`(最远落点 + 最大一片的边长)。
    static let milestoneConfettiDrop: ClosedRange<CGFloat> = 30...85
    static var milestoneConfettiReach: CGFloat { milestoneConfettiDrop.upperBound + 6 }
    /// 换歌翻牌:关着歌词行时,卡片为掉出来的那条歌名多长的高度(`NotchTrackDropStrip`)。
    static let trackDropHeight: CGFloat = 26
    /// 进度线:关着歌词行时卡片为它多长的高度(线在这一截的底部,见 `NotchProgressLine`)。
    static let progressLineStrip: CGFloat = 4

    // 收起态(没在播放)单侧耳宽:左耳只放音浪(约 14pt 宽)、右耳只放一枚小封面
    // (iPhone 灵动岛式极简形态,歌名/播放键都收进 hover 展开卡),
    // 34 = 内容 + 两侧呼吸空间。用在 NotchWindowRoot.cardWidth 的收起分支。
    static let collapsedEarWidth: CGFloat = 34
    // 以下同样是被泛型限制赶出来的固定尺寸(理由见类型注释)。
    // minWordDurationMs/wordEdgeSoftenBand 已随 wordGradient 收编进 WordKaraokeGradient
    // ——别在这里再留一份"看着在生效"的死常量,将来改 KaraokeFill 会静默失真。
    static let artworkLyricSpacing: CGFloat = 10
    /// 歌词行右端渐隐带的宽度。
    ///
    /// 跟 artworkLyricSpacing 同为 10pt 不是巧合:渐隐带的作用就是把"硬切口紧贴封面"
    /// 这 10pt 间隙里的突变摊开成一段过渡。13pt 半粗体下约合 1.5 个拉丁字符,再宽会开始
    /// 吃掉能读的内容。完整判据(为什么只在停在开头时给)见 MarqueeMath.trailingFadeWidth。
    static let lyricEdgeFadeWidth: CGFloat = 10
    static let artworkCornerRadius: CGFloat = 5
    /// 两只耳朵朝刘海那一侧的内缩。
    ///
    /// 顶行的排布是「左耳 + 刘海宽的空当 + 右耳」严丝合缝地铺满,于是右耳的左边界正好压在物理刘海的右沿上:装不下的歌手名
    /// (跑马灯,从左起)第一个字就贴着刘海黑边;左耳同理,长歌名会一直顶到刘海左沿。这 6pt 只吃进耳朵内部,不改耳宽、不动外缘的
    /// 音浪/卡片边距,代价是跑马灯可用宽度少 6pt(更容易触发滚动,而滚动本来就是长名字的正解)。
    static let earNotchInset: CGFloat = 6
    /// 卡片左右两侧的内边距(`topRow` 末尾那句 `.padding(.horizontal:)`)。
    ///
    /// 这是单侧值。三处按它算:那两句 padding、耳宽公式 `(卡片宽 − 刘海宽 − 2×它) / 2`、以及宽度下限
    /// `NotchLyricsWindowController.contentWidth`。下限要跟着耳朵配置现算,各写一份字面量必然漂。
    static let cardHorizontalPadding: CGFloat = 10
    /// 展开态那一列内容(曲目信息头部、歌词行 / 多行歌词、进度条、控制键)的左右内边距。展开态顶行也收到这里,两只耳朵的外沿跟它们
    /// 对齐(`NotchChromeSource.topRowPadding`)。
    static let expandedContentInset: CGFloat = 16
    /// 交给 Core `NotchCardLayout` 算卡片宽高的那几项固定尺寸。
    static let cardLayout = NotchCardLayout.Metrics(
        cardPadding: cardHorizontalPadding, contentInset: expandedContentInset, collapsedEarWidth: collapsedEarWidth,
        milestonePanelHeight: milestonePanelHeight, trackDropHeight: trackDropHeight, progressLineStrip: progressLineStrip)
    /// 耳朵里「可配模块」与外缘那簇音浪之间的间距(音浪贴哪只耳朵可配,两只耳朵都用得到)。同样要进宽度下限的账(见 `minEarWidth`)。
    static let earWaveSpacing: CGFloat = 5
    /// 耳朵里那枚封面的边长(收起态右耳那枚、稳态耳朵配成「封面」时那枚,同一档)。
    ///
    /// **三处必须用这一份**:两处渲染 + 一处宽度下限(`NotchEarModule.minEarContentWidth`)。
    /// 下限要是按一个"够宽的估计值"给,选了封面的耳朵就会白占几个 pt —— 而这一整轮改动
    /// 要消掉的正是这种白占。
    /// 上限 32 那一档是歌词行末尾那枚,不走这里(耳朵只有 contentTopInset 那么高,放不下 32)。
    static func earArtworkSide(contentTopInset: CGFloat) -> CGFloat { max(16, contentTopInset - 10) }
    /// 没有曲目时左耳里那枚 App 图标的边长。比封面那一档**大 4pt**:macOS 的 App 图标
    /// 位图自带约 12% 的透明外边(1024 画布里圆角方块只占 824),同一边长下它看起来比封面缩了一圈,
    /// 补 4pt 让肉眼看到的方块跟封面那枚差不多大;上限钉在顶行高减 4,矮刘海机型上不顶到边。
    /// 不进宽度下限的账:它只在没有曲目时出现,而且比任何模块都窄(≤ 26pt)。
    static func earAppIconSide(contentTopInset: CGFloat) -> CGFloat {
        min(contentTopInset - 4, earArtworkSide(contentTopInset: contentTopInset) + 4)
    }

    /// 广告期间左耳那枚喇叭的**字号**。SF Symbol 按字号渲染、不是按边长,所以这里
    /// 给的不是 side —— 取封面那一档边长的 0.56 倍(约 13pt),视觉重量跟它要替代的那枚 23pt
    /// 封面小图接近,又不至于在只有一个符号时显得过重。下界 11 兜住极矮刘海。
    static func earAdIconSize(contentTopInset: CGFloat) -> CGFloat {
        max(11, earArtworkSide(contentTopInset: contentTopInset) * 0.56)
    }
}

extension View {
    /// 灵动岛前景文字(歌名、歌词、占位 ♪ 与状态文字)统一的那层投影:卡片底色跟着封面变,浅色封面上白字靠它托住。
    func notchTextShadow() -> some View {
        shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }
}

/// NotchLyricsView 需要从"承载它的那个东西"那里知道的全部几何/状态,一共就这几项。
///
/// 抽成协议是为了让同一份视图既能装进真窗口,也能装进「外观」页的预览里。别给预览另写一份简化渲染:真的那个有左耳歌名、右耳
/// 控件、中间给物理刘海让出的空当、歌词行末尾的封面缩略图、以及 hover 才展开的第三行,两份渲染必然越漂越远。
@MainActor
protocol NotchChromeSource: ObservableObject {
    /// 收起态(暂停 / 广告且没 hover):卡片只留顶行那一条,宽度收到两只耳朵(`NotchWindowRoot.cardWidth`),歌词行不渲染。
    var isCollapsed: Bool { get }
    var isExpanded: Bool { get }
    /// 物理刘海的宽度,顶行中间要给它让出空当。无刘海屏幕是 0。
    var notchWidth: CGFloat { get }
    var contentTopInset: CGFloat { get }
    /// 卡片稳态 / 展开态的**真实**宽(经耳朵下限与「展开 ≥ 稳态」)。歌词行按形态各自定宽、以卡片中心为锚,
    /// 换形态时在原地交叉淡入淡出而不是跟着卡片边沿平移(见 `NotchLyricsView.lyricRowSlot`)。
    /// 真窗口是控制器 recomputeGeometry 算出的那两个数;编辑台由 NotchEditorStage 用同一套公式算好推进来。
    var steadyCardWidth: CGFloat { get }
    var expandedCardWidth: CGFloat { get }
    /// 歌词行的**实际**高度(`AppSettings.notchEffectiveLyricRowHeight`:设定值夹到装得下当前字号和副行为止)。
    /// 稳态、展开两份歌词行同高;卡片高度、展开区的位置、换歌歌名条、封面小图都按它。真窗口是控制器订阅三项设置
    /// 后镜像出来的值(`NotchWindowRoot` 只观察控制器);编辑台的替身现读设置。
    var lyricRowHeight: CGFloat { get }
    /// 展开区里那行"下一句歌词预览"会不会渲染 —— 决定要不要给它留高度。
    /// 曲目级信号(这首歌有没有歌词),不是"此刻有没有下一句",理由见
    /// NotchExpandedMetrics.height 的注释。
    var expandedShowsLyricPreview: Bool { get }
    /// 展开区里那条迷你进度条会不会渲染(= 这首歌有没有时长)。
    var expandedShowsScrubber: Bool { get }
    /// 此刻有没有一首曲目(有歌名/歌手,或者正在放广告)。
    ///
    /// 决定歌词行整行要不要渲染 —— 压根没有曲目时那一行是**全空**的(两个占位 ♪ 已经
    /// 按同一个判据留白了),留着 44pt 纯白只是白占空间。
    /// 刻意不看"在不在播":暂停中仍然有曲目,歌名/歌词/封面都该照常显示。
    var hasTrack: Bool { get }
    /// 此刻在放的是不是广告。决定展开态头部**只剩快捷操作那排键**(见 `trackInfoShowsTrackFields`):
    /// 广告期间歌名位只会写「广告中」、歌手/专辑一律留空(`metadataText` 的既有规矩),封面位是广告物料,
    /// 这四项一律不画;广告态的状态文字与倒计时由歌词行接管(`adStatusColumn`)。
    /// 真窗口 = 控制器镜像的 `isAdBreakNow`(它同时也是 `isCollapsed` 的第三个输入);预览同源(`PlaybackCoordinator`
    /// 的 `isCurrentTrackAdBreak`),但不替门槛轮询登记需求(`NotchLyricsView.drivesAdSkipGate`)。
    var isAdBreakNow: Bool { get }
    /// 此刻在报的收听里程碑(真窗口 = 控制器镜像 `ListenMilestoneCenter.current`;预览恒 nil)。非 nil 时卡片高度换成
    /// 报喜面板那一档(`cardHeight`),顶行以下画报喜面板(`NotchMilestonePanel`)。
    var milestone: ListenMilestone? { get }
    /// 换歌翻牌里此刻掉出来的那条歌名(真窗口 = 控制器的 `trackDrop`;预览恒 nil)。关着歌词行时卡片为它多长
    /// `NotchMetrics.trackDropHeight`(`cardHeight(expanded:)`),开着时盖在歌词行上。
    var trackDrop: NotchTrackDrop? { get }
    /// 此刻有没有瞬态横幅(真窗口 = 控制器镜像 `NotchTransientCenter.banner`;预览恒 false)。关着歌词行时卡片为它多长
    /// `NotchMetrics.trackDropHeight`(`showsBannerStrip`),开着时横幅盖在歌词行上。
    var transientBannerActive: Bool { get }
    /// 要不要画底边那根进度线(`AppSettings.notchShowsProgressLine`)。关着歌词行时卡片为它多长 `NotchMetrics.progressLineStrip`。
    var showsProgressLine: Bool { get }
    /// 进度线画在底边还是沿耳朵(`AppSettings.notchProgressLineStyle`)。沿耳朵时卡片不为它变高。
    var progressLineStyle: NotchProgressLineStyle { get }
    /// 换歌翻牌:`key`(`NotchTrackDropRules.key`)这一首揭晓了没有(真窗口 = 控制器最近一次揭晓的那首;预览恒 true)。
    /// 耳朵里的封面换歌后等它为 true 才翻,跟歌名掉下来同一拍。
    func revealsTrack(_ key: String) -> Bool
    /// 用户要不要看歌词行(`AppSettings.notchShowLyrics`)。关掉时卡片只剩顶行那一条,
    /// 退化成贴着刘海的状态栏。
    ///
    /// 走 chrome 而不是让视图直接读 AppSettings:卡片高度(NotchWindowRoot)和内容渲染
    /// (NotchLyricsView)必须用同一个值,而 NotchWindowRoot 只观察 controller、不观察
    /// AppSettings(那是性能审计定的:别让无关设置写入打醒整卡)。真窗口那一侧
    /// 由控制器订阅设置后 @Published 出来,预览那一侧现读即可。
    ///
    /// 卡片按它排歌词行;真窗口上它还叠了「纯音乐/无歌词时收起歌词行」(`NotchVisibility.showsLyrics`),
    /// 要表达"用户开关本身"的地方读 `showsLyricsSetting`。
    var showsLyrics: Bool { get }
    /// 用户「显示歌词」开关本身。只给展开态快捷操作那颗「显示 / 隐藏歌词」键用。
    var showsLyricsSetting: Bool { get }
    /// 要不要显示播放指示条(音浪)。同上,走 chrome 不直接读 AppSettings——它同时影响
    /// 渲染(NotchLyricsView.topRow)和宽度下限(NotchLyricsWindowController.minEarWidth)。
    var showsEqualizer: Bool { get }
    /// 音浪贴哪只耳朵的外缘。同上。
    var equalizerEar: NotchEqualizerEar { get }
    /// 用户要不要看展开区那行「下一句歌词预览」(`AppSettings.notchExpandedShowsNextLine`)。
    /// 跟 `expandedShowsLyricPreview`(这首歌有没有下一句)是两回事,两者都成立才画,见
    /// `showsExpandedLyricPreview`。同上,走 chrome 不直接读 AppSettings。
    var expandedShowsNextLine: Bool { get }
    /// 用户要不要看展开区那排播放控制键(`AppSettings.notchExpandedShowsControls`)。
    /// 跟 `expandedShowsNextLine`/`expandedShowsScrubber` 不一样的是:控制键不看曲目级
    /// 数据信号(播放/暂停/上一首/下一首任何时候都能点),纯粹是一个用户开关,不需要像
    /// `showsExpandedLyricPreview` 那样跟"这首歌有没有下一句"再取一次交集——这个属性
    /// 本身就是渲染判据,不用另包一层。
    var expandedShowsControls: Bool { get }
    /// 展开区「曲目信息头部」四个独立开关(封面/歌名/歌手/专辑),同上均走 chrome 现读设置。
    /// 这枚封面(`expandedTrackInfoShowsArtwork`)**不是**歌词行末尾那枚
    /// (`lyricRowShowsArtwork`/`lyricRowArtworkPosition`,走 `NotchPlayback` 而不是这个
    /// 协议)——两枚封面是独立开关,可以同时开,见 `AppSettings.notchExpandedShowsArtwork`。
    var expandedTrackInfoShowsArtwork: Bool { get }
    var expandedTrackInfoShowsTitle: Bool { get }
    var expandedTrackInfoShowsArtist: Bool { get }
    var expandedTrackInfoShowsAlbum: Bool { get }
    /// 头部右侧那排「快捷操作」(搜索歌词 / 显示歌词 │ 设置 / 关闭)要不要画。
    /// 跟头部四项同一条链路:它参与头部高度(`max` 里的第三块),所以必须走"镜像 + 重算几何"。
    var expandedShowsQuickActions: Bool { get }
    /// 展开时多行歌词那一格的高度(`AppSettings.notchExpandedLyricListHeight`),关着「多行歌词」时为 0。
    /// 决定展开区高度,走"镜像 + 重算几何"那条链路(同 `lyricRowHeight`)。
    var expandedLyricListHeight: CGFloat { get }
    /// 快捷操作里那颗 ✕:关掉「灵动岛歌词」总开关。真窗口走 `setVisible(false)`(跟设置页开关、菜单栏
    /// 面板同一个唯一入口),预览里是空实现 —— 预览卡整块 `allowsHitTesting(false)`,本来也点不到。
    func closeFromQuickAction()
    /// 展开态头部点歌名 / 专辑名 / 歌手名:开 / 关 / 切换简介浮框(`NotchEditorialPanel`)。预览里是空实现,理由同上。
    func toggleEditorial(_ kind: EditorialCard.Kind)
}

extension NotchChromeSource {
    /// 把承载方此刻的状态填进 Core 的 `NotchCardLayout`:卡片宽高和各块画不画的公式都在那里(selftest 按数值断言),
    /// 下面这些属性只是转发。真窗口和编辑台读的是同一份。
    var cardLayout: NotchCardLayout {
        NotchCardLayout(
            metrics: NotchMetrics.cardLayout, isCollapsed: isCollapsed, isExpanded: isExpanded, notchWidth: notchWidth,
            contentTopInset: contentTopInset, steadyCardWidth: steadyCardWidth, expandedCardWidth: expandedCardWidth,
            lyricRowHeight: lyricRowHeight, expandedLyricListHeight: expandedLyricListHeight, hasTrack: hasTrack,
            isAdBreak: isAdBreakNow, hasMilestone: milestone != nil, hasTrackDrop: trackDrop != nil,
            transientBannerActive: transientBannerActive, showsProgressLine: showsProgressLine,
            progressLineStyle: progressLineStyle, showsLyrics: showsLyrics,
            trackHasLyricPreview: expandedShowsLyricPreview, trackHasScrubber: expandedShowsScrubber,
            expandedShowsNextLine: expandedShowsNextLine, expandedShowsControls: expandedShowsControls,
            trackInfoShowsArtwork: expandedTrackInfoShowsArtwork, trackInfoShowsTitle: expandedTrackInfoShowsTitle,
            trackInfoShowsArtist: expandedTrackInfoShowsArtist, trackInfoShowsAlbum: expandedTrackInfoShowsAlbum,
            expandedShowsQuickActions: expandedShowsQuickActions)
    }

    var showsLyricRow: Bool { cardLayout.showsLyricRow }
    var showsBannerStrip: Bool { cardLayout.showsBannerStrip }
    var showsBottomProgressLine: Bool { cardLayout.showsBottomProgressLine }
    var showsEarProgressLine: Bool { cardLayout.showsEarProgressLine }
    var earProgressHeight: CGFloat { cardLayout.earProgressHeight }
    var showsExpandedLyricPreview: Bool { cardLayout.showsExpandedLyricPreview }
    var showsExpandedLyricList: Bool { cardLayout.showsExpandedLyricList }
    var trackInfoShowsTrackFields: Bool { cardLayout.trackInfoShowsTrackFields }
    var showsExpandedTrackInfo: Bool { cardLayout.showsExpandedTrackInfo }
    var expandedTrackInfoHeight: CGFloat { cardLayout.expandedTrackInfoHeight }
    var expandedTrackInfoHeaderHeight: CGFloat { cardLayout.expandedTrackInfoHeaderHeight }
    var expandedExtraHeightMax: CGFloat { cardLayout.expandedExtraHeightMax }
    var topRowPadding: CGFloat { cardLayout.topRowPadding }
    func earWidth(cardWidth: CGFloat) -> CGFloat { cardLayout.earWidth(cardWidth: cardWidth) }
    var cardWidth: CGFloat { cardLayout.cardWidth }
    var cardHeight: CGFloat { cardLayout.cardHeight }
    func cardHeight(expanded: Bool) -> CGFloat { cardLayout.cardHeight(expanded: expanded) }

    /// 卡片此刻是否顶在**宽度下限**上:稳态真实宽已经贴着宽度滑杆能拖到的下界(`NotchLyricsWindowController.usableWidthRange`,
    /// 量化取整已经算在里面)。音浪独占耳朵时只有这个状态居中于可视耳朵段,其余一律贴外缘(`NotchWidthBounds.soloEqualizerInset`)。
    /// 真窗口和编辑台按各自的刘海宽、顶行高现算;0.5 只是浮点余量。
    var isCardAtMinimumWidth: Bool {
        steadyCardWidth <= NotchLyricsWindowController.usableWidthRange(
            notchWidth: notchWidth, contentTopInset: contentTopInset).lowerBound + 0.5
    }

    /// 卡片外形要的几何(两个圆角设置另由 `NotchCornerLive` 给)。卡片自裁、纯色底、出场裁剪、编辑台虚线框四处都传这一个。
    var cardOutline: NotchCardOutline {
        NotchCardOutline(notchHeight: contentTopInset, collapsedHeight: cardHeight(expanded: false),
                         expandedHeight: cardHeight(expanded: true), isExpanded: isExpanded)
    }
}
