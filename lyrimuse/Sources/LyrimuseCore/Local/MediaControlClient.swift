import AppKit
import Foundation
import os

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "media-control")

// 读「现在在放什么」,按 PlaybackPlayerPreference.selected(可多选)分派(见 fetchSnapshot)。走 media-control 的路径上它只回答
// "现在是谁在放",认出来的播放器有自己的读法就换那条读(见 adaptedSnapshot):
//
// - Apple Music:用 AppleScript(JXA)直接问 Music.app。player position 是 Music.app 自己实时算的播放位置(精确到 ~0.1s),
//   不是 media-control 那个在稳定播放期间整段冻结的 elapsedTime。要「自动化」权限(MusicAutomationPermission)。
//
// - Spotify:同样走 AppleScript(JXA)直问 Spotify.app,它自带字典,`player position` 是它自己实时算的播放位置。media-control
//   在这条路上只回答"现在是谁在放"(以及电台那类 MediaRemote 独有的键),认出是 Spotify 之后由 `adaptedSnapshot` 整份换成
//   AppleScript 那份。它的 `duration` 是毫秒,Music.app 那份是秒。
//
// - Kaset(YouTube Music 的原生客户端):也有字典,`get player info` 一次给出曲目、时长、位置与播放状态。
//   系统 Now Playing 里它那份维护得很差(播放中交给 WebKit、换歌后常停在上一首),同样由 `adaptedSnapshot`
//   整份顶替;系统那边一拍都没有它、或者落回别的播放器暂停着的旧会话时,它开着就直接问
//   (`preferringPlayingKaset`)。解读见 KasetPlayerInfo。
//
// - VOX:有字典,歌名、歌手、专辑、位置、当前文件分开给。系统那份把歌手和专辑拼成一栏、播放中不报位置,
//   同样由 `adaptedSnapshot` 整份顶替。解读见 VoxPlayerInfo。
//
// - 洛雪音乐:用户打开了它的开放 API 时,系统那边这一拍没给出在放的歌(什么都没有、别家暂停着的旧会话、它换歌撤掉了会话)
//   就用它推的状态合成一份(`preferringLXMusicOpenAPI`),播放控制也直接发给它。
//
// - QQ 音乐/网易云音乐:两者都完全没有 AppleScript 支持(没有 .sdef 文件,也没开 NSAppleScriptEnabled),只能走系统级
//   MediaRemote(经内置的 `media-control` 二进制读,build.sh 拷贝进 app bundle,不需要用户自己装任何东西,见该文件注释;
//   BSD-3-Clause 开源,https://github.com/ungive/media-control)。原始 elapsedTime/timestamp 字段在稳定播放期间会整段冻结,
//   `--now` 给的 elapsedTimeNow 是按真实时钟外推的,跨 2 分钟窗口误差在 0.5 秒以内;读取不触发任何系统权限弹窗。
//   MediaRemote 是系统级的、App 无关的机制,任何注册了 MPNowPlayingInfoCenter 的 App(网页视频/Safari/另一个播放器等)
//   都可能占用"当前正在播放"这个位置,必须靠 bundleIdentifier 精确核对确实是当前选定的这个播放器本身在报告,见
//   PlaybackPlayer.bundleIdentifier。
public enum MediaControlClient {
    /// 状态查询的超时。这是 2 秒一轮的热路径,正常几十毫秒就回来;它卡住,悬浮歌词
    /// 就跟着停住,所以这道闸比别处都要紧。
    static let snapshotTimeout: TimeInterval = 5
    /// 上一份被接受的快照来自有 AppleScript 字典的播放器(Apple Music / Spotify / Kaset / VOX)时用这个短的:这一拍 media-control
    /// 回不来,焦点回退(snapshotAfterFocusLost)直接问播放器自己就是真值,不用干等满 snapshotTimeout(见 02 章决策 102)。
    static let snapshotTimeoutWithAppleScriptFallback: TimeInterval = 2
    /// 状态查询用时满这么久就记一行(超时也记):卡在这里的那几秒悬浮歌词是停着的,之后的回退又不留别的痕迹。
    static let slowSnapshotLogSecs: TimeInterval = 1

    /// 这一拍状态查询用哪个超时。纯函数,selftest 覆盖。
    public static func pollSnapshotTimeout(fallbackPlayer: PlaybackPlayer?) -> TimeInterval {
        switch fallbackPlayer {
        case .appleMusic?, .spotify?, .kaset?, .vox?: return snapshotTimeoutWithAppleScriptFallback
        default: return snapshotTimeout
        }
    }
    /// 取封面的超时给得宽一些 —— 封面 base64 有几百 KB,而且它不在每轮都跑。
    static let artworkTimeout: TimeInterval = 10


    /// players 是当前选中的播放器集合(可多选)。三条路径,按优先级(引擎不读播放器,这套读取只此一份):
    ///   - 选了「自动识别」(不管是否同时还勾了别的具体播放器,auto 是超集)→ fetchAutoDetectedSnapshot;
    ///   - 恰好只选了 Apple Music 一个、没有 auto → 跳过 media-control,直接走 fetchAppleMusicSnapshot 的 AppleScript 路径,
    ///     不多背一次子进程往返。外面包了一层 radioAwareAppleMusicSnapshot:电台判据是 MediaRemote 独有的字段,AppleScript
    ///     拿不到,按曲目探一次补上(详见那个函数的头注);
    ///   - 其它情况(单选或多选了 QQ音乐/网易云/Spotify/酷狗中的若干个,没有 auto)→ fetchMultiSelectedSnapshot,核对
    ///     media-control 报的系统级 Now Playing 焦点是不是落在选中的这个子集里。
    ///
    /// 走 media-control 的那两条(第一、三条)里,它只负责回答"现在是谁在放",识别出来的播放器有自己的适配方式就换那条读
    /// (见 `adaptedSnapshot`),勾没勾「自动识别」不改变这一点。
    public static func fetchSnapshot(players: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected) -> MediaControlSnapshot? {
        fetchSnapshotWithProvenance(players: players).snapshot
    }

    /// 快照是怎么来的:播放器原样报的标签(清洗后、套用引擎结论之前)、套用的是哪一版署名纠正、
    /// 以及系统信息里的三个原始标识。写播放状态文件用(见 `PlaybackStateFile`),引擎靠它们做署名纠正、
    /// 目录锚点这类判定。
    public struct SnapshotProvenance: Equatable, Sendable {
        public let bundleID: String
        public let raw: PlaybackStateFile.Tags
        public let appliedFixRev: Int64
        public let identifiers: NowPlayingIdentifiers?
    }

    /// 跟 `fetchSnapshot` 同一条路,另外交回这份快照的来源。两者在同一次调用里取,不会串到别的轮询。
    public static func fetchSnapshotWithProvenance(
        players: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected
    ) -> (snapshot: MediaControlSnapshot?, provenance: SnapshotProvenance?) {
        // 这一拍的归因从零开始记(只影响日志,不影响行为)。见 SnapshotFailure。
        setSnapshotFailure(nil)
        kasetLock.lock()
        kasetAskedThisRound = false
        kasetNotSongThisRound = false
        kasetLoadingThisRound = false
        otherPlayerLoadingThisRound = false
        kasetLock.unlock()
        let raw = rawSnapshot(players: players)
        // 三条路都要过一遍署名纠正:酷狗 3.3.2 把当前这句歌词发布成 artist,而
        // 引擎那边已经换成真署名了 —— 两边不一致的话,歌词缓存的 key 就对不上。
        // 套在这个唯一的公开出口上,下游(trackKey、缓存查询、界面)一处都不用改。
        // 见 PlayerArtistFix。
        // 汽水非会员试听换回原曲口径(见 PlayerPreviewFix);排在署名纠正之后,比对用的署名与引擎发布时一致。
        // 把「歌手 - 歌名」拼在标题里的播放器先拆回来(见 PlayerTitleSplit),Pine Player 按它开着的文件换回歌手和专辑
        // (见 PinePlayerInfo),QQ 音乐、网易云、酷狗放本机文件时按它开着的文件换成标签(见 PlayerOpenFile),排在最前。
        let fixState = PlayerArtistFix.current
        let snapshot = PlayerPreviewFix.applied(
            to: PlayerArtistFix.applied(to: PlayerOpenFile.applied(to: PlayerTitleSplit.applied(to: PinePlayerInfo.adapted(raw))), state: fixState))
        guard let raw else { return (snapshot, nil) }
        let bundleID = raw.bundleIdentifier ?? ""
        let rawTitle = raw.title ?? "", rawArtist = raw.artist ?? ""
        let identifiers = currentNowPlayingIdentifiers().flatMap {
            $0.bundleID == bundleID && $0.title == rawTitle && $0.artist == rawArtist ? $0 : nil
        }
        let provenance = SnapshotProvenance(
            bundleID: bundleID,
            raw: PlaybackStateFile.Tags(title: EnrichCacheKeys.cleanTag(rawTitle),
                                        artist: EnrichCacheKeys.cleanTag(rawArtist),
                                        album: EnrichCacheKeys.cleanTag(raw.album ?? "")),
            appliedFixRev: fixState?.updatedAt ?? 0, identifiers: identifiers)
        return (snapshot, provenance)
    }

    private static func rawSnapshot(players: Set<PlaybackPlayer>) -> MediaControlSnapshot? {
        // 这份设置不认 Kaset(没开自动识别也没勾它)时,上一次顶替系统那边的记录作废,播放控制别再发给它。
        if !players.contains(.auto), !players.contains(.kaset) { forgetKasetPreference() }
        let lxMusicWanted = players.contains(.auto) || players.contains(.lxMusic)
        if !lxMusicWanted { forgetLXMusicPreference() }
        if players.contains(.auto) {
            let found = fetchAutoDetectedSnapshot()
            noteSystemReading(found)
            return heldAcrossPlayerGap(preferringLXMusicOpenAPI(preferringPlayingKaset(found), wanted: true))
        }
        if players == [.appleMusic] { return radioAwareAppleMusicSnapshot() }
        guard !players.isEmpty else { return nil }
        let selected = fetchMultiSelectedSnapshot(players)
        noteSystemReading(selected)
        let withKaset = players.contains(.kaset) ? preferringPlayingKaset(selected) : selected
        return heldAcrossPlayerGap(preferringLXMusicOpenAPI(withKaset, wanted: lxMusicWanted))
    }

    // MARK: - 切歌间隙保持(见 PlayerGapHold)

    /// 这一拍是「播放器在放、但不是音乐」(KKBOX / Amazon 的播客单集,见 `TrustedPlayers.artistlessContent`;网易云的
    /// 播客单集,见 `NeteasePodcastQueue`;Spotify 的播客单集与 DJ 口播,见 `spotifyNoticeSaysNotMusic`;reAMP 电台流连上、攒缓冲
    /// 那几拍,见 `PlayerTitleSplit.streamPlaceholder`;Pine 放网络电台、放视频,见 `PinePlayerInfo.isNetworkRadio` / `isVideo`)就当没在放:
    /// 切歌间隙保持当场放手(不然会把上一首撑满整个窗口),调用方直接交回 nil、不退回去问别家的暂停会话。
    private static func playerContentNotMusic(bundleID: String, snapshot: MediaControlSnapshot) -> Bool {
        let artistless = TrustedPlayers.artistlessContent(bundleID: bundleID, artist: snapshot.artist,
                                                          duration: snapshot.duration, playing: snapshot.playing)
        guard artistless || neteasePodcastEpisode(bundleID: bundleID, snapshot: snapshot)
                || spotifyContentNotMusic(bundleID: bundleID, snapshot: snapshot)
                || PlayerTitleSplit.streamPlaceholder(bundleID: bundleID, title: snapshot.title, artist: snapshot.artist,
                                                      duration: snapshot.duration, playing: snapshot.playing)
                || PinePlayerInfo.isNetworkRadio(snapshot) || PinePlayerInfo.isVideo(snapshot)
        else { return false }
        setSnapshotFailure(.targetNotPlayingMusic)
        gapHoldLock.lock()
        defer { gapHoldLock.unlock() }
        if gapHoldLast?.snapshot.bundleIdentifier == bundleID {
            if let since = gapHoldingSince {
                logger.notice("now playing: gap hold ended after \(Int(Date().timeIntervalSince(since).rounded()), privacy: .public)s (next: \(bundleID, privacy: .public) is not playing music)")
            }
            gapHoldingSince = nil
            gapHoldLast = nil
        }
        return true
    }

    /// 认成网易云播客单集时打过日志的那一条(歌名),同一条只打一条。
    private static var neteasePodcastLoggedTitle: String?
    private static let neteasePodcastLogLock = NSLock()

    private static func neteasePodcastEpisode(bundleID: String, snapshot: MediaControlSnapshot) -> Bool {
        guard NeteasePodcastQueue.isEpisode(bundleID: bundleID, title: snapshot.title, artist: snapshot.artist) else {
            return false
        }
        neteasePodcastLogLock.lock()
        let log = neteasePodcastLoggedTitle != snapshot.title
        if log { neteasePodcastLoggedTitle = snapshot.title }
        neteasePodcastLogLock.unlock()
        if log {
            logger.notice("netease: podcast episode, not reported as a song track=\(snapshot.title ?? "", privacy: .public)")
        }
        return true
    }

    /// 认成 Spotify 非音乐内容时打过日志的那一条(歌名),同一条只打一条。
    private static var spotifyNotMusicLoggedTitle: String?

    private static func spotifyContentNotMusic(bundleID: String, snapshot: MediaControlSnapshot) -> Bool {
        let notice = currentSpotifyNotice()
        guard spotifyNoticeSaysNotMusic(bundleID: bundleID, snapshot: snapshot, notice: notice) else { return false }
        neteasePodcastLogLock.lock()
        let log = spotifyNotMusicLoggedTitle != snapshot.title
        if log { spotifyNotMusicLoggedTitle = snapshot.title }
        neteasePodcastLogLock.unlock()
        if log {
            logger.notice("spotify: not music (\(notice?.trackID.split(separator: ":").dropFirst().first.map(String.init) ?? "-", privacy: .public)), not reported as a song track=\(snapshot.title ?? "", privacy: .public)")
        }
        return true
    }

    /// Spotify 原生客户端这一拍放的是不是播客单集、DJ 口播这类不是音乐的内容:最近一条通知(或 AppleScript 补记的同形记录,
    /// 见 `LocalPlaybackSource.classifySpotifyViaAppleScript`)的 URI 类型说不是音乐,而且说的就是这一条(歌名对得上)。
    /// 不看在不在放:暂停着的单集同样不报。见 02 章决策 117。纯函数,selftest 覆盖。
    public nonisolated static func spotifyNoticeSaysNotMusic(bundleID: String, snapshot: MediaControlSnapshot,
                                                             notice: SpotifyNotificationHint?) -> Bool {
        guard bundleID == PlaybackPlayer.spotify.bundleIdentifier, let notice,
              notice.contentKind == .notMusic else { return false }
        return notice.matches(title: snapshot.title, artist: snapshot.artist)
    }

    /// `artistArrivesLate` 的播放器(KKBOX)开播先发一帧没有歌手的(约半秒后补齐):它在加载这一首,焦点没被别人占着。按
    /// 「在加载」交回空(留着上一首,见 `loadingGraceSeconds`),不去问别家暂停着的会话:焦点回退不问,Kaset 只在放或正要放时
    /// 才顶上来(`kasetWins`)。见 02 章决策 106。歌名还是播放器内部 id 的那一帧(`TrustedPlayers.titleIsPlaceholderID`,哪家都算)
    /// 同样是在加载这一首,一并按这一档处理。
    private static func artistNotYetReported(bundleID: String, snapshot: MediaControlSnapshot) -> Bool {
        guard TrustedPlayers.artistNotYetReported(bundleID: bundleID, artist: snapshot.artist)
                || TrustedPlayers.titleIsPlaceholderID(title: snapshot.title, album: snapshot.album) else { return false }
        setSnapshotFailure(.targetLoading)
        kasetLock.lock()
        otherPlayerLoadingThisRound = true
        kasetLock.unlock()
        return true
    }

    private static let gapHoldLock = NSLock()
    /// 上一份被采纳的快照和它读到的时刻;保持期间不更新(在放的话,位置从它还在放的最后一刻往前推)。
    private static var gapHoldLast: (snapshot: MediaControlSnapshot, at: Date)?
    /// 这一轮保持从哪一拍开始;nil = 没在保持。
    private static var gapHoldingSince: Date?
    /// 屏上这首是不是会话被撤后保持出来的(`PlayerGapHold.shouldHoldWhileOutputting`)。播放控制看它,见 `focusControlContext`。
    private static var holdingDroppedSession = false
    /// 会撤会话的那个播放器的进程号,保持期间拿它问内核「还在不在」。只在采纳它的快照时记:
    /// NSRunningApplication 在后台线程上偶尔返回空,保持期间别照它判(会提前放手)。
    private static var gapHoldPID: (bundleID: String, pid: pid_t)?

    private static func processAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private static let runningPIDLock = NSLock()
    private static var runningPIDs: [String: pid_t] = [:]

    /// 这个播放器的进程号,没在跑为 nil。轮询线程上判「在不在跑」走这里:`NSRunningApplication` 在后台线程上偶尔返回空
    /// (实测开着的 App 约两千多次查一次空),查到过一次就记下进程号,之后问内核它还在不在。
    private static func runningPID(_ bundleID: String) -> pid_t? {
        runningPIDLock.lock()
        let cached = runningPIDs[bundleID]
        runningPIDLock.unlock()
        if let cached, processAlive(cached) { return cached }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        runningPIDLock.lock()
        runningPIDs[bundleID] = pid
        runningPIDLock.unlock()
        return pid
    }

    private static func noteGapHoldPID(_ bundleID: String) {
        if let cur = gapHoldPID, cur.bundleID == bundleID, processAlive(cur.pid) { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            gapHoldPID = (bundleID, app.processIdentifier)
        }
    }

    /// 没记下进程号的当它在。
    private static func gapHoldPlayerRunning(_ bundleID: String?) -> Bool {
        guard let bundleID, let cur = gapHoldPID, cur.bundleID == bundleID else { return true }
        return processAlive(cur.pid)
    }

    private static func heldAcrossPlayerGap(_ snapshot: MediaControlSnapshot?) -> MediaControlSnapshot? {
        let now = Date()
        gapHoldLock.lock()
        defer { gapHoldLock.unlock() }
        holdingDroppedSession = false
        if let last = gapHoldLast,
           PlayerGapHold.shouldHold(lastBundleID: last.snapshot.bundleIdentifier, lastTrackKey: last.snapshot.trackKey,
                                    lastSeenAt: last.at, holdingSince: gapHoldingSince,
                                    newBundleID: snapshot?.bundleIdentifier, newTrackKey: snapshot?.trackKey,
                                    newPlaying: snapshot?.playing == true,
                                    lastPlayerRunning: { gapHoldPlayerRunning(last.snapshot.bundleIdentifier) },
                                    now: now) {
            if gapHoldingSince == nil {
                gapHoldingSince = now
                logger.notice("now playing: \(last.snapshot.bundleIdentifier ?? "", privacy: .public) dropped out between tracks, holding its last track")
            }
            let s = last.snapshot
            guard s.playing == true else { return s.withElapsed(s.elapsedTime, capturedAt: now) }
            let elapsed = PlayerGapHold.heldElapsed(elapsed: s.elapsedTime, rate: s.playbackRate, duration: s.duration,
                                                    since: now.timeIntervalSince(last.at))
            return s.withElapsed(elapsed, capturedAt: now)
        }
        if let last = gapHoldLast, let lastBundleID = last.snapshot.bundleIdentifier,
           PlayerGapHold.shouldHoldWhileOutputting(lastBundleID: lastBundleID, lastElapsed: last.snapshot.elapsedTime,
                                                   lastDuration: last.snapshot.duration, lastSeenAt: last.at,
                                                   newBundleID: snapshot?.bundleIdentifier, newPlaying: snapshot?.playing == true,
                                                   outputting: { ProcessAudioOutput.isRunningOutput(bundleID: lastBundleID) },
                                                   now: now) {
            if gapHoldingSince == nil {
                gapHoldingSince = now
                logger.notice("now playing: \(lastBundleID, privacy: .public) dropped its session while still outputting audio, holding its last track")
            }
            holdingDroppedSession = true
            let s = last.snapshot
            let elapsed = PlayerGapHold.heldElapsed(elapsed: s.elapsedTime, rate: s.playbackRate, duration: s.duration,
                                                    since: now.timeIntervalSince(last.at))
            return s.playing(atElapsed: elapsed, capturedAt: now)
        }
        if let since = gapHoldingSince {
            gapHoldingSince = nil
            logger.notice("now playing: gap hold ended after \(Int(now.timeIntervalSince(since).rounded()), privacy: .public)s (next: \(snapshot?.bundleIdentifier ?? "none", privacy: .public) playing=\(snapshot?.playing == true, privacy: .public))")
        }
        if let snapshot, let id = snapshot.bundleIdentifier {
            gapHoldLast = (snapshot, snapshot.capturedAt ?? now)
            if PlaybackPlayer.builtin(forBundleID: id)?.dropsSessionBetweenTracks == true { noteGapHoldPID(id) }
        } else {
            gapHoldLast = nil
        }
        return snapshot
    }

    private static let script = """
    (() => {
        \(JXARunningApp.attach("Music", player: .appleMusic, notRunning: "JSON.stringify(null)"))
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
        let mediaKind = "";
        try { mediaKind = String(track.mediaKind()); } catch (e) { mediaKind = ""; }
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
                bundleIdentifier: "com.apple.Music",
                isMusicVideo: mediaKind === "music video"
            });
        } catch (e) {
            return JSON.stringify(null);
        }
    })()
    """

