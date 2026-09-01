import SwiftUI

/// 「歌词显示 → 菜单栏」分段的编辑台(2026-09-01,用户要求"改成和悬浮歌词/灵动岛一样的
/// 风格"——照 `OverlayEditorStage`/`NotchEditorStage` 的范式改)。
///
/// 跟另外两段编辑台的**关键不同**:菜单栏歌词的预览不需要另画一套"模拟屏幕/模拟刘海"的
/// 画布——`MenuBarPreviewBar`(`SectionPreviewBars.swift`)本来就是**真实渲染**(同一份
/// `MenuBarMarqueeRenderer`/`MenuBarScrollingLabel`,不是另一份 mock),原来只是被钉在
/// 页顶的固定头部里、点不动。这次改造是"挪位置 + 换外壳"——把它搬进可滚动内容区,外面套
/// 一圈工具栏(浮层入口 + 重置)和宽度调整条,不重新实现预览本身。
///
/// 设置项本来就少(五项 + 一个总开关),不需要 Notch 那种两行工具栏——一行两个浮层入口
/// (「宽度模式」「配色」)+「重置 ▾」够用,横向预算离屏量过(见 `toolbar` 上面那条⚠️),
/// 499pt 窄档下中英文都有余量,不会重演灵动岛第一行那次"加了重置就超支"的教训。
@MainActor
struct MenuBarEditorStage: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var popover: StagePopover?

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            // 宽度调整条浮**在预览框里面**(2026-09-01 第三轮,用户原话「把这个配置项也给我
            // 和之前两个页面一样加到这个预览框里面去进行调整」)。前两版都不是他要的:
            // 第一版摆在预览下面平铺一行、第二版仍是 VStack 里的兄弟节点 —— 而
            // MenuBarWidthRow 用的是 SettingsRow 的外壳,在舞台那块近白的
            // controlBackgroundColor 上跟"页面上一条独立的设置行"长得几乎一样,难怪看着像
            // 没动。现在照 OverlayEditorStage/NotchEditorStage 的做法:预览条自己让出一条
            // 通道(reservesWidthLane),胶囊浮在通道里。
            MenuBarPreviewBar(reservesWidthLane: true)
                .overlay(alignment: .bottom) {
                    stageWidthBar.padding(.bottom, 8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 工具栏

    /// 「宽度模式」「配色」两个浮层入口 + 「重置 ▾」。
    ///
    /// ⚠️ 横向够不够:离屏 `NSHostingView.fittingSize`(方法论同 `NotchEditorStage.toolbar`
    /// 那条⚠️,复刻了 `.bordered` + `.controlSize(.small)` + 摘要 `.layoutPriority(-1)`):
    /// 两个入口(最坏摘要"自适应"/"卡拉OK染色")+ 重置菜单,中文 398.0pt、英文 458.0pt。
    /// 拿灵动岛那条测过的窄档舞台阈值 499pt 对比,中英两档都有余量(中文 101pt、英文 41pt)——
    /// 比灵动岛第一行(加重置后中文 586.0 超 87pt)宽松得多,这一行本身设置项就少,不会重演
    /// 那次"加了第 5 样东西就超支"的教训。
    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarButton(
                icon: "arrow.left.and.right.circle",
                title: L10n.t("宽度模式"),
                summary: settings.menuBarLyricsWidthMode.displayName,
                target: .widthMode
            )
            toolbarButton(
                // 跟悬浮歌词工具栏「配色」浮层同一个图标——两者都是"这一段的配色设置",
                // 概念相同就用同一个符号,不新造一套语言。
                icon: "circle.lefthalf.filled",
                title: L10n.t("配色"),
                summary: colorSummary,
                target: .color
            )
            Spacer(minLength: 8)
            // 「重置 ▾」逐字复刻悬浮歌词/灵动岛工具栏那颗:Menu 里一条恢复动作 + 一条不可点的
            // 作用范围说明。范围文案复用灵动岛那条"不含宽度和总开关"——两边排除的东西逐字
            // 相同(结构性宽度设置 + 总开关),没必要另造一句意思一样的话。
            Menu {
                Button(L10n.t("恢复默认宽度模式与配色")) { MenuBarStyleDefaults.restoreDefaults() }
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

    /// 「配色」按钮摘要——两个候选都是**现成的**既有文案(逐字染色开关自己的标题 / 颜色
    /// 重置按钮自己的标题),不新造描述句,理由同 `NotchEditorStage.lyricRowSummary` 那组
    /// "摘要复用现成 item 标题"的纪律。
    private var colorSummary: String {
        settings.menuBarLyricsKaraoke ? L10n.t("卡拉OK染色") : L10n.t("跟随系统")
    }

    private func toolbarButton(
        icon: String, title: String, summary: String, target: StagePopover
    ) -> some View {
        Button {
            popover = target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .environment(\.locale, Locale(identifier: "en"))
                Text(title)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.tertiary)
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

    private enum StagePopover: Equatable {
        case widthMode
        case color
    }

    private func popoverBinding(_ target: StagePopover) -> Binding<Bool> {
        Binding(
            get: { popover == target },
            set: { shown in
                if shown { popover = target } else if popover == target { popover = nil }
            })
    }

    @ViewBuilder
    private func popoverContent(for target: StagePopover) -> some View {
        switch target {
        case .widthMode: MenuBarWidthModePopover()
        case .color: MenuBarColorPopover()
        }
    }

    // MARK: - 宽度条

    /// 「最大宽度」——跟另外两段编辑台同一个理由单独钉一条常驻调整条,不藏进浮层:这是
    /// "调一下马上想看效果"的项。
    ///
    /// 浮在预览框那条通道里的宽度调整条。
    ///
    /// ⚠️ 这里原来是 `MenuBarWidthRow()`(设置页原生行样式),当时的理由是"菜单栏这段的预览
    /// 只是一小条,下面是设置页普通背景、不是一张可以浮在上面的场景图,硬套黑底胶囊只会变成
    /// 一块突兀的黑条"。**这个理由被用户否掉了**:他连着三次要求「和之前两个页面一样」,
    /// 而原生行样式在舞台那块近白底上跟页面里一条普通设置行几乎无从区分 —— 它没能传达
    /// "这是预览框自己的控件",反而正是他一直觉得"还没做"的原因。
    ///
    /// 样式照 `NotchEditorStage.widthBar` 逐项抄:黑底胶囊 + 白色描边 + 投影、白色小号
    /// Slider、等宽读数。固定黑白**不跟深浅色模式走** —— 跟另外两条同一个理由,它压在
    /// 预览那块壁纸/材质合成出来的底上,语义色在浅色壁纸上会读不出来。
    ///
    /// ⚠️ **不要给这根 Slider 传 `step:`**。macOS 的 Slider 一旦有 step 就会画刻度线,
    /// 80...600 / step 10 是 52 个刻度、密到连成一条实线,看着像轨道下面平白多一条白杠
    /// (悬浮歌词那根为此被用户报过一次,见 NotchEditorStage.widthBar 同款注释)。量化不必
    /// 靠它:下面 set 里自己 round 到 10 的整数倍。
    private var stageWidthBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
            Slider(value: Binding(
                get: { Double(settings.menuBarLyricsWidth) },
                set: {
                    let quantized = CGFloat(($0 / 10).rounded() * 10)
                    guard quantized != settings.menuBarLyricsWidth else { return }
                    settings.menuBarLyricsWidth = quantized
                }
            ), in: 80...600)
            .controlSize(.small)
            .tint(.white)
            .frame(width: 150)
            // Slider 自带键盘/VoiceOver 调节;显式给 value 是因为不给的话 VoiceOver 会把它
            // 读成百分比(同 NotchEditorStage.widthBar)。
            .accessibilityLabel(L10n.t("最大宽度"))
            .accessibilityValue(widthValueText)
            Text(widthValueText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                // 读数是滑杆的镜像,都进无障碍树会把同一个值读两遍。
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
    }

    private var widthValueText: String {
        String(format: L10n.t("%@pt"), "\(Int(settings.menuBarLyricsWidth))")
    }
}

/// 「最大宽度」行(图标 + 滑杆 + 只读数字)——`MenuBarEditorStage.widthBar`(常驻)和
/// `MenuBarAllSettingsDrawer`(全量兜底)共用同一份,跟灵动岛"宽度调整条和抽屉里那条是
/// 同一份滑杆逻辑、只是外壳不同宿主"同一个模式。
///
/// 没有 `NotchEditorStage.widthBar` 那套"拖动中间态 + 松手才提交"的复杂度:那边的宽度
/// 上限依赖实时屏幕几何(`usableWidthRange(notchWidth:contentTopInset:)`),这里的区间
/// 是写死的常量(80...600),不需要拖动防抖。
struct MenuBarWidthRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(icon: "arrow.left.and.right", title: L10n.t("最大宽度")) {
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(settings.menuBarLyricsWidth) },
                    set: {
                        // 量化到 10 的整数倍,理由同悬浮歌词/灵动岛宽度滑杆同款注释:相等
                        // 守卫避免拖动中间态频繁触发无意义的 didSet。
                        let quantized = CGFloat(($0 / 10).rounded() * 10)
                        guard quantized != settings.menuBarLyricsWidth else { return }
                        settings.menuBarLyricsWidth = quantized
                    }
                ), in: 80...600, step: 10)
                .frame(width: 150)
                Text(String(format: L10n.t("%@pt"), "\(Int(settings.menuBarLyricsWidth))"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}

extension MenuBarLyricsWidthMode {
    var displayName: String {
        switch self {
        case .fixed: return L10n.t("固定")
        case .adaptive: return L10n.t("自适应")
        }
    }
}

// MARK: - 恢复默认

/// 「重置」按钮的动作本体——恢复宽度模式 + 逐字染色 + 文字/染色两个自定义色,**不含**
/// `menuBarLyricsWidth`(宽度,结构性尺寸设置)和 `showLyricsInMenuBar`(总开关),取舍跟
/// 悬浮歌词/灵动岛两个「重置」一致。默认值只在 `AppSettings.defaultMenuBarXxx` 里出现
/// 一次,`AppSettings.init()` 的 fallback 和这里读的是同一份常量。
@MainActor
enum MenuBarStyleDefaults {
    static func restoreDefaults() {
        let settings = AppSettings.shared
        settings.menuBarLyricsWidthMode = AppSettings.defaultMenuBarLyricsWidthMode
        settings.menuBarLyricsAlignment = AppSettings.defaultMenuBarLyricsAlignment
        settings.menuBarLyricsKaraoke = AppSettings.defaultMenuBarLyricsKaraoke
        settings.menuBarLyricsTextColorHex = AppSettings.defaultMenuBarLyricsTextColorHex
        settings.menuBarLyricsFillColorHex = AppSettings.defaultMenuBarLyricsFillColorHex
    }
}

// MARK: - 「宽度模式」浮层

struct MenuBarWidthModePopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("宽度模式"), width: 430) {
            MenuBarWidthModeRow()
        }
    }
}

