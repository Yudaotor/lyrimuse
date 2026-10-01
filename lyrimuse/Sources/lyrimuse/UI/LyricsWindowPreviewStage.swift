import LyrimuseCore
import SwiftUI

/// 「歌词显示 › 歌词窗口」那一段的预览。
///
/// 这里**就是歌词窗口本体**(`LyricsWindowView`),不是照着它画的仿制品 —— 同一份视图、同一份
/// 数据、同一套逐字填色和自动滚动,所以它跟真窗口逐像素一致,也不会像仿制品那样迟早跟本体走散
/// (这条教训记在 `SectionPreviewBars` 的头注里:菜单栏那条预览当年就是"仿"的,连一个现实里不
/// 存在的音符图标都画上了)。
///
/// 三件事跟真窗口不一样,每一件都有非做不可的理由:
///
///   1. **`previewMode: true`** —— 关掉两处会伤到宿主窗口的副作用(接管设置窗口、误记账),
///      理由见 `LyricsWindowView.previewMode` 的注释。
///   2. **`.allowsHitTesting(false)`** —— 整块不收事件。歌词窗口里有「⋯」菜单、简介面板、榜单
///      面板、逐行 hover 跳转、播控、音量、翻译菜单……十几处交互,逐个关既要改本体、又必然漏。
///      一行整体禁用最干净,而且预览本来就不该能操作真实播放。副作用是连滚动也滚不动 —— 这正是
///      想要的:预览跟着播放自动滚,不该被人翻走。
///   3. **按真窗口尺寸渲染再整体缩小** —— 不是把视图塞进一个 600pt 宽的小 frame。歌词窗口在窄
///      宽度下会**退化成单列**(见 `LyricsWindowView` 根容器那段注释),直接塞小 frame 预览出来
///      的就是单列版,而用户真打开看到的是双列,那就谈不上"一致"了。
///
/// 迷你尺寸下顶部信息那一组可以点:悬停描一圈虚线框,点一下弹出「顶部信息」浮层(跟灵动岛编辑台
/// 的可点区域同一套观感,见 `NotchEditorStage.hotspotView`)。这块可点区域叠在**预览外面**,
/// 不在被 `allowsHitTesting(false)` 挡住的那一层里;浮层内容由设置页传进来(`headerPopover`),
/// 跟工具栏「顶部信息」那颗按钮是同一份。
struct LyricsWindowPreviewStage: View {
    /// 预览在看哪个形态的存储键。
    ///
    /// 设置页那边也要读它 —— 下面的配置卡跟着这个切(完整一套、迷你一套),所以提成常量,
    /// 别两处各写一遍字面量。
    static let showsMiniStorageKey = "settings:lyricsWindowPreviewMini"

    /// 看的是哪个形态。存进 AppStorage 而不是 @State:切过去看迷你、下次回到这一页还在迷你,
    /// 不用每次重选。纯 UI 偏好,不进 AppSettings(collector 不需要知道)。
    @AppStorage(showsMiniStorageKey) private var showsMini = false

    /// 画完整尺寸还是迷你尺寸(由上面那个偏好驱动,留参数是为了将来能从别处指定)。
    private var mini: Bool { showsMini }

    /// 迷你顶部信息那一块可点区域点开的浮层内容。擦成 AnyView 而不是做成泛型:这个类型上有静态
    /// 存储属性(`showsMiniStorageKey` 等,设置页也读),泛型类型不支持。
    private let headerPopover: () -> AnyView
    /// 外面(工具栏)打开了同一份「顶部信息」浮层:虚线框照悬停时那样亮着。浮层里有「宽度」,
    /// 拖它时要看得见框跟着变宽变窄。
    private let highlightsHeader: Bool

    init<Popover: View>(highlightsHeader: Bool = false,
                        @ViewBuilder headerPopover: @escaping () -> Popover) {
        self.highlightsHeader = highlightsHeader
        self.headerPopover = { AnyView(headerPopover()) }
    }

    /// 顶部信息那一组在**预览内容坐标**(缩放之前)里的范围,由 `LyricsWindowView` 经
    /// `LyricsWindowPreviewHeaderAnchorKey` 报上来;没有(完整尺寸、三样全关)就是 nil。
    @State private var headerRect: CGRect?
    @State private var headerHovered = false
    @State private var headerPopoverShown = false

    /// 按哪个尺寸渲染。取 `App.swift` 里那个 Window 场景声明的 ideal 尺寸 ——
    /// 也就是用户第一次打开歌词窗口看到的那个样子。
    ///
    /// 刻意**不**去读用户上次拖出来的尺寸(`LyricsWindowController.frameKey` 那份存档):那个值
    /// 可能是任意极端比例(拖得很扁、很窄),预览跟着变形既不好看、也不是"这扇窗长什么样"这个
    /// 问题的答案。预览回答的是形态,不是"你的窗口现在多大"。
    private static let contentSize = CGSize(width: 1020, height: 660)

    /// 预览占满内容列。跟着 `SettingsPage` 的列宽走,不写字面量 —— 那个数改了这里要跟着改。
    ///
    /// 要写 `<EmptyView>` 是因为 `SettingsPage` 是泛型(`SettingsPage<Content: View>`),而这个常量
    /// 跟 Content 无关;随便填一个具体类型把泛型参数占掉即可,取到的是同一个值。
    private static var previewWidth: CGFloat { SettingsPage<EmptyView>.maxCardColumnWidth }

