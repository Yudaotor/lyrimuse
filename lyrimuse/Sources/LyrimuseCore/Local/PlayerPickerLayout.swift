import AppKit

/// 「选择播放器」网格(设置页「播放器」卡 + 引导页「选择播放器」那一步)的具体播放器摆哪几张卡。
/// 画法在 App 侧的 `PlayerPicker`,这里只放纯判断。
///
/// 「自动识别」是网格里的一张卡,勾没勾就看集合里有没有 `.auto` —— 跟
/// `MediaControlClient.fetchSnapshot` / collector `getState` 读的是同一份 `players`。见 docs 02「播放器选择」。
public enum PlayerPickerLayout {
    public struct Tiles: Equatable {
        /// 网格里直接摆出来的播放器,按传进来的顺序。
        public let main: [PlaybackPlayer]
        /// 收进末尾「更多播放器」那一格的,按传进来的顺序。
        public let more: [PlaybackPlayer]

        public init(main: [PlaybackPlayer], more: [PlaybackPlayer]) {
            self.main = main
            self.more = more
        }
    }

    /// `order` 里的 `.auto` 一律摘掉:「自动识别」那张卡由 `PlayerPicker` 单独排在后面。
    ///
    /// 装了的,加上**勾着但没装的**(不摆出来就没处取消勾选,比如从别的 Mac 导入的配置);其余没装的
    /// 进「更多」。勾没勾「自动识别」都是这一条:卡片随时能勾,没装的也得有地方勾上。
    public static func tiles(order: [PlaybackPlayer],
                             selected: Set<PlaybackPlayer>,
                             installed: Set<PlaybackPlayer>) -> Tiles {
        let concrete = order.filter { $0 != .auto }
        let main = concrete.filter { installed.contains($0) || selected.contains($0) }
        let shown = Set(main)
        return Tiles(main: main, more: concrete.filter { !shown.contains($0) })
    }

    /// 这台 Mac 上装了哪些内置播放器。按 bundle id 问 LaunchServices,装在哪个目录都算。
    public static func installedPlayers() -> Set<PlaybackPlayer> {
        Set(PlaybackPlayer.allCases.filter { player in
            player != .auto
                && !player.bundleIdentifier.isEmpty
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) != nil
        })
    }
}
