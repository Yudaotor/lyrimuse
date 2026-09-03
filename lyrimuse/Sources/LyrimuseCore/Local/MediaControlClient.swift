import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "media-control")

// 两条完全独立的读取路径,按 PlaybackPlayerPreference.selected(2026-09-01 起可多选)
// 分派:
//
// - Apple Music:用 AppleScript(JXA)直接问 Music.app 本身要"现在在放什么",不依赖外部
//   `media-control`(需要 brew install,自带一份 MediaRemoteAdapter.framework + 一段
//   Perl 脚本去访问私有 MediaRemote 框架,没有文档、可能随系统版本失效)。两者需要的都
//   是同一个"自动化"权限(MusicAutomationPermission),换成 AppleScript 这条苹果官方
//   支持、系统自带的路径,不需要用户再多装一个 Homebrew 包。player position 是
//   Music.app 自己实时算的播放位置(精确到 ~0.1s),不是 media-control 那个会在稳定
//   播放期间整段冻结不动的 elapsedTime。
//
// - QQ 音乐/网易云音乐:用 `sdef`/PlistBuddy 核实过,两者都完全没有 AppleScript 支持
//   (没有 .sdef 文件,也没开 NSAppleScriptEnabled)——AppleScript 这条路对它们都是死路,
//   只能改走系统级 MediaRemote(经内置的 `media-control` 二进制读,build.sh 从 Homebrew
//   拷贝进 app bundle,不需要用户自己装任何东西,见该文件注释;BSD-3-Clause 开源,
//   https://github.com/ungive/media-control)。实测坐实两个细节:①原始 elapsedTime/
//   timestamp 字段在稳定播放期间会整段冻结(跟旧版 media-control 用在 Music.app 上
//   时一样的坑),但 `--now` 参数给的 elapsedTimeNow 是内部按真实时钟外推的,实测跨
//   2 分钟窗口误差在 0.5 秒以内,足够覆盖现有歌词同步引擎 700ms 的匹配容差;②读取
//   全程没有触发任何系统权限弹窗,跟 Apple Music 这条路要的"自动化"权限完全无关。
//   MediaRemote 是系统级的、App 无关的机制,任何注册了 MPNowPlayingInfoCenter 的
//   App(网页视频/Safari/另一个播放器等)都可能占用"当前正在播放"这个位置,必须靠
//   bundleIdentifier 精确核对确实是当前选定的这个播放器本身在报告,见
//   PlaybackPlayer.bundleIdentifier。
public enum MediaControlClient {
    /// 状态查询的超时。这是 2 秒一轮的热路径,正常几十毫秒就回来;它卡住,悬浮歌词
    /// 就跟着停住,所以这道闸比别处都要紧。
    static let snapshotTimeout: TimeInterval = 5
    /// 取封面的超时给得宽一些 —— 封面 base64 有几百 KB,而且它不在每轮都跑。
    static let artworkTimeout: TimeInterval = 10


    /// players 是当前选中的播放器集合(2026-09-01 起可多选,取代原来的单值 `player:`
    /// 参数)。三条路径,按优先级(跟 collector 侧 system.go 的 getState() 是同一套设计,
    /// 两侧必须同步维护):
    ///   - 选了「自动识别」(不管是否同时还勾了别的具体播放器,auto 是超集)→
    ///     fetchAutoDetectedSnapshot;
    ///   - 恰好只选了 Apple Music 一个、没有 auto → 跳过 media-control,直接走
    ///     fetchAppleMusicSnapshot 的 AppleScript 路径(跟单选年代完全一样,不多背一次
    ///     子进程往返);
    ///   - 其它情况(单选或多选了 QQ音乐/网易云/Spotify/酷狗中的若干个,没有 auto)→
    ///     fetchMultiSelectedSnapshot,核对 media-control 报的系统级 Now Playing 焦点是不是
    ///     落在选中的这个子集里。
    public static func fetchSnapshot(players: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected) -> MediaControlSnapshot? {
        if players.contains(.auto) { return fetchAutoDetectedSnapshot() }
        if players == [.appleMusic] { return fetchAppleMusicSnapshot() }
        guard !players.isEmpty else { return nil }
        return fetchMultiSelectedSnapshot(players)
    }

    private static let script = """
    (() => {
        const Music = Application("Music");
        try {
            if (!Music.running()) return JSON.stringify(null);
        } catch (e) {
            return JSON.stringify(null);
        }
        let state;
        try {
            state = Music.playerState();
        } catch (e) {
            return JSON.stringify(null);
        }
        if (state === "stopped") return JSON.stringify(null);
        let track;
        try {
            track = Music.currentTrack;
            if (!track.exists()) return JSON.stringify(null);
        } catch (e) {
            return JSON.stringify(null);
        }
        try {
            return JSON.stringify({
                title: track.name(),
                artist: track.artist(),
                album: track.album(),
                duration: track.duration(),
                elapsedTime: Music.playerPosition(),
                playing: state === "playing",
                playbackRate: state === "playing" ? 1 : 0,
                isMusicApp: true,
                bundleIdentifier: "com.apple.Music"
            });
        } catch (e) {
            return JSON.stringify(null);
        }
    })()
    """

    // 失败(没有"自动化"权限/Music.app 没在运行/没有曲目在加载/JSON 解析失败)一律
    // 返回 nil,不抛出——上层按"这次没拿到数据,下一轮再试"处理,理由跟旧版一致。
    // 没有权限时 osascript 会返回非零退出码(而不是抛出 Swift 异常),同样落进
    // `guard terminationStatus == 0` 这条分支,不需要单独处理。
    private static func fetchAppleMusicSnapshot() -> MediaControlSnapshot? {
        guard let r = ProcessRunner.run(
            "/usr/bin/osascript", ["-l", "JavaScript", "-e", script],
            timeout: MusicPlaybackController.appleScriptTimeout),
            r.succeeded
        else { return nil }
        return try? JSONDecoder().decode(MediaControlSnapshot.self, from: r.stdout)
    }

