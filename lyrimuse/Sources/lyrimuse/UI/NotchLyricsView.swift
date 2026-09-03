import AppKit
import SwiftUI
import Combine
import LyrimuseCore

/// 灵动岛的**窄订阅代理**(2026-08-19 性能审计落地,与悬浮歌词的 OverlayPlayback 同款
/// 模式,那边的注释讲了完整机制,这里不重复):PlaybackCoordinator 36 个 @Published 灵动岛
/// 实读约 17 个、AppSettings 47 个只读 2 个,整对象订阅会让歌词窗口拖音量、设置页无关
/// 滑杆这类写入以鼠标事件频率打醒整卡 body(含封面背景/跑马灯/音浪),开多屏镜像再按
/// 屏数翻倍。只转发实读字段,值类型一律 removeDuplicates。
///
/// ⚠️ sink 只用参数值,不回读源属性(@Published willSet 时机,回读是旧值)。
///
/// anchor 例外地**入订阅**(跟悬浮窗不同):灵动岛的 progressSection 要在 body 里判断
/// 「有没有锚点」决定进度条走播放态还是暂停态分支,而 LocalPlaybackSource 只在首锚/换歌/
/// seek/倍速变化时才重建锚点(稳定播放期间不赋值),它本身就是低频源,订阅无害。
/// currentLyricsOffsetMs 仍由逐字填色的 TimelineView 闭包直读协调器,不入订阅。
@MainActor
private final class NotchPlayback: ObservableObject {
    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    /// 只有「专辑」这个耳朵模块读它(2026-08-31 加)。窄订阅的纪律没变:多订一个字段是因为
    /// 真的有人读,不是"顺手都订上"。
    @Published private(set) var album = ""
    @Published private(set) var isPlayingNow = false
    @Published private(set) var currentLine: SyncedLyricLine?
    /// 单行展示面取这一行(唱完就切走,提前亮出下一句给跟唱用),不是 currentLine。
    /// 规则见 CompactLyricLead。currentLine 仍然保留 —— 均衡器条子跟的是"此刻在唱哪个字",
    /// 那是 currentLine 的语义,不能跟"屏幕上显示哪一句"混。
    @Published private(set) var compactLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    @Published private(set) var currentLineFillSettled = true
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var highResArtworkImage: NSImage?
    @Published private(set) var blurredArtworkImage: NSImage?
    @Published private(set) var anchor: ProgressAnchor?
    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?
    /// 灵动岛几乎所有前景元素的颜色:音浪、歌名、歌手、歌词(含逐字染色的调色板)、三个
    /// 播放键、进度条、瞬态横幅 —— 全卡 16 处 `accentOrWhite` 都是它。取到封面主色就用,
    /// 否则白(用 notchAccentColor 而非 artworkAccentColor 的理由见
    /// PlaybackCoordinator.notchAccentColor 注释)。两个输入在这里预组合成单个去重值,
    /// 任何一个变了才发一次。
    ///
    /// ⚠️ **"要不要跟封面走"这件事由 `notchCardStyle == .coverArt` 决定**(2026-08-31 改)。
    /// 在此之前它读的是 `AppSettings.followsCoverArt` —— 那是**桌面悬浮歌词**「配色」组里的
    /// 开关,而它的两个 UI 入口(设置页悬浮歌词段、悬浮窗上那个 ⚙ 快捷菜单)都挂在悬浮歌词上。
    /// 于是只开灵动岛的用户根本够不到这个决定自己整卡颜色的开关;更糟的是灵动岛「风格」里
    /// **已经有一个叫「跟随封面」的选项**(指背景铺封面模糊图),同样四个字、两件事,去那儿找
    /// 只会找错。现在两者合并成一件事:选「跟随封面」= 这张卡整体跟着封面走(背景是模糊封面、
    /// 前景是封面主色);选另外三种风格 = 前景恒为白。灵动岛因此不多一个开关,也不再受悬浮歌词
    /// 那边任何设置影响。
    /// (取不到封面主色时 `notchAccentColor` 为 nil,自动落回白色 —— 跟 `.coverArt` 背景在
    ///  没有封面时退回 darkGradient 是同一种兜底,不需要额外分支。)
    @Published private(set) var accent: Color = .white
    // ---- 来自 AppSettings ----
    // 灵动岛只读这一项:它既决定卡片背景(见 NotchCardStyle.fill / backgroundLayer),
    // 也决定前景取不取封面主色(折进上面的 accent)。
    @Published private(set) var notchCardStyle: NotchCardStyle = .coverArt
    /// 稳态/展开那一行两只耳朵各显示什么(见 NotchEarModule)。
    @Published private(set) var leftEar: NotchEarModule = .title
    @Published private(set) var rightEar: NotchEarModule = .artist
    /// 歌词行末尾那枚封面缩略图要不要显示、贴哪一边(2026-09-01)。走这里现读而不是
    /// `NotchChromeSource` 协议——它只影响 `lyricRowContent` 内部的 HStack 排列,不影响
    /// 卡片高度/宽度,理由同 `notchCardStyle`/`leftEar`/`rightEar`(那几个也只影响渲染)。
    @Published private(set) var lyricRowShowsArtwork: Bool = true
    @Published private(set) var lyricRowArtworkPosition: NotchLyricRowArtworkPosition = .right
    /// 装得下的短句靠哪边(2026-09-03)。同上走这里现读:它只改 `MarqueeText` 静止时的
    /// 对齐锚点和展开态「下一句」那一行的 frame 对齐,不影响卡片任何一个尺寸。
    /// ⚠️ 初值必须是 `AppSettings.defaultNotchLyricsAlignment`,不能另写一个字面量 ——
    /// 这个 `@Published` 的初值和 `AppSettings.init()` 的 fallback 是同一件事,写两份就会
    /// 在"订阅还没首次投递"的那一帧闪一下另一个方向。
    @Published private(set) var lyricsAlignment: LyricsRestingAlignment =
        AppSettings.defaultNotchLyricsAlignment
    /// 展开区时间行中间要不要显示「歌词时间轴微调」(2026-09-01)。同上走这里现读——只影响
    /// `NotchScrubber` 内部时间行怎么排,不影响卡片高度,理由见
    /// `AppSettings.notchExpandedShowsLyricsOffset` 上面那条⚠️。
    @Published private(set) var showsLyricsOffsetControls: Bool = false
    /// 这首歌的歌词时间轴校正值(毫秒)+ 每次点击的步长——菜单栏面板那颗微调控件读的是
    /// 同一对值(`PlaybackCoordinator.trackLyricsOffsetMs`/`AppSettings.lyricsOffsetStepMs`),
    /// 这里镜像一份是因为 `NotchScrubber` 是 `private struct`、靠参数传值(不直接订阅
    /// PlaybackCoordinator/AppSettings),得有人先把值取到手。
    @Published private(set) var trackLyricsOffsetMs: Int = 0
    @Published private(set) var lyricsOffsetStepMs: Int = 200
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$album.removeDuplicates().sink { [weak self] in self?.album = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$currentLine.removeDuplicates().sink { [weak self] in self?.currentLine = $0 },
            p.$compactLine.removeDuplicates().sink { [weak self] in self?.compactLine = $0 },
            p.$nextLineText.removeDuplicates().sink { [weak self] in self?.nextLineText = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            p.$artworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.artworkImage = $0 },
            p.$highResArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.highResArtworkImage = $0 },
            p.$blurredArtworkImage.removeDuplicates(by: { $0 === $1 })
                .sink { [weak self] in self?.blurredArtworkImage = $0 },
            // 锚点本身低频(见类型注释),不去重(ProgressAnchor 非 Equatable,每次重锚
            // 也确实都是新值)。
            p.$anchor.sink { [weak self] in self?.anchor = $0 },
            p.$pausedPositionMs.removeDuplicates().sink { [weak self] in self?.pausedPositionMs = $0 },
            p.$currentDurationMs.removeDuplicates().sink { [weak self] in self?.currentDurationMs = $0 },
            // ⚠️ 2026-08-31:第二个输入从**悬浮歌词那边的** `followsCoverArt` 换成了灵动岛
            // 自己的 `notchCardStyle`。理由见 accent 的注释。
            Publishers.CombineLatest(p.$notchAccentColor, s.$notchCardStyle)
                .map { accent, style in style == .coverArt ? (accent ?? .white) : .white }
                .removeDuplicates()
                .sink { [weak self] in self?.accent = $0 },
            s.$notchCardStyle.removeDuplicates().sink { [weak self] in self?.notchCardStyle = $0 },
            s.$notchLeftEar.removeDuplicates().sink { [weak self] in self?.leftEar = $0 },
            s.$notchRightEar.removeDuplicates().sink { [weak self] in self?.rightEar = $0 },
            s.$notchLyricRowShowsArtwork.removeDuplicates().sink { [weak self] in self?.lyricRowShowsArtwork = $0 },
            s.$notchLyricRowArtworkPosition.removeDuplicates().sink { [weak self] in self?.lyricRowArtworkPosition = $0 },
            s.$notchLyricsAlignment.removeDuplicates().sink { [weak self] in self?.lyricsAlignment = $0 },
            s.$notchExpandedShowsLyricsOffset.removeDuplicates().sink { [weak self] in self?.showsLyricsOffsetControls = $0 },
            p.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] in self?.trackLyricsOffsetMs = $0 },
            s.$lyricsOffsetStepMs.removeDuplicates().sink { [weak self] in self?.lyricsOffsetStepMs = $0 },
        ]
    }
}

// 用 AnyShapeStyle 抹掉三种截然不同的 ShapeStyle 具体类型(纯色/材质/渐变),让
// NotchHangingShape.fill(_:) 能用同一个属性统一接收,不需要写三份 if/switch 分支
// 各自调用不同重载的 .fill()。
extension NotchEarModule {
    /// ⚠️ 不能存成 `static let`/常量字典:`L10n.t` 要在每次取值时现算,存进去等于把首次访问
    /// 时的语言冻在里面(同 OverlayAlignmentSegmentedControl.label(for:) 那条)。
    var displayName: String {
        switch self {
        case .title: return L10n.t("歌名")
        case .artist: return L10n.t("歌手")
        case .album: return L10n.t("专辑")
        case .artwork: return L10n.t("封面")
        case .controls: return L10n.t("播放控制")
        case .elapsed: return L10n.t("已播时长")
        case .remaining: return L10n.t("剩余时长")
        case .none: return L10n.t("不显示")
        }
    }

    /// 这个模块要不要每秒重算一次(时间类才要)。用它把 TimelineView 圈在真正需要的那一格里 ——
    /// 顶行原本完全不随播放进度重绘,给不需要的模块也套一个周期时钟纯属白付。
    var isClock: Bool { self == .elapsed || self == .remaining }

    /// 这个模块塞进一只耳朵里**最少**要多宽。不含朝刘海那侧的 `earNotchInset`,也不含右耳
    /// 外缘那簇音浪 —— 那两样由 `NotchLyricsWindowController.minEarWidth(...)` 加。
    ///
    /// ⚠️ 判据是"**再窄就真的被裁**",不是"再窄就不好看"。宽度滑杆的下界完全按它算
    /// (`NotchLyricsWindowController.contentWidth`),往上多给一个 pt 就是替用户把岛的下限
    /// 抬高一个 pt —— 而这一整轮(2026-08-31)用户连提三次的都是同一件事:
    /// 「左右耳占用了很大空间」「支持调到更小」「这里还有很多位置,把最小调整为刚好放得下
    /// 一个封面,或者刚好放得下一个音浪就好」。
    ///
    /// ⚠️ **歌名 / 歌手 / 专辑给 0,这是有意的**。它们跑马灯,窄了只是滚得更勤、再窄就是
    /// 什么都不显示,**不会坏** —— 所以它们压根不该参与决定下限。第一版给过 24pt("可读窗口
    /// 还剩两个汉字"),那是拿"好看"当"会坏"用:它把默认配置(歌名/歌手)的下界钉在 300,而
    /// 用户看着 300pt 下那两个词旁边的空白说"这里还有很多位置"。给 0 之后,默认配置的下界
    /// 落到跟「不显示/不显示」同一个数(这台机器 251)—— 那时下限完全由右耳外缘那簇音浪撑着,
    /// 正是用户说的"刚好放得下一个音浪"。**代价说清楚**:拖到最底那一格,右耳的文字会被音浪
    /// 挤成 0 宽(左耳还剩 20pt 在滚)。这是滑杆上肉眼可见的连续过程,不是突变,用户想要文字
    /// 就往回拖两格 —— 把这个选择留给用户,而不是替他把区间截掉。
    ///
    /// 剩下三类是真的会被裁的,数字都是 2026-08-31 离屏实测:
    ///   - 三键 = 命中框 15 + 18 + 15,`spacing: 0`(见 `earControls` 的横向账)= **48**
    ///   - 时间 = 11.5pt 等宽数字下 "-12:34" / "-88:88" 实测 **39.0**
    ///   - 封面 = `NotchMetrics.earArtworkSide` 现算,**不给估计值**(这台机器菜单栏 32 → 22pt)
    func minEarContentWidth(contentTopInset: CGFloat) -> CGFloat {
        switch self {
        case .none, .title, .artist, .album: return 0
        case .controls: return 48
        case .artwork: return NotchMetrics.earArtworkSide(contentTopInset: contentTopInset)
        // ⚠️ 时间**不能**靠跑马灯兜底 —— 一秒一跳的数字滚起来根本读不了,所以这一档必须
        // 真的放得下。超过一小时的曲目("-1:23:45" 实测 50.1pt)在最窄处仍会滚:那是极少数,
        // 不值得为它把所有人的下限再抬 11pt。
        case .elapsed, .remaining: return 39
        }
    }

    /// 主要信息给 semibold + 更高不透明度,次要信息压一档。**样式跟着模块走、不跟着哪只耳朵走**:
    /// 把歌名换到右耳时它还是那个最显眼的东西,不会因为换了个位置就变次要。
    /// (这也正是改动前的样子:左耳歌名 semibold/0.85、右耳歌手 medium/0.6。)
    var isPrimary: Bool { self == .title }
}

extension NotchLyricRowArtworkPosition {
    var displayName: String {
        switch self {
        case .left: return L10n.t("左")
        case .right: return L10n.t("右")
        }
    }
}

