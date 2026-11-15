import AppKit

/// 同一个内置播放器的其他版本:另一个 bundle id、同一个开发者,按本体同一套行为认,没有逐个实测。系统报上来的这些 bundle id
/// 一进来就换成本体的(`canonical`:`MediaControlClient.reportingPlayerBundleID`、取封面的载荷、单问到的那份),下游按 bundle id
/// 收窄的判据照本体走;找它的进程、单问它的会话和封面、判装没装、取图标、启动它时几个都试(`all(for:)`、`inProbeOrder(for:)`、
/// `applicationURL(forBundleID:)`、`isInstalled(_:)`)。见 02 章决策 165。
///
/// `otherClients` 是另一个程序的那几个(iPad 版网易云、iPad 版 QQ 音乐):报给系统的会话按本体认,菜单、界面、本机数据却跟本体
/// 不一样,按本体的程序界面或数据去找它的地方(进程号、辅助功能 / 完全磁盘访问那两行)不算它。见 02 章决策 198、204。
public enum PlayerBundleAliases {
    public static let aliases: [String: PlaybackPlayer] = [
        "com.digipine.pineplayer.pro": .pinePlayer,
        "com.digipine.pineplayer.origin": .pinePlayer,
        "com.audirvana.Audirvana-Origin": .audirvana,
        NetEaseIPadNowPlaying.bundleID: .netease,
        QQIPadNowPlaying.bundleID: .qqMusic,
    ]

    public static let otherClients: Set<String> = [NetEaseIPadNowPlaying.bundleID, QQIPadNowPlaying.bundleID]

    /// 别名换成它所属的内置播放器的 bundle id;不是别名原样交回。纯函数,selftest 覆盖。
    public static func canonical(_ bundleID: String) -> String {
        aliases[bundleID]?.bundleIdentifier ?? bundleID
    }

    /// 这个 bundle id(本体或别名)所属播放器的全部 bundle id,本体在前、别名按字母序;`includingOtherClients` 为 false 时
    /// 不算 `otherClients`。纯函数,selftest 覆盖。
    public static func all(for bundleID: String, includingOtherClients: Bool = true) -> [String] {
        let main = canonical(bundleID)
        return [main] + aliases.filter {
            $0.value.bundleIdentifier == main && (includingOtherClients || !otherClients.contains($0.key))
        }.map(\.key).sorted()
    }

    /// 单问会话、封面时的次序:正在运行的排前面(常见情况第一次就问到),其余照 `all(for:)`。
    public static func inProbeOrder(for bundleID: String) -> [String] {
        let ids = all(for: bundleID)
        let running = ids.filter(isRunning)
        return running + ids.filter { !running.contains($0) }
    }

    /// 这个 bundle id 的 App 此刻在跑。
    public static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// 正在运行的那一个的 App 包,其次装在这台 Mac 上的(本体优先);都没装为 nil。
    public static func applicationURL(forBundleID bundleID: String, includingOtherClients: Bool = true) -> URL? {
        let ids = all(for: bundleID, includingOtherClients: includingOtherClients)
        for id in ids {
            if let url = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL { return url }
        }
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    /// 向这个内置播放器查、要「自动化」权限时对准的 bundle id:在跑的那个版本,其次装着的(本体优先),都没装为本体。
    /// 授权是按 bundle id 记的,只装了别的版本(Audirvana Origin)时问本体永远问不到结论。`otherClients` 不算。见 02 章决策 261。
    public static func automationBundleID(for player: PlaybackPlayer) -> String {
        guard !player.bundleIdentifier.isEmpty else { return player.bundleIdentifier }
        let ids = all(for: player.bundleIdentifier, includingOtherClients: false)
        // 只有本体时三条路都落到它,不用问在不在跑、装没装:设置页每拍都调,问一次在跑的就同步等 launchservicesd 一次。
        guard ids.count > 1 else { return player.bundleIdentifier }
        return ids.first(where: isRunning)
            ?? ids.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            ?? player.bundleIdentifier
    }

    /// 这个内置播放器(本体或别的版本)装在这台 Mac 上没有。只问 LaunchServices 登记的 App 位置(本进程里有缓存),不经
    /// `applicationURL` 先翻在跑的那份:那一步对在跑的 App 要同步等 launchservicesd 三次,设置页、引导页每次重画、每拍都调。
    /// 在跑的 App 都登记过,结论一样。见 02 章决策 262。
    public static func isInstalled(_ player: PlaybackPlayer, includingOtherClients: Bool = true) -> Bool {
        !player.bundleIdentifier.isEmpty
            && all(for: player.bundleIdentifier, includingOtherClients: includingOtherClients)
                .contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}
