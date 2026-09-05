import SwiftUI
import os

#if canImport(Translation)
    import Translation
#endif

/// 走统一 subsystem 的 Logger 不走 NSLog(2026-09-04,日志规范):诊断导出按 subsystem 查 OSLogStore,
/// NSLog 打出来的两行此前永远进不了导出——而这两行正是排"语言包读数全零"要看的。
private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "language-packs")

/// 语言包清单 + 可用性的共享缓存。
///
/// **为什么不能放在视图的 @State 里**:2026-08-08 用户反馈"点完打勾、退出去再进来又变回
/// 没装"。装没装这件事本来就不需要 App 自己持久化 —— `LanguageAvailability` 读的就是系统
/// 里的真实状态,而且实测连查五轮结果完全一致、不存在抖动。真正的原因是**读取有可见的
/// 延迟**:一次要串行问十几种语言,期间 @State 还是空的,于是每一种都渲染成"没装";视图
/// 一被重建(所在卡片随 features 变化重建)@State 又清空,再空窗一次,看起来就像状态丢了。
///
/// 提到这个单例里之后,重新进入设置页立刻拿得到上一次的结果,刷新在后台悄悄发生。
@available(macOS 26.0, *)
@MainActor
final class LanguagePackStatusStore: ObservableObject {
    static let shared = LanguagePackStatusStore()

    /// 当前该列出来的源语言,已经排好序、并且**剔除了目标语言自己**。
    @Published private(set) var codes: [String] = []
    @Published private(set) var statuses: [String: LanguageAvailability.Status] = [:]
    @Published private(set) var hasLoaded = false

    private var inFlight: Task<Void, Never>?

    /// 歌词里最常撞见的几种排前面,其余按本地化名称排。系统给的顺序本身没有可读性。
    private static let preferred = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    /// 归一成菜单里用的语言代码。
    ///
    /// 中文**保留 script**:简繁是两个独立的语言包,状态确实会不同(2026-08-09 实测
    /// zh-Hans→en 已装、zh-Hant→en 只是"支持未装")。其余语言的 script 没有区分意义,
    /// `en-Latn-US` 和 `en-Latn-GB` 是同一种英语,合成一条,否则菜单里会并排两个"英语"。
    private static func canonical(_ lang: Locale.Language) -> String? {
        guard let base = lang.languageCode?.identifier else { return nil }
        if base == "zh", let script = lang.script?.identifier { return "zh-\(script)" }
        return base
    }

    /// 用 `L10n.locale` 而不是 `Locale.current`:这里出来的是**界面文本**(下拉里那一列
    /// 语言名),必须跟同一行右边走 `L10n.t()` 的状态文案用同一种语言。用系统 locale 的话,
    /// 界面切成英文、系统仍是中文的机器上会渲染成「英语 · Downloaded」这种中英混排
    /// (2026-08-13 用户报)。译文的**目标**语言(target)是另一回事,那个照旧跟随系统。
    static func displayName(_ code: String) -> String {
        L10n.locale.localizedString(forIdentifier: code) ?? code
    }

