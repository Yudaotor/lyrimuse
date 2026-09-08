import SwiftUI
import LyrimuseCore

/// 「歌词显示 → 菜单栏」分段的编辑台(2026-09-01,用户要求"改成和悬浮歌词/灵动岛一样的
/// 风格"——照 `OverlayEditorStage`/`NotchEditorStage` 的范式改)。
///
/// 跟另外两段编辑台的**关键不同**:菜单栏歌词的预览不需要另画一套"模拟屏幕/模拟刘海"的
/// 画布——`MenuBarPreviewBar`(`SectionPreviewBars.swift`)本来就是**真实渲染**(同一份
/// `MenuBarMarqueeRenderer`/`MenuBarScrollingLabel`,不是另一份 mock),原来只是被钉在
/// 页顶的固定头部里、点不动。这次改造是"挪位置 + 换外壳"——把它搬进可滚动内容区,外面套
/// 一圈工具栏(浮层入口 + 重置)和宽度调整条,不重新实现预览本身。
///
/// 工具栏两行(2026-09-07 起,跟另外两段取齐):第一行「布局」「配色」「字体」+「重置 ▾」(第三个
/// 入口是 2026-09-03 用户点名加的),横向预算离屏量过(见 `toolbar` 上面那条⚠️):中文在 499pt 窄档下
/// 也放得下,英文在 600pt 宽档放得下、窄档只压摘要不压标题。第二行只有「行为」一颗 —— 两个行为开关
/// (悬停显示播放控制 / 无歌词时显示歌名)此前因为第一行装不下而寄住在「布局」里,`MenuBarHoverControlsRow`
/// 头注当时就写着"真要再来第二个行为开关,那时候一起拆一个「行为」浮层出来";第二个 09-04 就来了,
/// 这次按用户"不要这一个那一个"的要求拆出来。分组按卡片解剖:「布局」= 这一格怎么占位、几行、旁边
/// 有没有图标;「配色」= 颜色;「字体」= 字长什么样;「行为」= 什么状态下显示什么。
@MainActor
struct MenuBarEditorStage: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var popover: StagePopover?

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            toolbarRow2
            // 宽度调整条浮**在预览框里面**(2026-09-01 第三轮,用户原话「把这个配置项也给我
            // 和之前两个页面一样加到这个预览框里面去进行调整」)。前两版都不是他要的:
            // 第一版摆在预览下面平铺一行、第二版仍是 VStack 里的兄弟节点 —— 而
            // MenuBarWidthRow 用的是 SettingsRow 的外壳,在舞台那块近白的
            // controlBackgroundColor 上跟"页面上一条独立的设置行"长得几乎一样,难怪看着像
            // 没动。现在照 OverlayEditorStage/NotchEditorStage 的做法:预览条自己让出一条
            // 通道(reservesWidthLane),胶囊浮在通道里。
            // 2026-09-02:壁纸底扩展到包住整块舞台(含通道里的调整条),caption 挪到舞台
            // 外面 —— 用户原话「这里帮我把预览背景部分扩展到这下面,把下面的滑条包在里面,
            // 和灵动岛和悬浮歌词设置一样」。三块编辑台的舞台到此是同一个模型。
            //
            // ⚠️ 调整条现在**注入给预览条**、不再由这里 overlay 在外面:壁纸底一旦要包住它,
            // 背景/高度/圆角就必须由同一个人算(见 MenuBarPreviewBar.lane 的注释)。这里
            // 在外面 overlay 的话,那一层会落在"舞台 + caption"整块上,胶囊掉到 caption 下面。
            MenuBarPreviewBar(reservesWidthLane: true) {
                stageWidthBar.padding(.bottom, 8)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 工具栏

    /// 「布局」「配色」「字体」三个浮层入口 + 「重置 ▾」。
    ///
    /// ⚠️ 横向够不够:离屏 `NSHostingView.fittingSize`(方法论同 `NotchEditorStage.toolbar`
    /// 那条⚠️,复刻了 `.bordered` + `.controlSize(.small)` + 摘要 `.layoutPriority(-1)`)。
    /// 两个入口时(最坏摘要"自适应"/"卡拉OK效果",09-06 前叫"卡拉OK染色"、等长)+ 重置菜单是中文 398.0pt / 英文 458.0pt。
    /// 2026-09-03 加第三个入口「粗细」前重量了一遍:同一份复刻在这次的宿主里量出两入口
    /// 348.0 / 394.0(比记录值系统性少 50 / 64,是重置菜单在离屏宿主里渲染得更窄,按差值校准),
    /// 三入口 中文 450.0 → 校准 ≈500;英文标题若沿用 "Font Weight" 565.0 → ≈629,**改成 "Weight"**
    /// 后 538.0 → ≈602(最坏摘要 Semibold)。对照舞台宽度区间 499(窄档)~600(卡片列上限):
    /// 中文全区间标题、摘要都完整(窄档差 1pt 落在摘要上,看不出);英文在 600 宽档差 2pt、
    /// 窄档差约 100pt,亏空全由三个摘要的 `.layoutPriority(-1)` 吃掉,标题不截 —— 跟灵动岛
    /// 第一行现在的状态一样。所以「粗细」的英文词条特意是 "Weight" 不是 "Font Weight"
    /// (悬浮歌词那一行同一个键,在「文字」浮层里跟 Font / Size 并列,读起来反而更顺)。
    /// 同日晚些第三个入口从「粗细」改名「字体」(英文 Font,比 Weight 还短 13pt 左右),浮层里加了
    /// 「字号」;摘要在**用户改过字号时**才追加 " Npt"(约 +30pt),跟随系统时只报粗细 —— 这样默认
    /// 状态的预算不变,改过字号的英文用户在 600 宽档会看到摘要尾部被压掉几个字母,标题仍完整。
    /// **这一行到此也到底了**,再加入口或把哪个标题改长,先重新离屏量。
    private var toolbar: some View {
        HStack(spacing: 8) {
            // 2026-09-03 从「宽度模式」改叫「布局」:这个浮层里现在有三行 —— 宽度模式、
            // 对齐方式(固定宽度时)、歌词旁的图标。前两行还能算"宽度模式和它的从属选项",
            // 第三行不是,再挂在「宽度模式」这个标题下面就名不副实了。摘要仍然给宽度模式
            // (三项里最结构性的那个),跟改名前逐字一致。
            //
            // 改名顺带**更省**:「布局」比「宽度模式」少两个字,英文 Layout 也比 Width Mode 短 ——
            // 省下的正是 2026-09-03 第三个入口「粗细」要用的预算(账见 toolbar 头注)。
            toolbarButton(
                icon: "arrow.left.and.right.circle",
                title: L10n.t("布局"),
                summary: layoutSummary,
                target: .layout
            )
            toolbarButton(
                // 跟悬浮歌词工具栏「配色」浮层同一个图标——两者都是"这一段的配色设置",
                // 概念相同就用同一个符号,不新造一套语言。
                icon: "circle.lefthalf.filled",
                title: L10n.t("配色"),
                summary: colorSummary,
                target: .color
            )
            // 「字体」(2026-09-03,用户指着「配色」右边的空位:「把粗细加在这里」;当晚又加字号:
            // 「帮我再加上字体大小吧,也归类到字体这个下拉选项里面去,替换现在粗细这个大标题」)。
            // 第一版「粗细」放在「配色」浮层头一行,用户要的是跟另外两个同款的独立入口。图标跟
            // 悬浮歌词工具栏「文字」入口同一个 textformat —— 两边都是"这行字本身长什么样"。
            toolbarButton(
                icon: "textformat",
                title: L10n.t("字体"),
                summary: fontSummary,
                target: .font
            )
            Spacer(minLength: 8)
            // 「重置 ▾」逐字复刻悬浮歌词/灵动岛工具栏那颗:Menu 里一条恢复动作 + 一条不可点的
            // 作用范围说明。范围文案复用灵动岛那条"不含宽度和总开关"——两边排除的东西逐字
            // 相同(结构性宽度设置 + 总开关),没必要另造一句意思一样的话。
            //
            // 动作标题就叫「恢复默认」,范围由下面那条不可点的说明项(「不含宽度和总开关」)交代。
            // 2026-09-07 用户「简约克制」专项把三个编辑台(悬浮 / 灵动岛 / 菜单栏)的这颗按钮统一成这四个字:
            // 此前这里念的是工具栏四个入口的名字(「恢复默认布局、配色、字体与行为」,2026-09-03 起),
            // 更早叫「恢复默认宽度模式与配色」—— 两版都在标题里列举范围,越列越长,而排除项那一行
            // 本来就在菜单里,标题再列一遍是重复。范围本身(这个编辑台除宽度和总开关外的全部)不变。
            Menu {
                Button(L10n.t("恢复默认")) { MenuBarStyleDefaults.restoreDefaults() }
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

    /// 工具栏第二行(2026-09-07):只有「行为」一颗。另起一行而不是塞进第一行,理由跟另外两段
    /// 编辑台一样 —— 第一行的横向预算是量到上限的(见 `toolbar` 头注),第四颗必然把摘要压成「…」
    /// 甚至挤掉标题;一颗按钮独占一行看着松,但三段编辑台的结构因此一致(「行为」都在第二行末尾)。
    private var toolbarRow2: some View {
        HStack(spacing: 8) {
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

    /// 「布局」按钮摘要:宽度模式(三项里最结构性的那个),副行**非默认**时再追加「副行 · 译文」——
    /// 四选一不是开关,套不进"只列开着的";默认那一档(2026-09-07 起是「下一句」,此前是「不显示」)是多数人的状态,无条件报出来是恒定噪声
    /// (灵动岛「歌词行」摘要同一条规则)。歌词旁的图标不报:它在预览上一眼就看得见。
    private var layoutSummary: String {
        var parts = [settings.menuBarLyricsWidthMode.displayName]
        if settings.menuBarSecondaryLine != AppSettings.defaultMenuBarSecondaryLine {
            parts.append("\(L10n.t("副行")) · \(settings.menuBarSecondaryLine.displayName)")
        }
        return parts.joined(separator: " · ")
    }

    /// 「配色」按钮摘要——两个候选都是**现成的**既有文案(卡拉OK开关自己的标题 / 颜色
    /// 重置按钮自己的标题),不新造描述句,理由同 `NotchEditorStage.lyricRowSummary` 那组
    /// "摘要复用现成 item 标题"的纪律。(标题 2026-09-06 随开关改名「卡拉OK效果」,宽度预算见
    /// toolbar 头注:比原「卡拉OK染色」等长,不用重量。)
    private var colorSummary: String {
        settings.menuBarLyricsKaraoke ? L10n.t("卡拉OK效果") : L10n.t("跟随系统")
    }

    /// 「字体」按钮摘要:粗细档位显示名(跟下拉里的选项同一份文案);**只有用户改过字号、且字号在生效**
    /// 才追加 " Npt" —— 跟随系统时字号不是用户的决定;副行开着时字号由行高推出、滑杆让位(见
    /// `MenuBarFontSizeRow`),报出来都是占预算(toolbar 头注那笔账按这个口径算)。副行本身 2026-09-07 起
    /// 归「布局」,在那颗按钮的摘要里报。
    private var fontSummary: String {
        let weight = settings.menuBarLyricsFontWeight.displayName
        guard !settings.menuBarSecondaryLine.showsSecondaryRow, settings.menuBarLyricsFontSize > 0 else { return weight }
        let size = String(format: L10n.t("%@pt"), "\(Int(MenuBarMarqueeRenderer.font.pointSize))")
        return "\(weight) \(size)"
    }

    /// 「行为」按钮摘要:两个开关里开着的那几个,全开 / 全关给一句概括(`SettingsToggleSummary`,跟另外
    /// 两段编辑台的「行为」按钮同一份归约)。
    private var behaviorSummary: String {
        SettingsToggleSummary.text([
            (title: L10n.t("悬停显示播放控制"), isOn: settings.menuBarHoverShowsControls),
            (title: L10n.t("无歌词时显示歌名"), isOn: settings.menuBarShowsTitleWhenNoLyrics),
        ])
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
        case layout
        case color
        case font
        /// 2026-09-07 加,独占工具栏第二行。见 `toolbarRow2`。
        case behavior
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
        case .layout: MenuBarLayoutPopover()
        case .color: MenuBarColorPopover()
        case .font: MenuBarFontPopover()
        case .behavior: MenuBarBehaviorPopover()
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
                // SteppedSlider 而不是原生带步长的构造器:后者会在轨道下面画一排刻度点
                // (2026-09-02 用户点名「没有意义,不好看」),量化语义一模一样。
                SteppedSlider(value: Binding(
                    get: { Double(settings.menuBarLyricsWidth) },
                    set: {
                        // 量化到 10 的整数倍,理由同悬浮歌词/灵动岛宽度滑杆同款注释:相等
                        // 守卫避免拖动中间态频繁触发无意义的 didSet。
                        // (SteppedSlider 外面已经量化过一道,这里留着是因为 set 也可能被
                        //  别的写入路径调到 —— 幂等,再 round 一次不改变结果。)
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

extension MenuBarLyricsIconPosition {
    /// 三个选项名直接复用灵动岛「歌词行 → 封面位置」那组现成词条(不显示/左/右)——
    /// 那也是一个"要不要显示、显示在哪一侧"的三选一,语义逐字相同,没必要另造一套说法。
    var displayName: String {
        switch self {
        case .off: return L10n.t("不显示")
        case .leading: return L10n.t("左")
        case .trailing: return L10n.t("右")
        }
    }
}

/// 「歌词旁的图标」行(2026-09-03)—— 在歌词那一格的最左或最右放一枚菜单栏图标,图标上的
/// 染色从下往上涨,表示当前这首歌的播放进度。用户点名"仿照酷狗菜单栏歌词"加的。
///
/// 控件用**系统** `.pickerStyle(.segmented)`,不是手搓那个 `LyricsAlignmentSegmentedControl`。
/// 那个手搓件存在的理由是 `NSSegmentedControl` 会按**当前选中段的文字**重新量宽度、于是
/// "选了哪个选项控件整体就多宽"(为此修过三轮,见它的头注);这里三个标签是 3/1/1 个字
/// (英文 Nothing/Left/Right),差得比「左对齐/居中/右对齐」小得多,而且它上面那一行
/// 「宽度模式」用的就是系统 segmented picker —— 同一个浮层里两行控件长得不一样反而更怪。
/// (selftest 还有一条机械闸钉住手搓对齐控件只许有两份,复制第三份本来也过不了。)
struct MenuBarLyricsIconRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "chart.bar.fill",
            title: L10n.t("歌词旁的图标"),
            help: L10n.t("在歌词一格的最左或最右放一枚菜单栏图标，图标颜色从下往上涨表示播放进度：涨上来的用「已唱到」色，其余用「未唱到」色。只在显示歌词时出现。")
        ) {
            Picker("", selection: $settings.menuBarLyricsIconPosition) {
                ForEach(MenuBarLyricsIconPosition.allCases, id: \.self) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

/// 「悬停显示播放控制」行(2026-09-03)—— 鼠标停在菜单栏歌词上时,歌词收掉、换成
/// 「上一曲 / 播放暂停 / 下一曲」三个键。用户点名仿酷狗菜单栏。
///
/// 这是个**行为**开关。2026-09-03~09-07 它寄住在「布局」浮层里(第一行工具栏的横向预算已经用尽,
/// 不值得为一个开关新开第四个入口;当时写着"真要再来第二个行为开关,那时候一起拆一个「行为」
/// 浮层出来")—— 第二个(「无歌词时显示歌名」)09-04 就来了,2026-09-07 按用户"不要这一个那一个"
/// 的要求拆出了工具栏第二行的「行为」浮层(`MenuBarBehaviorPopover`),两项都搬了过去。
///
/// 在「重置 ▾」范围内(2026-09-03 用户拍板"这部分所有配置都改为默认,除了宽度"),见
/// `MenuBarStyleDefaults`。
struct MenuBarHoverControlsRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "playpause.circle",
            title: L10n.t("悬停显示播放控制"),
            help: L10n.t("鼠标移到菜单栏歌词上换成「上一曲 / 播放暂停 / 下一曲」三个键，移开变回。暂停、间奏、或那一格太窄时不接管。点键以外的地方仍是打开面板。")
        ) {
            Toggle("", isOn: $settings.menuBarHoverShowsControls)
        }
    }
}

/// 「无歌词时显示歌名」行(2026-09-04,借鉴清单 #28)。跟上面「悬停显示播放控制」同住「行为」浮层
/// 与「全部设置」抽屉「行为」组(2026-09-07 前两项都在「布局」里):它管的也是"这一格在什么状态下
/// 显示什么",不是样式。判据在 Core
/// (`MenuBarSlotPolicy.displayText`),help 里把三条边界(暂停仍缩回 / 广告不显示 / 歌词一到就换)说清。
/// 进「重置 ▾」——2026-09-03 漏过两项被用户当场看出来,见 `MenuBarStyleDefaults` 头注。
struct MenuBarTitleFallbackRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "music.note.list",
            title: L10n.t("无歌词时显示歌名"),
            help: L10n.t("这首歌没有歌词或还在搜索时，用「♪ 歌名」占住歌词的位置，不缩回小图标；歌词一到就换成歌词。暂停时仍缩回图标，广告中不显示")
        ) {
            Toggle("", isOn: $settings.menuBarShowsTitleWhenNoLyrics)
        }
    }
}

// MARK: - 恢复默认

/// 「重置」按钮的动作本体——把工具栏四个浮层(布局 / 配色 / 字体 / 行为)里的**每一项**恢复默认。
///
/// **只排除两样**(2026-09-03 用户拍板:"这里的重置需要把这部分所有配置都改为默认,除了宽度"):
///  - `menuBarLyricsWidth`(最大宽度)—— 用户点名要留;它也是唯一一项常驻在舞台上、不在
///    任何浮层里的设置,排除它跟"重置四个浮层"这个范围自洽;
///  - `showLyricsInMenuBar`(总开关)—— 它不在工具栏管辖范围内(单独一张卡在编辑台下面),
///    而且一颗样式重置按钮顺手把整个功能关掉是危险且反直觉的。两个排除跟悬浮歌词/灵动岛
///    那两颗「重置」的取舍一致,菜单里那句"不含宽度和总开关"说的就是这两样。
///
/// ⚠️ **新增设置项时记得同步加进来**:这个函数漏一项不会报错,表现是"点了重置有一项没变",
/// 用户很难判断是漏了还是本来就不该变。2026-09-03 就漏过两项(歌词旁的图标、悬停显示播放
/// 控制)——它们加进「布局」浮层时没同步这里,被用户当场看出来。
/// 默认值只在 `AppSettings.defaultMenuBarXxx` 里出现一次,`AppSettings.init()` 的 fallback
/// 和这里读的是同一份常量。
@MainActor
enum MenuBarStyleDefaults {
    static func restoreDefaults() {
        let settings = AppSettings.shared
        // 「布局」浮层
        settings.menuBarLyricsWidthMode = AppSettings.defaultMenuBarLyricsWidthMode
        settings.menuBarLyricsAlignment = AppSettings.defaultMenuBarLyricsAlignment
        settings.menuBarSecondaryLine = AppSettings.defaultMenuBarSecondaryLine
        settings.menuBarLyricsIconPosition = AppSettings.defaultMenuBarLyricsIconPosition
        // 「配色」浮层
        settings.menuBarLyricsKaraoke = AppSettings.defaultMenuBarLyricsKaraoke
        settings.menuBarLyricsTextColorHex = AppSettings.defaultMenuBarLyricsTextColorHex
        settings.menuBarLyricsFillColorHex = AppSettings.defaultMenuBarLyricsFillColorHex
        // 「字体」浮层
        settings.menuBarLyricsFontWeight = AppSettings.defaultMenuBarLyricsFontWeight
        settings.menuBarLyricsFontSize = AppSettings.defaultMenuBarLyricsFontSize
        // 「行为」浮层(2026-09-07 从「布局」拆出来)
        settings.menuBarHoverShowsControls = AppSettings.defaultMenuBarHoverShowsControls
        settings.menuBarShowsTitleWhenNoLyrics = AppSettings.defaultMenuBarShowsTitleWhenNoLyrics
    }
}

// MARK: - 「布局」浮层

/// 「布局」组的行(浮层与抽屉同一份,2026-09-07):宽度模式(+ 固定宽度下的对齐方式)→ 副行 → 歌词旁的图标。
/// 三样都是"这一格怎么占位":占多宽、排几行、旁边有没有图标。「副行」从「字体」搬过来 —— 悬浮歌词的
/// 「双行显示」在「排版」、灵动岛的「副行」在「歌词行」,三个面上"排几行"都归版面,不归字形;它顺带让
/// 「字号」失效这件事由「字号」那一行自己说(`MenuBarFontSizeRow`)。悬停 / 无歌词两颗行为开关同日
/// 搬去了 `MenuBarBehaviorRows`。
struct MenuBarLayoutRows: View {
    var body: some View {
        VStack(spacing: 0) {
            MenuBarWidthModeRow()
            CardDivider()
            MenuBarSecondaryLineRow()
            CardDivider()
            MenuBarLyricsIconRow()
        }
    }
}

/// 「布局」浮层 —— 内容就是 `MenuBarLayoutRows`。
///
/// ⚠️ 宽度 2026-09-03 从 430 放宽到 470。430 是当初为**宽度模式那一行**离屏量出来的
/// (中文 370.0 / 英文 414.0),而新加的「歌词旁的图标」行标题更长、尾部是个三段选择器 ——
/// 按同样的字数比例估英文大约 460pt,压着 430 会重演当时那个坑:`SettingsRow` 的尾部控件
/// `.fixedSize()` 之后容器一窄,SwiftUI 把亏空全摊给**标题**,标题被压没只剩一个 "?"。
/// 这个数是**估的、没离屏量过**,但估宽的方向是安全的那一侧(浮层宽一点只是留白多一点,
/// 窄了才会画坏);真要收紧回去,先按 `MenuBarWidthModeRow` 头注那条方法论量一次再改。
struct MenuBarLayoutPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("布局"), width: 470) {
            MenuBarLayoutRows()
        }
    }
}

/// 「行为」组的行(2026-09-07 从「布局」拆出来;浮层与抽屉同一份):悬停显示播放控制 / 无歌词时显示歌名。
/// 两项都是"这一格在什么状态下显示什么",不是样式 —— 跟另外两段编辑台的「行为」入口同一条判据。
struct MenuBarBehaviorRows: View {
    var body: some View {
        VStack(spacing: 0) {
            MenuBarHoverControlsRow()
            CardDivider()
            MenuBarTitleFallbackRow()
        }
    }
}

/// 工具栏第二行「行为」浮层(2026-09-07)。
///
/// ⚠️ 宽度 420 跟另外两段的「行为」浮层同宽(三个形态的「行为」看起来是一件东西),也够用:最宽一行
/// 是英文 "Show Title When No Lyrics" 161.3pt + ⓘ 19 + `SettingsRow` 固定开销 150(2×14 内边距 + 20 图标列
/// + 3×12 间距 + 12 Spacer + 54 开关)= 330(中文「悬停显示播放控制」103.2 + 19 + 150 = 272),13pt 系统字
/// 实测文字宽算的。
struct MenuBarBehaviorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("行为"), width: 420) {
            MenuBarBehaviorRows()
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
///      多余的装饰。改用 `SettingsRow(icon:)`——跟 `NotchBehaviorItem`/`NotchBehaviorToggleRow`
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
            help: L10n.t("只影响装得下的句子。\n固定：短句也占满设定宽度，位置不变。\n自适应：短句按自己的宽度占位，这一项随句变宽变窄，旁边的图标跟着挪。")
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
        // 恒无效果的控件比不摆更糟。完整判据见 LyricsRestingAlignment 头注。
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
            // 跟灵动岛「对齐方式」共用同一个控件(2026-09-03 搬到 UI/
            // LyricsAlignmentSegmentedControl.swift,原来长在这个文件里)。
            LyricsAlignmentSegmentedControl(selection: $settings.menuBarLyricsAlignment,
                                            options: LyricsRestingAlignment.menuBarOptions)
        }
    }
}