/// 「宽度模式」行——文案/help 一字不改自旧 `menuBarCard`。单独抽成一个 View 是因为浮层和
/// 「全部设置」抽屉都要渲染这一行,只留一份实现。
///
/// ⚠️ **两处踩过的坑,均系 2026-09-01 用户实测截图报的**:
///   ① 原来用 `SettingsSubRow`(标题左边带一条"子项"竖线),用户反馈"没必要加这个子项的
///      竖线"——这一行(以及「配色」那三行)在浮层/抽屉里本来就是**顶层**设置项,不是挂在
///      某个「主行」下面的从属选项,`SettingsSubRow` 那条竖线是给真正的主从关系准备的
///      (参见该组件文档:"标题缩进到跟主行标题同一列"),这里没有主行可对齐,套上去就是
///      多余的装饰。改用 `SettingsRow(icon:)`——跟 `NotchBehaviorItem`/`NotchBehaviorItemRows`
///      那套"每项一个图标、不用竖线"的既有惯例对齐,顺带跟「全部设置」抽屉里已经在用
///      `SettingsRow` 的「最大宽度」行取得一致(改之前二者一个有竖线一个有图标,风格对不上,
///      用户在「全部设置」截图里也点出了这一点)。
///   ② 浮层宽度 280 是**没有离屏量过、凭感觉给的数**,而这一行的分段选择器
///      `.fixedSize()` 不肯让步——`SettingsRow`/`SettingsSubRow` 的尾部控件一旦
///      `.fixedSize()`、又赶上容器太窄,SwiftUI 会把全部宽度亏空摊给**标题**那一侧
///      (这条坑两个组件自己的文档注释都写着,2026-08-30「我的配色主题」内联命名行就是
///      同一个坑),表现正是用户截图里"宽度模式"标题被压没、只剩一个"?"图标孤零零杵在
///      左边。离屏 `NSHostingView.fittingSize` 实测这一行(图标+标题+"?"+分段选择器)
///      需要中文 370.0pt / 英文 414.0pt,于是把浮层宽度改成 430——不能再凭感觉调,
///      这条教训之前在 05-notch.md 里给别的浮层记过一次,这次轮到自己踩。
struct MenuBarWidthModeRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "arrow.left.and.right.circle",
            title: L10n.t("宽度模式"),
            // ⚠️ 这行 help **只描述两种模式各自的最终效果,不给建议**(2026-09-01 用户:
            // "这里只需要说明最终的效果是什么就好,不需要说不建议")。原文里的
            // 「自适应（不建议）」、「想稳定就用固定」以及那整段机制解释都去掉了。
            //
            // 被删掉的那段机制是实测结论、别当废话丢了,搬到这里存着:自适应下**每换一句
            // 都要重建菜单栏这一项**,而系统只在项出生那一刻给邻居排位,重建太密时邻居
            // 图标会停在旧位置(错位、闪动),左键面板也可能被挤掉。UI 上现在只保留它的
            // **可见结果**(宽度随句变、旁边图标跟着挪)——那是"效果";成因和"别用"属于
            // 判断,不进这行字。
            help: L10n.t("只影响装得下的句子。\n\n固定：短句也占满设定宽度，右边留白，菜单栏上的位置不会变。\n\n自适应：短句按自己的宽度占位，省下多余空间；菜单栏这一项的宽度随每句变化，旁边的图标位置也跟着挪。")
        ) {
            Picker("", selection: $settings.menuBarLyricsWidthMode) {
                Text(L10n.t("固定")).tag(MenuBarLyricsWidthMode.fixed)
                Text(L10n.t("自适应")).tag(MenuBarLyricsWidthMode.adaptive)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        // 「对齐模式」只在**固定宽度**下出现(2026-09-01,用户自己先判断出来的:"看起来是不是
        // 只会在固定宽度模式下生效?我理解自适应的模式下不存在对齐模式" —— 对的)。自适应
        // 模式下那一格的宽度就等于文字宽度,没有多余空间,三个选项画出来一模一样;摆一个
        // 恒无效果的控件比不摆更糟。完整判据见 MenuBarLyricsAlignment 头注。
        //
        // 用 if 整行不渲染、不用 .disabled:这一段的既有做法就是"不适用就不显示"(见
        // MenuBarColorRows 里「已唱到的颜色」那行跟着染色开关显隐),灰着摆在那儿会让人
        // 去猜"要满足什么条件才能点"。
        if settings.menuBarLyricsWidthMode == .fixed {
            CardDivider()
            MenuBarAlignmentRow()
        }
    }
}

