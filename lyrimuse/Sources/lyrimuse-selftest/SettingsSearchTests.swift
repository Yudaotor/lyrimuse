import LyrimuseCore
import Foundation

// 设置搜索:Core 目录 与 源码调用点 与 本地化 catalog 三方对账,加匹配器纯函数。
//
// 目录是静态表,会漂;这一组守的就是"漂了要红":
//   1. 目录自身:id 不重复、面包屑非空、目的地 / 分段取值跟 SettingsView / AccountLinkingTab 里的枚举
//      对得上(那些枚举没有 rawValue 契约,只能扫源码文本);
//   2. 目录里每个 L10n 键都在 Localizable.xcstrings 里(表里的键是裸字符串,contracts 组那条
//      「源码里的 L10n.t 字面量都在 catalog 里」扫不到它们);
//   3. 覆盖:源码里每一处 `SettingsRow(` / `SettingsSubRow(` / `SettingsCardHeader(` / `PlayerBundleChipsRow(` 的字面量标题、
//      三个"标题在枚举里"的行族(OverlayBehaviorItem / AutoHideItem / NotchBehaviorItem),都得在目录里,
//      刻意不登记的写进下面的白名单——白名单里的项反过来也必须真的被扫到,免得成了死条目;
//   4. 匹配器:等级、多词、大小写、排序稳定。
// 跟 contracts 组一样是纯文本扫描,注释里若出现 `SettingsRow(title: L10n.t("…"))` 这种完整写法会被当成
// 调用点;真要在注释里提,别写全。

