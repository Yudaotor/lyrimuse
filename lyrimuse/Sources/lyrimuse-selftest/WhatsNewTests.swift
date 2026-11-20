import Foundation
import LyrimuseCore

func runWhatsNewTests() {
    do {
        print("\n== 本次更新:基准版本 ==")
        typealias W = WhatsNew
        expectEqual(W.baseline(current: "1.12.0", lastLaunched: nil, stored: nil, shownVersion: nil, hasCompletedOnboarding: true),
                    W.legacyBaseline, "基准: 老用户第一次跑到这套代码,按从上一个版本升上来算")
        expectEqual(W.baseline(current: "1.12.0", lastLaunched: nil, stored: nil, shownVersion: nil, hasCompletedOnboarding: false),
                    "1.12.0", "基准: 新装的用户就是当前版本")
        expectEqual(W.baseline(current: "1.13.0", lastLaunched: "1.12.0", stored: "1.11.0", shownVersion: "1.12.0", hasCompletedOnboarding: true),
                    "1.12.0", "基准: 刚升级,换成升级前那一版")
        expectEqual(W.baseline(current: "1.12.0", lastLaunched: "1.12.0", stored: "1.11.0", shownVersion: nil, hasCompletedOnboarding: true),
                    "1.11.0", "基准: 没升级,沿用存着的")
        expectEqual(W.baseline(current: "1.12.1", lastLaunched: "1.12.0", stored: "1.11.0", shownVersion: nil,
                               hasCompletedOnboarding: true),
                    "1.11.0", "基准: 上一版的横条没出过就又升了,沿用旧基准,大版本的提示照出")
        expectEqual(W.baseline(current: "1.12.1", lastLaunched: "1.12.0", stored: "1.11.0", shownVersion: "1.12.0",
                               hasCompletedOnboarding: true),
                    "1.12.0", "基准: 上一版的横条出过了,换成上一版")
        expectEqual(W.baseline(current: "1.13.0", lastLaunched: "1.13.0-beta.2", stored: "1.12.0", shownVersion: nil,
                               hasCompletedOnboarding: true),
                    "1.12.0", "基准: 从测试版升到正式版是升级,测试版没出过横条,沿用旧基准")
        expectEqual(W.compare("1.13.0", "1.13.0-beta.2"), .orderedDescending, "版本: 正式版比它的测试版新")
        expectEqual(W.compare("1.13.0-beta.2", "1.13.0-beta.10"), .orderedAscending, "版本: 测试版按后缀数字比")
        expectEqual(W.compare("1.13.0-beta.1", "1.12.5"), .orderedDescending, "版本: 先比 X.Y.Z")
        expectEqual(W.featureVersion("1.13.0-beta.1"), "1.13", "版本: 主次版本不带预发布后缀")
        expectEqual(W.compare("1.12.0", "1.9.0"), .orderedDescending, "版本: 按数字比,1.12 > 1.9")
        expectEqual(W.compare("1.12", "1.12.0"), .orderedSame, "版本: 缺的段当 0")
        expectEqual(W.featureVersion("1.12.3"), "1.12", "版本: 主次版本")
    }

    do {
        print("\n== 本次更新:面板顶部出不出 ==")
        typealias W = WhatsNew
        expectEqual(W.bannerPending(current: "1.12.0", baseline: "1.11.0", shownVersion: nil), true, "横条: 次版本升级出")
        expectEqual(W.bannerPending(current: "2.0.0", baseline: "1.12.3", shownVersion: nil), true, "横条: 主版本升级出")
        expectEqual(W.bannerPending(current: "1.12.1", baseline: "1.12.0", shownVersion: nil), false, "横条: 补丁版不出")
        expectEqual(W.bannerPending(current: "1.12.0", baseline: "1.11.0", shownVersion: "1.12.0"), false, "横条: 这一版出过不再出")
        expectEqual(W.bannerPending(current: "1.13.0", baseline: "1.12.0", shownVersion: "1.12.0"), true, "横条: 出过的是旧版,新版照出")
        expectEqual(W.bannerPending(current: "1.12.0", baseline: "1.12.0", shownVersion: nil), false, "横条: 新装的不出")
        expectEqual(W.bannerPending(current: "1.13.0-beta.1", baseline: "1.12.0", shownVersion: nil), false,
                    "横条: 测试版不出(CHANGELOG 里没有它的节)")
        expectEqual(W.bannerPending(current: "1.12.1", baseline: "1.11.0", shownVersion: "1.12.0"), false,
                    "横条: 同一个大版本出过就不再出")
    }

    do {
        print("\n== 本次更新:CHANGELOG 拆成单一语言 ==")
        let changelog = """
        # Changelog

        ## v1.13.0

        New / 新功能
        - Added a thing that wraps
          onto two lines
          新增一样东西，
          折成两行
        - English only
        - Fixed DNS
          修好 VPN 下发
          DNS
          时；
          ListenBrainz 也行

        Fixed / 修复
        - Fixed a 组曲 prefix
          修复「组曲」前缀
        | Chip / 芯片 | dmg |
        |---|---|
        Not sure which one? Check your chip
        不确定该下哪个？

        **Full Changelog**: https://example.com

        ## v1.12.0

        New / 新功能
        - Old item
          旧条目
        """
        let section = ReleaseNotes.section(version: "1.13.0", in: changelog) ?? ""
        expectEqual(section.contains("Old item"), false, "分节: 到下一个 ## v 为止")
        expectEqual(ReleaseNotes.section(version: "1.14.0", in: changelog), nil, "分节: 没有这一版为 nil")
        let range = ReleaseNotes.sections(after: "1.11.0", through: "1.13.0", in: changelog)
        expectEqual(range.count == 2 && range[0].contains("Added a thing") && range[1].contains("Old item"), true,
                    "分节: 基准之后到当前的每一版都取,新的在前")
        expectEqual(ReleaseNotes.sections(after: "1.13.0", through: "1.13.0", in: changelog).count, 1,
                    "分节: 范围里一节都没有时退回当前那一节")
        let merged = ReleaseNotes.merge(range.map { ReleaseNotes.parse($0, chinese: false) })
        expectEqual(merged.map(\.title), ["New", "Fixed"], "合并: 同名小节并在一起")
        expectEqual(merged.first?.items.last, "Old item", "合并: 条目新版在前")
        expectEqual(ReleaseNotes.parse(section, chinese: false), [
            .init(title: "New", items: ["Added a thing that wraps onto two lines", "English only", "Fixed DNS"]),
            .init(title: "Fixed", items: ["Fixed a 组曲 prefix"]),
        ], "英文: 小节标题取左边,硬换行补空格,夹着的中文词不算中文行,表格和散句不收")
        expectEqual(ReleaseNotes.parse(section, chinese: true), [
            .init(title: "新功能", items: ["新增一样东西，折成两行", "English only", "修好 VPN 下发 DNS 时；ListenBrainz 也行"]),
            .init(title: "修复", items: ["修复「组曲」前缀"]),
        ], "中文: 小节标题取右边,中文行直接接,汉字挨着英文字母补空格、挨着标点不补,没写中文的退回英文")
    }

    do {
        print("\n== 本次更新:仓库里的 CHANGELOG 每一版都拆得开 ==")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = (try? String(contentsOf: repo.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)) ?? ""
        let versions = text.components(separatedBy: "\n").filter { $0.hasPrefix("## v") }.map { String($0.dropFirst(4)) }
        expectEqual(versions.isEmpty, false, "CHANGELOG: 读得到")
        func hasCJK(_ s: String) -> Bool { s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        var broken: [String] = []
        for version in versions {
            let section = ReleaseNotes.section(version: version, in: text) ?? ""
            let en = ReleaseNotes.parse(section, chinese: false), zh = ReleaseNotes.parse(section, chinese: true)
            let zhItems = zh.flatMap(\.items)
            // 拆不出中文行的条目整条退回英文(中文行一起混进去),两边一模一样;同 split_release_notes.py 的 one_sided_bullets。
            let fellBack = zip(en.flatMap(\.items), zhItems).contains { $0 == $1 }
            if en.isEmpty || en.map(\.items.count) != zh.map(\.items.count) || zhItems.contains(where: { !hasCJK($0) }) || fellBack {
                broken.append(version)
            }
        }
        expectEqual(broken, [], "CHANGELOG: 每一版两种语言条目一一对应、中文条目都是中文、每条都拆得出中文行")
    }

    do {
        print("\n== 本次更新:按界面语言取译文 ==")
        let changelog = """
        ## v1.14.0

        New / 新功能
        - Added one
          新增一
        - Added two
          新增二

        Fixed / 修复
        - Fixed three
          修复三

        ## v1.13.0

        New / 新功能
        - Old item
          旧条目
        """
        let v14 = ReleaseNotes.section(version: "1.14.0", in: changelog) ?? ""
        let v13 = ReleaseNotes.section(version: "1.13.0", in: changelog) ?? ""
        typealias T = ReleaseNotes.Translation
        let ja = T(titles: ["新功能": "新機能", "修复": "修正"],
                   versions: ["1.14.0": ["新功能": ["一つ目", "二つ目"], "修复": ["三つ目"]]])
        expectEqual(ReleaseNotes.localize(v14, version: "1.14.0", language: "ja", translation: ja), [
            .init(title: "新機能", items: ["一つ目", "二つ目"]), .init(title: "修正", items: ["三つ目"]),
        ], "译文: 按版本号和小节的中文标题取")
        expectEqual(ReleaseNotes.localize(v14, version: "1.14.0", language: "zh-hans", translation: ja),
                    ReleaseNotes.parse(v14, chinese: true), "简体: 直接取 CHANGELOG 的中文")
        expectEqual(ReleaseNotes.localize(v14, version: "1.14.0", language: "en", translation: ja),
                    ReleaseNotes.parse(v14, chinese: false), "英文: 直接取 CHANGELOG 的英文")
        expectEqual(ReleaseNotes.localize(v13, version: "1.13.0", language: "ja", translation: ja),
                    [.init(title: "新機能", items: ["Old item"])], "译文缺这一版: 条目退回英文,小节标题仍用译文")
        let short = T(titles: [:], versions: ["1.14.0": ["新功能": ["一つ目"], "修复": ["三つ目"]]])
        expectEqual(ReleaseNotes.localize(v14, version: "1.14.0", language: "ja", translation: short), [
            .init(title: "New", items: ["Added one", "Added two"]), .init(title: "Fixed", items: ["三つ目"]),
        ], "条数跟 CHANGELOG 对不上的小节退回英文,别的小节照用译文;没有标题译文用英文标题")
        expectEqual(ReleaseNotes.localize(v14, version: "1.14.0", language: "de", translation: nil),
                    ReleaseNotes.parse(v14, chinese: false), "没有这种语言的译文: 整节英文")
        expectEqual(ReleaseNotes.localize(v13, version: "1.13.0", language: "zh-hant", translation: nil),
                    [.init(title: "新功能", items: ["舊條目"])], "繁体缺译文: 退回简体经 ICU 转写")
        let merged = ReleaseNotes.merge(ReleaseNotes.versionedSections(after: "1.12.0", through: "1.14.0", in: changelog).map {
            ReleaseNotes.localize($0.body, version: $0.version, language: "ja", translation: ja)
        })
        expectEqual(merged.first?.items, ["一つ目", "二つ目", "Old item"], "跨版本: 带上版本号逐节取译文,同名小节并在一起")
        expectEqual(T.decode(Data(#"{"titles":{"新功能":"新機能"},"versions":{"1.14.0":{"新功能":["一つ目"]}}}"#.utf8)),
                    T(titles: ["新功能": "新機能"], versions: ["1.14.0": ["新功能": ["一つ目"]]]), "译文文件: JSON 读得出")
    }

    do {
        print("\n== 本次更新:仓库里的译文 ==")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = (try? String(contentsOf: repo.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)) ?? ""
        let versions = text.components(separatedBy: "\n").filter { $0.hasPrefix("## v") }.map { String($0.dropFirst(4)) }
        // 从这一版起 CHANGELOG 里的每一版都要有全部界面语言的译文;新加的一节没写译文,这一组就红。见 14 章决策 236。
        let translatedSince = "1.13.0"
        let required = versions.filter { WhatsNew.compare($0, translatedSince) != .orderedAscending }
        expectEqual(required.contains("1.13.0") && required.contains("1.14.0"), true, "译文范围: 含 1.13.0 与 1.14.0")

        let dir = repo.appendingPathComponent("release-notes")
        let packs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        expectEqual(Set(packs).isDisjoint(with: ["zh-hans", "en"]) && Set(packs).union(["zh-hans", "en"]) == Set(UILanguage.packs), true,
                    "译文: 简体、英文以外的每种界面语言各一份(release-notes/<语言包>.json),没有多出来的")

        // 各语言给设置名加的引号,照 Localization/<语言>-STYLE.md。加界面语言时在这里登记。
        let nbsp = String(Character(Unicode.Scalar(UInt8(0xA0))))
        let quotes: [String: (String, String)] = [
            "zh-hant": ("「", "」"), "ja": ("「", "」"), "ko": ("‘", "’"), "es": ("«", "»"), "fr": ("«" + nbsp, nbsp + "»"),
            "de": ("„", "“"), "it": ("“", "”"), "pt-br": ("“", "”"), "vi": ("“", "”"), "ru": ("«", "»"), "uk": ("«", "»"),
            "th": ("“", "”"), "tr": ("“", "”"), "hi": ("“", "”"),
        ]
        expectEqual(Set(quotes.keys), Set(packs), "译文: 每种语言都登记了引号")

        let catalogData = (try? Data(contentsOf: repo.appendingPathComponent("lyrimuse/Localization/Localizable.xcstrings"))) ?? Data()
        let catalog = ((try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
        func catalogValue(_ key: String, _ pack: String) -> String? {
            let entry = catalog[key] as? [String: Any]
            let localization = (entry?["localizations"] as? [String: Any])?[UILanguage.localeIdentifier(for: pack)] as? [String: Any]
            return (localization?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        func quotedNames(_ line: String) -> [String] {
            var names: [String] = [], rest = Substring(line)
            while let open = rest.firstIndex(of: "「"), let close = rest[open...].firstIndex(of: "」") {
                names.append(String(rest[rest.index(after: open)..<close]))
                rest = rest[rest.index(after: close)...]
            }
            return names
        }
        expectEqual(quotedNames("新增「跟随音乐跳动」与「声音」"), ["跟随音乐跳动", "声音"], "引号里的名字: 逐个取出")

        var problems: [String] = []
        var checkedNames = 0
        for pack in packs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(pack + ".json")),
                  let translation = ReleaseNotes.Translation.decode(data) else {
                problems.append("\(pack): 读不出")
                continue
            }
            let (open, close) = quotes[pack] ?? ("", "")
            for version in translation.versions.keys where !versions.contains(version) {
                problems.append("\(pack): CHANGELOG 里没有 v\(version)")
            }
            for version in required {
                let section = ReleaseNotes.section(version: version, in: text) ?? ""
                let zh = ReleaseNotes.parse(section, chinese: true), en = ReleaseNotes.parse(section, chinese: false)
                guard let byTitle = translation.versions[version] else {
                    problems.append("\(pack) v\(version): 缺这一版")
                    continue
                }
                for title in byTitle.keys where !zh.contains(where: { $0.title == title }) {
                    problems.append("\(pack) v\(version): CHANGELOG 里没有小节「\(title)」")
                }
                for (zhSection, enSection) in zip(zh, en) {
                    let place = "\(pack) v\(version) \(zhSection.title)"
                    if (translation.titles[zhSection.title] ?? "").isEmpty { problems.append("\(place): 缺小节标题译文") }
                    guard let items = byTitle[zhSection.title], items.count == zhSection.items.count else {
                        problems.append("\(place): \(byTitle[zhSection.title]?.count ?? 0) 条,CHANGELOG 是 \(zhSection.items.count) 条")
                        continue
                    }
                    for (i, item) in items.enumerated() {
                        if item.trimmingCharacters(in: .whitespaces).isEmpty || item == enSection.items[i]
                            || (pack != "zh-hant" && item == zhSection.items[i]) {
                            problems.append("\(place) 第 \(i + 1) 条: 空的或照抄原文")
                        }
                        for name in quotedNames(zhSection.items[i]) {
                            guard let value = catalogValue(name, pack) else { continue }
                            checkedNames += 1
                            if !item.contains(open + value + close) {
                                problems.append("\(place) 第 \(i + 1) 条: 要写成 \(open)\(value)\(close)")
                            }
                        }
                    }
                }
            }
        }
        expectEqual(problems, [], "译文: \(translatedSince) 起每一版、每一小节的条数跟 CHANGELOG 一致,小节标题齐全,不照抄原文")
        expectEqual(checkedNames > 0, true, "译文: 「」里引用的设置名逐个对过 xcstrings(\(checkedNames) 处)")
    }

    do {
        print("\n== 本次更新:接线 ==")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func sourceText(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        expectEqual(sourceHas(sourceText("lyrimuse/AppDelegate.swift"), "WhatsNewCenter.shared.start()"), true,
                    "接线: 启动时定基准、记下当前版本")
        let panel = sourceText("lyrimuse/MenuBar/MenuBarPanel.swift")
        expectEqual(sourceHas(panel, "@State private var whatsNewVersion = WhatsNewCenter.shared.bannerVersion")
                    && sourceHas(panel, "AppActions.shared.openWhatsNew?()"), true,
                    "接线: 面板顶部「已更新」开面板那一刻取一次,点进去开卡片")
        expectEqual(sourceHas(sourceBody("private struct WhatsNewBanner: View", in: panel),
                              ".onAppear { WhatsNewCenter.shared.bannerShown() }"), true,
                    "接线: 横条摆出来就记下,只出一次")
        expectEqual(sourceHas(sourceText("lyrimuse/MenuBar/MenuBarStatusMenu.swift"), "L10n.t(\"查看本次更新…\")"), true,
                    "接线: 右键菜单有「查看本次更新…」")
        expectEqual(sourceHas(sourceText("lyrimuse/MenuBar/MenuBarSceneActions.swift"),
                              "openWindowAction(id: WhatsNewWindow.sceneID)"), true, "接线: 卡片窗口由锚点视图开")
        expectEqual(sourceHas(sourceText("lyrimuse/App.swift"), "id: WhatsNewWindow.sceneID"), true, "接线: 卡片是一扇场景窗")
        let notes = sourceBody("private var notes: some View", in: sourceText("lyrimuse/UI/WhatsNewWindow.swift"))
        expectEqual(sourceHas(notes, ".padding(.vertical, Self.edgeFade + 2)") && sourceHas(notes, ".mask {")
                    && sourceHas(notes, ".frame(height: Self.edgeFade)"), true,
                    "卡片: 滚动区上下边缘淡出、卡片离边缘留白大于淡出高度(玻璃卡投影不被滚动区切出灰带,14 章决策 235)")
        let build = sourceText("../build.sh")
        expectEqual(sourceHas(build, "cp ../CHANGELOG.md \"$APP_DIR/Contents/Resources/CHANGELOG.md\"")
                    && sourceHas(build, "cp -p ../CHANGELOG.md \"$SNAPSHOT_ROOT/CHANGELOG.md\"")
                    && sourceHas(sourceText("../package.sh"), "\"Resources/CHANGELOG.md\""), true,
                    "接线: CHANGELOG 打进包里(含快照),打包时查它在")
        expectEqual(sourceHas(build, "rsync \"${SNAPSHOT_RSYNC[@]}\" --delete ../release-notes/ \"$SNAPSHOT_ROOT/release-notes/\"")
                    && sourceHas(build, "cp -R ../release-notes \"$APP_DIR/Contents/Resources/release-notes\"")
                    && sourceHas(sourceText("../package.sh"), "\"Resources/release-notes/ja.json\""), true,
                    "接线: 各语言的译文 release-notes/ 打进包里(含快照),打包时查它在")
        let whatsNewCenter = sourceBody("static func currentNotes()", in: sourceText("lyrimuse/Settings/WhatsNewCenter.swift"))
        expectEqual(sourceHas(whatsNewCenter, "subdirectory: \"release-notes\"")
                    && sourceHas(whatsNewCenter, "ReleaseNotes.localize($0.body, version: $0.version, language: language, translation: translation)"),
                    true, "接线: 卡片按界面语言读包里的译文")
        let portability = sourceText("lyrimuse/Settings/ConfigPortability.swift")
        let machineLocal = portability.range(of: "private static let machineLocalDefaultsKeys").flatMap { a in
            portability.range(of: "\n    ]", range: a.upperBound..<portability.endIndex).map { portability[a.upperBound..<$0.lowerBound] }
        } ?? ""
        expectEqual(sourceHas(machineLocal, "WhatsNewCenter.Keys.lastLaunchedVersion,")
                    && sourceHas(machineLocal, "WhatsNewCenter.Keys.baseline,")
                    && sourceHas(machineLocal, "WhatsNewCenter.Keys.bannerShown,")
                    && sourceHas(machineLocal, "WhatsNewCenter.Keys.knownLanguagePacks,")
                    && sourceHas(machineLocal, "WhatsNewCenter.Keys.languageOffer,"), true, "接线: 这几个键是机器专属的")

        print("\n== 升级后提示改用新加的界面语言 ==")
        typealias O = NewLanguageOffer
        let old = O.legacyPacks
        expectEqual(O.offer(chosen: "en", preferredLanguages: ["th-TH", "en-US"], knownPacks: nil, isExistingUser: true), "th",
                    "提示: 老用户手动选了英文,系统首选是这次才有的泰语")
        expectEqual(O.offer(chosen: "zh-hans", preferredLanguages: ["pt-PT"], knownPacks: old, isExistingUser: true), "pt-br",
                    "提示: 葡萄牙语系统归巴西葡语包")
        expectEqual(O.offer(chosen: "en", preferredLanguages: ["uk", "ru"], knownPacks: old, isExistingUser: true), "uk",
                    "提示: 系统列表「uk, ru」提示乌克兰语")
        expectEqual(O.offer(chosen: nil, preferredLanguages: ["th"], knownPacks: old, isExistingUser: true), nil,
                    "不提示: 没选过界面语言(跟随系统),升级后自己就换了")
        expectEqual(O.offer(chosen: "system", preferredLanguages: ["th"], knownPacks: old, isExistingUser: true), nil,
                    "不提示: 选的是跟随系统")
        expectEqual(O.offer(chosen: "en", preferredLanguages: ["th"], knownPacks: UILanguage.packs, isExistingUser: true), nil,
                    "不提示: 上次启动时就有这种语言,他是特意选了别的")
        expectEqual(O.offer(chosen: "en", preferredLanguages: ["ja-JP"], knownPacks: nil, isExistingUser: true), nil,
                    "不提示: 日语是旧版本就有的")
        expectEqual(O.offer(chosen: "en", preferredLanguages: ["th"], knownPacks: nil, isExistingUser: false), nil,
                    "不提示: 新装的")
        expectEqual(O.offer(chosen: "en", preferredLanguages: ["en-GB", "th"], knownPacks: old, isExistingUser: true), nil,
                    "不提示: 系统首选就是他选的英文")
        expectEqual(O.offer(chosen: "th", preferredLanguages: ["th"], knownPacks: old, isExistingUser: true), nil,
                    "不提示: 已经是这种语言")
        expectEqual(O.offer(chosen: "en", preferredLanguages: ["nb-NO"], knownPacks: old, isExistingUser: true), nil,
                    "不提示: 系统语言没有语言包,协商落到英文")
        expectEqual(Set(old).isSubset(of: Set(UILanguage.packs)), true, "旧版本的语言包都还在")
        expectEqual([O.stillApplies(pending: "th", chosen: "en"), O.stillApplies(pending: "th", chosen: "th"),
                     O.stillApplies(pending: "th", chosen: "system"), O.stillApplies(pending: "th", chosen: nil),
                     O.stillApplies(pending: nil, chosen: "en"), O.stillApplies(pending: "xx", chosen: "en")],
                    [true, false, false, false, false, false], "存着的提示: 切过去了、改回跟随系统、包没了都不再出")
        expectEqual([O.settles(pending: "th", chosen: "th"), O.settles(pending: "th", chosen: "system"),
                     O.settles(pending: "th", chosen: "en"), O.settles(pending: nil, chosen: "th")],
                    [true, true, false, false], "自己在设置里切到那种语言或改回跟随系统:提示删掉,之后切回别的也不再出")
        expectEqual(sourceHas(sourceText("lyrimuse/Settings/AppSettings.swift"),
                              "defaults.set(appLanguage, forKey: Keys.appLanguage)\nWhatsNewCenter.shared.languageChosen(appLanguage)"), true,
                    "接线: 改界面语言时让提示自己判断要不要删")
        let center = sourceText("lyrimuse/Settings/WhatsNewCenter.swift")
        expectEqual(sourceHas(center, "defaults.set(UILanguage.packs, forKey: Keys.knownLanguagePacks)")
                    && sourceHas(center, "isExistingUser: lastLaunched != nil || AppSettings.shared.hasCompletedOnboarding"), true,
                    "接线: 启动时先算提示、再记下这一版的语言包")
        let offerPanel = sourceText("lyrimuse/MenuBar/MenuBarPanel.swift")
        expectEqual(sourceHas(offerPanel, "L10n.t(\"Lyrimuse 现已支持简体中文\", language: pack)")
                    && sourceHas(offerPanel, "L10n.t(\"切换\", language: pack)")
                    && sourceHas(offerPanel, "LanguageOfferBanner(pack: pack)"), true, "接线: 面板顶部的横条用那种语言写")
    }
}
