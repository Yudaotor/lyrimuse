import Foundation

// 设置搜索的目录。
//
// 设置页的每一行(以及一张卡)在这里登记一条:它在哪个分类、哪个分段、哪个「全部设置」抽屉的
// 哪一组,标题是哪个 L10n 键。侧栏顶部的搜索框按它出结果,命中后按它翻页、展开抽屉、高亮那一行。
//
// 为什么是一张**静态表**而不是运行时登记:设置行分布在六个分类、十几个分段和三个默认折叠的抽屉里,
// 没显示出来的行根本不会 onAppear,运行时登记只能搜到当前页。静态表的代价是会漂——新加一行忘了登记,
// 搜不到就等于"不存在",比没有搜索更糟。所以 selftest「设置搜索」组有守卫:扫源码里每一处
// `SettingsRow(` / `SettingsSubRow(` / `SettingsCardHeader(` 的字面量标题,逐个核对都在这张表里
// (刻意不登记的写进那边的白名单),同时核对表里每个键都在 Localizable.xcstrings 里。
//
// 为什么放 LyrimuseCore:纯数据 + 纯函数(匹配、排序),selftest 才能直接 import 来核对;本地化
// (L10n.t)、翻页(UserDefaults)、高亮(SwiftUI)都在 App 侧 Settings/SettingsSearch.swift。
//
// 字段约定:
//   - `titleKey` / `alternateTitleKeys` / `subtitleKey` / `pathKeys` 全是 **L10n 键(简体原文)**,
//     App 侧 `L10n.t` 之后跟界面上那一行的 `title` 逐字相等——高亮就是拿这个相等判的,所以这里的
//     字面量必须跟调用点的 `L10n.t("…")` 一字不差(守卫核的正是这件事)。标题随状态变的行
//     (菜单栏「文字颜色 / 未唱到的颜色」)把两种写法都列上,哪个显示着就高亮哪个。
//   - `keywords` 是**额外可搜、不显示**的词(简体),给同义词和一张卡里没有独立行的选项用
//     (「歌词来源」卡登记全部源的界面全名,搜「QQ」「咪咕音乐」都能落到那张卡;全名包含简称,搜简称也命中)。不是 L10n 键,守卫不核。
//   - `sectionKey` / `sectionValue`:这个分类有二级分段时,命中后往哪个 UserDefaults 键写哪个值
//     (设置页那边是 @AppStorage,写了立刻翻过去)。键名与取值是跨文件契约,守卫扫源码核对。
//   - `drawer`:命中的行住在哪个「全部设置」抽屉里,抽屉看到它就自己展开(那三个抽屉默认折叠、
//     状态是 @State,不展开的话高亮的行根本不在屏幕上)。

public struct SettingsSearchEntry: Hashable, Sendable, Identifiable {
    public enum Destination: Hashable, Sendable {
        /// 侧栏「核心设置」六个分类之一,值是 App 侧 `SettingsTab` 的 rawValue(= case 名)。
        case tab(String)
        /// 账号页之一,值是 App 侧 `AccountDestination` 的 case 名(那个枚举没有 rawValue,
        /// App 侧用 `String(describing:)` 对回去)。
        case account(String)
        /// 「软件更新」页:不属于六分类,App 侧是 `SettingsSidebarItem.softwareUpdate`。
        case softwareUpdate
    }

    public let destination: Destination
    public let sectionKey: String?
    public let sectionValue: String?
    public let drawer: LyricsSurface?
    public let titleKey: String
    public let alternateTitleKeys: [String]
    public let subtitleKey: String?
    public let keywords: [String]
    public let pathKeys: [String]
    /// 「歌词显示 › 歌词窗口」那一段里这一行只在哪个尺寸的预览下才有:true = 只有迷你、false = 只有完整、
    /// nil = 两种都有(或不在那一段)。命中时 App 先把预览切到那个尺寸,行才在页面上(14 章决策 56)。
    public let lyricsWindowMini: Bool?

    public init(destination: Destination, sectionKey: String? = nil, sectionValue: String? = nil,
                drawer: LyricsSurface? = nil, titleKey: String, alternateTitleKeys: [String] = [],
                subtitleKey: String? = nil, keywords: [String] = [], pathKeys: [String],
                lyricsWindowMini: Bool? = nil) {
        self.destination = destination
        self.sectionKey = sectionKey
        self.sectionValue = sectionValue
        self.drawer = drawer
        self.titleKey = titleKey
        self.alternateTitleKeys = alternateTitleKeys
        self.subtitleKey = subtitleKey
        self.keywords = keywords
        self.pathKeys = pathKeys
        self.lyricsWindowMini = lyricsWindowMini
    }

    public var id: String {
        let dest: String
        switch destination {
        case .tab(let raw): dest = "tab:\(raw)"
        case .account(let name): dest = "account:\(name)"
        case .softwareUpdate: dest = "softwareUpdate"
        }
        return "\(dest)|\(sectionValue ?? "")|\(pathKeys.joined(separator: "/"))|\(titleKey)"
    }

    /// 表里出现过的全部 L10n 键(守卫用来逐个核对 catalog)。
    public var localizedKeys: [String] {
        [titleKey] + alternateTitleKeys + (subtitleKey.map { [$0] } ?? []) + pathKeys
    }
}

public enum SettingsSearchCatalog {
    /// 「歌词」页分段的 @AppStorage 键(SettingsView.swift `LyricsSettingsTab`)。
    public static let lyricsSectionKey = "settings:lyricsSection"
    /// 这个键还没写过时,那一页停在哪一段(= `LyricsSettingsTab.Section` 的第一个 case)。
    /// 设置窗的前进 / 后退拿它还原「还没换过分段」那个位置 —— 跟那边对不上,表现是后退之后
    /// 停在另一个分段。selftest 按源码里的枚举首个 case 钉着它。
    public static let lyricsSectionDefault = "fetch"
    /// 「歌词」页「管理」那一段的取值(`LyricsSettingsTab.Section.manage`)。菜单栏面板「歌词管理」那一格的
    /// 「全部设置…」拿它翻页;selftest 按源码里的枚举钉着它。
    public static let lyricsManageSectionValue = "manage"
    /// Last.fm 账号页分段的 @AppStorage 键(AccountLinkingTab.swift)。它带 `np:` 前缀是历史原因,
    /// 这里只写不新建。
    public static let lastfmSectionKey = "np:lastfmDetailSection"
    /// 同 `lyricsSectionDefault`,对应 `LastfmSection` 的第一个 case。
    public static let lastfmSectionDefault = "stats"
    /// Discord 账号页分段(显示内容 / 隐私)的 @AppStorage 键(AccountLinkingTab.swift `DiscordSection`)。
    public static let discordSectionKey = "np:discordSection"
    /// 同 `lyricsSectionDefault`,对应 `DiscordSection` 的第一个 case。
    public static let discordSectionDefault = "display"
    /// 「播放器」页分段(播放器 / 联动 / 权限与服务)的 @AppStorage 键(SettingsView.swift `PlayerSettingsTab`)。
    public static let playerSectionKey = "settings:playerSection"
    /// 同 `lyricsSectionDefault`,对应 `PlayerSettingsTab.Section` 的第一个 case。
    public static let playerSectionDefault = "players"

    /// 「歌词显示」页第四段「歌词窗口」的分段取值(`AppearanceSettingsTab.Section.lyricsWindow`)。
    /// 前三段的取值来自 `LyricsSurface`,这一段没有对应的形态,所以单独在这里定义一份。
    public static let lyricsWindowSectionValue = "lyricsWindow"
    /// 「歌词窗口」那一段只在迷你预览下才有的行(按标题):完整尺寸那一套外观行不传字号、长句处理、歌词布局这些绑定,
    /// 「行为」「顶部信息」两组也只在迷你装配。设置页加了这类行要来这里登记。
    public static let lyricsWindowMiniOnlyTitles: Set<String> = [
        "字号", "歌词布局", "长句处理", "悬浮淡化", "淡化时点按穿透", "暂停时隐藏",
        "全屏时隐藏", "歌名", "歌手", "专辑", "封面", "时间", "宽度", "高度", "进度条",
    ]
    /// 只在完整预览下才有的行:「封面」那一组、「布局」里的对齐方式、「文字」里的 HDR 高亮。
    public static let lyricsWindowFullOnlyTitles: Set<String> = ["动态封面", "动态封面缓存", "对齐方式", "HDR 高亮"]