    func refresh(target: Locale.Language) {
        // 同一时刻只跑一次:视图出现和目标语言变化可能几乎同时触发,重复问一遍纯属浪费。
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            let availability = LanguageAvailability()
            let targetCode = Self.canonical(target)
            var seen = Set<String>()
            var list: [String] = []
            // 清单由系统给,不再硬编码。硬编码那一版漏掉了**中文本身** —— 目标语言换成英语
            // 之后,中文歌要的正是 zh→en 这个包,而菜单里根本没有它可点;顺带还漏了荷兰语/
            // 波兰语/土耳其语/乌克兰语,以及以后系统新增的任何语言。
            for lang in await availability.supportedLanguages {
                guard let code = Self.canonical(lang) else { continue }
                // 源语言就是目标语言时这一对没有意义,系统给的状态是 unsupported。留在菜单
                // 里只会让人点了之后卡在"下载中…"永远不动 —— 2026-08-09 用户就这么撞上了:
                // 译文语言设成英语,菜单里还列着"英语"。
                guard code != targetCode else { continue }
                guard seen.insert(code).inserted else { continue }
                list.append(code)
            }
            list.sort { a, b in
                let ia = Self.preferred.firstIndex(of: a) ?? Int.max
                let ib = Self.preferred.firstIndex(of: b) ?? Int.max
                if ia != ib { return ia < ib }
                // 排序规则也跟着界面语言走:localizedCompare 用的是系统 locale,英文界面下
                // 会按中文拼音序排出一串英文名,看着像没排序。
                return Self.displayName(a).compare(
                    Self.displayName(b), options: [], range: nil, locale: L10n.locale
                ) == .orderedAscending
            }

            var next: [String: LanguageAvailability.Status] = [:]
            for code in list {
                if Task.isCancelled { return }
                next[code] = await availability.status(
                    from: Locale.Language(identifier: code), to: target)
            }
            // 全零复查:2026-08-11 第三次复发终于抓到现行 —— 同一进程 19:46:25 查到
            // installed=0、19:46:32(7 秒后)就是 4,进程外同刻探针也是 4。也就是说
            // LanguageAvailability 在 translationd 冷启动/闲置退出后的第一轮查询会把
            // "已安装"整体误报成"未安装",几秒内自愈。所以:一轮查下来一个已装的都没有
            // 时先不信,等 5 秒重查一遍,以第二遍为准 —— 真被系统清掉的话第二遍还是零,
            // 照实显示;冷启动误报则被这一步吸收,用户不再看到"0/18"闪现。
            // (期间不发布任何结果,界面维持上一次的读数,单例缓存本来就在。)
            if !list.isEmpty, !next.values.contains(.installed) {
                logger.notice("language packs: all zero, re-verifying in 5s (translationd cold-start suspected)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                var second: [String: LanguageAvailability.Status] = [:]
                for code in list {
                    if Task.isCancelled { return }
                    second[code] = await availability.status(
                        from: Locale.Language(identifier: code), to: target)
                }
                next = second
            }
            // 系统说这一对压根不支持的,直接不列 —— 列出来也点不动,只会让人以为坏了。
            //
            // 上面按"规范代码相等"排除目标语言只挡住了 en→en 这种同码的情况。2026-08-10
            // 用户报「繁体中文 · 不支持」,查下来是**系统把中文当作一种语言**:简体和繁体
            // 之间不构成翻译对,所以目标是中文时 zh-Hant 和 zh-Hans 都会报 unsupported
            // (实测表:zh-Hant→zh-Hans / zh-Hant→zh-Hant / zh-Hans→zh 全是 unsupported,
            // 而 zh-Hant→en、zh-Hant→ja 都是已下载)。目标写成 zh-Hans 时 zh-Hans 被排除、
            // zh-Hant 却因为字符串不等留了下来,就露出了这一行。
            //
            // 不特判中文而是按**系统给的状态**过滤:同语言、中文简繁、以及以后任何一种
            // 系统不认的组合,都会被同一条规则挡掉,不用每出现一种就补一次名单。
            list.removeAll { next[$0] == .unsupported }
            next = next.filter { $0.value != .unsupported }
            guard !Task.isCancelled else { return }
            // 2026-08-10:用户第二次报"语言包全变成未下载"。同一时刻用独立进程跑**同一套
            // 查询**(同样的 canonical 代码往返、同样的 target "en")拿到的是 5 个已安装
            // (ja/ko/ru/zh-Hans/zh-Hant),全程 0.07s —— 也就是说 App 外复现不出来,输入也
            // 完全一致。差别只剩"进程"本身,那就只能让 App 自己把它读到的东西说出来,
            // 下次再发生时直接看日志,不用再靠猜。
            let installed = next.filter { $0.value == .installed }.map(\.key).sorted()
            logger.notice("language packs: target=\(Self.canonical(target) ?? "?", privacy: .public) listed=\(list.count, privacy: .public) installed=\(installed.count, privacy: .public) \(installed.joined(separator: ","), privacy: .public)")
            self?.codes = list
            self?.statuses = next
            self?.hasLoaded = true
        }
    }
}

