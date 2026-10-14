import AppKit
import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」那几张卡里的**设置行本体**,从 SettingsView 抽出来的唯一一份实现。
//
// 为什么抽(编辑台第二步):这一段现在有**两个**宿主 ——
//   ① 内容区里原有的卡片列(overlayColorCard / overlayThemesCard / overlayTextCard /
//      overlayResetCard),它是键盘/VoiceOver/"我就想找个开关"的全量兜底通路;
//   ② 编辑台(OverlayEditorStage)工具栏和画布命中区弹出的浮层。
// 两个宿主必须是**同一份**行实现。这个仓库刚为"同一个视觉属性有两条渲染路径"付过代价:
// 「对齐方式」在预览条上失效,根因就是补对齐时只改了静态文本那一条路径、逐字填色那条漏了
// (那份简化渲染 OverlayLyricsCanvas 已随钉条一起删除,完整记录见
//  docs/features/04-desktop-overlay.md)。设置行比渲染更容易漂 ——
// 复制一份之后,以后每加一个条件显示、每改一句副标题,都要记得改两处;漏了不会编译报错,
// 只会变成"在浮层里改了有用、在卡片里改了没用"。所以这里一律只留一份,宿主只负责外壳
// (卡片背景 / 浮层外壳)。
//
// 两个宿主绑的是同一个 AppSettings.shared,所以"浮层里改"和"卡片里改"天然同步,不需要
// 任何双向绑定代码 —— 这也是不把设置值往上提成 @State 的理由:一提就多出一份要同步的真相。

// MARK: - 字形

