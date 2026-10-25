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
    @StateObject private var playback = NotchPlayback()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 出场动画期间内容的透明度(NotchWindowRoot 在那 0.3s 里改,默认 1)。只作用于内容 VStack,
    /// 背景层不受影响 —— 先看到卡片形状从刘海长出来、再看到字,见 NotchRevealShape 头注。
    @Environment(\.notchRevealContentOpacity) private var revealContentOpacity
    /// 宿主是否已替卡片裁好外形(真窗口 true / 编辑台 false),见 EnvironmentValues.notchHostClipsCard。
    @Environment(\.notchHostClipsCard) private var hostClipsCard
    /// 窗口此刻看不看得见(`notchCardLayerActive` 在本视图位置上的值,由 `NotchWindowRoot` 给)。
    /// 只给顶行用。`cardBodyLayer` 里的块要按**所在那一层**停表,必须经 `NotchLayerActiveReader`
    /// 在层内读:这个属性拿不到 body 内部 `NotchCardLayerActive` 设的值。
    @Environment(\.notchCardLayerActive) private var surfaceVisible
    /// 这块内容所在显示器的像素倍率 —— 只给 `idleAppIcon` 算"要几像素的位图"用。
    @Environment(\.displayScale) private var displayScale
    /// 快捷操作里此刻被指到的那颗键(见 `QuickActionTooltipOverlay`);nil = 指针不在任何一颗上。
    @State private var hoveredQuickAction: QuickActionHint?
    /// 真正画出来的那一条。跟 `hoveredQuickAction` 分开存是为了那 260ms 的首次延迟(扫过一排键时
    /// 不该一路闪气泡);存整个 hint 而不只是文案,是因为气泡要**定位到那颗键**,文案和落点必须同源。
    @State private var shownQuickActionTooltip: QuickActionHint?

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
                if controller.showsProgressLine {
                    let shows = controller.showsBottomProgressLine
                    NotchProgressLine(anchor: playback.anchor, pausedPositionMs: playback.pausedPositionMs,
                                      // 有锚点时用锚点自己的时长,跟外推的位置同一次采样(同展开区的 NotchScrubber),换歌那一拍不跳。
                                      durationMs: (playback.anchor?.durationMs).flatMap { $0 > 0 ? $0 : nil }
                                          ?? playback.currentDurationMs, tint: accentOrWhite,
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
    private var isIdleNoTrack: Bool { !controller.hasTrack }

    /// 此刻画出来的那条掉下来的歌名:收起、展开、报喜时不画(控制器那边展开 / 报喜时也会把它收掉)。
    private var shownTrackDrop: NotchTrackDrop? {
        controller.isCollapsed || controller.isExpanded || controller.milestone != nil ? nil : controller.trackDrop
    }

    /// 掉下来那条歌名前那枚音符的颜色:「跟随封面」风格下用封面里最鲜艳的那种,其余风格跟别的前景一样白。
    private var trackDropNoteTint: Color {
        playback.notchCardStyle == .coverArt ? (playback.vividAccent ?? .white) : .white
    }

    /// 刘海空当(物理刘海遮挡处)里的品牌胶囊彩蛋。
    ///
    /// 肉眼永远看不到——那块被硬件挡死;只在截全屏 / 录屏 / 投屏或镜像到无刘海显示器时
    /// 露出来,像给刘海贴了个牌子。两个条件缺一不画:
    ///  - `notchWidth > 0`:无刘海屏幕的兜底几何和外接屏上的镜像副本都是 0,画了就真的能
    ///    看见,那就不是彩蛋而是一块白疤。
    ///  - `hasTrack`:会议里没放歌、灵动岛停在空闲黑块时,共享画面顶上不该挂着牌子(用户
    ///    选了"只在有曲目时画",而不是参考实现那种常驻)。
    /// 「截屏/录屏时隐藏」开着时整窗不进截图,不必另加开关。高度按顶行让 8pt 边、夹在
    /// 14～22pt(矮刘海机型顶行可能不到 26pt)。装饰元素,读屏不念。
    /// 顶行中间刘海那一段的**占位**:只有宽度,什么都不画。胶囊本体(notchSeam)自钉在 body 的
    /// ZStack 顶部居中(理由见那里),顶行只需要把这段宽度让出来。
    private var notchGap: some View {
        Spacer(minLength: 0).frame(width: controller.notchWidth)
    }

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
                        // 读得出"是个立体的牌子"("颜色跟着灵动岛走,稍微
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
        // 窗口看不见时按暂停处理:TimelineView 不会因为窗口被遮住 / orderOut 自己停。
        // 「减弱动态效果」开着也按暂停画:音浪是纯装饰的动画,别的会动的部分(弹簧、出场撑开)都已经为它停了。
        EqualizerBars(color: accentOrWhite, isPlaying: playback.isPlayingNow && surfaceVisible && !reduceMotion,
                      resyncKey: equalizerResyncKey,
                      amplitude: Self.vocalAmplitude(at:))
    }

    /// 音浪的关键帧是按「当前行的逐字 + 锚点外推」预先排好一段的(见 EqualizerBars 头注),这几样
    /// 一变就得按新基准重排:换行(包络跟着新一行的字走)、锚点重发(拖动进度 / 恢复播放)、总偏移。
    private var equalizerResyncKey: Int {
        var h = Hasher()
        let line = playback.currentLine
        h.combine(line?.words?.first?.startMs)
        h.combine(line?.words?.count)
        h.combine(line?.plainText)
        h.combine(playback.anchor?.fetchedAt)
        h.combine(playback.anchor?.progressMs)
        h.combine(playback.anchor?.rate)
        h.combine(playback.lyricsOffsetMs)
        return h.finalize()
    }

    /// 顶行:收起态与稳态/展开态共用这一个 HStack。两只耳朵的 `.frame(width: earWidth)` 随卡片连续动画;收起/稳态之间变的只是
    /// "这只耳朵此刻显示哪个模块、音浪在不在这侧"两个值:
    ///  - 收起:左耳固定封面、右耳固定音浪(iPhone 灵动岛式极简,歌名/播放键都收进 hover 展开卡);
    ///  - 稳态/展开:按设置(`leftEar` / `rightEar` / 音浪贴哪侧)。
    /// 两种形态下模块相同时(比如本来就左耳封面、右耳音浪)视图身份完全不变,连淡入淡出都没有,封面和音浪只是跟着耳朵边沿平移;
    /// 模块不同时,切换发生在耳朵内部、贴着耳朵外缘。别改成两个视图在 VStack 里按 isCollapsed 整行互换:SwiftUI 对离场的那一行按
    /// 离场时的耳宽布局、对刚插入的那一行按目标耳宽布局,两行都从卡片左沿起排,hover 展开的头 ~200ms 里两行的内容各在错的位置上
    /// 淡入淡出(刘海胶囊会漏出来,耳朵里的音浪 / 文字同样错位)。
    /// 音浪在暂停时是静止的矮条(EqualizerBars 自己按 isPlaying 处理),收起态的封面是"刚才在放什么"的余韵;没封面时左耳留空,
    /// 不画占位方块(理由同 artworkThumbnail)。
    ///
    /// 布局细节两条,收起与稳态一致、不随状态变:朝刘海那一侧内缩 `earNotchInset`(收起态 34pt 的耳朵减掉 6 还剩 28,放得下 23pt 的
    /// 封面 / 14pt 的音浪);左耳内容靠左外缘、右耳靠右外缘(05 章「指示条贴外缘,收放切换时不横跳」)。
    private func topRow(earWidth: CGFloat) -> some View {
        let collapsed = controller.isCollapsed
        let leftModule: NotchEarModule = collapsed ? .artwork : playback.leftEar
        let rightModule: NotchEarModule = collapsed ? .none : playback.rightEar
        let equalizerOnLeft = !collapsed && showsEqualizer(on: .left, module: playback.leftEar)
        let equalizerOnRight = collapsed || showsEqualizer(on: .right, module: playback.rightEar)
        // 音浪**独占**这只耳朵时的位置:非展开态一律贴外缘(左耳最左、右耳最右);只有
        // 卡片顶在宽度下限(最小宽,耳朵窄到音浪几乎填满可视段)时保持居中 —— 那是居中
        // 修好偏心的那个状态,宽度一放开居中就成了"飘在中间"。其余情况(耳朵里还有模块)
        // 本来就贴外缘 —— 那时音浪跟模块是一组,而文字跑马灯溢出时必须从外缘起排,不能居中。
        // **hover 展开态也不居中**(「展开要在最边上」):展开时耳朵宽出一大截,居中
        // 就成了飘在中间 —— 判据与推导见 soloEqualizerInset 的注释。
        let soloEqualizerLeft = equalizerOnLeft && !isIdleNoTrack && !controller.isAdBreakNow
            && leftModule == .none
        let soloEqualizerRight = equalizerOnRight && rightModule == .none
        let soloInset = NotchWidthBounds.soloEqualizerInset(
            earWidth: earWidth, barsWidth: EqualizerBars.width,
            cardPadding: controller.topRowPadding,
            shoulder: NotchOutline.shoulderRadius(notchHeight: controller.contentTopInset),
            expanded: controller.isExpanded,
            atMinimumWidth: controller.isCardAtMinimumWidth)
        return HStack(spacing: 0) {
            // 左耳:模块 + (可选)音浪。音浪贴哪只耳朵可配,
            // 这里跟下面右耳是完全对称的结构——只是音浪在外缘,外缘在左耳是"最左",
            // 所以音浪排在模块**前面**(下面右耳反过来,音浪排在模块后面)。
            // `.none` 不渲染(它是一条空的跑马灯,在 HStack 里会把音浪推到另一头去;要"贴外缘"
            // 靠的是外面那句 .frame(maxWidth:alignment:))。
            HStack(spacing: NotchMetrics.earWaveSpacing) {
                if equalizerOnLeft {
                    equalizerBars
                }
                // 压根没有曲目时左耳固定画 App 图标,
                // 不看配置:这时候除「播放控制」外每个模块都是空的(歌名/歌手/专辑/时长在 metadataText /
                // clockText 里对 isIdleNoTrack 一律回空串,封面为 nil 整块不画),左耳本来就是一片
                // 空白 —— 图标占的是这片空白,不是抢走谁的位置;左耳配了「播放控制」的,没有曲目时
                // 三键也无物可控,一并让位。有曲目的那一刻它让回配置的模块。
                if isIdleNoTrack {
                    // 经 idleEarIcon 再包一层:有「发现新播放器」的信任提议挂着时换成那个播放器的图标。
                    idleEarIcon(alignment: .leading)
                } else if leftModule == .artwork {
                    // 换歌翻牌:封面和广告时的喇叭画在同一枚翻牌里,广告结束、新封面到了,喇叭才能翻成封面。
                    flippingEarArtwork(alignment: .leading, showsAdIcon: controller.isAdBreakNow)
                } else if controller.isAdBreakNow {
                    // 广告期间左耳那枚喇叭。不看配置、也不看这一格原本有没有内容:只要识别到是广告,封面部分都用这个替代,不做
                    // "只占空白"那种折中,也不保留播放器给的广告物料图。这条口径覆盖全 App 四个当前曲目封面位(左耳、歌词行末尾、
                    // 歌词窗口封面卡、菜单栏面板那枚),清单与"为什么灵动岛展开头部那枚不用改"见 05 章「广告态」⑦。
                    //
                    // 代价:左耳配了「播放控制」的用户,广告期间那三颗键会被这枚图标顶掉。可接受,hover 展开卡的进度条下方本来就有
                    // 一整排三键(广告期间照旧渲染,见 adStatusColumn 头注)。这跟决策 #30(没有曲目时左耳固定画 App 图标、配了播放
                    // 控制的一并让位)是同一个取舍。收起态自动一并覆盖:上面 `leftModule` 在收起时固定是 `.artwork`。
                    adBreakEarIcon(alignment: .leading)
                } else if leftModule != .none {
                    earContent(leftModule, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 音浪独占且卡片顶在宽度下限时才往里推(居中于可视耳朵),其余贴外缘
            // (见 soloEqualizerInset)。
            .padding(.leading, soloEqualizerLeft ? soloInset : 0)
            // 内缩必须在 .frame(width:) **之前** —— 之后加等于把耳朵整体变宽 6pt,
            // 三段就不再严丝合缝铺满,背景形状/刘海空当会跟着错位。
            .padding(.trailing, NotchMetrics.earNotchInset)
            .frame(width: earWidth)

            // 刘海本身的空当——物理硬件不发光区域。那枚肉眼看不见的彩蛋(notchSeam)
            // **不画在这一行里**,而是钉在 body 的 ZStack 顶部居中,这里只留空当的宽度(理由见 notchGap)。
            notchGap

            // 右耳:模块 + (可选)音浪。控制键不放耳朵里:岛是 hover 展开的,光标到达耳朵之前岛已经展开,完整三键就在展开卡的
            // 进度条下方(见 expandedContent),耳朵里再留一枚播放键是重复目标。
            HStack(spacing: NotchMetrics.earWaveSpacing) {
                if rightModule != .none {
                    earContent(rightModule, alignment: .trailing)
                }
                if equalizerOnRight {
                    equalizerBars
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, soloEqualizerRight ? soloInset : 0) // 理由同左耳
            .padding(.leading, NotchMetrics.earNotchInset) // 理由同左耳,见 earNotchInset
            .frame(width: earWidth)
        }
        // 展开态收到跟下面那一列内容同一条边界(见 topRowPadding),跟卡片同一条弹簧过去。
        .padding(.horizontal, controller.topRowPadding)
    }

    // MARK: - 耳朵里的可配模块

    /// 一只耳朵里画什么。`alignment` 是**耳朵**的属性(左耳靠左、右耳靠右),不是模块的。
    ///
    /// 三条约束,每条都对应本仓一处既有做法:
    ///
    /// ① **只有时间类模块才套 `TimelineView`。** 给歌名/歌手/专辑也套一个时钟纯属白付(见 NotchPlayback 的头注)。
    ///
    /// ② **没有锚点就不排表**,静态画冻结值 —— 跟本仓既有的**存在性门**同一个做法(`NotchScrubber`
    ///    和歌词窗口那条进度都是 `if let anchor` 才挂表)。暂停/没在播放时 `LocalPlaybackSource`
    ///    会把 anchor 置 nil,于是这一格退回 `pausedPositionMs` 的冻结读数、一次表都不排。
    /// 这条不是可选优化:设置页那块编辑台渲染的是**同一份**视图,而它的替身 chrome 把
    ///    `isCollapsed` 写死 false、暂停着也照样画耳朵 —— 没有这道门,只要有人把耳朵配成时间类,
    ///    设置页开着就会每秒空转一次,哪怕歌是停着的。
    ///
    /// ③ **周期起点按锚点对齐到"曲目位置的整秒"**,步长按倍速取 `1/rate`(见
    ///    `NotchTimeFormat.clockSchedule`)。钉在**墙钟**整秒上是不行的:曲目位置的整秒边界跟
    ///    墙钟整秒无关,两者的相位差在一条锚点的生命周期里是**常量** —— 也就是说 hover 展开时
    ///    耳朵可能整首歌都比正下方那条迷你进度条**慢 1 秒**(耳朵 1:23、进度条 1:24 长期并排),
    ///    而不是偶尔闪一下。对齐之后两处读数同源同相。
    /// 别顺手把 `clockText` 里的 `Date()` 换成 `context.date`:对齐之后 tick 恰好落在边界上,
    ///    用调度时刻采样有可能因为亚毫秒取整读回旧的那一秒;实际派发比调度晚几毫秒,`Date()`
    ///    反而落在边界的正确一侧。
    @ViewBuilder
    private func earContent(_ module: NotchEarModule, alignment: Alignment) -> some View {
        switch module {
        case .artwork:
            flippingEarArtwork(alignment: alignment, showsAdIcon: false)
        case .controls:
            earControls(alignment: alignment)
        case .elapsed, .remaining:
            if let anchor = playback.anchor, surfaceVisible {
                TimelineView(NotchTimeFormat.clockSchedule(
                    for: anchor, countdownFromMs: module == .remaining ? playback.currentDurationMs : nil)) { _ in
                    earText(clockText(module), module: module, alignment: alignment)
                }
            } else {
                earText(clockText(module), module: module, alignment: alignment)
            }
        case .playCount:
            // 广告、电台口白期间没有「这首」可数(口白时歌名耳朵已换成台名)。
            if !isIdleNoTrack, !playback.isCurrentTrackAdBreak, radioTalkStation == nil {
                NotchEarPlayCount(title: playback.title, artist: playback.artist, tint: accentOrWhite, alignment: alignment)
            }
        case .player:
            if !isIdleNoTrack {
                NotchEarPlayerIcon(side: NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset),
                                   scale: max(1, displayScale), alignment: alignment,
                                   trackKey: "\(playback.artist)|\(playback.title)")
            }
        case .title, .artist, .album, .none:
            earText(metadataText(module), module: module, alignment: alignment)
        }
    }

    /// 耳朵里那枚封面(`NotchEarArtworkFlip`):换歌后新封面到了、控制器揭晓了这一首(歌名掉下来的那一拍)翻一下,
    /// 一直开着、不看设置。`showsAdIcon` 只有左耳会传 true —— 喇叭也画在这枚翻牌里,广告结束才能翻成封面。
    ///
    /// 尺寸走**收起态那一枚**的公式(`contentTopInset − 10`,约 23pt),**不是**歌词行末尾
    /// 那枚 32pt 的:耳朵只有 `contentTopInset` 那么高,32pt 塞进来上下一点余量都不剩(见 artworkThumbnail 上方)。
    ///
    /// 没有封面数据时**整块不画**(不摆占位方块)—— 跟歌词行末尾那枚同一个取舍,理由见那边。
    private func flippingEarArtwork(alignment: Alignment, showsAdIcon: Bool) -> some View {
        let side = NotchMetrics.earArtworkSide(contentTopInset: controller.contentTopInset)
        return NotchEarArtworkFlip(
            title: playback.title, artist: playback.artist,
            artworkImage: playback.artworkImage, highResImage: playback.highResArtworkImage,
            overrideImage: radioTalkStation?.image, isAdBreak: showsAdIcon,
            isRevealed: controller.revealsTrack(NotchTrackDropRules.key(
                title: playback.title, artist: playback.artist, isAdBreak: playback.isCurrentTrackAdBreak)),
            alignment: alignment, animated: !reduceMotion,
            artwork: { artworkThumbnail($0, side: side) },
            adIcon: { adBreakEarIconContent })
    }

    /// 广告期间左耳那枚喇叭。
    ///
    /// 符号沿用 `adStatusColumn` 和「没能跳过这条广告」瞬态横幅里的同一枚 `megaphone.fill` ——
    /// 同一件事在这张卡上不该出现两种画法。前景色也跟那一行同口径(`accentOrWhite` 七成不透明
    /// + 同一道投影);广告期间底已经是纯黑(见 body 里那层 `Color.black`),七成白在纯黑上足够清楚。
    ///
    /// 不接点击:它是个状态标记,不是按钮 —— 广告期间真正能点的那件事(「跳过广告」)有自己的键,
    /// 在展开卡的状态行右侧,见 `adStatusColumn`。读屏也不念(装饰元素):同一行的「广告中 · 还剩
    /// 0:20」已经把这件事说清楚了,再念一遍是重复。
    private func adBreakEarIcon(alignment: Alignment) -> some View {
        adBreakEarIconContent.frame(maxWidth: .infinity, alignment: alignment)
    }

    /// 喇叭本体(不含占满耳朵的那层 frame):换歌翻牌那枚翻牌里也画它。
    @ViewBuilder
    private var adBreakEarIconContent: some View {
        let side = NotchMetrics.earAdIconSize(contentTopInset: controller.contentTopInset)
        let hint = showsAdSkipHint
        HStack(spacing: side * 0.22) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: side, weight: .semibold))
            if hint {
                // 比喇叭小一号、再淡一点:它是**附注**(这条广告能跳),不是这一格的主语(在放广告)。
                // 符号跟展开卡那颗「跳过广告」键同一枚 `forward.end.fill` —— 同一件事在这张卡上
                // 不该出现两种画法(同喇叭那条)。
                // 0.78:喇叭 ~13pt 时这枚约 10pt,跟悬浮窗那排非主按钮的 10.5pt 同量级(那是这个
                // 仓库验过的"小到不挡视线、又还认得出"的下界),再小就开始糊成一个点。
                Image(systemName: "forward.end.fill")
                    .font(.system(size: side * 0.78, weight: .semibold))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(accentOrWhite.opacity(0.7))
        .notchTextShadow()
        // 喇叭本身是装饰(同一行的「广告中 · 还剩 0:20」已经说清楚了);带上提示之后这一组就有了
        // 独立信息 —— 稳态下它**是**读屏用户唯一能知道"这条能跳"的地方,所以这时候要念。
        .accessibilityHidden(!hint)
        .accessibilityLabel(hint ? L10n.t("此广告可跳过") : "")
    }

    /// 稳态下要不要在左耳那枚喇叭旁边补一枚「可跳过」提示(「这个按钮目前只在展开
    /// 状态有;帮我在灵动岛歌词行那里也加一个,虽然移动上去就展开了,但是可以起到提示可以跳过的作用」)。
    ///
    /// 两道门,都是"别把同一件事说两遍":
    ///  ① **展开态不画** —— 那时 `adStatusColumn` 右端就是那颗真的「跳过广告」键,再加一枚图标是重复。
    ///  ② **稳态歌词行画得出来时也不画** —— 开着「显示歌词」的人,稳态那份 `lyricRow` 渲染的就是
    ///     `adStatusColumn`(带真键),同理重复。关着的人稳态只剩顶行,那枚喇叭是广告这件事在卡上
    ///     唯一的落点,提示只能挂在它旁边(用户正是这一档:`notchShowLyrics = 0`)。
    ///
    /// 刻意**只是个标记、不接点击**:稳态下指针一压上来卡片就展开了,这一格根本没有"被点到"的时机,
    /// 做成按钮只会是又一段永不触发的死代码(同喇叭那条、同悬浮窗那排按钮为什么不是 Button)。
    private var showsAdSkipHint: Bool {
        playback.canSkipAd && !controller.isExpanded && !controller.showsLyrics
    }

    /// 没有曲目时左耳里的 App 图标(用户圈图要的「左侧显示我们的图标」)。
    ///
    /// 图标取 `NSApplication.shared.applicationIconImage`(bundle 里的 AppIcon.icns),但**不**直接
    /// `Image(nsImage:).resizable()` 缩 —— 那样 1024px 那档位图会被
    /// SwiftUI 一步线性采样到 ~52px,圆角和音符边缘全是台阶("很有锯齿感")。现在按「pt 边长 × 显示倍率」预先光栅化
    /// 一次(`NotchIdleAppIcon.bitmap`,高质量重采样、按像素边长缓存),`Image(decorative:scale:)` 逐像素
    /// 贴上去,运行期零缩放。不裁圆角、不描边、不投影 —— 它自己就是一枚带圆角方块的 macOS 图标,再套
    /// 一层 `artworkThumbnail` 那圈处理会把它的形状裁掉一截。
    ///
    /// 只是一个"我在这儿"的标记,不接点击:没有曲目时点它能做的事(打开歌词窗口 / 设置)在
    /// hover 展开卡和菜单栏里都有,这里再接一遍是重复目标;读屏也不念(装饰元素)。
    /// 尺寸见 `NotchMetrics.earAppIconSide`。
    @ViewBuilder
    private func idleAppIcon(alignment: Alignment) -> some View {
        let side = NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset)
        let scale = max(1, displayScale)
        Group {
            if let bitmap = NotchIdleAppIcon.bitmap(pixelSide: Int((side * scale).rounded())) {
                Image(decorative: bitmap, scale: scale)
            } else {
                // 理论上到不了:CGContext 建不出来才会 nil。退回原图,至少有东西。
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityHidden(true)
    }

    /// 耳朵里那一排播放控制键。
    ///
    /// 尺寸沿用 `controlButton` 的 `primary` 两档默认值(侧键 glyph 9.5 / 命中 15,播放键 11 / 18)。展开卡里那一排是 22pt,
    /// 比这里大一号,是刻意的(那儿是真正会被点的地方)。
    ///
    /// 横向账(min 宽度下也要放得下):三键 15+18+15 = 48pt,`spacing: 0` —— 命中框本身就比
    /// 图标大一圈(15 的框装 9.5 的图标,两侧各 2.75pt),再加间距会白白撑宽。而耳朵最窄是
    /// **70pt**(`NotchLyricsWindowController.minEarWidth`,宽度滑杆的下界就是按它算的),
    /// 减掉朝刘海那侧 6pt 的内缩还有 64pt,放得下。右耳还要再减音浪那 14pt + 5pt 间距 = 45pt
    /// —— 放不下,所以右耳选控制键时**音浪让位**(见 topRow)。
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
    /// 三条既有规矩原样保留,别在加模块时顺手丢掉:
    ///   ① **广告插播**:歌名位写「广告中」,不展示广告物料的名字;
    ///      歌手/专辑在广告期间一律留空 —— 广告没有"歌手"可言,画上去是假信息。
    ///   ② **压根没有曲目时留白**,不摆 ♪("那个无意义的音符不要占位置")。
    ///   ③ 歌名为空时的 ♪ 兜底只在"有曲目但拿不到歌名"这种边角才到得了,保留。
    private func metadataText(_ module: NotchEarModule) -> String {
        if isIdleNoTrack { return "" }
        let isAd = playback.isCurrentTrackAdBreak
        // 口白:歌名位换成台名,
        // 歌手/专辑留空 —— 理由跟广告那条一模一样,口白没有"歌手"可言,画上去是假信息。
        // 抓不到台卡(`radioTalkStation` 为 nil)就整条不生效,还显示上一首,见 RadioStationCard。
        let station = radioTalkStation
        switch module {
        case .title:
            if isAd { return L10n.t("广告中") }
            if let station { return station.name }
            return playback.displayTitle.isEmpty ? "♪" : playback.displayTitle
        case .artist: return (isAd || station != nil) ? "" : playback.displayArtist
        case .album: return (isAd || station != nil) ? "" : playback.displayAlbum
        // 非文本模块不走这条路(见 earContent 的分发),这里只是把 switch 补齐。
        case .artwork, .controls, .elapsed, .remaining, .playCount, .player, .none: return ""
        }
    }

    /// 口白期间顶替曲目卡的台名 / 台标。抓不到台卡就是 nil —— 那时一切照旧(还显示上一首),
    /// 宁可保持现状也不要编一个台名出来,判据与实测见 `RadioStationCard`。
    private var radioTalkStation: (name: String, image: NSImage?)? {
        guard playback.isRadioTalkBreak, let name = playback.radioStationName, !name.isEmpty else { return nil }
        return (name, playback.radioStationImage)
    }

    /// 歌词行、展开头部那两枚封面画哪张图:电台口白期间换台标,其余高清图优先、退到普通那张。
    private var displayedArtworkImage: NSImage? {
        radioTalkStation?.image ?? playback.highResArtworkImage ?? playback.artworkImage
    }

    /// 已播 / 剩余。位置口径跟卡片里那条迷你进度条同源:锚点外推 ?? 暂停冻结位置;歌词时间轴
    /// 偏移**不适用**(那是歌词的事,不是播放进度的事,别顺手加上去)。时长未知(播客/流)时
    /// 剩余算不出来,整块留白而不是画个 `--:--` 占位 —— 不为拿不到的数据编一个占位符,跟预览
    /// 那条"不编造假进度"是同一个态度。
    ///
    /// 同源**不等于**逐帧同值,两处已知的差:
    ///   - **拖动进度条时**:进度条画的是拖到哪儿(它自己的 `@GestureState`,私有),耳朵画的仍是
    ///     真实播放位置。不把拖动状态提上来是刻意的 —— 那要么把私有手势状态提到整卡这一层
    ///     (整卡跟着每个指针事件重估,正是那轮性能审计修掉的东西),要么再拉一条通道。
    ///   - **剩余时长的时长来源**:这里用 `playback.currentDurationMs`,进度条用 `anchor.durationMs`。
    ///     正常一致,但这是第二个可漂的点,改任一处时对一下另一处。
    ///
    /// **广告插播时照常显示**,不套用 `metadataText` 那条"广告期间歌手/专辑留空"的规矩:
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
    /// 跑马灯走图层(`LayerMarquee`),按窗口可见性停(05 章决策 99)。
    ///
    /// 等宽数字**只给时间类**。给歌名/歌手/专辑也套上的话,带数字的名字("M83"、
    /// "24K Magic")字形会被静默改掉 —— 而前提是"默认配置逐像素稳定"。
    /// 时间类必须套:不套的话每秒跳一格数字宽度就变、整行跟着抖。
    /// 条件收进 **Font 值本身**(`Font.monospacedDigit()` 返回 Font),不走 `if/else` 也不走
    /// `ViewModifier` + `AnyView`:那两种都会在视图树上多一层类型/身份变化,而这里变的只是
    /// 一个字体属性。(一度写成 `ConditionalMonospacedDigit` 那样一个 modifier,
    /// 附的理由是"避免分支切换整块重建" —— 那个理由是假的:`isClock` 一变,上面 `earContent`
    /// 的分支本来就先换了,子树无论如何都要重建。)
    private func earText(_ text: String, module: NotchEarModule, alignment: Alignment) -> some View {
        let base = Font.system(size: 11.5, weight: module.isPrimary ? .semibold : .medium)
        return LayerMarquee(id: text, restingAlignment: alignment, isActive: surfaceVisible) {
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

    // 歌词行尾端(卡片右下角)那枚专辑封面小图。
    //
    // 位置选在这里而不是顶行歌名左边:顶行左耳的可用宽度是 (窗口宽 - 刘海宽 - 20) / 2,默认 360pt 宽配 179pt 刘海只有 80.5pt,
    // 放进一枚小图连间距要占掉四分之一以上,歌名被挤得只剩 50 多 pt。歌词行是整条 360pt(去掉左右各 16pt padding 还有 328pt)、
    // 行高 44pt,同一枚封面在这里能做到 32pt 见方而只占掉歌词 12.8% 的宽度,视觉上也正好落在卡片右下角这个空着的位置上。
    //
    // 稳态下这里就是卡片的右下角;hover 展开时下面会再长出"下一句预览+进度条"那一块,封面保持钉在歌词行内不动(不跟着卡片底边
    // 往下跑),避免鼠标一进一出封面就上下跳。
    //
    // 没有封面数据时不画占位方块、直接连位置一起不占:播放中绝大多数曲目都拿得到封面(拿不到的是本来没有封面的播客/取图失败这类
    // 少数情况),为少数情况长期锁掉一块位置画一个空方块不值得。换歌时不会"封面消失再出现":换歌那一刻旧封面会一直留着直到新封面
    // 取回来(见 LocalPlaybackSource 的 scheduleArtworkStaleTimeout/artworkRetryDelays),只有"启动后第一首"和"这首歌真的没有封面"
    // 两种情况才会真的发生一次宽度增减。
    //
    // 描边 + 投影是给"卡片背景可能是浅色"兜底:磨砂玻璃风格会透出桌面颜色,浅色壁纸下一张浅色封面直接贴上去边界会糊成一片,
    // 一圈极淡的白描边能把方块轮廓钉住。
    /// side:不给就按歌词行那一档(32pt)。耳朵里那枚要小一号,理由见 earArtwork。
    ///
    /// 图不在运行期缩:`Image(nsImage:).resizable().scaledToFill()` 把 600px 的封面一步缩到 46px 走的是线性采样、没有面积平均,
    /// 半调网点封面(黄底黑点那种)缩出来是一片摩尔纹黑斑,而且随展开动画里的亚像素相位一帧一个样。按目标像素边长预先重采样一次
    /// (`ArtworkThumbnailCache` → `ArtworkThumbnail.squareBitmap`,`.high` 插值),`Image(decorative:scale:)` 逐像素贴,跟左耳
    /// App 图标(`NotchIdleAppIcon`,决策 #30)同一招。裁方(aspect-fill 居中裁)也在位图里做,所以这里不 `.scaledToFill()`;
    /// `.frame` 仍钉一次,`clipShape` 才按这枚的尺寸裁圆角。悬停 / 按下反馈的状态由 `HoverReveal` 持有而不是放在本视图上,理由见
    /// 那个壳的注释(这是函数,三处调用点共用)。
    private func artworkThumbnail(_ image: NSImage, side: CGFloat? = nil) -> some View {
        let side = side ?? Self.artworkSide(rowHeight: controller.lyricRowHeight)
        return HoverReveal { hovering in
            artworkButton(image, side: side, hovering: hovering)
        }
    }

    /// 封面键的本体。拆成单独一个函数只为**不给下面这四十行整体缩进**:壳套在外面、本体原位不动,
    /// diff 就只有签名和 buttonStyle 两行(这个文件同时有别的会话在改,小 diff 是硬要求)。
    private func artworkButton(_ image: NSImage, side: CGFloat, hovering: Bool) -> some View {
        let scale = max(1, displayScale)
        // 点封面 → 打开歌词窗口。走 AppActions 统一入口,激活
        // 时序(先 NSApp.activate 再 openWindow)在注册处已处理,跟快捷键/菜单/面板同路。
        return Button {
            AppActions.shared.openLyricsWindow?()
        } label: {
            Group {
                if let bitmap = ArtworkThumbnailCache.bitmap(for: image, pixelSide: Int((side * scale).rounded())) {
                    Image(decorative: bitmap, scale: scale)
                } else {
                    // 理论上到不了:CGContext 建不出来才会 nil。退回运行期缩放,至少有图。
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
                .frame(width: side, height: side)
                // 这一格只画静态封面,别叠动态封面(MotionCoverView):这一格最大也就 NotchExpandedMetrics.trackInfoArtworkSide 这个量级
                // (耳朵那档只有 32pt),Apple 的 motion artwork 是给整张专辑封面设计的慢镜头,缩到这么小基本只剩一片蠕动的色块,
                // 看不出画的是什么。歌词窗口那张 460pt 的卡才是它该出现的地方(03 章第 6 节)。
                .clipShape(RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous))
                // 那圈 0.18 白描边搬进了 `NotchArtworkButtonStyle` —— 它现在要随悬停 / 按下
                // 抬亮(0.18 → 0.38 → 0.5),留在标签里只能是定值。
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
        }
        .buttonStyle(NotchArtworkButtonStyle(cornerRadius: NotchMetrics.artworkCornerRadius,
                                             hovering: hovering))
        .help(L10n.t("打开歌词窗口"))
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
            // 曲目信息头部(歌名/歌手/专辑):画在歌词行**之上**——"新加的这些字段元素都是
            // 在最上面,然后歌词行和下一行歌词这些都放在最下面"。只在展开时可见:展开是用户主动选的动作。
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

    /// 歌词行,外面包一层瞬态横幅:有瞬态提示(改歌词偏移/调音量)时这一行让位给提示条,提示到期再换回歌词。只盖歌词行、
    /// 不动卡片高度和顶行控件:提示是"顺带说一句",不该让整块卡片跳一下。
    private func lyricRow(reportsWidth: Bool) -> some View {
        // NotchTransientCenter 的订阅下沉在 NotchTransientHost 子视图里 —— 横幅出现/
        // 消失(音量连调时每档一次)只失效歌词行,不打醒整卡 body。
        NotchTransientHost(tint: accentOrWhite) {
            lyricRowContent(reportsWidth: reportsWidth)
        }
    }

    private func lyricRowContent(reportsWidth: Bool) -> some View {
        HStack(spacing: NotchMetrics.artworkLyricSpacing) {
            // 封面贴左还是贴右可配(`notchLyricRowShowsArtwork` / `notchLyricRowArtworkPosition`,见 NotchPlayback 的注释),默认贴右、
            // 默认开:升级上来的人不能发现封面凭空挪位或消失。
            if playback.lyricRowArtworkPosition == .left { lyricRowArtwork }
            // restingAlignment = 「对齐方式」。只管**装得下**的短句靠哪边:
            // 溢出的句子跑马灯一律按 .leading 起滚(理由见 `MarqueeText.restingAlignment` 的注释,靠右摆等于
            // 一上来就把开头几个字挂在容器外面),所以这一项在长句上天然无效果 —— 跟菜单栏
            // 同名设置是同一条语义,help 文案里说明了。
            //
            // 对齐的参照系是**歌词这一格**,不是整张卡:封面是这个 HStack 的兄弟,它占掉的
            // 那 42pt(32 封面 + 10 间距)不在跑马灯的容器里。所以开着封面选「居中」时,
            // 文字是在"除封面之外的剩余宽度"里居中、相对整卡略偏封面对侧。这是刻意的 ——
            // 要相对整卡居中就得把封面改成 overlay 叠在歌词上,那会直接违反上面那段
            // `.animation(nil, value)` 治的"封面遮挡歌词"。
            // 广告插播:这一格整个换成「📣 广告中 · 还剩 0:21   [跳过广告]」,不走歌词那套
            // (副行 / 跑马灯 / 逐字染色对广告全无意义)。分流放在这一层而不是 `mainLyricLine` 的那个
            // 「广告中」分支里,因为倒计时和跳过键要占满这一格的宽度,而那个分支只是一段文字。
            Group {
                if playback.isCurrentTrackAdBreak {
                    adStatusColumn
                } else {
                    lyricTextColumn
                }
            }
            // 跑马灯按被提议的宽度定尺寸(能吃下任何宽度),HStack 会先给定尺寸的封面分配它那 32pt,
            // 剩下的宽度都留给歌词。这里仍然显式写一次 maxWidth: .infinity 把"歌词吃掉剩余宽度"
            // 这个意图钉死,不依赖它在 stack 里的隐式伸缩行为。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if reportsWidth { LineLayoutWidthReporter() }
            }
            if playback.lyricRowArtworkPosition == .right { lyricRowArtwork }
        }
        .padding(.horizontal, NotchMetrics.expandedContentInset)
        // 封面在场性的变化必须是瞬时的,不能落进任何补间,否则歌词会被封面挡住一截。
        //
        // 机制:封面是这个 HStack 的**条件兄弟**。它从不在场变在场时,SwiftUI 把它当结构性
        // 插入 —— 新插入的视图**一帧就落在终态位置**;而歌词那一侧的 frame(以及跟着 frame
        // 走的跑马灯裁剪边界)是被**动画平滑收缩**的,要花整条弹簧
        // 才从"没有封面时"的宽度收到"有封面时"的宽度。这段时间里歌词被裁到更靠右的旧边界,
        // 那一截字正好画在已经就位的封面**底下** —— HStack 里靠后的兄弟盖在前面的上面。
        //
        // 独立最小复现(SwiftUI,同构的 HStack + GeometryReader/.clipped 弹性子 + 32pt 定宽
        // 兄弟,弹簧刻意放慢到 3s 便于逐帧抓):封面到位那一帧文字右边界仍停在旧位置(623px),
        // 要 4 帧才收到终态 603px,90 帧里 25 帧文字被压在封面底下;加上这一行 .animation(nil,)
        // 之后同样 90 帧 **0** 帧遮挡,四次插入全部一帧到位。
        //
        // 触发窗口:必须"封面在场性变化"和某条活动动画落进**同一次** SwiftUI 更新 —— 把两者
        // 错开 300ms 复现同样是 0/90。现实里够得着这个窗口的有两处:
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
        // value 必须是"封面这一刻实际占不占位"这个合成布尔(开关 && 有数据),不能只看数据:开关关着时数据端的有无变化不该触发
        // 任何布局动作,只 key 数据端的话,开关重新打开的那一刻可能撞上活动动画的同一次更新窗口。
        .animation(nil, value: !lyricRowArtworkPresent)
    }

    /// 广告插播时歌词那一格的内容:
    ///
    ///     广告中 · 还剩 0:21                                 [⏭ 跳过广告]
    ///
    /// * 左边是这一态唯一有信息量的东西:还要多久结束。倒计时按 1Hz 走(`adCountdown`),跟耳朵里的时间模块同一套调度
    ///   (`NotchTimeFormat.clockSchedule`,相位对齐到曲目位置的整秒,跟正下方进度条同源同相),暂停时冻结、时长未知时不编数字。
    ///   这一行不带图标:左耳那枚喇叭在广告期间恒显示,同一张卡上再画一枚是重复。字号 / 七成不透明 / 投影跟 `mainLyricLine` 里
    ///   那个「广告中」分支逐字相同:稳态(不展开)时这一行也是这一格,用户看到的是同一句话变成了带倒计时的版本,不是一套新版式。
    /// * 右边那颗「跳过广告」只在 `playback.canSkipAd` 时出现:广告中且这是 YT Music 网页广告(`YouTubeMusicAdSkipper.isYouTubeMusicAd`,
    ///   探针强信号)且页面此刻真的放出了跳过键(`adSkipAvailable`,不可跳过的广告上不挂键)。Spotify 的广告没有可点的东西,不给键。
    ///   点了去点页面自己的跳过按钮(`NotchPlayback.skipAd`,不做拖到结尾那种绕过),结果用瞬态横幅回报。
    /// * 头部在广告期间只剩快捷操作那排键(`trackInfoShowsTrackFields`),状态文字只在这一行出现。广告期间全 App 四个封面位都让位
    ///   给同一枚 `megaphone.fill`(`adBreakArtworkTile` 等,清单见 05 章「广告态」⑦);这一列自己不画封面。
    private var adStatusColumn: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                // 这一格**不画喇叭**:广告期间左耳那枚(`adBreakEarIcon`)是无条件画的
                // (`isAdBreakNow` 那条分支不看配置、不看原本有没有内容),两枚并排在同一张卡上
                // 就是把同一件事说了两遍。留文字这一路 —— 它带着计数和倒计时,是这一态唯一有信息量的东西。
                //
                // 字体跟歌词主行同一份派生值:这一格就是歌词那一格换了内容,用户换了字体后它不该
                // 突然变回系统字体。倒计时那截同字号、细一档(`mainDetailFont`),保住 semibold / medium 的主次。
                Text(L10n.t("广告中"))
                    .font(playback.mainFont)
                adSlotText
                    .font(playback.mainDetailFont)
                adCountdown
                    .font(playback.mainDetailFont)
            }
            .foregroundStyle(accentOrWhite.opacity(0.7))
            .notchTextShadow()
            .lineLimit(1)
            Spacer(minLength: 0)
            if playback.canSkipAd {
                NotchPillButton(systemName: "forward.end.fill", title: L10n.t("跳过广告"), tint: accentOrWhite) {
                    playback.skipAd()
                }
                // 正在跑(点 + 复核)时压淡、不接第二下,理由见 `NotchPlayback.skipAdInFlight`。
                .opacity(playback.skipAdInFlight ? 0.45 : 1)
                .disabled(playback.skipAdInFlight)
            }
        }
    }

    /// 「· 还剩 0:21」。来源见 `playback.adCountdown`:广告本身就是一首曲目的(Spotify、YouTube Music 网页版)按曲目算,
    /// 位置口径同 `clockText`(锚点外推 ?? 暂停冻结位置);Kaset 的广告跟接下来那首歌共用身份,曲目时长是那首歌的,按广告
    /// 自己的那只表(`AdBreakClock`,内嵌网页报的时长与进度)算;拿不到时长就整个不画(不为拿不到的数据编占位)。
    /// TimelineView 只在这一层可见(层内读的 `notchCardLayerActive`)时才排表 —— 收起态 / 编辑台预览都不该有一张每秒空转的表
    /// (理由同 `earContent` 时间模块那条)。采样用 `Date()` 而不是 `context.date`,理由见 `earContent` 头注第 ③ 条。
    private var adCountdown: some View {
        NotchLayerActiveReader { active in
            switch playback.adCountdown {
            case .own(let clock):
                // 暂停时停在取样那一刻:这只表纯按墙钟外推、每次轮询重建,暂停着照推的话每秒减 1、每次轮询又跳回去。
                if !playback.isPlayingNow {
                    Text(adRemainingText(total: clock.durationMs, position: clock.positionMs))
                } else if active {
                    TimelineView(.periodic(from: clock.capturedAt.addingTimeInterval(-NotchClockPhase.msSinceBoundary(
                        positionMs: Double(clock.positionMs), countdownFromMs: clock.durationMs) / 1000), by: 1)) { _ in
                        Text(adRemainingText(total: clock.durationMs, position: clock.positionMs(now: Date())))
                    }
                } else {
                    Text(adRemainingText(total: clock.durationMs, position: clock.positionMs(now: Date())))
                }
            case .unknown:
                EmptyView()
            case .track:
                if let total = playback.currentDurationMs, total > 0 {
                    if let anchor = playback.anchor, active {
                        TimelineView(NotchTimeFormat.clockSchedule(for: anchor, countdownFromMs: total)) { _ in
                            Text(adRemainingText(total: total, position: anchor.extrapolatedPositionMs(now: Date())))
                        }
                    } else if let position = playback.anchor?.extrapolatedPositionMs(now: Date()) ?? playback.pausedPositionMs {
                        Text(adRemainingText(total: total, position: position))
                    }
                }
            }
        }
    }

    private func adRemainingText(total: Int, position: Int) -> String {
        "· " + String(format: L10n.t("还剩 %@"), NotchTimeFormat.mmss(ms: max(0, total - position)))
    }

    /// 「这是插播里的第几条」,排在「广告中」和倒计时之间,连起来读是「广告中 · 1/2 · 还剩 0:20」。
    ///
    /// 字号跟倒计时同一档(`mainDetailFont`,主行同字号细一档),两段都是"广告中"这句话的补充说明,不该有各自的字重。
    ///
    /// 写成 `1/2` 而不是「还剩 1 条」:它跟 YouTube 自己徽章上的写法逐字一致,用户在页面上看到什么、在灵动岛上就看到什么,不用在
    /// 心里做减法;而且纯数字不需要新增本地化文案。
    ///
    /// 拿不到就整段不画:只有 YT Music 网页广告给得出这个数,Spotify 恒 nil,YT Music 英文界面(`Ad 1 of 2`)也抓不到。宁可少一段,
    /// 不编。
    @ViewBuilder
    private var adSlotText: some View {
        if let slot = playback.currentAdSlot {
            Text(verbatim: "· \(slot.index)/\(slot.total)")
        }
    }

    /// 歌词这一格:副行关着就是改动前那一行跑马灯(逐像素不变);副行开着(
    /// 方案二)就在它下面再放一行 11pt 的副行,两行 + 3pt 间距 = 31pt,竖直居中塞进
    /// 44pt 的行里,**行高不变** —— 这是选方案二而不是叠行方案的全部理由:不动 `cardHeight`、
    /// 编辑台舞台常量、出场动画这片高度体系(05 章决策 22)。
    /// 主行那一格的高度随「字号」走(`playback.mainLineHeight`,11…17pt → 13…19pt),两行最多 35pt,
    /// 仍在 44 里、上下各余 ≥ 4pt —— 字号范围就是按这条倒推的,Core 有 selftest 钉着。
    @ViewBuilder
    private var lyricTextColumn: some View {
        if playback.secondaryLine.showsSecondaryRow {
            VStack(alignment: .leading, spacing: NotchLyricRowMetrics.lineSpacing) {
                mainLyricLine
                    .frame(height: playback.mainLineHeight)
                secondaryLyricLine
                    .frame(height: NotchLyricRowMetrics.secondaryLineHeight)
            }
        } else {
            mainLyricLine
                .offset(y: -NotchMetrics.singleLineOpticalLift)
        }
    }

    /// 主行本体,从 `lyricRowContent` 拆出来给副行让位。用这一行纯文本(不含逐字填色进度)当跑马灯的 id:换到新的一句才重新
    /// 测量/重新开始滚动,同一句内部逐字变色的高频刷新不打断正在进行的滚动。
    /// restingAlignment 与 edgeFadeWidth 的理由见 `lyricRowContent` 里紧挨着 `lyricTextColumn` 的那段注释。
    ///
    /// 没有逐字时间的行走图层跑马灯(`LayerMarquee`),只按窗口可见性停、不按所在那一层停:稳态 / 展开两份靠透明度轮流显示,
    /// 按层停会让长句在悬停展开时跳回开头;藏着那份的图层动画不占主线程。它的内容不继承这里的环境,字体要在里面再写一次(05 章决策 99)。
    private var mainLyricLine: some View {
        NotchLayerActiveReader { layerActive in
            if let words = playback.displayLine?.words, !words.isEmpty {
                layerKaraokeLine(words: words, layerActive: layerActive)
            } else {
                LayerMarquee(id: playback.displayLine?.plainText ?? "",
                             edgeFadeWidth: NotchMetrics.lyricEdgeFadeWidth,
                             restingAlignment: playback.mainLyricAlignment,
                             loops: false,
                             isActive: surfaceVisible) {
                    lyricContent(layerActive: layerActive)
                        .font(playback.mainFont)
                }
            }
        }
        // 字体 / 粗细 / 字号三件由设置决定,默认是 13pt semibold。里面那几个状态占位
        // 文字(纯音乐 / 暂无歌词 / …)和逐字染色的每个字都从这里继承字体,不各自再写。
        .font(playback.mainFont)
    }

    /// 有逐字时间轴的主行:走 AppKit 图层(`OverlayScrollingLyricRow`,悬浮歌词滚动模式那一套),
    /// 整行画成长图、逐字填色与跟唱滚动各一条 CAKeyframeAnimation,装好之后主线程不再按帧参与。
    ///
    /// 不用 `MarqueeText` 包 30Hz `TimelineView`、每个字一个渐变 `Text`:灵动岛窗口里任何一个逐帧子视图都会带着整窗每拍布局 +
    /// 提交一遍,那样这条逐字填色是灵动岛开销的大头。
    ///
    /// 跟 SwiftUI 版逐项对齐的:字体(`mainNSFont` = `mainFont` 的 AppKit 版)、已唱 = `accentOrWhite`、未唱 = 它的
    /// `WordKaraokeGradient.dimOpacity`、整行阴影(黑 0.45 / 半径 2 / 下移 1,同 `lyricContent` 里那条 `.compositingGroup().shadow`)、
    /// 溢出时尾部渐隐(`lyricEdgeFadeWidth`)、装得下时按「对齐方式」静置、停表判据(同 `lyricFollow`)。不同的一处:已唱 / 未唱的
    /// 交界是硬边(悬浮歌词滚动模式、菜单栏同款),没有 SwiftUI 版那条 `wordEdgeSoftenBand` 软过渡。
    private func layerKaraokeLine(words: [SyncedLyricWord], layerActive: Bool) -> some View {
        let fg = NSColor(accentOrWhite)
        let side: LyricDuet.Side
        switch playback.mainLyricAlignment.horizontal {
        case .leading: side = .leading
        case .trailing: side = .trailing
        default: side = .center
        }
        return OverlayScrollingLyricRow(
            spec: .init(
                lineKey: playback.displayLine?.plainText ?? "",
                words: words,
                groups: nil,
                font: playback.mainNSFont,
                romaFont: playback.mainNSFont,
                baseColor: fg.withAlphaComponent(fg.alphaComponent * WordKaraokeGradient.dimOpacity),
                fillColor: fg,
                romaBaseColor: fg,
                romaFillColor: fg,
                strokeColor: nil,
                alignment: side,
                paused: !playback.lyricsClockRunning || playback.currentLineFillSettled || !layerActive,
                shadow: .init(color: NSColor.black.withAlphaComponent(0.45), radius: 2, offsetY: 1),
                edgeFadeWidth: NotchMetrics.lyricEdgeFadeWidth,
                timingEpoch: LyricsTimingEpoch.of(anchor: playback.anchor, pausedPositionMs: playback.pausedPositionMs,
                                                  offsetMs: playback.lyricsOffsetMs),
                rate: playback.playbackRate),
            nowMs: Self.lyricsNowMs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: playback.displayLine?.plainText ?? ""))
    }

    /// 歌词读的播放位置,图层行、间奏三点、音浪振幅共用这一份:锚点外推 ?? 暂停冻结位置 ?? `fallbackMs`,再叠歌词时间轴偏移。
    /// 直读协调器、不经窄代理订阅:锚点重建会打醒整卡 body,而这里只要调用那一刻的快照。
    private static func lyricsPositionMs(at date: Date, fallbackMs: Int = 0) -> Int {
        let coordinator = PlaybackCoordinator.shared
        return (coordinator.anchor?.extrapolatedPositionMs(now: date) ?? coordinator.pausedPositionMs ?? fallbackMs)
            + coordinator.currentLyricsOffsetMs
    }

    private static func lyricsNowMs() -> Int { lyricsPositionMs(at: Date()) }

    /// 副行:下一句 / 当前句译文 / 当前句罗马音(由 `NotchPlayback.secondaryText` 按设置选好)。
    /// **不滚动**:装不下就尾部省略号 —— 主行已经是一条跑马灯,两条同时动太乱;而且它是"提前看一眼"
    /// 的辅助信息,不是要逐字跟唱的正文。对齐跟主行吃同一个「对齐方式」设置(展开态那行「下一句」
    /// 预览也是,selftest 钉着 `swiftUIAlignment` 的接线处数)。取不到内容时留空不缩高。
    /// 三档透明度沿用悬浮歌词那三行的口径(下一句那边 40%,这里 45% —— 11pt 在深底上再淡就看不清了;
    /// 译文 75%、罗马音 60% 照抄)。
    private var secondaryLyricLine: some View {
        Text(playback.secondaryText ?? "")
            // 固定 11pt、比主行细一档,只跟主行的字体族与粗细(理由见 NotchLyricRowMetrics.secondaryFontSize)。
            .font(playback.secondaryFont)
            .lyricTypesetting(playback.secondaryText, translation: playback.secondaryLine == .translation)
            .foregroundStyle(accentOrWhite.opacity(secondaryLineOpacity))
            .notchTextShadow()
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: playback.secondaryLyricAlignment)
    }

    private var secondaryLineOpacity: Double {
        switch playback.secondaryLine {
        case .off, .nextLine: return 0.45
        case .translation: return 0.75
        case .romanization: return 0.6
        }
    }

    /// 歌词行末尾(或开头)那枚封面缩略图,就有、到之间
    /// 固定显示,现在受 `notchLyricRowShowsArtwork` 开关控制。没有封面数据(没曲目/取图
    /// 失败)或开关关着时都不画占位方块,理由见 `artworkThumbnail` 上面那段。
    @ViewBuilder
    private var lyricRowArtwork: some View {
        if playback.lyricRowShowsArtwork {
            if controller.isAdBreakNow {
                // 广告期间这一格换成广告标识:播放器在广告时给的图是广告物料的缩略图,不是"这一刻在听什么"的封面,四个封面位统一让位
                // 给同一枚喇叭。开关(`notchLyricRowShowsArtwork`)仍然管这一格在不在:关了就还是不画,广告不该把用户关掉的东西请回来。
                adBreakArtworkTile(side: Self.artworkSide(rowHeight: controller.lyricRowHeight))
            } else if let image = displayedArtworkImage {
                artworkThumbnail(image)
            }
        }
    }

    /// 广告期间顶替封面的那枚方块。外框跟 `artworkThumbnail` 逐项对齐(同一个
    /// 圆角、同一道 0.5pt 白描边、同一层投影),这样广告开始/结束时这一格只是内容换了、
    /// 几何一点不动;里面是跟状态行、跟左耳同一枚 `megaphone.fill`。
    /// 不接点击:`artworkThumbnail` 那枚点了会打开歌词窗口,而广告没有歌词可看。
    private func adBreakArtworkTile(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous)
            .fill(.white.opacity(0.10))
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: "megaphone.fill")
                    .font(.system(size: side * 0.44, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NotchMetrics.artworkCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .accessibilityHidden(true)
    }

    /// 上面那枚封面此刻是不是真的占着一个位置——给 `.animation(nil, value:)` 当判据用,
    /// 见那一行的注释。
    private var lyricRowArtworkPresent: Bool {
        // 广告期间那枚替代方块同样占着这个位置(见 lyricRowArtwork),判据要跟着算上,
        // 否则 `.animation(nil, value:)` 会以为这一格是空的、放行一次不该有的布局动画。
        playback.lyricRowShowsArtwork
            && (controller.isAdBreakNow
                || displayedArtworkImage != nil)
    }

    private func lyricContent(layerActive: Bool) -> some View {
        Group {
            // 有逐字时间轴的行不走这里:`mainLyricLine` 先分流到图层行(`layerKaraokeLine`)。
            if playback.isCurrentTrackAdBreak {
                // 同 LyricsOverlayView.mainLine 的区分,必须排在"还在搜索中"分支前面,
                // 见 PlaybackCoordinator.isCurrentTrackAdBreak 定义处的注释。
                // 广告态在 `lyricRowContent` 那一层就分流到 `adStatusColumn` 了,这个分支
                // 正常到不了;留着当兜底(顺序契约不变),别删。
                Text(L10n.t("广告中"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.isRadioTalkBreak {
                // 电台口白:这首歌已经放完、台里在说话。必须排在"还在搜索中"之前,
                // 理由同上面那条广告分支 —— 口白期间元数据还停在上一首,不拦就会显示成
                // 「搜索歌词中…」。收歌词的判定在 LocalPlaybackSource.radioTrackFinished。
                Text(L10n.t("口白"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.isCurrentTrackInstrumental {
                // 同 LyricsOverlayView.mainLine 的区分,必须排在"还在搜索中"分支前面,
                // 见 PlaybackCoordinator.isCurrentTrackInstrumental 定义处的注释。
                Text(L10n.t("纯音乐"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.currentTrackHasNoLyrics {
                // 搜完了、确实一句都没有,同 LyricsOverlayView.mainLine 的同名分支——
                // 必须排在下面那个"搜索歌词中…"前面。
                Text(playback.hasPlainLyrics ? L10n.t("仅有纯文本，无时间戳") : L10n.t("暂无歌词"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.engineNetworkDown && !playback.hasLyricsContent {
                // 顺序理由同 LyricsOverlayView.mainLine 里那段:必须排在"搜索歌词中…"
                // 之前、"暂无歌词"之后。
                Text(L10n.t("网络连接失败"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else if playback.isPlayingNow && !playback.hasLyricsContent {
                // 同 LyricsOverlayView.mainLine 的区分:currentLine==nil 可能是"还没解析
                // 出这首歌的歌词"(引擎后台搜索中,见 PlaybackCoordinator.hasLyricsContent 注释),
                // 不能跟"这首歌真没歌词/正在间奏"共用同一个♪占位符。
                Text(L10n.t("搜索歌词中…"))
                    .foregroundStyle(accentOrWhite.opacity(0.7))
                    .notchTextShadow()
            } else {
                // 前奏/间奏占位符:跟悬浮歌词一样用三点动画(LyricsGapDotsView)。displayLine 为 nil 的成因这里天然合流:
                // 单行面的长间奏中段(唱完了、下一句还早)、"这一刻不在任何一句上"、
                // 以及副行开着时的前奏和够格的间奏(见 LyricSecondaryLine.currentLine(_:inMarkedInterlude:))。
                // 但压根没有曲目时它什么都不代表,留白。上面那一长串 else-if 已经把
                // 广告/纯音乐/无歌词/断网/搜索中都各自接走了,能落到这里的空态只剩"没有曲目"。
                if let plainText = playback.displayLine?.plainText {
                    Text(plainText)
                        .foregroundStyle(accentOrWhite)
                        .lyricTypesetting(plainText)
                        .notchTextShadow()
                } else if !isIdleNoTrack, let raw = playback.rawGapWindow {
                    let window = playback.secondaryLine.gapDotsWindow(raw, compactPlaceholder: playback.compactShowsPlaceholder)
                    // 尺寸按字号等比,别写死:歌词窗口字号至少 22(见 lyricFontSize),它那边 8pt 只相当于 0.36 倍字号;灵动岛主行只有
                    // 13pt(范围 11…17),同样画 8pt 就是 0.62 倍,呼吸到最大(×1.28)时逼近 10pt、在 15pt 的行高里比歌词本身还抢眼。
                    //
                    // 比例取 0.40 而不是歌词窗口 / 悬浮歌词那边的 0.32:小字号要补偿。那两处字号 22~38,0.32 出来是 7~12pt;灵动岛 13pt
                    // 照搬只剩 4.2pt,在 15pt 行高里弱到像三粒灰尘。0.40 = 5.2pt,还看得出是三颗会呼吸的圆点。spacing 跟着取 0.375,
                    // 维持两处一贯的「间距≈0.94 倍点径」手感。
                    LyricsGapDotsView(
                        startMs: window.startMs, endMs: window.endMs,
                        dotSize: playback.mainFontSize * 0.40,
                        spacing: playback.mainFontSize * 0.375,
                        color: accentOrWhite,
                        isPlaying: playback.lyricsClockRunning, isVisible: layerActive,
                        reduceMotion: reduceMotion,
                        timingEpoch: LyricsTimingEpoch.of(anchor: playback.anchor, pausedPositionMs: playback.pausedPositionMs,
                                                          offsetMs: playback.lyricsOffsetMs),
                        rate: playback.playbackRate,
                        // 同这一格其它占位文字的 `notchTextShadow()`;
                        // 三点现在画在原生图层上(见 LyricsGapDotsView 头注),SwiftUI 的 .shadow 罩不到,由图层自己投。
                        shadow: .init(color: NSColor.black.withAlphaComponent(0.45), radius: 2, offsetY: 1)
                    ) { date in
                        Self.lyricsPositionMs(at: date, fallbackMs: window.startMs)
                    }
                } else {
                    Text(isIdleNoTrack ? "" : "♪")
                        .foregroundStyle(accentOrWhite)
                        .notchTextShadow()
                }
            }
        }
        .lineLimit(1)
    }

    /// 灵动岛音浪的振幅:这一刻有没有字正在唱。
    ///
    /// 输入全部直读 `PlaybackCoordinator.shared`,**不经窄代理订阅** —— 跟同文件里逐字填色
    /// 那个 TimelineView 闭包同一个取舍(见 lyricRow 里 currentMs 那段注释):锚点重建会打醒
    /// 整卡 body,而这里只需要"调用那一刻的快照"。
    ///
    /// 形状由 `VocalEnvelope`(LyrimuseCore,selftest 覆盖)决定:字内稳态 1 + 起音脉冲、字间从 1
    /// 指数泄放到 0.6、没有逐字 1。取舍见 VocalEnvelope 头注(字内稳态刻意不动:按已唱比例插值反而更不像人声)。
    /// 这里只剩"读协调器快照、算位置、交给 Core":XxxxView 里不放数学,是仓库的分层边界。
    private static func vocalAmplitude(at date: Date) -> Double {
        let coordinator = PlaybackCoordinator.shared
        guard let words = coordinator.currentLine?.words, !words.isEmpty else {
            return VocalEnvelope.idleAmplitude
        }
        // 位置口径必须跟逐字填色一致,否则条子跟高亮的字对不上。
        return VocalEnvelope.amplitude(atMs: lyricsPositionMs(at: date), words: words)
    }


    /// 灵动岛里几乎所有前景元素的颜色,见 NotchPlayback.accent。除了封面缩略图的描边(刻意的,见 artworkThumbnail 注释:磨砂玻璃
    /// 风格下要给浅色封面兜一圈可见轮廓),前景都走这里:状态文字跟正常歌词在同一个 Group 里,一处写死白色,同一行就会出现
    /// "有歌词时跟着封面色、一旦变成「暂无歌词」就突然跳回白"的闪动。
    private var accentOrWhite: Color {
        // 组合逻辑(风格是不是「跟随封面」× 动态主色)已下沉进 NotchPlayback.accent 预组合去重,这里只是个语义化的别名。
        playback.accent
    }

    // hover 展开时多出来的这一块——下一句歌词预览 + 迷你进度条,用来强化"这是个歌词类
    // 产品"而不是退化成通用媒体控制器;进度条属于"有余量就加"的加分项。
    //
    // 曲目信息头部(歌名/歌手/专辑)**不在这里**——它在 body 里 lyricRow 前面,是一个
    // 独立的 `trackInfoHeader` 块(见 body 那段注释)。这里因此永远传
    // `trackInfoHeight: 0`——那部分高度已经在 `expandedTrackInfoHeaderHeight` 那份独立
    // 的 `.frame(height:)` 里算过一次。
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // `showsExpandedLyricPreview` 这一条跟下面 .frame(height:) 里留不留这行的高度
            // 是**同一个值**(协议扩展里那份),别在这里换成别的判据。没有下一句(最后一句)时照样占这一行、
            // 画一个空格,进度条和控制键不往上挪。见 05 章决策 75。
            if controller.showsExpandedLyricPreview {
                Text(nextLineDisplayText.isEmpty ? " " : nextLineDisplayText)
                    // 跟副行同一个派生字体:它俩是同一类"辅助的下一句",字号不随主行变、粗细细一档。
                    .font(playback.secondaryFont)
                    .lyricTypesetting(nextLineDisplayText)
                    .foregroundStyle(accentOrWhite.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 「对齐方式」也管这一行。不能只改主歌词行:那样选了「居中」之后主行居中、这一行还贴着左边,看起来就是没做完
                    // (同一个视觉属性别漏改一条路径,见 swiftUIAlignment 注释)。
                    //
                    // 用**这一行自己**的 `.frame(maxWidth:.infinity, alignment:)`,而不是
                    // 去改外层 `VStack(alignment:)`:那个 VStack 里还有进度条和播放键,而
                    // 下面那两条 `.padding(.bottom,)`/`.frame(height:)` 的高度算术是跟
                    // `NotchExpandedMetrics` 对账的(注释里记着"两处一个开一个不开必然对不上"),
                    // 动 VStack 的对齐属性等于把这一项的影响面从"一行文字"扩到整块布局。
                    // Text 撑满整行宽之后它自己的 leading 对齐导线就落在容器左边缘,VStack 那
                    // 一侧看到的仍是原来的形状;`.lineLimit(1)` 也保证高度不变。
                    .frame(maxWidth: .infinity,
                           alignment: playback.nextLineAlignment)
            }

            // 进度条独立成 NotchScrubber 子视图(拖动状态自持 + 30Hz 帧率上限),见其注释。
            NotchScrubber(
                anchor: playback.anchor,
                pausedPositionMs: playback.pausedPositionMs,
                durationMs: playback.currentDurationMs,
                isPlayingNow: playback.isPlayingNow,
                seekable: PlaybackCoordinator.shared.acceptsSeek,
                tint: accentOrWhite,
                // 广告期间不画「− 歌词 0.0s +」:广告没有歌词,校准无物可校。
                showsLyricsOffsetControls: playback.showsLyricsOffsetControls && !playback.isCurrentTrackAdBreak,
                trackLyricsOffsetMs: playback.trackLyricsOffsetMs,
                lyricsOffsetStepMs: playback.lyricsOffsetStepMs)

            // 完整三键:岛是 hover 展开的,真正的点击全发生在展开态,控制就该在展开卡里、进度条下方居中,跟菜单栏面板卡片同一套
            // 设计语言(进度条 + 居中三键),目标也大得多(22pt vs 耳朵里 15pt)。
            //
            // `expandedShowsControls` 关掉后这排键不画,理由见 `NotchChromeSource.expandedShowsControls` 的注释(不是唯一入口,
            // `NotchEarModule` 本来就有「播放控制」这个选项)。
            //
            // 随机、循环此刻都能切的播放器在播时左右两端再加随机 / 循环(歌词窗口同款排布),两颗等宽,
            // 三键仍居中。
            if controller.expandedShowsControls {
                HStack(spacing: 0) {
                    if let mode = playback.fullPlaybackMode {
                        shuffleButton(mode)
                        Spacer(minLength: 8)
                    }
                    HStack(spacing: 34) {
                        controlButton("backward.fill", glyphSize: 11.5, hitSize: 22, hintKey: "transport.previous") {
                            MusicPlaybackController.previousTrack()
                        }
                        controlButton(playback.isPlayingNow ? "pause.fill" : "play.fill",
                                      glyphSize: 14, hitSize: 22, hintKey: "transport.playPause") {
                            // 乐观回声版:歌词窗封面缩放/图标点击即动(见 userTogglePlayPause)。
                            PlaybackCoordinator.shared.userTogglePlayPause()
                        }
                        controlButton("forward.fill", glyphSize: 11.5, hitSize: 22, hintKey: "transport.next") {
                            MusicPlaybackController.nextTrack()
                        }
                    }
                    if let mode = playback.fullPlaybackMode {
                        Spacer(minLength: 8)
                        repeatButton(mode)
                    }
                }
                .frame(maxWidth: .infinity)
                // 播放控制被拦下时那三颗键的说明往上弹,盖在歌词上(同头部快捷操作那排的气泡)。
                .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                                    shown: $shownQuickActionTooltip,
                                                    tint: accentOrWhite, edge: .top))
            }
        }
        .padding(.horizontal, NotchMetrics.expandedContentInset)
        // 10pt 底边距是 `NotchExpandedMetrics.controlsBlock`(35 = 22 键高 + 10 底边距 +
        // 3pt 余量)的一部分,关掉播放控制键之后这一整块(含底边距)在高度算术里都不占
        // 地方了(见 height(...) 的 hasControls 分支),渲染这侧必须跟着不加,否则算出来的
        // 高度比实际渲染矮 10pt,会把上面的内容顶出去一截、被 `.frame(alignment: .top)`
        // 裁掉底部——两处一个开一个不开,必然对不上。 代价:关掉控制键但进度条/下一句
        // 预览还开着时,最后一个元素少了这 10pt 专属边距,只剩它自己那份"间距4"贴底(比如
        // 进度条时间行离底边只剩 4pt,不是 10pt)——比专属边距紧一些,但不会被裁,这是
        // 接受的取舍,不值得为这一种组合另开一条独立的常量。
        .padding(.bottom, controller.expandedShowsControls ? 10 : 0)
        // maxWidth: .infinity 是必须的,不是随手加的保险。
        //
        // 不钉这一下,这一块的宽度就跟着**内容**走。播放时里面有进度条,进度条用
        // GeometryReader 会自己撑满,于是整块占满整行、歌词预览自然贴左;而暂停时进度条
        // 那一段整个不渲染(它挂在 playback.anchor 上,暂停后 anchor 为 nil),VStack 里只
        // 剩一句歌词预览,这一块就缩成那行字那么宽 —— 再被外层 VStack 默认的**居中**
        // 对齐推到正中间。表现就是"暂停时下一句歌词跑到中间、播放时又靠左"。
        // 撑满 + topLeading 之后,两种状态下它都在同一个位置。
        // (分两个 .frame:maxWidth 走的是弹性那个重载,height 走固定尺寸那个,
        // 混在一次调用里编译不过。)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 高度跟 NotchWindowRoot.cardHeight **走同一个函数、同一组入参**(都读 controller
        // 上那两个曲目级标志)—— 两处各自判断的话必然漂,而漂的表现是卡片和内容差一截:
        // 要么底部多一条空隙,要么最下面那排三键被裁掉。
        .frame(height: NotchExpandedMetrics.height(
            hasLyricPreview: controller.showsExpandedLyricPreview,
            hasScrubber: controller.expandedShowsScrubber,
            hasControls: controller.expandedShowsControls,
            trackInfoHeight: 0), alignment: .top)
    }

    /// 曲目信息头部:封面 + 歌名/歌手/专辑,四项独立开关。解决的缺口:两只耳朵都配成非文本模块(比如「剩余时长」)时,hover 展开
    /// 也看不出这是哪首歌。
    ///
    /// 头部有自己的一枚封面(`expandedTrackInfoShowsArtwork`,这个协议里),固定贴文字块左边;歌词行末尾那枚是另一个开关
    /// (`lyricRowContent` 里的 `artworkThumbnail`,受 `notchLyricRowShowsArtwork`/`notchLyricRowArtworkPosition` 控制,走
    /// `NotchPlayback` 镜像,不在这个协议里)。两枚能同时开,不算矛盾。
    @ViewBuilder
    private var trackInfoHeader: some View {
        if controller.showsExpandedTrackInfo {
            HStack(spacing: 8) {
                trackInfoArtwork
                trackInfoTextStack
                trackInfoQuickActions
            }
                // 悬浮提示挂在**整行**上、不挂在那排按钮上:气泡要收敛在卡片里,而"卡片内容区有多宽"
                // 只有这一层的 GeometryReader 量得到(按钮排自己只有 100pt 宽)。见 `QuickActionTooltipOverlay`。
                .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                                    shown: $shownQuickActionTooltip,
                                                    tint: accentOrWhite, edge: .bottom))
                // 左右内边距是展开态那一列内容的边界(歌词首字、进度条、控制键同一条),展开态的顶行也收到这里(topRowPadding)。
                .padding(.horizontal, NotchMetrics.expandedContentInset)
                // 顶部间距:头部紧挨在 topRow 下面,没有它标题首行会贴到上面边。这份间距已经在 `expandedTrackInfoHeaderHeight`/
                // `NotchExpandedMetrics.height` 的高度算术里算过(`trackInfoSpacing * 2`,一份在上一份在下),这里只是把"上面那份"
                // 实现成看得见的留白;`.frame(alignment: .top)` 会把这段 padding 之后的内容继续钉在分配到的那块高度顶部。
                .padding(.top, NotchExpandedMetrics.trackInfoTopSpacing)
        }
    }

    /// 头部里的封面缩略图,复用 `artworkThumbnail`(点击打开歌词窗口的行为跟着一起继承)。
    /// 没有封面数据(没曲目/取图失败)时不画占位方块——跟 `lyricRowContent` 末尾那枚同一个
    /// 惯例(`@ViewBuilder` 的 `if let` 不满足时直接产出零视图,HStack 自然收缩)。
    @ViewBuilder
    private var trackInfoArtwork: some View {
        // 电台口白期间换台标,跟耳朵、歌词行那两枚同一个取法(头部标题这时也已经是台名)。
        if controller.trackInfoShowsTrackFields, controller.expandedTrackInfoShowsArtwork,
           let image = displayedArtworkImage {
            artworkThumbnail(image, side: NotchExpandedMetrics.trackInfoArtworkSide)
        }
    }

    /// 头部里的歌名/歌手/专辑三行,复用 `metadataText`——跟耳朵里那三个文本模块走同一份
    /// 广告插播/空曲目规则(广告中歌名写「广告中」、歌手专辑留空),不重新定义一套。
    ///
    /// `.frame(maxWidth: .infinity, alignment: .leading)` 是必须的:没有它,`.lineLimit(1)`
    /// 的 `Text` 在 VStack 里只会按内容天然宽度收缩,压根不会触发截断——这一块需要一个
    /// 明确的宽度提议才截得断长歌名/长专辑名。
    /// 广告期间三行都不画(`trackInfoShowsTrackFields`),留下的空 VStack 仍按 `maxWidth: .infinity` 吃掉
    /// 剩余宽度,把快捷操作那排键推到右端 —— 跟四项全关、只开快捷操作时同一个形态。
    /// 头部的专辑名。当前这首有专辑简介时可点(开 / 关浮框),没有就只是文字 —— 判据与悬停态在
    /// `NotchEditorialLine` 里,它自己订阅 `EditorialNotesStore`,简介到货只重画这一行。
    private var trackInfoAlbumLine: some View {
        NotchEditorialLine(kind: .album, text: metadataText(.album), tint: accentOrWhite,
                           font: .system(size: 9), restingOpacity: 0.4, hoverOpacity: 0.75,
                           tappable: !playback.album.isEmpty || !playback.youtubeMusicAlbum.isEmpty) { controller.toggleEditorial(.album) }
    }

    private var trackInfoTextStack: some View {
        let fields = controller.trackInfoShowsTrackFields
        return VStack(alignment: .leading, spacing: NotchExpandedMetrics.trackInfoLineSpacing) {
            // 歌名能点开歌曲简介;电台口白期间这一行是台名,不接。
            if fields && controller.expandedTrackInfoShowsTitle {
                NotchEditorialLine(kind: .song, text: metadataText(.title), tint: accentOrWhite,
                                   font: .system(size: 12, weight: .semibold), restingOpacity: 0.9, hoverOpacity: 1,
                                   tappable: !playback.title.isEmpty && radioTalkStation == nil) { controller.toggleEditorial(.song) }
            }
            if fields && controller.expandedTrackInfoShowsArtist {
                NotchEditorialLine(kind: .artist, text: metadataText(.artist), tint: accentOrWhite,
                                   font: .system(size: 10, weight: .medium), restingOpacity: 0.6, hoverOpacity: 0.9,
                                   tappable: !playback.artist.isEmpty) { controller.toggleEditorial(.artist) }
            }
            if fields && controller.expandedTrackInfoShowsAlbum {
                trackInfoAlbumLine
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 头部右侧那排「快捷操作」:喜欢、搜索歌词、显示 / 隐藏歌词、Last.fm、设置、关闭灵动岛。
    ///
    /// 排法照悬浮歌词那排控制胶囊(`LyricsOverlayView.playbackControls`):**对这首歌的操作 │ 窗口级
    /// 操作**,中间一条细竖线分组,✕ 放最右最边上 —— 喜欢 · 搜索歌词 · 显示歌词 │ Last.fm · 设置 · 关闭
    /// (喜欢只在播放器有「喜欢」时出现,Last.fm 只在连着账号时出现)。每颗都是
    /// 22pt 命中格(跟下面播放控制三键同一档,`NotchExpandedMetrics.trackInfoActionsHeight`),
    /// 字形 11pt,颜色跟卡上其它图标一样走 `accentOrWhite`、压到七成五 —— 这排是"手边的入口",
    /// 不该比歌名重。
    ///
    /// 各颗键的语义:
    ///   * 喜欢 → `PlaybackCoordinator.toggleFavorited()`,跟悬浮歌词那颗心、歌词窗口那颗星同一条路。`isFavorited` 为 nil
    ///     (这个播放器没有「喜欢」或没拿到权限)和广告期间不画。排在最左:这排键贴右对齐,它出现 / 消失时别的键不挪。
    ///     已喜欢画实心、全亮、带淡底,同随机 / 循环键点亮。展开时回读一次状态(`NotchLyricsWindowController.refreshExpanded`)。
    ///     见 05 章决策 79。
    ///   * 搜索歌词 → `AppActions.openLyricsQuickSearch`,跟悬浮歌词 ⚙ 菜单的「搜索歌词…」同一扇小窗。
    ///     头部本来就要求 `hasTrack`,所以不用像那边一样再按"有没有歌"决定显隐。广告期间四颗照常画、照常可点
    ///     (头部此时只剩这一排,见 `trackInfoShowsTrackFields`)。
    ///   * 显示歌词 → 切 `AppSettings.notchShowLyrics`(稳态那 44pt 歌词行的开关)。**展开态里看不出
    ///     变化**(展开永远画歌词行,见 `showsLyricRow`),关着时字形压淡到四成、tooltip 换成「显示歌词」,
    ///     让"现在是关的"当场可辨;收回稳态才看得出效果。状态读 `controller.showsLyrics`(控制器的镜像),
    ///     不另订阅 AppSettings。
    ///   * Last.fm 到 设置 › Last.fm 详情页(`openLastfmSettingsPage`)。是去 App 里某个页面、不是对这首歌做什么,
    ///     所以在竖线右边。只在 `LastfmStatsService.isConnected` 时画:没连的人点了只会落到一张连接卡上。
    ///   * 设置 → 直接翻到 设置 › 歌词显示 › 灵动岛,照抄 `OverlayQuickSettingsMenu.openMoreSettings` 那三行。
    ///   * 关闭 → 关掉「灵动岛歌词」**总开关**(`closeFromQuickAction` → `setVisible(false)`),跟悬浮歌词
    ///     那颗 ✕ 同一个意思;再打开走菜单栏面板 / 设置 / 快捷键。不做"只收起这一次":hover 展开
    ///     本来移开指针就收,那颗键等于没用。
    ///
    /// 不套 `controlButton` 那层"先查 Apple Music 自动化权限"的守卫:这几个动作跟播放控制毫不相干,
    /// 借那层守卫会引入一个跟按钮语义不匹配的隐藏依赖(跟悬浮歌词的锁定键同一条理由)。
    @ViewBuilder
    private var trackInfoQuickActions: some View {
        if controller.expandedShowsQuickActions {
            HStack(spacing: 2) {
                if let favorited = playback.isFavorited, !controller.isAdBreakNow {
                    quickActionButton(favorited ? "heart.fill" : "heart", key: "favorite",
                                      label: favorited ? L10n.t("取消喜欢") : L10n.t("喜欢"), lit: favorited) {
                        PlaybackCoordinator.shared.toggleFavorited()
                    }
                }
                quickActionButton("magnifyingglass", label: L10n.t("搜索歌词…")) {
                    AppActions.shared.openLyricsQuickSearch?()
                }
                quickActionButton("text.alignleft",
                                  label: controller.showsLyricsSetting ? L10n.t("隐藏歌词") : L10n.t("显示歌词"),
                                  dimmed: !controller.showsLyricsSetting) {
                    AppSettings.shared.notchShowLyrics.toggle()
                }
                // 分组线:前两颗是"对这首歌 / 这行歌词"的操作,后两颗是"这块卡片"的操作。
                Rectangle()
                    .fill(accentOrWhite.opacity(0.18))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                // 只在连着 Last.fm 时出现:没连的人这颗键无处可去,这排仍是四颗。
                // `isConnected` 不是 @Published,随下一次 body 重算取值(同歌词窗口的统计元素)。
                if LastfmStatsService.shared.isConnected {
                    quickActionButton("chart.bar.fill", label: L10n.t("在设置中查看 Last.fm")) {
                        openLastfmSettingsPage()
                    }
                }
                quickActionButton("gearshape.fill", label: L10n.t("设置…")) { openNotchSettingsPage() }
                quickActionButton("xmark", label: L10n.t("关闭灵动岛歌词")) {
                    controller.closeFromQuickAction()
                }
            }
            .frame(height: NotchExpandedMetrics.trackInfoActionsHeight)
        }
    }

    /// 「Last.fm」快捷键的动作:翻到 设置 › Last.fm 详情页,跟歌词窗口「收听次数」那行同一个落点。
    private func openLastfmSettingsPage() {
        AppActions.shared.requestSettings(.account(.lastfm))
        AppActions.shared.openSettings?()
    }

    /// 「设置…」快捷键的动作:直接翻到 设置 › 歌词显示 › 灵动岛,照抄 `OverlayQuickSettingsMenu.openMoreSettings`
    /// 那三行。抽成函数是因为头部快捷操作与空闲面板各有一颗。
    private func openNotchSettingsPage() {
        UserDefaults.standard.set(LyricsSurface.notch.appearanceSectionRawValue,
                                  forKey: LyricsSurface.appearanceSectionStorageKey)
        AppActions.shared.requestSettings(.tab(.appearance))
        AppActions.shared.openSettings?()
    }

    /// 没有曲目时左耳那一格(决策 #37):平时是 `idleAppIcon`;有「发现新播放器」的信任提议挂着时换成那个播放器的图标 + 右上角
    /// 一粒小圆点,收起态下这是提示存在的唯一线索(被动的那一半;主动的那一半是卡片自己撑开一次,见 NotchUnknownPlayerPrompt)。
    /// 切换与订阅都在宿主子视图里,这里只把尺寸账(同 idleAppIcon:`earAppIconSide` × 显示倍率)交下去。
    private func idleEarIcon(alignment: Alignment) -> some View {
        NotchIdleEarIconHost(prompt: prompt,
                             side: NotchMetrics.earAppIconSide(contentTopInset: controller.contentTopInset),
                             scale: max(1, displayScale), alignment: alignment) {
            idleAppIcon(alignment: alignment)
        }
    }

    /// 没有曲目时 hover 展开出来的那一块(现象是「没有播放的展开状态目前看起来不是很友好」)。
    ///
    /// 改前的样子:`cardHeight` 照有曲目的通式给展开区留"三键 + 进度条"的 59～76pt,而那块内容整个被
    /// `hasTrack` 挡掉 —— hover 上去长出一大块什么都没有的黑。现在只长出这一块,排法照曲目信息头部
    /// (`trackInfoHeader`):左边两行字、右边一排 22pt 图标键,左内边距同样是歌词那一列的 16pt,上面留
    /// `trackInfoTopSpacing`,下面留 `idlePanelBottomSpacing`(它贴底,4pt 太紧)—— 有曲目和没曲目时
    /// 展开出来的是"同一个位置上的同一种东西",不是两套版式。
    ///
    /// 文案与动作全部复用歌词窗口停播页那套(`IdleStandbyView.noTrackHero` / `IdlePlaybackActions`):
    /// 「没有在播放」+「在 X 播放任意歌曲,歌词会自动出现」;第一颗键 AM / Spotify 是「继续播放」(三段式,
    /// 失败兜底激活 App),其它播放器没有 AppleScript、只给「打开 X」。后两颗是「设置…」「关闭灵动岛歌词」,
    /// 跟头部快捷操作同款、同分组线 —— 但**不看** `expandedShowsQuickActions` 那个开关:那开关管的是"头部
    /// 右侧那块空地要不要塞按钮",而这里的键是空闲面板存在的全部理由,关掉就只剩两行字。不放「搜索歌词」
    /// 「显示歌词」:没有曲目,两者都无物可指。左耳那枚 App 图标已经在顶行上,这里不再画第二枚。
    ///
    /// 不套 `controlButton` 那层"先查 Apple Music 自动化权限"的守卫:`IdlePlaybackActions.resume` 自己会查
    /// (AM 那条走 `checkAppleMusicSafely`),「打开 X」压根不需要权限。
    private var idleExpandedPanel: some View {
        let player = IdlePlaybackActions.player
        let canResume = IdlePlaybackActions.canResume(player)
        let name = player.displayName
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: NotchExpandedMetrics.trackInfoLineSpacing) {
                Text(L10n.t("未在播放"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentOrWhite.opacity(0.9))
                // 提示句不点名播放器——
                // 灵动岛这句是泛指,不像歌词窗口停播页那句要跟旁边「打开 X」按钮对上;右边那颗键的
                // tooltip 仍带具体名字(那是一个具体动作的目标)。
                Text(L10n.t("在播放器中播放任意歌曲，歌词将自动显示"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentOrWhite.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                quickActionButton(canResume ? "play.fill" : "arrow.up.forward.app",
                                  label: canResume ? L10n.t("继续播放") : String(format: L10n.t("打开 %@"), name)) {
                    if canResume {
                        IdlePlaybackActions.resume(player: player)
                    } else {
                        IdlePlaybackActions.openPlayerApp(player)
                    }
                }
                // 分组线,同头部快捷操作:左边是"对播放器做什么",右边是"对这块卡片做什么"。
                Rectangle()
                    .fill(accentOrWhite.opacity(0.18))
                    .frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                quickActionButton("gearshape.fill", label: L10n.t("设置…")) { openNotchSettingsPage() }
                quickActionButton("xmark", label: L10n.t("关闭灵动岛歌词")) {
                    controller.closeFromQuickAction()
                }
            }
            .frame(height: NotchExpandedMetrics.trackInfoActionsHeight)
        }
        // 同一份提示,但**往上**弹:这块面板贴着卡片底(下面只剩 idlePanelBottomSpacing 那 10pt),
        // 气泡往下会被窗口硬裁;往上是顶行,空闲态那儿只有一枚 App 图标,盖一下无妨。
        .modifier(QuickActionTooltipOverlay(hovered: hoveredQuickAction,
                                            shown: $shownQuickActionTooltip,
                                            tint: accentOrWhite, edge: .top))
        .padding(.horizontal, NotchMetrics.expandedContentInset)
        .padding(.top, NotchExpandedMetrics.trackInfoTopSpacing)
    }

    /// 快捷操作里的一颗图标键。`label` 当读屏标签,同时喂给自绘的悬浮提示(见 `QuickActionTooltipOverlay`)
    /// —— 这几颗都是纯图标,没有文字。悬停 / 按下反馈在 `NotchIconButton` 里(加,跟三键同一份)。
    ///
    /// `.help(label)` 撤掉了:系统 tooltip 在这扇窗上一次都没弹过,理由与替代方案见
    /// `QuickActionTooltipOverlay` 的头注。
    ///
    /// `key` 是气泡认这颗键用的名字,字形会随状态换的键(喜欢:心 / 实心)要给一个固定的,不然点完气泡对不上它。
    /// `lit`:点亮样式(字形全亮 + 淡底),同随机 / 循环键。
    private func quickActionButton(_ systemName: String, key: String? = nil, label: String, dimmed: Bool = false,
                                   lit: Bool = false, action: @escaping () -> Void) -> some View {
        let hintKey = key ?? systemName
        return NotchIconButton(systemName: systemName, glyphSize: 11, hitSize: NotchExpandedMetrics.trackInfoActionsHeight,
                               tint: accentOrWhite, glyphOpacity: lit ? 1 : (dimmed ? 0.4 : 0.75),
                               restingLevel: lit ? 0.16 : 0, action: action)
            // 指针进出这颗键。离开时**只在"记着的还是自己"时**才清 —— 相邻两颗键的 enter/exit
            // 到达顺序没有保证,少了这道守卫会出现 B 刚记上就被 A 那条迟到的 exit 抹掉。
            .onHover { inside in
                if inside {
                    hoveredQuickAction = QuickActionHint(key: hintKey, text: label)
                } else if hoveredQuickAction?.key == hintKey {
                    hoveredQuickAction = nil
                }
            }
            // 「显示 / 隐藏歌词」那颗点完 `label` 就变,但指针没动、`onHover` 不会再来一次 —— 不同步
            // 的话气泡会停在点之前那句,而这颗键的状态本来就靠这句提示交代(05 章决策 28)。
            .onChange(of: label) { _, newLabel in
                if hoveredQuickAction?.key == hintKey {
                    hoveredQuickAction = QuickActionHint(key: hintKey, text: newLabel)
                }
            }
            // 把自己的位置报给上面那层,气泡靠它对准这颗键 —— 几何交给 SwiftUI 算,不在别处照着
            // 「22 + spacing 2 + 分隔线」再手写一份坐标(那种两处各算一份的数迟早会漂)。
            .anchorPreference(key: QuickActionAnchorKey.self, value: .bounds) { [hintKey: $0] }
            .accessibilityLabel(label)
    }

    private var nextLineDisplayText: String {
        playback.nextLineText ?? ""
    }

    // 必须用 checkForCurrentPlayerSafely(异步),不能用同步版本——理由跟
    // LyricsOverlayView.swift 同名方法的注释一致:同步版本在还没问过时会直接触达有据
    // 可查、可能永久挂起主线程的系统 API。权限不够时用 NSSound.beep() 给一个"没有
    // 生效"的听觉反馈(补上,跟另外两处播放控制入口保持一致),不静默无声。
    /// 随机:点亮 = shuffle,再点回列表。跟循环键互斥(脚本接口只有三态,见
    /// `LyricsWindowView.shuffleButton`)。权限检查在 `setPlaybackMode` 里。
    private func shuffleButton(_ mode: MusicPlaybackController.MusicPlaybackMode) -> some View {
        modeButton("shuffle", active: mode == .shuffle) {
            PlaybackCoordinator.shared.setPlaybackMode(mode == .shuffle ? .list : .shuffle)
        }
    }

    /// 循环:关 → 列表循环 → 单曲循环 → 关;没有单曲循环的播放器两态。跟歌词窗口 `repeatButton` 同一套。
    private func repeatButton(_ mode: MusicPlaybackController.MusicPlaybackMode) -> some View {
        modeButton(mode == .repeatOne ? "repeat.1" : "repeat",
                   active: mode == .repeatOne || mode == .repeatAll) {
            PlaybackCoordinator.shared.setPlaybackMode(
                mode.nextRepeat(allowsRepeatOne: playback.playbackModeAllowsRepeatOne,
                                allowsRepeatAll: playback.playbackModeAllowsRepeatAll))
        }
    }

    /// 熄灭时字形半透明、没有底;点亮时字形全亮、垫一层淡底(歌词窗口 `modeToggleButton` 的样子)。
    private func modeButton(_ systemName: String, active: Bool, action: @escaping () -> Void) -> some View {
        NotchIconButton(systemName: systemName, glyphSize: 10.5, hitSize: 22,
                        tint: accentOrWhite, glyphOpacity: active ? 1 : 0.45,
                        restingLevel: active ? 0.16 : 0, action: action)
            .accessibilityLabel(Text(Self.controlAccessibilityName(systemName)))
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// 播控键的读屏名。键只有图标,不给的话 VoiceOver 读的是符号自带的英文描述(「backward fill」),
    /// 也不跟界面语言走。按图标名给,调用处不用各传一遍。
    private static func controlAccessibilityName(_ systemName: String) -> String {
        switch systemName {
        case "backward.fill": return L10n.t("上一首")
        case "forward.fill": return L10n.t("下一首")
        case "play.fill", "pause.fill": return L10n.t("播放/暂停")
        case "shuffle": return L10n.t("随机播放")
        case "repeat.1": return L10n.t("单曲循环")
        case "repeat": return L10n.t("循环播放")
        default: return ""
        }
    }

    /// glyphSize/hitSize 显式给时优先(展开卡里的三键要比耳朵里的大一号),
    /// 不给就沿用 primary 的两档旧尺寸(耳朵那一个)。
    /// `hintKey` 不为 nil 时,播放控制被拦下那段时间悬停弹一句说明(同快捷操作那排的自绘气泡,外面那层要挂
    /// `QuickActionTooltipOverlay`)。耳朵上那排太窄、放不下气泡,不传。
    private func controlButton(_ systemName: String, primary: Bool = false,
                               glyphSize: CGFloat? = nil, hitSize: CGFloat? = nil, hintKey: String? = nil,
                               action: @escaping () -> Void) -> some View {
        let glyph = glyphSize ?? (primary ? 11 : 9.5)
        let hit = hitSize ?? (primary ? 18 : 15)
        let withheldReason = playback.controlsWithheldReason
        return NotchIconButton(systemName: systemName, glyphSize: glyph, hitSize: hit,
                               tint: accentOrWhite, glyphOpacity: withheldReason == nil ? 1 : PlaybackCoordinator.withheldControlOpacity) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                action()
            }
        }
        .accessibilityLabel(Text(Self.controlAccessibilityName(systemName)))
        .modifier(WithheldControlHint(key: hintKey, reason: withheldReason, hovered: $hoveredQuickAction))
    }
}

/// 歌词行上「瞬态横幅盖歌词」这层壳,单独订阅 NotchTransientCenter:banner 只被这一行消费,订阅挂在 NotchLyricsView 根上的话,
/// 音量连调时每档一次的 @Published 变化会打醒整卡 body(含封面背景/跑马灯/音浪)。下沉之后横幅出现/消失只失效这一行。
///
/// 歌词行常驻,横幅盖上来时只藏起来(`NotchCardLayerActive`:透明、停表、对读屏隐藏),别写回 `if let banner … else` 换视图:
/// 那样每弹一次横幅歌词行就拆掉重建,长句跑马灯从句首重来,逐字行重画整行位图。横幅自己的淡入淡出单独包一层,
/// `.animation(_:value:)` 的作用域不罩到歌词行上(05 章决策 101)。
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
private struct NotchIdleEarIconHost<Fallback: View>: View {
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
private struct NotchLayerActiveReader<Content: View>: View {
    @Environment(\.notchCardLayerActive) private var active
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(active) }
}

/// 展开态头部的歌名 / 歌手名 / 专辑名那一行。当前曲目有对应的简介(`EditorialNotesStore`)才接点击,指针移上去字色
/// 提亮;没有简介时就是一行字,不给任何「能点」的暗示。
private struct NotchEditorialLine: View {
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
