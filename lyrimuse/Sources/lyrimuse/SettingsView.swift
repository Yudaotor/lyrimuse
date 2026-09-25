import SwiftUI
import AppKit
import Combine
import LyrimuseCore
import KeyboardShortcuts

// 整个设置窗口是一层真正的 NavigationSplitView:左边一份侧边栏 List,右边显示当前
// 选中项的详情。"账号连接"没有做成侧边栏里单独可选中的大分类,而是拆成普通账号行,
// 跟播放/歌词/歌词显示/通用平级放进同一个 List 里。
//
// 不要嵌套第二层"看起来像侧边栏"的容器(内层再套一个 NavigationSplitView,或手搭
// HStack+List 模拟侧边栏):macOS 的窗口级 chrome/圆角遮罩只按"一个真正侧边栏列"设计,
// 嵌套会让外层侧边栏不渲染、或者窗口露出黑色阴影。全窗口只留一层真正的侧边栏。
//
// 每个分类各自是独立的 View,直接访问对应的单例(AppSettings.shared/
// FeatureSettingsStore.shared/ConfigStore.shared 等),不需要从 SettingsView 往下传
// 参数——唯一的例外是某个开关因为对应账号没连好被禁用时,旁边会有个跳转按钮,直接跳到
// 侧边栏里对应的那一个账号行,这就需要 SettingsView 把跳转能力下传给它。
/// 原始值(= case 名)会落盘(`settings:lastTab`,见 lastTabStorageKey)——改 case 名会让
/// 老值解码失败、退回「歌词」,不算坏事,但别无意识地改。
enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    // 「播放器」与「通用」分开:前者围绕"选哪个播放器、能不能正常读到它的播放状态",
    // 后者只留语言/开机启动/配置备份。播放器那一页见 PlayerSettingsTab。
    case lyrics, player, appearance, shortcuts, general, about

    var id: Self { self }

    /// 「上次停留的顶层分类」的 UserDefaults 键。二级分段早就在记
    /// (`settings:lyricsSection` / `settings:appearanceSection`),顶层一直没记,表现是反复开关设置窗
    /// 调灵动岛样式时每次都得先从「歌词」点到「歌词显示」。用 `settings:` 前缀而不是 `np:`:
    /// ConfigPortability 只导出 `np:` / `KeyboardShortcuts_`,界面停留位置是机器状态、不该随备份走,
    /// 这个前缀正好自然排除(selftest contracts 组有守卫钉着两头)。
    static let lastTabStorageKey = "settings:lastTab"

    /// 设置窗口新建时该停在哪个顶层分类:上次停留的那个,解码失败(没存过 / case 改过名)退回「歌词」
    /// ——绝不能落成 nil,否则 detail 会显示「选择左侧的设置分类」。只认 `.tab`,账号页不在这里(理由见
    /// SettingsView 写回处的注释)。信箱 / subject(AppActions.requestSettings)在 .onAppear 里覆盖它,
    /// 优先级更高。
    static func restoredLastTab(defaults: UserDefaults = .standard) -> SettingsTab {
        defaults.string(forKey: lastTabStorageKey).flatMap(SettingsTab.init(rawValue:)) ?? .lyrics
    }

    var title: String {
        switch self {
        case .lyrics: return L10n.t("歌词")
        case .player: return L10n.t("播放器")
        // 叫「歌词显示」不叫「外观」:这一页第一层结构是按**展示方式**分的四个分段
        // (悬浮歌词/灵动岛/菜单栏/其它),讲的是"歌词显示在哪儿";它**不含** App 真正的
        // 外观项(菜单栏图标、Dock 图标都在「通用」),却**含**一堆不是外观的东西(每种形态
        // 的开关、显示在哪块屏幕、截屏时隐藏、暂停时隐藏、锁定位置)。
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

// 图标徽标——彩色圆角方块背景 + 白色 SF Symbol,侧边栏行(20pt/圆角5)和账号详情页头
// (36pt/圆角8)共用同一份渲染逻辑,不各自重复手写一遍。
//
// 方块用连续圆角(continuous),并叠一层上亮下暗的竖向渐变 + 半透明白描边 —— 跟系统设置的
// 图标一样略带体积感,纯平色块摆在旁边一眼就能看出不是一家的。渐变只叠在色块上,白色符号
// 不受影响;深色模式的亮度封顶(SettingsIconTint)作用于底色。
//
// 真身是 View 类型而不是自由函数:深色模式压暗色块要读 @Environment(\.colorScheme),
// 自由函数拿不到 environment。对外仍是同名自由函数,调用点不用改。
func iconBadge(_ systemName: String, tint: Color, size: CGFloat = 20, cornerRadius: CGFloat = 5) -> some View {
    IconBadge(systemName: systemName, tint: tint, size: size, cornerRadius: cornerRadius)
}

private struct IconBadge: View {
    let systemName: String
    let tint: Color
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    /// 符号外接框占整个方块的比例。22pt 方块 × 0.62 = 13.6pt,跟圆形符号
    /// (play.circle/info.circle)本来的墨迹宽度 13.0pt 基本持平——被收窄的只有过宽的那几个。
    private static let glyphRatio: CGFloat = 0.62

    var body: some View {
        // 逐符号归一化:resizable + scaledToFit 把每个符号的**外接框**装进同一个内框,过宽的
        // 自己缩下去,本来就方的几乎不动。
        //
        // 不设 .font/.imageScale 的话符号吃环境默认的 13pt,而 SF Symbol 之间是按**大写字母高度**
        // 对齐的、不是按外接框对齐 —— 同一字号下宽符号必然比圆符号占掉多得多的横向空间(22pt 方块
        // 里 rectangle.3.group 的墨迹占 81%、dot.radiowaves.left.and.right 75%、keyboard 73%,而
        // play.circle / info.circle 只有 59%)。统一调小字号救不了:那是等比缩,相对差距原样保留。
        //
        // 同时保证符号大小跟着 size 走:否则 36pt 徽标里的符号仍是 22pt 那档大小,墨迹只占方块
        // 33%~50%,一个小图标飘在大方块中间。
        //
        // 代价说清楚:resizable 会连描边粗细一起缩放,严格说破坏了 SF Symbol 跨图标的统一线重
        // (Apple 因此不建议对 SF Symbol 用 resizable)。这里换来的是"每个彩色方块里的图形占位
        // 一致",对一组并排的徽标来说更重要。
        let base = colorScheme == .dark ? SettingsIconTint.dimmedForDarkMode(tint) : tint
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: size * Self.glyphRatio, height: size * Self.glyphRatio)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                shape.fill(base)
                    // 上亮下暗:顶部掺一点白、底部压一点黑,幅度很小,只为让色块有一点体积感。
                    .overlay(shape.fill(LinearGradient(
                        colors: [.white.opacity(0.20), .white.opacity(0.02), .black.opacity(0.07)],
                        startPoint: .top, endPoint: .bottom)))
                    // 半透明白描边 = 系统图标那圈细高光;0.5pt 在 Retina 下正好一个像素。
                    .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            }
    }
}

/// 深色模式下给徽标色块的亮度封顶。
///
/// 侧边栏这批 tint 里有几个绝对亮度非常高,压在深色底上像在发光 —— yellow #FFD600 相对亮度
/// 0.694、mint #00DAC3 0.541、teal #00D2E0 0.515,而 indigo/blue/red 都只有 0.25~0.28。更实的
/// 问题是压在色块上的那个**白色 SF Symbol**:白色在 yellow 上只有 1.41:1、mint 1.78:1、
/// teal 1.86:1,远低于 WCAG 对图形/UI 部件的 3:1。"发光"和"图标糊掉"是同一个根因。
///
/// 上限 0.30 是解出来的:白色相对亮度是 1.0,要保住 3:1 就要求 (1.0+0.05)/(L+0.05) >= 3,
/// 即 L <= 0.30 —— "色块最多亮到白图标还合格为止"。
///
/// 压暗在**线性光**里做:线性 RGB 三通道同乘一个系数,相对亮度按同一系数线性下降(亮度就是
/// 三通道线性值的加权和),而三者比例不变 = 色相和饱和度分毫不动。所以有闭式解
/// k = 上限 / 当前亮度,不需要二分逼近。已经低于上限的色块原样返回 —— indigo/blue/red 实际
/// 都不会被动到,gray 只会从 0.316 挪到 0.300(肉眼看不出)。
///
/// **只在深色模式下用**。浅色模式下白图标压在 yellow 上同样只有 1.51:1,但那边色块不会在亮底
/// 上"发光",而压暗会把黄压成橄榄色、丢掉"黄"的身份。要改浅色的话,把 IconBadge 里那个
/// colorScheme 判断去掉即可。
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
    /// 「软件更新」页(仿系统设置那页)。不是 SettingsTab:不进六分类、不记上次停留;侧栏只在
    /// 有新版本时有一行(「有软件更新可用」)指向它,平时从「关于 › 更新 › 软件更新」进,
    /// 任何「检查更新」动作也会把窗口翻到这一页。
    case softwareUpdate
}

/// 设置窗里的"一个位置" = 顶层面板 + 这一页当前停在哪个二级分段(没有分段的页是 nil)。
///
/// 前进 / 后退按这个粒度记账。**页内那几个分段在用户眼里跟换页是同一件事**(「歌词」的
/// 获取/译文/效果/管理、「歌词显示」的悬浮歌词/灵动岛/菜单栏、Last.fm 账号页的统计/榜单/
/// 足迹/设置),只记到面板这一层的话,后退键会把用户在页内走过的那几步整个跳过。
///
/// `section` 存的是分段的 **rawValue 字符串**,不是某个枚举:三个分段枚举各自私有在自己
/// 那一页里、类型互不相通,而它们本来就有一份对外契约 —— 各自那个 @AppStorage 键里的字符串
/// (`SettingsSearchCatalog.lyricsSectionKey` / `LyricsSurface.appearanceSectionStorageKey` /
/// `SettingsSearchCatalog.lastfmSectionKey`),设置搜索跳转、菜单栏快捷入口走的也是这份契约。
struct SettingsLocation: Hashable {
    let panel: SettingsSidebarItem
    /// 没有二级分段的面板(播放器 / 快捷键 / 通用 / 关于 / 软件更新 / 其余账号页)是 nil。
    let section: String?
}

struct SettingsView: View {
    // 只用来在语言手动切换时让侧边栏/详情页的整棵子树重新渲染(sidebarLabel/
    // selectedCategoryTitle 这些顶层 chrome 文字不属于任何一个具体 tab,需要这一处
    // @ObservedObject 才会响应 AppSettings.appLanguage 的变化)——本身不在 body
    // 里读它的其它字段。
    @ObservedObject private var languageSettings = AppSettings.shared
    // 初值直接读盘(静态函数,属性初始化器里能调),不在 .onAppear 里再改一次——那样会先画一帧「歌词」
    // 再跳到上次的分类。见 SettingsTab.restoredLastTab。
    @State private var selection: SettingsSidebarItem? = .tab(SettingsTab.restoredLastTab())
    @AppStorage(SettingsTab.lastTabStorageKey) private var lastTabRaw = SettingsTab.lyrics.rawValue
    /// 侧栏「播放器」项的警告徽标数据源,随设置窗口出现/消失启停。
    @StateObject private var playerHealth = PlayerHealthMonitor()
    /// 这扇窗口看不看得见。「歌词显示」页的几块预览靠它在被遮住 / 最小化时停表,
    /// 见 PreviewHostVisibility.swift。
    @StateObject private var windowSurface = SettingsWindowSurface()
    /// 「有软件更新可用」那一行的数据源:Sparkle 查到、还没装上的版本。
    @ObservedObject private var updater = SparkleUpdaterManager.shared
    // 默认收起、点击 Section 头才展开,不持久化(每次打开设置窗口都从收起状态开始)。
    // 变量名跟 Section 标题「实验室功能」不一致是有意的:变量名是内部实现细节,不跟用户可见文案走。
    @State private var isAdditionalFeaturesExpanded = false
    /// 侧栏顶部搜索框的文字。非空时侧栏 List 换成结果列表;不持久化。
    @State private var settingsSearchText = ""
    /// 搜索框的焦点。放在这里而不是搜索框自己身上,因为让出焦点的时机在这一层:选了侧栏别的分类、
    /// 打开了一条结果,光标就不该继续在搜索框里闪。
    @FocusState private var settingsSearchFocused: Bool
    /// 搜索命中后的"高亮哪几行 / 展开哪个抽屉"信号,经 Environment 下发给行组件与三个「全部设置」
    /// 抽屉(Settings/SettingsSearch.swift)。
    @ObservedObject private var searchRouter = SettingsSearchRouter.shared

    // MARK: - 前进 / 后退

    /// 三处页内二级分段的当前值:「歌词」(获取/译文/效果/管理)、「歌词显示」(悬浮歌词/灵动岛/
    /// 菜单栏)、Last.fm 账号页(统计/榜单/足迹/设置)。
    ///
    /// 这里是同一批 UserDefaults 键的**第二个**观察者 —— 真正画分段选择器的是各自那一页,
    /// 顶层读它们只为把「当前停在哪一段」并进前进 / 后退的位置里。
    ///
    /// 默认值必须跟那一页自己的 @AppStorage 一字不差:对不上的话,「一次都没换过分段」这个
    /// 位置会被记成另一段,后退回去就换错段。三个默认值都取共用常量,selftest 拿各页枚举的
    /// 首个 case 钉着。
    @AppStorage(SettingsSearchCatalog.lyricsSectionKey)
    private var lyricsSectionRaw = SettingsSearchCatalog.lyricsSectionDefault
    @AppStorage(LyricsSurface.appearanceSectionStorageKey)
    private var appearanceSectionRaw = LyricsSurface.overlay.appearanceSectionRawValue
    @AppStorage(SettingsSearchCatalog.lastfmSectionKey)
    private var lastfmSectionRaw = SettingsSearchCatalog.lastfmSectionDefault

    /// 走过的位置序列 + 当前停在第几个。语义跟系统「系统设置」逐条对齐:
    ///   · 后退回到上一个位置、前进再走回来;
    ///   · **从历史中间跳去一个新位置时,前面那一截被截断**(同浏览器);
    ///   · 重复进入当前这一个位置不产生新记录(点侧栏里已经亮着的那一行、点已经选中的那一段);
    ///   · 两颗键常驻、不可用时置灰 —— 不做"没历史就隐藏",位置忽有忽无比置灰更难用,
    ///     系统设置也是常驻置灰。
    ///
    /// 记账粒度是 `SettingsLocation`(顶层面板 + 页内二级分段),理由见那个类型的头注。
    /// 序列与游标那套逻辑整块在 Core(`NavigationHistory`,纯值语义、selftest 覆盖):
    /// 截断、去重、封顶、起点这几件都有边界,写在 View 里就只能靠肉眼守。
    @State private var history = NavigationHistory<SettingsLocation>()

    /// 前进 / 后退自己造成的那次位置变化不该再写回历史 —— 否则后退一步立刻被记成一次新跳转、
    /// 前进那半截当场被截断,两颗键就只剩后退能用。
    ///
    /// 存的是**目标位置**,不是一个"正在导航"的布尔开关:一次跳转要同时改 `selection` 和分段键
    /// 两处状态,SwiftUI 不保证它们并成同一帧。布尔开关会被中间那一帧(新面板 + 它原来停的分段)
    /// 吃掉,那一帧随即被当成一次真跳转记下来;比对目标位置是"到了才放行",中间几帧都不怕。
    /// 这个字段留在 View 这边(而不是塞进 Core):它描述的是 SwiftUI 那条单向数据流的性质,
    /// 跟历史本身无关。
    @State private var historyNavigationTarget: SettingsLocation?

    /// 这一页当前停在哪个二级分段;没有分段的面板是 nil。
    ///
    /// 新加一处页内分段时,这里和 `applySection` 要一起接上 —— 漏了不会编译报错,表现是
    /// 后退键把那几步整个跳过。设置搜索目录里也要有对应的 `sectionKey`(selftest 按两边的
    /// 键数量对账)。
    private func section(of panel: SettingsSidebarItem) -> String? {
        switch panel {
        case .tab(.lyrics): return lyricsSectionRaw
        case .tab(.appearance): return appearanceSectionRaw
        case .account(.lastfm): return lastfmSectionRaw
        default: return nil
        }
    }

    /// 当前位置 = 选中的面板 + 那一页此刻停的分段。`selection` 为 nil(什么都没选中)时没有位置。
    private var currentLocation: SettingsLocation? {
        selection.map { SettingsLocation(panel: $0, section: section(of: $0)) }
    }

    /// 把位置里的分段写回那一页的键。没有分段的位置什么都不做。
    private func applySection(_ location: SettingsLocation) {
        guard let section = location.section else { return }
        switch location.panel {
        case .tab(.lyrics): lyricsSectionRaw = section
        case .tab(.appearance): appearanceSectionRaw = section
        case .account(.lastfm): lastfmSectionRaw = section
        default: break
        }
    }

    /// 窗口刚出现时种下起点。此刻这个位置是"打开就在这儿",不是一次跳转,所以它只当历史的
    /// 第 0 项 —— 不这么种的话,刚打开设置窗就有一颗能点的后退键,退回一个从没露过面的页面。
    private func seedHistory() { history.seed(currentLocation) }

    /// 跳到历史里的某个位置。**先写分段、再换面板**:反过来会先画一帧"新面板 + 它上次停的分段",
    /// 再跳到目标分段,肉眼看得见闪一下。
    private func navigate(to target: SettingsLocation) {
        historyNavigationTarget = target
        applySection(target)
        selection = target.panel
    }

    private func goBack() {
        guard let target = history.goBack() else { return }
        navigate(to: target)
    }

    private func goForward() {
        guard let target = history.goForward() else { return }
        navigate(to: target)
    }

    /// 记一次跳转。改位置的入口有五路(侧栏点选、搜索命中、账号页内跳转、AppActions 的信箱与
    /// subject、三处页内分段选择器 —— 最后这路还包括悬浮歌词 / 灵动岛 / 菜单栏那几个"去设置里改"
    /// 的快捷入口,它们是直接写分段键的),全部经 `.onChange(of: currentLocation)` 汇到这里 ——
    /// 让各入口自己记迟早漏一个,而漏掉的那条在界面上表现为"后退键跳过了一页"。
    private func recordHistory(_ location: SettingsLocation?) {
        // nil 是"什么都没选中"(比如「有软件更新可用」那一行消失时 List 清掉选中),不是一个能
        // 回去的位置。抑制也一并解除:目标位置若永远等不到,两颗键会从此不再记账。
        guard let location else {
            historyNavigationTarget = nil
            return
        }
        if let target = historyNavigationTarget {
            // 到达目标才解除抑制;在那之前的中间帧同样不记。
            if location == target { historyNavigationTarget = nil }
            return
        }
        history.record(location)
    }

    /// 后退键。跟前进键分开两个 `ToolbarItem` 摆在同一个 placement 里 —— macOS 26 会把
    /// 相邻的工具栏项自动拼成一枚胶囊(中间一道分隔线),正是系统设置那对键的样子。
    ///
    /// **不要包 `ControlGroup`**:那样工具栏里只渲染得出第一颗键、前进那颗整个消失,
    /// 而且整组被挤到标题下面居中(实测截图)。`ControlGroup` 是给内容区用的,放进
    /// `ToolbarItem` 会跟工具栏自己的分组逻辑打架。
    @ViewBuilder private var historyBackButton: some View {
        Button(action: goBack) {
            Label(L10n.t("后退"), systemImage: "chevron.backward")
        }
        .disabled(!history.canGoBack)
        .help(L10n.t("后退"))
        // ⌘[ / ⌘] 跟 Safari、访达、系统设置同一套;本仓没有别处占这两个组合。
        .keyboardShortcut("[", modifiers: .command)
    }

    @ViewBuilder private var historyForwardButton: some View {
        Button(action: goForward) {
            Label(L10n.t("前进"), systemImage: "chevron.forward")
        }
        .disabled(!history.canGoForward)
        .help(L10n.t("前进"))
        .keyboardShortcut("]", modifiers: .command)
    }

