import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

// 灵动岛卡片的内容视图。顶行(高 = contentTopInset)中间给物理刘海让出 notchWidth 宽的空当,空当里只有一枚截屏 / 录屏时才露面的
// 品牌胶囊(notchSeam),两侧是两只可配的耳朵;顶行以下是歌词行,hover 展开时再长出曲目信息头部、下一句 / 多行歌词、进度条和
// 播放控制(cardBodyLayer)。卡片只在底部两角做圆角、顶边贴着屏幕顶(NotchHangingShape)。背景按「风格」设置(NotchCardStyle),
// 前景色跟着封面主色(NotchPlayback.accent)。
struct NotchLyricsView<Chrome: NotchChromeSource>: View {
    @ObservedObject var controller: Chrome

    /// 「发现新播放器」提示的状态源。**这里不订阅**(不是 @ObservedObject),只往下传给两个宿主
    /// 子视图(`NotchIdleEarIconHost` / `NotchIdlePanelHost`)各自订阅 —— 同 NotchTransientCenter 那条纪律,
    /// 提示挂上 / 撤掉只失效那一块。默认是惰性替身(编辑台预览永远看不到提示),真窗口传 `.shared`。
    var prompt: NotchUnknownPlayerPrompt = .inert

    /// 把歌词行的宽度报给按宽度断句(LineLayoutWidthReporter)。只有真窗口传 true:编辑台里跑的也是这个视图,
    /// 它的宽度跟真窗口不一样,报上去会把真窗口的断句覆盖掉。
    var reportsLineLayout = false

    /// 广告态时向 `YouTubeMusicAdSkipCenter` 登记要门槛结果。只有真窗口传 true:编辑台预览也会进广告态,但它一登记,
    /// 设置页开着时就会跟着真广告对用户的浏览器发 AppleScript —— 预览不产生副作用。
    var drivesAdSkipGate = false
    // 不整对象订阅 PlaybackCoordinator/AppSettings —— 见 NotchPlayback 的注释。
    // NotchTransientCenter 也不在这里订阅:banner 只被歌词行消费,订阅下沉到
    // NotchTransientHost 子视图,横幅出现/消失只失效那一行,不打醒整卡。
    // 进度条拖动的三个交互状态(@GestureState/宽度/悬停)同理下沉进 NotchScrubber,挂在这里的话拖动时每个指针事件都整卡重估。
    @StateObject var playback = NotchPlayback()
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// 出场动画期间内容的透明度(NotchWindowRoot 在那 0.3s 里改,默认 1)。只作用于内容 VStack,
    /// 背景层不受影响 —— 先看到卡片形状从刘海长出来、再看到字,见 NotchRevealShape 头注。
    @Environment(\.notchRevealContentOpacity) private var revealContentOpacity
    /// 宿主是否已替卡片裁好外形(真窗口 true / 编辑台 false),见 EnvironmentValues.notchHostClipsCard。
    @Environment(\.notchHostClipsCard) private var hostClipsCard
    /// 窗口此刻看不看得见(`notchCardLayerActive` 在本视图位置上的值,由 `NotchWindowRoot` 给)。
    /// 只给顶行用。`cardBodyLayer` 里的块要按**所在那一层**停表,必须经 `NotchLayerActiveReader`
    /// 在层内读:这个属性拿不到 body 内部 `NotchCardLayerActive` 设的值。
    @Environment(\.notchCardLayerActive) var surfaceVisible
    /// 这块内容所在显示器的像素倍率 —— 只给 `idleAppIcon` 算"要几像素的位图"用。
    @Environment(\.displayScale) var displayScale
    /// 快捷操作里此刻被指到的那颗键(见 `QuickActionTooltipOverlay`);nil = 指针不在任何一颗上。
    @State var hoveredQuickAction: QuickActionHint?
    /// 真正画出来的那一条。跟 `hoveredQuickAction` 分开存是为了那 260ms 的首次延迟(扫过一排键时
    /// 不该一路闪气泡);存整个 hint 而不只是文案,是因为气泡要**定位到那颗键**,文案和落点必须同源。
    @State var shownQuickActionTooltip: QuickActionHint?

