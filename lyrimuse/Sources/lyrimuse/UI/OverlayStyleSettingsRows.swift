import AppKit
import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」那几张卡里的**设置行本体**,从 SettingsView 抽出来的唯一一份实现。
//
// 为什么抽(2026-08-30,编辑台第二步):这一段现在有**两个**宿主 ——
//   ① 内容区里原有的卡片列(overlayColorCard / overlayThemesCard / overlayTextCard /
//      overlayResetCard),它是键盘/VoiceOver/"我就想找个开关"的全量兜底通路;
//   ② 编辑台(OverlayEditorStage)工具栏和画布命中区弹出的浮层。
// 两个宿主必须是**同一份**行实现。这个仓库刚为"同一个视觉属性有两条渲染路径"付过代价:
// 「对齐方式」在预览条上失效,根因就是补对齐时只改了静态文本那一条路径、逐字填色那条漏了
// (那份简化渲染 OverlayLyricsCanvas 2026-08-31 已随钉条一起删除,完整记录见
//  docs/features/04-desktop-overlay.md)。设置行比渲染更容易漂 ——
// 复制一份之后,以后每加一个条件显示、每改一句副标题,都要记得改两处;漏了不会编译报错,
// 只会变成"在浮层里改了有用、在卡片里改了没用"。所以这里一律只留一份,宿主只负责外壳
// (卡片背景 / 浮层外壳)。
//
// ⚠️ 两个宿主绑的是同一个 AppSettings.shared,所以"浮层里改"和"卡片里改"天然同步,不需要
// 任何双向绑定代码 —— 这也是不把设置值往上提成 @State 的理由:一提就多出一份要同步的真相。

// MARK: - 文字

/// 「文字」那一组:字体 / 字号。
///
/// 行与行之间的 `CardDivider()` 由这个组件自己插 —— 宿主只知道"这里放一组文字设置",
/// 不该知道它内部有几行、该在哪儿断。
///
/// (2026-08-31 起只剩这两项:「双行显示」「对齐方式」搬去了下面的 `OverlayLayoutSettingsRows`。
///  判据和用户原话记在那个组件的注释里。)
@MainActor
struct OverlayTextSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // 套一层 VStack(spacing: 0) 而不是裸 Group:卡片和浮层的外层容器本来就是
        // VStack(spacing: 0),多套一层不改变排版,但让下面那些 `.animation(value:)`
        // 有一个明确的挂载点(挂在 Group 上是**逐个子视图**生效的,条件行长出/收起
        // 这种"容器成员变了"的动画就没人负责)。
        VStack(spacing: 0) {
            SettingsRow(icon: "character", title: L10n.t("字体")) {
                // 系统装了什么就能选什么(带搜索、每行用字体自己渲染)。原来是一个只有 7 款的
                // 精选下拉,想用别的字体完全没出路,见 FontFamilyPicker 顶部注释。
                FontFamilyPicker(selection: $settings.fontFamilyName)
            }
            CardDivider()
            SettingsRow(icon: "textformat.size", title: L10n.t("字号")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { settings.fontSize },
                        set: { newValue in
                            // 相等守卫:拖动中每个鼠标事件都会调 set,step 量化后大量等值
                            // 赋值照样广播 objectWillChange,didSet 还会 recomputeFonts()
                            // 连带重赋 4 个派生字体 @Published(一写五发)——所有观察
                            // AppSettings 的界面跟着白跑(2026-08-19,同三个宽度滑杆)。
                            guard newValue != settings.fontSize else { return }
                            settings.fontSize = newValue
                        }
                    ), in: 14...36, step: 1)
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

// MARK: - 排版

