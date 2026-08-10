import AppKit
import Foundation

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

            let alert = NSAlert()
            alert.messageText = L10n.t("在 iCloud 里发现一份 Lyrimuse 配置")
            alert.informativeText = detail + L10n.t("导入会带上账号和所有个人设置，随后重启 Lyrimuse。")
            alert.addButton(withTitle: L10n.t("导入并重启"))
            alert.addButton(withTitle: L10n.t("跳过"))
            // .accessory 策略的 App 不会自动抢到前台,不激活的话这个弹窗可能压在别的
            // 窗口底下 —— 用户只会觉得"装完什么都没发生"。
            NSApp.activate(ignoringOtherApps: true)

            guard alert.runModal() == .alertFirstButtonReturn else {
                continuation()
                return
            }
            ConfigPortability.importData(data)
            ConfigPortability.restartApp()
        }
    }
}
