import AppKit
import LyrimuseCore
import SwiftUI

/// 设置 → 「软件更新」页(2026-09-12,用户拍板,仿系统设置「软件更新」那页,见 14 章决策 #25)。
///
/// 结构照系统那页:顶上一张状态卡(App 图标 + 「Lyrimuse 1.7.0」+ 大小 / 日期或进度 + 右侧动作),卡里往下
/// 是发版日志;然后「已安装」一行、「自动更新」卡(自动检查 / 自动下载并安装)、「测试版更新」;页脚一行
/// 上次检查时间。数据与动作全在 `SparkleUpdaterManager`(`flow` 状态机 + `pendingItem`),这里只画。
///
/// 页面从三处进:侧栏「有软件更新可用」那一行(只在有新版本时存在)、「关于 › 更新 › 软件更新」、以及任何
/// 「检查更新」动作(菜单栏右键菜单 / 面板底栏)—— 检查的过程与结果都显示在这里,没有 Sparkle 的弹窗。
struct SoftwareUpdatePage: View {
    @ObservedObject private var updater = SparkleUpdaterManager.shared
    /// 只为「测试版更新」那一个开关订阅。
    @ObservedObject private var settings = AppSettings.shared

    private var item: SoftwareUpdateItem? { updater.shownItem }
    private var appName: String { LyrimuseIdentity.displayName }

    var body: some View {
        // 窗口副标题已经写着「软件更新」,页内不再画大标题(跟「歌词显示」页同一个理由)。
        SettingsPage(title: L10n.t("软件更新"), showsHeader: false) {
            statusCard
            installedCard
            automaticCard
            betaCard
            footer
        }
        // 语言切换时整页重建,理由见 AboutSettingsTab 那处注释。
        .id(L10n.current)
    }

    // MARK: 状态卡