/// 「排版」那一组:双行显示 / 对齐方式。
///
/// 2026-08-31 从「文字」里拆出来。用户原话:「双行显示不应该挂在这个文字里面吧,是否应该是
/// 一个独立的开关呢;还有这个对齐方式也是,不应该是子选项吧」。判据:字体、字号讲的是**字
/// 长什么样**,而「双行显示」讲的是**显示几行内容**、「对齐方式」讲的是**摆在哪一侧**,后
/// 两者是版面不是字形 —— 挤在「文字」里靠的只是"都跟文字有关"这种最粗的相关性,那条相关性
/// 把整页设置都能装进去。
///
/// ⚠️ 两项**平级**,都用 `SettingsRow`。「对齐方式」原来是缩进的 `SettingsSubRow`(视觉上
/// 从属于上面那一行),那是**假的**从属关系:对齐对单行同样生效,关掉双行显示之后它照旧起
/// 作用。子行的缩进本身就是一句话("这是上一行的子选项"),这里没有这层关系就不该说。
@MainActor
struct OverlayLayoutSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // 2026-08-29 从「歌词」页的「效果」段挪来(用户提出)。判据跟这张卡当初收编
            // 字体/配色时用的是同一条(见 SettingsView.classicOverlayCard 上方注释):全仓
            // 核对消费方,只对这一种展示方式生效的就归到这一段。这个开关的消费方只有
            // LyricsOverlayView,而它原来所在的「效果」段其余三项(卡拉OK/繁简/罗马音)
            // 全是跨形态生效的,它夹在那里是唯一的异类。
            //
            // 挪过来之后原先那句 help("这个开关只影响「桌面悬浮歌词」…")就不必留了 ——
            // 那句话当初是**位置不对的补丁**(注释原话:开着灵动岛的人打开它没反应,会以为
            // 开关坏了);现在所在分段自己说明了生效面。
            //
            // 副标题「在当前句下方多显示一句」2026-08-30 按用户要求删了:标题里的"双行"
            // 已经把"下面再显示一句"讲完了,同一句话说两遍只是把行撑高。
            //
            // 图标 2026-08-31 从 `text.aligncenter` 换成 `rectangle.grid.1x2`:那个图标画的
            // 是"居中对齐",紧挨着下面真正的「对齐方式」一行时会被读成对齐设置;两格叠起来
            // 的方块讲的才是这一行的事 —— 显示几行。
            SettingsRow(icon: "rectangle.grid.1x2", title: L10n.t("双行显示")) {
                Toggle("", isOn: $settings.showNextLinePreview)
            }
            CardDivider()
            // 2026-08-29 采纳 GitHub issue #2:多人声部歌词默认按演唱者自动在左/右/居中
            // 之间切换(仿 Apple Music 的 Duet View),但对贴在桌面上的固定悬浮窗来说,
            // 位置来回跳会影响阅读体验——这一项让用户强制固定到一个方向,忽略声部信息。
            // 选了非"自动"时,两侧留白和声部指示圆点也会一并关掉(不止改对齐方向)——
            // 只改对齐、留着留白跟真实声部走,文字块还是会因为留白量变化而轻微漂移,
            // 没有真正做到"始终保持在同一个位置",具体见 OverlayDuetAlignmentOverride
            // 声明处注释。只影响悬浮窗,不影响歌词窗口(issue 与用户原话都只提悬浮歌词)。
            SettingsRow(
                icon: "text.alignleft",
                title: L10n.t("对齐方式"),
                help: L10n.t("自动：按对唱声部标记自动在左/右/居中之间切换（默认）。\n\n居中/左对齐/右对齐：忽略声部信息，所有歌词始终固定在同一个位置。")
            ) {
                // ⚠️ 故意不用系统 `.pickerStyle(.segmented)`(2026-08-29,三轮修法都没
                // 按住"选了哪个选项、控件整体宽度就跟着变"这个问题,完整排查过程见
                // docs/features/04-desktop-overlay.md 对应决策记录)。改用纯 SwiftUI 手搭的
                // OverlayAlignmentSegmentedControl——每个选项固定 minWidth,尺寸完全由自己
                // 控制,不经过任何系统分段控件的内部尺寸/动画逻辑。
                OverlayAlignmentSegmentedControl(selection: $settings.overlayDuetAlignmentOverride)
            }
        }
    }
}

