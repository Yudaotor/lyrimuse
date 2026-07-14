import Foundation
import SwiftUI
import AppKit

// 数据源:远程(跟网页版同一个 state-worker /now)或本地(这台 Mac 上直接读
// media-control + collector 的磁盘缓存,零网络)。新增选项,默认保持原有的远程行为。
enum PlaybackSourceMode: String, Codable, Hashable {
    case relay
    case local
}

// UserDefaults 支撑的设置存储。relay 域名默认写死成这个项目自己的地址(个人工具、
// 不打算分发给别人用,零配置优先),其余是歌词展示偏好 + 开机启动开关。
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
        static let textShadowEnabled = "np:textShadowEnabled"
        static let textShadowColorHex = "np:textShadowColorHex"
        static let fontFamilyName = "np:fontFamilyName"
        static let fontSize = "np:fontSize"
        static let foregroundColorHex = "np:foregroundColorHex"
        static let backgroundColorHex = "np:backgroundColorHex"
        static let lockPosition = "np:lockPosition"
        static let hideDuringScreenCapture = "np:hideDuringScreenCapture"
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
        dataSourceMode = PlaybackSourceMode(rawValue: defaults.string(forKey: Keys.dataSourceMode) ?? "") ?? .relay
        showNextLinePreview = (defaults.object(forKey: Keys.showNextLinePreview) as? Bool) ?? false
        textShadowEnabled = (defaults.object(forKey: Keys.textShadowEnabled) as? Bool) ?? true
        textShadowColorHex = defaults.string(forKey: Keys.textShadowColorHex) ?? "#000000A6"
        lockPosition = (defaults.object(forKey: Keys.lockPosition) as? Bool) ?? false
        hideDuringScreenCapture = (defaults.object(forKey: Keys.hideDuringScreenCapture) as? Bool) ?? false
        fontFamilyName = defaults.string(forKey: Keys.fontFamilyName) ?? ""
        fontSize = (defaults.object(forKey: Keys.fontSize) as? Double) ?? 20
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
