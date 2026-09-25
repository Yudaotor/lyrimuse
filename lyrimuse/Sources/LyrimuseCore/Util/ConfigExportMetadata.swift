import Foundation

/// 配置包里自报的导出时间和机器名(`ConfigPortability.buildExportData` 写,`ICloudConfigStore` 读)。
///
/// 两个字段只用来把「发现 iCloud 里有一份备份,要不要导入」那句提示写得具体一点,所以读的一侧解析失败一律
/// 返回空、不抛错,拿不到也不该妨碍导入。写和读走同一个格式(不带小数秒的 ISO8601),免得一边改了格式、
/// 另一边静默读成 nil。
public enum ConfigExportMetadata {
    public static let exportedAtKey = "exportedAt"
    public static let deviceNameKey = "deviceName"

    public static func exportedAtString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    public static func read(_ data: Data) -> (exportedAt: Date?, deviceName: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let date = (obj[exportedAtKey] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return (date, obj[deviceNameKey] as? String)
    }
}
