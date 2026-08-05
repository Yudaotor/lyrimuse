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

    /// 跳到曲目内的某个位置(秒)。跟上面三个动作走同一套双后端分派:Apple Music 用
    /// AppleScript 的 `set player position to`,其余播放器用 media-control 的 `seek`
    /// (实测核实过内置二进制的 `--help` 里有 `seek POSITION` 这个一等命令)。
    ///
    /// 小数位固定截到 3 位:AppleScript 的 player position 和 media-control 都吃浮点秒,
    /// 但直接插值 Double 可能吐出 `2.2000000000000002` 这种科学计数/长尾表示,拼进
    /// AppleScript 源码里不保险。
    ///
    /// 负值夹到 0。上界故意**不**在这里夹——这一层不知道曲目时长(调用方才知道),多传一点
    /// 由播放器自己处理(实测两个后端都只是跳到结尾/切下一首,不会出错),在这里凭猜测夹
    /// 反而会掩盖调用方的计算错误。
    /// preferAppleScript 让调用方按"这一刻实际在播的是谁"覆盖后端选择。设置里选了
    /// "自动识别"时 PlaybackPlayerPreference.current 不是 .appleMusic,dispatch 默认会走
    /// media-control;但如果实际在播的就是 Apple Music,那么位置**读**路径走的是精确的
    /// AppleScript 播放头,写路径也该走同一条,两边保持一致。
    public static func seek(toSeconds seconds: Double, preferAppleScript: Bool = false) {
        let value = seekArgument(forSeconds: seconds)
        let script = #"tell application "Music" to set player position to "# + value
        if preferAppleScript {
            runAppleScript(script)
            return
        }
        dispatch(appleScript: script, mediaControlCommand: "seek", mediaControlArguments: [value])
    }

    /// 把秒数格式化成两个后端都吃、且能安全拼进 AppleScript 源码的字符串。抽成独立的纯
    /// 函数是为了能被 lyrimuse-selftest 覆盖——seek 本身要发子进程,测不了。
    ///
    /// 三件事:
    /// ① 固定 3 位小数。直接插值 Double 可能吐出 "2.2000000000000002" 这种长尾表示,
    ///    拼进 AppleScript 源码里不保险。
    /// ② locale 显式固定成 en_US_POSIX。2026-08-05 实测核实过:`String(format:)` **不带**
    ///    locale 参数时本来就不做本地化(输出 "2.200"),只有显式传一个逗号小数点的区域
    ///    (如 de_DE)才会吐 "2,200"。所以这里不是在修一个现存 bug,而是把"必须是点"这个
    ///    要求写死在代码里——这个字符串要拼进 AppleScript 源码,一旦变成逗号就是语法错误,
    ///    不该依赖"默认行为恰好正确"这种隐式前提。
    /// ③ 负值夹到 0。上界故意**不**在这里夹:这一层不知道曲目时长(调用方才知道),多传一点
    ///    由播放器自己处理(跳到结尾/切下一首,不会出错),在这里凭猜测夹反而会掩盖调用方的
    ///    计算错误。
    public static func seekArgument(forSeconds seconds: Double) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), clamped)
    }

    private static func dispatch(appleScript: String, mediaControlCommand: String, mediaControlArguments: [String] = []) {
        if PlaybackPlayerPreference.current == .appleMusic {
            runAppleScript(appleScript)
        } else {
            runMediaControl(mediaControlCommand, arguments: mediaControlArguments)
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
    private static func runMediaControl(_ command: String, arguments: [String] = []) {
        guard let binaryPath = MediaControlClient.binaryPath() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [command] + arguments
        try? process.run()
    }
}
