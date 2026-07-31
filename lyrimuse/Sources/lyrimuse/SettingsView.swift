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
        // 见 AppActions.pendingSettingsSelection 注释——Onboarding 的 Last.fm 步骤
        // 借这个信箱指定"这次打开设置窗口要直接停在哪个分类",这里读一次就清空,不影响
        // 之后用户正常打开设置窗口(默认还是回到 .tab(.lyrics))。
        .onAppear {
            if let pending = AppActions.shared.pendingSettingsSelection {
                selection = pending
                AppActions.shared.pendingSettingsSelection = nil
            }
        }
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
                        HelpButton(text: L10n.t("控制要不要在线解析歌词——关闭后，第一次播放的新歌不会再去查下面「歌词来源」里的这些平台，只用本地已经缓存过的结果（如果有）。「歌词来源」「匹配算法」这两组设置都只在这个开关开启时才有意义"))
                    }
                }
                // "解析"(而非"预取")避免被误读成预先加载音频本身,这个开关从不碰音频。
                Toggle(isOn: Binding(
                    get: { features.albumPrefetch },
                    set: { features.albumPrefetch = $0; Task { await features.save() } }
                )) {
                    HStack(spacing: 4) {
                        Text(L10n.t("提前解析同专辑其它曲目"))
                        HelpButton(text: L10n.t("换到一首歌时，如果它属于某张专辑，会顺带在后台把同专辑里还没解析过的其它曲目也提前解析——封面无条件都会解析，歌词是否被预取取决于上面的「歌词在线匹配」开关是否开启"))
                    }
                }
            }

            // 拆成两件事:"歌词来源"决定查哪些源(至少留一个,不然歌词解析开着却什么都
            // 不查毫无意义);"匹配算法"决定从查到的结果里怎么选——智能算法沿用五源
            // 打分取最高分,顺序优先则完全听用户排的顺序、不比分数。实现在
            // collector/enrich.go 的 pickLyricCandidate,故意不影响"歌词管理"窗口的
            // 手动搜索(那边永远查全部五源,理由见它的注释)。
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
                Text(L10n.t("仅对 Musixmatch 来源生效——网易云音乐/QQ音乐的译文固定是中文"))
            }

            Section("展示") {
                Toggle(L10n.t("优先逐字高亮(有的话)"), isOn: Binding(
                    get: { settings.preferWordLevelKaraoke },
                    set: { newValue in
                        settings.preferWordLevelKaraoke = newValue
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
                        HelpButton(text: L10n.t("歌词默认就以这个文件夹为准维护——联网匹配到的结果会导出成文件存在这里，「歌词管理」里手动导入/编辑的文件也在这里。换成新文件夹后，旧文件夹里已有的文件不会自动搬过去，需要自己手动移动"))
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
                Text(L10n.t("每首歌听过一次,歌词就会永久保存在这个文件夹里;在「歌词管理」里删除会同时删掉这里已导出的文件"))
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
        settings.foregroundColorHex = theme.foregroundColorHex
        settings.backgroundColorHex = theme.backgroundColorHex
        settings.textStrokeEnabled = theme.textStrokeEnabled
        settings.textStrokeColorHex = theme.textStrokeColorHex
    }

    // 当前四个配色字段正好等于哪个内置预设/自定义主题就显示它的名字,谁都不等于
    // (比如套用之后又手动微调过某个颜色)就显示"自定义"——这是"使用内置预设"这个
    // Menu 唯一的选中反馈来源,见调用点注释。
    private var currentColorThemeLabel: String {
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
        Form {
            Section(L10n.t("歌词展示")) {
                // 桌面悬浮歌词(经典悬浮窗)、灵动岛歌词是两个完全独立的展示位置,各自
                // 独立开关,不互斥,可以同时开、只开一个、或都不开。每个开关只负责
                // "生效"这一个控制器自己的 setVisible,不碰另一个;首次打开某个样式时
                // 顺手把"截屏/录屏时隐藏""暂停/无播放时隐藏"这两个已配置好的偏好也
                // 应用上去——否则那个控制器还停留在 init() 里的硬编码默认值,要等下次
                // 重启 App 走 AppDelegate 那条初始化路径才会生效,期间会悄悄违背用户
                // 已经勾选的偏好。
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
                // 只负责持久化,NotchLyricsView 每次渲染直接读 settings.notchCardStyle,
                // 不需要像 classicOverlayEnabled/notchOverlayEnabled 那样在这里连带
                // 调用某个窗口控制器的方法"生效"。
                //
                // 灵动岛没开时这个风格选项对用户毫无意义(没有窗口在用它),包进
                // `if settings.notchOverlayEnabled` 才显示——跟下面"超过就截断"那组
                // 只在 showLyricsInMenuBar 开着时才出现是同一个模式。
                if settings.notchOverlayEnabled {
                    Picker(L10n.t("灵动岛风格"), selection: $settings.notchCardStyle) {
                        ForEach(NotchCardStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.menu)

                    // 跟上面经典悬浮窗的"宽度"滑块同一套写法(设置项本身只负责持久化,
                    // didSet 不碰 NSWindow,这里的 set 闭包显式调用窗口控制器的方法让
                    // 改动立刻生效)。跟经典悬浮窗不同的是灵动岛不需要"保持中心点"的
                    // 增量调整——它的位置从来都是重新居中算出来的,见
                    // NotchLyricsWindowController.applyContentWidthSetting() 的注释。
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
                }
                Toggle(L10n.t("菜单栏歌词"), isOn: $settings.showLyricsInMenuBar)
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
                    Text(L10n.t("没超过就整行显示；超过这个长度会截断，鼠标悬停在状态栏上能看到完整这一行"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L10n.t("外观")) {
                // 配色主题——内置预设一键套用+把当前调好的配色另存复用,对标 PlayStatus/
                // Lyricify/AlgerMusicPlayer/HotLyric/VutronMusic 都有的这层。只打包"配色"
                // 相关的四个字段(文字/背景/阴影颜色+阴影开关),不含字体/字号——那是排版,
                // 跟配色是两回事,不该被同一个"主题"捆在一起改(见 ColorTheme.swift)。
                // 套用即时生效,跟下面手动挪动色板是同一套 Binding,没有额外的"应用"步骤。
                // Menu 的标签本身显示"当前配色正好等于哪个主题"(不等于任何一个就显示
                // "自定义"),作为这个 Menu 唯一的选中反馈。
                Menu(currentColorThemeLabel) {
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

                Toggle(L10n.t("文字描边(与桌面背景区分)"), isOn: $settings.textStrokeEnabled)

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
                    settings.fontFamilyName = AppSettings.defaultFontFamilyName
                    settings.fontSize = AppSettings.defaultFontSize
                    settings.foregroundColorHex = ColorTheme.defaultTheme.foregroundColorHex
                    settings.backgroundColorHex = ColorTheme.defaultTheme.backgroundColorHex
                    settings.textStrokeEnabled = ColorTheme.defaultTheme.textStrokeEnabled
                    settings.textStrokeColorHex = ColorTheme.defaultTheme.textStrokeColorHex
                }
                .buttonStyle(.link)
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
                Toggle(L10n.t("锁定位置"), isOn: Binding(
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
                // 这个 Section 里"宽度"/"锁定位置"两项是经典悬浮窗
                // (LyricsOverlayWindowController)专属的,但下面"截屏/录屏时隐藏"/
                // "暂停/无播放时隐藏"这两个开关其实对灵动岛歌词
                // (NotchLyricsWindowController)同样生效(见各自的 set 闭包,两个控制器
                // 都会调)——标题"悬浮歌词窗口"对这两项来说不算完全精确,但没有拆分成
                // 两个 Section。
                Text(L10n.t("悬浮歌词窗口"))
            } footer: {
                // footer 挂在整个 Section 上(而不是紧跟某个 Toggle 下面的裸 Text)——
                // 分组样式里这是原生"注脚"位置,明确点名是哪个开关的说明,避免视觉上跟
                // 其它开关混在一起。两句分行摆放,顺序跟上面 Toggle 的出现顺序对应
                // (先"锁定位置"、再"截屏/录屏时隐藏")。
                //
                // 第一句是这次新加的:"锁定位置"改名去掉了"(不可拖拽+点击穿透)"这个
                // 括号说明,是因为点击穿透现在解锁状态下也一直生效(不再是锁定独有的
                // 行为),括号内容已经不准确;但"解锁后长按才能拖动"这个手势本身并不
                // 直观(不看说明容易只当成"按住就能拖"或者"这窗口点不动了"),需要在
                // 这里补一句显式说明,不能单靠去掉括号里的旧文案就假装用户会自己发现。
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("解锁「锁定位置」后,悬浮歌词默认可以直接点击穿透到它下面的内容;长按住悬浮歌词不放,才能拖动它的位置"))
                    Text(L10n.t("开启「截屏/录屏时隐藏」后,截图、录屏、视频会议共享屏幕都不会拍到悬浮歌词——但你自己在这台 Mac 上仍然正常看得见"))
                }
            }
        }
        .formStyle(.grouped)
        // SwiftUI 有时不会在语言切换后重新执行某些嵌套内容的 body(取决于该内容自己的
        // 存储属性有没有变,而非父视图是否重新渲染,详见 AccountLinkingTab.swift 里
        // DestinationStatus.label 的注释)。用 .id(L10n.current) 把 Form 的身份跟当前
        // 语言绑死,语言一变就强制整体重新构造,不需要逐个排查哪里在跳过刷新。
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
                            Text(L10n.t("这次请求耗时有点久——如果你已经看到系统弹窗，请去处理它；找不到弹窗的话，可以直接去系统设置里手动开启"))
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
                Text(L10n.t("Lyrimuse 靠这个权限读取 Apple Music 当前播放的歌曲信息——没有它，悬浮歌词/灵动岛都无法显示任何歌词内容"))
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
            } header: {
                Text(L10n.t("常驻服务"))
            } footer: {
                Text(L10n.t("负责读取播放状态、解析歌词/封面并写入本地缓存的后台程序——没有它，悬浮歌词/灵动岛同样无法显示任何内容"))
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
        Task {
            let running = await CollectorServiceManager.setEnabledAndWait(enabling)
            settings.collectorServiceEnabled = enabling
            collectorRunning = running
            isTogglingCollectorService = false
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
                    Text(L10n.t("跟着 Apple Music 播放，实时显示逐字同步歌词"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // Sparkle 自己处理"检查中/已是最新/发现新版本"这几种状态的 UI
                    // 展示(SPUStandardUserDriver 的标准弹窗),不需要自己维护 loading
                    // 状态或者判断结果再手动弹 alert。
                    Button(L10n.t("检查更新")) {
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
                Button(L10n.t("导出诊断信息")) {
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
                Text(L10n.t("汇总 App/采集器日志和权限、常驻服务等关键状态,保存成一份文本文件——不会包含任何账号 token 或密钥的原始内容"))
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