@MainActor
func runSettingsSearchTests() {
    let entries = SettingsSearchCatalog.entries
    let sourcesDir = URL(fileURLWithPath: #filePath)     // …/Sources/lyrimuse-selftest/SettingsSearchTests.swift
        .deletingLastPathComponent()                     // …/Sources/lyrimuse-selftest
        .deletingLastPathComponent()                     // …/Sources
    let appDir = sourcesDir.appendingPathComponent("lyrimuse")
    let catalogPath = sourcesDir.deletingLastPathComponent()
        .appendingPathComponent("Localization/Localizable.xcstrings").path

    func source(_ relative: String) -> String {
        let text = (try? String(contentsOfFile: appDir.appendingPathComponent(relative).path, encoding: .utf8)) ?? ""
        expectEqual(text.isEmpty, false, "设置搜索: 读到了 \(relative)")
        return text
    }

    /// `enum X` 之后那几行 `case a, b, c` 声明里的名字(到第一个 var / func / init / `}` 为止)。
    /// switch 里的 `case .a:` 带点和冒号,不会被算进来。
    func enumCaseNames(after marker: String, in text: String) -> [String] {
        guard let range = text.range(of: marker) else { return [] }
        var names: [String] = []
        for rawLine in text[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("var ") || line.hasPrefix("func ") || line.hasPrefix("init") || line == "}" { break }
            guard line.hasPrefix("case "), !line.contains(":"), !line.contains(".") else { continue }
            names += line.dropFirst("case ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return names
    }

    // ---- 1. 目录自身 ----
    expectEqual(entries.count >= 100, true, "设置搜索: 目录至少 100 条(实际 \(entries.count))")
    let ids = entries.map(\.id)
    expectEqual(Set(ids).count, ids.count, "设置搜索: 条目 id 不重复")
    expectEqual(entries.filter { $0.pathKeys.isEmpty }.map(\.titleKey), [], "设置搜索: 每条都有面包屑")
    expectEqual(entries.filter { $0.titleKey.isEmpty }.count, 0, "设置搜索: 标题键非空")

    let settingsView = source("SettingsView.swift")
    let accountTab = source("AccountLinkingTab.swift")
    let tabCases = enumCaseNames(after: "enum SettingsTab:", in: settingsView)
    expectEqual(tabCases, ["lyrics", "player", "appearance", "shortcuts", "general", "about"], "设置搜索: 扫到了 SettingsTab 的六个 case")
    let accountCases = enumCaseNames(after: "enum AccountDestination:", in: accountTab)
    expectEqual(accountCases, ["listenBrainz", "lastfm", "stateRelay", "bark", "discord"], "设置搜索: 扫到了 AccountDestination 的五个 case")
    let lyricsSectionCases: [String] = {
        guard let structRange = settingsView.range(of: "struct LyricsSettingsTab") else { return [] }
        return enumCaseNames(after: "private enum Section:", in: String(settingsView[structRange.upperBound...]))
    }()
    expectEqual(lyricsSectionCases, ["fetch", "translation", "display", "manage"], "设置搜索: 扫到了「歌词」页四个分段")
    let lastfmSectionCases = enumCaseNames(after: "private enum LastfmSection:", in: accountTab)
    expectEqual(lastfmSectionCases.contains("settings"), true, "设置搜索: Last.fm 页有「设置」分段")
    expectEqual(settingsView.contains("@AppStorage(\"\(SettingsSearchCatalog.lyricsSectionKey)\")"), true,
                "设置搜索: 「歌词」页分段键名与源码一致")
    expectEqual(accountTab.contains("@AppStorage(\"\(SettingsSearchCatalog.lastfmSectionKey)\")"), true,
                "设置搜索: Last.fm 页分段键名与源码一致")
    let discordSectionCases = enumCaseNames(after: "private enum DiscordSection:", in: accountTab)
    expectEqual(discordSectionCases, ["display", "buttons", "privacy"], "设置搜索: Discord 页三个分段")
    expectEqual(accountTab.contains("@AppStorage(SettingsSearchCatalog.discordSectionKey)"), true,
                "设置搜索: Discord 页分段键取目录常量")
    let playerSectionCases: [String] = {
        guard let structRange = settingsView.range(of: "struct PlayerSettingsTab") else { return [] }
        return enumCaseNames(after: "private enum Section:", in: String(settingsView[structRange.upperBound...]))
    }()
    expectEqual(playerSectionCases, ["players", "linkage", "permissions"], "设置搜索: 「播放器」页三个分段")
    expectEqual(SettingsSearchCatalog.playerSectionDefault, playerSectionCases.first,
                "设置搜索: 「播放器」页默认分段 = 枚举第一个 case")

    // ---- 分段的默认值:设置窗前进 / 后退要拿它还原「这一页还没换过分段」那个位置 ----
    //
    // 顶层(SettingsView 的 `section(of:)`)读的是同一批键的**第二份** @AppStorage,默认值跟那一页
    // 自己的对不上就会把"一次都没换过"记成另一段,后退回去换错段 —— 而两边都编译得过。各页的默认
    // 段就是分段枚举的第一个 case,这里按源码钉死。
    let appearanceSectionCases: [String] = {
        guard let structRange = settingsView.range(of: "struct AppearanceSettingsTab") else { return [] }
        return enumCaseNames(after: "private enum Section:", in: String(settingsView[structRange.upperBound...]))
    }()
    // 前三段跟 LyricsSurface 一一对应;第四段「触控栏」、第五段「歌词窗口」都不是 LyricsSurface
    // (触控栏不按宽度断句,歌词窗口没有常驻开关),取值只在目录那边各有一份常量。
    expectEqual(appearanceSectionCases,
                LyricsSurface.allCases.map(\.appearanceSectionRawValue)
                    + [SettingsSearchCatalog.touchBarSectionValue, SettingsSearchCatalog.lyricsWindowSectionValue],
                "设置搜索: 「歌词显示」页前三段跟 LyricsSurface 一一对应,第四段是触控栏、第五段是歌词窗口")
    expectEqual(SettingsSearchCatalog.lyricsSectionDefault, lyricsSectionCases.first,
                "设置搜索: 「歌词」页默认分段 = 枚举第一个 case")
    expectEqual(SettingsSearchCatalog.lastfmSectionDefault, lastfmSectionCases.first,
                "设置搜索: Last.fm 页默认分段 = 枚举第一个 case")
    expectEqual(SettingsSearchCatalog.discordSectionDefault, discordSectionCases.first,
                "设置搜索: Discord 页默认分段 = 枚举第一个 case")
    expectEqual(LyricsSurface.overlay.appearanceSectionRawValue, appearanceSectionCases.first,
                "设置搜索: 「歌词显示」页默认分段 = 枚举第一个 case")

    // 有页内分段的面板一共五处。再加一处时这条会红 —— 提醒除了往目录里登记,还要接上设置窗的
    // 前进 / 后退(SettingsView 的 `section(of:)` / `applySection`),漏了不报错、只表现成后退键
    // 把那几步整个跳过。
    let catalogSectionKeys = Set(entries.compactMap(\.sectionKey))
    expectEqual(catalogSectionKeys, [SettingsSearchCatalog.lyricsSectionKey,
                                     LyricsSurface.appearanceSectionStorageKey,
                                     SettingsSearchCatalog.lastfmSectionKey,
                                     SettingsSearchCatalog.discordSectionKey,
                                     SettingsSearchCatalog.playerSectionKey],
                "设置搜索: 页内分段只有这五处(新加一处要一并接上前进/后退)")
    let sectionKeyTokens = [
        LyricsSurface.appearanceSectionStorageKey: "LyricsSurface.appearanceSectionStorageKey",
        SettingsSearchCatalog.lyricsSectionKey: "SettingsSearchCatalog.lyricsSectionKey",
        SettingsSearchCatalog.lastfmSectionKey: "SettingsSearchCatalog.lastfmSectionKey",
        SettingsSearchCatalog.discordSectionKey: "SettingsSearchCatalog.discordSectionKey",
        SettingsSearchCatalog.playerSectionKey: "SettingsSearchCatalog.playerSectionKey",
    ]
    for key in catalogSectionKeys {
        let token = sectionKeyTokens[key] ?? key
        expectEqual(settingsView.contains("@AppStorage(\(token))"), true,
                    "设置搜索: 前进/后退读得到分段键 \(key)")
    }

    var badDestinations: [String] = []
    var badSections: [String] = []
    var badDrawers: [String] = []
    for entry in entries {
        switch entry.destination {
        case .tab(let raw): if !tabCases.contains(raw) { badDestinations.append("\(entry.titleKey)→tab:\(raw)") }
        case .account(let name): if !accountCases.contains(name) { badDestinations.append("\(entry.titleKey)→account:\(name)") }
        case .softwareUpdate: break   // 单页,没有枚举值要对
        }
        switch (entry.sectionKey, entry.sectionValue) {
        case (nil, nil): break
        case (SettingsSearchCatalog.lyricsSectionKey?, let value?):
            if !lyricsSectionCases.contains(value) { badSections.append("\(entry.titleKey)→\(value)") }
        case (LyricsSurface.appearanceSectionStorageKey?, let value?):
            // 核源码里那个枚举而不是 LyricsSurface:「歌词窗口」段不属于任何形态。
            if !appearanceSectionCases.contains(value) { badSections.append("\(entry.titleKey)→\(value)") }
        case (SettingsSearchCatalog.lastfmSectionKey?, let value?):
            if !lastfmSectionCases.contains(value) { badSections.append("\(entry.titleKey)→\(value)") }
        case (SettingsSearchCatalog.discordSectionKey?, let value?):
            if !discordSectionCases.contains(value) { badSections.append("\(entry.titleKey)→\(value)") }
        case (SettingsSearchCatalog.playerSectionKey?, let value?):
            if !playerSectionCases.contains(value) { badSections.append("\(entry.titleKey)→\(value)") }
        default:
            badSections.append("\(entry.titleKey)→\(entry.sectionKey ?? "nil")/\(entry.sectionValue ?? "nil")")
        }
        if let drawer = entry.drawer {
            // 抽屉只存在于「歌词显示」页,且必须跟条目自己所在的分段是同一个形态。
            if entry.destination != .tab("appearance") || entry.sectionValue != drawer.appearanceSectionRawValue {
                badDrawers.append(entry.titleKey)
            }
        }
    }
    expectEqual(badDestinations, [], "设置搜索: 目的地都对得上源码枚举")
    expectEqual(badSections, [], "设置搜索: 分段键 / 取值都对得上源码枚举")
    expectEqual(badDrawers, [], "设置搜索: 抽屉归属与分段一致")

    // ---- 2. 本地化键都在 catalog 里 ----
    var catalogKeys: Set<String> = []
    if let data = FileManager.default.contents(atPath: catalogPath),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let strings = obj["strings"] as? [String: Any] {
        catalogKeys = Set(strings.keys)
    }
    expectEqual(catalogKeys.isEmpty, false, "设置搜索: 读到了 Localizable.xcstrings")
    let missingKeys = entries.flatMap(\.localizedKeys)
        .filter { !SettingsSearchCatalog.brandPathComponents.contains($0) && !catalogKeys.contains($0) }
    expectEqual(Array(Set(missingKeys)).sorted(), [], "设置搜索: 目录里的每个键都在 catalog 里(缺的补进 Localizable.xcstrings)")

    // ---- 3. 覆盖:源码调用点 ⊆ 目录 ∪ 白名单 ----
    let indexedTitles = Set(entries.map(\.titleKey) + entries.flatMap(\.alternateTitleKeys))
    /// 刻意不登记的标题:纯分组标题(其下每一行都登记了)与只读状态行。
    let intentionallyUnindexed: Set<String> = [
        // 「背景」不在这儿:歌词窗口那一段有一行真的叫这个名字、已登记在目录里,而这张白名单
        // 跟目录必须不相交(下面那条断言)。悬浮歌词抽屉里同名的那个组标题因此顺带被目录覆盖 ——
        // 搜「背景」会落到歌词窗口那一行,不再是查无此项。
        "主题", "字形", "颜色", "内容", "排版", "行为",              // 悬浮歌词抽屉的组标题(「内容」也是歌词窗口抽屉的卡头)
        "文字",                                                   // 歌词窗口抽屉的卡头
        // 「封面」同「背景」:迷你「顶部信息」里有一行真的叫这个名字、已登记在目录里,
        // 所以完整尺寸那张同名卡头顺带被目录覆盖,不能再留在白名单里(两者必须不相交)。
        "顶部信息", "布局",                                       // 歌词显示 › 歌词窗口 的卡头
        "断句",                                                   // 歌词 › 调整 的卡头(同段的「文字」卡头见上一行)
        "批量匹配",                                         // 歌词 › 管理 的卡头
        "权限与服务",                                       // 播放器 › 权限与服务 的卡头(跟分段同名,分段本身已可搜到这一页)
        "歌词行", "展开态",                                 // 歌词显示 › 灵动岛「全部设置」抽屉的卡头(跟工具栏入口同名)
        "配色",                                             // 歌词显示 › 菜单栏「全部设置」抽屉的卡头(跟工具栏入口同名)
        "显示在",                                           // 灵动岛「屏幕」那一行的行名,目录里按「屏幕」登记
        "菜单栏与 Dock", "外观与语言", "启动与通知", "网络", "备份与迁移", // 通用页卡头
        "更新与帮助", "诊断与数据",                                   // 关于页卡头
        "更新设置",                                                   // 软件更新页的卡头
        "已改用自定义位置",                                           // 歌词文件夹的状态子行
        "此 Mac 未配备触控栏",                                         // 歌词显示 › 触控栏:没有触控栏时的说明卡
        // 全量扫库那条"下次启动接着跑"的状态子行。它是 subtitle 不是 title —— 上面那条
        // 正则里 `title:` 会顺带匹配到 `subtitle:` 的尾巴,所以状态子行一律走白名单
        // (同「已改用自定义位置」)。
        "上一轮扫描尚未完成，稍后将自动继续",
        "网络不可用，已暂停，稍后将自动继续",
        "需要 Discord 桌面版", "请打开 Discord", "Discord 尚未就绪",   // Discord 页的引导行(没装 / 没开 / 连不上时才有)
    ]
    let scannedFiles = [
        "SettingsView.swift", "AccountLinkingTab.swift",
        "UI/OverlayEditorStage.swift", "UI/NotchEditorStage.swift", "UI/MenuBarEditorStage.swift",
        "UI/OverlayStyleSettingsRows.swift", "UI/OverlayBehaviorSettingsRows.swift", "UI/AutoHideSettingsRows.swift",
        "UI/OverlayAllSettingsDrawer.swift", "UI/TouchBarSettingsRows.swift",
        "Settings/LanguagePackRow.swift", "Settings/PlayerLinkageRow.swift", "Settings/LyricsLibraryStats.swift",
        "Settings/SoftwareUpdatePage.swift",
    ]
    let titlePattern = #/title:\s*L10n\.t\("((?:[^"\\]|\\.)*)"\)/#
    var scannedTitles: [String: [String]] = [:]   // 标题 → 出现的文件
    for relative in scannedFiles {
        let text = source(relative)
        // `SettingsGroupCard(` 是「全部设置」抽屉里各组卡的卡头,跟 SettingsCardHeader 同一回事。
        for marker in ["SettingsRow(", "SettingsSubRow(", "SettingsCardHeader(", "PlayerBundleChipsRow(", "SettingsGroupCard("] {
            var searchStart = text.startIndex
            while let found = text.range(of: marker, range: searchStart..<text.endIndex) {
                // 取到配对右括号或第一个 `{`(尾随闭包)为止的参数段。
                var depth = 1
                var index = found.upperBound
                while index < text.endIndex, depth > 0 {
                    let ch = text[index]
                    if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 } else if ch == "{", depth == 1 { break }
                    index = text.index(after: index)
                }
                let segment = text[found.upperBound..<index]
                if let match = segment.firstMatch(of: titlePattern) {
                    scannedTitles[String(match.1), default: []].append(relative)
                }
                searchStart = found.upperBound
            }
        }
    }
    // 标题住在枚举里的三族行:标题块(`var title: String {`,按形态分文案的是 `func title(for:)`)里的 return L10n.t("…")。
    let enumTitleBlocks: [(file: String, marker: String, header: String)] = [
        ("UI/OverlayBehaviorSettingsRows.swift", "enum OverlayBehaviorItem", "var title: String {"),
        ("UI/AutoHideSettingsRows.swift", "enum AutoHideItem", "func title(for surface: AutoHideSurface) -> String {"),
        ("SettingsView.swift", "enum NotchBehaviorItem", "var title: String {"),
    ]
    let returnPattern = #/return L10n\.t\("((?:[^"\\]|\\.)*)"\)/#
    for block in enumTitleBlocks {
        let text = source(block.file)
        guard let enumRange = text.range(of: block.marker),
              let titleRange = text.range(of: block.header, range: enumRange.upperBound..<text.endIndex) else {
            expectEqual(false, true, "设置搜索: 找到了 \(block.marker) 的 title 块")
            continue
        }
        // 块到下一个同缩进的 `    }` 结束。
        let rest = text[titleRange.upperBound...]
        let blockEnd = rest.range(of: "\n    }")?.lowerBound ?? rest.endIndex
        var count = 0
        for match in rest[..<blockEnd].matches(of: returnPattern) {
            scannedTitles[String(match.1), default: []].append(block.file + "#" + block.marker)
            count += 1
        }
        expectEqual(count >= 2, true, "设置搜索: \(block.marker) 的标题块扫到了 \(count) 个字面量")
    }
    expectEqual(scannedTitles.count >= 100, true, "设置搜索: 源码里扫到了 \(scannedTitles.count) 个不同的字面量标题")
    let unindexed = scannedTitles.keys.filter { !indexedTitles.contains($0) && !intentionallyUnindexed.contains($0) }.sorted()
    expectEqual(unindexed.map { "\($0) @ \(scannedTitles[$0]!.joined(separator: ","))" }, [],
                "设置搜索: 源码里每个设置行标题都在目录里(新加了行就到 Core SettingsSearchCatalog 登记,或写进白名单)")
    let staleAllowlist = intentionallyUnindexed.filter { scannedTitles[$0] == nil }.sorted()
    expectEqual(staleAllowlist, [], "设置搜索: 白名单里的每一项都还真的存在于源码里")
    // 两处「内容」浮层不放标读音的语言:那是所有展示面共用的设置,只在「歌词 › 调整 › 标注读音的语言」设(04 章决策 47)。
    func memberBody(_ text: String, after marker: String) -> String {
        sourceBody(marker, in: text)
    }
    let contentRows = [
        memberBody(source("UI/OverlayStyleSettingsRows.swift"), after: "struct OverlayContentSettingsRows: View {"),
        memberBody(source("SettingsView.swift"), after: "private var lyricsWindowContentRows: some View {"),
    ]
    expectEqual(contentRows.map { $0.contains("L10n.t(\"读音\")") && !$0.localizedCaseInsensitiveContains("romanizationScripts") && !$0.contains("标注") },
                [true, true], "设置搜索: 两处「内容」浮层不放「标注读音的语言」")
    // 「内容」组按段各登记一遍:上面那条覆盖检查按标题判,两段都有「读音」「译文」,漏登记一段它看不出来。
    func contentGroupTitles(_ section: String) -> Set<String> {
        Set(entries.filter { $0.sectionValue == section && $0.pathKeys.last == "内容" }.map(\.titleKey))
    }
    expectEqual(contentGroupTitles(LyricsSurface.overlay.appearanceSectionRawValue), ["读音", "译文", "下一句"],
                "设置搜索: 悬浮歌词「内容」三行都登记在悬浮歌词那一段")
    expectEqual(contentGroupTitles(SettingsSearchCatalog.lyricsWindowSectionValue), ["读音", "进度条", "译文"],
                "设置搜索: 歌词窗口「内容」三行都登记在歌词窗口那一段(进度条只在迷你)")
    let allowlistedButIndexed = intentionallyUnindexed.filter { indexedTitles.contains($0) }.sorted()
    expectEqual(allowlistedButIndexed, [], "设置搜索: 白名单与目录不重叠")

    // ---- 导出给功能清单 ----
    // `scripts/gen-feature-list.py` 读 `shared/settings-catalog.json` 生成功能清单的「全部设置」,这份文件必须跟目录逐字节一致。
    // 设 LYRIMUSE_WRITE_SETTINGS_CATALOG=1 时改为重写它。
    let exportURL = sourcesDir.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shared/settings-catalog.json")
    let exportedRows: [[String: Any]] = entries.map { entry in
        let dest: String
        switch entry.destination {
        case .tab(let raw): dest = "tab:\(raw)"
        case .account(let name): dest = "account:\(name)"
        case .softwareUpdate: dest = "softwareUpdate"
        }
        var row: [String: Any] = ["dest": dest, "path": entry.pathKeys, "title": entry.titleKey]
        if let subtitle = entry.subtitleKey { row["subtitle"] = subtitle }
        if let mini = entry.lyricsWindowMini { row["lyricsWindowMini"] = mini }
        return row
    }
    var exported = (try? JSONSerialization.data(withJSONObject: ["entries": exportedRows],
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    exported.append(0x0A)
    if ProcessInfo.processInfo.environment["LYRIMUSE_WRITE_SETTINGS_CATALOG"] == "1" {
        try? exported.write(to: exportURL, options: .atomic)
    }
    expectEqual(FileManager.default.contents(atPath: exportURL.path) == exported, true,
                "设置搜索: shared/settings-catalog.json 跟目录一致(不一致就跑 LYRIMUSE_WRITE_SETTINGS_CATALOG=1 swift run lyrimuse-selftest -f settings-search,再跑 python3 scripts/gen-feature-list.py)")

    // ---- 4. 匹配器 ----
    expectEqual(SettingsSearchMatcher.rank(query: "字号", title: "字号", secondary: []), 0, "匹配: 标题整体命中 = 0")
    expectEqual(SettingsSearchMatcher.rank(query: "字", title: "字号", secondary: []), 0, "匹配: 标题前缀 = 0")
    expectEqual(SettingsSearchMatcher.rank(query: "号", title: "字号", secondary: []), 1, "匹配: 标题包含 = 1")
    expectEqual(SettingsSearchMatcher.rank(query: "font", title: "字号", secondary: ["font size"]), 2, "匹配: 只在次要字段 = 2")
    expectEqual(SettingsSearchMatcher.rank(query: "SPOTIFY", title: "播放器", secondary: ["Spotify"]), 2, "匹配: 不区分大小写")
    expectEqual(SettingsSearchMatcher.rank(query: "xyz", title: "字号", secondary: ["font size"]), nil, "匹配: 不命中 = nil")
    expectEqual(SettingsSearchMatcher.rank(query: "   ", title: "字号", secondary: []), nil, "匹配: 空查询不命中")
    expectEqual(SettingsSearchMatcher.rank(query: "菜单栏 字号", title: "字号", secondary: ["歌词显示 › 菜单栏"]), 0,
                "匹配: 多词——每个词都得命中,等级看标题")
    expectEqual(SettingsSearchMatcher.rank(query: "菜单栏 abc", title: "字号", secondary: ["歌词显示 › 菜单栏"]), nil,
                "匹配: 多词——有一个词落空就不命中")
    expectEqual(SettingsSearchMatcher.normalize("  Font   Size \n"), "font size", "匹配: 归一化去首尾空白、折叠空白、小写")
    let ranked = SettingsSearchMatcher.ranked(
        [("字体", ["背景"]), ("毛玻璃背景", [String]()), ("背景颜色", [String]())],
        query: "背景", title: { $0.0 }, secondary: { $0.1 })
    expectEqual(ranked.map(\.0), ["背景颜色", "毛玻璃背景", "字体"], "匹配: 排序按等级,同级保持原顺序")
    expectEqual(SettingsSearchMatcher.ranked([("a", [String]())], query: "", title: { $0.0 }, secondary: { $0.1 }).count, 0,
                "匹配: 空查询零结果")

    // 目录层面的抽查:五个面的「字号」都能被同一个词搜到,且顺序跟目录一致;快捷键页那两格也搜得到。
    let fontSizeHits = SettingsSearchMatcher.ranked(entries, query: "字号", title: { $0.titleKey }, secondary: { $0.keywords + $0.pathKeys })
    expectEqual(fontSizeHits.filter { $0.pathKeys != ["快捷键"] }.map(\.sectionValue), ["overlay", "notch", "menuBar", "touchBar", "lyricsWindow"],
                "目录: 「字号」命中悬浮歌词、灵动岛、菜单栏、触控栏、歌词窗口迷你尺寸五条,按目录顺序")
    expectEqual(fontSizeHits.filter { $0.pathKeys == ["快捷键"] }.map(\.titleKey), ["放大悬浮歌词字号", "缩小悬浮歌词字号"],
                "目录: 「字号」也命中快捷键页的放大 / 缩小悬浮歌词字号")
    let qqHits = SettingsSearchMatcher.ranked(entries, query: "QQ", title: { $0.titleKey }, secondary: { $0.keywords + $0.pathKeys })
    expectEqual(qqHits.map(\.titleKey).contains("歌词来源"), true, "目录: 搜「QQ」能落到「歌词来源」卡")
    expectEqual(qqHits.map(\.titleKey).contains("音乐 App"), true, "目录: 搜「QQ」也能落到「音乐 App」卡")
    let progressEntry = entries.first { $0.titleKey == "进度条" && $0.sectionValue == SettingsSearchCatalog.lyricsWindowSectionValue }
    expectEqual(progressEntry != nil && SettingsSearchCatalog.lyricsWindowMiniOnlyTitles.contains("进度条"), true,
                "目录: 迷你「进度条」登记在歌词窗口那一段,命中时预览切到迷你")
    // 用户嫌歌词不准时多半照抱怨的原话搜,不会搜「时间轴偏移」。
    for query in ["歌词太快", "太慢", "不同步", "out of sync"] {
        let hits = SettingsSearchMatcher.ranked(entries, query: query, title: { $0.titleKey }, secondary: { $0.keywords + $0.pathKeys })
        expectEqual(hits.first?.titleKey, "时间轴偏移", "目录: 搜「\(query)」第一条是时间轴偏移")
    }

    // 「歌词窗口」那一段只在一种尺寸的预览下才有的行(14 章决策 56):命中时预览先切过去。
    let lyricsWindowEntries = entries.filter { $0.sectionValue == SettingsSearchCatalog.lyricsWindowSectionValue }
    let miniOnly = SettingsSearchCatalog.lyricsWindowMiniOnlyTitles
    let fullOnly = SettingsSearchCatalog.lyricsWindowFullOnlyTitles
    expectEqual(Set(lyricsWindowEntries.filter { $0.lyricsWindowMini == true }.map(\.titleKey)), miniOnly,
                "歌词窗口尺寸: 只有迷你的那几行在目录里标了迷你")
    expectEqual(Set(lyricsWindowEntries.filter { $0.lyricsWindowMini == false }.map(\.titleKey)), fullOnly,
                "歌词窗口尺寸: 只有完整的那几行在目录里标了完整")
    expectEqual(entries.filter { $0.sectionValue != SettingsSearchCatalog.lyricsWindowSectionValue && $0.lyricsWindowMini != nil }.count,
                0, "歌词窗口尺寸: 别的段不带这个标记")
    let lyricsWindowTitles = Set(lyricsWindowEntries.map(\.titleKey))
    expectEqual(miniOnly.union(fullOnly).subtracting(lyricsWindowTitles).sorted(), [],
                "歌词窗口尺寸: 两份名单里的标题都在目录的歌词窗口那一段(改了名名单会落空)")
    expectEqual(miniOnly.intersection(fullOnly).sorted(), [], "歌词窗口尺寸: 两份名单不重叠")
    // 设置页里只在一种尺寸下才画的几组,行标题都得在对应名单里:新加一行忘了登记会红。
    let settingsSource = source("SettingsView.swift")
    func block(from start: String, to end: String) -> String {
        guard let s = settingsSource.range(of: start),
              let e = settingsSource.range(of: end, range: s.upperBound..<settingsSource.endIndex) else { return "" }
        return String(settingsSource[s.upperBound..<e.lowerBound])
    }
    func rowTitles(_ text: String) -> Set<String> { Set(text.matches(of: titlePattern).map { String($0.1) }) }
    let miniBlocks = [
        block(from: "    private var lyricsWindowMiniHeaderRows: some View {", to: "\n    }\n"),
        block(from: "    private var lyricsWindowMiniHeaderSizeRows: some View {", to: "\n    }\n"),
        block(from: "        case .layout:\n            if let miniLyricsLayout {", to: "            if let alignment {"),
        block(from: "    private var lyricsWindowBehaviorRows: some View {", to: "\n    }\n"),
    ]
    let fullBlocks = [
        block(from: "    private var lyricsWindowCoverRows: some View {", to: "\n    }\n"),
        block(from: "private struct MotionCoverCacheRow: View {", to: "\n}\n"),
        block(from: "    private func lyricsWindowAlignmentRows(", to: "\n    }\n"),
    ]
    expectEqual(miniBlocks.allSatisfy { !$0.isEmpty } && fullBlocks.allSatisfy { !$0.isEmpty }, true,
                "歌词窗口尺寸(契约): 认得出设置页里只在一种尺寸下才画的几组(认不出 = 改名了,先改这里)")
    let miniBlockTitles = miniBlocks.reduce(into: Set<String>()) { $0.formUnion(rowTitles($1)) }
    let fullBlockTitles = fullBlocks.reduce(into: Set<String>()) { $0.formUnion(rowTitles($1)) }
    expectEqual(miniBlockTitles.isEmpty || fullBlockTitles.isEmpty, false, "歌词窗口尺寸(契约): 那几组里扫得到行标题")
    expectEqual(miniBlockTitles.subtracting(miniOnly).sorted(), [], "歌词窗口尺寸: 顶部信息、迷你布局、行为三组的行都登记为只有迷你")
    expectEqual(fullBlockTitles.subtracting(fullOnly).sorted(), [], "歌词窗口尺寸: 封面那一组和对齐方式都登记为只有完整")
    // 迷你独有的字号、长句处理、歌词布局,靠完整尺寸那一支不传它们的绑定:真要让完整尺寸也有,名单得跟着改。
    let fullBranch = block(from: "        } else {\n            lyricsWindowAppearanceRowsImpl(", to: "\n        }\n")
    expectEqual(!fullBranch.isEmpty && ["fontSize:", "lineOverflow:", "miniLyricsLayout:"]
                    .allSatisfy { !fullBranch.contains($0) }, true,
                "歌词窗口尺寸: 完整尺寸那一支外观行不传迷你独有的那几样绑定")
    // 跳转那一段:写完分段键、翻面板之前,把预览切到这一行所在的尺寸。
    let jump = block(from: "    private func openSettingsSearchHit(_ hit: SettingsSearchHit) {", to: "        searchRouter.reveal(hit)")
    expectEqual(sourceHas(jump, "if let mini = entry.lyricsWindowMini {\n            UserDefaults.standard.set(mini, forKey: LyricsWindowPreviewStage.showsMiniStorageKey)\n        }\n        switch entry.destination {"),
                true, "歌词窗口尺寸: 命中时先切预览尺寸,再翻面板")

    // 随设置显隐的行:搜到时它不在页面上,一起点亮决定它出不出现的那一行(不替用户改设置,14 章决策 133)。
    do {
        let menuBar = ["歌词显示", "菜单栏", "布局"]
        let notch = ["歌词显示", "灵动岛", "歌词行"]
        let lastfm = ["Last.fm", "设置"]
        func gate(_ path: [String], _ title: String, false falseConditions: Set<String>) -> String? {
            SettingsSearchCatalog.gateTitle(path: path, title: title) { !falseConditions.contains($0) }
        }
        expectEqual(gate(menuBar, "屏幕", false: ["menuBar.centerSelected"]), "歌词位置", "搜索门: 没选菜单栏正中时「显示在」落到「歌词位置」")
        expectEqual(gate(menuBar, "屏幕", false: []), nil, "搜索门: 行在页面上不加门")
        expectEqual(gate(menuBar, "对齐方式", false: ["menuBar.centerIdle", "menuBar.widthFixed"]), "歌词位置",
                    "搜索门: 两条都不满足时按登记顺序取第一条")
        expectEqual(gate(menuBar, "对齐方式", false: ["menuBar.widthFixed"]), "宽度模式", "搜索门: 自适应时对齐方式落到「宽度模式」")
        expectEqual(gate(notch, "对齐方式", false: ["menuBar.widthFixed"]), nil, "搜索门: 按段区分,菜单栏的条件管不到灵动岛同名行")
        expectEqual(gate(notch, "封面位置", false: ["notch.lyricRowArtwork"]), "显示封面", "搜索门: 灵动岛封面位置落到「显示封面」")
        expectEqual(gate(notch, "封面位置", false: ["notch.showLyrics", "notch.lyricRowArtwork"]), "收起时显示歌词",
                    "搜索门: 歌词行整组藏着时落到「收起时显示歌词」")
        expectEqual(gate(notch, "展开时预览下一句", false: ["notch.expandedNextLine", "notch.showLyrics"]), "收起时显示歌词",
                    "搜索门: 落点自己也藏着时接着往上找")
        expectEqual(gate(notch, "展开时预览下一句", false: ["notch.expandedNextLine"]), "副行", "搜索门: 只隔一层时停在「副行」")
        expectEqual(gate(lastfm, "歌名", false: ["lastfm.matchCustom"]), "匹配模式", "搜索门: Last.fm 歌名落到「匹配模式」")
        expectEqual(gate(lastfm, "歌名", false: ["lastfm.mirror", "lastfm.matchCustom"]), "Scrobble 规则",
                    "搜索门: Scrobble 关着时落到「Scrobble 规则」")
        let window = ["歌词显示", "歌词窗口"]
        let overlay = ["歌词显示", "悬浮歌词"]
        for title in ["访问链接", "备用链接（IP 地址）", "重置访问密钥"] {
            expectEqual(gate(window, title, false: ["web.lan"]), "允许局域网访问", "搜索门: 网页歌词「\(title)」落到「允许局域网访问」")
            expectEqual(gate(overlay, title, false: ["obs.lan"]), "允许局域网访问", "搜索门: OBS「\(title)」落到「允许局域网访问」")
        }
        expectEqual(gate(["歌词", "译文"], "翻译语言包", false: ["translation.machine"]), "无译文时自动翻译",
                    "搜索门: 语言包落到「无译文时自动翻译」")
        // 表里每一条:那一行和落点在目录里同一段都有登记(点亮得到),条件在 App 侧有对应分支(认不出的名字会被当真、门失效)。
        let search = source("Settings/SettingsSearch.swift")
        for rule in SettingsSearchCatalog.rowGates {
            let inSection = entries.filter { $0.pathKeys.starts(with: rule.path) }.map(\.titleKey)
            expectEqual(inSection.contains(rule.title) && inSection.contains(rule.gate), true,
                        "搜索门: \(rule.path.joined(separator: " › ")) 「\(rule.title)」→「\(rule.gate)」都在目录里")
            expectEqual(search.contains("case \"\(rule.condition)\":"), true, "搜索门: 条件 \(rule.condition) 在 App 侧有分支")
        }
        // 菜单栏几行的显隐写法跟条件同步(别的段各行的写法见 rowCondition 头注)。
        let stage = source("UI/MenuBarEditorStage.swift")
        expectEqual(sourceHas(stage, "if settings.menuBarLyricsPlacement == .screenCenter {\nMenuBarCenterScreenRow()")
                    && sourceHas(stage, "if !MenuBarPlacementRow.centerInUse(settings) {\nMenuBarWidthModeRow()")
                    && sourceHas(stage, "if settings.menuBarLyricsWidthMode == .fixed {\nCardDivider()\nMenuBarAlignmentRow()")
                    && sourceHas(stage, "if settings.menuBarLyricsKaraoke || settings.menuBarLyricsIconPosition != .off {")
                    && sourceHas(search, "case \"menuBar.centerSelected\": return s.menuBarLyricsPlacement == .screenCenter")
                    && sourceHas(search, "case \"menuBar.centerIdle\": return !MenuBarPlacementRow.centerInUse(s)")
                    && sourceHas(search, "case \"menuBar.widthFixed\": return s.menuBarLyricsWidthMode == .fixed")
                    && sourceHas(search, "case \"menuBar.fillColorShown\": return s.menuBarLyricsKaraoke || s.menuBarLyricsIconPosition != .off")
                    && sourceHas(search, "highlightedTitles = hit.highlightTitles.union(Self.gateTitles(for: hit.entry))"),
                    true, "搜索门: 菜单栏各行显隐条件与搜索喂的条件同步")
    }
}
