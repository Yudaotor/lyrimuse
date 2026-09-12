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
    // 它自己报的 bundleIdentifier(见 fetchRawMediaControlSnapshot)。2026-08-03 补上——
    // 供 LocalPlaybackSource 判断"这次是不是 Spotify 在报告"(用于 Spotify 广告插播
    // 检测),不参与 trackKey/既有逻辑,纯附加信息。
    public let bundleIdentifier: String?
    // media-control 原始的锚点 elapsedTime(未经 livePositionSeconds 派生;AppleScript 路径为 nil)。
    // 只用来判"这个锚点是不是开播那个":0 = 开播锚点;>0 = 播放器后来重新发布的锚点(暂停冻结 /
    // 恢复 / 拖动)。Spotify 自然切歌偏置只属于开播锚点,见 LocalPlaybackSource.biasSurvivesAnchor
    // (2026-09-07)。纯附加信息,不参与 trackKey/既有逻辑。
    public let anchorElapsedTime: Double?
    /// 这是电台 / 直播流吗(2026-09-10)。判据是 media-control 载荷里的 `radioStationHash` 非空 ——
    /// 一个确定的字段,不用靠"歌手为空""时长特别长"这类启发式猜。
    ///
    /// 为真时 `duration` 与 `elapsedTime` **都已经被换掉**:系统那两个值报的是整档节目而不是当前
    /// 这首歌(实测见 `RadioTrackClock` 头注),所以 duration 置 nil(未知),elapsedTime 换成
    /// `RadioTrackClock` 自己按曲目边界起的表。下游拿到的因此是一份正常的单曲快照,不需要各自再判一次。
    ///
    /// ⚠️ 纯 JXA 路(fetchAppleMusicSnapshot)拿不到这个字段 —— AppleScript 问 Music.app 要不到
    /// MediaRemote 独有的键。设置里**只**选了 Apple Music 时走的正是那条路,2026-09-11 之前
    /// 电台在这一种配置下完全不生效;现在那条路按曲目探一次 media-control 把判据补回来
    /// (见 `MediaControlClient.radioAwareAppleMusicSnapshot`),见 02 章「电台」一节。
    public let isRadio: Bool?

    public var trackKey: String { Self.trackKey(artist: artist, title: title) }

    // 抽成静态函数是给封面取图那条路复用的:fetchArtwork() 的返回里要带上"这份封面
    // 属于哪首歌"(用 get --now 载荷里自己的 artist/title 算),LocalPlaybackSource
    // 拿它跟当前曲目的 trackKey 比对,推导方式必须跟这里逐字符一致,不能各写一份。
    public static func trackKey(artist: String?, title: String?) -> String {
        "\(artist ?? "")|\(title ?? "")"
    }

    /// 换掉专辑名的副本(2026-09-03)。唯一的用处是给 YouTube Music **每条队列第一首**
    /// 补上专辑名 —— 那些歌 MediaSession 里的 album 是空的,但页面上有,见
    /// `YouTubeMusicAdProbe.albumPatch`。
    ///
    /// 写成显式方法而不是就地用合成的 memberwise init:字段有十个,memberwise 调用点
    /// 长得看不出"只改了一个字段",而且以后加字段时那种调用点会静默漏改。
    public func withAlbum(_ newAlbum: String) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: newAlbum, duration: duration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime, isRadio: isRadio)
    }

    /// 换掉时长的副本(2026-09-10)。唯一的用处是电台:系统报的 `duration` 是**整档节目**的
    /// (实测 3390.122s),而位置已经换成单曲口径,分母不跟着换就会显示成「2:29 / 56:30」。
    /// 真曲长由 collector 从 Apple 目录查到、写进歌词缓存,App 在 `LocalPlaybackSource.apply`
    /// 里读出来替换。写成显式方法而不是就地用合成的 memberwise init,理由同 `withAlbum`。
    public func withDuration(_ newDuration: Double) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: album, duration: newDuration,
            elapsedTime: elapsedTime, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: anchorElapsedTime, isRadio: isRadio)
    }

    /// 换成电台口径的副本(2026-09-11)。位置**和锚点**都换成 `RadioTrackClock` 那块按曲目边界
    /// 起的单曲表,并置上 `isRadio` —— 走 media-control 的路径在
    /// `MediaControlClient.fetchRawMediaControlSnapshot` 里就地构造出同样的形状,这个方法是给
    /// 「只勾了 Apple Music」那条纯 AppleScript 路径补的(见
    /// `MediaControlClient.radioAwareAppleMusicSnapshot`)。锚点跟着换的理由与那边逐字相同:
    /// 留着原始值会让下游"锚点是不是开播那个"的判定按整档节目的钟去解读,自相矛盾。
    ///
    /// ⚠️ `duration` **原样不动**:系统那份报的是整档节目(实测 3390.122s),但置 nil 会让
    /// `LocalPlaybackSource.apply` 建不起进度锚点、整档节目都没有歌词(2026-09-10 真踩过)。
    /// 真曲长由 collector 从 Apple 目录查到写进歌词缓存,App 在 apply 里读出来替换。
    /// 写成显式方法而不是就地用合成的 memberwise init,理由同 `withAlbum`。
    public func withRadio(position: Double) -> MediaControlSnapshot {
        MediaControlSnapshot(
            title: title, artist: artist, album: album, duration: duration,
            elapsedTime: position, playing: playing, playbackRate: playbackRate,
            isMusicApp: isMusicApp, bundleIdentifier: bundleIdentifier,
            anchorElapsedTime: position, isRadio: true)
    }
}