    private var statusCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.system(size: 15, weight: .semibold))
                    subline
                }
                Spacer(minLength: 16)
                actions
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, 14)
            if case .failed(let message) = updater.flow {
                CardDivider()
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
                    .padding(.vertical, 10)
            }
            if let item, let notes = item.notesHTML, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CardDivider()
                ReleaseNotesView(source: notes, plainText: item.notesArePlainText)
                    .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
                    .padding(.vertical, 14)
            }
        }
    }

    private var headline: String {
        if let item { return "\(appName) \(item.version)" }
        return "\(appName) \(SparkleUpdaterManager.appVersionString)"
    }

    @ViewBuilder private var subline: some View {
        switch updater.flow {
        case .checking:
            spinnerLine(L10n.t("正在检查更新…"))
        case .downloading(let received, let expected):
            VStack(alignment: .leading, spacing: 4) {
                if let expected, expected > 0 {
                    ProgressView(value: Double(received), total: Double(expected))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(downloadProgressText(received: received, expected: expected))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: 260)
        case .extracting(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text(L10n.t("正在准备安装…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260)
        case .readyToInstall:
            secondaryLine(L10n.t("已下载，可以安装"))
        case .installing:
            spinnerLine(L10n.t("正在安装…"))
        case .failed:
            Text(L10n.t("更新失败"))
                .font(.system(size: 12))
                .foregroundStyle(.red)
        case .idle:
            if let item {
                if updater.installOnQuit {
                    secondaryLine(L10n.t("将在退出 Lyrimuse 时安装"))
                } else if item.downloaded {
                    secondaryLine(L10n.t("已下载，可以安装"))
                } else {
                    secondaryLine(itemMeta(item))
                }
            } else if let version = updater.updatedToVersion {
                secondaryLine(String(format: L10n.t("已更新到 %@"), version))
            } else {
                secondaryLine(L10n.t("已是最新版本"))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch updater.flow {
        case .checking, .downloading:
            Button(L10n.t("取消")) { updater.cancel() }
                .settingsGlassButtons()
        case .extracting:
            EmptyView()
        case .readyToInstall:
            HStack(spacing: 8) {
                Button(L10n.t("退出时安装")) { updater.installOnQuitInstead() }
                    .settingsGlassButtons()
                Button(L10n.t("立即重启")) { updater.installPendingUpdate() }
                    .settingsProminentGlassButton(tint: .accentColor)
            }
        case .installing(let applicationTerminated):
            if !applicationTerminated {
                Button(L10n.t("重试退出")) { updater.retryTerminatingForInstall() }
                    .settingsGlassButtons()
            }
        case .failed:
            Button(L10n.t("重试")) { updater.checkForUpdates() }
                .settingsGlassButtons()
        case .idle:
            if let item {
                HStack(spacing: 8) {
                    if item.downloaded || updater.installOnQuit {
                        Button(L10n.t("立即重启")) { updater.installPendingUpdate() }
                            .settingsProminentGlassButton(tint: .accentColor)
                    } else {
                        Button(L10n.t("立即更新")) { updater.installPendingUpdate() }
                            .settingsProminentGlassButton(tint: .accentColor)
                    }
                    // 系统设置那页的 ⓘ:去看这一版的完整说明(GitHub Release 页)。
                    Button {
                        NSWorkspace.shared.open(item.releaseURL)
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("查看发布页面"))
                    .accessibilityLabel(L10n.t("查看发布页面"))
                }
            } else {
                Button(L10n.t("检查更新…")) { updater.checkForUpdates() }
                    .settingsGlassButtons()
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    private func spinnerLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func secondaryLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「12.3 MB · 发布于 2026年9月13日」;appcast 没写大小 / 日期的那一半就不出现。
    private func itemMeta(_ item: SoftwareUpdateItem) -> String {
        var parts: [String] = []
        if item.contentLength > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(item.contentLength), countStyle: .file))
        }
        if let date = item.date {
            parts.append(String(format: L10n.t("发布于 %@"), Self.dateText(date)))
        }
        return parts.joined(separator: " · ")
    }

    private func downloadProgressText(received: UInt64, expected: UInt64?) -> String {
        let got = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
        guard let expected, expected > 0 else { return L10n.t("正在下载…") }
        return "\(got) / \(ByteCountFormatter.string(fromByteCount: Int64(expected), countStyle: .file))"
    }

    // MARK: 其余几张卡

    private var installedCard: some View {
        SettingsCard {
            SettingsRow(icon: "checkmark.seal", title: L10n.t("已安装")) {
                Text("\(appName) \(SparkleUpdaterManager.appVersionString) · \(Self.architectureName)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var automaticCard: some View {
        SettingsCard {
            SettingsCardHeader(title: L10n.t("自动更新"))
            CardDivider()
            SettingsRow(icon: "arrow.triangle.2.circlepath", title: L10n.t("自动检查")) {
                Toggle("", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            CardDivider()
            SettingsSubRow(title: L10n.t("自动下载并安装")) {
                Toggle("", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.automaticallyDownloadsUpdates = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                // 关掉自动检查后这一项在 Sparkle 那边根本不会被读到,置灰而不是藏起来。
                .disabled(!updater.automaticallyChecksForUpdates)
            }
        }
    }

    private var betaCard: some View {
        SettingsCard {
            // 语义与落盘见 SparkleUpdaterManager 头注与 15 章决策 11(机器专属键 np:receiveBetaUpdates)。
            SettingsRow(icon: "flask", title: L10n.t("测试版更新"), subtitle: L10n.t("预发布版本，可能不稳定")) {
                Toggle("", isOn: Binding(
                    get: { settings.receiveBetaUpdates },
                    set: { settings.receiveBetaUpdates = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }

    private var footer: some View {
        Text(lastCheckText)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
    }

    private var lastCheckText: String {
        guard let date = updater.lastUpdateCheckDate else { return L10n.t("还没有检查过更新") }
        return String(format: L10n.t("上次检查：%@"), Self.dateTimeText(date))
    }

    // MARK: 格式化

    private static var architectureName: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        // 跟界面语言走,不跟系统 Locale(理由见 L10n.locale 的注释)。
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}

// MARK: - 发版日志

/// appcast `<description>` 的 HTML(release.yml 用 split_release_notes.py 把 markdown 渲染成标题 / 列表 / 加粗 /
/// 链接的真 HTML,按 xml:lang 放两份,Sparkle 已按系统语言挑好一份)→ SwiftUI `Text`。
///
/// 走 `NSAttributedString(html:)` 解析,再把字体统一压成 13pt 系统字(标题与加粗 = semibold)、颜色换成
/// labelColor(HTML 默认黑字在深色模式下看不见)、链接保留。段落样式(列表缩进 / 段距)SwiftUI Text 不认,
/// 列表项靠转换时生成的「•⇥」字符仍能看出层次。转换只能在主线程做,结果按原文缓存,同一份说明只解一次。
private struct ReleaseNotesView: View {
    let source: String
    let plainText: Bool
    @State private var rendered: AttributedString?

    var body: some View {
        Group {
            if plainText {
                Text(source)
            } else if let rendered {
                Text(rendered)
            } else {
                Text(ReleaseNotesRenderer.strippedFallback(source))
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: source) {
            guard !plainText else { return }
            rendered = ReleaseNotesRenderer.render(html: source)
        }
    }
}

enum ReleaseNotesRenderer {
    @MainActor
    static func render(html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let parsed = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        let full = NSRange(location: 0, length: parsed.length)
        parsed.enumerateAttribute(.font, in: full) { value, range, _ in
            let old = value as? NSFont
            let traits = old?.fontDescriptor.symbolicTraits ?? []
            // HTML 里比正文大的(h2/h3)和 <strong> 都归成 semibold;其余一律 13pt regular。
            let emphasized = traits.contains(.bold) || (old?.pointSize ?? 13) > 13.5
            var font = NSFont.systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular)
            if traits.contains(.italic) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            parsed.addAttribute(.font, value: font, range: range)
        }
        parsed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        parsed.enumerateAttribute(.link, in: full) { value, range, _ in
            if value != nil { parsed.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range) }
        }
        // 解析器在末尾留的空行去掉,卡片底边才不会多出一截空白。
        while parsed.length > 0, let last = parsed.string.last, last.isNewline {
            parsed.deleteCharacters(in: NSRange(location: parsed.length - 1, length: 1))
        }
        return try? AttributedString(parsed, including: \.appKit)
    }

    /// 解析失败时的兜底:把标签剥掉当纯文本显示,总比一屏 HTML 源码强。
    static func strippedFallback(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
