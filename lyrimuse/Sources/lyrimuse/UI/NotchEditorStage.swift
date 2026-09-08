import AppKit
import LyrimuseCore
import SwiftUI

// 「歌词显示 → 灵动岛」的**编辑台**:一小片屏幕顶端(菜单栏 + 刘海 + 桌面),灵动岛卡片
// 1:1 挂在上面,直接在这块画面里改(2026-08-31)。
//
// 这是把桌面悬浮歌词那一段的编辑台范式(2026-08-30,见 OverlayEditorStage 与
// docs/features/04-desktop-overlay.md「编辑台改造」)搬到灵动岛这一段,用户原话:
// 「参考悬浮歌词这种做法,把灵动岛的对应设置 tab 页也改成这种风格」。搬过来的四件事:
//   ① 预览从**页顶钉条**(NotchPreviewBar,本次删除)挪进**可滚动内容区**。钉条那一层
//      收不到点击事件(这是 SettingsPageWithStickyHeader 结构本身的行为,跟里面放什么、
//      有没有手势无关,复现记录见 SettingsView 里那段 2026-08-16 的注释),所以凡是
//      "能动手改"的预览都只能待在内容区。
//   ② 宽度从卡片里的一根滑杆挪进舞台内部、正对卡片下沿 —— 它改的是上面那扇窗,待在
//      同一块画面里就不必再写一句话解释。
//   ③ 「风格」「屏幕」收进工具栏两个浮层,按钮上带当前值摘要(不点开也知道现在什么样)。
//   ④ 总开关卡留在编辑台正下方常驻(同悬浮歌词那一段:主开关不进折叠区)。
//
// ⚠️ **这里原来写着"没有「全部设置」抽屉,这不是漏做",那条论证 2026-08-31 已经被推翻。**
// 原话是:悬浮歌词那边的抽屉是 16 项设置的全量兜底通路,而灵动岛一共只有三项(风格 / 宽度 /
// 屏幕),两个浮层加舞台里那根滑杆已经全部覆盖,再加抽屉就是同一批设置摆两遍。**前提变了**:
// 可配项后来涨到两行工具栏共七个入口(风格 / 屏幕 / 左耳 / 右耳 + 歌词行 / 展开态 / 行为),
// 用户看过第一版抽屉之后要求把**原有**那几项也补齐,于是有了 `NotchAllSettingsDrawer`
// (在 SettingsView.swift,渲染点是 `currentSection` 的 `.notch` 分支)。它的分组、顺序、标题跟
// 工具栏七个入口**一一对应**(2026-09-07 起,中间多插宽度 / 展开宽度两根滑杆),每一组调的都是
// 浮层背后同一份组件;「音浪」开关在左右耳两组顶部,跟浮层里一样(抽屉末尾那张独立的音浪卡撤了)。
// (悬浮歌词那个抽屉同期也从 16 项涨到 18 项,同样是并进了那两行自动隐藏。)
//
// ⚠️ 舞台**放得下就 1:1、放不下就整体缩小到刚好放下**(`previewScale`,2026-09-06)。1:1 是从悬浮歌词
// 编辑台第四步继承的调子("看到多大就是多大"),在宽度上限 500 的年代它无条件成立(舞台最窄约 499)。
// 同日上限抬到 **800**(用户拖到 500 后说「最宽还是有点小了」)之后先按悬浮歌词那套"居中裁切 + 两端
// 渐隐 + 「两端已裁切」"处理过一版,用户当场否掉:「太大之后,预览放不下」—— 他要的是**看全**,不是
// 知道被裁了。于是改成缩放:缩放比 = min(1, 舞台宽 / 展开真实宽),**按展开宽算、不按此刻的卡片宽**,
// 这样 hover 展开时比例不跳、稳态和展开态在同一把尺子下。缩放的是「屏幕顶端」整组(仿菜单栏条 +
// 卡片 + 刘海)—— 三者描述的是同一块屏幕,只缩卡片会让刘海空当和菜单栏高度对不上;壁纸不缩(它只是
// 背景)。缩了就在 caption 写一句「预览已缩小至 NN%」,免得用户把缩过的尺寸当真。
// 卡片宽度上限就是 `widthRange.upperBound`(耳朵下限最高的一档 ≈ notchWidth + 150 ≈ 330–350,够不着,
// 封顶的是区间本身)。
//
// ⚠️ **舞台放不下 800**:舞台宽 = 卡片列宽 = min(600, 设置窗内容区 − 40),侧边栏可拖到 220
// (`.navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)`)、窗口可拖到 `minWidth` 760
// (SettingsWindowConfigurator 往 styleMask 里插了 `.resizable`),两样推到极限时舞台只有约 499pt。
// 缩放之后卡片永远不会比舞台宽,但舞台的裁切形状仍要是**顶直角**底圆角(见 stage 里那段):卡片
// 恰好等宽时每侧余量是 0,顶上带圆角就会把卡片两个顶部直角削圆。
//
// ⚠️ 舞台高度是常量(只随屏幕的刘海让位高度变,那是插拔显示器才会发生的事)。hover 展开
// 时卡片长高 76pt,**容器不跟着变** —— 编辑台挂在可滚动内容区里,它一变高下面所有卡片
// 都会跟着跳一下。这条是从 NotchPreviewBar 继承的既有纪律,不是新加的。

// MARK: - 预览用 chrome

/// 灵动岛编辑台用的 chrome:凑齐 NotchLyricsView 要的那几个属性,但不建窗口、不碰屏幕。
///
/// ⚠️ 这个类存在的唯一理由,就是让预览**不去碰 NotchLyricsWindowController.shared**。
/// 见那个文件顶部那条不变量:`.shared` 是 `static let`,哪怕只是拿来读一下属性都会执行
/// init() 建出整扇窗(NSPanel + NSHostingView + 一串 Combine 订阅和通知观察者),灵动岛
/// 关着的用户一打开设置页就凭空多一套。所以刘海几何这里走的是那边不碰实例状态的 static
/// 函数(`targetScreen()` / `geometry(for:)` / `contentWidth(baseWidth:notchWidth:)`)。
///
/// 用独立实例还有第二个好处:鼠标划过编辑台时展开的是**这一份**,不会顺手把真窗口也撑开。
///
/// (2026-08-31 从 SectionPreviewBars.swift 搬来 —— 它唯一的消费方现在是这个文件里的编辑台,
///  跟着一起搬,同 OverlayPreviewChrome 长在 OverlayEditorStage.swift 里。)
@MainActor
final class NotchPreviewChrome: ObservableObject, NotchChromeSource {
    @Published private(set) var isExpanded = false
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var contentTopInset: CGFloat = 0
    /// 卡片两种形态的真实宽,由舞台按真窗口同一套公式算好推进来(`NotchEditorStage.card` 的 onAppear /
    /// onChange),歌词行按它们定宽居中交叉淡入淡出(NotchChromeSource 里的说明)。初值只是占位。
    @Published private(set) var steadyCardWidth: CGFloat = AppSettings.defaultNotchContentWidth
    @Published private(set) var expandedCardWidth: CGFloat = AppSettings.defaultNotchContentWidth

    func setCardWidths(steady: CGFloat, expanded: CGFloat) {
        if steadyCardWidth != steady { steadyCardWidth = steady }
        if expandedCardWidth != expanded { expandedCardWidth = expanded }
    }

    /// 预览恒为 false。isCollapsed 是真窗口"没在播放就缩回刘海大小、内容整套不渲染"的
    /// 行为 —— 照搬到设置页就是一片空白,而用户恰恰是来这里看样式的。
    var isCollapsed: Bool { false }

    /// 预览恒按**最完整**形态画(有歌词预览、有进度条)—— 用户来这里是看样式的,给他一个
    /// 因为"此刻这首歌没歌词"而缩掉一截的样张没有意义。跟 isCollapsed 恒 false 同一个理由。
    var expandedShowsLyricPreview: Bool { true }
    var expandedShowsScrubber: Bool { true }
    /// 预览恒按"有曲目"画,理由同 isCollapsed 恒 false:用户来这儿是看样式的。
    var hasTrack: Bool { true }

    /// 「显示歌词」现读设置 —— 这一项**必须**反映真实配置(它决定卡片还剩不剩歌词行,
    /// 正是用户在这块画布上要看的东西),不能像上面几项那样为了"看样式"钉成常量。
    /// 不用 @Published 镜像:编辑台自己观察 AppSettings,设置一变整块重画,读到的必然是新值。
    var showsLyrics: Bool { AppSettings.shared.notchShowLyrics }
    /// 音浪开关/贴哪只耳朵,同上现读设置——预览要如实反映用户正在配的效果。
    ///
    /// ⚠️ 这两项比「显示歌词」更不能钉成常量:它们**同时**决定顶行怎么排
    /// (`NotchLyricsView.topRow`)和卡片宽度下限(`NotchLyricsWindowController.minEarWidth`
    /// 要按"哪只耳朵挂音浪"留出 `EqualizerBars.width + earWaveSpacing`)。钉死的话编辑台那根
    /// 宽度调整条的下界会跟真窗口对不上 —— 而"设定值和真实宽度之间不许有歧义"正是这块画布
    /// 2026-08-31 改造的出发点(见 widthValueText / usableWidthRange)。
    var showsEqualizer: Bool { AppSettings.shared.notchShowsEqualizer }
    var equalizerEar: NotchEqualizerEar { AppSettings.shared.notchEqualizerEar }

    /// 展开态那一组(2026-09-01)同上,一律现读设置——它们决定的正是"展开态"浮层里那几个
    /// 开关此刻要不要生效,预览必须如实反映。⚠️ 不含歌词行末尾那枚封面的开关/位置——那两项
    /// 走 `NotchPlayback` 而不是这个协议;但**含**头部自己的封面开关
    /// (`expandedTrackInfoShowsArtwork`),理由见 `NotchChromeSource.expandedTrackInfoShowsArtwork`
    /// 上面那条⚠️——它跟另外三项一样参与高度计算,预览这边不能漏。
    // 「下一句歌词预览」画不画 = 用户开关 && 没被歌词行「副行 · 下一句」顶掉(2026-09-06),判据只有
    // Core 那一份,跟真窗口 NotchLyricsWindowController 的订阅同源。
    var expandedShowsNextLine: Bool {
        LyricSecondaryLine.expandedNextLinePreviewVisible(
            userToggle: AppSettings.shared.notchExpandedShowsNextLine, secondary: AppSettings.shared.notchSecondaryLine)
    }
    var expandedShowsControls: Bool { AppSettings.shared.notchExpandedShowsControls }
    var expandedTrackInfoShowsArtwork: Bool { AppSettings.shared.notchExpandedShowsArtwork }
    var expandedTrackInfoShowsTitle: Bool { AppSettings.shared.notchExpandedShowsTrackTitle }
    var expandedTrackInfoShowsArtist: Bool { AppSettings.shared.notchExpandedShowsArtist }
    var expandedTrackInfoShowsAlbum: Bool { AppSettings.shared.notchExpandedShowsAlbum }
    var expandedShowsQuickActions: Bool { AppSettings.shared.notchExpandedShowsQuickActions }

    init() { refreshGeometry() }

    /// 视图内部那个 .onHover 打进来的调用,预览里**故意忽略**(空实现)。
    ///
    /// (NotchLyricsView 自己那个 .onHover 已于 2026-08-16 删除,真窗口的命中判定在
    /// NotchWindowRoot;这个空实现保留是因为它是协议成员 —— 而且"预览不该产生任何副作用"
    /// 这条本身仍然成立,同 OverlayPreviewChrome.controlsDidBecomeVisible。)
    ///
    /// 编辑台里真正生效的那条路是下面的 setExpandedFromPreview:宿主拿精确坐标跟卡片矩形
    /// 直接比,不吃隐式的 hover 范围(那个范围实测比肉眼看到的卡片大一圈)。
    func setExpanded(_ expanded: Bool) {}
    /// 快捷操作的 ✕ 在预览里**故意**是空实现:预览卡整块 `allowsHitTesting(false)`,点不到;真要能点到
    /// 也不该让"预览"把用户的灵动岛关掉(预览卡上的可点区域只开浮层、不产生副作用,见 05 章)。
    func closeFromQuickAction() {}

    /// 编辑台自己算出来的命中结果,这才是预览里真正生效的那条路。
    func setExpandedFromPreview(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
    }

    /// 跟真窗口 recomputeGeometry 取的是同一块屏、同一个公式,编辑台里的让位宽度/高度才
    /// 会跟真出来的严丝合缝。
    ///
    /// 可重入,有**两个**触发源:
    ///   - 插拔显示器(didChangeScreenParametersNotification);
    ///   - 用户在「屏幕」浮层里改了「显示在哪块屏幕」。⚠️ 第二条 2026-08-31 之前是**漏的**
    ///     —— 钉条只订了通知,于是从"内建屏"换到一块没有刘海的外接屏之后,预览里的刘海空当
    ///     和让位高度还是旧屏的。编辑台把刘海本身也画出来了(见 notchCutout),这个陈旧值
    ///     会直接表现成"画了一个那块屏根本没有的刘海",所以必须补上。
    /// ⚠️ 两个赋值**刻意不判等**。这个方法只在屏幕插拔和「屏幕」浮层提交时跑(低频到可以
    /// 忽略),判等省下的那次 objectWillChange 没有任何收益,却会掐掉编辑台唯一的一条刷新
    /// 通道:工具栏「屏幕」按钮上的摘要(`NotchScreenSummary.current`)是从 `NSScreen.screens`
    /// 现算的**纯派生值**,那个全局没有任何 publisher,只能靠这次发布带着 body 重估一遍。
    /// 判等版本会在"刘海几何恰好没变"的插拔里让摘要停在旧值 —— 典型场景:一台没有内建刘海
    /// 的机器接两块菜单栏等高的外接屏,钉住的那块拔掉/插回,notchWidth 恒 0、notchHeight 相等,
    /// 于是按钮上仍写着已经拔掉的那台显示器的名字(反过来插回来则卡在「已断开的屏幕」)。
    func refreshGeometry() {
        guard let screen = NotchLyricsWindowController.targetScreen() else { return }
        let geo = NotchLyricsWindowController.geometry(for: screen)
        notchWidth = geo.notchWidth
        contentTopInset = geo.notchHeight
    }
}

// MARK: - 编辑台

