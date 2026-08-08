import SwiftUI

#if canImport(Translation)
    import Translation
#endif

/// 「翻译语言包」设置行:显示常见源语言的语言包装没装,没装的可以点一下让系统下载。
///
/// 为什么这一行必须在 App 里、而不是交给采集器:系统的语言包下载会弹一个系统 UI,只有
/// SwiftUI 的 `.translationTask` 建出来的 `TranslationSession` 才有权拉起它
/// (`canRequestDownloads`)。采集器调的那个 `lyrics-translate` 是无界面子进程,自己触发
/// 下载会弹出没头没尾的窗口,所以它只负责如实回报"语言包没装",引导落在这里。
///
/// 只列这几种语言:它们是"歌词是外语、而用户想看中文"的绝大多数情况。全量列表有几十种,
/// 逐个查可用性要几十次异步调用,收益不抵噪音。
@available(macOS 26.0, *)
struct LanguagePackRow: View {
    private static let candidates = ["en", "ja", "ko", "es", "fr", "de"]

    @ObservedObject private var features = FeatureSettingsStore.shared
    @State private var statuses: [String: LanguageAvailability.Status] = [:]
    @State private var pending: TranslationSession.Configuration?
    @State private var downloading: String?

    private var target: Locale.Language {
        // 跟采集器侧 appleLangCode 保持同一套映射:同一个"中文"在 Apple 这边是 zh-Hans,
        // 在 MyMemory 那边是 zh-CN,混用会让其中一条路静默失效。
        switch features.lyricsTranslationLanguage.rawValue.lowercased() {
        case "zh-tw", "zh-hant": return Locale.Language(identifier: "zh-Hant")
        case "", "auto", "zh", "zh-cn", "zh-hans": return Locale.Language(identifier: "zh-Hans")
        case let other: return Locale.Language(identifier: other)
        }
    }

    var body: some View {
        SettingsRow(
            icon: "arrow.down.circle",
            title: L10n.t("翻译语言包"),
            subtitle: L10n.t("没装语言包的语言会退回联网翻译；点一下由系统下载，之后就完全在本机翻译")
        ) {
            HStack(spacing: 6) {
                ForEach(Self.candidates, id: \.self) { code in
                    languageChip(code)
                }
            }
        }
        .task { await refresh() }
        // configuration 置空再赋值才会重新触发;下载完成后回到 nil,顺带刷新一次状态。
        .translationTask(pending) { session in
            try? await session.prepareTranslation()
            await MainActor.run { downloading = nil; pending = nil }
            await refresh()
        }
    }

    @ViewBuilder
    private func languageChip(_ code: String) -> some View {
        let installed = statuses[code] == .installed
        let busy = downloading == code
        Button {
            downloading = code
            pending = TranslationSession.Configuration(
                source: Locale.Language(identifier: code), target: target)
        } label: {
            HStack(spacing: 3) {
                Text(displayName(code)).font(.caption)
                if busy {
                    ProgressView().controlSize(.mini)
                } else if installed {
                    Image(systemName: "checkmark.circle.fill").font(.caption2)
                } else {
                    Image(systemName: "arrow.down.circle").font(.caption2)
                }
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(installed ? Color.secondary : Color.accentColor)
        // 已装好的就没什么可点的了 —— 保留显示是为了让"哪些已经能离线翻"一目了然。
        .disabled(installed || busy)
        .help(installed ? L10n.t("已下载，可离线翻译") : L10n.t("点击下载语言包"))
    }

    private func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func refresh() async {
        let availability = LanguageAvailability()
        var next: [String: LanguageAvailability.Status] = [:]
        for code in Self.candidates {
            next[code] = await availability.status(
                from: Locale.Language(identifier: code), to: target)
        }
        await MainActor.run { statuses = next }
    }
}
