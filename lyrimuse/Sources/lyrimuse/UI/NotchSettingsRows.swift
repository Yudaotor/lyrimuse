import AppKit
import Combine
import LyrimuseCore
import SwiftUI

// MARK: - 工具栏摘要

/// 「屏幕」那颗按钮上的摘要。
///
/// 不能存成 `static let`:`L10n.t` 要在每次取值时现算,存进 static let 等于把首次访问时的
/// 语言冻在里面(同 OverlayAlignmentSegmentedControl.label(for:) 那条)。
@MainActor
enum NotchScreenSummary {
    static var current: String {
        let settings = AppSettings.shared
        if settings.notchAllScreens { return L10n.t("全部屏幕") }
        if settings.notchFollowsActiveScreen { return L10n.t("跟随当前窗口") }
        if settings.notchScreenID.isEmpty { return L10n.t("自动") }
        if let screen = ScreenIdentity.screen(withID: settings.notchScreenID) {
            return screen.localizedName
        }
        // 存着的那块屏现在没接着。报"自动"是撒谎(偏好还在,屏幕插回来就会恢复),
        // 报一个空串更糟。
        return L10n.t("已断开的屏幕")
    }
}

// MARK: - 「风格」浮层

/// 「✦ 风格」浮层。四种卡片背景四选一,下面两行「圆角 / 展开圆角」,最后一行「进度线」。
///
/// 用**单选列表**而不是 `.pickerStyle(.menu)` 下拉,有两个具体理由:
///   ① 菜单点一次只能试一个:选中即收起,想比较四种就得开合四次。列表在浮层里点完**不关**,
///      浮层比舞台窄,四种风格可以点着看过去。这正是编辑台范式要的东西(改一项、当场看见)。
///   ② 下拉是"把一个 NSMenu 开在一个 transient NSPopover 里",两层的关闭时机得靠系统巧合
///      对齐;单选列表全在浮层自己这一层,没有这层不确定性。
/// 代价是四行比一行下拉高,纵向有的是空间。
///
/// 宽度 440 是给圆角那两行的(英文行名「Expanded Corners」+ 100pt 滑杆 + 92pt 读数菜单)。
@MainActor
struct NotchStylePopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("风格"), width: 440) {
            NotchStyleSettingsRows()
        }
    }
}

/// 「显示歌词」开关(「多一种形态,对于有一些想要显示播放状态、但又不想
/// 有歌词挡住视线的人」)。关掉之后卡片只剩顶行那一条,退化成贴着刘海的状态栏。
///
/// 从「风格」浮层里搬出来,单独放在编辑台下面自己一张卡("不要合并到
/// 风格里面去")——它跟四种背景不是同一类东西:一个是卡片长什么样、一个是卡片还剩几行,
/// 值得有自己独立的位置。放在设置页正常流里而不是再开一个工具栏入口,理由不变:工具栏
/// 横向空间已经被四个入口占满(窄窗约 499pt,见 toolbar 那段横向账)。
@MainActor
struct NotchShowLyricsRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.alignleft",
            title: L10n.t("收起时显示歌词"),
            help: L10n.t("关闭后，常态下仅保留刘海高度，不显示歌词；指针悬停展开时，播放控制、进度条和下一句预览仍照常显示")
        ) {
            Toggle("", isOn: $settings.notchShowLyrics)
        }
    }
}

/// 「暂停时缩到最小」开关(广告时另有「广告时收起」)。关掉之后暂停时卡片不再收缩,保持稳态/展开尺寸,歌名/歌词照常显示(位置冻结在暂停那一刻)。
///
/// 跟 `NotchShowLyricsRow` 放在同一张卡里(见调用点):两者都是"暂停/播放时卡片还剩多少
/// 内容"这一类设置,跟「风格」浮层里那四种背景不是一回事,值得分在一起但各自一行。
@MainActor
struct NotchCollapsesWhenPausedRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "arrow.down.right.and.arrow.up.left",
            title: L10n.t("暂停时收起")
        ) {
            Toggle("", isOn: $settings.notchCollapsesWhenPaused)
        }
    }
}

