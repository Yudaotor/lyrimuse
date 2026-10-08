import LyrimuseCore
import SwiftUI

// 「歌词显示 › 触控栏」那一段的编辑台:预览上面一排工具栏(歌词 / 样式 / 布局三个浮层 + 「重置 ▾」),预览下面是总开关卡和
// 默认折叠的「全部设置」抽屉。浮层和抽屉装配同一份行视图(`TouchBarLyricsRows` / `TouchBarStyleRows` / `TouchBarLayoutRows`),
// 三组的顺序和标题两边一致。预览上点歌词那一格、封面、三键这些也能打开对应的浮层(`TouchBarPreviewStage`,弹的是同一份
// `TouchBarSettingsGroup.popoverContent`),工具栏照歌词窗口那一段摆在预览上面。

/// 工具栏的三个入口,也是抽屉里三组的顺序。
enum TouchBarSettingsGroup: CaseIterable {
    case lyrics
    case style
    case layout

    var title: String {
        switch self {
        case .lyrics: return L10n.t("歌词")
        case .style: return L10n.t("样式")
        case .layout: return L10n.t("布局")
        }
    }

    var icon: String {
        switch self {
        case .lyrics: return "text.alignleft"
        case .style: return "paintpalette"
        case .layout: return "rectangle.split.3x1"
        }
    }
}

extension TouchBarSettingsGroup {
    /// 这一组的浮层:工具栏那颗按钮和预览上对应的那块可点区域(`TouchBarPreviewStage`)弹的是同一份。
    /// 浮层宽度按内容估、宁宽勿窄(`SettingsPopoverShell.width` 那条)。没离屏量过,要收紧先量。
    @MainActor @ViewBuilder
    func popoverContent() -> some View {
        switch self {
        case .lyrics: SettingsPopoverShell(title: title, width: 460) { TouchBarLyricsRows() }
        case .style: SettingsPopoverShell(title: title, width: 400) { TouchBarStyleRows() }
        case .layout: SettingsPopoverShell(title: title, width: 440) { TouchBarLayoutRows() }
        }
    }
}

// MARK: - 三组行视图

/// 「歌词」组:副行 → 字号 → 对齐方式。字号紧跟在副行下面:副行开着时两行的字号由触控栏的高定(14 / 11pt,见
/// `TouchBarLyricsStyle`),滑杆拨了也没效果,行留着、尾部换成一句灰字「由副行决定」(同菜单栏「字号」那一行)。
struct TouchBarLyricsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // 四选一同灵动岛 / 菜单栏的「副行」(同一个枚举、同一套显示名),各存各的键,默认不显示。
            SettingsRow(icon: "text.append", title: L10n.t("副行"),
                        help: L10n.t("在主歌词下方增加一行（两行分别为 14pt / 11pt，「字号」不生效）。译文和读音对应当前句，「下一句」显示即将演唱的歌词；开启副行时，主行不再提前切换到下一句。副行显示不下时，按该句时长横向滚动。")) {
                Picker("", selection: $settings.touchBarSecondaryLine) {
                    ForEach(LyricSecondaryLine.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
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
                        help: L10n.t("仅影响能完整显示的短句在歌词行中的位置。「自动」按对唱声部对齐：各声部靠向各自一侧，合唱居中，无对唱信息时靠左。显示不下的句子会横向滚动，对齐设置对其无效")) {
                LyricsAlignmentSegmentedControl(selection: $settings.touchBarLyricsAlignment,
                                                options: LyricsRestingAlignment.notchOptions)
            }
        }
    }
}

/// 「样式」组:卡拉OK效果、跟随封面。触控栏底色恒黑,不给配色(见 17 章决策 5)。
struct TouchBarStyleRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(
                icon: "sparkles",
                title: L10n.t("卡拉OK效果"),
                help: L10n.t("逐字歌词随演唱逐字高亮；无逐字数据的歌曲整行高亮")
            ) {
                Toggle("", isOn: $settings.touchBarLyricsKaraoke)
            }
            CardDivider()
            SettingsRow(icon: "paintpalette", title: L10n.t("跟随封面"),
                        subtitle: L10n.t("歌词使用封面的主色，无法获取时使用白色")) {
                Toggle("", isOn: $settings.touchBarLyricsFollowsCover)
            }
        }
    }
}

