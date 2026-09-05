import LyrimuseCore
import Foundation

// 跨文件契约(多数靠 #filePath 扫源码文本):设置页分段 / 本地化 / 滑杆 / 封面口径 / 灵动岛对齐 / 引导页。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runSourceContractTests() {
    // ---- 「歌词显示」页分段的跨文件契约(2026-08-19) ----
    //
    // 菜单栏面板的「全部设置…」靠往一个 UserDefaults 键写这几个字符串,把设置窗口直接翻到
    // 对应那一段。键名和取值必须跟 SettingsView 里 AppearanceSettingsTab.Section 的 rawValue
    // 对得上 —— 对不上不会编译报错,只会表现成"长按灵动岛、设置窗口却停在悬浮歌词那一段"。
    // 这里能钉住的是本侧这一半;另一半在那个 enum 上留了 ⚠️ 注释。

    expectEqual(LyricsSurface.allCases.map(\.rawValue), ["overlay", "notch", "menuBar"],
                "形态: 三个取值与设置页分段一致")
    expectEqual(LyricsSurface.appearanceSectionStorageKey, "settings:appearanceSection",
                "形态: 分段存储键名")
    expectEqual(LyricsSurface.notch.appearanceSectionRawValue, "notch", "形态: 灵动岛 → notch 段")
    expectEqual(LyricsSurface(rawValue: "menuBar"), .menuBar, "形态: rawValue 往回认得出来")
    expectEqual(LyricsSurface(rawValue: "other"), nil, "形态: 「其它」段不属于任何一个形态")

    // ---- 本地化:Localizable.xcstrings 是唯一真源,生成的 .strings 必须与它逐键逐值一致 ----
    //
    // 2026-08-17 迁移到 String Catalog(吸收自 boring.notch 审阅 B9):词条只在
    // Localization/Localizable.xcstrings 里维护,两份 .lproj/Localizable.strings 是
    // generate-strings.py 的生成物、随仓库一起提交 —— 终端用户 `swift build`/build.sh
    // 完全不需要 Xcode(xcstringstool 只在完整 Xcode 里,CLT 没有)。
    // 这道守卫盯的就是"改了 catalog 忘了重新生成"和"手改了生成物"两种漂移:
    // 任何一边动了而另一边没跟上,这里立刻红,并指名去跑生成脚本。
    //
    // 用 #filePath 定位仓库内文件:文件真不在(目录挪了)就 FAIL 而不是静默跳过 ——
    // 守卫自身失效也必须看得见。
    do {
        // 生成物解析:一行一条 `"key" = "value";`。用 #/…/# 扩展定界符 —— 裸斜杠正则
        // 字面量在 5.9 工具链要开特性开关,扩展定界符不用。
        func stringsPairs(_ path: String) -> [String: String]? {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            func unescape(_ s: Substring) -> String {
                s.replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\t", with: "\t")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            var pairs: [String: String] = [:]
            let pattern = #/^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/#
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                if let m = line.firstMatch(of: pattern) {
                    let key = unescape(m.1)
                    // 同键后者静默覆盖前者,是排查不出来的那种坑 —— 当场红。
                    if pairs[key] != nil { return nil }
                    pairs[key] = unescape(m.2)
                }
            }
            return pairs
        }
        let sourcesDir = URL(fileURLWithPath: #filePath)    // …/Sources/lyrimuse-selftest/SourceContractTests.swift
            .deletingLastPathComponent()                    // …/Sources/lyrimuse-selftest
            .deletingLastPathComponent()                    // …/Sources
        let catalogPath = sourcesDir.deletingLastPathComponent()
            .appendingPathComponent("Localization/Localizable.xcstrings").path
        let resources = sourcesDir.appendingPathComponent("lyrimuse/Resources")

        struct CatalogPairs {
            var zh: [String: String] = [:]; var en: [String: String] = [:]; var hant: [String: String] = [:]
            /// 缺 zh-Hant 译文的键。2026-09-03 用户定:新加文案必须把当前支持的语言都写全,所以这里
            /// 不再回退简体后放行,而是记下来让下面那条断言红(生成脚本对同一情况也是直接失败)。
            var missingHant: [String] = []
        }
        func catalogPairs(_ path: String) -> CatalogPairs? {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["sourceLanguage"] as? String == "zh-Hans",
                  let strings = obj["strings"] as? [String: Any], !strings.isEmpty
            else { return nil }
            var out = CatalogPairs()
            for (key, raw) in strings {
                let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any]
                func value(_ lang: String) -> String? {
                    (((localizations?[lang] as? [String: Any])?["stringUnit"]) as? [String: Any])?["value"] as? String
                }
                // 源语言允许省略(值即键,跟 generate-strings.py 同一条规则);英文缺翻译
                // 必须红 —— 静默回退成中文正是这套守卫要消灭的事故。
                out.zh[key] = value("zh-Hans") ?? key
                if let hant = value("zh-Hant"), !hant.isEmpty {
                    out.hant[key] = hant
                } else {
                    out.missingHant.append(key)
                    out.hant[key] = out.zh[key]!
                }
                guard let en = value("en"), !en.isEmpty else { return nil }
                out.en[key] = en
            }
            return out
        }

        if let catalog = catalogPairs(catalogPath),
           let zhGen = stringsPairs(resources.appendingPathComponent("zh-hans.lproj/Localizable.strings").path),
           let hantGen = stringsPairs(resources.appendingPathComponent("zh-hant.lproj/Localizable.strings").path),
           let enGen = stringsPairs(resources.appendingPathComponent("en.lproj/Localizable.strings").path) {
            expectEqual(catalog.zh.isEmpty, false, "本地化: catalog 解析出键")
            expectEqual(catalog.missingHant.sorted(), [],
                        "本地化: 每个键都要有 zh-Hant 译文(新加文案必须三语齐全,见 AGENTS.md「本地化」与 Localization/zh-Hant-STYLE.md)")
            // 逐键逐值一致。两个方向的差集分别报,谁多谁少一目了然;值不同单独报。
            func diff(_ a: [String: String], _ b: [String: String], _ tag: String) {
                expectEqual(Set(a.keys).subtracting(b.keys).sorted(), [],
                            "本地化: catalog 有而 \(tag) 生成物缺的键(跑 Localization/generate-strings.py)")
                expectEqual(Set(b.keys).subtracting(a.keys).sorted(), [],
                            "本地化: \(tag) 生成物有而 catalog 缺的键(生成物只能由脚本生成,别手改)")
                let valueDiff = a.keys.filter { b[$0] != nil && a[$0] != b[$0] }.sorted()
                expectEqual(valueDiff, [], "本地化: \(tag) 生成物与 catalog 值不一致(跑 generate-strings.py)")
            }
            diff(catalog.zh, zhGen, "zh-hans")
            diff(catalog.hant, hantGen, "zh-hant")
            diff(catalog.en, enGen, "en")

            // ---- 语言协商(2026-09-03 加繁体):系统语言标签 → 语言包目录名,规则见 UILanguage ----
            expectEqual(UILanguage.resolve(preferred: "zh-Hans-CN"), "zh-hans", "本地化: zh-Hans-CN → 简体包")
            expectEqual(UILanguage.resolve(preferred: "zh"), "zh-hans", "本地化: 裸 zh → 简体包")
            expectEqual(UILanguage.resolve(preferred: "zh-SG"), "zh-hans", "本地化: zh-SG → 简体包")
            expectEqual(UILanguage.resolve(preferred: "zh-Hant-TW"), "zh-hant", "本地化: zh-Hant-TW → 繁体包")
            expectEqual(UILanguage.resolve(preferred: "zh-TW"), "zh-hant", "本地化: zh-TW → 繁体包")
            expectEqual(UILanguage.resolve(preferred: "zh-HK"), "zh-hant", "本地化: zh-HK → 繁体包")
            expectEqual(UILanguage.resolve(preferred: "zh-MO"), "zh-hant", "本地化: zh-MO → 繁体包")
            expectEqual(UILanguage.resolve(preferred: "zh-Hans-HK"), "zh-hans", "本地化: zh-Hans-HK 显式 Hans 优先于地区码 → 简体包")
            expectEqual(UILanguage.resolve(preferred: "zh-Hant-CN"), "zh-hant", "本地化: zh-Hant-CN 显式 Hant 优先于地区码 → 繁体包")
            expectEqual(UILanguage.resolve(preferred: "en-GB"), "en", "本地化: en-GB → 英文包")
            expectEqual(UILanguage.resolve(preferred: "EN"), "en", "本地化: 大小写不敏感")
            expectEqual(UILanguage.resolve(preferred: "ja-JP"), "zh-hans", "本地化: 没有对应语言包的系统语言退回开发语言(简体)")
            expectEqual(UILanguage.isTraditionalChineseTag("ja-JP"), false, "本地化: isTraditionalChineseTag 只管 zh 家族")

            // ---- 第三条:源码里每一个 L10n.t("字面量") 都必须在 catalog 里 ----
            //
            // 上面两条只对账 catalog ↔ 生成物,**从不看源码**,于是"加了个 L10n.t 却忘了往 catalog
            // 补词条"这类漏网全绿。而 L10n.t 的兜底是 `bundle.localizedString(forKey:value:key)`
            // —— 找不到就**静默返回键本身**(也就是原始中文),不崩、不空白。表现是英文界面下同一行
            // 中英混排(隔壁「来源」已经是 "Source"、这一格「偏移」还是汉字),极不显眼。
            // 2026-08-31 一次性核出 31 个这样的键,分布在歌词管理/歌词窗口/Last.fm 面板/关于页
            // —— 全都是"写代码时顺手 L10n.t 了一下"留下的,没有任何守卫拦得住,故补这一条。
            //
            // ⚠️ 只认**字面量**入参。`L10n.t(someVariable)` 这种拿不到键,自然扫不到,那是接受的
            // 盲区(真要覆盖得做全量语义分析);反过来说,新增文案时别绕开字面量写法。
            // ⚠️ 这是**纯文本扫描**,不区分代码和注释:注释里把一次调用整句写出来,同样算数。
            //    所以注释里引用调用点时别写全(写成「那个 L10n 键」即可),或者干脆把那个键留在
            //    catalog 里 —— 真撞上时红灯信息里会直接点名是哪个键,不难查。
            // 只扫 Sources/lyrimuse(全部调用点都在这个 target;LyrimuseCore 是纯逻辑库、不碰 UI 文案),
            // 顺带把本文件排除在外 —— 下面那条正则的**模式串本身**长得就像一次调用。
            let uiSources = sourcesDir.appendingPathComponent("lyrimuse")
            let callPattern = #/L10n\.t\(\s*"((?:[^"\\]|\\.)*)"\s*\)/#
            var literalKeys: Set<String> = []
            var scannedFiles = 0
            if let walker = FileManager.default.enumerator(atPath: uiSources.path) {
                for case let rel as String in walker where rel.hasSuffix(".swift") {
                    let path = uiSources.appendingPathComponent(rel).path
                    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                    scannedFiles += 1
                    for m in text.matches(of: callPattern) {
                        literalKeys.insert(
                            String(m.1)
                                .replacingOccurrences(of: "\\n", with: "\n")
                                .replacingOccurrences(of: "\\t", with: "\t")
                                .replacingOccurrences(of: "\\\"", with: "\"")
                                .replacingOccurrences(of: "\\\\", with: "\\"))
                    }
                }
            }
            // 一个都没扫到 = 目录挪了或正则失效,守卫自身失效必须看得见(同 #filePath 那条)。
            expectEqual(scannedFiles > 0 && !literalKeys.isEmpty, true,
                        "本地化: 源码扫描到了 L10n.t 调用点(扫到 \(scannedFiles) 个文件、\(literalKeys.count) 个键)")
            expectEqual(literalKeys.subtracting(catalog.zh.keys).sorted(), [],
                        "本地化: 源码用了但 catalog 里没有的键(英文界面会静默显示中文 —— 补进 Localization/Localizable.xcstrings 再跑 generate-strings.py)")
        } else {
            expectEqual(true, false,
                        "本地化: catalog/生成物读不出来 —— 文件缺失、en 缺翻译、或生成物有重复键")
        }
    }

    // ---- 滑杆刻度:界面里不许再出现"带步长入参的原生 Slider" ----
    //
    // macOS 的 SwiftUI Slider 一旦拿到步长入参,就会在轨道下面画一排刻度点,而且关不掉
    // (没有对应修饰符,底层也不是 NSSlider 包出来的,拿不到 numberOfTickMarks 清零 ——
    // 详见 SettingsDesignSystem.swift 里 SteppedSlider 的注释)。
    //
    // 为什么要上一条守卫而不是"注意点":用户为这排点报过两次。2026-08-31 第一次报的是悬浮
    // 歌词那一根,当时就地改掉了;2026-09-02 又报了设置页其余**全部**滑杆 —— 因为"每个调用点
    // 自己记得别传"根本挡不住后来新写的滑杆,五处里有四处是那之后新加的。所以改成:量化一律
    // 走 SteppedSlider(它内部那次调用本身不带步长入参,天然不会被算进来),这里盯着别复发。
    //
    // ⚠️ 纯文本扫描,不区分代码和注释(同上面 L10n 那条守卫的盲区)。注释里提到"带步长的那个
    //    构造器"时用中文描述,别把那句调用整句写全,否则会被当成一次真调用。
    // ⚠️ 只看**第一层**参数区:嵌套调用里的同名参数标签(比如 SteppedSlider 自己 body 里
    //    那句 snap 调用)不算,不然它会把自己判红。
    do {
        let uiSources = URL(fileURLWithPath: #filePath)    // …/Sources/lyrimuse-selftest/SourceContractTests.swift
            .deletingLastPathComponent()                   // …/Sources/lyrimuse-selftest
            .deletingLastPathComponent()                   // …/Sources
            .appendingPathComponent("lyrimuse")

        // 从左括号开始做括号配平,只把**深度 1**(也就是这次调用自己的参数区)的字符收集起来。
        // 配不平或超出上限就返回 nil —— 宁可漏报也不误报。
        func topLevelArguments(_ chars: [Character], openIndex: Int) -> String? {
            var depth = 0
            var collected: [Character] = []
            var i = openIndex
            let limit = min(chars.count, openIndex + 4000)
            while i < limit {
                let c = chars[i]
                if c == "(" {
                    depth += 1
                    if depth > 1 { collected.append(c) }
                } else if c == ")" {
                    depth -= 1
                    if depth == 0 { return String(collected) }
                    collected.append(c)
                } else if depth >= 1 {
                    if depth == 1 { collected.append(c) }
                }
                i += 1
            }
            return nil
        }

        let needle = Array("Slider(")
        var scannedFiles = 0
        var directCallSites = 0
        var offenders: [String] = []
        if let walker = FileManager.default.enumerator(atPath: uiSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: uiSources.appendingPathComponent(rel).path,
                                             encoding: .utf8) else { continue }
                scannedFiles += 1
                let chars = Array(text)
                var i = 0
                while i + needle.count <= chars.count {
                    guard Array(chars[i ..< (i + needle.count)]) == needle else { i += 1; continue }
                    // 前一个字符是标识符字符 = 这是 SteppedSlider( / volumeSlider( 这类别的名字,
                    // 不是对原生 Slider 的直接调用。
                    let prev: Character? = i > 0 ? chars[i - 1] : nil
                    let isDirectCall = prev.map { !($0.isLetter || $0.isNumber || $0 == "_") } ?? true
                    if isDirectCall {
                        directCallSites += 1
                        if let args = topLevelArguments(chars, openIndex: i + needle.count - 1),
                           args.contains("step:") {
                            offenders.append(rel)
                        }
                    }
                    i += needle.count
                }
            }
        }
        // 一个都没扫到 = 目录挪了或匹配失效。守卫自身失效必须看得见(同 L10n 那条)。
        expectEqual(scannedFiles > 0 && directCallSites > 0, true,
                    "滑杆刻度: 扫到了对原生 Slider 的直接调用(\(scannedFiles) 个文件、\(directCallSites) 处)")
        expectEqual(offenders.sorted(), [],
                    "滑杆刻度: 这些文件里的 Slider 还带着步长入参 —— 会在轨道下面画一排刻度点,换成 SteppedSlider")
    }

    // ---- 封面消费面必须用高清替代优先的口径(2026-09-02)----
    //
    // `PlaybackCoordinator.highResArtworkImage` 的契约是"系统那份太小/不像封面时才有值,
    // 否则 nil、消费方退回 artworkImage" —— 也就是说**每个消费面都有义务**写
    // `highResArtworkImage ?? artworkImage`。
    //
    // 为什么要上机械闸:这条口径靠"记得写"维护了三个月,漏了三处才被用户发现 —— 用户报
    // 「为什么这两个地方的封面不一样」(方大同《白发》,Chrome 里放 YouTube Music),菜单栏
    // 快捷面板显示的是系统给的**一帧 150×84 的 MV 截帧**,而歌词窗口显示的是缓存里正确的
    // 专辑封面。同一天连带查出灵动岛收起态左耳、Last.fm「正在播放」行也漏了同一个 `?? `。
    // 漏了**不会编译报错、也不会崩**,只表现成"两个地方的封面不一样",而新增一个消费面时
    // 最容易忘的就是这一句。
    //
    // ⚠️ 纯文本扫描,同 L10n / 滑杆刻度那两条守卫的盲区:注释里写 `playback.artworkImage`
    // 时**不要**写成 `if let image = playback.artworkImage {` 这种完整取值形态。
    do {
        let uiSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Sources/lyrimuse-selftest
            .deletingLastPathComponent()   // …/Sources
            .appendingPathComponent("lyrimuse")

        // 认"取值"而不是"声明/订阅/赋值":`<something>.artworkImage` 前面有个点、且这一行
        // 不是 @Published 声明、不是 Combine 订阅、不是赋值左值。
        var offenders: [String] = []
        var scannedFiles = 0
        var readSites = 0
        if let walker = FileManager.default.enumerator(atPath: uiSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: uiSources.appendingPathComponent(rel).path,
                                             encoding: .utf8) else { continue }
                scannedFiles += 1
                for (i, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(rawLine)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                    guard line.contains(".artworkImage") else { continue }
                    // 声明 / 订阅 / 赋值 / KeyPath —— 都不是"消费"。
                    if line.contains("@Published") || line.contains("$artworkImage")
                        || line.contains("removeDuplicates") || line.contains(".sink")
                        || line.contains("\\.artworkImage") || line.contains("artworkImage = ") {
                        continue
                    }
                    readSites += 1
                    // 消费点必须自带高清替代优先(直接写 `?? `,或走已经包好的 displayArtworkImage)。
                    if line.contains("highResArtworkImage ?? ") || line.contains("displayArtworkImage") {
                        continue
                    }
                    offenders.append("\(rel):\(i + 1)")
                }
            }
        }
        // 一个都没扫到 = 目录挪了或匹配失效,守卫自身失效必须看得见(同前两条守卫)。
        expectEqual(scannedFiles > 0 && readSites > 0, true,
                    "封面口径: 扫到了 artworkImage 的取值点(\(scannedFiles) 个文件、\(readSites) 处)")
        expectEqual(offenders.sorted(), [],
                    "封面口径: 这些地方裸读 artworkImage、没走高清替代优先 —— 会跟别处显示成两张不同的图(写 `highResArtworkImage ?? artworkImage`,或用 displayArtworkImage)")
    }

    // ---- 灵动岛「对齐方式」的三条接线必须都在(2026-09-03)----
    //
    // 这一项是纯 App target 的(枚举 `LyricsRestingAlignment` 和两个消费点都在
    // Sources/lyrimuse 里),selftest 只链 LyrimuseCore、拿不到类型,所以只能做**源码文本扫描**
    // —— 同上面「封面口径」「滑杆刻度」两条守卫的形态和盲区(注释里别写成完整取值形态)。
    //
    // 为什么值得上闸:三条接线漏任何一条**都不会编译报错**,只表现成"设置改了但某处没跟着变"。
    // 而这个仓库为同一类漏改付过两次代价 —— ①悬浮歌词的「对齐方式」当年在预览条上静默失效,
    // 根因是补对齐时只改了静态文本那一条路径、逐字填色那条漏了(见 OverlayStyleSettingsRows
    // 顶部注释);②封面口径那条(上面那个 do 块)漏了三处才被用户发现。
    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }

        // ① 灵动岛的**两处**歌词文本都要吃这个设置:收起态主歌词行(MarqueeText 的
        //    restingAlignment)和展开态「下一句」预览(那一行自己的 .frame(alignment:))。
        //    只接一处的表现正是"选了居中之后主行居中、预览还贴左",看起来就是没做完。
        if let notch = read("UI/NotchLyricsView.swift") {
            let wired = notch.components(separatedBy: "playback.lyricsAlignment.swiftUIAlignment").count - 1
            expectEqual(wired >= 2, true,
                        "灵动岛对齐: 主歌词行和展开态「下一句」都要接上这个设置(现在只接了 \(wired) 处)")
        } else {
            expectEqual(true, false, "灵动岛对齐: 读不到 UI/NotchLyricsView.swift(路径挪了?)")
        }

        // ② 编辑台的「重置 ▾」要恢复这一项。漏了的表现是"点了重置,对齐没回到左对齐"——
        //    这个仓库给灵动岛加重置按钮时定过纪律:init() 的 fallback 和重置按钮读**同一份**
        //    `AppSettings.defaultXxx` 常量,不各自硬编码。
        if let stage = read("UI/NotchEditorStage.swift") {
            expectEqual(stage.contains("settings.notchLyricsAlignment = AppSettings.defaultNotchLyricsAlignment"),
                        true, "灵动岛对齐: NotchStyleDefaults.restoreDefaults() 要覆盖这一项、且读默认值常量")
        } else {
            expectEqual(true, false, "灵动岛对齐: 读不到 UI/NotchEditorStage.swift(路径挪了?)")
        }

        // ③ 手搓的分段控件**只允许存在两份**:`LyricsAlignmentSegmentedControl`(菜单栏 +
        //    灵动岛共用,3 选项)和 `OverlayAlignmentSegmentedControl`(悬浮歌词那个 4 选项的
        //    对唱覆盖,语义不同、刻意分开)。2026-09-03 给灵动岛加这一项时**没有**复制第三份,
        //    而是把菜单栏那份改名搬去 UI/LyricsAlignmentSegmentedControl.swift —— 这两个控件
        //    的头注里记着"不用系统 segmented picker"和 `.fixedSize()` 两条实测踩出来的尺寸坑,
        //    再多一份就等于下次改尺寸要记得改三处。
        var controlDefs: [String] = []
        if let walker = FileManager.default.enumerator(atPath: appSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard let text = read(rel) else { continue }
                for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix("struct "), line.contains("AlignmentSegmentedControl"),
                          line.contains(": View") else { continue }
                    controlDefs.append(rel)
                }
            }
        }
        expectEqual(controlDefs.sorted(),
                    ["UI/LyricsAlignmentSegmentedControl.swift", "UI/OverlayStyleSettingsRows.swift"],
                    "灵动岛对齐: 手搓对齐分段控件只该有这两份(多出来的是复制的第三份,见上面注释)")
    }

    // ---- 引导页与设置页的"同一件事只有一份实现"(2026-09-03)----
    //
    // 这一轮做了三件事:引导页播放器从单选改多选、加一格 YouTube Music、后面新增「配对浏览器」
    // 一步。三件事都天然诱使人在引导页**照抄**一份设置页已有的逻辑,而那三份逻辑里都带着
    // 实测结论:①"选中集合不能清空"(清空会让 collector 读到非法状态);②`trustAndPair` 的
    // 四步顺序(配对先写、信任后跑、引擎族先落盘、气泡让出一拍);③"信任是候选的来源不是前提"。
    // 抄一份就等于给这些约束开了第二个漂移点。
    //
    // 同上几条守卫:纯文本扫描,只链 LyrimuseCore 的 selftest 拿不到 App target 的类型。
    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }

        // ① 播放器多选:引导页和设置页都必须走 `features.togglePlayer`,不准自己 insert/remove。
        //    裸写 `features.players = [player]`(改多选之前引导页就是这么写的)会绕开非空不变量。
        for rel in ["OnboardingView.swift", "SettingsView.swift"] {
            guard let text = read(rel) else {
                expectEqual(true, false, "引导页一份实现: 读不到 \(rel)(路径挪了?)")
                continue
            }
            let offenders = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .filter { $0.contains("features.players.insert") || $0.contains("features.players.remove")
                            || $0.contains("features.players = [") }
            expectEqual(offenders, [],
                        "引导页一份实现: \(rel) 里直接改 features.players —— 会绕开「选中集合不能清空」那条不变量,改用 features.togglePlayer")
        }

        // ② 配对浏览器:引导页必须调 `BrowserPairing.trustAndPair`,不准自己拼那四步。
        if let onboarding = read("OnboardingView.swift") {
            expectEqual(onboarding.contains("BrowserPairing.trustAndPair("), true,
                        "引导页一份实现: 「配对浏览器」那一步要走 BrowserPairing.trustAndPair(那个函数体里的顺序是实测结论)")
            // 引导页不该自己碰 browserPlatformPairs —— 那是 BrowserPairing 的地盘。
            //
            // ⚠️ 必须**过滤注释行**。第一版写的是整份 `contains`,当场自己红了:引导页的注释里
            // 两处提到这个符号名(讲"探针按它跑""真正落盘的是它"),而那正是应该写在注释里的
            // 说明。这个文件里另外几条源码扫描守卫本来就都跳 `//`/`///`,这条漏了。
            let offenders = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { _, raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && !line.hasPrefix("///")
                        && line.contains("browserPlatformPairs")
                }
                .map { "OnboardingView.swift:\($0.offset + 1)" }
            expectEqual(offenders, [],
                        "引导页一份实现: 引导页不该直接写 browserPlatformPairs,走 BrowserPairing 的 pair/unpair")
        } else {
            expectEqual(true, false, "引导页一份实现: 读不到 OnboardingView.swift(路径挪了?)")
        }

        // ③ 配对逻辑本体只有一份:`BrowserPairing.swift` 里。设置页那几个同名方法只准转发。
        if let settings = read("SettingsView.swift") {
            for forwarded in ["BrowserPairing.trustAndPair(", "BrowserPairing.pair(",
                              "BrowserPairing.unpair(", "BrowserPairing.addableBrowsers(",
                              "BrowserPairing.rememberManualBrowser(",
                              "BrowserPairing.chooseFromApplications(",
                              "BrowserPairing.forgetManualBrowserIfUnpaired("] {
                expectEqual(settings.contains(forwarded), true,
                            "引导页一份实现: SettingsView 里 \(forwarded) 这条转发不见了(逻辑被抄回去了?)")
            }
        } else {
            expectEqual(true, false, "引导页一份实现: 读不到 SettingsView.swift(路径挪了?)")
        }

        // ④ **平台 → 图标那张查表**只允许一份(2026-09-03 从 SettingsView 的 private 类型里
        //    搬出来的原因就是引导页够不着)。
        //
        // ⚠️ 判据翻过一次,记下来别再写错:第一版断言的是"`YouTubeMusicIcon`/`SpotifyIcon`
        // 这两个资源名只该出现在 WebPlatformIcon.swift 里",当场红了 —— 而且是**前提本身错**,
        // 不是漏改:`FeatureSettingsStore.swift` 里 `case .spotify: return "SpotifyIcon"` 是真
        // 代码且完全合理(Spotify **桌面版**那张播放器卡复用同一张 PNG,`AppIconResolver` 的
        // 注释写着"不用再拷一份")。真正该守的不是"资源名只出现一次",而是"把 platformID 翻成
        // 图标的那张表只有一处",所以改成扫 `case "youtubeMusic"` 这个映射形态。
        var platformTables: [String] = []
        if let walker = FileManager.default.enumerator(atPath: appSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard let text = read(rel) else { continue }
                let hit = text.split(separator: "\n", omittingEmptySubsequences: false).contains { raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && !line.hasPrefix("///")
                        && line.contains("case \"youtubeMusic\"")
                }
                if hit { platformTables.append(rel) }
            }
        }
        expectEqual(platformTables.sorted(), ["Settings/WebPlatformIcon.swift"],
                    "引导页一份实现: platformID → 图标那张查表只该有一份(在 WebPlatformIcon.swift)")

        // ⑤ **引导页只允许"一次点击取消一个配对",不准批量删**(2026-09-03 第二轮,真出过事)。
        //
        // 第一版的 `toggleYouTubeMusic` 在取消勾选时 `for bundleID in pairedBrowsers { unpair }`
        // —— 一个播放器网格里的格子,顺手把设置页里配好的一整份浏览器配对删空,没有二次确认、
        // 没有撤销。实测把用户 youtubeMusic 的四个配对删到 `{}`(配对值靠会话记录恢复)。
        // 这条闸钉住:整个引导页 `BrowserPairing.unpair(` 只允许出现**一次**(每张卡自己那次)。
        if let onboarding = read("OnboardingView.swift") {
            let unpairCalls = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .filter { $0.contains("BrowserPairing.unpair(") }
                .count
            expectEqual(unpairCalls, 1,
                        "引导页只删一个: BrowserPairing.unpair( 在引导页只该有一处调用(每张卡自己那次);批量删配对属于设置页那种能逐个确认的粒度")

            // ⑥ 浏览器候选必须**一份稳定列表**渲染,不准再按"已配对/未配对"分两组 —— 分组时
            //    点一下会让那张卡从一组跳到另一组、在网格里换位置(用户原话「点了以后图标会
            //    切换位置」),而"位置变了 + 边框变了"混在一起读不出"我刚取消了它"。
            expectEqual(onboarding.contains("BrowserPairing.candidateBrowsers("), true,
                        "引导页不换位: 浏览器网格要铺 candidateBrowsers(一份稳定列表),不按已配对/未配对分两组")
            let splitGroups = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .filter { $0.contains("BrowserPairing.addableBrowsers(")
                            || $0.contains("BrowserPairing.pairedBrowsers(") }
            expectEqual(splitGroups, [],
                        "引导页不换位: 引导页不该用 addableBrowsers/pairedBrowsers 分组渲染(那是「点一下换位置」的来源),用 candidateBrowsers + 每张卡现读 isPaired")
        } else {
            expectEqual(true, false, "引导页不换位: 读不到 OnboardingView.swift(路径挪了?)")
        }

        // ⑦ **不准再写 `steps[step]`** —— 那是一处真的会崩的越界(2026-09-03 修)。
        //
        // 原来的论证是"能让 steps 变短的控件全都在 index 1,所以安全",而它默认"引导页是
        // 唯一宿主":`features.players` 是 @Published,设置窗口能同时开着改它,引导页自己的
        // `.lastfm` 那一步还有个按钮专门去打开设置窗。走到最后一步再去设置里取消勾选
        // Apple Music,`steps` 少一项 → `steps[count]` 数组越界。守卫是 `currentStep`
        // (夹住下标)+ `.onChange(of: steps.count)`(把存储值本身拉回来)那一对。
        if let onboarding = read("OnboardingView.swift") {
            let rawIndexing = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { _, raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && !line.hasPrefix("///")
                        && line.contains("steps[step]")
                }
                .map { "OnboardingView.swift:\($0.offset + 1)" }
            expectEqual(rawIndexing, [],
                        "引导页不越界: 不准直接写 steps[step](设置窗口能同时改 features.players 让 steps 变短),用 currentStep")
            expectEqual(onboarding.contains("private var currentStep: Step"), true,
                        "引导页不越界: currentStep 这个夹住下标的访问器不见了")
            expectEqual(onboarding.contains(".onChange(of: steps.count)"), true,
                        "引导页不越界: 少了把 step 存储值拉回合法区间的 onChange(of: steps.count)")

            // ⑧ Apple Music 自动化那一步的判据必须**同时**认 .appleMusic 和 .auto。
            //    `refinedAppleMusicSnapshotIfNeeded` 只看在播的是不是 Music.app、完全不看
            //    features.players,而 players 的默认值恰恰是 [.auto] —— 漏掉 .auto 等于让
            //    "保持默认、平时听 Apple Music"的人永远不被问这个权限。
            expectEqual(onboarding.contains("features.players.contains(.appleMusic) || features.players.contains(.auto)"), true,
                        "引导页权限判据: needsAppleMusicAutomation 必须同时认 .appleMusic 和 .auto(默认就是 [.auto])")

            // ⑨ 「下一步」那道锁**不准再把 automation 关进去**。基础歌词来自 media-control
            //    通道,这个权限管的是进度精度和播放控制 —— 没有它歌词照样显示,多选之后更
            //    是"只对其中一个播放器有意义的权限挡住所有人"。诚实报告的活交给 doneStep
            //    的体检清单(见 ⑪)。
            let lockLines = onboarding.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .filter { $0.contains("nextIsLocked") && $0.contains("automation") }
            expectEqual(lockLines, [],
                        "引导页不硬锁权限: automation 不该回到 nextIsLocked 里(没有它歌词照样显示,病根在 doneStep 撒谎、不在按钮不够严)")

            // ⑩ **后台服务没起来就不算走完引导**。`hasCompletedOnboarding` 一置真这扇窗口
            //    再也不会自动出现,而它是把 collector 装起来的主要入口(15 章记的那条不可
            //    自愈死路)。同日新增的「暂时跳过」给那条死路开了新的到达方式,所以 finish()
            //    必须挡着。
            expectEqual(onboarding.contains("if collectorRunning {\n            settings.hasCompletedOnboarding = true"), true,
                        "引导页不留死路: finish() 里 hasCompletedOnboarding 必须被 collectorRunning 守着(服务没装+引导标记完成=桌面永久停在「搜索歌词中…」)")

            // ⑪ 最后一步必须是**体检清单**,不是无条件一句"一切就绪"。
            expectEqual(onboarding.contains("private var readinessItems: [ReadinessItem]"), true,
                        "引导页要体检: doneStep 的清单(readinessItems)不见了 —— 那是 automation 解锁之后唯一如实报告缺什么的地方")

            // ⑫ 引导页的「配对浏览器」必须有"自己挑一个"的出口。只铺 knownBrowserBundleIDs
            //    的话,Brave / Vivaldi / Opera / Arc 用户在引导里完全走不通。
            expectEqual(onboarding.contains("BrowserPairing.chooseFromApplications("), true,
                        "引导页配对有出口: 少了「从应用程序中选择…」,默认名单只有 Chrome/Edge/Safari 三个")
        }

        // ⑬ 首启那个"⌘+拖拽可以挪位置"的一次性气泡,必须等引导走完再弹。
        //    时间线:T+0.5s 弹引导窗口、T+1.5s 弹气泡、T+9.5s 它自动消失 —— 而"决定要展示"
        //    这一刻就把标记置真了,于是这个一辈子只出现一次的提示,恰好在用户盯着引导读第一
        //    屏的时候在旁边闪 8 秒然后永久消失。
        if let statusItem = read("MenuBar/MenuBarStatusItem.swift") {
            let gate = statusItem.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .contains { $0.contains("AppSettings.shared.hasCompletedOnboarding") }
            expectEqual(gate, true,
                        "菜单栏位置提示不抢引导: hasShownMenuBarPositionHint 那个分支要同时判 hasCompletedOnboarding,否则一次性提示会被引导窗口盖掉并烧掉标记")
        } else {
            expectEqual(true, false, "菜单栏位置提示不抢引导: 读不到 MenuBarStatusItem.swift(路径挪了?)")
        }

        // ⑭ **`lyrics_tr_source` 的哨兵字符串必须跟 collector 逐字节一致**(2026-09-03)。
        //
        // Swift 侧 `LyricsTranslationSource.machineSentinel` 和 Go 侧 translate.go 的
        // `lyricsTrSourceMachine` 之间**没有任何编译期耦合**。哪天 Go 那边把它改成
        // "auto"/"mt"/别的,Swift 这边不会报错,只会**静默**把所有机翻译文重新算成社区译文:
        // 设置页统计面板的两个数字对调、歌词管理里那枚紫色徽章集体变绿,没有任何东西会红。
        // 这条闸直接去扫 Go 源码对账 —— 跟「缓存 key 与 collector 逐字节一致」那组同源。
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/lyrimuse-selftest
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // lyrimuse
            .deletingLastPathComponent()   // 仓库根
        let translateGoPath = repoRoot.appendingPathComponent("lyrimuse-collector/translate.go").path
        if let goSource = try? String(contentsOfFile: translateGoPath, encoding: .utf8) {
            // 形如:  const lyricsTrSourceMachine = "machine"
            let goSentinel = goSource
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("const lyricsTrSourceMachine") }
                .flatMap { line -> String? in
                    guard let open = line.firstIndex(of: "\""),
                          let close = line.lastIndex(of: "\""), open < close else { return nil }
                    return String(line[line.index(after: open)..<close])
                }
            expectEqual(goSentinel, LyricsTranslationSource.machineSentinel,
                        "译文来源哨兵: collector translate.go 的 lyricsTrSourceMachine 必须逐字节等于 Swift 的 LyricsTranslationSource.machineSentinel(改一边不改另一边会静默把机翻全算成社区译文)")
        } else {
            expectEqual(true, false, "译文来源哨兵: 读不到 lyrimuse-collector/translate.go(路径挪了?)")
        }

        // ⑮ **整行罗马音的判定阶梯只允许有一份**(2026-09-03)。
        //
        // 播放引擎的客户端兜底和 collector 的 `lyrics-romanize` 预生成都要决定"这一行走
        // 日语形态分析还是 ICU 音译",两边必须**同一个函数**(`Romanizer.lineReading`)。
        // 各写一份的话,同一首歌"装了缓存"和"现算"读音可能不一样 —— 而这种不一致**不报错**,
        // 只表现成用户偶尔觉得"某句罗马音怎么变了"。
        let coreLyrics = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LyrimuseCore/Lyrics")
        func readCore(_ name: String) -> String? {
            try? String(contentsOfFile: coreLyrics.appendingPathComponent(name).path, encoding: .utf8)
        }
        if let engine = readCore("LyricsSyncEngine.swift") {
            expectEqual(engine.contains("Romanizer.lineReading("), true,
                        "罗马音阶梯一份: LyricsSyncEngine 要走 Romanizer.lineReading(别把阶梯抄回来)")
            let inlined = engine.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { _, raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && !line.hasPrefix("///")
                        && line.contains("Romanizer.readingFromSegments(")
                }
                .map { "LyricsSyncEngine.swift:\($0.offset + 1)" }
            expectEqual(inlined, [],
                        "罗马音阶梯一份: 引擎里又出现了 readingFromSegments 直调 —— 那是阶梯被抄回来的形状,走 Romanizer.lineReading")
        } else {
            expectEqual(true, false, "罗马音阶梯一份: 读不到 LyricsSyncEngine.swift(路径挪了?)")
        }
        if let helper = try? String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lyrics-romanize/main.swift").path, encoding: .utf8) {
            expectEqual(helper.contains("LyricsRomanization.romanizeLRC("), true,
                        "罗马音阶梯一份: helper 要走 LyricsRomanization.romanizeLRC,不准自己拼一套")
        } else {
            expectEqual(true, false, "罗马音阶梯一份: 读不到 Sources/lyrics-romanize/main.swift")
        }
        if let romanization = readCore("LyricsRomanization.swift") {
            expectEqual(romanization.contains("Romanizer.lineReading("), true,
                        "罗马音阶梯一份: LyricsRomanization 要走 Romanizer.lineReading")
        } else {
            expectEqual(true, false, "罗马音阶梯一份: 读不到 LyricsRomanization.swift")
        }
    }

    // ---- 署名过滤的「轮次计数」必须跟条目对齐(2026-09-03)----
    //
    // docs/features/08-lyrics-engine.md 里有两处**各自手工维护**的同一个数:一条条
    // 「第 N 轮」的条目,和「设计决策」那节「枚举法收敛不了(至今补到第 N 轮)」里的计数。
    // 加规则的人常常只补条目、忘了抬计数 —— 2026-09-03 实测:第十五轮记得抬,紧接着另一个
    // session 加第十六轮时就漏了。漏了什么都不报,只是让下一个读文档的人拿到一个偏小的数,
    // 从而低估这套规则的枚举成本 —— 而"枚举法收敛不了"正是这一节要传达的结论本身。
    //
    // 顺带钉住条目编号**连续且不重复**:这份文档同时有多个 session 在改(第十五轮和第十六轮
    // 就来自两个不同 session),两边各写一条「第十七轮」而互不知道是真实存在的撞车形态。
    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/lyrimuse-selftest
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // lyrimuse(包目录)
            .deletingLastPathComponent()   // 仓库根
        let docPath = repoRoot.appendingPathComponent("docs/features/08-lyrics-engine.md").path
        /// 「十六」→ 16。只覆盖 1…99 的写法(一位数 / 十 / 十X / X十 / X十Y),不够用时返回 nil 而不是瞎猜。
        func chineseNumeral(_ s: String) -> Int? {
            let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                                            "六": 6, "七": 7, "八": 8, "九": 9]
            let chars = Array(s)
            guard !chars.isEmpty, chars.count <= 3 else { return nil }
            guard let tenIdx = chars.firstIndex(of: "十") else {
                guard chars.count == 1, let v = digits[chars[0]] else { return nil }
                return v
            }
            let high = chars[..<tenIdx], low = chars[(tenIdx + 1)...]
            var value = 0
            if high.isEmpty {
                value = 10
            } else if high.count == 1, let v = digits[high[high.startIndex]] {
                value = v * 10
            } else {
                return nil
            }
            if low.isEmpty { return value }
            guard low.count == 1, let v = digits[low[low.startIndex]] else { return nil }
            return value + v
        }
        /// 扫出文本里 `<prefix>第…轮` 的那个数,按出现顺序。
        func rounds(in text: String, prefix: String) -> [Int] {
            var out: [Int] = []
            var rest = Substring(text)
            while let hit = rest.range(of: prefix + "第") {
                let tail = rest[hit.upperBound...]
                if let close = tail.firstIndex(of: "轮"),
                   let v = chineseNumeral(String(tail[tail.startIndex..<close])) {
                    out.append(v)
                }
                rest = rest[hit.upperBound...]
            }
            return out
        }
        if let doc = try? String(contentsOfFile: docPath, encoding: .utf8) {
            // 每个条目行只取**第一个**「第 N 轮」:条目正文里常回指别的轮次(「跟第十三轮同源」),
            // 全收会把回指也算成条目、连带把连续性判据搞乱。
            let entryRounds: [Int] = doc.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { $0.hasPrefix("- **第") }
                .compactMap { rounds(in: $0, prefix: "").first }
            expectNotEqual(entryRounds.count, 0,
                           "署名轮次: 扫到了「- **第 N 轮」条目(一条都没扫到 = 文档格式变了、这道闸自己失效了)")
            let counters = rounds(in: doc, prefix: "至今补到")
            expectEqual(counters.count, 1,
                        "署名轮次: 「至今补到第 N 轮」这句计数应当有且只有一处")
            expectEqual(counters.first, entryRounds.max(),
                        "署名轮次: 「至今补到第 N 轮」的计数必须等于最后一条「第 N 轮」条目的编号 —— 加了条目忘抬计数")
            let expectedRun = Array(stride(from: entryRounds.min() ?? 0, through: entryRounds.max() ?? 0, by: 1))
            expectEqual(entryRounds, expectedRun,
                        "署名轮次: 条目编号要连续不重复 —— 重号 = 两个 session 各加了一轮却互不知道")
        } else {
            expectEqual(true, false, "署名轮次: 读不到 docs/features/08-lyrics-engine.md(路径挪了?)")
        }
    }

    // ---- 使用与版权说明 / 第三方许可(2026-09-03)----
    //
    // 说明正文只在 README 维护(中英各一节),App 里两处入口(设置「关于」页两行、引导欢迎页一句)都只是
    // 链接;THIRD_PARTY_LICENSES 随包分发,「第三方许可」那一行打开的是包里那份。钉四件事:
    // ① 链接按语言指对文件和锚点;② README 里那两个标题还在 —— 改标题 = GitHub 锚点变 = 链接静默失效
    // (页面照常打开,只是不跳到那一节,肉眼看不出);③ 两处入口都走 LegalNotices,不准各自拼 URL;
    // ④ build.sh 还在把 THIRD_PARTY_LICENSES 拷进包、CI 还在跑声明覆盖检查。
    do {
        let en = LegalNoticeLinks.usageNoticeURL(language: "en")
        expectEqual(en.absoluteString, "https://github.com/Yudaotor/lyrimuse/blob/main/README.md#license-and-copyright",
                    "版权说明: 英文界面开英文 README 的 License and Copyright 一节")
        let hans = LegalNoticeLinks.usageNoticeURL(language: "zh-hans")
        expectEqual(hans.absoluteString,
                    "https://github.com/Yudaotor/lyrimuse/blob/main/README.zh-CN.md#%E8%AE%B8%E5%8F%AF%E4%B8%8E%E7%89%88%E6%9D%83%E8%AF%B4%E6%98%8E",
                    "版权说明: 简体界面开中文 README 的「许可与版权说明」,锚点百分号编码")
        expectEqual(LegalNoticeLinks.usageNoticeURL(language: "zh-hant"), hans, "版权说明: 繁体界面跟简体开同一份中文 README")
        expectEqual(LegalNoticeLinks.usageNoticeURL(language: "system"), en, "版权说明: 认不出的取值当英文")
        expectEqual(LegalNoticeLinks.thirdPartyLicensesOnGitHub.absoluteString,
                    "https://github.com/Yudaotor/lyrimuse/blob/main/THIRD_PARTY_LICENSES", "版权说明: 第三方许可的 GitHub 兜底指向仓库根那份")

        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // …/lyrimuse(包目录)
        let repoRoot = packageDir.deletingLastPathComponent()
        func read(_ url: URL) -> String? { try? String(contentsOfFile: url.path, encoding: .utf8) }
        func codeLines(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
        }
        if let readme = read(repoRoot.appendingPathComponent("README.md")) {
            expectEqual(readme.contains("\n## License and Copyright\n"), true,
                        "版权说明: README.md 要有「## License and Copyright」—— 锚点 license-and-copyright 由它生成")
        } else {
            expectEqual(true, false, "版权说明: 读不到 README.md(路径挪了?)")
        }
        if let readme = read(repoRoot.appendingPathComponent("README.zh-CN.md")) {
            expectEqual(readme.contains("\n## 许可与版权说明\n"), true,
                        "版权说明: README.zh-CN.md 要有「## 许可与版权说明」—— 中文锚点由它生成")
        } else {
            expectEqual(true, false, "版权说明: 读不到 README.zh-CN.md(路径挪了?)")
        }
        let appSources = packageDir.appendingPathComponent("Sources/lyrimuse")
        if let settings = read(appSources.appendingPathComponent("SettingsView.swift")) {
            let code = codeLines(settings)
            expectEqual(code.contains { $0.contains("LegalNotices.openUsageNotice()") }, true,
                        "版权说明: 关于页要有「使用与版权说明」入口且走 LegalNotices")
            expectEqual(code.contains { $0.contains("LegalNotices.openThirdPartyLicenses()") }, true,
                        "版权说明: 关于页要有「第三方许可」入口且走 LegalNotices")
            expectEqual(code.contains { $0.contains("README.zh-CN.md") || $0.contains("license-and-copyright") }, false,
                        "版权说明: 设置页不准自己拼 README 链接,走 LegalNoticeLinks")
        } else {
            expectEqual(true, false, "版权说明: 读不到 SettingsView.swift(路径挪了?)")
        }
        if let onboarding = read(appSources.appendingPathComponent("OnboardingView.swift")) {
            let code = codeLines(onboarding)
            expectEqual(code.contains { $0.contains("LegalNotices.openUsageNotice()") }, true,
                        "版权说明: 引导欢迎页要有那句告知且走 LegalNotices")
            expectEqual(code.contains { $0.contains("README.zh-CN.md") || $0.contains("license-and-copyright") }, false,
                        "版权说明: 引导页不准自己拼 README 链接,走 LegalNoticeLinks")
        } else {
            expectEqual(true, false, "版权说明: 读不到 OnboardingView.swift(路径挪了?)")
        }
        if let buildScript = read(packageDir.appendingPathComponent("build.sh")) {
            let copies = buildScript.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .contains { $0.hasPrefix("cp ") && $0.contains("THIRD_PARTY_LICENSES") && $0.contains("Contents/Resources") }
            expectEqual(copies, true, "版权说明: build.sh 要把 THIRD_PARTY_LICENSES 拷进 Contents/Resources —— 「第三方许可」打开的是这份")
        } else {
            expectEqual(true, false, "版权说明: 读不到 build.sh(路径挪了?)")
        }
        if let ci = read(repoRoot.appendingPathComponent(".github/workflows/ci.yml")) {
            expectEqual(ci.contains("scripts/check_third_party_licenses.py"), true, "版权说明: CI 要跑第三方声明覆盖检查")
        } else {
            expectEqual(true, false, "版权说明: 读不到 .github/workflows/ci.yml(路径挪了?)")
        }
    }

    // ---- 设置页:跨进程调用不许出现在 view body 里(2026-09-03) ----
    //
    // 真机 `sample` 抓栈坐实的卡顿(用户报「设置页切分页有延迟、不跟手」):「播放器」页的
    // body 里直接调了 `MusicAutomationPermission.check`(底下是 AEDeterminePermissionToAutomateTarget
    // → semaphore_wait_trap,跨进程问 tccd,独立脚本实测单次 3–48ms)、`BrowserAutomationPermission
    // .status`(读 Chromium Preferences 文件)、`CollectorServiceManager.state`(起 launchctl 子进程
    // 并 waitUntilExit)。4 个浏览器 × 每次 body 重算 → 主线程一次阻塞 20–380ms;60 秒切分页采样
    // 主线程 70% 在忙、其中 `browserAvatarButton` 一条路径 524 个采样。PlayerHealthMonitor 同款。
    //
    // 修法是"查在后台、画只读缓存"。这条闸钉住的不是"别调这些函数",而是**只能在这几个
    // refresh 函数里、而且必须包在 Task.detached 里调**——别人以后顺手在某个 card 的 body 里
    // 再写一句 `MusicAutomationPermission.check(...)`,这里当场红,而不是等用户再报一次"卡"。
    // 判定是纯文本的:找到调用行往上最近的 `func X`,X 必须在白名单里,且从那行 func 到调用行
    // 之间要出现过 `Task.detached`。注释行(// 或 ///)不算调用。
    do {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/lyrimuse-selftest
            .deletingLastPathComponent()   // Sources
        let ipcCalls = ["MusicAutomationPermission.check(", "BrowserAutomationPermission.status(",
                        "CollectorServiceManager.state", "CollectorServiceManager.isRunning"]
        let allow: [(file: String, funcs: Set<String>)] = [
            ("lyrimuse/SettingsView.swift", ["refreshBrowserLiveStatus", "refreshAutomationStatus", "refreshCollectorState"]),
            ("lyrimuse/Settings/PlayerHealthMonitor.swift", ["refresh"]),
        ]
        for entry in allow {
            let path = sourcesDir.appendingPathComponent(entry.file).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                expectEqual(true, false, "设置页 IPC 闸: 读不到 \(entry.file)(路径挪了?)")
                continue
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var offenders: [String] = []
            var checked = 0
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                guard ipcCalls.contains(where: { line.contains($0) }) else { continue }
                checked += 1
                // 往上找最近的 func 声明
                var funcName = "<无所属函数>"
                var funcLine = 0
                for j in stride(from: i, through: 0, by: -1) {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if let r = t.range(of: "func ") , !t.hasPrefix("//") {
                        let after = t[r.upperBound...]
                        funcName = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                        funcLine = j
                        break
                    }
                }
                let between = lines[funcLine...i].joined(separator: "\n")
                let inAllowedFunc = entry.funcs.contains(funcName)
                let detached = between.contains("Task.detached")
                if !(inAllowedFunc && detached) {
                    offenders.append("\(entry.file):\(i + 1) 在 \(funcName)()\(detached ? "" : "、且不在 Task.detached 里"): \(line.prefix(80))")
                }
            }
            expectEqual(checked > 0, true, "设置页 IPC 闸: \(entry.file) 里扫到了跨进程调用(扫不到 = 名字变了,先修这条闸)")
            expectEqual(offenders, [], "设置页 IPC 闸: 跨进程调用(AE 权限查询 / 读浏览器配置文件 / launchctl)只许在后台 refresh 函数的 Task.detached 里,别写进 view body(会同步阻塞主线程几十到几百毫秒)")
        }
    }

    // ---- 「重置」必须覆盖它那个形态的每一个默认值常量(2026-09-03) ----
    //
    // 2026-09-03 一天之内在同一类疏漏上栽了三次:菜单栏「重置」漏了「歌词旁的图标」和
    // 「悬停显示播放控制」、灵动岛「重置」漏了两个自动隐藏开关(都是设置项加进浮层时没同步
    // restoreDefaults())、灵动岛和菜单栏的「全部设置」抽屉各漏了一行「重置」兜底入口。
    // 这类漏**不会报错**,表现只是"点了重置有一项没变",用户很难判断是漏了还是本来就不该变。
    //
    // 可机械检查的规律:仓库纪律本来就是"进重置范围的项必须有 `AppSettings.defaultXxx` 命名
    // 常量"(init() 的兜底和重置按钮读同一份,不各自硬编码);反过来 —— **有常量就该在重置里**。
    //
    // ⚠️ 只覆盖 Notch / MenuBar 两族。悬浮歌词那边的常量不带形态前缀(defaultFollowsCoverArt /
    // defaultFontFamilyName / defaultFontSize / defaultOverlayFontWeight),而且它有几项默认值
    // 来自 `ColorTheme.defaultTheme` 而不是常量,按名字归类只能靠猜 —— 与其写一条似是而非的
    // 闸,不如只钉住规律确实成立的那两族。
    //
    // ⚠️ 扫的是 **restoreDefaults() 的函数体**(靠大括号配平截出来)、并且**剔掉注释行**,不是
    // 整文件扫。那两个文件的注释里都写着"默认值只在 AppSettings.defaultMenuBarXxx 里出现一次"
    // 这类句子,整文件扫会把注释当成赋值放过去 —— 这个仓库的源码扫描守卫已经吃过好几次
    // "纯文本扫描不区分代码与注释"的亏(本地化那条、滑杆那条的头注都记着)。
    do {
        let sourcesDir = URL(fileURLWithPath: #filePath)    // …/Sources/lyrimuse-selftest/SourceContractTests.swift
            .deletingLastPathComponent()                    // …/Sources/lyrimuse-selftest
            .deletingLastPathComponent()                    // …/Sources

        /// 把某个文件里 `static func restoreDefaults()` 的函数体抠出来(去掉整行注释)。
        func restoreDefaultsBody(_ relativePath: String) -> String? {
            let path = sourcesDir.appendingPathComponent(relativePath).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let start = text.range(of: "static func restoreDefaults() {") else { return nil }
            var depth = 0
            var body = ""
            for ch in text[start.lowerBound...] {
                body.append(ch)
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            return body.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        let settingsPath = sourcesDir.appendingPathComponent("lyrimuse/Settings/AppSettings.swift").path
        if let settings = try? String(contentsOfFile: settingsPath, encoding: .utf8),
           let notchBody = restoreDefaultsBody("lyrimuse/UI/NotchEditorStage.swift"),
           let menuBarBody = restoreDefaultsBody("lyrimuse/UI/MenuBarEditorStage.swift") {
            var notchConsts: [String] = []
            var menuBarConsts: [String] = []
            for m in settings.matches(of: #/static let (default(?:Notch|MenuBar)\w+)/#) {
                let name = String(m.1)
                if name.hasPrefix("defaultNotch") { notchConsts.append(name) } else { menuBarConsts.append(name) }
            }
            // 一个都没扫到 = 命名规范变了或正则失效,守卫自身失效必须看得见(同其它几条)。
            expectEqual(notchConsts.isEmpty || menuBarConsts.isEmpty, false,
                        "重置覆盖闸: 扫到了两族默认值常量(灵动岛 \(notchConsts.count) 个 / 菜单栏 \(menuBarConsts.count) 个)")

            // 明确豁免名单。**目前为空**:2026-09-03 实测 30 个常量 0 例外。
            // 将来真有一项"有常量但故意不进重置"时加到这里,并在旁边写清楚理由 ——
            // 空着比写一条含糊的例外更有价值,它逼着下一个人去想清楚。
            let exempt: Set<String> = []

            expectEqual(notchConsts.filter { !exempt.contains($0) && !notchBody.contains("AppSettings.\($0)") }.sorted(), [],
                        "重置覆盖闸: 灵动岛的默认值常量都在 NotchStyleDefaults.restoreDefaults() 里被赋值(漏了不报错,只表现为'点了重置有一项没变')")
            expectEqual(menuBarConsts.filter { !exempt.contains($0) && !menuBarBody.contains("AppSettings.\($0)") }.sorted(), [],
                        "重置覆盖闸: 菜单栏的默认值常量都在 MenuBarStyleDefaults.restoreDefaults() 里被赋值")
        } else {
            expectEqual(true, false,
                        "重置覆盖闸: 读不到 AppSettings.swift / NotchEditorStage.swift / MenuBarEditorStage.swift,或里面找不到 restoreDefaults()(文件挪了或函数改名了?)")
        }
    }

    // ---- 三个形态的「全部设置」抽屉都必须有「重置」兜底入口(2026-09-03) ----
    //
    // 抽屉的定位是**键盘 / VoiceOver 的全量兜底通路**,而工具栏那颗「重置 ▾」是 SwiftUI `Menu`。
    // 悬浮歌词一直在抽屉里放着一行 `resetRow`,灵动岛和菜单栏都漏了(2026-09-03 三形态设置审计
    // 发现,当天补齐)。这条闸钉住三个都在。
    do {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // 抽屉分别住在这三个文件里(灵动岛那个内嵌在 SettingsView.swift)。
        let drawers = [
            ("悬浮歌词", "lyrimuse/UI/OverlayAllSettingsDrawer.swift"),
            ("灵动岛", "lyrimuse/SettingsView.swift"),
            ("菜单栏", "lyrimuse/UI/MenuBarEditorStage.swift"),
        ]
        var missing: [String] = []
        var unreadable: [String] = []
        for (surface, rel) in drawers {
            let path = sourcesDir.appendingPathComponent(rel).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                unreadable.append(surface)
                continue
            }
            // 要求同时有**定义**和**装配**:只定义不装配等于没有。
            let defined = text.contains("private var resetRow: some View")
            // 装配点:抽屉 body 里单独一行 `resetRow`(前面是缩进,后面直接换行)。
            let mounted = text.contains("\n                resetRow\n")
            if !(defined && mounted) { missing.append("\(surface)(定义=\(defined) 装配=\(mounted))") }
        }
        expectEqual(unreadable, [], "抽屉重置闸: 三个抽屉的宿主文件都读得到(读不到 = 路径挪了)")
        expectEqual(missing, [],
                    "抽屉重置闸: 三个形态的「全部设置」抽屉都要有 resetRow —— 抽屉是键盘/VoiceOver 的全量兜底通路,工具栏那颗 Menu 不能算数")
    }

    // ---- 液态玻璃门控(2026-09-03,AGENTS.md「分层边界」成文的那条)----
    //
    // 部署目标 macOS 14、CI 跑 macos-26:没 #available 门控的 .glassEffect / .glass / GlassEffectContainer
    // 在 CI 编得过、在用户机器上启动即崩,编译器不会替你拦。规则是玻璃只经 SettingsDesignSystem 的入口
    // (展示面自己套时同样门控,现有唯一例外 LyricsOverlayView),这里把它做成机械闸:扫 App target 全部
    // 源文件的**非注释行**,这些 API 的调用点只允许出现在白名单文件里,且用到的文件必须含那句 #available。
    // 文本级检查,不是类型级:它拦的是"新开一个文件直接写玻璃"这种最常见的漏法,不是所有漏法。
    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        let glassAPIs = ["glassEffect(", "glassEffectID(", "glassEffectTransition(", "glassEffectUnion(",
                         "GlassEffectContainer(", ".glassProminent", "buttonStyle(.glass)"]
        let allowed: Set<String> = ["Settings/SettingsDesignSystem.swift", "UI/LyricsOverlayView.swift"]
        var offenders: [String] = []
        var filesUsingGlass: Set<String> = []
        var missingGate: [String] = []
        var scanned = 0
        if let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                let rel = url.path.replacingOccurrences(of: appSources.path + "/", with: "")
                var uses = false
                for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("//") { continue }
                    guard glassAPIs.contains(where: { line.contains($0) }) else { continue }
                    uses = true
                    if !allowed.contains(rel) { offenders.append("\(rel):\(index + 1)") }
                }
                if uses {
                    filesUsingGlass.insert(rel)
                    if !text.contains("#available(macOS 26.0, *)") { missingGate.append(rel) }
                }
            }
        }
        expectEqual(scanned > 50, true, "玻璃门控: 扫到了 App target 的源文件(守卫自身没跑空)")
        expectEqual(offenders.sorted(), [],
                    "玻璃门控: 液态玻璃 API 只准出现在 SettingsDesignSystem / LyricsOverlayView 里,别处走设计系统的入口(AGENTS.md「分层边界」)")
        expectEqual(missingGate.sorted(), [],
                    "玻璃门控: 用了 macOS 26 API 的文件必须有 #available(macOS 26.0, *) —— CI 在 macos-26 上编得过,用户的 macOS 14 上会崩")
        expectEqual(filesUsingGlass.contains("Settings/SettingsDesignSystem.swift"), true,
                    "玻璃门控: 设计系统那份入口还在(没扫到说明扫描本身失效了)")
        if let designSystem = try? String(contentsOf: appSources.appendingPathComponent("Settings/SettingsDesignSystem.swift"), encoding: .utf8) {
            for entry in ["func settingsCardBackground(", "func settingsGlassButtons(", "func settingsProminentGlassButton(",
                          "func clearGlassCapsule(", "struct SettingsGlassContainer"] {
                expectEqual(designSystem.contains(entry), true, "玻璃门控: AGENTS.md 点名的入口 \(entry) 还在设计系统里")
            }
        } else {
            expectEqual(true, false, "玻璃门控: 读不到 SettingsDesignSystem.swift(路径挪了?)")
        }

        // ⑯ **「开机启动」这个开关只准写/删 plist,不准起任何进程**(2026-09-03,同一个
        //    「点一下就闪退」修了三次才收口)。
        //
        // 两个方向各有一个坑,而且**都不产生 crash report**,极难查:
        //   · 关:`launchctl bootout gui/<uid>/me.yudaotor.lyrimuse` —— App 本身就是那个
        //     job(build.sh 装完走 bootstrap+kickstart,开机自启同理),等于让 launchd 给
        //     自己发一记 SIGTERM(日志里是 signal(2) SIGTERM(15))。
        //   · 开:`launchctl bootstrap` + plist 里的 RunAtLoad=true —— 当场再起一个
        //     lyrimuse,老进程让位退出(日志里是 `Process exited: voluntary`,新进程在
        //     **同一秒**启动)。
        //
        // 两者都不必要:plist 落在 ~/Library/LaunchAgents,launchd **下次登录**自己加载它,
        // 那就是这个开关承诺的全部内容。所以这条闸直接禁掉整类写法 —— 这个文件里不准出现
        // launchctl,也不准起子进程。
        if let loginItem = try? String(
            contentsOf: appSources.appendingPathComponent("Settings/LoginItemManager.swift"),
            encoding: .utf8) {
            let offenders = loginItem.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { _, raw in
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    guard !line.hasPrefix("//"), !line.hasPrefix("///") else { return false }
                    return line.contains("launchctl") || line.contains("Process()")
                }
                .map { "LoginItemManager.swift:\($0.offset + 1)" }
            expectEqual(offenders, [],
                        "开关不起进程: LoginItemManager 只准写/删 plist —— 出现 launchctl 或起子进程,就是「点一下开机启动就闪退」那个 bug 的形状")
        } else {
            expectEqual(true, false, "开关不起进程: 读不到 LoginItemManager.swift(路径挪了?)")
        }
    }

    // ---- 退出原因日志(2026-09-03,AGENTS.md「容易踩的具体坑 → 退出路径」)----
    //
    // 两侧的退出路径都要打 `exiting reason=<code>`:App 侧所有主动 terminate 只准经 AppExit.request
    // (applicationShouldTerminate 兜底、SIGTERM 由 AppExit 接住),collector 常驻路径(main.go)不准再出现裸
    // os.Exit / log.Fatalf,一律走 exitreason.go 的 logExit / fatalExit。纯文本扫描:它拦的是"新加一条退出
    // 路径忘了打日志"这种最常见的漏法。
    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appSources = packageDir.appendingPathComponent("Sources/lyrimuse")
        let repoRoot = packageDir.deletingLastPathComponent()
        func codeLines(_ text: String) -> [(Int, String)] {
            text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                return line.hasPrefix("//") ? nil : (index + 1, line)
            }
        }
        // ① App:terminate 调用点只准在 AppExit.swift 里。
        var offenders: [String] = []
        var scanned = 0
        if let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                let rel = url.path.replacingOccurrences(of: appSources.path + "/", with: "")
                if rel == "AppExit.swift" { continue }
                for (lineNo, line) in codeLines(text)
                where line.contains("NSApp.terminate(") || line.contains("NSApplication.shared.terminate(") {
                    offenders.append("\(rel):\(lineNo)")
                }
            }
        }
        expectEqual(scanned > 50, true, "退出原因: 扫到了 App target 的源文件(守卫自身没跑空)")
        expectEqual(offenders.sorted(), [], "退出原因: App 里主动 terminate 只准经 AppExit.request,别处直接 terminate 不会留下 exiting reason= 日志")
        if let appExit = try? String(contentsOf: appSources.appendingPathComponent("AppExit.swift"), encoding: .utf8) {
            expectEqual(appExit.contains("exiting reason="), true, "退出原因: AppExit 打的是 `exiting reason=` 前缀(collector 同款,grep 契约)")
            expectEqual(appExit.contains("category: \"lifecycle\""), true, "退出原因: 走 lifecycle 分类的 Logger,不走 NSLog")
        } else {
            expectEqual(true, false, "退出原因: 读不到 AppExit.swift(路径挪了?)")
        }
        if let delegate = try? String(contentsOf: appSources.appendingPathComponent("AppDelegate.swift"), encoding: .utf8) {
            let code = codeLines(delegate).map(\.1)
            expectEqual(code.contains { $0.contains("AppExit.logTermination(") }, true, "退出原因: applicationShouldTerminate 要调 AppExit.logTermination 兜底(⌘Q / Dock 退出 / Sparkle 重启都只经这里)")
            expectEqual(code.contains { $0.contains("AppExit.installSigtermHandler()") }, true, "退出原因: 启动时要装 SIGTERM 处理器,否则 kickstart -k 那条路连 delegate 都到不了")
            expectEqual(code.contains { $0.contains("NSLog(") }, false, "退出原因: AppDelegate 里不再有 NSLog(诊断导出按 subsystem 查不到它)")
        } else {
            expectEqual(true, false, "退出原因: 读不到 AppDelegate.swift(路径挪了?)")
        }
        // ② collector:main.go 的常驻路径不准裸 os.Exit / log.Fatalf。
        if let mainGo = try? String(contentsOf: repoRoot.appendingPathComponent("lyrimuse-collector/main.go"), encoding: .utf8) {
            let bare = codeLines(mainGo).filter { $0.1.contains("log.Fatal") }.map { "main.go:\($0.0)" }
            expectEqual(bare, [], "退出原因: collector main.go 不准再用 log.Fatal*,走 exitreason.go 的 fatalExit(reason:)")
            let exits = codeLines(mainGo).filter { $0.1.contains("os.Exit(") }
            expectEqual(exits.count, 1, "退出原因: main.go 里唯一一处 os.Exit 是拿不到单实例锁那条(前面一行 logExit(already_running))")
        } else {
            expectEqual(true, false, "退出原因: 读不到 lyrimuse-collector/main.go(路径挪了?)")
        }
        if let exitReason = try? String(contentsOf: repoRoot.appendingPathComponent("lyrimuse-collector/exitreason.go"), encoding: .utf8) {
            expectEqual(exitReason.contains("\"exiting reason=%s\""), true, "退出原因: collector 前缀与 App 一致")
        } else {
            expectEqual(true, false, "退出原因: 读不到 lyrimuse-collector/exitreason.go(路径挪了?)")
        }
    }

    // ---- features.json 键两侧镜像(2026-09-03)----
    //
    // Swift `FeatureFlagsFile.CodingKeys` 里的每个键,collector features.go 都得有同名 json tag —— App 写了、
    // collector 不认的键会**静默无效**(「跟随播放器启动」改逐播放器那次加的 launch_lyrimuse_on_players 就是
    // 这种键,漏了 Go 侧就是"设置里勾了、collector 照旧盯全部")。反方向不查:collector 自己的诊断键
    // (lyrics_decision_trace)App 不管,靠 unknownFileKeys 原样保留。
    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageDir.deletingLastPathComponent()
        let swiftPath = packageDir.appendingPathComponent("Sources/lyrimuse/Settings/FeatureSettingsStore.swift").path
        let goPath = repoRoot.appendingPathComponent("lyrimuse-collector/features.go").path
        if let swift = try? String(contentsOfFile: swiftPath, encoding: .utf8),
           let go = try? String(contentsOfFile: goPath, encoding: .utf8) {
            var keys: [String] = []
            var inEnum = false
            for raw in swift.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("enum CodingKeys: String, CodingKey, CaseIterable {") { inEnum = true; continue }
                guard inEnum else { continue }
                if line == "}" { break }
                guard line.hasPrefix("case ") else { continue }
                let body = line.dropFirst(5)
                if let eq = body.range(of: " = \"") {
                    keys.append(String(body[eq.upperBound...].dropLast()))
                } else {
                    keys.append(String(body).trimmingCharacters(in: .whitespaces))
                }
            }
            expectEqual(keys.count > 10, true, "features 键镜像: 解析到了 FeatureFlagsFile.CodingKeys(守卫自身没跑空)")
            let missing = keys.filter { !go.contains("json:\"\($0),omitempty\"") && !go.contains("json:\"\($0)\"") }
            expectEqual(missing, [], "features 键镜像: collector features.go 缺这些键的 json tag,App 写了 collector 不认")
        } else {
            expectEqual(true, false, "features 键镜像: 读不到 FeatureSettingsStore.swift 或 features.go(路径挪了?)")
        }
    }

    // ---- 「采纳候选」的三个入口必须同进同出(2026-09-04)----
    //
    // `LyricsSearchSheet` 有三个调用点(歌词管理 / 歌词窗口的 sheet / 悬浮窗 ⚙ 的独立小窗),
    // 每一处的 onApply 都要有同一套分流与参数:纯文本候选走 `savePlainTextEdit`(否则把没有
    // 时间戳的纯文本当 LRC 喂进 saveEdit,这首歌在别的展示面上从"至少有静态文字"退化成"看
    // 起来完全没有歌词"),带时间戳的走 `saveEdit` 且 `markManual` 读 `manualPickLocksLyrics`、
    // `fromManualPick: true`。这个仓库为"改了两处漏第三处"付过两次代价:2026-09-01 补
    // markManual 时漏了歌词窗口那处;2026-09-04 发现小窗那处从 08-30 加纯文本候选起就没有
    // 分流。守卫先数清楚调用点(多一处也要红 —— 新入口必须来这里登记,顺便读一遍上面的规矩),
    // 再逐处查五个记号(2026-09-04 加 currentFingerprint:「当前使用」双判据的正文指纹,三处都得传)。只数非注释行:别处的注释会提到 `LyricsSearchSheet(` 让人去 grep。
    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }
        var callSites: [String] = []
        if let walker = FileManager.default.enumerator(atPath: appSources.path) {
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                guard rel != "LyricsManager/LyricsSearchSheet.swift", let text = read(rel) else { continue }
                let hit = text.split(separator: "\n").contains { raw in
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    return !line.hasPrefix("//") && line.contains("LyricsSearchSheet(")
                }
                if hit { callSites.append(rel) }
            }
        }
        expectEqual(callSites.sorted(),
                    ["LyricsManager/LyricsManagerView.swift", "LyricsManager/LyricsQuickSearchWindow.swift",
                     "UI/LyricsWindowView.swift"],
                    "采纳候选入口: LyricsSearchSheet 的调用点就这三处(多了/少了都要来这条守卫登记)")
        for rel in callSites.sorted() {
            guard let text = read(rel) else { continue }
            for marker in ["isPlainTextOnly", "savePlainTextEdit(", "manualPickLocksLyrics", "fromManualPick: true", "currentFingerprint:"] {
                expectEqual(text.contains(marker), true, "采纳候选入口: \(rel) 缺 \(marker)")
            }
        }
    }

    // ---- 设置页顶层分类记忆(2026-09-04)----
    //
    // 顶层分类的落盘键必须是 `settings:` 前缀:ConfigPortability 只导出 `np:` / `KeyboardShortcuts_`,
    // 界面停留位置是机器状态、不该随备份走 —— 这个前缀正好自然排除。守卫两头:键名前缀没被改掉、
    // 导出过滤没有悄悄把 `settings:` 加进去;再钉住"初值直接读盘"(不在 onAppear 里补跳)和"只在
    // .tab 分支写回"(账号页不记,理由见 SettingsView 那处注释)。纯 App target,只能扫源码文本。
    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }
        if let settings = read("SettingsView.swift") {
            expectEqual(settings.contains("static let lastTabStorageKey = \"settings:lastTab\""), true,
                        "顶层分类记忆: 键名与 settings: 前缀")
            expectEqual(settings.contains("@AppStorage(SettingsTab.lastTabStorageKey)"), true,
                        "顶层分类记忆: @AppStorage 挂常量而不是字面量")
            expectEqual(settings.contains(".tab(SettingsTab.restoredLastTab())"), true,
                        "顶层分类记忆: selection 初值直接读盘,不在 onAppear 里补跳")
            expectEqual(settings.contains("if case .tab(let tab)? = item { lastTabRaw = tab.rawValue }"), true,
                        "顶层分类记忆: 只在 .tab 分支写回,账号页不记")
        } else {
            expectEqual(true, false, "顶层分类记忆: 读不到 SettingsView.swift(路径挪了?)")
        }
        if let portability = read("Settings/ConfigPortability.swift") {
            expectEqual(portability.contains("hasPrefix(\"settings:\")"), false,
                        "顶层分类记忆: settings: 前缀的界面停留位置不该进配置导出")
        } else {
            expectEqual(true, false, "顶层分类记忆: 读不到 Settings/ConfigPortability.swift(路径挪了?)")
        }
    }

    // ---- 菜单栏跟唱滚动(2026-09-04)----
    //
    // 有逐字时间轴的句子滚动跟着正在唱的字走(MenuBarMarquee.followReadingPath / followScrollPath)。
    // 三件容易被"顺手统一"掉的事只能扫源码守:① 阅读位置路径**不看**卡拉OK开关 —— 不染色也要跟着唱到的
    // 位置滚,它跟 karaokeFillPath 长得像但少一道守卫,合并它们就把关着染色的用户退回匀速配速;② 本体和
    // 设置页预览都把 followPath 传给标签(预览复用本体视图,少传一处预览就跟真机不一样);③ 标签把 followPath
    // 当滚动参数比对 —— 开唱那一刻它从 nil 变非 nil 必须装上跟唱动画。
    do {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func read(_ rel: String) -> String? {
            try? String(contentsOfFile: appSources.appendingPathComponent(rel).path, encoding: .utf8)
        }
        /// 取 `marker` 起到下一个四空格缩进的 `}` 为止的函数体。
        func body(of source: String, from marker: String) -> String? {
            guard let start = source.range(of: marker) else { return nil }
            let rest = source[start.lowerBound...]
            guard let end = rest.range(of: "\n    }\n") else { return nil }
            return String(rest[..<end.lowerBound])
        }
        for (file, marker) in [("MenuBar/MenuBarStatusItem.swift", "private func followReadingPath(for text: String)"),
                               ("UI/SectionPreviewBars.swift", "private var followReadingPath:")] {
            guard let source = read(file) else {
                expectEqual(true, false, "跟唱滚动: 读不到 \(file)(路径挪了?)")
                continue
            }
            guard let fn = body(of: source, from: marker) else {
                expectEqual(true, false, "跟唱滚动: \(file) 里找不到 followReadingPath")
                continue
            }
            expectEqual(fn.contains("menuBarLyricsKaraoke"), false,
                        "跟唱滚动: \(file) 的阅读位置路径不看卡拉OK开关")
            expectEqual(fn.contains("MenuBarMarquee.followReadingPath("), true,
                        "跟唱滚动: \(file) 走 Core 的 followReadingPath")
            expectEqual(source.contains("followPath: followReadingPath"), true,
                        "跟唱滚动: \(file) 把 followPath 传给了标签")
        }
        if let label = read("MenuBar/MenuBarScrollingLabel.swift") {
            expectEqual(label.contains("$0.followPath == next.followPath"), true,
                        "跟唱滚动: 标签把 followPath 当滚动参数比对")
            expectEqual(label.contains("MenuBarMarquee.followScrollPath("), true,
                        "跟唱滚动: 标签按自己的格子宽 / 长图宽算偏移路径")
        } else {
            expectEqual(true, false, "跟唱滚动: 读不到 MenuBar/MenuBarScrollingLabel.swift(路径挪了?)")
        }
    }

    // ---- 菜单栏自绘位图的栅格化比例(2026-09-05)----
    //
    // 三样自绘位图(歌词长图 / 进度图标 / 活体图标)都要按**按钮所在窗口**的 backingScaleFactor 栅格化
    // (NSView.menuBarBitmapScale),不许再拿 NSScreen.main(有键盘焦点的屏)猜、也不许写死 2 ——
    // 混接不同 DPI 的显示器时前者按错屏、后者在 1x 屏上白费两倍位图。比例变化靠
    // viewDidChangeBackingProperties / viewDidMoveToWindow 接住重排。纯 AppKit,只能扫源码。
    do {
        let menuBarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/MenuBar")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: menuBarDir.path)) ?? [])
            .filter { $0.hasSuffix(".swift") }.sorted()
        expectEqual(files.isEmpty, false, "位图比例: 找得到 MenuBar 目录")
        var offenders: [String] = []
        let hardcoded = try? NSRegularExpression(pattern: #"contentsScale\s*=\s*[0-9]"#)
        for f in files {
            guard let src = try? String(contentsOfFile: menuBarDir.appendingPathComponent(f).path, encoding: .utf8) else { continue }
            if src.contains("NSScreen.main?.backingScaleFactor") { offenders.append("\(f): NSScreen.main 猜屏") }
            if let hardcoded,
               hardcoded.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)) != nil {
                offenders.append("\(f): contentsScale 写死数字")
            }
        }
        expectEqual(offenders, [], "位图比例: 不许猜 NSScreen.main、不许写死 contentsScale")
        for f in ["MenuBarScrollingLabel.swift", "MenuBarLiveIconView.swift"] {
            let src = (try? String(contentsOfFile: menuBarDir.appendingPathComponent(f).path, encoding: .utf8)) ?? ""
            expectEqual(src.contains("override func viewDidChangeBackingProperties()"), true,
                        "位图比例: \(f) 接住换屏重排")
            expectEqual(src.contains("menuBarBitmapScale"), true, "位图比例: \(f) 用所在窗口的比例")
        }
    }

    // ---- 共享配置文件的读写口径(2026-09-05,借鉴清单 #46)----
    //
    // ConfigStore / FeatureSettingsStore 两份共享 JSON 文件的读盘、合并、写盘必须走 Core 的 JSONConfigDocument
    // (三态:missing / loaded / corrupt,corrupt 拒绝保存;写盘成功后才更新内存)。不许再各自
    // `try? Data(contentsOf:)` + `try? JSONSerialization` 把「文件不存在」和「文件坏了」混成一回事,也不许
    // 绕开文档直接 write —— 那正是 config.json 一个语法错误之后被 14 个空串覆盖的那条路。两个 Store 在
    // app target,selftest 只能扫源码;逻辑本体由 ops-diagnostics 组「配置文件三态读写」钉着。
    do {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse")
        func codeLines(_ rel: String) -> String {
            let src = (try? String(contentsOfFile: appDir.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
            // 只看代码行:两个文件的注释里大段引用了旧写法当反例。
            return src.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        for f in ["Settings/ConfigStore.swift", "Settings/FeatureSettingsStore.swift"] {
            let code = codeLines(f)
            expectEqual(code.isEmpty, false, "配置读写口径: 读得到 \(f)")
            expectEqual(code.contains("JSONConfigDocument.load(url:"), true, "配置读写口径: \(f) 读盘走 JSONConfigDocument")
            expectEqual(code.contains("document.save(fields:"), true, "配置读写口径: \(f) 写盘走 JSONConfigDocument.save")
            expectEqual(code.contains("Data(contentsOf:"), false, "配置读写口径: \(f) 不许自己读盘")
            expectEqual(code.contains(".write(to:"), false, "配置读写口径: \(f) 不许绕开文档直接写盘")
            expectEqual(code.contains("writeSecurely(to:"), false, "配置读写口径: \(f) 不许绕开文档直接写盘(secure)")
            expectEqual(code.contains("var loadFailure: String?"), true, "配置读写口径: \(f) 暴露 loadFailure 给横幅")
            expectEqual(code.contains("catch ConfigFileSaveError.refusedCorruptFile"), true,
                        "配置读写口径: \(f) 的 save() 把「拒绝」和「写失败」分开报")
            expectEqual(code.contains("func discardCorruptFileAndSave()"), true, "配置读写口径: \(f) 提供放弃坏文件的出口")
        }
        let settingsView = codeLines("SettingsView.swift")
        expectEqual(settingsView.contains("ConfigFileDamageBanner()"), true, "配置读写口径: 损坏横幅挂在设置窗口 detail 列")
        let banner = codeLines("Settings/ConfigFileDamageBanner.swift")
        expectEqual(banner.contains("discardCorruptFileAndSave()"), true, "配置读写口径: 横幅接了放弃出口")
        expectEqual(banner.contains("activateFileViewerSelecting"), true, "配置读写口径: 横幅给「在访达中显示」让用户自己修")
    }

    // ---- 项目级 skill(2026-09-05,借鉴清单 #49)----
    //
    // `.claude/skills/<名>/SKILL.md` 是 AGENTS.md 里三段操作型流程(真机验证 / 歌词排查 / 发版)的「步骤版」:
    // 只写步骤与判据,理由回链 AGENTS.md 与 docs。它最常见的死法是锚点腐烂(脚本改名、文档挪位、链接失效)和
    // 越写越长变成第二份 AGENTS.md,这里守:行数上限、frontmatter 齐、引用的仓库路径 / 文档链接都在、发版只许
    // 显式触发、真机验证开头就是禁 AppleScript 那条、两个入口文件都指过去。
    do {
        // #filePath = <repo>/lyrimuse/Sources/lyrimuse-selftest/SourceContractTests.swift → 上 4 层到仓库根
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let skillsDir = repoRoot.appendingPathComponent(".claude/skills")
        let expected = ["lyrimuse-lyrics-triage", "lyrimuse-release", "lyrimuse-verify-ui"]
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: skillsDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        expectEqual(found, expected, "项目级 skill: 三份都在、没有多出来的(多一份要来这里登记)")
        let linkPattern = try? NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
        let codePattern = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#)
        let pathPrefixes = ["lyrimuse/", "lyrimuse-collector/", "docs/", ".github/", ".claude/"]
        for name in expected {
            let file = skillsDir.appendingPathComponent("\(name)/SKILL.md")
            guard let src = try? String(contentsOfFile: file.path, encoding: .utf8) else {
                expectEqual(true, false, "项目级 skill: 读得到 \(name)/SKILL.md")
                continue
            }
            let lineCount = src.split(separator: "\n", omittingEmptySubsequences: false).count
            expectEqual(lineCount <= 80, true, "项目级 skill: \(name) 不超过 80 行(实际 \(lineCount))——只写步骤,理由回链")
            expectEqual(src.hasPrefix("---\nname: \(name)\n"), true, "项目级 skill: \(name) frontmatter 以 name 开头且与目录名一致")
            expectEqual(src.contains("\ndescription: "), true, "项目级 skill: \(name) 有 description(按场景触发靠它)")
            expectEqual(src.contains("AGENTS.md"), true, "项目级 skill: \(name) 回链 AGENTS.md(理由不在 skill 里)")
            let ns = src as NSString
            let whole = NSRange(location: 0, length: ns.length)
            var missing: [String] = []
            if let linkPattern {
                for m in linkPattern.matches(in: src, range: whole) {
                    var target = ns.substring(with: m.range(at: 1))
                    if target.hasPrefix("http") { continue }
                    if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
                    guard !target.isEmpty else { continue }
                    let url = file.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
                    if !FileManager.default.fileExists(atPath: url.path) { missing.append("link:" + target) }
                }
            }
            if let codePattern {
                for m in codePattern.matches(in: src, range: whole) {
                    let token = ns.substring(with: m.range(at: 1))
                    var first = token.split(separator: " ").first.map(String.init) ?? ""
                    if first.hasPrefix("./") { first.removeFirst(2) }
                    guard pathPrefixes.contains(where: { first.hasPrefix($0) }),
                          !first.contains("<"), !first.contains("*") else { continue }
                    if !FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(first).path) {
                        missing.append("path:" + first)
                    }
                }
            }
            expectEqual(missing, [], "项目级 skill: \(name) 引用的路径 / 链接都存在")
        }
        let release = (try? String(contentsOfFile: skillsDir.appendingPathComponent("lyrimuse-release/SKILL.md").path,
                                   encoding: .utf8)) ?? ""
        expectEqual(release.contains("\ndisable-model-invocation: true\n"), true,
                    "项目级 skill: 发版 skill 只许显式触发(它会打 tag 推远端)")
        let verify = (try? String(contentsOfFile: skillsDir.appendingPathComponent("lyrimuse-verify-ui/SKILL.md").path,
                                  encoding: .utf8)) ?? ""
        let verifyHead = verify.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
        expectEqual(verifyHead.contains("AppleScript"), true, "项目级 skill: 真机验证 skill 开头就写禁 AppleScript 那条硬规则")
        for entry in ["AGENTS.md", "CLAUDE.md"] {
            let text = (try? String(contentsOfFile: repoRoot.appendingPathComponent(entry).path, encoding: .utf8)) ?? ""
            expectEqual(text.contains(".claude/skills/"), true, "项目级 skill: \(entry) 指向 .claude/skills/")
        }
    }

    // ---- 日志规范(2026-09-04)----
    //
    // 业界通用范式,规则写在 AGENTS.md「容易踩的具体坑 → 日志」:正文一律英文、`component: message key=value`;
    // App/Core 侧只用统一 subsystem 的 os.Logger,禁 NSLog / 裸 print(诊断导出按 subsystem 查 OSLogStore,
    // 绕开 Logger 的日志进不了导出);collector 走 stdlib log.Printf。这里只守机器能查的三件事:两侧日志
    // 字面量不含 CJK、App/Core 里没有 NSLog( / 裸 print(、Logger 的 subsystem 只有一个。
    // 确需例外在那一行行尾写 `// log-style: allow`。只看字面量本身,不看行尾注释(注释可以是中文)。
    do {
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = packageDir.deletingLastPathComponent()
        func hasCJK(_ s: Substring) -> Bool {
            s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        }
        /// 从 `("` 之后取到第一个未转义的 `"` 为止 —— Go 的格式串 / Swift 字面量的前半段都够用。
        func firstLiteral(_ line: String) -> Substring? {
            guard let open = line.range(of: "(\"") else { return nil }
            var i = open.upperBound
            var prev: Character = " "
            while i < line.endIndex {
                if line[i] == "\"" && prev != "\\" { return line[open.upperBound..<i] }
                prev = line[i]; i = line.index(after: i)
            }
            return nil
        }
        func files(under dir: URL, suffix: String) -> [(rel: String, text: String)] {
            var out: [(String, String)] = []
            if let walker = FileManager.default.enumerator(atPath: dir.path) {
                for case let rel as String in walker where rel.hasSuffix(suffix) {
                    if let text = try? String(contentsOfFile: dir.appendingPathComponent(rel).path, encoding: .utf8) {
                        out.append((rel, text))
                    }
                }
            }
            return out.sorted { $0.0 < $1.0 }
        }
        var offenders: [String] = []
        var subsystems: Set<String> = []
        let swiftLogCall = try? NSRegularExpression(pattern: #"logger\.(debug|info|notice|error|warning|fault|log)\(""#)
        for dir in ["Sources/lyrimuse", "Sources/LyrimuseCore"] {
            for (rel, text) in files(under: packageDir.appendingPathComponent(dir), suffix: ".swift") {
                for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(raw)
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("//") || line.contains("// log-style: allow") { continue }
                    if t.contains("NSLog(") || t.hasPrefix("print(") {
                        offenders.append("\(dir)/\(rel):\(n + 1) NSLog/print")
                    }
                    if let r = line.range(of: "Logger(subsystem: \"") {
                        let rest = line[r.upperBound...]
                        if let q = rest.firstIndex(of: "\"") { subsystems.insert(String(rest[..<q])) }
                    }
                    if let re = swiftLogCall,
                       re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                       let open = line.range(of: "(\""), let close = line.range(of: "\")", options: .backwards),
                       open.upperBound <= close.lowerBound, hasCJK(line[open.upperBound..<close.lowerBound]) {
                        offenders.append("\(dir)/\(rel):\(n + 1) CJK in log literal")
                    }
                }
            }
        }
        // 2026-09-05 起 collector 新写的日志走 slog.Debug/Info/Warn/Error(logsink.go),一并扫。
        let goLogCall = try? NSRegularExpression(pattern: #"\b(?:log|slog)\.(Printf|Println|Print|Fatalf|Fatal|Debug|Info|Warn|Error)\(""#)
        for (rel, text) in files(under: repoRoot.appendingPathComponent("lyrimuse-collector"), suffix: ".go")
        where !rel.hasSuffix("_test.go") && !rel.contains("/") {
            for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(raw)
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || line.contains("// log-style: allow") { continue }
                if let re = goLogCall,
                   re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                   let lit = firstLiteral(line), hasCJK(lit) {
                    offenders.append("lyrimuse-collector/\(rel):\(n + 1) CJK in log literal")
                }
            }
        }
        expectEqual(offenders, [], "日志规范: 以下位置违反(日志字面量含 CJK / NSLog / 裸 print),规则见 AGENTS.md「日志」")
        expectEqual(subsystems, ["me.yudaotor.lyrimuse"], "日志规范: Logger 的 subsystem 只允许 me.yudaotor.lyrimuse(诊断导出按它查 OSLogStore)")
    }
}
