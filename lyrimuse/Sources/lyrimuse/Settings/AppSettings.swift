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
//
// ⚠️ **这个枚举不只决定背景**(2026-08-31 起):`.coverArt` 同时让**前景**(歌名/歌手/歌词/
// 逐字染色/播放键/进度条/音浪)走封面主色,其余三种风格前景恒为白 —— 也就是"跟随封面"这个
// 名字现在指的是**整张卡**跟着封面走,而不只是背景。在此之前前景由 `followsCoverArt` 决定,
// 而那是**桌面悬浮歌词**的开关、入口也全在悬浮歌词那一段,只开灵动岛的用户够不到它,并且跟
// 这里的「跟随封面」同名不同义。合并的完整理由见 NotchLyricsView 里 `NotchPlayback.accent`
// 的注释。改这个枚举时记得它现在牵着两处渲染。
enum NotchCardStyle: String, Codable, Hashable, CaseIterable {
    case solidBlack
    case frostedGlass
    case darkGradient
    case coverArt
}

/// 灵动岛**稳态/展开**那一行里,左右两只耳朵各显示什么。displayName 定义在
/// NotchLyricsView.swift(跟卡片本身的 UI 强相关),这里只负责持久化用的 rawValue。
///
/// ⚠️ **只管稳态/展开那一套耳朵,管不到收起态**(没在播放且没 hover 时的 iPhone 灵动岛式
/// 极简形态:左封面、右音浪,2026-08-19 用户拍板)。理由是硬的:收起态单侧耳宽是
/// `NotchMetrics.collapsedEarWidth` = 34pt,11.5pt 字号下连两个汉字都装不下,歌名/歌手/专辑
/// 放进去只能是个断头。给它单独配一套 = 多两个下拉、而可选项只剩图标类,收益配不上复杂度。
///
/// ⚠️ **音浪(EqualizerBars)不在这个列表里**,它恒定钉在右耳外缘 —— 它是播放指示灯不是内容,
/// 而且 2026-08-19 特意让它"在两种形态下都住右耳、收放切换时不横跳"。
/// **唯一的例外是右耳选了 `.controls`**:那时音浪让位(见 NotchLyricsView.topRow)。理由不是
/// "挤不下"这么将就 —— 播放/暂停那枚按钮的图标本身就在报播放状态(在播时画的是 ⏸),音浪摆在
/// 它旁边是同一件事说两遍;顺带也解决了右耳那点宽度不够摆下三键 + 音浪的问题。
///
/// ⚠️ `.artwork` / `.controls` 两个是 2026-08-31 用户点名要加的,而它们各自都有一段**曾经被
/// 判定为"不该放进耳朵"的历史**。加进来之后那些顾虑没有消失,只是变成了用户自己的取舍;
/// 记在这里免得下一个人以为是没想过就塞进来的:
///   - **封面**:`NotchLyricsView.artworkThumbnail` 上方有实测记录 —— 360pt 宽配实测 179pt
///     刘海,单耳只有 80.5pt,当年按歌词行那枚 32pt 的尺寸塞进来"实机看过就是放不下"。
///     现在按**收起态那枚**的尺寸走(`contentTopInset − 10`,约 23pt),放得下;而且歌词行末尾
///     那枚仍在,两处会同时出现同一张封面,这是选它的人自己的选择。
///   - **播放控制键**:2026-08-19 从耳朵挪进了 hover 展开卡,理由是"岛本来就是 hover 展开的,
///     光标到达耳朵之前卡片已经展开,耳朵里再留一枚播放键是重复目标"。那条论证今天依然成立
///     —— 但它论的是**默认**该摆哪儿,不是"不许摆"。尺寸沿用当年耳朵里那一档
///     (`controlButton` 的 `primary` 两档默认值 15/18pt,比展开卡里的 22pt 小一号),那两档
///     默认值从那次搬家起就一直留在代码里没有调用方,现在重新有了。
enum NotchEarModule: String, Codable, Hashable, CaseIterable {
    case title
    case artist
    case album
    /// 专辑封面小图。尺寸按收起态那枚走(约 23pt),不是歌词行末尾那枚 32pt 的 —— 耳朵只有
    /// `contentTopInset` 那么高。点它跟另外两处封面一样:打开歌词窗口。
    case artwork
    /// 上一首 / 播放暂停 / 下一首。放进右耳时音浪让位,见上面那段⚠️。
    case controls
    /// 已播时长。稳态下卡片里没有进度条(那个只在 hover 展开时才有),这是唯一能看时间的地方。
    case elapsed
    /// 剩余时长(带负号)。曲目时长未知时整块留白。
    case remaining
    case none
}

/// 播放指示条(音浪/EqualizerBars)贴哪只耳朵的外缘——2026-08-31 用户要求把"音浪固定贴右耳"
/// 开放成可配(原来写死在 NotchLyricsView.topRow 里,见那段⚠️)。它依然**不是** NotchEarModule
/// 的一个选项:音浪是播放指示灯不是内容,这条边界没变,变的只是"贴哪一侧、要不要贴"。
enum NotchEqualizerEar: String, Codable, Hashable, CaseIterable {
    case left
    case right
}