/// 「翻译语言包」设置行:右边一个读数「已下载 6 / 18」+ 一颗「管理…」,点开在卡里展开一块
/// 3 列的语言网格(✓ 已下载 / ⭳ 未下载、点一下让系统下载 / 转轴 下载中),网格下面一条说明
/// 告诉人语言包归 macOS 管、要删去系统设置。
///
/// 为什么这一行必须在 App 里、而不是交给采集器:系统的语言包下载会弹一个系统 UI,只有
/// SwiftUI 的 `.translationTask` 建出来的 `TranslationSession` 才有权拉起它
/// (`canRequestDownloads`)。采集器调的那个 `lyrics-translate` 是无界面子进程,自己触发
/// 下载会弹出没头没尾的窗口,所以它只负责如实回报"语言包没装",引导落在这里。
///
/// **2026-09-05 从下拉菜单改成展开网格**(用户:「点进去下载的交互很奇怪」)。下拉那版的
/// 问题不在样子而在隐喻:下拉是"从几个值里选一个",而这里点一项的后果是**触发一次下载**
/// (系统会弹一张确认下载的 sheet),动词跟控件对不上——菜单项写的是「法语 · 未下载」,
/// 看不出"点它就会下载";已装的那些点了什么都不发生;下载期间整个菜单的项全部置灰、却没
/// 有任何地方解释为什么。网格把每种语言的状态摆在明处,只有没装的那些是按钮(悬停有底色、
/// 提示写「点击下载」),装好的就是一个绿勾,下载中的那一格自己转圈——每个状态各占一个
/// 格子,不用再靠一串菜单文字去猜。
///
/// 展开而不是 popover:下载确认是系统弹在**设置窗口**上的 sheet,popover 在它弹出时会被
/// 收掉,用户下载完还得再点开一次才看得到结果;留在卡里就没有这层折腾。⚠️ 展开状态是
/// @State 不是 @AppStorage:默认折叠(跟「全部设置」抽屉同一条理由),不把上次展开的样子
/// 带到下次打开设置。
///
/// ⚠️ 读数「已下载 6 / 18」按**当前译文语言**统计"能翻成它的语言对",不是系统设置里
/// "下载了几种语言"——译文语言自己(简体中文)和同语系的繁体中文在这一对里是 unsupported,
/// 会被过滤掉,所以系统设置显示 8 种、这里是 6 / 18 是**正常的**(2026-09-05 用户觉得
/// "感觉有 bug",进程外探针对过:系统真值就是这 6 个)。help 气泡里把这条写明了。
@available(macOS 26.0, *)
struct LanguagePackRow: View {
    @ObservedObject private var features = FeatureSettingsStore.shared
    @ObservedObject private var store = LanguagePackStatusStore.shared
    @State private var pending: TranslationSession.Configuration?
    @State private var downloading: String?
    @State private var isExpanded = false
    /// 鼠标悬在哪一格上(只为悬停底色,跟「歌词来源」网格的 hoveredSource 同一个用法)。
    @State private var hoveredCode: String?
    /// 每发起一次下载 +1。两处靠它:
    ///   1. 下面那个**隐形 carrier** 的 `.id(downloadNonce)` —— 这是「再点同一个语言一直转圈」
    ///      的真正解药(见 requestDownload 的头注);
    ///   2. 看门狗 `.task(id: downloadNonce)` 靠它重新计时。
    /// 两处都需要「每次请求必然变化的键」,而 `downloading` 在连点同一个语言时值不变。
    @State private var downloadNonce = 0

    /// 网格固定 3 列(理由跟「歌词来源」网格固定 4 列相同:行数只取决于语言数,不随译名
    /// 长短折行;18 种正好 6 行)。3 而不是 4 是因为英文译名更长——“Chinese, Traditional”
    /// 这类在 4 列的格宽下要截断。
    private static let columns = 3