/// 四种风格的单选列表。行的度量(图标列宽 / 间距 / 内边距)一律走 `SettingsRowMetrics`,
/// 跟同一张浮层里别的行对齐 —— 别在这里写字面量。
@MainActor
struct NotchStyleSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    /// 圆角两行读写的是这一份(拖动中的值在这里,松手才写回 AppSettings,见 `NotchCornerLive`)。
    @ObservedObject private var corners = NotchCornerLive.shared
    /// 只用来按编辑台预览那套口径算这块屏上两种形态的卡片高度(`cardHeight(expanded:)`,全仓唯一那份公式),
    /// 给圆角滑杆定上限、给「默认」算读数。不碰 `NotchLyricsWindowController.shared`(理由见 NotchPreviewChrome)。
    @StateObject private var card = NotchPreviewChrome()

    // 一框:背景是一行下拉(四种风格选其一),下面两个圆角。浮层往上弹、高度有限,四行单选列表会把它撑到要滚动。
    var body: some View {
        SettingsRowGroup {
            VStack(spacing: 0) {
                SettingsRow(icon: "paintbrush", title: L10n.t("背景")) {
                    // 玻璃下拉不用分段:英文四档(Solid Black / Frosted Glass / …)在这个浮层里放不下。
                    // 顺序直接用 allCases(声明序),不另抄一份数组 —— 抄一份的话以后往枚举里加一种
                    // 风格,这里不加就是"设置里选不到的合法值"。
                    SettingsGlassMenuPicker(
                        selection: Binding(
                            get: { settings.notchCardStyle },
                            set: { style in
                                // 相等守卫:@Published 是 willSet 语义,等值赋值照样广播 objectWillChange 打醒
                                // 所有观察 AppSettings 的界面,didSet 还会白写一次 UserDefaults。
                                guard settings.notchCardStyle != style else { return }
                                settings.notchCardStyle = style
                            }),
                        options: NotchCardStyle.allCases,
                        label: \.displayName,
                        compact: true
                    )
                }
                CardDivider()
                cornerRadiusRow(icon: "square.bottomhalf.filled", title: L10n.t("圆角"), slot: .collapsed,
                                cardHeight: card.cardHeight(expanded: false))
                CardDivider()
                cornerRadiusRow(icon: "rectangle.bottomhalf.filled", title: L10n.t("展开圆角"), slot: .expanded,
                                cardHeight: card.cardHeight(expanded: true))
                CardDivider()
                SettingsRow(icon: "minus", title: L10n.t("进度线"), help: L10n.t("未展开时显示播放进度")) {
                    SettingsGlassMenuPicker(
                        selection: Binding(
                            get: {
                                NotchProgressLineChoice(shows: settings.notchShowsProgressLine,
                                                        style: settings.notchProgressLineStyle)
                            },
                            set: { choice in
                                // 相等守卫,理由同上面的背景下拉。
                                if let style = choice.style, settings.notchProgressLineStyle != style {
                                    settings.notchProgressLineStyle = style
                                }
                                if settings.notchShowsProgressLine != choice.shows {
                                    settings.notchShowsProgressLine = choice.shows
                                }
                            }),
                        options: NotchProgressLineChoice.allCases,
                        label: \.displayName,
                        compact: true
                    )
                }
            }
        }
        // 拖到一半、或指针还停在行上时这一页没了(浮层被关、抽屉收起):值写回去,预览也别停在摆出来的那一态上。
        .onDisappear {
            corners.endDrag()
            corners.clearHover()
        }
        // 插拔显示器时刘海高度会变,滑杆上限和读数跟着重算(同 NotchEditorStage 对自己那份 chrome 的处理)。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            card.refreshGeometry()
        }
    }

    /// 一行圆角:滑杆拖动就变成固定值(读数写 pt);右边菜单选「默认」(按卡片高度算)或「跟随刘海」
    /// (机器刘海本身的底角,两态同一个值),读数写模式名、滑杆停在那个模式此刻的值上。
    ///
    /// 滑杆上限是这一态的卡片画得出的最大圆角(`NotchOutline.customRadiusRange(cardHeight:notchHeight:)`),
    /// 读数报实际画出来的值:存着的固定值超过它时(比如关掉了歌词行、卡片变矮)读数和滑杆都停在上限。
    /// 拖动中只改 `NotchCornerLive`,松手(`onEditingChanged(false)`)才写回 AppSettings;菜单选模式是一次性的,直接写。
    /// 指针停在这一行上(含按着滑杆)时编辑台预览摆成这一态,移开交还(`NotchCornerLive.hover`)。
    private func cornerRadiusRow(icon: String, title: String, slot: NotchCornerSlot, cardHeight: CGFloat) -> some View {
        let notchHeight = card.contentTopInset
        let range = NotchOutline.customRadiusRange(cardHeight: cardHeight, notchHeight: notchHeight)
        let stored: ReferenceWritableKeyPath<AppSettings, Double> =
            slot == .collapsed ? \.notchCornerRadius : \.notchExpandedCornerRadius
        let rule = NotchCornerRule(setting: corners.value(slot))
        let shown: Double
        let label: String
        switch rule {
        case .proportional:
            shown = Double(NotchOutline.proportionalRadius(height: cardHeight)); label = L10n.t("默认")
        case .notch:
            shown = Double(NotchOutline.notchCornerRadius(notchHeight: notchHeight)); label = L10n.t("跟随刘海")
        case .fixed(let r):
            shown = min(Double(r), range.upperBound); label = String(format: L10n.t("%@pt"), "\(Int(shown))")
        }
        return SettingsRow(icon: icon, title: title) {
            HStack(spacing: 8) {
                SteppedSlider(value: Binding(
                    get: { shown },
                    set: { corners.drag(slot, to: $0) }
                ), in: range, step: 1, onEditingChanged: { editing in
                    if editing { corners.beginDrag(slot) } else { corners.endDrag() }
                })
                .frame(width: 100)
                cornerModeMenu(label: label, rule: rule, stored: stored)
                    .frame(width: 92, alignment: .trailing)
            }
        }
        .onHover { inside in corners.hover(slot, inside: inside) }
    }

    /// 圆角那颗菜单里的两种模式;固定值靠滑杆,不在菜单里。
    private enum NotchCornerMenuMode { case proportional, notch }

    /// 胶囊上写读数(固定值时是 pt 数),浮层里只有两种模式,所以不是 SettingsGlassMenuPicker。
    private func cornerModeMenu(
        label: String, rule: NotchCornerRule, stored: ReferenceWritableKeyPath<AppSettings, Double>
    ) -> some View {
        let modes: [NotchCornerMenuMode] = [.proportional, .notch]
        return SettingsGlassPopoverMenu(
            title: label,
            items: modes,
            itemLabel: { (mode: NotchCornerMenuMode) -> String in
                mode == .proportional ? L10n.t("默认") : L10n.t("跟随刘海")
            },
            isChecked: { (mode: NotchCornerMenuMode) -> Bool in
                mode == .proportional ? rule == .proportional : rule == .notch
            },
            height: 28
        ) { (mode: NotchCornerMenuMode) in
            let value: Double = mode == .proportional ? NotchOutline.defaultRadiusSetting : NotchOutline.notchRadiusSetting
            settings[keyPath: stored] = value
        }
    }
}

