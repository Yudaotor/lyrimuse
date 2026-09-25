import AppKit
import LyrimuseCore
import SwiftUI

// 「歌词显示 到 悬浮歌词」那几张卡里的**设置行本体**,从 SettingsView 抽出来的唯一一份实现。
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

// MARK: - 文字

/// 「文字」那一组:字体 / 粗细 / 字号 / 卡拉OK效果 / 文字颜色 / 文字描边 / 描边颜色。
///
/// 行与行之间的 `CardDivider()` 由这个组件自己插 —— 宿主只知道"这里放一组文字设置",
/// 不该知道它内部有几行、该在哪儿断。
///
/// **这一组三次增删的账**:
///   - 减:「双行显示」「对齐方式」搬去了 `OverlayLayoutSettingsRows` ——
///     字体字号讲的是**字长什么样**,那两项讲的是版面,判据记在那个组件的注释里。
///   - 增:原「配色」组里属于**文字层**的四行(跟随封面 / 文字颜色 / 文字描边 /
///     描边颜色)并了过来(「帮我把这 2 个里面的配置重新整理一下,拆分为文字以及
///     背景;分别归纳」)。拆分判据见 `OverlayBackgroundSettingsRows` 的头注。
///   - 减:「跟随封面」搬去了 `OverlayThemeSettingsRows`(整页按"不要这一个
///     那一个"重排)。它虽然只接管文字色,但它跟「配色主题」是同一个问题的两个答案——文字色从哪来:
///     封面主色,还是某一套主题;开关在这边、被它顶成「—」的主题行在那边,用户在「主题」浮层里看到
///     一个破折号却找不到原因。悬浮窗右键的「配色主题」子菜单(`OverlayQuickSettingsMenu`)现在也
///     只列主题、不放跟随封面。
/// 三次用的是同一条判据 —— 按"这个字段改的是哪一层 / 回答的是哪个问题"归组,不按"都跟文字有关"
/// 这种最粗的相关性(那条相关性把整页设置都能装进去)。
///
/// 「文字颜色」那一行**任何时候都在**:跟随封面开着时尾部不放取色器、改成一句
/// 灰字「跟随封面」—— 取色模式的开关已经不在这个浮层里,再把整行藏掉就成了"文字颜色去哪了"。
/// `if textStrokeEnabled` 那处条件显示是搬过来时**原样保留**的既有行为,理由写在那一行上面。
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
            // `.fixedSize` 不能省(已知坑第 15 条):`SettingsRow` 的 HStack 有三个
            // 可伸缩成员,SwiftUI **均分**剩余宽度而不是"先按理想宽度发",不加这一句时下拉会在
            // 行里还空着一大截的情况下被压到自己的下限、把最长的那个选项截掉。
            SettingsRow(icon: "bold", title: L10n.t("粗细")) {
                Picker("", selection: $settings.overlayFontWeight) {
                    ForEach(OverlayFontWeight.allCases, id: \.self) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }
                .labelsHidden()
                // 六个档位:分段控件在 380pt 的浮层里放不下六个中文标签(而且这一栏本来就不是
                // 高频项),下拉更合适。同 `FontFamilyPicker` 那一行的形态。
                .pickerStyle(.menu)
                .fixedSize()
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
            CardDivider()
            // 从「歌词」页的「效果」段拆过来的悬浮歌词那一份——"卡拉OK是某个展示面怎么画的
            // 问题,跟繁简 / 罗马音那些改歌词内容本身的不是一类"。判据跟 「双行显示」挪进
            // 「排版」那次同一条:只对这一种展示方式生效的就归到这一段。灵动岛 / 菜单栏各有自己那颗,歌词窗口
            // 始终逐字。
            //
            // 排在字号之后、颜色那几行之前:它讲的是"字怎么被点亮",介于字形和颜色之间,放在两组的
            // 分界上最不突兀。生效链路见 AppSettings.overlayLyricsKaraoke。
            SettingsRow(
                icon: "sparkles",
                title: L10n.t("卡拉OK效果"),
                help: L10n.t("逐字歌词，唱到哪个字亮到哪个字；没有逐字数据的歌整行高亮")
            ) {
                Toggle("", isOn: $settings.overlayLyricsKaraoke)
            }
            // ── 以下两行从原「配色」组并过来 ──
            //
            // 「跟随封面 / 自定义颜色」这两行共用的取色控件用下拉菜单(`colorModeMenu`,照抄
            // "配色主题"那颗 `Menu` 的写法,这个仓库里唯一验证过好用的下拉形态,见 themeItem
            // 上方注释)——下拉本身就是**当前模式的文字**,不依赖 Toggle 的标签渲染,选
            // "自定义颜色"才在旁边露出取色器。 别退回独立开关(切模式要跨两个浮层,体验
            // 割裂)或带文字标签的 `Toggle`(那个文字标签在 macOS 上不渲染,行里只剩一颗
            // 看不出意义的光秃秃开关)。
            //
            // 两行共用 `colorModeMenu(follows:color:supportsOpacity:)`(定义在这个 struct
            // 底部)——避免各写一遍、以后漏改一处。
            CardDivider()
            SettingsRow(icon: "paintbrush", title: L10n.t("文字颜色")) {
                colorModeMenu(
                    follows: $settings.followsCoverArt,
                    color: Binding(
                        get: { settings.foregroundColor },
                        set: { settings.foregroundColorHex = $0.hexStringWithAlpha }
                    ),
                    // 打开。之前故意关着,理由是"拖到
                    // alpha 0 悬浮窗会整个消失、没有任何视觉提示能定位问题"——但工具栏
                    // 「重置 ▾」菜单和设置页都有一颗「恢复默认文字与配色」
                    // (OverlayStyleDefaults.restoreTextAndColors),走的是菜单栏,不依赖看得见
                    // 悬浮窗本身,跟这次会话刚给「锁定态解锁提示」补的逃生路径是同一个道理:
                    // 原来的顾虑已经有退路兜底,不必为了防一个可恢复的状态阉割掉透明度这个
                    // 真实诉求。
                    supportsOpacity: true
                )
            }
            // **跟「文字颜色」是平级的一对独立颜色**,
            // 不是它的附属项——已唱色就是上面那行,这一行是未唱到那一段单独的颜色,两者各自
            // 都能"跟随封面"或"选一个具体颜色",互不牵连。
            //
            // 整行仍然只在开着「卡拉OK效果」时出现:没有卡拉OK就没有"已唱/未唱"这回事,给一个
            // 不会产生任何视觉效果的设置项没有意义。
            if settings.overlayLyricsKaraoke {
                CardDivider()
                SettingsRow(icon: "circle.lefthalf.filled", title: L10n.t("未唱到的颜色")) {
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
            CardDivider()
            SettingsRow(icon: "pencil.and.outline", title: L10n.t("文字描边")) {
                Toggle("", isOn: $settings.textStrokeEnabled)
            }
            if settings.textStrokeEnabled {
                CardDivider()
                SettingsSubRow(title: L10n.t("描边颜色")) {
                    AppColorPicker(selection: Binding(
                        get: { settings.textStrokeColor },
                        set: { settings.textStrokeColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: true) // 描边只让选颜色(含 alpha),粗细是固定常量
                                              // (LyricsOverlayView.swift 的 OptionalTextStroke),
                                              // 不额外加调节项——同类实现普遍也是这个取舍。
                }
            }
        }
        // 条件行长出/收起时别硬跳(设计稿明确要求)。挂 value: 而不是裸 .animation() ——
        // 裸的那种会把这一组里所有变化都动画化,包括拖字号滑杆时预览的每一帧。
        // (`followsCoverArt` 那条拿掉了:它在这一组里不再增删任何行,只换「文字颜色」
        //  尾部的内容,没有几何要过渡。)
        .animation(.default, value: settings.textStrokeEnabled)
        .animation(.default, value: settings.overlayLyricsKaraoke)
    }

    /// 「文字颜色」「未唱颜色」共用的取色控件:下拉菜单选"跟随封面"还是"自定义颜色",
    /// 选了自定义才在旁边露出取色器。下拉照抄这个文件里「配色主题」那颗 `Menu` 的写法
    /// (`Menu(标题) { Button(...) }`,纯文字条目、不带图标/勾选)——这是本仓唯一验证过
    /// 好用的下拉形态,`Menu` 条目里塞 `Toggle`/`Image` 会整个菜单画成空白(见 themeItem
    /// 上方那段"为什么不继续试哪一样能用")。
    ///
    /// 这里**不用** `Toggle(带文字标签, isOn:)`:macOS 上这个标签
    /// 实测不渲染,行里只剩一颗光秃秃看不出含义的开关。
    @ViewBuilder
    private func colorModeMenu(follows: Binding<Bool>, color: Binding<Color>, supportsOpacity: Bool) -> some View {
        HStack(spacing: 8) {
            Menu(follows.wrappedValue ? L10n.t("跟随封面") : L10n.t("自定义颜色")) {
                Button(L10n.t("跟随封面")) { follows.wrappedValue = true }
                Button(L10n.t("自定义颜色")) { follows.wrappedValue = false }
            }
            .fixedSize()
            if !follows.wrappedValue {
                AppColorPicker(selection: color, supportsOpacity: supportsOpacity)
            }
        }
    }
}

// MARK: - 排版

/// 「排版」那一组:双行显示 / 对齐方式。
///
/// 从「文字」里拆出来。「双行显示不应该挂在这个文字里面吧,是否应该是
/// 一个独立的开关呢;还有这个对齐方式也是,不应该是子选项吧」。判据:字体、字号讲的是**字
/// 长什么样**,而「双行显示」讲的是**显示几行内容**、「对齐方式」讲的是**摆在哪一侧**,后
/// 两者是版面不是字形 —— 挤在「文字」里靠的只是"都跟文字有关"这种最粗的相关性,那条相关性
/// 把整页设置都能装进去。
///
/// 两项**平级**,都用 `SettingsRow`,不用 `SettingsSubRow`(缩进的子行样式)——对齐
/// 对单行同样生效,关掉双行显示之后它照旧起作用,不是双行显示的从属选项。子行的缩进本身
/// 就是一句话("这是上一行的子选项"),这里没有这层关系就不该用。
@MainActor
struct OverlayLayoutSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // 归在这张卡而不是「歌词」页的「效果」段。判据跟这张卡收编
            // 字体/配色时用的是同一条(见 SettingsView.classicOverlayCard 上方注释):全仓
            // 核对消费方,只对这一种展示方式生效的就归到这一段。这个开关的消费方只有
            // LyricsOverlayView,而它原来所在的「效果」段其余三项(卡拉OK/繁简/罗马音)
            // 全是跨形态生效的,它夹在那里是唯一的异类。
            //
            // 挪过来之后原先那句 help("这个开关只影响「桌面悬浮歌词」…")就不必留了 ——
            // 那句话当初是**位置不对的补丁**(注释原话:开着灵动岛的人打开它没反应,会以为
            // 开关坏了);现在所在分段自己说明了生效面。
            //
            // 副标题「在当前句下方多显示一句」按删了:标题里的"双行"
            // 已经把"下面再显示一句"讲完了,同一句话说两遍只是把行撑高。
            //
            // 图标从 `text.aligncenter` 换成 `rectangle.grid.1x2`:那个图标画的
            // 是"居中对齐",紧挨着下面真正的「对齐方式」一行时会被读成对齐设置;两格叠起来
            // 的方块讲的才是这一行的事 —— 显示几行。
            SettingsRow(icon: "rectangle.grid.1x2", title: L10n.t("双行显示")) {
                Toggle("", isOn: $settings.showNextLinePreview)
            }
            CardDivider()
            // 多人声部歌词默认按演唱者自动在左/右/居中
            // 之间切换(仿 Apple Music 的 Duet View),但对贴在桌面上的固定悬浮窗来说,
            // 位置来回跳会影响阅读体验——这一项让用户强制固定到一个方向,忽略声部信息。
            // 选了非"自动"时,两侧留白和声部指示圆点也会一并关掉(不止改对齐方向)——
            // 只改对齐、留着留白跟真实声部走,文字块还是会因为留白量变化而轻微漂移,
            // 没有真正做到"始终保持在同一个位置",具体见 OverlayDuetAlignmentOverride
            // 声明处注释。只影响悬浮窗,不影响歌词窗口(issue 与原始描述都只提悬浮歌词)。
            SettingsRow(
                icon: "text.alignleft",
                title: L10n.t("对齐方式"),
                help: L10n.t("自动（默认）：按对唱声部在左 / 右 / 居中间切换。\n其余：忽略声部，固定在一个位置。")
            ) {
                // 故意不用系统 `.pickerStyle(.segmented)`(三轮修法都没
                // 按住"选了哪个选项、控件整体宽度就跟着变"这个问题,完整排查过程见
                // docs/features/04-desktop-overlay.md 对应决策记录)。改用纯 SwiftUI 手搭的
                // OverlayAlignmentSegmentedControl——每个选项固定 minWidth,尺寸完全由自己
                // 控制,不经过任何系统分段控件的内部尺寸/动画逻辑。
                OverlayAlignmentSegmentedControl(selection: $settings.overlayDuetAlignmentOverride)
            }
            CardDivider()
            // 归在「版面」这一组,判据同上面两行:它讲的是**版面**(一句话占几行、窗口高不高),
            // 不是字长什么样。这一颗只管悬浮窗;歌词窗口迷你尺寸另有自己的一颗,灵动岛 / 菜单栏
            // 只有一行高、恒滚动,不可配。
            SettingsRow(
                icon: "arrow.left.and.right.text.vertical",
                title: L10n.t("长句处理"),
                help: L10n.t("换行（默认）：一行放不下就折到下一行，窗口跟着变高。\n滚动：每行只占一行高，放不下的横向滚动；这一句有逐字时间轴时跟着唱到哪滚到哪。")
            ) {
                SettingsSegmentedControl(
                    selection: $settings.overlayLineOverflow,
                    options: OverlayLineOverflow.allCases,
                    label: OverlayLineOverflowLabel.text(for:)
                )
            }
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
        // `.fixedSize` 是必需的,不是保险(离屏渲染查出来的)。这个控件放在
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

// MARK: - 背景

/// 「背景」那一组:背景颜色 / 毛玻璃背景。
///
/// 从原来的「配色」组里拆出来(「帮我把这 2 个里面的配置重新整理一下,
/// 拆分为文字以及背景;分别归纳」)。原「配色」组一次装着 跟随封面 / 配色主题 / 文字颜色 /
/// 背景颜色 / 毛玻璃背景 / 文字描边 / 描边颜色 七行 —— "都是颜色"是它们唯一的共性,而那条
/// 共性太粗:改文字色和改背景色是两件互不相干的事,挤在一个入口里要先在七行里找。
///
/// 拆分判据是**这个字段改的是哪一层**:
///   - 文字层(字形 + 字色 + 描边)到 `OverlayTextSettingsRows`
///   - 背景层(底色 + 底的材质)到 本组
///   - 一键套一整套配色 到 `OverlayThemeSettingsRows`(它同时改两层,所以哪一边都不属于)
/// 「跟随封面」归了文字(它接管的只有文字颜色),又归了主题 —— 它跟「配色主题」
/// 回答的是同一个问题(文字色从哪来),见 `OverlayThemeSettingsRows` 头注。
@MainActor
struct OverlayBackgroundSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "rectangle.fill", title: L10n.t("背景颜色")) {
                AppColorPicker(selection: Binding(
                    get: { settings.backgroundColor },
                    set: { settings.backgroundColorHex = $0.hexStringWithAlpha }
                ), supportsOpacity: true) // 背景不透明度就是这个颜色的 alpha 通道本身,
                                          // 不另加一根 opacity 滑杆
            }
            // 毛玻璃:作为「背景颜色」的从属项——它改变的是背景颜色的**含义**
            // (从"卡片本色"变成"玻璃上的着色"),不是一个独立维度,所以缩进挂在背景颜色下面。
            // 默认关,关着时透明/纯色两种既有用法逐像素不变。
            CardDivider()
            // (删掉这一行的副标题「开启后背景颜色作为玻璃的着色」。
            //  上面那段注释已经把"它改变的是背景颜色的含义"这层关系交代清楚了,那是给读代码
            //  的人看的;界面上缩进本身就是一句话——这一行是上一行的从属项。L10n 键跟着一起
            //  从 catalog 里删了,全仓再无引用。)
            SettingsSubRow(title: L10n.t("毛玻璃背景")) {
                Toggle("", isOn: $settings.overlayBackgroundGlass)
            }
            // 毛玻璃「浓淡」。只在毛玻璃开着时才有意义——
            // 关着时背景要么纯色要么全透明,没有"材质浓淡"这回事。SwiftUI 的 Material 做不成
            // 连续滑杆(见 OverlayGlassIntensity 声明处注释),这里开的是 Material 全部五档,
            // 复用「文字」组「粗细」那一行验证过的同一种下拉写法。
            if settings.overlayBackgroundGlass {
                CardDivider()
                SettingsSubRow(title: L10n.t("玻璃浓淡")) {
                    Picker("", selection: $settings.overlayGlassIntensity) {
                        ForEach(OverlayGlassIntensity.allCases, id: \.self) { intensity in
                            Text(intensity.displayName).tag(intensity)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        }
        // 条件行长出/收起时别硬跳,同「文字」组那一句同一个理由(见 OverlayTextSettingsRows)。
        .animation(.default, value: settings.overlayBackgroundGlass)
    }
}

// MARK: - 主题

/// 「主题」那一组:配色主题 / 我的配色主题。
///
/// 单独立成第三个入口。它本来跟文字色、背景色挤在「配色」里,而按"改的是哪一层"
/// 这条判据它**两层都改** —— 塞进「文字」或「背景」任何一边都是错的分类。
///
/// 下面这段是「跟随封面」曾经住在这一组时的记录 —— **它又搬回「文字」浮层**、
/// 内联成「文字颜色」那一行的一个取值(跟随封面 / 自定义颜色),这一组从此只剩选配色主题
/// 这一件事。留着这段是因为那次改动(见下面第二条 提醒)正是冲着它的前提去的。
///
/// **「跟随封面」从「文字」搬到这一组的第一行**(整页按"不要这一个那一个"
/// 重排)。09-02 把它归「文字」的理由是"它接管的只有文字色";但从用户这一侧看,它跟「配色主题」
/// 是**同一个问题的两个答案**——文字色从哪来:封面主色,还是某一套主题。两个答案拆在两个浮层里,
/// 结果是「主题」浮层顶着一个「—」、原因却在别处;右键快捷菜单那份子菜单后来也去掉了
/// 跟随封面,只列主题(`OverlayQuickSettingsMenu.colorThemeMenu`)。09-02 那条"别搬"的警告因此撤销;「文字」组那边「文字颜色」一行改成常显、
/// 跟随时尾部写「跟随封面」指回这里。工具栏「主题」按钮的摘要也随之在跟随时报「跟随封面」
/// (见 `OverlayStyleSummary.theme`)—— 现在那颗按钮管的浮层里就有这个开关,报它就是报真实状态。
///
/// **「配色主题」那一行任何时候都显示,不再被「跟随封面」收起**(
/// 「勾选了跟随封面之后依然可以选择主题,但是你去选了主题之后跟随封面就自动取消勾选」)。
///
/// 在此之前它的显隐条件是 `!followsCoverArt`,理由是"文字颜色被封面主色接管时,留着它只会
/// 让人以为选了有用"。**那条理由现在不成立**:`ColorTheme.apply(to:)` 第一行就是
/// `settings.followsCoverArt = false` —— 选一个主题**本来就会**把跟随封面关掉、四个颜色
/// 字段当场生效。所以它不是"选了没用",而是"选了就切过去",藏起来反而把一步的操作变成两步
/// (先去「文字」浮层关掉跟随封面,再回这一组选)。
///
/// **跟随封面开着时这一行照常报主题名/「自定义」,不再报占位符「—」**。
///
/// 占位符是加的(「当我跟随封面开着的时候,主题这边摘要和详情都指向一个
/// 占位符」),成立的前提是「跟随封面」跟「配色主题」同处这一组、是同一个问题的两个答案 ——
/// 一个模式占着,另一个就没在生效。**那个前提就没了**:跟随封面搬进「文字」浮层、
/// 变成「文字颜色」那一行的一个取值,跟主题解耦:「跟随封面和主题不挂钩了,
/// 也就是可以被列为自定义,并且可以被正常保存」。
///
/// 占位符留着有两个实际坏处:① 这一组现在只剩"选一套配色"这件事,而那一格「—」的原因在
/// **另一个浮层**里,站在这里看不出来;② 跟随封面开着时点「存为新主题…」,主题确实存下来了、
/// 这一格却仍是「—」,看起来像没存进去 —— 表现就是这个。
///
/// 悬浮窗右键的「配色主题」子菜单(`OverlayQuickSettingsMenu.colorThemeMenu`)跟这里同一张清单、
/// 同一条判据:没有跟随封面这一项,当前配色等于哪套就是哪套。
///
@MainActor
struct OverlayThemeSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // 「跟随封面」(文字颜色/未唱颜色各一颗)从这里挪进了「文字」浮层、
            // 内联在各自的颜色行里——独立开关切模式要跨两个浮层,体验割裂。这张
            // 卡现在只剩"选一套配色主题预设"这一件事,见 OverlayTextSettingsRows 里那两行的
            // 头注——「配色主题」选中某个预设时仍然会调 ColorTheme.apply(to:) 把 followsCoverArt
            // 关掉(互斥逻辑没变,只是操作它的开关搬了地方)。
            //
            // 只打包"配色"相关的四个字段(文字/背景/描边颜色 + 描边开关),不含字体/字号 ——
            // 那是排版,跟配色是两回事,不该被同一个"主题"捆在一起改(见 ColorTheme.swift)。
            SettingsRow(icon: "swatchpalette", title: L10n.t("配色主题")) {
                Menu(Self.currentThemeLabel) {
                    ForEach(ColorTheme.builtInPresets) { theme in
                        themeItem(theme)
                    }
                    if !settings.customColorThemes.isEmpty {
                        Divider()
                        ForEach(settings.customColorThemes) { theme in
                            themeItem(theme)
                        }
                    }
                }
                .fixedSize()
            }
            CardDivider()
            OverlayCustomThemeRows()
        }
    }

    /// 下拉里的一项。**只有名字,没有色条也没有勾**。
    ///
    /// **别再往这个 `Menu` 的条目里塞 `Toggle` 或 `Image`**——会让菜单面板正常弹出、
    /// 尺寸正常,但**一个条目都画不出来**(连文字都没有,不是只丢图标),例如:
    ///
    /// ```swift
    /// Toggle(isOn: Binding(get: …, set: …)) {
    ///     Label { Text(theme.name) } icon: { Image(nsImage: theme.swatchImage()) }
    /// }
    /// ```
    ///
    /// 本仓所有正常工作的 SwiftUI `Menu` 条目都是纯 `Button(标题)`;SwiftUI 的 `Menu` 也不产生
    /// 可离屏检查的 `NSPopUpButton`(`NSMenu` 要点开那一刻才建),改错了只能真人点开才发现。
    /// 真要显示色条 + 勾,走 AppKit:`OverlayQuickSettingsMenu.colorThemeMenu` 已经证明
    /// `NSMenu` + `NSMenuItem.image` + `.state` 这条路在本仓是通的。
    ///
    /// 色条本身(`ThemeSwatch` / `ColorTheme.swatchImage()`)**保留**:它在「我的配色主题」那些
    /// **子行**里是普通 SwiftUI 视图、渲染正常,不受这条限制影响。
    private func themeItem(_ theme: ColorTheme) -> some View {
        Button(theme.name) { theme.apply(to: settings) }
    }

    /// 当前四个配色字段打包成一个匿名主题,给 hasSameColors 当比较对象(下拉的勾与 currentThemeLabel 共用)。
    static func currentColors(_ settings: AppSettings) -> ColorTheme {
        ColorTheme(
            name: "",
            foregroundColorHex: settings.foregroundColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            textStrokeEnabled: settings.textStrokeEnabled,
            textStrokeColorHex: settings.textStrokeColorHex
        )
    }

    /// 当前四个配色字段正好等于哪个内置预设/自定义主题就显示它的名字,谁都不等于
    /// (比如套用之后又手动微调过某个颜色)就显示"自定义"——这是「配色主题」那个
    /// Menu 唯一的选中反馈来源。
    ///
    /// **跟随封面开着时也照常算**。这一档来回改过三次,理由都记下来:
    ///  - **去掉**过"followsCoverArt 开着就直接显示「跟随封面」"这个短路,理由是
    ///    "否则开着跟随封面时,用户完全看不出自己的备用色到底是哪个主题"。
    ///  - **换一种形式加回来**:不是显示「跟随封面」(那是模式名、不是主题),而是
    ///    显示占位符 —— 当时跟随封面就在这一组里,那一刻确实没有主题在生效。
    ///  - **连占位符一起去掉**,回到 08-14 那一档。跟随封面变成
    ///    「文字颜色」那一行的取值之后,它跟"哪套配色在生效"不再是同一个问题(理由见本类型头注)。
    ///    这四个字段任何时候都真实存在,"它们等于哪套主题"这句话永远成立;答不上来的时候
    ///    有「自定义」兜着,不需要第三种状态。
    ///
    /// static 而不是实例计算属性:工具栏的「主题」按钮要拿同一个字符串当摘要
    /// (见 OverlayStyleSummary.theme),而那个位置构造不出这个 View。
    static var currentThemeLabel: String {
        let settings = AppSettings.shared
        let current = currentColors(settings)
        let all = ColorTheme.builtInPresets + settings.customColorThemes
        return all.first { $0.hasSameColors(as: current) }?.name ?? L10n.t("自定义")
    }
}

