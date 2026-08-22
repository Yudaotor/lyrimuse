import AppKit
import SwiftUI
import Combine
import LyrimuseCore

// 文件级常量(跟 LyricsOverlayWindowController.swift 同一个理由不挂在 @MainActor 类
// 上)。2026-08-03 补上——"显示灵动岛歌词"这个菜单开关(isVisible)之前只存在内存里,
// setVisible() 只改了 @Published 属性、从没写过 UserDefaults。用户关掉灵动岛后退出
// 重开 App,isVisible 又从声明处的硬编码默认值 true 重新起步,违背用户上一次的选择、
// 无条件重新冒出来——这个窗口 level 是 .screenSaver(见 NotchLyricsWindow.swift,
// 特意调到比系统菜单栏还高才能贴住刘海),意外重新出现时会整个盖在菜单栏那一整条上,
// 挡住(包括这个 App 自己的)菜单栏图标,肉眼看起来像"菜单栏图标跑到灵动岛的位置去
// 了"——实际是图标一直没动,只是被这个不该出现的高层级窗口盖住了。跟经典悬浮窗
// (overlayVisibleKey)是各自独立的 key,两种样式的"显示/隐藏"偏好不共用。
// isVisible 的持久化在 2026-08-05 并进了 AppSettings.notchOverlayEnabled(原来这里有一个
// 私有的 np:notchOverlayVisible,跟设置页那个开关是同一件事的两个真值),详见 setVisible(_:)
// 和 AppSettings.init() 里的迁移注释。

// 灵动岛/刘海样式悬浮歌词的窗口控制器——跟 LyricsOverlayWindowController 平行、完全
// 独立的第二套实现(两种样式互斥、各自独立的窗口控制器,不去改造经典那一套让它同时
// 兼容两种形态,那样的改造复杂度和风险都更高)。跟经典悬浮窗的行为差异:
// 1) 位置是算出来的、贴死在屏幕顶部居中,不支持用户拖拽(见 NotchLyricsWindow 里
//    isMovableByWindowBackground = false),所以没有"锁定位置"这个概念,也不需要
//    像经典悬浮窗那样持久化位置。
// 2) 稳态(没在播放、没 hover)缩到刘海本身(或无刘海屏幕的兜底胶囊)大小;播放中
//    常显"歌名+控制按钮+当前歌词"整套,不需要 hover 才能看到——歌词类信息本来就该
//    随时可见。hover 时在下面多展开一块补充信息(下一句歌词预览+迷你进度条),展开
//    态里播放控制按钮直接常驻,不需要再单独 hover 一次才出现。
//
// 极其重要的一条不变量,贯穿 AppDelegate/SettingsView/MenuBarMenu 三处外部路由代码:
// 这个类是 `static let shared`,真正引用到 `.shared` 才会执行 init() 建窗口——而
// init() 里订阅 PlaybackCoordinator.$isPlayingNow 的这个 Combine sink,在订阅的
// 一瞬间就会用当下的 isVisible(默认 true)触发一次 updateActualVisibility→
// orderFront。也就是说,只要有任何代码在"经典"样式生效期间不小心引用了
// `NotchLyricsWindowController.shared`(哪怕只是拿来读一下属性),这个没人要的
// 灵动岛胶囊就会凭空出现在屏幕顶部。三处外部路由代码因此都必须做到:只有在
// settings.overlayStyle == "notch" 的分支里才会出现 `.shared` 这个词——尤其
// MenuBarMenu.swift,不能像"同时持有两个控制器的 @ObservedObject"这种最直白的写法
// 那样两个都摸一遍。
//
// 歌词文字这一行让到物理刘海下方那一条,刘海本身所在的高度只留纯黑背景——物理刘海是
// 屏幕硬件层面真实不发光的区域,不是"渲染层级"问题,任何 App 都不可能把内容"显示"在
// 那个区域本身(参考 boring.notch/DynamicNotchKit 等真实刘海companion 应用的做法)。
//
// isCollapsed(缩到刘海大小,内容整套不渲染)跟已有的 hideWhenNotPlaying(整个窗口
// 隐藏)是两个独立机制,不冲突:后者关闭时窗口本身还在(用户能看到"这里有个东西"),
// 只是不常显内容、缩到最小,hover 到这一小块区域上依然能重新展开出完整内容(包括
// 播放按钮,可以用来重新播放)。见 isCollapsed/collapsedFallbackWidth。
@MainActor
// 已经有 NotchChromeSource 要的全部四个属性和 setExpanded,只是把这层契约显式写出来
// —— 这样「外观」页的预览可以拿一个轻量替身装同一份 NotchLyricsView。
final class NotchLyricsWindowController: NSWindowController, ObservableObject, NotchChromeSource {
    static let shared = NotchLyricsWindowController(pinnedScreenID: nil)

