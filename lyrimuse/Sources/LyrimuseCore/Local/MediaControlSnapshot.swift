import Foundation

// 镜像 `media-control get` 的 JSON 输出,只取本地播放数据源需要的那几个字段——
// collector/system.go 的 getState() 用的是同一条命令,同样只关心这几个字段。
public struct MediaControlSnapshot: Decodable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: Double?
    public let elapsedTime: Double?
    public let playing: Bool?
    public let playbackRate: Double?
    // media-control 自己算好的"这个 Now Playing 会话是不是 Apple Music"标记——系统级
    // Now Playing 是任何注册了 MPNowPlayingInfoCenter 的 App 都能占用的(网页视频、
    // Safari/Chrome 里的播放器等),只有 Apple Music 才该算,不能把当前系统里随便谁在放
    // 的东西当成这个 App 的"正在播放"。
    public let isMusicApp: Bool?
    // 这次快照实际匹配到的播放器 bundle id——Apple Music 走 AppleScript 时 JS 脚本自己
    // 字面量给"com.apple.Music";QQ音乐/网易云音乐/Spotify/.auto 走 media-control 时是
    // 它自己报的 bundleIdentifier(见 fetchRawMediaControlSnapshot)。补上——
    // 供 LocalPlaybackSource 判断"这次是不是 Spotify 在报告"(用于 Spotify 广告插播
    // 检测),不参与 trackKey/既有逻辑,纯附加信息。
    public let bundleIdentifier: String?
    // media-control 原始的锚点 elapsedTime(未经 livePositionSeconds 派生;AppleScript 路径为 nil)。
    // 只用来判"这个锚点是不是开播那个":0 = 开播锚点;>0 = 播放器后来重新发布的锚点(暂停冻结 /
    // 恢复 / 拖动)。Spotify 自然切歌偏置只属于开播锚点,见 LocalPlaybackSource.biasSurvivesAnchor
    //。纯附加信息,不参与 trackKey/既有逻辑。
    public let anchorElapsedTime: Double?
    /// 这是电台 / 直播流吗。判据是 media-control 载荷里的 `radioStationHash` 非空 ——
    /// 一个确定的字段,不用靠"歌手为空""时长特别长"这类启发式猜。
    ///
    /// 为真时 `duration` 与 `elapsedTime` **都已经被换掉**:系统那两个值报的是整档节目而不是当前
    /// 这首歌(实测见 `RadioTrackClock` 头注),所以 duration 置 nil(未知),elapsedTime 换成
    /// `RadioTrackClock` 自己按曲目边界起的表。下游拿到的因此是一份正常的单曲快照,不需要各自再判一次。
    ///
    /// 纯 JXA 路(fetchAppleMusicSnapshot)拿不到这个字段 —— AppleScript 问 Music.app 要不到
    /// MediaRemote 独有的键。设置里**只**选了 Apple Music 时走的正是那条路,之前
    /// 电台在这一种配置下完全不生效;现在那条路按曲目探一次 media-control 把判据补回来
    /// (见 `MediaControlClient.radioAwareAppleMusicSnapshot`),见 02 章「电台」一节。
    public let isRadio: Bool?
    /// 这份读数是什么时候读到的(Spotify 的 AppleScript 那份与酷狗 / Safari 的 media-control 那份填,见 `MediaControlClient.fetchSpotifySnapshot` / `stampsCaptureTime`)。
    /// 读数在后台读到、`LocalPlaybackSource.apply` 在主线程处理,主线程卡半秒多时读数会被记成"半秒前的位置",
    /// 精确档伺服一拍就往回拽。apply 按它把读数补到处理那一刻。nil = 按处理时刻算(其它来源)。
    public var capturedAt: Date? = nil
    /// 这份读数的位置比原始锚点外推多补了多少秒(酷狗自然切歌,见 `MediaControlClient.resetAnchorStartCorrection`)。
    /// `elapsedTime` 已经含着它,`anchorElapsedTime` 仍是原始值;App 据此把同一段修正写进偏置文件给 collector。
    public var anchorStartCorrection: Double? = nil
    /// Music.app 把这一条归为 MV(JXA 读 `media kind` == "music video")。只有 Apple Music 的 JXA 快照填;
    /// media-control 的 `mediaType` 对 MV 也报 Music,认不出来(见 02 章决策 33)。只用来显示,见
    /// `LocalPlaybackSource.isMusicVideo`。`with…` 系列副本不带它:那几条路(署名 / 专辑 / 试听段 / 电台)都不经过 Apple Music 的 MV。
    public var isMusicVideo: Bool? = nil

    public var trackKey: String { Self.trackKey(artist: artist, title: title) }

    /// 曲目身份——判「换歌了没有」和「这份封面属于哪一首」都用它，两处必须同一把尺子。
    ///
    /// 通常就等于 `trackKey`。但**署名不可信的播放器**（酷狗 3.3.2 拿当前这句歌词冒充
    /// artist）要把署名整个剔出去：真署名由 collector 单向发布，而它 5 秒一拍、还要读
    /// 播放器自己的 plist 才出得来，比 App 的轮询慢一截 —— 换歌头几秒 App 只拿得到脏署名。
    /// 让它参与身份，一首歌里身份就会抖三四次（实测「锁 (R&B版)」一首歌内
    /// `track changed` 触发 4 次：正确 → 版权声明行 → 歌词行 → 正确），而封面取图的完成
    /// 回调正是拿身份核对的（`guard expectedKey == self.lastKey`），每次都被丢掉 ——
    /// 表现就是这个播放器**永远没有封面**，而且日志里一个字都没有。
    ///
    /// **不要拿时长补进来**当区分度：换歌那一拍载荷里常常还没有 duration（实测
    /// `dur=None` 能持续好几拍），补上它等于又引入一次身份变化，白费。代价是同名不同歌
    /// 会撞（张学友和李佳薇都有《甲乙丙丁》）——要连着播两首同名的才撞得上，撞上的后果是
    /// 歌词没跟着刷新，比没有封面轻。
    /// 委托给封面核对用的**同一个**函数，两边是同一把尺子这件事因此是结构上的，
    /// 不是靠两处各写一遍、指望它们保持一致。
    public var identityKey: String {
        PlayerArtistFix.correctedTrackKey(bundle: bundleIdentifier, artist: artist, title: title)
    }

    // 抽成静态函数是给封面取图那条路复用的:fetchArtwork() 的返回里要带上"这份封面
    // 属于哪首歌"(用 get --now 载荷里自己的 artist/title 算),LocalPlaybackSource
    // 拿它跟当前曲目的 trackKey 比对,推导方式必须跟这里逐字符一致,不能各写一份。
    public static func trackKey(artist: String?, title: String?) -> String {
        "\(artist ?? "")|\(title ?? "")"
    }

    /// 回放测试造快照用(逐字段的 memberwise init 是 internal 的)。
    public static func forReplay(
        title: String?, artist: String?, album: String? = nil, duration: Double?, elapsedTime: Double?,
        playing: Bool?, playbackRate: Double? = 1, bundleIdentifier: String?, anchorElapsedTime: Double?,
        isRadio: Bool? = nil, capturedAt: Date? = nil, anchorStartCorrection: Double? = nil
    ) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: album, duration: duration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: true, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime, isRadio: isRadio, capturedAt: capturedAt,
            anchorStartCorrection: anchorStartCorrection)
    }

    /// 换掉专辑名的副本。唯一的用处是给 YouTube Music **每条队列第一首**
    /// 补上专辑名 —— 那些歌 MediaSession 里的 album 是空的,但页面上有,见
    /// `YouTubeMusicAdProbe.albumPatch`。
    ///
    /// 写成显式方法而不是就地用合成的 memberwise init:字段有十个,memberwise 调用点
    /// 长得看不出"只改了一个字段",而且以后加字段时那种调用点会静默漏改。
    /// 换掉位置和读数时刻的副本。唯一的用处是切歌间隙保持(`PlayerGapHold`):那几秒交回的是上一首的最后一份快照,
    /// 位置要外推到此刻。写成显式方法而不是就地用合成的 memberwise init,理由同 `withAlbum`。
    public func withElapsed(_ newElapsed: Double?, capturedAt newCapturedAt: Date) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: album, duration: duration,
            elapsedTime: newElapsed, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime, isRadio: isRadio, capturedAt: newCapturedAt,
            anchorStartCorrection: anchorStartCorrection)
    }

    public func withAlbum(_ newAlbum: String) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: newAlbum, duration: duration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime, isRadio: isRadio, capturedAt: capturedAt,
            anchorStartCorrection: anchorStartCorrection)
    }

    /// 换掉署名的副本。唯一的用处是酷狗 3.3.2 把**当前这一句歌词**发布成 artist —— 真署名
    /// 由 collector 从播放器自己的容器里读出来发布,App 读那条通道换回去,见 `PlayerArtistFix`。
    /// 两边必须换成同一个值,否则歌词缓存的 key 对不上。
    /// 写成显式方法而不是就地用合成的 memberwise init,理由同 `withAlbum`。
    public func withArtist(_ newArtist: String) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: newArtist, album: album, duration: duration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime, isRadio: isRadio, capturedAt: capturedAt,
            anchorStartCorrection: anchorStartCorrection)
    }

    /// 换掉曲名的副本。唯一的用处是信任进来的其他播放器把歌词写进 artist、把「歌名 - 歌手」
    /// 整串写进 title —— collector 拆出真曲名发布,App 读 `PlayerArtistFix` 换成同一个。
    /// 写成显式方法而不是就地用合成的 memberwise init,理由同 `withAlbum`。
    public func withTitle(_ newTitle: String) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: newTitle, artist: artist, album: album, duration: duration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime, isRadio: isRadio, capturedAt: capturedAt,
            anchorStartCorrection: anchorStartCorrection)
    }

    /// 换掉时长的副本。唯一的用处是电台:系统报的 `duration` 是**整档节目**的
    /// (实测 3390.122s),而位置已经换成单曲口径,分母不跟着换就会显示成「2:29 / 56:30」。
    /// 真曲长由 collector 从 Apple 目录查到、写进歌词缓存,App 在 `LocalPlaybackSource.apply`
    /// 里读出来替换。写成显式方法而不是就地用合成的 memberwise init,理由同 `withAlbum`。
    public func withDuration(_ newDuration: Double) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: album, duration: newDuration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime, isRadio: isRadio, capturedAt: capturedAt,
            anchorStartCorrection: anchorStartCorrection)
    }

    /// 汽水非会员试听换回原曲口径的副本:时长换成整首,位置与原始锚点都加上试听段起点。
    /// 唯一的用处是 `PlayerPreviewFix`。写成显式方法而不是就地用合成的 memberwise init,理由同 `withAlbum`。
    public func withPreviewOffset(start: Double, fullDuration: Double) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: album, duration: fullDuration,
            elapsedTime: elapsedTime.map { $0 + start }, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime.map { $0 + start }, isRadio: isRadio, capturedAt: capturedAt,
            anchorStartCorrection: anchorStartCorrection)
    }

    /// 换成电台口径的副本。位置**和锚点**都换成 `RadioTrackClock` 那块按曲目边界
    /// 起的单曲表,并置上 `isRadio` —— 走 media-control 的路径在
    /// `MediaControlClient.fetchRawMediaControlSnapshot` 里就地构造出同样的形状,这个方法是给
    /// 「只勾了 Apple Music」那条纯 AppleScript 路径补的(见
    /// `MediaControlClient.radioAwareAppleMusicSnapshot`)。锚点跟着换的理由与那边逐字相同:
    /// 留着原始值会让下游"锚点是不是开播那个"的判定按整档节目的钟去解读,自相矛盾。
    ///
    /// `duration` **原样不动**:系统那份报的是整档节目(实测 3390.122s),但置 nil 会让
    /// `LocalPlaybackSource.apply` 建不起进度锚点、整档节目都没有歌词(真踩过)。
    /// 真曲长由 collector 从 Apple 目录查到写进歌词缓存,App 在 apply 里读出来替换。
    /// 写成显式方法而不是就地用合成的 memberwise init,理由同 `withAlbum`。
    /// 标成电台、位置和锚点原样保留。给「系统报单曲位置」的那种台用(RadioTrackClock.State.perTrack),
    /// 那种台的位置以系统 / AppleScript 读数为准,不换成单曲表。
    public func markedRadio() -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: album, duration: duration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime, isRadio: true, capturedAt: capturedAt,
            anchorStartCorrection: anchorStartCorrection)
    }

    public func withRadio(position: Double) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: album, duration: duration,
            elapsedTime: position, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: position, isRadio: true, capturedAt: capturedAt,
            anchorStartCorrection: anchorStartCorrection)
    }
}
