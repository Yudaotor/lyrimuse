import SwiftUI
import AppKit
import LyrimuseCore
import KeyboardShortcuts

// 整个设置窗口是一层真正的 NavigationSplitView:左边一份侧边栏 List,右边显示当前
// 选中项的详情。"账号连接"没有做成侧边栏里单独可选中的大分类,而是拆成普通账号行,
// 跟播放/歌词/外观/通用平级放进同一个 List 里——原因是嵌套第二层"看起来像侧边栏"的
// 容器(不管是内层再套一个 NavigationSplitView,还是手搭 HStack+List 模拟侧边栏),
// 都会跟 macOS 只按"一个真正侧边栏列"设计的窗口级 chrome/圆角遮罩打架,导致外层
// 侧边栏不渲染,或者窗口露出黑色阴影。唯一稳妥的解法是彻底拍平,全窗口只留一层真正的
// 侧边栏,账号这一级也变成这层真侧边栏里的普通行。
//
// 每个分类各自是独立的 View,直接访问对应的单例(AppSettings.shared/
// FeatureSettingsStore.shared/ConfigStore.shared 等),不需要从 SettingsView 往下传
// 参数——唯一的例外是某个开关因为对应账号没连好被禁用时,旁边会有个跳转按钮,直接跳到
// 侧边栏里对应的那一个账号行,这就需要 SettingsView 把跳转能力下传给它。
enum SettingsTab: Hashable, CaseIterable, Identifiable {
    // 2026-07-30:播放器选择/权限/常驻服务/App 联动这几块原来跟语言/开机启动/配置备份
    // 一起挤在"通用"里,内容上其实是两件不相干的事——前者全部围绕"选哪个播放器、能不能
    // 正常读到它的播放状态"转,后者是些跟播放器选择完全无关的杂项。拆成独立的"播放器"
    // 分类,见 PlayerSettingsTab;"通用"只留语言/启动/配置备份。
    case lyrics, player, appearance, shortcuts, general, about

    var id: Self { self }

    var title: String {
        switch self {
        case .lyrics: return L10n.t("歌词")
        case .player: return L10n.t("播放器")
        case .appearance: return L10n.t("外观")
        case .shortcuts: return L10n.t("快捷键")
        case .general: return L10n.t("通用")
        case .about: return L10n.t("关于")
        }
    }

    var icon: String {
        switch self {
        case .lyrics: return "text.quote"
        case .player: return "play.circle"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }

    // tint 特意避开已经在用的四个账号色(orange/pink/blue/red)和歌词来源色点(red/
    // green/cyan/purple,见 LyricsManagerView.swift 的 sourceColor)——"外观"尤其不用
    // 青色系,因为默认打开的是"歌词"分类,会跟侧边栏里同屏出现的 LRCLIB 色点(cyan)
    // 太接近;"通用"用灰色齿轮,呼应 macOS 系统设置里"通用"的既有印象;"快捷键"用
    // teal,跟歌词来源色点的 cyan 有区分度、也不撞现有任何一个分类色;"播放器"用
    // mint,同样是上面这份"避开列表"之外、目前分类里也还没人用过的颜色。
    var tint: Color {
        switch self {
        case .lyrics: return .indigo
        case .player: return .mint
        case .appearance: return .yellow
        case .shortcuts: return .teal
        case .general: return .gray
        // 蓝色是"关于/信息"这类内容在 macOS 上最约定俗成的配色(系统"关于本机"/大多数
        // App 的 info.circle 图标都是蓝色),不跟其余分类的既有配色规避逻辑冲突。
        case .about: return .blue
        }
    }
}

// 图标徽标——彩色圆角方块背景 + 白色 SF Symbol,侧边栏行(22pt/圆角6)和账号详情页头
// (36pt/圆角8)共用同一份渲染逻辑,不各自重复手写一遍。用自由函数而不是新建 View
// 类型,跟这个项目里 sourceColor/sourceDisplayName 同一个"小工具用自由函数"的既有
// 习惯保持一致——这里只有两组固定的(size, cornerRadius)组合在用,不是一个需要
// View 身份/状态的东西。
func iconBadge(_ systemName: String, tint: Color, size: CGFloat = 22, cornerRadius: CGFloat = 6) -> some View {
    Image(systemName: systemName)
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(tint, in: RoundedRectangle(cornerRadius: cornerRadius))
}

enum SettingsSidebarItem: Hashable {
    case tab(SettingsTab)
    case account(AccountDestination)
}

struct SettingsView: View {
    // 只用来在语言手动切换时让侧边栏/详情页的整棵子树重新渲染(sidebarLabel/
    // navigationTitle 这些顶层 chrome 文字不属于任何一个具体 tab,原来没有任何一处
    // @ObservedObject,加了才会响应 AppSettings.appLanguage 的变化)——本身不在 body
    // 里读它的其它字段。
    @ObservedObject private var languageSettings = AppSettings.shared
    @State private var selection: SettingsSidebarItem? = .tab(.lyrics)
    // 默认收起、点击 Section 头才展开,不持久化(每次打开设置窗口都从收起状态开始)。
    // 变量名保留 isAdditionalFeaturesExpanded,没有跟着 Section 标题改成"实验室
    // 功能"——纯内部实现细节,不是用户可见文案。
    @State private var isAdditionalFeaturesExpanded = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(L10n.t("核心设置")) {
                    sidebarLabel(.lyrics)
                    sidebarLabel(.player)
                    sidebarLabel(.appearance)
                    sidebarLabel(.shortcuts)
                    sidebarLabel(.general)
                    sidebarLabel(.about)
                }

                // 2026-07-29:Last.fm 从下面的折叠区里单独提出来,常驻可见——功能本身
                // (双向同步收听记录 + 喂两个"听歌报告"推送的数据源)已经相当完整,继续
                // 跟"实验室功能"这几个字混在一起、默认收起才能看到,会让人低估它的成熟度、
                // 也发现不了。ListenBrainz/网页推送/推送提醒这三个账号保留原样在下面的
                // 折叠区,没有改动。
                Section(L10n.t("账号")) {
                    AccountSidebarRow(destination: .lastfm)
                        .tag(SettingsSidebarItem.account(.lastfm))
                }

                // 手搭折叠(而不是原生 Section(isExpanded:))是因为那个初始化方法的
                // Footer 类型定死成 EmptyView,没法在这里放"?"图标+悬浮提示。tooltip
                // 弹出延迟看着像没反应,其实是系统默认 tooltip 延迟(~1~1.5s)本身偏长,
                // 真正的调整点是 AppDelegate.swift 里的 NSInitialToolTipDelay,会影响
                // 整个 App 所有 .help() 提示,不是这一处独有的问题。
                Section {
                    if isAdditionalFeaturesExpanded {
                        // .lastfm 不在这里——它已经单独提到上面常驻可见的"账号" Section,
                        // 这里排除掉避免同一个目的地在侧边栏出现两次。
                        ForEach(AccountDestination.allCases.filter { $0 != .lastfm }) { destination in
                            AccountSidebarRow(destination: destination)
                                .tag(SettingsSidebarItem.account(destination))
                        }
                    }
                } header: {
                    Button {
                        withAnimation { isAdditionalFeaturesExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.t("实验室功能"))
                            Image(systemName: "questionmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isAdditionalFeaturesExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("以下都是可选的账号与推送服务，跟显示歌词本身无关；不配置也完全不影响悬浮歌词正常使用"))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
            // 去掉 NavigationSplitView 自动塞进工具栏的那颗"隐藏边栏"按钮:这个窗口的
            // 侧边栏就是它唯一的导航方式,收起来之后整扇窗口只剩内容、没有任何切换分类的
            // 入口,是个只会把人卡住的开关。窗口本身也不可缩放(见 .frame 那一处),不存在
            // "屏幕太窄需要腾地方"这种要收起侧边栏的场景。
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case .tab(.lyrics): LyricsSettingsTab()
                case .tab(.player): PlayerSettingsTab()
                case .tab(.appearance): AppearanceSettingsTab()
                case .tab(.shortcuts): ShortcutsSettingsTab()
                case .tab(.general): GeneralSettingsTab()
                case .tab(.about): AboutSettingsTab()
                case .account(let destination):
                    AccountLinkingTab(destination: destination, onJumpToAccount: { target in
                        // 2026-08-02 补上——跳转目标如果落在"实验室功能"这个默认折叠的
                        // 区域里(比如从 Last.fm 卡片跳去配置 ListenBrainz),detail 面板
                        // 会正常切过去,但侧边栏因为这一行还没展开、根本不存在于列表里,
                        // 高亮不到任何一行,用户会觉得"跳过去了但侧边栏看着什么都没选中"。
                        // .lastfm 本身常驻可见,不需要展开这个折叠区。
                        if target != .lastfm {
                            withAnimation { isAdditionalFeaturesExpanded = true }
                        }
                        selection = .account(target)
                    })
                case nil: ContentUnavailableView(L10n.t("选择左侧的设置分类"), systemImage: "gearshape")
                }
            }
            .navigationTitle(navigationTitle)
        }
        // 原来是给 TabView 焊死的 440pt 改出来的 minWidth/idealWidth——现在换成
        // NavigationSplitView,多了一列侧边栏,整体相应加宽;同样不设 maxWidth/固定
        // 高度,各分类继续按内容自动撑高。
        .frame(minWidth: 760, idealWidth: 860, minHeight: 460)
        // 见 AppActions.pendingSettingsSelection 注释——Onboarding 的 Last.fm 步骤
        // 借这个信箱指定"这次打开设置窗口要直接停在哪个分类",这里读一次就清空,不影响
        // 之后用户正常打开设置窗口(默认还是回到 .tab(.lyrics))。
        .onAppear {
            if let pending = AppActions.shared.pendingSettingsSelection {
                selection = pending
                AppActions.shared.pendingSettingsSelection = nil
            }
        }
        // 见 AuxiliaryWindowActivation 注释——.accessory 策略下临时借一个 Dock 图标,
        // 关掉后(没有别的辅助窗口还开着)还原,不跟"在 Dock 中显示"这个永久偏好打架。
        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        .onDisappear { AuxiliaryWindowActivation.windowDidDisappear() }
    }