    // 真值在 AppSettings.notchOverlayEnabled,这里只是它的镜像(菜单栏要观察这个
    // @Published)。只能经 setVisible(_:) 改,那是打开/关闭的唯一入口。
    @Published private(set) var isVisible: Bool = AppSettings.shared.notchOverlayEnabled
    @Published private(set) var hideWhenNotPlaying: Bool = false
    // 常显内容行(歌词)相对窗口顶部的偏移——正好等于刘海(或无刘海屏幕的兜底高度)
    // 本身的高度,这样歌词永远从刘海往下才开始画,不会被刘海真实挡住一部分。
    // NotchLyricsView 读这个属性给歌词行加 .padding(.top, contentTopInset)。
    @Published private(set) var contentTopInset: CGFloat = 32
    // 刘海本身的真实宽度(无真刘海时为 0)——播放控制按钮要挪到刘海两侧("耳朵")那
    // 两条空间里,不能摆在刘海本身的 x 范围内:物理刘海是屏幕硬件层面真实不发光的
    // 区域,横向也会跟纵向一样把落在这个范围内的内容整个挡掉。NotchLyricsView 读这个
    // 属性把顶部这一行让出中间 notchWidth 宽度的空当,按钮只放在左右两侧。
    @Published private(set) var notchWidth: CGFloat = 0
    // 鼠标是否悬停在这个悬浮窗上——由 NotchLyricsView 的 .onHover 驱动,决定窗口要不要
    // 多撑出 expandedExtraHeight 那一块、以及 NotchLyricsView 要不要渲染下一句预览+
    // 迷你进度条这部分补充内容。稳态(false)本身已经是"歌名+控制+当前歌词"完整可用的
    // 一套,这个状态只影响"要不要在下面多展开一块",不影响稳态内容本身是否显示。
    @Published private(set) var isExpanded: Bool = false
    /// 当前有没有在播放。由 isPlayingObserver 写入,值取 sink 的**参数**——不能回头去读
    /// PlaybackCoordinator 的存储属性,@Published 在 willSet 时机发布,那一刻读到的还是
    /// 旧值(本项目已实测踩过两次,见下面 isPlayingObserver 处的注释)。
    ///
    /// 单独存一份而不是每次现读,是为了让下面的 isCollapsed 能写成计算属性。
    @Published private(set) var isPlayingNow: Bool = false

    // 当前没有在播放、也没有 hover 展开时为 true——这时窗口收缩到真实刘海本身的大小
    // (无真刘海屏幕退到 collapsedFallbackWidth 那个兜底胶囊宽度),歌名/控制按钮/歌词
    // 这一整套常显内容完全不渲染,单纯是一小块跟屏幕硬件本身融为一体的黑色区域。
    // NotchLyricsView 读这个属性决定要不要渲染 topRow/lyricRow。
    //
    // ⚠️ 2026-08-17 从存储属性改成**计算属性**,修的是"暂停时鼠标移上去没反应"这个 bug:
    // 它原来只在 recomputeGeometry() 里赋值,而 hover 改 isExpanded 的那条路径
    // (setExpandedFromWindow)刻意不调 recomputeGeometry("窗口尺寸跟展开与否无关了")。
    // 于是暂停状态下移上去,isExpanded 确实变成了 true、isCollapsed 却还留在 true —— 卡片
    // 高度走 NotchWindowRoot.cardHeight 的 collapsed 分支原地不动,内容也照样不渲染,
    // 看着就是"灵动岛对 hover 毫无反应",而文件顶部承诺的"hover 到这一小块上依然能重新
    // 展开出完整内容(包括播放按钮,可以用来重新播放)"整个落空。
    //
    // 原来那版注释说它跟窗口尺寸"保持单一数据源、不在两处各自算一遍" —— 单一数据源确实
    // 做到了,但**同步**没有:公式只有一份,却挂在一条 hover 时根本不会走的路径上。写成
    // 计算属性之后,两个输入哪个变它都跟着变,不存在"忘了重算"这回事。
    // 2026-08-19 加入广告插播维度:Spotify 放广告时同样收起(用户拍板"和暂停一样
    // 缩回去")——广告没有歌词可展示,歌名位只显示「广告中」(见 NotchLyricsView.topRow),
    // hover 仍可展开(跟暂停态一致,里面有控制按钮可以切歌跳过广告)。
    var isCollapsed: Bool { (!isPlayingNow || isAdBreakNow) && !isExpanded }

    /// Spotify 广告插播中。写入规则与 isPlayingNow 相同:只取 sink 参数值。
    @Published private(set) var isAdBreakNow: Bool = false

    /// 展开区要不要给"下一句歌词预览"留高度(= 这首歌有没有歌词)。写入规则同
    /// isPlayingNow:只取 sink 参数值,绝不回头读 PlaybackCoordinator 的存储属性。
    @Published private(set) var expandedShowsLyricPreview: Bool = false
    /// 展开区要不要给迷你进度条留高度(= 这首歌有没有时长)。同上。
    @Published private(set) var expandedShowsScrubber: Bool = false

    /// 此刻有没有一首曲目 —— 决定歌词行整行占不占那 44pt(见协议 NotchChromeSource.hasTrack)。
    /// 由 CombineLatest3 一次给全三个值,不存在"回头读存储属性拿到旧值"那个坑。
    @Published private(set) var hasTrack: Bool = false

    /// 稳态/展开态卡片的宽度(= contentWidth(baseWidth:notchWidth:) 的结果)。
    /// 窗口本身常驻这个宽度,卡片在里面按形态变宽变窄,见 NotchWindowRoot。
    @Published private(set) var steadyCardWidth: CGFloat = 360
    /// 收起态卡片的宽度:物理刘海本身的宽度,无真刘海的屏幕退到兜底胶囊宽度。
    @Published private(set) var collapsedCardWidth: CGFloat = collapsedFallbackWidth

    // 没有真刘海的屏幕(比如 MacBook Air 全系不带刘海,只有 14"/16" MacBook Pro
    // 2021 起才有)退到的固定兜底高度:不是"关掉整个功能",是换一套不依赖真刘海几何
    // 形状的兜底样式,宽度沿用下面 contentWidth 算出来的常显宽度。
    // 无刘海屏幕上"假刘海"的兜底高度下限。真正用的值是那块屏**当前的菜单栏高度**
    // (见 menuBarHeight(of:)) —— 写死一个数字在外接屏上必然对不齐:菜单栏高度随屏幕
    // 缩放/分辨率变化(实测这台内建屏 33pt,外接屏常见 24~37pt 不等),黑条比菜单栏矮
    // 会露出一条桌面、比它高会压住窗口内容。这个常量只在菜单栏被自动隐藏(顶部差为 0)
    // 时兜底。
    private static let fallbackNotchHeight: CGFloat = 24