    // media-control 的原始输出形状(只取用得到的字段)——跟 MediaControlSnapshot 不能
    // 直接共用同一个 Decodable:elapsedTime/timestamp 会冻结(见文件顶部注释),真正
    // 拿来当"当前位置"用的是 elapsedTimeNow,需要在构造 MediaControlSnapshot 时手动
    // 做一次字段搬运,不是简单的一比一字段映射。
    private struct RawPayload: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let bundleIdentifier: String?
        let duration: Double?
        let elapsedTime: Double?
        let elapsedTimeNow: Double?
        let playing: Bool?
        let playbackRate: Double?
        /// elapsedTime 是"在这一刻"的位置。ISO8601(带 Z),用来在 elapsedTimeNow 不可信时
        /// 自己补算 —— 见 livePositionSeconds。
        let timestamp: String?
    }

    // media-control 不是单个独立二进制——可执行文件靠相对路径找同一次 Homebrew 安装
    // 里的 Perl 适配脚本和 MediaRemoteAdapter.framework(build.sh 把 bin/+lib/+
    // Frameworks/ 整棵相对路径子树原样搬进 Contents/Resources/media-control/,详见
    // build.sh 那段注释),不能用 Bundle.main.path(forResource:) 那套只找单个文件的
    // API,直接从 Bundle.main.resourcePath 拼这条固定子路径。同目录的
    // MusicPlaybackController(发播放控制指令,同样需要这个二进制)也要用这同一条
    // 路径,公开出去两边共用一份解析逻辑,不重复各写一份。
    public static func binaryPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else {
            logger.error("app bundle resourcePath unavailable")
            return nil
        }
        let binaryPath = resourcePath + "/media-control/bin/media-control"
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            logger.error("media-control binary not found in app bundle")
            return nil
        }
        return binaryPath
    }

    // QQ 音乐/网易云音乐/Spotify 共用这同一份实现,只是要核对的 expectedBundleID
    // 不同(见 fetchSnapshot 的 switch)——真正跑 media-control 子进程、解析原始输出的
    // 逻辑收在 fetchRawMediaControlSnapshot 里,这里只负责核对 bundle id 对不对得上。
    private static func fetchMediaControlSnapshot(expectedBundleID: String) -> MediaControlSnapshot? {
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot(), bundleID == expectedBundleID else {
            // bundleIdentifier 对不上:系统当前的 Now Playing 是别的 App(网页视频/
            // Safari/另一个播放器等),不是当前选定的这个——不能把它当成这个播放器的
            // "正在播放"。
            return nil
        }
        return snapshot
    }

    // fetchMultiSelectedSnapshot 是"显式多选了若干个具体播放器、没有勾自动识别"的读取
    // 路径(2026-09-01 加)——跟 fetchAutoDetectedSnapshot 同一套"系统级 Now Playing 只有
    // 一个焦点,问 media-control 一次就知道是谁"的机制,区别只在准入名单:这里认的是
    // players 里用户这次选中的那几个,**加上**信任列表(2026-09-01 补,见
    // TrustedPlayers.isTrusted 的注释——最典型场景是「网页播放器」卡"配对浏览器"这个
    // 动作,一步自动信任+配对,跟"选没选自动识别"是两件独立的事,不该因为没勾自动识别
    // 就让配对形同虚设)。单选且未配对任何浏览器时,这条路径跟旧版
    // fetchMediaControlSnapshot(expectedBundleID:) 行为等价,那个函数继续保留、单独调用时
    // 行为不变,fetchSnapshot() 本身不再直接调用它。
    private static func fetchMultiSelectedSnapshot(_ players: Set<PlaybackPlayer>) -> MediaControlSnapshot? {
        let acceptedBundleIDs = Set(players.map(\.bundleIdentifier))
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot() else { return nil }
        if !acceptedBundleIDs.contains(bundleID) {
            guard TrustedPlayers.isTrusted(bundleID) else { return nil }
            // 走信任列表这条路进来的(不是用户在「播放器」卡里选中的具体播放器)要多过
            // 一道"这是不是一首歌"的守卫——跟 fetchAutoDetectedSnapshot 的信任分支同一套
            // 语义,理由见 TrustedPlayers.notASong 的注释(浏览器视频/播客不能被当成一首歌)。
            guard !trustedPlaybackRejected(bundleID: bundleID, snapshot: snapshot) else {
                return nil
            }
            return refinedAppleMusicSnapshotIfNeeded(
                bundleID: bundleID, snapshot: snapshotWithProbedAlbum(snapshot))
        }
        return refinedAppleMusicSnapshotIfNeeded(bundleID: bundleID, snapshot: snapshot)
    }

    // "自动识别"(PlaybackPlayer.auto)——不预先假定是哪个播放器,直接问 media-control
    // 当前系统级 Now Playing 是谁,核对 bundleIdentifier 是不是这五个已知播放器之一
    // (不是的话说明是别的不相关的 App 在报告,视为"没有可关心的正在播放")。检测到的
    // 恰好是 Apple Music 时,用 fetchAppleMusicSnapshot() 的 AppleScript 路径拿更精确的
    // 播放位置——跟手动选 Apple Music 时同等精度。
    //
    // ⚠️ 不在这次调用里同步等 AppleScript 跑完——2026-08-02 实测排查坐实:早先这里是
    // "先跑 media-control、判断出 bundleID 是 Apple Music 之后,顺序再跑一次
    // fetchAppleMusicSnapshot()",两次子进程调用纯顺序阻塞,让 .auto+Apple Music 用户
    // 单次轮询耗时翻倍(每次都要背两次子进程往返),加大了 LocalPlaybackSource.poll()
    // 那边"较慢的一次轮询被较快的下一次轮询超车"的竞态窗口。改成:这次轮询直接返回
    // media-control 已经给出的数据(elapsedTimeNow 外推,实测坐实误差在 0.5s 以内,已经
    // 在歌词引擎 700ms 匹配容差范围内,不是"不可用"的数据),同时在后台异步刷新一份更
    // 高精度的 AppleScript 快照缓存起来,供下一次轮询直接取用——代价是精度提升要晚
    // 一个轮询周期(~2s)才体现,可以忽略不计,换来的是这次轮询不需要再多等一个子进程。
    //
    // 不选择"两个子进程一开始就并发发起"这个方案:①这个方法只在真的确认 bundleID 是
    // Apple Music 之后才知道需要 AppleScript 那条路,并发发起意味着对所有 .auto 用户
    // (包括从不用 Apple Music、只用 QQ音乐/网易云音乐/Spotify 的人)每次轮询都无条件多
    // 起一次 AppleScript 子进程,而 AppleScript 首次对 Music.app 发送 Apple Event 可能
    // 触发一次"自动化"权限的系统弹窗——对完全不相关的播放器用户凭空弹出这个权限对话框
    // 是不可接受的副作用;②LyrimuseCore 这一层刻意不引入 AppKit(见 Package.swift 的
    // 单向依赖注释),没有零成本的"Music.app 是否在跑"这类进程内检测手段能在不额外
    // fork 子进程的前提下提前避开①这个问题。后台缓存刷新的方案完全规避了这两个顾虑。
    private static let appleMusicSnapshotCacheLock = NSLock()
    private static var cachedAppleMusicSnapshot: MediaControlSnapshot?
    private static var cachedAppleMusicSnapshotAt: Date?
    private static var isRefreshingAppleMusicSnapshot = false

    private static func fetchAutoDetectedSnapshot() -> MediaControlSnapshot? {
        // 闸门 = 内置五个播放器 + 用户显式信任的未知播放器(见 TrustedPlayers)。
        // 跟 collector 的 isAcceptedPlayerBundleID 是同一套语义,两侧必须同时改。
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot(),
              TrustedPlayers.isAccepted(bundleID) else {
            return nil
        }
        // 信任的未知播放器再过一道"这是不是一首歌"的守卫:歌手名**或专辑名**为空的丢掉
        // (浏览器视频/播客)。见 TrustedPlayers.notASong —— 跟 collector 侧同一套语义。
        guard !trustedPlaybackRejected(bundleID: bundleID, snapshot: snapshot) else {
            return nil
        }
        return refinedAppleMusicSnapshotIfNeeded(
            bundleID: bundleID, snapshot: snapshotWithProbedAlbum(snapshot))
    }

    /// 上游报的专辑名为空时,用 YouTube Music 探针**刚刚那次**读到的那个补上(2026-09-03,
    /// 用户报「YT Music 播一张专辑时第一首不上送专辑名」)。判据是纯函数
    /// `YouTubeMusicAdProbe.albumPatch`(selftest 覆盖),这里只负责把它接上真实的探针缓存。
    ///
    /// ⚠️ **必须在 `trustedPlaybackRejected` 之后**调用,不能提前把专辑名补进去再过守卫:
    /// 那道守卫"album 为空"正是触发广告复核的唯一入口,先补上等于把广告检测整个绕过去
    /// (广告的 album 也是空的)。顺序反了不会报错,只会让广告悄悄进来。
    ///
    /// 只补内置五个播放器之外、走信任列表进来的那条路 —— 探针缓存本来也只在 YouTube Music
    /// 的标签页上才会有值(key 还带着曲目身份),但把调用点限制在这一支,读代码时不用去
    /// 推理"Apple Music 会不会被它改到"。
    private static func snapshotWithProbedAlbum(_ snapshot: MediaControlSnapshot)
        -> MediaControlSnapshot {
        let key = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        guard let album = YouTubeMusicAdProbe.albumPatch(
            reported: snapshot.album,
            reading: YouTubeMusicAdProbe.shared.cachedReading(forKey: key))
        else { return snapshot }
        return snapshot.withAlbum(album)
    }

    /// `TrustedPlayers.notASong` 的"带 YouTube Music 广告复核"版本,也是这两条取快照的
    /// 路径该用的那一个(2026-09-02)。
    ///
    /// 基础判据(artist 或 album 为空就丢)原样不动 —— 它跟 collector 侧
    /// `trustedPlaybackNotASong` 是逐字对应的一套语义。复核作为**外面一层**加上去,
    /// 只在一种情况下发生:基础判据要拒、而且唯一的理由是 album 为空(artist 非空)。
    ///
    /// 这一层是为了让 YouTube Music 能被识别 —— 它的 album **常常**是空的(不是总是,
    /// 见 `YouTubeMusicAdProbe` 头注那条订正),空的那些不复核就永远进不来
    /// (用户 2026-09-02 报的就是这个)。而不能简单免检 album,因为那一条同时也在挡广告:
    /// 实测广告的 artist 是广告主频道名、**非空**(见 `YouTubeMusicAdProbe` 头注的两条
    /// 真实样本)。
    ///
    /// 三条出口在 `YouTubeMusicAdProbe.gate` 里(纯函数、selftest 覆盖),这里只负责
    /// 把它接上真实的探针缓存。
    ///
    /// ⚠️ 2026-09-02 起「判定是广告」**不再拒**,而是放行、由
    /// `LocalPlaybackSource.isCurrentTrackAdBreak` 标成广告驱动 UI(用户要求 YT Music 的
    /// 广告也像 Spotify 那样显示「广告中」)。放行不会让广告被记录 —— 完整理由见
    /// `YouTubeMusicAdProbe.Gate.acceptAsAd` 的注释,那里也写明了 Swift 与 Go 在这一层
    /// 故意不对称。
    private static func trustedPlaybackRejected(
        bundleID: String, snapshot: MediaControlSnapshot
    ) -> Bool {
        guard TrustedPlayers.notASong(
            bundleID: bundleID, artist: snapshot.artist, album: snapshot.album) else {
            return false
        }
        // ⚠️ **Spotify 网页版广告必须在下面那道短路之前处理**(2026-09-03)。它的字段形状是
        // `title="广告" artist="" album="" duration≈30s`(现场抓的真实样本,见
        // `SpotifyWebAdProbe` 头注那张对照表)—— **artist 是空的**,而下面那行 guard 会把
        // 歌手名为空的一律丢掉,页面复核根本轮不到。后果是广告那 30 秒 App 手上一条播放数据
        // 都没有:菜单栏塌回小图标、灵动岛/悬浮窗一起消失,广告完了再弹回来。
        // (原生 Spotify 客户端不受这道闸约束 —— 内置播放器在 notASong 第一行就 return false,
        //  所以它一直是好的,只有浏览器里的 Spotify 掉在这个洞里。)
        if spotifyWebAdAccepted(bundleID: bundleID, snapshot: snapshot) { return false }
        guard !(snapshot.artist ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
            return true
        }
        let key = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        // 先踢一次(异步、不阻塞),再读缓存 —— 同步路径上绝不能等 AppleScript 往返,
        // 见 YouTubeMusicAdProbe 头注"异步 kick + 读缓存"那一节。
        YouTubeMusicAdProbe.shared.kickIfNeeded(bundleIdentifier: bundleID, key: key)
        let verdict = YouTubeMusicAdProbe.shared.cachedVerdict(forKey: key)
        return YouTubeMusicAdProbe.gate(artist: snapshot.artist, verdict: verdict) == .reject
    }

    /// 「这条是不是一段 Spotify 网页版广告,该放行并标成广告?」(2026-09-03)
    ///
    /// 三道门,全过才放行 —— 判据本体是两个纯函数(`fieldShapeNeedsProbe` / `gate`,
    /// selftest 覆盖),这里只负责把它们接上真实的配对表和探针缓存:
    ///
    /// 1. **这个浏览器配对过 spotifyWeb**。没配对就一个 AppleEvent 都不发 —— 用户没说过
    ///    "我拿这个浏览器听 Spotify",我们就不去 tell 它。
    /// 2. **字段形状是"标题非空 + 歌手为空"**。这是 Spotify 网页广告的形状,也正是下面那道
    ///    短路要丢掉的形状。⚠️ 这道门同时把 YT Music 那条探针的领地(artist 非空、album 空)
    ///    挡在外面 —— 不然配对了两个平台的浏览器(这台机器上 Safari / Arc)每一轮会背两次
    ///    osascript 往返。
    /// 3. **页面自己说此刻在放广告**(正向证据)。拿不准一律不放行 —— fail-closed 的方向是
    ///    "维持改动前的样子(丢掉)",不是"在一首真歌上贴广告标签"。
    ///
    /// 放行之后由谁标成广告:`LocalPlaybackSource` 里那套 `adByFields` 本来就认这个形状
    /// (`isSpotify && !title.isEmpty && (album 空 || artist 空)`,而 `isSpotify` 早已包含
    /// 网页版),所以这里**只要不丢**,「广告中」自然就亮了 —— 不需要再传一个标记下去。
    private static func spotifyWebAdAccepted(
        bundleID: String, snapshot: MediaControlSnapshot
    ) -> Bool {
        guard SpotifyWebAdProbe.fieldShapeNeedsProbe(title: snapshot.title,
                                                     artist: snapshot.artist) else { return false }
        let host = BrowserPositionProbe.probeTargetBundleID(forReported: bundleID)
        guard BrowserPositionProbe.shared.isPaired(bundleID: host, platformID: "spotifyWeb") else {
            return false
        }
        let key = SpotifyWebAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        SpotifyWebAdProbe.shared.kickIfNeeded(bundleIdentifier: bundleID, key: key)
        let verdict = SpotifyWebAdProbe.shared.cachedVerdict(forKey: key)
        return SpotifyWebAdProbe.gate(verdict: verdict) == .acceptAsAd
    }

    // refinedAppleMusicSnapshotIfNeeded 是 fetchAutoDetectedSnapshot/
    // fetchMultiSelectedSnapshot 共用的尾段(2026-09-01 从 fetchAutoDetectedSnapshot 内联
    // 的分支抽出来,给多选新增的 fetchMultiSelectedSnapshot 复用,不重复这段带缓存/补偿
    // 逻辑的代码):bundleID 不是 Apple Music 时原样返回 snapshot;是的话尝试借用后台
    // AppleScript 缓存的精确播放位置,见下面原有的详细注释。
    private static func refinedAppleMusicSnapshotIfNeeded(
        bundleID: String, snapshot: MediaControlSnapshot
    ) -> MediaControlSnapshot {
        guard bundleID == PlaybackPlayer.appleMusic.bundleIdentifier else { return snapshot }
        // ⚠️ 只在**正在播放**时才起这个后台 AppleScript 子进程。
        //
        // 它唯一的用途是给下面借一个更精确的 elapsedTime,而那次借用必须过
        // ageCompensatedCachedElapsed 的第一道 guard:`freshPlaying == true,
        // cachedPlaying == true`。也就是说暂停时刷出来的缓存**在结构上不可能被用到** ——
        // 位置本来就是冻结的,精度这件事没有意义。
        //
        // 改动前这里是无条件调用:挂着 Lyrimuse 但没在听的时段(Music.app 常驻很常见),
        // 每 2 秒白 fork 一个 osascript。恢复播放后的第一次轮询会因为缓存还是空的而退回
        // snapshot 自己的 elapsedTime(精度稍低但一定对应当前这首歌,见下面那段注释),
        // 第二次起就正常了 —— 拿一次轮询的精度换掉整个暂停时段的进程噪声。
        if snapshot.playing == true {
            refreshAppleMusicSnapshotCacheInBackground()
        }
        appleMusicSnapshotCacheLock.lock()
        let cached = cachedAppleMusicSnapshot
        let cachedAt = cachedAppleMusicSnapshotAt
        appleMusicSnapshotCacheLock.unlock()
        // 只在缓存快照确认是"同一首歌"(标题+歌手都对得上)时才借用它更精确的
        // elapsedTime,其它字段一律用 media-control 这次刚给的最新值,不把整份缓存快照
        // 原样顶替上去——换歌恰好发生在"上一次后台刷新"和"这一次轮询"之间的这一小段
        // 窗口里,缓存里可能还是上一首歌的数据:如果直接整体替换,会在下一次后台刷新
        // 追上之前,把上一首歌的标题/播放位置错当成新歌的显示出来(进度条突然跳到中段
        // 这种更明显的错误);现在缓存不匹配时老老实实退回 snapshot 自己的 elapsedTime
        // (精度稍低,但一定对应当前这首歌),精度让位于正确性。
        guard let cached, cached.title == snapshot.title, cached.artist == snapshot.artist,
              let compensated = ageCompensatedCachedElapsed(
                  cachedElapsed: cached.elapsedTime, cachedPlaying: cached.playing,
                  cachedRate: cached.playbackRate, cachedAt: cachedAt,
                  freshElapsed: snapshot.elapsedTime, freshPlaying: snapshot.playing
              ) else {
            return snapshot
        }
        return MediaControlSnapshot(
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            duration: snapshot.duration,
            elapsedTime: compensated,
            playing: snapshot.playing,
            playbackRate: snapshot.playbackRate,
            isMusicApp: snapshot.isMusicApp,
            bundleIdentifier: snapshot.bundleIdentifier
        )
    }

    // 借用后台 AppleScript 缓存快照的 elapsedTime 之前必经的补偿+核对,纯函数,
    // selftest 直接覆盖。2026-08-04 实测排查坐实的真实回归(这一层 2026-08-02 引入
    // 异步缓存时埋下):缓存里存的是"抓取那一刻"的播放位置,轮询借用它时读数已经老了
    // 一整个后台刷新周期(实测恒定 ~1.8s),不补偿就直接当"当前位置"用,等于把整条本地
    // 展示链(悬浮窗/灵动岛/歌词窗口)的时间基准整体拖慢 ~1.8s——超过歌词引擎 700ms 的
    // 匹配容差,肉眼可见"本地歌词比网页慢"。更隐蔽的是它跟 LocalPlaybackSource.
    // resolvePositionSeconds 的 2s seek 容差咬合出"有时正常有时慢"的双稳态:锚点如果
    // 恰好在"没借到缓存"的一轮(换歌瞬间)播种,预测值正确,之后每轮落后 1.8s 的借用值
    // 都在 2s 容差内被忽略,表现正常;锚点一旦在借用值上播种(实测单曲循环重启后必然
    // 发生:缓存还是上一轮循环的位置,先触发一次 JUMP 重锚到落后值),就整体慢 1.8s 且
    // 每轮借用值继续喂进来、永远纠不回去。修法:按"读数年龄 × 播放速率"把缓存值外推到
    // 当下再用,并跟这次 media-control 的新鲜读数(elapsedTimeNow,实测误差 ≤0.5s)做
    // 合理性核对——补偿后仍差 2s 以上,只可能是缓存跨越了一次不连续(seek/单曲循环
    // 重启),这时缓存不可信,退回新鲜读数(返回 nil = 调用方不借用)。
    public static func ageCompensatedCachedElapsed(
        cachedElapsed: Double?, cachedPlaying: Bool?, cachedRate: Double?, cachedAt: Date?,
        freshElapsed: Double?, freshPlaying: Bool?, now: Date = Date()
    ) -> Double? {
        // 暂停态不借用:当前暂停时 media-control 的冻结 elapsedTime 本身就是精确值;
        // 缓存是暂停态读数时无法按速率外推(刚恢复播放的这段年龄里位置没在走)。
        guard freshPlaying == true, cachedPlaying == true,
              let cachedElapsed, let cachedAt else { return nil }
        let age = now.timeIntervalSince(cachedAt)
        guard age >= 0 else { return nil }
        var rate = cachedRate ?? 1
        if rate <= 0 { rate = 1 } // 切歌加载瞬间短暂报 0,语义上按播放中(1)计,跟 collector/lb.go 同一处理
        let extrapolated = cachedElapsed + age * rate
        if let freshElapsed, abs(extrapolated - freshElapsed) > 2.0 { return nil }
        return extrapolated
    }

    // 后台线程刷新 cachedAppleMusicSnapshot——同一时刻只允许一份刷新在飞,避免每 2 秒
    // 一次轮询如果刷新本身耗时超过 2 秒(理论上不该发生,但没有硬保证),背靠背堆积出
    // 越来越多同时运行的 AppleScript 子进程。isRefreshingAppleMusicSnapshot 和
    // cachedAppleMusicSnapshot 都可能被轮询线程(读)和这个后台线程(写)同时访问,用同
    // 一把 NSLock 保护;这里没有用 actor/async——MediaControlClient 整个类型是同步、
    // 无状态的静态方法集合(在这次改动前完全没有可变状态),用 Thread 而不是
    // Task.detached 是因为这层文件里其它子进程调用都是纯 Foundation 同步阻塞风格,不
    // 引入 Swift Concurrency 到这个原本纯同步的类型里,保持风格一致。
    private static func refreshAppleMusicSnapshotCacheInBackground() {
        appleMusicSnapshotCacheLock.lock()
        guard !isRefreshingAppleMusicSnapshot else {
            appleMusicSnapshotCacheLock.unlock()
            return
        }
        isRefreshingAppleMusicSnapshot = true
        appleMusicSnapshotCacheLock.unlock()
        Thread.detachNewThread {
            let result = fetchAppleMusicSnapshot()
            let capturedAt = Date()
            appleMusicSnapshotCacheLock.lock()
            cachedAppleMusicSnapshot = result
            cachedAppleMusicSnapshotAt = capturedAt
            isRefreshingAppleMusicSnapshot = false
            appleMusicSnapshotCacheLock.unlock()
        }
    }

    // 真正调用 media-control 子进程、解析原始输出——fetchMediaControlSnapshot(核对
    // 单一 expectedBundleID)和 fetchAutoDetectedSnapshot(核对"是不是这几个已知播放器
    // 之一")共用同一份子进程调用逻辑,只是各自拿到 bundleID 之后核对的规则不同。
    // 封面图——跟上面 fetchSnapshot()/fetchRawMediaControlSnapshot() 完全独立的一条轻量
    // 取图路径,只在换歌那一刻调一次(见 LocalPlaybackSource.apply()/
    // fetchArtworkForCurrentTrack()),不掺进每 2 秒一次的常规轮询,避免每次都解码几百
    // KB 的 base64 图片数据。这里刻意统一走 media-control——不管当前选的是哪个播放器,
    // 包括 Apple Music:实测坐实(`media-control get --now`,不带 --no-artwork)对 Apple
    // Music 的系统级 Now Playing 会话同样能读到 artworkData 字段(systemwide
    // MediaRemote,不是只有 QQ音乐/网易云音乐才有),不需要另外给 Apple Music 走
    // AppleScript 的 track.artworks() 去拿封面(那条路要把二进制图片数据想办法序列化过
    // JSON,明显更麻烦,而且完全没必要碰这个项目里唯一对播放位置精度敏感、已经调好的
    // AppleScript 集成)。
    // trackKey:这份封面在 get --now 载荷里对应的曲目标识(跟 MediaControlSnapshot.trackKey
    // 同一套推导)。切歌瞬间系统侧 Now Playing 可能还没更新完,这一把抓到的会是**上一首**的
    // 完整条目(旧标题+旧封面)——载荷自己的 artist/title 是识别这种情况的唯一依据,调用方
    // 拿它跟当前曲目比对,不匹配就当"还没更新好"重试,而不是把上一首的封面错挂到新歌上
    // (2026-08-17 用户报网易云云盘歌"沿用上一首的封面"后补上)。
    public static func fetchArtwork(players: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected) -> (data: Data, mimeType: String, trackKey: String)? {
        guard let binaryPath = binaryPath() else { return nil }
        // 这次不传 --no-artwork——就是为了要这份数据,所以超时给得比状态查询宽:
        // 封面 base64 有几百 KB。
        guard let r = ProcessRunner.run(
            binaryPath, ["get", "--now"], timeout: artworkTimeout),
            r.succeeded
        else { return nil }
        guard let raw = try? JSONDecoder().decode(ArtworkPayload.self, from: r.stdout),
              let bundleID = raw.bundleIdentifier,
              artworkBundleIDMatches(bundleID, players: players),
              let base64 = raw.artworkData,
              let imageData = Data(base64Encoded: base64) else {
            return nil
        }
        return (imageData, raw.artworkMimeType ?? "image/jpeg",
                MediaControlSnapshot.trackKey(artist: raw.artist, title: raw.title))
    }

    // 只取封面相关的这几个字段——跟 RawPayload 是两份独立的 Decodable(理由跟文件顶部
    // RawPayload 的注释一致:各自只镜像自己关心的那一部分 media-control 输出,不是
    // 简单的一比一字段映射)。title/artist 不是多余:它们标识这份封面属于哪首歌,见
    // fetchArtwork 返回值 trackKey 的注释。
    private struct ArtworkPayload: Decodable {
        let bundleIdentifier: String?
        let artworkData: String?
        let artworkMimeType: String?
        let title: String?
        let artist: String?
    }

    // players 里有 .auto 时没有唯一固定的目标 bundle id,核对规则跟
    // fetchAutoDetectedSnapshot 一致:只要是内置播放器之一或信任列表成员就认。否则要求
    // bundleID 精确落在 players 这个子集里——系统级 Now Playing 焦点可能被别的 App
    // (网页视频/Safari 等)抢走,不能把那份图错当成选中播放器的封面,理由跟
    // fetchMultiSelectedSnapshot 一样(2026-09-01 从单个 player 参数改成 Set)。
    private static func artworkBundleIDMatches(_ bundleID: String, players: Set<PlaybackPlayer>) -> Bool {
        if players.contains(.auto) {
            return TrustedPlayers.isAccepted(bundleID)
        }
        if players.contains(where: { $0.bundleIdentifier == bundleID }) { return true }
        // 2026-09-01 补:信任列表(网页播放器配对)在没有勾自动识别时也该被认,跟
        // fetchMultiSelectedSnapshot 是同一份判断,理由见那边的注释。
        return TrustedPlayers.isTrusted(bundleID)
    }


    /// 从 media-control 的原始字段推出"当前播放位置"(秒)。纯函数,selftest 直接覆盖。
    ///
    /// ## 为什么不能直接用 elapsedTimeNow
    ///
    /// media-control 的 `--now` 是它自己按 `elapsedTime + (now − timestamp) × playbackRate`
    /// 外推出来的。**rate 缺失(或为 0)时这个增量就是 0**,elapsedTimeNow 退化成
    /// elapsedTime 本身、一动不动。
    ///
    /// 2026-08-18 实测坐实这不是理论风险:Spotify **暂停后恢复播放**,上报里的
    /// playbackRate 变成 null 且再也不回来,于是
    ///
    /// ```
    /// 16:55:27  playing=true rate=None elapsed=178.604 elapsedNow=178.60   (Spotify 真实 178.72)
    /// 16:55:42  playing=true rate=None elapsed=178.604 elapsedNow=178.60   (Spotify 真实 194.64)
    /// ```
    ///
    /// —— 15 秒里 elapsedNow 纹丝不动。这个恒定值喂进 LocalPlaybackSource 的伺服
    /// (cleanExtrapolated 档、门槛 0.4s)之后,每一拍 reported−predicted 都在扩大、每一拍
    /// 都触发 snap 把位置往回拽,最终把位置钉死在 178.6 —— 用户看到的就是"暂停再播放之后
    /// 歌词卡在一句话上不往下走",而逐字填色还会轻微倒退(被拽回去的指纹)。
    ///
    /// ## 修法
    ///
    /// rate 缺失时按 1 补,自己套同一个公式算。实测这条路径误差是 **+0.35s 的恒定偏移**
    /// (自算 179.07/182.23/…/194.99 对 Spotify 178.72/181.88/…/194.64),常量偏移正是
    /// 伺服和 lyricsOffset 本来就能吸收的东西,比冻死好得多。
    ///
    /// rate 正常(>0)时仍然优先用 elapsedTimeNow:实测它误差 +0.03s,比自算的 +0.72s 更准
    /// (media-control 内部用的时钟基准比我们从 ISO8601 字符串反解的更精确)。
    /// 锚点"陈旧"的判定门槛:now − timestamp 超过这个值,就说明这一份读数的锚点不是
    /// 刚发布的。会刷新锚点的源在报告暂停那一刻必然带一个新鲜时间戳(暂停本身就是事件),
    /// 所以 2 秒(一个轮询周期)足够把两类源分开。
    public nonisolated static let staleAnchorAfter: TimeInterval = 2.0
    /// 报告值比"播放中最后一次算出来的位置"低这么多以上,才判定它不是暂停位置。
    /// 3 秒 > 一个轮询周期,正常暂停时两者只差一拍(≤2s),不会误判。
    public nonisolated static let frozenAnchorPauseDrop: Double = 3.0

    /// 从**被截成整秒**的锚点时间戳,恢复一个更接近真实锚点时刻的估计。
    ///
    /// 2026-08-21 实测坐实的问题(用 Apple Music 的 AppleScript 播放头当独立真值,12 个样本):
    /// media-control 的 `timestamp` 恒无小数秒,而它就是 `elapsedTimeNow` 的外推基准 ——
    /// `ts = floor(真实时刻)`,于是 `位置 + (now − ts)` **恒偏快 frac 秒**(那一轮实测
    /// +0.824s,极差只有 0.042s:同一个锚点上稳如磐石)。锚点每刷新一次这个 frac 重新掷骰;
    /// **锚点冻结的源(网页播放器/酷狗)一次掷骰锁死一整首歌**,正是用户报的"歌词进度偏慢"
    /// 的镜像现象(那边是偏慢,这边是偏快,取决于源自己的位置量化,见 noisyFloored 那段)。
    ///
    /// 恢复办法是夹逼 —— 真实时刻 τ 有三个界:
    ///   - `ts ≤ τ`         (floor 语义)
    ///   - `τ < ts + 1`     (frac < 1)
    ///   - `τ ≤ 首见时刻`    (我们不可能在它发布之前看到它)
    /// 取 `[ts, min(ts+1, 首见时刻)]` 的中点。这个式子的好处是**永远不会比现状更差**:
    ///   - 事件流即时发现(首见 − ts 很小)→ 误差 ≤ 那个间隔的一半,很小
    ///   - 只靠 2 秒轮询发现(间隔 ≥ 1)→ 退化成 `ts + 0.5`,最坏 ±0.5s,仍是现状 [0,1) 的一半
    ///
    /// 纯函数,selftest 直接覆盖。
    public nonisolated static func estimatedAnchorInstant(timestamp: Date, firstSeenAt: Date) -> Date {
        let observedGap = firstSeenAt.timeIntervalSince(timestamp)
        // 首见时刻早于时间戳(时钟回拨/解析异常)→ 不猜,原样返回。
        guard observedGap > 0 else { return timestamp }
        return timestamp.addingTimeInterval(min(1.0, observedGap) / 2)
    }

    /// 暂停时该报哪个位置。纯函数,selftest 直接覆盖。
    ///
    /// 2026-08-21 用户报「用 Arc 播放音乐时歌词进度比较慢」时查出来的连带 bug。Arc 这类
    /// 网页播放器(页面没调 `mediaSession.setPositionState()`)的锚点是**冻结**的:实测
    /// `elapsedTime` 恒等于 0、`timestamp` 恒等于开播那一刻,位置全靠 media-control 按墙钟
    /// 外推的 `elapsedTimeNow`。于是"暂停时用原始 elapsedTime"这条既有规则会让位置**直接
    /// 变成 0** —— 用户视角是"在浏览器里一按暂停,歌词跳回第一句"。
    ///
    /// 两个条件**同时**成立才判定"这个 elapsedTime 不是暂停位置",各自挡住一种误判:
    ///  - 锚点陈旧(age > staleAnchorAfter):会刷新锚点的源报暂停时时间戳是新鲜的,
    ///    这一条把它们整个排除在外 —— 也就保住了"向后 seek 之后暂停"这种合法的大幅回退。
    ///  - 报告值比播放中最后一次位置低得离谱(> frozenAnchorPauseDrop):正常暂停时
    ///    两者只差一拍;差出几十秒只可能是"报告值压根不是当前位置"(Arc 恒报 0)。
    ///
    /// 都不成立就沿用原样的 elapsedTime,行为跟改动前逐字相同。
    public nonisolated static func pausedPositionSeconds(
        elapsedTime: Double?, anchorAge: TimeInterval?, lastPlayingPosition: Double?
    ) -> Double? {
        guard let last = lastPlayingPosition else { return elapsedTime }
        guard let reported = elapsedTime else { return last }
        guard let age = anchorAge, age > staleAnchorAfter else { return reported }
        return (last - reported) > frozenAnchorPauseDrop ? last : reported
    }

    /// lastPlayingPosition:**同一首曲目**播放期间最后一次算出来的位置。只有暂停分支会用到
    /// (见 pausedPositionSeconds);默认 nil = 调用方没有这个信息,行为跟改动前一致。
    public nonisolated static func livePositionSeconds(
        playing: Bool?, elapsedTime: Double?, elapsedTimeNow: Double?,
        playbackRate: Double?, timestamp: Date?, now: Date,
        lastPlayingPosition: Double? = nil,
        firstSeenAt: Date? = nil
    ) -> Double? {
        // 暂停态不外推:elapsedTimeNow 在暂停期间**照样**按暂停前的 rate 继续涨(拿到过
        // 远超曲长的荒谬值),因为暂停本身没让 media-control 的外推基准归零。
        //
        // 但"暂停时用原始 elapsedTime"这个假设**只对会刷新锚点的源成立**(QQ/网易云/
        // Apple Music:它们暂停时会重新发布一次 elapsedTime,那个值就是暂停位置)。
        // 锚点冻结的源不成立 —— 见 pausedPositionSeconds。
        guard playing == true else {
            return pausedPositionSeconds(
                elapsedTime: elapsedTime,
                anchorAge: timestamp.map { now.timeIntervalSince($0) },
                lastPlayingPosition: lastPlayingPosition)
        }
        // 锚点已经**冻结**(不再刷新)时,不用 media-control 那个基于整秒时间戳的外推 ——
        // 它恒偏快 frac 秒且被锁死一整首歌(见 estimatedAnchorInstant)。自己按订正后的
        // 锚点时刻重算一遍。
        //
        // 只在冻结时接手,刻意不碰"每拍都在刷新锚点"的源(QQ/网易云/Spotify):它们的
        // frac 每拍重新掷骰、且各自的位置量化还会部分抵消,那条路径的参数是按实测调出来
        // 的(见 noisyFloored 那一档的注释),不该被这条顺带改掉。
        if let rate = playbackRate, rate > 0, let base = elapsedTime, let timestamp,
           let firstSeenAt, now.timeIntervalSince(timestamp) > staleAnchorAfter {
            let corrected = estimatedAnchorInstant(timestamp: timestamp, firstSeenAt: firstSeenAt)
            let aged = now.timeIntervalSince(corrected)
            if aged > 0 { return base + aged * rate }
        }
        // rate 正常时信 media-control 自己的外推(更准)。
        if let rate = playbackRate, rate > 0, let now = elapsedTimeNow { return now }
        // rate 缺失/为 0:elapsedTimeNow 已经退化成 elapsedTime,自己按 rate=1 补算。
        guard let base = elapsedTime, let timestamp else { return elapsedTimeNow ?? elapsedTime }
        let aged = now.timeIntervalSince(timestamp)
        // 负数(时钟回拨/时区解析出错)时不倒推,老老实实用基准值。
        return aged > 0 ? base + aged : base
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// media-control 的 timestamp 实测形如 "2026-08-18T08:51:46Z"(可能带小数秒),
    /// 两种都要能解 —— 带小数秒的 formatOptions 解不了不带的,所以退一次。
    /// 无小数秒的兜底 formatter。static 一份(2026-08-20 性能审计:原来每次 fallback 都
    /// 现建一个 ISO8601DateFormatter,而实测 media-control 的时间戳**恒无小数秒**——带
    /// 小数秒的那份 static 永远解不中,等于每 2s 轮询各白建一个 formatter)。顺序也换成
    /// 先试无小数秒(实测的常态),miss 再试带小数秒的,别让常态路径恒走两次解析。
    private nonisolated static let plainTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public nonisolated static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = plainTimestampFormatter.date(from: s) { return d }
        return timestampFormatter.date(from: s)
    }

    /// 此刻系统级 Now Playing 是谁在报 —— **没过任何闸**的原始观察。
    ///
    /// 存在的唯一用途是设置页那张「检测到未知播放器」的卡片:过了闸的播放器本来就能在
    /// 界面上看见,被闸挡掉的那些才需要提示用户"要不要信任它"。
    public struct UngatedNowPlaying: Sendable, Equatable {
        public let bundleID: String
        public let artist: String
        /// 发现卡要跟 notASong 用同一套判据,所以专辑名也得带出来 —— 不带的话卡片会提议
        /// 信任一条信任后必定被丢掉的播放(YouTube 视频就是 artist 有、album 空)。
        public let album: String
        public let title: String
        /// 观察到的时刻 —— 调用方据此判断这条观察是不是已经陈旧(比如播放早就停了)。
        public let at: Date
    }

    // 「同一首曲目播放期间最后一次算出来的位置」—— 只服务 pausedPositionSeconds 那一支
    // (锚点冻结的源在暂停瞬间会归零,见那边的注释)。按曲目记:换歌就作废,不让上一首的
    // 位置漏到下一首头上。
    //
    // 用锁而不是 @MainActor:fetchRawMediaControlSnapshot 是 nonisolated 的(后台线程也会
    // 走到),跟旁边 appleMusicSnapshotCacheLock / ungatedLock 同一套既有做法。
    private static let playingPositionLock = NSLock()
    nonisolated(unsafe) private static var playingPositionTrack: String?
    nonisolated(unsafe) private static var playingPositionValue: Double?

    // 「这个锚点我们第一次看到是什么时候」—— estimatedAnchorInstant 的第三个界。
    // 锚点身份 = 曲目 + elapsedTime + timestamp 三者拼起来:任一变化就是新锚点,重新计时。
    // 只留最近一个(锚点是单调更替的,不需要字典)。
    private static let anchorSeenLock = NSLock()
    nonisolated(unsafe) private static var anchorSeenKey: String?
    nonisolated(unsafe) private static var anchorSeenAt: Date?

    /// 返回这个锚点的**最早**一次目击时刻;第一次见到就把 now 记下来并返回它。
    private nonisolated static func firstSeen(anchorKey: String, now: Date) -> Date {
        anchorSeenLock.lock()
        defer { anchorSeenLock.unlock() }
        if anchorSeenKey == anchorKey, let at = anchorSeenAt { return at }
        anchorSeenKey = anchorKey
        anchorSeenAt = now
        return now
    }

    private nonisolated static func rememberedPlayingPosition(forTrack track: String) -> Double? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        guard playingPositionTrack == track else { return nil }
        return playingPositionValue
    }

    private nonisolated static func rememberPlayingPosition(_ position: Double, forTrack track: String) {
        playingPositionLock.lock()
        playingPositionTrack = track
        playingPositionValue = position
        playingPositionLock.unlock()
    }

    private static let ungatedLock = NSLock()
    nonisolated(unsafe) private static var lastUngated: UngatedNowPlaying?

    /// 最近一次观察。nil = 从没观察到过(App 刚起来、或者系统里压根没有 Now Playing)。
    public static var lastUngatedNowPlaying: UngatedNowPlaying? {
        ungatedLock.lock()
        defer { ungatedLock.unlock() }
        return lastUngated
    }

    private static func recordUngatedNowPlaying(bundleID: String, artist: String?,
                                               album: String?, title: String?) {
        guard !bundleID.isEmpty else { return }
        let observed = UngatedNowPlaying(
            bundleID: bundleID, artist: artist ?? "", album: album ?? "",
            title: title ?? "", at: Date())
        ungatedLock.lock()
        lastUngated = observed
        ungatedLock.unlock()
    }

    private static func fetchRawMediaControlSnapshot() -> (MediaControlSnapshot, String)? {
        guard let binaryPath = binaryPath() else { return nil }
        // --now 让工具自己按内部时钟外推出一个不会冻结的 elapsedTimeNow(见文件顶部
        // 注释);--no-artwork 省掉几百 KB 的 base64 封面数据,这里从不使用。
        //
        // 这是 2 秒一轮的热路径 —— 它卡住,悬浮歌词就停住。超时是这里最要紧的东西。
        guard let r = ProcessRunner.run(
            binaryPath, ["get", "--now", "--no-artwork"], timeout: snapshotTimeout),
            r.succeeded
        else { return nil }
        let data = r.stdout
        // 没有任何 App 在报告 Now Playing 时,media-control 输出字面量 "null",
        // 退出码仍是 0——JSONDecoder 对着 "null" 解码 RawPayload 会失败,走
        // `try?` 落到下面的 guard raw != nil,行为跟"没有可报告的正在播放"一致。
        // 退出码已经由上面的 r.succeeded 判过。
        guard let raw = try? JSONDecoder().decode(RawPayload.self, from: data),
              let bundleID = raw.bundleIdentifier else {
            return nil
        }
        // 把"此刻系统在报谁"原样记一笔 —— **在过闸之前**。设置页那张"检测到未知播放器"
        // 的卡片要的正是被闸挡掉的那些:过了闸的本来就能看见,挡掉的才需要提示用户。
        //
        // 挂在这个唯一的子进程调用点上,而不是让设置页自己再起一次 media-control:
        // 这是 2 秒一轮的既有热路径,顺手记一笔是零成本,而设置页开着时每 2 秒多 fork
        // 一个子进程只为了看一眼 bundle id 是纯浪费。
        recordUngatedNowPlaying(bundleID: bundleID, artist: raw.artist, album: raw.album,
                                title: raw.title)
        // elapsedTimeNow 只在真的在播放时才可信——实测坐实:一首已经暂停的歌,
        // elapsedTimeNow 仍然会按暂停前最后一次记录的 playbackRate 继续按真实
        // 时钟外推(拿到过远超歌曲时长本身的荒谬值),因为暂停这件事本身并没有让
        // media-control 内部的外推基准归零。暂停时真正正确的位置就是原始
        // elapsedTime(暂停就是"冻结在这一刻",不需要外推)。
        //
        // ⚠️ 暂停那一支现在还要一个输入:**同一首曲目**播放期间最后一次算出来的位置。
        // 锚点冻结的源(网页播放器,elapsedTime 恒 0)少了它就会在暂停瞬间归零,
        // 见 pausedPositionSeconds。按曲目记,换歌自动作废 —— 不然上一首的位置会漏到
        // 下一首头上。
        let trackKey = MediaControlSnapshot.trackKey(artist: raw.artist, title: raw.title)
        let sampledAt = Date()
        // 锚点身份三段拼:曲目 + 原始 elapsedTime + 原始时间戳字符串。任一变化 = 新锚点。
        let anchorKey = "\(trackKey)|\(raw.elapsedTime.map { String($0) } ?? "-")|\(raw.timestamp ?? "-")"
        let elapsed = Self.livePositionSeconds(
            playing: raw.playing, elapsedTime: raw.elapsedTime, elapsedTimeNow: raw.elapsedTimeNow,
            playbackRate: raw.playbackRate, timestamp: Self.parseTimestamp(raw.timestamp), now: sampledAt,
            lastPlayingPosition: Self.rememberedPlayingPosition(forTrack: trackKey),
            firstSeenAt: Self.firstSeen(anchorKey: anchorKey, now: sampledAt))
        if raw.playing == true, let elapsed {
            Self.rememberPlayingPosition(elapsed, forTrack: trackKey)
        }
        // ⚠️ 这里**不再**对 Spotify 做 JXA 直查真值的覆盖(2026-08-18 用户拍板移除)。
        // 那条路 08-14 上线、连修三轮(1.64s 恒定偏移、gapless 预载回扣、真值缓存外推)
        // 仍"经常进度不准"——osascript 往返本身有抖动,Spotify 的 playerPosition 在
        // gapless/预载场景又有自己的时钟分叉,两个噪声源叠着调,不如放弃。现在 Spotify
        // 跟 QQ 音乐/网易云走完全相同的通用路径:media-control 外推读数 + LocalPlaybackSource
        // 的 EMA 平滑/高门槛伺服(alpha 0.3、1.0s)。代价是 MediaRemote 锚点自带的
        // 固定滞后(~1.6s 量级、会话间漂移)只能靠平滑吸收,换来的是行为可预期、无子进程
        // 依赖。若要重走"问播放器拿真值"的路线,先读 git 历史里被删掉的
        // spotifyPlayerPosition/spotifyRebase 全套注释再动手。
        let snapshot = MediaControlSnapshot(
            title: raw.title,
            artist: raw.artist,
            album: raw.album,
            duration: raw.duration,
            elapsedTime: elapsed,
            playing: raw.playing,
            playbackRate: raw.playbackRate,
            // 复用这个字段原本的语义("这是当前选定播放器的一份有效快照",见
            // MediaControlSnapshot 注释)——调用方(fetchMediaControlSnapshot/
            // fetchAutoDetectedSnapshot)已经各自核实过 bundleID 是它关心的那个,
            // 这里如实置 true。
            isMusicApp: true,
            bundleIdentifier: bundleID
        )
        return (snapshot, bundleID)
    }
}
