import Foundation

/// 这个进程有没有「完全磁盘访问」。打开系统的权限库:系统那份对所有人可读(644),只有这项授权挡着,被拒时不弹框;
/// 用户那份新系统上可能不存在。别换成探别的 App 的容器或偏好设置,那一下就会弹「想访问其他 App 的数据」。
/// 跟引擎 `containergate.go` 同一个判法,见 02 章决策 239。
public enum FullDiskAccessProbe {
    public static let paths = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
    ]

    public static func isGranted() -> Bool {
        paths.contains { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            try? handle.close()
            return true
        }
    }
}
