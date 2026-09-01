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
    /// 「手动选定歌词后锁定」开关翻面后追溯处理了多少首 —— 这个开关是整页唯一一个
    /// **会去改歌词缓存**的开关(其余全是纯显示偏好),不给回执的话它看起来跟没生效一样。
    @State private var manualPickLockNotice: String?
    /// 回执的世代号,只为了让旧的自动收回计时器别抹掉新回执(见 showManualPickLockNotice)。
    @State private var manualPickLockNoticeToken = 0
    /// 扫描/落盘/重启 collector 期间为真 —— 这一段是秒级的(要读整份缓存再写回),
    /// 没有进行中状态的话开关翻完到回执出现之间就是一段"点了没反应"的空窗。
    @State private var manualPickLockBusy = false
    /// 关掉开关时,可以一并解开的歌数(确认框要显示它)。
    @State private var pendingManualUnlockCount = 0
    @State private var showManualPickUnlockConfirm = false
    /// 鼠标悬在哪个来源上(只为悬停底色,不影响任何配置)。
    @State private var hoveredSource: String?
    /// 鼠标悬在哪个来源**整行**上(2026-08-31,跟上面 hoveredSource 是两件独立的事)——
    /// hoveredSource 现在只覆盖 sourceCheckbox 自己紧贴内容的那一小块(圆点+文字),跟
    /// 测试小图标(sourceTestAccessory)之间隔着一段 Spacer 空白;用户实机反馈"鼠标放在
    /// 复选框上才显示测试按钮,移过去的路上就消失了"——正是这段空白:途中既不在
    /// sourceCheckbox 的悬停范围内,也还没进测试小图标自己的 16×16 命中区,两个悬停信号
    /// 在这段空白里同时是 false。这个状态覆盖复选框+空白+测试图标整行,专门只用来
    /// 决定"这一行的测试图标要不要露出来",跟 hoveredSource 驱动的复选框高底色/`.help`
    /// 提示是两件不同的事,不合并。
    @State private var hoveredRow: LyricsSource?

    // MARK: - 歌词来源可用性测试(2026-08-30)

    /// 每个来源的测试状态,只在这次设置窗口的会话里有效——不持久化,重开设置就回到
    /// 「还没测过」,这本来就是一次性诊断动作,不是需要记住的偏好。
    private enum LyricSourceTestState: Equatable {
        case testing
        case result(status: LyricSourceTestService.Status, detail: String)
    }
    @State private var sourceTestStates: [LyricsSource: LyricSourceTestState] = [:]
    /// 「全部测试」和任意一个单独的「测试」按钮共用同一个 collector 子进程槙位
    /// (LyricSourceTestService 是单例,新一轮会 `cancelRunning()` 杀掉上一轮)。
    ///
    /// ⚠️ 2026-08-31 用户明确要求:标题行的「测试」(全部)**不能**被单个来源的测试锁住
    /// ——不管有没有单个测试在跑,右上角那颗按钮永远可以点、永远会正常触发"测全部"。
    /// 只有单个来源的测试按钮之间互相排队(靠下面 isTestingLyricSources 置灰),避免
    /// 用户连点几个不同来源的测试按钮时,自己发起的几轮互相杀来杀去、结果满屏"失败"。
    /// 所以 `testAllSources()` **不**守卫 `isTestingLyricSources`,随时可以点、随时会
    /// 取代正在跑的任何一轮(哪怕那一轮是另一颗单独的测试按钮发起的)。
    ///
    /// `lyricSourceTestGeneration` 是为了正确处理"取代"这件事:testAllSources 取代一个
    /// 正在跑的单个测试时,被取代那一轮的 collector 子进程会被杀掉、它的 `await` 会抛错,
    /// 它自己的收尾逻辑(把 isTestingLyricSources 置回 false)如果无条件执行,会踩在
    /// **新**这一轮刚设成 true 的状态上——每次发起测试先把这个代数加一,只有自己仍是
    /// "当前最新一轮"时,收尾才会真的改 isTestingLyricSources/写入"失败"结果;被取代的
    /// 那一轮的收尾发现代数已经变了,直接放弃,不覆盖新一轮的状态。
    @State private var isTestingLyricSources = false
    @State private var lyricSourceTestGeneration = 0

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
            SettingsCardHeader(title: L10n.t("歌词来源")) { testAllSourcesButton }
            CardDivider()
            // 固定 4 列的网格,不再用 WrapLayout 按可用宽度贪心折行 —— 折行位置这件事此前
            // 完全由译文长度决定:"网易云音乐"5 个字、英文界面下是 "NetEase Cloud Music"
            // 20 个字符,同一张卡在两种语言下折行结果从两行变成三行,布局"变来变去"。
            // 2026-08-26 改成固定列数(用户挑了 4 列):行数只取决于「来源数 ÷ 4」,跟语言、
            // 译文长短完全无关 —— 折行这件事从设计上被消除了,以后加新源最多只多一行。
            // 单格文字太长会被 sourceCheckbox 内部的 .lineLimit(1) 截断、hover 出完整名字
            // (.help),不会像 WrapLayout 那样把整张卡的折行结构带歪。
            SettingsRawRow(insetToText: true) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                    alignment: .leading, spacing: 4
                ) {
                    ForEach(LyricsSource.allCases) { source in
                        // 测试按钮/结果状态放在每一格尾部(2026-08-30)。
                        //
                        // ⚠️ 2026-08-31 用户实机反馈"点这个 hover 按钮没有反应"——第一版
                        // 用 `.overlay(alignment: .trailing)` 把测试小图标叠在
                        // sourceCheckbox 那个铺满整格的开关 Button 上面,想靠
                        // `.highPriorityGesture` 让点击优先分给小图标,实测**仍然没用**:
                        // 悬停走 NSTrackingArea,两个叠在一起的区域各自独立、互不冲突,
                        // 但点击是两个 Button 在抢同一次 mouseDown,这层竞争发生在
                        // AppKit 的 hit-test 阶段,SwiftUI 手势优先级(`.highPriorityGesture`)
                        // 根本没有机会介入——它只能调解 SwiftUI **自己**的手势系统内部的
                        // 优先级,管不到"外层这个 Button 本身的 mouseDown 直接被 AppKit
                        // 判给了它自己"。真正的修法是让两个控件在布局上就不重叠、变成平级
                        // 兄弟节点(HStack + Spacer),而不是想办法在重叠状态下调解优先级——
                        // sourceCheckbox 相应地不再自己占满整格宽度(见该函数改动),这里的
                        // HStack 补上"占满整格"的职责,Spacer 把测试小图标推到真正的尾部。
                        HStack(spacing: 4) {
                            sourceCheckbox(source)
                            Spacer(minLength: 0)
                            sourceTestAccessory(source)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // ⚠️ 2026-08-31 用户实机反馈"鼠标放在复选框上才显示测试按钮,移过去
                        // 的路上就消失了"——sourceCheckbox 自己的悬停范围现在紧贴内容(不再
                        // 占满整格,见上面那段改动注释),跟测试小图标之间隔着 Spacer 撑出来
                        // 的一段空白,途中两边的悬停信号都不成立。这里在整行(复选框+空白+
                        // 图标)上补一层独立的悬停追踪,专门喂给 hoveredRow——只用来决定
                        // 测试图标要不要露出来,跟 sourceCheckbox 自己那层驱动高亮底色/
                        // `.help` 的悬停信号(hoveredSource)是两件不同的事,不合并。
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveredRow = hovering ? source : (hoveredRow == source ? nil : hoveredRow)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
            CardDivider()
            // 2026-09-01 用户要求把「采纳候选要不要顺带锁定这首歌」的决定权交出来——见
            // LyricsManagerView / LyricsQuickSearchWindow / LyricsWindowView **三处**
            // 「采纳候选」调用点的 markManual 参数注释(grep `LyricsSearchSheet(` 数得到,
            // 改一处就要三处一起改)。默认关,纯本地 UI 偏好,不需要 collector 知道,存进
            // AppSettings 而不是 FeatureSettingsStore。
            //
            // ⚠️ 这是整个设置页唯一一个**会去改歌词缓存**的开关(其余全是显示偏好):翻面时
            // 要追溯处理存量(见下面 Toggle 的 setter)。追溯逻辑刻意留在这里而不是
            // AppSettings 的 didSet —— 它需要弹确认框、需要给回执,那是 View 的事;而且
            // didSet 会被配置导入那条路径顺带触发,那时候整份歌词缓存本来就是跟着一起换的,
            // 不该再自作主张改一遍锁定状态。
            SettingsRow(
                icon: "lock.circle",
                title: L10n.t("手动选定歌词后锁定"),
                // 文案按"开/关各一行"写(跟上面「匹配方式」那条 help 同一个格式):这个开关
                // 唯一要回答的问题就是"开跟关差在哪",两行对照比一整段散文快得多。刻意不再
                // 提"等同于直接编辑歌词"——那是实现口径(markManual),读的人不知道"直接编辑
                // 歌词"背后也是一次冻结,拿它当类比等于用一个更陌生的东西解释。
                //
                // ⚠️ 这行字必须跟 `manualPickLocksLyrics` 的真实两态逐字对得上。第一版文案
                // 老老实实把当时的关态("只记住用哪个来源")写了出来,用户一读就发现那不是他
                // 要的语义,当场把中间态否掉了——**把行为写进界面才发现行为是错的**。以后改
                // 这个开关的行为,这行字要一起改。
                help: L10n.t("关（默认）：只是当下换上这份；以后的自动重搜和打分改进照样会调整它，也可能换成别的来源\n开：这首歌就定在这份歌词上，之后任何自动匹配都不会再碰它\n打开时会把之前手动选定过的歌一并锁定（内容已经被自动换掉的除外）")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.manualPickLocksLyrics },
                    set: { on in
                        // 开关**先**落地(以后新采纳的立刻按新规矩走),再去追溯处理存量 ——
                        // 反过来的话,用户在下面那个确认框上犹豫的这几秒里,新采纳的歌会
                        // 按旧规矩落盘。
                        settings.manualPickLocksLyrics = on
                        runManualPickLockSweep(locking: on)
                    }
                ))
            }
            // 回执常驻一小会儿。⚠️ 位置在卡片最末、开关行的正下方 —— 别挪到别处:这条话
            // 说的就是刚才那一下开关的后果,离开关越远越像一条无主的系统提示。
            if manualPickLockBusy || manualPickLockNotice != nil {
                CardDivider()
                SettingsNote {
                    HStack(spacing: 6) {
                        if manualPickLockBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(manualPickLockNotice ?? L10n.t("正在检查已经手动选定过的歌…"))
                    }
                }
            }
        }
        // 这一条出现/消失会把卡片撑高再收回,不加动画就是一次生硬的跳变(而且它自己
        // 8 秒后还会自动收回去,跳两次)。
        .animation(.easeInOut(duration: 0.18), value: manualPickLockBusy)
        .animation(.easeInOut(duration: 0.18), value: manualPickLockNotice)
        .alert(L10n.t("要把之前锁定的歌一并解锁吗？"), isPresented: $showManualPickUnlockConfirm) {
            // 「保持锁定」也要给回执 —— 用户刚被问了一个问题,选完却什么都没变化的话,
            // 分不清"我的选择生效了"还是"这个按钮没反应"。
            Button(L10n.t("保持锁定"), role: .cancel) {
                showManualPickLockNotice(String(
                    format: L10n.t("%@ 首保持锁定；从现在起手动选定的歌不再自动锁定"),
                    "\(pendingManualUnlockCount)"))
            }
            Button(L10n.t("一并解锁")) {
                Task {
                    manualPickLockBusy = true
                    let n = await EnrichCacheStore.shared.applyManualPickLock(false)
                    manualPickLockBusy = false
                    showManualPickLockNotice(String(format: L10n.t("已解锁 %@ 首"), "\(n)"))
                }
            }
        } message: {
            Text(String(
                format: L10n.t("有 %@ 首歌是因为这个开关被锁定的。解锁后它们会重新接受自动重搜和打分改进；你手动编辑过正文的歌不受影响，始终保持锁定"),
                "\(pendingManualUnlockCount)"))
        }
    }

    /// 翻「手动选定歌词后锁定」这个开关之后的追溯扫描 + 回执。
    ///
    /// ⚠️ **每一条路径都必须说话**,包括"一首都没动"。第一版在 0 命中时直接 `return`,而这个
    /// 功能刚上线时所有人的留痕数都是 0(记号是这次才加的,历史上采纳过的歌一条都没有)——
    /// 也就是说**打开开关必然什么都不发生、也没有任何解释**,看起来跟功能坏了一模一样。
    /// 2026-09-01 用户反馈「交互有点差」,这是最主要的一条。
    ///
    /// 而且"没动"要分得清是哪一种:从没手动选过 / 选过但内容已被自动换掉 / 已经都锁着了,
    /// 三种的下一步动作完全不同(见 ManualPickLock.PickState)。
    private func runManualPickLockSweep(locking: Bool) {
        manualPickLockNotice = nil
        manualPickLockBusy = true
        Task {
            // ⚠️ 必须先 reload:设置页从没打开过「歌词管理」时 store.raw 是空的,直接算目标集
            // 会得到 0 条然后报"没有可锁定的歌"—— 一句**错误**的解释比不解释更糟。
            let store = EnrichCacheStore.shared
            await store.reload(onlyIfChanged: true)
            let stats = store.manualPickLockStats(locking: locking)

            guard locking else {
                manualPickLockBusy = false
                // 关掉:有东西可解锁才问,问完由 alert 那两个按钮各自给回执。
                guard stats.targets > 0 else {
                    showManualPickLockNotice(L10n.t("从现在起，手动选定的歌不再自动锁定"))
                    return
                }
                pendingManualUnlockCount = stats.targets
                showManualPickUnlockConfirm = true
                return
            }

            // 打开 = 用户说"我手动选过的都该是锁着的",直接做,不问(他要的就是自动)。
            let changed = await store.applyManualPickLock(true)
            manualPickLockBusy = false
            if changed > 0 {
                showManualPickLockNotice(String(
                    format: L10n.t("已锁定 %@ 首之前手动选定的歌；从现在起选定的会直接锁定"),
                    "\(changed)"))
            } else if stats.picked == 0 {
                // 绝大多数人(以及这个功能刚上线时的所有人)会落在这一支。必须说清楚"不是
                // 坏了,是还没有可追溯的对象",并且告诉他从现在起会怎样。
                showManualPickLockNotice(L10n.t("还没有手动选定过歌词；从现在起你选定的都会直接锁定"))
            } else if stats.stillOriginal == 0 {
                showManualPickLockNotice(String(
                    format: L10n.t("之前手动选定的 %@ 首，歌词后来都被自动更新过，已经不是你当初选的那一份，所以没有锁定"),
                    "\(stats.picked)"))
            } else {
                showManualPickLockNotice(String(
                    format: L10n.t("之前手动选定的 %@ 首已经都是锁定状态"), "\(stats.stillOriginal)"))
            }
        }
    }

    /// 显示一条一次性回执,几秒后自己收回去。
    ///
    /// 用 token 判定而不是直接 `manualPickLockNotice = nil`:连着翻两次开关时,第一条的
    /// 计时器会在第二条正显示着的时候到期,把**新**的那条抹掉。
    private func showManualPickLockNotice(_ text: String) {
        manualPickLockNoticeToken += 1
        let token = manualPickLockNoticeToken
        manualPickLockNotice = text
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard manualPickLockNoticeToken == token else { return }
            manualPickLockNotice = nil
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
                // 固定 4 列网格里,格宽是卡片宽度的四分之一 —— 英文译名("NetEase Cloud
                // Music" 这类)在这个宽度下装不下,原来 WrapLayout 时代靠折行/换行躲开这个
                // 问题,固定列数之后就躲不开了。这里改用截断:单行 + 尾部省略号,鼠标悬停
                // (.help)给出完整名字,不让某一个来源的长译名撑破所在的整列宽度。
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // ⚠️ 2026-08-31 去掉了这里的 `.frame(maxWidth: .infinity, alignment: .leading)`
            // ——这个 Button 曾经故意占满整格宽度,让测试小图标可以叠(overlay)在它上面;
            // 那个叠加方案在实机上点击互相抢占(见 ForEach 调用点的详细注释),改成两个
            // 控件平级放进一个 HStack 之后,这个 Button 只需要按自己的内容(圆点+文字)
            // 天然宽度来,"占满整格"这件事交给外层 HStack 负责,不然它会把 Spacer 和
            // 测试小图标都挤没有空间。
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.secondary.opacity(0.12) : .clear))
            // 整块(含内边距)都算命中区,不是只有文字和圆点上才点得到
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(name)
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

    /// 卡片标题行右侧的「测试」按钮(2026-08-31 从「全部测试」改成「测试」——两个字
    /// 已经说清楚是干什么的,"全部"是多余的修饰),只测**已启用**的源(跟 collector 侧
    /// 不传 -source 时默认测全部已启用源的口径一致)。
    ///
    /// ⚠️ **故意不 `.disabled(isTestingLyricSources)`**(2026-08-31 用户明确要求"这个
    /// 按钮不要被单个测试锁住,任何时候都能点、都会触发全部检测")——理由跟具体的取代
    /// 机制见 `isTestingLyricSources`/`lyricSourceTestGeneration` 声明处注释。`Text`/
    /// 图标仍然按 `isTestingLyricSources` 换成"测试中…"/转轴,只是这个视觉状态**不再
    /// 决定能不能点**——哪怕当前是单个测试按钮让它进入"测试中"的显示,这颗按钮依旧可点,
    /// 点下去会取代那一轮、改跑全部。
    private var testAllSourcesButton: some View {
        Button {
            testAllSources()
        } label: {
            HStack(spacing: 4) {
                if isTestingLyricSources {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                Text(isTestingLyricSources ? L10n.t("测试中…") : L10n.t("测试"))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .controlSize(.small)
        .settingsGlassButtons()
    }

    /// 每个来源格子尾部的测试按钮/结果状态(2026-08-30)。跟 `sourceCheckbox` 是平级的
    /// HStack 兄弟节点,不叠在它上面(见 ForEach 调用点注释——叠加方案在实机上悬停/点击
    /// 会跟下面那个铺满整格的开关 Button 打架,已经放弃)。三种形态:
    /// - 还没测过、也没在悬停:完全不显示(不给静止状态添视觉噪音)。
    /// - 悬停中(还没测过,或者正在测):悬停给一个中性的"测试"小图标按钮,鼠标真压在
    ///   它自己身上时再叠一层圆形底色——单靠一个裸图标看不出"这是能点的东西"
    ///   (2026-08-31 用户实机反馈"没看到可交互性以及信息能力")。真在测的时候换成
    ///   小转轴,不管有没有悬停都要看得见——用户点了就该看到反馈。
    /// - 已经有结果:一个按状态上色的小图标,不管有没有悬停都常驻显示(结果是持续有效的
    ///   信息,不该只在悬停时才看得见),再点一次等于重新测这一个源。
    ///
    /// ⚠️ **原因文案不用 `.help()`**——2026-08-31 用户实机反馈"悬浮并没有提示出来",当时
    /// 这个控件还叠在 `sourceCheckbox` 上面,两个互相重叠的原生 tooltip 注册区域在
    /// AppKit 层面会打架。现在已经不叠了,但保留用 `.popover` 自绘(而不是换回
    /// `.help()`)——popover 能精确控制多行换行(`.frame(width:)+.fixedSize`),
    /// `.help()` 换行控制没这么直接,不想再冒一次险。
    ///
    /// ⚠️ **"还没测过"这个态不再给提示文案**(2026-08-31 用户要求"把这个 hover 文案去掉")
    /// ——"测试这个来源现在是否可用"这句话本身信息量有限,图标 + 点击行为已经说明白了
    /// 是干什么的,不需要额外一句话重复。提示只留给 warn/fail 结果——那才是真正有必要
    /// 读一下的具体原因。
    @ViewBuilder
    private func sourceTestAccessory(_ source: LyricsSource) -> some View {
        let state = sourceTestStates[source]
        // 用整行悬停(hoveredRow),不是 sourceCheckbox 自己那段更窄的悬停(hoveredSource)
        // ——理由见 ForEach 调用点的 .onHover 注释:两者中间隔着一段 Spacer 空白,只用
        // 后者会在鼠标途经空白那一段时让图标提前消失。
        let isRowHovered = hoveredRow == source
        let isAccessoryHovered = accessoryHoverSource == source
        let tooltip = sourceAccessoryTooltip(state)
        Group {
            switch state {
            case .testing:
                ProgressView().controlSize(.mini)
            case .result(let status, _):
                Button { testSource(source) } label: {
                    Image(systemName: statusSymbol(status))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor(status))
                }
                .buttonStyle(.plain)
            case nil:
                if isRowHovered || isAccessoryHovered {
                    Button { testSource(source) } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                            .foregroundStyle(isAccessoryHovered ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // 固定尺寸的命中区,不随内容是否可见变化——悬停判定(下面的 .onHover)要在图标
        // 还没出现(比如"还没测过、鼠标刚移进这一格"那一帧)时也能立刻生效,不依赖内容
        // 本身有没有渲染出东西来提供可命中的几何。
        .frame(width: 16, height: 16)
        // 鼠标真压在这个控件上时给一圈圆形底色——单靠图标本身的颜色变化不够明显,
        // 这一层才是"这是可点的东西"最直接的信号(跟设置页其它按钮 hover 时的反馈同一个
        // 语言:有底色变化 = 能点)。
        .background(Circle().fill(isAccessoryHovered ? Color.secondary.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .disabled(isTestingLyricSources)
        .onHover { hovering in
            accessoryHoverSource = hovering ? source : (accessoryHoverSource == source ? nil : accessoryHoverSource)
        }
        .popover(isPresented: Binding(
            get: { isAccessoryHovered && tooltip != nil },
            set: { shown in if !shown { accessoryHoverSource = nil } }
        ), arrowEdge: .bottom) {
            if let tooltip {
                // ⚠️ `.frame(maxWidth:)` 单独用不住(2026-08-31 用户实机反馈"文案显示
                // 不完整,截断了")——popover 的内容尺寸是按 Text 的理想单行宽度算的,
                // `maxWidth` 只是给了一个上限,不会主动把宽度收窄逼着它换行。改成
                // `.frame(width:)` 钉死宽度 + `.fixedSize(horizontal: false, vertical:
                // true)`(横向不再收缩、纵向随内容长高)才会真的按这个宽度换行。
                Text(tooltip)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.leading)
                    .frame(width: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
        }
    }

    /// 悬浮在哪个来源的测试小图标上(只为上面那个自绘 popover,跟 hoveredSource——整格
    /// 悬停底色用的——是两件独立的事:这个格子悬停着,不代表鼠标正压在那个 16×16 的小
    /// 图标上)。
    @State private var accessoryHoverSource: LyricsSource?

    private func sourceAccessoryTooltip(_ state: LyricSourceTestState?) -> String? {
        switch state {
        // 通过(ok)不给提示——"接口有响应"这句话本身不携带任何决策信息,绿色✓已经说完了
        // 整件事,弹一个只会重复视觉状态的气泡纯属打扰。只有 warn/fail 才有值得读的原因。
        case .result(let status, let detail): return status == .ok ? nil : detail
        // 还没测过 / 正在测:都不给提示,理由见函数声明处注释。
        case .testing, nil: return nil
        }
    }

    private func statusSymbol(_ status: LyricSourceTestService.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .fail: return "wifi.slash"
        }
    }

    private func statusColor(_ status: LyricSourceTestService.Status) -> Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .secondary
        }
    }

    /// 单独测一个源——不管这个源当前是启用还是禁用都能测(想测一个已经关掉的源、
    /// 决定要不要重新打开,同样是合理的用法),跟「全部测试」只测已启用源的口径不同。
    ///
    /// ⚠️ 不再守卫 `isTestingLyricSources`(2026-08-31)——「全部测试」现在随时可以点、
    /// 随时会取代正在跑的任意一轮(哪怕是这个函数发起的)。这里靠 generation 编号辨认
    /// "我是不是被取代了":被取代那一轮的 collector 子进程会被 `cancelRunning()` 杀掉、
    /// `await` 因此抛错,如果这时候 generation 已经变了(说明"全部测试"或另一次单独测试
    /// 抢先了),这次的收尾整段放弃——不写"失败"结果(会误导用户以为这个源真的测试
    /// 失败),也不去动 `isTestingLyricSources`(新那一轮还在跑,不该被这里踩成 false)。
    private func testSource(_ source: LyricsSource) {
        lyricSourceTestGeneration += 1
        let generation = lyricSourceTestGeneration
        isTestingLyricSources = true
        sourceTestStates[source] = .testing
        Task {
            do {
                try await LyricSourceTestService.shared.test(source: source) { result in
                    guard let matched = LyricsSource(rawValue: result.source) else { return }
                    sourceTestStates[matched] = .result(
                        status: result.status,
                        detail: LyricSourceFailureReason.text(forCode: result.reasonCode))
                }
            } catch {
                if generation == lyricSourceTestGeneration {
                    sourceTestStates[source] = .result(
                        status: .fail, detail: error.localizedDescription)
                }
            }
            if generation == lyricSourceTestGeneration {
                isTestingLyricSources = false
            }
        }
    }

    /// ⚠️ **故意不守卫 `isTestingLyricSources`**(2026-08-31 用户明确要求)——这是唯一
    /// 一个"随时能点、会取代任何正在跑的一轮"的入口,跟 `testSource` 的取代/generation
    /// 机制完全对称,理由见 `isTestingLyricSources` 声明处注释。
    private func testAllSources() {
        lyricSourceTestGeneration += 1
        let generation = lyricSourceTestGeneration
        isTestingLyricSources = true
        for source in LyricsSource.allCases where features.lyricsSources.contains(source) {
            sourceTestStates[source] = .testing
        }
        Task {
            do {
                try await LyricSourceTestService.shared.test(source: nil) { result in
                    guard let matched = LyricsSource(rawValue: result.source) else { return }
                    sourceTestStates[matched] = .result(
                        status: result.status,
                        detail: LyricSourceFailureReason.text(forCode: result.reasonCode))
                }
            } catch {
                // 子进程整个没跑起来(比如 collector 二进制缺失)——已经标成"测试中"的
                // 那些格子要有个交代,不能永远转圈,统一改成失败并带上原因。仅在自己仍是
                // 最新一轮时才写,理由同 testSource 的 catch 分支。
                if generation == lyricSourceTestGeneration {
                    for source in LyricsSource.allCases where sourceTestStates[source] == .testing {
                        sourceTestStates[source] = .result(
                            status: .fail, detail: error.localizedDescription)
                    }
                }
            }
            if generation == lyricSourceTestGeneration {
                isTestingLyricSources = false
            }
        }
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
                            L10n.t("拼音"), .chinese,
                            help: L10n.t("只对判定为普通话的歌词生效，例如 你好 → nǐ hǎo"))
                        romanizationToggle(
                            L10n.t("粤拼"), .cantonese,
                            help: L10n.t("只对判定为粤语的歌词生效，用的是粤拼(Jyutping)方案，例如 你好 → nei5 hou2"))
                    }
                }
                // 这句原来是常驻副标题,2026-08-17 挪进悬停说明(用户要求)——四个语言
                // 开关各自已经带了更具体的 help,行上再顶一句概括是重复的噪声。
                .help(L10n.t("日语、韩语标成罗马字，普通话标成拼音，粤语标成粤拼"))
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
    // (灵动岛「显示在哪块屏幕」的选项快照和「所有屏幕」哨兵 tag 2026-08-31 随 notchOverlayCard
    //  一起搬进了 NotchEditorStage.swift 的 NotchScreenSettingsRows —— 只有那一处在用。)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // ⚠️ 2026-09-01:菜单栏这段跟进悬浮歌词/灵动岛,也升级成了内容区里**可交互**的
        // 编辑台(MenuBarEditorStage)——下面 Group 那段 switch 现在四个分支**全部**是
        // `EmptyView()`,这个固定头部因此已经不再挂任何东西。没有顺手把
        // `SettingsPageWithStickyHeader` 这套机制整个撤掉:`sectionPicker` 也早就因为
        // 同一个"固定头部点不动"的毛病挪回了滚动区(见下面那条注释),固定头部这层结构本身
        // 现在纯粹是历史遗留的空壳——值不值得连壳一起拆是一次单独的决定,这次改动没有做。
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
                // ⚠️ 悬浮歌词段(2026-08-30)和灵动岛段(2026-08-31)**刻意不钉预览条**:
                // 两段的预览都已经升级成内容区里的编辑台(OverlayEditorStage /
                // NotchEditorStage),里面有宽度调整条和工具栏浮层。而这个固定头部里的控件
                // **点不动** —— 见上面那段 2026-08-16 的复现记录:跟放的是哪个视图、内部有没有
                // hover 手势都无关,是这个头部结构本身在 SwiftUI 里的事件派发行为,连
                // .allowsHitTesting(false) 都救不回来。所以能交互的预览只能待在滚动区。
                case .overlay: EmptyView()
                case .notch: EmptyView()
                // 2026-09-01:菜单栏这段也升级成内容区里的编辑台(MenuBarEditorStage),
                // 预览(MenuBarPreviewBar,原样复用,渲染逻辑一个字没改)挪进了编辑台内部——
                // 理由跟悬浮歌词/灵动岛那两支一致,这个固定头部收不到点击。
                case .menuBar: EmptyView()
                }
            }
            .animation(.easeOut(duration: 0.18), value: sectionRaw)
        } page: {
            SettingsPage(
                title: L10n.t("歌词显示"),
                // 「三种」而不是原来的「四种」:这一页实际只有三个展示方式开关(桌面悬浮
                // 歌词/灵动岛歌词/菜单栏歌词)。第四种是「歌词窗口」,它压根不在这一页配置
                // —— 靠快捷键/菜单按需打开,没有开关。原文案让人数着三个开关去找第四个。
                subtitle: L10n.t("三种展示方式可以同时开启"),
                // 这一页顶着一块接近真实尺寸的编辑台,纵向空间格外紧;而窗口标题栏已经写着
                // 「设置 – 歌词显示」,页内那块 22pt 大标题是同一句话说两遍(2026-08-30 用户要求移除)。
                showsHeader: false
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
    /// 分法就按**形态**走 —— 这是这一页天然的结构。
    ///
    /// ⚠️ **原来还有第四段「其它」,只装着一张跨形态的「自动隐藏」卡,2026-09-01 整个撤掉**
    /// (用户原话:「是否可以把这两个配置全都塞到对应的页面里面去,悬浮歌词和灵动岛都塞一个
    /// 进去;不要单独开一个其他页面出来了」)。那张卡当初留在「其它」的理由是"它是跨形态的
    /// 规则、放进任何一个单独形态里都不对" —— 那句话在**它只有一份值**的前提下成立,而这次
    /// 连同前提一起改了:两个形态各自持有一份独立的设置(`hideDuringScreenCapture` /
    /// `hideWhenNotPlaying` 归悬浮歌词,`notchHide*` 归灵动岛),所以现在各放一张卡是对的。
    /// 见 `autoHideCard(subtitle:help:captureBinding:notPlayingBinding:)`。
    ///
    /// 删掉一个 rawValue 是安全的:`section` 那个计算属性带 `?? .overlay` 兜底,老用户上次
    /// 停在「其它」段的话,下次打开会落回悬浮歌词,不会白屏。
    ///
    /// ⚠️ 这三个的 rawValue 全是**跨文件契约**:菜单栏面板那边的「全部设置…」要把这一页直接
    /// 翻到对应的形态那一段,靠的就是往下面那个 @AppStorage 键写这几个字符串
    /// (LyrimuseCore.LyricsSurface.appearanceSectionRawValue)。改名字不会编译报错,只会
    /// 表现成"长按灵动岛、设置窗口却停在悬浮歌词那一段"。
    private enum Section: String, CaseIterable, Identifiable {
        case overlay, notch, menuBar
        var id: Self { self }
        var title: String {
            switch self {
            case .overlay: return L10n.t("悬浮歌词")
            case .notch: return L10n.t("灵动岛")
            case .menuBar: return L10n.t("菜单栏")
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
            // 编辑台(2026-08-30):这一段的预览从"顶部钉住的一条"改成内容区里的主体,
            // 因为它现在可交互(舞台里有宽度调整条、有点文字/点背景的命中区),而固定头部
            // 收不到事件(理由见上面
            // stickyHeader 里那条注释)。钉条本身仍然在,只是这一段不用它 ——
            // 灵动岛/菜单栏两段照旧,SectionPreviewMetrics 的高度契约不受影响。
            OverlayEditorStage()
            modeToggleCard(
                icon: "captions.bubble",
                title: L10n.t("桌面悬浮歌词"),
                isOn: Binding(
                    get: { settings.classicOverlayEnabled },
                    set: { LyricsOverlayWindowController.shared.setVisible($0) }))
            // 「行为」栏(2026-08-30,编辑台第三步):锁定位置 / 拖动前先长按 / 划过让开。
            // 从原来的「窗口」卡里提出来单独一栏 —— 它们在编辑台上看不出变化,混在配色
            // 字体那些"改了当场看得见"的项里,读者会一直等一个不会来的反馈。行本体在
            // OverlayBehaviorSettingsRows.swift,跟抽屉里「窗口」那一组是同一份。
            //
            // 总开关排在它上面而不是下面:那是这一段的主开关(它决定整个形态开不开),
            // 而行为项是"开了之后这扇窗怎么表现",从属于它。
            OverlayBehaviorBar()
            // 配置项**不跟开关联动**(2026-08-15 用户要求):关着也能调。
            // 理由:把它藏起来只是让"先开、调完、再关"变成必须的操作顺序,并不能阻止
            // 什么;而想先配好再打开的人会以为这个形态没有可调项。
            //
            // 2026-08-30 从平铺的六张卡收成一个默认折叠的抽屉(编辑台第三步)。总开关
            // 没进去(它在上面常驻),其余 16 项一项没少,见那个文件顶部的注释。
            // 「自动隐藏」(2026-09-01 从原来的「其它」段搬过来,并拆成只归悬浮歌词的一份)。
            // 排在抽屉**上面**:抽屉叫「全部设置」,一张常驻卡片摆在它下面读起来像"漏在外面的"。
            autoHideCard(
                subtitle: L10n.t("只对悬浮歌词生效"),
                help: L10n.t("以下两项只对「桌面悬浮歌词」生效；灵动岛、菜单栏歌词和歌词窗口不受影响"),
                captureBinding: Binding(
                    get: { settings.hideDuringScreenCapture },
                    set: { newValue in
                        settings.hideDuringScreenCapture = newValue
                        // ⚠️ 守卫必须留:`.shared` 是 `static let`,读一下就把整扇窗建出来。
                        if settings.classicOverlayEnabled {
                            LyricsOverlayWindowController.shared.setHiddenFromCapture(newValue)
                        }
                    }),
                notPlayingBinding: Binding(
                    get: { settings.hideWhenNotPlaying },
                    set: { newValue in
                        settings.hideWhenNotPlaying = newValue
                        if settings.classicOverlayEnabled {
                            LyricsOverlayWindowController.shared.setHideWhenNotPlaying(newValue)
                        }
                    }))
            OverlayAllSettingsDrawer()
        case .notch:
            // 编辑台(2026-08-31,照悬浮歌词那一段的范式改):一小片屏幕顶端(菜单栏 + 刘海
            // + 桌面),灵动岛卡片 1:1 挂在上面。它取代了页顶那条钉住的 NotchPreviewBar ——
            // 那一层收不到点击(理由见上面 stickyHeader 里那条注释),而这块画布里有宽度调整
            // 条和两个工具栏浮层。原来那张 notchOverlayCard(风格 / 宽度 / 显示在哪块屏幕)
            // 整张收进编辑台,这一段因此只剩"编辑台 + 总开关 + 显示歌词"三块。
            NotchEditorStage()
            // 总开关排在编辑台下面而不是上面,跟悬浮歌词那一段同一个排法:先看见这个形态
            // 长什么样,再决定开不开。
            modeToggleCard(
                icon: "rectangle.topthird.inset.filled",
                title: L10n.t("灵动岛歌词"),
                subtitle: L10n.t("紧凑地贴着屏幕顶部的刘海显示"),
                isOn: Binding(
                    get: { settings.notchOverlayEnabled },
                    set: { NotchLyricsWindowController.shared.setVisible($0) }))
            // 「显示歌词」/「暂停缩回」/「显示封面」/「下一句预览」/「歌名」/「歌手」/
            // 「专辑」这一批布尔开关(2026-08-31 起持续演进)最初直接铺在页面上——先是
            // 一张横排的「行为」卡片,后来陆续并进「显示封面」(几经反复:工具栏装不下、
            // 耳朵浮层里也不合适),再后来整张「展开态」卡片(下一句预览/歌名/歌手/专辑)
            // 也被要求"塞到行为卡片里再起一行"。2026-09-01 同一天最后一轮,用户要求整体
            // 改回跟「风格/屏幕/左耳/右耳」一致的"点开才配置"形态——不是否定之前的分组,
            // 三个新入口(见 NotchEditorStage.toolbarRow2)的分组是:「歌词行」→显示歌词+
            // 显示封面,「行为」→暂停缩回,「展开态」→下一句预览+封面+歌名+歌手+专辑
            // (`.showLyrics` 后来又从「行为」搬进了「歌词行」,见 `NotchLyricRowPopover`
            // 上方注释)。内容(图标/标题/Binding)仍然只有 `NotchBehaviorItem` 一份,页面上
            // 因此**不再有**常驻卡片,只剩编辑台工具栏里那三个新按钮 + 下面「全部设置」
            // 抽屉里同样拆成三组的 `NotchBehaviorItemRows` 兜底。
            // 「自动隐藏」——灵动岛自己那一份(`notchHide*`),跟悬浮歌词那张卡互不影响。
            //
            // ⚠️ 开着「暂停/无播放时隐藏」,灵动岛暂停后是整个 orderOut,**看不到"歌词行卷回
            // 顶行"那段收起动画**(窗口都没了)。关掉才看得到。这是设置本身的语义,不写进 UI
            // —— 用户试一下就知道。
            autoHideCard(
                subtitle: L10n.t("只对灵动岛生效"),
                help: L10n.t("以下两项只对「灵动岛歌词」生效；桌面悬浮歌词、菜单栏歌词和歌词窗口不受影响"),
                captureBinding: Binding(
                    get: { settings.notchHideDuringScreenCapture },
                    set: { newValue in
                        settings.notchHideDuringScreenCapture = newValue
                        if settings.notchOverlayEnabled {
                            NotchLyricsWindowController.shared.setHiddenFromCapture(newValue)
                        }
                    }),
                notPlayingBinding: Binding(
                    get: { settings.notchHideWhenNotPlaying },
                    set: { newValue in
                        settings.notchHideWhenNotPlaying = newValue
                        if settings.notchOverlayEnabled {
                            NotchLyricsWindowController.shared.setHideWhenNotPlaying(newValue)
                        }
                    }))
            NotchAllSettingsDrawer()
        case .menuBar:
            // 编辑台(2026-09-01,照悬浮歌词/灵动岛两段的范式改,用户原话"改为和悬浮歌词、
            // 灵动岛歌词一样的这种风格"):预览(MenuBarPreviewBar,原样复用)挪进编辑台内部
            // + 工具栏两个浮层(宽度模式/配色)+ 重置 ▾ + 常驻宽度条,取代原来平铺的
            // menuBarCard。总开关沿用跟灵动岛一样的排法:排在编辑台**下面**,先看见长什么样
            // 再决定开不开。详见 MenuBarEditorStage.swift 顶部注释。
            MenuBarEditorStage()
            modeToggleCard(
                icon: "menubar.rectangle",
                title: L10n.t("菜单栏歌词"),
                isOn: $settings.showLyricsInMenuBar)
            MenuBarAllSettingsDrawer()
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


    // 「桌面悬浮歌词」那一整套配置卡(配色 / 我的配色主题 / 文字 / 窗口 / 恢复)在
    // 2026-08-30(编辑台第三步)全部搬走了,这里不再有它们的定义:
    //   - 五张卡的内容收进了 OverlayAllSettingsDrawer —— 默认折叠的「全部设置」抽屉。
    //     原来它们平铺在编辑台下面要滚两屏,而高频项已经被编辑台和工具栏浮层接管,
    //     剩下的职责只有"全量兜底通路",没有理由常年占着两屏。
    //   - 「窗口」卡里那三个行为项提到了编辑台正下方的 OverlayBehaviorBar(行为栏)。
    // 行本体分别在 OverlayStyleSettingsRows.swift 和 OverlayBehaviorSettingsRows.swift,
    // 那也是编辑台两个浮层用的同一份。别在这里重新长出一张同名的卡:这一段现在有浮层、
    // 行为栏、抽屉三个宿主,多一份实现就多两处会漂的地方(理由见那两个文件顶部)。

    // (2026-08-30 第十步之前这一层还挂着「划过让开」那个预演的状态机:
    //  `overlayFadePreviewActive` / `overlayFadePreviewTask` / `playOverlayFadePreview()`。
    //  按钮在行为栏、淡的却是编辑台,两者是兄弟视图,这里是唯一的共同祖先,所以状态放在这层。
    //  用户要求把那颗「预演」按钮删掉,状态机跟着一起清干净了 —— 这一段现在只剩装配。)

    // 「灵动岛歌词」那张配置卡(风格 / 宽度 / 显示在哪块屏幕)在 2026-08-31 整张搬进了
    // NotchEditorStage.swift —— 前两项进了编辑台工具栏的两个浮层和舞台里那条宽度调整条,
    // 屏幕那一项进了「屏幕」浮层。别在这里重新长出一张同名的卡:那一段现在只有编辑台一个
    // 宿主,多一份实现就多一处会漂的地方(理由同上面悬浮歌词那几张卡)。
    //
    // 顺带修掉的两处:那张卡里 `NotchLyricsWindowController.shared.applyContentWidthSetting()`
    // 和 `.applyScreenSetting()` 原来都是**裸调**的,违反那个类的 `.shared` 不变量(读一下
    // 就 init 出整扇窗;见 docs/features/05-notch.md 设计决策第 1 条)。新的落点两处都带
    // `if settings.notchOverlayEnabled` 守卫。

    // 「菜单栏歌词」那张平铺卡片(宽度模式/逐字染色/文字颜色/染色颜色/最大宽度五项)在
    // 2026-09-01 整张搬进了 UI/MenuBarEditorStage.swift——前两项进了编辑台工具栏的两个
    // 浮层(宽度模式/配色),最大宽度进了舞台正下方的常驻宽度条,「全部设置」抽屉
    // (MenuBarAllSettingsDrawer)兜底。别在这里重新长出一张同名的卡:那一段现在只有编辑台
    // 一个宿主,多一份实现就多一处会漂的地方(理由同上面悬浮歌词/灵动岛那几张卡)。

    /// 「自动隐藏」卡。⚠️ 2026-09-01 起**每个形态各一张、各管各的一份设置**,由调用点把
    /// 对应的一对 Binding 传进来(用户要求把它从「其它」段搬进两个形态各自的页面,并拆成
    /// 互相独立的两套;「其它」那一段因此整个撤掉,见 `Section` 头注)。
    ///
    /// ⚠️ 拆之前这里写着"两个悬浮窗共用的隐藏开关",而且 `Section` 那边还专门论证过
    /// "它是跨形态的规则,放进任何一个单独形态里都不对"。那句话在**它只有一份值**的前提下
    /// 成立;这次连前提一起改了 —— 一旦按形态分栏展示,用户就会**按形态去理解**它
    /// (「我在灵动岛页面关掉的,当然只关灵动岛」),继续共用一份是个必然会踩的坑。
    ///
    /// ⚠️ 标题仍叫「自动隐藏」而不是「共用设置」之类:它描述的是这两个开关实际在做的事。
    ///
    /// ⚠️ **`.shared` 只准出现在调用点的 `set:` 闭包里,而且必须带 `if settings.xxxEnabled`
    /// 守卫** —— 两个控制器都是 `static let shared`,**读一下就把整扇窗建出来**(见
    /// `NotchLyricsWindowController` 顶部那条不变量)。关着的那个形态一行都不能碰。所以这个
    /// 函数本身只收 Binding、不认识任何控制器。
    private func autoHideCard(
        subtitle: String,
        help: String,
        captureBinding: Binding<Bool>,
        notPlayingBinding: Binding<Bool>
    ) -> some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("自动隐藏"), subtitle: subtitle, help: help)
            CardDivider()
            SettingsRow(
                icon: "camera.viewfinder",
                title: L10n.t("截屏/录屏时隐藏"),
                subtitle: L10n.t("别人看不到，你仍看得见"),
                // ⚠️ 措辞不写死"悬浮歌词":这张卡现在两个形态各用一次,原来那句
                // 「…都不会拍到悬浮歌词」摆在灵动岛那一段上就是错的。
                help: L10n.t("截图、录屏、视频会议共享屏幕都拍不到它")
            ) {
                Toggle("", isOn: captureBinding)
            }
            CardDivider()
            SettingsRow(icon: "pause.circle", title: L10n.t("暂停/无播放时隐藏")) {
                Toggle("", isOn: notPlayingBinding)
            }
        }
    }
}

// MARK: - 灵动岛「行为」类布尔开关(唯一数据源;宿主几经改版,见下方⚠️)

/// 灵动岛几个纯布尔"设一次就不动"的行为项的唯一一份实现(2026-08-31 起)。文案/图标/
/// Binding/帮助文案只有这一份,渲染它的宿主(下面 `NotchBehaviorItemRows`)也只有一份
/// 实现,具体摆在哪由**调用点**决定——避免"这边改了有用、那边改了没用"这类漏改不报错
/// 的坑(悬浮歌词那边已经为同一个理由付过一次代价)。
///
/// ⚠️ **落点几经反复,均系 2026-08-31~09-01 这两天**:最初「显示歌词」「暂停缩回」两项
/// 照悬浮歌词的「行为」栏范式,横排常驻在设置页上;「显示封面」(带从属的"封面位置"
/// 选择器,跟其它项"图标+标题+开关"的单一形状不一样)几经反复后也并了进来,常驻区一度
/// 因此变成一整张「行为」卡片;紧接着连独立的「展开态」卡片(下一句预览/歌名/歌手/专辑)
/// 也被要求"塞进行为卡片里再起一行"整个合并进来。**最终**用户要求整体改回跟
/// 「风格/屏幕/左耳/右耳」一致的"点开才配置"形态——常驻卡片因此整个撤掉,现在的宿主是
/// 编辑台工具栏第二行三个新入口各自的浮层(`NotchLyricRowPopover`/`NotchBehaviorPopover`/
/// `NotchExpandedPopover`,见 `NotchEditorStage.toolbarRow2`)+「全部设置」抽屉里按同样
/// 三组拆开的 `NotchAllSettingsDrawer.lyricRowGroup`/`behaviorGroup`/`expandedGroup`
/// (仍然常驻,是这几项**唯一**不用点开工具栏也能摸到的入口)。
/// 「显示音浪」**不在这个枚举里**——同样带一个从属选择器,但没人要求把它也挪进来,继续
/// 留在 `NotchEarSettingsRows.equalizerRow`/`NotchEqualizerRow` 里,不要顺手一起挪。
///
/// `.expandedNextLine`/`.expandedShowsTrackTitle`/`.expandedShowsArtist`/
/// `.expandedShowsAlbum` 源自已删除的独立「展开态」卡片(`NotchExpandedInfoCard`);
/// `AppSettings` 那几个键名依然保留 `notchExpanded*` 前缀(键名是持久化格式,不因为 UI
/// 挪了地方就迁移,迁移的收益配不上风险)。`.expandedShowsControls`(2026-09-01)是后补的
/// 第五项——展开区那排播放控制键第一次开放成可关的开关,用户原话"再加一个控制键是否
/// 展示",归到「展开态」这一组是因为它跟下一句预览一样,都是"展开区自己的内容"
/// (不像另外四项属于「曲目信息头部」这个子块)。`.expandedShowsLyricsOffset`(同一天再后补
/// 的第六项,用户原话"把调整歌词的也加进去")同理——菜单栏面板同款的歌词时间轴微调按钮,
/// 塞进展开区进度条时间行中间本来就空着的位置,归到「展开态」是因为它也是"展开区自己的
/// 内容"。⚠️ 它是这批开关里**唯一**不影响卡片高度的一项(按钮尺寸卡在时间行本身的高度
/// 里,不需要 `NotchChromeSource`/`NotchExpandedMetrics` 那套几何链路,详见
/// `AppSettings.notchExpandedShowsLyricsOffset` 上面那条⚠️),binding 因此也不用像
/// `.expandedShowsControls` 那样连带触发窗口重算几何。
enum NotchBehaviorItem: String, CaseIterable, Identifiable {
    case showLyrics
    case collapseWhenPaused
    case lyricRowArtwork
    case expandedNextLine
    case expandedShowsControls
    case expandedShowsLyricsOffset
    case expandedShowsArtwork
    case expandedShowsTrackTitle
    case expandedShowsArtist
    case expandedShowsAlbum

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .showLyrics: return "text.alignleft"
        case .collapseWhenPaused: return "arrow.down.right.and.arrow.up.left"
        case .lyricRowArtwork: return "photo"
        case .expandedNextLine: return "text.bubble"
        case .expandedShowsControls: return "playpause.fill"
        case .expandedShowsLyricsOffset: return "timer"
        case .expandedShowsArtwork: return "photo"
        case .expandedShowsTrackTitle: return "textformat"
        case .expandedShowsArtist: return "music.mic"
        case .expandedShowsAlbum: return "opticaldisc"
        }
    }

    var title: String {
        switch self {
        case .showLyrics: return L10n.t("显示歌词")
        case .collapseWhenPaused: return L10n.t("暂停缩回")
        case .lyricRowArtwork: return L10n.t("显示封面")
        case .expandedNextLine: return L10n.t("下一句歌词预览")
        case .expandedShowsControls: return L10n.t("显示播放控制")
        case .expandedShowsLyricsOffset: return L10n.t("显示歌词校准")
        // 跟 .lyricRowArtwork 用同一句文案(都是"显示封面")——两枚封面各自的开关分别
        // 出现在「歌词行」和「展开态」两个浮层里,标题不需要额外区分"是哪一枚"。
        case .expandedShowsArtwork: return L10n.t("显示封面")
        case .expandedShowsTrackTitle: return L10n.t("显示歌名")
        case .expandedShowsArtist: return L10n.t("显示歌手")
        case .expandedShowsAlbum: return L10n.t("显示专辑")
        }
    }

    /// 只有「下一句歌词预览」带帮助气泡(原「展开态」卡片上就是这样);其余项返回 nil,
    /// 宿主据此决定要不要传 `help:` 参数。
    var help: String? {
        switch self {
        case .expandedNextLine: return L10n.t("展开时在进度条上方显示下一句要唱的歌词。")
        default: return nil
        }
    }

    @MainActor
    var binding: Binding<Bool> {
        let settings = AppSettings.shared
        switch self {
        case .showLyrics:
            return Binding(get: { settings.notchShowLyrics }, set: { settings.notchShowLyrics = $0 })
        case .collapseWhenPaused:
            return Binding(get: { settings.notchCollapsesWhenPaused },
                            set: { settings.notchCollapsesWhenPaused = $0 })
        case .lyricRowArtwork:
            return Binding(get: { settings.notchLyricRowShowsArtwork },
                            set: { settings.notchLyricRowShowsArtwork = $0 })
        case .expandedNextLine:
            return Binding(get: { settings.notchExpandedShowsNextLine },
                            set: { settings.notchExpandedShowsNextLine = $0 })
        case .expandedShowsControls:
            return Binding(get: { settings.notchExpandedShowsControls },
                            set: { settings.notchExpandedShowsControls = $0 })
        case .expandedShowsLyricsOffset:
            return Binding(get: { settings.notchExpandedShowsLyricsOffset },
                            set: { settings.notchExpandedShowsLyricsOffset = $0 })
        case .expandedShowsArtwork:
            return Binding(get: { settings.notchExpandedShowsArtwork },
                            set: { settings.notchExpandedShowsArtwork = $0 })
        case .expandedShowsTrackTitle:
            return Binding(get: { settings.notchExpandedShowsTrackTitle },
                            set: { settings.notchExpandedShowsTrackTitle = $0 })
        case .expandedShowsArtist:
            return Binding(get: { settings.notchExpandedShowsArtist },
                            set: { settings.notchExpandedShowsArtist = $0 })
        case .expandedShowsAlbum:
            return Binding(get: { settings.notchExpandedShowsAlbum },
                            set: { settings.notchExpandedShowsAlbum = $0 })
        }
    }
}

