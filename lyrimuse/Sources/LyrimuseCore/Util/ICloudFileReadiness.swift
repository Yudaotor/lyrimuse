import Foundation

/// 「这个路径现在能不能直接读,而不用先等 iCloud 下载」。
///
/// 放在 LyrimuseCore 而不是跟 `ICloudConfigStore` 待在一起,理由跟 `ConfigSnapshotName`
/// 一模一样:这是整条 iCloud 链路里最容易错又最不容易发现错的一环,而自测 target
/// 只链 LyrimuseCore,留在 App target 里就永远测不到。这两个类型也正是同一个故事的两半——
/// 那边负责「占位符叫什么名字」,这边负责「占位符状态下该不该先下载」。
public enum ICloudFileReadiness {
    /// - Parameters:
    ///   - downloadingStatus: `URLResourceValues.ubiquitousItemDownloadingStatus`。
    ///     拿不到(查询抛错)就传 nil。查这个属性本身**不会**触发下载。
    ///   - realPathExists: 真名路径上现在有没有东西(`FileManager.fileExists`)。
    ///
    /// 2026-08-24 修的就是 `downloadingStatus == nil` 这一档。原来它无条件当"能读",而
    /// 拿不到状态其实是**两种完全相反**的情况:
    ///
    /// * 路径上有个普通文件 —— 用户手动拷进来的、或者备份文件夹压根不是 iCloud 管的
    ///   (Dropbox/坚果云/本地目录)。这种读它立即返回,确实"能读"。
    /// * 路径上**什么都没有** —— iCloud 只在本地留了 `.<真名>.icloud` 占位符,真名路径
    ///   不存在(见 `ConfigSnapshotName.realName(ofDirectoryEntry:)`;新机器上几乎必然
    ///   是这个形态)。这种恰恰是**最需要先去下载**的情况。
    ///
    /// 混成一档的代价是用户报上来的这个 bug:设置页点「导入」→ 判定成"能读"→ 跳过
    /// `startDownloadingUbiquitousItem` → 直接读一个不存在的路径失败 → 界面提示
    /// "这份备份还没从 iCloud 下载下来,等一会儿再试"。而下载**从头到尾没有被发起过**,
    /// 等多久都没用,除非用户自己去 Finder 里把那个文件夹点下来。
    ///
    /// 判据改成:拿不到状态时看真名路径在不在。在 = 普通文件,能读;不在 = 占位符,得先下载。
    public static func isReadyToRead(
        downloadingStatus: URLUbiquitousItemDownloadingStatus?,
        realPathExists: Bool
    ) -> Bool {
        if let downloadingStatus { return downloadingStatus == .current }
        return realPathExists
    }
}
