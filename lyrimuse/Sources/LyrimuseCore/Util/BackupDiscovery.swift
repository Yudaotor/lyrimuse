import Foundation

/// 在若干候选目录里找出**最新**的那一份配置备份。
///
/// 为什么要跨目录找:写备份只写一个地方,但换新机器时"备份放在哪"这个信息本身存在**旧**
/// 机器的偏好里,新机器恰恰没有。所以探测的范围必须比写入的范围大 —— 一个把备份放在
/// Dropbox 的用户,在新机器首启时如果只按当前设置去找,只会去 iCloud 翻,什么都找不到。
///
/// 抽在这一层(而不是留在 ICloudConfigStore 里)是为了能用真实的临时目录做端到端测试:
/// 那套逻辑只在换机器时走一次,出错时没有现场,而它又恰恰是"用户换新 Mac 能不能一键恢复"
/// 的唯一入口。
public enum BackupDiscovery {
    public struct Found: Equatable {
        /// 备份文件本身(已经是真实文件名,iCloud 未下载占位符已还原)。
        public let url: URL
        /// 它所在的目录 —— 导入之后要据此把"备份文件夹"设置对齐过去。
        public let folder: URL
        public let modifiedAt: Date

        public init(url: URL, folder: URL, modifiedAt: Date) {
            self.url = url
            self.folder = folder
            self.modifiedAt = modifiedAt
        }
    }

    /// 逐个目录列一遍,跨目录按修改时间取最新。
    ///
    /// - 目录不存在/读不了 → 跳过。探测要翻好几个候选,其中大部分在任意一台机器上都不存在,
    ///   这是常态而不是错误。
    /// - 只列目录、不读文件内容:iCloud 上未下载的文件读一下会触发**透明物化**(当场同步
    ///   下载并阻塞线程),而这个函数会在界面渲染路径上被调用。
    public static func latest(in folders: [URL]) -> Found? {
        var best: Found?
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants]
            ) else { continue }

            for entry in entries {
                // 认文件名的规则(含 iCloud 未下载占位符 `.<真名>.icloud`)统一在
                // ConfigSnapshotName,那边另有自测覆盖。
                guard let realName = ConfigSnapshotName.realName(
                    ofDirectoryEntry: entry.lastPathComponent) else { continue }
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if best == nil || modified > best!.modifiedAt {
                    best = Found(
                        url: folder.appendingPathComponent(realName),
                        folder: folder,
                        modifiedAt: modified)
                }
            }
        }
        return best
    }
}
