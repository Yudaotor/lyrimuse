import LyrimuseCore
import Foundation

// 设置搜索(2026-09-09,借鉴清单 S8):Core 目录 ↔ 源码调用点 ↔ 本地化 catalog 三方对账,加匹配器纯函数。
//
// 目录是静态表,会漂;这一组守的就是"漂了要红":
//   1. 目录自身:id 不重复、面包屑非空、目的地 / 分段取值跟 SettingsView / AccountLinkingTab 里的枚举
//      对得上(那些枚举没有 rawValue 契约,只能扫源码文本);
//   2. 目录里每个 L10n 键都在 Localizable.xcstrings 里(表里的键是裸字符串,contracts 组那条
//      「源码里的 L10n.t 字面量都在 catalog 里」扫不到它们);
//   3. 覆盖:源码里每一处 `SettingsRow(` / `SettingsSubRow(` / `SettingsCardHeader(` 的字面量标题、
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
    expectEqual(accountCases, ["listenBrainz", "lastfm", "stateRelay", "bark"], "设置搜索: 扫到了 AccountDestination 的四个 case")
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

    var badDestinations: [String] = []
    var badSections: [String] = []
    var badDrawers: [String] = []
    for entry in entries {
        switch entry.destination {
        case .tab(let raw): if !tabCases.contains(raw) { badDestinations.append("\(entry.titleKey)→tab:\(raw)") }
        case .account(let name): if !accountCases.contains(name) { badDestinations.append("\(entry.titleKey)→account:\(name)") }
        }
        switch (entry.sectionKey, entry.sectionValue) {
        case (nil, nil): break
        case (SettingsSearchCatalog.lyricsSectionKey?, let value?):
            if !lyricsSectionCases.contains(value) { badSections.append("\(entry.titleKey)→\(value)") }
        case (LyricsSurface.appearanceSectionStorageKey?, let value?):
            if LyricsSurface(rawValue: value) == nil { badSections.append("\(entry.titleKey)→\(value)") }
        case (SettingsSearchCatalog.lastfmSectionKey?, let value?):
            if !lastfmSectionCases.contains(value) { badSections.append("\(entry.titleKey)→\(value)") }
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
        "主题", "文字", "背景", "排版", "行为",                       // 悬浮歌词抽屉的组标题
        "菜单栏与 Dock", "语言与启动", "备份与迁移",                     // 通用页卡头
        "更新", "反馈与社区", "许可与版权", "诊断与数据",                 // 关于页卡头
        "已改用自定义位置",                                           // 歌词文件夹的状态子行
        "译文", "已缓存罗马音",                                       // 歌词库统计的只读行
    ]
    let scannedFiles = [
        "SettingsView.swift", "AccountLinkingTab.swift",
        "UI/OverlayEditorStage.swift", "UI/NotchEditorStage.swift", "UI/MenuBarEditorStage.swift",
        "UI/OverlayStyleSettingsRows.swift", "UI/OverlayBehaviorSettingsRows.swift", "UI/AutoHideSettingsRows.swift",
        "UI/OverlayAllSettingsDrawer.swift",
        "Settings/LanguagePackRow.swift", "Settings/PlayerLinkageRow.swift", "Settings/LyricsLibraryStats.swift",
    ]
    let titlePattern = #/title:\s*L10n\.t\("((?:[^"\\]|\\.)*)"\)/#
    var scannedTitles: [String: [String]] = [:]   // 标题 → 出现的文件
    for relative in scannedFiles {
        let text = source(relative)
        for marker in ["SettingsRow(", "SettingsSubRow(", "SettingsCardHeader("] {
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
    // 标题住在枚举里的三族行:`var title: String {` 块里的 return L10n.t("…")。
    let enumTitleBlocks: [(file: String, marker: String)] = [
        ("UI/OverlayBehaviorSettingsRows.swift", "enum OverlayBehaviorItem"),
        ("UI/AutoHideSettingsRows.swift", "enum AutoHideItem"),
        ("SettingsView.swift", "enum NotchBehaviorItem"),
    ]
    let returnPattern = #/return L10n\.t\("((?:[^"\\]|\\.)*)"\)/#
    for block in enumTitleBlocks {
        let text = source(block.file)
        guard let enumRange = text.range(of: block.marker),
              let titleRange = text.range(of: "var title: String {", range: enumRange.upperBound..<text.endIndex) else {
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
    let allowlistedButIndexed = intentionallyUnindexed.filter { indexedTitles.contains($0) }.sorted()
    expectEqual(allowlistedButIndexed, [], "设置搜索: 白名单与目录不重叠")

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

    // 目录层面的抽查:三个面的「字号」都能被同一个词搜到,且悬浮歌词那条排在菜单栏那条前面(目录顺序)。
    let fontSizeHits = SettingsSearchMatcher.ranked(entries, query: "字号", title: { $0.titleKey }, secondary: { $0.keywords + $0.pathKeys })
    expectEqual(fontSizeHits.map(\.sectionValue), ["overlay", "menuBar"], "目录: 「字号」命中悬浮歌词与菜单栏两条")
    let qqHits = SettingsSearchMatcher.ranked(entries, query: "QQ", title: { $0.titleKey }, secondary: { $0.keywords + $0.pathKeys })
    expectEqual(qqHits.map(\.titleKey).contains("歌词来源"), true, "目录: 搜「QQ」能落到「歌词来源」卡")
    expectEqual(qqHits.map(\.titleKey).contains("播放器"), true, "目录: 搜「QQ」也能落到「播放器」卡")
}