// MARK: - 「配色」浮层

/// 「配色」浮层:只放三行颜色。「粗细」2026-09-03 当天先放在这里头一行、几分钟后按用户要求
/// 挪成工具栏第三个入口(`MenuBarFontPopover`),这里不再混进非颜色的项。
struct MenuBarColorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("配色"), width: 330) {
            MenuBarColorRows()
        }
    }
}

/// 「字体」组的行(浮层与抽屉同一份,2026-09-07):「粗细」+「字号」,跟悬浮歌词「文字」浮层里那两行同款
/// 控件。「副行」2026-09-06 曾放在这一组第三行(它让字号失效,当时想让因果同屏),2026-09-07 搬去「布局」
/// —— 它首先是"排几行"的版面问题;因果同屏改由「字号」那一行自己交代(副行开着时尾部写「由副行决定」)。
struct MenuBarFontRows: View {
    var body: some View {
        VStack(spacing: 0) {
            MenuBarFontWeightRow()
            CardDivider()
            MenuBarFontSizeRow()
        }
    }
}

/// 「字体」浮层(2026-09-03):内容就是 `MenuBarFontRows`。
/// 宽度用 `SettingsPopoverShell` 的默认 380 —— 那正是悬浮歌词「文字」浮层(同样装着字号滑杆
/// 150 + 读数 46 那一行)量出来的值;字号这一行英文标题 Font Size 加滑杆比「配色」的三行都宽,
/// 330 不够。真要收窄先按 `MenuBarWidthModeRow` 头注那条方法论量一次。
struct MenuBarFontPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("字体")) {
            MenuBarFontRows()
        }
    }
}

