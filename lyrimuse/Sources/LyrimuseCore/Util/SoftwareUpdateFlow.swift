import Foundation

/// 「软件更新」页的进行态。只描述"正在发生什么";"有没有查到新版本"另看 `SparkleUpdaterManager.pendingItem`。
public enum SoftwareUpdateFlow: Equatable, Sendable {
    case idle
    case checking
    /// expected 为 nil = Sparkle 还没报总长度,画不定长进度条。
    case downloading(received: UInt64, expected: UInt64?)
    case extracting(progress: Double)
    case readyToInstall
    case installing(applicationTerminated: Bool)
    case failed(message: String)

    /// 窗口关掉也该继续跑的阶段(下载 / 解包 / 安装),关窗时不动它。
    public var isBusyInBackground: Bool {
        switch self {
        case .downloading, .extracting, .installing: return true
        case .idle, .checking, .readyToInstall, .failed: return false
        }
    }
}

/// 页面发起检查时的两条规则。Sparkle 的 `checkForUpdates` 在这一轮会话正给用户看着时(攥着「找到了 / 下完待装」
/// 没答、下载解包中)不开新检查,只回一次 `showUpdateInFocus`,之后不会再有 `showUserInitiatedUpdateCheck`、
/// 找到 / 没找到这些回调;页面先进了「正在检查」就再也出不来。见 14 章决策 233。
public enum SoftwareUpdateCheckRules {
    /// 页面要不要发起检查(进「正在检查」并调 Sparkle)。holdingReply = 手里攥着 Sparkle 在等答复的闭包。
    public static func startsCheck(flow: SoftwareUpdateFlow, holdingReply: Bool, canCheck: Bool) -> Bool {
        guard canCheck, !holdingReply else { return false }
        switch flow {
        case .idle, .failed: return true
        case .checking, .downloading, .extracting, .readyToInstall, .installing: return false
        }
    }

    /// 收到 `showUpdateInFocus` 时页面该回到的进行态。flowBeforeCheck = 页面发起、Sparkle 还没开始的那次检查
    /// 之前的进行态(nil = 没有这样一次检查)。
    public static func flowAfterFocusRequest(current: SoftwareUpdateFlow,
                                             flowBeforeCheck: SoftwareUpdateFlow?) -> SoftwareUpdateFlow {
        guard let before = flowBeforeCheck, current == .checking else { return current }
        return before == .checking ? .idle : before
    }
}
