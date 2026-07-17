import Foundation

// 跟 AppleMusicPositionClient(同目录,"读"精确播放进度)对称的"写"操作——发指令
// 控制 Music.app 播放,不需要读返回值,所以不用像那边一样解析 osascript 的 stdout。
// 复用同一份"自动化"权限(TCC 是按 (发起方 App, 目标 App) 这一对整体授权,不是按
// 具体某条 AppleScript 指令单独授权),调用方在真正发指令之前应该自己检查
// MusicAutomationPermission,这里不重复做判断——保持这三个函数纯粹只管"发指令"
// 这一件事。失败就静默失败(跟 AppleMusicPositionClient 一样宽松,不是核心路径)。
public enum MusicPlaybackController {
    public static func playPause() {
        run(#"tell application "Music" to playpause"#)
    }

    public static func nextTrack() {
        run(#"tell application "Music" to next track"#)
    }

    public static func previousTrack() {
        run(#"tell application "Music" to previous track"#)
    }

    private static func run(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
