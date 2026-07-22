import Foundation

// 用 AppleScript(JXA)直接问 Music.app 本身要"现在在放什么",不依赖外部 `media-control`
// (需要 `brew install`,自带一份 `MediaRemoteAdapter.framework` + 一段 Perl 脚本去访问
// 私有 MediaRemote 框架,没有文档、可能随系统版本失效)。两者需要的都是同一个"自动化"
// 权限(MusicAutomationPermission),换成 AppleScript 这条苹果官方支持、系统自带的路径,
// 不需要用户再多装一个 Homebrew 包。
//
// 返回值特意拼成跟旧版 `media-control get` 完全相同的 JSON 形状(title/artist/album/
// duration/elapsedTime/playing/playbackRate/isMusicApp/bundleIdentifier)——
// MediaControlSnapshot 的字段、以及 collector 侧 snapshot.go 的 extract() 都不用跟着
// 改一行,只是换了"这份 JSON 从哪个进程产出"而已。
//
// player position 是 Music.app 自己实时算的播放位置(精确到 ~0.1s),不是旧版
// media-control 那个会在稳定播放期间整段冻结不动的 elapsedTime——这意味着原来专门
// 补一次 AppleMusicPositionClient 调用来绕开"冻结"这个坑的做法,现在已经没有必要:
// 这一份快照本身给出的 elapsedTime 就已经是精确值,不需要再单独问一次。
public enum MediaControlClient {
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
    public static func fetchSnapshot() -> MediaControlSnapshot? {
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
}
