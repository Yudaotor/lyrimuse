import Foundation

/// 共享配置的键差分,给保存时的日志用。
///
/// 改设置不重启后台采集服务:collector 按 mtime 自己热重读 features.json(featuresreload.go)
/// 和 config.json(configreload.go),连 lyrics_dir 也是在运行中切换(lyricsdirswitch.go)。
/// 所以这里不再有「哪些键要重启」的名单,保存路径也别再调 CollectorRestartCoordinator。
public enum CollectorRestartPolicy {
    /// collector 会按 features.json 的 mtime 自己重读、因而**不需要重启**的键(json 键名,与 Go 侧逐字对应)。
    ///
    /// - `lastfm_excluded_bundles`:「Scrobble 的播放器」(lyrimuse-collector/lastfmexclude.go
    ///   `currentLastfmExcludedBundles`,照 lyricspins.go 的 `lyricsPinned` 写法 Stat + 重读)。
    /// - `lyrics_sources` 与它那六个迁移标记(`amll_lyrics` / `lyricfind_lyrics` / `kuwo_lyrics` /
    ///   `migu_lyrics` / `deezer_lyrics` / `applemusic_lyrics`):「歌词来源」的勾选
    ///   (lyrimuse-collector/lyricsourcesreload.go `currentLyricSources`,同一套 Stat + 重读)。
    ///   ⚠️ 六个标记必须跟 `lyrics_sources` 一起在名单里:取消勾选 amll / lyricfind / kuwo / migu /
    ///   deezer / Apple Music 中任何一个,写盘时对应那个标记也跟着变(见 FeatureSettingsStore 的
    ///   currentSnapshot),漏一个就等于"取消这几个源仍然要重启、取消别的源不用",行为随源而异。
    ///   ⚠️ 同一张卡片上的 `lyrics_source_mode`(匹配算法)和 `lyrics_source_order`(拖拽顺序)**不在**
    ///   名单里:collector 在启动时就把它们展开进包级变量、决定了走哪条取词路径。
    public static let hotReloadedKeys: Set<String> = [
        "lastfm_excluded_bundles",
        "lyrics_sources",
        "amll_lyrics", "lyricfind_lyrics", "kuwo_lyrics", "migu_lyrics", "deezer_lyrics", "applemusic_lyrics",
    ]

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
