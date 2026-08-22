import AppKit
import Foundation
import LyrimuseCore

/// 新电脑第一次启动时,如果 iCloud 里已经有一份配置,问一句要不要导入。
///
/// 这是"换电脑"这条路的另一半:旧机器把配置存进 iCloud Drive 的 Lyrimuse 文件夹
/// (设置 → 通用 → iCloud 配置),新机器装好后自己发现它。
///
/// ## 刻意问一句,而不是静默导入
///
/// 探测到就直接套上去更省事,但那份配置里有账号 token 和密钥:同一台 Mac 上换个用户、
/// 或者共用了 iCloud 账号的家庭成员,一装上 Lyrimuse 就被静默登进了别人的 Last.fm。
/// 问一句的成本是一次点击,省下的是这个。
///
/// ## 时序
///
/// 挂在"决定要不要弹引导向导"那一步之前(MenuBarMenu 里),两条路互斥地接下去:
///
///   - 用户选导入 → 写配置 → 重启。重启后 hasCompletedOnboarding 仍是 false(它刻意
///     不跟着导出走,见 ConfigPortability),所以引导照样会走 —— 新机器的自动化权限、
///     常驻服务本来就得各自重新授权/重新装,这是对的。
///   - 用户跳过 / iCloud 里没有 / 文件还没下载下来 → 原样走引导。
enum ICloudConfigImportPrompt {
    /// 需要的话问一句;不管走哪条路,最后都会调一次 `continuation`(除了"导入并重启"那条,
    /// 那条会直接重启进程,后面没有"接下去"了)。
    @MainActor
    static func offerIfNeeded(then continuation: @escaping () -> Void) {
        let settings = AppSettings.shared
        guard !settings.hasOfferedICloudImport,
              let snapshot = ICloudConfigStore.latestSnapshot()
        else {
            continuation()
            return
        }

        Task { @MainActor in
            // 自动这条路用短一点的超时:超了就安静地走引导,别让用户对着空屏幕干等。
            // 设置里那个手动按钮用完整超时(20s),想等的人可以在那儿等。
            guard let data = await ICloudConfigStore.read(snapshot.url, timeout: 8) else {
                // 不置 hasOfferedICloudImport —— 这次是"没能问出口",不是"问过了",
                // 下次启动 iCloud 同步好了再问。
                continuation()
                return
            }
            settings.hasOfferedICloudImport = true

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let when = formatter.string(from: snapshot.exportedAt ?? snapshot.modifiedAt)
            let detail: String
            if let device = snapshot.deviceName, !device.isEmpty {
                detail = String(format: L10n.t("导出时间 %1$@，来自 %2$@。"), when, device)
            } else {
                detail = String(format: L10n.t("导出时间 %@。"), when)
            }

            // 兄弟歌词包(同名、-Config- 换成 -Lyrics-)。这条是"换新 Mac 第一次开机"的主
            // 路径,给的超时比配置那份更宽:歌词包 6 MB 上下,而配置只有几十 KB —— 用同一个
            // 8 秒会让歌词大概率静默落空,而这一步落空恰恰是用户最疼的(几千首歌的校正值
            // 全查不到)。失败**不阻断**导入:设置照样恢复,歌词之后可以在设置页手动再导。
            let sidecarURL = snapshot.url.deletingLastPathComponent().appendingPathComponent(
                LyricsBackupArchive.sidecarName(forConfigName: snapshot.url.lastPathComponent))
            let lyricsData = await ICloudConfigStore.read(sidecarURL, timeout: 60)
            let lyricsCount = lyricsData == nil ? 0 : (await LyricsBackupStore.peek(lyricsData!)?.files ?? 0)

            let alert = NSAlert()
            alert.messageText = L10n.t("在 iCloud 里发现一份 Lyrimuse 备份")
            let lyricsLine = lyricsCount > 0
                ? String(format: L10n.t("其中含 %@ 个歌词文件，会一并恢复。"), "\(lyricsCount)")
                : ""
            alert.informativeText = detail + L10n.t("导入会带上账号和所有个人设置，随后重启 Lyrimuse。") + lyricsLine
            alert.addButton(withTitle: L10n.t("导入并重启"))
            alert.addButton(withTitle: L10n.t("跳过"))
            // .accessory 策略的 App 不会自动抢到前台,不激活的话这个弹窗可能压在别的
            // 窗口底下 —— 用户只会觉得"装完什么都没发生"。
            NSApp.activate(ignoringOtherApps: true)

            guard alert.runModal() == .alertFirstButtonReturn else {
                continuation()
                return
            }
            await ConfigPortability.importData(data)
            // ⚠️ 必须排在 importData 之后:歌词落点是 features.lyricsDir,而那个文件是
            // importData 刚写的(见 LyricsBackupStore.restore 的注释)。
            if let lyricsData {
                await LyricsBackupStore.restore(from: lyricsData)
            }
            // 探测范围比写入范围大 —— 这份很可能来自 Dropbox 之类而不是 iCloud。
            // 不对齐的话,用户之后点"更新备份"会写去 iCloud,备份就分裂成两半了。
            ICloudConfigStore.adoptFolder(snapshot.folderURL)
            ConfigPortability.restartApp()
        }
    }
}
