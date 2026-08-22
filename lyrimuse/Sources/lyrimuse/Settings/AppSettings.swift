import Foundation
import LyrimuseCore
import SwiftUI
import AppKit

// 灵动岛卡片的四种视觉风格。displayName/fill(alpha 相关的具体 ShapeStyle)定义在
// NotchLyricsView.swift(跟灵动岛卡片本身的 UI 强相关,不适合放在这个纯设置文件里),
// 这里只负责持久化用的 rawValue。
//
// coverArt(2026-08-02 新增,"跟随封面")——背景铺当前曲目封面模糊放大+压暗,效果跟
// "歌词窗口"(LyricsWindowView.artworkBackground)完全一致,只是缩小到灵动岛胶囊尺寸。
// 没有封面数据(还没解析出来/这首歌本来就没有封面)时退回 darkGradient 的固定渐变,
// 不会露出空白背景,具体判断逻辑在 NotchLyricsView.backgroundLayer。
enum NotchCardStyle: String, Codable, Hashable, CaseIterable {
    case solidBlack
    case frostedGlass
    case darkGradient
    case coverArt
}

// 菜单栏歌词那一格怎么占位。两种模式**只在这一句比设定宽度短时**才有区别 ——
// 装不下的句子两边一模一样:占满设定宽度、横向滚动。
//
// fixed(2026-08-17 起的默认):短句也占满设定宽度,右边空一块。好处是这一项的
// footprint 恒定,换句时右边其它 App 的图标不会被顶得左右晃(用户反馈"动来动去,
// 观感不太好",当时是直接写死成这个行为的)。
//
// adaptive:短句按自己的宽度占位,菜单栏项跟着缩短,不占用不需要的空间 —— 代价正是
// 上面那条:长短句来回切会伸缩。菜单栏图标本来就多的人更在意这个。
enum MenuBarLyricsWidthMode: String, Codable, Hashable, CaseIterable {
    case fixed
    case adaptive
}

