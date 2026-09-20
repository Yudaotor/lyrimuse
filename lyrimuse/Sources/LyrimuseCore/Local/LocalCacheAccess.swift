import Foundation

/// App ⇄ collector 的「客户端缓存被系统挡住了」状态通道(见 collector/localcachefs.go 头注)。
///
/// ## 为什么需要这条通道
///
/// 酷狗 / QQ 音乐 / 网易云三家的歌词缓存住在各自的 `~/Library/Containers/<bundle id>/Data`
/// 下,那是 macOS 给每个 App 的私有容器,读它必须有「完全磁盘访问」。collector 拿不到授权时
/// 这三条本地快速路径**整条哑掉**,而它们全程 fail-soft —— 表现与"用户压根没装那个播放器"
/// 逐字节相同,界面上没有任何迹象。这条通道就是为了让设置页能把这件事说出来。
///
/// ⚠️ **这个状态只能由 collector 发布,App 绝不能自己去探测**。两者是两个进程,TCC 授权
/// 各自独立:App 探得到不代表 collector 探得到(反之亦然),而真正走这条快速路径的是
/// collector,所以只有它的结论算数。App 自测一遍再显示,等于把一个与事实无关的结论摆给用户。
/// 同 `LyricsFullScan.scoringVersion` 不能在 Swift 侧硬编码是一个道理。
///
/// ⚠️ 名单里**只有尝试过且被拒的**来源。没听过那个播放器的用户这里是空的,界面因此什么都
/// 不显示 —— 而不是显示一排"未知"。collector 每次启动会清掉这份文件,授权状态可能在两次
/// 运行之间被改过,留着旧结论会让界面显示一个已经不成立的提示。
///
/// 只读通道:App 从不写这份文件。
public enum LocalCacheAccess {
    public struct State: Decodable, Equatable, Sendable {
        public let updatedAt: Int64
        /// 被系统挡住的来源名,取值与 `LyricsSource` 的 rawValue 同一套(kugou / qq / netease …)。
        public let denied: [String]

        enum CodingKeys: String, CodingKey {
            case updatedAt, denied
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
            denied = try c.decodeIfPresent([String].self, forKey: .denied) ?? []
        }

        public init(updatedAt: Int64 = 0, denied: [String] = []) {
            self.updatedAt = updatedAt
            self.denied = denied
        }
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
    /// ⚠️ 这个锚点(`Privacy_AllFiles`)是 macOS 13 起的写法,跟 `com.apple.settings.PrivacySecurity.extension`
    /// 这个新 bundle id 配套。打不开时系统会退回设置 App 的首页 —— 那不理想但不致命,
    /// 所以调用方不必自己判断版本。
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
}
