import Foundation
import os

/// 按 bundle id **直接问系统**"那个播放器自己在报什么" —— 绕开「系统级 Now Playing 只有一个焦点」。
///
/// ## 它解决的是什么
///
/// MediaRemote 的「正在播放」是系统级单一焦点,浏览器里一个 `video` 元素就能占走。焦点一被占,
/// media-control 那条路读到的是**占用者**的东西,目标播放器整个读不到 —— 而它多半还在放。
/// 但系统其实**同时保留着每个注册过 now playing 的 App 各自的状态**,media-control 只取了当选
/// 的那一个(`MRMediaRemoteGetNowPlayingInfo`)。这条路取的是指定的那一个,所以**不受焦点影响**,
/// 而且对**没有 AppleScript 字典的播放器一样有效**(QQ 音乐 / 网易云 / 酷狗 / 汽水音乐)。
///
/// 别指望 `MRMediaRemoteGetActivePlayerPathsForOrigin`:那里的 "active" 就是"当选的那一个",
/// 焦点被占时它只返回占用者,目标播放器的 path 从列表里直接消失。能用的是
/// `MRMediaRemoteGetNowPlayingClients` + `MRMediaRemoteGetNowPlayingInfoForClient`,
/// 签名与"为什么必须让 /usr/bin/perl 加载"都写在 `native/nowplaying-clients/nowplaying-clients.m`。
///
/// ## 这条路是**附加**的,不是替换
///
/// 正常情况下(焦点在目标播放器手里)照旧走 media-control —— 那条有 stream 常驻、有电台判据、
/// 有各播放器的适配,不该为这条新路推翻。这里只在**焦点被别人占走、media-control 这一拍什么都
/// 拿不到**时用。 私有接口 + 逆向出来的调用约定,系统升级可能变,所以**任何失败都必须静默退回**,
/// 绝不能让它把主链路带崩。
public enum NowPlayingClientsProbe {
    private static let logger = Logger(subsystem: LyrimuseIdentity.bundleIdentifier, category: "nowplaying-clients")

    /// 一次查询的超时。正常 ~120ms;卡住就放弃这一拍,下一拍再试。
    public static let timeout: TimeInterval = 2.0

    /// `Contents/Resources/nowplaying-clients/` 下的两件套(perl 加载器 + dylib)。
    /// 少任何一件都返回 nil —— 调用方按"这条路不可用"处理,退回既有逻辑。
    public static func helperPaths() -> (script: String, library: String)? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let dir = resourcePath + "/nowplaying-clients"
        let script = dir + "/nowplaying-clients.pl"
        let library = dir + "/libnowplaying-clients.dylib"
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: script), fm.isReadableFile(atPath: library) else { return nil }
        return (script, library)
    }

    /// 问某个 bundle id 此刻的封面。拿不到一律 nil。
    ///
    /// 单独一条路、**不跟状态查询合并**:带封面那一趟要把一张 JPEG 走 base64 过 JSON,明显更贵,
    /// 而状态是每拍都要问的。封面只在换歌时取一次(调用方按 trackKey 缓存)。
    ///
    /// **给不给取决于这一刻在放什么**:实测五家都给(汽水音乐 9KB、QQ音乐 113KB、Spotify 107KB、
    /// Apple Music 113KB),但 Spotify **放广告时不给**,浏览器里的视频也不给。拿不到就是拿不到,
    /// 调用方照旧退回既有来源(目录高清图等)。
    public static func artwork(forBundleID bundleID: String) -> (data: Data, mimeType: String, trackKey: String)? {
        guard !bundleID.isEmpty, let paths = helperPaths() else { return nil }
        guard let r = ProcessRunner.run(
            "/usr/bin/perl", [paths.script, paths.library, bundleID, "artwork"], timeout: artworkTimeout),
            r.succeeded,
            let decoded = try? JSONDecoder().decode(ArtworkPayload.self, from: r.stdout),
            let base64 = decoded.artworkData,
            let data = Data(base64Encoded: base64), !data.isEmpty
        else { return nil }
        return (data, decoded.artworkMimeType ?? "image/jpeg",
                MediaControlSnapshot.trackKey(artist: decoded.artist, title: decoded.title))
    }

    /// 带封面那一趟的超时:比状态查询宽,一张图要过 base64。
    public static let artworkTimeout: TimeInterval = 4.0

    /// 只镜像封面这几个字段 —— 与 `MediaControlClient.ArtworkPayload` 同样的取舍:各自只解自己要的那部分。
    /// title / artist 不是多余的:它们标识这份封面属于哪首歌(返回值里的 trackKey)。
    private struct ArtworkPayload: Decodable {
        let artworkData: String?
        let artworkMimeType: String?
        let title: String?
        let artist: String?
    }

    /// 问某个 bundle id 此刻在报什么。拿不到(没装 helper / 超时 / 那个 App 没在报)一律 nil。
    ///
    /// 位置已经在 helper 里按锚点外推过(`elapsed + (now - timestamp) * rate`)—— 载荷里的
    /// `ElapsedTime` 是**锚点**不是此刻的位置,同一首歌里连查几次它一动不动。锚点原值经
    /// `anchorElapsedTime` 一并带回,上层判"这是不是开播锚点"的既有逻辑照旧可用。
    public static func snapshot(forBundleID bundleID: String) -> MediaControlSnapshot? {
        guard !bundleID.isEmpty, let paths = helperPaths() else { return nil }
        guard let r = ProcessRunner.run(
            "/usr/bin/perl", [paths.script, paths.library, bundleID], timeout: timeout),
            r.succeeded
        else { return nil }
        // helper 对"那个 App 现在没在报"输出字面量 null,解码失败即视为没有。
        guard let decoded = try? JSONDecoder().decode(MediaControlSnapshot.self, from: r.stdout) else {
            return nil
        }
        // 标题空的一律不算 —— 与 media-control 那条路的准入口径一致。
        guard let title = decoded.title, !title.isEmpty else { return nil }
        return decoded
    }
}