/// 歌词行末尾那枚封面缩略图贴左还是贴右(2026-09-01)。displayName 定义在
/// NotchLyricsView.swift(同 NotchEarModule/NotchCardStyle 那两个枚举的惯例)。
///
/// ⚠️ 落点几经反复,均系同一天:最初设计成"展开区曲目信息头部"里的一枚独立封面、
/// 支持左右上下四个方位——用户看过效果后指出"右上角那枚已有的歌词行封面"和这枚新封面
/// 同时出现是重复,要求把可配置能力**并回**歌词行本来就有的那枚(`lyricRowContent` 尾端
/// 的 `artworkThumbnail`,2026-08-05 就有、2026-08-10 用户曾要求去掉开关固定显示)。
/// 并回之后"上/下"没有意义了(封面贴在单行歌词的行首或行尾,不存在"上下"),枚举因此
/// 只剩两个方位,不是偷懒少写。
enum NotchLyricRowArtworkPosition: String, Codable, Hashable, CaseIterable {
    case left, right
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

// 固定宽度模式下,装得下的短句在那一格里靠哪边(2026-09-01,用户点名要"对齐模式")。
//
// ⚠️ **只在固定宽度 + 这一句装得下时才有效果**,这不是偷懒而是定义使然:
//   - 自适应模式下那一格的宽度**就等于**文字宽度(见 MenuBarLyricsWidthMode.adaptive),
//     没有多余空间可言,三个选项画出来一模一样;
//   - 固定宽度下放不下的句子会横向滚动(MenuBarMarquee.ScrollPacing),文字比格子宽,
//     同样没有空位。
// 所以设置界面里这一行只在固定模式下出现 —— 摆一个恒无效果的控件比不摆更糟。
//
// 现有行为等于 .leading:MenuBarScrollingLabel 静止时把 contentLayer.position.x 复位到 0
// (那一格的左边缘),短句右边空出一块。所以 .leading 作默认值,存量用户观感一字不变。
enum MenuBarLyricsAlignment: String, Codable, Hashable, CaseIterable {
    case leading
    case center
    case trailing
}

// UserDefaults 支撑的设置存储。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let preferWordLevelKaraoke = "np:preferWordLevelKaraoke"
        static let lyricsChineseVariant = "np:lyricsChineseVariant"
        static let hasSeenChineseLyrics = "np:hasSeenChineseLyrics"
        static let hasShownMenuBarPositionHint = "np:hasShownMenuBarPositionHint"
        static let showRomanization = "np:showRomanization"
        static let romanizationScripts = "np:romanizationScripts"
        static let showTranslation = "np:showTranslation"
        static let launchAtLoginEnabled = "np:launchAtLoginEnabled"
        static let launchMusicOnLyrimuseOpen = "np:launchMusicOnLyrimuseOpen"
        static let collectorServiceEnabled = "np:collectorServiceEnabled"
        static let showInDock = "np:showInDock"
        static let showNextLinePreview = "np:showNextLinePreview"
        static let overlayDuetAlignmentOverride = "np:overlayDuetAlignmentOverride"
        static let showLyricsInMenuBar = "np:showLyricsInMenuBar"
        static let menuBarLyricsMaxChars = "np:menuBarLyricsMaxChars"
        static let menuBarLyricsWidth = "np:menuBarLyricsMaxWidth"
        static let menuBarLyricsWidthMode = "np:menuBarLyricsWidthMode"
        static let menuBarLyricsAlignment = "np:menuBarLyricsAlignment"
        static let menuBarLyricsKaraoke = "np:menuBarLyricsKaraoke"
        static let menuBarLyricsTextColorHex = "np:menuBarLyricsTextColorHex"
        static let menuBarLyricsFillColorHex = "np:menuBarLyricsFillColorHex"
        static let menuBarIconStyle = "np:menuBarIconStyle"
        static let menuBarIconAnimates = "np:menuBarIconAnimates"
        static let lyricsOffsetStepMs = "np:lyricsOffsetStepMs"
        static let manualPickLocksLyrics = "np:manualPickLocksLyrics"
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
        // ⚠️ 作用范围**只有桌面悬浮歌词**(2026-08-31 起)。此前它连带管着灵动岛整卡的前景
        // 取色,而它的入口全挂在悬浮歌词上;现在灵动岛那一半并进了 `notchCardStyle` 的
        // 「跟随封面」选项,两边彻底独立,详见 NotchCardStyle 上方那段注释。
        static let followsCoverArt = "np:followsCoverArt"
        static let lockPosition = "np:lockPosition"
        // ⚠️ 这两个键的**作用范围只有桌面悬浮歌词**(2026-09-01 起)。此前它们是"悬浮歌词和
        // 灵动岛共用一份",用户拍板拆开(见下面 notchHide* 那两个),旧键**原样留给悬浮歌词**、
        // 不改名:改名要么丢用户已有的值,要么多写一份迁移代码,而这台机器上单用户的本地设置
        // 没必要为了名字好看付那个代价。取值范围写在 @Published 那两处的注释里。
        // (同一个处置在 `followsCoverArt` 上做过一次,那次也是保留旧键 + 注释收窄范围。)
        static let hideDuringScreenCapture = "np:hideDuringScreenCapture"
        static let hideWhenNotPlaying = "np:hideWhenNotPlaying"
        // 灵动岛自己那一份(2026-09-01 拆出来的)。⚠️ 首次读取时从上面那两个旧键**继承**,
        // 见 init() —— 拆分对老用户必须是无感的:他之前配的是"两个形态都隐藏",拆完不能
        // 变成"灵动岛不隐藏了"。
        static let notchHideDuringScreenCapture = "np:notchHideDuringScreenCapture"
        static let notchHideWhenNotPlaying = "np:notchHideWhenNotPlaying"
        static let overlayFadeOnHover = "np:overlayFadeOnHover"
        static let overlayDragNeedsLongPress = "np:overlayDragNeedsLongPress"
        static let debugHUDEnabled = "np:debugHUD"
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
        static let notchShowLyrics = "np:notchShowLyrics"
        static let notchCollapsesWhenPaused = "np:notchCollapsesWhenPaused"
        static let notchShowsEqualizer = "np:notchShowsEqualizer"
        static let notchEqualizerEar = "np:notchEqualizerEar"
        static let notchExpandedShowsNextLine = "np:notchExpandedShowsNextLine"
        static let notchExpandedShowsControls = "np:notchExpandedShowsControls"
        static let notchExpandedShowsLyricsOffset = "np:notchExpandedShowsLyricsOffset"
        static let notchExpandedShowsArtwork = "np:notchExpandedShowsArtwork"
        static let notchExpandedShowsTrackTitle = "np:notchExpandedShowsTrackTitle"
        static let notchExpandedShowsArtist = "np:notchExpandedShowsArtist"
        static let notchExpandedShowsAlbum = "np:notchExpandedShowsAlbum"
        static let notchLyricRowShowsArtwork = "np:notchLyricRowShowsArtwork"
        static let notchLyricRowArtworkPosition = "np:notchLyricRowArtworkPosition"
        static let notchLeftEar = "np:notchLeftEar"
        static let notchRightEar = "np:notchRightEar"
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
        // 平台 id → 已配对浏览器 bundle id 集合。同样存 JSON 字符串(不是 Data),理由见
        // customColorThemesJSON 上面那条注释;Set 编码出来是 JSON 数组,`defaults read`
        // 照样能看懂。
        static let browserPlatformPairsJSON = "np:browserPlatformPairsJSON"
        // 用户手动挑进来的浏览器 bundle id → 实测判定出的引擎族("chromium"/"safari")。
        // 同样存 JSON 字符串,理由同上。
        static let manualBrowserFamiliesJSON = "np:manualBrowserFamiliesJSON"
        // bundle id → 最近一次「检测是否已生效」通过的时刻。
        static let browserJSVerifiedAtJSON = "np:browserJSVerifiedAtJSON"
    }

    // 字体/字号的默认值,跟配色四项(见下方 init())一样单独给一个有名字的默认值:
    // init() 和 SettingsView"恢复默认文字与配色"按钮都读这两个,不再各自硬编码一遍数字/字符串。
    // 2026-08-17 默认字体从 PingFang SC 改成跟随系统(用户要求)。空字符串就是"跟随
    // 系统"的表示法,见 fontFamilyName 那条属性和 FontFamilyPicker。
    static let defaultFontFamilyName = ""
    static let defaultFontSize = 31.0

    // 「跟随封面」不是 ColorTheme 的字段(那份只打包配色四项,见该类型注释),默认值
    // 单独放这里——跟配色四项同一个理由:init() 和"恢复默认文字与配色"按钮都读它,
    // 不再各自硬编码一遍(2026-08-26 之前两处各自硬编码的是 false,现在都改成读这个值)。
    // 2026-08-26 从 false 改成 true(用户要求把自己实际在用的配置——跟随封面 + 打开
    // 文字描边——定为新的默认初始化配色,见 ColorTheme.defaultTheme 的注释)。
    static let defaultFollowsCoverArt = true

    // 灵动岛「重置」按钮(编辑台工具栏第一行,2026-09-01)要恢复的那一批默认值——
    // 风格 + 左右耳 + 屏幕 + 全部内容开关,不含 `notchOverlayEnabled`(总开关)和
    // `notchContentWidth`(宽度,跟悬浮歌词「重置」的既有取舍一致:结构性/尺寸设置不碰)。
    // 跟上面配色/字体那几个默认值同一个理由单独命名:init() 和重置按钮都读同一份,不再
    // 各自硬编码一遍数字/case——这批默认值这几天刚被反复调整过
    // (`notchExpandedShowsArtwork` 就在本次改动的前几轮从 true 改成过 false),两处
    // 分别硬编码会有其中一处漏改、"点了重置却恢复不出真正默认值"的风险。
    static let defaultNotchCardStyle = NotchCardStyle.coverArt
    static let defaultNotchAllScreens = false
    static let defaultNotchScreenID = ""
    static let defaultNotchLeftEar = NotchEarModule.title
    static let defaultNotchRightEar = NotchEarModule.artist
    static let defaultNotchShowLyrics = true
    static let defaultNotchCollapsesWhenPaused = true
    static let defaultNotchShowsEqualizer = true
    static let defaultNotchEqualizerEar = NotchEqualizerEar.right
    static let defaultNotchExpandedShowsNextLine = true
    static let defaultNotchExpandedShowsControls = true
    static let defaultNotchExpandedShowsLyricsOffset = false
    static let defaultNotchExpandedShowsArtwork = false
    static let defaultNotchExpandedShowsTrackTitle = false
    static let defaultNotchExpandedShowsArtist = false
    static let defaultNotchExpandedShowsAlbum = false
    static let defaultNotchLyricRowShowsArtwork = true
    static let defaultNotchLyricRowArtworkPosition = NotchLyricRowArtworkPosition.right

    // 菜单栏歌词「重置」按钮(编辑台工具栏,2026-09-01,设置页改造成编辑台风格时一并补上)
    // 要恢复的那一批默认值——宽度模式 + 逐字染色 + 文字/染色两个自定义色,不含
    // `menuBarLyricsWidth`(宽度,结构性尺寸设置)和 `showLyricsInMenuBar`(总开关),
    // 取舍跟悬浮歌词/灵动岛两个「重置」一致。同一个理由单独命名:init() 和重置按钮读
    // 同一份,不各自硬编码。
    static let defaultMenuBarLyricsWidthMode = MenuBarLyricsWidthMode.fixed
    /// 见 MenuBarLyricsAlignment:.leading 就是改动前写死的行为。
    static let defaultMenuBarLyricsAlignment = MenuBarLyricsAlignment.leading
    static let defaultMenuBarLyricsKaraoke = true
    static let defaultMenuBarLyricsTextColorHex = ""
    static let defaultMenuBarLyricsFillColorHex = ""

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
    /// 「⌘+拖拽可以挪动菜单栏图标」这条提示有没有展示过。跟 hasSeenChineseLyrics 同一种
    /// 一次性语义,但方向相反 —— 那个是"条件成立就一直显示",这个是"展示过一次就永远
    /// 不再显示"(见 MenuBarStatusItem.start() 里的调用点)。2026-09-01 加,详见
    /// AppDelegate.applicationDidFinishLaunching 里挪动状态栏项创建时机那段注释的调研结论:
    /// macOS 没有 API 能保证图标位置,唯一真正可靠的办法是引导用户自己拖拽。
    @Published var hasShownMenuBarPositionHint: Bool {
        didSet { defaults.set(hasShownMenuBarPositionHint, forKey: Keys.hasShownMenuBarPositionHint) }
    }

    /// 这台机器的用户读不读中文 —— 用系统的**首选语言列表**判,不是只看 App 界面语言:
    /// 一个把系统语言设成英文、但语言列表里加了中文的用户,照样在听中文歌。
    /// 只在启动时算一次就够了(系统语言不会在 App 运行期间变)。
    static let userReadsChinese: Bool = Locale.preferredLanguages.contains {
        $0.lowercased().hasPrefix("zh")
    }

    /// 首选语言的**第一项**具体是不是简体中文(引导页"选择播放器"排序用,见
    /// `PlaybackPlayer.onboardingDisplayOrder`)——跟上面 `userReadsChinese` 不是同一件事:
    /// 那个问的是"这个人读不读中文"(列表里任意一项含中文就算,常用来决定要不要显示某个
    /// 功能),这个问的是"排在最前面的偏好到底是简体还是繁体/别的",繁体中文(台/港/澳)
    /// 地区用户在国内三家播放器上的使用率跟英文用户更接近,不该被并进简体那一档。
    /// 判据是字符串前缀/子串匹配(跟 L10n.current 同一套朴素写法,不依赖
    /// Locale.Language.script 这类新引入 API 在不同系统版本上的推断是否可靠):
    /// 含 "hant"/"-tw"/"-hk"/"-mo" 里任意一个 → 认成繁体;剩下以 "zh" 开头的(裸 "zh"、
    /// "zh-cn"、"zh-hans"、"zh-sg" 等)→ 简体。
    static let userReadsSimplifiedChinese: Bool = {
        guard let first = Locale.preferredLanguages.first?.lowercased(), first.hasPrefix("zh") else { return false }
        let traditionalMarkers = ["hant", "-tw", "-hk", "-mo"]
        return !traditionalMarkers.contains { first.contains($0) }
    }()

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
    /// 悬浮歌词的对齐方式覆盖(2026-08-29,GitHub issue #2)。只有 `LyricsOverlayView`
    /// 读它,消费方分工见 `OverlayDuetAlignmentOverride` 声明处注释。
    @Published var overlayDuetAlignmentOverride: OverlayDuetAlignmentOverride {
        didSet {
            defaults.set(overlayDuetAlignmentOverride.rawValue, forKey: Keys.overlayDuetAlignmentOverride)
        }
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
    /// 固定宽度那一格里,装得下的短句靠哪边。见 MenuBarLyricsAlignment(含"为什么只在固定
    /// 宽度下有效果")。
    @Published var menuBarLyricsAlignment: MenuBarLyricsAlignment {
        didSet { defaults.set(menuBarLyricsAlignment.rawValue, forKey: Keys.menuBarLyricsAlignment) }
    }
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
    //
    // ⚠️ **只对桌面悬浮歌词生效**(2026-09-01 起,用户要求把「自动隐藏」这张卡从「其它」段
    // 搬进各形态自己的页面,并且拆成互相独立的两套)。灵动岛那一份是
    // `notchHideDuringScreenCapture`。**别再往这个属性上接灵动岛的调用点** —— 拆之前
    // `NotchLyricsWindowController` 和 `NotchMirrorManager` 读的都是它,现在一处都不该有了。
    @Published var hideDuringScreenCapture: Bool {
        didSet { defaults.set(hideDuringScreenCapture, forKey: Keys.hideDuringScreenCapture) }
    }
    // 暂停/没有任何曲目在播放时自动隐藏悬浮窗,恢复播放自动重新显示——跟 hideDuringScreenCapture
    // 一样只负责持久化,"生效"这一步挪到 AppDelegate(启动时)和 SettingsView.swift 的
    // Toggle Binding(运行时切换)里手动调用 LyricsOverlayWindowController.shared.
    // setHideWhenNotPlaying(_:)。默认 false,保留"不管播不播放悬浮窗都一直显示"的原有行为。
    // ⚠️ 同上,**只对桌面悬浮歌词生效**;灵动岛那一份是 `notchHideWhenNotPlaying`。
    @Published var hideWhenNotPlaying: Bool {
        didSet { defaults.set(hideWhenNotPlaying, forKey: Keys.hideWhenNotPlaying) }
    }
    // 灵动岛自己的两个「自动隐藏」开关(2026-09-01 从上面那两个拆出来)。
    //
    // 拆分的理由:这张卡原来挂在「其它」那一段,因为它是跨形态的规则、"放进任何一个单独
    // 形态里都不对"。用户要求取消「其它」这一段、把卡搬进两个形态各自的页面 —— 一旦按
    // 形态分栏展示,用户就会**按形态去理解**它("我在灵动岛页面关掉的,当然只关灵动岛"),
    // 继续共用一份就是个必然踩的坑。所以是真拆成两份值,不是同一份显示两次。
    //
    // 语义、默认值、生效方式跟上面那两个完全一致(只负责持久化,"生效"在
    // AppDelegate 启动时和设置页 Toggle Binding 里手动调 `NotchLyricsWindowController`)。
    @Published var notchHideDuringScreenCapture: Bool {
        didSet { defaults.set(notchHideDuringScreenCapture, forKey: Keys.notchHideDuringScreenCapture) }
    }
    @Published var notchHideWhenNotPlaying: Bool {
        didSet { defaults.set(notchHideWhenNotPlaying, forKey: Keys.notchHideWhenNotPlaying) }
    }
    // 指针划过悬浮歌词时让它淡下去,离开再恢复。**只对桌面悬浮歌词生效**(灵动岛贴在刘海
    // 上、hover 是它展开的手势,让开会互相打架)。
    //
    // 它跟「点击穿透」解的是同一个痛点的两半:穿透保证"点得到下层",这个保证"看得到下层"。
    // 开了背景卡片或把字号调大之后,悬浮窗仍会实打实盖住下面窗口的内容,而穿透对此无能为力。
    //
    // ⚠️ 开着它会改变鼠标监听器的生命周期:见 LyricsOverlayWindowController.syncMouseMonitors
    // ——「锁定位置」原本会把监听器整个卸掉,而"锁定位置 + 划过让开"恰恰是最常见的组合。
    // 只负责持久化,"生效"在 controller 那边(它直读这个开关)。默认 false,保留原有行为。
    @Published var overlayFadeOnHover: Bool {
        didSet { defaults.set(overlayFadeOnHover, forKey: Keys.overlayFadeOnHover) }
    }
    /// 拖动悬浮歌词前要不要先长按 0.35 秒。
    ///
    /// 长按这道门原本是**必须**的:窗口常年点击穿透,而"按下就拖"会让整个窗口区域都吃掉
    /// 点击、点不到下面的东西。2026-08-23 精准歌词热区落地后这个前提变了 —— 关掉它时
    /// 只有**压在歌词文字上**才立刻武装拖动,四周空白照旧穿透,所以不再需要用时长去区分
    /// "想拖窗口"和"想点桌面"。
    ///
    /// 默认 false(按住歌词直接拖)。代价说清楚:压在字上的那一次点击会被窗口吃掉,
    /// 穿不到下层 —— 想保留"点哪儿都能穿透、只有长按才拖"的旧行为就打开它。
    @Published var overlayDragNeedsLongPress: Bool {
        didSet { defaults.set(overlayDragNeedsLongPress, forKey: Keys.overlayDragNeedsLongPress) }
    }
    // 调试 HUD:在悬浮歌词角落显示实测帧率(FrameRateProbe)。
    //
    // **刻意不进设置界面** —— 它是给开发/排障用的,不是功能。开:
    //     defaults write me.yudaotor.lyrimuse np:debugHUD -bool true
    // 然后重开悬浮歌词(或重启 App)。理由见 FrameRateProbe 的类型注释:这个项目最贵的两个
    // 渲染结论都靠一次性外部探针量出来,量完就没了,以后重试排程式填色还得再搭一次。
    @Published var debugHUDEnabled: Bool {
        didSet { defaults.set(debugHUDEnabled, forKey: Keys.debugHUDEnabled) }
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
    // 「联网搜索候选歌词」采纳一条候选时,要不要把这首歌标成"人工修正"(manual_lyrics)
    // 永久冻结、拒绝以后所有自动升级(打分改进/该源后来给出逐字/换了更好的源)。
    // 2026-09-01 用户要求把这个决定权交出来——有人确实想要"选一次就再也不许自动换"的
    // 强保证。默认 false。
    //
    // 严格两态,中间不留东西:
    //   false → 采纳只是"当下换上这份",缓存里一个约束标记都不写(saveEdit 收到
    //           `sourceChoice: ""`,把可能残留的 lyrics_source_choice 显式清掉),之后
    //           打分改进/升级重试照常调整这首歌,**也可以换成别的源**;
    //   true  → 置 manual_lyrics,collector 三条自愈路径(firstFill/rescore/retry)第一行
    //           就否决,这首歌定死在这份内容上。
    //
    // ⚠️ 2026-08-22 到 2026-09-01 之间 false 态并不是"什么都不写":它会记下
    // lyrics_source_choice,自愈照跑但被约束在所选源内(collector 侧
    // pickLyricCandidatePreferring)。用户看到设置里写出来的说明后当场否掉了这个中间态,
    // 明确要"关 = 不限制源"。别再把它加回来——完整来龙去脉见 LyricsManagerView.swift
    // 「采纳候选」调用点的注释。
    //
    // 只影响"采纳候选"这一条路径("重新自动匹配"是算法自己的选择,跟这个开关无关,永远
    // 不冻结;直接编辑歌词正文的"保存修改"永远置为 true,跟这个开关也无关——那份内容
    // 删了找不回来,自动逻辑没理由觉得自己比人工更懂)。
    //
    // **翻面时会追溯处理存量**(2026-09-01 用户要求:"关着的时候手动选的,开关开启后要
    // 自动变为锁定状态"):打开 → 把"手动采纳过、且当前内容还是当初采纳那一份"的歌一并
    // 置 manual_lyrics;关掉 → 弹一次确认,问要不要把因它而锁的那批解开(不默认解,也不
    // 默认留——两种意图都讲得通,而目前没有单曲解锁入口,猜错的代价是逐首点「重新自动
    // 匹配」、连歌词内容一起被换掉)。判据见 LyrimuseCore/ManualPickLock.shouldFlip,
    // 留痕字段是 `manual_pick_sha`,批量落地在 EnrichCacheStore.applyManualPickLock。
    // ⚠️ 这个联动挂在 SettingsView 的 Toggle setter 上,不在下面的 didSet 里 —— 理由见
    // 那处注释(要弹框/要回执;而且 didSet 会被配置导入顺带触发)。
    @Published var manualPickLocksLyrics: Bool {
        didSet { defaults.set(manualPickLocksLyrics, forKey: Keys.manualPickLocksLyrics) }
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
    // 稳态/展开那一行左右两只耳朵各显示什么(见 NotchEarModule)。跟 notchCardStyle 同一个
    // 模式:纯持久化,NotchLyricsView 每次渲染直接读,不需要连带调窗口控制器"生效"——它们
    // 只改这一行画什么,不改任何几何。
    // 默认 title / artist = 改动前写死的那一套,老用户升上来观感逐像素不变。
    /// 灵动岛要不要画歌词行(2026-08-31 用户要求:「多一种形态,对于有一些想要显示播放状态、
    /// 但又不想有歌词挡住视线的人」)。关掉之后卡片**只保留菜单栏那条高度**(顶行那一条),
    /// 歌词行连同它那 44pt 一起不渲染 —— 于是灵动岛退化成一条贴着刘海的状态栏,不遮任何东西。
    /// hover 展开完全不受影响(那是够到播放控制和进度条的唯一入口):播放控制、进度条、下一句
    /// 歌词预览、当前播放行照常显示,跟开着这个开关时一模一样(2026-08-31 回归修复,见
    /// NotchChromeSource.showsLyricRow 的注释)。
    ///
    /// ⚠️ 判据本身**必须经 `NotchChromeSource.showsLyrics`/`showsLyricRow` 走**,不许在视图里
    /// 直接读这个属性:卡片高度(NotchWindowRoot)、内容渲染(NotchLyricsView)、设置页编辑台
    /// 三处要用同一个值,而后两者拿到的是替身 chrome。三处各读各的必然漂,漂的表现是"行不见了
    /// 高度还留着"。
    @Published var notchShowLyrics: Bool {
        didSet { defaults.set(notchShowLyrics, forKey: Keys.notchShowLyrics) }
    }
    /// 暂停(或广告插播)时灵动岛要不要缩到最小 —— 只剩贴着刘海的一小块,两只耳朵退化成
    /// "左封面、右音浪"的 iPhone 灵动岛式极简形态(2026-08-19 用户拍板过这个默认形态,
    /// 2026-08-31 用户要求把它开放成可关闭的配置项)。关掉之后暂停时卡片保持原来的稳态/
    /// 展开尺寸不收缩,跟正常播放时一样显示歌名/歌词(位置冻结在暂停那一刻)。
    ///
    /// 默认 `true`——维持这个功能一直以来的既有行为,老用户升上来观感不变,只是现在能关了。
    ///
    /// ⚠️ 判据本身**必须经 `NotchLyricsWindowController.isCollapsed` 走**(同上面 showsLyrics
    /// 那条纪律):真窗口那一侧订阅这个设置后镜像成 `@Published`,不在计算属性里直接读
    /// AppSettings——那样设置一改,依赖 isCollapsed 的视图不会立刻收到 objectWillChange。
    @Published var notchCollapsesWhenPaused: Bool {
        didSet { defaults.set(notchCollapsesWhenPaused, forKey: Keys.notchCollapsesWhenPaused) }
    }
    /// 要不要显示播放指示条(音浪)。默认 `true`——维持一直以来的既有行为,老用户升上来
    /// 观感不变。关掉之后两只耳朵都只按各自选的模块渲染,不再固定带音浪(见
    /// NotchLyricsView.topRow 头上那段⚠️)。
    @Published var notchShowsEqualizer: Bool {
        didSet { defaults.set(notchShowsEqualizer, forKey: Keys.notchShowsEqualizer) }
    }
    /// 音浪贴哪只耳朵的外缘。默认 `.right`——维持一直以来的既有行为(音浪原来写死在右耳)。
    @Published var notchEqualizerEar: NotchEqualizerEar {
        didSet { defaults.set(notchEqualizerEar.rawValue, forKey: Keys.notchEqualizerEar) }
    }

    // MARK: - 展开态(2026-09-01)
    //
    // hover 展开区原来只有"下一句歌词预览 + 迷你进度条 + 三键",这一组给用户开放了两类
    // 自定义:①下一句预览本身能不能关(它以前无条件跟着"这首歌有没有下一句"这个数据出现,
    // 现在多一层用户开关,两者要同时成立才画,见 NotchChromeSource.showsExpandedLyricPreview);
    // ②新增一块可选的"曲目信息头部"(封面 + 歌名/歌手/专辑,四项独立开关),解决"两只耳朵
    // 都配成非文本模块(比如剩余时长)时,hover 展开也看不出是哪首歌"这个缺口。
    //
    // ⚠️ 头部里的封面(`notchExpandedShowsArtwork`)落点反复过:最初设计里就带一枚,用户
    // 看过效果后指出"跟歌词行末尾已有的那枚封面重复了",要求并回那一枚(见下面
    // `notchLyricRowShowsArtwork` / `notchLyricRowArtworkPosition`,那两项不属于这个
    // "展开态"分组——歌词行那枚封面稳态/展开都常显,不是 hover 才有的东西);过了几轮之后
    // 用户又要求"在展开态里面多增加一个显示封面",重新给头部配上**自己**的一枚——这次没有
    // 位置四选一,固定贴文字块左边(用户参照图就是"封面居左+文字居右"),两枚封面(歌词行
    // 尾端一枚、曲目信息头部左边一枚)因此是两个独立开关、可以同时开,不算走回头路:上次
    // 撤掉是因为"同一处画两次",这次是用户明确要求"两处都要"。

    /// 下一句歌词预览开关。默认 `true`——维持这个功能一直以来的既有行为(以前无条件显示,
    /// 现在能关了)。
    @Published var notchExpandedShowsNextLine: Bool {
        didSet { defaults.set(notchExpandedShowsNextLine, forKey: Keys.notchExpandedShowsNextLine) }
    }
    /// 展开区那一排播放控制键(上一首/播放暂停/下一首)开关(2026-09-01,用户要求"加一个
    /// 控制键是否展示")。默认 `true`——这排键 2026-08-19 从右耳搬进展开卡以来一直无条件
    /// 显示,第一次开放成可关的配置项,升级上来的用户观感不变。
    ///
    /// 关掉之后不是唯一的死胡同:`NotchEarModule` 本来就有「播放控制」这个选项(耳朵模块
    /// 八选一之一),想要一个不用 hover 就能点的入口,配一只耳朵成「播放控制」即可——两条
    /// 路一直并存,这个开关只是让"展开区里还要不要重复画一遍"变成用户能自己关的选择。
    @Published var notchExpandedShowsControls: Bool {
        didSet { defaults.set(notchExpandedShowsControls, forKey: Keys.notchExpandedShowsControls) }
    }
    /// 展开区进度条下面那行时间数字中间要不要显示"歌词时间轴微调"(2026-09-01,用户要求
    /// "把调整歌词的也加进去")——跟菜单栏面板里那颗「− 歌词±0.5s +」是同一份功能
    /// (`PlaybackCoordinator.nudgeLyricsOffset`/`resetLyricsOffset`),只是多了一个灵动岛
    /// 入口。默认 `false`——这块内容以前不存在,升级上来的用户不该无缘无故多出一截没见过的
    /// UI,想要的人自己去「展开态」浮层里开(跟 `notchExpandedShowsArtwork` 那批同一个理由)。
    ///
    /// ⚠️ 这个开关**只影响渲染,不影响高度**——按钮塞进的是时间行中间本来就空着的位置
    /// (`NotchScrubber` 的时间行左右两个时间数字之间,`HStack` 里原来是个 `Spacer()`),
    /// 按钮尺寸被刻意收窄到跟这一行本来的高度齐平,不会把行撑高,所以跟 `notchExpandedShowsNextLine`/
    /// `notchExpandedShowsControls` 那批不一样,**不需要**过 `NotchChromeSource`/
    /// `NotchExpandedMetrics` 那整套几何链路——走 `NotchPlayback` 现读即可(跟
    /// `notchLyricRowShowsArtwork` 同一个模式,理由见那个属性上面的注释)。
    @Published var notchExpandedShowsLyricsOffset: Bool {
        didSet { defaults.set(notchExpandedShowsLyricsOffset, forKey: Keys.notchExpandedShowsLyricsOffset) }
    }
    /// 曲目信息头部:封面缩略图,固定贴文字块左边。默认 `false`——这块内容以前不存在,
    /// 升级上来的用户不该无缘无故多出一截没见过的 UI,想要的人自己去「展开态」浮层里开。
    @Published var notchExpandedShowsArtwork: Bool {
        didSet { defaults.set(notchExpandedShowsArtwork, forKey: Keys.notchExpandedShowsArtwork) }
    }
    /// 曲目信息头部:歌名。默认 `false`,理由同上。
    @Published var notchExpandedShowsTrackTitle: Bool {
        didSet { defaults.set(notchExpandedShowsTrackTitle, forKey: Keys.notchExpandedShowsTrackTitle) }
    }
    /// 曲目信息头部:歌手。默认 `false`,理由同上。
    @Published var notchExpandedShowsArtist: Bool {
        didSet { defaults.set(notchExpandedShowsArtist, forKey: Keys.notchExpandedShowsArtist) }
    }
    /// 曲目信息头部:专辑。默认 `false`,理由同上。
    @Published var notchExpandedShowsAlbum: Bool {
        didSet { defaults.set(notchExpandedShowsAlbum, forKey: Keys.notchExpandedShowsAlbum) }
    }

    /// 歌词行(`NotchLyricsView.lyricRowContent`)末尾那枚封面缩略图要不要显示。
    /// 默认 `true`——这枚封面 2026-08-05 就有,2026-08-10 用户还曾要求去掉开关、固定
    /// 显示,这次重新给它开开关必须保 true 默认值,不然升级上来的用户会发现封面凭空
    /// 消失。稳态/展开两种形态都受这个开关影响(它本来就是稳态歌词行的一部分,不是
    /// hover 才出现的内容)。
    @Published var notchLyricRowShowsArtwork: Bool {
        didSet { defaults.set(notchLyricRowShowsArtwork, forKey: Keys.notchLyricRowShowsArtwork) }
    }
    /// 这枚封面贴歌词行的左边(歌词前面)还是右边(歌词后面,= 一直以来的既有位置)。
    /// 默认 `.right`,保住既有行为逐像素不变。
    @Published var notchLyricRowArtworkPosition: NotchLyricRowArtworkPosition {
        didSet { defaults.set(notchLyricRowArtworkPosition.rawValue, forKey: Keys.notchLyricRowArtworkPosition) }
    }

    @Published var notchLeftEar: NotchEarModule {
        didSet { defaults.set(notchLeftEar.rawValue, forKey: Keys.notchLeftEar) }
    }
    @Published var notchRightEar: NotchEarModule {
        didSet { defaults.set(notchRightEar.rawValue, forKey: Keys.notchRightEar) }
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
    // 设置页"浏览器歌词同步"卡片:哪个网页音乐平台(BrowserPositionProbe.supportedPlatforms
    // 的 id)配对了哪些浏览器(FeatureSettingsStore.trustedPlayers 的 bundle id)。只是
    // AppSettings 这边的持久化——真正让探针生效要靠 SettingsView 双写进
    // BrowserPositionProbe.shared.platformBrowserPairs(跟 romanizationScripts 同一个模式,
    // 见那边注释),这个属性本身不会被 LyrimuseCore 直接读到。
    @Published var browserPlatformPairs: [String: Set<String>] {
        didSet {
            let json = (try? JSONEncoder().encode(browserPlatformPairs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            defaults.set(json, forKey: Keys.browserPlatformPairsJSON)
        }
    }

    // 用户自己从「应用程序」里挑进来的浏览器(2026-08-31,用户:「这里点+号出来的是否可以加
    // 一个选项是自己在本机的应用程序里面选」)。bundle id → 引擎族的 rawValue。
    //
    // 存的是**判定结果**而不是"用户加过这个 App":引擎族是靠读那个 App 的脚本定义现场判出来的
    // (BrowserAutomationPermission.detectedFamily),把结论存下来,免得每次启动都去磁盘上
    // 重读一遍别人的 bundle。App 被卸载/换成别的版本时最坏是多留一条无效记录 —— 而
    // `isInstalled` 这道门会让它不出现在任何候选里,不会有实际影响。
    //
    // 跟 browserPlatformPairs 同一个模式:这边只管持久化,运行期要靠调用点双写进
    // BrowserAutomationPermission.manuallyAddedFamilies(启动时在 AppDelegate 灌一次)。
    @Published var manualBrowserFamilies: [String: String] {
        didSet {
            let json = (try? JSONEncoder().encode(manualBrowserFamilies)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            defaults.set(json, forKey: Keys.manualBrowserFamiliesJSON)
        }
    }

    // 浏览器那道 JS 开关最近一次**被实测证明可用**的时刻(bundle id → 时间)。
    //
    // ⚠️ 存这个是因为那道开关的状态**根本读不出来** —— Chromium 系存在浏览器 profile 的
    // `Preferences` 里,别的 App 读那个目录要「完全磁盘访问权限」。于是设置页只能永远显示
    // 「无法确认状态」,用户手动开完没有任何反馈,每次重开设置又回到原点(用户原话:
    // 「然后呢,状态怎么进一步流转?卡在这里」)。
    //
    // ⚠️ 它记的是**"某时刻实测通过"这个事实**,不是"现在一定还开着" —— 用户后来把开关
    // 关掉我们无从得知。所以 UI 上一律带着"上次检测"的口径说,并且永远保留重新检测的入口,
    // 不许写成"已开启"这种断言当下的说法。这条是今晚被粘滞状态坑过四次之后立的规矩。
    @Published var browserJSVerifiedAt: [String: Date] {
        didSet {
            let json = (try? JSONEncoder().encode(browserJSVerifiedAt)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            defaults.set(json, forKey: Keys.browserJSVerifiedAtJSON)
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
        hasShownMenuBarPositionHint = defaults.bool(forKey: Keys.hasShownMenuBarPositionHint)
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
        overlayDuetAlignmentOverride = defaults.string(forKey: Keys.overlayDuetAlignmentOverride)
            .flatMap(OverlayDuetAlignmentOverride.init(rawValue:)) ?? .automatic
        showLyricsInMenuBar = (defaults.object(forKey: Keys.showLyricsInMenuBar) as? Bool) ?? false
        menuBarLyricsMaxChars = (defaults.object(forKey: Keys.menuBarLyricsMaxChars) as? Int) ?? 60
        // 默认 200pt:大约中文 15 个字、英文 30 个字,菜单栏上占一小条,不至于把右边
        // 其它 App 的图标挤走。
        menuBarLyricsWidth = CGFloat(
            (defaults.object(forKey: Keys.menuBarLyricsWidth) as? Double) ?? 200)
        // 默认 fixed:2026-08-17 到加这个开关之间,固定宽度是写死的唯一行为,默认值
        // 保持它,升级上来的用户看不出任何变化。
        menuBarLyricsWidthMode = defaults.string(forKey: Keys.menuBarLyricsWidthMode)
            .flatMap(MenuBarLyricsWidthMode.init(rawValue:)) ?? Self.defaultMenuBarLyricsWidthMode
        menuBarLyricsAlignment = defaults.string(forKey: Keys.menuBarLyricsAlignment)
            .flatMap(MenuBarLyricsAlignment.init(rawValue:)) ?? Self.defaultMenuBarLyricsAlignment
        // 默认开:这是把"当前唱到哪"带进菜单栏的增量信息,且只在有逐字数据时出现;
        // 菜单栏歌词本身默认关着,不存在"谁都没选就改变观感"的问题。
        menuBarLyricsKaraoke = (defaults.object(forKey: Keys.menuBarLyricsKaraoke) as? Bool) ?? Self.defaultMenuBarLyricsKaraoke
        menuBarLyricsTextColorHex = defaults.string(forKey: Keys.menuBarLyricsTextColorHex) ?? Self.defaultMenuBarLyricsTextColorHex
        menuBarLyricsFillColorHex = defaults.string(forKey: Keys.menuBarLyricsFillColorHex) ?? Self.defaultMenuBarLyricsFillColorHex
        menuBarIconStyle = defaults.string(forKey: Keys.menuBarIconStyle)
            .flatMap(MenuBarIconStyle.init(rawValue:)) ?? .default
        menuBarIconAnimates = (defaults.object(forKey: Keys.menuBarIconAnimates) as? Bool) ?? true
        lyricsOffsetStepMs = (defaults.object(forKey: Keys.lyricsOffsetStepMs) as? Int) ?? 200
        manualPickLocksLyrics = (defaults.object(forKey: Keys.manualPickLocksLyrics) as? Bool) ?? false
        textStrokeEnabled = (defaults.object(forKey: Keys.textStrokeEnabled) as? Bool) ?? ColorTheme.defaultTheme.textStrokeEnabled
        textStrokeColorHex = defaults.string(forKey: Keys.textStrokeColorHex) ?? ColorTheme.defaultTheme.textStrokeColorHex
        lockPosition = (defaults.object(forKey: Keys.lockPosition) as? Bool) ?? false
        overlayFadeOnHover = (defaults.object(forKey: Keys.overlayFadeOnHover) as? Bool) ?? false
        overlayDragNeedsLongPress =
            (defaults.object(forKey: Keys.overlayDragNeedsLongPress) as? Bool) ?? false
        debugHUDEnabled = (defaults.object(forKey: Keys.debugHUDEnabled) as? Bool) ?? false
        // ⚠️ 灵动岛那两个的**兜底不是 false,而是悬浮歌词那一份的值**(2026-09-01 拆分时的
        // 迁移)。拆之前两个形态共用一份,老用户如果配的是"截屏时隐藏",拆完必须两边都还
        // 隐藏 —— 兜底写 false 的话,他的灵动岛会在某次升级后**悄悄开始出现在截图里**,而他
        // 什么都没改过。这类"静默放宽一条隐私设置"的迁移事故没有补救机会:截出去的图收不回来。
        //
        // ⚠️ 用局部变量而不是直接读 `self.hideDuringScreenCapture`:类的 init 在所有存储
        // 属性都赋值完之前不准碰 self,那样写编译不过("used before being initialized")。
        let legacyHideDuringCapture = (defaults.object(forKey: Keys.hideDuringScreenCapture) as? Bool) ?? false
        let legacyHideWhenNotPlaying = (defaults.object(forKey: Keys.hideWhenNotPlaying) as? Bool) ?? false
        hideDuringScreenCapture = legacyHideDuringCapture
        hideWhenNotPlaying = legacyHideWhenNotPlaying
        notchHideDuringScreenCapture =
            (defaults.object(forKey: Keys.notchHideDuringScreenCapture) as? Bool) ?? legacyHideDuringCapture
        notchHideWhenNotPlaying =
            (defaults.object(forKey: Keys.notchHideWhenNotPlaying) as? Bool) ?? legacyHideWhenNotPlaying
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
        notchCardStyle = defaults.string(forKey: Keys.notchCardStyle)
            .flatMap(NotchCardStyle.init(rawValue:)) ?? Self.defaultNotchCardStyle
        notchShowLyrics = (defaults.object(forKey: Keys.notchShowLyrics) as? Bool) ?? Self.defaultNotchShowLyrics
        notchCollapsesWhenPaused = (defaults.object(forKey: Keys.notchCollapsesWhenPaused) as? Bool)
            ?? Self.defaultNotchCollapsesWhenPaused
        notchShowsEqualizer = (defaults.object(forKey: Keys.notchShowsEqualizer) as? Bool) ?? Self.defaultNotchShowsEqualizer
        notchEqualizerEar = defaults.string(forKey: Keys.notchEqualizerEar)
            .flatMap(NotchEqualizerEar.init(rawValue:)) ?? Self.defaultNotchEqualizerEar
        notchExpandedShowsNextLine = (defaults.object(forKey: Keys.notchExpandedShowsNextLine) as? Bool)
            ?? Self.defaultNotchExpandedShowsNextLine
        notchExpandedShowsControls = (defaults.object(forKey: Keys.notchExpandedShowsControls) as? Bool)
            ?? Self.defaultNotchExpandedShowsControls
        notchExpandedShowsLyricsOffset = (defaults.object(forKey: Keys.notchExpandedShowsLyricsOffset) as? Bool)
            ?? Self.defaultNotchExpandedShowsLyricsOffset
        notchExpandedShowsArtwork = (defaults.object(forKey: Keys.notchExpandedShowsArtwork) as? Bool)
            ?? Self.defaultNotchExpandedShowsArtwork
        notchExpandedShowsTrackTitle = (defaults.object(forKey: Keys.notchExpandedShowsTrackTitle) as? Bool)
            ?? Self.defaultNotchExpandedShowsTrackTitle
        notchExpandedShowsArtist = (defaults.object(forKey: Keys.notchExpandedShowsArtist) as? Bool)
            ?? Self.defaultNotchExpandedShowsArtist
        notchExpandedShowsAlbum = (defaults.object(forKey: Keys.notchExpandedShowsAlbum) as? Bool)
            ?? Self.defaultNotchExpandedShowsAlbum
        notchLyricRowShowsArtwork = (defaults.object(forKey: Keys.notchLyricRowShowsArtwork) as? Bool)
            ?? Self.defaultNotchLyricRowShowsArtwork
        notchLyricRowArtworkPosition = defaults.string(forKey: Keys.notchLyricRowArtworkPosition)
            .flatMap(NotchLyricRowArtworkPosition.init(rawValue:)) ?? Self.defaultNotchLyricRowArtworkPosition
        notchLeftEar = defaults.string(forKey: Keys.notchLeftEar)
            .flatMap(NotchEarModule.init(rawValue:)) ?? Self.defaultNotchLeftEar
        notchRightEar = defaults.string(forKey: Keys.notchRightEar)
            .flatMap(NotchEarModule.init(rawValue:)) ?? Self.defaultNotchRightEar
        notchAllScreens = (defaults.object(forKey: Keys.notchAllScreens) as? Bool) ?? Self.defaultNotchAllScreens
        notchScreenID = defaults.string(forKey: Keys.notchScreenID) ?? Self.defaultNotchScreenID
        fontFamilyName = defaults.string(forKey: Keys.fontFamilyName) ?? Self.defaultFontFamilyName
        fontSize = (defaults.object(forKey: Keys.fontSize) as? Double) ?? Self.defaultFontSize
        overlayWidth = (defaults.object(forKey: Keys.overlayWidth) as? Double) ?? 640
        notchContentWidth = (defaults.object(forKey: Keys.notchContentWidth) as? Double) ?? 360
        foregroundColorHex = defaults.string(forKey: Keys.foregroundColorHex) ?? ColorTheme.defaultTheme.foregroundColorHex
        backgroundColorHex = defaults.string(forKey: Keys.backgroundColorHex) ?? ColorTheme.defaultTheme.backgroundColorHex
        followsCoverArt = (defaults.object(forKey: Keys.followsCoverArt) as? Bool) ?? Self.defaultFollowsCoverArt
        if let json = defaults.string(forKey: Keys.customColorThemesJSON),
           let data = json.data(using: .utf8),
           let themes = try? JSONDecoder().decode([ColorTheme].self, from: data) {
            customColorThemes = themes
        } else {
            customColorThemes = []
        }
        if let json = defaults.string(forKey: Keys.browserPlatformPairsJSON),
           let data = json.data(using: .utf8),
           let pairs = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            browserPlatformPairs = pairs
        } else {
            browserPlatformPairs = [:]
        }
        if let json = defaults.string(forKey: Keys.manualBrowserFamiliesJSON),
           let data = json.data(using: .utf8),
           let families = try? JSONDecoder().decode([String: String].self, from: data) {
            manualBrowserFamilies = families
        } else {
            manualBrowserFamilies = [:]
        }
        if let json = defaults.string(forKey: Keys.browserJSVerifiedAtJSON),
           let data = json.data(using: .utf8),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            browserJSVerifiedAt = map
        } else {
            browserJSVerifiedAt = [:]
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