/// 「封面位置」那一行(左/右两选一),从属于 `.lyricRowArtwork`,只在它开着时出现——被
/// `NotchBehaviorItemRows` 统一调用(不管它出现在哪个宿主里都是同一份),不单独为每个
/// 宿主各写一份分段选择器。
@MainActor
private struct NotchLyricRowArtworkPositionRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsSubRow(title: L10n.t("封面位置")) {
            Picker("", selection: $settings.notchLyricRowArtworkPosition) {
                ForEach(NotchLyricRowArtworkPosition.allCases, id: \.self) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

/// 一组 `NotchBehaviorItem` 的标准列表渲染——六个宿主都调这一份,传不同的子集:
///   - `NotchAllSettingsDrawer.lyricRowGroup`/`behaviorGroup`/`expandedGroup`
///     (下方,「全部设置」抽屉用,2026-09-01 起按跟浮层相同的三组分别渲染,不再是
///     `allCases` 铺平的一整块);
///   - `NotchLyricRowPopover`/`NotchBehaviorPopover`/`NotchExpandedPopover`
///     (工具栏第二行三个新入口各自的浮层):各传自己那一小撮。
/// 两边六处调用传的子集逐组相同,只是渲染宿主(带不带 `SettingsCardHeader`、外层是卡片
/// 还是浮层)不同。内容(图标/标题/帮助文案/Binding)只在 `NotchBehaviorItem` 里定义一份,
/// 这里只负责"给一组 item 排成竖排列表",不重复抄一份 SettingsRow+Toggle 的样板。
@MainActor
struct NotchBehaviorItemRows: View {
    @ObservedObject private var settings = AppSettings.shared
    let items: [NotchBehaviorItem]

    /// 「显示封面」(歌词行末尾那枚)从属于「显示歌词」——关掉歌词时这一行(连同它的
    /// 「封面位置」子行)整个隐藏,不只是禁用(2026-09-01 用户要求"联动隐藏"):没有歌词行,
    /// "封面贴哪一行"这件事也就没有意义了。只在两者**同时出现在同一个 `items` 列表里**时
    /// 才生效(`items.contains(.showLyrics)`)——目前是「歌词行」浮层和「全部设置」抽屉,
    /// `.lyricRowArtwork` 万一将来单独出现在没有 `.showLyrics` 的列表里,这条判断自动
    /// 不生效,照常显示(没有「显示歌词」可看,谈不上跟它联动)。
    private func isVisible(_ item: NotchBehaviorItem) -> Bool {
        guard item == .lyricRowArtwork, items.contains(.showLyrics) else { return true }
        return settings.notchShowLyrics
    }

    var body: some View {
        let visibleItems = items.filter(isVisible)
        VStack(spacing: 0) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardDivider() }
                SettingsRow(icon: item.icon, title: item.title, help: item.help) {
                    Toggle("", isOn: item.binding)
                }
                if item == .lyricRowArtwork, settings.notchLyricRowShowsArtwork {
                    CardDivider()
                    NotchLyricRowArtworkPositionRow()
                }
            }
        }
    }
}