    private var isSearchingSettings: Bool {
        !settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var settingsSearchHits: [SettingsSearchHit] {
        SettingsSearchIndex.shared.search(settingsSearchText)
    }

    /// 搜索时侧栏 List 的内容:结果行(标题 + 面包屑),或一句"没找到"。
    @ViewBuilder private var settingsSearchResultsSection: some View {
        let hits = settingsSearchHits
        if hits.isEmpty {
            Text(L10n.t("没有找到匹配的设置"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            Section {
                ForEach(hits) { hit in
                    SettingsSearchResultRow(hit: hit) { openSettingsSearchHit(hit) }
                }
            }
        }
    }

    private func openFirstSettingsSearchResult() {
        if let first = settingsSearchHits.first { openSettingsSearchHit(first) }
    }

    /// 命中一条:翻分类 到 切分段(写那一页的 @AppStorage 键,那边立刻跟着翻)到 发高亮 / 展抽屉信号 到
    /// 清空搜索框。目录条目怎么写见 Core `SettingsSearchCatalog` 头注。
    private func openSettingsSearchHit(_ hit: SettingsSearchHit) {
        let entry = hit.entry
        // 先写分段、再换面板(同 navigate(to:)):反过来"新面板 + 它上次停的分段"会自成一个位置,
        // 既闪一下,也会在前进 / 后退的历史里多出一条用户从没停过的记录。
        if let key = entry.sectionKey, let value = entry.sectionValue {
            UserDefaults.standard.set(value, forKey: key)
        }
        switch entry.destination {
        case .tab(let raw):
            if let tab = SettingsTab(rawValue: raw) { selection = .tab(tab) }
        case .softwareUpdate:
            selection = .softwareUpdate
        case .account(let name):
            if let destination = AccountDestination.allCases.first(where: { String(describing: $0) == name }) {
                // ListenBrainz / 网页推送 / 推送提醒住在默认折叠的「实验室功能」区,不展开的话
                // detail 切过去了、侧栏却高亮不到任何一行(同 onJumpToAccount 那条注释)。
                if destination != .lastfm {
                    withAnimation { isAdditionalFeaturesExpanded = true }
                }
                selection = .account(destination)
            }
        }
        searchRouter.reveal(hit)
        settingsSearchText = ""
        settingsSearchFocused = false
    }

    /// 平时(不在搜索)的侧栏内容,按系统「设置」的侧栏排布(对照表见
    /// Settings/SettingsSidebarChrome.swift 头注):
    ///   ① 身份区(Last.fm 头像 + 用户名)+ 有新版本时的「有软件更新可用」行;
    ///   ② 六个分类,分组之间只留空白、不加小标题 —— 系统设置的侧栏没有这种标题;
    ///   ③ 「实验室功能」用原生 `Section(isExpanded:)` 折叠(Finder / 邮件侧栏那种悬停露出的
    ///      显示/隐藏),标题旁的「?」悬浮提示放在自定义 header 里。
    @ViewBuilder private var sidebarSections: some View {
        Section {
            LastfmIdentityRow()
                .tag(SettingsSidebarItem.account(.lastfm))
            if updater.shownItem != nil {
                // 点了就是选中「软件更新」页(tag),跟系统设置一样这一行会亮起来。
                SoftwareUpdateSidebarRow()
                    .tag(SettingsSidebarItem.softwareUpdate)
            }
        }

        Section {
            sidebarLabel(.lyrics)
            sidebarLabel(.player)
            sidebarLabel(.appearance)
            sidebarLabel(.shortcuts)
            sidebarLabel(.general)
            sidebarLabel(.about)
        }

        // 默认收起、点 header 才展开,不持久化(每次打开设置窗口都从收起状态开始)。
        // 变量名跟 Section 标题「实验室功能」不一致是有意的,理由同上。
        //
        // 用带 `header:` 尾闭包的 `Section(isExpanded:header:)` 重载 —— 那个 header 是任意 View,
        // 「?」图标照放(放不下的是 `Section(_ title:isExpanded:)` 那个便捷初始化)。
        // Last.fm 不在这里:它是顶上的身份区。
        Section(isExpanded: $isAdditionalFeaturesExpanded) {
            ForEach(AccountDestination.allCases.filter { $0 != .lastfm }) { destination in
                AccountSidebarRow(destination: destination)
                    .tag(SettingsSidebarItem.account(destination))
            }
        } header: {
            // tooltip 弹出延迟看着像没反应,其实是系统默认 tooltip 延迟(~1~1.5s)本身偏长,
            // 真正的调整点是 AppDelegate.swift 里的 NSInitialToolTipDelay,会影响整个 App
            // 所有 .help() 提示,不是这一处独有的问题。
            HStack(spacing: 4) {
                Text(L10n.t("实验室功能"))
                Image(systemName: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help(L10n.t("实验性 Beta 功能"))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // 搜索框里有字时整张侧栏换成结果列表(系统设置就是这么做的);清空就回来。
                // 分类内容本体在 sidebarSections。
                if isSearchingSettings {
                    settingsSearchResultsSection
                } else {
                    sidebarSections
                }
            }
            .listStyle(.sidebar)
            // 搜索框钉在侧栏顶部、不随列表滚。
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsSearchField(text: $settingsSearchText, focused: $settingsSearchFocused,
                                    onSubmit: openFirstSettingsSearchResult)
            }
            // 侧栏宽度跟着系统设置的侧栏(约 215~240pt):顶上多了身份区,用户名要放得下。
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
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
                case .softwareUpdate: SoftwareUpdatePage()
                case .account(let destination):
                    AccountLinkingTab(destination: destination, onJumpToAccount: { target in
                        // 跳转目标如果落在"实验室功能"这个默认折叠的区域里(比如从 Last.fm 卡片跳去
                        // 配置 ListenBrainz),detail 面板会正常切过去,但侧边栏因为这一行还没展开、
                        // 根本不存在于列表里,高亮不到任何一行,看起来就是"跳过去了但侧边栏什么都
                        // 没选中"。.lastfm 本身常驻可见,不需要展开这个折叠区。
                        if target != .lastfm {
                            withAnimation { isAdditionalFeaturesExpanded = true }
                        }
                        selection = .account(target)
                    })
                case nil: ContentUnavailableView(L10n.t("选择左侧的设置分类"), systemImage: "gearshape")
                }
            }
            // 配置文件损坏告示:平时零高度;config.json / features.json 任一启动时
            // 判定为损坏就钉在 detail 列顶部,不挑分页 —— 那时所有保存都被拒,用户在哪一页拨开关都会撞上。
            .safeAreaInset(edge: .top, spacing: 0) { ConfigFileDamageBanner() }
            // 应用到后台服务的状态条:重启进行中 / 失败 + 重试 / 服务停用提示。浮在 detail 列
            // 底部(overlay 不是 inset:它随每次拨开关出现又消失,inset 会让整页内容跳),一处覆盖 20 多个保存调用点。
            .overlay(alignment: .bottom) { CollectorApplyStatusBar() }
            // 窗口**标题**钉死成「设置」,当前分类用副标题。别改回"标题=当前面板名"那套(系统
            // 「系统设置」的做法):那套设计假设这扇窗口有自己独占的 Dock 图标,而这个 App 的
            // Dock/Window 菜单是"设置"/"歌词管理"/"歌词窗口"四扇窗共用的**同一个**图标,右键菜单里
            // 蹦出一条"通用"或"外观",完全看不出它是设置窗口。副标题只出现在标题栏、不会进 Window
            // 菜单/Dock 右键列表,分类上下文照样留得住,只是不再顶替窗口的身份。
            .navigationTitle(L10n.t("设置"))
            .navigationSubtitle(selectedCategoryTitle)
            // 挂在 detail 这一侧(不是 NavigationSplitView 整体),`.navigation` 才会落到
            // 侧栏右边那一段工具栏的最左端 —— 跟系统设置里那对键同一个位置。侧栏那边用
            // `.toolbar(removing: .sidebarToggle)` 腾空了这一格。
            .toolbar {
                ToolbarItem(placement: .navigation) { historyBackButton }
                ToolbarItem(placement: .navigation) { historyForwardButton }
                // 这里**不需要**尾部弹性间隔。曾经加过一个 `ToolbarSpacer`,以为是
                // macOS 26 把 `.navigation` 这一组居中了 —— 装机截图证明加了没有任何变化,
                // 真正的原因是窗口的 `toolbarStyle`(见 SettingsWindowConfigurator)。
            }
        }
        // 宽度:NavigationSplitView 比原来的 TabView 多一列侧边栏,整体相应加宽;同样不设
        // maxWidth/固定高度,各分类继续按内容自动撑高。
        // 高度这一档是跟着「歌词显示」页定的 —— 六页里它最高,它放得下别的页就都放得下。
        // 那一页带页内大标题(68pt,见 AppearanceSettingsTab 里 SettingsPage 那处注释):标题栏
        // 吃掉 32pt,「桌面悬浮歌词」总开关卡的底边落在 605pt、「全部设置」抽屉头的底边在 658pt,
        // 再加 28pt 下留白 = 686pt —— 690 是"悬浮歌词这一段整段不用滚"的下限,720 再多留一点余量。
        //
        // **minHeight 是这两个数里唯一真的能改到已有窗口的那一档。** 这扇窗是 SwiftUI 的
        // `Settings` 场景,尺寸由 macOS 自动存档,idealHeight 只在没有存档时(首次打开 / 重置)
        // 说了算 —— 已经存在的窗口只会被 minHeight 顶上来。所以这一档不能按"别比头部还矮"那种
        // 下限来定,要顶到那张总开关卡整张露出来之上才算数。
        .frame(minWidth: 760, idealWidth: 860, minHeight: 690, idealHeight: 720)
        // 设置搜索的两路信号只在这扇窗口的子树里有值;别处复用行组件拿到的是默认值,不受影响。
        .environment(\.settingsSearchHighlightedTitles, searchRouter.highlightedTitles)
        .environment(\.settingsSearchPendingDrawer, searchRouter.pendingDrawer)
        .environment(\.previewHostVisible, windowSurface.isVisible)
        // 播放器页那张 collector 状态卡直接用它发布的状态,不再自己每 2 秒起一次 launchctl。
        .environmentObject(playerHealth)
        .background(SettingsWindowConfigurator(surface: windowSurface))
        // 见 AppActions.pendingSettingsSelection 注释——Onboarding 的 Last.fm 步骤
        // 借这个信箱指定"这次打开设置窗口要直接停在哪个分类",这里读一次就清空,不影响
        // 之后用户正常打开设置窗口(默认回到上次停留的顶层分类,见 SettingsTab.restoredLastTab)。
        .onAppear {
            if let pending = AppActions.shared.pendingSettingsSelection {
                selection = pending
                AppActions.shared.pendingSettingsSelection = nil
            }
            // 必须排在信箱之后:那一句才决定了用户真正看到的第一页,种早了会把一个
            // 没露过面的页面留在后退键底下。见 seedHistory。
            seedHistory()
        }
        // 窗口**已经开着**时走这条:上面那个 .onAppear 只在窗口新建那一次跑,不会再有第二次
        // (见 AppActions.requestSettings)。两条都要,因为反过来也成立 —— 窗口还没建时
        // subject 发出去没人接,那次得靠信箱。
        .onReceive(AppActions.shared.selectionRequests) { item in
            selection = item
            // 同一次请求在信箱里的那份一并清掉,免得下次新建窗口时又被它顶一次。
            AppActions.shared.pendingSettingsSelection = nil
        }
        // 记住顶层分类(见 SettingsTab.lastTabStorageKey)。只记 .tab:账号页多半在默认折叠的
        // 「实验室功能」区里,记了它下次新建窗口就会是"detail 切过去了、侧栏却高亮不到任何一行"
        // 的状态(同 onJumpToAccount 那条注释);而且账号页的落点本来就由引导页的信箱管。
        // 六个顶层分类都记,包括「关于」——上次停在低频页下次也落在那里,行为可预测。
        .onChange(of: selection) { previous, item in
            if case .tab(let tab)? = item { lastTabRaw = tab.rawValue }
            // 「有软件更新可用」那一行随更新装完 / 跳过 / 已是最新而消失时,List 会把选中清成 nil ——
            // 页面本身还在,别退成「选择左侧的设置分类」,把选中放回去(此时侧栏没有行亮着,跟账号页
            // 在折叠区里那种情形一样)。
            if item == nil, previous == .softwareUpdate {
                selection = .softwareUpdate
                return
            }
            // 选到别的分类了,搜索框的光标就别再闪。
            settingsSearchFocused = false
        }
        // 前进 / 后退的唯一记账口。盯的是**位置**(面板 + 页内分段)而不是 `selection`:页内换个
        // 分段跟换页是同一件事,只盯 selection 会让后退键跳过那一步。见 recordHistory 头注。
        .onChange(of: currentLocation) { _, location in
            recordHistory(location)
        }
        // 见 AuxiliaryWindowActivation 注释——只记账,不碰 Dock 图标,
        // "在 Dock 中显示"这个永久偏好是唯一的决定者。
        // 点空白处让输入框失焦,见 EndEditingOnOutsideClick。
        .background(EndEditingOnOutsideClick())
        .onAppear {
            AuxiliaryWindowActivation.windowDidAppear("settings")
            playerHealth.start()
            // 侧栏身份区的头像:行内 .task 在侧栏 List 的行上不触发,从这里拉一次,
            // 之后由 LastfmAvatarStore 盯着配置变化。
            LastfmAvatarStore.shared.refreshFromConfig()
        }
        // 窗口被挡住 / 最小化时停掉侧栏那条健康检查(每拍一次 tccd 查询 + 一个 launchctl 子进程),
        // 重新看得见时 start 会先补查一次。
        .onChange(of: windowSurface.isVisible) { _, visible in
            if visible { playerHealth.start() } else { playerHealth.stop() }
        }
        .onDisappear {
            AuxiliaryWindowActivation.windowDidDisappear("settings")
            playerHealth.stop()
            // 「软件更新」页攥着的 Sparkle 回复(找到了 / 下完待装)随窗口一起放掉,见那边注释。
            SparkleUpdaterManager.shared.settingsWindowClosed()
        }
    }

    // 保持单行(图标+标题),不加状态小字——账号行有状态是因为账号真的有"连没连上"
    // 这个概念,这几个纯设置分类没有对应的状态,硬凑一行小字是本末倒置。
    //
    // 唯一的例外是「播放器」:它有真实的健康状态(自动化权限被拒 / 后台采集服务没在跑,两条
    // 都会让歌词直接停摆),所以标题尾部带一枚红色计数徽标(SidebarCountBadge,数字 = 警告
    // 条数),跟「有软件更新可用 ①」同一套视觉,悬停看原因。判定规则见 Core `PlayerHealth`,
    // 平时不亮。
    private func sidebarLabel(_ tab: SettingsTab) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(tab.title)
                if tab == .player, let warning = playerHealth.warningText {
                    Spacer(minLength: 4)
                    SidebarCountBadge(count: max(1, playerHealth.warnings.count))
                        .help(warning)
                        .accessibilityLabel(warning)
                }
            }
        } icon: {
            iconBadge(tab.icon, tint: tab.tint)
        }
        .tag(SettingsSidebarItem.tab(tab))
    }

    private var selectedCategoryTitle: String {
        switch selection {
        case .tab(let tab): return tab.title
        case .account(let destination): return destination.title
        case .softwareUpdate: return L10n.t("软件更新")
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
    /// 「顺序优先」列表正在进行的把手拖拽(nil = 没在拖)。纯视图态,不进 store;松手一次 move + save。
    @State private var sourceDrag: SourceDragState?
    /// 各可见行在卡片坐标空间里的静止 frame(PrioritySourceFramesKey 收集)。只在拖拽**开始**那一刻读一次做快照。
    @State private var priorityRowFrames: [LyricsSource: CGRect] = [:]

    /// 一种文字的罗马音开关。跟中文繁简那个 Picker 一样**双写**:AppSettings 负责持久化,
    /// LocalPlaybackSource 负责让当前这首歌立刻重新解析(它的 didSet 会 reload)。
    /// 只写一边的话,要么关了 App 就忘,要么改了要等下一首歌才生效。
    ///
    /// 语言名必须自己摆一个 Text,不能用 Toggle 自带的 label —— 行容器
    /// (SettingsRow/SettingsSubRow)对 trailing 统一加了 .labelsHidden(),Toggle 自己的
    /// 标签会被一起吃掉,屏幕上只剩三个光秃秃的复选框。
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
    /// Apple Music 源要用户先连一次账号才有输出(见 AppleMusicConnection 的头注),
    /// 「歌词来源」卡底下那一行连接状态读的就是它。
    @ObservedObject private var appleMusic = AppleMusicConnection.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 这一页的四个分段。四段各 2–4 项,一屏放得下,而且分法本身就是语义:
    /// 「怎么找到这首歌的歌词」「译文怎么来」「歌词长什么样」「已经存下来的怎么管」。
    ///
    /// 不拆成两个侧边栏条目:那样侧边栏会从 6 项变 7 项,而这四段里真正常用的只有前两段,
    /// 把「显示」「管理」也提到侧边栏是把不常用的东西抬得更高。
    private enum Section: String, CaseIterable, Identifiable {
        case fetch, translation, display, manage
        var id: Self { self }
        var title: String {
            switch self {
            case .fetch: return L10n.t("获取")
            case .translation: return L10n.t("译文")
            // 叫「效果」不叫「显示」:侧边栏另有一个「歌词显示」分类(管三种展示面的开关和样式),
            // 同一个词出现在两层,想调字体的人会先来这里扑空。这一段管的是歌词内容本身的呈现效果
            // (卡拉OK/繁简/罗马音/双行)。rawValue 仍是 display,@AppStorage 存的是 rawValue,
            // 改显示名不动持久化。
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
    /// 鼠标悬在哪个来源**整行**上,跟 hoveredSource 是两件独立的事 —— hoveredSource 只覆盖
    /// sourceCheckbox 自己紧贴内容的那一小块(圆点+文字),跟测试小图标(sourceTestAccessory)
    /// 之间隔着一段 Spacer 空白,指针走在那段空白里时两个悬停信号同时是 false。这个状态覆盖
    /// 复选框+空白+测试图标整行,专门只用来决定"这一行的测试图标要不要露出来";复选框的
    /// 高底色/`.help` 提示仍由 hoveredSource 驱动,两者不合并。
    @State private var hoveredRow: LyricsSource?
    // collector 发布的「哪几家的客户端缓存被系统挡住了」。 只认它的结论,别在 App 里
    // 自己探一遍 —— 两个进程的 TCC 授权各自独立,理由见 LocalCacheAccess 头注。
    @State private var localCacheAccess: LocalCacheAccess.State?
    /// 哪一格的「客户端缓存读不到」说明正开着(`LocalCacheAccessHelp`)。同时最多一个。
    @State private var localCacheHelpSource: LyricsSource?

    // MARK: - 歌词来源可用性测试

    /// 每个来源的测试状态,只在这次设置窗口的会话里有效——不持久化,重开设置就回到
    /// 「还没测过」,这本来就是一次性诊断动作,不是需要记住的偏好。
    private enum LyricSourceTestState: Equatable {
        case testing
        case result(status: LyricSourceTestService.Status, detail: String)
    }
    @State private var sourceTestStates: [LyricsSource: LyricSourceTestState] = [:]
    /// 「全部测试」和任意一个单独的「测试」按钮共用同一个 collector 子进程槽位
    /// (LyricSourceTestService 是单例,新一轮会 `cancelRunning()` 杀掉上一轮)。
    ///
    /// 标题行的「测试」(全部)**不能**被单个来源的测试锁住 —— 不管有没有单个测试在跑,
    /// 右上角那颗按钮永远可以点、永远会正常触发"测全部",所以 `testAllSources()` **不**守卫
    /// `isTestingLyricSources`,随时可以取代正在跑的任何一轮。只有单个来源的测试按钮之间互相
    /// 排队(靠 isTestingLyricSources 置灰),避免连点几个不同来源时几轮互相杀来杀去、满屏"失败"。
    ///
    /// `lyricSourceTestGeneration` 是为了正确处理"取代"这件事:testAllSources 取代一个
    /// 正在跑的单个测试时,被取代那一轮的 collector 子进程会被杀掉、它的 `await` 会抛错,
    /// 它自己的收尾逻辑(把 isTestingLyricSources 置回 false)如果无条件执行,会踩在
    /// **新**这一轮刚设成 true 的状态上——每次发起测试先把这个代数加一,只有自己仍是
    /// "当前最新一轮"时,收尾才会真的改 isTestingLyricSources/写入"失败"结果;被取代的
    /// 那一轮的收尾发现代数已经变了,直接放弃,不覆盖新一轮的状态。
    @State private var isTestingLyricSources = false
    @State private var lyricSourceTestGeneration = 0

    // MARK: - 时间轴偏移那一行的「作用于哪个播放器」

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
    ///     `setPlayerOffset` 静默丢掉;"自动"这层语义本来就由「全部播放器」承担。
    ///  2. 用户信任的未知播放器(浏览器就在这一组 —— 这个功能的动机)。
    ///  3. **已经配过偏移的** —— 哪怕它已经不在信任名单里(取消信任了、App 卸了)也必须列出来,
    ///     否则那个非零偏移会变成看不见、改不动的隐形值(见 LyricsOffsetStore.playerOffsets 注释)。
    ///  4. 此刻正在放的那个 —— 可能是还没加进信任名单的 App,用户往往正是为它才来调这个。
    private var offsetScopeOptions: [String] {
        // 并集/去重/排序的规则连同那三条不变量都在 LyrimuseCore.LyricsOffsetScope 里(纯函数,
        // selftest 覆盖)—— 混在 View 里的话,「配过偏移但已不在信任名单」这类只在特定用户状态
        // 下才暴露的分支除了肉眼盯下拉框以外没法验证。
        //
        // builtInOrder 传 PlaybackPlayer.displayOrder —— 跟"选择播放器"图标网格用同一套按系统语言
        // 排的顺序,同一批播放器在这个下拉框里不该是另一个顺序。LyricsOffsetScope 自己在
        // LyrimuseCore,够不到 displayOrder(它在 App target 里依赖 AppSettings),所以顺序从这里
        // 传进去,见该函数参数注释。
        LyricsOffsetScope.options(
            builtInOrder: PlaybackPlayer.displayOrder,
            trusted: features.trustedPlayers,
            configured: Set(offsets.playerOffsets.keys),
            nowPlaying: nowPlayingBundleID
        )
    }

    /// bundle id 到 人看得懂的名字。内置的用枚举自带的显示名,信任项用当初存下来的那份(空串时
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

    // 标题/副标题/help 都是**固定文案**,不跟着下拉框选中项变 —— 每换一次选中项整行文案跳
    // 一次;而且这一项的语义是二选一,不是"额外叠加"。
    @AppStorage("settings:lyricsSection") private var sectionRaw = Section.fetch.rawValue
    private var section: Section { Section(rawValue: sectionRaw) ?? .fetch }

    var body: some View {
        // 这一页没有预览条,也就不需要固定头部;分段选择器跟「歌词显示」页一样留在滚动区
        // (理由见那一页 header 上的注释)。
        SettingsPage(
            title: L10n.t("歌词")
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
        SettingsSegmentedControl(
            selection: Binding(
                get: { section },
                set: { next in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        sectionRaw = next.rawValue
                    }
                }),
            options: Section.allCases,
            label: \.title
        )
        // 不铺满整列:居中的固定宽度跟上面居中的标题/说明是同一根轴,铺满会让它看起来像
        // 一条工具栏,而不是页头的一部分。
        .fixedSize()
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var currentSection: some View {
        switch section {
        case .fetch:
            // 两张卡:第一张只回答「从哪儿找」—— 来源网格 + 测试;第二张回答「找到之后怎么定」
            // —— 匹配算法、顺序、后台许不许换、预取、手动锁定。卡名「歌词来源」只对第一样成立,
            // 所以第二张**不给卡名**,跟「译文」「效果」两张卡同一个做法(卡里第一行的标题已经
            // 说明白这张卡管什么)。
            //
            // 预取排在决策项(选来源、挑算法)后面:它是无感优化,不该压在真正要动的决策上面。
            sourcesCard
            matchingCard
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
    private var sourcesCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("歌词来源")) { testAllSourcesButton }
            CardDivider()
            // 固定 4 列的网格,不用 WrapLayout 按可用宽度贪心折行 —— 那样折行位置完全由译文长度
            // 决定("网易云音乐"5 个字、英文界面下 "NetEase Cloud Music" 20 个字符,同一张卡在两种
            // 语言下从两行变三行)。固定列数下行数只取决于「来源数 ÷ 4」,跟语言、译文长短无关,
            // 以后加新源最多只多一行。单格文字太长会被 sourceCheckbox 内部的 .lineLimit(1) 截断、
            // hover 出完整名字(.help),不会像 WrapLayout 那样把整张卡的折行结构带歪。
            SettingsRawRow(insetToText: true) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                    alignment: .leading, spacing: 4
                ) {
                    ForEach(LyricsSource.settingsDisplayOrder) { source in
                        // 测试按钮/结果状态放在每一格尾部。
                        //
                        // **别把它 `.overlay` 叠回 sourceCheckbox 上面**:两个 Button 叠在一起会抢
                        // 同一次 mouseDown,这层竞争发生在 AppKit 的 hit-test 阶段,SwiftUI 手势优先级
                        // (`.highPriorityGesture`)根本没有机会介入 —— 它只能调解 SwiftUI **自己**手势
                        // 系统内部的优先级,管不到"外层这个 Button 的 mouseDown 被 AppKit 判给了它自己"。
                        // (悬停不受影响:悬停走 NSTrackingArea,两个叠在一起的区域各自独立、互不冲突,
                        // 所以这个坑只在点击上暴露。)正确做法是让两个控件在布局上就不重叠、变成平级
                        // 兄弟节点(HStack + Spacer):sourceCheckbox 因此不自己占满整格宽度,这里的
                        // HStack 补上"占满整格"的职责,Spacer 把测试小图标推到真正的尾部。
                        HStack(spacing: 4) {
                            sourceCheckbox(source)
                            Spacer(minLength: 0)
                            localCacheAccessory(source)
                            appleMusicConnectionAccessory(source)
                            sourceTestAccessory(source)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 在整行(复选框+空白+图标)上补一层独立的悬停追踪,专门喂给 hoveredRow:
                        // sourceCheckbox 自己的悬停范围紧贴内容(不占满整格,见上面那段),跟测试小图标
                        // 之间隔着 Spacer 撑出来的一段空白,指针走在那段空白里时两边的悬停信号都不成立。
                        // 这一层只用来决定测试图标要不要露出来,跟 sourceCheckbox 那层驱动高亮底色/
                        // `.help` 的 hoveredSource 是两件不同的事,不合并。
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveredRow = hovering ? source : (hoveredRow == source ? nil : hoveredRow)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { appleMusic.refresh() }
        // 这个状态只在用户改授权时才变,5 秒一次绰绰有余;`LocalCacheAccess.current` 自己按
        // mtime 缓存,没变过的一拍只花一次 stat。视图消失即取消,没有常驻计时器。
        .settingsPolling(every: 5, runsOnAppear: true) {
            let state = LocalCacheAccess.current
            if state != localCacheAccess { localCacheAccess = state }
        }
    }

    /// 那一格右侧的「客户端缓存读不到」提示。
    ///
    /// 酷狗 / QQ 音乐 / 网易云的歌词缓存住在各自的 `~/Library/Containers/…/Data` 里,读它要
    /// 「完全磁盘访问」。没授权时这三条本地快速路径整条哑掉,而它们全程 fail-soft —— 界面上
    /// 不说一句的话,表现与"这个源本来就慢"完全一样。点这个图标弹出说明(`LocalCacheAccessHelp`)。
    ///
    /// 命中区(18×18 的 `contentShape`)比图标(12pt)大一圈,而且说明走 popover 不走 tooltip:
    /// 原先两者都只有图标那么大,指针要压准才出得来提示 —— 这颗锁是唯一能解释"这个源为什么没在用
    /// 本地缓存"的地方,它不该难点。
    ///
    /// **只在 collector 报了被拒时出现**:能读是常态,常态不该占版面(同旁边那个测试图标
    /// "没测过就悬停才出现"的取向)。而且状态只认 collector 的 —— App 自己探一遍得到的是
    /// 另一个进程的授权结果,摆给用户就是个与事实无关的结论,理由见 `LocalCacheAccess` 头注。
    ///
    /// 别按来源名硬编码"哪三家需要授权":需不需要由**缓存路径在不在 `~/Library/Containers/`
    /// 下**决定(汽水在 `Application Support/`、Apple Music 在 `Caches/`,都不需要),那个判断
    /// 在 collector 侧,这里只负责显示它报上来的名单。
    @ViewBuilder
    private func localCacheAccessory(_ source: LyricsSource) -> some View {
        if LocalCacheAccess.isDenied(source.rawValue, state: localCacheAccess) {
            Button {
                localCacheHelpSource = source
            } label: {
                Image(systemName: "lock.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(format: L10n.t("读不到 %@ 的歌词缓存，点击看怎么处理"), source.displayName))
            .popover(
                isPresented: Binding(
                    get: { localCacheHelpSource == source },
                    set: { if !$0, localCacheHelpSource == source { localCacheHelpSource = nil } }
                ),
                arrowEdge: .bottom
            ) {
                LocalCacheAccessHelp(source: source) {
                    // 只有 collector 真的重新发布了状态(这个源不在名单里了)才会走到这里,
                    // 所以这一下关闭是"事情办成了",不是"指令发出去了"。界面不自己改
                    // localCacheAccess —— 那等于替另一个进程宣布结果。
                    localCacheHelpSource = nil
                }
            }
        }
    }

    /// Apple Music 那一格右侧的连接入口。
    ///
    /// 挂在格子上,不在卡片底部单独占一行:连接状态是**这一个源自己的属性**,跟它同格才
    /// 说得通;单独一行会让这张卡凭空多出一条只服务于十一分之一内容的横栏,视觉上还像是
    /// 整卡的设置项。
    ///
    /// 显隐规则跟旁边那个测试图标(sourceTestAccessory)刻意不同:那个"没测过"时要悬停才
    /// 出现,因为不测也不影响用;而**没连接**是这一路"勾了也没有输出"的唯一原因,必须常显
    /// —— 所以未连接 / 快到期时常亮橙色,只有一切正常时才退回悬停可见。
    @ViewBuilder
    private func appleMusicConnectionAccessory(_ source: LyricsSource) -> some View {
        if source == .applemusic {
            let needsAttention = !appleMusic.isConnected || appleMusic.needsRenewal
            let isVisible = needsAttention || hoveredRow == source || showAppleMusicConnection
            Group {
                if isVisible {
                    Button { showAppleMusicConnection = true } label: {
                        Image(systemName: needsAttention ? "exclamationmark.circle.fill" : "person.crop.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("Apple Music 账号连接"))
                }
            }
            // 固定命中区,理由同 sourceTestAccessory:图标还没出现的那一帧也要能接住悬停。
            .frame(width: 16, height: 16)
            .popover(isPresented: $showAppleMusicConnection, arrowEdge: .bottom) {
                appleMusicConnectionPopover
            }
        }
    }

    /// 连接管理弹窗:状态一句话 + 一到两个动作。
    ///
    /// 三种形态:未连接(说明它能带来什么 + 「连接账号」)、已连接(区域 + 到期日 + 「断开」)、
    /// 快到期/已过期(橙色提醒 + 「重新连接」)。到期日是按 Apple 的 6 个月硬上限推算的,
    /// 不是令牌自己声明的——它不是 JWT,读不出 exp。
    private var appleMusicConnectionPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(appleMusic.isConnected ? (appleMusic.needsRenewal ? Color.orange : Color.green) : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(verbatim: "Apple Music")
                    .font(.system(size: 12, weight: .semibold))
            }
            // `.frame(width:)` 钉死宽度 + `.fixedSize(horizontal: false, vertical: true)`
            // 才会真的按这个宽度换行,单用 maxWidth 会被按理想单行宽度撑开——同 sourceTestAccessory
            // 那个 tooltip 踩过的坑。
            Text(appleMusicConnectionSubtitle)
                .font(.system(size: 11))
                .foregroundStyle(appleMusic.isConnected && appleMusic.needsRenewal ? Color.orange : Color.secondary)
                .multilineTextAlignment(.leading)
                .frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if appleMusic.isConnected {
                    if appleMusic.needsRenewal {
                        Button(L10n.t("重新连接")) {
                            showAppleMusicConnection = false
                            appleMusic.connect()
                        }
                        .disabled(appleMusic.isConnecting)
                    }
                    Button(L10n.t("断开")) { appleMusic.disconnect() }
                } else {
                    Button(appleMusic.isConnecting ? L10n.t("登录中…") : L10n.t("连接账号")) {
                        // 先收起弹窗再开登录窗:登录窗是独立 NSWindow,会盖在设置窗前面,
                        // 留着这个 popover 只会在它背后半悬着。
                        showAppleMusicConnection = false
                        appleMusic.connect()
                    }
                    .disabled(appleMusic.isConnecting)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    @State private var showAppleMusicConnection = false

    private var appleMusicConnectionSubtitle: String {
        guard case let .connected(_, storefront) = appleMusic.state, let expiresAt = appleMusic.expiresAt else {
            return L10n.t("连接后可获取 Apple Music 官方歌词，需要 Apple Music 订阅")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = formatter.string(from: expiresAt)
        if expiresAt.timeIntervalSinceNow <= 0 {
            return L10n.t("登录已过期，需要重新连接")
        }
        // storefront 可能还是空的(登录时没等到 itua cookie),collector 首次取词时会问
        // Apple 补上。这里显示成「—」而不是猜一个区,免得用户看到一个错的区域码。
        let region = storefront.isEmpty ? "—" : storefront.uppercased()
        if appleMusic.needsRenewal {
            return String(format: L10n.t("%@ · 登录将在 %@ 过期，建议重新连接"), region, date)
        }
        return String(format: L10n.t("已连接 · %@ · 登录有效期至 %@"), region, date)
    }

    /// 「匹配算法」这一行的副标题:只说**当前选中**那一档是怎么取的,换档就换一句。
    ///
    /// 不用「?」气泡把两档合写在一起:常显的一句比藏在悬停里的两句更容易被读到,而且每句都
    /// 可以省掉那个"这是在说哪一档"的前缀 —— 右边 radio 已经标明了。
    private var matchingModeSubtitle: String {
        switch features.lyricsSourceMode {
        case .smart: return L10n.t("给每个来源打分，取分最高的")
        case .priority: return L10n.t("不打分，按下面的顺序取第一个有结果的来源")
        }
    }

    /// radio 的标签。「智能算法」带「（推荐）」后缀 —— 这是"推荐"这层语义唯一的表达方式。
    ///
    /// 别再往控件上叠图标(星标之类)来强调推荐:分段控件桥接成 NSSegmentedControl,没法在
    /// 某一格里放东西,只能往控件**外面**叠装饰,而任何叠在原生控件上的东西都不像原生。radio
    /// 每一档有自己的一行文字,「推荐」就写进标签里(同引导页「Apple Music 自动化权限（推荐）」)。
    /// 想强调就改文字。
    private func matchingModeLabel(_ mode: LyricsSourceMode) -> String {
        mode == .smart
            ? String(format: L10n.t("%@（推荐）"), mode.displayName)
            : mode.displayName
    }

    /// 第二张卡:找到来源之后"怎么定"—— 匹配算法、(顺序优先时的)手排顺序、后台许不许换、
    /// 预取、手动锁定。为什么跟来源网格分开成两张卡,见 currentSection 里 `.fetch` 分支的注释。
    private var matchingCard: some View {
        SettingsCard {
            // 二选一用原生 **纵向 radio 组**(macOS 系统设置里「点按滚动条时」那种,两颗 radio
            // 上下排、跟标题顶对齐),不用分段控件。三个原因:
            //   1. 每档一行文字,「（推荐）」才有地方写(见 matchingModeLabel);
            //   2. 分段控件是一块灰底色块,在一列开关里是这张卡上最重的东西,radio 只有两个
            //      小圆圈,视觉分量跟旁边的 Toggle 相当;
            //   3. 英文标签(“Smart Matching (recommended)”)比中文长一倍,横排会挤到左边的副
            //      标题折行,纵排的宽度只取决于最长那一条标签,两种语言下行高都是两行 radio。
            // 副标题随选中项变(matchingModeSubtitle),不另给「?」气泡。
            SettingsRow(
                icon: "slider.horizontal.3",
                title: L10n.t("匹配算法"),
                subtitle: matchingModeSubtitle
            ) {
                Picker("", selection: Binding(
                    get: { features.lyricsSourceMode },
                    set: { features.lyricsSourceMode = $0; Task { await features.save() } }
                )) {
                    ForEach(LyricsSourceMode.allCases) { mode in
                        Text(matchingModeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            if features.lyricsSourceMode == .priority {
                // 顺序列表支持把手拖拽排序:每行左侧一个 line.3.horizontal 把手,挂 DragGesture;
                // 上下箭头**保留**,是键盘 / VoiceOver 的通路(把手对 VoiceOver 不可操作)。拖拽期间
                // 从本地 sourceDrag 渲染让位与跟随、不碰 store;松手一次 move + 一次 save()。算法
                // (滞回 / 让位槛距 / 写回完整排列)在 Core ReorderDrag,这里只做手势与几何。
                let visible = orderedEnabledSources
                ForEach(Array(visible.enumerated()), id: \.element) { index, source in
                    CardDivider()
                    priorityRow(index: index, source: source, visible: visible)
                }
            }
            CardDivider()
            // 「自动跟进算法升级」:控制后台会不会按最新版本的算法自动调整已经选定的歌词。
            //
            // 紧挨着「匹配算法」放:这两项回答的是同一个问题的两半 —— 前者是"怎么选",这个是
            // "选完之后还许不许后台改主意"。分开摆的话,用户在别处看到歌词被换掉,想不到要回
            // 这一段来关。
            //
            // 它**只管"换掉已经选定的那份"**:首次填充(一条歌词都没有)、封面/译文回填、
            // 用户自己点「重新自动匹配」都不受它影响。闸门落在 collector 的
            // needsLyricsRescore / needsLyricsRetry 两处(见 features.go LyricsAutoUpgrade),
            // 这行 help 的两句就是照那两处的真实行为写的,改那边记得回来改这里。
            SettingsRow(
                icon: "arrow.triangle.2.circlepath",
                title: L10n.t("跟进算法升级"),
                help: L10n.t("开（默认）：匹配算法或打分规则更新后，后台会重新评估已有歌词，可能换成更合适的一份\n关：一旦定下来就不再自动更换；首次解析、手动重搜和手动编辑不受影响")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.lyricsAutoUpgrade },
                    set: { features.lyricsAutoUpgrade = $0; Task { await features.save() } }
                ))
            }
            CardDivider()
            // "解析"(而非"预取")避免被误读成预先加载音频本身,这个开关从不碰音频。
            SettingsRow(
                icon: "square.stack",
                // 不给 ? 提示:预取本来就是无感的(成功与否用户都看不见),标题本身已经说清楚这个
                // 开关做什么,为它常驻一个 ? 是拿噪声换不了任何决策。
                //
                // 标题只说"待播",不说具体从哪来:能读到播放器队列时就是队列里的下几首,读不到
                // 退回同一张专辑里的其它曲目(见 collector/upcoming.go)。哪条路走得通取决于用的是
                // 哪个播放器、此刻在播什么,摆进标题只会让用户以为自己能选。
                //
                // 「待播」取自系统音乐 App 的 Up Next(繁中/英文界面也照这个词对齐),不是自造词;
                // 「解析」而非"预取/预载",理由见上面那行 —— 这个开关从不碰音频。
                title: L10n.t("预解析待播曲目")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.albumPrefetch },
                    set: { features.albumPrefetch = $0; Task { await features.save() } }
                ))
            }
            CardDivider()
            // 「采纳候选要不要顺带锁定这首歌」的开关 —— 见 LyricsManagerView /
            // LyricsQuickSearchWindow / LyricsWindowView **三处**「采纳候选」调用点的 markManual
            // 参数注释(grep `LyricsSearchSheet(` 数得到,改一处就要三处一起改)。默认关,纯本地
            // UI 偏好,不需要 collector 知道,存进 AppSettings 而不是 FeatureSettingsStore。
            //
            // 这是整个设置页唯一一个**会去改歌词缓存**的开关(其余全是显示偏好):翻面时
            // 要追溯处理存量(见下面 Toggle 的 setter)。追溯逻辑刻意留在这里而不是
            // AppSettings 的 didSet —— 它需要弹确认框、需要给回执,那是 View 的事;而且
            // didSet 会被配置导入那条路径顺带触发,那时候整份歌词缓存本来就是跟着一起换的,
            // 不该再自作主张改一遍锁定状态。
            SettingsRow(
                icon: "lock.circle",
                title: L10n.t("锁定手选歌词"),
                // 文案按"开/关各一行"写(跟上面「匹配方式」那条 help 同一个格式):这个开关唯一要
                // 回答的问题就是"开跟关差在哪",两行对照比一整段散文快得多。**格式别动** —— 开/关
                // 各一行的对照结构是这条 help 的骨架,散文化会让"开跟关差在哪"重新变难读。
                //
                // 刻意不提"等同于直接编辑歌词":那是实现口径(markManual),读的人不知道"直接编辑
                // 歌词"背后也是一次冻结,拿它当类比等于用一个更陌生的东西解释。
                //
                // 这行字必须跟 `manualPickLocksLyrics` 的真实两态逐字对得上。以后改这个开关的
                // 行为,这行字要一起改。
                help: L10n.t("关（默认）：只换这一次，以后自动重搜或打分变化仍可能换掉\n开：锁住这首歌的歌词，自动匹配不再碰它\n打开时，之前手动选过的歌一并锁定（已被自动换掉的除外）")
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
            // 回执常驻一小会儿。 位置在卡片最末、开关行的正下方 —— 别挪到别处:这条话
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
        // 顺序列表拖拽排序的几何基础(见 priorityRow / priorityDragGesture):行中线与指针位移都在这个命名坐标
        // 空间里量;行数或匹配模式一变就丢掉进行中的拖拽,避免 offset 残留在一份已经不同的列表上。
        .coordinateSpace(name: Self.priorityListSpace)
        .onPreferenceChange(PrioritySourceFramesKey.self) { priorityRowFrames = $0 }
        .onChange(of: orderedEnabledSources.count) { _, _ in sourceDrag = nil }
        .onChange(of: features.lyricsSourceMode) { _, _ in sourceDrag = nil }
    }

    /// 翻「手动选定歌词后锁定」这个开关之后的追溯扫描 + 回执。
    ///
    /// **每一条路径都必须说话**,包括"一首都没动"。0 命中时直接 `return` 的话,留痕数本来
    /// 就是 0 的用户(历史上采纳过的歌没有记号)打开开关会什么都不发生、也没有任何解释,
    /// 看起来跟功能坏了一模一样。
    ///
    /// 而且"没动"要分得清是哪一种:从没手动选过 / 选过但内容已被自动换掉 / 已经都锁着了,
    /// 三种的下一步动作完全不同(见 ManualPickLock.PickState)。
    private func runManualPickLockSweep(locking: Bool) {
        manualPickLockNotice = nil
        manualPickLockBusy = true
        Task {
            // 必须先 reload:设置页从没打开过「歌词管理」时 store.raw 是空的,直接算目标集
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

            // 打开 = "我手动选过的都该是锁着的",直接做,不问。
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

    /// 一个来源 = 一个控件:选中圈填品牌色、里面一个白勾,没选中就是一圈空心灰环 + 文字
    /// 转次要色。勾负责"选没选中"、颜色负责"这是哪个来源",一个控件说两件不重复的事。
    ///
    /// 别拆回"系统复选框 + 品牌色圆点并排":那是同一个状态画了两遍,而且五个亮蓝方块横成
    /// 一排会把它们各自的品牌色全压住,一眼看过去只剩一串蓝。
    ///
    /// 也别加胶囊底色:这一页其余控件全是系统原生件、全是白底卡片 + 行,一排彩色药丸是
    /// 外来物。悬停时才给一层极淡的底,只为了说明"这里能点"。
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
                // 固定 4 列网格里,格宽是卡片宽度的四分之一 —— 英文译名("NetEase Cloud Music"
                // 这类)在这个宽度下装不下。所以用截断:单行 + 尾部省略号,鼠标悬停(.help)给出
                // 完整名字,不让某一个来源的长译名撑破所在的整列宽度。
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // 这个 Button **不要**加 `.frame(maxWidth: .infinity, alignment: .leading)`:它只
            // 按自己的内容(圆点+文字)天然宽度来,"占满整格"交给外层 HStack 负责 —— 占满的话会
            // 把 Spacer 和测试小图标挤没空间。测试图标是 HStack 里的平级兄弟、不是叠上来的
            // overlay(叠加方案在实机上点击互相抢占,见 ForEach 调用点的详细注释)。
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.secondary.opacity(0.12) : .clear))
            // 整块(含内边距)都算命中区,不是只有文字和圆点上才点得到
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(sourceHelpText(id))
        .onHover { hoveredSource = $0 ? id : (hoveredSource == id ? nil : hoveredSource) }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func setSource(_ source: LyricsSource, enabled: Bool) {
        // 关掉最后一个来源是不允许的(下面那句 count > 1 的守卫),这时集合没有任何变化 ——
        // 只在真的变了才 save():无条件保存会让一次被拒绝的点击照样写一遍 features.json 并
        // kickstart 一次 collector,后台服务被杀掉重启、期间歌词整片空掉(launchd 对连续
        // kickstart 还有约 10s 的节流),而配置压根没变。
        let before = features.lyricsSources
        if enabled {
            features.lyricsSources.insert(source)
        } else if features.lyricsSources.count > 1 {
            features.lyricsSources.remove(source)
        }
        guard features.lyricsSources != before else { return }
        Task { await features.save() }
    }

    /// 卡片标题行右侧的「测试」按钮,只测**已启用**的源(跟 collector 侧不传 -source 时默认
    /// 测全部已启用源的口径一致)。
    ///
    /// **故意不 `.disabled(isTestingLyricSources)`** —— 任何时候都能点、都会触发全部检测,
    /// 取代机制见 `isTestingLyricSources`/`lyricSourceTestGeneration` 声明处注释。`Text`/图标
    /// 仍然按 `isTestingLyricSources` 换成"测试中…"/转轴,但这个视觉状态**不决定能不能点**:
    /// 哪怕当前是单个测试按钮让它进入"测试中"的显示,这颗按钮依旧可点,点下去会取代那一轮。
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

    /// 每个来源格子尾部的测试按钮/结果状态。跟 `sourceCheckbox` 是平级的 HStack 兄弟节点,
    /// 不叠在它上面(叠加方案在实机上悬停/点击会跟铺满整格的开关 Button 打架)。三种形态:
    /// - 还没测过、也没在悬停:完全不显示(不给静止状态添视觉噪音)。
    /// - 悬停中(还没测过,或者正在测):给一个中性的"测试"小图标按钮,鼠标真压在它自己身上
    ///   时再叠一层圆形底色 —— 单靠一个裸图标看不出"这是能点的东西"。真在测的时候换成小
    ///   转轴,不管有没有悬停都要看得见。
    /// - 已经有结果:一个按状态上色的小图标,不管有没有悬停都常驻显示(结果是持续有效的
    ///   信息,不该只在悬停时才看得见),再点一次等于重新测这一个源。
    ///
    /// **原因文案用 `.popover` 自绘,不用 `.help()`** —— popover 能精确控制多行换行
    /// (`.frame(width:)+.fixedSize`),`.help()` 换行控制没这么直接。
    ///
    /// **"还没测过"这个态不给提示文案**:图标 + 点击行为已经说明白是干什么的。提示只留给
    /// warn/fail 结果 —— 那才是真正有必要读一下的具体原因。
    @ViewBuilder
    private func sourceTestAccessory(_ source: LyricsSource) -> some View {
        let state = sourceTestStates[source]
        // 用整行悬停(hoveredRow),不是 sourceCheckbox 自己那段更窄的悬停(hoveredSource)
        // ——理由见 ForEach 调用点的 .onHover 注释:两者中间隔着一段 Spacer 空白,只用
        // 后者会在鼠标途经空白那一段时让图标提前消失。
        let isRowHovered = hoveredRow == source
        let isAccessoryHovered = accessoryHoverSource == source
        let tooltip = sourceAccessoryTooltip(state)
        // Apple Music 是唯一一个"没配置账号就测不出任何东西"的源(见 AppleMusicConnection),
        // 未连接时整个测试入口**不出现**,不做成灰色禁用图标 —— 禁用态的灰图标(还带 hover
        // 底色)只是一个点不动的干扰物,该做的引导旁边那颗橙色感叹号已经在做了。
        //
        // 连**已有测试结果**那颗图标一起藏:它兼任"重测"按钮,断开账号后若留着,上一轮的
        // 旧结果仍然可点,又绕回那条必然失败的路;而那个结果本身也已经过期了。
        let testBlockedForConnection = source == .applemusic && !appleMusic.isConnected
        Group {
            if testBlockedForConnection {
                EmptyView()
            } else {
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
        }
        // 固定尺寸的命中区,不随内容是否可见变化——悬停判定(下面的 .onHover)要在图标
        // 还没出现(比如"还没测过、鼠标刚移进这一格"那一帧)时也能立刻生效,不依赖内容
        // 本身有没有渲染出东西来提供可命中的几何。
        .frame(width: 16, height: 16)
        // 鼠标真压在这个控件上时给一圈圆形底色——单靠图标本身的颜色变化不够明显,这一层才是
        // "这是可点的东西"最直接的信号(跟设置页其它按钮 hover 时的反馈同一个语言:有底色变化
        // = 能点)。没连账号时连 hover 底色一起跳过,否则那一格会冒出一个空的灰色圆底。
        .background(Circle().fill(isAccessoryHovered && !testBlockedForConnection ? Color.secondary.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .disabled(isTestingLyricSources || testBlockedForConnection)
        .onHover { hovering in
            guard !testBlockedForConnection else { return }
            accessoryHoverSource = hovering ? source : (accessoryHoverSource == source ? nil : accessoryHoverSource)
        }
        .popover(isPresented: Binding(
            get: { isAccessoryHovered && tooltip != nil },
            set: { shown in if !shown { accessoryHoverSource = nil } }
        ), arrowEdge: .bottom) {
            if let tooltip {
                // `.frame(maxWidth:)` 单独用不住(文案会被截断):popover 的内容尺寸是按 Text
                // 的理想单行宽度算的,`maxWidth` 只是给了一个上限,不会主动把宽度收窄逼着它换行。
                // 要 `.frame(width:)` 钉死宽度 + `.fixedSize(horizontal: false, vertical: true)`
                // (横向不再收缩、纵向随内容长高)才会真的按这个宽度换行。
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
    /// 不再守卫 `isTestingLyricSources`——「全部测试」现在随时可以点、
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

    /// **故意不守卫 `isTestingLyricSources`** —— 这是唯一一个"随时能点、会取代任何正在
    /// 跑的一轮"的入口,跟 `testSource` 的取代/generation 机制完全对称,理由见
    /// `isTestingLyricSources` 声明处注释。
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
            // 顺序是一条链:要不要显示译文 到 要哪种语言 到 没有译文时兜底 到 兜底要的语言包。
            SettingsRow(
                icon: "text.bubble",
                title: L10n.t("显示译文"),
                help: L10n.t("只影响桌面悬浮歌词和歌词窗口；灵动岛受空间所限不支持，菜单栏只能显示一行。")
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
            // 系统翻译按语言分别下载语言包,没装的语言(日语/韩语默认就没装)只能退回联网翻译。
            // 下载弹窗是系统 UI,只有 SwiftUI 的 .translationTask 建出来的 session 才有权拉起它 ——
            // 采集器那个子进程即使在 macOS 15…25 上挂了离屏视图也**刻意不碰**语言包下载
            // (它没有界面,弹窗会没头没尾),所以入口必须在这里。
            //
            // 闸是 15 而不是 26:`LanguageAvailability` 与 `.translationTask` 都是 macOS 15 起就有,
            // 端上翻译在 15…25 上同样能跑(见 lyrics-translate/main.swift)。这里卡 26 的话,
            // 那批系统的用户装不了语言包,端上那条路就永远是 notInstalled。
            if #available(macOS 15.0, *), features.lyricsMachineTranslation {
                CardDivider()
                LanguagePackRow()
            }
        }
    }

    // 「效果」这一段只放**改歌词内容本身**的三项:繁简 / 罗马音 / 时间轴偏移 —— 四个展示面
    // 看到的是同一份结果。「卡拉OK效果」不在这里:它讲的是"某个面怎么画",按「歌词显示」那一页
    // "按形态分"的结构拆成悬浮歌词 / 灵动岛 / 菜单栏各一颗(`overlayLyricsKaraoke` /
    // `notchLyricsKaraoke` / `menuBarLyricsKaraoke`),歌词窗口始终逐字。「双行显示」同理,
    // 在悬浮歌词的「排版」里。
    private var displayCard: some View {
        SettingsCard {
            // 这一项对完全不听中文歌的人是纯噪声,按系统首选语言收起来 —— 设置页已有
            // 同类先例(按来源模式/按跟随封面显示的那几行)。
            //
            // `|| 已经不是默认值` 这半边是必须的,不是保险起见:万一判据没覆盖到某个
            // 真实用户(比如系统语言列表里没加中文、但确实在听中文歌),而他之前已经打开过
            // 这个开关,收起来就等于**歌词正在被转换、而那个开关不见了** —— 那是最糟的
            // 一种状态,用户根本无从找回。只要它还在起作用,就一定看得见。
            //
            // 它是卡里**第一行**,分隔线要跟着条件走:这一行不显示时下一行不能顶着一条
            // 孤零零的分隔线。
            if AppSettings.userReadsChinese || settings.hasSeenChineseLyrics
                || settings.lyricsChineseVariant != .off
            {
            SettingsRow(
                icon: "character.bubble",
                title: L10n.t("繁简转换"),
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
            CardDivider()
            }
            SettingsRow(
                icon: "textformat.alt",
                title: L10n.t("显示罗马音"),
                help: L10n.t("只影响桌面悬浮歌词和歌词窗口；灵动岛受空间所限不支持，菜单栏只能显示一行。")
            ) {
                Toggle("", isOn: $settings.showRomanization)
            }
            // 按语言分别开关 —— 同一个人对不同语言的需求常常是相反的:听日文歌要罗马字
            // 才跟得上,听中文歌完全不需要拼音。总开关关着时这几行没有意义,收起来。
            if settings.showRomanization {
                CardDivider()
                // 这一项是"显示罗马音"的附属项,所以用子行(缩进 + 左边那条竖线)而不是主行:
                // 两者都用 SettingsRow 的话长得一模一样,看不出谁属于谁。
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
                            help: L10n.t("只对判定为粤语的歌词生效，用的是粤拼（Jyutping）方案，例如 你好 → nei5 hou2"))
                    }
                }
                // 放进悬停说明而不是常驻副标题 —— 四个语言开关各自已经带了更具体的 help,
                // 行上再顶一句概括是重复的噪声。
                .help(L10n.t("日语、韩语标成罗马字，普通话标成拼音，粤语标成粤拼"))
            }
            CardDivider()
            // 时间轴偏移。跟菜单栏「歌词时间轴」那个单曲微调是两档:这里校的是设备侧的固定延迟
            // (跟哪首歌无关,换首歌照样偏),那里校的是某一份歌词自己的时间轴不准。两者相加才是
            // 实际生效的值,见 LyricsOffsetStore.globalOffsetMs。
            //
            // 步长固定 0.05 秒,刻意不复用「快捷键」页那个「调整步长」:那个是"每按一次键跳多少",
            // 属于手感;这里是一次性把设备延迟校准到位,要的是精度。绑在一起的话,把步长调到 1 秒
            // 的人在这里就没法微调了。
            //
            // 「作用于哪个播放器」那个下拉框真正需要它的是**浏览器**:Arc/Chrome 这类只在切歌时报
            // 一次播放位置,之后 elapsedTime 再也不刷新,只能按墙钟外推
            // (PositionSourceTier.cleanExtrapolated),进度会系统性偏慢;而 Apple Music 那条路径是
            // 精确的、一点都不该补。偏差落在"播放器"这个维度上,不在"歌"上。
            //
            // 两档是**二选一、不相加**:单独配过的播放器只用自己那档,「全部播放器」对它不生效;
            // 调回 0 就撤掉单独设置、重新跟随「全部」。合成规则在 LyricsOffsetStore.baseOffsetMs,
            // selftest 有断言钉住(含一条变异测试验证过的"不许退回相加")。
            //
            // 标题/help 都是**固定文案**、不跟着下拉框选中项变;副标题整条去掉,help 只留
            // "符号往哪边走 + 典型用途"这一句。
            //
            // 「两档二选一、调回 0 就跟随全部」这些规则**界面上不写** —— 它们记在
            // LyricsOffsetStore.baseOffsetMs 的注释和 docs/features/08 里。别再往这一行加解释性文案。
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
                    // 必须 `.fixedSize()`,否则这个数字会竖着一个字一个字往下叠:旁边的 Picker
                    // 早就用 `.fixedSize()` 护住了自己的宽度(见上面那行),HStack 空间紧张时只会挤
                    // 没有保护的那个,数字被压到比单字符还窄,SwiftUI 只能逐字换行。
                    Text("\(AppSettings.signedSeconds(ms: scopedOffsetMs))\(L10n.t("秒"))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
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
            .settingsPolling(every: 2) {
                refreshNowPlayingPlayer()
            }
            .onAppear { refreshNowPlayingPlayer() }
        }
    }

    // 「管理」段拆成两张卡:「歌词库」(库里有什么 + 缺的怎么补)和一张单行卡「歌词文件夹」
    // (库在哪)。三条规则贯穿:
    //   1. 每个动作都落在它所属那一行的**尾部**,不设独立的按钮行;
    //   2. 卡名行右侧只放"这张卡的入口动作"(跟「歌词来源」卡右上角的「测试」同一语法);
    //   3. 统计块的读法照系统设置「储存空间」:总数 + 一条比例条 + 图例,不用六格平级数字。
    @ViewBuilder
    private var managementCard: some View {
        SettingsCard {
            // 「歌词管理」是卡名行右侧的按钮、不占一整行:它是跳到另一扇窗口的入口,不是设置项,
            // 占一行会跟统计块平权。说明文字降为按钮的 tooltip。
            SettingsCardHeader(title: L10n.t("歌词库")) {
                // accessory 策略下打开新窗口得先手动激活 App,不然 openWindow 调了也没反应
                // ——跟 MenuBarMenu.swift 里"歌词管理…"菜单项同一个坑、同一个修法。
                Button(L10n.t("打开歌词管理")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "lyrics-manager")
                }
                .font(.system(size: 11, weight: .medium))
                .controlSize(.small)
                .settingsGlassButtons()
                .help(L10n.t("查看、编辑、重搜已缓存的歌词"))
            }
            CardDivider()
            // 统计块 + 译文 / 罗马音两条从属行都在这个 View 里。数据全部来自 EnrichCacheStore 里
            // 早就存着的字段,没有新增解析。它自己订阅 store、自己在 .task 里 reload(onlyIfChanged:),
            // 不把 @ObservedObject 挂到这一页上 —— 理由见它的头注。
            LyricsLibraryStatsPanel()
        }
        SettingsCard {
            lyricsFolderRow
            // 只在偏离默认位置时多出一条从属行:既说明了状态(你现在不在默认位置),又给出退路。
            // 放在默认状态下也摆一颗"恢复默认"是在给一个点了什么都不会变的按钮占位。
            if !features.lyricsDir.isEmpty {
                CardDivider()
                SettingsSubRow(title: L10n.t("已改用自定义位置")) {
                    Button(L10n.t("恢复默认位置")) {
                        features.lyricsDir = ""
                        Task { await features.save() }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    /// 「歌词文件夹」行:标题 + 路径 + 两颗动作按钮,全部在同一行。
    ///
    /// 路径用 `~` 缩写(默认路径从 38 个字符缩到 26 个)、中间省略,完整路径放 tooltip。
    ///
    /// 尾部是"路径 + 两颗按钮"三件套,而 `SettingsRow` 的 HStack 里"标题列 / Spacer / 尾部"是三个
    /// 可伸缩成员,SwiftUI **均分**亏空(见 04 章「设计决策」第 15 条)。这个仓库为此踩过两种坑:按钮被压成
    /// 没有文字的空圆角矩形(「我的配色主题」命名行)、标题被压成换行。所以三件套里
    /// **只有路径可压**:两颗按钮 `.fixedSize()` 一分不让,路径 `.layoutPriority(-1)` 最后拿空间、
    /// 拿不够就中间省略 —— 它本来就带 `.truncationMode(.middle)`,`~/…/lyrics` 仍看得出首尾,
    /// 而按钮没字、标题换行都是纯粹的坏。默认路径缩写后约 150pt(11pt),两颗按钮约 170pt,
    /// 尾部预算约 430pt,常用情形远够;英文界面按钮更宽("Show in Finder"),也仍在预算内。
    private var lyricsFolderRow: some View {
        let url = features.effectiveLyricsDir
        return SettingsRow(
            icon: "folder",
            title: L10n.t("歌词文件夹"),
            help: L10n.t("换文件夹后，旧文件不会自动搬过去")
        ) {
            HStack(spacing: 8) {
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .help(url.path)
                    // 路径可能很长,给 VoiceOver 一个说得清"这是什么"的标签(可见文案里已经
                    // 没有副标题了,单读一串路径不知道它在说哪件事)。
                    .accessibilityLabel(L10n.t("歌词文件夹"))
                    .accessibilityValue(url.path)
                Button(L10n.t("在访达中显示")) {
                    // collector 那边(见 collector/lyricsexport.go)只在真正解析/导出过
                    // 至少一首歌之后才会建这个目录,这里先兜底建一下,避免文件夹还不存在
                    // 时 NSWorkspace 打不开、又没有任何提示。
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
                .fixedSize()
                Button(L10n.t("更改…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = L10n.t("选择")
                    panel.directoryURL = url
                    if panel.runModal() == .OK, let picked = panel.url {
                        features.lyricsDir = picked.path
                        Task { await features.save() }
                    }
                }
                .fixedSize()
            }
        }
    }

    // 只包含当前启用的来源,按 lyricsSourceOrder 里的相对顺序展示——"顺序优先"模式的
    // 列表只需要用户关心"我选的这几个,先后顺序是什么",被禁用的来源不出现在这份列表里,
    // 不需要用户先想着"跳过那些没打开的"。
    private var orderedEnabledSources: [LyricsSource] {
        features.lyricsSourceOrder.filter { features.lyricsSources.contains($0) }
    }

    // MARK: 顺序优先列表:拖拽排序

    /// 卡片容器的命名坐标空间。行中线在它里面量、指针位移也在它里面算 —— 不能用 value.translation:
    /// 被拖的行自己在动,相对它量的位移会被它自己的位移吃掉(歌词管理列宽把手踩过同一个坑,
    /// 见 LyricsManagerView 那段注释)。
    private static let priorityListSpace = "lyrics-priority-list"

    struct SourceDragState {
        /// 被拖行在可见列表里的原下标。
        var source: Int
        /// 此刻该占的槽位(Core ReorderDrag.targetIndex 带滞回算出来的)。
        var target: Int
        /// 被拖行相对静止位置的纵向位移(已夹在列表首尾之间)。
        var translation: CGFloat
        /// 拖拽开始那一刻各可见行的静止中线,拖拽期间不再更新(让位动画进行中量到的是半路的位置)。
        var rowMidYs: [CGFloat]
    }

    /// 顺序列表里的一行:把手 + 序号 + 色点 + 名称 + 上下箭头。拖拽期间被拖行跟着指针走(不动画),其余行按
    /// Core 算出的让位位移挪(0.15s 让位动画;reduceMotion 时不动画)。frame 收集放在 .offset **之后**,量到的
    /// 才是静止位置而不是挪动中的位置。
    private func priorityRow(index: Int, source: LyricsSource, visible: [LyricsSource]) -> some View {
        let isDragged = sourceDrag?.source == index
        let offset: CGFloat = {
            guard let drag = sourceDrag else { return 0 }
            if isDragged { return drag.translation }
            return ReorderDrag.displacement(row: index, source: drag.source, target: drag.target, rowMidYs: drag.rowMidYs)
        }()
        return SettingsRawRow(insetToText: true) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    // 锁拉丁语区,理由同 SettingsRow 里那处注释(SF Symbols 的部分符号有 CJK 变体)。
                    .environment(\.locale, Locale(identifier: "en"))
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
                    .help(L10n.t("拖动调整顺序"))
                    .accessibilityLabel(L10n.t("拖动调整顺序"))
                    .gesture(priorityDragGesture(index: index, visible: visible))
                Text("\(index + 1)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .trailing)
                Circle().fill(source.color).frame(width: 8, height: 8)
                Text(source.displayName)
                    .font(.system(size: 13))
                Spacer()
                // 箭头保留:键盘 / VoiceOver 的通路。把手是 Image 不是按钮,VoiceOver 操作不了它。
                Button {
                    moveEnabledSource(source, direction: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .accessibilityLabel(L10n.t("上移"))
                Button {
                    moveEnabledSource(source, direction: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(index == visible.count - 1)
                .accessibilityLabel(L10n.t("下移"))
            }
        }
        .offset(y: offset)
        .scaleEffect(isDragged ? 1.015 : 1)
        .zIndex(isDragged ? 1 : 0)
        .animation(isDragged || reduceMotion ? nil : .easeOut(duration: 0.15), value: sourceDrag?.target)
        .background(GeometryReader { geo in
            Color.clear.preference(
                key: PrioritySourceFramesKey.self,
                value: [source: geo.frame(in: .named(Self.priorityListSpace))]
            )
        })
    }

    /// 把手上的拖拽手势。minimumDistance 4:点一下不算拖;macOS 没有按住拖动滚动这回事,不必担心跟滚动区抢。
    /// 开始时一次性快照各可见行的静止中线(任一行还没量到就不开始);拖拽中另一只把手来的事件不理;松手时
    /// 目标位变了才写回一次 lyricsSourceOrder 并 save()。
    private func priorityDragGesture(index: Int, visible: [LyricsSource]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.priorityListSpace))
            .onChanged { value in
                if sourceDrag == nil {
                    let mids = visible.compactMap { priorityRowFrames[$0]?.midY }
                    guard mids.count == visible.count, visible.indices.contains(index) else { return }
                    sourceDrag = SourceDragState(source: index, target: index, translation: 0, rowMidYs: mids)
                }
                guard var drag = sourceDrag, drag.source == index else { return }
                let raw = value.location.y - value.startLocation.y
                drag.translation = ReorderDrag.clampedTranslation(raw, source: drag.source, rowMidYs: drag.rowMidYs)
                drag.target = ReorderDrag.targetIndex(
                    rowMidYs: drag.rowMidYs, source: drag.source, current: drag.target,
                    draggedMidY: drag.rowMidYs[drag.source] + drag.translation
                )
                sourceDrag = drag
            }
            .onEnded { _ in
                guard let drag = sourceDrag, drag.source == index else { return }
                let changed = drag.target != drag.source
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    sourceDrag = nil
                    if changed {
                        features.lyricsSourceOrder = ReorderDrag.moved(
                            features.lyricsSourceOrder,
                            isVisible: { features.lyricsSources.contains($0) },
                            from: drag.source, to: drag.target
                        )
                    }
                }
                if changed { Task { await features.save() } }
            }
    }

    // lyricsSourceOrder 始终是全部源的完整排列(LyricsSource.allCases,现在 9 个),不只是启用的那几个——
    // "上移/下移"只需要在这个完整数组里,把 source 换到"当前可见列表"里相邻的那个启用来源的位置,禁用的
    // 来源被跳过、位置不受影响,不需要临时把它们摘出数组再塞回去。把手拖拽松手时走 Core ReorderDrag.moved,
    // 语义与这里一致(禁用槽位不动),selftest 钉着两者等价。
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

/// 「顺序优先」列表各行在卡片坐标空间里的 frame,按来源收集(见 LyricsSettingsTab.priorityRow)。
private struct PrioritySourceFramesKey: PreferenceKey {
    static let defaultValue: [LyricsSource: CGRect] = [:]
    static func reduce(value: inout [LyricsSource: CGRect], nextValue: () -> [LyricsSource: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    // (灵动岛「显示在哪块屏幕」的选项快照和「所有屏幕」哨兵 tag 在 NotchEditorStage.swift
    //  的 NotchScreenSettingsRows —— 只有那一处在用。)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 这一页用卡片组件(见 SettingsDesignSystem.swift),按展示方式分组:一张卡放四个总开关,
        // 之后每种展示方式各一张卡、只在这种方式开着时出现。「自动隐藏」那两行并进各形态的
        // 「行为」入口,真源见 UI/AutoHideSettingsRows.swift。
        //
        // 每一行自带一句副标题,而不是把四种方式的说明串成一整段 Section 尾注 —— 串起来的话
        // 读者得自己把每一小段对应回上面第几个开关。
        //
        // 分段选择器 + 实时预览一起钉在页顶,下面才是滚动区。预览必须常驻:这一页控件多到本来
        // 就要滚,调下半屏的字号时预览要是滚出视野,等于白做。
        //
        // 这里是真正的固定头部,不是 `.safeAreaInset`。safeAreaInset 是"悬浮"语义:ScrollView
        // 仍占着整块区域,内容会滑到那条悬浮层**底下**去 —— 滚过一段之后选择器和第一张卡看得见
        // 却点不动、鼠标放上去连滚都滚不动。详见 SettingsPageWithStickyHeader 上那段注释。
        //
        // 下面 Group 那段 switch 四个分支**全部**是 `EmptyView()`:三种形态都升级成了内容区里
        // 可交互的编辑台,`sectionPicker` 也因为同一个"固定头部点不动"的毛病挪回了滚动区(见下面
        // 那条注释),所以这个固定头部现在不挂任何东西、纯粹是一层空壳。要不要连壳一起拆是一次
        // 单独的决定。
        SettingsPageWithStickyHeader {
            // 每一段挂**自己那一段**的预览:三种形态各自有反映自己设置的预览,而且不看开关 ——
            // 配置卡关着也能调(见 currentSection),预览要是跟着开关藏起来,调的时候就看不见效果了。
            //
            // 分段选择器**放不进**这个固定头部,尽管"页级导航不该跟内容滚"听起来更对:放进来它
            // 整排点不动。跟预览里放的是哪一个、它内部有没有 hover 手势**无关**(给整块预览加
            // .allowsHitTesting(false) 也没用),是这个固定头部结构本身在 SwiftUI 里的事件派发行为。
            // 真要做,得把选择器换成 NSViewRepresentable 包的 NSSegmentedControl 绕开 SwiftUI 这一层。
            //
            // 选择器因此留在滚动区(那边是另一个 hosting view,命中正常),代价是滚下去之后要滚回
            // 顶部才能换段。
            //
            // 高度按当前段自己的预览走(见 SectionPreviewMetrics 头注),换段的高度变化用这条动画
            // 滑过去,别硬跳 —— 挂 value: sectionRaw,只在换段那一刻生效,不会波及预览内部的高频
            // 刷新(karaoke/跑马灯)。
            Group {
                switch section {
                // 悬浮歌词段和灵动岛段**刻意不钉预览条**:两段的预览都已经升级成内容区里的编辑台
                // (OverlayEditorStage / NotchEditorStage),里面有宽度调整条和工具栏浮层,而这个固定
                // 头部里的控件**点不动**(理由见上面那段注释)。能交互的预览只能待在滚动区。
                case .overlay: EmptyView()
                case .notch: EmptyView()
                // 菜单栏这段也是内容区里的编辑台(MenuBarEditorStage),预览(MenuBarPreviewBar)在
                // 编辑台内部 —— 理由跟悬浮歌词/灵动岛那两支一致,这个固定头部收不到点击。
                case .menuBar: EmptyView()
                // 歌词窗口是一扇按需打开的真窗口,不做编辑台也不钉预览:要看效果就把那扇窗开着调。
                case .lyricsWindow: EmptyView()
                }
            }
            .animation(.easeOut(duration: 0.18), value: sectionRaw)
        } page: {
            SettingsPage(
                title: L10n.t("歌词显示"),
                // 前三个分段 = 三个展示方式开关,互不排斥,直接点名、不写「前三种」让读者去对分段。
                // 第四段「歌词窗口」没有开关,靠快捷键/菜单按需打开,所以副标题要把它分开讲。
                subtitle: L10n.t("悬浮歌词、灵动岛、菜单栏可同时开启，歌词窗口随用随开")
                // 这里**不要**再写 showsHeader: false:六个分类里只有这一页没有 22pt 大标题会显得
                // 不一致。省下来的纵向空间由窗口高度补(见 SettingsView 的 .frame:minHeight 520 /
                // idealHeight 720),保证桌面悬浮歌词的开关能落在首屏。
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
    /// 分法按**歌词落在哪块界面上**走 —— 这是这一页天然的结构:「桌面悬浮歌词」一张卡自己就有
    /// 十几项(字体/字号/颜色/描边/阴影/宽度/位置…),平铺的话开着两三个形态时这一页要滚很久,
    /// 想改灵动岛的一项得先翻过悬浮歌词的全部设置。歌词窗口的配置项(先是「动态封面」)归第四段,
    /// 不再散在「通用」页。
    ///
    /// **没有「其它」段**。跨形态的「自动隐藏」不再是一份共享的值:两个形态各自持有独立的
    /// 设置(`hideDuringScreenCapture` / `hideWhenNotPlaying` 归悬浮歌词,`notchHide*` 归灵动岛),
    /// 两行并进各形态**已经存在**的「行为」入口(悬浮歌词 =「行为」浮层 + 抽屉「窗口」组,
    /// 灵动岛 =「行为」浮层 + 抽屉「行为」组),真源合成一份 `UI/AutoHideSettingsRows.swift`。
    /// 这一页**不再有**任何一张只装隐藏开关的卡。
    ///
    /// 增减 rawValue 是安全的:`section` 那个计算属性带 `?? .overlay` 兜底,存的字符串认不出来
    /// (老版本停在一个已经删掉的段)时会落回悬浮歌词,不会白屏。
    ///
    /// **「歌词窗口」段不是一个 `LyricsSurface`**。前三个的 rawValue 是**跨文件契约**:菜单栏面板
    /// 那边的「全部设置…」要把这一页直接翻到对应的形态那一段,靠的就是往下面那个 @AppStorage 键
    /// 写这几个字符串(LyrimuseCore.LyricsSurface.appearanceSectionRawValue)。改名字不会编译报错,
    /// 只会表现成"长按灵动岛、设置窗口却停在悬浮歌词那一段"。`lyricsWindow` 没有对应的形态
    /// (那扇窗没有常驻开关,也进不了菜单栏面板那排磁贴),`LyricsSurface(rawValue:)` 对它返回 nil,
    /// 设置搜索目录那边因此单列一个构造器。
    private enum Section: String, CaseIterable, Identifiable {
        case overlay, notch, menuBar, lyricsWindow
        var id: Self { self }
        var title: String {
            switch self {
            case .overlay: return L10n.t("悬浮歌词")
            case .notch: return L10n.t("灵动岛")
            case .menuBar: return L10n.t("菜单栏")
            case .lyricsWindow: return L10n.t("歌词窗口")
            }
        }
    }

    // 键名跟菜单栏面板共用同一份常量,别再各写一遍字面量。
    @AppStorage(LyricsSurface.appearanceSectionStorageKey) private var sectionRaw = Section.overlay.rawValue
    /// 「歌词窗口」那一段的预览此刻在看哪个形态 —— 跟 LyricsWindowPreviewStage 共用同一个键
    /// (@AppStorage 同键自动同步),下面那些配置卡跟着它换:完整一套、迷你一套。
    @AppStorage(LyricsWindowPreviewStage.showsMiniStorageKey)
    private var lyricsWindowPreviewShowsMini = false
    /// 「歌词窗口」工具栏此刻弹着哪个浮层(同一时刻只弹一个,同菜单栏编辑台的 `popover`)。
    @State private var lyricsWindowPopover: LyricsWindowToolbarItem?
    private var section: Section { Section(rawValue: sectionRaw) ?? .overlay }

    private var sectionPicker: some View {
        SettingsSegmentedControl(
            selection: Binding(
                get: { section },
                set: { next in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        sectionRaw = next.rawValue
                    }
                }),
            options: Section.allCases,
            label: \.title
        )
        .fixedSize()
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var currentSection: some View {
        switch section {
        case .overlay:
            // 编辑台:这一段的预览是内容区里的主体、不是顶部钉住的一条,因为它可交互(舞台里有
            // 宽度调整条、有点文字/点背景的命中区),而固定头部收不到事件(理由见上面 stickyHeader
            // 里那条注释)。钉条本身仍然在,只是这一段不用它 —— 灵动岛/菜单栏两段照旧,
            // SectionPreviewMetrics 的高度契约不受影响。
            OverlayEditorStage()
            modeToggleCard(
                icon: "captions.bubble",
                title: L10n.t("桌面悬浮歌词"),
                isOn: Binding(
                    get: { settings.classicOverlayEnabled },
                    set: { LyricsOverlayWindowController.shared.setVisible($0) }))
            // 配置项**不跟开关联动**:关着也能调。把它藏起来只是让"先开、调完、再关"变成必须的
            // 操作顺序,并不能阻止什么;而想先配好再打开的人会以为这个形态没有可调项。
            //
            // 除总开关外的 18 项全在这个默认折叠的「全部设置」抽屉里 —— 高频项已经被编辑台和工具栏
            // 浮层接管,剩下的职责只有"全量兜底通路",没有理由常年占着两屏。每一组来自哪个文件见
            // `OverlayAllSettingsDrawer` 的头注,项数那个计数在同一个文件的 `disclosureHeader` 上。
            //
            // 别在这里长出常驻的「行为」卡或「自动隐藏」卡:锁定位置 / 长按拖动 / 悬浮淡化 + 两行
            // 自动隐藏这五项的宿主是编辑台工具栏第二行的 `OverlayBehaviorPopover` 和抽屉的「窗口」组,
            // 跟灵动岛那边取齐;真源 `UI/AutoHideSettingsRows.swift`。
            OverlayAllSettingsDrawer()
        case .notch:
            // 编辑台(照悬浮歌词那一段的范式):一小片屏幕顶端(菜单栏 + 刘海 + 桌面),灵动岛卡片
            // 1:1 挂在上面,里面有宽度调整条和两个工具栏浮层。它取代页顶那条钉住的 NotchPreviewBar
            // —— 那一层收不到点击(理由见上面 stickyHeader 里那条注释)。风格 / 宽度 / 显示在哪块屏幕
            // 都在编辑台里,这一段因此只剩"编辑台 + 总开关 + 显示歌词"三块。
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
            // 灵动岛那批布尔开关**不在页面上常驻**:宿主是编辑台工具栏第二行的三个浮层(见
            // NotchEditorStage.toolbarRow2)+ 下面「全部设置」抽屉兜底。分组按卡片解剖走(歌词行 /
            // 展开态 / 行为),浮层和抽屉调同一份分组视图,见 `NotchBehaviorItem` 头注。
            //
            // 别在这里长出常驻的「自动隐藏」卡:灵动岛自己那一份(`notchHide*`)的两行在编辑台
            // 工具栏的「行为」浮层和抽屉的「行为」组里,真源 `UI/AutoHideSettingsRows.swift`
            // (那条"开着「暂停/无播放时隐藏」就看不到收起动画"的结论也在那个文件里)。
            NotchAllSettingsDrawer()
        case .menuBar:
            // 编辑台(照悬浮歌词/灵动岛两段的范式):预览(MenuBarPreviewBar,原样复用)在编辑台
            // 内部 + 工具栏两个浮层(宽度模式/配色)+ 重置 ▾ + 常驻宽度条。总开关沿用跟灵动岛一样
            // 的排法:排在编辑台**下面**,先看见长什么样再决定开不开。详见 MenuBarEditorStage.swift
            // 顶部注释。
            MenuBarEditorStage()
            modeToggleCard(
                icon: "menubar.rectangle",
                title: L10n.t("菜单栏歌词"),
                isOn: $settings.showLyricsInMenuBar)
            MenuBarAllSettingsDrawer()
        case .lyricsWindow:
            // 预览排在最前面,跟另外三段的编辑台同一个位置 —— 先看见这个形态长什么样,再往下调它。
            //
            // 它跟那三块编辑台有一点本质不同:**不可交互**。那三块是"编辑台"(舞台里能拖宽度、能
            // 点工具栏浮层),这一块是纯预览 —— 歌词窗口的可调项本来就不靠拖拽(位置尺寸是用户自己
            // 拖那扇真窗口),而窗口里那十几处交互(「⋯」菜单、简介/榜单面板、逐行跳转、播控)放进
            // 设置页只会误触真实播放。理由和做法见 LyricsWindowPreviewStage。
            // 工具栏在预览上面,跟另外三段编辑台同一个位置:先看到能调什么,再看效果。
            lyricsWindowToolbar
            LyricsWindowPreviewStage()
            // 预览下面那张卡,位置同另外三段的总开关卡。歌词窗口没有"开不开"这件事,这里放的是
            // 打开那扇真窗口(走 `AppActions.openLyricsWindow`,跟菜单栏面板、快捷键同一个入口)。
            SettingsCard {
                SettingsRow(icon: "macwindow", title: L10n.t("歌词窗口")) {
                    Button(L10n.t("打开")) { AppActions.shared.openLyricsWindow?() }
                }
            }
            // 配置分**两套**:上面预览那个「完整 / 迷你」切到哪个,下面就配哪个。
            //
            // 两种尺寸是两种用法 —— 完整多半是摊开来看的、跟随封面好看;迷你常年钉在角落当挂件,
            // 很多人要的是一块安静的纯色。共用一份就得二选一,所以各存各的(见 AppSettings 里那两组
            // 同名字段)。两边的卡片长得一模一样,所以抽成 lyricsWindowAppearanceCard 带参调用,
            // 别复制两份 —— 复制出来的那份迟早只改一边。
            //
            // 自定义颜色这两档会**反过来决定文字颜色**:歌词窗口的正文默认是白的,那是因为
            // 封面背景必然够暗(烘焙压过 EV −1.9 + 0.15 黑遮罩)。用户填一个浅色背景时白字会直接
            // 消失,所以 LyricsWindowView.hasArtworkBackground 改成了真的算背景亮度 —— 判据在
            // LyricsWindowBackgroundLuma,selftest 钉着边界值。这里只管收集配置。
            // 工具栏浮层之外的全量兜底:默认折叠,跟另外三段的抽屉同一个排法。
            LyricsWindowAllSettingsDrawer {
                SettingsCardHeader(title: L10n.t("外观"))
                CardDivider()
                lyricsWindowAppearanceRows(.background)
                CardDivider()
                lyricsWindowAppearanceRows(.textColor)
                CardDivider()
                lyricsWindowAppearanceRows(.font)
                CardDivider()
                if lyricsWindowPreviewShowsMini {
                    SettingsCardHeader(title: L10n.t("布局"))
                    CardDivider()
                    lyricsWindowAppearanceRows(.layout)
                    CardDivider()
                    SettingsCardHeader(title: L10n.t("顶部信息"))
                    CardDivider()
                    lyricsWindowMiniHeaderRows
                } else {
                    SettingsCardHeader(title: L10n.t("封面"))
                    CardDivider()
                    lyricsWindowCoverRows
                }
            }
        }
    }

    /// 预览上面那排工具栏,照菜单栏编辑台(`MenuBarEditorStage.toolbar`)的样子:胶囊按钮 = 图标 ·
    /// 标题 · 当前值摘要,点开是浮层;浮层里的行跟下面「全部设置」抽屉是**同一份**。摘要和浮层
    /// 都跟着预览停在哪个尺寸走。
    ///
    /// 右边那格是「重置 ▾」,同另外三段:只恢复**当前预览的那个尺寸**(另一套不动,工具栏本来就
    /// 只管当前尺寸),动作本体是 `LyricsWindowStyleDefaults.restoreDefaults(mini:)`。
    ///
    /// 第二行迷你是「布局」「顶部信息」两颗、完整是「封面」一颗;隐藏占位 + `EditorToolbarResetReserve`
    /// 让它跟第一行的胶囊同宽(按钮宽度是一行之内平分出来的,理由同 `MenuBarEditorStage.toolbarRow2`)。
    private var lyricsWindowToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                lyricsWindowToolbarButton(.background)
                lyricsWindowToolbarButton(.textColor)
                lyricsWindowToolbarButton(.font)
                Spacer(minLength: 8)
                Menu {
                    Button(L10n.t("恢复默认")) {
                        LyricsWindowStyleDefaults.restoreDefaults(mini: lyricsWindowPreviewShowsMini)
                    }
                    Text(L10n.t("只恢复当前预览的尺寸"))
                } label: {
                    Label(L10n.t("重置"), systemImage: "arrow.uturn.backward")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack(spacing: 8) {
                if lyricsWindowPreviewShowsMini {
                    lyricsWindowToolbarButton(.layout)
                    lyricsWindowToolbarButton(.info)
                } else {
                    lyricsWindowToolbarButton(.info)
                    lyricsWindowToolbarGhost(.textColor)
                }
                lyricsWindowToolbarGhost(.font)
                Spacer(minLength: 8)
                EditorToolbarResetReserve()
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private func lyricsWindowToolbarLabel(_ item: LyricsWindowToolbarItem) -> EditorToolbarButtonLabel {
        let mini = lyricsWindowPreviewShowsMini
        switch item {
        case .background:
            let mode = mini ? settings.lyricsWindowMiniBackgroundMode : settings.lyricsWindowBackgroundMode
            let name: String = switch mode {
            case .artwork: L10n.t("跟随封面")
            case .solid: L10n.t("纯色")
            case .gradient: L10n.t("渐变")
            case .glass: L10n.t("毛玻璃")
            }
            return EditorToolbarButtonLabel(icon: "photo.artframe", title: L10n.t("背景"), summary: name)
        case .textColor:
            let mode = mini ? settings.lyricsWindowMiniTextColorMode : settings.lyricsWindowTextColorMode
            let name: String = switch mode {
            case .auto: L10n.t("自动")
            case .light: L10n.t("浅色")
            case .dark: L10n.t("深色")
            case .custom: L10n.t("自定义")
            }
            return EditorToolbarButtonLabel(icon: "paintpalette", title: L10n.t("文字颜色"), summary: name)
        case .font:
            var summary = FontFamilyPicker.displayName(
                for: mini ? settings.lyricsWindowMiniFontFamily : settings.lyricsWindowFontFamily)
            if mini {
                summary += " " + String(format: L10n.t("%@pt"), "\(Int(settings.lyricsWindowMiniFontSize))")
            }
            return EditorToolbarButtonLabel(icon: "textformat", title: L10n.t("字体"), summary: summary)
        case .layout:
            // 「简洁」档下长句处理改成了滚动才追加 —— 默认值不报,跟菜单栏「布局」摘要同一条规则。
            var summary = LyricsWindowMiniLyricsLayoutLabel.text(for: settings.lyricsWindowMiniLyricsLayout)
            if settings.lyricsWindowMiniLyricsLayout == .compact, settings.lyricsWindowMiniLineOverflow == .scroll {
                summary += " · " + OverlayLineOverflowLabel.text(for: .scroll)
            }
            return EditorToolbarButtonLabel(icon: "rectangle.split.1x2", title: L10n.t("布局"), summary: summary)
        case .info:
            if mini {
                let fields = settings.lyricsWindowMiniHeaderFields
                return EditorToolbarButtonLabel(
                    icon: "info.circle", title: L10n.t("顶部信息"),
                    summary: SettingsToggleSummary.text([
                        (title: L10n.t("封面"), isOn: settings.lyricsWindowMiniShowsCover),
                        (title: L10n.t("歌名"), isOn: fields.contains(.title)),
                        (title: L10n.t("歌手"), isOn: fields.contains(.artist)),
                        (title: L10n.t("专辑"), isOn: fields.contains(.album)),
                        (title: L10n.t("时间"), isOn: settings.lyricsWindowMiniShowsTime),
                    ]))
            }
            return EditorToolbarButtonLabel(
                icon: "photo", title: L10n.t("封面"),
                summary: SettingsToggleSummary.text([
                    (title: L10n.t("动态封面"), isOn: settings.motionCoverEnabled),
                ]))
        }
    }

    private func lyricsWindowToolbarButton(_ item: LyricsWindowToolbarItem) -> some View {
        Button {
            lyricsWindowPopover = item
        } label: {
            lyricsWindowToolbarLabel(item)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: Binding(
            get: { lyricsWindowPopover == item },
            set: { shown in
                if shown { lyricsWindowPopover = item } else if lyricsWindowPopover == item { lyricsWindowPopover = nil }
            }), arrowEdge: .bottom) {
            lyricsWindowPopoverContent(item)
        }
    }

    /// 第二行的对齐占位:同一份 label、同一套按钮样式,所以同宽;不挂浮层、不画、不进无障碍树。
    private func lyricsWindowToolbarGhost(_ item: LyricsWindowToolbarItem) -> some View {
        Button {} label: { lyricsWindowToolbarLabel(item) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .hidden()
            .accessibilityHidden(true)
    }

    /// 浮层宽度按内容估、宁宽勿窄(`SettingsPopoverShell.width` 那条:窄了尾部控件 fixedSize
    /// 之后亏空全摊给标题,标题会被压没)。**没离屏量过**,要收紧先量。
    @ViewBuilder
    private func lyricsWindowPopoverContent(_ item: LyricsWindowToolbarItem) -> some View {
        switch item {
        case .background:
            SettingsPopoverShell(title: L10n.t("背景"), width: 400) {
                VStack(spacing: 0) { lyricsWindowAppearanceRows(.background) }
            }
        case .textColor:
            SettingsPopoverShell(title: L10n.t("文字颜色"), width: 400) {
                VStack(spacing: 0) { lyricsWindowAppearanceRows(.textColor) }
            }
        case .font:
            SettingsPopoverShell(title: L10n.t("字体"), width: 440) {
                VStack(spacing: 0) { lyricsWindowAppearanceRows(.font) }
            }
        case .layout:
            SettingsPopoverShell(title: L10n.t("布局"), width: 440) {
                VStack(spacing: 0) { lyricsWindowAppearanceRows(.layout) }
            }
        case .info:
            if lyricsWindowPreviewShowsMini {
                SettingsPopoverShell(title: L10n.t("顶部信息"), width: 360) {
                    VStack(spacing: 0) { lyricsWindowMiniHeaderRows }
                }
            } else {
                SettingsPopoverShell(title: L10n.t("封面"), width: 420) {
                    VStack(spacing: 0) { lyricsWindowCoverRows }
                }
            }
        }
    }

    /// 迷你「顶部信息」那几行(工具栏浮层与抽屉同一份)。只有迷你有这一组 —— 完整尺寸的曲目
    /// 信息在左栏,跟封面、进度、播控排在一起,是另一套排版。
    ///
    /// 一样一颗开关而不是一个多选下拉:系统 `Menu` 在这个项目里有前科 —— 它的实际可点范围
    /// 只有 label 固有尺寸那一点(「⋯」菜单为此整个换成了自绘面板,见 LyricsWindowView
    /// 的 titleSideButtons 注释),摆进 SettingsRow 的尾部槽位直接点不动。全仓的下拉都是
    /// `Picker(.menu)`,而 Picker 做不了多选,所以这里回到最朴素、也最经得起点的形态。
    @ViewBuilder
    private var lyricsWindowMiniHeaderRows: some View {
        // 封面**自己一颗设置**,不并进 miniHeaderFields(同下面「时间」那条理由):
        // 那个 OptionSet 的 `visibleValues` 吐的是字符串,封面不是字符串。
        SettingsRow(icon: "photo", title: L10n.t("封面")) {
            Toggle("", isOn: $settings.lyricsWindowMiniShowsCover)
        }
        CardDivider()
        SettingsRow(icon: "music.note", title: L10n.t("歌名")) {
            Toggle("", isOn: miniHeaderFieldBinding(.title))
        }
        CardDivider()
        SettingsRow(icon: "music.mic", title: L10n.t("歌手")) {
            Toggle("", isOn: miniHeaderFieldBinding(.artist))
        }
        CardDivider()
        SettingsRow(icon: "square.stack", title: L10n.t("专辑")) {
            Toggle("", isOn: miniHeaderFieldBinding(.album))
        }
        CardDivider()
        // 时间自己一颗设置键(不并进 miniHeaderFields):上面三样是这首歌的元数据,时间不是,
        // 排版也不一样(更小更淡、单独一行)。并进那个 OptionSet 还会让老用户升级后默认拿不到 ——
        // 那个键他们早就有值,新加的位一律是 0。
        SettingsRow(icon: "clock", title: L10n.t("时间")) {
            Toggle("", isOn: $settings.lyricsWindowMiniShowsTime)
        }
    }

    /// 完整尺寸「封面」那一行(工具栏浮层与抽屉同一份)。「动态封面」只有完整尺寸有 —— 迷你那枚
    /// 是顶部信息里的小图,不播动态封面。
    @ViewBuilder
    private var lyricsWindowCoverRows: some View {
        SettingsRow(
            icon: "photo.badge.arrow.down",
            title: L10n.t("动态封面"),
            help: L10n.t("仅部分专辑提供；低电量或「减弱动态效果」时自动暂停")
        ) {
            Toggle("", isOn: $settings.motionCoverEnabled)
        }
    }

    /// 按预览停在哪个尺寸,把外观行绑到那一套字段上。
    @ViewBuilder
    private func lyricsWindowAppearanceRows(_ part: LyricsWindowAppearancePart) -> some View {
        if lyricsWindowPreviewShowsMini {
            lyricsWindowAppearanceRowsImpl(
                part: part,
                mode: $settings.lyricsWindowMiniBackgroundMode,
                direction: $settings.lyricsWindowMiniGradientDirection,
                startColor: Binding(
                    get: { settings.lyricsWindowMiniBackgroundColor },
                    set: { settings.lyricsWindowMiniBackgroundColorHex = $0.hexStringWithAlpha }),
                endColor: Binding(
                    get: { settings.lyricsWindowMiniBackgroundColorEnd },
                    set: { settings.lyricsWindowMiniBackgroundColorEndHex = $0.hexStringWithAlpha }),
                glass: $settings.lyricsWindowMiniGlassIntensity,
                textColorMode: $settings.lyricsWindowMiniTextColorMode,
                textColor: Binding(
                    get: { settings.lyricsWindowMiniTextColor },
                    set: { settings.lyricsWindowMiniTextColorHex = $0.hexStringWithAlpha }),
                font: $settings.lyricsWindowMiniFontFamily,
                fontSize: $settings.lyricsWindowMiniFontSize,
                lineOverflow: $settings.lyricsWindowMiniLineOverflow,
                miniLyricsLayout: $settings.lyricsWindowMiniLyricsLayout)
        } else {
            lyricsWindowAppearanceRowsImpl(
                part: part,
                mode: $settings.lyricsWindowBackgroundMode,
                direction: $settings.lyricsWindowGradientDirection,
                startColor: Binding(
                    get: { settings.lyricsWindowBackgroundColor },
                    set: { settings.lyricsWindowBackgroundColorHex = $0.hexStringWithAlpha }),
                endColor: Binding(
                    get: { settings.lyricsWindowBackgroundColorEnd },
                    set: { settings.lyricsWindowBackgroundColorEndHex = $0.hexStringWithAlpha }),
                glass: $settings.lyricsWindowGlassIntensity,
                textColorMode: $settings.lyricsWindowTextColorMode,
                textColor: Binding(
                    get: { settings.lyricsWindowTextColor },
                    set: { settings.lyricsWindowTextColorHex = $0.hexStringWithAlpha }),
                font: $settings.lyricsWindowFontFamily)
        }
    }

    /// 「歌词窗口」那一段外观配置的三块行(背景 / 文字颜色 / 字体),**不带卡片外壳**:工具栏三个
    /// 浮层各取一块,「全部设置」抽屉的「外观」组三块都要,两处调的是同一份。完整尺寸和迷你尺寸各调
    /// 一次,只有绑定的字段不同(按预览停在哪个尺寸分派,见 `lyricsWindowAppearanceRows(_:)`)。
    @ViewBuilder
    private func lyricsWindowAppearanceRowsImpl(
        part: LyricsWindowAppearancePart,
        mode: Binding<LyricsWindowBackgroundMode>,
        direction: Binding<LyricsWindowGradientDirection>,
        startColor: Binding<Color>,
        endColor: Binding<Color>,
        glass: Binding<OverlayGlassIntensity>,
        textColorMode: Binding<LyricsWindowTextColorMode>,
        textColor: Binding<Color>,
        font: Binding<String>,
        /// 只有迷你尺寸传:完整尺寸的字号由视口高度反推,不给滑杆(理由见 AppSettings 那颗设置)。
        fontSize: Binding<Double>? = nil,
        /// 同样只有迷你尺寸传:完整尺寸是一整页正文,恒换行。
        lineOverflow: Binding<OverlayLineOverflow>? = nil,
        /// 同样只有迷你尺寸传:完整尺寸本来就是整页列表。
        miniLyricsLayout: Binding<LyricsWindowMiniLyricsLayout>? = nil
    ) -> some View {
        switch part {
        case .background:
            SettingsRow(
                icon: "photo.artframe",
                title: L10n.t("背景")
            ) {
                Picker("", selection: mode) {
                    Text(L10n.t("跟随封面")).tag(LyricsWindowBackgroundMode.artwork)
                    Text(L10n.t("纯色")).tag(LyricsWindowBackgroundMode.solid)
                    Text(L10n.t("渐变")).tag(LyricsWindowBackgroundMode.gradient)
                    Text(L10n.t("毛玻璃")).tag(LyricsWindowBackgroundMode.glass)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            // 下面三项都是「背景」的**从属项** —— 选了哪一档才出现哪一项。用 SettingsSubRow
            // (缩进 + 无图标)把从属关系画出来:平级摆着的话,看上去像三个互不相干的设置。
            if mode.wrappedValue == .gradient {
                CardDivider()
                SettingsSubRow(title: L10n.t("方向")) {
                    Picker("", selection: direction) {
                        Text(L10n.t("从上到下")).tag(LyricsWindowGradientDirection.vertical)
                        Text(L10n.t("从左到右")).tag(LyricsWindowGradientDirection.horizontal)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            if mode.wrappedValue.usesCustomColor {
                CardDivider()
                SettingsSubRow(
                    // 两个颜色按**当前方向**叫「顶部/底部」或「左侧/右侧」,不叫「起点/终点」——
                    // 后者还要人回头去看方向那一行才知道是哪一端,而这两行本来就紧挨着。
                    title: mode.wrappedValue != .gradient
                        ? L10n.t("颜色")
                        : (direction.wrappedValue == .vertical ? L10n.t("顶部颜色") : L10n.t("左侧颜色"))
                ) {
                    AppColorPicker(selection: startColor)
                }
            }
            if mode.wrappedValue == .gradient {
                CardDivider()
                SettingsSubRow(
                    title: direction.wrappedValue == .vertical ? L10n.t("底部颜色") : L10n.t("右侧颜色")
                ) {
                    AppColorPicker(selection: endColor)
                }
            }
            // 浓淡复用悬浮歌词那套五档 Material(`OverlayGlassIntensity`),不另起一套档位 ——
            // 系统就这五档,两处各定义一份只会漂。
            if mode.wrappedValue == .glass {
                CardDivider()
                SettingsSubRow(
                    title: L10n.t("玻璃浓淡"),
                    help: L10n.t("毛玻璃折射的是窗口背后的桌面，所以这一档下窗口本身是透明的")
                ) {
                    Picker("", selection: glass) {
                        ForEach(OverlayGlassIntensity.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        case .textColor:
            // 文字颜色是**自己一颗设置**,不再是背景的派生物。
            //
            // 在此之前它没有设置:全窗配色读一个"背景够不够暗"的布尔(LyricsWindowBackgroundLuma
            // 算出来的),于是「深底配深字」「毛玻璃上钉死白字」这类搭配根本表达不出来 —— 而用户
            // 能自己填背景之后,这恰恰是最常见的诉求。`.auto` 档就是原来那套,仍是默认。
            SettingsRow(
                icon: "paintpalette",
                title: L10n.t("文字颜色"),
                // 迷你的顶部信息和控制条跟歌词紧挨成一块,文字色一起走(LyricsWindowView.miniPrimaryColor);
                // 完整尺寸只管歌词。说明按尺寸分开写,别合成一句。
                help: fontSize != nil
                    ? L10n.t("作用于歌词、顶部信息和控制条；「自动」会按背景亮度在浅色和深色之间切换")
                    : L10n.t("仅作用于歌词；「自动」会按背景亮度在浅色和深色之间切换")
            ) {
                Picker("", selection: textColorMode) {
                    Text(L10n.t("自动")).tag(LyricsWindowTextColorMode.auto)
                    Text(L10n.t("浅色")).tag(LyricsWindowTextColorMode.light)
                    Text(L10n.t("深色")).tag(LyricsWindowTextColorMode.dark)
                    Text(L10n.t("自定义")).tag(LyricsWindowTextColorMode.custom)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if textColorMode.wrappedValue.usesCustomColor {
                CardDivider()
                // 叫「指定颜色」不叫「颜色」:这张卡里「颜色」已经是背景那一档的从属行了,
                // 同名两行摆在一张卡里,看的人得先数缩进才知道哪个管哪个。
                SettingsSubRow(title: L10n.t("指定颜色")) {
                    AppColorPicker(selection: textColor)
                }
            }
        case .font:
            // 字号不给配:这扇窗的字号是跟着窗口尺寸算出来的(完整走 lyricFontSize、迷你走
            // miniFontSize),再给一根滑杆就是让两套规则打架 —— 拖窗口会把用户调好的数悄悄改掉。
            SettingsRow(
                icon: "textformat",
                title: L10n.t("字体"),
                // 完整尺寸的字号由窗口大小推出、不给滑杆;迷你有下面那根「字号」上限滑杆。
                help: fontSize != nil
                    ? L10n.t("仅作用于歌词；顶部信息和控制条仍用系统字体")
                    : L10n.t("仅作用于歌词；字号随窗口大小自动调整")
            ) {
                FontFamilyPicker(selection: font)
            }
            if let fontSize {
                CardDivider()
                SettingsRow(
                    icon: "textformat.size",
                    title: L10n.t("字号"),
                    help: L10n.t("这是上限：窗口够大时按这个值，拖小了字会跟着变小以免挤出窗外")
                ) {
                    HStack(spacing: 8) {
                        // SteppedSlider 而不是原生带步长的构造器:后者会在轨道下面画一排刻度点。
                        SteppedSlider(value: Binding(
                            get: { fontSize.wrappedValue },
                            // 相等守卫:拖动中每个鼠标事件都会调 set,量化后大量等值赋值照样
                            // 广播 objectWillChange,所有观察 AppSettings 的界面跟着白跑。
                            set: { v in
                                guard v != fontSize.wrappedValue else { return }
                                fontSize.wrappedValue = v
                            }
                        ), in: AppSettings.lyricsWindowMiniFontSizeRange, step: 1)
                            .frame(width: 150)
                        Text(String(format: L10n.t("%@pt"), "\(Int(fontSize.wrappedValue))"))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        case .layout:
            if let miniLyricsLayout {
                SettingsRow(
                    icon: "rectangle.split.1x2",
                    title: L10n.t("歌词布局"),
                    help: L10n.t("简洁：只显示当前句和下一句。\n多行：像完整尺寸那样整页滚动显示歌词。")
                ) {
                    SettingsSegmentedControl(
                        selection: miniLyricsLayout,
                        options: LyricsWindowMiniLyricsLayout.allCases,
                        label: LyricsWindowMiniLyricsLayoutLabel.text(for:)
                    )
                }
                // 长句处理只管「简洁」那两行;「多行」是完整布局那份列表,恒换行。选了多行就不摆这一行,
                // 摆着一颗改了没反应的开关只会让人以为坏了。
                if miniLyricsLayout.wrappedValue == .compact, let lineOverflow {
                    CardDivider()
                    SettingsRow(
                        icon: "arrow.left.and.right.text.vertical",
                        title: L10n.t("长句处理"),
                        help: L10n.t("换行（默认）：一行放不下就折到下一行。\n滚动：每行只占一行高，放不下的横向滚动；这一句有逐字时间轴时跟着唱到哪滚到哪。")
                    ) {
                        SettingsSegmentedControl(
                            selection: lineOverflow,
                            options: OverlayLineOverflow.allCases,
                            label: OverlayLineOverflowLabel.text(for:)
                        )
                    }
                }
            }
        }
    }

    /// 迷你顶部那一行的某一样勾没勾。
    private func miniHeaderFieldBinding(_ field: LyricsWindowMiniHeaderFields) -> Binding<Bool> {
        Binding(
            get: { settings.lyricsWindowMiniHeaderFields.contains(field) },
            set: { on in
                var v = settings.lyricsWindowMiniHeaderFields
                if on { v.insert(field) } else { v.remove(field) }
                settings.lyricsWindowMiniHeaderFields = v
            })
    }


    /// 每一段开头那张"这个形态开不开"的卡。
    ///
    /// 放在这一段的最上面,而不是集中成一张总开关卡:"开启 到 立刻在下面调它的样子"是一条直线,
    /// 集中的话要开某个形态得先退回总览、开完再切回来,来回两次。
    ///
    /// 关着的时候这一段也不会是空白 —— 这张卡本身就是内容,不需要另给"还没开启"的占位提示。
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


    // 「桌面悬浮歌词」那一整套配置卡(配色 / 我的配色主题 / 文字 / 窗口 / 恢复)不在这个文件里:
    //   - 五张卡的内容在 OverlayAllSettingsDrawer —— 默认折叠的「全部设置」抽屉。高频项已经被
    //     编辑台和工具栏浮层接管,剩下的职责只有"全量兜底通路",没有理由常年占着两屏;
    //   - 「窗口」卡里那三个行为项在编辑台工具栏第二行的 `OverlayBehaviorPopover`。
    // 行本体分别在 OverlayStyleSettingsRows.swift 和 OverlayBehaviorSettingsRows.swift,那也是
    // 编辑台几个浮层用的同一份。别在这里重新长出一张同名的卡:这一段有工具栏浮层和抽屉两个
    // 宿主,多一份实现就多两处会漂的地方(理由见那两个文件顶部)。

    // 「灵动岛歌词」那张配置卡(风格 / 宽度 / 显示在哪块屏幕)在 NotchEditorStage.swift ——
    // 前两项在编辑台工具栏的两个浮层和舞台里那条宽度调整条,屏幕那一项在「屏幕」浮层。别在
    // 这里重新长出一张同名的卡:那一段只有编辑台一个宿主,多一份实现就多一处会漂的地方。
    //
    // `NotchLyricsWindowController.shared.applyContentWidthSetting()` / `.applyScreenSetting()`
    // 不能裸调,那违反这个类的 `.shared` 不变量(读一下就 init 出整扇窗;见
    // docs/features/05-notch.md 设计决策第 1 条)。调用点都要带 `if settings.notchOverlayEnabled`
    // 守卫。

    // 「菜单栏歌词」那张平铺卡片(宽度模式/逐字染色/文字颜色/染色颜色/最大宽度五项)在
    // UI/MenuBarEditorStage.swift —— 前两项在编辑台工具栏的两个浮层(宽度模式/配色),最大宽度
    // 在舞台正下方的常驻宽度条,「全部设置」抽屉(MenuBarAllSettingsDrawer)兜底。别在这里重新
    // 长出一张同名的卡:那一段只有编辑台一个宿主,多一份实现就多一处会漂的地方。
}

// MARK: - 灵动岛「歌词行 / 展开态 / 行为」三组内容开关(唯一数据源 + 三个分组视图)

/// 灵动岛几个纯布尔"设一次就不动"的内容开关的唯一一份**数据**:图标 / 标题 /
/// 帮助文案 / Binding 只在这里定义一次。渲染它们的是下面三个**分组视图**
/// (`NotchLyricRowSettingsRows` / `NotchExpandedSettingsRows` / `NotchBehaviorSettingsRows`),
/// 工具栏第二行三个浮层和「全部设置」抽屉的三个组各调**同一份**分组视图 —— 两个宿主的内容在
/// 结构上就是一份,不靠"两处 `items` 数组必须逐字相同"这种靠人守的约定。
///
/// **分组按卡片解剖走**:
///   - 「歌词行」= 歌词行本身的一切:显不显示 到 对齐方式 到 副行(展开时预览下一句)到 卡拉OK效果
///     到 行末封面(封面位置);
///   - 「展开态」= 只有 hover 展开才有的东西:控制区(播放控制 / 歌词校准)+ 快捷操作(头部右侧
///     四颗键)+ 曲目信息头部(封面 / 歌名 / 歌手 / 专辑,四项归在一个「曲目信息」标题行下面);
///   - 「行为」= 什么时候缩、什么时候藏:暂停缩回 + 两项自动隐藏(`AutoHideSettingsRows`)。
///
/// 「展开时预览下一句」(`.expandedNextLine`)归「歌词行」不归「展开态」:它在用户眼里是
/// "第二行歌词"(预览卡可点区域就是按这个划的,见 `NotchEditorStage.cardHotspots`),而且跟
/// 「副行 · 下一句」讲的是同一件事。`AppSettings` 的键名仍是 `notchExpanded*`(持久化格式,
/// 不随 UI 挪动迁移)。
///
/// 「显示音浪」**不在这个枚举里**:它带一个从属的"贴哪只耳朵",宿主是左右耳浮层顶部那行开关
/// (`NotchEarSettingsRows`,`NotchEditorStage.swift`),不要顺手挪进来。
enum NotchBehaviorItem: String, CaseIterable, Identifiable {
    case showLyrics
    /// 歌词行要不要按逐字时间轴填色(灵动岛这一份见 AppSettings.notchLyricsKaraoke)。
    /// 归「歌词行」:它讲的是这一行**怎么画**。
    case karaoke
    case collapseWhenPaused
    case lyricRowArtwork
    case expandedNextLine
    case expandedShowsControls
    case expandedShowsLyricsOffset
    /// 展开态头部右侧那排快捷操作(搜索歌词 / 显示歌词 │ 设置 / 关闭)。一颗开关管四颗键。
    case expandedShowsQuickActions
    case expandedShowsArtwork
    case expandedShowsTrackTitle
    case expandedShowsArtist
    case expandedShowsAlbum

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .showLyrics: return "text.alignleft"
        case .karaoke: return "sparkles"
        case .collapseWhenPaused: return "arrow.down.right.and.arrow.up.left"
        case .lyricRowArtwork: return "photo"
        case .expandedNextLine: return "text.bubble"
        case .expandedShowsControls: return "playpause.fill"
        case .expandedShowsLyricsOffset: return "timer"
        case .expandedShowsQuickActions: return "ellipsis.circle"
        case .expandedShowsArtwork: return "photo"
        case .expandedShowsTrackTitle: return "textformat"
        case .expandedShowsArtist: return "music.mic"
        case .expandedShowsAlbum: return "opticaldisc"
        }
    }

    var title: String {
        switch self {
        case .showLyrics: return L10n.t("显示歌词")
        case .karaoke: return L10n.t("卡拉OK效果")
        case .collapseWhenPaused: return L10n.t("暂停缩回")
        case .lyricRowArtwork: return L10n.t("显示封面")
        // 标题里要把"只在展开时"说出来,否则跟上一行「副行 · 下一句」读起来像同一个开关的两种写法。
        case .expandedNextLine: return L10n.t("展开时预览下一句")
        case .expandedShowsControls: return L10n.t("显示播放控制")
        case .expandedShowsLyricsOffset: return L10n.t("显示歌词校准")
        case .expandedShowsQuickActions: return L10n.t("快捷操作")
        // 曲目信息头部的四项挂在「曲目信息」标题行下面(`NotchExpandedSettingsRows`),标题是
        // 光秃秃的名词 —— 复用耳朵模块那四个词条,不另造"显示封面 / 显示歌名…":那样会跟
        // 「歌词行」浮层里另一枚封面的开关同名「显示封面」,分不清是哪一枚。
        case .expandedShowsArtwork: return NotchEarModule.artwork.displayName
        case .expandedShowsTrackTitle: return NotchEarModule.title.displayName
        case .expandedShowsArtist: return NotchEarModule.artist.displayName
        case .expandedShowsAlbum: return NotchEarModule.album.displayName
        }
    }

    /// 带帮助气泡的项;其余返回 nil,宿主据此决定要不要传 `help:` 参数。
    var help: String? {
        switch self {
        case .expandedNextLine: return L10n.t("展开时在进度条上方显示下一句要唱的歌词。")
        case .karaoke: return L10n.t("逐字歌词，唱到哪个字亮到哪个字；没有逐字数据的歌整行高亮")
        case .expandedShowsQuickActions:
            return L10n.t("展开时在曲目信息右侧显示四颗按钮：搜索歌词、显示歌词、设置、关闭灵动岛歌词。")
        default: return nil
        }
    }

    @MainActor
    var binding: Binding<Bool> {
        let settings = AppSettings.shared
        switch self {
        case .showLyrics:
            return Binding(get: { settings.notchShowLyrics }, set: { settings.notchShowLyrics = $0 })
        case .karaoke:
            return Binding(get: { settings.notchLyricsKaraoke }, set: { settings.notchLyricsKaraoke = $0 })
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
        case .expandedShowsQuickActions:
            return Binding(get: { settings.notchExpandedShowsQuickActions },
                            set: { settings.notchExpandedShowsQuickActions = $0 })
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

/// 一个 `NotchBehaviorItem` 的标准渲染:图标 + 标题(+ ⓘ)+ 开关。三个分组视图都用它,不各抄一份
/// `SettingsRow` + `Toggle` 的样板。
///
/// `@ObservedObject` 是**必需**的,不是照抄的样板:`item.binding` 是手搓的 `Binding(get:set:)`,
/// 写入不经过任何能让 SwiftUI 失效的通道,而这个视图的存储属性只有一个 POD 的 `item` —— 宿主刷新
/// 时 SwiftUI 判等相等,就跳过它的 body 不再求值,开关于是画着陈旧值:点一次真值确实翻了、圆钮却
/// 不动;再点真值照样翻、圆钮还是不动,要切页把这个视图整个重建才会刷回真值。没有子项联动的那几项
/// (卡拉OK效果 / 显示封面)因此点下去一点反馈都没有,用户读到的就是"点不动"。
/// 同 `AutoHideSettingsRows`。
@MainActor
private struct NotchBehaviorToggleRow: View {
    let item: NotchBehaviorItem
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(icon: item.icon, title: item.title, help: item.help) {
            Toggle("", isOn: item.binding)
        }
    }
}

/// 同上,但画成**从属子行**(`SettingsSubRow`:左边一条淡竖线、标题缩进到主行标题那一列)——
/// 「曲目信息」下面的四项和「副行」下面的「展开时预览下一句」用它。
/// `@ObservedObject` 同样必需,理由见 `NotchBehaviorToggleRow`。
@MainActor
private struct NotchBehaviorToggleSubRow: View {
    let item: NotchBehaviorItem
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsSubRow(title: item.title, help: item.help) {
            Toggle("", isOn: item.binding)
        }
    }
}

/// 「封面位置」那一行(左/右两选一),从属于 `.lyricRowArtwork`,只在它开着时出现。
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

/// 「对齐方式」那一行 —— 装得下的短句在歌词行里靠哪边。
///
/// 跟菜单栏那个同名设置**共用**枚举(`LyricsRestingAlignment`)和分段控件
/// (`UI/LyricsAlignmentSegmentedControl.swift`)—— 两边的选项、语义、标签逐字相同,
/// 而那个控件是手搓的(不用系统 segmented picker,理由见它的头注),不该有第三份。
///
/// 用 `SettingsRow(icon:)` 而不是 `SettingsSubRow`:它是歌词行的一个**顶层**设置项,
/// 不从属于上面任何一个开关(跟「封面位置」不一样,那个确实是「显示封面」的子项)。
/// `MenuBarWidthModeRow` / `MenuBarColorRows` 同此。
///
/// 图标跟菜单栏那一行用同一个 `text.alignleft` —— 同一件事在两个展示面上该长一样。
@MainActor
private struct NotchLyricsAlignmentRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.alignleft",
            title: L10n.t("对齐方式"),
            // 「自动」那一档按什么走也写在这条 help 里(菜单栏那一行用的是另一条词条)。
            help: L10n.t("只影响装得下的短句：它在歌词行里靠哪边。「自动」按对唱声部走：谁唱靠谁那边、合唱居中，没有对唱信息就靠左。放不下的句子会横向滚动，没有多余空间，对齐不起作用")
        ) {
            LyricsAlignmentSegmentedControl(selection: $settings.notchLyricsAlignment,
                                            options: LyricsRestingAlignment.notchOptions)
        }
    }
}

/// 「副行」那一行:主歌词下方那 11pt 显示什么,四选一(不显示 / 下一句 / 译文 / 罗马音),
/// 默认「下一句」。行高恒 44、不影响卡片任何尺寸,所以跟「对齐方式」一样是歌词行自己的**顶层**
/// 设置项(`SettingsRow`,不是从属的 `SettingsSubRow`),顺序紧跟「对齐方式」。
///
/// 控件用下拉(`.pickerStyle(.menu)`)而不是分段控件:四个英文标签(Nothing / Next Line /
/// Translation / Romanization)在 420pt 的浮层里放不下(同悬浮歌词「粗细」那一行选下拉的理由);
/// 也不用「风格」浮层那种单选列表 —— 这个浮层已经有五行,再加一头四行会撑到要滚。
/// `.fixedSize()` 不能省,理由见 `OverlayStyleSettingsRows` 同款那条提醒。
/// 这是 `Picker`,不是 `Menu` + `Toggle` 条目。
@MainActor
private struct LyricSecondaryLineRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.append",
            title: L10n.t("副行"),
            help: L10n.t("主歌词下方多显示一行，行高不变。译文和罗马音显示的是当前句，下一句显示接下来那句；选「下一句」时展开区不再重复显示下一句预览")
        ) {
            Picker("", selection: $settings.notchSecondaryLine) {
                ForEach(LyricSecondaryLine.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// 「歌词行」组 —— 工具栏「歌词行」浮层(`NotchLyricRowPopover`)与「全部设置」抽屉
/// `lyricRowGroup` 调的是这同一份。
///
/// 顺序:显示歌词 到(对齐方式 到 副行 到 展开时预览下一句)到 卡拉OK效果 到 显示封面(到 封面位置)。
/// 先把歌词这一格自己的事说完(显不显示、怎么对齐、下面加哪一行、怎么填色),再说行末那枚封面。
///
/// **「显示歌词」关着时其余整组隐藏**(不是禁用):没有歌词行,"靠哪边 / 副行放什么 / 怎么填色 /
/// 封面贴哪一行"这些事都没有意义。 唯一的例外是「展开时预览下一句」:它画在展开区、不依赖
/// 歌词行(「显示歌词」关掉后展开时下一句预览照常显示,见 05 章「显示歌词」节),所以歌词行
/// 关着时它**仍然显示**,只是从「副行」的子行升回顶层一行。
///
/// 「展开时预览下一句」从属于「副行」(`SettingsSubRow`):副行选了「下一句」时稳态就常显下一句,
/// 展开再画一行是重复,这颗开关翻了也没有效果 —— 没有意义的开关不显示(判据只有 Core 一份
/// `LyricSecondaryLine.hidesExpandedNextLinePreview`,跟真窗口 / 编辑台画不画那行同源)。工具栏
/// 「歌词行」按钮的摘要按同一判据决定列不列它(`NotchEditorStage.lyricRowSummary`)。
///
/// `@ObservedObject` 不是样板:浮层宿主 `NotchLyricRowPopover` 自己不观察 `AppSettings`,
/// 这里的条件显隐要靠它自己刷新。
@MainActor
struct NotchLyricRowSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            NotchBehaviorToggleRow(item: .showLyrics)
            if settings.notchShowLyrics {
                CardDivider()
                NotchLyricsAlignmentRow()
                CardDivider()
                LyricSecondaryLineRow()
                if !settings.notchSecondaryLine.hidesExpandedNextLinePreview {
                    CardDivider()
                    NotchBehaviorToggleSubRow(item: .expandedNextLine)
                }
                CardDivider()
                NotchBehaviorToggleRow(item: .karaoke)
                CardDivider()
                NotchBehaviorToggleRow(item: .lyricRowArtwork)
                if settings.notchLyricRowShowsArtwork {
                    CardDivider()
                    NotchLyricRowArtworkPositionRow()
                }
            } else if !settings.notchSecondaryLine.hidesExpandedNextLinePreview {
                CardDivider()
                NotchBehaviorToggleRow(item: .expandedNextLine)
            }
        }
    }
}

/// 「字体」组 —— 工具栏第二行「字体」浮层(`NotchFontPopover`)与「全部设置」抽屉的「字体」组
/// 调的是这同一份。三行照搬悬浮歌词「文字」浮层的前三行(`OverlayTextSettingsRows`):同一个
/// `FontFamilyPicker`、同一个六档粗细下拉、同一根 `SteppedSlider`,只是绑到灵动岛自己的三个键。
/// 控件形态的理由(下拉不用分段、`.fixedSize()` 不能省、`SteppedSlider` 不画刻度点、相等守卫)
/// 都写在那边,这里不复述。
///
/// 只管歌词文字、字号只调主行、副行与展开预览固定 11pt —— 这些跟悬浮歌词那三行不同的地方由
/// 「粗细」「字号」两行的 ⓘ 说清,不然用户会拖着滑杆等副行变大。范围真源在 Core
/// `NotchLyricRowMetrics.mainFontSizeRange`,help 文案里的数字也从那里取,不手抄。
@MainActor
struct NotchFontSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    private var sizeRange: ClosedRange<Double> {
        Double(NotchLyricRowMetrics.mainFontSizeRange.lowerBound)...Double(NotchLyricRowMetrics.mainFontSizeRange.upperBound)
    }

    private var sizeHelp: String {
        String(format: L10n.t("只调主行，%@～%@pt，歌词行高度不变；副行和展开时的下一句预览固定 %@pt，只跟随字体与粗细"),
               "\(Int(NotchLyricRowMetrics.mainFontSizeRange.lowerBound))",
               "\(Int(NotchLyricRowMetrics.mainFontSizeRange.upperBound))",
               "\(Int(NotchLyricRowMetrics.secondaryFontSize))")
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "character", title: L10n.t("字体")) {
                FontFamilyPicker(selection: $settings.notchFontFamilyName)
            }
            CardDivider()
            SettingsRow(
                icon: "bold",
                title: L10n.t("粗细"),
                help: L10n.t("主行的笔画粗细；副行和展开时的下一句预览比它细一档")
            ) {
                Picker("", selection: $settings.notchFontWeight) {
                    ForEach(OverlayFontWeight.allCases, id: \.self) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            CardDivider()
            SettingsRow(icon: "textformat.size", title: L10n.t("字号"), help: sizeHelp) {
                HStack(spacing: 8) {
                    SteppedSlider(value: Binding(
                        get: { settings.notchFontSize },
                        set: { newValue in
                            // 相等守卫,理由同悬浮歌词「字号」那根:拖动中大量等值赋值会白白广播 + 重算三个派生字体。
                            guard newValue != settings.notchFontSize else { return }
                            settings.notchFontSize = newValue
                        }
                    ), in: sizeRange, step: 1)
                        .frame(width: 150)
                    Text(String(format: L10n.t("%@pt"), "\(Int(settings.notchFontSize))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}

/// 「展开态」组 —— 工具栏「展开态」浮层(`NotchExpandedPopover`)与抽屉 `expandedGroup` 同一份。
///
/// 两截:先是控制区的两颗(显示播放控制 / 显示歌词校准)加「快捷操作」(头部右侧那排四颗键的
/// 总开关),分割线之后一行「曲目信息」标题行(纯说明,没有控件)带四个从属子行
/// (封面 / 歌名 / 歌手 / 专辑)。分成两截是因为它们本来就是不同的东西 —— 平铺成一列开关的话,
/// 这里的「显示封面」会跟「歌词行」浮层那枚同名的项混在一起。
///
/// 「曲目信息」**没有总开关**:头部画不画 = 四项里任一开着(四项全关整块不占地方,见 05 章
/// 「展开区」节),再加一个总开关等于第五个状态来源,"总开关开着、四项全关、什么都没显示"这种
/// 组合说不清楚。标题行只负责把四项圈成一组。
@MainActor
struct NotchExpandedSettingsRows: View {
    var body: some View {
        VStack(spacing: 0) {
            NotchBehaviorToggleRow(item: .expandedShowsControls)
            CardDivider()
            NotchBehaviorToggleRow(item: .expandedShowsLyricsOffset)
            CardDivider()
            NotchBehaviorToggleRow(item: .expandedShowsQuickActions)
            CardDivider()
            SettingsRow(
                icon: "person.text.rectangle",
                title: L10n.t("曲目信息"),
                help: L10n.t("展开时在歌词行上方多一块曲目信息，四项各自独立；全关则这一块不占位置。")
            )
            CardDivider()
            NotchBehaviorToggleSubRow(item: .expandedShowsArtwork)
            CardDivider()
            NotchBehaviorToggleSubRow(item: .expandedShowsTrackTitle)
            CardDivider()
            NotchBehaviorToggleSubRow(item: .expandedShowsArtist)
            CardDivider()
            NotchBehaviorToggleSubRow(item: .expandedShowsAlbum)
        }
    }
}

/// 「行为」组 —— 工具栏「行为」浮层(`NotchBehaviorPopover`)与抽屉 `behaviorGroup` 同一份:
/// 「暂停缩回」+ 两行自动隐藏(`AutoHideSettingsRows`,跟悬浮歌词共用同一份视图、靠 `surface`
/// 分流到 `notchHide*`)。
///
/// 工具栏「行为」按钮的摘要(`NotchEditorStage.behaviorSummary`)要把这三项都算进去 ——
/// 少算自动隐藏那两项不会编译报错,只会让按钮在它们开着时照旧显示「全部关闭」。
@MainActor
struct NotchBehaviorSettingsRows: View {
    var body: some View {
        VStack(spacing: 0) {
            NotchBehaviorToggleRow(item: .collapseWhenPaused)
            // "本组之前"那条分隔线由宿主插,`AutoHideSettingsRows` 只在自己两行之间插一条(见那个文件头)。
            CardDivider()
            AutoHideSettingsRows(surface: .notch)
        }
    }
}

/// 工具栏第二行「歌词行」入口的浮层。内容就是 `NotchLyricRowSettingsRows`,没有第二份。
///
/// `width` 470 是**离屏量的**(`NSHostingView.fittingSize`),不是估的。瓶颈是「对齐方式」
/// 那一行尾部的 4 段分段控件:英文 278.3pt("Left-Aligned"/"Right-Aligned"/"Automatic" 都撑破
/// 每段 56pt 的下限,只按中文估会差 40pt 以上),加 `SettingsRow` 固定开销 96pt(2×14 内边距 +
/// 20 图标列 + 3×12 iconTextSpacing + 12 `Spacer(minLength:)`)+ 标题("Alignment" 61.1)+ ⓘ 19
/// = 英文 **454.4**,470 留 15.6pt 余量;中文四段 234 + 96 + 51.6 + 19 = 400.6,同样在内。
/// 「展开时预览下一句」子行英文约 345pt,不是瓶颈。悬浮歌词那个装同一套四段控件的「排版」浮层
/// 是 460,这里多 10 是因为这一行还带一个 ⓘ。
/// 不能指望截断兜底:`SettingsRow` 的标题没有 `lineLimit`,超宽的表现是**折行**。
struct NotchLyricRowPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("歌词行"), width: 470) {
            NotchLyricRowSettingsRows()
        }
    }
}

/// 工具栏第二行「字体」入口的浮层。内容就是 `NotchFontSettingsRows`。
///
/// 宽度用 `SettingsPopoverShell` 的默认 380,跟菜单栏「字体」浮层同一个理由:那是悬浮歌词「文字」浮层(同样装着
/// 字号滑杆 150 + 读数 46 那一行)量出来的值。这里「字号」行还带一枚 ⓘ(19pt),跟菜单栏那根带 ⓘ 的「字号」行
/// 几何完全相同,380 在那边真机验过。
struct NotchFontPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("字体")) {
            NotchFontSettingsRows()
        }
    }
}

/// 工具栏第二行「展开态」入口的浮层。内容就是 `NotchExpandedSettingsRows`。
///
/// `width` 340 是**按 13pt 系统字量出来的文字宽算的**,不是估:最宽一行是英文
/// "Show Playback Controls" 145.9pt + `SettingsRow` 固定开销 150pt(2×14 内边距 + 20 图标列 +
/// 3×12 间距 + 12 `Spacer(minLength:)` + 54 开关)= **296pt**,中文「显示播放控制」77.4 + 150 = 227。
/// 340 给英文留 44pt,比同族(24~+34)略宽一点,是给「曲目信息」那行的 ⓘ 和四个子行的竖线留的。
struct NotchExpandedPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("展开态"), width: 340) {
            NotchExpandedSettingsRows()
        }
    }
}

/// 工具栏第二行「行为」入口的浮层。内容就是 `NotchBehaviorSettingsRows`。
///
/// `width` 420 是**离屏量出来的**,不是拍脑袋。`SettingsRow` 固定开销 **150pt**:
/// 2×14(左右内边距)+ 20(图标列)+ 3×12(图标 / 文字 / `Spacer` / 尾部控件四个子节点 = 三段
/// `iconTextSpacing`)+ 12(`Spacer(minLength:)`)+ 54(开关固有宽,`NSSwitch().intrinsicContentSize`,
/// 四档 controlSize 都是 54×24)。 手算最常漏的是"图标 到 文字"那一段 12pt。再加最宽那一行 ——
/// 英文 "Hide During Screenshots/Recording" 216pt + ⓘ 19pt = 235pt,合计 385pt(中文只要 271pt);
/// 1pt 步进的换行探测给出英文硬下限 386,按同族浮层的余量取 420。 不能指望"截断"兜底:标题没有
/// `lineLimit`,超宽是**折行**,而 ⓘ 跟标题同处一个 HStack 会垂直居中、尾部开关却是 `.top` 对齐,
/// 三者当场错位。跟悬浮歌词的「行为」浮层同宽,两个形态的「行为」看起来是一件东西。
struct NotchBehaviorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("行为"), width: 420) {
            NotchBehaviorSettingsRows()
        }
    }
}


// MARK: - 歌词窗口「全部设置」抽屉

/// 「歌词窗口」外观行分成的三块(见 `SettingsView.lyricsWindowAppearanceRowsImpl`)。
enum LyricsWindowAppearancePart {
    case background
    case textColor
    case font
    /// 迷你专有:歌词布局(简洁 / 多行)+ 长句处理。完整尺寸没有这一块。
    case layout
}

/// 「歌词布局」两档的显示名(枚举本体在 Core、不带界面文案)。
enum LyricsWindowMiniLyricsLayoutLabel {
    static func text(for value: LyricsWindowMiniLyricsLayout) -> String {
        switch value {
        case .compact: return L10n.t("简洁")
        case .list: return L10n.t("多行")
        }
    }
}

/// 「歌词窗口」工具栏「重置 ▾」的动作。按尺寸各恢复各的,默认值跟 `AppSettings` 读盘时的兜底值一致。
/// 迷你那颗「悬停显示控制条」不在这里:它的开关在迷你窗右上角,不是设置页的样式项。
enum LyricsWindowStyleDefaults {
    @MainActor
    static func restoreDefaults(mini: Bool) {
        let s = AppSettings.shared
        if mini {
            s.lyricsWindowMiniBackgroundMode = .artwork
            s.lyricsWindowMiniBackgroundColorHex = AppSettings.defaultLyricsWindowBackgroundColorHex
            s.lyricsWindowMiniBackgroundColorEndHex = AppSettings.defaultLyricsWindowBackgroundColorEndHex
            s.lyricsWindowMiniGradientDirection = .vertical
            s.lyricsWindowMiniGlassIntensity = .default
            s.lyricsWindowMiniTextColorMode = .auto
            s.lyricsWindowMiniTextColorHex = AppSettings.defaultLyricsWindowTextColorHex
            s.lyricsWindowMiniFontFamily = ""
            s.lyricsWindowMiniFontSize = AppSettings.defaultLyricsWindowMiniFontSize
            s.lyricsWindowMiniLineOverflow = .wrap
            s.lyricsWindowMiniLyricsLayout = .compact
            s.lyricsWindowMiniHeaderFields = .default
            s.lyricsWindowMiniShowsCover = true
            s.lyricsWindowMiniShowsTime = true
        } else {
            s.lyricsWindowBackgroundMode = .artwork
            s.lyricsWindowBackgroundColorHex = AppSettings.defaultLyricsWindowBackgroundColorHex
            s.lyricsWindowBackgroundColorEndHex = AppSettings.defaultLyricsWindowBackgroundColorEndHex
            s.lyricsWindowGradientDirection = .vertical
            s.lyricsWindowGlassIntensity = .default
            s.lyricsWindowTextColorMode = .auto
            s.lyricsWindowTextColorHex = AppSettings.defaultLyricsWindowTextColorHex
            s.lyricsWindowFontFamily = ""
            s.motionCoverEnabled = AppSettings.defaultMotionCoverEnabled
        }
    }
}

/// 「歌词窗口」工具栏的胶囊。`info` 按尺寸是「顶部信息」(迷你)或「封面」(完整);`layout` 只有迷你有。
enum LyricsWindowToolbarItem: Equatable {
    case background
    case textColor
    case font
    case layout
    case info
}

/// 「歌词显示 → 歌词窗口」那一段的「全部设置」抽屉。外壳照另外三个抽屉(`OverlayAllSettingsDrawer` /
/// `NotchAllSettingsDrawer` / `MenuBarAllSettingsDrawer`):默认折叠、整行可点、展开动画写在改状态
/// 那一处。内容由调用方给 —— 行本体是 SettingsView 的私有方法,跟预览上面那排工具栏的浮层调的是同一份。
///
/// 设置搜索的"该展开了"信号走**行高亮**,不走 `settingsSearchPendingDrawer`:那个信号的类型是
/// `LyricsSurface`,而歌词窗口不是一个 `LyricsSurface`(没有常驻开关,进不了那个枚举)。这个抽屉
/// 只在「歌词窗口」那一段渲染,搜索命中落到这一段、有行被点名高亮时就展开(被点名的行只在
/// 抽屉里有常驻位置,工具栏浮层要点开才看得到)。
struct LyricsWindowAllSettingsDrawer<Content: View>: View {
    private let content: () -> Content
    /// 同另外三个抽屉:用 @State 不用 @AppStorage,每次打开设置窗口都是折叠的。
    @State private var isExpanded = false
    @Environment(\.settingsSearchHighlightedTitles) private var highlightedTitles

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()
                content()
            }
        }
        .onAppear { expandForSearchIfNeeded() }
        .onChange(of: highlightedTitles) { _, _ in expandForSearchIfNeeded() }
    }

    private func expandForSearchIfNeeded() {
        guard !highlightedTitles.isEmpty, !isExpanded else { return }
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
                // 撑满宽度:整行可点靠下面的 contentShape,它认的是 HStack 的实际尺寸。
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

// MARK: - 灵动岛「全部设置」抽屉

/// 灵动岛的「全部设置」抽屉。定位完全对齐 `OverlayAllSettingsDrawer`:不是"新配置项的
/// 收纳盒",是**这个形态全部可配项的完整兜底通路**(键盘 / VoiceOver / "我就想找个开关,不想点开
/// 浮层"的场合)。工具栏那几个浮层入口和宽度调整条这些**原有**配置项,也必须能在"全部设置"里找到。
///
/// **各组的顺序 = 工具栏两行入口的顺序**(风格 到 屏幕 到 左耳 到 右耳 到 宽度 / 展开宽度 到
/// 歌词行 到 字体 到 展开态 到 行为 到 恢复默认),标题也跟工具栏按钮一字不差 —— 抽屉是浮层的镜像,
/// 同一组东西在两个入口叫两个名字、排两种顺序就是"这一个那一个"。
///
/// 顶部工具栏和编辑台里那条宽度调整条**本体不受影响** —— 那条横向空间是"刚好塞满、不能再挤"
/// 的上限(见 NotchEditorStage.toolbar 头上那条提醒)。这里是**多开一条兜底入口**,不是挪走原来
/// 那条:每一组都复用浮层背后**同一份**组件,不是另起一份平行实现:
///   - 风格 到 `NotchStyleSettingsRows()`
///   - 屏幕 到 `NotchScreenSettingsRows(onScreenChange:)`(这里没有编辑台预览要刷新,传空闭包——真窗口
///     的更新在组件内部已经带着 `notchOverlayEnabled` 守卫做完了)
///   - 左耳 / 右耳 到 `NotchEarSettingsRows(side:)`(顶部那行「显示音浪」开关也在里面,跟浮层一模一样)
///   - 宽度 / 展开宽度 到 本文件的 `widthRow` / `expandedWidthRow`,只调 `NotchEditorStage` 的静态入口
///   - 歌词行 / 展开态 / 行为 到 `NotchLyricRowSettingsRows` / `NotchExpandedSettingsRows` /
///     `NotchBehaviorSettingsRows`(跟三个浮层是同一份视图,不是"同样的 items 数组")
///   - 字体 到 `NotchFontSettingsRows`(跟工具栏第二行「字体」浮层同一份;字体族 / 粗细 / 字号三行)
private struct NotchAllSettingsDrawer: View {
    @ObservedObject private var settings = AppSettings.shared

    /// 展开状态用 @State 而不是 @AppStorage,理由同 OverlayAllSettingsDrawer:设计要求
    /// "默认折叠",@AppStorage 会把上次展开的样子带到下次打开设置窗口。
    @State private var isExpanded = false
    /// 设置搜索命中了这个抽屉里的行时的"该展开了"信号(理由与写法同 `OverlayAllSettingsDrawer`)。
    @Environment(\.settingsSearchPendingDrawer) private var pendingSearchDrawer

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()
                group(L10n.t("风格")) { NotchStyleSettingsRows() }
                CardDivider()
                group(L10n.t("屏幕")) { NotchScreenSettingsRows(onScreenChange: {}) }
                CardDivider()
                group(L10n.t("左耳")) { NotchEarSettingsRows(side: .left) }
                CardDivider()
                group(L10n.t("右耳")) { NotchEarSettingsRows(side: .right) }
                CardDivider()
                widthRow
                CardDivider()
                expandedWidthRow
                CardDivider()
                group(L10n.t("歌词行")) { NotchLyricRowSettingsRows() }
                CardDivider()
                group(L10n.t("字体")) { NotchFontSettingsRows() }
                CardDivider()
                group(L10n.t("展开态")) { NotchExpandedSettingsRows() }
                CardDivider()
                group(L10n.t("行为")) { NotchBehaviorSettingsRows() }
                CardDivider()
                resetRow
            }
        }
        .onAppear { expandForSearchIfNeeded() }
        .onChange(of: pendingSearchDrawer) { _, _ in expandForSearchIfNeeded() }
        // 理由同 OverlayAllSettingsDrawer:展开/收起的动画挂在改状态那一处(disclosureHeader
        // 里的 withAnimation),不挂在卡片上——挂在卡片上会把同一个事务里任何不相干的布局
        // 变化(比如「显示封面」开着时下面多长出的「封面位置」行)一起带动起来。
    }

    private func expandForSearchIfNeeded() {
        guard pendingSearchDrawer == .notch else { return }
        if !isExpanded {
            withAnimation(.settingsCardReveal) { isExpanded = true }
        }
        SettingsSearchRouter.shared.consumeDrawer(.notch)
    }

    /// 一组:标题行 + 分隔线 + 内容。标题文案跟工具栏对应那颗按钮用同一个词条。
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Group {
            SettingsCardHeader(title: title)
            CardDivider()
            content()
        }
    }

    /// 「恢复默认风格与开关」——抽屉里的兜底入口。
    ///
    /// 动作本体跟工具栏那颗「重置 ▾」是**同一个函数**(`NotchStyleDefaults.restoreDefaults()`),
    /// 两处不能各写一份赋值 —— 理由与悬浮歌词那份逐字相同,见 `OverlayAllSettingsDrawer.resetRow`。
    ///
    /// 这一行不能省:**抽屉的定位是键盘 / VoiceOver 的全量兜底通路**,而工具栏那颗是 SwiftUI
    /// `Menu`,抽屉里这一行是普通 `SettingsRow` + Button。三个形态都要有。
    /// 标题/副标题跟工具栏那颗**一字不差** —— 同一个动作在两个入口自报两种范围是最坏的情况。
    private var resetRow: some View {
        SettingsRow(
            icon: "arrow.uturn.backward",
            title: L10n.t("恢复默认"),
            subtitle: L10n.t("不含宽度和总开关")
        ) {
            Button(L10n.t("恢复")) { NotchStyleDefaults.restoreDefaults() }
        }
    }

    /// 宽度滑杆。编辑台里那条调整条改的是同一个值,这里是它的兜底通路。
    ///
    /// 三条 ls-Rocky 核过的坑,都不是随手能猜对的:
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
                // SteppedSlider 而不是原生带步长的构造器:后者会在轨道下面画一排刻度点。
                // 这一根的量化栅格必须锚在区间下界(SteppedSlider 就是这么做的),因为这里的下界是
                // 这台机器的"耳朵下限"、是个任意数,锚到 0 会让所有落值整体偏移。
                // 写回走 `NotchEditorStage.commitWidths`(三个入口唯一的落盘路径):相等守卫、
                // 「展开 ≥ 稳态」归一(稳态拖过展开时把展开顶上去)、以及上面③那条 `notchOverlayEnabled`
                // 守卫都在里面,这里不再各写一份。
                SteppedSlider(value: Binding(
                    get: { NotchEditorStage.effectiveWidth(baseWidth: settings.notchContentWidth) },
                    set: { NotchEditorStage.commitWidths(steady: $0) }
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

    /// 展开宽度滑杆—— 编辑台那根双滑块调整条右边那只滑块的兜底通路。hover 展开后
    /// 卡片撑到的宽度,不许比上面那根「宽度」(稳态)窄,所以区间下界就是稳态**真实**宽
    /// (`usableExpandedWidthRangeOnCurrentScreen`),读数是 `effectiveExpandedWidth` 算出来的真实
    /// 展开宽(= max(稳态真实宽, 展开设定)),跟编辑台读数「稳态–展开」的右半边是同一个数。
    /// 其余三条(静态入口 / 真实宽读数 / 写回守卫)跟 `widthRow` 逐字同一套。
    private var expandedWidthRow: some View {
        SettingsRow(icon: "arrow.left.and.right.square", title: L10n.t("展开宽度")) {
            HStack(spacing: 8) {
                SteppedSlider(value: Binding(
                    get: {
                        NotchEditorStage.effectiveExpandedWidth(
                            steadyBase: settings.notchContentWidth,
                            expandedBase: settings.notchExpandedContentWidth)
                    },
                    set: { NotchEditorStage.commitWidths(expanded: $0) }
                ), in: NotchEditorStage.usableExpandedWidthRangeOnCurrentScreen, step: 10)
                .frame(width: 150)
                Text(String(format: L10n.t("%@pt"),
                            "\(Int(NotchEditorStage.effectiveExpandedWidth(steadyBase: settings.notchContentWidth, expandedBase: settings.notchExpandedContentWidth)))"))
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

// 「显示音浪」在设置页里的唯一入口是左右耳浮层 / 抽屉左右耳组顶部那一行开关
// (`NotchEarSettingsRows`,`NotchEditorStage.swift`)。别在这里另起一张合并了开关 +
// 「贴哪只耳朵」分段选择器的卡 —— 那是同一对状态(`notchShowsEqualizer` /
// `notchEqualizerEar`)的第二种控件、第二个位置。落点的来龙去脉见 05 章「编辑台改造」。

// 「播放器」分类:播放器选择/权限/常驻服务/App 联动这几块全部围绕"选哪个播放器、能不能
// 正常读到它的播放状态"转,是同一件事的四个侧面;语言/开机启动/配置备份这些不相干的杂项
// 留在「通用」。
/// 「播放器」页的**窄订阅代理**(机制同 OverlayPlayback / PanelPlayback,见 MenuBarPanel.swift
/// 那份的头注)。整对象订阅 `AppSettings.shared`(几十个 @Published)、`FeatureSettingsStore.shared`、
/// `MediaControlHealth.shared` 三个单例的话,别的分页拖个滑杆、播放链路刷一次健康状态,这一页
/// 整个 body 都要重算一遍 —— 而实读的只有下面九个字段。
///
/// 只转发实读字段、值类型一律 removeDuplicates;**写**不经过这里 —— 视图直接写
/// `AppSettings.shared` / 调 `FeatureSettingsStore.shared` 的方法,源一变自然经订阅回流。
/// sink 只用参数值,不回读源属性(@Published willSet 时机,回读是旧值)。
/// body 里不要嵌同步的跨进程调用(见 `refreshBrowserLiveStatus` 头注):重算一次就是几十到
/// 几百毫秒的主线程阻塞。
@MainActor
private final class PlayerTabStores: ObservableObject {
    // ---- AppSettings(只挑这一页实读的四项) ----
    @Published private(set) var browserJSVerifiedAt: [String: Date] = [:]
    @Published private(set) var browserPlatformPairs: [String: Set<String>] = [:]
    @Published private(set) var manualBrowserFamilies: [String: String] = [:]
    @Published private(set) var launchPlayersOnLyrimuseOpen: Set<PlaybackPlayer> = []
    @Published private(set) var quitWithPlayers: Set<PlaybackPlayer> = []
    // ---- FeatureSettingsStore(三项) ----
    @Published private(set) var players: Set<PlaybackPlayer> = [.auto]
    @Published private(set) var trustedPlayers: [String: String] = [:]
    @Published private(set) var launchLyrimuseOnPlayers: Set<PlaybackPlayer> = []
    // ---- MediaControlHealth ----
    @Published private(set) var mediaControlState: MediaControlHealth.State = .unknown
    private var subs: [AnyCancellable] = []

    init() {
        let s = AppSettings.shared
        let f = FeatureSettingsStore.shared
        let h = MediaControlHealth.shared
        browserJSVerifiedAt = s.browserJSVerifiedAt
        browserPlatformPairs = s.browserPlatformPairs
        manualBrowserFamilies = s.manualBrowserFamilies
        launchPlayersOnLyrimuseOpen = s.launchPlayersOnLyrimuseOpen
        quitWithPlayers = s.quitWithPlayers
        players = f.players
        trustedPlayers = f.trustedPlayers
        launchLyrimuseOnPlayers = f.launchLyrimuseOnPlayers
        mediaControlState = h.state
        subs = [
            s.$browserJSVerifiedAt.removeDuplicates().sink { [weak self] in self?.browserJSVerifiedAt = $0 },
            s.$browserPlatformPairs.removeDuplicates().sink { [weak self] in self?.browserPlatformPairs = $0 },
            s.$manualBrowserFamilies.removeDuplicates().sink { [weak self] in self?.manualBrowserFamilies = $0 },
            s.$launchPlayersOnLyrimuseOpen.removeDuplicates().sink { [weak self] in self?.launchPlayersOnLyrimuseOpen = $0 },
            s.$quitWithPlayers.removeDuplicates().sink { [weak self] in self?.quitWithPlayers = $0 },
            f.$players.removeDuplicates().sink { [weak self] in self?.players = $0 },
            f.$trustedPlayers.removeDuplicates().sink { [weak self] in self?.trustedPlayers = $0 },
            f.$launchLyrimuseOnPlayers.removeDuplicates().sink { [weak self] in self?.launchLyrimuseOnPlayers = $0 },
            h.$state.removeDuplicates().sink { [weak self] in self?.mediaControlState = $0 },
        ]
    }

}

private struct PlayerSettingsTab: View {
    @StateObject private var stores = PlayerTabStores()
    /// SettingsView 根上注入的那一份,collector 服务状态从它这里拿(见 collector 卡片的 onReceive)。
    @EnvironmentObject private var playerHealth: PlayerHealthMonitor
    // 「自动化」权限的状态/请求全在这个共享模型里,引导页那一步用的是同一个实例 ——
    // 需要这份权限的播放器不止一个,每家一套状态机分散在两个界面里必然漂。
    // 系统层面的权限变化(用户自己去系统设置里手动改)不会推通知回来,只能在这个页面
    // 被看到的时候被动刷新一次(askIfNeeded: false,不弹窗,纯读状态)。
    @ObservedObject private var automation = PlayerAutomationPermissions.shared
    // 「完全磁盘访问」同理,引导页那一步用的是同一个实例。
    @ObservedObject private var fullDiskAccess = FullDiskAccessPermission.shared
    // collector 常驻服务是否真的在跑——跟自动化权限同样的道理,只在 .onAppear
    // 和每次操作后重新查一次,不是 @Published:这个状态由 launchd 管,App 自己不会主动
    // 收到"进程挂了"这类通知,只能被动查。
    // 三态而不是 Bool —— 要展示"装了但没跑起来"这个中间态(见 LaunchdJobState)。
    @State private var collectorState: LaunchdJobState = .notRegistered
    @State private var isTogglingCollectorService = false
    // 只在"这次点了启用、结果没启动起来"时才为真,切走这个 tab 就清掉,不会把上一次失败的
    // 提示留着误导下一次操作。没有它的话,点"启用"失败后前台只会看到红叉+"未运行",跟从没
    // 点过一模一样,没有任何具体原因或下一步指引。
    @State private var collectorEnableFailed = false
    // App 本体版本 vs 打包进这份 App 的 collector 版本是否一致(见
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
            title: L10n.t("播放器")
        ) {
            playerCard
            browserAutomationCard
            unknownPlayerCard
            notificationDeniedCard
            trustedPlayersCard
            companionCard
            permissionCard
            fullDiskAccessCard
            collectorCard
        }
        .id(L10n.current)
        .onAppear {
            refreshUngatedNowPlaying(); refreshNotificationStatus(); refreshBrowserLiveStatus()
            // 卡里那句「媒体信息通道用不了」是启动时自检的结论,而那一下正好跑在最容易抖的
            // 时刻(见 MediaControlHealth 头注)。用户看到那句话的自然动作就是回这一页,
            // 借这一下复查:只在结论确实是「不可用」时才真跑一次,好的时候什么都不做。
            MediaControlHealth.shared.recheckIfUnavailable()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationStatus()
            // 用户可能切去系统设置 / 浏览器菜单改了权限再切回来,不等下一拍。
            refreshBrowserLiveStatus()
        }
        // 2 秒一拍跟主轮询同频 —— 这里只是**读**一个已经被填好的静态变量,不起任何子进程
        // (记录那一笔挂在 LocalPlaybackSource 既有的 media-control 调用上,见
        // MediaControlClient.recordUngatedNowPlaying)。浏览器实时状态那一查在后台线程跑。
        .settingsPolling(every: 2) {
            refreshUngatedNowPlaying()
            refreshBrowserLiveStatus()
        }
        .onChange(of: automationRefreshTick) { _, _ in refreshBrowserLiveStatus() }
        .onChange(of: stores.browserPlatformPairs) { _, _ in refreshBrowserLiveStatus() }
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

    // 播放器图标网格(「自动识别」是其中一张卡),跟引导页"选择播放器"那一步是同一个组件(Settings/PlayerPicker.swift),
    // 两处排版一致。用 SettingsCardHeader + SettingsRawRow 包起来而不是裸摆:这页所有分组都是
    // "卡片+发丝描边+统一内边距"的语言(见 SettingsDesignSystem.swift)。
    private var playerCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("播放器"))
            SettingsRawRow {
                PlayerPicker(features: FeatureSettingsStore.shared)
            }
            // 勾着「自动识别」时把话说明白:卡片上那圈虚线+角标只说得出"这颗由自动识别接管",说不出
            // "该去取消哪一张",所以这一行是必须的;没勾自动识别时不出现 —— 那时单独勾选就是全部判据。
            // 文案最后半句("取消勾选它")不能砍,那正是这一行存在的理由。
            if stores.players.contains(.auto) {
                SettingsNote {
                    Text(L10n.t("「自动识别」开着时会认出所有已知和你信任过的播放器，上面的勾选暂不生效。想只认其中几个，取消勾选它。"))
                }
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
        // (歌手名和专辑名都非空,且都是 trim 后判空;裸 `!isEmpty` 会让 album = " " 的播放
        // 过了这张卡、过不了那道守卫)。否则会摆出一张"点了必定没反应"的卡片:YouTube 视频
        // 就是 artist 有(频道名)、album 空这个形状,信任之后照样会被那道守卫丢掉。
        // 判据下沉到 LyrimuseCore.UnknownPlayerAlert.shouldOffer:通知那条路必须用**同一套**
        // 门槛,不然会出现「通知让你去信任,点进来这张卡却不在」。
        if let seen = ungatedNowPlaying,
           UnknownPlayerAlert.shouldOffer(
               bundleID: seen.bundleID, artist: seen.artist, album: seen.album,
               observedAt: seen.at, isAutoDetect: stores.players.contains(.auto), now: Date(),
               isAccepted: { TrustedPlayers.isAccepted($0) }) {
            SettingsCard {
                SettingsRow(
                    // 用真图标,跟隔壁两张卡同一份取图逻辑(AppIconResolver)。这张「发现未知播放器」
                    // 卡恰恰是最需要图标的一张:另外两张卡里的 App 用户本来就认识,这张问的是"这个你
                    // 没见过的 App 要不要信任",图标正是他判断"这是我刚在用的那个浏览器"最快的那条
                    // 线索,比 bundle id 那行小字快得多。
                    //
                    // 取不到(理论上不太可能:它此刻正在报播放,必然装着)才退回那个虚线问号 —— 那个
                    // 占位本身仍然是对的:"这个 App 是谁我们还不确定"。
                    icon: "questionmark.app.dashed",
                    iconImage: AppIconResolver.icon(forBundleID: seen.bundleID),
                    title: FeatureSettingsStore.appDisplayName(forBundleID: seen.bundleID) ?? seen.bundleID,
                    subtitle: unknownPlayerSubtitle(seen),
                    help: L10n.t("信任之后它跟内置播放器完全同权：显示歌词，也会记进收听历史")
                ) {
                    Button(L10n.t("加入信任列表")) {
                        Task { await FeatureSettingsStore.shared.trust(bundleID: seen.bundleID) }
                    }
                }
            }
        }
    }

    /// 通知权限被拒时说出来。
    ///
    /// 「发现未知播放器」**只做系统通知、没有菜单栏兜底**,所以权限被拒时这个功能会完全
    /// 静默,而用户会把它理解成「它没检测到新播放器」。这一行是唯一能说清"不是没检测到,
    /// 是通知被关了"的地方。只在真的 .denied 时出现,不占常态版面。
    @ViewBuilder
    private var notificationDeniedCard: some View {
        if stores.players.contains(.auto), notificationsDenied {
            SettingsCard {
                SettingsRow(
                    icon: "bell.slash",
                    title: L10n.t("新播放器提醒"),
                    subtitle: L10n.t("系统通知已关闭")
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
    /// **这张卡总是显示,哪怕一条信任项都没有** —— 它是「添加播放器…」唯一的入口。
    /// 原来的写法是"有信任项才显示",那在主动添加这个功能上就是一个**鸡生蛋**:没信任过
    /// 任何 App 到 卡片不显示 到 没有地方点「添加」到 只能回去被动等「自动识别」撞见。
    /// (同一个坑「网页播放器」卡踩过一次,见 `addablePlatformBrowsers` 头注。)
    ///
    /// 排版必须跟上面「播放器」「网页播放器」两张卡是同一套(3 列图标网格 +
    /// `choiceCardChrome` 外壳),别改回一行一条的 `SettingsRow` 列表:这三张卡在同一页里
    /// 上下挨着,讲的又是同一件事("哪些 App 算播放器"),两种排版并置会读成两类不相干的设置。
    /// bundle id 这种只在排查时才看的细节移进点开的气泡里(跟浏览器头像那套同一个套路),
    /// 格子面上只留图标+名字。
    private var trustedPlayersCard: some View {
        SettingsCard {
            // 补一个标题:playerCard 有自己的 SettingsCardHeader,紧跟着一张没有标题的卡在
            // 视觉上不成对,补上让两张卡看起来是同一套设计语言里的姐妹卡。
            SettingsCardHeader(title: L10n.t("已信任的播放器"))
            SettingsRawRow {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    // 按 bundle id 排序,别让格子顺序随 Dictionary 遍历顺序每次启动乱跳。
                    ForEach(stores.trustedPlayers.keys.sorted(), id: \.self) { bundleID in
                        trustedPlayerTile(bundleID: bundleID)
                    }
                    addTrustedPlayerTile
                }
                .frame(maxWidth: .infinity)
            }
            // 空列表时这张卡只剩标题和一个格子,得有一句话交代"加进来会怎样",
            // 否则它看起来像一个用途不明的入口。有信任项时那几格本身就说明了一切,不再重复。
            if stores.trustedPlayers.isEmpty {
                SettingsNote {
                    Text(L10n.t("加进来的应用跟内置播放器同权：它在播什么就显示什么，也计入收听记录。加错了随时移除。"))
                }
            }
        }
        .alert(
            L10n.t("没能添加"),
            isPresented: Binding(
                get: { trustedPlayerPickerError != nil },
                set: { if !$0 { trustedPlayerPickerError = nil } })
        ) {
            Button(L10n.t("知道了"), role: .cancel) { trustedPlayerPickerError = nil }
        } message: {
            Text(trustedPlayerPickerError ?? "")
        }
    }

    /// 哪一格正展开详情气泡。 跟 `expandedBrowserBundleID` 不同,这里**不需要**再搭一个
    /// platformID 去消歧:一个 bundle id 在这张网格里只出现一次,不存在同一个按钮被渲染两遍。
    @State private var expandedTrustedBundleID: String?

    /// 一格已信任的 App。图标用它自己的真图标(跟上面两张卡同一份 `AppIconResolver`),
    /// 查不到才退回印章图标 —— 一页里六个内置播放器都亮着真图标,这张卡清一色通用图标会显得不搭。
    private func trustedPlayerTile(bundleID: String) -> some View {
        Button { expandedTrustedBundleID = bundleID } label: {
            VStack(spacing: 6) {
                Self.appIconView(bundleID: bundleID, size: 26, fallbackSymbol: "checkmark.seal")
                Text(displayNameForTrusted(bundleID))
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.primary)
            }
            // 已信任 = 这个来源确实在生效,按跟上面两张卡同一套"选中"样式高亮(亮底+强调色
            // 描边+角标)。这张卡里没有"没选中"的格子 —— 不信任的 App 压根不在这里。
            .choiceCardChrome(isSelected: true)
        }
        .buttonStyle(.plain)
        // bundle id 直接当 tooltip:排查时最常要看的就是它,指一下就有,不必先点开气泡。
        .help(bundleID)
        .popover(isPresented: Binding(
            get: { expandedTrustedBundleID == bundleID },
            set: { if !$0 { expandedTrustedBundleID = nil } }
        )) {
            trustedPlayerPopover(bundleID: bundleID)
        }
    }

    /// 「添加播放器…」那一格。 它是主动添加**唯一**的入口,不能跟着"有没有信任项"隐藏
    /// (见 `trustedPlayersCard` 头注那条鸡生蛋)。
    ///
    /// 走未选中态的 `choiceCardChrome`(暗底+极淡描边),跟旁边亮着的已信任格子一眼分得开;
    /// 「从「应用程序」里挑一个」那句副标题塞不进一格卡片,改挂 tooltip。
    private var addTrustedPlayerTile: some View {
        Button { chooseTrustedPlayerFromApplications() } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                Text(L10n.t("添加播放器…"))
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.secondary)
            }
            .choiceCardChrome(isSelected: false)
        }
        .buttonStyle(.plain)
        .help(L10n.t("从「应用程序」里挑一个——不用等它正在播放"))
        // 手挂高亮:这一条在设置搜索目录里有登记(`SettingsSearchCatalog` 的
        // 「添加播放器…」),而自动挂高亮+滚进视野的是 `SettingsRow`/`SettingsCardHeader`
        // 那几个组件 —— 这里是一格自绘的卡片,不挂的话搜到它只会跳到这一页、既不高亮也不滚动。
        .settingsSearchHighlight(title: L10n.t("添加播放器…"))
    }

    /// 点一格弹出的详情气泡:图标+名称+bundle id,底下是「移除」。
    ///
    /// 排版和"移除放在最底下"这个位置都跟浏览器头像那个气泡(`browserPermissionPopover`)
    /// 一致 —— 两张卡并排在同一页里,点开长得不一样会被当成两种不同的东西。
    private func trustedPlayerPopover(bundleID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Self.appIconView(bundleID: bundleID, size: 24, fallbackSymbol: "checkmark.seal")
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayNameForTrusted(bundleID)).font(.system(size: 13))
                    // bundle id 可选中:它的用处就是被复制出去(贴进 issue、跟 features.json
                    // 里那份对一对)。提醒 `.fixedSize(vertical:)` 别删,理由同
                    // `browserPermissionPopover` 里那条:NSPopover 的尺寸协商会把多行压成一行加省略号。
                    Text(bundleID)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack {
                Button(L10n.t("移除")) {
                    expandedTrustedBundleID = nil
                    untrustPlayer(bundleID)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    /// 取消信任一个 App。
    ///
    /// **取消信任必须连带解除它的所有平台配对**。
    ///
    /// 「信任」和「配对」是两个存储(features.json 的 trusted_players /
    /// AppSettings 的 browserPlatformPairs)。只动前者会漂出一个**看着在工作、
    /// 其实全程被丢弃**的状态:浏览器还挂在「网页播放器」卡里、探针照常跑,
    /// 但它的播放因为不在信任列表里被整条丢掉,"发现未知播放器"那张卡还会
    /// 重新冒出来。
    ///
    /// 方向是**单向**的:取消信任 到 一并解除配对(不信任它,配对就没有
    /// 任何意义);而「移除配对」**不**取消信任 —— 信任的语义比配对宽
    /// (它还管"这个 App 的播放算不算数"),而且一个浏览器可能配了多个
    /// 平台,退出其中一个不代表不要它了。
    private func untrustPlayer(_ bundleID: String) {
        Task {
            await FeatureSettingsStore.shared.untrust(bundleID: bundleID)
            unpairBrowserEverywhere(bundleID)
        }
    }

    /// 「添加播放器…」那条路要说的话。nil = 没有待展示的失败。
    @State private var trustedPlayerPickerError: String?

    /// 从「应用程序」里挑一个 App,直接加进信任列表。
    ///
    /// 为什么要有这个主动入口:在此之前唯一的入口是**被动**的 —— 只有「自动识别」恰好撞见
    /// 某个未知 App **正在报 Now Playing**(还带 15 秒陈旧过滤)时,设置页才冒出一张发现卡。
    /// 错过那一刻就得回那个 App 里再放一首歌、再切回设置页等它出现;而用户决定"我要用它听歌"
    /// 的那一刻,往往恰恰是还没开始播的时候。
    ///
    /// 选完之后跟被动信任**完全同权**(显示 + 打卡),走的也是同一个 `trust` —— 这里只是多
    /// 一条到达它的路,没有第二套语义。
    private func chooseTrustedPlayerFromApplications() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.t("选择")
        panel.message = L10n.t("挑一个你想让 Lyrimuse 当作播放器的应用")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            trustedPlayerPickerError = L10n.t("读不出这个应用的标识，换一个试试。")
            return
        }
        // 用 Finder 显示的那个名字(本地化过、跟用户在「应用程序」里看到的一致),
        // 而不是 bundle id 或者文件名 —— 跟 BrowserPairing.chooseFromApplications 同一个理由。
        let name = FileManager.default.displayName(atPath: url.path)
        switch TrustedPlayers.manualTrustOutcome(
            bundleID: bundleID,
            trusted: stores.trustedPlayers,
            selfBundleID: Bundle.main.bundleIdentifier
        ) {
        case .itself:
            trustedPlayerPickerError = L10n.t("这就是 Lyrimuse 自己。")
        case .builtin(let player):
            trustedPlayerPickerError = String(
                format: L10n.t("「%@」已经是内置播放器了，在上面那张「播放器」卡里勾选它就行。"),
                player.displayName)
        case .alreadyTrusted:
            trustedPlayerPickerError = String(format: L10n.t("「%@」已经在这个列表里了。"), name)
        case .addable:
            Task { await FeatureSettingsStore.shared.trust(bundleID: bundleID) }
        }
    }

    /// 已信任项的显示名:优先用当初存下来的那份(collector 也用它当 ListenBrainz 标签),
    /// 空串(当初反查不到)时现查一次,还是查不到就退回 bundle id。
    private func displayNameForTrusted(_ bundleID: String) -> String {
        if let stored = stores.trustedPlayers[bundleID], !stored.isEmpty { return stored }
        return FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID
    }

    // MARK: - 浏览器歌词同步权限(平台与浏览器配对模型)

    /// 本体在 `BrowserPairing.addableBrowsers`(引导页那一步共用)——"信任是候选的一个来源、
    /// 不是候选的前提"这条规则记在那边的头注里。
    private func addablePlatformBrowsers(platformID: String) -> [String] {
        BrowserPairing.addableBrowsers(platformID: platformID)
    }

    /// 「从应用程序里选…」那条路失败时要说的话。nil = 没有待展示的失败。
    @State private var browserPickerError: String?

    /// 让用户自己从 /Applications 里挑一个浏览器。
    ///
    /// 为什么需要这条路:`knownBrowserBundleIDs` 只默认列四个,而那不是 UI 偷懒 ——
    /// `chromiumPrefsPaths` 只登记验证过的浏览器(见那边注释)。Vivaldi / Opera /
    /// Chromium / 各种 Beta 通道其实都是 Chrome 的分支、继承了同一份脚本字典,本来就驱得动,
    /// 只是没人验过它们的 Preferences 路径。
    ///
    /// 本体在 `BrowserPairing.chooseFromApplications`(引导页「配对浏览器」那一步共用同一份)
    /// —— 那边的头注记着"必须真的驱得动才收下"这条判据和它的理由。这里只负责把返回的错误
    /// 文案接到这一页的 `.alert` 上。
    private func chooseBrowserFromApplications(platformID: String) {
        browserPickerError = BrowserPairing.chooseFromApplications(
            platformID: platformID,
            revealPairing: { bundleID in
                expandedBrowserBundleID = bundleID
                expandedBrowserPlatformID = platformID
            },
            automationDidResolve: { automationRefreshTick &+= 1 })
    }

    /// 把"用户自己从应用程序里挑过这个浏览器"这件事记下来,让它此后出现在「+」菜单里。
    ///
    /// 双写:AppSettings 负责持久化,`BrowserAutomationPermission` 负责让本次运行立刻认它
    /// (同 `pairBrowser` 那条注释里的模式)。只写一边的话要么关了 App 就忘,要么这次加完
    /// 头像点开还是"不支持"。
    ///
    /// **内置名单里的直接跳过**:它们本来就默认展示,再记一份是冗余状态,而
    /// `addablePlatformBrowsers` 拼菜单时又要把它们从手动那段里滤掉,两处口径容易走散。
    /// 反过来,**不在内置名单、但 `family(...)` 本来就认识的(Arc)必须记** —— 那正是这个
    /// 函数存在的理由,见 `knownBrowserBundleIDs` 头注。
    /// 本体在 `BrowserPairing`(引导页那一步也要用),这里只转发。
    private func rememberManualBrowser(_ bundleID: String, family: BrowserAutomationPermission.Family) {
        BrowserPairing.rememberManualBrowser(bundleID, family: family)
    }

    /// 本体在 `BrowserPairing.trustAndPair`(引导页「配对浏览器」那一步共用同一份)——
    /// 那个函数体里的**顺序**是硬要求(配对先写、信任后跑、引擎族要在配对之前落盘、气泡
    /// 必须让出一拍再开),完整理由都在那边的头注里。
    ///
    /// 这里只把设置页**自己的**两个 UI 反应接进去:配对完展开那个浏览器的权限气泡,以及
    /// 系统授权有结果之后强制重算同步现读的权限状态。
    private func trustAndPairBrowser(_ bundleID: String, platformID: String) {
        BrowserPairing.trustAndPair(
            bundleID, platformID: platformID,
            revealPairing: {
                expandedBrowserBundleID = bundleID
                expandedBrowserPlatformID = platformID
            },
            automationDidResolve: { automationRefreshTick &+= 1 })
    }

    /// 请求过系统授权之后要求**重查一次**浏览器实时状态(见 `refreshBrowserLiveStatus`):
    /// 系统层面的权限变化没有 @Published 可依赖,靠这个计数器的 onChange 去触发后台重查。
    /// 它的语义是"触发后台重查",不是"强制重算 body、body 里同步现读"——后者会阻塞主线程。
    @State private var automationRefreshTick = 0

    /// 一个浏览器此刻的三样实时状态。**只由 `refreshBrowserLiveStatus` 在后台查、回主线程写**,
    /// body 里的任何判定(`browserJSLikelyWorking` / `browserSetupIncomplete` /
    /// `browserPermissionPopover`)都只读这份缓存。
    struct BrowserLiveStatus: Equatable {
        /// 浏览器自己那道「允许 Apple Events 里的 JavaScript」开关(读 Chromium 的 Preferences
        /// 文件 / Safari 的 CFPreferences —— 是**磁盘 I/O**)。
        var jsSwitch: BrowserAutomationPermission.Status
        var running: Bool
        /// 系统自动化(TCC)授权。nil = 浏览器没在跑、或这次查询超时,查不出来 —— **不能**显示成
        /// 未授权,那是假阴性,见 `MusicAutomationPermission.check(bundleID:askIfNeeded:)` 头注。
        var automation: MusicAutomationPermissionStatus?
    }
    @State private var browserLiveStatus: [String: BrowserLiveStatus] = [:]
    @State private var browserLiveStatusInFlight = false

    /// 把浏览器卡片要显示的实时状态**一次性在后台查完**,回主线程写进 `browserLiveStatus`。
    ///
    /// **不要把这些查询搬回 view body**。`browserSetupIncomplete` / `browserJSLikelyWorking` /
    /// `browserPermissionPopover` 底下是 `MusicAutomationPermission.check`
    /// (`AEDeterminePermissionToAutomateTarget` 到 `semaphore_wait_trap`,跨进程问 tccd,单次
    /// 3–48ms、中位 4ms)和 `BrowserAutomationPermission.status`(读 Chromium Preferences 文件)。
    /// 配了 4 个浏览器时每个平台卡片各画一遍 = 每次 body 重算 4–8 次 IPC、主线程阻塞 20–380ms,
    /// 表现为"设置页切分页有延迟、不跟手"。
    ///
    /// 查和画必须拆开:查在后台、画只读缓存。什么时候重查:进入页面、每 2 秒一拍(跟页面既有
    /// 的心跳同频,在后台跑,4 个浏览器 ×4ms 无感)、切回 App、请求过授权之后
    /// (`automationRefreshTick`)、配对表变了。同一时刻最多一次在飞。
    ///
    /// `isRunning` 读 `NSWorkspace.runningApplications`,在主线程读完再带进后台 —— 它便宜,
    /// 而且 NSWorkspace 那套属性按文档就该在主线程碰。
    private func refreshBrowserLiveStatus() {
        guard !browserLiveStatusInFlight else { return }
        let ids = Set(stores.browserPlatformPairs.values.flatMap { $0 })
        guard !ids.isEmpty else {
            if !browserLiveStatus.isEmpty { browserLiveStatus = [:] }
            return
        }
        let running = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, MusicAutomationPermission.isRunning(bundleID: $0))
        })
        browserLiveStatusInFlight = true
        Task {
            var fresh = await Task.detached(priority: .utility) { () -> [String: BrowserLiveStatus] in
                var out: [String: BrowserLiveStatus] = [:]
                for id in ids {
                    out[id] = BrowserLiveStatus(
                        jsSwitch: BrowserAutomationPermission.status(forBundleID: id),
                        running: running[id] ?? false,
                        automation: nil)
                }
                return out
            }.value
            // 目标没在跑时 check 查不出真实状态(会落进 procNotFound 被当成"还没问过"),
            // 干脆不问,留 nil 表示"查不到"。
            for id in ids where running[id] ?? false {
                fresh[id]?.automation = await MusicAutomationPermission.status(bundleID: id, askIfNeeded: false)
            }
            browserLiveStatusInFlight = false
            if fresh != browserLiveStatus { browserLiveStatus = fresh }
        }
    }

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
        guard stores.trustedPlayers[bundleID] == nil else { return name }
        return name + L10n.t("（未信任，选择后自动信任）")
    }

    // 配对/取消配对都走同一套"改 AppSettings(持久化)+ 同步进
    // BrowserPositionProbe.shared(让探针立刻生效)"双写,跟 romanizationScripts 那一档
    // 完全同一个模式(见 AppSettings.browserPlatformPairs 注释)——只写一边的话,要么关了
    // App 就忘,要么改了要等下次启动才生效。
    /// 本体在 `BrowserPairing.pair`,这里只转发。
    private func pairBrowser(_ bundleID: String, platformID: String) {
        BrowserPairing.pair(bundleID, platformID: platformID)
    }

    /// 把这个浏览器从**所有**平台的配对里摘掉。取消信任时用,理由见那个按钮上的提醒。
    private func unpairBrowserEverywhere(_ bundleID: String) {
        var pairs = stores.browserPlatformPairs
        var changed = false
        for (platformID, ids) in pairs where ids.contains(bundleID) {
            var next = ids
            next.remove(bundleID)
            if next.isEmpty { pairs.removeValue(forKey: platformID) } else { pairs[platformID] = next }
            changed = true
        }
        // 相等守卫:@Published 是 willSet 语义,等值赋值照样广播 objectWillChange。
        guard changed else { return }
        AppSettings.shared.browserPlatformPairs = pairs
        BrowserPositionProbe.shared.platformBrowserPairs = pairs
        forgetManualBrowserIfUnpaired(bundleID)
    }

    /// 用户手动挑进来的浏览器,**最后一个配对也被移除时一起忘掉**。
    ///
    /// 不忘的话它会**永远**留在「+」菜单里:`manualBrowserFamilies` 全仓只有一处写入
    /// (`chooseBrowserFromApplications`),删除只有这一处 —— 少了它,用户试着加过一个浏览器
    /// 就再也拿不掉了。
    ///
    /// 只在**这一次用户主动移除配对**时做,不做启动时的批量清理 —— 后者是在用户没做任何
    /// 动作的时候替他删状态,跟"卸载了的浏览器保留配对记录"那条既有原则冲突(见
    /// `browserPlatformCard` 头注)。
    ///
    /// 判据是"一个配对都不剩"而不是"移除了这个平台的配对":同一个浏览器可以配多个平台,
    /// 只撤掉其中一个的时候它显然还要留着。手动加进来的浏览器一加进来就**同步**被配对了
    /// (`chooseBrowserFromApplications` 到 `trustAndPairBrowser` 到 `pairBrowser`,后者不在
    /// await 之后),所以不存在"刚加完还没配上"这个中间态被误清的窗口。
    ///
    /// 忘掉的成本很低:再要它时「从应用程序中选择…」重新挑一次即可 —— 这份字典存的本来就是
    /// 一个**判定结果的缓存**(那个 App 的引擎族),不是用户精心配的偏好。
    /// 本体在 `BrowserPairing.forgetManualBrowserIfUnpaired`,这里只转发。
    private func forgetManualBrowserIfUnpaired(_ bundleID: String) {
        BrowserPairing.forgetManualBrowserIfUnpaired(bundleID)
    }

    /// 本体在 `BrowserPairing.unpair`(引导页那一步共用),这里只转发。
    private func unpairBrowser(_ bundleID: String, platformID: String) {
        BrowserPairing.unpair(bundleID, platformID: platformID)
    }

    /// 哪个浏览器的头像正在展开详情气泡——同一时间只有一个,点另一个头像会先收起上一个
    /// (`.popover` 各自绑定自己的 bool,靠这两个共享的可选值天然互斥)。
    ///
    /// **必须跟 `expandedBrowserPlatformID` 成对使用,单靠 bundleID 不够**:同一个浏览器
    /// 可以配对给多个平台(比如 Arc 同时挂在 YouTube Music 和 Spotify 两张卡下面),
    /// `browserAvatarButton` 会为同一个 bundleID 渲染出两个头像按钮。只判
    /// `expandedBrowserBundleID == bundleID` 的话,两张卡上的头像会同时满足呈现条件 ——
    /// SwiftUI 实际只呈现其中一个,而选中的是哪一个不受调用方控制,表现就是气泡挂错了卡。
    /// bundleID 本身不足以定位"是哪张卡上的哪个头像",必须搭配 platformID。
    @State private var expandedBrowserBundleID: String?
    @State private var expandedBrowserPlatformID: String?

    // 这张卡管的是"浏览器自己加的第二道 JS 执行开关"(跟下面 permissionCard 管的系统级
    // Automation/TCC 授权是两码事,见 BrowserAutomationPermission 头注)。
    //
    // **展示条件是"这台机器上装了受支持的浏览器",不是"已经信任过某个浏览器"**。
    // 「+」菜单走的是 `trustAndPairBrowser`,**不要求先信任** —— 选一个没信任过的浏览器会
    // 一步自动信任+配对。也就是说这张卡是"信任这件事本身的入口",不是"信任之后才用得上的
    // 配置面板"。拿"已信任"当条件会制造**鸡生蛋**:没信任过任何浏览器 到 卡片不显示 到
    // 界面上没有任何地方能发起信任 到 只能靠"真的用浏览器放歌 到 被动检测到未知播放器"这条
    // 被动路径绕回来。
    //
    // "不为了'这里没事'而占地方"这条原则**保留**,只是判据是"装了受支持浏览器 = 真的有事
    // 可做";一台只装了 Firefox 的机器仍然不显示这张卡。
    //
    // 模型是显式的"平台与浏览器配对":按 `BrowserPositionProbe.supportedPlatforms` 逐个平台
    // 分组,配对之外还提供"添加浏览器" —— 没配对过的浏览器完全不会触发后台探测(见
    // BrowserPositionProbe.kickIfNeeded)。
    //
    // 外层容器用 PlayerChoiceCard 同款的图标网格小卡片(不是铺满宽度的一行),让这张卡跟上面
    // 「播放器」卡在同一页里是同一套视觉语言;头像/气泡/添加菜单那套交互不变。
    @ViewBuilder
    private var browserAutomationCard: some View {
        // 走 `knownBrowserBundleIDs` + 用户手动加过的那批,判据跟 `addablePlatformBrowsers`
        // 里那一道完全同源 —— 那边能列出候选,这边就该把卡片显示出来,两处不该有分歧。
        let anySupportedInstalled = (BrowserAutomationPermission.knownBrowserBundleIDs
            + Array(stores.manualBrowserFamilies.keys))
            .contains { BrowserAutomationPermission.isInstalled(bundleID: $0)
                        && BrowserAutomationPermission.family(forBundleID: $0) != nil }
        if anySupportedInstalled {
            SettingsCard {
                SettingsCardHeader(
                    title: L10n.t("网页播放器"),
                    help: L10n.t("网页播放器不会主动汇报精确进度，切歌后需要这个开关才能立刻校准。")
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
            // **回到 Lyrimuse 时重新读一次两道门的状态**。
            //
            // 这张卡上所有状态都是**渲染时同步现读**的(浏览器那道 JS 开关读的是它自己的
            // 配置文件、系统自动化授权读的是 TCC),没有任何 `@Published` 可以依赖 ——
            // 用户按指引跑去浏览器菜单里把开关勾上、再切回来,界面上什么都不会变,得手动
            // 把气泡关掉重开(或者点一次「重新检测」)才刷新。
            //
            // 「App 重新变成活跃」正好是这条流程的天然节拍:去浏览器操作这件事**必然**要
            // 切走再切回来。比起给配置文件挂 FSEvents 或者起个定时器轮询,这个信号更准
            // (不会在用户没做任何事的时候空刷)、也更省 —— 而且它同时覆盖另一道门:用户
            // 去「系统设置 到 自动化」里勾完回来,那一行也会跟着更新。
            //
            // 只是让 SwiftUI 重新读一遍,不发起任何 AppleScript/自检 —— 自检有子进程开销,
            // 不该在每次切回 App 时白跑一次(要不要跑由用户点「重新检测」决定)。
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                automationRefreshTick &+= 1
                // **再补一拍**:Chromium 那道开关勾完之后**不是立刻写盘的** —— 它的偏好
                // 走批量延迟提交,用户在浏览器菜单里勾上、两三秒就切回来的话,文件里很可能
                // 还是旧值,上面那次刷新读到的就还是"关"。补这一拍让它过一会儿自己纠正过来,
                // 用户不必再手动做什么。
                //
                // 12 秒是个**留余量的兜底值,不是量出来的常数** —— 没有公开保证的提交
                // 间隔可依。真要立刻确认,气泡里那个「重新检测」是**不看文件**的活证据
                // (它直接执行一段 JavaScript),那条路任何时候都即时准确。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    automationRefreshTick &+= 1
                }
            }
        }
    }

    /// 跟 `PlayerChoiceCard` 同一套卡片底(10pt 圆角、26×26 图标、`.caption` 文字),
    /// 图标下面多一行头像+添加按钮,是跟 `PlayerChoiceCard` 相比唯一多出来的内容,交互
    /// 逐字复用 `browserAvatarButton`/`addablePlatformBrowsers`/`trustAndPairBrowser`,
    /// 没有新逻辑。
    ///
    /// 配对了至少一个浏览器就按 `PlayerChoiceCard` 同款样式高亮(强调色描边+浅色底)——
    /// "选中"不是一个新的独立开关,而是直接复用既有的"配了/没配"这个状态,配对本身早就是
    /// 显式的用户动作(点「+」选浏览器)。配对的浏览器无论有没有勾"自动识别"都会被采纳
    /// (见 MediaControlClient.fetchMultiSelectedSnapshot / collector isTrustedPlayerBundleID),
    /// 高亮因此如实反映"这确实是一个会生效的来源",不是纯装饰。整卡仍然不包一个 `Button`
    /// (配对的是一组浏览器,不是单选一个),只有头像和"+"各自可点。
    private func browserPlatformCard(platform: BrowserPositionProbe.BrowserMusicPlatform) -> some View {
        // 已配对的头像也要过 `isInstalled` 这道门。只在「+」菜单侧过滤装没装的话,
        // "配对过、后来把那个浏览器卸载了"会一直留一个取不到图标的虚线方框
        // (`appIconView` 的 `app.dashed` 兜底),点开还给一份无意义的权限状态 —— 那是
        // "设置里显示的东西跟实际能用的东西对不上"。
        //
        // **只是不显示,配对记录原样留在 `browserPlatformPairs` 里** —— 装回来自动恢复,
        // 用户不用重配。这跟「指定的屏幕拔掉后自动回落到自动、偏好保留、插回来即恢复」
        // 是同一个口径(见 05-notch.md「显示在哪块屏幕」),不是新发明的处置方式。
        // 也因此**不要**顺手在这里 `unpairBrowser` 去"清理" —— 那会把用户的配置替他删掉。
        let pairedBundleIDs = (stores.browserPlatformPairs[platform.id] ?? [])
            .filter { BrowserAutomationPermission.isInstalled(bundleID: $0) }
            .sorted()
        let addable = addablePlatformBrowsers(platformID: platform.id)
        return VStack(spacing: 6) {
            if let icon = WebPlatformIcon.image(platform.id) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            Text(platform.displayName)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.primary)
            // 头像并排展示、不重叠 —— 负间距的"头像堆叠"看不出到底配了几个。
            HStack(spacing: 6) {
                ForEach(pairedBundleIDs, id: \.self) { bundleID in
                    browserAvatarButton(bundleID: bundleID, platformID: platform.id)
                }
                // 条件恒真,不要写成 `!addable.isEmpty`:内置候选全配完之后「+」会整个消失,
                // 而菜单里还有「从应用程序中选择…」这条路 —— 那时恰恰是最需要它的时候(装的浏览器
                // 不在内置那四个里)。
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
                    // 「+」自己就长得像"点开有东西",再挂一个下拉小箭头只是噪声——这一行卡片上
                    // 排着一串浏览器头像,多出来的箭头会被当成其中一个图标的角标。
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        // 外壳走 `choiceCardChrome`,别在这里另写一份圆角/底色/描边:这张卡跟上面「播放器」
        // 卡在同一页里并排,样式各写一份下次调色就会漏一处。整卡不可点(只有头像和「+」各自
        // 可点),所以关掉悬停高亮。
        .choiceCardChrome(isSelected: !pairedBundleIDs.isEmpty, highlightsOnHover: false)
    }

    private func browserAvatarButton(bundleID: String, platformID: String) -> some View {
        Button {
            expandedBrowserBundleID = bundleID
            expandedBrowserPlatformID = platformID
        } label: {
            Self.appIconView(bundleID: bundleID, size: 22, fallbackSymbol: "app.dashed")
                // 角标是自动展开那条的**兜底**:气泡一关就再没有任何提示了,而"还差两步"
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
    /// (需要时才出现)。
    ///
    /// 这个气泡要说清**两道**门,不是一道。浏览器歌词同步一共需要三样东西:①Lyrimuse
    /// 自己的信任列表(配对这个动作本身就写了)、②浏览器自己那道「允许 Apple Events 里的
    /// JavaScript」开关、③**系统的自动化(TCC)授权**。只显示②的话③对用户完全不可见 ——
    /// ③在界面上没有入口时只能等探针第一次真的发 Apple Event 时由系统被动弹出,体感就是
    /// "配对完没弹授权框,放歌的时候才弹"。
    private func browserPermissionPopover(bundleID: String, platformID: String) -> some View {
        // 三样实时状态全部来自 `browserLiveStatus` 缓存(后台查好的),这里**不发任何 IPC、
        // 不读任何文件** —— 理由见 `refreshBrowserLiveStatus` 头注。还没查回来时按"查不到"
        // 显示,下一拍就会填上。
        let live = browserLiveStatus[bundleID]
        let status = live?.jsSwitch ?? .unknown
        // 目标没在跑时 `check` 查不出真实状态(会落进 procNotFound 被当成"还没问过"),
        // 所以用 nil 表示"查不到",**不能**显示成"未授权":那是假阴性,已经授权过的浏览器
        // 一关掉就会被说成没授权。
        let running = live?.running ?? false
        // **实时状态优先,查不到时才拿"自检通过过"当证据**。
        //
        // 自检做的是"真的让这个浏览器执行一段 JavaScript" —— 那条 Apple Event 发得出去,
        // 就**证明** TCC 自动化授权当时是通的(不通根本发不到浏览器那一步)。所以在浏览器
        // 没在运行、`check` 查不到的时候,这个既成事实比一句「查不到」有用得多 —— 否则会
        // 同时出现「✓ 已生效」和「请求系统授权」,自相矛盾。
        //
        // 但**浏览器在跑时一律以实时结果为准**,不许被这个既成事实盖过 —— 用户后来到
        // 系统设置里撤销授权是真会发生的(这个 App 是 ad-hoc 签名,下一次构建也会让授权
        // 失效),那时必须如实报 denied/notDetermined 并把按钮放出来。
        let liveAutomation: MusicAutomationPermissionStatus? = running ? live?.automation : nil
        let verifiedBefore = stores.browserJSVerifiedAt[bundleID] != nil
        let automation: MusicAutomationPermissionStatus? =
            liveAutomation ?? (verifiedBefore ? .authorized : nil)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Self.appIconView(bundleID: bundleID, size: 24, fallbackSymbol: "app.dashed")
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayNameForTrusted(bundleID)).font(.system(size: 13))
                    // 每条状态说明都必须 `.fixedSize(horizontal: false, vertical: true)`,否则会被
                    // 截成一行加省略号。它们没有 `lineLimit`、按理该自己换行,离屏渲染也确实正常折行 ——
                    // 问题在 **NSPopover 的尺寸协商**:内容一高,浮层给的高度提议不够,SwiftUI 就把多行
                    // 压成一行加省略号。`fixedSize(vertical:)` 让 Text 报出折行后的真实高度并拒绝被压。
                    // 别删,也别改成 `lineLimit(1)` —— 这几句正是要读全的。
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
            // 前台的按钮。 路径逐个浏览器不一样,别写一份通用文案,见 browserManualEnableHint。
            if !browserJSLikelyWorking(bundleID: bundleID) {
                Text(browserManualEnableHint(bundleID: bundleID))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // **"勾完要重启浏览器"必须写出来**:这个开关是**启动时读一次**的,开和关两个
                // 方向都要重启才落实。(Chromium:在菜单里把开关关掉、配置文件当场变 false,而没
                // 重启的浏览器照样能执行 JS;Safari:勾上之后一直失败,退出重开就通了。)
                //
                // 单独一行、不并进上面那句路径:那句是"点哪",这句是"点完还要做什么",混在一起
                // 读者会以为是同一步的补充说明而略过 —— 而略过的代价正是那种"我明明开了却不 work"。
                Text(L10n.t("勾完要退出并重新打开这个浏览器才生效——这个开关只在浏览器启动时读一次。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 自检结果(点过才有)。 这是用户手动开完之后**唯一**能确认"做对了没有"的通路
                // —— Chromium 系那道开关的状态读不出来(要完全磁盘访问权限),所以上面那行状态
                // 永远是「无法确认状态」,没有这里就没有任何回显。
                if let r = browserSelfTestResults[bundleID] {
                    // 传 switchDisabled:让这行知道上面那行正在说什么,别各说各话
                    // (见 browserSelfTestCaption 的头注)。
                    Text(browserSelfTestCaption(r, switchDisabled: status == .disabled))
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
                    // 传 switchDisabled:让这行知道上面那行正在说什么,别各说各话
                    // (见 browserSelfTestCaption 的头注)。
                    Text(browserSelfTestCaption(r, switchDisabled: status == .disabled))
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

    /// 自检结果与"正在检测"标记。 用 @State 而不是塞进某个 model:它是**这次点击的结果**,
    /// 关掉设置窗就该忘掉,不该持久化 —— 持久化就又造出一份会跟现实脱节的粘滞状态。
    @State private var browserSelfTestResults: [String: BrowserPositionProbe.SelfTestResult] = [:]
    @State private var browserSelfTestRunning: Set<String> = []

    /// 真的去试一次能不能执行 JavaScript。提醒 `selfTest` 会起 osascript 子进程并阻塞,
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
                // 通过就**落盘**,让状态真正往前流转 —— 否则关掉设置窗一切归零,用户每次打开
                // 都看见「无法确认状态」、还得再检测一遍。
                //
                // 反过来,**明确的反证要把这条记录抹掉**:浏览器就开着、命令也发到它手上了,
                // 它却回绝(`blocked`)或干脆不回(`noReply`) —— 那"上次通过过"就是一句过期的话,
                // 留着它下次打开设置窗又会把"已配好"说回去(`browserJSLikelyWorking` 认这条记录),
                // 角标也跟着消失。
                // `noTab`/`failed` **不动**:那是"没法判定"(浏览器没开、脚本自身出错),不是
                // "判定为不行",不该拿它抹掉之前证明过的事实。
                var map = stores.browserJSVerifiedAt
                switch r {
                case .ok:
                    map[bundleID] = Date()
                    AppSettings.shared.browserJSVerifiedAt = map
                case .blocked, .noReply:
                    if map.removeValue(forKey: bundleID) != nil { AppSettings.shared.browserJSVerifiedAt = map }
                case .noTab, .failed:
                    break
                }
                // 成功就顺手刷一次上面那行系统授权状态 —— 自检能过说明 TCC 也是通的。
                automationRefreshTick &+= 1
            }
        }
    }

    /// - switchDisabled: 那道 JS 开关在**配置文件里**是不是关着的(= 上面
    ///   `browserJSSwitchCaption` 正在说「重启后就会失效」的那种状态)。
    ///
    /// 传它进来是为了**不让这张卡自己跟自己打架**:这两块状态各自都没错、答的却是两个
    /// 不同的问题 —— 上面那行读配置文件,说的是「**下次启动**会怎样」;这里是实测发一条
    /// JavaScript 过去,说的是「**现在**怎样」。开关关掉但浏览器还没重启时两者同时为真,
    /// 于是上面橙字说「重启后就会失效」、下面绿字说「✓ 已生效」,两句都对,读起来却是直接矛盾。
    ///
    /// 病根在「已生效」这三个字有歧义:用户读成「我刚勾的那个开关已经生效了」,而它实际
    /// 只想说「此刻驱动得动」。所以这一档换成明确带时效的措辞,让两块变成同一个故事的两半。
    /// 这跟 browserPermissionPopover 那处是同一类问题、同一个修法:**让互相矛盾的状态块
    /// 互相感知**。
    private func browserSelfTestCaption(_ r: BrowserPositionProbe.SelfTestResult,
                                        switchDisabled: Bool = false) -> String {
        switch r {
        case .ok:
            if switchDisabled {
                return L10n.t("✓ 此刻驱动得动——但这是重启前的暂时状态：上面那个开关已经被关掉，重启后就会失效")
            }
            return L10n.t("✓ 已生效——这个浏览器现在可以被驱动了")
        case .noTab: return L10n.t("这个浏览器没在运行，或者一个标签页都没开——打开它并随便开一个网页，再检测一次")
        case .blocked: return L10n.t("还没生效：浏览器回绝了执行 JavaScript 的请求，按上面那条路径再确认一下开关勾上了没有")
        case .noReply: return L10n.t("还没生效：浏览器收下了请求却一直没回应，多半是那个开关还没勾上（有的浏览器不报错、直接不回）。按上面那条路径再确认一下")
        case .failed(let msg): return String(format: L10n.t("检测没通过：%@"), msg)
        }
    }

    /// 浏览器自己那道 JS 开关此刻什么状态。
    ///
    /// Chromium 系读的是浏览器 profile 里的 `Preferences`,而**别的 App 读
    /// `~/Library/Application Support/<浏览器>/` 需要「完全磁盘访问权限」** —— 没给的话
    /// 这里恒为 `.unknown`。那不是坏了,是查不到,文案要如实说,别显示成"未开启"。
    private func browserJSSwitchCaption(bundleID: String, status: BrowserAutomationPermission.Status) -> String {
        switch status {
        case .enabled: return L10n.t("已开启")
        case .disabled:
            // **文件和实测回答的是两个不同的问题,都对,不存在"以谁为准"**。文件说的是
            // 「**下次启动**会怎样」,实测说的是「**现在**怎样」—— Chromium 那道开关只在浏览器
            // 启动时读一次(见 BrowserAutomationPermission 头注),运行期间在菜单里改它,文件
            // 立刻变、运行中的浏览器**纹丝不动**(关的方向和开的方向都一样)。
            //
            // 所以两者不一致时**要给指引、不能报平安**:文件说关,意味着这个浏览器下次重启就会
            // 失效 —— 那是一次已经排好队的、必然到来的失效,正是最该提前告诉用户的事。
            // 别改成「以实测为准」,方向是反的。
            if browserJSProvenWorking(bundleID: bundleID) {
                return L10n.t("这个开关已经被关掉了——现在还能用，只是因为该浏览器还没重启；重启后就会失效")
            }
            return L10n.t("未开启")
        case .unknown:
            // 读不到文件时,**实测通过过**就是这里能拿到的最强证据,比"无法确认"有用得多。
            // 但措辞必须是"上次检测通过"而不是"已开启" —— 用户后来把开关关掉我们无从得知,
            // 断言当下就又成了一句会过期的谎(见 AppSettings.browserJSVerifiedAt 那段)。
            if let at = stores.browserJSVerifiedAt[bundleID] {
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

    /// **有没有硬证据证明这个浏览器现在真的驱得动** —— 这一轮自检通过,或者以前某次通过过
    /// 并落了盘。后者是 Chromium 系在没有完全磁盘访问权限时唯一拿得到的证据。
    /// 抽出来是因为两个地方要用同一条判据:`browserJSLikelyWorking`(决定给不给指引)和
    /// `browserJSSwitchCaption`(决定那行状态怎么措辞),两边说的话必须一致。
    private func browserJSProvenWorking(bundleID: String) -> Bool {
        if browserSelfTestResults[bundleID] == .ok { return true }
        return stores.browserJSVerifiedAt[bundleID] != nil
    }

    private func browserJSLikelyWorking(bundleID: String) -> Bool {
        // 只读缓存,不读文件 —— 见 `refreshBrowserLiveStatus` 头注。还没查回来按 `.unknown`
        // 走,下面的逻辑对 unknown 本来就有处理(落回自检结果 / 落盘证据)。
        let status = browserLiveStatus[bundleID]?.jsSwitch ?? .unknown
        // **文件明确说"关"的时候一律算没配好,哪怕此刻实测还能用**。理由见
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
        return stores.browserJSVerifiedAt[bundleID] != nil
    }

    /// **这个浏览器**打开那道开关的确切位置。
    ///
    /// 四家各不相同,而且**中英文不是同一条路径的直译**。出处(逐个从各自 App 包里的
    /// 本地化资源抠出来核对过):
    ///   - Chrome:`Google Chrome Framework.framework/.../{en,zh_CN}.lproj/locale.pak`
    ///     菜单栏标题英文 `View`、中文**「显示」**;子菜单 `Developer` / 「开发者」。
    /// Chrome **自己的帮助文案**里写的是「查看」,跟它自己的菜单栏对不上,别信它。繁体(zh_TW)
    ///     是「顯示方式 / 開發人員選項 / 允許 Apple 事件的 JavaScript」,不是简体的逐字转写。
    ///   - Edge:同样的 pak,英文 `View`、中文**「查看」**;子菜单 `Developer` / 「开发人员」。
    ///     跟 Chrome **两处都不同**,一份通用文案不可能同时对。
    ///   - Brave:`Brave Browser Framework.framework/.../{en,zh_CN,zh_TW}.lproj/locale.pak`,按字符串 ID
    ///     对(菜单栏标题 151、子菜单 162、开关 12465):简体与 Chrome 逐字相同「显示 / 开发者 /
    ///     允许 Apple 事件中的 JavaScript」,繁体是「顯示方式 / 開發人員選項 / 允許 Apple 事件的 JavaScript」。
    ///     Brave 自己帮助文案里写的「查看」同样跟它的菜单栏对不上。
    ///   - Arc:`Contents/Resources/Base.lproj/MainMenu.nib` 里是 `View` / `Developer` /
    ///     `Allow JavaScript from Apple Events`,而 `zh-CN.lproj/MainMenu.strings` 里
    ///     **没有**这几项 —— 也就是说中文系统下 Arc 这几个菜单**仍然显示英文**。
    ///   - Safari:压根不在菜单栏,在**设置**里(`DeveloperPreferences.strings`):
    ///     先在「高级」勾「显示网页开发者功能」(`Show features for web developers`),
    ///     设置里才会出现「开发」面板,里面才有「允许Apple事件中的JavaScript」(中文原文
    ///     就是不带空格的)。
    ///
    /// 改文案前请回到各自 App 包里重新核一遍,别照记忆写。
    private func browserManualEnableHint(bundleID: String) -> String {
        switch bundleID {
        case "com.google.Chrome":
            // **别把"Chrome 自己的帮助文案写错了"那段考据加进用户文案里** —— 那是给维护者
            // 看的,写在 `browserManualEnableHint` 的头注里就够了;用户要的只是"点哪"。
            return L10n.t("在 Chrome 菜单栏依次打开「显示 → 开发者 → 允许 Apple 事件中的 JavaScript」。")
        case "com.microsoft.edgemac":
            return L10n.t("在 Edge 菜单栏依次打开「查看 → 开发人员 → 允许 Apple 事件中的 JavaScript」。")
        case "com.brave.Browser":
            return L10n.t("在 Brave 菜单栏依次打开「显示 → 开发者 → 允许 Apple 事件中的 JavaScript」。")
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
    /// **只在"确定还没好"时才算未完成**。系统自动化授权那一档在浏览器没运行时**查不到**
    /// (见 `browserPermissionPopover` 里那段:`check` 会落进 procNotFound 被当成"还没问过"),
    /// 那种"不确定"**不算**未完成 —— 否则每次那个浏览器没开着,一个橙色感叹号就会挂在那儿,
    /// 而它什么问题都没有。宁可漏报也不误报:漏报的代价是用户点开才发现还差一步,误报的
    /// 代价是这个角标从此没人信。
    private func browserSetupIncomplete(bundleID: String) -> Bool {
        // 还没查回来先不亮角标:这个函数在每个头像的 overlay 里、每次 body 重算都会跑,第一帧
        // 亮一下再灭是最难看的那种闪烁。后台那一拍几毫秒就回来了。
        guard let live = browserLiveStatus[bundleID] else { return false }
        // 判据跟气泡里那条保持一致(`browserJSLikelyWorking`):实测通过过就算配好,
        // 否则 Chromium 系永远读不到配置文件、角标就永远挂着,那个角标也就没人信了。
        if !browserJSLikelyWorking(bundleID: bundleID) { return true }
        guard live.running else { return false }
        return live.automation != .authorized
    }


    /// 系统自动化授权那一行的说明。 nil ≠ 未授权 —— 见调用点那段。
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

    /// 按 bundle id 取这个 App 的真图标,取不到才退回一个 SF Symbol。
    /// - fallbackSymbol: 取不到时画什么。浏览器那几处用 `app.dashed`(读作"这个 App 是谁
    ///   我们还不确定"),已信任那张卡用 `checkmark.seal`(那一格的语义是"信任过",不是"不确定")。
    private static func appIconView(bundleID: String, size: CGFloat,
                                    fallbackSymbol: String) -> some View {
        Group {
            if let icon = AppIconResolver.icon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: fallbackSymbol)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }


    // 本地数据源通过 AppleScript 直接问 Music.app(见 MediaControlClient.swift),这个权限
    // 因此是"核心路径必需、没有就完全看不到歌词",不是"可选、只影响播放进度精度",副标题
    // 特意说清楚这一点,别让人以为不给也无所谓。
    //
    // QQ 音乐/网易云/Spotify 走系统级 MediaRemote,压根不需要这个权限,这张卡整个不出现。
    // 不需要时**不显示**,别改成显示一句"无需额外授权"的确认卡 —— 一张只为了说"这里
    // 没事"而存在的卡片本身就是噪声,占的篇幅跟真正需要处理的那张一样大,反而稀释了页面上
    // 真正要人动手的内容。
    /// 需要「自动化」权限的播放器 —— 一家一行,全部收在这一张卡里。
    ///
    /// 列表来自 `Set<PlaybackPlayer>.playersNeedingAutomation`(含 auto 时按超集算,两家都列)
    /// 再按"这台机器上装了"过滤,判据与理由见那个属性和 `PlayerAutomationPermissions`。
    ///
    /// **别把它收窄成"只选了某一家"**:多选时命中谁就走谁那条 AppleScript 路
    /// (`MediaControlClient.adaptedSnapshot` 只看 bundle id、不看 features.players),
    /// 而 `players` 的默认值就是 `[.auto]` —— 收窄的话默认配置的人在引导里被问过、回头在设置里
    /// **找不到入口**;当时点了拒绝、或更新/重签名之后 TCC 授权失效,就再没有地方能重新授权,
    /// 而读取路径那边只往 OSLog 写一行 `snapshot failed`,界面上一个字都没有。
    @ViewBuilder
    private var permissionCard: some View {
        let targets = automation.visiblePlayers(for: stores.players)
        if !targets.isEmpty {
            SettingsCard {
                // 卡头承担"这是什么权限",每一行只报**哪个播放器 + 什么状态** —— 行标题写成
                // 「Apple Music 自动化」「Spotify 自动化」的话,"自动化"三个字要在卡里重复两遍。
                // 卡头这句是这张卡在设置搜索里的**唯一锚点**(行标题是 `player.displayName`、
                // 不是字面量,扫不到也没法登记),改它要同步改 `SettingsSearchCatalog` 那一条。
                SettingsCardHeader(title: L10n.t("自动化权限"),
                                   help: L10n.t("没有它读不准播放进度，也控制不了播放"))
                ForEach(Array(targets.enumerated()), id: \.element) { index, player in
                    if index > 0 { CardDivider() }
                    SettingsRow(
                        icon: automation.iconName(player),
                        iconTint: automation.iconColor(player),
                        title: player.displayName,
                        // 副标题只留状态本身,"为什么需要它"挪进卡头的「?」——状态是每次扫一眼
                        // 都要读的,而理由只在第一次(或者犹豫要不要授权时)才需要。
                        subtitle: automation.caption(player)
                    ) {
                        if automation.isRequesting(player) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(automation.actionTitle(player)) { automation.handleAction(player) }
                        }
                    }
                    if automation.showsWaitingNote(player) {
                        CardDivider()
                        SettingsNote {
                            PlayerAutomationWaitingNote(timedOut: automation.hasTimedOut(player))
                        }
                    }
                }
            }
            .onAppear { automation.refresh(targets) }
            // 用户可能切去系统设置手动处理,切回来要重新读一次最新状态,并在已经不是
            // notDetermined 时清掉"正在等待"这套 UI,不然状态文字已经变了,下面却还卡在
            // 转圈/超时提示。
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                automation.refresh(targets, clearRequestUI: true)
            }
        }
    }

    /// 「完全磁盘访问」—— 勾了读私有容器的播放器(QQ 音乐 / 网易云音乐 / 酷狗音乐)且装了才出现。
    ///
    /// 列表来自 `Set<PlaybackPlayer>.playersNeedingFullDiskAccess`(含 auto 时按超集算)再按装没装过滤,
    /// 结论只认 collector 发布的状态,见 `FullDiskAccessPermission`。授权是整个 App 一份、几家共用,
    /// 所以只有一行,行标题就是这项权限本身;替哪几家要写在「?」里。
    @ViewBuilder
    private var fullDiskAccessCard: some View {
        let targets = fullDiskAccess.visiblePlayers(for: stores.players)
        if !targets.isEmpty {
            SettingsCard {
                // 行标题是这张卡在设置搜索里的唯一锚点,改它要同步改 `SettingsSearchCatalog`。
                SettingsRow(
                    icon: fullDiskAccess.iconName(targets),
                    iconTint: fullDiskAccess.iconColor(targets),
                    title: L10n.t("完全磁盘访问权限"),
                    subtitle: fullDiskAccess.caption(targets),
                    help: FullDiskAccessGuide.reason(targets)
                ) {
                    EmptyView()
                }
                if fullDiskAccess.grant(targets) != .granted || fullDiskAccess.restartPhase != .idle {
                    CardDivider()
                    SettingsNote {
                        FullDiskAccessGuide(players: targets)
                    }
                }
            }
            .onAppear { fullDiskAccess.refresh() }
            // 状态文件由 collector 写,不会推通知过来;按 mtime 读很便宜,跟这一页的主轮询同频。
            .settingsPolling(every: 2) {
                fullDiskAccess.refresh()
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
                // 只有「启用」,没有「停用」:这个服务停掉之后 App 就是个空壳(读不到播放状态、
                // 不解析歌词、不写缓存),界面上每一处都不再更新,而用户很难把"什么都不动了"跟
                // 自己在设置里点过的一个按钮联系起来。它没有"用户可能想关掉它"的正当场景。
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
                    Button(L10n.t("导出诊断…")) { exportDiagnostics() }
                }
            }
            // 私有通道自检失败时明说。不显示成报错红字:用户无法修复它(只能等上游适配),
            // 说清受影响范围比制造焦虑有用。
            //
            // 受影响范围**不是**"只有 QQ 音乐/网易云"。判据在 `MediaControlClient.fetchSnapshot`
            // 那三条路径上:勾了「自动识别」到 整条路的基座就是 media-control(Apple Music 也在内,
            // AppleScript 只做位置精化);恰好只勾 Apple Music、没勾自动识别 到 纯 AppleScript,
            // 这是**唯一**绕开它的配置;其余组合(QQ 音乐/网易云/Spotify/酷狗/汽水…)一律经它读。
            // 所以文案按"哪一种配置绕开了它"说,不按"哪几个播放器不受影响"说 —— 后者既不准
            // (Spotify 其实也经这条通道),又会随着新增播放器过期。
            if case .unavailable(let message) = stores.mediaControlState {
                CardDivider()
                SettingsNote {
                    Text(L10n.t("系统的媒体信息通道在这台机器上用不了，播放状态会读不到。绕开它的只有一种配置：关掉「自动识别」、只勾 Apple Music；其余配置都要经这条通道读。"))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            // App 本体版本跟打包的 collector 版本对不上(见
            // CollectorServiceManager.bundledCollectorVersion 头注)。只在真查到不一致时才显示这条,
            // 查不出来(nil)时保持沉默,不把"没法判断"说成"有问题"。
            //
            // 文案**不要**写成"建议重新安装 App" —— 版本号是编译期烧进二进制的,重装同一个安装包
            // 一万次也还是同一个版本号,用户照做只会白费力气还更困惑。如实说明:这是打包时的疏漏、
            // 不影响功能、不需要用户做任何事。
            if let mismatch = collectorVersionMismatch {
                CardDivider()
                SettingsNote {
                    Text(L10n.t("这个版本打包时漏了同步后台采集服务的版本号。不影响功能，采集服务的实际代码跟 App 是同一个版本，不需要你做任何处理"))
                    Text("App \(mismatch.appVersion) · \(L10n.t("采集服务")) \(mismatch.collectorVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        // 不能只在 onAppear 读一次。
        //
        // collector 的 job 在 bootout到bootstrap 中途,`launchctl print` 会退出码 0 但输出里
        // 认不出 state 字段 到 解析成 .unknown(见 LaunchdPrintParser:"我读不懂"跟"我知道它
        // 没跑"刻意分开两档)。而 build.sh 的重装顺序恰好制造这个窗口:**先** kickstart App
        // (设置窗口恢复、onAppear 读一次状态)、**再** reload collector 的 job。于是这一次读
        // 正好落在中间态上,之后再没人重读,卡片就永久挂着一个橙色警告和一颗本不该出现的
        // 「启用」按钮 —— 而服务其实一直在跑。
        //
        // 所以要让它自愈:每拍重读一次,外加切回 App 时重读一次。这两件事现在都由侧栏那条健康检查
        // (`PlayerHealthMonitor`,设置窗口看得见时每 2 秒一拍、切回 App 也补查)做,这里只接它发布的
        // 状态 —— 原来页面自己也每 2 秒起一次 `launchctl print`,跟它查的是同一件事。
        .onAppear {
            refreshCollectorState()
            refreshCollectorVersionCheck()
        }
        .onReceive(playerHealth.$collectorState.compactMap { $0 }) { latest in
            if latest != collectorState { collectorState = latest }
        }
    }

    // 「与播放器联动」卡:三项联动各一行,尾部一排播放器图标芯片,点图标勾选 / 取消。
    // 候选 = 选中集合里的具体播放器,选了「自动识别」时五个都可勾
    // (LyrimuseCore.PlayerLinkage.candidates)。按播放器逐个勾选,而不是拿一个布尔盯整个
    // 集合 —— 多选之下"跟哪个绑定"必须答得出来。
    private var linkageCandidates: [PlaybackPlayer] {
        let set = PlayerLinkage.candidates(selectedPlayers: stores.players)
        return PlaybackPlayer.displayOrder.filter { set.contains($0) }
    }

    private var companionCard: some View {
        SettingsCard {
            SettingsCardHeader(
                title: L10n.t("播放器联动"),
                help: L10n.t("每一项都按播放器单独勾选；选了「自动识别」时五个播放器都可勾"))
            CardDivider()
            PlayerLinkageRow(
                icon: "arrow.up.forward.app",
                title: L10n.t("打开 Lyrimuse 时启动"),
                help: L10n.t("Lyrimuse 启动时把勾选的播放器一起打开，已经在跑的不动，也不抢焦点"),
                candidates: linkageCandidates,
                chosen: stores.launchPlayersOnLyrimuseOpen
            ) { AppSettings.shared.launchPlayersOnLyrimuseOpen = $0 }
            CardDivider()
            PlayerLinkageRow(
                icon: "arrow.down.app",
                title: L10n.t("跟随播放器启动"),
                help: L10n.t("检测到播放器打开时自动拉起 Lyrimuse"),
                candidates: linkageCandidates,
                chosen: stores.launchLyrimuseOnPlayers
            ) { chosen in
                FeatureSettingsStore.shared.launchLyrimuseOnPlayers = chosen
                Task { await FeatureSettingsStore.shared.save() }
            }
            CardDivider()
            PlayerLinkageRow(
                icon: "power",
                title: L10n.t("跟随播放器退出"),
                help: L10n.t("勾选的播放器全部退出后，等 5 秒再退出 Lyrimuse；期间任一个重新打开就取消。设置、歌词管理或歌词窗口开着时，等它们关掉再退"),
                candidates: linkageCandidates,
                chosen: stores.quitWithPlayers
            ) { AppSettings.shared.quitWithPlayers = $0 }
        }
    }

    private var collectorStatusCaption: String {
        switch collectorState {
        case .running:
            return L10n.t("运行中")
        case .registeredNotRunning(let code):
            // 装上了却没有进程 —— KeepAlive 的 job 落到这个状态基本就是起不来/崩溃重启
            // 循环。带上退出码,反馈问题时这一个数字就够定位了。
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

    /// 同一时刻最多一次 launchctl 在飞(见 refreshCollectorState)。

    /// 请侧栏那条健康检查立刻重读一次后台采集服务的状态(结果经 `playerHealth.$collectorState` 回来)。
    ///
    /// `CollectorServiceManager.state` 要起一个 `launchctl print` 子进程并 `waitUntilExit`,那边在后台
    /// 线程跑、同一时刻最多一次在飞;结果只在真的变了时才赋给 collectorState(它驱动整张卡片)。
    private func refreshCollectorState() {
        playerHealth.refresh()
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
            AppSettings.shared.collectorServiceEnabled = true
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

    // (12 款菜单栏图标的格子在 `UI/MenuBarIconPicker.swift`。别在这里长回来 —— 同一组格子
    //  两处各画一份,选中态/尺寸迟早对不上。)

    @State private var showExportConfigWarning = false
    @State private var showImportConfigConfirm = false
    @State private var showICloudExportWarning = false
    // iCloud 文件夹里最新的那份配置(没有就是 nil)。只在 .onAppear 查一次 —— 这是文件
    // 系统状态,App 不会主动收到"iCloud 里多了个文件"的通知。
    @State private var iCloudSnapshot: ICloudConfigStore.Snapshot?
    /// 系统「登录项」里被用户关掉了(见 `LoginItemManager.needsApproval`)。
    @State private var loginItemNeedsApproval = false
    @State private var iCloudBusy = false
    @State private var iCloudMessage: String?
    /// 「设置文件」那一行的提示通道(导入失败 / 导出失败 / 清理结果)。
    ///
    /// 单独开一个,不复用 iCloudMessage:那条原来被关在 `if ICloudConfigStore.isAvailable`
    /// 里面,没开 iCloud Drive 的用户连提示通道都没有 —— 而"导出失败"恰恰跟 iCloud 无关
    /// (两处 `try?` 把错误全吞了,失败时界面上什么都不会发生)。
    @State private var configMessage: String?
    /// 「更新备份」写成功后按钮本身要不要变身成打勾的「已保存」。
    ///
    /// 反馈出现在按钮**自己**身上,不是按钮下面淡出一行小灰字 —— 后者出现在视线本来就没在看的
    /// 地方(眼睛/光标此刻都停在按钮上,不在按钮下面那一小条)。图标/文案/1 秒时长照抄"保存
    /// 修改"那颗按钮成功后变身「已保存 ✓」的写法(LyricsManagerView,同一个 App 只该有一种
    /// "保存成功"的样子);这里多一个失效令牌,让它在**别的**动作触发新一轮之前不会被那次
    /// 新的提前打断。
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
            // 副标题砍短:原句 33 字在 900pt 窗口里折行,「台 Mac」三个字孤零零掉到
            // 第二行。这一行只用回答"这页管什么",不用把每一项都点一遍 —— 下面的卡头本来就在点。
            subtitle: L10n.t("菜单栏图标、语言与启动，以及备份搬家")
        ) {
            // **这一页没有预览**:菜单栏就在屏幕顶上,选哪款抬头就看得见,不需要在设置页里
            // 再仿一条。别把仿菜单栏的 MenuBarIconStage 那套加回来。
            //
            // 12 款用写死 2×6 的 Grid,不用 LazyVGrid —— Lazy 容器在窗口不可见时不铺格子,表现是
            // 整块空白。选中款的名字常驻在「菜单栏图标」这一行的行尾,不是只有悬停 tooltip 才报
            // 名字。「菜单栏与 Dock」这张卡排在「语言与启动」前面 —— 它是这一页唯一带画面的一张,
            // 当页首比夹在中间稳;两张卡不合并(语言/开机启动讲 App 怎么跑,Dock/菜单栏图标讲它
            // 在系统 UI 里怎么露面)。
            SettingsCard {
                SettingsCardHeader(title: L10n.t("菜单栏与 Dock"))
                CardDivider()
                // 放在这张卡而不是「菜单栏歌词」那张里:这个图标恰恰是**没有**歌词可显示时才出现的
                // (没在放歌、还没解析出这一句、或者菜单栏歌词整个关掉),跟那边的宽度/滚动设置一件
                // 都不沾;它跟 Dock 那一行才是同类 —— 都在说"这个 App 在系统 UI 里长什么样"。
                //
                // 行尾放所选款的名字,跟「歌词文件夹」行尾放路径 / 歌词库统计块顶行放占用空间是同一种
                // 写法:裸值、次要色、11pt。
                SettingsRow(
                    icon: "menubar.rectangle",
                    title: L10n.t("菜单栏图标")
                ) {
                    Text(settings.menuBarIconStyle.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // 不 insetToText:这一块要在整张卡里居中,空出图标列再居中会让中轴往右偏半个图标列,
                // 见 MenuBarIconPicker.body 的注释。
                SettingsRawRow {
                    // 直接把图标本身摆出来让人挑,不用文字列表 —— 这一项的全部内容就是"长什么样",
                    // 写成一串名字反而要人先在脑子里翻译一遍。
                    MenuBarIconPicker()
                }
                CardDivider()
                // 律动紧跟在图标后面:它改的是上面那枚图标的状态。
                SettingsRow(
                    icon: "figure.dance",
                    title: L10n.t("随播放律动"),
                    help: L10n.t("播放时图标动起来，暂停即静止")
                ) {
                    Toggle("", isOn: $settings.menuBarIconAnimates)
                }
                CardDivider()
                SettingsRow(
                    icon: "macwindow",
                    title: L10n.t("在 Dock 中显示"),
                    help: L10n.t("关闭后只保留菜单栏图标，不占 Dock 位置")
                ) {
                    Toggle("", isOn: $settings.showInDock)
                }
            }

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
                        // 语言名一律用该语言自己的写法(简体中文 / 繁體中文 / English),三档下都不翻译。
                        Text(L10n.t("繁體中文")).tag("zh-hant")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                CardDivider()
                SettingsRow(icon: "power", title: L10n.t("开机启动")) {
                    Toggle("", isOn: $settings.launchAtLoginEnabled)
                }
                if loginItemNeedsApproval {
                    SettingsNote {
                        Text(L10n.t("「系统设置 › 通用 › 登录项」里关掉了 Lyrimuse，要开机启动得在那里重新打开"))
                        Button(L10n.t("打开系统设置")) { LoginItemManager.shared.openSystemSettings() }
                    }
                }
            }
            .onAppear { refreshLoginItemState() }
            // 用户去系统设置里改完切回来,开关和提示当场跟上。
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshLoginItemState()
            }

            // 导入/导出打包 collector 的 config.json(账号 token 原文都在里面)+ features.json +
            // App 自己的偏好设置,合并成一份 JSON。刻意跟"导出诊断信息"反着来:那个绝不能带任何
            // token(设计给贴进公开 issue),这个就是要把 token 原样带走(设计给换新机器用)——
            // 两处的用户提示因此也刻意写成相反的语气。
            //
            // 说明文字放在**各自行下面的副标题**里,不写成一整段 Section footer:每条只讲它自己
            // 那个按钮会发生什么,尤其"会覆盖""无法撤销"这类后果要紧贴着对应的按钮。
            SettingsCard {
                // 这张卡是两行(目的地 / 文件),卡级动作上提到卡头,配置文件夹在「关于」。
                //
                // 别再摊回"iCloud 备份 / 导出设置 / 导入设置 / 配置文件夹"四行平铺 —— 这四行不是
                // 同一类东西:第一行是个有状态的目的地(有快照、时间戳、来源设备、能换绑目录),二三行
                // 是围绕"文件"的一对互逆动作,第四行压根跟备份没有因果关系(它是给 dotfiles/chezmoi
                // 用户看活配置的)。四行等高平铺时唯一的层级信号只有"第一行副标题里有时间戳",读者
                // 没法看出它们不是并列关系。
                //
                // 卡名用文档里自己的说法(docs/features/14 §4「备份与迁移」)——「设置备份」既没盖住
                // dotfiles 那条路,也没盖住一起被备份的歌词库。
                SettingsCardHeader(title: L10n.t("备份与迁移")) {
                    // 卡级动作(换绑目录)上提到卡头 —— 这是本仓库既有的位置(见「歌词来源」卡头那颗
                    // 「测试」按钮)。别把它们藏回行尾的 ellipsis.circle 菜单:那个 ⋯ 会是整个设置页
                    // **唯一**的一个,别处的无边框 Menu 都带文字标签。
                    Menu {
                        Button(L10n.t("更换备份文件夹…")) { chooseBackupFolder() }
                        if ICloudConfigStore.usingCustomFolder {
                            Button(L10n.t("改回 iCloud")) {
                                ICloudConfigStore.setCustomFolder(nil)
                                iCloudSnapshot = ICloudConfigStore.latestSnapshot()
                            }
                        }
                        // 别加回「只保留最近 N 份」这类手动清理项:它是给"每存一次就新增一对文件、
                        // 永不删旧"这个缺陷贴的创可贴,正确的修法是写入时自动只留最近几份(见「存到
                        // iCloud」那个 alert 里的说明)。手动项等于要求用户记得定期来打扫自己的备份,
                        // 而这个菜单本来就藏在卡头,不点开根本不知道有多少份在堆。
                        Divider()
                        // 必须写清是**哪个**文件夹。这里和下面「配置文件夹」那行都叫「在访达中
                        // 显示」的话,一字不差却开两个不同目录(备份目录 vs ~/.config/lyrimuse 这个
                        // **活配置**目录),两个都没有二次确认 —— 用户把打开的活配置目录当成备份去
                        // 拷/删,丢的是正在用的配置。
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
                // 整行**不能**因为 iCloud Drive 关掉/自选目录掉线就消失(别写成
                // `if ICloudConfigStore.isAvailable { ... }`)—— 外置盘一拔整行没了,连菜单里的
                // 「改回 iCloud」也跟着没了,用户被锁死而且没有任何解释。行照常在,按钮禁用,
                // 副标题说明原因。
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
                        // 只给**这一颗**按钮定宽。本仓库的风格就是按钮宽度参差
                        // (SettingsDesignSystem 里没有任何 minWidth,定宽只用在滑杆和数字
                        // 读数上),不该全局统一。但这颗的文字会**原地变化**
                        // (存到 iCloud / 存一份 / 更新备份 / 已保存),每变一次整行跳一下 ——
                        // 跟 ShortcutRecorder 用 max(width,150) 解决的是同一个问题。
                        .frame(minWidth: 88)
                        .disabled(!ICloudConfigStore.isAvailable)
                        if iCloudSnapshot != nil {
                            // 这颗叫「恢复这份」不叫「导入…」:它直接恢复**副标题里说的那一份**
                            // (不开面板),而下面「设置文件」那行的「导入…」是开文件选择器;两条路的
                            // 文件面板默认目录还是同一个 iCloud 文件夹,同名会更难分辨。
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
                // 第二行:导出/导入合成一行 —— 它们是同一件事(把配置存成文件 / 从文件读回来)的
                // 两个方向,分成两行只是把一对互逆动作拆开摆,还各自挂一个点开才看得见的 ⓘ。
                //
                // 后果写进**副标题**而不是 help 气泡。本仓库的规矩写得很明确
                // (SettingsDesignSystem「两者只用其一」、SettingsView 里「副标题**常显**…藏在
                // tooltip 里等于没说」),而 HelpButton 是**点击**才弹、不是悬停。既有先例也都这么做:
                // 「导出诊断信息」把"不含 token"放副标题、「清除所有设置」把"无法撤销"放副标题。
                // 含凭证、覆盖一切并重启、含账号凭据这三条都是最该常显的事实,不许塞进气泡。
                SettingsRow(
                    icon: "doc.badge.gearshape",
                    title: L10n.t("设置文件"),
                    // 副标题和气泡**分工,不重复说**:副标题只留"点之前必须知道的后果",气泡只补
                    // 副标题装不下的**细节**。两边把同样三件事各讲一遍的话,读的人点开只是把刚看过的
                    // 话再读一遍。
                    //
                    // 副标题不能说"含账号凭证与歌词库":歌词库根本不在这个文件里 —— 它是单独的第二
                    // 个文件,而这正是用户最容易漏拷的东西。
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
            // 这个 alert 必须带 message 说清风险:存到 iCloud 才是把明文 token 推上 Apple
            // 服务器和你所有设备的那一步(write 设的 0600 权限过了同步就不作数),风险比本地
            // 导出更高,文案不能反而更轻。
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
                        // **这里不做任何自动清理,备份想攒多少份就多少份**。
                        //
                        // 每点一次都新写一对文件(配置 4KB + 歌词包 ~8MB),没有东西会删旧的(攒到 9 份
                        // 配置 + 8 份歌词包 ≈ 55MB)。这是刻意的:那是用户的磁盘和他的备份,「攒着」本身
                        // 就是他要的行为。
                        //
                        // 所以别再"顺手"加回来:不加定时清理、不加写入时清理、不加"超过 N 份就提醒"。
                        // 真要省空间由用户自己去备份文件夹删(卡头菜单里有「打开备份文件夹」)。
                        //
                        // 写成功的反馈由按钮自己变身「已保存」承担,写法与理由见 iCloudJustSaved 声明处注释。
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
                        // 这两处**不要**写成裸 `try?`:盘满、没有写权限、目标被别的进程占着时会完全
                        // 静默,界面上什么都不会发生,用户以为导出成功了。
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
                                // 必须把"旁边还有第二个文件"说出来:静默写的话,用户只会拷走自己在
                                // 面板里选中的那一个 —— 到新机器导入时找不到兄弟包,按设计"一个歌词文件
                                // 都不动",于是歌词**静默全丢**。
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
                            // `importData` 的返回值**必须检查**:它是 `async -> Bool`,顶层 JSON
                            // 解析失败时 return false(ConfigPortability.swift:254)。丢掉返回值再无条件
                            // restartApp() 的话,用户选错一个 .json(面板只过滤扩展名、不校验是不是我们的
                            // 导出包)的结果就是 **App 退出重启、设置一个字没改、界面上零提示**,唯一能
                            // 得出的结论是"导入把我的设置弄坏了"。
                            //
                            // 失败就地报错、**不重启**。歌词恢复和 adoptFolder 也一并跳过:配置都没写进去,
                            // 单独铺歌词/改备份目录只会留下一个半吊子状态。
                            guard await ConfigPortability.importData(data) else {
                                configMessage = L10n.t("导入失败：这个文件不是 Lyrimuse 的设置备份，或者已经损坏。当前设置没有被改动")
                                return
                            }
                            // 歌词必须排在 importData **之后**:歌词目录是
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
                // 确认框里要**讲对象**,不能只讲后果 —— 用户得看得出正要导入的是哪一份。
                // 导出时间和机器名就在包里(ConfigPortability 写的),iCloud 那一行也一直渲染成
                // "…· 来自 DJ-chenyuhao";同一份信息在行里有、在真正要拍下决定的确认框里反而
                // 没有,是反的。
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

            // 「封面」卡不在这一页:它只有「动态封面」一项,而那一项只管歌词窗口那张封面卡,
            // 归 设置 › 歌词显示 › 歌词窗口(AppearanceSettingsTab 的 .lyricsWindow 段)。

            // 单独一张卡,不跟上面的备份/恢复挤在一起 —— 这是本页唯一不可撤销的动作。
            // 「歌词显示」页的「恢复默认文字与配色」也是这么单独放的,同类动作按同一套处理。
            SettingsCard {
                SettingsRow(
                    icon: "trash",
                    title: L10n.t("清除全部设置"),
                    subtitle: L10n.t("本机设置，无法撤销")
                ) {
                    DestructiveButton(title: L10n.t("清除…")) { showClearConfigWarning = true }
                }
            }
            // 这条 alert 跟着按钮一起搬过来。留在上面那张卡上也能弹(alert 由 @State 驱动,
            // 锚点只要还在层级里就行),但按钮和它的确认框分居两张卡纯属给人添乱。
            .alert(L10n.t("确定要清除全部设置吗？"), isPresented: $showClearConfigWarning) {
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

    /// 开机启动开关与系统「登录项」对账,并决定要不要摆「去系统设置里打开」那句提示。
    private func refreshLoginItemState() {
        settings.syncLaunchAtLoginFromSystem()
        loginItemNeedsApproval = LoginItemManager.shared.needsApproval
    }

    /// 「从文件导入…」:开面板选一个配置包。内容抽成函数而不是内联在按钮闭包里,那一行
    /// 只剩一句调用,也方便在这里加校验。
    ///
    /// 面板只能按扩展名过滤(`.json`),挡不住"选了个别的 json"。所以选完**先自己验一遍**
    /// 再弹确认框 —— 只在确认后 guard 住的话,体验仍然是"点了确认才报错",甚至要走完
    /// "确认 到 App 重启 到 发现什么都没变"才知道选错了。
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
            // 新机器上这份文件很可能还只是个未下载的占位符,readOutcome 会先触发下载再等它到位。
            // 分档提示:超时那档下载是**真的已经在跑**了,叫用户再点一次才有意义;而"连下载都没
            // 发起"是另一回事,不能也让他干等 —— 两种不能压成同一句话,判据见 ICloudFileReadiness。
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

// 「快捷键」分类:6 个悬浮歌词相关快捷键 + 1 个步长调节 + 3 个播放控制快捷键,
// 内容量比「通用」其它几块加起来还多,所以是独立分类。
private struct ShortcutsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // "至少需要搭配 ⌘/⌥/⌃ 中一个"这条限制对本页每一个录制框都成立,所以写在页面说明里
        // 而不是某一组的 footer(放 footer 只挨着上面那一组,下面「播放控制」那组的录制框同样
        // 受限却看不到这句话)。规则本身照抄 KeyboardShortcuts 库自带 Recorder 的行为(见
        // ShortcutRecorder.swift 里 handle(_:) 的注释),不是这个项目额外加的 —— 但它只会
        // "响一声"、没有任何文字提示,必须写出来。
        SettingsPage(
            title: L10n.t("快捷键"),
            subtitle: L10n.t("在任何 App 里都能触发，需搭配 ⌘ ⌥ ⌃ 之一")
        ) {
            // 四张卡按语义分:「切换显示形态」和「打开某扇窗」是两类动作,16 项挤一张卡里
            // 会有十来行,找不到自己要的那一条。
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
                // 别再给这一行加副标题(比如"总开关;具体给哪几种文字标注仍在「歌词显示」里
                // 分别设置")—— 解释性文案在这一页是被明确否掉的,同「全局时间轴偏移」那一行。
                SettingsRow(icon: "textformat.abc", title: L10n.t("显示/隐藏罗马音")) {
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
                    title: L10n.t("搜索歌词")
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
                    title: L10n.t("歌词提前")
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
                    title: L10n.t("歌词偏移归零")
                ) {
                    ShortcutRecorderControl(name: .lyricsOffsetResetHotkey)
                }
                CardDivider()
                // 每次调整的步长——跟菜单栏"歌词时间轴"共用同一个值,这里改了菜单里的按钮文案/
                // 快捷键的实际调整量会一起变。0.05~2s 区间对"手动校准"这个场景够用,不需要再大
                // 或者再细。
                //
                // 数值必须作为**独立内容**摆在 Stepper 外面,不能塞进 Stepper 的 label:
                // SettingsRow/SettingsSubRow 对尾部控件统一套了 .labelsHidden()(用来藏掉
                // Toggle/Picker 自带的、会跟行标题重复的那份标签),而 Stepper 恰恰是把数值
                // 画在 label 里的——放进去会被一并藏掉,界面上只剩一对光秃秃的上下箭头,
                // 完全看不出当前步长是多少。
                //
                // 用完整的 SettingsRow 而不是 SettingsSubRow:只有"每次调整"四个字说不清调的是
                // 什么、影响哪里,配上图标和副标题才自解释。
                SettingsRow(
                    icon: "timer",
                    title: L10n.t("步长"),
                    subtitle: L10n.t("每按一次调整的幅度")
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

// 「关于」分类。
//
// 页头承担「身份 + 首要动作」:图标、名字、可点击拷贝的版本胶囊(反馈问题时最常被问的就是
// "什么版本、什么芯片、什么系统")、一句 tagline、两颗胶囊按钮(咖啡、GitHub 带 star 数)和
// 那句求 star 的话 —— 不用滚动就能到达这一页最常用的两个动作。
//
// 卡片按意图分四张并加 SettingsCardHeader:更新 / 反馈与社区 / 许可与版权 / 诊断与数据。
// 每张两三行,标题行 12pt 次要色把层级拉开,跟别的页同一套规则;每一行都有副标题,不点进去
// 也知道会到哪里。 别摊回一张八行的长卡 —— 更新开关、外链、法律说明三种不相干的东西混在
// 一起、没有任何分组标签,读者只能从上往下扫。
/// 页头 GitHub 胶囊按钮里的 star 数。
///
/// **不做 "1.2k" 那种缩写**:GitHub 网页上缩写是因为它要在一排徽章里挤位置,这里一整行
/// 只有这一个数字,写全反而更可信 —— 而且缩写会把 1200 和 1249 显示成同一个数,那正是这个
/// 角标唯一要传达的信息。真涨到五位数时它占的宽度也只有 ~40pt,这一行的横向预算够
/// (整行 600pt,标题列常见值不到 240pt)。
///
/// `.fixedSize()` 不是装饰:`SettingsRow` 的 HStack 里标题列 / Spacer / 尾部插槽是三个
/// 可伸缩成员,SwiftUI **均分**剩余宽度而不是"先按理想宽度发",尾部太挤时自绘内容会被压到
/// 下限(见 04 章「设计决策」第 15 条,英文标签被压成「Left-Ali…」那次)。数字被压掉一位
/// 比不显示更糟,所以先钉死它的理想宽度。
private struct GitHubStarsBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 10))
            Text(String(count))
                .font(.system(size: 12, weight: .medium))
                // 数字会变(每次刷新可能 +1),等宽数字避免那一下宽度抖动。
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(L10n.t("GitHub Star 数"))
        // 两个子视图(图标 + 数字)对 VoiceOver 是一件事:一个星标图标单独念出来没有意义。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("GitHub Star 数"))
        .accessibilityValue(String(count))
    }
}

private struct AboutSettingsTab: View {
    // 只为更新开关和 star 数订阅 —— 这一页其余内容都是静态的。两个都是单例、不是 @StateObject:
    // 离开设置页再回来不该重读缓存、更不该重复发请求。
    @ObservedObject private var updater = SparkleUpdaterManager.shared
    @ObservedObject private var githubStars = GitHubStarsService.shared
    /// 只为「接收测试版更新」那一个开关订阅 AppSettings —— 这一页其余内容不读它。
    @ObservedObject private var settings = AppSettings.shared
    /// 版本胶囊刚被点过(版本信息已在剪贴板)的短暂反馈态,1.6 秒后自动复原。
    @State private var versionCopied = false

    // CFBundleIconFile 指向 AppIcon.icns(build.sh 生成的 .app 包本身自带),直接读系统认的这份
    // "当前 App 图标",不用再手动拼一遍 Bundle 里的文件路径。
    private var appIcon: NSImage { NSApplication.shared.applicationIconImage }
    private var versionString: String { SparkleUpdaterManager.appVersionString }

    var body: some View {
        // 页头不走 SettingsPage 的 title/subtitle/heroImage 三件套:那套只能摆"图 + 标题 + 一句话",
        // 这里还要塞版本胶囊、两颗按钮和一行小字,所以用自定义页头容器(跟账号页同一个)。
        SettingsPageCustomHeader {
            hero
        } content: {
            // 无 Sparkle 构建里没有可用的更新动作,卡片整块不画(见 SparkleUpdaterManager 的 #else 分支)。
            #if canImport(Sparkle)
            updateCard
            #endif
            communityCard
            legalCard
            diagnosticsCard
            Text("© 2026 Yudaotor · GPL-3.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        // SwiftUI 有时不会在语言切换后重新执行某些嵌套内容的 body(取决于该内容自己的
        // 存储属性有没有变,而非父视图是否重新渲染,详见 AccountLinkingTab.swift 里
        // DestinationStatus.label 的注释)。用 .id(L10n.current) 把整页的身份跟当前语言
        // 绑死,语言一变就强制整体重新构造,不需要逐个排查哪里在跳过刷新。
        .id(L10n.current)
        // star 数:进这一页时**问一次要不要更新**,真发不发由 `GitHubStars.shouldRefresh`
        // 决定(6 小时 TTL + 失败退避)。放在 .task 而不是 App 启动时:这个数字只在这一页
        // 出现,没人看的时候不该占用户的网络。
        // 挂在 `.id(L10n.current)` **之后**:挂在前面的话切语言会重建视图身份、把这个
        // task 连同它的请求一起取消再重来,白发一次(这一页每个 .task 都要守这条)。
        .task { await githubStars.refreshIfStale() }
    }

    // MARK: 页头

    private var hero: some View {
        VStack(spacing: 8) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)
                // 图标本身带圆角和描边,这里只给一层软阴影让它从底色上"抬起来";不加发光 / 渐变底 ——
                // 图标的粉色已经够跳,再铺一层就腻了。
                .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                .padding(.bottom, 6)
            // 正式版 "Lyrimuse",Dev 构建 "Lyrimuse Dev"(图标上另有角标)——两个并排跑时靠这里认。
            Text(LyrimuseIdentity.displayName)
                .font(.system(size: 24, weight: .bold))
            versionChip
            Text(L10n.t("Lyric × Muse——把你的歌词交给音乐女神吧"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            HStack(spacing: 10) {
                // 落地页(微信/支付宝收款码)是独立的通用小仓库 Yudaotor/donate,托管在 GitHub Pages 上,
                // 不跟 Lyrimuse 这一个项目绑定,后续其它项目也能复用 —— 这里只是一个外链按钮。
                // 改版前它悬在卡片列底部、要滚到底才看得到;现在跟 GitHub 并排放页头,是这一页的首要动作。
                Button {
                    NSWorkspace.shared.open(URL(string: "https://yudaotor.github.io/donate/")!)
                } label: {
                    Label(L10n.t("请作者喝杯咖啡"), systemImage: "cup.and.saucer.fill")
                }
                .settingsProminentGlassButton(tint: .orange)
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse")!)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("GitHub")
                        // 取不到就整个不画(nil 而不是 0,理由见 GitHubStarsService 头注):没网的机器上
                        // 这颗按钮就是干净的「GitHub」,不会多出一个转圈或者感叹号。
                        if let stars = githubStars.starCount {
                            GitHubStarsBadge(count: stars)
                        }
                    }
                }
                .settingsGlassButtons()
            }
            .padding(.top, 8)
            // 这一行是唯一一处"求 star"的地方,所以常显而不是收进 help 气泡 —— 藏进悬停提示就没人
            // 会看到了。前半句用"鼓励"不用"支持":末尾已经有"谢谢支持",两个"支持"挤在同一行里撞词。
            Text(L10n.t("开源免费，你的 ⭐ 是最大的鼓励，谢谢支持"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        // 撑满卡片列的宽度,装饰层才铺得到两侧(否则 background 只有居中那一列文字那么宽)。
        .frame(maxWidth: .infinity)
        // 两侧的柔光和漂浮音符。纯装饰:不参与布局、不吃点击、减弱动态效果时静止,细节见
        // AboutHeroBackdrop 头注。
        .background { AboutHeroBackdrop() }
    }

    /// 「版本 1.4.0 · Apple Silicon」胶囊。点一下把完整版本信息拷进剪贴板 —— 反馈问题时最常被问到的
    /// 三样(App 版本、芯片架构、系统版本)一次带齐;1.6 秒内显示「已复制版本信息」再复原。
    private var versionChip: some View {
        Button {
            copyVersionInfo()
        } label: {
            HStack(spacing: 6) {
                if versionCopied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L10n.t("已拷贝版本信息"))
                } else {
                    Text(String(format: L10n.t("版本 %@"), versionString))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(Self.architectureName)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // 跟卡片同一套"低透明度填充 + 发丝描边"(见 settingsCardBackground 的理由):纯填充在浅色底上
            // 几乎看不出边界。
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(L10n.t("点击拷贝版本信息，反馈问题时贴上"))
        .animation(.easeInOut(duration: 0.15), value: versionCopied)
    }

    /// 芯片架构的产品名(不本地化:Apple 自己的界面里这两个词也不翻)。universal 包在两种机器上跑的是
    /// 各自原生那一半,所以编译期判断就是运行期事实。
    private static var architectureName: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }

    private func copyVersionInfo() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let text = "Lyrimuse \(versionString) (\(Self.architectureName)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        versionCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            versionCopied = false
        }
    }

    // MARK: 卡片

    /// 「更新」卡只剩一行入口:检查 / 下载 / 安装的全部界面搬去了「软件更新」页
    /// (Settings/SoftwareUpdatePage.swift,仿系统设置那页),这里像系统设置「通用 › 软件更新」那样只留一行
    /// 带当前状态的入口;副标题仍说「有新版本 X / 上次检查」。
    private var updateCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("更新"))
            CardDivider()
            SettingsRow(icon: "arrow.triangle.2.circlepath", title: L10n.t("软件更新"), subtitle: updateSubtitle) {
                Button(L10n.t("打开")) {
                    AppActions.shared.requestSettings(.softwareUpdate)
                }
            }
        }
    }

    /// 「检查更新」那一行的副标题:已经查到新版本就说新版本(文案跟菜单栏面板底栏那一格同一套);
    /// 否则说上次什么时候查过;从没查过就直说。
    private var updateSubtitle: String {
        if let update = updater.shownItem {
            // 两个 L10n.t 分开写:三目塞进 L10n.t 里,文案守卫(parity 脚本 / selftest)扫不到字面量。
            return String(format: update.downloaded ? L10n.t("%@ 已下载，点击安装") : L10n.t("有新版本 %@"),
                          update.version)
        }
        guard let date = updater.lastUpdateCheckDate else { return L10n.t("还没有检查过更新") }
        let formatter = DateFormatter()
        // 跟界面语言走,不跟系统 Locale(理由见 L10n.locale 的注释)。
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return String(format: L10n.t("上次检查：%@"), formatter.string(from: date))
    }

    private var communityCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("反馈与社区"))
            CardDivider()
            SettingsRow(
                icon: "exclamationmark.bubble",
                title: L10n.t("反馈问题"),
                subtitle: L10n.t("GitHub Issues")
            ) {
                Button(L10n.t("前往")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse/issues")!)
                }
            }
            CardDivider()
            // 跟上面"反馈问题"(Issues,追踪 bug 修复状态)分开:这里收想法/新功能建议,走 GitHub
            // Discussions 的 Ideas 分类。选它而不是另起一套表单/第三方服务:零额外基建(仓库自带),
            // 自带点赞投票和评论,还能让同一个想法别被重复提好几遍。
            SettingsRow(
                icon: "lightbulb",
                title: L10n.t("想法与建议"),
                subtitle: L10n.t("GitHub Discussions")
            ) {
                Button(L10n.t("前往")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Yudaotor/lyrimuse/discussions/categories/ideas")!)
                }
            }
        }
    }

    private var legalCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("许可与版权"))
            CardDivider()
            // 正文只在 README 维护(见 LegalNotices / LegalNoticeLinks 头注),这里只放入口,不带
            // 副标题 —— 版权声明是点进去看的东西,不该常驻在设置行上。
            SettingsRow(
                icon: "doc.text",
                title: L10n.t("版权说明")
            ) {
                Button(L10n.t("打开")) { LegalNotices.openUsageNotice() }
            }
            CardDivider()
            // THIRD_PARTY_LICENSES 一直随包分发(build.sh 拷进 Contents/Resources/),但此前 App 里
            // 没有任何入口能打开它 —— 分发条款要求"随附",随附了却没人找得到等于没附。
            SettingsRow(
                icon: "checkmark.seal",
                title: L10n.t("第三方许可"),
                subtitle: L10n.t("开源组件与词典")
            ) {
                Button(L10n.t("打开")) { LegalNotices.openThirdPartyLicenses() }
            }
            CardDivider()
            SettingsRow(
                icon: "scroll",
                title: L10n.t("开源许可证"),
                subtitle: L10n.t("GPL-3.0")
            ) {
                Button(L10n.t("打开")) { LegalNotices.openLicense() }
            }
        }
    }

    private var diagnosticsCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("诊断与数据"))
            CardDivider()
            // collector 日志一直写得比较完整,但 App 自己的日志全在系统统一日志里,普通人不会用
            // Console.app 去查。这里一键把两边日志+关键状态(权限/常驻服务/各功能是否已配置,不含任何
            // token 原始值)汇总成一份文本存到桌面,方便贴进 issue 或者发给开发者。
            SettingsRow(
                icon: "doc.text.magnifyingglass",
                title: L10n.t("导出诊断"),
                subtitle: L10n.t("不含账号与密钥")
            ) {
                Button(L10n.t("导出…")) {
                    DiagnosticsExporter.exportInteractively()
                }
            }
            CardDivider()
            // 这一行**不是备份手段** —— 它是给拿 dotfiles/chezmoi 管机器的人直接看活配置的入口,
            // 跟"备份/恢复"没有因果关系,所以不放进「备份与迁移」那张卡。放过去的直接后果是:它的
            // 按钮会跟备份行菜单里那个一字不差地都叫「在访达中显示」,却打开**两个不同目录**(备份
            // 目录 vs 这个活配置目录),两个都没有二次确认 —— 用户把活配置当备份去拷/删就出事。
            // 跟「导出诊断信息」放一起更合适:都是"给要自己动手的人看内部状态"。
            //
            // 副标题里"外观和快捷键不在里面"这句**必须常显**,不能收进 help 气泡:它们存在
            // UserDefaults,只拷这个文件夹会**静默**丢掉,是这条路子最容易踩的坑。help 只留副标题里
            // 没有的两件事:含凭据别外发、完整搬家走哪个功能。
            SettingsRow(
                icon: "folder",
                title: L10n.t("配置文件夹"),
                // 路径按变体显示(正式 ~/.config/lyrimuse,Dev ~/.config/lyrimuse-dev),别让 Dev 的用户对着一个错的路径找文件。
                subtitle: String(format: L10n.t("%@，纯文本可直接编辑；外观与快捷键不在里面（它们在 UserDefaults）"),
                                 "~/.config/" + LyrimuseIdentity.configDirName),
                help: L10n.t("含账号凭据，不要发给别人；要连外观、快捷键一起搬走，用「备份与迁移」")
            ) {
                Button(L10n.t("打开配置文件夹")) {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigPortability.configFolderURL])
                }
            }
        }
    }
}


/// 设置窗口的 NSWindow 收尾配置:让它能被拖大、能最小化。
///
/// SwiftUI 给 Settings scene 的 styleMask 里**没有** .resizable(32771 =
/// titled | closable | fullSizeContentView),所以这个窗口原本一格也拉不动,SettingsView
/// 上声明的 idealHeight 只决定它开出来多大。而「歌词显示」页顶上钉着 205pt 的固定头部,
/// 窗口拉不高的话滚动区就一直很憋屈。
///
/// 同一个 32771 里也没有 .miniaturizable —— 黄灯是灰的,点不动。那是苹果给 Settings scene
/// 定的默认,系统「设置」自己也这样;但这一页很长、内容也不是"改完就关"的一次性面板
/// (Last.fm 统计、歌词管理入口都在里面),留着能收起来更顺手,所以一并开了。收起来之后跟
/// 普通窗口一样在 Dock 右侧那段可以点回来,不受这个 App 是否显示 Dock 图标影响。
///
/// scene 修饰符 .windowResizability(.contentMinSize) 对 Settings scene 无效(加上之后
/// styleMask 纹丝不动),只能在 NSWindow 这一层开。缩放下限仍由 SettingsView 上声明的
/// minWidth/minHeight 兜着。
///
/// 这里**只**动 styleMask。别顺手改 collectionBehavior(.auxiliary / .fullScreenNone)
/// 或开 isMovableByWindowBackground —— "设置窗口拖不到另一块屏"跟这个窗口无关(全屏 Space
/// 本来就不接受任何窗口拖入,换别的 App 一样进不去),那些改动解决不了任何问题,留着只会
/// 给后来的人埋假线索。
struct SettingsWindowConfigurator: NSViewRepresentable {
    /// 顺带把窗口交给它盯可见性(预览停表用)。跟 styleMask 无关,只是这里是唯一拿得到 NSWindow 的地方。
    let surface: SettingsWindowSurface

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 视图刚建好时还没挂进窗口,拿不到 window,推迟到下一个 runloop。
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            surface.attach(window)
            window.styleMask.insert([.resizable, .miniaturizable])
            // `Settings` 场景默认给窗口的是 `.preference` 样式 —— AppKit 对它的定义就是
            // 「标题独占一行、工具栏项整体居中」,于是详情列最左那对前进/后退键被顶到了
            // 正中(实测截图)。`.unified` 让标题回到侧栏右边、跟工具栏项同一行,
            // `.navigation` 那一组才落在详情列的最左端,也就是系统「系统设置」那对键的位置。
            //
            // 为什么必须写 NSWindow、不能用 SwiftUI 的 `.windowToolbarStyle(.unified)`:
            // 那个 Scene 修饰符对 `Settings` 场景**无效**(加上之后版面一点没变,实测过一轮
            // 装机截图)。也不是 placement 判错了 —— 同一套 NavigationSplitView + 同一个
            // `.navigation`,放进 `WindowGroup`(默认样式与 `.expanded` 都试过)本来就落在最左;
            // 离线探针窗口把五种 placement 并排摆过一遍,`.navigation` 确实是最左那一档。
            window.toolbarStyle = .unified
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