/// 「对齐方式」用的自定义分段控件(2026-08-29;2026-08-30 从 SettingsView 里那个
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
    /// 2026-08-31 从实例的 `options` 数组改成 static func:工具栏「≣ 排版…」按钮上的摘要
    /// 要报当前选中的是哪一个(见 `OverlayStyleSummary.layout`),而那个位置构造不出这个
    /// View。两处必须同一份口径 —— 控件里写着「左对齐」、摘要里写成「左」,是同一个值的
    /// 两种叫法。
    ///
    /// ⚠️ 不能存成 `static let`:`L10n.t` 要在每次取值时现算,存进 static let 等于把首次
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
        HStack(spacing: 2) {
            ForEach(OverlayDuetAlignmentOverride.allCases, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(Self.label(for: option))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(minWidth: 56)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        // ⚠️ `.fixedSize()` 是必需的,不是保险(2026-08-31 离屏渲染查出来的)。这个控件放在
        // `SettingsRow` 的尾部插槽里,那一行的 HStack 有三个可伸缩成员(标题列、Spacer、
        // 这个控件),SwiftUI 给它们**均分**剩余宽度、而不是"先按各自的理想宽度发、多的给
        // Spacer";均分的份额小于本控件理想宽度时,它就被压到自己的下限(4×minWidth)。
        // 中文标签正好等于下限(每个都短于 56pt),看不出异常;英文标签("Left-Aligned"
        // 这种)长于 56pt,于是在**行里明明还剩一大截空白**的情况下四个选项被截成
        // "Automa…"「Left-Ali…」。加上这一句之后控件按理想宽度落位,剩余宽度才轮到标题和
        // Spacer 去分。
        //
        // 代价是亏空会转嫁给左边的标题(宿主太窄时标题换行)—— 这正是要的取舍:标题换行还
        // 读得出来,选项被截成"Automa…"就没法用了。宿主的宽度按这条取舍来定,见
        // OverlayLayoutPopover。
        .fixedSize()
    }
}

// MARK: - 配色