    var body: some View {
        GeometryReader { proxy in
            let earWidth = controller.earWidth(cardWidth: proxy.size.width)
            ZStack(alignment: .top) {
                backgroundLayer(size: proxy.size)
                // 这几种时候铺一层纯黑盖住卡片样式自己的底,底色只剩"像不像刘海"一个标准:
                // - 收起态(没在播放、没 hover):卡片就是挂在真刘海边上的一小块,深色渐变/磨砂/封面模糊底在真刘海的纯黑旁边都是
                //   "看得出来的一块灰",收起就该和机器刘海一个颜色;
                // - 压根没有曲目:没有封面可跟、没有内容要衬(尺寸由 collapsesWhenPaused 管,底色不看它),hover 展开时同样黑底;
                // - 广告期间:广告没有封面可跟(`accent` 退回默认冷色、`coverArt` 风格退回那块灰),底色既衬不了内容、也代表不了这一刻
                //   在放什么。广告一结束自动退回原风格。
                // 用 opacity 而不是 if/else 换填充:跟卡片收放同一条弹簧渐变,不硬切。没有曲目、广告这两档变化时卡片尺寸和收起状态都
                // 不变,外层那几条弹簧(绑在尺寸和 isCollapsed 上)带不动它,得自己挂一条;收起那一档仍跟外层弹簧走。
                // 用纯 `Color` 而不是 `NotchHangingShape.fill(.black)`:形状填充是 CG 路径光栅化、卡片每变一次尺寸就重画一遍整卡,而
                // `Color` 只是一层 backgroundColor;圆角交给外层那道统一的 clipShape(理由同 backgroundLayer 里的打底层)。
                Color.black
                    .opacity(controller.isCollapsed || isIdleNoTrack || controller.isAdBreakNow ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35),
                               value: isIdleNoTrack || controller.isAdBreakNow)
                // 刘海空当里的品牌胶囊(notchSeam)直接钉在 ZStack 顶部居中,不画在顶行的 HStack 里:位置只由 ZStack 的居中对齐
                // 决定,跟耳朵怎么换、怎么长都无关。挂在顶行里的话,收放过渡中按离场 / 插入时的耳宽布局,胶囊会跑出刘海的遮挡范围、
                // 在屏幕上漏出来一会。它本来就不属于哪只耳朵,顶行里这个位置只留同宽的空当(notchGap)。
                notchSeam
                    .frame(height: controller.contentTopInset)
                    .opacity(revealContentOpacity)
                VStack(spacing: 0) {
                    // 顶行占菜单栏那一条高度,收起后跟菜单栏齐平、不额外占屏。两种形态:
                    // 收起(没在播放)= iPhone 灵动岛式极简(左耳封面、右耳音浪,
                    // 歌名/播放键都收进 hover 展开卡);稳态/展开 = 歌名 + 播放键。
                    // 两种形态是**同一个** topRow 按 isCollapsed 换耳朵里的内容,不是两个视图
                    // 在这里 if/else 互换(理由见 topRow 头注)。
                    topRow(earWidth: earWidth)
                        .frame(height: controller.contentTopInset)
                    // 顶行以下的一切(曲目信息头部 / 歌词行 / 展开区)**不在这个 VStack 里**,
                    // 而是作为外层 ZStack 的 overlay 各自定宽、定 y、以卡片中心为锚(见 cardBodyLayer)。
                    // 卡片的高度本来就由 NotchChromeSource.cardHeight 给 NotchWindowRoot 钉死,不靠这里堆出来。
                }
                // 出场动画的内容淡入:值来自 NotchWindowRoot 的 keyframeAnimator,
                // 平时恒为 1;背景层不套它,所以卡片形状先长出来、字后到。
                .opacity(revealContentOpacity)
            }
            // 顶行以下的内容(曲目信息头部 / 两份歌词行变体 / 展开区)作为 ZStack 的 **overlay**、顶部居中,
            // 理由见 cardBodyLayer。
            // 必须是 overlay 而不是 ZStack 的子视图:展开宽那些在稳态下比卡片宽,做子视图会把 ZStack
            // 撑到展开宽,而 GeometryReader 把内容摆在左上角 —— 整卡内容右移 (展开宽 − 稳态宽) / 2
            // (逐帧抓窗撞到过两次:第一次是歌词行的定宽容器,第二次就是这里)。overlay 不参与
            // 父布局,居中对齐的参照始终是卡片本身。
            //
            // hasTrack 这一条必须跟 NotchChromeSource.cardHeight 里那个同款判断成对出现:
            // 压根没有曲目时歌词行是**全空**的,44pt 白占着就是纯粹占用空间。一处改一处不改的表现是
            // "行不见了高度还留着"或反过来把行裁掉半截。
            .overlay(alignment: .top) {
                if controller.hasTrack {
                    cardBodyLayer
                        // 收起时不摘、只藏:收起态里悬停展开时整块新插进来的话,决策 94 的延迟淡入、错开都不起作用,
                        // 多行歌词还要现建(05 章决策 101)。
                        .modifier(NotchCardLayerActive(active: !controller.isCollapsed))
                        // 出场动画的内容淡入:值来自 NotchWindowRoot 的 keyframeAnimator,平时恒为 1。
                        // 报收听里程碑时整块让给报喜面板(下面那个 overlay)。
                        .opacity(controller.milestone == nil ? revealContentOpacity : 0)
                } else if !controller.isCollapsed {
                    // 没有曲目:hover 展开只长出一块「空闲面板」(决策 #31),高度与
                    // `NotchChromeSource.cardHeight` 的 !hasTrack 分支读同一个值。跟 cardBodyLayer 里
                    // 各块同一套做法 —— 常驻、定宽、定 y、只切透明度(NotchCardLayerActive),稳态下
                    // 它透明地挂在顶行下面、被外层裁剪裁掉,展开时在最终位置原地淡入。
                    // 有「发现新播放器」的信任提议挂着时(决策 #37)这一块换成提议的变体,
                    // 同高同排法,由宿主子视图自己订阅、自己切,见 NotchIdlePanelHost。
                    NotchIdlePanelHost(prompt: prompt, tint: accentOrWhite) { idleExpandedPanel }
                        .frame(width: controller.expandedCardWidth,
                               height: NotchExpandedMetrics.idlePanelHeight, alignment: .top)
                        .padding(.top, controller.contentTopInset)
                        .modifier(NotchCardLayerActive(active: controller.isExpanded))
                        .opacity(revealContentOpacity)
                }
            }
            // 收听里程碑:报喜面板顶替顶行以下那一块;卡片高度那边换成同一个 milestonePanelHeight。
            .overlay(alignment: .top) {
                if let milestone = controller.milestone, !controller.isCollapsed {
                    NotchMilestonePanel(milestone: milestone, tint: accentOrWhite, animated: !reduceMotion)
                        .frame(width: controller.expandedCardWidth, height: NotchMetrics.milestonePanelHeight)
                        .padding(.top, controller.contentTopInset)
                        .opacity(revealContentOpacity)
                        .transition(.opacity)
                }
            }
            // 换歌翻牌:新歌名从刘海里掉出来。关着歌词行时卡片为它多长一截(`cardHeight(expanded:)`),开着时盖在
            // 歌词行上(稳态那份歌词行这时让开,见 cardBodyLayer)。常驻:收回 / 换下一条的动画才演得出来。
            .overlay(alignment: .top) {
                NotchTrackDropStrip(
                    drop: shownTrackDrop, noteTint: trackDropNoteTint, width: controller.steadyCardWidth,
                    height: controller.showsLyrics ? controller.lyricRowHeight : NotchMetrics.trackDropHeight,
                    animated: !reduceMotion)
                    .padding(.top, controller.contentTopInset)
                    .opacity(revealContentOpacity)
            }
            // 瞬态横幅:关着歌词行时画在卡片为它多长的那一截里(开着时在歌词行里,见 NotchTransientHost)。
            .overlay(alignment: .top) {
                if controller.showsBannerStrip {
                    NotchTransientHost(tint: accentOrWhite) { Color.clear }
                        .frame(width: controller.steadyCardWidth, height: NotchMetrics.trackDropHeight)
                        .padding(.top, controller.contentTopInset)
                        .opacity(revealContentOpacity)
                        .transition(.opacity)
                }
            }
            // 进度线:贴着稳态卡片底边,只在没展开时可见。开着「进度线」时常驻、只切透明度,透明度用自己那条曲线
            // (`NotchProgressLine.fade`,只套在 opacity 上),别写成 if + transition 交给卡片那条尺寸弹簧:线停在稳态底边的高度上,
            // 跟着弹簧慢慢淡出 / 淡入时会横在正在变形的卡片中间。见 05 章决策 94。
            .overlay(alignment: .bottom) {
                if controller.showsProgressLine && controller.progressLineStyle == .bottom {
                    let shows = controller.showsBottomProgressLine
                    NotchProgressLine(anchor: playback.anchor, pausedPositionMs: playback.pausedPositionMs,
                                      // 有锚点时用锚点自己的时长,跟外推的位置同一次采样(同展开区的 NotchScrubber),换歌那一拍不跳。
                                      durationMs: (playback.anchor?.durationMs).flatMap { $0 > 0 ? $0 : nil }
                                          ?? playback.currentDurationMs, tint: progressLineTint,
                                      active: surfaceVisible && shows, outline: controller.cardOutline)
                        .padding(.bottom, 1)
                        .animation(NotchProgressLine.fade(showing: shows, reduceMotion: reduceMotion)) {
                            $0.opacity(shows ? 1 : 0)
                        }
                        .opacity(revealContentOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(!shows)
                }
            }
            // 「耳朵」那一档:沿卡片外沿走到刘海。卡片尺寸作为形状的可动画值传进去,跟外层同一次尺寸弹簧逐帧插值,
            // 展开 / 收回时线跟着外沿走,透明度用自己那条曲线(`NotchEarProgressLine.fade`)一边变形一边淡出 / 淡入。
            // 常驻、只切透明度。
            .overlay(alignment: .top) {
                if controller.showsProgressLine && controller.progressLineStyle == .ears {
                    let shows = controller.showsEarProgressLine
                    NotchEarProgressLine(anchor: playback.anchor, pausedPositionMs: playback.pausedPositionMs,
                                         durationMs: (playback.anchor?.durationMs).flatMap { $0 > 0 ? $0 : nil }
                                             ?? playback.currentDurationMs, tint: progressLineTint,
                                         active: surfaceVisible && shows, outline: controller.cardOutline,
                                         notchWidth: controller.notchWidth,
                                         cardSize: CGSize(width: controller.cardWidth, height: controller.cardHeight))
                        .animation(NotchEarProgressLine.fade(showing: shows, reduceMotion: reduceMotion)) {
                            $0.opacity(shows ? 1 : 0)
                        }
                        .opacity(revealContentOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(!shows)
                }
            }
            // 展开态内容(下一句预览+进度条)本身没有另外裁一次形状——如果只让背景那一层
            // fill 是圆角、前景内容不跟着裁,内容溢出圆角边界时会带着直角"戳"出卡片轮廓。
            // 这里对整个 ZStack 统一裁一次,保证任何内容都不会越出这个卡片的真实外轮廓。
            // 背景打底层与收起态黑罩都是不带形状的纯色,底部圆角**只**靠这一道
            // (或宿主那道,见下)—— 别再把它们改回 NotchHangingShape.fill,那是每帧重画整卡。
            //
            // 宿主已经在卡片外面裁过同一个形状时(真窗口的 NotchWindowRoot,那道 NotchRevealShape
            // 终态与这里重合)这一道就省掉:两层 mask 在尺寸动画里每帧各重设一次路径,是白付的。
            // 这个环境值对某个宿主是常量(见其 doc),分支不会在运行期切换、不会重建子树。
            .modifier(NotchCardClip(enabled: !hostClipsCard, outline: controller.cardOutline))
        }
        // 这扇灵动岛向 `YouTubeMusicAdSkipCenter` 登记「广告态、要门槛结果」,挂在这里。
        //
        // 判据是 **chrome 的 `isAdBreakNow`**,而且只有 `drivesAdSkipGate`(真窗口)才登记 —— 编辑台预览也会进广告态、
        // `NotchPlayback` 在预览里也照样订阅真的 `PlaybackCoordinator`,让预览也登记的话,设置页只要开着,那块
        // 编辑台预览就会替轮询登记需求、跟着真广告对用户的浏览器发 AppleScript。理由同 `controlsDidBecomeVisible`
        // 在预览里是空实现:预览不产生副作用。插播里换到下一条广告由 center 按标题自己认,不用在这里重调。
        //
        // `.onAppear` 那一下是为了"窗口刚出现时已经在放广告"这种情形 —— `onChange` 只在值变化时触发。
        .onAppear { playback.syncAdSkipGate(adBreak: drivesAdSkipGate && controller.isAdBreakNow) }
        .onChange(of: controller.isAdBreakNow) { _, on in playback.syncAdSkipGate(adBreak: drivesAdSkipGate && on) }
        .onDisappear { playback.syncAdSkipGate(adBreak: false) }
        // 这里不挂 .onHover:它覆盖的范围比卡片大一圈,窗口常驻最大尺寸时鼠标划过卡片下方的透明区也会展开。命中判定和触觉反馈
        // 在 NotchWindowRoot,那里拿精确坐标跟卡片矩形直接比;预览那边走自己的 onContinuousHover。
        // 展开态也不加投影:灵动岛的设计语言是从刘海长出来,不是一张悬空的卡片,投影会把这件事拆穿,观感是整个卡片外侧糊着一层灰。
        // 要加投影的话,窗口必须按投影半径留出四周余量(见 NotchLyricsWindowController.recomputeGeometry),否则阴影会被窗口的
        // 矩形边界硬裁,在底部两个圆角外侧留下两块直角的深色残影。
    }

    // 「跟随封面」背景:跟"歌词窗口"的 artworkBackground(LyricsWindowView.swift)同一套效果(封面整图放大、高斯模糊、压一层
    // 半透明黑),缩小到灵动岛胶囊尺寸。模糊图要等烘焙好才有,所以 .coverArt 不走 `NotchCardStyle.backdrop`,
    // 在背景层直接铺 PlaybackCoordinator 预烘焙好的模糊图(`blurredArtworkImage`,烘焙参数见
    // `rebakeBlurredArtwork`),裁剪边界的约束见 NotchCrossfadeBackdrop 的头注。
    //
    // 没有封面数据(这首歌还没解析出封面/引擎还没查到/本来就没有)时退回纯黑(`NotchCardStyle.coverArt.backdrop`),跟机器刘海融成一块。
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        // 优先用高清替代(highResArtworkImage):系统那份对网易云永远只有 100×100,云盘没匹配上的歌还是灰底音符占位图,缓存里
        // 解析到真封面时背景该铺真封面。nil 时回落系统那份,跟歌词窗口封面卡同一套取舍(见 highResArtworkImage 的注释)。
        // 铺的是 PlaybackCoordinator 预烘焙好的模糊图(源同样是 highResArtworkImage ?? artworkImage),不在视图层挂活滤镜:那是
        // 合成期滤镜,这个窗口播放期间因逐字填色/音浪/跑马灯几乎永动,GPU 每次重合成都对同一张图重算同一个模糊。clampedToExtent
        // 让边缘实心,打底层只为烘焙空窗(封面刚到、模糊图晚几十 ms)兜底。
        if playback.notchCardStyle == .coverArt,
           let image = playback.blurredArtworkImage {
            ZStack {
                // 不透明打底,烘焙空窗期(封面刚到、模糊图晚几十 ms)先露它,见上。
                //
                // 是一块纯色,不是 darkGradient 那道渐变,也不套 NotchHangingShape:这一层平时整个压在封面模糊图底下、一个像素都看
                // 不见,却在 hover 展开/收起时随卡片尺寸每帧重画,画渐变时 Time Profiler 量到主线程 24% 的忙时是 CoreGraphics 在给这道
                // 看不见的渐变做 rgba64 轴向着色(`ripc_DrawShading` → `rgba64_shade_axial_RGB`,964×382px 每帧一遍)。纯色的 `Color`
                // 视图落成一个只有 backgroundColor 的 CALayer,尺寸变化零重画;底部圆角由外层 ZStack 那道统一的 clipShape 负责。
                // 颜色跟没有封面时的兜底一样是纯黑。
                Color.black
                // 两层交叉淡入(`NotchCrossfadeBackdrop`):换图时旧图留在下面、新图从透明淡到不透明。
                // 别换回 `.animation(value:)` 直接换 Image 内容 —— 那样旧图当场消失、新图从透明淡入,
                // 中间露出上面那块打底色,同一首歌换上高清封面(两张模糊图几乎一样)时表现为整卡暗一下再亮回来。
                NotchCrossfadeBackdrop(image: image, size: size, overlayOpacity: playback.backdropOverlayOpacity)
            }
        } else {
            playback.notchCardStyle.backdrop
        }
    }

