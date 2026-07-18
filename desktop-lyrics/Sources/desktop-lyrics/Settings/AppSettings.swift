import Foundation
import SwiftUI
import AppKit

// 数据源:远程(跟网页版同一个 state-worker /now)或本地(这台 Mac 上直接读
// media-control + collector 的磁盘缓存,零网络)。
enum PlaybackSourceMode: String, Codable, Hashable {
    case relay
    case local
}

// UserDefaults 支撑的设置存储。relay 域名的默认值是这个项目作者自己的地址,仅供切换
// 到 relay 模式又没填自己地址时有个能跑的示例——2026-07-17 起默认数据源已经改成
// local(见 dataSourceMode 的默认值),不会再有人零配置就悄悄连到作者自己的 Worker。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let defaultRelayBaseURL = "https://np.yudaotor.me"

    private enum Keys {
        static let relayBaseURL = "np:relayBaseURL"
        static let preferWordLevelKaraoke = "np:preferWordLevelKaraoke"
        static let showRomanization = "np:showRomanization"
        static let showTranslation = "np:showTranslation"
        static let launchAtLoginEnabled = "np:launchAtLoginEnabled"
        static let dataSourceMode = "np:dataSourceMode"
        static let showNextLinePreview = "np:showNextLinePreview"
        static let showLyricsInMenuBar = "np:showLyricsInMenuBar"
        static let menuBarLyricsMaxChars = "np:menuBarLyricsMaxChars"
        static let textShadowEnabled = "np:textShadowEnabled"
        static let textShadowColorHex = "np:textShadowColorHex"
        static let fontFamilyName = "np:fontFamilyName"
        static let fontSize = "np:fontSize"
        static let overlayWidth = "np:overlayWidth"
        static let foregroundColorHex = "np:foregroundColorHex"
        static let backgroundColorHex = "np:backgroundColorHex"
        static let lockPosition = "np:lockPosition"
        static let hideDuringScreenCapture = "np:hideDuringScreenCapture"
        static let hideWhenNotPlaying = "np:hideWhenNotPlaying"
        // 跟 L10n.swift 里的 languageOverrideKey 必须是同一个字符串——那边只读、这里
        // 只写(负责持久化+驱动"通用"tab 的语言 Picker),两处各自独立实现,不要互相
        // import,理由见 L10n.swift 顶部注释(L10n 不依赖 @MainActor 的 AppSettings)。
        static let appLanguage = "np:appLanguage"
        static let preciseAppleMusicPosition = "np:preciseAppleMusicPosition"
        static let hasShownAutomationOnboarding = "np:hasShownAutomationOnboarding"
        static let overlayStyle = "np:overlayStyle"
    }

    private let defaults = UserDefaults.standard

    @Published var relayBaseURL: String {
        didSet { defaults.set(relayBaseURL, forKey: Keys.relayBaseURL) }
    }
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
    // 只负责持久化——不在这里连带调 PlaybackCoordinator.applyMode(),那样会在
    // AppSettings 自己的 init() 里(设置 dataSourceMode 初始值那行)触发 didSet,
    // 顺带在 AppSettings.shared 还没构造完成时就去访问 PlaybackCoordinator.shared,
    // 有循环初始化的风险。改成跟 relayBaseURL/preferWordLevelKaraoke 一样的既有写法:
    // 设置面板的 Picker 里手动分两步调用(见 SettingsView.swift)。
    @Published var dataSourceMode: PlaybackSourceMode {
        didSet { defaults.set(dataSourceMode.rawValue, forKey: Keys.dataSourceMode) }
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
    // 加个阴影提高辨识度。纯展示开关,LyricsOverlayView 每次渲染都直接读这个值,不需要
    // 像 lockPosition/hideDuringScreenCapture 那样额外调用某个单例的方法"生效"。
    @Published var textShadowEnabled: Bool {
        didSet { defaults.set(textShadowEnabled, forKey: Keys.textShadowEnabled) }
    }
    // #RRGGBBAA。参考 LyricsX(Controller/Preferences/PreferenceDisplayViewController.swift
    // 的 AlphaColorWell + View/KaraokeLyricsView.swift 的 shadowColor)——那边阴影只让用户
    // 调"颜色"(含 alpha),模糊半径/偏移量是代码里的固定常量(shadowBlurRadius=3,
    // shadowOffset=.zero),没有做成单独的滑杆。这里跟随同一个克制的取舍:只加颜色选择器,
    // 不加半径/偏移这类额外调节项。默认 #000000A6(黑色、alpha≈0.65)跟这个功能刚上线时
    // 硬编码的 .black.opacity(0.65) 逐像素一致,没碰过这个新设置的人观感不变。
    @Published var textShadowColorHex: String {
        didSet {
            defaults.set(textShadowColorHex, forKey: Keys.textShadowColorHex)
            textShadowColor = Color(hexWithAlpha: textShadowColorHex, fallback: .black.opacity(0.65))
        }
    }
    // 只负责持久化,原因跟 dataSourceMode 一样——不在这里连带调
    // LyricsOverlayWindowController.shared.setLocked(_:),那样会在 AppSettings 自己的
    // init() 里触发 didSet、顺带在其它单例还没构造完成时去访问它,有循环初始化风险。
    // "生效"这一步挪到 SettingsView.swift 的 Toggle Binding 里手动分两步调用。
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
    // 是否尝试用"自动化"权限问 Music.app 要精确到 ~0.1s 的播放位置(见
    // AppleMusicPositionClient)——默认开(保持这个功能上线以来一直无条件尝试的行为
    // 不变),关掉就直接跳过这次尝试、退回 media-control 的估算进度(等同于"这次调用
    // 失败了"的既有回退路径,不需要改那条路径本身)。这个开关本身不受权限状态影响、
    // 随时能切;真正会不会成功仍然取决于 MusicAutomationPermission 那份系统授权。
    @Published var preciseAppleMusicPosition: Bool {
        didSet { defaults.set(preciseAppleMusicPosition, forKey: Keys.preciseAppleMusicPosition) }
    }
    // 首次启动的自动化权限引导框只弹一次——不管用户当时选的是"请求权限"还是"以后
    // 再说",都会置为 true,之后随时能在设置里的"权限"分区自己再看/再请求,不会被
    // 这个启动引导反复打扰。
    @Published var hasShownAutomationOnboarding: Bool {
        didSet { defaults.set(hasShownAutomationOnboarding, forKey: Keys.hasShownAutomationOnboarding) }
    }
    // "classic"(经典悬浮窗,默认,不影响现有用户)/"notch"(灵动岛/刘海样式)——两种
    // 样式各自对应一个完全独立的窗口控制器(LyricsOverlayWindowController/
    // NotchLyricsWindowController)。只负责持久化,原因跟 lockPosition 等既有窗口
    // 相关设置一样——"生效"这一步(把旧样式的控制器 setVisible(false)、新样式的
    // setVisible(true))挪到 SettingsView.swift 的 Picker Binding.set 里手动调用,
    // 不在这里的 didSet 里连带触发,避免在 AppSettings.init() 给这个属性赋初值时
    // 就去访问两个窗口控制器单例、有循环初始化风险。
    @Published var overlayStyle: String {
        didSet { defaults.set(overlayStyle, forKey: Keys.overlayStyle) }
    }
    // 字体族名——空字符串表示"跟随系统",对应悬浮窗原来硬编码的系统字体,不用额外
    // enum/Optional 表达"未设置",跟 relayBaseURL 的空字符串兜底是同一种写法。
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

    // 缓存值——LyricsOverlayView.body 随 poller.currentLine 每 50ms 重跑一次(逐字填色
    // 需要),不应该每次渲染都重新解析 hex 字符串/重新查 NSFontManager(会在换行瞬间跟
    // 换行动画的重新挂载撞在同一帧、造成卡顿感)。只在真正的输入(字体/字号/颜色四个
    // 字段)变化时的 didSet 里重算一次,渲染路径只读这些已经算好的值。
    @Published private(set) var foregroundColor: Color = .white
    @Published private(set) var backgroundColor: Color = .clear
    @Published private(set) var backgroundIsVisible: Bool = false
    @Published private(set) var textShadowColor: Color = .black.opacity(0.65)
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
        relayBaseURL = defaults.string(forKey: Keys.relayBaseURL) ?? Self.defaultRelayBaseURL
        preferWordLevelKaraoke = (defaults.object(forKey: Keys.preferWordLevelKaraoke) as? Bool) ?? true
        showRomanization = (defaults.object(forKey: Keys.showRomanization) as? Bool) ?? true
        showTranslation = (defaults.object(forKey: Keys.showTranslation) as? Bool) ?? true
        launchAtLoginEnabled = (defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool) ?? false
        // 2026-07-17 前默认是 .relay,零配置就会连到作者自己的 Worker、显示作者本人的
        // 播放——这台工具现在要给别人用,默认改成 .local(零网络、读本机 media-control +
        // collector 的磁盘缓存,没有缓存就是"暂无歌词"而不是"看到别人的数据")。
        dataSourceMode = PlaybackSourceMode(rawValue: defaults.string(forKey: Keys.dataSourceMode) ?? "") ?? .local
        showNextLinePreview = (defaults.object(forKey: Keys.showNextLinePreview) as? Bool) ?? false
        showLyricsInMenuBar = (defaults.object(forKey: Keys.showLyricsInMenuBar) as? Bool) ?? false
        menuBarLyricsMaxChars = (defaults.object(forKey: Keys.menuBarLyricsMaxChars) as? Int) ?? 60
        textShadowEnabled = (defaults.object(forKey: Keys.textShadowEnabled) as? Bool) ?? true
        textShadowColorHex = defaults.string(forKey: Keys.textShadowColorHex) ?? "#000000A6"
        lockPosition = (defaults.object(forKey: Keys.lockPosition) as? Bool) ?? false
        hideDuringScreenCapture = (defaults.object(forKey: Keys.hideDuringScreenCapture) as? Bool) ?? false
        hideWhenNotPlaying = (defaults.object(forKey: Keys.hideWhenNotPlaying) as? Bool) ?? false
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? "system"
        preciseAppleMusicPosition = (defaults.object(forKey: Keys.preciseAppleMusicPosition) as? Bool) ?? true
        hasShownAutomationOnboarding = (defaults.object(forKey: Keys.hasShownAutomationOnboarding) as? Bool) ?? false
        overlayStyle = defaults.string(forKey: Keys.overlayStyle) ?? "classic"
        fontFamilyName = defaults.string(forKey: Keys.fontFamilyName) ?? ""
        fontSize = (defaults.object(forKey: Keys.fontSize) as? Double) ?? 20
        overlayWidth = (defaults.object(forKey: Keys.overlayWidth) as? Double) ?? 640
        foregroundColorHex = defaults.string(forKey: Keys.foregroundColorHex) ?? "#FFFFFFFF"
        backgroundColorHex = defaults.string(forKey: Keys.backgroundColorHex) ?? "#00000000"
        // didSet 对属性在自己 init() 里的这次赋值不会触发(Swift 语义:属性观察者不响应
        // "首次赋初值"这一步),不能赌它会连带把上面 7 个缓存值填对——显式调一次,幂等、
        // 无副作用。
        recomputeFonts()
        foregroundColor = Color(hexWithAlpha: foregroundColorHex, fallback: .white)
        backgroundColor = Color(hexWithAlpha: backgroundColorHex, fallback: .clear)
        backgroundIsVisible = (NSColor(hexStringWithAlpha: backgroundColorHex)?.alphaComponent ?? 0) > 0.02
        textShadowColor = Color(hexWithAlpha: textShadowColorHex, fallback: .black.opacity(0.65))
    }
}