extension NotchCardStyle {
    var displayName: String {
        switch self {
        case .solidBlack: return L10n.t("纯黑")
        case .frostedGlass: return L10n.t("磨砂玻璃")
        case .darkGradient: return L10n.t("深色渐变")
        case .coverArt: return L10n.t("跟随封面")
        }
    }

    // .coverArt 的真实渲染(封面模糊图)是在 NotchLyricsView.backgroundLayer 里单独
    // 处理的(ShapeStyle 表达不了 .blur()/.overlay() 这类 View 修饰符,没法塞进这个
    // AnyShapeStyle 里),这里给它的返回值只是"没有封面数据时的兜底"/"万一有别处意外
    // 读到这个属性"的合理默认——跟 darkGradient 用同一个值,不代表 .coverArt 的
    // 实际效果,不要在其它地方依赖这条分支来渲染 .coverArt。
    var fill: AnyShapeStyle {
        switch self {
        case .solidBlack:
            return AnyShapeStyle(Color.black)
        case .frostedGlass:
            return AnyShapeStyle(.thickMaterial)
        case .darkGradient, .coverArt:
            // 从左上到右下过渡,比纯黑多一点点冷色调层次感,又不像磨砂玻璃那样会透出
            // 桌面背景色。
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(hexWithAlpha: "#1C1A24FF", fallback: .black),
                        Color(hexWithAlpha: "#14212AFF", fallback: .black),
                        Color(hexWithAlpha: "#10161CFF", fallback: .black),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

// 灵动岛样式的内容视图。稳态(不 hover)常显"歌名+播放控制+当前歌词逐字高亮+专辑封面"
// 整套,hover 时在下面多展开一块"下一句歌词预览+迷你进度条"作为补充信息(参考 boring.notch
// 等实现的分层思路:稳态给完整基本信息,hover 给深化信息)。
//
// 分两/三行:
// - 顶行(高度 = controller.contentTopInset,等于刘海本身/无刘海屏幕的兜底值):物理
//   刘海是屏幕硬件层面真实不发光的区域,横向落在刘海宽度(controller.notchWidth)范围内
//   的内容会被真实挡掉,这一行中间让出 notchWidth 宽度的空当。空当里唯一的内容是一枚
//   **故意让硬件挡住**的品牌胶囊彩蛋(notchSeam,2026-09-03):只在截屏/录屏/投屏时露面。
//   左耳放歌名,右耳放 3 个播放控制按钮。
// - 歌词行:逐字高亮跟随播放进度扫过,技术上跟 LyricsOverlayView.mainLine 是同一套原理
//   (TimelineView 按渲染帧频现算 fillFraction+渐变着色),但不复用那份实现——这里没有
//   WrapLayout(单行不换行,超长直接硬裁),前景色固定白色,复杂度明显小一截,直接写一份
//   简化版更清楚,不值得为了复用去抽象共享代码。这一行的尾端(也就是稳态下卡片的右下角)
//   放一枚专辑封面小图,见 artworkThumbnail。
// - hover 展开时才出现的第三行:下一句歌词预览 + 一条迷你进度条。
//
// 整个卡片形状故意只在底部两个角做圆角、顶部两个角是直角(NotchHangingShape)——顶部
// 紧贴屏幕/刘海本身那条边,视觉上应该是直接从刘海"长出来"、跟屏幕顶边严丝合缝,而不是
// 一个悬空的、四角都带圆角的胶囊。
//
// 背景用磨砂玻璃(.thickMaterial,配 NotchLyricsWindow 里固定的 .darkAqua 外观)。刘海
// 本身所在的那一段空当(顶行中间)物理上不会显示任何像素,渲染成什么都无所谓,不需要跟
// 其余部分区别对待。
/// 灵动岛卡片的固定尺寸。
///
/// 放在泛型视图**外面**有两个原因:泛型类型不能有 static stored property(编译器直接
/// 拒绝);而且预览那边(SectionPreviewBars)要用同样的数值算容器高度,单独一个命名空间
/// 比从视图里翻出来更直白。
///
/// ⚠️ 跟 NotchLyricsWindowController 里的同名常量是同一套几何的两处描述,改一处要改两处。
enum NotchMetrics {
    /// 稳态歌词行的高度。
    static let compactRowHeight: CGFloat = 44
    /// 展开区的最大高度 / 按内容算的实际高度 —— 实现在 LyrimuseCore 的
    /// NotchExpandedMetrics(那边有完整的推导注释和 selftest 断言),这里只是转发,
    /// 让调用点仍然只需要认识 NotchMetrics 这一个入口。
    ///
    /// ⚠️ 2026-09-01 加了 `trackInfoHeight`/`hasLyricPreviewPossible` 之后:**以后再往
    /// `NotchExpandedMetrics` 加一个决定展开区高度的入参,这两个转发函数(以及
    /// `NotchLyricsWindowController.expandedExtraHeight`)都要跟着加**,同时别忘了在
    /// `NotchLyricsWindowController` 加一条对应的设置订阅——漏了订阅的表现不是崩,是
    /// "改完设置卡片高度纹丝不动,直到下次触发别的几何重算才追上",很难联想到订阅上。
    static func expandedExtraHeightMax(
        hasLyricPreviewPossible: Bool = true, hasControlsPossible: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        NotchExpandedMetrics.maxHeight(
            hasLyricPreviewPossible: hasLyricPreviewPossible, hasControlsPossible: hasControlsPossible,
            trackInfoHeight: trackInfoHeight)
    }

    static func expandedExtraHeight(
        hasLyricPreview: Bool, hasScrubber: Bool, hasControls: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        NotchExpandedMetrics.height(
            hasLyricPreview: hasLyricPreview, hasScrubber: hasScrubber, hasControls: hasControls,
            trackInfoHeight: trackInfoHeight)
    }

    /// 曲目信息头部(封面 + 歌名/歌手/专辑三个文字开关)的高度。
    static func expandedTrackInfoHeight(
        showsArtwork: Bool, showsTitle: Bool, showsArtist: Bool, showsAlbum: Bool
    ) -> CGFloat {
        NotchExpandedMetrics.trackInfoHeight(
            showsArtwork: showsArtwork, showsTitle: showsTitle, showsArtist: showsArtist, showsAlbum: showsAlbum)
    }

    // 曲目信息头部渲染(而非高度算术)要用到的几个尺寸,同样只转发 NotchExpandedMetrics
    // 那份定义,不重复写字面量。
    static var trackInfoSpacing: CGFloat { NotchExpandedMetrics.trackInfoSpacing }
    static var trackInfoTopSpacing: CGFloat { NotchExpandedMetrics.trackInfoTopSpacing }
    static var trackInfoArtworkSide: CGFloat { NotchExpandedMetrics.trackInfoArtworkSide }
    static var trackInfoLineSpacing: CGFloat { NotchExpandedMetrics.trackInfoLineSpacing }

    // 收起态(没在播放)单侧耳宽:左耳只放音浪(约 14pt 宽)、右耳只放一枚小封面
    // (2026-08-19 用户拍板的 iPhone 灵动岛式极简形态,歌名/播放键都收进 hover 展开卡),
    // 34 = 内容 + 两侧呼吸空间。用在 NotchWindowRoot.cardWidth 的收起分支。
    static let collapsedEarWidth: CGFloat = 34
    // 以下同样是被泛型限制赶出来的固定尺寸(理由见类型注释)。
    // minWordDurationMs/wordEdgeSoftenBand 已随 wordGradient 收编进 WordKaraokeGradient
    // (2026-08-20)——别在这里再留一份"看着在生效"的死常量,将来改 KaraokeFill 会静默失真。
    static let artworkLyricSpacing: CGFloat = 10
    /// 歌词行右端渐隐带的宽度(2026-08-22 加,用户报「歌词有时候被封面挡住」)。
    ///
    /// 跟 artworkLyricSpacing 同为 10pt 不是巧合:渐隐带的作用就是把"硬切口紧贴封面"
    /// 这 10pt 间隙里的突变摊开成一段过渡。13pt 半粗体下约合 1.5 个拉丁字符,再宽会开始
    /// 吃掉能读的内容。完整判据(为什么只在停在开头时给)见 MarqueeMath.trailingFadeWidth。
    static let lyricEdgeFadeWidth: CGFloat = 10
    static let artworkCornerRadius: CGFloat = 5
    /// 两只耳朵**朝刘海那一侧**的内缩(2026-08-20 用户要求"歌手不要那么紧贴真实刘海")。
    ///
    /// 顶行的排布是「左耳 + 刘海宽的空当 + 右耳」严丝合缝地铺满,于是右耳的左边界正好
    /// 压在物理刘海的右沿上:装不下的歌手名(跑马灯,从左起)第一个字就贴着刘海黑边,
    /// 长歌名尤其明显(实测 "VALORANT/Grabbitz/bbno$")。左耳同理 —— 长歌名会一直顶到
    /// 刘海左沿。这 6pt 只吃进耳朵内部,不改耳宽、不动外缘的音浪/卡片边距,
    /// 代价是跑马灯可用宽度少 6pt(更容易触发滚动,而滚动本来就是长名字的正解)。
    static let earNotchInset: CGFloat = 6
    /// 卡片左右两侧的内边距(`topRow` / `collapsedRow` 末尾那句 `.padding(.horizontal:)`)。
    ///
    /// ⚠️ 这是**单侧**值。三处按它算:那两句 padding、耳宽公式 `(卡片宽 − 刘海宽 − 2×它) / 2`、
    /// 以及宽度下限 `NotchLyricsWindowController.contentWidth`。2026-08-31 之前三处各写一份
    /// 字面量(10 / 20 / 20),提成常量是因为下限现在要跟着耳朵配置现算,再抄一份必然漂。
    static let cardHorizontalPadding: CGFloat = 10
    /// 耳朵里「可配模块」与外缘那簇音浪之间的间距(2026-08-31 之前叫 rightEarContentSpacing——
    /// 音浪贴哪只耳朵可配之后,两只耳朵都用得到这个间距,改成不带方位的名字)。同样要进宽度
    /// 下限的账(见 `minEarWidth`)。
    static let earWaveSpacing: CGFloat = 5
    /// 耳朵里那枚封面的边长(收起态右耳那枚、稳态耳朵配成「封面」时那枚,同一档)。
    ///
    /// ⚠️ **三处必须用这一份**:两处渲染 + 一处宽度下限(`NotchEarModule.minEarContentWidth`)。
    /// 下限要是按一个"够宽的估计值"给,选了封面的耳朵就会白占几个 pt —— 而这一整轮改动
    /// (2026-08-31)要消掉的正是这种白占。
    /// 上限 32 那一档是歌词行末尾那枚,不走这里(耳朵只有 contentTopInset 那么高,放不下 32)。
    static func earArtworkSide(contentTopInset: CGFloat) -> CGFloat { max(16, contentTopInset - 10) }
}

/// NotchLyricsView 需要从"承载它的那个东西"那里知道的全部几何/状态 —— 一共就这几项。
///
/// 抽成协议是为了让**同一份视图**既能装进真窗口,也能装进「外观」页的预览里。
/// 预览曾经是另写的一份简化渲染(一个圆角矩形 + 一行居中文字),那跟真实灵动岛差得远:
/// 真的那个有左耳歌名、右耳三个播放控制、中间给物理刘海让出的空当、歌词行末尾的封面
/// 缩略图、以及 hover 才展开的第三行。两份渲染必然越漂越远,不如让预览用真的那一份。
@MainActor
protocol NotchChromeSource: ObservableObject {
    /// 收起态(没在播放且没 hover):窗口缩到刘海本身大小,内容整套摘掉。
    var isCollapsed: Bool { get }
    var isExpanded: Bool { get }
    /// 物理刘海的宽度,顶行中间要给它让出空当。无刘海屏幕是 0。
    var notchWidth: CGFloat { get }
    var contentTopInset: CGFloat { get }
    /// 展开区里那行"下一句歌词预览"会不会渲染 —— 决定要不要给它留高度。
    /// 曲目级信号(这首歌有没有歌词),不是"此刻有没有下一句",理由见
    /// NotchMetrics.expandedExtraHeight 的注释。
    var expandedShowsLyricPreview: Bool { get }
    /// 展开区里那条迷你进度条会不会渲染(= 这首歌有没有时长)。
    var expandedShowsScrubber: Bool { get }
    /// 此刻有没有一首曲目(有歌名/歌手,或者正在放广告)。
    ///
    /// 决定歌词行整行要不要渲染 —— 压根没有曲目时那一行是**全空**的(两个占位 ♪ 已经
    /// 按同一个判据留白了),44pt 白占着正是用户 2026-08-21 说的"占用空间"。
    /// 刻意不看"在不在播":暂停中仍然有曲目,歌名/歌词/封面都该照常显示。
    var hasTrack: Bool { get }
    /// 用户要不要看歌词行(`AppSettings.notchShowLyrics`)。关掉时卡片只剩顶行那一条,
    /// 退化成贴着刘海的状态栏。
    ///
    /// ⚠️ 走 chrome 而不是让视图直接读 AppSettings:卡片高度(NotchWindowRoot)和内容渲染
    /// (NotchLyricsView)必须用同一个值,而 NotchWindowRoot 只观察 controller、不观察
    /// AppSettings(那是 2026-08-19 性能审计定的:别让无关设置写入打醒整卡)。真窗口那一侧
    /// 由控制器订阅设置后 @Published 出来,预览那一侧现读即可。
    var showsLyrics: Bool { get }
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
    /// ⚠️ 这枚封面(`expandedTrackInfoShowsArtwork`)**不是**歌词行末尾那枚
    /// (`lyricRowShowsArtwork`/`lyricRowArtworkPosition`,走 `NotchPlayback` 而不是这个
    /// 协议)——两枚封面是独立开关,可以同时开,详见 `AppSettings.notchExpandedShowsArtwork`
    /// 上面那段⚠️的落点简史。
    var expandedTrackInfoShowsArtwork: Bool { get }
    var expandedTrackInfoShowsTitle: Bool { get }
    var expandedTrackInfoShowsArtist: Bool { get }
    var expandedTrackInfoShowsAlbum: Bool { get }
    func setExpanded(_ expanded: Bool)
}

extension NotchChromeSource {
    /// 那一行「正在播放」的歌词行(`lyricRow`,44pt 高)到底画不画 —— 用户关掉「显示歌词」时
    /// 稳态确实该隐藏(退化成贴着刘海的状态栏,这是那个开关本来的意思);但**展开之后必须
    /// 照常画**(2026-08-31 实测坐实的回归:第一版只放开了「下一句预览」这一行,忘了这一行
    /// 也被同一个开关挡着,表现是"展开后有下一句、却看不到正在播放的当前行"这种更怪的
    /// 半吊子状态——用户原话「展开只有一行歌词了，正在播放的那行被你搞没了」)。跟
    /// `showsExpandedLyricPreview` 同一个道理:展开是用户主动选的动作,不该被"平时不想被
    /// 歌词挡视线"这个理由连累。高度预留(`cardHeight`)和实际渲染(NotchLyricsView 的
    /// `if controller.showsLyricRow`)必须用同一个值。
    var showsLyricRow: Bool { hasTrack && (showsLyrics || isExpanded) }

    /// 展开区里那行「下一句歌词预览」到底画不画 —— 只看这首歌**有没有歌词**,不受
    /// 「显示歌词」那个开关影响(2026-08-31 用户要求:关掉稳态那一条歌词行之后,指向展开的
    /// 效果得跟开着歌词时完全一样)。`showsLyrics` 只管稳态那 44pt 的行(见 `showsLyricRow`),
    /// 不该连带影响展开区——展开是用户主动选的动作,他既然已经点开了,就不该因为"平时不想被
    /// 歌词挡视线"这个理由被拿掉。高度预留和实际渲染必须读同一个值,否则要么多留一行的空白、
    /// 要么把它裁掉半截。
    ///
    /// `expandedShowsNextLine`(2026-09-01)是这个功能第一次有用户开关:以前无条件跟着
    /// `expandedShowsLyricPreview` 这个曲目级数据出现,现在两者都成立才画。别把它塞进
    /// `NotchMetrics.expandedExtraHeight` 的入参列表——那会让"这一段到底该不该占高度"有
    /// 两个真源(一个在这里判、一个在 height() 里判),这里判完的**结果**才是 height() 该吃
    /// 的唯一输入。
    var showsExpandedLyricPreview: Bool { expandedShowsLyricPreview && expandedShowsNextLine }

    /// 展开区「曲目信息头部」到底画不画——只要四个开关(封面/歌名/歌手/专辑)有一个开着,
    /// 且此刻有曲目(没曲目时四者都是空的,画一块空头部没有意义,理由同
    /// `showsLyricRow` 对 `hasTrack` 的处理)。
    var showsExpandedTrackInfo: Bool {
        hasTrack && (expandedTrackInfoShowsArtwork || expandedTrackInfoShowsTitle
                     || expandedTrackInfoShowsArtist || expandedTrackInfoShowsAlbum)
    }

    /// 曲目信息头部按当前设置算出来的高度,`0` = 不画(见 `showsExpandedTrackInfo`)。
    /// 单独抽出来是因为 `cardHeight` 和 `NotchLyricsWindowController.expandedExtraHeight`
    /// 都要用同一个值——两处各自现算的话,当天早些时候「左右耳」那次教训会原样重演一遍。
    var expandedTrackInfoHeight: CGFloat {
        guard showsExpandedTrackInfo else { return 0 }
        return NotchMetrics.expandedTrackInfoHeight(
            showsArtwork: expandedTrackInfoShowsArtwork,
            showsTitle: expandedTrackInfoShowsTitle,
            showsArtist: expandedTrackInfoShowsArtist,
            showsAlbum: expandedTrackInfoShowsAlbum)
    }

    /// 曲目信息头部要占的**总**高度(内容本身 + 上下各一份间距)——头部现在是独立渲染在
    /// 歌词行**之上**的一块(2026-09-01 用户要求"新字段都在最上面,歌词行/下一句挪到
    /// 最下面"),不再是 `expandedContent` 内部的第一个子视图,所以它自己的 `.frame(height:)`
    /// 得包含"离下面歌词行的间距"这一截——跟 `NotchExpandedMetrics` 里
    /// `lyricPreviewBlock`/`scrubberBlock` 那种"值本身含尾随间距"是同一个惯例。
    /// `expandedContent` 自己那份 `NotchMetrics.expandedExtraHeight(...)` 调用因此永远传
    /// `trackInfoHeight: 0`——这部分高度已经在这里算过一次,不能算两次。
    ///
    /// ⚠️ **上面那份间距**是 2026-09-01 同一天补的第二轮:第一版只留了尾随间距,头部紧挨在
    /// 上面的 topRow 下面、零间距,用户报"标题首行贴到上面边了"。跟 `NotchExpandedMetrics.height`
    /// 的注释同步——两份间距都在 `trackInfoSpacing * 2` 里算过,渲染那侧
    /// (`NotchLyricsView.trackInfoHeader`)只需要在内容顶部真的加一次 `.padding(.top:)`
    /// 把上面那份"用出来",不需要在这里再调这个函数的返回值分配比例。
    var expandedTrackInfoHeaderHeight: CGFloat {
        let height = expandedTrackInfoHeight
        return height > 0 ? height + NotchMetrics.trackInfoTopSpacing + NotchMetrics.trackInfoSpacing : 0
    }

    /// 卡片当前高度 —— **全仓唯一一份公式**,真窗口(NotchWindowRoot)和设置页编辑台
    /// (NotchEditorStage)都读它。
    ///
    /// ⚠️ 2026-08-31 抽出来的:在此之前这个公式在那两处各写了一遍,而它的入参一路从 1 个
    /// (isCollapsed)涨到 4 个(再加 hasTrack / isExpanded 那一组 / showsLyrics)。本章
    /// 设计决策里早写过同类教训:"两处各自判断必然漂,而漂的表现是行不见了高度还留着、
    /// 或反过来把行裁掉半截"。加第四个入参那天正好把它收成一份。
    var cardHeight: CGFloat {
        if isCollapsed { return contentTopInset }
        return contentTopInset
            // 稳态歌词行要不要留高度,见 showsLyricRow(展开时哪怕关着「显示歌词」也要留)。
            + (showsLyricRow ? NotchMetrics.compactRowHeight : 0)
            + (isExpanded
               ? NotchMetrics.expandedExtraHeight(
                   hasLyricPreview: showsExpandedLyricPreview,
                   hasScrubber: expandedShowsScrubber,
                   hasControls: expandedShowsControls,
                   trackInfoHeight: expandedTrackInfoHeight)
               : 0)
    }
}

struct NotchLyricsView<Chrome: NotchChromeSource>: View {
    @ObservedObject var controller: Chrome
    // 不整对象订阅 PlaybackCoordinator/AppSettings —— 见 NotchPlayback 的注释。
    // NotchTransientCenter 也不在这里订阅:banner 只被歌词行消费,订阅下沉到
    // NotchTransientHost 子视图,横幅出现/消失只失效那一行,不打醒整卡。
    // 进度条拖动的三个交互状态(@GestureState/宽度/悬停)同理下沉进 NotchScrubber ——
    // 原来挂在这里,拖动时每个指针事件都整卡重估。
    @StateObject private var playback = NotchPlayback()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 出场动画期间内容的透明度(NotchWindowRoot 在那 0.3s 里改,默认 1)。只作用于内容 VStack,
    /// 背景层不受影响 —— 先看到卡片形状从刘海长出来、再看到字,见 NotchRevealShape 头注。
    @Environment(\.notchRevealContentOpacity) private var revealContentOpacity

    // 稳态歌词行的固定高度——跟 NotchLyricsWindowController.contentSize.height 保持
    // 一致(两个文件都描述同一个窗口的几何,这点数值耦合是设计使然,不值得为两个常量
    // 专门抽一个共享类型)。展开时窗口总高度会多出 expandedExtraHeight,这部分空间全部
    // 交给下面的展开内容,歌词行本身高度不跟着变。


    var body: some View {
        GeometryReader { proxy in
            // topRow 外层还有 .padding(.horizontal, 10)(左右各 10pt),这里要把这 20pt
            // 也算进去,否则「两只耳朵 + 刘海空当」正好等于 proxy.size.width 之后再叠加
            // padding,会让 topRow 的实际宽度比 GeometryReader 分配的宽度多出整整 20pt:
            // ZStack 会跟着这个更宽的子视图一起变宽,导致背景形状 NotchHangingShape 收到
            // 的 rect 比窗口真实宽度多 20pt,只有当这多出来的 20pt 沿某一侧溢出时,那一侧
            // 的底部圆角才会显示为直角(圆角计算本身没错,只是形状宽度比窗口多算了一截,
            // 超出边界的部分被窗口硬裁掉,裁到的正好是圆弧那一小段)。
            let earWidth = max(0, (proxy.size.width - controller.notchWidth
                                   - NotchMetrics.cardHorizontalPadding * 2) / 2)
            ZStack(alignment: .top) {
                backgroundLayer(size: proxy.size)
                // 收起态铺一层纯黑盖住卡片样式自己的底(2026-08-19 用户要求):没在播放时
                // 卡片就是挂在真刘海边上的一小块,深色渐变/磨砂/封面模糊底在真刘海的
                // 纯黑旁边都是"看得出来的一块灰"——收起就该和机器刘海一个颜色,融为一体。
                // 用 opacity 而不是 if/else 换填充:跟卡片收放同一条弹簧渐变,不硬切。
                NotchHangingShape(bottomCornerRadius: 20)
                    .fill(Color.black)
                    .opacity(controller.isCollapsed ? 1 : 0)
                // 收起态(没在播放、没 hover)卡片缩到刘海大小,这里把常显内容整套摘掉而不是
                // 指望卡片太小自然裁掉——避免文字/按钮在收缩过程中被挤压变形,收起就是纯粹
                // 一块背景,跟真实刘海融为一体。
                //
                // ⚠️ 但"摘掉"不能是硬切。2026-08-16 之前这里没有 transition,内容在收起的
                // 第一帧就整块消失,而卡片还要再花 0.45 秒缩回去 —— 观感是"字先没了,黑块才
                // 慢慢收",两段动作对不上。加一个跟卡片同一条弹簧驱动的淡出 + 轻微上缩
                // (anchor 在顶部,因为卡片是从顶边往上收的),内容就跟着卡片一起"被吸回刘海"。
                VStack(spacing: 0) {
                    // 顶行占菜单栏那一条高度,收起后跟菜单栏齐平、不额外占屏。两种形态:
                    // 收起(没在播放)= iPhone 灵动岛式极简(左耳封面、右耳音浪,2026-08-19
                    // 用户拍板,歌名/播放键都收进 hover 展开卡);稳态/展开 = 歌名 + 播放键。
                    if controller.isCollapsed {
                        collapsedRow(earWidth: earWidth)
                            .frame(height: controller.contentTopInset)
                    } else {
                        topRow(earWidth: earWidth)
                            .frame(height: controller.contentTopInset)
                    }
                    // 歌词行和 hover 展开区才是"收进去"的部分。
                    //
                    // ⚠️ hasTrack 这一条(2026-08-21)必须跟 NotchWindowRoot.cardHeight 里
                    // 那个同款判断成对出现:压根没有曲目时这一行是**全空**的(两个占位 ♪ 已按
                    // 同一判据留白),44pt 白占着就是用户报的"占用空间"。一处改一处不改的
                    // 表现是"行不见了高度还留着"或反过来把行裁掉半截。
                    if !controller.isCollapsed && controller.hasTrack {
                        // 曲目信息头部(歌名/歌手/专辑,2026-09-01):画在歌词行**之上**——
                        // 用户原话"新加的这些字段元素都是在最上面,然后歌词行和下一行歌词
                        // 这些都放在最下面,而不是现在这样信息都夹在两行歌词之间"(第一版
                        // 把它塞进 expandedContent 顶部,结果夹在"正在播放"那行和"下一句
                        // 预览"中间)。只在展开时出现,理由跟下面 expandedContent 一致:
                        // 展开是用户主动选的动作。高度用 `expandedTrackInfoHeaderHeight`——
                        // 它已经包含跟下面歌词行之间的间距,见该属性的注释。
                        if controller.isExpanded, controller.showsExpandedTrackInfo {
                            trackInfoHeader
                                .frame(height: controller.expandedTrackInfoHeaderHeight, alignment: .top)
                        }
                        // 用户关掉「显示歌词」时这一行连同它那 44pt 一起不渲染,卡片退化成
                        // 只剩顶行的一条状态栏(2026-08-31)——但展开时哪怕关着也要照常画,
                        // 见 showsLyricRow 的注释(2026-08-31 回归:第一版漏了展开这一档,
                        // 表现是"展开后有下一句预览、却看不到正在播放的当前行")。⚠️ 判据
                        // 必须跟 NotchChromeSource.cardHeight 里那一条**同源**,那边是全仓
                        // 唯一一份高度公式,两处各判各的必然漂。
                        if controller.showsLyricRow {
                            lyricRow
                                .frame(height: NotchMetrics.compactRowHeight)
                        }
                        // 展开区**完全不**受那个开关影响(2026-08-31 用户要求):它是够到
                        // 播放控制和进度条的唯一入口,而且用户主动指向展开这个动作本身就说明
                        // 他现在想看更多,不该因为平时不想被歌词挡视线这个理由被拿掉——连里面
                        // 那行下一句预览也照常画(见 showsExpandedLyricPreview 的注释)。
                        if controller.isExpanded {
                            expandedContent
                        }
                    }
                }
                // 出场动画的内容淡入(2026-09-03):值来自 NotchWindowRoot 的 keyframeAnimator,
                // 平时恒为 1;背景层不套它,所以卡片形状先长出来、字后到。
                .opacity(revealContentOpacity)
                // 卷进顶行:锚点放顶部,内容一边淡出一边往上缩,跟卡片高度收缩同一条弹簧。
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
            // 展开态内容(下一句预览+进度条)本身没有另外裁一次形状——如果只让背景那一层
            // fill 是圆角、前景内容不跟着裁,内容溢出圆角边界时会带着直角"戳"出卡片轮廓。
            // 这里对整个 ZStack 统一裁一次,保证任何内容都不会越出这个卡片的真实外轮廓。
            .clipShape(NotchHangingShape(bottomCornerRadius: 20))
        }
        // 2026-08-16 删掉了这里原来那个 .onHover。它覆盖的范围比卡片大一圈(预览那边
        // 早就记录过同一个现象),窗口改成常驻最大尺寸之后这变成了实打实的 bug:鼠标划过
        // 卡片下方的透明区也会展开。命中判定和触觉反馈都移到 NotchWindowRoot,那里拿
        // 精确坐标跟卡片矩形直接比;预览那边本来就走自己的 onContinuousHover。
        // hover 时给卡片一点投影,让它从桌面/窗口背景上"浮起来"。收起态不给 —— 那时它
        // 假装自己是刘海的一部分,投影会立刻暴露这是个窗口。
        // 2026-08-17 去掉了展开态那圈投影。它本来的用意是"hover 时让卡片从背景上浮起来",
        // 但实际观感是整个卡片外侧糊着一层灰 —— 灵动岛的设计语言是**从刘海长出来**,
        // 不是一张悬空的卡片,投影反而把这件事拆穿了。
        //
        // ⚠️ 将来如果要把投影加回来,窗口**必须**按投影半径留出四周余量,否则阴影会被
        // 窗口的矩形边界硬裁,在底部两个圆角外侧留下两块直角的深色残影(2026-08-17 用户
        // 报过一次"左右角怎么还有个虚的直角",离线渲染对照复现确认就是这个)。当时的
        // 修法是把窗口宽高各加一圈,见 NotchLyricsWindowController.recomputeGeometry ——
        // 投影既然撤了,那圈余量也跟着撤了,别只加回投影不加余量。
    }

    // 2026-08-02 新增"跟随封面"背景——跟"歌词窗口"的 artworkBackground(LyricsWindowView.swift)
    // 完全同一套效果(封面整图放大、高斯模糊、压一层半透明黑),只是缩小到灵动岛胶囊
    // 尺寸;封面数据本来就已经在转发给 PlaybackCoordinator 供"歌词窗口"用,这里直接复用
    // 同一个数据源,不需要新开一条取图链路。读的是解码缓存 playback.artworkImage 而不是
    // 原始字节,理由见 PlaybackCoordinator.artworkImage 的注释。
    //
    // ShapeStyle(NotchCardStyle.fill)表达不了 .blur()/.overlay() 这类 View 修饰符,
    // 所以 .coverArt 这个风格不走"给 NotchHangingShape 填色"这条路,改成在背景层直接
    // 塞一张 Image。
    //
    // ⚠️ .scaledToFill() 之后、.clipShape 之前必须显式钉一次 .frame(width:height:)
    // ——2026-08-02 实测排查坐实(用像素级采样确认过,不是肉眼被模糊柔化骗了),踩了
    // 三版才找对根因:
    // 第一版完全没裁——四个角全变直角。
    // 第二版换成 `.clipped()`——`.clipped()` 只会裁成矩形,压根不认识
    //   NotchHangingShape 这个"顶直角、底圆角"的形状,自然还是直角。
    // 第三版改成 `.clipShape(NotchHangingShape(...))` 直接套在 Image 上,以为这样
    //   总该认得形状了,肉眼截图看起来也像是圆角——但对左下角做像素级采样(逐行扫描
    //   card 区域与背景的分界线 x 坐标,检查是否随 y 增大而右移)后发现分界线纹丝不动,
    //   证明那次"看起来圆"其实是模糊本身的柔和渐变骗了肉眼,底层裁剪仍然是直角。
    // 真正原因是本文件顶部 topRow/earWidth 那处注释描述过的同一类问题:
    // `.scaledToFill()`(即 aspectRatio(contentMode: .fill))为了保证"图片撑满、
    // 不留缝隙"而向布局系统请求一个可能比 ZStack 实际可见尺寸更大的 frame(维持宽高比
    // 需要在某个方向溢出、裁掉多余部分)。`.clipShape` 是按它**紧邻**的上一个 View
    // 的 frame 算 `path(in rect:)` 的,而不是按外层 GeometryReader/窗口的真实尺寸——
    // 如果这张 Image 协商到的 frame 比灵动岛胶囊本身大一圈,NotchHangingShape 画出来的
    // 圆角就落在了这个偏大的矩形边缘,而不是胶囊真正的可见边缘,可见区域里看到的只是
    // 这个偏大矩形的中间一截,自然还是直角。修法:`.scaledToFill()` 之后先用
    // `.frame(width: size.width, height: size.height)` 把协商结果显式钉回胶囊真正的
    // 尺寸(GeometryReader 的 proxy.size,从 body 传进来),`.clipShape` 才会在正确的
    // 边界上计算圆角。
    //
    // 没有封面数据(这首歌还没解析出封面/collector 还没查到/本来就没有)时退回
    // NotchCardStyle.darkGradient 的固定渐变——不会露出空白背景,也不需要用户在"没有
    // 封面"和"其它三个固定风格"之间多做一次选择。
    //
    // 模糊半径比"歌词窗口"artworkBackground 的 60 小得多——那边画布常年好几百 pt 高,
    // 60pt 模糊半径只占画布的一小部分,还能看出封面本身的色块层次;灵动岛稳态高度只有
    // 76pt、宽度 360pt(约 4.7:1 的又矮又宽比例),照搬同一个绝对数值相对尺寸夸张太多,
    // 2026-08-02 实测排查坐实:哪怕换一张色彩很丰富的封面(比如粉色玩具马配红白条纹的
    // 封面),灵动岛这里也会被抹成跟其它封面几乎分不出来的统一深灰色,颜色信息基本损失
    // 殆尽,违背了"跟随封面颜色"这个功能本身的目的。调小到 20——仍然是明显的"模糊",
    // 但能留住封面主色调之间可辨认的差异。
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        // 优先用高清替代(highResArtworkImage):系统那份对网易云永远只有 100×100,云盘
        // 没匹配上的歌还是灰底音符占位图 —— 缓存里解析到真封面时背景该铺真封面。nil 时
        // 回落系统那份,跟歌词窗口封面卡同一套取舍(见 highResArtworkImage 的注释)。
        // 铺的是 PlaybackCoordinator 预烘焙好的模糊图(2026-08-19 性能审计落地),不再在
        // 视图层挂 .blur(radius: 20) 活滤镜 —— 那是合成期滤镜,这个窗口播放期间因逐字
        // 填色/音浪/跑马灯几乎永动,GPU 每次重合成都对同一张图重算同一个模糊。烘焙源在
        // 数据层就是 highResArtworkImage ?? artworkImage(高清替代优先的口径不变),且
        // clampedToExtent 让边缘实心 —— 原来靠打底层遮的羽化带不复存在,打底层保留只为
        // 烘焙空窗(封面刚到、模糊图晚几十 ms)兜底。
        if playback.notchCardStyle == .coverArt,
           let image = playback.blurredArtworkImage {
            ZStack {
                // 不透明打底(跟无封面时的深色渐变同款),烘焙空窗期先露它,见上。
                NotchHangingShape(bottomCornerRadius: 20)
                    .fill(NotchCardStyle.darkGradient.fill)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    // 数值跟 PlaybackCoordinator 算 accentForCoverArtBackground 时估算
                    // 背景亮度用的是同一个常量(LocalPlaybackSource.
                    // notchCoverArtOverlayOpacity)——两处对不上,文字对比度的估算就会
                    // 跟实际渲染出来的背景脱节。
                    .overlay(Color.black.opacity(LocalPlaybackSource.notchCoverArtOverlayOpacity))
                    .clipShape(NotchHangingShape(bottomCornerRadius: 20))
                    // 换歌/高清替代到货都会产出一张**新的**烘焙图实例(NSImage 指针比较),
                    // 一条过渡覆盖原来 artworkData 字节比较 + highRes 指针比较两条 ——
                    // 顺带省掉原来每次 body 对几十~几百 KB Data 的逐字节 memcmp。
                    .animation(.easeInOut(duration: 0.5), value: playback.blurredArtworkImage)
            }
        } else {
            NotchHangingShape(bottomCornerRadius: 20)
                .fill(playback.notchCardStyle.fill)
        }
    }

    /// 收起态顶行(2026-08-19 用户拍板):左耳专辑封面、右耳音浪 —— 跟 iPhone 灵动岛
    /// 收起形态同构(封面在左、声浪在右)。歌名/播放键不进这里:想看想按,hover 一下
    /// 就是完整展开卡。音浪在暂停时是静止的矮条(EqualizerBars 自己按 isPlaying 处理),
    /// 封面是"刚才在放什么"的余韵;没封面时左耳留空,不画占位方块(理由同 artworkThumbnail)。
    private func collapsedRow(earWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack {
                // ⚠️ 高清替代优先,跟本文件另外四处(展开卡小图、coverArt 背景等)同一个口径 ——
                // 这一处 2026-09-02 之前漏了 `?? `,于是收起态左耳显示的是**系统原图**。
                // 不只是清晰度问题:Chrome 里放 YouTube Music 时系统给的可能是一帧 MV 画面
                // (实测方大同《白发》给的是 150×84 的 MV 截帧),那就是显示了另一张图。
                if let image = playback.highResArtworkImage ?? playback.artworkImage {
                    let side = NotchMetrics.earArtworkSide(contentTopInset: controller.contentTopInset)
                    // 收起态的小封面也是「打开歌词窗口」的入口 —— 跟展开卡右下角那枚
                    // 封面同一动作(点封面看完整歌词,两种形态行为一致)。
                    Button {
                        AppActions.shared.openLyricsWindow?()
                    } label: {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("打开歌词窗口"))
                }
            }
            .frame(width: earWidth)

            notchSeam

            HStack {
                EqualizerBars(color: accentOrWhite, isPlaying: playback.isPlayingNow,
                              amplitude: Self.vocalAmplitude(at:))
            }
            .frame(width: earWidth)
        }
        .padding(.horizontal, NotchMetrics.cardHorizontalPadding)
    }

    /// 压根没有曲目。读 controller 那一份而不是自己再从 playback 算一遍 —— 卡片高度
    /// (NotchWindowRoot.cardHeight)也要用同一个判据决定歌词行占不占 44pt,两处各算一遍
    /// 必然漂,而漂的表现是"行不见了但高度还留着"或反过来把行裁掉半截。
    /// 跟菜单栏面板的同名属性是同一套语义(MenuBarPanel.isIdleNoTrack)。
    private var isIdleNoTrack: Bool { !controller.hasTrack }

    /// 刘海空当(物理刘海遮挡处)里的品牌胶囊彩蛋(2026-09-03,借鉴清单 #17,用户拍板)。
    ///
    /// 肉眼永远看不到——那块被硬件挡死;只在截全屏 / 录屏 / 投屏或镜像到无刘海显示器时
    /// 露出来,像给刘海贴了个牌子。两个条件缺一不画:
    ///  - `notchWidth > 0`:无刘海屏幕的兜底几何和外接屏上的镜像副本都是 0,画了就真的能
    ///    看见,那就不是彩蛋而是一块白疤。
    ///  - `hasTrack`:会议里没放歌、灵动岛停在空闲黑块时,共享画面顶上不该挂着牌子(用户
    ///    选了"只在有曲目时画",而不是参考实现那种常驻)。
    /// 「截屏/录屏时隐藏」开着时整窗不进截图,不必另加开关。高度按顶行让 8pt 边、夹在
    /// 14～22pt(矮刘海机型顶行可能不到 26pt)。装饰元素,读屏不念。
    private var notchSeam: some View {
        ZStack {
            if controller.notchWidth > 0, controller.hasTrack {
                Text(verbatim: "Lyrimuse")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(seamTextColor)
                    .padding(.horizontal, 9)
                    .frame(height: min(22, max(14, controller.contentTopInset - 8)))
                    .background {
                        // 底色跟灵动岛当前主色走(同歌名/音浪那份 accent),上半截叠一层淡白渐变
                        // 加 0.5pt 浅描边当光泽——纯色胶囊贴在纯黑刘海里像一块色卡,加点高光才
                        // 读得出"是个立体的牌子"(2026-09-03 用户要求"颜色跟着灵动岛走,稍微
                        // 加一点光泽有区分度")。
                        Capsule().fill(accentOrWhite)
                            .overlay {
                                Capsule().fill(LinearGradient(
                                    colors: [.white.opacity(0.42), .white.opacity(0.10), .clear],
                                    startPoint: .top, endPoint: .center))
                            }
                            .overlay { Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
                    }
                    .accessibilityHidden(true)
            }
        }
        .frame(width: controller.notchWidth)
    }

    /// 胶囊字色按底色的 WCAG 相对亮度选黑/白:亮度 > 0.179(黑白两侧对比度相等的临界点)
    /// 时黑字更清楚,否则白字。复用 LocalPlaybackSource 描边取色那套亮度公式,别再写一份。
    private var seamTextColor: Color {
        guard let ns = NSColor(accentOrWhite).usingColorSpace(.sRGB) else { return .black }
        let lum = LocalPlaybackSource.relativeLuminance(
            r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
        return lum > 0.179 ? .black : .white
    }

    /// 播放指示条(音浪)是不是配给了这只耳朵,而且这只耳朵没选控制键——三键本身已经在
    /// 报播放状态(播放时画 ⏸),音浪摆在旁边是同一件事说两遍,而且窄宽度下(耳朵最窄
    /// 70pt,减内缩 6 之后 64pt)刚好放得下三键的 48pt,再挤进音浪的 14+5 就超了。这是
    /// "音浪贴这只耳朵外缘"唯一的例外,跟哪只耳朵无关。
    private func showsEqualizer(on side: NotchEqualizerEar, module: NotchEarModule) -> Bool {
        controller.showsEqualizer && controller.equalizerEar == side && module != .controls
    }

    private var equalizerBars: some View {
        EqualizerBars(color: accentOrWhite, isPlaying: playback.isPlayingNow,
                      amplitude: Self.vocalAmplitude(at:))
    }

    private func topRow(earWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 左耳:可配模块 + (可选)音浪。音浪贴哪只耳朵可配之后(2026-08-31,原来写死在
            // 右耳),这里跟下面右耳是完全对称的结构——只是音浪在外缘,外缘在左耳是"最左",
            // 所以音浪排在模块**前面**(下面右耳反过来,音浪排在模块后面)。
            HStack(spacing: NotchMetrics.earWaveSpacing) {
                if showsEqualizer(on: .left, module: playback.leftEar) {
                    equalizerBars
                }
                earContent(playback.leftEar, alignment: .leading)
            }
            // 内缩必须在 .frame(width:) **之前** —— 之后加等于把耳朵整体变宽 6pt,
            // 三段就不再严丝合缝铺满,背景形状/刘海空当会跟着错位。
            .padding(.trailing, NotchMetrics.earNotchInset)
            .frame(width: earWidth)

            // 刘海本身的空当——物理硬件不发光区域,只放那枚肉眼看不见的彩蛋(见 notchSeam)。
            notchSeam

            // 右耳:可配模块 + (可选)音浪(2026-08-19 设计评审的终形,用户逐步拍板;
            // 2026-08-31 从"音浪固定贴右耳"改成可配置贴哪只耳朵/要不要显示):控制键全部
            // 退场 —— 岛是 hover 展开的,光标到达耳朵之前岛已经展开,完整三键就在展开卡
            // 的进度条下方(见 expandedContent),耳朵里再留一枚播放键是重复目标。默认配置
            // (左歌名、右歌手 + 音浪贴右耳)因此跟改动前逐像素一致——只是现在两者都能关/换边。
            HStack(spacing: NotchMetrics.earWaveSpacing) {
                earContent(playback.rightEar, alignment: .trailing)
                if showsEqualizer(on: .right, module: playback.rightEar) {
                    equalizerBars
                }
            }
            .padding(.leading, NotchMetrics.earNotchInset) // 理由同左耳,见 earNotchInset
            .frame(width: earWidth)
        }
        .padding(.horizontal, NotchMetrics.cardHorizontalPadding)
    }

    // MARK: - 耳朵里的可配模块

    /// 一只耳朵里画什么。`alignment` 是**耳朵**的属性(左耳靠左、右耳靠右),不是模块的。
    ///
    /// ⚠️ 三条约束,每条都对应本仓一处既有做法:
    ///
    /// ① **只有时间类模块才套 `TimelineView`。** 顶行原本完全不随播放进度重绘,给歌名/歌手/
    ///    专辑也套一个时钟纯属白付(这个仓库为"整卡跟着高频源重绘"做过一整轮性能审计,见
    ///    NotchPlayback 的头注)。
    ///
    /// ② **没有锚点就不排表**,静态画冻结值 —— 照搬本仓既有的**存在性门**(`NotchScrubber`
    ///    和歌词窗口那条进度都是 `if let anchor` 才挂表)。暂停/没在播放时 `LocalPlaybackSource`
    ///    会把 anchor 置 nil,于是这一格退回 `pausedPositionMs` 的冻结读数、一次表都不排。
    ///    ⚠️ 这条不是可选优化:设置页那块编辑台渲染的是**同一份**视图,而它的替身 chrome 把
    ///    `hasTrack` 写死 true、`isCollapsed` 写死 false —— 没有这道门,只要有人把耳朵配成时间类,
    ///    设置页开着就会每秒空转一次,哪怕根本没在放歌。
    ///
    /// ③ **周期起点按锚点对齐到"曲目位置的整秒"**,步长按倍速取 `1/rate`(见
    ///    `NotchTimeFormat.clockSchedule`)。钉在**墙钟**整秒上是不行的:曲目位置的整秒边界跟
    ///    墙钟整秒无关,两者的相位差在一条锚点的生命周期里是**常量** —— 也就是说 hover 展开时
    ///    耳朵可能整首歌都比正下方那条迷你进度条**慢 1 秒**(耳朵 1:23、进度条 1:24 长期并排),
    ///    而不是偶尔闪一下。对齐之后两处读数同源同相。
    ///    ⚠️ 别顺手把 `clockText` 里的 `Date()` 换成 `context.date`:对齐之后 tick 恰好落在边界上,
    ///    用调度时刻采样有可能因为亚毫秒取整读回旧的那一秒;实际派发比调度晚几毫秒,`Date()`
    ///    反而落在边界的正确一侧。
    @ViewBuilder
    private func earContent(_ module: NotchEarModule, alignment: Alignment) -> some View {
        switch module {
        case .artwork:
            earArtwork(alignment: alignment)
        case .controls:
            earControls(alignment: alignment)
        case .elapsed, .remaining:
            if let anchor = playback.anchor {
                TimelineView(NotchTimeFormat.clockSchedule(for: anchor)) { _ in
                    earText(clockText(module), module: module, alignment: alignment)
                }
            } else {
                earText(clockText(module), module: module, alignment: alignment)
            }
        case .title, .artist, .album, .none:
            earText(metadataText(module), module: module, alignment: alignment)
        }
    }

    /// 耳朵里那枚封面小图(2026-08-31)。
    ///
    /// ⚠️ 尺寸走**收起态那一枚**的公式(`contentTopInset − 10`,约 23pt),**不是**歌词行末尾
    /// 那枚 32pt 的:耳朵只有 `contentTopInset` 那么高,32pt 塞进来上下一点余量都不剩。当年
    /// 「封面放不进耳朵」的实测结论(见 artworkThumbnail 上方)量的正是 32pt 那一档。
    ///
    /// 没有封面数据时**整块不画**(不摆占位方块)—— 跟歌词行末尾那枚同一个取舍,理由见那边。
    @ViewBuilder
    private func earArtwork(alignment: Alignment) -> some View {
        if let image = playback.highResArtworkImage ?? playback.artworkImage {
            artworkThumbnail(
                image,
                side: NotchMetrics.earArtworkSide(contentTopInset: controller.contentTopInset))
                .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
        }
    }

    /// 耳朵里那一排播放控制键(2026-08-31 用户点名要加)。
    ///
    /// ⚠️ 尺寸沿用 `controlButton` 的 `primary` 两档**默认值**(侧键 glyph 9.5 / 命中 15,
    /// 播放键 11 / 18)—— 那正是 2026-08-19 把三键从耳朵挪进展开卡之前、耳朵里用的那一档,
    /// 默认值从那次搬家起就一直留在代码里没有调用方,现在重新有了。展开卡里那一排是 22pt,
    /// 比这里大一号,是刻意的(那儿是真正会被点的地方)。
    ///
    /// 横向账(min 宽度下也要放得下):三键 15+18+15 = 48pt,`spacing: 0` —— 命中框本身就比
    /// 图标大一圈(15 的框装 9.5 的图标,两侧各 2.75pt),再加间距会白白撑宽。而耳朵最窄是
    /// **70pt**(`NotchLyricsWindowController.minEarWidth`,宽度滑杆的下界就是按它算的),
    /// 减掉朝刘海那侧 6pt 的内缩还有 64pt,放得下。右耳还要再减音浪那 14pt + 5pt 间距 = 45pt
    /// —— 放不下,所以右耳选控制键时**音浪让位**(见 topRow 那段⚠️)。
    private func earControls(alignment: Alignment) -> some View {
        HStack(spacing: 0) {
            controlButton("backward.fill") { MusicPlaybackController.previousTrack() }
            controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill", primary: true) {
                // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                PlaybackCoordinator.shared.userTogglePlayPause()
            }
            controlButton("forward.fill") { MusicPlaybackController.nextTrack() }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// 三个元数据模块的取值。
    ///
    /// ⚠️ 三条既有规矩原样保留,别在加模块时顺手丢掉:
    ///   ① **广告插播**:歌名位写「广告中」,不展示广告物料的名字(2026-08-19 用户拍板);
    ///      歌手/专辑在广告期间一律留空 —— 广告没有"歌手"可言,画上去是假信息。
    ///   ② **压根没有曲目时留白**,不摆 ♪(2026-08-21 用户要求"那个无意义的音符不要占位置")。
    ///   ③ 歌名为空时的 ♪ 兜底只在"有曲目但拿不到歌名"这种边角才到得了,保留。
    private func metadataText(_ module: NotchEarModule) -> String {
        if isIdleNoTrack { return "" }
        let isAd = playback.isCurrentTrackAdBreak
        switch module {
        case .title:
            if isAd { return L10n.t("广告中") }
            return playback.title.isEmpty ? "♪" : playback.title
        case .artist: return isAd ? "" : playback.artist
        case .album: return isAd ? "" : playback.album
        // 非文本模块不走这条路(见 earContent 的分发),这里只是把 switch 补齐。
        case .artwork, .controls, .elapsed, .remaining, .none: return ""
        }
    }

    /// 已播 / 剩余。位置口径跟卡片里那条迷你进度条同源:锚点外推 ?? 暂停冻结位置;歌词时间轴
    /// 偏移**不适用**(那是歌词的事,不是播放进度的事,别顺手加上去)。时长未知(播客/流)时
    /// 剩余算不出来,整块留白而不是画个 `--:--` 占位 —— 不为拿不到的数据编一个占位符,跟预览
    /// 那条"不编造假进度"是同一个态度。
    ///
    /// ⚠️ 同源**不等于**逐帧同值,两处已知的差:
    ///   - **拖动进度条时**:进度条画的是拖到哪儿(它自己的 `@GestureState`,私有),耳朵画的仍是
    ///     真实播放位置。不把拖动状态提上来是刻意的 —— 那要么把私有手势状态提到整卡这一层
    ///     (整卡跟着每个指针事件重估,正是那轮性能审计修掉的东西),要么再拉一条通道。
    ///   - **剩余时长的时长来源**:这里用 `playback.currentDurationMs`,进度条用 `anchor.durationMs`。
    ///     正常一致,但这是第二个可漂的点,改任一处时对一下另一处。
    ///
    /// ⚠️ **广告插播时照常显示**,不套用 `metadataText` 那条"广告期间歌手/专辑留空"的规矩:
    /// 位置和时长在广告期间是播放器对广告物料的真实读数,不是假信息;清空反而会让耳朵跟正下方
    /// 那条进度条自相矛盾。
    private func clockText(_ module: NotchEarModule) -> String {
        guard !isIdleNoTrack else { return "" }
        guard let position = playback.anchor?.extrapolatedPositionMs(now: Date())
                ?? playback.pausedPositionMs else { return "" }
        switch module {
        case .elapsed:
            return NotchTimeFormat.mmss(ms: position)
        case .remaining:
            guard let total = playback.currentDurationMs, total > 0 else { return "" }
            return "-" + NotchTimeFormat.mmss(ms: max(0, total - position))
        default:
            return ""
        }
    }

    /// 耳朵里那一行字。跑马灯的 id 用**显示串**本身 —— 换了内容才重新测量/重新开始滚动。
    ///
    /// ⚠️ 等宽数字**只给时间类**。给歌名/歌手/专辑也套上的话,带数字的名字("M83"、
    /// "24K Magic")字形会被静默改掉 —— 而这次改造的前提是"默认配置跟改动前逐像素一致"。
    /// 时间类必须套:不套的话每秒跳一格数字宽度就变、整行跟着抖。
    /// 条件收进 **Font 值本身**(`Font.monospacedDigit()` 返回 Font),不走 `if/else` 也不走
    /// `ViewModifier` + `AnyView`:那两种都会在视图树上多一层类型/身份变化,而这里变的只是
    /// 一个字体属性。(2026-08-31 一度写成 `ConditionalMonospacedDigit` 那样一个 modifier,
    /// 附的理由是"避免分支切换整块重建" —— 那个理由是假的:`isClock` 一变,上面 `earContent`
    /// 的分支本来就先换了,子树无论如何都要重建。)
    private func earText(_ text: String, module: NotchEarModule, alignment: Alignment) -> some View {
        let base = Font.system(size: 11.5, weight: module.isPrimary ? .semibold : .medium)
        return MarqueeText(id: text, restingAlignment: alignment) {
            Text(text)
                .font(module.isClock ? base.monospacedDigit() : base)
                .foregroundStyle(accentOrWhite.opacity(module.isPrimary ? 0.85 : 0.6))
                .lineLimit(1)
        }
    }

    // 封面小图跟歌词之间的间距。

    // 32pt 是"在 44pt 高的歌词行里上下各留 6pt"倒推出来的观感取值,夹在 [16, 32] 之间:
    // 上限避免歌词行万一变高就把封面撑得比歌词本身还抢眼(歌词才是这个产品的主体),
    // 下限保证行高万一变矮,方块也不会缩到看不出是一张封面。
    private static func artworkSide(rowHeight: CGFloat) -> CGFloat {
        max(16, min(32, rowHeight - 12))
    }

    // 歌词行尾端(卡片右下角)那枚专辑封面小图(2026-08-05 新增)。
    //
    // 位置选在这里而不是顶行歌名左边:顶行左耳的可用宽度是 (窗口宽 - 刘海宽 - 20) / 2,
    // 默认 360pt 宽配实测 179pt 刘海只有 80.5pt,放进一枚小图连间距要占掉四分之一以上,
    // 歌名被挤得只剩 50 多 pt——实机看过就是放不下。歌词行是整条 360pt(去掉左右各 16pt
    // padding 还有 328pt)、行高 44pt,同一枚封面在这里能做到 32pt 见方而只占掉歌词
    // 12.8% 的宽度,视觉上也正好落在卡片右下角这个空着的位置上。
    //
    // 稳态下这里就是卡片的右下角;hover 展开时下面会再长出"下一句预览+进度条"那一块,
    // 封面保持钉在歌词行内不动(不跟着卡片底边往下跑),避免鼠标一进一出封面就上下跳。
    //
    // 没有封面数据时不画占位方块、直接连位置一起不占:灵动岛没在播放时是收起态,播放中
    // 绝大多数曲目都拿得到封面(拿不到的是本来没有封面的播客/取图失败这类少数情况),
    // 为这种少数情况长期锁掉一块位置画一个空方块不值得。这不会导致换歌时"封面消失再
    // 出现"式的布局跳动——换歌那一刻旧封面会一直留着直到新封面取回来(见
    // LocalPlaybackSource 的 scheduleArtworkStaleTimeout/artworkRetryDelays,那是
    // 2026-08-05 修"切歌白屏"时定下来的行为),只有"启动后第一首"和"这首歌真的没有封面"
    // 两种情况才会真的发生一次宽度增减。
    //
    // ⚠️ `.scaledToFill()` 之后、`.clipShape` 之前必须显式钉一次 `.frame(width:height:)`
    // ——同 backgroundLayer 上面那一大段注释里踩过三版才找对的坑,不重复展开。
    //
    // 描边 + 投影是给"卡片背景可能是浅色"兜底:磨砂玻璃风格会透出桌面颜色,浅色壁纸下
    // 一张浅色封面直接贴上去边界会糊成一片,一圈极淡的白描边能把方块轮廓钉住。
    /// side:不给就按歌词行那一档(32pt)。耳朵里那枚要小一号,理由见 earArtwork。
    private func artworkThumbnail(_ image: NSImage, side: CGFloat? = nil) -> some View {
        let side = side ?? Self.artworkSide(rowHeight: NotchMetrics.compactRowHeight)
        // 点封面 → 打开歌词窗口(2026-08-19 用户要求)。走 AppActions 统一入口,激活
        // 时序(先 NSApp.activate 再 openWindow)在注册处已处理,跟快捷键/菜单/面板同路。
        return Button {
            AppActions.shared.openLyricsWindow?()
        } label: {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        }
        .buttonStyle(.plain)
        .help(L10n.t("打开歌词窗口"))
    }

    // 用歌词这一行纯文本(不含逐字填色进度)当 MarqueeText 的 id——换到新的一句歌词才
    // 重新测量/重新开始滚动,同一句歌词内部逐字变色的高频刷新(TimelineView 那部分)
    // 不应该打断正在进行的滚动。
    // 有瞬态提示(改歌词偏移/调音量)时,这一行让位给提示条,提示到期再换回歌词。
    // 只盖歌词行、不动卡片高度和顶行控件 —— 提示是"顺带说一句",不该让整块卡片跳一下。
    private var lyricRow: some View {
        // NotchTransientCenter 的订阅下沉在 NotchTransientHost 子视图里 —— 横幅出现/
        // 消失(音量连调时每档一次)只失效歌词行,不再打醒整卡 body。
        NotchTransientHost(tint: accentOrWhite) {
            lyricRowContent
        }
    }

    private var lyricRowContent: some View {
        HStack(spacing: NotchMetrics.artworkLyricSpacing) {
            // 封面贴左还是贴右可配(2026-09-01,`notchLyricRowShowsArtwork` /
            // `notchLyricRowArtworkPosition`,见 NotchPlayback 的注释)——2026-08-10 之前
            // 用户曾要求去掉这个开关、固定显示,这次重开开关必须保住"默认贴右、默认开"
            // 这条既有行为,不能让升级上来的用户发现封面凭空挪位或消失。
            if playback.lyricRowArtworkPosition == .left { lyricRowArtwork }
            // restingAlignment = 「对齐方式」(2026-09-03)。只管**装得下**的短句靠哪边:
            // 溢出的句子 MarqueeText 一律按 .leading 起滚(理由见那个参数的注释,靠右摆等于
            // 一上来就把开头几个字挂在容器外面),所以这一项在长句上天然无效果 —— 跟菜单栏
            // 同名设置是同一条语义,help 文案里说明了。
            //
            // ⚠️ 对齐的参照系是**歌词这一格**,不是整张卡:封面是这个 HStack 的兄弟,它占掉的
            // 那 42pt(32 封面 + 10 间距)不在 MarqueeText 的容器里。所以开着封面选「居中」时,
            // 文字是在"除封面之外的剩余宽度"里居中、相对整卡略偏封面对侧。这是刻意的 ——
            // 要相对整卡居中就得把封面改成 overlay 叠在歌词上,那会直接违反上面那段
            // `.animation(nil, value:)` 治的"封面遮挡歌词"(2026-08-22 用户报的真 bug)。
            MarqueeText(id: playback.compactLine?.plainText ?? "",
                        restingAlignment: playback.lyricsAlignment.swiftUIAlignment,
                        edgeFadeWidth: NotchMetrics.lyricEdgeFadeWidth) {
                lyricContent
            }
            .font(.system(size: 13, weight: .semibold))
            // MarqueeText 内层是 GeometryReader(没有固有尺寸、能吃下任何被提议的宽度),
            // HStack 会先给定尺寸的封面分配它那 32pt,剩下的宽度都留给歌词。这里仍然显式
            // 写一次 maxWidth: .infinity 把"歌词吃掉剩余宽度"这个意图钉死,不依赖
            // GeometryReader 在 stack 里的隐式伸缩行为。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if playback.lyricRowArtworkPosition == .right { lyricRowArtwork }
        }
        .padding(.horizontal, 16)
        // ⚠️ 封面**在场性**的变化必须是瞬时的,不能落进任何补间 —— 这是用户报的
        // 「歌词被封面挡住」里真·遮挡的那一半(2026-08-22,最小复现对照实验坐实)。
        //
        // 机制:封面是这个 HStack 的**条件兄弟**。它从不在场变在场时,SwiftUI 把它当结构性
        // 插入 —— 新插入的视图**一帧就落在终态位置**;而歌词那一侧的 frame(以及跟着 frame
        // 走的 MarqueeText 内部那个 .clipped() 边界)是被**动画平滑收缩**的,要花整条弹簧
        // 才从"没有封面时"的宽度收到"有封面时"的宽度。这段时间里歌词被裁到更靠右的旧边界,
        // 那一截字正好画在已经就位的封面**底下** —— HStack 里靠后的兄弟盖在前面的上面。
        //
        // 独立最小复现(SwiftUI,同构的 HStack + GeometryReader/.clipped 弹性子 + 32pt 定宽
        // 兄弟,弹簧刻意放慢到 3s 便于逐帧抓):封面到位那一帧文字右边界仍停在旧位置(623px),
        // 要 4 帧才收到终态 603px,90 帧里 25 帧文字被压在封面底下;加上这一行 .animation(nil,)
        // 之后同样 90 帧 **0** 帧遮挡,四次插入全部一帧到位。
        //
        // 触发窗口:必须"封面在场性变化"和某条活动动画落进**同一次** SwiftUI 更新 —— 把两者
        // 错开 300ms 的第三版复现同样是 0/90。现实里够得着这个窗口的有两处:
        // NotchWindowRoot 挂在整棵子树上的三条 .animation(cardAnimation, value:)
        // (cardWidth/cardHeight/isCollapsed),以及 NotchTransientHost 自己那条 0.18s。
        // 而封面确实会真的离场再回来:换歌后取图迟迟不来时 LocalPlaybackSource 的
        // scheduleArtworkStaleTimeout 会在 3s 后把 artworkData 清成 nil,重试成功再填回来。
        //
        // 为什么不用别的修法:给封面留永久占位能根治,但那要一直吃掉 42pt 歌词宽度,与
        // artworkThumbnail 上面那段"没有封面就连位置一起不占"的决定直接冲突;给它加
        // .transition 淡入也不行 —— 淡入到不透明的过程中 clip 边界照旧滞后,只是把遮挡
        // 从"实心"变成"半透明"。封面出现/消失本来就是一次宽度**跳变**,补间只会制造不同步。
        //
        // ⚠️ 2026-09-01 加了显示开关之后,这里的 value 必须是"封面这一刻实际占不占位"这个
        // **合成**布尔(开关 && 有数据),不能只看数据——开关关着时数据端的有无变化不该
        // 触发任何布局動作,但如果只 key 数据端,`.animation(nil,)` 会在开关关闭期间对
        // 一个根本不影响布局的信号误判"没变化"而放行别的动画,反而在开关重新打开的
        // 那一刻可能撞上活动动画的同一次更新窗口——虽然实测未必能复现,但没有理由把
        // 判据故意做窄。
        .animation(nil, value: !lyricRowArtworkPresent)
    }

    /// 歌词行末尾(或开头)那枚封面缩略图,2026-08-05 就有、2026-08-10 到 2026-09-01 之间
    /// 固定显示,现在受 `notchLyricRowShowsArtwork` 开关控制。没有封面数据(没曲目/取图
    /// 失败)或开关关着时都不画占位方块,理由见 `artworkThumbnail` 上面那段。
    @ViewBuilder
    private var lyricRowArtwork: some View {
        if playback.lyricRowShowsArtwork, let image = playback.highResArtworkImage ?? playback.artworkImage {
            artworkThumbnail(image)
        }
    }

    /// 上面那枚封面此刻是不是真的占着一个位置——给 `.animation(nil, value:)` 当判据用,
    /// 见那一行的注释。
    private var lyricRowArtworkPresent: Bool {
        playback.lyricRowShowsArtwork && (playback.highResArtworkImage ?? playback.artworkImage) != nil
    }

    private var lyricContent: some View {
        Group {
            if let words = playback.compactLine?.words, !words.isEmpty {
                // 帧率上限见 WordKaraokeGradient.refreshInterval。跟悬浮歌词一样,这里也
                // 保持"TimelineView 包住整行"而不下沉到每个字 —— 外层同样套着
                // .compositingGroup()+.shadow(),理由见 LyricsOverlayView.mainLine 那段。
                //
                // paused 的第二个条件(2026-08-19 性能审计落地,与悬浮窗同款):这一行填完
                // 之后到下一行开始之前(行尾/间奏/曲末)视觉零变化,把表停掉;换行时
                // currentLine 赋值触发 body 重估,表自然恢复。
                TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                        paused: !playback.isPlayingNow || playback.currentLineFillSettled)) { context in
                    // 加上 currentLyricsOffsetMs,理由跟 LyricsOverlayView.mainLine 同一段
                    // 注释——不加的话"当前词判定"和"填色进度"用的时间基准对不上,会出现填到
                    // 一半就卡住的现象。anchor/offset 直读协调器不经代理订阅:这个闭包按帧
                    // 重跑,每帧读到的都是最新值(同悬浮窗的取舍,见 NotchPlayback 注释)。
                    // ?? pausedPositionMs:暂停基准兜底(2026-08-19,四个展示面同款,理由见
                    // LyricsOverlayView.mainLine 同位置注释)。
                    let currentMs = (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: context.date)
                        ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                        + PlaybackCoordinator.shared.currentLyricsOffsetMs
                    // 渐变素材每帧只取一次,纯色词跨帧复用同一实例(2026-08-20 性能审计,
                    // 见 WordKaraokeGradient.Palette 注释)。
                    let palette = WordKaraokeGradient.palette(fg: accentOrWhite)
                    HStack(spacing: 0) {
                        // indices 而不是 Array(enumerated()):后者每帧物化一个新数组纯为
                        // 当 id,Range 零分配,下标当 id 与原 offset 语义一致。
                        ForEach(words.indices, id: \.self) { i in
                            wordText(words[i], atMs: currentMs, palette: palette)
                        }
                    }
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                }
            } else if playback.isCurrentTrackAdBreak {
                // 同 LyricsOverlayView.mainLine 的区分,必须排在"还在搜索中"分支前面,
                // 见 PlaybackCoordinator.isCurrentTrackAdBreak 定义处的注释。
                Text(L10n.t("广告中"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.isCurrentTrackInstrumental {
                // 同 LyricsOverlayView.mainLine 的区分,必须排在"还在搜索中"分支前面,
                // 见 PlaybackCoordinator.isCurrentTrackInstrumental 定义处的注释。
                Text(L10n.t("纯音乐"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.currentTrackHasNoLyrics {
                // 搜完了、确实一句都没有,同 LyricsOverlayView.mainLine 的同名分支——
                // 必须排在下面那个"搜索歌词中…"前面。
                Text(L10n.t("暂无歌词"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.collectorNetworkDown && !playback.hasLyricsContent {
                // 顺序理由同 LyricsOverlayView.mainLine 里那段:必须排在"搜索歌词中…"
                // 之前、"暂无歌词"之后。
                Text(L10n.t("网络连接失败"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else if playback.isPlayingNow && !playback.hasLyricsContent {
                // 同 LyricsOverlayView.mainLine 的区分:currentLine==nil 可能是"还没解析
                // 出这首歌的歌词"(collector 后台搜索中,见 PlaybackCoordinator.hasLyricsContent 注释),
                // 不能跟"这首歌真没歌词/正在间奏"共用同一个♪占位符。
                Text(L10n.t("搜索歌词中…"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else {
                // ♪ 是**间奏**占位符(在播、有歌词、只是这一刻不在任何一句上)—— 那种
                // 情况下它是有意义的,保留。但压根没有曲目时它什么都不代表,留白
                // (2026-08-21 用户要求)。上面那一长串 else-if 已经把广告/纯音乐/无歌词/
                // 断网/搜索中都各自接走了,能落到这里的空态只剩"没有曲目"。
                // compactLine 为 nil 的两种成因这里天然合流:长间奏中段(唱完了、下一句
                // 还早)和"这一刻不在任何一句上",都该是 ♪。
                Text(playback.compactLine?.plainText ?? (isIdleNoTrack ? "" : "♪"))
                    .foregroundStyle(accentOrWhite)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            }
        }
        .lineLimit(1)
    }

    // 逐字时长下限/过渡带宽度跟 LyricsOverlayView 用同一组经验取值(80ms/0.08),这两个
    // 数字本身是"看起来顺眼"的调校结果,不是从歌词数据推导出来的,两处保持一致没有坏处。
    //
    // 2026-08-20 起填色渐变收编到 WordKaraokeGradient 共享实现 —— 这里原来自带一份
    // wordGradient(数学与共享版逐项一致:dim=0.35、过渡带混合 1-t*0.65),收编后三个
    // 整行 TimelineView 展示面共享同一份纯色渐变缓存(见 Palette 注释),不再逐词现造。
    private func wordText(
        _ w: SyncedLyricWord, atMs currentMs: Int, palette: WordKaraokeGradient.Palette
    ) -> some View {
        let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
        let band = WordKaraokeGradient.wordEdgeSoftenBand
        return Text(w.text)
            .foregroundStyle(palette.style(left: fraction - band, right: fraction + band))
    }

    /// 灵动岛里几乎所有前景元素的颜色。
    ///
    /// 复用桌面悬浮歌词那条既有语义:只有「跟随封面取色」开着、且这首歌真的取到了主色时
    /// 才用它,否则维持原来的白 —— 灵动岛贴在刘海下,底色是纯黑或封面模糊图,白色是那里
    /// 最稳的选择,不该在用户没要求时擅自换掉。
    ///
    /// 用的是 notchAccentColor 而不是 artworkAccentColor:后者只保了 HSB 亮度下限
    /// (brightenedAccent),饱和冷色(纯蓝 luma 0.07)能原样通过,贴在灵动岛永远深色的
    /// 背景上区分度差;前者在此之上又保了一道感知亮度下限,专为深色背景调的
    /// (见 LocalPlaybackSource.accentForDarkBackdrop)。提亮在数据层做完,这里直接用。
    ///
    /// 2026-08-16 补完:此前只有歌词正文和进度条填充吃它,顶行歌名、五种状态占位文字、
    /// 下一句预览、进度条底槽、时间文字、播放控制按钮全是写死的白。后果不只是"不够统一"
    /// —— 状态文字跟正常歌词**在同一个 Group 里**,于是同一行会出现"有歌词时跟着封面色、
    /// 一旦变成「暂无歌词」就突然跳回白"的闪动。现在除了封面缩略图的描边(那处是刻意的,
    /// 见 artworkThumbnail 注释:磨砂玻璃风格下要给浅色封面兜一圈可见轮廓),其余都走这里。
    /// 灵动岛音浪的振幅:这一刻有没有字正在唱。
    ///
    /// 输入全部直读 `PlaybackCoordinator.shared`,**不经窄代理订阅** —— 跟同文件里逐字填色
    /// 那个 TimelineView 闭包同一个取舍(见 lyricRow 里 currentMs 那段注释):锚点重建会打醒
    /// 整卡 body,而这里只需要"调用那一刻的快照"。
    ///
    /// 形状由 `VocalEnvelope`(LyrimuseCore,selftest 覆盖)决定:字内稳态 1 + 起音脉冲、字间从 1
    /// 指数泄放到 0.6、没有逐字 1。2026-09-02 之前是三档阶跃,历史与取舍见 VocalEnvelope 头注
    ///(含 05 章那次「按已唱比例插值反而更不像人声」的失败尝试——字内稳态刻意不动)。
    /// 这里只剩"读协调器快照、算位置、交给 Core":XxxxView 里不放数学,是仓库的分层边界。
    private static func vocalAmplitude(at date: Date) -> Double {
        let coordinator = PlaybackCoordinator.shared
        guard let words = coordinator.currentLine?.words, !words.isEmpty else {
            return VocalEnvelope.idleAmplitude
        }
        // 位置口径必须跟逐字填色完全一致(锚点外推 → 暂停冻结值兜底 → 叠加生效偏移),
        // 否则条子跟高亮的字对不上,那比不跟着动更奇怪。
        let posMs = (coordinator.anchor?.extrapolatedPositionMs(now: date)
            ?? coordinator.pausedPositionMs ?? 0)
            + coordinator.currentLyricsOffsetMs
        return VocalEnvelope.amplitude(atMs: posMs, words: words)
    }


    private var accentOrWhite: Color {
        // 组合逻辑(风格是不是「跟随封面」× 动态主色)已下沉进 NotchPlayback.accent 预组合
        // 去重,这里只是个语义化的别名。
        // (2026-08-31 之前那个"×"左边是悬浮歌词的 followsCoverArt 开关,见 accent 的注释。)
        playback.accent
    }

    // hover 展开时多出来的这一块——下一句歌词预览 + 迷你进度条,用来强化"这是个歌词类
    // 产品"而不是退化成通用媒体控制器;进度条属于"有余量就加"的加分项。
    //
    // ⚠️ 曲目信息头部(歌名/歌手/专辑)**不在这里**——2026-09-01 一度是这个 VStack 的第一个
    // 子视图,用户报"信息夹在两行歌词之间",要求挪到歌词行**之上**,现在是 body 里
    // lyricRow 前面一个独立的 `trackInfoHeader` 块(见 body 那段注释)。这里因此永远传
    // `trackInfoHeight: 0`——那部分高度已经在 `expandedTrackInfoHeaderHeight` 那份独立
    // 的 `.frame(height:)` 里算过一次。
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ⚠️ `showsExpandedLyricPreview` 这一条跟下面 .frame(height:) 里留不留这行的高度
            // 是**同一个值**(协议扩展里那份),别在这里换成别的判据。
            if controller.showsExpandedLyricPreview, !nextLineDisplayText.isEmpty {
                Text(nextLineDisplayText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accentOrWhite.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 「对齐方式」也管这一行(2026-09-03)。**不能只改主歌词行**:那样选了
                    // 「居中」之后主行居中、这一行还贴着左边,看起来就是没做完 —— 这个仓库
                    // 正是为"同一个视觉属性漏改一条路径"付过代价的(见 swiftUIAlignment 注释)。
                    //
                    // ⚠️ 用**这一行自己**的 `.frame(maxWidth:.infinity, alignment:)`,而不是
                    // 去改外层 `VStack(alignment:)`:那个 VStack 里还有进度条和播放键,而
                    // 下面那两条 `.padding(.bottom,)`/`.frame(height:)` 的高度算术是跟
                    // `NotchExpandedMetrics` 对账的(注释里记着"两处一个开一个不开必然对不上"),
                    // 动 VStack 的对齐属性等于把这一项的影响面从"一行文字"扩到整块布局。
                    // Text 撑满整行宽之后它自己的 leading 对齐导线就落在容器左边缘,VStack 那
                    // 一侧看到的仍是原来的形状;`.lineLimit(1)` 也保证高度不变。
                    .frame(maxWidth: .infinity,
                           alignment: playback.lyricsAlignment.swiftUIAlignment)
            }

            // 进度条独立成 NotchScrubber 子视图(拖动状态自持 + 30Hz 帧率上限),见其注释。
            NotchScrubber(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                isPlayingNow: playback.isPlayingNow,
                tint: accentOrWhite,
                showsLyricsOffsetControls: playback.showsLyricsOffsetControls,
                trackLyricsOffsetMs: playback.trackLyricsOffsetMs,
                lyricsOffsetStepMs: playback.lyricsOffsetStepMs)

            // 完整三键(2026-08-19 设计评审,从右耳挪进来):岛是 hover 展开的,真正的
            // 点击全发生在展开态 —— 控制就该在展开卡里、进度条下方居中,跟菜单栏面板
            // 卡片同一套设计语言(进度条 + 居中三键),目标也大得多(22pt vs 耳朵里 15pt)。
            //
            // 2026-09-01 加了 `expandedShowsControls` 开关——关掉后这排键不画,理由见
            // `NotchChromeSource.expandedShowsControls` 的注释(不是唯一入口,`NotchEarModule`
            // 本来就有「播放控制」这个选项)。
            if controller.expandedShowsControls {
                HStack(spacing: 34) {
                    controlButton("backward.fill", glyphSize: 11.5, hitSize: 22) {
                        MusicPlaybackController.previousTrack()
                    }
                    controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill",
                                  glyphSize: 14, hitSize: 22) {
                        // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                        PlaybackCoordinator.shared.userTogglePlayPause()
                    }
                    controlButton("forward.fill", glyphSize: 11.5, hitSize: 22) {
                        MusicPlaybackController.nextTrack()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        // 10pt 底边距是 `NotchExpandedMetrics.controlsBlock`(35 = 22 键高 + 10 底边距 +
        // 3pt 余量)的一部分,关掉播放控制键之后这一整块(含底边距)在高度算术里都不占
        // 地方了(见 height(...) 的 hasControls 分支),渲染这侧必须跟着不加,否则算出来的
        // 高度比实际渲染矮 10pt,会把上面的内容顶出去一截、被 `.frame(alignment: .top)`
        // 裁掉底部——两处一个开一个不开,必然对不上。⚠️ 代价:关掉控制键但进度条/下一句
        // 预览还开着时,最后一个元素少了这 10pt 专属边距,只剩它自己那份"间距4"贴底(比如
        // 进度条时间行离底边只剩 4pt,不是 10pt)——比专属边距紧一些,但不会被裁,这是
        // 接受的取舍,不值得为这一种组合另开一条独立的常量。
        .padding(.bottom, controller.expandedShowsControls ? 10 : 0)
        // ⚠️ maxWidth: .infinity 是必须的,不是随手加的保险。
        //
        // 不钉这一下,这一块的宽度就跟着**内容**走。播放时里面有进度条,进度条用
        // GeometryReader 会自己撑满,于是整块占满整行、歌词预览自然贴左;而暂停时进度条
        // 那一段整个不渲染(它挂在 playback.anchor 上,暂停后 anchor 为 nil),VStack 里只
        // 剩一句歌词预览,这一块就缩成那行字那么宽 —— 再被外层 VStack 默认的**居中**
        // 对齐推到正中间。表现就是"暂停时下一句歌词跑到中间、播放时又靠左"
        // (2026-08-17 用户报)。撑满 + topLeading 之后,两种状态下它都在同一个位置。
        // (分两个 .frame:maxWidth 走的是弹性那个重载,height 走固定尺寸那个,
        // 混在一次调用里编译不过。)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 高度跟 NotchWindowRoot.cardHeight **走同一个函数、同一组入参**(都读 controller
        // 上那两个曲目级标志)—— 两处各自判断的话必然漂,而漂的表现是卡片和内容差一截:
        // 要么底部多一条空隙,要么最下面那排三键被裁掉。
        .frame(height: NotchMetrics.expandedExtraHeight(
            hasLyricPreview: controller.showsExpandedLyricPreview,
            hasScrubber: controller.expandedShowsScrubber,
            hasControls: controller.expandedShowsControls,
            trackInfoHeight: 0), alignment: .top)
    }

    /// 曲目信息头部:封面 + 歌名/歌手/专辑,四项独立开关(2026-09-01)。解决的缺口:两只
    /// 耳朵都配成非文本模块(比如「剩余时长」)时,hover 展开也看不出这是哪首歌。
    ///
    /// ⚠️ **封面落点反复过**——最初设计里就带一枚,用户看过效果后指出"跟歌词行末尾已有的
    /// 那枚封面重复了",要求并回那一枚(`lyricRowContent` 里的 `artworkThumbnail`,受
    /// `notchLyricRowShowsArtwork`/`notchLyricRowArtworkPosition` 控制,走 `NotchPlayback`
    /// 镜像,不在这个协议里);过了几轮之后用户又要求"在展开态里面多增加一个显示封面",
    /// 重新给头部配上**自己**的一枚(`expandedTrackInfoShowsArtwork`,这个协议里),这次
    /// 没有位置四选一——固定贴文字块左边,用户参照图就是"封面居左+文字居右"。两枚封面因此
    /// 是两个独立开关,理论上能同时开(一枚在歌词行末尾、一枚在头部左边),不算矛盾。
    @ViewBuilder
    private var trackInfoHeader: some View {
        if controller.showsExpandedTrackInfo {
            HStack(spacing: 8) {
                trackInfoArtwork
                trackInfoTextStack
            }
                // 左内边距**跟下面歌词行的首字对齐**,不是跟上面 topRow 对齐——2026-09-01
                // 同一天先按 topRow 的 NotchMetrics.cardHorizontalPadding(10pt)对齐过一版,
                // 用户看完又改口"和下面的歌词首字左对齐更好看",所以这里改成跟
                // lyricRowContent/expandedContent 同一个 16pt(那两处也是这个字面量,不是
                // 巧合——都在描述"歌词那一列文字的左边界"这同一件事)。这会导致跟 topRow
                // 不对齐(10 vs 16,差 6pt),这是用户明确的取舍,不是遗漏。
                .padding(.horizontal, 16)
                // 顶部间距(2026-09-01,同一天第二轮):头部紧挨在 topRow 下面,原来零间距,
                // 用户报"标题首行贴到上面边了"。这份间距已经在
                // `expandedTrackInfoHeaderHeight`/`NotchExpandedMetrics.height` 的高度算术
                // 里算过(`trackInfoSpacing * 2`,一份在上一份在下),这里只是真的把"上面
                // 那份"实现成看得见的留白——`.frame(alignment: .top)` 会把这段 padding 之后
                // 的内容继续钉在分配到的那块高度顶部,不会把它推到底部去。
                .padding(.top, NotchMetrics.trackInfoTopSpacing)
        }
    }

    /// 头部里的封面缩略图,复用 `artworkThumbnail`(点击打开歌词窗口的行为跟着一起继承)。
    /// 没有封面数据(没曲目/取图失败)时不画占位方块——跟 `lyricRowContent` 末尾那枚同一个
    /// 惯例(`@ViewBuilder` 的 `if let` 不满足时直接产出零视图,HStack 自然收缩)。
    @ViewBuilder
    private var trackInfoArtwork: some View {
        if controller.expandedTrackInfoShowsArtwork,
           let image = playback.highResArtworkImage ?? playback.artworkImage {
            artworkThumbnail(image, side: NotchMetrics.trackInfoArtworkSide)
        }
    }

    /// 头部里的歌名/歌手/专辑三行,复用 `metadataText`——跟耳朵里那三个文本模块走同一份
    /// 广告插播/空曲目规则(广告中歌名写「广告中」、歌手专辑留空),不重新定义一套。
    ///
    /// `.frame(maxWidth: .infinity, alignment: .leading)` 是必须的:没有它,`.lineLimit(1)`
    /// 的 `Text` 在 VStack 里只会按内容天然宽度收缩,压根不会触发截断——这一块需要一个
    /// 明确的宽度提议才截得断长歌名/长专辑名。
    private var trackInfoTextStack: some View {
        VStack(alignment: .leading, spacing: NotchMetrics.trackInfoLineSpacing) {
            if controller.expandedTrackInfoShowsTitle {
                Text(metadataText(.title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.9))
            }
            if controller.expandedTrackInfoShowsArtist {
                Text(metadataText(.artist))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentOrWhite.opacity(0.6))
            }
            if controller.expandedTrackInfoShowsAlbum {
                Text(metadataText(.album))
                    .font(.system(size: 9))
                    .foregroundStyle(accentOrWhite.opacity(0.4))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nextLineDisplayText: String {
        playback.nextLineText ?? ""
    }

    // ⚠️ 必须用 checkForCurrentPlayerSafely(异步),不能用同步版本——理由跟
    // LyricsOverlayView.swift 同名方法的注释一致:同步版本在还没问过时会直接触达有据
    // 可查、可能永久挂起主线程的系统 API。权限不够时用 NSSound.beep() 给一个"没有
    // 生效"的听觉反馈(2026-08-02 补上,跟另外两处播放控制入口保持一致),不静默无声。
    /// glyphSize/hitSize 显式给时优先(展开卡里的三键要比耳朵里的大一号,2026-08-19),
    /// 不给就沿用 primary 的两档旧尺寸(耳朵那一个)。
    private func controlButton(_ systemName: String, primary: Bool = false,
                               glyphSize: CGFloat? = nil, hitSize: CGFloat? = nil,
                               action: @escaping () -> Void) -> some View {
        let glyph = glyphSize ?? (primary ? 11 : 9.5)
        let hit = hitSize ?? (primary ? 18 : 15)
        return Button {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                action()
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(accentOrWhite)
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


/// 歌词行上「瞬态横幅盖歌词」这层壳,单独订阅 NotchTransientCenter(2026-08-19 性能
/// 审计落地):banner 只被这一行消费,原来订阅挂在 NotchLyricsView 根上,音量连调时每档
/// 一次的 @Published 变化会打醒整卡 body(含封面背景/跑马灯/音浪)。下沉之后横幅出现/
/// 消失只失效这一行。
private struct NotchTransientHost<Fallback: View>: View {
    @ObservedObject private var transients = NotchTransientCenter.shared
    let tint: Color
    @ViewBuilder let fallback: () -> Fallback

    init(tint: Color, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.tint = tint
        self.fallback = fallback
    }

    var body: some View {
        ZStack {
            if let banner = transients.banner {
                NotchTransientRow(banner: banner, tint: tint)
                    .transition(.opacity)
            } else {
                fallback()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: transients.banner)
    }
}

/// 展开卡里的进度条 + 时间行,独立子视图(2026-08-19 性能审计落地,两件事):
/// ① 拖动的三个交互状态(@GestureState/测宽/悬停)在这里自持 —— 原来挂在
///    NotchLyricsView 根上,拖动时每个指针事件(60~120Hz)都整卡重估,实际要变的只有
///    这十来个视图;
/// ② TimelineView 补上 minimumInterval —— 原来是全仓唯一没封帧率上限的 .animation
///    时刻表(正是 2026-08-15 那次「只给窗口加了上限,这里和灵动岛漏了」同款失误的
///    残留),hover 展开+播放中按显示器刷新率(ProMotion 120Hz)驱动一条每秒只走
///    ~1.8pt、时间文字每秒才变一次的进度条。30Hz 与其余三处逐字填色同一口径。
///
/// 两种数据来源,跟「歌词窗口」的 progressSection 同一套三态口径:
///  - **播放中**:anchor 在,按帧从锚点外推;
///  - **暂停**:anchor 被清成 nil(见 PlaybackCoordinator.pausedPositionMs 的注释),
///    改用冻结位置 + 曲目时长照常显示,无 TimelineView。
/// ⚠️ 暂停这一档是 2026-08-17 补的:在那之前一暂停整条进度条凭空消失,顺带让展开区
/// 失去撑宽度的内容(「暂停时下一句歌词跑到中间」的根源,见 expandedContent 末尾注释)。
private struct NotchScrubber: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let isPlayingNow: Bool
    let tint: Color
    /// 「歌词时间轴微调」(2026-09-01,菜单栏面板同款功能的灵动岛入口)要不要塞进时间行
    /// 中间——三项都是纯渲染参数,理由见 `NotchPlayback.showsLyricsOffsetControls` 上面
    /// 那条注释(不影响卡片几何,不走 `NotchChromeSource`)。
    let showsLyricsOffsetControls: Bool
    let trackLyricsOffsetMs: Int
    let lyricsOffsetStepMs: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 正在拖进度条时手指所在的比例(0~1);没在拖就是 nil。
    // 用 @GestureState:手势被取消时(拖动中这块条件分支被摘掉)自动复位,@State 会永久卡住。
    @GestureState private var scrubbingFraction: Double?
    // 进度条那一块的实际宽度,拖拽换算比例用。
    @State private var scrubWidth: CGFloat = 0
    /// 光标是否停在进度条那一小条上(只影响它自己的粗细,跟卡片展开无关)。
    @State private var hoveringScrubber = false

    var body: some View {
        if let anchor, anchor.durationMs > 0 {
            TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                    paused: !isPlayingNow)) { context in
                // 拖动期间显示手指按住的位置,而不是外推出的真实位置——否则进度条会在
                // 手指底下被 TimelineView 每帧拉回去。松手才真的发 seek。
                let currentMs = scrubbingFraction.map { Int($0 * Double(anchor.durationMs)) }
                    ?? anchor.extrapolatedPositionMs(now: context.date)
                scrubberAndTimes(currentMs: currentMs, durationMs: anchor.durationMs)
            }
        } else if let paused = pausedPositionMs,
                  let duration = durationMs, duration > 0 {
            // 暂停态不需要 TimelineView —— 位置是冻住的,没有随时间推进这回事。
            let currentMs = scrubbingFraction.map { Int($0 * Double(duration)) } ?? paused
            scrubberAndTimes(currentMs: currentMs, durationMs: duration)
        }
    }

    /// 进度条本体 + 下面那行时间。播放态和暂停态共用,只是 currentMs/durationMs 的来源不同。
    private func scrubberAndTimes(currentMs: Int, durationMs: Int) -> some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let fraction = min(1, max(0, Double(currentMs) / Double(durationMs)))
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.18))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: proxy.size.width * fraction)
                }
                // 变粗只发生在下面那个**恒定高度的槽**里(垂直居中),布局上不占多一分 ——
                // 原来 .frame(height: scrubberHeight) 直接参与布局,悬停 3→5 那 2pt 会把
                // 时间行和三键整块往下推一下(2026-08-19 用户报"移到进度条上按钮会位移")。
                .frame(height: scrubberHeight)
                .frame(maxHeight: .infinity)
                // reduceMotion 下仍然变粗(那是功能反馈,不是装饰),只是不补间。
                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7),
                           value: scrubberHeight)
            }
            // 布局槽恒为最粗形态(拖动中的 6pt)的高度,悬停/拖动只改槽内的条,不动邻居。
            .frame(height: 6)
            // 命中区**只覆盖进度条这一行**,不含下面的时间行——原来挂在整块上,
            // 点右侧"剩余时间"文字就等于 seek 到 ~94%(把这首歌跳过去)。
            // 上下各撑 8pt 让 3pt 的条好按,再用等量负 padding 抵消布局:
            // 展开区高度是写死的 expandedExtraHeight(alignment .top),
            // 长高一点就把时间行裁掉。
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -8)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { scrubWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in scrubWidth = w }
                }
            )
            .onHover { hoveringScrubber = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($scrubbingFraction) { value, state, _ in
                        guard scrubWidth > 0 else { return }
                        // state 只有**这次手势的第一帧**才是 nil(@GestureState
                        // 的初始值),拿它当"刚按下"的边沿信号给一次触觉 ——
                        // 放 onChanged 里会每帧都震。
                        if state == nil {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment, performanceTime: .now)
                        }
                        state = min(1, max(0, value.location.x / scrubWidth))
                    }
                    .onEnded { value in
                        guard scrubWidth > 0 else { return }
                        let f = min(1, max(0, value.location.x / scrubWidth))
                        PlaybackCoordinator.shared.seek(toMs: Int(f * Double(durationMs)))
                    }
            )
            HStack {
                Text(Self.timeString(ms: currentMs))
                Spacer()
                // 「歌词时间轴微调」(2026-09-01):中间这一截以前一直空着(两个时间数字
                // 中间的 Spacer),塞进跟菜单栏面板同一份功能的灵动岛入口——见
                // `AppSettings.notchExpandedShowsLyricsOffset` 上面那条⚠️,两个 Spacer
                // 各占一半剩余空间,把中间那截天然居中,关掉开关时跟改动前逐字一样
                // (只剩一个 Spacer)。
                if showsLyricsOffsetControls {
                    lyricsOffsetControls
                    Spacer()
                }
                Text("-" + Self.timeString(ms: max(0, durationMs - currentMs)))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint.opacity(0.4))
            .monospacedDigit()
        }
    }

    // MARK: - 歌词时间轴微调(2026-09-01,菜单栏面板 `MenuBarPanel.offsetControls` 同款功能)

    /// 「− 歌词±0.5s +」。⚠️ 按钮尺寸刻意收窄到跟这一行本身的高度(9pt 字号撑出来的行高,
    /// `NotchExpandedMetrics.scrubberBlock` 里"时间行 11"那个常量)齐平,**不能**照抄菜单栏
    /// 面板那份 16×14——那边的行高本来就是被 14pt 的按钮撑出来的(见
    /// `MenuBarPanel.offsetButton` 的注释,那个面板没有这份高度预算的约束);这里按钮比
    /// 这一行本身的高度高,会把整个时间行顶出 `expandedContent` 预留的高度,被
    /// `.frame(alignment: .top)` 从底部裁掉一截。这也是这个开关全程不进
    /// `NotchExpandedMetrics`/`NotchChromeSource` 那套几何链路的前提——按钮必须真的不
    /// 长高这一行,不是"大概率不会",尺寸因此比菜单栏那份小一档。
    private var lyricsOffsetControls: some View {
        HStack(spacing: 3) {
            lyricsOffsetButton("minus", help: nudgeHelp(L10n.t("延后"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: -lyricsOffsetStepMs)
            }
            Text(offsetText)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard trackLyricsOffsetMs != 0 else { return }
                    PlaybackCoordinator.shared.resetLyricsOffset()
                }
                .modifier(OptionalHelp(text: trackLyricsOffsetMs != 0 ? L10n.t("点击归零") : nil))
            lyricsOffsetButton("plus", help: nudgeHelp(L10n.t("提前"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: lyricsOffsetStepMs)
            }
        }
    }

    /// 「歌词 +0.5s」/「歌词 0.0s」——值是**这首歌**那一部分,跟菜单栏面板 `offsetText`
    /// 同一个理由(不含设置里的全局基准,归零操作对应的是这个数字清零)。
    private var offsetText: String {
        "\(L10n.t("歌词")) \(AppSettings.signedSeconds(ms: trackLyricsOffsetMs))s"
    }

    private func nudgeHelp(_ verb: String) -> String {
        "\(verb) \(AppSettings.formattedSeconds(ms: lyricsOffsetStepMs))\(L10n.t("秒"))"
    }

    private func lyricsOffsetButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .semibold))
                .frame(width: 10, height: 11)
        }
        .buttonStyle(.plain)
        // 命中区上下左右各扩 5pt,跟上面进度条命中区同一个技巧:padding 撑开
        // contentShape,再用等量负 padding 抵消对布局尺寸的影响——按钮本身画多小,
        // 手指/鼠标能按到的范围都不因此缩水,但不会把这一行的实际高度撑高。
        .padding(5)
        .contentShape(Rectangle())
        .padding(-5)
        .modifier(OptionalHelp(text: help))
    }

    /// 进度条轨道的粗细:悬停变粗一点、真按住再粗一点。
    ///
    /// 这条轨道稳态只有 3pt,手指压上去几乎看不见自己有没有抓住 —— 它已经为此配了一圈
    /// 上下各 8pt 的隐形命中区(见 gesture 那段注释),但那是"能不能按到"的问题,这里补的是
    /// "有没有按到"的**反馈**。
    ///
    /// ⚠️ 幅度必须克制。参考实现是 5→9pt(+4),但那是在一个高得多的面板里;灵动岛展开区
    /// 总共只有 expandedExtraHeight,进度条 + 3pt 间距 + 时间行已经占掉大半,
    /// 再长 4pt 会把时间行往下挤出可见区。3→5→6 是量过余量之后的取值。
    private var scrubberHeight: CGFloat {
        if scrubbingFraction != nil { return 6 }
        return hoveringScrubber ? 5 : 3
    }

    private static func timeString(ms: Int) -> String { NotchTimeFormat.mmss(ms: ms) }
}

/// `m:ss` —— 迷你进度条底下那行时间和「已播/剩余时长」两个耳朵模块共用一份。
///
/// 抽出来是因为 2026-08-31 加耳朵模块时差点在 NotchLyricsView 里再写一份:同一个卡片上两处
/// 时间格式不一样(一处补前导零、一处不补)是那种没人会当 bug 报、但看着就是不对劲的东西。
enum NotchTimeFormat {
    /// 拿不到锚点时那条秒表的兜底起点。
    /// ⚠️ 放在这里而不是 NotchLyricsView 里:那是个泛型类型(`<Chrome: NotchChromeSource>`),
    /// Swift 不允许泛型类型有 static 存储属性。
    static let clockEpoch = Date(timeIntervalSince1970: 0)

    /// 时间类耳朵模块那条秒表的时刻表 —— **相位对齐到"曲目位置正好走到整秒"的那个墙钟时刻**,
    /// 步长按倍速取 `1/rate`。
    ///
    /// 为什么不能直接钉在墙钟整秒上(`from: clockEpoch`):曲目位置 p(t) = progressMs + 走过的时间,
    /// 它的整秒边界跟墙钟整秒**没有任何关系**,两者的相位差 φ 由 seek/换歌那一刻的锚点定死、
    /// 在这条锚点的整个生命周期里是**常量**。于是 hover 展开时,耳朵可能**整首歌**都比正下方那条
    /// 迷你进度条(30Hz,同一份 `mmss`)慢 1 秒 —— 耳朵 1:23、进度条 1:24 长期并排杵着,
    /// 而不是偶尔闪一下。按锚点均匀分布,期望约一半时间在错位。
    ///
    /// ⚠️ 只读 `fetchedAt`/`progressMs`/`rate` 这些**低频**字段,不碰 `Date()` —— 相位在 body
    /// 反复重估之间因此是稳定的,不会退回"每次重绘都把时钟相位重挪一次"那个问题。
    static func clockSchedule(for anchor: ProgressAnchor) -> PeriodicTimelineSchedule {
        guard anchor.rate > 0 else { return .periodic(from: clockEpoch, by: 1) }
        let ref = anchor.fetchedAt
        let posAtRef = Double(anchor.extrapolatedPositionMs(now: ref))
        let msToBoundary = 1000 - posAtRef.truncatingRemainder(dividingBy: 1000)
        return .periodic(from: ref.addingTimeInterval(msToBoundary / 1000 / anchor.rate),
                         by: 1 / anchor.rate)
    }

    static func mmss(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// 顶部两个角是直角、只有底部两个角带圆角的卡片形状——SwiftUI 的 RoundedRectangle
// 只支持四角统一圆角,`UnevenRoundedRectangle` 又要 macOS 26 起才有(这个项目部署
// 目标是 14),手写一个 Shape 直接按四段直线+两段圆弧画出这个轮廓,不依赖新 API。
// 不加 private:「外观」页的灵动岛预览(NotchPreviewBar)要用同一个形状画预览卡,
// 复制一份轮廓代码只会让两边慢慢漂开。
struct NotchHangingShape: Shape {
    var bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(bottomCornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

