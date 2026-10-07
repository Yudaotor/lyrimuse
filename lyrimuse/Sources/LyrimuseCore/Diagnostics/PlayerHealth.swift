import Foundation

/// 设置侧栏「播放器」项的健康判定:采集服务没在跑,以及选了的播放器要的权限没开(自动化、完全磁盘访问、
/// 辅助功能)。权限只替「选了 ∩ 本机装了」的播放器报;查不出结论的(播放器没在运行时的自动化、引擎还没探过的
/// 完全磁盘访问)不报。
///
/// 为什么是纯函数:判定规则(什么算故障、什么算"正常等待")是这条功能的全部内容,
/// 放在 Core 里让 selftest 钉住;真正去读权限/launchd 的那层在 App 侧
/// (`PlayerHealthMonitor`),那里只负责把读到的值填进 `Inputs`。
public enum PlayerHealth {
    public enum Warning: Equatable, CaseIterable, Sendable {
        /// 当前选择下需要自动化权限的播放器里,有本机装了、且没授权的:被系统记为拒绝,或在运行却还没授权过。
        /// 播放器没在运行时查询分不出「没问过」和「授权过」(都是 notDetermined),不报。
        case automationMissing
        /// 「后台采集服务」开关开着,launchd 里却没有活着的进程(没注册 / 崩溃循环)。
        /// 用户自己关掉服务不算故障。
        case engineNotRunning
        /// 需要完全磁盘访问的播放器里,引擎上报读它的容器被系统挡住了(只认明确被拒,还没探到不算)。
        case fullDiskAccessDenied
        /// 需要辅助功能权限的播放器(读界面上的播放时间校准进度,或按菜单栏切播放模式)在,App 却没有这项授权。
        /// 系统分不出「没问过」和「拒绝了」,两种都报。
        case accessibilityMissing
    }

    public struct Inputs: Equatable, Sendable {
        /// 自动化权限没开的播放器(`automationMissingPlayers` 算出来的)。
        public var automationMissingPlayers: [PlaybackPlayer]
        public var engineServiceEnabled: Bool
        public var engineRunning: Bool
        /// 完全磁盘访问被拒、读不到本机数据的播放器(`fullDiskAccessDeniedPlayers` 算出来的)。
        public var fullDiskAccessDeniedPlayers: [PlaybackPlayer]
        /// 缺辅助功能权限的播放器(`accessibilityMissingPlayers` 算出来的)。
        public var accessibilityMissingPlayers: [PlaybackPlayer]

        public init(automationMissingPlayers: [PlaybackPlayer],
                    engineServiceEnabled: Bool, engineRunning: Bool,
                    fullDiskAccessDeniedPlayers: [PlaybackPlayer] = [], accessibilityMissingPlayers: [PlaybackPlayer] = []) {
            self.automationMissingPlayers = automationMissingPlayers
            self.engineServiceEnabled = engineServiceEnabled
            self.engineRunning = engineRunning
            self.fullDiskAccessDeniedPlayers = fullDiskAccessDeniedPlayers
            self.accessibilityMissingPlayers = accessibilityMissingPlayers
        }
    }

    /// 按严重程度排序:采集服务没在跑意味着**所有**播放器都拿不到歌词,排在前面;自动化没开那几家读不准播放状态;
    /// 完全磁盘访问被拒少了本机歌词;缺辅助功能只是进度差一两秒或少了随机 / 循环键,排最后。
    public static func warnings(_ inputs: Inputs) -> [Warning] {
        var out: [Warning] = []
        if inputs.engineServiceEnabled && !inputs.engineRunning { out.append(.engineNotRunning) }
        if !inputs.automationMissingPlayers.isEmpty { out.append(.automationMissing) }
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

    /// 哪些播放器的自动化权限没开、要在徽标上报:当前选择需要权限的那几家(跟设置页权限卡、引导页那一步
    /// 同一份 `playersNeedingAutomation`,含「自动识别」时按超集算)∩ 本机装了 ∩ `isMissing`。
    /// 只看 Apple Music 会漏掉默认的「自动识别」和 Spotify。
    public static func automationMissingPlayers(
        selection: Set<PlaybackPlayer>, isInstalled: (PlaybackPlayer) -> Bool, isMissing: (PlaybackPlayer) -> Bool
    ) -> [PlaybackPlayer] {
        selection.playersNeedingAutomation.filter { isInstalled($0) && isMissing($0) }
    }

    /// 一家的自动化权限算不算没开:被拒算;还没授权过(`notDetermined`)只在它正在运行时算 ——
    /// 没在运行时查询拿不到结论,授权过的也报 notDetermined。查询超时(nil)不算。
    public static func automationIsMissing(_ status: AutomationAlert.Grant?, isRunning: Bool) -> Bool {
        switch status {
        case .denied: return true
        case .undetermined: return isRunning
        case .authorized, nil: return false
        }
    }
}
