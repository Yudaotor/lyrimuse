import Foundation

/// 这台机器上「完全磁盘访问」「辅助功能」授权成功过没有。两项授权都按 App 的签名记:换了签名的版本装上后,
/// 系统设置里那条还开着,对新版本却不算数,要在列表里删掉再加回来。没授权时靠它说「授权已失效」、给出这一步,
/// 而不是「未获授权」。属于机器状态:配置导出时排除(`ConfigPortability.machineLocalDefaultsKeys`)。见 14 章决策 67。
enum PermissionGrantMemory {
    static let fullDiskAccessKey = "np:fullDiskAccessEverGranted"
    static let accessibilityKey = "np:accessibilityEverGranted"

    static func record(_ key: String) {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
    }

    static func everGranted(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}