/// 「布局」组:封面、播放控制各自显不显示、摆在歌词哪一边(`TouchBarSide`,两项各管各的,开着才有那一行位置),
/// 展开时隐藏功能栏,以及去系统设置里调功能栏的入口。
struct TouchBarLayoutRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "photo", title: L10n.t("显示封面")) {
                Toggle("", isOn: $settings.touchBarShowsArtwork)
            }
            if settings.touchBarShowsArtwork {
                CardDivider()
                SettingsSubRow(title: L10n.t("封面位置")) {
                    TouchBarSidePicker(selection: $settings.touchBarArtworkSide)
                }
            }
            CardDivider()
            SettingsRow(icon: "playpause.fill", title: L10n.t("显示播放控制"),
                        subtitle: L10n.t("上一首、播放/暂停、下一首和设置键")) {
                Toggle("", isOn: $settings.touchBarShowsControls)
            }
            if settings.touchBarShowsControls {
                CardDivider()
                SettingsSubRow(title: L10n.t("播放控制位置")) {
                    TouchBarSidePicker(selection: $settings.touchBarControlsSide)
                }
            }
            CardDivider()
            // 占满整条触控栏要连系统的功能栏一起收起,展开期间够不着亮度、音量,所以默认关。
            SettingsRow(icon: "arrow.left.and.right", title: L10n.t("展开时隐藏功能栏"),
                        subtitle: L10n.t("歌词占满整个触控栏；如需使用亮度、音量等系统按键，请先点按左端的 ✕ 收起")) {
                Toggle("", isOn: $settings.touchBarHidesControlStrip)
            }
            CardDivider()
            // 右边那排是系统的功能栏,放哪些按钮由用户在系统设置里调,App 没有接口改。链接带 `TouchBarSettings` 锚点,
            // 直接弹出「触控栏设置…」那一层;不认这个锚点的系统停在「键盘」页,副标题写着往哪点。见 17 章决策 37。
            SettingsRow(icon: "keyboard", title: L10n.t("系统功能栏"),
                        subtitle: L10n.t("触控栏右侧的亮度、音量等系统按键，可在「系统设置 › 键盘 › 触控栏设置…」中增减或调整顺序")) {
                Button(L10n.t("打开系统设置")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?TouchBarSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

/// 「布局」组里两行位置的控件:摆在歌词左边还是右边(`TouchBarSide`)。跟别处从属行里的二选一一样用下拉菜单
/// (同歌词窗口背景的「方向」)。
struct TouchBarSidePicker: View {
    @Binding var selection: TouchBarSide

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(TouchBarSide.allCases, id: \.self) { side in
                Text(side.displayName).tag(side)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

// MARK: - 恢复默认

/// 「重置 ▾」和抽屉里「恢复默认」共用的动作:三组十项回到默认值,总开关不动。默认值跟 `AppSettings.init()` 的
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
        settings.touchBarLyricsFollowsCover = AppSettings.defaultTouchBarLyricsFollowsCover
        // 「布局」
        settings.touchBarShowsArtwork = AppSettings.defaultTouchBarShowsArtwork
        settings.touchBarArtworkSide = AppSettings.defaultTouchBarArtworkSide
        settings.touchBarShowsControls = AppSettings.defaultTouchBarShowsControls
        settings.touchBarControlsSide = AppSettings.defaultTouchBarControlsSide
        settings.touchBarHidesControlStrip = AppSettings.defaultTouchBarHidesControlStrip
    }
}

// MARK: - 工具栏

/// 预览上面那排工具栏:三颗胶囊按钮(图标 · 标题 · 当前值摘要)点开是浮层,右端「重置 ▾」。只有一行,不用另外几段
/// 第二行那种对齐占位。
struct TouchBarEditorToolbar: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var popover: TouchBarSettingsGroup?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TouchBarSettingsGroup.allCases, id: \.self) { group in
                toolbarButton(group)
            }
            Spacer(minLength: 8)
            Menu {
                Button(L10n.t("恢复默认")) { TouchBarStyleDefaults.restoreDefaults() }
                // 作用范围写成一条不可点的说明项,同另外几段那颗「重置 ▾」。
                Text(TouchBarStyleDefaults.scope)
            } label: {
                Label(L10n.t("重置"), systemImage: "arrow.uturn.backward")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private func toolbarButton(_ group: TouchBarSettingsGroup) -> some View {
        Button {
            popover = group
        } label: {
            EditorToolbarButtonLabel(icon: group.icon, title: group.title, summary: summary(for: group))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: Binding(
            get: { popover == group },
            set: { shown in
                if shown { popover = group } else if popover == group { popover = nil }
            }), arrowEdge: .bottom) {
            group.popoverContent()
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
            return SettingsToggleSummary.text([
                (title: L10n.t("卡拉OK"), isOn: settings.touchBarLyricsKaraoke),
                (title: L10n.t("跟随封面"), isOn: settings.touchBarLyricsFollowsCover),
            ])
        case .layout:
            // 只列显示着的;摆在右边(非默认)时带上位置。
            var parts: [String] = []
            if settings.touchBarShowsArtwork {
                parts.append(sided(L10n.t("封面"), settings.touchBarArtworkSide, default: AppSettings.defaultTouchBarArtworkSide))
            }
            if settings.touchBarShowsControls {
                parts.append(sided(L10n.t("播放控制"), settings.touchBarControlsSide, default: AppSettings.defaultTouchBarControlsSide))
            }
            if settings.touchBarHidesControlStrip { parts.append(L10n.t("隐藏功能栏")) }
            guard !parts.isEmpty else { return L10n.t("全部关闭") }
            return L10n.list(parts)
        }
    }

    private func sided(_ name: String, _ side: TouchBarSide, default defaultSide: TouchBarSide) -> String {
        side == defaultSide ? name : "\(name) · \(side.displayName)"
    }
}

// MARK: - 「全部设置」抽屉

/// 触控栏那一段的「全部设置」抽屉:键盘 / VoiceOver 的全量兜底通路。三组的顺序和标题跟工具栏一致,行视图跟浮层同一份,
/// 最后一行「恢复默认」跟「重置 ▾」同一个动作、同一句作用范围。
///
/// 设置搜索点名了这一段里总开关以外的行就展开:触控栏不是 `LyricsSurface`,用不上 `settingsSearchPendingDrawer`,
/// 同 `LyricsWindowAllSettingsDrawer` 走行高亮;总开关在抽屉外面那张卡上,只点名它时不展开。
struct TouchBarAllSettingsDrawer: View {
    /// 用 @State 不用 @AppStorage,每次打开设置窗口都是折叠的(同另外几个抽屉)。
    @State private var isExpanded = false
    @Environment(\.settingsSearchHighlightedTitles) private var highlightedTitles

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()
                group(.lyrics) { TouchBarLyricsRows() }
                CardDivider()
                group(.style) { TouchBarStyleRows() }
                CardDivider()
                group(.layout) { TouchBarLayoutRows() }
                CardDivider()
                SettingsRow(icon: "arrow.uturn.backward", title: L10n.t("恢复默认"),
                            subtitle: TouchBarStyleDefaults.scope) {
                    Button(L10n.t("恢复")) { TouchBarStyleDefaults.restoreDefaults() }
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

    /// 一组:标题行 + 分隔线 + 内容。标题跟工具栏对应那颗按钮同一个词条。
    private func group<Content: View>(_ group: TouchBarSettingsGroup, @ViewBuilder content: () -> Content) -> some View {
        Group {
            SettingsCardHeader(title: group.title)
            CardDivider()
            content()
        }
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
