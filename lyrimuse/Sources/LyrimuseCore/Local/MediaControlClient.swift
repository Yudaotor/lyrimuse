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
// - QQ 音乐:用 `sdef`/PlistBuddy 核实过,QQ音乐.app 完全没有 AppleScript 支持(没有
//   .sdef 文件,也没开 NSAppleScriptEnabled)——AppleScript 这条路对它是死路,只能改走
//   系统级 MediaRemote(经内置的 `media-control` 二进制读,build.sh 从 Homebrew 拷贝进
//   app bundle,不需要用户自己装任何东西,见该文件注释;BSD-3-Clause 开源,
//   https://github.com/ungive/media-control)。实测坐实两个细节:①原始 elapsedTime/
//   timestamp 字段在稳定播放期间会整段冻结(跟旧版 media-control 用在 Music.app 上
//   时一样的坑),但 `--now` 参数给的 elapsedTimeNow 是内部按真实时钟外推的,实测跨
//   2 分钟窗口误差在 0.5 秒以内,足够覆盖现有歌词同步引擎 700ms 的匹配容差;②读取
//   全程没有触发任何系统权限弹窗,跟 Apple Music 这条路要的"自动化"权限完全无关。
//   MediaRemote 是系统级的、App 无关的机制,任何注册了 MPNowPlayingInfoCenter 的
//   App(网页视频/Safari 等)都可能占用"当前正在播放"这个位置,必须靠
//   bundleIdentifier 精确核对确实是 QQ 音乐本身在报告,见 qqMusicBundleID。
public enum MediaControlClient {
    private static let qqMusicBundleID = "com.tencent.QQMusicMac"

    public static func fetchSnapshot(player: PlaybackPlayer = PlaybackPlayerPreference.current) -> MediaControlSnapshot? {
        switch player {
        case .appleMusic: return fetchAppleMusicSnapshot()
        case .qqMusic: return fetchQQMusicSnapshot()
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try? JSONDecoder().decode(MediaControlSnapshot.self, from: data)
        } catch {
            return nil
        }
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
    // API,直接从 Bundle.main.resourcePath 拼这条固定子路径。
    private static func fetchQQMusicSnapshot() -> MediaControlSnapshot? {
        guard let resourcePath = Bundle.main.resourcePath else {
            logger.error("app bundle resourcePath unavailable")
            return nil
        }
        let binaryPath = resourcePath + "/media-control/bin/media-control"
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            logger.error("media-control binary not found in app bundle")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        // --now 让工具自己按内部时钟外推出一个不会冻结的 elapsedTimeNow(见文件顶部
        // 注释);--no-artwork 省掉几百 KB 的 base64 封面数据,这里从不使用。
        process.arguments = ["get", "--now", "--no-artwork"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // 没有任何 App 在报告 Now Playing 时,media-control 输出字面量 "null",
            // 退出码仍是 0——JSONDecoder 对着 "null" 解码 RawPayload 会失败,走
            // `try?` 落到下面的 guard raw != nil,行为跟"没有可报告的正在播放"一致。
            guard process.terminationStatus == 0,
                  let raw = try? JSONDecoder().decode(RawPayload.self, from: data),
                  raw.bundleIdentifier == qqMusicBundleID else {
                // bundleIdentifier 对不上:系统当前的 Now Playing 是别的 App(网页
                // 视频/Safari 等),不是 QQ 音乐——不能把它当成 QQ 音乐的"正在播放"。
                return nil
            }
            // elapsedTimeNow 只在真的在播放时才可信——实测坐实:一首已经暂停的歌,
            // elapsedTimeNow 仍然会按暂停前最后一次记录的 playbackRate 继续按真实
            // 时钟外推(拿到过远超歌曲时长本身的荒谬值),因为暂停这件事本身并没有让
            // media-control 内部的外推基准归零。暂停时真正正确的位置就是原始
            // elapsedTime(暂停就是"冻结在这一刻",不需要外推)。
            let elapsed = (raw.playing == true) ? (raw.elapsedTimeNow ?? raw.elapsedTime) : raw.elapsedTime
            return MediaControlSnapshot(
                title: raw.title,
                artist: raw.artist,
                album: raw.album,
                duration: raw.duration,
                elapsedTime: elapsed,
                playing: raw.playing,
                playbackRate: raw.playbackRate,
                // 复用这个字段原本的语义("这是当前选定播放器的一份有效快照",见
                // MediaControlSnapshot 注释)——上面已经用 bundleIdentifier 精确核实过
                // 确实是 QQ 音乐在报告,这里如实置 true。
                isMusicApp: true
            )
        } catch {
            return nil
        }
    }
}