/// 「字形」那一组:字体 / 粗细 / 字号 —— 字长什么样。颜色、描边、卡拉OK 在「颜色」(`OverlayColorSettingsRows`),
/// 版面在「排版」,一键套一整套配色在「主题」:按"这个字段改的是哪一层"归组。
///
/// 原来的「文字」组(字形 + 卡拉OK + 字色 + 描边)和「背景」组在往上弹、只有按钮上方约 200pt 的浮层里放不下,
/// 重分成「字形」「颜色」两组,工具栏仍是三颗(第一行横向预算见 `OverlayEditorStage.toolbar`)。
@MainActor
struct OverlayTypeSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRowGroup {
            VStack(spacing: 0) {
                SettingsRow(icon: "character", title: L10n.t("字体")) {
                    // 系统装了什么就能选什么(带搜索、每行用字体自己渲染),见 FontFamilyPicker 顶部注释。
                    FontFamilyPicker(selection: $settings.fontFamilyName)
                }
                CardDivider()
                // 加(「帮我悬浮歌词模块加一个控制字体粗细的功能配置吧」)。
                //
                // 排在字体和字号**之间**:粗细是"这个字体族的哪一个粗细",跟字体是同一件事的两半,
                // 中间隔着字号会把它读成一个独立维度。
                //
                // 这一行叫「粗细」不叫「字重」(改的,「这个命名为字重是不是
                // 不太合适啊」)。「字重」是排版行话,而用户提这个需求时自己的原话就是"控制字体粗细"
                // —— 用户已经说出口的那个词,就是这一行该有的名字。**代码里的标识符仍然叫
                // `overlayFontWeight` / `OverlayFontWeight`**,那是给写代码的人看的,行业术语在那边
                // 反而更准确;这条不对称是有意的,别为了"统一"把界面文案改回去。
                //
                // 这里选的是**主歌词行**那一档,罗马音/译文/下一句三行按固定档位差自动跟着细
                // (见 `OverlayFontWeight`)。刻意不做成四行各自可调:那是四个滑杆的复杂度,换来的是
                // 用户可以把译文调得比主歌词还粗——一个没人想要、却要用界面去防的状态。
                //
                // 六个档位:分段放不下(英文更放不下),用玻璃下拉,同 `FontFamilyPicker` 那一行的形态。
                SettingsRow(icon: "bold", title: L10n.t("粗细")) {
                    SettingsGlassMenuPicker(
                        selection: $settings.overlayFontWeight,
                        options: OverlayFontWeight.allCases,
                        label: \.displayName,
                        compact: true
                    )
                }
                CardDivider()
                SettingsRow(icon: "textformat.size", title: L10n.t("字号")) {
                    HStack(spacing: 8) {
                        // SteppedSlider 而不是原生带步长的构造器:后者会在轨道下面画一排刻度点
                        // (「没有意义,不好看」),量化语义一模一样。
                        SteppedSlider(value: Binding(
                            get: { settings.fontSize },
                            set: { newValue in
                                // 相等守卫:拖动中每个鼠标事件都会调 set,step 量化后大量等值
                                // 赋值照样广播 objectWillChange,didSet 还会 recomputeFonts()
                                // 连带重赋 4 个派生字体 @Published(一写五发)——所有观察
                                // AppSettings 的界面跟着白跑(同三个宽度滑杆)。
                                guard newValue != settings.fontSize else { return }
                                settings.fontSize = newValue
                            }
                        ), in: AppSettings.overlayFontSizeRange, step: 1)
                            .frame(width: 150)
                        Text(String(format: L10n.t("%@pt"), "\(Int(settings.fontSize))"))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - 颜色

/// 「颜色」那一组:卡拉OK效果 / 文字描边 / 毛玻璃背景三个开关一行小块,下面文字颜色 / 未唱颜色 / 描边颜色 /
/// 背景颜色几格(两列)。
///
/// - 未唱颜色只在开着卡拉OK时出现:没有卡拉OK就没有"已唱 / 未唱"。它跟文字颜色是平级的一对,各自能跟随封面或选色。
/// - 描边颜色只在开着描边时出现;描边只让选颜色(含 alpha),粗细是固定常量(LyricsOverlayView 的 OptionalTextStroke)。
/// - 毛玻璃改变的是背景颜色的含义(从卡片本色变成玻璃上的着色);开着时浓淡下拉挂在毛玻璃那一块上
///   (SwiftUI 的 Material 做不成连续滑杆,见 OverlayGlassIntensity)。
/// - 文字颜色、背景颜色都开透明度:alpha 拖到 0 窗口会整个看不见,退路是工具栏「重置 ▾」和抽屉「恢复默认」。
///   背景不透明度就是背景颜色的 alpha,不另加滑杆。
/// - 「跟随封面」本身的开关在「主题」(见 OverlayThemeSettingsRows 头注);这里的下拉只切这一格的取色模式。
@MainActor
struct OverlayColorSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    // 外层那个 Stack 是下面 `.animation(value:)` 的挂载点(挂在 Group 上是逐个子视图生效的,条件格长出 / 收起的
    // 动画就没人负责)。挂 value: 而不是裸 .animation():裸的那种会把这一组里所有变化都动画化。
    var body: some View {
        SettingsRowGroupStack {
            SettingsTileGrid(columns: 3) {
                SettingsToggleTile(icon: "sparkles", title: L10n.t("卡拉OK效果"),
                                   help: L10n.t("逐字歌词随演唱逐字高亮；无逐字数据的歌曲整行高亮"),
                                   isOn: $settings.overlayLyricsKaraoke)
                SettingsToggleTile(icon: "pencil.and.outline", title: L10n.t("文字描边"), isOn: $settings.textStrokeEnabled)
                SettingsToggleTile(icon: "square.on.square", title: L10n.t("毛玻璃背景"), isOn: $settings.overlayBackgroundGlass) {
                    if settings.overlayBackgroundGlass {
                        SettingsGlassMenuPicker(
                            selection: $settings.overlayGlassIntensity,
                            options: OverlayGlassIntensity.allCases,
                            label: \.displayName,
                            compact: true
                        )
                        .help(L10n.t("玻璃浓淡"))
                        .settingsSearchHighlight(title: L10n.t("玻璃浓淡"))
                    }
                }
            }
            SettingsTileGrid(columns: 2) {
                SettingsControlCell(icon: "paintbrush", title: L10n.t("文字颜色")) {
                    colorModeMenu(
                        follows: $settings.followsCoverArt,
                        color: Binding(
                            get: { settings.foregroundColor },
                            set: { settings.foregroundColorHex = $0.hexStringWithAlpha }
                        ),
                        supportsOpacity: true
                    )
                }
                if settings.overlayLyricsKaraoke {
                    SettingsControlCell(icon: "circle.lefthalf.filled", title: L10n.t("未唱颜色")) {
                        colorModeMenu(
                            follows: $settings.karaokeUnsungFollowsCoverArt,
                            color: Binding(
                                get: { settings.karaokeUnsungColor },
                                set: { settings.karaokeUnsungColorHex = $0.hexStringWithAlpha }
                            ),
                            supportsOpacity: true
                        )
                    }
                }
                if settings.textStrokeEnabled {
                    SettingsControlCell(icon: "pencil.tip", title: L10n.t("描边颜色")) {
                        AppColorPicker(selection: Binding(
                            get: { settings.textStrokeColor },
                            set: { settings.textStrokeColorHex = $0.hexStringWithAlpha }
                        ), supportsOpacity: true)
                    }
                }
                SettingsControlCell(icon: "rectangle.fill", title: L10n.t("背景颜色")) {
                    HStack(spacing: 8) {
                        // 透明时色块只是一块棋盘格,写明「透明」;判据跟工具栏摘要同一个(`OverlayStyleSummary.background`)。
                        if !AppSettings.backgroundVisible(hex: settings.backgroundColorHex, glass: false) {
                            Text(L10n.t("透明"))
                                .foregroundStyle(.secondary)
                        }
                        AppColorPicker(selection: Binding(
                            get: { settings.backgroundColor },
                            set: { settings.backgroundColorHex = $0.hexStringWithAlpha }
                        ), supportsOpacity: true)
                    }
                }
            }
        }
        .animation(.default, value: settings.textStrokeEnabled)
        .animation(.default, value: settings.overlayLyricsKaraoke)
        .animation(.default, value: settings.overlayBackgroundGlass)
    }

    /// 「文字颜色」「未唱颜色」共用的取色控件:玻璃下拉选"跟随封面"还是"自定义颜色",
    /// 选了自定义才在旁边露出取色器。
    ///
    /// 这里**不用** `Toggle(带文字标签, isOn:)`:macOS 上这个标签
    /// 实测不渲染,行里只剩一颗光秃秃看不出含义的开关。
    @ViewBuilder
    private func colorModeMenu(follows: Binding<Bool>, color: Binding<Color>, supportsOpacity: Bool) -> some View {
        HStack(spacing: 8) {
            SettingsGlassMenuPicker(
                selection: follows,
                options: [true, false],
                label: { $0 ? L10n.t("跟随封面") : L10n.t("自定义颜色") },
                compact: true
            )
            if !follows.wrappedValue {
                AppColorPicker(selection: color, supportsOpacity: supportsOpacity)
            }
        }
    }
}

// MARK: - 排版

/// 「内容」那一组:主行下面画哪几行 —— 读音 / 译文 / 下一句,按卡片里从上到下的顺序。
///
/// 读音、译文是悬浮歌词自己那一份(`overlayShowRomanization` / `overlayShowTranslation`),不连带歌词窗口;
/// 给哪些语言标读音是歌词内容本身的设置、所有展示面共用,只在「歌词 › 调整 › 标注读音的语言」里设,这里不放
/// (04 章决策 47)。「下一句」归这里不归「排版」:它讲的是显示哪些内容,不是怎么排。见 04 章决策 42。
@MainActor
struct OverlayContentSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsTileGrid(columns: 3) {
            SettingsToggleTile(icon: "textformat.alt", title: L10n.t("读音"), isOn: $settings.overlayShowRomanization)
            SettingsToggleTile(icon: "text.bubble", title: L10n.t("译文"), isOn: $settings.overlayShowTranslation)
            SettingsToggleTile(icon: "rectangle.grid.1x2", title: L10n.t("下一句"), isOn: $settings.showNextLinePreview)
        }
    }
}

/// 「排版」那一组:对齐方式 / 长句处理 / 读音、译文、下一句的间距 —— 摆在哪一侧、放不下怎么办、行与行隔多远,
/// 是版面不是字形,不挤在「文字」里。显示哪几行是「内容」那一组的事(`OverlayContentSettingsRows`)。
///
/// 各项**平级**,都用 `SettingsRow`,不用 `SettingsSubRow`(缩进的子行样式):子行的缩进本身就是一句话
/// ("这是上一行的子选项"),这里没有这层关系就不该用。
@MainActor
struct OverlayLayoutSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    // 浮层里:对齐方式一行(四档分段太宽,单占一行);长句处理、换句动画并排两格;三格间距一组。
    // 一行一个控件时这个浮层放不下(往上弹,按钮上方只有约 236pt)。
    var body: some View {
        SettingsRowGroupStack {
            SettingsRowGroup { alignmentRow }
            SettingsTileGrid(columns: 2) {
                // 归在「版面」这一组:它讲的是**版面**(一句话占几行、窗口高不高),不是字长什么样。这一颗只管悬浮窗;
                // 歌词窗口迷你尺寸另有自己的一颗,灵动岛 / 菜单栏只有一行高、恒滚动,不可配。
                SettingsControlCell(
                    icon: "arrow.left.and.right.text.vertical",
                    title: L10n.t("长句处理"),
                    help: L10n.t("换行（默认）：一行显示不下时折行显示，窗口随之增高。\n滚动：每句只占一行，超出部分横向滚动；有逐字时间轴时随演唱进度滚动。")
                ) {
                    SettingsPillSegmentedControl(
                        selection: $settings.overlayLineOverflow,
                        options: OverlayLineOverflow.allCases,
                        label: OverlayLineOverflowLabel.text(for:),
                        minWidth: 40
                    )
                }
                SettingsToggleTile(
                    icon: "arrow.up.to.line",
                    title: L10n.t("换句动画"),
                    help: L10n.t("换句时，下一句从原来的位置移到当前行；关闭时直接切换"),
                    isOn: $settings.overlayLineChangeAnimation
                )
            }
            // 主行下面三行各自离上一行多远,按卡片里从上到下的顺序,三格一行。那一行在「内容」里关着时这一格不起作用,
            // 置灰。范围与默认值见 OverlayRowSpacing(04 章决策 48);拖动中只改临时值,见 OverlayRowSpacingDraft。
            SettingsTileGrid(title: L10n.t("间距"), columns: 3) {
                OverlayRowSpacingCell(item: .romanization, title: L10n.t("读音间距"))
                    .disabled(!settings.overlayShowRomanization)
                OverlayRowSpacingCell(item: .translation, title: L10n.t("译文间距"))
                    .disabled(!settings.overlayShowTranslation)
                OverlayRowSpacingCell(item: .nextLine, title: L10n.t("下一句间距"))
                    .disabled(!settings.showNextLinePreview)
            }
        }
    }

