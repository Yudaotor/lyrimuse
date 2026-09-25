import Foundation

/// 共享配置的键差分,给保存时的日志用。
///
/// 改设置不重启后台采集服务:collector 按 mtime 自己热重读 features.json(featuresreload.go)
/// 和 config.json(configreload.go),连 lyrics_dir 也是在运行中切换(lyricsdirswitch.go)。
/// 所以这里不再有「哪些键要重启」的名单,保存路径也别再调 CollectorRestartCoordinator。
public enum CollectorRestartPolicy {
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
