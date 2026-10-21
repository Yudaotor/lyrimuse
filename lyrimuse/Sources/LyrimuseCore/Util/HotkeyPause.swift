import Foundation

/// 全局快捷键为什么暂停着。几个暂停原因各管各的(菜单跟踪、录制快捷键),都撤了才重新打开 ——
/// 两处各自直接写同一个开关的话,录制中途开关一次菜单,菜单收起就把快捷键提前打开了。
public struct HotkeyPause: Equatable, Sendable {
    public enum Reason: Hashable, Sendable {
        case menuTracking
        case recording
    }

    public private(set) var reasons: Set<Reason> = []

    public init() {}

    /// 快捷键此刻该不该响应。
    public var enabled: Bool { reasons.isEmpty }

    public mutating func set(_ reason: Reason, paused: Bool) {
        if paused { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}