// MARK: - 恢复默认

/// 「重置」按钮(工具栏第一行右侧)的动作本体——逐字复刻悬浮歌词那边的写法
/// (`OverlayStyleDefaults.restoreTextAndColors()`):抽成独立函数而不是留在按钮闭包里,
/// 理由同源:以后要是再给这份设置开一个"全部设置"抽屉里的兜底恢复入口,两处调同一个
/// 函数才不会走出"从工具栏恢复和从抽屉恢复,恢复出来的样子不一样"这种岔子。
///
/// 范围:风格 + 左右耳 + 屏幕 + 这个
/// 形态全部的内容开关(歌词行/行为/展开态/音浪那一批布尔量,含各自的从属选择器)。
/// **不碰** `notchOverlayEnabled`(灵动岛总开关——重置一个"外观/内容默认值"的按钮，不该
/// 顺手把整个功能关掉)和 `notchContentWidth`(宽度——结构性尺寸设置,跟悬浮歌词「重置」
/// 明确排除宽度和锁定位置是同一条取舍)。
///
/// 每个字段的默认值只在 `AppSettings.defaultNotchXxx` 里出现一次、`AppSettings.init()`
/// 也读同一份——不在这里重新写一遍字面量,理由同 `defaultFollowsCoverArt` 那组:两处各自
/// 硬编码,以后改默认值容易漏掉其中一处,变成"点了重置却恢复不出真正默认值"。
@MainActor
enum NotchStyleDefaults {
    static func restoreDefaults() {
        let settings = AppSettings.shared
        settings.notchCardStyle = AppSettings.defaultNotchCardStyle
        settings.notchCornerRadius = AppSettings.defaultNotchCornerRadius
        settings.notchExpandedCornerRadius = AppSettings.defaultNotchExpandedCornerRadius
        settings.notchLeftEar = AppSettings.defaultNotchLeftEar
        settings.notchRightEar = AppSettings.defaultNotchRightEar
        settings.notchAllScreens = AppSettings.defaultNotchAllScreens
        settings.notchFollowsActiveScreen = AppSettings.defaultNotchFollowsActiveScreen
        settings.notchScreenID = AppSettings.defaultNotchScreenID
        settings.notchShowLyrics = AppSettings.defaultNotchShowLyrics
        settings.notchCollapsesWhenPaused = AppSettings.defaultNotchCollapsesWhenPaused
        settings.notchShowsEqualizer = AppSettings.defaultNotchShowsEqualizer
        settings.notchEqualizerEar = AppSettings.defaultNotchEqualizerEar
        settings.notchExpandedShowsNextLine = AppSettings.defaultNotchExpandedShowsNextLine
        settings.notchExpandedShowsControls = AppSettings.defaultNotchExpandedShowsControls
        settings.notchExpandedLyricList = AppSettings.defaultNotchExpandedLyricList
        settings.notchExpandedLyricListLines = AppSettings.defaultNotchExpandedLyricListLines
        settings.notchExpandedShowsLyricsOffset = AppSettings.defaultNotchExpandedShowsLyricsOffset
        settings.notchExpandedShowsArtwork = AppSettings.defaultNotchExpandedShowsArtwork
        settings.notchExpandedShowsTrackTitle = AppSettings.defaultNotchExpandedShowsTrackTitle
        settings.notchExpandedShowsArtist = AppSettings.defaultNotchExpandedShowsArtist
        settings.notchExpandedShowsAlbum = AppSettings.defaultNotchExpandedShowsAlbum
        settings.notchExpandedShowsQuickActions = AppSettings.defaultNotchExpandedShowsQuickActions
        settings.notchLyricRowShowsArtwork = AppSettings.defaultNotchLyricRowShowsArtwork
        settings.notchLyricRowArtworkPosition = AppSettings.defaultNotchLyricRowArtworkPosition
        settings.notchLyricsAlignment = AppSettings.defaultNotchLyricsAlignment
        settings.notchSecondaryLine = AppSettings.defaultNotchSecondaryLine
        // 「卡拉OK效果」在「歌词行」浮层里,同属内容开关。
        settings.notchLyricsKaraoke = AppSettings.defaultNotchLyricsKaraoke
        // 「字体」组三项。它们是字形、不是宽度那类结构性尺寸,按钮自报的排除范围「不含宽度和总开关」
        // 里也没有它们 —— 进重置(重置覆盖闸也会盯着这三个 defaultNotch* 常量)。
        settings.notchFontFamilyName = AppSettings.defaultNotchFontFamilyName
        settings.notchFontWeight = AppSettings.defaultNotchFontWeight
        settings.notchFontSize = AppSettings.defaultNotchFontSize
        // 歌词行「高度」同样进重置:按钮自报的排除范围只有「宽度和总开关」,它不在里面。
        settings.notchLyricRowHeight = AppSettings.defaultNotchLyricRowHeight
        // 「行为」组的开关都进重置:这颗按钮叫「恢复默认风格与开关」,界面自报的排除范围只有
        // "不含宽度和总开关"。
        settings.notchHideDuringScreenCapture = AppSettings.defaultNotchHideDuringScreenCapture
        settings.notchHideWhenNotPlaying = AppSettings.defaultNotchHideWhenNotPlaying
        settings.notchCollapseLyricsWhenNoLyrics = AppSettings.defaultNotchCollapseLyricsWhenNoLyrics
        settings.notchCollapsesDuringAds = AppSettings.defaultNotchCollapsesDuringAds
        settings.notchHideInFullScreen = AppSettings.defaultNotchHideInFullScreen
        settings.notchListenMilestones = AppSettings.defaultNotchListenMilestones
        settings.notchShowsTrackDrop = AppSettings.defaultNotchShowsTrackDrop
        settings.notchGestures = AppSettings.defaultNotchGestures
        settings.notchShowsProgressLine = AppSettings.defaultNotchShowsProgressLine
        settings.notchProgressLineStyle = AppSettings.defaultNotchProgressLineStyle
    }
}