    /// 这一档要按哪个尺寸渲染再缩。迷你按真窗口的默认尺寸画:字号和折行都跟着宽度走,高度决定下一行
    /// 和控制条放不放得下,两样都得跟真窗一致,预览才是"它真打开的样子"。
    private var contentSize: CGSize {
        mini ? LyricsWindowMiniMetrics.size : Self.contentSize
    }
    /// 完整尺寸缩到内容列那么宽;迷你按 1:1 画、在内容列里居中 —— 放大到列宽的话 420 宽的迷你窗
    /// 会被画成约 600 宽,比用户桌面上那扇真窗大一截,预览就不是"它真打开的样子"了。
    private var scale: CGFloat { mini ? 1 : Self.previewWidth / contentSize.width }
    /// 舞台(缩放后)的宽高。
    private var stageWidth: CGFloat { contentSize.width * scale }
    private var previewHeight: CGFloat { contentSize.height * scale }

    /// 圆角跟设置卡片同一档(`settingsCardBackground` 用的也是 continuous),让它在这一页里
    /// 读起来是"一块内容",而不是一张贴上去的截图。
    private static let cornerRadius: CGFloat = 12

    var body: some View {
        // 底下那一行原本是句「预览」的灰字,现在换成形态切换 —— 它同时兼了那句话的职责:
        // 一个选「完整/迷你」的控件摆在这儿,已经说明上面是个预览而不是真窗口。疏密仍走
        // SectionPreviewMetrics,跟菜单栏那条预览栏取齐。
        VStack(spacing: SectionPreviewMetrics.captionSpacing) {
            stage
            SettingsSegmentedControlHashable(
                selection: $showsMini,
                options: [false, true],
                label: { $0 ? L10n.t("迷你尺寸") : L10n.t("完整尺寸") }
            )
            .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }

    private var stage: some View {
        ZStack(alignment: .topLeading) {
            preview
            if mini, let headerRect {
                headerHotspot(headerRect)
            }
        }
        .frame(width: stageWidth, height: previewHeight, alignment: .topLeading)
        .onChange(of: mini) { _, isMini in
            if !isMini { headerPopoverShown = false }
        }
    }

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return LyricsWindowView(previewMode: true, previewMini: mini)
            .frame(width: contentSize.width, height: contentSize.height)
            // 在缩放之前取范围:这里拿到的是内容坐标,下面叠可点区域时再乘 scale。
            .overlayPreferenceValue(LyricsWindowPreviewHeaderAnchorKey.self) { anchor in
                GeometryReader { geo in
                    let rect = anchor.map { geo[$0].integral }
                    Color.clear
                        .onAppear { headerRect = rect }
                        .onChange(of: rect) { _, new in headerRect = new }
                }
            }
            .scaleEffect(scale, anchor: .topLeading)
            // scaleEffect 是渲染期变换、**不改变布局尺寸**,所以要再套一层缩小后的 frame 把
            // 版面占位收回来,否则这一块会按原尺寸占位、把下面的卡片全顶到屏幕外。
            .frame(width: stageWidth, height: previewHeight, alignment: .topLeading)
            .clipShape(shape)
            // 一条发丝描边,理由同 settingsCardBackground:窗口自己的背景是模糊封面,亮暗随歌
            // 变化,没有描边时边界时有时无。
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .allowsHitTesting(false)
            // 预览是给眼睛看的,不该出现在辅助技术的浏览顺序里 —— 里面那一堆按钮既点不动、
            // 也不是真窗口的那几个。
            .accessibilityHidden(true)
    }

    /// 顶部信息那一块可点区域:平时透明,悬停描一圈白色虚线细框 + 一层极淡的白底,指针换成手形;
    /// 点一下弹出「顶部信息」浮层,锚在这块下面。线型、透明度、圆角跟灵动岛编辑台的可点区域
    /// 一个样(`NotchEditorStage.hotspotView`),白色不跟深浅色走,理由同那边:它压在模糊封面上。
    ///
    /// 在缩放后的舞台坐标里画(范围乘 scale),线宽才是实打实的 1pt;四周外扩 6pt,框不贴着字。
    /// 用 padding 定位而不是 offset:浮层认的是布局 frame,offset 是几何效果、挪不动它。
    private func headerHotspot(_ contentRect: CGRect) -> some View {
        let rect = CGRect(x: contentRect.minX * scale, y: contentRect.minY * scale,
                          width: contentRect.width * scale, height: contentRect.height * scale)
            .insetBy(dx: -6, dy: -6)
        let lit = headerHovered || headerPopoverShown || highlightsHeader
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(lit ? 0.07 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(lit ? 0.7 : 0),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .onHover { inside in
                headerHovered = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture { headerPopoverShown = true }
            // 悬停着切到完整尺寸时这块直接消失、收不到移出事件,手形指针得在这里还回去。
            .onDisappear {
                if headerHovered { NSCursor.pop() }
                headerHovered = false
            }
            .animation(.easeOut(duration: 0.12), value: lit)
            .popover(isPresented: $headerPopoverShown, arrowEdge: .bottom) { headerPopover() }
            .accessibilityElement()
            .accessibilityLabel(String(format: L10n.t("打开「%@」设置"), L10n.t("顶部信息")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { headerPopoverShown = true }
            .padding(.leading, max(0, rect.minX))
            .padding(.top, max(0, rect.minY))
    }
}

/// 迷你顶部信息那一组的范围,只在预览里报(见 `LyricsWindowView.miniTopInfo`)。
struct LyricsWindowPreviewHeaderAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
