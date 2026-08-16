import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "media-control")

// 两条完全独立的读取路径,按 PlaybackPlayerPreference.current 选择:
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


    public static func fetchSnapshot(player: PlaybackPlayer = PlaybackPlayerPreference.current) -> MediaControlSnapshot? {
        switch player {
        case .appleMusic: return fetchAppleMusicSnapshot()
        case .qqMusic, .netease, .spotify: return fetchMediaControlSnapshot(expectedBundleID: player.bundleIdentifier)
        case .auto: return fetchAutoDetectedSnapshot()
        }
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

    // "自动识别"(PlaybackPlayer.auto)——不预先假定是哪个播放器,直接问 media-control
    // 当前系统级 Now Playing 是谁,核对 bundleIdentifier 是不是这四个已知播放器之一
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
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot(),
              PlaybackPlayer.allCases.contains(where: { $0 != .auto && $0.bundleIdentifier == bundleID }) else {
            return nil
        }
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
    public static func fetchArtwork(player: PlaybackPlayer = PlaybackPlayerPreference.current) -> (data: Data, mimeType: String)? {
        guard let binaryPath = binaryPath() else { return nil }
        // 这次不传 --no-artwork——就是为了要这份数据,所以超时给得比状态查询宽:
        // 封面 base64 有几百 KB。
        guard let r = ProcessRunner.run(
            binaryPath, ["get", "--now"], timeout: artworkTimeout),
            r.succeeded
        else { return nil }
        guard let raw = try? JSONDecoder().decode(ArtworkPayload.self, from: r.stdout),
              let bundleID = raw.bundleIdentifier,
              artworkBundleIDMatches(bundleID, player: player),
              let base64 = raw.artworkData,
              let imageData = Data(base64Encoded: base64) else {
            return nil
        }
        return (imageData, raw.artworkMimeType ?? "image/jpeg")
    }

    // 只取封面相关的这几个字段——跟 RawPayload 是两份独立的 Decodable(理由跟文件顶部
    // RawPayload 的注释一致:各自只镜像自己关心的那一部分 media-control 输出,不是
    // 简单的一比一字段映射)。
    private struct ArtworkPayload: Decodable {
        let bundleIdentifier: String?
        let artworkData: String?
        let artworkMimeType: String?
    }

    // .auto 没有唯一固定的目标 bundle id,核对规则跟 fetchAutoDetectedSnapshot 一致:
    // 只要是这四个已知播放器之一就认。选了具体某个播放器时要求精确匹配——系统级 Now
    // Playing 焦点可能被别的 App(网页视频/Safari 等)抢走,不能把那份图错当成这个
    // 播放器的封面,理由跟 fetchMediaControlSnapshot 一样。
    private static func artworkBundleIDMatches(_ bundleID: String, player: PlaybackPlayer) -> Bool {
        if player == .auto {
            return PlaybackPlayer.allCases.contains { $0 != .auto && $0.bundleIdentifier == bundleID }
        }
        return bundleID == player.bundleIdentifier
    }

    /// 直接问 Spotify 自己要当前播放位置(秒)。读不到返回 nil,调用方沿用 media-control
    /// 的读数 —— 那个虽然慢 1.6 秒,但总比没有强。
    ///
    /// ⚠️ 必须先 `.running()` 再碰任何属性:JXA 里 `Application('Spotify')` 本身不会拉起
    /// App,但访问它的属性就会 —— 没开 Spotify 的用户会被莫名其妙启动一个播放器。守卫写法
    /// 跟本文件 Apple Music 那段脚本一致。
    private static func spotifyPlayerPosition() -> Double? {
        let script = """
        (() => {
            const Spotify = Application('Spotify');
            try {
                if (!Spotify.running()) return JSON.stringify(null);
            } catch (e) {
                return JSON.stringify(null);
            }
            try {
                const state = Spotify.playerState();
                if (state !== 'playing' && state !== 'paused') return JSON.stringify(null);
                return JSON.stringify({ position: Spotify.playerPosition() });
            } catch (e) {
                return JSON.stringify(null);
            }
        })()
        """
        guard let r = ProcessRunner.run(
            "/usr/bin/osascript", ["-l", "JavaScript", "-e", script],
            timeout: MusicPlaybackController.appleScriptTimeout),
            r.succeeded
        else { return nil }
        struct Payload: Decodable { let position: Double }
        guard let p = try? JSONDecoder().decode(Payload.self, from: r.stdout), p.position >= 0 else {
            return nil
        }
        return p.position
    }

    /// 最近一次成功问到的 Spotify 真值位置(见下面 truth 覆盖那段的失败退路)。
    /// 轮询线程读写,跟 Apple Music 缓存一样用锁,不引入 Swift Concurrency。
    private static let spotifyTruthLock = NSLock()
    private static var lastSpotifyTruth: (position: Double, at: Date, title: String?, playing: Bool)?

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
        // elapsedTimeNow 只在真的在播放时才可信——实测坐实:一首已经暂停的歌,
        // elapsedTimeNow 仍然会按暂停前最后一次记录的 playbackRate 继续按真实
        // 时钟外推(拿到过远超歌曲时长本身的荒谬值),因为暂停这件事本身并没有让
        // media-control 内部的外推基准归零。暂停时真正正确的位置就是原始
        // elapsedTime(暂停就是"冻结在这一刻",不需要外推)。
        var elapsed = (raw.playing == true) ? (raw.elapsedTimeNow ?? raw.elapsedTime) : raw.elapsedTime
        // Spotify 的位置改问它自己 —— MediaRemote 给 Spotify 的锚点本身就滞后,
        // 2026-08-14 实测 elapsedTimeNow 恒定落后 Spotify 报的 player position
        // 1.64 秒(波动仅 ±0.02,是固定偏移不是抖动,所以提高轮询频率没用)。
        // Apple Music 不受影响是因为它走 AppleScript 直接问 Music.app。
        //
        // ⚠️ 2026-08-17 排查"自动切歌后歌词整首偏快"补充的机制认识(实测坐实):Spotify 的
        // MediaRemote 原始 elapsedTime **恒为 0**——锚点每首歌只打一次(在曲目开始那一刻),
        // elapsedTimeNow 就是"距锚点时间戳过了多久"。所以它的准确度完全取决于那一下
        // 时间戳打得准不准,而这是**会话间漂移**的:08-14 量到恒定偏慢 1.64s,08-17 又量到
        // 偏快 ~0.1s。锚点一旦打早(比如 gapless 预载时刻早于真实出声),elapsedTimeNow 就
        // **整首歌**偏快,而且这首歌内不会自愈(锚点不重打);手动重播这首歌会重新打锚,
        // 立刻恢复正常——跟用户报的症状逐条吻合。真值覆盖在,这个漂移就露不出来;
        // 真值覆盖一旦失败,退回的就是这个不可信的值。所以:
        //   1. 失败重试一次(osascript 单次 ~100ms,偶发的 Apple Event 抖动值得一次重试);
        //   2. 两次都失败要**出声**(logger.error),不再静默退回;
        //   3. 真值跟 elapsedTimeNow 偏差超过 1 秒时记录下来 —— 那正是"锚点打歪了"的
        //      直接证据,下次用户报"偏快"时 `log show` 一眼可见。
        //
        // ⚠️ 采集器(collector/system.go)里有一份**同样的**修正。两边各自独立读
        // media-control(采集器喂 ListenBrainz/网页,这里喂桌面悬浮窗),改一边只修一半 ——
        // 上一轮就是只改了采集器,用户反馈"还是有延迟",因为悬浮窗走的正是这条路。
        if bundleID == PlaybackPlayer.spotify.bundleIdentifier {
            var truth = spotifyPlayerPosition()
            if truth == nil { truth = spotifyPlayerPosition() } // 失败重试一次,见上
            if let truth {
                if let extrapolated = elapsed, abs(extrapolated - truth) > 1.0 {
                    // .notice(默认档)才会持久化进日志存储;.info 默认只进内存缓冲,
                    // 事后 `log show` 查不到 —— 这条就是留给事后查的。
                    logger.notice("spotify anchor skew: elapsedTimeNow=\(extrapolated, format: .fixed(precision: 2)) vs playerPosition=\(truth, format: .fixed(precision: 2)) (\(extrapolated - truth > 0 ? "ahead" : "behind", privacy: .public) by \(abs(extrapolated - truth), format: .fixed(precision: 2))s)")
                }
                elapsed = truth
                spotifyTruthLock.lock()
                lastSpotifyTruth = (truth, Date(), raw.title, raw.playing == true)
                spotifyTruthLock.unlock()
            } else {
                // 两次都失败:优先按"最近一次成功的真值 + 经过的墙钟时间"外推,而不是退回
                // elapsedTimeNow —— 后者带着这首歌的锚点误差,一口吞进去就是一次跳变
                // (LocalPlaybackSource 把 Spotify 当精确源,0.15s 门槛,咬得很紧)。
                // 缓存只在"同一首歌 + 10 秒内"时可信:换歌了缓存是上一首的位置,过期了
                // 外推误差也攒大了,都退回 elapsedTimeNow 并大声记日志。
                spotifyTruthLock.lock()
                let cached = lastSpotifyTruth
                spotifyTruthLock.unlock()
                if let cached, cached.title == raw.title,
                   case let age = Date().timeIntervalSince(cached.at), age >= 0, age < 10 {
                    // 播放中按走过的时间外推;暂停时位置冻结,原样用。
                    elapsed = cached.playing ? cached.position + age : cached.position
                    logger.notice("spotify playerPosition read failed twice; using cached truth \(cached.position, format: .fixed(precision: 2)) + \(age, format: .fixed(precision: 2))s")
                } else {
                    logger.error("spotify playerPosition read failed twice with no usable cache; falling back to elapsedTimeNow=\(elapsed ?? -1, format: .fixed(precision: 2)) which may carry a per-track anchor skew")
                }
            }
        }
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
