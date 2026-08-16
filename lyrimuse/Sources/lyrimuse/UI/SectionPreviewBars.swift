import AppKit
import LyrimuseCore
import SwiftUI

// 「外观」页里灵动岛/菜单栏两段各自的顶部预览。
//
// 桌面悬浮歌词那一段早就有 OverlayPreviewBar 了,这两段一直没有 —— 而它们同样面临
// "改完的效果只出现在别处、而那个别处此刻多半看不见"的问题:灵动岛贴在刘海下(设置窗
// 一挡就没了),菜单栏歌词只有一行字还得等有歌在播。
//
// ⚠️ 刻意**不**复用 OverlayPreviewBar。那一条画的是悬浮歌词的字体/颜色/描边/宽度,而
// 灵动岛和菜单栏**根本不读那些设置**(灵动岛用自己的 notchCardStyle,菜单栏就是系统
// 菜单栏字)。拿同一条预览挂在这两段上,等于暗示那些设置对它们也有效 —— 那是错的。
// 每一段的预览只反映这一段自己那几项设置。
//
// 这两个都照 OverlayPreviewBar 的几条教训写(见那边注释):高度固定不跟内容变(挂在
// safeAreaInset 上,高度一动整页就跳)、只订阅要用的那一两个 @Published(别 ObservedObject
// 整个 PlaybackCoordinator)、自带不透明底色(inset 区域盖不到 ScrollView 的 background)。

// 三段预览栏共用的外层度量。
//
// ⚠️ 高度必须**三段统一**。这一条钉在滚动区上方,它一变高变矮,下面整块内容就跟着上下
// 跳一次 —— 而三条预览的自然高度差得很远(灵动岛那条要给刘海让位、还要给 hover 展开
// 预留一截;菜单栏那条只有一行字),于是"点来点去整个框架一直在动"(2026-08-15 用户报的
// 就是这个)。
//
// 取三条里最高的那条当基准,其余两条把多出来的空间留白。不写死数字,是因为悬浮歌词那条
// 的卡片高度跟着字号走(见 OverlayPreviewBar.cardHeight),字号调大到一定程度它就会反超
// 灵动岛那条。
@MainActor
enum SectionPreviewMetrics {
    static let topPadding: CGFloat = 14
    static let bottomPadding: CGFloat = 10
    static let captionSpacing: CGFloat = 6
    /// caption 那一行(.font(.caption))的行高经验值。
    static let captionHeight: CGFloat = 15

    /// 卡片之外的固定开销。
    private static var chromeHeight: CGFloat {
        topPadding + captionSpacing + captionHeight + bottomPadding
    }

    static var barHeight: CGFloat {
        chromeHeight
            + max(
                OverlayPreviewBar.cardHeight,
                NotchPreviewBar.cardHeight,
                MenuBarPreviewBar.cardHeight)
    }
}

/// 灵动岛预览用的 chrome:凑齐 NotchLyricsView 要的那几个属性,但不建窗口、不碰屏幕。
///
/// ⚠️ 这个类存在的唯一理由,就是让预览**不去碰 NotchLyricsWindowController.shared**。
/// 见那个文件顶部那条不变量:`.shared` 是 `static let`,哪怕只是拿来读一下属性都会执行
/// init() 建窗口并立刻 orderFront —— 灵动岛关着的用户,一打开设置页就会在屏幕顶上凭空
/// 多出一个胶囊。所以刘海几何这里走的是那边不碰实例状态的 static 函数。
///
/// 用独立实例还有第二个好处:鼠标划过预览时展开的是**预览这一份**,不会顺手把真窗口
/// 也撑开。
@MainActor
final class NotchPreviewChrome: ObservableObject, NotchChromeSource {
    @Published private(set) var isExpanded = false
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var contentTopInset: CGFloat = 0

    /// 预览恒为 false。isCollapsed 是真窗口"没在播放就缩回刘海大小、内容整套不渲染"的
    /// 行为 —— 照搬到设置页就是一片空白,而用户恰恰是来这里看样式的。
    var isCollapsed: Bool { false }

    init() { refreshGeometry() }

    /// 视图内部那个 .onHover 打进来的调用,预览里**故意忽略**(空实现)。
    ///
    /// 那个 .onHover 挂在 NotchLyricsView 最外层的 GeometryReader 上,覆盖的是它整个
    /// 布局 frame。真窗口上这分毫不差 —— 那个 frame 就是窗口本身,鼠标进窗口才叫 hover。
    /// 但预览是嵌在设置页里的一块,外面还套着定高容器、等比缩放和 safeAreaInset,实测
    /// 触发范围比肉眼看到的卡片大一圈:鼠标还没真移到卡片上就展开了。
    ///
    /// 所以预览不吃这条隐式路径,命中判定改由 NotchPreviewBar 拿精确坐标跟卡片矩形直接
    /// 比 —— 见那边的 onContinuousHover。
    func setExpanded(_ expanded: Bool) {}