    // 失败(没有"自动化"权限/Music.app 没在运行/没有曲目在加载/JSON 解析失败)一律
    // 返回 nil,不抛出——上层按"这次没拿到数据,下一轮再试"处理。
    // 没有权限时 osascript 会返回非零退出码(而不是抛出 Swift 异常),同样落进
    // `guard terminationStatus == 0` 这条分支,不需要单独处理。
    private static func fetchAppleMusicSnapshot() -> MediaControlSnapshot? {
        guard !SourceKnockout.isOut(.appleMusicScript), let r = runPlayerScript("music", source: script), r.succeeded
        else {
            setSnapshotFailure(.appleScriptUnavailable)
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(MediaControlSnapshot.self, from: r.stdout) else {
            // 脚本自己 return 了 null(Music.app 没在跑 / stopped / 没有曲目在加载)。
            setSnapshotFailure(.appleScriptUnavailable)
            return nil
        }
        return decoded
    }

    /// 媒体流刚看到 Apple Music 的曲名换了、这一拍 AppleScript 读回来的还是换走的那个曲名,就隔一会儿再读,最多读几次。
    /// 切歌那一下 Music.app 的 AppleScript 要晚一会儿才整份换过来,中间那份是拼起来的:位置已经归零,曲名还是上一首
    /// (歌手有时也是上一首的,有时已经是下一首的)。照收的话这一拍不算换歌、上一首被当成从头重放,要等下一轮轮询才换过去。
    /// 读满几次还是旧曲名就照旧用这一份。判据见 `appleMusicReadLagsTitleChange`,数据见 02 章决策 78。
    private static func settledAppleMusicSnapshot() -> MediaControlSnapshot? {
        guard var snapshot = fetchAppleMusicSnapshot() else { return nil }
        let change = currentTitleChange()
        var rereads = 0
        while rereads < appleMusicSettleRereads,
              appleMusicReadLagsTitleChange(readTitle: snapshot.title, change: change, now: Date()) {
            Thread.sleep(forTimeInterval: appleMusicSettleDelay)
            rereads += 1
            guard let fresh = fetchAppleMusicSnapshot() else { break }
            snapshot = fresh
        }
        if rereads > 0 {
            let caughtUp = snapshot.title != change?.fromTitle
            logger.notice("apple music: AppleScript lagged the stream's title change, re-read \(rereads, privacy: .public)x, \(caughtUp ? "caught up" : "still on the previous title", privacy: .public)")
        }
        return snapshot
    }

    /// 媒体流看到曲名换了之后多久之内,AppleScript 还读到旧曲名才算还没换过来。
    public static let appleMusicSettleWindow: TimeInterval = 3
    static let appleMusicSettleDelay: TimeInterval = 0.3
    static let appleMusicSettleRereads = 3

    /// 这一拍 AppleScript 读到的曲名是不是还停在媒体流刚看到 Apple Music 换走的那一首。只比曲名:平时两边的写法
    /// 即使对不上,读到的也不会恰好是换走的那个旧曲名。纯函数,selftest 覆盖。
    public static func appleMusicReadLagsTitleChange(readTitle: String?, change: StreamTitleChange?, now: Date) -> Bool {
        guard let change, change.bundleID == PlaybackPlayer.appleMusic.bundleIdentifier,
              let readTitle, readTitle == change.fromTitle else { return false }
        let age = now.timeIntervalSince(change.at)
        return age >= -1 && age <= appleMusicSettleWindow
    }

    /// Spotify 自己的 JXA 快照,Spotify 这条路上曲目与位置的唯一来源,跟 Apple Music 对称。两个消费点:`adaptedSnapshot`
    /// (media-control 认出在播的是 Spotify 之后整份顶替)和 `snapshotAfterFocusLost`(焦点被别的 App 占走、media-control
    /// 这一拍什么都拿不到)。
    ///
    /// 别回到"每拍拿 `player position` 去纠 media-control 位置"的做法:两个位置源叠在一起,osascript 往返抖动 + gapless 预载
    /// 时钟分叉都会冒出来。整份顶替只有一个钟,不存在两源分叉。
    ///
    /// 已知限制,刻意不补:`player position` 比真实出声位置领先一段(本机内建扬声器 0.05s、蓝牙 0.41~0.51s,按输出设备各不相同)。
    /// 扣它要引一套按设备学习的领先量,而唯一的输入信号(暂停时 MediaRemote 冻结值与显示值的差)整份顶替之后已经不用了。
    /// Apple Music 同样带着这段链路延迟、同样不扣;要补偿走设置里的「时间轴偏移」。
    ///
    /// 每次起播之后它都整首领先真声一截(解码器的钟先跑,量取决于起播方式:手动点播 ~0.24、拖动 ~0.45、预载无缝换歌 ~0.5~0.7,
    /// 恢复播放 ~0.25),只有暂停那一刻 Spotify 把钟对回出声位置。这一段要扣,由 `LocalPlaybackSource` 按起播方式给
    /// (`SpotifyStartKind`),别当它是真值直接用。
    ///
    /// duration 是毫秒(296533 = 4:56),Music.app 那份是秒:这里除 1000,别照抄上面。
    private static let spotifyScript = """
    (() => {
        \(JXARunningApp.attach("S", player: .spotify, notRunning: "JSON.stringify(null)"))
        let state;
        try {
            state = S.playerState();
        } catch (e) {
            return JSON.stringify(null);
        }
        if (state === "stopped") return JSON.stringify(null);
        try {
            const t = S.currentTrack;
            return JSON.stringify({
                title: t.name(),
                artist: t.artist(),
                album: t.album(),
                duration: t.duration() / 1000,
                elapsedTime: S.playerPosition(),
                playing: state === "playing",
                playbackRate: state === "playing" ? 1 : 0,
                isMusicApp: true,
                bundleIdentifier: "com.spotify.client"
            });
        } catch (e) {
            return JSON.stringify(null);
        }
    })()
    """

    private static func fetchSpotifySnapshot() -> MediaControlSnapshot? {
        guard !SourceKnockout.isOut(.spotifyScript), let r = runPlayerScript("spotify", source: spotifyScript), r.succeeded
        else {
            setSnapshotFailure(.appleScriptUnavailable)
            return nil
        }
        guard var decoded = try? JSONDecoder().decode(MediaControlSnapshot.self, from: r.stdout) else {
            // 脚本自己 return 了 null(Spotify 没在跑 / stopped / 没有曲目)。
            setSnapshotFailure(.appleScriptUnavailable)
            return nil
        }
        // 位置是在脚本快结束时读的(实测慢调用的读数跟着调用结束时刻走,±0.05s),就按这一刻记。
        decoded.capturedAt = Date()
        return decoded
    }

    // MARK: - Kaset

    /// Kaset 的 AppleScript 读数:原样的 JSON 串连同读数调用返回那一刻的墙钟一起回(解读在
    /// `KasetPlayerInfo.parseScriptOutput`)。没在跑时回空串,不会把它拉起来。
    private static let kasetScript = """
    (() => {
        \(JXARunningApp.attach("K", player: .kaset, notRunning: "\"\""))
        try {
            const info = K.getPlayerInfo();
            return JSON.stringify({ readAtMs: Date.now(), info: info });
        } catch (e) {
            return "";
        }
    })()
    """

    /// Kaset 的待播队列原样(`get play queue`)。读到一首没见过的歌时问一次,补它入队时的写法
    /// (`KasetPlayerInfo.queueFirstReport`)。没在跑时回空串,不会把它拉起来。
    private static let kasetPlayQueueScript = """
    (() => {
        \(JXARunningApp.attach("K", player: .kaset, notRunning: "\"\""))
        try {
            return K.getPlayQueue();
        } catch (e) {
            return "";
        }
    })()
    """

    private static let kasetLock = NSLock()
    /// 位置最近一次变化,认卡顿用(见 `KasetPlayerInfo.isAdvancing`)。
    private static var kasetLastMove: KasetPlayerInfo.LastMove?
    /// 这一拍已经问过 Kaset 了(`fetchSnapshotWithProvenance` 入口清零),同一拍不问第二次。
    private static var kasetAskedThisRound = false
    /// 这一拍问过 Kaset,它在放的不是一首歌(开播时的占位、播客单集,见 `readKasetSnapshot`;入口清零):这一拍别报它,也别退回去
    /// 报系统那份或别家暂停着的会话。
    private static var kasetNotSongThisRound = false
    /// 上面那一拍是在加载下一首(开播占位、这一条的类型还在问),不是播客单集:按「在加载」留住上一首(见 02 章决策 92)。
    private static var kasetLoadingThisRound = false
    /// 这一拍交回空是因为别的播放器在加载下一首(`artistNotYetReported`;入口清零):Kaset 只在放或正要放时才顶上来。
    private static var otherPlayerLoadingThisRound = false
    /// 认成播客单集时打过日志的那一条(videoId),同一条只打一条。
    private static var kasetPodcastLoggedVideoID: String?
    /// 最近一次读到的那首(曲目身份同快照的 `trackKey`)和它的 videoId,写播放状态用(`kasetVideoID`)。
    private static var kasetLastVideo: (trackKey: String, videoID: String)?
    /// 这首最先报的歌名与署名(`KasetPlayerInfo.steadyIdentity`)。
    private static var kasetFirstReport: KasetPlayerInfo.FirstReport?
    /// 内嵌网页在放别的(广告)时打过日志的那首(videoId),同一首只打一条:某一拍没问到网页那份会话时
    /// 判定会说不上来,按「翻成 true 才打」的话一段广告会打好几遍。
    private static var kasetWebAdLoggedVideoID: String?
    /// 最近一次读到的那首(曲目身份同快照的 `identityKey`)能当封面用的地址(`KasetPlayerInfo.coverArtworkURL`)。
    private static var kasetLastArtwork: (trackKey: String, url: URL)?
    /// 同上那首没有能当封面用的地址时,这支视频的截图(`KasetPlayerInfo.videoFrameURL`),只给 Discord 状态兜底。
    private static var kasetLastVideoFrame: (trackKey: String, url: URL)?
    /// 最近下载的那张封面,同一个地址不重下(换歌后的取图会重试、复核好几次)。
    private static var kasetArtworkCache: (url: URL, data: Data)?
    /// 记下的内嵌网页那份会话(这一首的 videoId、记下的时刻)和它跟 Kaset 读数对账的进度(`KasetPlayerInfo.webClockStep`)。
    /// 锚点只在播放 / 暂停 / 拖动时重发,对得上就不用每拍起一次子进程去问;锚点不对了、换了一首、记下超过
    /// `kasetWebClockMaxAge` 才再问。
    private static var kasetWebClock: (videoID: String, web: KasetPlayerInfo.WebMedia, at: Date,
                                       check: KasetPlayerInfo.WebClockCheck)?
    /// 这一首最近一次问了却用不上(会话不在、锚点不对),到这个时刻之前不再问。
    private static var kasetWebClockRetryAt: (videoID: String, at: Date)?
    /// 开始跟着网页时钟走时打过日志的那首,同一首只打一条。
    private static var kasetWebClockLoggedVideoID: String?
    /// 对账满一整窗还对不上(时钟一直超前)时打过日志的那首,同一首只打一条。
    private static var kasetWebClockDistrustLoggedVideoID: String?
    private static let kasetWebClockMaxAge: TimeInterval = 30
    private static let kasetWebClockRetryInterval: TimeInterval = 10
    /// 此刻正顶替系统那边、改用 Kaset 的读数时,系统报的是谁("nothing" = 什么都没报);没在顶替为 nil。
    /// 播放控制据此直接发给 Kaset(`focusControlContext`),日志在它变化时打一条。
    private static var kasetPreferredOver: String?

    /// 问一次 Kaset。拿不到(没在跑、没有当前曲目、没授「自动化」权限、超时)返回 nil,不记失败原因:
    /// 两个调用方各自决定这算不算这一拍的失败。

    private static func readKasetSnapshot() -> MediaControlSnapshot? {
        kasetLock.lock()
        kasetAskedThisRound = true
        kasetLock.unlock()
        guard !SourceKnockout.isOut(.kasetScript), let r = runPlayerScript("kaset", source: kasetScript), r.succeeded,
            let (raw, readAt) = KasetPlayerInfo.parseScriptOutput(r.stdout, now: Date())
        else { return nil }
        // 不是一首歌:开播时的占位、播客单集(还没问到类型的这一条先按住,见 KasetVideoKind)。这一拍不报它。
        let kind = KasetPlayerInfo.isPlaceholder(raw) ? nil : KasetVideoKind.verdict(for: raw.videoID ?? "")
        if kind != .notPodcast {
            kasetLock.lock()
            kasetNotSongThisRound = true
            kasetLoadingThisRound = kind != .podcastEpisode
            let logPodcast = kind == .podcastEpisode && kasetPodcastLoggedVideoID != raw.videoID
            if logPodcast { kasetPodcastLoggedVideoID = raw.videoID }
            kasetLock.unlock()
            if logPodcast {
                logger.notice("kaset: podcast episode, not reported as a song track=\(raw.title, privacy: .public)")
            }
            return nil
        }
        kasetLock.lock()
        var first = kasetFirstReport
        kasetLock.unlock()
        if let id = raw.videoID, !id.isEmpty, first?.videoID != id {
            // 这首第一次读到(换了歌,或者 App 刚起来):开播那份按队列里入队时的写法补上。
            first = queuedFirstReport(videoID: id) ?? first
        }
        kasetLock.lock()
        let steady = KasetPlayerInfo.steadyIdentity(raw, first: first)
        kasetFirstReport = steady.first
        kasetLock.unlock()
        let reading = raw.withIdentity(title: steady.title, artist: steady.artist)
        let lastMove = kasetLastMoveSnapshot()
        // 报在放(或在加载)、位置却没动:Kaset 自己的读数分不出是在等还是在放广告,问一次内嵌网页此刻在放什么。
        // 正在走、暂停着都不问(每拍多一次子进程)。
        let web = reading.isPaused || KasetPlayerInfo.isAdvancing(reading, lastMove: lastMove, now: readAt)
            ? nil : kasetWebMedia()
        noteKasetWebMedia(web, reading: reading)
        // 在走:位置改用内嵌网页那份会话的播放时钟(Kaset 自己的读数是网页每 0.5 秒才推一次的值,比真值晚 0~0.5 秒)。
        let clockPosition = KasetPlayerInfo.isAdvancing(reading, lastMove: lastMove, now: readAt)
            ? kasetWebClockPosition(reading, at: readAt) : nil
        let snapshot = KasetPlayerInfo.snapshot(reading, lastMove: lastMove, capturedAt: readAt, webMedia: web,
                                                clockPosition: clockPosition)
        // 封面先用队列里这一格入队时那张(专辑图),没有才用读数里的;视频截图不当封面。
        let artwork = KasetPlayerInfo.coverArtworkURL(steady.first?.artworkURL) ?? KasetPlayerInfo.coverArtworkURL(reading.artworkURL)
        // 没有专辑图(放的是视频)时记下视频截图,只给 Discord 状态兜底,App 里不用。
        let frame = artwork == nil
            ? KasetPlayerInfo.videoFrameURL(videoID: reading.videoID, reportedArtwork: reading.artworkURL) : nil
        kasetLock.lock()
        kasetLastArtwork = artwork.map { (snapshot.identityKey, $0) }
        kasetLastVideoFrame = frame.map { (snapshot.identityKey, $0) }
        kasetLastMove = KasetPlayerInfo.nextMove(after: kasetLastMove, reading: reading, at: readAt)
        kasetLastVideo = reading.videoID.map { (snapshot.trackKey, $0) }
        kasetLock.unlock()
        return snapshot
    }

    /// Kaset 这首的封面:系统会话里它从不带图,这张当播放器自己的封面用(`LocalPlaybackSource.fetchArtworkForCurrentTrack`)。
    /// 最近一次读到的不是这首、这首没有能当封面的地址、下载失败返回 nil;同一个地址只下载一次。会阻塞到下载结束,
    /// 不要在主线程调用。
    public static func kasetArtwork(forTrackKey key: String) -> (data: Data, mimeType: String, trackKey: String)? {
        kasetLock.lock()
        let last = kasetLastArtwork
        let cached = kasetArtworkCache
        kasetLock.unlock()
        guard let last, last.trackKey.compare(key, options: [.caseInsensitive]) == .orderedSame else { return nil }
        if let cached, cached.url == last.url {
            return (cached.data, PlaybackStateFile.artworkMime(cached.data), last.trackKey)
        }
        guard let data = downloadKasetArtwork(last.url) else { return nil }
        kasetLock.lock()
        kasetArtworkCache = (last.url, data)
        kasetLock.unlock()
        return (data, PlaybackStateFile.artworkMime(data), last.trackKey)
    }

    /// Kaset 这首(按快照的 `identityKey` 认)能当封面用的地址,不下载。最近一次读到的不是这首、或这首没有为 nil。
    public static func kasetArtworkURL(forTrackKey key: String) -> URL? {
        kasetLock.lock()
        defer { kasetLock.unlock() }
        guard let last = kasetLastArtwork, last.trackKey.compare(key, options: [.caseInsensitive]) == .orderedSame
        else { return nil }
        return last.url
    }

    /// Kaset 这首(按快照的 `identityKey` 认)放的是视频、没有能当封面用的地址时,这支视频的截图地址;只给 Discord 状态兜底。
    /// 最近一次读到的不是这首、或这首有专辑图为 nil。
    public static func kasetVideoFrameURL(forTrackKey key: String) -> URL? {
        kasetLock.lock()
        defer { kasetLock.unlock() }
        guard let last = kasetLastVideoFrame, last.trackKey.compare(key, options: [.caseInsensitive]) == .orderedSame
        else { return nil }
        return last.url
    }

    /// 下载一次封面的上限。走系统代理(YouTube Music 的图床在这台机器上要经代理,实测 1.6 秒左右)。
    private static let kasetArtworkTimeout: TimeInterval = 10

    private final class DownloadResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (data: Data?, status: Int?, error: Error?) = (nil, nil, nil)
        func set(_ data: Data?, _ status: Int?, _ error: Error?) { lock.lock(); value = (data, status, error); lock.unlock() }
        func get() -> (data: Data?, status: Int?, error: Error?) { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func downloadKasetArtwork(_ url: URL) -> Data? {
        let started = Date()
        let result = DownloadResult()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: kasetArtworkTimeout)) { data, response, error in
            result.set(data, (response as? HTTPURLResponse)?.statusCode, error)
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + kasetArtworkTimeout + 1)
        let got = result.get()
        NetworkAuditLog.record(service: "image", operation: "kaset.artwork", host: url.host ?? "googleusercontent.com",
                               statusCode: got.status, durationMs: Date().timeIntervalSince(started) * 1000, error: got.error)
        guard got.status == 200, let data = got.data, CoverArtReplacementGate.isImage(data) else { return nil }
        return data
    }

    /// 在走的这一拍按内嵌网页那份会话的播放时钟算位置,跟 Kaset 读数对上了才用(`KasetPlayerInfo.webClockStep`)。先拿记下的
    /// 那份推、接着对账;锚点不对了当场再问一次;换了一首、记下太久才问;问了用不上,隔 `kasetWebClockRetryInterval` 再试。
    private static func kasetWebClockPosition(_ reading: KasetPlayerInfo.Reading, at t: Date) -> Double? {
        guard let id = reading.videoID, !id.isEmpty else { return nil }
        kasetLock.lock()
        let cached = kasetWebClock
        let retry = kasetWebClockRetryAt
        kasetLock.unlock()
        let previous = cached?.videoID == id ? cached?.check : nil
        var web: KasetPlayerInfo.WebMedia?
        var queriedAt = t
        var step: (position: Double?, check: KasetPlayerInfo.WebClockCheck?) = (nil, nil)
        if let cached, cached.videoID == id, t.timeIntervalSince(cached.at) < kasetWebClockMaxAge {
            web = cached.web
            queriedAt = cached.at
            step = KasetPlayerInfo.webClockStep(reading, web: web, at: t, check: previous)
        }
        if step.check == nil {
            if let retry, retry.videoID == id, t < retry.at { return nil }
            web = kasetWebMedia()
            queriedAt = t
            step = KasetPlayerInfo.webClockStep(reading, web: web, at: t, check: previous)
        }
        kasetLock.lock()
        if let web, let check = step.check {
            kasetWebClock = (id, web, queriedAt, check)
            kasetWebClockRetryAt = nil
        } else {
            kasetWebClock = nil
            kasetWebClockRetryAt = (id, t.addingTimeInterval(kasetWebClockRetryInterval))
        }
        let firstForTrack = step.position != nil && kasetWebClockLoggedVideoID != id
        if firstForTrack { kasetWebClockLoggedVideoID = id }
        let distrusted = step.check.map { !$0.confirmed && $0.leads.count >= KasetPlayerInfo.webClockCheckWindow } ?? false
            && kasetWebClockDistrustLoggedVideoID != id
        if distrusted { kasetWebClockDistrustLoggedVideoID = id }
        kasetLock.unlock()
        let minLead = step.check?.leads.min() ?? -1
        if firstForTrack, let position = step.position {
            logger.notice("kaset: position follows the web view clock track=\(reading.title, privacy: .public) lead=\(position - reading.position, format: .fixed(precision: 3)) minLead=\(minLead, format: .fixed(precision: 3))")
        }
        if distrusted {
            logger.notice("kaset: web view clock stays ahead of Kaset's readings, not used track=\(reading.title, privacy: .public) minLead=\(minLead, format: .fixed(precision: 3))")
        }
        return step.position
    }

    /// Kaset 内嵌网页此刻在放的那段媒体(`KasetPlayerInfo.webMedia`)。Kaset 没在跑、helper 不可用返回 nil。
    private static func kasetWebMedia() -> KasetPlayerInfo.WebMedia? {
        guard let pid = runningPID(PlaybackPlayer.kaset.bundleIdentifier),
              let sessions = NowPlayingClientsProbe.allSessions()
        else { return nil }
        return KasetPlayerInfo.webMedia(in: sessions, kasetPID: pid)
    }

    private static func noteKasetWebMedia(_ web: KasetPlayerInfo.WebMedia?, reading: KasetPlayerInfo.Reading) {
        guard KasetPlayerInfo.adByWebMedia(reading, web: web) == true else { return }
        let id = reading.videoID ?? reading.title
        kasetLock.lock()
        let first = kasetWebAdLoggedVideoID != id
        kasetWebAdLoggedVideoID = id
        kasetLock.unlock()
        guard first else { return }
        logger.notice("kaset: web view is playing other media, treating it as an ad web_duration=\(web?.duration ?? 0, format: .fixed(precision: 1)) track=\(reading.title, privacy: .public) position=\(reading.position, format: .fixed(precision: 1)) playing=\(reading.isPlaying)")
    }

    private static func queuedFirstReport(videoID: String) -> KasetPlayerInfo.FirstReport? {
        guard let r = ProcessRunner.run(
            "/usr/bin/osascript", ["-l", "JavaScript", "-e", kasetPlayQueueScript],
            timeout: MusicPlaybackController.appleScriptTimeout), r.succeeded
        else { return nil }
        return KasetPlayerInfo.queueFirstReport(fromQueueJSON: r.stdout, videoID: videoID)
    }

    private static func kasetLastMoveSnapshot() -> KasetPlayerInfo.LastMove? {
        kasetLock.lock()
        defer { kasetLock.unlock() }
        return kasetLastMove
    }

    /// Kaset 最近一次报的这首(按快照的 `trackKey` 认)的 videoId;不是这首、或者没读到过为 nil。
    public static func kasetVideoID(forTrackKey key: String) -> String? {
        kasetLock.lock()
        defer { kasetLock.unlock() }
        guard let last = kasetLastVideo, last.trackKey == key else { return nil }
        return last.videoID
    }

    private static func fetchKasetSnapshot() -> MediaControlSnapshot? {
        guard let snapshot = readKasetSnapshot() else {
            setSnapshotFailure(kasetNotSongFailure() ?? .appleScriptUnavailable)
            return nil
        }
        return snapshot
    }

    private static func kasetNotSongThisRoundValue() -> Bool {
        kasetLock.lock()
        defer { kasetLock.unlock() }
        return kasetNotSongThisRound
    }

    /// 这一拍问过 Kaset、它在放的不是一首歌时记哪一种原因:在加载下一首(开播占位、类型还在问)还是没在放音乐(播客单集)。
    /// 不是这种情况为 nil。
    private static func kasetNotSongFailure() -> SnapshotFailure? {
        kasetLock.lock()
        defer { kasetLock.unlock() }
        guard kasetNotSongThisRound else { return nil }
        return kasetLoadingThisRound ? .targetLoading : .targetNotPlayingMusic
    }

    /// 这一拍别的来源没给出在放的歌、Kaset 又开着,就直接问它一次。
    ///
    /// Kaset 在放时系统里可能一拍都没有它:会话交给了 WebKit(歌名歌手是空的,bundle id 报成 WebKit 的媒体进程),
    /// 换歌加载时它自己那份又整个撤掉。光等系统认出它,可能一整首都等不到,系统那边还会落回别的播放器暂停着的旧会话。
    /// 别的来源什么都没有时,Kaset 暂停着的那首也照样报(跟 Music.app 暂停着同一个口径);别的来源有一首暂停着的,
    /// 只在 Kaset 在放或正要放时才换过去。换过去之后记在 `kasetPreferredOver`:`focusControlContext` 据此把播放控制
    /// 直接发给它,不然 media-control 的指令会落在系统焦点上的那个 App 身上。别改成按焦点回退那套记账:系统那边每一拍
    /// 照样认下别的播放器(`noteAccepted`),回退开关一拍一翻,两条日志每拍各打一遍。
    ///
    /// 只在 Kaset 开着时才发 Apple Event,不用它的人一次都碰不到,不会凭空多弹「自动化」权限框。
    private static func preferringPlayingKaset(_ found: MediaControlSnapshot?) -> MediaControlSnapshot? {
        let kaset = kasetToPrefer(over: found)
        // Kaset 在放的不是一首歌(播客单集、开播占位)时什么都不报,别报别家暂停着的会话(同 KKBOX 的播客)。
        if kaset == nil, let failure = kasetNotSongFailure() {
            setSnapshotFailure(failure)
            return nil
        }
        let other = kaset == nil ? nil : (found?.bundleIdentifier ?? "nothing")
        kasetLock.lock()
        let changed = kasetPreferredOver != other
        kasetPreferredOver = other
        kasetLock.unlock()
        if changed, let other {
            logger.notice("now playing: the system reports \(other, privacy: .public); reading Kaset via AppleScript")
        }
        return kaset ?? found
    }

    /// 此刻正顶替系统那边、改用洛雪开放 API 推的读数时,系统报的是谁("nothing" = 什么都没报);没在顶替为 nil。
    /// 播放控制据此直接发给洛雪(`focusControlContext`),日志在它变化时打一条。只在 `kasetLock` 里读写。
    private static var lxMusicPreferredOver: String?

    /// 系统那边(顶替之前)最近一次报出来的播放器和时刻;报空的那几拍不动它。只在 `kasetLock` 里读写。
    private static var lastSystemReading: (bundleID: String, at: Date)?

    private static func noteSystemReading(_ found: MediaControlSnapshot?) {
        guard let id = found?.bundleIdentifier else { return }
        kasetLock.lock()
        lastSystemReading = (id, Date())
        kasetLock.unlock()
    }

    /// 这一拍系统什么都没报,而刚才还在报别的播放器(`fallbackBundleID` 之外的那个):按它在加载下一首处理,暂停着的兜底会话
    /// (洛雪开放 API、Kaset)不顶上来,空读数交给轮询的单拍宽限。
    private static func otherPlayerJustDropped(besides fallbackBundleID: String) -> Bool {
        kasetLock.lock()
        let last = lastSystemReading
        kasetLock.unlock()
        return otherPlayerBetweenTracks(lastBundleID: last?.bundleID, lastSeenAt: last?.at, fallbackBundleID: fallbackBundleID,
                                        now: Date())
    }

    /// 系统这一拍什么都没报时,是不是上一次报的那个播放器(不是兜底的这一家)在切歌撤会话:离最后一次报它不到
    /// `PlayerGapHold.startWindow`。Apple Music 自然连播实测会撤约 2.5 秒,哪家撤都一样,不按播放器收窄。不成立时暂停着的兜底
    /// 会话照旧顶上来(别家停了、只剩它)。见 02 章决策 147。纯函数,selftest 覆盖。
    public static func otherPlayerBetweenTracks(lastBundleID: String?, lastSeenAt: Date?, fallbackBundleID: String,
                                                now: Date) -> Bool {
        guard let lastBundleID, let lastSeenAt, lastBundleID != fallbackBundleID else { return false }
        let age = now.timeIntervalSince(lastSeenAt)
        return age >= 0 && age <= PlayerGapHold.startWindow
    }

    /// 这一拍的读数是不是洛雪开放 API 合成的(系统那边没报洛雪)。收藏读写据此改按它推的歌名认这一首。
    public static var lxMusicReadViaOpenAPI: Bool {
        kasetLock.lock()
        let preferred = lxMusicPreferredOver != nil
        kasetLock.unlock()
        // 切歌间隙保持把屏上留在别的播放器时,屏上这首不是洛雪推的(同 controlScriptTarget)。
        gapHoldLock.lock()
        let holdingAcrossGap = gapHoldingSince != nil
        gapHoldLock.unlock()
        return preferred && !holdingAcrossGap
    }

    /// 别的来源这一拍没给出在放的歌、洛雪又开着且用户打开了它的开放 API,就用它推的状态合成一份(`LXMusicOpenAPI.nowPlayingSnapshot`)。
    /// 系统那边可能一拍都没有它:系统的「正在播放」只有一个位置,被网页视频之类占了;它换歌时撤掉会话那半秒落回别家暂停着的旧会话。
    /// 取舍同 Kaset(`kasetWins`):别的来源什么都没有时洛雪暂停着的那首也报;别的来源有一首暂停着的,只在洛雪在放或正要放时才换过去。
    /// `wanted`:设置认洛雪(自动识别或勾了它)。洛雪开着就让订阅一直连着(`noteAppRunning`),本机 HTTP,不弹任何权限框。
    /// 见 02 章决策 134。
    private static func preferringLXMusicOpenAPI(_ found: MediaControlSnapshot?, wanted: Bool) -> MediaControlSnapshot? {
        let running = wanted
            && !NSRunningApplication.runningApplications(withBundleIdentifier: PlaybackPlayer.lxMusic.bundleIdentifier).isEmpty
        LXMusicOpenAPI.shared.noteAppRunning(running)
        var lx: MediaControlSnapshot?
        kasetLock.lock()
        let alreadyPreferred = lxMusicPreferredOver != nil
        let otherLoading = otherPlayerLoadingThisRound
        kasetLock.unlock()
        // 别的播放器在加载下一首、或刚撤会话(otherPlayerJustDropped)时,暂停着的洛雪不顶上来,跟 Kaset 那一路一样。
        let otherBetweenTracks = otherLoading
            || (found == nil && otherPlayerJustDropped(besides: PlaybackPlayer.lxMusic.bundleIdentifier))
        // 订阅连着(`currentState` 不是 nil)就说明洛雪活着,不再看 `running`:那个后台线程上偶尔返回空。
        if wanted, found?.bundleIdentifier != PlaybackPlayer.lxMusic.bundleIdentifier,
           let state = LXMusicOpenAPI.shared.currentState(),
           let synthesized = LXMusicOpenAPI.nowPlayingSnapshot(state, now: Date()),
           kasetWins(over: found, kaset: synthesized, otherPlayerLoading: otherBetweenTracks, alreadyPreferred: alreadyPreferred) {
            lx = synthesized
        }
        let other = lx == nil ? nil : (found?.bundleIdentifier ?? "nothing")
        kasetLock.lock()
        let changed = lxMusicPreferredOver != other
        lxMusicPreferredOver = other
        kasetLock.unlock()
        if changed {
            if let other {
                logger.notice("now playing: the system reports \(other, privacy: .public); reading LX Music via its open API")
            } else {
                logger.notice("now playing: back to the system's reading for LX Music")
            }
        }
        return lx ?? found
    }

    private static func forgetLXMusicPreference() {
        kasetLock.lock()
        lxMusicPreferredOver = nil
        kasetLock.unlock()
    }

    private static func forgetKasetPreference() {
        kasetLock.lock()
        kasetPreferredOver = nil
        kasetLock.unlock()
    }

    private static func kasetToPrefer(over found: MediaControlSnapshot?) -> MediaControlSnapshot? {
        if let found, found.playing == true || found.bundleIdentifier == PlaybackPlayer.kaset.bundleIdentifier {
            return nil
        }
        kasetLock.lock()
        let asked = kasetAskedThisRound
        let loading = otherPlayerLoadingThisRound
        let alreadyPreferred = kasetPreferredOver != nil
        kasetLock.unlock()
        let otherLoading = loading || (found == nil && otherPlayerJustDropped(besides: PlaybackPlayer.kaset.bundleIdentifier))
        guard !asked,
              runningPID(PlaybackPlayer.kaset.bundleIdentifier) != nil,
              let kaset = readKasetSnapshot(),
              Self.kasetWins(over: found, kaset: kaset, otherPlayerLoading: otherLoading, alreadyPreferred: alreadyPreferred)
        else { return nil }
        return kaset
    }

