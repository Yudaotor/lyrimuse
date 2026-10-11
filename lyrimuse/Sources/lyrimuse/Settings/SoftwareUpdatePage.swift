import AppKit
import LyrimuseCore
import SwiftUI

/// 设置 → 「软件更新」页(仿系统设置「软件更新」那页,见 14 章决策 #25、78)。
///
/// 从上到下:状态卡(App 图标 + 「Lyrimuse 1.11.0」+ 当前版本 / 大小 / 日期,或检查 / 下载 / 解包进度,或
/// 「已是最新版本 · 上次检查」+ 右侧动作);有新版本时一张发版说明卡(超过约六行折起,底下「查看完整说明」去发布页),
/// 没有时一行「本版更新内容」;最后「更新设置」卡(自动检查 / 自动下载并安装 / 测试版更新)。
/// 数据与动作全在 `SparkleUpdaterManager`(`flow` 状态机 + `pendingItem`),这里只画。
///
/// 页面从三处进:侧栏「有软件更新可用」那一行(只在有新版本时存在)、「关于 › 更新与帮助 › 软件更新」、以及任何
/// 「检查更新」动作(菜单栏右键菜单 / 面板底栏)—— 检查的过程与结果都显示在这里,没有 Sparkle 的弹窗。
struct SoftwareUpdatePage: View {
    @ObservedObject private var updater = SparkleUpdaterManager.shared
    /// 只为「测试版更新」那一个开关订阅。
    @ObservedObject private var settings = AppSettings.shared

    private var item: SoftwareUpdateItem? { updater.shownItem }
    private var appName: String { LyrimuseIdentity.displayName }
    private var currentVersion: String { SparkleUpdaterManager.appVersionString }

    /// 发版说明折起时的高度,约六行 13pt。
    private static let notesCollapsedHeight: CGFloat = 132

    var body: some View {
        // 窗口副标题已经写着「软件更新」,页内不再画大标题(跟「歌词显示」页同一个理由)。
        SettingsPage(title: L10n.t("软件更新"), showsHeader: false) {
            VStack(spacing: 14) {
                statusCard
                if let item {
                    notesCard(item)
                } else {
                    currentReleaseCard
                }
                settingsCard
            }
            .background { LastfmGlassGlow() }
        }
        // 语言切换时整页重建,理由见 AboutSettingsTab 那处注释。
        .id(L10n.current)
    }

    // MARK: 状态卡

    private var statusCard: some View {
        SettingsCard(cornerRadius: 18) {
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
        }
    }