    /// 压根没有曲目。读 controller 那一份而不是自己再从 playback 算一遍 —— 卡片高度
    /// (NotchWindowRoot.cardHeight)也要用同一个判据决定歌词行占不占 44pt,两处各算一遍
    /// 必然漂,而漂的表现是"行不见了但高度还留着"或反过来把行裁掉半截。
    /// 跟菜单栏面板的同名属性是同一套语义(MenuBarPanel.isIdleNoTrack)。
    var isIdleNoTrack: Bool { !controller.hasTrack }

    /// 此刻画出来的那条掉下来的歌名:收起、展开、报喜时不画(控制器那边展开 / 报喜时也会把它收掉)。
    private var shownTrackDrop: NotchTrackDrop? {
        controller.isCollapsed || controller.isExpanded || controller.milestone != nil ? nil : controller.trackDrop
    }

    /// 掉下来那条歌名前那枚音符的颜色:「跟随封面」风格下用封面里最鲜艳的那种,其余风格跟别的前景一样白。
    /// 进度线(底边 / 耳朵)的颜色:封面大片的那种色相的深色版(`vividDeepAccent`,饱和度 0.6~0.75、亮度在纯色那一档,
    /// 只为看得见留 2:1),封面里没有够鲜艳的颜色时退回前景色。前景色和音符色都提亮过,画成细线偏白。不看卡片风格:
    /// 线是点缀,不跟文字走。
    private var progressLineTint: Color {
        playback.vividDeepAccent ?? accentOrWhite
    }

