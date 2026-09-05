import SwiftUI
import LyrimuseCore

/// 设置窗口顶部的「配置文件损坏」告示(2026-09-05,借鉴清单 #46)。平时不渲染、不占高度。
///
/// 两份共享配置文件(config.json / lyrimuse-features.json)任一在启动时判定为损坏(见 Core
/// `JSONConfigDocument` 三态),对应 Store 的 `loadFailure` 非空、所有保存都被拒。这里说清三件事:哪份
/// 文件、为什么读不懂、现在保存已暂停;并给两个出口:「在 Finder 中显示」让用户自己修(修好重开 App 即可),
/// 「放弃坏文件并重建」把它挪到旁边(不删,`<文件名>.corrupt-<时间>`)再用当前值重建。
///
/// 挂在 NavigationSplitView 的 detail 列顶部(`safeAreaInset`),不挑分页:损坏是全局问题,用户在哪一页拨
/// 开关都会撞上;账号页自己那条红色 lastError 只在用户真去保存时才出现,不够早。
struct ConfigFileDamageBanner: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    @State private var busy = false

    var body: some View {
        if config.loadFailure != nil || features.loadFailure != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let reason = config.loadFailure {
                    row(url: ConfigStore.fileURL, reason: reason) {
                        await config.discardCorruptFileAndSave()
                    }
                }
                if let reason = features.loadFailure {
                    row(url: FeatureSettingsStore.fileURL, reason: reason) {
                        await features.discardCorruptFileAndSave()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    @ViewBuilder
    private func row(url: URL, reason: String, discard: @escaping @MainActor () async -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(String(format: L10n.t("配置文件 %@ 无法读取，为避免覆盖，所有保存已暂停"), url.lastPathComponent))
                    .font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    // 锁拉丁语区,理由同 SettingsRow 里那处注释(SF Symbols 的部分符号有 CJK 变体)。
                    .environment(\.locale, Locale(identifier: "en"))
            }
            Text(L10n.t("修好文件后重新打开 Lyrimuse；或放弃这份文件，用当前界面上的值重建（原文件会改名保留，不会删除）。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 技术原因原样给出(英文,来自 Foundation / DecodingError):只含位置、键名与期望类型,不含文件内容。
            Text(reason)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            HStack(spacing: 8) {
                Button(L10n.t("在访达中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button(L10n.t("放弃坏文件并重建")) {
                    busy = true
                    Task {
                        _ = await discard()
                        busy = false
                    }
                }
                .disabled(busy)
            }
            .controlSize(.small)
        }
    }
}