@MainActor
struct NotchEditorStage: View {
    /// ⚠️ 显式写 init 而不是靠合成的逐成员构造器:下面 `settings` 是 `private` 存储属性,
    /// 合成出来的逐成员构造器会跟着降成 private,SettingsView 那边就构造不出来了
    /// (同 OverlayEditorStage 里那条注释)。
    init() {}

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var chrome = NotchPreviewChrome()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 当前开着哪个浮层(nil = 都没开)。
    ///
    /// 用一个可空枚举而不是两个 Bool,是为了让"同时只能开一个"成为**类型上**的事实:
    /// 一个浮层还开着的时候点开另一个,SwiftUI 会把两个 NSPopover 都摆出来,它们互相
    /// 遮挡、而且各自的 transient 关闭时机会打架(同 OverlayEditorStage.StagePopover)。
    @State private var popover: StagePopover?

    /// 当前这个浮层锚在哪:工具栏按钮(从工具栏点开的),还是预览卡上某块可点区域的某个矩形
    /// (从卡片上点开的,2026-09-06 用户:「弹出来的那个窗口也不要在原本顶部的那个位置弹出来,
    /// 就从我点击的这个位置弹出来」)。跟 `popover` 一起构成"哪个浮层、开在哪"—— 同一个
    /// `StagePopover` 在工具栏和卡片上各挂着一份 `.popover`,靠这个字段保证同时只亮一份。
    @State private var popoverAnchor: PopoverAnchor = .toolbar

    private enum PopoverAnchor: Equatable {
        case toolbar
        /// 卡片上第 `rectIndex` 个矩形(一块区域可以有多个矩形,见 `CardHotspot.rects`)。
        case hotspot(CardHotspot.Kind, rectIndex: Int)
    }

    /// 指针此刻悬在预览卡的哪块**可点区域**上(nil = 都没悬)。只用来画那块区域的高亮框,
    /// 见 `cardHotspots` / `hotspotView`。
    @State private var hoveredHotspot: CardHotspot.Kind?

    /// 用户此刻正按着宽度调整条的哪只滑块(nil = 没按着)。两个用途:把卡片那圈轮廓加强一档
    /// (见 windowEdgeOutline);按着**展开**那只时让卡片按展开态画(见 card / cardWidth)——
    /// 否则拖上限时鼠标在滑杆上、卡片没被 hover,用户看不见自己在调的那个宽度。
    @State private var adjustingThumb: NotchWidthRangeDrag.Thumb?

    /// 拖动中的临时宽度(nil = 没在拖):稳态 / 展开各一份(2026-09-06 起宽度是一对)。
    ///
    /// ⚠️ 这是**性能必需**,不是锦上添花 —— 同 OverlayEditorStage.draggingWidth 那条(用户
    /// 报过"拖动这个宽度条的时候卡顿,不流畅")。直接写 `settings.notchContentWidth` 的话,
    /// 每一格都要 ①`@Published` 广播一遍(整页 + 菜单栏快捷面板 + 真灵动岛窗口跟着重渲染)、
    /// ②写一次 UserDefaults、③`applyContentWidthSetting()` 走一遍全量几何 + NSWindow.setFrame。
    /// 而编辑台里跑的是**真** NotchLyricsView(跑马灯、逐字填色、封面模糊背景都在里面)。
    ///
    /// 现在拖动中只动这两个 @State:只有编辑台自己重画,不写盘、不广播全局、不碰真窗口;
    /// onEditingChanged 收到 nil(松手)时一次性提交(commitWidths)。
    @State private var draggingSteady: Double?
    @State private var draggingExpanded: Double?

    // MARK: - 度量

    /// 舞台下半部留给宽度调整条的通道高度(胶囊约 30pt + 底距 12pt + 14pt 呼吸)。
    /// 卡片只在**这条通道以上**的那一格里挂着(见 cardAreaHeight)。
    private static let widthBarLaneHeight: CGFloat = 56

    /// 宽度调整条那根滑杆有多长、整条胶囊离舞台底边留多远。滑杆长度跟悬浮歌词编辑台同一个
    /// 数值 —— 同一个窗口里两条控件没有理由长得不一样(这根 2026-09-06 起是双滑块,轨道等长)。
    private static let widthBarSliderWidth: CGFloat = 168
    private static let widthBarBottomInset: CGFloat = 12

    /// 工具栏那一条的高度 / 它跟画布之间的呼吸。同悬浮歌词编辑台。
    private static let toolbarHeight: CGFloat = 26
    private static let toolbarSpacing: CGFloat = 10

    /// 宽度的合法区间。
    ///
    /// **这里是三处的唯一真源**:编辑台这根调整条、菜单栏快捷面板里的同一根,以及以后任何
    /// 第三处。不要在任何一处另写字面量 —— 一处能产生别处够不到的值,用户下次一动另一根滑杆
    /// 就会被弹回去,表现是"我调好的宽度自己变了"(悬浮歌词那边的 `OverlayEditorStage.widthRange`
    /// 就是为这件事立的规矩)。
    ///
    /// 下界 2026-08-31 从 260 降到 **200**(用户:「可以最小值再小一些,支持调到更小」)。降它
    /// 是因为耳朵下限那一层同一天改成了跟配置走(见 `NotchLyricsWindowController.minEarWidth`),
    /// 两只耳朵都配成「不显示」时这台机器的下限掉到约 251 —— 存储层要是还卡在 260,那 9pt
    /// 就白让了,而且换台刘海更窄的机器让得更多。200 这个数是**几何硬底**那头来的:卡片再窄
    /// 也不能窄过刘海本身,否则它整个躲进刘海里 —— 这台机器实测 `179 + 左右各 10 = 199`。
    /// 上界 2026-09-06 从 500 抬到 **800**(用户拖到 500 后:「最宽还是有点小了,帮我再调大一些」;
    /// 起因是同日加的「展开态可以更宽」—— 稳态 360 时展开只能到 500,+140pt 不够看)。两只滑块
    /// (稳态 / 展开)共用这一个区间,稳态也因此能到 800:没有理由替用户把稳态钉在 500,超宽的
    /// 代价(编辑台舞台放不下)由"整体缩小到刚好放下"兜着(`previewScale`,见文件头)。800 ≈ 14 吋 MBP 逻辑宽
    /// 1512 的一半,两侧菜单栏各还剩三百多 pt。
    /// ⚠️ 两端必须是 `widthStep`(2) 的整数倍(`snap()` 先夹后量化,不是倍数会把值顶出界);
    /// 200/800 都满足。
    ///
    /// ⚠️ 这是**存储层**的区间,不是滑杆能拖的区间 —— 后者见下面的 `usableWidthRange`,
    /// 下界会被这台机器的"耳朵下限"抬上去。两个宽度入口的读数则**一律报真实宽度、不报设定值**
    /// (编辑台见 widthValueText,菜单栏快捷面板见 effectiveWidth 的调用点):正常情况下两者
    /// 相等,而历史上落盘过的、低于耳朵下限的旧值(下界抬上去之前存的)靠这条口径仍然显示得对。
    static let widthRange: ClosedRange<Double> = 200 ... 800

    /// 滑杆**真正能拖**的区间:下界抬到这台机器**当前配置下**的"耳朵下限"(2026-08-31 用户
    /// 要求「既然最小就是 339,那么就应该把宽度条最小调整为 339」)。
    ///
    /// 在此之前下界恒为 260,而真实宽度还要跟耳朵下限取大者
    /// (`NotchLyricsWindowController.contentWidth`)—— 这台机器实测约 339,于是 260…339
    /// 这一段拖了卡片纹丝不动。抬上来之后那截死区**不存在**了:滑杆的每一格都真的会动。
    ///
    /// ⚠️ **下界是屏幕 _和_ 耳朵配置两者的函数,不是常量**(后半条是同日第二轮改的:用户
    /// 「我看依旧左右耳占用了很大空间」)。同一台机器上,凡是两只耳朵都只配文字或「不显示」的
    /// (含默认的歌名/歌手)下界都是 **252** —— 那时撑着下限的只剩右耳外缘那簇音浪;配上封面
    /// 会到 256(左)/ 296(右),播放控制 308,时长 330。没有真刘海的屏
    /// (外接显示器)`notchWidth == 0`,耳朵下限只剩一百出头,`max` 之后是存储层的 200。
    /// 所以这里必须**每次现算**,不能写死一个数,也不能只按屏幕缓存一次。
    ///
    /// ⚠️ 现算的前提是调用点会跟着耳朵配置重新求值:编辑台和菜单栏快捷面板都 `@ObservedObject`
    /// 了 `AppSettings`,改模块会重画;真窗口那一侧靠
    /// `NotchLyricsWindowController` 的 `leftEarObserver` / `rightEarObserver`。
    ///
    /// ⚠️ 三条护栏一条都不能少:
    ///   ① 下界**向上**取整到 `widthStep` 的倍数。否则 `snap` 的"先夹后量化"可能把值量化到
    ///      下界**以下**(例如下限 340.9 → 夹到 340.9 → 量化成 340,比下限还小 0.9pt)。
    ///   ② 下界不许越过上界:真刘海宽到 `notchWidth > 348` 时耳朵下限会超过 498(下限最高的
    ///      那一档 = 某只耳朵配成时长,单耳 65pt;现实里的
    ///      MacBook 刘海约 180pt,够不着,但这里不赌)。留出至少一个 `widthStep`,免得 Slider
    ///      拿到一个长度为 0 的区间。
    ///   ③ 存储层的 `widthRange` **不随屏幕/配置变**(200…800):它才是"这个值合不合法"的判据,
    ///      而合法性不该随插了哪块屏、耳朵配成什么而变 —— 配置导出/导入要跨机器,`notchScreenID`
    ///      那种机器本地键才不迁移,宽度是要迁移的。低于当前下界的旧值不会被改写,只是渲染时
    ///      被 `contentWidth` 顶上去;换回窄的耳朵配置,那个值原样回来。
    static func usableWidthRange(notchWidth: CGFloat,
                                 contentTopInset: CGFloat) -> ClosedRange<Double> {
        let earFloor = Double(NotchLyricsWindowController.contentWidth(
            baseWidth: CGFloat(widthRange.lowerBound), notchWidth: notchWidth,
            contentTopInset: contentTopInset))
        let ceiled = (earFloor / widthStep).rounded(.up) * widthStep          // 护栏 ①
        let lower = min(ceiled, widthRange.upperBound - widthStep)            // 护栏 ②
        return lower ... widthRange.upperBound
    }

    /// 同上,但**自己现读屏幕** —— 给构造不出这个 View 的调用点用(菜单栏快捷面板那根滑杆)。
    /// `targetScreen()` / `geometry(for:)` 都是 static、不碰 `NotchLyricsWindowController.shared`。
    static var usableWidthRangeOnCurrentScreen: ClosedRange<Double> {
        let geo = NotchLyricsWindowController.targetScreen()
            .map { NotchLyricsWindowController.geometry(for: $0) }
        return usableWidthRange(notchWidth: geo?.notchWidth ?? 0,
                                contentTopInset: geo?.notchHeight ?? 0)
    }

    /// **展开宽**那根单滑块(抽屉 / 菜单栏快捷面板)能拖的区间:下界 = 稳态**真实**宽(展开不许
    /// 比稳态窄,见 `NotchWidthBounds`),上界同 `widthRange`。编辑台自己的双滑块不用这个 ——
    /// 它两只滑块共用 `usableWidthRange`,"不越过对方"由 `NotchWidthRangeDrag` 管。
    ///
    /// 护栏跟 `usableWidthRange` 同一套:下界向上取整到 `widthStep`(SteppedSlider 的栅格锚在
    /// 下界,这里主要是为了跟编辑台那根 step 2 的落值对得上);下界不许越过上界(稳态拉满 800
    /// 时展开只剩 800 这一个值,给 Slider 一个零长区间会算出 nan)。
    static func usableExpandedWidthRange(steadyWidth: Double) -> ClosedRange<Double> {
        let ceiled = (steadyWidth / widthStep).rounded(.up) * widthStep
        let lower = min(max(ceiled, widthRange.lowerBound), widthRange.upperBound - widthStep)
        return lower ... widthRange.upperBound
    }

    /// 同上,稳态真实宽**自己现读设置和屏幕**(给构造不出这个 View 的调用点用)。
    static var usableExpandedWidthRangeOnCurrentScreen: ClosedRange<Double> {
        usableExpandedWidthRange(steadyWidth: effectiveWidth(baseWidth: AppSettings.shared.notchContentWidth))
    }

    /// 三个写入口(编辑台调整条 / 抽屉 / 快捷面板)**唯一**的落盘路径(2026-09-06)。
    ///
    /// 做三件事,顺序有讲究:
    ///   ① 归一到不变量「展开 ≥ 稳态」(`NotchWidthBounds.normalized`):单滑块入口把稳态拖过了
    ///      展开,展开被顶上去;展开拖到稳态以下,停在稳态。
    ///   ② **先写展开、后写稳态**:两个 `@Published` 各自派发一次,镜像管理器的 combineLatest 在
    ///      第一次派发时另一个值还是旧的 —— 先抬展开再抬稳态,中间那一帧仍满足不变量(读侧还有
    ///      一层 max 兜着,这里只是不制造一帧"展开 < 稳态"的落盘状态)。相等守卫一个都不能少:
    ///      `@Published` 等值赋值照样广播 objectWillChange,didSet 还会多写一次 UserDefaults。
    ///   ③ 带 `notchOverlayEnabled` 守卫再通知真窗口:`NotchLyricsWindowController.shared` 是
    ///      `static let`,读一下就建整扇窗,灵动岛关着的用户碰一下滑杆不该凭空多一套(守卫跳过
    ///      之后由 `setVisible(_:)` 的 visible 分支在重新打开时补一次 recomputeGeometry)。
    /// 传 nil 的那个值原样保留(只归一,不改)。
    static func commitWidths(steady: Double? = nil, expanded: Double? = nil) {
        let settings = AppSettings.shared
        let next = NotchWidthBounds.normalized(
            steady: steady ?? settings.notchContentWidth,
            expanded: expanded ?? settings.notchExpandedContentWidth)
        var changed = false
        if next.expanded != settings.notchExpandedContentWidth {
            settings.notchExpandedContentWidth = next.expanded
            changed = true
        }
        if next.steady != settings.notchContentWidth {
            settings.notchContentWidth = next.steady
            changed = true
        }
        guard changed, settings.notchOverlayEnabled else { return }
        NotchLyricsWindowController.shared.applyContentWidthSetting()
    }

    /// 宽度调整条的步长(pt)。
    ///
    /// 2pt 而不是菜单栏快捷面板那根的 10pt:那根是兜底通路、旁边没有实时预览,粗一点反而好
    /// 落值;编辑台这根紧挨着那张跟着实时变宽变窄的卡片,10pt 一格看得出来是在跳。落盘的值
    /// 因此可能不是 10 的整数倍,那根 10pt 的滑杆照样显示得出来:step 只约束滑杆自己产生的
    /// 值,不约束模型。
    static let widthStep: Double = 2