/// 「配色」那一组:跟随封面 / 配色主题 / 文字颜色 / 背景颜色 / 文字描边 / 描边颜色。
///
/// ⚠️ 两处条件显示(`if !followsCoverArt` / `if textStrokeEnabled`)是**原样保留**的既有
/// 行为,理由写在各自那一行上面,别顺手拉平。
@MainActor
struct OverlayColorSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // 标题「跟随封面」前面本来带着「文字」二字(2026-08-26 应用户要求去掉,嫌标题
            // 太长)——图标(photo.on.rectangle.angled)+ 卡片标题「配色」已经把语境定住了,
            // 桌面悬浮歌词这边被接管的只有**文字颜色**(PlaybackCoordinator.
            // displayForegroundColor),背景色(LyricsOverlayView 的 overlayBackground)和
            // 描边色(.lyricsTextStroke)任何时候都无条件生效。
            //
            // (2026-08-17 到 2026-08-31 之间这里挂着一条⚠️:"这个开关同时也管灵动岛"。
            //  已经不成立了 —— 灵动岛整卡前景取色 2026-08-31 并进了它自己的
            //  `notchCardStyle == .coverArt`,理由见 NotchPlayback.accent 的注释。这个开关
            //  现在**只管桌面悬浮歌词**,作用范围跟这一组里其余几项一致。)
            SettingsRow(
                icon: "photo.on.rectangle.angled",
                title: L10n.t("跟随封面")
            ) {
                Toggle("", isOn: $settings.followsCoverArt)
            }
            // 只打包"配色"相关的四个字段(文字/背景/描边颜色 + 描边开关),不含字体/字号 ——
            // 那是排版,跟配色是两回事,不该被同一个"主题"捆在一起改(见 ColorTheme.swift)。
            // 「跟随封面取色」开着时连这一行也收起来:预设主题的名字("经典黑字"/"经典白字")
            // 讲的就是文字颜色,而文字颜色已经被封面主色接管,留着只会让人以为选了有用。
            // 主题里的背景色/描边色确实还生效,但那两项本来就各有独立的一行可以单独调,
            // 不会因为收起这一行而够不着。
            //
            // 「跟随封面取色」开着时,文字颜色由封面主色接管,那一行也收起来 —— 它只剩
            // "拿不到封面主色时的兜底值"这一点残余作用,为它常占一行、还要配一句解释
            // 自己为什么半失效的副标题,不如干脆不显示。
            //
            // ⚠️ 这跟"展示方式的开关不再跟配置卡联动、关着也能配"不是一回事,别照那条推翻
            // 这里:那边是**没启用**某个形态时仍要让人能预先配好它;这里是某一项**已经被
            // 另一项接管**,显示出来只会让人以为改了有用。背景色和描边色不受接管(「文字
            // 跟随封面」这个名字里的"文字"两个字就是这个意思),所以照常显示。
            if !settings.followsCoverArt {
                CardDivider()
                SettingsRow(icon: "swatchpalette", title: L10n.t("配色主题")) {
                    Menu(Self.currentThemeLabel) {
                        ForEach(ColorTheme.builtInPresets) { theme in
                            Button(theme.name) { theme.apply(to: settings) }
                        }
                        if !settings.customColorThemes.isEmpty {
                            Divider()
                            ForEach(settings.customColorThemes) { theme in
                                Button(theme.name) { theme.apply(to: settings) }
                            }
                        }
                    }
                    .fixedSize()
                }
                CardDivider()
                SettingsRow(icon: "paintbrush", title: L10n.t("文字颜色")) {
                    ColorPicker("", selection: Binding(
                        get: { settings.foregroundColor },
                        set: { settings.foregroundColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: false) // 故意关掉——文字颜色允许透明的话,容易把 alpha
                                               // 拖到 0,悬浮窗整个消失且没有任何视觉提示能定位问题
                }
            }
            CardDivider()
            SettingsRow(icon: "rectangle.fill", title: L10n.t("背景颜色")) {
                ColorPicker("", selection: Binding(
                    get: { settings.backgroundColor },
                    set: { settings.backgroundColorHex = $0.hexStringWithAlpha }
                ), supportsOpacity: true) // 背景不透明度就是这个颜色的 alpha 通道本身,
                                          // 不另加一根 opacity 滑杆
            }
            CardDivider()
            SettingsRow(icon: "pencil.and.outline", title: L10n.t("文字描边")) {
                Toggle("", isOn: $settings.textStrokeEnabled)
            }
            if settings.textStrokeEnabled {
                CardDivider()
                SettingsSubRow(title: L10n.t("描边颜色")) {
                    ColorPicker("", selection: Binding(
                        get: { settings.textStrokeColor },
                        set: { settings.textStrokeColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: true) // 描边只让选颜色(含 alpha),粗细是固定常量
                                              // (LyricsOverlayView.swift 的 OptionalTextStroke),
                                              // 不额外加调节项——参考的是 LyricsX 的做法。
                }
            }
        }
        // 条件行长出/收起时别硬跳(设计稿明确要求)。挂 value: 而不是裸 .animation() ——
        // 裸的那种会把这一组里所有变化都动画化,包括拖字号滑杆时预览的每一帧。
        .animation(.default, value: settings.followsCoverArt)
        .animation(.default, value: settings.textStrokeEnabled)
    }

    /// 当前四个配色字段正好等于哪个内置预设/自定义主题就显示它的名字,谁都不等于
    /// (比如套用之后又手动微调过某个颜色)就显示"自定义"——这是「配色主题」那个
    /// Menu 唯一的选中反馈来源。
    ///
    /// 2026-08-14 去掉了"followsCoverArt 开着就直接显示「跟随封面」"这个短路。当时那么写是
    /// 因为「跟随封面」也是这个 Menu 里的一项,不短路的话选中态会指向别处;现在它已经是一个
    /// 独立开关,这个 Menu 只负责固定配色,就该老老实实反映四个颜色字段当前等于哪一套 ——
    /// 否则开着"跟随封面"时,用户完全看不出自己的备用色到底是哪个主题。
    ///
    /// static 而不是实例计算属性:工具栏的「◐ 配色…」按钮要拿同一个字符串当摘要
    /// (见 OverlayStyleSummary),而那个位置构造不出这个 View。
    static var currentThemeLabel: String {
        let settings = AppSettings.shared
        let current = ColorTheme(
            name: "",
            foregroundColorHex: settings.foregroundColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            textStrokeEnabled: settings.textStrokeEnabled,
            textStrokeColorHex: settings.textStrokeColorHex
        )
        let all = ColorTheme.builtInPresets + settings.customColorThemes
        return all.first { $0.hasSameColors(as: current) }?.name ?? L10n.t("自定义")
    }
}

// MARK: - 我的配色主题

/// 「我的配色主题」那一组:存为新主题 + 已存主题的套用/删除。
///
/// 设计稿把它放进配色浮层的底部(而不是像现状那样单独一张卡):它和配色强绑定,套用后
/// 预览立刻变色,跟「跟随封面 / 背景颜色 / 描边」待在同一个浮层里更连贯。卡片那一份
/// 仍然在(全量兜底通路),两边是同一个这个组件。
///
/// 「我的配色主题」那两行**内联确认**(命名 / 删除确认)专用的行容器。
///
/// ⚠️ 这两行刻意**不用** `SettingsSubRow`,这是 2026-08-30 修一个真 bug 换来的结论。
/// `SettingsSubRow` 是"左边一句说明、右边一组控件"的单行结构,说明和控件在同一个 HStack 里
/// 分同一份宽度;而这两行的控件特别宽(命名行是 130pt 输入框 + 两颗按钮),配色浮层又只有
/// 380pt —— SwiftUI 把不够的宽度按弹性摊给双方,输入框那 130pt 是写死的,整份亏空于是全压在
/// 两颗按钮上,它们被挤成两个**没有文字的空圆角矩形**(用户原话"右边这两个按钮是坏了吗")。
/// 离屏渲染逐个变量排除过:跟行容器统一套的 `.labelsHidden()` 无关(它只管 Toggle/Picker
/// 那类自带 label 的控件,按钮标题照显),跟 `.buttonStyle(.glass)` 也无关,纯粹是横向挤压;
/// 只给按钮加 `.fixedSize()` 同样不行 —— 亏空会原样转嫁给说明文字,那句话被压成一列单字。
/// 所以说明单独占一行、控件另起一行,谁都不用跟谁抢宽度,浮层再窄也不会把按钮挤没。
///
/// 视觉沿用 `SettingsSubRow`:同一条 2pt 淡竖线、同样的左右内边距,标题落在主行标题那一列。
private struct OverlayInlineConfirmRow<Content: View>: View {
    var title: String?
    var message: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 2)
                .padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 6) {
                if let title, !title.isEmpty {
                    Text(title).font(.system(size: 13))
                }
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 控件自己那一行:左对齐、跟说明同一条左边界,右边留白由外层 Spacer 吃掉。
                // 这里**不**套 .labelsHidden() —— 这一行里没有 Toggle/Picker,只有按钮和
                // 一个输入框,而输入框的占位符本来就该显示出来。
                HStack(spacing: 8) { content() }
                    .settingsGlassButtons()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, SettingsRowMetrics.textLeadingInset - 12)
        .padding(.trailing, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}