    private var alignmentRow: some View {
        // 多人声部歌词默认按演唱者自动在左/右/居中
        // 之间切换(仿 Apple Music 的 Duet View),但对贴在桌面上的固定悬浮窗来说,
        // 位置来回跳会影响阅读体验——这一项让用户强制固定到一个方向,忽略声部信息。
        // 选了非"自动"时,两侧留白也会一并关掉(不止改对齐方向)——
        // 只改对齐、留着留白跟真实声部走,文字块还是会因为留白量变化而轻微漂移,
        // 没有真正做到"始终保持在同一个位置",具体见 OverlayDuetAlignmentOverride
        // 声明处注释。只影响悬浮窗,不影响歌词窗口(issue 与原始描述都只提悬浮歌词)。
        SettingsRow(
            icon: "text.alignleft",
            title: L10n.t("对齐方式"),
            help: L10n.t("自动（默认）：按对唱声部在左 / 右 / 居中之间切换。\n其他：忽略声部，固定在同一位置。")
        ) {
            // 故意不用系统 `.pickerStyle(.segmented)`(三轮修法都没
            // 按住"选了哪个选项、控件整体宽度就跟着变"这个问题,完整排查过程见
            // docs/features/04-desktop-overlay.md 对应决策记录)。改用纯 SwiftUI 手搭的
            // OverlayAlignmentSegmentedControl——每个选项固定 minWidth,尺寸完全由自己
            // 控制,不经过任何系统分段控件的内部尺寸/动画逻辑。
            OverlayAlignmentSegmentedControl(selection: $settings.overlayDuetAlignmentOverride)
        }
    }
}

