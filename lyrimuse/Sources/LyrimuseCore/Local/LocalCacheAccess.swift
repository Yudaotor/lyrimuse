import Foundation

/// App 与 collector 的「客户端缓存被系统挡住了」状态通道(见 collector/localcachefs.go 头注)。
///
/// ## 为什么需要这条通道
///
/// 酷狗 / QQ 音乐 / 网易云三家的歌词缓存住在各自的 `~/Library/Containers/<bundle id>/Data`
/// 下,那是 macOS 给每个 App 的私有容器,读它必须有「完全磁盘访问」。collector 拿不到授权时
/// 这三条本地快速路径**整条哑掉**,而它们全程 fail-soft —— 表现与"用户压根没装那个播放器"
/// 逐字节相同,界面上没有任何迹象。这条通道就是为了让设置页能把这件事说出来。
///
/// **这个状态只能由 collector 发布,App 绝不能自己去探测**。两者是两个进程,TCC 授权
/// 各自独立:App 探得到不代表 collector 探得到(反之亦然),而真正走这条快速路径的是
/// collector,所以只有它的结论算数。App 自测一遍再显示,等于把一个与事实无关的结论摆给用户。
/// 同 `LyricsFullScan.scoringVersion` 不能在 Swift 侧硬编码是一个道理。
///
/// `denied` 只有**尝试过且被拒的**来源,`readable` 只有**确认读得到的**,两者互斥;都不在 =
/// 还没试过。collector 每次启动先清掉这份文件、再把装了的那几家容器探一遍重新发布
/// (localcacheprobe.go),授权状态可能在两次运行之间被改过,留着旧结论会让界面显示一个
/// 已经不成立的提示。
///
/// 只读通道:App 从不写这份文件。
public enum LocalCacheAccess {
    public struct State: Decodable, Equatable, Sendable {
        public let updatedAt: Int64
        /// 被系统挡住的来源名,取值与 `LyricsSource` 的 rawValue 同一套(kugou / qq / netease …)。
        public let denied: [String]
        /// 确认读得到的来源名,同一套取值。旧版 collector 不写这个字段,解出来是空。
        public let readable: [String]

        enum CodingKeys: String, CodingKey {
            case updatedAt, denied, readable
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
            denied = try c.decodeIfPresent([String].self, forKey: .denied) ?? []
            readable = try c.decodeIfPresent([String].self, forKey: .readable) ?? []
        }

        public init(updatedAt: Int64 = 0, denied: [String] = [], readable: [String] = []) {
            self.updatedAt = updatedAt
            self.denied = denied
            self.readable = readable
        }
    }

    /// 一组来源合起来的「完全磁盘访问」结论。授权是整个 App 一份,所以一组来源只给一个结论。
    public enum Grant: Equatable, Sendable {
        /// 每个来源都确认读得到。
        case granted
        /// 至少一个来源被系统挡住。
        case denied
        /// 没有被拒的,但也没有全部确认读到(collector 没在跑、还没探到、或旧版 collector)。
        case unknown
    }

    /// 被拒优先:只要有一个被挡住就是 `.denied`;空列表是 `.unknown`(没东西可判)。
    public static func grant(for sources: [String], state: State? = current) -> Grant {
        guard let state, !sources.isEmpty else { return .unknown }
        if sources.contains(where: state.denied.contains) { return .denied }
        if sources.allSatisfy(state.readable.contains) { return .granted }
        return .unknown
    }

    public static let stateURL = LyrimusePaths.configFile("lyrimuse-local-cache-access.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: State?

    /// 当前状态;文件不存在 / 解析失败都是 nil。按 mtime 缓存,同 `LyricsFullScan.current`。
    public static var current: State? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: stateURL.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        return cached
    }

    /// 这个来源此刻是不是被挡着。读不到状态一律 false —— 拿不准就什么都不说,
    /// 摆一个猜出来的警告比不摆更糟(同「占用空间」那条"算不出来就不显示"的规矩)。
    public static func isDenied(_ source: String, state: State? = current) -> Bool {
        state?.denied.contains(source) ?? false
    }

    /// 「完全磁盘访问」那一页的系统设置深链。
    ///
    /// 这个锚点(`Privacy_AllFiles`)是 macOS 13 起的写法,跟 `com.apple.settings.PrivacySecurity.extension`
    /// 这个新 bundle id 配套。打不开时系统会退回设置 App 的首页 —— 那不理想但不致命,
    /// 所以调用方不必自己判断版本。
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
}