/// 工具栏第二行「歌词行」入口的浮层(2026-09-01)。内容是「显示歌词」+「显示封面」
/// (带从属的「封面位置」选择器)——两项都是**歌词行本身**的开关(前者管这一行渲不渲染,
/// 后者管行末那枚封面),`.showLyrics` 因此从「行为」浮层搬了过来,跟「全部设置」抽屉里
/// 那两项是同一份 `NotchBehaviorItemRows`,只是分组不同。
struct NotchLyricRowPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("歌词行"), width: 220) {
            NotchBehaviorItemRows(items: [.showLyrics, .lyricRowArtwork])
        }
    }
}

/// 工具栏第二行「行为」入口的浮层(2026-09-01)。内容原本是「显示歌词」+「暂停缩回」,
/// `.showLyrics` 2026-09-01 同一天又被要求"放到歌词行选项里去配置"——它管的是歌词行
/// 渲不渲染,跟「歌词行」浮层里另一项(显示封面)是同一类东西,归到那边比归在通用的
/// "行为"下面更贴切。这里现在只剩「暂停缩回」一项,浮层内容是这个开关+跟「全部设置」
/// 抽屉同一份 `NotchBehaviorItemRows`。
struct NotchBehaviorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("行为"), width: 200) {
            NotchBehaviorItemRows(items: [.collapseWhenPaused])
        }
    }
}

/// 工具栏第二行「展开态」入口的浮层(2026-09-01)。内容是原独立「展开态」卡片
/// (`NotchExpandedInfoCard`,已删除)的全部四项(下一句预览 + 歌名/歌手/专辑)加上
/// 后来补的「显示播放控制」(用户要求"加一个控制键是否展示"的开关)。
struct NotchExpandedPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("展开态"), width: 240) {
            NotchBehaviorItemRows(items: [
                .expandedNextLine, .expandedShowsControls, .expandedShowsLyricsOffset, .expandedShowsArtwork,
                .expandedShowsTrackTitle, .expandedShowsArtist, .expandedShowsAlbum,
            ])
        }
    }
}


// MARK: - 灵动岛「全部设置」抽屉

