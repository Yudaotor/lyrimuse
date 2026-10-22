import Foundation
import LyrimuseCore
import OSLog

/// 设置 › 关于 › 诊断与数据里的「缓存」:算缓存目录里能重建的那部分多大,清理时删掉再重启。
///
/// 只删 `StorageLayout.cacheFileNames` 和动态封面目录,Sparkle 的下载缓存、系统给的网络缓存不碰。引擎和 App 都把这些缓存
/// 读在内存里、按自己的节奏整份写回,所以先停引擎、删完立刻重启 App:重启后的对账(`EngineServiceManager.reconcileAfterLaunch`)
/// 按「该跑没跑」把引擎装回去。设置、歌词、播放记录都在数据目录里,不受影响。见 14 章决策 136。
enum CacheCleaner {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "cache-cleaner")

    static var removableURLs: [URL] {
        StorageLayout.cacheFileNames.map { LyrimusePaths.cacheFile($0) } + [LyrimusePaths.cacheFile("motion-covers")]
    }

    /// 这些东西一共占多少字节。在调用方的线程上走目录,别放主线程。
    static func size() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for url in removableURLs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                continue
            }
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            while let item = walker?.nextObject() as? URL {
                total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// 停引擎、删缓存、重启 App。
    @MainActor
    static func clearAndRestart() async {
        await EngineServiceManager.stopForMaintenance()
        let urls = removableURLs
        let failed = await Task.detached { urls.filter { !FileIO.remove($0) }.count }.value
        logger.notice("cache cleanup: removed \(urls.count - failed, privacy: .public) of \(urls.count, privacy: .public) items")
        ConfigPortability.restartApp()
    }
}