// UserDefaults 支撑的设置存储。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let preferWordLevelKaraoke = "np:preferWordLevelKaraoke"
        static let lyricsChineseVariant = "np:lyricsChineseVariant"
        static let hasSeenChineseLyrics = "np:hasSeenChineseLyrics"
        static let showRomanization = "np:showRomanization"
        static let romanizationScripts = "np:romanizationScripts"
        static let showTranslation = "np:showTranslation"
        static let launchAtLoginEnabled = "np:launchAtLoginEnabled"
        static let launchMusicOnLyrimuseOpen = "np:launchMusicOnLyrimuseOpen"
        static let collectorServiceEnabled = "np:collectorServiceEnabled"
        static let showInDock = "np:showInDock"
        static let showNextLinePreview = "np:showNextLinePreview"
        static let showLyricsInMenuBar = "np:showLyricsInMenuBar"
        static let menuBarLyricsMaxChars = "np:menuBarLyricsMaxChars"
        static let menuBarLyricsWidth = "np:menuBarLyricsMaxWidth"
        static let menuBarLyricsWidthMode = "np:menuBarLyricsWidthMode"
        static let menuBarLyricsKaraoke = "np:menuBarLyricsKaraoke"
        static let menuBarLyricsTextColorHex = "np:menuBarLyricsTextColorHex"
        static let menuBarLyricsFillColorHex = "np:menuBarLyricsFillColorHex"
        static let menuBarIconStyle = "np:menuBarIconStyle"
        static let menuBarIconAnimates = "np:menuBarIconAnimates"
        static let lyricsOffsetStepMs = "np:lyricsOffsetStepMs"
        static let textStrokeEnabled = "np:textStrokeEnabled"
        static let textStrokeColorHex = "np:textStrokeColorHex"
        static let fontFamilyName = "np:fontFamilyName"
        static let fontSize = "np:fontSize"
        static let overlayWidth = "np:overlayWidth"
        static let notchContentWidth = "np:notchContentWidth"
        static let foregroundColorHex = "np:foregroundColorHex"
        static let backgroundColorHex = "np:backgroundColorHex"
        // "跟随封面"——桌面悬浮歌词的前景色改用当前曲目封面算出的动态高亮色,见
        // PlaybackCoordinator.displayForegroundColor。跟 foregroundColorHex 是独立的
        // 两个字段:开着这个模式时 foregroundColorHex 仍然保留、当"没有封面数据时的
        // 备用色"用,不会被覆盖/清空。
        static let followsCoverArt = "np:followsCoverArt"
        static let lockPosition = "np:lockPosition"
        static let hideDuringScreenCapture = "np:hideDuringScreenCapture"
        static let hideWhenNotPlaying = "np:hideWhenNotPlaying"
        // 跟 L10n.swift 里的 languageOverrideKey 必须是同一个字符串——那边只读、这里
        // 只写(负责持久化+驱动"通用"tab 的语言 Picker),两处各自独立实现,不要互相
        // import,理由见 L10n.swift 顶部注释(L10n 不依赖 @MainActor 的 AppSettings)。
        static let appLanguage = "np:appLanguage"
        static let hasShownAutomationOnboarding = "np:hasShownAutomationOnboarding" // 已废弃,只在 init() 里读一次做迁移
        static let hasCompletedOnboarding = "np:hasCompletedOnboarding"
        static let hasOfferedICloudImport = "np:hasOfferedICloudImport"
        static let overlayStyle = "np:overlayStyle" // 已废弃,只在 init() 里读一次做迁移
        static let classicOverlayEnabled = "np:classicOverlayEnabled"
        static let notchOverlayEnabled = "np:notchOverlayEnabled"
        static let notchCardStyle = "np:notchCardStyle"
        static let notchScreenID = "np:notchScreenID"
        static let notchAllScreens = "np:notchAllScreens"
        // 2026-08-05 之前,"这种悬浮歌词要不要显示"这一件事有**两份**独立持久化:上面这两个
        // {classic,notch}OverlayEnabled(设置页那两个 Toggle 读它),外加两个 WindowController
        // 各自私有的这两个 key(菜单栏"显示…"那两项、全局快捷键读它)。两份可以不一致,后果见
        // init() 里那段迁移注释。现在真值只剩上面那两个,这两个 key 只在 init() 里被读一次做
        // 迁移、随后主动删除(不能留着——留着的话每次启动都会再做一次逻辑与,用户以后重新
        // 打开这个模式,下次启动又会被旧的 false 关掉)。
        static let legacyClassicOverlayVisible = "np:overlayVisible"
        static let legacyNotchOverlayVisible = "np:notchOverlayVisible"
        // 存的是 JSON 字符串,不是 Data——这个文件里所有持久化字段一直是纯 String/Bool/
        // enum 原语(见 AppearanceHelpers.swift 顶部注释:图的是 `defaults read` 能直接
        // 看懂),自定义配色主题数组是个例外,但用 JSON 编码成字符串(不是 Data blob)
        // 存,`defaults read` 好歹还能读出一段可辨认的 JSON 文本,不是不可读的乱码。
        static let customColorThemesJSON = "np:customColorThemesJSON"
    }

    // 字体/字号的默认值,跟配色四项(见下方 init())一样单独给一个有名字的默认值:
    // init() 和 SettingsView"恢复默认文字与配色"按钮都读这两个,不再各自硬编码一遍数字/字符串。
    // 2026-08-17 默认字体从 PingFang SC 改成跟随系统(用户要求)。空字符串就是"跟随
    // 系统"的表示法,见 fontFamilyName 那条属性和 FontFamilyPicker。
    static let defaultFontFamilyName = ""
    static let defaultFontSize = 31.0

    private let defaults = UserDefaults.standard

    @Published var preferWordLevelKaraoke: Bool {
        didSet { defaults.set(preferWordLevelKaraoke, forKey: Keys.preferWordLevelKaraoke) }
    }
    /// 这台机器上曾经出现过中文歌词。只置不清 —— 一个已经露出来的设置不该因为"这首歌
    /// 不是中文"就消失。跨启动持久化:第一次会话里听过中文歌、第二次会话直接开设置页也
    /// 要看得见。
    @Published var hasSeenChineseLyrics: Bool {
        didSet { defaults.set(hasSeenChineseLyrics, forKey: Keys.hasSeenChineseLyrics) }
    }

    /// 这台机器的用户读不读中文 —— 用系统的**首选语言列表**判,不是只看 App 界面语言:
    /// 一个把系统语言设成英文、但语言列表里加了中文的用户,照样在听中文歌。
    /// 只在启动时算一次就够了(系统语言不会在 App 运行期间变)。
    static let userReadsChinese: Bool = Locale.preferredLanguages.contains {
        $0.lowercased().hasPrefix("zh")
    }

    /// 歌词正文显示成简体还是繁体。默认 .off:原样显示歌词源给的写法,不做任何转换。
    @Published var lyricsChineseVariant: ChineseVariant {
        didSet { defaults.set(lyricsChineseVariant.rawValue, forKey: Keys.lyricsChineseVariant) }
    }
    @Published var showRomanization: Bool {
        didSet { defaults.set(showRomanization, forKey: Keys.showRomanization) }
    }

    /// 要给哪几种文字标罗马音(日文/韩文/中文各自可开关)。存 OptionSet 的 rawValue。
    ///
    /// 跟 showRomanization 是两层:那个是"显不显示罗马音这一行"的总开关,这个决定
    /// **哪些语言**会产出罗马音。总开关关掉时这里的选择不起作用,但也不会被清掉。
    @Published var romanizationScripts: RomanizationScripts {
        didSet { defaults.set(romanizationScripts.rawValue, forKey: Keys.romanizationScripts) }
    }
    @Published var showTranslation: Bool {
        didSet { defaults.set(showTranslation, forKey: Keys.showTranslation) }
    }
    @Published var launchAtLoginEnabled: Bool {
        didSet {
            defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled)
            LoginItemManager.shared.setEnabled(launchAtLoginEnabled)
        }
    }
    // 打开 Lyrimuse 时顺带唤起 Apple Music——只在 AppDelegate.applicationDidFinishLaunching
    // 里读一次(见那边的调用点),不是"实时生效"的开关,didSet 只负责持久化,不需要额外
    // 触发什么。默认关闭:"自动启动另一个 App"这类有侵入性的行为,不该在用户没有主动
    // 选择的情况下发生。
    @Published var launchMusicOnLyrimuseOpen: Bool {
        didSet { defaults.set(launchMusicOnLyrimuseOpen, forKey: Keys.launchMusicOnLyrimuseOpen) }
    }
    // collector 常驻服务的装/卸开关——跟 launchAtLoginEnabled 同样的写法，但默认值不能
    // 照抄成 true:首次启动必须走一遍引导页面里的"启用"按钮，让用户看到真实的安装+验证
    // 过程，不能在 init() 阶段就静默尝试装一个 LaunchAgent。
    @Published var collectorServiceEnabled: Bool {
        didSet {
            defaults.set(collectorServiceEnabled, forKey: Keys.collectorServiceEnabled)
            CollectorServiceManager.setEnabled(collectorServiceEnabled)
        }
    }
    // 是否在 Dock 里显示图标(以及连带出现在 Cmd-Tab 里),默认 true(见下面 init() 的
    // 兜底值)。跟 launchAtLoginEnabled 同样的写法,直接在 didSet 里调用生效(而不是像
    // classicOverlayEnabled 那样只负责持久化、把"生效"这一步挪到 View 层)——
    // NSApp.setActivationPolicy 是纯 AppKit 调用,不依赖任何其它单例,不存在
    // "AppSettings.init() 时那个单例还没构造好"的循环初始化风险,可以放心直接在这里调用。
    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: Keys.showInDock)
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        }
    }
    @Published var showNextLinePreview: Bool {
        didSet { defaults.set(showNextLinePreview, forKey: Keys.showNextLinePreview) }
    }
    // 默认关闭:状态栏平时只是个不起眼的小图标,打开后会换成当前歌词行的文字,占用
    // 面积明显变大——不应该在谁都没主动选择的情况下就改变状态栏原有的观感。
    @Published var showLyricsInMenuBar: Bool {
        didSet { defaults.set(showLyricsInMenuBar, forKey: Keys.showLyricsInMenuBar) }
    }
    // 状态栏歌词行超过这个字数就截断+悬停 tooltip 补全,不超过就整行显示——做成可调的
    // 上限而不是写死一个数字。
    // ⚠️ 已经没有读取方了,只为兼容老配置文件保留(见下面 menuBarLyricsWidth)。
    @Published var menuBarLyricsMaxChars: Int {
        didSet { defaults.set(menuBarLyricsMaxChars, forKey: Keys.menuBarLyricsMaxChars) }
    }
    // 菜单栏歌词**固定**占多宽(点)。
    //
    // ⚠️ 2026-08-17 从「最多占多宽」改成「固定占多宽」。原来装得下的句子按自己的宽度
    // 占位,于是长短句来回切时菜单栏项一直在伸缩,右边其它 App 的图标跟着左右晃
    // (用户反馈"动来动去,观感不太好")。现在不管装不装得下都占同样宽,footprint 恒定;
    // 代价是短句右边会空出一块 —— 那是这个诉求本身自带的。实现见
    // MenuBarStatusItem.showFixedWidth。持久化的 key 没跟着改名(仍是
    // np:menuBarLyricsMaxWidth),老用户的设置照常读得出来。
    //
    // 2026-08-15 从"最多几个字"改成按宽度算。按字数根本不是等宽的:实测同为 10 个字,
    // 中文 128pt、英文只有 65pt,差了一倍 —— 同一个"20 字"设置,中文歌几乎占满一条,
    // 英文歌只有一小截,而用户想控制的从来就是"别占太宽"这件事本身。
    //
    // 旧的 menuBarLyricsMaxChars 还留在配置文件里(没删,便于回退),但已经没有读取方。
    @Published var menuBarLyricsWidth: CGFloat {
        didSet { defaults.set(Double(menuBarLyricsWidth), forKey: Keys.menuBarLyricsWidth) }
    }
    // 上面那个宽度对**装得下的句子**意味着什么 —— 2026-08-17 加,把原来写死的行为变成可选。
    //
    // 两种模式只在"这一句比设定宽度短"时才有区别;装不下的句子两边完全一样(占满设定
    // 宽度并横向滚动)。所以这个设置真正决定的是:短句要不要把多出来的地方让出去。
    @Published var menuBarLyricsWidthMode: MenuBarLyricsWidthMode {
        didSet { defaults.set(menuBarLyricsWidthMode.rawValue, forKey: Keys.menuBarLyricsWidthMode) }
    }
    // 菜单栏歌词逐字染色(2026-08-22,用户点名"像酷狗菜单栏歌词"):已唱到的部分染成
    // 系统强调色,边界按逐字时间轴连续推进(实现见 MenuBarScrollingLabel 的填色层)。
    // 只对带逐字时间轴的歌词生效,LRC 整行歌词维持纯色 —— 没有可信的字级进度就不假装有。
    @Published var menuBarLyricsKaraoke: Bool {
        didSet { defaults.set(menuBarLyricsKaraoke, forKey: Keys.menuBarLyricsKaraoke) }
    }
    // 菜单栏歌词的自定义颜色(2026-08-22 用户要的配置项)。**空串 = 跟随系统**:
    // 文字=labelColor(浅深自适应+菜单打开反白),染色=系统强调色(深色菜单栏提亮四成,
    // 见 MenuBarScrollingLabel.karaokeFillColor)。设了自定义色就**原样用**,不再做任何
    // 自动提亮/反白换色(用户挑的就是最终效果;唯一例外是菜单打开的反白态,文字仍换
    // selectedMenuItemTextColor —— 选中蓝底上什么自定义色都可能看不清)。
    // 只存 hex 不缓存 Color:消费方是 AppKit 位图渲染(MenuBarScrollingLabel),要的是
    // NSColor;跟 foregroundColorHex 那套"didSet 缓存 Color"服务的 SwiftUI 场景不同。
    @Published var menuBarLyricsTextColorHex: String {
        didSet { defaults.set(menuBarLyricsTextColorHex, forKey: Keys.menuBarLyricsTextColorHex) }
    }
    @Published var menuBarLyricsFillColorHex: String {
        didSet { defaults.set(menuBarLyricsFillColorHex, forKey: Keys.menuBarLyricsFillColorHex) }
    }
    // 菜单栏那个图标长什么样。它只在**没在显示歌词**时出现(没在放歌、还没解析出这一句、
    // 或者菜单栏歌词整个关掉),所以它跟上面那些宽度设置是两回事,不受它们影响。
    @Published var menuBarIconStyle: MenuBarIconStyle {
        didSet { defaults.set(menuBarIconStyle.rawValue, forKey: Keys.menuBarIconStyle) }
    }
    // 播放时菜单栏图标是否律动(音条跳动/卡拉OK扫色/声波流动/其余轻微摇摆,见
    // MenuBarLiveIconView)。暂停/无播放永远静止,这个开关只管"播放时动不动"。
    @Published var menuBarIconAnimates: Bool {
        didSet { defaults.set(menuBarIconAnimates, forKey: Keys.menuBarIconAnimates) }
    }
    // 悬浮窗背景透明,文字直接叠在桌面内容上——桌面壁纸/其它窗口文字撞色时容易糊在一起,
    // 加个描边提高辨识度。纯展示开关,LyricsOverlayView 每次渲染都直接读这个值,不需要
    // 像 lockPosition/hideDuringScreenCapture 那样额外调用某个单例的方法"生效"。
    //
    // 描边(非模糊阴影)效果参考了 katagaki/DJDX 仓库的 Canvas+alphaThreshold+blur
    // 技术(见 LyricsOverlayView.swift 的 OptionalTextStroke)。UserDefaults key 没有
    // 保留旧名做迁移——本机单用户的本地设置,旧值语义已经对不上新的渲染方式,不如直接
    // 改名、重新走一遍默认值。
    @Published var textStrokeEnabled: Bool {
        didSet { defaults.set(textStrokeEnabled, forKey: Keys.textStrokeEnabled) }
    }
    // #RRGGBBAA。只让用户调"颜色"(含 alpha),描边粗细是代码里的固定常量
    // (OptionalTextStroke 的 width,1.2pt),不做成单独的滑杆——参考 LyricsX 的
    // AlphaColorWell/shadowColor,保持这个克制的取舍。默认 #000000A6(黑色、
    // alpha≈0.65),没碰过这个设置的人从阴影切到描边后颜色不会跳变。
    @Published var textStrokeColorHex: String {
        didSet {
            defaults.set(textStrokeColorHex, forKey: Keys.textStrokeColorHex)
            textStrokeColor = Color(hexWithAlpha: textStrokeColorHex, fallback: .black.opacity(0.65))
        }
    }
    // 只负责持久化——不在这里连带调 LyricsOverlayWindowController.shared.setLocked(_:),
    // 那样会在 AppSettings 自己的 init() 里触发 didSet、顺带在其它单例还没构造完成时
    // 去访问它,有循环初始化风险。"生效"这一步挪到 SettingsView.swift 的 Toggle
    // Binding 里手动分两步调用。
    @Published var lockPosition: Bool {
        didSet { defaults.set(lockPosition, forKey: Keys.lockPosition) }
    }
    // sharingType 是 AppKit 官方支持的"截屏/录屏时隐藏这个窗口,但用户自己在物理屏幕上
    // 仍然看得见"的唯一机制(ScreenCaptureKit/QuickTime 录屏/视频会议共享屏幕/screencapture
    // 截图统统拿不到内容)。只负责持久化,原因跟 lockPosition 一样——"生效"这一步挪到
    // AppDelegate(启动时)和 SettingsView.swift 的 Toggle Binding(运行时切换)里手动调用
    // LyricsOverlayWindowController.shared.setHiddenFromCapture(_:)。
    @Published var hideDuringScreenCapture: Bool {
        didSet { defaults.set(hideDuringScreenCapture, forKey: Keys.hideDuringScreenCapture) }
    }
    // 暂停/没有任何曲目在播放时自动隐藏悬浮窗,恢复播放自动重新显示——跟 hideDuringScreenCapture
    // 一样只负责持久化,"生效"这一步挪到 AppDelegate(启动时)和 SettingsView.swift 的
    // Toggle Binding(运行时切换)里手动调用 LyricsOverlayWindowController.shared.
    // setHideWhenNotPlaying(_:)。默认 false,保留"不管播不播放悬浮窗都一直显示"的原有行为。
    @Published var hideWhenNotPlaying: Bool {
        didSet { defaults.set(hideWhenNotPlaying, forKey: Keys.hideWhenNotPlaying) }
    }
    // "system"(跟随系统语言,默认)/"zh-hans"/"en"——手动覆盖 L10n 的语言解析。这是个
    // @Published 属性而不是简单写完 UserDefaults 就完事,是因为要让所有观察
    // AppSettings.shared 的界面在切换的一瞬间就重新渲染成新语言,不用重启 App
    // (哪些界面需要额外补一份 @ObservedObject 才能吃到这次刷新,见各文件里的改动说明)。
    @Published var appLanguage: String {
        didSet { defaults.set(appLanguage, forKey: Keys.appLanguage) }
    }
    // 单曲歌词时间轴微调(菜单里的"歌词时间轴"/两个可选快捷键)每点一次调整多少——做成
    // 可调的步长而不是代码里的固定常量,跟 menuBarLyricsMaxChars 同样的取舍。范围
    // 50~2000ms 在 SettingsView 的 Stepper 里约束,这里不重复校验。
    @Published var lyricsOffsetStepMs: Int {
        didSet { defaults.set(lyricsOffsetStepMs, forKey: Keys.lyricsOffsetStepMs) }
    }
    // 首次启动的完整引导向导(欢迎/播放器/自动化权限/常驻服务/语言/显示形态/Last.fm/
    // 完成)只走一次。⚠️ 只由 finish() 置位,也就是**真的走到最后一步**才算引导过 ——
    // 中途关窗等于"稍后再说",下次启动会再问一次(2026-08-13 改;此前是"不管从哪一步
    // 关窗都算引导过",会把第一步就关窗的用户永久困在"服务没装、引导再也不出现"的
    // 死路上)。走完之后菜单栏留有"重新运行引导…"随时可以重来。这个向导上线前的老版本
    // 只有"自动化权限"
    // 这一步单独的 NSAlert(hasShownAutomationOnboarding,现已废弃),init() 里做
    // 一次性迁移:老版本已经弹过那一步的,直接视为"已经引导过"，不会突然对已经
    // 用过这个 App 的人强插一整套全新的多步向导。
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }
    // 首次启动时"在 iCloud 里发现一份配置,要导入吗"这一问只问一次。
    //
    // 必须有这个标记,否则会死循环:导入之后要重启才生效,而 hasCompletedOnboarding 是
    // 刻意不跟着导出走的(新机器本该自己走一遍引导,见 ConfigPortability 注释),重启后
    // 它仍然是 false、iCloud 里那份配置也仍然在,于是又弹一次同样的问题。
    //
    // 跟 hasCompletedOnboarding 同类:属于"这台机器的状态",所以同样被排除在导出之外。
    @Published var hasOfferedICloudImport: Bool {
        didSet { defaults.set(hasOfferedICloudImport, forKey: Keys.hasOfferedICloudImport) }
    }
    // 桌面悬浮歌词(经典悬浮窗)、灵动岛歌词各自独立开关,互不排斥——两者对应完全独立的
    // 窗口控制器(LyricsOverlayWindowController/NotchLyricsWindowController),可以
    // 同时开、同时关、或者只开一个(原来是互斥的单选"悬浮窗样式",迁移逻辑见下方
    // init())。只负责持久化,原因跟 lockPosition 等既有窗口相关设置一样——"生效"这
    // 一步(setVisible)挪到 SettingsView.swift 的 Toggle Binding.set 里手动调用,不在
    // 这里的 didSet 里连带触发,避免在 AppSettings.init() 给这两个属性赋初值时就去访问
    // 两个窗口控制器单例、有循环初始化风险。
    @Published var classicOverlayEnabled: Bool {
        didSet { defaults.set(classicOverlayEnabled, forKey: Keys.classicOverlayEnabled) }
    }
    @Published var notchOverlayEnabled: Bool {
        didSet { defaults.set(notchOverlayEnabled, forKey: Keys.notchOverlayEnabled) }
    }
    // 灵动岛卡片的视觉风格——默认磨砂玻璃。只负责持久化,纯展示用的设置,
    // NotchLyricsView 每次渲染直接读这个值,不需要像 classicOverlayEnabled 那样在
    // didSet 里连带调用某个单例的方法。
    /// 每块屏都显示一个灵动岛(默认关:绝大多数人只在眼前那块屏上看)。
    @Published var notchAllScreens: Bool {
        didSet { defaults.set(notchAllScreens, forKey: Keys.notchAllScreens) }
    }

    // 2026-08-17 删掉了 notchVolumeBanner / notchShowEqualizer 两个开关(用户要求),
    // 两者都固定开启:音量提示随灵动岛开关走(见 AppDelegate
    // .startObservingVolumeBannerPreference),播放指示条常驻(见 NotchLyricsView)。
    // 两个旧的 UserDefaults key 已登记进 ConfigPortability.obsoleteDefaultsKeys 就地清理。

    @Published var notchCardStyle: NotchCardStyle {
        didSet { defaults.set(notchCardStyle.rawValue, forKey: Keys.notchCardStyle) }
    }
    // 灵动岛贴在哪块屏幕上——存的是显示器 UUID(见 ScreenIdentity),空字符串 = 自动
    // (挑有刘海的那块)。跟 lockPosition/notchContentWidth 同一个模式:这里只负责持久化,
    // 不碰 NSWindow,由 SettingsView 的 Binding.set 显式调用窗口控制器让它立刻生效。
    @Published var notchScreenID: String {
        didSet { defaults.set(notchScreenID, forKey: Keys.notchScreenID) }
    }
    // 字体族名——空字符串表示"跟随系统",对应悬浮窗原来硬编码的系统字体,不用额外
    // enum/Optional 表达"未设置"。
    @Published var fontFamilyName: String {
        didSet {
            defaults.set(fontFamilyName, forKey: Keys.fontFamilyName)
            recomputeFonts()
        }
    }
    // 主歌词行字号(pt)。罗马音/译文/下一句预览三行的字号从这个值按比例换算(0.65x/0.7x)。
    @Published var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Keys.fontSize)
            recomputeFonts()
        }
    }
    // 悬浮窗宽度(pt)。字号已经能调到 36pt,宽度却一直写死 640——字号调大后长歌词行
    // 很快就得换行,这里加个滑块让宽度也能跟着字号/个人喜好调。只在 didSet 里通知
    // WindowController 实时应用,不在这个 model 层直接碰 NSWindow(跟 lockPosition 等
    // 既有窗口相关设置同一个模式,由 SettingsView 里的 Binding.set 显式调用)。
    @Published var overlayWidth: Double {
        didSet { defaults.set(overlayWidth, forKey: Keys.overlayWidth) }
    }
    // 灵动岛歌词的固定宽度(pt)——同一个模式:只在 didSet 里持久化,不在这个 model 层
    // 直接碰 NSWindow,实时应用交给 SettingsView 的 Binding.set 显式调
    // NotchLyricsWindowController.shared.applyContentWidthSetting()。灵动岛宽度不跟着
    // 歌词内容变化,保持固定。
    @Published var notchContentWidth: Double {
        didSet { defaults.set(notchContentWidth, forKey: Keys.notchContentWidth) }
    }
    // #RRGGBBAA。默认值统一取 ColorTheme.defaultTheme(现在是"深色卡片":不透明白字 +
    // 七成不透明黑底),不在这里硬编码 —— 这一行以前写的是"默认不透明白色,跟悬浮窗原来
    // 硬编码的 .white 视觉完全一致",而实际默认早就被换成过纯黑字、注释没跟上,导致
    // 2026-08-13 审计默认值时一度以为黑字是有意的设计。
    @Published var foregroundColorHex: String {
        didSet {
            defaults.set(foregroundColorHex, forKey: Keys.foregroundColorHex)
            foregroundColor = Color(hexWithAlpha: foregroundColorHex, fallback: .white)
        }
    }
    // #RRGGBBAA。默认 alpha=0(全透明),保留"没有背景、文字直接浮在桌面上"的原有观感——
    // 没主动去设置面板改过的人,悬浮窗外观应该跟改动前逐像素一致。
    @Published var backgroundColorHex: String {
        didSet {
            defaults.set(backgroundColorHex, forKey: Keys.backgroundColorHex)
            backgroundColor = Color(hexWithAlpha: backgroundColorHex, fallback: .clear)
            backgroundIsVisible = (NSColor(hexStringWithAlpha: backgroundColorHex)?.alphaComponent ?? 0) > 0.02
        }
    }
    // 见 Keys.followsCoverArt 注释。纯持久化,不在这里连带计算任何缓存值——实际生效
    // 靠 PlaybackCoordinator.displayForegroundColor 读取这个开关+按曲目算出的动态色,
    // 跟 foregroundColorHex/backgroundColorHex 那种"存 hex→didSet 里转 Color 缓存"的
    // 模式不一样,因为这个开关本身不是一个颜色值。
    @Published var followsCoverArt: Bool {
        didSet { defaults.set(followsCoverArt, forKey: Keys.followsCoverArt) }
    }
    // 用户在"外观"设置里"把当前配色存为新主题"存下的自定义配色主题列表(ColorTheme.swift)——
    // 跟内置预设(ColorTheme.builtInPresets,不持久化、每次都是同一份字面量)分开存放,
    // 这里只放用户自己存的那些。JSON 编码成字符串持久化的理由见 Keys.customColorThemesJSON
    // 注释。
    @Published var customColorThemes: [ColorTheme] {
        didSet {
            let json = (try? JSONEncoder().encode(customColorThemes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            defaults.set(json, forKey: Keys.customColorThemesJSON)
        }
    }

    // 缓存值——LyricsOverlayView.body 随 poller.currentLine 每 50ms 重跑一次(逐字填色
    // 需要),不应该每次渲染都重新解析 hex 字符串/重新查 NSFontManager(会在换行瞬间跟
    // 换行动画的重新挂载撞在同一帧、造成卡顿感)。只在真正的输入(字体/字号/颜色四个
    // 字段)变化时的 didSet 里重算一次,渲染路径只读这些已经算好的值。
    @Published private(set) var foregroundColor: Color = .white
    @Published private(set) var backgroundColor: Color = .clear
    @Published private(set) var backgroundIsVisible: Bool = false
    @Published private(set) var textStrokeColor: Color = .black.opacity(0.65)
    @Published private(set) var mainFont: Font = .system(size: 20, weight: .bold)
    @Published private(set) var romanizationFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var translationFont: Font = .system(size: 14, weight: .regular)
    @Published private(set) var previewFont: Font = .system(size: 14, weight: .medium)

    private func recomputeFonts() {
        mainFont = .overlayFont(familyName: fontFamilyName, size: CGFloat(fontSize), weight: .bold)
        romanizationFont = .overlayFont(familyName: fontFamilyName, size: CGFloat(fontSize) * 0.65, weight: .medium)
        translationFont = .overlayFont(familyName: fontFamilyName, size: CGFloat(fontSize) * 0.7, weight: .regular)
        previewFont = .overlayFont(familyName: fontFamilyName, size: CGFloat(fontSize) * 0.7, weight: .medium)
    }

    private init() {
        preferWordLevelKaraoke = (defaults.object(forKey: Keys.preferWordLevelKaraoke) as? Bool) ?? true
        lyricsChineseVariant = defaults.string(forKey: Keys.lyricsChineseVariant)
            .flatMap(ChineseVariant.init(rawValue:)) ?? .off
        hasSeenChineseLyrics = defaults.bool(forKey: Keys.hasSeenChineseLyrics)
        showRomanization = (defaults.object(forKey: Keys.showRomanization) as? Bool) ?? true
        // 没存过时用 .default(日文/韩文开、中文关)—— 等于改成可配置之前的实际观感,
        // 老用户升级上来看不出任何变化。
        romanizationScripts = (defaults.object(forKey: Keys.romanizationScripts) as? Int)
            .map(RomanizationScripts.init(rawValue:)) ?? .default
        // 默认值跟 App 界面语言联动——译文这几个歌词源(网易云/QQ 音乐)给的固定是
        // 中文翻译,不是"任意语言译文",界面语言不是中文的人默认看到一堆看不懂的
        // 中文字没有意义。L10n.current 直接读 np:appLanguage 这个 UserDefaults key
        // (不经过 self.appLanguage,那个要到下面几行才被赋值),只影响"从没手动碰过
        // 这个开关"的默认值——已经手动开过/关过的人,defaults.object(forKey:) 能读到
        // 已持久化的值,不会被这次改动覆盖。
        showTranslation = (defaults.object(forKey: Keys.showTranslation) as? Bool) ?? Self.userReadsChinese
        // 默认开。⚠️ 只改这个兜底值是**不够**的:init() 里的赋值不触发 didSet,而真正去
        // 注册登录项的是 didSet 里那句 LoginItemManager.setEnabled —— 光改这里会变成
        // "开关显示开着、系统里其实没注册"的假象。补的那一步在
        // AppDelegate.applicationDidFinishLaunching 里,两处必须一起看。
        launchAtLoginEnabled = (defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool) ?? true
        launchMusicOnLyrimuseOpen = (defaults.object(forKey: Keys.launchMusicOnLyrimuseOpen) as? Bool) ?? false
        collectorServiceEnabled = (defaults.object(forKey: Keys.collectorServiceEnabled) as? Bool) ?? false
        showInDock = (defaults.object(forKey: Keys.showInDock) as? Bool) ?? true
        // 默认开。多显示一句下文对跟读几乎总是有用的,而这一项本身不占额外窗口高度。
        showNextLinePreview = (defaults.object(forKey: Keys.showNextLinePreview) as? Bool) ?? true
        showLyricsInMenuBar = (defaults.object(forKey: Keys.showLyricsInMenuBar) as? Bool) ?? false
        menuBarLyricsMaxChars = (defaults.object(forKey: Keys.menuBarLyricsMaxChars) as? Int) ?? 60
        // 默认 200pt:大约中文 15 个字、英文 30 个字,菜单栏上占一小条,不至于把右边
        // 其它 App 的图标挤走。
        menuBarLyricsWidth = CGFloat(
            (defaults.object(forKey: Keys.menuBarLyricsWidth) as? Double) ?? 200)
        // 默认 fixed:2026-08-17 到加这个开关之间,固定宽度是写死的唯一行为,默认值
        // 保持它,升级上来的用户看不出任何变化。
        menuBarLyricsWidthMode = defaults.string(forKey: Keys.menuBarLyricsWidthMode)
            .flatMap(MenuBarLyricsWidthMode.init(rawValue:)) ?? .fixed
        // 默认开:这是把"当前唱到哪"带进菜单栏的增量信息,且只在有逐字数据时出现;
        // 菜单栏歌词本身默认关着,不存在"谁都没选就改变观感"的问题。
        menuBarLyricsKaraoke = (defaults.object(forKey: Keys.menuBarLyricsKaraoke) as? Bool) ?? true
        menuBarLyricsTextColorHex = defaults.string(forKey: Keys.menuBarLyricsTextColorHex) ?? ""
        menuBarLyricsFillColorHex = defaults.string(forKey: Keys.menuBarLyricsFillColorHex) ?? ""
        menuBarIconStyle = defaults.string(forKey: Keys.menuBarIconStyle)
            .flatMap(MenuBarIconStyle.init(rawValue:)) ?? .default
        menuBarIconAnimates = (defaults.object(forKey: Keys.menuBarIconAnimates) as? Bool) ?? true
        lyricsOffsetStepMs = (defaults.object(forKey: Keys.lyricsOffsetStepMs) as? Int) ?? 200
        textStrokeEnabled = (defaults.object(forKey: Keys.textStrokeEnabled) as? Bool) ?? ColorTheme.defaultTheme.textStrokeEnabled
        textStrokeColorHex = defaults.string(forKey: Keys.textStrokeColorHex) ?? ColorTheme.defaultTheme.textStrokeColorHex
        lockPosition = (defaults.object(forKey: Keys.lockPosition) as? Bool) ?? false
        hideDuringScreenCapture = (defaults.object(forKey: Keys.hideDuringScreenCapture) as? Bool) ?? false
        hideWhenNotPlaying = (defaults.object(forKey: Keys.hideWhenNotPlaying) as? Bool) ?? false
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? "system"
        hasCompletedOnboarding = (defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool)
            ?? (defaults.object(forKey: Keys.hasShownAutomationOnboarding) as? Bool) ?? false
        hasOfferedICloudImport =
            (defaults.object(forKey: Keys.hasOfferedICloudImport) as? Bool) ?? false
        // 一次性迁移:互斥的"悬浮窗样式"拆成两个独立开关之前,只可能同时生效一个——
        // 用旧值原样映射过来,保留用户当下已经在看的那个,不强行帮用户多打开另一个
        // (想同时开两个,拆开之后自己在设置里再手动开)。旧 key 只读不删,留着无害。
        //
        // 两个开关先算进局部变量、最后才一次性赋给属性:下面第二段迁移需要读到"算到目前为止
        // 是什么值",而在 init() 里所有存储属性都赋值完成之前读 self 的属性是编译错误
        // ('self' used in property access before all stored properties are initialized)。
        var classicOn: Bool
        var notchOn: Bool
        if let legacyStyle = defaults.string(forKey: Keys.overlayStyle) {
            classicOn = (defaults.object(forKey: Keys.classicOverlayEnabled) as? Bool) ?? (legacyStyle != "notch")
            notchOn = (defaults.object(forKey: Keys.notchOverlayEnabled) as? Bool) ?? (legacyStyle == "notch")
        } else {
            classicOn = (defaults.object(forKey: Keys.classicOverlayEnabled) as? Bool) ?? true
            notchOn = (defaults.object(forKey: Keys.notchOverlayEnabled) as? Bool) ?? false
        }
        // 一次性迁移(2026-08-05):把"菜单栏那份可见性"折进上面这两个开关,然后删掉旧 key。
        // 合并之前同一件事有两个真值——用户从菜单栏关掉某种悬浮歌词,只写了旧的 visible 那一
        // 份,设置页那个 Toggle 读的却是 {classic,notch}OverlayEnabled,于是设置页显示"开"、
        // 窗口实际是隐藏的;而且那个 Toggle 的 set 一旦被触发,就会把用户刚隐藏掉的窗口重新
        // 弄出来。取两者的逻辑与:旧的 visible 一侧是用户最后一次手动显示/隐藏的意图,只要它
        // 明确是 false 就以它为准,绝不把用户已经隐藏的窗口重新打开。
        //
        // 这里显式 defaults.set/removeObject 而不是指望属性的 didSet——didSet 在 init() 里给
        // 属性赋值时不会触发(跟本文件 showInDock 那处注释同一个 Swift 语义),不写就丢。
        if let legacyVisible = defaults.object(forKey: Keys.legacyClassicOverlayVisible) as? Bool {
            if !legacyVisible { classicOn = false }
            defaults.set(classicOn, forKey: Keys.classicOverlayEnabled)
            defaults.removeObject(forKey: Keys.legacyClassicOverlayVisible)
        }
        if let legacyVisible = defaults.object(forKey: Keys.legacyNotchOverlayVisible) as? Bool {
            if !legacyVisible { notchOn = false }
            defaults.set(notchOn, forKey: Keys.notchOverlayEnabled)
            defaults.removeObject(forKey: Keys.legacyNotchOverlayVisible)
        }
        classicOverlayEnabled = classicOn
        notchOverlayEnabled = notchOn
        notchCardStyle = defaults.string(forKey: Keys.notchCardStyle).flatMap(NotchCardStyle.init(rawValue:)) ?? .coverArt
        // 默认开:它是"正在播放"最直观的一个信号,而且不占几个像素。
        notchAllScreens = defaults.bool(forKey: Keys.notchAllScreens)
        notchScreenID = defaults.string(forKey: Keys.notchScreenID) ?? ""
        fontFamilyName = defaults.string(forKey: Keys.fontFamilyName) ?? Self.defaultFontFamilyName
        fontSize = (defaults.object(forKey: Keys.fontSize) as? Double) ?? Self.defaultFontSize
        overlayWidth = (defaults.object(forKey: Keys.overlayWidth) as? Double) ?? 640
        notchContentWidth = (defaults.object(forKey: Keys.notchContentWidth) as? Double) ?? 360
        foregroundColorHex = defaults.string(forKey: Keys.foregroundColorHex) ?? ColorTheme.defaultTheme.foregroundColorHex
        backgroundColorHex = defaults.string(forKey: Keys.backgroundColorHex) ?? ColorTheme.defaultTheme.backgroundColorHex
        followsCoverArt = (defaults.object(forKey: Keys.followsCoverArt) as? Bool) ?? false
        if let json = defaults.string(forKey: Keys.customColorThemesJSON),
           let data = json.data(using: .utf8),
           let themes = try? JSONDecoder().decode([ColorTheme].self, from: data) {
            customColorThemes = themes
        } else {
            customColorThemes = []
        }
        // didSet 对属性在自己 init() 里的这次赋值不会触发(Swift 语义:属性观察者不响应
        // "首次赋初值"这一步),不能赌它会连带把上面 7 个缓存值填对——显式调一次,幂等、
        // 无副作用。
        recomputeFonts()
        foregroundColor = Color(hexWithAlpha: foregroundColorHex, fallback: .white)
        backgroundColor = Color(hexWithAlpha: backgroundColorHex, fallback: .clear)
        backgroundIsVisible = (NSColor(hexStringWithAlpha: backgroundColorHex)?.alphaComponent ?? 0) > 0.02
        textStrokeColor = Color(hexWithAlpha: textStrokeColorHex, fallback: .black.opacity(0.65))
        // 顺手把功能改名/删除之后遗留下来的死键清掉(名单和理由见
        // ConfigPortability.obsoleteDefaultsKeys)。放在最后:上面那些读取全部完成之后再动
        // UserDefaults,不会影响本次启动读到的任何值。
        ConfigPortability.pruneObsoleteDefaults()
    }

    // 把 lyricsOffsetStepMs(毫秒)格式成"0.2"/"0.05"/"1.0"这种干净的秒数文案——
    // %.2f 统一先出两位小数,再把没意义的尾随 0 收掉,但至少留一位小数(不退化成"1"这种
    // 看着像别的数字类型的裸整数)。设置面板的 Stepper 标题、菜单里的"提前/延后 X 秒"
    // 共用这一份格式化,两处数字风格保持一致。
    static func formattedSeconds(ms: Int) -> String {
        var text = String(format: "%.2f", Double(ms) / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text += "0" }
        return text
    }

    /// 带符号的秒数文案("+0.5" / "-0.2" / "0.0")。给"这个值是提前还是延后"这类双向
    /// 调整的地方用 —— formattedSeconds 只管把数字格式干净,正负号由调用方决定要不要带。
    static func signedSeconds(ms: Int) -> String {
        guard ms != 0 else { return formattedSeconds(ms: 0) }
        return (ms > 0 ? "+" : "-") + formattedSeconds(ms: abs(ms))
    }
}
