import Foundation
import ServiceManagement

/// 歌词引擎的 LaunchAgent 有没有被「系统设置 › 通用 › 登录项与扩展 › 允许在后台」关掉(15 章决策 116)。
/// 状态由 `SMAppService.statusForLegacyPlist(at:)` 给,launchctl 的报错和 `launchctl print` 都认不出这个原因。
public enum EngineBackgroundItem {
    /// 引擎起不来是不是因为被关掉了。只认 `.requiresApproval`:`.notRegistered` / `.notFound` 是系统还没登记或认不出
    /// 这份 plist,不等于被关,调用方照旧用原来的说法。引擎在跑就答否,不问系统。`override` 是调试注入,有值时以它为准。
    public static func blocksEngine(
        engineRunning: Bool, override: Bool?, status: () -> SMAppService.Status
    ) -> Bool {
        if let override { return override }
        guard !engineRunning else { return false }
        return status() == .requiresApproval
    }

    /// 诊断导出里那一行的值。
    public static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval (turned off in Login Items)"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
