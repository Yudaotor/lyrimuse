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

    var body: some View {
        Form {
            // 播放位置现在通过 AppleScript 问 Music.app(见 MediaControlClient.swift)
            // 得到精确值,不再有"精确/估算"两条路径可选,所以没有对应开关——自动化权限
            // 是显示歌词的必要前提,状态统一显示在"通用"tab 的"权限"分区。
            Section(L10n.t("解析")) {
                Toggle(isOn: Binding(
                    get: { features.lyrics },
                    set: { features.lyrics = $0; Task { await features.save() } }
                )) {
                    HStack(spacing: 4) {
                        Text(L10n.t("歌词在线匹配"))
                        HelpButton(text: L10n.t("控制要不要在线解析歌词。关闭后，第一次播放的新歌不会再去查下面「歌词来源」里的这些平台，只用本地已经缓存过的结果（如果有）。「歌词来源」「匹配算法」这两组设置都只在这个开关开启时才有意义"))
                    }
                }
                // "解析"(而非"预取")避免被误读成预先加载音频本身,这个开关从不碰音频。
                Toggle(isOn: Binding(
                    get: { features.albumPrefetch },
                    set: { features.albumPrefetch = $0; Task { await features.save() } }
                )) {
                    HStack(spacing: 4) {
                        Text(L10n.t("提前解析同专辑其它曲目"))
                        HelpButton(text: L10n.t("换到一首歌时，如果它属于某张专辑，会顺带在后台把同专辑里还没解析过的其它曲目也提前解析。封面无条件都会解析，歌词是否被预取取决于上面的「歌词在线匹配」开关是否开启"))
                    }
                }
            }

            // 拆成两件事:"歌词来源"决定查哪些源(至少留一个,不然歌词解析开着却什么都
            // 不查毫无意义);"匹配算法"决定从查到的结果里怎么选——智能算法沿用五源
            // 打分取最高分,顺序优先则完全听用户排的顺序、不比分数。实现在
            // collector/enrich.go 的 pickLyricCandidate,故意不影响"歌词管理"窗口的
            // 手动搜索(那边永远查全部五源,理由见它的注释)。
            //
            // 这两组 Section 只在 features.lyrics(上面"歌词在线匹配"开关)打开时才
            // 显示——2026-08-02 补上:上面 HelpButton 文字明确写了"这两组设置都只在
            // 这个开关开启时才有意义",但 UI 上一直没有跟着做,关掉在线匹配后这两组
            // 依然完全正常可交互,用户会以为调了就生效。跟下面"灵动岛风格"/"歌词窗口"
            // 这两处已有的"父开关关闭就整体不显示"是同一个既有模式,不是新发明一套。
            if features.lyrics {
            Section {
                ForEach(LyricsSource.allCases) { source in
                    Toggle(isOn: Binding(
                        get: { features.lyricsSources.contains(source) },
                        set: { newValue in
                            if newValue {
                                features.lyricsSources.insert(source)
                            } else if features.lyricsSources.count > 1 {
                                features.lyricsSources.remove(source)
                            }
                            Task { await features.save() }
                        }
                    )) {
                        HStack(spacing: 6) {
                            Circle().fill(source.color).frame(width: 8, height: 8)
                            Text(source.displayName)
                        }
                    }
                }
            } header: {
                Text(L10n.t("歌词来源"))
            } footer: {
                Text(L10n.t("至少需要保留一个歌词来源"))
            }

            // Section 的 header/footer 只要塞进去的不是纯 Text(哪怕只是 Text+
            // HelpButton 这种最简单的 HStack),整个内容(连纯文字部分)都不出现在
            // 可访问性树里——跟 accountHintRow 上那个"footer 里嵌 Button 拿不到"是
            // 同一类限制,这次连 header、连纯 Text 都受影响。说明/操作一律放回 Section
            // 正文,header/footer 只留死板的字符串字面量。
            Section(L10n.t("匹配算法")) {
                // .labelsHidden()——Picker 自带的标签文字会跟上面 header 逐字重复
                // (两行同一句话叠在一起),这里隐藏掉,下面单独一行放简短说明+"?"。
                Picker(selection: Binding(
                    get: { features.lyricsSourceMode },
                    set: { features.lyricsSourceMode = $0; Task { await features.save() } }
                )) {
                    ForEach(LyricsSourceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text(L10n.t("匹配算法"))
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                HStack(spacing: 4) {
                    Text(L10n.t("智能算法自动打分选最高分，顺序优先按你排的顺序来"))
                        .font(.caption2).foregroundStyle(.secondary)
                    HelpButton(text: L10n.t("智能算法：查到的每个来源都打分（逐字时间轴、语言是否匹配等维度），自动挑分数最高的一条。顺序优先：按下面排的顺序，用第一个查到有效结果的来源，不比较分数"))
                }

                if features.lyricsSourceMode == .priority {
                    ForEach(Array(orderedEnabledSources.enumerated()), id: \.element) { index, source in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .trailing)
                            Circle().fill(source.color).frame(width: 8, height: 8)
                            Text(source.displayName)
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
            } // features.lyrics

            Section {
                Picker(selection: Binding(
                    get: { features.lyricsTranslationLanguage },
                    set: { features.lyricsTranslationLanguage = $0; Task { await features.save() } }
                )) {
                    ForEach(MusixmatchTranslationLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                } label: {
                    Text(L10n.t("译文语言"))
                }
            } header: {
                Text(L10n.t("译文语言"))
            } footer: {
                Text(L10n.t("仅对 Musixmatch 来源生效，网易云音乐/QQ音乐的译文固定是中文"))
            }

            Section {
                Toggle(L10n.t("优先逐字高亮（有的话）"), isOn: Binding(
                    get: { settings.preferWordLevelKaraoke },
                    set: { newValue in
                        settings.preferWordLevelKaraoke = newValue
                        local.preferWordLevelKaraoke = newValue
                    }
                ))
                Toggle(isOn: $settings.showRomanization) {
                    HStack(spacing: 4) {
                        Text(L10n.t("显示罗马音"))
                        // 2026-08-04 从常驻 footer caption 改成按需展开的 HelpButton——
                        // 跟本 Section 里"歌词在线匹配"等开关同一个既有约定(见 HelpButton
                        // 顶部注释:常驻 caption 留给"一眼扫过就该知道"的内容,这类需要
                        // 多一点背景知识才看得懂的说明按需展开)。这条说明原来整段常驻在
                        // footer,但内容其实只跟这两个具体开关有关,挤在 Section 底部反而
                        // 不如直接挂在对应开关旁边醒目。
                        HelpButton(text: L10n.t("这个开关只影响「桌面悬浮歌词」和「歌词窗口」；灵动岛歌词受限于胶囊空间不支持这一项，菜单栏歌词只能显示一行纯文字"))
                    }
                }
                Toggle(isOn: $settings.showTranslation) {
                    HStack(spacing: 4) {
                        Text(L10n.t("显示译文"))
                        HelpButton(text: L10n.t("这个开关只影响「桌面悬浮歌词」和「歌词窗口」；灵动岛歌词受限于胶囊空间不支持这一项，菜单栏歌词只能显示一行纯文字"))
                    }
                }
                Toggle(L10n.t("双行显示（预览下一句歌词）"), isOn: $settings.showNextLinePreview)
            } header: {
                Text(L10n.t("展示"))
            }

            Section {
                // accessory 策略下打开新窗口得先手动激活 App,不然 openWindow 调了也
                // 没反应——跟 MenuBarMenu.swift 里"歌词管理…"菜单项同一个坑、同一个
                // 修法,这里复用一模一样的写法。
                Button(L10n.t("打开歌词管理…")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "lyrics-manager")
                }

                LabeledContent {
                    Text(features.effectiveLyricsDir.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.t("歌词文件夹"))
                        HelpButton(text: L10n.t("歌词默认就以这个文件夹为准维护。联网匹配到的结果会导出成文件存在这里，「歌词管理」里手动导入/编辑的文件也在这里。换成新文件夹后，旧文件夹里已有的文件不会自动搬过去，需要自己手动移动"))
                    }
                }

                HStack {
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
                    if !features.lyricsDir.isEmpty {
                        Button(L10n.t("恢复默认位置")) {
                            features.lyricsDir = ""
                            Task { await features.save() }
                        }
                        .buttonStyle(.link)
                    }
                    Spacer()
                    Button(L10n.t("打开歌词文件夹")) {
                        let url = features.effectiveLyricsDir
                        // collector 那边(见 collector/lyricsexport.go)只在真正解析/导出过至少
                        // 一首歌之后才会建这个目录,这里先兜底建一下,避免文件夹还不存在时
                        // NSWorkspace 打不开、又没有任何提示。
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
            } header: {
                Text(L10n.t("管理"))
            } footer: {
                Text(L10n.t("每首歌听过一次，歌词就会永久保存在这个文件夹里；在「歌词管理」里删除会同时删掉这里已导出的文件"))
            }
        }
        .formStyle(.grouped)
        // SwiftUI 有时不会在语言切换后重新执行某些嵌套内容的 body(取决于该内容自己的
        // 存储属性有没有变,而非父视图是否重新渲染,详见 AccountLinkingTab.swift 里
        // DestinationStatus.label 的注释)。用 .id(L10n.current) 把 Form 的身份跟当前
        // 语言绑死,语言一变就强制整体重新构造,不需要逐个排查哪里在跳过刷新。
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
        // .formStyle(.grouped) 是 macOS 13+ 原生"系统设置"式外观(圆角分组卡片+
        // 灰色小标题+尾注)——分组样式下 ColorPicker/字体 Picker 不会被拉伸成贯穿整行
        // 的长条,说明性文字也有明确的"尾注"位置,不会跟控件混在一起,排版全部是
        // SwiftUI 原生处理,不用手工调间距。
        //
        // 2026-08-05 按"每种展示方式各占一张卡片"重排。改动前是按"设置的种类"分卡的,
        // 用户反馈几种歌词模式的设置混在一起、看不清哪一项属于谁。具体是三处混淆:
        // ① "歌词展示"这张卡里,四个总开关之间插着灵动岛的三项、菜单栏的三项子设置,
        //    子设置跟总开关同级并排,看不出它属于上面哪一个开关;
        // ② "外观"卡(配色/字体/字号)其实只对桌面悬浮歌词生效,但它是一张独立卡片、位置
        //    又紧跟在四个总开关下面,视觉上像是对四种方式都生效,只能靠一句尾注去解释;
        // ③ "悬浮歌词窗口"卡里"宽度/锁定位置"是桌面悬浮歌词专属,"截屏时隐藏/暂停时隐藏"
        //    两项却对灵动岛同样生效(见各自 set 闭包里两个控制器都会调),那个标题对后两项
        //    并不精确——改动前的注释里已经承认过这一点,但没拆。
        //
        // 现在的结构:"歌词展示"只放四个总开关;之后每种展示方式各自一张卡,卡片标题就是
        // 这种方式的名字、且只在这种方式开着时才出现;真正两个悬浮窗共用的两个隐藏开关
        // 单独一张卡。"这一项属于哪种展示方式"由卡片归属直接回答,不再依赖尾注解释。
        //
        // 歌词窗口没有自己的卡片——它一个可配置项都没有,只有总开关那一行。
        Form {
            displayModesSection
            // 每种方式的详细设置只在这种方式开着时才出现——沿用改动前灵动岛/菜单栏子设置
            // 的既有做法,关掉的方式不留一张空卡占位。
            if settings.classicOverlayEnabled { classicOverlaySection }
            if settings.notchOverlayEnabled { notchOverlaySection }
            if settings.showLyricsInMenuBar { menuBarSection }
            // 这两个开关只作用于两个悬浮窗(菜单栏歌词/歌词窗口不受影响),两个悬浮窗都
            // 关着时整张卡没有意义,不显示。
            if settings.classicOverlayEnabled || settings.notchOverlayEnabled { autoHideSection }
        }
        .formStyle(.grouped)
        // SwiftUI 有时不会在语言切换后重新执行某些嵌套内容的 body(取决于该内容自己的
        // 存储属性有没有变,而非父视图是否重新渲染,详见 AccountLinkingTab.swift 里
        // DestinationStatus.label 的注释)。用 .id(L10n.current) 把 Form 的身份跟当前
        // 语言绑死,语言一变就强制整体重新构造,不需要逐个排查哪里在跳过刷新。
        //
        // 2026-08-05 补回这个修饰符:它本来是 8e3f8fd("Fix language-switch staleness")
        // 一次性给几个 Form 都加上的,后来拆分 tab 的几次重构把修饰符丢了、上面这段注释
        // 却留了下来,变成"注释描述了一个并不存在的修复"。本文件还有另外 4 个 Form 是
        // 同样的状态(歌词/播放器/通用/关于),不在这次改动范围内。
        .id(L10n.current)
    }

    // 四个总开关。四种展示方式互不冲突,可以同时开、只开一个、或者都不开;每个开关只
    // 负责"生效"它自己那一个控制器,不碰另一个。
    //
    // 前两个的 set 只调 setVisible(_:) 一句:2026-08-05 把"这个模式开没开"合并成单一
    // 开关之后,写回 AppSettings.{classic,notch}OverlayEnabled 和"顺手应用两个已配置好的
    // 隐藏偏好"都收进了 setVisible(_:) 里面,这里再各自写一遍就是两个写入方,又会漂移。
    private var displayModesSection: some View {
        Section {
            Toggle(L10n.t("桌面悬浮歌词"), isOn: Binding(
                get: { settings.classicOverlayEnabled },
                set: { LyricsOverlayWindowController.shared.setVisible($0) }
            ))
            Toggle(L10n.t("灵动岛歌词"), isOn: Binding(
                get: { settings.notchOverlayEnabled },
                set: { NotchLyricsWindowController.shared.setVisible($0) }
            ))
            Toggle(L10n.t("菜单栏歌词"), isOn: $settings.showLyricsInMenuBar)
            // "歌词窗口"(正经的标题栏窗口,完整歌词列表+自动滚动)不像上面三个那样有一个
            // AppSettings 持久化的布尔开关来控制——它的开合状态完全交给 SwiftUI Window(id:)
            // 自己的窗口自动存档机制(见 App.swift 那个场景的注释),这里的 Toggle 只是
            // "现在这扇窗口是不是开着"的实时状态(见 LyricsWindowPresence 注释),开/关直接
            // 对应打开/关闭这扇窗口,不写入任何新的持久化配置项。
            Toggle(L10n.t("歌词窗口"), isOn: Binding(
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
        } header: {
            Text(L10n.t("歌词展示"))
        } footer: {
            // 这四个开关互相独立、可以同时开,但没有引导的话新用户第一次打开这个页面容易
            // 不知道该开哪个/是否可以全开。一句话各自说清典型使用场景,不展开成四段说明。
            Text(L10n.t("四种展示方式互不冲突，可以同时开启：桌面悬浮歌词贴在桌面上、支持逐字高亮；灵动岛歌词紧凑地贴着刘海显示；菜单栏歌词最不打扰、只占状态栏一行文字；歌词窗口是可以滚动阅读的完整歌词列表"))
        }
    }

    // 桌面悬浮歌词(经典悬浮窗)专属的一整套:窗口几何(宽度/锁定位置)+ 配色与字体。
    //
    // 配色/字体挪进这张卡是这次重排的核心一步。2026-08-05 全仓核对过消费方,确认这些设置
    // 确实只对这一种展示方式生效:mainFont/romanizationFont/translationFont 和
    // foregroundColor/backgroundColor/textStrokeColor 的读取点全部落在
    // LyricsOverlayView.swift 一个文件里(灵动岛/歌词窗口各自用固定的系统配色,菜单栏歌词
    // 是纯文字,都不读这些字段)。所以它们本来就该跟这个模式绑在同一张卡里,而不是单独一张
    // 看起来全局生效的"外观"卡 + 一句尾注。
    private var classicOverlaySection: some View {
        Section {
            LabeledContent(L10n.t("宽度")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { settings.overlayWidth },
                        set: { newValue in
                            settings.overlayWidth = newValue
                            LyricsOverlayWindowController.shared.setWidth(newValue)
                        }
                    ), in: 420...1000, step: 10)
                    Text(String(format: L10n.t("%@pt"), "\(Int(settings.overlayWidth))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            // "解锁后长按才能拖动"这个手势不直观(不看说明容易只当成"按住就能拖",或者
            // 反过来以为"这窗口点不动了"),必须有一句显式说明。改动前它挂在整个 Section 的
            // footer 里、跟"截屏时隐藏"那句挤在一个 VStack 中——那个写法有两个问题:一是
            // 本文件既定的约束是 header/footer 只放纯 Text 字面量(塞 VStack/HStack 进去
            // 整段文字都拿不到可访问性,见"匹配算法"那一节上面的注释),二是说明离它描述的
            // 那个开关隔了好几行。改成挂在开关自己身上的 HelpButton,跟"显示专辑封面"
            // "超宽时横向滚动"这两处已有做法一致。
            Toggle(isOn: Binding(
                get: { settings.lockPosition },
                set: { newValue in
                    settings.lockPosition = newValue
                    LyricsOverlayWindowController.shared.setLocked(newValue)
                }
            )) {
                HStack(spacing: 4) {
                    Text(L10n.t("锁定位置"))
                    HelpButton(text: L10n.t("解锁「锁定位置」后，悬浮歌词默认可以直接点击穿透到它下面的内容；长按住悬浮歌词不放，才能拖动它的位置"))
                }
            }

            // 配色主题——内置预设一键套用+把当前调好的配色另存复用,对标 PlayStatus/
            // Lyricify/AlgerMusicPlayer/HotLyric/VutronMusic 都有的这层。只打包"配色"
            // 相关的四个字段(文字/背景/阴影颜色+阴影开关),不含字体/字号——那是排版,
            // 跟配色是两回事,不该被同一个"主题"捆在一起改(见 ColorTheme.swift)。
            // 套用即时生效,跟下面手动挪动色板是同一套 Binding,没有额外的"应用"步骤。
            // Menu 的标签本身显示"当前配色正好等于哪个主题"(不等于任何一个就显示
            // "自定义"),作为这个 Menu 唯一的选中反馈。
            Menu(currentColorThemeLabel) {
                // "跟随封面"(2026-08-03 新增)——不是一个固定配色,是"改用当前曲目
                // 封面算出的动态高亮色"这个模式本身,跟下面的具体命名主题放在同一个
                // Menu 里、用 Divider 隔开,表明这是另一类选项。只影响前景色(见
                // PlaybackCoordinator.displayForegroundColor),背景色/描边仍然用
                // 下面手动挑的固定值,没有封面数据时前景也退回下面选的固定色——不是
                // 一整套独立的"主题",维持这个文件"配色只管四个字段"的既有范围。
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
            if settings.followsCoverArt {
                Text(L10n.t("没有封面数据时会使用下面选择的文字颜色作为备用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.customColorThemes) { theme in
                HStack {
                    Button(theme.name) { applyColorTheme(theme) }
                        .buttonStyle(.plain)
                    Spacer()
                    Button {
                        settings.customColorThemes.removeAll { $0.id == theme.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            Button(L10n.t("将当前配色存为新主题…")) {
                newThemeName = ""
                showSaveThemeAlert = true
            }
            .buttonStyle(.link)

            Picker(L10n.t("字体"), selection: $settings.fontFamilyName) {
                // 这一项原来也叫「跟随系统」,跟语言选择器那一项撞成同一个 L10n key
                // ("跟随系统"),而 .strings 里一个 key 只能有一个值——两处需要的英文
                // 不一样("Follow System" vs 字体语境下的默认系统字体),重复 key 里
                // plutil 只保留最后一条,结果语言选择器的英文被字体那条顶掉了。
                // 改成「系统字体」:key 各自独立,而且在「字体」选择器下这个说法本身就比
                // 「跟随系统」准确(后者容易被读成跟随深浅色外观)。
                Text(L10n.t("系统字体")).tag("")
                ForEach(Self.curatedFontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .pickerStyle(.menu)

            // LabeledContent 而不是裸 HStack——分组样式下 Toggle/Picker/ColorPicker
            // 这些自带标签的控件,标签会自动对齐成同一条竖线;裸 HStack 的"字号"只是
            // 行内第一个 Text,对不上那条对齐线。LabeledContent 让它享受同一套对齐。
            LabeledContent(L10n.t("字号")) {
                HStack(spacing: 8) {
                    Slider(value: $settings.fontSize, in: 14...36, step: 1)
                    Text(String(format: L10n.t("%@pt"), "\(Int(settings.fontSize))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
            }

            ColorPicker(
                L10n.t("文字颜色"),
                selection: Binding(
                    get: { settings.foregroundColor },
                    set: { settings.foregroundColorHex = $0.hexStringWithAlpha }
                ),
                supportsOpacity: false // 故意关掉——文字颜色允许透明的话,容易把 alpha
                                       // 拖到 0,悬浮窗整个消失且没有任何视觉提示能定位问题
            )

            ColorPicker(
                L10n.t("背景颜色"),
                selection: Binding(
                    get: { settings.backgroundColor },
                    set: { settings.backgroundColorHex = $0.hexStringWithAlpha }
                ),
                supportsOpacity: true // 背景不透明度就是这个颜色的 alpha 通道本身,
                                      // 不另加一根 opacity 滑杆
            )

            Toggle(L10n.t("文字描边（与桌面背景区分）"), isOn: $settings.textStrokeEnabled)

            if settings.textStrokeEnabled {
                ColorPicker(
                    L10n.t("描边颜色"),
                    selection: Binding(
                        get: { settings.textStrokeColor },
                        set: { settings.textStrokeColorHex = $0.hexStringWithAlpha }
                    ),
                    supportsOpacity: true // 描边只让选颜色(含 alpha),粗细是固定常量
                                          // (LyricsOverlayView.swift 的 OptionalTextStroke),
                                          // 不额外加调节项——参考的是 LyricsX 的做法。
                )
            }

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
        } header: {
            Text(L10n.t("桌面悬浮歌词"))
        } footer: {
            Text(L10n.t("以上配色、字体、字号只影响「桌面悬浮歌词」；灵动岛歌词和歌词窗口用的是固定的系统配色和字号，菜单栏歌词是纯文字，都不受这里影响"))
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

    // 灵动岛歌词专属。三项都只负责持久化,NotchLyricsView 每次渲染直接读,不需要像
    // classicOverlayEnabled/notchOverlayEnabled 那样在这里连带调某个窗口控制器"生效"
    // ——唯一的例外是"宽度",它改的是窗口本身的几何,见下面那一项。
    //
    // 标签从改动前的"灵动岛风格"简化成"风格":卡片标题已经是"灵动岛歌词"了,再重复一遍
    // "灵动岛"是冗余(同理"宽度"也不需要写成"灵动岛宽度",跟上面桌面悬浮歌词那张卡里的
    // "宽度"靠卡片归属区分,不会混淆)。
    private var notchOverlaySection: some View {
        Section {
            Picker(L10n.t("风格"), selection: $settings.notchCardStyle) {
                ForEach(NotchCardStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.menu)

            Toggle(isOn: $settings.notchShowArtwork) {
                HStack(spacing: 4) {
                    Text(L10n.t("显示专辑封面"))
                    HelpButton(text: L10n.t("在灵动岛右下角显示一枚专辑封面小图。开启后当前歌词能显示的宽度会略微变窄（过长的歌词仍然会横向滚动播完整句）"))
                }
            }

            // 跟上面桌面悬浮歌词的"宽度"滑块同一套写法(设置项本身只负责持久化,didSet
            // 不碰 NSWindow,这里的 set 闭包显式调用窗口控制器的方法让改动立刻生效)。
            // 跟桌面悬浮歌词不同的是灵动岛不需要"保持中心点"的增量调整——它的位置从来
            // 都是重新居中算出来的,见 NotchLyricsWindowController.applyContentWidthSetting()。
            LabeledContent(L10n.t("宽度")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { settings.notchContentWidth },
                        set: { newValue in
                            settings.notchContentWidth = newValue
                            NotchLyricsWindowController.shared.applyContentWidthSetting()
                        }
                    ), in: 260...500, step: 10)
                    Text(String(format: L10n.t("%@pt"), "\(Int(settings.notchContentWidth))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        } header: {
            Text(L10n.t("灵动岛歌词"))
        } footer: {
            Text(L10n.t("灵动岛的配色由上面的「风格」决定、字号固定，不使用「桌面悬浮歌词」那一组配色和字体设置"))
        }
    }

    // 菜单栏歌词专属。改动前那句随开关变化的说明是 Section 正文里一行 .font(.caption) 的
    // 裸 Text,现在挪到 footer——分组样式里 footer 才是"注脚"的原生位置,而且它是单个纯
    // Text,不触碰本文件那条"header/footer 只放纯 Text 字面量"的约束。
    private var menuBarSection: some View {
        Section {
            Toggle(isOn: $settings.menuBarLyricsScroll) {
                HStack(spacing: 4) {
                    Text(L10n.t("超宽时横向滚动"))
                    HelpButton(text: L10n.t("歌词比下面设置的宽度更长时，在状态栏里横向滚动播完整句（开头会先停一下再滚）；关掉则截断成「前 N 个字…」。两种模式下鼠标悬停在状态栏上都能看到完整的这一行"))
                }
            }
            LabeledContent(L10n.t(settings.menuBarLyricsScroll ? "显示宽度" : "超过就截断")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(settings.menuBarLyricsMaxChars) },
                        set: { settings.menuBarLyricsMaxChars = Int($0) }
                    ), in: 20...120, step: 5)
                    Text(String(format: L10n.t("%@ 字"), "\(settings.menuBarLyricsMaxChars)"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        } header: {
            Text(L10n.t("菜单栏歌词"))
        } footer: {
            Text(L10n.t(settings.menuBarLyricsScroll
                ? "状态栏里最多同时显示这么多字；更长的歌词会横向滚动播完"
                : "没超过就整行显示；超过这个长度会截断，鼠标悬停在状态栏上能看到完整这一行"))
        }
    }

    // 两个悬浮窗共用的两个隐藏开关。改动前它们跟桌面悬浮歌词专属的"宽度/锁定位置"挤在
    // 同一张叫"悬浮歌词窗口"的卡里,那个标题对这两项并不精确(它们对灵动岛同样生效)——
    // 改动前的注释已经指出过这个不精确,这次按归属拆开:专属的回各自的模式卡,共用的留在
    // 这张卡。标题用"自动隐藏"而不是"共用设置":它描述的是这两个开关实际在做的事,不管
    // 当下开着的是一个还是两个悬浮窗都成立。
    private var autoHideSection: some View {
        Section {
            Toggle(isOn: Binding(
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
            )) {
                HStack(spacing: 4) {
                    Text(L10n.t("截屏/录屏时隐藏"))
                    HelpButton(text: L10n.t("开启「截屏/录屏时隐藏」后，截图、录屏、视频会议共享屏幕都不会拍到悬浮歌词，但你自己在这台 Mac 上仍然正常看得见"))
                }
            }
            Toggle(L10n.t("暂停/无播放时隐藏"), isOn: Binding(
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
        } header: {
            Text(L10n.t("自动隐藏"))
        } footer: {
            Text(L10n.t("这两项对「桌面悬浮歌词」和「灵动岛歌词」同时生效；菜单栏歌词和歌词窗口不受影响"))
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
    // 一样,没有任何具体原因或下一步指引,用户卡在这里无计可施(对比下面"权限"Section
    // 失败时有文案+"打开系统设置"按钮)。只在"这次是想启用、结果没启动起来"时才为真,
    // 停用/切走这个 tab 都会清掉,不会把上一次失败的提示一直留着误导下一次操作。
    @State private var collectorEnableFailed = false

    var body: some View {
        Form {
            // 选哪个播放器决定了下面"权限"这个 Section 还要不要出现——QQ 音乐走系统级
            // MediaRemote,没有"自动化"这个概念,继续显示这个 Section 只会误导人以为
            // 还需要处理这个权限。切换后台采集服务(收集器只在启动时读一次这个设置)
            // 需要重启才生效,跟这个 store 其它开关一样"保存即重启"。
            Section {
                Picker(L10n.t("播放器"), selection: Binding(
                    get: { features.player },
                    set: { features.player = $0; Task { await features.save() } }
                )) {
                    ForEach(PlaybackPlayer.allCases) { player in
                        Text(player.displayName).tag(player)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.t("播放器"))
            } footer: {
                Text(L10n.t("选择 Lyrimuse 读取哪个 App 的播放状态"))
            }

            // 本地数据源现在通过 AppleScript 直接问 Music.app(见 MediaControlClient.swift),
            // 这个权限因此从"可选、只影响播放进度精度"变成"核心路径必需、没有就完全
            // 看不到歌词",footer 特意说清楚这一点,别让人以为不给也无所谓。QQ 音乐走
            // 系统级 MediaRemote,不需要这个权限,选中它时整个 Section 不出现。
            if features.player == .appleMusic {
            Section {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("Apple Music 自动化"))
                            Text(automationStatusCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: automationStatusIconName)
                            .foregroundStyle(automationStatusIconColor)
                    }
                    Spacer()
                    if isRequestingAutomation {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(automationActionTitle) { handleAutomationAction() }
                    }
                }
                if isRequestingAutomation {
                    if automationRequestTimedOut {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.t("这次请求耗时有点久。如果你已经看到系统弹窗，请去处理它；找不到弹窗的话，可以直接去系统设置里手动开启"))
                            Button(L10n.t("打开系统设置")) {
                                NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.t("请查看屏幕上弹出的系统授权对话框，选择「允许」"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.t("权限"))
            } footer: {
                Text(L10n.t("Lyrimuse 靠这个权限读取 Apple Music 当前播放的歌曲信息。没有它，悬浮歌词/灵动岛都无法显示任何歌词内容"))
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
                // 2026-08-02 补上——切到 QQ 音乐/网易云音乐/Spotify/自动识别后,"权限"
                // 整个 Section 直接消失,之前没有任何一句话确认"这是正常的、这个播放器
                // 不需要走这道授权",容易让用户怀疑是不是哪里坏了。这里补一句确认文案,
                // 不需要完整的 Section(没有状态/按钮可展示),用 Label 保持跟上面"权限"
                // Section 同样"图标+文字"的视觉语言。
                Section {
                    Label(
                        String(format: L10n.t("%@ 通过系统级机制读取播放状态，不需要在这里做额外授权"), features.player.displayName),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.t("权限"))
                }
            } // features.player == .appleMusic

            // collector(读播放状态、抓歌词/封面写本地缓存的后台服务)跟"权限"那个
            // Section 一样用图标+文案+按钮而不是简单 Toggle——需要展示"装了但没跑
            // 起来"这种中间态，纯 Toggle 表达不了。
            Section {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("后台采集服务"))
                            Text(collectorStatusCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: collectorStatusIconName)
                            .foregroundStyle(collectorStatusIconColor)
                    }
                    Spacer()
                    if isTogglingCollectorService {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(collectorActionTitle) { toggleCollectorService() }
                    }
                }
                // 启用失败时给具体指引,不是只把红叉留在原地——跟"权限"Section 失败时
                // 有文案+按钮同一个思路,这里能提供的具体行动是导出诊断信息(汇总 App/
                // 采集器日志),不是空泛地说"启用失败"。
                if collectorEnableFailed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("启用失败，可能是权限或系统限制导致后台服务没能正常启动，导出诊断信息能看到具体原因，也方便反馈问题"))
                        Button(L10n.t("导出诊断信息…")) { exportDiagnostics() }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.t("常驻服务"))
            } footer: {
                Text(L10n.t("负责读取播放状态、解析歌词/封面并写入本地缓存的后台程序。没有它，悬浮歌词/灵动岛同样无法显示任何内容"))
            }
            .onAppear { collectorRunning = CollectorServiceManager.isRunning }

            // 两个 Toggle 的文案跟着 features.player 走(Apple Music/QQ 音乐/...)——这两个
            // 联动本身已经改成跟着选定的播放器走(见 AppDelegate.swift/companionlaunch.go),
            // 文案继续写死"Apple Music"会跟实际行为对不上,选了 QQ 音乐却看着字面在说
            // Apple Music。选了"自动识别"(.auto)时这两个方向不对称:
            // "打开 Lyrimuse 时启动 X"没有唯一确定的 X,直接隐藏这个开关(而不是显示一句
            // "打开自动识别时启动 Lyrimuse"这种读不通的文案);"打开 X 时启动 Lyrimuse"
            // 反而在自动识别模式下更有用——companionlaunch.go 这时会同时盯着全部四个
            // 已知播放器的进程,任意一个启动都算数,文案换成不点名具体某个 App 的说法。
            Section {
                if features.player != .auto {
                    Toggle(String(format: L10n.t("打开 Lyrimuse 时启动 %@"), features.player.displayName), isOn: $settings.launchMusicOnLyrimuseOpen)
                }
                Toggle(isOn: Binding(
                    get: { features.launchLyrimuseOnMusicOpen },
                    set: { features.launchLyrimuseOnMusicOpen = $0; Task { await features.save() } }
                )) {
                    Text(features.player == .auto
                        ? L10n.t("打开任意已知播放器时启动 Lyrimuse")
                        : String(format: L10n.t("打开 %@ 时启动 Lyrimuse"), features.player.displayName))
                }
            } header: {
                Text(L10n.t("App 联动"))
            } footer: {
                Text(features.player == .auto
                    ? L10n.t("「打开任意已知播放器时启动 Lyrimuse」由后台采集服务负责监测，需要先在上面启用「后台采集服务」才会生效")
                    : String(format: L10n.t("「打开 %@ 时启动 Lyrimuse」由后台采集服务负责监测，需要先在上面启用「后台采集服务」才会生效"), features.player.displayName))
            }
        }
        .formStyle(.grouped)
        // SwiftUI 有时不会在语言切换后重新执行某些嵌套内容的 body(取决于该内容自己的
        // 存储属性有没有变,而非父视图是否重新渲染,详见 AccountLinkingTab.swift 里
        // DestinationStatus.label 的注释)。用 .id(L10n.current) 把 Form 的身份跟当前
        // 语言绑死,语言一变就强制整体重新构造,不需要逐个排查哪里在跳过刷新。
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
        Form {
            Section(L10n.t("语言")) {
                // 下拉菜单而不是分段控件——分段控件的宽度会随选项数线性变宽,以后再加
                // 语言(繁体中文/日语等)容易挤爆这一行;下拉菜单不管加多少个选项,这一行
                // 的宽度都不变。
                Picker(L10n.t("语言"), selection: $settings.appLanguage) {
                    Text(L10n.t("跟随系统")).tag("system")
                    Text(L10n.t("简体中文")).tag("zh-hans")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
            }
            Section(L10n.t("启动")) {
                Toggle(L10n.t("开机启动"), isOn: $settings.launchAtLoginEnabled)
                Toggle(L10n.t("在 Dock 中显示"), isOn: $settings.showInDock)
            }

            // 导入/导出打包 collector 的 config.json(账号 token 原文都在里面)+
            // features.json + App 自己的偏好设置,合并成一份 JSON。刻意跟"导出诊断
            // 信息"反着来:那个绝不能带任何 token(设计给贴进公开 issue),这个就是要把
            // token 原样带走(设计给换新机器用)——两处的用户提示因此也刻意写成相反的
            // 语气。
            Section {
                Button(L10n.t("导出配置…")) { showExportConfigWarning = true }
                Button(L10n.t("导入配置…")) {
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
                // "清除所有配置"跟上面两个反着来:不是搬一份配置走/换一份进来,是
                // 直接清空回到刚装完的样子。role: .destructive 让它天生就是红色文字,
                // 不用另外套样式表明这是危险操作。
                Button(L10n.t("清除所有配置…"), role: .destructive) { showClearConfigWarning = true }
            } header: {
                Text(L10n.t("配置备份"))
            } footer: {
                Text(L10n.t("导出的文件包含账号 token、密钥等敏感信息，注意妥善保管，不要分享给他人。导入会覆盖当前所有设置并重启 App。清除会抹掉所有账号和个人设置，恢复到刚装完时的样子"))
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
                Text(L10n.t("这会清除所有账号 token、密钥和个人设置，恢复到刚装完时的样子（下次启动会重新走一遍引导向导），且无法撤销。如果还没备份过，建议先点上面「导出配置…」"))
            }
        }
        .formStyle(.grouped)
        // SwiftUI 有时不会在语言切换后重新执行某些嵌套内容的 body(取决于该内容自己的
        // 存储属性有没有变,而非父视图是否重新渲染,详见 AccountLinkingTab.swift 里
        // DestinationStatus.label 的注释)。用 .id(L10n.current) 把 Form 的身份跟当前
        // 语言绑死,语言一变就强制整体重新构造,不需要逐个排查哪里在跳过刷新。
    }
}

// "快捷键"分类——原来跟"通用"tab 挤在一起,内容量(6 个悬浮歌词相关快捷键+1 个步长
// 调节+3 个播放控制快捷键)比"通用"其它几块加起来还多,拆成独立分类。
private struct ShortcutsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ShortcutRecorder(L10n.t("显示/隐藏悬浮歌词"), name: .toggleOverlay)
                ShortcutRecorder(L10n.t("锁定/解锁位置"), name: .toggleLockPosition)
                ShortcutRecorder(L10n.t("打开歌词管理"), name: .openLyricsManagerHotkey)
                ShortcutRecorder(L10n.t("打开歌词窗口"), name: .openLyricsWindowHotkey)
                ShortcutRecorder(L10n.t("打开设置"), name: .openSettingsHotkey)
                ShortcutRecorder(L10n.t("歌词提前"), name: .lyricsAdvanceHotkey)
                ShortcutRecorder(L10n.t("歌词延后"), name: .lyricsDelayHotkey)
                // 每次调整的步长——跟菜单栏"歌词时间轴"共用同一个值,这里改了菜单里的
                // 按钮文案/快捷键的实际调整量会一起变。0.05~2s 区间对"手动校准"这个场景
                // 够用,不需要再大或者再细。
                Stepper(value: Binding(
                    get: { Double(settings.lyricsOffsetStepMs) / 1000 },
                    set: { settings.lyricsOffsetStepMs = Int(($0 * 1000).rounded()) }
                ), in: 0.05...2.0, step: 0.05) {
                    Text("\(L10n.t("歌词时间轴步长"))：\(AppSettings.formattedSeconds(ms: settings.lyricsOffsetStepMs))\(L10n.t("秒"))")
                }
            } header: {
                Text(L10n.t("快捷键"))
            } footer: {
                // 录制时单独按字母/数字/符号键会被拒绝(响一声提示音,没有任何文字提示)
                // ——这条规则照抄 KeyboardShortcuts 库自带 Recorder 的原有行为(见
                // ShortcutRecorder.swift 里 handle(_:) 的注释),不是这次改动新引入的
                // 限制,但一直没有地方说明,2026-07-30 用户实测顺着"只有组合键才成功"
                // 这个疑问反馈过来,补一句说明。
                Text(L10n.t("至少需要搭配 ⌘/⌥/⌃ 中一个（功能键、媒体键除外）"))
            }

            Section(L10n.t("播放控制（附加功能）")) {
                ShortcutRecorder(L10n.t("播放/暂停"), name: .playPauseHotkey)
                ShortcutRecorder(L10n.t("下一首"), name: .nextTrackHotkey)
                ShortcutRecorder(L10n.t("上一首"), name: .previousTrackHotkey)
            }
        }
        .formStyle(.grouped)
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
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("Lyrimuse")
                        .font(.title2.weight(.semibold))
                    Text(String(format: L10n.t("版本 %@"), versionString))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L10n.t("跟着 Apple Music、QQ 音乐、网易云或 Spotify 播放，实时显示逐字同步歌词，还能一键同步播放记录到 Last.fm"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // Sparkle 自己处理"检查中/已是最新/发现新版本"这几种状态的 UI
                    // 展示(SPUStandardUserDriver 的标准弹窗),不需要自己维护 loading
                    // 状态或者判断结果再手动弹 alert。
                    Button(L10n.t("检查更新…")) {
                        SparkleUpdaterManager.shared.checkForUpdates()
                    }
                    .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section(L10n.t("链接")) {
                Button(L10n.t("GitHub 仓库")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse")!)
                }
                .buttonStyle(.link)
                Button(L10n.t("反馈问题")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse/issues")!)
                }
                .buttonStyle(.link)
            }

            // 落地页(微信/支付宝收款码)是独立的通用小仓库 Yudaotor/donate,托管在
            // GitHub Pages 上,不跟 Lyrimuse 这一个项目绑定,后续其它项目也能复用——
            // 这里只是一个外链按钮。
            Section {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://yudaotor.github.io/donate/")!)
                } label: {
                    Label(L10n.t("请作者喝杯咖啡"), systemImage: "cup.and.saucer.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            // collector 日志一直写得比较完整,但 App 自己的日志全在系统统一日志里,
            // 普通人不会用 Console.app 去查。这里一键把两边日志+关键状态(权限/常驻
            // 服务/各功能是否已配置,不含任何 token 原始值)汇总成一份文本存到桌面,
            // 方便贴进 issue 或者发给开发者。
            Section {
                Button(L10n.t("导出诊断信息…")) {
                    let report = DiagnosticsExporter.buildReport()
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = DiagnosticsExporter.suggestedFilename()
                    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                    if panel.runModal() == .OK, let url = panel.url {
                        try? report.write(to: url, atomically: true, encoding: .utf8)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } footer: {
                Text(L10n.t("汇总 App/采集器日志和权限、常驻服务等关键状态，保存成一份文本文件，不会包含任何账号 token 或密钥的原始内容"))
            }

            Section {
                Text("© 2026 Yudaotor")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        // SwiftUI 有时不会在语言切换后重新执行某些嵌套内容的 body(取决于该内容自己的
        // 存储属性有没有变,而非父视图是否重新渲染,详见 AccountLinkingTab.swift 里
        // DestinationStatus.label 的注释)。用 .id(L10n.current) 把 Form 的身份跟当前
        // 语言绑死,语言一变就强制整体重新构造,不需要逐个排查哪里在跳过刷新。
    }
}