    private var trackDropNoteTint: Color {
        playback.notchCardStyle == .coverArt ? (playback.vividAccent ?? .white) : .white
    }

    /// 顶行以下的全部内容:曲目信息头部、歌词行(两份定宽变体)、展开区。每一块都常驻、定宽、定 y、以卡片中心为锚,展开 / 收回
    /// 只切它们的透明度:稳态那份歌词行原地淡出,展开态的头部 / 歌词行 / 展开区在各自的最终位置淡入,不是平移过去。
    ///
    /// 淡出与淡入必须错开,不能同时进行,判据是 `staggered`(两份到底在不在同一个落点)。两份歌词行的纵向落点差正好是展开头部
    /// 的高度(`expandedTrackInfoHeaderHeight`,歌名+歌手+专辑全开是 55pt),横向则差着「稳态宽 vs 展开宽」:同一句歌词在窄容器里
    /// 溢出跑马灯、在宽容器里装得下就按 restingAlignment 摆,两份的字根本不在同一个 x 上。这两份若在同一段时间里都停在半透明
    /// (卡片那条尺寸弹簧驱动 opacity 时就是如此,弹簧尾巴长,中段两份都在 0.4~0.6),视觉上会把两个错位的半透明副本积分成
    /// 「一个东西斜着滑过去」,是假位移,比真平移和干脆切换都难看。曲线与时序在 `NotchCardLayerActive`。反过来,两宽相等且展开
    /// 头部关掉时两份落点逐像素重合,那时错开会变成白闪一下,所以 `staggered` 必须按落点算、不能写死 true。
    ///
    /// 为什么是常驻 + 透明度,而不是 if/else 换视图或把行留在 VStack 里:吃满卡片宽的行会跟着卡片左沿滑(卡片从稳态宽长到展开宽时,
    /// 靠左的歌词 / 歌名一路向左滑一百多 pt,头部插进来时歌词行还同时往下滑);if/else 直接放 VStack、放进定宽 overlay 容器、只把
    /// 歌词行挪出来,正在过渡的那份或新插进来的那份也都跟着卡片左沿滑。SwiftUI 对进出场视图怎么摆,跟持久视图不是一套规则,而且
    /// 不透明;持久视图被居中对齐这件事刘海胶囊(notchSeam)验证过:卡片怎么长,中心一像素不动。所以全部做成持久视图,位置交给
    /// 居中布局(overlay alignment .top = 顶部居中),自己只动 opacity(曲线在 `NotchCardLayerActive`)。竖直位置各自写死为常量:头部贴顶行;
    /// 稳态歌词行贴顶行,展开歌词行再往下让出头部高度(`expandedTrackInfoHeaderHeight`,没头部时为 0);展开区在展开歌词行之下。
    /// 没有任何一块的 frame 在动画里改值;各块相对卡片的横向偏移随卡片宽变,跟卡片同一条弹簧走、正好抵掉卡片自己的位移,所以屏幕上没有平移。
    ///
    /// 守则:① 藏着的那份**必须**停表 —— 逐字填色与迷你进度条的 TimelineView 都按环境值
    /// `notchCardLayerActive` 暂停,否则 30Hz 热路径翻倍(性能审计盯住的那条);跑马灯是图层动画、不占主线程,
    /// 只按窗口可见性停(见 `mainLyricLine`)。② 藏着的一律 `allowsHitTesting(false)`(里面有封面按钮、播放键、校准键)且对读屏
    /// 隐藏 —— 都收在 `NotchCardLayerActive` 这一个修饰器里。③ 两个宽度从 chrome 拿(协议
    /// `steadyCardWidth` / `expandedCardWidth`),不能用 GeometryReader 的现值。④ 「显示歌词」关着时稳态
    /// 那份歌词行不建(那时稳态本来没有歌词行,`showsLyricRow` 的语义),展开那份照常。⑤ 这一层里**不准**
    /// 出现**随时间反复触发**的隐式动画 —— 音浪那次(EqualizerBars 头注)证明它会在卡片尺寸弹簧中途把
    /// 作用域里的位置也接管走。`NotchCardLayerActive` 那条透明度曲线是唯一的例外:它只在展开 / 收起的**边沿**翻一次,
    /// 而且用 `.animation(_:body:)` 只套在 opacity 上 —— 上面那份横向偏移一旦被别的曲线接走,这一块就会横着滑(05 章决策 94)。
    /// ⑥ 高度算术仍以 NotchChromeSource.cardHeight /
    /// NotchExpandedMetrics.height 为唯一真源,这里的 y 只是把同一组量按顺序加起来。
    private var cardBodyLayer: some View {
        let expanded = controller.isExpanded
        let top = controller.contentTopInset
        let headerHeight = controller.expandedTrackInfoHeaderHeight
        // 稳态那份和展开那份到底在不在同一个落点:纵向差展开头部的高度,横向差两个卡片宽。
        // 两者都为零时两份逐像素重合,淡出淡入必须同步进行(错开会白闪一下);只要有一样不为零,
        // 就必须错开,否则两个错位的半透明副本会被看成「歌词斜着滑过去」。见头注那条。
        let staggered = headerHeight > 0 || controller.expandedCardWidth != controller.steadyCardWidth
        let showsList = controller.showsExpandedLyricList
        // 必须是**显式**的 ZStack(alignment: .top),不能让 @ViewBuilder 直接吐一个 TupleView 再在外面套
        // .opacity:套了修饰符的 TupleView 是一个视图,里面几块按**居中**叠,外面 overlay 的 .top 只管这一个整体
        // —— 那样稳态下最高的那块(展开区)会把整体撑到 220pt、居中后歌词行被顶到卡片上方裁没了,
        // 展开态头部落到了卡片中段。
        return ZStack(alignment: .top) {
            // 曲目信息头部(歌名/歌手/专辑):画在歌词行**之上**,歌词行和下一句在它下面。只在展开时可见。
            if controller.showsExpandedTrackInfo {
                trackInfoHeader
                    .frame(width: controller.expandedCardWidth, height: headerHeight, alignment: .top)
                    .padding(.top, top)
                    .modifier(NotchCardLayerActive(active: expanded, staggered: staggered))
            }
            // 用户关掉「显示歌词」时稳态没有歌词行——但展开时哪怕关着也要照常画,见 showsLyricRow
            // 的注释(回归护栏:漏了展开这一档的表现是"展开后有下一句预览、却看不到正在播放的当前行")。
            // 按宽度断句只认一份歌词行的宽:稳态那份(更窄)在就报它,不在(「显示歌词」关着)才报展开那份。
            if controller.showsLyrics {
                lyricRow(reportsWidth: reportsLineLayout)
                    .frame(width: controller.steadyCardWidth, height: controller.lyricRowHeight)
                    .padding(.top, top)
                    // 换歌翻牌的歌名盖在这一行上时让开(见 body 里那条 NotchTrackDropStrip)。
                    .modifier(NotchCardLayerActive(active: !expanded && shownTrackDrop == nil, staggered: staggered))
            }
            // 开着多行歌词时展开那份歌词行让给列表,但照样建着、只是藏着(停表):「显示歌词」关着时按宽度断句报的是它。
            lyricRow(reportsWidth: reportsLineLayout && !controller.showsLyrics)
                .frame(width: controller.expandedCardWidth, height: controller.lyricRowHeight)
                .padding(.top, top + headerHeight)
                .modifier(NotchCardLayerActive(active: expanded && !showsList, staggered: staggered))
            if showsList {
                NotchExpandedLyricList(tint: accentOrWhite)
                    .frame(width: controller.expandedCardWidth, height: controller.expandedLyricListHeight)
                    .padding(.top, top + headerHeight)
                    .modifier(NotchCardLayerActive(active: expanded, staggered: staggered, waitsForResize: true))
            }
            // 展开区**完全不**受「显示歌词」开关影响:它是够到播放控制和进度条的唯一入口,
            // 而且用户主动指向展开这个动作本身就说明他现在想看更多 —— 连里面那行下一句预览也照常画。
            expandedContent
                .frame(width: controller.expandedCardWidth)
                .padding(.top, top + headerHeight
                         + (showsList ? controller.expandedLyricListHeight : controller.lyricRowHeight))
                .modifier(NotchCardLayerActive(active: expanded, staggered: staggered))
        }
    }