// MARK: - 我的配色主题

/// 「我的配色主题」那一组:存为新主题 + 已存主题的套用/删除。
///
/// 设计稿把它放进配色浮层的底部(而不是像现状那样单独一张卡):它和配色强绑定,套用后
/// 预览立刻变色,跟「跟随封面 / 配色主题」待在同一个浮层里更连贯。抽屉那一份
/// 仍然在(全量兜底通路),两边是同一个这个组件。
///
/// 「我的配色主题」那两行**内联确认**(命名 / 删除确认)专用的行容器。
///
/// 这两行刻意**不用** `SettingsSubRow`,这是修一个真 bug 换来的结论。
/// `SettingsSubRow` 是"左边一句说明、右边一组控件"的单行结构,说明和控件在同一个 HStack 里
/// 分同一份宽度;而这两行的控件特别宽(命名行是 130pt 输入框 + 两颗按钮),配色浮层又只有
/// 380pt —— SwiftUI 把不够的宽度按弹性摊给双方,输入框那 130pt 是写死的,整份亏空于是全压在
/// 两颗按钮上,它们被挤成两个**没有文字的空圆角矩形**("右边这两个按钮是坏了吗")。
/// 离屏渲染逐个变量排除过:跟行容器统一套的 `.labelsHidden()` 无关(它只管 Toggle/Picker
/// 那类自带 label 的控件,按钮标题照显),跟 `.buttonStyle(.glass)` 也无关,纯粹是横向挤压;
/// 只给按钮加 `.fixedSize()` 同样不行 —— 亏空会原样转嫁给说明文字,那句话被压成一列单字。
/// 所以说明单独占一行、控件另起一行,谁都不用跟谁抢宽度,浮层再窄也不会把按钮挤没。
///
/// 视觉沿用 `SettingsSubRow`:同样的左右内边距,标题落在主行标题那一列。
/// (两边都不再画那条 2pt 淡竖线,理由见 `SettingsSubRow` 的头注 —— 改的时候
///  **两处要一起改**,否则配色浮层里的命名/删除确认行会是全 App 唯一还带着竖线的行。)
private struct OverlayInlineConfirmRow<Content: View>: View {
    var title: String?
    var message: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
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
        // 跟 `SettingsSubRow` 同一个值,理由见那边:那 12 是竖线 + 间距的补偿,线删了就还回来。
        .padding(.leading, SettingsRowMetrics.textLeadingInset)
        .padding(.trailing, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}

/// 命名和删除确认都是**内联**的,不再用 `.alert`。理由:这个组件现在
/// 有两个宿主,其中一个是 `.popover`。SwiftUI 在 macOS 上把 `.alert` 呈现成挂在窗口上的
/// sheet,而 NSPopover 是 transient 语义(点到浮层外面就关) —— 用户去点 sheet 里的输入框
/// 时,承载 alert 状态的那棵视图树很可能已经随浮层一起销毁了。内联做法两个宿主一模一样,
/// 不依赖任何"浮层还活着"的假设,也就不用为两个宿主各写一套呈现方式(那正是这次抽取要
/// 消灭的东西)。
/// 两条原有的安全约束一条没松:
///   - 空名不静默丢弃,而是把「保存」禁用掉(能看见的拒绝,见那次改动);
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
                Button(L10n.t("存为新配色主题…")) {
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
                            // 自定义主题只有名字可认,色条是唯一的视觉线索。放在「套用」
                            // 左边而不是行首:SettingsSubRow 刻意不占图标列(见它的注释)。
                            Image(nsImage: theme.swatchImage())
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
        // 「已唱/未唱」是文字组多出来的一对独立颜色(跟 foregroundColorHex/
        // followsCoverArt 同一个形状),同一条头注警告过的坑——新加字段不进这个函数,点
        // "恢复默认"时它会被漏掉。它不在 ColorTheme 里(见该属性头注),没有 defaultTheme
        // 可读:颜色沿用 AppSettings.init() 里没存过时同一条派生(默认主题文字色调暗),
        // 「跟随封面」**刻意**恢复成 false 而不是跟 followsCoverArt 一样的 true——两个都
        // 跟随的话已唱/未唱会是完全同一个色,卡拉OK的进度效果直接失去可读性。
        settings.karaokeUnsungFollowsCoverArt = false
        settings.karaokeUnsungColorHex = AppSettings.dimmedForegroundHex(ColorTheme.defaultTheme.foregroundColorHex)
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

// (删掉了 `overview` —— 拼给「全部设置」抽屉折起来时的那串「系统字体 31pt ·
//  跟随封面 · 486pt」。删掉那处展示,删完这个派生属性就一个消费方都没有了,留着
//  就是一段没人调的代码。其余几截仍在用:编辑台工具栏那几颗按钮上的摘要就是它们
//  —— 是 `theme` / `text` / `background` / `layout` 四截,`color` 那一截随
//  「配色」浮层一起拆成了前面的 `theme` 和 `background`。)

// MARK: - 浮层外壳

/// 「Aa 文字…」浮层。内容就是抽屉「文字」那一组,没有第二份实现。
///
/// 内容从三行(字体/粗细/字号)长到最多七行:原「配色」组里属于文字层的四行
/// (跟随封面 / 文字颜色 / 文字描边 / 描边颜色)并了过来;加「卡拉OK效果」;
/// 「跟随封面」搬去「主题」,现在是字体 / 粗细 / 字号 / 卡拉OK效果 / 文字颜色 /
/// 文字描边(描边颜色)最多七行。
/// 宽度仍吃外壳默认的 380 —— 这几行标题都很短,尾部是 Toggle / ColorPicker,横向瓶颈仍然是
/// 原来那三行(`FontFamilyPicker` 的字体名下拉、粗细下拉、字号滑杆+读数),没有变。高度最多
/// 七行 ≈ 340pt,在外壳 460 的上限内,不会退化成"多一条滚动条"。
@MainActor
struct OverlayTextPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("文字")) {
            OverlayTextSettingsRows()
        }
    }
}