extension NotchProgressLineChoice {
    var displayName: String {
        switch self {
        case .off: return L10n.t("不显示")
        case .bottom: return L10n.t("底边")
        case .ears: return L10n.t("耳朵")
        }
    }
}

// MARK: - 左右耳两个浮层

/// 一只耳朵显示什么模块。左右各一个浮层,由工具栏上对应那颗按钮打开。
///
/// 用单选列表,跟「风格」「屏幕」两个浮层同一个形态:列表点完不关,可以点着一路试过去,而下拉选中即收起。每个浮层只有 6 行
/// (约 260pt,离外壳 460 的上限还远)。
///
/// 收起态那一套耳朵(左封面、右音浪)**不在这里配**,理由见 `NotchEarModule` 上方那段。
///
/// 宽度 240 是**算出来的**。列表本身仍只要 124pt(中文)/ 136pt
/// (英文):八行两到四个字的模块名,最长英文 "Remaining" 63.0pt + 行内固定 60pt(左内边距 14 +
/// 勾列 20 + 间距 12 + 右内边距 14)。**抬到 240 的是顶上那一行「音浪」开关**(`SettingsRow` +
/// `Toggle`):`SettingsRow` 固定开销 150pt(2×14 内边距 + 20 图标列 + 3×12
/// 间距 + 12 Spacer + 54 开关)+ 标题 13pt 系统字「音浪」25.8 / "Audio Wave" 70.9 = 中文 176 /
/// **英文 221**,240 给英文留 19pt。**别顺手拉回 380 去跟别的浮层"对齐"** —— 那不是对齐,是空转。
@MainActor
struct NotchEarPopover: View {
    enum Side { case left, right }
    let side: Side

