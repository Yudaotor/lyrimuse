import Foundation

/// 界面语言「跟随系统」时的协商结果(`UILanguage.resolve(preferredLanguages:)`),记住 `ttl` 秒再重算。
/// `L10n.t` 每次查文案都要知道界面语言,而 `Locale.preferredLanguages` 每读一次都要从偏好里取整个数组再桥接成 Swift
/// 数组(约 4µs):列表重排、上万行文案一次就是几百毫秒。系统语言改了最多晚 `ttl` 秒跟上;`invalidate()` 当场作废。
/// 用户在 App 里手动选的界面语言不经过这里,调用方每次照读,切换当场生效。线程安全,任何线程都能调。
public final class SystemUILanguageCache: @unchecked Sendable {
    public static let ttl: TimeInterval = 1

    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let preferredLanguages: () -> [String]
    private var cached: (language: String, at: TimeInterval)?
    /// 真的去协商了几次(测试用)。
    public private(set) var resolveCount = 0

    public init(now: @escaping () -> TimeInterval = { CFAbsoluteTimeGetCurrent() },
                preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.now = now
        self.preferredLanguages = preferredLanguages
    }

    public func language() -> String {
        let t = now()
        lock.lock()
        defer { lock.unlock() }
        if let cached, t >= cached.at, t - cached.at < Self.ttl { return cached.language }
        let language = UILanguage.resolve(preferredLanguages: preferredLanguages())
        cached = (language, t)
        resolveCount += 1
        return language
    }

    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