    /// 卡片那一格的高度 = 展开态卡片的全高(刘海让位 + 稳态歌词行 + 展开区上限)。
    ///
    /// **必须按展开态留**:hover 展开时卡片长高 76pt,这一格要是按稳态留,展开出来的
    /// 下一句预览和迷你进度条会被舞台的 clipShape 裁掉半截。
    ///
    /// 它随 `contentTopInset` 变,而那个值只在插拔显示器/换屏时才变(刘海让位高度是屏幕的
    /// 函数)—— 跟悬浮歌词编辑台那条"高度不许依赖 overlayWidth"的纪律不冲突:这里的高度跟
    /// **宽度**没有任何关系,拖调整条时舞台一个像素都不动。
    /// ⚠️ 2026-09-01 起 `expandedExtraHeightMax` 不再是无参常量,吃"下一句预览开关"+
    /// "播放控制键开关"+"曲目信息头部现算高度"三个设置维度(见该函数注释)——这里从
    /// `chrome` 现读,不是钉常量:预览来这儿就是让用户看清楚"这些设置会让展开区变多高",
    /// 钉死的话舞台留白跟真窗口对不上。
    private var cardAreaHeight: CGFloat {
        chrome.contentTopInset + NotchMetrics.compactRowHeight + NotchMetrics.expandedExtraHeightMax(
            hasLyricPreviewPossible: chrome.expandedShowsNextLine,
            hasControlsPossible: chrome.expandedShowsControls,
            trackInfoHeight: NotchMetrics.expandedTrackInfoHeight(
                showsArtwork: chrome.expandedTrackInfoShowsArtwork,
                showsTitle: chrome.expandedTrackInfoShowsTitle,
                showsArtist: chrome.expandedTrackInfoShowsArtist,
                showsAlbum: chrome.expandedTrackInfoShowsAlbum,
                showsActions: chrome.expandedShowsQuickActions))
    }

    /// 编辑台画布区的高度 = 卡片那一格 + 调整条通道。
    private var stageHeight: CGFloat { cardAreaHeight + Self.widthBarLaneHeight }

    /// 整块(两行工具栏 + 画布 + 底部说明行)占的高度。caption 那一行的间距和行高沿用预览栏
    /// 共用的那套度量,免得同一个窗口里两处 caption 的疏密不一样。
    ///
    /// ⚠️ 2026-09-01 工具栏从一行变两行(第二行「歌词行/行为/展开态」三个新入口,见
    /// `toolbarRow2`)——按钮样式跟第一行完全一样,复用同一个 `toolbarHeight`,只是多加
    /// 一份「高度 + 行间距」。忘了这里加,表现是编辑台整块比实际内容矮一行,第二行工具栏
    /// 要么被画布裁掉一截,要么把下面的画布/说明行顶得跟外层预留的空间对不上。
    private var totalHeight: CGFloat {
        (Self.toolbarHeight + Self.toolbarSpacing) * 2
            + stageHeight + SectionPreviewMetrics.captionSpacing + SectionPreviewMetrics.captionHeight
    }

    /// 用户设定的稳态宽度(拖动中取临时值)。**不是**卡片的真实宽度,见 steadyCardWidth。
    private var baseWidth: Double { draggingSteady ?? settings.notchContentWidth }
    /// 用户设定的展开宽度(拖动中取临时值)。同上,真实值见 expandedCardWidth。
    private var expandedBaseWidth: Double { draggingExpanded ?? settings.notchExpandedContentWidth }

    /// 设定值经"两只耳朵放得下按钮"的下限之后,卡片**真实**有多宽 —— 给**构造不出这个 View**
    /// 的调用点用(菜单栏快捷面板那根滑杆的读数)。
    ///
    /// ⚠️ 刘海宽度这里现读屏幕(`targetScreen()` / `geometry(for:)` 都是 static、不碰
    /// `NotchLyricsWindowController.shared`,安全);编辑台自己走 `cardWidth`,取的是 chrome 里
    /// 那份会跟着屏幕插拔和「屏幕」浮层刷新的镜像。同一条公式、两个新鲜度相同的来源。
    static func effectiveWidth(baseWidth: Double) -> Double {
        let geo = NotchLyricsWindowController.targetScreen()
            .map { NotchLyricsWindowController.geometry(for: $0) }
        return Double(NotchLyricsWindowController.contentWidth(
            baseWidth: CGFloat(baseWidth), notchWidth: geo?.notchWidth ?? 0,
            contentTopInset: geo?.notchHeight ?? 0))
    }

    /// 展开态卡片的**真实**宽度,同上给构造不出这个 View 的调用点用(抽屉 / 快捷面板那根
    /// 「展开宽度」滑杆的读数)。公式就是真窗口 `recomputeGeometry` 里那一句
    /// `NotchWidthBounds.expandedWidth`,不另写。
    static func effectiveExpandedWidth(steadyBase: Double, expandedBase: Double) -> Double {
        Double(NotchWidthBounds.expandedWidth(
            steady: CGFloat(effectiveWidth(baseWidth: steadyBase)),
            expandedSetting: CGFloat(expandedBase)))
    }

    /// 稳态卡片此刻**真实**有多宽 —— 走真窗口那个公式,不直接用设定值。
    ///
    /// 宽度调得很小时真窗口会被"两只耳朵放得下按钮"的下限顶宽,编辑台得跟着一起顶,否则
    /// 这一段恰恰在最容易出岔的区间失真(这条是从 NotchPreviewBar 继承的,不是新想的)。
    private var steadyCardWidth: CGFloat {
        NotchLyricsWindowController.contentWidth(
            baseWidth: CGFloat(baseWidth), notchWidth: chrome.notchWidth,
            contentTopInset: chrome.contentTopInset)
    }

    /// 展开态卡片此刻真实有多宽:`max(稳态真实宽, 展开设定)`,跟真窗口 `recomputeGeometry`
    /// 同一个公式(`NotchWidthBounds.expandedWidth`)。
    private var expandedCardWidth: CGFloat {
        NotchWidthBounds.expandedWidth(steady: steadyCardWidth, expandedSetting: CGFloat(expandedBaseWidth))
    }

    /// 卡片**此刻**画多宽:hover 展开(含拖上限滑块时被程序置成的展开,见 widthBar)按展开宽,
    /// 否则按稳态宽 —— 跟真窗口 `NotchWindowRoot.cardWidth` 同一个分支。
    private var cardWidth: CGFloat {
        chrome.isExpanded ? expandedCardWidth : steadyCardWidth
    }

    /// 卡片此刻的真实高度。**公式本体在 `NotchChromeSource` 的协议扩展里**,真窗口
    /// (`NotchWindowRoot`)读的是同一份 —— 2026-08-31 收成一份,在此之前两处各写一遍,
    /// 而入参已经涨到四个(收起 / 有没有曲目 / 展不展开 / 显不显示歌词)。
    private var cardHeight: CGFloat { chrome.cardHeight }