    /// 别的来源这一拍给出的(nil = 什么都没有)跟 Kaset 自己报的,用哪个。`otherPlayerLoading`:这一拍是空的,是因为别的播放器
    /// 在加载下一首(`artistNotYetReported`),不是没人在放 —— 这时 Kaset 暂停着的那首不报。`alreadyPreferred`:上一拍已经在顶替
    /// 别的来源;别的那份这一拍还只是暂停着,就接着用它 —— 它刚停下,比那份更早暂停的会话更像用户在听的,否则一暂停读数和播放
    /// 控制就落到那份旧会话上(见 02 章决策 142)。纯函数,selftest 覆盖。
    public static func kasetWins(over found: MediaControlSnapshot?, kaset: MediaControlSnapshot,
                                 otherPlayerLoading: Bool = false, alreadyPreferred: Bool = false) -> Bool {
        if let found, found.playing == true { return false }
        if alreadyPreferred, found != nil { return true }
        let kasetMoving = kaset.playing == true || kaset.isWaitingToPlay == true
        if found == nil, otherPlayerLoading { return kasetMoving }
        return found == nil || kasetMoving
    }

    // MARK: - VOX

    /// 问一次 VOX(`VoxPlayerInfo.script`)。拿不到(没在跑、停住、没授「自动化」权限、超时)返回 nil。换歌那一拍位置还是
    /// 上一首的(`VoxPlayerInfo.positionLagsTrackChange`)就隔一会儿再读,最多读几次,读满还是那样照用这一份。
    private static func fetchVoxSnapshot() -> MediaControlSnapshot? {
        let previous = VoxPlayerInfo.previousMark()
        guard var reading = readVox() else {
            setSnapshotFailure(.appleScriptUnavailable)
            return nil
        }
        var rereads = 0
        while rereads < VoxPlayerInfo.settleRereads,
              VoxPlayerInfo.positionLagsTrackChange(previous: previous, current: VoxPlayerInfo.mark(reading)) {
            Thread.sleep(forTimeInterval: VoxPlayerInfo.settleDelay)
            rereads += 1
            guard let fresh = readVox() else { break }
            reading = fresh
        }
        if rereads > 0 {
            let settled = !VoxPlayerInfo.positionLagsTrackChange(previous: previous, current: VoxPlayerInfo.mark(reading))
            VoxPlayerInfo.logTornReading(rereads: rereads, settled: settled)
        }
        VoxPlayerInfo.remember(reading)
        return reading.snapshot
    }

    private static func readVox() -> VoxPlayerInfo.Reading? {
        guard !SourceKnockout.isOut(.voxScript) else { return nil }
        guard let r = runPlayerScript("vox", source: VoxPlayerInfo.script), r.succeeded else { return nil }
        // 位置是脚本最后读的,按调用返回这一刻记(同 Spotify)。
        return VoxPlayerInfo.reading(fromScriptOutput: r.stdout, capturedAt: Date())
    }

    // MARK: - 「只勾了 Apple Music」这条路上的电台判据

    /// 纯 AppleScript 那份快照拿不到 `radioStationHash`:那是 MediaRemote 独有的键,问 Music.app 要不到。不补的话「设置里只勾了
    /// Apple Music、没勾自动识别」这一种配置下,整套电台逻辑(单曲表 / 台卡 / 口白 / 按台校准)恒不生效:`isRadio` 永远是 nil,
    /// 位置照旧是整档节目的口径,歌词整档对不上。判据本身一处 bundleID 都不认(谁报 `radioStationHash` 就算谁)。
    ///
    /// 补法:AppleScript 那份快照整份留着(位置精度更高:289.7659912109375 vs 目录 289.766),只把那一个判据字段补进来。
    ///
    /// # 按曲目探一次,不每拍都问
    ///
    /// 这条路径跳过 media-control 就是为了"不多背一次子进程往返"(见 fetchSnapshot 头注),每拍都问等于白跳。而"这一路是不是电台"
    /// 在同一个曲目 key 内不会翻转:台卡、每首歌各自是不同的 key,口白期间系统一个字段都不变(整段 61 秒的口白)、沿用上一首的 key,
    /// 判据也确实还成立。所以按 key 探一次把结果记下来,换歌才多一次 fork(电台上 230~310 秒一次),而不是 2 秒一次。
    private static func radioAwareAppleMusicSnapshot() -> MediaControlSnapshot? {
        guard let snapshot = settledAppleMusicSnapshot() else { return nil }
        let hash = probedRadioStationHash(forTrack: snapshot.trackKey)
        // 设置里只选了 Apple Music 时,平时不读 media-control,这里只有 AppleScript 读到的歌名和进度。
        // 时长是空的话用 media-control 报的补上;这一拍刚为电台判据问过 media-control 的,就用那一份应答,不再另问。
        // 选了「自动识别」不会进这个函数,那条路已经拿着 media-control 的时长。
        let playable = supplementingMissingAppleDuration(snapshot, radioProbe: takeRadioProbeReply())
        guard let hash else {
            setRadioStationHash(nil)
            return playable
        }
        setRadioStationHash(hash)
        // 位置换成按曲目边界自己起的表 —— 跟 fetchRawMediaControlSnapshot 里那一段同一套口径,
        // 理由(系统报的 duration/elapsedTime 都是整档节目的)见 RadioTrackClock 头注。起表时刻
        // 同样取 stream watcher 观察到换歌的那一刻:那个订阅**不按 features.players 挂载**
        // (见 LocalPlaybackSource.startObservingPlayerInfoNotification 上那段注释),所以这条
        // 路上照样查得到,那 0.4~1.8 秒的恒定滞后不会因为换了条路又回来。
        // AppleScript 的 player position 是这一刻现读的,没有锚点新旧问题,锚点年龄按 0 传。
        let radio = advanceRadioClock(
            trackKey: playable.trackKey, playing: playable.playing == true, now: Date(),
            startedAt: lastTrackChangeObserved(forKey: playable.trackKey),
            systemPosition: playable.elapsedTime, reportedDuration: playable.duration, anchorAge: 0)
        // 报单曲位置的台:AppleScript 那份位置就是真值,只标电台、不换成单曲表(见 RadioTrackClock.State.perTrack)。
        return radio.perTrack ? playable.markedRadio() : playable.withRadio(position: radio.position)
    }

    /// 连续几次拿不到快照,才真的把播放状态清空。纯函数,selftest 覆盖。
    ///
    /// 一拍就清的话:`LocalPlaybackSource.clearIfWasPlaying()` 会把 title / artist / allLines / currentLine / 封面 / lastKey
    /// 一次全清掉,而单拍 nil 并不罕见(本机 24 小时抓到 2 次,都是单次、下一拍就恢复)。菜单栏靠那层 hold(内容 3s / 几何 8s)
    /// 看不出来,但悬浮歌词窗和灵动岛直接读这些发布状态,会闪一下。
    ///
    /// 这个宽限**吃不到"暂停"**:暂停时快照仍然有效(playing=false),压根不走这条路。
    /// 真正会变成 nil 的只有 stopped / 播放器退出 / 焦点被抢 / 通道坏 —— 前两种多留一拍无害,
    /// 后两种正是要兜的。
    ///
    /// 取 2(播放档 2s 轮询 ≈ 4 秒):比 media-control 那条 5 秒超时还短一点,再大就会在
    /// "播放列表放完"之后明显地多留一句歌词。
    public static let nilSnapshotGrace = 2

    /// 「焦点被别的 App 占走」这一档的宽限,单位是**秒**而不是拍数:nil 期间的轮询档位不是固定的
    /// (见 `LocalPlaybackSource.desiredPollInterval`),同样的拍数对应的真实时间能差好几倍,拍数
    /// 在这一档里不是一个稳定的量。
    ///
    /// 这一档跟其余几种失败有本质区别:那些说的是"没人在报",而这一档说的是**有别人在报,只是不是
    /// 我们要的那个** —— 系统级 Now Playing 是单焦点,浏览器里一个 video 元素就能把它占走,而目标
    /// 播放器多半还在放。实测:占用者释放焦点的那一拍,读回来的位置正是一路走过来的,期间它没停过。
    /// 所以这一档该维持而不是清空。
    ///
    /// 取 300 秒:比典型单曲长,覆盖绝大多数"看个视频再回来";再长就会在"看视频期间顺手把音乐停了"
    /// 这种情况下,把一份早已不成立的状态挂在屏幕上。焦点一回来就立刻按真实状态纠正(实测无
    /// 延迟),所以这个上限只影响"焦点一直被占着"那段时间里的显示。
    public static let focusHeldGraceSeconds: Double = 300

    /// 这次失败是不是「有别人在放,只是不是我们要的那个」。纯函数,selftest 覆盖。
    ///
    /// `nobodyReporting` **不在**这一档:那是真的没有任何 App 在报,目标播放器自己也没在报,
    /// 说明它确实停了,该按 nilSnapshotGrace 的短宽限清掉。
    public static func isFocusHeldElsewhere(_ failure: SnapshotFailure?) -> Bool {
        switch failure {
        case .focusHeldByOtherApp, .playerNotSelected, .notASong: return true
        default: return false
        }
    }

    /// 「播放器在加载下一首」(`targetLoading`)这一档留住上一首的上限,单位秒。Kaset 换歌通常 1~2 秒就加载完;一直报加载
    /// (网络断了、卡在占位)就按这个清。
    public static let loadingGraceSeconds: Double = 10

    public static func nilSnapshotClearsState(
        consecutiveNilCount: Int, failure: SnapshotFailure?, nilStreakSeconds: Double
    ) -> Bool {
        if isFocusHeldElsewhere(failure) { return nilStreakSeconds >= focusHeldGraceSeconds }
        if failure == .targetLoading { return nilStreakSeconds >= loadingGraceSeconds }
        return consecutiveNilCount >= nilSnapshotGrace
    }

    /// 这一拍要不要为电台判据多问一次 media-control。纯函数,selftest 直接覆盖。
    /// 判据只有一条:曲目 key 变了 —— "是不是电台"在同一个 key 内不会翻转,理由见
    /// `radioAwareAppleMusicSnapshot` 头注。
    public static func radioProbeNeeded(cachedKey: String?, trackKey: String) -> Bool {
        cachedKey != trackKey
    }

    private static let appleMusicRadioProbeLock = NSLock()
    private static var appleMusicRadioProbedKey: String?
    private static var appleMusicRadioProbedHash: String?

    /// 只选了 Apple Music 时,给「AppleScript 没读到时长」的歌补上 media-control 报的时长,按曲目记一份。
    /// 问失败(media-control 不在 / 超时 / 系统在报的不是 Apple Music)、或问到的就是这首,都记下,同一首不再问,
    /// 免得每 2 秒再启动一次 media-control。问到的是别的曲目(换歌那一拍系统多半还停在上一首)先不记、下一拍再问,
    /// 同一首最多问 `appleDurationProbeMaxTries` 次(`appleDurationProbeSettles`)。见 02 章决策 124。
    private static let appleDurationProbeLock = NSLock()
    private static var appleDurationProbeKey: String?
    private static var appleDurationProbeSecs: Double?
    private static var appleDurationProbeSettled = false
    private static var appleDurationProbeTries = 0
    /// 这一拍为电台判据问过 media-control(`probedRadioStationHash` 真的起了一次子进程)时,那份应答里的这一首
    /// (nil = 问失败、或系统在报的不是 Apple Music)。由 `takeRadioProbeReply` 取走。
    private static var appleMusicRadioProbeRan = false
    private static var appleMusicRadioProbeReply: MediaControlSnapshot?

    /// 同一首歌最多为补时长问几次 media-control。
    public static let appleDurationProbeMaxTries = 3

    /// 补时长这一次问到的结论记不记住(记住之后同一首不再问)。问失败(`probedKey` 为 nil)或问到的就是这首:记。
    /// 问到的是别的曲目先不记,但同一首问满 `appleDurationProbeMaxTries` 次也记:两边的写法一直对不上时,不会每 2 秒
    /// 起一次 media-control。纯函数,selftest 覆盖。
    public static func appleDurationProbeSettles(probedKey: String?, trackKey: String, tries: Int) -> Bool {
        probedKey == nil || probedKey == trackKey || tries >= appleDurationProbeMaxTries
    }

    /// `radioProbe`:这一拍为电台判据问 media-control 的结果(`takeRadioProbeReply`)。问过就用它,没问才另问一次。
    private static func supplementingMissingAppleDuration(
        _ apple: MediaControlSnapshot, radioProbe: (ran: Bool, reply: MediaControlSnapshot?)
    ) -> MediaControlSnapshot {
        if let duration = apple.duration, duration > 0 { return apple }
        let key = apple.trackKey
        appleDurationProbeLock.lock()
        if appleDurationProbeKey != key {
            appleDurationProbeKey = key
            appleDurationProbeSecs = nil
            appleDurationProbeSettled = false
            appleDurationProbeTries = 0
        }
        if appleDurationProbeSettled {
            let cached = appleDurationProbeSecs
            appleDurationProbeLock.unlock()
            return cached.map { apple.withDuration($0) } ?? apple
        }
        appleDurationProbeTries += 1
        let tries = appleDurationProbeTries
        appleDurationProbeLock.unlock()
        let probed = radioProbe.ran ? radioProbe.reply : probeAppleMusicSystemSnapshot()
        let filled = fillingMissingAppleDuration(apple, from: probed)
        appleDurationProbeLock.lock()
        if appleDurationProbeKey == key,
           appleDurationProbeSettles(probedKey: probed?.trackKey, trackKey: key, tries: tries) {
            appleDurationProbeSettled = true
            appleDurationProbeSecs = (filled.duration ?? 0) > 0 ? filled.duration : nil
        }
        appleDurationProbeLock.unlock()
        return filled
    }

    // MARK: - Apple Music 在放的那一版的时长

    private static let appleSystemDurationLock = NSLock()
    private static var appleSystemDuration: (trackKey: String, secs: Double)?

    /// 系统媒体信息(MediaRemote)给 Apple Music 这一首报的时长;没见过这一首的系统读数时为 nil。
    ///
    /// AppleScript 的 `duration` 是目录里立体声版的时长,放杜比全景声版时跟实际在放的差几秒,只有系统这份是在放的那一版。
    /// 认空间音频版、界面上的总时长要用它,见 `LocalPlaybackSource.applePlayingDuration` 与 08 章决策 54。三条读法都记:自动识别 / 多选在 `adaptedSnapshot` 里两份读数同时在手,
    /// 只选 Apple Music 时每首歌本来就为电台判据问一次 media-control(`probeRadioStationHash`)。
    public static func appleMusicSystemDuration(forTrack trackKey: String) -> Double? {
        appleSystemDurationLock.lock()
        defer { appleSystemDurationLock.unlock() }
        guard let known = appleSystemDuration, known.trackKey == trackKey else { return nil }
        return known.secs
    }

    /// 电台报的是整档节目的时长,不记。
    private static func noteAppleMusicSystemDuration(trackKey: String, duration: Double?, isRadio: Bool) {
        guard !isRadio, let duration, duration > 0 else { return }
        appleSystemDurationLock.lock()
        appleSystemDuration = (trackKey, duration)
        appleSystemDurationLock.unlock()
    }

    /// 取走这一拍电台判据那次探测的应答,取完清空(下一拍没有新的探测就是「没问」)。
    private static func takeRadioProbeReply() -> (ran: Bool, reply: MediaControlSnapshot?) {
        appleDurationProbeLock.lock()
        defer {
            appleMusicRadioProbeRan = false
            appleMusicRadioProbeReply = nil
            appleDurationProbeLock.unlock()
        }
        return (appleMusicRadioProbeRan, appleMusicRadioProbeReply)
    }

    private static func noteRadioProbeReply(ran: Bool, reply: MediaControlSnapshot?) {
        appleDurationProbeLock.lock()
        appleMusicRadioProbeRan = ran
        appleMusicRadioProbeReply = reply
        appleDurationProbeLock.unlock()
    }

    /// 向 media-control 要当前这首歌的时长。不走 `fetchRawMediaControlSnapshot`,那个还会改进度记录。
    private static func probeAppleMusicSystemSnapshot() -> MediaControlSnapshot? {
        guard let binaryPath = binaryPath(),
              let result = runGet(["--now", "--no-artwork"], binaryPath: binaryPath, timeout: snapshotTimeout),
              result.succeeded,
              let raw = try? JSONDecoder().decode(RawPayload.self, from: result.stdout),
              raw.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier
        else { return nil }
        return appleMusicSystemSnapshot(raw)
    }

    /// media-control 应答里 Apple Music 的这一首(只用来补时长,位置不取)。
    private static func appleMusicSystemSnapshot(_ raw: RawPayload) -> MediaControlSnapshot {
        MediaControlSnapshot.forReplay(
            title: raw.title, artist: raw.artist, album: raw.album, duration: raw.duration,
            elapsedTime: raw.elapsedTime, playing: raw.playing, bundleIdentifier: raw.bundleIdentifier,
            anchorElapsedTime: raw.elapsedTime)
    }

    /// 这一首的电台标识(nil = 不是电台 / 问不出来)。结果按曲目 key 记一份,同一首歌只探一次。
    ///
    /// 探测失败(media-control 不在 / 超时 / 系统 Now Playing 焦点根本不是 Apple Music)
    /// **也**记进缓存、按"不是电台"处理:这样最坏情况是这首歌整首退回改动前的行为(改动前这条
    /// 路上电台本来就完全不生效,所以是退化不是回归),换歌时自愈,而每首歌最多只多 fork 一次。
    /// 反过来"失败就不记、下一拍再试"会在 media-control 彻底坏掉时变成每 2 秒白 fork 一个子进程。
    private static func probedRadioStationHash(forTrack trackKey: String) -> String? {
        appleMusicRadioProbeLock.lock()
        if !radioProbeNeeded(cachedKey: appleMusicRadioProbedKey, trackKey: trackKey) {
            defer { appleMusicRadioProbeLock.unlock() }
            return appleMusicRadioProbedHash
        }
        appleMusicRadioProbeLock.unlock()
        noteRadioProbeReply(ran: true, reply: nil)
        let hash = probeRadioStationHash()
        appleMusicRadioProbeLock.lock()
        appleMusicRadioProbedKey = trackKey
        appleMusicRadioProbedHash = hash
        appleMusicRadioProbeLock.unlock()
        return hash
    }

    /// 只问 media-control 要两个字段:此刻系统在报谁、以及电台标识。
    ///
    /// **不复用** `fetchRawMediaControlSnapshot`:那个函数还会记未知播放器(设置页那张卡片的
    /// 数据源)、推进锚点目击表、动电台那块表 —— 在这条路上再跑一遍等于让两套位置逻辑同时写
    /// 同一份状态,而这里要的只是一个判据字段。
    private static func probeRadioStationHash() -> String? {
        guard let binaryPath = binaryPath(),
              let r = runGet(["--now", "--no-artwork"], binaryPath: binaryPath, timeout: snapshotTimeout),
              r.succeeded,
              let raw = try? JSONDecoder().decode(RawPayload.self, from: r.stdout)
        else { return nil }
        // 系统 Now Playing 焦点不是 Apple Music 时,这个 hash 属于**别人**(网页视频/另一个
        // 播放器),不能扣到 Music.app 头上 —— 跟 matchMediaControlState 那道核对同一条理由。
        guard raw.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier else { return nil }
        // 同一份应答里有这首的时长:AppleScript 没给时长的那几首拿它补(supplementingMissingAppleDuration),不再另问一次。
        let system = appleMusicSystemSnapshot(raw)
        noteRadioProbeReply(ran: true, reply: system)
        noteAppleMusicSystemDuration(trackKey: system.trackKey, duration: system.duration,
                                     isRadio: !(raw.radioStationHash ?? "").isEmpty)
        setNowPlayingIdentifiers(bundleID: PlaybackPlayer.appleMusic.bundleIdentifier, title: raw.title, artist: raw.artist,
                                 uniqueIdentifier: raw.uniqueIdentifier, trackNumber: raw.trackNumber,
                                 mediaType: raw.mediaType)
        let hash = raw.radioStationHash ?? ""
        return hash.isEmpty ? nil : hash
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
        /// 电台 / 直播流才有的电台标识(实测:Apple Music Radio 播放时非空,
        /// 值形如 "CgkIBRoFwOSKqxkQBA")。只当"这是不是电台"的判据用,值本身不看。
        let radioStationHash: String?
        /// 发布这份 Now Playing 的进程号。Amazon Music 的界面校准要它(见 AmazonMusicUIProbe)。
        let processIdentifier: Int?
        /// 放 Apple Music 目录曲目时是 Apple 的目录曲目 ID;本地文件是任意持久 ID。只原样转交引擎,
        /// 由它过目录锚点的守卫再用(见 `NowPlayingIdentifiers`)。
        let uniqueIdentifier: Int64?
        let trackNumber: Int?
        let mediaType: String?

        private enum CodingKeys: String, CodingKey {
            case title, artist, album, bundleIdentifier, playing, playbackRate, radioStationHash, processIdentifier
            case uniqueIdentifier, trackNumber, mediaType
        }

        /// 带 `--micros` 调用时四个时间键会被**替换**成微秒版,交给 `MediaControlMicros.TimeFields`
        /// 换算回原键名,下游只认一套字段。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            artist = try c.decodeIfPresent(String.self, forKey: .artist)
            album = try c.decodeIfPresent(String.self, forKey: .album)
            bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            playing = try c.decodeIfPresent(Bool.self, forKey: .playing)
            let rate = try c.decodeIfPresent(Double.self, forKey: .playbackRate)
            processIdentifier = try? c.decodeIfPresent(Int.self, forKey: .processIdentifier)
            radioStationHash = try c.decodeIfPresent(String.self, forKey: .radioStationHash)
            if let id = try? c.decodeIfPresent(Int64.self, forKey: .uniqueIdentifier) {
                uniqueIdentifier = id
            } else if let id = try? c.decodeIfPresent(Double.self, forKey: .uniqueIdentifier) {
                uniqueIdentifier = Int64(exactly: id)
            } else {
                uniqueIdentifier = nil
            }
            trackNumber = try? c.decodeIfPresent(Int.self, forKey: .trackNumber)
            mediaType = try? c.decodeIfPresent(String.self, forKey: .mediaType)
            let times = try MediaControlMicros.TimeFields(from: decoder)
            duration = times.duration
            timestamp = times.timestamp
            // VOX 那份播放中缺位置、恢复后速率报 0,补成能外推的锚点(见 VoxPlayerInfo.systemAnchor)。
            let anchor = VoxPlayerInfo.systemAnchor(
                bundleID: bundleIdentifier, playing: playing, elapsed: times.elapsedTime,
                elapsedNow: times.elapsedTimeNow, rate: rate, hasTimestamp: times.timestamp != nil)
            elapsedTime = anchor.elapsed
            elapsedTimeNow = anchor.elapsedNow
            playbackRate = anchor.rate
        }
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

    // MARK: - 常驻取数进程(见 02 章决策 111)

    /// 两个常驻脚本进程回答的结束行标记(见 `PersistentScriptServer`)。
    static let scriptServerEndMarker = "__LYRIMUSE_SCRIPT_END__"
    /// 常驻取数进程每答这么多次换一个:适配器每答一次,进程涨约 8KB。
    static let getServerRecycleAfterRequests = 300
    /// 取封面的常驻进程:带封面的回答每次让它涨约五倍于回答的内存,回答累计到这么多字节就换(一张专辑封面约 160KB,
    /// 九张左右换一次);系统一直不给封面、回答很小的歌,答满这么多次也换。见 02 章决策 146。
    static let artworkServerRecycleAfterBytes = 1_500_000
    static let artworkServerRecycleAfterRequests = 60
    /// 常驻 osascript 每答这么多次换一个:每答一次,进程涨 24~72KB。
    static let appleScriptServerRecycleAfterRequests = 100