    /// 「歌词显示」页「触控栏」那一段的分段取值(`AppearanceSettingsTab.Section.touchBar`)。跟歌词窗口一样
    /// 不是一个 `LyricsSurface`(见 `touchBar(_:sub:kw:)`),单独定义一份。
    public static let touchBarSectionValue = "touchBar"
    /// 那一段总开关的标题。没有触控栏的 Mac 上设置搜索只留这一条(落到「这台 Mac 没有触控栏」那张说明卡)。
    public static let touchBarToggleTitleKey = "触控栏歌词"
    /// 「快捷键」页「展开/收起触控栏歌词」那一行的标题。那一行只在有触控栏时出现,没有触控栏时设置搜索不收这一条。
    public static let touchBarHotkeyTitleKey = LyrimuseAction.toggleTouchBarLyricsHotkey.titleKey

    /// 随设置显隐的一行:`condition` 为假时它不在页面上,搜到它时落到 `gate` 那一行(一起点亮、滚过去的就是那一行)。
    /// `condition` 是名字,真假由 App 侧 `SettingsSearchRouter.rowCondition` 按此刻的设置算,写法要跟那一行自己的
    /// 显隐同步。新加随设置显隐的行要来这里登记。
    public struct RowGate: Equatable, Sendable {
        /// 条目 `pathKeys` 的前缀(哪一段)。
        public let path: [String]
        public let title: String
        public let condition: String
        public let gate: String
        public init(_ path: [String], _ title: String, _ condition: String, _ gate: String) {
            self.path = path
            self.title = title
            self.condition = condition
            self.gate = gate
        }
    }

    public static let rowGates: [RowGate] = {
        let menuBar = ["歌词显示", "菜单栏"]
        let notch = ["歌词显示", "灵动岛"]
        let overlay = ["歌词显示", "悬浮歌词"]
        let touchBar = ["歌词显示", "触控栏"]
        let window = ["歌词显示", "歌词窗口"]
        let lastfm = ["Last.fm", "设置"]
        var gates: [RowGate] = [
            RowGate(menuBar, "屏幕", "menuBar.centerSelected", "歌词位置"),
            RowGate(menuBar, "宽度模式", "menuBar.centerIdle", "歌词位置"),
            RowGate(menuBar, "对齐方式", "menuBar.centerIdle", "歌词位置"),
            RowGate(menuBar, "对齐方式", "menuBar.widthFixed", "宽度模式"),
            RowGate(menuBar, "已唱颜色", "menuBar.fillColorShown", "卡拉OK效果"),
        ]
        // 灵动岛「歌词行」组:收起时不显示歌词时整组藏起(`NotchLyricRowSettingsRows`)。
        for title in ["对齐方式", "副行", "高度", "卡拉OK效果", "显示封面", "封面位置"] {
            gates.append(RowGate(notch, title, "notch.showLyrics", "收起时显示歌词"))
        }
        // Last.fm「Scrobble 规则」:上面的「Scrobble 到 Last.fm」关着时整组换成一句提示,落到组标题上。
        for title in ["匹配模式", "歌名", "歌手", "Scrobble 时机", "短于 30 秒的曲目", "Scrobble 的播放器"] {
            gates.append(RowGate(lastfm, title, "lastfm.mirror", "Scrobble 规则"))
        }
        gates += [
            RowGate(notch, "封面位置", "notch.lyricRowArtwork", "显示封面"),
            RowGate(notch, "展开时预览下一句", "notch.expandedNextLine", "副行"),
            RowGate(overlay, "未唱颜色", "overlay.karaoke", "卡拉OK效果"),
            RowGate(overlay, "描边颜色", "overlay.stroke", "文字描边"),
            RowGate(overlay, "玻璃浓淡", "overlay.glass", "毛玻璃背景"),
            RowGate(touchBar, "封面位置", "touchBar.artwork", "显示封面"),
            RowGate(touchBar, "播放控制位置", "touchBar.controls", "显示播放控制"),
            RowGate(window, "方向", "lyricsWindow.gradient", "背景"),
            RowGate(window, "底部颜色", "lyricsWindow.gradient", "背景"),
            RowGate(window, "玻璃浓淡", "lyricsWindow.glass", "背景"),
            RowGate(window, "指定颜色", "lyricsWindow.customText", "文字颜色"),
            RowGate(window, "淡化时点按穿透", "lyricsWindow.miniFade", "悬浮淡化"),
            RowGate(window, "长句处理", "lyricsWindow.miniLayoutNotList", "歌词布局"),
            RowGate(window, "允许远程控制", "web.lan", "允许局域网访问"),
            RowGate(lastfm, "歌名", "lastfm.matchCustom", "匹配模式"),
            RowGate(lastfm, "歌手", "lastfm.matchCustom", "匹配模式"),
            RowGate(["歌词", "调整"], "日语读音", "romanization.japanese", "标注读音的语言"),
        ]
        return gates
    }()

    /// 搜到的这一行此刻不在页面上时该落到哪一行的标题(键);在页面上返回 nil。按 `rowGates` 的顺序找第一条条件为假的;
    /// 落点自己也藏着(灵动岛「展开时预览下一句」→「副行」→「收起时显示歌词」)就接着往上找,最多几层。
    public static func gateTitle(path: [String], title: String, isTrue: (String) -> Bool) -> String? {
        var current = title
        var found: String?
        for _ in 0..<4 {
            guard let rule = rowGates.first(where: {
                $0.title == current && path.starts(with: $0.path) && !isTrue($0.condition)
            }) else { break }
            found = rule.gate
            current = rule.gate
        }
        return found
    }

    /// 面包屑里不是 L10n 键的品牌名(AccountDestination.title 对这几个直接返回字面量)。守卫核
    /// 键是否在 catalog 里时跳过它们。
    public static let brandPathComponents: Set<String> = ["ListenBrainz", "Last.fm", "Discord"]

    // MARK: - 构造小工具(只在本文件用)

    private static func lyrics(_ section: String, _ title: String, alt: [String] = [], sub: String? = nil,
                               kw: [String] = [], group: String? = nil) -> SettingsSearchEntry {
        let sectionTitle: String
        switch section {
        case "fetch": sectionTitle = "获取"
        case "translation": sectionTitle = "译文"
        case "display": sectionTitle = "调整"
        default: sectionTitle = "管理"
        }
        return SettingsSearchEntry(destination: .tab("lyrics"), sectionKey: lyricsSectionKey, sectionValue: section,
                                   titleKey: title, alternateTitleKeys: alt, subtitleKey: sub, keywords: kw,
                                   pathKeys: ["歌词", sectionTitle] + (group.map { [$0] } ?? []))
    }

    private static func player(_ section: String, _ title: String, alt: [String] = [], sub: String? = nil,
                               kw: [String] = [], group: [String] = []) -> SettingsSearchEntry {
        // 第一段跟页名同叫「播放器」,面包屑里不重复写它。
        let sectionPath: [String]
        switch section {
        case "players": sectionPath = []
        case "linkage": sectionPath = ["联动"]
        default: sectionPath = ["权限与服务"]
        }
        return SettingsSearchEntry(destination: .tab("player"), sectionKey: playerSectionKey, sectionValue: section,
                                   titleKey: title, alternateTitleKeys: alt, subtitleKey: sub, keywords: kw,
                                   pathKeys: ["播放器"] + sectionPath + group)
    }

    private static func surface(_ surface: LyricsSurface, _ title: String, alt: [String] = [], sub: String? = nil,
                                kw: [String] = [], group: String? = nil, inDrawer: Bool = true) -> SettingsSearchEntry {
        let sectionTitle: String
        switch surface {
        case .overlay: sectionTitle = "悬浮歌词"
        case .notch: sectionTitle = "灵动岛"
        case .menuBar: sectionTitle = "菜单栏"
        }
        return SettingsSearchEntry(destination: .tab("appearance"),
                                   sectionKey: LyricsSurface.appearanceSectionStorageKey,
                                   sectionValue: surface.appearanceSectionRawValue,
                                   drawer: inDrawer ? surface : nil,
                                   titleKey: title, alternateTitleKeys: alt, subtitleKey: sub, keywords: kw,
                                   pathKeys: ["歌词显示", sectionTitle] + (group.map { [$0] } ?? []))
    }