/// 「长句处理」两档的显示名。跟「对齐方式」同一个安排:枚举本体在 Core、不带界面文案,
/// 文案留在界面层(Core 不依赖 L10n)。
enum OverlayLineOverflowLabel {
    static func text(for value: OverlayLineOverflow) -> String {
        switch value {
        case .wrap: return L10n.t("换行")
        case .scroll: return L10n.t("滚动")
        }
    }
}

/// 「排版」里三项间距**拖动中**的临时值。
///
/// 拖动中只改这里:编辑台预览经 `OverlayPreviewChrome` 跟手;不写设置、不广播 AppSettings(整页设置、菜单栏面板、
/// 真悬浮窗都会被打醒)、不碰真窗口(每一格都要重新布局、改一次窗高,改读音间距还要重画主行的位图)。
/// 松手(`onEditingChanged` 收到 false)一次性提交,真窗口这时才跟上 —— 同编辑台宽度条的 `draggingWidth`。
/// 见 04 章决策 48。
@MainActor
final class OverlayRowSpacingDraft: ObservableObject {
    static let shared = OverlayRowSpacingDraft()

    /// 拖动中的三项(nil = 没在拖)。
    @Published private(set) var values: OverlayRowSpacing.Values?

    /// 拖动中改一项:以设置里那一组为底,只换这一项。
    func set(_ item: OverlayRowSpacing.Item, to value: Double) {
        var next = values ?? AppSettings.shared.overlayRowSpacing
        next[item] = value
        guard next != values else { return }
        values = next
    }

    /// 松手:把临时值写进设置(只写变了的项)再清掉。没在拖时什么都不做。
    func commit() {
        guard let draft = values else { return }
        let settings = AppSettings.shared
        // 相等守卫:`@Published` 等值赋值照样广播,didSet 还会白写一次盘。先写设置再清临时值,
        // 两者是同一个数,预览不会跳。
        if settings.overlayRomanizationSpacing != draft.romanization {
            settings.overlayRomanizationSpacing = draft.romanization
        }
        if settings.overlayTranslationSpacing != draft.translation {
            settings.overlayTranslationSpacing = draft.translation
        }
        if settings.overlayNextLineSpacing != draft.nextLine {
            settings.overlayNextLineSpacing = draft.nextLine
        }
        values = nil
    }
}

/// 「排版」里三项间距共用的滑杆 + 读数,样式同「文字」里「字号」那一行(150pt 滑杆、等宽数字读数)。
/// 拖动中只改 `OverlayRowSpacingDraft`、松手才提交,读数跟着临时值走。
@MainActor
struct OverlayRowSpacingCell: View {
    let item: OverlayRowSpacing.Item
    let title: String
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var draft = OverlayRowSpacingDraft.shared

    private var value: Double { (draft.values ?? settings.overlayRowSpacing)[item] }

    // 名字和读数一行,滑杆铺满这一格。三格排一行:一行一根滑杆时浮层放不下。
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(String(format: L10n.t("%@pt"), "\(Int(value.rounded()))"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            SteppedSlider(
                value: Binding(get: { value }, set: { draft.set(item, to: $0) }),
                in: item.range, step: 1,
                onEditingChanged: { editing in
                    if !editing { draft.commit() }
                })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        // 浮层在拖动中途被关掉时收不到松手那一下,别把临时值留在预览上。
        .onDisappear { draft.commit() }
        .settingsSearchHighlight(title: title)
    }
}

/// 「对齐方式」用的自定义分段控件(从 SettingsView 里那个
/// `private struct` 提到这里 —— 卡片和浮层都要用,再是 private 就只有卡片够得着)。
///
/// 不用系统 `.pickerStyle(.segmented)` 的原因:三轮基于系统分段控件的修法都没能按住
/// "选了哪个选项、控件整体宽度就跟着变"这个问题——①给每个选项的 `Text` 加
/// `.frame(minWidth:)`,完全没用(macOS 把这个 Picker 桥接成 `NSSegmentedControl`,
/// 它按**当前选中段的文字**自己重新量一遍宽度,不读 SwiftUI 子视图上的 `.frame`);
/// ②给 `Picker` 整体套 `.frame(minWidth: 300)`,实测(只读查询这个控件的真实渲染
/// 尺寸,不是靠肉眼)这个 300 只影响 SwiftUI 布局预留的空间,控件自己实际渲染出来的
/// 尺寸完全没被这个下限管住,该多宽还是多宽;③以为是页面切换动画截了一帧未定型的
/// 尺寸,加 `.transaction { $0.disablesAnimations = true }`,同样没用。三轮都是在
/// SwiftUI 这一层加修饰符,而问题出在 AppKit 原生分段控件自己的尺寸计算逻辑里,这一层
/// 管不到那一层。完整排查记录见 docs/features/04-desktop-overlay.md。
///
/// 改成纯 SwiftUI 手搭:每个选项是一个套了固定 `minWidth` 的 `Button`,选中的那个
/// 手动垫一层高亮背景——全程不经过任何系统分段控件,尺寸永远只取决于这里写的数字,
/// 不会再因为"选中了哪一段"而变。`minWidth` 统一给 56(比最长的"左对齐/右对齐"三字
/// 稍留余量,四个选项因此固定宽度、不是各自贴着自己的文字收缩),控件总宽从此恒定。
@MainActor
struct OverlayAlignmentSegmentedControl: View {
    @Binding var selection: OverlayDuetAlignmentOverride

