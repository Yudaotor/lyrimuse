import AppKit
import Foundation
import os

/// Audirvana(订阅版 Studio、买断版 Origin)的 AppleScript 读数。它不往系统 Now Playing 报,曲目、播放状态、位置都只能从它的脚本字典
/// (`Audirvana.sdef`)读:系统那边没人在放时 `MediaControlClient.preferringPlayingAudirvana` 直接问它一次,读数合成一份快照。
///
/// 实测(放本地文件,只录它自己的声音对真值):
/// - `player position` 带小数,比真实出声早 0.01~0.03 秒,开播、暂停恢复、跳转、自动连播都一样,按精确读数用。
/// - `playing track duration` 只到整秒,精确时长另按当前文件读。
/// - `playing track url` 连斜杠也百分号编码(`file://%2FUsers%2F…`),先去掉 `file://` 再整段解码(`filePath`)。
/// - 没写标签的文件,歌名是去掉扩展名的文件名,歌手、专辑空。
/// - 停住(列表放完、按了停止)时 `player state` 是 Stopped,曲目字段约 2.5 秒后变空,当没在放。
/// - 把 `event types reported` 设成 TrackChanged 后,开播、恢复、暂停、换歌、放完都发 `noticeName` 这条分布式通知;
///   换歌那一条报的状态可能是 Paused(其实在放),播放中跳转、按上一首回到开头都不发。所以通知只当「马上读一次」的信号。
///
/// Origin 跟 Studio 是同一个程序的两个版本:脚本字典逐字相同、发同一条通知,只是 bundle id 和进程名不同,两个不能同时开
/// (共用数据目录,后开的那个起不来)。两个都认,读数一律记成 `bundleID`(Studio 那个,`PlaybackPlayer.audirvana`),
/// 歌词缓存、设置勾选都按同一个播放器算;发脚本(读数、封面、控制)时按此刻在跑的那个(`runningBundleID`)。
///
/// 见 02 章决策 254。
public enum AudirvanaPlayerInfo {
    public static var bundleID: String { PlaybackPlayer.audirvana.bundleIdentifier }
    /// 两个版本的 bundle id,Studio 在前(Origin 登记在 `PlayerBundleAliases`,找进程、判装没装、启动它时也都认)。
    public static let editionBundleIDs = PlayerBundleAliases.all(for: PlaybackPlayer.audirvana.bundleIdentifier)

    /// 此刻在跑的那个版本;都没在跑为 nil。
    public static func runningBundleID() -> String? {
        editionBundleIDs.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }
    /// 设了 TrackChanged 之后它发的分布式通知。
    public static let noticeName = "com.audirvana.audirvana-plus.playerStatus"

    /// JXA 快照脚本:没在跑、停住、没有曲目时回 `null`,不会把它拉起来。每个 Audirvana 进程第一次读时把它的
    /// `event types reported` 设成 TrackChanged(只影响它发不发上面那条通知)。位置放在最后读。
    public static let script = """
    (() => {
        if (!globalThis.lyrimuseAppKit) { ObjC.import('AppKit'); globalThis.lyrimuseAppKit = true; }
        let ARunning = null;
        for (const id of [\(editionBundleIDs.map { "\"\($0)\"" }.joined(separator: ", "))]) {
            const found = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(id);
            if (Number(found.count) > 0) { ARunning = found; break; }
        }
        if (ARunning === null) return JSON.stringify(null);
        const pid = Number(ARunning.objectAtIndex(0).processIdentifier);
        const A = Application(pid);
        if (globalThis.lyrimuseAudirvanaEvents !== pid) {
            try { A.eventTypesReported = "TrackChanged"; globalThis.lyrimuseAudirvanaEvents = pid; } catch (e) {}
        }
        try {
            const state = A.playerState();
            if (state !== "Playing" && state !== "Paused") return JSON.stringify(null);
            const title = A.playingTrackTitle();
            if (!title) return JSON.stringify(null);
            const reading = {
                title: title,
                artist: A.playingTrackArtist() || "",
                album: A.playingTrackAlbum() || "",
                duration: A.playingTrackDuration(),
                playing: state === "Playing",
                url: A.playingTrackUrl() || ""
            };
            reading.position = A.playerPosition();
            return JSON.stringify(reading);
        } catch (e) {
            return JSON.stringify(null);
        }
    })()
    """

    /// 脚本回的那一份。
    struct Raw: Decodable {
        let title: String
        let artist: String?
        let album: String?
        let duration: Double?
        let playing: Bool
        let url: String?
        let position: Double?
    }

    /// 解出来的一次读数。
    public struct Reading: Sendable {
        public var snapshot: MediaControlSnapshot
        /// 当前文件的路径;放的不是本地文件(流媒体)为 nil。
        public var filePath: String?
        /// 放的是网络电台(`isRadio(url:duration:)`)。
        public var isRadio = false
    }

