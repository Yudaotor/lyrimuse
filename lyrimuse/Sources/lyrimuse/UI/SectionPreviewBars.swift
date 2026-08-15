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
    /// 挂在 safeAreaInset 上就会把整页顶一下 —— OverlayPreviewBar 那边记过这个教训。
    private var fullHeight: CGFloat {
        chrome.contentTopInset + NotchMetrics.compactRowHeight + NotchMetrics.expandedExtraHeight
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
        .padding(.top, 14)
        .padding(.bottom, 10)
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

/// 菜单栏那一段的预览:按当前「最大字数」和「横向滚动」显示这一行会被截成什么样。
@MainActor
struct MenuBarPreviewBar: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var line: SyncedLyricLine?

    private var fullText: String {
        if let text = line?.plainText, !text.isEmpty { return text }
        return L10n.t("这里是一句歌词示例")
    }

    /// 复用真实的截断/取窗逻辑,不自己另写一份 —— 两份实现必然漂。
    /// step 传 0 = 停在开头那一帧(滚动到中段的样子这里没必要演,那需要常驻一个定时器)。
    private var visibleText: String {
        if settings.menuBarLyricsScroll {
            return MenuBarMarquee.window(
                text: fullText, maxChars: settings.menuBarLyricsMaxChars, step: 0, holdSteps: 0)
        }
        return fullText.count > settings.menuBarLyricsMaxChars
            ? String(fullText.prefix(settings.menuBarLyricsMaxChars)) + "…"
            : fullText
    }

    private var truncated: Bool { fullText.count > settings.menuBarLyricsMaxChars }

    var body: some View {
        VStack(spacing: 6) {
            // 仿一小段菜单栏:圆角条 + 音符图标 + 那行字。用系统菜单栏字号(13),
            // 因为菜单栏歌词就是系统字,这一页没有字体/颜色可调。
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                Text(visibleText)
                    .lineLimit(1)
            }
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            // 三态,别把"会滚动"说成"已截断":超宽时到底是滚还是截,取决于上面那个开关,
            // 说反了正是让人觉得这个功能"怪怪的"的原因之一。
            Text(
                !truncated
                    ? String(format: L10n.t("预览 · 上限 %@ 字"), "\(settings.menuBarLyricsMaxChars)")
                    : settings.menuBarLyricsScroll
                        ? String(format: L10n.t("预览 · 上限 %@ 字，本句会横向滚动"),
                                 "\(settings.menuBarLyricsMaxChars)")
                        : String(format: L10n.t("预览 · 上限 %@ 字，本句已截断"),
                                 "\(settings.menuBarLyricsMaxChars)")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(PlaybackCoordinator.shared.$currentLine.removeDuplicates()) { line = $0 }
        .accessibilityHidden(true)
    }
}