    /// 预览自己算出来的命中结果,这才是预览里真正生效的那条路。
    func setExpandedFromPreview(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
    }

    /// 跟真窗口 recomputeGeometry 取的是同一块屏、同一个公式,预览里的让位宽度/高度才
    /// 会跟真出来的严丝合缝。设置页开着时用户插拔显示器也要跟着变,所以是个可重入方法。
    func refreshGeometry() {
        guard let screen = NotchLyricsWindowController.targetScreen() else { return }
        let geo = NotchLyricsWindowController.geometry(for: screen)
        notchWidth = geo.notchWidth
        contentTopInset = geo.notchHeight
    }
}

/// 灵动岛那一段的预览:直接把真窗口那份 NotchLyricsView 搬进设置页渲染。
///
/// ⚠️ 这里刻意**不**画简化版的刘海卡。第一版就是手搓的(一个圆角矩形 + 一行居中的字),
/// 结果是"预览里长这样、真出来完全不是这样":两只耳朵上的歌名和三个播放按钮、歌词行
/// 尾端的封面缩略图、逐字高亮、hover 展开出来的下一句 + 迷你进度条,一样都没有。设置页
/// 预览的全部意义就是所见即所得,一份会漂的复刻件比没有预览更糟。
///
/// 做法是把 NotchLyricsView 泛型化(见 NotchChromeSource):真窗口拿
/// NotchLyricsWindowController 当 chrome,预览拿上面那个不建窗口的 NotchPreviewChrome。
/// 于是这里渲染的是**同一份视图代码**,不存在复刻件漂移;hover 展开、点播放按钮控制播放
/// 也都照常能用(按钮打的本来就是 PlaybackCoordinator,跟从哪个窗口点的无关)。
@MainActor
struct NotchPreviewBar: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var chrome = NotchPreviewChrome()

    // 预览条能给的最大宽度。比卡片列(600)窄一截,两侧留呼吸。
    private let maxPreviewWidth: CGFloat = 460

    /// 走真窗口那个公式,不直接用 settings.notchContentWidth —— 宽度调得很小时真窗口会被
    /// "两只耳朵放得下按钮"的下限顶宽,预览得跟着一起顶,否则这一段恰恰在最容易出岔的
    /// 区间失真。
    private var contentWidth: CGFloat {
        NotchLyricsWindowController.contentWidth(
            baseWidth: settings.notchContentWidth, notchWidth: chrome.notchWidth)
    }

    /// 卡片此刻的真实高度,跟真窗口 setFrame 的算法一致(刘海高 + 内容行,展开再加一截)。
    private var cardHeight: CGFloat {
        chrome.contentTopInset + NotchMetrics.compactRowHeight
            + (chrome.isExpanded ? NotchMetrics.expandedExtraHeight : 0)
    }

    /// 容器按**展开态**固定高。hover 展开时卡片会长高 40pt,容器高度要是跟着变,这条预览
    /// 就会把下面整页顶一下 —— OverlayPreviewBar 那边记过这个教训。
    private var fullHeight: CGFloat { Self.cardHeight }

    /// 这一条的卡片自然高度,供 SectionPreviewMetrics 取三条的最大值。
    /// 用 static 是因为要在不构造视图的情况下问出来;刘海让位高度只跟屏幕有关,
    /// 走的是不碰 .shared 的 static 几何函数(理由见 NotchPreviewChrome)。
    static var cardHeight: CGFloat {
        let inset = NotchLyricsWindowController.targetScreen()
            .map { NotchLyricsWindowController.geometry(for: $0).notchHeight } ?? 32
        return inset + NotchMetrics.compactRowHeight + NotchMetrics.expandedExtraHeight
    }

    // 宽度滑杆能拖到 500,超过预览区就整体等比缩小 —— 这样"宽度"这一项在预览里看得见。
    private var scale: CGFloat { min(1, maxPreviewWidth / max(contentWidth, 1)) }

    var body: some View {
        VStack(spacing: 6) {
            NotchLyricsView(controller: chrome)
                // 先钉当下的真实尺寸:视图内层是 GeometryReader,耳朵宽度按 proxy.size.width
                // 算,给错尺寸这一层就先失真了。
                .frame(width: contentWidth, height: cardHeight)
                .animation(.easeInOut(duration: 0.18), value: chrome.isExpanded)
                // 再顶对齐放进固定高的容器 —— 真窗口也是顶边贴死屏幕顶、只向下长。
                .frame(width: contentWidth, height: fullHeight, alignment: .top)
                // 命中判定显式做。这一层的局部坐标原点正好落在卡片左上角(卡片顶对齐、
                // 两者等宽),所以"鼠标在不在卡片上"就是一句 y 的比较,不受外层缩放/
                // safeAreaInset 的坐标转换影响 —— 理由见 NotchPreviewChrome.setExpanded。
                //
                // cardHeight 本身会随展开变高,于是展开后鼠标继续往下移进新长出来的那
                // 40pt 仍然算在卡片上、维持展开;这跟真窗口"展开时窗口一起变高"是同一个
                // 行为,展开出来的下一句和进度条才够得着。
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        chrome.setExpandedFromPreview(point.y <= cardHeight)
                    case .ended:
                        chrome.setExpandedFromPreview(false)
                    }
                }
                .scaleEffect(scale, anchor: .top)
                // 缩放不改变布局占位,得显式把外框收到缩放后的尺寸。
                .frame(width: contentWidth * scale, height: fullHeight * scale)
            Text(String(format: L10n.t("预览 · %@pt，指向可展开"), "\(Int(contentWidth))"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.top, SectionPreviewMetrics.topPadding)
        .padding(.bottom, SectionPreviewMetrics.bottomPadding)
        // 三条预览栏共用一个高度,切段时这一条不能变高变矮(见 SectionPreviewMetrics)。
        .frame(height: SectionPreviewMetrics.barHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            chrome.refreshGeometry()
        }
    }
}