    /// 放的是网络电台:地址不是本地文件,时长又不是正数(电台报 -9.7e8 这类值)。这时歌名是「收音机 URL: 地址」,ICY 标题脚本里没有,
    /// 播放条上那份只在第一次见到某个标题时更新,当不了这一首的身份,所以电台不当歌报。见 02 章决策 254。纯函数,selftest 覆盖。
    public static func isRadio(url: String?, duration: Double?) -> Bool {
        guard let url, !url.isEmpty, filePath(fromTrackURL: url) == nil else { return false }
        guard let duration else { return true }
        return !(duration > 0) || !duration.isFinite
    }

    /// 脚本输出 → 读数;`null`、解不开、没有位置为 nil。身份与时长在这里换好(`identity`、精确时长)。
    /// 在放时位置标精确(`positionIsPrecise`),读数时刻记成 `capturedAt`。会读盘(同一个文件只读一次)。
    public static func reading(fromScriptOutput data: Data, capturedAt: Date,
                               fileDuration: (String) -> Double? = VoxPlayerInfo.cachedFileDuration) -> Reading? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let position = raw.position,
              position.isFinite, position >= 0 else { return nil }
        let path = filePath(fromTrackURL: raw.url)
        let id = identity(title: raw.title, artist: raw.artist ?? "", album: raw.album ?? "", filePath: path)
        guard !id.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let reported = (raw.duration ?? 0) > 0 ? raw.duration : nil
        let duration = VoxPlayerInfo.preciseDuration(reported: reported, file: path.flatMap(fileDuration)) ?? reported
        var snapshot = MediaControlSnapshot(
            title: id.title, artist: id.artist.isEmpty ? nil : id.artist, album: id.album.isEmpty ? nil : id.album,
            duration: duration, elapsedTime: position, playing: raw.playing, playbackRate: raw.playing ? 1 : 0,
            isMusicApp: true, bundleIdentifier: bundleID, anchorElapsedTime: nil, isRadio: nil, capturedAt: capturedAt)
        if raw.playing { snapshot.positionIsPrecise = true }
        return Reading(snapshot: snapshot, filePath: path, isRadio: isRadio(url: raw.url, duration: raw.duration))
    }

    /// `playing track url` → 文件路径。它连斜杠都编码(`file://%2FUsers%2F…`),标准写法(`file:///Users/…`)也认;
    /// 不是本地文件为 nil。纯函数,selftest 覆盖。
    public static func filePath(fromTrackURL text: String?) -> String? {
        guard let text, text.hasPrefix("file://") else { return nil }
        let rest = String(text.dropFirst("file://".count))
        guard let decoded = rest.removingPercentEncoding else { return nil }
        let path = decoded.hasPrefix("localhost/") ? String(decoded.dropFirst("localhost".count)) : decoded
        return path.hasPrefix("/") && path.count > 1 ? path : nil
    }

    /// 读数里的歌名、歌手、专辑换成快照用的:先还原乱码(三个字段一起判);没写标签的文件(歌手空、歌名就是去掉扩展名的
    /// 文件名)有「 - 」按第一个拆成歌手和歌名,跟 VOX、Swinsian 写出同一份。纯函数,selftest 覆盖。
    public static func identity(title: String, artist: String, album: String,
                                filePath: String?) -> (title: String, artist: String, album: String) {
        let fixed = PlayerTitleSplit.repairingCJKMojibake([artist, title, album])
        var (outArtist, outTitle, outAlbum) = (fixed[0], fixed[1], fixed[2])
        guard outArtist.trimmingCharacters(in: .whitespaces).isEmpty, let filePath else { return (outTitle, outArtist, outAlbum) }
        let base = PlayerTitleSplit.strippingAudioExtension(URL(fileURLWithPath: filePath).lastPathComponent)
        guard !base.isEmpty, title == base else { return (outTitle, outArtist, outAlbum) }
        outTitle = base
        outArtist = ""
        outAlbum = ""
        if let dash = base.range(of: " - ") {
            let left = base[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = base[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { (outArtist, outTitle) = (left, right) }
        }
        return (outTitle, outArtist, outAlbum)
    }

    // MARK: 卡住时退避

    /// 问它一次等满超时(它主线程卡住、或者整机过载)之后,隔这么久再问。不退避的话每一拍都等满超时,常驻 osascript 被反复
    /// 杀掉重启,用同一个常驻进程的别家播放器读数跟着断。
    public static let stallBackoffSecs: TimeInterval = 20

    /// 这一次问它算不算卡住:没问成、而且耗时到了超时的九成。没在跑、停住这种很快回 `null` 的不算。纯函数,selftest 覆盖。
    public static func stalled(succeeded: Bool, elapsed: TimeInterval, timeout: TimeInterval) -> Bool {
        !succeeded && elapsed >= timeout * 0.9
    }

    // MARK: 最近一次读数

    private static let current = OSAllocatedUnfairLock<(title: String, artist: String, path: String?)?>(initialState: nil)

    /// 读到一次之后记下:写播放状态(`local_file`)、取封面时用。
    static func remember(_ reading: Reading) {
        let s = reading.snapshot
        current.withLock { $0 = (s.title ?? "", s.artist ?? "", reading.filePath) }
    }

    /// 最近一次读到的那首(歌手、歌名)对上时,它的文件(不读盘)。
    public static func currentFilePath(artist: String, title: String) -> String? {
        current.withLock { entry in
            guard let entry, entry.title == title, entry.artist == artist else { return nil }
            return entry.path
        }
    }

    /// 最近一次读到的那首。
    static func currentEntry() -> (title: String, artist: String, path: String?)? { current.withLock { $0 } }

    // MARK: 封面

    /// 读它此刻那首显示的封面(`playing track airfoillogo`,TIFF:文件嵌着的,没有就是它挑的同目录图)写进 argv 第一项那个文件,
    /// 回它此刻报的歌名;没在跑、没有图回空串。先判在不在跑,`tell` 不会把它拉起来。`appID` 是此刻在跑的那个版本:
    /// 脚本按它编译字典里的属性名,不能写成运行时才定的变量。纯函数,selftest 覆盖。
    public static func artworkScriptLines(appID: String) -> [String] { [
        "on run argv",
        "if application id \"\(appID)\" is not running then return \"\"",
        "tell application id \"\(appID)\"",
        "set t to playing track title",
        "set d to playing track airfoillogo",
        "end tell",
        "if d is missing value then return \"\"",
        "set fh to open for access POSIX file (item 1 of argv) with write permission",
        "try",
        "set eof fh to 0",
        "write d to fh",
        "end try",
        "close access fh",
        "return t",
        "end run",
    ] }

    /// 记下的这首的封面(转成 JPEG)。脚本回的歌名对不上(这期间换了歌)、没有图、关掉了脚本这条腿为 nil。会阻塞,不要在主线程调用。
    static func scriptArtwork(for entry: (title: String, path: String?)) -> Data? {
        guard !SourceKnockout.isOut(.audirvanaScript), let appID = runningBundleID() else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-audirvana-artwork-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let arguments = artworkScriptLines(appID: appID).flatMap { ["-e", $0] } + [file.path]
        guard let r = ProcessRunner.run("/usr/bin/osascript", arguments, timeout: MusicPlaybackController.appleScriptTimeout),
              r.succeeded,
              let rawTitle = String(data: r.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              artworkBelongs(rawTitle: rawTitle, to: entry),
              let tiff = FileIO.read(file), let jpeg = CoverArtReplacementGate.jpegData(tiff),
              CoverArtReplacementGate.isImage(jpeg)
        else { return nil }
        return jpeg
    }

    /// 脚本回的歌名(它原样报的:乱码、没写标签时是去掉扩展名的文件名)是不是记下的这首。纯函数,selftest 覆盖。
    public static func artworkBelongs(rawTitle: String, to entry: (title: String, path: String?)) -> Bool {
        guard !rawTitle.isEmpty else { return false }
        if rawTitle == entry.title || PlayerTitleSplit.repairingCJKMojibake(rawTitle) == entry.title { return true }
        return entry.path.map { PlayerTitleSplit.strippingAudioExtension(URL(fileURLWithPath: $0).lastPathComponent) } == rawTitle
    }

    // MARK: 播放控制

    /// 一条播放控制(media-control 的指令名)换成发给 `appID` 那个版本的脚本;字典里没有的动作为 nil。跳转按秒写(它的位置带小数)。
    /// 纯函数,selftest 覆盖。
    public static func controlScript(_ command: String, arguments: [String], appID: String = bundleID) -> String? {
        let verb: String
        switch command {
        case "toggle-play-pause": verb = "playpause"
        case "play": verb = "resume"
        case "pause": verb = "pause"
        case "next-track": verb = "next track"
        case "previous-track": verb = "previous track"
        case "seek":
            guard let value = arguments.first, let seconds = Double(value), seconds.isFinite, seconds >= 0 else { return nil }
            verb = "set player position to " + MusicPlaybackController.seekArgument(forSeconds: seconds)
        default: return nil
        }
        return "if application id \"\(appID)\" is not running then return \"\"\ntell application id \"\(appID)\" to " + verb
    }

    /// 能发给它的播放控制。
    public static let controlCommands: Set<String> = ["toggle-play-pause", "play", "pause", "next-track", "previous-track", "seek"]
}
