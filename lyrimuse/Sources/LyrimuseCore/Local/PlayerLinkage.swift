import Foundation

/// 「与播放器联动」三件事(打开 Lyrimuse 时启动 / 跟随播放器启动 / 跟随播放器退出)共用的纯判定(2026-09-03)。
///
/// 2026-09-01 播放器改成多选之后,原来的两个布尔开关回答不了"到底跟哪个播放器绑定":「打开 Lyrimuse 时
/// 启动 X」只敢在恰好选了一个具体播放器时显示,「跟随播放器启动」在多选 / 自动识别下盯的是整个集合。
/// 用户 2026-09-03 拍板:三件事全部改成**逐播放器勾选**,设置里重新设计成一排播放器图标芯片。
/// 这里只放不碰 UI、不碰磁盘的判定,selftest 钉着;存储在 AppSettings / FeatureSettingsStore,监听在
/// App 侧 PlayerQuitWatcher,collector 侧对称的候选逻辑在 companionlaunch.go。
public enum PlayerLinkage {
    /// 可供勾选的候选:选中集合里的具体播放器;选了「自动识别」时是全部五个已知播放器(自动识别可能跟着
    /// 任何一个走,auto 是超集)。YouTube Music 不在其中 —— 它是浏览器里的网页,浏览器退出不等于播放器退出,
    /// 也没有一个可以"启动"的 App。
    public static func candidates(selectedPlayers: Set<PlaybackPlayer>) -> Set<PlaybackPlayer> {
        if selectedPlayers.contains(.auto) {
            return Set(PlaybackPlayer.allCases).subtracting([.auto])
        }
        return selectedPlayers.subtracting([.auto])
    }

    /// 一项联动实际生效的集合 = 用户勾的 ∩ 候选。取消选中某个播放器后它在联动里就不再算数,但勾选记录
    /// 保留 —— 重新选回来时联动自动恢复,不用再勾一遍。
    public static func effective(_ chosen: Set<PlaybackPlayer>, selectedPlayers: Set<PlaybackPlayer>) -> Set<PlaybackPlayer> {
        chosen.intersection(candidates(selectedPlayers: selectedPlayers))
    }

    /// 「跟随退出」判定:刚退出的那个在绑定集合里,且绑定集合里已经**一个都不在跑**才算。绑了两个只退一个
    /// 不退 —— 用户可能只是换播放器听。
    public static func shouldQuit(terminatedBundleID: String, boundBundleIDs: Set<String>, runningBundleIDs: Set<String>) -> Bool {
        guard boundBundleIDs.contains(terminatedBundleID) else { return false }
        return boundBundleIDs.isDisjoint(with: runningBundleIDs)
    }

    /// 宽限期(秒)。播放器崩溃自动重启、用户手动重启、Spotify 更新后重启都会让进程短暂消失,被参考的做法
    /// 没有宽限、会让歌词整个消失再出现一次;5 秒内任一个绑定的播放器又起来就取消。
    public static let quitGraceSeconds: TimeInterval = 5

    /// 老配置迁移(布尔年代 → 集合):
    /// - 「打开 Lyrimuse 时启动 X」(`requiresSole`):当年只在唯一具体播放器时才显示开关,true 就迁成那一个;
    ///   当年含糊(纯 auto / 两个以上)开关本来就隐藏着,迁成空。
    /// - 「跟随播放器启动」:true 迁成当时的全部候选(collector 当年盯的就是这个范围)。
    public static func migratedLaunchSet(legacyEnabled: Bool, selectedPlayers: Set<PlaybackPlayer>, requiresSole: Bool) -> Set<PlaybackPlayer> {
        guard legacyEnabled else { return [] }
        if requiresSole {
            return selectedPlayers.soleExplicitPlayer.map { [$0] } ?? []
        }
        return candidates(selectedPlayers: selectedPlayers)
    }
}