/// 菜单栏那一段的预览。
///
/// 2026-08-16 重做:以前这里是"仿"一条菜单栏 —— 圆角条 + 一个现实里根本不存在的音符
/// 图标 + `.system(size: 13)` 的文字,而且滚动只演开头那一帧(静止的)。跟用户真正看到的
/// 东西差得远(用户原话:预览里要真实模拟实际的菜单栏)。
///
/// 现在这条预览**就是菜单栏本体那套代码**:
///   * 要不要滚、滚多快、首尾停多久 —— 走 MenuBarMarqueeRenderer.presentation,跟
///     MenuBarStatusItem 同一个函数,不可能漂;
///   * 需要滚的句子直接挂 MenuBarScrollingLabel(真窗口里那个 layer-backed NSView),
///     同一张长图、同一条 CAKeyframeAnimation,**真的会滚**;
///   * 装得下的句子用 NSFont.menuBarFont(系统菜单栏字体本体),不是 13pt 系统字。
///
/// 外框改成一小段仿菜单栏:.bar 材质(就是菜单栏/工具栏那层材质)、内容靠右,右边跟着
/// 几个常见的状态栏图标和真实时钟 —— 这些只是给"占多宽"一个参照物,让宽度滑杆的效果
/// 看得出来。歌词那一格的宽度**恒定**(设置里的「显示宽度」),跟真菜单栏上一模一样 ——
// 长短句来回切都不会伸缩。
@MainActor
struct MenuBarPreviewBar: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var line: SyncedLyricLine?

    private var fullText: String {
        if let text = line?.plainText, !text.isEmpty { return text }
        return L10n.t("这里是一句歌词示例")
    }

    private var presentation: MenuBarMarqueeRenderer.Presentation {
        MenuBarMarqueeRenderer.presentation(
            for: fullText, windowWidth: settings.menuBarLyricsWidth,
            // 演的是示例句(没在播放)时没有"这句会显示多久"可言,给 nil 走固定速度。
            //
            // ⚠️ 这个值是在 **body 求值时**现读的,不是在上面那个 onReceive 里存下来的。
            // $currentLine 是 @Published,回调跑在 willSet 时机 —— 那一刻
            // currentLineIndex/allLines 还可能是旧值(这个项目已经为这个时机踩过两次坑)。
            // 而 body 求值发生在状态落定之后,读到的必然是同一句歌词对应的那份数据。
            dwellSeconds: line == nil ? nil : PlaybackCoordinator.shared.currentLineDwellSeconds)
    }

    private var willScroll: Bool {
        if case .fixed(_, _, let pacing) = presentation { return pacing != nil }
        return false
    }

    /// 仿菜单栏那一条的高度。真菜单栏内容区约 22pt,这里取整到 24 留一点呼吸。
    static var cardHeight: CGFloat { 24 }

    var body: some View {
        VStack(spacing: 6) {
            menuBarStrip
            // 别把"会滚动"说成"已截断" —— 超宽时到底是滚还是截,由宽度决定,说反了正是
            // 让人觉得这个功能"怪怪的"的原因之一。
            Text(
                willScroll
                    ? String(format: L10n.t("预览 · 固定宽度 %@pt，本句会横向滚动"),
                             "\(Int(settings.menuBarLyricsWidth))")
                    : String(format: L10n.t("预览 · 固定宽度 %@pt"),
                             "\(Int(settings.menuBarLyricsWidth))")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.top, SectionPreviewMetrics.topPadding)
        .padding(.bottom, SectionPreviewMetrics.bottomPadding)
        // 三条预览栏共用一个高度(见 SectionPreviewMetrics)。这一条内容最少,多出来的
        // 空间留白 —— 留白远好过让下面整页跟着跳。
        .frame(height: SectionPreviewMetrics.barHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(PlaybackCoordinator.shared.$currentLine.removeDuplicates()) { line = $0 }
        .accessibilityHidden(true)
    }

    /// 一小段仿菜单栏。内容靠右,跟真菜单栏上状态栏项的位置一致。
    private var menuBarStrip: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 12)
            lyricsSlot
            // 右边这几个只是参照物,让"歌词占了菜单栏多宽"看得出来。用真实时钟而不是
            // 写死一个时间 —— 假数据会让人下意识觉得这块预览"不是真的"。
            HStack(spacing: 11) {
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text(Date(), style: .time)
            }
            .font(Font(MenuBarMarqueeRenderer.font))
            .foregroundStyle(Color(nsColor: .labelColor).opacity(0.55))
            .padding(.leading, 14)
            .padding(.trailing, 12)
        }
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity)
        // ⚠️ 只铺 .bar 材质是不够的:那层材质压在设置窗自己的背景上几乎同色,整条读起来
        // 就是"悬空的文字",完全不像菜单栏(2026-08-16 第一版实拍确认)。真菜单栏之所以
        // 一眼认得出来,是因为它半透明地压在**桌面壁纸**上。所以这里跟桌面悬浮歌词那条
        // 预览用同一张真实壁纸垫底(DesktopWallpaperSample),再压 .bar ——
        // 合成出来的就是菜单栏本来的样子。
        //
        // 壁纸顶端对齐:菜单栏在屏幕最上面,透出来的本来就是壁纸的上边缘那一条。
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                if let wallpaper = DesktopWallpaperSample.image {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(height: Self.cardHeight, alignment: .top)
                        .clipped()
                } else {
                    // 读不到壁纸(动态壁纸/没权限/无屏)就退回一块中性深色 —— 它至少还是
                    // 一条"压在别的东西上的横条",不会退化成跟页面同色的空白。
                    Color(nsColor: .textColor).opacity(0.14)
                }
                // 用 .ultraThinMaterial 而不是 .bar:.bar 在浅色外观下几乎不透明,压上去
                // 直接把壁纸糊成一块灰(2026-08-16 实拍确认),而真菜单栏的透明度高得多 ——
                // 深色壁纸下整条菜单栏是深的、文字自动转白,那正是它一眼认得出来的原因。
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// 歌词那一格。宽度恒等于设置里的「显示宽度」,跟真状态栏项一致(那边靠一张固定尺寸的
    /// 透明占位图把 footprint 跟内容脱钩,见 MenuBarStatusItem.showFixedWidth)。
    ///
    /// 短句右边空出一块是**正常的**,真菜单栏上就是这样 —— 那正是固定宽度换来的稳定:
    /// 长短句来回切,这一项和右边的图标都不会动。
    ///
    /// (这一段 2026-08-17 反复过两次:先是两条分支都钉成上限宽 → 那时语义还是"上限",
    /// 于是预览空一大片而真机不空,是真偏差;改成按文字自然宽度之后语义对上了,但用户
    /// 随即指出真机上那种伸缩本身就难看,于是把设置改成固定宽度,两边又都钉死了。)
    @ViewBuilder
    private var lyricsSlot: some View {
        switch presentation {
        case .text(let visible):
            // 退化路径(宽度设成 0):真机上也是交给按钮画一段截断文字。
            Text(visible)
                .font(Font(MenuBarMarqueeRenderer.font))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .fixedSize()
                .frame(height: MenuBarMarqueeRenderer.lineHeight)
        case .fixed(let text, let windowWidth, let pacing):
            MenuBarScrollingLabel.Representable(
                text: text, windowWidth: windowWidth, pacing: pacing)
                .frame(width: windowWidth, height: MenuBarMarqueeRenderer.lineHeight)
        }
    }
}
