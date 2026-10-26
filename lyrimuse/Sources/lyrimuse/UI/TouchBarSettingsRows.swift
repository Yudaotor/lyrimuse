import LyrimuseCore
import SwiftUI

// 「歌词显示 › 触控栏」那一段的编辑台:预览上面一行工具栏(歌词 / 样式 / 布局 / 行为四个浮层 + 「重置 ▾」),预览下面是总开关卡和
// 默认折叠的「全部设置」抽屉。浮层和抽屉装配同一份行视图(`TouchBarLyricsRows` / `TouchBarStyleRows` / `TouchBarLayoutRows` /
// `TouchBarBehaviorRows`),四组的顺序和标题两边一致。预览上点歌词那一格、封面、三键这些也能打开对应的浮层(`TouchBarPreviewStage`,弹的是同一份
// `TouchBarSettingsGroup.popoverContent`),工具栏照歌词窗口那一段摆在预览上面。

/// 工具栏的四个入口,也是抽屉里四组的顺序。
enum TouchBarSettingsGroup: CaseIterable {
    case lyrics
    case style
    case layout
    case behavior

    var title: String {
        switch self {
        case .lyrics: return L10n.t("歌词")
        case .style: return L10n.t("样式")
        case .layout: return L10n.t("布局")
        case .behavior: return L10n.t("行为")
        }
    }

    var icon: String {
        switch self {
        case .lyrics: return "text.alignleft"
        case .style: return "paintpalette"
        case .layout: return "rectangle.split.3x1"
        case .behavior: return "switch.2"
        }
    }
}

extension TouchBarSettingsGroup {
    /// 这一组的浮层:工具栏那颗按钮和预览上对应的那块可点区域(`TouchBarPreviewStage`)弹的是同一份。
    /// 浮层宽度按内容估、宁宽勿窄(`SettingsPopoverShell.width` 那条)。没离屏量过,要收紧先量。
    @MainActor @ViewBuilder
    func popoverContent() -> some View {
        switch self {
        // 「歌词」520:对齐方式四档胶囊分段 + 不折行的行名。
        case .lyrics: SettingsPopoverShell(title: title, width: 520) { TouchBarLyricsRows() }
        case .style: SettingsPopoverShell(title: title, width: 520) { TouchBarStyleRows() }
        // 「布局」四个开关两列小块、封面和三键的左 / 右下拉挂在小块里;「行为」三个开关两列。
        // 别排成一行三格:要 780 宽,浮层伸出设置窗口外。
        case .layout: SettingsPopoverShell(title: title, width: 680) { TouchBarLayoutRows() }
        case .behavior: SettingsPopoverShell(title: title, width: 580) { TouchBarBehaviorRows() }
        }
    }
}

// MARK: - 四组行视图

