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
    /// 协议)——两枚封面是独立开关,可以同时开,详见 `AppSettings.notchExpandedShowsArtwork`
    /// 上面那段的落点简史。
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
    /// 那一行「正在播放」的歌词行(`lyricRow`,44pt 高)到底画不画 —— 用户关掉「显示歌词」时
    /// 稳态确实该隐藏(退化成贴着刘海的状态栏,这是那个开关本来的意思);但**展开之后必须
    /// 照常画**(回归护栏:只放开「下一句预览」那一行是不够的,这一行
    /// 也被同一个开关挡着,表现是"展开后有下一句、却看不到正在播放的当前行"这种更怪的
    /// 半吊子状态——「展开只有一行歌词了，正在播放的那行被你搞没了」)。跟
    /// `showsExpandedLyricPreview` 同一个道理:展开是用户主动选的动作,不该被"平时不想被
    /// 歌词挡视线"这个理由连累。高度预留(`cardHeight`)和实际渲染(NotchLyricsView 的
    /// `if controller.showsLyricRow`)必须用同一个值。
    var showsLyricRow: Bool { hasTrack && (showsLyrics || isExpanded) }

    /// 瞬态横幅画在卡片为它多长的那一截里:关着歌词行、没展开、没收起时(开着歌词行或展开时横幅盖在歌词行上)。
    /// 高度预留(`cardHeight(expanded:)`)和渲染读同一个值。
    var showsBannerStrip: Bool {
        transientBannerActive && hasTrack && !showsLyrics && !isExpanded && !isCollapsed && milestone == nil
    }

    /// 底边那根进度线此刻画不画:开着「进度线」、有曲目,没展开(展开区有自己那条进度条)、没收起、没在报喜。
    var showsBottomProgressLine: Bool {
        showsProgressLine && hasTrack && !isExpanded && !isCollapsed && milestone == nil
    }

    /// 展开区里那行「下一句歌词预览」到底画不画 —— 只看这首歌**有没有歌词**,不受
    /// 「显示歌词」那个开关影响(关掉稳态那一条歌词行之后,指向展开的
    /// 效果得跟开着歌词时完全一样)。`showsLyrics` 只管稳态那 44pt 的行(见 `showsLyricRow`),
    /// 不该连带影响展开区——展开是用户主动选的动作,他既然已经点开了,就不该因为"平时不想被
    /// 歌词挡视线"这个理由被拿掉。高度预留和实际渲染必须读同一个值,否则要么多留一行的空白、
    /// 要么把它裁掉半截。
    ///
    /// `expandedShowsNextLine` 是用户开关、`expandedShowsLyricPreview` 是曲目级数据,两者都成立才画。别把它塞进
    /// `NotchExpandedMetrics.height` 的入参列表:那会让"这一段到底该不该占高度"有两个真源(一个在这里判、一个在 height()
    /// 里判),这里判完的结果才是 height() 该吃的唯一输入。
    ///
    /// 开着「多行歌词」时这一行不画:列表里本来就有下一句(见 `showsExpandedLyricList`)。
    var showsExpandedLyricPreview: Bool {
        expandedShowsLyricPreview && expandedShowsNextLine && expandedLyricListHeight == 0
    }

    /// 展开时歌词那一格(当前句那一行 + 下一句预览)换成多行列表:开着「多行歌词」、这首有歌词、不在放广告。
    /// 「有歌词」跟下一句预览是同一个曲目级信号(`expandedShowsLyricPreview`),一首歌里不变,卡片不会唱着唱着跳一下。
    /// 不看「收起时显示歌词」:展开是用户主动选的动作,同 `showsLyricRow`。高度预留(`cardHeight(expanded:)`)和渲染
    /// (`NotchLyricsView.cardBodyLayer`)读这同一个值。
    var showsExpandedLyricList: Bool {
        expandedLyricListHeight > 0 && hasTrack && expandedShowsLyricPreview && !isAdBreakNow
    }

    /// 头部那四项曲目字段(封面/歌名/歌手/专辑)此刻能不能画:广告期间一律不画,头部只剩
    /// 快捷操作那排键(见 `isAdBreakNow`)。高度算术(`expandedTrackInfoHeight`)和渲染
    /// (`trackInfoArtwork` / `trackInfoTextStack`)必须读同一个值,否则要么留一截空白、要么裁掉半截。
    var trackInfoShowsTrackFields: Bool { !isAdBreakNow }

    /// 展开区「曲目信息头部」到底画不画——此刻有曲目(没曲目时四者都是空的,画一块空头部没有意义,
    /// 理由同 `showsLyricRow` 对 `hasTrack` 的处理),且五项(封面/歌名/歌手/专辑/快捷操作)里至少
    /// 有一项此刻画得出来;广告期间只算快捷操作那一项(`trackInfoShowsTrackFields`)。
    /// 广告态切换只改这里的算术、不改窗口几何 —— 窗口常驻最大尺寸(`expandedExtraHeightMax`),
    /// 跟 `hasTrack` 那条空闲面板路一样不需要 `recomputeGeometry`。
    var showsExpandedTrackInfo: Bool {
        hasTrack
            && ((trackInfoShowsTrackFields
                 && (expandedTrackInfoShowsArtwork || expandedTrackInfoShowsTitle
                     || expandedTrackInfoShowsArtist || expandedTrackInfoShowsAlbum))
                // 快捷操作是头部的第五项:四项全关(或广告中)、只开它时头部就是一条按钮行。
                || expandedShowsQuickActions)
    }

    /// 曲目信息头部按当前设置算出来的高度,`0` = 不画(见 `showsExpandedTrackInfo`)。单独抽出来是因为 `cardHeight` 和
    /// `NotchLyricsWindowController.expandedExtraHeight` 都要用同一个值,两处各自现算必然漂。
    var expandedTrackInfoHeight: CGFloat {
        guard showsExpandedTrackInfo else { return 0 }
        let fields = trackInfoShowsTrackFields
        return NotchExpandedMetrics.trackInfoHeight(
            showsArtwork: fields && expandedTrackInfoShowsArtwork,
            showsTitle: fields && expandedTrackInfoShowsTitle,
            showsArtist: fields && expandedTrackInfoShowsArtist,
            showsAlbum: fields && expandedTrackInfoShowsAlbum,
            showsActions: expandedShowsQuickActions)
    }

    /// 曲目信息头部要占的**总**高度(内容本身 + 上下各一份间距)——头部现在是独立渲染在
    /// 歌词行**之上**的一块("新字段都在最上面,歌词行/下一句挪到
    /// 最下面"),不再是 `expandedContent` 内部的第一个子视图,所以它自己的 `.frame(height:)`
    /// 得包含"离下面歌词行的间距"这一截——跟 `NotchExpandedMetrics` 里
    /// `lyricPreviewBlock`/`scrubberBlock` 那种"值本身含尾随间距"是同一个惯例。
    /// `expandedContent` 自己那份 `NotchExpandedMetrics.height(...)` 调用因此永远传
    /// `trackInfoHeight: 0`——这部分高度已经在这里算过一次,不能算两次。
    ///
    /// **上面那份间距**不能省:只留尾随间距的话,头部会紧挨在
    /// 上面的 topRow 下面、零间距,标题首行贴到上边。跟 `NotchExpandedMetrics.height`
    /// 的注释同步——两份间距都在 `trackInfoSpacing * 2` 里算过,渲染那侧
    /// (`NotchLyricsView.trackInfoHeader`)只需要在内容顶部真的加一次 `.padding(.top:)`
    /// 把上面那份"用出来",不需要在这里再调这个函数的返回值分配比例。
    var expandedTrackInfoHeaderHeight: CGFloat {
        let height = expandedTrackInfoHeight
        return height > 0 ? height + NotchExpandedMetrics.trackInfoTopSpacing + NotchExpandedMetrics.trackInfoSpacing : 0
    }

    /// 顶行两侧此刻的内边距:稳态 / 收起 `cardHorizontalPadding`,展开态收到 `expandedContentInset`(展开宽够时),规则见
    /// `NotchWidthBounds.topRowPadding`。顶行的 padding、耳宽公式、编辑台的耳朵热区都读它。
    var topRowPadding: CGFloat {
        NotchWidthBounds.topRowPadding(expanded: isExpanded, steadyWidth: steadyCardWidth, expandedWidth: expandedCardWidth,
                                       cardPadding: NotchMetrics.cardHorizontalPadding,
                                       contentInset: NotchMetrics.expandedContentInset)
    }

    /// 一只耳朵的宽度(两只恒等宽):卡片宽扣掉刘海空当和两侧内边距后平分。真窗口按 GeometryReader 给的此刻卡片宽算(尺寸动画
    /// 逐帧跟着变),编辑台的耳朵热区按目标卡片宽算。内边距不能漏扣:漏了顶行比卡片宽 2×padding,ZStack 被撑宽,背景形状超出窗口,
    /// 底部圆角被窗口裁成直角。
    func earWidth(cardWidth: CGFloat) -> CGFloat {
        max(0, (cardWidth - notchWidth - topRowPadding * 2) / 2)
    }

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

    /// 卡片当前宽度,全仓唯一一份公式:真窗口(NotchWindowRoot)画卡片、控制器算卡片在屏幕上的矩形(`cardScreenFrame`)都读它。
    /// 收起态收到两只耳朵,展开态取展开宽。
    var cardWidth: CGFloat {
        if isCollapsed {
            return min(steadyCardWidth, notchWidth + 2 * NotchMetrics.collapsedEarWidth + 2 * NotchMetrics.cardHorizontalPadding)
        }
        return isExpanded ? expandedCardWidth : steadyCardWidth
    }

    /// 卡片当前高度,全仓唯一一份公式:真窗口(NotchWindowRoot)和设置页编辑台(NotchEditorStage)都读它。两处各写一份必然漂,
    /// 漂的表现是行不见了高度还留着、或反过来把行裁掉半截。
    var cardHeight: CGFloat {
        if isCollapsed { return contentTopInset }
        if milestone != nil { return contentTopInset + NotchMetrics.milestonePanelHeight }
        return cardHeight(expanded: isExpanded)
    }

    /// 没展开 / 展开某一种形态下的卡片高度(不看收起态)。`cardHeight` 和圆角两态的高度(`cardOutline`)都走这里。
    func cardHeight(expanded: Bool) -> CGFloat {
        // 没有曲目(决策 #31):展开只长出「空闲面板」那一块。走下面的通式的话,歌词行本来就被 hasTrack 守着不留,但展开区照常按
        // "三键 + 进度条"留 59～76pt,而那块内容(`cardBodyLayer`)整个被 hasTrack 挡掉,hover 上去会长出一大块什么都没有的黑。
        // 高度预留与实际渲染(`idleExpandedPanel` 的 frame)读同一个值。
        if !hasTrack {
            return contentTopInset + (expanded ? NotchExpandedMetrics.idlePanelHeight : 0)
        }
        return contentTopInset
            // 稳态歌词行要不要留高度,同 showsLyricRow(展开时哪怕关着「显示歌词」也要留;这里已经有曲目)。
            // 展开且开着多行歌词时,这一格换成列表的高度(`showsExpandedLyricList`)。
            + ((showsLyrics || expanded) ? (expanded && showsExpandedLyricList ? expandedLyricListHeight : lyricRowHeight)
               // 换歌翻牌、瞬态横幅:关着歌词行时为掉出来的歌名 / 横幅多长一截(开着时盖在歌词行上,不用另长)。
               : (trackDrop != nil || transientBannerActive ? NotchMetrics.trackDropHeight : 0))
            // 进度线:关着歌词行时卡片底边就是刘海下沿,线在刘海那一段会被挡住,往下多长一截让它整根露出来。
            + (!expanded && !showsLyrics && showsProgressLine ? NotchMetrics.progressLineStrip : 0)
            + (expanded
               ? NotchExpandedMetrics.height(
                   hasLyricPreview: showsExpandedLyricPreview,
                   hasScrubber: expandedShowsScrubber,
                   hasControls: expandedShowsControls,
                   trackInfoHeight: expandedTrackInfoHeight)
               : 0)
    }
}
