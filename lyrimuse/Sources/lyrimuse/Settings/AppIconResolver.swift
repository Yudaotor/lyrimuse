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

    /// 装不了 App 就没图标可查时的兜底:随 App 一起打包的静态品牌图。
    ///
    /// 2026-09-02 用户反馈:换一台只装了 Apple Music/QQ 音乐的机器,「播放器」卡片网格里
    /// 网易云音乐/酷狗音乐/Spotify 全变成了一个纯色块+SF Symbol 音符,"看着都跟坏了一样"。
    /// 根因是 `PlayerChoiceCard` 原来直接把 `icon(forBundleID:)` 查不到(=这台机器没装那个
    /// App)当"没图标"处理,退回占位——但这几个播放器的品牌图标本身跟"这台机器装没装"没
    /// 关系,是固定的。跟 `SettingsView.swift` 里 `platformIcon`(YouTube Music/Spotify 网页
    /// 播放器卡)同一个思路、同一批已经打包进 Contents/Resources/ 的 PNG(2026-08-31/
    /// 2026-09-01 那两次的先例:取自本机已安装 App 的 AppIcon.icns,sips 转 1024×1024 PNG,
    /// 不是从网上抓的品牌资源)——网易云音乐/酷狗音乐/QQ 音乐这三张是这次新加的
    /// (NeteaseIcon.png/KugouIcon.png/QQMusicIcon.png),Spotify 直接复用已有的
    /// SpotifyIcon.png,不用再拷一份。
    ///
    /// 用 `Bundle.main`(不是 `Bundle.module`)加载——理由跟 `platformIcon` 那边一致:
    /// 资源是 build.sh 拷进 Contents/Resources/ 的,不是走 SwiftPM 的资源打包机制。
    static func icon(bundledResourceName name: String) -> NSImage? {
        let key = "bundled:" + name
        if let cached = cache[key] { return cached }
        guard let path = Bundle.main.path(forResource: name, ofType: "png"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        cache[key] = image
        return image
    }
}