/// 「副行」行(2026-09-06,借鉴清单 #57,用户在五档 HTML 对比里选 B 方案:主 10pt / 副 9pt)—— 主歌词下面
/// 再放一行,内容四选一(不显示 / 下一句 / 译文 / 罗马音),跟灵动岛「歌词行 → 副行」同一个枚举、同一套
/// 显示名(`LyricSecondaryLine.displayName`)、同一个控件形态(`Picker(.menu)`),只是各存各的键,默认不显示。
///
/// 2026-09-06 放在「字体」浮层(它让字号失效,想让因果同屏);2026-09-07 搬到「布局」—— 它首先是
/// "排几行"的版面问题,悬浮歌词的「双行显示」在「排版」、灵动岛的「副行」在「歌词行」,三个面取齐;
/// 字号那边的因果由 `MenuBarFontSizeRow` 自己交代(副行开着时尾部写「由副行决定」)。
/// 进「重置 ▾」(`MenuBarStyleDefaults`)。
struct MenuBarSecondaryLineRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.append",
            title: L10n.t("副行"),
            help: L10n.t("主歌词下方多一行，高度不变（两行 10pt / 9pt，「字号」不生效）。译文和罗马音显示当前句，「下一句」显示接下来那句、主行不再提前切。副行不滚动，装不下时尾部渐隐。")
        ) {
            Picker("", selection: $settings.menuBarSecondaryLine) {
                ForEach(LyricSecondaryLine.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// 「字号」行(2026-09-03,用户:「帮我再加上字体大小吧」)。滑杆显示的是**生效字号**(跟随系统时就是
/// 系统那格,本机 13),范围 `MenuBarMarqueeRenderer.fontSizeRange`(10…16,上限由状态栏项 22pt 高
/// 推出,见那边注释)。拖回系统字号那一格时**存 0**(跟随)而不是那个数字,这样没有单独的「跟随系统」
/// 按钮也保住了语义,浮层宽度也不用为多一颗按钮重量。
///
/// 用 `SteppedSlider` 而不是原生带 step 的 Slider,理由同悬浮歌词「字号」行:后者会在轨道下画一排
/// 刻度点。相等守卫同样不能省:拖动中每个鼠标事件都会调 set,量化后大量等值赋值照样广播
/// objectWillChange,菜单栏那边订阅着这个值、每次都会 refresh()。
struct MenuBarFontSizeRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "textformat.size",
            title: L10n.t("字号"),
            help: L10n.t("默认跟随系统菜单栏，可在 10～16pt 间调，16pt 仍在菜单栏项高度内。拖回系统字号那一格即恢复跟随。")
        ) {
            // 副行开着时两行字号由行高推出(10 / 9pt,见 MenuBarLyricRows),滑杆翻了也没效果 —— 2026-09-06~07
            // 之间这一行是整行隐藏的;「副行」搬去「布局」浮层之后,这里再藏整行就成了"字号去哪了",
            // 改成行留着、尾部换一句灰字「由副行决定」指向原因(跟悬浮歌词「文字颜色」在跟随封面时的做法
            // 同款)。这是**值**的位置,不是可点的控件。
            if settings.menuBarSecondaryLine.showsSecondaryRow {
                Text(L10n.t("由副行决定"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    SteppedSlider(value: Binding(
                        get: { Double(MenuBarMarqueeRenderer.font.pointSize) },
                        set: { newValue in
                            let range = MenuBarMarqueeRenderer.fontSizeRange
                            let quantized = min(max(CGFloat(newValue.rounded()), range.lowerBound), range.upperBound)
                            let stored: CGFloat = quantized == MenuBarMarqueeRenderer.systemPointSize ? 0 : quantized
                            guard stored != settings.menuBarLyricsFontSize else { return }
                            settings.menuBarLyricsFontSize = stored
                        }
                    ), in: Double(MenuBarMarqueeRenderer.fontSizeRange.lowerBound)...Double(MenuBarMarqueeRenderer.fontSizeRange.upperBound), step: 1)
                        .frame(width: 150)
                    Text(String(format: L10n.t("%@pt"), "\(Int(MenuBarMarqueeRenderer.font.pointSize))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}

/// 「粗细」行(2026-09-03):菜单栏歌词的字重。字体族 / 字号继续跟系统菜单栏 —— 06 章「字体跟随
/// 系统」那条决策只放开了粗细这一维(行高不变、中文不变宽,数据见 MenuBarMarqueeRenderer.font)。
///
/// 控件跟悬浮歌词那行(OverlayStyleSettingsRows「粗细」)完全一致:同一个六档枚举、同一套显示名、
/// 同样用下拉而不是分段 —— 六个中文标签分段放不下,而且两处形态一致比"菜单栏这边手搭分段"
/// 重要。标题复用「粗细」词条(不叫「字重」,理由见那边的注释)。`.fixedSize()` 同样不能省
/// (已知坑第 15 条:SettingsRow 的 HStack 均分剩余宽度,下拉会被压到截掉最长选项)。
struct MenuBarFontWeightRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "bold",
            title: L10n.t("粗细"),
            help: L10n.t("菜单栏歌词的笔画粗细。字体族继续跟随系统菜单栏，「常规」就是系统菜单栏本来的粗细；中文只变粗不变宽，英文越粗越宽一点")
        ) {
            Picker("", selection: $settings.menuBarLyricsFontWeight) {
                ForEach(OverlayFontWeight.allCases, id: \.self) { weight in
                    Text(weight.displayName).tag(weight)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
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
    /// 两个色块画的是**菜单栏上**那个颜色,菜单栏由亮转暗时要跟着重画。
    @ObservedObject private var menuBarAppearance = MenuBarAppearanceStore.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(
                icon: "text.word.spacing",
                // 「逐字染色」→「卡拉OK染色」(2026-09-01,用户要求"改专业一点、和软件其他
                // 地方对齐")→「卡拉OK效果」(2026-09-06)。本仓面向用户的术语一直是**卡拉OK**,
                // 英文侧一直是 "Karaoke fill"。
                //
                // 09-06 之前它跟「歌词 → 效果」里那颗全局「卡拉OK效果」是**两层**(那个决定引擎要不要
                // 用逐字数据,这个决定菜单栏要不要跟着染),名字相近是想让这层关系看得出来。全局那颗
                // 已撤、拆成悬浮歌词 / 灵动岛 / 菜单栏各一颗,三个面同一个词 —— 这颗就是菜单栏那一份,
                // 也是菜单栏(状态栏项 + 面板里那行歌词)逐字填色**唯一**的闸。
                title: L10n.t("卡拉OK效果"),
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
                    // ⚠️ 色块必须画**菜单栏上那个颜色**,不是设置窗口里解析出来的那个
                    // (2026-09-03 用户报:菜单栏上明明是白字,这个块是黑的)。`labelColor`
                    // 是动态色,在浅色的设置窗口里求值就是黑 —— 所以取值走
                    // `MenuBarScrollingLabel.textColor`(跟真正渲染同一份口径)再
                    // `resolved(in: 菜单栏的 appearance)` 定型。详见 MenuBarAppearanceStore。
                    ColorPicker("", selection: Binding(
                        get: {
                            Color(nsColor: MenuBarScrollingLabel
                                .textColor(hex: settings.menuBarLyricsTextColorHex,
                                           highlighted: false)
                                .resolved(in: menuBarAppearance.appearance))
                        },
                        set: { settings.menuBarLyricsTextColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: false)
                }
            }
            // ⚠️ 显示条件 2026-09-03 加了后半句:这个色**还**是歌词旁那枚进度图标上"涨上来"
            // 那一截的颜色。只看卡拉OK染色开关的话,"染色关掉 + 图标开着"的用户会看不到这一行,
            // 却又确实被它影响 —— 一个在起作用、却在设置里找不到的颜色。
            if settings.menuBarLyricsKaraoke || settings.menuBarLyricsIconPosition != .off {
                CardDivider()
                SettingsRow(
                    icon: "paintpalette.fill",
                    // 「染色颜色」→「已唱到的颜色」:原来那个词组自己打结("染色"已经含"色"),
                    // 而且没说清染的是哪一半。它的 help 一直写着"已唱到部分的颜色" —— 标题
                    // 直接用 help 里那句话,跟上面「未唱到的颜色」成对。
                    title: L10n.t("已唱到的颜色"),
                    help: L10n.t("已唱到部分的颜色，也是歌词旁那枚图标上进度涨上来那一截的颜色。默认跟随系统强调色（深色菜单栏自动提亮）；自定义后原样使用、不再自动提亮")
                ) {
                    HStack(spacing: 8) {
                        if !settings.menuBarLyricsFillColorHex.isEmpty {
                            Button(L10n.t("跟随系统")) { settings.menuBarLyricsFillColorHex = "" }
                        }
                        // 同上一行:走渲染那份口径 + 按菜单栏的明暗定型。这一个还多一层
                        // ——「跟随系统」时深色菜单栏上要向白提亮四成,不这么取的话色块画的是
                        // 未提亮的原始强调色,跟菜单栏上看到的差一截。
                        ColorPicker("", selection: Binding(
                            get: {
                                Color(nsColor: MenuBarScrollingLabel
                                    .fillColor(hex: settings.menuBarLyricsFillColorHex,
                                               darkMenuBar: menuBarAppearance.isDark)
                                    .resolved(in: menuBarAppearance.appearance))
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

/// 菜单栏歌词的「全部设置」抽屉(2026-09-01)。**分组、顺序、标题跟工具栏四个入口一一对应**(2026-09-07
/// 起:布局 → 配色 → 字体 → 最大宽度 → 行为 → 恢复默认;每一组调的是浮层背后同一份 `MenuBarXxxRows`)。
/// 2026-09-01~09-07 之间是十一项单组平铺、顺序跟工具栏也对不上("项数少,分组反而是多余的层级"),
/// 用户按工具栏的记忆到抽屉里找会落空 —— 三段编辑台的抽屉这次统一成"工具栏的镜像"。「最大宽度」不属于
/// 任何一组(舞台上那条常驻调整条的兜底副本,跟灵动岛 / 悬浮歌词抽屉里的宽度滑杆同一个摆法)。
/// 默认折叠,理由同另外两个抽屉:键盘/VoiceOver 全量兜底通路,不是新配置项的收纳盒。
struct MenuBarAllSettingsDrawer: View {
    @State private var isExpanded = false
    /// 设置搜索命中了这个抽屉里的行时的"该展开了"信号(理由与写法同 `OverlayAllSettingsDrawer`)。
    @Environment(\.settingsSearchPendingDrawer) private var pendingSearchDrawer

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()
                group(L10n.t("布局")) { MenuBarLayoutRows() }
                CardDivider()
                group(L10n.t("配色")) { MenuBarColorRows() }
                CardDivider()
                group(L10n.t("字体")) { MenuBarFontRows() }
                CardDivider()
                MenuBarWidthRow()
                CardDivider()
                group(L10n.t("行为")) { MenuBarBehaviorRows() }
                CardDivider()
                resetRow
            }
        }
        .onAppear { expandForSearchIfNeeded() }
        .onChange(of: pendingSearchDrawer) { _, _ in expandForSearchIfNeeded() }
    }

    private func expandForSearchIfNeeded() {
        guard pendingSearchDrawer == .menuBar else { return }
        if !isExpanded {
            withAnimation(.settingsCardReveal) { isExpanded = true }
        }
        SettingsSearchRouter.shared.consumeDrawer(.menuBar)
    }

    /// 一组:标题行 + 分隔线 + 内容。标题文案跟工具栏对应那颗按钮用同一个词条(同 `NotchAllSettingsDrawer.group`)。
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Group {
            SettingsCardHeader(title: title)
            CardDivider()
            content()
        }
    }

    /// 「恢复默认布局、配色、字体与行为」——抽屉里的兜底入口(2026-09-03 补;2026-09-07 随「行为」入口改名)。
    ///
    /// 动作本体跟工具栏那颗「重置 ▾」是**同一个函数**(`MenuBarStyleDefaults.restoreDefaults()`)。
    /// 补这一行的理由、以及"两个入口的标题/副标题必须一字不差"这条,见灵动岛那份
    /// `NotchAllSettingsDrawer.resetRow`(SettingsView.swift)与悬浮歌词那份
    /// `OverlayAllSettingsDrawer.resetRow` —— 抽屉是键盘 / VoiceOver 的全量兜底通路,
    /// 工具栏那颗是 SwiftUI `Menu`,不能只有它。
    private var resetRow: some View {
        SettingsRow(
            icon: "arrow.uturn.backward",
            title: L10n.t("恢复默认"),
            subtitle: L10n.t("不含宽度和总开关")
        ) {
            Button(L10n.t("恢复")) { MenuBarStyleDefaults.restoreDefaults() }
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