    var body: some View {
        // 把这里的帮助气泡整段去掉(那两段话本来是解释"只影响播放中/
        // 展开态"+"音浪独立开关放在这里"这两件事;后者现在开关本身就在下面列表顶部,自解释,
        // 前者的信息量不足以单独留一个「?」气泡)。别再往这儿加 help 参数。
        SettingsPopoverShell(
            title: side == .left ? L10n.t("左耳") : L10n.t("右耳"),
            // 「显示内容」那一行是标题 + 下拉,240 时标题会被挤成一字一行。
            width: 320
        ) {
            NotchEarSettingsRows(side: side)
        }
    }
}

@MainActor
struct NotchEarSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    let side: NotchEarPopover.Side

    private var current: NotchEarModule {
        side == .left ? settings.notchLeftEar : settings.notchRightEar
    }

    /// 「音浪」开关在左右耳浮层顶部各一行(工具栏没地方再加第五个入口,见 toolbar 的横向账)。
    ///
    /// 用 `SettingsRow` + `Toggle`,不跟下面 `row(_)` 共用"勾存在/消失"的视觉:这个开关是独立开关(可以跟任意模块共存,不参与那组
    /// 互斥单选),用同一套视觉、只靠一条分割线隔开容易被看成"九行单选里有一行可以跟别的同时勾"。浮层和「全部设置」抽屉都是这一行。
    /// 左右耳各有一份,但背后共享同一对全局状态(`notchShowsEqualizer` + `notchEqualizerEar`):打开这边会把 `notchEqualizerEar`
    /// 掰到这一侧、同时打开总开关(另一侧那行随之变成关);关掉只关总开关,不改哪一侧。
    /// 标题用「音浪」不写「显示音浪」:它是个开关,"显示"两个字由开关本身说,短两个字浮层也能窄 30pt(见 `NotchEarPopover` 的宽度账)。
    private var equalizerEarValue: NotchEqualizerEar { side == .left ? .left : .right }

    private var showsEqualizerHere: Bool {
        settings.notchShowsEqualizer && settings.notchEqualizerEar == equalizerEarValue
    }

    private var equalizerRow: some View {
        SettingsRow(icon: "waveform", title: L10n.t("音浪")) {
            Toggle("", isOn: Binding(
                get: { showsEqualizerHere },
                set: { on in
                    if on {
                        settings.notchEqualizerEar = equalizerEarValue
                        settings.notchShowsEqualizer = true
                    } else {
                        settings.notchShowsEqualizer = false
                    }
                }))
        }
    }

    // 一框:音浪一行开关,这一侧显示什么一行下拉(选其一;选「不显示」就空着)。
    var body: some View {
        SettingsRowGroup {
            VStack(spacing: 0) {
                equalizerRow
                CardDivider()
                SettingsRow(icon: "rectangle.lefthalf.inset.filled", title: L10n.t("显示内容")) {
                    // 顺序直接用 allCases(声明序),不另抄一份数组 —— 抄一份的话以后往枚举里加一个
                    // 模块,这里不加就是"设置里选不到的合法值"。
                    SettingsGlassMenuPicker(
                        selection: Binding(get: { current }, set: { select($0) }),
                        options: NotchEarModule.allCases,
                        label: \.displayName,
                        compact: true
                    )
                }
            }
        }
    }

    /// 下拉选中哪个就是哪个(「不显示」= `NotchEarModule.none`)。写全 `NotchEarModule.none`,别缩成 `.none`:这个枚举有个
    /// 成员就叫 `none`,而 `.none` 同时也是 `Optional` 的成员,挪进可选上下文含义会静默换成"空值"。
    /// 相等守卫不能去掉:@Published 是 willSet 语义,等值赋值照样广播 objectWillChange,didSet 还会白写一次 UserDefaults。
    private func select(_ module: NotchEarModule) {
        if side == .left {
            guard settings.notchLeftEar != module else { return }
            settings.notchLeftEar = module
        } else {
            guard settings.notchRightEar != module else { return }
            settings.notchRightEar = module
        }
    }
}