    private var headline: String {
        if let item { return "\(appName) \(item.version)" }
        return "\(appName) \(currentVersion)"
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
            secondaryLine(L10n.t("已下载，可安装"))
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
                    secondaryLine(L10n.t("已下载，可安装"))
                } else {
                    secondaryLine(itemMeta(item))
                }
            } else if let version = updater.updatedToVersion {
                secondaryLine(String(format: L10n.t("已更新到 %@"), version))
            } else if let date = updater.lastUpdateCheckDate {
                // 上次检查时间放在这里而不是页脚:紧挨着「检查更新」按钮,一眼看得出自动检查是不是真的在跑。
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    secondaryLine(L10n.t("已是最新版本") + " · "
                                  + String(format: L10n.t("上次检查：%@"), Self.dateTimeText(date)))
                }
            } else {
                secondaryLine(L10n.t("尚未检查更新"))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch updater.flow {
        case .checking, .downloading:
            Button(L10n.t("取消")) { updater.cancel() }
                .settingsGlassButtons()
                .buttonBorderShape(.capsule)
        case .extracting:
            EmptyView()
        case .readyToInstall:
            HStack(spacing: 8) {
                Button(L10n.t("退出时安装")) { updater.installOnQuitInstead() }
                    .settingsGlassButtons()
                    .buttonBorderShape(.capsule)
                Button(L10n.t("立即重启")) { updater.installPendingUpdate() }
                    .settingsProminentGlassButton(tint: .accentColor)
            }
        case .installing(let applicationTerminated):
            if !applicationTerminated {
                Button(L10n.t("重试退出")) { updater.retryTerminatingForInstall() }
                    .settingsGlassButtons()
                    .buttonBorderShape(.capsule)
            }
        case .failed:
            Button(L10n.t("重试")) { updater.checkForUpdates() }
                .settingsGlassButtons()
                .buttonBorderShape(.capsule)
        case .idle:
            if let item {
                if item.downloaded || updater.installOnQuit {
                    Button(L10n.t("立即重启")) { updater.installPendingUpdate() }
                        .settingsProminentGlassButton(tint: .accentColor)
                } else {
                    Button(L10n.t("立即更新")) { updater.installPendingUpdate() }
                        .settingsProminentGlassButton(tint: .accentColor)
                }
            } else {
                Button(L10n.t("检查更新…")) { updater.checkForUpdates() }
                    .settingsGlassButtons()
                    .buttonBorderShape(.capsule)
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

    /// 「当前 1.10.0 · 12.3 MB · 发布于 2026年9月13日」;appcast 没写大小 / 日期的那一半就不出现。
    /// 页上没有单独的「已安装」一行,当前版本只在这里出现。
    private func itemMeta(_ item: SoftwareUpdateItem) -> String {
        var parts = [String(format: L10n.t("当前 %@"), currentVersion)]
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

    // MARK: 发版说明

    /// 新版本的发版说明。超过约六行就折起(底部渐隐),「查看完整说明」去这一版的发布页;appcast 没带说明时只剩这个链接。
    private func notesCard(_ item: SoftwareUpdateItem) -> some View {
        SettingsCard(cornerRadius: 18) {
            SettingsCardHeader(title: String(format: L10n.t("%@ 更新内容"), item.version))
            if let notes = item.notesHTML, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ReleaseNotesView(source: notes, plainText: item.notesArePlainText,
                                 collapsedHeight: Self.notesCollapsedHeight)
                    .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
                    .padding(.top, 2)
            }
            Button {
                NSWorkspace.shared.open(item.releaseURL)
            } label: {
                HStack(spacing: 3) {
                    Text(L10n.t("查看完整说明"))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    /// 没有新版本时的一行:去当前这一版的发布页,装完新版后回头看改了什么。
    private var currentReleaseCard: some View {
        SettingsCard(cornerRadius: 18) {
            SettingsLinkRow(icon: "sparkles",
                            title: String(format: L10n.t("%@ 更新内容"), currentVersion),
                            subtitle: L10n.t("在 GitHub 查看这一版的发布说明"),
                            opensExternally: true) {
                NSWorkspace.shared.open(UpdateChannel.releasePageURL(displayVersion: currentVersion))
            }
        }
    }

    // MARK: 更新设置

    private var settingsCard: some View {
        SettingsCard(cornerRadius: 18) {
            SettingsCardHeader(title: L10n.t("更新设置"))
            // 「每天」是 Sparkle 默认的检查间隔(Info.plist 没设 SUScheduledCheckInterval);改了间隔要同步改这句。
            SettingsRow(icon: "arrow.triangle.2.circlepath", title: L10n.t("自动检查"),
                        subtitle: L10n.t("每天检查一次新版本")) {
                Toggle("", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
            }
            CardDivider()
            // 自动下好的包在 dismiss 后由 Sparkle 在退出时装(见 SparkleUpdaterManager 的 installOnQuit)。
            SettingsRow(icon: "arrow.down.circle", title: L10n.t("自动下载并安装"),
                        subtitle: L10n.t("在后台下载，退出 Lyrimuse 时安装")) {
                Toggle("", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.automaticallyDownloadsUpdates = $0 }
                ))
                // 关掉自动检查后这一项在 Sparkle 那边根本不会被读到,置灰而不是藏起来。
                .disabled(!updater.automaticallyChecksForUpdates)
            }
            CardDivider()
            // 语义与落盘见 SparkleUpdaterManager 头注与 15 章决策 11(机器专属键 np:receiveBetaUpdates)。
            SettingsRow(icon: "flask", title: L10n.t("测试版更新"), subtitle: L10n.t("预发布版本，可能不稳定")) {
                Toggle("", isOn: Binding(
                    get: { settings.receiveBetaUpdates },
                    set: { settings.receiveBetaUpdates = $0 }
                ))
            }
        }
    }

    // MARK: 格式化

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
/// 走 `NSAttributedString(html:)` 解析,再把字体统一压成 13pt 系统字(标题与加粗 = semibold)、正文用
/// secondaryLabelColor、标题与加粗用 labelColor(系统「设置 → 软件更新」那块说明就是这个层次:说明文字
/// 比标题浅一档;HTML 默认的黑字则在深色模式下直接看不见)、链接保留。段落样式(列表缩进 / 段距)SwiftUI Text 不认,
/// 列表项靠转换时生成的「•⇥」字符仍能看出层次。转换只能在主线程做,结果按原文缓存,同一份说明只解一次。
private struct ReleaseNotesView: View {
    let source: String
    let plainText: Bool
    /// 给了就最多这么高,超出的部分底部渐隐;nil = 全部展开。
    var collapsedHeight: CGFloat?
    @State private var rendered: AttributedString?
    @State private var naturalHeight: CGFloat = 0

    private var overflows: Bool {
        guard let collapsedHeight else { return false }
        return naturalHeight > collapsedHeight + 1
    }

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
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { naturalHeight = $0 }
        .frame(maxHeight: collapsedHeight, alignment: .top)
        .clipped()
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: overflows ? 0.7 : 1),
                                   .init(color: overflows ? .clear : .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
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
            // 颜色跟字重一起定:正文次要色、标题与加粗主色。 别再在这之后统一刷一遍 labelColor,
            // 那会把这层层次抹平。
            parsed.addAttribute(.foregroundColor,
                                value: emphasized ? NSColor.labelColor : NSColor.secondaryLabelColor,
                                range: range)
        }
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