    /// 这块屏当前的菜单栏高度。
    ///
    /// ⚠️ 只能看**顶边差**,不能用 frame.height - visibleFrame.height —— 后者把 Dock
    /// 也算进去了(实测这台机器算出 109pt,而菜单栏其实只有 33pt)。
    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        max(fallbackNotchHeight, screen.frame.maxY - screen.visibleFrame.maxY)
    }
    // 收起态(没在播放、没 hover)在无真刘海屏幕上退到的兜底宽度——真刘海屏幕收起态
    // 直接用 notchWidth 本身(跟硬件刘海严丝合缝),这个值只在没有真刘海可以贴的场景
    // 才用得到,给一个能装得下一小块胶囊、不会小到近乎看不见的经验值。
    private static let collapsedFallbackWidth: CGFloat = 120
    // 常显内容行的固定高度(一行歌词 + 3 个播放控制按钮那一行的高度经验取值)——窗口
    // 总高度 = 刘海本身高度(或兜底高度)+ 这一行高度,让内容行完整落在刘海下方。
    // 数值本身在 NotchMetrics.compactRowHeight —— 视图那边按同一个数字排版,
    // 两处各写一份 44 迟早会漂。
    private static var contentHeight: CGFloat { NotchMetrics.compactRowHeight }
    // 宽度是固定值,不随当前歌词文字宽度动态变化——预期是多大就多大,不会随着歌词
    // 发生变化。数值本身(默认 360)以及用户可调的设置项都定义在 AppSettings.
    // notchContentWidth(这里不重复放一份、避免两处数字不同步)。超长歌词交给
    // NotchLyricsView 的 MarqueeText 来回滚动展示,不靠加宽窗口解决。
    // 顶行左右两只"耳朵"各自的最低可用宽度(歌名文字 + 3 个播放控制按钮都要放得下,
    // 不能比这更窄)——算下限时要把这两只耳朵 + 刘海本身宽度 + 左右 padding 都算进去。
    // 真刘海本身可能相当宽(实测有的机器约 179pt)、或者用户把设置里的宽度调得很小,
    // 这层下限比用户设的宽度还宽的话取这层,保证按钮不会被裁切。
    private static let minEarWidth: CGFloat = 70
    // hover 展开时在 contentSize 之外额外撑出的高度,放下一句歌词预览 + 迷你进度条这
    // 两样补充信息(更多控制按钮都不如这两样贴合"歌词类产品"的定位)。专辑封面不在这一块
    // ——它常显在歌词行的尾端(见 NotchLyricsView.artworkThumbnail),不需要 hover 才出现,
    // 也不占额外高度。
    // 同上,单一来源在 NotchMetrics。
    // 窗口恒按**最大**形态开(卡片在里面自己变大变小,见 NotchWindowRoot)——所以这里
    // 用 Max,不用那个按内容算的函数。用后者会让"没歌词的歌"把窗口也缩掉,而窗口一缩,
    // 后面换到有歌词的歌时卡片就没地方长了(会被窗口边界硬裁)。
    private static var expandedExtraHeight: CGFloat { NotchMetrics.expandedExtraHeightMax }

    private var isPlayingObserver: AnyCancellable?
    private var adBreakObserver: AnyCancellable?
    private var lyricPresenceObserver: AnyCancellable?
    private var durationObserver: AnyCancellable?
    private var trackPresenceObserver: AnyCancellable?
    private var screenParamsObserver: NSObjectProtocol?
    // 一个真实的坑:窗口 hover 展开/收起时靠 autoresizingMask 让 NSHostingView
    // 跟着 window.setFrame 自动同步尺寸——AppKit 层面这个同步是真的发生了(window.frame/
    // contentView.frame 都能读到新的高度),但 NSHostingView 内部的 SwiftUI 布局树没有
    // 跟着重新走一遍布局,导致新撑出来的那一段区域(展开态多出来的 40pt)在屏幕上什么都
    // 不画,肉眼看起来完全没有展开。直接持有这个引用、在 recomputeGeometry 里手动把它的
    // frame 也显式设一遍(而不是只信任 autoresizingMask 那条隐式路径),能让 SwiftUI 真正
    // 重新布局这一块。
    private var hostingView: NSHostingView<NotchWindowRoot>?

    /// 只有"每块屏各一个"模式下的副本实例才会设(见 NotchMirrorManager),且只在 init
    /// 里设一次。主实例(`.shared`)恒为 nil,跟着 targetScreen() 走。
    ///
    /// ⚠️ 这个字段是主/副实例的**唯一**区别 —— 副本共用同一个类、同一份视图、同一套
    /// hover/播放订阅,只是钉在别的屏上。多加一个"这是副本"的布尔就会诱使后面的人写
    /// `if isMirror { ... }` 的分支,那正是两套行为慢慢分叉的起点。
    private var pinnedScreenID: String?

    /// pinnedScreenID **必须**在这里传进来,不能等构造完再赋值:init() 末尾就会
    /// recomputeGeometry() 一次、并订阅播放状态(订阅那一瞬间就会触发一次
    /// updateActualVisibility → orderFront)。晚设一步的话,新建的副本会先按
    /// targetScreen() 在**主屏**上摆好并显示出来,然后才被挪到它该去的那块屏 ——
    /// 表现为主屏上闪一下重叠的第二个灵动岛。
    /// ⚠️ 这个参数**不能**给默认值。给了默认值之后 `NotchLyricsWindowController()` 这个
    /// 调用就有两个候选:这个 convenience init,和从 NSWindowController 继承来的
    /// `init()`。Swift 选后者 —— 于是 `.shared` 建出来的是一个**没有窗口、没跑过下面
    /// 任何一行**的空壳控制器,`updateActualVisibility()` 里的 `window?.orderFrontRegardless()`
    /// 对 nil 什么都不做,灵动岛就此彻底不出现,而且编译期、运行期都没有任何报错或日志。
    /// 2026-08-16 加"每块屏各一个"时正是这么写的,灵动岛静默消失了三次构建才查到这里。
    /// 所以主实例也显式传 nil(见 `shared` 的声明),不留 `()` 这种写法。
    convenience init(pinnedScreenID: String?) {
        // 初始 contentRect 只是占位——真正的尺寸/位置由下面 recomputeGeometry() 按
        // 当前屏幕几何重新算一遍并 setFrame,这里传什么都会被立刻覆盖掉。
        let placeholder = NSSize(width: AppSettings.shared.notchContentWidth, height: Self.fallbackNotchHeight + Self.contentHeight)
        let panel = NotchLyricsWindow(contentRect: NSRect(origin: .zero, size: placeholder))
        self.init(window: panel)
        self.pinnedScreenID = pinnedScreenID

        let hosting = NSHostingView(rootView: NotchWindowRoot(controller: self))
        hosting.frame = NSRect(origin: .zero, size: placeholder)
        hosting.autoresizingMask = [.width, .height]
        // 尺寸完全由 recomputeGeometry 手动管理(窗口和 hostingView 的 frame 都是),
        // 默认 .standardBounds 的 intrinsic 尺寸汇报没有任何消费者 —— 跟悬浮窗
        // (LyricsOverlayWindowController)同一天落地的同款卫生项。
        hosting.sizingOptions = []
        panel.contentView = hosting
        hostingView = hosting

        recomputeGeometry(animate: false)

        // 外接显示器插拔/切换分辨率时,"这台屏幕有没有真刘海"这个前提可能整个变了
        // (外接显示器基本不会有刘海)——重新算一遍,思路照抄经典悬浮窗
        // LyricsOverlayWindowController.restoredOrigin() 里"配置可能变了、需要重新
        // 夹回可见区域"那段既有处理。系统触发的几何变化不需要过渡动画,直接跳变。
        //
        // 只有主实例注册 —— 镜像副本的屏幕参数处理统一由 NotchMirrorManager 的同款
        // 通知驱动(refresh → syncStateFromSettings → recomputeGeometry),副本再注册
        // 一份就是同一次插拔跑两遍全量几何(2026-08-19 性能审计);副本被钉的屏拔掉时,
        // 它自己的 observer 也只会按 resolvedScreen()==nil 空转,真正的清理本来就在
        // manager 那侧。
        if pinnedScreenID == nil {
            screenParamsObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.recomputeGeometry(animate: false) }
            }
        }

        // 跟 LyricsOverlayWindowController 同一个坑同一个修法:sink 闭包里必须用参数
        // 里收到的 isPlaying,不能在闭包内另外去读 PlaybackCoordinator.shared.
        // isPlayingNow 这个存储属性——@Published 的 willSet 在真正写入新值*之前*就
        // 已经发布,这个时间点读存储属性拿到的是上一次的旧值,细节见
        // LyricsOverlayWindowController.swift 同一处注释,不重复展开。
        isPlayingObserver = PlaybackCoordinator.shared.$isPlayingSmoothed.sink { [weak self] isPlaying in
            // 收缩与否(isCollapsed)现在是从这个属性算出来的计算属性,写进来就等于生效,
            // 不用再触发一次几何重算。同一个坑同一个修法:存的必须是 sink 参数里的
            // isPlaying,不能回头读 PlaybackCoordinator 的存储属性(那一刻还是旧值)。
            self?.isPlayingNow = isPlaying
            self?.updateActualVisibility(isPlayingNow: isPlaying)
        }

        // 广告插播 → 收起(isCollapsed 的第三个输入)。同一个 willSet 坑同一个修法:
        // 存 sink 参数值,绝不回头读 PlaybackCoordinator 的存储属性。写入 @Published
        // 即生效,几何不用重算(窗口常驻最大尺寸,收起只是内容层的事,同 isPlayingNow)。
        adBreakObserver = PlaybackCoordinator.shared.$isCurrentTrackAdBreak.sink { [weak self] isAd in
            self?.isAdBreakNow = isAd
        }

        // 有没有曲目(2026-08-21,修"没曲目时歌词行 44pt 全空还占着")。三个输入必须
        // **同时**拿到才能算,所以用 CombineLatest3 而不是三个独立 sink —— 独立 sink 里
        // 只能拿到自己那一个参数,另外两个得回头读存储属性,而那正是这个文件反复踩过的
        // @Published willSet 旧值坑。
        trackPresenceObserver = Publishers.CombineLatest3(
            PlaybackCoordinator.shared.$title,
            PlaybackCoordinator.shared.$artist,
            PlaybackCoordinator.shared.$isCurrentTrackAdBreak
        ).sink { [weak self] title, artist, isAd in
            self?.hasTrack = !title.isEmpty || !artist.isEmpty || isAd
        }

        // 展开区的两个"要不要留高度"标志(2026-08-21,修"没歌词时展开卡一大片空白")。
        // 刻意订阅**曲目级**信号而不是"此刻有没有下一句"——理由见
        // NotchMetrics.expandedExtraHeight 的注释(后者会让最后一句唱完时卡片抽动)。
        // 同一个 willSet 坑同一个修法:存 sink 参数值。写入 @Published 即生效,窗口尺寸
        // 不用重算(窗口恒为最大形态,卡片高度是内容层的事)。
        lyricPresenceObserver = PlaybackCoordinator.shared.$hasLyricsContent.sink { [weak self] has in
            self?.expandedShowsLyricPreview = has
        }
        durationObserver = PlaybackCoordinator.shared.$currentDurationMs.sink { [weak self] ms in
            self?.expandedShowsScrubber = (ms ?? 0) > 0
        }

        // 宽度固定后,recomputeGeometry 的结果不再跟 currentLine 有任何关系,不需要
        // 额外订阅 currentLine 来触发重算。
    }

    deinit {
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
    }

    // 打开/关闭"灵动岛歌词"的**唯一**入口——设置页那个 Toggle、菜单栏"显示灵动岛歌词"两处
    // 都必须走这里。理由跟 LyricsOverlayWindowController.setVisible(_:) 完全对称,不重复展开:
    // 统一写回 AppSettings.notchOverlayEnabled(由它的 didSet 持久化),打开时顺手把两个已
    // 配置好的隐藏偏好也应用上。
    func setVisible(_ visible: Bool) {
        isVisible = visible
        AppSettings.shared.notchOverlayEnabled = visible
        if visible {
            setHiddenFromCapture(AppSettings.shared.hideDuringScreenCapture)
            setHideWhenNotPlaying(AppSettings.shared.hideWhenNotPlaying)
        }
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    // 跟经典悬浮窗共用同一个"暂停/无播放时隐藏"设置项(AppSettings.hideWhenNotPlaying),
    // 不新增独立开关——两种样式各自独立调用这个方法应用同一个设置值。
    /// 全屏状态变化时重新过一遍可见性闸。由 AppDelegate 订阅 FullscreenAppMonitor 后调。
    func refreshVisibilityForFullscreenChange() {
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    func setHideWhenNotPlaying(_ hide: Bool) {
        hideWhenNotPlaying = hide
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
    }

    // 跟经典悬浮窗共用同一个"截屏/录屏时隐藏"设置项(AppSettings.hideDuringScreenCapture),
    // 不新增独立开关——两种样式各自独立调用这个方法应用同一个设置值。
    func setHiddenFromCapture(_ hidden: Bool) {
        window?.sharingType = hidden ? .none : .readWrite
    }

    // NotchLyricsView 的 .onHover 调这个,animate 传 false(瞬间展开/收起,不做过渡
    // 动画)——2026-08-02 实测排查坐实:这里原来的注释错误地写着"跟经典悬浮窗
    // updateHeight() 同一个既有模式",但 updateHeight() 其实一直是 animate: true,
    // 两者从未真正一致过,是注释本身写错了,不是代码需要改成 true 去凑注释。这里刻意
    // 用瞬时响应是因为 hover 展开/收起是对鼠标动作的直接反馈,需要跟手感觉跟得上,不能
    // 有过渡延迟;而下面 isPlayingObserver(播放状态切换)/applyContentWidthSetting
    // (拖动宽度滑块)这两处用 animate: true,是因为它们是后台状态变化触发的、非用户
    // 直接操作的尺寸调整,平滑过渡观感更好,不需要即时响应。两处需求不同,animate 参数
    // 本来就该不一样,不是遗漏。
    // hover 意图判定的两个延迟。
    //
    // 光标从刘海底下横穿而过(去点菜单栏、去够右上角控制中心)会连着触发 enter+exit,
    // 没有延迟的话灵动岛就闪一下,很扎眼;反过来光标停在展开态卡片的下边缘时,内容
    // 高度变化会让 hover 状态在边界上来回抖,收起延迟能把这种抖动吸收掉。
    //
    // 值取自 boringNotch 的实测手感(它默认进入 0.3s / 离开 0.1s),这里进入先压到 0.2s:
    // 我们展开出来的是"下一句 + 迷你进度条",是想看就得马上看到的信息,不像它那样
    // 展开出一整块控制面板。2026-08-17 再压到 0.12s(用户反馈"唤起还是稍微长了点")——
    // 展开本身还有一条 0.38s 的弹簧,感知延迟是这两段之和,砍在意图判定这一段最划算。
    //
    // 不再往下压了:这个延迟唯一的作用就是滤掉"鼠标只是路过刘海下方"的误触发,
    // 归零的话光标横穿屏幕顶部就会一路把灵动岛捅开。
    private static let hoverEnterDelay: TimeInterval = 0.12
    private static let hoverExitDelay: TimeInterval = 0.1
    private var pendingHoverWork: DispatchWorkItem?

    /// 协议里那条 hover 入口,窗口这边**故意空实现** —— 跟 NotchPreviewChrome 同一个理由,
    /// 而且是同一个现象:NotchLyricsView 里那个 .onHover 覆盖的范围比卡片本身大一圈。
    ///
    /// 改成"窗口常驻最大尺寸"之后这件事从"无害"变成"有害":以前窗口就是卡片,大一圈也大
    /// 不到哪去;现在卡片下面有几十 pt 的透明区,鼠标划过那片空白(实际是在用户自己的窗口
    /// 上面)灵动岛就会展开。2026-08-16 实测:光标停在卡片下方 24pt 的透明处,卡片照样展开。
    ///
    /// 所以命中判定改由 NotchWindowRoot 拿精确坐标跟卡片矩形直接比,走 setExpandedFromWindow。
    func setExpanded(_ expanded: Bool) {}

    func setExpandedFromWindow(_ expanded: Bool) {
        // 每次新的 hover 事件都先撤掉上一次还没兑现的意图 —— "进了又出"必须净效果为零,
        // 而不是两个延迟各自到期、先展开再收起地闪一下。
        pendingHoverWork?.cancel()
        pendingHoverWork = nil
        guard expanded != isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, expanded != self.isExpanded else { return }
            self.pendingHoverWork = nil
            self.isExpanded = expanded
            // 不再 recomputeGeometry:窗口尺寸跟展开与否无关了,展开这件事整个发生在
            // SwiftUI 那一侧(NotchWindowRoot 的弹簧动画)。
        }
        pendingHoverWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (expanded ? Self.hoverEnterDelay : Self.hoverExitDelay),
            execute: work)
    }

    // 设置里"灵动岛宽度"滑块调用——跟经典悬浮窗的 setWidth(_:) 不是同一套实现:那个
    // 需要"保持窗口中心点不变"的增量调整,因为经典悬浮窗的位置是用户拖拽/持久化的,直接
    // 重设宽度容易把窗口推出屏幕外。灵动岛完全不是这么回事:它的位置从来不是持久化的,
    // 每次都是 recomputeGeometry 里用当前屏幕的 geo.centerX 重新居中算出来的,所以这里
    // 直接把完整的几何计算(位置+尺寸)重新走一遍就行,不用另外单独维护一份"保持居中"
    // 的增量逻辑。
    func applyContentWidthSetting() {
        // animate: false —— 平滑过渡现在由卡片那条弹簧负责(窗口只是个更大的透明容器,
        // 它自己怎么变没人看得见)。让 NSWindow 也动画反而会跟卡片的弹簧打架。
        recomputeGeometry(animate: false)
    }

    /// 上一次实际执行的显隐动作,updateActualVisibility 的判等守卫用。nil = 还没执行过。
    /// orderFrontRegardless 不是免费的(一次 WindowServer 重排序事务),而这个函数挂在
    /// 播放状态翻转/设置同步/镜像 syncAll 多条路径上,值没变就别重复叫(2026-08-19)。
    private var lastAppliedShouldShow: Bool?

    private func updateActualVisibility(isPlayingNow: Bool) {
        // ⚠️ 开着「暂停/无播放时隐藏」时,暂停就整个 orderOut —— 那样**看不到收起动画**
        // (窗口都没了,还收什么)。灵动岛的收起态本身只占菜单栏那一条高度、不额外占屏,
        // 所以想看到"歌词行卷回顶行"的效果,得把这个设置关掉。这是设置本身的语义,不是 bug:
        // 有人就是要暂停后连那条顶行都别留。
        // 「别的 App 全屏时隐藏」是第三个与项(2026-08-22)。跟另外两个自动隐藏一样,
        // 不碰 isVisible 本身 —— 那是纯粹的"用户手动想不想看见"。开关关着时
        // FullscreenAppMonitor 不监听、isFullscreenAppPresent 恒为 false,这一项等于常真。
        let shouldShow = isVisible && (!hideWhenNotPlaying || isPlayingNow)
            && !FullscreenAppMonitor.shared.isFullscreenAppPresent
        guard shouldShow != lastAppliedShouldShow else { return }
        lastAppliedShouldShow = shouldShow
        // orderFrontRegardless(),不是 orderFront(nil)——这个 App 是 .accessory 策略、
        // 从不激活成前台 App,参照的真实开源实现(NotchDrop/DynamicNotchKit)贴刘海用的
        // 都是这个,不看"当前是否是活跃 App"这个前提就把窗口调到最前。
        if shouldShow { window?.orderFrontRegardless() } else { window?.orderOut(nil) }
    }

    // 不加 private:「外观」页的灵动岛预览要用同一套刘海几何。
    //
    // ⚠️ 预览**只能**用这个 static 函数,绝不能去读 `.shared` 的属性 —— 见文件顶部那条
    // 不变量:引用 .shared 会执行 init() 建窗口并立刻 orderFront,灵动岛关着的用户会
    // 凭空多出一个胶囊。这个函数不碰任何实例状态,拿它算几何是安全的。
    struct NotchGeometry {
        // 刘海本身(或无刘海屏幕的兜底值)的高度——这一整条永远只留纯黑背景,不放
        // 任何文字/图标,常显内容行从这条高度往下才开始画,见 NotchLyricsView。
        let notchHeight: CGFloat
        let centerX: CGFloat
        // 刘海本身的真实宽度——无真刘海时为 0(没有需要横向避开的硬件区域,顶部这一行
        // 可以整条给按钮用)。
        let notchWidth: CGFloat
    }

    // 用 safeAreaInsets.top 判断这台屏幕有没有真刘海(>0 即有),用
    // auxiliaryTopLeftArea/auxiliaryTopRightArea(macOS 12 起的 API,这个项目部署
    // 目标是 14,肯定能用)量出刘海左右边界算出的真正中心点——不是简单假设刘海永远
    // 精确居中于整块屏幕,虽然实践中几乎总是如此。没有真刘海的屏幕退到固定兜底高度、
    // 水平居中于整块屏幕。
    static func geometry(for screen: NSScreen) -> NotchGeometry {
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            let centerX = (leftArea.maxX + rightArea.minX) / 2
            let notchWidth = rightArea.minX - leftArea.maxX
            // ⚠️ 高度取 safeAreaInsets.top 和**菜单栏条高**里的大者。
            //
            // 2026-08-19 实测这台内建屏:safeAreaInsets.top = 32,而菜单栏条
            // (frame.maxY - visibleFrame.maxY)= **33** —— 系统这两个数差 1pt。收起态那条
            // 黑带的高度就是这个值,取 32 的话它的底边比刘海/菜单栏的底边高 1pt(retina 上
            // 是 2 个物理像素的一道发丝),看着就是"比刘海短了一截"。取大者之后底边跟菜单栏
            // 齐平,黑带和刘海连成一片。
            //
            // 只会变大不会变小,所以不会反过来压住窗口内容;contentTopInset 跟着 +1,
            // 歌词行相应往下 1pt,更稳妥(绝不会被刘海压到)。
            return NotchGeometry(notchHeight: max(notchHeight, menuBarHeight(of: screen)),
                                 centerX: centerX, notchWidth: notchWidth)
        }
        // 无真刘海:黑条高度跟这块屏的菜单栏对齐,视觉上跟系统融为一体。
        return NotchGeometry(
            notchHeight: menuBarHeight(of: screen), centerX: screen.frame.midX, notchWidth: 0)
    }

    // 用户在设置里调的固定宽度(baseWidth,即 AppSettings.notchContentWidth)+ 耳朵下限
    // 两者取较大值——大多数情况下就是 baseWidth 本身,只有真刘海本身特别宽(这台机器
    // 实测约 179pt)、或者用户把 baseWidth 调得很小,把两只耳朵挤到摆不下按钮时才会
    // 突破 baseWidth(这层下限保护的是"按钮不被裁",不是"给歌词文字腾地方",不跟当前
    // 是哪句歌词、歌词有多长有任何关系)。
    // 不加 private:设置页的灵动岛预览要用同一个公式算宽度,否则设成小宽度时预览
    // 显示的是设定值、真窗口却被耳朵下限顶宽,两边对不上。
    static func contentWidth(baseWidth: CGFloat, notchWidth: CGFloat) -> CGFloat {
        let earBasedFloor = notchWidth + minEarWidth * 2 + 20
        return max(baseWidth, earBasedFloor)
    }

    // 灵动岛贴哪块屏。
    //
    // 用户在设置里指定了某块屏(存的是显示器 UUID,见 ScreenIdentity)就用那块;没指定
    // (或者指定的那块现在没接着——拔了、合盖了)就自动挑**真的有刘海**的那块,再没有
    // 就退回 NSScreen.main。
    //
    // 2026-08-07 之前这里直接用 NSScreen.main,注释写的是"当前有键盘焦点/菜单栏所在的
    // 那块屏幕……跟'灵动岛只应该出现在当前主屏'这个直觉一致"。实测这个直觉不成立:
    // NSScreen.main 跟着**键盘焦点**跳,而 recomputeGeometry 只在少数几个时机重算
    // (init/屏幕配置变化/播放状态切换/hover/拖宽度),于是最后一次重算时焦点碰巧在哪块
    // 屏,窗口就一直停在哪块屏。用户的外接屏排在内置屏上方,灵动岛就停在外接屏顶部
    // (CG 坐标 y=-1440)——那块屏还没有刘海,而用户正看着内置屏,怎么找都找不到它,
    // 报的是"开了灵动岛歌词但是不显示"。
    // 不加 private:设置页预览要跟真窗口取同一块屏(纯静态、不碰实例状态,安全)。
    static func targetScreen() -> NSScreen? {
        if let pinned = ScreenIdentity.screen(withID: AppSettings.shared.notchScreenID) {
            return pinned
        }
        return ScreenIdentity.notched ?? NSScreen.main
    }

    // 设置页改完"显示在哪块屏幕"后调这个立刻生效(跟 applyContentWidthSetting 同一个模式)。
    func applyScreenSetting() {
        recomputeGeometry(animate: false)
    }

    /// 这个实例贴哪块屏:副本贴它被钉的那块,主实例走全局的 targetScreen()。
    ///
    /// 副本被钉的屏拔掉时返回 nil,recomputeGeometry 直接 return —— 窗口维持原样不动。
    /// 这是刻意的:真正的清理由 NotchMirrorManager 在屏幕配置变化时做(它会把这个实例
    /// 整个销毁),这里再自作主张挪一次位置只会让窗口在被销毁前先闪到别的屏上去。
    private func resolvedScreen() -> NSScreen? {
        if let pinnedScreenID {
            return ScreenIdentity.screen(withID: pinnedScreenID)
        }
        return Self.targetScreen()
    }

    /// 把当前偏好重新应用一遍。副本没有自己的设置入口(设置页那些控件只调 `.shared`),
    /// 所以偏好变化时由 NotchMirrorManager 挨个调这个方法把它们同步过来。
    ///
    /// ⚠️ 三个参数是给**设置变化的 sink** 用的:@Published 在 willSet 时机发布,sink 里
    /// 回读 AppSettings 存储属性拿到的是**旧值**(本文件 isPlayingObserver 处同款坑;
    /// 2026-08-19 核实这里原来就踩着 —— 拖宽度滑杆时镜像恒滞后一档、隐藏开关同步到翻转前
    /// 的状态)。触发源不在变化中的字段传 nil 回读即可(屏幕插拔/开关翻转这些时机,其余
    /// 设置的存储值是稳定的)。各写入点判等 —— 原来 6 个 @Published 不判等地全量重写,
    /// 值没变也广播 objectWillChange。
    func syncStateFromSettings(
        notchEnabled: Bool? = nil,
        hideWhenNotPlaying hide: Bool? = nil,
        hideDuringCapture: Bool? = nil,
        contentWidth: CGFloat? = nil
    ) {
        let settings = AppSettings.shared
        let visible = notchEnabled ?? settings.notchOverlayEnabled
        if isVisible != visible { isVisible = visible }
        let hideValue = hide ?? settings.hideWhenNotPlaying
        if hideWhenNotPlaying != hideValue { hideWhenNotPlaying = hideValue }
        let captureHidden = hideDuringCapture ?? settings.hideDuringScreenCapture
        let sharing: NSWindow.SharingType = captureHidden ? .none : .readWrite
        if window?.sharingType != sharing { window?.sharingType = sharing }
        updateActualVisibility(isPlayingNow: PlaybackCoordinator.shared.isPlayingSmoothed)
        recomputeGeometry(animate: false, contentWidth: contentWidth)
    }

    /// 副本销毁前调:先把窗口收走,再断掉订阅,最后**破掉保留环**。
    ///
    /// ⚠️ 最后两行不是可选的清理,是释放的前提(2026-08-19 性能审计坐实的真泄漏):
    /// controller.hostingView 强持 NSHostingView,其 rootView(NotchWindowRoot)的
    /// @ObservedObject controller 又强持回来 —— 教科书式两节点保留环。NotchMirrorManager
    /// 把 mirrors[id] 置 nil 后没人再引用这套对象,但环内互持,整套 NSPanel + SwiftUI 树
    /// (还可能钉着一张旧封面)永久泄漏,且泄漏树仍挂在 PlaybackCoordinator/AppSettings/
    /// NotchTransientCenter 的 objectWillChange 扇出里;拔屏/合盖/开关「所有屏幕」的
    /// 插拔循环会无界累积。断开 contentView/hostingView 这一向,环即解体。
    /// (主实例 .shared 是有意常驻的单例、从不 teardown,不受影响。)
    func teardown() {
        window?.orderOut(nil)
        isPlayingObserver?.cancel()
        isPlayingObserver = nil
        adBreakObserver?.cancel()
        adBreakObserver = nil
        lyricPresenceObserver?.cancel()
        lyricPresenceObserver = nil
        durationObserver?.cancel()
        durationObserver = nil
        trackPresenceObserver?.cancel()
        trackPresenceObserver = nil
        if let screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
            self.screenParamsObserver = nil
        }
        pendingHoverWork?.cancel()
        pendingHoverWork = nil
        window?.contentView = nil
        hostingView = nil
    }

    // 顶边固定贴在屏幕最顶端(screen.frame.maxY)、水平居中对齐刘海中心点、总高度 =
    // 刘海高度 + 内容行高度(+ hover 展开时再加 expandedExtraHeight)、宽度固定(见
    // contentWidth(baseWidth:notchWidth:))。
    // 2026-08-17 去掉了 isPlayingOverride 参数:它唯一的用途是算 isCollapsed,而那个已经
    // 改成计算属性了(见那边的注释)。这个函数现在跟播放状态完全无关,自然也就不再需要
    // 绕开 @Published willSet 的旧值陷阱。
    /// contentWidth:非 nil = 调用方正处于 notchContentWidth 的 willSet 窗口(镜像
    /// sink 那条路),必须用传入值;nil = 回读存储值(设置页滑杆对 .shared 的调用发生在
    /// 赋值语句之后,以及 init/屏幕插拔这些时机,存储值都是稳定的)。
    private func recomputeGeometry(animate: Bool, contentWidth: CGFloat? = nil) {
        guard let window, let screen = resolvedScreen() else { return }
        let geo = Self.geometry(for: screen)
        // 四个 @Published 全部判等再写(2026-08-19):这个函数挂在设置同步/屏幕插拔/镜像
        // syncAll 多条路径上,绝大多数调用几何根本没变,不判等就是每次白发四条
        // objectWillChange 打醒整卡视图树。
        if contentTopInset != geo.notchHeight { contentTopInset = geo.notchHeight }
        if notchWidth != geo.notchWidth { notchWidth = geo.notchWidth }
        // 兜底同样读缓收版:收缩判定必须跟上面的可见性判定同一口径,否则会出现
        // "窗口还在但已经缩成刘海"或反过来的错配。
        // 这里不再算 isCollapsed —— 它已经是从 isPlayingNow/isExpanded 现算的计算属性
        // (2026-08-17 改,理由见那边的注释)。几何重算只管刘海尺寸和卡片宽度。
        let newSteady = Self.contentWidth(
            baseWidth: contentWidth ?? AppSettings.shared.notchContentWidth,
            notchWidth: geo.notchWidth)
        if steadyCardWidth != newSteady { steadyCardWidth = newSteady }
        let newCollapsed = geo.notchWidth > 0 ? geo.notchWidth : Self.collapsedFallbackWidth
        if collapsedCardWidth != newCollapsed { collapsedCardWidth = newCollapsed }
        // 窗口恒为**最大**形态(展开态)的尺寸,不再随收起/稳态/展开三种形态改。三种形态
        // 现在是卡片在这个固定窗口里自己变大变小(NotchWindowRoot),窗口只在屏幕几何或
        // 宽度设置变化时才动。
        //
        // ⚠️ 多出来的那片区域必须保持纯透明、不能有任何命中形状 —— 它压在系统菜单栏上,
        // 详见 NotchWindowRoot 顶部那段(带实测结论)。
        // 窗口尺寸 = 展开态卡片本身,不留额外余量。
        //
        // ⚠️ 2026-08-17 这里短暂加过一圈"投影余量":当时展开态卡片带 .shadow,而窗口跟
        // 卡片严丝合缝,阴影被窗口的矩形边界硬裁,在底部两个圆角外侧留下两块直角残影。
        // 留出余量确实修好了那个直角,但阴影完整画出来之后整个卡片外侧糊着一层灰,比原
        // 来更糟 —— 于是投影整个撤掉(见 NotchLyricsView 的 body 末尾),这圈余量也跟着
        // 撤回。**要加投影就得同时加回余量**,两件事绑在一起,别只做一半。
        let size = NSSize(
            width: steadyCardWidth,
            height: geo.notchHeight + Self.contentHeight + Self.expandedExtraHeight)
        let frame = NSRect(
            x: geo.centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        // 判等同上:setFrame(display: true) 是一次同步重绘 + WindowServer 事务,几何没变
        // 时纯属白付(镜像 syncAll 的每次触达都会走到这里)。
        if window.frame != frame { window.setFrame(frame, display: true, animate: animate) }
        let hostFrame = NSRect(origin: .zero, size: size)
        if hostingView?.frame != hostFrame { hostingView?.frame = hostFrame }
    }
}