    /// 灵动岛里几乎所有前景元素的颜色,见 NotchPlayback.accent。除了封面缩略图的描边(刻意的,见 artworkThumbnail 注释:磨砂玻璃
    /// 风格下要给浅色封面兜一圈可见轮廓),前景都走这里:状态文字跟正常歌词在同一个 Group 里,一处写死白色,同一行就会出现
    /// "有歌词时跟着封面色、一旦变成「暂无歌词」就突然跳回白"的闪动。
    var accentOrWhite: Color {
        // 组合逻辑(风格是不是「跟随封面」× 动态主色)已下沉进 NotchPlayback.accent 预组合去重,这里只是个语义化的别名。
        playback.accent
    }
}

/// 歌词行上「瞬态横幅盖歌词」这层壳,单独订阅 NotchTransientCenter:banner 只被这一行消费,订阅挂在 NotchLyricsView 根上的话,
/// 音量连调时每档一次的 @Published 变化会打醒整卡 body(含封面背景/跑马灯/音浪)。下沉之后横幅出现/消失只失效这一行。
///
/// 歌词行常驻,横幅盖上来时只藏起来(`NotchCardLayerActive`:透明、停表、对读屏隐藏),别写回 `if let banner … else` 换视图:
/// 那样每弹一次横幅歌词行就拆掉重建,长句跑马灯从句首重来,逐字行重画整行位图。横幅自己的淡入淡出单独包一层,
/// `.animation(_:value:)` 的作用域不罩到歌词行上(05 章决策 101)。
struct NotchTransientHost<Fallback: View>: View {
    @ObservedObject private var transients = NotchTransientCenter.shared
    let tint: Color
    @ViewBuilder let fallback: () -> Fallback