    /// 译文的目标语言。跟采集器侧 `appleLangCode` / `resolveLyricsTranslationLanguage`
    /// 保持同一套语义:
    ///   - 具体语言就用它;
    ///   - `auto` 表示**跟随系统语言**(采集器那边是读 AppleLocale 取两位代码),这里用
    ///     `Locale.current.language`,而不是想当然地写死成中文 —— 系统语言是英文的用户
    ///     选了"跟随系统",目标就该是英文。
    /// 中文另外映射成 zh-Hans/zh-Hant:Apple 认带地区的写法,而设置里存的是两位代码。
    private var target: Locale.Language {
        let raw = features.lyricsTranslationLanguage.rawValue.lowercased()
        switch raw {
        case "auto", "":
            let system = Locale.current.language
            return system.languageCode?.identifier == "zh"
                ? Locale.Language(identifier: "zh-Hans") : system
        case "zh", "zh-cn", "zh-hans": return Locale.Language(identifier: "zh-Hans")
        case "zh-tw", "zh-hant": return Locale.Language(identifier: "zh-Hant")
        default: return Locale.Language(identifier: raw)
        }
    }

    private var installedCount: Int {
        store.statuses.values.filter { $0 == .installed }.count
    }

    var body: some View {
        // ⚠️ 外面必须是 VStack 而不是 Group:下面挂的 .task / .onReceive / .translationTask
        // 要是套在 Group 上,会被转发给**每一个**子视图 —— 刷新跑两遍还只是浪费,
        // translationTask 跑两遍就是弹两张下载 sheet。VStack(spacing: 0) 嵌在 SettingsCard
        // 自己那个 VStack(spacing: 0) 里,对布局是透明的。
        VStack(spacing: 0) {
            SettingsRow(
                icon: "arrow.down.circle",
                title: L10n.t("翻译语言包"),
                help: L10n.t("只统计能翻成当前译文语言的语言；译文语言自己和同一语系的语言不计，所以数字可能比「系统设置」里的少。语言包由 macOS 管理，翻译在本机完成")
            ) {
                HStack(spacing: 10) {
                    // 首次读取有可见延迟(进程刚起时 translationd 冷启动还会先误报全零、
                    // 等 5 秒复查,见 LanguagePackStatusStore.refresh),这段时间明说
                    // "检查中",而不是让人以为一个都没装。
                    Text(summaryText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button(isExpanded ? L10n.t("收起") : L10n.t("管理…")) {
                        withAnimation(.settingsCardReveal) { isExpanded.toggle() }
                    }
                    .controlSize(.small)
                    .accessibilityValue(isExpanded ? L10n.t("已展开") : L10n.t("已折叠"))
                }
            }
            if isExpanded {
                CardDivider()
                SettingsRawRow(insetToText: true) { packGrid }
                SettingsNote {
                    Text(L10n.t("要删除已下载的语言包，请到「系统设置 › 通用 › 语言与地区 › 翻译语言」"))
                    Button(L10n.t("打开系统设置")) {
                        // 语言与地区面板;「翻译语言…」是那一页底部的一颗按钮,系统没给它
                        // 单独的深链,只能开到这一层。
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        // 出现时刷新一次;目标语言改了要按新目标重算 —— 可用性是**按语言对**算的,换了目标
        // 整张表的含义都变了(2026-08-09 实测同一台机器:目标中文时 en/ja/ko/ru 四种已装,
        // 目标英语时只剩 ja/ko/ru 三种,英语那一格变成 unsupported)。缓存在单例里,所以
        // 这两次刷新都不会让界面先空一下。
        .task(id: target.maximalIdentifier) {
            // pending 也要清:换目标那一刻若还挂着上一个目标的下载配置,translationTask 会
            // 按旧目标继续跑完,而界面已经在按新目标显示了。
            downloading = nil
            pending = nil
            store.refresh(target: target)
        }
        // 每次窗口重新变成前台再查一次。这一行的内容不是 App 自己的状态,而是**系统当下**
        // 的语言包情况 —— 用户完全可能刚去"系统设置 → 翻译"里装了或删了一个包,回来时
        // 这里该是新的。顺带也给一次坏读数一条自愈的路:2026-08-09 用户截到过一次
        // "已下载 0 / 19",而同一份代码事后连查四轮(含三次冷启动)都是正确的 5 / 19 ——
        // 原因没能复现,但至少点开别处再回来就能纠正,而不是一直卡着。
        //
        // 它还兜住"回来时上一轮下载的转圈还亮着":didBecomeActive 时若 downloading 那个语言
        // 系统已报已装,就把 spinner 收掉(下面看门狗是超时兜底,这个是"回到前台立刻纠正")。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            store.refresh(target: target)
            if let code = downloading, store.statuses[code] == .installed {
                downloading = nil
                pending = nil
            }
        }
        // 看门狗:下载完成的回调(下面 translationTask 的 action)在**关掉窗口**时可能整段不
        // 执行 —— 系统的下载确认 sheet 被连带撤掉,`prepareTranslation()` 就悬在那里不返回,
        // 收尾(把 downloading 清空)永远轮不到,spinner 于是无限转圈。这里给它一个上限:发起
        // 下载 180 秒后还卡在同一个语言、且系统仍报未装,就认定这一轮已经断了,把转圈收掉。
        // 真装没装始终以 store 为准,清早了下次刷新会纠正回来;180s 对一个语言包(几十 MB)是
        // 很宽的余量,正常下载走 translationTask 的回调早就收尾了,轮不到这里。
        // 键用 downloadNonce 而不是 downloading:同一个语言点第二次时 downloading 值不变,
        // 只有 nonce 每次必变,才能让 .task(id:) 重新计时。
        .task(id: downloadNonce) {
            guard downloadNonce > 0, let code = downloading else { return }
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled else { return }
            if downloading == code, store.statuses[code] != .installed {
                logger.notice("language packs: download watchdog fired for \(code, privacy: .public), clearing stuck spinner")
                downloading = nil
                pending = nil
            }
        }
        // 挂 translationTask 的隐形 carrier。放进 .background 不占布局;`.id(downloadNonce)`
        // 是关键:每次点下载 nonce 都变、这段整块重建,新实例 appear 时 action 必然重跑,
        // 绕开「等值 Configuration 不重跑」那个坑(见 requestDownload 头注 + harness 结论)。
        .background {
            Color.clear
                .frame(width: 0, height: 0)
                .translationTask(pending) { session in
                    // 每次真正跑起来都留一条痕:排「点了没反应」时,看这条在不在就知道 action
                    // 到底有没有被触发(而不是卡在 SwiftUI 不重跑那一层)。
                    logger.notice("language packs: prepareTranslation start (nonce=\(downloadNonce, privacy: .public), for=\(downloading ?? "?", privacy: .public))")
                    try? await session.prepareTranslation()
                    await MainActor.run {
                        logger.notice("language packs: prepareTranslation done (for=\(downloading ?? "?", privacy: .public))")
                        downloading = nil
                        pending = nil
                        store.refresh(target: target)
                    }
                }
                .id(downloadNonce)
        }
    }

    private var summaryText: String {
        guard store.hasLoaded else { return L10n.t("检查中…") }
        return String(format: L10n.t("已下载 %@ / %@"), "\(installedCount)", "\(store.codes.count)")
    }

    /// 发起一次语言包下载。
    ///
    /// ⚠️ 「点第二次同一个语言一直转圈」的正解是**下面那个隐形 carrier 的 `.id(downloadNonce)`**,
    /// 这里只要把 nonce 抬一下就行。原理:`.translationTask(pending)` 只在配置**变化**时重跑
    /// 它的 action(苹果文档原话:view 出现或配置变化时运行),而 `TranslationSession
    /// .Configuration` 是 Equatable —— 同源同目标两次点击给的是**等值**配置,直接赋值它判定
    /// "没变"、不重跑,spinner 亮着(`downloading == code`)、底下却没任务在跑,永远转圈。
    ///
    /// ⚠️ 曾经试过「先把 pending 清成 nil、下一拍 Task 里再赋值」想凑出 nil→config 的跳变,
    /// **实测无效**(一次性 harness translationtask_probe.swift 坐实:两次等值请求 action 只跑
    /// 一次)—— SwiftUI 把同一轮里的 `nil` 和随后的 `config` 合并成一次更新,translationTask
    /// 看到的仍是"没变"。真正可靠的是给挂 translationTask 的那段视图一个每次都变的 `.id`:
    /// id 一变,SwiftUI 把那段整块销毁重建,新视图 appear 时 translationTask 的 action 必然重跑,
    /// 跟配置等不等值无关(同一份 harness 里 `.id(nonce)` 那一路两次请求 action 跑了两次)。
    ///
    /// (设置是 `Settings {}` 场景,关窗只隐藏、SwiftUI 视图不销毁、`@State` 不清空,所以上一轮
    ///  卡住的 downloading/pending 会留到下次打开——这也是为什么"等值不重跑"会以"关窗再点"的
    ///  形态被撞见。nonce 方案对这个也成立:下次打开点一下 nonce 照样变、carrier 照样重建。)
    private func requestDownload(_ code: String) {
        downloading = code
        pending = TranslationSession.Configuration(
            source: Locale.Language(identifier: code), target: target)
        // 抬 nonce 放在最后:carrier 的 .id 变化时,它读到的 pending 已经是新配置。
        downloadNonce += 1
    }

    /// 语言网格。写死列数的 `Grid`(不是 LazyVGrid):格子数是语言数、不需要按内容自适应,
    /// 而 Lazy 容器在窗口不可见时不铺格子(「通用」页的图标网格踩过,见 MenuBarIconPicker)。
    /// 最后一行不满 3 格时 Grid 自己会留空,不用补占位。
    private var packGrid: some View {
        let codes = store.codes
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(stride(from: 0, to: codes.count, by: Self.columns)), id: \.self) { start in
                GridRow {
                    ForEach(codes[start ..< min(start + Self.columns, codes.count)], id: \.self) { code in
                        packCell(code)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("翻译语言包"))
    }

    /// 一格 = 状态图标 + 语言名,三种形态各自说话:
    /// - 已下载:绿色实心勾 + 主色文字,**不是按钮**(系统对已装的语言不会重复下载,点了
    ///   什么都不发生,那就别让它看起来能点);删除走系统设置,网格下面那句说明指了路。
    /// - 未下载:空心下载圈 + 次要色文字,是按钮:悬停给一层极淡的底色说明"能点",提示
    ///   写「点击下载」;点了把这一格交给 translationTask,系统弹 sheet 问要不要下载。
    /// - 下载中:小转轴代替图标。系统的下载 sheet 是模态的,这个态实际上只在 sheet 弹出前
    ///   后各露一瞬,但没有它,从点下到 sheet 出现之间就是一段"点了没反应"。
    ///
    /// 视觉上跟「歌词来源」网格是一家(圆形状态图标 15pt + 13pt 文字 + 悬停底色),读的人
    /// 不用再学一套。区别只在语义:那边的勾是"启用了",这边的勾是"装好了"。
    @ViewBuilder
    private func packCell(_ code: String) -> some View {
        let installed = store.statuses[code] == .installed
        let isDownloading = downloading == code
        let name = LanguagePackStatusStore.displayName(code)
        let label = HStack(spacing: 6) {
            Group {
                if isDownloading {
                    ProgressView().controlSize(.mini)
                } else if installed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 15, height: 15)
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(installed ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)

        if installed {
            label
                .help(L10n.t("已下载"))
                .accessibilityLabel(String(format: L10n.t("%@，已下载"), name))
        } else {
            let hovered = hoveredCode == code
            Button {
                requestDownload(code)
            } label: {
                label
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(hovered ? Color.secondary.opacity(0.12) : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            // 一次只下一个:系统 sheet 本来就是模态的,这里置灰只是把"为什么现在点不动"
            // 画出来。转圈的那一格不置灰,不然转轴也跟着变淡。
            .disabled(downloading != nil && !isDownloading)
            .help(isDownloading ? L10n.t("下载中…") : L10n.t("点击下载"))
            .onHover { hoveredCode = $0 ? code : (hoveredCode == code ? nil : hoveredCode) }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .accessibilityLabel(String(format: L10n.t("%@，点击下载"), name))
        }
    }
}
