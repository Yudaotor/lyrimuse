import Foundation

/// 改了共享配置之后,到底要不要重启后台采集服务(2026-09-10)。
///
/// collector 绝大多数配置只在**启动时**读一次,所以设置页每保存一次就 `launchctl kickstart -k` 重启它一遍。
/// 2026-09-10 量了这一下的真实代价:App 那句「正在应用到后台服务…」只转 1~3 秒(0.5s 合并去抖 + kickstart +
/// 最多 3s 轮询到新进程号),但它把"launchd 报出了一个新 pid"当成了完成 —— 新进程还要在 74MB 歌词缓存之上跑
/// 九道迁移、全量导入导出 14307 个歌词文件才开始服务。当天四次重启从 SIGTERM 到打出启动横幅分别是
/// 68 / 37 / 40 / 43 秒,这段时间歌词与「正在播放」推送整个停摆。
///
/// 所以:能让 collector 自己按 mtime 热读的键,就别为它重启。这份名单是**白名单**,默认仍然重启 ——
/// 加一个键进来之前,collector 侧必须真的有对应的热重读,否则用户会看到"改了没反应、重启才生效"。
public enum CollectorRestartPolicy {
    /// collector 会按 features.json 的 mtime 自己重读、因而**不需要重启**的键(json 键名,与 Go 侧逐字对应)。
    ///
    /// - `lastfm_excluded_bundles`:「Scrobble 的播放器」(lyrimuse-collector/lastfmexclude.go
    ///   `currentLastfmExcludedBundles`,照 lyricspins.go 的 `lyricsPinned` 写法 Stat + 重读)。
    public static let hotReloadedKeys: Set<String> = ["lastfm_excluded_bundles"]

    /// 这批改动要不要重启。**改动集合为空时照旧重启**:那不是"没必要重启",而是调用方没告诉我们改了什么
    /// (比如从损坏文件重建、或者外部原因触发的保存),保守起见维持既有行为。
    public static func needsRestart(changedKeys: Set<String>) -> Bool {
        guard !changedKeys.isEmpty else { return true }
        return !changedKeys.isSubset(of: hotReloadedKeys)
    }

    /// 两份 JSON 字典之间变了哪些顶层键。只在一边出现的键算变了(值被删掉也是一种变化)。
    ///
    /// 值用 `NSObject.isEqual` 比:`JSONSerialization` 产出的都是 NSString / NSNumber / NSArray /
    /// NSDictionary / NSNull,它们的 `isEqual` 对数组和字典是深比较,不需要自己递归。
    public static func changedKeys(from old: [String: Any], to new: [String: Any]) -> Set<String> {
        var changed: Set<String> = []
        for key in Set(old.keys).union(new.keys) {
            let a = old[key] as? NSObject
            let b = new[key] as? NSObject
            if let a, let b, a.isEqual(b) { continue }
            if a == nil, b == nil { continue } // 两边都没有(或都不是 JSON 值):当没变
            changed.insert(key)
        }
        return changed
    }
}
