import Foundation

/// 导出的配置文件叫什么、以及在一个目录列表里怎么把它认出来。
///
/// 放在 LyrimuseCore 而不是跟 `ICloudConfigStore` 待在一起,只为一件事:**这段是纯字符串
/// 逻辑,也是整条 iCloud 链路里最容易错又最不容易发现错的一环**,而自测 target
/// (lyrimuse-selftest)只链 LyrimuseCore,放在 App target 里就永远测不到。
public enum ConfigSnapshotName {
    public static let prefix = "Lyrimuse-Config-"
    public static let suffix = ".json"

    /// 把目录项的文件名还原成"真实文件名";不是我们的配置就返回 nil。
    ///
    /// 为什么不能只按 `Lyrimuse-Config-*.json` 匹配:iCloud 会把**还没下载到本机**的
    /// 文件在本地留成占位符,形态是 `.<真名>.icloud`(前面多一个点、后面多一个 .icloud)。
    /// 漏掉这种形态的后果不是"少认一个文件",而是**整个功能在最该生效的场景下失灵**——
    /// 刚装好的新电脑上,那份配置几乎必然还没下载,正是占位符形态。
    ///
    /// 只有点和 .icloud **同时**存在才当占位符剥:一个单纯以点开头的 `.json`
    /// (比如别的工具留下的隐藏文件)不是我们的东西,不该认。
    public static func realName(ofDirectoryEntry entryName: String) -> String? {
        var name = entryName
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            name = String(name.dropFirst().dropLast(".icloud".count))
        }
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        // 剥完只剩前后缀、中间没有时间戳的话不算 —— 那不是导出产物
        guard name.count > prefix.count + suffix.count else { return nil }
        return name
    }
}