// MARK: - 「屏幕」浮层

/// 「🖥 屏幕」浮层。跟「风格」同一个形态(单选列表),理由见 NotchStylePopover。
///
/// 「所有屏幕」从一个独立的 Toggle 并进了这个选择:它跟"选哪一块屏"
/// 本来就是同一个问题的几个互斥答案 —— 拆成"下拉 + 一个会把下拉整个禁用掉的开关"是把一个
/// 选择硬掰成两个控件,还得额外写一句"开启后上面的指定屏幕不再起作用"来解释它们的关系。
/// 现在是一行「显示在」+ 下拉(浮层往上弹、高度有限,单选列表会撑高),那条并法原样保留。
///
/// 宽度 340:下拉里显示的是 `NSScreen.localizedName`,运行时才知道多长(常见机器量下来英文最长约 215pt,
/// "LG UltraFine 5K Display")。行名「显示在」+ ⓘ + 图标列约 110pt,再加下拉自身的边距。更长的名字下拉会截尾。
@MainActor
struct NotchScreenPopover: View {
    /// 选完之后让宿主重算编辑台的刘海几何(换到没有刘海的外接屏,画面里那个刘海要消失)。
    var onScreenChange: () -> Void

    var body: some View {
        SettingsPopoverShell(title: L10n.t("屏幕"), width: 340) {
            NotchScreenSettingsRows(onScreenChange: onScreenChange)
        }
    }
}

