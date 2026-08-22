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
    @Published private(set) var isPlayingNow = false
    @Published private(set) var currentLine: SyncedLyricLine?
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
    /// 灵动岛几乎所有前景元素的颜色 —— 语义同原来的 accentOrWhite 计算属性(只有
    /// 「跟随封面取色」开着且这首歌真的取到了主色时用它,否则白;用 notchAccentColor
    /// 而非 artworkAccentColor 的理由见 PlaybackCoordinator.notchAccentColor 注释),
    /// 在这里预组合成单个去重值,两个输入任何一个变了才发一次。
    @Published private(set) var accent: Color = .white
    // ---- 来自 AppSettings(灵动岛只读这一项;followsCoverArt 已折进上面的 accent) ----
    @Published private(set) var notchCardStyle: NotchCardStyle = .coverArt
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$title.removeDuplicates().sink { [weak self] in self?.title = $0 },
            p.$artist.removeDuplicates().sink { [weak self] in self?.artist = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$currentLine.removeDuplicates().sink { [weak self] in self?.currentLine = $0 },
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
            Publishers.CombineLatest(p.$notchAccentColor, s.$followsCoverArt)
                .map { accent, follows in follows ? (accent ?? .white) : .white }
                .removeDuplicates()
                .sink { [weak self] in self?.accent = $0 },
            s.$notchCardStyle.removeDuplicates().sink { [weak self] in self?.notchCardStyle = $0 },
        ]
    }
}