    init(tint: Color, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.tint = tint
        self.fallback = fallback
    }

    var body: some View {
        ZStack {
            fallback()
                .modifier(NotchCardLayerActive(active: transients.banner == nil))
            ZStack {
                if let banner = transients.banner {
                    NotchTransientRow(banner: banner, tint: tint)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: transients.banner)
        }
    }
}

// MARK: - 「发现新播放器」的两个宿主(决策 #37)

/// 收起态左耳那一格的宿主:平时是 fallback(`idleAppIcon`,Lyrimuse 自己的图标);`NotchUnknownPlayerPrompt`
/// 挂着信任提议时换成**那个播放器**的图标 + 右上角一粒小圆点。订阅下沉到这里,提议挂上 / 撤掉只失效这一格
/// (同 `NotchTransientHost` 那条性能审计纪律)。
///
/// 图标走 `AppIconResolver.icon(forBundleID:)`(跟菜单栏面板那枚来源角标、设置页「已信任的其它播放器」列表
/// 同一份缓存),再经 `NotchIdleAppIcon.bitmap(of:cacheKey:pixelSide:)` 按像素预先光栅化 —— 跟 App 图标那枚
/// 同一个锯齿问题、同一个解法。反查不到图标(App 装在非常规位置)时退回 fallback:提议本身还在,hover 展开
/// 照样能看到、能点,只是收起态少了那条线索。
///
/// 小圆点**破例用红**、不走这张卡的 tint:它是"有事等你处理"的角标,不是内容装饰 —— Dock / 系统通知的角标
/// 就是红的,换成 tint 在「跟随封面取色」下会变成一粒随机颜色的点,读不出"未处理"的意思。外面描 1pt 黑边,
/// 跟图标的浅色边角分开(卡片底本来就是纯黑,黑边等于一圈留白)。
struct NotchIdleEarIconHost<Fallback: View>: View {
    @ObservedObject private var prompt: NotchUnknownPlayerPrompt
    let side: CGFloat
    let scale: CGFloat
    let alignment: Alignment
    @ViewBuilder let fallback: () -> Fallback