/// ⚠️ 命名和删除确认都是**内联**的,不再用 `.alert`(2026-08-30 改)。理由:这个组件现在
/// 有两个宿主,其中一个是 `.popover`。SwiftUI 在 macOS 上把 `.alert` 呈现成挂在窗口上的
/// sheet,而 NSPopover 是 transient 语义(点到浮层外面就关) —— 用户去点 sheet 里的输入框
/// 时,承载 alert 状态的那棵视图树很可能已经随浮层一起销毁了。内联做法两个宿主一模一样,
/// 不依赖任何"浮层还活着"的假设,也就不用为两个宿主各写一套呈现方式(那正是这次抽取要
/// 消灭的东西)。
/// 两条原有的安全约束一条没松:
///   - 空名不静默丢弃,而是把「保存」禁用掉(能看见的拒绝,见 2026-08-14 那次改动);
///   - 删除必须二次确认(customColorThemes 的 didSet 立刻落盘、没有撤销,而"套用"和
///     "删除"两颗按钮挨着,点错一次用户自己调了半天的配色就没了)。
@MainActor
struct OverlayCustomThemeRows: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var isNaming = false
    @State private var newThemeName = ""
    /// 待确认删除的主题 id。存 id 而不是整个 ColorTheme:它只用来做相等比较和喂
    /// `.animation(value:)`,存值对象等于把一份可能已经被删掉的快照留在状态里。
    @State private var pendingDeletion: ColorTheme.ID?

    private var trimmedName: String {
        newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "square.stack", title: L10n.t("我的配色主题")) {
                Button(L10n.t("存为新主题…")) {
                    newThemeName = ""
                    // 两个内联态互斥:正在确认删除时又点"存为新主题",两行同时展开会让人
                    // 分不清哪个按钮属于哪件事。
                    pendingDeletion = nil
                    isNaming = true
                }
            }
            if isNaming {
                CardDivider()
                OverlayInlineConfirmRow(
                    message: L10n.t("会把当前的文字颜色、背景颜色、描边颜色存成一个可以随时再套用的主题")
                ) {
                    TextField(L10n.t("主题名称"), text: $newThemeName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        // 敲回车等于点「保存」—— 输完名字还要去够鼠标是多余的一步。
                        .onSubmit { saveTheme() }
                    Button(L10n.t("保存")) { saveTheme() }
                        .disabled(trimmedName.isEmpty)
                    Button(L10n.t("取消")) { isNaming = false }
                }
            }
            ForEach(settings.customColorThemes) { theme in
                CardDivider()
                if pendingDeletion == theme.id {
                    // 跟命名行同一个容器,同一个理由:主题名是用户数据、长度不设上限,留在
                    // SettingsSubRow 的尾部插槽里迟早会把「删除」「取消」挤成两个空按钮。
                    OverlayInlineConfirmRow(
                        title: theme.name,
                        message: String(format: L10n.t("「%@」删除后无法恢复"), theme.name)
                    ) {
                        // 红色是显式染的:`role: .destructive` 在 macOS 上只对菜单项和
                        // 弹窗按钮生效,普通按钮里它只是语义标记、外观跟普通按钮一样
                        // (同 SettingsDesignSystem.DestructiveButton 的注释)。
                        Button(L10n.t("删除"), role: .destructive) {
                            settings.customColorThemes.removeAll { $0.id == theme.id }
                            pendingDeletion = nil
                        }
                        .foregroundStyle(.red)
                        .tint(.red)
                        Button(L10n.t("取消")) { pendingDeletion = nil }
                    }
                } else {
                    SettingsSubRow(title: theme.name) {
                        HStack(spacing: 10) {
                            Button(L10n.t("套用")) { theme.apply(to: settings) }
                            Button {
                                isNaming = false
                                pendingDeletion = theme.id
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .animation(.default, value: isNaming)
        .animation(.default, value: pendingDeletion)
    }

    private func saveTheme() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        settings.customColorThemes.append(ColorTheme(
            name: name,
            foregroundColorHex: settings.foregroundColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            textStrokeEnabled: settings.textStrokeEnabled,
            textStrokeColorHex: settings.textStrokeColorHex
        ))
        newThemeName = ""
        isNaming = false
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
        // 2026-08-26 从硬编码 false 改成读 defaultFollowsCoverArt——这颗按钮的
        // 名字就是"恢复默认",默认值现在是"跟随封面开着",硬编码 false 会让它
        // 跟"全新安装长什么样"不一致(点了"恢复默认"却恢复不出默认的样子)。
        settings.followsCoverArt = AppSettings.defaultFollowsCoverArt
        settings.fontFamilyName = AppSettings.defaultFontFamilyName
        settings.fontSize = AppSettings.defaultFontSize
        settings.foregroundColorHex = ColorTheme.defaultTheme.foregroundColorHex
        settings.backgroundColorHex = ColorTheme.defaultTheme.backgroundColorHex
        settings.textStrokeEnabled = ColorTheme.defaultTheme.textStrokeEnabled
        settings.textStrokeColorHex = ColorTheme.defaultTheme.textStrokeColorHex
    }
}

// MARK: - 工具栏摘要

/// 编辑台工具栏按钮上那一小截"当前值"。
///
/// 来自方案 B 的一点:把设置收进浮层之后丢掉的"全貌感",靠按钮上这一截补回来 ——
/// 不点开也知道现在是什么字体、什么配色。
///
/// ⚠️ 它是**纯派生值**,跟着同一份 AppSettings 走,不新增任何状态。别为了"少算一次"
/// 把它缓存成 @State:那就又多了一份要跟设置同步的真相,正是这次抽取要消灭的东西。
@MainActor
enum OverlayStyleSummary {
    /// 例:「系统字体 31pt」。字体名复用 FontFamilyPicker 的同一份显示口径 ——
    /// 空串要显示成「系统字体」这条规则只能有一处。
    static var text: String {
        let settings = AppSettings.shared
        let size = String(format: L10n.t("%@pt"), "\(Int(settings.fontSize))")
        return "\(FontFamilyPicker.displayName(for: settings.fontFamilyName)) \(size)"
    }

    /// 例:「跟随封面」/「暗夜霓虹」/「自定义」。跟随封面开着时文字颜色由封面主色接管,
    /// 这时候报主题名会误导(那只是拿不到封面主色时的兜底值),所以优先报模式本身。
    static var color: String {
        AppSettings.shared.followsCoverArt
            ? L10n.t("跟随封面")
            : OverlayColorSettingsRows.currentThemeLabel
    }

    /// 例:「双行 · 自动」。两项都报 —— 排版浮层里总共就这两项,摘要少报一项等于让人为了
    /// 确认另一项再点开一次浮层,那这截摘要就白给了。
    ///
    /// 对齐那一截复用分段控件的同一份标签(`OverlayAlignmentSegmentedControl.label(for:)`),
    /// 不在这里另写一套短名:控件里选中的是「左对齐」、摘要里却写「左」,是同一个值两种叫法。
    static var layout: String {
        let settings = AppSettings.shared
        let lines = settings.showNextLinePreview ? L10n.t("双行") : L10n.t("单行")
        let alignment = OverlayAlignmentSegmentedControl.label(for: settings.overlayDuetAlignmentOverride)
        return "\(lines) · \(alignment)"
    }
}

// (2026-08-30 删掉了 `overview` —— 拼给「全部设置」抽屉折起来时的那串「系统字体 31pt ·
//  跟随封面 · 486pt」。用户要求删掉那处展示,删完这个派生属性就一个消费方都没有了,留着
//  就是一段没人调的代码。`text` / `color` 两截仍在用:编辑台工具栏「Aa 文字…」「◐ 配色…」
//  两颗按钮上的摘要就是它们。)

// MARK: - 浮层外壳

/// 「Aa 文字…」浮层。内容就是卡片里那一组,没有第二份实现。
@MainActor
struct OverlayTextPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("文字")) {
            OverlayTextSettingsRows()
        }
    }
}

