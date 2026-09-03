import Foundation

/// 设置侧栏「播放器」项的健康判定(2026-09-03)。只认两种会让歌词直接停摆的硬故障,其余一律
/// 不报——徽标的价值在"平时不亮",常亮就没人看了。
///
/// 为什么是纯函数:判定规则(什么算故障、什么算"正常等待")是这条功能的全部内容,
/// 放在 Core 里让 selftest 钉住;真正去读权限/launchd 的那层在 App 侧
/// (`PlayerHealthMonitor`),那里只负责把读到的值填进 `Inputs`。
public enum PlayerHealth {
    public enum Warning: Equatable, CaseIterable, Sendable {
        /// 已选播放器含 Apple Music,且自动化权限被系统记为"拒绝"。播放器没在运行时权限
        /// 查询返回的是 notDetermined 而不是 denied,所以"播放器没开"天然不会触发这一条。
        case automationDenied
        /// 「后台采集服务」开关开着,launchd 里却没有活着的进程(没注册 / 崩溃循环)。
        /// 用户自己关掉服务不算故障。
        case collectorNotRunning
    }

    public struct Inputs: Equatable, Sendable {
        public var appleMusicSelected: Bool
        public var automationDenied: Bool
        public var collectorServiceEnabled: Bool
        public var collectorRunning: Bool

        public init(appleMusicSelected: Bool, automationDenied: Bool,
                    collectorServiceEnabled: Bool, collectorRunning: Bool) {
            self.appleMusicSelected = appleMusicSelected
            self.automationDenied = automationDenied
            self.collectorServiceEnabled = collectorServiceEnabled
            self.collectorRunning = collectorRunning
        }
    }

    /// 按严重程度排序:采集服务没在跑意味着**所有**播放器都拿不到歌词,排在前面。
    public static func warnings(_ inputs: Inputs) -> [Warning] {
        var out: [Warning] = []
        if inputs.collectorServiceEnabled && !inputs.collectorRunning { out.append(.collectorNotRunning) }
        if inputs.appleMusicSelected && inputs.automationDenied { out.append(.automationDenied) }
        return out
    }
}