/// 灵动岛的「全部设置」抽屉(2026-08-31)。用户看过第一版(只收了「显示歌词」/「暂停缩回」/
/// 「显示音浪」三项)之后要求补齐:工具栏那四个浮层入口(风格/屏幕/左耳/右耳)和宽度调整条
/// 这些**原有**配置项,也该能在"全部设置"里找到——完全对齐 `OverlayAllSettingsDrawer` 的
/// 定位:不是"新配置项的收纳盒",是**这个形态全部可配项的完整兜底通路**(键盘/VoiceOver/
/// "我就想找个开关,不想点开浮层"的场合)。
///
/// ⚠️ 顶部工具栏(风格/屏幕/左耳/右耳)和编辑台里那条宽度调整条**本体不受影响**——那条
/// 横向空间已经被反复验证过是"刚好塞满、不能再挤"的上限(见 NotchEditorStage.toolbar 头
/// 上那条⚠️)。这里是**多开一条兜底入口**,不是挪走原来那条:每一行都复用浮层/调整条背后
/// 那份同源组件或同一个 AppSettings 键,不是另起一份平行实现(同悬浮歌词那边的纪律,漏改
/// 一处的代价是"两个入口改出两个不同的效果")。
///
/// 各行的来源:
///   - 风格 → `NotchStyleSettingsRows()`(跟工具栏「风格」浮层同一份)
///   - 左耳 / 右耳 → `NotchEarSettingsRows(side:)`(跟工具栏那两个浮层同一份)
///   - 屏幕 → `NotchScreenSettingsRows(onScreenChange:)`(跟工具栏「屏幕」浮层同一份;
///     这里没有编辑台预览要刷新,`onScreenChange` 传空闭包——真窗口的更新在这个组件内部
///     已经带着 `notchOverlayEnabled` 守卫做完了,见该组件本体)
///   - 宽度 → 本文件新写的 `widthRow`,只读调用 `NotchEditorStage.usableWidthRangeOnCurrentScreen`
///     / `.effectiveWidth(baseWidth:)`(2026-08-31 归 ls-Rocky 维护的静态 API,这里不改
///     它们的实现,只是又开一个调用点——跟悬浮歌词抽屉里那根 step 10 的滑杆同一个模式:
///     跟画布上那条 step 2 的调整条是同一个值的两个入口)
///   - 歌词行(显示歌词 / 显示封面+位置)/ 行为(暂停缩回)/ 展开态(下一句预览 / 显示封面 /
///     显示歌名 / 显示歌手 / 显示专辑)→ 各自一个 `SettingsCardHeader` + `NotchBehaviorItemRows`,
///     item 子集跟工具栏第二行三个浮层(`NotchLyricRowPopover`/`NotchBehaviorPopover`/
///     `NotchExpandedPopover`)逐字相同——不是重新分组一遍,是照抄浮层已经定好的分类,两边
///     改哪个子集都不会漂。2026-09-01 之前这 8 项在这里是 `NotchBehaviorItem.allCases`
///     铺平的一整块、中间没有任何分隔标题,用户反馈"混乱、没分类";按浮层的分类拆成三个
///     带标题的组,跟上面「风格」「左耳」「右耳」「屏幕」的呈现方式取齐。
///   - 显示音浪 → `NotchEqualizerRow()`,全局兜底,跟「左耳」「右耳」浮层顶部那两个独立
///     开关行(`NotchEarSettingsRows.equalizerRow`)不是同一份组件复用,是两种粒度的入口:
///     那边答的是"这只耳朵现在开不开",这里答的是"不管哪只耳朵,一眼看总状态"——两边
///     共享同一对 `notchShowsEqualizer`/`notchEqualizerEar`,改哪边都会同步反映到另一边,
///     只是渲染各自独立,没有强行合并成一份组件(合并会破坏"左耳/右耳浮层只关心自己"
///     这条既有边界)。
private struct NotchAllSettingsDrawer: View {
    @ObservedObject private var settings = AppSettings.shared

