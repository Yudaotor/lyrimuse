import SwiftUI

#if canImport(Translation)
    import Translation
#endif

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

    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
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
                return Self.displayName(a).localizedCompare(Self.displayName(b)) == .orderedAscending
            }

            var next: [String: LanguageAvailability.Status] = [:]
            for code in list {
                if Task.isCancelled { return }
                next[code] = await availability.status(
                    from: Locale.Language(identifier: code), to: target)
            }
            guard !Task.isCancelled else { return }
            // 2026-08-10:用户第二次报"语言包全变成未下载"。同一时刻用独立进程跑**同一套
            // 查询**(同样的 canonical 代码往返、同样的 target "en")拿到的是 5 个已安装
            // (ja/ko/ru/zh-Hans/zh-Hant),全程 0.07s —— 也就是说 App 外复现不出来,输入也
            // 完全一致。差别只剩"进程"本身,那就只能让 App 自己把它读到的东西说出来,
            // 下次再发生时直接看日志,不用再靠猜。
            let installed = next.filter { $0.value == .installed }.map(\.key).sorted()
            NSLog("lyrimuse: language packs target=%@ listed=%d installed=%d %@",
                  Self.canonical(target) ?? "?", list.count, installed.count,
                  installed.joined(separator: ","))
            self?.codes = list
            self?.statuses = next
            self?.hasLoaded = true
        }
    }
}

/// 「翻译语言包」设置行:一个下拉,列出可离线翻译的源语言,没装的选一下让系统下载。
///
/// 为什么这一行必须在 App 里、而不是交给采集器:系统的语言包下载会弹一个系统 UI,只有
/// SwiftUI 的 `.translationTask` 建出来的 `TranslationSession` 才有权拉起它
/// (`canRequestDownloads`)。采集器调的那个 `lyrics-translate` 是无界面子进程,自己触发
/// 下载会弹出没头没尾的窗口,所以它只负责如实回报"语言包没装",引导落在这里。
///
/// 做成下拉而不是一排并列的胶囊:并排排开六种就已经换行挤成两行了,语言再多就没法操作。
@available(macOS 26.0, *)
struct LanguagePackRow: View {
    @ObservedObject private var features = FeatureSettingsStore.shared
    @ObservedObject private var store = LanguagePackStatusStore.shared
    @State private var pending: TranslationSession.Configuration?
    @State private var downloading: String?

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
        SettingsRow(
            icon: "arrow.down.circle",
            title: L10n.t("翻译语言包"),
            help: L10n.t("请提前下载好需要翻译的语言")
        ) {
            Menu {
                ForEach(store.codes, id: \.self) { code in
                    Button {
                        downloading = code
                        pending = TranslationSession.Configuration(
                            source: Locale.Language(identifier: code), target: target)
                    } label: {
                        // 状态**写进文字**,不只靠图标:2026-08-08 实测,macOS 的 SwiftUI
                        // Menu 默认把菜单项 Label 的图标整个丢掉,只渲染标题 —— 上一版就是
                        // 这样,一整列语言看不出哪个装了。.labelStyle(.titleAndIcon) 是
                        // 官方的要图标写法,加上;但状态不能只押在它身上,所以文字里也说清。
                        Label(
                            "\(LanguagePackStatusStore.displayName(code))  ·  \(stateText(code))",
                            systemImage: downloading == code
                                ? "arrow.down.circle.dotted"
                                : (store.statuses[code] == .installed
                                    ? "checkmark.circle.fill" : "arrow.down.circle")
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    // 已装好的也不禁用:读数万一是旧的,用户还能点(系统对已装的语言不会
                    // 重复下载),总好过被一个错误状态锁死。系统明说不支持的那一档要禁用 ——
                    // 那不是"还没下载",是这一对永远下不来,点了只会卡在"下载中…"。
                    .disabled(downloading != nil || store.statuses[code] == .unsupported)
                }
            } label: {
                // 首次读取有可见延迟,这段时间明说"检查中",而不是让人以为一个都没装。
                Text(
                    store.hasLoaded
                        ? String(
                            format: L10n.t("已下载 %@ / %@"), "\(installedCount)",
                            "\(store.codes.count)")
                        : L10n.t("检查中…"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        // 出现时刷新一次;目标语言改了要按新目标重算 —— 可用性是**按语言对**算的,换了目标
        // 整张表的含义都变了(2026-08-09 实测同一台机器:目标中文时 en/ja/ko/ru 四种已装,
        // 目标英语时只剩 ja/ko/ru 三种,英语那一格变成 unsupported)。缓存在单例里,所以
        // 这两次刷新都不会让界面先空一下。
        .task(id: target.maximalIdentifier) {
            downloading = nil
            store.refresh(target: target)
        }
        // 每次窗口重新变成前台再查一次。这一行的内容不是 App 自己的状态,而是**系统当下**
        // 的语言包情况 —— 用户完全可能刚去"系统设置 → 翻译"里装了或删了一个包,回来时
        // 这里该是新的。顺带也给一次坏读数一条自愈的路:2026-08-09 用户截到过一次
        // "已下载 0 / 19",而同一份代码事后连查四轮(含三次冷启动)都是正确的 5 / 19 ——
        // 原因没能复现,但至少点开别处再回来就能纠正,而不是一直卡着。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            store.refresh(target: target)
        }
        // configuration 置空再赋值才会重新触发;下载结束后回到 nil,顺带刷新一次状态。
        .translationTask(pending) { session in
            try? await session.prepareTranslation()
            await MainActor.run {
                downloading = nil
                pending = nil
                store.refresh(target: target)
            }
        }
    }

    private func stateText(_ code: String) -> String {
        if downloading == code { return L10n.t("下载中…") }
        switch store.statuses[code] {
        case .installed: return L10n.t("已下载")
        case .unsupported: return L10n.t("不支持")
        case .supported: return L10n.t("未下载")
        default: return store.hasLoaded ? L10n.t("未下载") : L10n.t("检查中…")
        }
    }
}
