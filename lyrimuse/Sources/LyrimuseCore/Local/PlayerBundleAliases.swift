import AppKit

/// 同一个内置播放器的其他版本:另一个 bundle id、同一个开发者,按本体同一套行为认,没有逐个实测。系统报上来的这些 bundle id
/// 一进来就换成本体的(`canonical`,在 `MediaControlClient.reportingPlayerBundleID`),下游按 bundle id 收窄的判据照本体走;
/// 找它的进程、单问它的会话、判装没装、取图标时几个都试(`all(for:)`、`applicationURL(forBundleID:)`)。见 02 章决策 165。
public enum PlayerBundleAliases {
    public static let aliases: [String: PlaybackPlayer] = [
        "com.digipine.pineplayer.pro": .pinePlayer,
        "com.digipine.pineplayer.origin": .pinePlayer,
    ]

    /// 别名换成它所属的内置播放器的 bundle id;不是别名原样交回。纯函数,selftest 覆盖。
    public static func canonical(_ bundleID: String) -> String {
        aliases[bundleID]?.bundleIdentifier ?? bundleID
    }

    /// 这个 bundle id(本体或别名)所属播放器的全部 bundle id,本体在前、别名按字母序。纯函数,selftest 覆盖。
    public static func all(for bundleID: String) -> [String] {
        let main = canonical(bundleID)
        return [main] + aliases.filter { $0.value.bundleIdentifier == main }.map(\.key).sorted()
    }

    /// 装在这台 Mac 上的那一个(本体优先);都没装为 nil。
    public static func applicationURL(forBundleID bundleID: String) -> URL? {
        for id in all(for: bundleID) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }
}