/// 「对齐模式」行 —— 固定宽度那一格里,装得下的短句靠哪边。
struct MenuBarAlignmentRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.alignleft",
            // 用「对齐方式」而不是「对齐模式」:悬浮歌词那个同名设置就叫「对齐方式」
            // (OverlayStyleSettingsRows),用户上一轮的要求正是"和软件其他地方对齐"。
            // 顺带复用已有词条(含 Left-Aligned/Center/Right-Aligned 三个选项名)。
            title: L10n.t("对齐方式"),
            help: L10n.t("只影响装得下的短句：它在固定宽度那一格里靠哪边。放不下的句子会横向滚动，没有多余空间，对齐不起作用")
        ) {
            MenuBarAlignmentSegmentedControl(selection: $settings.menuBarLyricsAlignment)
        }
    }
}

/// 「对齐方式」用的分段控件。
///
/// ⚠️ **刻意不用系统 `.pickerStyle(.segmented)`** —— 照 `OverlayAlignmentSegmentedControl`
/// (悬浮歌词那个同名设置)的解法搬过来,那边为这件事修了三轮:macOS 把 SwiftUI 的 Picker
/// 桥接成 `NSSegmentedControl`,而它按**当前选中段的文字**自己重新量宽度,于是"选了哪个
/// 选项、控件整体宽度就跟着变"。给子 `Text` 加 `.frame(minWidth:)` 不管用(AppKit 那层
/// 不读 SwiftUI 子视图的 frame),给 Picker 整体加 `.frame(minWidth:)` 也不管用。完整排查
/// 记录见 docs/features/04-desktop-overlay.md。
///
/// 我这三个标签正好是不等宽的(左对齐/居中/右对齐 = 3/2/3 字,英文 Left-Aligned/Center/
/// Right-Aligned 差得更多),是那个 bug 的正射场景,所以直接用手搭的:每个选项固定
/// `minWidth`,尺寸只取决于这里写的数字。
///
/// ⚠️ `.fixedSize()` 是必需的、不是保险(同样抄自那边 2026-08-31 离屏渲染查出来的结论):
/// 这个控件在 `SettingsRow` 尾部插槽里,那一行有三个可伸缩成员(标题列/Spacer/本控件),
/// SwiftUI **均分**剩余宽度而不是"先按理想宽度发";均分份额小于理想宽度时控件被压到下限,
/// 英文标签("Left-Aligned" 长于 56pt)就会在**行里还剩一大截空白**的情况下被截成
/// "Left-Ali…"。
@MainActor
struct MenuBarAlignmentSegmentedControl: View {
    @Binding var selection: MenuBarLyricsAlignment