    var body: some View {
        GeometryReader { geo in
            // 舞台宽度 = 容器给多少吃多少(卡片列上限 600pt)。
            let stageWidth = geo.size.width
            VStack(spacing: Self.toolbarSpacing) {
                toolbar
                    .frame(height: Self.toolbarHeight)
                toolbarRow2
                    .frame(height: Self.toolbarHeight)
                VStack(spacing: SectionPreviewMetrics.captionSpacing) {
                    stage(stageWidth: stageWidth)
                    caption(stageWidth: stageWidth)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // GeometryReader 会贪心吃掉外部给的全部空间,所以高度必须在外面焊死;高度不依赖
        // 任何测量结果(只依赖刘海让位高度这个屏幕常量),不存在"读了尺寸又改尺寸"的布局回路。
        .frame(height: totalHeight)
        // ⚠️ 高度**在交互路径上是常量**,但它依赖 `chrome.contentTopInset`(刘海让位高度),
        // 而那个值有两个变法:插拔显示器,以及**这一页自己的**「屏幕」浮层换了一块屏(内建刘海
        // 屏 33pt ↔ 外接屏的菜单栏高度,能差好几个 pt)。后者是页内操作,硬跳的话下面那张
        // 总开关卡会跟着抖一下 —— 用一条只认这个值的动画滑过去。挂 value: 而不是裸
        // `.animation()`:裸的那种会把编辑台里所有变化都动画化,包括逐字填色每一帧。
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: chrome.contentTopInset)
        // 设置页开着的时候插拔显示器,刘海几何要跟着变。真窗口自己也订阅了同一条通知
        // (见 NotchLyricsWindowController.screenParamsObserver)。
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            chrome.refreshGeometry()
        }
    }

    // MARK: - 工具栏

    /// 编辑台顶上那一条:四个浮层入口(风格 / 屏幕 / 左耳 / 右耳)+ 右边一个「重置 ▾」菜单。
    ///
    /// ⚠️ **2026-09-01 前这里右边是刻意空着的**——当时的理由是"灵动岛的外观只有「风格」
    /// 一个枚举,不值得配一个重置菜单"。用户之后明确要求"和悬浮歌词那个一样加一个重置
    /// 按钮",于是这条结论被推翻:范围也跟着扩到"风格 + 左右耳 + 屏幕 + 全部内容开关"
    /// (`NotchStyleDefaults.restoreDefaults()`),不再是当初设想的"就一个枚举"。
    ///
    /// ⚠️ 横向够不够:这一条的可用宽度就是卡片列宽(窗口按 idealWidth 860 打开时 600pt,
    /// 拖到 minWidth 760 时约 530pt,再窄约 499pt)。**四个**入口都带摘要,最坏情况
    /// 是「屏幕」那截报一个很长的显示器名(`screen.localizedName`,例如 "内建视网膜显示器"
    /// 或 "DELL U2723QE"),所以摘要那截跟悬浮歌词那边一样限宽 140 + 单行 + 尾部省略 +
    /// `.layoutPriority(-1)`(见 toolbarButton)—— 挤不下时**先压摘要、标题始终完整**。
    /// 这条取舍跟悬浮歌词工具栏第四个位置那次是同一条,不重复推导。「重置 ▾」本身是固定宽度
    /// 的 `Menu`,不参与这套压缩逻辑(跟悬浮歌词工具栏同一个模式)。
    ///
    /// ⚠️ **加了这颗按钮之后,第一行的横向预算从"余量 1pt"变成"确定超支"**(2026-09-01,
    /// ls-Rocky 离屏 `NSHostingView.fittingSize` 实测,方法论同下面②那次回归):「重置 ▾」
    /// 本体 + 前后间距增量中文 +88.0pt、英文 +97.0pt——叠到四个入口原有的中文 498.0/英文
    /// 644.0 上,变成中文 586.0(阈值 499,超 87pt)、英文 741.0(超 242pt)。499pt 下用
    /// 最坏摘要(风格=磨砂玻璃/Frosted Glass、屏幕=内建视网膜显示器/Built-in Retina Display、
    /// 左右耳=剩余时长/Remaining)离屏渲染逐个看过:四个标题(含"重置")中英文都完整,亏空
    /// 全被 `layoutPriority(-1)` 摊给了摘要——但**英文摘要已经归零**(压到单个字母 "R",
    /// 连省略号都放不下)。也就是说这一行现在真的到底了:**摘要没有任何可让的空间了**,
    /// 下一次改动——加第五个入口、把哪个标题改长、给摘要多加两个字——亏空会直接开始吃
    /// 标题,重演当初「Left…」「Righ…」那次回归。改这一行之前必须先重新离屏量一遍,
    /// 不要凭感觉现改。
    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarButton(
                icon: "paintbrush.pointed",
                title: L10n.t("风格"),
                summary: settings.notchCardStyle.displayName,
                target: .style
            )
            toolbarButton(
                icon: "display",
                title: L10n.t("屏幕"),
                summary: NotchScreenSummary.current,
                target: .screen
            )
            // 左右耳各一个入口(2026-08-31 用户要求从一个「耳朵」拆开:「拆成两个,左右耳,
            // 各一半宽度」)。图标用带方向的 `arrow.left.to.line` / `arrow.right.to.line`,
            // 跟浮层里那两行是同一对记号。
            //
            // ⚠️ **别再试图给这两颗钉一个固定宽度去凑"等宽"**(2026-08-31 试过一次,当天撤掉)。
            // 那一版给摘要传了 `.frame(width: 60)`,结果是:
            //   ① **等宽根本没做到**。离屏量过(600/530/499/700/900 五档 × 中英):容器宽裕时四颗
            //      按钮本来就各自贴着自己的文字(英文 155.0 / 162.0),容器不够时 HStack 均分、
            //      四颗一起变等宽 —— 两种情形下"等宽与否"都跟这个定宽无关。
            //   ② **代价是标题被截**。刚性 frame 的 min/ideal/max 全是 60,对任何提议都返回 60,
            //      `.layoutPriority(-1)` 只决定谁先拿到提议、决定不了谁能被压缩,于是亏空 100%
            //      摊到标题上:英文 @600(= 卡片列上限,窗口拖到多宽都是这个数)标题 41→30.0、
            //      48→37.0,正是用户截图里的「Left…」「Righ…」;@499 只剩 9.0pt。中文同样中招,
            //      @530 标题 22→11.0。而摘要列在所有档位恒 60.0、一格没让。
            //   ③ 那个 60pt 的上限**永远碰不到**:最长的模块名 "Remaining" 渲染出来才 55.0pt。
            // 现在四颗一律走同一条默认路径(摘要上限 140、`.layoutPriority(-1)` 先被压),实测
            // 中英在 499~900 全区间标题都不截。
            toolbarButton(
                icon: "arrow.left.to.line",
                title: L10n.t("左耳"),
                summary: earSummary(.left),
                target: .leftEar
            )
            toolbarButton(
                icon: "arrow.right.to.line",
                title: L10n.t("右耳"),
                summary: earSummary(.right),
                target: .rightEar
            )
            Spacer(minLength: 8)
            // 「重置 ▾」——逐字复刻悬浮歌词工具栏那颗(见 OverlayEditorStage.toolbar):
            // Menu 里一条恢复动作 + 一条不可点的作用范围说明,范围声明必须写在这里,理由
            // 同悬浮歌词那边——"不含宽度和总开关"是安全边界,不能只在动作本体的注释里
            // 交代、界面上却什么都不提示。
            Menu {
                Button(L10n.t("恢复默认")) { NotchStyleDefaults.restoreDefaults() }
                Text(L10n.t("不含宽度和总开关"))
            } label: {
                Label(L10n.t("重置"), systemImage: "arrow.uturn.backward")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    /// 工具栏第二行(2026-09-01):「歌词行 / 字体 / 展开态 / 行为」四个入口(「字体」2026-09-09 加),收纳的是这几轮陆续加的
    /// 一批布尔开关。这些开关最初直接铺在页面上(先是"行为"卡片横排两格,后来陆续并进「显示封面」
    /// 和整张「展开态」卡片的四项),用户看过之后要求改回跟「风格/屏幕/左耳/右耳」一样的
    /// "点开才配置"形态。
    ///
    /// **2026-09-07 按卡片解剖重新分组**(用户:「很多都是混乱的…有些它不应该放在这一个框框里面…
    /// 不要出现这一个那一个的情况」):「歌词行」= 歌词行本身的一切(显不显示 / 对齐 / 副行 +
    /// 展开时预览下一句 / 卡拉OK / 行末封面);「展开态」= 只有 hover 展开才有的(控制区两颗 +
    /// 「快捷操作」+「曲目信息」四项);「行为」= 什么时候缩、什么时候藏(暂停缩回 + 两项自动隐藏)。顺序也按
    /// 卡片从上到下走:歌词行 → 展开态 → 行为(改前是 歌词行 → 行为 → 展开态)。内容(图标 / 标题 /
    /// Binding)仍只有 `NotchBehaviorItem` 一份,三个浮层和「全部设置」抽屉的三个组各调**同一份**
    /// 分组视图(`NotchLyricRowSettingsRows` / `NotchExpandedSettingsRows` / `NotchBehaviorSettingsRows`,
    /// `SettingsView.swift`),不再是"两处传同样的 items 数组"。
    ///
    /// ⚠️ 横向预算:2026-09-01 三颗时的账(中文 493 余 6pt / 英文 649 超 150pt)见 05 章「编辑台改造 → 搬过来的
    /// 四件事」那张表;2026-09-09 加第四颗「字体」前按同一套方法论(离屏复刻这一行的版式、`NSHostingView.fittingSize`)
    /// 重新量过:四颗入口、摘要压到零时的**硬下限**中文 374.0 / 英文 468.0(三颗时 288.0 / 380.0),都在最窄
    /// 卡片列 499 之内 —— 标题在任何窄档都不会截,亏空全由摘要吃(`toolbarButton` 摘要限宽 140 +
    /// `.layoutPriority(-1)`)。代价跟第一行一样:摘要全长(默认值中文 793 / 英文 921,最坏 934 / 1028)远超 600,
    /// 四截摘要在 600 下每截只剩约 56pt(中文)/ 33pt(英文),499 下英文摘要基本只剩省略号。这是有意接受的
    /// 取舍(第一行早已如此),**但这一行也到底了**:再加第五个入口或把哪个标题改长之前,先重新离屏量一遍,
    /// 不要凭感觉现改数字。
    private var toolbarRow2: some View {
        HStack(spacing: 8) {
            toolbarButton(
                icon: "text.alignleft",
                title: L10n.t("歌词行"),
                summary: lyricRowSummary,
                target: .lyricRow
            )
            // 「字体」(2026-09-09):字体族 / 粗细 / 字号,紧跟「歌词行」—— 它是歌词行文字的属性,排在"这一行显示什么"
            // 之后、"展开才有的东西"之前。图标 `textformat` 跟悬浮歌词「文字」按钮同一枚。
            toolbarButton(
                icon: "textformat",
                title: L10n.t("字体"),
                summary: fontSummary,
                target: .font
            )
            toolbarButton(
                icon: "rectangle.expand.vertical",
                title: L10n.t("展开态"),
                summary: expandedSummary,
                target: .expanded
            )
            toolbarButton(
                icon: "switch.2",
                title: L10n.t("行为"),
                summary: behaviorSummary,
                target: .behavior
            )
            Spacer(minLength: 8)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    /// 「字体」按钮摘要(2026-09-09):「系统字体 较粗 13pt」,跟悬浮歌词「文字」按钮那截是**同一个函数**
    /// (`OverlayStyleSummary.fontText`)—— 三项全报、字体名"空串 = 系统字体"的口径都在那边定,两个编辑台
    /// 各拼一遍迟早漂开。
    private var fontSummary: String {
        OverlayStyleSummary.fontText(family: settings.notchFontFamilyName, weight: settings.notchFontWeight,
                                     size: Int(settings.notchFontSize))
    }

    /// 「歌词行」按钮摘要:2026-09-01「显示歌词」从「行为」浮层搬过来之后,这里要拼两项
    /// (显示歌词 / 显示封面)。规则跟下面 `behaviorLikeSummary` 一样"只列开着的",但
    /// 「显示封面」开着时额外带上位置(`NotchEarModule.artwork.displayName` 直接借用耳朵
    /// 那边"封面"两个字,不新造一个词)——这一细节不能简单并进 `behaviorLikeSummary` 的
    /// "只列标题"逻辑,否则"贴左还是贴右"这个用户在意的信息会丢,所以单独写。
    private var lyricRowSummary: String {
        var parts: [String] = []
        if settings.notchShowLyrics { parts.append(NotchBehaviorItem.showLyrics.title) }
        // 「对齐方式」(2026-09-03)只在**非默认**时才报。三选一不是开关,套不进上面那条
        // "只列开着的"规则;而默认值(左对齐)是绝大多数人的状态,无条件报出来等于给每个人的
        // 按钮上加一句恒定噪声、还要跟 140pt 限宽抢地方。非默认才报 = 跟"只列开着的"同一个
        // 精神(只说偏离缺省的那部分)。文案走 `LyricsAlignmentSegmentedControl.label(for:)`,
        // 跟控件里的标签是同一份口径 —— 控件写「左对齐」、摘要写「左」是同一个值的两种叫法
        // (悬浮歌词那边为这件事专门把 label 提成了 static func,见那个注释)。
        if settings.notchLyricsAlignment != AppSettings.defaultNotchLyricsAlignment {
            parts.append(LyricsAlignmentSegmentedControl.label(for: settings.notchLyricsAlignment))
        }
        // 「副行」(2026-09-06)同一条规则:四选一、默认「下一句」,只在非默认时报,写成「副行 · 译文」。
        if settings.notchSecondaryLine != AppSettings.defaultNotchSecondaryLine {
            parts.append("\(L10n.t("副行")) · \(settings.notchSecondaryLine.displayName)")
        }
        // 「展开时预览下一句」(2026-09-07 从「展开态」搬来):副行选「下一句」时它被顶掉、浮层里也不显示
        // (`NotchLyricRowSettingsRows`),摘要跟浮层说同一套话;没被顶掉就按"只列开着的"。
        if !settings.notchSecondaryLine.hidesExpandedNextLinePreview, settings.notchExpandedShowsNextLine {
            parts.append(NotchBehaviorItem.expandedNextLine.title)
        }
        if settings.notchLyricRowShowsArtwork {
            parts.append("\(NotchEarModule.artwork.displayName) · \(settings.notchLyricRowArtworkPosition.displayName)")
        }
        guard !parts.isEmpty else { return L10n.t("全部关闭") }
        return ListFormatter.localizedString(byJoining: parts)
    }

    /// 「行为」/「展开态」按钮摘要:全开/全关给一句概括,部分开着就把开着的那几项标题
    /// 列出来(短则直接读全,长则交给 toolbarButton 摘要那 140pt 限宽 + 尾部省略处理,
    /// 跟「屏幕」按钮遇到长显示器名同一个兜底,不专门为这里再写一套截断逻辑)。列表拼接
    /// 用 `ListFormatter`(系统 API)而不是手写分隔符——中文按区域习惯给"、"、英文给
    /// ", "/"and",不用为这一个用途单独造一条要翻译的标点字符串。
    @MainActor
    private func behaviorLikeSummary(_ items: [NotchBehaviorItem]) -> String {
        toggleSummary(items.map { (title: $0.title, isOn: $0.binding.wrappedValue) })
    }

    /// 上面那套归约逻辑的本体。2026-09-02 从 `behaviorLikeSummary` 里下沉了一层,吃的是
    /// "标题 + 当前值"而不是某一个具体枚举 —— 因为「行为」浮层那一组的开关**来自两个枚举**
    /// (`NotchBehaviorItem.collapseWhenPaused` + `AutoHideItem` 那两项),摘要必须把两个来源
    /// 都算进去,见 `behaviorSummary`。
    ///
    /// 同一天悬浮歌词的编辑台也要这句摘要(「行为」按钮,见 `OverlayEditorStage.behaviorSummary`),
    /// 归约本体因此又往上提了一层到 `SettingsToggleSummary` —— 它产出的是用户看得见的文案,
    /// 两个编辑台各留一份迟早会漂开。这里保留这个薄包装,只是为了让本文件里三处调用点读起来
    /// 不变。
    @MainActor
    private func toggleSummary(_ entries: [(title: String, isOn: Bool)]) -> String {
        SettingsToggleSummary.text(entries)
    }

    /// 「行为」浮层现在有三项,而且**跨两个枚举**:`NotchBehaviorItem.collapseWhenPaused`
    /// (`.showLyrics` 2026-09-01 搬去了「歌词行」浮层,见 `lyricRowSummary`)+ `AutoHideItem`
    /// 那两项(2026-09-02 从撤掉的独立「自动隐藏」卡并进来的)。
    ///
    /// ⚠️ **两个来源必须都算,而且要跟 `NotchBehaviorPopover` /
    /// `NotchAllSettingsDrawer.behaviorGroup` 的内容一致**:少算自动隐藏那两项不会编译报错,
    /// 只会让这颗按钮在它们开着时照旧显示「全部关闭」—— 一个会撒谎的派生值。
    ///
    /// 三项都开时摘要会拼成一长串(「暂停缩回、截屏/录屏时隐藏、暂停/无播放时隐藏」),交给
    /// `toolbarButton` 里那 140pt 限宽 + 尾部省略处理,跟「屏幕」按钮遇到长显示器名是同一个
    /// 兜底,不为这里另写一套截断。
    private var behaviorSummary: String {
        toggleSummary(
            [(title: NotchBehaviorItem.collapseWhenPaused.title,
              isOn: NotchBehaviorItem.collapseWhenPaused.binding.wrappedValue)]
                + AutoHideItem.allCases.map {
                    (title: $0.title, isOn: $0.binding(for: .notch).wrappedValue)
                })
    }

    /// 「展开态」浮层里的七项(2026-09-07 起「展开时预览下一句」归「歌词行」,不在这里算;同日加「快捷操作」)。曲目信息
    /// 那四项的标题是光秃秃的名词(封面 / 歌名 / 歌手 / 专辑),摘要里读作「显示播放控制、封面、歌名」。
    private var expandedSummary: String {
        behaviorLikeSummary([
            .expandedShowsControls, .expandedShowsLyricsOffset, .expandedShowsQuickActions, .expandedShowsArtwork,
            .expandedShowsTrackTitle, .expandedShowsArtist, .expandedShowsAlbum,
        ])
    }

    /// 「左耳」/「右耳」按钮摘要:这只耳朵的模块名,音浪贴在这一侧时再带上「音浪」(2026-09-07)。
    /// 改前只报模块名,右耳配成「不显示」而音浪开着时按钮写着「右耳 · 不显示」、卡片上却明明有
    /// 五根条子在跳 —— 一个会撒谎的派生值。模块是「不显示」且音浪在这侧时只报「音浪」。
    private func earSummary(_ side: NotchEarPopover.Side) -> String {
        let module = side == .left ? settings.notchLeftEar : settings.notchRightEar
        let equalizerHere = settings.notchShowsEqualizer
            && settings.notchEqualizerEar == (side == .left ? NotchEqualizerEar.left : .right)
        guard equalizerHere else { return module.displayName }
        if module == NotchEarModule.none { return L10n.t("音浪") }
        return ListFormatter.localizedString(byJoining: [module.displayName, L10n.t("音浪")])
    }

    private func toolbarButton(
        icon: String, title: String, summary: String, target: StagePopover
    ) -> some View {
        Button {
            popoverAnchor = .toolbar
            popover = target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    // 图标锁死拉丁语区,理由同 SettingsRow:部分"字母造型"的 SF Symbol 带
                    // CJK 变体,中文界面下会被渲染成汉字。
                    .environment(\.locale, Locale(identifier: "en"))
                Text(title)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.tertiary)
                // ⚠️ 摘要**必须**限宽 + 单行 + 尾部省略:它是派生值,内容里有显示器名这种
                // 长度完全不受控的串。`.layoutPriority(-1)` 让它在标题之前被压 —— 不加的话
                // SwiftUI 会把亏空按比例摊给按钮里所有文字,标题先被截成「风…」「屏…」,
                // 入口的名字没了、摘要却还留着半截,主次正好反过来。
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                    .layoutPriority(-1)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: popoverBinding(target), arrowEdge: .bottom) {
            popoverContent(for: target)
        }
    }

    // MARK: - 浮层

    private enum StagePopover: Equatable {
        case style
        case screen
        case leftEar
        case rightEar
        case lyricRow
        case font
        case behavior
        case expanded
    }

    /// 工具栏那一份 `.popover` 的开关:目标对、**而且**锚点是工具栏才亮 —— 同一个浮层从卡片上点开
    /// 时挂在 `hotspotPopoverAnchor` 那一份上,这里必须保持关着,否则两份 NSPopover 会同时弹。
    private func popoverBinding(_ target: StagePopover) -> Binding<Bool> {
        Binding(
            get: { popover == target && popoverAnchor == .toolbar },
            // 只在关的是"自己"那一份时才清空:popover 已经切到别的目标时,旧那份收到的
            // isPresented=false 不该把新开的这个也一起关掉。
            set: { shown in
                if shown {
                    popoverAnchor = .toolbar
                    popover = target
                } else if popover == target, popoverAnchor == .toolbar {
                    popover = nil
                }
            })
    }

    /// 卡片上那一份 `.popover` 的开关(挂在 `hotspotPopoverAnchor` 上):任何一块区域点开的都走它。
    private var hotspotPopoverBinding: Binding<Bool> {
        Binding(
            get: {
                if case .hotspot = popoverAnchor { return popover != nil }
                return false
            },
            set: { shown in
                if !shown, case .hotspot = popoverAnchor { popover = nil }
            })
    }

    @ViewBuilder
    private func popoverContent(for target: StagePopover) -> some View {
        switch target {
        case .style: NotchStylePopover()
        // 浮层里改完屏幕,编辑台的刘海几何要跟着重算 —— 换到一块没有刘海的外接屏,
        // 画面里那个刘海必须消失。
        case .screen: NotchScreenPopover(onScreenChange: { chrome.refreshGeometry() })
        case .leftEar: NotchEarPopover(side: .left)
        case .rightEar: NotchEarPopover(side: .right)
        case .lyricRow: NotchLyricRowPopover()
        case .font: NotchFontPopover()
        case .behavior: NotchBehaviorPopover()
        case .expanded: NotchExpandedPopover()
        }
    }

    // MARK: - 画布区

    private func stage(stageWidth: CGFloat) -> some View {
        let scale = Self.previewScale(stageWidth: stageWidth, widestCardWidth: expandedCardWidth)
        // 「屏幕顶端」那一组先按放大后的虚拟宽度排版,再整体缩回舞台宽:缩完仿菜单栏条正好横贯舞台。
        let screenWidth = stageWidth / scale
        return ZStack {
            stageBackground
            desktopSurround(stageWidth: stageWidth)
            // 「屏幕顶端」整组:仿菜单栏条 + 卡片 + 刘海。三者描述同一块屏幕的同一条上边缘,所以
            // 一起缩放(只缩卡片会让刘海空当和菜单栏高度对不上)。scaleEffect 不改布局尺寸,
            // 外面再套一层舞台宽的定位框;anchor .top 让顶边钉在屏幕上沿、水平仍居中。
            // 命中测试跟着几何效果一起变换(SwiftUI 的 GeometryEffect 语义),缩过的卡片仍然
            // 只在它画出来的那块上响应 hover。
            ZStack {
                atScreenTop { menuBarStrip(stageWidth: screenWidth) }
                card
                // 刘海画在**卡片之上**:物理刘海是屏幕上真实不发光的一块,任何窗口的像素都到
                // 不了那里。卡片背景本来就铺满整张卡(只有顶行的**内容**给刘海让了空当),
                // 不盖这一层的话,「磨砂玻璃」风格下刘海那一块会被画成半透明的磨砂 —— 而真机上
                // 那里恒为纯黑。
                atScreenTop { notchCutout }
            }
            .frame(width: screenWidth, height: cardAreaHeight, alignment: .top)
            .scaleEffect(scale, anchor: .top)
            .frame(width: stageWidth, height: cardAreaHeight, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            // 从卡片上点开的浮层锚在这块**不缩放**的透明视图上(位置 = 被点的那个矩形经 previewScale
            // 换算到舞台坐标)。不直接把 .popover 挂在可点区域自己身上:它们在 scaleEffect 里面,
            // 而 scaleEffect 不改布局 frame,NSPopover 会按未缩放的位置摆,预览缩过时箭头就指偏了。
            hotspotPopoverAnchor(stageWidth: stageWidth, scale: scale)
            // 调整条摆在最上面:它是**控件**不是内容,任何时候都不该被别的层盖住。
            // 先 padding 再 frame:反过来的话那 12pt 会加在"撑满舞台"的那一层外面,把整块顶高。
            widthBar
                .padding(.bottom, Self.widthBarBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // 宽度用**测出来的实际值**,高度是常量。
        .frame(width: stageWidth, height: stageHeight)
        // ⚠️ 舞台的裁切形状是**顶直角、底圆角**(跟卡片同一个 NotchHangingShape),不是悬浮歌词
        // 编辑台那边的四角全圆。两个理由,第二个是硬的:
        //   ① 语义:这块舞台画的是**屏幕的上沿**,而屏幕上沿是直的。
        //   ② 几何:卡片在舞台里**顶对齐**,顶角是直角。舞台如果在顶上带 12pt 圆角,只要每侧
        //      余量小于 12pt,卡片那两个顶部直角就会落进圆弧要削掉的那块里被削圆 —— 而"1:1
        //      还原它贴在屏幕上沿的样子"正是这块画布的卖点。余量小于 12pt 是**够得着**的:
        //      舞台宽 = 卡片列宽 = min(600, 设置窗内容区 − 40),而侧边栏可以拖到 220
        //      (`.navigationSplitViewColumnWidth(min:170, ideal:190, max:220)`)、窗口可以拖到
        //      minWidth 760,那时舞台只有约 499pt;卡片比舞台宽时整组按 previewScale 缩到恰好
        //      等宽(2026-09-06),余量正好是 0。
        .clipShape(NotchHangingShape(bottomCornerRadius: 12))
        // 舞台自己那条发丝描边画在裁切**之后**:壁纸铺满整块舞台,压在底板上会把它整个盖住,
        // 而这条边是舞台跟设置页之间唯一的分界。透明度 0.12 —— 它描在一张照片上,更淡的档位
        // 在壁纸上基本看不见(这两条都是悬浮歌词编辑台第五步实测出来的,直接沿用)。
        // `.stroke` 而不是 `.strokeBorder`,理由见 windowEdgeOutline。
        .overlay(
            NotchHangingShape(bottomCornerRadius: 12)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    /// 把一块内容摆到"屏幕顶端"那一线:顶对齐,水平居中。
    ///
    /// 菜单栏条、刘海、卡片三者必须走同一个纵向锚点 —— 它们描述的是同一块屏幕的同一条上边缘,
    /// 任何一个单独居中都会跟另外两个错位。(卡片不走这个函数,因为它还要一层定高的命中容器,
    /// 见 card。)
    private func atScreenTop<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 编辑台的底板。读得到桌面壁纸时它整个被 desktopSurround 盖住;读不到时
    /// desktopSurround 退回棋盘格,这块底板就是那些格子底下的地。
    ///
    /// 刻意**不**用 settingsCardBackground 那套液态玻璃:玻璃的可见度完全取决于背后有什么,
    /// 而这块底板上压着的是真实桌面壁纸 —— 玻璃只会让"哪里是壁纸、哪里是设置页"这条边界更糊。
    private var stageBackground: some View {
        NotchHangingShape(bottomCornerRadius: 12)
            .fill(Color.primary.opacity(0.05))
    }

    // MARK: - 舞台那片屏幕顶端

    /// 铺满整个舞台的桌面壁纸 —— **舞台是一小片屏幕**,灵动岛卡片 1:1 挂在它的上边缘。
    ///
    /// 跟悬浮歌词编辑台走的是同一份实现(OverlayDesktopSurface),不在这里手搓第二份:
    /// 尤其是读不到壁纸时的棋盘格,格子大小/相位/配色只要有一处不同,两段设置页一对比就露馅。
    ///
    /// 薄纱那一层**均匀**盖住整块舞台,只负责把这一小片屏幕压得别在设置页里太抢眼。均匀是
    /// 硬要求 —— 任何"只压某一块"的遮罩都会随卡片宽度变形,那就变成"改宽度把背景也改了"
    /// (悬浮歌词编辑台第七步为这件事付过一次代价,用户原话「背景永远不要变」)。
    private func desktopSurround(stageWidth: CGFloat) -> some View {
        OverlayDesktopSurface()
            .frame(width: stageWidth, height: stageHeight)
            .clipped()
            .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.16))
            // 舞台上的桌面不是任何可操作的东西,点它什么也不该发生。
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 舞台顶端那一条仿菜单栏。
    ///
    /// 它不是装饰:灵动岛这个形态的全部特征就是"贴着屏幕最上沿、压在菜单栏那一条上"。
    /// 改版前的钉条把卡片悬空放在设置页底色上,那块画面里没有任何东西说明它挂在哪儿。
    ///
    /// ⚠️ 材质用 `.ultraThinMaterial` 而不是 `.bar`:`.bar` 在浅色外观下几乎不透明,压上去
    /// 直接把壁纸糊成一块灰,而真菜单栏的透明度高得多 —— 深色壁纸下整条菜单栏是深的、文字
    /// 自动转白,那正是它一眼认得出来的原因(2026-08-16 菜单栏预览条实拍确认过,这里直接
    /// 沿用同一条结论)。
    ///
    /// 两侧那几个图标和时钟只是**参照物**,让"卡片占了菜单栏多宽"看得出来 —— 卡片够宽时会
    /// 把它们盖住,那正是真机上会发生的事,不是渲染出错。用真实时钟而不是写死一个时间:
    /// 假数据会让人下意识觉得这块预览"不是真的"(同菜单栏预览条那条)。
    private func menuBarStrip(stageWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "apple.logo")
                .padding(.leading, 12)
            Spacer(minLength: 0)
            HStack(spacing: 11) {
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text(Date(), style: .time)
            }
            .padding(.trailing, 12)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(nsColor: .labelColor).opacity(0.6))
        .frame(width: stageWidth, height: chrome.contentTopInset)
        .background(.ultraThinMaterial)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 物理刘海。
    ///
    /// 形状复用卡片自己那个「顶直角、底圆角」的 NotchHangingShape —— 真刘海就是这个轮廓,
    /// 而且用同一个 Shape 意味着圆角画法只有一份。圆角 8 比卡片的 20 小:刘海本身的下沿
    /// 收得比卡片紧。
    ///
    /// 无真刘海的屏幕(外接显示器)`notchWidth == 0`,这里什么都不画 —— 那种屏上灵动岛就是
    /// 一块贴着菜单栏顶边的胶囊,没有刘海可言,画一个是撒谎。
    @ViewBuilder
    private var notchCutout: some View {
        if chrome.notchWidth > 0 {
            NotchHangingShape(bottomCornerRadius: 8)
                .fill(Color.black)
                .frame(width: chrome.notchWidth, height: chrome.contentTopInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 舞台上边缘挂着的那张卡 —— **真窗口那份 NotchLyricsView 本体**。
    ///
    /// 两只耳朵上的歌名和三个播放按钮、给刘海让出的空当、歌词行尾端的封面缩略图、逐字高亮、
    /// 跑马灯、hover 展开出来的下一句 + 迷你进度条 —— 一律由真视图自己画,这边一行渲染代码
    /// 都没有,也就没有第二份会漂的实现(这条从 NotchPreviewBar 就是这么做的,别退回去手搓)。
    ///
    /// 宽度必须**恰好等于**真窗口算出来的那个值:真视图内部按 `proxy.size.width` 反推两只
    /// 耳朵的宽度,给个别的宽度耳朵就错位了。
    ///
    /// 命中判定显式做,不吃 SwiftUI 的隐式 hover 范围:外层那一层的局部坐标原点正好落在卡片
    /// 左上角(卡片顶对齐、两者等宽),所以"鼠标在不在卡片上"就是一句 y 的比较。cardHeight
    /// 本身会随展开变高,于是展开后鼠标继续往下移进新长出来的那 76pt 仍然算在卡片上、维持
    /// 展开 —— 跟真窗口"展开时窗口一起变高"是同一个行为,展开出来的内容才够得着。
    ///
    /// ⚠️ **卡片内部一律不接事件**(`.allowsHitTesting(false)`)。改版前它天然点不动 —— 预览
    /// 在页顶钉条里,那一层收不到点击;挪进内容区之后,真视图里那一整套控件突然全都可达了:
    /// 三个播放键、可拖的迷你进度条、以及歌词行尾端那枚**封面缩略图**(它打的是
    /// `AppActions.shared.openLyricsWindow`,会 `NSApp.activate` + 开一扇歌词窗口直接盖在
    /// 用户正在调的设置窗口上)。在一块用来"看样子"的画布上误点一下就改播放进度、或者凭空
    /// 弹出一扇窗,不是想要的行为 —— 本仓对预览的既定口径就是**不产生任何副作用**(见
    /// `NotchPreviewChrome.setExpanded` 和 `OverlayPreviewChrome.controlsDidBecomeVisible`
    /// 两处空实现),这里只是把同一条口径贯彻到真视图那一侧。悬浮歌词编辑台的做法(第十步
    /// 删掉画布上所有命中区)是同一件事的另一种写法。
    ///
    /// ⚠️ hover 展开**不受影响**:`.onContinuousHover` 挂在外层那个定高容器上(不在被禁用的
    /// 子树里),而且紧挨着它显式加了一句 `.contentShape(Rectangle())` 把整格钉成命中形状 ——
    /// 既保证 hover 一定收得到,也顺手把落在卡片上的点击**吞掉**(不会穿到底下那张桌面上)。
    ///
    /// ⚠️ **例外:卡片上叠了一层"可点区域"(`hotspotLayer`,2026-09-06)** —— 那不是真视图里的控件
    /// 重新可达,而是编辑台自己按几何算出来的几块透明命中区(左耳 / 右耳 / 曲目信息头部 / 歌词行 /
    /// 展开区),点一下打开**管这块的浮层**(用户:「类似这些区域帮我调整成可以点击来换取相应的
    /// 配置」)。它们仍然不碰播放、不开窗口,"预览不产生副作用"这条口径没破;打开的浮层就是工具栏
    /// 那几个,但**锚在被点的那块区域旁边**(用户第二轮要求「就从我点击的这个位置弹出来」;第一版锚在
    /// 工具栏按钮上被否),从区域的**侧边**弹出(耳朵朝外、整行朝右,见 `CardHotspot.arrowEdge`)——
    /// 压在卡片上面会挡住正要看的东西。
    ///
    /// ⚠️ 卡片按**真实 pt** 排版(视图内层按 `proxy.size.width` 反推耳宽,给别的宽度耳朵就错位),
    /// "放不下"由外层 `stage` 对「屏幕顶端」整组做 `scaleEffect` 解决(见 previewScale),这里不知道
    /// 也不该知道缩放这回事;hover 判定用的 `point.y` 是本地(未缩放)坐标,跟 `cardHeight` 同一把尺。
    ///
    /// **从卡片上点开**的浮层开着时预览**钉在展开态**(`keepsExpandedForPopover`,用户:「我一旦选中有弹窗
    /// 出来的期间,你不要去把它的展开态给关闭了,一直维持着展开状态」):从卡片上点开浮层时卡片本来就是
    /// 展开的,浮层一开它缩回去就是"选中的东西自己变形了"。**从工具栏点开的不钉**(用户第四轮:「点开
    /// 这些选项,不要把下面的自动展开呀」)—— 工具栏那条路卡片本来是稳态,凭空展开是多余的动作;
    /// 想看展开区的效果把指针移到卡片上即可,跟以前一样。中间有过一版"任一浮层都钉"(含工具栏),被否。
    private var card: some View {
        NotchLyricsView(controller: chrome)
            // 先钉当下的真实尺寸:视图内层是 GeometryReader,耳朵宽度按 proxy.size.width 算,
            // 给错尺寸这一层就先失真了。
            .frame(width: cardWidth, height: cardHeight)
            // 两种形态的真实宽推给替身 chrome(歌词行按它们定宽,见 NotchChromeSource.steadyCardWidth):
            // 拖宽度滑块时逐帧变,onChange 比卡片晚一帧跟上,16ms 肉眼不可辨。
            .onAppear { chrome.setCardWidths(steady: steadyCardWidth, expanded: expandedCardWidth) }
            .onChange(of: steadyCardWidth) { _, w in chrome.setCardWidths(steady: w, expanded: expandedCardWidth) }
            .onChange(of: expandedCardWidth) { _, w in chrome.setCardWidths(steady: steadyCardWidth, expanded: w) }
            .allowsHitTesting(false)
            // 可点区域压在真视图之上、轮廓之下;它在 allowsHitTesting(false) **之后**挂上,所以自己
            // 收得到 hover / 点击。
            .overlay(alignment: .topLeading) { hotspotLayer }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: chrome.isExpanded)
            // 再顶对齐放进定高容器 —— 真窗口也是顶边贴死屏幕顶、只向下长。
            .frame(width: cardWidth, height: cardAreaHeight, alignment: .top)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    chrome.setExpandedFromPreview(point.y <= cardHeight || keepsExpandedForPopover)
                case .ended:
                    chrome.setExpandedFromPreview(keepsExpandedForPopover)
                }
            }
            .onChange(of: popover) { _, newValue in
                // 从卡片上点开的浮层开 → 钉在展开;关 → 放开(指针若还在卡片上,下一次 hover 事件会
                // 再展开)。从工具栏点开的两头都不碰:开时不展开、关时也不去收(收放仍归 hover 管)。
                // popoverAnchor 在关闭时保持着上一个浮层的锚点,所以关的时候也能分辨它是从哪开的。
                guard case .hotspot = popoverAnchor else { return }
                if newValue != nil {
                    chrome.setExpandedFromPreview(true)
                } else if adjustingThumb == nil {
                    chrome.setExpandedFromPreview(false)
                }
            }
            // 卡片那圈轮廓压在卡片上,理由见 windowEdgeOutline。
            .overlay(alignment: .top) { windowEdgeOutline }
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 从卡片上点开的浮层开着时预览钉在展开态(工具栏点开的不钉),理由见 `card` 的注释。
    private var keepsExpandedForPopover: Bool {
        guard popover != nil, case .hotspot = popoverAnchor else { return false }
        return true
    }

    // MARK: - 预览卡上的可点区域

    /// 预览卡上一块可点的区域:点它打开管这块内容的浮层(2026-09-06,用户:「类似这些区域帮我
    /// 调整成可以点击来换取相应的配置的逻辑」)。
    ///
    /// **同一个浮层管的内容只算一块**(用户第二轮:「现在拆的太密了,你需要把那些一样的都给它整合在
    /// 一起」;第一版把展开区拆成下一句 / 进度条 / 播放键三块、曲目信息头部又一块,四块都开「展开态」)。
    /// 一块区域可以由**多个矩形**组成 —— 「展开态」那块 = 歌词行之上的曲目信息头部 + 下一句预览之下的
    /// 进度条与播放键,中间隔着歌词行(含下一句),悬在任一个上两块一起亮、点任一个都开同一个浮层
    /// (锚在被点的那个上)。
    ///
    /// `rects` 是**卡片本地、未缩放**坐标(原点卡片左上角),跟 `NotchLyricsView.body` 那棵 VStack
    /// 的排版逐段对应:顶行两只耳朵 → 曲目信息头部(展开且开着才有)→ 歌词行(`showsLyricRow`)
    /// **+ 紧跟着的「下一句预览」**(展开且开着才有)→ 展开区剩下的(进度条 / 播放键)。高度全部取自
    /// 跟渲染同一份的度量(`contentTopInset` / `expandedTrackInfoHeaderHeight` / `compactRowHeight` /
    /// `NotchExpandedMetrics.lyricPreviewBlock` / `cardHeight`),不另写数字 —— 渲染那边一改这里就跟着对。
    ///
    /// ⚠️ 「下一句预览」划给**歌词行**那块、不划给展开态(用户第三轮:「这个框不应该把这个歌词行也包括
    /// 进去。选中歌词行的时候,应该把下面那个下一行歌词也包进去」):它在用户眼里是"第二行歌词",跟
    /// 上面那行是一回事;而且「歌词行」浮层里的「对齐方式」确实也管它。它的开关(`notchExpandedShowsNextLine`)
    /// 仍在「展开态」浮层里,没跟着搬。
    private struct CardHotspot: Identifiable {
        enum Kind: Hashable {
            case leftEar, rightEar, lyricRow, expanded
        }
        let kind: Kind
        let rects: [CGRect]
        let target: StagePopover
        /// 无障碍标签用的浮层名(跟工具栏按钮标题同一份文案)。
        let title: String
        /// 浮层从矩形的哪条边弹出:耳朵朝**外**(左耳往左、右耳往右),整行的朝右 —— 四种情形里浮层
        /// 都不压在卡片上,改一项当场看得见。
        let arrowEdge: Edge
        var id: Kind { kind }
    }

    private var cardHotspots: [CardHotspot] {
        let width = cardWidth
        let earWidth = max(0, (width - chrome.notchWidth - NotchMetrics.cardHorizontalPadding * 2) / 2)
        let top = chrome.contentTopInset
        var spots: [CardHotspot] = [
            CardHotspot(kind: .leftEar,
                        rects: [CGRect(x: NotchMetrics.cardHorizontalPadding, y: 0, width: earWidth, height: top)],
                        target: .leftEar, title: L10n.t("左耳"), arrowEdge: .leading),
            CardHotspot(kind: .rightEar,
                        rects: [CGRect(x: width - NotchMetrics.cardHorizontalPadding - earWidth, y: 0,
                                       width: earWidth, height: top)],
                        target: .rightEar, title: L10n.t("右耳"), arrowEdge: .trailing),
        ]
        var y = top
        var expandedRects: [CGRect] = []
        if chrome.isExpanded, chrome.showsExpandedTrackInfo {
            let height = chrome.expandedTrackInfoHeaderHeight
            expandedRects.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        if chrome.showsLyricRow {
            var lyricHeight = NotchMetrics.compactRowHeight
            // 展开时紧跟在歌词行下面的「下一句预览」并进同一个矩形(理由见类型注释那条⚠️)。
            // 它是 expandedContent 的第一个子视图,跟歌词行在布局上是连着的,所以能合成一块。
            if chrome.isExpanded, chrome.showsExpandedLyricPreview {
                lyricHeight += NotchExpandedMetrics.lyricPreviewBlock
            }
            spots.append(CardHotspot(kind: .lyricRow,
                                     rects: [CGRect(x: 0, y: y, width: width, height: lyricHeight)],
                                     target: .lyricRow, title: L10n.t("歌词行"), arrowEdge: .trailing))
            y += lyricHeight
        }
        if chrome.isExpanded, cardHeight > y {
            // 下一句预览以下到卡片底边(进度条 / 播放键)算展开态那块的第二个矩形。
            expandedRects.append(CGRect(x: 0, y: y, width: width, height: cardHeight - y))
        }
        if !expandedRects.isEmpty {
            spots.append(CardHotspot(kind: .expanded, rects: expandedRects,
                                     target: .expanded, title: L10n.t("展开态"), arrowEdge: .trailing))
        }
        return spots
    }

    /// 全部可点区域,按 `rects` 摆在卡片本地坐标里。压在真视图之上(真视图 `allowsHitTesting(false)`,
    /// 这一层自己接事件)。
    private var hotspotLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cardHotspots) { spot in
                ForEach(Array(spot.rects.enumerated()), id: \.offset) { index, rect in
                    hotspotView(spot, rectIndex: index)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
    }

    /// 一块可点区域的一个矩形:平时完全透明,指针悬上去(悬在**同一块**的任一矩形上)描一圈白色**虚线**
    /// 细框 + 一层极淡的白底(告诉用户"这块能点"),指针换成手形;点一下打开 `spot.target` 那个浮层,
    /// 锚在这个矩形旁边(见 `hotspotPopoverAnchor`)。
    ///
    /// 虚线 + 七成不透明(用户第三轮:「这个框框的边框不要那么硬,可以用一些虚线之类的」;首版是 0.9 实线)。
    /// 线型跟拖宽度时那圈 `windowEdgeOutline` 同一套(4-3 虚线、1pt),编辑台里两种"临时标注框"长一个样。
    /// 内缩 2pt 是让相邻两块(歌词行和它上下的区域)的高亮框不贴在一起;点击命中区仍是整块
    /// (`contentShape` 在 padding 之外)。白色不跟深浅色走,理由同 `windowEdgeOutline`:它压在
    /// 四种卡片风格上,语义色在封面模糊底上读不出来。
    private func hotspotView(_ spot: CardHotspot, rectIndex: Int) -> some View {
        let hovering = hoveredHotspot == spot.kind
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(hovering ? 0.07 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(hovering ? 0.7 : 0),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .padding(2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredHotspot = spot.kind
                    NSCursor.pointingHand.push()
                } else {
                    if hoveredHotspot == spot.kind { hoveredHotspot = nil }
                    NSCursor.pop()
                }
            }
            .onTapGesture { openPopover(for: spot, rectIndex: rectIndex) }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityElement()
            .accessibilityLabel(String(format: L10n.t("打开「%@」设置"), spot.title))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openPopover(for: spot, rectIndex: rectIndex) }
    }

    private func openPopover(for spot: CardHotspot, rectIndex: Int) {
        popoverAnchor = .hotspot(spot.kind, rectIndex: rectIndex)
        popover = spot.target
    }

    /// 从卡片上点开的浮层真正挂着的那块透明锚点视图:摆在**舞台坐标**里、跟被点的矩形重合
    /// (卡片本地坐标经 previewScale 换算 —— 「屏幕顶端」整组以顶边中点为锚缩放、水平居中舞台,
    /// 所以 x = 舞台中线 + (本地 x − 卡宽/2) × 比例,y = 本地 y × 比例)。
    ///
    /// 视图**常驻**、不按需插入:`.popover(isPresented:)` 挂在一个刚插进视图树、isPresented 已经是
    /// true 的视图上,NSPopover 有时不弹;常驻一块 0×0 的透明视图,要弹时先挪到位再翻开关,稳。
    /// 没在弹时它是原点处一个 0×0 的点,`allowsHitTesting(false)`,对什么都没有影响。
    private func hotspotPopoverAnchor(stageWidth: CGFloat, scale: CGFloat) -> some View {
        var rect = CGRect.zero
        var arrowEdge: Edge = .bottom
        var target: StagePopover?
        if case .hotspot(let kind, let index) = popoverAnchor,
           let spot = cardHotspots.first(where: { $0.kind == kind }),
           index < spot.rects.count {
            let local = spot.rects[index]
            rect = CGRect(x: stageWidth / 2 + (local.minX - cardWidth / 2) * scale,
                          y: local.minY * scale,
                          width: local.width * scale, height: local.height * scale)
            arrowEdge = spot.arrowEdge
            target = spot.target
        }
        // 用 padding 定位而不是 offset:offset 是几何效果、不改布局 frame,NSPopover 认的是布局 frame。
        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .popover(isPresented: hotspotPopoverBinding, arrowEdge: arrowEdge) {
                if let target { popoverContent(for: target) }
            }
            .padding(.leading, rect.minX)
            .padding(.top, rect.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 拖宽度时把卡片的左右边界描出来。
    ///
    /// 灵动岛跟悬浮歌词不同:它的背景**永远**画得出来(四种风格没有"全透明"那一档),所以
    /// 不需要悬浮歌词那圈**常驻**的虚线轮廓 —— 卡片自己就是可见的边界。这里只在按住调整条
    /// 那一刻描一圈,把"我正在改的是这张卡的宽度"钉死;松手就淡掉,免得平时多一个假边框。
    ///
    /// 固定白色 + 黑色投影,**不跟深浅色模式走**:它压在用户真实的桌面壁纸上,那块底色什么
    /// 样完全不受 App 控制,语义色(primary/secondary)在浅壁纸上会直接读不出来;投影负责在
    /// 亮壁纸上给白线兜一圈暗轮廓。(这条规矩连同下面 widthBar 的三层配色都是悬浮歌词编辑台
    /// 实测定下来的,直接沿用。)
    private var windowEdgeOutline: some View {
        // ⚠️ `.stroke` 而不是 `.strokeBorder`:后者只有 InsettableShape 才有,而
        // NotchHangingShape 是手写的普通 Shape(顶直角底圆角,UnevenRoundedRectangle 要
        // macOS 26 才有)。代价是这条线**骑在**卡片边界上、各半个像素在内外,而不是完全
        // 描在里侧 —— 1pt 的虚线看不出区别,不值得为此给那个共用形状加一层 inset 实现。
        NotchHangingShape(bottomCornerRadius: 20)
            .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .shadow(color: .black.opacity(0.55), radius: 1)
            .frame(width: cardWidth, height: cardHeight)
            // 用透明度而不是 if 分支:轮廓始终在视图树里,按下/松开才淡得起来。
            .opacity(adjustingThumb != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: adjustingThumb != nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 「屏幕顶端」整组的预览缩放比:放得下就 1(1:1),放不下就缩到**最宽形态**刚好等于舞台宽。
    ///
    /// **按展开真实宽算,不按此刻画的卡片宽**:hover 时卡片从稳态宽长到展开宽,要是比例跟着此刻的
    /// 宽度走,鼠标一进一出整块屏幕就会忽大忽小;钉在展开宽上,稳态和展开态在同一把尺子下,展开时
    /// 恰好把舞台撑满。拖上限那只滑块时展开宽在变,比例跟着连续变,是预期的("越拉越宽,预览越小")。
    ///
    /// 0.5 的余量:宽度量化到 2pt、舞台宽度是测出来的浮点数,差几个 0.0x 不该触发缩放。
    /// `widestCardWidth <= 0` 不做除法,直接 1。
    static func previewScale(stageWidth: CGFloat, widestCardWidth: CGFloat) -> CGFloat {
        guard widestCardWidth > stageWidth + 0.5, widestCardWidth > 0 else { return 1 }
        return stageWidth / widestCardWidth
    }

    // MARK: - 宽度调整条

    /// 舞台内部、卡片正下方那条宽度调整条 —— 2026-09-06 起是**双滑块**(`RangeSlider`):左边那只
    /// 是稳态宽(下限,没 hover 时卡片多宽),右边那只是展开宽(上限,hover 展开后撑到多宽)。
    /// 用户原话:「配置宽度的时候可以设置一个上限和一个下限,下限就是正常状态的宽度,上限就是
    /// 悬浮展开时候的宽度」。两只滑块重叠 = 展开不加宽(老用户升级后的样子)。
    ///
    /// 摆在**舞台里面**而不是舞台底下那行 caption 旁边,是因为它得跟它改的那张卡待在同一块
    /// 画面里:卡片两侧和下方现在露着桌面,调整条压在桌面上、正对卡片下沿,"这根条改的是
    /// 上面这张卡的宽度"不用另写一句话解释。
    ///
    /// **拖哪只滑块,卡片就按哪种形态画**:按住展开那只时把预览 chrome 置成展开态(卡片变宽也变高,
    /// 就是 hover 时的样子),松手复原;按住稳态那只时确保是稳态。不这么做的话拖上限时鼠标在
    /// 滑杆上、卡片没被 hover,那只滑块改的宽度在画布上**看不见**,而"改一项、当场看见"正是编辑台
    /// 的全部意义。
    ///
    /// ⚠️ 配色**固定黑底白字 + 投影,不跟深浅色模式走**:它底下垫的是用户真实的桌面壁纸。
    /// 三层各司其职:半透明黑胶囊把滑杆和读数从任意壁纸里托出来;白色发丝描边负责在**深**
    /// 壁纸上给胶囊自己留一圈边界;投影负责在**亮**壁纸上兜一圈暗轮廓。滑杆的 `.white` tint
    /// 同理 —— 默认强调色跟着系统主题走,压在壁纸上深浅不定。
    private var widthBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
            // 两只滑块共用同一个可拖区间(下界 = 这台机器当前配置下的耳朵下限);"展开不越过
            // 稳态"由 RangeSlider 内部的 NotchWidthRangeDrag 管,不靠区间。量化 step 2,不画刻度。
            RangeSlider(
                lower: baseWidth, upper: expandedBaseWidth,
                range: Self.usableWidthRange(notchWidth: chrome.notchWidth,
                                             contentTopInset: chrome.contentTopInset),
                step: Self.widthStep, tint: .white,
                lowerLabel: L10n.t("灵动岛宽度"), upperLabel: L10n.t("灵动岛展开宽度"),
                valueText: { String(format: L10n.t("%@pt"), "\(Int($0))") },
                onChange: { steady, expanded in
                    // 拖动中**只**改本地 @State,理由见 draggingSteady 的注释。落盘与通知真窗口都
                    // 推迟到 onEditingChanged 收到 nil 那一下。
                    draggingSteady = steady
                    draggingExpanded = expanded
                },
                onEditingChanged: { thumb in
                    adjustingThumb = thumb
                    switch thumb {
                    case .expanded?:
                        chrome.setExpandedFromPreview(true)
                    case .steady?:
                        chrome.setExpandedFromPreview(false)
                    case nil:
                        // 松手:把拖动中攒下的那对值提交出去,然后交还给 settings 当真源。
                        // 展开态由「展开态」浮层钉着的话不放开(见 keepsExpandedForPopover)。
                        chrome.setExpandedFromPreview(keepsExpandedForPopover)
                        if draggingSteady != nil || draggingExpanded != nil {
                            Self.commitWidths(steady: draggingSteady, expanded: draggingExpanded)
                            draggingSteady = nil
                            draggingExpanded = nil
                        }
                    }
                })
            .frame(width: Self.widthBarSliderWidth)
            Text(widthValueText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
                // 读数是滑块的镜像、不是第二个可读元素:都进无障碍树的话 VoiceOver 会把同一个
                // 值读两遍(两只滑块各自带着 accessibilityValue)。
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
    }

    /// "360pt" / "360–460pt" 这种带单位的读数:稳态宽 = 展开宽时只报一个数(展开不加宽),否则
    /// 报「稳态–展开」两个。
    ///
    /// ⚠️ 报的是**卡片真实宽度**(`steadyCardWidth` / `expandedCardWidth`,已经过"两只耳朵放得下
    /// 按钮"的下限和「展开 ≥ 稳态」),不是设定值(2026-08-31 用户要求:「这里的宽度帮我改为带上
    /// 耳朵的宽度,这样就没有歧义了」)。此前报设定值、再由 caption 补一句「已被两侧耳朵撑到
    /// NNNpt」—— 同一件事两个数字、还得配一句话解释它们的关系。现在数字跟眼前这张卡逐像素对
    /// 得上,那句 caption 也就删了。
    ///
    /// (2026-08-31 当天稍后:滑杆下界抬到耳朵下限之后,"拖了数字不动"那截死区已经不存在了 ——
    ///  见 usableWidthRange。这条口径仍然留着:它让**历史上落盘过的**、低于下限的旧值也显示得对。)
    ///
    /// ⚠️ 走真实宽而不是 `settings.notch*Width`:后者在拖动期间不更新(落盘推迟到松手),读数会
    /// 冻住而卡片却在跟着变宽,看着像坏了。真实宽读的是 `baseWidth` / `expandedBaseWidth`,拖动中跟手。
    private var widthValueText: String {
        let steady = Int(steadyCardWidth)
        let expanded = Int(expandedCardWidth)
        if expanded == steady {
            return String(format: L10n.t("%@pt"), "\(steady)")
        }
        return String(format: L10n.t("%@–%@pt"), "\(steady)", "\(expanded)")
    }

    // MARK: - 底部说明

    /// 舞台底下那行小字。
    ///
    /// **常态是空的**。唯一会出现的是「预览已缩小至 NN%」—— 展开宽超过舞台宽、整组被
    /// `previewScale` 缩过时(理由见下面)。跟悬浮歌词编辑台的 caption 同一个口径:只在真的有话说时才写字。
    private func caption(stageWidth: CGFloat) -> some View {
        Text(captionText(stageWidth: stageWidth))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func captionText(stageWidth: CGFloat) -> String {
        var parts: [String] = []
        // (2026-08-31 这一行先后删掉了两截,现在**常态是空的**:
        //   ① 「已被两侧耳朵撑到 NNNpt」—— 调整条旁边的读数已经直接报带耳朵的真实宽度,
        //      同一件事不必再用一句话解释一遍;
        //   ② 「指向可展开」—— 用户要求去掉。
        //  跟悬浮歌词编辑台的 caption 现在是同一个口径:只在真的有话说时才出现。)
        // 「预览已缩小至 NN%」:展开宽放不进舞台、整组被缩过时出现(2026-09-06,随宽度上限 500 → 800)。
        // 上限 500 那会儿这里是一句"正常情况下永远不出现"的「两端已裁切」兜底(500 vs 舞台最窄约 499);
        // 抬到 800 后先按悬浮歌词那套裁切 + 渐隐做过一版,用户否掉(「太大之后,预览放不下」),改成
        // 缩放。这块画布的卖点本是 1:1,缩过就必须说出来,否则用户会把缩过的尺寸当真。
        let scale = Self.previewScale(stageWidth: stageWidth, widestCardWidth: expandedCardWidth)
        if scale < 1 {
            parts.append(String(format: L10n.t("预览已缩小至 %@"), "\(Int((scale * 100).rounded()))%"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 工具栏摘要

/// 「屏幕」那颗按钮上的摘要。
///
/// ⚠️ 不能存成 `static let`:`L10n.t` 要在每次取值时现算,存进 static let 等于把首次访问时的
/// 语言冻在里面(同 OverlayAlignmentSegmentedControl.label(for:) 那条)。
@MainActor
enum NotchScreenSummary {
    static var current: String {
        let settings = AppSettings.shared
        if settings.notchAllScreens { return L10n.t("所有屏幕") }
        if settings.notchScreenID.isEmpty { return L10n.t("自动") }
        if let screen = ScreenIdentity.screen(withID: settings.notchScreenID) {
            return screen.localizedName
        }
        // 存着的那块屏现在没接着。报"自动"是撒谎(偏好还在,屏幕插回来就会恢复),
        // 报一个空串更糟。
        return L10n.t("已断开的屏幕")
    }
}

// MARK: - 「风格」浮层

/// 「✦ 风格」浮层。四种卡片背景四选一。
///
/// ⚠️ 用**单选列表**而不是原来那个 `.pickerStyle(.menu)` 下拉,有两个具体理由:
///   ① 菜单点一次只能试一个:选中即收起,想比较四种就得开合四次。列表在浮层里点完**不关**,
///      而浮层只有 270pt 宽、舞台有 600pt —— 卡片右半边一直露着,四种风格可以点着看过去。
///      这正是编辑台范式要的东西(改一项、当场看见)。
///   ② 下拉是"把一个 NSMenu 开在一个 transient NSPopover 里",两层的关闭时机得靠系统巧合
///      对齐;单选列表全在浮层自己这一层,没有这层不确定性。
/// 代价是四行比一行下拉高,而这个浮层里就这一组,纵向有的是空间。
///
/// ⚠️ 宽度 270 是**量出来的**,不是外壳那个 380 的默认值(见 `SettingsPopoverShell.width`)。
/// 离屏 `NSHostingView.fittingSize`:内容自然宽中文 221pt / 英文 242pt。270 给英文留
/// 28pt 余量。2026-08-31「显示歌词」那行搬去下面单独一张卡之后,四行风格名成了这个浮层
/// 唯一的内容,没有重新量过收窄的空间——留着 270 偏保守但不会截断,不去动它。
@MainActor
struct NotchStylePopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("风格"), width: 270) {
            NotchStyleSettingsRows()
        }
    }
}

/// 「显示歌词」开关(2026-08-31 用户要求:「多一种形态,对于有一些想要显示播放状态、但又不想
/// 有歌词挡住视线的人」)。关掉之后卡片只剩顶行那一条,退化成贴着刘海的状态栏。
///
/// 2026-08-31 从「风格」浮层里搬出来,单独放在编辑台下面自己一张卡(用户明确要求"不要合并到
/// 风格里面去")——它跟四种背景不是同一类东西:一个是卡片长什么样、一个是卡片还剩几行,
/// 值得有自己独立的位置。放在设置页正常流里而不是再开一个工具栏入口,理由不变:工具栏
/// 横向空间已经被四个入口占满(窄窗约 499pt,见 toolbar 那段横向账)。
@MainActor
struct NotchShowLyricsRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.alignleft",
            title: L10n.t("显示歌词"),
            help: L10n.t("关掉后稳态只保留刘海那条高度，不显示歌词；指向展开时播放控制、进度条、下一句预览仍照常显示。")
        ) {
            Toggle("", isOn: $settings.notchShowLyrics)
        }
    }
}

/// 「暂停时缩到最小」开关(2026-08-31 用户要求把这个一直以来的默认行为开放成可关的配置项)。
/// 关掉之后暂停(或广告插播)时卡片不再收缩,保持原来的稳态/展开尺寸,歌名/歌词照常显示
/// (位置冻结在暂停那一刻)。
///
/// 跟 `NotchShowLyricsRow` 放在同一张卡里(见调用点):两者都是"暂停/播放时卡片还剩多少
/// 内容"这一类设置,跟「风格」浮层里那四种背景不是一回事,值得分在一起但各自一行。
@MainActor
struct NotchCollapsesWhenPausedRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "arrow.down.right.and.arrow.up.left",
            title: L10n.t("暂停缩回")
        ) {
            Toggle("", isOn: $settings.notchCollapsesWhenPaused)
        }
    }
}

/// 四种风格的单选列表。行的度量(图标列宽 / 间距 / 内边距)一律走 `SettingsRowMetrics`,
/// 跟同一张浮层里别的行对齐 —— 别在这里写字面量。
@MainActor
struct NotchStyleSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // 顺序直接用 allCases(声明序),不另抄一份数组 —— 抄一份的话以后往枚举里加一种
            // 风格,这里不加就是"设置里选不到的合法值"。
            ForEach(Array(NotchCardStyle.allCases.enumerated()), id: \.element) { index, style in
                if index > 0 { CardDivider() }
                row(style)
            }
        }
    }

    private func row(_ style: NotchCardStyle) -> some View {
        let isSelected = settings.notchCardStyle == style
        return Button {
            // 相等守卫:@Published 是 willSet 语义,等值赋值照样广播 objectWillChange 打醒
            // 所有观察 AppSettings 的界面,didSet 还会白写一次 UserDefaults。
            guard settings.notchCardStyle != style else { return }
            settings.notchCardStyle = style
        } label: {
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                // 勾**始终占位**(不选中时透明),否则选中项一变、整列文字就横向跳一格。
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(style.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                // 整行可点靠下面那句 contentShape,而它认的是 HStack 的实际尺寸 —— 没有
                // Spacer 撑满宽度,命中区就缩回"勾 + 几个字"那一小截。
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 恢复默认

/// 「重置」按钮(工具栏第一行右侧)的动作本体——逐字复刻悬浮歌词那边的写法
/// (`OverlayStyleDefaults.restoreTextAndColors()`):抽成独立函数而不是留在按钮闭包里,
/// 理由同源:以后要是再给这份设置开一个"全部设置"抽屉里的兜底恢复入口,两处调同一个
/// 函数才不会走出"从工具栏恢复和从抽屉恢复,恢复出来的样子不一样"这种岔子。
///
/// 范围(2026-09-01 跟用户确认过,三选一里选的是最宽的一档):风格 + 左右耳 + 屏幕 + 这个
/// 形态全部的内容开关(歌词行/行为/展开态/音浪那一批布尔量,含各自的从属选择器)。
/// **不碰** `notchOverlayEnabled`(灵动岛总开关——重置一个"外观/内容默认值"的按钮，不该
/// 顺手把整个功能关掉)和 `notchContentWidth`(宽度——结构性尺寸设置,跟悬浮歌词「重置」
/// 明确排除宽度和锁定位置是同一条取舍)。
///
/// 每个字段的默认值只在 `AppSettings.defaultNotchXxx` 里出现一次、`AppSettings.init()`
/// 也读同一份——不在这里重新写一遍字面量,理由同 `defaultFollowsCoverArt` 那组:两处各自
/// 硬编码,以后改默认值容易漏掉其中一处,变成"点了重置却恢复不出真正默认值"。
@MainActor
enum NotchStyleDefaults {
    static func restoreDefaults() {
        let settings = AppSettings.shared
        settings.notchCardStyle = AppSettings.defaultNotchCardStyle
        settings.notchLeftEar = AppSettings.defaultNotchLeftEar
        settings.notchRightEar = AppSettings.defaultNotchRightEar
        settings.notchAllScreens = AppSettings.defaultNotchAllScreens
        settings.notchScreenID = AppSettings.defaultNotchScreenID
        settings.notchShowLyrics = AppSettings.defaultNotchShowLyrics
        settings.notchCollapsesWhenPaused = AppSettings.defaultNotchCollapsesWhenPaused
        settings.notchShowsEqualizer = AppSettings.defaultNotchShowsEqualizer
        settings.notchEqualizerEar = AppSettings.defaultNotchEqualizerEar
        settings.notchExpandedShowsNextLine = AppSettings.defaultNotchExpandedShowsNextLine
        settings.notchExpandedShowsControls = AppSettings.defaultNotchExpandedShowsControls
        settings.notchExpandedShowsLyricsOffset = AppSettings.defaultNotchExpandedShowsLyricsOffset
        settings.notchExpandedShowsArtwork = AppSettings.defaultNotchExpandedShowsArtwork
        settings.notchExpandedShowsTrackTitle = AppSettings.defaultNotchExpandedShowsTrackTitle
        settings.notchExpandedShowsArtist = AppSettings.defaultNotchExpandedShowsArtist
        settings.notchExpandedShowsAlbum = AppSettings.defaultNotchExpandedShowsAlbum
        settings.notchExpandedShowsQuickActions = AppSettings.defaultNotchExpandedShowsQuickActions
        settings.notchLyricRowShowsArtwork = AppSettings.defaultNotchLyricRowShowsArtwork
        settings.notchLyricRowArtworkPosition = AppSettings.defaultNotchLyricRowArtworkPosition
        settings.notchLyricsAlignment = AppSettings.defaultNotchLyricsAlignment
        settings.notchSecondaryLine = AppSettings.defaultNotchSecondaryLine
        // 「字体」组三项(2026-09-09)。它们是字形、不是宽度那类结构性尺寸,按钮自报的排除范围「不含宽度和总开关」
        // 里也没有它们 —— 进重置(重置覆盖闸也会盯着这三个 defaultNotch* 常量)。
        settings.notchFontFamilyName = AppSettings.defaultNotchFontFamilyName
        settings.notchFontWeight = AppSettings.defaultNotchFontWeight
        settings.notchFontSize = AppSettings.defaultNotchFontSize
        // 「行为」组里那两个自动隐藏开关(2026-09-03 补漏)。
        //
        // 它们 2026-09-02 才从撤掉的那张跨形态「自动隐藏」卡并进灵动岛「行为」组,**并进来时
        // 没同步扩这里** —— 而这颗按钮叫「恢复默认风格与**开关**」、界面自报的排除范围只有
        // "不含宽度和总开关",这两项既是开关又不在排除项里,点了重置却不动,是漏不是取舍。
        // (同一天菜单栏那颗也因为同样的原因漏了两项,见 MenuBarStyleDefaults 的头注。)
        settings.notchHideDuringScreenCapture = AppSettings.defaultNotchHideDuringScreenCapture
        settings.notchHideWhenNotPlaying = AppSettings.defaultNotchHideWhenNotPlaying
    }
}

// MARK: - 左右耳两个浮层

/// 一只耳朵显示什么模块(2026-08-31)。左右各一个浮层,由工具栏上对应那颗按钮打开。
///
/// ⚠️ 用**单选列表**,跟「风格」「屏幕」两个浮层同一个形态。一度写成一个「耳朵」浮层 + 两行
/// `.pickerStyle(.menu)` 下拉,理由是"两只耳朵各六个选项 = 12 行,列表会把浮层撑到要滚";
/// 拆成左右两个浮层之后每个只剩 6 行(约 260pt,离外壳 460 的上限还远),那条理由不成立了,
/// 于是回到跟另外两个浮层一致的形态 —— 列表点完不关,可以点着一路试过去,而下拉选中即收起。
///
/// ⚠️ 收起态那一套耳朵(左封面、右音浪)**不在这里配**,理由见 `NotchEarModule` 上方那段。
///
/// ⚠️ 宽度 240 是**算出来的**(2026-09-07;2026-08-31 定的 160 是纯列表时代的数,那次用户报
/// 「太大了,明明需要的空间很小就够了」把 380 收到了 160)。列表本身仍只要 124pt(中文)/ 136pt
/// (英文):八行两到四个字的模块名,最长英文 "Remaining" 63.0pt + 行内固定 60pt(左内边距 14 +
/// 勾列 20 + 间距 12 + 右内边距 14)。**抬到 240 的是顶上那一行「音浪」开关**(2026-09-07 从勾选行
/// 改成 `SettingsRow` + `Toggle`):`SettingsRow` 固定开销 150pt(2×14 内边距 + 20 图标列 + 3×12
/// 间距 + 12 Spacer + 54 开关)+ 标题 13pt 系统字「音浪」25.8 / "Audio Wave" 70.9 = 中文 176 /
/// **英文 221**,240 给英文留 19pt。**别顺手拉回 380 去跟别的浮层"对齐"** —— 那不是对齐,是空转。
@MainActor
struct NotchEarPopover: View {
    enum Side { case left, right }
    let side: Side

    var body: some View {
        // ⚠️ 2026-08-31 用户要求把这里的帮助气泡整段去掉(那两段话本来是解释"只影响播放中/
        // 展开态"+"音浪独立开关放在这里"这两件事;后者现在开关本身就在下面列表顶部,自解释,
        // 前者的信息量不足以单独留一个「?」气泡)。别再往这儿加 help 参数。
        SettingsPopoverShell(
            title: side == .left ? L10n.t("左耳") : L10n.t("右耳"),
            width: 240
        ) {
            NotchEarSettingsRows(side: side)
        }
    }
}

@MainActor
struct NotchEarSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    let side: NotchEarPopover.Side

    private var current: NotchEarModule {
        side == .left ? settings.notchLeftEar : settings.notchRightEar
    }

    /// 「音浪」落点第四次(也是最终)拍板处(2026-08-31,同一天):风格浮层
    /// →独立卡→(设计出工具栏第五入口方案,但同事 ls-Rocky 离屏量出中英文都装不下,
    /// 未落地)→**这里**,左右耳浮层顶部各一个独立开关行。用户原话:"放到左右耳列表里面啊,
    /// 最顶上加一个展示音浪的选项,但是和下面的通过分割线分开,可以和下面的同时选择"。
    ///
    /// **2026-09-07 从勾选行改成 `SettingsRow` + `Toggle`。** 改前它跟下面 `row(_:)` 用同一套"勾
    /// 存在/消失"的视觉、只靠一条分割线隔开 —— 用户看到的是"九行单选里有一行可以跟别的同时勾",
    /// 而它其实是个独立开关(可以跟任意模块共存,不参与那组互斥);同一份状态在「全部设置」抽屉里
    /// 又是另一种控件(开关 + 「贴哪只耳朵」分段选择器),用户报"混乱"。现在两处都是这一行,
    /// 抽屉里那张 `NotchEqualizerRow` 撤掉了。左右耳各有一份,但背后共享同一对全局状态
    /// (`notchShowsEqualizer` + `notchEqualizerEar`):打开这边会把 `notchEqualizerEar` 掰到这一侧、
    /// 同时打开总开关(另一侧那行随之变成关);关掉只关总开关,不改哪一侧。
    /// 图标 `waveform` 跟撤掉的抽屉那张同一个;标题用「音浪」而不是原来的「显示音浪」——它现在是个
    /// 开关,"显示"两个字由开关本身说,短两个字浮层也能窄 30pt(见 `NotchEarPopover` 的宽度账)。
    private var equalizerEarValue: NotchEqualizerEar { side == .left ? .left : .right }

    private var showsEqualizerHere: Bool {
        settings.notchShowsEqualizer && settings.notchEqualizerEar == equalizerEarValue
    }

    private var equalizerRow: some View {
        SettingsRow(icon: "waveform", title: L10n.t("音浪")) {
            Toggle("", isOn: Binding(
                get: { showsEqualizerHere },
                set: { on in
                    if on {
                        settings.notchEqualizerEar = equalizerEarValue
                        settings.notchShowsEqualizer = true
                    } else {
                        settings.notchShowsEqualizer = false
                    }
                }))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            equalizerRow
            CardDivider()
            // 顺序直接用 allCases(声明序),不另抄一份数组 —— 抄一份的话以后往枚举里加一个
            // 模块,这里不加就是"设置里选不到的合法值"。
            ForEach(Array(NotchEarModule.allCases.enumerated()), id: \.element) { index, module in
                if index > 0 { CardDivider() }
                row(module)
            }
        }
    }

    private func row(_ module: NotchEarModule) -> some View {
        let isSelected = current == module
        return Button {
            apply(module)
        } label: {
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                // 勾**始终占位**(不选中时透明),否则选中项一变、整列文字就横向跳一格。
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(module.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// 点**已勾选**的那一项 = 取消勾选,落回「不显示」(2026-09-06 用户要求)。这让整个浮层
    /// 上下两段的语义统一:顶上那行「音浪」是个能关的开关(`equalizerRow`),下面这组单选此前
    /// 却是"点自己 = 无操作",同一个浮层里一半能关一半关不掉。
    ///
    /// 取消**不是**清空成"没有值":`NotchEarModule` 是全域枚举、`.none` 就是它表达"这只耳朵
    /// 什么都不放"的合法成员(显示名正是「不显示」),所以取消 = 选中 `.none`,勾也跟着跳到
    /// 那一行去 —— 不存在"一个都没勾"的中间态。
    ///
    /// 相等守卫留着,但守的是**算完之后的目标值**,不再是入参:
    ///   - 点未选中项 → target = 该项(照旧);
    ///   - 点已选中项 → target = `.none`(本次新增的取消语义);
    ///   - 「不显示」已选中时点它自己 → target 仍是 `.none`、等于当前值,被守卫吃掉(无操作)——
    ///     这一条正是守卫必须算在 target 上的原因,写在入参上会漏掉它。
    ///
    /// 守卫本身不能去掉:@Published 是 willSet 语义,等值赋值照样广播 objectWillChange 打醒
    /// 所有观察 AppSettings 的界面,didSet 还会白写一次 UserDefaults。
    /// ⚠️ 写全 `NotchEarModule.none`,别缩成 `.none`:这个枚举有个成员就叫 `none`,而 `.none`
    /// 同时也是 `Optional` 的成员 —— 简写在这里能编过(左边标了非可选类型),但只要哪天有人
    /// 把它挪进一个可选上下文,含义就会静默换成"空值"。
    private func apply(_ module: NotchEarModule) {
        let target: NotchEarModule = current == module ? NotchEarModule.none : module
        if side == .left {
            guard settings.notchLeftEar != target else { return }
            settings.notchLeftEar = target
        } else {
            guard settings.notchRightEar != target else { return }
            settings.notchRightEar = target
        }
    }
}

// MARK: - 「屏幕」浮层

/// 「🖥 屏幕」浮层。跟「风格」同一个形态(单选列表),理由见 NotchStylePopover。
///
/// 「所有屏幕」2026-08-17 从一个独立的 Toggle 并进了这个选择(用户要求):它跟"选哪一块屏"
/// 本来就是同一个问题的几个互斥答案 —— 拆成"下拉 + 一个会把下拉整个禁用掉的开关"是把一个
/// 选择硬掰成两个控件,还得额外写一句"开启后上面的指定屏幕不再起作用"来解释它们的关系。
/// 这次换成单选列表,那条并法原样保留。
///
/// ⚠️ 宽度 300 —— 四个浮层里余量给得最大的一个,因为它是**唯一内容在运行时才知道**的:行文字
/// 是 `NSScreen.localizedName`。离屏 `fittingSize` 拿几台常见机器的名字量下来是中文 176pt /
/// 英文 215pt(最长那行 "LG UltraFine 5K Display"),300 留出约 85pt ≈ 再多 13 个西文字符。
/// 更长的名字会走 `.truncationMode(.tail)` 截尾 —— 但 380 一样会截,只是阈值往后挪十几个字符,
/// 所以"留宽点更安全"到不了"保证不截"这一步,不值得为它把浮层撑成内容的 1.8 倍。
@MainActor
struct NotchScreenPopover: View {
    /// 选完之后让宿主重算编辑台的刘海几何(换到没有刘海的外接屏,画面里那个刘海要消失)。
    var onScreenChange: () -> Void

    var body: some View {
        SettingsPopoverShell(
            title: L10n.t("屏幕"),
            help: L10n.t("「自动」选带刘海的那块；「所有屏幕」每块屏各显示一个；指定的屏幕拔掉后自动回到「自动」"),
            width: 300
        ) {
            NotchScreenSettingsRows(onScreenChange: onScreenChange)
        }
    }
}

@MainActor
struct NotchScreenSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    var onScreenChange: () -> Void

    /// 下拉/列表里的选项来源。用 @State 快照而不是每次 body 现读 NSScreen.screens:
    /// 插拔显示器时 SwiftUI 不会因为一个全局数组变了就重算 body,得靠下面那条
    /// didChangeScreenParameters 通知显式刷新。
    @State private var availableScreens: [NSScreen] = NSScreen.screens

    /// 「所有屏幕」在这个列表里的哨兵 tag。屏幕的真实 tag 是 ScreenIdentity 给的 UUID 串,
    /// 不可能撞上这个值;空串已经被「自动」占了。
    private static let allScreensTag = "__all_screens__"

    /// 当前选中的是哪一项。两个设置项还是各存各的(notchAllScreens 有自己的订阅方
    /// NotchMirrorManager),这里只是把它们合成一个选择呈现出来。
    private var selection: String {
        settings.notchAllScreens ? Self.allScreensTag : settings.notchScreenID
    }

    var body: some View {
        VStack(spacing: 0) {
            row(tag: "", title: L10n.t("自动"))
            CardDivider()
            row(tag: Self.allScreensTag, title: L10n.t("所有屏幕"))
            ForEach(availableScreens, id: \.self) { screen in
                if let id = ScreenIdentity.id(of: screen) {
                    CardDivider()
                    row(tag: id, title: screen.localizedName)
                }
            }
            // 存着的那块屏现在没接着时补一行。少了它,列表里没有任何一项是选中的 ——
            // 那看起来像设置丢了,而实际上偏好还在、屏幕插回来就会恢复。
            // (改版前这里是 Picker 的一个占位 tag:选中值在选项里找不到对应 tag 时整个
            //  控件会显示成空白,同一个问题的同一条修法。)
            if !settings.notchAllScreens, !settings.notchScreenID.isEmpty,
               ScreenIdentity.screen(withID: settings.notchScreenID) == nil {
                CardDivider()
                row(tag: settings.notchScreenID, title: L10n.t("已断开的屏幕"))
            }
        }
        // 设置页开着的时候插拔显示器,列表里的选项要跟着变。
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            availableScreens = NSScreen.screens
        }
    }

    private func row(tag: String, title: String) -> some View {
        let isSelected = selection == tag
        return Button {
            apply(tag)
        } label: {
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// ⚠️ `if settings.notchOverlayEnabled` 守卫不能省 —— 理由同
    /// `NotchEditorStage.commitWidths` 那条(`.shared` 是 `static let`,读一下就建整扇窗)。
    /// 改版前这一句是裸调的。
    private func apply(_ tag: String) {
        let allScreens = (tag == Self.allScreensTag)
        var changed = false
        if settings.notchAllScreens != allScreens {
            settings.notchAllScreens = allScreens
            changed = true
        }
        // 选具体屏幕时顺手把 allScreens 关掉(上面那一句已经做了),否则选了没反应。
        if !allScreens, settings.notchScreenID != tag {
            settings.notchScreenID = tag
            changed = true
        }
        guard changed else { return }
        if settings.notchOverlayEnabled {
            NotchLyricsWindowController.shared.applyScreenSetting()
        }
        onScreenChange()
    }
}
