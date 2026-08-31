import AppKit
import LyrimuseCore

// 悬浮歌词 ⚙ 按钮弹出的快捷设置菜单(2026-08-29,参考 QQ 音乐悬浮歌词的设置菜单)。
//
// 为什么是真正的 NSMenu,不是 SwiftUI 自绘的圆角气泡:悬浮窗常年 `ignoresMouseEvents = true`、
// 点击靠 LyricsOverlayWindowController 自己按坐标分发(见该文件「点击穿透 + 悬停热区」那节),
// 这套机制不支持弹出一个能接收自己鼠标事件的浮层。NSMenu 完全独立于父窗口的
// ignoresMouseEvents——弹出、多级子菜单、勾选态、键盘导航全部是 AppKit 免费给的,风险和工作量
// 都远小于在这套点击穿透架构里再搭一套"浮层自己的命中测试"。
//
// 写法照抄 MenuBar/MenuBarStatusMenu.swift(同一个仓库已有的两处 NSMenu 范本之一,另一处是
// MenuBar/DockMenu.swift):纯 target/action(NSMenuItem 不支持闭包)、每次弹出前
// menuNeedsUpdate 里整棵 removeAllItems() 重建(保证勾选态永远是最新的,菜单项十几个、重建
// 代价可以忽略)、autoenablesItems = false(这里每一项都常驻可点,没有需要变灰的场景)。
//
// ⚠️ 同 MenuBarStatusMenu 的那条不变量:构建菜单时只读 AppSettings/PlaybackCoordinator,
// 不碰其它 `static let shared` 单例的构造路径——不过这个类本身就是
// LyricsOverlayWindowController 的属性,被弹出这一刻悬浮窗控制器早已存在,不存在"构建菜单时
// 意外把窗口建出来"这个风险,跟菜单栏那边要专门绕的坑不是同一个场景。
@MainActor
final class OverlayQuickSettingsMenu: NSObject, NSMenuDelegate {
    private let menu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }()

    override init() {
        super.init()
        menu.delegate = self
    }

    /// 在当前鼠标位置弹出——不需要把 SwiftUI 上报的按钮矩形换算成屏幕坐标,鼠标点击这一刻
    /// 本来就落在按钮上。
    func popUp() {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    // MARK: - 构建

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = AppSettings.shared

        // 「简繁转换」只在**这首歌的歌词真的会被转换**时才给(2026-08-31 用户要求"只有中文歌
        // 时才出现这个选项")。跟下面「搜索歌词…」按当前曲目决定显隐是同一个模式 —— 右键菜单
        // 本来就是上下文菜单,每次弹出都重建(见 menuNeedsUpdate)。
        //
        // ⚠️ 判据故意**不是**"这首歌是不是中文歌"(`Romanizer.songScript`),而是
        // `ChineseVariant.affects` —— 也就是 `converted(_:)` 自己用的那一个。理由见它的
        // 注释:按 songScript 判会在韩文歌含汉字时"隐藏了菜单、汉字却照转",而那正是
        // SettingsView 那条「只要它还在起作用,就一定看得见」要防的最坏状态。共用判据之后
        // **菜单显示 ⟺ 转换真的会发生**,所以这里不需要再加一条
        // 「|| 已经不是默认值」的兜底(设置页那条仍然需要,它的判据是粘性的、宽得多)。
        if LocalPlaybackSource.shared.currentLyricsSupportsChineseVariant {
            menu.addItem(submenu(L10n.t("简繁转换"), symbol: "character.bubble", menu: chineseVariantMenu(settings)))
        }
        menu.addItem(toggle(L10n.t("双行歌词"), symbol: "text.aligncenter",
                            on: settings.showNextLinePreview,
                            action: #selector(toggleNextLinePreview)))
        menu.addItem(submenu(L10n.t("更改配色"), symbol: "paintpalette", menu: colorThemeMenu(settings)))
        menu.addItem(submenu(offsetMenuTitle, symbol: "timer", menu: lyricsOffsetMenu()))
        // 没歌在播时不给这一项——跟 LyricsWindowView 的「⋯」菜单同一条件
        // (`if !playback.title.isEmpty`),搜索面板本身就是按"当前播放的这首歌"算的,
        // 没有曲目信息搜什么都没意义。
        if !PlaybackCoordinator.shared.title.isEmpty {
            menu.addItem(action(L10n.t("搜索歌词…"), symbol: "magnifyingglass",
                               selector: #selector(searchLyrics)))
        }
        menu.addItem(.separator())
        menu.addItem(action(L10n.t("更多设置…"), symbol: "gearshape",
                           selector: #selector(openMoreSettings)))
    }

    /// 「简繁转换」子菜单——lyrimuse 是三态(不转换/简体/繁体),跟参考图里看起来的单行不一样,
    /// 三态放不进一个可勾选行,做成子菜单。
    private func chineseVariantMenu(_ settings: AppSettings) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let current = settings.lyricsChineseVariant
        m.addItem(toggle(L10n.t("不转换"), symbol: "", on: current == .off,
                         action: #selector(setChineseVariantOff)))
        m.addItem(toggle(L10n.t("简体"), symbol: "", on: current == .simplified,
                         action: #selector(setChineseVariantSimplified)))
        m.addItem(toggle(L10n.t("繁体"), symbol: "", on: current == .traditional,
                         action: #selector(setChineseVariantTraditional)))
        return m
    }

    /// 「更改配色」子菜单:跟随封面 → 6 个内置主题 → 用户自存主题。
    ///
    /// ⚠️ **跟随封面开着时,下面整段主题列表不展示**(2026-08-31 用户拍板)。跟设置页
    /// (`OverlayStyleSettingsRows.swift` 的 `if !settings.followsCoverArt`)现在是同一个
    /// 口径 —— 某一项已经被另一项接管时,把它显示出来只会让人以为改了有用。
    ///
    /// 这里原来是反过来的:主题照常列出,理由是"这是改一下的快捷入口,点具体主题会顺带
    /// 关掉跟随封面(见 ColorTheme.apply(to:)),不需要用可见性去暗示联动"。那个设计的实际
    /// 后果是用户报的 bug:跟随封面开着时,四个颜色字段仍然等于某个主题,于是「跟随封面 ✓」
    /// 和「黑字描边 ✓」**同时打勾**,读起来是两个互相矛盾的"正在生效"。
    /// (中间试过用第三态 `.mixed` 渲染成短横表示"这是备用色、没在生效",用户否掉了,
    /// 要的就是干脆不显示。)
    ///
    /// 代价如实记下:从跟随封面切到某个固定主题现在要两步(先取消跟随封面、再打开菜单选),
    /// 不能一步到位。`ColorTheme.apply(to:)` 里那句 `followsCoverArt = false` 仍然保留 ——
    /// 设置页那条路径、以及以后任何别的入口都还依赖它。
    private func colorThemeMenu(_ settings: AppSettings) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(toggle(L10n.t("跟随封面"), symbol: "photo",
                         on: settings.followsCoverArt,
                         action: #selector(toggleFollowsCoverArt)))
        // 跟随封面开着 → 到此为止,下面一个主题都不列(见头注释)。
        guard !settings.followsCoverArt else { return m }
        m.addItem(.separator())
        let current = ColorTheme(
            name: "", foregroundColorHex: settings.foregroundColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            textStrokeEnabled: settings.textStrokeEnabled, textStrokeColorHex: settings.textStrokeColorHex)
        for theme in ColorTheme.builtInPresets {
            m.addItem(colorThemeItem(theme, checked: theme.hasSameColors(as: current)))
        }
        if !settings.customColorThemes.isEmpty {
            m.addItem(.separator())
            for theme in settings.customColorThemes {
                m.addItem(colorThemeItem(theme, checked: theme.hasSameColors(as: current)))
            }
        }
        return m
    }

    /// 每个主题条目携带自己的 `ColorTheme`(NSMenuItem.representedObject)——不像别处的
    /// action 都是零参数的固定 selector,这里同一个 selector 要服务任意多个主题,只能靠
    /// representedObject 区分点的是哪一个。
    private func colorThemeItem(_ theme: ColorTheme, checked: Bool) -> NSMenuItem {
        let item = makeItem(theme.name, symbol: "", selector: #selector(applyColorTheme(_:)))
        item.representedObject = theme
        // 两态就够:跟随封面开着时这些条目压根不会被建出来(见 colorThemeMenu 的早退),
        // 所以不存在"打着勾但其实没生效"那种状态,不需要第三态。
        item.state = checked ? .on : .off
        return item
    }

    /// 「歌词进度」子菜单——跟 MenuBar/MenuBarStatusMenu.swift 的「歌词时间轴」子菜单同一套
    /// 动作(`PlaybackCoordinator.nudgeLyricsOffset(by:)`/`.resetLyricsOffset()`),标题也照抄
    /// 那边的"把当前校准值直接写进子菜单标题"做法,不用另开一个只读展示行。
    private func lyricsOffsetMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(action(nudgeTitle(L10n.t("提前")), symbol: "gobackward",
                        selector: #selector(nudgeEarlier)))
        m.addItem(action(nudgeTitle(L10n.t("延后")), symbol: "goforward",
                        selector: #selector(nudgeLater)))
        if PlaybackCoordinator.shared.trackLyricsOffsetMs != 0 {
            m.addItem(.separator())
            m.addItem(action(L10n.t("重置"), symbol: "arrow.counterclockwise",
                            selector: #selector(resetOffset)))
        }
        return m
    }

    private func nudgeTitle(_ verb: String) -> String {
        let step = AppSettings.shared.lyricsOffsetStepMs
        return "\(verb) \(AppSettings.formattedSeconds(ms: step))\(L10n.t("秒"))"
    }

    private var offsetMenuTitle: String {
        let ms = PlaybackCoordinator.shared.trackLyricsOffsetMs
        guard ms != 0 else { return L10n.t("歌词进度") }
        let sign = ms > 0 ? "+" : ""
        return "\(L10n.t("歌词进度"))(\(sign)\(AppSettings.formattedSeconds(ms: ms))s)"
    }

    // MARK: - 菜单项工厂(同 MenuBarStatusMenu 的写法)

    private func makeItem(_ title: String, symbol: String, selector: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        if !symbol.isEmpty, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            item.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) ?? image
        }
        return item
    }

    private func action(_ title: String, symbol: String, selector: Selector) -> NSMenuItem {
        makeItem(title, symbol: symbol, selector: selector)
    }

    private func toggle(_ title: String, symbol: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = makeItem(title, symbol: symbol, selector: action)
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, symbol: String, menu: NSMenu) -> NSMenuItem {
        let item = makeItem(title, symbol: symbol, selector: nil)
        item.submenu = menu
        return item
    }

    // MARK: - 动作

    @objc private func toggleNextLinePreview() {
        AppSettings.shared.showNextLinePreview.toggle()
    }

    /// 中文繁简要双写(跟 SettingsView.swift 那个 Picker 完全一致):AppSettings 负责持久化,
    /// LocalPlaybackSource 负责让**当前正在播的这首歌**立刻按新设置重新解析——只写前者的话
    /// 要等切下一首歌才会生效,像是这一项点了没反应。
    private func setChineseVariant(_ variant: ChineseVariant) {
        AppSettings.shared.lyricsChineseVariant = variant
        LocalPlaybackSource.shared.chineseVariant = variant
    }
    @objc private func setChineseVariantOff() { setChineseVariant(.off) }
    @objc private func setChineseVariantSimplified() { setChineseVariant(.simplified) }
    @objc private func setChineseVariantTraditional() { setChineseVariant(.traditional) }

    @objc private func toggleFollowsCoverArt() {
        AppSettings.shared.followsCoverArt.toggle()
    }

    @objc private func applyColorTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? ColorTheme else { return }
        theme.apply(to: AppSettings.shared)
    }

    @objc private func nudgeEarlier() {
        PlaybackCoordinator.shared.nudgeLyricsOffset(by: AppSettings.shared.lyricsOffsetStepMs)
    }

    @objc private func nudgeLater() {
        PlaybackCoordinator.shared.nudgeLyricsOffset(by: -AppSettings.shared.lyricsOffsetStepMs)
    }

    @objc private func resetOffset() {
        PlaybackCoordinator.shared.resetLyricsOffset()
    }

    /// 「搜索歌词…」——**不**跟 ⤢ 共用「展开到歌词窗口」那个入口:用户明确要求点了只弹
    /// 搜索页面本身,不需要连带拉起完整的歌词窗口。走它自己独立的一扇
    /// `Window(id: "lyrics-quick-search")`(`LyricsQuickSearchWindow`,App.swift),
    /// 曲目快照/写回逻辑全在那扇窗口自己的 `.task` 里,这里只管把窗口叫出来。
    @objc private func searchLyrics() {
        AppActions.shared.openLyricsQuickSearch?()
    }

    /// 「更多设置…」——跳到设置页「悬浮歌词」子段,照抄
    /// MenuBar/MenuBarPanelQuickSettings.swift 的「全部设置…」那三行:先把
    /// LyricsSurface.appearanceSectionStorageKey 写成 .overlay 对应的值(设置页那边是
    /// @AppStorage,窗口已经开着也会立刻跟着翻),再请求侧边栏停在「歌词显示」分类,最后
    /// 才真正打开设置窗口。
    @objc private func openMoreSettings() {
        UserDefaults.standard.set(LyricsSurface.overlay.appearanceSectionRawValue,
                                  forKey: LyricsSurface.appearanceSectionStorageKey)
        AppActions.shared.requestSettings(.tab(.appearance))
        AppActions.shared.openSettings?()
    }
}
