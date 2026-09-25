import Foundation

/// App 侧 iTunes Search(`itunes.apple.com/search`)的限流退避,口径同 collector `apple.go` 的
/// `noteITunesSearchStatus`:429 按 Retry-After(没给默认 60 秒、封顶 300 秒),403 固定 30 秒且
/// 不缩短已有的更长窗口,其余状态码清掉窗口。两边的数字要一起改。
///
public enum ITunesSearchBackoff {
    public static let forbiddenCooldown: TimeInterval = 30
    public static let retryAfterDefault: TimeInterval = 60
    public static let retryAfterMax: TimeInterval = 300

    /// 按一次响应的状态码算新的退避截止时刻;返回 nil 表示清掉退避。
    public static func until(status: Int, retryAfter: String?, now: Date, current: Date?) -> Date? {
        switch status {
        case 429:
            return now.addingTimeInterval(retryAfterSeconds(retryAfter))
        case 403:
            let candidate = now.addingTimeInterval(forbiddenCooldown)
            if let current, current > candidate { return current }
            return candidate
        default:
            return nil
        }
    }

    /// 只认整数秒;缺失、解析不出、非正数都用默认值,超过上限按上限。
    public static func retryAfterSeconds(_ raw: String?) -> TimeInterval {
        guard let raw, let secs = Int(raw.trimmingCharacters(in: .whitespaces)), secs > 0
        else { return retryAfterDefault }
        return min(TimeInterval(secs), retryAfterMax)
    }
}

/// 退避状态。后台批量查询(「最近记录」封面兜底)在窗口内不发请求;用户点「前往专辑/艺人」
/// 这类单次操作照发,但结果同样记进来。
///
/// 带 `store` 时跟 collector 共享窗口(`OutboundCooldowns`):自己撞到的限流写进去,collector 写的
/// 窗口也算冷却中。
public final class ITunesSearchGate: @unchecked Sendable {
    public static let shared = ITunesSearchGate(store: .shared)

    private let lock = NSLock()
    private var until: Date?
    private let store: OutboundCooldownStore?

    public init(store: OutboundCooldownStore? = nil) {
        self.store = store
    }

    public func coolingDown(now: Date = Date()) -> Bool {
        lock.lock()
        let local = until
        lock.unlock()
        if let local, now < local { return true }
        return store?.activeUntil(OutboundCooldowns.itunesSearchKey, now: now) != nil
    }

    public func note(status: Int, retryAfter: String?, now: Date = Date()) {
        lock.lock()
        until = ITunesSearchBackoff.until(status: status, retryAfter: retryAfter, now: now, current: until)
        let published = until
        lock.unlock()
        if let published, published > now {
            store?.publish(OutboundCooldowns.itunesSearchKey, until: published, now: now)
        }
    }
}
