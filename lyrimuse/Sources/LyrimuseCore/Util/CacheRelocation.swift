import Foundation

/// 把一个缓存子目录从旧位置搬到新位置(配置目录 → `LyrimusePaths.cachesDir`),升级后第一次用到时调一次。
///
/// 只认 `extensions` 里的扩展名,别的文件原样留着(旧目录因此不空时也不删)。逐个 `rename(2)`,不拷贝:
/// 同卷一次改名,几百个文件也在毫秒内完成,可以放在主线程上;跨卷时改名失败,那一份直接删掉 —— 搬的只是能重新下载的
/// 缓存,删掉的代价是下次用到时重下一份,拷贝的代价是主线程上拷几百 MB。新位置已有同名文件时以新位置的为准。
public enum CacheRelocation {
    public struct Outcome: Equatable, Sendable {
        public var moved = 0
        public var dropped = 0
        public var removedOldDirectory = false

        public init(moved: Int = 0, dropped: Int = 0, removedOldDirectory: Bool = false) {
            self.moved = moved
            self.dropped = dropped
            self.removedOldDirectory = removedOldDirectory
        }
    }

    /// 旧目录不存在时什么都不做,返回全零。
    @discardableResult
    public static func move(from old: URL, to new: URL, extensions: Set<String>) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        guard let items = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return outcome }
        guard FileIO.createDirectory(new) else { return outcome }
        for item in items where extensions.contains(item.pathExtension) {
            let target = new.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: target.path), rename(item.path, target.path) == 0 {
                outcome.moved += 1
            } else if (try? fm.removeItem(at: item)) != nil {
                outcome.dropped += 1
            }
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true, (try? fm.removeItem(at: old)) != nil {
            outcome.removedOldDirectory = true
        }
        return outcome
    }
}