    /// 常驻取数进程跑的 perl:加载适配框架一次,之后每读到一行请求(适配器的选项名,空格分隔)就按它设好选项环境变量、
    /// 调一次 `adapter_get_env`(回答由适配器直接写 stdout,跟 `media-control get` 最后调的是同一个函数),再写结束行。
    /// stdin 读到 EOF 就退出。
    public static let getServerScript = #"""
    use strict; use warnings; use DynaLoader;
    $| = 1;
    my $framework = shift @ARGV;
    my ($name) = $framework =~ m{([^/]+)\.framework/?$} or exit 2;
    my $handle = DynaLoader::dl_load_file("$framework/$name", 0) or exit 3;
    my $symbol = DynaLoader::dl_find_symbol($handle, 'adapter_get_env') or exit 4;
    DynaLoader::dl_install_xsub('main::adapter_get', $symbol);
    while (my $line = <STDIN>) {
        my %want = map { $_ => 1 } split ' ', $line;
        for my $option (qw(micros no_artwork now)) {
            if ($want{$option}) { $ENV{"MEDIAREMOTEADAPTER_OPTION_$option"} = '' }
            else { delete $ENV{"MEDIAREMOTEADAPTER_OPTION_$option"} }
        }
        adapter_get();
        print "\n\#(scriptServerEndMarker) 0\n";
    }
    """#

    static let getServer = PersistentScriptServer(
        label: "media-control get server", endMarker: scriptServerEndMarker,
        recycleAfterRequests: getServerRecycleAfterRequests, launch: { getServerLaunch() })

    /// 取封面单独一个常驻进程,跟每拍轮询那个分开:封面回答撑大的内存不带进轮询那个、换进程的节奏也各管各的。
    static let artworkServer = PersistentScriptServer(
        label: "media-control artwork server", endMarker: scriptServerEndMarker,
        recycleAfterRequests: artworkServerRecycleAfterRequests, recycleAfterBytes: artworkServerRecycleAfterBytes,
        launch: { getServerLaunch() })

    /// 常驻取数进程的起法:`/usr/bin/perl -e getServerScript <适配框架>`。没走 build.sh 打包、找不到适配框架时为 nil。
    private static func getServerLaunch() -> PersistentScriptServer.Launch? {
        guard let binary = binaryPath() else { return nil }
        let framework = URL(fileURLWithPath: binary).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Frameworks/MediaRemoteAdapter.framework").path
        guard FileManager.default.fileExists(atPath: framework + "/MediaRemoteAdapter") else { return nil }
        return .init(executable: "/usr/bin/perl", arguments: ["-e", getServerScript, framework])
    }

    /// `media-control get` 的参数换成常驻取数进程的请求行(适配器的选项名,`--no-artwork` → `no_artwork`)。只认这三个,
    /// 带别的参数时为 nil(走子进程)。纯函数,selftest 覆盖。
    public static func getServerRequest(for arguments: [String]) -> String? {
        var names: [String] = []
        for argument in arguments {
            switch argument {
            case "--now": names.append("now")
            case "--no-artwork": names.append("no_artwork")
            case "--micros": names.append("micros")
            default: return nil
            }
        }
        return names.joined(separator: " ")
    }

    /// 跑一次 `media-control get <arguments>`:先问常驻取数进程,这次用不上再起子进程。
    private static func runGet(_ arguments: [String], binaryPath: String, timeout: TimeInterval) -> ProcessRunner.Result? {
        if let request = getServerRequest(for: arguments), let result = getServer.request(request, timeout: timeout) {
            return result
        }
        return ProcessRunner.run(binaryPath, ["get"] + arguments, timeout: timeout)
    }

    /// 常驻 osascript 跑的 JXA:每读到一行请求名(`music` / `spotify` / `kaset` / `vox`)就跑对应那份快照脚本,把它返回的字符串原样
    /// 写到 stdout,再写结束行;脚本抛错时状态码为 1。stdin 读到 EOF 就退出。
    /// JXA 把 NSData 的 `length` 桥成字符串,判 EOF 必须先转数字:写成 `data.length === 0` 永远不成立,EOF 之后空转占满一个核。
    public static let appleScriptServerScript = """
    ObjC.import('Foundation');
    const handlers = {
        music: () => \(script),
        spotify: () => \(spotifyScript),
        kaset: () => \(kasetScript),
        vox: () => \(VoxPlayerInfo.script)
    };
    const input = $.NSFileHandle.fileHandleWithStandardInput;
    const output = $.NSFileHandle.fileHandleWithStandardOutput;
    let pending = '';
    for (;;) {
        const data = input.availableData;
        if (Number(data.length) === 0) break;
        pending += $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
        let newline;
        while ((newline = pending.indexOf('\\n')) >= 0) {
            const name = pending.slice(0, newline).trim();
            pending = pending.slice(newline + 1);
            let text = '';
            let status = 0;
            try {
                const result = handlers[name] ? handlers[name]() : '';
                text = result === undefined || result === null ? '' : String(result);
            } catch (e) {
                status = 1;
            }
            output.writeData($(text + '\\n\(scriptServerEndMarker) ' + status + '\\n').dataUsingEncoding($.NSUTF8StringEncoding));
        }
    }
    """

    static let appleScriptServer = PersistentScriptServer(
        label: "osascript snapshot server", endMarker: scriptServerEndMarker,
        recycleAfterRequests: appleScriptServerRecycleAfterRequests,
        launch: { .init(executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", appleScriptServerScript]) })

    /// 跑一份播放器快照脚本:`name` 是常驻 osascript 里的请求名,`source` 是同一份脚本。先问常驻 osascript,这次用不上
    /// 再起一个 osascript。
    private static func runPlayerScript(_ name: String, source: String) -> ProcessRunner.Result? {
        let timeout = MusicPlaybackController.appleScriptTimeout
        if let result = appleScriptServer.request(name, timeout: timeout) { return result }
        return ProcessRunner.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", source], timeout: timeout)
    }

    // 只认一个 bundle id 的读取:真正跑 media-control 子进程、解析原始输出的逻辑收在 fetchRawMediaControlSnapshot 里,
    // 这里只核对 bundle id 对不对得上。
    private static func fetchMediaControlSnapshot(expectedBundleID: String) -> MediaControlSnapshot? {
        guard let (snapshot, bundleID) = fetchRawMediaControlSnapshot(), bundleID == expectedBundleID else {
            // bundleIdentifier 对不上:系统当前的 Now Playing 是别的 App(网页视频/
            // Safari/另一个播放器等),不是当前选定的这个——不能把它当成这个播放器的
            // "正在播放"。
            return nil
        }
        return snapshot
    }

    // fetchMultiSelectedSnapshot 是"显式多选了若干个具体播放器、没有勾自动识别"的读取路径,跟 fetchAutoDetectedSnapshot
    // 同一套"系统级 Now Playing 只有一个焦点,问 media-control 一次就知道是谁"的机制,区别只在准入名单:这里认的是 players 里
    // 用户选中的那几个,加上信任列表(见 TrustedPlayers.isTrusted 的注释:「网页版」卡片配对浏览器会顺带信任它,跟"选没选
    // 自动识别"是两件独立的事,不该因为没勾自动识别就让配对形同虚设)。
    private static func fetchMultiSelectedSnapshot(_ players: Set<PlaybackPlayer>) -> MediaControlSnapshot? {
        let acceptedBundleIDs = Set(players.map(\.bundleIdentifier))
        // 跟 fetchAutoDetectedSnapshot 同一条兜底:焦点被别的 App 占走时直接问上一份被接受的快照所属的播放器,但只在用户
        // 勾了它时。开关与收敛性见 snapshotAfterFocusLost 的头注。
        func fallback() -> MediaControlSnapshot? {
            appleMusicFocusLock.lock()
            let candidate = lastAcceptedDirectQueryTarget
            appleMusicFocusLock.unlock()
            // 仍要核一次"用户这次确实勾了它" —— 开关只说明上一份快照来自谁,不代表它还在名单里。
            // 「其他 App」里信任的那几个不在勾选集合里,还在信任名单上就算(snapshotAfterFocusLost 里再核一次)。
            guard let candidate else { return nil }
            if let player = candidate.player, !players.contains(player) { return nil }
            return snapshotAfterFocusLost()
        }
        guard let (snapshot, bundleID) = resolvingSpotifyConnectMirror(fetchRawMediaControlSnapshot()) else {
            return fallback() ?? snapshotWhileChannelBroken(players: players)
        }
        if !acceptedBundleIDs.contains(bundleID) {
            guard TrustedPlayers.isTrusted(bundleID) else {
                setSnapshotFailure(.playerNotSelected)
                return fallback()
            }
            // 走信任列表这条路进来的(不是用户在「播放器」卡里选中的具体播放器)要多过
            // 一道"这是不是一首歌"的守卫——跟 fetchAutoDetectedSnapshot 的信任分支同一套
            // 语义,理由见 TrustedPlayers.notASong 的注释(浏览器视频/播客不能被当成一首歌)。
            if playerContentNotMusic(bundleID: bundleID, snapshot: snapshot) { return nil }
            guard !trustedPlaybackRejected(bundleID: bundleID, snapshot: snapshot) else {
                setSnapshotFailure(.notASong)
                return fallback()
            }
            noteAccepted(bundleID: bundleID)
            return adaptedSnapshot(
                bundleID: bundleID, mediaControl: snapshotWithProbedAlbum(snapshot))
        }
        // 勾选的内置播放器也过一次:KKBOX 的播客、开播那一帧还没有歌手,都不退回去问别家。
        if playerContentNotMusic(bundleID: bundleID, snapshot: snapshot) { return nil }
        if artistNotYetReported(bundleID: bundleID, snapshot: snapshot) { return nil }
        guard !trustedPlaybackRejected(bundleID: bundleID, snapshot: snapshot) else {
            setSnapshotFailure(.notASong)
            return fallback()
        }
        noteAccepted(bundleID: bundleID)
        return adaptedSnapshot(bundleID: bundleID, mediaControl: snapshot)
    }

    // MARK: - 焦点被别的 App 抢走时退回 AppleScript

    /// 这一拍为什么没拿到快照。**只为归因日志,任何一条都不改变行为。**
    ///
    /// 失败原因必须分得开:合成一句 `snapshot failed (no automation permission,
    /// Music.app not running, or nothing playing)` 既混了三种原因、又**漏掉第四种**
    /// (焦点被别的 App 占走 / 私有通道坏了)。诊断日志里只有这一句时,排查指不出任何方向。
    ///
    /// rawValue 必须是英文:它会被原样插进 OSLog,而 selftest 的「日志规范」那条守卫
    /// 不许日志字面量含 CJK。
    public enum SnapshotFailure: String, Sendable {
        case mediaControlMissing = "media-control binary is not bundled"
        case mediaControlUnavailable = "media-control exited non-zero (the private MediaRemote channel may be broken)"
        case nobodyReporting = "no app is reporting Now Playing"
        case focusHeldByOtherApp = "Now Playing focus is held by an app we do not accept"
        case notASong = "the reporting app is trusted but this is not a song"
        case appleScriptUnavailable = "AppleScript could not reach Music.app (no automation permission, not running, or stopped)"
        case playerNotSelected = "the reporting app is not among the players the user selected"
        /// 报的就是我们要的播放器,但它此刻放的不是歌(KKBOX / Amazon 的播客单集、Amazon 上一次会话留下的陈旧元数据)。
        /// 跟 `notASong`(别的 App 在放非歌曲内容)不同:这里焦点没被别人占,是这个播放器确实没在放音乐,按短宽限清
        /// (引擎那边同样交回空状态,约 3 拍清掉)。
        case targetNotPlayingMusic = "the selected player is reporting something that is not a song"
        /// 报的就是我们要的播放器,它在加载下一首(Kaset 的开播占位、新的一条还没问到是不是播客)。不是没在放:留着上一首,
        /// 按 `loadingGraceSeconds` 清,不然换歌那一下界面整个空掉(见 02 章决策 92)。
        case targetLoading = "the selected player is loading the next track"
    }

    private static let failureLock = NSLock()
    private static var lastFailure: SnapshotFailure?

    static func setSnapshotFailure(_ reason: SnapshotFailure?) {
        failureLock.lock()
        lastFailure = reason
        failureLock.unlock()
    }

    /// 最近一次 `fetchSnapshot` 返回 nil 的原因(每次 fetchSnapshot 入口清零)。
    public static var lastSnapshotFailure: SnapshotFailure? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return lastFailure
    }

    /// 上一份**被接受**的快照来自哪个"能直接问它自己"的播放器(nil = 没有 / 那个播放器没有直查通路)
    /// —— 回退的唯一开关。
    private static let appleMusicFocusLock = NSLock()
    private static var lastAcceptedDirectQueryTarget: FocusFallbackTarget?
    /// 回退已经问过、确认目标播放器不在了(退出 / stopped / 权限没了),之后还没接受过任何快照。这时焦点虽然还被别人占着,
    /// 我们要的那个已经不在放:后面几拍回退入口没有目标可问,失败原因要记成「问不到」,不能停在「焦点被占」那一档挂 300 秒。
    private static var fallbackTargetGone = false
    /// 回退连着问不到了几拍。问到、或正常路径接受了快照就清零。
    private static var fallbackFailureStreak = 0

    /// 回退入口没有目标可问时,这一拍的失败原因要不要改记。纯函数,selftest 覆盖。
    public static func failureWithoutFallbackTarget(targetConfirmedGone: Bool) -> SnapshotFailure? {
        targetConfirmedGone ? .appleScriptUnavailable : nil
    }

    /// 这个 bundle id 对应的播放器,焦点被占时有没有办法绕开 media-control 问到它自己。
    ///
    /// **所有内置播放器都有** —— `NowPlayingClientsProbe` 是按 bundle id 直接问系统的,不挑播放器,
    /// 连没有 AppleScript 字典的 QQ 音乐 / 网易云 / 酷狗 / 汽水音乐都覆盖。Apple Music 与 Spotify
    /// 额外还有一条 JXA 通路,在探针不可用时兜底(见 `snapshotAfterFocusLost` 的两级顺序)。
    ///
    /// `.auto` 的 `bundleIdentifier` 是空字符串,不会匹配到任何真实 bundle id,不用单独排除。
    public static func directQueryPlayer(forBundleID bundleID: String?) -> PlaybackPlayer? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return PlaybackPlayer.allCases.first { $0.bundleIdentifier == bundleID }
    }

    /// 焦点被占时回退去问的那个播放器。内置的带上 `player`(有 AppleScript 字典的先问它自己);
    /// 「其他 App」里信任的只有 bundle id,只走按 bundle id 问系统那一级。
    public struct FocusFallbackTarget: Equatable {
        public let bundleID: String
        public let player: PlaybackPlayer?

        public init(bundleID: String, player: PlaybackPlayer?) {
            self.bundleID = bundleID
            self.player = player
        }
    }

    /// 这个 bundle id 焦点被占时能不能直接问到。内置播放器都能;「其他 App」里信任的也能(探针按 bundle id 问,不挑播放器),
    /// 浏览器除外:抢焦点的视频常常就在浏览器自己里,网页播放器另有按页面读的那条路(`BrowserPositionProbe`)。
    /// 纯函数,信任名单由调用方传入。见 02 章决策 138。
    public static func focusFallbackTarget(forBundleID bundleID: String?, trusted: [String: String]) -> FocusFallbackTarget? {
        if let player = directQueryPlayer(forBundleID: bundleID) {
            return FocusFallbackTarget(bundleID: player.bundleIdentifier, player: player)
        }
        guard let bundleID, TrustedPlayers.isTrusted(bundleID, trusted: trusted), !isBrowser(bundleID) else { return nil }
        return FocusFallbackTarget(bundleID: bundleID, player: nil)
    }

    private static func isBrowser(_ bundleID: String) -> Bool {
        BrowserAutomationPermission.family(forBundleID: bundleID) != nil
            || BrowserAutomationPermission.knownBrowserBundleIDs.contains(bundleID)
            || TrustedPlayers.mediaProxyOwner(of: bundleID) != nil
    }
    /// 此刻是不是正处在回退状态(只为让那条 notice 日志在**状态翻转**时打一次,不是每拍都打)。
    private static var fallbackActive = false
    /// 这一拍回退是不是经 AppleScript 问到的(而不是 per-client 探针)。播放控制要不要改发 AppleScript 看它,
    /// 见 `focusControlContext`。
    private static var fallbackViaAppleScript = false

    /// 回退开关的状态转移。纯函数,selftest 覆盖 —— 这条把"它会不会一直白 fork 下去"
    /// 写成了可验证的形式。
    ///
    /// - Parameter acceptedBundleID: 这一拍**被接受**的快照来自谁(nil = 这一拍没拿到)。
    /// - Parameter fallbackSucceeded: 回退问 Music.app 有没有拿到东西(nil = 这一拍没走回退)。
    /// - Parameter consecutiveFailures: 回退连着问不到了几拍(含这一拍),只在 fallbackSucceeded 为 false 时看。不传按已到
    ///   `fallbackRetryLimit` 算。
    public static func nextFocusFallbackPlayer(
        current: PlaybackPlayer?, acceptedBundleID: String?, fallbackSucceeded: Bool?,
        consecutiveFailures: Int = MediaControlClient.fallbackRetryLimit
    ) -> PlaybackPlayer? {
        nextFocusFallbackTarget(
            current: current.map { FocusFallbackTarget(bundleID: $0.bundleIdentifier, player: $0) },
            acceptedBundleID: acceptedBundleID, trusted: [:], fallbackSucceeded: fallbackSucceeded,
            consecutiveFailures: consecutiveFailures)?.player
    }

    /// 同 `nextFocusFallbackPlayer`,目标也可以是「其他 App」里信任的播放器(`trusted` 是信任名单)。
    public static func nextFocusFallbackTarget(
        current: FocusFallbackTarget?, acceptedBundleID: String?, trusted: [String: String], fallbackSucceeded: Bool?,
        consecutiveFailures: Int = MediaControlClient.fallbackRetryLimit
    ) -> FocusFallbackTarget? {
        // 正常路径拿到了快照:它是谁说了算 —— 切到没有直查通路的播放器就当场关掉开关。
        if let acceptedBundleID { return focusFallbackTarget(forBundleID: acceptedBundleID, trusted: trusted) }
        // 走了回退:拿到了就保持(它还在放,焦点被占多久都兜得住)。拿不到先留着,下一拍接着问:偶尔一拍超时不该把回退
        // 整个关掉,关掉之后要等它重新拿到焦点才会再问,这期间屏上一直没有歌词。连着问不到 fallbackRetryLimit 拍才关
        // (播放器退出 / stopped / 权限没了),此后不再为它 fork。
        if let fallbackSucceeded {
            return fallbackSucceeded || consecutiveFailures < fallbackRetryLimit ? current : nil
        }
        return current
    }

    /// 回退连着问不到几拍才放弃那个播放器。跟屏上那首在空快照之后留几拍(`nilSnapshotGrace`)一样:还显示着就接着问,
    /// 清掉了就不再为它起子进程。
    public static let fallbackRetryLimit = nilSnapshotGrace

    /// 此刻是不是正处在「焦点被别人占走、正靠回退取数」的状态,是的话回退到哪个播放器。
    /// 封面那条路要跟快照对齐,靠的就是它 —— 不然会拿回占用者的图。
    private static func activeFocusFallbackTarget() -> FocusFallbackTarget? {
        appleMusicFocusLock.lock()
        defer { appleMusicFocusLock.unlock() }
        return fallbackActive ? lastAcceptedDirectQueryTarget : nil
    }

    /// 控制所需的回退目标与保护状态在同一次读取里取出,避免拼接不同轮询拍的值。
    /// Kaset 顶替和会话保持仍按各自已有的锁读取。`directQueryTarget` 是能定向按菜单的那个播放器:直查回退问到的,
    /// 或者屏上这首是它会话被撤后保持出来的(这时系统焦点空着或在别人手里,屏上这首仍是它在放)。
    public static func focusControlContext() -> (scriptTarget: PlaybackPlayer?, directQueryTarget: PlaybackPlayer?, heldElsewhere: Bool) {
        kasetLock.lock()
        let kasetPreferred = kasetPreferredOver != nil
        let lxMusicPreferred = lxMusicPreferredOver != nil
        kasetLock.unlock()
        appleMusicFocusLock.lock()
        let scriptTarget = fallbackActive && fallbackViaAppleScript ? lastAcceptedDirectQueryTarget?.player : channelFallbackPlayer
        let directQueryTarget = fallbackActive ? lastAcceptedDirectQueryTarget?.player : nil
        let viaProbe = shouldWithholdFocusControls(
            fallingBack: fallbackActive, targetGone: fallbackTargetGone, viaAppleScript: fallbackViaAppleScript)
        appleMusicFocusLock.unlock()
        gapHoldLock.lock()
        let heldElsewhere = viaProbe || holdingDroppedSession
        let droppedSessionPlayer = holdingDroppedSession
            ? PlaybackPlayer.builtin(forBundleID: gapHoldLast?.snapshot.bundleIdentifier) : nil
        let holdingAcrossGap = gapHoldingSince != nil
        gapHoldLock.unlock()
        let target = controlScriptTarget(kasetPreferred: kasetPreferred, lxMusicPreferred: lxMusicPreferred,
                                         holdingAcrossGap: holdingAcrossGap, scriptTarget: scriptTarget)
        return (target, directQueryTarget ?? droppedSessionPlayer, heldElsewhere)
    }

    /// 播放控制按哪家的脚本发。Kaset / 洛雪顶替了系统那边的读数时发给它们;但切歌间隙保持(`heldAcrossPlayerGap`)把屏上
    /// 留在别的播放器时,顶替是这一拍按「系统什么都没报」判出来的,屏上并不是它们 —— 这时照回退目标发,不然按播放会把暂停着的
    /// Kaset / 洛雪放起来,跟保持着的那家同时出声。见 02 章决策 149。纯函数,selftest 覆盖。
    public static func controlScriptTarget(kasetPreferred: Bool, lxMusicPreferred: Bool, holdingAcrossGap: Bool,
                                           scriptTarget: PlaybackPlayer?) -> PlaybackPlayer? {
        guard !holdingAcrossGap else { return scriptTarget }
        return kasetPreferred ? .kaset : lxMusicPreferred ? .lxMusic : scriptTarget
    }

    /// 回退查询失败只关闭读取开关,不证明焦点恢复。targetGone 由被接受的快照清零;
    /// 在此前的显示宽限期里仍不能把全局控制发到网页视频。纯判据供状态转移测试复用。
    public static func shouldWithholdFocusControls(
        fallingBack: Bool, targetGone: Bool, viaAppleScript: Bool
    ) -> Bool {
        (fallingBack || targetGone) && !viaAppleScript
    }

    /// 正常路径拿到了被接受的快照 —— 记下它是谁报的。
    private static func noteAccepted(bundleID: String) {
        // 信任名单要读盘,只在不是内置播放器时读。
        let trusted = directQueryPlayer(forBundleID: bundleID) == nil ? TrustedPlayers.current : [:]
        let webSource = SpotifyConnectMirror.nextWebSource(
            acceptedBundleID: bundleID,
            acceptedIsSpotifyWebBrowser: directQueryPlayer(forBundleID: bundleID) == nil && isSpotifyWebBrowser(bundleID))
        appleMusicFocusLock.lock()
        lastAcceptedDirectQueryTarget = nextFocusFallbackTarget(
            current: lastAcceptedDirectQueryTarget, acceptedBundleID: bundleID, trusted: trusted, fallbackSucceeded: nil)
        spotifyWebSource = webSource
        fallbackTargetGone = false
        fallbackFailureStreak = 0
        let wasFallingBack = fallbackActive
        fallbackActive = false
        appleMusicFocusLock.unlock()
        if wasFallingBack {
            logger.notice("now playing focus regained; back on media-control")
        }
    }

    // MARK: - 桌面版 Spotify 的 Connect 镜像

    /// 上一份被接受的快照来自配对了 Spotify 网页版的浏览器时,它报上来的 bundle id(Safari 是它的媒体进程);别的情况为 nil。
    private static var spotifyWebSource: String?
    /// 此刻是不是正把焦点上的桌面版 Spotify 当成镜像、改用网页版那份(只为让日志在状态翻转时各打一条)。
    private static var spotifyMirrorActive = false

    /// 焦点上的桌面版 Spotify 正在遥控网页版(Spotify Connect)时,换成网页版自己报的那份。判据见 `SpotifyConnectMirror`。
    ///
    /// 只在「上一份被接受的来自网页版、焦点跳到了桌面版」时才动:先问 CoreAudio 桌面版有没有在本机输出音频(不起子进程),
    /// 没在输出才按 bundle id 问一次网页版(起一个子进程)。问不到、或者不是同一首,就照旧用桌面版那份,并清掉记录,
    /// 之后不再问,直到又接受了一份网页版的快照。
    private static func resolvingSpotifyConnectMirror(
        _ raw: (MediaControlSnapshot, String)?
    ) -> (MediaControlSnapshot, String)? {
        guard let (snapshot, bundleID) = raw, bundleID == PlaybackPlayer.spotify.bundleIdentifier else { return raw }
        appleMusicFocusLock.lock()
        let webSource = spotifyWebSource
        appleMusicFocusLock.unlock()
        guard let webSource else { return raw }
        let ask = SpotifyConnectMirror.shouldAskWebPlayer(
            focusBundleID: bundleID, webSourceBundleID: webSource,
            desktopOutputting: ProcessAudioOutput.isRunningOutput(bundleID: bundleID))
        let web = ask ? NowPlayingClientsProbe.snapshot(forBundleID: webSource) : nil
        let useWeb = ask && SpotifyConnectMirror.webPlayerWins(desktop: snapshot, web: web)
        appleMusicFocusLock.lock()
        let wasActive = spotifyMirrorActive
        spotifyMirrorActive = useWeb
        if !useWeb { spotifyWebSource = nil }
        appleMusicFocusLock.unlock()
        if useWeb, let web {
            if !wasActive {
                logger.notice("now playing: \(bundleID, privacy: .public) is mirroring the Spotify web player; staying on \(webSource, privacy: .public)")
            }
            return (web, webSource)
        }
        if wasActive {
            logger.notice("now playing: \(bundleID, privacy: .public) no longer mirrors the Spotify web player; using it again")
        }
        return raw
    }

    /// 这个 bundle id 是不是配对了 Spotify 网页版的浏览器(Safari 报上来的是它的媒体进程,先换成宿主再查配对)。
    private static func isSpotifyWebBrowser(_ bundleID: String) -> Bool {
        BrowserPositionProbe.shared.isPaired(
            bundleID: BrowserPositionProbe.probeTargetBundleID(forReported: bundleID), platformID: "spotifyWeb")
    }

    /// media-control 这一拍没给出可用快照(通道坏 / 没人在报 / 焦点在别的 App 上)时,直接去问上一份被接受的快照所属的播放器
    /// (`lastAcceptedDirectQueryTarget`,没有直查通路的播放器不记):Apple Music / Spotify / Kaset 问它自己的 AppleScript
    /// 字典,其余(含「其他 App」里信任的)按 bundle id 直接问系统(`NowPlayingClientsProbe`)。见 02 章决策 36、37、138。
    ///
    /// ## 为什么需要它
    ///
    /// MediaRemote 的「正在播放」是系统级的单一焦点,任何注册了 MPNowPlayingInfoCenter 的 App 都能占走(网页里一个 video 元素
    /// 就够)。默认配置(`[.auto]`)下播放器的身份基座也是 media-control(它回答"现在是谁在放")。焦点一被占,这条路直接
    /// return nil → `LocalPlaybackSource` 把歌词 / 标题 / 封面全清空,而播放器一直在放。
    ///
    /// ## 为什么不是"每拍都并发问一次 AppleScript"
    ///
    /// 对从不用 Apple Music 的 .auto 用户(只听 QQ 音乐 / 网易云 / Spotify)凭空每拍多 fork 一个 osascript,而且首次对 Music.app
    /// 发 Apple Event 会弹一次"自动化"权限对话框,对完全不相关的用户弹这个框不可接受。上面那个开关把它挡死:只有已经从这个播放器
    /// 拿到过快照的用户才会走到这里。对这些人这条 osascript 本来就在跑(`adaptedSnapshot` 在播放中每拍都调同一个脚本),所以这条
    /// 回退一次额外的自动化权限对话框都不会多弹。
    ///
    /// 电台在回退期间退化成普通曲目:台标识 `radioStationHash` 是 MediaRemote 独有的字段,而这条路正是 media-control 不可用时才走的。
    /// 跟 `probedRadioStationHash` 探测失败时按"不是电台"处理是同一个取舍。
    ///
    /// 已知边界,刻意不补:进程刚起来时开关是 false。如果启动那一刻焦点正好被别的 App 占着,这一拍兜不住,要等焦点回到那个播放器
    /// 一次把开关点亮。补法是把开关持久化进 UserDefaults,代价是"用过 Apple Music、现在改用 QQ 音乐"的人每次冷启动白 fork 一次
    /// osascript,而冷启动恰好撞上焦点被占的概率很低(用户一般是听着歌才打开它)。
    private static func snapshotAfterFocusLost() -> MediaControlSnapshot? {
        appleMusicFocusLock.lock()
        let allowed = lastAcceptedDirectQueryTarget
        let targetGone = fallbackTargetGone
        appleMusicFocusLock.unlock()
        // 信任的播放器被移出名单之后不再替它问。
        guard let target = allowed, target.player != nil || TrustedPlayers.isTrusted(target.bundleID) else {
            if let failure = failureWithoutFallbackTarget(targetConfirmedGone: targetGone) { setSnapshotFailure(failure) }
            return nil
        }
        // 第一级:问播放器**自己的钟**(只有 Apple Music / Spotify / Kaset / VOX 有 AppleScript 字典)。
        //
        // 顺序是这样定的,别调过来:per-client 探针拿回来的是**同一份 MediaRemote 载荷**,
        // 因此原样继承了那条链的锚点缺陷 —— Spotify 的开播锚点实测晚 ~2s(02 章决策 28:+1.91 /
        // +1.96 / +2.14),Apple Music 手动点歌时会连发好几个 elapsed=0 锚点(02 章决策 35)。
        // 真机对照:焦点被占期间暂停 Spotify,走 JXA 时 `pause transition delta=-0.157`,
        // 走探针时 `delta=-2.039`。AppleScript 那份带的只是输出链路的领先量(0.06~0.65s),
        // 明显更小。
        var snapshot: MediaControlSnapshot?
        switch target.player {
        case .appleMusic: snapshot = fetchAppleMusicSnapshot()
        case .spotify: snapshot = fetchSpotifySnapshot()
        case .kaset: snapshot = fetchKasetSnapshot()
        case .vox:
            // 网络电台的这一首只在系统那份里:按 bundle id 单问一份拿 ICY 标题,拿不到交给下面那一级。
            snapshot = fetchVoxSnapshot().flatMap { vox in
                guard VoxPlayerInfo.isRadioReading(vox) else { return vox }
                return VoxPlayerInfo.radioSnapshot(
                    station: vox, system: NowPlayingClientsProbe.snapshotWithAnchor(forBundleID: target.bundleID)?.snapshot,
                    now: Date())
            }
        default: break
        }
        let viaAppleScript = snapshot != nil
        // 第二级:按 bundle id 直接问系统。不受焦点影响,而且是**没有 AppleScript 字典的那几家**
        // (QQ 音乐 / 网易云 / 酷狗 / 汽水音乐)唯一能问到真相的通路;对 Apple Music / Spotify 则是字典不可用
        // (没装 helper 之外的情况:Music.app 没在跑、自动化权限被收回)时的兜底。
        // Kaset 不走这一级:系统按 bundle id 存着的就是它自己发的那份,换歌后常停在上一首(见 KasetPlayerInfo 头注)。
        if snapshot == nil, target.player != .kaset,
           let probed = NowPlayingClientsProbe.snapshotWithAnchor(forBundleID: target.bundleID) {
            let now = Date()
            snapshot = VoxPlayerInfo.systemFallback(VoxPlayerInfo.probedSnapshot(
                probed.snapshot, anchorTimestamp: probed.anchor.timestamp, pid: probed.anchor.processIdentifier, now: now))
            if target.bundleID == PinePlayerInfo.bundleID {
                snapshot = pineProbedSnapshot(probed.snapshot, anchor: probed.anchor, now: now)
            }
            if let reading = amazonMusicReading(
                bundleID: target.bundleID, trackKey: probed.snapshot.trackKey, title: probed.snapshot.title,
                metadataTimestamp: probed.anchor.timestamp.map { Date(timeIntervalSince1970: $0) },
                playing: probed.snapshot.playing == true, pid: probed.anchor.processIdentifier.map { Int($0) },
                duration: probed.snapshot.duration, now: now) {
                if reading.staleMetadata {
                    setSnapshotFailure(.targetNotPlayingMusic)
                    return nil
                }
                snapshot = probed.snapshot.withPlayerClock(reading.position, capturedAt: now)
            }
        }
        // 回退问到的这一份跟主路径过同一道闸:KKBOX / Amazon 在放播客单集、
        // 开播那一帧还没有歌手的,主路径会挡下,从这里绕进来的却会被当成一首歌去查歌词、换一次曲目身份丢一次封面。
        // 挡下时不动回退开关:播放器还是那一个,只是这一拍没有可报的歌。
        if let s = snapshot {
            if playerContentNotMusic(bundleID: target.bundleID, snapshot: s) { return nil }
            // 开播那一帧还没有歌手(KKBOX)是在加载这一首,同主路径按「在加载」交回空,不记成「不是歌」。
            if artistNotYetReported(bundleID: target.bundleID, snapshot: s) { return nil }
            if trustedPlaybackRejected(bundleID: target.bundleID, snapshot: s) {
                setSnapshotFailure(.notASong)
                return nil
            }
        }
        appleMusicFocusLock.lock()
        fallbackFailureStreak = snapshot == nil ? fallbackFailureStreak + 1 : 0
        lastAcceptedDirectQueryTarget = nextFocusFallbackTarget(
            current: allowed, acceptedBundleID: nil, trusted: [:], fallbackSucceeded: snapshot != nil,
            consecutiveFailures: fallbackFailureStreak)
        let firstTick = !fallbackActive
        fallbackActive = snapshot != nil
        fallbackTargetGone = snapshot == nil
        fallbackViaAppleScript = viaAppleScript
        appleMusicFocusLock.unlock()
        guard snapshot != nil else {
            setSnapshotFailure(.appleScriptUnavailable)
            return nil
        }
        // 只在**进入**回退那一拍记一条(落盘),焦点被占多久都不会刷屏。
        if firstTick {
            let name = target.bundleID
            // 说清走的是哪一级 —— 两级的精度与可用性不一样,只看"进回退了"分不出来。
            let via = viaAppleScript ? "AppleScript" : "per-client MediaRemote probe"
            logger.notice("now playing focus lost to another app; falling back to \(via, privacy: .public) for \(name, privacy: .public)")
        }
        return snapshot
    }

    // MARK: - media-control 通道坏了时直问 Apple Music / Spotify

    /// 连续这么多次 media-control 子进程报错就按通道坏了处理。
    public static let channelExecFailThreshold = 3
    /// 下面四个受 `appleMusicFocusLock` 保护。
    private static var channelExecFailures = 0
    private static var channelTestFailed = false
    /// 本进程读到过一份真快照。之后 `test` 的失败不再算数:通道已经证明能用,自检偶发失败不该把读取切到直问。
    private static var channelSeenSnapshot = false
    /// 通道坏了期间屏上这首经 AppleScript 问自哪个播放器(nil = 没在靠直问取数)。播放控制看它,见 `focusControlContext`。
    private static var channelFallbackPlayer: PlaybackPlayer?

    /// `MediaControlHealth` 落定结论时调:`media-control test` 失败 = 通道坏了。系统更新弄坏私有 MediaRemote
    /// 通道后,`get` 常常照常退出、对谁都回 null,光看子进程退出码认不出来,要靠这条。
    public static func setChannelTestFailed(_ failed: Bool) {
        appleMusicFocusLock.lock()
        channelTestFailed = failed && !channelSeenSnapshot
        appleMusicFocusLock.unlock()
    }

    private static func noteChannelExec(succeeded: Bool) {
        appleMusicFocusLock.lock()
        channelExecFailures = succeeded ? 0 : channelExecFailures + 1
        appleMusicFocusLock.unlock()
    }

    /// 真读到了一份快照:通道好了。直问期间记下的播放器一并撤掉,不然播放控制还会绕开 media-control 发给它
    /// (`focusControlContext`),哪怕用户已经换到别的播放器。
    private static func noteChannelReadSnapshot() {
        appleMusicFocusLock.lock()
        channelTestFailed = false
        channelSeenSnapshot = true
        let wasFallingBack = channelFallbackPlayer != nil
        channelFallbackPlayer = nil
        appleMusicFocusLock.unlock()
        if wasFallingBack {
            logger.notice("media-control channel usable again; back on media-control")
        }
    }

    /// 此刻是否按通道坏了处理。纯函数,selftest 覆盖。
    public static func channelLooksBroken(execFailures: Int, testFailed: Bool) -> Bool {
        execFailures >= channelExecFailThreshold || testFailed
    }

    /// 通道坏了时按顺序问谁:勾了「自动识别」有字典的几家都问,否则只问勾了的。QQ 音乐 / 网易云 / 酷狗 / 汽水音乐 / KKBOX
    /// 没有 AppleScript 字典,按 bundle id 直查系统的那条路(`NowPlayingClientsProbe`)也是 MediaRemote,跟着一起坏,
    /// 不在其列。纯函数,selftest 覆盖。
    /// 通道坏了时,勾选的播放器里有没有读不到的(勾了「自动识别」也算:它会遇到任何播放器)。`MediaChannelNotifier` 据此决定弹不弹通知。
    public static func channelOutageAffects(selected: Set<PlaybackPlayer>) -> Bool {
        selected.contains(.auto) || !selected.isSubset(of: Set(channelFallbackCandidates(selected: [.auto])))
    }

    public static func channelFallbackCandidates(selected: Set<PlaybackPlayer>) -> [PlaybackPlayer] {
        let order: [PlaybackPlayer] = [.appleMusic, .spotify, .kaset, .vox]
        if selected.contains(.auto) { return order }
        return order.filter(selected.contains)
    }

    /// media-control 通道坏了(`channelLooksBroken`)时,直接问还开着的 Apple Music / Spotify / Kaset / VOX:在放的优先,都没在放取
    /// 第一个暂停着的。没开着的不问(不 fork osascript,也不会对从不用它的人弹自动化授权)。
    ///
    /// `snapshotAfterFocusLost` 那条回退只在「上一份被接受的快照」存在时才走,通道一启动就坏的话开关永远点不亮,
    /// 播放器停一次也会关掉,这条补的是它。
    private static func snapshotWhileChannelBroken(players: Set<PlaybackPlayer>) -> MediaControlSnapshot? {
        appleMusicFocusLock.lock()
        let broken = channelLooksBroken(execFailures: channelExecFailures, testFailed: channelTestFailed)
        let wasActive = channelFallbackPlayer
        appleMusicFocusLock.unlock()
        guard broken else {
            if wasActive != nil {
                setChannelFallbackPlayer(nil)
                logger.notice("media-control channel usable again; back on media-control")
            }
            return nil
        }
        var paused: (PlaybackPlayer, MediaControlSnapshot)?
        var chosen: (PlaybackPlayer, MediaControlSnapshot)?
        for player in channelFallbackCandidates(selected: players) {
            guard runningPID(player.bundleIdentifier) != nil else { continue }
            let snapshot: MediaControlSnapshot?
            switch player {
            case .appleMusic: snapshot = fetchAppleMusicSnapshot()
            case .kaset: snapshot = fetchKasetSnapshot()
            case .vox:
                // 通道坏了拿不到系统那份,网络电台认不出在放哪一首,不报。
                snapshot = fetchVoxSnapshot().flatMap { VoxPlayerInfo.isRadioReading($0) ? nil : $0 }
            default: snapshot = fetchSpotifySnapshot()
            }
            guard let snapshot else { continue }
            if snapshot.playing == true {
                chosen = (player, snapshot)
                break
            }
            if paused == nil { paused = (player, snapshot) }
        }
        let picked = chosen ?? paused
        setChannelFallbackPlayer(picked?.0)
        guard let (player, snapshot) = picked else { return nil }
        if wasActive != player {
            let name = player.bundleIdentifier
            logger.notice("media-control channel broken; reading \(name, privacy: .public) via AppleScript")
        }
        return snapshot
    }

    private static func setChannelFallbackPlayer(_ value: PlaybackPlayer?) {
        appleMusicFocusLock.lock()
        channelFallbackPlayer = value
        appleMusicFocusLock.unlock()
    }

    private static func fetchAutoDetectedSnapshot() -> MediaControlSnapshot? {
        // 闸门 = 内置播放器 + 用户显式信任的未知播放器(见 TrustedPlayers)。准入只在这里判:
        // 引擎不复核,只记这里认下、写进播放状态的播放器。
        //
        // 三条 nil 出口都先过一次 `snapshotAfterFocusLost`:「系统 Now Playing 焦点被别的 App 占走」跟「真的没人在放歌」在这里
        // 长得一模一样,而前者下播放器往往还在放。理由与收敛性见那个函数的头注。
        guard let (snapshot, bundleID) = resolvingSpotifyConnectMirror(fetchRawMediaControlSnapshot()) else {
            // 失败原因已由 fetchRawMediaControlSnapshot 记下,别在这里覆盖掉。
            return snapshotAfterFocusLost() ?? snapshotWhileChannelBroken(players: [.auto])
        }
        guard TrustedPlayers.isAccepted(bundleID) else {
            setSnapshotFailure(.focusHeldByOtherApp)
            return snapshotAfterFocusLost()
        }
        // KKBOX / Amazon / 网易云在放播客:没在放音乐,不退回去问别家(见 playerContentNotMusic)。
        if playerContentNotMusic(bundleID: bundleID, snapshot: snapshot) { return nil }
        if artistNotYetReported(bundleID: bundleID, snapshot: snapshot) { return nil }
        // 信任的未知播放器再过一道"这是不是一首歌"的守卫:歌手名**或专辑名**为空的丢掉
        // (浏览器视频/播客)。见 TrustedPlayers.notASong。
        guard !trustedPlaybackRejected(bundleID: bundleID, snapshot: snapshot) else {
            setSnapshotFailure(.notASong)
            return snapshotAfterFocusLost()
        }
        noteAccepted(bundleID: bundleID)
        return adaptedSnapshot(
            bundleID: bundleID, mediaControl: snapshotWithProbedAlbum(snapshot))
    }

    /// 上游报的专辑名为空时,用 YouTube Music 探针**刚刚那次**读到的那个补上——
    /// YT Music 播一张专辑时,第一首不上送专辑名。判据是纯函数
    /// `YouTubeMusicAdProbe.albumPatch`(selftest 覆盖),这里只负责把它接上真实的探针缓存。
    ///
    /// **必须在 `trustedPlaybackRejected` 之后**调用,不能提前把专辑名补进去再过守卫:
    /// 那道守卫"album 为空"正是触发广告复核的唯一入口,先补上等于把广告检测整个绕过去
    /// (广告的 album 也是空的)。顺序反了不会报错,只会让广告悄悄进来。
    ///
    /// 只补内置播放器之外、走信任列表进来的那条路 —— 探针缓存本来也只在 YouTube Music
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
    /// 路径该用的那一个。
    ///
    /// 基础判据(artist 或 album 为空就丢)原样不动,复核作为外面一层加上去,只在一种情况下发生:基础判据要拒、而且唯一的理由是
    /// album 为空(artist 非空)。
    ///
    /// 这一层是为了让 YouTube Music 能被识别:它的 album 常常是空的(不是总是,见 `YouTubeMusicAdProbe` 头注),空的那些不复核
    /// 就永远进不来。不能简单免检 album,因为那一条同时也在挡广告:广告的 artist 是广告主频道名、非空(见 `YouTubeMusicAdProbe`
    /// 头注的两条真实样本)。
    ///
    /// 三条出口在 `YouTubeMusicAdProbe.gate` 里(纯函数、selftest 覆盖),这里只负责把它接上真实的探针缓存。
    ///
    /// 「判定是广告」放行,由 `LocalPlaybackSource.isCurrentTrackAdBreak` 标成广告驱动 UI(YT Music 的广告也像 Spotify 那样
    /// 显示「广告中」)。放行不会让广告被记录,理由见 `YouTubeMusicAdProbe.Gate.acceptAsAd` 的注释。
    private static func trustedPlaybackRejected(
        bundleID: String, snapshot: MediaControlSnapshot
    ) -> Bool {
        guard TrustedPlayers.notASong(
            bundleID: bundleID, artist: snapshot.artist, album: snapshot.album) else {
            return false
        }
        // Spotify 网页版广告必须在下面那道短路之前处理。它的字段形状是 `title="广告" artist="" album="" duration≈30s`(见
        // `SpotifyWebAdProbe` 头注那张对照表),artist 是空的,而下面那行 guard 会把歌手名为空的一律丢掉,页面复核根本轮不到:
        // 广告那 30 秒 App 手上一条播放数据都没有,菜单栏塌回小图标、灵动岛/悬浮窗一起消失,广告完了再弹回来。原生 Spotify
        // 客户端不受这道闸约束(内置播放器在 notASong 第一行就 return false)。
        if spotifyWebAdAccepted(bundleID: bundleID, snapshot: snapshot) { return false }
        guard !(snapshot.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        let key = YouTubeMusicAdProbe.trackKey(artist: snapshot.artist, title: snapshot.title)
        // 先踢一次(异步、不阻塞),再读缓存 —— 同步路径上绝不能等 AppleScript 往返,
        // 见 YouTubeMusicAdProbe 头注"异步 kick + 读缓存"那一节。
        // 带上标题和在不在放:只认页面上正放着这一首的 YouTube Music 标签页(02 章决策 150)。
        YouTubeMusicAdProbe.shared.kickIfNeeded(bundleIdentifier: bundleID, key: key,
                                                title: snapshot.title, playing: snapshot.playing != false)
        let verdict = YouTubeMusicAdProbe.shared.cachedVerdict(forKey: key)
        return YouTubeMusicAdProbe.gate(artist: snapshot.artist, verdict: verdict) == .reject
    }

    /// 「这条是不是一段 Spotify 网页版广告,该放行并标成广告?」
    ///
    /// 三道门,全过才放行。判据本体是两个纯函数(`fieldShapeNeedsProbe` / `gate`,selftest 覆盖),这里只负责把它们接上真实的
    /// 配对表和探针缓存:
    ///
    /// 1. 这个浏览器配对过 spotifyWeb。没配对就一个 AppleEvent 都不发:用户没说过"我拿这个浏览器听 Spotify",就不去 tell 它。
    /// 2. 字段形状是"标题非空 + 歌手为空"。这是 Spotify 网页广告的形状,也正是下面那道短路要丢掉的形状。这道门同时把 YT Music
    ///    那条探针的领地(artist 非空、album 空)挡在外面,不然配对了两个平台的浏览器每一轮会背两次 osascript 往返。
    /// 3. 页面自己说此刻在放广告(正向证据)。拿不准一律不放行:fail-closed 的方向是丢掉,不是在一首真歌上贴广告标签。
    ///
    /// 放行之后由 `LocalPlaybackSource.adBreakByFields` 读同一份探针缓存(`SpotifyWebAdProbe.cachedVerdict == .ad`)标成广告,
    /// 两处口径一致。别改成"配对过 spotifyWeb 就套原生那套 album 空 / artist 空 启发式":配对关系不等于此刻在放 Spotify(一个
    /// 浏览器可能两个平台都配了),YT Music 里没有专辑名的 MV 会整首被标成广告。见 02 章决策 25。
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

    // MARK: - 谁在放,就用谁的适配方式读

    /// media-control 在这一层只回答一件事:**现在是谁在放**。识别出来的播放器如果有自己的
    /// 适配方式,就走那条;不因为用户勾没勾「自动识别」而退回通用通路。
    ///
    /// 有自己 AppleScript 字典的三家 —— Apple Music、Spotify 与 Kaset —— 各走各的直问路径。QQ 音乐 /
    /// 网易云 / 酷狗 / 汽水音乐都没有字典(核实过:无 .sdef、未开 NSAppleScriptEnabled),继续走
    /// media-control,这里原样放行。
    ///
    /// 口径:**AppleScript 那份整份顶替**,只有 MediaRemote 独有的键留给 media-control。
    ///
    /// 别改回"只借 `elapsedTime`、且要跟 media-control 差 2 秒以内才肯借":media-control
    /// 的锚点整体偏掉 2 秒以上时,真值会被那道闸自己挡在门外,而伺服同时也看不见误差
    /// (reported 与 predicted 出自同一个坏锚点),整首歌锁死在错的位置上、一暂停才纠回来。
    ///
    /// 权限触发面:这条 osascript 只在**已经确认在播的就是它本人之后**才发 Apple Event,
    /// 不用这个播放器的人一次都碰不到,不会凭空多弹「自动化」权限框。
    ///
    /// 有些没有本地文件的 Apple Music 曲目,脚本读得到播到哪了,读不到这首歌有多长。
    /// 拿不到时长就不会开始计时,悬浮歌词会一直停在 ♪。
    /// 时长缺了、并且两边是同一首歌时,用 media-control 报的时长补上。
    /// 播到哪了仍用脚本读到的。上面说的「不要改用 media-control 的进度」仍然成立,这里补的只是时长。
    public static func fillingMissingAppleDuration(
        _ apple: MediaControlSnapshot, from donor: MediaControlSnapshot?
    ) -> MediaControlSnapshot {
        if let duration = apple.duration, duration > 0 { return apple }
        guard let donor,
              donor.bundleIdentifier == PlaybackPlayer.appleMusic.bundleIdentifier,
              let duration = donor.duration, duration > 0,
              let title = apple.title, !title.isEmpty,
              apple.trackKey == donor.trackKey
        else { return apple }
        return apple.withDuration(duration)
    }

    private static func adaptedSnapshot(
        bundleID: String, mediaControl: MediaControlSnapshot
    ) -> MediaControlSnapshot? {
        // 电台的适配方式**就是** media-control 的台标识 + RadioTrackClock 单曲表:
        // `player position` 在电台上报的同样是整档节目的位置,借过来会把
        // fetchRawMediaControlSnapshot 刚换好的那块单曲表覆盖回错的值。见 RadioTrackClock 头注。
        // 例外是「系统报单曲位置」的台(RadioTrackClock.State.perTrack):那种台 player position 就是这首的
        // 真值,跟普通曲目一样整份顶替,只把电台标记带过去。
        let perTrackRadio = mediaControl.isRadio == true && radioTrackIsPerTrack(mediaControl.trackKey)
        guard mediaControl.isRadio != true || perTrackRadio else { return mediaControl }
        // 拿不到(没授「自动化」权限 / 播放器不可达 / 超时)一律退回 media-control 这份,不整个放弃。
        switch bundleID {
        case PlaybackPlayer.appleMusic.bundleIdentifier:
            noteAppleMusicSystemDuration(trackKey: mediaControl.trackKey, duration: mediaControl.duration,
                                         isRadio: mediaControl.isRadio == true)
            // 暂停态不问:Apple Music 暂停时会重新发布一次 elapsedTime,那个值**就是**暂停位置
            // (见 livePositionSeconds 里的同一条),多 fork 一个 osascript 换不到任何精度。
            guard mediaControl.playing == true else { return mediaControl }
            guard let apple = settledAppleMusicSnapshot() else { return mediaControl }
            let timed = fillingMissingAppleDuration(apple, from: mediaControl)
            return perTrackRadio ? timed.markedRadio() : timed
        case PlaybackPlayer.spotify.bundleIdentifier:
            // 这里跟 Apple Music **不一样**:暂停态也问。Spotify 的两个钟不重合 ——
            // MediaRemote 那个冻结值是音频位置,`player position` 是它自己的钟,两者差一段输出
            // 链路的领先量。播放中显示后者、暂停那一拍换成前者,就是一次肉眼可见的回跳;从头到尾
            // 只用一个钟才没有接缝。
            let asked = Date()
            if let spotify = fetchSpotifySnapshot() { return spotify }
            let now = Date()
            if let fromNotice = spotifyNoticeReading(mediaControl, notice: currentSpotifyNotice(),
                                                     sampledAt: asked, now: now) {
                return fromNotice
            }
            return spotifyFallbackCaughtUp(mediaControl, waited: now.timeIntervalSince(asked), now: now)
        case PlaybackPlayer.kaset.bundleIdentifier:
            // 跟 Spotify 一样暂停态也问:系统那份连歌名都可能是上一首的(见 KasetPlayerInfo 头注)。它此刻放的不是一首歌
            // (占位、播客单集)时也不退回去报系统那份,那份就是它自己发的同一条。
            if let kaset = fetchKasetSnapshot() { return kaset }
            return kasetNotSongThisRoundValue() ? nil : mediaControl
        case PlaybackPlayer.vox.bundleIdentifier:
            // 暂停态也问:系统那份播放中不报位置,暂停时报的那一次比脚本冻结的值少 0.1 秒,换钟就是一次回跳。
            // 拿不到时退回系统那份:按 VOX 开着的文件认这一首、拆开歌手和专辑(见 VoxPlayerInfo.systemFallback)。
            // 放网络电台时脚本只有台名,这一首取系统那份的 ICY 标题;取不到就是这一拍没有歌,不退回台名。
            guard let vox = fetchVoxSnapshot() else { return VoxPlayerInfo.systemFallback(mediaControl) }
            guard VoxPlayerInfo.isRadioReading(vox) else { return vox }
            if let radio = VoxPlayerInfo.radioSnapshot(
                station: vox, system: mediaControl, now: Date(),
                observedAt: lastTrackChangeObserved(forKey: mediaControl.trackKey)) { return radio }
            setSnapshotFailure(.targetNotPlayingMusic)
            return nil
        default:
            return mediaControl
        }
    }

    // 封面图——跟 fetchSnapshot()/fetchRawMediaControlSnapshot() 完全独立的一条轻量
    // 取图路径,只在换歌那一刻调一次(见 LocalPlaybackSource.apply()/
    // fetchArtworkForCurrentTrack()),不掺进每 2 秒一次的常规轮询,避免每次都解码几百
    // KB 的 base64 图片数据。这里刻意统一走 media-control——不管当前选的是哪个播放器,
    // 包括 Apple Music:实测(`media-control get --now`,不带 --no-artwork)对 Apple
    // Music 的系统级 Now Playing 会话同样能读到 artworkData 字段,不需要另外给 Apple Music
    // 走 AppleScript 的 track.artworks() 去拿封面(那条路要把二进制图片数据想办法序列化过
    // JSON,明显更麻烦)。
    // trackKey:这份封面在 get --now 载荷里对应的曲目标识(跟 MediaControlSnapshot.trackKey
    // 同一套推导)。切歌瞬间系统侧 Now Playing 可能还没更新完,这一把抓到的会是**上一首**的
    // 完整条目(旧标题+旧封面)——载荷自己的 artist/title 是识别这种情况的唯一依据,调用方
    // 拿它跟当前曲目比对,不匹配就当"还没更新好"重试,而不是把上一首的封面错挂到新歌上
    // (网易云云盘歌会出现"沿用上一首的封面"这种情况)。
    public static func fetchArtwork(players: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected) -> (data: Data, mimeType: String, trackKey: String)? {
        fetchArtworkExplained(players: players).artwork
    }

    /// 同 `fetchArtwork`,取不到时另外交回一句为什么(英文,进日志;见 `LocalPlaybackSource.artworkMissDescription`)。
    public static func fetchArtworkExplained(players: Set<PlaybackPlayer> = PlaybackPlayerPreference.selected)
        -> (artwork: (data: Data, mimeType: String, trackKey: String)?, miss: String?) {
        // 焦点被别的 App 占走时,封面必须跟快照走**同一条路**。`media-control get --now` 问的是
        // 系统级焦点,这时候它给的是**占用者**那张图(浏览器视频的缩略图)——下游那道 trackKey 守卫
        // 会如实拦下来丢弃,于是歌还在、歌词还在,唯独封面没了。两边不对称就会长这样。
        var prefix = ""
        // media-control 通道坏了、屏上这首是从 VOX 脚本读来的:系统那份拿不到,直接走 VOX 自己的退路。
        appleMusicFocusLock.lock()
        let channelFallback = channelFallbackPlayer
        appleMusicFocusLock.unlock()
        if channelFallback == .vox, let art = voxArtwork(tryingFolder: true) { return (art, nil) }
        if let target = activeFocusFallbackTarget() {
            if !SourceKnockout.isOut(.systemArtwork),
               let art = NowPlayingClientsProbe.artwork(forBundleID: target.bundleID) { return (art, nil) }
            if target.bundleID == VoxPlayerInfo.bundleID, let art = voxArtwork(tryingFolder: true) { return (art, nil) }
            prefix = "focus is held elsewhere and \(target.bundleID) gave no artwork; "
        }
        guard let binaryPath = binaryPath() else { return (nil, prefix + "media-control is not bundled") }
        // 这次不传 --no-artwork——就是为了要这份数据,所以超时给得比状态查询宽:
        // 封面 base64 有几百 KB。先问取封面的常驻进程,用不上再起子进程。
        guard let r = artworkServer.request("now", timeout: artworkTimeout)
                ?? ProcessRunner.run(binaryPath, ["get", "--now"], timeout: artworkTimeout),
            r.succeeded
        else { return (nil, prefix + "media-control get --now failed") }
        guard let raw = try? JSONDecoder().decode(ArtworkPayload.self, from: r.stdout) else {
            return (nil, prefix + "the system reports nothing")
        }
        guard let bundleID = raw.bundleIdentifier.map(PlayerBundleAliases.canonical), artworkBundleIDMatches(bundleID, players: players) else {
            return (nil, prefix + "the system reports \(raw.bundleIdentifier ?? "no player"), which is not accepted")
        }
        // VOX 这份载荷的歌手是「歌手 — 专辑」、没写标签时歌名是小写文件名:换成跟快照同一份再算曲目标识(见 VoxPlayerInfo)。
        var keyTitle = raw.title, keyArtist = raw.artist
        var filePath = PlayerTitleSplit.currentFilePath(bundleID: bundleID, title: raw.title)
            ?? PlayerOpenFile.currentFilePath(bundleID: bundleID, rawArtist: raw.artist, rawTitle: raw.title)
        if bundleID == VoxPlayerInfo.bundleID {
            (keyTitle, keyArtist, filePath) = VoxPlayerInfo.artworkIdentity(title: raw.title, artist: raw.artist)
        } else if bundleID == PinePlayerInfo.bundleID {
            (keyTitle, keyArtist, filePath) = PinePlayerInfo.artworkIdentity(title: raw.title, artist: raw.artist)
        }
        guard !SourceKnockout.isOut(.systemArtwork), let imageData = artworkImageData(base64: raw.artworkData) else {
            // 放本地文件的播放器(reAMP、VOX,放本机文件的 QQ 音乐、网易云、酷狗)只报文件里嵌着的封面:没嵌的改用正在放的文件
            // 同目录里的那张(见 PlayerTitleSplit)。
            if let path = filePath, let cover = PlayerTitleSplit.folderCover(forAudioFile: path) {
                return ((cover.data, cover.mimeType,
                         PlayerArtistFix.correctedTrackKey(bundle: bundleID, artist: keyArtist, title: keyTitle)), nil)
            }
            if bundleID == VoxPlayerInfo.bundleID, let art = voxArtwork(tryingFolder: false) { return (art, nil) }
            let artwork = raw.artworkData.map { "with artwork that is not an image (\(Data(base64Encoded: $0)?.count ?? 0) bytes)" }
                ?? "without artwork"
            return (nil, prefix + "\(bundleID) reports \(raw.title ?? "") \(artwork)")
        }
        // Pine Player 文件没有封面时推的是它自己的图标(登记在 KnownPlaceholderArtwork):先找正在放的文件同目录的图。
        if bundleID == PinePlayerInfo.bundleID, KnownPlaceholderArtwork.isPlaceholder(imageData),
           let path = filePath, let cover = PlayerTitleSplit.folderCover(forAudioFile: path) {
            return ((cover.data, cover.mimeType,
                     PlayerArtistFix.correctedTrackKey(bundle: bundleID, artist: keyArtist, title: keyTitle)), nil)
        }
        return ((imageData, raw.artworkMimeType ?? "image/jpeg",
                 PlayerArtistFix.correctedTrackKey(bundle: bundleID, artist: keyArtist, title: keyTitle)), nil)
    }

    /// 按 bundle id 单问到的 Pine 那份(焦点被别的 App 占着时):位置过主路径同一块表(`PinePlayhead`);曲目在公开出口换
    /// (`PinePlayerInfo.adapted`)。单问那份没有原始锚点时原样交回。
    private static func pineProbedSnapshot(_ probed: MediaControlSnapshot, anchor: NowPlayingClientsProbe.SessionAnchor,
                                           now: Date) -> MediaControlSnapshot {
        var snapshot = probed
        if snapshot.processIdentifier == nil { snapshot.processIdentifier = anchor.processIdentifier.map { Int($0) } }
        if let reading = PinePlayhead.reading(
            track: probed.trackKey, playing: probed.playing == true, anchorElapsed: probed.anchorElapsedTime,
            anchorAt: anchor.timestamp.map { Date(timeIntervalSince1970: $0) }, duration: probed.duration,
            pid: snapshot.processIdentifier, now: now) {
            let pid = snapshot.processIdentifier
            snapshot = reading.waiting
                ? snapshot.withLXMusicClock(position: reading.position, playing: true, rate: 1, waiting: true)
                : snapshot.withPlayerClock(reading.position, capturedAt: now)
            snapshot.processIdentifier = pid
            if reading.precise { snapshot.positionIsPrecise = true }
            snapshot.republishDueBy = reading.dueBy
        }
        return snapshot
    }

    /// VOX 这首的封面,系统那份给不了时:先问它的脚本要它显示的那张,再找正在放的文件同目录的图(`tryingFolder`)。
    /// 曲目标识按记下的这首算,跟快照对得上。
    private static func voxArtwork(tryingFolder: Bool) -> (data: Data, mimeType: String, trackKey: String)? {
        guard let entry = VoxPlayerInfo.currentEntry(), !entry.title.isEmpty else { return nil }
        let key = PlayerArtistFix.correctedTrackKey(bundle: VoxPlayerInfo.bundleID, artist: entry.artist, title: entry.title)
        if let jpeg = VoxPlayerInfo.scriptArtwork(for: (entry.title, entry.path)) { return (jpeg, "image/jpeg", key) }
        if tryingFolder, let path = entry.path, let cover = PlayerTitleSplit.folderCover(forAudioFile: path) {
            return (cover.data, cover.mimeType, key)
        }
        return nil
    }

    /// 载荷里的 `artworkData`(base64)解出来的图;没带、解不开、读不出图头(`CoverArtReplacementGate.isImage`)都是 nil。
    /// 空字符串解出来是 0 字节而不是 nil,只判 nil 会把这首当成有封面定案,见 03 章决策 46。nowplaying-clients 那条同用。
    public static func artworkImageData(base64: String?) -> Data? {
        guard let base64, let data = Data(base64Encoded: base64), CoverArtReplacementGate.isImage(data) else { return nil }
        return data
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
    // fetchMultiSelectedSnapshot 一样。
    private static func artworkBundleIDMatches(_ bundleID: String, players: Set<PlaybackPlayer>) -> Bool {
        if players.contains(.auto) {
            return TrustedPlayers.isAccepted(bundleID)
        }
        if players.contains(where: { $0.bundleIdentifier == bundleID }) { return true }
        // 补:信任列表(网页播放器配对)在没有勾自动识别时也该被认,跟
        // fetchMultiSelectedSnapshot 是同一份判断,理由见那边的注释。
        return TrustedPlayers.isTrusted(bundleID)
    }


    /// 锚点"陈旧"的判定门槛:now − timestamp 超过这个值,就说明这一份读数的锚点不是
    /// 刚发布的。会刷新锚点的源在报告暂停那一刻必然带一个新鲜时间戳(暂停本身就是事件),
    /// 所以 2 秒(一个轮询周期)足够把两类源分开。
    public nonisolated static let staleAnchorAfter: TimeInterval = 2.0
    /// 报告值比"播放中最后一次算出来的位置"低这么多以上,才判定它不是暂停位置。
    /// 3 秒 > 一个轮询周期,正常暂停时两者只差一拍(≤2s),不会误判。
    public nonisolated static let frozenAnchorPauseDrop: Double = 3.0

    /// 从被截成整秒的锚点时间戳,恢复一个更接近真实锚点时刻的估计。带 `--micros` 拿到的是精确时刻,原样返回;整秒格式才要估。
    ///
    /// 整秒时间戳是 `ts = floor(真实时刻)`,于是 `位置 + (now − ts)` 恒偏快 frac 秒(用 Apple Music 的 AppleScript 播放头当独立
    /// 真值,12 个样本:+0.824s,极差只有 0.042s)。锚点每刷新一次这个 frac 重新掷骰;锚点冻结的源(网页播放器/酷狗)一次掷骰
    /// 锁死一整首歌。
    ///
    /// 恢复办法是夹逼,真实时刻 τ 有三个界:
    ///   - `ts ≤ τ`         (floor 语义)
    ///   - `τ < ts + 1`     (frac < 1)
    ///   - `τ ≤ 首见时刻`    (不可能在它发布之前看到它)
    /// 取 `[ts, min(ts+1, 首见时刻)]` 的中点,不会比直接用 ts 更差:
    ///   - 事件流即时发现(首见 − ts 很小)→ 误差 ≤ 那个间隔的一半,很小;
    ///   - 只靠 2 秒轮询发现(间隔 ≥ 1)→ 退化成 `ts + 0.5`,最坏 ±0.5s,是直接用 ts 的 [0,1) 的一半。
    ///
    /// 纯函数,selftest 直接覆盖。
    public nonisolated static func estimatedAnchorInstant(timestamp: Date, firstSeenAt: Date) -> Date {
        // 带 `--micros` 拿到的是精确锚点时刻,没有被抹掉的小数可估,原样返回(见 MediaControlMicros)。
        guard !MediaControlMicros.isPrecise(timestamp) else { return timestamp }
        let observedGap = firstSeenAt.timeIntervalSince(timestamp)
        // 首见时刻早于时间戳(时钟回拨/解析异常)→ 不猜,原样返回。
        guard observedGap > 0 else { return timestamp }
        return timestamp.addingTimeInterval(min(1.0, observedGap) / 2)
    }

    /// 一次「看见这个锚点」的记录。`tight`=来自 stream 事件到达时刻(上界紧,锚点打好后几十毫秒
    /// 就到);false=来自轮询首见,可能晚到 2s,只能取中点。见 anchorSightings 注释。
    public struct AnchorSighting: Sendable, Equatable {
        public let at: Date
        public let tight: Bool
        public init(at: Date, tight: Bool) {
            self.at = at
            self.tight = tight
        }
    }

    /// stream 事件在锚点打好之后到达的典型延迟。实测:Spotify 的
    /// `com.spotify.client.PlaybackStateChanged` 通知带着它自己那一刻的位置,能反推锚点真实
    /// 时刻;stream 事件比通知晚到 17/17/20/26ms(4 次)。
    public nonisolated static let streamAnchorLatency: TimeInterval = 0.025
    /// tight 目击对锚点年龄的上限:事件到达时锚点的整秒时间戳已经比这更老,说明这不是"刚打好
    /// 被看到",而是 watcher 刚(重)启、media-control 把当前**旧**锚点整份吐了一遍 —— 只能算 loose。
    public nonisolated static let tightSightingMaxAge: TimeInterval = 1.5

    /// 带目击类型的锚点时刻估计。tight → 到达时刻回退一个典型延迟,再夹进 [ts, ts+1)(floor
    /// 语义 + frac<1,两条界跟上面一样);loose → 退回上面的中点法。
    ///
    /// 为什么值得多这一档(实测,Spotify 暂停后恢复播放):恢复那一刻 Spotify 重打
    /// 锚点且 playbackRate 变 null,media-control 的 elapsedTimeNow 从此不再外推,App 只能自己
    /// 按整秒时间戳补算,抹掉的小数(实测 .914/.724/.560)就是那首歌余下部分偏快的量;一按暂停
    /// (冻结值是准的)显示就退回去 0.95/0.73s。中点法把它压到 ±0.5,tight 目击压到 ±20ms。
    /// 纯函数,selftest 直接覆盖。
    public nonisolated static func estimatedAnchorInstant(timestamp: Date, sighting: AnchorSighting) -> Date {
        guard !MediaControlMicros.isPrecise(timestamp) else { return timestamp }
        guard sighting.tight else { return estimatedAnchorInstant(timestamp: timestamp, firstSeenAt: sighting.at) }
        let guess = sighting.at.timeIntervalSince(timestamp) - streamAnchorLatency
        return timestamp.addingTimeInterval(min(max(guess, 0), 0.999))
    }

    /// 暂停时该报哪个位置。纯函数,selftest 直接覆盖。
    ///
    /// Arc 这类网页播放器(页面没调 `mediaSession.setPositionState()`)的锚点是**冻结**的:实测
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
    /// 都不成立就沿用原样的 elapsedTime。
    public nonisolated static func pausedPositionSeconds(
        elapsedTime: Double?, anchorAge: TimeInterval?, lastPlayingPosition: Double?
    ) -> Double? {
        guard let last = lastPlayingPosition else { return elapsedTime }
        guard let reported = elapsedTime else { return last }
        guard let age = anchorAge, age > staleAnchorAfter else { return reported }
        return (last - reported) > frozenAnchorPauseDrop ? last : reported
    }

    /// 暂停锚点与暂停事件时刻最多差这么多,才算"这个锚点是暂停时发布的"。时间戳只有整秒,再加
    /// 事件到达的几十毫秒,1.5s 足够宽,又远小于一个 2s 轮询周期。
    public nonisolated static let pauseAnchorMaxSkew: TimeInterval = 1.5

    /// 暂停时该报哪个位置 —— 带暂停事件时刻的版本。纯函数,selftest 直接覆盖。
    ///
    /// 通过 MediaRemote 指令暂停(App 自己的暂停键 / media-control pause / 媒体键)时,Spotify 不重新发布 elapsedTime,事件流里
    /// 只有 `playing:false`,原始 elapsedTime 仍是开播那个锚点(0@开播)。只看锚点年龄的那版这时退回"上一拍轮询记住的播放位置",
    /// 最多旧一个轮询周期,暂停瞬间显示会往回退。在 Spotify 自己界面里按暂停它会发布冻结值(带新时间戳),那时冻结值是对的。
    ///
    /// 规则(有暂停事件时刻 `pauseObservedAt`,且它落在上一拍之后、现在之前):
    ///  - 锚点时间戳比暂停事件早 `pauseAnchorMaxSkew` 以上 → 锚点早于暂停,冻结值不可信,把上一拍的位置按 rate=1 外推到暂停那一刻;
    ///  - 否则锚点就是暂停时发布的 → 原样用冻结值。
    /// 没有事件时刻(watcher 挂了 / 事件比轮询晚)→ 退回只看锚点年龄的那版。
    public nonisolated static func pausedPositionSeconds(
        elapsedTime: Double?, anchorTimestamp: Date?,
        lastPlaying: (position: Double, sampledAt: Date)?, pauseObservedAt: Date?, now: Date
    ) -> Double? {
        guard let lastPlaying else { return elapsedTime }
        guard let reported = elapsedTime else { return lastPlaying.position }
        if let pauseAt = pauseObservedAt,
           pauseAt >= lastPlaying.sampledAt.addingTimeInterval(-0.5), pauseAt <= now.addingTimeInterval(0.5) {
            if let anchorTimestamp, pauseAt.timeIntervalSince(anchorTimestamp) > pauseAnchorMaxSkew {
                return lastPlaying.position + max(0, pauseAt.timeIntervalSince(lastPlaying.sampledAt))
            }
            return reported
        }
        return pausedPositionSeconds(
            elapsedTime: reported,
            anchorAge: anchorTimestamp.map { now.timeIntervalSince($0) },
            lastPlayingPosition: lastPlaying.position)
    }

    /// 从 media-control 的原始字段推出"当前播放位置"(秒)。纯函数,selftest 直接覆盖。
    ///
    /// rate 正常(>0)时用 media-control 自己的 elapsedTimeNow(它按全精度锚点时刻外推)。rate 缺失或为 0 时那个外推的增量就是 0、
    /// elapsedTimeNow 一动不动(Spotify 暂停后恢复播放,上报的 playbackRate 变成 null 且不再回来);这个恒定值喂进
    /// LocalPlaybackSource 的伺服,会被每拍当成回跳往回拽、把位置钉死。这时按 rate=1 自己补算,锚点时刻走
    /// estimatedAnchorInstant(timestamp:sighting:)。见 02 章「Spotify 恢复播放后的锚点相位:整秒时间戳与 stream 目击」。
    ///
    /// lastPlayingPosition:同一首曲目播放期间最后一次算出来的位置。只有暂停分支会用到(见 pausedPositionSeconds);
    /// 默认 nil = 调用方没有这个信息。
    public nonisolated static func livePositionSeconds(
        playing: Bool?, elapsedTime: Double?, elapsedTimeNow: Double?,
        playbackRate: Double?, timestamp: Date?, now: Date,
        lastPlayingPosition: Double? = nil,
        firstSeenAt: Date? = nil,
        sighting: AnchorSighting? = nil,
        republishedAnchorInstant: Date? = nil,
        lastPlayingSampledAt: Date? = nil,
        pauseObservedAt: Date? = nil,
        playbackStartedAt: Date? = nil
    ) -> Double? {
        // firstSeenAt 只记轮询首见(loose 语义),sighting 带目击类型;同传时以 sighting 为准。
        let effectiveSighting = sighting ?? firstSeenAt.map { AnchorSighting(at: $0, tight: false) }
        // 暂停态不外推:elapsedTimeNow 在暂停期间**照样**按暂停前的 rate 继续涨(拿到过
        // 远超曲长的荒谬值),因为暂停本身没让 media-control 的外推基准归零。
        //
        // 但"暂停时用原始 elapsedTime"这个假设**只对会刷新锚点的源成立**(QQ/网易云/
        // Apple Music:它们暂停时会重新发布一次 elapsedTime,那个值就是暂停位置)。
        // 锚点冻结的源不成立 —— 见 pausedPositionSeconds。
        guard playing == true else {
            // 有"上一拍是哪一刻算的"就走能外推到暂停时刻的那版;没有就走只看锚点年龄的那版。
            if let lastPlayingPosition, let lastPlayingSampledAt {
                return pausedPositionSeconds(
                    elapsedTime: elapsedTime, anchorTimestamp: timestamp,
                    lastPlaying: (lastPlayingPosition, lastPlayingSampledAt),
                    pauseObservedAt: pauseObservedAt, now: now)
            }
            return pausedPositionSeconds(
                elapsedTime: elapsedTime,
                anchorAge: timestamp.map { now.timeIntervalSince($0) },
                lastPlayingPosition: lastPlayingPosition)
        }
        // 陈旧锚点重发(见 isStaleAnchorRepublish 一带):新时间戳是假的,elapsedTimeNow 也是按
        // 假时间戳外推的,一律按原锚点时刻自己外推。rate 缺失/为 0 按 1 计,跟下面一致。
        if let republishedAnchorInstant, let base = elapsedTime {
            let rate = (playbackRate ?? 0) > 0 ? (playbackRate ?? 1) : 1
            let aged = now.timeIntervalSince(republishedAnchorInstant)
            return aged > 0 ? base + aged * rate : base
        }
        // 锚点已经冻结(不再刷新,Spotify 一首歌内就是单锚点)时,按订正后的锚点时刻自己外推:整秒格式的时间戳要经
        // estimatedAnchorInstant 估回被抹掉的小数,暂停中发布的锚点要从真正起播那一刻算(playbackStartedAt,见
        // notePlaybackStarted)。每拍都在刷新锚点的源(QQ/网易云)走不到这里,那条路径的参数按实测调过(见 noisyFloored
        // 那一档的注释)。
        if let rate = playbackRate, rate > 0, let base = elapsedTime, let timestamp,
           let effectiveSighting, now.timeIntervalSince(timestamp) > staleAnchorAfter {
            let corrected = laterInstant(estimatedAnchorInstant(timestamp: timestamp, sighting: effectiveSighting),
                                         playbackStartedAt)
            let aged = now.timeIntervalSince(corrected)
            if aged > 0 { return base + aged * rate }
        }
        // rate 正常时信 media-control 自己的外推(更准)。
        if let rate = playbackRate, rate > 0, let now = elapsedTimeNow { return now }
        // rate 缺失/为 0:elapsedTimeNow 已经退化成 elapsedTime,自己按 rate=1 补算。Spotify 暂停后恢复播放走的就是这条分支,
        // 且锚点一首歌内不再刷新;锚点时刻有目击就按目击订正(见 estimatedAnchorInstant(timestamp:sighting:)),没有(watcher 挂了、
        // 调用方不传)才用 timestamp 本身。
        guard let base = elapsedTime, let timestamp else { return elapsedTimeNow ?? elapsedTime }
        // 暂停中发布的锚点(见 notePlaybackStarted)从真正起播那一刻算,不从发布那一刻算。
        let anchorInstant = laterInstant(
            effectiveSighting.map { estimatedAnchorInstant(timestamp: timestamp, sighting: $0) } ?? timestamp,
            playbackStartedAt)
        let aged = now.timeIntervalSince(anchorInstant)
        // 负数(时钟回拨/时区解析出错)时不倒推,老老实实用基准值。
        return aged > 0 ? base + aged : base
    }

    private nonisolated static func laterInstant(_ a: Date, _ b: Date?) -> Date {
        guard let b, b > a else { return a }
        return b
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 整秒 ISO8601 时间戳(形如 "…T08:51:46Z")的 formatter;带小数秒的由 timestampFormatter 解,带小数秒的 formatOptions
    /// 解不了不带的。两份都 static 复用,不在每次解析时现建。带 `--micros` 的 `@<epoch 微秒>` 由 MediaControlMicros 解,
    /// 见 parseTimestamp。
    private nonisolated static let plainTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public nonisolated static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = MediaControlMicros.date(fromTimestampString: s) { return d }
        if let d = plainTimestampFormatter.date(from: s) { return d }
        return timestampFormatter.date(from: s)
    }

    /// 此刻系统级 Now Playing 是谁在报 —— **没过任何闸**的原始观察。
    ///
    /// 存在的唯一用途是设置页那张「检测到未知播放器」的卡片:过了闸的播放器本来就能在
    /// 界面上看见,被闸挡掉的那些才需要提示"要不要信任它"。
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
    // 走到),跟旁边 playingAnchorLock / ungatedLock 同一套既有做法。
    private static let playingPositionLock = NSLock()
    nonisolated(unsafe) private static var playingPositionTrack: String?
    nonisolated(unsafe) private static var playingPositionValue: Double?
    /// 那次播放位置是哪一拍算出来的 —— 暂停分支要把它外推到暂停那一刻(见 pausedPositionSeconds
    /// 带 pauseObservedAt 的那版),不外推就是"最多旧一个轮询周期"的陈旧值。
    nonisolated(unsafe) private static var playingPositionSampledAt: Date?
    /// stream watcher 看到 `playing:false` 的到达时刻 = 暂停发生的时刻(±20ms)。
    nonisolated(unsafe) private static var pauseObservedAt: Date?

    /// stream watcher 报告「刚看到播放器进入暂停」。
    nonisolated static func notePauseObserved(at: Date) {
        playingPositionLock.lock()
        pauseObservedAt = at
        playingPositionLock.unlock()
    }

    private nonisolated static func lastPauseObservedAt() -> Date? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        return pauseObservedAt
    }

    /// stream watcher 看到曲目变成了哪一首、发生在哪一刻。只有电台那块曲内表用它起表
    /// (见 RadioTrackClock 头注「起表时刻」一节)。按曲目 key 记:轮询那一拍要核对
    /// "这个时刻是不是这一首的",不然会拿上一首留下的时刻去播种。
    nonisolated(unsafe) private static var trackChangeKey: String?
    nonisolated(unsafe) private static var trackChangeAt: Date?

    nonisolated static func noteTrackChangeObserved(key: String, at: Date) {
        playingPositionLock.lock()
        trackChangeKey = key
        trackChangeAt = at
        playingPositionLock.unlock()
    }

    private nonisolated static func lastTrackChangeObserved(forKey key: String) -> Date? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        guard trackChangeKey == key else { return nil }
        return trackChangeAt
    }

    /// stream watcher 最近一次看到曲名变了:哪个播放器、从哪个曲名换走、发生在哪一刻。只给
    /// `settledAppleMusicSnapshot` 判 AppleScript 是不是还没换过来。
    public struct StreamTitleChange: Equatable, Sendable {
        public let bundleID: String
        public let fromTitle: String
        public let at: Date

        public init(bundleID: String, fromTitle: String, at: Date) {
            self.bundleID = bundleID
            self.fromTitle = fromTitle
            self.at = at
        }
    }

    nonisolated(unsafe) private static var titleChange: StreamTitleChange?

    /// 只换了歌手、曲名没变的那次换曲把上一条作废(这时没有「旧曲名」可比);从空标题换过来的(watcher 刚起来整份吐一遍)不记。
    nonisolated static func noteTitleChangeObserved(bundleID: String?, fromTitle: String?, toTitle: String?, at: Date) {
        var change: StreamTitleChange?
        if let bundleID, let fromTitle, !fromTitle.isEmpty, let toTitle, toTitle != fromTitle {
            change = StreamTitleChange(bundleID: bundleID, fromTitle: fromTitle, at: at)
        }
        playingPositionLock.lock()
        titleChange = change
        playingPositionLock.unlock()
    }

    private nonisolated static func currentTitleChange() -> StreamTitleChange? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        return titleChange
    }

    private nonisolated static func rememberedPlayingSampledAt(forTrack track: String) -> Date? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        guard playingPositionTrack == track else { return nil }
        return playingPositionSampledAt
    }

    // 「这个锚点我们第一次看到是什么时候」—— estimatedAnchorInstant 的第三个界。
    // 锚点身份 = 曲目 + elapsedTime + timestamp 三者拼起来(anchorKey(...);轮询路径与
    // MediaControlStreamWatcher 必须用同一个构造,否则两边记的是两把不同的 key,永远对不上)。
    //
    // 两种目击(AnchorSighting,拆开):
    //  - tight:来自 stream 事件的到达时刻。锚点打好后 ~15-40ms 事件就到(实测见
    //    streamAnchorLatency),真实锚点时刻能夹到 ±20ms;
    //  - loose:来自轮询首见。轮询可能晚到 2s(通知触发也要 ~0.4s),只能取 [ts, 首见] 中点。
    // 同一把 key 只留**最早**的一次目击,tight 恒优先于 loose。用字典而不是单槽:锚点是单调
    // 更替的,但 stream 与轮询看到同一批锚点的顺序可能交错(Apple Music 的事件也走这条流),
    // 单槽会被后来者顶掉。封顶 16 条按时间淘汰。
    private static let anchorSeenLock = NSLock()
    nonisolated(unsafe) private static var anchorSightings: [String: AnchorSighting] = [:]
    private static let anchorSightingCapacity = 16

    /// 返回这个锚点的**最早**一次目击;第一次见到就把 now 记成一次 loose 目击并返回它。
    private nonisolated static func firstSeen(anchorKey: String, now: Date) -> AnchorSighting {
        anchorSeenLock.lock()
        defer { anchorSeenLock.unlock() }
        if let existing = anchorSightings[anchorKey] { return existing }
        let sighting = AnchorSighting(at: now, tight: false)
        anchorSightings[anchorKey] = sighting
        pruneAnchorSightingsLocked()
        return sighting
    }

    /// stream watcher 报告「看到了一个锚点」。tight 覆盖已有的 loose(轮询可能抢先看到同一个
    /// 锚点);同类之间取更早的那次。
    nonisolated static func noteStreamAnchorSighting(anchorKey: String, at: Date, tight: Bool) {
        anchorSeenLock.lock()
        defer { anchorSeenLock.unlock() }
        if let existing = anchorSightings[anchorKey] {
            if existing.tight {
                guard tight, at < existing.at else { return }
            } else {
                guard tight || at < existing.at else { return }
            }
        }
        anchorSightings[anchorKey] = AnchorSighting(at: at, tight: tight)
        pruneAnchorSightingsLocked()
    }

    // ---- 报 playing:false 却还在播的播放器 ----
    //
    // 酷狗单曲循环回到开头时发一份新锚点 `elapsed=0`,`playing` 却是 false、`playbackRate` 仍是 1,
    // 之后整遍都不再翻回 true;真暂停时 rate 归 0(跟 `playing:false` 同一瞬间到,相隔 ≤3ms)。
    // 只对 `playingFromRate` 的播放器按 rate 判,数据见 02 章「酷狗单曲循环报暂停」。

    /// 按锚点外推超过曲长多少还当它在播。循环每一遍都会重发锚点,超出曲长还没新锚点就是停了。
    public nonisolated static let rateOnlyPlayingOverrunSecs: TimeInterval = 2

    /// 这一份读数算不算在播。纯函数,selftest 直接覆盖。
    public nonisolated static func effectivePlaying(
        bundleID: String?, playing: Bool?, playbackRate: Double?,
        elapsedTime: Double?, timestamp: Date?, duration: Double?, now: Date
    ) -> Bool? {
        guard playing != true,
              PlaybackPlayer.builtin(forBundleID: bundleID)?.playingFromRate == true,
              let rate = playbackRate, rate > 0,
              let elapsed = elapsedTime, let timestamp, let duration, duration > 0
        else { return playing }
        let position = elapsed + max(0, now.timeIntervalSince(timestamp)) * rate
        return position <= duration + rateOnlyPlayingOverrunSecs ? true : playing
    }

    // ---- 切歌:旧标题下先到的那份锚点 ----
    //
    // 酷狗切到下一首时(整首放完、试听段到点),先在**上一首的标题下**发下一首的第一份锚点:带着下一首的
    // 时长,位置是这一段的起点(从头放 ~0,试听段从歌曲中间放起就是片段起点)。0.6~1s 后标题才换过来,
    // 新标题下的锚点多数比真实起播晚 ~0.5s、之后播放中不再重发。旧标题那份是准的,新标题那份整段恒偏慢。
    // 数据见 02 章「酷狗自然切歌」与决策 104。
    private static let resetAnchorLock = NSLock()
    /// 最近几份候选锚点。只留一份不够:新标题下紧跟着的那份位置同样很小,会把旧标题那份顶掉。
    nonisolated(unsafe) private static var recentResetAnchors: [ResetAnchor] = []
    private static let recentResetAnchorLimit = 4

    public struct ResetAnchor: Sendable, Equatable {
        public var title: String
        public var elapsed: Double
        public var timestamp: Date
        /// 这份锚点带着的下一首时长:标题没换、时长先换了的那份才有(见 `nextTrackDurationUnderOldTitle`);
        /// nil = 按位置归零认的。
        public var nextTrackDuration: Double?
        public init(title: String, elapsed: Double, timestamp: Date, nextTrackDuration: Double? = nil) {
            self.title = title
            self.elapsed = elapsed
            self.timestamp = timestamp
            self.nextTrackDuration = nextTrackDuration
        }
    }

    /// 没带下一首时长的锚点,位置不超过这么多才算一份归零锚点。
    public nonisolated static let resetAnchorMaxElapsed: Double = 1.0
    /// 新标题的锚点离候选锚点多久之内,才按候选锚点的起播时刻算;候选锚点是按位置归零认的,新锚点的位置也不能超过这么多。
    public nonisolated static let resetAnchorWindowSecs: TimeInterval = 3
    /// 两份锚点推出的起播时刻至少差这么多才补(再小就是锚点本身的抖动);超过上限说明不是同一次起播。
    public nonisolated static let resetAnchorMinCorrectionSecs: Double = 0.05
    public nonisolated static let resetAnchorMaxCorrectionSecs: Double = 1.5
    /// 时长差在这个以内算同一个值。
    public nonisolated static let resetAnchorDurationToleranceSecs: Double = 0.5

    nonisolated(unsafe) private static var lastLoggedStartCorrectionKey: String?
    /// 同一个锚点只记一行。
    private nonisolated static func noteStartCorrectionLogged(anchorKey: String) -> Bool {
        resetAnchorLock.lock()
        defer { resetAnchorLock.unlock() }
        guard lastLoggedStartCorrectionKey != anchorKey else { return false }
        lastLoggedStartCorrectionKey = anchorKey
        return true
    }

    /// 只对实测过的播放器开(02 章决策 41)。
    public nonisolated static func correctsFromResetAnchor(bundleID: String?) -> Bool {
        bundleID == PlaybackPlayer.kugou.bundleIdentifier
    }

    /// 一份锚点是不是下一首的第一份:标题跟上一份锚点相同,时长却变了。是就返回这个新时长。纯函数,selftest 直接覆盖。
    public nonisolated static func nextTrackDurationUnderOldTitle(
        previousTitle: String?, previousDuration: Double?, title: String?, duration: Double?
    ) -> Double? {
        guard let title, !title.isEmpty, title == previousTitle, let duration, let previousDuration,
              abs(duration - previousDuration) > resetAnchorDurationToleranceSecs
        else { return nil }
        return duration
    }

    /// stream watcher 报告:这一行带着锚点。位置归零的、带着下一首时长的(`nextTrackDuration`)记下来,
    /// 供之后换了标题的那份锚点对照。
    nonisolated static func noteAnchorForReset(title: String?, elapsed: Double?, timestamp: Date?,
                                               nextTrackDuration: Double? = nil) {
        guard let title, !title.isEmpty, let elapsed, let timestamp,
              elapsed <= resetAnchorMaxElapsed || nextTrackDuration != nil
        else { return }
        resetAnchorLock.lock()
        recentResetAnchors.append(ResetAnchor(title: title, elapsed: elapsed, timestamp: timestamp,
                                              nextTrackDuration: nextTrackDuration))
        if recentResetAnchors.count > recentResetAnchorLimit { recentResetAnchors.removeFirst() }
        resetAnchorLock.unlock()
    }

    private nonisolated static func currentResetAnchors() -> [ResetAnchor] {
        resetAnchorLock.lock()
        defer { resetAnchorLock.unlock() }
        return recentResetAnchors
    }

    /// 新标题这份锚点该往前补多少秒(= 它推出的起播时刻比候选锚点推出的晚多少)。纯函数,selftest 直接覆盖。
    ///
    /// 对照的是最近一份**标题不同**的候选锚点:同一个标题下的归零是单曲循环回绕(或新标题自己那份),
    /// 那份锚点本身就准。候选锚点带着下一首时长时,这份锚点的时长(`duration`)对得上才是同一首,位置不限
    /// (试听段可以从歌曲中间放起),对不上不补;没带时长的,这份锚点的位置不超过 `resetAnchorWindowSecs` 才补。
    public nonisolated static func resetAnchorStartCorrection(
        resets: [ResetAnchor], title: String?, elapsed: Double?, timestamp: Date?, duration: Double? = nil
    ) -> Double? {
        guard let title, let elapsed, let timestamp,
              let reset = resets.last(where: { $0.title != title })
        else { return nil }
        if let next = reset.nextTrackDuration, let duration {
            guard abs(duration - next) <= resetAnchorDurationToleranceSecs else { return nil }
        } else {
            guard elapsed <= resetAnchorWindowSecs else { return nil }
        }
        let gap = timestamp.timeIntervalSince(reset.timestamp)
        guard gap >= 0, gap <= resetAnchorWindowSecs else { return nil }
        let correction = (timestamp.timeIntervalSince1970 - elapsed)
            - (reset.timestamp.timeIntervalSince1970 - reset.elapsed)
        guard correction > resetAnchorMinCorrectionSecs, correction <= resetAnchorMaxCorrectionSecs else { return nil }
        return correction
    }

    // ---- 补过的锚点,App 重启后接着补 ----
    //
    // 候选锚点只在内存里,新标题那份晚的锚点播放中又不重发:补过一次就把锚点身份和补的量记进文件,
    // App 重启后同一个锚点接着补;锚点一变(暂停、拖动、换歌)就对不上了。见 02 章决策 104。
    nonisolated(unsafe) private static var persistedStartCorrection: AnchorStartCorrectionRecord?
    nonisolated(unsafe) private static var persistedStartCorrectionLoaded = false

    /// 这一拍补上的量记下来;同一个锚点只写一次。
    private nonisolated static func rememberStartCorrection(_ correction: Double, anchorKey: String,
                                                            bundleID: String, now: Date) {
        resetAnchorLock.lock()
        loadPersistedStartCorrectionLocked()
        guard persistedStartCorrection?.anchorKey != anchorKey else {
            resetAnchorLock.unlock()
            return
        }
        let record = AnchorStartCorrectionRecord(
            bundleID: bundleID, anchorKey: anchorKey, correctionSecs: correction,
            writtenAtMs: Int64(now.timeIntervalSince1970 * 1000))
        persistedStartCorrection = record
        resetAnchorLock.unlock()
        AnchorStartCorrectionFile.write(record)
    }

    /// 上一个进程给这个锚点补过的量。
    private nonisolated static func restoredStartCorrection(bundleID: String?, anchorKey: String) -> Double? {
        resetAnchorLock.lock()
        defer { resetAnchorLock.unlock() }
        loadPersistedStartCorrectionLocked()
        return restoredStartCorrection(record: persistedStartCorrection, bundleID: bundleID, anchorKey: anchorKey)
    }

    /// 调用方持有 `resetAnchorLock`。文件只读一次,之后以内存里这份为准。
    private nonisolated static func loadPersistedStartCorrectionLocked() {
        guard !persistedStartCorrectionLoaded else { return }
        persistedStartCorrectionLoaded = true
        persistedStartCorrection = AnchorStartCorrectionFile.read()
    }

    /// 记下的那份能不能用在这个锚点上:同一个播放器、锚点身份逐字一致、量在补偿范围内。纯函数,selftest 直接覆盖。
    public nonisolated static func restoredStartCorrection(
        record: AnchorStartCorrectionRecord?, bundleID: String?, anchorKey: String
    ) -> Double? {
        guard let record, record.bundleID == bundleID, record.anchorKey == anchorKey,
              record.correctionSecs > resetAnchorMinCorrectionSecs,
              record.correctionSecs <= resetAnchorMaxCorrectionSecs
        else { return nil }
        return record.correctionSecs
    }

    // ---- 跟随重发锚点的播放器:重发断档 = 卡在加载 ----
    //
    // KKBOX 在放的时候约每 1.06 秒重发一次锚点;卡在加载(网络慢、缓冲)时照旧报在放、速率 1,只是不再重发。上一份锚点
    // 过了 `republishOverdueSecs` 还没有下一份,这一拍就当作在加载:位置停在「上一份锚点 + 这段时长」,快照报没在走、
    // 标 `isWaitingToPlay`,下一份锚点一到就接着走。下一份锚点说明声音其实一直在走的(误报),这首余下部分不再停。
    // 见 02 章决策 107。
    private static let republishLock = NSLock()
    /// 停住时对着的那份锚点(曲目、原始 elapsed、时间戳)。
    nonisolated(unsafe) private static var republishHeldAnchor: (track: String, elapsed: Double, timestamp: Date)?
    /// 停住误报过的曲目,这首余下部分不再停。
    nonisolated(unsafe) private static var republishHoldDisabledTrack: String?

    /// 上一份锚点之后这么久还没有下一份,就当作卡在加载。
    public nonisolated static let republishOverdueSecs: TimeInterval = 1.5
    /// 停住之后来的下一份锚点,位置走的比墙钟少不到这么多,就是声音一直在走(误报)。
    public nonisolated static let republishFalseAlarmToleranceSecs: Double = 0.5

    /// 这一拍该不该按「在加载」停住:该停返回停住的位置,不该为 nil。停住的位置到了曲长就不停。纯函数,selftest 直接覆盖。
    public nonisolated static func republishOverdueHold(
        bundleID: String?, playing: Bool?, playbackRate: Double?, anchorElapsed: Double?, anchorTimestamp: Date?,
        duration: Double?, now: Date
    ) -> Double? {
        guard LocalPlaybackSource.followsRepublishedAnchors(bundleID: bundleID), playing == true,
              let rate = playbackRate, rate > 0, let elapsed = anchorElapsed, let timestamp = anchorTimestamp,
              now.timeIntervalSince(timestamp) > republishOverdueSecs
        else { return nil }
        let held = elapsed + republishOverdueSecs * rate
        if let duration, duration > 0, held >= duration { return nil }
        return held
    }

    /// 停住之后到的这份锚点说明声音其实一直在走:位置走的比墙钟少不到 `republishFalseAlarmToleranceSecs`。纯函数,selftest 直接覆盖。
    public nonisolated static func republishHoldWasFalseAlarm(
        heldElapsed: Double, heldTimestamp: Date, nextElapsed: Double, nextTimestamp: Date
    ) -> Bool {
        let wall = nextTimestamp.timeIntervalSince(heldTimestamp)
        return wall > 0 && nextElapsed - heldElapsed >= wall - republishFalseAlarmToleranceSecs
    }

    /// 这一拍的停住判定(`hold`:停住的位置),以及没停住时下一份锚点最晚该在什么时候到(`dueBy`,到点补查一次)。
    /// 换了锚点时先核上一次停住是不是误报。
    private nonisolated static func republishHold(
        bundleID: String?, trackKey: String, title: String?, playing: Bool?, playbackRate: Double?,
        anchorElapsed: Double?, anchorTimestamp: Date?, duration: Double?, now: Date
    ) -> (hold: Double?, dueBy: Date?) {
        guard LocalPlaybackSource.followsRepublishedAnchors(bundleID: bundleID) else { return (nil, nil) }
        republishLock.lock()
        defer { republishLock.unlock() }
        if let held = republishHeldAnchor, let elapsed = anchorElapsed, let timestamp = anchorTimestamp,
           held.track != trackKey || timestamp > held.timestamp {
            republishHeldAnchor = nil
            if held.track == trackKey {
                let wall = timestamp.timeIntervalSince(held.timestamp)
                if republishHoldWasFalseAlarm(heldElapsed: held.elapsed, heldTimestamp: held.timestamp,
                                              nextElapsed: elapsed, nextTimestamp: timestamp) {
                    republishHoldDisabledTrack = trackKey
                    logger.notice("republish hold was a false alarm: \(title ?? "", privacy: .public) moved \(elapsed - held.elapsed, format: .fixed(precision: 3))s in \(wall, format: .fixed(precision: 3))s; not holding again for this track")
                } else {
                    logger.notice("republish hold ended: \(title ?? "", privacy: .public) at \(elapsed, format: .fixed(precision: 3)) after \(wall, format: .fixed(precision: 3))s")
                }
            }
        }
        guard republishHoldDisabledTrack != trackKey else { return (nil, nil) }
        if let hold = republishOverdueHold(bundleID: bundleID, playing: playing, playbackRate: playbackRate,
                                           anchorElapsed: anchorElapsed, anchorTimestamp: anchorTimestamp,
                                           duration: duration, now: now),
           let elapsed = anchorElapsed, let timestamp = anchorTimestamp {
            if republishHeldAnchor == nil {
                logger.notice("republish overdue: holding \(title ?? "", privacy: .public) at \(hold, format: .fixed(precision: 3)) (last anchor \(now.timeIntervalSince(timestamp), format: .fixed(precision: 3))s ago)")
            }
            republishHeldAnchor = (trackKey, elapsed, timestamp)
            return (hold, nil)
        }
        guard playing == true, let timestamp = anchorTimestamp else { return (nil, nil) }
        return (nil, timestamp.addingTimeInterval(republishOverdueSecs))
    }

    // ---- 暂停中发布的锚点:真正开始计时的时刻 ----
    //
    // 网易云换歌时先在「暂停」态把新曲的 `elapsed=0 @ ts` 发出来,0.3~1.1s 后才真正出声,之后**不再
    // 重发锚点**、只把 playing 翻成 true(实测还会真/假来回翻十几次,最后一次 true 离出声 ~0.05s)。
    // 从锚点发布那一刻起算,整首歌恒偏快这段加载时间(数据见 02 章「网易云开播锚点」)。
    // 这种锚点真正的起算时刻是它之后那次 `playing:true`。
    private static let pausedAnchorLock = NSLock()
    nonisolated(unsafe) private static var pausedAnchorKey: String?
    nonisolated(unsafe) private static var pausedAnchorPublishedAt: Date?
    nonisolated(unsafe) private static var anchorPlaybackStart: (key: String, at: Date)?
    /// 暂停中发布的锚点之后多久内的 `playing:true` 才算它的起播(实测翻转都在发布后 1.2s 内)。
    /// 再往后的恢复是另一回事(用户自己按了播放),那时播放器会重发锚点,不归这里管。
    public nonisolated static let pausedAnchorStartWindow: TimeInterval = 5

    /// stream watcher 报告:这一行打了新锚点,当时是不是暂停态。
    nonisolated static func noteAnchorPublished(anchorKey: String, whilePaused: Bool, at: Date) {
        pausedAnchorLock.lock()
        defer { pausedAnchorLock.unlock() }
        pausedAnchorKey = whilePaused ? anchorKey : nil
        pausedAnchorPublishedAt = whilePaused ? at : nil
    }

    /// 最近到达的那个锚点是不是在暂停中发布的(stream watcher 没看到过锚点时为 false)。暂停那一拍拿它认
    /// 「快照里的冻结值还是播放时的旧锚点」,见 `LocalPlaybackSource.pauseAnchorIsStale`。
    public nonisolated static func latestAnchorPublishedWhilePaused() -> Bool {
        pausedAnchorLock.lock()
        defer { pausedAnchorLock.unlock() }
        return pausedAnchorKey != nil
    }

    /// stream watcher 报告:这一行报了 `playing:true`。落在暂停锚点的窗口里就记成它的起播时刻(后到的覆盖先到的)。
    nonisolated static func notePlaybackStarted(at: Date) {
        pausedAnchorLock.lock()
        defer { pausedAnchorLock.unlock() }
        guard let key = pausedAnchorKey, let published = pausedAnchorPublishedAt,
              Self.pausedAnchorStartApplies(publishedAt: published, startedAt: at)
        else { return }
        anchorPlaybackStart = (key, at.addingTimeInterval(-streamAnchorLatency))
    }

    /// 这个锚点(暂停中发布的)真正开始计时的时刻;不是这种锚点返回 nil。
    nonisolated static func playbackStart(forAnchorKey key: String) -> Date? {
        pausedAnchorLock.lock()
        defer { pausedAnchorLock.unlock() }
        guard let start = anchorPlaybackStart, start.key == key else { return nil }
        return start.at
    }

    /// 纯函数,selftest 直接覆盖。
    public nonisolated static func pausedAnchorStartApplies(publishedAt: Date, startedAt: Date) -> Bool {
        let gap = startedAt.timeIntervalSince(publishedAt)
        return gap >= 0 && gap <= pausedAnchorStartWindow
    }

    /// 这个播放器要不要把「暂停中发布的锚点」改从起播时刻算。只登记实测过的(网易云)。
    public nonisolated static func startsPausedAnchorOnPlay(bundleID: String?) -> Bool {
        bundleID == PlaybackPlayer.netease.bundleIdentifier
    }

    private nonisolated static func pruneAnchorSightingsLocked() {
        guard anchorSightings.count > anchorSightingCapacity else { return }
        let oldestFirst = anchorSightings.sorted { $0.value.at < $1.value.at }
        for (key, _) in oldestFirst.prefix(anchorSightings.count - anchorSightingCapacity) {
            anchorSightings.removeValue(forKey: key)
        }
    }

    /// 锚点身份。轮询路径(fetchRawMediaControlSnapshot)与 stream watcher 共用这一个构造;
    /// elapsedTime 定格到毫秒再拼 —— 两边都是从 JSON 数字解出来的 Double,理论上 String(_:)
    /// 一致,但一边走 JSONDecoder 一边走 JSONSerialization,不赌两条解码路径的格式化细节。
    public nonisolated static func anchorKey(artist: String?, title: String?, elapsedTime: Double?, timestamp: String?) -> String {
        let elapsed = elapsedTime.map { String(format: "%.3f", $0) } ?? "-"
        return "\(MediaControlSnapshot.trackKey(artist: artist, title: title))|\(elapsed)|\(timestamp ?? "-")"
    }

    // ---- Spotify 陈旧锚点重发 ----
    //
    // Spotify 会在播放中把 now-playing 信息重发一遍:elapsedTime 逐毫秒不变、时间戳却换成当下(playbackRate 顺带从 null 变回 1)。
    // MediaRemote 按新时间戳外推,elapsedTimeNow 一下退回几十秒,App 的 seek 分支把它当成真实回跳重锚,表现是"歌词落后很多,
    // 一暂停往前补一大段"(暂停时 Spotify 才重新算一次真实位置)。广告开始后 1~2 秒也常见同一形态。数据见 02 章「Spotify 恢复
    // 播放后的锚点相位:整秒时间戳与 stream 目击」。
    //
    // 签名 = 同一首歌、elapsedTime 逐 ms 相等、时间戳变了:真实的 seek / 暂停 / 恢复必然改 elapsed(恢复还会 +0.25 左右),
    // 只有"没重算 elapsed 就重发"才会一模一样。两条排除:
    //  - elapsed == 0 的重发,只对 `republishesZeroAnchor` 的播放器判,且要原锚点还很新(`zeroAnchorRepublishWindowSecs`)。
    //    同一首歌被「上一曲」按钮重头播放也是 0 @ 新时间戳,签名上跟重发一模一样,在会重发的播放器上只能按时间分:开播双发
    //    全挤在原锚点后 2 秒内(连发三次时累计 3.4s),而真的"回到 0"(曲末归零、隔了很久重播)要隔几分钟。
    //    名单不能外扩到没实测过的播放器:连发里哪一个是真起播点,各家相反(汽水音乐/网易云是第一个,Apple Music 是最后一个,
    //    见 02 章决策 41)。判反 = 整首歌恒定偏移,而且伺服看不见(reported 与 predicted 出自同一个坏锚点),只有暂停才纠得回来。
    //    两个方向的代价也不对称:错当重发,最多多走窗口那么长、下一个真锚点就纠回来;错当真锚点,是整首歌恒定落后重发间隔。
    //  - 按旧锚点外推已经越过曲长不判:旧锚点已死(单曲循环回绕 / 曲末),新锚点是真的。
    // 命中时调用方按原锚点时刻自己外推,既不信新时间戳,也不信按新时间戳外推的 elapsedTimeNow。

    /// 上一个**播放中**的锚点(暂停锚点不记:恢复必然重打)。`instant` 是它订正后的锚点时刻。
    public struct PlayingAnchor: Sendable, Equatable {
        public let track: String
        public let elapsed: Double
        public let timestamp: String
        public let instant: Date
        public init(track: String, elapsed: Double, timestamp: String, instant: Date) {
            self.track = track
            self.elapsed = elapsed
            self.timestamp = timestamp
            self.instant = instant
        }
    }

    /// elapsed == 0 的重发,离原锚点多久之内还算"重发"。取值见 isStaleAnchorRepublish 上面那段:
    /// 观测到的开播双发最远 1.99s、连发累计 3.4s,而最近的一次真"回到 0"在 175s 之后 —— 5 秒落在
    /// 两簇中间很宽的空档里,不是一个需要精调的数。
    public static let zeroAnchorRepublishWindowSecs: TimeInterval = 5

    /// 这次读到的播放锚点是不是上一个播放锚点的陈旧重发。纯函数,selftest 直接覆盖。
    /// `bundleID` 只用于 elapsed == 0 那条分支的准入(见上面那段);elapsed > 0 的签名是通用的
    /// MediaRemote 行为,不分播放器。
    public nonisolated static func isStaleAnchorRepublish(
        last: PlayingAnchor?, track: String, elapsed: Double?, timestamp: String?, duration: Double?,
        bundleID: String?, now: Date
    ) -> Bool {
        guard let last, let elapsed, let timestamp,
              last.track == track, last.elapsed == elapsed, last.timestamp != timestamp
        else { return false }
        if elapsed <= 0 {
            guard PlaybackPlayer.builtin(forBundleID: bundleID)?.republishesZeroAnchor == true else { return false }
            if republishGapSeconds(last: last, timestamp: timestamp, now: now) > zeroAnchorRepublishWindowSecs {
                return false
            }
        }
        if let duration, duration > 0, last.elapsed + now.timeIntervalSince(last.instant) > duration + 1 {
            return false
        }
        return true
    }

    /// 这次重发离**原**锚点多久。两个时间戳都解得出就按它们算(整秒,而要分开的两簇差着两个
    /// 数量级,够用);解不出才退回墙钟 —— 后者把轮询延迟也算进来,只当兜底。
    private nonisolated static func republishGapSeconds(last: PlayingAnchor, timestamp: String, now: Date) -> TimeInterval {
        if let newTS = parseTimestamp(timestamp), let oldTS = parseTimestamp(last.timestamp) {
            return newTS.timeIntervalSince(oldTS)
        }
        return now.timeIntervalSince(last.instant)
    }

    private static let playingAnchorLock = NSLock()
    nonisolated(unsafe) private static var lastPlayingAnchor: PlayingAnchor?
    nonisolated(unsafe) private static var lastIgnoredRepublishTimestamp: String?

    /// 记住"上一个播放锚点",并判定这次是不是它的陈旧重发。是 → 返回原锚点时刻(调用方据此自己
    /// 外推);否 → 记下这次的锚点,返回 nil。日志只在每个被忽略的新时间戳第一次出现时打一行。
    private nonisolated static func trackPlayingAnchor(
        track: String, elapsed: Double, timestamp: String, candidateInstant: Date, duration: Double?,
        bundleID: String?, now: Date
    ) -> Date? {
        playingAnchorLock.lock()
        defer { playingAnchorLock.unlock() }
        if let last = lastPlayingAnchor,
           isStaleAnchorRepublish(last: last, track: track, elapsed: elapsed, timestamp: timestamp,
                                  duration: duration, bundleID: bundleID, now: now) {
            if lastIgnoredRepublishTimestamp != timestamp {
                lastIgnoredRepublishTimestamp = timestamp
                logger.notice("stale anchor republish ignored: elapsed=\(elapsed, format: .fixed(precision: 3)) newTs=\(timestamp, privacy: .public) keepingAnchorTs=\(last.timestamp, privacy: .public) track=\(track, privacy: .public)")
            }
            return last.instant
        }
        lastPlayingAnchor = PlayingAnchor(track: track, elapsed: elapsed, timestamp: timestamp, instant: candidateInstant)
        lastIgnoredRepublishTimestamp = nil
        return nil
    }

    private nonisolated static func rememberedPlayingPosition(forTrack track: String) -> Double? {
        playingPositionLock.lock()
        defer { playingPositionLock.unlock() }
        guard playingPositionTrack == track else { return nil }
        return playingPositionValue
    }

    private nonisolated static func rememberPlayingPosition(_ position: Double, forTrack track: String, at sampledAt: Date) {
        playingPositionLock.lock()
        playingPositionTrack = track
        playingPositionValue = position
        playingPositionSampledAt = sampledAt
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

    /// 真正调用 media-control 子进程、解析原始输出。fetchAutoDetectedSnapshot、fetchMultiSelectedSnapshot、
    /// fetchMediaControlSnapshot 共用这一份子进程调用,各自拿到 bundleID 之后按自己的规则核对。
    private static func fetchRawMediaControlSnapshot() -> (MediaControlSnapshot, String)? {
        guard let binaryPath = binaryPath() else {
            setSnapshotFailure(.mediaControlMissing)
            return nil
        }
        // --now 让工具自己按内部时钟外推出一个不会冻结的 elapsedTimeNow(见文件顶部
        // 注释);--no-artwork 省掉几百 KB 的 base64 封面数据,这里从不使用;--micros 给出
        // 精确到微秒的锚点时间戳(不带它恒无小数秒,见 MediaControlMicros),键名由
        // RawPayload 换算回原名。
        //
        // 这是 2 秒一轮的热路径 —— 它卡住,悬浮歌词就停住。超时是这里最要紧的东西。
        appleMusicFocusLock.lock()
        let fallbackPlayer = lastAcceptedDirectQueryTarget?.player
        appleMusicFocusLock.unlock()
        let timeout = pollSnapshotTimeout(fallbackPlayer: fallbackPlayer)
        let started = Date()
        let result = runGet(["--now", "--no-artwork", "--micros"], binaryPath: binaryPath, timeout: timeout)
        let took = Date().timeIntervalSince(started)
        let timedOut = result?.timedOut == true
        if took >= slowSnapshotLogSecs || timedOut {
            logger.notice("media-control get took \(took, format: .fixed(precision: 2))s (timeout \(timeout, format: .fixed(precision: 0))s, timed out \(timedOut))")
        }
        guard let r = result, r.succeeded else {
            setSnapshotFailure(.mediaControlUnavailable)
            noteChannelExec(succeeded: false)
            return nil
        }
        noteChannelExec(succeeded: true)
        let data = r.stdout
        // 没有任何 App 在报告 Now Playing 时,media-control 输出字面量 "null",
        // 退出码仍是 0——JSONDecoder 对着 "null" 解码 RawPayload 会失败,走
        // `try?` 落到下面的 guard raw != nil,行为跟"没有可报告的正在播放"一致。
        // 退出码已经由上面的 r.succeeded 判过。
        guard let raw = try? JSONDecoder().decode(RawPayload.self, from: data),
              let reportedBundleID = raw.bundleIdentifier else {
            setSnapshotFailure(.nobodyReporting)
            return nil
        }
        // WebKit 的媒体进程替谁报的按负责进程认,Kaset 内嵌网页那份记在 Kaset 名下(见 `reportingPlayerBundleID`)。
        let owner = reportedBundleID == safariMediaProcessBundleID
            ? raw.processIdentifier.flatMap { responsibleBundleID(ofPID: $0) } : nil
        let bundleID = reportingPlayerBundleID(reportedBundleID, owner: owner)
        // 真读到了一份快照:通道是好的,自检留下的「坏了」也作废。
        noteChannelReadSnapshot()
        setNowPlayingIdentifiers(bundleID: bundleID, title: raw.title, artist: raw.artist,
                                 uniqueIdentifier: raw.uniqueIdentifier, trackNumber: raw.trackNumber,
                                 mediaType: raw.mediaType)
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
        // 暂停那一支现在还要一个输入:**同一首曲目**播放期间最后一次算出来的位置。
        // 锚点冻结的源(网页播放器,elapsedTime 恒 0)少了它就会在暂停瞬间归零,
        // 见 pausedPositionSeconds。按曲目记,换歌自动作废 —— 不然上一首的位置会漏到
        // 下一首头上。
        let trackKey = MediaControlSnapshot.trackKey(artist: raw.artist, title: raw.title)
        let sampledAt = Date()
        // 锚点身份三段拼:曲目 + 原始 elapsedTime + 原始时间戳字符串。任一变化 = 新锚点。
        // 跟 MediaControlStreamWatcher 共用 anchorKey(...) 这一个构造(它记的 tight 目击要靠
        // 同一把 key 才查得到)。
        let anchorKey = Self.anchorKey(
            artist: raw.artist, title: raw.title, elapsedTime: raw.elapsedTime, timestamp: raw.timestamp)
        let timestampDate = Self.parseTimestamp(raw.timestamp)
        // 下面一律用它,不用 raw.playing(见 effectivePlaying)。
        let playing = Self.effectivePlaying(
            bundleID: raw.bundleIdentifier, playing: raw.playing, playbackRate: raw.playbackRate,
            elapsedTime: raw.elapsedTime, timestamp: timestampDate, duration: raw.duration, now: sampledAt)
        let sighting = Self.firstSeen(anchorKey: anchorKey, now: sampledAt)
        // 播放中的锚点先过一道"陈旧重发"判定(见 isStaleAnchorRepublish):命中就按原锚点时刻外推。
        var republishedAnchorInstant: Date?
        if playing == true, let timestampDate, let elapsedRaw = raw.elapsedTime, let timestampString = raw.timestamp {
            let candidate = Self.estimatedAnchorInstant(timestamp: timestampDate, sighting: sighting)
            republishedAnchorInstant = Self.trackPlayingAnchor(
                track: trackKey, elapsed: elapsedRaw, timestamp: timestampString,
                candidateInstant: candidate, duration: raw.duration,
                bundleID: raw.bundleIdentifier, now: sampledAt)
        }
        let liveElapsed = Self.livePositionSeconds(
            playing: playing, elapsedTime: raw.elapsedTime, elapsedTimeNow: raw.elapsedTimeNow,
            playbackRate: raw.playbackRate, timestamp: timestampDate, now: sampledAt,
            lastPlayingPosition: Self.rememberedPlayingPosition(forTrack: trackKey),
            sighting: sighting, republishedAnchorInstant: republishedAnchorInstant,
            lastPlayingSampledAt: Self.rememberedPlayingSampledAt(forTrack: trackKey),
            pauseObservedAt: Self.lastPauseObservedAt(),
            playbackStartedAt: Self.startsPausedAnchorOnPlay(bundleID: raw.bundleIdentifier)
                ? Self.playbackStart(forAnchorKey: anchorKey) : nil)
        // 切歌时新标题的锚点晚打了,按旧标题下先到的那份候选锚点的起播时刻补回来(见 resetAnchorStartCorrection);
        // 这一拍没有候选锚点(App 中途重启过)时,同一个锚点用上一个进程记下的量(见 restoredStartCorrection)。
        let correctsStart = playing == true && Self.correctsFromResetAnchor(bundleID: raw.bundleIdentifier)
        let liveStartCorrection: Double? = correctsStart
            ? Self.resetAnchorStartCorrection(
                resets: Self.currentResetAnchors(), title: raw.title, elapsed: raw.elapsedTime, timestamp: timestampDate,
                duration: raw.duration)
            : nil
        let restoredCorrection: Double? = correctsStart && liveStartCorrection == nil
            ? Self.restoredStartCorrection(bundleID: raw.bundleIdentifier, anchorKey: anchorKey)
            : nil
        let startCorrection = liveStartCorrection ?? restoredCorrection
        let readingElapsed = liveElapsed.map { $0 + (startCorrection ?? 0) }
        if let liveStartCorrection {
            Self.rememberStartCorrection(liveStartCorrection, anchorKey: anchorKey,
                                         bundleID: raw.bundleIdentifier ?? "", now: sampledAt)
        }
        if let startCorrection, Self.noteStartCorrectionLogged(anchorKey: anchorKey) {
            let from = liveStartCorrection != nil ? "the reset anchor" : "the record kept across restart"
            logger.notice("natural advance anchor late: \(raw.title ?? "", privacy: .public) raw=\(raw.elapsedTime ?? -1, format: .fixed(precision: 3)) → +\(startCorrection, format: .fixed(precision: 3))s from \(from, privacy: .public)")
        }
        // 跟随重发锚点的播放器重发断档了,当作卡在加载、位置停住(见 republishHold)。
        let republish = Self.republishHold(
            bundleID: raw.bundleIdentifier, trackKey: trackKey, title: raw.title, playing: playing,
            playbackRate: raw.playbackRate, anchorElapsed: raw.elapsedTime, anchorTimestamp: timestampDate,
            duration: raw.duration, now: sampledAt)
        if playing == true, republish.hold == nil, let readingElapsed {
            Self.rememberPlayingPosition(readingElapsed, forTrack: trackKey, at: sampledAt)
        }
        let elapsed = republish.hold ?? readingElapsed
        // Spotify 的位置不在这里纠:认出是 Spotify 之后由 adaptedSnapshot 整份换成 AppleScript 那份(见 spotifyScript 头注)。
        //
        // 电台:系统报的 duration / elapsedTime 都是整档节目的,不是这首歌的。位置换成按曲目边界自己起的表(机制、实测数据与
        // 未验证项见 RadioTrackClock 头注)。起表时刻取 stream watcher 观察到换歌的那一刻,不取这一拍轮询的时刻:差的那 0.4~1.8 秒
        // 会变成整首歌的恒定滞后。换在这里而不是让下游各自判:LocalPlaybackSource 的伺服 / 锚点 / 歌词引擎拿到的就是一份正常的
        // 单曲快照,一处也不用改。
        //
        // 电台的 duration 照旧原样传,别置成 nil:`LocalPlaybackSource.apply` 里建进度锚点那一整支的闸是
        // `if playing, let duration = snapshot.duration, duration > 0`,duration 一 nil 锚点就建不起来,歌词引擎没有钟可走,
        // 表现成"电台放到歌了却没有歌词"。这一侧的 duration 只影响进度条分母(电台上本来就不准),不会写进歌词缓存(那是引擎的
        // 事,见 lyrimuse-engine/snapshot.go)。
        let isRadio = !(raw.radioStationHash ?? "").isEmpty
        Self.setRadioStationHash(isRadio ? raw.radioStationHash : nil)
        let radioClock = isRadio
            ? Self.advanceRadioClock(trackKey: trackKey, playing: playing == true, now: sampledAt,
                                     startedAt: Self.lastTrackChangeObserved(forKey: trackKey),
                                     systemPosition: elapsed, reportedDuration: raw.duration,
                                     anchorAge: timestampDate.map { sampledAt.timeIntervalSince($0) })
            : nil
        // 报单曲位置的台不顶替:位置与锚点保留系统原值,下游按普通 Apple Music 曲目处理(见 RadioTrackClock.State.perTrack)。
        let radioPosition: Double? = radioClock?.perTrack == true ? nil : radioClock?.position
        // Amazon Music 的位置换成按它的日志重放出来的(见 amazonMusicReading)。跟电台同一个理由换在这里:
        // 下游拿到的是一份锚点干净的快照。上一次会话留下的旧曲目那一帧不采纳。
        var amazonPosition: Double?
        if let reading = Self.amazonMusicReading(
            bundleID: bundleID, trackKey: trackKey, title: raw.title, metadataTimestamp: timestampDate,
            playing: playing == true, pid: raw.processIdentifier, duration: raw.duration, now: sampledAt) {
            if reading.staleMetadata {
                setSnapshotFailure(.targetNotPlayingMusic)
                return nil
            }
            amazonPosition = reading.position
        }
        // Pine Player 的锚点只到整秒、开播连发两份:位置换成 PinePlayhead 那块表,理由同 Amazon。
        let pine = bundleID == PinePlayerInfo.bundleID
            ? PinePlayhead.reading(track: trackKey, playing: playing == true, anchorElapsed: raw.elapsedTime,
                                   anchorAt: timestampDate, duration: raw.duration, pid: raw.processIdentifier, now: sampledAt)
            : nil
        let held = republish.hold != nil || pine?.waiting == true
        var snapshot = MediaControlSnapshot(
            title: raw.title,
            artist: raw.artist,
            album: raw.album,
            duration: raw.duration,
            elapsedTime: amazonPosition ?? radioPosition ?? pine?.position ?? elapsed,
            playing: held ? false : playing,
            playbackRate: held ? 0 : raw.playbackRate,
            // 复用这个字段原本的语义("这是当前选定播放器的一份有效快照",见
            // MediaControlSnapshot 注释)——调用方(fetchMediaControlSnapshot/
            // fetchAutoDetectedSnapshot)已经各自核实过 bundleID 是它关心的那个,
            // 这里如实置 true。
            isMusicApp: true,
            bundleIdentifier: bundleID,
            // 电台把锚点也换成自己那块表:留着原始值会让下游"锚点是不是开播那个"的判定
            // (anchorElapsedTime == 0)按整档节目的钟去解读,自相矛盾。
            anchorElapsedTime: amazonPosition ?? radioPosition ?? raw.elapsedTime,
            isRadio: isRadio ? true : nil
        )
        // 读到之后主线程可能要等一两百毫秒才处理(换歌那一刻加载封面 / 歌词,实测 0.21s),位置得按读到的时刻
        // 补到处理那一刻(见 MediaControlSnapshot.capturedAt)。只对实测过的播放器开(02 章决策 41)。
        if Self.stampsCaptureTime(bundleID: bundleID) || amazonPosition != nil || pine != nil { snapshot.capturedAt = sampledAt }
        if held { snapshot.isWaitingToPlay = true }
        if pine?.precise == true { snapshot.positionIsPrecise = true }
        snapshot.republishDueBy = republish.dueBy ?? pine?.dueBy
        snapshot.processIdentifier = raw.processIdentifier
        return (snapshot, bundleID)
    }

    /// Amazon Music 不报 elapsedTime:位置按它的日志重放,读不到日志时自记时(见 AmazonMusicPlayhead)。主路径与焦点回退都走这里,
    /// 回退那份不换的话屏上从 0 重新走(见 02 章决策 113)。不是 Amazon 或没有标题时返回 nil。
    private static func amazonMusicReading(
        bundleID: String?, trackKey: String, title: String?, metadataTimestamp: Date?, playing: Bool,
        pid: Int?, duration: Double?, now: Date
    ) -> AmazonMusicPlayhead.Reading? {
        guard bundleID == PlaybackPlayer.amazonMusic.bundleIdentifier, !(title ?? "").isEmpty else { return nil }
        let watcher = AmazonMusicLogWatcher.shared
        watcher.ensureStarted()
        return watcher.reading(
            trackKey: trackKey, metadataTimestamp: metadataTimestamp, playing: playing,
            pauseObservedAt: lastPauseObservedAt(), now: now, pid: pid.map { pid_t($0) }, duration: duration)
    }

    private static let spotifyNoticeLock = NSLock()
    private static var latestSpotifyNotice: SpotifyNotificationHint?

    /// `LocalPlaybackSource` 收到 Spotify 那条通知时记下(主队列上写,轮询的后台线程上读)。
    public nonisolated static func noteSpotifyNotice(_ notice: SpotifyNotificationHint) {
        spotifyNoticeLock.lock()
        defer { spotifyNoticeLock.unlock() }
        latestSpotifyNotice = notice
    }

    private static func currentSpotifyNotice() -> SpotifyNotificationHint? {
        spotifyNoticeLock.lock()
        defer { spotifyNoticeLock.unlock() }
        return latestSpotifyNotice
    }

    /// 问不到 Spotify 的 AppleScript 时,拿它那条通知里的 `Playback Position` 当它自己的钟。MediaRemote 的开播锚点
    /// 整首晚一截(02 章决策 28),通知在开播那一刻就到,按收到的时刻推出来的位置跟 `player position` 只差一两百毫秒。
    /// 只在放着、通知说的是这首歌、而且不早于 MediaRemote 最近一次重发锚点超过 `spotifyNoticeAnchorSlackSecs` 时用:
    /// 拖动后 MediaRemote 重发的锚点是准的,比它旧的通知让位。产出的读数不带锚点(`anchorElapsedTime` = nil),
    /// 下游按「播放器自己的钟」处置,跟 AppleScript 那份同一套起播领先量(见 02 章决策 63)。纯函数,selftest 直接覆盖。
    public nonisolated static func spotifyNoticeReading(_ mediaControl: MediaControlSnapshot,
                                                        notice: SpotifyNotificationHint?,
                                                        sampledAt: Date, now: Date) -> MediaControlSnapshot? {
        guard mediaControl.playing == true, let notice, notice.playing == true, let position = notice.position,
              notice.matches(title: mediaControl.title, artist: mediaControl.artist),
              let anchor = mediaControl.anchorElapsedTime, let elapsed = mediaControl.elapsedTime
        else { return nil }
        let rate = mediaControl.playbackRate ?? 1
        guard rate > 0 else { return nil }
        let anchorPublishedAt = sampledAt.addingTimeInterval(-(elapsed - anchor) / rate)
        guard notice.receivedAt >= anchorPublishedAt.addingTimeInterval(-spotifyNoticeAnchorSlackSecs) else { return nil }
        return MediaControlSnapshot(
            title: mediaControl.title, artist: mediaControl.artist, album: mediaControl.album,
            duration: mediaControl.duration,
            elapsedTime: position + now.timeIntervalSince(notice.receivedAt) * rate,
            playing: true, playbackRate: mediaControl.playbackRate, isMusicApp: mediaControl.isMusicApp,
            bundleIdentifier: mediaControl.bundleIdentifier, anchorElapsedTime: nil, isRadio: mediaControl.isRadio,
            capturedAt: now)
    }

    /// 开播时通知比 MediaRemote 的锚点先到(实测早约 1s),这点提前量仍算同一段播放。
    public nonisolated static let spotifyNoticeAnchorSlackSecs: Double = 3

    /// 问 Spotify 自己没问到时退回的 media-control 那份:它是**问之前**读的,中间可能等满了 JXA 的超时
    /// (自动化授权弹窗挂着时每次 5s 再加 SIGKILL 宽限)。在放的话按等掉的时间补到此刻、记成此刻读到的;
    /// 不补的话每一拍都整段落后,伺服把屏上位置往回拽(见 02 章决策 63)。纯函数,selftest 直接覆盖。
    public nonisolated static func spotifyFallbackCaughtUp(_ snapshot: MediaControlSnapshot, waited: TimeInterval,
                                                            now: Date) -> MediaControlSnapshot {
        guard snapshot.playing == true, let elapsed = snapshot.elapsedTime, waited > 0 else { return snapshot }
        return snapshot.withElapsed(elapsed + waited * (snapshot.playbackRate ?? 1), capturedAt: now)
    }

    /// 哪些播放器的 media-control 读数带上读到的时刻(见上面那句)。酷狗;Safari 的媒体进程
    /// (它的外推与页面 `currentTime` 逐拍差 0.001s,读数本身就是真值,晚处理多少就差多少);
    /// 跟随重发锚点的播放器(KKBOX,见 `LocalPlaybackSource.followsRepublishedAnchors`:位置要对齐这份读数,读数得准)。
    public static func stampsCaptureTime(bundleID: String?) -> Bool {
        correctsFromResetAnchor(bundleID: bundleID) || bundleID == safariMediaProcessBundleID
            || LocalPlaybackSource.followsRepublishedAnchors(bundleID: bundleID)
    }
    public static let safariMediaProcessBundleID = "com.apple.WebKit.GPU"

    /// 系统当选的这份会话记在谁名下。WebKit 的媒体进程每个用到网页的 App 各有一个,bundle id 都是
    /// `safariMediaProcessBundleID`,只有负责进程分得出是谁的(`owner`,见 `responsibleBundleID(ofPID:)`):Kaset 内嵌网页那份
    /// 记成 Kaset,别的照报上来的记(Safari 自己那份再经 `mediaProxyOwners` 换回 Safari)。见 02 章决策 91。纯函数,selftest 覆盖。
    public static func reportingPlayerBundleID(_ reported: String, owner: String?) -> String {
        reported == safariMediaProcessBundleID && owner == PlaybackPlayer.kaset.bundleIdentifier
            ? PlaybackPlayer.kaset.bundleIdentifier : PlayerBundleAliases.canonical(reported)
    }

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t
    /// 系统把子进程算到哪个 App 头上用的函数(活动监视器把 WebKit 的媒体进程算到宿主头上用的也是它)。私有符号,按名字取
    /// (`bitPattern: -2` 即 `RTLD_DEFAULT`);取不到为 nil。
    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    /// 这个进程的负责 App 的 bundle id;查不到为 nil。在轮询线程上调。
    private static func responsibleBundleID(ofPID pid: Int) -> String? {
        guard pid > 0, let responsible = responsiblePIDFunction else { return nil }
        let owner = responsible(pid_t(pid))
        guard owner > 0 else { return nil }
        return NSRunningApplication(processIdentifier: owner)?.bundleIdentifier
    }

    // MARK: - 电台曲内时钟

    private static let radioClockLock = NSLock()
    private static var radioClockState: RadioTrackClock.State?
    /// 落盘副本的最近一次内容,决定"这一拍要不要写盘"(见 RadioClockFile.shouldWrite)。
    private static var radioClockWritten: RadioClockRecord?
    /// 冷启动只尝试恢复一次:文件读不出来 / 判据不过就当没有,别每一拍都去读盘。
    private static var radioClockRestoreTried = false
    /// 这一刻在放的电台是哪个台(载荷里的 `radioStationHash`,非电台为 nil)。
    ///
    /// 走静态旁路而不是加进 `MediaControlSnapshot`:那个结构体有十三处构造点、还是 Decodable
    /// (加字段会顺带从 media-control 的 JSON 自动解),而这个值只有 `LocalPlaybackSource.apply`
    /// 一处要用 —— 用它给台卡分台(见 `RadioStationCard`)。同一时刻系统只有一个 Now Playing
    /// 会话,所以"当前那个台"是明确的;每次取快照都写一遍(非电台写 nil),不会留陈旧值。
    nonisolated(unsafe) private static var radioStationHashValue: String?

    public nonisolated static func currentRadioStationHash() -> String? {
        radioClockLock.lock()
        defer { radioClockLock.unlock() }
        return radioStationHashValue
    }

    /// 两条取快照的路径共用这一个写入点(轮询的 fetchRawMediaControlSnapshot,以及只勾
    /// Apple Music 时的 radioAwareAppleMusicSnapshot)—— 每次取快照都写一遍(非电台写 nil),
    /// 不会留陈旧值。
    private static func setRadioStationHash(_ hash: String?) {
        radioClockLock.lock()
        radioStationHashValue = hash
        radioClockLock.unlock()
    }

    /// 系统信息里跟这首歌一起报的三个原始标识,带着它们所属的播放器与原始曲名 / 歌手。
    /// 走静态旁路而不是加进 `MediaControlSnapshot`,理由同 `radioStationHashValue`;
    /// 读方(`fetchSnapshotWithProvenance`)按播放器 + 曲名 + 歌手核对,对不上当没有。
    public struct NowPlayingIdentifiers: Equatable, Sendable {
        public let bundleID: String
        public let title: String
        public let artist: String
        public let catalogTrackID: Int64?
        public let trackNumber: Int?
        public let mediaType: String?
    }

    nonisolated(unsafe) private static var nowPlayingIdentifiersValue: NowPlayingIdentifiers?

    public nonisolated static func currentNowPlayingIdentifiers() -> NowPlayingIdentifiers? {
        radioClockLock.lock()
        defer { radioClockLock.unlock() }
        return nowPlayingIdentifiersValue
    }

    /// 写入点同 `setRadioStationHash`:轮询的 fetchRawMediaControlSnapshot 每拍写,只勾 Apple Music 时按曲目探的那次写。
    private static func setNowPlayingIdentifiers(bundleID: String, title: String?, artist: String?,
                                                 uniqueIdentifier: Int64?, trackNumber: Int?, mediaType: String?) {
        let value = NowPlayingIdentifiers(
            bundleID: bundleID, title: title ?? "", artist: artist ?? "",
            catalogTrackID: uniqueIdentifier.flatMap { $0 == 0 ? nil : $0 },
            trackNumber: trackNumber.flatMap { $0 > 0 ? $0 : nil },
            mediaType: mediaType.flatMap { $0.isEmpty ? nil : $0 })
        radioClockLock.lock()
        nowPlayingIdentifiersValue = value
        radioClockLock.unlock()
    }

    /// 上一拍电台快照里系统报的位置(按曲目 key 记),换歌那一拍拿它判「系统位置归零了没有」,见 RadioTrackClock.perTrackSeed。
    private static var radioLastSystemPosition: (key: String, position: Double)?
    /// 这首起表时记下的「上一首最后的系统位置」与起表时刻,补判单曲位置(perTrackDecisionWindow 内)用。
    private static var radioTrackStartPrevious: Double?
    private static var radioTrackStartedAt: Date?

    /// 推进电台那块曲内表并取当前位置。状态只有一块(系统同一时刻只有一个 Now Playing 会话)。
    /// 纯算术在 `RadioTrackClock.advance`(selftest 钉住),这里只管加锁存取。
    /// `systemPosition` / `anchorAge` 是这一拍系统自己的读数,用来判这个台是不是报单曲位置(起表那一拍,
    /// 以及 perTrackDecisionWindow 内还没判成时的每一拍)。
    private static func advanceRadioClock(trackKey: String, playing: Bool, now: Date, startedAt: Date?,
                                          systemPosition: Double?, reportedDuration: Double?,
                                          anchorAge: TimeInterval?)
        -> (position: Double, perTrack: Bool) {
        radioClockLock.lock()
        defer { radioClockLock.unlock() }
        let previousSystem = radioLastSystemPosition
        if let systemPosition { radioLastSystemPosition = (trackKey, systemPosition) }
        // 冷启动:内存里没有表,先看看上一个进程留下的账能不能接(判据见 RadioClockFile 头注)。
        // 接不上就是 nil,后面照旧按 startedAt 播种 —— 跟没有这份文件时逐字相同。
        if radioClockState == nil, !radioClockRestoreTried {
            radioClockRestoreTried = true
            if let restored = RadioClockFile.restorable(RadioClockFile.load(), trackKey: trackKey, now: now) {
                radioClockState = restored
                logger.notice("radio clock: restored key=\(trackKey, privacy: .public) position=\(restored.position, format: .fixed(precision: 3)) gap=\(now.timeIntervalSince(restored.tickedAt), format: .fixed(precision: 3))")
            }
        }
        let starting = radioClockState?.trackKey != trackKey
        if starting {
            radioTrackStartPrevious = previousSystem?.key == trackKey ? nil : previousSystem?.position
            radioTrackStartedAt = now
        }
        let deciding = starting || (radioClockState?.perTrack == false && radioTrackStartedAt.map {
            now.timeIntervalSince($0) <= RadioTrackClock.perTrackDecisionWindow } == true)
        let perTrack = deciding && playing
            ? RadioTrackClock.perTrackSeed(
                systemPosition: systemPosition, anchorAge: anchorAge, previousPosition: radioTrackStartPrevious,
                reportedDuration: reportedDuration)
            : nil
        let next = RadioTrackClock.advance(radioClockState, trackKey: trackKey, playing: playing, now: now,
                                           startedAt: startedAt, perTrackSeed: perTrack,
                                           systemPosition: systemPosition)
        // 只在起表那一拍打一行:换歌是低频事件,而"播种了多少"是这套机制唯一看得见的产物 —— 没有它,
        // 链路断掉(startedAt 恒 nil、key 对不上)只会安静地退回从 0 起,表现成"整首歌恒慢一点"。
        if !starting, perTrack != nil, radioClockState?.perTrack == false {
            logger.notice("radio clock: per-track upgrade key=\(trackKey, privacy: .public) system=\(systemPosition ?? -1, format: .fixed(precision: 3)) wallclock=\(radioClockState?.position ?? -1, format: .fixed(precision: 3)) prev=\(radioTrackStartPrevious ?? -1, format: .fixed(precision: 3))")
        }
        if starting {
            logger.notice("radio clock: start key=\(trackKey, privacy: .public) seed=\(next.position, format: .fixed(precision: 3)) observed=\(startedAt == nil ? "no" : "yes", privacy: .public) perTrack=\(perTrack == nil ? "no" : "yes", privacy: .public) system=\(systemPosition ?? -1, format: .fixed(precision: 3)) duration=\(reportedDuration ?? -1, format: .fixed(precision: 1)) prev=\(previousSystem?.position ?? -1, format: .fixed(precision: 3))")
        }
        radioClockState = next
        // 落盘,好让下一个进程接得上。写不写由 shouldWrite 定(换歌/播放翻转立刻写,平凡推进 15 秒一次)。
        let record = RadioClockRecord(trackKey: next.trackKey, position: next.position,
                                      tickedAtMs: Int64(next.tickedAt.timeIntervalSince1970 * 1000),
                                      playing: next.playing, perTrack: next.perTrack ? true : nil)
        if RadioClockFile.shouldWrite(previous: radioClockWritten, next: record, now: now) {
            radioClockWritten = record
            RadioClockFile.write(record)
        }
        return (next.position, next.perTrack)
    }

    /// 这首歌的电台表是不是判成了「系统报单曲位置」。adaptedSnapshot 据此决定要不要整份换成 AppleScript 读数。
    private static func radioTrackIsPerTrack(_ trackKey: String) -> Bool {
        radioClockLock.lock()
        defer { radioClockLock.unlock() }
        return radioClockState?.trackKey == trackKey && radioClockState?.perTrack == true
    }
}