    /// 四个选项的显示名。
    ///
    /// 从实例的 `options` 数组改成 static func:工具栏「≣ 排版…」按钮上的摘要
    /// 要报当前选中的是哪一个(见 `OverlayStyleSummary.layout`),而那个位置构造不出这个
    /// View。两处必须同一份口径 —— 控件里写着「左对齐」、摘要里写成「左」,是同一个值的
    /// 两种叫法。
    ///
    /// 不能存成 `static let`:`L10n.t` 要在每次取值时现算,存进 static let 等于把首次
    /// 访问时的语言冻在里面(切了语言之后这四个标签不跟着变)。
    static func label(for option: OverlayDuetAlignmentOverride) -> String {
        switch option {
        case .automatic: return L10n.t("自动")
        case .center: return L10n.t("居中")
        case .leading: return L10n.t("左对齐")
        case .trailing: return L10n.t("右对齐")
        }
    }

    var body: some View {
        // 顺序直接用 allCases(声明序:自动/居中/左/右),不另抄一份数组 —— 抄一份的话
        // 以后往枚举里加一个方向,这里不加就是"设置里选不到的合法值"。
        SettingsPillSegmentedControl(
            selection: $selection,
            options: OverlayDuetAlignmentOverride.allCases,
            label: Self.label(for:),
            minWidth: 56)
    }
}

// MARK: - 主题

/// 「主题」那一组:内置预设和「我的配色主题」都画成预览卡(`ThemePreviewCard`),点一下套用。
///
/// 当前生效的那张描强调色边框,判据是配色字段完全相等(`ColorTheme.hasSameColors`,含两处「跟随封面」
/// 开关;跟随时不比那个备用色)。套用会按主题自己的值写两处跟随封面(`ColorTheme.apply(to:)`)。
/// 悬浮窗右键的「配色主题」子菜单(`OverlayQuickSettingsMenu.colorThemeMenu`)是同一张清单、同一条判据。
///
/// 自存主题的改名 / 用当前配色覆盖 / 删除挂在卡片的右键菜单上。命名、改名与删除确认都摆在
/// 「我的配色主题」那行标题的右侧,不另起一行:编辑台里这组视图是从舞台上沿往上弹的浮层,高度封顶在
/// 舞台上方的剩余空间里,多长一行就得滚动才看得见。也不用 `.alert`:宿主之一是 transient 的
/// `NSPopover`,alert 以 sheet 挂在窗口上,点进去时承载状态的视图树可能已随浮层销毁。空名禁用「保存」
/// 而不是静默丢弃;删除必须二次确认(`customColorThemes` 的 didSet 立刻落盘、没有撤销)。
@MainActor
struct OverlayThemeSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    private enum Editing: Equatable {
        case none
        case naming
        case renaming(ColorTheme.ID)
        case confirmingDeletion(ColorTheme.ID)
    }

