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

    /// 这一档要按哪个尺寸渲染再缩。迷你直接取真窗口那份常量,别另写一个数 —— 两边一漂,
    /// 预览就不是"它真打开的样子"了。
    private var contentSize: CGSize {
        mini ? LyricsWindowMiniMetrics.size : Self.contentSize
    }
    private var scale: CGFloat { Self.previewWidth / contentSize.width }
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
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return LyricsWindowView(previewMode: true, previewMini: mini)
            .frame(width: contentSize.width, height: contentSize.height)
            .scaleEffect(scale, anchor: .topLeading)
            // scaleEffect 是渲染期变换、**不改变布局尺寸**,所以要再套一层缩小后的 frame 把
            // 版面占位收回来,否则这一块会按原尺寸占位、把下面的卡片全顶到屏幕外。
            .frame(width: Self.previewWidth, height: previewHeight, alignment: .topLeading)
            .clipShape(shape)
            // 一条发丝描边,理由同 settingsCardBackground:窗口自己的背景是模糊封面,亮暗随歌
            // 变化,没有描边时边界时有时无。
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .allowsHitTesting(false)
            // 预览是给眼睛看的,不该出现在辅助技术的浏览顺序里 —— 里面那一堆按钮既点不动、
            // 也不是真窗口的那几个。
            .accessibilityHidden(true)
    }
}