/// 「主题」浮层(原「◐ 配色…」浮层拆出来的三个之一)。
///
/// 宽度吃外壳默认的 380:里面的 `OverlayCustomThemeRows` 有两行内联确认(130pt 输入框 +
/// 两颗按钮),380 是它验证过的下限——那次"按钮被挤成空圆角矩形"就是在 380 的
/// 配色浮层里踩的,修法是把那两行改成"说明一行、控件另起一行",不是把浮层拉宽。别为了跟
/// 「背景」浮层的 420 取齐而动它,那两个数各有各的来路。
@MainActor
struct OverlayThemePopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("主题")) {
            OverlayThemeSettingsRows()
        }
    }
}

/// 「背景」浮层(同上)。
///
/// **宽度 420 现在没有依据了,是个待重量的遗留值**。
///
/// 它当初是量出来的:内容自然宽中文 298pt / **英文 386pt**(离屏 `NSHostingView.fittingSize`,
/// 1pt 步进的换行探测给出的英文硬下限就是 386),420 按同族浮层的既有余量取
/// (`NotchStylePopover` +28 / `NotchEarPopover` +24 / `OverlayLayoutPopover` +32)。
/// **但那 386 的瓶颈是「毛玻璃背景」那一行的副标题**——英文
/// "When on, the background color tints the glass" 比中文长出 88pt,380 差 6pt、英文下当场
/// 折成两行。同一天把那句副标题删掉,瓶颈随之消失,这个数就悬空了。
///
/// 现在这个浮层只剩两行短内容(背景颜色 + 色板 / 毛玻璃背景 + 开关),420 几乎肯定过宽 ——
/// 而"浮层比内容宽出一大截"正是现象是过的那类问题(左右耳浮层从 380 收到 160 那次,原话
/// 是「明明需要的空间很小就够了,还是占了这么多空间」)。
///
/// **没有顺手改成 380 或别的数**:380 是「文字」「主题」两个浮层量出来的值,不是通用基线
/// (见 `SettingsPopoverShell.width` 的注释),照搬同样是凭感觉。要收窄就得按同一套方法论
/// 重新离屏量一遍(中英各一次),仓库里没有现成的测量脚本,那是一次单独的改动。
@MainActor
struct OverlayBackgroundPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("背景"), width: 420) {
            OverlayBackgroundSettingsRows()
        }
    }
}

/// 「≣ 排版…」浮层。内容就是抽屉里那一组,没有第二份实现。
///
/// 宽度 460、不是另外两个浮层的 380,这是**量出来的**,别顺手拉平:
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