    @State private var editing: Editing = .none
    @Environment(\.settingsInPopover) private var inPopover
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let current = ColorTheme.current(settings)
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: ThemeGalleryMetrics.columns, spacing: ThemeGalleryMetrics.rowSpacing) {
                ForEach(ColorTheme.builtInPresets) { theme in
                    ThemePreviewCard(theme: theme, isCurrent: theme.hasSameColors(as: current)) {
                        theme.applyKeepingUnsaved(to: settings)
                    }
                }
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, 12)
            // 浮层里没存过主题、也没有待存 / 可恢复的配色时整段不画:只剩一句提示,往上弹的浮层放不下。抽屉里照旧显示。
            if !(inPopover && customSectionIsEmpty(current: current)) {
                CardDivider()
                customSection(current: current)
            }
        }
        .animation(.default, value: editing)
        .animation(.default, value: settings.customColorThemes)
    }

    /// 「我的配色主题」那一段只剩空状态提示:当前配色对得上某套、没有可恢复的那套、也没存过主题(判据同 customSection)。
    private func customSectionIsEmpty(current: ColorTheme) -> Bool {
        guard UnsavedColorThemeSnapshot.isKnown(current, settings: settings) else { return false }
        let restorable = UnsavedColorThemeSnapshot.load().flatMap {
            UnsavedColorThemeSnapshot.isKnown($0, settings: settings) ? nil : $0
        }
        return restorable == nil && settings.customColorThemes.isEmpty
    }

    @ViewBuilder
    private func customSection(current: ColorTheme) -> some View {
        // 当前配色跟哪套都对不上 = 用户调过、还没存:排第一张「自定义」卡,用当前配色画、描选中框、
        // 右上角一个存储标记,点一下长出命名行。对得上时它不出现 —— 那时存下来只是某套主题的复本。
        let isUnsaved = !UnsavedColorThemeSnapshot.isKnown(current, settings: settings)
        // 套用主题之前手调、没存过的那套(见 ColorTheme.applyKeepingUnsaved)。当前配色本身就是没存过的
        // 那套时不再另外摆:上面那张「自定义」卡已经是它。
        let restorable: ColorTheme? = isUnsaved ? nil : UnsavedColorThemeSnapshot.load().flatMap {
            UnsavedColorThemeSnapshot.isKnown($0, settings: settings) ? nil : $0
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.t("我的配色主题"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 12)
                editorControls
            }
            .frame(minHeight: 22)
            if isUnsaved || restorable != nil || !settings.customColorThemes.isEmpty {
                LazyVGrid(columns: ThemeGalleryMetrics.columns, spacing: ThemeGalleryMetrics.rowSpacing) {
                    if isUnsaved {
                        ThemePreviewCard(
                            theme: ColorTheme.current(settings, name: L10n.t("自定义")), isCurrent: true,
                            badge: "square.and.arrow.down", help: L10n.t("当前配色尚未保存，点按保存为主题")
                        ) {
                            draftName = ""
                            editing = .naming
                        }
                    }
                    if let restorable {
                        ThemePreviewCard(
                            theme: { var t = restorable; t.name = L10n.t("之前的自定义"); return t }(), isCurrent: false,
                            badge: "arrow.uturn.backward", help: L10n.t("应用主题前手动调整的配色，点按即可恢复")
                        ) {
                            restorable.apply(to: settings)
                        }
                    }
                    ForEach(settings.customColorThemes) { theme in
                        ThemePreviewCard(theme: theme, isCurrent: theme.hasSameColors(as: current)) {
                            theme.applyKeepingUnsaved(to: settings)
                        }
                        .contextMenu { customThemeMenu(theme) }
                    }
                }
            } else {
                Text(L10n.t("调整颜色后，此处将出现「自定义」，点按即可保存为主题"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if !settings.customColorThemes.isEmpty {
                Text(L10n.t("右键点按主题可重命名、用当前配色覆盖或删除"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func customThemeMenu(_ theme: ColorTheme) -> some View {
        Button(L10n.t("重命名…")) {
            draftName = theme.name
            editing = .renaming(theme.id)
        }
        Button(L10n.t("用当前配色覆盖")) { overwrite(theme.id) }
        Divider()
        Button(L10n.t("删除"), role: .destructive) { editing = .confirmingDeletion(theme.id) }
    }

    /// 标题行右侧的编辑控件:命名 / 改名是输入框 + 保存 + 取消,删除确认是一句提示 + 删除 + 取消。
    @ViewBuilder
    private var editorControls: some View {
        switch editing {
        case .none:
            EmptyView()
        case .naming:
            HStack(spacing: 8) {
                nameField(placeholder: L10n.t("为当前配色命名")) { saveNewTheme() }
                Button(L10n.t("保存")) { saveNewTheme() }
                    .disabled(trimmedName.isEmpty)
                    .fixedSize()
                Button(L10n.t("取消")) { editing = .none }
                    .fixedSize()
            }
            .settingsGlassButtons()
        case .renaming(let id):
            HStack(spacing: 8) {
                nameField(placeholder: L10n.t("主题名称")) { rename(id) }
                Button(L10n.t("保存")) { rename(id) }
                    .disabled(trimmedName.isEmpty)
                    .fixedSize()
                Button(L10n.t("取消")) { editing = .none }
                    .fixedSize()
            }
            .settingsGlassButtons()
        case .confirmingDeletion(let id):
            if let theme = settings.customColorThemes.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    Text(String(format: L10n.t("删除「%@」？删除后无法恢复"), theme.name))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L10n.t("删除"), role: .destructive) {
                        settings.customColorThemes.removeAll { $0.id == id }
                        editing = .none
                    }
                    .foregroundStyle(.red)
                    .tint(.red)
                    .fixedSize()
                    Button(L10n.t("取消")) { editing = .none }
                        .fixedSize()
                }
                .settingsGlassButtons()
            }
        }
    }

    private func nameField(placeholder: String, onSubmit: @escaping () -> Void) -> some View {
        TextField(placeholder, text: $draftName)
            .textFieldStyle(.roundedBorder)
            .frame(width: 170)
            .focused($nameFieldFocused)
            .onSubmit(onSubmit)
            .onAppear { nameFieldFocused = true }
    }

    private func saveNewTheme() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        settings.customColorThemes.append(ColorTheme.current(settings, name: name))
        editing = .none
    }

    private func rename(_ id: ColorTheme.ID) {
        let name = trimmedName
        guard !name.isEmpty, let index = settings.customColorThemes.firstIndex(where: { $0.id == id }) else { return }
        settings.customColorThemes[index].name = name
        editing = .none
    }

    private func overwrite(_ id: ColorTheme.ID) {
        guard let index = settings.customColorThemes.firstIndex(where: { $0.id == id }) else { return }
        let existing = settings.customColorThemes[index]
        var updated = ColorTheme.current(settings, name: existing.name)
        updated.id = existing.id
        settings.customColorThemes[index] = updated
    }

    /// 工具栏「主题」按钮的摘要:配色等于哪套就报哪套的名字,都不等报「自定义」。
    static var currentThemeLabel: String {
        let settings = AppSettings.shared
        let current = ColorTheme.current(settings)
        let all = ColorTheme.builtInPresets + settings.customColorThemes
        return all.first { $0.hasSameColors(as: current) }?.name ?? L10n.t("自定义")
    }
}

// MARK: - 恢复默认

/// 「恢复默认文字与配色」的动作本体。
///
/// 抽成函数而不是留在卡片的按钮闭包里:工具栏的「重置 ▾」菜单要执行**同一件事**。
/// 复制一份的话,以后新增一个外观字段时很容易只往其中一处补赋值,表现为"从菜单点恢复
/// 和从卡片点恢复,恢复出来的样子不一样"。
///
/// 名字从"恢复默认外观"收窄成"恢复默认文字与配色":它重置七个字段,却**不碰**宽度和
/// 锁定位置。两处入口的副标题都要带上"不含宽度和锁定位置",比悄悄扩大重置范围安全 ——
/// 扩大的话还得连带调 setWidth/setLocked,漏调就会变成"点了按钮但窗口纹丝不动"。
@MainActor
enum OverlayStyleDefaults {
    static func restoreTextAndColors() {
        let settings = AppSettings.shared
        // 从硬编码 false 改成读 defaultFollowsCoverArt——这颗按钮的
        // 名字就是"恢复默认",默认值现在是"跟随封面开着",硬编码 false 会让它
        // 跟"全新安装长什么样"不一致(点了"恢复默认"却恢复不出默认的样子)。
        settings.followsCoverArt = AppSettings.defaultFollowsCoverArt
        settings.fontFamilyName = AppSettings.defaultFontFamilyName
        settings.fontSize = AppSettings.defaultFontSize
        // 字重跟字体/字号同属「文字」那一组,"恢复默认文字与配色"必须把它一起带上,
        // 否则点完之后字体字号回默认、粗细还停在用户上次选的档,那不叫恢复默认。
        settings.overlayFontWeight = AppSettings.defaultOverlayFontWeight
        settings.foregroundColorHex = ColorTheme.defaultTheme.foregroundColorHex
        settings.backgroundColorHex = ColorTheme.defaultTheme.backgroundColorHex
        // 毛玻璃是背景那一组的第八个字段,"恢复默认文字与配色"一起带回默认的关。
        settings.overlayBackgroundGlass = false
        // 毛玻璃浓淡跟毛玻璃开关同组,一起恢复到默认档——不然点"恢复默认"之后
        // 毛玻璃虽然关了,浓淡却停在用户上次选的档,下次重新打开毛玻璃时又不是默认观感
        // (同上面那条注释警告的坑,新加字段不进这个函数就会被漏掉)。
        settings.overlayGlassIntensity = .default
        settings.textStrokeEnabled = ColorTheme.defaultTheme.textStrokeEnabled
        settings.textStrokeColorHex = ColorTheme.defaultTheme.textStrokeColorHex
        // 「已唱/未唱」是文字组多出来的一对独立颜色,新加字段不进这个函数,点"恢复默认"时它会被漏掉。
        // 取值跟「默认」主题一致。
        settings.karaokeUnsungFollowsCoverArt = ColorTheme.defaultTheme.karaokeUnsungFollowsCoverArt
        settings.karaokeUnsungColorHex = ColorTheme.defaultTheme.karaokeUnsungColorHex
    }
}

// MARK: - 工具栏摘要

/// 编辑台工具栏按钮上那一小截"当前值"。
///
/// 来自方案 B 的一点:把设置收进浮层之后丢掉的"全貌感",靠按钮上这一截补回来 ——
/// 不点开也知道现在是什么字体、什么配色。
///
/// 它是**纯派生值**,跟着同一份 AppSettings 走,不新增任何状态。别为了"少算一次"
/// 把它缓存成 @State:那就又多了一份要跟设置同步的真相,正是这次抽取要消灭的东西。
@MainActor
enum OverlayStyleSummary {
    /// 例:「系统字体 加粗 31pt」。字体名复用 FontFamilyPicker 的同一份显示口径 ——
    /// 空串要显示成「系统字体」这条规则只能有一处。
    ///
    /// 加了中间那截字重。**三项全报**,跟 `layout` 那条同一个理由:这个浮层里总共就
    /// 这三项,少报一项等于让人为了确认它再点开一次浮层,那这截摘要就白给了。代价是长字体名
    /// 下更容易触发截断 —— 那本来就有兜底(`EditorToolbarButtonLabel` 里 140pt 限宽 + `.layoutPriority(-1)`,
    /// 摘要先被压、标题始终完整),不为多这一截另写一套。
    static var text: String {
        let settings = AppSettings.shared
        return fontText(family: settings.fontFamilyName, weight: settings.overlayFontWeight, size: Int(settings.fontSize))
    }

    /// 上面那句的本体(抽出来,灵动岛编辑台「字体」按钮的摘要走同一份):字体名复用 `FontFamilyPicker`
    /// 的显示口径("空串 = 系统字体"只能有一处),中间是粗细的显示名,末尾字号。两个编辑台各拼一遍迟早漂开。
    static func fontText(family: String, weight: OverlayFontWeight, size: Int) -> String {
        let sizeText = String(format: L10n.t("%@pt"), "\(size)")
        return "\(FontFamilyPicker.displayName(for: family)) \(weight.displayName) \(sizeText)"
    }

    /// 例:「暗夜霓虹」/「自定义」。
    ///
    /// 从 `color` 改名成 `theme`(那个浮层拆成了「主题」「背景」两个)。
    ///
    /// 这一截来回改过四次,理由都记着 —— 每次都是"这颗按钮管的浮层里到底有没有跟随封面":
    ///  - 之前:短路成 `followsCoverArt ? "跟随封面": …`;
    ///  - 改成直接复用 `currentThemeLabel`、跟随时同样显示占位符「—」—— 当时「跟随封面」
    ///    开关在**「文字」**浮层里,按钮说"跟随封面"、浮层里的行说"—",用户要的是两边一致;
    ///  - 开关搬进了「主题」浮层,这颗按钮管的浮层里就有它,报「跟随封面」= 报这个
    ///    浮层的真实状态;
    ///  - (现在):开关又搬去了「文字」浮层,这个浮层里**没有**它了 ——
    ///    再报「跟随封面」就成了拿另一个浮层的状态当自己的摘要。回到"跟 `currentThemeLabel`
    ///    同一个字符串",而那个字符串现在也不再是占位符(理由见 `OverlayThemeSettingsRows` 头注)。
    static var theme: String { OverlayThemeSettingsRows.currentThemeLabel }

    /// 「颜色」按钮的摘要:文字色从哪来 + 背景是什么,例「跟随封面 · 透明」。
    static var color: String {
        let text = AppSettings.shared.followsCoverArt ? L10n.t("跟随封面") : L10n.t("自定义颜色")
        return "\(text) · \(background)"
    }

    /// 例:「毛玻璃」/「纯色」/「透明」。报的是**背景当前是什么材质**,不是颜色值本身 ——
    /// 一串 hex 或者 rgb 数字在按钮上没人读得出来是什么样,而"毛玻璃/纯色/透明"这三档正好
    /// 覆盖了这一组两个字段的全部有意义组合。
    ///
    /// 「透明」这一档不能省:背景色的 ColorPicker 是 `supportsOpacity: true`,把 alpha 拖到 0
    /// (歌词直接浮在桌面上、没有底板)是个常用配置,而那种状态报「纯色」是错的。
    ///
    /// 阈值**不在这里重写一遍**:直接借 `AppSettings.backgroundVisible(hex:glass:)`,`glass`
    /// 传 false 之后它正好退化成"背景色本身看得见吗"(alpha > 0.02)。那个函数已经是窗口阴影 /
    /// 拖拽捕获层 / 编辑台虚线边界三处联动共用的判据,再抄一份 0.02 就是第四个会漂的地方。
    /// (`settings.backgroundIsVisible` 那个缓存属性不能直接用 —— 它把毛玻璃也算成"可见",
    ///  而这里要的正是把两者分开。)
    static var background: String {
        let settings = AppSettings.shared
        if settings.overlayBackgroundGlass { return L10n.t("毛玻璃") }
        return AppSettings.backgroundVisible(hex: settings.backgroundColorHex, glass: false)
            ? L10n.t("纯色") : L10n.t("透明")
    }

    /// 例:「自动 · 换行」。对齐方式 / 长句处理两项都报 —— 摘要少报一项等于让人为了确认另一项再点开一次浮层,
    /// 那这截摘要就白给了。读音 / 译文 / 下一句三项间距不报:三个数字挤在按钮上读不出是哪一行的。
    ///
    /// 两截都复用控件的同一份标签(`OverlayAlignmentSegmentedControl.label(for:)` / `OverlayLineOverflowLabel`),
    /// 不在这里另写一套短名:控件里选中的是「左对齐」、摘要里却写「左」,是同一个值两种叫法。
    static var layout: String {
        let settings = AppSettings.shared
        let alignment = OverlayAlignmentSegmentedControl.label(for: settings.overlayDuetAlignmentOverride)
        return "\(alignment) · \(OverlayLineOverflowLabel.text(for: settings.overlayLineOverflow))"
    }

    /// 「内容」按钮的摘要:读音 / 译文 / 下一句开着哪几项(全开报「全部开启」、全关报「全部关闭」)。
    static var content: String {
        let settings = AppSettings.shared
        return SettingsToggleSummary.text([
            (title: L10n.t("读音"), isOn: settings.overlayShowRomanization),
            (title: L10n.t("译文"), isOn: settings.overlayShowTranslation),
            (title: L10n.t("下一句"), isOn: settings.showNextLinePreview),
        ])
    }
}

// (删掉了 `overview` —— 拼给「全部设置」抽屉折起来时的那串「系统字体 31pt ·
//  跟随封面 · 486pt」。删掉那处展示,删完这个派生属性就一个消费方都没有了,留着
//  就是一段没人调的代码。其余几截仍在用:编辑台工具栏那几颗按钮上的摘要就是它们
//  —— 是 `theme` / `text` / `background` / `layout` 四截,`color` 那一截随
//  「配色」浮层一起拆成了前面的 `theme` 和 `background`。)