/// 「◐ 配色…」浮层。配色六项 + 底部的「我的配色主题」分组 —— 后者在设计稿里就该跟配色
/// 待在一起(套用后预览立刻变色),而不是像现状那样拆成上下两张卡。
@MainActor
struct OverlayColorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("配色")) {
            OverlayColorSettingsRows()
            CardDivider()
            OverlayCustomThemeRows()
        }
    }
}

/// 「≣ 排版…」浮层。内容就是抽屉里那一组,没有第二份实现。
///
/// ⚠️ 宽度 460、不是另外两个浮层的 380,这是**量出来的**,别顺手拉平:
///   - 「对齐方式」那一行的理想宽度(离屏测 `fittingSize`)中文 377pt、英文 428pt ——
///     四选一控件本身中文 234pt / 英文 275pt,加上图标列、标题、`Spacer(minLength: 12)`
///     和左右内边距;
///   - 380pt 下中文标题「对齐方式」当场折成两行(离屏渲染确认过,不是估算);英文更差,
///     420pt 时「Alignment」折三行、440pt 折两行;
///   - 460pt 是两种语言都一行放得下、且四个选项完整可读的第一档,中文还余 83pt。
/// 上限 460 不与外壳的 `maxHeight: 460` 相干,只是碰巧同一个数。
@MainActor
struct OverlayLayoutPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("排版"), width: 460) {
            OverlayLayoutSettingsRows()
        }
    }
}
