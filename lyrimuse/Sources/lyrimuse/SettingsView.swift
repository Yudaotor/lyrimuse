import SwiftUI
import AppKit
import LyrimuseCore
import KeyboardShortcuts

// 整个设置窗口是一层真正的 NavigationSplitView:左边一份侧边栏 List,右边显示当前
// 选中项的详情。"账号连接"没有做成侧边栏里单独可选中的大分类,而是拆成普通账号行,
// 跟播放/歌词/歌词显示/通用平级放进同一个 List 里——原因是嵌套第二层"看起来像侧边栏"的
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
        // 2026-08-17 从「外观」改成这个。原名错在三处:① 这一页的第一层结构是按**展示
        // 方式**分的四个分段(悬浮歌词/灵动岛/菜单栏/其它),讲的是"歌词显示在哪儿",不是
        // "外观";② 它**不含** App 真正的外观项 —— 菜单栏图标和 Dock 图标都在「通用」,
        // 想换图标的人第一下必点「外观」然后找不到;③ 它**含**一堆不是外观的东西:每种形态
        // 的开关、显示在哪块屏幕、截屏时隐藏、暂停时隐藏、锁定位置。
        case .appearance: return L10n.t("歌词显示")
        case .shortcuts: return L10n.t("快捷键")
        case .general: return L10n.t("通用")
        case .about: return L10n.t("关于")
        }
    }

    var icon: String {
        switch self {
        case .lyrics: return "text.quote"
        case .player: return "play.circle"
        // 画笔是"外观"的语言,跟着改名一起换掉。rectangle.3.group 读出来是"同一份内容摆在
        // 好几处",正对上这一页的实际结构(歌词能出现在三个地方);也不跟侧边栏现有的
        // text.quote/play.circle/keyboard/gearshape/info.circle 撞。
        case .appearance: return "rectangle.3.group"
        case .shortcuts: return "keyboard"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }

    // tint 特意避开已经在用的四个账号色(orange/pink/blue/red)和歌词来源色点(red/
    // green/cyan/purple,见 LyricsManagerView.swift 的 sourceColor)——"歌词显示"尤其不用
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
// (36pt/圆角8)共用同一份渲染逻辑,不各自重复手写一遍。
//
// 2026-08-18:原来这里整个是个自由函数,理由写的是"只有两组固定的(size, cornerRadius)
// 组合在用,不是一个需要 View 身份/状态的东西"。深色模式压暗色块要读
// @Environment(\.colorScheme),自由函数拿不到 environment,所以真身改成了 View 类型;
// 对外仍是同名自由函数,十几个调用点一个都不用改。
func iconBadge(_ systemName: String, tint: Color, size: CGFloat = 22, cornerRadius: CGFloat = 6) -> some View {
    IconBadge(systemName: systemName, tint: tint, size: size, cornerRadius: cornerRadius)
}

private struct IconBadge: View {
    let systemName: String
    let tint: Color
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    /// 符号外接框占整个方块的比例。22pt 方块 × 0.62 = 13.6pt,跟改之前圆形符号
    /// (play.circle/info.circle)本来的墨迹宽度 13.0pt 基本持平——所以那几个看上去
    /// 几乎没变,被收窄的只有原本过宽的那几个。
    private static let glyphRatio: CGFloat = 0.62

    var body: some View {
        // 2026-08-18 用户反馈「歌词显示」这个徽标"里面的内容都已经大到边框了"。量下来
        // 属实,而且是整套徽标的系统性问题:原来这里既不设 .font 也不设 .imageScale,
        // 符号吃环境默认的 13pt,而 SF Symbol 之间是按**大写字母高度**对齐的、不是按
        // 外接框对齐——同一字号下宽符号必然比圆符号占掉多得多的横向空间。实测 22pt
        // 方块里的墨迹占比:rectangle.3.group 81%(左右只剩 2.0pt 边距)、
        // dot.radiowaves.left.and.right 75%、keyboard 73%,而 play.circle / info.circle
        // 只有 59%(边距 4.5pt)。
        //
        // 统一调小字号救不了:那是等比缩,相对差距原样保留(试过 ×0.5,rectangle.3.group
        // 仍占 69%、边距仍只有 3.25pt,别的图标反而一起变小变弱)。所以改成逐符号归一化
        // ——resizable + scaledToFit 把每个符号的**外接框**装进同一个内框,过宽的自己缩
        // 下去,本来就方的几乎不动。
        //
        // 同一处顺带修掉一个一直没人报的问题:不设字号 = 符号大小完全不跟 size 走。账号
        // 详情页头那个 36pt 徽标里的符号一直还是 22pt 那档大小,墨迹只占方块 33%~50%,
        // 一个小图标飘在大方块中间。现在符号跟着 size 等比,大徽标才真的被填满。
        //
        // 代价说清楚:resizable 会连描边粗细一起缩放,严格说破坏了 SF Symbol 跨图标的
        // 统一线重(Apple 因此不建议对 SF Symbol 用 resizable)。这里换来的是"每个彩色
        // 方块里的图形占位一致",对一组并排的徽标来说更重要。离线渲染逐档比对过。
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: size * Self.glyphRatio, height: size * Self.glyphRatio)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(colorScheme == .dark ? SettingsIconTint.dimmedForDarkMode(tint) : tint,
                        in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// 深色模式下给徽标色块的亮度封顶。
///
/// 起因(2026-08-18 用户反馈"这些图标在深色模式下会不会太亮"):侧边栏这批 tint 里有几个
/// 绝对亮度非常高,压在深色底上像在发光——量出来 yellow #FFD600 相对亮度 0.694、
/// mint #00DAC3 0.541、teal #00D2E0 0.515,而 indigo/blue/red 都只有 0.25~0.28。更实的
/// 问题是压在色块上的那个**白色 SF Symbol**:白色在 yellow 上只有 1.41:1、mint 1.78:1、
/// teal 1.86:1,远低于 WCAG 对图形/UI 部件的 3:1。"发光"和"图标糊掉"是同一个根因。
///
/// 上限 0.30 不是拍脑袋来的:白色相对亮度是 1.0,要保住 3:1 就要求 (1.0+0.05)/(L+0.05) >= 3,
/// 解出来 L <= 0.30。也就是"色块最多亮到白图标还合格为止"。
///
/// 压暗在**线性光**里做:线性 RGB 三通道同乘一个系数,相对亮度按同一系数线性下降(亮度就是
/// 三通道线性值的加权和),而三者比例不变 = 色相和饱和度分毫不动。所以有闭式解
/// k = 上限 / 当前亮度,不需要二分逼近。已经低于上限的色块原样返回——indigo/blue/red 实际
/// 都不会被动到,gray 只会从 0.316 挪到 0.300(肉眼看不出)。
///
/// 只在深色模式下用。浅色模式下白图标压在 yellow 上同样只有 1.51:1,但那边色块不会在亮底上
/// "发光",而压暗会把黄压成橄榄色、丢掉"黄"的身份;2026-08-18 拿离线渲染把两边并排比过之后
/// 决定浅色维持原样。要改浅色的话,把 IconBadge 里那个 colorScheme 判断去掉即可。
enum SettingsIconTint {
    /// 白图标要保住 3:1,色块相对亮度的上限。
    static let luminanceCap = 0.30

    static func dimmedForDarkMode(_ tint: Color) -> Color {
        // 系统色(.yellow/.mint/…)是随外观解析的动态色,必须显式在 darkAqua 下取值——
        // body 求值时的 currentDrawing 不保证就是深色。
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(tint).usingColorSpace(.sRGB)
        }
        guard let base = resolved else { return tint }
        let r = linearized(base.redComponent)
        let g = linearized(base.greenComponent)
        let b = linearized(base.blueComponent)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luminance > luminanceCap else { return tint }
        let k = luminanceCap / luminance
        return Color(nsColor: NSColor(srgbRed: encoded(r * k), green: encoded(g * k),
                                      blue: encoded(b * k), alpha: base.alphaComponent))
    }

    private static func linearized(_ c: CGFloat) -> Double {
        let v = Double(c)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ c: Double) -> CGFloat {
        let v = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return CGFloat(min(max(v, 0), 1))
    }
}

enum SettingsSidebarItem: Hashable {
    case tab(SettingsTab)
    case account(AccountDestination)
}

struct SettingsView: View {
    // 只用来在语言手动切换时让侧边栏/详情页的整棵子树重新渲染(sidebarLabel/
    // selectedCategoryTitle 这些顶层 chrome 文字不属于任何一个具体 tab,原来没有任何一处
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
                        // 箭头紧跟标题,不用 Spacer 顶到最右:侧边栏只有 220pt 宽,顶到最右
                        // 会离边缘只剩 3.5pt(比下面那些行的胶囊还往外突出一截)、中间空出
                        // 近 100pt,一个孤零零的箭头吊在那儿(2026-08-12 用户反馈)。跟
                        // Last.fm 那三张卡的折叠表头也是同一个样式:箭头就在标题旁边。
                        HStack(spacing: 4) {
                            Text(L10n.t("实验室功能"))
                            Image(systemName: "questionmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isAdditionalFeaturesExpanded ? 90 : 0))
                                .padding(.leading, 1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("实验性 Beta 功能"))
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
            // 2026-08-25 拆开:窗口**标题**钉死成「设置」,当前分类改用副标题。原来标题栏
            // 跟着选中的分类走(仿系统"系统设置"那套"标题=当前面板名"的做法),但那套设计
            // 假设这扇窗口有自己独占的 Dock 图标——这个 App 的 Dock/Window 菜单是"设置"/
            // "歌词管理"/"歌词窗口"四扇窗共用的**同一个**图标,右键菜单里蹦出一条"通用"或
            // "外观",完全看不出它是设置窗口(用户 2026-08-25 反馈"想在 Dock 里认出哪扇是
            // 哪扇")。副标题只出现在标题栏、不会进 Window 菜单/Dock 右键列表,分类上下文
            // 照样留得住,只是不再顶替窗口的身份。
            .navigationTitle(L10n.t("设置"))
            .navigationSubtitle(selectedCategoryTitle)
        }
        // 原来是给 TabView 焊死的 440pt 改出来的 minWidth/idealWidth——现在换成
        // NavigationSplitView,多了一列侧边栏,整体相应加宽;同样不设 maxWidth/固定
        // 高度,各分类继续按内容自动撑高。
        // 高度这一档是跟着「歌词显示」页的固定头部定的:那一页顶上钉着分段选择器 + 实时预览,
        // 实测占 205pt。窗口 460 高时滚动区只剩 255pt,一屏放不下两张卡,滚起来很碎;
        // idealHeight 给到 640,滚动区就有 ~430pt。minHeight 同步抬到 520,避免有人拖到
        // 极限后滚动区比头部还矮。
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
        .background(SettingsWindowConfigurator())
        // 见 AppActions.pendingSettingsSelection 注释——Onboarding 的 Last.fm 步骤
        // 借这个信箱指定"这次打开设置窗口要直接停在哪个分类",这里读一次就清空,不影响
        // 之后用户正常打开设置窗口(默认还是回到 .tab(.lyrics))。
        .onAppear {
            if let pending = AppActions.shared.pendingSettingsSelection {
                selection = pending
                AppActions.shared.pendingSettingsSelection = nil
            }
        }
        // 窗口**已经开着**时走这条:上面那个 .onAppear 只在窗口新建那一次跑,不会再有第二次
        // (见 AppActions.requestSettings)。两条都要,因为反过来也成立 —— 窗口还没建时
        // subject 发出去没人接,那次得靠信箱。
        .onReceive(AppActions.shared.selectionRequests) { item in
            selection = item
            // 同一次请求在信箱里的那份一并清掉,免得下次新建窗口时又被它顶一次。
            AppActions.shared.pendingSettingsSelection = nil
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

    private var selectedCategoryTitle: String {
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
    // 这一个反过来要订阅:下面「时间轴偏移」那行得实时显示当前值。它只在用户真的
    // 改这个值时才发通知,不像 local 那样每轮播放轮询都推,所以订阅它不会带来上面那段
    // 注释里说的白白重渲染。
    @ObservedObject private var offsets = LyricsOffsetStore.shared

    /// 一种文字的罗马音开关。跟中文繁简那个 Picker 一样**双写**:AppSettings 负责持久化,
    /// LocalPlaybackSource 负责让当前这首歌立刻重新解析(它的 didSet 会 reload)。
    /// 只写一边的话,要么关了 App 就忘,要么改了要等下一首歌才生效。
    ///
    /// ⚠️ 语言名必须自己摆一个 Text,不能用 Toggle 自带的 label —— 行容器
    /// (SettingsRow/SettingsSubRow)对 trailing 统一加了 .labelsHidden(),Toggle 自己的
    /// 标签会被一起吃掉。2026-08-15 之前正是这么写的,屏幕上就是三个光秃秃的复选框,
    /// 谁也看不出哪个对应哪种语言(用户报的就是这个)。
    private func romanizationToggle(
        _ title: String, _ option: RomanizationScripts, help: String
    ) -> some View {
        HStack(spacing: 4) {
            Toggle("", isOn: Binding(
                get: { settings.romanizationScripts.contains(option) },
                set: { on in
                    var next = settings.romanizationScripts
                    if on { next.insert(option) } else { next.remove(option) }
                    settings.romanizationScripts = next
                    local.romanizationScripts = next
                }
            ))
            .toggleStyle(.checkbox)
            Text(title).font(.system(size: 12))
        }
        .help(help)
    }
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
            // 2026-08-17 从「显示」改名:侧边栏另有一个「歌词显示」分类(管三种展示面的
            // 开关和样式),同一个词出现在两层,想调字体的人会先来这里扑空。这一段管的是
            // 歌词内容本身的呈现效果(卡拉OK/繁简/罗马音/双行),「效果」不与那边撞名。
            // rawValue 仍是 display,@AppStorage 存的是 rawValue,改显示名不动持久化。
            case .display: return L10n.t("效果")
            case .manage: return L10n.t("管理")
            }
        }
    }

    // 记住上次看的是哪一段 —— 每次重开设置都跳回第一段的话,连着调同一段的两项就要多点
    // 一次。存 rawValue 而不是枚举:@AppStorage 只吃基础类型。
    /// 鼠标悬在哪个来源上(只为悬停底色,不影响任何配置)。
    @State private var hoveredSource: String?

    // MARK: - 时间轴偏移那一行的「作用于哪个播放器」(2026-08-21 加)

    /// 空串 = 「全部播放器」(就是既有的全局那层,存储上没有"全部"这个哨兵);否则是某个播放器
    /// 的 bundle id。**故意只是 @State、不持久化**:绝大多数人只需要动「全部」那一档,每次打开
    /// 设置页从它开始最省事;落进 @AppStorage 还会多一个 np: 键(而 np: 前缀是配置导出的白
    /// 名单,等于把一个纯界面状态搬去新机器)。
    @State private var offsetScope = ""
    /// 下拉里标「正在播放」用。**必须拿播放态兜一道**:LocalPlaybackSource 从不清 lastSnapshot,
    /// 停播之后 lastResolvedBundleID 是"陈旧但非 nil"的,直接用会一直指着最后那个播放器说
    /// 它正在放。
    @State private var nowPlayingBundleID: String?

    private func refreshNowPlayingPlayer() {
        let coordinator = PlaybackCoordinator.shared
        nowPlayingBundleID = coordinator.isPlayingSmoothed ? coordinator.resolvedPlayerBundleID : nil
    }

    /// 下拉框的候选,四组并集(顺序即展示顺序):
    ///  1. 内置播放器,按 `PlaybackPlayer.displayOrder`(按系统语言排,跟"选择播放器"图标
    ///     网格同一套顺序)—— **不含「自动识别」**:它的 bundleIdentifier 是空串,存进去会被
    ///     `setPlayerOffset` 静默丢掉(用户调了半天没反应);"自动"这层语义本来就由「全部
    ///     播放器」承担。
    ///  2. 用户信任的未知播放器(浏览器就在这一组 —— 这个功能的动机)。
    ///  3. **已经配过偏移的** —— 哪怕它已经不在信任名单里(取消信任了、App 卸了)也必须列出来,
    ///     否则那个非零偏移会变成看不见、改不动的隐形值。2026-08-18 那版按播放器偏移正是这么
    ///     翻的车(见 LyricsOffsetStore.playerOffsets 的注释)。
    ///  4. 此刻正在放的那个 —— 可能是还没加进信任名单的 App,用户往往正是为它才来调这个。
    private var offsetScopeOptions: [String] {
        // 并集/去重/排序的规则连同那三条不变量都在 LyrimuseCore.LyricsOffsetScope 里(纯函数,
        // selftest 覆盖)—— 混在 View 里的话,「配过偏移但已不在信任名单」这类只在特定用户状态
        // 下才暴露的分支除了肉眼盯下拉框以外没法验证。
        //
        // builtInOrder 传 PlaybackPlayer.displayOrder(2026-08-25 用户要求)——跟"选择播放器"
        // 图标网格用同一套按系统语言排的顺序,同一批播放器在这个下拉框里不该是另一个顺序。
        // LyricsOffsetScope 自己在 LyrimuseCore,够不到 displayOrder(App target 里依赖
        // AppSettings 的属性),所以顺序从这里传进去,见该函数参数注释。
        LyricsOffsetScope.options(
            builtInOrder: PlaybackPlayer.displayOrder,
            trusted: features.trustedPlayers,
            configured: Set(offsets.playerOffsets.keys),
            nowPlaying: nowPlayingBundleID
        )
    }

    /// bundle id → 人看得懂的名字。内置的用枚举自带的显示名,信任项用当初存下来的那份(空串时
    /// 现查一次 NSWorkspace),都查不到就退回 bundle id 本身 —— 退回也比显示空白好。
    private func playerDisplayName(_ bundleID: String) -> String {
        if let builtin = PlaybackPlayer.allCases.first(where: { $0 != .auto && $0.bundleIdentifier == bundleID }) {
            return builtin.displayName
        }
        if let trusted = features.trustedPlayers[bundleID], !trusted.isEmpty { return trusted }
        return FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
    }

    /// 下拉项的文字:名字 + 一个状态后缀。「已调」那个后缀是为了让"哪些播放器配过"一眼可见 ——
    /// 不然用户得逐个点开才知道,而看不见的非零偏移正是这层要避免的事。
    private func offsetScopeLabel(_ bundleID: String) -> String {
        let name = playerDisplayName(bundleID)
        if bundleID == nowPlayingBundleID { return name + L10n.t("（正在播放）") }
        if offsets.playerOffset(forBundleID: bundleID) != 0 { return name + L10n.t("（已调）") }
        return name
    }

    /// 当前作用域那一档的值。两个作用域各读各的存储,切换下拉时数字**不跟着带过去** ——
    /// 那会让人以为在改同一个数,实际是往两层各写一份、相加成双倍校正。
    private var scopedOffsetMs: Int {
        offsetScope.isEmpty ? offsets.globalOffsetMs : offsets.playerOffset(forBundleID: offsetScope)
    }

    private func setScopedOffset(_ ms: Int) {
        if offsetScope.isEmpty {
            PlaybackCoordinator.shared.setGlobalLyricsOffset(ms)
        } else {
            PlaybackCoordinator.shared.setPlayerLyricsOffset(ms, forBundleID: offsetScope)
        }
    }

    // 标题/副标题/help 都是**固定文案**,不跟着下拉框选中项变(2026-08-21 用户要求:「列表里选了
    // 也不要变前面的文案,始终一个就好」)。原来那版会把标题换成「Apple Music 的时间轴偏移」、
    // 副标题换成「只在 X 放歌时额外叠加」—— 每换一次选中项整行文案跳一次,而且"额外叠加"那句
    // 在语义改成二选一之后本身就错了。
    @AppStorage("settings:lyricsSection") private var sectionRaw = Section.fetch.rawValue
    private var section: Section { Section(rawValue: sectionRaw) ?? .fetch }

    var body: some View {
        // 这一页没有预览条,也就不需要固定头部;分段选择器跟「歌词显示」页一样留在滚动区
        // (理由见那一页 header 上的注释)。
        SettingsPage(
            title: L10n.t("歌词"),
            subtitle: L10n.t("让每首歌都有一份对得上的歌词")
        ) {
            sectionPicker
            // 切段用纯淡入淡出,不用卡片那套 .settingsCard(带从顶边缩放):那个是"这一行
            // 下面长出一张卡"的语义,整页换内容时会像整块东西塌下去。时长也短一截 ——
            // 分段切换在用户心里等同于换标签页,该是即时的。
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
            // 这一段只有一张卡(来源/匹配/预取),跟其余三段的一段一卡对齐。预取原来是
            // 独立一张卡摆在最前面 —— 用户真正要动的决策(选来源、挑算法)反而被一个
            // 无感优化开关压在下面,2026-08-17 并进来源卡尾部,主次归位。
            sourcesAndMatchingCard
        case .translation:
            translationCard
        case .display:
            displayCard
        case .manage:
            managementCard
        }
    }

    // 每个来源前面那个彩色圆点用 iconTint 上色——这里的图标不是"行首的视觉锚点",它本身
    // 就是这个来源的身份色(跟"歌词管理"窗口里来源列的色点是同一套 source.color)。
    private var sourcesAndMatchingCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("歌词来源"))
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
                help: L10n.t("智能算法：给每个来源打分（逐字时间轴、语言匹配等），取分最高的\n顺序优先：不打分，按下面的顺序取第一个有结果的来源")
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
            CardDivider()
            // "解析"(而非"预取")避免被误读成预先加载音频本身,这个开关从不碰音频。
            // 2026-08-09 起它曾独立成卡摆在这一段最前面,2026-08-17 并进来:一个无感优化
            // 开关不值得占一整张卡,更不该排在来源/匹配这些真正的决策项前面。
            SettingsRow(
                icon: "square.stack",
                // 不给 ? 提示。这里原来解释的是"它只认资料库里的曲目" —— 那条注意事项
                // 存在的理由是"开了却什么都没发生";2026-08-14 预取扩展到全部播放器之后,
                // 那个坑只剩"Apple Music 播非资料库专辑"这一种窄情况,而预取本来就是无感的
                // (成功与否用户都看不见),为它常驻一个 ? 是拿噪声换不了任何决策。标题本身
                // 已经说清楚这个开关做什么。
                title: L10n.t("提前解析同专辑其它曲目")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.albumPrefetch },
                    set: { features.albumPrefetch = $0; Task { await features.save() } }
                ))
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
        sourceCheckbox(
            id: source.rawValue, name: source.displayName, color: source.color,
            on: features.lyricsSources.contains(source),
            toggle: { setSource(source, enabled: $0) })
    }

    private func sourceCheckbox(
        id: String, name: String, color: Color, on: Bool, toggle: @escaping (Bool) -> Void
    ) -> some View {
        let hovered = hoveredSource == id
        return Button {
            toggle(!on)
        } label: {
            HStack(spacing: 6) {
                // 勾要留着 —— 只画一个实心圆点的话,五个来源全开时这一排看上去就是一条
                // 静态色标图例,完全读不出"能点"。勾 = 多选,圆的颜色 = 这是谁,两件事各
                // 说各的,不再重复。
                ZStack {
                    Circle()
                        .fill(on ? color : .clear)
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
                Text(name)
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
        .onHover { hoveredSource = $0 ? id : (hoveredSource == id ? nil : hoveredSource) }
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
                title: L10n.t("中文繁简切换"),
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
            // 按语言分别开关 —— 同一个人对不同语言的需求常常是相反的:听日文歌要罗马字
            // 才跟得上,听中文歌完全不需要拼音。总开关关着时这几行没有意义,收起来。
            if settings.showRomanization {
                CardDivider()
                // 这一项是"显示罗马音"的附属项,所以用子行(缩进 + 左边那条竖线)而不是主行:
                // 原来用的是跟上面同款的 SettingsRow,两行长得一模一样,看不出谁属于谁。
                SettingsSubRow(
                    title: L10n.t("标注哪些语言")
                ) {
                    HStack(spacing: 12) {
                        romanizationToggle(
                            L10n.t("日语"), .japanese,
                            help: L10n.t("只对判定为日语的歌词生效，例如 こんにちは → konnichiwa"))
                        romanizationToggle(
                            L10n.t("韩语"), .korean,
                            help: L10n.t("只对判定为韩语的歌词生效，例如 안녕하세요 → annyeonghaseyo"))
                        romanizationToggle(
                            L10n.t("中文"), .chinese,
                            help: L10n.t("只对判定为中文的歌词生效，例如 你好 → nǐ hǎo；默认关闭，中文歌词加拼音对中文读者通常是干扰"))
                    }
                }
                // 这句原来是常驻副标题,2026-08-17 挪进悬停说明(用户要求)——三个语言
                // 开关各自已经带了更具体的 help,行上再顶一句概括是重复的噪声。
                .help(L10n.t("日语、韩语标成罗马字，中文标成拼音"))
            }
            CardDivider()
            SettingsRow(
                icon: "text.aligncenter",
                title: L10n.t("双行显示"),
                // 旁边的译文/罗马音都标了生效面,唯独这行没有 —— 开着灵动岛的人打开它
                // 没反应,会以为开关坏了。实际消费方只有 LyricsOverlayView(悬浮歌词)。
                help: L10n.t("这个开关只影响「桌面悬浮歌词」：在当前句下方预览下一句。歌词窗口本来就显示整份歌词，灵动岛和菜单栏只有一行空间")
            ) {
                Toggle("", isOn: $settings.showNextLinePreview)
            }
            CardDivider()
            // 时间轴偏移(2026-08-17 加,2026-08-21 加播放器维度)。跟菜单栏「歌词时间轴」那个单曲微调是两档:
            // 这里校的是设备侧的固定延迟(它跟哪首歌无关,换首歌照样偏),那里校的是某一
            // 份歌词自己的时间轴不准。两者相加才是实际生效的值,见
            // LyricsOffsetStore.globalOffsetMs。
            //
            // 步长固定 0.05 秒,刻意不复用「快捷键」页那个「调整步长」:那个是"每按一次
            // 键跳多少",属于手感;这里是一次性把设备延迟校准到位,要的是精度。绑在一起
            // 的话,把步长调到 1 秒的人在这里就没法微调了。
            // 2026-08-21:这一行加了「作用于哪个播放器」的下拉框。跟 2026-08-18 那个写死的
            // 「Spotify 时间轴偏移」行**不是一回事** —— 那个是代码内部替用户猜的补偿(界面上
            // 看不见、重置不了,后来查明它要补的偏差是自然切歌锚点超前、已由
            // naturalAdvanceCorrection 按曲根修,于是 08-20 连值一起删了)。这个下拉框是用户
            // 自己选播放器、自己调,默认全 0,谁都看得见改得动。
            //
            // 真正需要它的是**浏览器**:Arc/Chrome 这类只在切歌时报一次播放位置,之后
            // elapsedTime 再也不刷新,只能按墙钟外推(PositionSourceTier.cleanExtrapolated),
            // 进度会系统性偏慢;而 Apple Music 那条路径是精确的、一点都不该补。偏差落在
            // "播放器"这个维度上,不在"歌"上。
            //
            // 两档是**二选一、不相加**(2026-08-21 用户拍板):单独配过的播放器只用自己那档,
            // 「全部播放器」对它不生效;调回 0 就撤掉单独设置、重新跟随「全部」。合成规则在
            // LyricsOffsetStore.baseOffsetMs,selftest 有断言钉住(含一条变异测试验证过的
            // "不许退回相加")。
            // 标题/help 都是**固定文案**、不跟着下拉框选中项变(2026-08-21 用户要求:「列表里选了
            // 也不要变前面的文案,始终一个就好」);副标题整条去掉、help 只留"符号往哪边走 + 典型
            // 用途"这一句(同一次要求:那两段解释语义的长文案都删掉)。
            //
            // 也就是说「两档二选一、调回 0 就跟随全部」这些规则**界面上不写** —— 它们记在
            // LyricsOffsetStore.baseOffsetMs 的注释和 docs/features/08 里。改这一行的人注意:
            // 别再往这里加解释性文案,那是用户明确否掉过两次的东西。
            SettingsRow(
                icon: "timer",
                title: L10n.t("全局时间轴偏移"),
                help: L10n.t("正数＝歌词提前，负数＝歌词延后；常用来抵消蓝牙耳机的声音延迟")
            ) {
                HStack(spacing: 8) {
                    Picker("", selection: $offsetScope) {
                        // 「全部播放器」= 既有的全局那层,tag 用空串(bundle id 不可能是空串)。
                        Text(L10n.t("全部播放器")).tag("")
                        ForEach(offsetScopeOptions, id: \.self) { bundleID in
                            Text(offsetScopeLabel(bundleID)).tag(bundleID)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Text("\(AppSettings.signedSeconds(ms: scopedOffsetMs))\(L10n.t("秒"))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    // 数值必须摆在 Stepper 外面 —— SettingsRow 给尾部控件统一套了
                    // .labelsHidden(),而 Stepper 是把数值画在 label 里的,放进去会被
                    // 一并藏掉(「调整步长」那一行踩过,见那边的注释)。
                    Stepper("", value: Binding(
                        get: { Double(scopedOffsetMs) / 1000 },
                        set: { setScopedOffset(Int(($0 * 1000).rounded())) }
                    ), in: -5.0...5.0, step: 0.05)
                    // 只在真的偏移过时才给「重置」:值为 0 时摆一个点了什么都不会变的
                    // 按钮,跟菜单里那个「重置」同一个道理。
                    if scopedOffsetMs != 0 {
                        Button(L10n.t("重置")) { setScopedOffset(0) }
                    }
                }
            }
            // 「正在播放」那个标记要跟着播放状态走。2 秒一跳,跟这个设置页里其它几处轮询同一个
            // 节奏;读的是存储属性而不是订阅 —— 这个 Tab 刻意不订阅 local/coordinator(每轮播放
            // 轮询都推,会让整页白重渲染,见文件顶部 `local` 那条注释)。
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                refreshNowPlayingPlayer()
            }
            .onAppear { refreshNowPlayingPlayer() }
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
                subtitle: L10n.t("歌词保存在这里"),
                help: L10n.t("换文件夹后，旧文件不会自动搬过去")
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
    @State private var showSaveThemeAlert = false
    @State private var newThemeName = ""
    // 待确认删除的自定义主题。删除会立刻落盘且没有撤销,必须先问一句。
    @State private var themePendingDeletion: ColorTheme?
    // 灵动岛"显示在哪块屏幕"下拉的选项来源。用 @State 快照而不是每次 body 现读
    // NSScreen.screens:插拔显示器时 SwiftUI 不会因为一个全局数组变了就重算 body,
    // 得靠下面那条 didChangeScreenParameters 通知显式刷新。
    @State private var availableScreens: [NSScreen] = NSScreen.screens
    /// 「所有屏幕」在那个下拉里的哨兵 tag。屏幕的真实 tag 是 ScreenIdentity 给的 UUID
    /// 串,不可能撞上这个值;空串已经被「自动」占了。
    private static let allScreensTag = "__all_screens__"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    // 字段。
    //
    // 2026-08-14 去掉了"followsCoverArt 开着就直接显示「跟随封面」"这个短路。当时那么写是
    // 因为「跟随封面」也是这个 Menu 里的一项,不短路的话选中态会指向别处;现在它已经是一个
    // 独立开关,这个 Menu 只负责固定配色,就该老老实实反映四个颜色字段当前等于哪一套 ——
    // 否则开着"跟随封面"时,用户完全看不出自己的备用色到底是哪个主题。
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
        // 2026-08-06 从 .formStyle(.grouped) 换成这套卡片组件(见 SettingsDesignSystem.swift)。
        // 结构上的分组沿用 2026-08-05 那次"每种展示方式各占一张卡"的划分,没有再动:
        // 一张卡放四个总开关,之后每种展示方式各一张卡、只在这种方式开着时出现,共用的
        // 两个隐藏开关单独一张。
        //
        // 换成卡片之后多出来一件原来做不到的事:每一行可以自带一句副标题。原来"四种展示
        // 方式互不冲突,可以同时开启:桌面悬浮歌词贴在桌面上、支持逐字高亮;灵动岛歌词
        // 紧凑地贴着刘海显示;..." 是**一整段** Section 尾注,四种方式的说明串在一句话里,
        // 读者得自己把每一小段对应回上面第几个开关;现在直接拆成四行各自的副标题。
        // 分段选择器 + 实时预览一起钉在页顶,下面才是滚动区。
        //
        // 预览必须常驻的理由:这一页控件多到本来就要滚,调下半屏的字号时预览要是滚出视野,
        // 等于白做。选择器一起钉上来的理由:它是这一页的导航,滚下去之后还得先滚回顶部才能
        // 换段是说不通的。
        //
        // ⚠️ 2026-08-15 从 .safeAreaInset 换成真正的固定头部。safeAreaInset 是"悬浮"语义:
        // ScrollView 仍占着整块区域,内容会滑到那条悬浮层**底下**去 —— 滚过一段之后选择器
        // 和第一张卡看得见却点不动、鼠标放上去连滚都滚不动。详见
        // SettingsPageWithStickyHeader 上那段注释。
        //
        // 另外一段(「其它」)不给预览:那一段是两个悬浮窗共用的隐藏开关,没有"长什么样"
        // 可看。灵动岛和菜单栏**不能**共用 OverlayPreviewBar —— 那条画的是悬浮歌词的
        // 字体/颜色,而这两个形态压根不读那些字段,各自的预览见 SectionPreviewBars。
        SettingsPageWithStickyHeader {
            // 每一段挂**自己那一段**的预览。
            //
            // 2026-08-15:原来只有悬浮歌词有预览,而且还跟开关联动(关着就不显示)。两处都改:
            //   - 灵动岛/菜单栏各自有了反映自己设置的预览,不再是"这两段没什么可预览的"。
            //   - 不再看开关:配置卡现在关着也能调(见 currentSection),预览要是还跟着开关
            //     藏起来,调的时候就又看不见效果了。
            //
            // ⚠️ 分段选择器**放不进**这个固定头部,尽管"页级导航不该跟内容滚"听起来更对。
            // 放进来它整排点不动 —— 2026-08-15 试过一次,2026-08-16 应用户要求又试了一次,
            // 两次都是同一个结果(第二次用 CGEvent 往选择器真实坐标投点击、截图对比选中态,
            // 确认没有切换;而同一套点击方式点左侧边栏是生效的,排除了"点击没送达")。
            //
            // 2026-08-16 顺带订正了上一版注释里的**归因错误**:那次写的是"指向 NotchPreviewBar
            // 内部那份真实的 NotchLyricsView(它带 .onHover)"。这次复现时当前段是「悬浮歌词」、
            // 头部里根本没有 NotchPreviewBar,照样点不动;而且给整块预览加 .allowsHitTesting(false)
            // 也没用。所以跟预览里放的是哪一个、它内部有没有 hover 手势**无关**,是这个
            // 固定头部结构本身在 SwiftUI 里的事件派发行为。真要做,得把选择器换成
            // NSViewRepresentable 包的 NSSegmentedControl 绕开 SwiftUI 这一层。
            //
            // 选择器因此留在滚动区(那边是另一个 hosting view,实测命中正常),代价是滚下去
            // 之后要滚回顶部才能换段。
            // 高度按当前段自己的预览走(2026-08-19,见 SectionPreviewMetrics 头注),
            // 换段的高度变化用这条动画滑过去,别硬跳 —— 挂 value: sectionRaw,只在换段
            // 那一刻生效,不会波及预览内部的高频刷新(karaoke/跑马灯)。
            Group {
                switch section {
                case .overlay: OverlayPreviewBar()
                case .notch: NotchPreviewBar()
                case .menuBar: MenuBarPreviewBar()
                case .other: EmptyView()
                }
            }
            .animation(.easeOut(duration: 0.18), value: sectionRaw)
        } page: {
            SettingsPage(
                title: L10n.t("歌词显示"),
                // 「三种」而不是原来的「四种」:这一页实际只有三个展示方式开关(桌面悬浮
                // 歌词/灵动岛歌词/菜单栏歌词)。第四种是「歌词窗口」,它压根不在这一页配置
                // —— 靠快捷键/菜单按需打开,没有开关。原文案让人数着三个开关去找第四个。
                subtitle: L10n.t("三种展示方式可以同时开启")
            ) {
                sectionPicker
                currentSection
                    .id(section)
                    .transition(.opacity)
            }
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
    ///
    /// ⚠️ 前三个的 rawValue 是**跨文件契约**:菜单栏面板那边的「全部设置…」要把这一页直接
    /// 翻到对应的形态那一段,靠的就是往下面那个 @AppStorage 键写这几个字符串
    /// (LyrimuseCore.LyricsSurface.appearanceSectionRawValue)。改名字不会编译报错,只会
    /// 表现成"长按灵动岛、设置窗口却停在悬浮歌词那一段"。
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

    // 键名跟菜单栏面板共用同一份常量,别再各写一遍字面量。
    @AppStorage(LyricsSurface.appearanceSectionStorageKey) private var sectionRaw = Section.overlay.rawValue
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
                isOn: Binding(
                    get: { settings.classicOverlayEnabled },
                    set: { LyricsOverlayWindowController.shared.setVisible($0) }))
            // 配置卡**不跟开关联动**(2026-08-15 用户要求):关着也能调。
            // 理由:把它藏起来只是让"先开、调完、再关"变成必须的操作顺序,并不能阻止
            // 什么;而想先配好再打开的人会以为这个形态没有可调项。
            classicOverlayCard
        case .notch:
            modeToggleCard(
                icon: "rectangle.topthird.inset.filled",
                title: L10n.t("灵动岛歌词"),
                subtitle: L10n.t("紧凑地贴着屏幕顶部的刘海显示"),
                isOn: Binding(
                    get: { settings.notchOverlayEnabled },
                    set: { NotchLyricsWindowController.shared.setVisible($0) }))
            notchOverlayCard
        case .menuBar:
            modeToggleCard(
                icon: "menubar.rectangle",
                title: L10n.t("菜单栏歌词"),
                isOn: $settings.showLyricsInMenuBar)
            menuBarCard
        case .other:
            // 自动隐藏是**跨形态**的(悬浮歌词/灵动岛共用同一组规则),所以不能塞进任何一个
            // 单独形态那一段,只能留在这里。两个都没开时它没有作用对象,不显示。
            // 同样不再跟开关联动。原来两个悬浮窗都关着时这里会退化成一块
            // ContentUnavailableView 白板 —— 现在直接把卡片摆出来,想先配好再开的人
            // 不用先去别的段打开开关。
            autoHideCard
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


    // 桌面悬浮歌词(经典悬浮窗)专属的一整套:窗口几何 + 配色与字体。
    //
    // 配色/字体放在这张卡里的依据:2026-08-05 全仓核对过消费方,确认字体和三个颜色确实只对
    // 这一种展示方式生效——mainFont/romanizationFont/translationFont 和 foregroundColor/
    // backgroundColor/textStrokeColor 的读取点全部落在 LyricsOverlayView.swift 一个文件里
    // (歌词窗口用固定的系统配色,菜单栏歌词是纯文字,都不读这些字段)。
    //
    // ⚠️ 2026-08-16 更正:这段原来把**灵动岛**也算进"都不读这些字段"里,现在不成立了 ——
    // 「跟随封面取色」(followsCoverArt)这一项被灵动岛读走了(NotchLyricsView.accentOrWhite),
    // 它是这张卡里唯一一个跨展示方式生效的开关。字体和那三个颜色仍然只对经典悬浮窗生效,
    // 所以这一项留在这张卡里、只在它自己的副标题上说明作用范围,不为它单开一张卡。
    //
    // 原来第一行是一条没有控件的"身份行"(图标 captions.bubble + 标题「桌面悬浮歌词」),
    // 跟正上方那张总开关卡的图标和标题**一模一样**、相隔 14pt 说了两遍。2026-08-10 把总开关
    // 按展示方式拆开之后,它当初存在的理由("不点名就跟上面那张卡分不清关系")已经失效,这次
    // 一并去掉;分组改由每张卡自己的组标题承担。
    //
    // 2026-08-14 从一张 13 行的巨型卡拆成五张。原来那张卡里"宽度(几何)/锁定位置(行为)/
    // 配色主题/字体/字号/三个颜色选择器/描边"平铺在一起,只靠分隔线隔开,读起来分不出层次;
    // 更糟的是自定义主题列表被 ForEach 插在"配色主题"和"字体"中间 —— **页面长度成了用户
    // 数据的函数**,每存一个主题,下面的字体/字号/颜色就整体往下掉一行。
    //
    // 拆完的顺序是"离预览条越近的越先出现":配色和字体是预览里当场看得见的,窗口几何看不
    // 太出来,重置放最后。
    private var classicOverlayCard: some View {
        Group {
            overlayColorCard
            overlayThemesCard
            overlayTextCard
            overlayWindowCard
            overlayResetCard
        }
    }

    // 配色。原来"配色主题"这个 Menu 里塞着「跟随封面」,而它根本不是一个配色,是"改用封面
    // 算出的动态色"这个模式本身 —— 结果是**只能开、不能关**:Menu 里没有"不跟随"这一项,
    // 唯一的退出路径是套用某个具体主题(连带覆盖四个颜色字段)。拆成一个独立开关之后,开关
    // 两个方向都走得通,Menu 也回归它本来的职责(选一套固定配色)。
    private var overlayColorCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("配色"))
            CardDivider()
            // 标题就把范围说清楚了:桌面悬浮歌词这边被接管的只有**文字颜色**
            // (PlaybackCoordinator.displayForegroundColor),背景色(LyricsOverlayView 的
            // overlayBackground)和描边色(.lyricsTextStroke)任何时候都无条件生效。
            //
            // ⚠️ 有一件事标题里装不下、副标题又已按用户要求去掉(2026-08-17):这个开关
            // **同时也管灵动岛**,那边歌词、歌名、进度条、播放指示条、控制按钮整套都跟着
            // 封面走(见 NotchLyricsView.accentOrWhite)。改这一项时记得它的影响不止这张卡。
            SettingsRow(
                icon: "photo.on.rectangle.angled",
                title: L10n.t("文字跟随封面")
            ) {
                Toggle("", isOn: $settings.followsCoverArt)
            }
            CardDivider()
            // 只打包"配色"相关的四个字段(文字/背景/描边颜色 + 描边开关),不含字体/字号 ——
            // 那是排版,跟配色是两回事,不该被同一个"主题"捆在一起改(见 ColorTheme.swift)。
            // 「跟随封面取色」开着时连这一行也收起来:预设主题的名字("经典黑字"/"经典白字")
            // 讲的就是文字颜色,而文字颜色已经被封面主色接管,留着只会让人以为选了有用。
            // 主题里的背景色/描边色确实还生效,但那两项本来就各有独立的一行可以单独调,
            // 不会因为收起这一行而够不着。
            if !settings.followsCoverArt {
            SettingsRow(icon: "swatchpalette", title: L10n.t("配色主题")) {
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
                .fixedSize()
            }
            }
            // 「跟随封面取色」开着时,文字颜色由封面主色接管,这一行就收起来 —— 它只剩
            // "拿不到封面主色时的兜底值"这一点残余作用,为它常占一行、还要配一句解释
            // 自己为什么半失效的副标题,不如干脆不显示。
            //
            // ⚠️ 这跟"展示方式的开关不再跟配置卡联动、关着也能配"不是一回事,别照那条推翻
            // 这里:那边是**没启用**某个形态时仍要让人能预先配好它;这里是某一项**已经被
            // 另一项接管**,显示出来只会让人以为改了有用。背景色和描边色不受接管(「文字
            // 跟随封面」这个名字里的"文字"两个字就是这个意思),所以照常显示。
            if !settings.followsCoverArt {
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
    }

    // 自定义主题独占一张卡。挪出配色卡是这次拆卡的主要目的之一(见 classicOverlayCard 上
    // 的注释:它原来夹在配色和字体中间,存几个主题就把页面撑长几行)。一个都没存过时整张卡
    // 只有"存为新主题"一行,不占地方。
    private var overlayThemesCard: some View {
        SettingsCard {
            SettingsRow(icon: "square.stack", title: L10n.t("我的配色主题")) {
                Button(L10n.t("存为新主题…")) {
                    newThemeName = ""
                    showSaveThemeAlert = true
                }
            }
            ForEach(settings.customColorThemes) { theme in
                CardDivider()
                SettingsSubRow(title: theme.name) {
                    HStack(spacing: 10) {
                        Button(L10n.t("套用")) { applyColorTheme(theme) }
                        // ⚠️ 删除必须二次确认。customColorThemes 的 didSet 立刻落盘、没有撤销,
                        // 而这一行的"套用"和"删除"两颗按钮挨着 —— 点错一次,用户自己调了半天
                        // 的配色就没了,且无从恢复。
                        Button {
                            themePendingDeletion = theme
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
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
            // 空名原来走 `guard !name.isEmpty else { return }` 静默丢弃:alert 已经关掉了,
            // 用户看不到任何反馈,只会以为"存了但没出现"。禁用按钮才是能看见的那种拒绝。
            .disabled(newThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(L10n.t("会把当前的文字颜色、背景颜色、描边颜色存成一个可以随时再套用的主题"))
        }
        .alert(
            L10n.t("删除这个配色主题？"),
            isPresented: Binding(
                get: { themePendingDeletion != nil },
                set: { if !$0 { themePendingDeletion = nil } }
            ),
            presenting: themePendingDeletion
        ) { theme in
            Button(L10n.t("删除"), role: .destructive) {
                settings.customColorThemes.removeAll { $0.id == theme.id }
                themePendingDeletion = nil
            }
            Button(L10n.t("取消"), role: .cancel) { themePendingDeletion = nil }
        } message: { theme in
            Text(String(format: L10n.t("「%@」删除后无法恢复"), theme.name))
        }
    }

    private var overlayTextCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("文字"))
            CardDivider()
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

    private var overlayWindowCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("窗口"))
            CardDivider()
            SettingsRow(icon: "arrow.left.and.right", title: L10n.t("宽度")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { settings.overlayWidth },
                        set: { newValue in
                            // 相等守卫:Slider 拖动中会按鼠标事件频率重复调 set,值经 step
                            // 量化后大量重复 —— @Published 是 willSet 语义,等值赋值照样
                            // 广播 objectWillChange 打醒所有观察 AppSettings 的界面,didSet
                            // 还会同步写一次 UserDefaults。下面两个宽度滑杆同款。
                            guard newValue != settings.overlayWidth else { return }
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
            // 手势不直观,说明放在 help 气泡里(原来副标题和 help 各写了一遍同一件事,
            // 副标题那句还更短更含糊)。怎么拖由下面那个「拖动前先长按」决定,这里不写死。
            SettingsRow(
                icon: "lock",
                title: L10n.t("锁定位置"),
                help: L10n.t("解锁后鼠标点击会穿到桌面上；拖动方式见下面「拖动前先长按」")
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
            // 紧挨着「锁定位置」放:它决定"解锁之后怎么拖"。
            //
            // 关掉(默认)= 按住歌词文字直接拖,四周空白照旧穿透 —— 靠的是 2026-08-23 那套
            // 精准歌词热区(lyricsHotZoneLocal)。打开 = 旧行为:窗口范围内长按 0.35s 才武装,
            // 期间点哪儿都能穿透。
            SettingsRow(
                icon: "hand.tap",
                title: L10n.t("拖动前先长按"),
                subtitle: L10n.t("关闭时按住歌词就能拖；打开则要长按 0.35 秒")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.overlayDragNeedsLongPress },
                    set: { settings.overlayDragNeedsLongPress = $0 }
                ))
            }
            CardDivider()
            // 紧挨着「锁定位置」放:两者解的是同一个痛点的两半 —— 那个让点击穿到下层,
            // 这个让视线看到下层。这张卡本身就在「窗口」标题下、整卡只讲悬浮歌词,不用
            // 在这一行里重复交代"只对悬浮歌词生效"(那句是给跨形态共用项准备的免责声明,
            // 这一项从不跨形态)。
            SettingsRow(
                icon: "cursorarrow.motionlines",
                title: L10n.t("划过让开"),
                subtitle: L10n.t("鼠标移到悬浮歌词上时它会淡下去，移开恢复")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.overlayFadeOnHover },
                    set: { newValue in
                        settings.overlayFadeOnHover = newValue
                        LyricsOverlayWindowController.shared.setFadeOnHover(newValue)
                    }
                ))
            }
        }
    }

    // 名字从"恢复默认外观"收窄成"恢复默认文字与配色":它重置七个字段,却**不碰**宽度和
    // 锁定位置。原来两者同在一张卡里,"外观"这个说法看着就像把整张卡都恢复了。补上副标题
    // 明说不含窗口项,比悄悄扩大重置范围安全 —— 扩大的话还得连带调 setWidth/setLocked,
    // 漏调就会变成"点了按钮但窗口纹丝不动"。
    private var overlayResetCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "arrow.uturn.backward",
                title: L10n.t("恢复默认文字与配色"),
                subtitle: L10n.t("不含宽度和锁定位置")
            ) {
                Button(L10n.t("恢复")) {
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
        }
    }

    // 灵动岛歌词专属。三项都只负责持久化,NotchLyricsView 每次渲染直接读,不需要连带调
    // 某个窗口控制器"生效"——唯一的例外是"宽度",它改的是窗口本身的几何。
    private var notchOverlayCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("灵动岛歌词"))
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
                            // 相等守卫,理由见悬浮歌词"宽度"滑杆同款注释。
                            guard newValue != settings.notchContentWidth else { return }
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
            // 「所有屏幕」2026-08-17 从下面一个独立的 Toggle 并进了这个下拉(用户要求)。
            // 它跟"选哪一块屏"本来就是同一个问题的几个互斥答案 —— 拆成"下拉 + 一个会把
            // 下拉整个禁用掉的开关"是把一个选择硬掰成了两个控件,还得额外写一句"开启后
            // 上面的指定屏幕不再起作用"来解释它们的关系。
            SettingsRow(
                icon: "display",
                title: L10n.t("显示在哪块屏幕"),
                help: L10n.t("「自动」选带刘海的那块；「所有屏幕」每块屏各显示一个；指定的屏幕拔掉后自动回到「自动」")
            ) {
                Picker("", selection: Binding<String>(
                    get: {
                        settings.notchAllScreens ? Self.allScreensTag : settings.notchScreenID
                    },
                    set: { newValue in
                        // 两个设置项还是各存各的(notchAllScreens 有自己的订阅方
                        // NotchMirrorManager),这里只是把它们合成一个选择呈现出来。
                        // 选具体屏幕时顺手把 allScreens 关掉,否则选了没反应。
                        settings.notchAllScreens = (newValue == Self.allScreensTag)
                        if newValue != Self.allScreensTag {
                            settings.notchScreenID = newValue
                        }
                        NotchLyricsWindowController.shared.applyScreenSetting()
                    }
                )) {
                    Text(L10n.t("自动")).tag("")
                    Text(L10n.t("所有屏幕")).tag(Self.allScreensTag)
                    Divider()
                    ForEach(availableScreens, id: \.self) { screen in
                        if let id = ScreenIdentity.id(of: screen) {
                            Text(screen.localizedName).tag(id)
                        }
                    }
                    // 存着的那块屏现在没接着时补一个占位项。Picker 的选中值如果在选项里
                    // 找不到对应 tag,整个控件会显示成空白——那看起来像设置丢了,而实际上
                    // 偏好还在、屏幕插回来就会恢复。
                    if !settings.notchAllScreens, !settings.notchScreenID.isEmpty,
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

    // 菜单栏歌词专属。
    //
    // 2026-08-16 删掉了「超宽时横向滚动」这个开关:超出宽度就滚是这里唯一合理的行为,
    // 关掉它只会得到一句被截断的歌词 —— 没人会主动要那个。少一个开关,少一份要跟着
    // 它变的文案(那一行原来的副标题和 help 都得写两套说辞)。
    private var menuBarCard: some View {
        SettingsCard {
            SettingsCardHeader(
                title: L10n.t("菜单栏歌词"),
                help: L10n.t("放不下的句子会横向滚动，鼠标悬停也能看到完整的这一行")
            )
            CardDivider()
            // 「宽度模式」摆在「显示宽度」上面:它决定下面那个宽度对短句意味着什么
            // (上限还是定值),先读到它再看宽度才讲得通。
            // 「自适应」打 Beta(2026-08-19 用户要求)。副标题**常显**、不只挂 hover:这是
            // 一条"选它可能不好用"的警告,藏在 tooltip 里等于没说(用户为面板上那个只在悬停
            // 才出现的「⋯」提示专门问过一次,教训记在这儿)。
            // 说明放「?」气泡而不是副标题(2026-08-19 用户要求改成 tip):这段话要讲清
            // "为什么不建议自适应",写成常显副标题会占两行、把这张卡撑高;而 Beta 标签本身
            // 已经在按钮上常显着,气泡只负责展开原因。
            SettingsSubRow(title: L10n.t("宽度模式"), help: L10n.t("只影响装得下的句子。\n\n固定：短句也占满设定宽度，右边留白，菜单栏上的位置不会变。\n\n自适应（不建议）：短句按自己的宽度占位，省下多余空间——代价是每换一句都要重建菜单栏这一项。系统只在项出生那一刻给邻居排位，重建太密时邻居图标会停在旧位置（错位、闪动），左键面板也可能被挤掉。想稳定就用固定。")) {
                Picker("", selection: $settings.menuBarLyricsWidthMode) {
                    Text(L10n.t("固定")).tag(MenuBarLyricsWidthMode.fixed)
                    Text(L10n.t("自适应（Beta）")).tag(MenuBarLyricsWidthMode.adaptive)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            // 两种模式的区别整段收进悬停说明,行上不再留副标题。help 挂在**整行**上而不是
            // 只挂 Picker:悬停标题那一侧同样该出提示,而不是非得压到那两个小分段上。
            // "只影响装得下的句子"这句原来是副标题,并进来了 —— 去掉副标题不等于丢掉这个
            // 范围限定,它恰恰是这一项最容易被误解的地方。
            CardDivider()
            SettingsSubRow(
                title: L10n.t("逐字染色"),
                help: L10n.t("跟着演唱进度把已唱到的部分染成系统强调色。只在这首歌有逐字时间轴时生效；打开菜单反白期间暂不染色")
            ) {
                Toggle("", isOn: $settings.menuBarLyricsKaraoke)
            }
            // 两个颜色项(2026-08-22 用户要的配置)。默认都"跟随系统",设过自定义色才出现
            // 「跟随系统」按钮 —— ColorPicker 自己表达不了"回到自动"这个状态,得有个显式
            // 出口,不然一旦点过颜色就再也回不去自适应了。
            CardDivider()
            SettingsSubRow(
                title: L10n.t("文字颜色"),
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
                    ), supportsOpacity: false) // 理由同悬浮窗文字颜色:允许透明容易把 alpha
                                               // 拖到 0,菜单栏歌词凭空消失且无从定位
                }
            }
            if settings.menuBarLyricsKaraoke {
                CardDivider()
                SettingsSubRow(
                    title: L10n.t("染色颜色"),
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
            CardDivider()
            SettingsSubRow(title: L10n.t("最大宽度")) {
                HStack(spacing: 8) {
                    // 按点(pt)而不是字数 —— 字符宽度差得太远,按字数控不住实际占宽,
                    // 见 AppSettings.menuBarLyricsWidth。
                    Slider(value: Binding(
                        get: { Double(settings.menuBarLyricsWidth) },
                        set: {
                            // 相等守卫,理由见悬浮歌词"宽度"滑杆同款注释。
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

    // 两个悬浮窗共用的隐藏开关。标题用"自动隐藏"而不是"共用设置":它描述的是这两个开关
    // 实际在做的事,不管当下开着的是一个还是两个悬浮窗都成立。
    private var autoHideCard: some View {
        SettingsCard {
            SettingsCardHeader(
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
            // ⚠️ 开着它,灵动岛暂停后是整个 orderOut,看不到"歌词行卷回顶行"那段收起动画
            // (窗口都没了)。关掉才看得到。这是设置本身的语义,不写进 UI —— 用户试一下就知道。
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
    @ObservedObject private var mediaControlHealth = MediaControlHealth.shared
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
    // 三态而不是 Bool —— 这张卡片的注释一直写着要展示"装了但没跑起来"这个中间态,
    // 但底层的 isRunning 以前根本区分不出来(见 LaunchdJobState)。
    @State private var collectorState: LaunchdJobState = .notRegistered
    @State private var isTogglingCollectorService = false
    // 2026-08-02 补上——之前点"启用"失败后,前台只会看到红叉+"未运行"跟从没点过一模
    // 一样,没有任何具体原因或下一步指引,用户卡在这里无计可施。只在"这次点了启用、结果
    // 没启动起来"时才为真,切走这个 tab 就清掉,不会把上一次失败的提示一直留着误导下一次
    // 操作。
    @State private var collectorEnableFailed = false
    // 「检测到未知播放器」那张卡的数据源。MediaControlClient 那份观察是普通静态变量、
    // 不是 @Published(它在 LyrimuseCore、每 2 秒轮询里顺手记的一笔,不该为了一张设置卡
    // 背上发布语义),所以这里自己按拍取一次。
    @State private var ungatedNowPlaying: MediaControlClient.UngatedNowPlaying?
    /// 通知授权是不是被拒了。系统**不会**把权限变化推给你,所以 onAppear 查一次、
    /// 回到前台再查一次(用户可能刚去系统设置里改过)。
    @State private var notificationsDenied = false

    var body: some View {
        SettingsPage(
            title: L10n.t("播放器"),
            subtitle: L10n.t("选择读取哪个 App 的播放状态")
        ) {
            playerCard
            unknownPlayerCard
            notificationDeniedCard
            trustedPlayersCard
            permissionCard
            collectorCard
            companionCard
        }
        .id(L10n.current)
        .onAppear { refreshUngatedNowPlaying(); refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationStatus()
        }
        // 2 秒一拍跟主轮询同频 —— 这里只是**读**一个已经被填好的静态变量,不起任何子进程
        // (记录那一笔挂在 LocalPlaybackSource 既有的 media-control 调用上,见
        // MediaControlClient.recordUngatedNowPlaying)。
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshUngatedNowPlaying()
        }
    }

    /// 取一次"系统此刻在报谁"。**带陈旧过滤**:播放停了之后那笔观察还挂在静态变量上,
    /// 不过滤的话卡片会一直挂着一个早就不放了的 App,用户点了信任却完全看不出效果。
    /// 15 秒 = 主轮询周期(2s)的七倍多,足够容忍一次卡顿,又不至于把停播后的残影留太久。
    private func refreshUngatedNowPlaying() {
        guard let seen = MediaControlClient.lastUngatedNowPlaying,
              Date().timeIntervalSince(seen.at) < 15 else {
            if ungatedNowPlaying != nil { ungatedNowPlaying = nil }
            return
        }
        if ungatedNowPlaying != seen { ungatedNowPlaying = seen }
    }

    private func refreshNotificationStatus() {
        Task {
            let denied = await UnknownPlayerNotifier.authorizationStatus() == .denied
            if notificationsDenied != denied { notificationsDenied = denied }
        }
    }

    // 2026-08-25 从纯文字 Picker 换成图标卡片网格——跟引导页"选择播放器"那一步换成
    // 同一套组件(PlayerChoiceCard,见 Settings/PlayerChoiceCard.swift),用户要求两处
    // 排版和谐一致。用 SettingsCardHeader + SettingsRawRow 而不是直接把网格摆在页面上:
    // 这页所有分组都是"卡片+发丝描边+统一内边距"的语言(见 SettingsDesignSystem.swift),
    // 网格如果裸摆会跟旁边"Arc"信任列表、"后台采集服务"这些卡片脱节。六个选项(五个
    // 播放器+自动识别)正好铺满 3 列 2 行,不需要引导页那张"陆续支持中"占位卡——这里
    // 不是第一印象页,不需要强调"还在长"这件事。
    private var playerCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("播放器"))
            SettingsRawRow {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(PlaybackPlayer.displayOrder) { player in
                        PlayerChoiceCard(player: player, isSelected: features.player == player) {
                            features.player = player
                            Task { await features.save() }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // 「检测到未知播放器」——「自动识别」不再限死内置那几个 App 的入口。
    //
    // 为什么是"发现 + 一键信任"而不是"一律接受":那道白名单不只挡显示,**也挡打卡**
    // (collector 的 poller.isTracked)。一律接受等于让 YouTube 视频、播客、网课被当成
    // 收听写进 Last.fm / ListenBrainz 的**永久历史**,还会往"设计上永不清理"的歌词缓存里
    // 灌垃圾条目。而靠内容形状分辨也不可靠 —— 浏览器里的网页播放器能用 MediaSession API
    // 自己填 title/artist/artwork,一个 YouTube 音乐视频跟一首歌长得一模一样。所以口径是
    // 用户显式同意:这里只负责把"系统正在报一个我们没见过的 App"这件事**如实告诉用户**,
    // 点不点由他定。详见 LyrimuseCore/TrustedPlayers。
    @ViewBuilder
    private var unknownPlayerCard: some View {
        // 只在「自动识别」下出现:选了具体播放器时,系统在报谁跟这个 App 无关,提示只是噪声。
        // 只提议"看起来像一首歌"的 —— 判据必须跟 TrustedPlayers.notASong 完全一致
        // (歌手名和专辑名都非空),否则会摆出一张"点了必定没反应"的卡片:YouTube 视频就是
        // artist 有(频道名)、album 空这个形状,信任之后照样会被那道守卫丢掉。
        // 判据下沉到 LyrimuseCore.UnknownPlayerAlert.shouldOffer(2026-08-22):通知那条路
        // 必须用**同一套**门槛,不然会出现「通知让你去信任,点进来这张卡却不在」。
        // 顺带修掉一个既有 bug:原来写的是裸 `!seen.album.isEmpty`,而 TrustedPlayers.notASong
        // 是 trim 后判空 —— album = " " 的播放能过这张卡、过不了那道守卫。
        if let seen = ungatedNowPlaying,
           UnknownPlayerAlert.shouldOffer(
               bundleID: seen.bundleID, artist: seen.artist, album: seen.album,
               observedAt: seen.at, isAutoDetect: features.player == .auto, now: Date(),
               isAccepted: { TrustedPlayers.isAccepted($0) }) {
            SettingsCard {
                SettingsRow(
                    icon: "questionmark.app.dashed",
                    title: FeatureSettingsStore.appDisplayName(forBundleID: seen.bundleID) ?? seen.bundleID,
                    subtitle: unknownPlayerSubtitle(seen),
                    help: L10n.t("信任之后它跟内置播放器完全同权:显示歌词，也会记进收听历史")
                ) {
                    Button(L10n.t("加入信任列表")) {
                        Task { await features.trust(bundleID: seen.bundleID) }
                    }
                }
            }
        }
    }

    /// 通知权限被拒时说出来。
    ///
    /// 用户 2026-08-22 明确选了「只做系统通知,不要菜单栏兜底」—— 权限被拒时这个功能会
    /// **完全静默**,而用户会把它理解成「它没检测到新播放器」。这一行是唯一能说清
    /// "不是没检测到,是通知被关了"的地方。只在真的 .denied 时出现,不占常态版面。
    @ViewBuilder
    private var notificationDeniedCard: some View {
        if features.player == .auto, notificationsDenied {
            SettingsCard {
                SettingsRow(
                    icon: "bell.slash",
                    title: L10n.t("检测到新的播放器"),
                    subtitle: L10n.t("系统通知已关闭，发现新播放器时不会主动提醒你"),
                    help: L10n.t("信任之后它跟内置播放器完全同权:显示歌词，也会记进收听历史")
                ) {
                    Button(L10n.t("打开系统设置")) {
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    /// 未知播放器卡的副标题:bundle id + 它此刻在放什么。放什么这件事很重要 —— 用户得靠它
    /// 判断"这是我的播放器"还是"某个网页视频"。
    private func unknownPlayerSubtitle(_ seen: MediaControlClient.UngatedNowPlaying) -> String {
        let what = [seen.artist, seen.title].filter { !$0.isEmpty }.joined(separator: " - ")
        if what.isEmpty { return seen.bundleID }
        return seen.bundleID + " · " + String(format: L10n.t("正在放：%@"), what)
    }

    @ViewBuilder
    private var trustedPlayersCard: some View {
        if !features.trustedPlayers.isEmpty {
            SettingsCard {
                // 2026-08-25 补标题:playerCard 换成图标网格之后有了自己的
                // SettingsCardHeader,紧跟着一张没有标题的卡在视觉上不成对,补一个让两张
                // 卡看起来是同一套设计语言里的姐妹卡。
                SettingsCardHeader(title: L10n.t("已信任的其它播放器"))
                // 按 bundle id 排序,别让列表顺序随 Dictionary 遍历顺序每次启动乱跳。
                ForEach(features.trustedPlayers.keys.sorted(), id: \.self) { bundleID in
                    if bundleID != features.trustedPlayers.keys.sorted().first { CardDivider() }
                    // 2026-08-25 图标从通用的"checkmark.seal"换成这个 App 自己的真图标
                    // (跟 playerCard 那套图标网格同一份取图标逻辑,AppIconResolver)——
                    // 一张卡里六个内置播放器都亮出真图标,紧接着这张卡却清一色一个通用
                    // 印章图标,两张卡放在一起会显得不搭。查不到(理论上不太可能:它刚被
                    // 检测到在跑,必然装着)才退回原来的印章图标,不留空白。
                    SettingsRow(
                        icon: "checkmark.seal",
                        iconImage: AppIconResolver.icon(forBundleID: bundleID),
                        title: displayNameForTrusted(bundleID),
                        subtitle: bundleID
                    ) {
                        Button(L10n.t("移除")) {
                            Task { await features.untrust(bundleID: bundleID) }
                        }
                    }
                }
            }
        }
    }

    /// 已信任项的显示名:优先用当初存下来的那份(collector 也用它当 ListenBrainz 标签),
    /// 空串(当初反查不到)时现查一次,还是查不到就退回 bundle id。
    private func displayNameForTrusted(_ bundleID: String) -> String {
        if let stored = features.trustedPlayers[bundleID], !stored.isEmpty { return stored }
        return FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
    }

    // 本地数据源现在通过 AppleScript 直接问 Music.app(见 MediaControlClient.swift),
    // 这个权限因此从"可选、只影响播放进度精度"变成"核心路径必需、没有就完全看不到
    // 歌词",副标题特意说清楚这一点,别让人以为不给也无所谓。
    //
    // QQ 音乐/网易云/Spotify 走系统级 MediaRemote,压根不需要这个权限,这张卡整个不出现。
    // ⚠️ 这里翻过一次:2026-08-02 曾经担心"卡片凭空消失会让人怀疑是不是坏了",改成显示
    // 一句"无需额外授权"的确认卡;2026-08-17 用户要求撤回 —— 一张只为了说"这里没事"而
    // 存在的卡片,本身就是噪声,而且它占的篇幅跟真正需要处理的那张一样大,反而稀释了
    // 页面上真正要人动手的内容。不需要就不显示。
    @ViewBuilder
    private var permissionCard: some View {
        if features.player == .appleMusic {
            SettingsCard {
                SettingsRow(
                    icon: automationStatusIconName,
                    iconTint: automationStatusIconColor,
                    title: L10n.t("Apple Music 自动化"),
                    // 副标题只留状态本身,"为什么需要它"挪进「?」——状态是每次扫一眼都要读的,
                    // 而理由只在第一次(或者犹豫要不要授权时)才需要,两者挤在一行里前者被拖长了。
                    subtitle: automationStatusCaption,
                    help: L10n.t("没有它读不到播放状态")
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
                // 同 permissionCard:副标题只留状态,职责说明进「?」。
                subtitle: collectorStatusCaption,
                help: L10n.t("读取播放状态、抓歌词和封面")
            ) {
                // 2026-08-10:这里原来是「启用/停用」双向按钮。停用入口去掉了 ——
                // 这个服务停掉之后 App 就是个空壳(读不到播放状态、不解析歌词、不写缓存),
                // 界面上每一处都不再更新,而用户很难把"什么都不动了"跟自己在设置里点过的
                // 一个按钮联系起来。它没有"用户可能想关掉它"的正当场景,不该出现在设置里。
                // 只保留没跑起来时的「启用」——那是个真的能救回来的动作。
                if isTogglingCollectorService {
                    ProgressView().controlSize(.small)
                } else if !collectorState.isRunning {
                    Button(L10n.t("启用")) { enableCollectorService() }
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
            // 私有通道自检失败时明说 —— 这条只影响 QQ 音乐/网易云(它们的播放信息全经
            // media-control 读),Apple Music/Spotify 走 AppleScript 不受影响。不显示成
            // 报错红字:用户无法修复它(只能等上游适配),说清受影响范围比制造焦虑有用。
            if case .unavailable(let message) = mediaControlHealth.state {
                CardDivider()
                SettingsNote {
                    Text(L10n.t("系统的媒体信息通道在这台机器上不可用，QQ 音乐 / 网易云音乐的播放检测会受影响（Apple Music、Spotify 不受影响）"))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        // ⚠️ 不能只在 onAppear 读一次(2026-08-21 用户报"怎么变成未知了")。
        //
        // 实际发生的事:collector 的 job 在 bootout→bootstrap 中途,`launchctl print` 会
        // 退出码 0 但输出里认不出 state 字段 → 解析成 .unknown(见 LaunchdPrintParser:
        // "我读不懂"跟"我知道它没跑"刻意分开两档)。而 build.sh 的重装顺序恰好制造这个窗口:
        // **先** kickstart App(设置窗口恢复、onAppear 读一次状态)、**再** reload collector
        // 的 job。于是这一次读正好落在中间态上,之后再没人重读,卡片就永久挂着一个橙色警告
        // 和一颗本不该出现的「启用」按钮 —— 而服务其实一直在跑。
        //
        // 修法是让它自愈:每拍重读一次(`launchctl print` 实测 4ms,只在这一页显示着时跑),
        // 外加切回 App 时重读一次(跟上面 permissionCard 的既有做法一致)。
        .onAppear { refreshCollectorState() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshCollectorState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCollectorState()
        }
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
                    ? L10n.t("跟随播放器启动")
                    : String(format: L10n.t("跟随 %@ 启动"), features.player.displayName),
                help: L10n.t("检测到播放器打开时自动拉起 Lyrimuse")
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
        switch collectorState {
        case .running:
            return L10n.t("运行中")
        case .registeredNotRunning(let code):
            // 装上了却没有进程 —— KeepAlive 的 job 落到这个状态基本就是起不来/崩溃重启
            // 循环。带上退出码,用户反馈时这一个数字就够定位了。
            if let code {
                return String(format: L10n.t("已安装但未运行（上次退出码 %d）"), code)
            }
            return L10n.t("已安装但未运行")
        case .unknown:
            return L10n.t("状态未知")
        case .notRegistered:
            return L10n.t("未运行")
        }
    }

    private var collectorStatusIconName: String {
        switch collectorState {
        case .running: return "checkmark.circle.fill"
        case .registeredNotRunning, .unknown: return "exclamationmark.triangle.fill"
        case .notRegistered: return "xmark.circle.fill"
        }
    }

    private var collectorStatusIconColor: Color {
        switch collectorState {
        case .running: return .green
        case .registeredNotRunning, .unknown: return .orange
        case .notRegistered: return .red
        }
    }

    /// 重读一次后台采集服务的真实状态。
    ///
    /// 只在真的变了时才赋值 —— 这是每 2 秒一拍的路径,而 collectorState 驱动整张卡片的
    /// 图标/文案/按钮;无条件赋值会让 SwiftUI 每拍重算一遍这张卡(值没变也算变化)。
    /// LaunchdJobState 是 Equatable,比较是零成本的。
    private func refreshCollectorState() {
        let latest = CollectorServiceManager.state
        if latest != collectorState { collectorState = latest }
    }

    private func enableCollectorService() {
        isTogglingCollectorService = true
        collectorEnableFailed = false
        Task {
            let state = await CollectorServiceManager.setEnabledAndWait(true)
            settings.collectorServiceEnabled = true
            collectorState = state
            isTogglingCollectorService = false
            // 只有这一个方向了(见上面按钮处的注释),没跑起来就是失败,直接标红给指引。
            collectorEnableFailed = !state.isRunning
        }
    }

    // 跟"关于"tab 里"导出诊断信息"按钮同一份实现(DiagnosticsExporter 是无状态的纯
    // 静态工具,两处各自调用即可,不需要抽共享 View)——常驻服务启用失败时给用户一个
    // 具体能做的事,而不是让红叉停在原地不知道下一步。
    private func exportDiagnostics() {
        DiagnosticsExporter.exportInteractively()
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    private func menuBarIconChoice(_ style: MenuBarIconStyle) -> some View {
        let selected = settings.menuBarIconStyle == style
        return Button {
            settings.menuBarIconStyle = style
        } label: {
            // .template 让它跟在菜单栏上一样只按 alpha 上色,而不是画出黑色本体 ——
            // 否则深色外观下这一格会是一团黑。
            Image(nsImage: MenuBarIconStyle.cachedImage(for: style))
                .renderingMode(.template)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 42, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(style.displayName)
        .accessibilityLabel(style.displayName)
    }

    @State private var showExportConfigWarning = false
    @State private var showImportConfigConfirm = false
    @State private var showICloudExportWarning = false
    // iCloud 文件夹里最新的那份配置(没有就是 nil)。只在 .onAppear 查一次 —— 这是文件
    // 系统状态,App 不会主动收到"iCloud 里多了个文件"的通知。
    @State private var iCloudSnapshot: ICloudConfigStore.Snapshot?
    @State private var iCloudBusy = false
    @State private var iCloudMessage: String?
    @State private var pendingImportData: Data?
    /// 待导入配置包**旁边**那份歌词归档(同名、-Config- 换成 -Lyrics-)。nil = 这份备份不带
    /// 歌词(老备份,或用户只导出了设置)—— 那就一个歌词文件都不许动,绝不能当成"空歌词库"
    /// 去清掉本机现有的。
    @State private var pendingImportLyrics: Data?
    /// 上面那份里有多少个歌词文件,只用于导入前那句确认文案报数(异步 peek 出来)。
    @State private var pendingImportLyricsCount = 0
    // 这次待确认的导入来自哪个**备份目录**。从任意文件选进来的那条路径是 nil ——
    // 那可能只是下载目录里的一份临时文件,不该因此把它当成今后的备份落点。
    @State private var pendingImportFolder: URL?
    @State private var showClearConfigWarning = false

    var body: some View {
        SettingsPage(
            title: L10n.t("通用"),
            subtitle: L10n.t("语言、启动方式、菜单栏和 Dock 图标，以及把全部设置搬到另一台 Mac")
        ) {
            // 2026-08-17 这一页从"两张无标题的卡"改成四张带小标题的卡。原来五项挤在同一张
            // 卡里,其实是两类东西:语言/开机启动讲的是这个 App 怎么跑,Dock/菜单栏图标讲的
            // 是它在系统 UI 里怎么露面 —— 中间只有一条分隔线,读起来是一串杂项。而且 12 款
            // 图标那个网格夹在正中间,视觉上本来就已经把那张卡切成了上下两半。
            //
            // 另外:这一页原来是全 App 唯一两张卡都没有 SettingsCardHeader 的分类(其它页
            // 都有:歌词来源/配色/文字/窗口/灵动岛歌词/菜单栏歌词/自动隐藏)。
            SettingsCard {
                SettingsCardHeader(title: L10n.t("语言与启动"))
                CardDivider()
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
            }

            // 这张卡讲的是同一件事的两面:这个 App 在系统 UI 里以什么形态露面 —— Dock 里
            // 有没有图标、菜单栏那枚长什么样、动不动。三项互相有关,跟上面的语言/开机启动
            // 没关系,所以分开成卡而不是继续接在同一张里。
            SettingsCard {
                SettingsCardHeader(title: L10n.t("菜单栏与 Dock"))
                CardDivider()
                SettingsRow(
                    icon: "macwindow",
                    title: L10n.t("在 Dock 中显示"),
                    help: L10n.t("关闭后只保留菜单栏图标，不占 Dock 位置")
                ) {
                    Toggle("", isOn: $settings.showInDock)
                }
                CardDivider()
                // 放在「在 Dock 中显示」后面而不是「菜单栏歌词」那张卡里:这个图标恰恰是
                // **没有**歌词可显示时才出现的(没在放歌、还没解析出这一句、或者菜单栏歌词
                // 整个关掉),跟那边的宽度/滚动设置一件都不沾。它跟上面这一行才是同类 ——
                // 都在说"这个 App 在系统 UI 里长什么样"(2026-08-17 用户指出)。
                SettingsRow(
                    icon: "menubar.rectangle",
                    title: L10n.t("菜单栏图标")
                ) { EmptyView() }
                SettingsRawRow(insetToText: true) {
                    // 直接把图标本身摆出来让人挑,不用文字列表 —— 这一项的全部内容就是
                    // "长什么样",写成一串名字反而要人先在脑子里翻译一遍。
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 46), spacing: 6, alignment: .leading)],
                        alignment: .leading, spacing: 6
                    ) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            menuBarIconChoice(style)
                        }
                    }
                }
                CardDivider()
                SettingsRow(
                    icon: "figure.dance",
                    title: L10n.t("随播放律动"),
                    help: L10n.t("播放时图标动起来，暂停即静止")
                ) {
                    Toggle("", isOn: $settings.menuBarIconAnimates)
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
                SettingsCardHeader(title: L10n.t("设置备份"))
                CardDivider()
                // 换电脑用的快捷通道:一键存到 iCloud Drive 的 Lyrimuse 文件夹、在新机器上
                // 一键读回来。下面的"导出…/导入…"仍然保留 —— 那是通用的存文件路径(存到
                // U 盘、发给自己、放进别的网盘),不是所有人都用 iCloud。
                //
                // 用户没开 iCloud Drive 时整行不显示,而不是留一个点了必然失败的按钮。
                if ICloudConfigStore.isAvailable {
                    SettingsRow(
                        // 用户把备份挪到别处之后,再叫"iCloud 备份"就是错的。图标一起换:
                        // 云 vs 文件夹,一眼能看出这份备份现在落在哪一类地方。
                        icon: ICloudConfigStore.usingCustomFolder ? "folder" : "icloud",
                        title: ICloudConfigStore.usingCustomFolder
                            ? L10n.t("备份文件夹") : L10n.t("iCloud 备份"),
                        subtitle: iCloudSubtitle
                    ) {
                        HStack(spacing: 8) {
                            if iCloudBusy { ProgressView().controlSize(.small) }
                            // 已经存过一份的话这个动作是覆盖式地再存一份新的,叫"存到
                            // iCloud"读起来像还没存过。副标题那行同时在显示现有那份是
                            // 什么时候的,两处合起来才说得通。
                            Button(iCloudSnapshot == nil
                                ? (ICloudConfigStore.usingCustomFolder
                                    ? L10n.t("存一份") : L10n.t("存到 iCloud"))
                                : L10n.t("更新备份"))
                            {
                                showICloudExportWarning = true
                            }
                            if iCloudSnapshot != nil {
                                Button(L10n.t("导入…")) { importFromICloud() }
                            }
                            // 换文件夹这类低频动作收进省略号菜单,不跟上面两个常用按钮抢
                            // 这一行本来就不宽的横向空间。
                            Menu {
                                Button(L10n.t("更换备份文件夹…")) { chooseBackupFolder() }
                                if ICloudConfigStore.usingCustomFolder {
                                    Button(L10n.t("改回 iCloud")) {
                                        ICloudConfigStore.setCustomFolder(nil)
                                        iCloudSnapshot = ICloudConfigStore.latestSnapshot()
                                    }
                                }
                                Divider()
                                Button(L10n.t("在访达中显示")) {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [ICloudConfigStore.preparedFolderURL()])
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    if let iCloudMessage {
                        CardDivider()
                        SettingsNote { Text(iCloudMessage) }
                    }
                    CardDivider()
                }
                SettingsRow(
                    icon: "square.and.arrow.up",
                    title: L10n.t("导出设置"),
                    help: L10n.t("文件里包含账号登录凭证和密钥，妥善保管，不要发给别人")
                ) {
                    Button(L10n.t("导出…")) { showExportConfigWarning = true }
                }
                CardDivider()
                SettingsRow(
                    icon: "square.and.arrow.down",
                    title: L10n.t("导入设置"),
                    help: L10n.t("会覆盖当前所有设置，包括已连接的账号和播放数据发往的地址，并立即重启 Lyrimuse")
                ) {
                    Button(L10n.t("导入…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowedContentTypes = [.json]
                        panel.prompt = L10n.t("导入")
                        if ICloudConfigStore.isAvailable {
                            panel.directoryURL = ICloudConfigStore.folderURL
                        }
                        if panel.runModal() == .OK, let url = panel.url,
                           let data = try? Data(contentsOf: url) {
                            pendingImportData = data
                            pendingImportFolder = nil
                            // 同目录下的兄弟歌词包(同名、-Config- 换成 -Lyrics-)。没有就是
                            // 一份老备份或用户只想恢复设置 —— 那就什么都不动,绝不能当成
                            // "空歌词库"去清掉本机现有的。
                            let sidecar = url.deletingLastPathComponent().appendingPathComponent(
                                LyricsBackupArchive.sidecarName(forConfigName: url.lastPathComponent))
                            pendingImportLyrics = try? Data(contentsOf: sidecar)
                            pendingImportLyricsCount = 0
                            showImportConfigConfirm = true
                            if let lyrics = pendingImportLyrics {
                                Task { @MainActor in
                                    pendingImportLyricsCount = await LyricsBackupStore.peek(lyrics)?.files ?? 0
                                }
                            }
                        }
                    }
                }
                CardDivider()
                // 给拿 dotfiles/chezmoi 管机器的人用:这个 App 的配置本来就是
                // ~/.config 下的纯文本 JSON,直接纳入版本管理就行,不必走导出。
                // 副标题必须点明"外观和快捷键不在里面"—— 它们在 UserDefaults,
                // 只拷这个文件夹会静默丢掉,这是这条路子最容易踩的坑。
                SettingsRow(
                    icon: "folder",
                    title: L10n.t("配置文件夹"),
                    help: L10n.t("整份配置都在这里，纯文本可直接编辑；里面含账号凭据，不要发给别人")
                ) {
                    Button(L10n.t("在访达中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigPortability.configFolderURL])
                    }
                }
            }
            .onAppear { iCloudSnapshot = ICloudConfigStore.latestSnapshot() }
            .alert(L10n.t("确定要存到 iCloud 吗？"), isPresented: $showICloudExportWarning) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("存到 iCloud")) {
                    // Task 包一层:歌词归档要读几千个文件 + 压缩,不能卡在 alert 的按钮里
                    // (buildArchive 内部已经把重活扔进 detached task,这里只是别同步等)。
                    Task { @MainActor in
                        guard let data = ConfigPortability.buildExportData() else { return }
                        let name = ConfigPortability.suggestedFilename()
                        guard ICloudConfigStore.write(data, filename: name) != nil else {
                            iCloudMessage = L10n.t("写入 iCloud 失败，可以改用下面的「导出…」存成文件")
                            return
                        }
                        // 歌词库单独一份 sidecar(同名同时间戳,只把 -Config- 换成 -Lyrics-)。
                        // 失败**不算整体失败**:配置已经存好了,歌词那份下次再存就行,所以
                        // 只在下面那行小字里如实说一句。
                        var note: String?
                        if let archive = await LyricsBackupStore.buildArchive() {
                            let lyricsName = LyricsBackupArchive.sidecarName(forConfigName: name)
                            if ICloudConfigStore.write(archive, filename: lyricsName) == nil {
                                note = L10n.t("设置已存好，但歌词库那一份没写成功")
                            }
                        }
                        // 不弹"已存好"——副标题会立刻换成刚写进去那份的时间,按钮也从
                        // "存到 iCloud"变成"更新",反馈已经在界面上了。
                        iCloudSnapshot = ICloudConfigStore.latestSnapshot()
                        iCloudMessage = note
                    }
                }
            }
            .alert(L10n.t("确定要导出设置吗？"), isPresented: $showExportConfigWarning) {
                Button(L10n.t("取消"), role: .cancel) {}
                Button(L10n.t("继续导出")) {
                    guard let data = ConfigPortability.buildExportData() else { return }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = ConfigPortability.suggestedFilename()
                    // 默认落点改成 iCloud Drive 里的 Lyrimuse 文件夹(没开 iCloud 就退回
                    // 桌面)—— 换电脑是这个按钮唯一的用途,而新机器能自动找到的就是这个
                    // 文件夹。用户仍然可以在面板里改到任何地方。
                    panel.directoryURL = ICloudConfigStore.isAvailable
                        ? ICloudConfigStore.preparedFolderURL()
                        : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                    if panel.runModal() == .OK, let url = panel.url {
                        // 导出包里带着全部凭据(上面那句警告文案说的就是它)。
                        try? data.writeSecurely(to: url)
                        // 歌词库那份写在**紧邻的同名文件**旁边 —— 导入时就是靠这个位置关系
                        // 找到它的(NSSavePanel 只能给一个落点,所以是"兄弟文件"而不是两次面板)。
                        Task { @MainActor in
                            guard let archive = await LyricsBackupStore.buildArchive() else { return }
                            let sidecar = url.deletingLastPathComponent().appendingPathComponent(
                                LyricsBackupArchive.sidecarName(forConfigName: url.lastPathComponent))
                            try? archive.writeSecurely(to: sidecar)
                        }
                    }
                }
            } message: {
                Text(L10n.t("导出的文件包含账号登录凭证和密钥，妥善保管，不要发给别人"))
            }
            .alert(L10n.t("确定要导入这份设置吗？"), isPresented: $showImportConfigConfirm) {
                Button(L10n.t("取消"), role: .cancel) {}
                // Task 包一层:importData 现在要等 collector 重新读到新配置才返回(见那边
                // 的注释),而 restartApp() 必须排在它后面 —— 一旦 terminate,没跑完的
                // launchctl 操作就跟着进程一起没了。
                Button(L10n.t("导入并重启"), role: .destructive) {
                    if let data = pendingImportData {
                        Task { @MainActor in
                            await ConfigPortability.importData(data)
                            // ⚠️ 歌词必须排在 importData **之后**:歌词目录是
                            // features.lyricsDir(用户可自定义的绝对路径),而那个文件正是
                            // importData 刚写的 —— 先铺后导会铺到旧机器那个目录里去。
                            if let lyrics = pendingImportLyrics {
                                await LyricsBackupStore.restore(from: lyrics)
                            }
                            // 必须排在 importData 之后:备份目录这个键在导入排除表里、
                            // 不会被导入的包覆盖,但顺序反了会先被写、再被这一句改回来。
                            if let folder = pendingImportFolder {
                                ICloudConfigStore.adoptFolder(folder)
                            }
                            ConfigPortability.restartApp()
                        }
                    }
                }
            } message: {
                // 歌词那句只在真有 sidecar 时才加 —— 没有的时候提一句"不含歌词"只会让人
                // 以为哪里出错了。两句都是完整句子,不在运行时拼半句。
                if pendingImportLyrics != nil {
                    Text(String(format: L10n.t("这会覆盖当前所有设置，包括已连接的账号和播放数据发往的地址；同一份备份里的 %@ 个歌词文件也会一并恢复（同名的会被覆盖）。完成后立即重启 Lyrimuse 使其生效"),
                                "\(pendingImportLyricsCount)"))
                } else {
                    Text(L10n.t("这会覆盖当前所有设置，包括已连接的账号和播放数据发往的地址，并立即重启 Lyrimuse 使其生效"))
                }
            }

            // 单独一张卡,不跟上面的备份/恢复挤在一起 —— 这是本页唯一不可撤销的动作,而它
            // 原来紧贴在「配置文件夹」下面、只隔一条分隔线。「歌词显示」页的「恢复默认文字与
            // 配色」就是这么单独放的,同类动作按同一套处理。
            SettingsCard {
                SettingsRow(
                    icon: "trash",
                    title: L10n.t("清除所有设置"),
                    subtitle: L10n.t("只抹掉本机设置，无法撤销；iCloud 和已导出的备份不受影响")
                ) {
                    DestructiveButton(title: L10n.t("清除…")) { showClearConfigWarning = true }
                }
            }
            // 这条 alert 跟着按钮一起搬过来。留在上面那张卡上也能弹(alert 由 @State 驱动,
            // 锚点只要还在层级里就行),但按钮和它的确认框分居两张卡纯属给人添乱。
            .alert(L10n.t("确定要清除所有设置吗？"), isPresented: $showClearConfigWarning) {
                Button(L10n.t("取消"), role: .cancel) {}
                // 同上:clearAllConfig 现在要等常驻服务真的卸载完才返回,不能在它之前 terminate。
                Button(L10n.t("清除并重启"), role: .destructive) {
                    Task { @MainActor in
                        await ConfigPortability.clearAllConfig()
                        ConfigPortability.restartApp()
                    }
                }
            } message: {
                Text(L10n.t("这会清除本机所有账号 token、密钥和个人设置，恢复到刚装完时的样子（下次启动会重新走一遍引导向导），且无法撤销。iCloud 里那份备份和已经导出的文件都不受影响；两样都没有的话，建议先备份一份"))
            }
        }
        .id(L10n.current)
    }

    /// iCloud 那一行的副标题:有配置就说清是哪一份(时间 + 哪台机器写的),没有就说还没存过。
    private var iCloudSubtitle: String {
        guard let snap = iCloudSnapshot else {
            // 还没存过时这行是这一栏唯一的说明,所以要说清楚存了有什么用。自选了文件夹
            // 的话改成报位置 —— 那时"换 Mac 时读回来"能不能成立取决于用户挑的是不是一个
            // 会同步的目录,不该由我们替他打这个包票。
            guard ICloudConfigStore.usingCustomFolder else {
                return L10n.t("存一份到 iCloud，换 Mac 时直接读回来")
            }
            return String(format: L10n.t("备份到「%@」，还没存过"), ICloudConfigStore.folderURL.lastPathComponent)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let when = formatter.string(from: snap.exportedAt ?? snap.modifiedAt)
        let base: String
        if let device = snap.deviceName, !device.isEmpty {
            base = String(format: L10n.t("%1$@ · 来自 %2$@"), when, device)
        } else {
            base = when
        }
        // 自选文件夹时把落点也报出来 —— 否则用户看到一个时间戳,却不知道它指的是哪个目录
        // 里的那份(尤其是在两台机器指了不同目录的时候)。
        guard ICloudConfigStore.usingCustomFolder else { return base }
        return base + " · " + ICloudConfigStore.folderURL.lastPathComponent
    }

    /// 让用户挑一个目录当备份落点 —— Dropbox / 坚果云 / OneDrive / Syncthing / 一个 git
    /// 工作副本都行,我们只管往里写文件,同步是那个目录自己的事(见 ICloudConfigStore)。
    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("选择")
        panel.message = L10n.t("选一个会自动同步的文件夹（Dropbox、坚果云、OneDrive 等），换 Mac 时在那台机器上指向同一个文件夹即可")
        panel.directoryURL = ICloudConfigStore.preparedFolderURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ICloudConfigStore.setCustomFolder(url)
        // 换了目录,原来那份快照的信息就不成立了,立刻按新目录重新探测一次。
        iCloudSnapshot = ICloudConfigStore.latestSnapshot()
        iCloudMessage = nil
    }

    private func importFromICloud() {
        guard let snap = iCloudSnapshot else { return }
        iCloudBusy = true
        iCloudMessage = nil
        Task {
            // 新机器上这份文件很可能还只是个未下载的占位符,readOutcome 会先触发下载再等
            // 它到位。分档提示:超时那档下载是**真的已经在跑**了,叫用户再点一次才有意义;
            // 而"连下载都没发起"是另一回事,不能也让他干等(2026-08-24 用户报的就是这两种
            // 被压成同一句话,病根见 ICloudFileReadiness)。
            let outcome = await ICloudConfigStore.readOutcome(snap.url)
            iCloudBusy = false
            let data: Data
            switch outcome {
            case .data(let d):
                data = d
            case .downloading:
                iCloudMessage = L10n.t("正在从 iCloud 下载这份备份，下载完再点一次「导入」")
                return
            case .unavailable:
                iCloudMessage = L10n.t("读不到这份备份：可能没开 iCloud Drive，或者这个文件夹不在同步")
                return
            }
            pendingImportData = data
            pendingImportFolder = snap.folderURL
            // 兄弟歌词包也要从 iCloud 拉一次(它可能同样还是个未下载的占位符)。**失败不
            // 阻断**:配置照样能导,歌词那份下次再说 —— 6 MB 的下载不该拦住"换机器"这件事。
            let sidecarURL = snap.url.deletingLastPathComponent().appendingPathComponent(
                LyricsBackupArchive.sidecarName(forConfigName: snap.url.lastPathComponent))
            pendingImportLyrics = await ICloudConfigStore.read(sidecarURL)
            pendingImportLyricsCount = 0
            if let lyrics = pendingImportLyrics {
                pendingImportLyricsCount = await LyricsBackupStore.peek(lyrics)?.files ?? 0
            }
            showImportConfigConfirm = true
        }
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
    // 只为这两个更新开关订阅 —— 这一页其余内容都是静态的。
    @ObservedObject private var updater = SparkleUpdaterManager.shared
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
                + L10n.t("Lyric × Muse——把你的歌词交给音乐女神吧"),
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
                SettingsSubRow(title: L10n.t("自动检查")) {
                    Toggle("", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsSubRow(
                    title: L10n.t("自动下载并安装")
                ) {
                    Toggle("", isOn: Binding(
                        get: { updater.automaticallyDownloadsUpdates },
                        set: { updater.automaticallyDownloadsUpdates = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    // 关掉自动检查后这一项在 Sparkle 那边根本不会被读到,置灰而不是藏起来
                    // —— 藏起来会让人以为设置项没了。
                    .disabled(!updater.automaticallyChecksForUpdates)
                }
                CardDivider()
                // 这一行的副标题是唯一一处"求 star"的地方,所以用常显 subtitle 而不是
                // help 气泡 —— 藏进悬停提示就没人会看到了。语气刻意跟同一页的"请作者喝杯
                // 咖啡"呼应,自嘲而不是撒娇,跟这个 App 其余克制的文案调子还搭得上。
                SettingsRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: L10n.t("GitHub 仓库"),
                    subtitle: L10n.t("开源免费，觉得顺手就点颗 ⭐")
                ) {
                    Button(L10n.t("打开")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse")!)
                    }
                }
                CardDivider()
                SettingsRow(icon: "exclamationmark.bubble", title: L10n.t("反馈问题")) {
                    Button(L10n.t("前往")) {
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
                        DiagnosticsExporter.exportInteractively()
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


/// 设置窗口的 NSWindow 收尾配置:让它能被拖大、能最小化。
///
/// SwiftUI 给 Settings scene 的 styleMask 里**没有** .resizable(实测 32771 =
/// titled | closable | fullSizeContentView),所以这个窗口原本一格也拉不动,SettingsView
/// 上声明的 idealHeight 只决定它开出来多大。而「歌词显示」页顶上钉着 205pt 的固定头部,
/// 窗口拉不高的话滚动区就一直很憋屈。
///
/// 同一个 32771 里也没有 .miniaturizable —— 黄灯是灰的,点不动(2026-08-17 用户问)。
/// 那是苹果给 Settings scene 定的默认,系统「设置」自己也这样;但这一页很长、内容也不是
/// "改完就关"的一次性面板(Last.fm 统计、歌词管理入口都在里面),留着能收起来更顺手,
/// 所以一并开了。收起来之后跟普通窗口一样在 Dock 右侧那段可以点回来,不受这个 App
/// 是否显示 Dock 图标影响。
///
/// ⚠️ scene 修饰符 .windowResizability(.contentMinSize) 对 Settings scene 无效
/// (实测加上之后 styleMask 纹丝不动),只能在 NSWindow 这一层开。缩放下限仍由
/// SettingsView 上声明的 minWidth/minHeight 兜着。
///
/// ⚠️ 这里**只**动 styleMask。2026-08-15 排查"设置窗口拖不到另一块屏"时,曾顺手把
/// collectionBehavior 的 .auxiliary 改成 .primary、.fullScreenNone 改成
/// .fullScreenPrimary,还开了 isMovableByWindowBackground —— 后来查明那个问题跟这个窗口
/// 毫无关系(用户那块屏当时有 App 处于全屏,全屏 Space 本来就不接受任何窗口拖入,换别的
/// App 一样进不去),那几项改动因此全部撤回。留着不痛不痒的改动等于给后来的人埋假线索:
/// 它们看着像是在解决某个问题,其实什么问题都没解决。
struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 视图刚建好时还没挂进窗口,拿不到 window,推迟到下一个 runloop。
        DispatchQueue.main.async {
            view.window?.styleMask.insert([.resizable, .miniaturizable])
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