/// 「歌词」组:副行 → 字号 → 对齐方式。字号紧跟在副行下面:副行开着时两行的字号由触控栏的高定(14 / 11pt,见
/// `TouchBarLyricsStyle`),滑杆拨了也没效果,行留着、尾部换成一句灰字「由副行决定」(同菜单栏「字号」那一行)。
struct TouchBarLyricsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRowGroup {
            VStack(spacing: 0) {
                // 四选一同灵动岛 / 菜单栏的「副行」(同一个枚举、同一套显示名),各存各的键,默认「下一句」。
                SettingsRow(icon: "text.append", title: L10n.t("副行"),
                            help: L10n.t("在主行下方增加一行：译文和读音对应当前句，「下一句」为即将演唱的歌词。开启后两行字号固定为 14pt / 11pt，「字号」不生效，主行也不再提前切换到下一句；副行空间不足时，按该句时长横向滚动")) {
                    SettingsGlassMenuPicker(
                        selection: $settings.touchBarSecondaryLine,
                        options: LyricSecondaryLine.allCases,
                        label: \.displayName,
                        compact: true
                    )
                    .fixedSize()
                }
                CardDivider()
                SettingsRow(icon: "textformat.size", title: L10n.t("字号")) {
                    if settings.touchBarSecondaryLine.showsSecondaryRow {
                        Text(L10n.t("由副行决定"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            SteppedSlider(value: Binding(
                                get: { TouchBarLyricsStyle.clampedFontSize(settings.touchBarLyricsFontSize) },
                                set: { newValue in
                                    guard newValue != settings.touchBarLyricsFontSize else { return }
                                    settings.touchBarLyricsFontSize = newValue
                                }
                            ), in: TouchBarLyricsStyle.fontSizeRange, step: 1)
                            .frame(width: 150)
                            Text(String(format: L10n.t("%@pt"),
                                        "\(Int(TouchBarLyricsStyle.clampedFontSize(settings.touchBarLyricsFontSize)))"))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }
                CardDivider()
                // 同灵动岛「对齐方式」那四档(含按对唱声部走的「自动」),说明文案也是同一条。
                SettingsRow(icon: "text.alignleft", title: L10n.t("对齐方式"),
                            help: L10n.t("仅作用于可完整显示的句子，需横向滚动的句子不受影响。「自动」按对唱声部对齐：各声部靠向各自一侧，合唱居中，无对唱信息时靠左对齐")) {
                    LyricsAlignmentSegmentedControl(selection: $settings.touchBarLyricsAlignment,
                                                    options: LyricsRestingAlignment.notchOptions)
                }
            }
        }
    }
}

/// 「样式」组:卡拉OK效果、歌词颜色(白色 / 跟随封面 / 自定义,自定义时挂色块)、暗部亮度。底色恒黑,自选色照原色画,
/// 没唱到的部分和副行仍有亮度下限(17 章决策 30、51)。系统开了「减弱动态效果」时卡拉OK效果那一行多一句副标题,
/// 说明这时不逐字填色(17 章决策 43)。
struct TouchBarStyleRows: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsRowGroup {
            VStack(spacing: 0) {
                SettingsRow(
                    icon: "sparkles",
                    title: L10n.t("卡拉OK效果"),
                    subtitle: reduceMotion ? L10n.t("系统已开启「减弱动态效果」，触控栏歌词不滚动、不逐字高亮") : nil,
                    help: L10n.t("逐字歌词随演唱逐字高亮；无逐字数据的歌曲整行高亮")
                ) {
                    Toggle("", isOn: $settings.touchBarLyricsKaraoke)
                }
                CardDivider()
                SettingsRow(icon: "paintpalette", title: L10n.t("歌词颜色"),
                            subtitle: settings.touchBarLyricsColorMode == .cover
                                ? L10n.t("歌词使用封面主色；无法获取时为白色") : nil) {
                    HStack(spacing: 8) {
                        SettingsGlassTabPicker(
                            selection: $settings.touchBarLyricsColorMode,
                            options: TouchBarLyricsColorMode.allCases,
                            label: \.displayName,
                            compact: true
                        )
                        .fixedSize()
                        if settings.touchBarLyricsColorMode == .custom {
                            AppColorPicker(selection: Binding(
                                get: {
                                    Color(nsColor: TouchBarLyricsCell.lyricColor(
                                        mode: .custom, coverAccent: nil, customHex: settings.touchBarLyricsColorHex))
                                },
                                set: { settings.touchBarLyricsColorHex = $0.hexStringWithAlpha }
                            ), supportsOpacity: false)
                        }
                    }
                }
                CardDivider()
                SettingsRow(icon: "sun.max", title: L10n.t("暗部亮度"),
                            subtitle: L10n.t("未唱部分与副行的亮度")) {
                    HStack(spacing: 8) {
                        SteppedSlider(value: Binding(
                            get: { TouchBarLyricsStyle.clampedDimLevel(settings.touchBarLyricsDimLevel) },
                            set: { newValue in
                                guard newValue != settings.touchBarLyricsDimLevel else { return }
                                settings.touchBarLyricsDimLevel = newValue
                            }
                        ), in: TouchBarLyricsStyle.dimLevelRange, step: 0.05)
                        .frame(width: 150)
                        Text(verbatim: "\(Int((TouchBarLyricsStyle.clampedDimLevel(settings.touchBarLyricsDimLevel) * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// 「布局」组:封面、播放控制各自显不显示、摆在歌词哪一边(`TouchBarSide`,两项各管各的,开着那一块才挂左 / 右下拉),
/// 「⋯」键,展开时隐藏功能栏,以及去系统设置里调功能栏的入口。
struct TouchBarLayoutRows: View {
    @ObservedObject private var settings = AppSettings.shared

    // 四个开关两列小块(封面、三键开着时左 / 右下拉挂在那一块上),去系统设置那一行单独一框。说明都收进 ⓘ:
    // 往上弹的浮层只有按钮上方约 200pt,一行一个开关加副标题放不下。
    var body: some View {
        SettingsRowGroupStack {
            SettingsTileGrid {
                SettingsToggleTile(icon: "photo", title: L10n.t("显示封面"), isOn: $settings.touchBarShowsArtwork) {
                    if settings.touchBarShowsArtwork {
                        TouchBarSidePicker(selection: $settings.touchBarArtworkSide)
                            .help(L10n.t("封面位置"))
                            .settingsSearchHighlight(title: L10n.t("封面位置"))
                    }
                }
                SettingsToggleTile(icon: "playpause.fill", title: L10n.t("显示播放控制"),
                                   help: L10n.t("上一首、播放/暂停、下一首和设置键"),
                                   isOn: $settings.touchBarShowsControls) {
                    if settings.touchBarShowsControls {
                        TouchBarSidePicker(selection: $settings.touchBarControlsSide)
                            .help(L10n.t("播放控制位置"))
                            .settingsSearchHighlight(title: L10n.t("播放控制位置"))
                    }
                }
                // 最右端那颗「⋯」键,点一下换成「更多」那一页(17 章决策 47)。
                SettingsToggleTile(icon: "ellipsis.circle", title: L10n.t("显示「更多」键"),
                                   help: L10n.t("点按后切换到播放进度、歌词校准、喜欢、随机/循环和音量；当前播放器不支持的项不显示"),
                                   isOn: $settings.touchBarShowsMoreKey)
                // 占满整条触控栏要连系统的功能栏一起收起,展开期间够不着亮度、音量;默认开(`AppSettings.defaultTouchBarHidesControlStrip`)。
                SettingsToggleTile(icon: "arrow.left.and.right", title: L10n.t("展开时隐藏功能栏"),
                                   help: L10n.t("歌词占满整条触控栏；需要调节亮度、音量等时，请先点按左端的 ✕ 收起歌词"),
                                   isOn: $settings.touchBarHidesControlStrip)
            }
            SettingsRowGroup {
                // 右边那排是系统的功能栏,放哪些按钮由用户在系统设置里调,App 没有接口改。链接带 `TouchBarSettings` 锚点,
                // 直接弹出「触控栏设置…」那一层;不认这个锚点的系统停在「键盘」页,ⓘ 里写着往哪点。见 17 章决策 37。
                SettingsRow(icon: "keyboard", title: L10n.t("系统功能栏"),
                            help: L10n.t("触控栏右侧的亮度、音量等系统按键，可在「系统设置 › 键盘 › 触控栏设置…」中增减或调整顺序")) {
                    Button(L10n.t("打开系统设置")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?TouchBarSettings") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .animation(.default, value: settings.touchBarShowsArtwork)
        .animation(.default, value: settings.touchBarShowsControls)
    }
}

/// 「行为」组:自动展开 / 收起的三个开关(默认都关)。只在情况变的那一刻动一次,手动展开、收起之后保持原样;
/// 怎么判见 Core `TouchBarAutoPresent`(17 章决策 45)。
struct TouchBarBehaviorRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsTileGrid {
            SettingsToggleTile(icon: "play.circle", title: L10n.t("开始播放时自动展开"),
                               help: L10n.t("从暂停恢复播放时展开歌词；播放中切歌不展开，手动收起后保持收起"),
                               isOn: $settings.touchBarExpandOnPlay)
            SettingsToggleTile(icon: "pause.circle", title: L10n.t("暂停时自动收起"),
                               help: L10n.t("暂停 10 秒后收起为功能栏图标，恢复播放时自动展开"),
                               isOn: $settings.touchBarCollapseWhenPaused)
            SettingsToggleTile(icon: "text.badge.xmark", title: L10n.t("纯音乐/无歌词时收起"),
                               help: L10n.t("确认无歌词后才收起，找到歌词后自动展开；搜索期间照常显示"),
                               isOn: $settings.touchBarCollapseWhenNoLyrics)
        }
    }
}

/// 「布局」组里封面、三键的位置控件:摆在歌词左边还是右边(`TouchBarSide`),挂在对应那一块开关上。跟别处从属行里的二选一一样用下拉菜单
/// (同歌词窗口背景的「方向」)。
struct TouchBarSidePicker: View {
    @Binding var selection: TouchBarSide

    var body: some View {
        // 只有左右两档,玻璃分段一眼看全。
        SettingsGlassTabPicker(
            selection: $selection,
            options: TouchBarSide.allCases,
            label: \.displayName,
            compact: true
        )
        .fixedSize()
    }
}

// MARK: - 恢复默认

/// 「重置 ▾」和抽屉里「恢复默认」共用的动作:四组十六项回到默认值,总开关不动。默认值跟 `AppSettings.init()` 的
/// fallback 读同一组常量(`AppSettings.defaultTouchBarXxx`,字号是 Core 的 `TouchBarLyricsStyle.defaultFontSize`)。
@MainActor
enum TouchBarStyleDefaults {
    /// 两个入口的作用范围说明,必须一字不差。
    static var scope: String { L10n.t("不含总开关") }

    static func restoreDefaults() {
        let settings = AppSettings.shared
        // 「歌词」
        settings.touchBarSecondaryLine = AppSettings.defaultTouchBarSecondaryLine
        settings.touchBarLyricsFontSize = TouchBarLyricsStyle.defaultFontSize
        settings.touchBarLyricsAlignment = AppSettings.defaultTouchBarLyricsAlignment
        // 「样式」
        settings.touchBarLyricsKaraoke = AppSettings.defaultTouchBarLyricsKaraoke
        settings.touchBarLyricsColorMode = AppSettings.defaultTouchBarLyricsColorMode
        settings.touchBarLyricsColorHex = AppSettings.defaultTouchBarLyricsColorHex
        settings.touchBarLyricsDimLevel = TouchBarLyricsStyle.defaultDimLevel
        // 「布局」
        settings.touchBarShowsArtwork = AppSettings.defaultTouchBarShowsArtwork
        settings.touchBarArtworkSide = AppSettings.defaultTouchBarArtworkSide
        settings.touchBarShowsControls = AppSettings.defaultTouchBarShowsControls
        settings.touchBarControlsSide = AppSettings.defaultTouchBarControlsSide
        settings.touchBarHidesControlStrip = AppSettings.defaultTouchBarHidesControlStrip
        settings.touchBarShowsMoreKey = AppSettings.defaultTouchBarShowsMoreKey
        // 「行为」
        settings.touchBarExpandOnPlay = AppSettings.defaultTouchBarExpandOnPlay
        settings.touchBarCollapseWhenPaused = AppSettings.defaultTouchBarCollapseWhenPaused
        settings.touchBarCollapseWhenNoLyrics = AppSettings.defaultTouchBarCollapseWhenNoLyrics
    }
}

// MARK: - 工具栏

/// 预览上面那排工具栏:胶囊按钮(图标 · 标题 · 当前值摘要)点开是浮层。一行四颗加右端「重置 ▾」,同灵动岛工具栏第一行;
/// 按钮宽度在这一行里平分,放不下时只压摘要、标题不截(17 章决策 53)。
struct TouchBarEditorToolbar: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var popover: TouchBarSettingsGroup?
    /// 浮层高度上限 = 点开那一刻按钮那一行上沿到屏幕顶的距离(见 toolbarButton)。
    @State private var popoverMaxHeight: CGFloat = SettingsPopoverMetrics.defaultMaxHeight
    @State private var toolbarProbe = StageTopProbe()

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TouchBarSettingsGroup.allCases, id: \.self) { group in
                toolbarButton(group)
            }
            Spacer(minLength: 8)
            EditorToolbarResetMenu(scope: TouchBarStyleDefaults.scope) { TouchBarStyleDefaults.restoreDefaults() }
        }
        .overlay(alignment: .top) { probeAnchor(toolbarProbe) }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
        .editorToolbarGlassGroup()
    }

    /// 按钮那一行上沿的测量点(同悬浮歌词、灵动岛编辑台的 `StageTopProbe`)。
    private func probeAnchor(_ probe: StageTopProbe) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(StageTopProbeView(probe: probe))
    }

    /// 浮层挂在按钮上往上弹(`arrowEdge: .top`),不往下压在预览上;高度封顶在按钮那一行上方的空间里,放不下时在浮层里滚,
    /// 不让系统翻下来(同悬浮歌词、灵动岛编辑台,04 章决策 34、61)。
    private func toolbarButton(_ group: TouchBarSettingsGroup) -> some View {
        Button {
            popoverMaxHeight = toolbarProbe.popoverHeightLimit()
            popover = group
        } label: {
            EditorToolbarButtonLabel(icon: group.icon, title: group.title, summary: summary(for: group))
        }
        .editorToolbarButtonStyle()
        .popover(isPresented: Binding(
            get: { popover == group },
            set: { shown in
                if shown { popover = group } else if popover == group { popover = nil }
            }), arrowEdge: .top) {
            group.popoverContent()
                .environment(\.settingsPopoverMaxHeight, popoverMaxHeight)
        }
    }

    /// 摘要只说偏离默认值的那部分(同灵动岛「歌词行」那颗按钮),拼接用 `ListFormatter`。
    private func summary(for group: TouchBarSettingsGroup) -> String {
        switch group {
        case .lyrics:
            // 副行开着时报副行(两行的字号由触控栏的高定),关着时报字号;对齐方式非默认才报。
            var parts: [String] = []
            if settings.touchBarSecondaryLine.showsSecondaryRow {
                parts.append("\(L10n.t("副行")) · \(settings.touchBarSecondaryLine.displayName)")
            } else {
                parts.append(String(format: L10n.t("%@pt"),
                                    "\(Int(TouchBarLyricsStyle.clampedFontSize(settings.touchBarLyricsFontSize)))"))
            }
            if settings.touchBarLyricsAlignment != AppSettings.defaultTouchBarLyricsAlignment {
                parts.append(LyricsAlignmentSegmentedControl.label(for: settings.touchBarLyricsAlignment))
            }
            return L10n.list(parts)
        case .style:
            // 卡拉OK 开着才报;颜色一直报;暗部亮度非默认才报。
            var parts: [String] = []
            if settings.touchBarLyricsKaraoke { parts.append(L10n.t("卡拉OK")) }
            parts.append(settings.touchBarLyricsColorMode == .custom
                         ? L10n.t("自定义颜色") : settings.touchBarLyricsColorMode.displayName)
            let dim = TouchBarLyricsStyle.clampedDimLevel(settings.touchBarLyricsDimLevel)
            if abs(dim - TouchBarLyricsStyle.defaultDimLevel) > 0.001 {
                parts.append(String(format: L10n.t("暗部 %@"), "\(Int((dim * 100).rounded()))%"))
            }
            return L10n.list(parts)
        case .layout:
            // 只列显示着的;摆在右边(非默认)时带上位置。
            var parts: [String] = []
            if settings.touchBarShowsArtwork {
                parts.append(sided(L10n.t("封面"), settings.touchBarArtworkSide, default: AppSettings.defaultTouchBarArtworkSide))
            }
            if settings.touchBarShowsControls {
                parts.append(sided(L10n.t("播放控制"), settings.touchBarControlsSide, default: AppSettings.defaultTouchBarControlsSide))
            }
            if settings.touchBarShowsMoreKey { parts.append(L10n.t("更多")) }
            if settings.touchBarHidesControlStrip { parts.append(L10n.t("隐藏功能栏")) }
            guard !parts.isEmpty else { return L10n.t("全部关闭") }
            return L10n.list(parts)
        case .behavior:
            return SettingsToggleSummary.text([
                (title: L10n.t("自动展开"), isOn: settings.touchBarExpandOnPlay),
                (title: L10n.t("暂停收起"), isOn: settings.touchBarCollapseWhenPaused),
                (title: L10n.t("无歌词收起"), isOn: settings.touchBarCollapseWhenNoLyrics),
            ])
        }
    }

    private func sided(_ name: String, _ side: TouchBarSide, default defaultSide: TouchBarSide) -> String {
        side == defaultSide ? name : "\(name) · \(side.displayName)"
    }
}

// MARK: - 「全部设置」抽屉

/// 触控栏那一段的「全部设置」抽屉:键盘 / VoiceOver 的全量兜底通路。四组的顺序和标题跟工具栏一致,行视图跟浮层同一份,
/// 最后一行「恢复默认」跟「重置 ▾」同一个动作、同一句作用范围。
///
/// 设置搜索点名了这一段里总开关以外的行就展开:触控栏不是 `LyricsSurface`,用不上 `settingsSearchPendingDrawer`,
/// 同 `LyricsWindowAllSettingsDrawer` 走行高亮;总开关在抽屉外面那张卡上,只点名它时不展开。
struct TouchBarAllSettingsDrawer: View {
    /// 用 @State 不用 @AppStorage,每次打开设置窗口都是折叠的(同另外几个抽屉)。
    @State private var isExpanded = false
    @Environment(\.settingsSearchHighlightedTitles) private var highlightedTitles

    // 展开后一组一张卡(同悬浮歌词、灵动岛抽屉,14 章决策 83、84),最后「恢复默认」单独一张卡。
    var body: some View {
        VStack(spacing: 14) {
            SettingsCard(cornerRadius: 18) {
                disclosureHeader
            }
            if isExpanded {
                SettingsGroupCard(title: TouchBarSettingsGroup.lyrics.title) { TouchBarLyricsRows() }
                SettingsGroupCard(title: TouchBarSettingsGroup.style.title) { TouchBarStyleRows() }
                SettingsGroupCard(title: TouchBarSettingsGroup.layout.title) { TouchBarLayoutRows() }
                SettingsGroupCard(title: TouchBarSettingsGroup.behavior.title) { TouchBarBehaviorRows() }
                SettingsCard(cornerRadius: 18) {
                    SettingsRow(icon: "arrow.uturn.backward", title: L10n.t("恢复默认"),
                                subtitle: TouchBarStyleDefaults.scope) {
                        Button(L10n.t("恢复")) { TouchBarStyleDefaults.restoreDefaults() }
                            .buttonBorderShape(.capsule)
                    }
                }
            }
        }
        .onAppear { expandForSearchIfNeeded() }
        .onChange(of: highlightedTitles) { _, _ in expandForSearchIfNeeded() }
    }

    private func expandForSearchIfNeeded() {
        let toggleTitle = L10n.t(SettingsSearchCatalog.touchBarToggleTitleKey)
        guard !isExpanded, !highlightedTitles.subtracting([toggleTitle]).isEmpty else { return }
        withAnimation(.settingsCardReveal) { isExpanded = true }
    }

    /// 折叠/展开那一行,逐字照 `MenuBarAllSettingsDrawer.disclosureHeader`。
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
                Spacer(minLength: 12)
                if !isExpanded {
                    AllSettingsGroupNames([TouchBarSettingsGroup.lyrics, .style, .layout, .behavior].map(\.title))
                }
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glassRow)
        .accessibilityLabel(L10n.t("全部设置"))
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityValue(isExpanded ? L10n.t("已展开") : L10n.t("已折叠"))
    }
}
