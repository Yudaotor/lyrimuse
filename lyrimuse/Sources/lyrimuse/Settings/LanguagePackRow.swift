import SwiftUI

#if canImport(Translation)
    import Translation
#endif

/// 语言包可用性的共享缓存。
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

    @Published private(set) var statuses: [String: LanguageAvailability.Status] = [:]
    @Published private(set) var hasLoaded = false

    private var inFlight: Task<Void, Never>?

    func refresh(codes: [String], target: Locale.Language) {
        // 同一时刻只跑一次:视图出现和目标语言变化可能几乎同时触发,重复问一遍纯属浪费。
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            let availability = LanguageAvailability()
            var next: [String: LanguageAvailability.Status] = [:]
            for code in codes {
                if Task.isCancelled { return }
                next[code] = await availability.status(
                    from: Locale.Language(identifier: code), to: target)
            }
            guard !Task.isCancelled else { return }
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
/// 做成下拉而不是一排并列的胶囊:同样是那次反馈 —— 并排排开六种就已经换行挤成两行了,
/// 语言再多就没法操作。下拉之后不受宽度限制,列表可以给全。
@available(macOS 26.0, *)
struct LanguagePackRow: View {
    /// 歌词常见的外语 + 系统支持的主要语种。
    private static let candidates = [
        "en", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "th", "vi", "id", "ar", "hi",
    ]

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
            subtitle: L10n.t("没装语言包的语言会退回联网翻译；选一个由系统下载，之后就完全在本机翻译")
        ) {
            Menu {
                ForEach(Self.candidates, id: \.self) { code in
                    Button {
                        downloading = code
                        pending = TranslationSession.Configuration(
                            source: Locale.Language(identifier: code), target: target)
                    } label: {
                        // 状态用 Label 自带的图标位表达:已装打勾、没装是下载箭头、正在下
                        // 的用虚线箭头(菜单项里放不了 ProgressView)。
                        Label(
                            displayName(code),
                            systemImage: downloading == code
                                ? "arrow.down.circle.dotted"
                                : (store.statuses[code] == .installed
                                    ? "checkmark.circle.fill" : "arrow.down.circle"))
                    }
                    // 已装好的也不禁用:读数万一是旧的,用户还能点(系统对已装的语言不会
                    // 重复下载),总好过被一个错误状态锁死。
                    .disabled(downloading != nil)
                }
            } label: {
                // 首次读取有可见延迟,这段时间明说"检查中",而不是让人以为一个都没装。
                Text(
                    store.hasLoaded
                        ? String(
                            format: L10n.t("已下载 %@ / %@"), "\(installedCount)",
                            "\(Self.candidates.count)")
                        : L10n.t("检查中…"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        // 出现时刷新一次;目标语言改了要按新目标重算(同一种源语言对不同目标语言的可用性
        // 是分开的)。缓存在单例里,所以这两次刷新都不会让界面先空一下。
        .task(id: target.maximalIdentifier) {
            store.refresh(codes: Self.candidates, target: target)
        }
        // configuration 置空再赋值才会重新触发;下载结束后回到 nil,顺带刷新一次状态。
        .translationTask(pending) { session in
            try? await session.prepareTranslation()
            await MainActor.run {
                downloading = nil
                pending = nil
                store.refresh(codes: Self.candidates, target: target)
            }
        }
    }

    private func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