    init(prompt: NotchUnknownPlayerPrompt, side: CGFloat, scale: CGFloat, alignment: Alignment,
         @ViewBuilder fallback: @escaping () -> Fallback) {
        self.prompt = prompt
        self.side = side
        self.scale = scale
        self.alignment = alignment
        self.fallback = fallback
    }

    /// 圆点直径。7pt 在 26pt 的图标角上是 iOS 角标那个量级,再小看不见、再大盖住图标一角。
    /// (泛型类型里放不了 static 存储属性,所以是计算属性。)
    private static var badgeSide: CGFloat { 7 }

    var body: some View {
        if let offer = prompt.offer,
           let icon = AppIconResolver.icon(forBundleID: offer.bundleID),
           let bitmap = NotchIdleAppIcon.bitmap(of: icon, cacheKey: offer.bundleID,
                                                pixelSide: Int((side * scale).rounded())) {
            Image(decorative: bitmap, scale: scale)
                .frame(width: side, height: side)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.red)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
                        .frame(width: Self.badgeSide, height: Self.badgeSide)
                        // 往角外挪一点:压在图标圆角上而不是整颗落在图标里面,角标的惯例。
                        .offset(x: 2, y: -2)
                }
                .frame(maxWidth: .infinity, alignment: alignment)
                .accessibilityLabel(L10n.t("检测到新的播放器") + " " + offer.displayName)
                .transition(.opacity)
        } else {
            fallback()
        }
    }
}

/// 没有曲目时 hover 展开出来那一块的宿主:平时是 fallback(`idleExpandedPanel`,「没有在播放」+ 三颗键);
/// `NotchUnknownPlayerPrompt` 挂着信任提议时换成:
///
///     检测到新的播放器                                [✓ 加入信任列表] [×]
///     Podcasts · 正在放:热可可 - 28. …
///
/// 排法、字号、行距、按钮档位**逐项照抄** `idleExpandedPanel`(左边两行字按头部歌名 / 歌手两档行高,右边一排
/// 22pt 键,同样的 16pt 左右内边距与 `trackInfoTopSpacing`)—— 高度必须跟它**一样**:`NotchChromeSource.cardHeight`
/// 的 `!hasTrack` 分支只认 `idlePanelHeight` 一个数,这里若高一截就被窗口硬裁、矮一截就底下留空。第一行只用
/// 通知那条现成的标题键,播放器名挪到第二行行首(`名字 · 正在放:…`),不新造带占位符的词条 —— 本地化表是四份
/// 手写文件 + 一份 xcstrings 真源,加一条键要动五个文件、且 xcstrings 多会话并发改会丢更新(11 章有记录)。
///
/// 「加入信任列表」是文字胶囊键(`NotchPillButton`,跟广告态那颗「跳过广告」同款):这颗键要是做成纯图标,用户
/// 得先猜它是什么才敢点 —— 提议信任是个有后果的动作(信任之后这个 App 的播放会进 Last.fm / ListenBrainz),
/// 文案必须摆在明面上。× 是"这次别烦我"(`NotchUnknownPlayerPrompt.dismiss`,同一段播放里不再挂),纯图标 +
/// 自绘悬浮提示(`QuickActionTooltipOverlay`,`.help()` 在这扇窗上永远不弹,理由见那个类型的头注)。
///
/// 这一块自己**不**读 `hasTrack` / `isExpanded`:它跟 `idleExpandedPanel` 一样只在没有曲目时被外层挂上,
/// 稳态下透明地待在顶行下面、展开时原地淡入,那套由外层的 `NotchCardLayerActive` 管。
private struct NotchIdlePanelHost<Fallback: View>: View {
    @ObservedObject private var prompt: NotchUnknownPlayerPrompt
    let tint: Color
    @ViewBuilder let fallback: () -> Fallback

    /// × 的悬浮提示状态,跟 `NotchLyricsView.hoveredQuickAction` / `shownQuickActionTooltip` 是同一套两段式
    ///(首次 150ms 才弹、已弹着时立即换字),这一块是独立视图,得自己存一份。
    @State private var hoveredAction: QuickActionHint?
    @State private var shownTooltip: QuickActionHint?

    init(prompt: NotchUnknownPlayerPrompt, tint: Color, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.prompt = prompt
        self.tint = tint
        self.fallback = fallback
    }

