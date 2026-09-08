import Foundation

// 设置搜索的目录(2026-09-09,借鉴清单 S8)。
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
//     (「歌词来源」卡登记九个源名,搜「QQ」能落到那张卡)。不是 L10n 键,守卫不核。
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

    public init(destination: Destination, sectionKey: String? = nil, sectionValue: String? = nil,
                drawer: LyricsSurface? = nil, titleKey: String, alternateTitleKeys: [String] = [],
                subtitleKey: String? = nil, keywords: [String] = [], pathKeys: [String]) {
        self.destination = destination
        self.sectionKey = sectionKey
        self.sectionValue = sectionValue
        self.drawer = drawer
        self.titleKey = titleKey
        self.alternateTitleKeys = alternateTitleKeys
        self.subtitleKey = subtitleKey
        self.keywords = keywords
        self.pathKeys = pathKeys
    }

    public var id: String {
        let dest: String
        switch destination {
        case .tab(let raw): dest = "tab:\(raw)"
        case .account(let name): dest = "account:\(name)"
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
    /// Last.fm 账号页分段的 @AppStorage 键(AccountLinkingTab.swift)。它带 `np:` 前缀是历史原因,
    /// 这里只写不新建。
    public static let lastfmSectionKey = "np:lastfmDetailSection"

    /// 面包屑里不是 L10n 键的品牌名(AccountDestination.title 对这两个直接返回字面量)。守卫核
    /// 键是否在 catalog 里时跳过它们。
    public static let brandPathComponents: Set<String> = ["ListenBrainz", "Last.fm"]

    // MARK: - 构造小工具(只在本文件用)

    private static func lyrics(_ section: String, _ title: String, alt: [String] = [], sub: String? = nil,
                               kw: [String] = [], group: String? = nil) -> SettingsSearchEntry {
        let sectionTitle: String
        switch section {
        case "fetch": sectionTitle = "获取"
        case "translation": sectionTitle = "译文"
        case "display": sectionTitle = "效果"
        default: sectionTitle = "管理"
        }
        return SettingsSearchEntry(destination: .tab("lyrics"), sectionKey: lyricsSectionKey, sectionValue: section,
                                   titleKey: title, alternateTitleKeys: alt, subtitleKey: sub, keywords: kw,
                                   pathKeys: ["歌词", sectionTitle] + (group.map { [$0] } ?? []))
    }

    private static func player(_ title: String, sub: String? = nil, kw: [String] = [], group: String? = nil) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("player"), titleKey: title, subtitleKey: sub, keywords: kw,
                            pathKeys: ["播放器"] + (group.map { [$0] } ?? []))
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

    private static func shortcut(_ title: String, sub: String? = nil, kw: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("shortcuts"), titleKey: title, subtitleKey: sub,
                            keywords: kw + ["快捷键", "hotkey"], pathKeys: ["快捷键"])
    }

    private static func general(_ title: String, alt: [String] = [], sub: String? = nil, kw: [String] = [],
                                group: String? = nil) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("general"), titleKey: title, alternateTitleKeys: alt, subtitleKey: sub,
                            keywords: kw, pathKeys: ["通用"] + (group.map { [$0] } ?? []))
    }

    private static func about(_ title: String, sub: String? = nil, kw: [String] = [], group: String) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .tab("about"), titleKey: title, subtitleKey: sub, keywords: kw,
                            pathKeys: ["关于", group])
    }

    private static func account(_ name: String, path: [String], sectionValue: String? = nil, _ title: String,
                                kw: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(destination: .account(name),
                            sectionKey: sectionValue == nil ? nil : lastfmSectionKey, sectionValue: sectionValue,
                            titleKey: title, keywords: kw, pathKeys: path)
    }

    // MARK: - 目录本体

    public static let entries: [SettingsSearchEntry] = [
        // ---- 歌词 › 获取 ----
        lyrics("fetch", "歌词来源", kw: ["歌词源", "网易云音乐", "QQ音乐", "酷狗", "Musixmatch", "LRCLIB", "AMLL",
                                      "LyricFind", "酷我", "咪咕", "测试", "顺序"]),
        lyrics("fetch", "匹配算法", kw: ["智能", "顺序优先", "打分"]),
        lyrics("fetch", "跟进算法升级", kw: ["重打分", "自动升级"]),
        lyrics("fetch", "提前解析同专辑其它曲目", kw: ["预解析", "专辑"]),
        lyrics("fetch", "锁定手选歌词", kw: ["手动选定", "锁定"]),
        // ---- 歌词 › 译文 ----
        lyrics("translation", "显示译文", kw: ["翻译"]),
        lyrics("translation", "译文语言", kw: ["翻译", "语言"]),
        lyrics("translation", "系统兜底翻译", kw: ["机翻", "MyMemory", "翻译"]),
        lyrics("translation", "翻译语言包", kw: ["下载", "语言包", "Apple 翻译"]),
        // ---- 歌词 › 效果 ----
        lyrics("display", "繁简转换", kw: ["繁体", "简体", "OpenCC"]),
        lyrics("display", "显示罗马音", kw: ["罗马字", "注音", "拼音", "粤拼", "发音"]),
        lyrics("display", "标注哪些语言", kw: ["日语", "韩语", "中文", "罗马音"]),
        lyrics("display", "全局时间轴偏移", kw: ["歌词偏移", "提前", "延后", "校准", "同步"]),
        // ---- 歌词 › 管理 ----
        lyrics("manage", "歌词库", kw: ["歌词管理", "统计", "缓存"]),
        lyrics("manage", "歌词文件夹", kw: ["lyrics", "自定义位置", "目录", "lrc"]),

        // ---- 播放器 ----
        player("播放器", kw: ["Apple Music", "QQ音乐", "网易云音乐", "酷狗音乐", "Spotify", "自动识别", "多选"]),
        player("网页播放器", kw: ["YouTube Music", "Spotify", "浏览器", "Chrome", "Safari", "Edge", "Arc"]),
        player("已信任的播放器", kw: ["信任列表", "其它播放器"]),
        player("新播放器提醒", sub: "系统通知已关闭", kw: ["通知", "未知播放器"]),
        player("Apple Music 自动化", kw: ["权限", "AppleScript", "自动化"]),
        player("后台采集服务", kw: ["collector", "launchd", "服务", "运行状态"]),
        player("播放器联动", kw: ["启动", "退出", "联动"]),
        player("打开 Lyrimuse 时启动", kw: ["联动", "启动播放器"], group: "播放器联动"),
        player("跟随播放器启动", kw: ["联动", "自动启动"], group: "播放器联动"),
        player("跟随播放器退出", kw: ["联动", "自动退出"], group: "播放器联动"),

        // ---- 歌词显示 › 悬浮歌词 ----
        surface(.overlay, "桌面悬浮歌词", kw: ["开关", "悬浮窗", "总开关"], inDrawer: false),
        surface(.overlay, "跟随封面", kw: ["封面色", "取色", "配色"], group: "主题"),
        surface(.overlay, "配色主题", kw: ["预设", "经典白字", "白字描边", "经典黑字", "黑字描边", "深色卡片", "浅色卡片"], group: "主题"),
        surface(.overlay, "我的配色主题", kw: ["自存", "保存主题"], group: "主题"),
        surface(.overlay, "字体", kw: ["字体族", "font"], group: "文字"),
        surface(.overlay, "粗细", kw: ["字重", "weight"], group: "文字"),
        surface(.overlay, "字号", kw: ["大小", "font size"], group: "文字"),
        surface(.overlay, "卡拉OK效果", kw: ["逐字", "染色", "karaoke"], group: "文字"),
        surface(.overlay, "文字颜色", kw: ["字色", "颜色"], group: "文字"),
        surface(.overlay, "文字描边", kw: ["描边", "outline"], group: "文字"),
        surface(.overlay, "描边颜色", kw: ["描边"], group: "文字"),
        surface(.overlay, "背景颜色", kw: ["背景", "透明"], group: "背景"),
        surface(.overlay, "毛玻璃背景", kw: ["模糊", "玻璃", "blur"], group: "背景"),
        surface(.overlay, "双行显示", kw: ["两行", "副行", "下一句"], group: "排版"),
        surface(.overlay, "对齐方式", kw: ["居中", "左对齐", "右对齐"], group: "排版"),
        surface(.overlay, "宽度", kw: ["窗口宽度", "pt"]),
        surface(.overlay, "锁定位置", kw: ["锁定", "拖动"], group: "行为"),
        surface(.overlay, "长按拖动", kw: ["拖动", "长按"], group: "行为"),
        surface(.overlay, "悬浮淡化", kw: ["鼠标", "指针", "淡出", "让开"], group: "行为"),
        surface(.overlay, "截屏/录屏时隐藏", kw: ["截图", "录屏", "会议", "共享屏幕"], group: "行为"),
        surface(.overlay, "暂停/无播放时隐藏", kw: ["自动隐藏", "暂停"], group: "行为"),
        surface(.overlay, "恢复默认", sub: "不含排版、行为和宽度", kw: ["重置"]),

        // ---- 歌词显示 › 灵动岛 ----
        surface(.notch, "灵动岛歌词", sub: "紧凑地贴着屏幕顶部的刘海显示", kw: ["开关", "刘海", "总开关"], inDrawer: false),
        surface(.notch, "风格", kw: ["纯黑", "磨砂玻璃", "深色渐变", "跟随封面", "背景", "强调色"]),
        surface(.notch, "屏幕", kw: ["自动", "所有屏幕", "指定屏幕", "显示器", "多屏"]),
        surface(.notch, "左耳", kw: ["模块", "歌名", "歌手", "专辑", "封面", "播放控制", "已播时长", "剩余时长"]),
        surface(.notch, "右耳", kw: ["模块", "歌名", "歌手", "专辑", "封面", "播放控制", "已播时长", "剩余时长"]),
        surface(.notch, "音浪", kw: ["频谱", "音条", "律动"], group: "左耳"),
        surface(.notch, "宽度", kw: ["稳态宽", "pt"]),
        surface(.notch, "展开宽度", kw: ["展开态", "pt"]),
        surface(.notch, "显示歌词", kw: ["歌词行", "状态条"], group: "歌词行"),
        surface(.notch, "对齐方式", kw: ["居中", "左对齐", "右对齐"], group: "歌词行"),
        surface(.notch, "副行", kw: ["下一句", "译文", "罗马音", "两行"], group: "歌词行"),
        surface(.notch, "展开时预览下一句", kw: ["下一句", "预览"], group: "歌词行"),
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
        surface(.notch, "暂停缩回", kw: ["暂停", "收起", "缩回"], group: "行为"),
        surface(.notch, "截屏/录屏时隐藏", kw: ["截图", "录屏", "会议", "共享屏幕"], group: "行为"),
        surface(.notch, "暂停/无播放时隐藏", kw: ["自动隐藏", "暂停"], group: "行为"),
        surface(.notch, "恢复默认", sub: "不含宽度和总开关", kw: ["重置"]),

        // ---- 歌词显示 › 菜单栏 ----
        surface(.menuBar, "菜单栏歌词", kw: ["开关", "跑马灯", "总开关"], inDrawer: false),
        surface(.menuBar, "宽度模式", kw: ["固定", "自适应", "宽度"], group: "布局"),
        surface(.menuBar, "对齐方式", kw: ["居中", "左对齐", "右对齐"], group: "布局"),
        surface(.menuBar, "副行", kw: ["下一句", "译文", "罗马音", "双排", "两行"], group: "布局"),
        surface(.menuBar, "歌词旁的图标", kw: ["进度图标", "图标"], group: "布局"),
        surface(.menuBar, "卡拉OK效果", kw: ["逐字", "染色", "karaoke"], group: "配色"),
        surface(.menuBar, "文字颜色", alt: ["未唱到的颜色"], kw: ["字色", "颜色", "跟随系统"], group: "配色"),
        surface(.menuBar, "已唱到的颜色", kw: ["染色", "高亮色"], group: "配色"),
        surface(.menuBar, "粗细", kw: ["字重", "weight"], group: "字体"),
        surface(.menuBar, "字号", kw: ["大小", "font size"], group: "字体"),
        surface(.menuBar, "最大宽度", kw: ["宽度", "pt"]),
        surface(.menuBar, "悬停显示播放控制", kw: ["悬停", "播放控制", "鼠标"], group: "行为"),
        surface(.menuBar, "无歌词时显示歌名", kw: ["歌名", "兜底", "没有歌词"], group: "行为"),
        surface(.menuBar, "恢复默认", sub: "不含宽度和总开关", kw: ["重置"]),

        // ---- 快捷键 ----
        shortcut("显示/隐藏悬浮歌词", kw: ["悬浮歌词", "开关"]),
        shortcut("显示/隐藏灵动岛歌词", kw: ["灵动岛", "开关"]),
        shortcut("显示/隐藏菜单栏歌词", kw: ["菜单栏", "开关"]),
        shortcut("锁定/解锁位置", kw: ["锁定", "位置"]),
        shortcut("显示/隐藏译文", kw: ["译文", "翻译"]),
        shortcut("显示/隐藏发音", kw: ["罗马音", "发音"]),
        shortcut("打开歌词管理", kw: ["歌词管理", "窗口"]),
        shortcut("打开歌词窗口", kw: ["歌词窗口", "窗口"]),
        shortcut("搜索歌词", kw: ["手动搜索", "换歌词"]),
        shortcut("打开设置", kw: ["设置窗口"]),
        shortcut("歌词提前", kw: ["偏移", "时间轴", "校准"]),
        shortcut("歌词延后", kw: ["偏移", "时间轴", "校准"]),
        shortcut("歌词偏移归零", kw: ["偏移", "重置", "时间轴"]),
        shortcut("步长", sub: "每按一次调整的幅度", kw: ["偏移", "幅度"]),
        shortcut("播放/暂停", kw: ["播放控制"]),
        shortcut("下一首", kw: ["播放控制", "切歌"]),
        shortcut("上一首", kw: ["播放控制", "切歌"]),

        // ---- 通用 ----
        general("菜单栏图标", kw: ["图标", "状态栏", "12 款"], group: "菜单栏与 Dock"),
        general("随播放律动", kw: ["动画", "图标", "律动"], group: "菜单栏与 Dock"),
        general("在 Dock 中显示", kw: ["Dock", "程序坞", "图标"], group: "菜单栏与 Dock"),
        general("语言", kw: ["简体中文", "繁體中文", "English", "跟随系统", "界面语言"], group: "语言与启动"),
        general("开机启动", kw: ["登录项", "自动启动", "启动"], group: "语言与启动"),
        general("iCloud 备份", alt: ["备份文件夹"], kw: ["备份", "迁移", "搬家", "同步", "文件夹"], group: "备份与迁移"),
        general("设置文件", sub: "含明文凭证；导入会覆盖全部设置并重启", kw: ["导出", "导入", "备份", "JSON"], group: "备份与迁移"),
        general("清除所有设置", sub: "本机设置，无法撤销", kw: ["重置", "恢复出厂", "删除"]),

        // ---- 关于 ----
        about("检查更新", kw: ["更新", "Sparkle", "版本"], group: "更新"),
        about("自动检查", kw: ["更新", "自动"], group: "更新"),
        about("自动下载并安装", kw: ["更新", "自动"], group: "更新"),
        about("测试版更新", sub: "预发布版本，可能不稳定", kw: ["beta", "测试版", "预发布"], group: "更新"),
        about("反馈问题", sub: "GitHub Issues", kw: ["issue", "bug", "反馈"], group: "反馈与社区"),
        about("想法与建议", sub: "GitHub Discussions", kw: ["discussion", "建议"], group: "反馈与社区"),
        about("版权说明", kw: ["版权", "歌词版权"], group: "许可与版权"),
        about("第三方许可", sub: "开源组件与词典", kw: ["许可证", "开源", "license"], group: "许可与版权"),
        about("开源许可证", sub: "GPL-3.0", kw: ["GPL", "许可证", "license"], group: "许可与版权"),
        about("导出诊断", sub: "不含账号与密钥", kw: ["诊断", "日志", "排查"], group: "诊断与数据"),
        about("配置文件夹", kw: ["config", "配置", "文件夹", "路径"], group: "诊断与数据"),

        // ---- 账号 ----
        account("listenBrainz", path: ["ListenBrainz"], "账户信息", kw: ["ListenBrainz", "token", "令牌", "用户名", "连接"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "Scrobble", kw: ["Last.fm", "scrobble", "记录"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "合唱歌曲的歌手", kw: ["Last.fm", "scrobble", "合唱", "歌手"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "Scrobble 时机", kw: ["Last.fm", "scrobble", "50%", "曲终"]),
        account("lastfm", path: ["Last.fm", "设置"], sectionValue: "settings", "短于 30 秒的曲目", kw: ["Last.fm", "scrobble", "短曲"]),
        account("stateRelay", path: ["网页推送"], "连接信息", kw: ["中继", "网页", "relay", "worker", "推送"]),
        account("bark", path: ["推送提醒"], "提醒", kw: ["Bark", "推送", "webhook", "通知"]),
        account("bark", path: ["推送提醒"], "每周听歌小结", kw: ["周报", "推送", "Bark"]),
        account("bark", path: ["推送提醒"], "每日听歌报告", kw: ["日报", "推送", "Bark"]),
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
