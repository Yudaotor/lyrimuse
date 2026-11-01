import AppKit
import LyrimuseCore
import SwiftUI

/// 设置 › 歌词 › 歌词库里的「歌词导入」卡:导入歌词文件夹、批量导入方式、监视文件夹、导入库(11 章决策 154)。导入和导入库的
/// 面板在歌词管理里,这里的按钮打开歌词管理再弹面板(`AppActions.requestLyricsManagerSheet`);导入方式、监视文件夹跟歌词管理
/// 那边是同一份设置。
struct LyricsImportSettingsCard: View {
    @AppStorage(LyricsBatchImport.modeDefaultsKey) private var mode: LyricsBatchImport.Mode = .prefer
    @ObservedObject private var watcher = LyricsImportWatcher.shared

    var body: some View {
        SettingsCard(cornerRadius: 18) {
            SettingsCardHeader(title: L10n.t("歌词导入"))
            SettingsRow(
                icon: "square.and.arrow.down.on.square",
                title: L10n.t("导入歌词文件夹"),
                subtitle: L10n.t("将文件夹中的歌词文件对应到歌词库中的歌曲，导入前可预览")
            ) {
                Button(L10n.t("导入…")) { chooseImportFolder() }
                    .fixedSize()
            }
            CardDivider()
            // 副标题只说明选中的那一档。
            SettingsRow(icon: "lock", title: L10n.t("文件夹导入方式"), subtitle: mode.explanation) {
                SettingsGlassMenuPicker(selection: $mode, options: LyricsBatchImport.Mode.allCases, label: \.title, compact: true)
                    .fixedSize()
            }
            CardDivider()
            SettingsRow(
                icon: "eye",
                title: L10n.t("监视文件夹"),
                subtitle: L10n.t("文件夹中新增或修改的歌词文件会自动导入：对应的歌曲没有歌词时直接补上，已有歌词的不变"),
                footer: watcher.folder != nil ? watcher.problem.map { problem in
                    AnyView(Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange))
                } : nil
            ) {
                // 按钮按完整宽度排,放不下时路径先缩短(同「歌词文件夹」那一行)。
                HStack(spacing: 8) {
                    if let folder = watcher.folder {
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(-1)
                            .help(folder.path)
                    }
                    Button(watcher.folder == nil ? L10n.t("选择…") : L10n.t("更换…")) { chooseWatchFolder() }
                        .fixedSize()
                    if watcher.folder != nil {
                        Button(L10n.t("停止监视")) { watcher.setFolder(nil) }
                            .fixedSize()
                    }
                }
            }
            CardDivider()
            SettingsRow(icon: "tray.full", title: L10n.t("导入库"), subtitle: L10n.t("查看和删除导入的歌词")) {
                Button(L10n.t("查看…")) { AppActions.shared.requestLyricsManagerSheet(.importLibrary) }
                    .fixedSize()
            }
        }
        .settingsGlassButtons()
    }

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("导入")
        panel.message = L10n.t("选择存放歌词文件的文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppActions.shared.requestLyricsManagerSheet(.importFolder(url))
    }

    private func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("监视")
        panel.message = L10n.t("选择要监视的歌词文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !watcher.setFolder(url) { LyricsImportWatcher.showOverlapAlert() }
    }
}
