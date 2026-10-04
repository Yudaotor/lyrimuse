import Foundation

/// 设置侧栏「播放器」项的健康判定。只报当前选择下真的会碍事的权限 / 服务问题:歌词直接停摆的
/// (采集服务没在跑、自动化被拒),以及读不到某家本机数据、或没法校准某家进度的(完全磁盘访问被拒、
/// 没有辅助功能权限)。都只替「选了 ∩ 本机装了」的播放器报,其余一律不报——徽标的价值在"平时不亮",
/// 常亮就没人看了。
///
/// 为什么是纯函数:判定规则(什么算故障、什么算"正常等待")是这条功能的全部内容,
/// 放在 Core 里让 selftest 钉住;真正去读权限/launchd 的那层在 App 侧
/// (`PlayerHealthMonitor`),那里只负责把读到的值填进 `Inputs`。
public enum PlayerHealth {
    public enum Warning: Equatable, CaseIterable, Sendable {
        /// 当前选择下需要自动化权限的播放器里,有本机装了、且被系统记为"拒绝"的。播放器没在
        /// 运行时权限查询返回的是 notDetermined 而不是 denied,所以"播放器没开"天然不会触发这一条。
        case automationDenied
        /// 「后台采集服务」开关开着,launchd 里却没有活着的进程(没注册 / 崩溃循环)。
        /// 用户自己关掉服务不算故障。
        case engineNotRunning
        /// 需要完全磁盘访问的播放器里,引擎上报读它的容器被系统挡住了(只认明确被拒,还没探到不算)。
        case fullDiskAccessDenied
        /// 需要辅助功能权限的播放器(读它界面上的播放时间校准进度)在,App 却没有这项授权。系统分不出
        /// 「没问过」和「拒绝了」,两种都报。
        case accessibilityMissing
    }

    public struct Inputs: Equatable, Sendable {
        /// 自动化权限被拒的播放器(`automationDeniedPlayers` 算出来的)。
        public var automationDeniedPlayers: [PlaybackPlayer]
        public var engineServiceEnabled: Bool
        public var engineRunning: Bool
        /// 完全磁盘访问被拒、读不到本机数据的播放器(`fullDiskAccessDeniedPlayers` 算出来的)。
        public var fullDiskAccessDeniedPlayers: [PlaybackPlayer]
        /// 缺辅助功能权限、没法校准进度的播放器(`accessibilityMissingPlayers` 算出来的)。
        public var accessibilityMissingPlayers: [PlaybackPlayer]

        public init(automationDeniedPlayers: [PlaybackPlayer],
                    engineServiceEnabled: Bool, engineRunning: Bool,
                    fullDiskAccessDeniedPlayers: [PlaybackPlayer] = [], accessibilityMissingPlayers: [PlaybackPlayer] = []) {
            self.automationDeniedPlayers = automationDeniedPlayers
            self.engineServiceEnabled = engineServiceEnabled
            self.engineRunning = engineRunning
            self.fullDiskAccessDeniedPlayers = fullDiskAccessDeniedPlayers
            self.accessibilityMissingPlayers = accessibilityMissingPlayers
        }
    }

    /// 按严重程度排序:采集服务没在跑意味着**所有**播放器都拿不到歌词,排在前面;自动化被拒那几家读不到播放状态;
    /// 完全磁盘访问被拒少了本机歌词;缺辅助功能只是进度差一两秒,排最后。
    public static func warnings(_ inputs: Inputs) -> [Warning] {
        var out: [Warning] = []
        if inputs.engineServiceEnabled && !inputs.engineRunning { out.append(.engineNotRunning) }
        if !inputs.automationDeniedPlayers.isEmpty { out.append(.automationDenied) }
        if !inputs.fullDiskAccessDeniedPlayers.isEmpty { out.append(.fullDiskAccessDenied) }
        if !inputs.accessibilityMissingPlayers.isEmpty { out.append(.accessibilityMissing) }
        return out
    }

    /// 完全磁盘访问要报哪几家:设置页那张卡摆出来的那几家(`visible` = 需要 ∩ 装了,见 `FullDiskAccessPermission`),
    /// 引擎上报的结论是明确被拒时才报;还没探到(`.unknown`)不报。
    public static func fullDiskAccessDeniedPlayers(visible: [PlaybackPlayer], grant: LocalCacheAccess.Grant) -> [PlaybackPlayer] {
        grant == .denied ? visible : []
    }

    /// 辅助功能要报哪几家:设置页那张卡摆出来的那几家(`visible` = 需要 ∩ 装了,见 `AccessibilityPermission`),App 没授权时报。
    public static func accessibilityMissingPlayers(visible: [PlaybackPlayer], trusted: Bool) -> [PlaybackPlayer] {
        trusted ? [] : visible
    }

    /// 哪些播放器的自动化权限被拒、要在徽标上报:当前选择需要权限的那几家(跟设置页权限卡、引导页那一步
    /// 同一份 `playersNeedingAutomation`,含「自动识别」时按超集算)∩ 本机装了 ∩ 系统记为拒绝。
    /// 只看 Apple Music 会漏掉默认的「自动识别」和 Spotify。
    public static func automationDeniedPlayers(
        selection: Set<PlaybackPlayer>, isInstalled: (PlaybackPlayer) -> Bool, isDenied: (PlaybackPlayer) -> Bool
    ) -> [PlaybackPlayer] {
        selection.playersNeedingAutomation.filter { isInstalled($0) && isDenied($0) }
    }
}