    /// 展开状态用 @State 而不是 @AppStorage,理由同 OverlayAllSettingsDrawer:设计要求
    /// "默认折叠",@AppStorage 会把上次展开的样子带到下次打开设置窗口。
    @State private var isExpanded = false

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()
                styleGroup
                CardDivider()
                earGroup
                CardDivider()
                screenGroup
                CardDivider()
                widthRow
                CardDivider()
                lyricRowGroup
                CardDivider()
                behaviorGroup
                CardDivider()
                expandedGroup
                CardDivider()
                NotchEqualizerRow()
            }
        }
        // 理由同 OverlayAllSettingsDrawer:展开/收起的动画挂在改状态那一处(disclosureHeader
        // 里的 withAnimation),不挂在卡片上——挂在卡片上会把同一个事务里任何不相干的布局
        // 变化(比如「显示音浪」展开时下面多长出的耳朵选择行)一起带动起来。
    }

    // MARK: - 各组

    private var styleGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("风格"))
            CardDivider()
            NotchStyleSettingsRows()
        }
    }

    private var earGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("左耳"))
            CardDivider()
            NotchEarSettingsRows(side: .left)
            CardDivider()
            SettingsCardHeader(title: L10n.t("右耳"))
            CardDivider()
            NotchEarSettingsRows(side: .right)
        }
    }

    private var screenGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("显示在哪块屏幕"))
            CardDivider()
            NotchScreenSettingsRows(onScreenChange: {})
        }
    }

    /// item 子集跟工具栏「歌词行」浮层(`NotchLyricRowPopover`)逐字相同,理由见本文件上方
    /// `NotchAllSettingsDrawer` 的分组说明。
    private var lyricRowGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("歌词行"))
            CardDivider()
            NotchBehaviorItemRows(items: [.showLyrics, .lyricRowArtwork])
        }
    }

    /// item 子集跟工具栏「行为」浮层(`NotchBehaviorPopover`)逐字相同。
    private var behaviorGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("行为"))
            CardDivider()
            NotchBehaviorItemRows(items: [.collapseWhenPaused])
        }
    }

    /// item 子集跟工具栏「展开态」浮层(`NotchExpandedPopover`)逐字相同。
    private var expandedGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("展开态"))
            CardDivider()
            NotchBehaviorItemRows(items: [
                .expandedNextLine, .expandedShowsControls, .expandedShowsLyricsOffset, .expandedShowsArtwork,
                .expandedShowsTrackTitle, .expandedShowsArtist, .expandedShowsAlbum,
            ])
        }
    }

    /// 宽度滑杆。编辑台里那条调整条改的是同一个值,这里是它的兜底通路。
    ///
    /// ⚠️ 三条 ls-Rocky 核过的坑,都不是随手能猜对的:
    ///   ① 区间/读数走 `NotchEditorStage` 那两个**静态**入口(`usableWidthRangeOnCurrentScreen`
    ///      / `effectiveWidth(baseWidth:)`),自己现算屏幕几何、不碰 `.shared`——这里没有
    ///      编辑台的 chrome 可以问。
    ///   ② 读数必须是 `effectiveWidth(baseWidth:)` 算出来的**真实**卡片宽度,不能直接显示
    ///      `notchContentWidth` 这个设定值:两者在下界附近会不一样(存过更小的旧值,或者
    ///      换了耳朵配置把下限抬上去了),直接显示设定值会出现"滑杆停在最左、卡片却是另一个
    ///      宽度"。
    ///   ③ 写回必须带 `notchOverlayEnabled` 守卫——`NotchLyricsWindowController.shared` 是
    ///      `static let`,哪怕只是读一下也会执行 init() 建出整扇窗;灵动岛关着的用户碰一下
    ///      这根滑杆,不该凭空多一套窗口。
    /// step 10(不是画布那条的 2):这里是兜底通路,旁边没有实时预览,粗一点好落值;落盘值
    /// 不是 10 的倍数也没关系,step 只约束滑杆自己产生的值,不约束模型(悬浮歌词那根已经
    /// 验过这条)。
    private var widthRow: some View {
        SettingsRow(icon: "arrow.left.and.right", title: L10n.t("宽度")) {
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { NotchEditorStage.effectiveWidth(baseWidth: settings.notchContentWidth) },
                    set: { newValue in
                        guard newValue != settings.notchContentWidth else { return }
                        settings.notchContentWidth = newValue
                        if settings.notchOverlayEnabled {
                            NotchLyricsWindowController.shared.applyContentWidthSetting()
                        }
                    }
                ), in: NotchEditorStage.usableWidthRangeOnCurrentScreen, step: 10)
                .frame(width: 150)
                Text(String(format: L10n.t("%@pt"),
                            "\(Int(NotchEditorStage.effectiveWidth(baseWidth: settings.notchContentWidth)))"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    // MARK: - 抽屉头

    /// 折叠/展开那一行,逐字复用 OverlayAllSettingsDrawer.disclosureHeader 的写法:用
    /// Button 手搭而不是 DisclosureGroup(后者的三角形+缩进排版跟这套卡片组件对不上),
    /// 整行(含右边留白)都可点。
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

/// 「显示音浪」开关 + (开着时才出现的)贴哪只耳朵选择(2026-08-31)。
///
/// 播放指示条(音浪/EqualizerBars)原来写死贴在右耳外缘,不是 `NotchEarModule` 的可配
/// 模块(它是播放指示灯不是内容,这条边界没变)。用户看过左右耳配置后提出两点:①右耳
/// 固定带着音浪不太合适——想要的话应该能关;②但也想要"歌手 + 音浪同时显示",而这本来
/// 就是现有行为(音浪跟耳朵内容共存,只在那只耳朵选了「播放控制」时才让位)。于是拍板
/// 加一个独立开关(默认开,维持既有行为)+ 一个左右耳选择器,而不是把音浪塞进
/// `NotchEarModule` 的选项列表——塞进去反而会破坏"两种形态都住同一侧、收放切换不横跳"
/// 这条音浪本来的设计初衷(见 NotchEarModule 上方那段⚠️)。
///
/// 副作用值得在这里写清楚:关掉音浪能让灵动岛的最小宽度显著变窄(两只耳朵恒等宽,音浪
/// 占的那部分宽度会在总宽度上翻倍算);具体贴哪只耳朵不影响下限(左右对称)。精确数字
/// 因屏幕/刘海尺寸而异,不在这里写死,交给 `NotchLyricsWindowController.minEarWidth` 的
/// 宽度那条链自己算(那条链 2026-08-31 归 ls-Rocky 维护,见 docs/features/05-notch.md
/// 「宽度」节)。
///
/// ⚠️ 落点四经反复,均系同一天(2026-08-31):最初塞进「风格」浮层(用户要求拆出来)→
/// 拆成常驻的独立卡(用户嫌它孤零零杵在「行为」栏下面,要求"要么挪进预览框那部分,要么你
/// 找地方")→ 设计过"并进工具栏当第五个入口"的方案,但同事 ls-Rocky 离屏量过:工具栏
/// 现状 4 个入口的中文自然宽已经 498pt、窄档舞台可用宽度上限 499pt,只剩 1pt 余量,
/// 5 个入口不管怎么压摘要/间距,中英文都装不进去(中文最好 592pt、英文 769pt),这条路线
/// 没有落地 → **最终**改放进「左耳」「右耳」浮层顶部,各一个独立开关行,用分割线跟下面
/// `NotchEarModule` 的单选列表隔开、可以同时选中(见 `NotchEarSettingsRows.equalizerRow`)。
/// 这份完整卡片(开关 + 分段选择器二合一)不再对应任何工具栏入口,只作为「全部设置」抽屉
/// 里的全局兜底——两只耳朵各自的开关是"就地配当前这只耳朵",这份是"不管哪只耳朵,一眼
/// 看总状态"。
private struct NotchEqualizerRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                icon: "waveform",
                title: L10n.t("显示音浪"),
                help: L10n.t("播放指示条，跟着音量起伏摆动，跟耳朵里选的内容共存显示（选了「播放控制」时让位）。关掉之后两只耳朵纯按你选的模块渲染，灵动岛也能配得更窄。")
            ) {
                Toggle("", isOn: $settings.notchShowsEqualizer)
            }
            if settings.notchShowsEqualizer {
                CardDivider()
                SettingsSubRow(title: L10n.t("贴哪只耳朵")) {
                    Picker("", selection: $settings.notchEqualizerEar) {
                        Text(L10n.t("左耳")).tag(NotchEqualizerEar.left)
                        Text(L10n.t("右耳")).tag(NotchEqualizerEar.right)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
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
    // App 本体版本 vs 打包进这份 App 的 collector 版本是否一致(2026-08-31 加,见
    // CollectorServiceManager.bundledCollectorVersion 头注)。nil = 一致或没法判断(两种
    // 都不该报警,见 refreshCollectorVersionCheck);非 nil 才代表真的查到了不一致,存的是
    // (App 版本, collector 版本)这一对,卡片直接把两个号都摊出来给用户看。
    //
    // 只在 .onAppear 查一次,不放进每 2 秒一拍的 refreshCollectorState——那条路径要跑得
    // 够轻(只是解析 `launchctl print` 的文本输出),而这里要真的 spawn 一次 collector
    // 子进程,版本号在一次设置页停留期间不会变,没必要反复起进程。
    @State private var collectorVersionMismatch: (appVersion: String, collectorVersion: String)?
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
            browserAutomationCard
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
            SettingsCardHeader(title: L10n.t("播放器（可多选）"))
            SettingsRawRow {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(PlaybackPlayer.displayOrder) { player in
                        PlayerChoiceCard(player: player, isSelected: features.players.contains(player)) {
                            toggleSelectedPlayer(player)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// 2026-09-01 从单选换成多选:点一下切换这个播放器的选中状态,选中的会同时高亮。
    /// 「自动识别」跟具体播放器不是互斥关系,可以一起勾——见 PlaybackPlayerPreference
    /// 的注释,勾了自动识别之后它按超集处理,不会因为同时也勾了具体播放器就退化。
    ///
    /// ⚠️ 不能取消到空集:选中集合永远至少留一个,跟 LyrimuseCore
    /// PlaybackPlayerPreference.selected/collector resolvePlayers 的"保证非空"这条
    /// 不变量对称——真放任清空,下一次 collector 重启读到的会是"什么都没选"这个非法
    /// 状态(两侧都会各自兜底成 auto,但界面会有一瞬间显示"什么都没选中",观感是错的)。
    private func toggleSelectedPlayer(_ player: PlaybackPlayer) {
        if features.players.contains(player) {
            guard features.players.count > 1 else { return }
            features.players.remove(player)
        } else {
            features.players.insert(player)
        }
        Task { await features.save() }
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
               observedAt: seen.at, isAutoDetect: features.players.contains(.auto), now: Date(),
               isAccepted: { TrustedPlayers.isAccepted($0) }) {
            SettingsCard {
                SettingsRow(
                    // 2026-09-01 补上真图标(用户点名)。跟隔壁「已信任的其它播放器」那张卡
                    // 2026-08-25 那次改动是同一件事、同一份取图逻辑(AppIconResolver):那次
                    // 的理由是"一张卡里六个内置播放器都亮出真图标,紧接着这张卡却清一色一个
                    // 通用印章图标,两张卡放在一起会显得不搭",而这张「发现未知播放器」卡当时
                    // 漏了 —— 它恰恰是最需要图标的一张:另外两张卡里的 App 用户本来就认识,
                    // 这张问的是"这个你没见过的 App 要不要信任",图标正是他判断"这是我刚在用
                    // 的那个浏览器"最快的那条线索,比 bundle id 那行小字快得多。
                    //
                    // 取不到(理论上不太可能:它此刻正在报播放,必然装着)才退回原来那个虚线
                    // 问号 —— 那个占位本身仍然是对的:"这个 App 是谁我们还不确定"。
                    icon: "questionmark.app.dashed",
                    iconImage: AppIconResolver.icon(forBundleID: seen.bundleID),
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
        if features.players.contains(.auto), notificationsDenied {
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
                            Task {
                                await features.untrust(bundleID: bundleID)
                                // ⚠️ **取消信任必须连带解除它的所有平台配对**(2026-09-01)。
                                //
                                // 「信任」和「配对」是两个存储(features.json 的 trusted_players
                                // / AppSettings 的 browserPlatformPairs),而这个按钮以前只动前者
                                // —— 于是能漂出一个**看着在工作、其实全程被丢弃**的状态:浏览器
                                // 还挂在「网页播放器」卡里、探针照常跑,但它的播放因为不在信任
                                // 列表里被整条丢掉,"发现未知播放器"那张卡还会重新冒出来。
                                //
                                // 用户实测撞上(原话「这个怎么还需要在播放的时候单独信任,可以
                                // 前置吗」):Safari 的 browserPlatformPairs 里还在,trusted_players
                                // 键却整个没了 —— 他先配对、后在这张卡上点了「移除」。
                                //
                                // 方向是**单向**的:取消信任 → 一并解除配对(不信任它,配对就没有
                                // 任何意义);而「移除配对」**不**取消信任 —— 信任的语义比配对宽
                                // (它还管"这个 App 的播放算不算数"),而且一个浏览器可能配了多个
                                // 平台,退出其中一个不代表不要它了。
                                unpairBrowserEverywhere(bundleID)
                            }
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

    // MARK: - 浏览器歌词同步权限(2026-08-31,平台↔浏览器配对模型)

    /// (历史)"一键开启"按钮点下去之后的临时状态。那条路 2026-09-01 整条移除了,只在这次设置窗口的会话里有效(重开设置就
    /// 重新读一次 `BrowserAutomationPermission.status` 的实时状态,不持久化)。

    /// 某个平台还能新配对的浏览器:这台机器上**装了**(`BrowserAutomationPermission.
    /// isInstalled`)+ 引擎受支持 + 还没配过这个平台。
    ///
    /// ⚠️ **信任是候选的一个来源,不是候选的前提** —— 这两件事 2026-08-31 和 09-01 各定过
    /// 一半,别再把其中一半当成全部:没信任过的已安装内置浏览器**照样列出来**(选中时
    /// `trustAndPairBrowser` 一步自动信任+配对,不逼用户先去那个浏览器里放首歌被动等检测);
    /// 而**已经信任过的浏览器也一定要列出来**,哪怕它不在内置名单、也没被手动加过。按
    /// `knownBrowserBundleIDs` 的固定顺序展示,不是字典序。Firefox 这类不受支持的内核
    /// 原样不出现在候选里,不是"报不支持",是这个功能对它压根不适用(见 BrowserPositionProbe
    /// 头注)。
    private func addablePlatformBrowsers(platformID: String) -> [String] {
        let paired = settings.browserPlatformPairs[platformID] ?? []
        let known = BrowserAutomationPermission.knownBrowserBundleIDs
        // 第二段有**两个来源**,合并去重:
        //   ① 用户自己从「应用程序」里挑进来的(`manualBrowserFamilies`);
        //   ② **已经信任过的播放器里,凡是驱得动的浏览器**(2026-09-01 用户原话:「已经被
        //      信任了,就应该出现在这个列表里面,这个逻辑还是要的」)。②这一路必须有:信任
        //      本身就是一次显式的用户动作,而它可以发生在配对之外 —— 用户在「发现未知播放器」
        //      卡里点信任、或者配对过又移除了配对(那会顺手忘掉 `manualBrowserFamilies` 里
        //      的登记,见 `forgetManualBrowserIfUnpaired`),两种情况下它都还在信任列表里、
        //      却进不了候选。用户看到的就是"下面明明信任着 Doubao Browser,上面菜单里没有它"。
        //      判据用 `resolvedFamily`(会现场读 sdef)而不是 `family` —— 信任列表里只有
        //      bundle id,从没登记过引擎族。
        var extras = Set(settings.manualBrowserFamilies.keys)
        extras.formUnion(features.trustedPlayers.keys.filter {
            BrowserAutomationPermission.isInstalled(bundleID: $0)
                && BrowserAutomationPermission.resolvedFamily(forBundleID: $0) != nil
        })
        // 内置那份固定顺序在前,第二段按名字排在后面 —— 后者数量不定,混进固定顺序里会让
        // 内置那几个的位置随"加过谁"漂移。
        let rest = extras.subtracting(known)
            .sorted { (FeatureSettingsStore.appDisplayName(forBundleID: $0) ?? $0)
                        .localizedCaseInsensitiveCompare(FeatureSettingsStore.appDisplayName(forBundleID: $1) ?? $1) == .orderedAscending }
        return (known + rest)
            .filter { BrowserAutomationPermission.isInstalled(bundleID: $0) && !paired.contains($0) }
    }

    /// 「从应用程序里选…」那条路失败时要说的话。nil = 没有待展示的失败。
    @State private var browserPickerError: String?

    /// 让用户自己从 /Applications 里挑一个浏览器(2026-08-31,用户原话:「这里点+号出来的
    /// 是否可以加一个选项是自己在本机的应用程序里面选」)。
    ///
    /// 为什么需要这条路:`knownBrowserBundleIDs` 只默认列三个,而那不是 UI 偷懒 —— 是
    /// `chromiumPrefsPaths` 只登记实测验证过的浏览器(见那边注释)。Brave / Vivaldi / Opera /
    /// Chromium / 各种 Beta 通道其实同内核、本来就驱得动,只是没人验过它们的 Preferences 路径。
    ///
    /// ⚠️ **挑中的 App 必须真的驱得动才收下**,判据是它的脚本定义里有没有"执行 JavaScript"
    /// 那条命令(`BrowserAutomationPermission.detectedFamily`,认 AppleScript 四字码不认名字)。
    /// 判不出来就**拒收并说清理由**,不能放进去一个永远不会工作的配对 —— 那比列表里没有它
    /// 更糟:用户会以为配好了,然后花时间去查"为什么歌词进度还是不同步"。
    private func chooseBrowserFromApplications(platformID: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.t("选择")
        panel.message = L10n.t("挑一个用来播放这个网站的浏览器")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            browserPickerError = L10n.t("读不出这个应用的标识，换一个试试。")
            return
        }
        // 已经认识引擎族的(内置那几个、代码里适配着但不默认展示的 Arc、或者之前加过的)
        // 不必再判一次 —— 但**仍然要登记成"用户自己选的"**:否则像 Arc 这种"适配全在、只是
        // 不进默认名单"的浏览器,选完之后不会出现在「+」菜单里,下次想再配一个平台还得重新
        // 走一遍文件选择器。`rememberManualBrowser` 自己会跳过内置那几个。
        if let known = BrowserAutomationPermission.family(forBundleID: bundleID) {
            rememberManualBrowser(bundleID, family: known)
            trustAndPairBrowser(bundleID, platformID: platformID)
            return
        }
        guard let family = BrowserAutomationPermission.detectedFamily(forAppAt: url) else {
            // 用 Finder 显示的那个名字(本地化过、跟用户在「应用程序」里看到的一致),
            // 而不是 bundle id 或者文件名。
            let name = FileManager.default.displayName(atPath: url.path)
            browserPickerError = String(
                format: L10n.t("「%@」不能用来同步歌词进度。这项功能要靠浏览器执行一小段 JavaScript 来读播放进度，而这个应用没有提供对应的脚本命令——Firefox 这类内核，以及非浏览器的应用，都属于这种情况。"),
                name)
            return
        }
        rememberManualBrowser(bundleID, family: family)
        trustAndPairBrowser(bundleID, platformID: platformID)
    }

    /// 把"用户自己从应用程序里挑过这个浏览器"这件事记下来,让它此后出现在「+」菜单里。
    ///
    /// 双写:AppSettings 负责持久化,`BrowserAutomationPermission` 负责让本次运行立刻认它
    /// (同 `pairBrowser` 那条注释里的模式)。只写一边的话要么关了 App 就忘,要么这次加完
    /// 头像点开还是"不支持"。
    ///
    /// ⚠️ **内置名单里的直接跳过**:它们本来就默认展示,再记一份是冗余状态,而
    /// `addablePlatformBrowsers` 拼菜单时又要把它们从手动那段里滤掉,两处口径容易走散。
    /// 反过来,**不在内置名单、但 `family(...)` 本来就认识的(Arc)必须记** —— 那正是这个
    /// 函数存在的理由,见 `knownBrowserBundleIDs` 头注。
    private func rememberManualBrowser(_ bundleID: String, family: BrowserAutomationPermission.Family) {
        guard !BrowserAutomationPermission.knownBrowserBundleIDs.contains(bundleID) else { return }
        guard settings.manualBrowserFamilies[bundleID] != family.rawValue else { return }
        var families = settings.manualBrowserFamilies
        families[bundleID] = family.rawValue
        settings.manualBrowserFamilies = families
        BrowserAutomationPermission.manuallyAddedFamilies[bundleID] = family
    }

    /// 选中一个还没信任过的浏览器时,先信任、再配对——一步到位,不逼用户先去那个浏览器
    /// 播放点什么、等 Lyrimuse 被动检测到再手动信任。`trust(bundleID:)` 本身没有"必须
    /// 观测到过播放"这类前置校验(读过 FeatureSettingsStore.trust 源码确认过),纯粹是
    /// "写进信任字典"这一步,可以在用户主动选择时直接调用。
    ///
    /// `Task { }` 在 MainActor 隔离的 View 操作回调里创建,会继承 MainActor——`await` 之后
    /// 直接调 `pairBrowser`(同样 MainActor 隔离)不需要额外包 `MainActor.run`,跟
    /// `unknownPlayerCard` 里 `Task { await features.trust(...) }` 是同一个既有写法。
    private func trustAndPairBrowser(_ bundleID: String, platformID: String) {
        // ⚠️ **配对先写,信任后跑,两件事互不等待**(2026-09-01 修,用户报「我在加了新浏览器
        // 之后过了很久才在这边出现图标」)。
        //
        // 头像那一行铺的是 `settings.browserPlatformPairs`(见 `browserPlatformCard`),
        // 写它是纯本地、瞬时的。而 `features.trust` 里那句 `save()` 会走一整套 **collector
        // 重启**:`CollectorRestartCoordinator` 0.5 秒去抖 → `launchctl kickstart -k` →
        // 轮询到一个**新 pid** 才返回,确认超时 3 秒(`CollectorControl.restartConfirmTimeout`)。
        // 也就是说最坏情况要 3.5 秒以上,重启失败还会把这 3.5 秒整个耗满。原来的顺序把这套
        // 重启**夹在**"用户在菜单里点了那个浏览器"和"头像出现"之间,连带下面那个自动展开的
        // 气泡也一起被推后 —— 用户看到的就是"点完什么都没发生,过一会儿才蹦出来"。
        //
        // 两者之间没有依赖:信任写的是 features.json(给 collector 看,决定它采不采纳这个
        // App 上报的播放),配对写的是 AppSettings(给这张卡和探针看)。谁先谁后都不改变最终
        // 状态;失败处理也一样 —— `trust` 的返回值本来就没人接,重启失败时配对照样成立。
        // ⚠️ **先把引擎族落盘再配对**(2026-09-01)。菜单里可能列着一个"已信任、引擎族是
        // 这次渲染现场判出来的"条目(见 `addablePlatformBrowsers` 第②路) —— 那个判定结果
        // 只活在内存缓存里,不落盘的话配对之后 `family(...)` 仍然返回 nil,探针
        // (`kickIfNeeded`)和自检(`runBrowserSelfTest`)都会在第一道 guard 上直接返回,
        // 表现是"配上了、头像也有了,却永远不同步、连检测按钮都不工作"。
        // `rememberManualBrowser` 自己跳过内置那几个。
        if let family = BrowserAutomationPermission.resolvedFamily(forBundleID: bundleID) {
            rememberManualBrowser(bundleID, family: family)
        }
        pairBrowser(bundleID, platformID: platformID)
        Task {
            if features.trustedPlayers[bundleID] == nil {
                await features.trust(bundleID: bundleID)
            }
        }
        Task {
            // ⚠️ 配对成功后**直接把那个浏览器的气泡打开**(2026-09-01)。
            //
            // 在此之前,选完一个浏览器界面上只有两处变化:头像那一行多一个 22pt 的小图标、
            // 下面「已信任的其它播放器」多一行 —— 而真正要做的两件事(开浏览器自己那道 JS
            // 开关、给系统自动化授权)全藏在"点那个小图标"后面,没有任何指引。用户原话:
            // 「选完之后除了下面多一行,左边多一个图标,指引太少了,不知道要去点击图标下一步
            // 授权,帮我衔接起来」。
            //
            // 自动展开是**指引**不是**代劳**:里面的按钮仍然要用户自己点。「请求系统授权」
            // 会后台拉起那个浏览器、「打开该浏览器」会抢焦点 —— 都不该在"我只是把它加进
            // 列表"这个动作里顺带发生。
            //
            // ⚠️ **必须让出一拍再设**,不能紧跟着 `pairBrowser` 同步设:
            //   ① 承载 `.popover` 的那个头像按钮是**这次配对才出现**的(它来自
            //      `pairedBundleIDs`,而那份数据正是进这个 Task 之前那句 `pairBrowser`
            //      刚写的)。同一次 SwiftUI 更新里
            //      "视图刚被插入"+"要求它呈现 popover"是 macOS 上经典的呈现不出来。
            //   ② 这条路径的触发点是 `Menu` 里的一个 `Button` —— 此刻那个 NSMenu 正在
            //      收起,在它的关闭动画里挂一个新的 popover 同样容易被吞掉。
            // 250ms 覆盖菜单收起那一下,肉眼上仍然是"选完就弹出来"。
            try? await Task.sleep(nanoseconds: 250_000_000)
            expandedBrowserBundleID = bundleID
            expandedBrowserPlatformID = platformID
            // 2026-08-31 用户报:「并不是点击自动信任之后就弹出授权框的,是在我实际通过这个
            // 浏览器播放音乐的时候才弹出」。原因是这里一共有**三道门**,而"信任+配对"只走完
            // 前两道 —— ①Lyrimuse 自己的信任列表(features.json)、②浏览器自己那道"允许
            // Apple Events 里的 JavaScript"开关、③**系统的自动化(TCC)授权**。第③道以前
            // 完全没人主动触发,只能等 `BrowserPositionProbe` 第一次真的发 Apple Event 时由
            // 系统弹出 —— 而那要等到用户真的用这个浏览器放歌。
            //
            // ⚠️ **只在浏览器已经在跑时才问**。目标 App 没在运行时系统弹窗压根不出现
            // (2026-07-24 实测坐实,见 MusicAutomationPermission.requestWithTimeout 上那段),
            // 要弹就得先后台把它启动起来 —— 而用户点的是"把这个浏览器加进列表",不是"现在
            // 把我的浏览器打开"。没在跑的那条路交给气泡里那个显式的「请求系统授权」按钮。
            guard MusicAutomationPermission.isRunning(bundleID: bundleID) else { return }
            _ = await MusicAutomationPermission.requestWithTimeout(
                bundleID: bundleID, launchIfNeeded: false)
            automationRefreshTick &+= 1
        }
    }

    /// 请求过系统授权之后强制重算气泡 —— 状态是同步现读的(见 `browserPermissionPopover`),
    /// 没有 @Published 可依赖,靠这个计数器让 SwiftUI 知道该重新读一次。
    @State private var automationRefreshTick = 0

    /// 显式请求某个浏览器的系统自动化授权。跟配对时那次的区别只有一个:**允许后台启动**
    /// 那个浏览器(`launchIfNeeded: true`)—— 用户是主动点的这个按钮,把目标拉起来是完成
    /// 他这个请求所必需的一步,不是顺带的副作用。
    private func requestBrowserAutomation(bundleID: String) {
        Task {
            _ = await MusicAutomationPermission.requestWithTimeout(
                bundleID: bundleID, launchIfNeeded: true)
            automationRefreshTick &+= 1
        }
    }

    /// 菜单里给还没信任过的候选加一句提示,别让用户点了之后才发现"顺带把这个浏览器也加进了
    /// 通用信任列表"这件事很意外。
    private func addBrowserMenuLabel(_ bundleID: String) -> String {
        let name = FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
        guard features.trustedPlayers[bundleID] == nil else { return name }
        return name + L10n.t("（未信任，选择后自动信任）")
    }

    // 配对/取消配对都走同一套"改 AppSettings(持久化)+ 同步进
    // BrowserPositionProbe.shared(让探针立刻生效)"双写,跟 romanizationScripts 那一档
    // 完全同一个模式(见 AppSettings.browserPlatformPairs 注释)——只写一边的话,要么关了
    // App 就忘,要么改了要等下次启动才生效。
    private func pairBrowser(_ bundleID: String, platformID: String) {
        var pairs = settings.browserPlatformPairs
        pairs[platformID, default: []].insert(bundleID)
        settings.browserPlatformPairs = pairs
        BrowserPositionProbe.shared.platformBrowserPairs = pairs
    }

    /// 把这个浏览器从**所有**平台的配对里摘掉。取消信任时用,理由见那个按钮上的⚠️。
    private func unpairBrowserEverywhere(_ bundleID: String) {
        var pairs = settings.browserPlatformPairs
        var changed = false
        for (platformID, ids) in pairs where ids.contains(bundleID) {
            var next = ids
            next.remove(bundleID)
            if next.isEmpty { pairs.removeValue(forKey: platformID) } else { pairs[platformID] = next }
            changed = true
        }
        // 相等守卫:@Published 是 willSet 语义,等值赋值照样广播 objectWillChange。
        guard changed else { return }
        settings.browserPlatformPairs = pairs
        BrowserPositionProbe.shared.platformBrowserPairs = pairs
        forgetManualBrowserIfUnpaired(bundleID)
    }

    /// 用户手动挑进来的浏览器,**最后一个配对也被移除时一起忘掉**(2026-09-01)。
    ///
    /// ⚠️ 不忘的话它会**永远**留在「+」菜单里:`manualBrowserFamilies` 在此之前全仓只有
    /// 一处写入(`chooseBrowserFromApplications`)、**零处删除**,用户试着加过一个浏览器就再也
    /// 拿不掉了。用户原话:「剩下的只有用户自己选了新的浏览器才会显示在这里」——一个已经被
    /// 他移除干净的浏览器,不该继续占着那份"用户自己选的"名额。
    ///
    /// ⚠️ 只在**这一次用户主动移除配对**时做,不做启动时的批量清理 —— 后者是在用户没做任何
    /// 动作的时候替他删状态,跟"卸载了的浏览器保留配对记录"那条既有原则冲突(见
    /// `browserPlatformCard` 头注)。
    ///
    /// ⚠️ 判据是"一个配对都不剩"而不是"移除了这个平台的配对":同一个浏览器可以配多个平台,
    /// 只撤掉其中一个的时候它显然还要留着。手动加进来的浏览器一加进来就**同步**被配对了
    /// (`chooseBrowserFromApplications` → `trustAndPairBrowser` → `pairBrowser`,后者不在
    /// await 之后),所以不存在"刚加完还没配上"这个中间态被误清的窗口。
    ///
    /// 忘掉的成本很低:再要它时「从应用程序中选择…」重新挑一次即可 —— 这份字典存的本来就是
    /// 一个**判定结果的缓存**(那个 App 的引擎族),不是用户精心配的偏好。
    private func forgetManualBrowserIfUnpaired(_ bundleID: String) {
        guard settings.manualBrowserFamilies[bundleID] != nil else { return }
        guard !settings.browserPlatformPairs.values.contains(where: { $0.contains(bundleID) }) else { return }
        var families = settings.manualBrowserFamilies
        families.removeValue(forKey: bundleID)
        settings.manualBrowserFamilies = families
        BrowserAutomationPermission.manuallyAddedFamilies.removeValue(forKey: bundleID)
    }

    private func unpairBrowser(_ bundleID: String, platformID: String) {
        var pairs = settings.browserPlatformPairs
        pairs[platformID]?.remove(bundleID)
        if pairs[platformID]?.isEmpty == true { pairs.removeValue(forKey: platformID) }
        settings.browserPlatformPairs = pairs
        BrowserPositionProbe.shared.platformBrowserPairs = pairs
        forgetManualBrowserIfUnpaired(bundleID)
    }

    /// 哪个浏览器的头像正在展开详情气泡——同一时间只有一个,点另一个头像会先收起上一个
    /// (`.popover` 各自绑定自己的 bool,靠这两个共享的可选值天然互斥)。
    ///
    /// ⚠️ **必须跟 `expandedBrowserPlatformID` 成对使用,单靠 bundleID 不够**(2026-09-01
    /// 修复:用户给 YouTube Music 也配对了 Arc——Arc 这时候**同时**挂在 YouTube Music 和
    /// Spotify 两张平台卡下面,`browserAvatarButton` 会为同一个 bundleID 渲染出两个头像
    /// 按钮。之前 `.popover(isPresented:)` 只判 `expandedBrowserBundleID == bundleID`,
    /// 于是给 YouTube Music 配对完之后设置这一个字段,两张卡上"bundleID 相同"的头像会
    /// 同时满足呈现条件——SwiftUI 实际只会呈现其中一个,但选中的是哪一个不受调用方控制,
    /// 表现就是用户截图里那样:气泡挂到了 Spotify 那张卡的 Arc 图标上,而用户操作的明明是
    /// YouTube Music。同一个浏览器可以配对给多个平台,bundleID 本身不足以定位"是哪张卡上的
    /// 哪个头像",必须搭配 platformID 才是这张卡片网格里真正唯一的身份。
    @State private var expandedBrowserBundleID: String?
    @State private var expandedBrowserPlatformID: String?

    // 这张卡管的是"浏览器自己加的第二道 JS 执行开关"(跟下面 permissionCard 管的系统级
    // Automation/TCC 授权是两码事,见 BrowserAutomationPermission 头注)。
    //
    // ⚠️ **展示条件是"这台机器上装了受支持的浏览器",不是"已经信任过某个浏览器"**
    // (2026-09-01 改)。原来的条件是后者,理由是"没有可配对对象时展示空卡片只是噪声"——
    // 那条理由在 2026-08-31 之后就不成立了:那天「+」菜单改成了 `trustAndPairBrowser`,
    // **不再要求先信任**,选一个没信任过的浏览器会一步自动信任+配对。也就是说这张卡
    // 从"信任之后才用得上的配置面板"变成了"信任这件事本身的入口"。
    //
    // 旧条件因此制造了一个**鸡生蛋**:没信任过任何浏览器 → 卡片不显示 → 界面上没有任何
    // 地方能发起信任 → 只能靠"真的用浏览器放歌 → 被动检测到未知播放器 → 发现卡/系统通知"
    // 这条**被动**路径绕回来。用户清空全部浏览器配置想重走一遍流程时当场撞上:整张卡
    // 连同 YouTube Music 一起消失,没有入口了。用户原话:「这里的 YouTube Music 应该是
    // 要常驻的」。
    //
    // "不为了'这里没事'而占地方"这条原则**保留**,只是判据换了:装了受支持浏览器 = 真的
    // 有事可做(点开就能配);一台只装了 Firefox 的机器仍然不显示这张卡,因为那台机器上
    // 这个功能确实无从谈起。
    //
    // 2026-08-31 用户要求从"信任了就自动探测"改成显式的"平台↔浏览器配对":按
    // `BrowserPositionProbe.supportedPlatforms` 逐个平台分组,配对之外还提供"添加浏览器"——
    // 没配对过的浏览器完全不会触发后台探测(见 BrowserPositionProbe.kickIfNeeded)。
    //
    // 2026-08-31 用户看过三版设计稿后先选了"头像堆叠·紧凑版"(平台一行:图标+名称+
    // 一叠已配对浏览器的小头像+添加按钮),后来又要求整张卡换成跟上面"播放器"一样的
    // 图标网格风格(截图对比着说的)——两次要求不矛盾:头像/气泡/添加菜单这套交互逐字
    // 保留,只是外层容器从"铺满宽度的一行"换成 PlayerChoiceCard 同款的网格小卡片,让
    // 两张卡在同一页里看起来是同一套视觉语言,不是分别长出来的两种组件。
    @ViewBuilder
    private var browserAutomationCard: some View {
        // 走 `knownBrowserBundleIDs` + 用户手动加过的那批,判据跟 `addablePlatformBrowsers`
        // 里那一道完全同源 —— 那边能列出候选,这边就该把卡片显示出来,两处不该有分歧。
        let anySupportedInstalled = (BrowserAutomationPermission.knownBrowserBundleIDs
            + Array(settings.manualBrowserFamilies.keys))
            .contains { BrowserAutomationPermission.isInstalled(bundleID: $0)
                        && BrowserAutomationPermission.family(forBundleID: $0) != nil }
        if anySupportedInstalled {
            SettingsCard {
                SettingsCardHeader(
                    title: L10n.t("网页播放器（可多选）"),
                    help: L10n.t("网页播放器不会像本地 App 那样主动汇报精确的播放进度，切歌之后需要这个开关才能立刻校准。")
                )
                SettingsRawRow {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(BrowserPositionProbe.supportedPlatforms) { platform in
                            browserPlatformCard(platform: platform)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            // 挂在整张卡上,不是挂在每个平台的小卡上:`browserPickerError` 只有一个,
            // 而 supportedPlatforms 有好几个 —— 每张小卡各挂一个 `.alert` 绑同一个状态,
            // 一次失败会同时触发多个弹窗。
            .alert(
                L10n.t("这个应用用不了"),
                isPresented: Binding(
                    get: { browserPickerError != nil },
                    set: { if !$0 { browserPickerError = nil } })
            ) {
                Button(L10n.t("知道了"), role: .cancel) { browserPickerError = nil }
            } message: {
                Text(browserPickerError ?? "")
            }
            // ⚠️ **回到 Lyrimuse 时重新读一次两道门的状态**(2026-09-01)。
            //
            // 这张卡上所有状态都是**渲染时同步现读**的(浏览器那道 JS 开关读的是它自己的
            // 配置文件、系统自动化授权读的是 TCC),没有任何 `@Published` 可以依赖 ——
            // 也就是说用户按指引跑去浏览器菜单里把开关勾上、再切回来,界面上**什么都不会变**,
            // 得手动把气泡关掉重开(或者点一次「重新检测」)才刷新。用户原话:「那我现在去
            // 打开了,设置里这里要怎么流转状态呢;自动的吗」。
            //
            // 「App 重新变成活跃」正好是这条流程的天然节拍:去浏览器操作这件事**必然**要
            // 切走再切回来。比起给配置文件挂 FSEvents 或者起个定时器轮询,这个信号更准
            // (不会在用户没做任何事的时候空刷)、也更省 —— 而且它同时覆盖另一道门:用户
            // 去「系统设置 → 自动化」里勾完回来,那一行也会跟着更新。
            //
            // 只是让 SwiftUI 重新读一遍,不发起任何 AppleScript/自检 —— 自检有子进程开销,
            // 不该在每次切回 App 时白跑一次(要不要跑由用户点「重新检测」决定)。
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                automationRefreshTick &+= 1
                // ⚠️ **再补一拍**:Chromium 那道开关勾完之后**不是立刻写盘的** —— 它的偏好
                // 走批量延迟提交,用户在浏览器菜单里勾上、两三秒就切回来的话,文件里很可能
                // 还是旧值,上面那次刷新读到的就还是"关"。补这一拍让它过一会儿自己纠正过来,
                // 用户不必再手动做什么。
                //
                // ⚠️ 12 秒是个**留余量的兜底值,不是实测出来的常数** —— 没有公开保证的提交
                // 间隔可依。真要立刻确认,气泡里那个「重新检测」是**不看文件**的活证据
                // (它直接执行一段 JavaScript),那条路任何时候都即时准确。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    automationRefreshTick &+= 1
                }
            }
        }
    }

    /// 跟 `PlayerChoiceCard` 同一套卡片底(10pt 圆角、26×26 图标、`.caption` 文字)，
    /// 图标下面多一行头像+添加按钮,是跟 `PlayerChoiceCard` 相比唯一多出来的内容,交互
    /// 逐字复用 `browserAvatarButton`/`addablePlatformBrowsers`/`trustAndPairBrowser`,
    /// 没有新逻辑。
    ///
    /// ⚠️ 2026-09-01 起这张卡**也有**"选中"这个概念了(用户原话「网页播放器不可以选择
    /// 并高亮吗」):配对了至少一个浏览器就按 `PlayerChoiceCard` 同款样式高亮(强调色描边
    /// +浅色底)——"选中"不是一个新的独立开关,而是直接复用既有的"配了/没配"这个状态,
    /// 配对本身早就是显式的用户动作(点「+」选浏览器),不需要再叠一层"选不选用它"。跟
    /// 配套的功能改动一起做的(见 MediaControlClient.fetchMultiSelectedSnapshot/
    /// collector isTrustedPlayerBundleID):配对的浏览器现在无论有没有勾"自动识别"都会
    /// 被采纳,高亮因此如实反映"这确实是一个会生效的来源",不是纯装饰。整卡仍然不包一个
    /// `Button`(配对的是一组浏览器,不是单选一个),只有头像和"+"各自可点。
    private func browserPlatformCard(platform: BrowserPositionProbe.BrowserMusicPlatform) -> some View {
        // ⚠️ 已配对的头像也要过 `isInstalled` 这道门(2026-08-31 用户拍板)。在此之前只有
        // 「+」菜单的候选过滤了装没装,头像这一侧是直接铺 `browserPlatformPairs` 的 ——
        // 于是"配对过、后来把那个浏览器卸载了"会一直留一个取不到图标的虚线方框
        // (`browserIconView` 的 `app.dashed` 兜底),点开还给一份无意义的权限状态。那是
        // "设置里显示的东西跟实际能用的东西对不上"。
        //
        // ⚠️ **只是不显示,配对记录原样留在 `browserPlatformPairs` 里** —— 装回来自动恢复,
        // 用户不用重配。这跟「指定的屏幕拔掉后自动回落到自动、偏好保留、插回来即恢复」
        // 是同一个口径(见 05-notch.md「显示在哪块屏幕」),不是新发明的处置方式。
        // 也因此**不要**顺手在这里 `unpairBrowser` 去"清理"——那会把用户的配置替他删掉。
        let pairedBundleIDs = (settings.browserPlatformPairs[platform.id] ?? [])
            .filter { BrowserAutomationPermission.isInstalled(bundleID: $0) }
            .sorted()
        let addable = addablePlatformBrowsers(platformID: platform.id)
        return VStack(spacing: 6) {
            if let icon = Self.platformIcon(platform.id) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            Text(platform.displayName)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.primary)
            // 2026-08-31 用户要求头像并排展示,不要重叠(最初版本是负间距叠在一起的
            // "头像堆叠"效果,改成这样更清楚地看出到底配了几个)——这条既有决定原样保留。
            HStack(spacing: 6) {
                ForEach(pairedBundleIDs, id: \.self) { bundleID in
                    browserAvatarButton(bundleID: bundleID, platformID: platform.id)
                }
                // ⚠️ 条件从 `!addable.isEmpty` 放宽成恒真(2026-08-31):内置候选全配完之后
                // 「+」原本整个消失,而菜单里现在还有「从应用程序中选择…」这条路 —— 那时
                // 恰恰是最需要它的时候(装的浏览器不在内置那四个里)。
                do {
                    Menu {
                        ForEach(addable, id: \.self) { bundleID in
                            Button(addBrowserMenuLabel(bundleID)) { trustAndPairBrowser(bundleID, platformID: platform.id) }
                        }
                        Divider()
                        Button(L10n.t("从应用程序中选择…")) { chooseBrowserFromApplications(platformID: platform.id) }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 15))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(pairedBundleIDs.isEmpty ? Color.primary.opacity(0.05) : Color.accentColor.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(pairedBundleIDs.isEmpty ? Color.clear : Color.accentColor, lineWidth: 1.5)
        )
    }

    private func browserAvatarButton(bundleID: String, platformID: String) -> some View {
        Button {
            expandedBrowserBundleID = bundleID
            expandedBrowserPlatformID = platformID
        } label: {
            Self.browserIconView(bundleID: bundleID, size: 22)
                // ⚠️ 角标是自动展开那条的**兜底**:气泡一关就再没有任何提示了,而"还差两步"
                // 这件事必须在卡片上长期看得见,否则用户关掉气泡就回到了原来那个"图标默默
                // 待在那儿、没人告诉我还要干嘛"的状态。
                .overlay(alignment: .topTrailing) {
                    if browserSetupIncomplete(bundleID: bundleID) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white, Color.orange)
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(browserSetupIncomplete(bundleID: bundleID)
              ? L10n.t("还没配置完，点开看看还差什么")
              : L10n.t("已配置好，点开可查看或移除"))
        .popover(isPresented: Binding(
            get: { expandedBrowserBundleID == bundleID && expandedBrowserPlatformID == platformID },
            set: { if !$0 { expandedBrowserBundleID = nil; expandedBrowserPlatformID = nil } }
        )) {
            browserPermissionPopover(bundleID: bundleID, platformID: platformID)
        }
    }

    /// 点头像弹出的详情气泡:图标+名称+两道门的状态+各自的下一步,底下是"移除配对"
    /// (需要时才出现)。跟之前那版详细列表行是同一套状态/文案逻辑
    /// 只是从常驻的卡片行搬进了按需弹出的气泡里。
    /// ⚠️ 这个气泡要说清**两道**门,不是一道(2026-08-31 补的第二道)。浏览器歌词同步一共
    /// 需要三样东西:①Lyrimuse 自己的信任列表(配对这个动作本身就写了)、②浏览器自己那道
    /// 「允许 Apple Events 里的 JavaScript」开关、③**系统的自动化(TCC)授权**。
    /// 改之前这里只显示②,于是③对用户完全不可见 —— 用户报的原话是「并不是点击自动信任
    /// 之后就弹出授权框的,是在我实际通过这个浏览器播放音乐的时候才弹出」:③以前只能等
    /// 探针第一次真的发 Apple Event 时由系统被动弹出。
    private func browserPermissionPopover(bundleID: String, platformID: String) -> some View {
        _ = automationRefreshTick
        let status = BrowserAutomationPermission.status(forBundleID: bundleID)
        // ⚠️ 目标没在跑时 `check` 查不出真实状态(会落进 procNotFound 被当成"还没问过"),
        // 所以用 nil 表示"查不到",**不能**显示成"未授权":那是假阴性,已经授权过的浏览器
        // 一关掉就会被说成没授权。
        let running = MusicAutomationPermission.isRunning(bundleID: bundleID)
        // ⚠️ **实时状态优先,查不到时才拿"自检通过过"当证据**(2026-09-01)。
        //
        // 自检做的是"真的让这个浏览器执行一段 JavaScript" —— 那条 Apple Event 发得出去,
        // 就**证明** TCC 自动化授权当时是通的(不通根本发不到浏览器那一步)。所以在浏览器
        // 没在运行、`check` 查不到的时候,这个既成事实比一句「查不到」有用得多:
        // 在此之前会同时出现「✓ 已生效」和「请求系统授权」,自相矛盾。
        //
        // ⚠️ 但**浏览器在跑时一律以实时结果为准**,不许被这个既成事实盖过 —— 用户后来到
        // 系统设置里撤销授权是真会发生的(这个 App 是 ad-hoc 签名,下一次构建也会让授权
        // 失效),那时必须如实报 denied/notDetermined 并把按钮放出来。
        let liveAutomation: MusicAutomationPermissionStatus? = running
            ? MusicAutomationPermission.check(bundleID: bundleID, askIfNeeded: false)
            : nil
        let verifiedBefore = settings.browserJSVerifiedAt[bundleID] != nil
        let automation: MusicAutomationPermissionStatus? =
            liveAutomation ?? (verifiedBefore ? .authorized : nil)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Self.browserIconView(bundleID: bundleID, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayNameForTrusted(bundleID)).font(.system(size: 13))
                    // ⚠️ 每条状态说明都必须 `.fixedSize(horizontal: false, vertical: true)`
                    // (2026-09-01 用户报「这里文案没显示完整」,截图里两行都被截成一行带省略号)。
                    // 它们没有 `lineLimit`、按理该自己换行,离屏渲染也确实正常折行 —— 问题在
                    // **NSPopover 的尺寸协商**:内容一高,浮层给的高度提议不够,SwiftUI 就把多行
                    // 压成一行加省略号。`fixedSize(vertical:)` 让 Text 报出折行后的真实高度并
                    // 拒绝被压。⚠️ 别删,也别改成 `lineLimit(1)` —— 这几句正是要读全的。
                    Text(browserJSSwitchCaption(bundleID: bundleID, status: status))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(browserAutomationCaption(automation, live: liveAutomation != nil))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // 那道 JS 开关没确认开着时,给出**这个浏览器自己的**菜单路径 + 一个把它唤到
            // 前台的按钮。⚠️ 路径逐个浏览器不一样,别写一份通用文案,见 browserManualEnableHint。
            if !browserJSLikelyWorking(bundleID: bundleID) {
                Text(browserManualEnableHint(bundleID: bundleID))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 自检结果(点过才有)。⚠️ 这是用户手动开完之后**唯一**能确认"做对了没有"的
                // 通路 —— Chromium 系那道开关的状态读不出来(要完全磁盘访问权限),所以
                // 上面那行状态永远是「无法确认状态」。用户原话:「我现在已经手动去打开了,
                // 这个页面怎么回显?没有按钮啊」。
                if let r = browserSelfTestResults[bundleID] {
                    Text(browserSelfTestCaption(r))
                        .font(.system(size: 11))
                        .foregroundStyle(r == .ok ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L10n.t("检测是否已生效")) { runBrowserSelfTest(bundleID: bundleID) }
                        .disabled(browserSelfTestRunning.contains(bundleID))
                    Spacer()
                    // 抢焦点(`activates = true`)是对的 —— 用户点它就是为了立刻去那个浏览器
                    // 操作,跟 `ensureAppRunning` 那种后台预启动是两回事。
                    Button(L10n.t("打开该浏览器")) {
                        guard let appURL = NSWorkspace.shared
                            .urlForApplication(withBundleIdentifier: bundleID) else { return }
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = true
                        NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                    }
                }
            }
            // 已经配好了:不再摆一堆指引,只留结果 + 一个重新检测的入口(开关可能被用户
            // 后来关掉,得给他自己复核的通路)。
            if browserJSLikelyWorking(bundleID: bundleID) {
                if let r = browserSelfTestResults[bundleID] {
                    Text(browserSelfTestCaption(r))
                        .font(.system(size: 11))
                        .foregroundStyle(r == .ok ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L10n.t("重新检测")) { runBrowserSelfTest(bundleID: bundleID) }
                        .disabled(browserSelfTestRunning.contains(bundleID))
                    Spacer()
                }
            }
            if automation != .authorized {
                HStack {
                    Spacer()
                    if automation == .denied {
                        // 被拒绝之后官方没有 API 能再触发一次系统弹窗,只能引导去面板手动开。
                        Button(L10n.t("打开系统设置")) {
                            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
                        }
                    } else {
                        Button(L10n.t("请求系统授权")) { requestBrowserAutomation(bundleID: bundleID) }
                    }
                }
            }
            Divider()
            HStack {
                Button(L10n.t("移除配对")) {
                    unpairBrowser(bundleID, platformID: platformID)
                    expandedBrowserBundleID = nil
                    expandedBrowserPlatformID = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// 自检结果与"正在检测"标记。⚠️ 用 @State 而不是塞进某个 model:它是**这次点击的结果**,
    /// 关掉设置窗就该忘掉,不该持久化(持久化就又造出一份会跟现实脱节的粘滞状态 —— 这个
    /// 气泡今晚已经因为那类状态返工过四次)。
    @State private var browserSelfTestResults: [String: BrowserPositionProbe.SelfTestResult] = [:]
    @State private var browserSelfTestRunning: Set<String> = []

    /// 真的去试一次能不能执行 JavaScript。⚠️ `selfTest` 会起 osascript 子进程并阻塞,
    /// 必须挪出主线程。
    private func runBrowserSelfTest(bundleID: String) {
        guard let family = BrowserAutomationPermission.family(forBundleID: bundleID) else { return }
        browserSelfTestRunning.insert(bundleID)
        browserSelfTestResults[bundleID] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = BrowserPositionProbe.selfTest(bundleID: bundleID, family: family)
            DispatchQueue.main.async {
                browserSelfTestRunning.remove(bundleID)
                browserSelfTestResults[bundleID] = r
                // ⚠️ 通过就**落盘**,让状态真正往前流转 —— 否则关掉设置窗一切归零,用户
                // 每次打开都看见「无法确认状态」、还得再检测一遍(用户原话:「然后呢,
                // 状态怎么进一步流转?卡在这里」)。
                //
                // ⚠️ 反过来,**明确的反证要把这条记录抹掉**(2026-09-01 补):浏览器就开着、
                // 命令也发到它手上了,它却回绝(`blocked`)或干脆不回(`noReply`) —— 那"上次
                // 通过过"就是一句过期的话,留着它下次打开设置窗又会把"已配好"说回去
                // (`browserJSLikelyWorking` 认这条记录),角标也跟着消失。
                // `noTab`/`failed` **不动**:那是"没法判定"(浏览器没开、脚本自身出错),
                // 不是"判定为不行",不该拿它抹掉之前证明过的事实。
                var map = settings.browserJSVerifiedAt
                switch r {
                case .ok:
                    map[bundleID] = Date()
                    settings.browserJSVerifiedAt = map
                case .blocked, .noReply:
                    if map.removeValue(forKey: bundleID) != nil { settings.browserJSVerifiedAt = map }
                case .noTab, .failed:
                    break
                }
                // 成功就顺手刷一次上面那行系统授权状态 —— 自检能过说明 TCC 也是通的。
                automationRefreshTick &+= 1
            }
        }
    }

    private func browserSelfTestCaption(_ r: BrowserPositionProbe.SelfTestResult) -> String {
        switch r {
        case .ok: return L10n.t("✓ 已生效——这个浏览器现在可以被驱动了")
        case .noTab: return L10n.t("这个浏览器没在运行，或者一个标签页都没开——打开它并随便开一个网页，再检测一次")
        case .blocked: return L10n.t("还没生效：浏览器回绝了执行 JavaScript 的请求，按上面那条路径再确认一下开关勾上了没有")
        case .noReply: return L10n.t("还没生效：浏览器收下了请求却一直没回应，多半是那个开关还没勾上（有的浏览器不报错、直接不回）。按上面那条路径再确认一下")
        case .failed(let msg): return String(format: L10n.t("检测没通过：%@"), msg)
        }
    }

    /// 浏览器自己那道 JS 开关此刻什么状态。
    ///
    /// ⚠️ Chromium 系读的是浏览器 profile 里的 `Preferences`,而**别的 App 读
    /// `~/Library/Application Support/<浏览器>/` 需要「完全磁盘访问权限」** —— 没给的话
    /// 这里恒为 `.unknown`。那不是坏了,是查不到,文案要如实说,别显示成"未开启"。
    private func browserJSSwitchCaption(bundleID: String, status: BrowserAutomationPermission.Status) -> String {
        switch status {
        case .enabled: return L10n.t("已开启")
        case .disabled:
            // ⚠️ **文件和实测回答的是两个不同的问题,都对,不存在"以谁为准"**(2026-09-01,
            // 用户亲手做的对照实验坐实)。文件说的是「**下次启动**会怎样」,实测说的是
            // 「**现在**怎样」——Chromium 那道开关只在浏览器启动时读一次(见
            // BrowserAutomationPermission 头注),运行期间在菜单里改它,文件立刻变、
            // 运行中的浏览器**纹丝不动**。
            //
            // 实证(这台机器上的 Arc,进程自 8/30 17:49 起一次没重启):用户 16:46 在 Arc 菜单里
            // 把它**关掉**,文件当场变 false;11 分钟后 `execute … javascript "1+1"` 照样返回 2。
            // 关的方向和开的方向都一样,不是单向的。
            //
            // 所以两者不一致时**要给指引、不能报平安**:文件说关,意味着这个浏览器下次重启
            // 就会失效——那是一次已经排好队的、必然到来的失效,正是最该提前告诉用户的事。
            // (2026-09-01 早些时候这里一度写成「以实测为准」,方向是反的,当天改回。)
            if browserJSProvenWorking(bundleID: bundleID) {
                return L10n.t("这个开关已经被关掉了——现在还能用，只是因为该浏览器还没重启；重启后就会失效")
            }
            return L10n.t("未开启")
        case .unknown:
            // ⚠️ 读不到文件时,**实测通过过**就是这里能拿到的最强证据,比"无法确认"有用得多。
            // 但措辞必须是"上次检测通过"而不是"已开启" —— 用户后来把开关关掉我们无从得知,
            // 断言当下就又成了一句会过期的谎(见 AppSettings.browserJSVerifiedAt 那段)。
            if let at = settings.browserJSVerifiedAt[bundleID] {
                return String(format: L10n.t("上次检测通过（%@）"), Self.verifiedAtFormatter.localizedString(for: at, relativeTo: Date()))
            }
            return L10n.t("无法确认状态（读不到该浏览器的配置文件）")
        case .unsupported: return ""
        }
    }

    private static let verifiedAtFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// 这个浏览器算不算"已经配好了"。⚠️ 两条证据取其一:能读到配置文件且开着,或者**实测
    /// 通过过**。后者是 Chromium 系在没有完全磁盘访问权限时唯一拿得到的证据。
    /// **有没有硬证据证明这个浏览器现在真的驱得动** —— 这一轮自检通过,或者以前某次通过过
    /// 并落了盘。抽出来是因为两个地方要用同一条判据:`browserJSLikelyWorking`(决定给不给
    /// 指引)和 `browserJSSwitchCaption`(决定那行状态怎么措辞),两边说的话必须一致。
    private func browserJSProvenWorking(bundleID: String) -> Bool {
        if browserSelfTestResults[bundleID] == .ok { return true }
        return settings.browserJSVerifiedAt[bundleID] != nil
    }

    private func browserJSLikelyWorking(bundleID: String) -> Bool {
        let status = BrowserAutomationPermission.status(forBundleID: bundleID)
        // ⚠️ **文件明确说"关"的时候一律算没配好,哪怕此刻实测还能用**(2026-09-01)。理由见
        // `browserJSSwitchCaption` 的 `.disabled` 分支:那预告了一次必然到来的失效(重启即生效),
        // 指引块挂在这个函数的 false 分支上,这时候正是最需要把菜单路径摆出来的时候。
        if status == .disabled { return false }
        // 其次看这一轮**真的试过**的结果 —— 它压过下面两条间接证据。文件里写着"开着"也不算数:
        // 同理,那说的是下次启动,不是现在。不然会出现最难受的一种界面:上面一行说「已开启」、
        // 下面一行说「检测没通过」,却一句指引都不给。
        // `noTab` 不算反证(浏览器没开着而已),落回间接证据。
        if let r = browserSelfTestResults[bundleID] {
            switch r {
            case .ok: return true
            case .blocked, .noReply, .failed: return false
            case .noTab: break
            }
        }
        if status == .enabled { return true }
        return settings.browserJSVerifiedAt[bundleID] != nil
    }

    /// **这个浏览器**打开那道开关的确切位置。
    ///
    /// ⚠️ 四家各不相同,而且**中英文不是同一条路径的直译** —— 2026-09-01 逐个从各自 App 包
    /// 里的本地化资源抠出来核对过(用户原话:「在 chrome 里你说这个查看完全不存在;你没有实际
    /// 去看 chrome 的设置菜单吧,还有确保英文版本的也是对的」)。实测出处:
    ///   - Chrome:`Google Chrome Framework.framework/.../{en,zh_CN}.lproj/locale.pak`
    ///     菜单栏标题英文 `View`、中文**「显示」**;子菜单 `Developer` / 「开发者」。
    ///     ⚠️ Chrome **自己的帮助文案**里写的是「查看」,跟它自己的菜单栏对不上 ——
    ///     照抄那句就是这次的 bug 来源,别再信它。
    ///   - Edge:同样的 pak,英文 `View`、中文**「查看」**;子菜单 `Developer` / 「开发人员」。
    ///     跟 Chrome **两处都不同**,一份通用文案不可能同时对。
    ///   - Arc:`Contents/Resources/Base.lproj/MainMenu.nib` 里是 `View` / `Developer` /
    ///     `Allow JavaScript from Apple Events`,而 `zh-CN.lproj/MainMenu.strings` 里
    ///     **没有**这几项 —— 也就是说中文系统下 Arc 这几个菜单**仍然显示英文**。
    ///   - Safari:压根不在菜单栏,在**设置**里(`DeveloperPreferences.strings`):
    ///     先在「高级」勾「显示网页开发者功能」(`Show features for web developers`),
    ///     设置里才会出现「开发」面板,里面才有「允许Apple事件中的JavaScript」(中文原文
    ///     就是不带空格的)。
    ///
    /// ⚠️ 改文案前请回到各自 App 包里重新核一遍,别照记忆写。
    private func browserManualEnableHint(bundleID: String) -> String {
        switch bundleID {
        case "com.google.Chrome":
            // ⚠️ **别把"Chrome 自己的帮助文案写错了"那段考据加回文案里**(2026-09-01 用户
            // 明确要求去掉:「这段话你没必要写啊」)。那是给维护者看的,写在
            // `browserManualEnableHint` 的头注里就够了;用户要的只是"点哪"。
            return L10n.t("在 Chrome 菜单栏依次打开「显示 → 开发者 → 允许 Apple 事件中的 JavaScript」。")
        case "com.microsoft.edgemac":
            return L10n.t("在 Edge 菜单栏依次打开「查看 → 开发人员 → 允许 Apple 事件中的 JavaScript」。")
        case "company.thebrowser.Browser":
            return L10n.t("在 Arc 菜单栏依次打开「View → Developer → Allow JavaScript from Apple Events」。Arc 的这几个菜单项在中文系统下也是英文。")
        case "com.apple.Safari":
            return L10n.t("Safari 在设置里，不在菜单栏：先到「Safari 浏览器 → 设置 → 高级」勾上「显示网页开发者功能」，设置里就会多出「开发」一栏，在那里勾上「允许Apple事件中的JavaScript」。")
        default:
            return L10n.t("到该浏览器的开发者菜单里打开「允许 Apple 事件中的 JavaScript」。")
        }
    }

    /// 这个浏览器还没配置完吗 —— 决定头像上要不要挂角标。
    ///
    /// ⚠️ **只在"确定还没好"时才算未完成**。系统自动化授权那一档在浏览器没运行时**查不到**
    /// (见 `browserPermissionPopover` 里那段:`check` 会落进 procNotFound 被当成"还没问过"),
    /// 那种"不确定"**不算**未完成 —— 否则每次那个浏览器没开着,一个橙色感叹号就会挂在那儿,
    /// 而它什么问题都没有。宁可漏报也不误报:漏报的代价是用户点开才发现还差一步,误报的
    /// 代价是这个角标从此没人信。
    private func browserSetupIncomplete(bundleID: String) -> Bool {
        _ = automationRefreshTick
        // ⚠️ 判据跟气泡里那条保持一致(`browserJSLikelyWorking`):实测通过过就算配好,
        // 否则 Chromium 系永远读不到配置文件、角标就永远挂着,那个角标也就没人信了。
        if !browserJSLikelyWorking(bundleID: bundleID) { return true }
        guard MusicAutomationPermission.isRunning(bundleID: bundleID) else { return false }
        return MusicAutomationPermission.check(bundleID: bundleID, askIfNeeded: false) != .authorized
    }


    /// 系统自动化授权那一行的说明。⚠️ nil ≠ 未授权 —— 见调用点那段。
    private func browserAutomationCaption(_ status: MusicAutomationPermissionStatus?,
                                          live: Bool = true) -> String {
        switch status {
        case .authorized:
            // 区分"此刻查到的已授权"和"上次自检时证明过" —— 后者不该冒充当下的读数。
            return live ? L10n.t("系统自动化授权：已授权")
                        : L10n.t("系统自动化授权：上次检测时已授权")
        case .denied: return L10n.t("系统自动化授权：已拒绝，需要在系统设置里打开")
        case .notDetermined: return L10n.t("系统自动化授权：尚未授权")
        case nil: return L10n.t("系统自动化授权：这个浏览器没在运行，查不到当前状态")
        }
    }

    private static func browserIconView(bundleID: String, size: CGFloat) -> some View {
        Group {
            if let icon = AppIconResolver.icon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }

    /// 平台图标——YouTube Music 是个网站,没有 `.app` 可以像浏览器那样用 AppIconResolver
    /// 取真图标。2026-08-31 用户要求用真实图标,跟 lastfmBadgeImage/listenBrainzBadgeImage
    /// 同一个既有先例:素材取自 Simple Icons(CC0 授权、专门收录给第三方集成场景用的品牌
    /// 图标合集,矢量描摹自官方标志,不是截图抠像素),PNG 由 build.sh 拷进
    /// Contents/Resources/,用 Bundle.main(不是 Bundle.module)加载——理由见 L10n.swift
    /// 顶部注释、AccountLinkingTab.swift 里 lastfmBadgeImage 的同款写法。以后新增别的网页
    /// 平台,照这个模式再加一份资源 + 一个 case 就行。
    /// ⚠️ 这里的 key 必须跟 `BrowserPositionProbe.supportedPlatforms` 里的 `id` 一字不差 ——
    /// 对不上不会编译报错,只表现成"那张平台卡的图标位空着"。
    private static func platformIcon(_ platformID: String) -> NSImage? {
        switch platformID {
        case "youtubeMusic": return youtubeMusicIcon
        case "spotifyWeb": return spotifyIcon
        default: return nil
        }
    }

    /// ⚠️ 图片取自本机 `/Applications/Spotify.app` 的 `AppIcon.icns`(2026-09-01 用 sips 转成
    /// 1024×1024 PNG),跟 `YouTubeMusicIcon.png` 同规格同来路 —— 不去网上抓品牌资源。
    private static let spotifyIcon: NSImage = {
        guard let path = Bundle.main.path(forResource: "SpotifyIcon", ofType: "png"),
              let image = NSImage(contentsOfFile: path)
        else {
            return NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage()
        }
        return image
    }()

    private static let youtubeMusicIcon: NSImage = {
        guard let path = Bundle.main.path(forResource: "YouTubeMusicIcon", ofType: "png"),
              let image = NSImage(contentsOfFile: path)
        else {
            // 没走 build.sh 打包时(直接 swift build 跑)找不到资源,退回 SF Symbol,
            // 别让图标位裸奔成空白——跟 lastfmBadgeImage/listenBrainzBadgeImage 同一个兜底。
            return NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage()
        }
        return image
    }()



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
        // 2026-09-01 多选后从"== .appleMusic"(唯一选项)放宽到"包含 Apple Music"——
        // 同时选了 Apple Music 和别的播放器时,Apple Music 那条 AppleScript 路径照样会被
        // 走到(见 MediaControlClient.refinedAppleMusicSnapshotIfNeeded),用户仍然值得
        // 在这里管理这份自动化权限,不该因为多选了别的播放器就把入口藏起来。纯 auto(不
        // 显式包含 Apple Music)维持原有行为不显示——跟改动前一致,不在这次改动范围内。
        if features.players.contains(.appleMusic) {
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
            // App 本体版本跟打包的 collector 版本对不上——2026-08-31 加,见
            // CollectorServiceManager.bundledCollectorVersion 头注(v1.3.0 发布时真的
            // 漏同步过一次,当时没有任何地方能看出来)。只在真查到不一致时才显示这条,
            // 查不出来(nil)时保持沉默,不把"没法判断"说成"有问题"。
            if let mismatch = collectorVersionMismatch {
                CardDivider()
                SettingsNote {
                    Text(L10n.t("App 版本和后台采集服务版本不一致，可能是这次打包时漏了同步版本号，建议重新安装 App"))
                    Text("App \(mismatch.appVersion) · \(L10n.t("采集服务")) \(mismatch.collectorVersion)")
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
        .onAppear {
            refreshCollectorState()
            refreshCollectorVersionCheck()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshCollectorState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCollectorState()
        }
    }

    // 两个开关的文案跟着 features.players 走(Apple Music/QQ 音乐/...)——这两个联动本身
    // 已经改成跟着选定的播放器走(见 AppDelegate.swift/companionlaunch.go),文案继续写死
    // "Apple Music"会跟实际行为对不上。"打开 Lyrimuse 时启动 X"需要一个唯一确定的 X 才
    // 有意义,2026-09-01 多选后判据从"!= .auto"变成"soleExplicitPlayer 不是 nil"(排除
    // 自动识别之后,选中集合里恰好只剩一个具体播放器)——含糊(纯 auto、或者同时选了
    // 两个以上具体播放器)就直接隐藏这个开关,不猜、不显示读不通的文案;"打开 X 时启动
    // Lyrimuse"反而在含糊的场景下更有用——companionlaunch.go 这时会同时盯着选中集合里
    // (或者纯 auto 下全部已知播放器)每一个的进程。
    private var companionCard: some View {
        SettingsCard {
            if let only = features.players.soleExplicitPlayer {
                SettingsRow(
                    icon: "arrow.up.forward.app",
                    title: String(format: L10n.t("打开 Lyrimuse 时启动 %@"), only.displayName)
                ) {
                    Toggle("", isOn: $settings.launchMusicOnLyrimuseOpen)
                }
                CardDivider()
            }
            SettingsRow(
                icon: "arrow.down.app",
                title: features.players.soleExplicitPlayer.map {
                    String(format: L10n.t("跟随 %@ 启动"), $0.displayName)
                } ?? L10n.t("跟随播放器启动"),
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

    /// 查一次"App 本体版本"跟"打包进这份 App 的 collector 版本"是否一致(见
    /// CollectorServiceManager.bundledCollectorVersion 头注)。只在 .onAppear 调一次
    /// (不放进每 2 秒那条心跳),而且真的 spawn 一次子进程,丢到后台线程跑,不阻塞
    /// 设置页打开这一下的主线程。
    private func refreshCollectorVersionCheck() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        Task.detached(priority: .utility) {
            guard let collectorVersion = CollectorServiceManager.bundledCollectorVersion(),
                  collectorVersion != appVersion else {
                // nil(拿不到)或版本一致,都不该报警——见调用点注释,"没法判断"不等于
                // "有问题"。已经报过警的情况下重新查到一致(比如刚重新安装完),也要
                // 把旧警告收回去,不能一直挂着。
                await MainActor.run { collectorVersionMismatch = nil }
                return
            }
            await MainActor.run {
                collectorVersionMismatch = (appVersion: appVersion, collectorVersion: collectorVersion)
            }
        }
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
    /// 「设置文件」那一行的提示通道(导入失败 / 导出失败 / 清理结果)。
    ///
    /// ⚠️ 单独开一个,不复用 iCloudMessage:那条原来被关在 `if ICloudConfigStore.isAvailable`
    /// 里面,没开 iCloud Drive 的用户连提示通道都没有 —— 而"导出失败"恰恰跟 iCloud 无关
    /// (两处 `try?` 把错误全吞了,失败时界面上什么都不会发生)。
    @State private var configMessage: String?
    /// 「更新备份」写成功后按钮本身要不要变身成打勾的「已保存」(2026-08-26 两轮改)。
    /// 第一版做的是"按钮下面淡出一行小灰字",用户实测反馈"不明显,不仔细看都不知道"——
    /// 那行字出现在**视线本来就没在看**的地方(眼睛/光标此刻都停在按钮上,不在按钮下面
    /// 那一小条)。改成按钮**自己**变身「已保存」+ 打勾图标,反馈就出现在用户刚刚点击、
    /// 视线正停留的地方,不用移动视线去找 —— 图标/文案/1 秒时长直接照抄"保存修改"那颗
    /// 按钮成功后变身「已保存 ✓」的写法(LyricsManagerView,同一个 App 只该有一种
    /// "保存成功"的样子),这里只是多了个失效令牌让它在**别的**动作触发新一轮之前
    /// 不会被那次新的提前打断(那颗按钮没有这层,因为它不会连着触发两轮反馈)。
    @State private var iCloudJustSaved = false
    /// 上面这个"已保存"态的失效令牌——只有它读到自己发出时的这个值才把 `iCloudJustSaved`
    /// 拨回 false,避免计时器到点时把用户这期间又点了一次触发的**新一轮**"已保存"提前
    /// 掐掉(两次点击间隔小于展示时长时,新的那次应该完整展示完自己的时长)。
    @State private var iCloudJustSavedToken = 0
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
                // ⚠️ 2026-09-01 整张卡重排(用户要求)。原来是四行平铺:iCloud 备份 /
                // 导出设置 / 导入设置 / 配置文件夹 —— 问题不在样式,在**这四行不是同一类
                // 东西**:第一行是个有状态的目的地(有快照、时间戳、来源设备、能换绑目录),
                // 二三行是围绕"文件"的一对互逆动作,第四行压根跟备份没有因果关系(它是给
                // dotfiles/chezmoi 用户看活配置的)。四行等高平铺,唯一的层级信号只有
                // "第一行副标题里有时间戳",读者没法看出它们不是并列关系。
                //
                // 现在:两行(目的地 / 文件),卡级动作上提到卡头,配置文件夹搬去「关于」。
                // 卡名也换成文档里自己用的说法(docs/features/14 §4「配置备份与搬家」)——
                // 「设置备份」既没盖住 dotfiles 那条路,也没盖住一起被备份的歌词库。
                SettingsCardHeader(title: L10n.t("配置备份与搬家")) {
                    // 卡级动作(换绑目录)上提到卡头 —— 这是本仓库既有的位置(见「歌词来源」
                    // 卡头那颗「测试」按钮)。原来它们藏在行尾一个 ellipsis.circle 菜单里,
                    // 而那个 ⋯ 是整个设置页**唯一**的一个,别处的无边框 Menu 都带文字标签。
                    Menu {
                        Button(L10n.t("更换备份文件夹…")) { chooseBackupFolder() }
                        if ICloudConfigStore.usingCustomFolder {
                            Button(L10n.t("改回 iCloud")) {
                                ICloudConfigStore.setCustomFolder(nil)
                                iCloudSnapshot = ICloudConfigStore.latestSnapshot()
                            }
                        }
                        // 这里原来有一项「只保留最近 3 份（现有 N 份）」。2026-09-01 删掉:
                        // 它是给"每存一次就新增一对文件、永不删旧"这个缺陷贴的创可贴,
                        // 而正确的修法是写入时自动只留最近几份(见「存到 iCloud」那个
                        // alert 里的说明)。留着它等于要求用户记得定期来打扫自己的备份 ——
                        // 而这个菜单本来就藏在卡头,不点开根本不知道有多少份在堆。
                        Divider()
                        // ⚠️ 必须写清是**哪个**文件夹。原来这里和下面「配置文件夹」那行
                        // 都叫「在访达中显示」,一字不差却开两个不同目录(备份目录 vs
                        // ~/.config/lyrimuse 这个**活配置**目录),两个都没有二次确认 ——
                        // 用户把打开的活配置目录当成备份去拷/删,丢的是正在用的配置。
                        Button(L10n.t("打开备份文件夹")) {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [ICloudConfigStore.preparedFolderURL()])
                        }
                    } label: {
                        Text(L10n.t("备份文件夹…"))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                CardDivider()
                // 第一行:有状态的目的地。
                //
                // ⚠️ 整行**不再**因为 iCloud Drive 关掉/自选目录掉线就消失。原来是
                // `if ICloudConfigStore.isAvailable { ... }`,把外置盘一拔整行没了 ——
                // 连菜单里的「改回 iCloud」也跟着没了,用户被锁死而且没有任何解释。
                // 现在行照常在,按钮禁用,副标题说明原因。
                SettingsRow(
                    icon: ICloudConfigStore.usingCustomFolder ? "folder" : "icloud",
                    title: ICloudConfigStore.usingCustomFolder
                        ? L10n.t("备份文件夹") : L10n.t("iCloud 备份"),
                    subtitle: iCloudSubtitle
                ) {
                    HStack(spacing: 8) {
                        if iCloudBusy { ProgressView().controlSize(.small) }
                        Button {
                            showICloudExportWarning = true
                        } label: {
                            if iCloudJustSaved {
                                Label(L10n.t("已保存"), systemImage: "checkmark")
                            } else {
                                Text(iCloudSnapshot == nil
                                    ? (ICloudConfigStore.usingCustomFolder
                                        ? L10n.t("存一份") : L10n.t("存到 iCloud"))
                                    : L10n.t("更新备份"))
                            }
                        }
                        // ⚠️ 只给**这一颗**按钮定宽。本仓库的风格就是按钮宽度参差
                        // (SettingsDesignSystem 里没有任何 minWidth,定宽只用在滑杆和数字
                        // 读数上),不该全局统一。但这颗的文字会**原地变化**
                        // (存到 iCloud / 存一份 / 更新备份 / 已保存),每变一次整行跳一下 ——
                        // 跟 ShortcutRecorder 用 max(width,150) 解决的是同一个问题。
                        .frame(minWidth: 88)
                        .disabled(!ICloudConfigStore.isAvailable)
                        if iCloudSnapshot != nil {
                            // ⚠️ 原来这颗也叫「导入…」,跟下面「设置文件」那行的「导入…」
                            // 一字不差却是两件事:这颗直接恢复**副标题里说的那一份**(不开
                            // 面板),那颗是开文件选择器。而代码还把文件面板的默认目录设成
                            // 同一个 iCloud 文件夹,两条路常落到同一个文件上,更难分辨。
                            Button(L10n.t("恢复这份")) { importFromICloud() }
                                .disabled(!ICloudConfigStore.isAvailable)
                        }
                    }
                }
                if let iCloudMessage {
                    CardDivider()
                    SettingsNote { Text(iCloudMessage) }
                }
                CardDivider()
                // 第二行:把原来的「导出设置」「导入设置」合成一行 —— 它们是同一件事
                // (把配置存成文件 / 从文件读回来)的两个方向,分成两行只是把一对互逆动作
                // 拆开摆,还各自挂了一个点开才看得见的 ⓘ。
                //
                // ⚠️ 后果写进**副标题**而不是 help 气泡。本仓库的规矩写得很明确
                // (SettingsDesignSystem「两者只用其一」、SettingsView 里「副标题**常显**…
                // 藏在 tooltip 里等于没说」),而 HelpButton 是**点击**才弹、不是悬停。
                // 既有先例也都这么做:「导出诊断信息」把"不含 token"放副标题、「清除所有
                // 设置」把"无法撤销"放副标题。这张卡原来正好反着来,把三条最该常显的事实
                // (含凭证、覆盖一切并重启、含账号凭据)全塞进了气泡。
                SettingsRow(
                    icon: "doc.badge.gearshape",
                    title: L10n.t("设置文件"),
                    // ⚠️ 副标题和气泡**分工,不重复说**。原来两边把同样三件事各讲一遍
                    // (气泡那段 110 字基本是副标题的长版),读的人点开只是把刚看过的话
                    // 再读一遍。现在:副标题只留"点之前必须知道的后果",气泡只补副标题
                    // 装不下的**细节**。
                    //
                    // 顺带修一处不准确:原副标题说"含账号凭证与歌词库",但歌词库根本不在
                    // 这个文件里 —— 它是单独的第二个文件,而这正是用户最容易漏拷的东西。
                    subtitle: L10n.t("含明文凭证；导入会覆盖全部设置并重启"),
                    help: L10n.t("歌词库是同名的第二个文件，搬家时两个都要拷。\n凭证别发给别人；导入连已连接的账号、播放数据发往的地址一起覆盖")
                ) {
                    HStack(spacing: 8) {
                        Button(L10n.t("导出…")) { showExportConfigWarning = true }
                        Button(L10n.t("从文件导入…")) { pickConfigFileToImport() }
                    }
                }
                if let configMessage {
                    CardDivider()
                    SettingsNote { Text(configMessage) }
                }
            }
            .onAppear {
                iCloudSnapshot = ICloudConfigStore.latestSnapshot()
            }
            // ⚠️ 这个 alert 原来**只有标题、没有 message**,而本地导出那个却明确写了
            // "包含账号登录凭证和密钥" —— 反了。存到 iCloud 才是把明文 token 推上 Apple
            // 服务器和你所有设备的那一步(write 设的 0600 权限过了同步就不作数)。
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
                        // ⚠️ **这里不做任何自动清理,备份想攒多少份就多少份**(2026-09-01
                        // 用户明确定的:「不需要这个清理逻辑,想塞几份就几份」)。
                        //
                        // 背景是当天先加过一版"写入时自动只留最近 3 份":每点一次都新写一对
                        // 文件(配置 4KB + 歌词包 ~8MB)、没有东西会删旧的,实测攒到 9 份配置
                        // + 8 份歌词包 = 55MB。用户看完这个数据仍然选择不清理 —— 那是他的
                        // 磁盘和他的备份,「攒着」本身就是他要的行为。
                        //
                        // 所以别再"顺手"加回来:不加定时清理、不加写入时清理、不加"超过 N
                        // 份就提醒"。真要省空间由用户自己去备份文件夹删(卡头菜单里有
                        // 「打开备份文件夹」)。
                        // 2026-08-26 两轮改:原来这里不弹任何反馈——理由是副标题会立刻
                        // 换成刚写进去那份的时间、按钮也从"存到 iCloud"变成"更新",反馈
                        // 已经在界面上了。用户实测反馈:**更新**一份已有备份时,界面上唯一
                        // 的变化只是副标题里的时间戳往前跳几秒,按钮文字本来就已经是
                        // "更新备份"、不会再变——那种"反馈"太不起眼,点完根本看不出生效
                        // 没有。第一版补的是按钮下面淡出一行小灰字,用户又反馈"不明显,
                        // 不仔细看都不知道"——那行字在视线本来就没在看的地方。改成按钮
                        // 自己变身,理由与写法见 iCloudJustSaved 声明处注释。
                        iCloudSnapshot = ICloudConfigStore.latestSnapshot()
                        iCloudMessage = note
                        // note 非 nil(歌词库那份没写成功)时不弹这个打勾态:那种情况
                        // 已经有一条要用户看到并处理的持久提示了(上面 iCloudMessage),
                        // 按钮再摆出一副"全成功"的样子会互相矛盾。
                        if note == nil {
                            iCloudJustSavedToken += 1
                            let token = iCloudJustSavedToken
                            withAnimation { iCloudJustSaved = true }
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1))
                                guard iCloudJustSavedToken == token else { return }
                                withAnimation { iCloudJustSaved = false }
                            }
                        }
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
                        //
                        // ⚠️ 2026-09-01:这两处原来是裸 `try?`,**失败完全静默** —— 盘满、
                        // 没有写权限、目标被别的进程占着,界面上什么都不会发生,用户以为
                        // 导出成功了。现在失败就报出来。
                        do {
                            try data.writeSecurely(to: url)
                        } catch {
                            configMessage = String(format: L10n.t("导出失败：%@"), error.localizedDescription)
                            return
                        }
                        // 歌词库那份写在**紧邻的同名文件**旁边 —— 导入时就是靠这个位置关系
                        // 找到它的(NSSavePanel 只能给一个落点,所以是"兄弟文件"而不是两次面板)。
                        Task { @MainActor in
                            guard let archive = await LyricsBackupStore.buildArchive() else {
                                configMessage = L10n.t("设置已导出；歌词库这次没打包成功，只有设置那一个文件")
                                return
                            }
                            let sidecarName = LyricsBackupArchive.sidecarName(forConfigName: url.lastPathComponent)
                            let sidecar = url.deletingLastPathComponent().appendingPathComponent(sidecarName)
                            do {
                                try archive.writeSecurely(to: sidecar)
                                // ⚠️ 必须把"旁边还有第二个文件"说出来。原来它是静默写的,
                                // 而用户只会拷走自己在面板里选中的那一个 —— 到新机器导入时
                                // 找不到兄弟包,按设计"一个歌词文件都不动",于是歌词**静默全丢**。
                                configMessage = String(format: L10n.t("已导出两个文件：设置和歌词库（%@）。搬到新电脑时两个都要拷"), sidecarName)
                            } catch {
                                configMessage = L10n.t("设置已导出；歌词库那份写盘失败，只有设置那一个文件")
                            }
                        }
                    }
                }
            } message: {
                Text(L10n.t("导出的文件包含账号登录凭证和密钥，妥善保管，不要发给别人。歌词库会另外存成同名的第二个文件，搬家时两个都要拷"))
            }
            .alert(L10n.t("确定要导入这份设置吗？"), isPresented: $showImportConfigConfirm) {
                Button(L10n.t("取消"), role: .cancel) {}
                // Task 包一层:importData 现在要等 collector 重新读到新配置才返回(见那边
                // 的注释),而 restartApp() 必须排在它后面 —— 一旦 terminate,没跑完的
                // launchctl 操作就跟着进程一起没了。
                Button(L10n.t("导入并重启"), role: .destructive) {
                    if let data = pendingImportData {
                        Task { @MainActor in
                            // ⚠️ 2026-09-01 修:这里原来是 `await importData(data)`,**把返回值
                            // 丢掉**,然后无条件 restartApp()。而 importData 是
                            // `async -> Bool`,顶层 JSON 解析失败时 return false
                            // (ConfigPortability.swift:254)。于是用户选错一个 .json ——
                            // 面板只过滤扩展名、不校验是不是我们的导出包 —— 结果是
                            // **App 退出重启、设置一个字没改、界面上零提示**,唯一能得出的
                            // 结论是"导入把我的设置弄坏了"。
                            //
                            // 现在失败就地报错、**不重启**。歌词恢复和 adoptFolder 也一并
                            // 跳过:配置都没写进去,单独铺歌词/改备份目录只会留下一个
                            // 半吊子状态。
                            guard await ConfigPortability.importData(data) else {
                                configMessage = L10n.t("导入失败：这个文件不是 Lyrimuse 的设置备份，或者已经损坏。当前设置没有被改动")
                                return
                            }
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
                // ⚠️ 2026-09-01 补:原来这里**只讲后果、不讲对象** —— 用户看不出正要导入的
                // 是哪一份。而导出时间和机器名早就在包里(ConfigPortability 写的),
                // iCloud 那一行也一直渲染成"…· 来自 DJ-chenyuhao"。同一份信息在行里有、
                // 在真正要拍下决定的确认框里反而没有,是反的。
                //
                // 这一句放在后果**之前**:先说清"你要覆盖成哪一份",再说"会覆盖掉什么"。
                if let source = pendingImportSourceDescription {
                    Text(String(format: L10n.t("即将导入：%@"), source))
                }
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

    /// 正要导入的那份备份是"哪一份":导出时间 + 写它的那台机器。
    ///
    /// 直接从 `pendingImportData` 现读,不依赖 `iCloudSnapshot` —— 「从文件导入…」那条路
    /// 压根没有 snapshot(用户可能从 U 盘选了一个文件),而恰恰是那条路最需要这句话。
    /// 复用 `ICloudConfigStore.metadata(in:)`,不另写一份解析。
    private var pendingImportSourceDescription: String? {
        guard let data = pendingImportData else { return nil }
        let meta = ICloudConfigStore.metadata(in: data)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        switch (meta.exportedAt, meta.deviceName) {
        case let (when?, device?) where !device.isEmpty:
            return String(format: L10n.t("%1$@ 从「%2$@」导出的备份"), formatter.string(from: when), device)
        case let (when?, _):
            return String(format: L10n.t("%@ 导出的备份"), formatter.string(from: when))
        case let (nil, device?) where !device.isEmpty:
            return String(format: L10n.t("从「%@」导出的备份"), device)
        default:
            // 老版本导出的包里没有这两个字段。此时不编造,返回 nil 让这句整段不出现。
            return nil
        }
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

    /// 「从文件导入…」:开面板选一个配置包。原来这段内联在按钮闭包里,行数比按钮本身多
    /// 十倍;抽出来之后那一行只剩一句调用,也方便在这里加校验。
    ///
    /// ⚠️ 面板只能按扩展名过滤(`.json`),挡不住"选了个别的 json"。所以选完**先自己验一遍**
    /// 再弹确认框 —— 不然用户要走完"确认 → App 重启 → 发现什么都没变"才知道选错了
    /// (那正是这次修的那个 bug 的另一半:光在确认后 guard 住,体验仍然是"点了确认才报错")。
    private func pickConfigFileToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = L10n.t("导入")
        if ICloudConfigStore.isAvailable {
            panel.directoryURL = ICloudConfigStore.folderURL
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        // 长得像不像我们的导出包:顶层是个对象、且带 appSettings 或 config 之一。
        // 判据刻意宽松(只挡"明显不是"),严格校验仍然在 importData 里,这里只是把
        // "一眼就知道不对"的情况提前拦掉。
        let looksLikeExport: Bool = {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return obj["appSettings"] != nil || obj["config"] != nil || obj["version"] != nil
        }()
        guard looksLikeExport else {
            configMessage = L10n.t("这个文件不是 Lyrimuse 的设置备份，没有导入")
            return
        }
        configMessage = nil
        pendingImportData = data
        pendingImportFolder = nil
        // 同目录下的兄弟歌词包(同名、-Config- 换成 -Lyrics-)。没有就是一份老备份或用户
        // 只想恢复设置 —— 那就什么都不动,绝不能当成"空歌词库"去清掉本机现有的。
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
            // 2026-08-31 从三张卡重排成四张。原来第一张混着"切换显示形态"和"打开某扇窗"
            // 两类动作,只有 5 项时还看得过去;这次加到 16 项之后必须按语义分开,否则
            // 一张卡里十来行、找不到自己要的那一条。
            SettingsCard {
                SettingsRow(icon: "eye", title: L10n.t("显示/隐藏悬浮歌词")) {
                    ShortcutRecorderControl(name: .toggleOverlay)
                }
                CardDivider()
                SettingsRow(icon: "inset.filled.topthird.square", title: L10n.t("显示/隐藏灵动岛歌词")) {
                    ShortcutRecorderControl(name: .toggleNotchOverlayHotkey)
                }
                CardDivider()
                SettingsRow(icon: "menubar.rectangle", title: L10n.t("显示/隐藏菜单栏歌词")) {
                    ShortcutRecorderControl(name: .toggleMenuBarLyricsHotkey)
                }
                CardDivider()
                SettingsRow(icon: "lock", title: L10n.t("锁定/解锁位置")) {
                    ShortcutRecorderControl(name: .toggleLockPosition)
                }
                CardDivider()
                SettingsRow(
                    icon: "character.book.closed",
                    title: L10n.t("显示/隐藏译文")
                ) {
                    ShortcutRecorderControl(name: .toggleTranslationHotkey)
                }
                CardDivider()
                // ⚠️ 别再给这一行加副标题。原来有一句"总开关；具体给哪几种文字标注仍在
                // 「歌词显示」里分别设置",2026-08-31 用户看到实机效果后直接要求去掉。
                // (同一个偏好在「全局时间轴偏移」那一行也有记录:用户明确否掉过解释性文案。)
                SettingsRow(icon: "textformat.abc", title: L10n.t("显示/隐藏发音")) {
                    ShortcutRecorderControl(name: .toggleRomanizationHotkey)
                }
            }

            SettingsCard {
                SettingsRow(icon: "list.bullet.rectangle", title: L10n.t("打开歌词管理")) {
                    ShortcutRecorderControl(name: .openLyricsManagerHotkey)
                }
                CardDivider()
                SettingsRow(icon: "text.quote", title: L10n.t("打开歌词窗口")) {
                    ShortcutRecorderControl(name: .openLyricsWindowHotkey)
                }
                CardDivider()
                SettingsRow(
                    icon: "magnifyingglass",
                    title: L10n.t("搜索歌词"),
                    subtitle: L10n.t("给当前这首歌手动搜索候选歌词")
                ) {
                    ShortcutRecorderControl(name: .lyricsQuickSearchHotkey)
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
                SettingsRow(
                    icon: "arrow.counterclockwise",
                    title: L10n.t("歌词偏移归零"),
                    subtitle: L10n.t("把当前这首歌的校准值清回 0")
                ) {
                    ShortcutRecorderControl(name: .lyricsOffsetResetHotkey)
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
                CardDivider()
                // 跟上面"反馈问题"(Issues,追踪 bug 修复状态)分开:这里收想法/新功能建议,
                // 走 GitHub Discussions 的 Ideas 分类(2026-08-27 新开——仓库原来没启用
                // Discussions)。选它而不是另起一套表单/第三方服务:零额外基建(仓库自带),
                // 自带 👍 投票和评论,还能让同一个想法别被重复提好几遍。
                SettingsRow(icon: "lightbulb", title: L10n.t("想法与建议")) {
                    Button(L10n.t("前往")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse/discussions/categories/ideas")!)
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
                    subtitle: L10n.t("汇总日志、权限与后台服务状态，保存为一份文本文件，不含账号 token 或密钥")
                ) {
                    Button(L10n.t("导出…")) {
                        DiagnosticsExporter.exportInteractively()
                    }
                }
                CardDivider()
                // ⚠️ 2026-09-01 从「配置备份与搬家」那张卡搬过来的。它**不是备份手段** ——
                // 它是给拿 dotfiles/chezmoi 管机器的人直接看活配置的入口,跟"备份/恢复"
                // 没有因果关系。放在那张卡里的直接后果是:它的按钮原来也叫「在访达中显示」,
                // 跟备份行菜单里那个一字不差,却打开**两个不同目录**(备份目录 vs 这个
                // 活配置目录),两个都没有二次确认 —— 用户把活配置当备份去拷/删就出事。
                // 跟「导出诊断信息」放一起更合适:都是"给要自己动手的人看内部状态"。
                //
                // ⚠️ 副标题里"外观和快捷键不在里面"这句**必须常显**,不能收进 help 气泡:
                // 它们存在 UserDefaults,只拷这个文件夹会**静默**丢掉,是这条路子最容易
                // 踩的坑。原来这句只写在代码注释里,UI 上一个字都没有。
                SettingsRow(
                    icon: "folder",
                    title: L10n.t("配置文件夹"),
                    subtitle: L10n.t("~/.config/lyrimuse，纯文本可直接编辑；外观与快捷键不在里面（它们在 UserDefaults）"),
                    help: L10n.t("整份配置都在这里，可以直接纳入 dotfiles 版本管理。里面含账号凭据，不要发给别人。注意外观、配色、快捷键这些存在 UserDefaults 里，只拷这个文件夹会丢掉它们——要完整搬家请用「配置备份与搬家」")
                ) {
                    Button(L10n.t("打开配置文件夹")) {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigPortability.configFolderURL])
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