    // 保持单行(图标+标题),不加状态小字——账号行有状态是因为账号真的有"连没连上"
    // 这个概念,这四个纯设置分类没有对应的状态,硬凑一行小字是本末倒置。
    private func sidebarLabel(_ tab: SettingsTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            iconBadge(tab.icon, tint: tab.tint)
        }
        .tag(SettingsSidebarItem.tab(tab))
    }

    private var navigationTitle: String {
        switch selection {
        case .tab(let tab): return tab.title
        case .account(let destination): return destination.title
        case nil: return L10n.t("设置")
        }
    }
}

// 歌词相关设置的统一入口,也扛下原"播放"tab 的"数据源"设置(远程/本地+Relay 地址,
// 现在叫"播放状态来源")。
private struct LyricsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    // local 在这个页面里只当"写目标"用(切换开关时顺手同步给它),这个 View 的 body
    // 从来不读它的 @Published 数据渲染任何东西——声明成 @ObservedObject 会让这个页面
    // 在本地播放每次轮询(~2秒一次)更新歌曲信息时跟着白白重渲染一次。用普通引用
    // (class 本身是引用类型,let 一样能改它的属性),不订阅。
    private let local = LocalPlaybackSource.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 这一页的四个分段。
    ///
    /// 2026-08-09 重排:原来 6 张卡片、14 个设置项平铺在一条长滚动里,没有层级也没有主次,
    /// 一屏装不下、找一项要滚半天。四段各 2–4 项,一屏放得下,而且分法本身就是语义:
    /// 「怎么找到这首歌的歌词」「译文怎么来」「歌词长什么样」「已经存下来的怎么管」。
    ///
    /// 为什么不拆成两个侧边栏条目:那样侧边栏会从 6 项变 7 项,而这四段里真正常用的只有
    /// 前两段,把「显示」「管理」也提到侧边栏是把不常用的东西抬得更高了。
    private enum Section: String, CaseIterable, Identifiable {
        case fetch, translation, display, manage
        var id: Self { self }
        var title: String {
            switch self {
            case .fetch: return L10n.t("获取")
            case .translation: return L10n.t("译文")
            case .display: return L10n.t("显示")
            case .manage: return L10n.t("管理")
            }
        }
    }

    // 记住上次看的是哪一段 —— 每次重开设置都跳回第一段的话,连着调同一段的两项就要多点
    // 一次。存 rawValue 而不是枚举:@AppStorage 只吃基础类型。
    /// 鼠标悬在哪个来源上(只为悬停底色,不影响任何配置)。
    @State private var hoveredSource: LyricsSource?
    @AppStorage("settings:lyricsSection") private var sectionRaw = Section.fetch.rawValue
    private var section: Section { Section(rawValue: sectionRaw) ?? .fetch }

    var body: some View {
        SettingsPage(
            title: L10n.t("歌词"),
            subtitle: L10n.t("让每首歌都有一份对得上的歌词")
        ) {
            sectionPicker
            // 切段用纯淡入淡出,不用卡片那套 .settingsCard(带从顶边缩放):那个是"这一行下面
            // 长出一张卡"的语义,整页换内容时会像整块东西塌下去。时长也短一截 —— 分段切换
            // 在用户心里等同于换标签页,该是即时的。
            currentSection
                .id(section)
                .transition(.opacity)
        }
        .id(L10n.current)
    }

    private var sectionPicker: some View {
        Picker(
            "",
            selection: Binding(
                get: { section },
                set: { next in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        sectionRaw = next.rawValue
                    }
                })
        ) {
            ForEach(Section.allCases) { s in
                Text(s.title).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // 不铺满整列:居中的固定宽度跟上面居中的标题/说明是同一根轴,铺满会让它看起来像
        // 一条工具栏,而不是页头的一部分。
        .fixedSize()
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var currentSection: some View {
        switch section {
        case .fetch:
            parsingCard
            // 「来源」和「匹配」合成一张卡:它们是同一件事的两半 —— 去哪儿查、查回来怎么挑。
            // 分成两张卡的时候这一段是三张卡、一屏装不下,而其余三段都只有一张卡,轻重失衡。
            sourcesAndMatchingCard
        case .translation:
            translationCard
        case .display:
            displayCard
        case .manage:
            managementCard
        }
    }

    // 播放位置现在通过 AppleScript 问 Music.app(见 MediaControlClient.swift)得到精确值,
    // 不再有"精确/估算"两条路径可选,所以没有对应开关——自动化权限是显示歌词的必要前提,
    // 状态统一显示在"播放器"分类的"权限"里。
    private var parsingCard: some View {
        SettingsCard {
            // "解析"(而非"预取")避免被误读成预先加载音频本身,这个开关从不碰音频。
            SettingsRow(
                icon: "square.stack",
                title: L10n.t("提前解析同专辑其它曲目"),
                // 副标题原来是把标题重说一遍;? 里原来还提到「歌词在线匹配」开关 —— 那个
                // 开关 2026-08-10 已经删掉,留着就是条错信息。现在只说一件从界面上看不出来、
                // 又真的会让人白开开关的事:它只认资料库里的曲目。
                help: L10n.t("只对资料库里的曲目生效。在 Apple Music 里直接点播、没有添加到资料库的专辑查不到曲目")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.albumPrefetch },
                    set: { features.albumPrefetch = $0; Task { await features.save() } }
                ))
            }
        }
    }

    // 每个来源前面那个彩色圆点用 iconTint 上色——这里的图标不是"行首的视觉锚点",它本身
    // 就是这个来源的身份色(跟"歌词管理"窗口里来源列的色点是同一套 source.color)。
    private var sourcesAndMatchingCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "arrow.down.circle",
                title: L10n.t("歌词来源"),
                subtitle: L10n.t("至少需要保留一个歌词来源")
            )
            CardDivider()
            // 五个来源横排成一排可勾选的胶囊,不再一个来源占一整行 —— 五行开关加上分隔线
            // 把这张卡撑到了半屏高,而这里要表达的只是"哪几个开着"。
            // 用 WrapLayout 而不是 HStack:万一系统字号调大、或以后加了第六个来源,自动折到
            // 第二行,不会被卡片宽度裁掉。
            SettingsRawRow(insetToText: true) {
                WrapLayout(horizontalSpacing: 10, verticalSpacing: 6, rowAlignment: .leading) {
                    ForEach(LyricsSource.allCases) { source in
                        sourceCheckbox(source)
                    }
                }
            }
            CardDivider()
            // 分段控件放在标题行右边,不再单独占一整行 —— 一行一个设置是这套设置页其余地方
            // 的通用写法(开关、下拉都是这样),原来那种"标题一行、控件再一行"把这一段的高度
            // 白白翻了一倍。
            SettingsRow(
                icon: "slider.horizontal.3",
                title: L10n.t("匹配算法"),
                help: L10n.t("智能算法：查到的每个来源都打分（逐字时间轴、语言是否匹配等维度），自动挑分数最高的一条。顺序优先：按下面排的顺序，用第一个查到有效结果的来源，不比较分数")
            ) {
                Picker("", selection: Binding(
                    get: { features.lyricsSourceMode },
                    set: { features.lyricsSourceMode = $0; Task { await features.save() } }
                )) {
                    ForEach(LyricsSourceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if features.lyricsSourceMode == .priority {
                ForEach(Array(orderedEnabledSources.enumerated()), id: \.element) { index, source in
                    CardDivider()
                    SettingsRawRow(insetToText: true) {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .trailing)
                            Circle().fill(source.color).frame(width: 8, height: 8)
                            Text(source.displayName)
                                .font(.system(size: 13))
                            Spacer()
                            Button {
                                moveEnabledSource(source, direction: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            Button {
                                moveEnabledSource(source, direction: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == orderedEnabledSources.count - 1)
                        }
                    }
                }
            }
        }
    }

    /// 一个来源 = 一个原生复选框。
    ///
    /// 2026-08-09 先做成了带来源色底的胶囊,用户反馈"跟整体风格不搭" —— 这一页其余控件
    /// 全是系统原生件(开关、分段控件、下拉),五个饱和色块摆在中间确实突兀,而且"选中"
    /// 本来就有一个所有人都认识的 macOS 表达方式。来源色只留一个小圆点作身份标记(跟
    /// "歌词管理"窗口来源列同一套色),不再铺成背景。
    /// 一个来源的开关。
    ///
    /// 2026-08-10 重做:原来是系统复选框 + 品牌色圆点并排,**同一个状态画了两遍** ——
    /// 复选框说"选中了"、圆点说"这是网易云",五个亮蓝方块横成一排,把它们各自的品牌色
    /// 全压住了,一眼看过去只剩一串蓝。
    ///
    /// 现在合成一个元素:选中圈填品牌色、里面一个白勾,没选中就是一圈空心灰环 + 文字
    /// 转次要色。勾负责"选没选中"、颜色负责"这是哪个来源",一个控件说两件不重复的事。
    ///
    /// 刻意不加胶囊底色 —— 那一版(彩色 chip)做过,用户的评价是"和整体不是很搭":这一页
    /// 其余全是白底卡片 + 行,一排彩色药丸是外来物。悬停时才给一层极淡的底,只为了说明
    /// "这里能点"。
    private func sourceCheckbox(_ source: LyricsSource) -> some View {
        let on = features.lyricsSources.contains(source)
        let hovered = hoveredSource == source
        return Button {
            setSource(source, enabled: !on)
        } label: {
            HStack(spacing: 6) {
                // 勾要留着 —— 只画一个实心圆点的话,五个来源全开时这一排看上去就是一条
                // 静态色标图例,完全读不出"能点"。勾 = 多选,圆的颜色 = 这是谁,两件事各
                // 说各的,不再重复。
                ZStack {
                    Circle()
                        .fill(on ? source.color : .clear)
                        .overlay(
                            Circle().strokeBorder(
                                on ? .clear : Color.secondary.opacity(0.4), lineWidth: 1.5))
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 15, height: 15)
                Text(source.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.secondary.opacity(0.12) : .clear))
            // 整块(含内边距)都算命中区,不是只有文字和圆点上才点得到
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hoveredSource = $0 ? source : (hoveredSource == source ? nil : hoveredSource) }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func setSource(_ source: LyricsSource, enabled: Bool) {
        // 关掉最后一个来源是不允许的(下面那句 count > 1 的守卫),这时集合没有任何变化 ——
        // 但原来 save() 是无条件调的,于是这次被拒绝的点击照样写一遍 features.json 并
        // kickstart 一次 collector:后台服务被杀掉重启,期间歌词整片空掉(launchd 对连续
        // kickstart 还有约 10s 的节流),而配置压根没变。只在真的变了才保存。
        let before = features.lyricsSources
        if enabled {
            features.lyricsSources.insert(source)
        } else if features.lyricsSources.count > 1 {
            features.lyricsSources.remove(source)
        }
        guard features.lyricsSources != before else { return }
        Task { await features.save() }
    }

    private var translationCard: some View {
        SettingsCard {
            // 顺序是一条链:要不要显示译文 → 要哪种语言 → 没有译文时兜底 → 兜底要的语言包。
            // "显示译文"原来在下面那张"显示"卡片里,跟罗马音/双行放一起,离它真正相关的三行很远。
            SettingsRow(
                icon: "text.bubble",
                title: L10n.t("显示译文"),
                help: L10n.t("这个开关只影响「桌面悬浮歌词」和「歌词窗口」；灵动岛歌词受限于胶囊空间不支持这一项，菜单栏歌词只能显示一行纯文字")
            ) {
                Toggle("", isOn: $settings.showTranslation)
            }
            CardDivider()
            SettingsRow(
                icon: "globe",
                title: L10n.t("译文语言")
            ) {
                Picker("", selection: Binding(
                    get: { features.lyricsTranslationLanguage },
                    set: { features.lyricsTranslationLanguage = $0; Task { await features.save() } }
                )) {
                    ForEach(MusixmatchTranslationLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            CardDivider()
            SettingsRow(
                icon: "character.book.closed",
                title: L10n.t("系统兜底翻译"),
                help: L10n.t("歌词源没带译文时补充")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.lyricsMachineTranslation },
                    set: { features.lyricsMachineTranslation = $0; Task { await features.save() } }
                ))
            }
            // 系统翻译按语言分别下载语言包,没装的语言(实测这台机器上日语/韩语默认就没装)
            // 只能退回联网翻译。下载弹窗是系统 UI,只有 SwiftUI 的 .translationTask 建出来的
            // session 才有权拉起它 —— 采集器那个无界面子进程做不到,所以入口必须在这里。
            if #available(macOS 26.0, *), features.lyricsMachineTranslation {
                CardDivider()
                LanguagePackRow()
            }
        }
    }

    private var displayCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "sparkles",
                title: L10n.t("卡拉OK效果"),
                help: L10n.t("逐字歌词，唱到哪个字亮到哪个字；没有逐字数据的歌整行高亮")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.preferWordLevelKaraoke },
                    set: { newValue in
                        settings.preferWordLevelKaraoke = newValue
                        local.preferWordLevelKaraoke = newValue
                    }
                ))
            }
            // 这一项对完全不听中文歌的人是纯噪声,按系统首选语言收起来 —— 设置页已有
            // 同类先例(按来源模式/按跟随封面显示的那几行)。
            //
            // ⚠️ `|| 已经不是默认值` 这半边是必须的,不是保险起见:万一判据没覆盖到某个
            // 真实用户(比如系统语言列表里没加中文、但确实在听中文歌),而他之前已经打开过
            // 这个开关,收起来就等于**歌词正在被转换、而那个开关不见了** —— 那是最糟的
            // 一种状态,用户根本无从找回。只要它还在起作用,就一定看得见。
            if AppSettings.userReadsChinese || settings.hasSeenChineseLyrics
                || settings.lyricsChineseVariant != .off
            {
            CardDivider()
            SettingsRow(
                icon: "character.bubble",
                title: L10n.t("中文歌词字体"),
                help: L10n.t("把中文歌词统一显示成简体或繁体")
            ) {
                Picker("", selection: Binding(
                    get: { settings.lyricsChineseVariant },
                    set: { newValue in
                        settings.lyricsChineseVariant = newValue
                        local.chineseVariant = newValue
                    }
                )) {
                    Text(L10n.t("不转换")).tag(ChineseVariant.off)
                    Text(L10n.t("简体")).tag(ChineseVariant.simplified)
                    Text(L10n.t("繁体")).tag(ChineseVariant.traditional)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            }
            CardDivider()
            SettingsRow(
                icon: "textformat.alt",
                title: L10n.t("显示罗马音"),
                help: L10n.t("这个开关只影响「桌面悬浮歌词」和「歌词窗口」；灵动岛歌词受限于胶囊空间不支持这一项，菜单栏歌词只能显示一行纯文字")
            ) {
                Toggle("", isOn: $settings.showRomanization)
            }
            CardDivider()
            SettingsRow(
                icon: "text.aligncenter",
                title: L10n.t("双行显示"),
                subtitle: L10n.t("多显示一行下一句")
            ) {
                Toggle("", isOn: $settings.showNextLinePreview)
            }
        }
    }

    private var managementCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "list.bullet.rectangle",
                title: L10n.t("歌词管理"),
                subtitle: L10n.t("查看、编辑、重搜已缓存的歌词")
            ) {
                // accessory 策略下打开新窗口得先手动激活 App,不然 openWindow 调了也没反应
                // ——跟 MenuBarMenu.swift 里"歌词管理…"菜单项同一个坑、同一个修法。
                Button(L10n.t("打开…")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "lyrics-manager")
                }
            }
            CardDivider()
            SettingsRow(
                icon: "folder",
                title: L10n.t("歌词文件夹"),
                subtitle: L10n.t("歌词永久保存在这里"),
                help: L10n.t("歌词默认就以这个文件夹为准维护。联网匹配到的结果会导出成文件存在这里，「歌词管理」里手动导入/编辑的文件也在这里。换成新文件夹后，旧文件夹里已有的文件不会自动搬过去，需要自己手动移动")
            )
            CardDivider()
            SettingsRawRow(insetToText: true) {
                Text(features.effectiveLyricsDir.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            CardDivider()
            SettingsRawRow(insetToText: true) {
                HStack(spacing: 10) {
                    Button(L10n.t("选择文件夹…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.prompt = L10n.t("选择")
                        panel.directoryURL = features.effectiveLyricsDir
                        if panel.runModal() == .OK, let url = panel.url {
                            features.lyricsDir = url.path
                            Task { await features.save() }
                        }
                    }
                    Button(L10n.t("打开歌词文件夹")) {
                        let url = features.effectiveLyricsDir
                        // collector 那边(见 collector/lyricsexport.go)只在真正解析/导出过
                        // 至少一首歌之后才会建这个目录,这里先兜底建一下,避免文件夹还不存在
                        // 时 NSWorkspace 打不开、又没有任何提示。
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                    if !features.lyricsDir.isEmpty {
                        Button(L10n.t("恢复默认位置")) {
                            features.lyricsDir = ""
                            Task { await features.save() }
                        }
                        .buttonStyle(.link)
                    }
                    Spacer()
                }
            }
        }
    }

    // 只包含当前启用的来源,按 lyricsSourceOrder 里的相对顺序展示——"顺序优先"模式的
    // 列表只需要用户关心"我选的这几个,先后顺序是什么",被禁用的来源不出现在这份列表里,
    // 不需要用户先想着"跳过那些没打开的"。
    private var orderedEnabledSources: [LyricsSource] {
        features.lyricsSourceOrder.filter { features.lyricsSources.contains($0) }
    }

    // lyricsSourceOrder 始终是全部 4 个源的排列,不只是启用的那几个——"上移/下移"只需要
    // 在这个完整数组里,把 source 换到"当前可见列表"里相邻的那个启用来源的位置,禁用的
    // 来源被跳过、位置不受影响,不需要临时把它们摘出数组再塞回去。
    private func moveEnabledSource(_ source: LyricsSource, direction: Int) {
        let visible = orderedEnabledSources
        guard let visibleIndex = visible.firstIndex(of: source) else { return }
        let targetIndex = visibleIndex + direction
        guard visible.indices.contains(targetIndex) else { return }
        let other = visible[targetIndex]
        guard let i = features.lyricsSourceOrder.firstIndex(of: source),
              let j = features.lyricsSourceOrder.firstIndex(of: other) else { return }
        features.lyricsSourceOrder.swapAt(i, j)
        Task { await features.save() }
    }
}

private struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var lyricsWindowPresence = LyricsWindowPresence.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showSaveThemeAlert = false
    @State private var newThemeName = ""
    // 灵动岛"显示在哪块屏幕"下拉的选项来源。用 @State 快照而不是每次 body 现读
    // NSScreen.screens:插拔显示器时 SwiftUI 不会因为一个全局数组变了就重算 body,
    // 得靠下面那条 didChangeScreenParameters 通知显式刷新。
    @State private var availableScreens: [NSScreen] = NSScreen.screens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 精选常用字体,而不是列出这台机器上全部两百多个已安装字体族——选不过来。清单
    // 来源是调研结论,不是凭印象挑的:
    // - 拉丁文/通用部分:Helvetica(现代排版标杆)、Arial(全球装机量/曝光量最高的
    //   英文字体)、Times New Roman(最常见的衬线字体)、Futura(经典几何无衬线设计)。
    // - 中文部分:黑体用得最多、宋体次之,楷体屏幕显示效果差故不收;另加 PingFang SC,
    //   因为它是 macOS/iOS 自 El Capitan 起的实际默认中文字体。
    // 仍然过一遍 NSFontManager 实际安装列表做交叉核对而不是硬编码假设——理论上都是
    // macOS 系统自带字体、不会缺失,但跟项目里"字体设置要显式检查装没装、不能隐式
    // 假设"的既有惯例(见 AppearanceHelpers.swift)保持一致。
    private static let curatedFontFamilies: [String] = {
        let candidates = [
            "Helvetica Neue", "Arial", "Times New Roman", "Futura",
            "PingFang SC", "Heiti SC", "Songti SC",
        ]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return candidates.filter { installed.contains($0) }
    }()

    private func applyColorTheme(_ theme: ColorTheme) {
        // 套用一个具体命名主题就是在明确表态"我要固定色,不要动态色"——顺手关掉
        // "跟随封面"(如果开着),不然套用之后前景色看起来毫无反应,像是这个 Menu
        // 失灵了(实际上是被"跟随封面"接管了,只是用户不知道)。
        settings.followsCoverArt = false
        settings.foregroundColorHex = theme.foregroundColorHex
        settings.backgroundColorHex = theme.backgroundColorHex
        settings.textStrokeEnabled = theme.textStrokeEnabled
        settings.textStrokeColorHex = theme.textStrokeColorHex
    }

    // 当前四个配色字段正好等于哪个内置预设/自定义主题就显示它的名字,谁都不等于
    // (比如套用之后又手动微调过某个颜色)就显示"自定义"——这是"使用内置预设"这个
    // Menu 唯一的选中反馈来源,见调用点注释。"跟随封面"开着时优先显示它,不比较颜色
    // 字段——那几个字段这时只是"没有封面数据时的备用色",不代表当前实际生效的前景色。
    private var currentColorThemeLabel: String {
        if settings.followsCoverArt {
            return L10n.t("跟随封面")
        }
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

    var body: some View {
        // 2026-08-06 从 .formStyle(.grouped) 换成这套卡片组件(见 SettingsDesignSystem.swift)。
        // 结构上的分组沿用 2026-08-05 那次"每种展示方式各占一张卡"的划分,没有再动:
        // 一张卡放四个总开关,之后每种展示方式各一张卡、只在这种方式开着时出现,共用的
        // 两个隐藏开关单独一张。
        //
        // 换成卡片之后多出来一件原来做不到的事:每一行可以自带一句副标题。原来"四种展示
        // 方式互不冲突,可以同时开启:桌面悬浮歌词贴在桌面上、支持逐字高亮;灵动岛歌词
        // 紧凑地贴着刘海显示;..." 是**一整段** Section 尾注,四种方式的说明串在一句话里,
        // 读者得自己把每一小段对应回上面第几个开关;现在直接拆成四行各自的副标题。
        SettingsPage(
            title: L10n.t("外观"),
            subtitle: L10n.t("四种展示方式可以同时开启")
        ) {
            sectionPicker
            currentSection
                .id(section)
                .transition(.opacity)
        }
        .id(L10n.current)
    }

    /// 这一页的四个分段,跟「歌词」页同一个范式(见 LyricsSettingsTab.Section 的注释)。
    ///
    /// 原来是 5 张卡片平铺在一条长滚动里,而且「桌面悬浮歌词」那一张自己就有十几项
    /// (字体/字号/颜色/描边/阴影/宽度/位置…),开着两三个形态时这一页要滚很久,想改灵动岛
    /// 的一项得先翻过悬浮歌词的全部设置。
    ///
    /// 分法就按**形态**走 —— 这是这一页天然的结构:先在「总览」里决定开哪几个,再进各自
    /// 那一段调它自己的样子。「自动隐藏」跟着总览走,因为它是**跨形态**的规则(悬浮歌词和
    /// 灵动岛共用),放进任何一个单独形态里都不对。
    private enum Section: String, CaseIterable, Identifiable {
        case overlay, notch, menuBar, other
        var id: Self { self }
        var title: String {
            switch self {
            case .overlay: return L10n.t("悬浮歌词")
            case .notch: return L10n.t("灵动岛")
            case .menuBar: return L10n.t("菜单栏")
            case .other: return L10n.t("其它")
            }
        }
    }

    @AppStorage("settings:appearanceSection") private var sectionRaw = Section.overlay.rawValue
    private var section: Section { Section(rawValue: sectionRaw) ?? .overlay }

    private var sectionPicker: some View {
        Picker(
            "",
            selection: Binding(
                get: { section },
                set: { next in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        sectionRaw = next.rawValue
                    }
                })
        ) {
            ForEach(Section.allCases) { s in
                Text(s.title).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var currentSection: some View {
        switch section {
        case .overlay:
            modeToggleCard(
                icon: "captions.bubble",
                title: L10n.t("桌面悬浮歌词"),
                subtitle: L10n.t("贴在桌面上，支持逐字高亮"),
                isOn: Binding(
                    get: { settings.classicOverlayEnabled },
                    set: { LyricsOverlayWindowController.shared.setVisible($0) }))
            if settings.classicOverlayEnabled {
                classicOverlayCard.transition(.settingsCard)
            }
        case .notch:
            modeToggleCard(
                icon: "rectangle.topthird.inset.filled",
                title: L10n.t("灵动岛歌词"),
                subtitle: L10n.t("紧凑地贴着屏幕顶部的刘海显示"),
                isOn: Binding(
                    get: { settings.notchOverlayEnabled },
                    set: { NotchLyricsWindowController.shared.setVisible($0) }))
            if settings.notchOverlayEnabled {
                notchOverlayCard.transition(.settingsCard)
            }
        case .menuBar:
            modeToggleCard(
                icon: "menubar.rectangle",
                title: L10n.t("菜单栏歌词"),
                isOn: $settings.showLyricsInMenuBar)
            if settings.showLyricsInMenuBar {
                menuBarCard.transition(.settingsCard)
            }
        case .other:
            lyricsWindowCard
            // 自动隐藏是**跨形态**的(悬浮歌词/灵动岛共用同一组规则),所以不能塞进任何一个
            // 单独形态那一段,只能留在这里。两个都没开时它没有作用对象,不显示。
            if settings.classicOverlayEnabled || settings.notchOverlayEnabled {
                autoHideCard.transition(.settingsCard)
            }
        }
    }

    /// 每一段开头那张"这个形态开不开"的卡。
    ///
    /// 2026-08-10 从原来集中的一张总开关卡拆过来:开关跟它自己那一堆设置隔着一个分段,
    /// 要开某个形态得先退回总览、开完再切回来,来回两次。放在这一段的最上面之后,
    /// "开启 → 立刻在下面调它的样子"是一条直线。
    ///
    /// 关着的时候这一段也不会是空白 —— 这张卡本身就是内容,替代了原来那个"还没开启"的
    /// 占位提示。
    private func modeToggleCard(
        icon: String, title: String, subtitle: String? = nil, isOn: Binding<Bool>
    ) -> some View {
        SettingsCard {
            SettingsRow(icon: icon, title: title, subtitle: subtitle) {
                Toggle("", isOn: Binding(
                    get: { isOn.wrappedValue },
                    set: { newValue in
                        // withAnimation 包在"改状态"这一处,理由见 Animation.settingsCardReveal
                        withAnimation(.settingsCardReveal) { isOn.wrappedValue = newValue }
                    }
                ))
            }
        }
    }

    /// "歌词窗口"跟上面三种形态不是一回事:它没有 AppSettings 里的持久化开关,开合状态
    /// 完全交给 SwiftUI Window(id:) 自己的窗口自动存档机制(见 App.swift 那个场景的注释),
    /// 这里的 Toggle 只是"现在这扇窗口是不是开着"的实时状态(见 LyricsWindowPresence),
    /// 开/关直接对应打开/关闭这扇窗口,不写入任何配置项。
    ///
    /// 它也没有任何外观设置可调(用固定的系统配色),所以不单独占一段,跟同样跨形态的
    /// "自动隐藏"一起放在「其它」里。
    private var lyricsWindowCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "text.quote",
                title: L10n.t("歌词窗口"),
                subtitle: L10n.t("可以滚动阅读的完整歌词列表")
            ) {
                Toggle("", isOn: Binding(
                    get: { lyricsWindowPresence.isOpen },
                    set: { newValue in
                        if newValue {
                            // accessory 策略下打开新窗口得先手动激活 App,不然 openWindow
                            // 调了也没反应——跟"打开歌词管理…"按钮同一个坑、同一个修法。
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "lyrics-window")
                        } else {
                            dismissWindow(id: "lyrics-window")
                        }
                    }
                ))
            }
        }
    }

    // 桌面悬浮歌词(经典悬浮窗)专属的一整套:窗口几何 + 配色与字体。
    //
    // 配色/字体放在这张卡里的依据:2026-08-05 全仓核对过消费方,确认这些设置确实只对这一种
    // 展示方式生效——mainFont/romanizationFont/translationFont 和 foregroundColor/
    // backgroundColor/textStrokeColor 的读取点全部落在 LyricsOverlayView.swift 一个文件里
    // (灵动岛/歌词窗口各自用固定的系统配色,菜单栏歌词是纯文字,都不读这些字段)。
    //
    // 第一行是一条没有控件的"身份行",只写模式名 + 适用范围。这张卡里全是"配色/字体"这类
    // 通用词,不点名属于谁的话,跟上面那张总开关卡分不清关系。
    private var classicOverlayCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "captions.bubble",
                title: L10n.t("桌面悬浮歌词"),
                subtitle: L10n.t("配色与字体只作用于这里"),
                help: L10n.t("下面的配色、字体、字号只影响桌面悬浮歌词；灵动岛、菜单栏、歌词窗口各自用固定样式")
            )
            CardDivider()
            SettingsRow(icon: "arrow.left.and.right", title: L10n.t("宽度")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { settings.overlayWidth },
                        set: { newValue in
                            settings.overlayWidth = newValue
                            LyricsOverlayWindowController.shared.setWidth(newValue)
                        }
                    ), in: 420...1000, step: 10)
                    .frame(width: 150)
                    Text(String(format: L10n.t("%@pt"), "\(Int(settings.overlayWidth))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
            CardDivider()
            // "解锁后长按才能拖动"这个手势不直观(不看说明容易只当成"按住就能拖",或者
            // 反过来以为"这窗口点不动了"),必须有一句显式说明。挂成这一行的副标题,而不是
            // 卡片底部的统一说明——它只跟这一个开关有关。
            SettingsRow(
                icon: "lock",
                title: L10n.t("锁定位置"),
                subtitle: L10n.t("解锁后可点击穿透"),
                help: L10n.t("解锁后鼠标点击会穿到桌面上；长按住悬浮歌词不放才能拖动它")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.lockPosition },
                    set: { newValue in
                        settings.lockPosition = newValue
                        LyricsOverlayWindowController.shared.setLocked(newValue)
                    }
                ))
            }
            CardDivider()
            // 配色主题——内置预设一键套用+把当前调好的配色另存复用。只打包"配色"相关的
            // 四个字段(文字/背景/阴影颜色+阴影开关),不含字体/字号——那是排版,跟配色是
            // 两回事,不该被同一个"主题"捆在一起改(见 ColorTheme.swift)。Menu 的标签本身
            // 显示"当前配色正好等于哪个主题"(不等于任何一个就显示"自定义")。
            SettingsRow(
                icon: "paintpalette",
                title: L10n.t("配色主题"),
                subtitle: settings.followsCoverArt ? L10n.t("没有封面数据时会使用下面选择的文字颜色作为备用") : nil
            ) {
                Menu(currentColorThemeLabel) {
                    // "跟随封面"不是一个固定配色,是"改用当前曲目封面算出的动态高亮色"这个
                    // 模式本身,用 Divider 跟下面的具体命名主题隔开,表明这是另一类选项。
                    Button(L10n.t("跟随封面")) { settings.followsCoverArt = true }
                    Divider()
                    ForEach(ColorTheme.builtInPresets) { theme in
                        Button(theme.name) { applyColorTheme(theme) }
                    }
                    if !settings.customColorThemes.isEmpty {
                        Divider()
                        ForEach(settings.customColorThemes) { theme in
                            Button(theme.name) { applyColorTheme(theme) }
                        }
                    }
                }
                .fixedSize()
            }
            ForEach(settings.customColorThemes) { theme in
                CardDivider()
                SettingsSubRow(title: theme.name) {
                    HStack(spacing: 10) {
                        Button(L10n.t("套用")) { applyColorTheme(theme) }
                        Button {
                            settings.customColorThemes.removeAll { $0.id == theme.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            CardDivider()
            SettingsSubRow {
                Button(L10n.t("将当前配色存为新主题…")) {
                    newThemeName = ""
                    showSaveThemeAlert = true
                }
                .buttonStyle(.link)
            }
            CardDivider()
            SettingsRow(icon: "textformat", title: L10n.t("字体")) {
                Picker("", selection: $settings.fontFamilyName) {
                    // 这一项原来也叫「跟随系统」,跟语言选择器那一项撞成同一个 L10n key,
                    // 而 .strings 里一个 key 只能有一个值——改成「系统字体」:key 各自独立,
                    // 而且在「字体」选择器下这个说法本身就比「跟随系统」准确。
                    Text(L10n.t("系统字体")).tag("")
                    ForEach(Self.curatedFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            CardDivider()
            SettingsRow(icon: "textformat.size", title: L10n.t("字号")) {
                HStack(spacing: 8) {
                    Slider(value: $settings.fontSize, in: 14...36, step: 1)
                        .frame(width: 150)
                    Text(String(format: L10n.t("%@pt"), "\(Int(settings.fontSize))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
            CardDivider()
            SettingsRow(icon: "paintbrush", title: L10n.t("文字颜色")) {
                ColorPicker("", selection: Binding(
                    get: { settings.foregroundColor },
                    set: { settings.foregroundColorHex = $0.hexStringWithAlpha }
                ), supportsOpacity: false) // 故意关掉——文字颜色允许透明的话,容易把 alpha
                                           // 拖到 0,悬浮窗整个消失且没有任何视觉提示能定位问题
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
            SettingsRow(
                icon: "pencil.and.outline",
                title: L10n.t("文字描边"),
                subtitle: L10n.t("杂乱背景上更清楚"),
                help: L10n.t("在浅色或杂乱的桌面背景上给文字加一圈描边，把字撑出来")
            ) {
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
            CardDivider()
            SettingsSubRow {
                Button(L10n.t("恢复默认外观")) {
                    settings.followsCoverArt = false
                    settings.fontFamilyName = AppSettings.defaultFontFamilyName
                    settings.fontSize = AppSettings.defaultFontSize
                    settings.foregroundColorHex = ColorTheme.defaultTheme.foregroundColorHex
                    settings.backgroundColorHex = ColorTheme.defaultTheme.backgroundColorHex
                    settings.textStrokeEnabled = ColorTheme.defaultTheme.textStrokeEnabled
                    settings.textStrokeColorHex = ColorTheme.defaultTheme.textStrokeColorHex
                }
                .buttonStyle(.link)
            }
        }
        .alert(L10n.t("存为新配色主题"), isPresented: $showSaveThemeAlert) {
            TextField(L10n.t("主题名称"), text: $newThemeName)
            Button(L10n.t("保存")) {
                let name = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                settings.customColorThemes.append(ColorTheme(
                    name: name,
                    foregroundColorHex: settings.foregroundColorHex,
                    backgroundColorHex: settings.backgroundColorHex,
                    textStrokeEnabled: settings.textStrokeEnabled,
                    textStrokeColorHex: settings.textStrokeColorHex
                ))
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(L10n.t("会把当前的文字颜色、背景颜色、描边颜色存成一个可以随时再套用的主题"))
        }
    }

    // 灵动岛歌词专属。三项都只负责持久化,NotchLyricsView 每次渲染直接读,不需要连带调
    // 某个窗口控制器"生效"——唯一的例外是"宽度",它改的是窗口本身的几何。
    private var notchOverlayCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "rectangle.topthird.inset.filled",
                title: L10n.t("灵动岛歌词"),
            )
            CardDivider()
            SettingsRow(icon: "paintbrush.pointed", title: L10n.t("风格")) {
                Picker("", selection: $settings.notchCardStyle) {
                    ForEach(NotchCardStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            CardDivider()
            // 跟上面桌面悬浮歌词的"宽度"滑块同一套写法(设置项本身只负责持久化,didSet
            // 不碰 NSWindow,这里的 set 闭包显式调用窗口控制器的方法让改动立刻生效)。
            // 跟桌面悬浮歌词不同的是灵动岛不需要"保持中心点"的增量调整——它的位置从来
            // 都是重新居中算出来的,见 NotchLyricsWindowController.applyContentWidthSetting()。
            SettingsRow(icon: "arrow.left.and.right", title: L10n.t("宽度")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { settings.notchContentWidth },
                        set: { newValue in
                            settings.notchContentWidth = newValue
                            NotchLyricsWindowController.shared.applyContentWidthSetting()
                        }
                    ), in: 260...500, step: 10)
                    .frame(width: 150)
                    Text(String(format: L10n.t("%@pt"), "\(Int(settings.notchContentWidth))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
            CardDivider()
            SettingsRow(
                icon: "display",
                title: L10n.t("显示在哪块屏幕"),
                help: L10n.t("「自动」选带刘海的那块；指定的屏幕拔掉后自动回到「自动」")
            ) {
                Picker("", selection: Binding(
                    get: { settings.notchScreenID },
                    set: { newValue in
                        settings.notchScreenID = newValue
                        NotchLyricsWindowController.shared.applyScreenSetting()
                    }
                )) {
                    Text(L10n.t("自动")).tag("")
                    ForEach(availableScreens, id: \.self) { screen in
                        if let id = ScreenIdentity.id(of: screen) {
                            Text(screen.localizedName).tag(id)
                        }
                    }
                    // 存着的那块屏现在没接着时补一个占位项。Picker 的选中值如果在选项里
                    // 找不到对应 tag,整个控件会显示成空白——那看起来像设置丢了,而实际上
                    // 偏好还在、屏幕插回来就会恢复。
                    if !settings.notchScreenID.isEmpty,
                       ScreenIdentity.screen(withID: settings.notchScreenID) == nil {
                        Text(L10n.t("已断开的屏幕")).tag(settings.notchScreenID)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        // 设置页开着的时候插拔显示器,下拉里的选项要跟着变。灵动岛窗口自己也订阅了同一条
        // 通知去重算位置(见 NotchLyricsWindowController.screenParamsObserver)。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            availableScreens = NSScreen.screens
        }
    }

    // 菜单栏歌词专属。那句随开关变化的说明挂成"超宽时横向滚动"这一行的副标题——它讲的
    // 就是这个开关两种状态各自的行为,原来是 Section 正文里一行独立的 caption 文字。
    private var menuBarCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "menubar.rectangle",
                title: L10n.t("菜单栏歌词"),
                help: L10n.t("状态栏宽度有限，歌词可能被截断；鼠标悬停在上面永远能看到完整的这一行")
            )
            CardDivider()
            SettingsRow(
                icon: "arrow.left.arrow.right",
                title: L10n.t("超宽时横向滚动"),
                subtitle: L10n.t(settings.menuBarLyricsScroll
                    ? "超出宽度时横向滚动播完"
                    : "超出宽度时截断，不滚动"),
                help: L10n.t(settings.menuBarLyricsScroll
                    ? "比下面的宽度更长时，在状态栏里横向滚动播完整句；开头会先停一下再滚"
                    : "比下面的宽度更长时截断成「前 N 个字…」，不滚动")
            ) {
                Toggle("", isOn: $settings.menuBarLyricsScroll)
            }
            CardDivider()
            SettingsSubRow(title: L10n.t(settings.menuBarLyricsScroll ? "显示宽度" : "超过就截断")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(settings.menuBarLyricsMaxChars) },
                        set: { settings.menuBarLyricsMaxChars = Int($0) }
                    ), in: 20...120, step: 5)
                    .frame(width: 150)
                    Text(String(format: L10n.t("%@ 字"), "\(settings.menuBarLyricsMaxChars)"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }

    // 两个悬浮窗共用的隐藏开关。标题用"自动隐藏"而不是"共用设置":它描述的是这两个开关
    // 实际在做的事,不管当下开着的是一个还是两个悬浮窗都成立。
    private var autoHideCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "eye.slash",
                title: L10n.t("自动隐藏"),
                subtitle: L10n.t("对悬浮歌词和灵动岛生效"),
                help: L10n.t("以下两项对「桌面悬浮歌词」和「灵动岛歌词」同时生效；菜单栏歌词和歌词窗口不受影响")
            )
            CardDivider()
            SettingsRow(
                icon: "camera.viewfinder",
                title: L10n.t("截屏/录屏时隐藏"),
                subtitle: L10n.t("别人看不到，你仍看得见"),
                help: L10n.t("截图、录屏、视频会议共享屏幕都不会拍到悬浮歌词")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.hideDuringScreenCapture },
                    set: { newValue in
                        settings.hideDuringScreenCapture = newValue
                        // 两个悬浮窗互不排斥,可能同时开着——应用到当前每一个确实启用了的
                        // 控制器,关闭的那个不碰(避免凭空构造出一个没人要的窗口,见
                        // NotchLyricsWindowController 顶部注释的那条不变量)。
                        if settings.classicOverlayEnabled {
                            LyricsOverlayWindowController.shared.setHiddenFromCapture(newValue)
                        }
                        if settings.notchOverlayEnabled {
                            NotchLyricsWindowController.shared.setHiddenFromCapture(newValue)
                        }
                    }
                ))
            }
            CardDivider()
            SettingsRow(icon: "pause.circle", title: L10n.t("暂停/无播放时隐藏")) {
                Toggle("", isOn: Binding(
                    get: { settings.hideWhenNotPlaying },
                    set: { newValue in
                        settings.hideWhenNotPlaying = newValue
                        if settings.classicOverlayEnabled {
                            LyricsOverlayWindowController.shared.setHideWhenNotPlaying(newValue)
                        }
                        if settings.notchOverlayEnabled {
                            NotchLyricsWindowController.shared.setHideWhenNotPlaying(newValue)
                        }
                    }
                ))
            }
        }
    }
}

// "播放器"分类——2026-07-30 从"通用"里拆出来:播放器选择/权限/常驻服务/App 联动这
// 几块内容全部围绕"选哪个播放器、能不能正常读到它的播放状态"转,是同一件事的四个
// 侧面;语言/开机启动/配置备份这些是完全不相干的杂项,继续留在"通用"里,不需要
// 陪着一起挪(用户反馈原来两类东西挤在一个 tab 里不好找)。
private struct PlayerSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    // 只在 .onAppear 和每次操作后重新查一次(askIfNeeded: false,不会弹窗,纯读状态)——
    // 不是 @Published,系统层面的权限变化(比如用户自己去系统设置里手动改)不会主动
    // 推送通知回来,只能在这个页面被看到的时候被动刷新一次。
    @State private var automationStatus: MusicAutomationPermissionStatus = .notDetermined
    // 见 OnboardingView 里同名属性的注释——请求权限这一步不能同步阻塞主线程,这两个
    // 状态管这次请求的"正在等待/等了太久还没结果"两档展示。
    @State private var isRequestingAutomation = false
    @State private var automationRequestTimedOut = false
    // collector 常驻服务是否真的在跑——跟 automationStatus 同样的道理，只在 .onAppear
    // 和每次操作后重新查一次，不是 @Published:这个状态由 launchd 管，App 自己不会主动
    // 收到"进程挂了"这类通知，只能被动查。
    @State private var collectorRunning = false
    @State private var isTogglingCollectorService = false
    // 2026-08-02 补上——之前点"启用"失败后,前台只会看到红叉+"未运行"跟从没点过一模
    // 一样,没有任何具体原因或下一步指引,用户卡在这里无计可施。只在"这次是想启用、结果
    // 没启动起来"时才为真,停用/切走这个 tab 都会清掉,不会把上一次失败的提示一直留着
    // 误导下一次操作。
    @State private var collectorEnableFailed = false

    var body: some View {
        SettingsPage(
            title: L10n.t("播放器"),
            subtitle: L10n.t("选择读取哪个 App 的播放状态，并确认它能被正常读到")
        ) {
            playerCard
            permissionCard
            collectorCard
            companionCard
        }
        .id(L10n.current)
    }

    // 切换后台采集服务(收集器只在启动时读一次这个设置)需要重启才生效,跟这个 store
    // 其它开关一样"保存即重启"。
    private var playerCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "music.note.list",
                title: L10n.t("播放器"),
                subtitle: L10n.t("选择 Lyrimuse 读取哪个 App 的播放状态")
            ) {
                Picker("", selection: Binding(
                    get: { features.player },
                    set: { features.player = $0; Task { await features.save() } }
                )) {
                    ForEach(PlaybackPlayer.allCases) { player in
                        Text(player.displayName).tag(player)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    // 本地数据源现在通过 AppleScript 直接问 Music.app(见 MediaControlClient.swift),
    // 这个权限因此从"可选、只影响播放进度精度"变成"核心路径必需、没有就完全看不到
    // 歌词",副标题特意说清楚这一点,别让人以为不给也无所谓。QQ 音乐/网易云/Spotify 走
    // 系统级 MediaRemote,不需要这个权限——那种情况下不是把这张卡整个撤掉(2026-08-02
    // 的教训:卡片凭空消失会让人怀疑是不是坏了),而是换成一句明确的"不需要授权"确认。
    @ViewBuilder
    private var permissionCard: some View {
        if features.player == .appleMusic {
            SettingsCard {
                SettingsRow(
                    icon: automationStatusIconName,
                    iconTint: automationStatusIconColor,
                    title: L10n.t("Apple Music 自动化"),
                    subtitle: automationStatusCaption + "・" + L10n.t("没有它，悬浮歌词/灵动岛都无法显示任何歌词内容")
                ) {
                    if isRequestingAutomation {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(automationActionTitle) { handleAutomationAction() }
                    }
                }
                if isRequestingAutomation {
                    CardDivider()
                    SettingsNote {
                        if automationRequestTimedOut {
                            Text(L10n.t("这次请求耗时有点久。如果你已经看到系统弹窗，请去处理它；找不到弹窗的话，可以直接去系统设置里手动开启"))
                            Button(L10n.t("打开系统设置")) {
                                NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
                            }
                        } else {
                            Text(L10n.t("请查看屏幕上弹出的系统授权对话框，选择「允许」"))
                        }
                    }
                }
            }
            .onAppear { automationStatus = MusicAutomationPermission.check(askIfNeeded: false) }
            // 见 OnboardingView 里同一处的注释:用户可能切去系统设置手动处理,切回来
            // 要重新读一次最新状态,并在已经不是 notDetermined 时清掉"正在等待"这套
            // UI,不然状态文字已经变了,下面却还卡在转圈/超时提示。
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                let latest = MusicAutomationPermission.check(askIfNeeded: false)
                automationStatus = latest
                if latest != .notDetermined {
                    isRequestingAutomation = false
                    automationRequestTimedOut = false
                }
            }
        } else {
            SettingsCard {
                SettingsRow(
                    icon: "checkmark.circle.fill",
                    iconTint: .green,
                    title: L10n.t("无需额外授权"),
                    subtitle: String(format: L10n.t("%@ 通过系统级机制读取播放状态，不需要在这里做额外授权"), features.player.displayName)
                )
            }
        }
    }

    // collector(读播放状态、抓歌词/封面写本地缓存的后台服务)用"状态图标 + 状态文字 +
    // 动作按钮"而不是简单 Toggle——需要展示"装了但没跑起来"这种中间态,纯 Toggle 表达不了。
    private var collectorCard: some View {
        SettingsCard {
            SettingsRow(
                icon: collectorStatusIconName,
                iconTint: collectorStatusIconColor,
                title: L10n.t("后台采集服务"),
                subtitle: collectorStatusCaption + "・" + L10n.t("负责读取播放状态、解析歌词/封面并写入本地缓存；没有它同样无法显示任何内容")
            ) {
                if isTogglingCollectorService {
                    ProgressView().controlSize(.small)
                } else {
                    Button(collectorActionTitle) { toggleCollectorService() }
                }
            }
            // 启用失败时给具体指引,不是只把红叉留在原地——这里能提供的具体行动是导出
            // 诊断信息(汇总 App/采集器日志),不是空泛地说"启用失败"。
            if collectorEnableFailed {
                CardDivider()
                SettingsNote {
                    Text(L10n.t("启用失败，可能是权限或系统限制导致后台服务没能正常启动，导出诊断信息能看到具体原因，也方便反馈问题"))
                    Button(L10n.t("导出诊断信息…")) { exportDiagnostics() }
                }
            }
        }
        .onAppear { collectorRunning = CollectorServiceManager.isRunning }
    }

    // 两个开关的文案跟着 features.player 走(Apple Music/QQ 音乐/...)——这两个联动本身
    // 已经改成跟着选定的播放器走(见 AppDelegate.swift/companionlaunch.go),文案继续写死
    // "Apple Music"会跟实际行为对不上。选了"自动识别"(.auto)时这两个方向不对称:
    // "打开 Lyrimuse 时启动 X"没有唯一确定的 X,直接隐藏这个开关(而不是显示一句"打开
    // 自动识别时启动 Lyrimuse"这种读不通的文案);"打开 X 时启动 Lyrimuse"反而在自动识别
    // 模式下更有用——companionlaunch.go 这时会同时盯着全部四个已知播放器的进程。
    private var companionCard: some View {
        SettingsCard {
            if features.player != .auto {
                SettingsRow(
                    icon: "arrow.up.forward.app",
                    title: String(format: L10n.t("打开 Lyrimuse 时启动 %@"), features.player.displayName)
                ) {
                    Toggle("", isOn: $settings.launchMusicOnLyrimuseOpen)
                }
                CardDivider()
            }
            SettingsRow(
                icon: "arrow.down.app",
                title: features.player == .auto
                    ? L10n.t("打开任意已知播放器时启动 Lyrimuse")
                    : String(format: L10n.t("打开 %@ 时启动 Lyrimuse"), features.player.displayName),
                subtitle: L10n.t("由后台采集服务负责监测，需要先启用上面的「后台采集服务」才会生效")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.launchLyrimuseOnMusicOpen },
                    set: { features.launchLyrimuseOnMusicOpen = $0; Task { await features.save() } }
                ))
            }
        }
    }

    private var automationStatusCaption: String {
        switch automationStatus {
        case .authorized: return L10n.t("已授权")
        case .denied: return L10n.t("已拒绝")
        case .notDetermined: return L10n.t("未授权")
        }
    }

    private var automationStatusIconName: String {
        switch automationStatus {
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        }
    }

    private var automationStatusIconColor: Color {
        switch automationStatus {
        case .authorized: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }

    // 还没问过才提供"请求权限"(会真的弹系统对话框);已经有结果(不管授权还是拒绝)
    // 系统不会重复弹窗,只能引导去系统设置——两种情况下按钮都跳转同一个面板。
    private var automationActionTitle: String {
        automationStatus == .notDetermined ? L10n.t("请求权限") : L10n.t("打开系统设置")
    }

    private func handleAutomationAction() {
        if automationStatus == .notDetermined {
            requestAutomationPermission()
        } else {
            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
        }
    }

    // 见 OnboardingView 里同名函数的注释——不能在按钮点击回调里同步调用,那样会把
    // 整个 App UI 冻结、表现成"点了没反应"(AEDeterminePermissionToAutomateTarget
    // 在主线程调用有据可查的"可能永久挂起"系统级已知问题)。
    private func requestAutomationPermission() {
        isRequestingAutomation = true
        automationRequestTimedOut = false
        Task {
            if let status = await MusicAutomationPermission.requestWithTimeout() {
                automationStatus = status
                isRequestingAutomation = false
                automationRequestTimedOut = false
            } else {
                automationRequestTimedOut = true
            }
        }
    }

    private var collectorStatusCaption: String {
        collectorRunning ? L10n.t("运行中") : L10n.t("未运行")
    }

    private var collectorStatusIconName: String {
        collectorRunning ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var collectorStatusIconColor: Color {
        collectorRunning ? .green : .red
    }

    private var collectorActionTitle: String {
        collectorRunning ? L10n.t("停用") : L10n.t("启用")
    }

    private func toggleCollectorService() {
        let enabling = !collectorRunning
        isTogglingCollectorService = true
        collectorEnableFailed = false
        Task {
            let running = await CollectorServiceManager.setEnabledAndWait(enabling)
            settings.collectorServiceEnabled = enabling
            collectorRunning = running
            isTogglingCollectorService = false
            // 只有"这次是想启用"且结果确实没跑起来才算失败——停用操作本身就是想让它
            // 不运行,running==false 是预期结果,不能也标红报错。
            collectorEnableFailed = enabling && !running
        }
    }

    // 跟"关于"tab 里"导出诊断信息"按钮同一份实现(DiagnosticsExporter 是无状态的纯
    // 静态工具,两处各自调用即可,不需要抽共享 View)——常驻服务启用失败时给用户一个
    // 具体能做的事,而不是让红叉停在原地不知道下一步。
    private func exportDiagnostics() {
        let report = DiagnosticsExporter.buildReport()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsExporter.suggestedFilename()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        if panel.runModal() == .OK, let url = panel.url {
            try? report.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showExportConfigWarning = false
    @State private var showImportConfigConfirm = false
    @State private var pendingImportData: Data?
    @State private var showClearConfigWarning = false

    var body: some View {
        SettingsPage(
            title: L10n.t("通用"),
            subtitle: L10n.t("语言、启动方式，以及把全部配置搬到另一台 Mac")
        ) {
            SettingsCard {
                // 下拉菜单而不是分段控件——分段控件的宽度会随选项数线性变宽,以后再加
                // 语言(繁体中文/日语等)容易挤爆这一行;下拉菜单不管加多少个选项,这一行
                // 的宽度都不变。
                SettingsRow(icon: "globe", title: L10n.t("语言")) {
                    Picker("", selection: $settings.appLanguage) {
                        Text(L10n.t("跟随系统")).tag("system")
                        Text(L10n.t("简体中文")).tag("zh-hans")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                CardDivider()
                SettingsRow(icon: "power", title: L10n.t("开机启动")) {
                    Toggle("", isOn: $settings.launchAtLoginEnabled)
                }
                CardDivider()
                SettingsRow(
                    icon: "macwindow",
                    title: L10n.t("在 Dock 中显示"),
                    subtitle: L10n.t("关闭后只保留菜单栏图标，不占 Dock 位置")
                ) {
                    Toggle("", isOn: $settings.showInDock)
                }
            }

            // 导入/导出打包 collector 的 config.json(账号 token 原文都在里面)+
            // features.json + App 自己的偏好设置,合并成一份 JSON。刻意跟"导出诊断
            // 信息"反着来:那个绝不能带任何 token(设计给贴进公开 issue),这个就是要把
            // token 原样带走(设计给换新机器用)——两处的用户提示因此也刻意写成相反的
            // 语气。
            //
            // 三条说明原来是**一整段** Section footer,三件事挤在一句话里;拆成各自行下面
            // 的副标题之后,每条只讲它自己那个按钮会发生什么,尤其"会覆盖""无法撤销"这类
            // 后果紧贴着对应的按钮,不用读者自己去对应。
            SettingsCard {
                SettingsRow(
                    icon: "square.and.arrow.up",
                    title: L10n.t("导出配置"),
                    subtitle: L10n.t("文件里包含账号 token、密钥等敏感信息，注意妥善保管，不要分享给他人")
                ) {
                    Button(L10n.t("导出…")) { showExportConfigWarning = true }
                }
                CardDivider()
                SettingsRow(
                    icon: "square.and.arrow.down",
                    title: L10n.t("导入配置"),
                    subtitle: L10n.t("会覆盖当前所有设置（包括已连接的账号），并立即重启 Lyrimuse")
                ) {
                    Button(L10n.t("导入…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowedContentTypes = [.json]
                        panel.prompt = L10n.t("导入")
                        if panel.runModal() == .OK, let url = panel.url,
                           let data = try? Data(contentsOf: url) {
                            pendingImportData = data
                            showImportConfigConfirm = true
                        }
                    }
                }
                CardDivider()
                SettingsRow(
                    icon: "trash",
                    title: L10n.t("清除所有配置"),
                    subtitle: L10n.t("抹掉所有账号和个人设置，恢复到刚装完时的样子，且无法撤销")
                ) {
                    DestructiveButton(title: L10n.t("清除…")) { showClearConfigWarning = true }
                }
            }
            .alert(L10n.t("确定要导出配置吗？"), isPresented: $showExportConfigWarning) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("继续导出")) {
                    guard let data = ConfigPortability.buildExportData() else { return }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = ConfigPortability.suggestedFilename()
                    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                    if panel.runModal() == .OK, let url = panel.url {
                        try? data.write(to: url, options: .atomic)
                    }
                }
            } message: {
                Text(L10n.t("导出的文件包含你的账号 token、密钥等敏感信息，请妥善保管，不要分享给他人"))
            }
            .alert(L10n.t("确定要导入这份配置吗？"), isPresented: $showImportConfigConfirm) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("导入并重启"), role: .destructive) {
                    if let data = pendingImportData {
                        ConfigPortability.importData(data)
                        ConfigPortability.restartApp()
                    }
                }
            } message: {
                Text(L10n.t("这会覆盖当前所有设置（包括已连接的账号），并立即重启 Lyrimuse 使其生效"))
            }
            .alert(L10n.t("确定要清除所有配置吗？"), isPresented: $showClearConfigWarning) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("清除并重启"), role: .destructive) {
                    ConfigPortability.clearAllConfig()
                    ConfigPortability.restartApp()
                }
            } message: {
                Text(L10n.t("这会清除所有账号 token、密钥和个人设置，恢复到刚装完时的样子（下次启动会重新走一遍引导向导），且无法撤销。如果还没备份过，建议先用上面「导出配置」那一行的「导出…」按钮备份一份"))
            }
        }
        .id(L10n.current)
    }
}

// "快捷键"分类——原来跟"通用"tab 挤在一起,内容量(6 个悬浮歌词相关快捷键+1 个步长
// 调节+3 个播放控制快捷键)比"通用"其它几块加起来还多,拆成独立分类。
private struct ShortcutsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // "至少需要搭配 ⌘/⌥/⌃ 中一个"这条限制对本页每一个录制框都成立,所以挪到页面说明
        // 里(原来是第一组 Section 的 footer,只挨着上面那一组,下面"播放控制"那一组的
        // 录制框其实也受这条限制,却看不到这句话)。这条规则本身照抄 KeyboardShortcuts
        // 库自带 Recorder 的行为(见 ShortcutRecorder.swift 里 handle(_:) 的注释),不是
        // 这个项目额外加的限制——但它只会"响一声"、没有任何文字提示,必须写出来。
        SettingsPage(
            title: L10n.t("快捷键"),
            subtitle: L10n.t("全局快捷键在任何 App 里都能触发。至少需要搭配 ⌘/⌥/⌃ 中一个（功能键、媒体键除外）")
        ) {
            SettingsCard {
                SettingsRow(icon: "eye", title: L10n.t("显示/隐藏悬浮歌词")) {
                    ShortcutRecorderControl(name: .toggleOverlay)
                }
                CardDivider()
                SettingsRow(icon: "lock", title: L10n.t("锁定/解锁位置")) {
                    ShortcutRecorderControl(name: .toggleLockPosition)
                }
                CardDivider()
                SettingsRow(icon: "list.bullet.rectangle", title: L10n.t("打开歌词管理")) {
                    ShortcutRecorderControl(name: .openLyricsManagerHotkey)
                }
                CardDivider()
                SettingsRow(icon: "text.quote", title: L10n.t("打开歌词窗口")) {
                    ShortcutRecorderControl(name: .openLyricsWindowHotkey)
                }
                CardDivider()
                SettingsRow(icon: "gearshape", title: L10n.t("打开设置")) {
                    ShortcutRecorderControl(name: .openSettingsHotkey)
                }
            }

            SettingsCard {
                SettingsRow(
                    icon: "backward.end",
                    title: L10n.t("歌词提前"),
                    subtitle: L10n.t("按当前这首歌记忆校准值，下次再放这首歌自动生效")
                ) {
                    ShortcutRecorderControl(name: .lyricsAdvanceHotkey)
                }
                CardDivider()
                SettingsRow(icon: "forward.end", title: L10n.t("歌词延后")) {
                    ShortcutRecorderControl(name: .lyricsDelayHotkey)
                }
                CardDivider()
                // 每次调整的步长——跟菜单栏"歌词时间轴"共用同一个值,这里改了菜单里的
                // 按钮文案/快捷键的实际调整量会一起变。0.05~2s 区间对"手动校准"这个场景
                // 够用,不需要再大或者再细。
                //
                // ⚠️ 数值必须作为**独立内容**摆在 Stepper 外面,不能塞进 Stepper 的 label:
                // SettingsRow/SettingsSubRow 对尾部控件统一套了 .labelsHidden()(用来藏掉
                // Toggle/Picker 自带的、会跟行标题重复的那份标签),而 Stepper 恰恰是把数值
                // 画在 label 里的——放进去会被一并藏掉,界面上只剩一对光秃秃的上下箭头,
                // 完全看不出当前步长是多少(2026-08-06 实机确认过是这个症状)。
                //
                // 同时从 SettingsSubRow 换成完整的 SettingsRow:原来只有"每次调整"四个字,
                // 没说清调的是什么、影响哪里,配上图标和副标题才自解释。
                SettingsRow(
                    icon: "timer",
                    title: L10n.t("调整步长"),
                    subtitle: L10n.t("「歌词提前」「歌词延后」每按一次的幅度；菜单栏的「歌词时间轴」也用这个值")
                ) {
                    HStack(spacing: 8) {
                        Text("\(AppSettings.formattedSeconds(ms: settings.lyricsOffsetStepMs))\(L10n.t("秒"))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("", value: Binding(
                            get: { Double(settings.lyricsOffsetStepMs) / 1000 },
                            set: { settings.lyricsOffsetStepMs = Int(($0 * 1000).rounded()) }
                        ), in: 0.05...2.0, step: 0.05)
                    }
                }
            }

            SettingsCard {
                SettingsRow(icon: "playpause", title: L10n.t("播放/暂停")) {
                    ShortcutRecorderControl(name: .playPauseHotkey)
                }
                CardDivider()
                SettingsRow(icon: "forward.fill", title: L10n.t("下一首")) {
                    ShortcutRecorderControl(name: .nextTrackHotkey)
                }
                CardDivider()
                SettingsRow(icon: "backward.fill", title: L10n.t("上一首")) {
                    ShortcutRecorderControl(name: .previousTrackHotkey)
                }
            }
        }
        .id(L10n.current)
    }
}

// "关于"分类——参考常见 macOS App 的"关于本 App"面板(图标+名称+版本居中,下面分组
// 罗列简介/仓库链接/版权)。这几项都是静态文本/链接,不需要任何 @Published 状态或
// 单例,是这几个 tab 里最简单的一个,只留最基本的身份信息+反馈入口。
private struct AboutSettingsTab: View {
    // CFBundleIconFile 指向 AppIcon.icns(build.sh 生成的 .app 包本身自带),直接读
    // 系统认的这份"当前 App 图标",不用再手动拼一遍 Bundle 里的文件路径。
    private var appIcon: NSImage { NSApplication.shared.applicationIconImage }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        // 这一页的页头本身就是"App 身份"(图标 + 名称 + 版本 + 一句简介),所以直接用
        // SettingsPage 的 heroImage/title/subtitle 三件套承担,不另外再搭一张卡。
        SettingsPage(
            title: "Lyrimuse",
            subtitle: String(format: L10n.t("版本 %@"), versionString) + "\n"
                + L10n.t("跟着 Apple Music、QQ 音乐、网易云或 Spotify 播放，实时显示逐字同步歌词，还能一键同步播放记录到 Last.fm"),
            heroImage: appIcon
        ) {
            SettingsCard {
                // Sparkle 自己处理"检查中/已是最新/发现新版本"这几种状态的 UI 展示
                // (SPUStandardUserDriver 的标准弹窗),不需要自己维护 loading 状态或者
                // 判断结果再手动弹 alert。
                SettingsRow(icon: "arrow.triangle.2.circlepath", title: L10n.t("检查更新")) {
                    Button(L10n.t("检查更新…")) {
                        SparkleUpdaterManager.shared.checkForUpdates()
                    }
                }
                CardDivider()
                SettingsRow(icon: "chevron.left.forwardslash.chevron.right", title: L10n.t("GitHub 仓库")) {
                    Button(L10n.t("打开")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse")!)
                    }
                }
                CardDivider()
                SettingsRow(icon: "exclamationmark.bubble", title: L10n.t("反馈问题")) {
                    Button(L10n.t("打开")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse/issues")!)
                    }
                }
            }

            SettingsCard {
                // collector 日志一直写得比较完整,但 App 自己的日志全在系统统一日志里,
                // 普通人不会用 Console.app 去查。这里一键把两边日志+关键状态(权限/常驻
                // 服务/各功能是否已配置,不含任何 token 原始值)汇总成一份文本存到桌面,
                // 方便贴进 issue 或者发给开发者。
                SettingsRow(
                    icon: "doc.text.magnifyingglass",
                    title: L10n.t("导出诊断信息"),
                    subtitle: L10n.t("汇总 App/采集器日志和权限、常驻服务等关键状态，保存成一份文本文件，不会包含任何账号 token 或密钥的原始内容")
                ) {
                    Button(L10n.t("导出…")) {
                        let report = DiagnosticsExporter.buildReport()
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = DiagnosticsExporter.suggestedFilename()
                        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                        if panel.runModal() == .OK, let url = panel.url {
                            try? report.write(to: url, atomically: true, encoding: .utf8)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }

            // 落地页(微信/支付宝收款码)是独立的通用小仓库 Yudaotor/donate,托管在
            // GitHub Pages 上,不跟 Lyrimuse 这一个项目绑定,后续其它项目也能复用——
            // 这里只是一个外链按钮。放在卡片之外单独居中,因为它不是一条"设置",
            // 混进卡片列里反而像一个可以开关的选项。
            Button {
                NSWorkspace.shared.open(URL(string: "https://yudaotor.github.io/donate/")!)
            } label: {
                Label(L10n.t("请作者喝杯咖啡"), systemImage: "cup.and.saucer.fill")
            }
            .settingsProminentGlassButton(tint: .orange)
            .padding(.top, 4)

            Text("© 2026 Yudaotor")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        // SwiftUI 有时不会在语言切换后重新执行某些嵌套内容的 body(取决于该内容自己的
        // 存储属性有没有变,而非父视图是否重新渲染,详见 AccountLinkingTab.swift 里
        // DestinationStatus.label 的注释)。用 .id(L10n.current) 把整页的身份跟当前语言
        // 绑死,语言一变就强制整体重新构造,不需要逐个排查哪里在跳过刷新。
        .id(L10n.current)
    }
}