    /// ⚠️ 不能存成 `static let`:`L10n.t` 要在每次取值时现算,存进 static let 等于把首次
    /// 访问时的语言冻在里面(切语言之后这几个标签不跟着变)——同 OverlayAlignment 那边。
    static func label(for option: MenuBarLyricsAlignment) -> String {
        switch option {
        case .leading: return L10n.t("左对齐")
        case .center: return L10n.t("居中")
        case .trailing: return L10n.t("右对齐")
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarLyricsAlignment.allCases, id: \.self) { option in
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
        .fixedSize()
    }
}

// MARK: - 「配色」浮层

struct MenuBarColorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("配色"), width: 330) {
            MenuBarColorRows()
        }
    }
}

/// 「逐字染色」+「文字颜色」+「染色颜色」(条件显示)三行——文案/help 一字不改自旧
/// `menuBarCard`,浮层和抽屉共用同一份。
///
/// ⚠️ 跟 `MenuBarWidthModeRow` 同一天(2026-09-01)的同一条修正:改用 `SettingsRow(icon:)`
/// 而不是 `SettingsSubRow`——这三行在浮层/抽屉里都是顶层设置项,不该带"子项"竖线,理由
/// 详见 `MenuBarWidthModeRow` 上面那条⚠️。浮层宽度也一并离屏量过(实测这三行最宽一条
/// 中文 288.0pt / 英文 308.0pt,原来的 280 连中文都不够),改成 330 留出余量。
struct MenuBarColorRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(
                icon: "text.word.spacing",
                // 「逐字染色」→「卡拉OK染色」(2026-09-01,用户要求"改专业一点、和软件其他
                // 地方对齐")。本仓面向用户的术语一直是**卡拉OK**(「歌词 → 效果」那张卡就叫
                // 「卡拉OK效果」,候选打分说明里也是「带逐字（卡拉OK）时间轴」),而英文侧本来
                // 就是 "Karaoke fill" —— 漂的只有这一处中文。
                //
                // ⚠️ 跟「卡拉OK效果」是**两层**、不是重名:那个是全局的
                // `preferWordLevelKaraoke`(要不要用逐字数据),这个是 `menuBarLyricsKaraoke`
                // (菜单栏要不要跟着染)。名字相近正是想让这层关系看得出来。
                title: L10n.t("卡拉OK染色"),
                help: L10n.t("跟着演唱进度把已唱到的部分染成系统强调色。只在这首歌有逐字时间轴时生效；打开菜单反白期间暂不染色")
            ) {
                Toggle("", isOn: $settings.menuBarLyricsKaraoke)
            }
            CardDivider()
            SettingsRow(
                icon: "textformat",
                // 标题跟着上面那个开关走,因为这一行管的范围**真的会变**:染色关着时它就是
                // 整条歌词的颜色(叫「未唱到的颜色」会莫名其妙——什么都不会被"唱到"),开着时
                // 它只管未唱到那半截。
                //
                // 两个都是既有说法:关态复用「文字颜色」(跟悬浮歌词那行同一个键,
                // OverlayStyleSettingsRows),开态用下面那行的对称说法。⚠️ 正因为共用,
                // **别去改「文字颜色」那个键的值** —— 那会连带把悬浮歌词那一行也改掉。
                title: settings.menuBarLyricsKaraoke
                    ? L10n.t("未唱到的颜色") : L10n.t("文字颜色"),
                help: L10n.t("未唱到部分的文字颜色。默认跟随系统：浅色/深色菜单栏自动适配，打开菜单时自动反白")
            ) {
                HStack(spacing: 8) {
                    if !settings.menuBarLyricsTextColorHex.isEmpty {
                        Button(L10n.t("跟随系统")) { settings.menuBarLyricsTextColorHex = "" }
                    }
                    ColorPicker("", selection: Binding(
                        get: {
                            settings.menuBarLyricsTextColorHex.isEmpty
                                ? Color(nsColor: .labelColor)
                                : Color(hexWithAlpha: settings.menuBarLyricsTextColorHex,
                                        fallback: Color(nsColor: .labelColor))
                        },
                        set: { settings.menuBarLyricsTextColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: false)
                }
            }
            if settings.menuBarLyricsKaraoke {
                CardDivider()
                SettingsRow(
                    icon: "paintpalette.fill",
                    // 「染色颜色」→「已唱到的颜色」:原来那个词组自己打结("染色"已经含"色"),
                    // 而且没说清染的是哪一半。它的 help 一直写着"已唱到部分的颜色" —— 标题
                    // 直接用 help 里那句话,跟上面「未唱到的颜色」成对。
                    title: L10n.t("已唱到的颜色"),
                    help: L10n.t("已唱到部分的颜色。默认跟随系统强调色（深色菜单栏自动提亮）；自定义后原样使用、不再自动提亮")
                ) {
                    HStack(spacing: 8) {
                        if !settings.menuBarLyricsFillColorHex.isEmpty {
                            Button(L10n.t("跟随系统")) { settings.menuBarLyricsFillColorHex = "" }
                        }
                        ColorPicker("", selection: Binding(
                            get: {
                                settings.menuBarLyricsFillColorHex.isEmpty
                                    ? Color(nsColor: .controlAccentColor)
                                    : Color(hexWithAlpha: settings.menuBarLyricsFillColorHex,
                                            fallback: Color(nsColor: .controlAccentColor))
                            },
                            set: { settings.menuBarLyricsFillColorHex = $0.hexStringWithAlpha }
                        ), supportsOpacity: false)
                    }
                }
            }
        }
    }
}

// MARK: - 「全部设置」抽屉

/// 菜单栏歌词的「全部设置」抽屉(2026-09-01)——五项(宽度模式/最大宽度/逐字染色/文字颜色/
/// 染色颜色)单组平铺,不像 `NotchAllSettingsDrawer` 那样再分组:项数本来就少,分组反而是
/// 多余的层级。默认折叠,理由同另外两个抽屉:键盘/VoiceOver 全量兜底通路,不是新配置项的
/// 收纳盒。
struct MenuBarAllSettingsDrawer: View {
    @State private var isExpanded = false

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()
                MenuBarWidthModeRow()
                CardDivider()
                // 「最大宽度」在这里是**兜底副本**,跟舞台上那条常驻的 `widthBar` 改的是
                // 同一个值——跟灵动岛「全部设置」抽屉里那条 `widthRow` 同一个模式。
                MenuBarWidthRow()
                CardDivider()
                MenuBarColorRows()
            }
        }
    }

    private var disclosureHeader: some View {
        Button {
            withAnimation(.settingsCardReveal) { isExpanded.toggle() }
        } label: {
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(L10n.t("全部设置"))
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("全部设置"))
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityValue(isExpanded ? L10n.t("已展开") : L10n.t("已折叠"))
    }
}
