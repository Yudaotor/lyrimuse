import Foundation

/// 用户显式信任的「未知播放器」名单 —— bundle id 到 界面显示名。
///
/// ## 为什么是"信任列表"而不是"一律接受"
///
/// 「自动识别」原来只认写死的五个播放器。那道白名单不只挡显示,**也挡打卡**
/// (collector 的 `poller.isTracked`):一律接受等于让 YouTube 视频、播客、网课被当成
/// 收听写进用户的 Last.fm / ListenBrainz **永久历史**,还会往"设计上永不清理"的歌词
/// 缓存里灌垃圾条目、白烧全部歌词源的查询。
///
/// 而"靠内容形状分辨是不是音乐"这条路不可靠:浏览器里的网页播放器能通过 MediaSession
/// API 自己填 title/artist/artwork,一个 YouTube 音乐视频跟一首歌长得一模一样;
/// `mediaType` 也不能指望 —— 实测酷狗压根不报这个字段。
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

    private static let featuresURL = LyrimusePaths.configFile("lyrimuse-features.json")

    /// bundle id 到 显示名(可能是空串:反查不到 App 名时)。文件不存在/解析失败一律空表。
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
    /// 含 Safari 的媒体代理进程别名解析(见 `mediaProxyOwner`)—— 信任了 Safari 之后,
    /// 它报告 Now Playing 时用的 `com.apple.WebKit.GPU` 也该被这个函数认下来,跟
    /// `isAccepted` 内部的同一步解析保持一致,调用方不需要自己再查一遍代理表。
    ///
    /// 在"选中了具体播放器但没勾自动识别"这条路径上也会被查(见
    /// `MediaControlClient.fetchMultiSelectedSnapshot`)——最典型场景是「网页播放器」卡
    /// "配对浏览器"这个动作(一步自动信任+配对),用户没有理由因为没勾自动识别就让配对
    /// 形同虚设。collector 侧对应的是 `isTrustedPlayerBundleID`,两侧必须同步维护。
    public static func isTrusted(_ bundleID: String?) -> Bool {
        isTrusted(bundleID, trusted: current)
    }

    /// 同上,但信任名单由调用方传入 —— 纯函数,selftest 直接覆盖(不然断言会去读这台机器
    /// 上真实的 features.json,结果随用户配置变),跟 `isAccepted(_:trusted:)` 同一个理由。
    public static func isTrusted(_ bundleID: String?, trusted: [String: String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if trusted[bundleID] != nil { return true }
        if let owner = mediaProxyOwner(of: bundleID), trusted[owner] != nil { return true }
        return false
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
        return isTrusted(bundleID, trusted: trusted)
    }

    // MARK: - 媒体代理进程

    /// 「媒体进程 bundle id 到 真正的宿主 App bundle id」。
    ///
    /// Safari 播网页音视频时,解码/播放跑在一个**独立的 WebKit GPU 进程**里,而 MediaRemote
    /// 报"现在谁在放"时报的是**那个进程**(`com.apple.WebKit.GPU`),不是 `com.apple.Safari`。
    /// Chromium 系(Arc/Chrome/Edge)不这样 —— 它们报浏览器自己的 bundle id,所以只有 Safari
    /// 需要这层映射。
    ///
    /// 不加这层的后果是**用户看得见的断层**(实测撞上,原话「为什么这里又
    /// 出现了一个 webkit 啥玩意」):在设置页「网页播放器」卡里配对了 Safari,配对动作也确实
    /// 把 `com.apple.Safari` 写进了信任列表,可真播起来上报方是 `com.apple.WebKit.GPU` ——
    /// 不在名单里 到 整条播放不被采纳,同时"发现未知播放器"那张卡还会跳出来要用户再信任一个
    /// 看不懂的 bundle id。两个身份、两套机制,中间没人搭桥。
    ///
    /// **选择"别名"而不是"配对时连带把代理进程也写进信任列表"**:后者会在设置页
    /// 「已信任的其它播放器」里留下一条用户看不懂的 `com.apple.WebKit.GPU`,而且撤销配对时
    /// 还得记得把它一起删掉(漏了就是永久多一条)。别名跟着宿主的信任状态自动生效/失效,
    /// 没有需要同步维护的第二份状态。
    ///
    /// **只登记实测见过的**。`com.apple.WebKit.WebContent` 这类同族进程没有实测到它报过
    /// Now Playing,不凭猜测往里加 —— 真遇到了在这张表里补一行就行,其余逻辑不用动。
    public static let mediaProxyOwners: [String: String] = [
        "com.apple.WebKit.GPU": "com.apple.Safari",
    ]

    /// 这个 bundle id 是某个 App 的媒体代理进程吗 —— 是就返回宿主的 bundle id。
    public static func mediaProxyOwner(of bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return mediaProxyOwners[bundleID]
    }

    /// 一条来自**信任的未知播放器**的播放,歌手名**或专辑名**是空的 到 判成"这不是一首歌",
    /// 整条丢掉(不解析歌词、不打卡)。
    ///
    /// 判据跟 collector 的 isAdBreak 完全一致(`album == "" || artist == ""`),区别只在
    /// 作用域:那个只服务 Spotify 广告,这个服务信任列表。
    ///
    /// 全靠真实样本定的,四份实测:
    ///   - 酷狗音乐    artist=周杰伦     album=七里香              到 是歌
    ///   - Apple Music artist=方大同     album=Soulboy/100种生活   到 是歌
    ///   - Spotify     artist=方大同     album=Soulboy             到 是歌
    ///   - Arc 放视频  artist=""/频道名  album=**恒为空**          到 不是歌
    ///
    /// **album 是这四份样本里唯一 100% 分对的字段**。artist 单独不够:YouTube 会把**频道名**
    /// 塞进 artist(实测 `Dream in reality` / 时长 925 秒的法语 vlog),从数据形状上跟
    /// "歌手 - 歌名"无法区分;而它的 album 两次都空。代价是电台/单曲场景真音乐 App 若不报
    /// 专辑名会被误挡 —— 接受(宁可漏认,不要把视频写进永久收听历史)。
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
        // 走 isTrusted 而不是裸查 trusted[bundleID]:Safari 的播放报的是媒体代理进程
        // com.apple.WebKit.GPU,信任表里存的是宿主 com.apple.Safari,裸查永远落空 到
        // 这道守卫对 Safari 恒不生效,Safari 播非歌曲视频(album 为空)会被当成一首歌
        // (修,collector 侧 trustedPlaybackNotASong 同一个洞、同日一起修,
        // 见 system.go getAutoDetectedState 那处的完整案情)。
        guard isTrusted(bundleID, trusted: trusted) else { return false }
        func blank(_ s: String?) -> Bool {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return blank(artist) || blank(album)
    }

    // MARK: - 主动添加

    /// 用户自己从「应用程序」里挑一个 App 加进信任列表时,这一下的结果。
    ///
    /// 为什么需要它:`FeatureSettingsStore.trust` 对"已经在列表里"和"本来就是内置播放器"
    /// 都是**静默 return**。对被动发现那张卡没问题 —— 它压根不会对这两种 App 显示;但主动
    /// 挑选是用户自己走进文件选择器挑出来的,静默不动 = 一个"点了没反应"的按钮,正是这个
    /// 项目反复要避开的那种形态(见 `unknownPlayerCard` 的"点了必定没反应的卡片")。
    /// 所以判据独立成纯函数,由调用方把每一种结果都说出来。
    public enum ManualTrustOutcome: Equatable, Sendable {
        /// 可以加 —— 调用方接着走 `FeatureSettingsStore.trust`。
        case addable
        /// 已经在信任列表里。带的是当初存下来的显示名(可能是空串:当时反查不到)。
        case alreadyTrusted(name: String)
        /// 它本来就是内置播放器 —— 该去「播放器」卡里勾选,不是加进信任列表。
        case builtin(PlaybackPlayer)
        /// 挑中的就是 Lyrimuse 自己。
        case itself
    }

    /// 纯函数(信任名单和自己的 bundle id 都由调用方传入,不读这台机器上的真实配置),
    /// selftest 直接覆盖。
    ///
    /// 顺序有讲究:`builtin` 排在 `alreadyTrusted` 前面 —— 内置播放器本来就不该出现在信任
    /// 列表里(`trust` 挡着、collector 的 `resolveTrustedPlayers` 也会剔掉),真撞上了(手改过
    /// 共享文件)该说的是"它是内置的",而不是"它已经在列表里了"。
    public static func manualTrustOutcome(
        bundleID: String, trusted: [String: String], selfBundleID: String?
    ) -> ManualTrustOutcome {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selfBundleID, !selfBundleID.isEmpty, id == selfBundleID { return .itself }
        if let builtin = PlaybackPlayer.builtin(forBundleID: id) { return .builtin(builtin) }
        if let name = trusted[id] { return .alreadyTrusted(name: name) }
        return .addable
    }
}