    var body: some View {
        if let offer = prompt.offer {
            unknownPlayerPanel(offer)
                .transition(.opacity)
        } else {
            fallback()
        }
    }

    /// × 那颗键在悬浮提示登记表里的 key(同 quickActionButton:用 SF Symbol 名)。泛型里放不了 static 存储属性。
    private static var dismissKey: String { "xmark" }

    private func unknownPlayerPanel(_ offer: NotchUnknownPlayerPrompt.Offer) -> some View {
        let dismissLabel = L10n.t("关闭")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: NotchExpandedMetrics.trackInfoLineSpacing) {
                Text(L10n.t("检测到新的播放器"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
                Text(offer.displayName + " · " + String(format: L10n.t("正在播放：%@"), offer.nowPlayingText))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                NotchPillButton(systemName: "checkmark.shield.fill", title: L10n.t("加入信任列表"), tint: tint) {
                    prompt.trust()
                }
                NotchIconButton(systemName: Self.dismissKey, glyphSize: 11, hitSize: NotchExpandedMetrics.trackInfoActionsHeight,
                                tint: tint, glyphOpacity: 0.75) {
                    prompt.dismiss()
                }
                // 下面三样照抄 NotchLyricsView.quickActionButton:进出登记 / 位置上报 / 读屏标签。
                .onHover { inside in
                    if inside {
                        hoveredAction = QuickActionHint(key: Self.dismissKey, text: dismissLabel)
                    } else if hoveredAction?.key == Self.dismissKey {
                        hoveredAction = nil
                    }
                }
                .anchorPreference(key: QuickActionAnchorKey.self, value: .bounds) { [Self.dismissKey: $0] }
                .accessibilityLabel(dismissLabel)
            }
            .frame(height: NotchExpandedMetrics.trackInfoActionsHeight)
        }
        // 气泡往上弹:这块面板贴着卡片底,理由同 idleExpandedPanel 那处。
        .modifier(QuickActionTooltipOverlay(hovered: hoveredAction, shown: $shownTooltip, tint: tint, edge: .top))
        .padding(.horizontal, NotchMetrics.expandedContentInset)
        .padding(.top, NotchExpandedMetrics.trackInfoTopSpacing)
    }
}

/// 在 `NotchCardLayerActive` 之下读 `notchCardLayerActive`。`NotchLyricsView` 自己声明的 `@Environment`
/// 取的是它在层级里所处位置(根上)的值,拿不到它 body 内部那层修饰器设的值;`cardBodyLayer`
/// 里要按所在那一层停表的地方一律经这里读。
struct NotchLayerActiveReader<Content: View>: View {
    @Environment(\.notchCardLayerActive) private var active
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(active) }
}

/// 展开态头部的歌名 / 歌手名 / 专辑名那一行。当前曲目有对应的简介(`EditorialNotesStore`)才接点击,指针移上去字色
/// 提亮;没有简介时就是一行字,不给任何「能点」的暗示。
struct NotchEditorialLine: View {
    @ObservedObject private var store = EditorialNotesStore.shared
    let kind: EditorialCard.Kind
    let text: String
    let tint: Color
    let font: Font
    let restingOpacity: Double
    let hoverOpacity: Double
    /// 有歌名 / 歌手名 / 专辑名、不在广告里(歌名还要不在电台口白里)。
    let tappable: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let clickable = tappable && !text.isEmpty && store.card(kind) != nil
        let label = Text(text)
            .font(font)
            .foregroundStyle(tint.opacity(clickable && hovered ? hoverOpacity : restingOpacity))
        if clickable {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityLabel(kind.openHint)
        } else {
            label
        }
    }
}

/// 灵动岛「跟随封面」背景那张模糊图,换图时两层交叉淡入:旧图不透明地留在下面,新图在上面 0.5s 从 0 淡到 1,
/// 淡完撤掉旧图。换歌、高清替代到货都会产出一张新的烘焙图实例(`PlaybackCoordinator.blurredArtworkImage`,
/// 按实例比较),每次都走这一条。
///
/// 每一层自带那道黑色压暗(`overlayOpacity`,按模糊图亮区算,跟 PlaybackCoordinator 估算背景亮度用的同一个值)
/// —— 两层都不透明,上层按透明度叠在下层上,压暗不会叠两遍。尺寸必须按 `size` 钉住:`scaledToFill` 协商出的
/// 偏大 frame 不钉回来,外层裁剪会裁在错的边界上。
private struct NotchCrossfadeBackdrop: View {
    let image: NSImage
    let size: CGSize
    let overlayOpacity: Double

    @State private var front: NSImage?
    @State private var back: NSImage?
    @State private var frontOpacity: Double = 1
    /// 每次换图加一。淡入完成回调只在自己仍是最新一次时才撤旧图:0.5s 内连着换两次(普通封面刚到、高清紧跟着
    /// 到)时,第一次的回调会把第二次还垫在下面的那张撤掉,露出底下的纯色,整卡暗闪一下。
    @State private var fadeGeneration = 0

    var body: some View {
        ZStack {
            if let back { layer(back) }
            if let front { layer(front).opacity(frontOpacity) }
        }
        .onAppear { front = image }
        .onChange(of: ObjectIdentifier(image)) { _, _ in
            back = front
            front = image
            frontOpacity = 0
            fadeGeneration &+= 1
            let generation = fadeGeneration
            withAnimation(.easeInOut(duration: 0.5)) {
                frontOpacity = 1
            } completion: {
                if generation == fadeGeneration { back = nil }
            }
        }
    }

    private func layer(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .overlay(Color.black.opacity(overlayOpacity))
    }
}