// 用 AnyShapeStyle 抹掉三种截然不同的 ShapeStyle 具体类型(纯色/材质/渐变),让
// NotchHangingShape.fill(_:) 能用同一个属性统一接收,不需要写三份 if/switch 分支
// 各自调用不同重载的 .fill()。
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
//   的内容会被真实挡掉,这一行中间让出 notchWidth 宽度的空当什么都不放。左耳放歌名,
//   右耳放 3 个播放控制按钮。
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
    static var expandedExtraHeightMax: CGFloat { NotchExpandedMetrics.maxHeight }

    static func expandedExtraHeight(hasLyricPreview: Bool, hasScrubber: Bool) -> CGFloat {
        NotchExpandedMetrics.height(hasLyricPreview: hasLyricPreview, hasScrubber: hasScrubber)
    }

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
    func setExpanded(_ expanded: Bool)
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
            let earWidth = max(0, (proxy.size.width - controller.notchWidth - 20) / 2)
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
                    // 收起(没在播放)= iPhone 灵动岛式极简(左耳音浪、右耳封面,2026-08-19
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
                        lyricRow
                            .frame(height: NotchMetrics.compactRowHeight)
                        if controller.isExpanded {
                            expandedContent
                        }
                    }
                }
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
                    .overlay(Color.black.opacity(0.45))
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
                if let image = playback.artworkImage {
                    let side = max(16, controller.contentTopInset - 10)
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

            Color.clear
                .frame(width: controller.notchWidth)

            HStack {
                EqualizerBars(color: accentOrWhite, isPlaying: playback.isPlayingNow,
                              amplitude: Self.vocalAmplitude(at:))
            }
            .frame(width: earWidth)
        }
        .padding(.horizontal, 10)
    }

    /// 压根没有曲目。读 controller 那一份而不是自己再从 playback 算一遍 —— 卡片高度
    /// (NotchWindowRoot.cardHeight)也要用同一个判据决定歌词行占不占 44pt,两处各算一遍
    /// 必然漂,而漂的表现是"行不见了但高度还留着"或反过来把行裁掉半截。
    /// 跟菜单栏面板的同名属性是同一套语义(MenuBarPanel.isIdleNoTrack)。
    private var isIdleNoTrack: Bool { !controller.hasTrack }

    private func topRow(earWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 左耳:歌名。播放指示条(音浪)原在歌名左边,2026-08-19 用户拍板挪到右耳
            // 歌手侧、贴外缘 —— 跟收起态「封面左/音浪右」的 iPhone 灵动岛构图对齐,
            // 音浪在两种形态下都住右耳,收放切换时它不横跳。
            HStack(spacing: 5) {
                // 广告插播:歌名位直接写「广告中」,不展示广告物料的名字(用户拍板
                // 2026-08-19)。MarqueeText 的 id 也用显示串——切进/切出广告要重置跑马灯。
                let displayTitle = playback.isCurrentTrackAdBreak ? L10n.t("广告中") : playback.title
                MarqueeText(id: displayTitle) {
                    // 压根没有曲目时**留白**,不摆 ♪(2026-08-21 用户要求"那个无意义的音符
                    // 不要占位置")。这里的 ♪ 其实只在"没有曲目"这一种情况下才到得了 ——
                    // 有曲目就有歌名,广告插播也被上面那行换成了「广告中」—— 所以它从来
                    // 没有"代表一首歌"的语义,纯粹是一个占位。
                    Text(isIdleNoTrack ? "" : (displayTitle.isEmpty ? "♪" : displayTitle))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(accentOrWhite.opacity(0.85))
                }
            }
            // 内缩必须在 .frame(width:) **之前** —— 之后加等于把耳朵整体变宽 6pt,
            // 三段就不再严丝合缝铺满,背景形状/刘海空当会跟着错位。
            .padding(.trailing, NotchMetrics.earNotchInset)
            .frame(width: earWidth)

            // 刘海本身的空当——物理硬件不发光区域,什么都不放。
            Color.clear
                .frame(width: controller.notchWidth)

            // 右耳:歌手名 + 音浪(2026-08-19 设计评审的终形,用户逐步拍板):控制键全部
            // 退场 —— 岛是 hover 展开的,光标到达耳朵之前岛已经展开,完整三键就在展开卡
            // 的进度条下方(见 expandedContent),耳朵里再留一枚播放键是重复目标。顶行
            // 回归纯信息:左歌名、右歌手,音浪贴外缘(跟收起态同侧,收放切换不横跳;
            // 它固定宽度,放最右不会被滚动的歌手名推着动)。广告时左耳已写「广告中」,
            // 这里只剩音浪。
            //
            // 歌手名 2026-08-20 从"截尾成省略号"改成跑马灯(用户要求)。原来刻意不滚,
            // 理由是"两只耳朵各滚各的太闹" —— 现在按用户口径改:名字看不全比两处同时
            // 动更烦,而且只有真的装不下才会滚(MarqueeText 自己测),绝大多数歌手名短、
            // 一动不动。
            //
            // ⚠️ 不能只是把 Text 套进 MarqueeText 就完事:它内层是 GeometryReader、
            // 会吃满可用宽度,原来靠 Spacer 顶到右边的短名字会整块跑到左耳侧、跟音浪
            // 之间空出一大段。靠右由 restingAlignment 负责(见 MarqueeText),Spacer 撤掉
            // —— 留着它会把跑马灯挤成 0 宽,长名字反而一个字都看不见。
            HStack(spacing: 5) {
                let displayArtist = playback.isCurrentTrackAdBreak ? "" : playback.artist
                MarqueeText(id: displayArtist, restingAlignment: .trailing) {
                    Text(displayArtist)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(accentOrWhite.opacity(0.6))
                        .lineLimit(1)
                }
                EqualizerBars(color: accentOrWhite, isPlaying: playback.isPlayingNow,
                              amplitude: Self.vocalAmplitude(at:))
            }
            .padding(.leading, NotchMetrics.earNotchInset) // 理由同左耳,见 earNotchInset
            .frame(width: earWidth)
        }
        .padding(.horizontal, 10)
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
    private func artworkThumbnail(_ image: NSImage) -> some View {
        let side = Self.artworkSide(rowHeight: NotchMetrics.compactRowHeight)
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
            MarqueeText(id: playback.currentLine?.plainText ?? "",
                        edgeFadeWidth: NotchMetrics.lyricEdgeFadeWidth) {
                lyricContent
            }
            .font(.system(size: 13, weight: .semibold))
            // MarqueeText 内层是 GeometryReader(没有固有尺寸、能吃下任何被提议的宽度),
            // HStack 会先给定尺寸的封面分配它那 32pt,剩下的宽度都留给歌词。这里仍然显式
            // 写一次 maxWidth: .infinity 把"歌词吃掉剩余宽度"这个意图钉死,不依赖
            // GeometryReader 在 stack 里的隐式伸缩行为。
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 封面小图在歌词右边(卡片右下角),没有封面数据时整个摘掉、把宽度全部还给
            // 歌词,理由见 artworkThumbnail 上面的注释。
            // 2026-08-10 删掉了「显示专辑封面」开关(用户要求),固定按原来的默认值走:
            // 有封面就显示。
            // 高清替代优先,理由同 backgroundLayer:网易云的系统封面只有 100×100,云盘
            // 未匹配歌还是灰底音符占位图。
            if let image = playback.highResArtworkImage ?? playback.artworkImage {
                artworkThumbnail(image)
            }
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
        .animation(nil, value: (playback.highResArtworkImage ?? playback.artworkImage) == nil)
    }

    private var lyricContent: some View {
        Group {
            if let words = playback.currentLine?.words, !words.isEmpty {
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
                Text(playback.currentLine?.plainText ?? (isIdleNoTrack ? "" : "♪"))
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
    /// 三档,刻意不做连续包络:
    ///   - 正落在某个字的发声区间里 → 满幅;
    ///   - 有逐字数据但此刻是字与字之间的空档(换气/行尾)→ `gapAmplitude`,明显收一下;
    ///   - 压根没有逐字数据(整行模式/纯音乐/还没解析出来)→ `idleAmplitude`,退回加这个
    ///     机制之前的观感。
    /// 做成连续包络(按字的已唱比例插值)试过更"高级",但 tick 只有 3.6Hz,插出来的中间值
    /// 在两拍之间根本体现不出来,只是让每一跳的高度更平均、反而**更不像**跟着人声。
    private static func vocalAmplitude(at date: Date) -> Double {
        let coordinator = PlaybackCoordinator.shared
        guard let words = coordinator.currentLine?.words, !words.isEmpty else {
            return idleAmplitude
        }
        // 位置口径必须跟逐字填色完全一致(锚点外推 → 暂停冻结值兜底 → 叠加生效偏移),
        // 否则条子跟高亮的字对不上,那比不跟着动更奇怪。
        let posMs = (coordinator.anchor?.extrapolatedPositionMs(now: date)
            ?? coordinator.pausedPositionMs ?? 0)
            + coordinator.currentLyricsOffsetMs
        for word in words where posMs >= word.startMs && posMs < word.startMs + word.durationMs {
            return 1
        }
        return gapAmplitude
    }

    /// 字与字之间的空档。收到六成:听感上换气确实是"弱"而不是"停"。
    /// ⚠️ 计算属性而不是 `static let` —— `NotchLyricsView` 是泛型类型(chrome 源可替换,
    /// 见类型定义),Swift 不允许泛型类型有 static 存储属性。
    private static var gapAmplitude: Double { 0.6 }
    /// 没有逐字数据时的默认幅度 —— 取 1 是刻意的:那正是加这个机制之前的行为,整行模式
    /// 和纯音乐不该因为"拿不到字"就显得比有词的时候更蔫。
    private static var idleAmplitude: Double { 1 }


    private var accentOrWhite: Color {
        // 组合逻辑(「跟随封面」开关 × 动态主色)已下沉进 NotchPlayback.accent 预组合去重,
        // 这里只是个语义化的别名,语义与历史版本逐字一致。
        playback.accent
    }

    // hover 展开时多出来的这一块——下一句歌词预览 + 迷你进度条,用来强化"这是个歌词类
    // 产品"而不是退化成通用媒体控制器;进度条属于"有余量就加"的加分项。
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !nextLineDisplayText.isEmpty {
                Text(nextLineDisplayText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accentOrWhite.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // 进度条独立成 NotchScrubber 子视图(拖动状态自持 + 30Hz 帧率上限),见其注释。
            NotchScrubber(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                isPlayingNow: playback.isPlayingNow,
                tint: accentOrWhite)

            // 完整三键(2026-08-19 设计评审,从右耳挪进来):岛是 hover 展开的,真正的
            // 点击全发生在展开态 —— 控制就该在展开卡里、进度条下方居中,跟菜单栏面板
            // 卡片同一套设计语言(进度条 + 居中三键),目标也大得多(22pt vs 耳朵里 15pt)。
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
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
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
            hasLyricPreview: controller.expandedShowsLyricPreview,
            hasScrubber: controller.expandedShowsScrubber), alignment: .top)
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
                Text("-" + Self.timeString(ms: max(0, durationMs - currentMs)))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint.opacity(0.4))
            .monospacedDigit()
        }
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

    private static func timeString(ms: Int) -> String {
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