    /// 「歌词显示 › 歌词窗口」那一段。跟 `surface` 分开是因为这一段**不是**一个 `LyricsSurface`
    /// (歌词窗口没有常驻开关,进不了那个枚举),分段取值只能直接写字面量;selftest 拿
    /// `AppearanceSettingsTab.Section` 的源码枚举核它。这一段的「全部设置」抽屉不靠 `drawer`
    /// 字段展开(那个字段是 `LyricsSurface` 类型),靠行高亮信号,见 `LyricsWindowAllSettingsDrawer`。
    /// 只在一种尺寸下才有的行按两份名单标上 `lyricsWindowMini`。
    private static func lyricsWindow(_ title: String, sub: String? = nil, kw: [String] = [],
                                     group: String? = nil) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("appearance"),
                            sectionKey: LyricsSurface.appearanceSectionStorageKey,
                            sectionValue: lyricsWindowSectionValue,
                            titleKey: title, subtitleKey: sub, keywords: kw,
                            pathKeys: ["歌词显示", "歌词窗口"] + (group.map { [$0] } ?? []),
                            lyricsWindowMini: lyricsWindowMiniOnlyTitles.contains(title) ? true
                                : lyricsWindowFullOnlyTitles.contains(title) ? false : nil)
    }

    /// 「歌词显示 › 触控栏」那一段。跟 `lyricsWindow` 同理不是一个 `LyricsSurface`:触控栏有常驻开关、也按宽度断句
    /// (`LineBreakSurface.touchBar`),但进不了菜单栏面板那排磁贴。这一段的「全部设置」抽屉同歌词窗口那一段,搜索命中时
    /// 靠行高亮展开,`drawer` 留空。
    private static func touchBar(_ title: String, sub: String? = nil, kw: [String] = [],
                                 group: String? = nil) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("appearance"),
                            sectionKey: LyricsSurface.appearanceSectionStorageKey,
                            sectionValue: touchBarSectionValue,
                            titleKey: title, subtitleKey: sub, keywords: kw,
                            pathKeys: ["歌词显示", "触控栏"] + (group.map { [$0] } ?? []))
    }

    /// 「快捷键」页:「深度链接」卡、各个动作(格子、顺序、标题、关键词都取 `LyrimuseAction`)、「歌词时间轴」卡底下的「步长」。
    private static var shortcutEntries: [SettingsSearchEntry] {
        var entries = [shortcut("深度链接", sub: "可在快捷指令、Raycast、Alfred 等工具中打开；将指针悬停在上方的快捷键上，可拷贝对应操作的链接",
                                kw: ["深链", "URL", "URL Scheme", "x-callback", "文档", "lyrimuse://", "Raycast", "Alfred", "Stream Deck",
                                     "自动化", "拷贝链接"])]
        for (group, actions) in LyrimuseAction.shortcutLayout {
            entries += actions.map { shortcut($0.titleKey, kw: $0.searchKeywords) }
            if group == .timing {
                entries.append(shortcut("步长", sub: "每按一次调整的幅度", kw: ["偏移", "幅度"]))
            }
        }
        return entries
    }

    private static func shortcut(_ title: String, sub: String? = nil, kw: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("shortcuts"), titleKey: title, subtitleKey: sub,
                            keywords: kw + ["快捷键", "hotkey"], pathKeys: ["快捷键"])
    }

    private static func general(_ title: String, alt: [String] = [], sub: String? = nil, kw: [String] = [],
                                group: String? = nil) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("general"), titleKey: title, alternateTitleKeys: alt, subtitleKey: sub,
                            keywords: kw, pathKeys: ["通用"] + (group.map { [$0] } ?? []))
    }

    private static func about(_ title: String, sub: String? = nil, kw: [String] = [], group: String?) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("about"), titleKey: title, subtitleKey: sub, keywords: kw,
                            pathKeys: ["关于"] + (group.map { [$0] } ?? []))
    }

    private static func softwareUpdate(_ title: String, sub: String? = nil, kw: [String] = [],
                                       group: String?) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .softwareUpdate, titleKey: title, subtitleKey: sub, keywords: kw,
                            pathKeys: ["软件更新"] + (group.map { [$0] } ?? []))
    }

    private static func account(_ name: String, path: [String], sectionValue: String? = nil, _ title: String,
                                kw: [String] = []) -> SettingsSearchEntry {
        let key = sectionValue == nil ? nil : (name == "discord" ? discordSectionKey : lastfmSectionKey)
        return SettingsSearchEntry(destination: .account(name), sectionKey: key, sectionValue: sectionValue,
                                   titleKey: title, keywords: kw, pathKeys: path)
    }

    // MARK: - 目录本体

    public static let entries: [SettingsSearchEntry] = [
        // ---- 歌词 › 获取 ----
        lyrics("fetch", "歌词来源", kw: ["歌词源", "网易云音乐", "QQ音乐", "酷狗音乐", "Musixmatch", "LRCLIB", "AMLL",
                                      "LyricFind", "酷我音乐", "咪咕音乐", "Deezer", "Apple Music", "汽水音乐",
                                      "测试", "顺序"]),
        lyrics("fetch", "匹配算法", kw: ["智能", "顺序优先", "打分"]),
        lyrics("fetch", "随匹配算法更新重新选择", kw: ["重打分", "自动升级"]),
        lyrics("fetch", "同曲条目共用歌词", kw: ["同曲条目", "同一首歌", "歌词同步", "共享歌词", "歌曲实体"]),
        lyrics("fetch", "预解析待播曲目", kw: ["预解析", "提前解析", "待播", "专辑", "队列", "播放列表", "下一首"]),
        lyrics("fetch", "锁定手选歌词", kw: ["手动选定", "锁定"]),
        // ---- 歌词 › 译文 ----
        lyrics("translation", "译文语言", sub: "各处是否显示译文，在「歌词显示」中设置", kw: ["翻译", "语言"]),
        lyrics("translation", "无译文时自动翻译", alt: ["系统兜底翻译"], sub: "优先在本机翻译，无法翻译时再联网翻译",
               kw: ["机翻", "Google", "MyMemory", "翻译"]),
        lyrics("translation", "翻译语言包", kw: ["下载", "语言包", "Apple 翻译"]),
        // ---- 歌词 › 调整 ----
        lyrics("display", "繁简转换", sub: "中文歌词统一成简体或繁体", kw: ["繁体", "简体", "OpenCC"]),
        lyrics("display", "标注读音的语言", alt: ["标注的语言"], sub: "为勾选的语言标注读音；是否显示在「歌词显示」中设置",
               kw: ["日语", "韩语", "普通话", "粤语", "中文", "拼音", "粤拼", "读音", "罗马音", "罗马字", "注音", "发音"]),
        lyrics("display", "日语读音", sub: "标注罗马字，或只给汉字标注平假名", kw: ["假名", "平假名", "振假名", "furigana", "罗马字", "罗马音", "汉字读音", "注音"]),
        lyrics("display", "长句拆分", sub: "单行无法完整显示时，拆分为多段依次显示", kw: ["长句", "拆分", "断句", "换行", "折行", "滚动", "跑马灯", "宽度", "悬浮歌词", "灵动岛", "菜单栏", "触控栏"]),
        lyrics("display", "短句合并", sub: "相邻短句可容纳于一行时合并显示", kw: ["短句", "合并", "断句", "频繁", "闪", "宽度", "悬浮歌词", "灵动岛", "菜单栏", "触控栏"]),
        lyrics("display", "时间轴偏移", sub: "正值歌词提前，负值延后",
               kw: ["全局", "歌词偏移", "提前", "延后", "校准", "同步", "延迟",
                    "歌词太快", "歌词太慢", "歌词快了", "歌词慢了", "歌词不同步", "歌词对不上",
                    "out of sync", "too early", "too late"]),
        // ---- 歌词 › 管理 ----
        lyrics("manage", "歌词库", kw: ["歌词管理", "统计", "缓存"]),
        lyrics("manage", "自动匹配缺失歌词", sub: "仅搜索无歌词或仅有纯文本歌词的歌曲", kw: ["重新扫描", "重搜", "补空", "没有歌词", "暂无", "缺失"]),
        lyrics("manage", "重新匹配整个歌词库", sub: "已有歌词的歌曲也重新选择；手动修改、已校准和纯音乐的歌曲保持不变", kw: ["重新扫描", "重搜", "全量", "扫库", "升级", "跟进算法"]),
        lyrics("manage", "扫描间隔", sub: "每首歌曲之间的间隔秒数；建议不少于 2 秒，以免被限流",
               kw: ["速度", "间隔", "限流", "风控", "并发", "快", "慢"]),
        lyrics("manage", "歌词文件夹", sub: "更改位置后，已有文件不会随之移动", kw: ["lyrics", "自定义位置", "目录", "lrc"]),

        // ---- 播放器 ----
        player("players", "音乐 App", alt: ["选择播放器"],
               kw: ["Apple Music", "QQ音乐", "网易云音乐", "酷狗音乐", "Spotify", "自动识别", "多选"]),
        player("players", "网页版", alt: ["网页播放器"], kw: ["YouTube Music", "Spotify", "浏览器", "Chrome", "Safari", "Edge", "Arc", "配对"]),
        player("players", "自动跳过 YouTube Music 广告", sub: "可跳过的广告出现时自动跳过", kw: ["广告", "跳过", "YouTube Music", "辅助功能"],
               group: ["网页版"]),
        player("players", "其他 App", alt: ["已信任的播放器"], kw: ["信任列表", "其它播放器"]),
        player("players", "添加 App…", alt: ["添加播放器…"], sub: "从「应用程序」中选择，无需等待其开始播放",
               kw: ["信任列表", "手动添加", "第三方播放器", "应用程序"]),
        player("players", "新播放器提醒", sub: "系统通知已关闭", kw: ["通知", "未知播放器"]),
        // 一条通用条目,不按播放器各登记一条:那张卡的行标题是播放器名(运行期从
        // `playersNeedingAutomation` 来),登记成字面量就等于在第三个地方再抄一份播放器清单。
        // 关键词把两家的名字都收进来,搜「Spotify 权限」同样命中。
        player("permissions", "自动化权限", kw: ["权限", "AppleScript", "自动化", "Apple Music", "Spotify"]),
        player("permissions", "完全磁盘访问权限", kw: ["权限", "磁盘", "隐私", "歌词缓存", "播放队列", "QQ音乐", "网易云音乐", "酷狗音乐"]),
        player("permissions", "辅助功能权限", kw: ["权限", "辅助功能", "隐私", "播放进度", "Amazon Music"]),
        player("permissions", "洛雪音乐开放 API", kw: ["洛雪", "LX Music", "开放 API", "Open API", "音量", "播放进度"]),
        player("permissions", "歌词引擎", kw: ["lyrimuse-engine", "collector", "launchd", "服务", "运行状态", "后台采集服务", "后台服务", "采集"]),
        player("linkage", "播放器联动", kw: ["启动", "退出", "联动"]),
        player("linkage", "启动时打开播放器", kw: ["联动", "启动播放器", "打开 Lyrimuse 时启动"]),
        player("linkage", "跟随播放器启动", kw: ["联动", "自动启动"]),
        player("linkage", "跟随播放器退出", kw: ["联动", "自动退出"]),

        // ---- 歌词显示 › 悬浮歌词 ----
        surface(.overlay, "桌面悬浮歌词", kw: ["开关", "悬浮窗", "总开关"], inDrawer: false),
        // 「OBS」那一组:编辑台工具栏「OBS」浮层和「全部设置」抽屉「OBS」组(19 章)。
        surface(.overlay, "OBS", kw: ["直播", "推流", "浏览器源", "录屏"]),
        surface(.overlay, "OBS 输出", sub: "作为浏览器源叠加到直播画面，宽高设为 OBS 画布尺寸",
                kw: ["OBS", "直播", "推流", "浏览器源", "录屏", "开关"], group: "OBS"),
        surface(.overlay, "浏览器源地址", kw: ["OBS", "链接", "预览", "直播", "localhost"], group: "OBS"),
        surface(.overlay, "歌名卡", sub: "左上角显示歌名、歌手和封面",
                kw: ["OBS", "歌名", "歌手", "封面", "正在播放", "直播", "换歌"], group: "OBS"),
        surface(.overlay, "允许局域网访问", sub: "同一网络中的设备可通过带密钥的链接访问",
                kw: ["局域网", "LAN", "OBS", "推流", "另一台电脑", "双机"], group: "OBS"),
        surface(.overlay, "访问链接", kw: ["OBS", ".local", "拷贝", "链接"], group: "OBS"),
        surface(.overlay, "备用链接（IP 地址）", kw: ["IP", "OBS"], group: "OBS"),
        surface(.overlay, "重置访问密钥", sub: "已分享的链接将失效", kw: ["密钥", "重新生成", "OBS"], group: "OBS"),
        surface(.overlay, "端口", sub: "更改后需同步修改 OBS 中的地址", kw: ["port", "3940", "占用", "OBS"], group: "OBS"),
        surface(.overlay, "配色主题", kw: ["预设", "默认", "墨字白边", "卡拉OK", "夜幕卡片", "磨砂玻璃", "纸白卡片", "霓虹"], group: "主题"),
        surface(.overlay, "我的配色主题", kw: ["自存", "保存主题", "改名", "覆盖"], group: "主题"),
        surface(.overlay, "字体", kw: ["字体族", "font"], group: "字形"),
        surface(.overlay, "粗细", kw: ["字重", "weight"], group: "字形"),
        surface(.overlay, "字号", kw: ["大小", "font size"], group: "字形"),
        surface(.overlay, "卡拉OK效果", kw: ["逐字", "染色", "karaoke"], group: "颜色"),
        surface(.overlay, "文字颜色", kw: ["字色", "颜色", "跟随封面"], group: "颜色"),
        surface(.overlay, "文字描边", kw: ["描边", "outline"], group: "颜色"),
        surface(.overlay, "描边颜色", kw: ["描边"], group: "颜色"),
        surface(.overlay, "未唱颜色", kw: ["卡拉OK", "未唱", "未唱颜色", "逐字", "karaoke", "跟随封面"], group: "颜色"),
        surface(.overlay, "背景颜色", kw: ["背景", "透明"], group: "颜色"),
        surface(.overlay, "毛玻璃背景", kw: ["模糊", "玻璃", "blur"], group: "颜色"),
        surface(.overlay, "玻璃浓淡", kw: ["模糊", "玻璃", "毛玻璃", "浓淡", "blur", "强度", "薄", "厚", "材质"], group: "颜色"),
        surface(.overlay, "读音", kw: ["罗马音", "罗马字", "注音", "拼音", "粤拼", "发音", "显示读音"], group: "内容"),
        surface(.overlay, "译文", kw: ["翻译", "显示译文"], group: "内容"),
        surface(.overlay, "下一句", kw: ["双行显示", "双行歌词", "两行", "副行"], group: "内容"),
        surface(.overlay, "对齐方式", kw: ["居中", "左对齐", "右对齐"], group: "排版"),
        surface(.overlay, "长句处理", kw: ["换行", "滚动", "跑马灯", "折行", "长句", "太长"], group: "排版"),
        surface(.overlay, "换句动画", kw: ["动画", "过渡", "换行动画", "上移", "LyricsX"], group: "排版"),
        surface(.overlay, "读音间距", kw: ["间距", "行距", "行间距", "距离", "罗马音", "注音", "紧凑"], group: "排版"),
        surface(.overlay, "译文间距", kw: ["间距", "行距", "行间距", "距离", "翻译", "紧凑"], group: "排版"),
        surface(.overlay, "下一句间距", kw: ["间距", "行距", "行间距", "距离", "下一行", "预览", "紧凑"], group: "排版"),
        surface(.overlay, "宽度", kw: ["窗口宽度", "pt"]),
        surface(.overlay, "锁定位置", kw: ["锁定", "拖动"], group: "行为"),
        surface(.overlay, "长按拖动", kw: ["拖动", "长按"], group: "行为"),
        surface(.overlay, "悬浮淡化", kw: ["鼠标", "指针", "淡出", "让开"], group: "行为"),
        surface(.overlay, "悬停时显示控制条", kw: ["鼠标", "指针", "悬停", "控制", "按钮", "菜单", "工具栏"], group: "行为"),
        surface(.overlay, "截屏时隐藏", kw: ["截图", "录屏", "会议", "共享屏幕", "防截屏"], group: "行为"),
        surface(.overlay, "暂停时隐藏", kw: ["自动隐藏", "暂停", "没在播放"], group: "行为"),
        surface(.overlay, "纯音乐/无歌词时隐藏", kw: ["自动隐藏", "纯音乐", "无歌词", "没有歌词", "伴奏", "instrumental"], group: "行为"),
        surface(.overlay, "广告时隐藏", kw: ["自动隐藏", "广告", "插播", "Spotify", "YouTube Music", "ad"], group: "行为"),
        surface(.overlay, "全屏时隐藏", kw: ["全屏", "隐藏", "自动隐藏", "遮挡", "看视频", "玩游戏", "fullscreen"], group: "行为"),
        // 「位置」自成一组(工具栏第二行第三颗 / 抽屉「位置」组),标题就是组名,不带 group。
        surface(.overlay, "位置", kw: ["自由", "顶部居中", "底部居中", "Dock", "预设", "对齐"]),
        surface(.overlay, "所在屏幕", kw: ["屏幕", "多屏", "外接屏", "显示器", "跟随", "跟随当前窗口", "固定"]),
        surface(.overlay, "恢复默认", sub: "不含内容、排版、行为、位置、OBS 和宽度", kw: ["重置"]),

        // ---- 歌词显示 › 灵动岛 ----
        surface(.notch, "灵动岛歌词", sub: "紧贴屏幕顶部的刘海显示", kw: ["开关", "刘海", "总开关"], inDrawer: false),
        surface(.notch, "风格", kw: ["纯黑", "毛玻璃", "磨砂玻璃", "深色渐变", "跟随封面", "背景", "强调色"]),
        surface(.notch, "圆角", kw: ["弧度", "圆弧", "收起", "跟随刘海", "pt"], group: "风格"),
        surface(.notch, "展开圆角", kw: ["弧度", "圆弧", "展开态", "跟随刘海", "pt"], group: "风格"),
        surface(.notch, "进度线", kw: ["进度条", "播放进度", "底边", "细线"], group: "风格"),
        surface(.notch, "屏幕", kw: ["自动", "全部屏幕", "所有屏幕", "指定屏幕", "显示器", "多屏", "跟随", "跟随当前窗口"]),
        surface(.notch, "左耳", kw: ["模块", "歌名", "歌手", "专辑", "封面", "播放控制", "已播时长", "剩余时长", "收听次数", "播放器"]),
        surface(.notch, "右耳", kw: ["模块", "歌名", "歌手", "专辑", "封面", "播放控制", "已播时长", "剩余时长", "收听次数", "播放器"]),
        surface(.notch, "音浪", kw: ["频谱", "音条", "律动"], group: "左耳"),
        surface(.notch, "宽度", kw: ["稳态宽", "pt"]),
        surface(.notch, "展开宽度", kw: ["展开态", "pt"]),
        surface(.notch, "收起时显示歌词", kw: ["显示歌词", "歌词行", "状态条"], group: "歌词行"),
        surface(.notch, "对齐方式", kw: ["居中", "左对齐", "右对齐"], group: "歌词行"),
        surface(.notch, "副行", kw: ["下一句", "译文", "读音", "罗马音", "两行"], group: "歌词行"),
        surface(.notch, "展开时预览下一句", kw: ["下一句", "预览"], group: "歌词行"),
        surface(.notch, "高度", kw: ["行高", "歌词行高度", "调高", "调矮", "遮挡", "pt"], group: "歌词行"),
        surface(.notch, "卡拉OK效果", kw: ["逐字", "染色", "karaoke"], group: "歌词行"),
        surface(.notch, "显示封面", kw: ["封面缩略图", "专辑图"], group: "歌词行"),
        surface(.notch, "封面位置", kw: ["左侧", "右侧", "封面"], group: "歌词行"),
        surface(.notch, "字体", kw: ["字体族", "font"], group: "字体"),
        surface(.notch, "粗细", kw: ["字重", "weight"], group: "字体"),
        surface(.notch, "字号", kw: ["大小", "font size"], group: "字体"),
        surface(.notch, "显示播放控制", kw: ["播放", "暂停", "上一首", "下一首", "三键"], group: "展开态"),
        surface(.notch, "显示歌词校准", kw: ["偏移", "校准", "时间轴"], group: "展开态"),
        surface(.notch, "快捷操作", kw: ["搜索歌词", "设置", "关闭", "图标键"], group: "展开态"),
        surface(.notch, "曲目信息", kw: ["封面", "歌名", "歌手", "专辑", "头部"], group: "展开态"),
        surface(.notch, "暂停时收起", kw: ["暂停", "收起", "缩回", "暂停缩回"], group: "行为"),
        surface(.notch, "截屏时隐藏", kw: ["截图", "录屏", "会议", "共享屏幕", "防截屏"], group: "行为"),
        surface(.notch, "暂停时隐藏", kw: ["自动隐藏", "暂停", "没在播放"], group: "行为"),
        surface(.notch, "纯音乐/无歌词时收起歌词行", kw: ["自动隐藏", "收起", "纯音乐", "无歌词", "没有歌词", "伴奏", "instrumental"], group: "行为"),
        surface(.notch, "广告时收起", kw: ["自动隐藏", "收起", "缩回", "广告", "插播", "Spotify", "YouTube Music", "ad"], group: "行为"),
        surface(.notch, "全屏时隐藏", kw: ["全屏", "隐藏", "自动隐藏", "遮挡", "看视频", "收起歌词", "fullscreen"], group: "行为"),
        surface(.notch, "收听里程碑", kw: ["里程碑", "第 100 次", "累计", "报喜", "纪念", "Last.fm"], group: "行为"),
        surface(.notch, "换歌时显示歌名", kw: ["换歌", "切歌", "歌名", "歌手", "刘海", "滑出", "掉下来", "换歌翻牌"], group: "行为"),
        surface(.notch, "触控板手势", kw: ["手势", "滑动", "切歌", "音量", "双指", "trackpad", "swipe"], group: "行为"),
        surface(.notch, "恢复默认", sub: "不含宽度和总开关", kw: ["重置"]),

        // ---- 歌词显示 › 菜单栏 ----
        surface(.menuBar, "菜单栏歌词", kw: ["开关", "跑马灯", "总开关"], inDrawer: false),
        surface(.menuBar, "歌词位置", kw: ["菜单栏正中", "图标旁", "中间", "居中", "刘海"], group: "布局"),
        surface(.menuBar, "屏幕", kw: ["显示在", "全部屏幕", "所有屏幕", "自动", "指定屏幕", "显示器", "外接屏", "多屏"], group: "布局"),
        surface(.menuBar, "宽度模式", kw: ["固定", "自适应", "宽度"], group: "布局"),
        surface(.menuBar, "对齐方式", kw: ["居中", "左对齐", "右对齐"], group: "布局"),
        surface(.menuBar, "副行", kw: ["下一句", "译文", "读音", "罗马音", "双排", "两行"], group: "布局"),
        surface(.menuBar, "歌词旁的图标", kw: ["进度图标", "图标"], group: "布局"),
        surface(.menuBar, "卡拉OK效果", kw: ["逐字", "染色", "karaoke"], group: "配色"),
        surface(.menuBar, "文字颜色", alt: ["未唱颜色"], kw: ["字色", "颜色", "跟随系统"], group: "配色"),
        surface(.menuBar, "已唱颜色", kw: ["染色", "高亮色"], group: "配色"),
        surface(.menuBar, "字体", kw: ["字体族", "font"], group: "字体"),
        surface(.menuBar, "粗细", kw: ["字重", "weight"], group: "字体"),
        surface(.menuBar, "字号", kw: ["大小", "font size"], group: "字体"),
        surface(.menuBar, "最大宽度", kw: ["宽度", "pt"]),
        surface(.menuBar, "悬停显示播放控制", kw: ["悬停", "播放控制", "鼠标"], group: "行为"),
        surface(.menuBar, "无歌词时显示歌名", kw: ["歌名", "兜底", "没有歌词"], group: "行为"),
        surface(.menuBar, "恢复默认", sub: "不含宽度和总开关", kw: ["重置"]),


        // ---- 歌词显示 › 触控栏 ----
        touchBar(touchBarToggleTitleKey, kw: ["Touch Bar", "触控栏", "功能栏", "Control Strip", "开关"]),
        touchBar("副行", kw: ["下一句", "译文", "读音", "罗马音", "两行", "双行"], group: "歌词"),
        touchBar("字号", kw: ["大小", "font size"], group: "歌词"),
        touchBar("对齐方式", kw: ["左对齐", "居中", "右对齐", "自动", "靠左", "靠右", "对唱"], group: "歌词"),
        touchBar("卡拉OK效果", kw: ["逐字", "染色", "karaoke"], group: "样式"),
        touchBar("歌词颜色", sub: "白色、跟随封面或自定义颜色", kw: ["颜色", "主色", "封面颜色", "跟随封面", "自定义", "白色"], group: "样式"),
        touchBar("暗部亮度", sub: "未唱部分与副行的亮度", kw: ["亮度", "透明度", "未唱", "副行", "太暗", "brightness"], group: "样式"),
        touchBar("显示封面", kw: ["封面缩略图", "专辑图", "位置", "左边", "右边"], group: "布局"),
        touchBar("封面位置", kw: ["位置", "左边", "右边", "封面"], group: "布局"),
        touchBar("显示播放控制", sub: "上一首、播放/暂停、下一首和设置键",
                 kw: ["播放", "暂停", "上一首", "下一首", "三键", "设置", "位置", "左边", "右边"], group: "布局"),
        touchBar("播放控制位置", kw: ["位置", "左边", "右边", "三键", "播放控制"], group: "布局"),
        touchBar("显示「更多」键", sub: "点按后切换到播放进度、歌词校准、喜欢、随机/循环和音量；当前播放器不支持的项不显示",
                 kw: ["更多", "⋯", "进度", "跳转", "校准", "偏移", "喜欢", "随机", "循环", "音量"], group: "布局"),
        touchBar("展开时隐藏功能栏", sub: "歌词占满整条触控栏；需要调节亮度、音量等时，请先点按左端的 ✕ 收起歌词",
                 kw: ["功能栏", "Control Strip", "全宽", "占满", "亮度", "音量"], group: "布局"),
        touchBar("系统功能栏", sub: "触控栏右侧的亮度、音量等系统按键，可在「系统设置 › 键盘 › 触控栏设置…」中增减或调整顺序",
                 kw: ["功能栏", "Control Strip", "触控栏设置", "自定义功能栏", "系统设置", "亮度", "音量", "Siri"],
                 group: "布局"),
        touchBar("开始播放时自动展开", kw: ["自动", "展开", "播放", "弹出", "行为"], group: "行为"),
        touchBar("暂停时自动收起", kw: ["自动", "收起", "暂停", "隐藏", "行为"], group: "行为"),
        touchBar("纯音乐/无歌词时收起", kw: ["自动", "收起", "纯音乐", "无歌词", "没有歌词", "隐藏", "行为"], group: "行为"),
        touchBar("恢复默认", sub: "不含总开关", kw: ["重置"]),

        // ---- 歌词显示 › 歌词窗口 ----
        // 预览下面那张卡「歌词窗口 [打开]」。搜「打开歌词窗口」另有快捷键那一条,各跳各的。
        lyricsWindow("歌词窗口", kw: ["打开", "打开歌词窗口", "窗口"]),
        // 「网页歌词」那一组:编辑台工具栏「网页歌词」浮层和「全部设置」抽屉「网页歌词」组(19 章),两种尺寸都有。
        // 开关那一行跟组同名,不再挂组名,路径停在「歌词窗口」。
        lyricsWindow("网页歌词", sub: "在浏览器中显示歌词窗口",
                     kw: ["网页", "浏览器", "副屏", "手机", "平板", "iPad", "web", "局域网", "二维码", "开关"]),
        lyricsWindow("本机地址", kw: ["网页", "浏览器", "打开", "localhost"], group: "网页歌词"),
        lyricsWindow("允许局域网访问", sub: "同一网络中的设备可通过带密钥的链接访问",
                     kw: ["局域网", "Wi-Fi", "LAN", "二维码", "手机", "平板", "其他设备"], group: "网页歌词"),
        lyricsWindow("允许远程控制", sub: "可在其他设备上控制播放、跳转歌词",
                     kw: ["控制", "遥控", "播放", "暂停", "切歌", "按钮", "手机"], group: "网页歌词"),
        lyricsWindow("访问链接", kw: ["二维码", "网页", ".local", "拷贝", "链接"], group: "网页歌词"),
        lyricsWindow("备用链接（IP 地址）", kw: ["IP", "安卓", "Android", "打不开"], group: "网页歌词"),
        lyricsWindow("重置访问密钥", sub: "已分享的链接将失效", kw: ["密钥", "重新生成", "失效", "安全", "链接"], group: "网页歌词"),
        lyricsWindow("端口", sub: "更改后需重新扫码连接", kw: ["port", "3939", "占用", "网页"], group: "网页歌词"),
        lyricsWindow("背景", sub: "歌词窗口的背景：跟随封面／纯色／渐变／毛玻璃",
                     kw: ["背景", "跟随封面", "纯色", "渐变", "颜色", "不透明度", "透明"],
                     group: "背景"),
        lyricsWindow("方向", kw: ["渐变", "背景", "从上到下", "从左到右", "横向", "竖向"], group: "背景"),
        lyricsWindow("玻璃浓淡", sub: "毛玻璃的材质浓淡（五档）",
                     kw: ["毛玻璃", "玻璃", "模糊", "透明", "材质", "背景", "浓淡"], group: "背景"),
        lyricsWindow("字号", sub: "迷你尺寸的歌词字号上限",
                     kw: ["字体大小", "大小", "迷你"], group: "文字"),
        // 跟悬浮歌词那条「长句处理」同名、不同段,各自跳到自己那一段。
        lyricsWindow("长句处理", sub: "迷你尺寸中一行显示不下时换行或滚动",
                     kw: ["换行", "滚动", "跑马灯", "折行", "长句", "太长", "迷你"], group: "布局"),
        lyricsWindow("歌词布局", sub: "迷你尺寸仅显示当前句、显示当前句与下一句，或与完整尺寸相同整页滚动",
                     kw: ["单行", "双行", "多行", "一行", "两行", "当前句", "下一句", "列表", "行数", "简洁", "迷你", "布局"],
                     group: "布局"),
        // 跟悬浮歌词那条「悬浮淡化」同名、不同段,各自跳到自己那一段。
        lyricsWindow("悬浮淡化", kw: ["透明", "半透明", "淡出", "让开", "悬停", "鼠标", "指针", "迷你"], group: "行为"),
        lyricsWindow("淡化时点按穿透", sub: "淡化时点按将穿透到下层窗口；按住 ⌥ 可恢复不透明并进行操作",
                     kw: ["穿透", "点击穿透", "透明", "点不到", "下面的窗口", "option", "迷你"], group: "行为"),
        // 跟悬浮歌词、灵动岛那两条同名、不同段,各自跳到自己那一段。
        lyricsWindow("暂停时隐藏", kw: ["自动隐藏", "暂停", "没在播放", "迷你"], group: "行为"),
        lyricsWindow("全屏时隐藏", kw: ["全屏", "隐藏", "自动隐藏", "遮挡", "看视频", "fullscreen", "迷你"], group: "行为"),
        lyricsWindow("卡拉OK效果", kw: ["逐字", "染色", "karaoke", "迷你", "完整"], group: "文字"),
        // 跟悬浮歌词那条「字体」同名、不同段:搜「字体」会同时列出两处,各自跳到自己那一段。
        lyricsWindow("文字颜色", sub: "歌词窗口的文字颜色；「自动」根据背景亮度在浅色与深色之间切换",
                     kw: ["颜色", "字体颜色", "文字", "浅色", "深色", "自定义", "自动"], group: "文字"),
        lyricsWindow("指定颜色", kw: ["文字颜色", "自定义", "颜色"], group: "文字"),
        lyricsWindow("字体", sub: "歌词窗口的歌词字体（正文、译文、读音）",
                     kw: ["字体", "字型", "font", "歌词窗口"], group: "文字"),
        lyricsWindow("粗细", kw: ["字重", "weight", "迷你", "完整"], group: "文字"),
        lyricsWindow("已唱颜色", kw: ["卡拉OK", "填色", "逐字", "跟随封面", "颜色", "迷你", "完整"], group: "文字"),
        lyricsWindow("HDR 高亮", kw: ["HDR", "EDR", "高亮", "提亮", "亮度", "已唱", "完整"], group: "文字"),
        // 跟灵动岛、菜单栏、触控栏那几条同名、不同段,各自跳到自己那一段。
        lyricsWindow("对齐方式", sub: "完整尺寸歌词的对齐；「自动」按对唱声部对齐",
                     kw: ["对齐", "左对齐", "居中", "右对齐", "靠左", "靠右", "对唱", "alignment"], group: "布局"),
        lyricsWindow("读音", kw: ["罗马音", "罗马字", "注音", "拼音", "粤拼", "发音", "显示读音"], group: "内容"),
        lyricsWindow("译文", kw: ["翻译", "显示译文"], group: "内容"),
        lyricsWindow("进度条", sub: "关闭后，仅在悬停显示播放控制时出现",
                     kw: ["进度", "底部", "播放进度", "隐藏进度条", "迷你", "progress"], group: "内容"),
        lyricsWindow("歌名", sub: "迷你尺寸顶部显示歌名／歌手／专辑",
                     kw: ["顶部信息", "标题", "迷你"], group: "顶部信息"),
        lyricsWindow("歌手", kw: ["顶部信息", "艺人", "迷你"], group: "顶部信息"),
        lyricsWindow("专辑", kw: ["顶部信息", "迷你"], group: "顶部信息"),
        lyricsWindow("封面", sub: "迷你尺寸顶部信息左侧的封面缩略图",
                     kw: ["顶部信息", "迷你", "专辑封面", "小图"], group: "顶部信息"),
        lyricsWindow("时间", sub: "迷你尺寸顶部显示已播放时间与歌曲时长",
                     kw: ["顶部信息", "迷你", "时长", "进度", "剩余", "已播"], group: "顶部信息"),
        lyricsWindow("宽度", sub: "迷你尺寸顶部信息占窗口宽度的百分比",
                     kw: ["顶部信息", "宽度", "百分比", "省略号", "截断", "太窄", "迷你"], group: "顶部信息"),
        lyricsWindow("高度", sub: "迷你尺寸顶部信息占窗口高度的百分比，字号与封面随之缩放",
                     kw: ["顶部信息", "高度", "百分比", "大小", "放大", "缩小", "封面", "迷你"], group: "顶部信息"),
        // 作用范围那句跟着预览停在哪个尺寸变,目录里不放副标题。
        lyricsWindow("恢复默认", kw: ["重置", "默认", "还原", "迷你", "完整"]),
        // 渐变档才出现的第二个颜色。「顶部颜色」跟「颜色」是同一行标题的两种形态(三元),
        // 扫描器只认得出这一条,登记它就够 —— 搜「颜色」由上面那条的 kw 兜住。
        lyricsWindow("底部颜色", kw: ["渐变", "颜色", "背景"], group: "背景"),
        lyricsWindow("动态封面", sub: "仅部分专辑提供；低电量或「减弱动态效果」时自动暂停",
                     kw: ["封面", "动画", "motion", "artwork", "会动", "视频"], group: "封面"),
        lyricsWindow("动态封面缓存", sub: "已下载的动态封面占用的磁盘空间；清除后再次显示时会重新下载",
                     kw: ["缓存", "磁盘", "空间", "占用", "清除", "清理", "存储", "动态封面"], group: "封面"),

        // ---- 快捷键 ----(按 LyrimuseAction.shortcutLayout 生成,见 shortcutEntries)
    ] + shortcutEntries + [

        // ---- 通用 ----
        general("菜单栏图标", kw: ["图标", "状态栏", "12 款"], group: "菜单栏与 Dock"),
        general("图标动画", kw: ["动画", "图标", "律动"], group: "菜单栏与 Dock"),
        general("在 Dock 中显示", kw: ["Dock", "程序坞", "图标"], group: "菜单栏与 Dock"),
        general("外观", sub: "设置、歌词窗口、歌词管理与菜单栏面板的配色",
                kw: ["深色", "浅色", "自动", "深色模式", "浅色模式", "暗色", "夜间", "主题", "dark", "light"], group: "外观与语言"),
        general("语言", kw: ["简体中文", "繁體中文", "English", "跟随系统", "界面语言"], group: "外观与语言"),
        general("开机启动", kw: ["登录项", "登录时打开", "自动启动", "启动"], group: "启动与通知"),
        general("静默启动", kw: ["静默", "后台启动", "不打开窗口", "最小化", "启动", "菜单栏", "silent"], group: "启动与通知"),
        general("换歌时显示通知", kw: ["通知", "切歌", "换歌", "正在播放", "横幅", "系统通知"], group: "启动与通知"),
        general("代理", kw: ["代理", "网络", "Clash", "VPN", "系统代理", "代理服务器", "端口", "proxy", "socks"], group: "网络"),
        general("iCloud 备份", alt: ["备份文件夹"], kw: ["备份", "迁移", "搬家", "同步", "文件夹"], group: "备份与迁移"),
        general("设置文件", sub: "含明文凭证；导出为设置与歌词库两个文件，导入将覆盖全部设置", kw: ["导出", "导入", "备份", "JSON"], group: "备份与迁移"),
        general("清除全部设置", sub: "仅清除本机设置，备份与导出的文件不受影响；无法撤销", kw: ["重置", "恢复出厂", "删除", "清除所有设置"],
                group: "备份与迁移"),

        // ---- 关于 ----
        // 「软件更新」页。「软件更新」同时也是「关于 › 更新与帮助」卡里那一行入口的标题,目的地都是这一页。
        softwareUpdate("软件更新", kw: ["更新", "Sparkle", "版本", "检查更新", "升级"], group: nil),
        softwareUpdate("自动检查", sub: "每天检查一次新版本", kw: ["更新", "自动"], group: "更新设置"),
        softwareUpdate("自动下载并安装", sub: "在后台下载，退出 Lyrimuse 时安装", kw: ["更新", "自动"], group: "更新设置"),
        softwareUpdate("测试版更新", sub: "预发布版本，可能不稳定", kw: ["beta", "测试版", "预发布"], group: "更新设置"),
        about("反馈问题", sub: "在 GitHub 新建 issue，自动附带版本、系统与播放器信息", kw: ["issue", "bug", "反馈", "建议", "github", "邮件", "邮箱", "email"], group: "更新与帮助"),
        about("使用求助", sub: "在 GitHub 讨论区的问答分类中提问", kw: ["discussion", "求助", "提问", "问答", "help"], group: "更新与帮助"),
        about("功能清单", sub: "全部功能、所在位置及默认状态", kw: ["全部功能", "功能列表", "功能介绍", "默认", "设置项", "features"], group: "更新与帮助"),
        about("Discord 社区", sub: "与其他用户交流，也可在此提问或提出建议", kw: ["discord", "社区", "社群", "交流", "聊天", "community"], group: nil),
        about("Telegram 群组", sub: "与其他用户交流，也可在此提问或提出建议", kw: ["telegram", "电报", "群组", "社群", "交流", "聊天", "community"], group: nil),
        about("版权说明", kw: ["版权", "歌词版权"], group: nil),
        about("第三方许可", sub: "开源组件与词典", kw: ["许可证", "开源", "license"], group: nil),
        about("开源许可证", sub: "GPL-3.0", kw: ["GPL", "许可证", "license"], group: nil),
        about("导出诊断", sub: "打包日志、崩溃记录与运行状态，已移除账号凭据；含曲目名与本机路径，公开前请检查", kw: ["诊断", "日志", "排查", "反馈"], group: "诊断与数据"),
        about("运行日志", sub: "歌词引擎的原始日志，供自行排查", kw: ["日志", "log", "排查", "访达"], group: "诊断与数据"),
        about("配置文件夹", sub: "纯文本格式，不含账号凭据、外观与快捷键；完整迁移请使用「备份与迁移」", kw: ["config", "配置", "文件夹", "路径"], group: "诊断与数据"),

        // ---- 账号 ----
        account("listenBrainz", path: ["ListenBrainz"], "账号信息", kw: ["ListenBrainz", "token", "令牌", "用户名", "连接"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "Scrobble 规则", kw: ["Last.fm", "scrobble", "记录", "规则"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "匹配模式", kw: ["Last.fm", "scrobble", "合唱", "歌手", "歌名", "曲名", "繁简", "匹配"]),
        // 「匹配模式」选了「自定义」才出现的两个维度。照样登记:用户搜「繁简」「合唱」时
        // 该找得到它们,找到了再去把档位切到自定义 —— 搜不到才是坏体验。标题本身只剩字段名,
        // 所以关键词要把「改写 / 合唱 / 第一位」这些用户嘴里的说法都收进来。
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "歌名", kw: ["Last.fm", "scrobble", "歌名", "曲名", "繁简", "改写", "匹配", "编目", "自定义"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "歌手", kw: ["Last.fm", "scrobble", "歌手", "合唱", "第一位", "改写", "匹配", "编目", "自定义"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "Scrobble 时机", kw: ["Last.fm", "scrobble", "50%", "曲终"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "短于 30 秒的曲目", kw: ["Last.fm", "scrobble", "短曲"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "Scrobble 的播放器", kw: ["Last.fm", "scrobble", "播放器", "排除", "不上送", "浏览器"]),
        account("stateRelay", path: ["网页推送"], "连接信息", kw: ["中继", "网页", "relay", "worker", "推送"]),
        account("bark", path: ["推送提醒"], "推送渠道", kw: ["推送", "渠道", "通知", "添加渠道", "发送测试", "webhook", "Bark", "Telegram", "钉钉", "飞书",
                                                        "企业微信", "Discord", "Slack", "Server酱", "ntfy", "通用 Webhook",
                                                        "启用", "停用", "预览"]),
        account("bark", path: ["推送提醒"], "推送时间", kw: ["推送时间", "几点", "时间", "定时", "时区", "发送时间", "推送", "免打扰", "静默"]),
        account("bark", path: ["推送提醒"], "听歌报告", kw: ["推送", "通知", "提醒", "日报", "周报", "月报", "年报",
                                                        "推到", "全部渠道", "选择渠道"]),
        account("bark", path: ["推送提醒"], "数据来源", kw: ["数据源", "Last.fm", "ListenBrainz", "听歌报告"]),
        account("bark", path: ["推送提醒"], "每类列出", kw: ["条数", "前几名", "Top", "排行", "歌手", "专辑", "歌曲", "听歌报告"]),
        account("bark", path: ["推送提醒"], "每周听歌小结", kw: ["周报", "推送", "Bark"]),
        account("bark", path: ["推送提醒"], "每日听歌报告", kw: ["日报", "推送", "Bark"]),
        account("bark", path: ["推送提醒"], "每月听歌小结", kw: ["月报", "推送", "Bark", "专辑"]),
        account("bark", path: ["推送提醒"], "年度听歌小结", kw: ["年报", "年度", "推送", "Bark", "专辑"]),
        account("bark", path: ["推送提醒"], "推送记录", kw: ["推送", "记录", "失败", "重发", "送达", "历史"]),
        account("discord", path: ["Discord"], "在 Discord 上显示", kw: ["Discord", "正在听", "状态", "资料卡", "Rich Presence"]),
        account("discord", path: ["Discord"], sectionValue: "display", "显示内容", kw: ["Discord", "状态", "角标", "暂停"]),
        account("discord", path: ["Discord"], sectionValue: "display", "「正在收听」后面显示",
                kw: ["Discord", "正在听", "正在收听", "资料卡", "播放器", "歌名", "歌手"]),
        account("discord", path: ["Discord"], sectionValue: "display", "用户名下方显示", kw: ["Discord", "好友列表", "成员列表", "状态", "歌名", "歌手", "播放器"]),
        account("discord", path: ["Discord"], sectionValue: "display", "封面角标", kw: ["Discord", "角标", "小图", "图标", "Lyrimuse", "播放器", "官网"]),
        account("discord", path: ["Discord"], sectionValue: "display", "暂停后", kw: ["Discord", "暂停", "保留", "清掉", "进度条"]),
        account("discord", path: ["Discord"], sectionValue: "display", "歌曲信息",
                kw: ["Discord", "歌名", "歌手", "专辑", "歌词", "当前歌词", "第一行", "第二行", "第三行", "顺序", "合并", "资料卡"]),
        account("discord", path: ["Discord"], sectionValue: "display", "状态文字", kw: ["Discord", "正在收听", "用户名", "好友列表"]),
        account("discord", path: ["Discord"], sectionValue: "display", "封面与进度", kw: ["Discord", "封面", "角标", "进度条", "暂停"]),
        account("discord", path: ["Discord"], sectionValue: "display", "为歌手和专辑添加前缀", kw: ["Discord", "演唱", "专辑", "前缀", "by", "on"]),
        account("discord", path: ["Discord"], sectionValue: "buttons", "按钮", kw: ["Discord", "按钮", "链接", "button"]),
        account("discord", path: ["Discord"], sectionValue: "buttons", "自定义按钮", kw: ["Discord", "按钮", "自定义", "链接", "button"]),
        account("discord", path: ["Discord"], sectionValue: "buttons", "「在播放器上收听」", kw: ["Discord", "按钮", "收听", "歌曲页", "链接"]),
        account("discord", path: ["Discord"], sectionValue: "buttons", "「获取 Lyrimuse」", kw: ["Discord", "按钮", "官网", "Lyrimuse"]),
        account("discord", path: ["Discord"], sectionValue: "privacy", "隐私", kw: ["Discord", "隐藏", "播放器", "不显示"]),
        account("discord", path: ["Discord"], sectionValue: "privacy", "暂时隐藏", kw: ["Discord", "隐藏", "暂时", "隐私", "不显示"]),
        account("discord", path: ["Discord"], sectionValue: "privacy", "隐藏歌曲信息", kw: ["Discord", "隐私", "隐藏歌名", "不显示", "匿名"]),
        account("discord", path: ["Discord"], sectionValue: "display", "显示进度条", kw: ["Discord", "进度条", "时间", "隐私"]),
        account("discord", path: ["Discord"], sectionValue: "privacy", "显示哪些播放器", kw: ["Discord", "播放器", "排除", "浏览器"]),
    ]
}

/// 匹配与排序:纯函数,App 侧把本地化后的字段喂进来。
public enum SettingsSearchMatcher {
    /// 去首尾空白、小写、连续空白折成一个。CJK 没有大小写,这一步对它是恒等。
    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 命中等级:0 = 标题以查询开头,1 = 标题包含,2 = 只在副标题/关键词/面包屑里;nil = 不命中。
    /// 查询按空白拆成多个词,**每个词**都得在标题或次要字段里出现,等级取最好的那个词决定的标题命中。
    public static func rank(query: String, title: String, secondary: [String]) -> Int? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        let terms = q.split(separator: " ").map(String.init)
        let t = normalize(title)
        let others = secondary.map(normalize)
        var best = 3
        for term in terms {
            if t.hasPrefix(term) { best = min(best, 0); continue }
            if t.contains(term) { best = min(best, 1); continue }
            if others.contains(where: { $0.contains(term) }) { best = min(best, 2); continue }
            return nil
        }
        return best == 3 ? nil : best
    }

    /// 按等级稳定排序(同级保持目录顺序),不命中的剔掉。
    public static func ranked<T>(_ items: [T], query: String, title: (T) -> String, secondary: (T) -> [String]) -> [T] {
        let scored: [(Int, Int, T)] = items.enumerated().compactMap { index, item in
            rank(query: query, title: title(item), secondary: secondary(item)).map { ($0, index, item) }
        }
        return scored.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }.map { $0.2 }
    }
}
