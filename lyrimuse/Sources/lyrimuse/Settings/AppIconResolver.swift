import AppKit

/// 按 bundle identifier 查真实 App 图标——NSWorkspace 找到 .app 再取图标,最好认,还不用
/// 自带任何商标素材(2026-08-19 用户拍板改图标时定的取图标原则,见调用点)。
///
/// 2026-08-25 从三处各自维护的同一段逻辑收拢到这里:「正在播放」面板来源角标
/// (原 `PlaybackCoordinator.resolvedPlayerIcon` 自己那份 `playerIconCache`)、引导页选
/// 播放器的图标卡片(`PlayerChoiceCard`)、设置页"已信任的其它播放器"列表。三处各写一遍、
/// 其中两处各自还维护一份独立缓存——统一到这一个地方,一份缓存全进程共用,免得三份实现
/// 慢慢长歪(其中一处忘了处理某种边界情况,另外两处不会跟着改)。
///
/// App 图标在进程生命周期内不会变,查一次够用一辈子,缓存不需要失效。
@MainActor
enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]

    /// 空字符串(比如 `PlaybackPlayer.auto` 没有唯一固定的目标 App)直接返回 nil,
    /// 不去问 NSWorkspace——那样问到的是"哪个 App 声明了处理空 bundle id",没有意义。
    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