@MainActor
struct NotchScreenSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    var onScreenChange: () -> Void

    /// 下拉/列表里的选项来源。用 @State 快照而不是每次 body 现读 NSScreen.screens:
    /// 插拔显示器时 SwiftUI 不会因为一个全局数组变了就重算 body,得靠下面那条
    /// didChangeScreenParameters 通知显式刷新。
    @State private var availableScreens: [NSScreen] = NSScreen.screens

    /// 「所有屏幕」「跟随当前窗口」在这个列表里的哨兵 tag。屏幕的真实 tag 是 ScreenIdentity 给的 UUID 串,
    /// 不可能撞上这两个值;空串已经被「自动」占了。
    private static let allScreensTag = "__all_screens__"
    private static let followActiveTag = "__follow_active_window__"

    /// 下拉里的各项:自动、跟随当前窗口、全部屏幕、接着的每块屏。存着的那块屏现在没接着时补一项「已断开的屏幕」 ——
    /// 少了它,没有任何一项是选中的,看起来像设置丢了,而实际上偏好还在、屏幕插回来就会恢复。
    private var screenOptions: [(tag: String, name: String)] {
        var options: [(tag: String, name: String)] = [
            ("", L10n.t("自动")), (Self.followActiveTag, L10n.t("跟随当前窗口")), (Self.allScreensTag, L10n.t("全部屏幕")),
        ]
        for screen in availableScreens {
            if let id = ScreenIdentity.id(of: screen) { options.append((id, screen.localizedName)) }
        }
        if !settings.notchAllScreens, !settings.notchFollowsActiveScreen, !settings.notchScreenID.isEmpty,
           ScreenIdentity.screen(withID: settings.notchScreenID) == nil {
            options.append((settings.notchScreenID, L10n.t("已断开的屏幕")))
        }
        return options
    }

    /// 当前选中的是哪一项。三个设置项还是各存各的(notchAllScreens 有自己的订阅方 NotchMirrorManager,
    /// notchFollowsActiveScreen 由主灵动岛订阅),这里只是把它们合成一个选择呈现出来。
    private var selection: String {
        if settings.notchAllScreens { return Self.allScreensTag }
        if settings.notchFollowsActiveScreen { return Self.followActiveTag }
        return settings.notchScreenID
    }

    // 一行「显示在 [下拉]」,说明在这一行的 ⓘ 里(浮层和抽屉两个宿主都看得到)。别做成没有行名、居中铺开的下拉:
    // 放进抽屉那张宽卡里就是一个孤零零浮在中间的框,看不出在选什么。
    var body: some View {
        SettingsRowGroup {
            SettingsRow(
                icon: "display",
                title: L10n.t("显示在"),
                help: L10n.t("「自动」选择带刘海的屏幕；「跟随当前窗口」显示在正在使用的窗口所在的屏幕；「全部屏幕」在每块屏幕上各显示一个；指定的屏幕断开时按「自动」显示，插回后回到那块屏幕")
            ) {
                let options = screenOptions
                SettingsGlassMenuPicker(
                    selection: Binding(get: { selection }, set: { apply($0) }),
                    options: options.map(\.tag),
                    label: { tag in options.first { $0.tag == tag }?.name ?? "" },
                    compact: true
                )
            }
            // 搜索目录里这一项按「屏幕」登记。
            .settingsSearchHighlight(title: L10n.t("屏幕"))
        }
        // 设置页开着的时候插拔显示器,列表里的选项要跟着变。
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            availableScreens = NSScreen.screens
        }
    }

    /// 只写设置:主灵动岛自己订阅 `notchScreenID`(`NotchLyricsWindowController` init),这里不碰它的 `.shared`。
    private func apply(_ tag: String) {
        let allScreens = (tag == Self.allScreensTag)
        let follows = (tag == Self.followActiveTag)
        var changed = false
        if settings.notchAllScreens != allScreens {
            settings.notchAllScreens = allScreens
            changed = true
        }
        if settings.notchFollowsActiveScreen != follows {
            settings.notchFollowsActiveScreen = follows
            changed = true
        }
        // 选具体屏幕 / 自动时顺手把另两项关掉(上面两句已经做了),否则选了没反应。选跟随时留着原来指定的屏,换回来还在。
        if !allScreens, !follows, settings.notchScreenID != tag {
            settings.notchScreenID = tag
            changed = true
        }
        guard changed else { return }
        onScreenChange()
    }
}
