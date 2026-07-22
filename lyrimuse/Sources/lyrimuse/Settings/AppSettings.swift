import Foundation
import SwiftUI
import AppKit

// 灵动岛卡片的三种视觉风格——UI 预览阶段给用户看过三个方向(纯黑/磨砂玻璃/深色渐变),
// 当时选了磨砂玻璃直接实现,用户后来反馈"另外两个也做一下,做成可配置的"。displayName/
// fill(alpha 相关的具体 ShapeStyle)定义在 NotchLyricsView.swift(跟灵动岛卡片本身的
// UI 强相关,不适合放在这个纯设置文件里),这里只负责持久化用的 rawValue。
enum NotchCardStyle: String, Codable, Hashable, CaseIterable {
    case solidBlack
    case frostedGlass
    case darkGradient
}

// UserDefaults 支撑的设置存储。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let preferWordLevelKaraoke = "np:preferWordLevelKaraoke"
        static let showRomanization = "np:showRomanization"
        static let showTranslation = "np:showTranslation"
        static let launchAtLoginEnabled = "np:launchAtLoginEnabled"
        static let collectorServiceEnabled = "np:collectorServiceEnabled"
        static let showInDock = "np:showInDock"
        static let showNextLinePreview = "np:showNextLinePreview"
        static let showLyricsInMenuBar = "np:showLyricsInMenuBar"
        static let menuBarLyricsMaxChars = "np:menuBarLyricsMaxChars"
        static let lyricsOffsetStepMs = "np:lyricsOffsetStepMs"
        static let textStrokeEnabled = "np:textStrokeEnabled"
        static let textStrokeColorHex = "np:textStrokeColorHex"
        static let fontFamilyName = "np:fontFamilyName"
        static let fontSize = "np:fontSize"
        static let overlayWidth = "np:overlayWidth"
        static let notchContentWidth = "np:notchContentWidth"
        static let foregroundColorHex = "np:foregroundColorHex"
        static let backgroundColorHex = "np:backgroundColorHex"
        static let lockPosition = "np:lockPosition"
        static let hideDuringScreenCapture = "np:hideDuringScreenCapture"
        static let hideWhenNotPlaying = "np:hideWhenNotPlaying"
        // 跟 L10n.swift 里的 languageOverrideKey 必须是同一个字符串——那边只读、这里
        // 只写(负责持久化+驱动"通用"tab 的语言 Picker),两处各自独立实现,不要互相
        // import,理由见 L10n.swift 顶部注释(L10n 不依赖 @MainActor 的 AppSettings)。
        static let appLanguage = "np:appLanguage"
        static let hasShownAutomationOnboarding = "np:hasShownAutomationOnboarding" // 已废弃,只在 init() 里读一次做迁移
        static let hasCompletedOnboarding = "np:hasCompletedOnboarding"
        static let overlayStyle = "np:overlayStyle" // 已废弃,只在 init() 里读一次做迁移
        static let classicOverlayEnabled = "np:classicOverlayEnabled"
        static let notchOverlayEnabled = "np:notchOverlayEnabled"
        static let notchCardStyle = "np:notchCardStyle"
        // 存的是 JSON 字符串,不是 Data——这个文件里所有持久化字段一直是纯 String/Bool/
        // enum 原语(见 AppearanceHelpers.swift 顶部注释:图的是 `defaults read` 能直接
        // 看懂),自定义配色主题数组是个例外,但用 JSON 编码成字符串(不是 Data blob)
        // 存,`defaults read` 好歹还能读出一段可辨认的 JSON 文本,不是不可读的乱码。
        static let customColorThemesJSON = "np:customColorThemesJSON"
    }

    // 2026-07-22:字体/字号的默认值——配色四项的默认值改成引用 ColorTheme.defaultTheme
    // 之后(见下方 init()),这两个排版字段(不属于 ColorTheme,见该文件顶部注释)单独在
    // 这里给一个同样有名字的默认值,道理一样:init() 和 SettingsView"恢复默认外观"按钮
    // 都读这两个,不再各自硬编码一遍数字/字符串。
    static let defaultFontFamilyName = "PingFang SC"
    static let defaultFontSize = 31.0

    private let defaults = UserDefaults.standard

    @Published var preferWordLevelKaraoke: Bool {
        didSet { defaults.set(preferWordLevelKaraoke, forKey: Keys.preferWordLevelKaraoke) }
    }
    @Published var showRomanization: Bool {
        didSet { defaults.set(showRomanization, forKey: Keys.showRomanization) }
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
    // collector 常驻服务的装/卸开关——跟 launchAtLoginEnabled 同样的写法，但默认值不能
    // 照抄成 true:首次启动必须走一遍引导页面里的"启用"按钮，让用户看到真实的安装+验证
    // 过程，不能在 init() 阶段就静默尝试装一个 LaunchAgent。
    @Published var collectorServiceEnabled: Bool {
        didSet {
            defaults.set(collectorServiceEnabled, forKey: Keys.collectorServiceEnabled)
            CollectorServiceManager.setEnabled(collectorServiceEnabled)
        }
    }
    // 是否在 Dock 里显示图标(以及连带出现在 Cmd-Tab 里)——用户反馈默认就应该开启,
    // 所以这里默认 true(见下面 init() 的兜底值),不是原来"跟裸可执行文件时代保持一致"
    // 那版的默认关闭。跟 launchAtLoginEnabled 同样的写法,直接在 didSet 里调用生效
    // (而不是像 classicOverlayEnabled 那样只负责持久化、把"生效"这
    // 一步挪到 View 层)——NSApp.setActivationPolicy 是纯 AppKit 调用,不依赖任何其它
    // 单例,不存在"AppSettings.init() 时那个单例还没构造好"的循环初始化风险,可以放心
    // 直接在这里调用。
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
    // 状态栏歌词行超过这个字数就截断+悬停 tooltip 补全,不超过就整行显示——用户反馈
    // "不拦截,有多长展示多少,合理范围内就好",做成可调的上限而不是写死一个数字。
    @Published var menuBarLyricsMaxChars: Int {
        didSet { defaults.set(menuBarLyricsMaxChars, forKey: Keys.menuBarLyricsMaxChars) }
    }
    // 悬浮窗背景透明,文字直接叠在桌面内容上——桌面壁纸/其它窗口文字撞色时容易糊在一起,
    // 加个描边提高辨识度。纯展示开关,LyricsOverlayView 每次渲染都直接读这个值,不需要
    // 像 lockPosition/hideDuringScreenCapture 那样额外调用某个单例的方法"生效"。
    //
    // 2026-07-22:这两个属性原来叫 textShadowEnabled/textShadowColorHex,渲染效果是
    // 模糊阴影(.shadow(radius:))——用户反馈想改成描边(实心轮廓),参考了
    // katagaki/DJDX 仓库的 Canvas+alphaThreshold+blur 技术做出真正的描边效果(见
    // LyricsOverlayView.swift 的 OptionalTextStroke)。属性/UserDefaults key 一并
    // 改名,不留旧 key 做迁移——这是本机单用户的本地设置,旧值(阴影开关+颜色)语义已经
    // 对不上新的渲染方式,沿用旧 key 只会让人以为这个值"应该还生效",不如直接改名、
    // 重新走一遍默认值,跟这个项目其它"渲染方式变了就直接改名不做兼容"的先例一致
    // (比如 weeklyDigestPush 整个函数被 digest.go 拆分替代时也没留旧接口)。
    @Published var textStrokeEnabled: Bool {
        didSet { defaults.set(textStrokeEnabled, forKey: Keys.textStrokeEnabled) }
    }
    // #RRGGBBAA。延续原来阴影功能的取舍(参考 LyricsX 的 AlphaColorWell/shadowColor):
    // 只让用户调"颜色"(含 alpha),描边粗细是代码里的固定常量(OptionalTextStroke 的
    // width,1.2pt),不做成单独的滑杆——原来阴影功能的模糊半径/偏移量也是同样处理,
    // 保持这个克制的一贯做法。默认 #000000A6(黑色、alpha≈0.65)直接沿用改名前的默认值,
    // 没碰过这个设置的人从阴影切到描边后颜色不会跳变,只有渲染方式本身变了。
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
    // 单曲歌词时间轴微调(菜单里的"歌词时间轴"/两个可选快捷键)每点一次调整多少——用户
    // 反馈"不要写死 0.2 秒",做成可调的步长而不是代码里的固定常量,跟 menuBarLyricsMaxChars
    // 同样的取舍。范围 50~2000ms 在 SettingsView 的 Stepper 里约束,这里不重复校验。
    @Published var lyricsOffsetStepMs: Int {
        didSet { defaults.set(lyricsOffsetStepMs, forKey: Keys.lyricsOffsetStepMs) }
    }
    // 首次启动的完整引导向导(欢迎/自动化权限/语言/完成)只走一次——不管从哪一步
    // 关掉窗口都会置为 true(见 OnboardingView 的 .onDisappear),没有任何重新打开的
    // 入口(不留菜单项),关掉就是关掉了。这个向导上线前的老版本只有"自动化权限"
    // 这一步单独的 NSAlert(hasShownAutomationOnboarding,现已废弃),init() 里做
    // 一次性迁移:老版本已经弹过那一步的,直接视为"已经引导过"，不会突然对已经
    // 用过这个 App 的人强插一整套全新的多步向导。
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }
    // 桌面悬浮歌词(经典悬浮窗)、灵动岛歌词各自独立开关,互不排斥——两者对应完全独立的
    // 窗口控制器(LyricsOverlayWindowController/NotchLyricsWindowController),可以
    // 同时开、同时关、或者只开一个。最初做成互斥的单选"悬浮窗样式"(要么经典要么灵动岛),
    // 用户反馈这两个应该是独立的展示位置,不是同一个设置的两种取值,改成这样。只负责
    // 持久化,原因跟 lockPosition 等既有窗口相关设置一样——"生效"这一步(setVisible)挪到
    // SettingsView.swift 的 Toggle Binding.set 里手动调用,不在这里的 didSet 里连带触发,
    // 避免在 AppSettings.init() 给这两个属性赋初值时就去访问两个窗口控制器单例、有循环
    // 初始化风险。
    @Published var classicOverlayEnabled: Bool {
        didSet { defaults.set(classicOverlayEnabled, forKey: Keys.classicOverlayEnabled) }
    }
    @Published var notchOverlayEnabled: Bool {
        didSet { defaults.set(notchOverlayEnabled, forKey: Keys.notchOverlayEnabled) }
    }
    // 灵动岛卡片的视觉风格——默认磨砂玻璃(第一版直接实现、真机验证过的那个方向),
    // 只负责持久化,纯展示用的设置,NotchLyricsView 每次渲染直接读这个值,不需要像
    // classicOverlayEnabled 那样在 didSet 里连带调用某个单例的方法。
    @Published var notchCardStyle: NotchCardStyle {
        didSet { defaults.set(notchCardStyle.rawValue, forKey: Keys.notchCardStyle) }
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
    // 灵动岛歌词的固定宽度(pt)——2026-07-22 新增,同一个模式:只在 didSet 里持久化,
    // 不在这个 model 层直接碰 NSWindow,实时应用交给 SettingsView 的 Binding.set 显式调
    // NotchLyricsWindowController.shared.applyContentWidthSetting()(见该文件注释——
    // 这条设置项本身就是为了回应"灵动岛宽度不应该跟着歌词内容变"这条反馈而加的,默认值
    // 360 沿用改回固定宽度那次定的数值)。
    @Published var notchContentWidth: Double {
        didSet { defaults.set(notchContentWidth, forKey: Keys.notchContentWidth) }
    }
    // #RRGGBBAA。默认不透明白色,跟悬浮窗原来硬编码的 .white 视觉完全一致。
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
        showRomanization = (defaults.object(forKey: Keys.showRomanization) as? Bool) ?? true
        showTranslation = (defaults.object(forKey: Keys.showTranslation) as? Bool) ?? true
        launchAtLoginEnabled = (defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool) ?? false
        collectorServiceEnabled = (defaults.object(forKey: Keys.collectorServiceEnabled) as? Bool) ?? false
        showInDock = (defaults.object(forKey: Keys.showInDock) as? Bool) ?? true
        showNextLinePreview = (defaults.object(forKey: Keys.showNextLinePreview) as? Bool) ?? false
        showLyricsInMenuBar = (defaults.object(forKey: Keys.showLyricsInMenuBar) as? Bool) ?? false
        menuBarLyricsMaxChars = (defaults.object(forKey: Keys.menuBarLyricsMaxChars) as? Int) ?? 60
        lyricsOffsetStepMs = (defaults.object(forKey: Keys.lyricsOffsetStepMs) as? Int) ?? 200
        textStrokeEnabled = (defaults.object(forKey: Keys.textStrokeEnabled) as? Bool) ?? ColorTheme.defaultTheme.textStrokeEnabled
        textStrokeColorHex = defaults.string(forKey: Keys.textStrokeColorHex) ?? ColorTheme.defaultTheme.textStrokeColorHex
        lockPosition = (defaults.object(forKey: Keys.lockPosition) as? Bool) ?? false
        hideDuringScreenCapture = (defaults.object(forKey: Keys.hideDuringScreenCapture) as? Bool) ?? false
        hideWhenNotPlaying = (defaults.object(forKey: Keys.hideWhenNotPlaying) as? Bool) ?? false
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? "system"
        hasCompletedOnboarding = (defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool)
            ?? (defaults.object(forKey: Keys.hasShownAutomationOnboarding) as? Bool) ?? false
        // 一次性迁移:互斥的"悬浮窗样式"拆成两个独立开关之前,只可能同时生效一个——
        // 用旧值原样映射过来,保留用户当下已经在看的那个,不强行帮用户多打开另一个
        // (想同时开两个,拆开之后自己在设置里再手动开)。旧 key 只读不删,留着无害。
        if let legacyStyle = defaults.string(forKey: Keys.overlayStyle) {
            classicOverlayEnabled = (defaults.object(forKey: Keys.classicOverlayEnabled) as? Bool) ?? (legacyStyle != "notch")
            notchOverlayEnabled = (defaults.object(forKey: Keys.notchOverlayEnabled) as? Bool) ?? (legacyStyle == "notch")
        } else {
            classicOverlayEnabled = (defaults.object(forKey: Keys.classicOverlayEnabled) as? Bool) ?? true
            notchOverlayEnabled = (defaults.object(forKey: Keys.notchOverlayEnabled) as? Bool) ?? false
        }
        notchCardStyle = defaults.string(forKey: Keys.notchCardStyle).flatMap(NotchCardStyle.init(rawValue:)) ?? .frostedGlass
        fontFamilyName = defaults.string(forKey: Keys.fontFamilyName) ?? Self.defaultFontFamilyName
        fontSize = (defaults.object(forKey: Keys.fontSize) as? Double) ?? Self.defaultFontSize
        overlayWidth = (defaults.object(forKey: Keys.overlayWidth) as? Double) ?? 640
        notchContentWidth = (defaults.object(forKey: Keys.notchContentWidth) as? Double) ?? 360
        foregroundColorHex = defaults.string(forKey: Keys.foregroundColorHex) ?? ColorTheme.defaultTheme.foregroundColorHex
        backgroundColorHex = defaults.string(forKey: Keys.backgroundColorHex) ?? ColorTheme.defaultTheme.backgroundColorHex
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
}
