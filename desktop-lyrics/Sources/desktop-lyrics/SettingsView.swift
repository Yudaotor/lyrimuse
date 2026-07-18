import SwiftUI
import AppKit
import DesktopLyricsCore
import KeyboardShortcuts

// 整个设置窗口是一层真正的 NavigationSplitView:左边一份侧边栏 List,右边显示当前
// 选中项的详情。"账号连接"不是侧边栏里单独一个可选中的大分类,而是拆成 Section("账号
// 连接")下的 4 个账号条目(ListenBrainz/Last.fm/网页推送/推送提醒),跟
// 播放/歌词/外观/功能开关/通用平级放进同一个 List 里——这是踩了两次真实的 SwiftUI/
// AppKit 坑之后收敛出来的结构:最早"账号连接"内部自己套了一层 NavigationSplitView
// (分类侧边栏之下又嵌一层账号侧边栏),两层 NavigationSplitView 叠在同一个窗口里,
// macOS 在侧边栏/工具栏这层窗口级 chrome 上打架,外层侧边栏直接不渲染;改成手搭的
// HStack+List(.listStyle(.sidebar)) 规避了那个冲突,但这种"看起来像侧边栏、实际不是
// NavigationSplitView 真正分栏列"的 List,又拿不到 AppKit 只对"真正的侧边栏列"做的
// 窗口圆角遮罩,导致窗口左下角露出一块黑色阴影(实测截图坐实,是用户报的"有bug阴影")。
// 两次踩坑指向同一个结论:伪造第二层"看起来像侧边栏"的容器,不管哪种实现方式,都会
// 跟只按"一个真正侧边栏列"设计的窗口级 chrome/遮罩打架。唯一稳妥的解法是彻底拍平,
// 全窗口只留一层真正的侧边栏,"账号"这一级也变成这层真侧边栏里的普通行。
//
// 2026-07-16:新增"歌词"分类——用户反馈"应该单独设置出一个歌词模块把相关的功能放
// 进去"。歌词相关的设置原来分散在三个不同 tab 里(播放 tab 的"歌词展示"、功能开关
// tab 的"歌词解析"/"歌词文件夹作为权威源"、通用 tab 的"打开歌词文件夹"),要改个歌词
// 相关的东西得先想好去哪个 tab 找。现在收进一个 LyricsSettingsTab,还顺带加了个
// "打开歌词管理…"按钮(原来只能从菜单栏进,Settings 里完全没有入口)。留在原地没搬的:
// "封面/主色/平台跳转链接"——这是纯封面/取色/跳转链接的事,跟歌词完全无关;字体/颜色/
// 阴影这些视觉样式留在"外观"tab,那边管的是整个悬浮窗的视觉呈现,不只是歌词文字本身。
// "换歌时预取同专辑其它曲目"最早也留在了功能开关 tab(当时的理由是"同时预取封面,不是
// 歌词专属"),后来用户反馈"这个功能开关我理解是放在歌词tab里面合适一点"、又改了主意——
// 搬进了"歌词"分类且改名"提前解析同专辑其它曲目（封面+歌词）",详见 LyricsSettingsTab
// 里的改动说明。
//
// 2026-07-17:"功能开关"分类(原来的 FeatureTogglesTab)整个删掉了——搬完上面几轮之后
// 它只剩"封面/主色/平台跳转链接"一个开关,用户反馈"这个不需要设置吧,默认就是支持的,
// 也不需要可以设置为关闭",于是这个开关本身也从 collector/desktop-lyrics 两侧一起
// 删除,封面/主色/跳转链接变成无条件执行的行为,不再是可关闭的设置项。tab 因此被搬空、
// 直接删掉这个分类,不留一个空壳——跟当初"播放"tab 空了就整个删除是同一个处理方式。
//
// 随后"播放"tab 剩下的"数据源"(远程/本地+Relay 地址)也搬进了"歌词"tab、改名"播放
// 状态来源"——用户反馈"播放tab的那个也改到歌词tab吧"。"播放"tab因此被搬空,直接
// 删掉这个分类,不留一个空壳。
//
// 每个分类各自还是独立的 View,直接访问对应的单例(AppSettings.shared/
// FeatureSettingsStore.shared/ConfigStore.shared 等),不需要从 SettingsView 往下传
// 参数——唯一的例外是"功能开关"分类里某个开关因为对应账号没连好被禁用时,旁边会有个
// "前往「账号连接」"的跳转按钮,直接跳到侧边栏里对应的那一个账号行(而不是笼统跳到
// "账号连接"这个不再存在的单一分类),这就需要 SettingsView 把跳转能力下传给它。
enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case lyrics, appearance, general

    var id: Self { self }

    var title: String {
        switch self {
        case .lyrics: return L10n.t("歌词")
        case .appearance: return L10n.t("外观")
        case .general: return L10n.t("通用")
        }
    }

    var icon: String {
        switch self {
        case .lyrics: return "text.quote"
        case .appearance: return "paintbrush"
        case .general: return "gearshape"
        }
    }

    // 2026-07-17:侧边栏视觉重设计——这几个纯设置分类原来是系统默认 Label(纯图标+
    // 文字,无背景),"账号连接"那四个账号行却是自定义彩色圆角方块图标,同一个 List 里
    // 两种风格混着很不统一。这里给这几个也配一个 tint,跟 sidebarLabel(_:) 一起改成
    // 跟账号行同款的彩色徽标——特意避开已经在用的四个账号色(orange/pink/blue/red)和
    // 歌词来源色点(red/green/cyan/purple,见 LyricsManagerView.swift 的 sourceColor):
    // "外观"尤其不用青色系,因为默认打开的就是"歌词"分类,LRCLIB 色点(cyan)跟侧边栏里
    // "外观"图标会同屏出现,选太近的色系容易混淆。"通用"用灰色齿轮,呼应 macOS 系统
    // 设置里"通用"本来就是灰色齿轮的既有印象。
    var tint: Color {
        switch self {
        case .lyrics: return .indigo
        case .appearance: return .yellow
        case .general: return .gray
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

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                sidebarLabel(.lyrics)
                sidebarLabel(.appearance)
                sidebarLabel(.general)

                Section(L10n.t("账号连接")) {
                    ForEach(AccountDestination.allCases) { destination in
                        AccountSidebarRow(destination: destination)
                            .tag(SettingsSidebarItem.account(destination))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            Group {
                switch selection {
                case .tab(.lyrics): LyricsSettingsTab()
                case .tab(.appearance): AppearanceSettingsTab()
                case .tab(.general): GeneralSettingsTab()
                case .account(let destination):
                    AccountLinkingTab(destination: destination, onJumpToAccount: { selection = .account($0) })
                case nil: ContentUnavailableView(L10n.t("选择左侧的设置分类"), systemImage: "gearshape")
                }
            }
            .navigationTitle(navigationTitle)
        }
        // 原来是给 TabView 焊死的 440pt 改出来的 minWidth/idealWidth——现在换成
        // NavigationSplitView,多了一列侧边栏,整体相应加宽;同样不设 maxWidth/固定
        // 高度,各分类继续按内容自动撑高。
        .frame(minWidth: 760, idealWidth: 860, minHeight: 460)
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

// 歌词相关设置的统一入口——见上面 SettingsTab 枚举旁的改动说明。原"播放"tab 的
// "数据源"(远程/本地+Relay 地址)也搬到这里、改名"播放状态来源"，所以这个 View
// 也持有 PlaybackSettingsTab 原来那几个单例(settings/poller/local)。
private struct LyricsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    // poller/local 在这个页面里只当"写目标"用(切换开关时顺手同步给它们),这个 View
    // 的 body 从来不读它们的 @Published 数据渲染任何东西——声明成 @ObservedObject
    // 会让这个页面在本地播放每次轮询(~2秒一次)更新歌曲信息时跟着白白重渲染一次。
    // 用普通引用(class 本身是引用类型,let 一样能改它们的属性),不订阅。
    private let poller = RelayPoller.shared
    private let local = LocalPlaybackSource.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showAutomationDeniedAlert = false

    var body: some View {
        Form {
            Section(L10n.t("播放状态来源")) {
                Picker(selection: Binding(
                    get: { settings.dataSourceMode },
                    set: { newValue in
                        settings.dataSourceMode = newValue
                        PlaybackCoordinator.shared.applyMode(newValue)
                    }
                )) {
                    Text(L10n.t("远程(网页同源)")).tag(PlaybackSourceMode.relay)
                    Text(L10n.t("本地播放(这台 Mac)")).tag(PlaybackSourceMode.local)
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.t("来源"))
                        HelpButton(text: L10n.t("远程(网页同源)：跟网页版读同一份数据，来自你自己部署的状态中继服务，适合想跟网页显示保持完全一致的场景。本地播放(这台 Mac)：直接读这台 Mac 上系统正在播放的内容，不经过网络，更实时。"))
                    }
                }
                .pickerStyle(.segmented)

                if settings.dataSourceMode == .relay {
                    TextField(L10n.t("Relay 地址"), text: Binding(
                        get: { settings.relayBaseURL },
                        set: { newValue in
                            settings.relayBaseURL = newValue
                            poller.updateBaseURL(newValue)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                } else if settings.dataSourceMode == .local {
                    Toggle(L10n.t("精确追踪 Apple Music 播放进度"), isOn: Binding(
                        get: { settings.preciseAppleMusicPosition },
                        set: setPrecisePosition
                    ))
                    Text(L10n.t("需要系统「自动化」权限允许控制 Music.app；没有这个权限也能正常使用，播放进度会改用估算值，可能有 1-2 秒误差。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .alert(
                L10n.t("还没有自动化权限"),
                isPresented: $showAutomationDeniedAlert
            ) {
                Button(L10n.t("打开系统设置")) { NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL) }
                Button(L10n.t("取消"), role: .cancel) {}
            } message: {
                Text(L10n.t("请先在系统设置的「自动化」里允许 desktop-lyrics 控制 Music.app，再回来打开这个开关。"))
            }

            Section(L10n.t("解析")) {
                Toggle(isOn: Binding(
                    get: { features.lyrics },
                    set: { features.lyrics = $0; Task { await features.save() } }
                )) {
                    HStack(spacing: 4) {
                        Text(L10n.t("歌词在线匹配"))
                        HelpButton(text: L10n.t("控制要不要在线解析歌词——关闭后，第一次播放的新歌不会再去查下面「歌词来源」里的这些平台，只用本地已经缓存过的结果（如果有）。「歌词来源」「匹配算法」这两组设置都只在这个开关开启时才有意义。"))
                    }
                }
                // 2026-07-16:改名自"换歌时预取同专辑其它曲目"——原文案没提到它其实也会
                // 预取封面,光看字面容易让人以为只跟歌词有关;"预取"改"解析"是为了跟上面
                // "歌词在线匹配"的措辞统一,也避免被误读成"预先加载音频本身"(这个开关
                // 从来不碰音频,只提前解析封面/歌词这类元数据)。同时从"功能开关"tab 搬
                // 过来——用户反馈"这个功能开关我理解是放在歌词tab里面合适一点"。
                Toggle(isOn: Binding(
                    get: { features.albumPrefetch },
                    set: { features.albumPrefetch = $0; Task { await features.save() } }
                )) {
                    HStack(spacing: 4) {
                        Text(L10n.t("提前解析同专辑其它曲目（封面+歌词）"))
                        HelpButton(text: L10n.t("换到一首歌时，如果它属于某张专辑，会顺带在后台把同专辑里还没解析过的其它曲目也提前解析——封面无条件都会解析，歌词是否被预取取决于上面的「歌词在线匹配」开关是否开启。"))
                    }
                }
            }

            // 2026-07-16:用户反馈"应该做到配置化，可以选择使用哪些源，然后还可以选择
            // 智能算法，或者是自己排一个选择顺序"——原来"歌词解析"的四个源(网易云/QQ/
            // 酷狗/LRCLIB)是硬编码全查+固定打分,现在拆成两件事:"歌词来源"决定查哪些
            // (至少留一个,不然歌词解析开着却什么都不用毫无意义);"匹配算法"决定从查到
            // 的结果里怎么选——智能算法沿用原有的四源打分取最高分,顺序优先则改成完全
            // 听用户排的顺序、不比分数。实现在 collector/enrich.go 的 pickLyricCandidate,
            // 故意不影响"歌词管理"窗口的手动搜索(那边永远查全部四源,理由见它的注释)。
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
                Text(L10n.t("至少需要保留一个歌词来源。"))
            }

            // 实测坐实:Section 的 header/footer 只要塞进去的不是纯 Text(哪怕只是
            // Text+HelpButton 这种最简单的 HStack),整个内容(连纯文字部分)都不出现在
            // 可访问性树里,不是"footer 里的 Button 点不到"那种局部问题——跟这个项目
            // 之前在 accountHintRow 上踩过的那个坑(footer 里嵌 Button 拿不到)是同一类
            // 限制,只是这次连 header、连纯 Text 都受影响。说明/操作一律放回 Section
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
                    Text(L10n.t("智能算法自动打分选最高分，顺序优先按你排的顺序来。"))
                        .font(.caption2).foregroundStyle(.secondary)
                    HelpButton(text: L10n.t("智能算法：查到的每个来源都打分（逐字时间轴、语言是否匹配等维度），自动挑分数最高的一条。顺序优先：按下面排的顺序，用第一个查到有效结果的来源，不比较分数。"))
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

            Section("展示") {
                Toggle(L10n.t("优先逐字高亮(有的话)"), isOn: Binding(
                    get: { settings.preferWordLevelKaraoke },
                    set: { newValue in
                        settings.preferWordLevelKaraoke = newValue
                        poller.preferWordLevelKaraoke = newValue
                        local.preferWordLevelKaraoke = newValue
                    }
                ))
                Toggle(L10n.t("显示罗马音"), isOn: $settings.showRomanization)
                Toggle(L10n.t("显示译文"), isOn: $settings.showTranslation)
                Toggle(L10n.t("双行显示(预览下一句歌词)"), isOn: $settings.showNextLinePreview)
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
                        HelpButton(text: L10n.t("歌词默认就以这个文件夹为准维护——联网匹配到的结果会导出成文件存在这里，「歌词管理」里手动导入/编辑的文件也在这里。换成新文件夹后，旧文件夹里已有的文件不会自动搬过去，需要自己手动移动。"))
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
                Text(L10n.t("每首歌听过一次,歌词就会永久保存在这个文件夹里;在「歌词管理」里删除会同时删掉这里已导出的文件。"))
            }
        }
        .formStyle(.grouped)
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

    // 打开时才校验权限、没通过就弹窗提示——跟 AccountLinkingTab 里账号前置条件校验
    // 同一种"点了才校验"的语言,不做静态常驻的 disabled/hint。关闭这个开关不需要任何
    // 权限,始终允许。
    private func setPrecisePosition(_ enabled: Bool) {
        guard enabled else {
            settings.preciseAppleMusicPosition = false
            local.preciseAppleMusicPosition = false
            return
        }
        guard MusicAutomationPermission.check(askIfNeeded: true).isAuthorized else {
            showAutomationDeniedAlert = true
            return
        }
        settings.preciseAppleMusicPosition = true
        local.preciseAppleMusicPosition = true
    }
}

private struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    // 精选常用字体,而不是列出这台机器上全部两百多个已安装字体族(选不过来是用户
    // 2026-07-14 的原话反馈)。清单来源是真实调研,不是凭印象挑的:
    // - 拉丁文/通用部分:Helvetica(被反复称为"现代排版标杆")、Arial(Windows/Office
    //   数十年的默认字体,公认全球装机量/曝光量最高、因而"用得最多"的英文字体)、
    //   Times New Roman(最常被提及/最易识别的衬线字体)、Futura(多份 2025 年度
    //   常用字体盘点里反复出现的经典几何无衬线设计)。
    // - 中文部分:调研结论是"黑体使用最多、宋体次多、楷体因屏幕显示效果差目前用得
    //   最少"——只保留前两名(Heiti SC/Songti SC),刻意不收楷体。另外加了 PingFang SC:
    //   它是 macOS/iOS 自 El Capitan 起所有设备的实际默认中文字体,是这台机器上体感
    //   "用得最多"的中文字体,即使它不在"黑体/宋体/楷体"这个传统三分类调研范围内。
    // 仍然过一遍 NSFontManager 实际安装列表做交叉核对而不是硬编码假设——理论上不会有
    // 哪一个缺失(这几个都是 macOS 系统自带字体),但跟项目里"字体设置要显式检查装没装、
    // 不能隐式假设"这个既有惯例(见 AppearanceHelpers.swift)保持一致。
    private static let curatedFontFamilies: [String] = {
        let candidates = [
            "Helvetica Neue", "Arial", "Times New Roman", "Futura",
            "PingFang SC", "Heiti SC", "Songti SC",
        ]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return candidates.filter { installed.contains($0) }
    }()

    var body: some View {
        // .formStyle(.grouped) 是 macOS 13+ 原生"系统设置"式外观(圆角分组卡片+
        // 灰色小标题+尾注),换掉原来 Form 默认的纯列表样式——原来的问题:每个 Section
        // 的标题只是一行普通粗体文字、跟内容之间没有视觉分组;ColorPicker/字体 Picker
        // 在默认样式下会被拉伸成贯穿整行的长条,不像系统里那种紧凑的小色块/下拉按钮;
        // 说明性文字(截屏隐藏/歌词存储那两句)夹在控件中间当成普通一行,读起来像是漏了
        // 什么而不是备注。分组样式换来的排版全部是 SwiftUI 原生处理,不用手工调间距。
        Form {
            Section(L10n.t("悬浮窗")) {
                // 桌面悬浮歌词(经典悬浮窗)、灵动岛歌词是两个完全独立的展示位置,各自
                // 独立开关,不互斥——可以同时开、只开一个、或都不开。最初做成互斥的单选
                // "悬浮窗样式",用户反馈这两个应该分开,改成这样。每个开关只负责"生效"
                // 这一个控制器自己的 setVisible,不碰另一个;首次打开某个样式时顺手把
                // "截屏/录屏时隐藏"“暂停/无播放时隐藏"这两个已经配置好的偏好也应用上去——
                // 否则那个控制器还停留在 init() 里的硬编码默认值,要等下次重启 App 走
                // AppDelegate 那条初始化路径才会生效,期间会悄悄违背用户已经勾选的偏好。
                Toggle(L10n.t("桌面悬浮歌词"), isOn: Binding(
                    get: { settings.classicOverlayEnabled },
                    set: { newValue in
                        settings.classicOverlayEnabled = newValue
                        LyricsOverlayWindowController.shared.setVisible(newValue)
                        if newValue {
                            LyricsOverlayWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
                            LyricsOverlayWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
                        }
                    }
                ))
                Toggle(L10n.t("灵动岛歌词"), isOn: Binding(
                    get: { settings.notchOverlayEnabled },
                    set: { newValue in
                        settings.notchOverlayEnabled = newValue
                        NotchLyricsWindowController.shared.setVisible(newValue)
                        if newValue {
                            NotchLyricsWindowController.shared.setHiddenFromCapture(settings.hideDuringScreenCapture)
                            NotchLyricsWindowController.shared.setHideWhenNotPlaying(settings.hideWhenNotPlaying)
                        }
                    }
                ))
                // 从"歌词"tab 的"展示"分组搬过来——用户反馈"状态栏歌词也是个歌词展示
                // 位置,应该跟桌面悬浮歌词/灵动岛歌词放一起",三个开关概念上都是"歌词
                // 显示在哪"，不是三件互不相关的事。
                Toggle(L10n.t("在状态栏显示当前歌词"), isOn: $settings.showLyricsInMenuBar)
                if settings.showLyricsInMenuBar {
                    LabeledContent(L10n.t("超过就截断")) {
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
                    Text(L10n.t("没超过就整行显示；超过这个长度会截断，鼠标悬停在状态栏上能看到完整这一行。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L10n.t("外观")) {
                Picker(L10n.t("字体"), selection: $settings.fontFamilyName) {
                    Text(L10n.t("跟随系统")).tag("")
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

                Toggle(L10n.t("文字阴影(与桌面背景区分)"), isOn: $settings.textShadowEnabled)

                if settings.textShadowEnabled {
                    ColorPicker(
                        L10n.t("阴影颜色"),
                        selection: Binding(
                            get: { settings.textShadowColor },
                            set: { settings.textShadowColorHex = $0.hexStringWithAlpha }
                        ),
                        supportsOpacity: true // 参考 LyricsX:阴影只让选颜色(含 alpha),
                                              // 模糊半径/偏移是固定常量,不额外加调节项
                    )
                }

                Button(L10n.t("恢复默认外观")) {
                    settings.fontFamilyName = ""
                    settings.fontSize = 20
                    settings.foregroundColorHex = "#FFFFFFFF"
                    settings.backgroundColorHex = "#00000000"
                    settings.textShadowEnabled = true
                    settings.textShadowColorHex = "#000000A6"
                }
                .buttonStyle(.link)
            }

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
                Toggle(L10n.t("锁定位置(不可拖拽+点击穿透)"), isOn: Binding(
                    get: { settings.lockPosition },
                    set: { newValue in
                        settings.lockPosition = newValue
                        LyricsOverlayWindowController.shared.setLocked(newValue)
                    }
                ))
                Toggle(L10n.t("截屏/录屏时隐藏"), isOn: Binding(
                    get: { settings.hideDuringScreenCapture },
                    set: { newValue in
                        settings.hideDuringScreenCapture = newValue
                        // 两个悬浮窗现在互不排斥,可能同时开着——应用到当前每一个确实
                        // 启用了的控制器,关闭的那个不碰(避免凭空构造出一个没人要的
                        // 窗口,见 NotchLyricsWindowController 顶部注释的那条不变量)。
                        if settings.classicOverlayEnabled {
                            LyricsOverlayWindowController.shared.setHiddenFromCapture(newValue)
                        }
                        if settings.notchOverlayEnabled {
                            NotchLyricsWindowController.shared.setHiddenFromCapture(newValue)
                        }
                    }
                ))
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
                Text(L10n.t("窗口"))
            } footer: {
                // footer 挂在整个 Section 上(而不是紧跟某个 Toggle 下面的裸 Text)——
                // 分组样式里这是原生"注脚"位置,明确点名是哪个开关的说明,避免视觉上跟
                // "锁定位置"混在一起。
                Text(L10n.t("开启「截屏/录屏时隐藏」后,截图、录屏、视频会议共享屏幕都不会拍到悬浮歌词——但你自己在这台 Mac 上仍然正常看得见。"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    // 只在 .onAppear 和每次操作后重新查一次(askIfNeeded: false,不会弹窗,纯读状态)——
    // 不是 @Published,系统层面的权限变化(比如用户自己去系统设置里手动改)不会主动
    // 推送通知回来,只能在这个页面被看到的时候被动刷新一次。
    @State private var automationStatus: MusicAutomationPermissionStatus = .notDetermined

    var body: some View {
        Form {
            Section(L10n.t("权限")) {
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
                    Button(automationActionTitle) { handleAutomationAction() }
                }
                Text(L10n.t("采集器（collector）在「专辑预取」等功能里会单独用到自己的一份自动化权限，是完全独立的系统授权，跟上面这一项是两次不同的系统弹窗；如果专辑预取没有生效，可以去系统设置里检查一下。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { automationStatus = MusicAutomationPermission.check(askIfNeeded: false) }

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
            }
            Section(L10n.t("快捷键")) {
                KeyboardShortcuts.Recorder(L10n.t("显示/隐藏悬浮歌词"), name: .toggleOverlay)
                KeyboardShortcuts.Recorder(L10n.t("锁定/解锁位置"), name: .toggleLockPosition)
                KeyboardShortcuts.Recorder(L10n.t("打开歌词管理"), name: .openLyricsManagerHotkey)
                KeyboardShortcuts.Recorder(L10n.t("打开设置"), name: .openSettingsHotkey)
                KeyboardShortcuts.Recorder(L10n.t("播放/暂停"), name: .playPauseHotkey)
                KeyboardShortcuts.Recorder(L10n.t("下一首"), name: .nextTrackHotkey)
                KeyboardShortcuts.Recorder(L10n.t("上一首"), name: .previousTrackHotkey)
            }
        }
        .formStyle(.grouped)
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
            automationStatus = MusicAutomationPermission.check(askIfNeeded: true)
        } else {
            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
        }
    }
}
