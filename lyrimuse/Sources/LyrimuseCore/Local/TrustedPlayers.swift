import Foundation

/// 用户显式信任的「未知播放器」名单 —— bundle id → 界面显示名。
///
/// ## 为什么是"信任列表"而不是"一律接受"
///
/// 「自动识别」原来只认写死的五个播放器。那道白名单不只挡显示,**也挡打卡**
/// (collector 的 `poller.isTracked`):一律接受等于让 YouTube 视频、播客、网课被当成
/// 收听写进用户的 Last.fm / ListenBrainz **永久历史**,还会往"设计上永不清理"的歌词
/// 缓存里灌垃圾条目、白烧五个歌词源的查询。
///
/// 而"靠内容形状分辨是不是音乐"这条路不可靠:浏览器里的网页播放器能通过 MediaSession
/// API 自己填 title/artist/artwork,一个 YouTube 音乐视频跟一首歌长得一模一样;
/// `mediaType` 也不能指望 —— 实测酷狗压根不报这个字段(2026-08-21)。
///
/// 所以口径是**用户显式同意**:设置页发现有未知 App 在报 Now Playing 就提示一张卡,
/// 用户点一下加进这份名单,之后它跟五个内置播放器完全同权(显示 + 打卡)。这样任何 App
/// 都能接(包括这个项目从没听说过的),而默认状态下一条垃圾都进不来。
///
/// 读法跟 `PlaybackPlayerPreference` 完全一致:LyrimuseCore 是被依赖的下层,不能反向
/// 依赖 App target 的 FeatureSettingsStore,所以自己独立读一份共享 JSON、只取用得到的
/// 那个字段。同样不加 mtime 缓存 —— 文件很小,而"刚点了信任就要立刻生效"比省这点 IO
/// 重要得多。
public enum TrustedPlayers {
    private struct MinimalFeatureFlags: Decodable {
        let trusted_players: [String: String]?
    }

    private static let featuresURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-features.json")

    /// bundle id → 显示名(可能是空串:反查不到 App 名时)。文件不存在/解析失败一律空表。
    public static var current: [String: String] {
        guard let data = try? Data(contentsOf: featuresURL),
              let f = try? JSONDecoder().decode(MinimalFeatureFlags.self, from: data),
              let map = f.trusted_players
        else { return [:] }
        return map
    }

    /// 这个 bundle id 是不是用户信任过的未知播放器。
    ///
    /// 只回答"信任"这一半,**不含**五个内置播放器 —— 调用方要的是"内置 or 信任"时自己
    /// 用 `isAccepted`,别在这里把两件事混起来(内置那份是编译期常量,信任这份要读盘)。
    public static func isTrusted(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return current[bundleID] != nil
    }

    /// 「自动识别」下真正的成员判断:内置五个 + 用户信任的。跟 collector 的
    /// `isAcceptedPlayerBundleID` 是同一套语义,两侧必须同时改。
    public static func isAccepted(_ bundleID: String?) -> Bool {
        isAccepted(bundleID, trusted: current)
    }

    /// 同上,但信任名单由调用方传入 —— 纯函数,selftest 直接覆盖(不然断言会去读这台机器
    /// 上真实的 features.json,结果随用户配置变)。
    public static func isAccepted(_ bundleID: String?, trusted: [String: String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if PlaybackPlayer.allCases.contains(where: { $0 != .auto && $0.bundleIdentifier == bundleID }) {
            return true
        }
        return trusted[bundleID] != nil
    }

    /// 一条来自**信任的未知播放器**的播放,歌手名**或专辑名**是空的 → 判成"这不是一首歌",
    /// 整条丢掉(不解析歌词、不打卡)。
    ///
    /// 判据跟 collector 的 isAdBreak 完全一致(`album == "" || artist == ""`),区别只在
    /// 作用域:那个只服务 Spotify 广告,这个服务信任列表。
    ///
    /// 2026-08-21 全靠真实样本定的,四份实测:
    ///   - 酷狗音乐    artist=周杰伦     album=七里香              → 是歌
    ///   - Apple Music artist=方大同     album=Soulboy/100种生活   → 是歌
    ///   - Spotify     artist=方大同     album=Soulboy             → 是歌
    ///   - Arc 放视频  artist=""/频道名  album=**恒为空**          → 不是歌
    ///
    /// **album 是这四份样本里唯一 100% 分对的字段**。artist 单独不够:YouTube 会把**频道名**
    /// 塞进 artist(实测 `Dream in reality` / 时长 925 秒的法语 vlog),从数据形状上跟
    /// "歌手 - 歌名"无法区分;而它的 album 两次都空。代价是电台/单曲场景真音乐 App 若不报
    /// 专辑名会被误挡 —— 2026-08-21 用户拍板接受(宁可漏认,不要把视频写进永久收听历史)。
    ///
    /// mediaType 这条路走不通,记下别再试:酷狗压根不报这个字段,Arc 也不报(不是报 Video,
    /// 是没有这个键),只有 Apple Music 有。内置五个播放器不走这条(各有既有守卫)。
    ///
    /// 跟 collector 的 trustedPlaybackNotASong 是同一套语义,两侧必须同时改。
    public static func notASong(bundleID: String?, artist: String?, album: String?) -> Bool {
        notASong(bundleID: bundleID, artist: artist, album: album, trusted: current)
    }

    /// 同上,名单由调用方传入 —— 纯函数,selftest 直接覆盖。
    public static func notASong(bundleID: String?, artist: String?, album: String?,
                                trusted: [String: String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        // 内置播放器不受这条守卫约束。
        if PlaybackPlayer.allCases.contains(where: { $0 != .auto && $0.bundleIdentifier == bundleID }) {
            return false
        }
        guard trusted[bundleID] != nil else { return false }
        func blank(_ s: String?) -> Bool {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return blank(artist) || blank(album)
    }
}
