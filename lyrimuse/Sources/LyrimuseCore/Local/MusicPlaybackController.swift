import Foundation

// 跟 AppleMusicPositionClient(同目录,"读"精确播放进度)对称的"写"操作——发指令
// 控制当前选定播放器(PlaybackPlayerPreference.current)的播放。
//
// 2026-07-29 之前这里无条件发 AppleScript 给"Music"这一个应用,不管当前选的是哪个
// 播放器——QQ 音乐/网易云音乐接入时都没有同步修这一处,导致选了它们之后悬浮窗/全局
// 快捷键的播放/暂停/上一首/下一首按钮全部不生效(AppleScript 发给了根本没在播的
// Music.app),是遗留下来一直没修的坑,这次一起补上。
//
// Apple Music 继续走 AppleScript(复用同一份"自动化"权限,TCC 是按 (发起方 App,
// 目标 App) 这一对整体授权,不是按具体某条 AppleScript 指令单独授权,调用方在真正
// 发指令之前应该自己检查 MusicAutomationPermission,这里不重复做判断)。QQ 音乐/
// 网易云音乐都没有 AppleScript 支持,改发 media-control 的控制指令(实测坐实:
// media-control 的播放控制指令走的是系统级 MediaRemote,对"当前系统认定的 Now
// Playing 焦点"生效,不需要指定具体是哪个 App——跟读取状态那条路径依赖同一个
// "当前是谁在报告"的系统机制,QQ 音乐/网易云音乐被读取路径确认正在播放时,这几个
// 控制指令天然作用在它们身上,不会误控到别的 App)。失败就静默失败(跟
// AppleMusicPositionClient 一样宽松,不是核心路径)。
public enum MusicPlaybackController {
    public static func playPause() {
        dispatch(appleScript: #"tell application "Music" to playpause"#, mediaControlCommand: "toggle-play-pause")
    }

    public static func nextTrack() {
        dispatch(appleScript: #"tell application "Music" to next track"#, mediaControlCommand: "next-track")
    }

    public static func previousTrack() {
        dispatch(appleScript: #"tell application "Music" to previous track"#, mediaControlCommand: "previous-track")
    }

    private static func dispatch(appleScript: String, mediaControlCommand: String) {
        if PlaybackPlayerPreference.current == .appleMusic {
            runAppleScript(appleScript)
        } else {
            runMediaControl(mediaControlCommand)
        }
    }

    private static func runAppleScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    // 二进制路径解析复用 MediaControlClient.binaryPath()(同目录,读取状态那条路径
    // 也要用这同一个二进制),不重复各写一份。
    private static func runMediaControl(_ command: String) {
        guard let binaryPath = MediaControlClient.binaryPath() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [command]
        try? process.run()
    }
}
